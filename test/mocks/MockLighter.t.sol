// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockLighter} from "./MockLighter.sol";
import {MockERC20} from "./MockERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

contract MockLighterTest is Test {
    MockLighter lighter;
    MockERC20 usdg;

    function setUp() public {
        usdg = new MockERC20("USDG", "USDG", 6);
        lighter = new MockLighter(IERC20(address(usdg)), 3);
        usdg.mint(address(this), 1_000_000e6);
        usdg.approve(address(lighter), type(uint256).max);
    }

    function test_depositRegistersAccount() public {
        assertEq(lighter.addressToAccountIndex(address(this)), 0);
        lighter.deposit(address(this), 3, 0, 1_000e6);
        assertGt(lighter.addressToAccountIndex(address(this)), 0);
        assertEq(lighter.marginBalance(), 1_000e6);
    }

    function test_createOrderRevertsForUnregisteredAccount() public {
        vm.expectRevert(MockLighter.AccountIsNotRegistered.selector);
        lighter.createOrder(0, 16, 100, 35586, 0, 1);
    }

    function test_orderDoesNotFillUntilBatchSettles() public {
        lighter.deposit(address(this), 3, 0, 1_000e6);
        uint48 idx = lighter.addressToAccountIndex(address(this));
        lighter.createOrder(idx, 16, 100, 35586, 0, 1);

        // The whole point: no fill in the calling transaction.
        assertEq(lighter.positionBase(16), 0);
        assertEq(lighter.queuedOrderCount(), 1);

        lighter.settleBatch();
        assertEq(lighter.positionBase(16), 100);
        assertEq(lighter.queuedOrderCount(), 0);
    }

    function test_zeroBaseAmountClosesEntirePosition() public {
        lighter.deposit(address(this), 3, 0, 1_000e6);
        uint48 idx = lighter.addressToAccountIndex(address(this));
        lighter.createOrder(idx, 16, 500, 35586, 0, 1);
        lighter.settleBatch();
        assertEq(lighter.positionBase(16), 500);

        lighter.createOrder(idx, 16, 0, 35586, 1, 1);
        lighter.settleBatch();
        assertEq(lighter.positionBase(16), 0);
    }
}
