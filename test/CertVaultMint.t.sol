// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {CertVault} from "../src/CertVault.sol";
import {VaultFixture} from "./helpers/VaultFixture.sol";
import {SolvencyRegistry} from "../src/SolvencyRegistry.sol";

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

    /// @notice requestMint escrows and mints nothing; settleMint mints exactly the certificates
    ///         the hedge was sized for, and the fill price argument does not move that amount.
    /// @dev C-1 (external C1 audit) rewrote what this test asserts, and the old assertion is worth
    ///      recording because it was the defect written down as a requirement. It read
    ///      `assertLt(cert.balanceOf(alice), 139e18)` — i.e. it required the minted amount to be
    ///      `escrow / fillPx18`, 138.98 certificates at a fill 1% worse than the oracle, against a
    ///      hedge that had already gone in for 140.364100. fillPx18 is a caller-supplied argument
    ///      on a permissionless function, so that requirement is exactly the caller price
    ///      discretion C-1 is about: the same receipt minted anywhere in a settleBandBps-wide range
    ///      depending on who called first. settleMint now mints r.indicativeCerts and reconciles
    ///      the escrow remainder into BufferBook, so the assertion below is an equality and the
    ///      fill price is proven not to matter.
    function test_requestMintEscrowsAndSettlesAtActualFill() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        assertEq(cert.balanceOf(alice), 0);

        (, uint256 escrow,,,,, uint256 indicative) = vault.mintReceipts(id);
        assertEq(escrow, 49_950e6);
        // escrow / PX floored to the venue's own size granularity (sizeDecimals = 4)
        assertEq(indicative, 140_364_100_000_000_000_000);

        lighter.settleBatch();
        // filled 1% worse than oracle — in band, and irrelevant to the amount minted
        vault.settleMint(id, PX * 101 / 100);

        assertEq(cert.balanceOf(alice), indicative, "the fill price still moved the mint");
    }

    /// @notice The other side of the same fix: a fill 1% BETTER than the request price mints the
    ///         identical amount. Two settles that differ only in the caller's argument must not
    ///         produce two different supplies — that difference was worth $2,628.95 on a $50,000
    ///         mint at settleBandBps = 500.
    function test_settleMintAmountIsIndependentOfTheFillPriceArgument() public {
        vm.prank(alice);
        uint256 idLow = vault.requestMint(50_000e6);
        vm.prank(alice);
        uint256 idHigh = vault.requestMint(50_000e6);
        lighter.settleBatch();

        (,,,,,, uint256 indicative) = vault.mintReceipts(idLow);

        uint256 before = cert.balanceOf(alice);
        vault.settleMint(idLow, PX * 95 / 100); // the band floor
        uint256 mintedAtFloor = cert.balanceOf(alice) - before;

        before = cert.balanceOf(alice);
        vault.settleMint(idHigh, PX * 105 / 100); // the band ceiling
        uint256 mintedAtCeiling = cert.balanceOf(alice) - before;

        assertEq(mintedAtFloor, indicative);
        assertEq(mintedAtCeiling, indicative);
        assertEq(mintedAtFloor, mintedAtCeiling);
    }

    /// @notice C-1's escrow reconciliation. The remainder between the escrow and what
    ///         indicativeCerts cost at the request price is credited to BufferBook, never silently
    ///         retained. It is size-decimals dust — one venue tick of notional at most.
    function test_settleMintCreditsTheEscrowRemainderToTheBuffer() public {
        int256 bookBefore = book.balance18(address(vault));

        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        lighter.settleBatch();
        (, uint256 escrow,,,,, uint256 indicative) = vault.mintReceipts(id);

        vault.settleMint(id, PX);

        uint256 escrow18 = uint256(escrow) * 1e12;
        uint256 hedgeCost18 = indicative * PX / 1e18;
        assertGt(escrow18, hedgeCost18, "there should be a remainder to reconcile");
        assertEq(book.balance18(address(vault)) - bookBefore, int256(escrow18 - hedgeCost18));
        // Dust, not a windfall: below one tick of notional at PX with sizeDecimals = 4.
        assertLt(escrow18 - hedgeCost18, 1e14 * PX / 1e18);
    }

    /// @notice C-2, the cumulative half. The cap bounded one call and nothing bounded the sum,
    ///         because `current` came from an attestation that does not move between batches.
    ///         20 sequential mintInstant calls in one block minted $199,800 against a $119,000
    ///         cap — 1.68x. This is the directed proof the sum is now bounded.
    /// @dev test_A1_capacityCapIsPerCallNotCumulative in test/AuditPoC.t.sol is the auditor's
    ///      version of this and CANNOT be made green as written: it calls mintInstant 20 times
    ///      unguarded, so a cap that actually binds reverts the 12th call before the test reaches
    ///      its own assertion. The property it asserts does hold, and this test is what asserts it.
    function test_capacityIsCumulativeAcrossMintsInOneBlock() public {
        uint256 max = cap.maxNotional18(address(vault), book.capacity18(address(vault)));
        assertEq(max, 119_000e18);

        usdg.mint(alice, 1_000_000e6);
        uint256 admitted;
        vm.startPrank(alice);
        for (uint256 i = 0; i < 20; i++) {
            try vault.mintInstant(10_000e6) {
                admitted++;
            } catch (bytes memory reason) {
                assertEq(bytes4(reason), CertVault.CertVault_AtCapacity.selector, "refused for the wrong reason");
                break;
            }
        }
        vm.stopPrank();

        // The attestation never moved — the same untouched headroom the old check re-read.
        assertEq(cap.maxNotional18(address(vault), book.capacity18(address(vault))), max, "cap moved");
        assertEq(reg.latest(address(vault)).notional18, 0, "the attested notional moved after all");

        assertEq(admitted, 11, "the cap admitted the wrong number of mints");
        assertLe(cert.totalSupply() * PX / 1e18, max, "minted notional must respect maxNotional");
        // And it is a real bound, not an accidental one: a 12th mint of the same size is refused.
        vm.expectRevert(CertVault.CertVault_AtCapacity.selector);
        vm.prank(alice);
        vault.mintInstant(10_000e6);
    }

    /// @notice The queued path has to be bounded by the same counter, and for the same reason:
    ///         certificate.totalSupply() does not move at requestMint either, so without
    ///         pendingMintCerts a run of requestMint calls reproduces C-2 exactly.
    function test_capacityIsCumulativeAcrossQueuedMintRequests() public {
        usdg.mint(alice, 1_000_000e6);
        uint256 admitted;
        vm.startPrank(alice);
        for (uint256 i = 0; i < 10; i++) {
            try vault.requestMint(25_000e6) {
                admitted++;
            } catch (bytes memory reason) {
                assertEq(bytes4(reason), CertVault.CertVault_AtCapacity.selector, "refused for the wrong reason");
                break;
            }
        }
        vm.stopPrank();

        assertEq(cert.totalSupply(), 0, "requestMint must not mint");
        assertEq(admitted, 4, "the cap admitted the wrong number of requests");
        assertLe(vault.pendingMintCerts() * PX / 1e18, 119_000e18);
    }

    /// @notice A refund gives the reservation back, so capacity is not permanently consumed by a
    ///         request that never settled. stageRefund is permissionless, so anyone can free it.
    function test_stageRefundReleasesTheCapacityReservation() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        (,,,,,, uint256 indicative) = vault.mintReceipts(id);
        assertEq(vault.pendingMintCerts(), indicative);

        vm.warp(block.timestamp + SETTLE_WINDOW + 1);
        vm.prank(makeAddr("stagingStranger"));
        vault.stageRefund(id);

        assertEq(vault.pendingMintCerts(), 0, "the reservation outlived the promise");
    }

    /// @notice And a settle hands it over to supply rather than double-counting it.
    function test_settleMintHandsTheReservationOverToSupply() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        (,,,,,, uint256 indicative) = vault.mintReceipts(id);

        lighter.settleBatch();
        vault.settleMint(id, PX);

        assertEq(vault.pendingMintCerts(), 0);
        assertEq(cert.totalSupply(), indicative);
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
        lighter.settleBatch(); // TASK 6a: the venue executes the request in a batch, not inline
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

    // ---------------------------------------------------------------------------------------
    // M-5 (MEDIUM, external C1 audit), end to end. The finding is not that a setter was missing —
    // it is that the CONSEQUENCE of losing the attester key was terminal for the whole mint
    // pipeline: attestations stop, ageSec passes CapacityOracle.maxAttestationAgeSec, capacity
    // goes to zero permanently, and rebalance() dies with it because batchId stops advancing.
    // Redemption survives throughout (Law 2), which this test also asserts rather than assumes.
    //
    // The unit-level rotation mechanics live in SolvencyRegistry.t.sol and CertOracle.t.sol. This
    // one is the whole vault recovering.
    // ---------------------------------------------------------------------------------------

    /// @dev VaultFixture deploys `reg` and `oracle`, so this test contract is their rotation
    ///      authority (M-5 binds governance to msg.sender at construction). That is the deployment
    ///      rule, not a test convenience — see docs/DEPLOYMENT-CHECKLIST.md.
    function test_attesterRotationRepairsAVaultThatKeyLossHadBricked() public {
        address newAttester = makeAddr("newAttester");

        // A holder is in the vault before the key goes missing, so Law 2 has something to prove.
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();
        uint256 bal = cert.balanceOf(alice);
        assertGt(bal, 0);

        // ---- The key is lost. Nothing can attest, so the attestation ages out.
        vm.warp(block.timestamp + 10 days);
        feed.set(int256(PX / 1e10), block.timestamp); // isolate the failure: the FEED is still fine
        assertGt(reg.ageSec(address(vault)), 300, "the attestation was supposed to age out");
        assertEq(cap.maxNotional18(address(vault), vault.bufferCapacity18()), 0, "capacity did not die");

        // Minting is dead, and before M-5 it was dead forever.
        vm.expectRevert(CertVault.CertVault_AtCapacity.selector);
        vm.prank(alice);
        vault.mintInstant(1_000e6);

        // ---- LAW 2 HOLDS ANYWAY, and holds through the notice period below. The backstop needs no
        //      attestation, no capacity and no live attester.
        vm.prank(alice);
        vault.forceExit(bal / 2);
        assertEq(cert.balanceOf(alice), bal - bal / 2);

        // ---- Recovery. Governance proposes on both attested-data contracts; neither is instant.
        reg.proposeAttester(newAttester);
        oracle.proposeAttester(newAttester);
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_RotationNotDue.selector);
        reg.acceptAttester();

        vm.warp(block.timestamp + reg.ATTESTER_ROTATION_DELAY());
        feed.set(int256(PX / 1e10), block.timestamp);

        // Redemption still open during the window, before either rotation is installed. The
        // balance is read into a local first: an external call in argument position consumes the
        // prank, so vault.forceExit(cert.balanceOf(alice)) would run as this test contract.
        uint256 rest = cert.balanceOf(alice);
        vm.prank(alice);
        vault.forceExit(rest);
        assertEq(cert.balanceOf(alice), 0);

        // Permissionless finalisation (Law 6): a stranger closes both rotations out.
        address stranger = makeAddr("rotationStranger");
        vm.startPrank(stranger);
        reg.acceptAttester();
        oracle.acceptAttester();
        vm.stopPrank();
        assertEq(reg.attester(), newAttester);
        assertEq(oracle.attester(), newAttester);

        // ---- The pipeline is repaired, not replaced. The new key attests, capacity returns, and
        //      the vault mints again — on the SAME vault, with the same certificate.
        vm.startPrank(newAttester);
        oracle.setMarkPrice(PX);
        reg.attest(address(vault), 2, 0, 0, 1_190_000e18);
        vm.stopPrank();
        assertGt(cap.maxNotional18(address(vault), vault.bufferCapacity18()), 0, "capacity did not return");

        vm.prank(alice);
        uint256 out = vault.mintInstant(1_000e6);
        assertGt(out, 0, "the vault did not mint again");

        // And rebalance()'s batchId advances again, which is the other half of the finding.
        vm.prank(newAttester);
        reg.attest(address(vault), 3, 0, 0, 1_190_000e18);
        assertEq(vault.solvency().provenAtBatch, 3, "the batch id stopped advancing");
    }
}
