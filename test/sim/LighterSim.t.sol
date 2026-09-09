// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LighterCore} from "../../src/sim/LighterCore.sol";
import {LighterSim} from "../../src/sim/LighterSim.sol";
import {MockLighter} from "../mocks/MockLighter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice Task 4 acceptance tests (`MockLighter` and `LighterSim` are two front ends onto one
///         behaviour implementation, and the deployable one fits EIP-170), Task 5's three closures
///         (caller-bound account operations, a gated and floored operator surface, and a
///         `settleBatch` that fails closed on an unset mark), and TASK 7's per-account state
///         isolation.
///
/// @dev The Task 7 section is the first multi-account venue coverage in this repo. Every venue test
///      written before it ran with one account holding collateral and one account holding a
///      position, which is why a global `marginBalance`, a global `positionBase[market]` and an
///      account-less `equity()` were indistinguishable from per-account ones for three fix rounds.
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

        // Fix round 1, Critical 1. `LighterSim.deposit` now refuses a `to` the owner has not
        // approved, so every sim deposit below needs its recipient allowlisted first. This test
        // contract is the sim's owner and its main depositor. `mockL` needs nothing: the allowlist
        // is deliberately on `LighterSim` only, so `MockLighter` still registers anyone — which is
        // why no test outside this file needed a line changed.
        sim.setDepositorAllowed(address(this), true);
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
        // Task 7: `equity` takes an account index and has no global overload. One account here, so
        // every figure below is unchanged.
        assertEq(mockL.equity(mockIdx), sim.equity(simIdx), "equity");
        assertGt(sim.equity(simIdx), sim.marginBalance(), "gain not modelled");

        // Draw the whole of equity, which forces the gain to be realised and entryPrice rewritten.
        uint64 all = uint64(sim.equity(simIdx));
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
    /// @dev Task 7, item 3: `settleBatch` now rejects the individual under-margined order and
    ///      continues rather than reverting the batch, because a whole-batch revert was fix round
    ///      1's Critical 2. This test's assertion is unchanged and runs in STRICT MODE, which is
    ///      the compatibility path that exists precisely so the three pre-Task-7 tests pinning the
    ///      gate as a revert keep pinning it as a revert. The non-strict behaviour has its own
    ///      test: `test_oneAccountsBadOrderCannotBrickSettlement`.
    function test_simRejectsUnderMarginedFillLikeMock() public {
        mockL.setMarkPrice(MARKET, 100e18);
        sim.setMarkPrice(MARKET, 100e18);
        mockL.setStrictMode(true);
        sim.setStrictMode(true);
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
        sim.setDepositorAllowed(depositorA, true); // fix round 1: the recipient must be approved
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
        // Task 7, item 3: in strict mode, which is where this assertion belongs — see
        // `test_simRejectsUnderMarginedFillLikeMock`.
        sim.setStrictMode(true);
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

    /// @notice Every privileged entry point `LighterSim` exposes is unreachable by a stranger. This
    ///         is the assertion that replaces the vacuous half of the probe above, and it is the
    ///         one place the operator surface is ENUMERATED — so it must grow with the surface.
    ///
    /// @dev Fix round 1 added three: `setDepositorAllowed` (Critical 1's registration allowlist)
    ///      and the two halves of Critical 2's stuck-queue escape hatch. Leaving them out would
    ///      have reproduced §5.3's defect exactly — a green test that stays green through the
    ///      change it exists to guard against.
    ///
    ///      Task 7 added two more: `setStrictMode` and `setKeeper`. `settleBatch` is now gated too,
    ///      but it is not a knob and its refusal is `LighterSim_OnlyOwnerOrKeeper`, so it is
    ///      asserted separately in `test_settleBatchIsGatedToOwnerOrKeeper`.
    function test_theOperatorKnobsThatDoExistAreAllGated() public {
        bytes[8] memory knobs = [
            abi.encodeWithSignature("setMarkPrice(uint16,uint256)", MARKET, uint256(100e18)),
            abi.encodeWithSignature("setRequiredMarginBps(uint256)", uint256(9_000)),
            abi.encodeWithSignature("setDepositCapTicks(uint256)", uint256(1_000)),
            abi.encodeWithSignature("setDepositorAllowed(address,bool)", depositorA, true),
            abi.encodeWithSignature("ownerCancelAccountOrders(uint48)", uint48(3)),
            abi.encodeWithSignature("ownerPurgeQueue()"),
            // Task 7 added these two. The enumeration is only as good as its completeness, which is
            // this test's whole point.
            abi.encodeWithSignature("setStrictMode(bool)", true),
            abi.encodeWithSignature("setKeeper(address)", depositorA)
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
    // TASK 7: per-account state isolation.
    //
    // THIS IS THE FIRST MULTI-ACCOUNT VENUE COVERAGE IN THE REPO, and that absence is why three
    // Criticals survived three fix rounds. Every venue test written before this task ran with
    // exactly one account holding collateral and one account holding a position, so a global
    // `marginBalance`, a global `positionBase[market]` and an account-less `equity()` were
    // indistinguishable from per-account ones. Each of the tests below was written by first
    // reproducing the hole against the pre-fix artefact and watching the assertion fail.
    // ---------------------------------------------------------------------------------------

    /// @notice **THE REGRESSION TEST FOR THE MISS.** A stranger who registers cannot draw the pool.
    ///
    ///         The two prior rounds both closed this at the door: bind the call to its caller
    ///         (round 0), then restrict who may register (round 1). Neither touched the fact that
    ///         `withdraw`'s ceiling was the WHOLE POOL, so both were one successful registration
    ///         away from being no defence at all. This test therefore opens BOTH earlier gates
    ///         deliberately — the stranger is allowlisted, and it registers with a real deposit
    ///         rather than the zero-value one that is separately refused — and asserts the ceiling
    ///         itself.
    ///
    /// @dev Measured against the pre-fix artefact with exactly this fixture: the stranger deposited
    ///      1 USDG and withdrew 1_000_001 USDG, leaving the simulator holding 0. It now takes back
    ///      its own 1 USDG and not one unit more.
    function test_selfRegisteredStrangerCannotDrainThePool() public {
        _fundTwoDepositors();
        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        uint48 bIdx = sim.addressToAccountIndex(depositorB);

        // Gate 1 opened on purpose: the operator approves the attacker.
        sim.setDepositorAllowed(stranger, true);
        usdgSim.mint(stranger, 1e6);
        vm.startPrank(stranger);
        usdgSim.approve(address(sim), type(uint256).max);
        // The cheapest registration the venue permits. A literally-zero deposit is refused on the
        // core (`LighterCore_ZeroDepositAmount`, pinned in test/sim/DrainPoC.t.sol), so registering
        // for 1 unit is the strongest version of the attack that is actually reachable — and the
        // point of this test is that even a SUCCESSFUL registration buys nothing.
        sim.deposit(stranger, ASSET_IDX, 0, 1e6);
        uint48 sIdx = sim.addressToAccountIndex(stranger);
        assertGt(sIdx, 0, "the attacker did not register, so this test proves nothing");

        // The exact pre-fix drain call, and the ceiling is now the caller's own balance.
        sim.withdraw(sIdx, ASSET_IDX, 0, type(uint64).max);
        vm.stopPrank();

        assertEq(sim.getPendingBalance(stranger, ASSET_IDX), 1e6, "the ceiling was not the caller's own balance");

        // Every other account's money is exactly where it was.
        assertEq(sim.marginBalanceOf(aIdx), 600_000e6, "A's margin moved");
        assertEq(sim.marginBalanceOf(bIdx), 400_000e6, "B's margin moved");
        assertEq(sim.equity(aIdx), 600_000e6, "A's equity moved");
        assertEq(sim.equity(bIdx), 400_000e6, "B's equity moved");
        assertEq(sim.marginBalanceOf(sIdx), 0, "the attacker still has a margin balance");

        // And the collateral the simulator holds is down by the attacker's own deposit only.
        vm.prank(stranger);
        sim.withdrawPendingBalance(stranger, ASSET_IDX, 1e6);
        assertEq(usdgSim.balanceOf(stranger), 1e6, "the attacker took more than it put in");
        assertEq(usdgSim.balanceOf(address(sim)), 1_000_000e6, "the depositors' collateral left the venue");
    }

    /// @notice An account that holds NOTHING claims nothing, which is the same statement as above
    ///         with the attacker's own stake removed. Registered by a third party's deposit, then
    ///         emptied, then asking for the pool.
    function test_anAccountHoldingNothingClaimsNothing() public {
        _fundTwoDepositors();
        sim.setDepositorAllowed(stranger, true);
        sim.deposit(stranger, ASSET_IDX, 0, 1e6); // funded by this contract, registers the stranger
        uint48 sIdx = sim.addressToAccountIndex(stranger);

        vm.startPrank(stranger);
        sim.withdraw(sIdx, ASSET_IDX, 0, 1e6);
        sim.withdrawPendingBalance(stranger, ASSET_IDX, 1e6);
        assertEq(sim.equity(sIdx), 0, "the account still has equity");

        // Holding nothing, asking for everything.
        sim.withdraw(sIdx, ASSET_IDX, 0, type(uint64).max);
        vm.stopPrank();

        assertEq(sim.getPendingBalance(stranger, ASSET_IDX), 0, "an empty account was credited");
        assertEq(usdgSim.balanceOf(address(sim)), 1_000_000e6, "the depositors' collateral moved");
    }

    /// @notice `equity` is a question about ONE account, and there is no way left to ask it about
    ///         the pool.
    function test_equityIsPerAccount() public {
        _fundTwoDepositors();
        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        uint48 bIdx = sim.addressToAccountIndex(depositorB);

        assertEq(sim.equity(aIdx), 600_000e6, "A sees the wrong equity");
        assertEq(sim.equity(bIdx), 400_000e6, "B sees the wrong equity");
        assertEq(sim.marginBalance(), 1_000_000e6, "the aggregate view stopped summing");

        // A's position gains; B's equity must not move by one unit.
        sim.setMarkPrice(MARKET, 100e18);
        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 100_000, 10_000, 0, 1); // 10 units long at 100
        sim.settleBatch();
        sim.setMarkPrice(MARKET, 120e18); // +20 -> 10 units * 20 = 200 USDG of gain

        assertEq(sim.unrealisedPnl(aIdx), 200e6, "A's gain is wrong");
        assertEq(sim.unrealisedPnl(bIdx), 0, "B was credited with A's gain");
        assertEq(sim.equity(aIdx), 600_200e6, "A's equity did not include its own gain");
        assertEq(sim.equity(bIdx), 400_000e6, "B's equity moved on A's position");
    }

    /// @notice There is deliberately NO no-argument `equity()`.
    /// @dev The global figure was `withdraw`'s ceiling for two fix rounds and it is the single line
    ///      that turned every one of this simulator's holes into a total drain. Asserting its
    ///      ABSENCE is what stops the next `withdraw`-shaped entry point reintroducing it by
    ///      autocomplete. Probed with correct encoding, both halves asserted — see
    ///      `test_simDoesNotInheritTestConveniences` for why a bare-selector probe is vacuous.
    function test_thereIsNoGlobalEquityOverload() public {
        (bool globalOk,) = address(sim).call(abi.encodeWithSignature("equity()"));
        assertFalse(globalOk, "a global equity() is still callable");
        (bool mockGlobalOk,) = address(mockL).call(abi.encodeWithSignature("equity()"));
        assertFalse(mockGlobalOk, "a global equity() is still callable on the test front end");

        // Sanity: the per-account one exists on both, so the assertions above fail for the right
        // reason rather than because the encoding is wrong.
        (bool simOk,) = address(sim).call(abi.encodeWithSignature("equity(uint48)", uint48(3)));
        assertTrue(simOk, "equity(uint48) is missing");
        (bool mockOk,) = address(mockL).call(abi.encodeWithSignature("equity(uint48)", uint48(3)));
        assertTrue(mockOk, "equity(uint48) is missing on the test front end");
    }

    /// @notice Vault A cannot open a position on vault B's margin.
    ///
    /// @dev The initial-margin check read the GLOBAL cash balance, so an account holding 1 USDG
    ///      could open whatever the pool covered. Reproduced before the fix with exactly this
    ///      fixture: the poor account's $10,000 notional position filled.
    function test_marginIsIsolatedPerAccount() public {
        _fundTwoDepositors();
        sim.setMarkPrice(MARKET, 100e18);

        // A third account with a dollar, next to 1_000_000 USDG of other people's collateral.
        sim.setDepositorAllowed(stranger, true);
        usdgSim.mint(stranger, 1e6);
        vm.startPrank(stranger);
        usdgSim.approve(address(sim), type(uint256).max);
        sim.deposit(stranger, ASSET_IDX, 0, 1e6);
        uint48 sIdx = sim.addressToAccountIndex(stranger);
        // 1_000_000 base ticks at size_decimals 4 is 100 units => $10,000 notional against $1.
        sim.createOrder(sIdx, MARKET, 1_000_000, 10_000, 0, 1);
        vm.stopPrank();

        sim.settleBatch();
        assertEq(sim.positionBaseOf(sIdx, MARKET), 0, "an account opened a position on the pool's margin");
        assertEq(sim.positionBase(MARKET), 0, "the venue took on the position anyway");

        // The SAME order from an account that can actually cover it fills, so the gate is a gate
        // and not a brick.
        uint48 bIdx = sim.addressToAccountIndex(depositorB);
        vm.prank(depositorB);
        sim.createOrder(bIdx, MARKET, 1_000_000, 10_000, 0, 1);
        sim.settleBatch();
        assertEq(sim.positionBaseOf(bIdx, MARKET), 1_000_000, "a covered order was refused");
        assertEq(sim.positionBaseOf(sIdx, MARKET), 0, "the poor account got a position after all");
    }

    /// @notice **THE HEDGE-DESTRUCTION REGRESSION TEST**, from the Task 5 fix-round re-review.
    ///
    ///         `settleBatch` read `previous = positionBase[o.marketIndex]` with NO account scoping,
    ///         and `baseAmount == 0` means "the full position size on the side the caller named".
    ///         So any second registered account could queue
    ///         `createOrder(idx, market, 0, px, isAsk = 1, 1)` and, at settlement, zero out the
    ///         vault's entire hedge. Same harm as the pre-Task-5 `delete _queue`, reached through
    ///         settlement rather than cancellation, and `Order.account` did not touch it because
    ///         that attribution governed CANCELLATION only.
    ///
    /// @dev Measured against the pre-fix artefact: the vault's 100_000-tick hedge went to 0 in one
    ///      settled batch. The assertion below is the one that flipped.
    function test_aSecondAccountCannotDestroyTheVaultsHedge() public {
        _fundTwoDepositors();
        sim.setMarkPrice(MARKET, 100e18);
        uint48 aIdx = sim.addressToAccountIndex(depositorA);

        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 100_000, 10_000, 0, 1);
        sim.settleBatch();
        assertEq(sim.positionBaseOf(aIdx, MARKET), 100_000, "the hedge did not open");

        // The attack, verbatim from the amendment. B is a legitimately registered, funded account.
        uint48 bIdx = sim.addressToAccountIndex(depositorB);
        vm.prank(depositorB);
        sim.createOrder(bIdx, MARKET, 0, 10_000, 1, 1);
        sim.settleBatch();

        assertEq(sim.positionBaseOf(aIdx, MARKET), 100_000, "a second account destroyed the vault's hedge");
        assertEq(sim.positionBaseOf(bIdx, MARKET), 0, "the zero-amount order acted on an empty book");
        assertEq(sim.positionBase(MARKET), 100_000, "the venue's net position moved");
    }

    /// @notice And the close-all primitive still works for its OWN position, which is why the fix
    ///         is a scoping change rather than a rejection of `baseAmount == 0`.
    ///
    /// @dev `CertVault.closeAll()` is a real caller of Lighter's zero-amount "default to the full
    ///      position size" primitive — governance's wind-down of last resort submits a literal 0 on
    ///      the side its own ledger says it holds. Rejecting zero amounts at `createOrder` would
    ///      have broken it, so Task 7 took the amendment's PREFERRED option: scope the reading to
    ///      the submitting account. This test is what makes that choice safe to have made.
    function test_zeroBaseAmountClosesTheSubmittersOwnPosition() public {
        _fundTwoDepositors();
        sim.setMarkPrice(MARKET, 100e18);
        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        uint48 bIdx = sim.addressToAccountIndex(depositorB);

        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 100_000, 10_000, 0, 1);
        vm.prank(depositorB);
        sim.createOrder(bIdx, MARKET, 700, 10_000, 0, 1);
        sim.settleBatch();

        // A closes its own long with the primitive. B's position must be untouched.
        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 0, 10_000, 1, 1);
        sim.settleBatch();
        assertEq(sim.positionBaseOf(aIdx, MARKET), 0, "the close-all primitive stopped closing");
        assertEq(sim.entryPriceOf(aIdx, MARKET), 0, "a flat position kept an entry price");
        assertEq(sim.positionBaseOf(bIdx, MARKET), 700, "the close-all reached another account");

        // And the M-3 reading is preserved: an ASK against a SHORT doubles it rather than closing
        // it, on the submitter's own book.
        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 500, 10_000, 1, 1); // open a short
        sim.settleBatch();
        assertEq(sim.positionBaseOf(aIdx, MARKET), -500);
        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 0, 10_000, 1, 1); // full-size ASK against a SHORT
        sim.settleBatch();
        assertEq(sim.positionBaseOf(aIdx, MARKET), -1_000, "the wrong-side close-all stopped being harmful");
    }

    /// @notice **THE CRITICAL 2 REGRESSION TEST.** One account's unsettleable order is rejected
    ///         individually and every other account still settles.
    ///
    /// @dev Fix round 1's Critical 2 was the liveness regression the caller binding INTRODUCED:
    ///      once only an order's own account could cancel it, and `settleBatch` reverted as a
    ///      whole, one under-margined order killed settlement for everyone — permanently, with no
    ///      operator recourse and `requiredMarginBps` only raisable. Round 1 shipped an owner
    ///      escape hatch. This is the structural fix, and it means the jam cannot form.
    function test_oneAccountsBadOrderCannotBrickSettlement() public {
        _fundTwoDepositors();
        sim.setMarkPrice(MARKET, 100e18);
        uint48 aIdx = sim.addressToAccountIndex(depositorA);

        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 100, 10_000, 0, 1); // the vault's legitimate hedge

        sim.setDepositorAllowed(stranger, true);
        usdgSim.mint(stranger, 1e6);
        vm.startPrank(stranger);
        usdgSim.approve(address(sim), type(uint256).max);
        sim.deposit(stranger, ASSET_IDX, 0, 1e6);
        uint48 sIdx = sim.addressToAccountIndex(stranger);
        sim.createOrder(sIdx, MARKET, type(uint48).max, 10_000, 0, 1); // the poison pill
        vm.stopPrank();

        // No revert, and the refusal is on the record naming the order and the reason.
        vm.expectEmit(true, true, true, true, address(sim));
        emit LighterCore.OrderRejected(sIdx, MARKET, 1, LighterCore.InsufficientMargin.selector);
        sim.settleBatch();

        assertEq(sim.positionBaseOf(aIdx, MARKET), 100, "the honest hedge did not fill");
        assertEq(sim.positionBaseOf(sIdx, MARKET), 0, "the poison pill filled");
        assertEq(sim.queueLength(), 0, "the rejected order stayed in the queue");
        assertEq(sim.queuedOrdersOf(sIdx), 0, "the rejected order still counts against its account");

        // And settlement keeps working afterwards, which is the half round 1 could not deliver.
        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 50, 10_000, 0, 1);
        sim.settleBatch();
        assertEq(sim.positionBaseOf(aIdx, MARKET), 150, "settlement did not survive the rejection");
    }

    /// @notice The compatibility path: `strictMode` restores revert-on-first-failure.
    /// @dev Three pre-Task-7 tests pin the margin gate AS A REVERT, which is still the sharpest
    ///      available proof that the gate is not vacuous. Rather than soften them, they run in
    ///      strict mode; this test is what keeps the mode itself honest.
    function test_strictModeStillRevertsOnInsufficientMargin() public {
        _fundTwoDepositors();
        sim.setMarkPrice(MARKET, 100e18);
        sim.setDepositorAllowed(stranger, true);
        usdgSim.mint(stranger, 1e6);
        vm.startPrank(stranger);
        usdgSim.approve(address(sim), type(uint256).max);
        sim.deposit(stranger, ASSET_IDX, 0, 1e6);
        uint48 sIdx = sim.addressToAccountIndex(stranger);
        sim.createOrder(sIdx, MARKET, type(uint48).max, 10_000, 0, 1);
        vm.stopPrank();

        // Default is OFF, so the same queue settles.
        assertFalse(sim.strictMode(), "strict mode must not be the deployed default");

        sim.setStrictMode(true);
        assertTrue(sim.strictMode());
        vm.expectRevert(LighterCore.InsufficientMargin.selector);
        sim.settleBatch();

        // Off again, and the order is rejected instead. Nothing about the THRESHOLD changed
        // between the two runs — only what the venue does about it.
        sim.setStrictMode(false);
        sim.settleBatch();
        assertEq(sim.positionBaseOf(sIdx, MARKET), 0, "the order filled in non-strict mode");
    }

    function test_setStrictModeIsOwnerOnlyAndEvented() public {
        vm.prank(stranger);
        vm.expectRevert(LighterSim.LighterSim_OnlyOwner.selector);
        sim.setStrictMode(true);

        vm.expectEmit(true, true, true, true, address(sim));
        emit LighterSim.StrictModeSet(false, true);
        sim.setStrictMode(true);
    }

    /// @notice `cancelAllOrders(accountIndex)` affects only the caller's account, asserted on the
    ///         PER-ACCOUNT books this task introduced rather than on a global net figure.
    /// @dev The pre-existing `test_cancelAllOrdersOnlyTouchesTheCallersQueue` asserts the same
    ///      property through `positionBase(market)`, which on a two-account venue is a NET figure —
    ///      A's +500 and B's -500 would have summed to the same 0 as "nothing filled". This one
    ///      cannot be fooled that way, which is the whole difference multi-account coverage makes.
    function test_cancelAllOrdersOnlyAffectsCallerAccount() public {
        _fundTwoDepositors();
        sim.setMarkPrice(MARKET, 100e18);
        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        uint48 bIdx = sim.addressToAccountIndex(depositorB);

        // Deliberately opposite sides of the SAME market and the same size, so a net-position
        // assertion could not tell "both filled" from "neither filled".
        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 500, 10_000, 0, 1); // long
        vm.prank(depositorB);
        sim.createOrder(bIdx, MARKET, 500, 10_000, 1, 1); // short

        vm.prank(depositorB);
        sim.cancelAllOrders(bIdx);
        assertEq(sim.queuedOrdersOf(bIdx), 0, "B's counter did not come down with its orders");
        assertEq(sim.queuedOrdersOf(aIdx), 1, "A's counter came down with B's cancellation");

        sim.settleBatch();
        assertEq(sim.positionBaseOf(aIdx, MARKET), 500, "A's order was cancelled by B");
        assertEq(sim.positionBaseOf(bIdx, MARKET), 0, "B's own order was not cancelled");
    }

    /// @notice Item 4: `settleBatch` processes at most `SETTLE_BATCH_MAX` orders, in bounded gas,
    ///         and repeated calls drain the queue.
    function test_settleBatchCursorBoundsGas() public {
        _fundTwoDepositors();
        sim.setMarkPrice(MARKET, 100e18);
        uint48 aIdx = sim.addressToAccountIndex(depositorA);

        uint256 total = 100; // > SETTLE_BATCH_MAX (64), < MAX_ORDERS_PER_ACCOUNT (128)
        vm.startPrank(depositorA);
        for (uint256 i = 0; i < total; ++i) {
            sim.createOrder(aIdx, MARKET, 1, 10_000, 0, 1);
        }
        vm.stopPrank();
        assertEq(sim.queuedOrdersOf(aIdx), total);

        uint256 before = gasleft();
        sim.settleBatch();
        uint256 used = before - gasleft();

        assertEq(sim.positionBaseOf(aIdx, MARKET), int256(sim.SETTLE_BATCH_MAX()), "the whole queue settled at once");
        assertEq(sim.settleCursor(), sim.SETTLE_BATCH_MAX(), "the cursor did not advance");
        // A generous ceiling: the point is that it is a CONSTANT in the queue's length, not that it
        // is small. The pre-fix loop was O(queue) with no bound at all.
        assertLt(used, 15_000_000, "one settleBatch call is not gas-bounded");

        // Called again, it drains the rest and resets.
        sim.settleBatch();
        assertEq(sim.positionBaseOf(aIdx, MARKET), int256(total), "the queue did not drain");
        assertEq(sim.settleCursor(), 0, "the cursor did not reset");
        assertEq(sim.queueLength(), 0, "the queue was not cleared");
        assertEq(sim.queuedOrdersOf(aIdx), 0, "the per-account counter did not drain");
    }

    /// @notice A cancellation between two halves of a drain cannot rewind or re-settle a fill.
    /// @dev `_cancelOrdersOf` compacts from `settleCursor`, not from 0. Compacting over the settled
    ///      prefix would either replay a fill or drop an unsettled order.
    function test_cancellationCannotRewindASettledPrefix() public {
        _fundTwoDepositors();
        sim.setMarkPrice(MARKET, 100e18);
        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        uint48 bIdx = sim.addressToAccountIndex(depositorB);

        vm.startPrank(depositorA);
        for (uint256 i = 0; i < 70; ++i) {
            sim.createOrder(aIdx, MARKET, 1, 10_000, 0, 1);
        }
        vm.stopPrank();
        vm.prank(depositorB);
        sim.createOrder(bIdx, MARKET, 5, 10_000, 0, 1);

        sim.settleBatch(); // settles the first 64, all A's
        assertEq(sim.positionBaseOf(aIdx, MARKET), 64);

        // A cancels what it has left. Its 64 filled ticks must stay filled, and B's order must
        // still be there to settle.
        vm.prank(depositorA);
        sim.cancelAllOrders(aIdx);
        assertEq(sim.positionBaseOf(aIdx, MARKET), 64, "a cancellation rewound a settled fill");
        assertEq(sim.queuedOrdersOf(aIdx), 0);

        sim.settleBatch();
        assertEq(sim.positionBaseOf(aIdx, MARKET), 64, "a settled prefix was replayed");
        assertEq(sim.positionBaseOf(bIdx, MARKET), 5, "another account's order was lost");
        assertEq(sim.queueLength(), 0);
    }

    /// @notice Item 4: the queue is bounded per account, so no one account can monopolise it.
    function test_queueIsCappedPerAccount() public {
        _fundTwoDepositors();
        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        uint256 cap = sim.MAX_ORDERS_PER_ACCOUNT();

        vm.startPrank(depositorA);
        for (uint256 i = 0; i < cap; ++i) {
            sim.createOrder(aIdx, MARKET, 1, 10_000, 0, 1);
        }
        vm.expectRevert(LighterCore.LighterCore_AccountOrderCapReached.selector);
        sim.createOrder(aIdx, MARKET, 1, 10_000, 0, 1);
        vm.stopPrank();

        // A different account is unaffected: the per-account cap is not a global lockout.
        uint48 bIdx = sim.addressToAccountIndex(depositorB);
        vm.prank(depositorB);
        sim.createOrder(bIdx, MARKET, 1, 10_000, 0, 1);
        assertEq(sim.queuedOrdersOf(bIdx), 1, "the per-account cap locked out another account");
    }

    /// @notice Item 4: and the queue is bounded globally, which is what makes the operator hatch's
    ///         cost a number rather than an unknown.
    /// @dev `MAX_QUEUE / MAX_ORDERS_PER_ACCOUNT` accounts are needed to reach it, which is the
    ///      point: the global bound exists for the hatch's gas, the per-account bound exists so the
    ///      global one cannot be weaponised.
    function test_queueIsCappedGlobally() public {
        sim.setMarkPrice(MARKET, 100e18);
        uint256 perAccount = sim.MAX_ORDERS_PER_ACCOUNT();
        uint256 accounts = sim.MAX_QUEUE() / perAccount;

        for (uint256 a = 0; a < accounts; ++a) {
            address who = address(uint160(0xC0DE00 + a));
            sim.setDepositorAllowed(who, true);
            usdgSim.mint(who, 1_000e6);
            vm.startPrank(who);
            usdgSim.approve(address(sim), type(uint256).max);
            sim.deposit(who, ASSET_IDX, 0, 1_000e6);
            uint48 idx = sim.addressToAccountIndex(who);
            for (uint256 i = 0; i < perAccount; ++i) {
                sim.createOrder(idx, MARKET, 1, 10_000, 0, 1);
            }
            vm.stopPrank();
        }
        assertEq(sim.queueLength(), sim.MAX_QUEUE(), "the fixture did not fill the queue");

        address extra = address(uint160(0xC0DEFF));
        sim.setDepositorAllowed(extra, true);
        usdgSim.mint(extra, 1_000e6);
        vm.startPrank(extra);
        usdgSim.approve(address(sim), type(uint256).max);
        sim.deposit(extra, ASSET_IDX, 0, 1_000e6);
        uint48 extraIdx = sim.addressToAccountIndex(extra);
        vm.expectRevert(LighterCore.LighterCore_QueueFull.selector);
        sim.createOrder(extraIdx, MARKET, 1, 10_000, 0, 1);
        vm.stopPrank();

        // And the hatch that has to rescue a full queue still fits in a block.
        uint256 before = gasleft();
        sim.ownerPurgeQueue();
        assertLt(before - gasleft(), 25_000_000, "the escape hatch is priced out by a full queue");
        assertEq(sim.queueLength(), 0, "the purge left orders behind");
    }

    /// @notice A purge must release the per-account order counters with the orders it drops.
    /// @dev Otherwise the hatch meant to unstick an account would lock it out of `createOrder` up
    ///      to `MAX_ORDERS_PER_ACCOUNT` forever — a rescue that bricks what it rescues.
    function test_ownerPurgeQueueReleasesTheAccountOrderCounters() public {
        _fundTwoDepositors();
        sim.setMarkPrice(MARKET, 100e18);
        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        uint48 bIdx = sim.addressToAccountIndex(depositorB);

        vm.startPrank(depositorA);
        sim.createOrder(aIdx, MARKET, 1, 10_000, 0, 1);
        sim.createOrder(aIdx, MARKET, 2, 10_000, 0, 1);
        vm.stopPrank();
        vm.prank(depositorB);
        sim.createOrder(bIdx, MARKET, 3, 10_000, 0, 1);

        vm.expectEmit(true, false, false, true, address(sim));
        emit LighterSim.OperatorCancelledOrders(0, 3);
        sim.ownerPurgeQueue();

        assertEq(sim.queuedOrdersOf(aIdx), 0, "A stayed counted after the purge");
        assertEq(sim.queuedOrdersOf(bIdx), 0, "B stayed counted after the purge");
        assertEq(sim.settleCursor(), 0);

        // And both accounts can queue again.
        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 1, 10_000, 0, 1);
        vm.prank(depositorB);
        sim.createOrder(bIdx, MARKET, 1, 10_000, 0, 1);
        assertEq(sim.queueLength(), 2);
    }

    /// @notice Item 5: `ownerCancelAccountOrders(0)` is refused, so the documented log convention
    ///         (`accountIndex == 0` means "the whole queue was purged") is TRUE and not just
    ///         written down.
    function test_ownerCancelAccountOrdersRejectsIndexZero() public {
        vm.expectRevert(LighterSim.LighterSim_AccountIndexZeroIsReservedForPurge.selector);
        sim.ownerCancelAccountOrders(0);

        // A real index still works, so this is a guard and not a brick.
        _fundTwoDepositors();
        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 1, 10_000, 0, 1);
        vm.expectEmit(true, false, false, true, address(sim));
        emit LighterSim.OperatorCancelledOrders(aIdx, 1);
        sim.ownerCancelAccountOrders(aIdx);
    }

    /// @notice Item 2: `settleBatch` is owner-or-keeper only.
    /// @dev Permissionless settlement was judged defensible while there was a single global
    ///      position, because a caller timing a fill had no counterparty leg to profit from.
    ///      Accounts now have separate positions, so whoever settles picks which block — and
    ///      therefore which mark — someone else's queued order fills at.
    function test_settleBatchIsGatedToOwnerOrKeeper() public {
        _fundTwoDepositors();
        sim.setMarkPrice(MARKET, 100e18);

        vm.prank(stranger);
        vm.expectRevert(LighterSim.LighterSim_OnlyOwnerOrKeeper.selector);
        sim.settleBatch();

        // Not even a registered, funded depositor.
        vm.prank(depositorA);
        vm.expectRevert(LighterSim.LighterSim_OnlyOwnerOrKeeper.selector);
        sim.settleBatch();

        sim.settleBatch(); // owner
    }

    function test_keeperCanSettleAndIsOwnerSettable() public {
        _fundTwoDepositors();
        sim.setMarkPrice(MARKET, 100e18);
        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 100, 10_000, 0, 1);

        vm.prank(stranger);
        vm.expectRevert(LighterSim.LighterSim_OnlyOwner.selector);
        sim.setKeeper(stranger);

        vm.expectEmit(true, true, false, true, address(sim));
        emit LighterSim.KeeperSet(address(0), depositorB);
        sim.setKeeper(depositorB);
        assertEq(sim.keeper(), depositorB);

        vm.prank(depositorB);
        sim.settleBatch();
        assertEq(sim.positionBaseOf(aIdx, MARKET), 100, "the keeper could not settle");

        // Clearing the keeper leaves the owner as the only settler — the fail-closed direction.
        sim.setKeeper(address(0));
        vm.prank(depositorB);
        vm.expectRevert(LighterSim.LighterSim_OnlyOwnerOrKeeper.selector);
        sim.settleBatch();
    }

    /// @notice The aggregate views really are sums of the per-account books, so a log reader or an
    ///         invariant that asks a venue-level question gets a true answer.
    /// @dev They are the only remaining consumers of the old global names. Asserting they SUM is
    ///      what stops them silently becoming a second, drifting source of truth — which is the
    ///      failure mode the two-book design would otherwise invite.
    function test_aggregateViewsSumThePerAccountBooks() public {
        _fundTwoDepositors();
        sim.setMarkPrice(MARKET, 100e18);
        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        uint48 bIdx = sim.addressToAccountIndex(depositorB);

        assertEq(sim.accountCount(), 2, "the account list is wrong");
        assertEq(sim.marginBalance(), sim.marginBalanceOf(aIdx) + sim.marginBalanceOf(bIdx), "margin sum");

        // A long 400, B short 100: the NET is 300 and neither account's own figure is 300.
        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 400, 10_000, 0, 1);
        vm.prank(depositorB);
        sim.createOrder(bIdx, MARKET, 100, 10_000, 1, 1);
        sim.settleBatch();

        assertEq(sim.positionBaseOf(aIdx, MARKET), 400);
        assertEq(sim.positionBaseOf(bIdx, MARKET), -100);
        assertEq(sim.positionBase(MARKET), 300, "the net view is not a sum");
        // Both entered at the same mark, so the size-weighted mean is that mark.
        assertEq(sim.entryPrice(MARKET), 100e18, "the weighted entry view is wrong");

        sim.setMarkPrice(MARKET, 120e18);
        assertEq(
            sim.unrealisedPnl(),
            sim.unrealisedPnl(aIdx) + sim.unrealisedPnl(bIdx),
            "the aggregate pnl view is not a sum"
        );
        assertGt(sim.unrealisedPnl(aIdx), 0, "the long did not gain");
        assertLt(sim.unrealisedPnl(bIdx), 0, "the short did not lose");
    }

    /// @notice `queuedOrdersOf` matches a direct scan of the queue after every kind of mutation.
    /// @dev The counter is maintained in four places (`createOrder` up; `settleBatch`,
    ///      `_cancelOrdersOf` and `_purgeQueue` down) and a cap enforced off a drifting counter is
    ///      a lockout waiting to happen, so it is pinned against the queue itself rather than
    ///      trusted.
    function test_queuedOrderCountersTrackTheQueue() public {
        _fundTwoDepositors();
        sim.setMarkPrice(MARKET, 100e18);
        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        uint48 bIdx = sim.addressToAccountIndex(depositorB);

        vm.startPrank(depositorA);
        for (uint256 i = 0; i < 5; ++i) {
            sim.createOrder(aIdx, MARKET, 1, 10_000, 0, 1);
        }
        vm.stopPrank();
        vm.startPrank(depositorB);
        for (uint256 i = 0; i < 3; ++i) {
            sim.createOrder(bIdx, MARKET, 1, 10_000, 0, 1);
        }
        vm.stopPrank();
        assertEq(sim.queuedOrdersOf(aIdx), 5);
        assertEq(sim.queuedOrdersOf(bIdx), 3);
        assertEq(sim.queueLength(), 8);

        vm.prank(depositorA);
        sim.cancelAllOrders(aIdx);
        assertEq(sim.queuedOrdersOf(aIdx), 0, "cancel left A counted");
        assertEq(sim.queuedOrdersOf(bIdx), 3, "cancel decremented B");
        assertEq(sim.queueLength(), 3, "compaction lost or kept the wrong entries");

        sim.settleBatch();
        assertEq(sim.queuedOrdersOf(bIdx), 0, "settlement left B counted");
        assertEq(sim.queueLength(), 0);
    }

    // ---------------------------------------------------------------------------------------

    /// @dev Two funded, registered accounts on the sim: 600_000 and 400_000 USDG.
    ///
    ///      The note that used to stand here said `marginBalance` is GLOBAL in `LighterCore`, which
    ///      "is exactly why the unbound `withdraw` was a total drain rather than a single-account
    ///      one". Task 7 made that false: `marginBalanceOf`, `positionBaseOf` and `entryPriceOf`
    ///      are keyed by account index and `equity(accountIndex)` takes an account. This fixture is
    ///      now the base for the multi-account tests above, which are what prove it.
    function _fundTwoDepositors() internal {
        // Fix round 1, Critical 1: both recipients must be owner-approved before they can register.
        sim.setDepositorAllowed(depositorA, true);
        sim.setDepositorAllowed(depositorB, true);
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
        assertEq(
            mockL.equity(mockL.addressToAccountIndex(address(this))),
            sim.equity(sim.addressToAccountIndex(address(this))),
            string.concat("equity ", tag)
        );
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
