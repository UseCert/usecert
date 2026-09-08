// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CertVault} from "../src/CertVault.sol";
import {Certificate} from "../src/Certificate.sol";
import {CertOracle} from "../src/CertOracle.sol";
import {SolvencyRegistry} from "../src/SolvencyRegistry.sol";
import {CapacityOracle} from "../src/CapacityOracle.sol";
import {BufferBook} from "../src/BufferBook.sol";
import {MockLighter} from "./mocks/MockLighter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

contract CertVaultMintTest is Test {
    CertVault vault;
    Certificate cert;
    CertOracle oracle;
    SolvencyRegistry reg;
    CapacityOracle cap;
    BufferBook book;
    MockLighter lighter;
    MockERC20 usdg;
    MockAggregatorV3 feed;

    address attester = makeAddr("attester");
    address gov = makeAddr("gov");
    address alice = makeAddr("alice");

    uint256 constant PX = 355.86e18;
    uint16 constant MARKET = 16; // TSLA
    uint16 constant ASSET_IDX = 3;

    function setUp() public {
        vm.warp(1_800_000_000);
        usdg = new MockERC20("USDG", "USDG", 6);
        feed = new MockAggregatorV3(8, 355_86000000);
        lighter = new MockLighter(IERC20(address(usdg)), ASSET_IDX);
        reg = new SolvencyRegistry(attester);
        oracle = new CertOracle(address(feed), attester, 2, 3600, 500, 100);
        cap = new CapacityOracle(address(reg), gov, 1000, 100, 3000, 300);

        vault = new CertVault(
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
                settleBandBps: 500
            }),
            "UseCert TSLA",
            "uTSLA"
        );
        cert = Certificate(vault.certificate());
        book = BufferBook(vault.buffer());

        vm.prank(gov);
        cap.setAbsoluteCap(address(vault), 5_000_000e18);
        vm.startPrank(attester);
        oracle.setMarkPrice(PX);
        reg.attest(address(vault), 1, 0, 0, 1_190_000e18);
        vm.stopPrank();

        usdg.mint(alice, 1_000_000e6);
        usdg.mint(address(this), 1_000_000e6);
        vm.prank(alice);
        usdg.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);

        // seed the buffer so capacity is not buffer-bound
        vault.seedBuffer(100_000e6);
        vault.bootstrap();
        lighter.settleBatch();
    }

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
                settleBandBps: 500
            }),
            "UseCert TSLA",
            "uTSLA"
        );
        vm.expectRevert(CertVault.CertVault_NotBootstrapped.selector);
        fresh.mintInstant(1_000e6);
    }
}
