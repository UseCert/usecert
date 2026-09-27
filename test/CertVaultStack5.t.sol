// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {VaultFixture} from "./helpers/VaultFixture.sol";
import {CertVault} from "../src/CertVault.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice Stack 5: one test per pre-audit finding fixed in CertVault, each asserting that the
///         attack in the finding no longer works (and, where the fix adds a wait or a refusal,
///         that it is bounded and that forceExit stays open - Law 2).
/// @dev Findings are from the internal pre-audit of 2026-09-27 (KNOWN-ISSUES). Every test name
///      carries its finding id.
contract CertVaultStack5Test is VaultFixture {
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        usdg.mint(bob, 1_000_000e6);
        vm.prank(bob);
        usdg.approve(address(vault), type(uint256).max);
    }

    function _owed(uint256 id) internal view returns (uint256) {
        (, uint256 owed18,,,) = vault.redeemReceipts(id);
        return owed18 / 1e12;
    }

    function _paid(uint256 id) internal view returns (bool p) {
        (,,,, p) = vault.redeemReceipts(id);
    }

    function _mintAlice(uint256 amount) internal returns (uint256 certs) {
        vm.prank(alice);
        certs = vault.mintInstant(amount);
        lighter.settleBatch();
    }

    // ================================================================== H-1 stale weekend price

    /// The weekend option: Friday's price is the last one the feed published, the perp has since
    /// fallen, and a holder redeems instantly at Friday's price. Refused; the queue stays open.
    function test_H1_redeemInstantRefusesAPriceOlderThanTheBound() public {
        uint256 certs = _mintAlice(10_000e6);

        // Exactly at the bound it is still instant.
        vm.warp(block.timestamp + vault.INSTANT_MAX_PRICE_AGE());
        vm.prank(alice);
        vault.redeemInstant(certs / 4);

        // One second past it, the same call is refused and names the reason.
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        vm.expectRevert(CertVault.CertVault_InstantPriceTooOld.selector);
        vault.redeemInstant(certs / 4);

        // Law 2: both queued doors are open at the same stale price.
        vm.prank(alice);
        uint256 q = vault.requestRedeem(certs / 4);
        vm.prank(alice);
        uint256 f = vault.forceExit(certs / 4);
        assertGt(q, 0);
        assertGt(f, 0);

        // A fresh price reopens the instant path.
        _setPrice(PX);
        uint256 rest = cert.balanceOf(alice);
        vm.prank(alice);
        assertGt(vault.redeemInstant(rest), 0);
    }

    /// The queued half of the same option: a receipt written at Friday's price must not be paid
    /// at it after the perp fell. The claim waits for a price observed after the request, and
    /// that price caps it.
    function test_H1_queuedClaimIsCappedOnlyByAPriceObservedAfterTheRequest() public {
        uint256 certs = _mintAlice(10_000e6);
        vm.warp(block.timestamp + 2 hours); // the feed has stopped; the last price is Friday's

        vm.prank(alice);
        uint256 id = vault.requestRedeem(certs);
        uint256 owed = _owed(id); // written at Friday's price

        // No price since the request: the claim waits, retryably.
        vm.prank(alice);
        vm.expectRevert(CertVault.CertVault_AwaitingFreshPrice.selector);
        vault.claimRedeem(id);
        assertFalse(_paid(id));

        // Monday: the feed prints 30% lower. The claim is capped at that value, not paid at Friday's.
        vm.warp(block.timestamp + 1 days);
        _setPrice(PX * 70 / 100);
        uint256 worthNow = certs * (PX * 70 / 100) / 1e18 / 1e12;
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = vault.claimRedeem(id);
        assertEq(paid, worthNow, "the claim was not capped at the post-request price");
        assertLt(paid, owed, "the holder was paid Friday's price");
        assertEq(usdg.balanceOf(alice) - before, paid);
        assertTrue(_paid(id));
        assertEq(vault.totalOwedOutstanding(), 0, "a capped close must retire its whole entry");
    }

    /// The wait is bounded: with no usable price at all, the claim pays owed18 uncapped at the
    /// timeout, and needs nobody to act.
    function test_H1_queuedClaimPaysUncappedAtTheTimeoutWithNoPriceEver() public {
        uint256 certs = _mintAlice(10_000e6);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(alice);
        uint256 id = vault.forceExit(certs);
        uint256 owed = _owed(id);

        vm.warp(block.timestamp + vault.QUEUED_PRICE_TIMEOUT() - 1);
        vm.prank(alice);
        vm.expectRevert(CertVault.CertVault_AwaitingFreshPrice.selector);
        vault.claimRedeem(id);

        vm.warp(block.timestamp + 1);
        // A stranger may make it: an uncapped payment cannot hurt the holder.
        uint256 before = usdg.balanceOf(alice);
        vm.prank(stranger);
        assertEq(vault.claimRedeem(id), owed);
        assertEq(usdg.balanceOf(alice) - before, owed);
        assertTrue(_paid(id));
    }

    // ================================================================== H-7 no loss path

    /// A shortfall used to land whole on whoever claimed last, and a claim paid all or nothing.
    /// Now it pays what is there, keeps the rest on the receipt, and pays the rest when it comes.
    function test_H7_claimPaysWhatIsThereAndKeepsTheRest() public {
        uint256 certs = _mintAlice(10_000e6);
        vm.prank(alice);
        uint256 id = vault.forceExit(certs);
        uint256 owed = _owed(id);

        // Leave only a third of the claim in the buffer.
        uint256 part = owed / 3;
        _drainAmount(vault.hotBuffer() - part);

        uint256 before = usdg.balanceOf(alice);
        vm.expectEmit(true, false, false, true, address(vault));
        emit CertVault.RedeemClaimOutstanding(id, owed - part);
        vm.prank(stranger); // uncapped instalments are anyone's to trigger
        assertEq(vault.claimRedeem(id), part);
        assertEq(usdg.balanceOf(alice) - before, part);
        assertFalse(_paid(id), "an instalment closed the receipt");
        assertEq(vault.redeemPaid(id), part);
        assertEq(vault.totalOwedOutstanding(), owed - part, "the instalment was not retired");

        // Nothing there: the retryable "not yet", and the receipt is untouched.
        vm.expectRevert(CertVault.CertVault_AwaitingSettlement.selector);
        vault.claimRedeem(id);

        // The rest arrives (recall, a seed or insurance); the same receipt pays it and closes.
        vault.seedBuffer(owed);
        assertEq(vault.claimRedeem(id), owed - part);
        assertTrue(_paid(id));
        assertEq(usdg.balanceOf(alice) - before, owed, "the holder was not made whole");
        assertEq(vault.totalOwedOutstanding(), 0);
    }

    /// redeemInstant used to check the gross buffer, so it could spend cash already recalled for
    /// a queued receipt. It is ring-fenced now.
    function test_H7_instantExitCannotSpendCashOwedToAQueuedReceipt() public {
        uint256 aCerts = _mintAlice(10_000e6);
        vm.prank(bob);
        uint256 bCerts = vault.mintInstant(10_000e6);
        vm.prank(alice);
        uint256 id = vault.forceExit(aCerts);
        uint256 owed = _owed(id);

        // The buffer holds exactly what alice is owed plus a little.
        _drainAmount(vault.hotBuffer() - owed - 100e6);
        uint256 small = bCerts / 10; // ~$355, more than the $100 that is nobody's
        vm.prank(bob);
        vm.expectRevert(CertVault.CertVault_UseQueuedRedeem.selector);
        vault.redeemInstant(small);

        // Alice's cash was not touched.
        vm.prank(alice);
        assertEq(vault.claimRedeem(id), owed);
    }

    /// ...nor spend the part of an open mint receipt's escrow that sits in the buffer, which a
    /// refund will need. The escrow's venue share is not held back: it was never in the buffer.
    function test_H7_instantExitCannotSpendAnOpenReceiptsEscrow() public {
        uint256 aCerts = _mintAlice(10_000e6);
        vm.prank(bob);
        vault.requestMint(50_000e6);
        uint256 held = vault.escrowOutstanding() - vault.escrowAtVenue();
        assertEq(held, 50_000e6 - 44_955e6, "held = the escrow's float plus its fee");

        _drainAmount(vault.hotBuffer() - held - 100e6);
        vm.prank(alice);
        vm.expectRevert(CertVault.CertVault_UseQueuedRedeem.selector);
        vault.redeemInstant(aCerts / 10);
        // Law 2: the queue is open.
        vm.prank(alice);
        vault.forceExit(aCerts / 10);
    }

    /// Refunds likewise must not spend cash owed to queued claims.
    function test_H7_refundCannotSpendCashOwedToAQueuedReceipt() public {
        uint256 aCerts = _mintAlice(10_000e6);
        vm.prank(bob);
        uint256 mintId = vault.requestMint(50_000e6);
        lighter.settleBatch();
        vm.warp(block.timestamp + SETTLE_WINDOW + 1);
        _setPrice(PX);
        vault.stageRefund(mintId);
        vm.prank(alice);
        uint256 id = vault.forceExit(aCerts);
        uint256 owed = _owed(id);

        // Enough for the refund alone, not for the refund AND alice.
        uint256 refund = 50_000e6;
        _drainAmount(vault.hotBuffer() - refund);
        vm.expectRevert(CertVault.CertVault_RefundAwaitingSettlement.selector);
        vault.refundMint(mintId);

        // Alice, who was owed first, is paid; the refund waits for the rest to arrive and then pays.
        vm.prank(alice);
        assertEq(vault.claimRedeem(id), owed);
        vault.seedBuffer(owed);
        uint256 before = usdg.balanceOf(bob);
        assertEq(vault.refundMint(mintId), refund);
        assertEq(usdg.balanceOf(bob) - before, refund);
    }

    // ================================================================== M-5 capacity

    /// A deposit used to vouch for itself: collateral was pulled before the capacity check, so an
    /// empty vault's "own capital" leg read the minter's own money. Measured before the pull now.
    function test_M5_aDepositCannotVouchForItself() public {
        _drainHotBuffer();
        assertEq(vault.freeCollateral18(), 0);
        vm.prank(alice);
        vm.expectRevert(CertVault.CertVault_AtCapacity.selector);
        vault.mintInstant(1_000e6);
        vm.prank(alice);
        vm.expectRevert(CertVault.CertVault_AtCapacity.selector);
        vault.requestMint(50_000e6);

        // Real capital restores it: 10 USDG of capital supports 1_000 of notional at 1% coverage.
        vault.seedBuffer(10e6);
        vm.prank(alice);
        vault.mintInstant(900e6);
    }

    /// Holders' float and open escrow are not the vault's capital either.
    function test_M5_freeCollateralExcludesFloatAndHeldEscrow() public {
        _mintAlice(10_000e6);
        vm.prank(bob);
        vault.requestMint(50_000e6);
        uint256 held = vault.escrowOutstanding() - vault.escrowAtVenue();
        uint256 own = vault.hotBuffer() - vault.retainedBacking() - held - vault.totalOwedOutstanding();
        assertEq(vault.freeCollateral18(), own * 1e12);
        assertEq(own, 99_999e6 + 10e6, "own capital = seed less bootstrap dust, plus the instant fee");
    }

    // ================================================================== M-12 queued fee

    /// The queued fee used to be counted at the request. On a capped claim it was never cash, and
    /// sweeping it took other holders' backing. It is accrued only on what is paid uncapped.
    function test_M12_aCappedClaimEarnsNoFeeAndAnUncappedOneEarnsItProRata() public {
        uint256 certs = _mintAlice(10_000e6);
        uint256 feesAfterMint = vault.feesAccrued();
        vm.prank(alice);
        uint256 capped = vault.forceExit(certs / 2);
        uint256 rest = cert.balanceOf(alice); // read BEFORE the prank, which the next call consumes
        vm.prank(alice);
        uint256 full = vault.forceExit(rest);
        assertEq(vault.feesAccrued(), feesAfterMint, "a fee was counted before it was earned");

        // Uncapped, in two instalments: the whole fee, pro rata, floored.
        uint256 owed = _owed(full);
        _drainAmount(vault.hotBuffer() - owed / 2);
        vault.claimRedeem(full);
        uint256 fee = vault.redeemFee(full);
        assertEq(vault.feesAccrued(), feesAfterMint + fee * (owed / 2) / owed);
        vault.seedBuffer(owed);
        vault.claimRedeem(full);
        assertApproxEqAbs(vault.feesAccrued(), feesAfterMint + fee, 1);

        // Capped: nothing.
        uint256 feesBefore = vault.feesAccrued();
        _setPrice(PX * 80 / 100);
        vm.prank(alice);
        vault.claimRedeem(capped);
        assertEq(vault.feesAccrued(), feesBefore, "a capped payout accrued a fee it never earned");
    }

    // ================================================================== L-10 refund keeps the fee

    function test_L10_refundReturnsTheFeeAndTheFeeWasNeverSweepable() public {
        address[] memory r = new address[](1);
        uint256[] memory s = new uint256[](1);
        (r[0], s[0]) = (makeAddr("treasury"), 10_000);
        FeeVault fv = new FeeVault(IERC20(address(usdg)), r, s);
        vm.prank(gov);
        vault.setFeeSink(address(fv));

        uint256 before = usdg.balanceOf(bob);
        vm.prank(bob);
        uint256 id = vault.requestMint(50_000e6);
        assertEq(vault.mintFee(id), 50e6);
        assertEq(vault.feesAccrued(), 0);
        assertEq(vault.sweepFees(), 0, "an unearned mint fee was swept");

        vm.warp(block.timestamp + SETTLE_WINDOW + 1);
        vault.stageRefund(id);
        lighter.settleBatch();
        vault.recallMargin();
        lighter.settleBatch();
        vault.recallMargin();
        assertEq(vault.refundMint(id), 50_000e6);
        assertEq(usdg.balanceOf(bob), before, "the refund kept the fee");
        assertEq(vault.feesAccrued(), 0);
        assertEq(vault.escrowOutstanding(), 0);
    }

    // ================================================================== L-11 stranger at a dip

    function test_L11_strangerCannotLockInADipDuringTheGracePeriod() public {
        uint256 certs = _mintAlice(10_000e6);
        vm.prank(alice);
        uint256 id = vault.forceExit(certs);
        _setPrice(PX * 70 / 100);

        vm.prank(stranger);
        vm.expectRevert(CertVault.CertVault_OwnerGracePeriod.selector);
        vault.claimRedeem(id);

        // After the grace period anyone may, at whatever the price then is.
        vm.warp(block.timestamp + vault.REDEEM_OWNER_GRACE());
        _setPrice(PX * 70 / 100);
        vm.prank(stranger);
        assertGt(vault.claimRedeem(id), 0);
        assertTrue(_paid(id));
    }

    function test_L11_ownerMayTakeACappedPayoutAtOnce() public {
        uint256 certs = _mintAlice(10_000e6);
        vm.prank(alice);
        uint256 id = vault.forceExit(certs);
        _setPrice(PX * 70 / 100);
        vm.prank(alice);
        assertEq(vault.claimRedeem(id), certs * (PX * 70 / 100) / 1e18 / 1e12);
    }
}
