// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockBurnableERC20} from "./mocks/MockBurnableERC20.sol";
import {TokenStaking} from "../../src/revshare/TokenStaking.sol";

contract TokenStakingTest is Test {
    MockBurnableERC20 tkn;
    TokenStaking st;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address funder = address(0xF00D);

    function setUp() public {
        vm.warp(1_000_000);
        tkn = new MockBurnableERC20();
        st = new TokenStaking(tkn);
        for (uint256 i = 0; i < 3; i++) {
            address a = [alice, bob, funder][i];
            tkn.mint(a, 100_000_000e18);
            vm.prank(a);
            tkn.approve(address(st), type(uint256).max);
        }
    }

    function _fund(uint256 x) internal {
        vm.prank(funder);
        st.notifyRewardAmount(x);
    }

    function test_fundingStreamsOverAWeek() public {
        vm.prank(alice);
        st.stake(1_000e18);
        _fund(700e18);
        assertEq(st.periodFinish(), block.timestamp + 7 days);
        skip(7 days);
        assertApproxEqAbs(st.earned(alice), 700e18, 1e6);
    }

    function test_twoStakersShareByStake() public {
        vm.prank(alice);
        st.stake(1_000e18);
        vm.prank(bob);
        st.stake(3_000e18);
        _fund(400e18);
        skip(7 days);
        assertApproxEqAbs(st.earned(alice), 100e18, 1e6);
        assertApproxEqAbs(st.earned(bob), 300e18, 1e6);
    }

    /// Sermium M-01: staking one hour before a large late funding must capture < 1% of it.
    function test_jitCaptureOfALateFundingIsBelowOnePercent() public {
        vm.prank(alice);
        st.stake(1_000_000e18);
        _fund(70e18);                                      // the base weekly stream
        skip(7 days - 2 hours);                           // two hours left: the old rule would stream over them
        vm.prank(bob);
        st.stake(9_000_000e18);                            // the attacker, just before the late funding
        _fund(1_000e18);                                   // the large late funding
        skip(1 hours);
        vm.prank(bob);
        st.requestUnstake(9_000_000e18);                   // stops earning at once
        uint256 fromFunding = st.earned(bob);
        assertLt(fromFunding, 10e18, "attacker captured >= 1% of the funding");
    }

    /// Sermium L-01: a dust funding every hour must not hold back vesting by more than 1%.
    function test_dustFundingsBarelyDelayVesting() public {
        vm.prank(alice);
        st.stake(1_000e18);
        _fund(700e18);
        for (uint256 i = 0; i < 168; i++) {
            skip(1 hours);
            _fund(1);
        }
        assertGt(st.earned(alice), 693e18, "more than 1% still unvested after a week");
    }

    function test_cooldownStakeEarnsNothingAndWithdrawsAfterSevenDays() public {
        vm.prank(alice);
        st.stake(1_000e18);
        vm.prank(bob);
        st.stake(1_000e18);
        _fund(700e18);
        skip(1 days);
        vm.prank(bob);
        st.requestUnstake(1_000e18);
        uint256 bobAt = st.earned(bob);
        skip(6 days);
        assertEq(st.earned(bob), bobAt, "stake in cooldown kept earning");
        vm.prank(bob);
        vm.expectRevert(TokenStaking.TokenStaking_CooldownNotOver.selector);
        st.withdraw();
        skip(1 days);
        uint256 before = tkn.balanceOf(bob);
        vm.prank(bob);
        st.withdraw();
        assertEq(tkn.balanceOf(bob) - before, 1_000e18);
    }

    function test_rewardAccruedWithNobodyStakedIsCarried() public {
        _fund(700e18);
        skip(3 days);
        vm.prank(alice);
        st.stake(1_000e18);
        _fund(1e18);                                        // folds the carried amount back in
        skip(8 days);
        assertApproxEqAbs(st.earned(alice), 701e18, 1e9);
    }

    function test_getRewardPays() public {
        vm.prank(alice);
        st.stake(1_000e18);
        _fund(700e18);
        skip(7 days);
        uint256 before = tkn.balanceOf(alice);
        vm.prank(alice);
        st.getReward();
        assertApproxEqAbs(tkn.balanceOf(alice) - before, 700e18, 1e6);
    }

    function test_zeroAmountsRefused() public {
        vm.expectRevert(TokenStaking.TokenStaking_ZeroAmount.selector);
        st.stake(0);
        vm.expectRevert(TokenStaking.TokenStaking_ZeroAmount.selector);
        st.notifyRewardAmount(0);
    }

    /// Solvency: what the contract owes never exceeds what it holds.
    function testFuzz_solvency(uint96 a, uint96 b, uint96 f1, uint96 f2, uint32 dt1, uint32 dt2) public {
        a = uint96(bound(a, 1, 10_000_000e18));
        b = uint96(bound(b, 1, 10_000_000e18));
        f1 = uint96(bound(f1, 1, 1_000_000e18));
        f2 = uint96(bound(f2, 1, 1_000_000e18));
        vm.prank(alice);
        st.stake(a);
        _fund(f1);
        skip(bound(dt1, 0, 30 days));
        vm.prank(bob);
        st.stake(b);
        _fund(f2);
        skip(bound(dt2, 0, 30 days));
        uint256 owed = st.earned(alice) + st.earned(bob) + st.totalStaked() + st.remainingReward() + st.carried();
        assertLe(owed, tkn.balanceOf(address(st)));
    }
}
