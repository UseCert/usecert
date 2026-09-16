// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface ICapacityOracle {
    function maxNotional18(address asset, uint256 bufferCapacity18) external view returns (uint256);
    function depthBps() external view returns (uint256);
}
