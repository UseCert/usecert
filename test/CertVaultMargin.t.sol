// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {CertVault} from "../src/CertVault.sol";
import {VaultFixture} from "./helpers/VaultFixture.sol";
import {MockLighter} from "./mocks/MockLighter.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice Task 8b: proves the vault posts margin behind the perp position it opens on Lighter
///         (Law 1), that leverage stays bounded by contract constants no governance can widen
///         (Law 6), and that the resulting instant-redeem gate does not compromise Law 2's
///         unconditionally-open queued exits.
contract CertVaultMarginTest is VaultFixture {
    function test_mintPostsTargetShareAsMargin() public {
        uint256 amountIn = 3_558.6e6;
        uint256 bufferBefore = vault.hotBuffer();
        uint256 marginBefore = lighter.marginBalance();

        vm.prank(alice);
        vault.mintInstant(amountIn);

        uint256 fee = amountIn * 10 / 10_000; // mintFeeBps = 10
        uint256 net = amountIn - fee;
        uint256 expectedMarginPosted = net * 9_000 / 10_000; // targetMarginBps = 9_000

        assertEq(lighter.marginBalance(), marginBefore + expectedMarginPosted);
        assertEq(vault.hotBuffer(), bufferBefore + amountIn - expectedMarginPosted);
    }

    function test_mintWouldFailWithoutMargin() public {
        lighter.setRequiredMarginBps(5_000);

        vm.prank(alice);
        vault.mintInstant(3_558.6e6);

        // Step 3's fix: margin was posted before the hedge, so settlement does not revert.
        lighter.settleBatch();
        assertGt(lighter.marginBalance(), 0);

        // Load-bearing check: prove InsufficientMargin is a real gate, not a vacuous one. Note
        // MockLighter tracks marginBalance and positionBase globally, not per account, so this
        // cannot be shown by adding a second small order to the shared `lighter` above — the
        // vault's own margin would trivially cover it. Instead reproduce the pre-fix scenario on
        // an independent mock/account: the SAME-SIZED hedge order the vault above just submitted
        // (99_900 base ticks, the vault's certOut of 9.99e18 at sizeDecimals = 4), backed by only
        // bootstrap-sized dust margin instead of the 90% share _postMargin posts. This is exactly
        // the failure mode recorded in task-8b-report.md: 9 tests reverted with
        // InsufficientMargin() when Step 6 landed before Step 3 wired _postMargin in.
        MockLighter bareLighter = new MockLighter(IERC20(address(usdg)), ASSET_IDX, 4);
        bareLighter.setMarkPrice(MARKET, PX);
        usdg.mint(address(this), 1e6);
        usdg.approve(address(bareLighter), 1e6);
        bareLighter.deposit(address(this), ASSET_IDX, 0, 1e6); // ~$1 dust margin, no real backing
        uint48 idx = bareLighter.addressToAccountIndex(address(this));
        bareLighter.createOrder(idx, MARKET, 99_900, 35586, 0, 1); // same size as the vault's hedge
        vm.expectRevert(MockLighter.InsufficientMargin.selector);
        bareLighter.settleBatch();
    }

    function test_leverageStaysAtOrBelowTwo() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();

        int256 pos = lighter.positionBase(MARKET);
        uint256 absPos = pos >= 0 ? uint256(pos) : uint256(-pos);
        uint256 notional18 = absPos * lighter.markPrice(MARKET) / (10 ** 4); // sizeDecimals = 4
        uint256 marginBalance18 = lighter.marginBalance() * 1e12; // USDG has 6 decimals

        uint256 leverage = notional18 * 1e18 / marginBalance18;
        assertLe(leverage, 2e18);
    }

    function test_constructorRejectsTargetMarginBelowFloor() public {
        vm.expectRevert(CertVault.CertVault_TargetMarginOutOfBounds.selector);
        new CertVault(
            CertVault.Deps({
                lighter: address(lighter),
                oracle: address(oracle),
                registry: address(reg),
                capacity: address(cap),
                governance: gov
            }),
            CertVault.VaultConfig({
                collateral: address(usdg),
                collateralAssetIndex: ASSET_IDX,
                routeType: 0,
                marketIndex: MARKET,
                sizeDecimals: 4,
                mintFeeBps: 10,
                redeemFeeBps: 10,
                instantCap18: 10_000e18,
                settleBandBps: 500,
                targetMarginBps: 4_999
            }),
            "UseCert TSLA",
            "uTSLA"
        );
    }

    function test_constructorRejectsTargetMarginAboveCeiling() public {
        vm.expectRevert(CertVault.CertVault_TargetMarginOutOfBounds.selector);
        new CertVault(
            CertVault.Deps({
                lighter: address(lighter),
                oracle: address(oracle),
                registry: address(reg),
                capacity: address(cap),
                governance: gov
            }),
            CertVault.VaultConfig({
                collateral: address(usdg),
                collateralAssetIndex: ASSET_IDX,
                routeType: 0,
                marketIndex: MARKET,
                sizeDecimals: 4,
                mintFeeBps: 10,
                redeemFeeBps: 10,
                instantCap18: 10_000e18,
                settleBandBps: 500,
                targetMarginBps: 10_001
            }),
            "UseCert TSLA",
            "uTSLA"
        );
    }

    /// @notice Law 2 guard for this task: the fast path may route away, but the always-open
    ///         path must always still work. Both halves are required — this test is not
    ///         satisfied by the first assertion alone.
    function test_redeemInstantRoutesToQueuedWhenHotBufferShort() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        uint256 bal = cert.balanceOf(alice);

        // Drain the hot buffer directly, simulating an empty instant-redeem float.
        uint256 buf = vault.hotBuffer();
        vm.prank(address(vault));
        usdg.transfer(makeAddr("sink"), buf);
        assertEq(vault.hotBuffer(), 0);

        vm.prank(alice);
        vm.expectRevert(CertVault.CertVault_UseQueuedRedeem.selector);
        vault.redeemInstant(bal);

        // The always-open path must still work with the hot buffer empty.
        vm.prank(alice);
        uint256 id = vault.forceExit(bal);
        assertGt(id, 0);
        assertEq(cert.balanceOf(alice), 0);
    }

    function test_queuedRedeemWithdrawsFromMargin() public {
        vm.prank(alice);
        uint256 id0 = vault.requestMint(50_000e6);
        lighter.settleBatch();
        vault.settleMint(id0, PX);
        uint256 bal = cert.balanceOf(alice);

        uint256 marginBefore = lighter.marginBalance();

        (uint256 px18,) = oracle.pxUnguarded();
        uint256 gross18 = bal * px18 / 1e18;
        uint256 fee18 = gross18 * 10 / 10_000; // redeemFeeBps = 10
        uint256 owed18 = gross18 - fee18;
        uint256 owedCollateral = owed18 / 1e12; // 18 -> 6 decimals
        uint256 expectedFromMargin = owedCollateral * 9_000 / 10_000; // targetMarginBps = 9_000

        vm.prank(alice);
        uint256 id = vault.requestRedeem(bal);

        assertEq(lighter.marginBalance(), marginBefore - expectedFromMargin);

        lighter.settleBatch();

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.claimRedeem(id);
        assertGt(out, 0);
        assertEq(usdg.balanceOf(alice), before + out);
    }
}
