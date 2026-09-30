// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";
import {IRevShareVault, IPxOracle, IVaultFactory, IInsurancePool} from "./interfaces/IRevShare.sol";

/// @title RevenueRouter - stack 6's fee sink: insurance first, then the token
/// @notice distribute() splits the income nobody has been credited yet by how well the insurance
///         pool covers the certificates outstanding:
///           cover <  target: 50% insurance, 30% token side, 10% ops, 10% treasury
///           cover >= target:  0% insurance, 80% token side, 10% ops, 10% treasury
///           pool has no shares: its share goes to the treasury (Sermium L-02: no first-depositor prize)
///         target = targetBps x the value of every registered vault's certificates. Pull-based like
///         FeeVault: distribute() only books; claim(recipient) pays one recipient.
/// @dev No owner. Recipients are immutable. The only setting is targetBps, within
///      [MIN_TARGET_BPS, MAX_TARGET_BPS], by governance, after TARGET_DELAY.
contract RevenueRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error RevenueRouter_ZeroAddress();
    error RevenueRouter_OnlyGovernance();
    error RevenueRouter_TargetOutOfBounds();
    error RevenueRouter_TargetNotReady();
    error RevenueRouter_NoPendingTarget();

    event Credited(address indexed recipient, uint256 amount);
    event Distributed(uint256 amount, uint256 dustKept, uint256 insBps, uint256 tokenBps);
    event Claimed(address indexed recipient, address indexed caller, uint256 amount);
    event TargetProposed(uint256 bps, uint256 readyAt);
    event TargetApplied(uint256 bps);

    uint256 public constant TOTAL_BPS = 10_000;
    uint256 public constant MIN_TARGET_BPS = 200;
    uint256 public constant MAX_TARGET_BPS = 1_000;
    uint256 public constant TARGET_DELAY = 2 days;
    uint256 public constant MAX_VAULTS = 16;

    IERC20 public immutable asset;
    uint256 public immutable assetScale;                 // 10 ** (18 - assetDecimals)
    IVaultFactory public immutable factory;
    IInsurancePool public immutable insurance;
    address public immutable buyback;
    address public immutable ops;
    address public immutable treasury;
    address public immutable governance;

    uint256 public targetBps = 500;
    uint256 public pendingTargetBps;
    uint256 public pendingTargetAt;

    mapping(address => uint256) public owed;
    uint256 public totalOwed;

    constructor(IERC20 asset_, uint8 assetDecimals, IVaultFactory factory_, IInsurancePool insurance_,
                address buyback_, address ops_, address treasury_, address governance_) {
        if (address(asset_) == address(0) || address(factory_) == address(0) || address(insurance_) == address(0)
            || buyback_ == address(0) || ops_ == address(0) || treasury_ == address(0) || governance_ == address(0)) {
            revert RevenueRouter_ZeroAddress();
        }
        asset = asset_;
        assetScale = 10 ** (18 - assetDecimals);
        factory = factory_;
        insurance = insurance_;
        buyback = buyback_;
        ops = ops_;
        treasury = treasury_;
        governance = governance_;
    }

    // ------------------------------------------------------------------ views
    /// @notice The value of every registered vault's certificates, 18-decimal USD.
    function openValue18() public view returns (uint256 v) {
        uint256 n = factory.vaultCount();
        if (n > MAX_VAULTS) n = MAX_VAULTS;
        for (uint256 i = 0; i < n; i++) {
            IRevShareVault vault = IRevShareVault(factory.vaults(i));
            (uint256 px18,) = IPxOracle(vault.oracle()).pxUnguarded();
            v += Math.mulDiv(IERC20(vault.certificate()).totalSupply(), px18, 1e18);
        }
    }

    function shares() public view returns (uint256 insBps, uint256 tokenBps, uint256 opsBps, uint256 treasuryBps) {
        if (insurance.totalSupply() == 0) return (0, 3_000, 1_000, 6_000);
        uint256 target = Math.mulDiv(openValue18(), targetBps, TOTAL_BPS) / assetScale;
        if (insurance.totalAssets() < target) return (5_000, 3_000, 1_000, 1_000);
        return (0, 8_000, 1_000, 1_000);
    }

    function uncredited() public view returns (uint256) {
        uint256 bal = asset.balanceOf(address(this));
        return bal > totalOwed ? bal - totalOwed : 0;
    }

    // ------------------------------------------------------------------ split and pay
    function distribute() external nonReentrant returns (uint256 credited) {
        uint256 fresh = uncredited();
        if (fresh == 0) return 0;
        (uint256 insBps, uint256 tokenBps, uint256 opsBps, uint256 treasuryBps) = shares();
        credited += _credit(address(insurance), fresh, insBps);
        credited += _credit(buyback, fresh, tokenBps);
        credited += _credit(ops, fresh, opsBps);
        credited += _credit(treasury, fresh, treasuryBps);
        totalOwed += credited;
        emit Distributed(credited, fresh - credited, insBps, tokenBps);
    }

    function _credit(address to, uint256 fresh, uint256 bps) internal returns (uint256 amount) {
        if (bps == 0) return 0;
        amount = Math.mulDiv(fresh, bps, TOTAL_BPS);
        if (amount == 0) return 0;
        owed[to] += amount;
        emit Credited(to, amount);
    }

    function claim(address recipient) external nonReentrant returns (uint256 amount) {
        amount = owed[recipient];
        if (amount == 0) return 0;
        owed[recipient] = 0;
        totalOwed -= amount;
        asset.safeTransfer(recipient, amount);
        emit Claimed(recipient, msg.sender, amount);
    }

    // ------------------------------------------------------------------ the one setting
    function proposeTarget(uint256 bps) external {
        if (msg.sender != governance) revert RevenueRouter_OnlyGovernance();
        if (bps < MIN_TARGET_BPS || bps > MAX_TARGET_BPS) revert RevenueRouter_TargetOutOfBounds();
        pendingTargetBps = bps;
        pendingTargetAt = block.timestamp + TARGET_DELAY;
        emit TargetProposed(bps, pendingTargetAt);
    }

    function applyTarget() external {
        if (pendingTargetAt == 0) revert RevenueRouter_NoPendingTarget();
        if (block.timestamp < pendingTargetAt) revert RevenueRouter_TargetNotReady();
        targetBps = pendingTargetBps;
        pendingTargetBps = 0;
        pendingTargetAt = 0;
        emit TargetApplied(targetBps);
    }
}
