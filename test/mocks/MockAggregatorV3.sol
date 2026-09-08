// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

contract MockAggregatorV3 is IAggregatorV3 {
    uint8 internal _decimals;
    int256 public answer;
    uint256 public updatedAt;
    /// @dev when true, both latestRoundData() and decimals() revert — simulates a paused or
    ///      access-controlled aggregator, e.g. Finding 1's scenario.
    bool public shouldRevert;

    constructor(uint8 d, int256 a) {
        _decimals = d;
        answer = a;
        updatedAt = block.timestamp;
    }

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
    }

    function setShouldRevert(bool r) external {
        shouldRevert = r;
    }

    function decimals() external view returns (uint8) {
        if (shouldRevert) revert("MockAggregatorV3: reverted");
        return _decimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (shouldRevert) revert("MockAggregatorV3: reverted");
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
