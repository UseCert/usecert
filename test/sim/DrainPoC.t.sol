// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LighterCore} from "../../src/sim/LighterCore.sol";
import {LighterSim} from "../../src/sim/LighterSim.sol";
import {MockLighter} from "../mocks/MockLighter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice FROZEN AUDIT EVIDENCE. The reproductions of every drain and denial-of-service this
///         simulator has actually had, kept in-tree as permanent regression tests rather than
///         described in a report. Same convention, and same reason, as `test/AuditPoC.t.sol`:
///         evidence that a hole is closed should be code that fails if it reopens.
///
///         Unlike `test/AuditPoC.t.sol`, these are expected to PASS. They are written in the
///         defender's favour — each one pins the revert that closes the attack and asserts the
///         simulator's collateral did not move. A failure here is a reopened Critical.
///
/// @dev Three rounds of the same underlying defect, which is worth keeping visible in one file
///      because each round's fix was faithful to its brief and still insufficient:
///
///      * TASK 4 (deployment): `withdraw` gated only on `accountIndex != 0` and never bound
///        `msg.sender`. An unregistered address named a literal index and took every depositor's
///        collateral in two transactions. Closed by Task 5's caller binding.
///      * FIX ROUND 1, CRITICAL 1: registering was FREE — `deposit(self, _, _, 0)` is a zero-value
///        `transferFrom`, which OpenZeppelin permits with no allowance and no balance, and it ran
///        the registration branch. So the attacker registered first and the caller binding was
///        then SATISFIED. Same end state, three transactions. Closed here by two independent
///        gates: an owner registration allowlist on `LighterSim`, and a zero-amount refusal on
///        `LighterCore`.
///      * FIX ROUND 1, CRITICAL 2: the liveness regression the caller binding INTRODUCED. Once
///        only an order's own account could cancel it, and `settleBatch` reverted as a whole, one
///        unsettleable order killed settlement for everyone with no operator recourse. Closed here
///        by an owner escape hatch — interim, superseded below.
///
///      The common cause of all three is that `marginBalance` and `positionBase` are GLOBAL, so
///      any account's actions reach every other account's money. Every fix in this file is an
///      interim that narrows who can act rather than what an actor can reach. TASK 7 shipped the
///      real fix — per-account collateral isolation, plus a `settleBatch` that rejects one order
///      instead of the batch.
///
///      RE-POINTED 2026-09-09: Task 7's `settleBatch` change means the Critical-2 jam this file
///      demonstrated can no longer form — the poison order is rejected on its own turn and the
///      batch completes, so `test_C2_ownerHatchClearsAJammedQueue`'s premise (four reverting
///      `settleBatch()` calls, cleared only by the owner hatch) went obsolete: see
///      `.superpowers/sdd/2026-09-09-usecert-testnet-execution/task-7-report.md` §7, which reports
///      the failure and recommends this re-point rather than applying it itself, per that task's
///      own brief to leave this frozen file alone. That test is now
///      `test_C2_poisonOrderIsRejectedAndSettlementSurvives`: same setup, same two accounts, but it
///      asserts the new answer to the same question — does one account's bad order stop everyone
///      else's settlement, and is there any way out — with real values (the poison order rejected
///      by name, the honest hedge filled at its full size, the queue fully drained) rather than an
///      absence-of-revert check. The hatch itself is unweakened and still covered: it is no longer
///      needed for AN INSUFFICIENT-MARGIN jam, but `test_C2_ownerHatchClearsAMarklessMarketJam`
///      already pins it for the jam that is still whole-batch by design (an unset mark price, §6 of
///      the same report), and `test_C2_theHatchIsScopedToTheNamedAccount`,
///      `test_C2_ownerPurgeQueueDropsEverything`, `test_C2_theHatchIsOwnerOnly`, and
///      `test_C2_theHatchIsOnTheDeployableFrontEndOnly` are untouched. The remaining 14 tests in
///      this file, including both Critical 1 gates, are untouched. The attack stays a valid
///      question even after the answer changed — this is that re-point, not a deletion.
contract DrainPoCTest is Test {
    uint16 constant ASSET_IDX = 3;
    uint8 constant SIZE_DECIMALS = 4;
    uint16 constant MARKET = 16; // TSLA on the real venue
    uint16 constant MARKET_NO_MARK = 26; // SPY on the real venue, deliberately left markless
    uint256 constant IMF = 5_000;

    MockERC20 usdgSim;
    MockERC20 usdgMock;
    LighterSim sim;
    /// @dev Only for the two front-end-placement probes at the end of each section: the
    ///      simulator-only restrictions must NOT have leaked onto the suite's front end.
    MockLighter mockL;

    address stranger = address(0xBAD);
    address depositorA = address(0xA11CE);
    address depositorB = address(0xB0B);

    function setUp() public {
        usdgSim = new MockERC20("USDG", "USDG", 6);
        usdgMock = new MockERC20("USDG", "USDG", 6);
        sim = new LighterSim(IERC20(address(usdgSim)), ASSET_IDX, SIZE_DECIMALS, IMF, address(this));
        mockL = new MockLighter(IERC20(address(usdgMock)), ASSET_IDX, SIZE_DECIMALS);

        // The operator approves the two legitimate depositors and only those two. On the
        // single-vault deployment Task 9 performs, this set is `{vault}` — which is what reduces
        // the reachable account set to one.
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

        assertEq(usdgSim.balanceOf(address(sim)), 1_000_000e6, "fixture");
    }

    // ------------------------------------------------------------------------- CRITICAL 1
    // Fix round 1: the drain, reached by registering first.
    // ---------------------------------------------------------------------------------------

    /// @notice THE FIX-ROUND-1 CRITICAL 1 PROOF. The attack in full: self-register with a
    ///         zero-value deposit, then withdraw against the GLOBAL `equity()`.
    ///
    ///         Before the fix this passed with the assertions written the other way round —
    ///         `balanceOf(stranger) == 1_000_000e6` and `balanceOf(sim) == 0`. It now stops at the
    ///         first step.
    function test_C1_selfRegistrationDrainIsRefusedAtRegistration() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LighterSim.LighterSim_DepositorNotAllowed.selector, stranger));
        sim.deposit(stranger, ASSET_IDX, 0, 0);

        // No index, so the caller binding also still holds behind the allowlist.
        assertEq(sim.addressToAccountIndex(stranger), 0, "stranger registered anyway");
        vm.prank(stranger);
        vm.expectRevert(LighterCore.LighterCore_AccountNotCaller.selector);
        sim.withdraw(5, ASSET_IDX, 0, type(uint64).max);

        _assertNothingMoved();
    }

    /// @notice The SECOND, INDEPENDENT gate on the same attack, pinned separately on purpose.
    ///
    ///         The allowlist is a `LighterSim` deployment-shape mitigation that Task 7 deletes; the
    ///         zero-amount refusal is venue mechanics on `LighterCore` that outlives it. So the
    ///         mechanism that made registration FREE is proved closed here with the attacker
    ///         explicitly allowlisted — i.e. with the first gate deliberately opened.
    function test_C1_freeRegistrationIsRefusedEvenForAnAllowlistedAttacker() public {
        sim.setDepositorAllowed(stranger, true);

        vm.prank(stranger);
        vm.expectRevert(LighterCore.LighterCore_ZeroDepositAmount.selector);
        sim.deposit(stranger, ASSET_IDX, 0, 0);

        assertEq(sim.addressToAccountIndex(stranger), 0, "a zero deposit still registered");
        _assertNothingMoved();
    }

    /// @notice And the refusal is on the core, so `MockLighter` inherits it. A free registration is
    ///         not venue behaviour worth modelling on either front end.
    function test_C1_theZeroAmountRefusalIsOnTheCore() public {
        vm.prank(stranger);
        vm.expectRevert(LighterCore.LighterCore_ZeroDepositAmount.selector);
        sim.deposit(depositorA, ASSET_IDX, 0, 0); // allowlisted `to`, so only the amount can refuse
    }

    /// @notice The TASK 4 drain, kept for the record: an UNREGISTERED stranger naming a literal
    ///         index. Closed by Task 5's caller binding, which every pre-existing test exercised —
    ///         and which is exactly why the self-registration path above went unnoticed.
    function test_C1_unregisteredStrangerDrainIsRefused() public {
        vm.prank(stranger);
        vm.expectRevert(LighterCore.LighterCore_AccountNotCaller.selector);
        sim.withdraw(3, ASSET_IDX, 0, type(uint64).max);

        assertEq(sim.getPendingBalance(stranger, ASSET_IDX), 0, "stranger was credited");
        _assertNothingMoved();
    }

    /// @notice A registered account is still bound to its OWN index, so registration is not a
    ///         licence to name someone else's account. The gate the allowlist sits in front of.
    function test_C1_aRegisteredAccountCannotNameAnothersIndex() public {
        uint48 bIdx = sim.addressToAccountIndex(depositorB);
        vm.prank(depositorA);
        vm.expectRevert(LighterCore.LighterCore_AccountNotCaller.selector);
        sim.withdraw(bIdx, ASSET_IDX, 0, 1e6);
    }

    /// @notice The gate is a gate, not a brick: an approved depositor still deposits, and the
    ///         legitimate withdraw path still works. A closure that broke the happy path would be
    ///         a different outage, not a fix.
    function test_C1_theAllowlistedPathStillWorks() public {
        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        assertGt(aIdx, 0, "A never registered");

        vm.prank(depositorA);
        sim.withdraw(aIdx, ASSET_IDX, 0, 100e6);
        assertEq(sim.getPendingBalance(depositorA, ASSET_IDX), 100e6, "A's own withdraw broke");
    }

    /// @notice Revoking an allowance stops further deposits but does not unregister an existing
    ///         account — `addressToAccountIndex` is the venue's own state, on the core.
    function test_C1_revocationStopsDepositsNotTheExistingAccount() public {
        sim.setDepositorAllowed(depositorA, false);
        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        assertGt(aIdx, 0, "revocation unregistered A");

        vm.prank(depositorA);
        vm.expectRevert(abi.encodeWithSelector(LighterSim.LighterSim_DepositorNotAllowed.selector, depositorA));
        sim.deposit(depositorA, ASSET_IDX, 0, 1e6);
    }

    function test_C1_setDepositorAllowedIsOwnerOnlyAndEvented() public {
        vm.prank(stranger);
        vm.expectRevert(LighterSim.LighterSim_OnlyOwner.selector);
        sim.setDepositorAllowed(stranger, true);

        vm.expectEmit(true, false, false, true, address(sim));
        emit LighterSim.DepositorAllowedSet(stranger, true);
        sim.setDepositorAllowed(stranger, true);
        assertTrue(sim.depositorAllowed(stranger));
    }

    /// @notice `MockLighter` stays UNRESTRICTED, so the existing suite runs against the venue's
    ///         real registration model. The allowlist is not venue-faithful and must not leak onto
    ///         the test front end.
    ///
    /// @dev Probed with CORRECT encoding, and both halves asserted. A bare-selector probe would
    ///      fail in the ABI decoder whether or not the function exists, which is the vacuity the
    ///      Task 5 report's §5.3 is about.
    function test_C1_theAllowlistIsOnTheSimOnly() public {
        bytes memory probe = abi.encodeWithSignature("depositorAllowed(address)", stranger);
        (bool simOk,) = address(sim).call(probe);
        assertTrue(simOk, "the sim lost its allowlist");
        (bool mockOk,) = address(mockL).call(probe);
        assertFalse(mockOk, "the simulator-only allowlist leaked onto MockLighter");

        // And the mock genuinely still registers an arbitrary address, which is the behaviour the
        // absence is there to preserve.
        usdgMock.mint(address(this), 1_000e6);
        usdgMock.approve(address(mockL), type(uint256).max);
        mockL.deposit(stranger, ASSET_IDX, 0, 1_000e6);
        assertGt(mockL.addressToAccountIndex(stranger), 0, "the mock stopped registering freely");
    }

    // ------------------------------------------------------------------------- CRITICAL 2
    // Fix round 1: the settlement DoS that fix round 0 introduced.
    // ---------------------------------------------------------------------------------------

    /// @notice RE-POINTED 2026-09-09 (was `test_C2_ownerHatchClearsAJammedQueue`; see the file
    ///         header). Same original question — can one account's bad order stop everyone else's
    ///         settlement, and is there any way out — with the new answer: no, `settleBatch`
    ///         rejects the poison order by name and keeps going, so the jam this test used to prove
    ///         cannot form and no hatch is needed for it at all. `settleCursor` is the queue's own
    ///         evidence that nothing is stuck: after the poison order's turn, it is back to 0.
    ///
    ///         The jammer is ALLOWLISTED here on purpose, unchanged from the original test: the
    ///         allowlist reduces who can reach the venue but was never what made this attack fail.
    ///
    /// @dev Twin of `test_oneAccountsBadOrderCannotBrickSettlement` in `test/sim/LighterSim.t.sol`
    ///      and `test_twoVaultsShareOneSimWithoutInterference` in
    ///      `test/sim/SharedSimMultiVault.t.sol` — the task-7 report's evidence that this attack is
    ///      closed twice over, kept here as the frozen file's own proof rather than relying on
    ///      theirs.
    function test_C2_poisonOrderIsRejectedAndSettlementSurvives() public {
        sim.setMarkPrice(MARKET, 100e18);
        sim.setDepositorAllowed(stranger, true);

        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 100, 10_000, 0, 1); // the vault's legitimate hedge, queued first

        usdgSim.mint(stranger, 1e6);
        vm.startPrank(stranger);
        usdgSim.approve(address(sim), type(uint256).max);
        sim.deposit(stranger, ASSET_IDX, 0, 1e6); // $1, nowhere near enough
        uint48 sIdx = sim.addressToAccountIndex(stranger);
        sim.createOrder(sIdx, MARKET, type(uint48).max, 10_000, 0, 1); // the poison pill, queued second
        vm.stopPrank();

        // One call, no revert, from the owner: the refusal is on the record, naming the order and
        // the reason, instead of stopping the batch.
        vm.expectEmit(true, true, true, true, address(sim));
        emit LighterCore.OrderRejected(sIdx, MARKET, 1, LighterCore.InsufficientMargin.selector);
        sim.settleBatch();

        // The vault's hedge filled at its full, requested size...
        assertEq(sim.positionBaseOf(aIdx, MARKET), 100, "the legitimate hedge did not survive settlement");
        // ...the poison pill holds nothing, rejected rather than partially applied...
        assertEq(sim.positionBaseOf(sIdx, MARKET), 0, "the rejected order still moved the poison account's book");
        // ...and the venue-level view agrees: open interest is exactly the hedge.
        assertEq(sim.positionBase(MARKET), 100, "aggregate position does not match the surviving hedge");

        // The rejection consumed its queue slot instead of jamming it: nothing left, and no one
        // stuck waiting behind it.
        assertEq(sim.queueLength(), 0, "the rejected order stayed in the queue");
        assertEq(sim.queuedOrdersOf(sIdx), 0, "the rejected order still counts against its account");
        assertEq(sim.settleCursor(), 0, "a rejected order left the cursor stuck");

        // And settlement keeps working afterwards — the half the old owner-hatch-only answer could
        // not give a third party without operator help.
        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 50, 10_000, 0, 1);
        sim.settleBatch();
        assertEq(sim.positionBaseOf(aIdx, MARKET), 150, "settlement did not survive the earlier rejection");
    }

    /// @notice The hatch drops ONLY the named account's orders, so unjamming does not silently
    ///         cancel the vault's hedge along with the poison pill.
    function test_C2_theHatchIsScopedToTheNamedAccount() public {
        sim.setMarkPrice(MARKET, 100e18);
        sim.setDepositorAllowed(stranger, true);

        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 100, 10_000, 0, 1);

        usdgSim.mint(stranger, 1e6);
        vm.startPrank(stranger);
        usdgSim.approve(address(sim), type(uint256).max);
        sim.deposit(stranger, ASSET_IDX, 0, 1e6);
        uint48 sIdx = sim.addressToAccountIndex(stranger);
        sim.createOrder(sIdx, MARKET, type(uint48).max, 10_000, 0, 1);
        vm.stopPrank();

        sim.ownerCancelAccountOrders(sIdx);
        sim.settleBatch();
        // A's 100 survived and filled; the poison pill did not.
        assertEq(sim.positionBase(MARKET), 100, "the hatch took the wrong orders");
    }

    /// @notice The other whole-batch revert Task 5 added jams settlement the same way: an order on
    ///         a market whose mark was never set trips the `LighterSim_MarkPriceUnset` pre-pass.
    ///         Here the owner has a second route out — set the mark the log names — but the hatch
    ///         is what works when the order should not fill at all.
    function test_C2_ownerHatchClearsAMarklessMarketJam() public {
        sim.setMarkPrice(MARKET, 100e18);
        sim.setDepositorAllowed(stranger, true);

        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        vm.prank(depositorA);
        sim.createOrder(aIdx, MARKET, 100, 10_000, 0, 1);

        usdgSim.mint(stranger, 1e6);
        vm.startPrank(stranger);
        usdgSim.approve(address(sim), type(uint256).max);
        sim.deposit(stranger, ASSET_IDX, 0, 1e6);
        uint48 sIdx = sim.addressToAccountIndex(stranger);
        sim.createOrder(sIdx, MARKET_NO_MARK, 1, 10_000, 0, 1);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(LighterSim.LighterSim_MarkPriceUnset.selector, MARKET_NO_MARK));
        sim.settleBatch();

        sim.ownerCancelAccountOrders(sIdx);
        sim.settleBatch();
        assertEq(sim.positionBase(MARKET), 100, "A's hedge did not survive the unjam");
        assertEq(sim.positionBase(MARKET_NO_MARK), 0, "the markless order filled");
    }

    /// @notice The blunt instrument, for a queue stuck for a reason the operator cannot attribute
    ///         to one account. Logged with `accountIndex == 0`, which is never a real index, so a
    ///         reader can tell a purge from a scoped drop.
    function test_C2_ownerPurgeQueueDropsEverything() public {
        sim.setMarkPrice(MARKET, 100e18);
        uint48 aIdx = sim.addressToAccountIndex(depositorA);
        vm.startPrank(depositorA);
        sim.createOrder(aIdx, MARKET, 100, 10_000, 0, 1);
        sim.createOrder(aIdx, MARKET, 20, 10_000, 0, 1);
        vm.stopPrank();

        vm.expectEmit(true, false, false, true, address(sim));
        emit LighterSim.OperatorCancelledOrders(0, 2);
        sim.ownerPurgeQueue();

        sim.settleBatch();
        assertEq(sim.positionBase(MARKET), 0, "purge left orders behind");
    }

    /// @notice The hatch is ADDITIONAL, not a relaxation. Both entry points are owner-only, and
    ///         `cancelAllOrders` keeps its per-account binding for everyone else.
    function test_C2_theHatchIsOwnerOnly() public {
        uint48 aIdx = sim.addressToAccountIndex(depositorA);

        vm.prank(stranger);
        vm.expectRevert(LighterSim.LighterSim_OnlyOwner.selector);
        sim.ownerCancelAccountOrders(aIdx);

        vm.prank(depositorA);
        vm.expectRevert(LighterSim.LighterSim_OnlyOwner.selector);
        sim.ownerCancelAccountOrders(aIdx);

        vm.prank(stranger);
        vm.expectRevert(LighterSim.LighterSim_OnlyOwner.selector);
        sim.ownerPurgeQueue();

        vm.prank(depositorA);
        vm.expectRevert(LighterSim.LighterSim_OnlyOwner.selector);
        sim.ownerPurgeQueue();
    }

    /// @notice The hatch exists on `LighterSim` only. `MockLighter` has no owner to gate it with,
    ///         so an inherited hatch would be an ungated `delete _queue` on the test front end —
    ///         which is precisely the pre-Task-5 defect, reintroduced by the fix for its successor.
    ///
    /// @dev `_cancelOrdersOf` is `internal` on the core and carries no authorisation of its own;
    ///      nothing on `LighterCore` exposes it. Both halves asserted, correct encoding.
    function test_C2_theHatchIsOnTheDeployableFrontEndOnly() public {
        bytes[2] memory probes = [
            abi.encodeWithSignature("ownerPurgeQueue()"),
            abi.encodeWithSignature("ownerCancelAccountOrders(uint48)", uint48(3))
        ];
        for (uint256 i = 0; i < probes.length; ++i) {
            (bool simOk,) = address(sim).call(probes[i]);
            assertTrue(simOk, "the sim lost its escape hatch");
            (bool mockOk,) = address(mockL).call(probes[i]);
            assertFalse(mockOk, "the owner escape hatch leaked onto MockLighter");
        }
    }

    // ---------------------------------------------------------------------------------------

    /// @dev The simulator's collateral, its margin ledger, and the attacker's holdings are all
    ///      exactly where the fixture left them. Asserting the revert alone would not rule out a
    ///      partial credit before it.
    function _assertNothingMoved() internal view {
        assertEq(usdgSim.balanceOf(address(sim)), 1_000_000e6, "simulator collateral moved");
        assertEq(sim.marginBalance(), 1_000_000e6, "marginBalance moved");
        assertEq(usdgSim.balanceOf(stranger), 0, "attacker holds tokens");
        assertEq(sim.getPendingBalance(stranger, ASSET_IDX), 0, "attacker holds a pending credit");
    }
}
