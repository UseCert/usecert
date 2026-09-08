// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CertVault} from "../src/CertVault.sol";
import {VaultFixture} from "./helpers/VaultFixture.sol";

contract CertVaultRebalanceTest is VaultFixture {

    function test_solvencyReportsBackingWithProvenanceAndAge() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);

        vm.prank(attester);
        reg.attest(address(vault), 2, 3_554e18, 3_600e18, 1_190_000e18);
        vm.warp(block.timestamp + 45);

        CertVault.Solvency memory s = vault.solvency();
        assertEq(s.supply, cert.totalSupply());
        assertEq(s.notional18, 3_554e18);
        assertEq(s.margin18, 3_600e18);
        assertEq(s.provenAtBatch, 2);
        assertEq(s.ageSec, 45); // age is PUBLISHED, never hidden
    }

    function test_rebalanceRevertsWhenDeltaIsInBand() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();

        vm.prank(attester);
        reg.attest(address(vault), 2, 3_554e18, 3_600e18, 1_190_000e18);

        vm.expectRevert(CertVault.CertVault_InBand.selector);
        vault.rebalance();
    }

    function test_rebalanceTrimsDeltaWhenUnderHedged() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();

        // report only half the needed notional -> under-hedged, out of band
        vm.prank(attester);
        reg.attest(address(vault), 2, 1_777e18, 3_600e18, 1_190_000e18);

        vault.rebalance();
        assertEq(lighter.queuedOrderCount(), 1);
        (,,, uint8 isAsk,) = lighter.lastOrder();
        assertEq(isAsk, 0); // buy more to close the gap
    }

    function test_rebalanceIsPermissionless() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();
        vm.prank(attester);
        reg.attest(address(vault), 2, 1_777e18, 3_600e18, 1_190_000e18);

        vm.prank(makeAddr("stranger")); // a stranger
        vault.rebalance();
        assertEq(lighter.queuedOrderCount(), 1);
    }

    function test_rebalanceBoundsNotionalPerCall() public {
        // NOTE: the brief's sample used requestMint(500_000e6), but that produces a ~499,500e18
        // notional mint against a fixture CapacityOracle capped at openInterest(1_190_000e18) *
        // depthBps(1000) / 10_000 = 119_000e18 — it reverts CertVault_AtCapacity() before
        // rebalance() is ever reached. 50_000e6 (already used elsewhere in this suite for an
        // above-instant-cap mint) stays under that capacity limit while still leaving the vault
        // unhedged by far more than MAX_REBALANCE_NOTIONAL_18, so the cap is still what's tested.
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        lighter.settleBatch();
        vault.settleMint(id, PX);

        vm.prank(attester);
        reg.attest(address(vault), 2, 0, 600_000e18, 1_190_000e18); // fully unhedged

        vault.rebalance();
        (, uint48 baseAmount,,,) = lighter.lastOrder();
        // capped at maxRebalanceNotional18 (10k) -> 10000/355.86 = 28.1 TSLA -> 281_0xx ticks
        assertLt(baseAmount, 300_000);
    }

    // The brief's Interfaces section for accrueFunding ("permissionless relay into BufferBook;
    // reverts unless the caller is the attester") isn't covered by its own Step 1 sample test —
    // added here so the produced interface actually has coverage.

    function test_accrueFundingRelaysIntoBuffer() public {
        int256 before = book.balance18(address(vault));

        vm.prank(attester);
        vault.accrueFunding(-500e18);

        assertEq(book.balance18(address(vault)), before - 500e18);
    }

    function test_accrueFundingRevertsForNonAttester() public {
        vm.expectRevert(CertVault.CertVault_OnlyAttester.selector);
        vm.prank(alice);
        vault.accrueFunding(100e18);
    }

    // ---------------------------------------------------------------------
    // Task 10 review fixes: Finding 1 (CRITICAL) — baseAmount == 0 is Lighter's "close the
    // entire position" primitive (see ILighter.sol), not a no-op. It was reachable both by an
    // innocent rebalance() rounding its trim to zero (1a) and by anyone calling forceExit(0) /
    // requestRedeem(0) for free (1b). See CertVault_ZeroAmount, CertVault_ZeroHedgeAmount and the
    // CertVault_InBand check added to rebalance().
    // ---------------------------------------------------------------------

    /// Finding 1b: forceExit(0) must revert instead of forwarding baseAmount == 0 to Lighter and
    /// wiping the vault's entire hedge for free. This is the security proof for that guard.
    function test_forceExitZeroRevertsAndCannotWipeHedge() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();

        int256 posBefore = lighter.positionBase(MARKET);
        assertNotEq(posBefore, int256(0)); // sanity: there is a real hedge to protect

        // A stranger holding zero certificates — certificate.burn(msg.sender, 0) would succeed
        // trivially, so nothing but this guard stops them from reaching _tryHedge(0, ...).
        address stranger = makeAddr("zeroStranger");
        assertEq(cert.balanceOf(stranger), 0);

        vm.prank(stranger);
        vm.expectRevert(CertVault.CertVault_ZeroAmount.selector);
        vault.forceExit(0);

        lighter.settleBatch(); // nothing was queued by the reverted call
        assertEq(lighter.positionBase(MARKET), posBefore); // hedge is untouched

        // LOAD-BEARING CHECK (performed manually, not left in the committed suite; see
        // task-10-report.md's fix appendix for the full transcript):
        //  1. With ONLY _queueExit's `if (certIn == 0) revert CertVault_ZeroAmount();` removed,
        //     this test's vm.expectRevert fails as expected
        //     (`[FAIL: next call did not revert as expected]`) — but _tryHedge's own
        //     `if (baseAmount == 0) return false;` defence-in-depth still catches the zero:
        //     positionBase stayed at 99900 (unchanged), CloseOrderNotPlaced(0) fired instead.
        //  2. With BOTH that line AND _tryHedge's `if (baseAmount == 0) return false;` removed
        //     (reproducing the pre-fix state exactly), forceExit(0) from the zero-balance
        //     stranger drove `lighter.positionBase(MARKET)` from 99900 straight to 0 — the entire
        //     hedge wiped for the cost of one permissionless, zero-value call. Both lines were
        //     then restored and the full suite re-verified green.
    }

    /// Finding 1b: requestRedeem(0) shares _queueExit with forceExit(0) and must be rejected the
    /// same way.
    function test_requestRedeemZeroReverts() public {
        vm.expectRevert(CertVault.CertVault_ZeroAmount.selector);
        vm.prank(alice);
        vault.requestRedeem(0);
    }

    /// Finding 1a: drive outstanding supply down to a dust remainder so that the notional gap
    /// rebalance() would trim is worth only a fraction of a cent — small enough that, after the
    /// sizeDecimals conversion, it floors to baseAmount == 0. rebalance() must treat this as
    /// already in-band rather than ever submitting a zero-amount order.
    function test_rebalanceTreatsDustAsInBand() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();

        // Redeem almost everything away, leaving 1e13 wei of cert (0.00001 uTSLA) outstanding —
        // at PX = 355.86e18 and sizeDecimals = 4, the full notional this dust demands rounds to
        // less than one tradeable tick (see the exact math in the fix report).
        uint256 dust = 1e13;
        uint256 bal = cert.balanceOf(alice);
        vm.prank(alice);
        vault.redeemInstant(bal - dust);
        lighter.settleBatch();
        assertEq(cert.totalSupply(), dust);

        int256 posBefore = lighter.positionBase(MARKET);

        // Attest a matching low (zero) notional for the now-dust supply -> the vault reads as
        // fully unhedged in percentage terms, but the dollar gap is sub-tick.
        vm.prank(attester);
        reg.attest(address(vault), 2, 0, 100e18, 1_190_000e18);

        vm.expectRevert(CertVault.CertVault_InBand.selector);
        vault.rebalance();

        lighter.settleBatch(); // no-op: the reverted call queued nothing
        assertEq(lighter.positionBase(MARKET), posBefore); // not force-closed
    }

    // ---------------------------------------------------------------------
    // C2 (final review wave, CRITICAL): rebalance() bounded notional PER CALL
    // (MAX_REBALANCE_NOTIONAL_18) but nothing bounded calls per unit of information. It reads a
    // *stale* attestation, so the same gap is still there on the next call — a stranger made 25
    // calls in one block and pushed 250_000e18 of notional against a 119_000e18 ceiling.
    // rebalance() is the only function that moves position size without posting margin, so this
    // levers the vault for the price of gas. The fix ties it to attestation freshness: one
    // rebalance per new batchId. It stays permissionless (Law 6) — no access-control gate — and
    // the per-call bound finally means something, because a call can only ever act on data it
    // has not already acted on.
    // ---------------------------------------------------------------------

    /// @dev Puts the vault well out of band: a large mint's hedge is filled, then the attester
    ///      reports the position as fully unhedged, so the gap is ~50_000e18 against a
    ///      MAX_REBALANCE_NOTIONAL_18 of 10_000e18.
    function _driveLargeDelta(uint64 batchId) internal {
        vm.prank(attester);
        reg.attest(address(vault), batchId, 0, 600_000e18, 1_190_000e18);
    }

    function test_rebalanceCannotBeSpammedWithinOneBatch() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        lighter.settleBatch();
        vault.settleMint(id, PX);
        _driveLargeDelta(2);

        int256 posBefore = lighter.positionBase(MARKET);
        address stranger = makeAddr("rebalanceSpammer");

        // 25 calls in one block, exactly the griefing sequence the review measured.
        vm.startPrank(stranger);
        vault.rebalance(); // the first one acts on batch 2
        for (uint256 i = 0; i < 24; ++i) {
            vm.expectRevert(CertVault.CertVault_AlreadyRebalancedThisBatch.selector);
            vault.rebalance();
        }
        vm.stopPrank();

        assertEq(lighter.queuedOrderCount(), 1, "more than one rebalance order was queued");
        assertEq(vault.lastRebalancedBatch(), 2);

        // Total notional actually moved across all 25 attempts must stay inside the per-call
        // bound — which is the property the per-call bound was always supposed to deliver.
        lighter.settleBatch();
        int256 moved = lighter.positionBase(MARKET) - posBefore;
        assertGt(moved, 0);
        uint256 movedNotional18 = uint256(moved) * PX / (10 ** 4); // sizeDecimals = 4
        assertLe(movedNotional18, vault.MAX_REBALANCE_NOTIONAL_18());

        // Fresh information re-opens it: still permissionless, still bounded per call.
        _driveLargeDelta(3);
        vm.prank(stranger);
        vault.rebalance();
        assertEq(lighter.queuedOrderCount(), 1);
        assertEq(vault.lastRebalancedBatch(), 3);
    }

    /// @notice The freshness gate must not become a Law 6 access gate: a stranger is still the
    ///         one who may act, and a reverted attempt must not consume the batch for everyone.
    function test_inBandRebalanceDoesNotConsumeTheBatch() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();

        // In band -> reverts InBand, which rolls back lastRebalancedBatch.
        vm.prank(attester);
        reg.attest(address(vault), 2, 3_554e18, 3_600e18, 1_190_000e18);
        vm.expectRevert(CertVault.CertVault_InBand.selector);
        vault.rebalance();
        assertEq(vault.lastRebalancedBatch(), 0, "a reverted attempt consumed the batch");

        // Same batch, now genuinely out of band: a real trim must still be possible.
        vm.prank(attester);
        reg.attest(address(vault), 3, 1_777e18, 3_600e18, 1_190_000e18);
        vm.prank(makeAddr("anyone"));
        vault.rebalance();
        assertEq(lighter.queuedOrderCount(), 1);
    }

    /// @notice CRITICAL A follow-on, so the new branch is not dead. `_solvency`'s `required` is
    ///         `supply * px18 / 1e18`, so a px18 of 0 makes it 0 even with supply outstanding.
    ///         Before CRITICAL A that state reported deltaBps == 10_000 and rebalance() stopped at
    ///         CertVault_InBand, which incidentally hid the fact that `certEquivalent`'s division
    ///         by px18 was below it. Now that a zero `required` with a non-zero attested notional
    ///         is out of band, that division is genuinely reachable — so it gets a named error
    ///         rather than an anonymous panic in a permissionless entry point.
    /// @dev A px18 of 0 with ok == true is real, not contrived: a 19-decimal feed reporting
    ///      answer = 1 normalises to 1 / 10 == 0, which is what
    ///      CertOracle.test_mintAllowedFalseWhenFeedTruncatesToZero already pins.
    ///      LOAD-BEARING: without the px18 guard this test fails with
    ///      `panic: division or modulo by zero (0x12)` instead of CertVault_NoPrice.
    function test_rebalanceRevertsNamedErrorWhenThePriceIsZero() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();

        feed.setDecimals(19);
        feed.set(1, block.timestamp);
        (uint256 px18,) = oracle.pxUnguarded();
        assertEq(px18, 0, "the feed did not actually truncate to zero");

        vm.prank(attester);
        reg.attest(address(vault), 2, 3_554e18, 3_600e18, 1_190_000e18);
        assertEq(vault.solvency().deltaBps, vault.DELTA_UNBOUNDED_BPS(), "a zero price is not a hedged vault");

        vm.expectRevert(CertVault.CertVault_NoPrice.selector);
        vault.rebalance();
    }

    /// The guards above must not break closeAll(), the one legitimate caller of Lighter's
    /// baseAmount == 0 primitive.
    function test_closeAllStillClosesEverything() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();
        assertNotEq(lighter.positionBase(MARKET), int256(0)); // sanity: a position exists to close

        vm.prank(gov);
        vault.closeAll();
        lighter.settleBatch();

        assertEq(lighter.positionBase(MARKET), 0);
    }
}
