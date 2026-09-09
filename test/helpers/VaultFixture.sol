// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CertVault} from "../../src/CertVault.sol";
import {Certificate} from "../../src/Certificate.sol";
import {CertOracle} from "../../src/CertOracle.sol";
import {SolvencyRegistry} from "../../src/SolvencyRegistry.sol";
import {CapacityOracle} from "../../src/CapacityOracle.sol";
import {BufferBook} from "../../src/BufferBook.sol";
import {MockLighter} from "../mocks/MockLighter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice Shared vault stack for CertVault tests (mint, redeem, and later rebalance/solvency).
/// @dev Extracted from Task 8's CertVaultMintTest.setUp() so every CertVault test file builds the
///      same deployment instead of duplicating it. Declared abstract + virtual so later tasks can
///      extend setUp() without copying it.
abstract contract VaultFixture is Test {
    CertVault internal vault;
    Certificate internal cert;
    CertOracle internal oracle;
    SolvencyRegistry internal reg;
    CapacityOracle internal cap;
    BufferBook internal book;
    MockLighter internal lighter;
    MockERC20 internal usdg;
    MockAggregatorV3 internal feed;

    address internal attester = makeAddr("attester");
    address internal gov = makeAddr("gov");
    address internal alice = makeAddr("alice");

    uint256 internal constant PX = 355.86e18;
    uint16 internal constant MARKET = 16; // TSLA
    uint16 internal constant ASSET_IDX = 3;
    /// @dev C1: the venue's per-asset withdrawal ceiling. Set effectively unbounded here so the
    ///      clamp never masks what a test is actually measuring; MockLighter's own
    ///      depositCapTicks is the knob tests use to model a venue refusing a request.
    uint256 internal constant VENUE_WITHDRAW_CAP = type(uint64).max;
    /// @dev C3: how long a mint receipt stays settleable before it can only be refunded.
    uint256 internal constant SETTLE_WINDOW = 1 days;
    /// @dev M4: CapacityOracle's immutable ceiling on any absoluteCap18 governance may set.
    uint256 internal constant MAX_ABSOLUTE_CAP = 1_000_000_000e18;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        usdg = new MockERC20("USDG", "USDG", 6);
        feed = new MockAggregatorV3(8, 355_86000000);
        lighter = new MockLighter(IERC20(address(usdg)), ASSET_IDX, 4);
        reg = new SolvencyRegistry(attester);
        oracle = new CertOracle(address(feed), attester, 2, 3600, 500, 100, 3600, false);
        cap = new CapacityOracle(address(reg), gov, 1000, 100, 3000, 300, MAX_ABSOLUTE_CAP);

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
                settleBandBps: 500,
                targetMarginBps: 9_000
            }),
            VENUE_WITHDRAW_CAP,
            SETTLE_WINDOW,
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

        // The venue's own mark price, used by MockLighter.settleBatch() to value margin
        // requirements. Kept in sync with the oracle price so the margin gate is live for every
        // test that fills an order, not just the margin-specific ones.
        lighter.setMarkPrice(MARKET, PX);

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

    /// @dev Moves the Chainlink feed AND keeps the Lighter mark / oracle mark price in sync with
    ///      it, mirroring what setUp() does for the initial price. pxUnguarded() (what _queueExit
    ///      prices redemptions off) reads the feed, not markPx18 — see CertOracle. Keeping the
    ///      venue's mark in sync is what makes MockLighter's mark-to-market (M3) move, which is
    ///      what makes C1 observable at all.
    /// @dev Lifted here from CertVaultMargin.t.sol (final review wave) so the recall tests can use
    ///      the same price move; behaviour is unchanged.
    function _setPrice(uint256 px18) internal {
        feed.set(int256(px18 / 1e10), block.timestamp); // feed has 8 decimals
        vm.prank(attester);
        oracle.setMarkPrice(px18);
        lighter.setMarkPrice(MARKET, px18);
    }

    /// @dev Empties the vault's ERC20 hot buffer without touching BufferBook's ledger (so mint
    ///      capacity is unaffected), the same way CertVaultMargin's
    ///      test_redeemInstantRoutesToQueuedWhenHotBufferShort does. Used by tests that must prove
    ///      a payout came from the venue rather than from the fixture's 100k seed.
    function _drainHotBuffer() internal {
        uint256 buf = vault.hotBuffer();
        if (buf == 0) return;
        vm.prank(address(vault));
        usdg.transfer(makeAddr("bufferSink"), buf);
    }
}
