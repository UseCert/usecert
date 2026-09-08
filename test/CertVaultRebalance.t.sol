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
}
