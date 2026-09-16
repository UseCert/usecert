// SPDX-License-Identifier: MIT
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

        // TASK 6a: this batch now does two things — it fills the staged hedge close, and it
        // executes the withdrawal request `recallMargin` just submitted. Fills run first, so the
        // withdrawal is fulfilled against the flattened book.
        lighter.settleBatch();
        assertEq(uint256(lighter.getPendingBalance(address(vault), ASSET_IDX)), POSTED);

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
        // C-1: indicativeCerts is now FLOORED to the venue's own size granularity before it is
        // recorded or hedged, because settleMint mints exactly this number — so it has to be a
        // number the venue can hold. The unquantised escrow/PX figure this used to assert
        // (140.364188163884673748) is 88_163_884_673_748 wei above what the 1_403_641-tick order
        // actually represents, and minting that difference is supply the hedge does not cover.
        assertEq(indicative, uint256(HEDGE_TICKS) * 1e14, "the hedged amount was not recorded");
        assertLe(indicative, uint256(ESCROW) * 1e12 * 1e18 / PX, "the record exceeds the escrow it was sized from");
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
        // TASK 6a: `MarginRecallRequested` still fires in the `recallMargin` transaction — it is
        // the SUBMISSION event and always was — but the venue now credits the pending balance when
        // a batch executes the request. The assertion below is unchanged in substance: the staged
        // refund share is what the venue was asked for, and it is what arrives.
        lighter.settleBatch();
        assertEq(uint256(lighter.getPendingBalance(address(vault), ASSET_IDX)), POSTED);
    }

    /// @notice `CertVault_RefundNotStaged` must never become permanent, or the Critical is back in
    ///         a new shape. `stageRefund` originally read `oracle.pxUnguarded()` unwrapped to price
    ///         the closing order, and that read is NOT actually revert-proof despite its NatSpec:
    ///         `CertOracle._tryFeed` computes `block.timestamp - t` inside a try's SUCCESS block,
    ///         which that try's own catch does not cover, so a feed reporting a future
    ///         `updatedAt` panics straight through `pxUnguarded()` and its `lastGoodPx18` fallback
    ///         is unreachable. `oracle` and `feed` are both immutable, so there is no swap.
    ///         Found in self-review, not by the brief.
    /// @dev UPDATED for CRITICAL B, which fixed the underflow this test originally *asserted*:
    ///      the first assertion below used to be `vm.expectRevert(); oracle.pxUnguarded();`,
    ///      recording the panic as the finding. `CertOracle._tryFeed` now short-circuits
    ///      `t > block.timestamp` before the subtraction, so `pxUnguarded()` reaches its
    ///      `lastGoodPx18` fallback instead of panicking, and that first assertion is now false.
    ///      It is replaced with the stronger statement of the same property — the read is
    ///      revert-free AND returns last-good — not deleted. Nothing else in this test changed:
    ///      the point that `stageRefund` must not depend on an oracle read at all is independent
    ///      of whether the oracle happens to be revert-free today, and is still asserted below.
    ///      (See test/CertOracle.t.sol's test_pxUnguardedSurvivesFutureFeedTimestamp and
    ///      test_pxRevertsNamedErrorOnFutureTimestamp for CRITICAL B's own direct coverage.)
    function test_stageRefundSurvivesAnOracleThatPanicsOnRead() public {
        uint256 id = _drainThenRequestPastWindow();

        // The feed starts reporting a timestamp in the future and freezes there.
        feed.set(int256(PX / 1e10), block.timestamp + 1 days);

        // Post-CRITICAL B: the documented-never-to-revert read genuinely does not revert, and
        // answers with the last-good snapshot rather than the malfunctioning feed's live value.
        (uint256 unguardedPx,) = oracle.pxUnguarded();
        assertEq(unguardedPx, PX, "pxUnguarded did not fall back to last-good");

        // stageRefund does not care: it prices the close off the receipt's own requestPx18.
        vault.stageRefund(id);
        (,,,,, bool staged,) = vault.mintReceipts(id);
        assertTrue(staged, "staging was blocked by a broken oracle");
        assertEq(vault.marginPendingRecall(), POSTED);
        assertEq(lighter.queuedOrderCount(), 1, "the close was not even submitted");

        // And the whole refund completes with the oracle still broken — no path here reads it.
        vault.recallMargin();
        lighter.settleBatch();
        vault.recallMargin();
        uint256 before = usdg.balanceOf(alice);
        vault.refundMint(id);
        assertEq(usdg.balanceOf(alice) - before, ESCROW);
        assertEq(lighter.positionBase(MARKET), 0);
    }

    /// @notice A venue whose pending-balance VIEW reverts must not block a refund the vault can
    ///         already afford. `_sweepPending` read `getPendingBalance` unguarded (only the drain
    ///         was wrapped), so a paused or misconfigured venue would have reverted `refundMint`
    ///         with a venue error while the buffer was fully funded — a revert that is neither
    ///         `CertVault_RefundAwaitingSettlement` nor escapable by anything, since every
    ///         documented escape (`recallMargin`, and `claimRedeem` on the redeem side) sweeps
    ///         through the same read. Found in self-review, not by the brief.
    function test_refundSurvivesABrokenPendingBalanceRead() public {
        uint256 id = _drainThenRequestPastWindow();
        vault.stageRefund(id);

        // Fund the buffer so the ONLY thing that could refuse the payout is the broken read.
        vault.seedBuffer(50_000e6);
        assertGe(vault.hotBuffer(), ESCROW);

        lighter.setShouldRevertPendingRead(true);

        uint256 before = usdg.balanceOf(alice);
        uint256 out = vault.refundMint(id); // must not propagate the venue's error
        assertEq(out, ESCROW);
        assertEq(usdg.balanceOf(alice) - before, ESCROW);

        // The same read is on claimRedeem's and recallMargin's paths; neither may propagate it.
        lighter.setShouldRevertPendingRead(true);
        vault.recallMargin(); // fail-open, must not revert
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

    // ---------------------------------------------------------------------------------------
    // CRITICAL A (C1 final review): the escalation in refund-fix-report.md section 8.1.
    // stageRefund's hedge close is open-loop (ILighter exposes no position getter), so a refund
    // can end with a position still open at zero outstanding supply. That much is still true.
    // What made it a CRITICAL rather than a delta breach was the second half: _solvency reported
    // deltaBps == 10_000 for ANY state with required == 0, so the vault claimed to be perfectly
    // hedged with zero certificates outstanding and a live position, and rebalance() reverted
    // CertVault_InBand at exactly the moment a trim was needed. forceExit/requestRedeem need
    // certificates and there were none; stageRefund is once-only. Governance's closeAll() was the
    // only escape, and the venue's initial-margin lock on the unwanted position blocked the very
    // recall the refund depended on. That second half is what these two tests are about.
    // ---------------------------------------------------------------------------------------

    /// @notice The full refund sequence in the state that used to be terminal, then the proof that
    ///         a permissionless caller walks the vault back to flat with NO governance involvement
    ///         (Law 6). Every call below is made by a stranger holding no certificates and no
    ///         collateral, except the attestations, which are the attester's ordinary per-batch
    ///         duty that C2's one-rebalance-per-batch bound is defined in terms of - not a
    ///         privileged intervention, and specifically not closeAll().
    /// @dev The stranding is produced by the venue REFUSING the closing order, which is exactly
    ///      what _tryHedge's fail-open catch and CertVault's CloseOrderNotPlaced event exist for.
    ///      It is the only way to strand a position at zero supply that does not also flatten the
    ///      position being stranded: staging prices its close off r.requestPx18, so no oracle
    ///      state can make it unplaceable (see test_stageRefundSurvivesAnOracleThatPanicsOnRead).
    /// @dev LOAD-BEARING: with _solvency's `required == 0` branch restored to an unconditional
    ///      10_000, the first rebalance() below reverts CertVault_InBand and this test fails on
    ///      "the dangling position never reached flat" with the position still at 1_403_641.
    function test_refundDoesNotLeaveVaultPermanentlyOverHedged() public {
        uint256 id = _drainThenRequestPastWindow();
        address stranger = makeAddr("overHedgeStranger");

        // Phase 1, with the venue refusing orders: staging must still succeed (fail-open), and
        // it records that the close did NOT go in.
        lighter.setShouldRevertCreateOrder(true);
        vm.expectEmit(true, true, true, true, address(vault));
        emit CertVault.RefundStaged(id, POSTED, false);
        vm.prank(stranger);
        vault.stageRefund(id);
        lighter.setShouldRevertCreateOrder(false);

        assertEq(lighter.positionBase(MARKET), HEDGE_TICKS, "the close went in after all");
        assertEq(cert.totalSupply(), 0, "no certificate was ever minted for this receipt");

        // Phase 2 still pays in full, through permissionless calls only.
        vm.prank(stranger);
        vault.recallMargin();
        lighter.settleBatch();
        vm.prank(stranger);
        vault.recallMargin();
        uint256 aliceBefore = usdg.balanceOf(alice);
        vm.prank(stranger);
        vault.refundMint(id);
        assertEq(usdg.balanceOf(alice) - aliceBefore, ESCROW, "the user was not made whole");

        // Here is the CRITICAL A state: escrow returned, zero supply, full hedge still open.
        assertEq(cert.totalSupply(), 0);
        assertEq(lighter.positionBase(MARKET), HEDGE_TICKS, "the setup did not leave a dangling position");

        // 1_403_641 ticks is ~49_950e18 of notional against a MAX_REBALANCE_NOTIONAL_18 of
        // 10_000e18, so this deliberately takes SEVERAL attested batches: the point is that it
        // converges to flat, not that one call fixes it.
        uint64 batchId = 2;
        uint256 rebalances;
        for (uint256 i = 0; i < 12 && lighter.positionBase(MARKET) != 0; ++i) {
            uint256 remaining18 = uint256(lighter.positionBase(MARKET)) * PX / (10 ** 4);
            vm.prank(attester);
            reg.attest(address(vault), batchId++, remaining18, 0, 1_190_000e18);
            assertEq(vault.solvency().deltaBps, vault.DELTA_UNBOUNDED_BPS(), "still reported as in band");

            int256 posBefore = lighter.positionBase(MARKET);
            vm.prank(stranger);
            try vault.rebalance() {
                ++rebalances;
                lighter.settleBatch();
                assertLt(lighter.positionBase(MARKET), posBefore, "a trim did not reduce the position");
                assertGe(lighter.positionBase(MARKET), 0, "a trim overshot through flat into a short");
            } catch (bytes memory reason) {
                // The only acceptable stop short of flat is the sub-tick dust guard.
                assertEq(bytes4(reason), CertVault.CertVault_InBand.selector, "rebalance stopped for the wrong reason");
                break;
            }
        }

        assertEq(lighter.positionBase(MARKET), 0, "the dangling position never reached flat");
        assertGt(rebalances, 1, "this was supposed to need more than one batch");
        assertEq(cert.totalSupply(), 0);
    }

    /// @notice KNOWN GAP, asserted rather than left in a report: the zero-supply trim is SIGN
    ///         BLIND, because ISolvencyRegistry.Attestation.notional18 is a uint256 and carries no
    ///         direction. At zero supply the vault therefore always SELLS, which flattens a
    ///         dangling LONG (the test above) but ENLARGES a dangling SHORT.
    ///
    ///         That matters because the shortest route to a dangling position - closeAll(), then
    ///         a staged refund whose open-loop ASK has nothing left to close - produces a SHORT,
    ///         and this fix does not rescue it: rebalance() sells into it, one bounded
    ///         MAX_REBALANCE_NOTIONAL_18 step per attested batch, until the venue refuses the
    ///         increase for want of margin. Governance's closeAll() remains the escape for that
    ///         one shape.
    ///
    ///         Neither half of a real fix is patchable here: sizing the close against the true
    ///         position needs a position getter ILighter does not have, and telling a long from a
    ///         short needs a signed attestation, which is an interface change across
    ///         SolvencyRegistry, CapacityOracle and every attester. Both are named in
    ///         final-criticals-report.md as the follow-up.
    /// @dev DELETE THIS TEST when the attestation gains a sign or the close stops being open-loop.
    ///      It exists to keep the gap visible and to fail loudly if someone "fixes" the direction
    ///      without fixing the data model.
    function test_zeroSupplyTrimCannotCloseADanglingShort() public {
        uint256 id = _drainThenRequestPastWindow();

        // Governance winds the vault down: the position goes flat and the margin stays put.
        vm.prank(gov);
        vault.closeAll();
        lighter.settleBatch();
        assertEq(lighter.positionBase(MARKET), 0, "closeAll did not flatten");

        // Now a stranger stages the refund. The open-loop ASK has nothing to close, so it OPENS a
        // short of exactly the size requestMint once went long.
        vault.stageRefund(id);
        lighter.settleBatch();
        assertEq(lighter.positionBase(MARKET), -HEDGE_TICKS, "the open-loop close did not open a short");
        assertEq(cert.totalSupply(), 0);

        // The attester can only report the MAGNITUDE, so the vault reads this identically to the
        // dangling long above and sells again.
        uint256 magnitude18 = uint256(HEDGE_TICKS) * PX / (10 ** 4);
        vm.prank(attester);
        reg.attest(address(vault), 2, magnitude18, 0, 1_190_000e18);
        assertEq(vault.solvency().deltaBps, vault.DELTA_UNBOUNDED_BPS());

        vault.rebalance();
        (, uint48 baseAmount,, uint8 isAsk,) = lighter.lastOrder();
        assertEq(isAsk, 1, "the trim is a SELL, which is the gap");
        assertGt(baseAmount, 0);

        // And it makes the short bigger, not smaller. Asserted so nobody has to take the report's
        // word for it. The mock's own margin check is what stops it in the end, not the vault.
        lighter.settleBatch();
        assertLt(lighter.positionBase(MARKET), -HEDGE_TICKS, "the short did not grow, re-check this gap");
    }

    // ---------------------------------------------------------------------------------------
    // M-3 (MEDIUM, external C1 audit). closeAll() hardcoded SIDE_ASK while `baseAmount == 0`
    // defaults to the full position SIZE and leaves the direction to the caller — so against a
    // SHORT the governance wind-down of last resort submitted a full-size sell and DOUBLED it.
    // The vault can genuinely be short, and this file already builds that state:
    // test_zeroSupplyTrimCannotCloseADanglingShort reaches it through closeAll() then a staged
    // refund whose open-loop ASK has nothing left to close.
    //
    // MockLighter now models the direction faithfully (see its settleBatch and
    // test_zeroBaseAmountAskAgainstAShortDoublesIt), which is what makes these two observable.
    // ---------------------------------------------------------------------------------------

    /// @dev Reaches the dangling-SHORT state, exactly as test_zeroSupplyTrimCannotCloseADanglingShort
    ///      does: wind the long down first, then stage a refund whose open-loop ASK opens a short of
    ///      precisely the size requestMint once went long.
    function _danglingShort() internal {
        uint256 id = _drainThenRequestPastWindow();

        vm.prank(gov);
        vault.closeAll(); // ledger is long here, so this is an ASK and it flattens
        lighter.settleBatch();
        assertEq(lighter.positionBase(MARKET), 0, "closeAll did not flatten the long");
        assertEq(vault.venuePositionBase(), 0, "the ledger did not follow the close");

        vault.stageRefund(id);
        lighter.settleBatch();
        assertEq(lighter.positionBase(MARKET), -HEDGE_TICKS, "the open-loop close did not open a short");
        assertEq(vault.venuePositionBase(), -HEDGE_TICKS, "the ledger did not follow the short");
        assertEq(cert.totalSupply(), 0);
    }

    /// @notice The finding itself: closeAll() must close a short, not double it.
    /// @dev LOAD-BEARING TWICE, and both were measured rather than reasoned about.
    ///      (1) Restore `SIDE_ASK` in closeAll(): this fails on the ClosedAll event, then on
    ///          `isAsk`, and with both of those assertions removed it fails on
    ///          MockLighter.InsufficientMargin() at settleBatch — the venue's own initial-margin
    ///          requirement refuses to fill a doubling of the short in THIS state, so the concrete
    ///          consequence here is a wind-down that does not wind anything down. Where margin does
    ///          permit the fill the position doubles outright; that is pinned separately and
    ///          unambiguously by MockLighter.t.sol's test_zeroBaseAmountAskAgainstAShortDoublesIt.
    ///          Either way the governance function of last resort fails to get flat.
    ///      (2) Restore `resulting = 0` for `baseAmount == 0` in MockLighter: the isAsk assertion
    ///          still fails, but the POSITION assertion passes — which is exactly why the mock had
    ///          to be fixed first. Without it the venue-side consequence of the wrong side is
    ///          invisible and the suite certifies a wind-down the venue would not perform.
    function test_closeAllClosesAShortInsteadOfDoublingIt() public {
        _danglingShort();

        vm.expectEmit(true, true, true, true, address(vault));
        emit CertVault.ClosedAll(0, -HEDGE_TICKS); // 0 == SIDE_BID, derived from the ledger
        vm.prank(gov);
        vault.closeAll();

        (, uint48 baseAmount,, uint8 isAsk,) = lighter.lastOrder();
        assertEq(baseAmount, 0, "closeAll stopped using the full-size primitive");
        assertEq(isAsk, 0, "closeAll still hardcodes the sell side");

        lighter.settleBatch();
        assertEq(lighter.positionBase(MARKET), 0, "the wind-down did not flatten the short");
        assertEq(vault.venuePositionBase(), 0, "the ledger was not reset by the close");
    }

    /// @notice And it still closes a LONG with an ASK — the direction is derived, not inverted.
    function test_closeAllStillClosesALongWithAnAsk() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();
        int256 known = vault.venuePositionBase();
        assertGt(known, 0, "the ledger did not record the mint hedge");
        assertEq(lighter.positionBase(MARKET), known, "the ledger and the venue disagree");

        vm.expectEmit(true, true, true, true, address(vault));
        emit CertVault.ClosedAll(1, known); // 1 == SIDE_ASK
        vm.prank(gov);
        vault.closeAll();

        (,,, uint8 isAsk,) = lighter.lastOrder();
        assertEq(isAsk, 1);
        lighter.settleBatch();
        assertEq(lighter.positionBase(MARKET), 0);
    }

    /// @notice At a flat ledger closeAll() FAILS CLOSED: it submits no directional order and still
    ///         repatriates. Reverting instead would remove the wind-down in the state where the
    ///         position is already on its way to zero (see test_windDownRecoversAllMargin).
    function test_closeAllSubmitsNothingWhenTheLedgerIsFlat() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();
        uint256 bal = cert.balanceOf(alice);

        // The exit's own ASK is submitted but not yet filled: the vault is net flat on its own
        // books while the venue still shows the long.
        vm.prank(alice);
        vault.forceExit(bal);
        assertEq(vault.venuePositionBase(), 0, "the exit did not bring the ledger back to flat");
        assertGt(lighter.positionBase(MARKET), 0, "the venue was supposed to still be lagging");

        uint256 queuedBefore = lighter.queuedOrderCount();
        vm.expectEmit(true, true, true, true, address(vault));
        emit CertVault.CloseAllSkippedFlat();
        vm.prank(gov);
        vault.closeAll(); // must not revert: the repatriation half is unconditional

        assertEq(lighter.queuedOrderCount(), queuedBefore, "a directional order was guessed anyway");
        // The queued exit still flattens the venue on its own, which is why skipping is correct.
        lighter.settleBatch();
        assertEq(lighter.positionBase(MARKET), 0, "the exit's own close did not flatten the venue");
    }
}
