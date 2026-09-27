// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
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

    // ================================================================== H-2 / M-7 / H-4 delays

    bytes internal constant PUBKEY =
        hex"012258abd09aa219c49c168c88d3fdb0c4f1004757709ae2400824c2ed19534cb4e3e038864c6076";

    /// The venue key could be replaced in the block governance sent it. Now: proposed, public,
    /// applied no sooner than GOVERNANCE_DELAY later, once, and cancellable.
    function test_H2_venueApiKeyChangeWaitsTheDelayAppliesOnceAndCanBeCancelled() public {
        bytes memory data = abi.encodeCall(CertVault.setVenueApiKey, (uint8(3), PUBKEY));
        bytes32 id = keccak256(data);

        vm.prank(alice);
        vm.expectRevert(CertVault.CertVault_OnlyGovernance.selector);
        vault.proposeChange(data);

        uint256 t0 = block.timestamp;
        vm.expectEmit(true, false, false, true, address(vault));
        emit CertVault.ChangeProposed(id, t0 + vault.GOVERNANCE_DELAY(), data);
        vm.prank(gov);
        vault.proposeChange(data);

        vm.warp(t0 + vault.GOVERNANCE_DELAY() - 1);
        vm.prank(gov);
        vm.expectRevert(CertVault.CertVault_ChangeNotReady.selector);
        vault.setVenueApiKey(3, PUBKEY);
        // A different key than the one proposed is not the proposal.
        vm.warp(t0 + vault.GOVERNANCE_DELAY());
        vm.prank(gov);
        vm.expectRevert(CertVault.CertVault_ChangeNotReady.selector);
        vault.setVenueApiKey(4, PUBKEY);

        vm.prank(gov);
        vault.setVenueApiKey(3, PUBKEY);
        assertEq(lighter.apiKeyOf(vault.lighterAccountIndex(), 3), PUBKEY);
        // Consumed: it cannot be replayed.
        vm.prank(gov);
        vm.expectRevert(CertVault.CertVault_ChangeNotReady.selector);
        vault.setVenueApiKey(3, PUBKEY);

        // Cancelled proposals never apply.
        vm.prank(gov);
        vault.proposeChange(data);
        vm.prank(gov);
        vault.cancelChange(id);
        vm.warp(block.timestamp + vault.GOVERNANCE_DELAY());
        vm.prank(gov);
        vm.expectRevert(CertVault.CertVault_ChangeNotReady.selector);
        vault.setVenueApiKey(3, PUBKEY);
    }

    /// minBase was bounded only by uint48, so every close could be priced out. Now bounded in
    /// notional at the price when applied, and delayed like the key.
    function test_M7_venueMinBaseIsBoundedInNotionalAndDelayed() public {
        // 200 TSLA (~$71k): refused even after the delay.
        bytes memory tooBig = abi.encodeCall(CertVault.setVenueMinimums, (2_000_000, 0));
        vm.prank(gov);
        vault.proposeChange(tooBig);
        vm.warp(block.timestamp + vault.GOVERNANCE_DELAY());
        vm.prank(gov);
        vm.expectRevert(CertVault.CertVault_VenueMinimumOutOfBounds.selector);
        vault.setVenueMinimums(2_000_000, 0);

        // 2.8 TSLA (~$996) is inside the $1,000 ceiling.
        _setPrice(PX);
        _applyDelayed(vault, abi.encodeCall(CertVault.setVenueMinimums, (28_000, 10e18)));
        assertEq(vault.venueMinBase(), 28_000);
        assertEq(vault.venueMinNotional18(), 10e18);
        // Not without the delay.
        vm.prank(gov);
        vm.expectRevert(CertVault.CertVault_ChangeNotReady.selector);
        vault.setVenueMinimums(0, 0);
    }

    /// One attester key used to both attest and settle keeper-mode mints on its own word. Now
    /// settlement belongs to a separate settler, set through the delay; the attester keeps its
    /// attestations and funding relay.
    function test_H4_attesterCannotSettleKeeperMintsAndTheSettlerIsDelayed() public {
        vm.prank(gov);
        vault.enableKeeperHedging();
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);

        // No settler yet: nobody settles, and the receipt still refunds (a missing settler costs
        // time, not principal).
        vm.prank(attester);
        vm.expectRevert(CertVault.CertVault_OnlySettler.selector);
        vault.settleMint(id, PX);

        address keeper = makeAddr("keeper");
        bytes memory data = abi.encodeCall(CertVault.setSettler, (keeper));
        vm.prank(gov);
        vault.proposeChange(data);
        vm.prank(gov);
        vm.expectRevert(CertVault.CertVault_ChangeNotReady.selector);
        vault.setSettler(keeper);

        vm.warp(block.timestamp + SETTLE_WINDOW + 1);
        vault.stageRefund(id); // the refund path is untouched by the settler
        vm.warp(block.timestamp + vault.GOVERNANCE_DELAY());
        vm.prank(gov);
        vault.setSettler(keeper);
        assertEq(vault.settler(), keeper);

        _setPrice(PX);
        vm.startPrank(attester);
        reg.attest(address(vault), 2, 0, 0, 1_190_000e18);
        vault.accrueFunding(0); // the attester keeps the funding relay
        vm.stopPrank();
        vm.prank(alice);
        uint256 id2 = vault.requestMint(50_000e6);
        vm.prank(attester);
        vm.expectRevert(CertVault.CertVault_OnlySettler.selector);
        vault.settleMint(id2, PX);
        vm.prank(keeper);
        vault.settleMint(id2, PX);
        assertGt(cert.balanceOf(alice), 0);
        // and the settler is not an attester
        vm.prank(keeper);
        vm.expectRevert(CertVault.CertVault_OnlyAttester.selector);
        vault.accrueFunding(0);
    }

    // ================================================================== H-5 double close

    /// forceExit(X), then relay an attestation observed BEFORE the exit (its notional still
    /// includes X), then rebalance(): the vault used to sell X a second time. Refused now; an
    /// attestation observed after the exit plus the venue lag is acted on as before.
    function test_H5_anAttestationThatPredatesTheLastOrderCannotCloseTheHedgeAgain() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        lighter.settleBatch();
        vault.settleMint(id, PX);
        uint256 certs = cert.balanceOf(alice);
        uint256 fullNotional18 = certs * PX / 1e18;

        vm.warp(block.timestamp + 5 minutes);
        vm.prank(attester);
        reg.attest(address(vault), 2, fullNotional18, 0, 1_190_000e18); // observed now, pre-exit

        vm.warp(block.timestamp + 30);
        vm.prank(alice);
        vault.forceExit(certs / 2); // sells half on chain
        uint256 orders = lighter.queuedOrderCount();

        vm.expectRevert(CertVault.CertVault_AttestationPredatesLastOrder.selector);
        vault.rebalance();
        assertEq(lighter.queuedOrderCount(), orders, "the exit was closed twice");

        // Inside the lag, still refused.
        vm.warp(block.timestamp + vault.REBALANCE_VENUE_LAG());
        vm.prank(attester);
        reg.attest(address(vault), 3, fullNotional18, 0, 1_190_000e18);
        vm.expectRevert(CertVault.CertVault_AttestationPredatesLastOrder.selector);
        vault.rebalance();

        // Observed after the lag: an honest attestation of the half that is left is in band.
        lighter.settleBatch();
        vm.warp(block.timestamp + 1);
        vm.prank(attester);
        reg.attest(address(vault), 4, fullNotional18 - fullNotional18 / 2, 0, 1_190_000e18);
        vm.expectRevert(CertVault.CertVault_InBand.selector);
        vault.rebalance();
    }

    /// A compromised attester signing an inflated notional every batch used to be able to walk the
    /// hedge off in minutes. Now: one order per REBALANCE_MIN_INTERVAL, and at most
    /// REBALANCE_DAILY_BUDGET_18 in any rolling 24 hours, whatever it signs.
    function test_H5_aHostileAttesterCannotUnwindTheHedgeInMinutes() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(110_000e6);
        lighter.settleBatch();
        vault.settleMint(id, PX);
        lighter.settleBatch();
        uint256 supplyValue18 = cert.totalSupply() * PX / 1e18;

        uint64 batch = 2;
        uint256 moved18;
        uint256 t0 = block.timestamp;
        for (uint256 i = 0; i < 24 * 6; ++i) {
            // A fresh, inflated batch every 10 minutes: double what supply needs.
            vm.warp(t0 + (i + 1) * 10 minutes);
            vm.prank(attester);
            reg.attest(address(vault), batch++, 2 * supplyValue18, 0, 1_190_000e18);
            uint256 before = lighter.queuedOrderCount();
            try vault.rebalance() {
                (, uint48 base,,,) = lighter.lastOrder();
                moved18 += uint256(base) * PX / 1e4;
                // back-to-back, same information: refused
                vm.expectRevert(CertVault.CertVault_AlreadyRebalancedThisBatch.selector);
                vault.rebalance();
            } catch (bytes memory reason) {
                bytes4 sel = bytes4(reason);
                assertTrue(
                    sel == CertVault.CertVault_RebalanceTooSoon.selector
                        || sel == CertVault.CertVault_RebalanceBudgetSpent.selector
                        || sel == CertVault.CertVault_AttestationPredatesLastOrder.selector,
                    "rebalance stopped for an unexpected reason"
                );
                assertEq(lighter.queuedOrderCount(), before);
            }
            lighter.settleBatch();
        }
        emit log_named_decimal_uint("notional sold in 24h", moved18, 18);
        assertLe(moved18, vault.REBALANCE_DAILY_BUDGET_18() + 1e18, "the daily budget did not bind");
        assertLt(moved18, supplyValue18, "the hedge was unwound in a day");
        // It keeps converging, only slowly: the burst half of the budget was usable.
        assertGe(moved18, vault.REBALANCE_DAILY_BUDGET_18() / 2);
    }

    // ================================================================== M-6 close band

    /// A reduce-only close the venue kills is booked as done anyway, so a close must cross in a
    /// normal market: sells take CLOSE_PRICE_BAND_BPS, buys keep HEDGE_PRICE_BAND_BPS.
    function test_M6_closesAcceptAWiderBandThanOpens() public {
        vm.prank(alice);
        uint256 certs = vault.mintInstant(10_000e6); // not settled: the order is still queued
        (,, uint32 buyTick, uint8 isAskBuy,) = lighter.lastOrder();
        assertEq(isAskBuy, 0);
        assertEq(uint256(buyTick), PX * (10_000 + vault.HEDGE_PRICE_BAND_BPS()) / 10_000 * 100 / 1e18);

        lighter.settleBatch();
        vm.prank(alice);
        vault.forceExit(certs);
        (,, uint32 sellTick, uint8 isAsk,) = lighter.lastOrder();
        assertEq(isAsk, 1);
        assertEq(vault.CLOSE_PRICE_BAND_BPS(), 500);
        assertEq(uint256(sellTick), PX * (10_000 - vault.CLOSE_PRICE_BAND_BPS()) / 10_000 * 100 / 1e18);
    }

    // ================================================================== M-9 recall over-ask

    /// The books said 12.24 USDG while the venue held 2.06, and the venue refuses an over-sized
    /// withdrawal entirely. recallMargin() now never asks for more than the attested margin.
    function test_M9_recallIsCappedAtTheAttestedMargin() public {
        uint256 certs = _mintAlice(10_000e6);
        vm.prank(alice);
        vault.forceExit(certs);
        _drainHotBuffer();
        assertGt(vault.marginPendingRecall(), 2e6, "setup: the books ask for more than 2 USDG");

        vm.prank(attester);
        reg.attest(address(vault), 2, 0, 2e18, 1_190_000e18); // the venue holds 2 USDG

        vm.recordLogs();
        vault.recallMargin();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 asked;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == keccak256("MarginRecallRequested(uint256)")) {
                asked += abi.decode(logs[i].data, (uint256));
            }
        }
        assertEq(asked, 2e6, "the recall asked for more than the venue holds");
    }

    // ================================================================== M-10 orphan keeper hedge

    /// A keeper that opened a hedge and never settled leaves a position no ledger knows about.
    /// While the receipt is open its reservation keeps the pending hedge in `required`, so it is
    /// NOT trimmed; once staged, the orphan reads as over-hedge and rebalance() sells it - and the
    /// vault's ledger reaches flat rather than recording a short that does not exist.
    function test_M10_orphanKeeperHedgeIsTrimmedOnlyOnceTheReceiptIsAbandoned() public {
        vm.prank(gov);
        vault.enableKeeperHedging();
        vm.prank(alice);
        uint256 id = vault.requestMint(9_000e6);
        uint256 hedge18 = vault.pendingMintCerts() * PX / 1e18;

        // The keeper opened the hedge off chain; the attestation shows it; the receipt is open.
        _pastVenueLag();
        vm.prank(attester);
        reg.attest(address(vault), 2, hedge18, 0, 1_190_000e18);
        vm.expectRevert(CertVault.CertVault_InBand.selector);
        vault.rebalance();

        // The keeper never settles. Once the receipt is staged, the same position is an orphan.
        vm.warp(block.timestamp + SETTLE_WINDOW + 1);
        vault.stageRefund(id);
        vm.prank(attester);
        reg.attest(address(vault), 3, hedge18, 0, 1_190_000e18);
        assertEq(vault.venuePositionBase(), 0, "the orphan was never in the ledger");
        vault.rebalance();
        (, uint48 base,, uint8 isAsk,) = lighter.lastOrder();
        assertEq(isAsk, 1, "the orphan trim must be a reduce-only sell");
        assertGt(base, 0);
        assertEq(vault.venuePositionBase(), 0, "the ledger recorded a short that does not exist");
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
