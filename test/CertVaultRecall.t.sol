// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {CertVault} from "../src/CertVault.sol";
import {VaultFixture} from "./helpers/VaultFixture.sol";

/// @notice Task 8d: two-phase margin recall. Margin backing an open position is locked by the
///         venue's initial margin requirement and cannot be withdrawn until the closing order
///         fills in a batch — so _queueExit only allocates (postedMargin -> marginPendingRecall)
///         and the separate, permissionless, retryable recallMargin() is what actually withdraws,
///         reconciled only against getPendingBalance — the sole on-chain proof cash arrived.
contract CertVaultRecallTest is VaultFixture {
    /// @notice The exit must allocate, not submit: no withdrawal reaches Lighter at request time.
    function test_queueExitNoLongerSubmitsWithdraw() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();
        uint256 bal = cert.balanceOf(alice);
        uint256 postedBefore = vault.postedMargin();

        vm.prank(alice);
        vault.forceExit(bal);

        assertEq(lighter.getPendingBalance(address(vault), ASSET_IDX), 0);
        assertEq(vault.marginPendingRecall(), postedBefore);
        assertEq(vault.postedMargin(), 0);
    }

    /// @notice After the close fills, recallMargin() submits the withdrawal (no counter change —
    ///         submission is not arrival), and a later call sweeps what actually landed.
    function test_recallMarginSubmitsAndSweeps() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();
        uint256 bal = cert.balanceOf(alice);

        vm.prank(alice);
        vault.forceExit(bal);
        uint256 pendingRecall = vault.marginPendingRecall();
        assertGt(pendingRecall, 0);

        lighter.settleBatch(); // the close fills, freeing IMR at the venue

        uint256 vaultBalBefore = usdg.balanceOf(address(vault));

        vm.expectEmit(true, true, true, true, address(vault));
        emit CertVault.MarginRecallRequested(pendingRecall);
        vault.recallMargin(); // submits the withdrawal
        assertEq(vault.marginPendingRecall(), pendingRecall); // unchanged: submission != arrival

        lighter.settleBatch(); // models the second round trip; a no-op for the mock's withdraw path

        vm.expectEmit(true, true, true, true, address(vault));
        emit CertVault.MarginRecalled(pendingRecall, 0);
        vault.recallMargin(); // sweeps what landed

        assertEq(vault.marginPendingRecall(), 0);
        assertEq(usdg.balanceOf(address(vault)), vaultBalBefore + pendingRecall);
    }

    /// @notice The retryability proof for this task. A refused withdrawal must not revert the
    ///         caller and must not lose the counter; once the venue accepts, progress resumes.
    ///         Note the two-step shape even after the cap is restored: MockLighter.withdraw()
    ///         credits its pending balance synchronously (no batch delay for withdrawals, unlike
    ///         createOrder), but recallMargin() only sweeps pending balance it observes at the
    ///         START of a call — so the call that submits and the call that sweeps are distinct.
    function test_recallMarginIsRetryableAndFailOpen() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();
        uint256 bal = cert.balanceOf(alice);

        vm.prank(alice);
        vault.forceExit(bal);
        lighter.settleBatch(); // the close fills

        uint256 pendingRecall = vault.marginPendingRecall();
        assertGt(pendingRecall, 0);

        lighter.setDepositCapTicks(1); // the venue refuses any real withdrawal request
        vault.recallMargin(); // must not revert
        assertEq(vault.marginPendingRecall(), pendingRecall); // unchanged: refused, never lost

        lighter.setDepositCapTicks(type(uint64).max); // restore
        vault.recallMargin(); // submits successfully this time
        assertEq(vault.marginPendingRecall(), pendingRecall); // still unchanged: submission != arrival

        vault.recallMargin(); // a later call sweeps what the prior call landed
        assertLt(vault.marginPendingRecall(), pendingRecall); // progress
        assertEq(vault.marginPendingRecall(), 0);
    }

    /// @notice recallMargin() is deliberately not gated to holders or governance — anyone,
    ///         including a stranger holding no certificates, may call it.
    function test_recallMarginIsPermissionless() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();
        uint256 bal = cert.balanceOf(alice);

        vm.prank(alice);
        vault.forceExit(bal);
        lighter.settleBatch();

        uint256 pendingRecall = vault.marginPendingRecall();
        assertGt(pendingRecall, 0);

        address stranger = makeAddr("stranger");
        assertEq(cert.balanceOf(stranger), 0);

        vm.prank(stranger);
        vault.recallMargin(); // submits — callable by anyone

        vm.prank(stranger);
        vault.recallMargin(); // sweeps — the stranger's second call still lands the funds

        assertEq(vault.marginPendingRecall(), 0);
    }

    /// @notice Law 2 proof for this task: claimRedeem must remain payable from the vault's own
    ///         hot buffer even when the exit-allocated margin has never come home. Payment must
    ///         never be conditional on the sweep succeeding.
    function test_claimRedeemPaysFromHotBufferWhenMarginNeverArrives() public {
        vm.prank(alice);
        uint256 id0 = vault.requestMint(50_000e6);
        lighter.settleBatch();
        vault.settleMint(id0, PX);
        uint256 bal = cert.balanceOf(alice);

        vm.prank(alice);
        uint256 id = vault.requestRedeem(bal);
        lighter.settleBatch(); // the close fills, but recallMargin() is never called

        uint256 pendingRecall = vault.marginPendingRecall();
        assertGt(pendingRecall, 0);
        assertEq(lighter.getPendingBalance(address(vault), ASSET_IDX), 0); // nothing has arrived

        uint256 aliceBefore = usdg.balanceOf(alice);
        uint256 vaultBalBefore = usdg.balanceOf(address(vault));

        vm.prank(alice);
        uint256 out = vault.claimRedeem(id);

        assertGt(out, 0);
        assertEq(usdg.balanceOf(alice), aliceBefore + out); // paid in full despite margin never arriving
        assertEq(usdg.balanceOf(address(vault)), vaultBalBefore - out); // paid from the vault's own balance
        assertEq(vault.marginPendingRecall(), pendingRecall); // still outstanding — nothing to sweep
    }

    /// @notice A sweep larger than the outstanding recall (e.g. venue-credited funding landing in
    ///         the same pending balance) must floor marginPendingRecall at 0, not underflow.
    function test_sweepLargerThanOutstandingDoesNotUnderflow() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();
        uint256 bal = cert.balanceOf(alice);

        // Redeem only a quarter so marginPendingRecall is small relative to what remains posted.
        uint256 part = bal / 4;
        vm.prank(alice);
        vault.requestRedeem(part);

        uint256 pendingRecall = vault.marginPendingRecall();
        assertGt(pendingRecall, 0);

        // Model the venue crediting more to the vault's pending balance than is outstanding for
        // recall (e.g. funding) as the vault itself submitting a larger withdrawal directly.
        // NOTE: lighterAccountIndex() must be read BEFORE the prank — vm.prank affects only the
        // very next external call, and calling it inline as an argument here would consume the
        // prank on that view call, leaving lighter.withdraw() itself unpranked (same gotcha
        // documented in CertVaultRedeem.t.sol's test_claimRedeemPaysOnceWithdrawalLands).
        uint48 accountIndex = vault.lighterAccountIndex();
        uint256 oversized = pendingRecall * 3;
        vm.prank(address(vault));
        lighter.withdraw(accountIndex, ASSET_IDX, 0, uint64(oversized));
        assertEq(lighter.getPendingBalance(address(vault), ASSET_IDX), oversized);

        vault.recallMargin(); // sweeps `oversized`, more than marginPendingRecall

        assertEq(vault.marginPendingRecall(), 0); // floors at 0, does not revert
    }

    /// @notice Wind-down still recovers everything: closeAll() -> the position closes in a batch
    ///         -> recallMargin() succeeds once IMR frees the margin. Nothing is stranded.
    function test_windDownRecoversAllMargin() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();
        uint256 bal = cert.balanceOf(alice);

        vm.prank(alice);
        vault.forceExit(bal); // burns supply and allocates the full pro-rata share to recall

        uint256 pendingRecall = vault.marginPendingRecall();
        assertGt(pendingRecall, 0);
        uint256 vaultBalBefore = usdg.balanceOf(address(vault));

        vm.prank(gov);
        vault.closeAll(); // wind-down: guarantee the position is fully closed regardless

        lighter.settleBatch(); // the close fills, freeing IMR
        vault.recallMargin(); // submits the withdrawal
        lighter.settleBatch(); // second round trip
        vault.recallMargin(); // sweeps what landed

        assertEq(vault.marginPendingRecall(), 0);
        assertEq(usdg.balanceOf(address(vault)), vaultBalBefore + pendingRecall);
    }
}
