// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
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

/// The forwarder pattern the buyback leg will use: pay in the whole balance, skip below minNotify.
contract ForwarderLike {
    function forward(CertStaking pool, IERC20 token) external returns (bool) {
        uint256 bal = token.balanceOf(address(this));
        if (bal < pool.minNotify()) return false;
        token.approve(address(pool), bal);
        pool.notifyRewardAmount(bal);
        return true;
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
    address attacker = makeAddr("attacker");
    uint256 constant WEEK = 7 days;
    uint256 constant CAP = 10_000_000e18;
    uint256 constant MIN_NOTIFY = 1e6; // 1 USDG

    function setUp() public {
        vm.warp(1_790_000_000);
        cert = new MockERC20("UseCert", "CERT", 18);
        usdg = new MockERC20("USDG", "USDG", 6);
        pool = new CertStaking(cert, usdg, WEEK, CAP, MIN_NOTIFY);
        for (uint256 i = 0; i < 2; i++) {
            address u = i == 0 ? alice : bob;
            cert.mint(u, 50_000_000e18);
            vm.prank(u);
            cert.approve(address(pool), type(uint256).max);
        }
        usdg.mint(fund, 1_000_000e6);
        vm.prank(fund);
        usdg.approve(address(pool), type(uint256).max);
        usdg.mint(attacker, 1_000e6);
        vm.prank(attacker);
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

    /// What the pool owes in reward-token units: every earned reward, what is still to stream,
    /// and what is carried. It must never exceed what the pool holds.
    function _owed(CertStaking p, address[] memory who) internal view returns (uint256 owed) {
        for (uint256 i = 0; i < who.length; i++) owed += p.earned(who[i]);
        owed += p.remainingReward() + p.unallocated();
    }

    // ------------------------------------------------------------------ construction

    function test_constructor_rejects_bad_config() public {
        vm.expectRevert(CertStaking.CertStaking_BadConfig.selector);
        new CertStaking(cert, cert, WEEK, CAP, MIN_NOTIFY); // same token
        vm.expectRevert(CertStaking.CertStaking_BadConfig.selector);
        new CertStaking(cert, usdg, 12 hours, CAP, MIN_NOTIFY);
        vm.expectRevert(CertStaking.CertStaking_BadConfig.selector);
        new CertStaking(cert, usdg, 91 days, CAP, MIN_NOTIFY);
        vm.expectRevert(CertStaking.CertStaking_BadConfig.selector);
        new CertStaking(cert, usdg, WEEK, 0, MIN_NOTIFY);
        vm.expectRevert(CertStaking.CertStaking_BadConfig.selector);
        new CertStaking(cert, usdg, WEEK, CAP, 0); // minNotify must be > 0
        vm.expectRevert(CertStaking.CertStaking_ZeroAddress.selector);
        new CertStaking(MockERC20(address(0)), usdg, WEEK, CAP, MIN_NOTIFY);
        assertEq(pool.minNotify(), MIN_NOTIFY);
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
        CertStaking p = new CertStaking(fot, usdg, WEEK, CAP, MIN_NOTIFY);
        fot.mint(alice, 1_000e18);
        vm.startPrank(alice);
        fot.approve(address(p), type(uint256).max);
        p.stake(1_000e18);
        vm.stopPrank();
        assertEq(p.balanceOf(alice), 990e18, "1% burnt in transfer is not credited");
        assertEq(fot.balanceOf(address(p)), 990e18);
    }

    /// A fee-on-transfer REWARD token cannot slip a funding under minNotify: the check is on what
    /// arrived, not on `amount`.
    function test_fee_on_transfer_funding_checked_on_what_arrived() public {
        FeeOnTransfer fot = new FeeOnTransfer();
        CertStaking p = new CertStaking(cert, fot, WEEK, CAP, 100);
        fot.mint(fund, 1_000);
        vm.startPrank(fund);
        fot.approve(address(p), type(uint256).max);
        vm.expectRevert(CertStaking.CertStaking_BelowMinNotify.selector);
        p.notifyRewardAmount(100); // 99 arrives
        p.notifyRewardAmount(102); // 101 arrives
        vm.stopPrank();
        // At scale, still-to-stream + carried is exactly the 101 that arrived.
        assertEq((p.periodFinish() - block.timestamp) * p.rewardRate() + p.unallocatedScaled(), 101e18);
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

    /// The unallocated view counts an empty stretch that has not been checkpointed yet.
    function test_unallocated_view_includes_the_pending_empty_stretch() public {
        _fund(700e6);
        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(pool.unallocated(), 100e6, 1, "a day of nobody, before any checkpoint");
        assertLt(pool.unallocatedScaled(), 1e18, "in storage only the rate's sub-unit remainder, so far");
    }

    /// M-4: a top-up while a period is running is folded into the time LEFT; the end stays put.
    function test_topping_up_mid_period_keeps_the_end() public {
        _stake(alice, 1_000e18);
        _fund(700e6);
        uint256 finish = pool.periodFinish();
        vm.warp(block.timestamp + WEEK / 2);
        _fund(700e6); // 350 left + 700 new, over the half week left
        assertEq(pool.periodFinish(), finish, "the end does not move");
        assertApproxEqAbs(pool.remainingReward(), 1_050e6, 1);
        vm.warp(finish);
        assertApproxEqAbs(pool.earned(alice), 1_400e6, 2, "all of it by the original end");
    }

    function test_funding_after_the_end_starts_a_full_period() public {
        _stake(alice, 1_000e18);
        _fund(700e6);
        vm.warp(block.timestamp + WEEK + 3 days);
        _fund(70e6);
        assertEq(pool.periodFinish(), block.timestamp + WEEK);
    }

    function test_funding_is_permissionless_and_too_small_is_refused() public {
        usdg.mint(alice, 10e6);
        vm.startPrank(alice);
        usdg.approve(address(pool), type(uint256).max);
        pool.notifyRewardAmount(10e6); // anyone can pay in
        vm.stopPrank();
        assertGt(pool.rewardRate(), 0);
        vm.startPrank(fund);
        vm.expectRevert(CertStaking.CertStaking_BelowMinNotify.selector);
        pool.notifyRewardAmount(MIN_NOTIFY - 1);
        vm.expectRevert(CertStaking.CertStaking_BelowMinNotify.selector);
        pool.notifyRewardAmount(0);
        pool.notifyRewardAmount(MIN_NOTIFY); // exactly the minimum is fine
        vm.stopPrank();
    }

    function test_forwarder_can_read_minNotify_and_skip() public {
        ForwarderLike fwd = new ForwarderLike();
        usdg.mint(address(fwd), MIN_NOTIFY - 1);
        assertFalse(fwd.forward(pool, usdg), "below the minimum: skipped, not reverted");
        usdg.mint(address(fwd), 1);
        assertTrue(fwd.forward(pool, usdg));
        assertEq(usdg.balanceOf(address(fwd)), 0);
        assertEq(usdg.balanceOf(address(pool)), MIN_NOTIFY);
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

    /// (e) exit() with nothing staked claims instead of reverting on withdraw(0).
    function test_exit_with_zero_stake_only_claims() public {
        vm.prank(bob);
        pool.exit(); // never staked, nothing earned: a no-op, not a revert

        _stake(alice, 1_000e18);
        _fund(700e6);
        vm.warp(block.timestamp + WEEK / 2);
        vm.prank(alice);
        pool.withdraw(1_000e18);
        uint256 owed = pool.earned(alice);
        assertGt(owed, 0);
        vm.prank(alice);
        pool.exit(); // zero stake, 350 USDG earned
        assertEq(usdg.balanceOf(alice), owed);
        assertEq(pool.earned(alice), 0);
    }

    function test_large_stake_does_not_round_rewards_away() public {
        _stake(alice, CAP); // 10M CERT
        _fund(100e6); // 100 USDG for a week: ~165 units/s over 1e25 staked
        vm.warp(block.timestamp + WEEK);
        assertApproxEqAbs(pool.earned(alice), 100e6, 1e3, "1e36 precision keeps it");
    }

    // ------------------------------------------------------------------ M-3: dust counted twice

    /// (a) The exact pre-audit M-3 reproduction. v1: earned 8, unallocated 1, held 8 - owed 9.
    ///     v2 carries the remainder at 1e18 scale, so what was streamed is not also carried.
    function test_M3_exact_reproduction_is_now_solvent() public {
        CertStaking p = new CertStaking(cert, usdg, WEEK, CAP, 1);
        vm.prank(alice);
        cert.approve(address(p), type(uint256).max);
        vm.prank(alice);
        p.stake(1e21);
        vm.startPrank(fund);
        usdg.approve(address(p), type(uint256).max);
        p.notifyRewardAmount(7);
        vm.warp(block.timestamp + WEEK);
        p.notifyRewardAmount(1);
        vm.stopPrank();
        vm.warp(block.timestamp + WEEK);

        // rate1 = 7e18 / 604800 streams 6.9999999999999552e18; 44,800 carried at scale.
        // rate2 = (1e18 + 44800) / 604800 streams 0.9999999999999072e18; 137,600 carried.
        // Streamed + carried = exactly the 8e18 that came in.
        assertEq(p.unallocatedScaled(), 137_600, "carry is exact, at scale");
        assertEq(p.rewardRate() * WEEK + p.unallocatedScaled() + 6_999_999_999_999_955_200, 8e18, "nothing counted twice");
        assertEq(usdg.balanceOf(address(p)), 8);
        assertEq(p.earned(alice), 7, "7.99 streamed, floored");
        assertEq(p.unallocated(), 0);
        assertEq(p.remainingReward(), 0);
        address[] memory who = new address[](1);
        who[0] = alice;
        assertLe(_owed(p, who), usdg.balanceOf(address(p)), "owes no more than it holds");
        vm.prank(alice);
        p.exit(); // v1: the last claimer is blocked; here it pays
        assertEq(usdg.balanceOf(alice), 7);
    }

    // ------------------------------------------------------------------ M-4: stream stretching

    /// (c) Daily dust fundings no longer delay payout. One real funding of 700 USDG; an attacker
    ///     pays minNotify every day. By the ORIGINAL periodFinish the staker has it all (plus the
    ///     attacker's dust). v1 would have paid only ~63% by then.
    function test_M4_daily_dust_does_not_delay_payout() public {
        _stake(alice, 1_000e18);
        _fund(700e6);
        uint256 finish = pool.periodFinish();
        for (uint256 d = 1; d <= 6; d++) {
            vm.warp(finish - WEEK + d * 1 days);
            vm.prank(attacker);
            pool.notifyRewardAmount(MIN_NOTIFY);
            assertEq(pool.periodFinish(), finish, "dust cannot move the end");
        }
        vm.warp(finish);
        vm.prank(alice);
        pool.getReward();
        assertGe(usdg.balanceOf(alice), 700e6 - 10, "the whole 700 by the original end");
        assertApproxEqAbs(usdg.balanceOf(alice), 706e6, 10, "and the dust too");
    }

    /// (c, continued) The attacker's best timing: fund in the last hour, which does restart the
    ///     period. What that moves out of the original period is at most one hour's stream, and
    ///     the attacker cannot do it again until the new period is itself in its last hour.
    function test_M4_best_timed_dust_moves_at_most_one_hour() public {
        _stake(alice, 1_000e18);
        _fund(700e6);
        uint256 finish = pool.periodFinish();
        vm.warp(finish - 1 hours + 1); // just inside the last hour
        vm.prank(attacker);
        pool.notifyRewardAmount(MIN_NOTIFY);
        uint256 newFinish = pool.periodFinish();
        assertEq(newFinish, block.timestamp + WEEK, "last hour: a new full period");
        vm.prank(attacker);
        pool.notifyRewardAmount(MIN_NOTIFY); // immediately again: folded in
        assertEq(pool.periodFinish(), newFinish, "one restart per period");
        vm.warp(finish);
        uint256 oneHour = uint256(700e6) * 1 hours / WEEK; // 4.1667 USDG
        assertGe(pool.earned(alice), 700e6 - oneHour, "at most one hour's stream delayed");
        // Every day after: the new end does not move either.
        for (uint256 d = 1; d <= 5; d++) {
            vm.warp(finish + d * 1 days);
            vm.prank(attacker);
            pool.notifyRewardAmount(MIN_NOTIFY);
            assertEq(pool.periodFinish(), newFinish, "still one restart per period");
        }
        vm.warp(newFinish);
        assertApproxEqAbs(pool.earned(alice), 707e6, 10, "and it all arrives by the new end");
    }

    /// (d) The tiny-time-left edge, at its boundary: exactly MIN_TIME_LEFT left is still folded in;
    ///     one second less starts a new period, carrying the remainder with it.
    function test_M4_tiny_time_left_edge() public {
        _stake(alice, 1_000e18);
        _fund(700e6);
        uint256 finish = pool.periodFinish();

        uint256 snap = vm.snapshotState();
        vm.warp(finish - pool.MIN_TIME_LEFT());
        _fund(100e6);
        assertEq(pool.periodFinish(), finish, "exactly an hour left: folded in");
        assertApproxEqAbs(pool.remainingReward(), 100e6 + uint256(700e6) / 168, 2);
        vm.warp(finish);
        assertApproxEqAbs(pool.earned(alice), 800e6, 2, "the 100 streams in the last hour");

        vm.revertToState(snap);
        vm.warp(finish - pool.MIN_TIME_LEFT() + 1);
        uint256 left = pool.remainingReward();
        _fund(100e6);
        assertEq(pool.periodFinish(), block.timestamp + WEEK, "under an hour: a new full period");
        assertApproxEqAbs(pool.remainingReward(), 100e6 + left, 2, "the remainder rolls into it");
        vm.warp(block.timestamp + WEEK);
        assertApproxEqAbs(pool.earned(alice), 800e6, 2);
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

    /// (b) A long random sequence against a minNotify = 1 pool: six stakers, fundings from 1 unit
    ///     up, empty-pool stretches, and time jumps past periodFinish. After EVERY step the pool
    ///     holds at least every earned reward + what is still to stream + what is carried.
    function testFuzz_long_random_sequence_stays_solvent(uint256 seed) public {
        CertStaking p = new CertStaking(cert, usdg, WEEK, CAP, 1);
        address[] memory who = new address[](6);
        for (uint256 i = 0; i < who.length; i++) {
            who[i] = address(uint160(0xC0FFEE00 + i));
            cert.mint(who[i], CAP);
            vm.prank(who[i]);
            cert.approve(address(p), type(uint256).max);
        }
        vm.prank(fund);
        usdg.approve(address(p), type(uint256).max);

        for (uint256 step = 0; step < 120; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            address u = who[seed % who.length];
            uint256 op = (seed >> 8) % 8;
            uint256 x = seed >> 16;
            if (op == 0 || op == 1) {
                uint256 room = CAP - p.totalStaked();
                if (room > 0) {
                    vm.prank(u);
                    p.stake(bound(x, 1, room < 2_000_000e18 ? room : 2_000_000e18));
                }
            } else if (op == 2) {
                uint256 bal = p.balanceOf(u);
                if (bal > 0) {
                    vm.prank(u);
                    p.withdraw(bound(x, 1, bal));
                }
            } else if (op == 3) {
                vm.prank(u);
                p.exit();
            } else if (op == 4) {
                // an empty-pool stretch: everyone leaves
                for (uint256 i = 0; i < who.length; i++) {
                    vm.prank(who[i]);
                    p.exit();
                }
            } else if (op == 5) {
                vm.prank(fund);
                p.notifyRewardAmount(x % 3 == 0 ? bound(x >> 4, 1, 10) : bound(x >> 4, 1, 50_000e6));
            } else if (op == 6) {
                vm.prank(u);
                p.getReward();
            } else {
                // from seconds to past the period end
                vm.warp(block.timestamp + bound(x, 1, x % 4 == 0 ? 20 days : 1 days));
            }
            assertLe(_owed(p, who), usdg.balanceOf(address(p)), "solvent after every step");
            assertEq(cert.balanceOf(address(p)), p.totalStaked(), "stakes covered exactly");
        }
        // Everyone can still leave with everything they earned.
        vm.warp(block.timestamp + 30 days);
        for (uint256 i = 0; i < who.length; i++) {
            vm.prank(who[i]);
            p.exit();
        }
        assertEq(p.totalStaked(), 0);
    }
}

// ---------------------------------------------------------------------- stateful invariant

/// @notice Drives CertStaking with random stake / withdraw / claim / exit / fund / warp calls.
/// @dev fail_on_revert = false (foundry.toml), so every action is bounded to be valid; a revert
///      is recorded in `unexpectedReverts` (claim, exit and valid funding must never revert).
contract CertStakingHandler is CommonBase, StdUtils {
    CertStaking public immutable pool;
    MockERC20 public immutable cert;
    MockERC20 public immutable usdg;
    address[] public actors;
    address public immutable funder = address(0xF00D);
    uint256 public unexpectedReverts;
    uint256 public checkpoints; // user checkpoints: each may strand < 1 unit of rounding
    uint256 public fundings;
    uint256 public dustFundings;
    uint256 public emptyStretches;
    uint256 public pastFinishJumps;

    constructor(CertStaking pool_, MockERC20 cert_, MockERC20 usdg_) {
        pool = pool_;
        cert = cert_;
        usdg = usdg_;
        for (uint256 i = 0; i < 8; i++) {
            address a = address(uint160(0xA11CE00 + i));
            actors.push(a);
            cert.mint(a, pool_.stakeCap());
            vm.prank(a);
            cert.approve(address(pool_), type(uint256).max);
        }
        usdg.mint(funder, type(uint128).max);
        vm.prank(funder);
        usdg.approve(address(pool_), type(uint256).max);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function stake(uint256 s, uint256 amt) external {
        uint256 room = pool.stakeCap() - pool.totalStaked();
        if (room == 0) return;
        amt = bound(amt, 1, room < 3_000_000e18 ? room : 3_000_000e18);
        vm.prank(_actor(s));
        pool.stake(amt);
        checkpoints++;
    }

    function withdraw(uint256 s, uint256 amt) external {
        address a = _actor(s);
        uint256 bal = pool.balanceOf(a);
        if (bal == 0) return;
        vm.prank(a);
        pool.withdraw(bound(amt, 1, bal));
        checkpoints++;
    }

    function claim(uint256 s) external {
        vm.prank(_actor(s));
        try pool.getReward() {} catch { unexpectedReverts++; }
        checkpoints++;
    }

    function exit(uint256 s) external {
        vm.prank(_actor(s));
        try pool.exit() {} catch { unexpectedReverts++; }
        checkpoints += 2;
    }

    function everyoneLeaves() external {
        for (uint256 i = 0; i < actors.length; i++) {
            vm.prank(actors[i]);
            try pool.exit() {} catch { unexpectedReverts++; }
            checkpoints += 2;
        }
        emptyStretches++;
    }

    function fund(uint256 amt, bool dust) external {
        amt = dust ? bound(amt, 1, 5) : bound(amt, 1, 100_000e6);
        vm.prank(funder);
        try pool.notifyRewardAmount(amt) {} catch { unexpectedReverts++; }
        fundings++;
        if (dust) dustFundings++;
    }

    function warp(uint256 dt, bool far) external {
        dt = far ? bound(dt, 1, 20 days) : bound(dt, 1, 1 days);
        vm.warp(block.timestamp + dt);
        if (block.timestamp > pool.periodFinish() && pool.periodFinish() != 0) pastFinishJumps++;
    }
}

contract CertStakingInvariantTest is Test {
    CertStakingHandler handler;
    CertStaking pool;
    MockERC20 usdg;
    MockERC20 cert;

    function setUp() public {
        vm.warp(1_790_000_000);
        cert = new MockERC20("UseCert", "CERT", 18);
        usdg = new MockERC20("USDG", "USDG", 6);
        pool = new CertStaking(cert, usdg, 7 days, 10_000_000e18, 1); // minNotify 1: 1-unit fundings allowed
        handler = new CertStakingHandler(pool, cert, usdg);
        targetContract(address(handler));
    }

    function _owed() internal view returns (uint256 owed) {
        for (uint256 i = 0; i < handler.actorCount(); i++) owed += pool.earned(handler.actors(i));
        owed += pool.remainingReward() + pool.unallocated();
    }

    /// USDG held >= every earned reward + what is still to stream + what is carried. Checked by
    /// the fuzzer after every call in every sequence.
    function invariant_rewards_always_covered() public view {
        assertLe(_owed(), usdg.balanceOf(address(pool)));
    }

    /// The same at 1e18 scale, with no view flooring to hide behind.
    function invariant_rewards_covered_at_scale() public view {
        uint256 owed18;
        for (uint256 i = 0; i < handler.actorCount(); i++) owed18 += pool.earned(handler.actors(i)) * 1e18;
        uint256 finish = pool.periodFinish();
        owed18 += block.timestamp >= finish ? 0 : (finish - block.timestamp) * pool.rewardRate();
        owed18 += pool.unallocatedScaled();
        if (pool.totalStaked() == 0) {
            uint256 applicable = block.timestamp < finish ? block.timestamp : finish;
            if (applicable > pool.lastUpdateTime()) owed18 += (applicable - pool.lastUpdateTime()) * pool.rewardRate();
        }
        assertLe(owed18, usdg.balanceOf(address(pool)) * 1e18);
    }

    /// Falsifiable in the other direction too: nothing is stranded beyond rounding. Each user
    /// checkpoint may floor away < 1 unit, and the two views floor < 1 unit each.
    function invariant_nothing_stranded_beyond_rounding() public view {
        assertLe(usdg.balanceOf(address(pool)), _owed() + handler.checkpoints() + handler.actorCount() + 2);
    }

    function invariant_stakes_covered_exactly() public view {
        assertEq(cert.balanceOf(address(pool)), pool.totalStaked());
    }

    function invariant_claims_and_fundings_never_revert() public view {
        assertEq(handler.unexpectedReverts(), 0);
    }
}
