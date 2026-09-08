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
        vm.warp(block.timestamp + 3601);
        (uint256 p, uint256 t) = oracle.pxUnguarded();
        assertEq(p, PX);
        assertGt(t, 0);
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
}
