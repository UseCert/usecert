// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "openzeppelin-contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

import {VaultFixture} from "./helpers/VaultFixture.sol";
import {CertVault} from "../src/CertVault.sol";
import {Certificate} from "../src/Certificate.sol";
import {CertOracle} from "../src/CertOracle.sol";
import {SolvencyRegistry} from "../src/SolvencyRegistry.sol";
import {CapacityOracle} from "../src/CapacityOracle.sol";
import {BufferBook} from "../src/BufferBook.sol";
import {CertFactory} from "../src/CertFactory.sol";
import {DcaVault} from "../src/periphery/DcaVault.sol";
import {MockLighter} from "./mocks/MockLighter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

/// @notice A collateral token that can call back into any contract from inside a transfer out of
///         one chosen address. Unarmed it is exactly MockERC20. Used as the vault's collateral in
///         this whole file so the reentrancy tests exercise the real vault, not a stub.
contract HookToken is MockERC20 {
    address public hookFrom;
    address public hookTarget;
    bytes public hookData;
    bool public hookFired;
    bool public hookOk;
    bytes public hookRet;
    /// @dev Fee-on-transfer mode: a transfer INTO `feeTo` loses `fee` units on the way.
    address public feeTo;
    uint256 public fee;

    function setFee(address to, uint256 amount) external {
        feeTo = to;
        fee = amount;
    }

    constructor() MockERC20("USDG", "USDG", 6) {}

    function arm(address from_, address target_, bytes calldata data_) external {
        hookFrom = from_;
        hookTarget = target_;
        hookData = data_;
        hookFired = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to == feeTo && to != address(0) && from != address(0) && fee != 0 && value >= fee) {
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
        address t = hookTarget;
        if (t != address(0) && from == hookFrom) {
            hookTarget = address(0); // fire once
            hookFired = true;
            (hookOk, hookRet) = t.call(hookData);
        }
    }
}

contract DcaVaultTest is VaultFixture {
    DcaVault internal dca;
    CertFactory internal factory;
    HookToken internal hook;

    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    uint64 internal batch = 1;

    uint256 internal constant AMOUNT = 100e6; // $100 a period
    uint256 internal constant DAY = 1 days;

    /// @dev VaultFixture.setUp with HookToken as the collateral and keeper mode on, as on 4663.
    function setUp() public override {
        vm.warp(1_800_000_000);
        hook = new HookToken();
        usdg = hook;
        feed = new MockAggregatorV3(8, 355_86000000);
        lighter = new MockLighter(IERC20(address(usdg)), ASSET_IDX, 4);
        reg = new SolvencyRegistry(attester);
        oracle = new CertOracle(address(feed), attester, 2, 3600, 500, 100, 3600, false, 3600, address(0));
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
        lighter.setMarkPrice(MARKET, PX);

        usdg.mint(address(this), 1_000_000e6);
        usdg.approve(address(vault), type(uint256).max);
        vault.seedBuffer(100_000e6);
        vault.bootstrap();
        lighter.settleBatch();

        // Keeper mode and a settler, as deployed; a $10 venue minimum.
        vm.prank(gov);
        vault.enableKeeperHedging();
        _setSettler(vault);
        _applyDelayed(vault, abi.encodeCall(CertVault.setVenueMinimums, (0, 10e18)));

        factory = new CertFactory(address(lighter), address(reg), address(cap), gov);
        vm.prank(gov);
        factory.registerVault(address(vault), address(cert));

        dca = new DcaVault(address(factory), address(usdg));

        usdg.mint(bob, 1_000_000e6);
        vm.prank(bob);
        usdg.approve(address(dca), type(uint256).max);
    }

    // ------------------------------------------------------------------------------ helpers

    /// A fresh mark, feed round and attestation, so the vault is mintable at the current time.
    function _fresh() internal {
        _setPrice(PX);
        vm.prank(attester);
        reg.attest(address(vault), ++batch, 0, 0, 1_190_000e18);
    }

    function _create(uint256 amount, uint256 period, uint256 window, uint256 periods, uint256 tip)
        internal
        returns (uint256 id)
    {
        vm.prank(bob);
        id = dca.createSchedule(address(vault), amount, period, window, periods, 0, tip);
    }

    function _start(uint256 id) internal view returns (uint256 start) {
        (, uint64 s,,,,,,,,) = dca.schedules(id);
        start = s;
    }

    function _next(uint256 id) internal view returns (uint256 next) {
        (,,,,,, uint32 n,,,) = dca.schedules(id);
        next = n;
    }

    function _certsOf(uint256 receiptId) internal view returns (uint256 c) {
        (,,,,,, c) = vault.mintReceipts(receiptId);
    }

    function _settle(uint256 receiptId) internal {
        vm.prank(settler);
        vault.settleMint(receiptId, PX);
    }

    function _exec(uint256 id) internal returns (uint256 receiptId) {
        vm.prank(keeper);
        receiptId = dca.execute(id);
    }

    function _pendingOwner(uint256 receiptId) internal view returns (address o) {
        (o,,) = dca.pending(address(vault), receiptId);
    }

    // ------------------------------------------------------------------------------ cadence

    function test_executesAtCadence_andCertificatesEndWithTheUser() public {
        uint256 id = _create(AMOUNT, DAY, 6 hours, 5, 0);
        uint256 t0 = _start(id);
        uint256 bobBefore = usdg.balanceOf(bob);
        uint256 expected;

        for (uint256 i = 0; i < 5; i++) {
            vm.warp(t0 + i * DAY + 1 hours);
            _fresh();
            uint256 rid = _exec(id);
            assertEq(_next(id), i + 1, "period not consumed");
            assertEq(cert.balanceOf(address(dca)), 0, "certificates before settlement");
            _settle(rid);
            expected += _certsOf(rid);
            vm.prank(stranger);
            dca.forward(address(vault), rid);
            assertEq(_pendingOwner(rid), address(0), "record not cleared");
        }
        assertGt(expected, 0);
        assertEq(cert.balanceOf(bob), expected, "certificates did not reach the user");
        assertEq(cert.balanceOf(address(dca)), 0, "certificates left in DcaVault");
        assertEq(cert.balanceOf(stranger), 0);
        assertEq(bobBefore - usdg.balanceOf(bob), 5 * AMOUNT, "charged other than 5 periods");
        assertEq(usdg.balanceOf(address(dca)), 0, "USDG left in DcaVault");

        vm.warp(t0 + 5 * DAY + 1 hours);
        _fresh();
        vm.expectRevert(DcaVault.DcaVault_Finished.selector);
        _exec(id);
    }

    function test_receiptIsTheVaultsOwnAndNamesDcaVault() public {
        uint256 id = _create(AMOUNT, DAY, 6 hours, 3, 0);
        _fresh();
        vm.expectEmit(true, true, true, true, address(dca));
        emit DcaVault.Executed(id, 0, 1, address(vault), AMOUNT, keeper, 0);
        uint256 rid = _exec(id);
        (address user, uint256 escrow,,,,,) = vault.mintReceipts(rid);
        assertEq(user, address(dca));
        assertEq(escrow + vault.mintFee(rid), AMOUNT, "vault did not receive exactly the period amount");
        assertEq(_pendingOwner(rid), bob);
        assertEq(usdg.allowance(address(dca), address(vault)), 0, "allowance to the vault left standing");
    }

    // ------------------------------------------------------------------------------ early / twice

    function test_cannotExecuteEarlyOrTwice() public {
        vm.prank(bob);
        uint256 id = dca.createSchedule(address(vault), AMOUNT, DAY, 6 hours, 3, block.timestamp + 1 hours, 0);
        uint256 t0 = _start(id);

        _fresh();
        vm.expectRevert(DcaVault.DcaVault_NotDue.selector);
        _exec(id);

        vm.warp(t0);
        _fresh();
        _exec(id);

        vm.expectRevert(DcaVault.DcaVault_AlreadyExecuted.selector);
        _exec(id);

        // Still inside period 0's window, and after it but before period 1 falls due.
        vm.warp(t0 + 5 hours);
        _fresh();
        vm.expectRevert(DcaVault.DcaVault_AlreadyExecuted.selector);
        _exec(id);
        vm.warp(t0 + DAY - 1);
        _fresh();
        vm.expectRevert(DcaVault.DcaVault_AlreadyExecuted.selector);
        _exec(id);

        vm.warp(t0 + DAY);
        _fresh();
        _exec(id);
        assertEq(_next(id), 2);
    }

    function test_windowClosedPeriodIsMissedNotCaughtUp() public {
        uint256 id = _create(AMOUNT, DAY, 6 hours, 3, 0);
        uint256 t0 = _start(id);
        uint256 bobBefore = usdg.balanceOf(bob);

        vm.warp(t0 + 6 hours + 1);
        _fresh();
        vm.expectRevert(DcaVault.DcaVault_WindowClosed.selector);
        _exec(id);
        assertEq(usdg.balanceOf(bob), bobBefore, "charged for a missed period");

        vm.warp(t0 + 2 * DAY + 1);
        _fresh();
        vm.expectEmit(true, false, false, true, address(dca));
        emit DcaVault.PeriodsMissed(id, 0, 1);
        _exec(id);
        assertEq(_next(id), 3);
        assertEq(bobBefore - usdg.balanceOf(bob), AMOUNT, "a missed period was caught up");

        vm.expectRevert(DcaVault.DcaVault_AlreadyExecuted.selector);
        _exec(id);
    }

    // ------------------------------------------------------------------------------ cancel

    function test_cancelStopsEverything() public {
        uint256 id = _create(AMOUNT, DAY, 6 hours, 10, 0);
        uint256 t0 = _start(id);
        _fresh();
        uint256 rid = _exec(id);

        vm.prank(stranger);
        vm.expectRevert(DcaVault.DcaVault_NotScheduleOwner.selector);
        dca.cancel(id);

        vm.expectEmit(true, false, false, true, address(dca));
        emit DcaVault.Cancelled(id, 1);
        vm.prank(bob);
        dca.cancel(id);

        vm.prank(bob);
        vm.expectRevert(DcaVault.DcaVault_Cancelled.selector);
        dca.cancel(id);

        uint256 bobAfterCancel = usdg.balanceOf(bob);
        for (uint256 i = 1; i < 10; i++) {
            vm.warp(t0 + i * DAY);
            _fresh();
            vm.expectRevert(DcaVault.DcaVault_Cancelled.selector);
            _exec(id);
        }
        assertEq(usdg.balanceOf(bob), bobAfterCancel, "taken after cancel");
        (bool ok,,) = dca.nextExecution(id);
        assertFalse(ok);

        // What was requested before the cancel is still the user's. Past the settle window, so
        // settle is gone and the escrow comes back instead.
        vm.warp(t0 + SETTLE_WINDOW + 1);
        vault.stageRefund(rid);
        vault.refundMint(rid);
        dca.forward(address(vault), rid);
        assertEq(usdg.balanceOf(bob), bobAfterCancel + AMOUNT);
    }

    // ------------------------------------------------------------------------------ skips

    function test_mintPausedPeriodCostsNothingAndDefersWithinWindow() public {
        uint256 id = _create(AMOUNT, DAY, 12 hours, 3, 0);
        uint256 t0 = _start(id);
        uint256 bobBefore = usdg.balanceOf(bob);

        // The weekend: the mark is older than maxMarkAge, so mintAllowed is false.
        vm.warp(t0 + 2 hours);
        assertFalse(oracle.mintAllowed());
        vm.expectRevert(CertVault.CertVault_MintPaused.selector);
        _exec(id);
        assertEq(usdg.balanceOf(bob), bobBefore, "charged for a paused period");
        assertEq(_next(id), 0, "a failed execution consumed the period");

        // Mintable again inside the same window: the period runs, deferred, not lost.
        vm.warp(t0 + 10 hours);
        _fresh();
        _exec(id);
        assertEq(bobBefore - usdg.balanceOf(bob), AMOUNT);
    }

    function test_zeroCapacityPeriodCostsNothing() public {
        uint256 id = _create(AMOUNT, DAY, 6 hours, 3, 0);
        uint256 bobBefore = usdg.balanceOf(bob);
        _fresh();
        vm.prank(gov);
        cap.setAbsoluteCap(address(vault), 0);
        vm.expectRevert(CertVault.CertVault_AtCapacity.selector);
        _exec(id);
        assertEq(usdg.balanceOf(bob), bobBefore);
        assertEq(_next(id), 0);
    }

    function test_staleAttestationPeriodCostsNothing() public {
        uint256 id = _create(AMOUNT, DAY, 6 hours, 3, 0);
        uint256 bobBefore = usdg.balanceOf(bob);
        vm.warp(block.timestamp + 1 hours);
        _setPrice(PX); // price fresh, attestation not: capacity reads 0
        vm.expectRevert(CertVault.CertVault_AtCapacity.selector);
        _exec(id);
        assertEq(usdg.balanceOf(bob), bobBefore);
    }

    function test_venueMinimumRaisedAfterCreationCostsNothing() public {
        uint256 id = _create(20e6, DAY, 6 hours, 3, 0);
        _applyDelayed(vault, abi.encodeCall(CertVault.setVenueMinimums, (0, 50e18)));
        _fresh();
        uint256 bobBefore = usdg.balanceOf(bob);
        vm.expectRevert(CertVault.CertVault_BelowVenueMinimum.selector);
        _exec(id);
        assertEq(usdg.balanceOf(bob), bobBefore);
    }

    function test_retiredVaultPeriodCostsNothing() public {
        uint256 id = _create(AMOUNT, DAY, 6 hours, 3, 0);
        // No supply, no open receipts, nothing owed: governance may retire it.
        vm.prank(gov);
        vault.retire();
        _fresh();
        uint256 bobBefore = usdg.balanceOf(bob);
        vm.expectRevert(CertVault.CertVault_Retired.selector);
        _exec(id);
        assertEq(usdg.balanceOf(bob), bobBefore);
    }

    // ------------------------------------------------------------------------------ refunds

    function test_refundEndsWithTheUser_feeIncluded_tipNot() public {
        uint256 id = _create(AMOUNT, DAY, 6 hours, 3, 0.5e6);
        _fresh();
        uint256 bobBefore = usdg.balanceOf(bob);
        uint256 rid = _exec(id);
        assertEq(usdg.balanceOf(keeper), 0.5e6, "tip not paid");
        assertEq(bobBefore - usdg.balanceOf(bob), AMOUNT + 0.5e6);

        vm.expectRevert(DcaVault.DcaVault_NotFinal.selector);
        dca.forward(address(vault), rid);

        // The settler never settles. The refund is permissionless on the vault; so is forward.
        vm.warp(block.timestamp + SETTLE_WINDOW + 1);
        vm.prank(stranger);
        vault.stageRefund(rid);
        vm.prank(stranger);
        vault.refundMint(rid);
        assertEq(usdg.balanceOf(address(dca)), AMOUNT, "refund did not land");

        vm.expectEmit(true, true, true, true, address(dca));
        emit DcaVault.RefundForwarded(address(vault), rid, bob, id, AMOUNT);
        vm.prank(stranger);
        dca.forward(address(vault), rid);
        assertEq(bobBefore - usdg.balanceOf(bob), 0.5e6, "user not made whole (bar the tip)");
        assertEq(usdg.balanceOf(address(dca)), 0);
        assertEq(usdg.balanceOf(stranger), 0);

        vm.expectRevert(DcaVault.DcaVault_UnknownReceipt.selector);
        dca.forward(address(vault), rid);
    }

    /// Refunds in DcaVault waiting to be forwarded are never spent by another execution: a pull
    /// that delivers less than the period amount (fee-on-transfer) would otherwise let the vault's
    /// pull top up from the pooled refund.
    function test_unforwardedRefundIsNotSpentByLaterExecutions() public {
        uint256 id = _create(AMOUNT, DAY, 6 hours, 5, 0);
        uint256 t0 = _start(id);
        _fresh();
        uint256 rid = _exec(id);
        vm.warp(t0 + SETTLE_WINDOW + 1);
        vault.stageRefund(rid);
        vault.refundMint(rid);
        assertEq(usdg.balanceOf(address(dca)), AMOUNT);

        hook.setFee(address(dca), 1e6);
        uint256 bobBefore = usdg.balanceOf(bob);
        vm.warp(t0 + DAY + 2 hours);
        _fresh();
        vm.expectRevert(DcaVault.DcaVault_BadPull.selector);
        _exec(id);
        assertEq(usdg.balanceOf(address(dca)), AMOUNT, "pooled refund touched");
        assertEq(usdg.balanceOf(bob), bobBefore);

        hook.setFee(address(0), 0);
        dca.forward(address(vault), rid);
        assertEq(usdg.balanceOf(address(dca)), 0);
        assertEq(usdg.balanceOf(bob), bobBefore + AMOUNT);
    }

    function test_forwardToIsOwnerOnly() public {
        uint256 id = _create(AMOUNT, DAY, 6 hours, 3, 0);
        _fresh();
        uint256 rid = _exec(id);
        _settle(rid);
        address cold = makeAddr("cold");

        vm.prank(stranger);
        vm.expectRevert(DcaVault.DcaVault_NotScheduleOwner.selector);
        dca.forwardTo(address(vault), rid, stranger);

        vm.prank(bob);
        dca.forwardTo(address(vault), rid, cold);
        assertEq(cert.balanceOf(cold), _certsOf(rid));
        assertEq(cert.balanceOf(address(dca)), 0);
    }

    function test_settledAndRefundedReceiptsInterleaved() public {
        uint256 id = _create(AMOUNT, DAY, 6 hours, 4, 0);
        uint256 t0 = _start(id);
        uint256[] memory rids = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(t0 + i * DAY);
            _fresh();
            rids[i] = _exec(id);
            if (i % 2 == 0) _settle(rids[i]);
        }
        vm.warp(t0 + 4 * DAY + SETTLE_WINDOW);
        uint256 bobUsdg = usdg.balanceOf(bob);
        uint256 certs;
        for (uint256 i = 0; i < 4; i++) {
            if (i % 2 == 0) {
                certs += _certsOf(rids[i]);
            } else {
                vault.stageRefund(rids[i]);
                vault.refundMint(rids[i]);
            }
        }
        // Forward in reverse order: each record pays exactly its own.
        for (uint256 i = 4; i > 0; i--) {
            dca.forward(address(vault), rids[i - 1]);
        }
        assertEq(cert.balanceOf(bob), certs);
        assertEq(usdg.balanceOf(bob) - bobUsdg, 2 * AMOUNT);
        assertEq(cert.balanceOf(address(dca)), 0);
        assertEq(usdg.balanceOf(address(dca)), 0);
    }

    // ------------------------------------------------------------------------------ allowance

    function test_revokedAllowanceFailsSafely() public {
        uint256 id = _create(AMOUNT, DAY, 6 hours, 3, 0);
        uint256 t0 = _start(id);
        _fresh();
        vm.prank(bob);
        usdg.approve(address(dca), 0);
        uint256 bobBefore = usdg.balanceOf(bob);
        uint256 openBefore = vault.openMintReceipts();

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(dca), 0, AMOUNT)
        );
        _exec(id);
        assertEq(usdg.balanceOf(bob), bobBefore);
        assertEq(_next(id), 0, "period consumed by a failed pull");
        assertEq(vault.openMintReceipts(), openBefore, "a receipt was opened");

        // Allowance for the amount but not the tip: still all or nothing.
        vm.prank(bob);
        uint256 id2 = dca.createSchedule(address(vault), AMOUNT, DAY, 6 hours, 3, 0, 1e6);
        vm.prank(bob);
        usdg.approve(address(dca), AMOUNT);
        vm.expectRevert();
        _exec(id2);
        assertEq(usdg.balanceOf(bob), bobBefore);

        // Re-approved inside the window: it runs.
        vm.prank(bob);
        usdg.approve(address(dca), type(uint256).max);
        vm.warp(t0 + 1 hours);
        _fresh();
        _exec(id);
        assertEq(bobBefore - usdg.balanceOf(bob), AMOUNT);
    }

    function test_insufficientBalanceFailsSafely() public {
        uint256 id = _create(AMOUNT, DAY, 6 hours, 3, 0);
        uint256 all = usdg.balanceOf(bob);
        vm.prank(bob);
        usdg.transfer(stranger, all - AMOUNT + 1);
        _fresh();
        vm.expectRevert();
        _exec(id);
        assertEq(usdg.balanceOf(bob), AMOUNT - 1);
        assertEq(_next(id), 0);
    }

    // ------------------------------------------------------------------------------ creation

    function test_createValidation() public {
        vm.startPrank(bob);
        vm.expectRevert(DcaVault.DcaVault_UnknownVault.selector);
        dca.createSchedule(stranger, AMOUNT, DAY, 1 hours, 3, 0, 0);
        vm.expectRevert(DcaVault.DcaVault_BelowVenueMinimum.selector);
        dca.createSchedule(address(vault), 10e6, DAY, 1 hours, 3, 0, 0); // $10 less the fee < $10.10
        vm.expectRevert(DcaVault.DcaVault_BelowVenueMinimum.selector);
        dca.createSchedule(address(vault), 0, DAY, 1 hours, 3, 0, 0);
        vm.expectRevert(DcaVault.DcaVault_BadPeriod.selector);
        dca.createSchedule(address(vault), AMOUNT, DAY - 1, 1 hours, 3, 0, 0);
        vm.expectRevert(DcaVault.DcaVault_BadWindow.selector);
        dca.createSchedule(address(vault), AMOUNT, DAY, DAY + 1, 3, 0, 0);
        vm.expectRevert(DcaVault.DcaVault_BadWindow.selector);
        dca.createSchedule(address(vault), AMOUNT, DAY, 1 hours - 1, 3, 0, 0);
        vm.expectRevert(DcaVault.DcaVault_BadPeriodCount.selector);
        dca.createSchedule(address(vault), AMOUNT, DAY, 1 hours, 0, 0, 0);
        vm.expectRevert(DcaVault.DcaVault_BadPeriodCount.selector);
        dca.createSchedule(address(vault), AMOUNT, DAY, 1 hours, 10_001, 0, 0);
        vm.expectRevert(DcaVault.DcaVault_BadStart.selector);
        dca.createSchedule(address(vault), AMOUNT, DAY, 1 hours, 3, block.timestamp - 1, 0);
        vm.expectRevert(DcaVault.DcaVault_BadStart.selector);
        dca.createSchedule(address(vault), AMOUNT, DAY, 1 hours, 3, block.timestamp + 366 days, 0);
        // Tip: at most 1% of the amount and at most 1 USDG.
        vm.expectRevert(DcaVault.DcaVault_TipTooHigh.selector);
        dca.createSchedule(address(vault), AMOUNT, DAY, 1 hours, 3, 0, 1e6 + 1);
        vm.expectRevert(DcaVault.DcaVault_TipTooHigh.selector);
        dca.createSchedule(address(vault), 20e6, DAY, 1 hours, 3, 0, 0.2e6 + 1);
        uint256 id = dca.createSchedule(address(vault), 20e6, DAY, 1 hours, 3, 0, 0.2e6);
        vm.stopPrank();
        assertEq(dca.perExecution(id), 20.2e6);
        assertEq(usdg.balanceOf(address(dca)), 0, "creation took funds");
    }

    function test_wrongCollateralVaultRefused() public {
        DcaVault other = new DcaVault(address(factory), address(new MockERC20("X", "X", 6)));
        vm.prank(bob);
        vm.expectRevert(DcaVault.DcaVault_WrongCollateral.selector);
        other.createSchedule(address(vault), AMOUNT, DAY, 1 hours, 3, 0, 0);
    }

    function test_unknownScheduleAndReceipt() public {
        vm.expectRevert(DcaVault.DcaVault_UnknownSchedule.selector);
        dca.execute(99);
        vm.expectRevert(DcaVault.DcaVault_UnknownSchedule.selector);
        dca.cancel(99);
        vm.expectRevert(DcaVault.DcaVault_UnknownReceipt.selector);
        dca.forward(address(vault), 99);
    }

    /// A receipt someone opened directly on the vault is not DcaVault's to forward.
    function test_foreignReceiptCannotBeForwarded() public {
        usdg.mint(alice, AMOUNT);
        vm.prank(alice);
        usdg.approve(address(vault), AMOUNT);
        _fresh();
        vm.prank(alice);
        uint256 rid = vault.requestMint(AMOUNT);
        _settle(rid);
        vm.expectRevert(DcaVault.DcaVault_UnknownReceipt.selector);
        dca.forward(address(vault), rid);
        assertEq(cert.balanceOf(alice), _certsOf(rid));
    }

    // ------------------------------------------------------------------------------ reentrancy

    function _reenter() internal view returns (bool ok, bytes memory ret) {
        assertTrue(hook.hookFired(), "hook did not fire");
        ok = hook.hookOk();
        ret = hook.hookRet();
    }

    function test_reentrancy_executeFromInsideThePull() public {
        uint256 id = _create(AMOUNT, DAY, 6 hours, 3, 0);
        _fresh();
        hook.arm(bob, address(dca), abi.encodeCall(DcaVault.execute, (id)));
        uint256 bobBefore = usdg.balanceOf(bob);
        _exec(id);
        (bool ok, bytes memory ret) = _reenter();
        assertFalse(ok, "reentrant execute succeeded");
        assertEq(bytes4(ret), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(bobBefore - usdg.balanceOf(bob), AMOUNT, "executed twice");
        assertEq(_next(id), 1);
    }

    function test_reentrancy_cancelAndForwardFromInsideTheVaultPull() public {
        uint256 id = _create(AMOUNT, DAY, 6 hours, 3, 0);
        _fresh();
        uint256 rid = _exec(id);
        _settle(rid);

        vm.warp(block.timestamp + DAY);
        _fresh();
        // Fires when the vault pulls from DcaVault, i.e. from inside requestMint.
        hook.arm(address(dca), address(dca), abi.encodeCall(DcaVault.forward, (address(vault), rid)));
        _exec(id);
        (bool ok, bytes memory ret) = _reenter();
        assertFalse(ok, "reentrant forward succeeded");
        assertEq(bytes4(ret), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(_pendingOwner(rid), bob, "record consumed by the reentrant call");
        dca.forward(address(vault), rid);
        assertEq(cert.balanceOf(bob), _certsOf(rid));
    }

    function test_reentrancy_forwardFromInsideARefundForward() public {
        uint256 id = _create(AMOUNT, DAY, 6 hours, 3, 0);
        uint256 t0 = _start(id);
        _fresh();
        uint256 r1 = _exec(id);
        vm.warp(t0 + DAY);
        _fresh();
        uint256 r2 = _exec(id);
        vm.warp(t0 + DAY + SETTLE_WINDOW + 1);
        vault.stageRefund(r1);
        vault.refundMint(r1);
        vault.stageRefund(r2);
        vault.refundMint(r2);

        uint256 bobBefore = usdg.balanceOf(bob);
        // While forwarding r1, try to forward r1 again (double pay) and r2.
        hook.arm(address(dca), address(dca), abi.encodeCall(DcaVault.forward, (address(vault), r1)));
        dca.forward(address(vault), r1);
        (bool ok, bytes memory ret) = _reenter();
        assertFalse(ok);
        assertEq(bytes4(ret), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(usdg.balanceOf(bob) - bobBefore, AMOUNT, "paid twice");
        assertEq(usdg.balanceOf(address(dca)), AMOUNT, "r2's refund touched");
        dca.forward(address(vault), r2);
        assertEq(usdg.balanceOf(address(dca)), 0);
    }

    function test_reentrancy_createFromInsideThePull() public {
        uint256 id = _create(AMOUNT, DAY, 6 hours, 3, 0);
        _fresh();
        hook.arm(
            bob, address(dca), abi.encodeCall(DcaVault.createSchedule, (address(vault), AMOUNT, DAY, 1 hours, 3, 0, 0))
        );
        uint256 nextId = dca.nextScheduleId();
        _exec(id);
        (bool ok,) = _reenter();
        assertFalse(ok);
        assertEq(dca.nextScheduleId(), nextId);
    }

    // ------------------------------------------------------------------------------ fuzz

    struct Fz {
        uint256 id;
        uint256 t0;
        uint256 periods;
        uint256 amount;
        uint256 period;
        uint256 window;
        uint256 executeMask;
        uint256 settleMask;
        uint256 offsetSeed;
        uint256 bobBefore;
        uint256 executed;
    }

    /// Any schedule shape, any pattern of executed / missed periods, and any mix of settled and
    /// refunded receipts: the user pays exactly amount x executed, receives exactly the
    /// certificates of the settled ones and the full amount of the refunded ones, and DcaVault is
    /// left holding nothing.
    function testFuzz_scheduleAccounting(
        uint256 periods,
        uint256 amount,
        uint256 periodDays,
        uint256 executeMask,
        uint256 settleMask,
        uint256 offsetSeed
    ) public {
        Fz memory f;
        f.periods = bound(periods, 1, 12);
        f.amount = bound(amount, 11e6, 5_000e6);
        f.period = bound(periodDays, 1, 30) * DAY;
        f.window = f.period / 2;
        f.executeMask = executeMask;
        f.settleMask = settleMask;
        f.offsetSeed = offsetSeed;
        f.id = _create(f.amount, f.period, f.window, f.periods, 0);
        f.t0 = _start(f.id);
        f.bobBefore = usdg.balanceOf(bob);

        uint256[] memory rids = _runPeriods(f);
        assertEq(f.bobBefore - usdg.balanceOf(bob), f.executed * f.amount, "charged for other than executed periods");
        _finishAll(f, rids);

        vm.expectRevert(DcaVault.DcaVault_Finished.selector);
        _exec(f.id);
    }

    function _runPeriods(Fz memory f) internal returns (uint256[] memory rids) {
        rids = new uint256[](f.periods);
        for (uint256 i = 0; i < f.periods; i++) {
            if ((f.executeMask >> i) & 1 == 0) continue;
            uint256 off = uint256(keccak256(abi.encode(f.offsetSeed, i))) % (f.window + 1);
            vm.warp(f.t0 + i * f.period + off);
            _fresh();
            rids[i] = _exec(f.id);
            f.executed++;
            // An immediate second try in the same period is refused.
            vm.expectRevert(DcaVault.DcaVault_AlreadyExecuted.selector);
            _exec(f.id);
            if ((f.settleMask >> i) & 1 == 1) _settle(rids[i]);
        }
    }

    function _finishAll(Fz memory f, uint256[] memory rids) internal {
        vm.warp(f.t0 + f.periods * f.period + SETTLE_WINDOW + 1);
        uint256 certs;
        uint256 refunds;
        for (uint256 i = 0; i < f.periods; i++) {
            if (rids[i] == 0) continue;
            if ((f.settleMask >> i) & 1 == 1) {
                certs += _certsOf(rids[i]);
            } else {
                vault.stageRefund(rids[i]);
                vault.refundMint(rids[i]);
                refunds += f.amount;
            }
            vm.prank(stranger);
            dca.forward(address(vault), rids[i]);
        }
        assertEq(cert.balanceOf(bob), certs);
        assertEq(f.bobBefore - usdg.balanceOf(bob), f.executed * f.amount - refunds);
        assertEq(cert.balanceOf(address(dca)), 0, "certificates stuck");
        assertEq(usdg.balanceOf(address(dca)), 0, "USDG stuck");
    }

    /// Any time at all: execute succeeds only inside an unexecuted period's window.
    function testFuzz_onlyInsideAWindow(uint256 periodDays, uint256 windowHours, uint256 t) public {
        uint256 period = bound(periodDays, 1, 14) * DAY;
        uint256 window = bound(windowHours, 1, period / 1 hours) * 1 hours;
        uint256 id = _create(AMOUNT, period, window, 5, 0);
        uint256 t0 = _start(id);
        t = bound(t, t0, t0 + 6 * period);
        vm.warp(t);
        _fresh();
        uint256 k = (t - t0) / period;
        bool inside = k < 5 && t <= t0 + k * period + window;
        (bool ok, uint256 pk,) = dca.nextExecution(id);
        assertEq(ok, inside);
        if (inside) {
            assertEq(pk, k);
            _exec(id);
            assertEq(_next(id), k + 1);
        } else {
            vm.expectRevert();
            _exec(id);
            assertEq(_next(id), 0);
        }
    }
}
