// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {ICapacityOracle} from "./interfaces/ICapacityOracle.sol";
import {ISolvencyRegistry} from "./interfaces/ISolvencyRegistry.sol";

/// @notice Capacity is a formula, not a constant, so the product grows as the market grows
///         without redeployment:
///
///           maxNotional = min(depthBps * openInterest, absoluteCap, bufferCapacity)
///
/// @dev Open interest comes from the same per-batch attestation that feeds solvency, so it is not
///      operator self-reporting. absoluteCap and the depthBps bounds are immutable at deploy:
///      governance can tune within them and can never remove the cap. A stale attestation yields
///      zero capacity, which pauses minting — never redemption (Law 2).
contract CapacityOracle is ICapacityOracle {
    error CapacityOracle_OnlyGovernance();
    error CapacityOracle_DepthOutOfBounds();
    /// @dev M4: absoluteCap18 is the single number bounding a compromised or lying attester, so
    ///      governance must not be able to set it to any value it likes. maxAbsoluteCap is the
    ///      deploy-time ceiling on that number and cannot be changed afterwards.
    error CapacityOracle_CapAboveCeiling();
    /// @dev L-3 (LOW, external C1 audit): a zero registry makes maxNotional18 revert on every call,
    ///      which reverts both mint paths through _requireCapacity; a zero governance makes the
    ///      depth and cap levers permanently unreachable, freezing them at their deploy values.
    error CapacityOracle_ZeroAddress();

    event DepthBpsSet(uint256 depthBps);
    event AbsoluteCapSet(address indexed asset, uint256 cap18);

    ISolvencyRegistry public immutable registry;
    address public immutable governance;
    uint256 public immutable minDepthBps;
    uint256 public immutable maxDepthBps;
    uint256 public immutable maxAttestationAgeSec;
    /// @notice Hard ceiling on any per-asset absoluteCap18 governance may set. Immutable.
    /// @dev M4: deliberately an immutable ceiling and NOT a timelock. A timelock needs a
    ///      governance framework (queue, delay, cancel, executor) that does not exist in C1, and
    ///      bolting a half-one onto this contract would be worse than the ceiling. The timelock
    ///      is recorded as a C2 item; this is the C1-shaped mitigation.
    uint256 public immutable maxAbsoluteCap;

    uint256 public depthBps;
    mapping(address => uint256) public absoluteCap18;

    constructor(
        address _registry,
        address _governance,
        uint256 _depthBps,
        uint256 _minDepthBps,
        uint256 _maxDepthBps,
        uint256 _maxAttestationAgeSec,
        uint256 _maxAbsoluteCap
    ) {
        if (_registry == address(0) || _governance == address(0)) revert CapacityOracle_ZeroAddress();
        if (_depthBps < _minDepthBps || _depthBps > _maxDepthBps) {
            revert CapacityOracle_DepthOutOfBounds();
        }
        registry = ISolvencyRegistry(_registry);
        governance = _governance;
        depthBps = _depthBps;
        minDepthBps = _minDepthBps;
        maxDepthBps = _maxDepthBps;
        maxAttestationAgeSec = _maxAttestationAgeSec;
        maxAbsoluteCap = _maxAbsoluteCap;
    }

    function setDepthBps(uint256 v) external {
        if (msg.sender != governance) revert CapacityOracle_OnlyGovernance();
        if (v < minDepthBps || v > maxDepthBps) revert CapacityOracle_DepthOutOfBounds();
        depthBps = v;
        emit DepthBpsSet(v);
    }

    /// @dev Governance only, with no first-call exception. An earlier draft let anyone set a
    ///      never-before-set cap "for bootstrap convenience"; that let a stranger front-run the
    ///      cap for a new asset, which is the one number holding a compromised attester in check.
    /// @dev M4: bounded by the immutable maxAbsoluteCap. Governance may tune the cap down or up
    ///      within that ceiling and can never remove it — the same shape as setDepthBps against
    ///      [minDepthBps, maxDepthBps].
    function setAbsoluteCap(address asset, uint256 cap18) external {
        if (msg.sender != governance) revert CapacityOracle_OnlyGovernance();
        if (cap18 > maxAbsoluteCap) revert CapacityOracle_CapAboveCeiling();
        absoluteCap18[asset] = cap18;
        emit AbsoluteCapSet(asset, cap18);
    }

    function maxNotional18(address asset, uint256 bufferCapacity18) external view returns (uint256) {
        if (registry.ageSec(asset) > maxAttestationAgeSec) return 0;

        uint256 oi = registry.latest(asset).openInterest18;
        if (oi == 0) return 0;

        uint256 byDepth = Math.mulDiv(oi, depthBps, 10_000);
        uint256 cap = absoluteCap18[asset];
        uint256 out = byDepth < cap ? byDepth : cap;
        return out < bufferCapacity18 ? out : bufferCapacity18;
    }
}
