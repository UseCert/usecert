// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

/// @title CertStaking — stake CERT for a share of the protocol's buyback-fund income
/// @notice Owner decision 2026-09-26 (option 2): CERT staking is a SHARE OF FEES, not insurance.
///         The 20% buyback-fund leg of the 70/20/5/5 split is paid in here as rewards and streamed
///         to CERT stakers pro rata. The insurance layer stays USDG (InsuranceStaking): staked
///         CERT is never drawn, and cannot be lost to a draw.
/// @dev The StakingRewards pattern, with these deliberate differences:
///      - funding is PERMISSIONLESS (`notifyRewardAmount` pulls the reward token from the caller),
///        so no owner or distributor key is needed: the buyback fund, or anyone, can pay in;
///      - stakes and rewards are credited by BALANCE DELTA, so a fee-on-transfer token can never
///        credit more than arrived (CERT's source is not verified, so this is not assumed away);
///      - reward accrued while nobody is staked is not stranded: it is carried into the next
///        funding (`unallocated`) instead of paying out to an empty pool;
///      - a funding during a running period is folded into THAT period and never moves its end
///        (pre-audit M-4), and fundings below an immutable `minNotify` are refused;
///      - every carried remainder is kept at 1e18 scale, so no fraction of a unit is both
///        streamed and carried (pre-audit M-3);
///      - an immutable `stakeCap` bounds what an unaudited contract can hold.
///      No owner, no pause, no upgrade, no parameter setters. Withdrawals are immediate: this is
///      not an insurance tranche, so there is nothing for a cooldown to protect.
///
///      v2. The v1 deployment on chain 4663 is immutable and keeps v1's behaviour; this source is
///      for a new deployment only.
contract CertStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error CertStaking_ZeroAddress();
    error CertStaking_BadConfig();
    error CertStaking_ZeroAmount();
    error CertStaking_AboveStakeCap();
    error CertStaking_InsufficientStake();
    error CertStaking_BelowMinNotify();

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(address indexed funder, uint256 received, uint256 rewardRate, uint256 periodFinish);

    /// @dev Reward amounts are carried internally at this scale (reward-token units * 1e18).
    uint256 private constant SCALE = 1e18;

    /// @notice A funding that arrives with less than this left in the running period starts a
    ///         fresh period of `rewardsDuration` instead of being folded into the time left.
    /// @dev Why the edge exists: folding a funding into `periodFinish - now` seconds concentrates
    ///      it. One second before the end, a funding would stream in one second; it would also
    ///      hand the whole amount to whoever is staked in that second. Below one hour the funding
    ///      starts a new full period instead, so the densest a funding can ever stream is its
    ///      amount over one hour.
    ///
    ///      Why it is not a griefing vector: the edge is reachable only when the running period
    ///      has genuinely run down to its last hour, and a funding cannot move `periodFinish`
    ///      while more than an hour is left. So a restart can happen at most once per period, at
    ///      that period's natural end, and what it moves into the next period is at most one
    ///      hour's stream (1/168 of a weekly period). Compare v1, where `notifyRewardAmount(1)`
    ///      restarted the full period on every call (pre-audit M-4).
    uint256 public constant MIN_TIME_LEFT = 1 hours;

    IERC20 public immutable stakingToken; // CERT
    IERC20 public immutable rewardToken; // USDG (the buyback fund's asset until a CERT market exists)
    uint256 public immutable rewardsDuration;
    /// @notice The most CERT this contract will hold in total, to bound what an unaudited
    ///         contract can hold.
    /// @dev Pre-audit L-13, concentration: one holder can fill the whole cap (10M is 1% of CERT
    ///      supply), take the whole fee share, and keep other holders out until they withdraw.
    ///      This is ACCEPTED, and a per-address cap is deliberately NOT added: splitting a stake
    ///      across fresh addresses costs nothing, so a per-address cap would not bind the holder it
    ///      is aimed at and would only inconvenience honest users. The cap bounds EXPOSURE, not
    ///      concentration. Concentration changes who receives fees, never solvency: every staker
    ///      can withdraw at any time. If it becomes a problem the answer is a new deployment with
    ///      a larger cap, not an allow-list.
    uint256 public immutable stakeCap;
    /// @notice The smallest funding `notifyRewardAmount` accepts, in reward-token units (> 0).
    /// @dev Stops dust spam: with fundings folded into the running period a dust funding can no
    ///      longer delay anything, but every funding still costs the pool a storage rewrite and
    ///      an event. A forwarder that pays in its whole balance should read `minNotify()` and
    ///      skip the call when its balance is below it, rather than revert.
    uint256 internal immutable _minNotify;

    uint256 public periodFinish;
    /// @notice Reward-token units per second, scaled by 1e18. Unscaled, 700 USDG over a week
    ///         floors to 1,157 units/s and streams only 699.7536: a quarter of a USDG short of what
    ///         was paid in, every time. Scaled, what the rate cannot stream is carried at 1e18
    ///         scale in `unallocatedScaled`.
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    /// @dev 1e36, not the usual 1e18: rewards are USDG (6 decimals) and stakes are CERT (18). At
    ///      1e18, a week of 100 USDG over 1e9 staked CERT is 165 units/s * 1e18 / 1e27 = 0 per
    ///      second - every second's reward would round away. At 1e36 it is 1.65e11. Overflow bound:
    ///      balance * rewardPerToken is at most total rewards * 1e36, far below 2^256.
    uint256 public constant PRECISION = 1e36;
    uint256 public rewardPerTokenStored; // scaled by PRECISION
    /// @notice Reward carried to the next funding, in reward-token units * 1e18: what accrued
    ///         while nothing was staked, plus what the last rate could not stream.
    /// @dev Pre-audit M-3. v1 kept this in whole units: after `total * 1e18 / D` it carried
    ///      `total - floor(rate * D / 1e18)`, i.e. the remainder ROUNDED UP to a whole unit, while
    ///      `rewardPerToken` streamed all but a fraction of that same unit. The fraction was paid
    ///      twice: fund 7, then 1, and the pool owed 9 while holding 8. At 1e18 scale the carry is
    ///      exactly `total18 - rate * D`, disjoint from what the rate streams, so the scaled sum
    ///      of streamed + still-to-stream + carried always equals what was received.
    uint256 public unallocatedScaled;

    uint256 public totalStaked;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    constructor(IERC20 stakingToken_, IERC20 rewardToken_, uint256 rewardsDuration_, uint256 stakeCap_, uint256 minNotify_) {
        if (address(stakingToken_) == address(0) || address(rewardToken_) == address(0)) revert CertStaking_ZeroAddress();
        // Same token for both would let rewards be paid out of stakes (and stakes counted as rewards).
        if (
            address(stakingToken_) == address(rewardToken_) || rewardsDuration_ < 1 days || rewardsDuration_ > 90 days || stakeCap_ == 0
                || minNotify_ == 0
        ) {
            revert CertStaking_BadConfig();
        }
        stakingToken = stakingToken_;
        rewardToken = rewardToken_;
        rewardsDuration = rewardsDuration_;
        stakeCap = stakeCap_;
        _minNotify = minNotify_;
    }

    // ------------------------------------------------------------------ views

    /// @notice The smallest funding `notifyRewardAmount` accepts, in reward-token units.
    function minNotify() external view returns (uint256) {
        return _minNotify;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * (PRECISION / SCALE) / totalStaked;
    }

    function earned(address account) public view returns (uint256) {
        return balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account]) / PRECISION + rewards[account];
    }

    /// @notice Reward still to be streamed in the current period, in reward-token units (floor).
    function remainingReward() public view returns (uint256) {
        return _remainingScaled() / SCALE;
    }

    /// @notice Reward carried to the next funding, in reward-token units (floor). Includes any
    ///         stretch since the last update during which nothing was staked.
    function unallocated() public view returns (uint256) {
        return (unallocatedScaled + _pendingEmptyScaled()) / SCALE;
    }

    function _remainingScaled() internal view returns (uint256) {
        return block.timestamp >= periodFinish ? 0 : (periodFinish - block.timestamp) * rewardRate;
    }

    /// @dev The stream since `lastUpdateTime` that nobody earned because nothing was staked.
    function _pendingEmptyScaled() internal view returns (uint256) {
        uint256 applicable = lastTimeRewardApplicable();
        return totalStaked == 0 && applicable > lastUpdateTime ? (applicable - lastUpdateTime) * rewardRate : 0;
    }

    // ------------------------------------------------------------------ accounting

    modifier updateReward(address account) {
        // Nobody earned this stretch: keep it, exactly, for the next funding instead of stranding it.
        unallocatedScaled += _pendingEmptyScaled();
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
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

    /// @notice Withdraw the whole stake (if any) and claim. With nothing staked it only claims:
    ///         someone who already withdrew must still be able to use it to collect what they
    ///         earned, instead of hitting `withdraw(0)`'s ZeroAmount revert.
    function exit() external {
        uint256 staked = balanceOf[msg.sender];
        if (staked > 0) withdraw(staked);
        getReward();
    }

    // ------------------------------------------------------------------ funding

    /// @notice Pay `amount` of the reward token in and stream it. Permissionless.
    ///         While a period is running, the funding (plus what is still to stream and anything
    ///         carried) is spread over the time LEFT: `periodFinish` does not move. With no period
    ///         running, or less than `MIN_TIME_LEFT` left, it starts a new period of
    ///         `rewardsDuration`.
    /// @dev Pre-audit M-4. v1 restarted the full period on every funding, so a 1-unit funding
    ///      called daily pushed about 37% of each week's reward from current stakers to later
    ///      ones. Here a funding can only ADD to what current stakers receive by the current end.
    ///
    ///      Trade-off, stated so it is not mistaken for an oversight: a funding late in a period
    ///      streams over the short time left, so stakers who join just for that stretch share it
    ///      in full (at most one hour's concentration, see `MIN_TIME_LEFT`). Whoever pays in
    ///      controls when, so a caller that forwards accumulated fees should forward often, in
    ///      small amounts, rather than let a large balance build up.
    ///
    ///      `rate` cannot be zero: `received >= minNotify >= 1`, so `total18 >= 1e18`, and the
    ///      stream length is at most 90 days (7.8e6 s).
    function notifyRewardAmount(uint256 amount) external nonReentrant updateReward(address(0)) {
        if (amount < _minNotify) revert CertStaking_BelowMinNotify();
        uint256 before = rewardToken.balanceOf(address(this));
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = rewardToken.balanceOf(address(this)) - before;
        // Balance delta, not `amount`: a fee-on-transfer reward token cannot slip a dust funding in.
        if (received < _minNotify) revert CertStaking_BelowMinNotify();

        // All at 1e18 scale: what arrived, what the running rate has still to stream, and what is
        // carried. updateReward has just checkpointed to `now`, so these three are disjoint.
        uint256 total18 = received * SCALE + _remainingScaled() + unallocatedScaled;

        uint256 length;
        if (block.timestamp + MIN_TIME_LEFT <= periodFinish) {
            length = periodFinish - block.timestamp; // running: fold in, keep the end
        } else {
            length = rewardsDuration; // idle, or in its last hour: a new full period
            periodFinish = block.timestamp + length;
        }
        uint256 rate = total18 / length;
        // Exactly what `rate` cannot stream over `length`, kept at scale for the next funding.
        unallocatedScaled = total18 - rate * length;
        rewardRate = rate;
        lastUpdateTime = block.timestamp;
        emit RewardAdded(msg.sender, received, rate, periodFinish);
    }
}
