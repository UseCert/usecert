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
    /// @dev Task 1: pokeLastGood's confirmation window, now its own immutable rather than a reuse
    ///      of STALENESS. Deliberately set EQUAL to STALENESS in this base fixture so every test
    ///      written against the old welded-together behaviour keeps measuring exactly what it
    ///      measured before; the tests that prove the two knobs are independent construct their
    ///      own oracle with different values.
    uint256 constant POKE_WINDOW = 3600;

    function setUp() public {
        vm.warp(1_800_000_000);
        feed = new MockAggregatorV3(8, 355_86000000); // 8 decimals
        oracle = new CertOracle(address(feed), attester, 2, STALENESS, DEVIATION_BPS, 100, POKE_WINDOW, false);
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
        CertOracle absurdOracle = new CertOracle(address(absurdFeed), attester, 2, 3600, 500, 100, POKE_WINDOW, false);
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
        CertOracle hugeOracle = new CertOracle(address(hugeFeed), attester, 2, 3600, 500, 100, POKE_WINDOW, false);
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
    ///         it has held for a full confirmation window — and the confirming observation is a
    ///         DIFFERENT feed round than the arming one.
    /// @dev Task 1 rewrote the prose in this test, not its assertions. The behaviour it measures is
    ///      unchanged because the base fixture sets POKE_WINDOW == STALENESS; what changed is WHY
    ///      each step is refused. Round distinctness used to be inferred from the timestamp
    ///      inequality and is now proven directly from roundId, so the comments below no longer
    ///      describe the mechanism they used to.
    function test_H1_referenceAdvancesOnlyAfterTheMoveHeldForAWindow() public {
        _movePrice(PX * 106 / 100);
        uint256 armedAt = block.timestamp;

        vm.prank(stranger);
        oracle.pokeLastGood(); // phase one: arm
        assertEq(oracle.pendingPx18(), PX * 106 / 100);
        assertEq(oracle.pendingSince(), armedAt);
        assertEq(oracle.lastGoodPx18(), PX, "arming must not advance the reference");

        // Exactly pokeConfirmationSeconds later the window has not ELAPSED — the edge is a strict
        // `>` — so the rate limit refuses it. (The roundId proof would refuse it too: the feed is
        // still serving the round that armed the candidate.)
        vm.warp(armedAt + POKE_WINDOW);
        vm.prank(stranger);
        vm.expectRevert(CertOracle.CertOracle_ReferenceRateLimited.selector);
        oracle.pokeLastGood();

        // One second later the window has elapsed, but here POKE_WINDOW == STALENESS, so the
        // arming round has aged out in the same breath and the feed is now unreadable. The poke
        // therefore fails earlier, on staleness, before either confirmation condition is reached.
        vm.warp(armedAt + STALENESS + 1);
        vm.prank(stranger);
        vm.expectRevert(CertOracle.CertOracle_StalePrice.selector);
        oracle.pokeLastGood();

        _refreshFeedRound(); // the feed independently re-reports the same level, in a NEW round
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
        CertOracle tinyOracle = new CertOracle(address(tinyFeed), attester, 2, STALENESS, DEVIATION_BPS, 100, POKE_WINDOW, false);
        vm.prank(attester);
        tinyOracle.setMarkPrice(PX);

        vm.prank(stranger);
        vm.expectRevert(CertOracle.CertOracle_StalePrice.selector);
        tinyOracle.pokeLastGood();
        assertFalse(tinyOracle.mintAllowed());
    }

    // =======================================================================================
    // Task 1. H-1's fix proved that a confirming feed observation was a different, fresher round
    // than its arming observation by an INFERENCE from timestamps:
    //   t_conf >= block.timestamp - stalenessSeconds > pendingSince >= t_arm
    // Sound, but it welded the breaker's rate limit to the feed-freshness bound. At the mainnet
    // stalenessSeconds of 93_600 (26 h) every clamped step cost 26 hours, so a 20% repricing kept
    // minting shut for ~4.3 days — a breaker outlasting the event it fired on.
    //
    // The round identity was available all along in latestRoundData()'s first member and the
    // contract discarded it. Distinctness is now ASSERTED (roundId > pendingRoundId) instead of
    // inferred, which frees the rate limit onto its own immutable, pokeConfirmationSeconds.
    // Both conditions remain necessary; the tests below pin each one down on its own.
    // =======================================================================================

    /// @dev TESTNET-PLAN.md §1's mainnet feed bound: 26 h, one hour past Chainlink's 24 h equity
    ///      heartbeat. The number that made the old welded rule unusable.
    uint256 internal constant MAINNET_STALENESS = 93_600;
    /// @dev The breaker's patience, as a risk tolerance rather than a heartbeat.
    uint256 internal constant HOUR_WINDOW = 3_600;

    /// @dev An oracle whose two time knobs DIFFER — which the base fixture cannot demonstrate,
    ///      since there POKE_WINDOW == STALENESS. Returns the feed too so the test can drive it.
    function _deployWithSplitWindows(uint256 staleness, uint256 window)
        internal
        returns (CertOracle o, MockAggregatorV3 f)
    {
        f = new MockAggregatorV3(8, 355_86000000);
        o = new CertOracle(address(f), attester, 2, staleness, DEVIATION_BPS, 100, window, false);
        vm.prank(attester);
        o.setMarkPrice(PX);
    }

    /// @dev _movePrice against an arbitrary pair; publishes a NEW feed round, as a live
    ///      aggregator does on every update.
    function _movePriceOn(CertOracle o, MockAggregatorV3 f, uint256 px18) internal {
        f.set(int256(px18 / 1e10), block.timestamp);
        vm.prank(attester);
        o.setMarkPrice(px18);
    }

    function test_pokeConfirmsOnNewRoundIdAfterWindow() public {
        _movePrice(PX * 106 / 100);
        uint80 armingRound = feed.roundId();

        vm.prank(stranger);
        oracle.pokeLastGood();
        assertEq(oracle.pendingRoundId(), armingRound, "the arming round id was not recorded");
        assertEq(oracle.lastGoodPx18(), PX, "arming must not advance the reference");

        vm.warp(block.timestamp + POKE_WINDOW + 1);
        _refreshFeedRound(); // the same price, in a new round
        assertEq(feed.roundId(), armingRound + 1, "precondition: the feed minted a new round");

        vm.prank(stranger);
        oracle.pokeLastGood();

        assertEq(
            oracle.lastGoodPx18(),
            PX + PX * DEVIATION_BPS / 10_000,
            "a new round after a full window must earn one clamped step"
        );
        assertEq(oracle.pendingRoundId(), armingRound + 1, "the confirm did not re-arm on the confirming round");
        assertEq(oracle.pendingSince(), block.timestamp, "the confirm did not restart the window");
    }

    /// @notice THE DISTINCTNESS PROOF, and the test that replaces the timestamp inequality. With
    ///         stalenessSeconds far wider than the confirmation window, time alone can no longer
    ///         prove the confirming observation is a new round — the old inference is simply gone.
    ///         Only roundId stands between a caller and confirming one round against itself.
    function test_pokeRejectsSameRoundIdEvenAfterWindow() public {
        (CertOracle o, MockAggregatorV3 f) = _deployWithSplitWindows(MAINNET_STALENESS, HOUR_WINDOW);
        _movePriceOn(o, f, PX * 106 / 100);
        uint80 armingRound = f.roundId();

        vm.prank(stranger);
        o.pokeLastGood();
        assertEq(o.pendingRoundId(), armingRound);
        assertEq(o.lastGoodPx18(), PX);

        // Twice the window, and still comfortably inside stalenessSeconds, so _tryFeed happily
        // serves the very round that armed the candidate.
        vm.warp(block.timestamp + 2 * HOUR_WINDOW);
        assertEq(f.roundId(), armingRound, "precondition: the feed has not re-reported");

        vm.prank(stranger);
        vm.expectRevert(CertOracle.CertOracle_ReferenceRoundNotAdvanced.selector);
        o.pokeLastGood();
        assertEq(o.lastGoodPx18(), PX, "PROPERTY: one round read twice must not confirm itself");
        assertFalse(o.mintAllowed(), "the breaker reopened on an unconfirmed dislocation");

        // Nor does a fresher TIMESTAMP inside the same round buy a confirmation. This is the exact
        // observation the old timestamp inference could not distinguish from a real new round.
        f.setSameRound(f.answer(), block.timestamp);
        vm.prank(stranger);
        vm.expectRevert(CertOracle.CertOracle_ReferenceRoundNotAdvanced.selector);
        o.pokeLastGood();
        assertEq(o.lastGoodPx18(), PX, "a re-timestamped round confirmed itself");

        // One genuine new round and the identical call goes through, so the two refusals above
        // were about round identity and nothing else in the state.
        f.set(f.answer(), block.timestamp);
        vm.prank(stranger);
        o.pokeLastGood();
        assertEq(o.lastGoodPx18(), PX + PX * DEVIATION_BPS / 10_000, "a real new round must confirm");
    }

    /// @notice Round distinctness is NECESSARY, not sufficient: the rate limit is the other half
    ///         of H-1 and a brand-new round does not shorten it.
    function test_pokeRejectsNewRoundIdBeforeWindow() public {
        _movePrice(PX * 106 / 100);
        uint256 armedAt = block.timestamp;
        uint80 armingRound = feed.roundId();
        vm.prank(stranger);
        oracle.pokeLastGood();

        vm.warp(armedAt + POKE_WINDOW / 2);
        _refreshFeedRound();
        assertGt(feed.roundId(), armingRound, "precondition: the feed did re-report");

        vm.prank(stranger);
        vm.expectRevert(CertOracle.CertOracle_ReferenceRateLimited.selector);
        oracle.pokeLastGood();
        assertEq(oracle.lastGoodPx18(), PX, "a new round inside the window advanced the reference");
        assertEq(oracle.pendingRoundId(), armingRound, "a refused poke must not re-arm");
        assertEq(oracle.pendingSince(), armedAt, "a refused poke must not restart the window");

        // The edge itself: at EXACTLY pokeConfirmationSeconds the window has not elapsed, because
        // the comparison is a strict `>`. A new round here is still refused.
        vm.warp(armedAt + POKE_WINDOW);
        _refreshFeedRound();
        vm.prank(stranger);
        vm.expectRevert(CertOracle.CertOracle_ReferenceRateLimited.selector);
        oracle.pokeLastGood();
        assertEq(oracle.lastGoodPx18(), PX, "the window edge is not strict");
    }

    /// @notice THE POINT OF THE TASK. The confirmation window and the feed-freshness bound are
    ///         independent immutables, so a held repricing is absorbed one hour after arming even
    ///         though the feed may legitimately be 26 hours old. Under the welded rule this same
    ///         call was refused for another 25 hours.
    function test_pokeWindowIsIndependentOfStaleness() public {
        (CertOracle o, MockAggregatorV3 f) = _deployWithSplitWindows(MAINNET_STALENESS, HOUR_WINDOW);
        assertEq(o.stalenessSeconds(), 93_600, "the mainnet feed bound must be untouched");
        assertEq(o.pokeConfirmationSeconds(), 3_600, "the breaker's window must be its own knob");

        _movePriceOn(o, f, PX * 106 / 100);
        uint256 armedAt = block.timestamp;
        vm.prank(stranger);
        o.pokeLastGood();
        assertEq(o.lastGoodPx18(), PX);

        // At exactly one hour: refused, the edge is strict.
        vm.warp(armedAt + 3_600);
        f.set(f.answer(), block.timestamp);
        vm.prank(stranger);
        vm.expectRevert(CertOracle.CertOracle_ReferenceRateLimited.selector);
        o.pokeLastGood();

        // One second past the hour: confirmed.
        vm.warp(armedAt + 3_601);
        f.set(f.answer(), block.timestamp);
        vm.prank(stranger);
        o.pokeLastGood();

        assertEq(block.timestamp - armedAt, 3_601, "the confirm did not land one hour after arming");
        assertLt(
            block.timestamp - armedAt,
            MAINNET_STALENESS,
            "the confirm was NOT inside one staleness window, so the knobs are still welded"
        );
        assertEq(o.lastGoodPx18(), PX + PX * DEVIATION_BPS / 10_000, "the clamped step did not happen");
        assertTrue(o.mintAllowed(), "a held 6% repricing must reopen minting in an hour, not in 26");
    }

    /// @notice A zero window would leave the roundId proof as the only gate, and that proof bounds
    ///         distinctness rather than rate — so every fresh round would buy another step. Refuse
    ///         it at deploy time rather than discover it live.
    function test_constructorRejectsZeroPokeWindow() public {
        MockAggregatorV3 f = new MockAggregatorV3(8, 355_86000000);

        vm.expectRevert(CertOracle.CertOracle_ConfigOutOfBounds.selector);
        new CertOracle(address(f), attester, 2, STALENESS, DEVIATION_BPS, 100, 0, false);

        // The identical deployment with a one-second window is accepted, so the refusal above is
        // about the zero and not about anything else in the argument list.
        CertOracle o = new CertOracle(address(f), attester, 2, STALENESS, DEVIATION_BPS, 100, 1, false);
        assertEq(o.pokeConfirmationSeconds(), 1);
    }

    /// @notice The re-arm-from-scratch behaviour must survive the rewrite: a price that keeps
    ///         moving never holds, so a transient spike expires instead of confirming — and it is
    ///         the WINDOW that refuses the follow-up poke, with the roundId proof already
    ///         satisfied. Both halves stay load-bearing.
    function test_transientSpikeStillExpires() public {
        _movePrice(PX * 106 / 100);
        uint256 firstArm = block.timestamp;
        vm.prank(stranger);
        oracle.pokeLastGood();
        uint80 firstRound = oracle.pendingRoundId();
        assertEq(oracle.pendingPx18(), PX * 106 / 100);

        // Half a window later the spike has kept going: 660 bps from the ARMED candidate.
        vm.warp(firstArm + POKE_WINDOW / 2);
        _movePrice(PX * 113 / 100);
        vm.prank(stranger);
        oracle.pokeLastGood();

        assertEq(oracle.lastGoodPx18(), PX, "the reference moved on a price that never held");
        assertEq(oracle.pendingPx18(), PX * 113 / 100, "the candidate was not replaced");
        assertEq(oracle.pendingSince(), block.timestamp, "the window did not restart");
        assertGt(oracle.pendingRoundId(), firstRound, "the round anchor did not move with the candidate");

        // Past the FIRST arming's window, with a brand-new round, so the distinctness proof is
        // satisfied. The re-armed window is what refuses it.
        vm.warp(firstArm + POKE_WINDOW + 1);
        _refreshFeedRound();
        vm.prank(stranger);
        vm.expectRevert(CertOracle.CertOracle_ReferenceRateLimited.selector);
        oracle.pokeLastGood();
        assertEq(oracle.lastGoodPx18(), PX);
        assertFalse(oracle.mintAllowed());
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
        CertOracle o = new CertOracle(address(lagging), attester, 2, STALENESS, DEVIATION_BPS, 100, POKE_WINDOW, false);

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
        new CertOracle(address(dead), attester, 2, STALENESS, DEVIATION_BPS, 100, POKE_WINDOW, false);
    }

    function test_L4_constructorRejectsAFutureTimestampedFeed() public {
        MockAggregatorV3 ahead = new MockAggregatorV3(8, 355_86000000);
        ahead.set(355_86000000, block.timestamp + 1 days);

        // Named error, not the arithmetic panic an unguarded `block.timestamp - t` would give.
        vm.expectRevert(CertOracle.CertOracle_StalePrice.selector);
        new CertOracle(address(ahead), attester, 2, STALENESS, DEVIATION_BPS, 100, POKE_WINDOW, false);
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
        CertOracle o = new CertOracle(address(f), attester, 2, STALENESS, DEVIATION_BPS, 100, POKE_WINDOW, false);

        assertEq(o.markPx18(), 0);
        assertEq(o.basisBps(), 0);
        (bool known,) = o.basisBpsChecked();
        assertFalse(known, "an unattested mark must not read as a zero basis");
    }

    function test_mintAllowedFalseWhenFeedTruncatesToZero() public {
        // 19 feed decimals with answer = 1 truncates to px18 = 1 / 10 = 0 on normalisation,
        // while _tryFeed() still reports ok = true. mintAllowed() must not divide by that zero.
        MockAggregatorV3 tinyFeed = new MockAggregatorV3(19, 1);
        CertOracle tinyOracle = new CertOracle(address(tinyFeed), attester, 2, 3600, 500, 100, POKE_WINDOW, false);
        vm.prank(attester);
        tinyOracle.setMarkPrice(PX);

        assertFalse(tinyOracle.mintAllowed());
    }

    // ---------------------------------------------------------------------------------------
    // M-5 (MEDIUM, external C1 audit). The attester was immutable with no rotation. Losing the key
    // froze markPx18 forever — and because mintAllowed() requires markPx18 != 0 and measures the
    // basis band against it, a frozen mark eventually holds minting shut with nothing able to
    // reopen it. Compromise is worse: one key wrote the mark here AND open interest, notional and
    // margin in SolvencyRegistry, plus the BufferBook ledger through CertVault.accrueFunding.
    //
    // Rotation is governance-gated behind an immutable notice period. Law 6 is untouched: this is
    // a role change, not a trading power. Law 2 is untouched too, and that is asserted below —
    // pxUnguarded() is not attester-writable and a pending rotation cannot reach it.
    // ---------------------------------------------------------------------------------------

    address internal recovered = makeAddr("recoveredAttester");

    function test_governanceIsTheDeployer() public view {
        assertEq(oracle.governance(), address(this));
        assertEq(oracle.ATTESTER_ROTATION_DELAY(), 2 days);
    }

    function test_attesterRotationServesItsNoticePeriodThenWorks() public {
        oracle.proposeAttester(recovered);
        assertEq(oracle.attester(), attester, "proposing installed it immediately");

        vm.expectRevert(CertOracle.CertOracle_RotationNotDue.selector);
        oracle.acceptAttester();

        vm.warp(block.timestamp + oracle.ATTESTER_ROTATION_DELAY());
        vm.prank(stranger); // permissionless finalisation (Law 6)
        oracle.acceptAttester();
        assertEq(oracle.attester(), recovered);

        // The new key writes the mark; the old one cannot.
        vm.prank(recovered);
        oracle.setMarkPrice(PX);
        assertEq(oracle.markPx18(), PX);

        vm.expectRevert(CertOracle.CertOracle_OnlyAttester.selector);
        vm.prank(attester);
        oracle.setMarkPrice(1e18);
    }

    function test_onlyGovernanceMayProposeARotation() public {
        vm.expectRevert(CertOracle.CertOracle_OnlyGovernance.selector);
        vm.prank(stranger);
        oracle.proposeAttester(recovered);

        vm.expectRevert(CertOracle.CertOracle_OnlyGovernance.selector);
        vm.prank(attester);
        oracle.proposeAttester(recovered);
    }

    function test_rotationCannotInstallTheZeroAddress() public {
        vm.expectRevert(CertOracle.CertOracle_ZeroAddress.selector);
        oracle.proposeAttester(address(0));
    }

    function test_acceptRevertsWithNothingPending() public {
        vm.expectRevert(CertOracle.CertOracle_NoPendingAttester.selector);
        oracle.acceptAttester();
    }

    /// @notice LAW 2 ACROSS THE WHOLE ROTATION. The published redemption price answers before the
    ///         proposal, during the notice period, and after the install — a rotation cannot reach
    ///         it, because pxUnguarded() reads the immutable feed and never the attester.
    function test_pxUnguardedIsUnaffectedByAPendingOrCompletedRotation() public {
        (uint256 pBefore,) = oracle.pxUnguarded();
        assertEq(pBefore, PX);

        oracle.proposeAttester(recovered);
        (uint256 pDuring,) = oracle.pxUnguarded();
        assertEq(pDuring, PX, "a pending rotation moved the redemption price");

        vm.warp(block.timestamp + oracle.ATTESTER_ROTATION_DELAY());
        oracle.acceptAttester();
        // Keep the feed fresh so this measures the rotation and not staleness.
        feed.set(int256(PX / 1e10), block.timestamp);
        (uint256 pAfter,) = oracle.pxUnguarded();
        assertEq(pAfter, PX, "the rotation moved the redemption price");
    }

    /// @notice L-3: the constructor names a bad dependency instead of failing later somewhere else.
    function test_constructorRejectsZeroDependencies() public {
        vm.expectRevert(CertOracle.CertOracle_ZeroAddress.selector);
        new CertOracle(address(0), attester, 2, STALENESS, DEVIATION_BPS, 100, POKE_WINDOW, false);

        vm.expectRevert(CertOracle.CertOracle_ZeroAddress.selector);
        new CertOracle(address(feed), address(0), 2, STALENESS, DEVIATION_BPS, 100, POKE_WINDOW, false);
    }

    // =======================================================================================
    // Task 2: SINGLE-SOURCE mode.
    //
    // 28 of the venue's 57 perp markets have NO Chainlink feed — 20.5% of open interest,
    // including XAU (gold, $12.5M OI), XAG, ANTHROPIC ($4.88M OI on $19.3M daily volume), OPENAI
    // and SHEIN. Those markets are in scope, so a vault will be deployed where the venue's own
    // mark, directly or through a venue-sourced adapter, is the only price there is.
    //
    // The old contract accepted that deployment SILENTLY. basisBpsChecked() reported
    // `known = true, bps = 0` — a healthy basis ASSERTED, never computed, because feed and mark
    // were the same number. Two of mintAllowed()'s three guards degenerated for the same reason.
    // Only the deviation clamp survived, and that is a rate limit, not a truth check. Nothing in
    // the contracts, the suite or the checklist would have flagged it, which is worse than a loud
    // failure: pushing the venue mark moves a venue-sourced feed and markPx18 TOGETHER and holds
    // the basis at zero, so the degenerate band reads healthiest exactly while it is defeated.
    // =======================================================================================

    /// @dev The widest deviation a single-source deployment may be built with. Must equal
    ///      CertOracle.MAX_SINGLE_SOURCE_DEVIATION_BPS; asserted in
    ///      test_constructorRejectsWideDeviationInSingleSource.
    uint256 internal constant SS_DEVIATION_BPS = 200;

    /// @dev A single-source oracle with a mark attested at the index, i.e. the exact degenerate
    ///      configuration the finding is about: feed and mark agreeing because they are the same
    ///      number, not because two independent sources concur.
    function _deploySingleSource(uint256 devBps) internal returns (CertOracle o, MockAggregatorV3 f) {
        f = new MockAggregatorV3(8, 355_86000000);
        o = new CertOracle(address(f), attester, 2, STALENESS, devBps, 100, POKE_WINDOW, true);
        vm.prank(attester);
        o.setMarkPrice(PX);
    }

    /// @notice THE CORE DEFECT. `known = false` (absent) and `known = true, bps = 0` (healthy) must
    ///         be distinguishable by a caller. That they were not — that a deployment with no
    ///         second source reported a perfect basis it had never computed — is the whole finding.
    /// @dev Both oracles below are in the SAME observable state as far as the returned bps is
    ///         concerned: mark exactly on the index, both returning 0. The only thing separating
    ///         "there is nothing to compute" from "I computed it and it is zero" is the bit.
    function test_singleSourceBasisIsAbsentNotZero() public {
        (CertOracle ss,) = _deploySingleSource(SS_DEVIATION_BPS);
        assertTrue(ss.singleSource(), "precondition: single-source mode");
        assertEq(ss.markPx18(), PX, "precondition: a mark IS attested, so absence is not about that");

        (bool ssKnown, uint256 ssBps) = ss.basisBpsChecked();
        assertFalse(ssKnown, "PROPERTY: a deployment with no independent second source has NO basis");
        assertEq(ssBps, 0, "the bps half is meaningless when known is false");

        // The dual-source oracle, in the base fixture, with the mark likewise sitting exactly on
        // the index: a real, computed, zero basis.
        (bool dualKnown, uint256 dualBps) = oracle.basisBpsChecked();
        assertFalse(oracle.singleSource(), "precondition: dual-source mode");
        assertTrue(dualKnown, "a computable basis must still report known");
        assertEq(dualBps, 0);

        // And the assertion that names the bug: identical numbers, opposite meanings, and the
        // caller can tell. Before Task 2 both sides of this returned (true, 0).
        assertEq(ssBps, dualBps, "the two states return the same number, which is why the bit is needed");
        assertTrue(ssKnown != dualKnown, "PROPERTY: absent and zero must be DISTINGUISHABLE");
    }

    /// @notice basisBps() has no bit to carry, so it refuses by name rather than returning a
    ///         meaningless zero. This is the one deliberate exception to its never-reverts
    ///         contract; `singleSource` is immutable, so it cannot surprise a caller mid-flight.
    function test_singleSourceBasisBpsReverts() public {
        (CertOracle ss,) = _deploySingleSource(SS_DEVIATION_BPS);

        vm.expectRevert(CertOracle.CertOracle_NoIndependentBasis.selector);
        ss.basisBps();

        // The checked variant stays total — a caller that wants the bit rather than the revert has
        // one, and it never reverts in either mode.
        (bool known,) = ss.basisBpsChecked();
        assertFalse(known);

        // And the dual-source path is untouched: still answers, still never reverts.
        assertEq(oracle.basisBps(), 0);
    }

    /// @notice In single-source mode the basis band is skipped ENTIRELY, because it is not a guard:
    ///         feed and mark are the same number, so it compares a value with itself. A mark 50%
    ///         away from the index — which shuts minting in dual-source mode — must not shut it
    ///         here, precisely because the band's verdict carries no information.
    function test_singleSourceMintAllowedIgnoresBasisBand() public {
        (CertOracle ss,) = _deploySingleSource(SS_DEVIATION_BPS);
        assertTrue(ss.mintAllowed(), "precondition: minting open");

        // 5000 bps of "basis" against a 100 bps band.
        vm.prank(attester);
        ss.setMarkPrice(PX * 150 / 100);
        assertTrue(ss.mintAllowed(), "PROPERTY: the band is meaningless here and must not gate minting");

        // The same mark on the dual-source fixture, where the band IS a cross-check between two
        // independent numbers, does shut minting. Same input, different mode, opposite verdict —
        // which is the point: the band is dropped where it means nothing and kept where it means
        // something.
        vm.prank(attester);
        oracle.setMarkPrice(PX * 150 / 100);
        assertFalse(oracle.mintAllowed(), "the dual-source band must still bite");

        // The band's `markPx18 != 0` precondition goes with it: a mark of zero is not a guard
        // either, and keeping it would hand the attester a mint pause by inaction (Law 6).
        vm.prank(attester);
        ss.setMarkPrice(0);
        assertEq(ss.markPx18(), 0);
        assertTrue(ss.mintAllowed(), "an unread input must not gate minting in single-source mode");
    }

    /// @notice The two guards that DO survive must still bite, or the mode is not a smaller guard
    ///         set, it is no guard set. Staleness first, then the deviation clamp — the only
    ///         remaining defence, and the reason it is capped at construction.
    function test_singleSourceStillEnforcesStalenessAndDeviation() public {
        (CertOracle ss, MockAggregatorV3 f) = _deploySingleSource(SS_DEVIATION_BPS);
        assertTrue(ss.mintAllowed(), "precondition: minting open");

        // STALENESS still bites.
        vm.warp(block.timestamp + STALENESS + 1);
        assertFalse(ss.mintAllowed(), "PROPERTY: staleness must still pause minting");

        // A fresh round at the same price reopens it, so the refusal above was staleness and not
        // something else that the warp happened to trip.
        f.set(f.answer(), block.timestamp);
        assertTrue(ss.mintAllowed(), "a fresh feed must reopen minting");

        // The DEVIATION CLAMP still bites: 300 bps against the 200 bps single-source maximum.
        // Note the mark is moved with the feed, exactly as a venue-sourced deployment does, which
        // is what would have held the degenerate basis band at zero.
        f.set(int256(PX * 103 / 100 / 1e10), block.timestamp);
        vm.prank(attester);
        ss.setMarkPrice(PX * 103 / 100);
        assertFalse(ss.mintAllowed(), "PROPERTY: the deviation clamp must still pause minting");

        // And it is the clamp doing it, not staleness: a move inside 200 bps is accepted.
        f.set(int256(PX * 101 / 100 / 1e10), block.timestamp);
        assertTrue(ss.mintAllowed(), "a move inside the clamp must be accepted");
    }

    /// @notice The clamp is the only defence left, so its width is the whole safety budget. A
    ///         single-source deployment wider than MAX_SINGLE_SOURCE_DEVIATION_BPS is refused at
    ///         construction, by name, and the bound is not configurable.
    function test_constructorRejectsWideDeviationInSingleSource() public {
        assertEq(oracle.MAX_SINGLE_SOURCE_DEVIATION_BPS(), SS_DEVIATION_BPS, "the bound moved");

        MockAggregatorV3 f = new MockAggregatorV3(8, 355_86000000);

        vm.expectRevert(CertOracle.CertOracle_DeviationTooWideForSingleSource.selector);
        new CertOracle(address(f), attester, 2, STALENESS, SS_DEVIATION_BPS + 1, 100, POKE_WINDOW, true);

        // The bound is inclusive: exactly 200 deploys.
        CertOracle atBound =
            new CertOracle(address(f), attester, 2, STALENESS, SS_DEVIATION_BPS, 100, POKE_WINDOW, true);
        assertEq(atBound.deviationBps(), SS_DEVIATION_BPS);
        assertTrue(atBound.singleSource());

        // And the check is conditional on the MODE, not on the number: the identical 201 bps is
        // accepted for a dual-source deployment, where the basis band still stands behind it.
        CertOracle dual =
            new CertOracle(address(f), attester, 2, STALENESS, SS_DEVIATION_BPS + 1, 100, POKE_WINDOW, false);
        assertEq(dual.deviationBps(), SS_DEVIATION_BPS + 1);
        assertFalse(dual.singleSource());
    }

    /// @notice `singleSource == false` must be BIT-IDENTICAL to the behaviour before Task 2. The
    ///         pre-existing tests passing is necessary but not sufficient — they were written
    ///         against a contract that had no mode at all — so every one of the three affected
    ///         entry points is exercised explicitly here, including the `markPx18 == 0` precondition
    ///         that single-source mode drops and dual-source mode must keep.
    function test_dualSourceBehaviourUnchanged() public {
        MockAggregatorV3 f = new MockAggregatorV3(8, 355_86000000);
        CertOracle o = new CertOracle(address(f), attester, 2, STALENESS, DEVIATION_BPS, 100, POKE_WINDOW, false);
        assertFalse(o.singleSource());

        // --- markPx18 == 0: basis unknown, and minting REFUSED. Both are pre-Task-2 behaviour.
        assertEq(o.markPx18(), 0);
        (bool known, uint256 bps) = o.basisBpsChecked();
        assertFalse(known, "an unattested mark must not read as a zero basis");
        assertEq(bps, 0);
        assertEq(o.basisBps(), 0, "basisBps must not revert in dual-source mode");
        assertFalse(o.mintAllowed(), "dual-source mode must still require an attested mark");

        // --- mark on the index: a real, computed, zero basis, and minting open.
        vm.prank(attester);
        o.setMarkPrice(PX);
        (known, bps) = o.basisBpsChecked();
        assertTrue(known);
        assertEq(bps, 0);
        assertEq(o.basisBps(), 0);
        assertTrue(o.mintAllowed());

        // --- mark inside the band: value reported, minting open.
        vm.prank(attester);
        o.setMarkPrice(PX * 1005 / 1000);
        (known, bps) = o.basisBpsChecked();
        assertTrue(known);
        assertEq(bps, 50);
        assertEq(o.basisBps(), 50);
        assertTrue(o.mintAllowed());

        // --- mark beyond the band: the band still bites, and it is the BAND, since the feed has
        // not moved so the deviation clamp cannot be the one refusing.
        vm.prank(attester);
        o.setMarkPrice(PX * 103 / 100);
        (known, bps) = o.basisBpsChecked();
        assertTrue(known);
        assertEq(bps, 300);
        assertEq(o.basisBps(), 300);
        assertFalse(o.mintAllowed(), "the dual-source basis band must still pause minting");

        // --- unreadable feed: basis unknown, basisBps still total, minting refused.
        vm.prank(attester);
        o.setMarkPrice(PX);
        f.setShouldRevert(true);
        (known, bps) = o.basisBpsChecked();
        assertFalse(known);
        assertEq(bps, 0);
        assertEq(o.basisBps(), 0, "basisBps must never revert in dual-source mode");
        assertFalse(o.mintAllowed());

        // --- stale feed: same.
        f.setShouldRevert(false);
        vm.warp(block.timestamp + STALENESS + 1);
        (known,) = o.basisBpsChecked();
        assertFalse(known);
        assertEq(o.basisBps(), 0);
        assertFalse(o.mintAllowed());
    }

    /// @notice The deviation clamp's REFERENCE is required to exist in single-source mode, because
    ///         there is nothing behind it. `lastGoodPx18 == 0` skips the deviation check, which is
    ///         harmless in dual-source mode (the band still stands) and would leave single-source
    ///         minting with no guard at all beyond "the feed answered". It fails closed instead —
    ///         and pokeLastGood's bootstrap path repairs it, so a real deployment loses nothing.
    /// @dev The zero reference is reachable exactly as test_H1_pokeRejectsAPriceThatNormalisesToZero
    ///      describes: a feed whose answer truncates to zero on normalisation at construction.
    function test_singleSourceFailsClosedWithoutADeviationReference() public {
        MockAggregatorV3 ssFeed = new MockAggregatorV3(19, 1); // 1 / 10 == 0 on normalisation
        CertOracle ss =
            new CertOracle(address(ssFeed), attester, 2, STALENESS, SS_DEVIATION_BPS, 100, POKE_WINDOW, true);
        assertEq(ss.lastGoodPx18(), 0, "precondition: construction normalised to a zero reference");

        MockAggregatorV3 dualFeed = new MockAggregatorV3(19, 1);
        CertOracle dual =
            new CertOracle(address(dualFeed), attester, 2, STALENESS, DEVIATION_BPS, 100, POKE_WINDOW, false);
        assertEq(dual.lastGoodPx18(), 0);

        // Both feeds recover to a real, readable price, so `p != 0` while the reference stays 0.
        ssFeed.setDecimals(8);
        ssFeed.set(355_86000000, block.timestamp);
        dualFeed.setDecimals(8);
        dualFeed.set(355_86000000, block.timestamp);
        vm.startPrank(attester);
        ss.setMarkPrice(PX);
        dual.setMarkPrice(PX);
        vm.stopPrank();

        assertFalse(ss.mintAllowed(), "PROPERTY: single-source must fail closed with no reference");
        // UNCHANGED dual-source behaviour, stated rather than implied: there the basis band is
        // still a real cross-check, so a missing deviation reference does not pause minting and
        // this task must not make it start doing so.
        assertTrue(dual.mintAllowed(), "dual-source behaviour changed");

        // Repairable without a key (Law 6): the bootstrap branch of pokeLastGood installs one.
        vm.prank(stranger);
        ss.pokeLastGood();
        assertEq(ss.lastGoodPx18(), PX);
        assertTrue(ss.mintAllowed(), "a bootstrapped reference must reopen minting");
    }
}
