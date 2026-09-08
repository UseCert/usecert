// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {VaultHandler} from "./VaultHandler.sol";
import {VaultFixture} from "../helpers/VaultFixture.sol";
import {CertVault} from "../../src/CertVault.sol";

/// @notice Task 12: proves under randomised call sequences the properties the whole design rests
///         on — Law 2 (redemption is never gated) and supply integrity — plus a third added for
///         the margin-split work: margin conservation. See foundry.toml's
///         [profile.default.invariant] for runs = 256, depth = 32, fail_on_revert = false.
///         fail_on_revert = false means VaultHandler itself is responsible for telling an
///         acceptable revert from a real violation; the fuzzer does not fail a run on a revert by
///         itself, so every invariant here checks a ground-truth counter the handler maintains,
///         never "did anything revert".
///
///         Task 12 review fix (see task-12-report.md's appended "Fix report"): a fourth property,
///         `invariant_capacityNeverExceedsAbsoluteCap`, has been replaced below by a plain
///         `test_capacityNeverExceedsAbsoluteCap` — see that function's NatSpec for why it is not
///         a fuzz-worthy stateful property with this fixture. Three directed regression tests were
///         also added (`test_mintInstantCanHitCapacity`,
///         `test_rebalanceInBandIsReachableAtZeroSupplyWithNoPosition` — renamed from
///         `test_rebalanceCanHitInBandAtZeroSupply` by CRITICAL A, which narrowed when zero supply
///         is legitimately in band — and `test_redeemSurvivesNegativeBuffer`) as deterministic,
///         always-reproducible proof that
///         the branches Finding 1 flagged as unreachable are now genuinely reachable — the fuzz
///         campaign itself reaches them too (see the Fix report's console-log evidence), but a
///         fuzz hit is seed-dependent, so these directed tests are the durable regression guard.
contract BackingInvariantTest is VaultFixture {
    VaultHandler handler;

    /// @notice The vault's own capital at the start of the campaign — the fixture's 100_000e6
    ///         buffer seed, less the bootstrap dust, all of it still on the venue or in the vault.
    ///         invariant_backingCoversSupply requires this to survive on top of the certificate
    ///         obligation, so the seed can never be counted as certificate backing.
    uint256 internal startingCapital18;

    /// @dev VaultFixture.setUp() already builds the stack, seeds the buffer, bootstraps and
    ///      settles. Extend it, do not rebuild it.
    function setUp() public override {
        super.setUp();
        handler = new VaultHandler(vault, usdg, lighter, reg, cap, attester, gov);
        targetContract(address(handler));
        startingCapital18 = _venueBacking18();
        assertEq(cert.totalSupply(), 0, "the campaign must start with nothing outstanding");
    }

    /// @notice Law 2, expressed as an invariant: every non-zero redemption attempt the handler
    ///         made against certificates it actually held succeeded through SOME path (instant,
    ///         queued, or the force-exit backstop), including the queued path's final payout.
    function invariant_redemptionNeverBlockedByBuffer() public view {
        assertEq(handler.lawTwoViolations(), 0);
    }

    /// @notice LAW 1, the design's first law and the property spec §13 promised and this suite
    ///         never asserted: the certificates outstanding must be covered by value the vault and
    ///         the venue actually hold, and never by the vault's own starting capital.
    ///
    ///         Measured against VENUE GROUND TRUTH, the way test_A6_lawOneBreachedAgainstVenue-
    ///         GroundTruth does it: nothing here reads postedMargin, marginPendingRecall,
    ///         SolvencyRegistry's attestation, BufferBook's ledger, or any figure the vault
    ///         computed for itself. Backing is the vault's real ERC20 balance plus what MockLighter
    ///         actually holds for it — cash margin, the position's mark-to-market gain or loss, and
    ///         any withdrawal the venue has credited but not yet released.
    ///
    /// @dev THE FORM MATTERS, and the literal reading of Law 1 does not work. Written as the design
    ///      states it — `supply x px <= position notional + margin` (plus the vault's own
    ///      collateral) — this invariant is unfalsifiable, and it was MEASURED so before being
    ///      replaced: a full 256x32 campaign passed it while
    ///      invariant_supplyMatchesMintedMinusBurned was failing on a two-call over-mint. The
    ///      reason is double counting. The margin is what BOUGHT the notional, so at
    ///      targetMarginBps = 9_000 the sum `notional + margin` is about 1.9x the collateral that
    ///      actually came in, and no over-mint the capacity cap can admit will ever eat that much
    ///      slack. So backing is measured here as value, not as value plus the exposure bought
    ///      with it: cash at the vault, cash at the venue, and the position's PnL (which is what
    ///      makes the hedge show up — an under-hedged book fails this as soon as the price moves,
    ///      which is exactly the risk Law 1 exists to bound).
    ///
    ///      The second reason the literal form cannot bite is the fixture's own 100_000e6 buffer
    ///      seed. That capital is the vault's, not the certificate holders' — it is there to absorb
    ///      funding and basis — so counting it as certificate backing lets any over-mint smaller
    ///      than the seed hide behind it. `startingCapital18` is therefore required to survive
    ///      untouched on top of the obligation. It is captured from the live stack in setUp rather
    ///      than hardcoded, and it is deliberately NOT BufferBook's balance: accrueFunding() lets
    ///      the attester declare that number anything at all (see
    ///      test_A7_publishedBufferIsNotBackedByAnything), which would make this invariant a
    ///      measurement of the attester's honesty instead of the vault's solvency.
    function invariant_backingCoversSupply() public view {
        (uint256 px18,) = oracle.pxUnguarded();
        uint256 obligation18 = cert.totalSupply() * px18 / 1e18;
        assertGe(_venueBacking18(), startingCapital18 + obligation18, "LAW 1: backing must cover supply x px");
    }

    /// @dev Everything the vault and the venue actually hold for it, in 18 decimals. equity() is
    ///      MockLighter's own cash-plus-mark-to-market figure (M3); the pending balance is margin
    ///      the venue has debited but not yet released, which would otherwise read as a hole in
    ///      the backing for the window between recallMargin()'s request and its sweep.
    function _venueBacking18() internal view returns (uint256) {
        return _to18(usdg.balanceOf(address(vault))) + _to18(lighter.equity())
            + _to18(lighter.getPendingBalance(address(vault), ASSET_IDX));
    }

    /// @notice Certificate supply always equals what this run minted minus what it burned — no
    ///         certificate appears or disappears off-ledger across mint/settleMint/redeem/queued
    ///         exits.
    /// @dev The equality below measures the vault against its own transcript (VaultHandler
    ///      recorded whatever balance delta the vault produced), so no over-mint could ever
    ///      falsify it. The first assertion is the missing half: VaultHandler now also computes,
    ///      outside the vault, what each mint was entitled to — escrow over the price the hedge
    ///      was sized at — and accumulates every excess in overMintTotal.
    function invariant_supplyMatchesMintedMinusBurned() public view {
        assertEq(handler.overMintTotal(), 0, "a mint exceeded the certificates its hedge was sized for");
        assertEq(cert.totalSupply(), handler.totalMinted() - handler.totalBurned());
    }

    function _to18(uint256 amount) internal pure returns (uint256) {
        return amount * 1e12; // 6-decimal collateral
    }

    /// @notice Margin conservation: the vault can never be carrying more margin (posted, plus
    ///         allocated but not yet swept back for recall) than it has ever actually deposited to
    ///         the venue. This is the accounting invariant that three rejected margin-recall
    ///         designs failed (see CertVault._queueExit's and recallMargin()'s doc comments).
    ///         marginPendingRecall underflowing is covered implicitly: every subtraction against
    ///         it is checked arithmetic, so an underflow there would revert the call that caused
    ///         it — surfacing as a lawTwoViolations increment on the redeem side, not silent
    ///         corruption.
    /// @dev M-4 added a THIRD margin counter, marginExcess (margin freed by an instant redemption,
    ///      which no receipt will ever allocate — see CertVault). It is included in the sum here
    ///      deliberately rather than left out: redeemInstant fills it by TRANSFERRING out of
    ///      postedMargin, so including it leaves this assertion measuring exactly what it measured
    ///      before, while omitting it would have silently weakened the property — any margin moved
    ///      into the new counter would have stopped being counted at all, and this invariant would
    ///      have gone on passing while conserving less than its own name claims.
    function invariant_marginNeverExceedsDeposited() public view {
        assertLe(
            vault.postedMargin() + vault.marginPendingRecall() + vault.marginExcess(),
            handler.totalDepositedToVenue()
        );
    }

    /// @notice NOT an invariant (deliberately): `CapacityOracle.maxNotional18` computes
    ///         `min(depthBps * openInterest, absoluteCap18, bufferCapacity18)` — the `min` against
    ///         `absoluteCap18` itself means the result is `<= absoluteCap18` by construction, for
    ///         ANY inputs whatsoever. No sequence of attest()/setDepthBps()/accrueFunding() calls
    ///         this handler can make — no matter how the fuzzer drives oi, depthBps or the buffer —
    ///         can ever make this assertion fail; it is a mathematical identity about the formula,
    ///         not a reachability gap the way Finding 1's other three branches were.
    /// @dev Task 12 review, Finding 1's escape valve: "If invariant 4 still cannot be made to move
    ///      after this, replace it with a plain unit test and say plainly that it is not a
    ///      fuzz-worthy property with this fixture." It cannot be made to move — confirmed by
    ///      inspection of CapacityOracle.maxNotional18's source, not just by fuzzing failing to
    ///      falsify it — so here it is as what it actually is: one deterministic check against the
    ///      fixture's live values, kept only as a smoke test that the two contracts still agree on
    ///      calling convention. The property this used to gesture at (governance/attester inputs,
    ///      including a lying attester or extreme open interest, never push capacity above the
    ///      absolute cap) is already the subject of dedicated, thorough unit tests in
    ///      test/CapacityOracle.t.sol (test_absoluteCapBoundsALyingAttester,
    ///      test_extremeOpenInterestClampsInsteadOfReverting) — this function does not attempt to
    ///      duplicate that coverage.
    function test_capacityNeverExceedsAbsoluteCap() public view {
        uint256 max = cap.maxNotional18(address(vault), type(uint256).max);
        assertLe(max, cap.absoluteCap18(address(vault)));
    }

    // ----------------------------------------------------------------------------------------
    // Directed regression tests (Task 12 review, Finding 1): each proves, deterministically and
    // independent of fuzz seed, that a branch the review flagged as unreachable dead code is now
    // genuinely reachable through the handler's public surface. These complement, not replace,
    // the fuzz campaign's own (seed-dependent) hits on the same branches — see the Fix report.
    // ----------------------------------------------------------------------------------------

    /// @notice Proves CertVault_AtCapacity is reachable from mintInstant now that attest() can move
    ///         registry.latest(vault).openInterest18 away from the fixture's frozen setUp() value.
    ///         Attesting openInterest18 = 0 makes CapacityOracle.maxNotional18 return 0
    ///         unconditionally (its own early-return), so any non-zero mint notional exceeds it.
    function test_mintInstantCanHitCapacity() public {
        assertEq(handler.mintAtCapacityCount(), 0);
        handler.attest(0, 0, 0); // openInterest18 = 0 => maxNotional18 = 0 for this asset
        handler.mintInstant(5_000e6);
        assertEq(handler.mintAtCapacityCount(), 1, "CertVault_AtCapacity did not fire");
        assertEq(handler.totalMinted(), 0, "a capacity-gated mint must not have minted anything");
    }

    /// @notice Proves CertVault_InBand is reachable from rebalance() now that the handler
    ///         exercises it at all — the reachability half of what
    ///         `test_rebalanceCanHitInBandAtZeroSupply` used to cover, kept here so the handler's
    ///         `rebalanceInBandCount` branch does not become dead when CRITICAL A's fix narrows
    ///         the zero-supply case.
    /// @dev The old NatSpec stated the reason as "deltaBps = 10_000 whenever supply == 0", which
    ///      was CRITICAL A itself. The correct reason is narrower and is asserted below: nothing
    ///      outstanding AND nothing attested. A fresh handler is in that state because the
    ///      fixture's setUp() attests notional18 = 0. With a non-zero attested notional at zero
    ///      supply, rebalance() must NOT be in band — see
    ///      test_rebalanceTrimsDanglingPositionAtZeroSupply.
    function test_rebalanceInBandIsReachableAtZeroSupplyWithNoPosition() public {
        assertEq(cert.totalSupply(), 0);
        // Assert the real precondition, so a fixture change cannot make this test vacuous the way
        // the "supply == 0 is enough" reading of it silently was.
        assertEq(reg.latest(address(vault)).notional18, 0, "there is an attested position after all");
        assertEq(vault.solvency().deltaBps, 10_000);

        assertEq(handler.rebalanceInBandCount(), 0);
        handler.rebalance();
        assertEq(handler.rebalanceInBandCount(), 1, "CertVault_InBand did not fire");
    }

    /// @notice CRITICAL A. `_solvency` reported `deltaBps = 10_000` — dead centre of the
    ///         [9_900, 10_100] band, i.e. perfectly hedged — for ANY state with `required == 0`,
    ///         including zero certificates outstanding against a live position. That is backwards:
    ///         a position with no obligation behind it is pure unhedged directional risk, the
    ///         single worst state the vault can be in, and it must be maximally OUT of band. The
    ///         consequence was not cosmetic: `rebalance()` reverted CertVault_InBand at exactly
    ///         the moment a trim was needed, `forceExit`/`requestRedeem` need certificates and
    ///         there were none, and `stageRefund` is once-only — so governance's `closeAll()` was
    ///         the ONLY escape, while the venue's initial-margin lock on the unwanted position
    ///         blocked the very margin recall a refund depends on.
    ///
    ///         Replaces `test_rebalanceCanHitInBandAtZeroSupply`, which asserted the reachability
    ///         of CertVault_InBand from a state that only *incidentally* satisfied it (the
    ///         fixture attests notional18 = 0) while its NatSpec claimed the buggy rule. The
    ///         reachability coverage it really provided is preserved above; this is what should
    ///         have been true instead.
    /// @dev LOAD-BEARING: with `_solvency`'s `required == 0` branch restored to an unconditional
    ///      10_000, this test fails at the first rebalance() with
    ///      `CertVault_InBand()` — measured, see final-criticals-report.md.
    function test_rebalanceTrimsDanglingPositionAtZeroSupply() public {
        handler.mintInstant(5_000e6);
        handler.settleBatch();
        uint256 minted = cert.balanceOf(address(handler));
        assertGt(minted, 0);
        int256 dangling = lighter.positionBase(MARKET);
        assertGt(dangling, 0, "no position was opened to dangle");

        // Strand the position at zero supply. The exit's closing order has to be UNPLACEABLE for
        // that: px18 = 1e15 makes CertOracle.toTickPrice floor its tick to 0 and revert
        // CertOracle_TickOverflow inside _tryHedge, which is fail-open (Law 2), so the burn and
        // the receipt stand while the venue-side position does not move. This is precisely the
        // state CertVault's own CloseOrderNotPlaced event exists to record (see
        // test_forceExitSurvivesUnplaceableCloseOrder), not a manufactured one.
        feed.set(1e5, block.timestamp); // 8 feed decimals -> px18 = 1e15
        handler.forceExit(minted);
        assertEq(handler.lawTwoViolations(), 0, "forceExit itself was blocked");
        assertEq(cert.totalSupply(), 0, "supply is not zero");
        assertEq(lighter.positionBase(MARKET), dangling, "the position closed after all");

        _setPrice(PX); // a usable price again, so rebalance()'s own order can be placed

        // Attest that dangling notional truthfully. This is the state the fix is about.
        uint256 notional18 = uint256(dangling) * PX / (10 ** 4); // sizeDecimals = 4
        vm.prank(attester);
        reg.attest(address(vault), 2, notional18, 3_600e18, 1_190_000e18);
        assertEq(
            vault.solvency().deltaBps,
            vault.DELTA_UNBOUNDED_BPS(),
            "a live position against a zero obligation still reads as in band"
        );

        // Permissionless (Law 6): a stranger with no certificates and no collateral trims it.
        vm.prank(makeAddr("danglingTrimmer"));
        vault.rebalance();
        (, uint48 baseAmount,, uint8 isAsk,) = lighter.lastOrder();
        assertEq(isAsk, 1, "the trim was not a SELL");
        assertGt(baseAmount, 0, "a zero baseAmount is the venue's close-all primitive");
        lighter.settleBatch();

        int256 afterFirst = lighter.positionBase(MARKET);
        assertLt(afterFirst, dangling, "the position was not trimmed");
        assertGe(afterFirst, 0, "the trim overshot through flat into a short");

        // Convergence, across a SECOND attested batch: the next attestation reports the smaller
        // remainder, the next trim takes it, and the sequence ends flat rather than oscillating.
        // Bounded per batch by MAX_REBALANCE_NOTIONAL_18 as always, so this loop is what "walk it
        // to flat one batch at a time" actually looks like.
        uint64 batchId = 3;
        for (uint256 i = 0; i < 8 && lighter.positionBase(MARKET) != 0; ++i) {
            uint256 remaining18 = uint256(lighter.positionBase(MARKET)) * PX / (10 ** 4);
            vm.prank(attester);
            reg.attest(address(vault), batchId++, remaining18, 3_600e18, 1_190_000e18);
            vm.prank(makeAddr("danglingTrimmer"));
            try vault.rebalance() {
                lighter.settleBatch();
            } catch (bytes memory reason) {
                // The only acceptable stop is the dust guard: a remainder too small to trade.
                assertEq(bytes4(reason), CertVault.CertVault_InBand.selector, "rebalance stopped for the wrong reason");
                break;
            }
        }
        assertEq(lighter.positionBase(MARKET), 0, "the dangling position never reached flat");

        // And once flat, a truthful attestation puts the vault back in band: it stops, it does
        // not keep selling into a short.
        vm.prank(attester);
        reg.attest(address(vault), 99, 0, 3_600e18, 1_190_000e18);
        assertEq(vault.solvency().deltaBps, 10_000);
        vm.expectRevert(CertVault.CertVault_InBand.selector);
        vault.rebalance();

        // No governance call anywhere above (Law 6): closeAll() was never needed.
        assertEq(handler.lawTwoViolations(), 0);
    }

    /// @notice The headline invariant is named invariant_redemptionNeverBlockedByBuffer, but
    ///         without accrueFunding() the BufferBook ledger never leaves the fixture's seeded
    ///         +100_000e18, so the invariant never actually tests its own namesake. This drives it
    ///         deeply negative (three calls, each clamped to -200_000e18, well past the
    ///         insuranceDraw18 = 0 / mintSlow18 = 30_000e18 / feeOn18 = 60_000e18 / floor18 =
    ///         100_000e18 thresholds) and then proves every redemption entry point still succeeds —
    ///         confirming what reading CertVault.sol shows: hotBuffer() (redeemInstant's own gate)
    ///         reads the vault's real ERC20 balance, not BufferBook's ledger, and _queueExit
    ///         (requestRedeem/forceExit) and claimRedeem read BufferBook not at all.
    function test_redeemSurvivesNegativeBuffer() public {
        handler.mintInstant(5_000e6);
        uint256 minted = cert.balanceOf(address(handler));
        assertGt(minted, 0);

        handler.accrueFunding(type(int256).min); // clamped to -200_000e18
        handler.accrueFunding(type(int256).min); // -400_000e18 cumulative
        handler.accrueFunding(type(int256).min); // -600_000e18 cumulative
        assertLt(book.balance18(address(vault)), 0, "buffer did not actually go negative");

        assertEq(handler.lawTwoViolations(), 0);
        handler.forceExit(minted);
        assertEq(handler.lawTwoViolations(), 0, "forceExit was blocked by a negative buffer");
    }

    // ----------------------------------------------------------------------------------------
    // Final review wave: the same directed-regression treatment for the two new revert branches
    // this handler has to tell apart from a real violation. Both are deterministic here rather
    // than left to a fuzz seed, for the same reason the three above are.
    // ----------------------------------------------------------------------------------------

    /// @notice M2: claimRedeem's CertVault_AwaitingSettlement must be understood by this handler
    ///         as a retryable "not yet" and NOT as a Law 2 violation — which is only legitimate
    ///         because the receipt survives untouched and does eventually pay. This proves both
    ///         halves; the first assertion alone would not be enough.
    function test_claimAwaitingSettlementIsRetryableNotAViolation() public {
        handler.mintInstant(5_000e6);
        uint256 minted = cert.balanceOf(address(handler));
        assertGt(minted, 0);
        handler.forceExit(minted);
        _drainHotBuffer(); // the vault cannot pay out of its own balance right now

        assertEq(handler.claimAwaitingSettlementCount(), 0);
        handler.claimRedeem(0);
        assertEq(handler.claimAwaitingSettlementCount(), 1, "CertVault_AwaitingSettlement did not fire");
        assertEq(handler.lawTwoViolations(), 0, "a retryable not-yet was counted as a violation");

        // Now let the funds arrive through permissionless paths and claim the SAME receipt.
        lighter.settleBatch(); // the close fills at the venue
        handler.recallMargin(); // submits
        handler.recallMargin(); // sweeps
        vault.seedBuffer(1_000e6); // permissionless top-up for the drained remainder

        uint256 before = usdg.balanceOf(address(handler));
        handler.claimRedeem(0);
        assertGt(usdg.balanceOf(address(handler)), before, "the receipt never actually paid");
        assertEq(handler.lawTwoViolations(), 0);
        assertEq(handler.claimAwaitingSettlementCount(), 1, "the retry did not succeed");
    }

    /// @notice The mint-side twin of the test above, for the two-phase refund. The handler's
    ///         refundMint catch used to be bare, which would have accepted "this escrow can never
    ///         be paid" as indistinguishable from "not yet" — the exact reason a permanently
    ///         strandable refund could ship past this suite. It now accepts only
    ///         CertVault_RefundAwaitingSettlement, and this proves both halves: the retryable
    ///         revert is not counted as a violation, AND the same receipt does eventually pay.
    /// @dev Directed rather than fuzzed for a reason worth stating: the invariant fuzzer barely
    ///      advances block.timestamp across a run, so settleWindow (1 day) never expires under
    ///      fuzzing and neither refund action gets past its "window still open" filter. That is a
    ///      pre-existing property of this fixture, not new here — settleMintWindowExpiredCount has
    ///      never fired in a campaign either. These two directed tests are therefore the real
    ///      coverage of the refund branches, and the fuzzed actions are there so the branches
    ///      cannot silently stop being callable.
    function test_refundAwaitingSettlementIsRetryableNotAViolation() public {
        _drainHotBuffer(); // the vault cannot pay an escrow out of its own balance
        handler.requestMint(20_000e6); // escrow 19_980e6, of which 17_982e6 goes to the venue
        handler.settleBatch(); // the mint's own hedge fills
        vm.warp(block.timestamp + SETTLE_WINDOW + 1);

        assertEq(handler.stageRefundCount(), 0);
        handler.stageRefund(0);
        assertEq(handler.stageRefundCount(), 1, "phase 1 did not go through");
        assertEq(handler.lawTwoViolations(), 0);

        assertEq(handler.refundAwaitingSettlementCount(), 0);
        handler.refundMint(0);
        assertEq(handler.refundAwaitingSettlementCount(), 1, "CertVault_RefundAwaitingSettlement did not fire");
        assertEq(handler.lawTwoViolations(), 0, "a retryable not-yet was counted as a violation");
        assertEq(handler.refundMintCount(), 0);

        // Now let the funds arrive through the permissionless paths this handler already drives,
        // and refund the SAME receipt.
        handler.recallMargin(); // submits the withdrawal staging made askable-for
        handler.settleBatch(); // the staged hedge close fills
        handler.recallMargin(); // sweeps what the venue released

        uint256 before = usdg.balanceOf(address(handler));
        handler.refundMint(0);
        assertEq(handler.refundMintCount(), 1, "the receipt never actually refunded");
        assertEq(usdg.balanceOf(address(handler)) - before, 19_980e6, "the escrow was not returned in full");
        assertEq(handler.lawTwoViolations(), 0);
        assertEq(handler.refundAwaitingSettlementCount(), 1);
        assertEq(cert.totalSupply(), 0);
        assertEq(lighter.positionBase(MARKET), 0, "the refund left the vault long against nothing");
    }

    /// @notice refundMint before stageRefund is a sequencing signal, not a violation — and only
    ///         because staging is permanently available to anyone. Proves the handler tells the
    ///         two apart, and that the receipt is not abandoned in the meantime.
    function test_refundNotStagedIsRecognisedAndNotAViolation() public {
        handler.requestMint(20_000e6);
        handler.settleBatch();
        vm.warp(block.timestamp + SETTLE_WINDOW + 1);

        assertEq(handler.refundNotStagedCount(), 0);
        handler.refundMint(0);
        assertEq(handler.refundNotStagedCount(), 1, "the unstaged branch was not recognised");
        assertEq(handler.lawTwoViolations(), 0);
        assertEq(handler.refundMintCount(), 0);

        // The route out is one permissionless call, and then the refund goes through: the fixture's
        // buffer is untouched here, so no recall is even needed.
        handler.stageRefund(0);
        handler.refundMint(0);
        assertEq(handler.refundMintCount(), 1);
        assertEq(handler.lawTwoViolations(), 0);
    }

    /// @notice C2: rebalance()'s per-batch bound is reachable through the handler's own surface,
    ///         and is not a Law 2 path.
    function test_rebalanceAlreadyThisBatchIsReachable() public {
        handler.mintInstant(5_000e6);
        assertGt(cert.totalSupply(), 0);
        handler.attest(type(uint256).max, 0, 0); // fresh batch, notional 0 -> far out of band

        assertEq(handler.rebalanceAlreadyThisBatchCount(), 0);
        handler.rebalance(); // acts on the new batch
        assertEq(handler.rebalanceAlreadyThisBatchCount(), 0, "the first call should have acted");
        handler.rebalance(); // same batch: refused
        assertEq(handler.rebalanceAlreadyThisBatchCount(), 1, "CertVault_AlreadyRebalancedThisBatch did not fire");

        handler.attest(type(uint256).max, 0, 0); // new information re-opens it
        handler.rebalance();
        assertEq(handler.rebalanceAlreadyThisBatchCount(), 1);
    }
}
