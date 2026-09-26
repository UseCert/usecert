// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

/// @title CertStaking — stake CERT for a share of the protocol's buyback-fund income
/// @notice Owner decision 2026-09-26 (option 2): CERT staking is a SHARE OF FEES, not insurance.
///         The 20% buyback-fund leg of the 70/20/5/5 split is paid in here as rewards and streamed
///         to CERT stakers pro rata over `rewardsDuration`. The insurance layer stays USDG
///         (InsuranceStaking): staked CERT is never drawn, and cannot be lost to a draw.
/// @dev The StakingRewards pattern, with four deliberate differences:
///      - funding is PERMISSIONLESS (`notifyRewardAmount` pulls the reward token from the caller),
///        so no owner or distributor key is needed: the buyback fund, or anyone, can pay in;
///      - stakes and rewards are credited by BALANCE DELTA, so a fee-on-transfer token can never
///        credit more than arrived (CERT's source is not verified, so this is not assumed away);
///      - reward accrued while nobody is staked is not stranded: it is carried into the next
///        funding (`unallocated`) instead of paying out to an empty pool;
///      - an immutable `stakeCap` bounds what an unaudited contract can hold.
///      No owner, no pause, no upgrade, no parameter setters. Withdrawals are immediate: this is
///      not an insurance tranche, so there is nothing for a cooldown to protect.
contract CertStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error CertStaking_ZeroAddress();
    error CertStaking_BadConfig();
    error CertStaking_ZeroAmount();
    error CertStaking_AboveStakeCap();
    error CertStaking_InsufficientStake();
    error CertStaking_RewardTooSmall();

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(address indexed funder, uint256 received, uint256 rewardRate, uint256 periodFinish);

    IERC20 public immutable stakingToken; // CERT
    IERC20 public immutable rewardToken; // USDG (the buyback fund's asset until a CERT market exists)
    uint256 public immutable rewardsDuration;
    uint256 public immutable stakeCap;

    uint256 public periodFinish;
    /// @notice Reward-token units per second, scaled by 1e18. Unscaled, 700 USDG over a week
    ///         floors to 1,157 units/s and streams only 699.7536: a quarter of a USDG short of what
    ///         was paid in, every time. Scaled, the undistributed remainder is at most 1 unit.
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    /// @dev 1e36, not the usual 1e18: rewards are USDG (6 decimals) and stakes are CERT (18). At
    ///      1e18, a week of 100 USDG over 1e9 staked CERT is 165 units/s * 1e18 / 1e27 = 0 per
    ///      second - every second's reward would round away. At 1e36 it is 1.65e11. Overflow bound:
    ///      balance * rewardPerToken is at most total rewards * 1e36, far below 2^256.
    uint256 public constant PRECISION = 1e36;
    uint256 public rewardPerTokenStored; // scaled by PRECISION
    /// @notice Reward that accrued while nothing was staked; re-streamed by the next funding.
    uint256 public unallocated;

    uint256 public totalStaked;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    constructor(IERC20 stakingToken_, IERC20 rewardToken_, uint256 rewardsDuration_, uint256 stakeCap_) {
        if (address(stakingToken_) == address(0) || address(rewardToken_) == address(0)) revert CertStaking_ZeroAddress();
        // Same token for both would let rewards be paid out of stakes (and stakes counted as rewards).
        if (address(stakingToken_) == address(rewardToken_) || rewardsDuration_ < 1 days || rewardsDuration_ > 90 days || stakeCap_ == 0) {
            revert CertStaking_BadConfig();
        }
        stakingToken = stakingToken_;
        rewardToken = rewardToken_;
        rewardsDuration = rewardsDuration_;
        stakeCap = stakeCap_;
    }

    // ------------------------------------------------------------------ views

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * (PRECISION / 1e18) / totalStaked;
    }

    function earned(address account) public view returns (uint256) {
        return balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account]) / PRECISION + rewards[account];
    }

    /// @notice Reward still to be streamed in the current period.
    function remainingReward() public view returns (uint256) {
        return block.timestamp >= periodFinish ? 0 : (periodFinish - block.timestamp) * rewardRate / 1e18;
    }

    // ------------------------------------------------------------------ accounting

    modifier updateReward(address account) {
        uint256 applicable = lastTimeRewardApplicable();
        if (totalStaked == 0 && applicable > lastUpdateTime) {
            // Nobody earned this stretch: keep it for the next funding instead of stranding it.
            unallocated += (applicable - lastUpdateTime) * rewardRate / 1e18;
        }
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = applicable;
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // ------------------------------------------------------------------ staker actions

    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert CertStaking_ZeroAmount();
        uint256 before = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = stakingToken.balanceOf(address(this)) - before;
        if (received == 0) revert CertStaking_ZeroAmount();
        if (totalStaked + received > stakeCap) revert CertStaking_AboveStakeCap();
        totalStaked += received;
        balanceOf[msg.sender] += received;
        emit Staked(msg.sender, received);
    }

    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert CertStaking_ZeroAmount();
        if (amount > balanceOf[msg.sender]) revert CertStaking_InsufficientStake();
        totalStaked -= amount;
        balanceOf[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external {
        withdraw(balanceOf[msg.sender]);
        getReward();
    }

    // ------------------------------------------------------------------ funding

    /// @notice Pay `amount` of the reward token in and stream it (plus anything unstreamed or
    ///         unallocated) over the next `rewardsDuration`. Permissionless.
    function notifyRewardAmount(uint256 amount) external nonReentrant updateReward(address(0)) {
        if (amount == 0) revert CertStaking_ZeroAmount();
        uint256 before = rewardToken.balanceOf(address(this));
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = rewardToken.balanceOf(address(this)) - before;

        uint256 total = received + remainingReward() + unallocated;
        unallocated = 0;
        uint256 rate = total * 1e18 / rewardsDuration;
        if (rate == 0) revert CertStaking_RewardTooSmall();
        // What the scaled rate cannot stream (at most 1 unit) stays for the next funding.
        unallocated = total - rate * rewardsDuration / 1e18;
        rewardRate = rate;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(msg.sender, received, rate, periodFinish);
    }
}
