// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";
import {IUniswapV2PairLike, ITokenStaking} from "./interfaces/IRevShare.sol";

interface IBurnable {
    function burn(uint256 amount) external;
}

/// @title Buyback - turns the token side's USDG into burnt and staked tokens
/// @notice Before the token graduates it only holds USDG. Governance sets the token/USDG pair
///         once, after POOL_DELAY. Then anyone may call buy() once per BUY_INTERVAL: it spends
///         min(trancheMax, 1% of the pair's USDG reserve, balance), refuses unless the swap
///         returns at least (1 - GUARD_BPS) of what the pair's own average price over the last
///         30 minutes to 2 hours implies, burns half of the tokens and funds TokenStaking with
///         the other half (all burnt when nothing is staked). The caller keeps a small reward.
/// @dev No owner, no pause. Never holds tokens after a buy. The average price is taken from the
///      pair's UQ112x112 cumulative prices, with the counterfactual accumulation since the pair's
///      last update, exactly as UniswapV2OracleLibrary.currentCumulativePrices does.
contract Buyback is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error Buyback_ZeroAddress();
    error Buyback_OnlyGovernance();
    error Buyback_PoolAlreadySet();
    error Buyback_NoPendingPool();
    error Buyback_PoolNotReady();
    error Buyback_WrongPool();
    error Buyback_NoPool();
    error Buyback_TooSoon();
    error Buyback_ObservationTooRecent();
    error Buyback_PriceGuard();
    error Buyback_NothingToSpend();

    event PoolProposed(address pair, uint256 readyAt);
    event PoolSet(address pair);
    event Observed(uint256 cumulative, uint256 at);
    event Bought(address indexed caller, uint256 usdgSpent, uint256 tokensReceived, uint256 avgTokensPerUsdgX112,
                 uint256 burnt, uint256 toStakers, uint256 callerReward);

    uint256 public constant BUY_INTERVAL = 1 hours;
    uint256 public constant TWAP_MIN = 30 minutes;
    uint256 public constant TWAP_MAX = 2 hours;
    uint256 public constant GUARD_BPS = 200;
    uint256 public constant POOL_DELAY = 2 days;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable usdg;
    IERC20 public immutable token;
    ITokenStaking public immutable staking;
    address public immutable governance;
    bool public immutable tokenHasBurn;
    uint256 public immutable trancheMax;
    uint256 public immutable callerRewardMax;

    IUniswapV2PairLike public pair;
    bool public usdgIsToken0;
    address public pendingPair;
    uint256 public pendingPairAt;

    uint256 public lastObsCumulative;
    uint256 public lastObsTime;
    uint256 public lastBuyAt;

    constructor(IERC20 usdg_, IERC20 token_, ITokenStaking staking_, address governance_, bool tokenHasBurn_,
                uint256 trancheMax_, uint256 callerRewardMax_) {
        if (address(usdg_) == address(0) || address(token_) == address(0) || address(staking_) == address(0)
            || governance_ == address(0)) revert Buyback_ZeroAddress();
        usdg = usdg_;
        token = token_;
        staking = staking_;
        governance = governance_;
        tokenHasBurn = tokenHasBurn_;
        trancheMax = trancheMax_;
        callerRewardMax = callerRewardMax_;
    }

    // ------------------------------------------------------------------ the pool, once
    function proposePool(address p) external {
        if (msg.sender != governance) revert Buyback_OnlyGovernance();
        if (address(pair) != address(0)) revert Buyback_PoolAlreadySet();
        if (p == address(0)) revert Buyback_ZeroAddress();
        pendingPair = p;
        pendingPairAt = block.timestamp + POOL_DELAY;
        emit PoolProposed(p, pendingPairAt);
    }

    function applyPool() external {
        if (address(pair) != address(0)) revert Buyback_PoolAlreadySet();
        if (pendingPair == address(0)) revert Buyback_NoPendingPool();
        if (block.timestamp < pendingPairAt) revert Buyback_PoolNotReady();
        IUniswapV2PairLike p = IUniswapV2PairLike(pendingPair);
        address t0 = p.token0();
        address t1 = p.token1();
        bool ok = (t0 == address(usdg) && t1 == address(token)) || (t0 == address(token) && t1 == address(usdg));
        if (!ok) revert Buyback_WrongPool();
        pair = p;
        usdgIsToken0 = t0 == address(usdg);
        pendingPair = address(0);
        pendingPairAt = 0;
        emit PoolSet(address(p));
    }

    // ------------------------------------------------------------------ price
    /// @dev Cumulative "tokens per USDG" in UQ112x112 seconds, including the time since the pair's
    ///      last update at its current reserves.
    function _cumulative() internal view returns (uint256 cum, uint256 rUsdg, uint256 rToken) {
        (uint112 r0, uint112 r1, uint32 last) = pair.getReserves();
        (rUsdg, rToken) = usdgIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        cum = usdgIsToken0 ? pair.price0CumulativeLast() : pair.price1CumulativeLast();
        uint32 elapsed = uint32(block.timestamp) - last;
        if (elapsed > 0 && rUsdg != 0) cum += (rToken << 112) / rUsdg * elapsed;
    }

    function _observe(uint256 cum) internal {
        lastObsCumulative = cum;
        lastObsTime = block.timestamp;
        emit Observed(cum, block.timestamp);
    }

    // ------------------------------------------------------------------ buy
    /// @dev One buy's figures, kept in memory: the legacy code generator has no room for them as
    ///      locals (the repo builds with via_ir off).
    struct Trade {
        uint256 avgX112;
        uint256 rUsdg;
        uint256 rToken;
        uint256 spend;
        uint256 reward;
        uint256 amountIn;
        uint256 out;
    }

    function buy() external nonReentrant returns (uint256 received) {
        if (address(pair) == address(0)) revert Buyback_NoPool();
        if (lastBuyAt != 0 && block.timestamp < lastBuyAt + BUY_INTERVAL) revert Buyback_TooSoon();
        Trade memory t;
        bool observedOnly;
        (observedOnly, t.avgX112, t.rUsdg, t.rToken) = _averagePrice();
        if (observedOnly) return 0;
        _quote(t);
        received = _swap(t.amountIn, t.out);
        (uint256 cum,,) = _cumulative();
        _observe(cum);
        lastBuyAt = block.timestamp;
        (uint256 burnt, uint256 toStakers) = _burnAndStake(received);
        if (t.reward > 0) usdg.safeTransfer(msg.sender, t.reward);
        emit Bought(msg.sender, t.spend, received, t.avgX112, burnt, toStakers, t.reward);
    }

    /// @dev The average tokens-per-USDG since the last observation, or - with no observation, or
    ///      one older than TWAP_MAX - a fresh observation and `observedOnly`.
    function _averagePrice() internal returns (bool observedOnly, uint256 avgX112, uint256 rUsdg, uint256 rToken) {
        uint256 cum;
        (cum, rUsdg, rToken) = _cumulative();
        uint256 age = block.timestamp - lastObsTime;
        if (lastObsTime == 0 || age > TWAP_MAX) {
            _observe(cum);
            return (true, 0, rUsdg, rToken);
        }
        if (age < TWAP_MIN) revert Buyback_ObservationTooRecent();
        avgX112 = (cum - lastObsCumulative) / age;
    }

    /// @dev The tranche, the caller's reward, the swap input and output, and the price guard:
    ///      the output must be at least (1 - GUARD_BPS) of what the average price implies.
    function _quote(Trade memory t) internal view {
        t.spend = Math.min(Math.min(trancheMax, t.rUsdg / 100), usdg.balanceOf(address(this)));
        if (t.spend == 0) revert Buyback_NothingToSpend();
        t.reward = Math.min(callerRewardMax, t.spend / 100);
        t.amountIn = t.spend - t.reward;
        uint256 expected = Math.mulDiv(t.amountIn, t.avgX112, 1 << 112);
        uint256 inWithFee = t.amountIn * 997;
        t.out = inWithFee * t.rToken / (t.rUsdg * 1000 + inWithFee);
        if (t.out * 10_000 < expected * (10_000 - GUARD_BPS)) revert Buyback_PriceGuard();
    }

    function _swap(uint256 amountIn, uint256 out) internal returns (uint256 received) {
        uint256 before = token.balanceOf(address(this));
        usdg.safeTransfer(address(pair), amountIn);
        if (usdgIsToken0) pair.swap(0, out, address(this), "");
        else pair.swap(out, 0, address(this), "");
        received = token.balanceOf(address(this)) - before;
    }

    /// @dev Half burnt, half to stakers; all burnt when nothing is staked (no first-staker prize).
    function _burnAndStake(uint256 received) internal returns (uint256 burnt, uint256 toStakers) {
        toStakers = staking.totalStaked() == 0 ? 0 : received - received / 2;
        burnt = received - toStakers;
        if (tokenHasBurn) IBurnable(address(token)).burn(burnt);
        else token.safeTransfer(DEAD, burnt);
        if (toStakers > 0) {
            token.forceApprove(address(staking), toStakers);
            staking.notifyRewardAmount(toStakers);
            token.forceApprove(address(staking), 0);
        }
    }
}
