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
import {IERC20Metadata} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title  The address book, parsed — shared by `VerifyTestnet` and `script/smoke/SmokeTest.s.sol`.
///
/// @notice NEITHER SCRIPT TAKES AN ADDRESS AS AN ARGUMENT, and that is the whole point of a
///         verifier. A checker told which oracle a vault "should" point at is being handed the
///         answer; one that reads `deployments/<chainId>.json` — the file
///         `script/DeployTestnet.s.sol` generated and every keeper and the front-end adapter read —
///         is checking the artefact the rest of the system actually believes. If the book and the
///         chain disagree, something downstream is already wrong.
///
/// @dev    PARSED KEY BY KEY, NEVER AS A STRUCT. `vm.parseJson(json)` into a struct requires the
///         JSON's shape to match the struct exactly and in alphabetical field order, so ONE ADDED
///         KEY BREAKS IT. The address book is a living file — Task 8 adds `shared.testCollateral`
///         and a faucet entry, and the parameters block grows with the design — so every read below
///         names its own key and an unknown sibling key is simply not read. Optional keys are
///         probed with `vm.keyExistsJson` first. A key this file needs and cannot find is a loud
///         `require`, never a zero.
///
/// @dev    `_bookJson()` IS THE INJECTION SEAM, and it is the FILE READ that is virtual rather than
///         the parse — the same decision, for the same measured reason, as
///         `script/keepers/KeeperScript.sol`. A test overrides the read and still runs every line
///         of the real parser. It does NOT override the parse and hand in a struct, which would
///         test nothing.
///
///         WHY A SEAM AND NOT `vm.setEnv`: a `vm.setEnv` inside a test function is NOT rolled back
///         when Foundry reverts to the post-`setUp` snapshot, and a restore written at the end of
///         that test does not reliably take effect for the next one. An env-mutating test therefore
///         corrupts its neighbours and races across suites. Measured, not assumed.
///
///         AND WHY THE TESTS DO NOT RUN `DeployTestnet.run()`: that writes
///         `deployments/46630.json` unconditionally at a fixed path, and
///         `test/script/DeployTestnet.t.sol` reads that exact file back asserting its own
///         addresses. Two suites writing it would make that test flaky. The tests feed this parser
///         a book in the real format through the seam; the live `anvil` run in
///         `docs/TESTNET-RUNBOOK.md` is what exercises the real file.
abstract contract TestnetAddressBook is Script {
    /// @dev One mirror, as the book records it.
    struct Mirror {
        string symbol;
        address vault;
        address certificate;
        address bufferBook;
        address certOracle;
        address replayAggregator;
        uint16 marketIndex;
        uint8 priceDecimals;
        uint8 sizeDecimals;
        uint256 seedPrice18;
        uint256 absoluteCap18;
    }

    /// @dev The declared parameters. Read back so the BOOK is verified against the chain too, not
    ///      merely used as a source of addresses: a book whose `parameters` block disagrees with
    ///      the deployed immutables is a book that will mislead the next operator to read it.
    struct Params {
        uint256 targetMarginBps;
        uint256 instantCap18;
        uint256 settleWindow;
        uint256 settleBandBps;
        uint256 mintFeeBps;
        uint256 redeemFeeBps;
        uint256 stalenessSeconds;
        uint256 pokeConfirmationSeconds;
        uint256 deviationBps;
        uint256 basisBandBps;
        bool singleSource;
        uint256 depthBps;
        uint256 minDepthBps;
        uint256 maxDepthBps;
        uint256 maxAttestationAgeSec;
        uint256 maxAbsoluteCap18;
        uint256 venueWithdrawCap;
        uint256 simRequiredMarginBps;
        uint256 feedDecimals;
    }

    // The book, in STORAGE rather than in memory structs handed between functions. Not a style
    // choice: `foundry.toml` sets `via_ir = false` and must not be changed (Global Constraint 1),
    // so the legacy codegen's stack limit binds, and `CertVault.cfg()`'s ten-field destructuring
    // alone nearly exhausts it. `script/DeployTestnet.s.sol` reached the same conclusion for the
    // same reason. Writing this contract's OWN storage broadcasts nothing — see `VerifyTestnet`.
    uint256 internal bookChainId;
    address internal bookDeployer;
    address internal bookGovernance;
    address internal bookAttester;
    address internal bookCollateral;
    uint256 internal bookCollateralDecimals;
    address internal bookTestFaucet;
    address internal bookLighterSim;
    address internal bookRegistry;
    address internal bookCapacity;
    address internal bookBatchKeeper;
    address internal bookFactory;
    Params internal p;
    Mirror[] internal mirrors;

    /// @dev The bound on the mirror probe below. Far above the two mirrors
    ///      `script/DeployTestnet.s.sol` deploys; it exists so a truncated or malformed book cannot
    ///      make the loop run away, and exceeding it is an explicit error rather than a silent
    ///      truncation that would leave a real vault unverified.
    uint256 internal constant MAX_MIRRORS = 64;

    function _bookPath() internal view virtual returns (string memory) {
        return vm.envOr("ADDRESS_BOOK", string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }

    /// @dev The seam. See the contract NatSpec.
    function _bookJson() internal view virtual returns (string memory) {
        return vm.readFile(_bookPath());
    }

    function _loadBook() internal {
        string memory json = _bookJson();

        bookChainId = vm.parseJsonUint(json, ".chainId");
        bookDeployer = vm.parseJsonAddress(json, ".senders.deployer");
        bookGovernance = vm.parseJsonAddress(json, ".senders.governance");
        bookAttester = vm.parseJsonAddress(json, ".senders.attester");

        bookCollateral = vm.parseJsonAddress(json, ".shared.collateral");
        bookCollateralDecimals = vm.parseJsonUint(json, ".shared.collateralDecimals");
        // OPTIONAL BY DESIGN. `address(0)` is what the book records while Task 8's faucet has not
        // landed, and a future book may drop the key entirely. Absence is not a failure; a faucet
        // is not a §9 item.
        bookTestFaucet =
            vm.keyExistsJson(json, ".shared.testFaucet") ? vm.parseJsonAddress(json, ".shared.testFaucet") : address(0);
        bookLighterSim = vm.parseJsonAddress(json, ".shared.lighterSim");
        bookRegistry = vm.parseJsonAddress(json, ".shared.solvencyRegistry");
        bookCapacity = vm.parseJsonAddress(json, ".shared.capacityOracle");
        bookBatchKeeper = vm.parseJsonAddress(json, ".shared.batchKeeper");
        bookFactory = vm.parseJsonAddress(json, ".shared.certFactory");

        _loadParams(json);
        _loadMirrors(json);
    }

    function _loadParams(string memory json) private {
        p.targetMarginBps = vm.parseJsonUint(json, ".parameters.targetMarginBps");
        // QUOTED IN THE BOOK, NOT A JSON NUMBER: these exceed 2^53 and would lose precision in any
        // JavaScript consumer, so `DeployTestnet` writes them as strings and this reads them back
        // as strings. `parseJsonUint` on a quoted value is not portable across Foundry versions.
        p.instantCap18 = vm.parseUint(vm.parseJsonString(json, ".parameters.instantCap18"));
        p.settleWindow = vm.parseJsonUint(json, ".parameters.settleWindow");
        p.settleBandBps = vm.parseJsonUint(json, ".parameters.settleBandBps");
        p.mintFeeBps = vm.parseJsonUint(json, ".parameters.mintFeeBps");
        p.redeemFeeBps = vm.parseJsonUint(json, ".parameters.redeemFeeBps");
        p.stalenessSeconds = vm.parseJsonUint(json, ".parameters.stalenessSeconds");
        p.pokeConfirmationSeconds = vm.parseJsonUint(json, ".parameters.pokeConfirmationSeconds");
        p.deviationBps = vm.parseJsonUint(json, ".parameters.deviationBps");
        p.basisBandBps = vm.parseJsonUint(json, ".parameters.basisBandBps");
        p.singleSource = vm.parseJsonBool(json, ".parameters.singleSource");
        p.depthBps = vm.parseJsonUint(json, ".parameters.depthBps");
        p.minDepthBps = vm.parseJsonUint(json, ".parameters.minDepthBps");
        p.maxDepthBps = vm.parseJsonUint(json, ".parameters.maxDepthBps");
        p.maxAttestationAgeSec = vm.parseJsonUint(json, ".parameters.maxAttestationAgeSec");
        p.maxAbsoluteCap18 = vm.parseUint(vm.parseJsonString(json, ".parameters.maxAbsoluteCap18"));
        p.venueWithdrawCap = vm.parseUint(vm.parseJsonString(json, ".parameters.venueWithdrawCap"));
        p.simRequiredMarginBps = vm.parseJsonUint(json, ".parameters.simRequiredMarginBps");
        p.feedDecimals = vm.parseJsonUint(json, ".parameters.feedDecimals");
    }

    function _loadMirrors(string memory json) private {
        // MIRRORS ARE COUNTED BY PROBING `.vaults[i]`, NOT BY READING A COLUMN WITH `[*]`.
        // `vm.parseJsonAddressArray(json, ".vaults[*].vault")` is wrong in the single-mirror case:
        // Foundry's jsonpath collapses a one-element match to a scalar and the array parse fails
        // with `expected [`. The deployed configuration has two mirrors, so that bug would have
        // hidden until the day someone deployed one. `script/keepers/KeeperScript.sol` found this
        // by running it; the same probe is used here.
        uint256 n;
        while (n < MAX_MIRRORS && vm.keyExistsJson(json, _vaultKey(n, "vault"))) {
            ++n;
        }
        require(n != 0, "V9-BOOK: no vaults in the address book - re-run script/DeployTestnet.s.sol");
        require(
            !vm.keyExistsJson(json, _vaultKey(n, "vault")),
            "V9-BOOK: more than MAX_MIRRORS vaults - raise the bound rather than leaving a vault unverified"
        );

        for (uint256 i = 0; i < n; ++i) {
            uint256 market = vm.parseJsonUint(json, _vaultKey(i, "marketIndex"));
            uint256 pdec = vm.parseJsonUint(json, _vaultKey(i, "priceDecimals"));
            uint256 sdec = vm.parseJsonUint(json, _vaultKey(i, "sizeDecimals"));
            require(market <= type(uint16).max, "V9-BOOK: marketIndex does not fit uint16");
            require(pdec <= type(uint8).max, "V9-BOOK: priceDecimals does not fit uint8");
            require(sdec <= type(uint8).max, "V9-BOOK: sizeDecimals does not fit uint8");
            mirrors.push(
                Mirror({
                    symbol: vm.parseJsonString(json, _vaultKey(i, "symbol")),
                    vault: vm.parseJsonAddress(json, _vaultKey(i, "vault")),
                    certificate: vm.parseJsonAddress(json, _vaultKey(i, "certificate")),
                    bufferBook: vm.parseJsonAddress(json, _vaultKey(i, "bufferBook")),
                    certOracle: vm.parseJsonAddress(json, _vaultKey(i, "certOracle")),
                    replayAggregator: vm.parseJsonAddress(json, _vaultKey(i, "replayAggregator")),
                    marketIndex: uint16(market),
                    priceDecimals: uint8(pdec),
                    sizeDecimals: uint8(sdec),
                    seedPrice18: vm.parseUint(vm.parseJsonString(json, _vaultKey(i, "seedPrice18"))),
                    absoluteCap18: vm.parseUint(vm.parseJsonString(json, _vaultKey(i, "absoluteCap18")))
                })
            );
        }
    }

    function _vaultKey(uint256 i, string memory field) private pure returns (string memory) {
        return string.concat(".vaults[", vm.toString(i), "].", field);
    }

    /// @dev THE ONE THING THE BOOK CANNOT PROVE ABOUT ITSELF. `vm.readFile` reads a local file: a
    ///      book generated against one deployment and left in the tree while a second deployment
    ///      happened elsewhere parses perfectly and names dead contracts. Checked before a single
    ///      assertion is made about their state, so "wrong book" never presents as "broken
    ///      deployment".
    function _requireBookMatchesChain() internal view {
        require(
            bookChainId == block.chainid, "V9-00: book chainId != the chain this RPC is on - wrong book or wrong RPC"
        );
        _requireCode(bookCollateral, "collateral");
        _requireCode(bookLighterSim, "lighterSim");
        _requireCode(bookRegistry, "solvencyRegistry");
        _requireCode(bookCapacity, "capacityOracle");
        _requireCode(bookFactory, "certFactory");
        for (uint256 i = 0; i < mirrors.length; ++i) {
            _requireCode(mirrors[i].vault, "vault");
            _requireCode(mirrors[i].certificate, "certificate");
            _requireCode(mirrors[i].bufferBook, "bufferBook");
            _requireCode(mirrors[i].certOracle, "certOracle");
            _requireCode(mirrors[i].replayAggregator, "replayAggregator");
        }
    }

    function _requireCode(address a, string memory what) internal view {
        require(a != address(0), string.concat("V9-00: book records address(0) for ", what));
        require(a.code.length > 0, string.concat("V9-00: no code at the book's ", what, " on this chain - stale book"));
    }
}

/// @title  §9, discharged against the LIVE CHAIN. Read-only.
///
/// @notice WHY THIS EXISTS SEPARATELY FROM `script/DeployTestnet.s.sol`, AND IT IS NOT REDUNDANCY.
///         `forge script --broadcast` simulates the ENTIRE run first and only then sends the
///         transactions it collected. So every `require` inside the deploy script asserts the
///         LOCAL SIMULATION's state and never once observes the chain. That is valuable — a
///         misconfiguration aborts before a single transaction is sent, rather than
///         half-completing an unrepairable deployment of immutables — but
///         `docs/DEPLOYMENT-CHECKLIST.md` §9 says "read these back on-chain", and nothing did.
///         This script is that reader.
///
/// @notice READ-ONLY, AND DELIBERATELY. It opens no broadcast, sends no transaction and changes no
///         state on any contract. A verifier that mutates the thing it verifies is not a verifier:
///         it cannot be run against a live deployment on a whim, which is exactly when §9 matters.
///         The one live mutation §9 does ask for — the dust `forceExit`, "this is Law 2 and it is
///         worth one real transaction" — lives in `script/smoke/SmokeTest.s.sol` behind its own
///         entrypoint, so an operator can run this check without touching the deployment.
///
///         `run()` is not `view` because it writes THIS CONTRACT's own storage while parsing the
///         book (see `TestnetAddressBook`'s note on the legacy codegen's stack limit). Nothing in
///         this file is inside a `vm.startBroadcast`, so nothing is ever sent.
///
/// @notice IT FAILS ON THE FIRST ITEM THAT FAILS, BY NAME. Every assertion is a `require` whose
///         message names the §9 row and the actual problem, in the order §9 lists them, so the
///         revert an operator sees tells them what to do rather than that "verification failed".
///
/// @dev    CONFIGURATION FACTS ARE ASSERTED; LIVENESS FACTS ARE REPORTED. The distinction is
///         load-bearing and it is not a softening. §9's rows are permanent properties of the
///         deployment — immutable dependencies, governance bindings, the allowlist, the keeper —
///         and every one of them is a hard `require` here. But `docs/TESTNET-RUNBOOK.md` §6 says to
///         run this script BEFORE STARTING THE KEEPERS, and at that moment the attestation seeded
///         during deployment is already minutes old against a 300 s deadline and the feed is
///         heading toward its 900 s bound. Asserting attestation freshness or `mintAllowed()` would
///         make the verifier fail on a perfectly good deployment whose keepers simply have not been
///         started yet — a check that cries wolf gets run with `|| true` within a week. Those
///         facts are printed, loudly, under `LIVENESS`, and the runbook's §7.4 health check is
///         where they belong.
///
/// @dev    USAGE — no keys, no `--broadcast`, nothing to fund:
///
///           forge script script/VerifyTestnet.s.sol --rpc-url robinhood_testnet
///
///         `ADDRESS_BOOK` overrides the book's path for an operator running from outside the repo
///         root; by default it is `deployments/<chainId>.json` keyed on the chain the RPC is on, so
///         a verifier aimed at the wrong RPC fails to find a book rather than checking the wrong
///         chain's addresses.
contract VerifyTestnet is TestnetAddressBook {
    function run() external {
        _loadBook();
        _requireBookMatchesChain();
        console2.log("=== VerifyTestnet: DEPLOYMENT-CHECKLIST S9 against chain", block.chainid, "===");
        console2.log("book           ", _bookPath());
        console2.log("mirrors in book", mirrors.length);

        _checkGovernanceAndAttester();
        _checkCapacity();
        _checkFactory();
        _checkCollateral();
        _checkSimulatorGlobals();

        for (uint256 i = 0; i < mirrors.length; ++i) {
            _checkMirror(i);
        }

        // Item 4, precondition 5: the allowed set, reported rather than merely probed for
        // membership. Runs after the per-mirror checks so its "vaults are allowed" half is already
        // established and this is purely the "and nothing else is" half.
        _checkAllowlistIsRestricted();
        _checkSimBookAgreement();

        _reportLiveness();

        console2.log("");
        console2.log("S9: ALL ON-CHAIN ITEMS PASS.");
        console2.log("Still owed by hand, and NOT verifiable from here:");
        console2.log("  - the dust forceExit: forge script script/smoke/SmokeTest.s.sol --broadcast");
        console2.log("  - the EIP-170 size gate against this commit: bash script/check-sizes.sh");
    }

    // ------------------------------------------------------------------ S9: governance, attester

    /// @dev §9 rows 1-3. THE ITEMS WITH NO REMEDY BUT A FULL REDEPLOYMENT: `governance` on the
    ///      registry and on every `CertOracle` is bound to `msg.sender` AT CONSTRUCTION and is
    ///      immutable. If it landed on an address nobody controls, attester rotation is unreachable
    ///      forever. The oracles' half is checked per mirror in `_checkMirrorOracle`.
    function _checkGovernanceAndAttester() private view {
        SolvencyRegistry r = SolvencyRegistry(bookRegistry);
        require(r.governance() == bookGovernance, "V9-01: registry.governance() != senders.governance in the book");
        require(r.attester() == bookAttester, "V9-02: registry.attester() != senders.attester in the book");
        require(r.pendingAttester() == address(0), "V9-02: registry.pendingAttester() != 0 - a rotation is in flight");
        require(r.ATTESTER_ROTATION_DELAY() == 2 days, "V9-03: registry.ATTESTER_ROTATION_DELAY() != 2 days");
        console2.log("V9-01..03 registry governance / attester / rotation delay  OK");

        // §9 says "the multisig". Nothing on-chain can check that an address is a multisig, and on
        // testnet it deliberately is not one, so this is REPORTED and not asserted — see the
        // contract NatSpec on configuration versus liveness. An EOA has no code; a multisig does.
        if (bookGovernance.code.length == 0) {
            console2.log("  NOTE: governance is an EOA (no code). S9 row 1 says multisig - true for MAINNET only.");
        }
    }

    // ---------------------------------------------------------------------------- S9: capacity

    /// @dev §9 row 4, minus the per-vault cap which is checked per mirror.
    function _checkCapacity() private view {
        CapacityOracle c = CapacityOracle(bookCapacity);
        require(c.governance() == bookGovernance, "V9-04: capacity.governance() != senders.governance in the book");
        require(address(c.registry()) == bookRegistry, "V9-04: capacity.registry() != shared.solvencyRegistry");
        // THE SINGLE IMMUTABLE BOUND ON A COMPROMISED OR LYING ATTESTER. `type(uint256).max` would
        // remove it entirely while reading as "configured".
        require(c.maxAbsoluteCap() != 0, "V9-04: capacity.maxAbsoluteCap() == 0 - no capacity at all");
        require(
            c.maxAbsoluteCap() != type(uint256).max,
            "V9-04: capacity.maxAbsoluteCap() is uint256 max - the only bound on a lying attester is gone"
        );
        require(
            c.maxAbsoluteCap() == p.maxAbsoluteCap18, "V9-04: capacity.maxAbsoluteCap() != parameters.maxAbsoluteCap18"
        );
        require(c.depthBps() == p.depthBps, "V9-04: capacity.depthBps() != parameters.depthBps");
        require(c.minDepthBps() == p.minDepthBps, "V9-04: capacity.minDepthBps() != parameters.minDepthBps");
        require(c.maxDepthBps() == p.maxDepthBps, "V9-04: capacity.maxDepthBps() != parameters.maxDepthBps");
        // Governance can move `depthBps` but never outside the immutable bounds. A live value
        // outside them would mean the bounds are not what the book says they are.
        require(c.depthBps() >= c.minDepthBps(), "V9-04: capacity.depthBps() below its own immutable floor");
        require(c.depthBps() <= c.maxDepthBps(), "V9-04: capacity.depthBps() above its own immutable ceiling");
        require(
            c.maxAttestationAgeSec() == p.maxAttestationAgeSec,
            "V9-04: capacity.maxAttestationAgeSec() != parameters.maxAttestationAgeSec"
        );
        console2.log("V9-04    capacity oracle bounds and governance               OK");
    }

    // ----------------------------------------------------------------------------- S9: factory

    /// @dev §9 rows 7 and the factory half of row 6. `vaultCount()` equals the number of vaults in
    ///      the book, so a third vault registered out of band — or a book that has fallen behind a
    ///      redeployment — fails here rather than going unverified.
    function _checkFactory() private view {
        CertFactory f = CertFactory(bookFactory);
        require(f.lighter() == bookLighterSim, "V9-06: factory.lighter() != shared.lighterSim in the book");
        require(f.registry() == bookRegistry, "V9-06: factory.registry() != shared.solvencyRegistry in the book");
        require(f.capacity() == bookCapacity, "V9-06: factory.capacity() != shared.capacityOracle in the book");
        require(f.governance() == bookGovernance, "V9-06: factory.governance() != senders.governance in the book");
        require(
            f.vaultCount() == mirrors.length,
            "V9-07: factory.vaultCount() != the number of vaults in the book - a vault is unverified or the book is stale"
        );
        console2.log("V9-06/07 factory immutables and vaultCount                   OK");
    }

    // -------------------------------------------------------------------------- S9: collateral

    /// @dev The figure the whole deployment turns on. `CertVault` reads
    ///      `IERC20Metadata(collateral).decimals()` exactly ONCE at construction and stores it as
    ///      an immutable, so a mismatch here means every `_to18`/`_from18` in every vault is wrong
    ///      in both directions forever, with no setter to repair it.
    function _checkCollateral() private view {
        require(
            IERC20Metadata(bookCollateral).decimals() == bookCollateralDecimals,
            "V9-CO: collateral decimals() != shared.collateralDecimals in the book - every vault's _to18 is wrong"
        );
        console2.log("V9-CO    collateral decimals match the book                  OK");
    }

    // ------------------------------------------------- S9 + item 4: the simulator, once globally

    /// @dev §9's two simulator-only rows and THREE OF TASK 7's FIVE PRECONDITIONS. Every one is a
    ///      configuration fact NO CONTRACT CHECKS, and each has a silent failure mode.
    ///
    ///      NOT APPLICABLE TO A MAINNET DEPLOYMENT against Lighter itself, exactly as §9 says: the
    ///      real venue has no owner, no keeper and no allowlist to read. This function would have
    ///      to be skipped, not adapted.
    function _checkSimulatorGlobals() private view {
        LighterSim s = LighterSim(bookLighterSim);

        // ---- §9: the simulator must never be EASIER than the venue (Global Constraint 5). This
        //      project shipped three defects a passing suite could not see because the mock was
        //      more permissive than the venue.
        require(
            s.requiredMarginBps() >= s.VENUE_IMF_BPS(),
            "V9-12: LighterSim.requiredMarginBps() below VENUE_IMF_BPS - the simulator is easier than the venue"
        );
        // The book-agreement half of this row is DELIBERATELY NOT HERE. It runs last, in
        // `_checkSimBookAgreement`, because a raised `requiredMarginBps` breaks two things at once
        // and they are not equally urgent: it makes the book's `simRequiredMarginBps` stale, AND it
        // can push the simulator's requirement above a vault's `targetMarginBps`, at which point
        // that vault mints unhedged. An operator who raised the margin on purpose and forgot the
        // book must hear "your vaults now mint unhedged" (V9-P1, per vault, below) before "your
        // JSON is out of date". Checking the equality here would report only the bookkeeping.

        // ---- §9: the owner is the key the batch advancer and the mark updates run with.
        require(s.owner() == bookDeployer, "V9-12: LighterSim.owner() != senders.deployer in the book");

        // ---- ITEM 4, PRECONDITION 3 — and §9's own row. FAILURE MODE: every `settleBatch` from
        //      the keeper's key reverts `LighterSim_OnlyOwnerOrKeeper`, which is INDISTINGUISHABLE
        //      ON-CHAIN FROM A DEAD KEEPER. Zero means "owner only", which is the fail-closed
        //      reading a forgotten `setKeeper` gets, and it is the one an operator will read as a
        //      crashed bot.
        require(
            s.keeper() != address(0),
            "V9-13: LighterSim.keeper() is unset - settleBatch reverts LighterSim_OnlyOwnerOrKeeper for the keeper bot"
        );
        require(
            s.keeper() == bookBatchKeeper,
            "V9-13: LighterSim.keeper() != shared.batchKeeper in the book - every settleBatch from that key reverts"
        );

        // ---- ITEM 4, PRECONDITION 4. The deployed DEFAULT is false, and false is right: reverting
        //      a whole batch because one account's order is under-margined is not venue behaviour,
        //      and it is a denial of service — one stuck order stops settlement for every vault
        //      sharing the simulator. `true` exists only so three pre-Task-7 tests keep asserting
        //      the margin gate as a revert. A deployment that flipped it is not merely stricter, it
        //      is fragile in a way the venue is not.
        require(
            !s.strictMode(),
            "V9-P4: LighterSim.strictMode() is true - one under-margined order would revert whole batches"
        );

        console2.log("V9-12    sim margin floor / owner                            OK");
        console2.log("V9-13    sim keeper == shared.batchKeeper                    OK");
        console2.log("V9-P4    sim strictMode == false                             OK");
    }

    // ------------------------------------------------------------------------------ per mirror

    /// @dev Split into six, and the split is FORCED rather than stylistic: `via_ir` is false and
    ///      must stay false (Global Constraint 1), so the legacy codegen's stack limit binds, and
    ///      `CertVault.cfg()`'s ten-field destructuring alone nearly exhausts it. One flat function
    ///      does not compile.
    function _checkMirror(uint256 i) private view {
        console2.log("");
        console2.log(string.concat("--- ", mirrors[i].symbol), mirrors[i].vault);
        _checkMirrorOracle(i);
        _checkMirrorDeps(i);
        _checkMirrorRegistration(i);
        _checkMirrorConfigVenue(i);
        _checkMirrorConfigEconomics(i);
        _checkMirrorSimAndTick(i);
    }

    /// @dev §9 rows 1-3 for the oracle, plus §2's configuration. The oracle is the other contract
    ///      that binds `governance = msg.sender` at construction and is immutable.
    function _checkMirrorOracle(uint256 i) private view {
        CertOracle o = CertOracle(mirrors[i].certOracle);
        require(o.governance() == bookGovernance, "V9-01: oracle.governance() != senders.governance in the book");
        require(o.attester() == bookAttester, "V9-02: oracle.attester() != senders.attester in the book");
        require(o.pendingAttester() == address(0), "V9-02: oracle.pendingAttester() != 0 - a rotation is in flight");
        require(o.ATTESTER_ROTATION_DELAY() == 2 days, "V9-03: oracle.ATTESTER_ROTATION_DELAY() != 2 days");
        require(
            o.ATTESTER_ROTATION_DELAY() == SolvencyRegistry(bookRegistry).ATTESTER_ROTATION_DELAY(),
            "V9-03: oracle and registry rotation delays differ"
        );

        // The feed the oracle actually reads must be the aggregator the book names. A book pointing
        // a keeper at one aggregator while the oracle reads another is a feed keeper pushing prices
        // nothing consumes — minting pauses in 900 s with every process apparently healthy.
        require(
            address(o.feed()) == mirrors[i].replayAggregator,
            "V9-OR: oracle.feed() != vaults[i].replayAggregator - the feed keeper would push to the wrong aggregator"
        );

        // §2's sharpest pre-deploy gate. `false` DECLARES feed and venue mark independent and
        // nothing on-chain can check that; set `false` on a venue-derived feed and the deployment
        // fails SILENTLY, with `basisBpsChecked()` returning a healthy basis it never computed.
        require(o.singleSource() == p.singleSource, "V9-OR: oracle.singleSource() != parameters.singleSource");
        require(o.deviationBps() == p.deviationBps, "V9-OR: oracle.deviationBps() != parameters.deviationBps");
        require(
            o.deviationBps() != 0,
            "V9-OR: oracle.deviationBps() == 0 - the H-1 clamp permits no advance, so the first tick pauses minting forever"
        );
        require(
            o.stalenessSeconds() == p.stalenessSeconds,
            "V9-OR: oracle.stalenessSeconds() != parameters.stalenessSeconds"
        );
        require(
            o.pokeConfirmationSeconds() == p.pokeConfirmationSeconds,
            "V9-OR: oracle.pokeConfirmationSeconds() != parameters.pokeConfirmationSeconds"
        );
        require(o.pokeConfirmationSeconds() != 0, "V9-OR: oracle.pokeConfirmationSeconds() == 0");
        require(o.basisBandBps() == p.basisBandBps, "V9-OR: oracle.basisBandBps() != parameters.basisBandBps");
        require(
            o.priceDecimals() == mirrors[i].priceDecimals,
            "V9-09: oracle.priceDecimals() != vaults[i].priceDecimals (the venue's price_decimals)"
        );
        // `lastGoodPx18 == 0` makes `mintAllowed()` fail closed in single-source mode and removes
        // `pxUnguarded()`'s fallback in both modes. The constructor writes it, so zero here means
        // something is very wrong.
        require(o.lastGoodPx18() != 0, "V9-OR: oracle.lastGoodPx18() == 0 - the deviation reference was never written");
        console2.log("  V9-01..03/OR oracle governance, attester, feed, S2 config  OK");
    }

    /// @dev §9 rows 5 and 6. EVERY ONE OF THESE IS IMMUTABLE ON BOTH SIDES, so a mismatch is not
    ///      repairable and the remedy is a redeployment.
    ///
    ///      Row 6 is THE ONE `registerVault` DOES NOT CHECK. The old `CertFactory.deployVault`
    ///      wired the four dependencies from the factory's own immutables and guaranteed the match
    ///      structurally; `registerVault` records a vault someone else deployed and checks only the
    ///      certificate. §9 exists to catch this, and this is where it is caught.
    function _checkMirrorDeps(uint256 i) private view {
        CertVault v = CertVault(mirrors[i].vault);
        CertFactory f = CertFactory(bookFactory);

        require(v.governance() == bookGovernance, "V9-05: vault.governance() != senders.governance in the book");
        require(address(v.lighter()) == bookLighterSim, "V9-05: vault.lighter() != shared.lighterSim in the book");
        require(
            address(v.oracle()) == mirrors[i].certOracle,
            "V9-05: vault.oracle() != vaults[i].certOracle in the book - the vault prices off a different oracle"
        );
        require(address(v.registry()) == bookRegistry, "V9-05: vault.registry() != shared.solvencyRegistry in the book");
        require(address(v.capacity()) == bookCapacity, "V9-05: vault.capacity() != shared.capacityOracle in the book");

        require(
            address(v.lighter()) == f.lighter(),
            "V9-06: vault.lighter() != factory.lighter() - NOT REPAIRABLE, redeploy"
        );
        require(
            address(v.registry()) == f.registry(),
            "V9-06: vault.registry() != factory.registry() - NOT REPAIRABLE, redeploy"
        );
        require(
            address(v.capacity()) == f.capacity(),
            "V9-06: vault.capacity() != factory.capacity() - NOT REPAIRABLE, redeploy"
        );
        require(
            v.governance() == f.governance(),
            "V9-06: vault.governance() != factory.governance() - NOT REPAIRABLE, redeploy"
        );
        console2.log("  V9-05/06     vault deps, and each equal to the factory's    OK");
    }

    /// @dev §9 rows 7, 8 and the per-vault half of row 4.
    function _checkMirrorRegistration(uint256 i) private view {
        CertVault v = CertVault(mirrors[i].vault);
        CertFactory f = CertFactory(bookFactory);

        require(f.isVault(mirrors[i].vault), "V9-07: factory.isVault(vault) is false - the vault was never registered");
        // EXACTLY ONE SLOT. Scanned rather than indexed by `i`, because the book's order need not be
        // the factory's registration order, and "registered twice" is a distinct defect from
        // "registered once at another index" — a duplicate would double-count in `vaultCount()`.
        uint256 seen;
        uint256 n = f.vaultCount();
        for (uint256 k = 0; k < n; ++k) {
            if (f.vaults(k) == mirrors[i].vault) ++seen;
        }
        require(seen != 0, "V9-07: vault is isVault but appears in no factory.vaults(i) slot");
        require(seen == 1, "V9-07: vault appears in more than one factory.vaults(i) slot");

        // `registerVault` ENFORCED this, so it is a read-back rather than a check — and it is worth
        // reading back because each deployment produces a new vault AND A NEW CERTIFICATE TOKEN. A
        // book naming the previous deployment's certificate would show holders nothing while
        // nothing on-chain is wrong.
        require(
            address(v.certificate()) == mirrors[i].certificate,
            "V9-08: vault.certificate() != vaults[i].certificate in the book - a UI would read the wrong token"
        );
        require(
            Certificate(mirrors[i].certificate).vault() == mirrors[i].vault,
            "V9-08: certificate.vault() != vault - the pair does not point at each other"
        );
        require(
            keccak256(bytes(Certificate(mirrors[i].certificate).symbol())) == keccak256(bytes(mirrors[i].symbol)),
            "V9-08: certificate.symbol() != vaults[i].symbol in the book"
        );
        require(
            address(v.buffer()) == mirrors[i].bufferBook, "V9-08: vault.buffer() != vaults[i].bufferBook in the book"
        );

        // §9 row 4, per vault. ZERO MEANS NO CAPACITY, NOT UNBOUNDED, and this is the single most
        // likely way the deployment appears broken: a vault that reads as perfectly deployed still
        // reverts `CertVault_AtCapacity` on every mint until governance has called
        // `setAbsoluteCap`. The `!= 0` check comes FIRST deliberately — it is the failure that
        // actually happens, and its message says what to do.
        CapacityOracle c = CapacityOracle(bookCapacity);
        require(
            c.absoluteCap18(mirrors[i].vault) != 0,
            "V9-04: capacity.absoluteCap18(vault) is UNSET - every mint reverts CertVault_AtCapacity until governance sets it"
        );
        require(
            c.absoluteCap18(mirrors[i].vault) == mirrors[i].absoluteCap18,
            "V9-04: capacity.absoluteCap18(vault) != vaults[i].absoluteCap18 in the book"
        );
        require(
            c.absoluteCap18(mirrors[i].vault) <= c.maxAbsoluteCap(),
            "V9-04: capacity.absoluteCap18(vault) above maxAbsoluteCap"
        );
        console2.log("  V9-07/08/04  registration, certificate pair, absoluteCap18  OK");
    }

    /// @dev §9 row 9, the venue-shaped half: these must match the venue's own per-market config
    ///      exactly. `sizeDecimals` in particular decides every hedge quantisation, and a wrong
    ///      `marketIndex` hedges the wrong asset while every read-back looks clean.
    function _checkMirrorConfigVenue(uint256 i) private view {
        (address cCollateral, uint16 cAssetIdx,, uint16 cMarketIndex, uint8 cSizeDecimals,,,,,) =
            CertVault(mirrors[i].vault).cfg();
        require(cCollateral == bookCollateral, "V9-09: cfg.collateral != shared.collateral in the book");
        require(
            cAssetIdx == LighterSim(bookLighterSim).collateralAssetIndex(),
            "V9-09: cfg.collateralAssetIndex != the venue's own collateralAssetIndex - every deposit reverts"
        );
        require(
            cMarketIndex == mirrors[i].marketIndex,
            "V9-09: cfg.marketIndex != vaults[i].marketIndex (the venue market_id)"
        );
        require(
            cSizeDecimals == mirrors[i].sizeDecimals,
            "V9-09: cfg.sizeDecimals != vaults[i].sizeDecimals (the venue size_decimals)"
        );
        require(
            cSizeDecimals == LighterSim(bookLighterSim).sizeDecimals(),
            "V9-09: cfg.sizeDecimals != the simulator's own sizeDecimals - every hedge mis-quantises"
        );
        console2.log("  V9-09        cfg venue half: collateral, indices, decimals  OK");
    }

    /// @dev §9 rows 9 and 10, the economics half, plus ITEM 4's FIRST AND MOST DANGEROUS
    ///      PRECONDITION.
    function _checkMirrorConfigEconomics(uint256 i) private view {
        (,,,,, uint256 cMintFee, uint256 cRedeemFee, uint256 cInstantCap, uint256 cBand, uint256 cMargin) =
            CertVault(mirrors[i].vault).cfg();
        require(cMintFee == p.mintFeeBps, "V9-09: cfg.mintFeeBps != parameters.mintFeeBps");
        require(cRedeemFee == p.redeemFeeBps, "V9-09: cfg.redeemFeeBps != parameters.redeemFeeBps");
        // A fee above 100% underflows `gross18 - fee18` inside `forceExit` for EVERY holder: a
        // reachable Law 2 breach. Bounded at construction since Finding 1; asserted anyway, because
        // this is the one row whose failure would take the last-resort redemption path with it.
        require(cRedeemFee <= 10_000, "V9-09: cfg.redeemFeeBps > 100pct - Law 2 breach in forceExit");
        require(cInstantCap == p.instantCap18, "V9-09: cfg.instantCap18 != parameters.instantCap18");
        require(cBand == p.settleBandBps, "V9-09: cfg.settleBandBps != parameters.settleBandBps");
        require(cMargin == p.targetMarginBps, "V9-09: cfg.targetMarginBps != parameters.targetMarginBps");

        // ---- ITEM 4, PRECONDITION 1 — THE SINGLE MOST DANGEROUS MISCONFIGURATION AVAILABLE ON A
        //      MULTI-VAULT DEPLOYMENT, and NOTHING asserts this pairing. `LighterSim` enforces its
        //      own floor against the venue and `CertVault`'s constructor enforces its own bounds on
        //      `targetMarginBps`, but NEITHER contract can see the other's number.
        //
        //      A vault whose `targetMarginBps` is BELOW the simulator's `requiredMarginBps` posts
        //      less margin than the venue demands, so `_coversInitialMargin` refuses the order and
        //      EVERY HEDGE IS SILENTLY REJECTED at settlement — `strictMode` is false, so the batch
        //      succeeds and only an `OrderRejected` event marks it — while the vault's own
        //      `venuePositionBase` keeps claiming the hedge was placed. It mints unhedged and
        //      believes otherwise. Our values are safe (9000 vs 5000); this asserts the PAIRING per
        //      vault, which is what a second mirror at a different margin would break.
        uint256 required = LighterSim(bookLighterSim).requiredMarginBps();
        require(
            cMargin >= required,
            "V9-P1: cfg.targetMarginBps < LighterSim.requiredMarginBps() - EVERY HEDGE IS SILENTLY REJECTED, the vault mints unhedged"
        );
        console2.log("  V9-09/10     cfg economics half                             OK");
        console2.log("  V9-P1        targetMarginBps >= sim requiredMarginBps       OK");
    }

    /// @dev §9 rows 10, 11, 12 and the tick domain, plus ITEM 4's SECOND PRECONDITION.
    function _checkMirrorSimAndTick(uint256 i) private view {
        CertVault v = CertVault(mirrors[i].vault);
        LighterSim s = LighterSim(bookLighterSim);

        // §9 row 10. `LighterCore.withdraw` takes a `uint64`, so a cap above that is a number the
        // venue cannot express.
        require(
            v.venueWithdrawCap() == p.venueWithdrawCap, "V9-10: vault.venueWithdrawCap() != parameters.venueWithdrawCap"
        );
        require(v.venueWithdrawCap() <= type(uint64).max, "V9-10: vault.venueWithdrawCap() > uint64 max");
        require(v.settleWindow() == p.settleWindow, "V9-10: vault.settleWindow() != parameters.settleWindow");

        // §9 row 11: the REGISTERING DEPOSIT HAS EXECUTED. `createOrder` reverts
        // `AccountIsNotRegistered` until the venue has populated the index, and on this simulator
        // registration is asynchronous — the deposit alone is not enough, a batch has to advance.
        // Until then every mint reverts as one atomic transaction.
        require(v.bootstrapped(), "V9-11: vault.bootstrapped() is false - bootstrap() was never called");
        require(
            v.lighterAccountIndex() != 0,
            "V9-11: vault.lighterAccountIndex() == 0 - the registering deposit has not been executed by a batch"
        );

        // §9 row 12. Reaching a bootstrapped vault already implies this — `bootstrap()` could not
        // have succeeded otherwise — so it is read back to catch the case where a LATER RUN
        // reorders the allowlist call after the bootstrap, and revocation is a live owner call.
        require(
            s.depositorAllowed(mirrors[i].vault),
            "V9-12: LighterSim.depositorAllowed(vault) is false - every further deposit reverts LighterSim_DepositorNotAllowed"
        );

        // ---- ITEM 4, PRECONDITION 2. A SINGLE UNMARKED MARKET REFUSES ITS WHOLE SETTLEMENT
        //      WINDOW: `settleBatch`'s pre-pass reverts `LighterSim_MarkPriceUnset` for the batch,
        //      not the order, so one unmarked market stops settlement for every vault sharing the
        //      simulator. And at a zero mark the mark-to-market layer is not merely missing a
        //      check, it is DEAD — notional is `|position| * 0`, so the margin gate passes
        //      vacuously at any size, and `entryPrice == 0` makes `unrealisedPnl()` permanently
        //      zero. Checked for the market EVERY ALLOWLISTED VAULT IS CONFIGURED FOR, which is
        //      what `_checkAllowlistIsRestricted` bounds to this set.
        require(
            s.markPrice(mirrors[i].marketIndex) != 0,
            "V9-P2: LighterSim.markPrice(cfg.marketIndex) is UNSET - settleBatch reverts for the whole batch and margin passes vacuously"
        );

        // §9's tick row: the live price is inside the uint32 domain at the configured
        // `priceDecimals`. Priced off `pxUnguarded()`, NOT `px()`: `px()` reverts on a stale feed,
        // which is a dead keeper and not a misconfiguration, and this row is about the DOMAIN. The
        // guarded read is reported under LIVENESS instead.
        (uint256 px18,) = CertOracle(mirrors[i].certOracle).pxUnguarded();
        require(px18 != 0, "V9-TK: oracle.pxUnguarded() is 0 - no feed observation and no last-good snapshot");
        try CertOracle(mirrors[i].certOracle).toTickPrice(px18) returns (uint32 tick) {
            require(tick != 0, "V9-TK: toTickPrice(pxUnguarded) == 0 - the price rounds to nothing at priceDecimals");
            console2.log("  V9-10/11/12  withdraw cap, bootstrap, allowlist row       OK");
            console2.log("  V9-P2        venue markPrice set for this market          OK");
            console2.log("  V9-TK        tick price", uint256(tick));
        } catch {
            // The only reasons `toTickPrice` reverts are tick == 0 or tick > uint32 max, and both
            // mean the same operational thing: this vault cannot place an order at the live price.
            revert(
                "V9-TK: oracle.toTickPrice(pxUnguarded) reverts CertOracle_TickOverflow - the live price is outside the uint32 tick domain at this priceDecimals"
            );
        }
    }

    // -------------------------------------------------- item 4, precondition 5: the allowed set

    /// @dev ITEM 4, PRECONDITION 5. "`depositorAllowed` restricted to the operator's own vaults,
    ///      AND REPORT THE FULL ALLOWED SET rather than just checking the vaults are in it. The
    ///      gate is conditional on that set being what the operator thinks it is, and nothing
    ///      enforces its size."
    ///
    ///      WHAT CAN AND CANNOT BE READ, STATED PLAINLY. `depositorAllowed` is a bare
    ///      `mapping(address => bool)` with no enumerable set beside it and no index-to-address
    ///      mapping on `LighterCore`, so THE ALLOWED SET IS NOT ENUMERABLE ON-CHAIN. A Solidity
    ///      script cannot call `eth_getLogs`, so the `DepositorAllowedSet` event history is out of
    ///      reach from here too. Rather than pretend, this discharges the requirement two ways and
    ///      says which is which:
    ///
    ///        1. THE PROBED SET, printed in full: every address the book knows about is queried and
    ///           its flag printed, so the operator sees the actual answer for each rather than a
    ///           bare "restricted". Every non-vault address among them is a hard failure — an
    ///           allowlisted sender, keeper or token contract is a second account able to reach
    ///           `MAX_QUEUE` and the shared queue.
    ///        2. THE REGISTERED COUNT, which is the fact that actually bounds the hazard.
    ///           `accountCount()` is the number of addresses that have EVER registered on this
    ///           venue, and an allowlisted address that never deposited holds no account, no
    ///           position and no collateral. `accountCount() == mirrors.length` therefore proves
    ///           NO ADDRESS OTHER THAN THESE VAULTS HAS AN ACCOUNT AT ALL — a stronger statement
    ///           than any per-address probe, and the one that closes Critical 1's and Critical 2's
    ///           entry conditions.
    ///
    ///      The residual gap: an address allowlisted but never yet deposited would pass both, and
    ///      is reported by (1) only if the book happens to name it. That is a real limit of the
    ///      contract's surface and is recorded as such in the task report, not papered over.
    function _checkAllowlistIsRestricted() private view {
        LighterSim s = LighterSim(bookLighterSim);
        console2.log("");
        console2.log("V9-P5    the depositor allowlist, as read (mapping is NOT enumerable on-chain)");
        for (uint256 i = 0; i < mirrors.length; ++i) {
            console2.log(string.concat("  ALLOWED   vault ", mirrors[i].symbol), mirrors[i].vault);
        }

        // Every other address the book names. A vault is the only thing that should ever be
        // allowlisted; each of these being false is a real assertion, not a formality.
        _requireNotAllowed(s, bookDeployer, "senders.deployer");
        _requireNotAllowed(s, bookGovernance, "senders.governance");
        _requireNotAllowed(s, bookAttester, "senders.attester");
        _requireNotAllowed(s, bookBatchKeeper, "shared.batchKeeper");
        _requireNotAllowed(s, bookCollateral, "shared.collateral");
        _requireNotAllowed(s, bookLighterSim, "shared.lighterSim");
        _requireNotAllowed(s, bookRegistry, "shared.solvencyRegistry");
        _requireNotAllowed(s, bookCapacity, "shared.capacityOracle");
        _requireNotAllowed(s, bookFactory, "shared.certFactory");
        _requireNotAllowed(s, address(0), "address(0)");
        if (bookTestFaucet != address(0)) _requireNotAllowed(s, bookTestFaucet, "shared.testFaucet");
        for (uint256 i = 0; i < mirrors.length; ++i) {
            _requireNotAllowed(s, mirrors[i].certificate, "vaults[i].certificate");
            _requireNotAllowed(s, mirrors[i].bufferBook, "vaults[i].bufferBook");
            _requireNotAllowed(s, mirrors[i].certOracle, "vaults[i].certOracle");
            _requireNotAllowed(s, mirrors[i].replayAggregator, "vaults[i].replayAggregator");
        }

        // The bound that actually matters. See the NatSpec above.
        console2.log("  registered accounts on the venue", s.accountCount());
        require(
            s.accountCount() == mirrors.length,
            "V9-P5: LighterSim.accountCount() != the number of vaults - an address other than the operator's vaults holds an account"
        );
        console2.log("  V9-P5   allowed set is the vaults, and NOTHING else holds an account  OK");
    }

    function _requireNotAllowed(LighterSim s, address a, string memory what) private view {
        require(
            !s.depositorAllowed(a),
            string.concat(
                "V9-P5: LighterSim.depositorAllowed is TRUE for ",
                what,
                " - a non-vault address can hold an account, reach MAX_QUEUE and share the settlement queue"
            )
        );
    }

    /// @dev The book-agreement half of §9's simulator row, run LAST. See `_checkSimulatorGlobals`
    ///      for why it is not there: the per-vault pairing (V9-P1) has to be reported first,
    ///      because it is the half that means "this vault is minting unhedged" rather than "this
    ///      JSON is stale". Both matter; only one of them is an emergency.
    function _checkSimBookAgreement() private view {
        require(
            LighterSim(bookLighterSim).requiredMarginBps() == p.simRequiredMarginBps,
            "V9-12: LighterSim.requiredMarginBps() != parameters.simRequiredMarginBps - the book is stale, re-run the deployment or fix the sim"
        );
        console2.log("V9-12    sim requiredMarginBps agrees with the book          OK");
    }

    // ----------------------------------------------------------------------------- liveness

    /// @dev REPORTED, NEVER ASSERTED, and the contract NatSpec says why: `docs/TESTNET-RUNBOOK.md`
    ///      §6 runs this script BEFORE the keepers are started, when the deployment's own seed
    ///      attestation is already minutes old against a 300 s deadline. These are the keepers'
    ///      job, not the deployment's, and a verifier that fails on them gets run with `|| true`.
    function _reportLiveness() private view {
        console2.log("");
        console2.log("LIVENESS (reported, not asserted - these are the keepers' job, see RUNBOOK 7.4)");
        SolvencyRegistry r = SolvencyRegistry(bookRegistry);
        CapacityOracle c = CapacityOracle(bookCapacity);
        for (uint256 i = 0; i < mirrors.length; ++i) {
            CertOracle o = CertOracle(mirrors[i].certOracle);
            console2.log(string.concat("  ", mirrors[i].symbol, ":"));
            uint256 age = r.ageSec(mirrors[i].vault);
            console2.log("    attestation age s          ", age);
            if (age > p.maxAttestationAgeSec) {
                console2.log(
                    "    ^^ STALE: maxNotional18 is 0 and MINTING IS OFF. Start script/keepers/Attester.s.sol."
                );
            }
            try o.px() returns (uint256 live) {
                console2.log("    feed px18 (guarded)        ", live);
            } catch {
                console2.log(
                    "    ^^ px() REVERTS: the feed is stale past stalenessSeconds. Start script/FeedKeeper.s.sol."
                );
            }
            (bool known, uint256 bps) = o.basisBpsChecked();
            if (known) {
                console2.log("    basis bps vs venue mark    ", bps);
                if (bps > p.basisBandBps) {
                    console2.log("    ^^ OUTSIDE basisBandBps: the mint gate is closed on the basis leg.");
                }
            } else {
                console2.log("    basis UNKNOWN (markPx18 unset in dual-source mode) - the mint gate is closed");
            }
            console2.log("    mintAllowed()              ", o.mintAllowed());
            console2.log(
                "    maxNotional18              ",
                c.maxNotional18(mirrors[i].vault, CertVault(mirrors[i].vault).bufferCapacity18())
            );
        }
    }
}
