// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployTestnet} from "../../script/DeployTestnet.s.sol";
import {CertVault} from "../../src/CertVault.sol";
import {Certificate} from "../../src/Certificate.sol";
import {CertOracle} from "../../src/CertOracle.sol";
import {CertFactory} from "../../src/CertFactory.sol";
import {SolvencyRegistry} from "../../src/SolvencyRegistry.sol";
import {CapacityOracle} from "../../src/CapacityOracle.sol";
import {LighterSim} from "../../src/sim/LighterSim.sol";
import {ReplayAggregator} from "../../src/sim/ReplayAggregator.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice A `DeployTestnet` that "forgets" `setAbsoluteCap`, to prove the most likely
///         misconfiguration is caught before anything is broadcast.
/// @dev Overrides the governance phase and keeps everything else, so the ONLY difference from a
///      real run is the missing cap — exactly the state §5 warns about, where the vault is
///      registered, bootstrapped, attested and `mintAllowed()`, and still cannot mint because
///      `absoluteCap18` is zero and `maxNotional18`'s `min()` reads zero as "no capacity".
contract DeployTestnetNoCap is DeployTestnet {
    function _phase4_governance() internal override {
        for (uint256 i = 0; i < assets.length; ++i) {
            CertFactory(factory).registerVault(deployed[i].vault, deployed[i].certificate);
            // setAbsoluteCap DELIBERATELY OMITTED. Everything else is a normal run.
            CertVault(deployed[i].vault).setBufferThresholds(
                assets[i].bufferFloor18, assets[i].bufferFeeOn18, assets[i].bufferMintSlow18, 0
            );
        }
    }
}

/// @notice A `DeployTestnet` whose governance key is the deployer's, to prove the three-sender
///         separation §4 requires is actually enforced rather than merely documented.
/// @dev Overrides the key seam instead of mutating `GOV_PK` in the environment: `vm.setEnv` writes
///      process-global state that Foundry does not roll back between test cases, so an env-mutating
///      test corrupts its neighbours.
contract DeployTestnetCollapsedSenders is DeployTestnet {
    function _senderKeys() internal view override returns (uint256, uint256, uint256) {
        (uint256 d,, uint256 a) = super._senderKeys();
        return (d, d, a);
    }
}

/// @notice A `DeployTestnet` pointed at an 18-decimal collateral token.
contract DeployTestnetWrongDecimals is DeployTestnet {
    address public immutable badToken;

    constructor(address badToken_) {
        badToken = badToken_;
    }

    function _collateralAddress() internal view override returns (address) {
        return badToken;
    }
}

/// @notice A `DeployTestnet` with no collateral at all — the Task 8 blocker as a guard.
contract DeployTestnetNoCollateral is DeployTestnet {
    function _collateralAddress() internal view override returns (address) {
        return address(0);
    }
}

/// @notice Task 10's tests. Runs `script/DeployTestnet.s.sol` in-process against a local chain
///         with the chain ID overridden to 46630, and asserts the deployment is not merely
///         constructed but actually USABLE end to end.
///
/// @dev WHAT THESE TESTS CAN AND CANNOT PROVE — the same distinction the script's own NatSpec
///      makes. `vm.startBroadcast` in a test executes the calls in-process, so this file proves the
///      script's LOGIC, ORDER and PARAMETERS are right, and that the resulting stack mints and
///      exits. It does NOT prove anything about a live chain: `forge script --broadcast` simulates
///      the whole run first and only then sends transactions, so the script's `require`s never
///      observe on-chain state. `script/VerifyTestnet.s.sol` (Task 11) is what discharges
///      `docs/DEPLOYMENT-CHECKLIST.md` §9 against a real deployment. Neither file replaces the
///      other.
contract DeployTestnetTest is Test {
    DeployTestnet internal script;
    MockERC20 internal collateral;

    /// @dev Well-known throwaway test keys. The SCRIPT never hardcodes a key — it reads all three
    ///      from the environment, which is what lets the operator hold the real ones. These exist
    ///      only so the test can populate that environment.
    uint256 internal constant DEPLOYER_PK = 0xD3910;
    uint256 internal constant GOV_PK = 0x60;
    uint256 internal constant ATTESTER_PK = 0xA77E5;

    uint256 internal constant CHAIN_ID = 46_630;

    address internal deployerAddr;
    address internal govAddr;
    address internal attesterAddr;
    address internal alice = makeAddr("alice");

    /// @dev Task 7 gated `LighterSim.settleBatch` to `owner` or `keeper`. This is the address the
    ///      script registers as `keeper` (env `BATCH_KEEPER`), standing in for Task 12's
    ///      `BatchAdvancer` bot — a distinct key from all three senders, same as the real deployment
    ///      would use.
    address internal batchKeeperAddr = makeAddr("batchKeeper");

    function setUp() public {
        // A real-ish wall clock: `ReplayAggregator`'s constructor stamps round 1 at
        // `block.timestamp`, and `CertOracle`'s constructor rejects a feed whose observation is
        // already older than `stalenessSeconds` (900). At Foundry's default timestamp of 1 the
        // subtraction is fine but the figures read as nonsense.
        vm.warp(1_800_000_000);
        vm.chainId(CHAIN_ID);

        deployerAddr = vm.addr(DEPLOYER_PK);
        govAddr = vm.addr(GOV_PK);
        attesterAddr = vm.addr(ATTESTER_PK);

        // THE BLOCKER, WORKED AROUND ONLY INSIDE THIS TEST. Task 8 owns the deployable 6-decimal
        // test collateral (`src/sim/TestFaucet.sol` and its token) and it has not landed, so the
        // script takes the collateral as an injected address. Here that injection is satisfied by
        // `test/mocks/MockERC20.sol` at 6 decimals — a TEST mock, which is why the script does not
        // and must not reference it. Six decimals matters: `CertVault` reads the collateral's
        // decimals once, at construction, into an immutable.
        collateral = new MockERC20("Test USDG", "tUSDG", 6);

        // The deployer funds both vaults' buffer seeds (2 x 100_000e6) plus bootstrap dust.
        collateral.mint(deployerAddr, 1_000_000e6);
        vm.deal(deployerAddr, 100 ether);
        vm.deal(govAddr, 100 ether);
        vm.deal(attesterAddr, 100 ether);

        vm.setEnv("DEPLOYER_PK", vm.toString(bytes32(DEPLOYER_PK)));
        vm.setEnv("GOV_PK", vm.toString(bytes32(GOV_PK)));
        vm.setEnv("ATTESTER_PK", vm.toString(bytes32(ATTESTER_PK)));
        vm.setEnv("COLLATERAL", vm.toString(address(collateral)));
        vm.setEnv("BATCH_KEEPER", vm.toString(batchKeeperAddr));
        vm.setEnv("COMMIT", "test-run-not-a-real-commit");

        script = new DeployTestnet();
    }

    // ------------------------------------------------------------------------------- the run

    /// @notice The whole script against a local chain with `chainid` overridden, asserting every
    ///         §9 read-back passes.
    /// @dev The script's own `require`s ARE the §9 read-backs, so `run()` completing without
    ///         reverting is the first half of this assertion. The second half re-derives the
    ///         sharpest items here independently, so a `require` accidentally deleted from the
    ///         script fails a test rather than passing silently.
    function test_deployScriptRunsCleanOnAnvil() public {
        script.run();

        (
            address collateral_,
            address faucet_,
            address lighter_,
            address registry_,
            address capacity_,
            address factory_
        ) = script.sharedAddresses();

        assertEq(collateral_, address(collateral), "collateral");
        assertEq(faucet_, address(0), "faucet: Task 8 has not landed, so it must be recorded as zero");
        assertTrue(lighter_.code.length > 0, "LighterSim has no code");
        assertTrue(registry_.code.length > 0, "SolvencyRegistry has no code");
        assertTrue(capacity_.code.length > 0, "CapacityOracle has no code");
        assertTrue(factory_.code.length > 0, "CertFactory has no code");

        // §4, THE ITEM WITH NO REMEDY BUT REDEPLOYMENT: governance bound to the GOV key at
        // construction, because the script constructed it under `vm.startBroadcast(GOV_PK)` in
        // `run()`'s own frame. If this ever reads as the script's address, §4 has been violated.
        assertEq(SolvencyRegistry(registry_).governance(), govAddr, "registry.governance != GOV");
        assertTrue(SolvencyRegistry(registry_).governance() != address(script), "governance landed on the script");
        assertEq(SolvencyRegistry(registry_).attester(), attesterAddr, "registry.attester");
        assertEq(SolvencyRegistry(registry_).pendingAttester(), address(0), "registry.pendingAttester");
        assertEq(SolvencyRegistry(registry_).ATTESTER_ROTATION_DELAY(), 2 days, "rotation delay");

        // §5: the immutable ceiling on a lying attester is a real, finite number.
        assertEq(CapacityOracle(capacity_).maxAbsoluteCap(), 1_000_000_000e18, "maxAbsoluteCap");
        assertTrue(CapacityOracle(capacity_).maxAbsoluteCap() != type(uint256).max, "maxAbsoluteCap unbounded");
        assertEq(CapacityOracle(capacity_).governance(), govAddr, "capacity.governance");

        assertEq(script.assetCount(), 2, "two mirrors");
        assertEq(CertFactory(factory_).vaultCount(), 2, "factory.vaultCount");

        // uTSLA FIRST, uSPY SECOND. The order is a requirement, not an accident: TSLA (16) for
        // continuity with the existing suite, then SPY (26) - not NVDA.
        assertEq(script.paramsOf(0).marketIndex, 16, "first mirror is market 16 (TSLA)");
        assertEq(script.paramsOf(1).marketIndex, 26, "second mirror is market 26 (SPY)");
        assertEq(script.paramsOf(0).symbol, "uTSLA", "first symbol");
        assertEq(script.paramsOf(1).symbol, "uSPY", "second symbol");

        for (uint256 i = 0; i < 2; ++i) {
            _assertMirrorUsable(i, lighter_, registry_, capacity_, factory_);
        }

        _assertAddressBookWritten();
    }

    /// @dev The address book is a deliverable, not a log line: `script/VerifyTestnet.s.sol` reads it
    ///      to re-assert §9 on-chain, and the front-end adapter reads it for every address it
    ///      displays. So assert it was actually written and that the addresses in it are the ones
    ///      deployed — a book that silently disagreed with the chain is the failure mode the
    ///      "never hand-edit" rule exists to prevent.
    function _assertAddressBookWritten() internal view {
        string memory book = vm.readFile("deployments/46630.json");
        assertTrue(bytes(book).length > 0, "address book is empty");

        assertEq(vm.parseJsonUint(book, ".chainId"), CHAIN_ID, "book chainId");
        assertEq(vm.parseJsonAddress(book, ".senders.governance"), govAddr, "book governance");
        assertEq(vm.parseJsonAddress(book, ".senders.attester"), attesterAddr, "book attester");
        assertEq(vm.parseJsonAddress(book, ".shared.collateral"), address(collateral), "book collateral");
        assertEq(vm.parseJsonUint(book, ".shared.collateralDecimals"), 6, "book collateralDecimals");

        // The parameters a reader must not have to guess at, and the two loud notes.
        assertEq(vm.parseJsonUint(book, ".parameters.targetMarginBps"), 9_000, "book targetMarginBps");
        assertEq(vm.parseJsonUint(book, ".parameters.stalenessSeconds"), 900, "book stalenessSeconds");
        assertEq(vm.parseJsonUint(book, ".parameters.deviationBps"), 500, "book deviationBps");
        assertFalse(vm.parseJsonBool(book, ".parameters.singleSource"), "book singleSource");

        // Both mirrors, in order, with the addresses the run actually produced.
        assertEq(vm.parseJsonAddress(book, ".vaults[0].vault"), script.deploymentOf(0).vault, "book vault 0");
        assertEq(vm.parseJsonAddress(book, ".vaults[1].vault"), script.deploymentOf(1).vault, "book vault 1");
        assertEq(
            vm.parseJsonAddress(book, ".vaults[0].certificate"), script.deploymentOf(0).certificate, "book cert 0"
        );
        assertEq(vm.parseJsonUint(book, ".vaults[0].marketIndex"), 16, "book market 0 is TSLA");
        assertEq(vm.parseJsonUint(book, ".vaults[1].marketIndex"), 26, "book market 1 is SPY");
    }

    function _assertMirrorUsable(uint256 i, address lighter_, address registry_, address capacity_, address factory_)
        internal
    {
        DeployTestnet.AssetDeployment memory d = script.deploymentOf(i);
        DeployTestnet.AssetParams memory a = script.paramsOf(i);
        CertVault v = CertVault(d.vault);
        CertOracle o = CertOracle(d.oracle);

        // §4 again, per oracle. Each mirror gets its own CertOracle and each one binds governance
        // at construction.
        assertEq(o.governance(), govAddr, "oracle.governance != GOV");
        assertTrue(o.governance() != address(script), "oracle governance landed on the script");
        assertEq(o.attester(), attesterAddr, "oracle.attester");
        assertEq(o.pendingAttester(), address(0), "oracle.pendingAttester");

        // §2: the parameters that must never be wrong.
        assertEq(address(o.feed()), d.aggregator, "oracle.feed");
        assertEq(o.deviationBps(), 500, "deviationBps");
        assertTrue(o.deviationBps() != 0, "deviationBps == 0 locks minting shut");
        assertEq(o.stalenessSeconds(), 900, "stalenessSeconds: the testnet reachability value");
        assertEq(o.pokeConfirmationSeconds(), 300, "pokeConfirmationSeconds");
        assertTrue(o.pokeConfirmationSeconds() != 0, "pokeConfirmationSeconds == 0");
        assertEq(o.basisBandBps(), 500, "basisBandBps");
        assertFalse(o.singleSource(), "singleSource must be false for a fed market at 500 bps");
        assertEq(o.priceDecimals(), a.priceDecimals, "priceDecimals");
        assertEq(uint256(a.priceDecimals), 2, "venue price_decimals is 2 for both markets");
        assertEq(uint256(a.sizeDecimals), 4, "venue size_decimals is 4 for both markets");

        // THE SINGLE MOST LIKELY WAY THIS DEPLOYMENT APPEARS BROKEN.
        assertEq(CapacityOracle(capacity_).absoluteCap18(d.vault), a.absoluteCap18, "absoluteCap18");
        assertTrue(CapacityOracle(capacity_).absoluteCap18(d.vault) != 0, "absoluteCap18 UNSET");

        // §9: the five immutable dependencies, and the cross-check `registerVault` does NOT do.
        assertEq(v.governance(), govAddr, "vault.governance");
        assertEq(address(v.lighter()), lighter_, "vault.lighter");
        assertEq(address(v.oracle()), d.oracle, "vault.oracle");
        assertEq(address(v.registry()), registry_, "vault.registry");
        assertEq(address(v.capacity()), capacity_, "vault.capacity");
        assertEq(address(v.lighter()), CertFactory(factory_).lighter(), "vault.lighter != factory.lighter");
        assertEq(address(v.registry()), CertFactory(factory_).registry(), "vault.registry != factory.registry");
        assertEq(address(v.capacity()), CertFactory(factory_).capacity(), "vault.capacity != factory.capacity");
        assertEq(v.governance(), CertFactory(factory_).governance(), "vault.governance != factory.governance");

        // §9: registration and the certificate cross-check.
        assertTrue(CertFactory(factory_).isVault(d.vault), "isVault");
        assertEq(CertFactory(factory_).vaults(i), d.vault, "vaults(i)");
        assertEq(address(v.certificate()), d.certificate, "vault.certificate");
        assertEq(Certificate(d.certificate).symbol(), a.symbol, "certificate.symbol");
        assertEq(Certificate(d.certificate).vault(), d.vault, "certificate.vault");

        // §9: the venue-shaped config and the caps.
        assertEq(v.venueWithdrawCap(), uint256(type(uint64).max), "venueWithdrawCap");
        assertTrue(v.venueWithdrawCap() <= uint256(type(uint64).max), "venueWithdrawCap > uint64");
        assertEq(v.settleWindow(), 1 days, "settleWindow");

        // §9: the registering deposit has EXECUTED. This is what the mandatory batch advance buys,
        // and without it every mint reverts `AccountIsNotRegistered` as one atomic transaction.
        assertTrue(v.bootstrapped(), "not bootstrapped");
        assertTrue(v.lighterAccountIndex() != 0, "lighterAccountIndex == 0: batch was not advanced");

        // PLAN STEP 3a. Without this row `bootstrap()` above would have reverted
        // `LighterSim_DepositorNotAllowed`, so reaching here already proves it - asserted anyway,
        // because a future refactor could reorder the allowlist after the bootstrap and this is the
        // assertion that would catch it.
        assertTrue(LighterSim(lighter_).depositorAllowed(d.vault), "depositorAllowed(vault) false");

        // Global Constraint 5: the simulator must never be easier than the venue.
        assertEq(LighterSim(lighter_).requiredMarginBps(), 5_000, "sim margin != verified venue IMF");
        assertTrue(
            LighterSim(lighter_).requiredMarginBps() >= LighterSim(lighter_).VENUE_IMF_BPS(), "sim below venue floor"
        );
        assertEq(LighterSim(lighter_).owner(), deployerAddr, "sim owner");
        // Task 7 / Task 10: the keeper the script registered is the one the address book must agree
        // with, or Task 12's BatchAdvancer reverts LighterSim_OnlyOwnerOrKeeper the first time it
        // calls in - indistinguishable from a dead keeper.
        assertEq(LighterSim(lighter_).keeper(), batchKeeperAddr, "sim keeper != BATCH_KEEPER");
        // The venue mark, without which `settleBatch` refuses the batch and the whole
        // mark-to-market layer would be dead (zero notional, zero PnL, vacuous margin gate).
        assertEq(LighterSim(lighter_).markPrice(a.marketIndex), a.seedPx18, "venue markPrice");

        // §9: the live price is inside the uint32 tick domain at this market's price_decimals.
        assertTrue(o.toTickPrice(o.px()) != 0, "toTickPrice == 0");

        // The attestation is live and the MINT GATE IS ACTUALLY OPEN. This is the assertion the
        // whole deployment exists to reach.
        assertTrue(SolvencyRegistry(registry_).ageSec(d.vault) <= 300, "attestation stale at deploy");
        assertEq(SolvencyRegistry(registry_).latest(d.vault).openInterest18, a.openInterest18, "attested OI");
        assertTrue(o.markPx18() != 0, "markPx18 == 0");
        (bool known, uint256 bps) = o.basisBpsChecked();
        assertTrue(known, "basis unknown in dual-source mode");
        assertLe(bps, 500, "basis outside the band");
        assertTrue(o.mintAllowed(), "MINT GATE CLOSED: mintAllowed() false");
        assertTrue(
            CapacityOracle(capacity_).maxNotional18(d.vault, v.bufferCapacity18()) != 0,
            "MINT GATE CLOSED: maxNotional18 == 0"
        );
    }

    // ------------------------------------------------------- the end-to-end proof, mint to exit

    /// @notice THE ONE THAT MATTERS: the freshly deployed stack mints and then force-exits.
    /// @dev Everything above proves the wiring reads back correctly. This proves the stack WORKS —
    ///      a mint pulls collateral, quantises to the venue's own tick, posts margin, opens a hedge
    ///      the simulator actually accepts under its margin gate, and then `forceExit` — Law 2's
    ///      last-resort backstop, which must never revert for a holder with a balance — burns the
    ///      certificates and books the obligation. Run for BOTH mirrors, since uSPY's numbers
    ///      differ from uTSLA's by ~1.8x in price and 55x in capacity.
    function test_deployedVaultCanMintAndForceExit() public {
        script.run();
        (,, address lighter_,,,) = script.sharedAddresses();

        for (uint256 i = 0; i < script.assetCount(); ++i) {
            DeployTestnet.AssetDeployment memory d = script.deploymentOf(i);
            CertVault v = CertVault(d.vault);
            Certificate cert = Certificate(d.certificate);

            // $900 of collateral. Sized to stay under `instantCap18` of 1_000e18 of NOTIONAL at
            // both mirrors' seed prices - the instant cap is the whole reason a tester crosses into
            // the queued path, and this test is about the instant path.
            uint256 amountIn = 900e6;
            collateral.mint(alice, amountIn);
            vm.startPrank(alice);
            collateral.approve(d.vault, amountIn);
            uint256 certOut = v.mintInstant(amountIn);
            vm.stopPrank();

            assertTrue(certOut > 0, "mintInstant returned zero certificates");
            assertEq(cert.balanceOf(alice), certOut, "certificate balance != certOut");
            assertEq(cert.totalSupply(), certOut, "totalSupply != certOut");

            // The hedge was submitted, not merely intended. It settles on the next batch, exactly
            // as the real venue's asynchronous fills do. Task 7 gates `settleBatch` to `owner` or
            // `keeper`; called here as the keeper the script registered (env `BATCH_KEEPER`), the
            // same key Task 12's `BatchAdvancer` would sign with - not the owner, so this also
            // exercises the keeper path the deployment wires up rather than only the owner's.
            vm.prank(batchKeeperAddr);
            LighterSim(lighter_).settleBatch();
            assertTrue(LighterSim(lighter_).positionBase(script.paramsOf(i).marketIndex) != 0, "no hedge opened");

            // LAW 2. `forceExit` must work for a holder with a balance, at any price, in any oracle
            // or buffer state. It prices off `pxUnguarded()`, which never reverts.
            vm.prank(alice);
            uint256 receiptId = v.forceExit(certOut);

            assertEq(cert.balanceOf(alice), 0, "certificates not burned by forceExit");
            assertEq(cert.totalSupply(), 0, "totalSupply not reduced by forceExit");
            assertTrue(v.totalOwedOutstanding() > 0, "forceExit booked no obligation");

            // The closing order reaches the venue and the venue accepts it. A revert here would
            // mean the exit hedge was unsettleable, which is the failure mode Global Constraint 5
            // exists to make visible. Again as the registered keeper, not the owner.
            vm.prank(batchKeeperAddr);
            LighterSim(lighter_).settleBatch();

            // The receipt is real. Receipt ids are per-vault and start at 1, so this also pins that
            // the exit was recorded rather than silently no-oped.
            assertTrue(receiptId != 0, "forceExit returned receipt id 0");
        }
    }

    // ------------------------------------------------------------------------------ the guards

    /// @notice The script cannot be pointed at another chain by accident.
    /// @dev Mainnet's chain ID is still unverified (`docs/TESTNET-PLAN.md` §8), which is why the
    ///      guard is an equality against 46630 rather than a "not mainnet" test - a blocklist
    ///      cannot block an ID nobody has measured.
    function test_scriptRevertsOnWrongChainId() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployTestnet.DeployTestnet_WrongChain.selector, 1, CHAIN_ID));
        script.run();

        // And not merely "not 1": a neighbouring testnet is refused too.
        vm.chainId(46_631);
        vm.expectRevert(abi.encodeWithSelector(DeployTestnet.DeployTestnet_WrongChain.selector, 46_631, CHAIN_ID));
        script.run();
    }

    /// @notice The most likely misconfiguration is caught BEFORE anything is broadcast.
    /// @dev `absoluteCap18` is zero by default and `maxNotional18`'s `min()` reads zero as "no
    ///      capacity", not "unbounded". A vault in that state looks perfectly deployed —
    ///      registered, bootstrapped, attested, `mintAllowed() == true` — and reverts
    ///      `CertVault_AtCapacity` on every single mint, with governance the only party who can
    ///      repair it. This test runs a script that omits exactly that one call and asserts the
    ///      §9 read-back names it.
    function test_scriptRevertsIfAbsoluteCapUnset() public {
        DeployTestnetNoCap broken = new DeployTestnetNoCap();
        vm.expectRevert(bytes("S9: absoluteCap18(vault) UNSET - cannot mint"));
        broken.run();
    }

    /// @notice The three senders must be distinct, or §4's separation is defeated silently.
    /// @dev With governance == deployer, "governance is a multisig" stops being true and the
    ///      emergency `setAbsoluteCap(vault, 0)` lever sits on the key that ran the deployment.
    function test_scriptRevertsIfSendersCollapse() public {
        DeployTestnetCollapsedSenders broken = new DeployTestnetCollapsedSenders();
        vm.expectRevert(bytes("SENDERS: deployer == governance"));
        broken.run();
    }

    /// @notice The collateral's decimals are checked, because `CertVault` fixes them immutably.
    /// @dev `USDG` has 6. An 18-decimal token would make every `_to18`/`_from18` conversion wrong
    ///      in both directions forever — every published figure off by 10**12 — with no setter to
    ///      repair it. Cheap check, unrepairable failure.
    function test_scriptRevertsOnWrongCollateralDecimals() public {
        MockERC20 wrong = new MockERC20("Wrong", "WRONG", 18);
        wrong.mint(deployerAddr, 1_000_000e18);
        DeployTestnetWrongDecimals broken = new DeployTestnetWrongDecimals(address(wrong));
        vm.expectRevert(bytes("COLLATERAL: decimals() != 6 - CertVault fixes this immutably at construction"));
        broken.run();
    }

    /// @notice The collateral is not optional, and its absence is named rather than a zero address
    ///         propagating into two immutable vault configs.
    /// @dev This is the Task 8 blocker surfacing as a guard: the deployable 6-decimal token and
    ///      `src/sim/TestFaucet.sol` are Task 8's artefacts and are not in this tree.
    function test_scriptRevertsWithoutCollateral() public {
        DeployTestnetNoCollateral broken = new DeployTestnetNoCollateral();
        vm.expectRevert(DeployTestnet.DeployTestnet_MissingCollateral.selector);
        broken.run();
    }
}
