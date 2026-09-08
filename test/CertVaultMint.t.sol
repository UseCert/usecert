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
            "UseCert TSLA",
            "uTSLA"
        );
        vm.expectRevert(CertVault.CertVault_NotBootstrapped.selector);
        fresh.mintInstant(1_000e6);
    }
}
