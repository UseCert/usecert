// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {CertVault} from "../src/CertVault.sol";
import {VaultFixture} from "./helpers/VaultFixture.sol";

/// @notice The two-phase mint refund, and the proof it cannot strand escrow.
///
///         Every test here DRAINS THE HOT BUFFER FIRST, and that is the point of the file. The
///         pre-existing test_refundMintReturnsEscrowAfterWindow (CertVaultMint.t.sol) exercises a
///         refund against the fixture's 100_000e6 seeded buffer, so the payout always happened to
///         be affordable and the funding path was never tested at all — which is exactly how a
///         permanently strandable refund shipped. Against a drained buffer the payout is NOT
///         affordable at refund time, so the recall path has to actually work.
///
///         The defect this file pins: refundMint used to reallocate the escrow's venue-side margin
///         share (postedMargin -> marginPendingRecall, the only thing that makes recallMargin()
///         ask the venue for it) in the SAME function that paid the user. Solidity has no partial
///         commit, so when the payout reverted on insufficient balance the reallocation was rolled
///         back with it — the reallocation could never run in the one situation it existed for.
///         With marginPendingRecall left at 0 and mint escrow absent from totalOwedOutstanding,
///         recallMargin()'s `want = max(need, marginPendingRecall)` computed 0 and submitted
///         nothing, so no external call could ever create the funding condition. Hence two entry
///         points: stageRefund (counters and a fail-open hedge close, so it always succeeds) and
///         refundMint (may revert retryably on funding).
contract CertVaultRefundTest is VaultFixture {
    /// The fixture's numbers for one 50_000e6 requestMint, at mintFeeBps = 10 and
    /// targetMarginBps = 9_000, spelled out so the arithmetic is auditable from the test alone.
    uint256 internal constant MINT_IN = 50_000e6;
    /// 50_000 less the 10 bps mint fee (50e6).
    uint256 internal constant ESCROW = 49_950e6;
    /// ESCROW * 9_000 / 10_000 — what requestMint's _postMargin sent to the venue.
    uint256 internal constant POSTED = 44_955e6;
    /// MINT_IN - POSTED — the escrow's retained 10% plus the 50e6 fee, i.e. all the vault keeps.
    uint256 internal constant RETAINED = 5_045e6;
    /// _baseAmount(indicative) at PX = 355.86e18 with sizeDecimals = 4: the hedge requestMint
    /// opens, and the exposure a refund has to close.
    int256 internal constant HEDGE_TICKS = 1_403_641;

    /// @dev Drain the vault's ERC20 balance, open a 50k request against the emptied vault, let the
    ///      venue fill the hedge, and warp one second past the settle window. Leaves the vault
    ///      holding RETAINED — far less than the ESCROW a refund owes — with POSTED at the venue.
    function _drainThenRequestPastWindow() internal returns (uint256 id) {
        _drainHotBuffer();
        assertEq(vault.hotBuffer(), 0, "buffer was not drained");

        vm.prank(alice);
        id = vault.requestMint(MINT_IN);
        lighter.settleBatch(); // the BID fills at the venue

        assertEq(vault.hotBuffer(), RETAINED);
        assertLt(vault.hotBuffer(), ESCROW, "the payout must NOT be affordable at refund time");
        assertEq(lighter.positionBase(MARKET), HEDGE_TICKS);

        vm.warp(block.timestamp + SETTLE_WINDOW + 1);
    }

    /// @notice THE PROOF THIS FIX EXISTS FOR. A refund the vault cannot afford at refund time must
    ///         still end with the user holding the full escrow, reached entirely through
    ///         permissionless calls by a stranger who holds nothing.
    /// @dev Load-bearing: with Step 2's reallocation removed from stageRefund, marginPendingRecall
    ///      stays 0, mint escrow is in no other counter, recallMargin()'s
    ///      `want = max(need, marginPendingRecall)` is 0, the withdrawal is never submitted, and
    ///      this test fails on the CertVault_RefundAwaitingSettlement below no matter how many
    ///      recall/settle cycles are added. Verified by doing exactly that; see the fix report.
    function test_refundIsRecoverableFromADrainedBuffer() public {
        uint256 id = _drainThenRequestPastWindow();
        uint256 aliceBefore = usdg.balanceOf(alice);
        address stranger = makeAddr("refundStranger");

        // ---- Phase 1 always succeeds: it moves counters, it does not move money.
        uint256 postedBefore = vault.postedMargin();
        vm.prank(stranger);
        vault.stageRefund(id);
        assertEq(vault.postedMargin(), postedBefore - POSTED);
        assertEq(vault.marginPendingRecall(), POSTED);

        // ---- Phase 2 cannot pay yet, and says so retryably rather than reverting rawly on the
        //      ERC20's own balance check (which is what it used to do, forever).
        vm.expectRevert(CertVault.CertVault_RefundAwaitingSettlement.selector);
        vault.refundMint(id);
        assertEq(vault.hotBuffer(), RETAINED, "a failed payout must not have moved anything");

        // ---- The escape route, every step of it permissionless and called by a stranger.
        vm.prank(stranger);
        vault.recallMargin(); // submits the withdrawal the staging made askable-for
        assertEq(uint256(lighter.getPendingBalance(address(vault), ASSET_IDX)), POSTED);

        lighter.settleBatch(); // the staged hedge close fills, flattening the position

        vm.prank(stranger);
        vault.recallMargin(); // sweeps what the venue actually released
        assertEq(vault.marginPendingRecall(), 0);
        assertEq(vault.hotBuffer(), RETAINED + POSTED); // 5_045 + 44_955 = 50_000e6

        // ---- And the user is paid the escrow, in full, to the last unit.
        vm.prank(stranger);
        uint256 out = vault.refundMint(id);
        assertEq(out, ESCROW);
        assertEq(usdg.balanceOf(alice) - aliceBefore, ESCROW, "the user was not made whole");
        assertEq(usdg.balanceOf(stranger), 0, "the refund paid its caller");
        assertEq(cert.totalSupply(), 0); // refunded, not minted
        // Only the mint fee is left behind: 50_000 in, 49_950 out, 50 retained.
        assertEq(vault.hotBuffer(), MINT_IN - ESCROW);

        // Settled once and for all.
        vm.expectRevert(CertVault.CertVault_BadReceipt.selector);
        vault.refundMint(id);
        vm.expectRevert(CertVault.CertVault_BadReceipt.selector);
        vault.stageRefund(id);
    }

    /// @notice refundMint without staging is refused — and the refusal is escapable immediately by
    ///         anyone, which is the only reason it is allowed to exist (Law 2).
    function test_refundMintRevertsWhenNotStaged() public {
        uint256 id = _drainThenRequestPastWindow();

        vm.expectRevert(CertVault.CertVault_RefundNotStaged.selector);
        vault.refundMint(id);

        // The route out, taken by someone with no stake in the receipt at all.
        vm.prank(makeAddr("anyone"));
        vault.stageRefund(id);

        // The gate is gone: what is left is the retryable funding condition, not the staging one.
        vm.expectRevert(CertVault.CertVault_RefundAwaitingSettlement.selector);
        vault.refundMint(id);
    }

    /// @notice Law 6: staging has no owner, keeper or pause. A stranger holding no collateral and
    ///         no certificates can do it, and is paid nothing for it.
    function test_stageRefundIsPermissionless() public {
        uint256 id = _drainThenRequestPastWindow();

        address stranger = makeAddr("brokeStranger");
        assertEq(usdg.balanceOf(stranger), 0);
        assertEq(cert.balanceOf(stranger), 0);

        vm.prank(stranger);
        vault.stageRefund(id);

        (,,,,, bool staged,) = vault.mintReceipts(id);
        assertTrue(staged);
        assertEq(usdg.balanceOf(stranger), 0);
        assertEq(vault.marginPendingRecall(), POSTED);
    }

    /// @notice Staging is idempotent-once. A second reallocation would manufacture venue headroom
    ///         out of nothing — the exact failure mode that killed three earlier recall designs.
    function test_stageRefundOnlyOnce() public {
        uint256 id = _drainThenRequestPastWindow();
        vault.stageRefund(id);

        uint256 posted = vault.postedMargin();
        uint256 pending = vault.marginPendingRecall();

        vm.expectRevert(CertVault.CertVault_BadReceipt.selector);
        vault.stageRefund(id);

        assertEq(vault.postedMargin(), posted);
        assertEq(vault.marginPendingRecall(), pending);
    }

    /// @notice While the window is open, settleMint is the live path and there is nothing to stage.
    /// @dev DEVIATION from the brief, which named a new CertVault_SettleWindowActive for this. The
    ///      contract already had CertVault_SettleWindowNotExpired meaning exactly "too early" (it
    ///      is what refundMint has always reverted with before the window), so this reuses it
    ///      rather than adding a second, synonymous error every caller would then have to handle.
    function test_stageRefundRevertsBeforeWindow() public {
        _drainHotBuffer();
        vm.prank(alice);
        uint256 id = vault.requestMint(MINT_IN);
        lighter.settleBatch();

        vm.expectRevert(CertVault.CertVault_SettleWindowNotExpired.selector);
        vault.stageRefund(id);

        vm.warp(block.timestamp + SETTLE_WINDOW); // exactly at the deadline: still settleable
        vm.expectRevert(CertVault.CertVault_SettleWindowNotExpired.selector);
        vault.stageRefund(id);

        vm.warp(block.timestamp + 1); // one second later the fork opens
        vault.stageRefund(id);
        (,,,,, bool staged,) = vault.mintReceipts(id);
        assertTrue(staged);
    }

    /// @notice The coupled Important. requestMint opens a hedge; the refund path never closed it,
    ///         leaving the vault long against certificates that were never minted (measured: a
    ///         1,403,641-tick position against totalSupply 0). stageRefund closes exactly the
    ///         exposure the receipt recorded, and does it fail-open.
    function test_stageRefundClosesTheHedge() public {
        uint256 id = _drainThenRequestPastWindow();

        (,,,,,, uint256 indicative) = vault.mintReceipts(id);
        assertEq(indicative, uint256(ESCROW) * 1e12 * 1e18 / PX, "the hedged amount was not recorded");
        assertEq(int256(indicative * 1e4 / 1e18), HEDGE_TICKS); // sizeDecimals = 4
        assertEq(lighter.positionBase(MARKET), HEDGE_TICKS);

        vm.expectEmit(true, true, true, true, address(vault));
        emit CertVault.RefundStaged(id, POSTED, true);
        vault.stageRefund(id);

        // The order that went in is a SELL of exactly the recorded exposure.
        assertEq(lighter.queuedOrderCount(), 1);
        (uint16 mkt, uint48 base,, uint8 isAsk, uint8 orderType) = lighter.lastOrder();
        assertEq(mkt, MARKET);
        assertEq(uint256(base), uint256(HEDGE_TICKS));
        assertEq(isAsk, 1); // closing a long
        assertEq(orderType, 1); // MarketOrder

        lighter.settleBatch();
        assertEq(lighter.positionBase(MARKET), 0, "the hedge outlived the mint it hedged");
    }

    /// @notice Law 1, end to end: once the refund has run there is no supply and no position. No
    ///         rebalance() and therefore no attester is needed to get there.
    function test_refundDoesNotLeaveVaultOverHedged() public {
        uint256 id = _drainThenRequestPastWindow();

        vault.stageRefund(id);
        vault.recallMargin();
        lighter.settleBatch();
        vault.recallMargin();
        vault.refundMint(id);

        assertEq(cert.totalSupply(), 0);
        assertEq(lighter.positionBase(MARKET), 0);
        assertEq(lighter.entryPrice(MARKET), 0);
    }

    /// @notice The reallocation is a TRANSFER between two counters, never new headroom. This is the
    ///         same property invariant_marginNeverExceedsDeposited asserts under fuzzing, pinned
    ///         deterministically on the one function that moves both counters at once.
    function test_counterSumConservedAcrossStageRefund() public {
        uint256 id = _drainThenRequestPastWindow();

        uint256 sumBefore = vault.postedMargin() + vault.marginPendingRecall();
        vault.stageRefund(id);
        assertEq(vault.postedMargin() + vault.marginPendingRecall(), sumBefore);
        assertEq(vault.marginPendingRecall(), POSTED); // it genuinely moved, it did not no-op
    }

    /// @notice The retryable revert must leave the receipt exactly as it found it: unsettled, so it
    ///         can still be refunded, and still staged, so the reallocation is not redone. Setting
    ///         r.settled before the funding check would burn the receipt on a failed payout — the
    ///         sharpest possible Law 2 breach.
    function test_refundAwaitingSettlementDoesNotMarkSettled() public {
        uint256 id = _drainThenRequestPastWindow();
        vault.stageRefund(id);

        vm.expectRevert(CertVault.CertVault_RefundAwaitingSettlement.selector);
        vault.refundMint(id);

        (address user, uint256 escrow, bool settled,,, bool staged,) = vault.mintReceipts(id);
        assertEq(user, alice);
        assertEq(escrow, ESCROW);
        assertFalse(settled, "a failed payout marked the receipt settled");
        assertTrue(staged);

        vm.expectRevert(CertVault.CertVault_BadReceipt.selector);
        vault.stageRefund(id); // still exactly once, so the counters cannot be moved twice

        // And it does eventually pay, which is the half that makes accepting the revert legitimate.
        vault.recallMargin();
        lighter.settleBatch();
        vault.recallMargin();
        uint256 before = usdg.balanceOf(alice);
        vault.refundMint(id);
        assertEq(usdg.balanceOf(alice) - before, ESCROW);
    }

    // ------------------------------------------------------------------------------------ Step 4
    // recallMargin()'s `want = max(need, marginPendingRecall)` is claimed to already cover a staged
    // refund, because staging moves the amount into marginPendingRecall. The brief asked for that
    // to be verified by test rather than by reading. These two are that verification: the first
    // shows the request lands at exactly the staged amount, the second pins the defect's mechanism
    // by showing the request is nothing at all when the reallocation has not happened.

    /// @notice Verified, not read: a staged refund's posted share reaches recallMargin()'s sizing
    ///         through marginPendingRecall, and the venue is asked for exactly it. No change to
    ///         `need` was required.
    function test_recallMarginRequestsTheStagedRefundShare() public {
        uint256 id = _drainThenRequestPastWindow();
        assertEq(vault.totalOwedOutstanding(), 0, "mint escrow is in no owed counter, by design");

        vault.stageRefund(id);

        vm.expectEmit(true, true, true, true, address(vault));
        emit CertVault.MarginRecallRequested(POSTED);
        vault.recallMargin();
        assertEq(uint256(lighter.getPendingBalance(address(vault), ASSET_IDX)), POSTED);
    }

    /// @notice The sharp edge of the `posted > postedMargin` cap, measured rather than assumed.
    ///         A full-supply forceExit allocates ALL of postedMargin to itself, so a refund staged
    ///         afterwards gets a reallocation of exactly ZERO. That cap is correct and must stay —
    ///         it is what stops staging manufacturing venue headroom — but it means the escrow's
    ///         recovery then depends on something other than its own margin share. This test
    ///         proves the remaining route out is real: the venue is genuinely empty
    ///         (marginBalance == 0, so there is nothing left to recall and the shortfall is an
    ///         insolvency, not a routing failure), and the permissionless seedBuffer pays the user
    ///         in full. Law 2 holds through the capped case, which is the thing worth knowing.
    function test_cappedReallocationStillEscapesViaSeedBuffer() public {
        // Some supply, then a large request, then a full-supply exit that claims all of
        // postedMargin, then a drain that removes every retained share.
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();
        vm.prank(alice);
        uint256 id = vault.requestMint(MINT_IN);
        lighter.settleBatch();

        // Captured before the prank on purpose: cert.balanceOf is itself an external call and
        // would otherwise consume the prank, sending forceExit from this test contract instead.
        uint256 aliceCerts = cert.balanceOf(alice);
        vm.prank(alice);
        vault.forceExit(aliceCerts); // certIn == supplyBefore -> takes all of postedMargin
        assertEq(vault.postedMargin(), 0, "the exit did not claim the whole allocation counter");
        _drainHotBuffer();

        vm.warp(block.timestamp + SETTLE_WINDOW + 1);

        // Staging still succeeds — it always does — but reallocates nothing, because there is
        // nothing left in postedMargin to reallocate.
        vm.expectEmit(true, true, true, true, address(vault));
        emit CertVault.RefundStaged(id, 0, true);
        vault.stageRefund(id);

        // Bring home everything the venue will give up, and pay the queued redeem out of it.
        for (uint256 i = 0; i < 4; ++i) {
            vault.recallMargin();
            lighter.settleBatch();
        }
        vault.recallMargin();
        vault.claimRedeem(2); // the forceExit receipt: ids are shared, mintInstant issues none
        assertEq(lighter.marginBalance(), 0, "the venue still holds recallable margin");

        // The refund is short — of exactly what the drain removed, not of anything the vault
        // failed to ask for — and it says so retryably rather than reverting rawly.
        assertLt(vault.hotBuffer(), ESCROW);
        vm.expectRevert(CertVault.CertVault_RefundAwaitingSettlement.selector);
        vault.refundMint(id);

        // The route out, open to anyone: top the buffer up and the user is paid in full.
        vault.seedBuffer(10_000e6);
        uint256 before = usdg.balanceOf(alice);
        vault.refundMint(id);
        assertEq(usdg.balanceOf(alice) - before, ESCROW, "the user was not made whole");
    }

    /// @notice The defect's mechanism, pinned. Unstaged, the escrow's posted share appears in
    ///         neither counter recallMargin() sizes off, so `want` is 0 and NOTHING is submitted —
    ///         no number of retries can help. This is why the reallocation had to leave refundMint.
    function test_recallMarginDoesNotRequestUnstagedRefundEscrow() public {
        _drainThenRequestPastWindow();

        assertEq(vault.marginPendingRecall(), 0);
        assertEq(vault.totalOwedOutstanding(), 0);

        for (uint256 i = 0; i < 5; ++i) {
            vault.recallMargin();
            lighter.settleBatch();
        }
        assertEq(uint256(lighter.getPendingBalance(address(vault), ASSET_IDX)), 0, "something was requested");
        assertEq(vault.hotBuffer(), RETAINED, "the buffer moved without a staged reallocation");
    }
}
