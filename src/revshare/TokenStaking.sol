// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

/// @title TokenStaking - stack-6 Staking v3: stake the token, earn the token
/// @notice Each funding vests over a weighted window: the stream's end moves to
///         now + (R·(end−now) + X·DURATION)/(R+X), R the reward still to stream and X the new
///         funding. A large funding therefore streams over close to a full week however late it
///         lands (Sermium M-01), and a dust funding barely moves the end (L-01). Leaving takes
///         COOLDOWN, and stake that is leaving earns nothing (the rolling-escrow advantage of M-2).
///         No owner, no pause, no stake cap (L-04). Funding is permissionless.
/// @dev Accounting is in `PRECISION`-scaled token units: rewardRate is tokens·PRECISION per
///      second; `carriedScaled` holds reward that streamed while nothing was staked plus every
///      rounding remainder, and is folded into the next funding. Invariant (fuzzed):
///      earned(all) + totalStaked + totalUnstaking + remainingReward + carried <= balance.
contract TokenStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error TokenStaking_ZeroAmount();
    error TokenStaking_InsufficientStake();
    error TokenStaking_CooldownNotOver();
    error TokenStaking_NothingUnstaking();

    event Staked(address indexed user, uint256 amount);
    event UnstakeRequested(address indexed user, uint256 amount, uint64 readyAt);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event RewardAdded(address indexed funder, uint256 received, uint256 rewardRate, uint256 periodFinish);

    uint256 public constant DURATION = 7 days;
    uint256 public constant COOLDOWN = 7 days;
    uint256 public constant PRECISION = 1e18;

    IERC20 public immutable token;

    uint256 public totalStaked;
    uint256 public totalUnstaking;
    mapping(address => uint256) public balanceOf;

    struct Unstake {
        uint256 amount;
        uint64 readyAt;
    }

    mapping(address => Unstake) public unstaking;

    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public carriedScaled;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    constructor(IERC20 token_) {
        token = token_;
    }

    // ------------------------------------------------------------------ views
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        uint256 t = lastTimeRewardApplicable();
        if (t <= lastUpdateTime) return rewardPerTokenStored;
        return rewardPerTokenStored + rewardRate * (t - lastUpdateTime) / totalStaked;
    }

    function earned(address a) public view returns (uint256) {
        return balanceOf[a] * (rewardPerToken() - userRewardPerTokenPaid[a]) / PRECISION + rewards[a];
    }

    function remainingReward() public view returns (uint256) {
        if (block.timestamp >= periodFinish) return 0;
        return rewardRate * (periodFinish - block.timestamp) / PRECISION;
    }

    /// @notice Reward carried for the next funding: streamed while nothing was staked, plus rounding.
    function carried() public view returns (uint256) {
        uint256 c = carriedScaled;
        if (totalStaked == 0) {
            uint256 t = lastTimeRewardApplicable();
            if (t > lastUpdateTime) c += rewardRate * (t - lastUpdateTime);
        }
        return c / PRECISION;
    }

    // ------------------------------------------------------------------ bookkeeping
    function _update(address a) internal {
        uint256 t = lastTimeRewardApplicable();
        if (t > lastUpdateTime) {
            uint256 streamed = rewardRate * (t - lastUpdateTime);
            if (totalStaked == 0) {
                carriedScaled += streamed;
            } else {
                rewardPerTokenStored += streamed / totalStaked;
                carriedScaled += streamed % totalStaked;
            }
        }
        lastUpdateTime = t > lastUpdateTime ? t : lastUpdateTime;
        if (a != address(0)) {
            rewards[a] = earned(a);
            userRewardPerTokenPaid[a] = rewardPerTokenStored;
        }
    }

    // ------------------------------------------------------------------ staking
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert TokenStaking_ZeroAmount();
        _update(msg.sender);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        balanceOf[msg.sender] += received;
        totalStaked += received;
        emit Staked(msg.sender, received);
    }

    /// @notice Move `amount` of active stake into the cooldown. It stops earning at once. A new
    ///         request adds to the pending one and restarts its clock.
    function requestUnstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert TokenStaking_ZeroAmount();
        if (amount > balanceOf[msg.sender]) revert TokenStaking_InsufficientStake();
        _update(msg.sender);
        balanceOf[msg.sender] -= amount;
        totalStaked -= amount;
        totalUnstaking += amount;
        Unstake storage u = unstaking[msg.sender];
        u.amount += amount;
        u.readyAt = uint64(block.timestamp + COOLDOWN);
        emit UnstakeRequested(msg.sender, amount, u.readyAt);
    }

    function withdraw() external nonReentrant {
        Unstake memory u = unstaking[msg.sender];
        if (u.amount == 0) revert TokenStaking_NothingUnstaking();
        if (block.timestamp < u.readyAt) revert TokenStaking_CooldownNotOver();
        delete unstaking[msg.sender];
        totalUnstaking -= u.amount;
        token.safeTransfer(msg.sender, u.amount);
        emit Withdrawn(msg.sender, u.amount);
    }

    function getReward() external nonReentrant {
        _update(msg.sender);
        uint256 r = rewards[msg.sender];
        if (r == 0) return;
        rewards[msg.sender] = 0;
        token.safeTransfer(msg.sender, r);
        emit RewardPaid(msg.sender, r);
    }

    // ------------------------------------------------------------------ funding
    function notifyRewardAmount(uint256 amount) external nonReentrant {
        if (amount == 0) revert TokenStaking_ZeroAmount();
        _update(address(0));
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 x = token.balanceOf(address(this)) - before;

        uint256 remainingScaled = block.timestamp < periodFinish ? rewardRate * (periodFinish - block.timestamp) : 0;
        uint256 left = block.timestamp < periodFinish ? periodFinish - block.timestamp : 0;
        uint256 r = remainingScaled / PRECISION;
        uint256 incoming = x + carriedScaled / PRECISION;
        uint256 duration = (r + incoming) == 0 ? DURATION : (r * left + incoming * DURATION) / (r + incoming);
        if (duration == 0) duration = 1;

        uint256 totalScaled = remainingScaled + x * PRECISION + carriedScaled;
        rewardRate = totalScaled / duration;
        carriedScaled = totalScaled - rewardRate * duration;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + duration;
        emit RewardAdded(msg.sender, x, rewardRate, periodFinish);
    }
}
