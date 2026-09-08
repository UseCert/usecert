// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CertOracle} from "../src/CertOracle.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

contract CertOracleTest is Test {
    CertOracle oracle;
    MockAggregatorV3 feed;
    address attester = makeAddr("attester");
    /// @dev No key, no role, no delay. Every pokeLastGood() below is pranked as this address, so
    ///      the H-1 fix is proven not to have bought its rate limit with an owner (Law 6).
    address stranger = makeAddr("stranger");

    // TSLA: price_decimals = 2, so 355.86 -> tick 35586
    uint256 constant PX = 355.86e18;
    uint256 constant STALENESS = 3600;
    uint256 constant DEVIATION_BPS = 500;

    function setUp() public {
        vm.warp(1_800_000_000);
        feed = new MockAggregatorV3(8, 355_86000000); // 8 decimals
        oracle = new CertOracle(address(feed), attester, 2, STALENESS, DEVIATION_BPS, 100);
        vm.prank(attester);
        oracle.setMarkPrice(PX);
    }

    /// @dev Moves the feed AND the attested mark together, so the basis band stays satisfied and
    ///      the deviation breaker is the only guard in play — mirroring VaultFixture._setPrice,
    ///      which is what AuditPoC's A-3 uses.
    function _movePrice(uint256 px18) internal {
        feed.set(int256(px18 / 1e10), block.timestamp); // feed has 8 decimals
        vm.prank(attester);
        oracle.setMarkPrice(px18);
    }

    /// @dev A NEW feed round at the price the feed is already reporting.
    function _refreshFeedRound() internal {
        feed.set(feed.answer(), block.timestamp);
    }

    function test_pxNormalisesFeedDecimalsTo18() public view {
        assertEq(oracle.px(), PX);
    }

    function test_stalePriceRevertsAndBlocksMint() public {
        vm.warp(block.timestamp + 3601);
        assertFalse(oracle.mintAllowed());
        vm.expectRevert(CertOracle.CertOracle_StalePrice.selector);
        oracle.px();
    }

    function test_pxUnguardedNeverRevertsWhenStale() public {
        // Record a known last-good value distinct from whatever the feed reports next.
        oracle.pokeLastGood();
        (uint256 lastGoodP, uint256 lastGoodT) = oracle.pxUnguarded();
        assertEq(lastGoodP, PX);

        // Now move the feed to a clearly different price AND make it stale, so the live
        // branch of pxUnguarded() (if it ran) would return a different value than last-good.
        feed.set(999_99000000, block.timestamp);
        vm.warp(block.timestamp + 3601);

        (uint256 p, uint256 t) = oracle.pxUnguarded();
        // If the staleness check were broken and the live branch ran, p would be 999.99e18.
        assertEq(p, lastGoodP);
        assertEq(t, lastGoodT);
        assertGt(t, 0);
    }

    function test_pxUnguardedNeverRevertsWhenFeedReverts() public {
        oracle.pokeLastGood();
        (uint256 lastGoodP, uint256 lastGoodT) = oracle.pxUnguarded();

        feed.setShouldRevert(true);

        (uint256 p, uint256 t) = oracle.pxUnguarded();
        assertEq(p, lastGoodP);
        assertEq(t, lastGoodT);
    }

    function test_basisBpsNeverRevertsWhenFeedReverts() public {
        feed.setShouldRevert(true);
        assertEq(oracle.basisBps(), 0);
    }

    function test_mintAllowedNeverRevertsWhenFeedReverts() public {
        feed.setShouldRevert(true);
        assertFalse(oracle.mintAllowed());
    }

    function test_nonPositivePriceReverts() public {
        feed.set(0, block.timestamp);
        vm.expectRevert(CertOracle.CertOracle_NonPositivePrice.selector);
        oracle.px();
    }

    function test_basisWithinBandAllowsMint() public {
        // mark 0.5% above index = 50 bps, band is 100 bps
        vm.prank(attester);
        oracle.setMarkPrice(PX * 1005 / 1000);
        assertEq(oracle.basisBps(), 50);
        assertTrue(oracle.mintAllowed());
    }

    function test_basisBeyondBandBlocksMintButNotRedeem() public {
        // mark 3% above index = 300 bps > 100 bps band
        vm.prank(attester);
        oracle.setMarkPrice(PX * 103 / 100);
        assertEq(oracle.basisBps(), 300);
        assertFalse(oracle.mintAllowed());

        // pxUnguarded stays available: redemption is never gated (Law 2)
        (uint256 p,) = oracle.pxUnguarded();
        assertEq(p, PX);
    }

    function test_toTickPriceAppliesPriceDecimals() public view {
        assertEq(oracle.toTickPrice(PX), 35586);
        assertEq(oracle.toTickPrice(1e18), 100);
    }

    function test_toTickPriceRevertsOnOverflow() public {
        vm.expectRevert(CertOracle.CertOracle_TickOverflow.selector);
        oracle.toTickPrice(type(uint256).max / 1e16);
    }

    function test_onlyAttesterSetsMarkPrice() public {
        vm.expectRevert(CertOracle.CertOracle_OnlyAttester.selector);
        oracle.setMarkPrice(1e18);
    }

    /// Finding 2 (Task 10 review): arithmetic in a try's success block is NOT covered by that
    /// try's own catch. _tryFeed()'s success block does
    /// `uint256(answer) / (10 ** (d - 18))` unguarded — a feed reporting decimals() >= 96 makes
    /// that exponentiation overflow uint256 and panic, uncaught, propagating through
    /// pxUnguarded()/basisBps()/mintAllowed(), all three of which are documented to never revert
    /// and are reachable from forceExit(). Construct a dedicated oracle+feed pair (a straight
    /// second CertOracle constructed directly against a decimals()=100 feed would itself panic
    /// in the constructor's own unguarded _readFeed() call, so establish a good last-good price
    /// first, then flip the SAME feed to the absurd decimals afterward via the mock's setter).
    function test_pxUnguardedSurvivesAbsurdFeedDecimals() public {
        MockAggregatorV3 absurdFeed = new MockAggregatorV3(8, 355_86000000);
        CertOracle absurdOracle = new CertOracle(address(absurdFeed), attester, 2, 3600, 500, 100);
        (uint256 lastGoodP,) = absurdOracle.pxUnguarded();
        assertEq(lastGoodP, PX); // sane construction established a real last-good price

        absurdFeed.setDecimals(100); // >= 96 -> 10 ** (d - 18) would overflow uint256

        (uint256 p, uint256 t) = absurdOracle.pxUnguarded();
        assertEq(p, lastGoodP); // falls back to last-good, does not panic
        assertGt(t, 0);

        assertEq(absurdOracle.basisBps(), 0); // must not revert either
        assertFalse(absurdOracle.mintAllowed()); // unusable feed -> minting must not be allowed
    }

    // ---------------------------------------------------------------------------------------
    // CRITICAL B (C1 final review): `block.timestamp - t` sat inside the SUCCESS block of
    // _tryFeed's `try feed.latestRoundData()`, which that try's own catch does not cover. A feed
    // reporting an `updatedAt` in the FUTURE underflowed it, panicked (0x11), and propagated
    // uncaught through _tryFeed() -> pxUnguarded() -> CertVault._queueExit -> forceExit — the
    // protocol's last-resort backstop (Law 2) — while the lastGoodPx18 fallback that exists for
    // exactly this case sat two lines away, unreachable. Both `feed` here and `oracle` in
    // CertVault are immutable, so there was no swapping out of it.
    // ---------------------------------------------------------------------------------------

    /// @notice The Law 2 half: a future feed timestamp must be treated as a malfunctioning feed
    ///         (unusable), NOT as "fresher than fresh", so every documented-never-reverts reader
    ///         falls back cleanly. All three of pxUnguarded(), basisBps() and mintAllowed() are
    ///         asserted, because all three go through _tryFeed and all three claim never to
    ///         revert.
    function test_pxUnguardedSurvivesFutureFeedTimestamp() public {
        // Record a known last-good value first, so a live-branch answer would be distinguishable.
        oracle.pokeLastGood();
        (uint256 lastGoodP, uint256 lastGoodT) = oracle.pxUnguarded();
        assertEq(lastGoodP, PX);
        assertGt(lastGoodT, 0);

        // A clearly different price AND an updatedAt one day in the future. If the guard were
        // absent this underflows; if the guard were wrong (e.g. treating the future as fresh),
        // p would come back as 999.99e18 instead of last-good.
        feed.set(999_99000000, block.timestamp + 1 days);

        (uint256 p, uint256 t) = oracle.pxUnguarded();
        assertEq(p, lastGoodP, "pxUnguarded did not fall back to last-good");
        assertEq(t, lastGoodT);

        assertEq(oracle.basisBps(), 0, "basisBps must not revert on a future timestamp");
        assertFalse(oracle.mintAllowed(), "a malfunctioning feed must not permit minting");

        // pokeLastGood must not be able to record the malfunctioning feed either — otherwise
        // lastGoodAt itself could be set into the future and poison the fallback.
        vm.expectRevert(CertOracle.CertOracle_StalePrice.selector);
        oracle.pokeLastGood();
        (, uint256 tAfter) = oracle.pxUnguarded();
        assertEq(tAfter, lastGoodT, "a future-timestamped feed contaminated last-good");
    }

    /// @notice The other half: px() is *supposed* to revert on a malfunctioning feed (it backs
    ///         minting, which must be gated), but it must revert with the NAMED error callers can
    ///         switch on rather than with an anonymous arithmetic panic. `vm.expectRevert` with a
    ///         selector does not match a Panic, so this assertion is what makes the guard in
    ///         px() load-bearing.
    function test_pxRevertsNamedErrorOnFutureTimestamp() public {
        feed.set(int256(355_86000000), block.timestamp + 1 days);
        vm.expectRevert(CertOracle.CertOracle_StalePrice.selector);
        oracle.px();
    }

    /// @notice CRITICAL B re-audit of the same success block: the `d > 36` bound makes the
    ///         exponentiation safe, but `uint256(answer) * (10 ** (18 - d))` could still overflow
    ///         and panic uncaught in exactly the same position. int256's positive range reaches
    ///         ~5.8e76 and the multiplier is 1e18 at d = 0, so any answer above ~1.15e59 did it.
    ///         Same treatment as every other unusable feed: fall back, never panic.
    function test_pxUnguardedSurvivesAnAnswerTooLargeToNormalise() public {
        MockAggregatorV3 hugeFeed = new MockAggregatorV3(8, 355_86000000);
        CertOracle hugeOracle = new CertOracle(address(hugeFeed), attester, 2, 3600, 500, 100);
        (uint256 lastGoodP,) = hugeOracle.pxUnguarded();
        assertEq(lastGoodP, PX); // sane construction established a real last-good price

        // d = 0 -> multiplier 1e18; 2e59 * 1e18 > type(uint256).max (~1.16e77).
        hugeFeed.setDecimals(0);
        hugeFeed.set(2e59, block.timestamp);

        (uint256 p, uint256 t) = hugeOracle.pxUnguarded();
        assertEq(p, lastGoodP, "an unnormalisable answer did not fall back to last-good");
        assertGt(t, 0);
        assertEq(hugeOracle.basisBps(), 0);
        assertFalse(hugeOracle.mintAllowed());
    }

    // =======================================================================================
    // H-1 (High, C1 audit): pokeLastGood() disarmed the deviation circuit breaker.
    //
    // mintAllowed() pauses minting when the live price deviates from lastGoodPx18 by more than
    // deviationBps. pokeLastGood() was permissionless and wrote lastGoodPx18 = live price, so the
    // breaker's own reference was resettable, for gas, by the party it exists to stop —
    // atomically, in the mint's transaction. _tryFeed screens for staleness, positivity and
    // normalisability, never for deviation, so a post-jump price is "healthy" by that definition
    // and the poke laundered it into the reference.
    //
    // These tests are the oracle-level statement of AuditPoC's test_A3. That PoC cannot pass as
    // written — it needs mintAllowed() == true for its mintInstant() and false for its closing
    // assertion, in one block, with nothing in between that can write the feed, markPx18 or
    // lastGoodPx18 (no src/ code calls setMarkPrice or pokeLastGood). See the audit report.
    // =======================================================================================

    /// @notice The A-3 property itself: a single permissionless call must not clear a tripped
    ///         breaker. Measured with deviationBps = 500 and a genuine 6% move.
    function test_H1_pokeLastGoodCannotClearTheDeviationBreakerInOneCall() public {
        assertTrue(oracle.mintAllowed(), "precondition: minting open");
        assertEq(oracle.lastGoodPx18(), PX);

        _movePrice(PX * 106 / 100); // 600 bps > 500 bps
        assertFalse(oracle.mintAllowed(), "precondition: deviation breaker tripped");

        vm.prank(stranger);
        oracle.pokeLastGood();

        assertEq(oracle.lastGoodPx18(), PX, "the reference teleported onto the post-jump price");
        assertFalse(oracle.mintAllowed(), "PROPERTY: the breaker must not be clearable by its target");

        // Nor by repeating the call — nothing rate-limits how many pokes fit in one transaction,
        // which is why a per-call clamp alone would not have been a fix.
        vm.startPrank(stranger);
        for (uint256 i = 0; i < 5; i++) {
            vm.expectRevert(CertOracle.CertOracle_ReferenceRateLimited.selector);
            oracle.pokeLastGood();
        }
        vm.stopPrank();
        assertEq(oracle.lastGoodPx18(), PX, "a loop of pokes walked the reference");
        assertFalse(oracle.mintAllowed(), "PROPERTY: still shut after a poke loop");
    }

    /// @notice The other half: a move that is genuinely there is absorbed, in bounded steps, once
    ///         it has held for a full staleness window — and the confirming observation is
    ///         provably a DIFFERENT feed round than the arming one.
    function test_H1_referenceAdvancesOnlyAfterTheMoveHeldForAWindow() public {
        _movePrice(PX * 106 / 100);
        uint256 armedAt = block.timestamp;

        vm.prank(stranger);
        oracle.pokeLastGood(); // phase one: arm
        assertEq(oracle.pendingPx18(), PX * 106 / 100);
        assertEq(oracle.pendingSince(), armedAt);
        assertEq(oracle.lastGoodPx18(), PX, "arming must not advance the reference");

        // Exactly stalenessSeconds later the ARMING round is still fresh (the edge is `>`), so
        // this call could be served by the very same round it armed from. The strict comparison is
        // what refuses it.
        vm.warp(armedAt + STALENESS);
        vm.prank(stranger);
        vm.expectRevert(CertOracle.CertOracle_ReferenceRateLimited.selector);
        oracle.pokeLastGood();

        // One second later the arming round has aged out, so there is nothing to confirm against
        // until the feed speaks again. This is what makes "the price held" mean the feed
        // re-reported it rather than one round being read twice.
        vm.warp(armedAt + STALENESS + 1);
        vm.prank(stranger);
        vm.expectRevert(CertOracle.CertOracle_StalePrice.selector);
        oracle.pokeLastGood();

        _refreshFeedRound(); // the feed independently re-reports the same level
        vm.prank(stranger);
        oracle.pokeLastGood();

        // Advanced by at most deviationBps: 355.86 -> 373.653, not to the live 377.2116.
        uint256 clamped = PX + PX * DEVIATION_BPS / 10_000;
        assertEq(oracle.lastGoodPx18(), clamped, "advance was not clamped to deviationBps");
        assertEq(oracle.lastGoodAt(), block.timestamp, "lastGoodAt is the confirming feed round");
        // 377.2116 vs 373.653 is 95 bps, inside the band, so a real 6% repricing does reopen
        // minting — one window and two transactions later, not atomically.
        assertTrue(oracle.mintAllowed(), "a held repricing must eventually be absorbed");
    }

    /// @notice A move large enough not to fit in one clamped step leaves the breaker shut even
    ///         after the window: the reference chases at most deviationBps per window.
    function test_H1_advanceIsClampedSoALargeMoveTakesSeveralWindows() public {
        _movePrice(PX * 150 / 100); // +50%
        vm.prank(stranger);
        oracle.pokeLastGood(); // arm

        vm.warp(block.timestamp + STALENESS + 1);
        _refreshFeedRound();
        vm.prank(stranger);
        oracle.pokeLastGood(); // confirm one step

        assertEq(oracle.lastGoodPx18(), PX + PX * DEVIATION_BPS / 10_000);
        assertFalse(oracle.mintAllowed(), "one clamped step must not clear a 50% dislocation");

        // And the next step costs another full window: the confirm re-armed.
        vm.prank(stranger);
        vm.expectRevert(CertOracle.CertOracle_ReferenceRateLimited.selector);
        oracle.pokeLastGood();
    }

    /// @notice A price that does not hold never confirms: moving out of band relative to the
    ///         ARMED price re-arms from scratch, so a transient spike expires instead of being
    ///         laundered into the reference on the strength of an old timestamp.
    function test_H1_aMoveThatDoesNotHoldRestartsItsWindow() public {
        _movePrice(PX * 106 / 100);
        uint256 firstArm = block.timestamp;
        vm.prank(stranger);
        oracle.pokeLastGood();
        assertEq(oracle.pendingSince(), firstArm);

        // Half a window later the price has moved again, 660 bps away from the armed candidate.
        vm.warp(firstArm + STALENESS / 2);
        _movePrice(PX * 113 / 100);
        vm.prank(stranger);
        oracle.pokeLastGood();
        assertEq(oracle.pendingPx18(), PX * 113 / 100, "candidate was not replaced");
        assertEq(oracle.pendingSince(), block.timestamp, "the window did not restart");
        assertEq(oracle.lastGoodPx18(), PX, "reference moved on an unheld price");

        // Past the FIRST arming's window, but not the second's: still refused.
        vm.warp(firstArm + STALENESS + 1);
        _refreshFeedRound();
        vm.prank(stranger);
        vm.expectRevert(CertOracle.CertOracle_ReferenceRateLimited.selector);
        oracle.pokeLastGood();
        assertFalse(oracle.mintAllowed());
    }

    /// @notice A price back inside the band is still recorded immediately, with no waiting: the
    ///         breaker is not tripped on it, so nothing is being laundered — and lastGoodPx18 /
    ///         lastGoodAt are also pxUnguarded()'s fallback, so Law 2's snapshot has to stay
    ///         refreshable in normal operation. It also clears any armed candidate.
    function test_H1_inBandPokeStillRecordsImmediatelyAndClearsThePending() public {
        _movePrice(PX * 106 / 100);
        vm.prank(stranger);
        oracle.pokeLastGood(); // arms
        assertGt(oracle.pendingSince(), 0);

        _movePrice(PX * 102 / 100); // 200 bps, inside the band
        vm.prank(stranger);
        oracle.pokeLastGood();

        assertEq(oracle.lastGoodPx18(), PX * 102 / 100, "in-band poke must record at once");
        assertEq(oracle.lastGoodAt(), block.timestamp);
        assertEq(oracle.pendingSince(), 0, "a resolved dislocation must not stay armed");
        assertEq(oracle.pendingPx18(), 0);
        assertTrue(oracle.mintAllowed());
    }

    /// @notice pokeLastGood() accepted a price that _tryFeed reports as ok with px18 == 0 (a
    ///         high-decimals feed truncating on normalisation). Writing that into lastGoodPx18
    ///         would have switched the deviation breaker OFF entirely — mintAllowed() skips the
    ///         check when lastGoodPx18 == 0 — and poisoned pxUnguarded()'s fallback with a zero.
    function test_H1_pokeRejectsAPriceThatNormalisesToZero() public {
        MockAggregatorV3 tinyFeed = new MockAggregatorV3(19, 1); // 1 / 10 == 0
        CertOracle tinyOracle = new CertOracle(address(tinyFeed), attester, 2, STALENESS, DEVIATION_BPS, 100);
        vm.prank(attester);
        tinyOracle.setMarkPrice(PX);

        vm.prank(stranger);
        vm.expectRevert(CertOracle.CertOracle_StalePrice.selector);
        tinyOracle.pokeLastGood();
        assertFalse(tinyOracle.mintAllowed());
    }

    // =======================================================================================
    // L-4: lastGoodAt had two meanings — block.timestamp from the constructor, the feed's
    // updatedAt from pokeLastGood — and the constructor checked positivity but not staleness.
    // The feed-round meaning is the one that is kept, because pxUnguarded()'s live branch returns
    // the feed's own updatedAt and the fallback branch must be the same kind of number.
    // =======================================================================================

    function test_L4_lastGoodAtIsTheFeedRoundTimestampNotBlockTime() public {
        MockAggregatorV3 lagging = new MockAggregatorV3(8, 355_86000000);
        lagging.set(355_86000000, block.timestamp - 100); // fresh, but 100s behind the block
        CertOracle o = new CertOracle(address(lagging), attester, 2, STALENESS, DEVIATION_BPS, 100);

        assertEq(o.lastGoodAt(), block.timestamp - 100, "constructor recorded block time, not the round");
        assertTrue(o.lastGoodAt() != block.timestamp, "the two clocks must be distinguishable here");

        // And the fallback branch of pxUnguarded() reports the same kind of number as its live
        // branch, which is the whole point of picking one meaning.
        (, uint256 liveT) = o.pxUnguarded();
        assertEq(liveT, block.timestamp - 100);
        lagging.setShouldRevert(true);
        (, uint256 fallbackT) = o.pxUnguarded();
        assertEq(fallbackT, liveT, "fallback timestamp is not comparable with the live one");

        // pokeLastGood keeps the same meaning.
        lagging.setShouldRevert(false);
        vm.warp(block.timestamp + 10);
        lagging.set(355_86000000, block.timestamp - 5);
        vm.prank(stranger);
        o.pokeLastGood();
        assertEq(o.lastGoodAt(), block.timestamp - 5);
    }

    function test_L4_constructorRejectsAnAlreadyStaleFeed() public {
        MockAggregatorV3 dead = new MockAggregatorV3(8, 355_86000000);
        vm.warp(block.timestamp + STALENESS + 1);

        vm.expectRevert(CertOracle.CertOracle_StalePrice.selector);
        new CertOracle(address(dead), attester, 2, STALENESS, DEVIATION_BPS, 100);
    }

    function test_L4_constructorRejectsAFutureTimestampedFeed() public {
        MockAggregatorV3 ahead = new MockAggregatorV3(8, 355_86000000);
        ahead.set(355_86000000, block.timestamp + 1 days);

        // Named error, not the arithmetic panic an unguarded `block.timestamp - t` would give.
        vm.expectRevert(CertOracle.CertOracle_StalePrice.selector);
        new CertOracle(address(ahead), attester, 2, STALENESS, DEVIATION_BPS, 100);
    }

    // =======================================================================================
    // L-5: basisBps() returned 0 both for "the mark sits on the index" and for "the basis could
    // not be computed", so "no basis" read as "healthy" on any dashboard wired to it.
    // =======================================================================================

    function test_L5_basisBpsCheckedDistinguishesUnreadableFromAZeroBasis() public {
        // A real zero basis: mark == index.
        (bool known, uint256 bps) = oracle.basisBpsChecked();
        assertTrue(known, "a computable basis must report known");
        assertEq(bps, 0);
        assertEq(oracle.basisBps(), 0);

        // A real non-zero basis still comes back with its value.
        vm.prank(attester);
        oracle.setMarkPrice(PX * 1005 / 1000);
        (known, bps) = oracle.basisBpsChecked();
        assertTrue(known);
        assertEq(bps, 50);

        // Unreadable feed: same 0 from basisBps(), but no longer indistinguishable.
        feed.setShouldRevert(true);
        assertEq(oracle.basisBps(), 0, "basisBps must still never revert");
        (known, bps) = oracle.basisBpsChecked();
        assertFalse(known, "an unreadable feed must not read as a zero basis");
        assertEq(bps, 0);

        // Stale feed: likewise.
        feed.setShouldRevert(false);
        vm.warp(block.timestamp + STALENESS + 1);
        (known,) = oracle.basisBpsChecked();
        assertFalse(known, "a stale feed must not read as a zero basis");
    }

    function test_L5_basisIsUnknownBeforeAnyMarkIsAttested() public {
        MockAggregatorV3 f = new MockAggregatorV3(8, 355_86000000);
        CertOracle o = new CertOracle(address(f), attester, 2, STALENESS, DEVIATION_BPS, 100);

        assertEq(o.markPx18(), 0);
        assertEq(o.basisBps(), 0);
        (bool known,) = o.basisBpsChecked();
        assertFalse(known, "an unattested mark must not read as a zero basis");
    }

    function test_mintAllowedFalseWhenFeedTruncatesToZero() public {
        // 19 feed decimals with answer = 1 truncates to px18 = 1 / 10 = 0 on normalisation,
        // while _tryFeed() still reports ok = true. mintAllowed() must not divide by that zero.
        MockAggregatorV3 tinyFeed = new MockAggregatorV3(19, 1);
        CertOracle tinyOracle = new CertOracle(address(tinyFeed), attester, 2, 3600, 500, 100);
        vm.prank(attester);
        tinyOracle.setMarkPrice(PX);

        assertFalse(tinyOracle.mintAllowed());
    }
}
