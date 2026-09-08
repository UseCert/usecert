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

    event Attested(address indexed asset, uint64 batchId, uint256 notional18, uint256 margin18, uint256 openInterest18);

    address public immutable attester;
    mapping(address => Attestation) private _latest;

    constructor(address _attester) {
        attester = _attester;
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
