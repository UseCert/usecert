// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {DeployTestnet} from "./DeployTestnet.s.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {CertVault} from "../src/CertVault.sol";
import {CertOracle} from "../src/CertOracle.sol";
import {CapacityOracle} from "../src/CapacityOracle.sol";
import {CertFactory} from "../src/CertFactory.sol";
import {InsuranceStaking, IVaultRegistry} from "../src/InsuranceStaking.sol";
import {CertStaking} from "../src/CertStaking.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {BuybackForwarder, ICertStakingFunding} from "../src/BuybackForwarder.sol";

/// @notice Deploys UseCert to Robinhood Chain MAINNET (chain 4663).
///
/// @dev WHAT THIS IS, AND WHAT IT IS NOT.
///
///      It is `DeployTestnet` with the six answers that differ on mainnet, and nothing else.
///      Every phase, every ordering constraint, every post-deploy assertion is inherited
///      unchanged — deliberately. A parallel mainnet script would drift from the testnet one
///      silently, and the testnet one is the only version any test has ever exercised.
///
///      It is NOT a licence to deploy. Running this needs answers that are not in this file and
///      cannot be guessed: see `_collateralAssetIndex` and `_singleSource` below, both of which
///      revert rather than return a plausible number. `deploy/mainnet/SWITCHING.md` lists what
///      else must be true first, of which the important one is that `LighterCore` is this
///      project's MODEL of the venue's behaviour and has never met the real engine.
///
///      THE THREE THINGS THAT ARE NOT DEPLOYED HERE, and must not be:
///
///        * `TestUSDG` — the collateral is real USDG at the address below. `_deployCollateral`
///          returns it rather than constructing anything.
///        * `TestFaucet` — a faucet on mainnet is a mint of free money. `_phase1_simulators` is
///          overridden to skip it.
///        * `LighterSim` — the venue is Lighter's real `ZkLighter` proxy. The simulator exists
///          only because Lighter is absent on testnet.
///
///      Addresses and market data measured 2026-09-25 and recorded, with provenance, in
///      `deployments/history/4663.0-plan-before-deploy.json` (moved there once deployed: its market
///      indices predate ROADMAP 6.8). They are literals here for the same reason every other
///      parameter in the parent is a literal: a script parsing JSON for safety-critical
///      immutables turns a mistyped key into a zero, and `absoluteCap18 = 0` deploys clean.
///
/// @dev STACK 5 (docs/AUDIT-SCOPE-STACK5.md, docs/STACK5-DEPLOY-RUNBOOK.md). On top of stack 4's
///      six vaults this deploys, from the deployer, the four stand-alone contracts stack 5 adds:
///      InsuranceStaking v2, CertStaking v2, BuybackForwarder and FeeVault (70/20/5/5). It does
///      NOT wire them to the vaults: every vault setter is governance's, and governance is the
///      Safe, so the wiring is three Safe batches built by `script/SafeBatches.s.sol` - phase A
///      (day 0: set-once sinks, registration, proposals), phase B (day >= 2: the delayed applies)
///      and openMinting (per vault: the capacity cap, which is what lets a vault take money).
///      Stack 5 is Safe-governed or nothing: MAINNET_GOVERNANCE_SAFE is required.
///
///      The book goes to `deployments/4663.stack5.json`, NOT `4663.json`. The book is written in
///      forge's simulation pass, so a dry run that wrote `4663.json` would overwrite the LIVE
///      stack-4 book on the host the front end and health checks read. It is promoted to
///      `4663.json` by hand at cutover (runbook step 9).
contract DeployMainnet is DeployTestnet {
    // ------------------------------------------------------------------------------ external
    //
    // Live on chain 4663, and all four return `0x` on testnet 46630 — which is the whole reason
    // `src/sim/LighterSim.sol` exists.

    /// @dev Global Dollar. `symbol()` returns "USDG" and `decimals()` returns 6, matching
    ///      `COLLATERAL_DECIMALS`, which `CertVault` reads ONCE at construction.
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    /// @dev Lighter's venue. The PROXY, never the implementation: implementations rotate on
    ///      upgrade and the proxy is the stable address.
    address internal constant ZK_LIGHTER = 0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d;

    uint256 internal constant MAINNET_CHAIN_ID = 4663;

    /// @dev 26 hours. The parent's 900 is a testnet reachability value and its own note says it
    ///      must not be carried over — long enough here to span a weekend close plus a holiday.
    uint256 internal constant MAINNET_STALENESS_SECONDS = 93_600;

    error DeployMainnet_AnswerRequired(string what);

    // ------------------------------------------------------------------- overridable parameters

    function _chainId() internal view override returns (uint256) {
        return MAINNET_CHAIN_ID;
    }

    function _stalenessSeconds() internal view override returns (uint256) {
        return MAINNET_STALENESS_SECONDS;
    }

    /// @dev ANSWERED 2026-09-25 by asking the venue itself. A wrong index deposits margin
    ///      against the wrong asset, so this is measured rather than reasoned about.
    ///
    ///      HOW IT WAS MEASURED, AND HOW IT WAS FIRST MEASURED WRONG. `api/v1/assets` and
    ///      `api/v1/info` are both 403, but `api/v1/orderBooks` is public and carries a
    ///      `quote_asset_id` per market. Every one of our six markets reports 0, so 0 went in
    ///      here - and the deploy dry run reverted `AdditionalZkLighter_InvalidAssetIndex` at
    ///      `bootstrap()`. The order book's quote asset id and `deposit()`'s asset index are
    ///      DIFFERENT NUMBERINGS; reading one and calling it the other was measuring the wrong
    ///      thing and describing it as a measurement.
    ///
    ///      What settled it: `eth_call` of `deposit(deployer, i, 0, 1e6)` across i = 0..24.
    ///      0 and 2 revert `InvalidAssetIndex`; 1 and 4..24 revert `InvalidDepositAmount`;
    ///      3 alone reached the ERC-20 transfer and failed only on allowance. Granting a
    ///      1 USDG allowance turned that inference into a pass - index 3 then SUCCEEDS and
    ///      every other index still fails. The allowance was revoked immediately.
    ///
    ///      The parent also uses 3, which is a coincidence of LighterSim's own numbering and
    ///      not evidence: had it disagreed, the venue would still be right.
    function _collateralAssetIndex() internal view override returns (uint16) {
        return 3;
    }

    /// @dev ANSWERED 2026-09-25: false, and the constructor would refuse anything else.
    ///
    ///      This declares the price feed and the venue mark economically independent. On
    ///      testnet it was `false` while both keepers ran on our own keys, which made the
    ///      declaration organisational rather than economic. On mainnet it is now true in the
    ///      economic sense the flag is for: the mark comes from Lighter's order book and the
    ///      price from Chainlink's own aggregators on this chain, which share no operator.
    ///
    ///      It is also forced. `true` caps `deviationBps` at MAX_SINGLE_SOURCE_DEVIATION_BPS
    ///      (200) and construction REVERTS at our 500, so `true` could not deploy without also
    ///      loosening a risk parameter - which is the right coupling and worth not fighting.
    function _singleSource() internal view override returns (bool) {
        return false;
    }

    /// @dev No free collateral. The parent mints its own seed because the deployer owns
    ///      `TestUSDG`; here the float is real USDG that somebody has to send. Seeding is done
    ///      separately and deliberately, so this returns zero and `_phase5` skips it.
    function _seedCollateral() internal view virtual override returns (uint256) {
        return vm.envUint("MAINNET_SEED_COLLATERAL");
    }

    /// @dev The real venue advances its own batches; there is no keeper role to register.
    function _requiresBatchKeeper() internal view override returns (bool) {
        return false;
    }

    /// @dev False: see `_phase5_allowlistMarksAndBootstrap` above. Bootstrap is done by
    ///      `deploy/bin/usecert-mainnet-bootstrap` as six direct transactions, because forge
    ///      cannot execute the venue's Stylus deposit in any mode.
    /// @dev The real Lighter proxy, so the book says `lighter`. Written as `lighterSim` twice, and
    ///      each time the mainnet site described the real exchange as a simulator (ROADMAP 6.5).
    function _venueBookKey() internal pure override returns (string memory) {
        return "lighter";
    }

    /// @dev ROADMAP 6.15: governance is the UseCert 2-of-3 Safe.
    /// @dev Stack 5: REQUIRED. Stack 4 treated unset as "an EOA governance key, as before"; stack 5's
    ///      wiring (two-day proposals, set-once sinks, registration clock) is built only as Safe
    ///      batches, so an EOA-governed mainnet stack 5 would deploy clean and then have no tested
    ///      path to being wired.
    function _externalGovernance() internal view virtual override returns (address) {
        address safe = vm.envOr("MAINNET_GOVERNANCE_SAFE", address(0));
        if (safe == address(0)) {
            revert DeployMainnet_AnswerRequired("MAINNET_GOVERNANCE_SAFE: stack 5 is governed by the Safe; set its address");
        }
        return safe;
    }

    function _externalRegistry() internal view virtual override returns (address) {
        return vm.envAddress("MAINNET_SAFE_REGISTRY");
    }

    function _externalOracle(uint256 i) internal view virtual override returns (address) {
        return vm.envAddress(string.concat("MAINNET_SAFE_ORACLE_", assets[i].symbol));
    }

    function _bootstrapsInScript() internal view override returns (bool) {
        return false;
    }

    /// @dev The real venue, asserted for what it IS rather than for what `LighterSim` is.
    ///
    ///      The parent checks an allowlist row, a margin floor, a seeded mark, a simulator owner
    ///      and a batch keeper. Lighter has none of those: no depositor allowlist we sit on, no
    ///      owner we control, and it advances its own batches. Calling them here would revert
    ///      rather than fail an assertion.
    ///
    ///      What IS assertable before bootstrap is that each vault points at the venue this file
    ///      names, carries the collateral asset index that venue accepts, and has NOT yet been
    ///      registered - the last one being the precondition the bootstrap step depends on. The
    ///      post-conditions of bootstrap are asserted by the tool that performs it.
    function _verifyVenueWiring(uint256 i) internal view override {
        CertVault v = CertVault(deployed[i].vault);
        (, uint16 assetIndex,,,,,,,,) = v.cfg();

        require(address(v.lighter()) == ZK_LIGHTER, "S9 MAINNET: vault.lighter is not Lighter's proxy");
        require(assetIndex == 3, "S9 MAINNET: cfg.collateralAssetIndex != 3 - the venue rejects the deposit");
        require(!v.bootstrapped(), "S9 MAINNET: already bootstrapped before the bootstrap step");
        require(
            v.lighterAccountIndex() == 0,
            "S9 MAINNET: lighterAccountIndex non-zero before bootstrap - this vault is not fresh"
        );
    }

    /// @dev The parent asserts the collateral is deployer-owned and that a faucet holds its
    ///      float. Neither is true or desirable here: USDG is owned by its issuer - the deploy
    ///      dry run read `owner()` as 0xcFA0388f5ddf905FdC08c45c716C15Dc10A14C6F, which is the
    ///      point of using real collateral - and no faucet is deployed, because a faucet on
    ///      mainnet is a mint of free money.
    ///
    ///      The check is REPLACED rather than dropped. What matters on this chain is that the
    ///      vaults were wired to the USDG this file names and not to something else that also
    ///      reports six decimals, and that no faucet slipped into the deployment.
    function _verifyCollateralAndFaucet() internal view override {
        require(collateral == USDG, "S9 MAINNET: collateral is not the USDG this script names");
        require(testFaucet == address(0), "S9 MAINNET: a faucet was deployed on mainnet");
        require(IERC20(collateral).totalSupply() > 0, "S9 MAINNET: collateral has no supply");
    }

    // ---------------------------------------------------------------------------------- senders

    /// @dev DISTINCT ENV NAMES, and that is the point.
    ///
    ///      The parent reads `DEPLOYER_PK` / `GOV_PK` / `ATTESTER_PK`, and those are exactly the
    ///      names already exported on the operations host for the TESTNET keeper. Inheriting them
    ///      would mean a mainnet deploy run in the wrong shell picks up testnet keys and broadcasts
    ///      real transactions from them - and the first sign would be a deployment owned by an
    ///      address whose key is in a keeper env file.
    ///
    ///      `MAINNET_*` cannot collide. If they are unset, `vm.envUint` reverts and nothing is
    ///      broadcast, which is the correct outcome for a shell that was not prepared for this.
    ///
    ///      Keys live in `/etc/usecert/mainnet-deployer.env`, root-owned 0600, and are never in
    ///      this repository. See `deploy/mainnet/SWITCHING.md` for how a run loads them.
    /// @dev Stack 5: no governance key. Governance is the Safe (see `_externalGovernance`), which
    ///      signs nothing here; `run()` never derives an address from this slot in Safe mode, so
    ///      MAINNET_GOV_PK is no longer read and should not exist on the deploy host.
    function _senderKeys()
        internal
        view
        virtual
        override
        returns (uint256 deployerPk, uint256 govPk, uint256 attesterPk)
    {
        return (vm.envUint("MAINNET_DEPLOYER_PK"), 0, vm.envUint("MAINNET_ATTESTER_PK"));
    }

    /// @dev The batch keeper is a LighterSim concept: the simulator needs a registered key to
    ///      settle its own batches. The real venue settles its own, so there is no such role.
    function _batchKeeperAddress() internal view override returns (address) {
        return address(0);
    }

    // ---------------------------------------------------------------------------------- seams

    /// @dev The collateral already exists. Nothing is constructed.
    function _deployCollateral() internal override returns (address) {
        return USDG;
    }

    /// @dev No simulator, no faucet, and no price feeds of our own making.
    ///
    ///      The parent's phase 1 deploys `TestUSDG`, a `TestFaucet`, a `LighterSim` sized to the
    ///      first asset's `sizeDecimals`, and one `ReplayAggregator` per mirror. The simulator
    ///      sizing is itself a testnet-only constraint: one sim cannot serve two different size
    ///      decimals, and the real venue has six distinct decimal pairs across its markets.
    ///
    ///      What replaces them here: the real collateral, the real venue, and a REAL price feed
    ///      per mirror, which this project does not deploy and must be told. `_pushAggregator`
    ///      still has to be called once per asset in order — later phases index the array by
    ///      mirror, and skipping it is how an earlier version of this override panicked with an
    ///      array out-of-bounds after `SolvencyRegistry` rather than saying what was missing.
    function _phase1_simulators() internal override {
        collateral = _deployCollateral();
        lighter = ZK_LIGHTER;
        testFaucet = address(0);
        for (uint256 i = 0; i < assets.length; ++i) {
            _pushAggregator(_feedFor(assets[i].symbol));
        }
    }

    /// @dev The real aggregator for one mirror, read from the environment.
    ///
    ///      REVERTS when unset, like the other answers this file refuses to guess. A feed is the
    ///      single input that decides what every certificate is worth; a wrong or absent one is
    ///      not a degraded deployment, it is a differently-priced asset. `_readFeed` also does not
    ///      bound `decimals()`, so the feed must report 8 — a deployment-time constraint with no
    ///      runtime check behind it.
    function _feedFor(string memory symbol) internal view virtual returns (address) {
        string memory key = string.concat("MAINNET_FEED_", symbol);
        address feed = vm.envOr(key, address(0));
        if (feed == address(0)) {
            revert DeployMainnet_AnswerRequired(
                string.concat(key, ": set a real 8-decimal price aggregator for this mirror")
            );
        }
        return feed;
    }

    /// @dev The parent allowlists each vault on `LighterSim` before bootstrapping, then seeds
    ///      each buffer from minted collateral. Neither applies: the real venue has no
    ///      owner-gated depositor allowlist for us to call, and there is no free collateral.
    ///
    ///      Bootstrapping still has to happen, so it is done here without the two testnet steps.
    /// @dev BOOTSTRAP IS NOT DONE HERE, and cannot be.
    ///
    ///      `CertVault.bootstrap()` calls `lighter.deposit(...)`, which on mainnet delegates to
    ///      0xDa2B59fFB41485a6f21E14e479AE7B7AB29a997c - an Arbitrum Stylus (WASM) contract that
    ///      foundry's EVM cannot execute. It aborts with `NotActivated` after burning ~963M gas,
    ///      which is the signature of that rather than of a contract fault: the USDG transfer
    ///      into the venue completes first and the venue's balance visibly increments.
    ///
    ///      `--skip-simulation` does not help. `forge script` ALWAYS executes the script locally
    ///      to collect the transactions to send; that flag only skips the separate on-chain
    ///      simulation pass. So a script that calls `bootstrap()` can never broadcast anything
    ///      at all - it dies while building the list. Confirmed by running it: nothing was sent,
    ///      no address book was written, and not one wei moved.
    ///
    ///      The chain itself has no such trouble: `eth_call` of `deposit()` at asset index 3
    ///      SUCCEEDS against the node. So bootstrapping is a direct transaction, not a scripted
    ///      one - `deploy/bin/usecert-mainnet-bootstrap` does the six and verifies each.
    ///
    ///      What stays here is the part forge can do: fund each buffer so the dust is already in
    ///      the vault when bootstrap is called.
    function _phase5_allowlistMarksAndBootstrap() internal override {
        uint256 seed = _seedCollateral();
        require(seed > 0, "MAINNET: seed collateral must be non-zero; bootstrap deposits from it");
        for (uint256 i = 0; i < assets.length; ++i) {
            IERC20(collateral).approve(deployed[i].vault, seed);
            CertVault(deployed[i].vault).seedBuffer(seed);
        }
    }

    // ------------------------------------------------------------------------------- the mirrors
    //
    // Market indices, price decimals and size decimals read from Lighter's live market list on
    // 2026-09-25 (`mainnet.zklighter.elliot.ai/api/v1/orderBookDetails`, 210 active markets).
    //
    // EVERY ONE DIFFERS FROM THE TESTNET DEPLOYMENT, including the two the address book recorded
    // as venue-verified. `marketIndex` is immutable on `CertVault`, so these are the only chance
    // to get them right — a wrong index hedges a different company, silently, because on the
    // simulator `setMarkPrice()` creates any index implicitly.
    //
    // DECIMALS. `_quantiseToVenue` rounds size by `10 ** sizeDecimals`, so a wrong pair quantises
    // every order to the wrong lot - never copy a neighbour's. The "3 and 3" notes this file used to
    // carry for uNVDA and uAAPL match `deploy/mainnet/lighter-markets.json`, the OTHER exchange's catalogue
    // (mainnet.zklighter, USDC - see usecert-mainnet-preflight); the values in this table are the
    // ones stack 4 (deployments/4663.json) was deployed with on Robinhood Chain Lighter.
    // usecert-mainnet-preflight re-reads them from api.rh.lighter.xyz before every deploy and
    // refuses on any mismatch - it, not this comment, is the check.
    //
    // STACK 5 carries this table over unchanged: same markets, same decimals, same order.
    //
    // Caps, open interest and buffer thresholds are carried over from the testnet parameters and
    // are the values most worth arguing about before a real deployment: they size how much real
    // money can be minted against each mirror.
    function _loadAssets() internal override {
        assets.push(
            AssetParams({
                name: "UseCert TSLA",
                symbol: "uTSLA",
                feedDescription: "TSLA / USD",
                marketIndex: 16,
                priceDecimals: 2,
                sizeDecimals: 4,
                seedPx18: 372.58e18,
                absoluteCap18: 90_000e18,
                openInterest18: 900_000e18,
                bufferFloor18: 100_000e18,
                bufferFeeOn18: 60_000e18,
                bufferMintSlow18: 30_000e18
            })
        );
        assets.push(
            AssetParams({
                name: "UseCert SPY",
                symbol: "uSPY",
                feedDescription: "SPY / USD",
                marketIndex: 26,
                priceDecimals: 2,
                sizeDecimals: 4,
                seedPx18: 769.82e18,
                absoluteCap18: 5_000_000e18,
                openInterest18: 50_000_000e18,
                bufferFloor18: 100_000e18,
                bufferFeeOn18: 60_000e18,
                bufferMintSlow18: 30_000e18
            })
        );
        assets.push(
            AssetParams({
                name: "UseCert QQQ",
                symbol: "uQQQ",
                feedDescription: "QQQ / USD",
                marketIndex: 25,
                priceDecimals: 2,
                sizeDecimals: 4,
                seedPx18: 742.79e18,
                absoluteCap18: 3_050_000e18,
                openInterest18: 30_500_000e18,
                bufferFloor18: 100_000e18,
                bufferFeeOn18: 60_000e18,
                bufferMintSlow18: 30_000e18
            })
        );
        assets.push(
            AssetParams({
                name: "UseCert NVDA",
                symbol: "uNVDA",
                feedDescription: "NVDA / USD",
                marketIndex: 15,
                // See DECIMALS above: the 3/3 figure is the other exchange's.
                priceDecimals: 2,
                sizeDecimals: 4,
                seedPx18: 224.908e18,
                absoluteCap18: 311_000e18,
                openInterest18: 3_110_000e18,
                bufferFloor18: 100_000e18,
                bufferFeeOn18: 60_000e18,
                bufferMintSlow18: 30_000e18
            })
        );
        assets.push(
            AssetParams({
                name: "UseCert AAPL",
                symbol: "uAAPL",
                feedDescription: "AAPL / USD",
                marketIndex: 10,
                // See DECIMALS above: the 3/3 figure is the other exchange's.
                priceDecimals: 2,
                sizeDecimals: 4,
                seedPx18: 339.336e18,
                absoluteCap18: 500_000e18,
                openInterest18: 5_000_000e18,
                bufferFloor18: 100_000e18,
                bufferFeeOn18: 60_000e18,
                bufferMintSlow18: 30_000e18
            })
        );
        assets.push(
            AssetParams({
                name: "UseCert MSFT",
                symbol: "uMSFT",
                feedDescription: "MSFT / USD",
                marketIndex: 14,
                priceDecimals: 2,
                sizeDecimals: 4,
                seedPx18: 514.46e18,
                absoluteCap18: 500_000e18,
                openInterest18: 5_000_000e18,
                bufferFloor18: 100_000e18,
                bufferFeeOn18: 60_000e18,
                bufferMintSlow18: 30_000e18
            })
        );

        // ONE VAULT AT A TIME. The first two mainnet deploys created and seeded all six vaults
        // before a single hedge had been proven, and every one of them was broken the same way.
        // MAINNET_ONLY=<symbol> keeps exactly that asset, so the first deploy of a new design is
        // one vault by construction rather than by someone remembering. Unset = all six.
        string memory only = _onlyAsset();
        if (bytes(only).length != 0) {
            uint256 keep = type(uint256).max;
            for (uint256 i = 0; i < assets.length; ++i) {
                if (keccak256(bytes(assets[i].symbol)) == keccak256(bytes(only))) keep = i;
            }
            if (keep == type(uint256).max) revert DeployMainnet_AnswerRequired("MAINNET_ONLY names no asset");
            AssetParams memory kept = assets[keep];
            delete assets;
            assets.push(kept);
        }

        // M-8: every per-asset cap the Safe will set must sit under that asset's reviewed ceiling.
        for (uint256 i = 0; i < assets.length; ++i) {
            require(
                assets[i].absoluteCap18 <= _maxAbsoluteCapOf(assets[i].symbol),
                "M-8: asset absoluteCap18 above its reviewed ceiling"
            );
        }
    }

    /// @dev MAINNET_ONLY=<symbol> keeps exactly that asset. A seam so a test need not write the
    ///      process environment.
    function _onlyAsset() internal view virtual returns (string memory) {
        return vm.envOr("MAINNET_ONLY", string(""));
    }

    // =================================================================================== STACK 5
    //
    // Every value below is IMMUTABLE in the contract it configures. None of these contracts has an
    // owner, a setter or an upgrade path, so each number is reviewed here, once, or never.

    /// @dev CERT, the protocol token, on chain 4663 (18 decimals). CertStaking v1 used the same
    ///      address (deployments/4663.certstaking.json).
    address internal constant CERT = 0xb01356A005403C38c0fb01bd0aAfe51e81Ab9B07;

    // ----------------------------------------------------------------- InsuranceStaking v2
    //
    // The constructor enforces the relations between these (docs/K-INSURANCE-STAKING.md):
    //   cooldown > drawDelay; withdrawWindow >= drawDelay + DRAW_EXECUTION_WINDOW (3 d) + 1 d (M-2);
    //   drawDelay + 3 d + 1 d <= MIN_PROPOSAL_GAP (7 d); registrationDelay >= cooldown + window (H-3).
    // With 10 d / 6 d / 2 d / 16 d every one holds with no slack to spare on the M-2 and H-3 legs,
    // which is intended: a longer window or registration delay is safer, a shorter one reverts.

    /// @dev A staker's notice before exiting. v1 used the same 10 days.
    uint256 internal constant INSURANCE_COOLDOWN = 10 days;
    /// @dev How long an exit stays open once the cooldown ends. v1 had 3 d; v2's constructor
    ///      requires >= drawDelay + 4 d (M-2), so a draw pause can never cover a whole window.
    uint256 internal constant INSURANCE_WITHDRAW_WINDOW = 6 days;
    /// @dev Public notice between a draw proposal and its execution. Same as v1.
    uint256 internal constant INSURANCE_DRAW_DELAY = 2 days;
    /// @dev At most 30% of the pool per draw, and per rolling 30 days. Same as v1.
    uint256 internal constant INSURANCE_MAX_DRAW_BPS = 3_000;
    /// @dev 10,000 USDG of net principal: the unaudited-contract exposure bound. Same as v1.
    uint256 internal constant INSURANCE_DEPOSIT_CAP = 10_000e6;
    /// @dev H-3: a vault can be drawn to only this long after `registerVault`, longer than a full
    ///      exit (cooldown + window), so every staker can leave ahead of a registration they dislike.
    uint256 internal constant INSURANCE_REGISTRATION_DELAY = 16 days;
    string internal constant INSURANCE_NAME = "UseCert Insurance Pool v2";
    /// @dev Not v1's "ucINS": two live share tokens with one symbol would be indistinguishable in a
    ///      wallet while v1 winds down.
    string internal constant INSURANCE_SYMBOL = "ucINS2";

    // ----------------------------------------------------------------------- CertStaking v2

    uint256 internal constant CERT_STAKING_DURATION = 7 days;
    /// @dev 10,000,000 CERT: the unaudited-contract exposure bound, as v1.
    uint256 internal constant CERT_STAKING_CAP = 10_000_000e18;
    /// @dev 1 USDG: fundings below this are refused (pre-audit M-4), and BuybackForwarder skips.
    uint256 internal constant CERT_STAKING_MIN_NOTIFY = 1e6;

    // ------------------------------------------------------------------------- the fee split
    //
    // Pinned by test_mainnetSplit_order_and_bps: four distinct recipients, in this order.

    uint256 internal constant FEE_BPS_INSURANCE = 7_000;
    uint256 internal constant FEE_BPS_BUYBACK = 2_000;
    uint256 internal constant FEE_BPS_OPS = 500;
    uint256 internal constant FEE_BPS_TREASURY = 500;

    // ----------------------------------------------------------------- M-8: capacity ceilings
    //
    // `CapacityOracle.maxAbsoluteCap` is the immutable ceiling on every `absoluteCap18` governance
    // may set, i.e. the one number that bounds a lying attester. Stack 4 deployed 1e27 ($1bn), which
    // bounds nothing. Stack 5 sizes it from this table: per asset, the stack-4 `absoluteCap18`
    // (10% of the venue open interest measured 2026-09-25), which is also the cap the Safe sets.
    //
    // ONE ORACLE, ONE CEILING. CapacityOracle has a single `maxAbsoluteCap` and CertFactory a single
    // `capacity`, so the deployed ceiling is the LARGEST row of the table (uSPY's $5M with all six
    // assets, or the one row with MAINNET_ONLY). The per-asset rows are enforced where they can be:
    // `_loadAssets` refuses an asset whose cap is above its row, and SafeBatches.openMinting refuses
    // to set a cap above it. What the chain cannot enforce, stated: the Safe could later raise uTSLA
    // from $90k up to the shared $5M ceiling without a redeploy. See the runbook's owner decisions.

    uint256 internal constant MAX_ABS_CAP_UTSLA = 90_000e18;
    uint256 internal constant MAX_ABS_CAP_USPY = 5_000_000e18;
    uint256 internal constant MAX_ABS_CAP_UQQQ = 3_050_000e18;
    uint256 internal constant MAX_ABS_CAP_UNVDA = 311_000e18;
    uint256 internal constant MAX_ABS_CAP_UAAPL = 500_000e18;
    uint256 internal constant MAX_ABS_CAP_UMSFT = 500_000e18;

    /// @dev The reviewed ceiling for one asset. Reverts for an asset with no row: a new mirror gets a
    ///      reviewed number, not a default.
    function _maxAbsoluteCapOf(string memory symbol) internal pure returns (uint256) {
        bytes32 h = keccak256(bytes(symbol));
        if (h == keccak256("uTSLA")) return MAX_ABS_CAP_UTSLA;
        if (h == keccak256("uSPY")) return MAX_ABS_CAP_USPY;
        if (h == keccak256("uQQQ")) return MAX_ABS_CAP_UQQQ;
        if (h == keccak256("uNVDA")) return MAX_ABS_CAP_UNVDA;
        if (h == keccak256("uAAPL")) return MAX_ABS_CAP_UAAPL;
        if (h == keccak256("uMSFT")) return MAX_ABS_CAP_UMSFT;
        revert DeployMainnet_AnswerRequired(string.concat("M-8: no reviewed maxAbsoluteCap row for ", symbol));
    }

    /// @dev The deployed ceiling: the largest reviewed row among the assets being deployed.
    function _maxAbsoluteCap() internal view override returns (uint256 m) {
        for (uint256 i = 0; i < assets.length; ++i) {
            uint256 c = _maxAbsoluteCapOf(assets[i].symbol);
            if (c > m) m = c;
        }
        require(m != 0, "M-8: no assets loaded, no ceiling to size");
    }

    // ------------------------------------------------------------------------ stack-5 state

    address internal feeVault;
    address internal buybackForwarder;
    address internal insuranceStaking;
    address internal certStaking;
    address internal settlerAddr;
    address internal opsWallet;
    address internal treasury;

    // ----------------------------------------------------------------------- stack-5 inputs

    /// @dev The keeper-mode settler (H-4): a key of its own, never the attester's. The vault's
    ///      `settler` is set by the phase-B Safe batch; the deploy only records it and checks it.
    function _settlerAddr() internal view virtual returns (address) {
        return vm.envOr("MAINNET_SETTLER_ADDR", address(0));
    }

    /// @dev The 5% ops leg. Defaults to the deployer (0x6381...8e92 on mainnet), which pays the
    ///      keepers' gas.
    function _opsWalletAddr() internal view virtual returns (address) {
        return vm.envOr("MAINNET_OPS_WALLET", deployerAddr);
    }

    /// @dev The 5% treasury leg. Defaults to the governance Safe (0x848c...70DF on mainnet).
    function _treasuryAddr() internal view virtual returns (address) {
        return vm.envOr("MAINNET_TREASURY_SAFE", govAddr);
    }

    /// @dev Everything stack 5 needs that is not in this file, checked before the first broadcast.
    ///      FeeVault has no owner and no setter, so a wrong recipient is wrong for ever.
    function _preBroadcastChecks() internal virtual override {
        settlerAddr = _settlerAddr();
        opsWallet = _opsWalletAddr();
        treasury = _treasuryAddr();

        require(govAddr.code.length > 0, "MAINNET: the governance Safe has no code on this chain");
        require(USDG.code.length > 0, "MAINNET: USDG has no code on this chain");
        require(ZK_LIGHTER.code.length > 0, "MAINNET: the venue proxy has no code on this chain");
        require(CERT.code.length > 0, "MAINNET: CERT has no code on this chain");

        if (settlerAddr == address(0)) {
            revert DeployMainnet_AnswerRequired("MAINNET_SETTLER_ADDR: the keeper-mode settler key's address (H-4)");
        }
        // H-4: the settler is a separate key. As the attester it could mint unhedged certificates
        // and then attest them away; as the deployer or the Safe it collapses a separation.
        require(settlerAddr != attesterAddr, "SENDERS: settler == attester (H-4)");
        require(settlerAddr != deployerAddr, "SENDERS: settler == deployer");
        require(settlerAddr != govAddr, "SENDERS: settler == governance");

        require(opsWallet != address(0), "FEES: ops wallet is zero");
        require(treasury != address(0), "FEES: treasury is zero");
        // An EOA typo here is a permanent recipient of 5% of all fees.
        require(treasury.code.length > 0, "FEES: treasury has no code - it must be a Safe");
        require(opsWallet != treasury, "FEES: ops wallet == treasury - FeeVault refuses duplicates");
    }

    // ----------------------------------------------------------------------- stack-5 phase 3

    /// @dev Stack 4's phase 3 (CapacityOracle with the M-8 ceiling, CertFactory, the six vaults),
    ///      then the four stack-5 contracts, all from the deployer. None of them binds governance to
    ///      msg.sender: InsuranceStaking takes it as an argument and the other three have none.
    function _phase3_coreAndVaults() internal override {
        super._phase3_coreAndVaults();
        _deployStack5Shared();
    }

    /// @dev The four stack-5 contracts. None needs an oracle, so on 2026-09-27 they were deployed
    ///      ahead of the vaults (script/DeployStack5Shared.s.sol) while the stock feeds were frozen
    ///      for the weekend. Each is reused when named in the environment; the S9 read-backs
    ///      (_verifyFeeVault, _verifyStakings) check reused ones exactly as fresh ones, so a wrong
    ///      address fails the dry run before anything is sent.
    function _deployStack5Shared() internal {
        // Registry = CertFactory: the pool reads isVault and registeredAt (H-3) from it.
        insuranceStaking = _reuse("MAINNET_INSURANCE_STAKING");
        if (insuranceStaking == address(0)) {
            insuranceStaking = address(
                new InsuranceStaking(
                    IERC20(collateral),
                    IVaultRegistry(factory),
                    govAddr,
                    INSURANCE_COOLDOWN,
                    INSURANCE_WITHDRAW_WINDOW,
                    INSURANCE_DRAW_DELAY,
                    INSURANCE_MAX_DRAW_BPS,
                    INSURANCE_DEPOSIT_CAP,
                    INSURANCE_REGISTRATION_DELAY,
                    INSURANCE_NAME,
                    INSURANCE_SYMBOL
                )
            );
        }

        certStaking = _reuse("MAINNET_CERT_STAKING");
        if (certStaking == address(0)) {
            certStaking = address(
                new CertStaking(
                    IERC20(CERT), IERC20(collateral), CERT_STAKING_DURATION, CERT_STAKING_CAP, CERT_STAKING_MIN_NOTIFY
                )
            );
        }

        // Its constructor checks the staking contract streams USDG and has minNotify.
        buybackForwarder = _reuse("MAINNET_BUYBACK_FORWARDER");
        if (buybackForwarder == address(0)) {
            buybackForwarder = address(new BuybackForwarder(IERC20(collateral), ICertStakingFunding(certStaking)));
        }

        feeVault = _reuse("MAINNET_FEE_VAULT");
        if (feeVault == address(0)) {
            (address[] memory r, uint256[] memory b) = _feeSplit();
            feeVault = address(new FeeVault(IERC20(collateral), r, b));
        }
    }

    /// @dev An already-deployed contract named by `key`, or zero. A named address with no code
    ///      is a typo, not a request to deploy.
    function _reuse(string memory key) internal view returns (address a) {
        a = vm.envOr(key, address(0));
        if (a != address(0)) require(a.code.length > 0, string.concat("STACK5: ", key, " has no code"));
    }

    function _presetCapacity() internal view override returns (address) {
        return _reuse("MAINNET_CAPACITY_ORACLE");
    }

    function _presetFactory() internal view override returns (address) {
        return _reuse("MAINNET_CERT_FACTORY");
    }

    /// @dev 70% InsuranceStaking, 20% BuybackForwarder, 5% ops wallet, 5% treasury Safe.
    function _feeSplit() internal view returns (address[] memory r, uint256[] memory b) {
        r = new address[](4);
        b = new uint256[](4);
        (r[0], r[1], r[2], r[3]) = (insuranceStaking, buybackForwarder, opsWallet, treasury);
        (b[0], b[1], b[2], b[3]) = (FEE_BPS_INSURANCE, FEE_BPS_BUYBACK, FEE_BPS_OPS, FEE_BPS_TREASURY);
    }

    // --------------------------------------------------------------- stack-5 read-backs (S9)

    function _verifyExtra() internal view override {
        _verifyFeeVault();
        _verifyStakings();
        _verifyCapsAndMarks();
    }

    function _verifyFeeVault() internal view {
        FeeVault fv = FeeVault(feeVault);
        require(address(fv.asset()) == collateral, "S9 STACK5: feeVault.asset != USDG");
        require(fv.recipientCount() == 4, "S9 STACK5: feeVault must have exactly four recipients");
        (address[] memory r, uint256[] memory b) = _feeSplit();
        for (uint256 k = 0; k < 4; ++k) {
            (address who, uint256 bps) = fv.recipientAt(k);
            require(who == r[k], "S9 STACK5: feeVault recipient out of order");
            require(bps == b[k], "S9 STACK5: feeVault share wrong");
        }

        BuybackForwarder bf = BuybackForwarder(buybackForwarder);
        require(address(bf.usdg()) == collateral, "S9 STACK5: forwarder.usdg != USDG");
        require(address(bf.staking()) == certStaking, "S9 STACK5: forwarder not bound to the new CertStaking");
    }

    function _verifyStakings() internal view {
        InsuranceStaking ins = InsuranceStaking(insuranceStaking);
        require(ins.asset() == collateral, "S9 STACK5: insurance.asset != USDG");
        require(address(ins.registry()) == factory, "S9 STACK5: insurance.registry != CertFactory");
        require(ins.governance() == govAddr, "S9 STACK5: insurance.governance != Safe");
        require(ins.cooldown() == INSURANCE_COOLDOWN, "S9 STACK5: insurance.cooldown");
        require(ins.withdrawWindow() == INSURANCE_WITHDRAW_WINDOW, "S9 STACK5: insurance.withdrawWindow");
        require(ins.drawDelay() == INSURANCE_DRAW_DELAY, "S9 STACK5: insurance.drawDelay");
        require(ins.maxDrawBps() == INSURANCE_MAX_DRAW_BPS, "S9 STACK5: insurance.maxDrawBps");
        require(ins.depositCap() == INSURANCE_DEPOSIT_CAP, "S9 STACK5: insurance.depositCap");
        require(ins.registrationDelay() == INSURANCE_REGISTRATION_DELAY, "S9 STACK5: insurance.registrationDelay");

        CertStaking cs = CertStaking(certStaking);
        require(address(cs.stakingToken()) == CERT, "S9 STACK5: certStaking.stakingToken != CERT");
        require(address(cs.rewardToken()) == collateral, "S9 STACK5: certStaking.rewardToken != USDG");
        require(cs.rewardsDuration() == CERT_STAKING_DURATION, "S9 STACK5: certStaking.rewardsDuration");
        require(cs.stakeCap() == CERT_STAKING_CAP, "S9 STACK5: certStaking.stakeCap");
        require(cs.minNotify() == CERT_STAKING_MIN_NOTIFY, "S9 STACK5: certStaking.minNotify");
    }

    function _verifyCapsAndMarks() internal view {
        uint256 ceiling = CapacityOracle(capacity).maxAbsoluteCap();
        require(ceiling < 1_000_000_000e18, "S9 STACK5 M-8: maxAbsoluteCap is the stack-4 1e27 again");
        for (uint256 i = 0; i < assets.length; ++i) {
            CertVault v = CertVault(deployed[i].vault);
            require(_maxAbsoluteCapOf(assets[i].symbol) <= ceiling, "S9 STACK5 M-8: a row above the deployed ceiling");
            require(CertOracle(deployed[i].oracle).maxMarkAge() == MAX_MARK_AGE, "S9 STACK5: oracle.maxMarkAge");
            // Nothing is wired yet: the Safe's phase A does all of it, and every one of these is
            // set-once or delayed, so a value here would be one nobody reviewed.
            require(v.feeSink() == address(0), "S9 STACK5: feeSink already set before phase A");
            require(v.insurancePool() == address(0), "S9 STACK5: insurancePool already set before phase A");
            require(v.settler() == address(0), "S9 STACK5: settler already set before phase B");
            require(!v.keeperHedging(), "S9 STACK5: keeper hedging already on before phase A");
            require(CertFactory(factory).registeredAt(deployed[i].vault) == 0, "S9 STACK5: registered before phase A");
        }
    }

    // --------------------------------------------------------------------- stack-5 address book

    function _bookPath() internal view virtual override returns (string memory) {
        return "deployments/4663.stack5.json";
    }

    function _generatedBy() internal pure override returns (string memory) {
        return "script/DeployMainnet.s.sol (stack 5)";
    }

    function _stackMarkerJson() internal pure override returns (string memory) {
        return string.concat(
            '  "stack": 5,\n',
            '  "_stackNote": "Stack 5 (docs/AUDIT-SCOPE-STACK5.md). Written to 4663.stack5.json and promoted to 4663.json by hand at cutover; the wiring (fee sink, insurance pool, settler, venue key and minimums, caps) is done by the Safe batches in script/SafeBatches.s.sol, not by this deploy.",\n'
        );
    }

    function _extraSharedJson() internal view override returns (string memory) {
        string memory out = _jAddr("    ", "feeVault", feeVault);
        out = string.concat(out, _jAddr("    ", "buybackForwarder", buybackForwarder));
        out = string.concat(out, _jAddr("    ", "insuranceStaking", insuranceStaking));
        out = string.concat(out, _jAddr("    ", "certStaking", certStaking));
        out = string.concat(out, _jAddr("    ", "cert", CERT));
        out = string.concat(out, _jAddr("    ", "settler", settlerAddr));
        out = string.concat(out, _jAddr("    ", "opsWallet", opsWallet));
        out = string.concat(out, _jAddr("    ", "treasury", treasury));
        return out;
    }

    function _extraParametersJson() internal view override returns (string memory) {
        return string.concat(
            ',\n    "governanceDelay": ', vm.toString(uint256(2 days)), _insuranceJson(), _certStakingJson(), _splitJson()
        );
    }

    function _insuranceJson() internal pure returns (string memory) {
        string memory a = string.concat(
            ',\n    "insuranceStaking": {"cooldown": ', vm.toString(INSURANCE_COOLDOWN),
            ', "withdrawWindow": ', vm.toString(INSURANCE_WITHDRAW_WINDOW),
            ', "drawDelay": ', vm.toString(INSURANCE_DRAW_DELAY)
        );
        return string.concat(
            a,
            ', "maxDrawBps": ', vm.toString(INSURANCE_MAX_DRAW_BPS),
            ', "depositCap": "', vm.toString(INSURANCE_DEPOSIT_CAP),
            '", "registrationDelay": ', vm.toString(INSURANCE_REGISTRATION_DELAY),
            ', "name": "', INSURANCE_NAME, '", "symbol": "', INSURANCE_SYMBOL, '"}'
        );
    }

    function _certStakingJson() internal pure returns (string memory) {
        return string.concat(
            ',\n    "certStaking": {"rewardsDuration": ', vm.toString(CERT_STAKING_DURATION),
            ', "stakeCap": "', vm.toString(CERT_STAKING_CAP),
            '", "minNotify": "', vm.toString(CERT_STAKING_MIN_NOTIFY), '"}'
        );
    }

    function _splitJson() internal view returns (string memory) {
        string memory r = string.concat(
            '["', vm.toString(insuranceStaking), '", "', vm.toString(buybackForwarder), '", "'
        );
        r = string.concat(r, vm.toString(opsWallet), '", "', vm.toString(treasury), '"]');
        return string.concat(
            ',\n    "feeSplit": {"recipients": ', r,
            ', "bps": [7000, 2000, 500, 500], "labels": ["insuranceStaking", "buybackForwarder", "opsWallet", "treasury"]}'
        );
    }

    function _extraAssetJson(uint256 i) internal view override returns (string memory) {
        return _jStr("      ", "maxAbsoluteCap18", vm.toString(_maxAbsoluteCapOf(assets[i].symbol)));
    }

    function _reportExtra() internal view override {
        console2.log("--- stack 5 ---");
        console2.log("FeeVault        ", feeVault);
        console2.log("BuybackForwarder", buybackForwarder);
        console2.log("InsuranceStaking", insuranceStaking);
        console2.log("CertStaking     ", certStaking);
        console2.log("settler (phase B)", settlerAddr);
        console2.log("maxAbsoluteCap18", CapacityOracle(capacity).maxAbsoluteCap());
        console2.log("NEXT: bootstrap, then SafeBatches phaseA(). Nothing can mint until openMinting().");
    }

    // ------------------------------------------------------------------ accessors, for tests

    function stack5Addresses()
        external
        view
        returns (address feeVault_, address forwarder_, address insurance_, address certStaking_, address settler_)
    {
        return (feeVault, buybackForwarder, insuranceStaking, certStaking, settlerAddr);
    }
}
