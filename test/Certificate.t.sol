// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Certificate} from "../src/Certificate.sol";

contract CertificateTest is Test {
    Certificate cert;
    address vault = makeAddr("vault");
    address alice = makeAddr("alice");

    function setUp() public {
        cert = new Certificate("UseCert TSLA", "uTSLA", vault);
    }

    function test_metadata() public view {
        assertEq(cert.name(), "UseCert TSLA");
        assertEq(cert.symbol(), "uTSLA");
        assertEq(cert.decimals(), 18);
        assertEq(cert.vault(), vault);
    }

    function test_vaultCanMintAndBurn() public {
        vm.prank(vault);
        cert.mint(alice, 5e18);
        assertEq(cert.balanceOf(alice), 5e18);

        vm.prank(vault);
        cert.burn(alice, 2e18);
        assertEq(cert.balanceOf(alice), 3e18);
        assertEq(cert.totalSupply(), 3e18);
    }

    function test_nonVaultCannotMint() public {
        vm.expectRevert(Certificate.Certificate_OnlyVault.selector);
        vm.prank(alice);
        cert.mint(alice, 1e18);
    }

    function test_nonVaultCannotBurn() public {
        vm.prank(vault);
        cert.mint(alice, 1e18);

        vm.expectRevert(Certificate.Certificate_OnlyVault.selector);
        vm.prank(alice);
        cert.burn(alice, 1e18);
    }

    function test_transfersAreUnrestricted() public {
        vm.prank(vault);
        cert.mint(alice, 1e18);
        vm.prank(alice);
        cert.transfer(makeAddr("bob"), 1e18);
        assertEq(cert.balanceOf(makeAddr("bob")), 1e18);
    }

    /// @notice L-3: a zero vault makes mint and burn permanently unreachable, so the certificate
    ///         could never be issued or redeemed.
    function test_constructorRejectsAZeroVault() public {
        vm.expectRevert(Certificate.Certificate_ZeroAddress.selector);
        new Certificate("UseCert TSLA", "uTSLA", address(0));
    }
}
