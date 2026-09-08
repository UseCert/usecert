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
