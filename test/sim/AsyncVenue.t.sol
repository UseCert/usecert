// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CertVault} from "../../src/CertVault.sol";
import {Certificate} from "../../src/Certificate.sol";
import {CertOracle} from "../../src/CertOracle.sol";
import {SolvencyRegistry} from "../../src/SolvencyRegistry.sol";
import {CapacityOracle} from "../../src/CapacityOracle.sol";
import {LighterCore} from "../../src/sim/LighterCore.sol";
import {LighterSim} from "../../src/sim/LighterSim.sol";
import {TestUSDG} from "../../src/sim/TestUSDG.sol";
import {MockLighter} from "../mocks/MockLighter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice TASK 6. The two places this simulator was EASIER THAN MAINNET, and the proof that each
///         is now as hard as the venue — plus the proof that the fix did not overshoot into the one
///         behaviour the protocol depends on.
///
/// @dev Both defects were the same shape: a decision the real venue defers to its rollup, taken
///      here in the calling transaction. Both let a testnet deployment pass where mainnet fails.
///
///      6a — `withdraw` CREDITED SYNCHRONOUSLY. The real `AdditionalZkLighter.withdraw` performs no
///      balance check at all: it validates flags, enqueues a priority request, and an insufficient
///      request is rejected INSIDE THE ROLLUP with no on-chain signal and no rollback. The caller
///      sees success and the cash never arrives. `getPendingBalance` is the only on-chain evidence
///      a withdrawal executed, which is exactly why `CertVault.recallMargin` is two-phase and
///      reduces `marginPendingRecall` only on proven arrival. A simulator that credited in the
///      calling transaction meant `_sweepPending`'s "the money may simply never come" path was
///      never exercised — the vault's entire defence against a venue that pays nothing, certified
///      by nothing.
///
///      6b — REGISTRATION RESOLVED SYNCHRONOUSLY. `deposit()` assigned `addressToAccountIndex`
///      inline, so a freshly-funded address could trade in the same transaction. On the real venue
///      the index resolves only when the rollup executes the registering deposit, which is why
///      `createOrder` reverts `AccountIsNotRegistered` until then and why
///      `docs/DEPLOYMENT-CHECKLIST.md` step 8 calls that wait "the real sequencing guarantee". A
///      deploy script validated against the old mock never exercised the window it exists to
///      protect.
///
///      AND THE THING THAT MUST NOT CHANGE, which is why this file is as much about a preserved
///      property as about two fixed ones. A request LARGER THAN THE ACCOUNT'S EQUITY is still
///      PARTIALLY FULFILLED. `CertVault.recallMargin` deliberately over-requests — it asks the
///      venue for what the vault OWES, not what it deposited, which was the C1 audit fix — and
///      that is safe only because the venue fulfils `min(request, available)`. Measured at that
///      audit: a receipt owed 7,102.97 while everything recallable totalled 3,559.54. Turning
///      partial fulfilment into all-or-nothing makes that receipt unpayable again, which is the
///      sharpest Law 2 breach the audit found — reintroduced through the simulator instead of
///      through the vault. `test_partialFulfilmentStillPartiallyFulfilsWithTheAuditsOwnNumbers`
///      pins it with those exact figures.
///
///      What DOES fail closed is a different case entirely: a credit the simulator's own token
///      balance cannot back. See `test_anUnfundableWithdrawalIsRefusedWholeAndMutatesNothing`.
contract AsyncVenueTest is Test {
    uint16 constant ASSET_IDX = 3;
    uint8 constant SIZE_DECIMALS = 4;
    uint16 constant MARKET = 16; // TSLA on the real venue
    uint256 constant IMF = 5_000; // == LighterSim.VENUE_IMF_BPS

    MockERC20 usdgSim;
    MockERC20 usdgMock;
    LighterSim sim;
    MockLighter mockL;

    address depositorA = makeAddr("depositorA");
    address stranger = makeAddr("stranger");

    function setUp() public {
        usdgSim = new MockERC20("USDG", "USDG", 6);
        usdgMock = new MockERC20("USDG", "USDG", 6);
        sim = new LighterSim(IERC20(address(usdgSim)), ASSET_IDX, SIZE_DECIMALS, IMF, address(this));
        mockL = new MockLighter(IERC20(address(usdgMock)), ASSET_IDX, SIZE_DECIMALS);

        sim.setDepositorAllowed(depositorA, true);
        sim.setMarkPrice(MARKET, 100e18);

        usdgSim.mint(depositorA, 10_000_000e6);
        vm.prank(depositorA);
        usdgSim.approve(address(sim), type(uint256).max);
    }

    /// @dev Deposit `amount` for A and settle the batch that resolves its registration, leaving A
    ///      a usable account. Every test below that is not ABOUT the registration window starts
    ///      here, which is also the sequence `docs/DEPLOYMENT-CHECKLIST.md` step 8 prescribes.
    function _registeredA(uint256 amount) internal returns (uint48 idx) {
        vm.prank(depositorA);
        sim.deposit(depositorA, ASSET_IDX, 0, amount);
        sim.settleBatch();
        idx = sim.addressToAccountIndex(depositorA);
        assertGt(idx, 0, "fixture: A did not register");
    }

    // ===================================================================================== 6b
    // Account registration must not resolve in the calling transaction.
    // =======================================================================================

    /// @notice **The window exists.** A funded account has NO index until a batch executes the
    ///         registering deposit, and `createOrder` refuses it by name until then.
    ///
    /// @dev THIS IS "the real sequencing guarantee" of `docs/DEPLOYMENT-CHECKLIST.md` step 8, and
    ///      before this task it was unreachable: `deposit` assigned the index inline, so no test
    ///      and no deployment rehearsal could ever observe the state the checklist step protects
    ///      against.
    function test_createOrderRevertsBeforeRegistrationBatch() public {
        vm.prank(depositorA);
        sim.deposit(depositorA, ASSET_IDX, 0, 1_000e6);

        // Funded, reserved, and NOT registered. All three, because the middle one is what makes
        // the third one a deferral rather than a loss.
        assertEq(usdgSim.balanceOf(address(sim)), 1_000e6, "the collateral did not land");
        assertEq(sim.accountRegistrationBatch(depositorA), 1, "no registration was queued");
        assertEq(sim.addressToAccountIndex(depositorA), 0, "the index resolved in the calling transaction");

        // The vault's own path: `lighterAccountIndex()` forwards the 0, and the venue refuses it by
        // name. This is the revert `CertVault._hedge` propagates and `_tryHedge` catches.
        vm.prank(depositorA);
        vm.expectRevert(LighterCore.AccountIsNotRegistered.selector);
        sim.createOrder(0, MARKET, 100, 10_000, 0, 1);

        // And naming the reserved index instead does not get round it: the caller does not own an
        // account it has not been registered for.
        vm.prank(depositorA);
        vm.expectRevert(LighterCore.LighterCore_AccountNotCaller.selector);
        sim.createOrder(3, MARKET, 100, 10_000, 0, 1);
    }

    /// @notice **The window closes.** One `settleBatch` resolves the index, and the account then
    ///         trades normally.
    function test_registrationResolvesAfterBatch() public {
        vm.prank(depositorA);
        sim.deposit(depositorA, ASSET_IDX, 0, 1_000e6);
        assertEq(sim.addressToAccountIndex(depositorA), 0, "registered too early");

        sim.settleBatch();

        uint48 idx = sim.addressToAccountIndex(depositorA);
        assertEq(idx, 3, "the venue's first account index is not 3");
        assertEq(sim.marginBalanceOf(idx), 1_000e6, "the deposit did not reach the resolved account");

        // Usable, not merely visible.
        vm.prank(depositorA);
        sim.createOrder(idx, MARKET, 100, 10_000, 0, 1);
        sim.settleBatch();
        assertEq(sim.positionBaseOf(idx, MARKET), 100, "the resolved account cannot trade");
    }

    /// @notice A SECOND deposit made inside the window tops up the SAME account rather than
    ///         reserving a second one.
    ///
    /// @dev The sharp edge of deferring the index. `deposit` has to decide "is this address new?"
    ///      against the RESERVATION and not against the published answer — the published answer is
    ///      still 0 inside the window, so reading it here would hand the address a second index and
    ///      orphan the first deposit's collateral in a book nothing can ever name. One line, and it
    ///      is the difference between a deferral and a silent loss of funds.
    function test_aSecondDepositInsideTheWindowTopsUpTheSameAccount() public {
        vm.startPrank(depositorA);
        sim.deposit(depositorA, ASSET_IDX, 0, 1_000e6);
        sim.deposit(depositorA, ASSET_IDX, 0, 500e6);
        vm.stopPrank();

        assertEq(sim.accountCount(), 1, "the second deposit reserved a second account");
        sim.settleBatch();

        uint48 idx = sim.addressToAccountIndex(depositorA);
        assertEq(sim.marginBalanceOf(idx), 1_500e6, "the two deposits did not land in one book");
        assertEq(sim.marginBalance(), 1_500e6, "the venue-level total lost a deposit");
    }

    /// @notice The deferral is on the SHARED CORE, so `MockLighter` has it too and the whole suite
    ///         runs against the venue's real sequencing rather than a looser one.
    ///
    /// @dev Placement matters here as much as behaviour. The asynchronous fill was always on the
    ///      core; putting asynchronous registration on `LighterSim` alone would have left 400-odd
    ///      tests certifying a venue that registers instantly against a deployment that does not —
    ///      which is the drift the `LighterCore` extraction exists to prevent.
    function test_theRegistrationDeferralIsOnTheCore() public {
        usdgMock.mint(address(this), 1_000e6);
        usdgMock.approve(address(mockL), type(uint256).max);
        mockL.deposit(stranger, ASSET_IDX, 0, 1_000e6);

        assertEq(mockL.addressToAccountIndex(stranger), 0, "the mock still registers synchronously");
        mockL.settleBatch();
        assertGt(mockL.addressToAccountIndex(stranger), 0, "the mock never resolves the registration");
    }

    /// @notice The registering deposit announces the batch that will resolve it, so an indexer can
    ///         reconstruct the window from logs alone.
    /// @dev There is deliberately no second event at resolution — nothing happens in that
    ///      transaction beyond the batch itself, so a consumer joins this against
    ///      `BatchSettled(batchId)` for `batchId >= resolvesAtBatch`. Asserted here at a non-zero
    ///      clock so the field cannot be passing by coincidence with a hardcoded 1.
    function test_registrationAnnouncesTheBatchThatResolvesIt() public {
        sim.settleBatch();
        sim.settleBatch();
        assertEq(sim.batchesSettled(), 2, "the clock did not advance");

        vm.expectEmit(true, true, true, true, address(sim));
        emit LighterCore.AccountRegistered(depositorA, 3, 3);
        vm.prank(depositorA);
        sim.deposit(depositorA, ASSET_IDX, 0, 1_000e6);

        assertEq(sim.addressToAccountIndex(depositorA), 0, "resolved before batch 3");
        sim.settleBatch();
        assertEq(sim.addressToAccountIndex(depositorA), 3, "batch 3 did not resolve it");
    }

    // ===================================================================================== 6a
    // `withdraw` must not credit in the calling transaction.
    // =======================================================================================

    /// @notice **The pending balance stays 0 until a batch executes the request.**
    ///
    /// @dev The whole of 6a in four assertions. Before this task the credit landed in the
    ///      `withdraw` transaction, so `CertVault._sweepPending` always found the money there and
    ///      its "the money may simply never come" branch was dead code on every testnet rehearsal.
    function test_withdrawCreditsOnlyAfterBatch() public {
        uint48 idx = _registeredA(1_000e6);

        vm.prank(depositorA);
        sim.withdraw(idx, ASSET_IDX, 0, 400e6);

        // Accepted — and that is ALL that happened. No credit, and no book moved.
        assertEq(sim.withdrawQueueLength(), 1, "the request was not enqueued");
        assertEq(sim.getPendingBalance(depositorA, ASSET_IDX), 0, "credited in the calling transaction");
        assertEq(sim.pendingTotal(), 0, "the venue's outstanding promise moved before settlement");
        assertEq(sim.marginBalanceOf(idx), 1_000e6, "margin was debited before settlement");

        sim.settleBatch();

        assertEq(sim.getPendingBalance(depositorA, ASSET_IDX), 400e6, "the batch did not credit");
        assertEq(sim.marginBalanceOf(idx), 600e6, "the batch did not debit the margin");
        assertEq(sim.withdrawQueueLength(), 0, "the executed request stayed in the queue");
        assertEq(sim.queuedWithdrawalsOf(idx), 0, "the executed request still counts against its account");

        // And only then do tokens actually move.
        vm.prank(depositorA);
        sim.withdrawPendingBalance(depositorA, ASSET_IDX, 400e6);
        assertEq(usdgSim.balanceOf(depositorA), 10_000_000e6 - 1_000e6 + 400e6, "the drain did not pay");
    }

    /// @notice **The mainnet behaviour that matters most, and the one the mock was hiding.** A
    ///         withdrawal the venue cannot fund at all does NOT revert at request time, credits
    ///         NOTHING after the batch, and announces the rejection.
    ///
    /// @dev This is the state that is invisible on the real venue: `withdraw` returns success, the
    ///      rollup refuses the request internally, and on-chain "paid nothing" is indistinguishable
    ///      from "paid in full". `WithdrawalSilentlyRejected` is the simulator showing an operator
    ///      what mainnet would hide, and it is why the event is separate from
    ///      `WithdrawalCredited` — so it can be filtered on alone.
    function test_unfulfillableWithdrawIsConsumedSilently() public {
        uint48 idx = _registeredA(1_000e6);

        // Empty the account first, so the second request has no equity at all behind it.
        vm.prank(depositorA);
        sim.withdraw(idx, ASSET_IDX, 0, 1_000e6);
        sim.settleBatch();
        assertEq(sim.equity(idx), 0, "fixture: the account still has equity");

        // NO REVERT at request time. The real venue does not check, so neither may this one.
        vm.prank(depositorA);
        sim.withdraw(idx, ASSET_IDX, 0, 500e6);
        assertEq(sim.withdrawQueueLength(), 1, "the unfulfillable request was refused at request time");

        // The batch consumes it, credits nothing, and says so.
        vm.expectEmit(true, true, true, true, address(sim));
        emit LighterCore.WithdrawalSilentlyRejected(depositorA, idx, ASSET_IDX, 500e6, 0, 500e6);
        sim.settleBatch();

        assertEq(sim.getPendingBalance(depositorA, ASSET_IDX), 1_000e6, "the empty request credited something");
        assertEq(sim.marginBalanceOf(idx), 0, "the empty request moved the margin book");
        assertEq(sim.withdrawQueueLength(), 0, "the consumed request stayed in the queue");
        assertEq(sim.queuedWithdrawalsOf(idx), 0, "a consumed request still counts against its account");
    }

    /// @notice **THE PROPERTY `CertVault.recallMargin` DEPENDS ON, with the C1 audit's own
    ///         numbers.** A request larger than the account's equity is PARTIALLY fulfilled:
    ///         `min(request, available)` is credited and the shortfall is announced.
    ///
    /// @dev THE CORRECTION THIS TASK EXISTS UNDER. `recallMargin` asks the venue for what the vault
    ///      OWES, not what it deposited — that is the C1 audit fix — and it is safe only because
    ///      the venue fulfils `min(request, available)` and `_sweepPending` reconciles whatever
    ///      arrives. The figures below are the ones measured at that audit: a receipt owed 7,102.97
    ///      while everything recallable totalled 3,559.54. Make withdrawals all-or-nothing and that
    ///      receipt becomes unpayable, which is the sharpest Law 2 breach the audit found.
    ///
    ///      So this is not a "nice to have" assertion, it is the negative control on the fix:
    ///      partial fulfilment and the fail-closed refusal are two different decisions for two
    ///      different causes, and conflating them reintroduces a Critical.
    function test_partialFulfilmentStillPartiallyFulfilsWithTheAuditsOwnNumbers() public {
        uint256 recallable = 3_559.54e6; // everything the vault could actually get back
        uint256 owed = 7_102.97e6; // what the receipt was owed, and therefore what it asks for
        uint48 idx = _registeredA(recallable);

        assertEq(sim.equity(idx), recallable, "fixture: available is not the audit's figure");

        vm.prank(depositorA);
        sim.withdraw(idx, ASSET_IDX, 0, uint64(owed));

        vm.expectEmit(true, true, true, true, address(sim));
        emit LighterCore.WithdrawalCredited(depositorA, idx, ASSET_IDX, uint64(owed), recallable, recallable, 2);
        vm.expectEmit(true, true, true, true, address(sim));
        emit LighterCore.WithdrawalSilentlyRejected(
            depositorA, idx, ASSET_IDX, uint64(owed), recallable, owed - recallable
        );
        sim.settleBatch();

        // min(request, available), to the unit, with real numbers.
        assertEq(sim.getPendingBalance(depositorA, ASSET_IDX), recallable, "partial fulfilment was lost");
        assertEq(sim.getPendingBalance(depositorA, ASSET_IDX), owed < recallable ? owed : recallable, "not min()");
        assertEq(sim.marginBalanceOf(idx), 0, "the fulfilled part was not debited");

        // And it is genuinely payable, which is the half that makes the receipt claimable at all.
        vm.prank(depositorA);
        sim.withdrawPendingBalance(depositorA, ASSET_IDX, uint128(recallable));
        assertEq(sim.getPendingBalance(depositorA, ASSET_IDX), 0, "the partial credit could not be drained");
    }

    /// @notice **FINDING I2, AND THE ONE CASE THAT FAILS CLOSED.** A credit the simulator's own
    ///         token balance cannot back is refused WHOLE: `marginBalanceOf`, `entryPriceOf` and
    ///         `pendingTotal()` are ALL unchanged.
    ///
    /// @dev Not a partial fill — a bookkeeping half-application, which is a different defect with a
    ///      different fix. Before this task `withdraw` SUCCEEDED here: it debited `marginBalance`,
    ///      rewrote `entryPrice` through `_realiseGain`, bumped `_pendingTotal`, and only the LATER
    ///      `withdrawPendingBalance` reverted on the token transfer — leaving a permanently
    ///      unsweepable pending credit against books that had already moved. On testnet that
    ///      presents as a vault wedged in `_sweepPending` forever, which is a genuinely confusing
    ///      thing to debug.
    ///
    ///      The state is reachable because equity includes UNREALISED GAIN, which no token backs:
    ///      on the real venue those tokens are the losing counterparty's collateral, and
    ///      `LighterSim` has no counterparty and — deliberately — no `_fundPending` override to
    ///      mint them with.
    function test_anUnfundableWithdrawalIsRefusedWholeAndMutatesNothing() public {
        uint48 idx = _registeredA(1_000e6);

        // Long 10 units at a mark of 100e18: $1000 notional against $1000 of cash, so it clears the
        // 50% initial margin the venue requires.
        vm.prank(depositorA);
        sim.createOrder(idx, MARKET, 100_000, 10_000, 0, 1);
        sim.settleBatch();
        assertEq(sim.positionBaseOf(idx, MARKET), 100_000, "fixture: the hedge did not open");
        assertEq(sim.entryPriceOf(idx, MARKET), 100e18, "fixture: entry price not recorded");

        // Mark triples: $2000 of unrealised gain on top of $1000 of cash.
        sim.setMarkPrice(MARKET, 300e18);
        assertEq(sim.equity(idx), 3_000e6, "fixture: equity is not cash + gain");
        assertEq(usdgSim.balanceOf(address(sim)), 1_000e6, "fixture: the venue holds more than the deposit");

        vm.prank(depositorA);
        sim.withdraw(idx, ASSET_IDX, 0, 3_000e6);

        // Inside equity, so partial fulfilment would have credited the whole 3_000e6 — and the
        // venue cannot back it. Refused whole, on the record, naming what it would have credited.
        vm.expectEmit(true, true, true, true, address(sim));
        emit LighterCore.WithdrawalUnfundable(depositorA, idx, ASSET_IDX, 3_000e6, 3_000e6, 3);
        sim.settleBatch();

        // ALL THREE unchanged. This is the assertion the amendment asks for.
        assertEq(sim.marginBalanceOf(idx), 1_000e6, "margin was debited by a refused withdrawal");
        assertEq(sim.entryPriceOf(idx, MARKET), 100e18, "entryPrice was rewritten by a refused withdrawal");
        assertEq(sim.pendingTotal(), 0, "the pending total was bumped by a refused withdrawal");
        assertEq(sim.getPendingBalance(depositorA, ASSET_IDX), 0, "a refused withdrawal credited something");
        assertEq(sim.positionBaseOf(idx, MARKET), 100_000, "the position moved");

        // The invariant that makes the refusal worth having: everything promised is backed, so
        // `withdrawPendingBalance` cannot revert on its transfer.
        assertGe(usdgSim.balanceOf(address(sim)), sim.pendingTotal(), "a pending credit is unbacked");
    }

    /// @notice The refusal is a REFUSAL, not a brick: the same account's fundable withdrawal still
    ///         goes through, and a retry after the venue is funded goes through too.
    ///
    /// @dev A fail-closed check that also closed the happy path would be a different outage, not a
    ///      fix. Both halves matter: the amount the venue CAN pay is paid, and the amount it could
    ///      not becomes payable once the tokens exist — so the refusal strands nothing permanently.
    function test_theUnfundableRefusalIsNotABrick() public {
        uint48 idx = _registeredA(1_000e6);
        vm.prank(depositorA);
        sim.createOrder(idx, MARKET, 100_000, 10_000, 0, 1);
        sim.settleBatch();
        sim.setMarkPrice(MARKET, 300e18);

        // The cash half alone is fully backed and pays.
        vm.prank(depositorA);
        sim.withdraw(idx, ASSET_IDX, 0, 1_000e6);
        sim.settleBatch();
        assertEq(sim.getPendingBalance(depositorA, ASSET_IDX), 1_000e6, "the fundable half did not pay");

        // The gain half is not backed and is refused...
        vm.prank(depositorA);
        sim.withdraw(idx, ASSET_IDX, 0, 2_000e6);
        sim.settleBatch();
        assertEq(sim.getPendingBalance(depositorA, ASSET_IDX), 1_000e6, "the unbacked half credited anyway");

        // ...until the counterparty's collateral actually arrives, at which point a retry works.
        // On the real venue this is the losing side's margin being settled in; here it is the only
        // honest way to produce it, because `LighterSim` must not be able to mint it itself.
        usdgSim.mint(address(sim), 2_000e6);
        vm.prank(depositorA);
        sim.withdraw(idx, ASSET_IDX, 0, 2_000e6);
        sim.settleBatch();
        assertEq(sim.getPendingBalance(depositorA, ASSET_IDX), 3_000e6, "the retry did not pay once funded");
    }

    /// @notice `MockLighter` still honours a gain-drawing withdrawal, because its `_fundPending`
    ///         override mints the counterparty's side — and that divergence is now VISIBLE rather
    ///         than latent.
    ///
    /// @dev The same request, on the two front ends, with opposite outcomes and both correct. The
    ///      mock is a one-account venue with no losing counterparty, so without the mint a
    ///      genuinely payable receipt would fail on the mock's own token balance rather than on
    ///      anything the contract under test did. `LighterSim` has no such override on purpose:
    ///      a simulator that could mint its counterparty's money would be easier than mainnet.
    function test_theMockStillFundsAGainDrawingWithdrawalAndTheSimDoesNot() public {
        usdgMock.mint(address(this), 1_000e6);
        usdgMock.approve(address(mockL), type(uint256).max);
        mockL.setMarkPrice(MARKET, 100e18);
        mockL.deposit(address(this), ASSET_IDX, 0, 1_000e6);
        mockL.settleBatch();

        uint48 idx = mockL.addressToAccountIndex(address(this));
        mockL.createOrder(idx, MARKET, 100_000, 10_000, 0, 1);
        mockL.settleBatch();
        mockL.setMarkPrice(MARKET, 300e18);
        assertEq(mockL.equity(idx), 3_000e6, "fixture: the mock's equity is not cash + gain");

        mockL.withdraw(idx, ASSET_IDX, 0, 3_000e6);
        mockL.settleBatch();

        assertEq(mockL.getPendingBalance(address(this), ASSET_IDX), 3_000e6, "the mock stopped funding the gain");
        assertGe(usdgMock.balanceOf(address(mockL)), mockL.pendingTotal(), "the mock left a credit unbacked");
    }

    /// @notice A withdrawal request is validated at request time for exactly the four things the
    ///         real contract validates, and the CEILING IS NOT ONE OF THEM.
    ///
    /// @dev The negative control on 6a's shape. If any of these moved to settlement the venue would
    ///      be easier than mainnet; if the ceiling joined them the venue would be HARDER in the one
    ///      way Law 2 cannot survive. `type(uint64).max` is asked for and accepted here on purpose.
    function test_theRequestTimeValidationsAreTheVenuesFourAndNotTheCeiling() public {
        uint48 idx = _registeredA(1_000e6);

        vm.prank(depositorA);
        vm.expectRevert(LighterCore.AccountIsNotRegistered.selector);
        sim.withdraw(0, ASSET_IDX, 0, 1e6);

        vm.prank(stranger);
        vm.expectRevert(LighterCore.LighterCore_AccountNotCaller.selector);
        sim.withdraw(idx, ASSET_IDX, 0, 1e6);

        vm.prank(depositorA);
        vm.expectRevert(LighterCore.ZeroBaseAmount.selector);
        sim.withdraw(idx, ASSET_IDX, 0, 0);

        sim.setDepositCapTicks(500e6);
        vm.prank(depositorA);
        vm.expectRevert(LighterCore.AboveDepositCap.selector);
        sim.withdraw(idx, ASSET_IDX, 0, 500e6 + 1);
        sim.setDepositCapTicks(type(uint64).max);

        // And an absurd over-request is ACCEPTED, because that is what `recallMargin` does.
        vm.prank(depositorA);
        sim.withdraw(idx, ASSET_IDX, 0, type(uint64).max);
        assertEq(sim.withdrawQueueLength(), 1, "the over-request was refused at request time");
    }

    /// @notice The withdrawal queue is bounded per account, which is what keeps the settlement walk
    ///         affordable when the requesting entry point is permissionless.
    ///
    /// @dev `CertVault.recallMargin()` is permissionless by Law 6, so anyone may submit a
    ///      withdrawal request on the vault's behalf as often as they like. Unbounded, that would
    ///      make `settleBatch`'s cost a stranger's choice on the one function the testnet's
    ///      liveness runs through. The refusal is a NAMED error, not a panic, because
    ///      `_requestWithdraw` swallows it in a `catch` and the log is the only diagnostic left.
    function test_theWithdrawalQueueIsBoundedPerAccount() public {
        uint48 idx = _registeredA(1_000e6);
        uint256 cap = sim.MAX_ORDERS_PER_ACCOUNT();

        vm.startPrank(depositorA);
        for (uint256 i = 0; i < cap; ++i) {
            sim.withdraw(idx, ASSET_IDX, 0, 1e6);
        }
        vm.expectRevert(LighterCore.LighterCore_AccountWithdrawCapReached.selector);
        sim.withdraw(idx, ASSET_IDX, 0, 1e6);
        vm.stopPrank();

        assertEq(sim.queuedWithdrawalsOf(idx), cap, "the counter does not track the queue");
    }

    /// @notice A batch drains at most `SETTLE_BATCH_MAX` withdrawal requests, on its own cursor,
    ///         and repeated calls finish the job.
    /// @dev The same windowing the order queue has, and for the same reason: a long queue must be
    ///      drained by repeated calls rather than by one transaction that may not fit in a block.
    ///      The two cursors are independent, which is why they cannot be one field.
    function test_withdrawalSettlementIsWindowedOnItsOwnCursor() public {
        uint48 idx = _registeredA(1_000e6);
        uint256 window = sim.SETTLE_BATCH_MAX();

        vm.startPrank(depositorA);
        for (uint256 i = 0; i < window + 5; ++i) {
            sim.withdraw(idx, ASSET_IDX, 0, 1e6);
        }
        vm.stopPrank();

        sim.settleBatch();
        assertEq(sim.withdrawCursor(), window, "the first batch did not stop at the window");
        assertEq(sim.getPendingBalance(depositorA, ASSET_IDX), window * 1e6, "the window credited the wrong amount");

        sim.settleBatch();
        assertEq(sim.withdrawCursor(), 0, "the second batch did not drain the queue");
        assertEq(sim.withdrawQueueLength(), 0, "the drained queue was not cleared");
        assertEq(sim.getPendingBalance(depositorA, ASSET_IDX), (window + 5) * 1e6, "the tail was not credited");
    }

    /// @notice The enqueue and the credit are two separate events, joinable by a monotonic request
    ///         id, and the enqueue carries no credited amount because nothing was credited.
    function test_theEnqueueAndTheCreditAreSeparateEvents() public {
        uint48 idx = _registeredA(1_000e6);

        vm.expectEmit(true, true, true, true, address(sim));
        emit LighterCore.WithdrawalRequested(depositorA, idx, ASSET_IDX, 400e6, 1, 0);
        vm.prank(depositorA);
        sim.withdraw(idx, ASSET_IDX, 0, 400e6);

        vm.expectEmit(true, true, true, true, address(sim));
        emit LighterCore.WithdrawalCredited(depositorA, idx, ASSET_IDX, 400e6, 400e6, 400e6, 2);
        vm.expectEmit(true, true, true, true, address(sim));
        emit LighterCore.WithdrawalsSettled(2, 0, 1, 1, 0, true);
        sim.settleBatch();
    }
}

/// @notice TASK 6's ACCEPTANCE TEST: the bootstrap sequence of
///         `docs/DEPLOYMENT-CHECKLIST.md` step 8, mirrored against a REAL `CertVault` on a REAL
///         `LighterSim`.
///
/// @dev Deliberately a separate fixture from every other vault test in the repo, and the
///      difference is one line: `test/helpers/VaultFixture.sol` and
///      `test/sim/DepositCapMintPause.t.sol` both call `settleBatch()` immediately after
///      `bootstrap()` — which is correct, and is exactly the sequence the checklist prescribes —
///      so neither can ever observe the window BETWEEN the two. This fixture stops after
///      `bootstrap()` on purpose, because the window is the thing under test.
///
///      Before Task 6 that window did not exist, so a deploy script validated against the
///      simulator had never once exercised the guarantee its own step 8 is about.
contract AsyncVenueVaultTest is Test {
    uint16 constant ASSET_IDX = 3;
    uint8 constant SIZE_DECIMALS = 4;
    uint16 constant MARKET = 16;
    uint256 constant PX = 355.86e18;
    uint256 constant SETTLE_WINDOW = 1 days;
    uint256 constant MAX_ABSOLUTE_CAP = 1_000_000_000e18;
    uint256 constant SIM_IMF = 5_000;
    uint256 constant MINT_IN = 3_558.6e6;

    TestUSDG usdg;
    MockAggregatorV3 feed;
    LighterSim sim;
    SolvencyRegistry reg;
    CapacityOracle cap;
    CertOracle oracle;
    CertVault vault;
    Certificate cert;

    address attester = makeAddr("attester");
    address gov = makeAddr("gov");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_800_000_000);
        usdg = new TestUSDG(address(this));
        feed = new MockAggregatorV3(8, 355_86000000);
        sim = new LighterSim(IERC20(address(usdg)), ASSET_IDX, SIZE_DECIMALS, SIM_IMF, address(this));
        reg = new SolvencyRegistry(attester);
        cap = new CapacityOracle(address(reg), gov, 1000, 100, 3000, 300, MAX_ABSOLUTE_CAP);
        oracle = new CertOracle(address(feed), attester, 2, 3600, 500, 100, 3600, false);

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
                instantCap18: 10_000e18,
                settleBandBps: 500,
                targetMarginBps: 9_000
            }),
            type(uint64).max,
            SETTLE_WINDOW,
            "UseCert TSLA",
            "uTSLA"
        );
        cert = Certificate(vault.certificate());

        vm.prank(gov);
        cap.setAbsoluteCap(address(vault), 5_000_000e18);
        vm.startPrank(attester);
        oracle.setMarkPrice(PX);
        reg.attest(address(vault), 1, 0, 0, 1_190_000e18);
        vm.stopPrank();

        sim.setMarkPrice(MARKET, PX);
        sim.setDepositorAllowed(address(vault), true);

        usdg.mint(alice, 1_000_000e6);
        usdg.mint(address(this), 1_000_000e6);
        usdg.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        usdg.approve(address(vault), type(uint256).max);

        // Checklist step 8, first half: the vault must hold collateral before it can bootstrap.
        // NOTE: NO `settleBatch()` here. That is the point of this fixture.
        vault.seedBuffer(100_000e6);
    }

    /// @notice **THE ACCEPTANCE MIRROR.** Transfer collateral, `bootstrap()`, a mint reverts
    ///         ATOMICALLY, `settleBatch()`, the same mint then succeeds.
    ///
    /// @dev "Atomically" is the load-bearing word and it gets its own assertions. `CertVault._hedge`
    ///      is the REVERT-CAPABLE hedge path — mint and rebalance use it deliberately, because an
    ///      unhedged mint must not pass silently (Law 1) — and it reads `lighterAccountIndex()`
    ///      UNGUARDED. Inside the registration window that read returns 0, `createOrder` refuses
    ///      it by name, and the whole mint transaction unwinds: no certificates issued, no
    ///      collateral taken, no margin posted, no half-hedged position left behind. A vault that
    ///      minted-then-failed-to-hedge here would be the Law 1 breach the fail-open `_tryHedge`
    ///      exists to keep OUT of the mint path.
    function test_vaultBootstrapSequenceMatchesChecklistStep8() public {
        vault.bootstrap();

        // The window: bootstrapped, funded, and not yet registered.
        assertTrue(vault.bootstrapped(), "bootstrap did not take");
        assertEq(sim.accountRegistrationBatch(address(vault)), 1, "the registering deposit was not queued");
        assertEq(vault.lighterAccountIndex(), 0, "the index resolved in the bootstrap transaction");

        uint256 aliceBefore = usdg.balanceOf(alice);
        uint256 supplyBefore = cert.totalSupply();
        uint256 postedBefore = vault.postedMargin();

        // The mint reverts, by name, and unwinds completely.
        vm.prank(alice);
        vm.expectRevert(LighterCore.AccountIsNotRegistered.selector);
        vault.mintInstant(MINT_IN);

        assertEq(usdg.balanceOf(alice), aliceBefore, "a reverted mint still took collateral");
        assertEq(cert.totalSupply(), supplyBefore, "a reverted mint still issued certificates");
        assertEq(vault.postedMargin(), postedBefore, "a reverted mint still posted margin");
        assertEq(sim.positionBase(MARKET), 0, "a reverted mint left a position at the venue");

        // "The real sequencing guarantee": one batch, and the window closes.
        sim.settleBatch();
        assertGt(vault.lighterAccountIndex(), 0, "the batch did not resolve the registration");

        vm.prank(alice);
        vault.mintInstant(MINT_IN);
        sim.settleBatch();

        uint256 minted = cert.balanceOf(alice);
        assertApproxEqRel(minted, 9.99e18, 0.002e18, "the mint after the batch is off by more than the fee");
        assertGt(sim.positionBaseOf(vault.lighterAccountIndex(), MARKET), 0, "the mint after the batch never hedged");
    }

    /// @notice **6a's consequence for the vault: submission is not arrival.**
    ///         `recallMargin()` now genuinely leaves nothing pending until a batch runs, so
    ///         `_sweepPending`'s "the money may simply never come" path is finally reachable.
    ///
    /// @dev The reason 6a matters to `CertVault` rather than only to the simulator. `recallMargin`
    ///      reduces `marginPendingRecall` ONLY by what `getPendingBalance` proves arrived, and that
    ///      two-phase shape was written against a venue whose credit is asynchronous. Against a
    ///      synchronously-crediting mock the second phase always found the money already there, so
    ///      the branch that handles a venue paying nothing was dead code on every rehearsal.
    function test_recallMarginSubmissionIsNotArrivalAcrossTheBatchBoundary() public {
        vault.bootstrap();
        sim.settleBatch();

        vm.prank(alice);
        vault.mintInstant(MINT_IN);
        sim.settleBatch();

        // A redemption allocates an obligation the venue has to fund.
        uint256 minted = cert.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(minted);
        assertGt(vault.marginPendingRecall(), 0, "fixture: nothing was allocated for recall");

        uint256 owedBefore = vault.marginPendingRecall();
        vault.recallMargin();

        // SUBMITTED, and nothing more: the request is queued at the venue and the vault's counter
        // is untouched, because no cash has arrived to reconcile against.
        assertEq(sim.withdrawQueueLength(), 1, "recallMargin did not submit a request");
        assertEq(sim.getPendingBalance(address(vault), ASSET_IDX), 0, "the venue credited synchronously");
        assertEq(vault.marginPendingRecall(), owedBefore, "the counter fell before any cash arrived");

        // The batch executes it; the next permissionless call sweeps and reconciles.
        sim.settleBatch();
        assertGt(sim.getPendingBalance(address(vault), ASSET_IDX), 0, "the batch credited nothing");

        vault.recallMargin();
        assertLt(vault.marginPendingRecall(), owedBefore, "the sweep did not reconcile what arrived");
    }

    /// @notice **A FINDING, PINNED RATHER THAN DESCRIBED.** `recallMargin`'s `marginExcess` path —
    ///         the M-4 fix — was documented as reaching the freed margin in ONE permissionless
    ///         call. Against an asynchronous venue it cannot, and it never could have on mainnet.
    ///         It now takes two calls with a batch between them, and it still takes nothing else:
    ///         no owner, no keeper, no certificate and no receipt.
    ///
    /// @dev WHY THIS IS A FINDING AND NOT A REGRESSION. `recallMargin` deliberately sweeps
    ///      `marginExcess` in the SAME call that requests it, and its comment gives the reason:
    ///      unlike allocated recall, the exit that freed this margin was already paid out of the
    ///      float, so there is no claim to keep the counter alive for. That reasoning is still
    ///      sound. What was NOT sound is the conclusion drawn from it — "reachable in ONE
    ///      permissionless call" — because it depended on the venue crediting inside `withdraw`,
    ///      which the real `AdditionalZkLighter` does not do. The old simulator credited
    ///      synchronously, so the same-call sweep always worked here and the claim was never
    ///      tested against venue behaviour.
    ///
    ///      DESIGN LAW 2 IS NOT AT RISK, and that is the important half. The margin is still
    ///      recallable, still by anyone, and still without a queued receipt — which is exactly the
    ///      property `test_A5_recallMarginCannotRefillTheBufferAfterInstantRedeems` in the frozen
    ///      `test/AuditPoC.t.sol` asserts. It costs one more permissionless call and one keeper
    ///      batch, both of which any address can wait for. `test/sim/AsyncVenue.t.sol` pins it
    ///      here so the property has coverage that is not in a frozen file.
    ///
    ///      REPORTED, NOT FIXED: no change is made to `src/CertVault.sol`. The single-call claim in
    ///      `recallMargin`'s comment is now inaccurate against a faithful venue and is worth
    ///      correcting, but the code is not wrong — it is one call slower than its own NatSpec
    ///      says, on a path that is retryable by construction.
    function test_marginExcessIsStillRecallableWithoutAReceiptAcrossABatch() public {
        vault.bootstrap();
        sim.settleBatch();

        vm.prank(alice);
        vault.mintInstant(MINT_IN);
        sim.settleBatch();

        // An INSTANT redemption frees margin into `marginExcess` and allocates nothing for recall:
        // the holder was already paid, in full, out of the float.
        uint256 minted = cert.balanceOf(alice);
        vm.prank(alice);
        vault.redeemInstant(minted);
        sim.settleBatch(); // the closing hedge fills, releasing the initial-margin requirement

        assertGt(vault.marginExcess(), 0, "an instant redemption freed no margin");
        assertEq(vault.marginPendingRecall(), 0, "an instant redemption allocated a recall");
        assertEq(vault.totalOwedOutstanding(), 0, "an instant redemption left an obligation");

        // ONE call is no longer enough, and this is the finding.
        address nobody = makeAddr("nobody");
        assertEq(cert.balanceOf(nobody), 0, "the fixture's caller holds a claim");
        uint256 bufferBefore = vault.hotBuffer();
        vm.prank(nobody);
        vault.recallMargin();
        assertEq(vault.hotBuffer(), bufferBefore, "the venue credited inside withdraw after all");
        assertEq(sim.withdrawQueueLength(), 1, "no request was submitted");

        // TWO calls with a batch between them still are, and still from an address holding nothing.
        sim.settleBatch();
        vm.prank(nobody);
        vault.recallMargin();
        assertGt(vault.hotBuffer(), bufferBefore, "the freed margin never came home");
        assertEq(vault.marginExcess(), 0, "the excess counter was not cleared by the sweep");
    }
}
