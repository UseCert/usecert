// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BufferBook} from "../src/BufferBook.sol";

contract BufferBookTest is Test {
    BufferBook book;
    address vault = makeAddr("vault");
    address asset = makeAddr("tsla");

    // floor 100k, feeOn 60k, mintSlow 30k, insuranceDraw 0, feeCap 200 bps
    function setUp() public {
        book = new BufferBook(vault, 200);
        vm.prank(vault);
        book.configure(asset, 100_000e18, 60_000e18, 30_000e18, 0);
    }

    function _fund(uint256 amt) internal {
        vm.prank(vault);
        book.accrue(asset, int256(amt));
    }

    function test_positiveFundingFattensBuffer() public {
        _fund(100_000e18);
        assertEq(book.balance18(asset), int256(100_000e18));
        assertEq(book.holdingFeeBps(asset), 0);
        assertFalse(book.mintSlowed(asset));
    }

    function test_healthyBufferChargesNoHoldingFee() public {
        _fund(80_000e18);
        assertEq(book.holdingFeeBps(asset), 0);
    }

    function test_crossingFeeOnActivatesCappedFee() public {
        _fund(50_000e18); // below feeOn 60k
        uint256 fee = book.holdingFeeBps(asset);
        assertGt(fee, 0);
        assertLe(fee, 200);
    }

    function test_feeIsCappedAtDeployBound() public {
        _fund(1e18); // almost empty
        assertEq(book.holdingFeeBps(asset), 200);
    }

    function test_feeRoundsToNearestNotUpwards() public {
        _fund(60_000e18 - 1); // exactly 1 wei shortfall
        assertEq(book.holdingFeeBps(asset), 0);
    }

    function test_crossingMintSlowFlagsIt() public {
        _fund(50_000e18);
        assertFalse(book.mintSlowed(asset));
        vm.prank(vault);
        book.accrue(asset, -25_000e18); // now 25k, below mintSlow 30k
        assertTrue(book.mintSlowed(asset));
    }

    function test_exhaustedBufferRequestsInsuranceDraw() public {
        _fund(10_000e18);
        vm.prank(vault);
        book.accrue(asset, -15_000e18); // negative
        assertLt(book.balance18(asset), 0);
        assertEq(book.insuranceDrawNeeded(asset), 5_000e18);
    }

    function test_capacityIsZeroWhenBufferNegative() public {
        _fund(10_000e18);
        vm.prank(vault);
        book.accrue(asset, -15_000e18);
        assertEq(book.capacity18(asset), 0);
    }

    function test_capacityScalesWithBuffer() public {
        _fund(100_000e18);
        assertGt(book.capacity18(asset), 0);
    }

    function test_onlyVaultMayAccrue() public {
        vm.expectRevert(BufferBook.BufferBook_OnlyVault.selector);
        book.accrue(asset, 1e18);
    }
}
