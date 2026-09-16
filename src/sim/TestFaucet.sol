// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Hands out test collateral to whoever asks, at most once per `interval` per address.
///
/// @dev DELIBERATELY NOT PART OF `LighterSim`, and that separation is the whole design.
///
///      The venue does not mint collateral. A prior round of this project shipped a simulator
///      whose `_fundPending()` conjured the tokens a gain-drawing withdrawal needed, and the
///      consequence was a venue that could ALWAYS pay — which is precisely the one state solvency
///      exists to detect, made unobservable. `LighterCore._fundPending()` is a no-op for that
///      reason and the mint override lives on `MockLighter` alone. Putting a faucet on the
///      simulator would reintroduce the same confusion through a different door: an operator
///      reading the venue's token balance could no longer tell collateral that depositors brought
///      from collateral the venue made up.
///
///      So: this contract holds a float and transfers from it. It has NO mint call, no reference to
///      the simulator, and no privileged path back out.
///
///      ------------------------------------------------------------------------------------------
///      NO OWNER, AND NO SWEEP. There is deliberately no `rescue`, `withdraw`, `sweep` or
///      `setDripAmount`, and no owner to call one. Two reasons:
///
///        1. A drainable faucet is a faucet whose balance is not evidence of anything. Every token
///           in here left through `claim()`, one drip at a time, and each drip is a log — so
///           `token.balanceOf(faucet)` plus the `Dripped` stream is a closed account.
///        2. An owner-drainable pool of the same collateral the venue holds looks like a second
///           venue balance sheet to anything reading the chain, which is the confusion this
///           contract is separate in order to avoid.
///
///      Everything is immutable and set at construction. To change the drip, deploy another faucet;
///      to retire one, stop topping it up. Both cost nothing on a testnet, and neither needs a key
///      that can move collateral.
///      ------------------------------------------------------------------------------------------
///
///      Topping it up is a plain ERC-20 `transfer` in — there is no `fund()` to call and no
///      accounting to keep in step, so a top-up cannot be done wrongly.
contract TestFaucet {
    using SafeERC20 for IERC20;

    /// @dev The caller claimed again before its interval elapsed. Carries the timestamp at which it
    ///      may, so a UI does not have to recompute it.
    error TestFaucet_TooSoon(uint256 availableAt);
    /// @dev The faucet is out of collateral. Named rather than a failed transfer, because "the
    ///      testnet faucet is empty" and "the token is broken" are different operator actions.
    ///      This is the state the faucet is ALLOWED to reach: see the no-sweep note above.
    error TestFaucet_Empty(uint256 held, uint256 requested);
    /// @dev A zero token address, a zero drip or a zero interval each produce a faucet that is
    ///      deployed and either useless or unlimited. Refused at construction.
    error TestFaucet_BadConfig();

    /// @notice A drip was dispensed.
    /// @dev `recipient` is indexed because rate limiting is per address and an operator's question
    ///      is always about one address. `nextAvailableAt` is emitted so a consumer never has to
    ///      know `interval` to render the cooldown.
    event Dripped(address indexed recipient, uint256 amount, uint256 nextAvailableAt, uint256 faucetBalanceAfter);

    /// @notice The test collateral this faucet dispenses.
    IERC20 public immutable token;
    /// @notice How much one claim pays out, in the token's own units (6 decimals for `TestUSDG`).
    uint256 public immutable dripAmount;
    /// @notice The minimum seconds between two claims by the same address.
    uint256 public immutable interval;

    /// @notice When each address last claimed. Zero means never.
    /// @dev Keyed on `msg.sender`, NOT on a recipient argument. A `to` parameter would make the
    ///      rate limit trivially bypassable by one address naming a different recipient each call
    ///      and collecting the proceeds, which is a rate limit in name only. A determined tester
    ///      can still cycle fresh addresses — that is inherent to every faucet and is why the
    ///      float, not the limit, is what bounds the total.
    mapping(address => uint256) public lastClaimAt;

    constructor(IERC20 _token, uint256 _dripAmount, uint256 _interval) {
        if (address(_token) == address(0) || _dripAmount == 0 || _interval == 0) revert TestFaucet_BadConfig();
        token = _token;
        dripAmount = _dripAmount;
        interval = _interval;
    }

    /// @notice Send one drip to the caller.
    /// @dev Permissionless by design: a faucet with an allowlist is a distribution list.
    function claim() external {
        uint256 available = nextAvailableAt(msg.sender);
        if (block.timestamp < available) revert TestFaucet_TooSoon(available);

        uint256 held = token.balanceOf(address(this));
        if (held < dripAmount) revert TestFaucet_Empty(held, dripAmount);

        // Written BEFORE the transfer. `TestUSDG` is a plain OpenZeppelin ERC-20 with no callback,
        // so no reentrancy is reachable today; the ordering costs nothing and does not rely on
        // that staying true for whatever token a future testnet points this at.
        lastClaimAt[msg.sender] = block.timestamp;
        token.safeTransfer(msg.sender, dripAmount);

        emit Dripped(msg.sender, dripAmount, block.timestamp + interval, held - dripAmount);
    }

    /// @notice The earliest timestamp at which `who` may claim. Zero-ish for an address that never
    ///         has, so a first claim is always immediate.
    function nextAvailableAt(address who) public view returns (uint256) {
        uint256 last = lastClaimAt[who];
        return last == 0 ? 0 : last + interval;
    }

    /// @notice How many more drips this faucet can pay out before it needs topping up.
    /// @dev For the runbook's troubleshooting table: "the faucet gave me nothing" is answered by
    ///      this returning zero, and the fix is a transfer in rather than a redeploy.
    function dripsRemaining() external view returns (uint256) {
        return token.balanceOf(address(this)) / dripAmount;
    }
}
