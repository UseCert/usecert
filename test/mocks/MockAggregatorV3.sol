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

    /// @dev Lets a test flip an already-deployed feed's reported decimals() after the fact —
    ///      e.g. modelling a live feed that starts sane and later reports something absurd
    ///      (Task 10 review, Finding 2), which a straight second constructor call cannot
    ///      reproduce: CertOracle's own constructor reads the feed unguarded, so a feed that is
    ///      already broken at construction time makes the CertOracle constructor itself panic.
    function setDecimals(uint8 d) external {
        _decimals = d;
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
