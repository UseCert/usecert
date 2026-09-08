// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ISolvencyRegistry} from "./interfaces/ISolvencyRegistry.sol";

/// @notice Per-batch attested backing for each vault's Lighter account.
/// @dev C1 (route A): a single attester posts figures reconstructed from Lighter's on-chain
///      blob data, and anyone can independently rebuild the tree and check them. The claim is
///      "independently verifiable", NOT "verified on-chain" — do not overstate it.
///      C2 (route B) replaces the attester with a Poseidon2 proof check inside attest(); the
///      Attestation struct and both view functions stay identical so consumers never change.
contract SolvencyRegistry is ISolvencyRegistry {
    error SolvencyRegistry_OnlyAttester();
    error SolvencyRegistry_StaleBatch();
    /// @dev M-5: only the rotation authority bound at deploy may propose a new attester.
    error SolvencyRegistry_OnlyGovernance();
    /// @dev L-3, and M-5's own hard floor: an attester of address(0) is unrecoverable, since
    ///      nothing could ever attest again and rotation itself would be the only way back. Never
    ///      constructible and never installable.
    error SolvencyRegistry_ZeroAddress();
    error SolvencyRegistry_NoPendingAttester();
    error SolvencyRegistry_RotationNotDue();

    event Attested(address indexed asset, uint64 batchId, uint256 notional18, uint256 margin18, uint256 openInterest18);
    /// @dev M-5 (Law 3): a rotation is a public commitment with a published effective time, not a
    ///      silent swap. This is the whole protection, so it has to be observable.
    event AttesterRotationProposed(address indexed attester, uint256 effectiveAt);
    event AttesterRotated(address indexed previous, address indexed attester);

    /// @notice The immutable notice period every attester rotation must serve. Cannot be shortened,
    ///         waived, or configured — by governance or by anyone else.
    /// @dev M-5 (MEDIUM, external C1 audit). THE CEILING, and what it deliberately does and does
    ///      not constrain.
    ///
    ///      The finding: every privileged address was immutable with no rotation, so losing the
    ///      attester key was TERMINAL for minting — attestations stop, ageSec passes
    ///      CapacityOracle.maxAttestationAgeSec, capacity goes to zero permanently, and rebalance()
    ///      dies with it because batchId stops advancing. Redemption survives (Law 2 does not read
    ///      this contract for any gate) but the vault could only be replaced, never repaired.
    ///      Unrecoverable key loss is not a design goal.
    ///
    ///      The risk rotation ADDS is not the same as the risk it removes: governance compromise
    ///      now also yields attester powers. So the lever needs an immutable bound, in the spirit
    ///      of CapacityOracle.maxAbsoluteCap — and a bound on SPEED is the right one, because speed
    ///      is the only dimension a rotation has. What a newly installed attester could then DO is
    ///      already ceiling-bounded elsewhere and does not need bounding again here:
    ///        - inflated openInterest18 cannot widen minting past
    ///          min(absoluteCap18, 100 * CertVault.freeCollateral18()), and absoluteCap18 is itself
    ///          bounded by the immutable maxAbsoluteCap (M-4) while the buffer leg is derived from
    ///          collateral the vault actually holds (M-1);
    ///        - the accrual ledger sits under a `min` and can only ever make the vault MORE
    ///          conservative (M-1);
    ///        - no redemption path reads an attestation at all (Law 2).
    ///      And governance already holds an INSTANT lever against a misbehaving attester —
    ///      setAbsoluteCap(asset, 0) shuts new minting in one transaction — so the delay costs
    ///      nothing operationally in the emergency case. It buys the thing an instant swap cannot:
    ///      a published, unskippable window in which holders can see the rotation coming and exit
    ///      (forceExit needs no attestation, no oracle and no counterparty).
    ///
    ///      A CONSTANT rather than a per-deployment immutable, which is stronger than the
    ///      maxAbsoluteCap shape rather than weaker: there is nothing here for a deployer to tune
    ///      DOWN to zero and thereby recreate the instant rotation this bound exists to prevent.
    ///
    ///      Governance itself stays immutable. Rotating governance needs a governance framework
    ///      (queue, delay, cancel, executor) and that is a C2 concern, exactly as
    ///      CapacityOracle.maxAbsoluteCap's own NatSpec argues about timelocks.
    uint256 public constant ATTESTER_ROTATION_DELAY = 2 days;

    /// @notice The rotation authority. Immutable, and bound to the deployer at construction.
    /// @dev M-5: taken from msg.sender rather than from a constructor parameter, and that is a
    ///      deliberate constraint of this pass rather than a preference. This contract's
    ///      `constructor(address _attester)` signature is depended on verbatim by the external
    ///      audit's own evidence files (test/AttackSuite.t.sol), which must not be edited, so the
    ///      arity is frozen. DEPLOYMENT REQUIREMENT, recorded in docs/DEPLOYMENT-CHECKLIST.md:
    ///      deploy this contract DIRECTLY FROM the governance multisig, never from a script
    ///      contract or a factory, or the rotation authority lands on an address nobody controls
    ///      and the key loss M-5 fixes becomes terminal again. An explicit `_governance` parameter
    ///      is the C2 cleanup.
    address public immutable governance;

    /// @notice Who may post attestations. No longer immutable — see ATTESTER_ROTATION_DELAY.
    address public attester;
    /// @notice The proposed next attester, and the timestamp from which it may be installed.
    /// @dev Zero means no rotation is pending. A proposal is corrected by proposing again, which
    ///      overwrites it and RESTARTS the notice period; proposing the incumbent is how a rotation
    ///      is abandoned. There is deliberately no separate cancel function — one fewer governance
    ///      entry point, and no way to cancel a proposal that has already come due.
    address public pendingAttester;
    uint256 public pendingAttesterAt;

    mapping(address => Attestation) private _latest;

    constructor(address _attester) {
        // L-3: no constructor in src/ validated its dependencies, so a mistyped address deployed
        // silently and failed later at an arbitrary call site.
        if (_attester == address(0)) revert SolvencyRegistry_ZeroAddress();
        attester = _attester;
        governance = msg.sender;
    }

    /// @notice Start an attester rotation. Governance-gated, and it takes effect no sooner than
    ///         ATTESTER_ROTATION_DELAY from now.
    /// @dev M-5: a role change, NOT a trading power (Law 6). This cannot move collateral, cannot
    ///      place an order, cannot pause anything, and cannot touch a redemption path — the
    ///      attester it installs may only write the per-batch attestation, under the ceilings
    ///      described on ATTESTER_ROTATION_DELAY.
    function proposeAttester(address next) external {
        if (msg.sender != governance) revert SolvencyRegistry_OnlyGovernance();
        if (next == address(0)) revert SolvencyRegistry_ZeroAddress();
        pendingAttester = next;
        pendingAttesterAt = block.timestamp + ATTESTER_ROTATION_DELAY;
        emit AttesterRotationProposed(next, pendingAttesterAt);
    }

    /// @notice Install a rotation whose notice period has elapsed. Permissionless (Law 6).
    /// @dev Anyone may finalise, deliberately: once the window has been served the rotation is a
    ///      commitment that has already been public for ATTESTER_ROTATION_DELAY, and requiring
    ///      governance to act a second time would let a lost or stalled governance key strand a
    ///      recovery that the protocol has already been told is coming.
    function acceptAttester() external {
        address next = pendingAttester;
        if (next == address(0)) revert SolvencyRegistry_NoPendingAttester();
        if (block.timestamp < pendingAttesterAt) revert SolvencyRegistry_RotationNotDue();

        address previous = attester;
        attester = next;
        pendingAttester = address(0);
        pendingAttesterAt = 0;
        emit AttesterRotated(previous, next);
    }

    function attest(address asset, uint64 batchId, uint256 notional18, uint256 margin18, uint256 openInterest18)
        external
    {
        if (msg.sender != attester) revert SolvencyRegistry_OnlyAttester();
        if (batchId <= _latest[asset].batchId) revert SolvencyRegistry_StaleBatch();

        _latest[asset] = Attestation({
            notional18: notional18,
            margin18: margin18,
            openInterest18: openInterest18,
            batchId: batchId,
            attestedAt: uint64(block.timestamp)
        });

        emit Attested(asset, batchId, notional18, margin18, openInterest18);
    }

    function latest(address asset) external view returns (Attestation memory) {
        return _latest[asset];
    }

    /// @notice Age of the newest attestation. Returns max for never-attested assets so callers
    ///         treating "old" as unsafe are correct by default.
    function ageSec(address asset) external view returns (uint256) {
        uint64 t = _latest[asset].attestedAt;
        if (t == 0) return type(uint256).max;
        return block.timestamp - t;
    }
}
