// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice The part of CertStaking this contract relies on. `minNotify` is the smallest funding
///         the staking contract accepts; `rewardToken` is checked once, at construction.
interface ICertStakingFunding {
    function rewardToken() external view returns (IERC20);
    function minNotify() external view returns (uint256);
    function notifyRewardAmount(uint256 amount) external;
}

/// @title BuybackForwarder — the 20% buyback leg of the fee split, forwarded to CERT stakers
/// @notice A FeeVault recipient whose only possible use of its USDG is to fund one CertStaking
///         contract. forward(), callable by anyone, pays the whole balance in as rewards.
/// @dev Pre-audit L-1 and L-15. Under the first K2 plan the buyback leg and the ops leg were both
///      the deployer EOA: FeeVault refuses a duplicate recipient (L-1), so that split could not
///      even be deployed, and 25% of all fees would have sat on the hot key that signs deploys,
///      reaching CERT stakers only if that key later chose to call notifyRewardAmount (L-15).
///      This contract is a distinct address for the buyback leg, and no key controls it.
///
///      Why a forwarder and not FeeVault paying CertStaking directly: a plain transfer into
///      CertStaking is not credited to anyone and nothing could ever stream it. Funding has to go
///      through notifyRewardAmount, which pulls from its caller. This contract is that caller.
///
///      What it can do with its funds is exactly one thing: approve `staking` for its balance,
///      call staking.notifyRewardAmount, and reset the allowance. Both addresses are immutable.
///      There is no owner, no rescue, no setter, no receive/fallback, and no other function that
///      moves tokens. Any other token sent here stays here forever; that is the price of there
///      being no key that could also take the USDG.
///
///      Below `staking.minNotify()` it does nothing, so the balance simply accumulates until a
///      funding is large enough to be accepted, instead of every call reverting.
contract BuybackForwarder {
    using SafeERC20 for IERC20;

    error BuybackForwarder_ZeroAddress();
    error BuybackForwarder_WrongRewardToken();

    event Forwarded(address indexed caller, uint256 amount);
    /// @dev A keeper watching this sees why nothing moved, rather than a silent no-op.
    event Skipped(uint256 balance, uint256 minNotify);

    IERC20 public immutable usdg;
    ICertStakingFunding public immutable staking;

    constructor(IERC20 usdg_, ICertStakingFunding staking_) {
        if (address(usdg_) == address(0) || address(staking_) == address(0)) revert BuybackForwarder_ZeroAddress();
        // With no rescue, a forwarder bound to a staking contract that streams another token would
        // hold its USDG forever: every notifyRewardAmount would pull the wrong token and revert.
        // Checked here, the only time it can be.
        if (address(staking_.rewardToken()) != address(usdg_)) revert BuybackForwarder_WrongRewardToken();
        // The same reasoning for minNotify: a staking version without it (the earlier CertStaking)
        // would make every forward() revert. Calling it now makes that a failed deploy instead.
        staking_.minNotify();
        usdg = usdg_;
        staking = staking_;
    }

    /// @notice Pay the whole USDG balance into `staking` as rewards, if it is at least
    ///         `staking.minNotify()`. Permissionless: the destination is fixed, so the only choice
    ///         a caller has is when.
    /// @return amount What was paid in; 0 when skipped.
    function forward() external returns (uint256 amount) {
        uint256 bal = usdg.balanceOf(address(this));
        uint256 min = staking.minNotify();
        // notifyRewardAmount refuses zero, so a zero balance is skipped even when min is 0.
        if (bal == 0 || bal < min) {
            emit Skipped(bal, min);
            return 0;
        }
        amount = bal;
        // Exactly the amount, and back to zero afterwards: no standing allowance ever outlives
        // the call, whatever the staking contract does with the one it was given.
        usdg.forceApprove(address(staking), amount);
        staking.notifyRewardAmount(amount);
        usdg.forceApprove(address(staking), 0);
        emit Forwarded(msg.sender, amount);
    }
}
