// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CertOracle} from "../src/CertOracle.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

contract CertOracleTest is Test {
    CertOracle oracle;
    MockAggregatorV3 feed;
    address attester = makeAddr("attester");

    // TSLA: price_decimals = 2, so 355.86 -> tick 35586
    uint256 constant PX = 355.86e18;

    function setUp() public {
        vm.warp(1_800_000_000);
        feed = new MockAggregatorV3(8, 355_86000000); // 8 decimals
        oracle = new CertOracle(address(feed), attester, 2, 3600, 500, 100);
        vm.prank(attester);
        oracle.setMarkPrice(PX);
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
