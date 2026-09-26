// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ISolvencyRegistry} from "./interfaces/ISolvencyRegistry.sol";
import {ECDSA} from "openzeppelin-contracts/utils/cryptography/ECDSA.sol";

/// @notice Per-batch attested backing for each vault's Lighter account.
/// @dev C1 (route A): a single attester posts figures reconstructed from Lighter's on-chain
///      blob data, and anyone can independently rebuild the tree and check them. The claim is
///      "independently verifiable", NOT "verified on-chain" — do not overstate it.
///      C2 (route B) replaces the attester with a Poseidon2 proof check inside attest(); the
///      Attestation struct and both view functions stay identical so consumers never change.
contract SolvencyRegistry is ISolvencyRegistry {
    error SolvencyRegistry_OnlyAttester();
    error SolvencyRegistry_StaleBatch();
    /// @dev The signed-attestation path. Each of these exists because the signature moves WHO pays
    ///      gas from the attester to the minter, and with it the assumption that observation and
    ///      settlement happen in the same instant. See attestSigned.
    error SolvencyRegistry_SignatureExpired();
    error SolvencyRegistry_BadSignature();
    error SolvencyRegistry_ObservationInFuture();
    error SolvencyRegistry_ObservationWentBackwards();
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

    /// @dev EIP-712 domain, built here rather than inherited from OpenZeppelin's EIP712. That base
    ///      reaches ShortStrings, which compiles to `mcopy` — a Cancun opcode — and this project
    ///      targets `shanghai`. Raising evm_version to pull in one helper would change the
    ///      compilation target of every audited contract in src/, which is not a trade worth making
    ///      for a domain separator that is ten lines of standard, unchanging code.
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _NAME_HASH = keccak256("UseCert SolvencyRegistry");
    bytes32 private constant _VERSION_HASH = keccak256("1");

    /// @notice The EIP-712 domain separator for this contract on this chain.
    /// @dev Computed per call rather than cached at construction. Caching is the usual gas
    ///      optimisation and it is wrong here: a cached separator keeps the chainId of the chain the
    ///      contract was DEPLOYED on, so after a fork every signature stays valid on both sides.
    ///      Recomputing costs a few hundred gas and makes a signature belong to exactly one chain.
    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));
    }

    function _hashTypedData(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    /// @notice EIP-712 type of a signed attestation. `observedAt` is part of the signed payload
    ///         precisely so it cannot be chosen by whoever relays it.
    bytes32 public constant ATTEST_TYPEHASH = keccak256(
        "Attest(address asset,uint64 batchId,uint256 notional18,uint256 margin18,uint256 openInterest18,uint64 observedAt,uint64 deadline)"
    );

    /// @notice The longest a signature may remain usable. Immutable and short by construction.
    /// @dev This is the whole defence against a relayer HOLDING a signature. The attestation's own
    ///      age is honest either way (see attestSigned), so a held signature cannot lie about
    ///      freshness — but it can still be used to burn a batchId with stale figures and briefly
    ///      push capacity to zero. Bounding the window to a minute bounds that grief to a minute,
    ///      after which the signature is simply dead and the next one supersedes it.
    uint256 public constant SIGNATURE_VALIDITY = 60;

    // The constructor ARITY is frozen (see `governance`) - test/AttackSuite.t.sol depends on
    // `constructor(address _attester)` verbatim and must not be edited. An EIP-712 base constructor
    // adds no parameter, so the signature is unchanged.
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

    /// @notice Post an attestation the attester SIGNED rather than SENT. Anyone may relay it, and
    ///         the relayer pays the gas.
    /// @dev WHY THIS EXISTS. attest() requires the attester to be msg.sender, so the attester paid
    ///      for every write — and because capacity goes to zero once ageSec passes
    ///      CapacityOracle.maxAttestationAgeSec, it had to keep writing on a timer whether or not
    ///      anyone was minting. That is a standing gas cost for an idle protocol. Here the attester
    ///      signs off-chain and the minter submits the signature inside their own transaction, so
    ///      an idle protocol costs nothing and the person who wants the mint pays for it.
    ///
    /// @dev THE TIMESTAMP IS THE WHOLE DESIGN, so it is worth being explicit about what changed.
    ///      attest() stores block.timestamp, which is honest ONLY because the attester broadcasts
    ///      the instant it observes. Once a signature can sit in someone's pocket, observation and
    ///      settlement are no longer the same moment: signing at T0 and relaying at T1 would stamp
    ///      data that is (T1 - T0) old with a timestamp of T1. ageSec would then report seconds
    ///      where the truth is minutes, and the capacity gate would admit mints against figures it
    ///      believes are fresh. That is C-2's shape exactly — a bound that looks like it binds and
    ///      does not — so `observedAt` is part of the SIGNED payload and is what gets stored. The
    ///      relayer cannot choose it, and ageSec keeps measuring the age of the DATA rather than
    ///      the age of the transaction.
    ///
    /// @dev Three guards follow from that, and each is load-bearing:
    ///      - `observedAt` in the FUTURE is rejected. Not defence in depth: ageSec computes
    ///        `block.timestamp - attestedAt` under checked arithmetic, so a future timestamp makes
    ///        ageSec REVERT, and every consumer of capacity reverts with it. This is the same
    ///        failure C-1 found on the feed timestamp.
    ///      - `observedAt` going BACKWARDS is rejected. Storing an older observation than the one
    ///        already held would move the recorded age up rather than down, which is a free way to
    ///        push capacity to zero using a signature the attester really did issue.
    ///      - `deadline` is capped at SIGNATURE_VALIDITY from the observation, not merely honoured
    ///        as given, so a signer cannot mint a long-lived credential by mistake or otherwise.
    ///
    /// @dev Replay is already handled and needs nothing new: `asset` is inside the digest so a
    ///      signature cannot be moved between vaults; EIP-712's domain separator binds chainId and
    ///      this contract so it cannot be moved between deployments or chains; and batchId must
    ///      strictly increase, so a signature dies the moment a later one lands. Recovery is
    ///      checked against the CURRENT attester, so a rotated-out key's signatures stop working
    ///      the instant acceptAttester() runs — rotation keeps the meaning M-5 gave it.
    function attestSigned(
        address asset,
        uint64 batchId,
        uint256 notional18,
        uint256 margin18,
        uint256 openInterest18,
        uint64 observedAt,
        uint64 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert SolvencyRegistry_SignatureExpired();
        if (deadline > uint256(observedAt) + SIGNATURE_VALIDITY) revert SolvencyRegistry_SignatureExpired();
        if (observedAt > block.timestamp) revert SolvencyRegistry_ObservationInFuture();
        if (observedAt < _latest[asset].attestedAt) revert SolvencyRegistry_ObservationWentBackwards();
        if (batchId <= _latest[asset].batchId) revert SolvencyRegistry_StaleBatch();

        bytes32 digest = _hashTypedData(
            keccak256(
                abi.encode(
                    ATTEST_TYPEHASH, asset, batchId, notional18, margin18, openInterest18, observedAt, deadline
                )
            )
        );
        // ECDSA.recover rejects a malleable `s` and a zero recovery, so a forged signature cannot
        // resolve to address(0) and match an uninitialised attester — which the constructor's
        // zero-address check already makes unreachable, and this makes unreachable twice.
        if (ECDSA.recover(digest, signature) != attester) revert SolvencyRegistry_BadSignature();

        _latest[asset] = Attestation({
            notional18: notional18,
            margin18: margin18,
            openInterest18: openInterest18,
            batchId: batchId,
            // The observation time, NOT block.timestamp. See the timestamp note above.
            attestedAt: observedAt
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
