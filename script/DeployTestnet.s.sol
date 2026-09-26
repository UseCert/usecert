// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {CertVault} from "../src/CertVault.sol";
import {Certificate} from "../src/Certificate.sol";
import {CertOracle} from "../src/CertOracle.sol";
import {CertFactory} from "../src/CertFactory.sol";
import {SolvencyRegistry} from "../src/SolvencyRegistry.sol";
import {CapacityOracle} from "../src/CapacityOracle.sol";
import {LighterSim} from "../src/sim/LighterSim.sol";
import {ReplayAggregator} from "../src/sim/ReplayAggregator.sol";
import {TestUSDG} from "../src/sim/TestUSDG.sol";
import {TestFaucet} from "../src/sim/TestFaucet.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title  UseCert C1 testnet deployment — Robinhood Chain testnet (46630)
///
/// @notice THE ONLY REPRODUCIBLE PATH TO A DEPLOYMENT. `CertFactory` cannot deploy a vault and no
///         contract can: `CertVault`'s creation code is 25,743 B and any contract embedding it
///         would have to fit that inside EIP-170's 24,576 B *runtime* ceiling. See
///         `docs/DEPLOYMENT-CHECKLIST.md` §0. `CertFactory` is a registry now, and this script is
///         what deploys the vaults it registers.
///
/// @dev    `docs/DEPLOYMENT-CHECKLIST.md` IS NORMATIVE. This script implements §4 (governance
///         binding), §5 (governance parameters and their order), §6 (the bootstrap sequence) and
///         §9 (the read-backs). Read it before changing a line here.
///
/// @dev    WHAT THE `require`s IN THIS SCRIPT DO AND DO NOT PROVE. `forge script --broadcast`
///         simulates the entire run first and only then sends the transactions it collected. So
///         every `require` below asserts the **local simulation's** state, never on-chain state.
///         That is genuinely valuable — a misconfiguration aborts the run before a single
///         transaction is broadcast, rather than half-completing an unrepairable deployment of
///         immutables — but it is NOT §9, which says "read these back on-chain".
///
///         §9 IS INTENDED TO BE DISCHARGED by `script/VerifyTestnet.s.sol`, which reads
///         `deployments/46630.json` and re-asserts every item against the live chain, and by
///         `script/smoke/SmokeTest.s.sol`, which performs the one real dust `forceExit` §9 asks
///         for. **NEITHER FILE IS IN THIS TREE YET** — they belong to a task still in flight, so
///         nothing here should be read as asserting they exist. Until they land, §9's on-chain half
///         is done by hand: `docs/TESTNET-RUNBOOK.md` §7.4's health check is the equivalent
///         minimum, and it is a minimum and not a substitute. When they do land, do not delete
///         either on the grounds that this script already checks those things. It does not.
///
/// @dev    THREE SENDERS, and the split is a safety property, not tidiness:
///
///           - `DEPLOYER_PK`  — the simulators, `CapacityOracle`, `CertFactory`, both vaults, and
///                              the bootstrap/collateral phase.
///           - `GOV_PK`       — `SolvencyRegistry` and both `CertOracle`s, plus the governance
///                              phase. §4: both bind `governance = msg.sender` AT CONSTRUCTION and
///                              it is immutable, so they are constructed inside
///                              `vm.startBroadcast(GOV_PK)` in `run()`'s own frame — never from a
///                              helper contract, never via CREATE2. If governance lands on an
///                              address nobody controls, attester rotation is unreachable forever
///                              and the remedy is a full redeployment.
///           - `ATTESTER_PK`  — `attest()` and `setMarkPrice()` only. It deploys nothing.
///
///         No key is ever hardcoded, logged, or derived from a mnemonic here. The operator sets the
///         three env vars. Only the derived ADDRESSES are logged.
///
/// @dev    USAGE — SELF-CONTAINED. No collateral or faucet address is read from the environment;
///         this script deploys both itself, from the deployer, inside `_phase1_simulators()`.
///
///           export DEPLOYER_PK=0x...  GOV_PK=0x...  ATTESTER_PK=0x...  BATCH_KEEPER=0x...
///           forge script script/DeployTestnet.s.sol \
///             --rpc-url robinhood_testnet --broadcast --slow
///
///         `--slow` matters: the run spans three senders and later transactions depend on earlier
///         ones having landed.
///
/// @dev    THE COLLATERAL TOKEN AND THE FAUCET, AND WHY THEY ARE DEPLOYED RATHER THAN INJECTED.
///
///         `src/sim/TestUSDG.sol` (Task 8) is the deployable 6-decimal stand-in for `USDG`, and
///         `src/sim/TestFaucet.sol` hands it out to testers. `_phase1_simulators()` deploys both
///         from the deployer — who becomes `TestUSDG.owner` — mints the deployer's own seed
///         collateral and the faucet's opening float (both owner-gated `mint` calls), and the
///         faucet is constructed pointed at the token this same run just deployed. Nothing here is
///         read from `COLLATERAL` or `TEST_FAUCET`; there is no way to point this script at a
///         collateral token it did not itself deploy, and therefore no way for the decimals check
///         below to be checking someone else's token.
///
///         Six decimals is not a detail. `USDG` on the real chain has 6, and `CertVault` reads
///         `IERC20Metadata(collateral).decimals()` exactly ONCE at construction and stores it as an
///         immutable. Deploy against an 18-decimal token by mistake and `_to18`/`_from18` are wrong
///         in both directions forever — every published figure off by 10**12 — with no setter to
///         repair it. `TestUSDG.decimals()` is a `pure` override returning the literal 6, so there
///         is no deployment of it with any other value; the `require` below is defence in depth,
///         kept alive by `test_scriptRevertsOnWrongCollateralDecimals` substituting a differently-
///         shaped token through the `_deployCollateral()` seam rather than by trusting the literal.
///
///         A MAINNET DEPLOYMENT MUST NOT REUSE THIS. `TestUSDG` and `TestFaucet` are disposable
///         testnet scaffolding — `TestUSDG.owner` can mint an unbounded supply of the very asset
///         a vault's solvency is denominated in. A mainnet deployment script takes the REAL `USDG`
///         address as an injected, already-deployed address (the same `COLLATERAL`-env shape this
///         script used before Task 8 landed) and never deploys collateral itself. See
///         `docs/DEPLOYMENT-CHECKLIST.md` §1.
contract DeployTestnet is Script {
    // ---------------------------------------------------------------------------------- errors

    /// @dev Guarded so the script cannot be pointed at mainnet by accident. A named error rather
    ///      than a `require` string because this is the one condition a test asserts by selector.
    error DeployTestnet_WrongChain(uint256 actual, uint256 expected);
    /// @dev Task 7 gated `LighterSim.settleBatch` to `owner` or `keeper`; an unregistered keeper
    ///      leaves no address on file for the bot that has to call it after deployment, and
    ///      `settleBatch` would revert `LighterSim_OnlyOwnerOrKeeper` for it the first time it did.
    error DeployTestnet_MissingBatchKeeper();

    // ------------------------------------------------------------------------------- the chain

    /// @dev Robinhood Chain testnet. Verified live 2026-09-09 with `cast chain-id` against
    ///      https://rpc.testnet.chain.robinhood.com. Mainnet's chain ID is still UNVERIFIED
    ///      (docs/TESTNET-PLAN.md §8), which is a second reason this guard is an equality and not
    ///      a "not mainnet" test.
    uint256 internal constant CHAIN_ID = 46_630;

    // ------------------------------------------------------- shared parameters, and why each one
    //
    // Every value below is IMMUTABLE at the vault or the oracle. There is no setter and no upgrade
    // path (Law 6). A number got wrong here is got wrong permanently.

    /// @dev `docs/TESTNET-PLAN.md` §1 and §3. NEVER RELAX THIS. Leverage is
    ///      `10000 / targetMarginBps`, so 9000 is ~1.11x and 5000 (the constructor's floor) is the
    ///      2x ceiling. The whole design is a 1:1 hedge with a margin cushion; relaxing this turns
    ///      the vault into a leveraged fund and every solvency argument in the audit stops holding.
    uint256 internal constant TARGET_MARGIN_BPS = 9_000;

    /// @dev `docs/TESTNET-PLAN.md` §3, the "Testnet (either)" row — deliberately BELOW the
    ///      capacity-derived figures for real vaults (uTSLA 2_000e18, uSPY 50_000e18) so testers
    ///      cross into the QUEUED mint/redeem path on purpose rather than never exercising it.
    ///      The instant path's mint-to-fill variance lands on the hot buffer (~10% of TVL), so an
    ///      instant cap above the buffer is decorative.
    uint256 internal constant INSTANT_CAP_18 = 1_000e18;

    /// @dev C3: how long a mint receipt stays settleable before it can only be refunded. Bounds
    ///      how far the price may have moved between `requestMint`'s recorded `requestPx18` and
    ///      `settleMint`'s band check.
    uint256 internal constant SETTLE_WINDOW = 1 days;

    /// @dev The band `settleMint` allows between the request price and the settle price.
    uint256 internal constant SETTLE_BAND_BPS = 500;

    uint256 internal constant MINT_FEE_BPS = 10;
    /// @dev Must be <= 10_000 or `gross18 - fee18` underflows inside `forceExit` for every holder —
    ///      a reachable Law 2 breach, bounded at construction since Finding 1. 10 bps is nowhere
    ///      near it; the note is here so nobody "tunes" this field without reading that bound.
    uint256 internal constant REDEEM_FEE_BPS = 10;

    /// @dev ============================ TESTNET REACHABILITY VALUE ============================
    ///      900 s (15 min) IS A TESTNET VALUE AND MUST NOT BE CARRIED TO MAINNET.
    ///
    ///      `docs/TESTNET-PLAN.md` §1 sets the MAINNET shape at **93_600 s (26 hours)**, just above
    ///      the real Chainlink feeds' own 24 h heartbeat, so the 24/5 market gap, the weekend, and
    ///      a corporate-action pause do not read as a dead feed.
    ///
    ///      On testnet 46630 THERE IS NO CHAINLINK AT ALL (six mainnet proxies return `0x`), so the
    ///      feed is the `ReplayAggregator` this script deploys and the only thing that advances it
    ///      is `script/FeedKeeper.s.sol`. 900 s answers one question — how old may an observation
    ///      be and still be usable — against a keeper we run ourselves, and it means the keeper
    ///      must push at least every 15 minutes or MINTING PAUSES. That is the intended trade: a
    ///      short bound makes a stopped keeper obvious immediately instead of certifying a stale
    ///      price for a day.
    ///
    ///      Copying 900 to mainnet would pause minting every weekend. Copying 93_600 to testnet
    ///      would let a dead keeper keep minting open for a day. Neither value is portable.
    ///      Redemption is unaffected either way — `forceExit` prices off `pxUnguarded()` (Law 2).
    ///      =====================================================================================
    uint256 internal constant STALENESS_SECONDS = 900;

    /// @dev Task 1 DECOUPLED this from `stalenessSeconds`; do not set them equal out of habit,
    ///      that coupling is exactly what Task 1 removed. This is H-1's confirmation window: how
    ///      long an out-of-band price must hold before the deviation reference concedes one
    ///      clamped `deviationBps` step. A RISK TOLERANCE, not a heartbeat. Must not be 0
    ///      (`CertOracle_ConfigOutOfBounds`) — at zero the `roundId` proof is the only gate and it
    ///      bounds round distinctness, not rate, degrading to a full clamped step per block.
    ///      300 s is short for a testnet so a tester can actually observe the two-phase poke
    ///      complete inside a session; mainnet's reasoning puts it on the order of an hour.
    uint256 internal constant POKE_CONFIRMATION_SECONDS = 300;

    /// @dev NEVER 0. At zero the H-1 clamp permits no advance in either direction, so the FIRST
    ///      price tick pauses minting and it stays paused until an operator widens their own
    ///      tolerance — which they cannot, because this is immutable. 500 bps (5%) is ~10x the
    ///      widest honest basis measured live (11.3-49.3 bps across 13 markets), so it does not
    ///      fire on ordinary noise, and it is the per-window budget a sustained dislocation gets.
    uint256 internal constant DEVIATION_BPS = 500;

    /// @dev The band between the independent feed and the venue's attested mark. Read ONLY when
    ///      `singleSource == false`, which is this deployment's mode — see SINGLE_SOURCE.
    uint256 internal constant BASIS_BAND_BPS = 500;

    /// @dev ================== §2's SHARPEST PRE-DEPLOY GATE, AND A HUMAN ASSERTION ==============
    ///      `false` DECLARES that `feed` and the venue mark are INDEPENDENT price sources. Nothing
    ///      on-chain can check that; the whole basis guard rests on this bit.
    ///
    ///      Why `false` here. The feed is a `ReplayAggregator` owned by the DEPLOYER and advanced
    ///      by `script/FeedKeeper.s.sol` from real Chainlink mainnet prints (TSLA and SPY both have
    ///      live mainnet feeds — this is why the plan picks SPY over NVDA). The venue mark is
    ///      written by the ATTESTER from `LighterSim`'s own state. Two different keys, two
    ///      different sources, so the basis band is a real cross-check and `mintAllowed()` keeps
    ///      all three of its guards. `true` would additionally cap `deviationBps` at
    ///      MAX_SINGLE_SOURCE_DEVIATION_BPS = 200 and construction would REVERT at our 500.
    ///
    ///      STATED PLAINLY RATHER THAN SOFTENED (§8): on testnet that independence is
    ///      ORGANISATIONAL, not economic. Both price paths are ultimately operated by us, and a
    ///      single operator running both keepers can move them together in a way no mainnet
    ///      attacker could. Testnet does not prove the basis band works; it proves it is wired and
    ///      that honest operation passes it. Do not let this configuration be read as evidence
    ///      about mainnet.
    ///
    ///      FOR A REAL MIRROR: set this `true` for any market with no Chainlink feed — 28 of the
    ///      venue's 57 perp markets, 20.5% of open interest, including XAU, XAG, ANTHROPIC, OPENAI
    ///      and SHEIN — and verify `oracle.singleSource()` against the feed actually wired before
    ///      funding anything. Set `false` on a venue-derived feed and the deployment fails
    ///      SILENTLY: `basisBpsChecked()` returns `known = true, bps = 0`, a healthy basis
    ///      asserted and never computed.
    ///      =====================================================================================
    bool internal constant SINGLE_SOURCE = false;

    /// @dev CapacityOracle's depth leg: capacity is `depthBps` of attested open interest, inside
    ///      the immutable `[minDepthBps, maxDepthBps]` bounds governance can never escape. 10% of
    ///      OI is the figure every capacity number in `docs/TESTNET-PLAN.md` is quoted at.
    uint256 internal constant DEPTH_BPS = 1_000;
    uint256 internal constant MIN_DEPTH_BPS = 100;
    uint256 internal constant MAX_DEPTH_BPS = 3_000;

    /// @dev Below this age `maxNotional18` returns 0 and MINTING IS OFF. It must exceed the
    ///      attester keeper's real cadence with margin. 300 s is why `script/keepers/Attester.s.sol`
    ///      MUST be running: without it minting stops ~5 minutes after deployment, and the runbook's
    ///      first troubleshooting row exists because that reads like a deploy failure.
    uint256 internal constant MAX_ATTESTATION_AGE_SEC = 300;

    /// @dev THE SINGLE IMMUTABLE BOUND ON A COMPROMISED OR LYING ATTESTER (§5). The attester writes
    ///      `openInterest18` and the depth leg is derived from it, so without this ceiling an
    ///      attester can widen capacity arbitrarily. `type(uint256).max` would remove the only
    ///      bound that survives them. 1e9 * 1e18 is ~1000x the largest real market's capacity and
    ///      still a real, finite, considered number.
    uint256 internal constant MAX_ABSOLUTE_CAP_18 = 1_000_000_000e18;

    /// @dev The venue's per-asset withdrawal ceiling, in venue base units. `uint64` max is
    ///      effectively unbounded, which is correct for the simulator; §9 asserts the `<= uint64`
    ///      bound because `LighterCore.withdraw` takes a `uint64`.
    uint256 internal constant VENUE_WITHDRAW_CAP = type(uint64).max;

    /// @dev Verified live across all 57 venue markets: `5000` = 50% of `ASSET_MARGIN_TICK`. Passed
    ///      as exactly `LighterSim.VENUE_IMF_BPS` so the simulator matches the venue and is never
    ///      MORE PERMISSIVE than it (Global Constraint 5 — this project has shipped three defects a
    ///      passing suite could not see because the mock was easier than the venue).
    uint256 internal constant SIM_REQUIRED_MARGIN_BPS = 5_000;

    /// @dev The real Robinhood Chain feeds report 8 (verified live, e.g. the TSLA feed at
    ///      0x4A1166a659A55625345e9515b32adECea5547C38). `ReplayAggregator` matches them.
    uint8 internal constant FEED_DECIMALS = 8;

    /// @dev USDG's index in the venue's collateral asset table.
    uint16 internal constant COLLATERAL_ASSET_INDEX = 3;
    uint8 internal constant ROUTE_TYPE = 0;

    /// @dev What the deployer seeds into each vault's buffer. Must be >= `10 ** decimals` or
    ///      `bootstrap()` reverts (§6 step 6), and large enough that `bufferCapacity18()` is not
    ///      the binding leg of `maxNotional18`'s `min()` at deployment.
    uint256 internal constant SEED_COLLATERAL = 100_000e6;

    /// @dev The one figure the whole deployment turns on, and it is NOT a style choice: `USDG` has
    ///      6 decimals and `CertVault` reads the collateral's decimals once, at construction, into
    ///      an immutable. See the contract NatSpec.
    uint8 internal constant COLLATERAL_DECIMALS = 6;

    /// @dev `TestFaucet`'s per-claim drip and per-address cooldown. Matches the convention in
    ///      `test/sim/TestCollateralAndFaucet.t.sol`: enough tUSDG for a meaningful mint, on a
    ///      cooldown long enough that the float stretches across many testers rather than one
    ///      address draining it in a loop.
    uint256 internal constant FAUCET_DRIP = 10_000e6;
    uint256 internal constant FAUCET_INTERVAL = 1 days;

    /// @dev The faucet's opening float, minted by the deployer at deploy time (the deployer is
    ///      `TestUSDG.owner`). 100 drips' worth so testers do not run it dry on day one.
    ///      `TestFaucet` has deliberately no privileged refill path (see its NatSpec) — topping it
    ///      up later is a plain ERC-20 `transfer` in, done by whoever holds `owner` on the token.
    uint256 internal constant FAUCET_OPENING_FLOAT = 100 * FAUCET_DRIP;

    // ------------------------------------------------------------------------------ the assets

    /// @dev Per-mirror parameters. `docs/TESTNET-PLAN.md` §6 is the playbook: shared across all
    ///      mirrors are `SolvencyRegistry`, `CapacityOracle`, `CertFactory` and the simulator; new
    ///      per mirror are a `CertOracle`, a `CertVault`, and the `Certificate` + `BufferBook` the
    ///      vault's constructor deploys.
    struct AssetParams {
        string name;
        string symbol;
        string feedDescription;
        uint16 marketIndex;
        uint8 priceDecimals;
        uint8 sizeDecimals;
        uint256 seedPx18;
        uint256 absoluteCap18;
        uint256 openInterest18;
        uint256 bufferFloor18;
        uint256 bufferFeeOn18;
        uint256 bufferMintSlow18;
    }

    /// @dev Deployed addresses per mirror, kept in storage rather than in locals: `run()` would be
    ///      "stack too deep" otherwise, and the address book needs them all at the end anyway.
    struct AssetDeployment {
        address aggregator;
        address oracle;
        address vault;
        address certificate;
        address bufferBook;
    }

    AssetParams[] internal assets;
    AssetDeployment[] internal deployed;

    // shared addresses
    address internal collateral;
    address internal testFaucet;
    address internal batchKeeper;
    address internal lighter;
    address internal registry;
    address internal capacity;
    address internal factory;

    // senders
    address internal deployerAddr;
    address internal govAddr;
    address internal attesterAddr;

    // --------------------------------------------------------------------- overridable parameters
    //
    // These five were `constant`, which made a mainnet subclass impossible: Solidity cannot
    // override a constant, and every one of them has to change on mainnet. They are now virtual
    // getters returning the same testnet literals, so this contract and its tests are unaffected,
    // and `DeployMainnet` can answer differently.
    //
    // The literals stay where they were, with their reasoning attached. Moving the VALUES here
    // would have separated each number from the paragraph explaining it, which is most of what
    // makes them reviewable.

    /// @dev The chain this script refuses to run anywhere but.
    function _chainId() internal view virtual returns (uint256) {
        return CHAIN_ID;
    }

    /// @dev Feed staleness budget. 900 here is a TESTNET REACHABILITY VALUE; mainnet is 93_600.
    function _stalenessSeconds() internal view virtual returns (uint256) {
        return STALENESS_SECONDS;
    }

    /// @dev The venue's asset index for the collateral. 3 is LighterSim's own numbering and
    ///      means nothing on a real venue.
    function _collateralAssetIndex() internal view virtual returns (uint16) {
        return COLLATERAL_ASSET_INDEX;
    }

    /// @dev Declares the feed and the venue mark economically independent. See SINGLE_SOURCE:
    ///      on testnet that independence is organisational, not economic.
    function _singleSource() internal view virtual returns (bool) {
        return SINGLE_SOURCE;
    }

    /// @dev Buffer float seeded per vault at deploy. Free on testnet because the deployer owns
    ///      the collateral's mint; on mainnet this is real money and there is no mint to call.
    function _seedCollateral() internal view virtual returns (uint256) {
        return SEED_COLLATERAL;
    }

    /// @dev Whether a fourth key is needed to advance the venue's batches. True for the
    ///      simulator, which gates `settleBatch` on owner-or-keeper; false for a real venue,
    ///      which settles its own.
    function _requiresBatchKeeper() internal view virtual returns (bool) {
        return true;
    }

    // ------------------------------------------------------------------------------------ setup

    /// @dev DELIBERATELY NOT read from `script/config/testnet.json`. A Foundry script parsing JSON
    ///      for safety-critical immutables adds a failure mode — a mistyped key yields zero, and
    ///      `absoluteCap18 = 0` means "no capacity" while `deviationBps = 0` locks minting shut —
    ///      in exchange for nothing, since every value is immutable at the vault. The JSON is
    ///      documentation of these values; the compiler is the source of truth. Keep them in sync
    ///      by review.
    /// @dev Safe mode: the multisig that is governance, or zero for an EOA governance key.
    function _externalGovernance() internal view virtual returns (address) {
        return address(0);
    }

    /// @dev Safe mode: the SolvencyRegistry the Safe created (its governance is the Safe).
    function _externalRegistry() internal view virtual returns (address) {
        revert("SAFE MODE: no external registry configured");
    }

    /// @dev Safe mode: asset i's CertOracle, created by the Safe.
    function _externalOracle(uint256) internal view virtual returns (address) {
        revert("SAFE MODE: no external oracle configured");
    }

    /// @dev False in Safe mode until the phase-4 Safe batch has executed on chain.
    function _phase4Applied() internal view returns (bool) {
        return _externalGovernance() == address(0);
    }

    function _loadAssets() internal virtual {
        // uTSLA FIRST: market 16, for continuity with the existing suite (the whole test fixture
        // is built at TSLA's price and market index).
        assets.push(
            AssetParams({
                name: "UseCert TSLA",
                symbol: "uTSLA",
                feedDescription: "RHTSLA / USD",
                marketIndex: 16,
                priceDecimals: 2,
                sizeDecimals: 4,
                // $366.6204, the live mainnet Chainlink print on 2026-09-09.
                seedPx18: 366.6204e18,
                // §5: "a real, considered number". TSLA's capacity at 10% depth is $90k — 18th of
                // the 57 markets, and its OI fell 24% in two days. This is the capacity the vault
                // is sized from, so `absoluteCap18` and the depth leg agree at deployment rather
                // than one being decorative.
                absoluteCap18: 90_000e18,
                // The attester's seed figure. $900k of OI * 1000 bps = the $90k capacity above.
                openInterest18: 900_000e18,
                // M-2: RETUNED, not the constructor's 100k/60k/30k defaults, which are meaningless
                // against a $90k book. Buffer is ~10% of capacity (1 - targetMarginBps); the
                // 100/60/30/0 RATIO is preserved. These gate nothing — a reporting choice, per §5 —
                // and `BufferBook.configure` requires them non-increasing.
                bufferFloor18: 9_000e18,
                bufferFeeOn18: 5_400e18,
                bufferMintSlow18: 2_700e18
            })
        );

        // uSPY SECOND: market 26. NOT NVDA — SPY has a real Chainlink mainnet feed (so
        // `singleSource == false` is honest for it) and 55x TSLA's capacity: $5.00M against $90k,
        // the highest of all 57 markets at 10% depth.
        assets.push(
            AssetParams({
                name: "UseCert SPY",
                symbol: "uSPY",
                feedDescription: "RHSPY / USD",
                marketIndex: 26,
                priceDecimals: 2,
                sizeDecimals: 4,
                seedPx18: 650e18,
                absoluteCap18: 5_000_000e18,
                // $50.0M of OI * 1000 bps = the $5.00M capacity.
                openInterest18: 50_000_000e18,
                bufferFloor18: 500_000e18,
                bufferFeeOn18: 300_000e18,
                bufferMintSlow18: 150_000e18
            })
        );
    }

    // ------------------------------------------------------------- injection seams, for tests
    //
    // The two inputs a test needs to vary, behind `virtual` functions so a test can override them
    // by SUBCLASSING rather than by mutating the process environment. That matters: `vm.setEnv`
    // writes process-global state that Foundry does not roll back between test cases, so tests
    // that each set a different `GOV_PK` interfere with one another and fail in whichever order
    // they happen to run. Production behaviour is unchanged — the defaults are the env reads.

    /// @dev The three senders. NEVER hardcode, log, or derive these from a mnemonic here; the
    ///      operator owns them and this script only ever asks the environment for them.
    function _senderKeys() internal view virtual returns (uint256 deployerPk, uint256 govPk, uint256 attesterPk) {
        return (vm.envUint("DEPLOYER_PK"), vm.envUint("GOV_PK"), vm.envUint("ATTESTER_PK"));
    }

    /// @dev Deploys the 6-decimal test collateral, from the deployer, who becomes `TestUSDG.owner`.
    ///      Behind a `virtual` seam for the same reason as the others here — a test that wants to
    ///      exercise the decimals guard in `_phase1_simulators()` overrides this to return a
    ///      differently-shaped token, BY SUBCLASSING, rather than there being an env var that could
    ///      point a real deployment at an untrusted token. Production behaviour is unchanged: this
    ///      is the only implementation that ever runs outside a test.
    function _deployCollateral() internal virtual returns (address) {
        return address(new TestUSDG(deployerAddr));
    }

    /// @dev The address Task 12's `BatchAdvancer` keeper signs with. Injected for the same reason as
    ///      `_collateralAddress()` — a test overrides it by SUBCLASSING rather than mutating the
    ///      process environment. Registered on `LighterSim` in phase 5 (Task 7's gate) and recorded
    ///      in the address book so the keeper process and the deployment agree on it.
    function _batchKeeperAddress() internal view virtual returns (address) {
        return vm.envOr("BATCH_KEEPER", address(0));
    }

    // ------------------------------------------------------------------------------------- run

    function run() external {
        if (block.chainid != _chainId()) revert DeployTestnet_WrongChain(block.chainid, _chainId());

        (uint256 deployerPk, uint256 govPk, uint256 attesterPk) = _senderKeys();

        deployerAddr = vm.addr(deployerPk);
        govAddr = vm.addr(govPk);
        attesterAddr = vm.addr(attesterPk);

        // SAFE MODE (ROADMAP 6.15). Governance is an existing multisig rather than an EOA key. It
        // cannot sign here, so the two governance phases change shape: the msg.sender-bound
        // contracts (registry, oracles) were already created BY THE SAFE through a delegatecall to
        // Safe's CreateCall and are adopted - and fully verified - rather than deployed; and
        // phase 4 is not broadcast at all, it is a Safe batch (script/SafeBatches.s.sol).
        address safeGov = _externalGovernance();
        if (safeGov != address(0)) govAddr = safeGov;

        // Three DISTINCT senders. Collapsing any two would silently defeat §4's separation: with
        // governance == deployer, "governance is a multisig" stops being true and the emergency
        // `setAbsoluteCap(vault, 0)` lever sits on the same key that ran the deployment.
        require(deployerAddr != govAddr, "SENDERS: deployer == governance");
        require(deployerAddr != attesterAddr, "SENDERS: deployer == attester");
        require(govAddr != attesterAddr, "SENDERS: governance == attester");

        _loadAssets();

        // Task 7 gated `LighterSim.settleBatch` to `owner` or `keeper`. Registered in phase 5, by
        // the deployer (who is also the simulator's owner); loaded and validated here so a missing
        // key aborts before anything is broadcast, exactly like the collateral check above.
        batchKeeper = _batchKeeperAddress();
        // Required here because LighterSim gates settleBatch on owner-or-keeper. A real venue
        // advances its own batches and has no such role, so the requirement is overridable.
        if (_requiresBatchKeeper() && batchKeeper == address(0)) {
            revert DeployTestnet_MissingBatchKeeper();
        }

        // AND IT MUST BE A FOURTH KEY, checked the same way the three above are.
        //
        // Non-zero was the only check here, and `docs/TESTNET-RUNBOOK.md` §3 explains at length why
        // the batch keeper is a fourth key rather than the deployer's: it is a long-running process
        // on a box somewhere, while `DEPLOYER_PK` is the venue's IMMUTABLE owner — the allowlist,
        // the marks and the stuck-queue hatches all sit on it. With `BATCH_KEEPER == deployerAddr`
        // every check passed, the deployment read as clean, and the separation the runbook promises
        // quietly did not exist: a compromised keeper box would hold `setDepositorAllowed`,
        // `setMarkPrice` and `setKeeper`.
        //
        // Against governance and the attester too, for the same reason the three `require`s above
        // are pairwise rather than just "governance != deployer": a keeper box holding `GOV_PK`
        // owns `setAbsoluteCap`, and one holding `ATTESTER_PK` owns every published solvency
        // figure. `setKeeper` is rotatable from `DEPLOYER_PK` afterwards, so this costs an operator
        // nothing but a second address.
        require(batchKeeper != deployerAddr, "SENDERS: batchKeeper == deployer");
        require(batchKeeper != govAddr, "SENDERS: batchKeeper == governance");
        require(batchKeeper != attesterAddr, "SENDERS: batchKeeper == attester");

        // ------------------------------------------------------------------- phase 1: deployer
        vm.startBroadcast(deployerPk);
        _phase1_simulators();
        vm.stopBroadcast();

        // ----------------------------------------------------------------- phase 2: GOVERNANCE
        //
        // §4, AND THE MOST IMPORTANT TEN LINES IN THIS FILE.
        //
        // `SolvencyRegistry` and `CertOracle` both do `governance = msg.sender` in their
        // constructors and the field is IMMUTABLE. Under `vm.startBroadcast(govPk)` a `new X()`
        // written HERE — in `run()`'s own frame, at depth 1 — is sent as a bare CREATE from the
        // governance EOA, so `msg.sender` inside the constructor is `govAddr`.
        //
        // MOVE THESE INTO A HELPER CONTRACT AND THE DEPLOYMENT IS PERMANENTLY BROKEN: `msg.sender`
        // becomes the helper's address, governance lands somewhere nobody controls, attester
        // rotation is unreachable forever, and the only remedy is a full redeployment. Same for a
        // CREATE2 factory. They stay written out inline, in this frame, on purpose — an internal
        // function would in fact keep the same frame, but writing them here removes the question.
        if (safeGov == address(0)) vm.startBroadcast(govPk);

        registry = safeGov == address(0) ? address(new SolvencyRegistry(attesterAddr)) : _externalRegistry();

        uint256 n = assets.length;
        for (uint256 i = 0; i < n; ++i) {
            deployed.push(
                AssetDeployment({
                    aggregator: address(0),
                    oracle: address(0),
                    vault: address(0),
                    certificate: address(0),
                    bufferBook: address(0)
                })
            );
        }
        // The aggregators were deployed in phase 1; the oracles that read them are governance's.
        for (uint256 i = 0; i < n; ++i) {
            deployed[i].aggregator = _aggregatorOf(i);
            deployed[i].oracle = safeGov != address(0)
                ? _externalOracle(i)
                : address(
                    new CertOracle(
                        _aggregatorOf(i),
                        attesterAddr,
                        assets[i].priceDecimals,
                        _stalenessSeconds(),
                        DEVIATION_BPS,
                        BASIS_BAND_BPS,
                        POKE_CONFIRMATION_SECONDS,
                        _singleSource()
                    )
                );
        }

        if (safeGov == address(0)) vm.stopBroadcast();

        // ------------------------------------------------------------------- phase 3: deployer
        vm.startBroadcast(deployerPk);
        _phase3_coreAndVaults();
        vm.stopBroadcast();

        // ----------------------------------------------------------------- phase 4: governance
        if (safeGov == address(0)) {
            vm.startBroadcast(govPk);
            _phase4_governance();
            vm.stopBroadcast();
        }

        // ------------------------------------------------- phase 5: deployer / venue operator
        vm.startBroadcast(deployerPk);
        _phase5_allowlistMarksAndBootstrap();
        vm.stopBroadcast();

        // ------------------------------------------------------------------- phase 6: attester
        vm.startBroadcast(attesterPk);
        _phase6_attest();
        vm.stopBroadcast();

        // ------------------------------------------------------------- verify, then write it down
        _verifyLocalSimulation();
        _writeAddressBook();
        _report();
    }

    // ------------------------------------------------------------------------------- phase 1

    /// @dev The simulators, from the deployer. Robinhood Chain testnet has NEITHER dependency:
    ///      Lighter is absent (both candidate `ZkLighter` addresses return `0x`) and Chainlink is
    ///      absent (six known mainnet proxies return `0x`), both verified live 2026-09-09. So the
    ///      deployment brings its own venue and its own aggregator.
    function _phase1_simulators() internal virtual {
        // TASK 8 INTEGRATION POINT, DELIVERED. `src/sim/TestUSDG.sol` and `src/sim/TestFaucet.sol`
        // are deployed HERE, from the deployer, who becomes both `TestUSDG.owner` and the address
        // that funds itself and the faucet. No env var is required or read for either.
        collateral = _deployCollateral();
        require(
            IERC20Metadata(collateral).decimals() == COLLATERAL_DECIMALS,
            "COLLATERAL: decimals() != 6 - CertVault fixes this immutably at construction"
        );

        testFaucet = address(new TestFaucet(IERC20(collateral), FAUCET_DRIP, FAUCET_INTERVAL));

        // With the token injected out of band an operator funded the deployer by hand before
        // running this script. That stops being true now that the script owns the token: without
        // these two mints, phase 5's `seedBuffer` calls revert on an ERC-20 balance the deployer
        // never received, and nothing explains why. `TestUSDG.mint` is owner-gated and the
        // deployer IS `TestUSDG.owner` (see `_deployCollateral`), so both calls are self-funding.
        //
        //   - the deployer's seed collateral: `SEED_COLLATERAL` is spent once per vault in phase 5
        //     (`seedBuffer` then `bootstrap`), so the deployer needs `assets.length` copies of it.
        //   - the faucet's opening float, so testers can `claim()` from block one.
        TestUSDG(collateral).mint(deployerAddr, _seedCollateral() * assets.length);
        TestUSDG(collateral).mint(testFaucet, FAUCET_OPENING_FLOAT);

        // The venue. `_owner` is the deployer, standing in for the venue operator: the allowlist,
        // the mark prices and the stuck-queue hatches are all `onlyOwner`. `settleBatch()` is gated
        // to `owner` or `keeper` too (Task 7, item 2) — a permissionless settler picks the block,
        // and therefore the mark, at which someone else's queued order fills. Phase 5 registers
        // Task 12's `BatchAdvancer` bot as `keeper` on this simulator.
        //
        // `sizeDecimals` is taken from the FIRST asset because it is a per-simulator field while
        // the venue has it per-market. Both C1 markets are `size_decimals 4` (verified live), so
        // this is exact today; the require makes a future mirror with a different value fail loudly
        // here rather than mis-quantise every hedge on one of the two vaults.
        for (uint256 i = 1; i < assets.length; ++i) {
            require(
                assets[i].sizeDecimals == assets[0].sizeDecimals,
                "SIM: one LighterSim cannot serve two different sizeDecimals - deploy a second sim"
            );
        }
        lighter = address(
            new LighterSim(
                IERC20(collateral),
                _collateralAssetIndex(),
                assets[0].sizeDecimals,
                SIM_REQUIRED_MARGIN_BPS,
                deployerAddr
            )
        );

        // One aggregator per asset. `ReplayAggregator` — NOT `MockAggregatorV3`, which is a test
        // mock and not deployable scaffolding. It writes round 1 in its own constructor so
        // `roundId` starts at a real value, and `roundId` STRICTLY INCREMENTS on every write, which
        // is load-bearing: §2 makes `pokeLastGood`'s round-distinctness proof `roundId >
        // pendingRoundId`, so a feed serving a constant `roundId` freezes H-1's reference
        // permanently and a large sustained repricing could never be absorbed.
        //
        // Owner is the DEPLOYER, not the attester, and that is the point: the attester writes
        // `markPx18`, so giving it the feed too would make the two "independent" sources one key
        // and `singleSource == false` a lie. `script/FeedKeeper.s.sol` must therefore be invoked
        // with DEPLOYER_PK.
        for (uint256 i = 0; i < assets.length; ++i) {
            address agg = address(
                new ReplayAggregator(
                    deployerAddr, FEED_DECIMALS, assets[i].feedDescription, _toFeedAnswer(assets[i].seedPx18)
                )
            );
            _pushAggregator(agg);
        }
    }

    // ------------------------------------------------------------------------------- phase 3

    /// @dev `CapacityOracle`, `CertFactory` and the vaults, from the deployer.
    ///
    ///      Neither of these binds governance to `msg.sender` — both take it as an explicit
    ///      parameter — so unlike phase 2 they are safe to deploy from the deployer, and §6 step 2
    ///      says to. `CertFactory` comes before the vaults only because `registerVault` has to
    ///      exist to be called; the vault holds NO reference to the factory and does not depend on
    ///      it at all.
    function _phase3_coreAndVaults() internal virtual {
        capacity = address(
            new CapacityOracle(
                registry, govAddr, DEPTH_BPS, MIN_DEPTH_BPS, MAX_DEPTH_BPS, MAX_ATTESTATION_AGE_SEC, MAX_ABSOLUTE_CAP_18
            )
        );

        factory = address(new CertFactory(lighter, registry, capacity, govAddr));

        for (uint256 i = 0; i < assets.length; ++i) {
            // §6 step 3: deployed DIRECTLY, never through `CertFactory.deployVault` — that reverts
            // `CertFactory_UseRegisterVault` by construction, because no contract can `new
            // CertVault` under EIP-170 (§0).
            //
            // The four `Deps` addresses MUST be the same four the factory holds. `registerVault`
            // does NOT check this for you and a mismatch is not repairable — every dependency on
            // both sides is immutable — so it is asserted in `_verifyLocalSimulation` and again
            // on-chain by `VerifyTestnet`.
            CertVault v = new CertVault(
                CertVault.Deps({
                    lighter: lighter,
                    oracle: deployed[i].oracle,
                    registry: registry,
                    capacity: capacity,
                    governance: govAddr
                }),
                CertVault.VaultConfig({
                    collateral: collateral,
                    collateralAssetIndex: _collateralAssetIndex(),
                    routeType: ROUTE_TYPE,
                    marketIndex: assets[i].marketIndex,
                    sizeDecimals: assets[i].sizeDecimals,
                    mintFeeBps: MINT_FEE_BPS,
                    redeemFeeBps: REDEEM_FEE_BPS,
                    instantCap18: INSTANT_CAP_18,
                    settleBandBps: SETTLE_BAND_BPS,
                    targetMarginBps: TARGET_MARGIN_BPS
                }),
                VENUE_WITHDRAW_CAP,
                SETTLE_WINDOW,
                assets[i].name,
                assets[i].symbol
            );
            deployed[i].vault = address(v);
            // The vault's constructor deployed both of these. Read them back — the certificate
            // address is needed for `registerVault`, which cross-checks it.
            deployed[i].certificate = address(v.certificate());
            deployed[i].bufferBook = address(v.buffer());
        }
    }

    // ------------------------------------------------------------------------------- phase 4

    /// @dev The governance phase, in §5's order.
    function _phase4_governance() internal virtual {
        for (uint256 i = 0; i < assets.length; ++i) {
            // §6 step 4. Records the vault in `vaults`/`isVault` and cross-checks the certificate.
            CertFactory(factory).registerVault(deployed[i].vault, deployed[i].certificate);

            // §6 step 5, AND THE SINGLE MOST LIKELY WAY THIS DEPLOYMENT APPEARS BROKEN.
            //
            // `absoluteCap18` is ZERO by default and `maxNotional18`'s `min()` makes zero mean
            // "NO CAPACITY" — not "unbounded". There is deliberately no first-call exception for a
            // stranger to bootstrap it (that would let anyone front-run the one number holding a
            // compromised attester in check). So a vault that reads as perfectly deployed —
            // registered, bootstrapped, attested, `mintAllowed() == true` — still reverts
            // `CertVault_AtCapacity` on every mint until this line runs. It is read back below.
            CapacityOracle(capacity).setAbsoluteCap(deployed[i].vault, assets[i].absoluteCap18);

            // M-2: retune the published buffer ladder off the asset's real book size. The
            // constructor's 100k/60k/30k/0 defaults are the same for every asset regardless of
            // size. They gate nothing (§5: a reporting choice, not a safety one).
            CertVault(deployed[i].vault).setBufferThresholds(
                assets[i].bufferFloor18, assets[i].bufferFeeOn18, assets[i].bufferMintSlow18, 0
            );
        }
    }

    // ------------------------------------------------------------------------------- phase 5

    /// @dev Allowlist, venue marks, collateral, bootstrap, batch advance — from the deployer,
    ///      which is also the simulator's owner.
    function _phase5_allowlistMarksAndBootstrap() internal virtual {
        for (uint256 i = 0; i < assets.length; ++i) {
            // ============================== PLAN STEP 3a — DO NOT REMOVE ==========================
            // `bootstrap()` REVERTS `LighterSim_DepositorNotAllowed(vault)` WITHOUT THIS LINE.
            //
            // Task 5's fix round added an owner-gated registration allowlist to `LighterSim` as the
            // interim that closes the self-registration drain (Critical 1: a zero-value
            // `transferFrom` succeeds with no allowance and no balance, so registration used to be
            // free rather than merely open; and Critical 2's entry condition, since an attacker
            // needs an account to queue the poison order that blocks settlement for everyone).
            //
            // It FAILS CLOSED, which is right. But it is a deployment step that exists in no
            // earlier document — `docs/DEPLOYMENT-CHECKLIST.md` was off-limits to the task that
            // introduced it — and without it the deployment stops at §6 step 7 with an error
            // nothing explains. The checklist row was added by this task; the line is here.
            //
            // SIMULATOR-ONLY. It has no counterpart on the real venue, which registers anyone, and
            // must never be read as modelling one. Task 7 supersedes it with per-account collateral
            // isolation, at which point this line and the mapping both go.
            // =====================================================================================
            LighterSim(lighter).setDepositorAllowed(deployed[i].vault, true);

            // The VENUE's own mark, distinct from `CertOracle.markPx18`. `LighterSim.settleBatch`
            // refuses outright to settle a market whose mark is unset, and that guard exists
            // because at a zero mark the simulator is not merely missing a margin check — the
            // whole mark-to-market layer is DEAD: notional is `|position| * 0` so the
            // `InsufficientMargin` gate passes vacuously at any size, and `entryPrice = 0` makes
            // `unrealisedPnl()` permanently zero. A deploy script that forgot this would look
            // completely clean while certifying the vault against a venue with no margin
            // requirement and no PnL — which is precisely the epistemic state that hid a Critical
            // in this project's external audit.
            LighterSim(lighter).setMarkPrice(assets[i].marketIndex, assets[i].seedPx18);

            // §6 step 6: collateral IN BEFORE `bootstrap()`. `bootstrap()` deposits exactly
            // `10 ** collateralDecimals` as registering dust and reverts without it. `seedBuffer`
            // is the permissionless way in and also lifts `bufferCapacity18()` off zero, which is
            // one of the three legs of `maxNotional18`'s `min()`.
            IERC20(collateral).approve(deployed[i].vault, _seedCollateral());
            CertVault(deployed[i].vault).seedBuffer(_seedCollateral());

            // §6 step 7. One-time, permissionless.
            CertVault(deployed[i].vault).bootstrap();
        }

        // ============================== PLAN STEP 3b — DO NOT REMOVE =============================
        // TASK 7 INTEGRATION POINT. `settleBatch()` is gated to `owner` or `keeper` (Task 7, item
        // 2): a permissionless settler picks the block, and therefore the mark, someone else's
        // queued order fills at. Sent by the DEPLOYER, who is also `LighterSim.owner` (see
        // `_phase1_simulators`), so this call needs no keeper registration to succeed itself — but
        // without it, Task 12's `BatchAdvancer` keeper has no address on file and reverts
        // `LighterSim_OnlyOwnerOrKeeper` the first time IT calls in, which reads identically to a
        // dead keeper. Read back in `_verifyAssetGate` and recorded in the address book.
        // =====================================================================================
        LighterSim(lighter).setKeeper(batchKeeper);

        // §6 step 8 / plan step 3: THE BATCH ADVANCE, and it is MANDATORY.
        //
        // `createOrder` reverts `AccountIsNotRegistered` until `addressToAccountIndex[vault]` is
        // populated, so every mint reverts as one atomic transaction until the registering deposit
        // has been EXECUTED by a batch. Called UNCONDITIONALLY and deliberately not conditioned on
        // whether the simulator's registration path is synchronous or asynchronous today: it is
        // harmless on an empty queue, and the alternative couples this script to a venue detail
        // that is expected to change.
        //
        // TO BE PRECISE ABOUT WHAT IS AND IS NOT IN THE TREE, because the earlier wording here
        // claimed otherwise: **`LighterCore.deposit` still assigns `addressToAccountIndex` inline**,
        // so registration is SYNCHRONOUS as shipped and `bootstrap()` alone already populates the
        // index. The asynchronous-registration change (planned as Task 6) is not in this tree. This
        // call is therefore forward-compatible rather than currently load-bearing — which is the
        // right shape, and is why it stays.
        //
        // AND THE §9 READ-BACK DOES NOT PROVE THE ORDERING IT LOOKS LIKE IT PROVES.
        // `_verifyAssetGate`'s `require(v.lighterAccountIndex() != 0)` passes whether or not this
        // `settleBatch()` ran, because the inline assignment already satisfied it. So neither that
        // read-back nor the suite establishes "the batch advance is what registered the vault"
        // today. Stated rather than repaired: when registration does become asynchronous the
        // read-back becomes exactly the proof it reads as, and weakening it now to chase the
        // present behaviour would have to be undone.
        //
        // Task 12's `BatchAdvancer` keeper calls exactly this on an interval, signing with the
        // `batchKeeper` address registered just above, and on mainnet Lighter advances its own
        // batches.
        LighterSim(lighter).settleBatch();
    }

    // ------------------------------------------------------------------------------- phase 6

    /// @dev §6 step 9. Attest once and set the mark so `maxNotional18` and `mintAllowed()` are
    ///      live. Nothing else in the deployment is sent by this key.
    function _phase6_attest() internal virtual {
        for (uint256 i = 0; i < assets.length; ++i) {
            // `asset` is keyed by the VAULT address, not the certificate and not the market index.
            // `batchId` must strictly increase (`SolvencyRegistry_StaleBatch`), so the deployment
            // seeds 1 and Task 12's keeper continues from there.
            //
            // `notional18` and `margin18` are 0 because the vault has no position yet — it has
            // minted nothing. `_requireCapacity` takes `max(own18, attested18)`, so a non-zero
            // seed here would fabricate exposure that does not exist and eat real capacity.
            SolvencyRegistry(registry).attest(deployed[i].vault, 1, 0, 0, assets[i].openInterest18);

            // `CertOracle.markPx18`: the venue-side price the basis band is measured against. Seeded
            // equal to the feed, so the basis is 0 bps at deployment and well inside the 500 bps
            // band. It has NO timestamp and NO staleness check anywhere (§2) — its liveness is an
            // operational assumption on the attester keeper's cadence, not a contract guarantee.
            CertOracle(deployed[i].oracle).setMarkPrice(assets[i].seedPx18);
        }
    }

    // ------------------------------------------------------------- §9, against the simulation

    /// @dev EVERY §9 ITEM, AS A `require` WITH A NAMED MESSAGE, so a bad deployment aborts before
    ///      broadcasting rather than half-completing a set of immutables.
    ///
    ///      READ THE CONTRACT NATSPEC ON WHAT THIS DOES NOT PROVE. `forge script --broadcast`
    ///      simulates the whole run and only then sends transactions, so these assert the LOCAL
    ///      SIMULATION. They are an abort gate, not §9. `script/VerifyTestnet.s.sol` (Task 11) is
    ///      what discharges §9 against the live chain.
    function _verifyLocalSimulation() internal view {
        // ---- §4 / §9: governance and attester binding on the two msg.sender-bound contracts
        require(SolvencyRegistry(registry).governance() == govAddr, "S9: registry.governance != GOV");
        require(SolvencyRegistry(registry).attester() == attesterAddr, "S9: registry.attester != ATTESTER");
        require(SolvencyRegistry(registry).pendingAttester() == address(0), "S9: registry.pendingAttester != 0");
        require(SolvencyRegistry(registry).ATTESTER_ROTATION_DELAY() == 2 days, "S9: registry rotation delay != 2d");

        // ---- §5 / §9: the capacity oracle's immutable ceiling and its governance
        require(CapacityOracle(capacity).governance() == govAddr, "S9: capacity.governance != GOV");
        require(CapacityOracle(capacity).maxAbsoluteCap() == MAX_ABSOLUTE_CAP_18, "S9: capacity.maxAbsoluteCap wrong");
        require(CapacityOracle(capacity).maxAbsoluteCap() != type(uint256).max, "S9: maxAbsoluteCap is unbounded");
        require(CapacityOracle(capacity).depthBps() == DEPTH_BPS, "S9: capacity.depthBps wrong");
        require(CapacityOracle(capacity).minDepthBps() == MIN_DEPTH_BPS, "S9: capacity.minDepthBps wrong");
        require(CapacityOracle(capacity).maxDepthBps() == MAX_DEPTH_BPS, "S9: capacity.maxDepthBps wrong");
        require(
            CapacityOracle(capacity).maxAttestationAgeSec() == MAX_ATTESTATION_AGE_SEC,
            "S9: capacity.maxAttestationAgeSec wrong"
        );

        // ---- §9: the factory's own four immutables, which the vaults must match
        require(CertFactory(factory).lighter() == lighter, "S9: factory.lighter wrong");
        require(CertFactory(factory).registry() == registry, "S9: factory.registry wrong");
        require(CertFactory(factory).capacity() == capacity, "S9: factory.capacity wrong");
        require(CertFactory(factory).governance() == govAddr, "S9: factory.governance != GOV");
        if (_phase4Applied()) {
            require(CertFactory(factory).vaultCount() == assets.length, "S9: factory.vaultCount != vaults deployed");
        }

        // ---- §1: the collateral decimals, immutably baked into every vault
        require(IERC20Metadata(collateral).decimals() == COLLATERAL_DECIMALS, "S9: collateral decimals != 6");
        _verifyCollateralAndFaucet();

        for (uint256 i = 0; i < assets.length; ++i) {
            _verifyAsset(i);
        }
    }

    /// @dev The part of §9 that is about THIS deployment's collateral rather than about the
    ///      protocol, split out because it is the only part a real-collateral chain cannot
    ///      satisfy: mainnet USDG is owned by its issuer and there is no faucet to check.
    ///
    ///      Kept as assertions rather than deleted. `TestUSDG` being deployer-owned is what lets
    ///      this script mint its own seed, and a faucet pointed at a different token would hand
    ///      testers collateral no vault here accepts - both are worth failing the run over.
    /// @dev The venue-shaped half of §9, split out because NONE of it survives a change of
    ///      venue. `LighterSim` is a contract this repository deploys; the mainnet venue is
    ///      Lighter's own proxy, which has no `depositorAllowed`, no `requiredMarginBps`, no
    ///      `owner()` we control and no `keeper()` - calling them would revert rather than fail
    ///      an assertion, which is a worse way to find out.
    ///
    ///      Split rather than weakened: every assertion below is unchanged and still runs on the
    ///      chain it was written for.
    function _verifyVenueWiring(uint256 i) internal view virtual {
        AssetParams memory a = assets[i];
        AssetDeployment memory d = deployed[i];
        CertVault v = CertVault(d.vault);

        // ---- §9: the registering deposit has EXECUTED (this is what the batch advance buys)
        require(v.bootstrapped(), "S9: vault not bootstrapped");
        require(v.lighterAccountIndex() != 0, "S9: lighterAccountIndex == 0 - registering deposit not executed");

        // ---- plan step 3a: the allowlist row, read back
        require(LighterSim(lighter).depositorAllowed(d.vault), "S9: depositorAllowed(vault) false");

        // ---- §5 / Global Constraint 5: the simulator is not easier than the venue
        require(
            LighterSim(lighter).requiredMarginBps() >= LighterSim(lighter).VENUE_IMF_BPS(),
            "S9: sim margin below the venue floor"
        );
        require(LighterSim(lighter).markPrice(a.marketIndex) != 0, "S9: venue mark unset - settleBatch would revert");
        require(LighterSim(lighter).owner() == deployerAddr, "S9: sim owner != DEPLOYER");

        // ---- Task 7 / Task 10: the keeper registered above is the one on file. A mismatch here is
        //      the exact failure mode integration missed: every settleBatch from that bot's key
        //      reverts LighterSim_OnlyOwnerOrKeeper, indistinguishable from a dead keeper.
        require(
            LighterSim(lighter).keeper() == batchKeeper,
            "S9: sim keeper != BATCH_KEEPER - settleBatch will revert for that key"
        );
    }

    /// @dev Does THIS script perform `bootstrap()` itself?
    ///
    ///      True here: the testnet venue is `LighterSim`, a contract this repository deploys and
    ///      foundry can execute. False on mainnet, where the venue's deposit delegates to an
    ///      Arbitrum Stylus (WASM) contract that foundry's EVM cannot run at all - so bootstrap
    ///      is a direct transaction sent afterwards, and the assertions that depend on it belong
    ///      to that step rather than to this one.
    function _bootstrapsInScript() internal view virtual returns (bool) {
        return true;
    }

    function _verifyCollateralAndFaucet() internal view virtual {
        require(TestUSDG(collateral).owner() == deployerAddr, "S9: collateral.owner != DEPLOYER");

        // ---- Task 10: the faucet points at the token this deployment actually minted, and holds
        //      the float this run put into it. A faucet not holding its float would fail every
        //      claim from block one.
        require(address(TestFaucet(testFaucet).token()) == collateral, "S9: faucet.token != collateral");
        require(IERC20(collateral).balanceOf(testFaucet) == FAUCET_OPENING_FLOAT, "S9: faucet float wrong");
    }

    /// @dev Split into four, and the split is forced rather than stylistic: `foundry.toml` sets
    ///      `via_ir = false` and must not be changed (Global Constraint 1), so the legacy codegen's
    ///      stack limit binds. `vault.cfg()`'s ten-field destructuring alone nearly exhausts it, and
    ///      one flat function here failed to compile with "Stack too deep".
    function _verifyAsset(uint256 i) internal view {
        _verifyAssetOracle(i);
        _verifyAssetDeps(i);
        _verifyAssetConfig(i);
        _verifyAssetGate(i);
    }

    function _verifyAssetOracle(uint256 i) internal view {
        AssetParams memory a = assets[i];
        AssetDeployment memory d = deployed[i];
        CertOracle o = CertOracle(d.oracle);

        // ---- §4 / §9: the oracle's governance binding. THE ITEM WITH NO REMEDY BUT REDEPLOYMENT.
        require(o.governance() == govAddr, "S9: oracle.governance != GOV");
        require(o.attester() == attesterAddr, "S9: oracle.attester != ATTESTER");
        require(o.pendingAttester() == address(0), "S9: oracle.pendingAttester != 0");
        require(o.ATTESTER_ROTATION_DELAY() == 2 days, "S9: oracle rotation delay != 2d");
        require(
            o.ATTESTER_ROTATION_DELAY() == SolvencyRegistry(registry).ATTESTER_ROTATION_DELAY(),
            "S9: oracle/registry rotation delays differ"
        );

        // ---- §2: the oracle's configuration, and the two values that must never be wrong
        require(address(o.feed()) == d.aggregator, "S9: oracle.feed != aggregator");
        require(o.singleSource() == _singleSource(), "S9: oracle.singleSource != declared mode");
        require(o.deviationBps() == DEVIATION_BPS, "S9: oracle.deviationBps wrong");
        require(o.deviationBps() != 0, "S9: deviationBps == 0 locks minting shut on the first tick");
        require(o.stalenessSeconds() == _stalenessSeconds(), "S9: oracle.stalenessSeconds wrong");
        require(o.pokeConfirmationSeconds() == POKE_CONFIRMATION_SECONDS, "S9: pokeConfirmationSeconds wrong");
        require(o.pokeConfirmationSeconds() != 0, "S9: pokeConfirmationSeconds == 0");
        require(o.basisBandBps() == BASIS_BAND_BPS, "S9: oracle.basisBandBps wrong");
        require(o.priceDecimals() == a.priceDecimals, "S9: oracle.priceDecimals != venue price_decimals");
        require(o.lastGoodPx18() != 0, "S9: oracle.lastGoodPx18 == 0, mintAllowed fails closed");

        // ---- §9: `absoluteCap18(vault)` is set. Zero means NO CAPACITY, not unbounded.
        //      The `!= 0` assertion comes FIRST deliberately: it is the failure that actually
        //      happens (governance forgot `setAbsoluteCap`), and "UNSET - cannot mint" tells the
        //      operator what to do, where the generic "wrong" would send them looking for a typo.
        if (_phase4Applied()) {
            require(CapacityOracle(capacity).absoluteCap18(d.vault) != 0, "S9: absoluteCap18(vault) UNSET - cannot mint");
            require(CapacityOracle(capacity).absoluteCap18(d.vault) == a.absoluteCap18, "S9: absoluteCap18(vault) wrong");
        }
    }

    // ------------------------------------------------------- accessors, for tests and Task 11

    /// @dev Read-only views over what the run deployed. `VerifyTestnet` reads the address book
    ///      rather than these, but a test that runs this script in-process needs them.
    function assetCount() external view returns (uint256) {
        return assets.length;
    }

    function deploymentOf(uint256 i) external view returns (AssetDeployment memory) {
        return deployed[i];
    }

    function paramsOf(uint256 i) external view returns (AssetParams memory) {
        return assets[i];
    }

    function sharedAddresses()
        external
        view
        returns (address collateral_, address faucet_, address lighter_, address registry_, address capacity_, address factory_)
    {
        return (collateral, testFaucet, lighter, registry, capacity, factory);
    }

    function _verifyAssetDeps(uint256 i) internal view {
        AssetParams memory a = assets[i];
        AssetDeployment memory d = deployed[i];
        CertVault v = CertVault(d.vault);

        // ---- §9: the vault's five immutable dependencies
        require(v.governance() == govAddr, "S9: vault.governance != GOV");
        require(address(v.lighter()) == lighter, "S9: vault.lighter wrong");
        require(address(v.oracle()) == d.oracle, "S9: vault.oracle wrong");
        require(address(v.registry()) == registry, "S9: vault.registry wrong");
        require(address(v.capacity()) == capacity, "S9: vault.capacity wrong");

        // ---- §9: THE ONE `registerVault` DOES NOT CHECK. The old `deployVault` wired these four
        //      from the factory's own immutables and guaranteed the match structurally; the
        //      deployment script does it now, and a mismatch is a redeployment.
        require(address(v.lighter()) == CertFactory(factory).lighter(), "S9: vault.lighter != factory.lighter");
        require(address(v.registry()) == CertFactory(factory).registry(), "S9: vault.registry != factory.registry");
        require(address(v.capacity()) == CertFactory(factory).capacity(), "S9: vault.capacity != factory.capacity");
        require(v.governance() == CertFactory(factory).governance(), "S9: vault.governance != factory.governance");

        // ---- §9: registration, and exactly one slot
        if (_phase4Applied()) {
            require(CertFactory(factory).isVault(d.vault), "S9: factory.isVault(vault) false");
            require(CertFactory(factory).vaults(i) == d.vault, "S9: factory.vaults(i) != vault");
        }
        require(!CertFactory(factory).enabled(d.vault), "S9: vault enabled - L-1 says do not, it is cosmetic");

        // ---- §9: the certificate cross-check (`registerVault` enforced it; this is the read-back)
        require(address(v.certificate()) == d.certificate, "S9: vault.certificate != recorded certificate");
        require(Certificate(d.certificate).vault() == d.vault, "S9: certificate.vault != vault");
        require(
            keccak256(bytes(Certificate(d.certificate).symbol())) == keccak256(bytes(a.symbol)),
            "S9: certificate symbol wrong"
        );
    }

    /// @dev §9 / §3: the vault config against the venue's own market config. Split across two
    ///      functions, each destructuring only the half of `cfg()`'s ten-field tuple it asserts on
    ///      (the rest elided with bare commas) — one flat read of all ten plus the comparison
    ///      operands exceeds the legacy codegen's stack, and `via_ir` is not available to us.
    function _verifyAssetConfig(uint256 i) internal view {
        _verifyAssetConfigVenue(i);
        _verifyAssetConfigEconomics(i);
    }

    /// @dev The venue-shaped half: these must match Lighter's own per-market config exactly, and
    ///      `sizeDecimals` in particular decides every hedge quantisation.
    function _verifyAssetConfigVenue(uint256 i) internal view {
        (address cCollateral, uint16 cAssetIdx, uint8 cRouteType, uint16 cMarketIndex, uint8 cSizeDecimals,,,,,) =
            CertVault(deployed[i].vault).cfg();
        require(cCollateral == collateral, "S9: cfg.collateral wrong");
        require(cAssetIdx == _collateralAssetIndex(), "S9: cfg.collateralAssetIndex wrong");
        require(cRouteType == ROUTE_TYPE, "S9: cfg.routeType wrong");
        require(cMarketIndex == assets[i].marketIndex, "S9: cfg.marketIndex != venue market_id");
        require(cSizeDecimals == assets[i].sizeDecimals, "S9: cfg.sizeDecimals != venue size_decimals");
    }

    /// @dev The economics half.
    function _verifyAssetConfigEconomics(uint256 i) internal view {
        (,,,,, uint256 cMintFee, uint256 cRedeemFee, uint256 cInstantCap, uint256 cBand, uint256 cMargin) =
            CertVault(deployed[i].vault).cfg();
        require(cMintFee == MINT_FEE_BPS, "S9: cfg.mintFeeBps wrong");
        require(cRedeemFee == REDEEM_FEE_BPS, "S9: cfg.redeemFeeBps wrong");
        // A fee above 100% underflows `gross18 - fee18` inside forceExit for EVERY holder: a
        // reachable Law 2 breach, bounded at construction since Finding 1. Asserted anyway.
        require(cRedeemFee <= 10_000, "S9: redeemFeeBps > 100pct - Law 2 breach in forceExit");
        require(cInstantCap == INSTANT_CAP_18, "S9: cfg.instantCap18 wrong");
        require(cBand == SETTLE_BAND_BPS, "S9: cfg.settleBandBps wrong");
        // NEVER RELAXED.
        require(cMargin == TARGET_MARGIN_BPS, "S9: cfg.targetMarginBps != 9000 - NEVER RELAX THIS");
    }

    function _verifyAssetGate(uint256 i) internal view {
        AssetParams memory a = assets[i];
        AssetDeployment memory d = deployed[i];
        CertVault v = CertVault(d.vault);
        CertOracle o = CertOracle(d.oracle);

        // ---- §9: the venue withdraw cap fits the venue's own uint64 parameter
        require(v.venueWithdrawCap() == VENUE_WITHDRAW_CAP, "S9: venueWithdrawCap wrong");
        require(v.venueWithdrawCap() <= type(uint64).max, "S9: venueWithdrawCap > uint64 max");
        require(v.settleWindow() == SETTLE_WINDOW, "S9: vault.settleWindow wrong");

        // ---- everything that is true of THIS venue rather than of the protocol
        _verifyVenueWiring(i);

        // ---- §9: the live price is inside the uint32 tick domain at the configured priceDecimals
        require(o.toTickPrice(o.px()) != 0, "S9: toTickPrice(px) == 0");

        // ---- the attestation is live and the mint gate is ACTUALLY OPEN
        require(SolvencyRegistry(registry).ageSec(d.vault) <= MAX_ATTESTATION_AGE_SEC, "S9: attestation already stale");
        require(SolvencyRegistry(registry).latest(d.vault).openInterest18 != 0, "S9: attested openInterest18 == 0");
        require(o.markPx18() != 0, "S9: oracle.markPx18 == 0 - basis band fails closed at false");
        (bool basisKnown, uint256 basisBps) = o.basisBpsChecked();
        require(basisKnown, "S9: basis unknown in dual-source mode");
        require(basisBps <= BASIS_BAND_BPS, "S9: basis outside the band at deployment");
        require(o.mintAllowed(), "S9: MINT GATE CLOSED - oracle.mintAllowed() is false");
        // In Safe mode the cap is set by the Safe's phase-4 batch, after this deploy.
        if (_phase4Applied()) {
            require(
                CapacityOracle(capacity).maxNotional18(d.vault, v.bufferCapacity18()) != 0,
                "S9: MINT GATE CLOSED - maxNotional18 == 0"
            );
        }
    }

    // ------------------------------------------------------------------------ the address book

    /// @dev `deployments/46630.json`, written per deployment and NEVER HAND-EDITED.
    ///
    ///      Each new mirror is a new vault AND a new `Certificate` token. A hand-edited map would
    ///      silently repoint a UI at a new token while real balances sat in the old one — the
    ///      holder's certificates would simply stop being visible, with nothing on-chain wrong.
    ///      Re-run the script to regenerate; `script/VerifyTestnet.s.sol` reads this file and
    ///      re-asserts §9 against the live chain from it.
    /// @dev Assembled row by row through the three `_j*` helpers below rather than in a few large
    ///      `string.concat` calls. Not a style choice: a wide `string.concat` blows the legacy
    ///      codegen's stack ("Stack too deep" in the generated assembly) and `via_ir` is off and
    ///      must stay off (Global Constraint 1).
    /// @dev The address-book key for the venue. Testnet's venue is `LighterSim`; mainnet overrides.
    function _venueBookKey() internal pure virtual returns (string memory) {
        return "lighterSim";
    }

    function _writeAddressBook() internal {
        string memory out = "{\n";
        out = string.concat(out, _jStr("  ", "_generatedBy", "script/DeployTestnet.s.sol"));
        out = string.concat(
            out,
            _jStr(
                "  ",
                "_warning",
                "GENERATED PER DEPLOYMENT. NEVER HAND-EDIT: each mirror is a new vault AND a new certificate token, and an edited map repoints a UI at a new token while balances sit in the old one. Re-run the script."
            )
        );
        out = string.concat(out, _jNum("  ", "chainId", block.chainid));
        out = string.concat(out, _jNum("  ", "blockNumber", block.number));
        out = string.concat(out, _jNum("  ", "timestamp", block.timestamp));
        out = string.concat(out, _jStr("  ", "commit", _commit()));

        out = string.concat(out, '  "senders": {\n');
        out = string.concat(out, _jAddr("    ", "deployer", deployerAddr));
        out = string.concat(out, _jAddr("    ", "governance", govAddr));
        out = string.concat(out, _jAddr("    ", "attester", attesterAddr));
        out = string.concat(out, "    \"_note\": \"governance deployed SolvencyRegistry and every CertOracle itself (checklist S4); those bindings are immutable\"\n  },\n");

        out = string.concat(out, '  "shared": {\n');
        out = string.concat(out, _jAddr("    ", "collateral", collateral));
        out = string.concat(out, _jNum("    ", "collateralDecimals", COLLATERAL_DECIMALS));
        // Only where a faucet exists. On mainnet there is none, and a zero-address row reads
        // to the front end as a faucet that is there (ROADMAP 6.5).
        if (testFaucet != address(0)) {
            out = string.concat(out, _jAddr("    ", "testFaucet", testFaucet));
            out = string.concat(
                out,
                _jStr(
                    "    ",
                    "_testFaucetNote",
                    "Deployed by this script alongside the collateral token (Task 10). Holds an opening float the deployer minted; has no owner and no sweep, so its balance plus its Dripped event stream is a closed account - see TestFaucet's NatSpec"
                )
            );
            out = string.concat(out, _jNum("    ", "faucetDripAmount", FAUCET_DRIP));
            out = string.concat(out, _jNum("    ", "faucetIntervalSeconds", FAUCET_INTERVAL));
            out = string.concat(out, _jNum("    ", "faucetOpeningFloat", FAUCET_OPENING_FLOAT));
        }
        // The key says what the venue IS: `lighterSim` on testnet, `lighter` on mainnet, where
        // it is the real exchange. The front end reads the key's presence as "simulated".
        out = string.concat(out, _jAddr("    ", _venueBookKey(), lighter));
        out = string.concat(out, _jAddr("    ", "solvencyRegistry", registry));
        out = string.concat(out, _jAddr("    ", "capacityOracle", capacity));
        if (batchKeeper != address(0)) {
            out = string.concat(out, _jAddr("    ", "batchKeeper", batchKeeper));
            out = string.concat(
                out,
                _jStr(
                    "    ",
                    "_batchKeeperNote",
                    "Task 12's BatchAdvancer keeper must sign with this exact address, registered via LighterSim.setKeeper - otherwise every settleBatch reverts LighterSim_OnlyOwnerOrKeeper, indistinguishable from a dead keeper"
                )
            );
        }
        out = string.concat(out, _jAddrLast("    ", "certFactory", factory));
        out = string.concat(out, "  },\n");

        out = string.concat(out, '  "parameters": {\n');
        out = string.concat(out, _parametersJson());
        out = string.concat(out, "\n  },\n");

        out = string.concat(out, '  "vaults": [\n');
        for (uint256 i = 0; i < assets.length; ++i) {
            out = string.concat(out, _assetJson(i));
            out = string.concat(out, i + 1 == assets.length ? "\n" : ",\n");
        }
        out = string.concat(out, "  ]\n}\n");

        vm.writeFile(string.concat("deployments/", vm.toString(block.chainid), ".json"), out);
    }

    function _jStr(string memory pad, string memory k, string memory v) internal pure returns (string memory) {
        return string.concat(pad, '"', k, '": "', v, '",\n');
    }

    function _jNum(string memory pad, string memory k, uint256 v) internal pure returns (string memory) {
        return string.concat(pad, '"', k, '": ', vm.toString(v), ",\n");
    }

    function _jAddr(string memory pad, string memory k, address v) internal pure returns (string memory) {
        return _jStr(pad, k, vm.toString(v));
    }

    function _jAddrLast(string memory pad, string memory k, address v) internal pure returns (string memory) {
        return string.concat(pad, '"', k, '": "', vm.toString(v), '"\n');
    }

    function _parametersJson() internal pure returns (string memory) {
        return string.concat(
            '    "targetMarginBps": 9000,\n',
            '    "instantCap18": "1000000000000000000000",\n',
            '    "settleWindow": 86400,\n',
            '    "settleBandBps": 500,\n',
            '    "mintFeeBps": 10,\n',
            '    "redeemFeeBps": 10,\n',
            '    "stalenessSeconds": 900,\n',
            '    "_stalenessSecondsNote": "TESTNET REACHABILITY VALUE. Mainnet is 93600 (TESTNET-PLAN.md S1). Must not be carried over.",\n',
            '    "pokeConfirmationSeconds": 300,\n',
            '    "deviationBps": 500,\n',
            '    "basisBandBps": 500,\n',
            '    "singleSource": false,\n',
            '    "_singleSourceNote": "Declares feed and venue mark independent. On testnet that independence is ORGANISATIONAL (two keys), not economic - both keepers are operated by us. Not evidence about mainnet.",\n',
            '    "depthBps": 1000,\n',
            '    "minDepthBps": 100,\n',
            '    "maxDepthBps": 3000,\n',
            '    "maxAttestationAgeSec": 300,\n',
            '    "maxAbsoluteCap18": "1000000000000000000000000000",\n',
            '    "venueWithdrawCap": "18446744073709551615",\n',
            '    "simRequiredMarginBps": 5000,\n',
            '    "feedDecimals": 8'
        );
    }

    function _assetJson(uint256 i) internal view returns (string memory) {
        string memory out = "    {\n";
        out = string.concat(out, _jStr("      ", "symbol", assets[i].symbol));
        out = string.concat(out, _jStr("      ", "name", assets[i].name));
        out = string.concat(out, _jNum("      ", "marketIndex", assets[i].marketIndex));
        out = string.concat(out, _jNum("      ", "priceDecimals", assets[i].priceDecimals));
        out = string.concat(out, _jNum("      ", "sizeDecimals", assets[i].sizeDecimals));
        out = string.concat(out, _jAddr("      ", "vault", deployed[i].vault));
        out = string.concat(out, _jAddr("      ", "certificate", deployed[i].certificate));
        out = string.concat(out, _jAddr("      ", "bufferBook", deployed[i].bufferBook));
        out = string.concat(out, _jAddr("      ", "certOracle", deployed[i].oracle));
        out = string.concat(out, _jAddr("      ", "replayAggregator", deployed[i].aggregator));
        // Quoted strings, not JSON numbers: these exceed 2^53 and would lose precision in any
        // JavaScript consumer that parsed them as numbers. The front-end adapter reads this file.
        out = string.concat(out, _jStr("      ", "seedPrice18", vm.toString(assets[i].seedPx18)));
        out = string.concat(out, _jStr("      ", "absoluteCap18", vm.toString(assets[i].absoluteCap18)));
        out = string.concat(
            out, string.concat('      "seedOpenInterest18": "', vm.toString(assets[i].openInterest18), '"\n    }')
        );
        return out;
    }

    /// @dev The commit being deployed. §9's last item requires `forge build --sizes` to have been
    ///      run against THIS commit, so the commit has to be recorded for that claim to be
    ///      checkable later.
    ///
    ///      Taken from the `COMMIT` env var rather than shelled out with FFI: `ffi` is not enabled
    ///      in `foundry.toml` and enabling it would let any dependency in the compilation unit run
    ///      arbitrary commands during a run that handles three private keys. Not worth it for a
    ///      string. The deploy command in `docs/TESTNET-RUNBOOK.md` sets it:
    ///          COMMIT=$(git rev-parse HEAD) forge script ...
    ///      Falls back to a loud marker rather than reverting the deployment - EXCEPT on mainnet.
    ///      Stack 4 on 4663 went out with COMMIT unset and its book said UNKNOWN until it was
    ///      recorded by hand (ROADMAP 6.22). On 4663 an unset or malformed COMMIT now reverts.
    ///      The book is written during forge's simulation pass, before anything is broadcast,
    ///      so this refuses the whole run rather than stranding a deployed stack without a book.
    function _commit() internal view returns (string memory) {
        string memory c = vm.envOr("COMMIT", string(""));
        if (block.chainid == 4663) {
            bytes memory b = bytes(c);
            bool ok = b.length == 40;
            for (uint256 i = 0; ok && i < 40; i++) {
                bytes1 x = b[i];
                ok = (x >= "0" && x <= "9") || (x >= "a" && x <= "f");
            }
            require(ok, "COMMIT must be a 40-char lowercase hash on mainnet: COMMIT=$(git rev-parse HEAD)");
            return c;
        }
        return bytes(c).length == 0 ? "UNKNOWN - COMMIT env unset; record it by hand before publishing" : c;
    }

    // --------------------------------------------------------------------------------- helpers

    /// @dev `seedPx18` (18 decimals) into the aggregator's own `FEED_DECIMALS` (8). Division, so it
    ///      cannot overflow. The exponent is widened to `uint256` deliberately: left as `uint8`,
    ///      `10 ** (18 - FEED_DECIMALS)` is `10 ** 10` evaluated in `uint8` and overflows.
    function _toFeedAnswer(uint256 px18) internal pure returns (int256) {
        return int256(px18 / (10 ** (uint256(18) - uint256(FEED_DECIMALS))));
    }

    /// @dev Phase 1 runs before `deployed` is sized (the oracles are governance's and come later),
    ///      so the aggregators are parked in their own array and joined up by index.
    address[] internal aggregators;

    function _pushAggregator(address a) internal {
        aggregators.push(a);
    }

    function _aggregatorOf(uint256 i) internal view returns (address) {
        return aggregators[i];
    }

    function _report() internal view {
        console2.log("=== UseCert testnet deployment, chain", block.chainid, "===");
        console2.log("deployer       ", deployerAddr);
        console2.log("governance     ", govAddr);
        console2.log("attester       ", attesterAddr);
        console2.log("collateral     ", collateral);
        console2.log("testFaucet     ", testFaucet);
        console2.log("LighterSim     ", lighter);
        console2.log("SolvencyRegistry", registry);
        console2.log("CapacityOracle ", capacity);
        console2.log("batchKeeper    ", batchKeeper);
        console2.log("CertFactory    ", factory);
        for (uint256 i = 0; i < assets.length; ++i) {
            console2.log("---", assets[i].symbol, "market", assets[i].marketIndex);
            console2.log("  ReplayAggregator", deployed[i].aggregator);
            console2.log("  CertOracle      ", deployed[i].oracle);
            console2.log("  CertVault       ", deployed[i].vault);
            console2.log("  Certificate     ", deployed[i].certificate);
            console2.log("  BufferBook      ", deployed[i].bufferBook);
        }
        console2.log("address book -> deployments/%s.json", vm.toString(block.chainid));
        console2.log("NEXT: this script's requires are simulation-only, so verify on chain.");
        console2.log("      script/VerifyTestnet.s.sol is NOT in the tree yet - until it is, run");
        console2.log("      docs/TESTNET-RUNBOOK.md section 7.4's health check by hand instead.");
        console2.log("      Then start ALL THREE keepers, or minting stops in ~5 minutes.");
    }
}
