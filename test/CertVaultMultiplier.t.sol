// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CertVault} from "../src/CertVault.sol";
import {Certificate} from "../src/Certificate.sol";
import {CertOracle} from "../src/CertOracle.sol";
import {SolvencyRegistry} from "../src/SolvencyRegistry.sol";
import {CapacityOracle} from "../src/CapacityOracle.sol";
import {MockLighter} from "./mocks/MockLighter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockUIMultiplierToken} from "./mocks/MockUIMultiplierToken.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice A venue that can apply a stock split to its books, or not. Lighter documents no split
///         policy, so both behaviours are tested.
contract SplitLighter is MockLighter {
    constructor(IERC20 c, uint16 a, uint8 d) MockLighter(c, a, d) {}

    /// @dev The venue RESCALES at a `ratio`:1 split: every position in `market` x ratio, its entry
    ///      price / ratio, and the mark / ratio. Notional and PnL are unchanged.
    function splitRescale(uint16 market, uint48 account, uint256 ratio) external {
        positionBaseOf[account][market] *= int256(ratio);
        entryPriceOf[account][market] /= ratio;
        markPrice[market] /= ratio;
    }
}

/// @notice Option A (total return): a certificate is a synthetic of ONE Robinhood stock token.
///         The feed prices the token, one token is `uiMultiplier()` shares (ERC-8056), the venue
///         trades shares, so the vault's hedge target is supply x M shares. Covers the owner's
///         cases (a)-(g).
contract CertVaultMultiplierTest is Test {
    CertVault internal vault;
    Certificate internal cert;
    CertOracle internal oracle;
    SolvencyRegistry internal reg;
    CapacityOracle internal cap;
    SplitLighter internal lighter;
    MockERC20 internal usdg;
    MockAggregatorV3 internal feed;
    MockUIMultiplierToken internal token;

    address internal attester = makeAddr("attester");
    address internal gov = makeAddr("gov");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal settler = makeAddr("settler");

    /// @dev One SPY token, and SPY's real multiplier on 2026-09-27.
    uint256 internal constant PX = 600e18;
    uint256 internal constant M0 = 1.001717991187472003e18;
    uint16 internal constant MARKET = 26;
    uint16 internal constant ASSET_IDX = 3;
    uint256 internal constant OI = 1_190_000e18;

    uint64 internal batch = 1;

    bytes32 internal constant HEDGE_REQUESTED = keccak256("HedgeRequested(uint256,uint256,uint8,uint256)");

    function setUp() public {
        vm.warp(1_800_000_000);
        usdg = new MockERC20("USDG", "USDG", 6);
        feed = new MockAggregatorV3(8, int256(PX / 1e10));
        token = new MockUIMultiplierToken(M0);
        lighter = new SplitLighter(IERC20(address(usdg)), ASSET_IDX, 4);
        reg = new SolvencyRegistry(attester);
        oracle = new CertOracle(address(feed), attester, 2, 3600, 500, 100, 3600, false, 3600, address(token));
        cap = new CapacityOracle(address(reg), gov, 1000, 100, 3000, 300, 1_000_000_000e18);
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
            type(uint64).max,
            1 days,
            "UseCert SPY",
            "uSPY"
        );
        cert = Certificate(vault.certificate());

        vm.prank(gov);
        cap.setAbsoluteCap(address(vault), 5_000_000e18);
        vm.prank(attester);
        reg.attest(address(vault), batch, 0, 0, OI);
        _mark(PX);

        usdg.mint(alice, 1_000_000e6);
        usdg.mint(bob, 1_000_000e6);
        usdg.mint(address(this), 1_000_000e6);
        vm.prank(alice);
        usdg.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdg.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vault.seedBuffer(100_000e6);
        vault.bootstrap();
        lighter.settleBatch();

        _applyDelayed(abi.encodeCall(CertVault.setSettler, (settler)));
    }

    // ================================================================================ helpers

    /// @dev A new feed round at `tokenPx`, and the attester's and the venue's mark at the SHARE
    ///      price, tokenPx / M at the token's live multiplier.
    function _mark(uint256 tokenPx) internal {
        uint256 spx = tokenPx * 1e18 / token.uiMultiplier();
        feed.set(int256(tokenPx / 1e10), block.timestamp);
        vm.prank(attester);
        oracle.setMarkPrice(spx);
        lighter.setMarkPrice(MARKET, spx);
    }

    function _applyDelayed(bytes memory data) internal {
        uint256 t0 = block.timestamp;
        vm.prank(gov);
        vault.proposeChange(data);
        vm.warp(t0 + vault.GOVERNANCE_DELAY());
        vm.prank(gov);
        (bool ok, bytes memory ret) = address(vault).call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        vm.warp(t0);
    }

    function _enableKeeper() internal {
        vm.prank(gov);
        vault.enableKeeperHedging();
    }

    function _acct() internal view returns (uint48) {
        return vault.lighterAccountIndex();
    }

    /// @dev What the venue holds for the vault, in venue units (share units at sizeDecimals 4).
    function _venueBase() internal view returns (int256) {
        return lighter.positionBaseOf(_acct(), MARKET);
    }

    /// @dev supply x M shares in venue units, floored: the hedge target.
    function _target() internal view returns (uint256) {
        return (cert.totalSupply() + vault.pendingMintCerts()) * token.uiMultiplier() * 1e4 / 1e36;
    }

    function _certsToBase(uint256 certs, uint256 m) internal pure returns (uint256) {
        return certs * m * 1e4 / 1e36;
    }

    /// @dev The attester's view of the venue, after the lag and the rebalance interval: venue base x
    ///      the venue's SHARE mark, i.e. what the signer attests.
    function _attestVenue() internal {
        vm.warp(block.timestamp + vault.REBALANCE_MIN_INTERVAL() + 1);
        int256 pos = _venueBase();
        uint256 abs = pos >= 0 ? uint256(pos) : uint256(-pos);
        uint256 notional18 = abs * lighter.markPrice(MARKET) / 1e4;
        vm.prank(attester);
        reg.attest(address(vault), ++batch, notional18, 0, OI);
    }

    /// @dev The keeper opening what a work order asked for, with the vault account's API key.
    function _keeperFill(uint256 base, uint256 limitPx18) internal {
        uint32 tick = oracle.toTickPrice(limitPx18);
        uint48 acct = _acct();
        vm.prank(address(vault));
        lighter.createOrder(acct, MARKET, uint48(base), tick, 0, 1);
        lighter.settleBatch();
    }

    /// @dev The single HedgeRequested in the recorded logs.
    function _workOrder(Vm.Log[] memory logs) internal view returns (uint256 rid, uint256 base, uint8 side, uint256 limitPx18) {
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] != HEDGE_REQUESTED) continue;
            require(!found, "two work orders");
            found = true;
            rid = uint256(logs[i].topics[1]);
            (base, side, limitPx18) = abi.decode(logs[i].data, (uint256, uint8, uint256));
        }
        require(found, "no work order");
    }

    function _lastOrder() internal view returns (uint48 base, uint32 price, uint8 isAsk) {
        (, base, price, isAsk,) = lighter.lastOrder();
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    // ============================================== (a) at M = 1.0017 the hedge is certs x M

    function test_a_mintOpensCertsTimesMSharesAtTheSharePrice() public {
        uint256 spx = PX * 1e18 / M0;
        vm.prank(alice);
        uint256 certs = vault.mintInstant(5_000e6);

        (uint48 base, uint32 price, uint8 isAsk) = _lastOrder();
        assertEq(isAsk, 0, "an open is a buy");
        assertEq(base, _certsToBase(certs, M0), "open base != certs x M");
        assertGt(base, certs * 1e4 / 1e18, "the old one-share-per-certificate size");
        assertEq(price, oracle.toTickPrice(spx * 10_100 / 10_000), "open limit is not the SHARE price + 1%");

        lighter.settleBatch();
        assertEq(_venueBase(), int256(uint256(base)), "venue holds the order");
        assertEq(vault.venuePositionBase(), int256(uint256(base)), "ledger");

        // Solvency is exact: attested base x share mark against supply x token price.
        _attestVenue();
        CertVault.Solvency memory s = vault.solvency();
        uint256 required = certs * PX / 1e18;
        assertLe(required - s.notional18, spx / 1e4, "under-hedged by more than one venue unit");
        assertGe(s.deltaBps, 9_999, "delta off at M = 1.0017");
        assertLe(s.deltaBps, 10_000, "delta off at M = 1.0017");
        // One share per certificate would have read ~9,983 bps: short by M - 1.
    }

    function test_a_keeperWorkOrderCarriesTheShareBaseAndTheShareLimit() public {
        _enableKeeper();
        uint256 spx = PX * 1e18 / M0;
        vm.recordLogs();
        vm.prank(alice);
        uint256 id = vault.requestMint(20_000e6);
        (uint256 rid, uint256 base, uint8 side, uint256 limitPx18) = _workOrder(vm.getRecordedLogs());
        (,,,,,, uint256 certs) = vault.mintReceipts(id);

        assertEq(rid, id, "work order names the receipt");
        assertEq(side, 0, "buy");
        assertEq(base, _certsToBase(certs, M0), "work order base != certs x M");
        assertEq(limitPx18, spx * 10_100 / 10_000, "work order limit is not the share price + 1%");
        assertEq(vault.mintMult18(id), M0, "receipt records M");

        // The keeper opens exactly that and reports its SHARE fill; the ledger books that base.
        _keeperFill(base, limitPx18);
        vm.prank(settler);
        vault.settleMint(id, spx);
        assertEq(vault.venuePositionBase(), int256(base), "ledger != the base the keeper opened");
        assertEq(_venueBase(), int256(base), "venue");
    }

    function test_a_queuedExitAndRefundCloseCertsTimesM() public {
        vm.prank(alice);
        uint256 certs = vault.mintInstant(5_000e6);
        lighter.settleBatch();

        vm.prank(alice);
        vault.forceExit(certs / 2);
        (uint48 base,, uint8 isAsk) = _lastOrder();
        assertEq(isAsk, 1, "a close is a sell");
        assertEq(base, _certsToBase(certs / 2, M0), "exit close != certIn x M");

        // Non-keeper requestMint hedges at request; a refund closes exactly that base, sized with
        // the multiplier RECORDED at request even though the token has moved since.
        vm.prank(bob);
        uint256 id = vault.requestMint(20_000e6);
        (,,,,,, uint256 indicative) = vault.mintReceipts(id);
        uint256 opened = _certsToBase(indicative, M0);
        (uint48 openBase,,) = _lastOrder();
        assertEq(openBase, opened, "requestMint open");
        lighter.settleBatch();
        token.setMultiplier(1.004e18); // a later, unstaged change
        vm.warp(block.timestamp + 1 days + 1);
        vault.stageRefund(id);
        (uint48 closeBase,, uint8 closeSide) = _lastOrder();
        assertEq(closeSide, 1, "refund close is a sell");
        assertEq(closeBase, opened, "refund did not close what was opened");
    }

    // ==================================== (b) a 10:1 split that the venue RESCALES: no action

    function test_b_splitWithVenueRescale_holdersContinuous_newOrdersTenTimes() public {
        vm.prank(alice);
        uint256 c1 = vault.mintInstant(8_000e6);
        lighter.settleBatch();
        int256 b1 = _venueBase();
        assertEq(uint256(b1), _certsToBase(c1, M0));

        uint256 eff = block.timestamp + 2 hours;
        token.stage(M0 * 10, eff);
        assertTrue(oracle.mintAllowed(), "open until the pre-window");
        vm.warp(eff - 30 minutes);
        _mark(PX);
        assertFalse(oracle.mintAllowed(), "mint must close ahead of the split");
        assertTrue(oracle.corporateActionWindow());

        // The split. Token price continuous; share price / 10; the venue rescales its books.
        vm.warp(eff);
        lighter.splitRescale(MARKET, _acct(), 10);
        assertEq(oracle.multiplier18(), M0 * 10);
        assertEq(_venueBase(), b1 * 10, "venue rescaled");
        (uint256 pxNow,) = oracle.pxUnguarded();
        assertEq(pxNow, PX, "holders' price is the token's: continuous");
        assertFalse(oracle.mintAllowed(), "mint closed at effectiveAt (feed not yet re-published)");

        // Solvency is unchanged: 10x the shares at a tenth of the price. No action needed.
        _attestVenue();
        CertVault.Solvency memory s = vault.solvency();
        assertGe(s.deltaBps, 9_999, "delta moved at a rescaled split");
        assertLe(s.deltaBps, 10_000, "delta moved at a rescaled split");
        vm.expectRevert(CertVault.CertVault_InBand.selector);
        vault.rebalance();

        // After the window and a fresh feed round, minting reopens and every order is 10x.
        vm.warp(eff + oracle.MULTIPLIER_POST_WINDOW() + 1);
        _mark(PX);
        assertTrue(oracle.mintAllowed(), "mint must reopen after the window");
        _attestVenue(); // capacity needs an attestation younger than 300 s
        _splitNewMintAndCloseAreTenTimes(c1);
        // The venue rescaled a position that was floored to a unit under the old M, so the drift
        // is up to one unit per pre-split order times the ratio (here 10), plus one per order
        // since: a few cents, inside the band.
        assertLe(_abs(_venueBase() - int256(_target())), 12, "venue != supply x M");
        // RESIDUAL, pinned so it cannot be forgotten: the vault's own ledger (venuePositionBase,
        // read by closeAll for its side and by retire) cannot see a rescale done on the venue's
        // books, so after one it understates the position by the split ratio. The hedge and
        // solvency above are right; the ledger is re-zeroed by closeAll.
        assertLt(vault.venuePositionBase(), _venueBase(), "ledger followed a venue-side rescale?");
    }

    function _splitNewMintAndCloseAreTenTimes(uint256 c1) internal {
        {
            vm.prank(bob);
            uint256 c2 = vault.mintInstant(8_000e6);
            (uint48 open2,, uint8 side2) = _lastOrder();
            assertEq(side2, 0);
            assertEq(open2, _certsToBase(c2, M0 * 10), "new mint is not certs x 10M");
            lighter.settleBatch();
        }
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.redeemInstant(c1 / 2);
        (uint48 close1,, uint8 side3) = _lastOrder();
        assertEq(side3, 1);
        assertEq(close1, _certsToBase(c1 / 2, M0 * 10), "close is not certIn x 10M");
        assertEq(usdg.balanceOf(alice) - before, out);
        // Paid at the (continuous) token price, less the 0.1% fee.
        assertApproxEqRel(out * 1e12, (c1 / 2) * PX / 1e18, 0.0011e18, "holder value not continuous");
        lighter.settleBatch();
    }

    // ============================ (c) a 10:1 split the venue does NOT rescale: rehedge fixes it

    function test_c_splitWithoutRescale_detected_mintPaused_rehedged_exitsOpenThroughout() public {
        _enableKeeper();
        uint256 spx0 = PX * 1e18 / M0;
        vm.recordLogs();
        vm.prank(alice);
        uint256 id = vault.requestMint(20_000e6);
        (, uint256 base0,, uint256 lim0) = _workOrder(vm.getRecordedLogs());
        _keeperFill(base0, lim0);
        vm.prank(settler);
        vault.settleMint(id, spx0);
        uint256 certs = cert.balanceOf(alice);

        uint256 eff = block.timestamp + 2 hours;
        token.stage(M0 * 10, eff);
        vm.warp(eff);
        // The share trades at a tenth; the venue leaves the position as it was. The long loses
        // 90% of its value (margin is disabled here so the venue does not refuse the rehedge; on a
        // real venue this is a margin loss that the insurance pool has to cover).
        lighter.setMarkPrice(MARKET, spx0 / 10);
        lighter.setRequiredMarginBps(0);
        assertFalse(oracle.mintAllowed(), "mint must be closed at the split");

        // Law 2: exits are open in the window.
        vm.prank(alice);
        uint256 rid = vault.forceExit(certs / 20);
        (address u,,,,) = vault.redeemReceipts(rid);
        assertEq(u, alice, "forceExit refused in the window");
        lighter.settleBatch();

        // The attestation shows the under-hedge: a tenth of the notional supply requires.
        _attestVenue();
        CertVault.Solvency memory s = vault.solvency();
        assertLt(s.deltaBps, 2_000, "under-hedge not visible");
        // The permissionless path cannot open in keeper mode.
        vm.expectRevert(CertVault.CertVault_OpenRequiresKeeper.selector);
        vault.rebalance();
        vm.expectRevert(CertVault.CertVault_OnlySettler.selector);
        vm.prank(alice);
        vault.rehedge(type(uint256).max);

        // The settler rehedges, one bounded step per fresh attestation, until on target.
        for (uint256 k = 0; k < 6; ++k) {
            vm.recordLogs();
            vm.prank(settler);
            try vault.rehedge(type(uint256).max) {}
            catch (bytes memory err) {
                assertEq(bytes4(err), CertVault.CertVault_InBand.selector, "rehedge failed");
                break;
            }
            (uint256 wrid, uint256 wb, uint8 ws, uint256 wl) = _workOrder(vm.getRecordedLogs());
            assertEq(wrid, 0, "a rehedge names no receipt");
            assertEq(ws, 0, "a rehedge in deficit is a buy");
            assertEq(wl, (PX * 1e18 / (M0 * 10)) * 10_100 / 10_000, "rehedge limit is not the new share price");
            _keeperFill(wb, wl);
            _attestVenue();
            // Law 2 throughout: a holder can still exit instantly between steps.
            if (k == 0) {
                // Instant redemption needs a feed round under an hour old (stack 5); the token
                // price is continuous, so the feed simply re-publishes it.
                feed.set(int256(PX / 1e10), block.timestamp);
                vm.prank(alice);
                vault.redeemInstant(certs / 50);
                lighter.settleBatch();
                _attestVenue();
            }
        }
        assertLe(_abs(_venueBase() - int256(_target())), 1, "rehedge did not restore supply x M");
        assertEq(vault.venuePositionBase(), _venueBase(), "ledger != venue after the rehedge");
        s = vault.solvency();
        assertGe(s.deltaBps, 9_999);

        // Minting reopens after the window, on a fresh feed round and a new share mark.
        vm.warp(block.timestamp + 1 hours);
        _mark(PX);
        assertTrue(oracle.mintAllowed());
    }

    function test_c_afterASplitSettleBandsTheShareFillNotTheTokenPrice() public {
        _enableKeeper();
        uint256 eff = block.timestamp + 2 hours;
        token.stage(M0 * 10, eff);
        vm.warp(eff + 2 hours);
        _mark(PX);
        assertTrue(oracle.mintAllowed());
        _attestVenue(); // capacity needs an attestation younger than 300 s
        uint256 spx = PX * 1e18 / (M0 * 10);

        vm.recordLogs();
        vm.prank(alice);
        uint256 id = vault.requestMint(20_000e6);
        (, uint256 base,, uint256 lim) = _workOrder(vm.getRecordedLogs());
        (,,,,,, uint256 certs) = vault.mintReceipts(id);
        assertEq(base, _certsToBase(certs, M0 * 10), "x10 base");
        assertEq(lim, spx * 10_100 / 10_000, "x0.1 limit");

        vm.startPrank(settler);
        vm.expectRevert(CertVault.CertVault_FillPriceOutOfBand.selector);
        vault.settleMint(id, PX); // the token price is ten times the share fill
        vault.settleMint(id, spx);
        vm.stopPrank();
    }

    // ======================================= (d) a dividend step: visible cost, rehedge tops up

    function test_d_dividendStep_solvencyShowsTheCost_rehedgeTopsUp() public {
        token.setMultiplier(1e18);
        _mark(PX);
        vm.prank(alice);
        uint256 id = vault.requestMint(40_000e6); // non-keeper: hedged on chain at request
        lighter.settleBatch();
        vault.settleMint(id, PX);
        _attestVenue();
        uint256 deltaBefore = vault.solvency().deltaBps;
        assertGe(deltaBefore, 9_999);

        // Dividend reinvested: M 1.000 -> 1.008. The token is worth 0.8% more; the share is not.
        uint256 eff = block.timestamp + 2 hours;
        token.stage(1.008e18, eff);
        vm.warp(eff + 2 hours);
        _mark(PX * 1008 / 1000);

        _attestVenue();
        CertVault.Solvency memory s = vault.solvency();
        // The holder's certificates are worth 0.8% more; the perp paid nothing. That is the
        // dividend the protocol bears, and it shows as an under-hedge of ~80 bps.
        assertGe(s.deltaBps, 9_918, "dividend cost");
        assertLe(s.deltaBps, 9_922, "dividend cost");
        // Inside the 1% band, so the permissionless rebalance does nothing ...
        vm.expectRevert(CertVault.CertVault_InBand.selector);
        vault.rebalance();
        // ... and the settler tops up (non-keeper vault: the order goes on chain).
        vm.prank(settler);
        vault.rehedge(type(uint256).max);
        (uint48 b,, uint8 side) = _lastOrder();
        assertEq(side, 0, "top-up is a buy");
        assertApproxEqRel(uint256(b), uint256(_venueBase()) * 8 / 1000, 0.01e18, "top-up is not ~0.8%");
        lighter.settleBatch();
        assertLe(_abs(_venueBase() - int256(_target())), 1, "not on supply x 1.008");
        _attestVenue();
        assertGe(vault.solvency().deltaBps, 9_999, "still under-hedged after the top-up");
    }

    function test_d_rehedgeHonoursItsCapAndTheRebalanceGates() public {
        token.setMultiplier(1e18);
        _mark(PX);
        vm.prank(alice);
        vault.requestMint(40_000e6);
        lighter.settleBatch();
        token.setMultiplier(1.008e18);
        _mark(PX * 1008 / 1000);

        // Not after an order without a fresh attestation.
        vm.prank(settler);
        vm.expectRevert(CertVault.CertVault_AttestationPredatesLastOrder.selector);
        vault.rehedge(type(uint256).max);

        _attestVenue();
        vm.prank(settler);
        vault.rehedge(3);
        (uint48 b,,) = _lastOrder();
        assertEq(b, 3, "maxBase not honoured");
        // One per attested batch.
        vm.prank(settler);
        vm.expectRevert(CertVault.CertVault_AlreadyRebalancedThisBatch.selector);
        vault.rehedge(type(uint256).max);
    }

    // ============================= (e) oraclePaused and the staged window close MINTING only

    function test_e_oraclePausedClosesMintOnly() public {
        vm.prank(alice);
        uint256 certs = vault.mintInstant(8_000e6);
        lighter.settleBatch();
        assertTrue(oracle.mintAllowed());

        token.setOraclePaused(true);
        assertFalse(oracle.mintAllowed(), "oraclePaused must close minting");
        vm.expectRevert(CertVault.CertVault_MintPaused.selector);
        vm.prank(bob);
        vault.mintInstant(1_000e6);
        vm.expectRevert(CertVault.CertVault_MintPaused.selector);
        vm.prank(bob);
        vault.requestMint(20_000e6);
        vm.prank(alice);
        vault.redeemInstant(certs / 4);
        vm.prank(alice);
        vault.forceExit(certs / 4);

        token.setOraclePaused(false);
        assertTrue(oracle.mintAllowed());
    }

    function test_e_stagedWindowClosesMintOnly_fromPreUntilTheFeedRepublishes() public {
        vm.prank(alice);
        uint256 certs = vault.mintInstant(8_000e6);
        lighter.settleBatch();

        uint256 eff = block.timestamp + 3 hours;
        token.stage(1.01e18, eff);
        vm.warp(eff - oracle.MULTIPLIER_PRE_WINDOW() - 1);
        _mark(PX);
        assertTrue(oracle.mintAllowed(), "closed too early");
        vm.warp(eff - oracle.MULTIPLIER_PRE_WINDOW());
        assertFalse(oracle.mintAllowed(), "pre-window open");
        vm.prank(alice);
        vault.redeemInstant(certs / 4);

        vm.warp(eff + oracle.MULTIPLIER_POST_WINDOW() + 1);
        vm.prank(attester);
        oracle.setMarkPrice(PX * 1e18 / 1.01e18);
        // POST has passed, but the feed's latest round predates effectiveAt.
        assertFalse(oracle.mintAllowed(), "open before the feed re-published");
        vm.prank(alice);
        vault.forceExit(certs / 4);
        _mark(PX);
        assertTrue(oracle.mintAllowed(), "not reopened");
    }

    function test_e_brokenOrAbsurdTokenFailsClosedForMintAndFallsBackForExits() public {
        vm.prank(alice);
        uint256 certs = vault.mintInstant(8_000e6);
        lighter.settleBatch();

        token.setBroken(true);
        assertFalse(oracle.mintAllowed(), "an unreadable token must close minting");
        assertEq(oracle.multiplier18(), M0, "fallback is the multiplier seen with the last mark");
        vm.prank(alice);
        vault.forceExit(certs / 4);
        (uint48 base,,) = _lastOrder();
        assertEq(base, _certsToBase(certs / 4, M0), "exit close not sized with the fallback");
        vm.prank(alice);
        vault.redeemInstant(certs / 4);
        token.setBroken(false);

        token.setMultiplier(1e22); // outside the bounds
        assertFalse(oracle.mintAllowed());
        assertEq(oracle.multiplier18(), M0);
        vm.prank(alice);
        vault.forceExit(certs / 8);

        // An unstaged change inside the bounds: minting needs a mark taken under it.
        token.setMultiplier(M0 * 2);
        assertFalse(oracle.mintAllowed(), "a mark from before a 2:1 change still opens minting");
        _mark(PX);
        assertEq(oracle.markMult18(), M0 * 2);
        assertTrue(oracle.mintAllowed());
    }

    function test_e_constructorRefusesABadToken() public {
        MockUIMultiplierToken absurd = new MockUIMultiplierToken(1e22);
        vm.expectRevert(CertOracle.CertOracle_MultiplierOutOfRange.selector);
        new CertOracle(address(feed), attester, 2, 3600, 500, 100, 3600, false, 3600, address(absurd));

        MockUIMultiplierToken dead = new MockUIMultiplierToken(1e18);
        dead.setBroken(true);
        vm.expectRevert(CertOracle.CertOracle_MultiplierOutOfRange.selector);
        new CertOracle(address(feed), attester, 2, 3600, 500, 100, 3600, false, 3600, address(dead));

        vm.expectRevert(CertOracle.CertOracle_MultiplierOutOfRange.selector);
        new CertOracle(address(feed), attester, 2, 3600, 500, 100, 3600, false, 3600, makeAddr("eoa"));

        vm.chainId(4663);
        vm.expectRevert(CertOracle.CertOracle_StockTokenRequired.selector);
        new CertOracle(address(feed), attester, 2, 3600, 500, 100, 3600, false, 3600, address(0));
        CertOracle ok = new CertOracle(address(feed), attester, 2, 3600, 500, 100, 3600, false, 3600, address(token));
        assertEq(ok.stockToken(), address(token));
        assertEq(ok.multiplier18(), M0);
    }

    // ============================================== (f) the basis guard compares mark x M

    function test_f_basisGuardScalesTheMarkByM() public {
        // A 10 bps band: tighter than SPY's 17 bps multiplier, so an unscaled comparison of the
        // share mark with the token feed would fail here.
        CertOracle tight = new CertOracle(address(feed), attester, 2, 3600, 500, 10, 3600, false, 3600, address(token));
        uint256 spx = PX * 1e18 / M0;
        vm.prank(attester);
        tight.setMarkPrice(spx);
        assertTrue(tight.mintAllowed(), "a normal multiplier trips the basis band");
        (bool known, uint256 bps) = tight.basisBpsChecked();
        assertTrue(known);
        assertEq(bps, 0, "basis of the share mark x M");
        assertGt((PX - spx) * 10_000 / PX, 10, "precondition: unscaled, the basis would exceed the band");

        // A genuine gap: the perp 0.5% below the token-implied share price.
        vm.prank(attester);
        tight.setMarkPrice(spx * 995 / 1000);
        assertFalse(tight.mintAllowed(), "a real price gap passed");
        (, bps) = tight.basisBpsChecked();
        assertGe(bps, 49);

        // And the vault's own oracle (100 bps band) at a 2% gap.
        vm.prank(attester);
        oracle.setMarkPrice(spx * 98 / 100);
        assertFalse(oracle.mintAllowed());
    }

    // ========================= (g) fuzz: venue base == floor(supply x M) within one unit

    function testFuzz_g_venueTracksSupplyTimesM(uint256 m, uint256 seed) public {
        m = bound(m, oracle.MIN_MULTIPLIER_18(), oracle.MAX_MULTIPLIER_18());
        token.setMultiplier(m);
        _mark(PX);
        assertTrue(oracle.mintAllowed());

        uint256 ops = 3 + seed % 6;
        for (uint256 k = 0; k < ops; ++k) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            address who = r % 2 == 0 ? alice : bob;
            uint256 bal = cert.balanceOf(who);
            if (bal == 0 || r % 3 != 0) {
                uint256 amt = 1_000e6 + (r >> 8) % 8_000e6;
                vm.prank(who);
                vault.mintInstant(amt);
            } else {
                uint256 certIn = bal * (1 + (r >> 16) % 99) / 100;
                if (certIn * m / 1e18 * 1e4 / 1e18 == 0) continue; // below one venue unit
                vm.prank(who);
                vault.redeemInstant(certIn);
            }
            lighter.settleBatch();
        }
        // Each order floors to a venue unit (round in, floor out), so the venue drifts from the
        // target by at most one unit per order; the settler's rehedge closes the drift.
        _attestVenue();
        vm.prank(settler);
        try vault.rehedge(type(uint256).max) {
            lighter.settleBatch();
        } catch (bytes memory err) {
            assertEq(bytes4(err), CertVault.CertVault_InBand.selector, "rehedge failed");
        }
        assertLe(_abs(_venueBase() - int256(_target())), 1, "venue base != floor(supply x M) +- 1");
        assertEq(vault.venuePositionBase(), _venueBase(), "ledger != venue");
    }
}
