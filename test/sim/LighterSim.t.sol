// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LighterCore} from "../../src/sim/LighterCore.sol";
import {LighterSim} from "../../src/sim/LighterSim.sol";
import {MockLighter} from "../mocks/MockLighter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice Task 4 acceptance tests (`MockLighter` and `LighterSim` are two front ends onto one
///         behaviour implementation, and the deployable one fits EIP-170) plus Task 5's three
///         closures: caller-bound account operations, a gated and floored operator surface, and a
///         `settleBatch` that fails closed on an unset mark.
///
/// @dev Task 5 deleted this file's `LighterSimHarness`. It existed only because `LighterSim` had no
///      `setMarkPrice` and a zero mark makes the initial-margin check vacuous, so the harness
///      supplied an ungated one. `LighterSim` now has a real, owner-gated `setMarkPrice`, so the
///      harness's whole reason to exist is gone and the mark-to-market tests below run against the
///      deployable contract itself rather than against a subclass of it.
contract LighterSimTest is Test {
    uint16 constant ASSET_IDX = 3;
    uint8 constant SIZE_DECIMALS = 4;
    uint16 constant MARKET = 16; // TSLA on the real venue
    uint16 constant MARKET_B = 26; // SPY on the real venue
    uint256 constant IMF = 5_000; // == LighterSim.VENUE_IMF_BPS

    MockERC20 usdgMock;
    MockERC20 usdgSim;
    MockLighter mockL;
    LighterSim sim;

    address stranger = address(0xBAD);
    address depositorA = address(0xA11CE);
    address depositorB = address(0xB0B);

    function setUp() public {
        usdgMock = new MockERC20("USDG", "USDG", 6);
        usdgSim = new MockERC20("USDG", "USDG", 6);
        mockL = new MockLighter(IERC20(address(usdgMock)), ASSET_IDX, SIZE_DECIMALS);
        sim = new LighterSim(IERC20(address(usdgSim)), ASSET_IDX, SIZE_DECIMALS, IMF, address(this));

        usdgMock.mint(address(this), 1_000_000e6);
        usdgSim.mint(address(this), 1_000_000e6);
        usdgMock.approve(address(mockL), type(uint256).max);
        usdgSim.approve(address(sim), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------
    // The extraction did not fork behaviour.
    // ---------------------------------------------------------------------------------------

    /// @notice The same deposit -> createOrder -> settleBatch -> withdraw sequence against both
    ///         front ends leaves identical state. This is what proves `MockLighter` and
    ///         `LighterSim` share one implementation rather than two that drift.
    /// @dev Task 5: both front ends now get a mark price before settling. This test used to settle
    ///      the sim's batch with no mark at all, which `LighterSim.settleBatch`'s new fail-closed
    ///      guard refuses — so this test was itself relying on the vacuous margin gate. Setting a
    ///      mark is strictly stronger: every assertion below is unchanged and the sequence now runs
    ///      through a live initial-margin check and a live entry-price book instead of past two
    ///      short-circuited ones.
    function test_simAndMockShareBehaviour() public {
        mockL.setMarkPrice(MARKET, 100e18);
        sim.setMarkPrice(MARKET, 100e18);

        // deposit
        mockL.deposit(address(this), ASSET_IDX, 0, 1_000e6);
        sim.deposit(address(this), ASSET_IDX, 0, 1_000e6);

        uint48 mockIdx = mockL.addressToAccountIndex(address(this));
        uint48 simIdx = sim.addressToAccountIndex(address(this));
        assertEq(mockIdx, simIdx, "account index");
        assertGt(simIdx, 0, "registering deposit");
        assertEq(mockL.marginBalance(), sim.marginBalance(), "margin after deposit");

        // createOrder — must NOT fill in the calling transaction on either front end
        mockL.createOrder(mockIdx, MARKET, 100, 35586, 0, 1);
        sim.createOrder(simIdx, MARKET, 100, 35586, 0, 1);
        assertEq(mockL.positionBase(MARKET), 0, "mock filled in-tx");
        assertEq(sim.positionBase(MARKET), 0, "sim filled in-tx");

        // settleBatch
        mockL.settleBatch();
        sim.settleBatch();
        _assertSameState("after settle");
        assertEq(sim.positionBase(MARKET), 100, "sim position");

        // withdraw — asynchronous credit to pending, no synchronous transfer
        mockL.withdraw(mockIdx, ASSET_IDX, 0, 400e6);
        sim.withdraw(simIdx, ASSET_IDX, 0, 400e6);
        _assertSameState("after withdraw");
        assertEq(sim.getPendingBalance(address(this), ASSET_IDX), 400e6, "sim pending");

        // drain the pending balance
        uint256 mockBefore = usdgMock.balanceOf(address(this));
        uint256 simBefore = usdgSim.balanceOf(address(this));
        mockL.withdrawPendingBalance(address(this), ASSET_IDX, 400e6);
        sim.withdrawPendingBalance(address(this), ASSET_IDX, 400e6);
        assertEq(usdgMock.balanceOf(address(this)) - mockBefore, 400e6, "mock drained");
        assertEq(usdgSim.balanceOf(address(this)) - simBefore, 400e6, "sim drained");
        _assertSameState("after drain");
    }

    /// @notice The same sequence with a non-zero mark price, so the extracted mark-to-market and
    ///         initial-margin mechanics are actually exercised rather than short-circuited by a
    ///         zero mark. Run against `LighterSim` itself now that it has a gated `setMarkPrice`.
    function test_simAndMockShareBehaviourUnderMarkToMarket() public {
        mockL.setMarkPrice(MARKET, 100e18);
        sim.setMarkPrice(MARKET, 100e18);

        mockL.deposit(address(this), ASSET_IDX, 0, 1_000e6);
        sim.deposit(address(this), ASSET_IDX, 0, 1_000e6);

        uint48 mockIdx = mockL.addressToAccountIndex(address(this));
        uint48 simIdx = sim.addressToAccountIndex(address(this));

        mockL.createOrder(mockIdx, MARKET, 100, 35586, 0, 1);
        sim.createOrder(simIdx, MARKET, 100, 35586, 0, 1);
        mockL.settleBatch();
        sim.settleBatch();

        // Entry recorded at the fill's mark on both.
        assertEq(mockL.entryPrice(MARKET), 100e18, "mock entry");
        assertEq(sim.entryPrice(MARKET), 100e18, "sim entry");

        // Mark up: the position now carries an unrealised gain on both.
        mockL.setMarkPrice(MARKET, 120e18);
        sim.setMarkPrice(MARKET, 120e18);
        assertEq(mockL.unrealisedPnl(), sim.unrealisedPnl(), "pnl");
        assertEq(mockL.equity(), sim.equity(), "equity");
        assertGt(sim.equity(), sim.marginBalance(), "gain not modelled");

        // Draw the whole of equity, which forces the gain to be realised and entryPrice rewritten.
        uint64 all = uint64(sim.equity());
        mockL.withdraw(mockIdx, ASSET_IDX, 0, all);
        sim.withdraw(simIdx, ASSET_IDX, 0, all);

        assertEq(mockL.marginBalance(), sim.marginBalance(), "margin after realising gain");
        assertEq(mockL.entryPrice(MARKET), sim.entryPrice(MARKET), "entry after realising gain");
        assertEq(mockL.entryPrice(MARKET), 120e18, "gain fully realised");
        assertEq(mockL.unrealisedPnl(), sim.unrealisedPnl(), "residual pnl");
        assertEq(
            mockL.getPendingBalance(address(this), ASSET_IDX),
            sim.getPendingBalance(address(this), ASSET_IDX),
            "pending credit"
        );

        // The ONE deliberate front-end difference, and it fails in the conservative direction:
        // MockLighter mints the counterparty collateral a gain-drawing withdrawal needs, because a
        // one-account mock has no losing counterparty. LighterSim does not, so the same receipt is
        // unpayable on the simulator. Global Constraint 5 — never easier than mainnet.
        mockL.withdrawPendingBalance(address(this), ASSET_IDX, uint128(all));
        vm.expectRevert();
        sim.withdrawPendingBalance(address(this), ASSET_IDX, uint128(all));
    }

    /// @notice The initial-margin gate is the same gate on both front ends, and it is not vacuous.
    function test_simRejectsUnderMarginedFillLikeMock() public {
        mockL.setMarkPrice(MARKET, 100e18);
        sim.setMarkPrice(MARKET, 100e18);
        mockL.deposit(address(this), ASSET_IDX, 0, 1e6);
        sim.deposit(address(this), ASSET_IDX, 0, 1e6);

        // 1_000_000 base ticks at size_decimals 4 is 100 units => $10,000 notional against $1.
        mockL.createOrder(mockL.addressToAccountIndex(address(this)), MARKET, 1_000_000, 35586, 0, 1);
        sim.createOrder(sim.addressToAccountIndex(address(this)), MARKET, 1_000_000, 35586, 0, 1);

        vm.expectRevert(LighterCore.InsufficientMargin.selector);
        mockL.settleBatch();
        vm.expectRevert(LighterCore.InsufficientMargin.selector);
        sim.settleBatch();
    }

    // ---------------------------------------------------------------------------------------
    // Task 5, item 7 (C1): every account-scoped entry point is bound to its caller.
    //
    // BEFORE THIS FIX, reproduced against the deployable artefact exactly as Task 4 left it:
    // two depositors funded the sim with 600_000e6 and 400_000e6 USDG. `stranger`, whose
    // `addressToAccountIndex` was 0 and who had never deposited, called
    // `withdraw(3, ASSET_IDX, 0, type(uint64).max)`. The only gate was `accountIndex != 0`, so
    // the literal 3 passed; `equity()` returned the entire global `marginBalance`
    // (1_000_000e6); and the credit landed in `_pending[msg.sender]`. One
    // `withdrawPendingBalance` later the sim held 0 USDG and the stranger held 1_000_000e6.
    // Two transactions, no registration, no deposit. The tests below pin the reverts that
    // close it.
    // ---------------------------------------------------------------------------------------

    /// @notice **The C1 proof.** A stranger who never deposited cannot withdraw against anyone
    ///         else's account, and the simulator's collateral is untouched.
    function test_withdrawRejectsAnUnboundCaller() public {
        _fundTwoDepositors();

        uint256 heldBefore = usdgSim.balanceOf(address(sim));
        uint256 marginBefore = sim.marginBalance();
        assertEq(sim.addressToAccountIndex(stranger), 0, "stranger is registered");

        // The exact pre-fix drain call.
        vm.prank(stranger);
        vm.expectRevert(LighterCore.LighterCore_AccountNotCaller.selector);
        sim.withdraw(3, ASSET_IDX, 0, type(uint64).max);

        // And the same call naming a real depositor's index, which is the sharper version: the
        // index exists, it just is not the caller's.
        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        vm.prank(stranger);
        vm.expectRevert(LighterCore.LighterCore_AccountNotCaller.selector);
        sim.withdraw(aIdx, ASSET_IDX, 0, 1e6);

        assertEq(usdgSim.balanceOf(address(sim)), heldBefore, "collateral moved");
        assertEq(sim.marginBalance(), marginBefore, "marginBalance moved");
        assertEq(sim.getPendingBalance(stranger, ASSET_IDX), 0, "stranger was credited");
        assertEq(usdgSim.balanceOf(stranger), 0, "stranger holds collateral");
    }

    /// @notice The owner of an account is still the one address that can withdraw against it, so
    ///         the fix bound the caller rather than breaking the entry point.
    function test_withdrawStillWorksForTheAccountsOwnAddress() public {
        _fundTwoDepositors();

        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        vm.prank(depositorA);
        sim.withdraw(aIdx, ASSET_IDX, 0, 100e6);
        assertEq(sim.getPendingBalance(depositorA, ASSET_IDX), 100e6, "own withdrawal refused");
    }

    function test_createOrderRejectsAnUnboundCaller() public {
        _fundTwoDepositors();
        uint48 aIdx = sim.addressToAccountIndex(depositorA);

        vm.prank(stranger);
        vm.expectRevert(LighterCore.LighterCore_AccountNotCaller.selector);
        sim.createOrder(aIdx, MARKET, 100, 35586, 0, 1);

        // An arbitrary non-zero index the stranger simply invented, which is what the old
        // `accountIndex != 0` gate let through.
        vm.prank(stranger);
        vm.expectRevert(LighterCore.LighterCore_AccountNotCaller.selector);
        sim.createOrder(7, MARKET, 100, 35586, 0, 1);
    }

    function test_cancelAllOrdersRejectsAnUnboundCaller() public {
        _fundTwoDepositors();
        uint48 aIdx = sim.addressToAccountIndex(depositorA);

        vm.prank(stranger);
        vm.expectRevert(LighterCore.LighterCore_AccountNotCaller.selector);
        sim.cancelAllOrders(aIdx);

        // The pre-fix call ignored its argument entirely, so any value wiped the whole queue.
        vm.prank(stranger);
        vm.expectRevert(LighterCore.LighterCore_AccountNotCaller.selector);
        sim.cancelAllOrders(999);

        // Index 0 is still "unregistered", the same answer createOrder and withdraw give.
        vm.prank(stranger);
        vm.expectRevert(LighterCore.AccountIsNotRegistered.selector);
        sim.cancelAllOrders(0);
    }

    /// @notice `cancelAllOrders(accountIndex)` cancels that account's orders and only that
    ///         account's. It used to ignore its argument and `delete _queue`, so one account's
    ///         cancellation silently cancelled the vault's hedge.
    function test_cancelAllOrdersOnlyTouchesTheCallersQueue() public {
        _fundTwoDepositors();
        sim.setMarkPrice(MARKET, 100e18);
        sim.setMarkPrice(MARKET_B, 50e18);

        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        uint48 bIdx = sim.addressToAccountIndex(depositorB);

        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 500, 10_000, 0, 1);
        vm.prank(depositorB);
        sim.createOrder(bIdx, MARKET_B, 700, 5_000, 0, 1);

        // B cancels its own. A's order must survive.
        vm.prank(depositorB);
        sim.cancelAllOrders(bIdx);

        sim.settleBatch();
        assertEq(sim.positionBase(MARKET), 500, "A's order was cancelled by B");
        assertEq(sim.positionBase(MARKET_B), 0, "B's own order was not cancelled");

        // And A cancelling its own really does cancel it.
        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 300, 10_000, 0, 1);
        vm.prank(depositorA);
        sim.cancelAllOrders(aIdx);
        sim.settleBatch();
        assertEq(sim.positionBase(MARKET), 500, "A's own cancellation did not take effect");
    }

    /// @notice Cancelling out of the middle of a shared queue must not reshuffle the surviving
    ///         entries: `settleBatch` fills in queue order, so compaction has to be stable.
    function test_cancelAllOrdersPreservesSurvivingQueueOrder() public {
        _fundTwoDepositors();
        sim.setMarkPrice(MARKET, 100e18);

        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        uint48 bIdx = sim.addressToAccountIndex(depositorB);

        // A, B, A, B, A interleaved on the same market.
        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 100, 10_000, 0, 1);
        vm.prank(depositorB);
        sim.createOrder(bIdx, MARKET, 9_000, 10_000, 0, 1);
        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 20, 10_000, 0, 1);
        vm.prank(depositorB);
        sim.createOrder(bIdx, MARKET, 9_000, 10_000, 0, 1);
        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 3, 10_000, 0, 1);

        vm.prank(depositorB);
        sim.cancelAllOrders(bIdx);

        sim.settleBatch();
        // Exactly A's three orders remain, all of them, once each.
        assertEq(sim.positionBase(MARKET), 123, "compaction lost or duplicated an order");
    }

    /// @notice The binding is on `LighterCore`, so the test mock inherits it too. That is
    ///         deliberate — the suite must run against the venue's real authorisation model, and a
    ///         mock that is looser than the deployed artefact is how this defect survived to
    ///         Task 4 in the first place.
    function test_theBindingIsOnTheCoreSoTheMockInheritsIt() public {
        mockL.deposit(address(this), ASSET_IDX, 0, 1_000e6);
        uint48 idx = mockL.addressToAccountIndex(address(this));

        vm.prank(stranger);
        vm.expectRevert(LighterCore.LighterCore_AccountNotCaller.selector);
        mockL.withdraw(idx, ASSET_IDX, 0, 100e6);

        vm.prank(stranger);
        vm.expectRevert(LighterCore.LighterCore_AccountNotCaller.selector);
        mockL.createOrder(idx, MARKET, 100, 35586, 0, 1);

        vm.prank(stranger);
        vm.expectRevert(LighterCore.LighterCore_AccountNotCaller.selector);
        mockL.cancelAllOrders(idx);
    }

    /// @notice `deposit(to, ...)` is deliberately NOT bound to its caller: it legitimately
    ///         registers another address, which is how a vault gets an account index at all — the
    ///         vault is registered by whoever funds it.
    function test_depositStillRegistersAThirdParty() public {
        sim.deposit(depositorA, ASSET_IDX, 0, 1_000e6); // funded by this contract, registers A
        assertGt(sim.addressToAccountIndex(depositorA), 0, "third-party registration broke");
        assertEq(sim.addressToAccountIndex(address(this)), 0, "the funder got registered instead");
    }

    // ---------------------------------------------------------------------------------------
    // Task 5, items 1, 2 and 4: the operator surface is gated, and the margin fraction is floored.
    // ---------------------------------------------------------------------------------------

    function test_setRequiredMarginBpsIsOwnerOnly() public {
        vm.prank(stranger);
        vm.expectRevert(LighterSim.LighterSim_OnlyOwner.selector);
        sim.setRequiredMarginBps(9_000);

        sim.setRequiredMarginBps(9_000); // owner
        assertEq(sim.requiredMarginBps(), 9_000);
    }

    function test_setMarkPriceIsOwnerOnly() public {
        vm.prank(stranger);
        vm.expectRevert(LighterSim.LighterSim_OnlyOwner.selector);
        sim.setMarkPrice(MARKET, 100e18);

        sim.setMarkPrice(MARKET, 100e18); // owner
        assertEq(sim.markPrice(MARKET), 100e18);
    }

    function test_setDepositCapTicksIsOwnerOnly() public {
        vm.prank(stranger);
        vm.expectRevert(LighterSim.LighterSim_OnlyOwner.selector);
        sim.setDepositCapTicks(1_000);

        sim.setDepositCapTicks(1_000); // owner
        assertEq(sim.depositCapTicks(), 1_000);
    }

    /// @notice The floor is the venue's measured requirement. Raising is allowed (harder than
    ///         mainnet); lowering below it is impossible, not merely discouraged.
    function test_marginCannotGoBelowVenueFloor() public {
        assertEq(sim.VENUE_IMF_BPS(), 5_000, "the measured venue IMF changed");

        vm.expectRevert(LighterSim.LighterSim_MarginBelowVenueFloor.selector);
        sim.setRequiredMarginBps(4_999);

        // Lighter's own foreign-testnet values, which is the realistic way this gets misconfigured.
        vm.expectRevert(LighterSim.LighterSim_MarginBelowVenueFloor.selector);
        sim.setRequiredMarginBps(500);
        vm.expectRevert(LighterSim.LighterSim_MarginBelowVenueFloor.selector);
        sim.setRequiredMarginBps(666);
        vm.expectRevert(LighterSim.LighterSim_MarginBelowVenueFloor.selector);
        sim.setRequiredMarginBps(0);

        sim.setRequiredMarginBps(5_000);
        assertEq(sim.requiredMarginBps(), 5_000, "the floor itself was refused");
        sim.setRequiredMarginBps(9_000);
        assertEq(sim.requiredMarginBps(), 9_000, "raising the requirement was refused");
    }

    /// @notice Item 4: a misconfigured simulator cannot be deployed at all, so there is no window
    ///         — not even one block — in which it is more permissive than the venue.
    function test_constructorRejectsMarginBelowFloor() public {
        vm.expectRevert(LighterSim.LighterSim_MarginBelowVenueFloor.selector);
        new LighterSim(IERC20(address(usdgSim)), ASSET_IDX, SIZE_DECIMALS, 4_999, address(this));

        vm.expectRevert(LighterSim.LighterSim_MarginBelowVenueFloor.selector);
        new LighterSim(IERC20(address(usdgSim)), ASSET_IDX, SIZE_DECIMALS, 500, address(this));

        vm.expectRevert(LighterSim.LighterSim_MarginBelowVenueFloor.selector);
        new LighterSim(IERC20(address(usdgSim)), ASSET_IDX, SIZE_DECIMALS, 0, address(this));

        LighterSim ok = new LighterSim(IERC20(address(usdgSim)), ASSET_IDX, SIZE_DECIMALS, 5_000, address(this));
        assertEq(ok.requiredMarginBps(), 5_000);
        assertEq(ok.owner(), address(this));
    }

    function test_constructorRejectsAZeroOwner() public {
        vm.expectRevert(LighterSim.LighterSim_OwnerIsZero.selector);
        new LighterSim(IERC20(address(usdgSim)), ASSET_IDX, SIZE_DECIMALS, IMF, address(0));
    }

    /// @notice Every owner-gated setter emits the value before and after, so a testnet's
    ///         configuration history is reconstructible from logs rather than from trust.
    function test_ownerKnobsEmitEvents() public {
        vm.expectEmit(true, true, true, true, address(sim));
        emit LighterSim.RequiredMarginBpsSet(5_000, 9_000);
        sim.setRequiredMarginBps(9_000);

        vm.expectEmit(true, true, true, true, address(sim));
        emit LighterSim.MarkPriceSet(MARKET, 0, 100e18);
        sim.setMarkPrice(MARKET, 100e18);

        vm.expectEmit(true, true, true, true, address(sim));
        emit LighterSim.MarkPriceSet(MARKET, 100e18, 120e18);
        sim.setMarkPrice(MARKET, 120e18);

        uint256 capBefore = sim.depositCapTicks();
        vm.expectEmit(true, true, true, true, address(sim));
        emit LighterSim.DepositCapTicksSet(capBefore, 1_234);
        sim.setDepositCapTicks(1_234);
    }

    /// @notice The construction-time margin fraction is announced too, so the deployed value never
    ///         has to be inferred from a storage read.
    function test_constructorEmitsTheMarginFraction() public {
        vm.expectEmit(true, true, true, true);
        emit LighterSim.RequiredMarginBpsSet(0, 7_500);
        new LighterSim(IERC20(address(usdgSim)), ASSET_IDX, SIZE_DECIMALS, 7_500, address(this));
    }

    // ---------------------------------------------------------------------------------------
    // Task 5, items 3 and 8: a zero mark fails closed.
    // ---------------------------------------------------------------------------------------

    /// @notice **The vacuous-gate proof.** Deposit, queue an order, settle without ever setting a
    ///         mark: the batch must be refused rather than filling an unmargined position.
    function test_settleBatchRevertsOnUnsetMarkPrice() public {
        sim.deposit(address(this), ASSET_IDX, 0, 1e6); // $1 of margin
        uint48 idx = sim.addressToAccountIndex(address(this));

        // $10,000 of notional at a real mark — 10_000x the posted margin.
        sim.createOrder(idx, MARKET, 1_000_000, 35586, 0, 1);

        vm.expectRevert(abi.encodeWithSelector(LighterSim.LighterSim_MarkPriceUnset.selector, MARKET));
        sim.settleBatch();

        // Nothing filled, so nothing was margined at zero.
        assertEq(sim.positionBase(MARKET), 0, "an unmargined position was opened");
        assertEq(sim.entryPrice(MARKET), 0, "an entry price was recorded at a zero mark");

        // With the mark set, the same batch is refused for the RIGHT reason: the gate is live.
        sim.setMarkPrice(MARKET, 35586e16);
        vm.expectRevert(LighterCore.InsufficientMargin.selector);
        sim.settleBatch();
    }

    /// @notice The guard covers every market in the batch, not only the ones that would reach the
    ///         margin branch. A decrease settled at a zero mark still corrupts the entry-price book
    ///         — `_applyFill` writes `entryPrice = 0` and `_pnl18` then early-returns forever, so
    ///         `unrealisedPnl()` is dead and `equity() == marginBalance`. That silent state is what
    ///         hid a Critical in this project's external audit.
    function test_settleBatchRevertsOnAnUnsetMarkForAnyMarketInTheBatch() public {
        sim.deposit(address(this), ASSET_IDX, 0, 100_000e6);
        uint48 idx = sim.addressToAccountIndex(address(this));
        sim.setMarkPrice(MARKET, 100e18); // MARKET priced, MARKET_B not

        sim.createOrder(idx, MARKET, 100, 10_000, 0, 1);
        sim.createOrder(idx, MARKET_B, 100, 5_000, 0, 1);

        vm.expectRevert(abi.encodeWithSelector(LighterSim.LighterSim_MarkPriceUnset.selector, MARKET_B));
        sim.settleBatch();

        // The whole batch is refused, including the priced leg: a partially-settled batch would
        // leave the queue and the position ledger disagreeing.
        assertEq(sim.positionBase(MARKET), 0, "the priced leg settled anyway");

        sim.setMarkPrice(MARKET_B, 50e18);
        sim.settleBatch();
        assertEq(sim.positionBase(MARKET), 100);
        assertEq(sim.positionBase(MARKET_B), 100);
        assertEq(sim.entryPrice(MARKET_B), 50e18, "entry not recorded at the real mark");
    }

    /// @notice An empty batch is not "a market with no mark", so settling nothing still succeeds.
    function test_settleBatchOnAnEmptyQueueIsAllowed() public {
        sim.settleBatch();
    }

    /// @notice The guard is on `LighterSim` and NOT on `LighterCore`, so `MockLighter` keeps
    ///         settling markless batches. `test/mocks/MockLighter.t.sol`'s
    ///         `test_orderDoesNotFillUntilBatchSettles` and
    ///         `test_zeroBaseAmountClosesEntirePosition` pin the asynchronous-fill and close-all
    ///         primitives and have no business caring about a price; a core-level guard would force
    ///         marks into tests that are not about marks. Pinned here so the placement is a
    ///         decision on the record rather than an accident.
    function test_theMarkGuardIsOnTheDeployableFrontEndOnly() public {
        mockL.deposit(address(this), ASSET_IDX, 0, 1_000e6);
        uint48 idx = mockL.addressToAccountIndex(address(this));
        mockL.createOrder(idx, MARKET, 100, 35586, 0, 1);
        mockL.settleBatch(); // no mark set, and that stays legal on the test front end
        assertEq(mockL.positionBase(MARKET), 100);
    }

    // ---------------------------------------------------------------------------------------
    // Deployability and surface hygiene.
    // ---------------------------------------------------------------------------------------

    function test_simIsDeployableUnderEip170() public {
        address deployed =
            address(new LighterSim(IERC20(address(usdgSim)), ASSET_IDX, SIZE_DECIMALS, IMF, address(this)));
        uint256 size = deployed.code.length;
        assertGt(size, 0, "LighterSim did not deploy");
        assertLt(size, 24_576, "LighterSim exceeds EIP-170");
    }

    /// @notice `MockLighter`'s fault injection and queue introspection did not reach the deployable
    ///         contract. Each would be a knob or an oracle no real venue exposes.
    ///
    /// @dev Task 5 SPLIT this test, and the reason is itself the class of defect this task is
    ///      about. The original probed all eight names with `abi.encodeWithSignature(sig)` and NO
    ///      arguments, then asserted the call failed. For a function that does not exist that is a
    ///      real probe; for one that DOES it is vacuous, because a bare selector fails in the ABI
    ///      decoder before reaching any body. Task 5 legitimately adds `setMarkPrice`,
    ///      `setRequiredMarginBps` and `setDepositCapTicks` to `LighterSim` as owner-gated knobs,
    ///      so those three would have kept "passing" while asserting nothing at all. They are now
    ///      probed for GATING (below) with correctly-encoded arguments, and the five names that
    ///      must still not exist are probed here with correct encoding too.
    function test_simDoesNotInheritTestConveniences() public {
        // The mock needs one queued order, or its own `lastOrder()` reverts on an empty array and
        // the sanity probe below would fail for a reason that has nothing to do with the leak.
        mockL.deposit(address(this), ASSET_IDX, 0, 1_000e6);
        mockL.createOrder(mockL.addressToAccountIndex(address(this)), MARKET, 100, 35586, 0, 1);

        bytes[5] memory leaks = [
            abi.encodeWithSignature("setShouldRevertDrain(bool)", true),
            abi.encodeWithSignature("setShouldRevertPendingRead(bool)", true),
            abi.encodeWithSignature("setShouldRevertCreateOrder(bool)", true),
            abi.encodeWithSignature("queuedOrderCount()"),
            abi.encodeWithSignature("lastOrder()")
        ];
        for (uint256 i = 0; i < leaks.length; ++i) {
            (bool ok,) = address(sim).call(leaks[i]);
            assertFalse(ok, "a test convenience reached the deployable contract");
            // Sanity: the same probe SUCCEEDS against the mock, so the assertion above fails for
            // the right reason rather than because the encoding is wrong.
            (bool mockOk,) = address(mockL).call(leaks[i]);
            assertTrue(mockOk, "probe encoding is wrong");
        }
    }

    /// @notice The three knobs `LighterSim` does expose are unreachable by a stranger. This is the
    ///         assertion that replaces the vacuous half of the probe above.
    function test_theOperatorKnobsThatDoExistAreAllGated() public {
        bytes[3] memory knobs = [
            abi.encodeWithSignature("setMarkPrice(uint16,uint256)", MARKET, uint256(100e18)),
            abi.encodeWithSignature("setRequiredMarginBps(uint256)", uint256(9_000)),
            abi.encodeWithSignature("setDepositCapTicks(uint256)", uint256(1_000))
        ];
        for (uint256 i = 0; i < knobs.length; ++i) {
            vm.prank(stranger);
            (bool ok, bytes memory ret) = address(sim).call(knobs[i]);
            assertFalse(ok, "an operator knob was reachable by a stranger");
            assertEq(bytes4(ret), LighterSim.LighterSim_OnlyOwner.selector, "wrong revert reason");

            // And the owner can reach it, so the gate is a gate and not a brick.
            (bool ownerOk,) = address(sim).call(knobs[i]);
            assertTrue(ownerOk, "the owner could not reach its own knob");
        }
    }

    /// @dev `LighterCore` is abstract on purpose: a deployable core would be a permanent, ungated
    ///      bypass of everything above — the caller binding is on the core, but the owner gating,
    ///      the margin floor and the mark guard are on this front end. Recorded here because it is
    ///      a structural decision and `forge build --sizes` cannot show it.
    function test_simIsTheOnlyDeployableFrontEndInSrcSim() public view {
        assertGt(address(sim).code.length, 0, "sim is deployable");
    }

    // ---------------------------------------------------------------------------------------

    /// @dev Two funded, registered accounts on the sim: 600_000 and 400_000 USDG. `marginBalance`
    ///      is global in `LighterCore` (per-account isolation is Task 7), which is exactly why the
    ///      unbound `withdraw` was a total drain rather than a single-account one.
    function _fundTwoDepositors() internal {
        usdgSim.mint(depositorA, 600_000e6);
        usdgSim.mint(depositorB, 400_000e6);
        vm.prank(depositorA);
        usdgSim.approve(address(sim), type(uint256).max);
        vm.prank(depositorB);
        usdgSim.approve(address(sim), type(uint256).max);
        vm.prank(depositorA);
        sim.deposit(depositorA, ASSET_IDX, 0, 600_000e6);
        vm.prank(depositorB);
        sim.deposit(depositorB, ASSET_IDX, 0, 400_000e6);
    }

    function _assertSameState(string memory tag) internal view {
        assertEq(mockL.marginBalance(), sim.marginBalance(), string.concat("marginBalance ", tag));
        assertEq(mockL.positionBase(MARKET), sim.positionBase(MARKET), string.concat("positionBase ", tag));
        assertEq(mockL.entryPrice(MARKET), sim.entryPrice(MARKET), string.concat("entryPrice ", tag));
        assertEq(mockL.markPrice(MARKET), sim.markPrice(MARKET), string.concat("markPrice ", tag));
        assertEq(mockL.unrealisedPnl(), sim.unrealisedPnl(), string.concat("unrealisedPnl ", tag));
        assertEq(mockL.equity(), sim.equity(), string.concat("equity ", tag));
        assertEq(mockL.requiredMarginBps(), sim.requiredMarginBps(), string.concat("requiredMarginBps ", tag));
        assertEq(mockL.depositCapTicks(), sim.depositCapTicks(), string.concat("depositCapTicks ", tag));
        assertEq(
            mockL.getPendingBalance(address(this), ASSET_IDX),
            sim.getPendingBalance(address(this), ASSET_IDX),
            string.concat("pending ", tag)
        );
        assertEq(
            usdgMock.balanceOf(address(mockL)),
            usdgSim.balanceOf(address(sim)),
            string.concat("venue token holdings ", tag)
        );
    }
}
