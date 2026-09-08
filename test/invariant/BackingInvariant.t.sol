// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {VaultHandler} from "./VaultHandler.sol";
import {VaultFixture} from "../helpers/VaultFixture.sol";

/// @notice Task 12: proves under randomised call sequences the properties the whole design rests
///         on — Law 2 (redemption is never gated) and supply integrity — plus a third added for
///         the margin-split work: margin conservation. See foundry.toml's
///         [profile.default.invariant] for runs = 256, depth = 32, fail_on_revert = false.
///         fail_on_revert = false means VaultHandler itself is responsible for telling an
///         acceptable revert from a real violation; the fuzzer does not fail a run on a revert by
///         itself, so every invariant here checks a ground-truth counter the handler maintains,
///         never "did anything revert".
contract BackingInvariantTest is VaultFixture {
    VaultHandler handler;

    /// @dev VaultFixture.setUp() already builds the stack, seeds the buffer, bootstraps and
    ///      settles. Extend it, do not rebuild it.
    function setUp() public override {
        super.setUp();
        handler = new VaultHandler(vault, usdg, lighter);
        targetContract(address(handler));
    }

    /// @notice Law 2, expressed as an invariant: every non-zero redemption attempt the handler
    ///         made against certificates it actually held succeeded through SOME path (instant,
    ///         queued, or the force-exit backstop), including the queued path's final payout.
    function invariant_redemptionNeverBlockedByBuffer() public view {
        assertEq(handler.lawTwoViolations(), 0);
    }

    /// @notice Certificate supply always equals what this run minted minus what it burned — no
    ///         certificate appears or disappears off-ledger across mint/settleMint/redeem/queued
    ///         exits.
    function invariant_supplyMatchesMintedMinusBurned() public view {
        assertEq(cert.totalSupply(), handler.totalMinted() - handler.totalBurned());
    }

    /// @notice Margin conservation: the vault can never be carrying more margin (posted, plus
    ///         allocated but not yet swept back for recall) than it has ever actually deposited to
    ///         the venue. This is the accounting invariant that three rejected margin-recall
    ///         designs failed (see CertVault._queueExit's and recallMargin()'s doc comments).
    ///         marginPendingRecall underflowing is covered implicitly: every subtraction against
    ///         it is checked arithmetic, so an underflow there would revert the call that caused
    ///         it — surfacing as a lawTwoViolations increment on the redeem side, not silent
    ///         corruption.
    function invariant_marginNeverExceedsDeposited() public view {
        assertLe(vault.postedMargin() + vault.marginPendingRecall(), handler.totalDepositedToVenue());
    }

    /// @notice Capacity's own ceiling can never be reported above the immutable absolute cap, no
    ///         matter how open interest or the buffer moved during the run.
    function invariant_capacityNeverExceedsAbsoluteCap() public view {
        uint256 max = cap.maxNotional18(address(vault), type(uint256).max);
        assertLe(max, cap.absoluteCap18(address(vault)));
    }
}
