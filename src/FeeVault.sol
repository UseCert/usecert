// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";

/// @title FeeVault — where the vaults' fee income lands, and the fixed split that sends it on
/// @notice CertVault.sweepFees() sends fee income here. distribute() splits the whole balance
///         between a fixed list of recipients in fixed basis points. Anyone may call it.
/// @dev K2. Not deployed. No owner, no setters, no upgrade path: the recipients and their shares
///      are written once in the constructor and nothing can change them. Changing the split
///      means deploying a new FeeVault, and because CertVault.setFeeSink is set-once, a new vault
///      stack too. That is deliberate. A split governance could retune would be a standing
///      governance decision over every fee.
///
///      THE SPLIT IS NOT DECIDED HERE. The whitepaper says 80/10/5/5 buyback / staker pay /
///      treasury / ops. The site's learn copy says 80/10/5/5 stakers / insurance buffer / keepers
///      / treasury. Those are different contracts receiving different money. This contract takes
///      whichever the owner decides as constructor input. See docs/K-INSURANCE-STAKING.md, K2.
///
///      Rounding: each share is floored, so at most (recipients - 1) units stay behind per call.
///      They are not lost. They are part of the balance the next distribute() splits.
///
///      One recipient whose transfer reverts (for example an address the collateral's issuer has
///      frozen) makes every distribute() revert, and with no owner nothing can route around it.
///      All or nothing is chosen over skipping it on purpose, because skipping would silently
///      re-split that recipient's share among the others on the next call. Choose recipients that
///      cannot be frozen out, such as the Safe and InsuranceStaking. Collateral in this contract is
///      protocol income, never holder backing, so a stall costs revenue and not principal.
contract FeeVault {
    using SafeERC20 for IERC20;

    error FeeVault_ZeroAddress();
    error FeeVault_BadRecipientCount();
    error FeeVault_LengthMismatch();
    error FeeVault_ZeroShare();
    error FeeVault_DuplicateRecipient();
    error FeeVault_SharesDoNotSumTo10000();

    event Paid(address indexed recipient, uint256 amount);
    /// @dev `dustKept` is the remainder left in the vault for the next distribute().
    event Distributed(uint256 amount, uint256 dustKept);

    uint256 public constant TOTAL_BPS = 10_000;
    uint256 public constant MAX_RECIPIENTS = 8;

    /// @notice The only token this contract distributes: the vaults' collateral.
    /// @dev Any other token sent here stays here forever, since nothing can move it.
    IERC20 public immutable asset;

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
            // replaced. With no owner, catching it here is the only chance.
            for (uint256 j = 0; j < i; j++) {
                if (recipients_[j] == r) revert FeeVault_DuplicateRecipient();
            }
            sum += bps_[i];
        }
        // Exactly 10_000: below it the difference would pile up as permanent "dust", above it
        // the last transfers of every distribute() would revert.
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

    /// @notice Split the whole balance by the fixed shares. Permissionless: the destination of
    ///         every unit is fixed, so the only choice a caller has is when.
    /// @return distributed What was sent in total, which is the balance less the rounding dust.
    function distribute() external returns (uint256 distributed) {
        uint256 bal = asset.balanceOf(address(this));
        uint256 n = _recipients.length;
        for (uint256 i = 0; i < n; i++) {
            // mulDiv so no balance can overflow the product. The floor is what leaves the dust.
            uint256 amount = Math.mulDiv(bal, _bps[i], TOTAL_BPS);
            if (amount == 0) continue;
            distributed += amount;
            asset.safeTransfer(_recipients[i], amount);
            emit Paid(_recipients[i], amount);
        }
        if (distributed > 0) emit Distributed(distributed, bal - distributed);
    }
}
