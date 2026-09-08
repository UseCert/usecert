// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

interface ISolvencyRegistry {
    struct Attestation {
        uint256 notional18;
        uint256 margin18;
        uint256 openInterest18;
        uint64 batchId;
        uint64 attestedAt;
    }

    function latest(address asset) external view returns (Attestation memory);
    function ageSec(address asset) external view returns (uint256);
}
