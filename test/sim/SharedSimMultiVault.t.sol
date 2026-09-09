// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CertVault} from "../../src/CertVault.sol";
import {Certificate} from "../../src/Certificate.sol";
import {CertOracle} from "../../src/CertOracle.sol";
import {SolvencyRegistry} from "../../src/SolvencyRegistry.sol";
import {CapacityOracle} from "../../src/CapacityOracle.sol";
import {LighterCore} from "../../src/sim/LighterCore.sol";
import {LighterSim} from "../../src/sim/LighterSim.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice TASK 7 ACCEPTANCE: two real `CertVault`s sharing ONE `LighterSim`.
///
///         `TESTNET-PLAN.md` §6 requires the simulator to be shared across mirrors while each
///         vault gets its own `CertOracle` and `CertVault`. Before this task that arrangement was
///         unsafe in three independent ways, and every one of them would have presented as a VAULT
///         bug rather than as a venue bug:
///
///           1. `marginBalance` was one shared pool, so vault B's collateral silently margined
///              vault A's position — and `withdraw`'s ceiling was that pool, so either vault could
///              take the other's money.
///           2. `positionBase[market]` was global, so a zero-amount close-all order from B zeroed
///              A's hedge at settlement.
///           3. `settleBatch` reverted as a whole, so one vault's under-margined order froze the
///              other vault's settlement permanently.
///
///         This file is the end-to-end proof that all three are closed, driven through the real
///         `mintInstant` path rather than through direct venue calls.
///
/// @dev The two vaults are deliberately configured with DIFFERENT `targetMarginBps` against a
///      simulator whose `requiredMarginBps` sits between what they each post: vault A posts 90% of
///      net collateral and clears the venue's requirement, vault B posts 50% and does not. That is
///      the "one deliberately under-margined" half of the requirement, and it is arranged through
///      configuration rather than through a hand-built order so that what fails is a real vault
///      doing a real mint.
///
///      `requiredMarginBps = 6_000` is ABOVE `VENUE_IMF_BPS` (5_000), which the simulator permits
///      and Global Constraint 5 explicitly allows: raising the requirement makes the simulator
///      harder than the venue, never easier.
contract SharedSimMultiVaultTest is Test {
    uint16 constant ASSET_IDX = 3;
    uint8 constant SIZE_DECIMALS = 4;
    uint16 constant MARKET = 16; // TSLA on the real venue
    uint256 constant PX = 355.86e18;
    uint256 constant SETTLE_WINDOW = 1 days;
    uint256 constant VENUE_WITHDRAW_CAP = type(uint64).max;
    uint256 constant MAX_ABSOLUTE_CAP = 1_000_000_000e18;
    /// @dev Between vault B's 5_000 and vault A's 9_000, and above `LighterSim.VENUE_IMF_BPS`.
    uint256 constant SIM_IMF = 6_000;

    /// @dev The mint both vaults perform. 3_558.6 USDG at 355.86 is 9.99 certificates, which is
    ///      99_900 base ticks at size_decimals 4 — the same figure the single-vault suite uses.
    uint256 constant MINT_IN = 3_558.6e6;
    int256 constant HEDGE_TICKS = 99_900;

    MockERC20 usdg;
    MockAggregatorV3 feed;
    LighterSim sim;
    SolvencyRegistry reg;
    CapacityOracle cap;

    CertOracle oracleA;
    CertOracle oracleB;
    CertVault vaultA;
    CertVault vaultB;

    address attester = makeAddr("attester");
    address gov = makeAddr("gov");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        usdg = new MockERC20("USDG", "USDG", 6);
        feed = new MockAggregatorV3(8, 355_86000000);
        // This test contract is the simulator's operator, which is also who settles: `settleBatch`
        // is owner-or-keeper only from Task 7 on.
        sim = new LighterSim(IERC20(address(usdg)), ASSET_IDX, SIZE_DECIMALS, SIM_IMF, address(this));
        reg = new SolvencyRegistry(attester);
        cap = new CapacityOracle(address(reg), gov, 1000, 100, 3000, 300, MAX_ABSOLUTE_CAP);

        oracleA = new CertOracle(address(feed), attester, 2, 3600, 500, 100, 3600, false);
        oracleB = new CertOracle(address(feed), attester, 2, 3600, 500, 100, 3600, false);
        vaultA = _deployVault(oracleA, 9_000, "UseCert TSLA A", "uTSLAa");
        vaultB = _deployVault(oracleB, 5_000, "UseCert TSLA B", "uTSLAb");

        vm.prank(gov);
        cap.setAbsoluteCap(address(vaultA), 5_000_000e18);
        vm.prank(gov);
        cap.setAbsoluteCap(address(vaultB), 5_000_000e18);
        vm.startPrank(attester);
        oracleA.setMarkPrice(PX);
        oracleB.setMarkPrice(PX);
        reg.attest(address(vaultA), 1, 0, 0, 1_190_000e18);
        reg.attest(address(vaultB), 1, 0, 0, 1_190_000e18);
        vm.stopPrank();

        sim.setMarkPrice(MARKET, PX);
        // Fix round 1's registration allowlist, kept by Task 7 as defence in depth: the operator
        // approves the two vaults and nobody else. On the single-vault deployment Task 10 performs
        // this set has one member; here it has exactly the two tenants the sim is shared between.
        sim.setDepositorAllowed(address(vaultA), true);
        sim.setDepositorAllowed(address(vaultB), true);

        usdg.mint(address(this), 5_000_000e6);
        usdg.mint(alice, 1_000_000e6);
        usdg.mint(bob, 1_000_000e6);
        usdg.approve(address(vaultA), type(uint256).max);
        usdg.approve(address(vaultB), type(uint256).max);
        vm.prank(alice);
        usdg.approve(address(vaultA), type(uint256).max);
        vm.prank(bob);
        usdg.approve(address(vaultB), type(uint256).max);

        vaultA.seedBuffer(100_000e6);
        vaultB.seedBuffer(100_000e6);
        vaultA.bootstrap();
        vaultB.bootstrap();
        sim.settleBatch();
    }

    function _deployVault(CertOracle oracle, uint256 targetMarginBps, string memory name, string memory symbol)
        internal
        returns (CertVault v)
    {
        v = new CertVault(
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
                instantCap18: 10_000e18,
                settleBandBps: 500,
                targetMarginBps: targetMarginBps
            }),
            VENUE_WITHDRAW_CAP,
            SETTLE_WINDOW,
            name,
            symbol
        );
    }

    function _idxA() internal view returns (uint48) {
        return sim.addressToAccountIndex(address(vaultA));
    }

    function _idxB() internal view returns (uint48) {
        return sim.addressToAccountIndex(address(vaultB));
    }

    // ---------------------------------------------------------------------------------------

    /// @notice The two vaults hold DISTINCT accounts on the shared simulator, which is the
    ///         precondition everything below rests on.
    function test_eachVaultGetsItsOwnAccount() public view {
        assertGt(_idxA(), 0, "vault A never registered");
        assertGt(_idxB(), 0, "vault B never registered");
        assertNotEq(_idxA(), _idxB(), "the two vaults share one account index");
        assertEq(sim.accountCount(), 2, "the simulator sees the wrong number of tenants");
    }

    /// @notice **THE TASK 7 ACCEPTANCE TEST.** Two vaults, both mint, one deliberately
    ///         under-margined: the healthy vault still settles and its position is correct.
    ///
    /// @dev Before this task, this sequence failed in whichever of three ways the reader looked
    ///      for. Reproduced against the pre-fix artefact:
    ///        * `settleBatch()` reverted `InsufficientMargin` for BOTH vaults, so vault A's hedge
    ///          never filled and vault A was permanently unhedged through no fault of its own —
    ///          and no non-owner call could clear it.
    ///        * With B's order removed, B's collateral in the shared pool margined A's position, so
    ///          the venue's "A is adequately margined" answer was not about A at all.
    function test_twoVaultsShareOneSimWithoutInterference() public {
        vm.prank(alice);
        vaultA.mintInstant(MINT_IN);
        vm.prank(bob);
        vaultB.mintInstant(MINT_IN);

        // Both hedges are queued, neither has filled: orders never fill in the calling transaction.
        assertEq(sim.queueLength(), 2, "the two hedges did not queue");
        assertEq(sim.positionBaseOf(_idxA(), MARKET), 0, "A filled in-tx");
        assertEq(sim.positionBaseOf(_idxB(), MARKET), 0, "B filled in-tx");

        // Settlement does NOT revert. B's under-margined order is refused individually, named in
        // the log, and A's fills.
        vm.expectEmit(true, true, true, true, address(sim));
        emit LighterCore.OrderRejected(_idxB(), MARKET, 1, LighterCore.InsufficientMargin.selector);
        sim.settleBatch();

        assertEq(sim.positionBaseOf(_idxA(), MARKET), HEDGE_TICKS, "the healthy vault's hedge did not fill");
        assertEq(sim.entryPriceOf(_idxA(), MARKET), PX, "the healthy vault's entry was not recorded at the mark");
        assertEq(sim.positionBaseOf(_idxB(), MARKET), 0, "the under-margined hedge filled anyway");
        assertEq(sim.queueLength(), 0, "the queue did not drain");

        // The healthy vault's margin is its own, and B's is B's.
        assertGt(sim.marginBalanceOf(_idxA()), 0, "A posted no margin");
        assertGt(sim.marginBalanceOf(_idxB()), 0, "B posted no margin");
        assertEq(
            sim.marginBalance(),
            sim.marginBalanceOf(_idxA()) + sim.marginBalanceOf(_idxB()),
            "the aggregate view is not a sum of the two tenants"
        );

        // A can mint again: one tenant's refused order has not degraded the other's service.
        vm.prank(alice);
        vaultA.mintInstant(MINT_IN);
        sim.settleBatch();
        assertEq(sim.positionBaseOf(_idxA(), MARKET), HEDGE_TICKS * 2, "A's second hedge did not fill");
        assertEq(sim.positionBaseOf(_idxB(), MARKET), 0, "B's hedge filled on A's margin");
    }

    /// @notice Neither vault's `withdraw` can reach the other's collateral, driven through the real
    ///         `recallMargin` path rather than through a direct venue call.
    ///
    /// @dev This is the drain, asked as a question about two real tenants. `withdraw`'s ceiling used
    ///      to be the global `equity()`, so whichever vault recalled first could have taken the
    ///      other's posted margin and the other's `_sweepPending` would have found nothing.
    function test_neitherVaultCanRecallTheOthersMargin() public {
        vm.prank(alice);
        vaultA.mintInstant(MINT_IN);
        vm.prank(bob);
        vaultB.mintInstant(MINT_IN);
        sim.settleBatch();

        uint256 aMargin = sim.marginBalanceOf(_idxA());
        uint256 bMargin = sim.marginBalanceOf(_idxB());
        assertGt(aMargin, 0);
        assertGt(bMargin, 0);
        assertEq(sim.equity(_idxA()), aMargin, "A's equity is not A's own margin");
        assertEq(sim.equity(_idxB()), bMargin, "B's equity is not B's own margin");

        // The whole of A's certificate supply is redeemed and its margin recalled. The ceiling is
        // A's own equity, so B's margin cannot be part of the payout.
        uint256 supplyA = Certificate(vaultA.certificate()).totalSupply();
        vm.prank(alice);
        vaultA.redeemInstant(supplyA);
        vaultA.recallMargin();
        sim.settleBatch();
        vaultA.recallMargin();

        assertEq(sim.marginBalanceOf(_idxB()), bMargin, "vault B's margin was recalled by vault A");
        assertEq(sim.positionBaseOf(_idxB(), MARKET), 0, "vault B's book moved");
        assertLe(
            sim.getPendingBalance(address(vaultA), ASSET_IDX) + sim.marginBalanceOf(_idxA()),
            aMargin,
            "vault A was credited more than it ever posted"
        );
    }

    /// @notice Vault B cannot destroy vault A's hedge, through the one primitive that reached it.
    ///
    /// @dev `CertVault.closeAll()` submits `baseAmount == 0` — Lighter's "the entire position"
    ///      primitive — on the side its own ledger says it holds. Before Task 7, `settleBatch`
    ///      resolved that against the GLOBAL position, so B's governance wind-down would have
    ///      flattened A's hedge. B here is flat (its own hedge was refused), which is exactly the
    ///      state in which the pre-fix reading was most destructive: a full-size order against a
    ///      position B does not own.
    function test_oneVaultsCloseAllCannotFlattenTheOthersHedge() public {
        vm.prank(alice);
        vaultA.mintInstant(MINT_IN);
        vm.prank(bob);
        vaultB.mintInstant(MINT_IN);
        sim.settleBatch();
        assertEq(sim.positionBaseOf(_idxA(), MARKET), HEDGE_TICKS, "A's hedge did not open");

        // Give B a position of its own so its ledger has a side to pick, then flatten B.
        vm.prank(bob);
        vaultB.mintInstant(MINT_IN);
        // B is still under-margined, so its order is refused; drive its close-all directly through
        // the venue instead, which is the sharper version of the same attack.
        sim.settleBatch();

        vm.prank(gov);
        vaultB.closeAll();
        sim.settleBatch();

        assertEq(sim.positionBaseOf(_idxA(), MARKET), HEDGE_TICKS, "B's wind-down flattened A's hedge");
        assertEq(sim.positionBase(MARKET), HEDGE_TICKS, "the venue's net position moved");
    }

    /// @notice One vault cancelling its own orders cannot cancel the other's queued hedge.
    /// @dev Task 5 scoped `cancelAllOrders`; this is the two-real-tenant version of that assertion,
    ///      and the first one where the two accounts are actual vaults rather than test addresses.
    function test_oneVaultsCancelCannotDropTheOthersHedge() public {
        vm.prank(alice);
        vaultA.mintInstant(MINT_IN);
        vm.prank(bob);
        vaultB.mintInstant(MINT_IN);
        assertEq(sim.queueLength(), 2);

        // B, as itself, cancels its own queue. The index is read BEFORE the prank: `_idxB()` is
        // itself an external call to the simulator, and `vm.prank` applies to the next call only.
        uint48 bIdx = _idxB();
        vm.prank(address(vaultB));
        sim.cancelAllOrders(bIdx);
        assertEq(sim.queueLength(), 1, "B's cancel took more than B's orders");

        sim.settleBatch();
        assertEq(sim.positionBaseOf(_idxA(), MARKET), HEDGE_TICKS, "A's hedge was cancelled by B");
    }
}
