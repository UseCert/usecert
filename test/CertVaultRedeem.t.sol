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
}
