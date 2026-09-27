// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

/// @title FeeVault — where the vaults' fee income lands, and the fixed split that sends it on
/// @notice CertVault.sweepFees() sends fee income here. distribute() credits the income that has
///         not been credited yet to a fixed list of recipients in fixed basis points, and
///         claim(recipient) pays a recipient what it has been credited. Anyone may call either.
/// @dev K2. Not deployed. No owner, no setters, no upgrade path: the recipients and their shares
///      are written once in the constructor and nothing can change them. Changing the split
///      means deploying a new FeeVault, and because CertVault.setFeeSink is set-once, a new vault
///      stack too. That is deliberate. A split governance could retune would be a standing
///      governance decision over every fee.
///
///      THE SPLIT IS CONSTRUCTOR INPUT. The owner set it on 2026-09-26: 70/20/5/5 - stakers
///      (InsuranceStaking) / the buyback leg (a BuybackForwarder into CertStaking) / keeper and
///      ops gas / the treasury (the 2-of-3 Safe). test_mainnetSplit_order_and_bps pins the order
///      and the shares. See docs/K-INSURANCE-STAKING.md, K2.
///
///      PULL, NOT PUSH (pre-audit L-2). The first version paid every recipient inside
///      distribute(), so one recipient whose transfer reverts (an address the collateral's issuer
///      has frozen, say) made every distribute() revert forever, and with no owner nothing could
///      route around it. Now distribute() moves no tokens: it only books each recipient's share
///      in `owed`. The transfer happens in claim(recipient), one recipient at a time, so a
///      reverting transfer reverts only that recipient's claim. Its credit stays booked for it
///      (never re-split among the others) and is paid in full if the transfer ever works again.
///      Every other recipient's claim, and every later distribute(), is unaffected.
///
///      Accounting invariant: sum(owed) == totalOwed <= asset.balanceOf(this). distribute() only
///      ever splits `balance - totalOwed`, the income nobody has been credited yet, so no unit is
///      credited twice.
///
///      Rounding: each share is floored, so at most (recipients - 1) units of each distribute()
///      stay uncredited. They are not lost. They are part of the uncredited balance the next
///      distribute() splits.
contract FeeVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error FeeVault_ZeroAddress();
    error FeeVault_BadRecipientCount();
    error FeeVault_LengthMismatch();
    error FeeVault_ZeroShare();
    error FeeVault_DuplicateRecipient();
    error FeeVault_SharesDoNotSumTo10000();

    event Credited(address indexed recipient, uint256 amount);
    /// @dev `dustKept` is the uncredited remainder left for the next distribute().
    event Distributed(uint256 amount, uint256 dustKept);
    event Claimed(address indexed recipient, address indexed caller, uint256 amount);

    uint256 public constant TOTAL_BPS = 10_000;
    uint256 public constant MAX_RECIPIENTS = 8;

    /// @notice The only token this contract distributes: the vaults' collateral.
    /// @dev CertVault.setFeeSink checks `asset() == collateral` before binding a sink, so a vault
    ///      can never be pointed, set-once, at a FeeVault for another token. Any other token sent
    ///      here stays here forever, since nothing can move it.
    IERC20 public immutable asset;

    /// @notice What each recipient has been credited and not yet been paid.
    mapping(address => uint256) public owed;
    /// @notice sum(owed): the part of the balance that already belongs to a recipient.
    uint256 public totalOwed;

    address[] private _recipients;
    uint256[] private _bps;

    constructor(IERC20 asset_, address[] memory recipients_, uint256[] memory bps_) {
        if (address(asset_) == address(0)) revert FeeVault_ZeroAddress();
        uint256 n = recipients_.length;
        if (n == 0 || n > MAX_RECIPIENTS) revert FeeVault_BadRecipientCount();
        if (bps_.length != n) revert FeeVault_LengthMismatch();

        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            address r = recipients_[i];
            if (r == address(0)) revert FeeVault_ZeroAddress();
            // A zero share is a recipient that can never receive anything: a misconfiguration
            // hiding in a list that can never be edited.
            if (bps_[i] == 0) revert FeeVault_ZeroShare();
            // A duplicate is almost always a copy-paste slip that silently drops the address it
            // replaced. With no owner, catching it here is the only chance. Two legs that should
            // end up with one party get two distinct addresses (for example a BuybackForwarder).
            for (uint256 j = 0; j < i; j++) {
                if (recipients_[j] == r) revert FeeVault_DuplicateRecipient();
            }
            sum += bps_[i];
        }
        // Exactly 10_000: below it the difference would pile up as permanent "dust", above it
        // the vault would credit more than it holds.
        if (sum != TOTAL_BPS) revert FeeVault_SharesDoNotSumTo10000();

        asset = asset_;
        _recipients = recipients_;
        _bps = bps_;
    }

    function recipientCount() external view returns (uint256) {
        return _recipients.length;
    }

    /// @notice The i-th recipient and its share in basis points.
    function recipientAt(uint256 i) external view returns (address recipient, uint256 bps) {
        return (_recipients[i], _bps[i]);
    }

    /// @notice The income that has arrived and not been credited to anyone yet.
    function uncredited() public view returns (uint256) {
        uint256 bal = asset.balanceOf(address(this));
        // Floored at zero: the collateral is not expected to shrink a holder's balance, but if it
        // ever did, crediting nothing is the only answer that cannot over-credit.
        return bal > totalOwed ? bal - totalOwed : 0;
    }

    /// @notice Credit the uncredited income to the recipients by the fixed shares. Moves no
    ///         tokens, so no recipient can make it revert. Permissionless: the destination of
    ///         every unit is fixed, so the only choice a caller has is when.
    /// @return credited What was credited in total: the uncredited income less the rounding dust.
    function distribute() external nonReentrant returns (uint256 credited) {
        uint256 fresh = uncredited();
        uint256 n = _recipients.length;
        for (uint256 i = 0; i < n; i++) {
            // mulDiv so no balance can overflow the product. The floor is what leaves the dust.
            uint256 amount = Math.mulDiv(fresh, _bps[i], TOTAL_BPS);
            if (amount == 0) continue;
            credited += amount;
            owed[_recipients[i]] += amount;
            emit Credited(_recipients[i], amount);
        }
        if (credited > 0) {
            totalOwed += credited;
            emit Distributed(credited, fresh - credited);
        }
    }

    /// @notice Pay `recipient` everything it has been credited. Permissionless, and the tokens go
    ///         only to `recipient`, so a contract recipient (InsuranceStaking, a
    ///         BuybackForwarder) needs no code of its own to be paid: anyone can call this for it.
    /// @dev If the transfer reverts (the recipient is frozen, the token is paused) the whole call
    ///      reverts and the credit stays booked. Nothing else is touched, so the other recipients
    ///      and distribute() carry on. nonReentrant with distribute(): a token that called back
    ///      between the bookkeeping and the balance change could otherwise make the in-flight
    ///      amount look uncredited.
    /// @return amount What was paid; 0, and nothing moved, for an address owed nothing.
    function claim(address recipient) external nonReentrant returns (uint256 amount) {
        amount = owed[recipient];
        if (amount == 0) return 0;
        owed[recipient] = 0;
        totalOwed -= amount;
        asset.safeTransfer(recipient, amount);
        emit Claimed(recipient, msg.sender, amount);
    }
}
