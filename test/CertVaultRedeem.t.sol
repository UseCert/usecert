// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {CertVault} from "../src/CertVault.sol";
import {VaultFixture} from "./helpers/VaultFixture.sol";

contract CertVaultRedeemTest is VaultFixture {
    function test_redeemInstantPaysOracklePriceMinusFee() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        uint256 bal = cert.balanceOf(alice);

        vm.prank(alice);
        uint256 out = vault.redeemInstant(bal);
        assertGt(out, 0);
        assertEq(cert.balanceOf(alice), 0);
    }

    /// Law 2: this is the test that matters most in the whole suite.
    function test_redeemSucceedsWithBufferAtZeroAndOracleStale() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        uint256 bal = cert.balanceOf(alice);

        // drain the buffer completely
        vm.prank(address(vault));
        book.accrue(address(vault), -type(int256).max / 2);
        // and break the oracle
        vm.warp(block.timestamp + 100_000);

        vm.prank(alice);
        uint256 id = vault.forceExit(bal);
        assertGt(id, 0);
        assertEq(cert.balanceOf(alice), 0);
    }

    function test_redeemIgnoresCapacityLimits() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        uint256 bal = cert.balanceOf(alice);

        // report the vault as massively over capacity
        vm.prank(attester);
        reg.attest(address(vault), 2, 10_000_000e18, 0, 1e18);

        vm.prank(alice);
        vault.redeemInstant(bal); // must not revert
        assertEq(cert.balanceOf(alice), 0);
    }

    function test_requestRedeemBurnsImmediatelyAndQueuesExit() public {
        vm.prank(alice);
        uint256 id0 = vault.requestMint(50_000e6);
        lighter.settleBatch();
        vault.settleMint(id0, PX);
        uint256 bal = cert.balanceOf(alice);

        vm.prank(alice);
        uint256 id = vault.requestRedeem(bal);

        assertEq(cert.balanceOf(alice), 0); // burned up front
        (,, uint64 enqueuedAt, uint64 expiresAt,) = vault.redeemReceipts(id);
        assertEq(expiresAt - enqueuedAt, 14 days); // PRIORITY_EXPIRATION
    }

    function test_claimRedeemPaysOnceWithdrawalLands() public {
        vm.prank(alice);
        uint256 id0 = vault.requestMint(50_000e6);
        lighter.settleBatch();
        vault.settleMint(id0, PX);

        // NOTE: `bal` must be read outside the prank — vm.prank affects only the very next
        // external call, and cert.balanceOf(alice) as an inline argument would consume it
        // before requestRedeem itself runs, leaving requestRedeem unpranked.
        uint256 bal = cert.balanceOf(alice);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(bal);
        lighter.settleBatch();

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.claimRedeem(id);
        assertGt(out, 0);
        assertEq(usdg.balanceOf(alice), before + out);
    }

    function test_claimTwiceReverts() public {
        vm.prank(alice);
        uint256 id0 = vault.requestMint(50_000e6);
        lighter.settleBatch();
        vault.settleMint(id0, PX);
        uint256 bal = cert.balanceOf(alice);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(bal);
        lighter.settleBatch();
        vm.prank(alice);
        vault.claimRedeem(id);

        vm.expectRevert(CertVault.CertVault_NothingToClaim.selector);
        vm.prank(alice);
        vault.claimRedeem(id);
    }

    function test_claimRedeemRejectsUnknownReceipt() public {
        vm.expectRevert(CertVault.CertVault_NothingToClaim.selector);
        vault.claimRedeem(999);
    }

    function test_claimRedeemIsCallableByAnyoneButPaysTheHolder() public {
        vm.prank(alice);
        uint256 id0 = vault.requestMint(50_000e6);
        lighter.settleBatch();
        vault.settleMint(id0, PX);

        uint256 bal = cert.balanceOf(alice);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(bal);
        lighter.settleBatch();

        uint256 before = usdg.balanceOf(alice);
        uint256 callerBefore = usdg.balanceOf(address(this));
        // called by the test contract itself, not alice
        uint256 out = vault.claimRedeem(id);
        assertGt(out, 0);
        assertEq(usdg.balanceOf(alice), before + out); // payout lands on the holder
        assertEq(usdg.balanceOf(address(this)), callerBefore); // caller receives nothing
    }

    function test_forceExitIsPermissionlessAndQueuesReduceOrder() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();
        uint256 bal = cert.balanceOf(alice);

        vm.prank(alice);
        vault.forceExit(bal);

        (,, , uint8 isAsk,) = lighter.lastOrder();
        assertEq(isAsk, 1); // selling to close
    }

    function test_closeAllUsesZeroBaseAmountPrimitive() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();

        vm.prank(gov);
        vault.closeAll();

        (, uint48 baseAmount,,,) = lighter.lastOrder();
        assertEq(baseAmount, 0); // 0 == "the entire position"
    }

    function test_closeAllRevertsForNonGovernance() public {
        vm.expectRevert(CertVault.CertVault_OnlyGovernance.selector);
        vm.prank(alice);
        vault.closeAll();
    }

    /// @notice M2 (final review wave): redeemInstant refuses when hotBuffer() < amountOut and
    ///         routes to the queued path, but claimRedeem performed no equivalent check — so a
    ///         queued claim could consume the very buffer that gate protects (making the gate
    ///         decorative) and a later receipt could effectively jump an earlier one when funds
    ///         were scarce. The new check is a retryable "not yet", NOT a gate: it reverts before
    ///         r.paid is set, so the receipt stays claimable forever, and every path that can
    ///         make the funds arrive (recallMargin, the sweep inside claimRedeem, seedBuffer) is
    ///         permissionless. Deliberately not FIFO — see claimRedeem's NatSpec.
    function test_claimRedeemRevertsRetryablyWhenUnderfunded() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();
        uint256 bal = cert.balanceOf(alice);

        vm.prank(alice);
        uint256 id = vault.forceExit(bal);
        (, uint256 owed18,,,) = vault.redeemReceipts(id);
        uint256 owed = owed18 / 1e12; // USDG has 6 decimals
        assertEq(owed, 3_551_486_358); // 9.99 certs at 355.86 less the 10 bps redeem fee

        _drainHotBuffer(); // drive the buffer below the owed amount
        assertLt(vault.hotBuffer(), owed);

        vm.prank(alice);
        vm.expectRevert(CertVault.CertVault_AwaitingSettlement.selector);
        vault.claimRedeem(id);

        (,,,, bool paid) = vault.redeemReceipts(id);
        assertFalse(paid, "an unpayable claim must not consume the receipt");

        // Now make the funds arrive through permissionless paths only — no owner, no keeper.
        lighter.settleBatch(); // the close fills at the venue
        vault.recallMargin(); // submits
        vault.recallMargin(); // sweeps
        assertGt(vault.hotBuffer(), 0);
        // The recall alone is short by exactly what the drain removed (the mint's retained share
        // plus fees), so top the buffer back up — seedBuffer is permissionless too.
        vault.seedBuffer(1_000e6);

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.claimRedeem(id); // the SAME receipt pays
        assertEq(out, owed);
        assertEq(usdg.balanceOf(alice), before + owed);
    }

    /// Law 2: forceExit must survive even when the closing hedge itself cannot be placed.
    /// Drive the feed to a price so extreme that CertOracle.toTickPrice() overflows uint32 —
    /// pxUnguarded() still returns it (fresh, so not stale) but _hedge would revert
    /// CertOracle_TickOverflow. forceExit must not revert: the burn and the receipt must stand,
    /// with CloseOrderNotPlaced recording that the close order itself was not placed.
    function test_forceExitSurvivesUnplaceableCloseOrder() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();
        uint256 bal = cert.balanceOf(alice);

        // priceDecimals is 2 in this fixture's oracle: tick = px18 * 100 / 1e18. Push px18 far
        // past the point where that overflows uint32 (~4.29e9), while keeping the feed fresh.
        vm.prank(attester);
        feed.set(int256(5e28), block.timestamp);

        vm.expectEmit(true, true, true, true, address(vault));
        emit CertVault.CloseOrderNotPlaced(bal);

        vm.prank(alice);
        uint256 id = vault.forceExit(bal);

        assertGt(id, 0);
        assertEq(cert.balanceOf(alice), 0); // burn still happened
        (address user,,,, bool paid) = vault.redeemReceipts(id);
        assertEq(user, alice); // receipt still exists
        assertFalse(paid);
    }

    /// CRITICAL B, and the Law 2 proof for it. `CertOracle._tryFeed` computed
    /// `block.timestamp - t` inside the SUCCESS block of `try feed.latestRoundData()`, which that
    /// try's own catch does not cover. A feed reporting an `updatedAt` in the FUTURE underflowed
    /// it and panicked (0x11) uncaught, straight through `pxUnguarded()` — documented never to
    /// revert — and through `_queueExit`, reverting `forceExit`, the protocol's last-resort
    /// backstop. Both the feed and the oracle are immutable, so a holder had no way out and the
    /// `lastGoodPx18` fallback that exists for precisely this case was unreachable.
    ///
    /// This is the end-to-end trace, deliberately on the two-phase mint path so real margin is
    /// posted and a real position is open when the feed breaks. LOAD-BEARING: reverting the
    /// `t > block.timestamp` guard in CertOracle._tryFeed fails this test with
    /// `panic: arithmetic underflow or overflow (0x11)`.
    function test_forceExitSurvivesFutureFeedTimestamp() public {
        vm.prank(alice);
        uint256 mintId = vault.requestMint(50_000e6);
        lighter.settleBatch();
        vault.settleMint(mintId, PX);

        uint256 bal = cert.balanceOf(alice);
        assertGt(bal, 0);
        assertGt(vault.postedMargin(), 0, "no real margin was posted");
        assertNotEq(lighter.positionBase(MARKET), int256(0), "no real position is open");

        // The feed reports one day into the future and freezes there. Note the price is also
        // moved, so if the guard let the live branch through, the exit would price off 999.99e18
        // rather than the last-good PX.
        feed.set(999_99000000, block.timestamp + 1 days);

        vm.prank(alice);
        uint256 id = vault.forceExit(bal); // must not revert, and must not panic

        assertEq(cert.balanceOf(alice), 0, "certificates were not burned");
        assertEq(cert.totalSupply(), 0);
        (address user, uint256 owed18,,, bool paid) = vault.redeemReceipts(id);
        assertEq(user, alice);
        assertFalse(paid);
        // Priced off last-good (PX), not off the malfunctioning feed's live value.
        uint256 expectedOwed18 = bal * PX / 1e18;
        expectedOwed18 -= expectedOwed18 * 10 / 10_000; // redeemFeeBps = 10
        assertEq(owed18, expectedOwed18, "the exit did not price off the last-good snapshot");
    }

    /// The third unguarded read on the Law 2 path, found by re-tracing forceExit end to end for
    /// CRITICAL B and fixed in the same commit. `_tryHedge` evaluated `lighterAccountIndex()` in
    /// ARGUMENT position inside its own `try lighter.createOrder(...)`, and argument evaluation
    /// runs before the protected call, so that try's catch never covered it. A venue whose
    /// `addressToAccountIndex` view reverts — paused behind a proxy, storage layout moved by an
    /// upgrade — therefore reverted `forceExit` outright, and `stageRefund` with it. Same class
    /// as the arithmetic-in-a-try's-success-block defect this commit fixes in CertOracle.
    ///
    /// LOAD-BEARING: with the read moved back into argument position, this test fails with
    /// `AccountIndexReadRefused()` propagating out of forceExit.
    function test_forceExitSurvivesAVenueThatRefusesTheAccountIndexRead() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();
        uint256 bal = cert.balanceOf(alice);
        int256 posBefore = lighter.positionBase(MARKET);

        // Only the vault's own account-index read is broken; every other venue call still works.
        vm.mockCallRevert(
            address(lighter),
            abi.encodeWithSignature("addressToAccountIndex(address)", address(vault)),
            abi.encodeWithSignature("AccountIndexReadRefused()")
        );

        vm.expectEmit(true, true, true, true, address(vault));
        emit CertVault.CloseOrderNotPlaced(bal);

        vm.prank(alice);
        uint256 id = vault.forceExit(bal); // must not revert

        assertEq(cert.balanceOf(alice), 0, "the burn did not happen");
        (address user,,,, bool paid) = vault.redeemReceipts(id);
        assertEq(user, alice);
        assertFalse(paid);
        // Fail-open means the close was skipped, not silently mis-submitted.
        vm.clearMockedCalls();
        lighter.settleBatch();
        assertEq(lighter.positionBase(MARKET), posBefore, "an order went in after all");
    }

    /// @notice H-2's Law 2 proof. claimRedeem now reads the oracle, to cap a queued payout at
    ///         what the certificates it burned are worth at claim time. That read sits in a
    ///         payout path, so it must be incapable of two things: blocking a claim, and valuing
    ///         a claim at nothing. Both are driven here, on two receipts of the same funded exit.
    ///
    ///         The first half mocks `pxUnguarded()` into reverting. CertOracle does not do that
    ///         today — CRITICAL B hardened its last uncaught arithmetic — but the vault must not
    ///         depend on that being permanently true, and the mock is the only way to prove the
    ///         try/catch is really there.
    ///
    ///         The second half returns a price of ZERO, which CertOracle genuinely can (an ok
    ///         feed whose answer normalises down to 0 at high decimals). Capping at zero would
    ///         pay a burned holder nothing at all, so zero must read as the absence of a price
    ///         and not as a valuation.
    ///
    ///         The third half is the one the re-trace found, and it is a real feed value rather
    ///         than a mock: an answer of 1e49 at the feed's 8 decimals is px18 = 1e59, which
    ///         _tryFeed's own overflow headroom check passes and returns live. Against a receipt
    ///         of ~10 certificates, `certIn * px18` then does not fit in uint256 — a 0x11 panic
    ///         INSIDE a payout, i.e. a receipt whose certificates are already burned and which
    ///         no longer pays. The cap must decline to compute rather than panic.
    ///
    /// @dev LOAD-BEARING: replace `_payout18`'s try/catch with a direct `oracle.pxUnguarded()`
    ///      call and the first claim reverts `OracleUnreadable()`; drop its `px18 == 0` guard and
    ///      the second claim pays 0 instead of the full owed amount; drop its
    ///      `px18 > type(uint256).max / certIn` guard and the third panics 0x11.
    function test_claimRedeemPaysInFullWhenTheOracleCannotPrice() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        uint256 third = cert.balanceOf(alice) / 3;

        vm.prank(alice);
        uint256 idA = vault.forceExit(third);
        vm.prank(alice);
        uint256 idB = vault.forceExit(third);
        // The remainder is read BEFORE the prank: vm.prank affects only the very next external
        // call, and cert.balanceOf() inline as an argument would consume it (the same gotcha
        // documented in test_sweepLargerThanOutstandingDoesNotUnderflow).
        uint256 rest = cert.balanceOf(alice);
        vm.prank(alice);
        uint256 idC = vault.forceExit(rest);
        (, uint256 owedA18,,,) = vault.redeemReceipts(idA);
        (, uint256 owedB18,,,) = vault.redeemReceipts(idB);
        (, uint256 owedC18,,,) = vault.redeemReceipts(idC);
        uint256 owedA = owedA18 / 1e12; // USDG has 6 decimals
        uint256 owedB = owedB18 / 1e12;
        uint256 owedC = owedC18 / 1e12;
        assertGt(owedA, 0);
        assertGt(owedB, 0);
        assertGt(owedC, 0);

        // 1. The oracle read itself reverts.
        vm.mockCallRevert(
            address(oracle), abi.encodeWithSignature("pxUnguarded()"), abi.encodeWithSignature("OracleUnreadable()")
        );
        uint256 beforeA = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 outA = vault.claimRedeem(idA);
        assertEq(outA, owedA, "an unreadable oracle shrank the payout");
        assertEq(usdg.balanceOf(alice), beforeA + owedA, "the holder was not paid in full");
        vm.clearMockedCalls();

        // 2. The oracle answers, with zero.
        vm.mockCall(
            address(oracle), abi.encodeWithSignature("pxUnguarded()"), abi.encode(uint256(0), block.timestamp)
        );
        uint256 beforeB = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 outB = vault.claimRedeem(idB);
        assertEq(outB, owedB, "a zero price was treated as a valuation of zero");
        assertEq(usdg.balanceOf(alice), beforeB + owedB, "the holder was not paid in full");
        vm.clearMockedCalls();

        // 3. A real, live feed value whose product with the receipt's quantity does not fit in
        //    uint256. No mock: this is what CertOracle actually returns for this answer.
        feed.set(int256(1e49), block.timestamp);
        (uint256 hugePx,) = oracle.pxUnguarded();
        assertEq(hugePx, 1e59, "the feed value did not reach the vault unclamped");
        assertGt(rest * (hugePx / 1e18), type(uint256).max / 1e18, "the product does not actually overflow");
        uint256 beforeC = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 outC = vault.claimRedeem(idC);
        assertEq(outC, owedC, "an unrepresentable valuation blocked or shrank the payout");
        assertEq(usdg.balanceOf(alice), beforeC + owedC, "the holder was not paid in full");
    }
}
