// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC4626} from "openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice The subset of CertFactory this contract reads: which addresses are real vaults.
interface IVaultRegistry {
    function isVault(address vault) external view returns (bool);
}

/// @title InsuranceStaking — the insurance rung of the loss order: buffer -> THIS -> (never) holders
/// @notice Stakers deposit the vaults' own collateral (USDG) and receive shares. A draw moves
///         collateral from here into a registered vault, where it becomes that vault's buffer and
///         backs holders; every share absorbs the loss pro rata. Anything sent here raises the
///         share price for every staker. See docs/K-INSURANCE-STAKING.md for why each rule exists.
/// @dev K1. Not deployed. Immutable: no owner, no upgrade path, no parameter setters.
///
///      Draws pay out WITHOUT touching a deployed vault: CertVault.hotBuffer() is its collateral
///      balanceOf, so a plain transfer to the vault is collateral the solvency math counts.
///
///      A draw is proposed by governance (the Safe), executable by anyone after `drawDelay`, and
///      expires DRAW_EXECUTION_WINDOW later. It can only go to a registered vault and is capped at
///      `maxDrawBps` of pool assets, checked at proposal and again at execution. While a draw is
///      pending, redeems and deposits are paused, so nobody leaves ahead of an announced loss or
///      walks into one; the pause ends when the draw executes, is cancelled or expires.
contract InsuranceStaking is ERC4626 {
    using SafeERC20 for IERC20;

    error InsuranceStaking_ZeroAddress();
    error InsuranceStaking_BadConfig();
    error InsuranceStaking_OnlyGovernance();
    error InsuranceStaking_NotAVault();
    error InsuranceStaking_ZeroAmount();
    error InsuranceStaking_DrawAboveCap();
    error InsuranceStaking_DrawPending();
    error InsuranceStaking_DrawNotExecutable();
    error InsuranceStaking_DrawClosed();
    error InsuranceStaking_CooldownNotReady();
    error InsuranceStaking_WithdrawWindowClosed();
    error InsuranceStaking_ExceedsCooldownShares();
    error InsuranceStaking_ExceedsBalance();
    error InsuranceStaking_ProposalTooSoon();
    error InsuranceStaking_AboveDepositCap();

    event WithdrawRequested(address indexed owner, uint256 shares, uint64 readyAt, uint64 closesAt);
    event WithdrawRequestCancelled(address indexed owner);
    event DrawProposed(uint256 indexed id, address indexed vault, uint256 amount, uint64 executableAt, uint64 expiresAt);
    event DrawExecuted(uint256 indexed id, address indexed vault, uint256 amount, uint256 assetsAfter);
    event DrawCancelled(uint256 indexed id);

    /// @notice How long a proposed draw stays executable once its delay has passed.
    uint256 public constant DRAW_EXECUTION_WINDOW = 3 days;
    uint256 public constant MAX_DRAW_BPS_BOUND = 5_000;
    /// @notice Minimum time between two draw proposals. Exits pause while a draw is pending, so
    ///         without a gap governance could re-propose forever and hold every staker in place.
    ///         7 days against drawDelay + DRAW_EXECUTION_WINDOW (<= cooldown + 3 days) leaves
    ///         exits open between cycles. The constructor makes drawDelay small enough for that.
    uint256 public constant MIN_PROPOSAL_GAP = 7 days;

    address public immutable governance;
    IVaultRegistry public immutable registry;
    uint256 public immutable cooldown;
    uint256 public immutable withdrawWindow;
    uint256 public immutable drawDelay;
    uint256 public immutable maxDrawBps;
    /// @notice The most the pool may hold from deposits. Immutable: the first deployment is
    ///         unaudited, and a hard ceiling is what bounds what anyone can lose to a bug in it.
    ///         A donation or income can take totalAssets past it; only deposits are refused.
    uint256 public immutable depositCap;

    struct WithdrawRequest {
        uint256 shares;
        uint64 readyAt;
    }

    struct Draw {
        address vault;
        uint256 amount;
        uint64 executableAt;
        bool executed;
        bool cancelled;
    }

    mapping(address => WithdrawRequest) public withdrawRequests;
    Draw[] public draws;
    uint256 public lastProposalAt;

    constructor(
        IERC20 asset_,
        IVaultRegistry registry_,
        address governance_,
        uint256 cooldown_,
        uint256 withdrawWindow_,
        uint256 drawDelay_,
        uint256 maxDrawBps_,
        uint256 depositCap_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) ERC4626(asset_) {
        if (address(asset_) == address(0) || address(registry_) == address(0) || governance_ == address(0)) {
            revert InsuranceStaking_ZeroAddress();
        }
        // cooldown > drawDelay: a staker who had not already requested cannot finish a withdrawal
        // inside a draw's public delay. The other two bound the draw and keep the window usable.
        if (
            cooldown_ <= drawDelay_ || withdrawWindow_ < 1 days || drawDelay_ == 0 || maxDrawBps_ == 0
                || maxDrawBps_ > MAX_DRAW_BPS_BOUND
                // a pending draw (delay + execution window) must end well inside the proposal
                // gap, so exits reopen between cycles
                || drawDelay_ + DRAW_EXECUTION_WINDOW + 1 days > MIN_PROPOSAL_GAP
                || depositCap_ == 0
        ) revert InsuranceStaking_BadConfig();
        governance = governance_;
        registry = registry_;
        cooldown = cooldown_;
        withdrawWindow = withdrawWindow_;
        drawDelay = drawDelay_;
        maxDrawBps = maxDrawBps_;
        depositCap = depositCap_;
    }

    // ------------------------------------------------------------------ withdrawals

    /// @notice Start the cooldown for `shares`. Replaces any earlier request. The shares keep
    ///         earning and keep absorbing draws until they are redeemed.
    function requestWithdraw(uint256 shares) external {
        if (shares == 0) revert InsuranceStaking_ZeroAmount();
        if (shares > balanceOf(msg.sender)) revert InsuranceStaking_ExceedsBalance();
        uint64 readyAt = uint64(block.timestamp + cooldown);
        withdrawRequests[msg.sender] = WithdrawRequest(shares, readyAt);
        emit WithdrawRequested(msg.sender, shares, readyAt, uint64(readyAt + withdrawWindow));
    }

    function cancelWithdraw() external {
        delete withdrawRequests[msg.sender];
        emit WithdrawRequestCancelled(msg.sender);
    }

    /// @notice True while the owner's request is inside its redeem window.
    function withdrawOpen(address owner) public view returns (bool) {
        WithdrawRequest memory r = withdrawRequests[owner];
        return r.shares > 0 && block.timestamp >= r.readyAt && block.timestamp < uint256(r.readyAt) + withdrawWindow;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (drawPending() || !withdrawOpen(owner)) return 0;
        uint256 s = withdrawRequests[owner].shares;
        uint256 bal = balanceOf(owner);
        return s < bal ? s : bal;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return convertToAssets(maxRedeem(owner));
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (drawPending()) return 0;
        uint256 held = totalAssets();
        return held >= depositCap ? 0 : depositCap - held;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    /// @dev Every exit path (withdraw and redeem) lands here. The checks are explicit rather than
    ///      left to ERC4626's max* guards so each refusal carries its own reason.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (drawPending()) revert InsuranceStaking_DrawPending();
        WithdrawRequest storage r = withdrawRequests[owner];
        if (r.shares == 0 || block.timestamp < r.readyAt) revert InsuranceStaking_CooldownNotReady();
        if (block.timestamp >= uint256(r.readyAt) + withdrawWindow) revert InsuranceStaking_WithdrawWindowClosed();
        if (shares > r.shares) revert InsuranceStaking_ExceedsCooldownShares();
        r.shares -= shares;
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (drawPending()) revert InsuranceStaking_DrawPending();
        if (totalAssets() + assets > depositCap) revert InsuranceStaking_AboveDepositCap();
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev Virtual shares at 1e6 per unit of a 6-decimal asset: OZ's first-depositor
    ///      (donation / inflation) mitigation.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ------------------------------------------------------------------ draws

    function drawCount() external view returns (uint256) {
        return draws.length;
    }

    /// @notice The most one draw may take right now.
    function drawCap() public view returns (uint256) {
        return totalAssets() * maxDrawBps / 10_000;
    }

    function _open(Draw memory d) private view returns (bool) {
        return !d.executed && !d.cancelled && block.timestamp < uint256(d.executableAt) + DRAW_EXECUTION_WINDOW;
    }

    /// @notice True while any draw is proposed and neither executed, cancelled nor expired.
    /// @dev Linear in draws; draws are rare governance events and expire, so the open ones are
    ///      the last few. Scanned from the newest backwards and stops at the first expired one
    ///      whose executableAt is older than every later proposal could be (proposals are
    ///      pushed in time order, so an expired draw means every earlier one is expired too).
    function drawPending() public view returns (bool) {
        for (uint256 i = draws.length; i > 0; i--) {
            Draw memory d = draws[i - 1];
            if (_open(d)) return true;
            if (block.timestamp >= uint256(d.executableAt) + DRAW_EXECUTION_WINDOW) return false;
        }
        return false;
    }

    function proposeDraw(address vault, uint256 amount) external returns (uint256 id) {
        if (msg.sender != governance) revert InsuranceStaking_OnlyGovernance();
        if (!registry.isVault(vault)) revert InsuranceStaking_NotAVault();
        if (amount == 0) revert InsuranceStaking_ZeroAmount();
        if (amount > drawCap()) revert InsuranceStaking_DrawAboveCap();
        if (lastProposalAt != 0 && block.timestamp < lastProposalAt + MIN_PROPOSAL_GAP) {
            revert InsuranceStaking_ProposalTooSoon();
        }
        lastProposalAt = block.timestamp;
        uint64 executableAt = uint64(block.timestamp + drawDelay);
        id = draws.length;
        draws.push(Draw(vault, amount, executableAt, false, false));
        emit DrawProposed(id, vault, amount, executableAt, uint64(executableAt + DRAW_EXECUTION_WINDOW));
    }

    /// @notice Permissionless once the delay has passed: governance decides, it cannot also stall.
    function executeDraw(uint256 id) external {
        Draw storage d = draws[id];
        if (d.executed || d.cancelled) revert InsuranceStaking_DrawClosed();
        if (block.timestamp < d.executableAt) revert InsuranceStaking_DrawNotExecutable();
        if (block.timestamp >= uint256(d.executableAt) + DRAW_EXECUTION_WINDOW) revert InsuranceStaking_DrawClosed();
        // Re-checked: deposits and exits are paused while the draw is pending, but a donation or a
        // second draw executed first can still move totalAssets.
        if (d.amount > drawCap()) revert InsuranceStaking_DrawAboveCap();
        d.executed = true;
        IERC20(asset()).safeTransfer(d.vault, d.amount);
        emit DrawExecuted(id, d.vault, d.amount, totalAssets());
    }

    function cancelDraw(uint256 id) external {
        if (msg.sender != governance) revert InsuranceStaking_OnlyGovernance();
        Draw storage d = draws[id];
        if (d.executed || d.cancelled) revert InsuranceStaking_DrawClosed();
        d.cancelled = true;
        emit DrawCancelled(id);
    }
}
