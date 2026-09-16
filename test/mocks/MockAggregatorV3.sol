// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

contract MockAggregatorV3 is IAggregatorV3 {
    uint8 internal _decimals;
    int256 public answer;
    uint256 public updatedAt;
    /// @dev Task 1: the round the feed is currently reporting. Real aggregators mint a NEW round
    ///      id for every new answer they publish, and CertOracle's poke confirmation now proves
    ///      round distinctness from this number directly instead of inferring it from timestamps.
    ///      Starts at 1 so `roundId > pendingRoundId` is a meaningful comparison from the first
    ///      observation (0 would make an unarmed sentinel indistinguishable from a real round).
    uint80 public roundId = 1;
    /// @dev when true, both latestRoundData() and decimals() revert — simulates a paused or
    ///      access-controlled aggregator, e.g. Finding 1's scenario.
    bool public shouldRevert;

    constructor(uint8 d, int256 a) {
        _decimals = d;
        answer = a;
        updatedAt = block.timestamp;
    }

    /// @dev Publishes a NEW round, so the round id advances — this is what a live aggregator does
    ///      on every update, and it is why the 13 existing call sites need no change: every
    ///      `set()` in the suite already means "the feed spoke again".
    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
        roundId++;
    }

    /// @dev Task 1: republish inside the SAME round — a fresher `updatedAt` with no new round id.
    ///      Models the case the roundId proof exists to refuse: a feed (or a caller re-reading
    ///      one) whose timestamp advances without the feed having independently re-reported.
    function setSameRound(int256 a, uint256 t) external {
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
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}
