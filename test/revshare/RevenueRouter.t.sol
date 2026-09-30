// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPxOracle, MockRevShareVault, MockVaultFactory, MockInsurancePool} from "./mocks/MockRevShareVault.sol";
import {RevenueRouter} from "../../src/revshare/RevenueRouter.sol";
import {IVaultFactory, IInsurancePool} from "../../src/revshare/interfaces/IRevShare.sol";

contract RevenueRouterTest is Test {
    MockERC20 usdg;
    MockERC20 cert;
    MockPxOracle oracle;
    MockVaultFactory factory;
    MockInsurancePool pool;
    RevenueRouter router;
    address buyback = address(0xB8);
    address ops = address(0x0B5);
    address treasury = address(0x7E);
    address gov = address(0x60);

    function setUp() public {
        vm.warp(1_000_000);
        usdg = new MockERC20("USDG", "USDG", 6);
        cert = new MockERC20("uTSLA", "uTSLA", 18);
        oracle = new MockPxOracle();
        oracle.setPx(350e18);
        factory = new MockVaultFactory();
        factory.add(address(new MockRevShareVault(address(cert), address(oracle))));
        pool = new MockInsurancePool();
        router = new RevenueRouter(usdg, 6, IVaultFactory(address(factory)), IInsurancePool(address(pool)),
                                   buyback, ops, treasury, gov);
    }

    function _income(uint256 amt) internal {
        usdg.mint(address(router), amt);
        router.distribute();
    }

    function test_belowTargetSplit_50_30_10_10() public {
        cert.mint(address(1), 100e18);          // 100 certs x $350 = $35,000 open; 5% target = $1,750
        pool.set(1_000e6, 1e12);                // $1,000 of cover < target
        _income(1_000e6);
        assertEq(router.owed(address(pool)), 500e6);
        assertEq(router.owed(buyback), 300e6);
        assertEq(router.owed(ops), 100e6);
        assertEq(router.owed(treasury), 100e6);
    }

    function test_atTargetSplit_0_80_10_10() public {
        cert.mint(address(1), 100e18);
        pool.set(1_750e6, 1e12);                // exactly at target
        _income(1_000e6);
        assertEq(router.owed(address(pool)), 0);
        assertEq(router.owed(buyback), 800e6);
        assertEq(router.owed(ops), 100e6);
        assertEq(router.owed(treasury), 100e6);
    }

    function test_emptyPoolShareGoesToTreasury() public {
        cert.mint(address(1), 100e18);
        pool.set(0, 0);
        _income(1_000e6);
        assertEq(router.owed(address(pool)), 0);
        assertEq(router.owed(buyback), 300e6);
        assertEq(router.owed(treasury), 600e6);
    }

    function test_noOpenCertificatesMeansTargetMet() public {
        pool.set(0, 1e12);                      // depositors exist, nothing open
        _income(1_000e6);
        assertEq(router.owed(buyback), 800e6);
    }

    function test_claimPaysOnlyTheRecipient() public {
        pool.set(0, 1e12);
        _income(1_000e6);
        uint256 paid = router.claim(buyback);
        assertEq(paid, 800e6);
        assertEq(usdg.balanceOf(buyback), 800e6);
        assertEq(router.owed(buyback), 0);
    }

    function test_nothingCreditedTwice() public {
        pool.set(0, 1e12);
        _income(1_000e6);
        router.distribute();                    // no new income
        assertEq(router.totalOwed(), 1_000e6);
    }

    function test_targetChangeNeedsGovernanceBoundsAndTwoDays() public {
        vm.expectRevert(RevenueRouter.RevenueRouter_OnlyGovernance.selector);
        router.proposeTarget(300);
        vm.startPrank(gov);
        vm.expectRevert(RevenueRouter.RevenueRouter_TargetOutOfBounds.selector);
        router.proposeTarget(1_001);
        vm.expectRevert(RevenueRouter.RevenueRouter_TargetOutOfBounds.selector);
        router.proposeTarget(199);
        router.proposeTarget(300);
        vm.stopPrank();
        vm.expectRevert(RevenueRouter.RevenueRouter_TargetNotReady.selector);
        router.applyTarget();
        skip(2 days);
        router.applyTarget();                   // permissionless once due
        assertEq(router.targetBps(), 300);
    }

    function testFuzz_sharesSumToIncomeLessDust(uint64 income, uint64 cover, uint64 certs) public {
        cert.mint(address(1), uint256(certs));
        pool.set(cover, 1e12);
        usdg.mint(address(router), income);
        uint256 credited = router.distribute();
        assertLe(income - credited, 3);
        assertEq(router.totalOwed(), credited);
    }
}
