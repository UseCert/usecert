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
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title  Add ONE mirror to the EXISTING UseCert deployment on Robinhood Chain testnet (46630)
///
/// @notice WHY THIS FILE EXISTS AT ALL, AND WHY IT IS NOT A FLAG ON `DeployTestnet`.
///
///         `script/DeployTestnet.s.sol` has exactly one entry point and it is a FULL BOOTSTRAP: it
///         deploys its own collateral token, its own faucet, its own `LighterSim`, its own
///         `SolvencyRegistry`, `CapacityOracle` and `CertFactory`, and then two vaults, and it
///         overwrites `deployments/46630.json` with the result. Re-running it against a live
///         deployment does not "add" anything. It deploys a SECOND, PARALLEL universe and then
///         renames the address book to point at it — abandoning the live vaults, their Blockscout
///         source verification, the real certificate supply outstanding against them, and every
///         front-end and keeper reading that file. Nothing on-chain would look broken; holders'
///         certificates would simply stop being visible in a UI that now reads a different token.
///
///         So the incremental path is a DIFFERENT SCRIPT with a DIFFERENT SHAPE: it deploys the
///         five per-mirror contracts and NOTHING shared, it takes every shared address from the
///         existing address book rather than constructing one, and it APPENDS to that book instead
///         of replacing it. One mirror per invocation.
///
/// @dev    THE PARTS OF `DeployTestnet` THAT ARE COPIED HERE ON PURPOSE, because they are the
///         safety properties and not the plumbing:
///
///           - THREE SENDERS, pairwise distinct, checked with the same `require` shape (§4). And
///             additionally checked to be THE SAME THREE the book records: a mirror added under a
///             different `GOV_PK` would give the new vault a governance the other vaults do not
///             share, so the emergency `setAbsoluteCap(vault, 0)` lever would live on two different
///             keys and neither operator would know it.
///           - `CertOracle` IS CONSTRUCTED IN `run()`'s OWN FRAME UNDER `vm.startBroadcast(govPk)`.
///             It does `governance = msg.sender` and the field is IMMUTABLE. Move that `new` into a
///             helper contract or a CREATE2 factory and governance lands on an address nobody
///             controls, attester rotation is unreachable forever, and the only remedy is
///             redeploying the mirror. It stays inline, at depth 1, deliberately.
///           - PHASE 5's ORDERING. `setDepositorAllowed` BEFORE `bootstrap()` (which otherwise
///             reverts `LighterSim_DepositorNotAllowed`), `setMarkPrice` before anything can settle
///             (at a zero mark the simulator's whole mark-to-market layer is dead and `settleBatch`
///             refuses outright), collateral IN before `bootstrap()` (it deposits
///             `10 ** decimals` of registering dust and reverts without it).
///           - §9's READ-BACKS, as `require`s with named messages.
///           - THE EIP-170 AWARENESS. `bash script/check-sizes.sh` is the gate, and it is a gate
///             this script cannot discharge for itself: `forge` does not enforce EIP-170 in
///             simulation, so an oversized `CertVault` would simulate green here and fail on chain.
///             Run it before invoking this. Nothing new is added to the compilation unit by this
///             file — it deploys the same five contracts `DeployTestnet` already deploys — so the
///             gate's result is unchanged by construction, which is a reason to check rather than a
///             reason to skip.
///
/// @dev    WHAT THE `require`s IN THIS SCRIPT DO AND DO NOT PROVE — the same caveat
///         `DeployTestnet` carries, and it has not weakened. `forge script --broadcast` simulates
///         the entire run first and only then sends the transactions it collected, so every
///         `require` below asserts the LOCAL SIMULATION's state. That is worth a great deal on a
///         live deployment — a misconfiguration aborts before a single transaction is broadcast,
///         rather than half-completing an unrepairable set of immutables next to vaults that
///         already hold real supply — but it is NOT the on-chain half of §9.
///
///         THE ON-CHAIN HALF IS DISCHARGED BY `script/VerifyTestnet.s.sol`, which is in the tree
///         now: it reads `deployments/46630.json` — the file this script just appended to — and
///         re-asserts every §9 item against the live chain for EVERY mirror in it, including the
///         one just added. Run it after this, and do not read "the transaction did not revert" as
///         evidence of anything.
///
/// @dev    THE `marketIndex` HONESTY WARNING. READ THIS BEFORE ADDING ANY MIRROR.
///         =====================================================================================
///         `marketIndex` IS AN IMMUTABLE ON THE VAULT (`cfg.marketIndex`) AND THERE IS NO SETTER.
///         Get it wrong and the vault hedges on the WRONG MARKET forever; the remedy is a new
///         vault, a new certificate token, and a migration for every holder.
///
///         ONLY TWO MARKET IDS ON THIS VENUE HAVE EVER BEEN READ LIVE FROM THE VENUE'S OWN API:
///         **TSLA = 16** and **NVDA = 15** (`docs/WHITEPAPER.md` §4.4, `api/v1/orderBookDetails`,
///         2026-09-07; the design doc's §15.1 venue table is the same measurement). EVERY OTHER
///         ASSET'S MARKET ID IN THIS REPOSITORY IS UNCONFIRMED. That includes **uSPY's 26, which
///         IS ALREADY LIVE** and was never venue-verified either, and it includes **uQQQ's 27**,
///         which is a PLACEHOLDER chosen only so as not to collide with 15, 16 and 26.
///
///         ON THE SIMULATOR THIS IS HARMLESS AND THAT IS EXACTLY THE TRAP.
///         `LighterSim.setMarkPrice(marketIndex, px)` writes a mapping, so it IMPLICITLY CREATES
///         whatever market index it is handed. An unverified index therefore deploys clean, passes
///         every read-back in this file and in `VerifyTestnet`, mints, hedges and settles — while
///         being a market that does not exist. On the REAL venue the same number pushes ANOTHER
///         market's mark and leaves the intended one frozen, which is precisely the failure
///         `script/FeedKeeper.s.sol`'s NatSpec warns about at length: a hedge that fills in the
///         wrong book, a `solvency().deltaBps` that drifts without limit, and nothing on-chain
///         looking wrong.
///
///         SO IT IS RECORDED, NOT PAPERED OVER. Every mirror carries `marketIndexVerified` in the
///         address book, and `_marketIndexVerified()` below returns `true` for 15 and 16 and
///         `false` for everything else. BEFORE ANY MAINNET DEPLOYMENT, OR BEFORE POINTING A REAL
///         VENUE AT ANY MIRROR WHOSE FLAG IS `false`, re-read `market_id` from
///         `api/v1/orderBookDetails` and redeploy the mirror if it differs. The flag is not a
///         disclaimer; it is a work item.
///         =====================================================================================
///
/// @dev    A SECOND HONESTY NOTE, ON `singleSource` — smaller, but in the same family.
///         `parameters.singleSource` is `false` for this deployment and CANNOT be `true` here: at
///         `deviationBps = 500` a single-source `CertOracle` reverts at construction
///         (`MAX_SINGLE_SOURCE_DEVIATION_BPS = 200`). `false` DECLARES the feed and the venue mark
///         to be independent sources.
///
///         `DeployTestnet`'s own NatSpec is careful that on testnet that independence is
///         ORGANISATIONAL (two keys), never economic, since both keepers are ours. For uQQQ and
///         uNVDA there is a further gap worth stating rather than softening: `docs/TESTNET-PLAN.md`
///         picked SPY over NVDA *precisely because SPY has a live Chainlink mainnet feed and NVDA
///         does not*, and the feed leg here is a `ReplayAggregator` replaying real mainnet prints.
///         For a mirror with no mainnet feed to replay, whatever the operator feeds
///         `script/FeedKeeper.s.sol` is a price of their own choosing. The basis band is still
///         WIRED and still checked; it is simply weaker evidence for these two mirrors than for
///         uTSLA and uSPY. Not a reason to flip the bit — flipping it would be a lie in the other
///         direction and would not compile at 500 bps anyway — a reason not to cite uNVDA's green
///         basis as proof of anything.
///
/// @dev    USAGE — ONE MIRROR PER INVOCATION, selected by symbol.
///
///           bash script/check-sizes.sh          # the EIP-170 gate, first
///
///           export DEPLOYER_PK=0x... GOV_PK=0x... ATTESTER_PK=0x...
///           MIRROR=uQQQ COMMIT=$(git rev-parse HEAD) \
///             forge script script/AddMirror.s.sol \
///               --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast --slow
///
///           forge script script/VerifyTestnet.s.sol --rpc-url ...   # §9, on chain
///
///         `--slow` is NOT optional. The run spans three senders and later transactions depend on
///         earlier ones having landed — the `CertOracle` constructor reads the `ReplayAggregator`
///         deployed one phase earlier, and `bootstrap()` needs the allowlist row to exist.
///
///         `MIRROR` selects a row from the hardcoded table in `_loadAsset()`; an unknown symbol is
///         a named revert and never a default. Adding a THIRD mirror means adding a row there, in
///         Solidity, reviewed — not passing numbers on a command line. Which is the same decision
///         `DeployTestnet` documents for `script/config/testnet.json`: a mistyped key yields zero,
///         and `absoluteCap18 = 0` means "no capacity" while `deviationBps = 0` locks minting shut.
///         The compiler is the source of truth; the JSON is documentation.
contract AddMirror is Script {
    // ---------------------------------------------------------------------------------- errors

    /// @dev Guarded so the script cannot be pointed at mainnet by accident, exactly as
    ///      `DeployTestnet` is. Mainnet's chain ID is still UNVERIFIED
    ///      (`docs/TESTNET-PLAN.md` §8), which is a second reason this is an equality and not a
    ///      "not mainnet" test.
    error AddMirror_WrongChain(uint256 actual, uint256 expected);
    /// @dev `MIRROR` named no row in `_loadAsset()`'s table. Never falls back to a default: a
    ///      script that guessed which mirror to deploy would deploy the wrong one from a typo.
    error AddMirror_UnknownMirror(string symbol);
    /// @dev The symbol is already in the address book. Re-running this script for a mirror that
    ///      exists would deploy a SECOND vault and a SECOND certificate token under the same
    ///      ticker and append it, leaving two records a UI cannot choose between. Adding a mirror
    ///      is not idempotent and must not pretend to be.
    error AddMirror_AlreadyInBook(string symbol);
    /// @dev The book records a market index that this run is about to reuse for a different vault.
    ///      Two vaults on one market index would hedge into the same book and share a mark while
    ///      publishing separate solvency — and on the simulator it would deploy perfectly clean.
    error AddMirror_MarketIndexTaken(uint256 marketIndex, string takenBy);

    // ------------------------------------------------------------------------------- the chain

    uint256 internal constant CHAIN_ID = 46_630;

    // ----------------------------------------------------- shared parameters, and where they live
    //
    // EVERY VALUE BELOW IS IMMUTABLE AT THE VAULT OR THE ORACLE (Law 6: no setter, no upgrade
    // path), and every one of them ALREADY HAS A LIVE VALUE on this deployment. So unlike
    // `DeployTestnet`, where these constants are the only source of truth, here they are a CLAIM
    // that must agree with two things that already exist:
    //
    //   1. `parameters.*` in `deployments/46630.json` — asserted in `_requireParamsMatchBook()`.
    //   2. THE LIVE CONTRACTS of an existing mirror — asserted in `_requireParamsMatchChain()`.
    //
    // The chain check is the one that matters. The book is a local file that can be stale or hand-
    // edited; the deployed `CertOracle` of mirror 0 is what the protocol actually runs on. A mirror
    // added with a different `stalenessSeconds` or a different `targetMarginBps` is not a mirror of
    // the same system, and there is no setter to converge them afterwards.
    //
    // Values copied verbatim from `script/DeployTestnet.s.sol`. Read its NatSpec for WHY each one
    // is what it is; the reasoning is not duplicated here, because duplicated reasoning drifts.

    uint256 internal constant TARGET_MARGIN_BPS = 9_000;
    uint256 internal constant INSTANT_CAP_18 = 1_000e18;
    uint256 internal constant SETTLE_WINDOW = 1 days;
    uint256 internal constant SETTLE_BAND_BPS = 500;
    uint256 internal constant MINT_FEE_BPS = 10;
    uint256 internal constant REDEEM_FEE_BPS = 10;
    /// @dev TESTNET REACHABILITY VALUE. Mainnet is 93_600 (`docs/TESTNET-PLAN.md` §1). Must not be
    ///      carried over. See `DeployTestnet`'s constant for the full argument.
    uint256 internal constant STALENESS_SECONDS = 900;
    uint256 internal constant POKE_CONFIRMATION_SECONDS = 300;
    uint256 internal constant DEVIATION_BPS = 500;
    uint256 internal constant BASIS_BAND_BPS = 500;
    /// @dev See the `singleSource` honesty note in the contract NatSpec. Cannot be `true` at
    ///      `DEVIATION_BPS = 500`.
    bool internal constant SINGLE_SOURCE = false;
    uint256 internal constant DEPTH_BPS = 1_000;
    uint256 internal constant MAX_ATTESTATION_AGE_SEC = 300;
    uint256 internal constant VENUE_WITHDRAW_CAP = type(uint64).max;
    uint8 internal constant FEED_DECIMALS = 8;
    uint16 internal constant COLLATERAL_ASSET_INDEX = 3;
    uint8 internal constant ROUTE_TYPE = 0;
    uint8 internal constant COLLATERAL_DECIMALS = 6;

    /// @dev What the deployer seeds into the new mirror's buffer. Must be >= `10 ** decimals` or
    ///      `bootstrap()` reverts, and MATCHES THE EXISTING TWO MIRRORS at 100_000e6 — a mirror
    ///      seeded differently would publish a `bufferCapacity18()` that is not comparable with
    ///      its siblings' for no reason a reader of the numbers could see.
    uint256 internal constant SEED_COLLATERAL = 100_000e6;

    /// @dev The FIRST attestation's batch id. `SolvencyRegistry.attest` requires strictly
    ///      increasing ids PER ASSET (`SolvencyRegistry_StaleBatch`) and the mapping is keyed by
    ///      the VAULT address, so a brand-new vault starts at 1 exactly as `DeployTestnet` seeds
    ///      it — it does not have to continue the existing mirrors' batch numbering, and must not
    ///      try to.
    uint64 internal constant SEED_BATCH_ID = 1;

    // ------------------------------------------------------------------------------- the asset

    /// @dev Same shape as `DeployTestnet.AssetParams`, plus the one field that file has no place
    ///      for: whether `marketIndex` was read off the venue or chosen. See the contract NatSpec.
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

    AssetParams internal a;

    // deployed this run
    address internal newAggregator;
    address internal newOracle;
    address internal newVault;
    address internal newCertificate;
    address internal newBufferBook;

    // ------------------------------------------------------------------- the book, as it stands

    /// @dev One mirror record, held as the book's OWN BYTES for the three big numbers. They are
    ///      quoted strings in the file (they exceed 2^53 and would lose precision in any
    ///      JavaScript consumer — the front-end adapter reads this file), and echoing the string
    ///      back verbatim means a re-emitted record cannot differ from the record that was read.
    ///      A parse-then-reserialise round trip on a LIVE address book buys nothing and can only
    ///      lose.
    struct BookMirror {
        string symbol;
        string name;
        uint256 marketIndex;
        uint256 priceDecimals;
        uint256 sizeDecimals;
        address vault;
        address certificate;
        address bufferBook;
        address certOracle;
        address replayAggregator;
        string seedPrice18;
        string absoluteCap18;
        string seedOpenInterest18;
        bool marketIndexVerified;
    }

    BookMirror[] internal bookMirrors;

    // shared addresses, READ FROM THE BOOK and never from the environment
    address internal collateral;
    address internal testFaucet;
    address internal lighter;
    address internal registry;
    address internal capacity;
    address internal factory;
    address internal batchKeeper;

    // senders recorded in the book
    address internal bookDeployer;
    address internal bookGov;
    address internal bookAttester;

    // senders derived from the operator's keys
    address internal deployerAddr;
    address internal govAddr;
    address internal attesterAddr;

    /// @dev Bound on the mirror probe. Same value and same reason as
    ///      `script/VerifyTestnet.s.sol`'s: a truncated or malformed book must not make the loop
    ///      run away, and exceeding the bound is an explicit error rather than a silent truncation
    ///      that would drop a live mirror from the book this script rewrites.
    uint256 internal constant MAX_MIRRORS = 64;

    // --------------------------------------------------------------- injection seams, for tests

    /// @dev The three senders. NEVER hardcoded, logged, or derived from a mnemonic here. Behind a
    ///      `virtual` seam for the same reason `DeployTestnet`'s is: `vm.setEnv` writes
    ///      process-global state Foundry does not roll back between test cases, so a test varies
    ///      this by SUBCLASSING. Production behaviour is unchanged.
    function _senderKeys() internal view virtual returns (uint256 deployerPk, uint256 govPk, uint256 attesterPk) {
        return (vm.envUint("DEPLOYER_PK"), vm.envUint("GOV_PK"), vm.envUint("ATTESTER_PK"));
    }

    function _bookPath() internal view virtual returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }

    /// @dev The FILE READ is virtual, not the parse — the same decision, for the same reason, as
    ///      `script/VerifyTestnet.s.sol` and `script/keepers/KeeperScript.sol`. A test overriding
    ///      this still runs every line of the real parser. A test handing in a struct would test
    ///      nothing.
    function _bookJson() internal view virtual returns (string memory) {
        return vm.readFile(_bookPath());
    }

    function _selectedMirror() internal view virtual returns (string memory) {
        return vm.envString("MIRROR");
    }

    // ------------------------------------------------------------------------------------- run

    function run() external {
        if (block.chainid != CHAIN_ID) revert AddMirror_WrongChain(block.chainid, CHAIN_ID);

        (uint256 deployerPk, uint256 govPk, uint256 attesterPk) = _senderKeys();
        deployerAddr = vm.addr(deployerPk);
        govAddr = vm.addr(govPk);
        attesterAddr = vm.addr(attesterPk);

        // Three DISTINCT senders. Collapsing any two silently defeats §4's separation: with
        // governance == deployer, "governance is a multisig" stops being true and the emergency
        // `setAbsoluteCap(vault, 0)` lever sits on the same key that ran the deployment.
        require(deployerAddr != govAddr, "SENDERS: deployer == governance");
        require(deployerAddr != attesterAddr, "SENDERS: deployer == attester");
        require(govAddr != attesterAddr, "SENDERS: governance == attester");

        _loadAsset(_selectedMirror());
        _loadBook();

        // AND THE SAME THREE THE LIVE DEPLOYMENT ALREADY USES. This check has no counterpart in
        // `DeployTestnet` because it cannot: that script CREATES the deployment, so whatever keys
        // it is handed become the right ones by definition. Here the answer already exists, and a
        // mirror added under a different key set would be a second protocol wearing the first
        // one's address book.
        require(deployerAddr == bookDeployer, "SENDERS: DEPLOYER_PK != senders.deployer in the book");
        require(govAddr == bookGov, "SENDERS: GOV_PK != senders.governance in the book - SPLIT GOVERNANCE");
        require(attesterAddr == bookAttester, "SENDERS: ATTESTER_PK != senders.attester in the book");

        _requireBookMatchesChain();
        _requireParamsMatchBook();
        _requireParamsMatchChain();
        _requireAssetSane();

        // ------------------------------------------------------------------- phase 1: deployer
        vm.startBroadcast(deployerPk);
        _phase1_fundAndFeed();
        vm.stopBroadcast();

        // ----------------------------------------------------------------- phase 2: GOVERNANCE
        //
        // §4, AND THE MOST IMPORTANT SIX LINES IN THIS FILE.
        //
        // `CertOracle` does `governance = msg.sender` in its constructor and the field is
        // IMMUTABLE. Under `vm.startBroadcast(govPk)` a `new CertOracle(...)` written HERE — in
        // `run()`'s own frame, at depth 1 — is sent as a bare CREATE from the governance EOA, so
        // `msg.sender` inside the constructor is `govAddr`.
        //
        // MOVE THIS INTO A HELPER CONTRACT AND THE MIRROR IS PERMANENTLY BROKEN: `msg.sender`
        // becomes the helper's address, governance lands somewhere nobody controls, attester
        // rotation is unreachable forever, and the only remedy is redeploying the mirror — a new
        // certificate token, and a migration for anyone already holding the old one. Same for a
        // CREATE2 factory. It stays written out inline, in this frame, on purpose.
        //
        // Note the constructor also READS the aggregator and refuses a feed already older than
        // `STALENESS_SECONDS` (L-4), which is the other reason `--slow` is mandatory: phase 1's
        // `ReplayAggregator` has to have landed for this to see a live round.
        vm.startBroadcast(govPk);

        newOracle = address(
            new CertOracle(
                newAggregator,
                attesterAddr,
                a.priceDecimals,
                STALENESS_SECONDS,
                DEVIATION_BPS,
                BASIS_BAND_BPS,
                POKE_CONFIRMATION_SECONDS,
                SINGLE_SOURCE
            )
        );

        vm.stopBroadcast();

        // ------------------------------------------------------------------- phase 3: deployer
        vm.startBroadcast(deployerPk);
        _phase3_vault();
        vm.stopBroadcast();

        // ----------------------------------------------------------------- phase 4: governance
        vm.startBroadcast(govPk);
        _phase4_governance();
        vm.stopBroadcast();

        // ------------------------------------------------- phase 5: deployer / venue operator
        vm.startBroadcast(deployerPk);
        _phase5_allowlistMarkAndBootstrap();
        vm.stopBroadcast();

        // ------------------------------------------------------------------- phase 6: attester
        vm.startBroadcast(attesterPk);
        _phase6_attest();
        vm.stopBroadcast();

        // ------------------------------------------------------------- verify, then write it down
        _verifyLocalSimulation();
        _appendToAddressBook();
        _report();
    }

    // ------------------------------------------------------------------------------- phase 1

    /// @dev Self-funding, and the mirror's own feed. NOTHING SHARED IS DEPLOYED HERE — no
    ///      collateral token, no faucet, no `LighterSim`. That is the whole difference between this
    ///      script and `DeployTestnet._phase1_simulators()`, and it is why `collateral` and
    ///      `lighter` are read from the book above and merely USED here.
    function _phase1_fundAndFeed() internal virtual {
        // The deployer IS `TestUSDG.owner` (asserted on chain in `_requireParamsMatchChain`), so
        // it can mint what phase 5 is about to spend. It holds a working float rather than a
        // treasury, so mint THE SHORTFALL and not a round number: `TestUSDG` is the asset every
        // vault's solvency is denominated in, and inflating it further than the step needs makes
        // the token's supply story harder to read for no gain. If the deployer already holds
        // enough, nothing is minted at all.
        uint256 held = IERC20(collateral).balanceOf(deployerAddr);
        if (held < SEED_COLLATERAL) {
            TestUSDG(collateral).mint(deployerAddr, SEED_COLLATERAL - held);
        }
        require(
            IERC20(collateral).balanceOf(deployerAddr) >= SEED_COLLATERAL,
            "FUND: deployer still short of SEED_COLLATERAL - seedBuffer would revert on an ERC20 balance"
        );

        // The mirror's own feed. `ReplayAggregator` — NOT `MockAggregatorV3`, which is a test mock
        // and not deployable scaffolding. It writes round 1 in its own constructor so `roundId`
        // starts at a real value, and `roundId` STRICTLY INCREMENTS on every write, which is
        // load-bearing: §2 makes `pokeLastGood`'s round-distinctness proof `roundId >
        // pendingRoundId`, so a feed serving a constant `roundId` freezes H-1's reference
        // permanently.
        //
        // Owner is the DEPLOYER, not the attester, and that is the point: the attester writes
        // `markPx18`, so giving it the feed too would make the two "independent" sources one key
        // and `singleSource == false` a lie. `script/FeedKeeper.s.sol` must be invoked with
        // DEPLOYER_PK, and it selects this mirror BY THIS AGGREGATOR ADDRESS once the book records
        // it.
        newAggregator =
            address(new ReplayAggregator(deployerAddr, FEED_DECIMALS, a.feedDescription, _toFeedAnswer(a.seedPx18)));
    }

    // ------------------------------------------------------------------------------- phase 3

    /// @dev The vault, from the deployer. `CapacityOracle` and `CertFactory` are NOT redeployed —
    ///      they are shared, they are already live, and they came out of the book.
    function _phase3_vault() internal virtual {
        // Deployed DIRECTLY, never through `CertFactory.deployVault` — that reverts
        // `CertFactory_UseRegisterVault` by construction, because no contract can `new CertVault`
        // under EIP-170: the creation code is 25,743 B and an embedding contract would have to fit
        // that inside the 24,576 B RUNTIME ceiling (`docs/DEPLOYMENT-CHECKLIST.md` §0).
        //
        // The four `Deps` addresses MUST be the same four the factory holds. `registerVault` does
        // NOT check this for you and a mismatch is not repairable — every dependency on both sides
        // is immutable. Asserted in `_verifyLocalSimulation` and again on-chain by `VerifyTestnet`.
        CertVault v = new CertVault(
            CertVault.Deps({
                lighter: lighter,
                oracle: newOracle,
                registry: registry,
                capacity: capacity,
                governance: govAddr
            }),
            CertVault.VaultConfig({
                collateral: collateral,
                collateralAssetIndex: COLLATERAL_ASSET_INDEX,
                routeType: ROUTE_TYPE,
                marketIndex: a.marketIndex,
                sizeDecimals: a.sizeDecimals,
                mintFeeBps: MINT_FEE_BPS,
                redeemFeeBps: REDEEM_FEE_BPS,
                instantCap18: INSTANT_CAP_18,
                settleBandBps: SETTLE_BAND_BPS,
                targetMarginBps: TARGET_MARGIN_BPS
            }),
            VENUE_WITHDRAW_CAP,
            SETTLE_WINDOW,
            a.name,
            a.symbol
        );
        newVault = address(v);
        // The vault's constructor deployed both of these. Read them back — the certificate address
        // is needed for `registerVault`, which cross-checks it.
        newCertificate = address(v.certificate());
        newBufferBook = address(v.buffer());
    }

    // ------------------------------------------------------------------------------- phase 4

    /// @dev The governance phase, in §5's order.
    function _phase4_governance() internal virtual {
        // §6 step 4. Records the vault in `vaults`/`isVault` and cross-checks the certificate.
        // Reverts `CertFactory_AlreadyRegistered` if this vault were somehow already in — which is
        // a genuine safety net for a re-run, on top of `AddMirror_AlreadyInBook`.
        CertFactory(factory).registerVault(newVault, newCertificate);

        // §6 step 5, AND THE SINGLE MOST LIKELY WAY A NEW MIRROR APPEARS BROKEN.
        //
        // `absoluteCap18` is ZERO by default and `maxNotional18`'s `min()` makes zero mean "NO
        // CAPACITY" — not "unbounded". There is deliberately no first-call exception for a stranger
        // to bootstrap it. So a vault that reads as perfectly deployed — registered, bootstrapped,
        // attested, `mintAllowed() == true` — still reverts `CertVault_AtCapacity` on every mint
        // until this line runs. It is read back below, and again on chain by `VerifyTestnet`.
        CapacityOracle(capacity).setAbsoluteCap(newVault, a.absoluteCap18);

        // M-2: the published buffer ladder, retuned off THIS asset's book size rather than left at
        // the constructor's 100k/60k/30k defaults, which are the same for every asset regardless
        // of size and are meaningless against a small book. Buffer is ~10% of capacity and the
        // 100/60/30/0 RATIO is preserved. These gate nothing — a reporting choice per §5 — and
        // `BufferBook.configure` requires them non-increasing.
        CertVault(newVault).setBufferThresholds(a.bufferFloor18, a.bufferFeeOn18, a.bufferMintSlow18, 0);
    }

    // ------------------------------------------------------------------------------- phase 5

    /// @dev Allowlist, venue mark, collateral, bootstrap, batch advance — from the deployer, which
    ///      is also the simulator's owner. THE ORDER IS `DeployTestnet._phase5_...`'s ORDER and
    ///      every step of it is load-bearing.
    function _phase5_allowlistMarkAndBootstrap() internal virtual {
        // ============================== BEFORE `bootstrap()`, ALWAYS =============================
        // `bootstrap()` REVERTS `LighterSim_DepositorNotAllowed(vault)` WITHOUT THIS LINE. The
        // allowlist is Task 5's interim fix for the self-registration drain (Critical 1: a
        // zero-value `transferFrom` succeeds with no allowance and no balance, so registration used
        // to be free rather than merely open). It FAILS CLOSED, which is right, and it is a
        // deployment step nothing in the vault's own interface hints at.
        //
        // SIMULATOR-ONLY. It has no counterpart on the real venue, which registers anyone, and must
        // never be read as modelling one.
        // =====================================================================================
        LighterSim(lighter).setDepositorAllowed(newVault, true);

        // The VENUE's own mark, distinct from `CertOracle.markPx18`. `LighterSim.settleBatch`
        // refuses outright to settle a market whose mark is unset, and that guard exists because at
        // a zero mark the simulator is not merely missing a margin check — the whole mark-to-market
        // layer is DEAD: notional is `|position| * 0` so the `InsufficientMargin` gate passes
        // vacuously at any size, and `entryPrice = 0` makes `unrealisedPnl()` permanently zero. A
        // script that forgot this would look completely clean while certifying the vault against a
        // venue with no margin requirement and no PnL.
        //
        // AND SEE THE `marketIndex` WARNING IN THE CONTRACT NATSPEC. This mapping write IMPLICITLY
        // CREATES `a.marketIndex` on the simulator, so an unverified index deploys perfectly clean
        // here and pushes the WRONG market's mark on a real venue.
        LighterSim(lighter).setMarkPrice(a.marketIndex, a.seedPx18);

        // §6 step 6: collateral IN BEFORE `bootstrap()`. `bootstrap()` deposits exactly
        // `10 ** collateralDecimals` as registering dust and reverts without it. `seedBuffer` is
        // the permissionless way in and also lifts `bufferCapacity18()` off zero, which is one of
        // the three legs of `maxNotional18`'s `min()`.
        IERC20(collateral).approve(newVault, SEED_COLLATERAL);
        CertVault(newVault).seedBuffer(SEED_COLLATERAL);

        // §6 step 7. One-time, permissionless.
        CertVault(newVault).bootstrap();

        // §6 step 8: THE BATCH ADVANCE.
        //
        // `LighterSim.setKeeper` IS NOT CALLED HERE and must not be. The keeper is a SHARED
        // simulator-level setting, it is already registered (asserted against the book in
        // `_requireParamsMatchChain`), and re-registering it from a mirror-add script is how a
        // shared setting silently acquires a per-mirror history. This call is the deployer's own,
        // and the deployer is the simulator's owner, so it needs no keeper registration to succeed.
        //
        // `createOrder` reverts `AccountIsNotRegistered` until `addressToAccountIndex[vault]` is
        // populated, so every mint would revert as one atomic transaction until the registering
        // deposit has been EXECUTED by a batch.
        //
        // TO BE PRECISE ABOUT WHAT IS AND IS NOT IN THE TREE: `LighterCore.deposit` still assigns
        // `addressToAccountIndex` inline, so registration is SYNCHRONOUS as shipped and
        // `bootstrap()` alone already populates the index. This call is therefore
        // FORWARD-COMPATIBLE rather than currently load-bearing — and the §9 read-back
        // `lighterAccountIndex() != 0` passes whether or not it ran, so neither that read-back nor
        // any test establishes "the batch advance is what registered the vault" today. Stated
        // rather than repaired, exactly as `DeployTestnet` states it.
        //
        // IT IS ALSO THE ONE CALL IN THIS SCRIPT THAT TOUCHES STATE BELONGING TO THE OTHER,
        // ALREADY-LIVE MIRRORS: `settleBatch()` drains the SHARED queue and fills whatever is in it
        // at the current mark, so on a live deployment with a stopped `BatchAdvancer` it settles
        // other vaults' pending orders too. That is exactly what the keeper does on an interval, so
        // it is not a new kind of action — but the queue length is logged either side of it in
        // `_report()` so the effect is recorded rather than assumed to be nil.
        LighterSim(lighter).settleBatch();
    }

    // ------------------------------------------------------------------------------- phase 6

    /// @dev §6 step 9. Attest once and set the mark so `maxNotional18` and `mintAllowed()` are
    ///      live for the new mirror. Nothing else in this run is sent by this key.
    function _phase6_attest() internal virtual {
        // `asset` is keyed by the VAULT address, not the certificate and not the market index, so
        // this attestation is the new vault's own and does not disturb the existing mirrors'.
        //
        // `notional18` and `margin18` are 0 because the vault has no position yet — it has minted
        // nothing. `_requireCapacity` takes `max(own18, attested18)`, so a non-zero seed here would
        // fabricate exposure that does not exist and eat real capacity.
        SolvencyRegistry(registry).attest(newVault, SEED_BATCH_ID, 0, 0, a.openInterest18);

        // `CertOracle.markPx18`: the venue-side price the basis band is measured against. Seeded
        // equal to the feed, so the basis is 0 bps at deployment and well inside the 500 bps band.
        // It has NO timestamp and NO staleness check anywhere (§2) — its liveness is an operational
        // assumption on the attester keeper's cadence, not a contract guarantee.
        CertOracle(newOracle).setMarkPrice(a.seedPx18);
    }

    // ------------------------------------------------------------------- the asset table

    /// @dev THE MIRROR TABLE. Hardcoded, in Solidity, reviewed — see the contract NatSpec on why
    ///      this is not read from `script/config/testnet.json`.
    function _loadAsset(string memory symbol) internal virtual {
        bytes32 k = keccak256(bytes(symbol));

        if (k == keccak256("uQQQ")) {
            a = AssetParams({
                name: "UseCert QQQ",
                symbol: "uQQQ",
                feedDescription: "RHQQQ / USD",
                // ================ PLACEHOLDER. NOT VENUE-VERIFIED. SEE THE CONTRACT NATSPEC ======
                // Chosen only so as not to collide with 15 (NVDA), 16 (TSLA) or 26 (uSPY, itself
                // unverified). The design doc's §15.1 venue table says market index is "still to
                // confirm" for every asset except TSLA and NVDA. Recorded as
                // `marketIndexVerified: false` in the address book, and it is a WORK ITEM, not a
                // disclaimer: re-read `market_id` from `api/v1/orderBookDetails` before this mirror
                // is pointed at a real venue, and redeploy it if the number differs.
                // =================================================================================
                marketIndex: 27,
                // `price_decimals` 2 / `size_decimals` 4, per the design doc §15.1 venue table.
                // `size_decimals` MUST match the shared `LighterSim`'s single per-simulator value —
                // asserted against the live simulator in `_requireAssetSane()`.
                priceDecimals: 2,
                sizeDecimals: 4,
                // $716.31, the real QQQ close on 2026-09-10.
                seedPx18: 716.31e18,
                // `docs/TESTNET-PLAN.md` §1's capacity table: QQQ $3.05M at 10% depth (second only
                // to SPY's $5.00M across all 57 markets). This is the capacity the vault is sized
                // from, so `absoluteCap18` and the depth leg agree at deployment rather than one
                // being decorative.
                absoluteCap18: 3_050_000e18,
                // The attester's seed figure. $30.5M of OI * DEPTH_BPS (1000) = the $3.05M above.
                openInterest18: 30_500_000e18,
                // Buffer is 10% of `absoluteCap18` with the 100/60/30/0 ratio preserved, the same
                // shape both live mirrors use. Non-increasing, as `BufferBook.configure` requires.
                bufferFloor18: 305_000e18,
                bufferFeeOn18: 183_000e18,
                bufferMintSlow18: 91_500e18
            });
            return;
        }

        if (k == keccak256("uNVDA")) {
            a = AssetParams({
                name: "UseCert NVDA",
                symbol: "uNVDA",
                feedDescription: "RHNVDA / USD",
                // VENUE-VERIFIED. `docs/WHITEPAPER.md` §4.4 / design doc §15.1: NVDA `market_id`
                // 15, read live from `api/v1/orderBookDetails` on 2026-09-07, active. One of only
                // TWO market ids in this repository that were ever actually measured.
                marketIndex: 15,
                priceDecimals: 2,
                sizeDecimals: 4,
                // $223.67, the real NVDA close on 2026-09-10. Sanity-checks against the $232.46
                // implied by the recorded 2026-09-07 order book ($2.88M OI / 12,389 shares) —
                // a 3.8% difference over three sessions, which is ordinary for NVDA.
                seedPx18: 223.67e18,
                // `docs/TESTNET-PLAN.md` §1's capacity table: NVDA $311k at 10% depth.
                //
                // A RECONCILIATION NOTE, because the two figures in this repository do not agree
                // exactly and pretending they do is how a number stops being checkable:
                // `docs/WHITEPAPER.md` §4.4's live 2026-09-07 book puts NVDA OI at ~$2.88M, whose
                // 10% is $288k, not $311k. The capacity table is the figure every capacity number
                // in the plan is quoted at and is what the sibling mirrors were sized from, so it
                // is what is used here; the $23k gap is OI drift between two readings of a moving
                // book, not a derivation error. `openInterest18` below is back-derived from the
                // table so the depth leg and `absoluteCap18` agree, exactly as they do for uTSLA
                // and uSPY.
                absoluteCap18: 311_000e18,
                // $3.11M of OI * DEPTH_BPS (1000) = the $311k above.
                openInterest18: 3_110_000e18,
                bufferFloor18: 31_100e18,
                bufferFeeOn18: 18_660e18,
                bufferMintSlow18: 9_330e18
            });
            return;
        }

        revert AddMirror_UnknownMirror(symbol);
    }

    /// @dev WAS THIS MARKET INDEX READ OFF THE VENUE, OR CHOSEN? The whole answer, in one place.
    ///
    ///      `true` for exactly the two ids `docs/WHITEPAPER.md` §4.4 records from a live
    ///      `api/v1/orderBookDetails` call on 2026-09-07 — TSLA 16 and NVDA 15 — and `false` for
    ///      everything else, INCLUDING uSPY's 26, which is already live and was never verified.
    ///      Written as a whitelist rather than a per-asset flag so that a new mirror cannot be
    ///      added with an unverified index and a `true` beside it.
    function _marketIndexVerified(uint256 marketIndex) internal pure returns (bool) {
        return marketIndex == 15 || marketIndex == 16;
    }

    // -------------------------------------------------------------------- the book, as it stands

    function _loadBook() internal {
        string memory json = _bookJson();

        require(
            vm.parseJsonUint(json, ".chainId") == block.chainid,
            "BOOK: chainId != the chain this RPC is on - wrong book or wrong RPC"
        );

        bookDeployer = vm.parseJsonAddress(json, ".senders.deployer");
        bookGov = vm.parseJsonAddress(json, ".senders.governance");
        bookAttester = vm.parseJsonAddress(json, ".senders.attester");

        collateral = vm.parseJsonAddress(json, ".shared.collateral");
        testFaucet = vm.parseJsonAddress(json, ".shared.testFaucet");
        lighter = vm.parseJsonAddress(json, ".shared.lighterSim");
        registry = vm.parseJsonAddress(json, ".shared.solvencyRegistry");
        capacity = vm.parseJsonAddress(json, ".shared.capacityOracle");
        batchKeeper = vm.parseJsonAddress(json, ".shared.batchKeeper");
        factory = vm.parseJsonAddress(json, ".shared.certFactory");

        _loadBookMirrors(json);
    }

    function _loadBookMirrors(string memory json) private {
        // MIRRORS ARE COUNTED BY PROBING `.vaults[i]`, NOT BY READING A COLUMN WITH `[*]`.
        // `vm.parseJsonAddressArray(json, ".vaults[*].vault")` is wrong in the single-mirror case:
        // Foundry's jsonpath collapses a one-element match to a scalar and the array parse fails
        // with `expected [`. `script/keepers/KeeperScript.sol` found this by running it and
        // `script/VerifyTestnet.s.sol` uses the same probe; so does this.
        uint256 n;
        while (n < MAX_MIRRORS && vm.keyExistsJson(json, _vaultKey(n, "vault"))) {
            ++n;
        }
        require(n != 0, "BOOK: no vaults in the address book - this script APPENDS, it cannot bootstrap");
        require(
            !vm.keyExistsJson(json, _vaultKey(n, "vault")),
            "BOOK: more than MAX_MIRRORS vaults - raise the bound rather than dropping a live mirror"
        );

        for (uint256 i = 0; i < n; ++i) {
            bookMirrors.push(
                BookMirror({
                    symbol: vm.parseJsonString(json, _vaultKey(i, "symbol")),
                    name: vm.parseJsonString(json, _vaultKey(i, "name")),
                    marketIndex: vm.parseJsonUint(json, _vaultKey(i, "marketIndex")),
                    priceDecimals: vm.parseJsonUint(json, _vaultKey(i, "priceDecimals")),
                    sizeDecimals: vm.parseJsonUint(json, _vaultKey(i, "sizeDecimals")),
                    vault: vm.parseJsonAddress(json, _vaultKey(i, "vault")),
                    certificate: vm.parseJsonAddress(json, _vaultKey(i, "certificate")),
                    bufferBook: vm.parseJsonAddress(json, _vaultKey(i, "bufferBook")),
                    certOracle: vm.parseJsonAddress(json, _vaultKey(i, "certOracle")),
                    replayAggregator: vm.parseJsonAddress(json, _vaultKey(i, "replayAggregator")),
                    // Echoed back as the book's own strings. See `BookMirror`.
                    seedPrice18: vm.parseJsonString(json, _vaultKey(i, "seedPrice18")),
                    absoluteCap18: vm.parseJsonString(json, _vaultKey(i, "absoluteCap18")),
                    seedOpenInterest18: vm.parseJsonString(json, _vaultKey(i, "seedOpenInterest18")),
                    // OPTIONAL, because the field did not exist when the live book was written.
                    // Absent means "never recorded", NOT "verified" — so it is derived from the
                    // whitelist rather than defaulted to `true`, which is what makes uSPY's 26
                    // show up as `false` the first time this script rewrites the book.
                    marketIndexVerified: vm.keyExistsJson(json, _vaultKey(i, "marketIndexVerified"))
                        ? vm.parseJsonBool(json, _vaultKey(i, "marketIndexVerified"))
                        : _marketIndexVerified(vm.parseJsonUint(json, _vaultKey(i, "marketIndex")))
                })
            );
        }
    }

    function _vaultKey(uint256 i, string memory field) private pure returns (string memory) {
        return string.concat(".vaults[", vm.toString(i), "].", field);
    }

    // ------------------------------------------------------------- pre-flight gates, before any tx

    /// @dev THE ONE THING THE BOOK CANNOT PROVE ABOUT ITSELF. `vm.readFile` reads a LOCAL file: a
    ///      book generated against one deployment and left in the tree while a second deployment
    ///      happened elsewhere parses perfectly and names dead contracts. A new mirror wired to a
    ///      dead `CapacityOracle` would deploy, register nowhere useful, and never mint — with all
    ///      five of its immutables already fixed.
    function _requireBookMatchesChain() internal view {
        _requireCode(collateral, "collateral");
        _requireCode(lighter, "lighterSim");
        _requireCode(registry, "solvencyRegistry");
        _requireCode(capacity, "capacityOracle");
        _requireCode(factory, "certFactory");
        for (uint256 i = 0; i < bookMirrors.length; ++i) {
            _requireCode(bookMirrors[i].vault, "vault");
            _requireCode(bookMirrors[i].certificate, "certificate");
            _requireCode(bookMirrors[i].certOracle, "certOracle");
            _requireCode(bookMirrors[i].replayAggregator, "replayAggregator");
        }
        require(
            CertFactory(factory).vaultCount() == bookMirrors.length,
            "BOOK: factory.vaultCount() != vaults in the book - the book is stale, STOP and reconcile it"
        );
    }

    function _requireCode(address addr, string memory what) internal view {
        require(addr != address(0), string.concat("BOOK: records address(0) for ", what));
        require(addr.code.length > 0, string.concat("BOOK: no code at the book's ", what, " - stale book"));
    }

    /// @dev The constants in this file, against `parameters.*` in the book. Cheap, and it catches
    ///      the case where someone edited one and not the other.
    function _requireParamsMatchBook() internal view {
        string memory j = _bookJson();
        require(vm.parseJsonUint(j, ".parameters.targetMarginBps") == TARGET_MARGIN_BPS, "PARAM: targetMarginBps");
        require(
            vm.parseUint(vm.parseJsonString(j, ".parameters.instantCap18")) == INSTANT_CAP_18, "PARAM: instantCap18"
        );
        require(vm.parseJsonUint(j, ".parameters.settleWindow") == SETTLE_WINDOW, "PARAM: settleWindow");
        require(vm.parseJsonUint(j, ".parameters.settleBandBps") == SETTLE_BAND_BPS, "PARAM: settleBandBps");
        require(vm.parseJsonUint(j, ".parameters.mintFeeBps") == MINT_FEE_BPS, "PARAM: mintFeeBps");
        require(vm.parseJsonUint(j, ".parameters.redeemFeeBps") == REDEEM_FEE_BPS, "PARAM: redeemFeeBps");
        require(vm.parseJsonUint(j, ".parameters.stalenessSeconds") == STALENESS_SECONDS, "PARAM: stalenessSeconds");
        require(
            vm.parseJsonUint(j, ".parameters.pokeConfirmationSeconds") == POKE_CONFIRMATION_SECONDS,
            "PARAM: pokeConfirmationSeconds"
        );
        require(vm.parseJsonUint(j, ".parameters.deviationBps") == DEVIATION_BPS, "PARAM: deviationBps");
        require(vm.parseJsonUint(j, ".parameters.basisBandBps") == BASIS_BAND_BPS, "PARAM: basisBandBps");
        require(vm.parseJsonBool(j, ".parameters.singleSource") == SINGLE_SOURCE, "PARAM: singleSource");
        require(vm.parseJsonUint(j, ".parameters.depthBps") == DEPTH_BPS, "PARAM: depthBps");
        require(
            vm.parseJsonUint(j, ".parameters.maxAttestationAgeSec") == MAX_ATTESTATION_AGE_SEC,
            "PARAM: maxAttestationAgeSec"
        );
        require(
            vm.parseUint(vm.parseJsonString(j, ".parameters.venueWithdrawCap")) == VENUE_WITHDRAW_CAP,
            "PARAM: venueWithdrawCap"
        );
        require(vm.parseJsonUint(j, ".parameters.feedDecimals") == FEED_DECIMALS, "PARAM: feedDecimals");
        require(vm.parseJsonUint(j, ".shared.collateralDecimals") == COLLATERAL_DECIMALS, "PARAM: collateralDecimals");
    }

    /// @dev THE CHECK THAT ACTUALLY MATTERS, and the one the book cannot substitute for: the
    ///      constants in this file against the LIVE CONTRACTS of mirror 0 and the live shared
    ///      infrastructure. The book is a local file; these are what the protocol runs on.
    ///
    ///      Split in two only because `foundry.toml` sets `via_ir = false` and must not be changed
    ///      (Global Constraint 1), so the legacy codegen's stack limit binds — the same reason
    ///      `DeployTestnet._verifyAsset` is split into four.
    function _requireParamsMatchChain() internal view {
        _requireSharedMatchChain();
        _requireMirrorZeroMatchChain();
    }

    function _requireSharedMatchChain() internal view {
        // The roles this run is about to exercise, read off the live contracts. Every one of these
        // is a transaction in this script that would otherwise revert mid-run, AFTER some
        // immutables had already been deployed.
        require(IERC20Metadata(collateral).decimals() == COLLATERAL_DECIMALS, "CHAIN: collateral decimals != 6");
        require(TestUSDG(collateral).owner() == deployerAddr, "CHAIN: TestUSDG.owner != DEPLOYER - cannot mint seed");
        require(LighterSim(lighter).owner() == deployerAddr, "CHAIN: LighterSim.owner != DEPLOYER - cannot allowlist");
        require(CertFactory(factory).governance() == govAddr, "CHAIN: factory.governance != GOV - registerVault fails");
        require(
            CapacityOracle(capacity).governance() == govAddr, "CHAIN: capacity.governance != GOV - setAbsoluteCap fails"
        );
        require(
            SolvencyRegistry(registry).attester() == attesterAddr, "CHAIN: registry.attester != ATTESTER - attest fails"
        );
        require(
            SolvencyRegistry(registry).governance() == govAddr, "CHAIN: registry.governance != GOV - not our registry"
        );

        // The shared oracle's depth leg and its immutable ceiling. `absoluteCap18` above the
        // ceiling reverts `CapacityOracle_CapAboveCeiling` in phase 4.
        require(CapacityOracle(capacity).depthBps() == DEPTH_BPS, "CHAIN: capacity.depthBps != DEPTH_BPS");
        require(
            CapacityOracle(capacity).maxAttestationAgeSec() == MAX_ATTESTATION_AGE_SEC,
            "CHAIN: capacity.maxAttestationAgeSec"
        );
        require(
            a.absoluteCap18 <= CapacityOracle(capacity).maxAbsoluteCap(),
            "CHAIN: absoluteCap18 above capacity.maxAbsoluteCap - setAbsoluteCap would revert"
        );

        // The factory's four immutables are what the new vault's `Deps` must match. Checked HERE,
        // before the vault is constructed, rather than only afterwards: a mismatch found after
        // construction is a redeployment, because both sides are immutable.
        require(CertFactory(factory).lighter() == lighter, "CHAIN: factory.lighter != book lighterSim");
        require(CertFactory(factory).registry() == registry, "CHAIN: factory.registry != book solvencyRegistry");
        require(CertFactory(factory).capacity() == capacity, "CHAIN: factory.capacity != book capacityOracle");

        // The shared keeper. NOT set by this script — read back, so the run records that the
        // simulator's `settleBatch` gate still names the address the book publishes. A mismatch
        // means every `settleBatch` from the `BatchAdvancer` bot's key reverts
        // `LighterSim_OnlyOwnerOrKeeper`, indistinguishable from a dead keeper.
        require(
            LighterSim(lighter).keeper() == batchKeeper,
            "CHAIN: LighterSim.keeper() != shared.batchKeeper - the keeper bot's settleBatch reverts"
        );
    }

    function _requireMirrorZeroMatchChain() internal view {
        // MIRROR 0's LIVE ORACLE. The new mirror's `CertOracle` is constructed with the constants
        // in this file; if they disagree with what the existing mirrors run on, the new mirror is
        // not a mirror of the same system and no setter can converge them.
        CertOracle o = CertOracle(bookMirrors[0].certOracle);
        require(o.governance() == govAddr, "CHAIN: mirror0 oracle.governance != GOV - wrong key set entirely");
        require(o.attester() == attesterAddr, "CHAIN: mirror0 oracle.attester != ATTESTER");
        require(o.stalenessSeconds() == STALENESS_SECONDS, "CHAIN: mirror0 oracle.stalenessSeconds != ours");
        require(o.deviationBps() == DEVIATION_BPS, "CHAIN: mirror0 oracle.deviationBps != ours");
        require(o.basisBandBps() == BASIS_BAND_BPS, "CHAIN: mirror0 oracle.basisBandBps != ours");
        require(
            o.pokeConfirmationSeconds() == POKE_CONFIRMATION_SECONDS, "CHAIN: mirror0 oracle.pokeConfirmationSeconds"
        );
        require(o.singleSource() == SINGLE_SOURCE, "CHAIN: mirror0 oracle.singleSource != our declared mode");

        // MIRROR 0's LIVE VAULT — the economics half of `cfg()`, destructured on its own for the
        // legacy codegen's stack limit.
        (,,,,, uint256 cMintFee, uint256 cRedeemFee, uint256 cInstantCap, uint256 cBand, uint256 cMargin) =
            CertVault(bookMirrors[0].vault).cfg();
        require(cMintFee == MINT_FEE_BPS, "CHAIN: mirror0 cfg.mintFeeBps != ours");
        require(cRedeemFee == REDEEM_FEE_BPS, "CHAIN: mirror0 cfg.redeemFeeBps != ours");
        require(cInstantCap == INSTANT_CAP_18, "CHAIN: mirror0 cfg.instantCap18 != ours");
        require(cBand == SETTLE_BAND_BPS, "CHAIN: mirror0 cfg.settleBandBps != ours");
        require(cMargin == TARGET_MARGIN_BPS, "CHAIN: mirror0 cfg.targetMarginBps != ours - NEVER RELAX 9000");
        require(
            CertVault(bookMirrors[0].vault).settleWindow() == SETTLE_WINDOW, "CHAIN: mirror0 vault.settleWindow != ours"
        );
        require(
            CertVault(bookMirrors[0].vault).venueWithdrawCap() == VENUE_WITHDRAW_CAP,
            "CHAIN: mirror0 vault.venueWithdrawCap != ours"
        );
    }

    /// @dev The selected asset against the book and the live simulator, BEFORE anything is
    ///      broadcast. Each of these is a way to add a mirror that deploys perfectly cleanly and is
    ///      wrong.
    function _requireAssetSane() internal view {
        // NOT ALREADY THERE. A re-run would otherwise deploy a second vault and a second
        // certificate token under the same ticker and append it, leaving two records a UI cannot
        // choose between and real balances split across them.
        for (uint256 i = 0; i < bookMirrors.length; ++i) {
            if (keccak256(bytes(bookMirrors[i].symbol)) == keccak256(bytes(a.symbol))) {
                revert AddMirror_AlreadyInBook(a.symbol);
            }
            if (bookMirrors[i].marketIndex == a.marketIndex) {
                revert AddMirror_MarketIndexTaken(a.marketIndex, bookMirrors[i].symbol);
            }
        }

        // ONE `LighterSim` HAS ONE `sizeDecimals` WHILE THE VENUE HAS IT PER MARKET.
        // `DeployTestnet` requires all its assets agree with asset 0's for exactly this reason; the
        // incremental form of that check is against the LIVE simulator, which is stronger — it is
        // the value that actually quantises every hedge.
        require(
            LighterSim(lighter).sizeDecimals() == a.sizeDecimals,
            "ASSET: sizeDecimals != the live LighterSim's - one sim cannot serve two, deploy a second sim"
        );

        // `LighterCore.createOrder` reverts `MarketIndexTooHigh` above 254, so a vault configured
        // past it can never hedge and Law 1 is unsatisfiable for it. Immutable, so this must be
        // caught here.
        require(a.marketIndex <= 254, "ASSET: marketIndex > 254 - every createOrder reverts MarketIndexTooHigh");

        // The venue mark for this market must be UNSET. If it is not, some other market — or an
        // earlier attempt at this one — already owns the index on the shared simulator, and
        // overwriting it would move a mark something else is pricing against.
        require(
            LighterSim(lighter).markPrice(a.marketIndex) == 0,
            "ASSET: LighterSim.markPrice(marketIndex) is already set - the index is in use, STOP"
        );

        // The capacity table and the depth leg must AGREE, or one of them is decorative:
        // `maxNotional18` takes `min(openInterest18 * depthBps / 10000, absoluteCap18, buffer)`.
        require(
            (a.openInterest18 * DEPTH_BPS) / 10_000 == a.absoluteCap18,
            "ASSET: openInterest18 * depthBps != absoluteCap18 - the depth leg and the cap disagree"
        );

        // `BufferBook.configure` requires the ladder non-increasing; caught here with a message
        // that names the problem rather than as an anonymous revert in phase 4.
        require(
            a.bufferFloor18 >= a.bufferFeeOn18 && a.bufferFeeOn18 >= a.bufferMintSlow18,
            "ASSET: buffer ladder is not non-increasing - BufferBook.configure refuses it"
        );

        require(a.seedPx18 != 0, "ASSET: seedPx18 == 0 - a zero mark kills the simulator's mark-to-market layer");
        require(_toFeedAnswer(a.seedPx18) > 0, "ASSET: seedPx18 rounds to a zero feed answer at FEED_DECIMALS");
    }

    // ------------------------------------------------------------- §9, against the simulation

    /// @dev EVERY §9 ITEM THAT APPLIES TO A NEW MIRROR, as a `require` with a named message, so a
    ///      bad add aborts before broadcasting rather than half-completing a set of immutables
    ///      beside vaults that already hold real supply.
    ///
    ///      READ THE CONTRACT NATSPEC ON WHAT THIS DOES NOT PROVE. These assert the LOCAL
    ///      SIMULATION. `script/VerifyTestnet.s.sol` is what discharges §9 against the live chain,
    ///      and it is in the tree — run it afterwards.
    function _verifyLocalSimulation() internal view {
        _verifyOracle();
        _verifyDeps();
        _verifyConfig();
        _verifyGate();
        _verifyExistingUntouched();
    }

    function _verifyOracle() internal view {
        CertOracle o = CertOracle(newOracle);

        // §4 / §9: the governance binding. THE ITEM WITH NO REMEDY BUT REDEPLOYMENT.
        require(o.governance() == govAddr, "S9: oracle.governance != GOV");
        require(o.attester() == attesterAddr, "S9: oracle.attester != ATTESTER");
        require(o.pendingAttester() == address(0), "S9: oracle.pendingAttester != 0");
        require(o.ATTESTER_ROTATION_DELAY() == 2 days, "S9: oracle rotation delay != 2d");
        require(
            o.ATTESTER_ROTATION_DELAY() == SolvencyRegistry(registry).ATTESTER_ROTATION_DELAY(),
            "S9: oracle/registry rotation delays differ"
        );

        // §2: the oracle's configuration, and the two values that must never be wrong
        require(address(o.feed()) == newAggregator, "S9: oracle.feed != the aggregator this run deployed");
        require(o.singleSource() == SINGLE_SOURCE, "S9: oracle.singleSource != declared mode");
        require(o.deviationBps() == DEVIATION_BPS, "S9: oracle.deviationBps wrong");
        require(o.deviationBps() != 0, "S9: deviationBps == 0 locks minting shut on the first tick");
        require(o.stalenessSeconds() == STALENESS_SECONDS, "S9: oracle.stalenessSeconds wrong");
        require(o.pokeConfirmationSeconds() == POKE_CONFIRMATION_SECONDS, "S9: pokeConfirmationSeconds wrong");
        require(o.pokeConfirmationSeconds() != 0, "S9: pokeConfirmationSeconds == 0");
        require(o.basisBandBps() == BASIS_BAND_BPS, "S9: oracle.basisBandBps wrong");
        require(o.priceDecimals() == a.priceDecimals, "S9: oracle.priceDecimals != venue price_decimals");
        require(o.lastGoodPx18() != 0, "S9: oracle.lastGoodPx18 == 0, mintAllowed fails closed");

        // The aggregator is this mirror's own and carries this mirror's description — the string
        // `FeedKeeper`'s operator reads to confirm which market they are pushing.
        require(ReplayAggregator(newAggregator).decimals() == FEED_DECIMALS, "S9: aggregator.decimals != FEED_DECIMALS");
        require(
            keccak256(bytes(ReplayAggregator(newAggregator).description())) == keccak256(bytes(a.feedDescription)),
            "S9: aggregator.description != feedDescription"
        );
        require(ReplayAggregator(newAggregator).owner() == deployerAddr, "S9: aggregator.owner != DEPLOYER");

        // §9: `absoluteCap18(vault)` is set. Zero means NO CAPACITY, not unbounded. The `!= 0`
        // assertion comes FIRST deliberately: it is the failure that actually happens (governance
        // forgot `setAbsoluteCap`), and "UNSET - cannot mint" tells the operator what to do.
        require(CapacityOracle(capacity).absoluteCap18(newVault) != 0, "S9: absoluteCap18(vault) UNSET - cannot mint");
        require(CapacityOracle(capacity).absoluteCap18(newVault) == a.absoluteCap18, "S9: absoluteCap18(vault) wrong");
    }

    function _verifyDeps() internal view {
        CertVault v = CertVault(newVault);

        // §9: the vault's five immutable dependencies, all pointing at the SHARED infrastructure
        // the book named — not at anything this run created.
        require(v.governance() == govAddr, "S9: vault.governance != GOV");
        require(address(v.lighter()) == lighter, "S9: vault.lighter != book lighterSim");
        require(address(v.oracle()) == newOracle, "S9: vault.oracle != the oracle this run deployed");
        require(address(v.registry()) == registry, "S9: vault.registry != book solvencyRegistry");
        require(address(v.capacity()) == capacity, "S9: vault.capacity != book capacityOracle");

        // §9: THE ONE `registerVault` DOES NOT CHECK. A mismatch is not repairable — every
        // dependency on both sides is immutable.
        require(address(v.lighter()) == CertFactory(factory).lighter(), "S9: vault.lighter != factory.lighter");
        require(address(v.registry()) == CertFactory(factory).registry(), "S9: vault.registry != factory.registry");
        require(address(v.capacity()) == CertFactory(factory).capacity(), "S9: vault.capacity != factory.capacity");
        require(v.governance() == CertFactory(factory).governance(), "S9: vault.governance != factory.governance");

        // §9: registration, and exactly one slot — the NEW last one.
        require(CertFactory(factory).isVault(newVault), "S9: factory.isVault(vault) false");
        require(
            CertFactory(factory).vaultCount() == bookMirrors.length + 1,
            "S9: factory.vaultCount() != previous vaults + 1"
        );
        require(
            CertFactory(factory).vaults(bookMirrors.length) == newVault, "S9: factory.vaults(last) != the new vault"
        );
        require(!CertFactory(factory).enabled(newVault), "S9: vault enabled - L-1 says do not, it is cosmetic");

        // §9: the certificate cross-check (`registerVault` enforced it; this is the read-back)
        require(address(v.certificate()) == newCertificate, "S9: vault.certificate != recorded certificate");
        require(Certificate(newCertificate).vault() == newVault, "S9: certificate.vault != vault");
        require(
            keccak256(bytes(Certificate(newCertificate).symbol())) == keccak256(bytes(a.symbol)),
            "S9: certificate symbol wrong"
        );
        require(
            keccak256(bytes(Certificate(newCertificate).name())) == keccak256(bytes(a.name)),
            "S9: certificate name wrong"
        );
        require(address(v.buffer()) == newBufferBook, "S9: vault.buffer() != recorded bufferBook");
    }

    /// @dev §9 / §3: the vault config against the venue's own market config. The venue-shaped half
    ///      and the economics half destructure `cfg()` separately — one flat read of all ten fields
    ///      plus the comparison operands exceeds the legacy codegen's stack, and `via_ir` is not
    ///      available to us (Global Constraint 1).
    function _verifyConfig() internal view {
        (address cCollateral, uint16 cAssetIdx, uint8 cRouteType, uint16 cMarketIndex, uint8 cSizeDecimals,,,,,) =
            CertVault(newVault).cfg();
        require(cCollateral == collateral, "S9: cfg.collateral != book collateral");
        require(cAssetIdx == COLLATERAL_ASSET_INDEX, "S9: cfg.collateralAssetIndex wrong");
        require(cRouteType == ROUTE_TYPE, "S9: cfg.routeType wrong");
        require(cMarketIndex == a.marketIndex, "S9: cfg.marketIndex != the table's market index");
        require(cSizeDecimals == a.sizeDecimals, "S9: cfg.sizeDecimals != venue size_decimals");
        _verifyConfigEconomics();
    }

    function _verifyConfigEconomics() internal view {
        (,,,,, uint256 cMintFee, uint256 cRedeemFee, uint256 cInstantCap, uint256 cBand, uint256 cMargin) =
            CertVault(newVault).cfg();
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

    function _verifyGate() internal view {
        CertVault v = CertVault(newVault);
        CertOracle o = CertOracle(newOracle);

        require(v.venueWithdrawCap() == VENUE_WITHDRAW_CAP, "S9: venueWithdrawCap wrong");
        require(v.venueWithdrawCap() <= type(uint64).max, "S9: venueWithdrawCap > uint64 max");
        require(v.settleWindow() == SETTLE_WINDOW, "S9: vault.settleWindow wrong");

        // §9: the registering deposit has EXECUTED.
        require(v.bootstrapped(), "S9: vault not bootstrapped");
        require(v.lighterAccountIndex() != 0, "S9: lighterAccountIndex == 0 - registering deposit not executed");

        // The allowlist row, read back.
        require(LighterSim(lighter).depositorAllowed(newVault), "S9: depositorAllowed(vault) false");

        // The seed actually landed. `bootstrap()` posts `10 ** decimals` of it as registering dust,
        // so the vault's own balance is the seed minus that dust.
        require(v.postedMargin() == 10 ** COLLATERAL_DECIMALS, "S9: postedMargin != the registering dust");
        require(
            v.hotBuffer() == SEED_COLLATERAL - 10 ** COLLATERAL_DECIMALS,
            "S9: hotBuffer != SEED_COLLATERAL minus the registering dust - the seed did not land"
        );
        require(v.bufferCapacity18() != 0, "S9: bufferCapacity18 == 0 - one of maxNotional18's three legs is dead");

        // §5 / Global Constraint 5: the simulator is not easier than the venue, and this market's
        // mark is set — `settleBatch` refuses a market whose mark is unset.
        require(
            LighterSim(lighter).requiredMarginBps() >= LighterSim(lighter).VENUE_IMF_BPS(),
            "S9: sim margin below the venue floor"
        );
        require(
            LighterSim(lighter).markPrice(a.marketIndex) == a.seedPx18,
            "S9: venue mark != seedPx18 - settleBatch would revert or fill at the wrong price"
        );

        // §9: the live price is inside the uint32 tick domain at the configured priceDecimals
        require(o.toTickPrice(o.px()) != 0, "S9: toTickPrice(px) == 0");

        // The attestation is live and the mint gate is ACTUALLY OPEN for the new mirror.
        require(SolvencyRegistry(registry).ageSec(newVault) <= MAX_ATTESTATION_AGE_SEC, "S9: attestation already stale");
        require(
            SolvencyRegistry(registry).latest(newVault).openInterest18 == a.openInterest18,
            "S9: attested openInterest18 != the table's figure"
        );
        require(
            SolvencyRegistry(registry).latest(newVault).batchId == SEED_BATCH_ID, "S9: attested batchId != SEED_BATCH_ID"
        );
        require(o.markPx18() == a.seedPx18, "S9: oracle.markPx18 != seedPx18 - basis band fails closed at false");
        (bool basisKnown, uint256 basisBps) = o.basisBpsChecked();
        require(basisKnown, "S9: basis unknown in dual-source mode");
        require(basisBps <= BASIS_BAND_BPS, "S9: basis outside the band at deployment");
        require(o.mintAllowed(), "S9: MINT GATE CLOSED - oracle.mintAllowed() is false");
        require(
            CapacityOracle(capacity).maxNotional18(newVault, v.bufferCapacity18()) != 0,
            "S9: MINT GATE CLOSED - maxNotional18 == 0"
        );
    }

    /// @dev THE CHECK `DeployTestnet` HAS NO NEED FOR AND THIS SCRIPT CANNOT DO WITHOUT: the
    ///      already-live mirrors are UNCHANGED. This run touches shared contracts — the factory's
    ///      vault list, the simulator's allowlist and mark table, the capacity oracle's cap
    ///      mapping, the registry — and every one of those is state the existing vaults read. An
    ///      "add" that quietly moved one of their caps to zero, or reused one of their market
    ///      indices, would deploy perfectly cleanly.
    ///
    ///      Asserted against the BOOK's record of them, which is what the front-end and every
    ///      keeper read, so a drift between the book and the chain is caught in the same breath.
    function _verifyExistingUntouched() internal view {
        for (uint256 i = 0; i < bookMirrors.length; ++i) {
            address vlt = bookMirrors[i].vault;
            require(CertFactory(factory).isVault(vlt), "S9-EXISTING: a live vault lost its factory registration");
            require(CertFactory(factory).vaults(i) == vlt, "S9-EXISTING: a live vault moved factory slot");
            require(
                CapacityOracle(capacity).absoluteCap18(vlt) == vm.parseUint(bookMirrors[i].absoluteCap18),
                "S9-EXISTING: a live vault's absoluteCap18 no longer matches the book - STOP"
            );
            require(
                LighterSim(lighter).depositorAllowed(vlt), "S9-EXISTING: a live vault lost its LighterSim allowlist row"
            );
            require(
                LighterSim(lighter).markPrice(uint16(bookMirrors[i].marketIndex)) != 0,
                "S9-EXISTING: a live vault's venue mark was cleared"
            );
            require(vlt != newVault, "S9-EXISTING: the new vault address collides with a live one");
            require(
                bookMirrors[i].certificate != newCertificate, "S9-EXISTING: the new certificate collides with a live one"
            );
            require(
                bookMirrors[i].marketIndex != a.marketIndex, "S9-EXISTING: the new market index collides with a live one"
            );
        }
    }

    // ------------------------------------------------------------------------ the address book

    /// @dev `deployments/46630.json`, APPENDED TO — never replaced, and never hand-edited.
    ///
    ///      The existing records are read in `_loadBookMirrors()` and written back out FIELD BY
    ///      FIELD, with the three large numbers echoed as the book's own strings so a re-emitted
    ///      record cannot differ from the record that was read. That is the whole reason this is
    ///      done in the script rather than by editing the file: each mirror is a new vault AND a
    ///      new `Certificate` token, and an edited map silently repoints a UI at a new token while
    ///      real balances sit in the old one — the holder's certificates just stop being visible,
    ///      with nothing on-chain wrong.
    ///
    ///      `_generatedBy` is left naming `DeployTestnet` — it is still the file that created this
    ///      deployment, and the shared addresses and `parameters` block are still its output.
    ///      `_amendedBy` records that this script appended, which is a different claim and is kept
    ///      as one.
    ///
    ///      Assembled row by row through the `_j*` helpers rather than in a few large
    ///      `string.concat` calls. Not a style choice: a wide `string.concat` blows the legacy
    ///      codegen's stack and `via_ir` is off and must stay off (Global Constraint 1).
    function _appendToAddressBook() internal {
        bookMirrors.push(
            BookMirror({
                symbol: a.symbol,
                name: a.name,
                marketIndex: a.marketIndex,
                priceDecimals: a.priceDecimals,
                sizeDecimals: a.sizeDecimals,
                vault: newVault,
                certificate: newCertificate,
                bufferBook: newBufferBook,
                certOracle: newOracle,
                replayAggregator: newAggregator,
                seedPrice18: vm.toString(a.seedPx18),
                absoluteCap18: vm.toString(a.absoluteCap18),
                seedOpenInterest18: vm.toString(a.openInterest18),
                marketIndexVerified: _marketIndexVerified(a.marketIndex)
            })
        );

        string memory out = "{\n";
        out = string.concat(out, _jStr("  ", "_generatedBy", "script/DeployTestnet.s.sol"));
        out = string.concat(out, _jStr("  ", "_amendedBy", "script/AddMirror.s.sol"));
        out = string.concat(
            out,
            _jStr(
                "  ",
                "_warning",
                "GENERATED PER DEPLOYMENT. NEVER HAND-EDIT: each mirror is a new vault AND a new certificate token, and an edited map repoints a UI at a new token while balances sit in the old one. Re-run the script."
            )
        );
        out = string.concat(
            out,
            _jStr(
                "  ",
                "_marketIndexVerifiedNote",
                "Per mirror: was marketIndex READ from the venue's api/v1/orderBookDetails, or CHOSEN? true for TSLA 16 and NVDA 15 only (WHITEPAPER.md 4.4, measured 2026-09-07). false is a WORK ITEM, not a disclaimer - uSPY's 26 and uQQQ's 27 are placeholders. On LighterSim setMarkPrice implicitly creates any index, so an unverified one deploys clean; on a real venue it pushes the WRONG market's mark. Re-read market_id and redeploy the mirror before pointing it at a real venue."
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
        out = string.concat(
            out,
            "    \"_note\": \"governance deployed SolvencyRegistry and every CertOracle itself (checklist S4); those bindings are immutable\"\n  },\n"
        );

        out = string.concat(out, '  "shared": {\n');
        out = string.concat(out, _sharedJson());
        out = string.concat(out, "  },\n");

        out = string.concat(out, '  "parameters": {\n');
        out = string.concat(out, _parametersJson());
        out = string.concat(out, "\n  },\n");

        out = string.concat(out, '  "vaults": [\n');
        for (uint256 i = 0; i < bookMirrors.length; ++i) {
            out = string.concat(out, _mirrorJson(i));
            out = string.concat(out, i + 1 == bookMirrors.length ? "\n" : ",\n");
        }
        out = string.concat(out, "  ]\n}\n");

        vm.writeFile(_bookPath(), out);
    }

    /// @dev The shared block, echoed back from the book's own values. The three note fields and the
    ///      faucet parameters are re-emitted verbatim so the file this script writes is the file
    ///      `DeployTestnet` would have written, plus the new mirror.
    function _sharedJson() internal view returns (string memory) {
        string memory j = _bookJson();
        string memory out = _jAddr("    ", "collateral", collateral);
        out = string.concat(out, _jNum("    ", "collateralDecimals", COLLATERAL_DECIMALS));
        out = string.concat(out, _jAddr("    ", "testFaucet", testFaucet));
        out = string.concat(out, _jStr("    ", "_testFaucetNote", vm.parseJsonString(j, ".shared._testFaucetNote")));
        out = string.concat(out, _jNum("    ", "faucetDripAmount", vm.parseJsonUint(j, ".shared.faucetDripAmount")));
        out = string.concat(
            out, _jNum("    ", "faucetIntervalSeconds", vm.parseJsonUint(j, ".shared.faucetIntervalSeconds"))
        );
        out = string.concat(out, _jNum("    ", "faucetOpeningFloat", vm.parseJsonUint(j, ".shared.faucetOpeningFloat")));
        out = string.concat(out, _jAddr("    ", "lighterSim", lighter));
        out = string.concat(out, _jAddr("    ", "solvencyRegistry", registry));
        out = string.concat(out, _jAddr("    ", "capacityOracle", capacity));
        out = string.concat(out, _jAddr("    ", "batchKeeper", batchKeeper));
        out = string.concat(out, _jStr("    ", "_batchKeeperNote", vm.parseJsonString(j, ".shared._batchKeeperNote")));
        out = string.concat(out, _jAddrLast("    ", "certFactory", factory));
        return out;
    }

    function _jStr(string memory pad, string memory k, string memory v) internal pure returns (string memory) {
        return string.concat(pad, '"', k, '": "', v, '",\n');
    }

    function _jNum(string memory pad, string memory k, uint256 v) internal pure returns (string memory) {
        return string.concat(pad, '"', k, '": ', vm.toString(v), ",\n");
    }

    function _jBool(string memory pad, string memory k, bool v) internal pure returns (string memory) {
        return string.concat(pad, '"', k, '": ', v ? "true" : "false", ",\n");
    }

    function _jAddr(string memory pad, string memory k, address v) internal pure returns (string memory) {
        return _jStr(pad, k, vm.toString(v));
    }

    function _jAddrLast(string memory pad, string memory k, address v) internal pure returns (string memory) {
        return string.concat(pad, '"', k, '": "', vm.toString(v), '"\n');
    }

    /// @dev Byte-identical to `DeployTestnet._parametersJson()`, and every value in it is asserted
    ///      against the book AND against mirror 0's live contracts before a transaction is sent
    ///      (`_requireParamsMatchBook`, `_requireParamsMatchChain`). Duplicated rather than
    ///      imported because importing `DeployTestnet` into this file would pull its
    ///      full-bootstrap `run()` into the same compilation unit and make it one `forge script`
    ///      contract-selection mistake away from being invoked.
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

    function _mirrorJson(uint256 i) internal view returns (string memory) {
        BookMirror memory m = bookMirrors[i];
        string memory out = "    {\n";
        out = string.concat(out, _jStr("      ", "symbol", m.symbol));
        out = string.concat(out, _jStr("      ", "name", m.name));
        out = string.concat(out, _jNum("      ", "marketIndex", m.marketIndex));
        // The new field. See `_marketIndexVerifiedNote` at the top of the file and the contract
        // NatSpec. Placed directly under `marketIndex` so a reader cannot see one without the
        // other.
        out = string.concat(out, _jBool("      ", "marketIndexVerified", m.marketIndexVerified));
        out = string.concat(out, _jNum("      ", "priceDecimals", m.priceDecimals));
        out = string.concat(out, _jNum("      ", "sizeDecimals", m.sizeDecimals));
        out = string.concat(out, _jAddr("      ", "vault", m.vault));
        out = string.concat(out, _jAddr("      ", "certificate", m.certificate));
        out = string.concat(out, _jAddr("      ", "bufferBook", m.bufferBook));
        out = string.concat(out, _jAddr("      ", "certOracle", m.certOracle));
        out = string.concat(out, _jAddr("      ", "replayAggregator", m.replayAggregator));
        // Quoted strings, not JSON numbers: these exceed 2^53 and would lose precision in any
        // JavaScript consumer that parsed them as numbers. The front-end adapter reads this file.
        out = string.concat(out, _jStr("      ", "seedPrice18", m.seedPrice18));
        out = string.concat(out, _jStr("      ", "absoluteCap18", m.absoluteCap18));
        out = string.concat(out, string.concat('      "seedOpenInterest18": "', m.seedOpenInterest18, '"\n    }'));
        return out;
    }

    /// @dev The commit being deployed. §9's last item requires `forge build --sizes` to have been
    ///      run against THIS commit, so the commit has to be recorded for that claim to be
    ///      checkable later.
    ///
    ///      Taken from the `COMMIT` env var rather than shelled out with FFI: `ffi` is not enabled
    ///      in `foundry.toml` and enabling it would let any dependency in the compilation unit run
    ///      arbitrary commands during a run that handles three private keys. Not worth it for a
    ///      string.
    function _commit() internal view returns (string memory) {
        return vm.envOr("COMMIT", string("UNKNOWN - COMMIT env unset; record it by hand before publishing"));
    }

    // --------------------------------------------------------------------------------- helpers

    /// @dev `seedPx18` (18 decimals) into the aggregator's own `FEED_DECIMALS` (8). Division, so it
    ///      cannot overflow. The exponent is widened to `uint256` deliberately: left as `uint8`,
    ///      `10 ** (18 - FEED_DECIMALS)` is `10 ** 10` evaluated in `uint8` and overflows.
    function _toFeedAnswer(uint256 px18) internal pure returns (int256) {
        return int256(px18 / (10 ** (uint256(18) - uint256(FEED_DECIMALS))));
    }

    function _report() internal view {
        console2.log("=== UseCert: ONE MIRROR ADDED to the live deployment, chain", block.chainid, "===");
        console2.log("mirror          ", a.symbol);
        console2.log("marketIndex     ", a.marketIndex);
        console2.log(
            _marketIndexVerified(a.marketIndex)
                ? "  marketIndexVerified TRUE  (read live from the venue API)"
                : "  marketIndexVerified FALSE - PLACEHOLDER. On a real venue this pushes the WRONG market's mark."
        );
        console2.log("deployer        ", deployerAddr);
        console2.log("governance      ", govAddr);
        console2.log("attester        ", attesterAddr);
        console2.log("--- reused, NOT redeployed ---");
        console2.log("  collateral      ", collateral);
        console2.log("  LighterSim      ", lighter);
        console2.log("  SolvencyRegistry", registry);
        console2.log("  CapacityOracle  ", capacity);
        console2.log("  CertFactory     ", factory);
        console2.log("--- deployed this run ---");
        console2.log("  ReplayAggregator", newAggregator);
        console2.log("  CertOracle      ", newOracle);
        console2.log("  CertVault       ", newVault);
        console2.log("  Certificate     ", newCertificate);
        console2.log("  BufferBook      ", newBufferBook);
        console2.log("--- shared state this run touched ---");
        console2.log("  factory.vaultCount", CertFactory(factory).vaultCount());
        console2.log("  sim.queueLength   ", LighterSim(lighter).queueLength());
        console2.log("  sim.settleCursor  ", LighterSim(lighter).settleCursor());
        console2.log("address book -> %s", _bookPath());
        console2.log("NEXT, AND THIS SCRIPT'S REQUIRES DO NOT SUBSTITUTE FOR IT:");
        console2.log("  forge script script/VerifyTestnet.s.sol --rpc-url <rpc>   # S9, on chain");
        console2.log("  bash script/check-sizes.sh                                # EIP-170 gate");
        console2.log("  python scripts/gen-frontend-abi.py                        # front-end bundle");
        console2.log("  restart ALL THREE keepers, including a FeedKeeper leg for this new mirror,");
        console2.log("  or minting on it stops ~5 minutes from now (maxAttestationAgeSec = 300).");
    }
}
