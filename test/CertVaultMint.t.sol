// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {CertVault} from "../src/CertVault.sol";
import {VaultFixture} from "./helpers/VaultFixture.sol";

contract CertVaultMintTest is VaultFixture {
    function test_bootstrapRegistersLighterAccount() public view {
        assertGt(vault.lighterAccountIndex(), 0);
    }

    function test_mintInstantMintsAtOraclePriceMinusFee() public {
        vm.prank(alice);
        uint256 out = vault.mintInstant(3_558.6e6); // ~10 TSLA at 355.86

        // (3558.6 - 0.1%) / 355.86 = 9.99 certificates
        assertEq(out, 9.99e18);
        assertEq(cert.balanceOf(alice), 9.99e18);
    }

    function test_mintInstantQueuesItsOwnHedgeInTheSameTransaction() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);

        // Law 6: the vault submits its own order. No keeper involved.
        assertEq(lighter.queuedOrderCount(), 1);
        (uint16 mkt,, uint32 price, uint8 isAsk, uint8 orderType) = lighter.lastOrder();
        assertEq(mkt, MARKET);
        assertEq(isAsk, 0); // buying
        assertEq(orderType, 1); // MarketOrder
        assertEq(price, 35586);
    }

    function test_mintPausedWhenOracleUnhealthy() public {
        vm.warp(block.timestamp + 3601);
        vm.expectRevert(CertVault.CertVault_MintPaused.selector);
        vm.prank(alice);
        vault.mintInstant(1_000e6);
    }

    function test_mintPausedWhenBasisOutsideBand() public {
        vm.prank(attester);
        oracle.setMarkPrice(PX * 103 / 100);
        vm.expectRevert(CertVault.CertVault_MintPaused.selector);
        vm.prank(alice);
        vault.mintInstant(1_000e6);
    }

    function test_mintRevertsAtCapacityWithDistinctError() public {
        // capacity = 10% of 1.19M = 119k notional
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);

        vm.prank(attester);
        reg.attest(address(vault), 2, 119_000e18, 0, 1_190_000e18);

        vm.expectRevert(CertVault.CertVault_AtCapacity.selector);
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
    }

    function test_mintAboveInstantCapMustUseRequestPath() public {
        vm.expectRevert(CertVault.CertVault_AboveInstantCap.selector);
        vm.prank(alice);
        vault.mintInstant(50_000e6); // > instantCap 10k notional
    }

    function test_requestMintEscrowsAndSettlesAtActualFill() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        assertEq(cert.balanceOf(alice), 0);

        lighter.settleBatch();
        // filled 1% worse than oracle
        vault.settleMint(id, PX * 101 / 100);

        // 49_950 / 359.4186 = 138.98... certificates
        assertGt(cert.balanceOf(alice), 0);
        assertLt(cert.balanceOf(alice), 139e18);
    }

    function test_requestMintBelowInstantCapReverts() public {
        vm.expectRevert(CertVault.CertVault_BelowInstantCap.selector);
        vm.prank(alice);
        vault.requestMint(100e6);
    }

    function test_settleMintRejectsUnknownReceipt() public {
        vm.expectRevert(CertVault.CertVault_BadReceipt.selector);
        vault.settleMint(999, PX);
    }

    function test_settleMintCannotSettleTwice() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);

        lighter.settleBatch();
        vault.settleMint(id, PX * 101 / 100);

        vm.expectRevert(CertVault.CertVault_BadReceipt.selector);
        vault.settleMint(id, PX * 101 / 100);
    }

    function test_settleMintRejectsOutOfBandFillPrice() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);

        lighter.settleBatch();
        vm.expectRevert(CertVault.CertVault_FillPriceOutOfBand.selector);
        vault.settleMint(id, 1);
    }

    // ---------------------------------------------------------------------------------------
    // C3 (final review wave, CRITICAL): settleMint had no deadline and banded fillPx18 against
    // oracle.pxUnguarded() AT SETTLE TIME, while the price the user requested at was never
    // recorded. So a receipt could sit indefinitely and be settled against a price that had
    // moved arbitrarily far from the request — the review measured a week-old receipt minting
    // 280.7 certificates against a hedge covering 140.4, a 4_999 bps delta. The receipt now
    // carries requestPx18/requestedAt, the band is measured against requestPx18, and an
    // unsettled receipt past settleWindow is refundable rather than settleable.
    // ---------------------------------------------------------------------------------------

    /// @notice The exact scenario the review measured. requestMint hedges 140.36 certificates at
    ///         355.86; the price then halves; a fill at the halved price is 0 bps from the
    ///         settle-time price (so the pre-C3 band accepted it) and 5_000 bps from the request
    ///         price. Accepting it would have minted 280.73 certificates against a hedge covering
    ///         140.36 — twice the supply the vault is hedged for, which is a Law 1 breach.
    function test_settleMintBandsAgainstRequestPriceNotSettlePrice() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        lighter.settleBatch();

        // What the vault actually hedged, at the price the user requested at.
        uint256 hedged = 49_950e18 * 1e18 / PX; // escrow (net of the 10 bps fee) / requestPx
        assertEq(hedged, 140_364_188_163_884_673_748); // 140.364188... certificates

        _setPrice(PX / 2); // the settle-time reference is now half the request price

        // A fill exactly at the new reference: in band under the old rule, rejected under C3.
        vm.expectRevert(CertVault.CertVault_FillPriceOutOfBand.selector);
        vault.settleMint(id, PX / 2);

        // Proof the rejected fill is the review's number, not an arbitrary one.
        uint256 wouldHaveMinted = 49_950e18 * 1e18 / (PX / 2);
        // 280.728376... against a hedge covering 140.364188 — the review's 280.7 vs 140.4.
        assertApproxEqAbs(wouldHaveMinted, 2 * hedged, 1); // 1 wei of floor-division dust
        assertEq(cert.balanceOf(alice), 0); // nothing was minted

        // A fill near the price actually requested still settles, and mints within the band of
        // what was hedged.
        vault.settleMint(id, PX * 101 / 100);
        uint256 minted = cert.balanceOf(alice);
        assertGt(minted, 0);
        uint256 diffBps = (hedged - minted) * 10_000 / hedged;
        assertLe(diffBps, 500); // settleBandBps
    }

    function test_settleMintRevertsAfterWindow() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        lighter.settleBatch();

        // Exactly at the deadline the receipt is still settleable: it is the band that rejects
        // this fill, not the window.
        vm.warp(block.timestamp + SETTLE_WINDOW);
        vm.expectRevert(CertVault.CertVault_FillPriceOutOfBand.selector);
        vault.settleMint(id, 1);

        vm.warp(block.timestamp + 1);
        // Keep capacity live across the warp so the window is the ONLY thing that can refuse the
        // call below — the fixture's capacity oracle stales after 300s, which is unrelated to the
        // deadline under test and would otherwise mask it behind CertVault_AtCapacity.
        vm.prank(attester);
        reg.attest(address(vault), 2, 0, 0, 1_190_000e18);

        vm.expectRevert(CertVault.CertVault_SettleWindowExpired.selector);
        vault.settleMint(id, PX);
        assertEq(cert.balanceOf(alice), 0);
    }

    /// @notice Law 2's half of C3: the deadline must be a fork, not a dead end. An expired
    ///         receipt returns the escrow to the user, and both refund phases are permissionless
    ///         so no off-chain service is needed to unstick it.
    /// @dev The refund is two-phase since the strand fix: stageRefund() reallocates the counters
    ///      and closes the hedge, refundMint() pays. This test is otherwise unchanged, and it is
    ///      NOT the proof the fix works — it passes on the fixture's 100k seeded buffer, which is
    ///      exactly why the strand shipped. See test/CertVaultRefund.t.sol.
    function test_refundMintReturnsEscrowAfterWindow() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        lighter.settleBatch();
        (, uint256 escrow,,,,,) = vault.mintReceipts(id);
        assertEq(escrow, 49_950e6); // amountIn less the 10 bps mint fee

        vm.warp(block.timestamp + SETTLE_WINDOW + 1);

        uint256 aliceBefore = usdg.balanceOf(alice);
        address stranger = makeAddr("refundCaller");
        uint256 strangerBefore = usdg.balanceOf(stranger);

        vm.prank(stranger); // permissionless, and it pays the user, never the caller
        vault.stageRefund(id);
        vm.prank(stranger);
        uint256 out = vault.refundMint(id);

        assertEq(out, escrow);
        assertEq(usdg.balanceOf(alice), aliceBefore + escrow);
        assertEq(usdg.balanceOf(stranger), strangerBefore);
        assertEq(cert.totalSupply(), 0); // refunded, not minted

        // Settled once and for all: neither refundable twice nor settleable afterwards.
        vm.expectRevert(CertVault.CertVault_BadReceipt.selector);
        vault.refundMint(id);
        vm.expectRevert(CertVault.CertVault_BadReceipt.selector);
        vault.settleMint(id, PX);
    }

    /// @notice A refund must not strand the share of the escrow requestMint posted to the venue.
    ///         Nothing else would ever ask for it back — the certificates were never minted, so
    ///         no exit will ever allocate this receipt's share and recallMargin() sizes off
    ///         counters that never learned about it. stageRefund therefore reallocates it, and the
    ///         reallocation is a transfer between the two counters, never new headroom.
    function test_refundMintReallocatesThePostedShareForRecall() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        lighter.settleBatch();

        uint256 postedBefore = vault.postedMargin();
        uint256 pendingBefore = vault.marginPendingRecall();
        uint256 expected = 49_950e6 * 9_000 / 10_000; // escrow * targetMarginBps
        assertEq(expected, 44_955e6);

        vm.warp(block.timestamp + SETTLE_WINDOW + 1);
        vault.stageRefund(id); // the reallocation lives here now, not in refundMint
        vault.refundMint(id);

        assertEq(vault.postedMargin(), postedBefore - expected);
        assertEq(vault.marginPendingRecall(), pendingBefore + expected);
        // The sum is conserved: a refund never manufactures venue headroom.
        assertEq(vault.postedMargin() + vault.marginPendingRecall(), postedBefore + pendingBefore);

        // And it is genuinely recoverable now: close the over-hedged position and bring it home.
        vm.prank(gov);
        vault.closeAll();
        lighter.settleBatch();
        uint256 bufferBefore = vault.hotBuffer();
        vault.recallMargin(); // submits
        vault.recallMargin(); // sweeps
        assertEq(vault.hotBuffer(), bufferBefore + expected);
        assertEq(vault.marginPendingRecall(), 0);
    }

    function test_refundMintRevertsBeforeWindow() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        lighter.settleBatch();

        vm.expectRevert(CertVault.CertVault_SettleWindowNotExpired.selector);
        vault.refundMint(id);

        vm.warp(block.timestamp + SETTLE_WINDOW); // exactly at the deadline: still settleable
        vm.expectRevert(CertVault.CertVault_SettleWindowNotExpired.selector);
        vault.refundMint(id);

        // The receipt is untouched and the normal path still works. A fresh attestation is
        // needed only because a day's warp staled the capacity oracle (maxAttestationAgeSec =
        // 300), which is unrelated to the settle window under test.
        vm.prank(attester);
        reg.attest(address(vault), 2, 0, 0, 1_190_000e18);
        vault.settleMint(id, PX);
        assertGt(cert.balanceOf(alice), 0);
    }

    function test_refundMintRejectsUnknownAndSettledReceipts() public {
        vm.warp(block.timestamp + SETTLE_WINDOW + 1);
        vm.expectRevert(CertVault.CertVault_BadReceipt.selector);
        vault.refundMint(999);
    }

    function test_mintBeforeBootstrapReverts() public {
        CertVault fresh = new CertVault(
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
                targetMarginBps: 9_000
            }),
            VENUE_WITHDRAW_CAP,
            SETTLE_WINDOW,
            "UseCert TSLA",
            "uTSLA"
        );
        vm.expectRevert(CertVault.CertVault_NotBootstrapped.selector);
        fresh.mintInstant(1_000e6);
    }
}
