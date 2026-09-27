// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {InsuranceStaking, IVaultRegistry, IInsurableVault} from "../src/InsuranceStaking.sol";
import {CertFactory} from "../src/CertFactory.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

contract MockRegistry is IVaultRegistry {
    mapping(address => bool) public isVault;
    mapping(address => uint64) public registeredAt;

    /// @dev Registers at the current time, as CertFactory does. Deregistering is not something the
    ///      real factory can do; it is here to prove executeDraw re-checks isVault.
    function set(address v, bool ok) external {
        isVault[v] = ok;
        if (ok && registeredAt[v] == 0) registeredAt[v] = uint64(block.timestamp);
    }

    function setRegisteredAt(address v, uint64 at) external {
        registeredAt[v] = at;
    }
}

/// @notice A vault as the pool sees it: IInsurableVault, plus the two getters CertFactory's
///         registerVault reads, so the same mock can be registered in a real factory.
contract MockInsurableVault is IInsurableVault {
    enum Mode {
        Honest,
        PullsNothing,
        PullsHalf,
        ReentersDeposit,
        ReentersSync
    }

    IERC20 public immutable usdg;
    address public immutable certificate;
    bool public retired;
    uint256 public insuranceShortfall = type(uint128).max;
    Mode public mode;
    uint256 public received;

    constructor(IERC20 usdg_, address certificate_) {
        usdg = usdg_;
        certificate = certificate_;
    }

    function setRetired(bool r) external {
        retired = r;
    }

    function setShortfall(uint256 s) external {
        insuranceShortfall = s;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    /// @dev CertFactory.registerVault decodes marketIndex out of CertVault.cfg().
    function cfg()
        external
        pure
        returns (address, uint16, uint8, uint16, uint8, uint256, uint256, uint256, uint256, uint256)
    {
        return (address(0), 0, 0, 16, 4, 0, 0, 0, 0, 0);
    }

    function receiveInsurance(uint256 amount) external {
        if (mode == Mode.PullsNothing) return;
        if (mode == Mode.ReentersDeposit) {
            usdg.approve(msg.sender, type(uint256).max);
            InsuranceStaking(msg.sender).deposit(1e6, address(this));
        }
        if (mode == Mode.ReentersSync) InsuranceStaking(msg.sender).sync();
        uint256 pull = mode == Mode.PullsHalf ? amount / 2 : amount;
        usdg.transferFrom(msg.sender, address(this), pull);
        received += pull;
        insuranceShortfall = insuranceShortfall > pull ? insuranceShortfall - pull : 0;
    }
}

/// @notice The insurance rung, v2. Every rule in docs/K-INSURANCE-STAKING.md has a test here, and
///         most tests are a way the pool could fail its stakers or its holders - and must refuse.
///         Tests named after a pre-audit finding (H-3, H-9, M-2, M-14, L-3, L-14, L-16) or a K2
///         PoC (H01, H02, M01, L01) replay that attack and assert it no longer works.
contract InsuranceStakingTest is Test {
    MockERC20 usdg;
    MockRegistry reg;
    MockInsurableVault vault;
    InsuranceStaking pool;

    address gov = address(0x5AFE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address eve = address(0xE7E);

    uint256 constant COOLDOWN = 10 days;
    uint256 constant WINDOW = 5 days; // M-2: > DELAY + 3-day execution window + 1 day
    uint256 constant DELAY = 1 days;
    uint256 constant CAP_BPS = 3_000;
    uint256 constant POOL_CAP = 2_000_000e6;
    uint256 constant REG_DELAY = 15 days; // H-3: >= COOLDOWN + WINDOW
    uint256 constant VEST = 7 days; // InsuranceStaking.VESTING_PERIOD

    function setUp() public {
        vm.warp(1_790_000_000);
        usdg = new MockERC20("USDG", "USDG", 6);
        reg = new MockRegistry();
        vault = new MockInsurableVault(IERC20(address(usdg)), address(0xCE27));
        reg.set(address(vault), true);
        vm.warp(block.timestamp + REG_DELAY); // the vault has been public long enough
        pool = _make(reg, COOLDOWN, WINDOW, DELAY, CAP_BPS, POOL_CAP, REG_DELAY);
        for (uint256 i = 0; i < 3; i++) {
            address u = [alice, bob, eve][i];
            usdg.mint(u, 1_000_000e6);
            vm.prank(u);
            usdg.approve(address(pool), type(uint256).max);
        }
    }

    function _make(
        IVaultRegistry r,
        uint256 cooldown_,
        uint256 window_,
        uint256 delay_,
        uint256 bps_,
        uint256 cap_,
        uint256 regDelay_
    ) internal returns (InsuranceStaking) {
        return new InsuranceStaking(
            IERC20(address(usdg)), r, gov, cooldown_, window_, delay_, bps_, cap_, regDelay_, "UseCert Insurance", "sUSDG"
        );
    }

    function _stake(address u, uint256 amt) internal returns (uint256 shares) {
        vm.prank(u);
        shares = pool.deposit(amt, u);
    }

    function _requestAll(address u) internal returns (uint256 s) {
        s = pool.balanceOf(u);
        vm.prank(u);
        pool.requestWithdraw(s);
    }

    function _requested(address u) internal view returns (uint256 s) {
        (s,) = pool.withdrawRequests(u);
    }

    /// @dev Income lands, is synced, and fully vests.
    function _income(uint256 amt) internal {
        usdg.mint(address(pool), amt);
        pool.sync();
        vm.warp(block.timestamp + VEST);
    }

    function _draw(address v, uint256 amt) internal returns (uint256 id) {
        vm.prank(gov);
        id = pool.proposeDraw(v, amt);
        vm.warp(block.timestamp + DELAY);
        pool.executeDraw(id);
    }

    function _paid(uint256 id) internal view returns (uint256 paid) {
        (,,,,,, paid) = pool.draws(id);
    }

    // ------------------------------------------------------------------ construction

    function test_constructor_rejects_bad_config() public {
        bytes4 bad = InsuranceStaking.InsuranceStaking_BadConfig.selector;
        vm.expectRevert(bad);
        _make(reg, DELAY, WINDOW, DELAY, CAP_BPS, POOL_CAP, REG_DELAY); // cooldown == delay
        vm.expectRevert(bad);
        _make(reg, COOLDOWN, WINDOW, DELAY, 5_001, POOL_CAP, REG_DELAY); // cap above 50%
        vm.expectRevert(bad);
        _make(reg, COOLDOWN, WINDOW, DELAY, 0, POOL_CAP, REG_DELAY);
        vm.expectRevert(bad);
        _make(reg, COOLDOWN, 12 hours, DELAY, CAP_BPS, POOL_CAP, REG_DELAY); // window < 1 day
        vm.expectRevert(bad);
        _make(reg, 30 days, 10 days, 4 days, CAP_BPS, POOL_CAP, 40 days); // delay+3d+1d > 7d gap
        vm.expectRevert(bad);
        _make(reg, COOLDOWN, WINDOW, DELAY, CAP_BPS, POOL_CAP, COOLDOWN + WINDOW - 1); // H-3
        vm.expectRevert(InsuranceStaking.InsuranceStaking_ZeroAddress.selector);
        new InsuranceStaking(
            IERC20(address(usdg)), reg, address(0), COOLDOWN, WINDOW, DELAY, CAP_BPS, POOL_CAP, REG_DELAY, "x", "x"
        );
        // the bounds are inclusive where they say so
        _make(reg, COOLDOWN, DELAY + 3 days + 1 days, DELAY, CAP_BPS, POOL_CAP, COOLDOWN + DELAY + 4 days);
        assertEq(pool.VESTING_PERIOD(), VEST);
    }

    function test_constructor_rejects_zero_deposit_cap() public {
        vm.expectRevert(InsuranceStaking.InsuranceStaking_BadConfig.selector);
        _make(reg, COOLDOWN, WINDOW, DELAY, CAP_BPS, 0, REG_DELAY);
    }

    /// @notice M-2 / K2 L01: a window must outlast the longest pause by a day. The deployed
    ///         parameters (window 3d, delay 2d, so a 5-day pause) are now refused, as is a window
    ///         that only equals or barely exceeds the pause.
    function test_M2_window_must_outlast_a_pause() public {
        bytes4 bad = InsuranceStaking.InsuranceStaking_BadConfig.selector;
        vm.expectRevert(bad);
        _make(reg, 10 days, 3 days, 2 days, 3_000, 10_000e6, 13 days); // the stack-4 pool
        vm.expectRevert(bad);
        _make(reg, COOLDOWN, DELAY + 3 days, DELAY, CAP_BPS, POOL_CAP, REG_DELAY); // == pause
        vm.expectRevert(bad);
        _make(reg, COOLDOWN, DELAY + 4 days - 1, DELAY, CAP_BPS, POOL_CAP, REG_DELAY);
    }

    // ------------------------------------------------------------------ deposit cap (L-16)

    function test_deposit_cap_is_a_hard_ceiling() public {
        InsuranceStaking small = _make(reg, COOLDOWN, WINDOW, DELAY, CAP_BPS, 1_000e6, REG_DELAY);
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
        // income can take assets past the cap; it neither opens nor closes deposits
        usdg.mint(address(small), 50e6);
        assertEq(small.totalAssets(), 1_000e6, "unsynced income is unvested");
        small.sync();
        vm.warp(block.timestamp + VEST);
        assertEq(small.totalAssets(), 1_050e6);
        assertEq(small.maxDeposit(bob), 0);
        assertEq(small.netPrincipal(), 1_000e6);
    }

    /// @notice L-16: v1 capped totalAssets(), so income closed deposits. The cap is on net principal.
    function test_L16_income_and_donations_never_close_deposits() public {
        InsuranceStaking small = _make(reg, COOLDOWN, WINDOW, DELAY, CAP_BPS, 1_000e6, REG_DELAY);
        vm.startPrank(alice);
        usdg.approve(address(small), type(uint256).max);
        small.deposit(600e6, alice);
        vm.stopPrank();
        usdg.mint(address(small), 5_000e6); // five times the cap, as income
        small.sync();
        vm.warp(block.timestamp + VEST);
        assertGt(small.totalAssets(), 1_000e6);
        assertEq(small.maxDeposit(bob), 400e6, "income used up none of the cap");
        vm.startPrank(bob);
        usdg.approve(address(small), type(uint256).max);
        small.deposit(400e6, bob);
        vm.stopPrank();
        assertEq(small.netPrincipal(), 1_000e6);
    }

    /// @notice L-16: a withdrawal of `shares` removes principal * shares / supply, whatever the
    ///         share price; the last shares out remove exactly what is left.
    function test_L16_withdrawal_reduces_principal_pro_rata() public {
        uint256 sa = _stake(alice, 600e6);
        _stake(bob, 400e6);
        _income(500e6); // price up 50%: withdrawn value no longer equals principal
        assertEq(pool.netPrincipal(), 1_000e6);

        vm.prank(alice);
        pool.requestWithdraw(sa / 2);
        vm.warp(block.timestamp + COOLDOWN);
        uint256 supply = pool.totalSupply();
        uint256 expected = 1_000e6 - 1_000e6 * (sa / 2) / supply;
        vm.prank(alice);
        uint256 paid = pool.redeem(sa / 2, alice, alice);
        assertApproxEqAbs(paid, 450e6, 2, "half of alice's 900 of value");
        assertEq(pool.netPrincipal(), expected, "principal leaves pro rata, not at the payout");
        assertApproxEqAbs(pool.netPrincipal(), 700e6, 1);
        assertEq(pool.maxDeposit(eve), POOL_CAP - pool.netPrincipal());

        // everyone out: principal is exactly zero, not dust
        _requestAll(alice);
        _requestAll(bob);
        vm.warp(block.timestamp + COOLDOWN);
        uint256 ra = _requested(alice);
        uint256 rb = _requested(bob);
        vm.prank(alice);
        pool.redeem(ra, alice, alice);
        vm.prank(bob);
        pool.redeem(rb, bob, bob);
        assertEq(pool.totalSupply(), 0);
        assertEq(pool.netPrincipal(), 0);
    }

    function test_L16_a_draw_does_not_release_principal() public {
        _stake(alice, 1_000e6);
        _draw(address(vault), 300e6);
        assertEq(pool.totalAssets(), 700e6);
        assertEq(pool.netPrincipal(), 1_000e6, "the drawn principal was deposited and was lost, not withdrawn");
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
        uint256 s = _requestAll(alice);

        vm.warp(block.timestamp + COOLDOWN - 1);
        assertEq(pool.maxRedeem(alice), 0, "one second early");

        vm.warp(block.timestamp + 1);
        assertEq(pool.maxRedeem(alice), s, "window open");

        vm.warp(block.timestamp + WINDOW);
        assertEq(pool.maxRedeem(alice), 0, "window closed");
    }

    function test_redeem_in_window_pays_and_consumes_the_request() public {
        _stake(alice, 1_000e6);
        uint256 s = _requestAll(alice);
        vm.warp(block.timestamp + COOLDOWN);
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        pool.redeem(s / 2, alice, alice);
        assertApproxEqAbs(usdg.balanceOf(alice) - before, 500e6, 1);
        assertEq(_requested(alice), s - s / 2, "request shrinks by what was redeemed");
        assertEq(pool.balanceOf(address(pool)), s - s / 2, "and so does the escrow");
    }

    function test_withdraw_by_assets_burns_from_the_escrow() public {
        _stake(alice, 1_000e6);
        uint256 s = _requestAll(alice);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(alice);
        uint256 burned = pool.withdraw(250e6, alice, alice);
        assertEq(_requested(alice), s - burned);
        assertEq(pool.balanceOf(address(pool)), s - burned);
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

    // ------------------------------------------------------------------ escrow (H-9)

    function test_H9_request_escrows_the_shares_which_keep_counting() public {
        uint256 s = _stake(alice, 1_000e6);
        uint256 supply = pool.totalSupply();
        _requestAll(alice);
        assertEq(pool.balanceOf(alice), 0, "requested shares leave the owner's balance");
        assertEq(pool.balanceOf(address(pool)), s, "into escrow");
        assertEq(pool.totalSupply(), supply, "and still count");
        assertEq(_requested(alice), s);
    }

    function test_H9_escrowed_shares_cannot_be_transferred() public {
        uint256 s = _stake(alice, 1_000e6);
        vm.prank(alice);
        pool.requestWithdraw(s);
        vm.prank(alice);
        vm.expectRevert(); // ERC20InsufficientBalance: the shares are not alice's to move
        pool.transfer(eve, 1);

        // not even by the pool's own address: the escrow only burns or returns
        vm.prank(address(pool));
        vm.expectRevert(InsuranceStaking.InsuranceStaking_EscrowedShares.selector);
        pool.transfer(eve, 1);
        vm.prank(eve);
        vm.expectRevert(); // no allowance from the escrow exists, and none can be granted usefully
        pool.transferFrom(address(pool), eve, 1);
    }

    function test_H9_nothing_can_be_sent_into_the_escrow() public {
        uint256 s = _stake(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_EscrowedShares.selector);
        pool.transfer(address(pool), s);
        vm.prank(bob);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_EscrowedShares.selector);
        pool.deposit(100e6, address(pool));
    }

    function test_H9_cancel_returns_the_shares() public {
        uint256 s = _stake(alice, 1_000e6);
        _requestAll(alice);
        vm.prank(alice);
        pool.cancelWithdraw();
        assertEq(pool.balanceOf(alice), s);
        assertEq(pool.balanceOf(address(pool)), 0);
        assertEq(_requested(alice), 0);
    }

    function test_H9_expired_request_is_reclaimed_by_its_owner() public {
        uint256 s = _stake(alice, 1_000e6);
        _requestAll(alice);
        vm.warp(block.timestamp + COOLDOWN + WINDOW);
        assertFalse(pool.withdrawOpen(alice));
        assertEq(pool.maxRedeem(alice), 0);
        vm.prank(alice);
        pool.cancelWithdraw();
        assertEq(pool.balanceOf(alice), s, "every escrowed share comes back");
    }

    function test_H9_replacing_a_request_tops_up_or_returns_the_escrow() public {
        uint256 s = _stake(alice, 1_000e6);
        vm.prank(alice);
        pool.requestWithdraw(s / 4);
        vm.prank(alice);
        pool.requestWithdraw(s / 2); // up: another quarter moves in
        assertEq(pool.balanceOf(address(pool)), s / 2);
        assertEq(pool.balanceOf(alice), s - s / 2);
        vm.prank(alice);
        pool.requestWithdraw(s / 8); // down: the difference comes back
        assertEq(pool.balanceOf(address(pool)), s / 8);
        assertEq(pool.balanceOf(alice), s - s / 8);
        vm.prank(alice);
        pool.requestWithdraw(s); // all of it, counting what is already escrowed
        assertEq(pool.balanceOf(alice), 0);
        assertEq(pool.balanceOf(address(pool)), s);
    }

    /// @notice K2 PoC H02, fixed. v1: shuttle the same shares across five addresses, each with a
    ///         staggered request, and exit instantly at any moment. v2: a request holds its shares,
    ///         so there is nothing left to shuttle, and the honest staker is not left alone.
    function test_H02_cooldown_can_no_longer_be_bypassed_by_transfer() public {
        address[5] memory e;
        for (uint256 k = 0; k < 5; k++) {
            e[k] = makeAddr(string(abi.encodePacked("eve", k)));
        }
        usdg.mint(e[0], 5_000e6);
        vm.startPrank(e[0]);
        usdg.approve(address(pool), type(uint256).max);
        uint256 shares = pool.deposit(5_000e6, e[0]);
        vm.stopPrank();
        _stake(bob, 5_000e6);

        uint256 t0 = block.timestamp;
        vm.prank(e[0]);
        pool.requestWithdraw(shares);
        for (uint256 k = 1; k < 5; k++) {
            vm.warp(t0 + k * 3 days);
            vm.prank(e[k - 1]);
            vm.expectRevert(); // the shares are in escrow: there is nothing to move
            pool.transfer(e[k], shares);
            vm.prank(e[k]);
            vm.expectRevert(InsuranceStaking.InsuranceStaking_ExceedsBalance.selector);
            pool.requestWithdraw(shares);
        }

        vm.warp(t0 + 17 days + 5 hours); // the PoC's arbitrary moment; e[0]'s only window has closed
        _requestAll(bob);
        for (uint256 k = 0; k < 5; k++) {
            assertEq(pool.maxRedeem(e[k]), 0, "no instant exit anywhere");
        }
        assertEq(pool.totalSupply(), shares + _requested(bob), "both stakers still carry the next draw");
    }

    // ------------------------------------------------------------------ yield vests (M-14)

    function test_income_vests_into_the_share_price_for_everyone_including_cooldown() public {
        _stake(alice, 1_000e6);
        _stake(bob, 3_000e6);
        _requestAll(alice); // in cooldown: still earns
        usdg.mint(address(pool), 400e6);
        assertEq(pool.totalAssets(), 4_000e6, "no step on arrival");
        pool.sync();
        assertEq(pool.totalAssets(), 4_000e6, "no step on sync");
        vm.warp(block.timestamp + VEST / 2);
        assertApproxEqAbs(pool.totalAssets(), 4_200e6, 1, "half vested half way");
        vm.warp(block.timestamp + VEST / 2);
        assertEq(pool.totalAssets(), 4_400e6);
        assertApproxEqAbs(pool.convertToAssets(_requested(alice)), 1_100e6, 2);
        assertApproxEqAbs(pool.convertToAssets(pool.balanceOf(bob)), 3_300e6, 2);
    }

    function test_M14_new_income_rolls_the_remainder_into_a_fresh_schedule() public {
        _stake(alice, 1_000e6);
        usdg.mint(address(pool), 700e6);
        pool.sync();
        vm.warp(block.timestamp + VEST / 2);
        assertApproxEqAbs(pool.unvestedIncome(), 350e6, 1);
        uint256 assetsBefore = pool.totalAssets();
        usdg.mint(address(pool), 100e6);
        pool.sync();
        assertEq(pool.totalAssets(), assetsBefore, "a new arrival never steps the price either");
        assertApproxEqAbs(pool.unvestedIncome(), 450e6, 1);
        assertEq(pool.vestingEnd(), block.timestamp + VEST);
        vm.warp(block.timestamp + VEST / 2);
        assertApproxEqAbs(pool.unvestedIncome(), 225e6, 1);
        vm.warp(block.timestamp + VEST / 2);
        assertEq(pool.unvestedIncome(), 0);
        assertEq(pool.totalAssets(), 1_800e6);
    }

    function test_M14_sync_without_income_changes_nothing() public {
        _stake(alice, 1_000e6);
        usdg.mint(address(pool), 700e6);
        pool.sync();
        uint64 end = pool.vestingEnd();
        vm.warp(block.timestamp + 1 days);
        uint256 a = pool.totalAssets();
        pool.sync(); // anyone, any time: re-checkpoints, does not stretch or step
        assertEq(pool.totalAssets(), a);
        assertEq(pool.vestingEnd(), end);
    }

    /// @notice K2 PoC M01, fixed. v1: with an open window, deposit fresh capital, trigger the
    ///         distribution and redeem, all in one transaction, for a riskless share of the fees.
    ///         v2: only escrowed shares redeem, and the distribution does not move the price.
    function test_M01_atomic_deposit_distribute_redeem_earns_nothing() public {
        address[] memory r = new address[](2);
        uint256[] memory s = new uint256[](2);
        (r[0], r[1]) = (address(pool), makeAddr("treasury"));
        (s[0], s[1]) = (7_000, 3_000);
        FeeVault fv = new FeeVault(IERC20(address(usdg)), r, s);

        _stake(bob, 2_000e6); // honest staker, carries the risk all along
        uint256 armed = _stake(eve, 1_000e6);
        vm.prank(eve);
        pool.requestWithdraw(armed);
        usdg.mint(address(fv), 18e6); // fee income waiting to be distributed: 12.6 to the pool
        vm.warp(block.timestamp + COOLDOWN);

        uint256 eveBefore = usdg.balanceOf(eve);
        vm.startPrank(eve);
        uint256 fresh = pool.deposit(1_000e6, eve);
        fv.distribute();
        vm.expectRevert(); // the fresh shares are not the request: they are not redeemable at all
        pool.redeem(armed + fresh, eve, eve);
        uint256 back = pool.redeem(armed, eve, eve);
        vm.stopPrank();

        assertLe(back, 1_000e6, "the armed shares took none of the distribution");
        assertEq(usdg.balanceOf(eve) + 1_000e6, eveBefore + back, "and the fresh 1,000 is still in the pool");
        assertEq(pool.balanceOf(eve), fresh);
        assertEq(pool.maxRedeem(eve), 0);
        assertEq(pool.unvestedIncome(), 12.6e6, "the income waits to vest to whoever stays");
    }

    /// @notice Pre-audit L-3: fees sent while nobody is staked. v1 let the virtual shares absorb
    ///         them. v2 holds them unvested until there are shares, then vests them to the stakers.
    function test_L3_income_with_no_stakers_waits_then_vests_to_the_first_stakers() public {
        usdg.mint(address(pool), 100e6);
        pool.sync();
        vm.warp(block.timestamp + 30 days);
        assertEq(pool.unvestedIncome(), 100e6, "nothing vests while there are no shares");
        assertEq(pool.totalAssets(), 0);

        uint256 s = _stake(alice, 1_000e6);
        assertApproxEqAbs(pool.convertToAssets(s), 1_000e6, 1, "the first depositor does not capture it for free");
        vm.warp(block.timestamp + VEST / 2);
        assertApproxEqAbs(pool.convertToAssets(s), 1_050e6, 2);
        vm.warp(block.timestamp + VEST / 2);
        assertApproxEqAbs(pool.convertToAssets(s), 1_100e6, 2, "it vests to the stakers, not to the virtual shares");
    }

    function test_L3_remainder_freezes_when_the_last_staker_leaves() public {
        uint256 s = _stake(alice, 1_000e6);
        _requestAll(alice);
        vm.warp(block.timestamp + COOLDOWN - VEST / 2);
        usdg.mint(address(pool), 700e6);
        pool.sync();
        vm.warp(block.timestamp + VEST / 2); // window opens with half vested
        vm.prank(alice);
        uint256 out = pool.redeem(s, alice, alice);
        assertApproxEqAbs(out, 1_350e6, 2);
        assertEq(pool.totalSupply(), 0);
        uint256 frozen = pool.unvestedIncome();
        assertApproxEqAbs(frozen, 350e6, 2);
        vm.warp(block.timestamp + 60 days);
        assertEq(pool.unvestedIncome(), frozen, "frozen with no shares");
        uint256 sb = _stake(bob, 1_000e6);
        vm.warp(block.timestamp + VEST);
        assertApproxEqAbs(pool.convertToAssets(sb), 1_000e6 + frozen, 10, "and vests to whoever stakes next");
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
        pool.proposeDraw(address(vault), 100e6);
        vm.prank(gov);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_NotAVault.selector);
        pool.proposeDraw(eve, 100e6);
    }

    function test_draw_is_capped_at_proposal() public {
        _stake(alice, 1_000e6);
        vm.prank(gov);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_DrawAboveCap.selector);
        pool.proposeDraw(address(vault), 300e6 + 1);
    }

    function test_draw_waits_for_the_delay_then_anyone_executes() public {
        _stake(alice, 1_000e6);
        vm.prank(gov);
        uint256 id = pool.proposeDraw(address(vault), 300e6);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_DrawNotExecutable.selector);
        pool.executeDraw(id);
        vm.warp(block.timestamp + DELAY);
        vm.prank(eve); // not governance: once decided, governance cannot also stall it
        pool.executeDraw(id);
        assertEq(usdg.balanceOf(address(vault)), 300e6, "the collateral lands in the vault");
        assertEq(vault.received(), 300e6, "through receiveInsurance");
        assertEq(pool.totalAssets(), 700e6);
        assertEq(usdg.allowance(address(pool), address(vault)), 0, "no allowance left behind");
    }

    function test_draw_loss_is_shared_pro_rata_including_cooldown_shares() public {
        _stake(alice, 1_000e6);
        _stake(bob, 3_000e6);
        _requestAll(alice); // requested exits do not escape a loss
        _draw(address(vault), 1_000e6); // 25% of 4,000
        assertApproxEqAbs(pool.convertToAssets(_requested(alice)), 750e6, 2);
        assertApproxEqAbs(pool.convertToAssets(pool.balanceOf(bob)), 2_250e6, 2);
    }

    function test_draw_expires() public {
        _stake(alice, 1_000e6);
        vm.prank(gov);
        uint256 id = pool.proposeDraw(address(vault), 100e6);
        vm.warp(block.timestamp + DELAY + pool.DRAW_EXECUTION_WINDOW());
        vm.expectRevert(InsuranceStaking.InsuranceStaking_DrawClosed.selector);
        pool.executeDraw(id);
        assertFalse(pool.drawPending(), "an expired draw no longer pauses anything");
    }

    function test_cancelled_draw_cannot_execute() public {
        _stake(alice, 1_000e6);
        vm.prank(gov);
        uint256 id = pool.proposeDraw(address(vault), 100e6);
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
        uint256 id = _draw(address(vault), 100e6);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_DrawClosed.selector);
        pool.executeDraw(id);
    }

    function test_pending_draw_pauses_exits_and_deposits_then_releases() public {
        _stake(alice, 1_000e6);
        uint256 s = _requestAll(alice);
        vm.warp(block.timestamp + COOLDOWN); // alice's window is open...
        vm.prank(gov);
        uint256 id = pool.proposeDraw(address(vault), 100e6); // ...and a draw is announced
        assertTrue(pool.drawPending());
        assertEq(pool.maxRedeem(alice), 0, "cannot leave ahead of an announced loss");
        assertEq(pool.maxDeposit(bob), 0, "cannot walk into an announced loss");
        vm.prank(alice);
        vm.expectRevert();
        pool.redeem(s, alice, alice);

        vm.warp(block.timestamp + DELAY);
        pool.executeDraw(id);
        assertFalse(pool.drawPending());
        assertGt(pool.maxDeposit(bob), 0, "deposits reopen");
        assertGt(pool.maxRedeem(alice), 0, "and alice's window is still open (M-2)");
    }

    /// @notice L-14, accepted: shares not in escrow stay transferable during a pause. The receiver
    ///         still has no request, so nothing leaves the pool.
    function test_L14_free_shares_transfer_during_a_pause_but_cannot_exit() public {
        uint256 s = _stake(alice, 1_000e6);
        vm.prank(gov);
        pool.proposeDraw(address(vault), 100e6);
        vm.prank(alice);
        pool.transfer(eve, s);
        assertEq(pool.maxRedeem(eve), 0);
        assertEq(pool.totalSupply(), s);
    }

    function test_governance_cannot_hold_stakers_by_reproposing() public {
        _stake(alice, 1_000e6);
        vm.prank(gov);
        pool.proposeDraw(address(vault), 10e6);
        vm.warp(block.timestamp + DELAY + pool.DRAW_EXECUTION_WINDOW()); // first draw expired
        vm.prank(gov);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_ProposalTooSoon.selector);
        pool.proposeDraw(address(vault), 10e6);
        assertFalse(pool.drawPending(), "exits are open in the gap");
        vm.warp(block.timestamp + 3 days); // 7 days after the first proposal
        vm.prank(gov);
        pool.proposeDraw(address(vault), 10e6);
    }

    function test_cap_rechecked_at_execution() public {
        _stake(alice, 1_000e6);
        vm.prank(gov);
        uint256 id = pool.proposeDraw(address(vault), 300e6); // exactly the cap now
        // Assets fall before execution (simulated by moving collateral out behind the pool's back:
        // the pool cannot stop a mock token doing this, which is the point of the re-check).
        vm.prank(address(pool));
        usdg.transfer(eve, 100e6);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_DrawAboveCap.selector);
        pool.executeDraw(id);
    }

    // ------------------------------------------------------------------ draw targets (H-3)

    function test_H3_no_draw_to_a_freshly_registered_vault() public {
        _stake(alice, 1_000e6);
        MockInsurableVault fresh = new MockInsurableVault(IERC20(address(usdg)), address(0xCE28));
        reg.set(address(fresh), true);
        vm.prank(gov);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_VaultTooNew.selector);
        pool.proposeDraw(address(fresh), 100e6);
        vm.warp(block.timestamp + REG_DELAY - 1);
        vm.prank(gov);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_VaultTooNew.selector);
        pool.proposeDraw(address(fresh), 100e6);
        vm.warp(block.timestamp + 1);
        vm.prank(gov);
        pool.proposeDraw(address(fresh), 100e6);
    }

    function test_H3_a_registry_that_reports_no_registration_time_is_refused() public {
        _stake(alice, 1_000e6);
        reg.setRegisteredAt(address(vault), 0);
        vm.prank(gov);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_VaultTooNew.selector);
        pool.proposeDraw(address(vault), 100e6);
    }

    function test_H3_no_draw_to_a_retired_vault() public {
        _stake(alice, 1_000e6);
        vault.setRetired(true);
        vm.prank(gov);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_VaultRetired.selector);
        pool.proposeDraw(address(vault), 100e6);

        // and retiring it during the delay stops the execution
        vault.setRetired(false);
        vm.prank(gov);
        uint256 id = pool.proposeDraw(address(vault), 100e6);
        vault.setRetired(true);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_VaultRetired.selector);
        pool.executeDraw(id);
    }

    function test_H3_execution_rechecks_registration() public {
        _stake(alice, 1_000e6);
        vm.prank(gov);
        uint256 id = pool.proposeDraw(address(vault), 100e6);
        reg.set(address(vault), false);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_NotAVault.selector);
        pool.executeDraw(id);
    }

    function test_H3_no_draw_without_a_shortfall() public {
        _stake(alice, 1_000e6);
        vault.setShortfall(0);
        vm.prank(gov);
        uint256 id = pool.proposeDraw(address(vault), 100e6);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_NoShortfall.selector);
        pool.executeDraw(id);
    }

    function test_H3_draw_is_capped_at_the_shortfall() public {
        _stake(alice, 1_000e6);
        vault.setShortfall(40e6);
        uint256 id = _draw(address(vault), 300e6);
        assertEq(_paid(id), 40e6, "pays what the vault needs, not what was proposed");
        assertEq(usdg.balanceOf(address(vault)), 40e6);
        assertEq(pool.totalAssets(), 960e6);
        assertEq(vault.insuranceShortfall(), 0);
    }

    function test_H3_a_vault_that_does_not_pull_the_draw_reverts_it() public {
        _stake(alice, 1_000e6);
        vault.setMode(MockInsurableVault.Mode.PullsNothing);
        vm.prank(gov);
        uint256 id = pool.proposeDraw(address(vault), 100e6);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_DrawNotPaid.selector);
        pool.executeDraw(id);
        vault.setMode(MockInsurableVault.Mode.PullsHalf);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_DrawNotPaid.selector);
        pool.executeDraw(id);
    }

    function test_H3_a_vault_cannot_reenter_the_pool_during_a_draw() public {
        _stake(alice, 1_000e6);
        usdg.mint(address(vault), 10e6);
        vm.prank(gov);
        uint256 id = pool.proposeDraw(address(vault), 100e6);
        vm.warp(block.timestamp + DELAY);
        vault.setMode(MockInsurableVault.Mode.ReentersDeposit);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        pool.executeDraw(id);
        vault.setMode(MockInsurableVault.Mode.ReentersSync);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        pool.executeDraw(id);
    }

    /// @notice H-3 (d): executed draws in any 30 days total at most maxDrawBps of the pool at the
    ///         start of those 30 days. v1 allowed a fresh 30% every 7 days.
    function test_H3_rolling_cap_across_draws() public {
        _stake(alice, 1_000e6);
        uint256 id = _draw(address(vault), 300e6);
        uint256 executedAt = block.timestamp;
        assertEq(pool.drawCap(), 0, "the period's cap is spent");
        vm.warp(executedAt + 7 days);
        vm.prank(gov);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_DrawAboveCap.selector);
        pool.proposeDraw(address(vault), 1);
        vm.warp(executedAt + pool.DRAW_CAP_PERIOD() - 1);
        assertEq(pool.drawCap(), 0);
        vm.warp(executedAt + pool.DRAW_CAP_PERIOD());
        assertEq(pool.drawnInPeriod(), 0);
        assertEq(pool.drawCap(), 210e6, "a new period: 30% of what is left");
        assertEq(_paid(id), 300e6);
    }

    function test_H3_rolling_cap_binds_a_window_that_straddles_two_draws() public {
        _stake(alice, 1_000e6);
        _draw(address(vault), 100e6); // day 0
        vm.warp(block.timestamp + 20 days);
        // 30% of (900 now + 100 drawn) = 300, less the 100 already drawn
        assertEq(pool.drawCap(), 200e6);
        _draw(address(vault), 200e6); // day ~21
        vm.warp(block.timestamp + 10 days); // the first draw has left the trailing period
        // trailing period holds only the 200: 30% of (700 + 200) = 270, less 200
        assertEq(pool.drawnInPeriod(), 200e6);
        assertEq(pool.drawCap(), 70e6, "no fresh 30% just because the first draw aged out");
    }

    /// @notice K2 PoC H01, fixed, against a REAL CertFactory. v1: the Safe registers an empty
    ///         vault, retires it, and draws 30% into it weekly, sweeping each draw back to itself:
    ///         65.7% of the pool in 21 days. v2: the fresh registration is refused, the retired
    ///         vault is refused, a vault with no shortfall is refused, and even a vault that lies
    ///         about its shortfall gets one capped slice per 30 days, after a public delay.
    function test_H01_governance_can_no_longer_drain_through_a_new_or_retired_vault() public {
        CertFactory factory = new CertFactory(address(0x1), address(0x2), address(0x3), gov);
        pool = _make(IVaultRegistry(address(factory)), COOLDOWN, WINDOW, DELAY, CAP_BPS, POOL_CAP, REG_DELAY);
        for (uint256 i = 0; i < 2; i++) {
            address u = [bob, eve][i];
            vm.prank(u);
            usdg.approve(address(pool), type(uint256).max);
        }
        _stake(bob, 6_000e6);
        _stake(eve, 4_000e6);
        uint256 start = pool.totalAssets();

        MockInsurableVault shell = new MockInsurableVault(IERC20(address(usdg)), address(0xCE29));
        vm.prank(gov);
        factory.registerVault(address(shell), address(0xCE29));
        assertEq(factory.registeredAt(address(shell)), block.timestamp);
        assertTrue(factory.isVault(address(shell)));

        // 1. straight away: refused, the registration is too new
        uint256 cap0 = pool.drawCap();
        vm.prank(gov);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_VaultTooNew.selector);
        pool.proposeDraw(address(shell), cap0);

        // 2. a full cooldown + window later, retired and empty: refused
        vm.warp(block.timestamp + REG_DELAY);
        shell.setRetired(true);
        vm.prank(gov);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_VaultRetired.selector);
        pool.proposeDraw(address(shell), cap0);

        // 3. not retired but nothing owed: the proposal pauses exits for a while, then pays nothing
        shell.setRetired(false);
        shell.setShortfall(0);
        vm.prank(gov);
        uint256 id = pool.proposeDraw(address(shell), cap0);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(InsuranceStaking.InsuranceStaking_NoShortfall.selector);
        pool.executeDraw(id);

        // 4. worst case: the contract lies about a huge shortfall. Three weekly cycles as in the PoC.
        shell.setShortfall(type(uint128).max);
        uint256 taken;
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 7 days);
            uint256 c = pool.drawCap();
            if (c == 0) {
                vm.prank(gov);
                vm.expectRevert(InsuranceStaking.InsuranceStaking_DrawAboveCap.selector);
                pool.proposeDraw(address(shell), 1);
                continue;
            }
            vm.prank(gov);
            id = pool.proposeDraw(address(shell), c);
            vm.warp(block.timestamp + DELAY);
            pool.executeDraw(id);
            taken += _paid(id);
        }
        assertEq(usdg.balanceOf(gov), 0, "nothing reaches governance through the pool");
        assertEq(taken, start * CAP_BPS / 10_000, "one capped slice in 30 days, not three");
        assertEq(pool.totalAssets(), start - taken);
    }

    // ------------------------------------------------------------------ M-2 / L01

    /// @notice K2 PoC L01, fixed: a proposal timed just before a staker's window opens can no
    ///         longer run the whole window out. The pause ends with at least a day left.
    function test_L01_a_timed_proposal_cannot_close_a_whole_window() public {
        _stake(alice, 1_000e6);
        uint256 s = _requestAll(alice);
        (, uint64 readyAt) = pool.withdrawRequests(alice);
        vm.warp(readyAt - 1 hours);
        vm.prank(gov);
        pool.proposeDraw(address(vault), 1); // left to expire
        vm.warp(readyAt - 1 hours + DELAY + pool.DRAW_EXECUTION_WINDOW());
        assertFalse(pool.drawPending());
        assertTrue(pool.withdrawOpen(alice), "the window outlasted the pause");
        vm.prank(alice);
        pool.redeem(s, alice, alice);
    }

    /// @dev M-2: wherever a proposal lands, from the request to the window's last second, at least
    ///      a day of the window is unpaused, and the staker can really redeem in it.
    function testFuzz_M2_every_window_has_an_unpaused_day(uint32 offset) public {
        _stake(alice, 1_000e6);
        _requestAll(alice);
        (, uint64 readyAt) = pool.withdrawRequests(alice);
        uint256 closesAt = uint256(readyAt) + WINDOW;
        uint256 at = block.timestamp + bound(offset, 0, COOLDOWN + WINDOW - 1);
        uint256 open;
        if (at > readyAt) {
            vm.warp(readyAt);
            assertGt(pool.maxRedeem(alice), 0, "open before the proposal");
            open += at - readyAt;
        }
        vm.warp(at);
        vm.prank(gov);
        pool.proposeDraw(address(vault), 1);
        assertEq(pool.maxRedeem(alice), 0, "paused");
        uint256 pauseEnd = at + DELAY + pool.DRAW_EXECUTION_WINDOW();
        uint256 t = pauseEnd > readyAt ? pauseEnd : readyAt;
        if (t < closesAt) {
            vm.warp(t);
            assertFalse(pool.drawPending());
            assertGt(pool.maxRedeem(alice), 0, "open after the pause");
            open += closesAt - t;
        }
        assertGe(open, 1 days, "at least a day of the window is unpaused");
    }

    // ------------------------------------------------------------------ invariant-style

    /// @dev Across random deposits, income and one draw, nobody can take out more than the pool
    ///      holds, and the pool never owes more than it has.
    function testFuzz_solvency_of_the_pool(uint96 a, uint96 b, uint96 income, uint16 drawBps, uint32 vestFor) public {
        uint256 da = bound(a, 1e6, 500_000e6);
        uint256 db = bound(b, 1e6, 500_000e6);
        _stake(alice, da);
        _stake(bob, db);
        usdg.mint(address(pool), bound(income, 0, 100_000e6));
        pool.sync();
        vm.warp(block.timestamp + bound(vestFor, 0, 2 * VEST));
        uint256 amt = pool.drawCap() * bound(drawBps, 1, 10_000) / 10_000;
        if (amt > 0) _draw(address(vault), amt);
        uint256 owed = pool.convertToAssets(pool.balanceOf(alice)) + pool.convertToAssets(pool.balanceOf(bob));
        assertLe(owed, pool.totalAssets(), "never owes more than it holds");
        uint256 sa = _requestAll(alice);
        uint256 sb = _requestAll(bob);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(alice);
        pool.redeem(sa, alice, alice);
        vm.prank(bob);
        pool.redeem(sb, bob, bob);
        assertEq(pool.totalSupply(), 0);
        assertLe(pool.totalAssets(), usdg.balanceOf(address(pool)));
    }

    /// @dev H-9: every escrowed request can be paid, in full, at the share price of the moment,
    ///      whatever income, vesting and draws happened while it waited.
    function testFuzz_every_escrowed_request_is_payable(
        uint96 a,
        uint96 b,
        uint96 c,
        uint16 fa,
        uint16 fb,
        uint96 income,
        uint32 vestFor,
        uint16 drawBps
    ) public {
        _stake(alice, bound(a, 1e6, 500_000e6));
        _stake(bob, bound(b, 1e6, 500_000e6));
        _stake(eve, bound(c, 1, 500_000e6));
        // hoisted: an external call in the argument list would consume the prank
        uint256 qa = pool.balanceOf(alice) * bound(fa, 1, 10_000) / 10_000;
        uint256 qb = pool.balanceOf(bob) * bound(fb, 1, 10_000) / 10_000;
        vm.prank(alice);
        pool.requestWithdraw(qa);
        vm.prank(bob);
        pool.requestWithdraw(qb);
        _requestAll(eve);
        usdg.mint(address(pool), bound(income, 0, 200_000e6));
        pool.sync();
        vm.warp(block.timestamp + bound(vestFor, 0, 8 days));
        uint256 amt = pool.drawCap() * bound(drawBps, 0, 10_000) / 10_000;
        if (amt > 0) _draw(address(vault), amt);
        vm.warp(block.timestamp + COOLDOWN - bound(vestFor, 0, 8 days) - (amt > 0 ? DELAY : 0));

        address[3] memory us = [alice, bob, eve];
        uint256 owed;
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(pool.withdrawOpen(us[i]));
            owed += pool.previewRedeem(_requested(us[i]));
        }
        assertEq(pool.balanceOf(address(pool)), _requested(alice) + _requested(bob) + _requested(eve), "escrow == requests");
        assertLe(owed, pool.totalAssets(), "every escrowed request fits in the assets");
        assertLe(pool.totalAssets(), usdg.balanceOf(address(pool)));
        for (uint256 i = 0; i < 3; i++) {
            uint256 req = _requested(us[i]);
            uint256 quote = pool.previewRedeem(req);
            uint256 before = usdg.balanceOf(us[i]);
            vm.prank(us[i]);
            assertEq(pool.redeem(req, us[i], us[i]), quote);
            assertEq(usdg.balanceOf(us[i]) - before, quote);
        }
        assertEq(pool.balanceOf(address(pool)), 0);
        assertLe(pool.totalAssets(), usdg.balanceOf(address(pool)));
    }

    /// @dev M-14: across a random sequence of deposits, donations, syncs, time, requests, redeems
    ///      and draws, totalAssets() never exceeds the balance, unvested income is always in the
    ///      balance, the escrow always equals the open requests, and no single step raises the
    ///      share value of a unit of assets by an arrival of income.
    function testFuzz_totalAssets_never_exceeds_balance(uint256 seed) public {
        address[3] memory us = [alice, bob, eve];
        for (uint256 i = 0; i < 24; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = r % 7;
            address u = us[(r >> 8) % 3];
            uint256 amt = (r >> 16) % 50_000e6 + 1;
            if (op == 0 && pool.maxDeposit(u) >= amt) {
                _stake(u, amt);
            } else if (op == 1) {
                uint256 before = pool.totalAssets();
                usdg.mint(address(pool), amt);
                assertEq(pool.totalAssets(), before, "an arrival never steps totalAssets");
                pool.sync();
                assertEq(pool.totalAssets(), before, "nor does syncing it");
            } else if (op == 2) {
                vm.warp(block.timestamp + (r >> 16) % 5 days);
            } else if (op == 3 && pool.balanceOf(u) > 0) {
                uint256 all = pool.balanceOf(u) + _requested(u);
                vm.prank(u);
                pool.requestWithdraw(all);
            } else if (op == 4 && pool.maxRedeem(u) > 0) {
                uint256 m = pool.maxRedeem(u);
                vm.prank(u);
                pool.redeem(m, u, u);
            } else if (op == 5) {
                uint256 c = pool.drawCap();
                if (c > 0 && !pool.drawPending()) {
                    vm.prank(gov);
                    try pool.proposeDraw(address(vault), c) returns (uint256 id) {
                        vm.warp(block.timestamp + DELAY);
                        try pool.executeDraw(id) {} catch {}
                    } catch {}
                }
            } else if (op == 6) {
                vm.prank(u);
                pool.cancelWithdraw();
            }
            uint256 bal = usdg.balanceOf(address(pool));
            assertLe(pool.totalAssets(), bal, "totalAssets <= balance");
            assertLe(pool.unvestedIncome(), bal, "unvested income is really here");
            assertEq(pool.balanceOf(address(pool)), _requested(alice) + _requested(bob) + _requested(eve));
            assertLe(pool.netPrincipal(), POOL_CAP);
        }
    }
}
