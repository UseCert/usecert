// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CertOracle} from "../src/CertOracle.sol";
import {CertMorphoOracle} from "../src/periphery/CertMorphoOracle.sol";
import {MarketParams, MarketParamsLib, Id} from "../src/periphery/interfaces/IMorphoBlue.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockUIMultiplierToken} from "./mocks/MockUIMultiplierToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMorphoBlue} from "./mocks/MockMorphoBlue.sol";
import {MockCertOracleForMorpho} from "./mocks/MockCertOracleForMorpho.sol";

/// @notice CertMorphoOracle against the REAL CertOracle (mock feed and stock token), plus a
///         misbehaving CertOracle mock for the cases the real one never produces, plus Morpho
///         Blue's solvency math (MockMorphoBlue) for the liquidation sanity checks. Fork-free.
contract CertMorphoOracleTest is Test {
    // Friday 25 Sept 2026 19:02:24 UTC: RHTSLA's last round before the weekend, on chain 4663.
    uint256 internal constant T0 = 1_790_362_944;
    uint256 internal constant STALENESS = 93_600; // CertOracle.stalenessSeconds on 4663
    int256 internal constant TSLA_8DP = 371_77000000; // $371.77, 8 decimals like the live feed
    uint256 internal constant TSLA_18 = 371.77e18;

    /// @dev The largest move across any of the 78 measured closures (QQQ, 24-27 July 2026). With
    ///      78 samples the sample p99 is the maximum.
    uint256 internal constant WEEKEND_P99_BPS = 177;

    MockAggregatorV3 internal feed;
    MockUIMultiplierToken internal stock;
    CertOracle internal certOracle;
    MockERC20 internal cert;
    MockERC20 internal usdg;
    CertMorphoOracle internal adapter;

    function setUp() public {
        vm.warp(T0);
        feed = new MockAggregatorV3(8, TSLA_8DP);
        stock = new MockUIMultiplierToken(1e18);
        certOracle = new CertOracle(
            address(feed), makeAddr("attester"), 2, STALENESS, 500, 100, 3600, false, 300, address(stock)
        );
        cert = new MockERC20("UseCert TSLA", "uTSLA", 18);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        adapter = new CertMorphoOracle(address(certOracle), address(cert), address(usdg), _defaults());
    }

    function _defaults() internal pure returns (CertMorphoOracle.Haircuts memory) {
        return CertMorphoOracle.Haircuts({
            step1Age: 26 hours,
            step1Bps: 300,
            step2Age: 66 hours,
            step2Bps: 600,
            step3Age: 96 hours,
            step3Bps: 1_500,
            corporateActionBps: 500
        });
    }

    function _cut(uint256 p18, uint256 bps) internal pure returns (uint256) {
        return p18 * 1e6 * (10_000 - bps) / 10_000;
    }

    // ------------------------------------------------------------------------------ scaling

    function test_scaling_exact_18dec_collateral_6dec_loan() public view {
        assertEq(adapter.SCALE(), 1e6);
        assertEq(adapter.price(), 371.77e24, "px18 x 1e6");
        // Morpho's reading: `collateral * price / 1e36` is loan-token units.
        // 1 certificate (1e18) -> 371.77 USDG = 371_770_000 units.
        assertEq(uint256(1e18) * adapter.price() / 1e36, 371_770_000);
        // 2.5 certificates -> 929.425 USDG.
        assertEq(uint256(2.5e18) * adapter.price() / 1e36, 929_425_000);
    }

    function test_scaling_matches_live_4663_stock_oracle() public {
        // The live RH-stock/USDG Morpho oracles on 4663 answered 371769406164369862191731503 for
        // RHTSLA at 371.76940616... (read-only cast call, 2026-09-27): px18 x 1e6, same scale.
        feed.set(37176940616, block.timestamp);
        assertEq(adapter.price(), 371769406160000000000000000);
        // Same scale: they differ only below the 8-decimal feed's last digit ($1e-8 = 1e16 here).
        assertApproxEqAbs(adapter.price(), 371769406164369862191731503, 1e16);
    }

    function testFuzz_scaling_fresh_is_px18_times_1e6(uint256 answer) public {
        answer = bound(answer, 1, 1e20); // up to $1e12 per certificate at 8 decimals
        feed.set(int256(answer), block.timestamp);
        assertEq(adapter.price(), answer * 1e10 * 1e6);
    }

    function test_scaling_other_decimals() public {
        MockERC20 c8 = new MockERC20("c8", "c8", 8);
        MockERC20 l18 = new MockERC20("l18", "l18", 18);
        CertMorphoOracle a = new CertMorphoOracle(address(certOracle), address(c8), address(l18), _defaults());
        // 36 + 18 - 8 = 46 decimals of price, px18 carries 18 -> x 1e28.
        assertEq(a.SCALE(), 1e28);
        assertEq(uint256(1e8) * a.price() / 1e36, 371.77e18, "1 whole 8-dec token = 371.77 of an 18-dec loan token");

        MockERC20 c60 = new MockERC20("c60", "c60", 60);
        vm.expectRevert(CertMorphoOracle.CertMorphoOracle_DecimalsOutOfRange.selector);
        this.deployAdapter(address(certOracle), address(c60), address(usdg), _defaults());
        assertEq(a.SCALE(), 1e28, "reached");
    }

    // ------------------------------------------------------------------ fresh / stale steps

    function test_fresh_no_haircut_up_to_staleness_boundary() public {
        vm.warp(T0 + STALENESS); // px() still accepts: its test is `age > stalenessSeconds`
        (uint256 p, uint256 h, uint256 age, CertMorphoOracle.Source src) = adapter.quote();
        assertEq(uint256(src), uint256(CertMorphoOracle.Source.Fresh));
        assertEq(p, TSLA_18);
        assertEq(h, 0);
        assertEq(age, 0);
        assertEq(adapter.price(), _cut(TSLA_18, 0));
    }

    function test_stale_steps() public {
        uint256[9] memory ages = [
            STALENESS + 1,
            uint256(48 hours), // a short two-day weekend
            61 hours, // the longest two-day weekend measured (60.6 h), rounded up
            66 hours, // step 2 boundary, inclusive of step 1
            66 hours + 1,
            91.5 hours, // the longest closure measured (QQQ, Labor Day)
            96 hours,
            96 hours + 1,
            30 days
        ];
        uint256[9] memory want = [uint256(300), 300, 300, 300, 600, 600, 600, 1_500, 1_500];
        for (uint256 i; i < ages.length; ++i) {
            vm.warp(T0 + ages[i]);
            vm.expectRevert(CertOracle.CertOracle_StalePrice.selector);
            certOracle.px();
            (uint256 p, uint256 h, uint256 age, CertMorphoOracle.Source src) = adapter.quote();
            assertEq(uint256(src), uint256(CertMorphoOracle.Source.StaleFeed));
            assertEq(p, TSLA_18, "the last print");
            assertEq(age, ages[i]);
            assertEq(h, want[i]);
            assertEq(adapter.price(), _cut(TSLA_18, want[i]));
        }
    }

    function test_continuous_across_fresh_stale_boundary_except_haircut() public {
        vm.warp(T0 + STALENESS);
        uint256 fresh = adapter.price();
        vm.warp(T0 + STALENESS + 1);
        assertEq(adapter.price(), fresh * 9_700 / 10_000);
    }

    function testFuzz_never_reverts_and_monotone_in_age(uint256 a1, uint256 a2) public {
        a1 = bound(a1, 0, 3650 days);
        a2 = bound(a2, a1, 3650 days);
        vm.warp(T0 + a1);
        uint256 p1 = adapter.price();
        vm.warp(T0 + a2);
        uint256 p2 = adapter.price();
        assertLe(p2, p1, "an older print is never worth more");
        assertGe(p2, _cut(TSLA_18, 1_500), "capped at step 3");
    }

    function test_stale_uses_feed_last_print_not_breaker_reference() public {
        // A 19% drop, wider than deviationBps: nobody pokes, so lastGoodPx18 stays at 371.77.
        feed.set(301_13370000, T0 + 1 hours);
        vm.warp(T0 + 1 hours + STALENESS + 1);
        (uint256 lg,) = certOracle.pxUnguarded();
        assertEq(lg, TSLA_18, "pxUnguarded falls back to the breaker's reference");
        (uint256 p,,,) = adapter.quote();
        assertEq(p, 301.1337e18, "the adapter prices the feed's last round");
        assertEq(adapter.price(), _cut(301.1337e18, 300));
    }

    // ------------------------------------------------------------------ never reverts when stale

    function test_feed_reverting_falls_back_to_lastGood_with_at_least_step1() public {
        feed.setShouldRevert(true);
        (uint256 p, uint256 h,, CertMorphoOracle.Source src) = adapter.quote();
        assertEq(uint256(src), uint256(CertMorphoOracle.Source.Fallback));
        assertEq(p, TSLA_18);
        // CertOracle cannot read the token's feed-dependent window either; the token is fine, so
        // only the step-1 floor applies (lastGoodAt is T0, age 0).
        assertEq(h, 300);
        vm.warp(T0 + 97 hours);
        assertEq(adapter.price(), _cut(TSLA_18, 1_500), "aged by lastGoodAt");
    }

    function test_nonpositive_answer_future_timestamp_absurd_decimals_all_answer() public {
        feed.set(0, T0);
        assertEq(adapter.price(), _cut(TSLA_18, 300));
        feed.set(-1, T0);
        assertEq(adapter.price(), _cut(TSLA_18, 300));
        feed.set(TSLA_8DP, T0 + 1 days); // a round from the future
        (,,, CertMorphoOracle.Source src) = adapter.quote();
        assertEq(uint256(src), uint256(CertMorphoOracle.Source.Fallback));
        assertEq(adapter.price(), _cut(TSLA_18, 300));
        feed.set(TSLA_8DP, T0);
        feed.setDecimals(40);
        assertEq(adapter.price(), _cut(TSLA_18, 300));
    }

    function test_mock_px_zero_is_not_fresh() public {
        MockCertOracleForMorpho m = new MockCertOracleForMorpho(address(feed), STALENESS);
        CertMorphoOracle a = new CertMorphoOracle(address(m), address(cert), address(usdg), _defaults());
        m.setPx(0, false); // CertOracle can return 0 when a high-decimals feed truncates
        (,,, CertMorphoOracle.Source src) = a.quote();
        assertEq(uint256(src), uint256(CertMorphoOracle.Source.StaleFeed));
        assertEq(a.price(), _cut(TSLA_18, 300));
    }

    function test_mock_everything_broken_reverts_rather_than_price_zero() public {
        MockCertOracleForMorpho m = new MockCertOracleForMorpho(address(feed), STALENESS);
        CertMorphoOracle a = new CertMorphoOracle(address(m), address(cert), address(usdg), _defaults());
        m.setPx(0, true);
        feed.setShouldRevert(true);
        m.setUnguarded(0, 0, true);
        vm.expectRevert(CertMorphoOracle.CertMorphoOracle_NoPrice.selector);
        a.price();
        m.setUnguarded(0, block.timestamp, false); // a zero last-good is no price either
        vm.expectRevert(CertMorphoOracle.CertMorphoOracle_NoPrice.selector);
        a.price();
        m.setUnguarded(TSLA_18, 0, false); // a price with no timestamp: the oldest possible
        assertEq(a.price(), _cut(TSLA_18, 1_500));
        m.setUnguarded(TSLA_18, block.timestamp + 1, false); // from the future: same
        assertEq(a.price(), _cut(TSLA_18, 1_500));
    }

    // ------------------------------------------------------------------------ corporate action

    function test_corporate_action_haircut_fresh() public {
        stock.stage(2e18, block.timestamp + 30 minutes); // a 2:1 split staged 30 min out
        assertTrue(certOracle.corporateActionWindow());
        (uint256 p, uint256 h,, CertMorphoOracle.Source src) = adapter.quote();
        assertEq(uint256(src), uint256(CertMorphoOracle.Source.Fresh));
        assertEq(p, TSLA_18);
        assertEq(h, 500);
        assertEq(adapter.price(), _cut(TSLA_18, 500));
    }

    function test_corporate_action_window_closes_after_post_window_and_republish() public {
        stock.stage(2e18, block.timestamp + 30 minutes);
        vm.warp(block.timestamp + 30 minutes + 2 hours);
        assertTrue(certOracle.corporateActionWindow(), "the feed has not re-published since");
        assertEq(adapter.price(), _cut(TSLA_18, 500));
        feed.set(TSLA_8DP, block.timestamp);
        assertFalse(certOracle.corporateActionWindow());
        assertEq(adapter.price(), _cut(TSLA_18, 0));
    }

    function test_corporate_action_compounds_with_staleness() public {
        stock.setOraclePaused(true);
        vm.warp(T0 + STALENESS + 1);
        (, uint256 h,,) = adapter.quote();
        assertEq(h, 785, "1 - 0.97 x 0.95");
        assertEq(adapter.price(), _cut(TSLA_18, 785));
    }

    function test_broken_stock_token_counts_as_corporate_action() public {
        stock.setBroken(true);
        assertEq(adapter.price(), _cut(TSLA_18, 500));
    }

    function test_mock_window_reverting_counts_as_corporate_action() public {
        MockCertOracleForMorpho m = new MockCertOracleForMorpho(address(feed), STALENESS);
        CertMorphoOracle a = new CertMorphoOracle(address(m), address(cert), address(usdg), _defaults());
        m.setPx(TSLA_18, false);
        m.setWindow(false, true);
        assertEq(a.price(), _cut(TSLA_18, 500));
        m.setWindow(false, false);
        assertEq(a.price(), _cut(TSLA_18, 0));
    }

    // ------------------------------------------------------------------------- constructor bounds

    /// @dev External, so each `vm.expectRevert` below wraps exactly one call and the test goes on
    ///      after it (a bare `new` under expectRevert ended the test at the first match).
    function deployAdapter(address o, address c, address l, CertMorphoOracle.Haircuts memory h)
        external
        returns (CertMorphoOracle)
    {
        return new CertMorphoOracle(o, c, l, h);
    }

    function test_constructor_bounds() public {
        CertMorphoOracle.Haircuts memory h = _defaults();
        uint256 checked;

        vm.expectRevert(CertMorphoOracle.CertMorphoOracle_ZeroAddress.selector);
        this.deployAdapter(address(0), address(cert), address(usdg), h);
        vm.expectRevert(CertMorphoOracle.CertMorphoOracle_ZeroAddress.selector);
        this.deployAdapter(address(certOracle), address(0), address(usdg), h);
        vm.expectRevert(CertMorphoOracle.CertMorphoOracle_ZeroAddress.selector);
        this.deployAdapter(address(certOracle), address(cert), address(0), h);
        MockCertOracleForMorpho noFeed = new MockCertOracleForMorpho(address(0), STALENESS);
        vm.expectRevert(CertMorphoOracle.CertMorphoOracle_ZeroAddress.selector);
        this.deployAdapter(address(noFeed), address(cert), address(usdg), h);

        h = _defaults();
        h.step1Age = STALENESS - 1; // would cut a price px() still accepts
        checked += _expectBadSchedule(h);
        h = _defaults();
        h.step2Age = h.step1Age;
        checked += _expectBadSchedule(h);
        h = _defaults();
        h.step3Age = h.step2Age;
        checked += _expectBadSchedule(h);
        h = _defaults();
        h.step3Age = 30 days + 1;
        checked += _expectBadSchedule(h);
        h = _defaults();
        h.step1Bps = 0;
        checked += _expectBadSchedule(h);
        h = _defaults();
        h.step2Bps = h.step1Bps - 1;
        checked += _expectBadSchedule(h);
        h = _defaults();
        h.step3Bps = h.step2Bps - 1;
        checked += _expectBadSchedule(h);
        h = _defaults();
        h.step3Bps = 5_001;
        checked += _expectBadSchedule(h);
        h = _defaults();
        h.corporateActionBps = 5_001;
        checked += _expectBadSchedule(h);
        assertEq(checked, 9, "every bound was exercised");

        // The extremes of the bounds are accepted, and nothing is mutable afterwards.
        h = CertMorphoOracle.Haircuts(STALENESS, 1, STALENESS + 1, 1, 30 days, 5_000, 5_000);
        CertMorphoOracle a = this.deployAdapter(address(certOracle), address(cert), address(usdg), h);
        assertEq(a.step1Age(), STALENESS);
        assertEq(a.step3Bps(), 5_000);
        assertEq(address(a.feed()), address(feed));
        assertEq(a.oracleStalenessSeconds(), STALENESS);
        assertEq(a.collateralToken(), address(cert));
        assertEq(a.loanToken(), address(usdg));
    }

    function _expectBadSchedule(CertMorphoOracle.Haircuts memory h) internal returns (uint256) {
        vm.expectRevert(CertMorphoOracle.CertMorphoOracle_ScheduleOutOfBounds.selector);
        this.deployAdapter(address(certOracle), address(cert), address(usdg), h);
        return 1;
    }

    // --------------------------------------------------------------- liquidation math sanity

    MockMorphoBlue internal morpho;
    address internal constant IRM = address(0x1A1A);
    address internal borrower = address(0xB0B);

    function _market(uint256 lltv) internal returns (MarketParams memory p) {
        morpho = new MockMorphoBlue();
        morpho.enableIrm(IRM);
        morpho.enableLltv(lltv);
        p = MarketParams(address(usdg), address(cert), address(adapter), IRM, lltv);
        morpho.createMarket(p);
    }

    /// @dev Opens a position borrowing the maximum the health check allows: exactly at LLTV.
    function _atLltv(MarketParams memory p, uint256 collateral) internal returns (uint256 debt) {
        morpho.supplyCollateral(p, collateral, borrower);
        debt = morpho.maxBorrow(collateral, adapter.price(), p.lltv);
        morpho.borrow(p, debt, borrower);
        assertTrue(morpho.isHealthy(p, borrower));
        vm.expectRevert(bytes("insufficient collateral"));
        morpho.borrow(p, 1, borrower);
    }

    /// @dev Liquidates the whole debt at the current oracle price; returns the collateral seized.
    function _liquidateAll(MarketParams memory p) internal returns (uint256 seized, uint256 repaid) {
        (, uint256 debt) = morpho.position(_id(p), borrower);
        seized = morpho.seizeFor(debt, adapter.price(), p.lltv);
        (uint256 coll,) = morpho.position(_id(p), borrower);
        if (seized > coll) seized = coll;
        repaid = morpho.liquidate(p, borrower, seized);
    }

    function _id(MarketParams memory p) internal pure returns (Id) {
        return MarketParamsLib.id(p);
    }

    function _weekendAndP99Gap(uint256 lltv) internal {
        MarketParams memory p = _market(lltv);
        uint256 debt = _atLltv(p, 100e18);

        // Saturday, px() stale: the 3% haircut alone makes an at-LLTV position liquidatable, so it
        // can be closed DURING the closure instead of after the gap.
        vm.warp(T0 + STALENESS + 1);
        assertFalse(morpho.isHealthy(p, borrower), "liquidatable over the weekend");

        // Monday 00:00 UTC, the feed restarts one p99 gap lower. Fresh again, no haircut.
        vm.warp(T0 + 53 hours);
        uint256 monday18 = TSLA_18 * (10_000 - WEEKEND_P99_BPS) / 10_000;
        feed.set(int256(monday18 / 1e10), block.timestamp);
        (, uint256 h,, CertMorphoOracle.Source src) = adapter.quote();
        assertEq(uint256(src), uint256(CertMorphoOracle.Source.Fresh));
        assertEq(h, 0);
        assertFalse(morpho.isHealthy(p, borrower), "liquidatable after the gap");

        (uint256 seized, uint256 repaid) = _liquidateAll(p);
        (uint256 collLeft, uint256 debtLeft) = morpho.position(_id(p), borrower);
        assertEq(morpho.badDebt(_id(p)), 0, "no bad debt");
        assertGt(collLeft, 0, "collateral left over for the borrower");
        assertLe(debtLeft, 1, "debt cleared (rounding dust only)");
        assertApproxEqAbs(repaid, debt, 1);
        // The liquidator is whole at the TRUE Monday price: seized value covers what it repaid.
        assertGe(seized * monday18 / 1e18 / 1e12, repaid);
    }

    function test_liquidation_weekend_p99_gap_no_bad_debt_385() public {
        _weekendAndP99Gap(0.385e18);
    }

    function test_liquidation_weekend_p99_gap_no_bad_debt_625() public {
        _weekendAndP99Gap(0.625e18);
    }

    function test_liquidation_weekend_p99_gap_no_bad_debt_77() public {
        _weekendAndP99Gap(0.77e18);
    }

    /// @notice Liquidating DURING the closure, at the haircut price: the lender is repaid in full
    ///         and the liquidator receives more than it paid at Friday's print.
    function test_liquidation_during_weekend_at_haircut_price() public {
        MarketParams memory p = _market(0.385e18);
        uint256 debt = _atLltv(p, 100e18);
        vm.warp(T0 + 60 hours);
        (uint256 seized, uint256 repaid) = _liquidateAll(p);
        assertEq(morpho.badDebt(_id(p)), 0);
        assertApproxEqAbs(repaid, debt, 1);
        assertGt(seized * TSLA_18 / 1e18 / 1e12, repaid * 115 / 100 - 1, "paid the full 15% incentive, plus the 3% cut");
    }

    /// @notice Stress beyond the measurement. At 38.5% LLTV (incentive 1.15) an at-LLTV position
    ///         carries no bad debt for any gap up to 1 - 0.385 x 1.15 = 55.7%; at 62.5% (1.127)
    ///         up to 29.6%. The haircut is not what protects against a tail gap; the LLTV is.
    function testFuzz_gap_bound_385(uint256 gapBps) public {
        gapBps = bound(gapBps, WEEKEND_P99_BPS, 5_500);
        _gap(0.385e18, gapBps, false);
    }

    function testFuzz_gap_bound_625(uint256 gapBps) public {
        gapBps = bound(gapBps, WEEKEND_P99_BPS, 2_900);
        _gap(0.625e18, gapBps, false);
    }

    function test_gap_past_bound_leaves_bad_debt() public {
        _gap(0.385e18, 5_600, true);
    }

    function _gap(uint256 lltv, uint256 gapBps, bool expectBadDebt) internal {
        MarketParams memory p = _market(lltv);
        _atLltv(p, 100e18);
        vm.warp(T0 + 53 hours);
        feed.set(int256(TSLA_18 * (10_000 - gapBps) / 10_000 / 1e10), block.timestamp);
        _liquidateAll(p);
        if (expectBadDebt) assertGt(morpho.badDebt(_id(p)), 0);
        else assertEq(morpho.badDebt(_id(p)), 0);
    }

    function test_weekend_borrow_capacity_is_cut() public {
        MarketParams memory p = _market(0.385e18);
        morpho.supplyCollateral(p, 100e18, borrower);
        uint256 friday = morpho.maxBorrow(100e18, adapter.price(), p.lltv);
        vm.warp(T0 + 30 hours);
        uint256 saturday = morpho.maxBorrow(100e18, adapter.price(), p.lltv);
        assertEq(saturday, friday * 9_700 / 10_000);
        vm.expectRevert(bytes("insufficient collateral"));
        morpho.borrow(p, saturday + 1, borrower);
        morpho.borrow(p, saturday, borrower);
    }

    function test_repay_and_liquidation_work_when_deep_stale() public {
        MarketParams memory p = _market(0.385e18);
        uint256 debt = _atLltv(p, 100e18);
        vm.warp(T0 + 365 days);
        morpho.repay(p, debt / 2, borrower); // Morpho's repay never reads the oracle
        (uint256 c, uint256 d) = morpho.position(_id(p), borrower);
        assertEq(d, debt - debt / 2);
        assertEq(adapter.price(), _cut(TSLA_18, 1_500), "still answering a year on");
        // At half the debt and a 15% cut, the position is healthy: the cut is bounded.
        assertTrue(morpho.isHealthy(p, borrower));
        morpho.withdrawCollateral(p, c / 10, borrower);
    }
}
