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

    /// @notice Task 8c: fromMargin is sized pro-rata by burned supply against postedMargin, not by
    ///         the current oracle price (see test_withdrawSizedProRataNotByPrice for the case where
    ///         that distinction actually bites).
    function test_queuedRedeemWithdrawsFromMargin() public {
        vm.prank(alice);
        uint256 id0 = vault.requestMint(50_000e6);
        lighter.settleBatch();
        vault.settleMint(id0, PX);
        uint256 bal = cert.balanceOf(alice);

        uint256 marginBefore = lighter.marginBalance();
        uint256 postedBefore = vault.postedMargin();
        uint256 supplyBefore = cert.totalSupply();
        uint256 expectedFromMargin = postedBefore * bal / supplyBefore;

        vm.prank(alice);
        uint256 id = vault.requestRedeem(bal);

        // Task 8d: the pro-rata share is now *allocated* to marginPendingRecall, not withdrawn
        // from Lighter at request time — margin behind an open position is locked by the venue's
        // initial margin requirement until the closing order fills in a batch, so
        // lighter.marginBalance() is untouched here. See CertVaultRecall.t.sol for the separate,
        // retryable recallMargin() step that actually withdraws once the position has closed.
        assertEq(lighter.marginBalance(), marginBefore);
        assertEq(vault.postedMargin(), postedBefore - expectedFromMargin);
        assertEq(vault.marginPendingRecall(), expectedFromMargin);

        lighter.settleBatch();

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.claimRedeem(id);
        assertGt(out, 0);
        assertEq(usdg.balanceOf(alice), before + out);
    }

    /// @dev Moves the Chainlink feed AND keeps the Lighter mark / oracle mark price in sync with
    ///      it, mirroring what VaultFixture.setUp() does for the initial price. pxUnguarded() (what
    ///      _queueExit prices redemptions off) reads the feed, not markPx18 — see CertOracle.
    function _setPrice(uint256 px18) internal {
        feed.set(int256(px18 / 1e10), block.timestamp); // feed has 8 decimals
        vm.prank(attester);
        oracle.setMarkPrice(px18);
        lighter.setMarkPrice(MARKET, px18);
    }

    /// @notice Task 8c's core proof: the margin withdrawal request tracks the holder's share of
    ///         what was actually posted, not a recomputation off the (now higher) price.
    function test_withdrawSizedProRataNotByPrice() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        uint256 bal = cert.balanceOf(alice);
        uint256 supplyBefore = cert.totalSupply();
        uint256 postedBefore = vault.postedMargin();
        uint256 marginBefore = lighter.marginBalance();

        uint256 raisedPx = PX * 120 / 100; // +20%
        _setPrice(raisedPx);

        // What the OLD, price-derived sizing would have requested at the raised price — this is
        // strictly more than was ever posted, which is exactly the defect this task fixes.
        uint256 gross18 = bal * raisedPx / 1e18;
        uint256 fee18 = gross18 * 10 / 10_000; // redeemFeeBps = 10
        uint256 owedCollateral = (gross18 - fee18) / 1e12; // 18 -> 6 decimals
        uint256 oldFromMargin = owedCollateral * 9_000 / 10_000; // targetMarginBps = 9_000

        uint256 expectedFromMargin = postedBefore * bal / supplyBefore;
        assertLt(expectedFromMargin, oldFromMargin);

        vm.prank(alice);
        vault.requestRedeem(bal);

        // Task 8d: the pro-rata share is allocated to marginPendingRecall, not withdrawn from
        // Lighter at request time (see _queueExit's doc comment) — so lighter.marginBalance() is
        // untouched here. The core proof this test exists for — sizing tracks what was actually
        // posted, not a recomputation off the raised price — now lives in marginPendingRecall.
        assertEq(lighter.marginBalance(), marginBefore);
        assertEq(vault.marginPendingRecall(), expectedFromMargin);
        assertEq(vault.postedMargin(), 0);
    }

    /// @notice Task 8d: _queueExit no longer calls lighter.withdraw at all — the venue's deposit
    ///         cap is therefore irrelevant to forceExit itself (it only matters to a later
    ///         recallMargin() call; see CertVaultRecall.t.sol's
    ///         test_recallMarginIsRetryableAndFailOpen for that retryability proof). This test
    ///         previously proved forceExit survives a refused withdrawal by restoring postedMargin
    ///         after a caught revert; that restore path no longer exists because there is no
    ///         withdrawal to refuse here. What must still hold: forceExit succeeds unconditionally
    ///         regardless of depositCapTicks, and its pro-rata share is allocated away from
    ///         postedMargin into marginPendingRecall permanently, not restored.
    function test_forceExitSurvivesVenueRefusingWithdraw() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        uint256 bal = cert.balanceOf(alice);
        uint256 postedBefore = vault.postedMargin();

        lighter.setDepositCapTicks(1); // would refuse a real withdrawal request; irrelevant here

        vm.prank(alice);
        uint256 id = vault.forceExit(bal);

        assertGt(id, 0);
        assertEq(cert.balanceOf(alice), 0);
        (address user,,,, bool paid) = vault.redeemReceipts(id);
        assertEq(user, alice);
        assertFalse(paid);
        assertEq(vault.postedMargin(), 0); // fully allocated away, not restored
        assertEq(vault.marginPendingRecall(), postedBefore); // allocation landed in the recall counter
    }

    /// @notice Load-bearing regression: under the old price-derived sizing, fromMargin could
    ///         outgrow postedMargin after a large price move, and forceExit — the Law 2
    ///         backstop — could hard-revert on the venue's depositCapTicks check. The task-8c
    ///         report records verifying this test fails when the old sizing is restored.
    function test_forceExitSurvivesAfterLargePriceRise() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        uint256 bal = cert.balanceOf(alice);

        _setPrice(PX * 10); // 10x

        vm.prank(alice);
        uint256 id = vault.forceExit(bal);

        assertGt(id, 0);
        assertEq(cert.balanceOf(alice), 0);
    }

    /// @notice Redeeming in unequal parts must not strand margin: each partial redemption
    ///         allocates exactly its pro-rata share of what remains posted to marginPendingRecall,
    ///         and the sum across all parts recovers the original posted margin (up to
    ///         floor-division dust).
    /// @dev Task 8d: this test previously measured the sum via lighter.marginBalance() dropping,
    ///      because _queueExit used to submit a withdrawal per partial redeem. It no longer does
    ///      (margin behind an open position is locked by IMR until the closing order fills — see
    ///      _queueExit's doc comment) — so the conservation proof now runs against
    ///      marginPendingRecall, which accumulates the allocation instead of lighter.marginBalance
    ///      dropping. lighter.marginBalance() is asserted unchanged throughout.
    function test_partialRedemptionsDoNotStrandMargin() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        uint256 bal = cert.balanceOf(alice);

        uint256 part1 = bal * 20 / 100;
        uint256 part2 = bal * 35 / 100;
        uint256 part3 = bal - part1 - part2; // remainder: sums exactly to bal

        uint256 originalPosted = vault.postedMargin();
        uint256 marginBefore = lighter.marginBalance();
        uint256 totalAllocated;

        totalAllocated += _redeemPartAndCheck(part1);
        totalAllocated += _redeemPartAndCheck(part2);
        totalAllocated += _redeemPartAndCheck(part3);

        assertEq(cert.balanceOf(alice), 0);
        assertEq(vault.postedMargin(), 0);
        assertEq(vault.marginPendingRecall(), totalAllocated);
        assertEq(lighter.marginBalance(), marginBefore); // untouched — no withdrawal submitted
        assertApproxEqAbs(totalAllocated, originalPosted, 2);
    }

    /// @dev Redeems `certIn` from alice, asserting postedMargin lands exactly where the same
    ///      pro-rata formula the contract uses says it should, and returns the amount allocated to
    ///      marginPendingRecall (Task 8d: allocation, not a venue withdrawal — see _queueExit).
    function _redeemPartAndCheck(uint256 certIn) internal returns (uint256 allocated) {
        uint256 supply = cert.totalSupply();
        uint256 posted = vault.postedMargin();
        uint256 expectedFromMargin = posted * certIn / supply;
        uint256 pendingBefore = vault.marginPendingRecall();

        vm.prank(alice);
        vault.requestRedeem(certIn);

        allocated = vault.marginPendingRecall() - pendingBefore;
        assertEq(allocated, expectedFromMargin);
        assertEq(vault.postedMargin(), posted - expectedFromMargin);
    }

    /// @notice postedMargin must account for bootstrap()'s registering dust deposit too, so the
    ///         counter matches every deposit the vault has ever made to Lighter.
    function test_postedMarginCountsBootstrapDust() public view {
        // VaultFixture.setUp() already called bootstrap(); nothing else has posted margin since.
        assertEq(vault.postedMargin(), 1e6); // dust = 10 ** collateralDecimals, USDG has 6
    }
}
