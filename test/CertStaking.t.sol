// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {CertStaking} from "../src/CertStaking.sol";

/// A token that burns 1% of every transfer, to prove stakes are credited by what ARRIVES.
contract FeeOnTransfer is ERC20 {
    constructor() ERC20("Fee", "FEE") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @notice CERT staking for a share of the buyback fund (owner decision 2026-09-26, option 2).
contract CertStakingTest is Test {
    MockERC20 cert;
    MockERC20 usdg;
    CertStaking pool;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address fund = makeAddr("buybackFund");
    uint256 constant WEEK = 7 days;
    uint256 constant CAP = 10_000_000e18;

    function setUp() public {
        vm.warp(1_790_000_000);
        cert = new MockERC20("UseCert", "CERT", 18);
        usdg = new MockERC20("USDG", "USDG", 6);
        pool = new CertStaking(cert, usdg, WEEK, CAP);
        for (uint256 i = 0; i < 2; i++) {
            address u = i == 0 ? alice : bob;
            cert.mint(u, 50_000_000e18);
            vm.prank(u);
            cert.approve(address(pool), type(uint256).max);
        }
        usdg.mint(fund, 1_000_000e6);
        vm.prank(fund);
        usdg.approve(address(pool), type(uint256).max);
    }

    function _stake(address u, uint256 a) internal {
        vm.prank(u);
        pool.stake(a);
    }

    function _fund(uint256 a) internal {
        vm.prank(fund);
        pool.notifyRewardAmount(a);
    }

    // ------------------------------------------------------------------ construction

    function test_constructor_rejects_bad_config() public {
        vm.expectRevert(CertStaking.CertStaking_BadConfig.selector);
        new CertStaking(cert, cert, WEEK, CAP); // same token
        vm.expectRevert(CertStaking.CertStaking_BadConfig.selector);
        new CertStaking(cert, usdg, 12 hours, CAP);
        vm.expectRevert(CertStaking.CertStaking_BadConfig.selector);
        new CertStaking(cert, usdg, 91 days, CAP);
        vm.expectRevert(CertStaking.CertStaking_BadConfig.selector);
        new CertStaking(cert, usdg, WEEK, 0);
        vm.expectRevert(CertStaking.CertStaking_ZeroAddress.selector);
        new CertStaking(MockERC20(address(0)), usdg, WEEK, CAP);
    }

    // ------------------------------------------------------------------ staking

    function test_stake_and_withdraw_immediately() public {
        _stake(alice, 1_000e18);
        assertEq(pool.balanceOf(alice), 1_000e18);
        assertEq(pool.totalStaked(), 1_000e18);
        vm.prank(alice);
        pool.withdraw(400e18);
        assertEq(pool.balanceOf(alice), 600e18);
        assertEq(cert.balanceOf(alice), 50_000_000e18 - 600e18);
    }

    function test_cannot_withdraw_more_than_staked() public {
        _stake(alice, 1_000e18);
        vm.prank(alice);
        vm.expectRevert(CertStaking.CertStaking_InsufficientStake.selector);
        pool.withdraw(1_000e18 + 1);
    }

    function test_stake_cap_is_a_hard_ceiling() public {
        _stake(alice, CAP - 1e18);
        vm.prank(bob);
        vm.expectRevert(CertStaking.CertStaking_AboveStakeCap.selector);
        pool.stake(2e18);
        _stake(bob, 1e18);
        assertEq(pool.totalStaked(), CAP);
    }

    function test_fee_on_transfer_stake_credits_only_what_arrived() public {
        FeeOnTransfer fot = new FeeOnTransfer();
        CertStaking p = new CertStaking(fot, usdg, WEEK, CAP);
        fot.mint(alice, 1_000e18);
        vm.startPrank(alice);
        fot.approve(address(p), type(uint256).max);
        p.stake(1_000e18);
        vm.stopPrank();
        assertEq(p.balanceOf(alice), 990e18, "1% burnt in transfer is not credited");
        assertEq(fot.balanceOf(address(p)), 990e18);
    }

    // ------------------------------------------------------------------ rewards

    function test_single_staker_gets_the_whole_stream() public {
        _stake(alice, 1_000e18);
        _fund(700e6);
        vm.warp(block.timestamp + WEEK);
        assertApproxEqAbs(pool.earned(alice), 700e6, 2, "all of it, to the unit");
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        pool.getReward();
        assertApproxEqAbs(usdg.balanceOf(alice) - before, 700e6, 2);
    }

    function test_rewards_are_pro_rata_and_time_weighted() public {
        _stake(alice, 1_000e18);
        _stake(bob, 3_000e18);
        _fund(700e6);
        vm.warp(block.timestamp + WEEK / 2);
        _stake(bob, 4_000e18); // bob now 7,000 of 8,000 for the second half
        vm.warp(block.timestamp + WEEK / 2);
        // first half: alice 1/4 of 350 = 87.5; second half: alice 1/8 of 350 = 43.75
        assertApproxEqAbs(pool.earned(alice), 131.25e6, 1e3);
        assertApproxEqAbs(pool.earned(bob), 568.75e6, 1e3);
    }

    function test_no_jump_in_just_before_a_payout() public {
        _stake(alice, 1_000e18);
        _fund(700e6);
        vm.warp(block.timestamp + WEEK - 1 hours);
        _stake(bob, 1_000_000e18); // a whale arrives an hour before the end
        vm.warp(block.timestamp + 1 hours);
        // bob only earns the last hour's stream: 700/168 = 4.17 USDG, not a share of the week
        assertLt(pool.earned(bob), 4.2e6);
        assertGt(pool.earned(alice), 695e6);
    }

    function test_reward_while_nobody_staked_is_not_stranded() public {
        _fund(700e6); // nobody staked yet
        vm.warp(block.timestamp + 2 days);
        _stake(alice, 1_000e18); // two days of stream accrued to nobody
        vm.warp(block.timestamp + WEEK);
        uint256 got = pool.earned(alice);
        assertApproxEqAbs(got, 500e6, 1e3, "the 5 days she was in");
        // the 2 unstaked days are carried into the next funding, not lost
        assertApproxEqAbs(pool.unallocated(), 200e6, 1e3);
        _fund(1e6);
        vm.warp(block.timestamp + WEEK);
        assertApproxEqAbs(pool.earned(alice), got + 201e6, 2e3);
    }

    function test_topping_up_mid_period_rolls_the_remainder_in() public {
        _stake(alice, 1_000e18);
        _fund(700e6);
        vm.warp(block.timestamp + WEEK / 2);
        _fund(700e6); // 350 left + 700 new, over a fresh week
        assertApproxEqAbs(pool.remainingReward(), 1_050e6, 1e3);
        vm.warp(block.timestamp + WEEK);
        assertApproxEqAbs(pool.earned(alice), 1_400e6, 1e3);
    }

    function test_funding_is_permissionless_and_too_small_is_refused() public {
        usdg.mint(alice, 10e6);
        vm.startPrank(alice);
        usdg.approve(address(pool), type(uint256).max);
        pool.notifyRewardAmount(10e6); // anyone can pay in
        vm.stopPrank();
        assertGt(pool.rewardRate(), 0);
        // With the 1e18-scaled rate even 1 unit streams; zero is refused.
        vm.prank(fund);
        vm.expectRevert(CertStaking.CertStaking_ZeroAmount.selector);
        pool.notifyRewardAmount(0);
    }

    function test_withdraw_keeps_earned_reward_and_exit_pays_both() public {
        _stake(alice, 1_000e18);
        _fund(700e6);
        vm.warp(block.timestamp + WEEK / 2);
        vm.prank(alice);
        pool.withdraw(1_000e18);
        assertApproxEqAbs(pool.earned(alice), 350e6, 1e3, "earned survives the withdrawal");
        vm.warp(block.timestamp + WEEK / 2);
        assertApproxEqAbs(pool.earned(alice), 350e6, 1e3, "and stops growing");
        _stake(alice, 500e18);
        vm.prank(alice);
        pool.exit();
        assertEq(pool.balanceOf(alice), 0);
        assertApproxEqAbs(usdg.balanceOf(alice), 350e6 + pool.earned(alice), 1e3);
    }

    function test_large_stake_does_not_round_rewards_away() public {
        _stake(alice, CAP); // 10M CERT
        _fund(100e6); // 100 USDG for a week: ~165 units/s over 1e25 staked
        vm.warp(block.timestamp + WEEK);
        assertApproxEqAbs(pool.earned(alice), 100e6, 1e3, "1e36 precision keeps it");
    }

    // ------------------------------------------------------------------ solvency

    /// @dev Whatever the sequence, the pool can always pay every staker's stake AND every earned
    ///      reward from what it holds.
    function testFuzz_always_solvent(uint96 a, uint96 b, uint64 r1, uint64 r2, uint32 t1, uint32 t2) public {
        uint256 sa = bound(a, 1, 5_000_000e18);
        uint256 sb = bound(b, 1, 5_000_000e18);
        _stake(alice, sa);
        _fund(bound(r1, 1e6, 100_000e6));
        vm.warp(block.timestamp + bound(t1, 0, 30 days));
        _stake(bob, sb);
        _fund(bound(r2, 1e6, 100_000e6));
        vm.warp(block.timestamp + bound(t2, 0, 30 days));
        assertLe(pool.earned(alice) + pool.earned(bob), usdg.balanceOf(address(pool)), "rewards covered");
        assertEq(cert.balanceOf(address(pool)), pool.totalStaked(), "stakes covered exactly");
        vm.prank(alice);
        pool.exit();
        vm.prank(bob);
        pool.exit();
        assertEq(pool.totalStaked(), 0);
        assertEq(cert.balanceOf(address(pool)), 0);
    }
}
