// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {InsuranceStaking, IVaultRegistry} from "../src/InsuranceStaking.sol";

contract MockRegistry is IVaultRegistry {
    mapping(address => bool) public isVault;

    function set(address v, bool ok) external {
        isVault[v] = ok;
    }
}

/// @notice K1: the insurance rung. Every rule in docs/K-INSURANCE-STAKING.md has a test here, and
///         most tests are a way the pool could fail its stakers or its holders - and must refuse.
contract InsuranceStakingTest is Test {
    MockERC20 usdg;
    MockRegistry reg;
    InsuranceStaking pool;

    address gov = address(0x5AFE);
    address vault = address(0xCE47);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address eve = address(0xE7E);

    uint256 constant COOLDOWN = 10 days;
    uint256 constant WINDOW = 2 days;
    uint256 constant DELAY = 1 days;
    uint256 constant CAP_BPS = 3_000;
    uint256 constant POOL_CAP = 2_000_000e6;

    function setUp() public {
        vm.warp(1_790_000_000);
        usdg = new MockERC20("USDG", "USDG", 6);
        reg = new MockRegistry();
        reg.set(vault, true);
        pool = new InsuranceStaking(usdg, reg, gov, COOLDOWN, WINDOW, DELAY, CAP_BPS, POOL_CAP, "UseCert Insurance", "sUSDG");
        for (uint256 i = 0; i < 3; i++) {
            address u = [alice, bob, eve][i];
            usdg.mint(u, 1_000_000e6);
            vm.prank(u);
            usdg.approve(address(pool), type(uint256).max);
        }
    }

    function _stake(address u, uint256 amt) internal returns (uint256 shares) {
        vm.prank(u);
        shares = pool.deposit(amt, u);
    }

    function _requestAll(address u) internal {
        uint256 s = pool.balanceOf(u);
        vm.prank(u);
        pool.requestWithdraw(s);
    }

    // ------------------------------------------------------------------ construction

    function test_constructor_rejects_bad_config() public {
        vm.expectRevert(InsuranceStaking.InsuranceStaking_BadConfig.selector);
        new InsuranceStaking(usdg, reg, gov, DELAY, WINDOW, DELAY, CAP_BPS, POOL_CAP, "x", "x"); // cooldown == delay
        vm.expectRevert(InsuranceStaking.InsuranceStaking_BadConfig.selector);
        new InsuranceStaking(usdg, reg, gov, COOLDOWN, WINDOW, DELAY, 5_001, POOL_CAP, "x", "x"); // cap above 50%
        vm.expectRevert(InsuranceStaking.InsuranceStaking_BadConfig.selector);
        new InsuranceStaking(usdg, reg, gov, COOLDOWN, WINDOW, DELAY, 0, POOL_CAP, "x", "x");
        vm.expectRevert(InsuranceStaking.InsuranceStaking_BadConfig.selector);
        new InsuranceStaking(usdg, reg, gov, COOLDOWN, 12 hours, DELAY, CAP_BPS, POOL_CAP, "x", "x"); // window < 1 day
        vm.expectRevert(InsuranceStaking.InsuranceStaking_BadConfig.selector);
        new InsuranceStaking(usdg, reg, gov, 30 days, WINDOW, 4 days, CAP_BPS, POOL_CAP, "x", "x"); // delay+3d+1d > 7d gap
        vm.expectRevert(InsuranceStaking.InsuranceStaking_ZeroAddress.selector);
        new InsuranceStaking(usdg, reg, address(0), COOLDOWN, WINDOW, DELAY, CAP_BPS, POOL_CAP, "x", "x");
    }

    function test_constructor_rejects_zero_deposit_cap() public {
        vm.expectRevert(InsuranceStaking.InsuranceStaking_BadConfig.selector);
        new InsuranceStaking(usdg, reg, gov, COOLDOWN, WINDOW, DELAY, CAP_BPS, 0, "x", "x");
    }

    function test_deposit_cap_is_a_hard_ceiling() public {
        InsuranceStaking small = new InsuranceStaking(usdg, reg, gov, COOLDOWN, WINDOW, DELAY, CAP_BPS, 1_000e6, "s", "s");
        vm.startPrank(alice);
        usdg.approve(address(small), type(uint256).max);
        small.deposit(600e6, alice);
        assertEq(small.maxDeposit(alice), 400e6, "room left under the cap");
        vm.expectRevert();
        small.deposit(400e6 + 1, alice);
        small.deposit(400e6, alice);
        assertEq(small.maxDeposit(alice), 0);
        assertEq(small.maxMint(alice), 0);
        vm.expectRevert();
        small.deposit(1, alice);
        vm.stopPrank();
        usdg.mint(address(small), 50e6); // income can take it past the cap; only deposits stop
        assertEq(small.totalAssets(), 1_050e6);
        assertEq(small.maxDeposit(bob), 0);
    }

    // ------------------------------------------------------------------ deposits and exits

    function test_deposit_is_one_to_one_at_start() public {
        uint256 s = _stake(alice, 1_000e6);
        assertApproxEqAbs(pool.convertToAssets(s), 1_000e6, 1, "virtual shares cost at most 1 unit");
        assertLe(pool.convertToAssets(s), 1_000e6, "and never round in the depositor's favour");
        assertEq(pool.totalAssets(), 1_000e6);
    }

    function test_no_exit_without_cooldown() public {
        _stake(alice, 1_000e6);
        assertEq(pool.maxRedeem(alice), 0);
        uint256 s = pool.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(); // ERC4626 max* guard fires first; the reason is maxRedeem == 0
        pool.redeem(s, alice, alice);
    }

    function test_exit_only_inside_the_window() public {
        _stake(alice, 1_000e6);
        _requestAll(alice);
        uint256 s = pool.balanceOf(alice);

        vm.warp(block.timestamp + COOLDOWN - 1);
        assertEq(pool.maxRedeem(alice), 0, "one second early");

        vm.warp(block.timestamp + 1);
        assertEq(pool.maxRedeem(alice), s, "window open");

        vm.warp(block.timestamp + WINDOW);
        assertEq(pool.maxRedeem(alice), 0, "window closed");
    }

    function test_redeem_in_window_pays_and_consumes_the_request() public {
        _stake(alice, 1_000e6);
        _requestAll(alice);
        uint256 s = pool.balanceOf(alice);
        vm.warp(block.timestamp + COOLDOWN);
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        pool.redeem(s / 2, alice, alice);
        assertApproxEqAbs(usdg.balanceOf(alice) - before, 500e6, 1);
        (uint256 left,) = pool.withdrawRequests(alice);
        assertEq(left, s - s / 2, "request shrinks by what was redeemed");
    }

    function test_cannot_redeem_more_than_requested() public {
        _stake(alice, 1_000e6);
        uint256 s = pool.balanceOf(alice);
        vm.prank(alice);
        pool.requestWithdraw(s / 4);
        vm.warp(block.timestamp + COOLDOWN);
        assertEq(pool.maxRedeem(alice), s / 4);
        vm.prank(alice);
        vm.expectRevert();
        pool.redeem(s / 2, alice, alice);
    }

    function test_request_above_balance_reverts() public {
        _stake(alice, 1_000e6);
        uint256 s = pool.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_ExceedsBalance.selector);
        pool.requestWithdraw(s + 1);
    }

    function test_transferring_shares_does_not_skip_the_cooldown() public {
        _stake(alice, 1_000e6);
        uint256 s = pool.balanceOf(alice);
        vm.prank(alice);
        pool.transfer(eve, s);
        assertEq(pool.maxRedeem(eve), 0, "a fresh holder has no request");
    }

    // ------------------------------------------------------------------ yield

    function test_income_raises_the_share_price_for_everyone_including_cooldown() public {
        _stake(alice, 1_000e6);
        _stake(bob, 3_000e6);
        _requestAll(alice); // in cooldown: still earns
        usdg.mint(address(pool), 400e6); // income sent to the pool
        assertApproxEqAbs(pool.convertToAssets(pool.balanceOf(alice)), 1_100e6, 2);
        assertApproxEqAbs(pool.convertToAssets(pool.balanceOf(bob)), 3_300e6, 2);
    }

    function test_first_depositor_inflation_attack_fails() public {
        // Attacker deposits 1 unit, then donates a lot to inflate the share price before the victim.
        _stake(eve, 1);
        usdg.mint(eve, 100_000e6);
        vm.prank(eve);
        usdg.transfer(address(pool), 100_000e6);
        uint256 s = _stake(alice, 1_000e6);
        assertGt(s, 0, "victim still gets shares");
        assertApproxEqRel(pool.convertToAssets(s), 1_000e6, 0.01e18, "victim keeps ~all of the deposit");
    }

    // ------------------------------------------------------------------ draws

    function test_only_governance_proposes_and_only_to_a_vault() public {
        _stake(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_OnlyGovernance.selector);
        pool.proposeDraw(vault, 100e6);
        vm.prank(gov);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_NotAVault.selector);
        pool.proposeDraw(eve, 100e6);
    }

    function test_draw_is_capped_at_proposal() public {
        _stake(alice, 1_000e6);
        vm.prank(gov);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_DrawAboveCap.selector);
        pool.proposeDraw(vault, 300e6 + 1);
    }

    function test_draw_waits_for_the_delay_then_anyone_executes() public {
        _stake(alice, 1_000e6);
        vm.prank(gov);
        uint256 id = pool.proposeDraw(vault, 300e6);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_DrawNotExecutable.selector);
        pool.executeDraw(id);
        vm.warp(block.timestamp + DELAY);
        vm.prank(eve); // not governance: once decided, governance cannot also stall it
        pool.executeDraw(id);
        assertEq(usdg.balanceOf(vault), 300e6, "the collateral lands in the vault");
        assertEq(pool.totalAssets(), 700e6);
    }

    function test_draw_loss_is_shared_pro_rata_including_cooldown_shares() public {
        _stake(alice, 1_000e6);
        _stake(bob, 3_000e6);
        _requestAll(alice); // requested exits do not escape a loss
        vm.prank(gov);
        uint256 id = pool.proposeDraw(vault, 1_000e6); // 25% of 4,000
        vm.warp(block.timestamp + DELAY);
        pool.executeDraw(id);
        assertApproxEqAbs(pool.convertToAssets(pool.balanceOf(alice)), 750e6, 2);
        assertApproxEqAbs(pool.convertToAssets(pool.balanceOf(bob)), 2_250e6, 2);
    }

    function test_draw_expires() public {
        _stake(alice, 1_000e6);
        vm.prank(gov);
        uint256 id = pool.proposeDraw(vault, 100e6);
        vm.warp(block.timestamp + DELAY + pool.DRAW_EXECUTION_WINDOW());
        vm.expectRevert(InsuranceStaking.InsuranceStaking_DrawClosed.selector);
        pool.executeDraw(id);
        assertFalse(pool.drawPending(), "an expired draw no longer pauses anything");
    }

    function test_cancelled_draw_cannot_execute() public {
        _stake(alice, 1_000e6);
        vm.prank(gov);
        uint256 id = pool.proposeDraw(vault, 100e6);
        vm.prank(gov);
        pool.cancelDraw(id);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_DrawClosed.selector);
        pool.executeDraw(id);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_DrawClosed.selector);
        pool.executeDraw(id);
    }

    function test_draw_cannot_execute_twice() public {
        _stake(alice, 1_000e6);
        vm.prank(gov);
        uint256 id = pool.proposeDraw(vault, 100e6);
        vm.warp(block.timestamp + DELAY);
        pool.executeDraw(id);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_DrawClosed.selector);
        pool.executeDraw(id);
    }

    function test_pending_draw_pauses_exits_and_deposits_then_releases() public {
        _stake(alice, 1_000e6);
        _requestAll(alice);
        vm.warp(block.timestamp + COOLDOWN); // alice's window is open...
        vm.prank(gov);
        uint256 id = pool.proposeDraw(vault, 100e6); // ...and a draw is announced
        assertTrue(pool.drawPending());
        assertEq(pool.maxRedeem(alice), 0, "cannot leave ahead of an announced loss");
        assertEq(pool.maxDeposit(bob), 0, "cannot walk into an announced loss");
        uint256 s = pool.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        pool.redeem(s, alice, alice);

        vm.warp(block.timestamp + DELAY);
        pool.executeDraw(id);
        assertFalse(pool.drawPending());
        assertGt(pool.maxDeposit(bob), 0, "deposits reopen");
    }

    function test_governance_cannot_hold_stakers_by_reproposing() public {
        _stake(alice, 1_000e6);
        vm.prank(gov);
        pool.proposeDraw(vault, 10e6);
        vm.warp(block.timestamp + DELAY + pool.DRAW_EXECUTION_WINDOW()); // first draw expired
        vm.prank(gov);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_ProposalTooSoon.selector);
        pool.proposeDraw(vault, 10e6);
        assertFalse(pool.drawPending(), "exits are open in the gap");
        vm.warp(block.timestamp + 3 days); // 7 days after the first proposal
        vm.prank(gov);
        pool.proposeDraw(vault, 10e6);
    }

    function test_cap_rechecked_at_execution() public {
        _stake(alice, 1_000e6);
        vm.prank(gov);
        uint256 id = pool.proposeDraw(vault, 300e6); // exactly the cap now
        // Assets fall before execution (simulated by moving collateral out behind the pool's back:
        // the pool cannot stop a mock token doing this, which is the point of the re-check).
        vm.prank(address(pool));
        usdg.transfer(eve, 100e6);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_DrawAboveCap.selector);
        pool.executeDraw(id);
    }

    // ------------------------------------------------------------------ invariant-style

    /// @dev Across random deposits, income and one draw, nobody can take out more than the pool
    ///      holds, and the pool never owes more than it has.
    function testFuzz_solvency_of_the_pool(uint96 a, uint96 b, uint96 income, uint16 drawBps) public {
        uint256 da = bound(a, 1e6, 500_000e6);
        uint256 db = bound(b, 1e6, 500_000e6);
        _stake(alice, da);
        _stake(bob, db);
        usdg.mint(address(pool), bound(income, 0, 100_000e6));
        uint256 amt = pool.totalAssets() * bound(drawBps, 1, CAP_BPS) / 10_000;
        if (amt > 0) {
            vm.prank(gov);
            uint256 id = pool.proposeDraw(vault, amt);
            vm.warp(block.timestamp + DELAY);
            pool.executeDraw(id);
        }
        uint256 owed = pool.convertToAssets(pool.balanceOf(alice)) + pool.convertToAssets(pool.balanceOf(bob));
        assertLe(owed, pool.totalAssets(), "never owes more than it holds");
        _requestAll(alice);
        _requestAll(bob);
        vm.warp(block.timestamp + COOLDOWN);
        uint256 sa = pool.balanceOf(alice);
        uint256 sb = pool.balanceOf(bob);
        vm.prank(alice);
        pool.redeem(sa, alice, alice);
        vm.prank(bob);
        pool.redeem(sb, bob, bob);
        assertLe(pool.totalSupply(), 0);
    }
}
