// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice The four ERC-8056 views of a Robinhood stock token that CertOracle reads, with the
///         staging behaviour observed on chain 4663 (2026-09-27): `uiMultiplier()` switches to
///         `newUIMultiplier()` at `effectiveAt`, and `oraclePaused` is Robinhood's advisory flag
///         for the feed during a large change.
/// @dev Test-only knobs: `stage` (a scheduled change), `setMultiplier` (an UNSTAGED, instant
///      change), `setOraclePaused`, and `setBroken` (every view reverts).
contract MockUIMultiplierToken {
    uint256 internal _current;
    uint256 internal _next;
    uint256 internal _at;
    bool internal _paused;
    bool public broken;

    constructor(uint256 m) {
        _current = m;
        _next = m;
    }

    function uiMultiplier() external view returns (uint256) {
        require(!broken, "MockUIMultiplierToken: broken");
        return _live();
    }

    function newUIMultiplier() external view returns (uint256) {
        require(!broken, "MockUIMultiplierToken: broken");
        return _next;
    }

    function effectiveAt() external view returns (uint256) {
        require(!broken, "MockUIMultiplierToken: broken");
        return _at;
    }

    function oraclePaused() external view returns (bool) {
        require(!broken, "MockUIMultiplierToken: broken");
        return _paused;
    }

    /// @dev Schedule `next` to take effect at `at` (a staged change: dividend or split).
    function stage(uint256 next, uint256 at) external {
        _current = _live();
        _next = next;
        _at = at;
    }

    /// @dev An unstaged change, effective at once, with no window announced.
    function setMultiplier(uint256 m) external {
        _current = m;
        _next = m;
    }

    function setOraclePaused(bool p) external {
        _paused = p;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function _live() internal view returns (uint256) {
        return _at != 0 && block.timestamp >= _at ? _next : _current;
    }
}
