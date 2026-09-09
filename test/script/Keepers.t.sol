// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CertVault} from "../../src/CertVault.sol";
import {Certificate} from "../../src/Certificate.sol";
import {CertOracle} from "../../src/CertOracle.sol";
import {SolvencyRegistry} from "../../src/SolvencyRegistry.sol";
import {CapacityOracle} from "../../src/CapacityOracle.sol";
import {LighterSim} from "../../src/sim/LighterSim.sol";
import {ReplayAggregator} from "../../src/sim/ReplayAggregator.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

import {Attester} from "../../script/keepers/Attester.s.sol";
import {BatchAdvancer} from "../../script/keepers/BatchAdvancer.s.sol";
import {VenueTruth} from "../../script/keepers/VenueTruth.sol";

/// @notice An `Attester` whose address book is supplied in memory rather than read from
///         `deployments/46630.json`.
/// @dev Overrides `_bookJson()` — the FILE READ — and not `_book()`, so the real parser still runs
///      over a book in the exact format `DeployTestnet._writeAddressBook()` emits. It does not run
///      the deploy script, because that writes `deployments/46630.json` unconditionally and
///      `test/script/DeployTestnet.t.sol` reads that path back asserting its own addresses; a
///      second suite writing it in parallel would make that test fail intermittently. The live
///      `anvil` run in the runbook is what exercises the real file end to end.
contract AttesterWithBook is Attester {
    string internal book;
    uint256 internal key;

    function setBook(string memory json) external {
        book = json;
    }

    function setKey(uint256 k) external {
        key = k;
    }

    function _bookJson() internal view override returns (string memory) {
        return book;
    }

    /// @dev Injected rather than set with `vm.setEnv`, and that is a MEASURED choice: a `setEnv`
    ///      inside a test function is not rolled back when Foundry reverts to the post-`setUp`
    ///      snapshot, and a restore at the end of that test does not reliably take effect for the
    ///      next one. The wrong-key tests below would have silently corrupted every test after
    ///      them — six of them did, before this seam existed.
    function _signerKey() internal view override returns (uint256) {
        return key;
    }

    /// @dev Exposed so the test can assert the keeper's read logic against the simulator's raw
    ///      per-account storage without going through a broadcast.
    function figures(address sim, address vault, uint16 marketIndex)
        external
        view
        returns (uint256 notional18, uint256 margin18, uint256 markPx18)
    {
        notional18 = VenueTruth.notional18(LighterSim(sim), vault, marketIndex);
        margin18 = VenueTruth.margin18(LighterSim(sim), vault);
        markPx18 = VenueTruth.markPx18(LighterSim(sim), marketIndex);
    }
}

/// @notice A `BatchAdvancer` with the same in-memory book seam.
contract BatchAdvancerWithBook is BatchAdvancer {
    string internal book;
    uint256 internal key;

    function setBook(string memory json) external {
        book = json;
    }

    function setKey(uint256 k) external {
        key = k;
    }

    function _bookJson() internal view override returns (string memory) {
        return book;
    }

    function _signerKey() internal view override returns (uint256) {
        return key;
    }
}

/// @notice TASK 12 ACCEPTANCE. The two keepers, driven against a stack built with the deployment's
///         own parameters, on chain id 46630.
///
/// @dev WHAT THIS FILE PROVES AND WHAT IT DOES NOT. `vm.broadcast` inside a test executes the call
///      in-process, so this proves the keepers' LOGIC — which addresses they read, which key they
///      sign with, which figures they compute, and that the figures equal the simulator's own
///      per-account books. It does NOT prove anything about a live chain: an RPC, a nonce, a gas
///      price and a real `deployments/46630.json` are all absent here. The `anvil --chain-id 46630`
///      run recorded in the Task 12 report is the other half, and neither replaces the other —
///      the same distinction `test/script/DeployTestnet.t.sol` draws about the deploy script.
contract KeepersTest is Test {
    // The deployment's own numbers, so what is tested is what gets deployed. Sourced from
    // `script/DeployTestnet.s.sol`; the ones that matter to this file are called out below.
    uint256 internal constant CHAIN_ID = 46_630;
    uint16 internal constant ASSET_IDX = 3;
    uint8 internal constant SIZE_DECIMALS = 4;
    uint16 internal constant MARKET = 16; // TSLA
    uint256 internal constant PX_18 = 366.6204e18;
    int256 internal constant FEED_PX_8 = 36_662_040_000;
    uint256 internal constant SIM_IMF = 5_000;
    uint256 internal constant TARGET_MARGIN_BPS = 9_000;
    uint256 internal constant INSTANT_CAP_18 = 1_000e18;
    uint256 internal constant SETTLE_WINDOW = 1 days;
    uint256 internal constant VENUE_WITHDRAW_CAP = type(uint64).max;
    uint256 internal constant MAX_ABSOLUTE_CAP_18 = 1_000_000_000e18;
    uint256 internal constant ABSOLUTE_CAP_18 = 90_000e18;
    uint256 internal constant OPEN_INTEREST_18 = 900_000e18;
    uint256 internal constant SEED_COLLATERAL = 100_000e6;

    /// @dev THE TWO PARAMETERS THIS WHOLE TASK EXISTS FOR. Both immutable at construction.
    uint256 internal constant MAX_ATTESTATION_AGE_SEC = 300;
    uint256 internal constant STALENESS_SECONDS = 900;
    uint256 internal constant POKE_CONFIRMATION_SECONDS = 300;

    MockERC20 internal usdg;
    ReplayAggregator internal feed;
    LighterSim internal sim;
    SolvencyRegistry internal reg;
    CapacityOracle internal cap;
    CertOracle internal oracle;
    CertVault internal vault;
    Certificate internal cert;

    AttesterWithBook internal attesterKeeper;
    BatchAdvancerWithBook internal batchKeeper;

    /// @dev Throwaway keys. The SCRIPTS never hardcode one — both read the environment, which is
    ///      what lets the operator hold the real ones. These exist only so the test can sign.
    uint256 internal constant ATTESTER_PK = 0xA77E5;
    uint256 internal constant BATCH_KEEPER_PK = 0xB47C4;
    uint256 internal constant WRONG_PK = 0xBAD;

    address internal attesterAddr;
    address internal batchKeeperAddr;
    address internal gov = makeAddr("gov");
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");

    function setUp() public {
        // A real-ish wall clock: `ReplayAggregator`'s constructor stamps round 1 at
        // `block.timestamp`, and `CertOracle`'s constructor rejects a feed already older than
        // `stalenessSeconds`. Also leaves headroom to warp forward past 300 s without underflowing.
        vm.warp(1_800_000_000);
        vm.chainId(CHAIN_ID);

        attesterAddr = vm.addr(ATTESTER_PK);
        batchKeeperAddr = vm.addr(BATCH_KEEPER_PK);

        usdg = new MockERC20("Test USDG", "tUSDG", 6);

        vm.startPrank(deployer);
        feed = new ReplayAggregator(deployer, 8, "RHTSLA / USD", FEED_PX_8);
        sim = new LighterSim(IERC20(address(usdg)), ASSET_IDX, SIZE_DECIMALS, SIM_IMF, deployer);
        vm.stopPrank();

        // Governance constructs the registry and the oracle itself: both bind `governance =
        // msg.sender` immutably. Mirrors phase 2 of the deploy script.
        vm.startPrank(gov);
        reg = new SolvencyRegistry(attesterAddr);
        cap = new CapacityOracle(address(reg), gov, 1_000, 100, 3_000, MAX_ATTESTATION_AGE_SEC, MAX_ABSOLUTE_CAP_18);
        oracle = new CertOracle(
            address(feed), attesterAddr, 2, STALENESS_SECONDS, 500, 500, POKE_CONFIRMATION_SECONDS, false
        );
        vm.stopPrank();

        vault = new CertVault(
            CertVault.Deps({
                lighter: address(sim),
                oracle: address(oracle),
                registry: address(reg),
                capacity: address(cap),
                governance: gov
            }),
            CertVault.VaultConfig({
                collateral: address(usdg),
                collateralAssetIndex: ASSET_IDX,
                routeType: 0,
                marketIndex: MARKET,
                sizeDecimals: SIZE_DECIMALS,
                mintFeeBps: 10,
                redeemFeeBps: 10,
                instantCap18: INSTANT_CAP_18,
                settleBandBps: 500,
                targetMarginBps: TARGET_MARGIN_BPS
            }),
            VENUE_WITHDRAW_CAP,
            SETTLE_WINDOW,
            "UseCert TSLA",
            "uTSLA"
        );
        cert = Certificate(address(vault.certificate()));

        vm.prank(gov);
        cap.setAbsoluteCap(address(vault), ABSOLUTE_CAP_18);

        // Phase 5, in the deploy script's order: allowlist, venue mark, keeper, collateral in,
        // bootstrap, batch advance.
        vm.startPrank(deployer);
        sim.setDepositorAllowed(address(vault), true);
        sim.setMarkPrice(MARKET, PX_18);
        sim.setKeeper(batchKeeperAddr);
        vm.stopPrank();

        usdg.mint(deployer, SEED_COLLATERAL);
        vm.startPrank(deployer);
        usdg.approve(address(vault), SEED_COLLATERAL);
        vault.seedBuffer(SEED_COLLATERAL);
        vault.bootstrap();
        vm.stopPrank();

        vm.prank(batchKeeperAddr);
        sim.settleBatch();

        // Phase 6: the seed attestation, batch 1.
        vm.startPrank(attesterAddr);
        reg.attest(address(vault), 1, 0, 0, OPEN_INTEREST_18);
        oracle.setMarkPrice(PX_18);
        vm.stopPrank();

        assertTrue(vault.bootstrapped(), "fixture: not bootstrapped");
        assertTrue(vault.lighterAccountIndex() != 0, "fixture: batch never advanced");
        assertTrue(oracle.mintAllowed(), "fixture: mint gate closed at t0");

        // In production both keepers read their one key from the environment (`ATTESTER_PK`,
        // `BATCH_KEEPER_PK`). Here they are injected through the same seam the deploy script uses
        // for its senders — see `AttesterWithBook._signerKey()` for why the environment is not
        // touched by this file at all. Every ADDRESS still comes from the address book.
        attesterKeeper = new AttesterWithBook();
        attesterKeeper.setBook(_bookJson());
        attesterKeeper.setKey(ATTESTER_PK);
        batchKeeper = new BatchAdvancerWithBook();
        batchKeeper.setBook(_bookJson());
        batchKeeper.setKey(BATCH_KEEPER_PK);
    }

    /// @dev The address book, in the exact shape `DeployTestnet._writeAddressBook()` emits — the
    ///      nesting, the key names, and the big figures quoted as strings rather than written as
    ///      JSON numbers (they exceed 2^53). Built here so the parser under test sees real JSON.
    ///
    ///      Assembled through three helpers rather than one wide `string.concat`, for the same
    ///      reason `DeployTestnet._writeAddressBook()` is: a wide concat blows the legacy codegen's
    ///      stack ("Stack too deep" in the generated assembly) and `via_ir` is off and must stay
    ///      off (Global Constraint 1). Hit while writing this file, not copied on faith.
    function _bookJson() internal view returns (string memory) {
        return string.concat(_bookHeadJson(), _bookSharedJson(), _bookVaultsJson());
    }

    function _bookHeadJson() internal view returns (string memory) {
        string memory out = string.concat("{\n", '  "chainId": ', vm.toString(CHAIN_ID), ",\n");
        out = string.concat(out, '  "senders": {\n');
        out = string.concat(out, '    "deployer": "', vm.toString(deployer), '",\n');
        out = string.concat(out, '    "governance": "', vm.toString(gov), '",\n');
        return string.concat(out, '    "attester": "', vm.toString(attesterAddr), '"\n  },\n');
    }

    function _bookSharedJson() internal view returns (string memory) {
        string memory out = '  "shared": {\n';
        out = string.concat(out, '    "collateral": "', vm.toString(address(usdg)), '",\n');
        out = string.concat(out, '    "collateralDecimals": 6,\n');
        out = string.concat(out, '    "lighterSim": "', vm.toString(address(sim)), '",\n');
        out = string.concat(out, '    "solvencyRegistry": "', vm.toString(address(reg)), '",\n');
        out = string.concat(out, '    "capacityOracle": "', vm.toString(address(cap)), '",\n');
        return string.concat(out, '    "batchKeeper": "', vm.toString(batchKeeperAddr), '"\n  },\n');
    }

    function _bookVaultsJson() internal view returns (string memory) {
        string memory out = '  "vaults": [\n    {\n';
        out = string.concat(out, '      "symbol": "uTSLA",\n');
        out = string.concat(out, '      "marketIndex": ', vm.toString(uint256(MARKET)), ",\n");
        out = string.concat(out, '      "sizeDecimals": 4,\n');
        out = string.concat(out, '      "vault": "', vm.toString(address(vault)), '",\n');
        out = string.concat(out, '      "certificate": "', vm.toString(address(cert)), '",\n');
        out = string.concat(out, '      "certOracle": "', vm.toString(address(oracle)), '",\n');
        out = string.concat(out, '      "replayAggregator": "', vm.toString(address(feed)), '",\n');
        out = string.concat(out, '      "seedOpenInterest18": "', vm.toString(OPEN_INTEREST_18), '"\n');
        return string.concat(out, "    }\n  ]\n}\n");
    }

    // -------------------------------------------------------------- the address book is honoured

    /// @notice The keepers take NO addresses as arguments: everything comes from the book.
    /// @dev The sharpest consequence, and the reason it is a test rather than a comment: a keeper
    ///      given a hand-typed vault address would attest a PREVIOUS deployment's vault — valid
    ///      attestations against an asset key nothing is minting, while the live vault starves.
    function test_keepersReadTheAddressBookNotArguments() public {
        // Batch 1 is the deployment's seed. One keeper cycle must advance it to 2, using only what
        // the book says, with no address passed in.
        assertEq(reg.latest(address(vault)).batchId, 1, "fixture batchId");
        attesterKeeper.run();
        assertEq(reg.latest(address(vault)).batchId, 2, "attester did not continue from the chain's batchId");

        // And it resumes from the CHAIN, not from a counter in the process: a fresh keeper instance
        // with no memory of the last cycle still writes 3, never 2 again.
        AttesterWithBook fresh = new AttesterWithBook();
        fresh.setBook(_bookJson());
        fresh.setKey(ATTESTER_PK);
        fresh.run();
        assertEq(reg.latest(address(vault)).batchId, 3, "a restarted attester did not resume from the chain");
    }

    /// @notice A book from another chain is refused before anything is sent.
    function test_attesterRefusesABookFromAnotherChain() public {
        vm.chainId(1);
        vm.expectRevert(bytes("ADDRESS BOOK: chainId != the chain this RPC is on"));
        attesterKeeper.run();
    }

    // ---------------------------------------------------- the attester's figures are venue truth

    /// @notice **PLAN TEST 1.** The attested notional and margin equal the simulator's actual
    ///         per-account position and margin.
    ///
    /// @dev The truth side is re-derived here from `LighterSim`'s RAW per-account storage —
    ///      `addressToAccountIndex`, `positionBaseOf`, `marginBalanceOf`, `equity`, `markPrice` —
    ///      not by calling the same library the keeper calls. So a `VenueTruth` that computed the
    ///      right shape from the wrong book (an aggregate instead of the account's own) fails here.
    function test_attesterFiguresMatchSimulatorTruth() public {
        // A real mint, so there is a real hedge to attest rather than the deployment's zero.
        _mint(alice, 900e6);
        vm.prank(batchKeeperAddr);
        sim.settleBatch();

        uint48 acct = sim.addressToAccountIndex(address(vault));
        assertTrue(acct != 0, "vault not registered on the venue");

        int256 pos = sim.positionBaseOf(acct, MARKET);
        assertTrue(pos != 0, "no hedge opened - nothing to attest");

        uint256 abs = pos > 0 ? uint256(pos) : uint256(-pos);
        uint256 expectedNotional18 = abs * sim.markPrice(MARKET) / (10 ** sim.sizeDecimals());

        uint256 cash = sim.marginBalanceOf(acct);
        uint256 drawable = sim.equity(acct);
        uint256 expectedMargin18 = (drawable < cash ? drawable : cash) * 1e12; // 6 -> 18 decimals
        assertTrue(cash != 0, "the account posted no margin - the assertion would be vacuous");

        (uint256 notional18, uint256 margin18, uint256 markPx18) =
            attesterKeeper.figures(address(sim), address(vault), MARKET);

        assertEq(notional18, expectedNotional18, "attested notional != the account's own position at the venue mark");
        assertEq(margin18, expectedMargin18, "attested margin != the account's own margin");
        assertEq(markPx18, sim.markPrice(MARKET), "attested mark != the venue mark");

        // And what the keeper actually WRITES is those figures, not a recomputation.
        attesterKeeper.run();
        SolvencyRegistry.Attestation memory a = reg.latest(address(vault));
        assertEq(a.notional18, expectedNotional18, "registry notional18");
        assertEq(a.margin18, expectedMargin18, "registry margin18");
        assertEq(a.openInterest18, OPEN_INTEREST_18, "registry openInterest18 - carried from the book");
        assertEq(oracle.markPx18(), sim.markPrice(MARKET), "CertOracle.markPx18 not set from the venue mark");

        // The published delta is the point of all of it: a 1:1 hedge reads near 10_000 bps.
        CertVault.Solvency memory s = vault.solvency();
        assertEq(s.notional18, expectedNotional18, "solvency().notional18");
        assertApproxEqRel(s.deltaBps, 10_000, 0.01e18, "published delta is not ~1.0 for a 1:1 hedge");
    }

    /// @notice The figures are the VAULT's own, not the venue's aggregate — the distinction Task 7
    ///         created and the one an attester can silently get wrong on a shared simulator.
    /// @dev `script/DeployTestnet.s.sol` puts uTSLA and uSPY on ONE `LighterSim`, so this is the
    ///      deployed configuration and not a hypothetical. A second tenant is given a position in
    ///      the same market; the aggregate views move and the vault's attested figures must not.
    function test_attesterReadsThePerAccountBookNotTheAggregate() public {
        _mint(alice, 900e6);
        vm.prank(batchKeeperAddr);
        sim.settleBatch();

        (uint256 notionalBefore, uint256 marginBefore,) = attesterKeeper.figures(address(sim), address(vault), MARKET);
        int256 aggregateBefore = sim.positionBase(MARKET);
        uint256 aggregateMarginBefore = sim.marginBalance();

        // A second tenant on the same simulator and the same market, exactly as uSPY would be.
        address tenant = makeAddr("otherTenant");
        usdg.mint(tenant, 50_000e6);
        vm.prank(deployer);
        sim.setDepositorAllowed(tenant, true);
        vm.startPrank(tenant);
        usdg.approve(address(sim), type(uint256).max);
        sim.deposit(tenant, ASSET_IDX, 0, 40_000e6);
        vm.stopPrank();
        vm.prank(batchKeeperAddr);
        sim.settleBatch();
        // Read the index BEFORE the prank: `vm.prank` applies to the very next external call, and
        // a view call made inside the prank consumes it — the order would then be submitted by this
        // test contract and revert `LighterCore_AccountNotCaller`.
        uint48 tenantAcct = sim.addressToAccountIndex(tenant);
        assertTrue(tenantAcct != 0, "the second tenant never registered");
        vm.prank(tenant);
        sim.createOrder(tenantAcct, MARKET, 50_000, 36_662, 0, 1);
        vm.prank(batchKeeperAddr);
        sim.settleBatch();

        // The venue-level views moved. If the attester read those, it would now be attesting the
        // other tenant's exposure and margin as this vault's backing.
        assertTrue(sim.positionBase(MARKET) != aggregateBefore, "the aggregate position did not move");
        assertTrue(sim.marginBalance() != aggregateMarginBefore, "the aggregate margin did not move");

        (uint256 notionalAfter, uint256 marginAfter,) = attesterKeeper.figures(address(sim), address(vault), MARKET);
        assertEq(notionalAfter, notionalBefore, "another tenant's position changed this vault's attested notional");
        assertEq(marginAfter, marginBefore, "another tenant's margin changed this vault's attested margin");
    }

    /// @notice An unregistered vault is refused loudly rather than attested as honest-looking zeros.
    /// @dev Zero notional and zero margin ARE the truth for an unregistered account — and are also
    ///      exactly what a wrong vault address in the book produces. Refusing costs no liveness:
    ///      an unregistered vault cannot mint anyway (`createOrder` reverts
    ///      `AccountIsNotRegistered`).
    function test_attesterRefusesAVaultWithNoVenueAccount() public {
        address ghost = makeAddr("ghostVault");
        vm.expectRevert(abi.encodeWithSelector(VenueTruth.VenueTruth_VaultNotRegistered.selector, ghost));
        attesterKeeper.figures(address(sim), ghost, MARKET);
    }

    /// @notice The wrong attester key aborts with a named reason, not a bare selector at 3am.
    function test_attesterRefusesTheWrongKey() public {
        attesterKeeper.setKey(WRONG_PK);
        vm.expectRevert(
            bytes(
                "ATTESTER_PK does not derive .senders.attester from the address book - attest would revert SolvencyRegistry_OnlyAttester"
            )
        );
        attesterKeeper.run();
    }

    // ------------------------------------------------------------------- THE ACCEPTANCE TEST

    /// @notice **PLAN TEST 2, BOTH HALVES.** With the attester keeper running, minting survives
    ///         time passing `maxAttestationAgeSec`. Without it, capacity goes to zero.
    ///
    /// @dev The second half is what the runbook's FIRST troubleshooting row describes, and it is
    ///      the reason that row exists: `CapacityOracle.maxNotional18` opens with
    ///      `if (registry.ageSec(asset) > maxAttestationAgeSec) return 0`, and 300 s is IMMUTABLE.
    ///      An operator who reads `CertVault_AtCapacity` five minutes after a deployment as a
    ///      deploy failure will try to change a parameter that has no setter, conclude the
    ///      deployment is broken, and redeploy into the same state.
    function test_vaultKeepsMintingWithKeepersRunning() public {
        uint256 capAtT0 = cap.maxNotional18(address(vault), vault.bufferCapacity18());
        assertTrue(capAtT0 != 0, "fixture: no capacity at t0");

        // ---------------------------------------------------------------- half 1: keeper running
        //
        // Well past 300 s, in steps a 60 s keeper interval would cover, with the keeper cycling
        // each time. `stalenessSeconds` is 900 so the feed also has to be pushed — that is
        // `script/FeedKeeper.s.sol`'s job (Task 9), stood in for here by advancing the aggregator
        // the same way it does, because the point of this half is that ALL the keepers together
        // keep the gate open, not that the attester alone can.
        for (uint256 i = 0; i < 10; ++i) {
            vm.warp(block.timestamp + 60);
            vm.prank(deployer);
            feed.push(FEED_PX_8);
            attesterKeeper.run();
            vm.prank(batchKeeperAddr);
            sim.settleBatch();
        }

        assertGt(block.timestamp - 1_800_000_000, MAX_ATTESTATION_AGE_SEC, "did not advance past maxAttestationAgeSec");
        assertLe(reg.ageSec(address(vault)), MAX_ATTESTATION_AGE_SEC, "attestation stale with the keeper running");
        assertTrue(oracle.mintAllowed(), "MINT GATE CLOSED with the keepers running");
        assertEq(
            cap.maxNotional18(address(vault), vault.bufferCapacity18()),
            capAtT0,
            "capacity changed with the keepers running"
        );

        // Not merely "permitted": a mint actually lands.
        uint256 certOut = _mint(alice, 900e6);
        assertTrue(certOut != 0, "mint returned zero certificates with the keepers running");

        // -------------------------------------------------------------- half 2: keeper NOT running
        //
        // Same deployment, same immutable parameters, nothing reconfigured. Only the keeper stops.
        uint256 ageBefore = reg.ageSec(address(vault));
        vm.warp(block.timestamp + MAX_ATTESTATION_AGE_SEC + 1);
        assertGt(reg.ageSec(address(vault)), MAX_ATTESTATION_AGE_SEC, "attestation did not go stale");
        assertGt(reg.ageSec(address(vault)), ageBefore, "age did not advance");

        assertEq(
            cap.maxNotional18(address(vault), vault.bufferCapacity18()),
            0,
            "CAPACITY DID NOT STARVE - the runbook's first troubleshooting row would be wrong"
        );

        // And the mint is refused with the error an operator will actually see. `CertVault_AtCapacity`
        // — NOT a stale-price error, and NOT a paused-mint error. Telling those apart is what the
        // runbook's diagnostic section is for.
        usdg.mint(alice, 900e6);
        vm.startPrank(alice);
        usdg.approve(address(vault), 900e6);
        vm.expectRevert(CertVault.CertVault_AtCapacity.selector);
        vault.mintInstant(900e6);
        vm.stopPrank();

        // LAW 2 THROUGHOUT. A starved deployment stops taking money in; it never traps money
        // already in. `forceExit` reads no health state and must work at any price and any age.
        vm.prank(alice);
        uint256 receiptId = vault.forceExit(certOut);
        assertTrue(receiptId != 0, "forceExit failed on a starved deployment - Law 2 breach");
        assertEq(cert.balanceOf(alice), 0, "certificates not burned");

        // ------------------------------------------------------- and the keeper coming back fixes it
        //
        // The row says "the keepers are not running", so restarting them — with nothing else
        // changed — must restore capacity. Otherwise the advice sends an operator down a blind
        // alley.
        vm.prank(deployer);
        feed.push(FEED_PX_8);
        attesterKeeper.run();
        assertEq(
            cap.maxNotional18(address(vault), vault.bufferCapacity18()),
            capAtT0,
            "restarting the attester did not restore capacity"
        );
        assertTrue(oracle.mintAllowed(), "mint gate still closed after the keeper restarted");
    }

    /// @notice The feed keeper's failure symptom is DIFFERENT from the attester's, and both look
    ///         like "minting stopped".
    /// @dev This is the diagnostic the runbook's table has to support. `stalenessSeconds` is 900
    ///      and `maxAttestationAgeSec` is 300, so with only the ATTESTER running, minting survives
    ///      300 s and dies at 900 s — and it dies through `mintAllowed()` (a stale feed) with
    ///      capacity still non-zero, which is the OPPOSITE reading from half 2 above.
    function test_stoppedFeedKeeperAndStoppedAttesterFailDifferently() public {
        // Attester running, feed keeper stopped. Past `stalenessSeconds`.
        for (uint256 i = 0; i < 16; ++i) {
            vm.warp(block.timestamp + 60);
            attesterKeeper.run();
        }
        assertGt(block.timestamp - 1_800_000_000, STALENESS_SECONDS, "did not pass stalenessSeconds");

        // THE DISTINGUISHING PAIR OF READS, and it is exactly the pair the runbook tells the
        // operator to take: capacity is FINE, the mint gate is SHUT.
        assertTrue(
            cap.maxNotional18(address(vault), vault.bufferCapacity18()) != 0,
            "capacity starved - that would make the two symptoms indistinguishable"
        );
        assertFalse(oracle.mintAllowed(), "mint gate open on a feed past stalenessSeconds");

        // Pushing the feed — one `script/FeedKeeper.s.sol` invocation — reopens it, with nothing
        // else touched.
        vm.prank(deployer);
        feed.push(FEED_PX_8);
        assertTrue(oracle.mintAllowed(), "a feed push did not reopen the mint gate");
    }

    // --------------------------------------------------------------------- the batch advancer

    /// @notice The batch advancer moves the queue: an order submitted and not settled becomes a
    ///         position.
    function test_batchAdvancerSettlesTheQueue() public {
        _mint(alice, 900e6);

        uint48 acct = sim.addressToAccountIndex(address(vault));
        assertEq(sim.positionBaseOf(acct, MARKET), 0, "position exists before any settlement");
        assertTrue(sim.queueLength() != 0, "the mint queued no order");

        batchKeeper.run();

        assertTrue(sim.positionBaseOf(acct, MARKET) != 0, "BatchAdvancer did not open the hedge");
        assertEq(sim.queueLength(), 0, "BatchAdvancer left the queue unsettled");
    }

    /// @notice **THE KEEPER-MISMATCH ROW.** A batch advancer signing with a key the simulator does
    ///         not have on file is refused with a named reason.
    /// @dev Left to reach the chain it reverts `LighterSim_OnlyOwnerOrKeeper()` on every cycle,
    ///      which is INDISTINGUISHABLE from the keeper process being dead — nothing on-chain says
    ///      the two disagree. So the script refuses to broadcast and says which side is wrong.
    function test_batchAdvancerRefusesAKeyTheSimDoesNotKnow() public {
        batchKeeper.setKey(WRONG_PK);
        vm.expectRevert(
            bytes(
                "BATCH_KEEPER_PK does not derive .shared.batchKeeper from the address book - settleBatch would revert LighterSim_OnlyOwnerOrKeeper"
            )
        );
        batchKeeper.run();

        // And the raw revert the operator would otherwise be chasing, so the runbook row's claim
        // about what it looks like is pinned rather than asserted.
        vm.prank(vm.addr(WRONG_PK));
        vm.expectRevert(LighterSim.LighterSim_OnlyOwnerOrKeeper.selector);
        sim.settleBatch();
    }

    /// @notice A book whose `batchKeeper` disagrees with `LighterSim.keeper()` on chain is caught
    ///         too, and reported as the OTHER failure — a stale book, not a wrong process key.
    function test_batchAdvancerRefusesAStaleBook() public {
        address rotated = makeAddr("rotatedKeeper");
        vm.prank(deployer);
        sim.setKeeper(rotated);

        vm.expectRevert(
            bytes(
                "LighterSim.keeper() on chain is neither the signer nor the owner - the deployment and this process disagree; only the sim owner can setKeeper"
            )
        );
        batchKeeper.run();
    }

    /// @notice The allowlist row: a vault the simulator has not approved cannot bootstrap, which is
    ///         the deployment-time cousin of the keeper-mismatch failure.
    /// @dev `LighterSim_DepositorNotAllowed` is owner-gated state with no counterpart on the real
    ///      venue, so no earlier document describes it and the error explains nothing on its own.
    function test_unallowlistedVaultCannotBootstrap() public {
        CertVault fresh = new CertVault(
            CertVault.Deps({
                lighter: address(sim),
                oracle: address(oracle),
                registry: address(reg),
                capacity: address(cap),
                governance: gov
            }),
            CertVault.VaultConfig({
                collateral: address(usdg),
                collateralAssetIndex: ASSET_IDX,
                routeType: 0,
                marketIndex: MARKET,
                sizeDecimals: SIZE_DECIMALS,
                mintFeeBps: 10,
                redeemFeeBps: 10,
                instantCap18: INSTANT_CAP_18,
                settleBandBps: 500,
                targetMarginBps: TARGET_MARGIN_BPS
            }),
            VENUE_WITHDRAW_CAP,
            SETTLE_WINDOW,
            "UseCert TSLA 2",
            "uTSLA2"
        );

        usdg.mint(address(this), SEED_COLLATERAL);
        usdg.approve(address(fresh), SEED_COLLATERAL);
        fresh.seedBuffer(SEED_COLLATERAL);

        vm.expectRevert(abi.encodeWithSelector(LighterSim.LighterSim_DepositorNotAllowed.selector, address(fresh)));
        fresh.bootstrap();
    }

    // ------------------------------------------------------------------------------- helpers

    function _mint(address who, uint256 amountIn) internal returns (uint256 certOut) {
        usdg.mint(who, amountIn);
        vm.startPrank(who);
        usdg.approve(address(vault), amountIn);
        certOut = vault.mintInstant(amountIn);
        vm.stopPrank();
    }
}
