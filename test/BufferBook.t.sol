// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BufferBook} from "../src/BufferBook.sol";
import {CertVault} from "../src/CertVault.sol";
import {VaultFixture} from "./helpers/VaultFixture.sol";

contract BufferBookTest is Test {
    BufferBook book;
    address vault = makeAddr("vault");
    address asset = makeAddr("tsla");

    // floor 100k, feeOn 60k, mintSlow 30k, insuranceDraw 0, feeCap 200 bps
    function setUp() public {
        book = new BufferBook(vault, 200);
        vm.prank(vault);
        book.configure(asset, 100_000e18, 60_000e18, 30_000e18, 0);
    }

    function _fund(uint256 amt) internal {
        vm.prank(vault);
        book.accrue(asset, int256(amt));
    }

    function test_positiveFundingFattensBuffer() public {
        _fund(100_000e18);
        assertEq(book.balance18(asset), int256(100_000e18));
        assertEq(book.holdingFeeBps(asset), 0);
        assertFalse(book.mintSlowed(asset));
    }

    function test_healthyBufferChargesNoHoldingFee() public {
        _fund(80_000e18);
        assertEq(book.holdingFeeBps(asset), 0);
    }

    function test_crossingFeeOnActivatesCappedFee() public {
        _fund(50_000e18); // below feeOn 60k
        uint256 fee = book.holdingFeeBps(asset);
        assertGt(fee, 0);
        assertLe(fee, 200);
    }

    function test_feeIsCappedAtDeployBound() public {
        _fund(1e18); // almost empty
        assertEq(book.holdingFeeBps(asset), 200);
    }

    function test_feeRoundsToNearestNotUpwards() public {
        _fund(60_000e18 - 1); // exactly 1 wei shortfall
        assertEq(book.holdingFeeBps(asset), 0);
    }

    function test_crossingMintSlowFlagsIt() public {
        _fund(50_000e18);
        assertFalse(book.mintSlowed(asset));
        vm.prank(vault);
        book.accrue(asset, -25_000e18); // now 25k, below mintSlow 30k
        assertTrue(book.mintSlowed(asset));
    }

    function test_exhaustedBufferRequestsInsuranceDraw() public {
        _fund(10_000e18);
        vm.prank(vault);
        book.accrue(asset, -15_000e18); // negative
        assertLt(book.balance18(asset), 0);
        assertEq(book.insuranceDrawNeeded(asset), 5_000e18);
    }

    function test_capacityIsZeroWhenBufferNegative() public {
        _fund(10_000e18);
        vm.prank(vault);
        book.accrue(asset, -15_000e18);
        assertEq(book.capacity18(asset), 0);
    }

    function test_capacityScalesWithBuffer() public {
        _fund(100_000e18);
        assertGt(book.capacity18(asset), 0);
    }

    function test_onlyVaultMayAccrue() public {
        vm.expectRevert(BufferBook.BufferBook_OnlyVault.selector);
        book.accrue(asset, 1e18);
    }

    /// @notice L-6. `if (c.feeOn18 == 0) return 0;` used to sit between the two branches below and
    ///         was unreachable: with feeOn18 == 0 every possible balance is already answered by one
    ///         of them, so control never arrived at it and the division it was guarding was never
    ///         reached with a zero denominator. This is that argument as a test rather than as a
    ///         comment, so the removal cannot be undone by accident.
    function test_zeroFeeOnIsFullyCoveredByTheTwoBranchesAroundTheRemovedOne() public {
        vm.prank(vault);
        book.configure(asset, 0, 0, 0, 0);

        // balance == 0 == feeOn18: the first branch (b >= feeOn18) answers it.
        assertEq(book.balance18(asset), 0);
        assertEq(book.holdingFeeBps(asset), 0);

        // balance < 0: the second branch (b <= 0) answers it, at the cap.
        vm.prank(vault);
        book.accrue(asset, -1);
        assertEq(book.holdingFeeBps(asset), 200);
    }

    /// @notice M-2. The four thresholds are configuration now, and they are a descending ladder
    ///         that every reader in this contract assumes. A mis-ordered ladder is refused.
    function test_configureRefusesAMisorderedLadder() public {
        vm.startPrank(vault);

        vm.expectRevert(BufferBook.BufferBook_ThresholdsOutOfOrder.selector);
        book.configure(asset, 60_000e18, 100_000e18, 30_000e18, 0); // feeOn above floor

        vm.expectRevert(BufferBook.BufferBook_ThresholdsOutOfOrder.selector);
        book.configure(asset, 100_000e18, 30_000e18, 60_000e18, 0); // mintSlow above feeOn

        vm.expectRevert(BufferBook.BufferBook_ThresholdsOutOfOrder.selector);
        book.configure(asset, 100_000e18, 60_000e18, 30_000e18, 40_000e18); // draw above mintSlow

        // Equalities are a legitimate configuration: collapsing rungs is allowed.
        book.configure(asset, 1e18, 1e18, 1e18, 1e18);
        vm.stopPrank();
    }
}

/// @notice The vault-side half of M-1 and M-2: what the published buffer figure is, what the
///         capacity leg is derived from, and what buffer health does and does not do to a mint.
/// @dev Lives in this file rather than in CertVaultMint.t.sol because it is BufferBook's contract
///      with the vault that is under test here, and because the audit's own evidence files
///      (test/AuditPoC.t.sol, test/AttackSuite.t.sol) must not be touched.
contract BufferBookVaultTest is VaultFixture {
    /// @notice M-1(a) and M-1(b) together. The figure published as the buffer is collateral the
    ///         vault actually holds, it cannot drift from that under ordinary operation, and the
    ///         attester cannot declare it.
    /// @dev The auditor's version of this is test_A7_publishedBufferIsNotBackedByAnything. This one
    ///      also pins the accrual ledger's new home (accrual18), which A-7 does not look at, so a
    ///      "fix" that simply stopped publishing the ledger at all would fail here.
    function test_publishedBufferIsTheCollateralActuallyHeldAndTheLedgerIsPublishedSeparately() public {
        // Ordinary operation: a mint's fee in, an instant redemption out. Neither accrues.
        vm.startPrank(alice);
        vault.mintInstant(10_000e6);
        vault.redeemInstant(cert.balanceOf(alice));
        vm.stopPrank();

        CertVault.Solvency memory s = vault.solvency();
        assertEq(uint256(s.buffer18), vault.hotBuffer() * 1e12, "published buffer drifted from the balance");
        assertEq(s.accrual18, book.balance18(address(vault)), "the accrual ledger is not published");
        assertTrue(uint256(s.buffer18) != uint256(s.accrual18), "the two figures should have parted");

        // And the attester cannot move the published buffer, only the ledger it writes.
        int256 ledgerBefore = s.accrual18;
        vm.prank(attester);
        vault.accrueFunding(500_000_000e18);

        CertVault.Solvency memory after_ = vault.solvency();
        assertEq(uint256(after_.buffer18), vault.hotBuffer() * 1e12, "the attester moved the published buffer");
        assertEq(after_.buffer18, s.buffer18, "the published buffer moved at all");
        assertEq(after_.accrual18, ledgerBefore + 500_000_000e18, "the ledger did not record the relay");
    }

    /// @notice M-1. Admission control is bounded by collateral the vault really holds, so an
    ///         attester who declares a fat buffer cannot widen it.
    /// @dev Load-bearing shape: with the pre-fix leg (BufferBook.capacity18 handed over raw) the
    ///      declared ledger below claims 510,000,000 of capacity and the final mint is ADMITTED.
    function test_capacityIsBoundedByRealCollateralNotTheAttestersLedger() public {
        vm.prank(alice);
        vault.mintInstant(10_000e6); // real exposure, hedged out of real collateral

        _drainHotBuffer(); // the float is spent — the ledger does not notice, and never did

        vm.prank(attester);
        vault.accrueFunding(5_000_000e18); // and the attester declares a fat buffer

        assertGt(book.capacity18(address(vault)), 500_000_000e18, "the ledger did not claim what it claims");
        assertEq(vault.freeCollateral18(), 0, "the float is not actually drained");
        assertEq(vault.bufferCapacity18(), 0, "the declared ledger widened the real leg");

        // A mint whose own collateral cannot carry the exposure already outstanding is refused,
        // half a billion of declared buffer notwithstanding.
        vm.prank(alice);
        vm.expectRevert(CertVault.CertVault_AtCapacity.selector);
        vault.mintInstant(100e6);
    }

    /// @notice M-1, the other direction, kept on purpose: an EXHAUSTED ledger still shuts new
    ///         minting, and Law 2 still holds while it is shut.
    function test_anExhaustedLedgerStillShutsMintingButNeverAnExit() public {
        vm.prank(alice);
        vault.mintInstant(10_000e6);
        uint256 certs = cert.balanceOf(alice);

        vm.prank(attester);
        vault.accrueFunding(-200_000e18); // ledger deeply negative
        assertLt(book.balance18(address(vault)), 0);
        assertEq(vault.bufferCapacity18(), 0, "a negative ledger must tighten the leg to zero");
        assertGt(vault.freeCollateral18(), 0, "the vault does still hold collateral");

        vm.prank(alice);
        vm.expectRevert(CertVault.CertVault_AtCapacity.selector);
        vault.mintInstant(1_000e6);

        // Law 2: every exit stays open with the buffer reported as exhausted.
        vm.prank(alice);
        uint256 id = vault.forceExit(certs);
        assertGt(id, 0, "LAW 2: forceExit must issue a receipt with the buffer exhausted");
    }

    /// @notice M-2, as shipped. Crossing feeOn and mintSlow changes the published SIGNALS and
    ///         nothing else: no holding fee is charged and the instant cap does not taper. This is
    ///         the cliff the spec now describes, asserted rather than assumed.
    function test_crossingTheThresholdsChangesTheSignalsAndNotTheMint() public {
        vm.prank(alice);
        uint256 healthy = vault.mintInstant(1_000e6);
        assertEq(book.holdingFeeBps(address(vault)), 0, "precondition: no fee while healthy");
        assertFalse(book.mintSlowed(address(vault)), "precondition: not slowed while healthy");

        // Below mintSlow (30k) and therefore below feeOn (60k) too.
        vm.prank(attester);
        vault.accrueFunding(-75_000e18);
        assertGt(book.holdingFeeBps(address(vault)), 0, "the fee signal did not activate");
        assertTrue(book.mintSlowed(address(vault)), "the mint-slow signal did not activate");

        (,,,,,,, uint256 capBefore,,) = vault.cfg();
        vm.prank(alice);
        uint256 degraded = vault.mintInstant(1_000e6);

        assertEq(degraded, healthy, "a holding fee was charged after all, or the mint was slowed");
        (,,,,,,, uint256 capAfter,,) = vault.cfg();
        assertEq(capAfter, capBefore, "the instant cap tapered after all");
    }

    /// @notice M-2. The thresholds are retunable per asset, by governance only, and retuning them
    ///         cannot gate a mint (Law 6: this is a reporting parameter, not a lever).
    function test_thresholdsAreRetunablePerAssetAndGateNothing() public {
        vm.prank(alice);
        vm.expectRevert(CertVault.CertVault_OnlyGovernance.selector);
        vault.setBufferThresholds(1, 1, 1, 1);

        // A book ten times larger wants a ladder ten times higher.
        vm.prank(gov);
        vault.setBufferThresholds(1_000_000e18, 600_000e18, 300_000e18, 0);
        (uint256 floor18, uint256 feeOn18, uint256 mintSlow18,,) = book.config(address(vault));
        assertEq(floor18, 1_000_000e18);
        assertEq(feeOn18, 600_000e18);
        assertEq(mintSlow18, 300_000e18);

        // The vault is now far below every rung of its own ladder...
        assertTrue(book.mintSlowed(address(vault)));
        assertGt(book.holdingFeeBps(address(vault)), 0);
        // ...and minting is unaffected, because the thresholds gate nothing.
        vm.prank(alice);
        assertGt(vault.mintInstant(1_000e6), 0, "a threshold change gated a mint");

        vm.prank(gov);
        vm.expectRevert(BufferBook.BufferBook_ThresholdsOutOfOrder.selector);
        vault.setBufferThresholds(1e18, 2e18, 0, 0);
    }

    /// @notice L-3: a zero vault makes configure() and accrue() permanently unreachable, so the
    ///         ledger could never be written at all.
    function test_constructorRejectsAZeroVault() public {
        vm.expectRevert(BufferBook.BufferBook_ZeroAddress.selector);
        new BufferBook(address(0), 200);
    }
}
