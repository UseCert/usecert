// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {VaultFixture} from "./helpers/VaultFixture.sol";
import {CertVault} from "../src/CertVault.sol";

/// @notice retire() / sweepRetired(): recovering the protocol's own capital from an EMPTY vault.
/// @dev Exists because two mainnet deployments left ~33 USDG in vaults nobody holds, with no way
///      out. The property that no owner can take collateral from under holders is kept: every test
///      below except the last two is a way retire() could hurt someone, and must refuse.
contract CertVaultRetireTest is VaultFixture {
    function _retire() internal {
        vm.prank(gov);
        vault.retire();
    }

    // ----------------------------------------------------------- it must refuse while anyone is in

    function test_retireRefusesWhileCertificatesExist() public {
        vm.prank(alice);
        vault.mintInstant(1_000e6);
        assertGt(cert.totalSupply(), 0);

        vm.expectRevert(CertVault.CertVault_NotEmpty.selector);
        vm.prank(gov);
        vault.retire();
    }

    /// The case no pre-existing counter covered: an escrow is owed from request until settle or
    /// refund, and stageRefund releases pendingMintCerts while the escrow is STILL owed.
    function test_retireRefusesWhileAMintEscrowIsOpen_evenAfterRefundIsStaged() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        assertEq(vault.openMintReceipts(), 1);

        vm.expectRevert(CertVault.CertVault_NotEmpty.selector);
        vm.prank(gov);
        vault.retire();

        vm.warp(block.timestamp + SETTLE_WINDOW + 1);
        vault.stageRefund(id);
        assertEq(vault.openMintReceipts(), 1, "a staged refund is still owed");

        vm.expectRevert(CertVault.CertVault_NotEmpty.selector);
        vm.prank(gov);
        vault.retire();
    }

    function test_settlingAndRefundingBothCloseTheReceipt() public {
        vm.prank(alice);
        uint256 a = vault.requestMint(50_000e6);
        vm.prank(alice);
        uint256 b = vault.requestMint(50_000e6);
        assertEq(vault.openMintReceipts(), 2);

        lighter.settleBatch();
        vault.settleMint(a, PX);
        assertEq(vault.openMintReceipts(), 1, "settle did not close the receipt");

        vm.warp(block.timestamp + SETTLE_WINDOW + 1);
        vault.stageRefund(b);
        lighter.settleBatch();
        vault.recallMargin();
        lighter.settleBatch();
        vault.refundMint(b);
        assertEq(vault.openMintReceipts(), 0, "refund did not close the receipt");
    }

    function test_retireRefusesWhileARedemptionIsOwed() public {
        vm.prank(alice);
        vault.mintInstant(1_000e6);
        uint256 certs = cert.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(certs);
        assertEq(cert.totalSupply(), 0, "setup: the redemption burned the certificates");
        assertGt(vault.totalOwedOutstanding(), 0, "setup: something is owed");

        vm.expectRevert(CertVault.CertVault_NotEmpty.selector);
        vm.prank(gov);
        vault.retire();
    }

    // ------------------------------------------------------------------------- access control

    function test_retireAndSweepAreGovernanceOnly_andSweepNeedsRetire() public {
        vm.expectRevert(CertVault.CertVault_OnlyGovernance.selector);
        vm.prank(alice);
        vault.retire();

        vm.expectRevert(CertVault.CertVault_NotRetired.selector);
        vm.prank(gov);
        vault.sweepRetired(0);

        _retire();
        vm.expectRevert(CertVault.CertVault_OnlyGovernance.selector);
        vm.prank(alice);
        vault.sweepRetired(0);
    }

    // ------------------------------------------------------------------ what it is for

    /// An empty vault: retire, then the capital comes back and no mint can ever happen again.
    function test_retireThenSweepReturnsTheCapitalAndBlocksMintsForever() public {
        uint256 held = usdg.balanceOf(address(vault));
        assertGt(held, 0, "setup: the fixture seeds a buffer");

        _retire();
        assertTrue(vault.retired());

        vm.expectRevert(CertVault.CertVault_Retired.selector);
        vm.prank(alice);
        vault.mintInstant(1_000e6);
        vm.expectRevert(CertVault.CertVault_Retired.selector);
        vm.prank(alice);
        vault.requestMint(50_000e6);

        uint256 govBefore = usdg.balanceOf(gov);
        vm.prank(gov);
        vault.sweepRetired(0);
        assertEq(usdg.balanceOf(gov) - govBefore, held, "capital not returned to governance");
        assertEq(usdg.balanceOf(address(vault)), 0);
    }

    /// The venue side: sweepRetired asks the venue for exactly the amount governance read off it.
    function test_sweepRetiredRecallsTheVenueBalanceItIsGiven() public {
        _retire();
        bytes32 topic = keccak256("MarginRecallRequested(uint256)");
        vm.recordLogs();
        vm.prank(gov);
        vault.sweepRetired(1e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == topic) {
                seen = true;
                assertEq(abi.decode(logs[i].data, (uint256)), 1e6);
            }
        }
        assertTrue(seen, "no venue withdrawal requested");
    }
}
