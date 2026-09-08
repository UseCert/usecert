// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

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

    event DepthBpsSet(uint256 depthBps);
    event AbsoluteCapSet(address indexed asset, uint256 cap18);

    ISolvencyRegistry public immutable registry;
    address public immutable governance;
    uint256 public immutable minDepthBps;
    uint256 public immutable maxDepthBps;
    uint256 public immutable maxAttestationAgeSec;

    uint256 public depthBps;
    mapping(address => uint256) public absoluteCap18;

    constructor(
        address _registry,
        address _governance,
        uint256 _depthBps,
        uint256 _minDepthBps,
        uint256 _maxDepthBps,
        uint256 _maxAttestationAgeSec
    ) {
        if (_depthBps < _minDepthBps || _depthBps > _maxDepthBps) {
            revert CapacityOracle_DepthOutOfBounds();
        }
        registry = ISolvencyRegistry(_registry);
        governance = _governance;
        depthBps = _depthBps;
        minDepthBps = _minDepthBps;
        maxDepthBps = _maxDepthBps;
        maxAttestationAgeSec = _maxAttestationAgeSec;
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
    function setAbsoluteCap(address asset, uint256 cap18) external {
        if (msg.sender != governance) revert CapacityOracle_OnlyGovernance();
        absoluteCap18[asset] = cap18;
        emit AbsoluteCapSet(asset, cap18);
    }

    function maxNotional18(address asset, uint256 bufferCapacity18) external view returns (uint256) {
        if (registry.ageSec(asset) > maxAttestationAgeSec) return 0;

        uint256 oi = registry.latest(asset).openInterest18;
        if (oi == 0) return 0;

        uint256 byDepth = oi * depthBps / 10_000;
        uint256 cap = absoluteCap18[asset];
        uint256 out = byDepth < cap ? byDepth : cap;
        return out < bufferCapacity18 ? out : bufferCapacity18;
    }
}
