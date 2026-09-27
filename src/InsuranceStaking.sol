// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC4626} from "openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";

/// @notice The subset of CertFactory this contract reads: which addresses are real vaults, and
///         since when.
interface IVaultRegistry {
    function isVault(address vault) external view returns (bool);
    /// @dev 0 for an address that was never registered. Written once, never changed.
    function registeredAt(address vault) external view returns (uint64);
}

/// @notice What a vault must expose to be paid by a draw.
/// @dev Implemented by CertVault from stack 5. The pool trusts a registered vault to report its own
///      shortfall honestly and to book what `receiveInsurance` pulls as capital that backs holders
///      and can never be swept out (not as fees, and not to governance through sweepRetired). That
///      trust is bounded by the registration delay, the per-draw and rolling caps below: see the
///      contract NatSpec for exactly what a dishonest registered contract can take.
interface IInsurableVault {
    function retired() external view returns (bool);
    /// @notice How much collateral the vault needs from insurance right now; 0 when it needs none.
    function insuranceShortfall() external view returns (uint256);
    /// @notice Pull exactly `amount` of collateral from the caller (it has approved exactly that).
    function receiveInsurance(uint256 amount) external;
}

/// @title InsuranceStaking v2 — the insurance rung of the loss order: buffer -> THIS -> (never) holders
/// @notice Stakers deposit the vaults' own collateral (USDG) and receive shares. A draw moves
///         collateral from here into a registered vault that declares a shortfall, where it backs
///         holders; every share absorbs the loss pro rata. Income sent here (fees, returned draws,
///         donations) vests into the share price over VESTING_PERIOD. See
///         docs/K-INSURANCE-STAKING.md for why each rule exists.
/// @dev Stack 5. Immutable: no owner, no upgrade path, no parameter setters. The only privileged
///      role is `governance`'s right to propose and cancel draws.
///
///      WHAT CHANGED FROM v1 (internal pre-audit 2026-09-27), each with its reason:
///
///      H-9 (was M-1) — the cooldown could be bypassed. A v1 request was a number attached to an
///      address, and shares stayed transferable, so a staker could keep staggered requests on a few
///      addresses and move the shares to whichever had an open window: an instant exit whenever no
///      draw was pending. v2 ESCROWS requested shares: requestWithdraw moves them into this contract,
///      where nobody can transfer them (see _update), and redeem burns from the escrow. Escrowed
///      shares still count in totalSupply, so they keep earning and keep absorbing draws.
///
///      M-14 — deposit, distribute and redeem in one transaction. Income used to step the share
///      price the moment it arrived, and the arrival is caller-timed (sweepFees and distribute are
///      permissionless). v2 VESTS income linearly over VESTING_PERIOD: an arrival nobody has synced
///      yet counts as wholly unvested, sync() starts it vesting, and a new arrival rolls any unvested
///      remainder into one fresh schedule. Nothing that arrives can raise totalAssets() inside the
///      transaction it arrives in. Income that arrives while there are no shares is held unvested
///      until there are, then vests (pre-audit L-3: v1 let the virtual shares absorb it).
///
///      M-2 — a draw's pause (drawDelay + DRAW_EXECUTION_WINDOW) could outlast a withdraw window,
///      so a well-timed 1-unit proposal could close a chosen staker's window every time. v2 requires
///      the window to be at least a day longer than the longest pause.
///
///      H-3 — governance could route the pool back to itself: propose a capped draw to an empty
///      vault, retire it, sweep it to governance, repeat weekly. v2: the target must have been
///      registered for `registrationDelay` (longer than a full cooldown plus window, so every
///      staker can leave after a registration they do not trust), must not be retired, and must
///      declare a shortfall that caps the draw; the draw pays through the vault's receiveInsurance
///      with an exact allowance and an exact balance check; and executed draws are capped at
///      `maxDrawBps` across any rolling DRAW_CAP_PERIOD, not only per draw.
///
///      L-16 — the deposit cap used to bound totalAssets(), so income and donations closed the pool
///      to new stakers. v2 bounds net principal: deposits in, minus principal withdrawn (pro rata).
///
///      L-14 — shares that are NOT in escrow stay transferable during a pending draw. That is
///      accepted: a transfer moves exposure between two stakers, it takes nothing out of the pool,
///      and the receiver cannot redeem without its own request and cooldown.
///
///      WHAT A COMPROMISED GOVERNANCE SAFE CAN STILL DO: register a contract of its own in the
///      factory, wait `registrationDelay` in public, then propose draws to it; that contract can
///      claim any shortfall and keep what it pulls. Each such draw waits `drawDelay` in public, and
///      together they take at most `maxDrawBps` of the pool per DRAW_CAP_PERIOD. Every staker has a
///      full cooldown and window between the registration and the first draw it allows. What the
///      Safe can NOT do: draw to a vault that was just registered, to a retired vault, to a vault
///      that declares no shortfall, more than the vault declares, more than the rolling cap, or
///      outside the proposal gap and draw windows; hold a staker in place across a whole window;
///      or touch escrowed shares, the vesting schedule or the deposit cap.
contract InsuranceStaking is ERC4626, ReentrancyGuard {
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
    /// @dev H-9: escrowed shares cannot move except back to their owner or into a burn, and shares
    ///      cannot be sent into the escrow except by requestWithdraw.
    error InsuranceStaking_EscrowedShares();
    /// @dev H-3: the target was registered less than `registrationDelay` ago.
    error InsuranceStaking_VaultTooNew();
    error InsuranceStaking_VaultRetired();
    error InsuranceStaking_NoShortfall();
    /// @dev H-3: the vault did not pull exactly the amount drawn.
    error InsuranceStaking_DrawNotPaid();

    event WithdrawRequested(address indexed owner, uint256 shares, uint64 readyAt, uint64 closesAt);
    event WithdrawRequestCancelled(address indexed owner, uint256 shares);
    event DrawProposed(uint256 indexed id, address indexed vault, uint256 amount, uint64 executableAt, uint64 expiresAt);
    event DrawExecuted(uint256 indexed id, address indexed vault, uint256 amount, uint256 assetsAfter);
    event DrawCancelled(uint256 indexed id);
    /// @notice `incoming` USDG was found that no deposit brought; `unvested` now vests until `vestsBy`.
    event IncomeSynced(uint256 incoming, uint256 unvested, uint64 vestsBy);

    /// @notice How long a proposed draw stays executable once its delay has passed.
    uint256 public constant DRAW_EXECUTION_WINDOW = 3 days;
    uint256 public constant MAX_DRAW_BPS_BOUND = 5_000;
    /// @notice Minimum time between two draw proposals. Exits pause while a draw is pending, so
    ///         without a gap governance could re-propose forever and hold every staker in place.
    ///         7 days against drawDelay + DRAW_EXECUTION_WINDOW (<= 6 days) leaves exits open for at
    ///         least a day between cycles. The constructor makes drawDelay small enough for that.
    uint256 public constant MIN_PROPOSAL_GAP = 7 days;
    /// @notice H-3: executed draws within any window of this length are capped, in total, at
    ///         `maxDrawBps` of the assets the pool had at the start of that window. See drawCap().
    uint256 public constant DRAW_CAP_PERIOD = 30 days;
    /// @notice M-14: how long income takes to vest fully into the share price. Long enough that
    ///         capturing income means holding shares, exposed to draws, for days rather than for a
    ///         transaction; short enough that stakers are paid within one CertStaking-length period.
    ///         A constant rather than a constructor argument: the constructor is at the EVM's stack
    ///         limit, and nothing about a deployment should tune it.
    uint256 public constant VESTING_PERIOD = 7 days;

    address public immutable governance;
    IVaultRegistry public immutable registry;
    uint256 public immutable cooldown;
    uint256 public immutable withdrawWindow;
    uint256 public immutable drawDelay;
    uint256 public immutable maxDrawBps;
    /// @notice The most net principal (deposits minus principal withdrawn) the pool may hold.
    ///         Immutable: the deployment is unaudited, and a hard ceiling is what bounds what anyone
    ///         can lose to a bug in it. L-16: income and donations do not count against it.
    uint256 public immutable depositCap;
    /// @notice H-3: how long a vault must have been registered before a draw can be proposed to or
    ///         executed into it. At least cooldown + withdrawWindow, so every staker can finish a
    ///         withdrawal between a registration and the first draw it makes possible.
    uint256 public immutable registrationDelay;

    struct WithdrawRequest {
        uint256 shares; // held in escrow by this contract
        uint64 readyAt;
    }

    struct Draw {
        address vault;
        uint256 amount; // proposed; the most it may pay
        uint64 executableAt;
        bool executed;
        bool cancelled;
        uint64 executedAt;
        uint256 paid; // what it paid, at most `amount`, capped at the vault's shortfall
    }

    mapping(address => WithdrawRequest) public withdrawRequests;
    Draw[] public draws;
    uint256 public lastProposalAt;

    /// @notice L-16: principal deposited and not yet withdrawn. A withdrawal of `shares` removes
    ///         `netPrincipal * shares / totalSupply` (rounded down, so the cap errs tight), which is
    ///         exactly the share of principal those shares carry; the last shares out remove the rest.
    ///         A draw does not reduce it: that principal was deposited and is still at risk.
    uint256 public netPrincipal;

    /// @notice M-14: the USDG balance the pool has accounted for. Every flow the pool makes itself
    ///         (deposit, withdrawal, draw) moves it with the balance; anything else that raises the
    ///         balance is income, and sync() finds it as the difference.
    uint256 public accountedBalance;
    /// @notice Income still vesting as of `vestingCheckpoint`; it vests linearly to 0 at `vestingEnd`.
    uint256 public vestingRemaining;
    uint64 public vestingCheckpoint;
    uint64 public vestingEnd;

    constructor(
        IERC20 asset_,
        IVaultRegistry registry_,
        address governance_,
        uint256 cooldown_,
        uint256 withdrawWindow_,
        uint256 drawDelay_,
        uint256 maxDrawBps_,
        uint256 depositCap_,
        uint256 registrationDelay_,
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
                // M-2: a window must outlast the longest pause by at least a day, so no proposal,
                // however timed, can close a staker's whole window. Proposals are MIN_PROPOSAL_GAP
                // apart and a pause ends at least a day before the next can start, so a window
                // overlapping two pauses also has at least a day open between them.
                || withdrawWindow_ < drawDelay_ + DRAW_EXECUTION_WINDOW + 1 days
                // H-3: a registration must be public for longer than a full exit takes
                || registrationDelay_ < cooldown_ + withdrawWindow_
                || depositCap_ == 0
        ) revert InsuranceStaking_BadConfig();
        governance = governance_;
        registry = registry_;
        cooldown = cooldown_;
        withdrawWindow = withdrawWindow_;
        drawDelay = drawDelay_;
        maxDrawBps = maxDrawBps_;
        depositCap = depositCap_;
        registrationDelay = registrationDelay_;
    }

    // ------------------------------------------------------------------ income vesting (M-14)

    /// @notice Assets that back shares right now: the balance minus income not yet vested. An
    ///         arrival not yet synced is wholly unvested, so no transfer in can raise this in the
    ///         transaction it arrives in. Never more than the balance.
    function totalAssets() public view override returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 locked = unvestedIncome();
        return bal > locked ? bal - locked : 0;
    }

    /// @notice Income in the balance that is not yet part of the share price: the running schedule's
    ///         remainder plus any arrival nobody has synced yet.
    function unvestedIncome() public view returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 pending = bal > accountedBalance ? bal - accountedBalance : 0;
        return _scheduledUnvested() + pending;
    }

    /// @notice Start any unsynced income vesting. Permissionless: it can only ever start a
    ///         schedule for USDG that is really here, and it never changes totalAssets() at the
    ///         moment it runs. Every deposit, withdrawal and draw also syncs first.
    function sync() external nonReentrant {
        _sync();
    }

    /// @dev What the schedule still holds back. With no shares in existence nothing vests: the
    ///      remainder is frozen until someone deposits (pre-audit L-3), and the first deposit's sync
    ///      restarts the full period from that moment. Rounded up, so totalAssets() errs low.
    function _scheduledUnvested() internal view returns (uint256) {
        if (totalSupply() == 0) return vestingRemaining;
        if (block.timestamp >= vestingEnd) return 0;
        return Math.mulDiv(
            vestingRemaining, vestingEnd - block.timestamp, vestingEnd - vestingCheckpoint, Math.Rounding.Ceil
        );
    }

    /// @dev Checkpoints the schedule at now and folds in any new arrival. Leaves totalAssets()
    ///      unchanged at this timestamp: the unvested amount before and after is the same, only its
    ///      future path changes. A new arrival, or any sync while there are no shares, restarts the
    ///      full period for the whole remainder; otherwise the end is kept, so a re-checkpoint does
    ///      not stretch anything. A balance that fell behind the pool's back (not possible with
    ///      USDG short of a seizure) is taken as it is, and the remainder is capped at it.
    function _sync() internal {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 incoming = bal > accountedBalance ? bal - accountedBalance : 0;
        uint256 remaining = _scheduledUnvested() + incoming;
        if (remaining > bal) remaining = bal;
        if (incoming > 0 || totalSupply() == 0) vestingEnd = uint64(block.timestamp + VESTING_PERIOD);
        vestingRemaining = remaining;
        vestingCheckpoint = uint64(block.timestamp);
        accountedBalance = bal;
        if (incoming > 0) emit IncomeSynced(incoming, remaining, vestingEnd);
    }

    // ------------------------------------------------------------------ withdrawals (H-9)

    /// @notice Start the cooldown for `shares`, moving them into escrow. Replaces any earlier
    ///         request and restarts its cooldown: the escrow is topped up or partly returned so it
    ///         holds exactly `shares`. Escrowed shares keep earning and keep absorbing draws until
    ///         they are redeemed or returned, and nobody can transfer them.
    function requestWithdraw(uint256 shares) external {
        if (shares == 0) revert InsuranceStaking_ZeroAmount();
        WithdrawRequest storage r = withdrawRequests[msg.sender];
        uint256 held = r.shares;
        if (shares > balanceOf(msg.sender) + held) revert InsuranceStaking_ExceedsBalance();
        uint64 readyAt = uint64(block.timestamp + cooldown);
        r.shares = shares;
        r.readyAt = readyAt;
        // super._update: the escrow's own moves bypass the transfer block in _update below.
        if (shares > held) super._update(msg.sender, address(this), shares - held);
        else if (held > shares) super._update(address(this), msg.sender, held - shares);
        emit WithdrawRequested(msg.sender, shares, readyAt, uint64(readyAt + withdrawWindow));
    }

    /// @notice Cancel the caller's request and return its escrowed shares. Works at any time,
    ///         including after the window has closed: that is how an expired request is reclaimed.
    function cancelWithdraw() external {
        uint256 shares = withdrawRequests[msg.sender].shares;
        delete withdrawRequests[msg.sender];
        if (shares > 0) super._update(address(this), msg.sender, shares);
        emit WithdrawRequestCancelled(msg.sender, shares);
    }

    /// @notice True while the owner's request is inside its redeem window.
    function withdrawOpen(address owner) public view returns (bool) {
        WithdrawRequest memory r = withdrawRequests[owner];
        return r.shares > 0 && block.timestamp >= r.readyAt && block.timestamp < uint256(r.readyAt) + withdrawWindow;
    }

    /// @notice Only escrowed shares can be redeemed, and only inside their window.
    function maxRedeem(address owner) public view override returns (uint256) {
        if (drawPending() || !withdrawOpen(owner)) return 0;
        return withdrawRequests[owner].shares;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return convertToAssets(maxRedeem(owner));
    }

    /// @notice L-16: room left under the cap on net principal. Income never uses it up.
    function maxDeposit(address) public view override returns (uint256) {
        if (drawPending()) return 0;
        return netPrincipal >= depositCap ? 0 : depositCap - netPrincipal;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    /// @dev Every exit path (withdraw and redeem) lands here. The checks are explicit rather than
    ///      left to ERC4626's max* guards so each refusal carries its own reason. Replaces
    ///      ERC4626._withdraw rather than extending it, because the shares burned are the escrowed
    ///      ones held by this contract, not the owner's free balance. `assets` was priced by the
    ///      caller (previewRedeem/previewWithdraw) before the sync, which does not move the price.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (drawPending()) revert InsuranceStaking_DrawPending();
        WithdrawRequest storage r = withdrawRequests[owner];
        if (r.shares == 0 || block.timestamp < r.readyAt) revert InsuranceStaking_CooldownNotReady();
        if (block.timestamp >= uint256(r.readyAt) + withdrawWindow) revert InsuranceStaking_WithdrawWindowClosed();
        if (shares > r.shares) revert InsuranceStaking_ExceedsCooldownShares();
        if (caller != owner) _spendAllowance(owner, caller, shares);
        _sync();
        netPrincipal -= Math.mulDiv(netPrincipal, shares, totalSupply());
        r.shares -= shares;
        accountedBalance -= assets;
        _burn(address(this), shares);
        IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (drawPending()) revert InsuranceStaking_DrawPending();
        if (netPrincipal + assets > depositCap) revert InsuranceStaking_AboveDepositCap();
        // Before the transfer in, so the deposit itself is never mistaken for income.
        _sync();
        netPrincipal += assets;
        accountedBalance += assets;
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev H-9: the escrow is closed to ordinary transfers in both directions. Nothing may send
    ///      shares into it (a mint or transfer to this contract would be shares nobody can
    ///      redeem), and nothing may move shares out of it except a burn. The escrow's own
    ///      moves (request, cancel) call super._update directly and so are not blocked here.
    function _update(address from, address to, uint256 value) internal override {
        if (to == address(this) || (from == address(this) && to != address(0))) {
            revert InsuranceStaking_EscrowedShares();
        }
        super._update(from, to, value);
    }

    /// @dev Virtual shares at 1e6 per unit of a 6-decimal asset: OZ's first-depositor
    ///      (donation / inflation) mitigation. Vesting makes a donation useless for it as well.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ------------------------------------------------------------------ draws (H-3)

    function drawCount() external view returns (uint256) {
        return draws.length;
    }

    /// @notice What executed draws paid in the last DRAW_CAP_PERIOD.
    /// @dev Scans from the newest draw backwards and stops at the first one that could not have
    ///      executed inside the period (executedAt < executableAt + DRAW_EXECUTION_WINDOW, and
    ///      executableAt only grows with the index). Proposals are MIN_PROPOSAL_GAP apart, so that is
    ///      at most a handful of entries.
    function drawnInPeriod() public view returns (uint256 sum) {
        for (uint256 i = draws.length; i > 0; i--) {
            Draw memory d = draws[i - 1];
            if (uint256(d.executableAt) + DRAW_EXECUTION_WINDOW + DRAW_CAP_PERIOD <= block.timestamp) break;
            if (d.executed && uint256(d.executedAt) + DRAW_CAP_PERIOD > block.timestamp) sum += d.paid;
        }
    }

    /// @notice The most one draw may take right now: what is left of the rolling cap.
    /// @dev The cap on a DRAW_CAP_PERIOD is `maxDrawBps` of the assets at its start, which the pool
    ///      reconstructs as the assets now plus what draws took inside the period:
    ///          drawn + next <= maxDrawBps * (totalAssets() + drawn) / 10_000
    ///      Checked at every proposal and execution over the trailing period ending then, this
    ///      bounds EVERY window of that length, not just fixed epochs: for any window, take its last
    ///      draw; the check at that draw summed every earlier draw in the window. Deposits, exits and
    ///      income move the base with the pool, which is what a percentage cap should follow; with
    ///      none of them the draws in any period total at most maxDrawBps of the pool at its start.
    ///      It is never more than the v1 per-draw cap, `maxDrawBps` of totalAssets(). Rounded down.
    function drawCap() public view returns (uint256) {
        uint256 drawn = drawnInPeriod();
        uint256 cap = (totalAssets() + drawn) * maxDrawBps / 10_000;
        return cap > drawn ? cap - drawn : 0;
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

    /// @dev H-3: a registered vault, registered long enough ago that every staker could have left
    ///      after seeing the registration, and not retired. Checked at proposal and again at
    ///      execution, because the pool does not trust that nothing changed during the delay.
    function _requireEligible(address vault) internal view {
        if (!registry.isVault(vault)) revert InsuranceStaking_NotAVault();
        uint256 at = registry.registeredAt(vault);
        if (at == 0 || block.timestamp < at + registrationDelay) revert InsuranceStaking_VaultTooNew();
        if (IInsurableVault(vault).retired()) revert InsuranceStaking_VaultRetired();
    }

    function proposeDraw(address vault, uint256 amount) external returns (uint256 id) {
        if (msg.sender != governance) revert InsuranceStaking_OnlyGovernance();
        _requireEligible(vault);
        if (amount == 0) revert InsuranceStaking_ZeroAmount();
        if (amount > drawCap()) revert InsuranceStaking_DrawAboveCap();
        if (lastProposalAt != 0 && block.timestamp < lastProposalAt + MIN_PROPOSAL_GAP) {
            revert InsuranceStaking_ProposalTooSoon();
        }
        lastProposalAt = block.timestamp;
        uint64 executableAt = uint64(block.timestamp + drawDelay);
        id = draws.length;
        draws.push(Draw(vault, amount, executableAt, false, false, 0, 0));
        emit DrawProposed(id, vault, amount, executableAt, uint64(executableAt + DRAW_EXECUTION_WINDOW));
    }

    /// @notice Permissionless once the delay has passed: governance decides, it cannot also stall.
    ///         Pays the smaller of the proposed amount and the vault's declared shortfall, through
    ///         the vault's receiveInsurance, and only if that is within the rolling cap.
    function executeDraw(uint256 id) external nonReentrant {
        Draw storage d = draws[id];
        if (d.executed || d.cancelled) revert InsuranceStaking_DrawClosed();
        if (block.timestamp < d.executableAt) revert InsuranceStaking_DrawNotExecutable();
        if (block.timestamp >= uint256(d.executableAt) + DRAW_EXECUTION_WINDOW) revert InsuranceStaking_DrawClosed();
        address vault = d.vault;
        _requireEligible(vault);
        uint256 shortfall = IInsurableVault(vault).insuranceShortfall();
        if (shortfall == 0) revert InsuranceStaking_NoShortfall();
        uint256 amount = d.amount < shortfall ? d.amount : shortfall;
        _sync();
        // Re-checked: deposits and exits are paused while the draw is pending, but income, a
        // balance change or an earlier draw leaving the period can still move the cap.
        if (amount > drawCap()) revert InsuranceStaking_DrawAboveCap();

        d.executed = true;
        d.executedAt = uint64(block.timestamp);
        d.paid = amount;

        IERC20 usdg = IERC20(asset());
        uint256 before = usdg.balanceOf(address(this));
        usdg.forceApprove(vault, amount);
        IInsurableVault(vault).receiveInsurance(amount);
        usdg.forceApprove(vault, 0);
        // Exactly `amount` must have left: less would leave an allowance-free draw half done, more
        // is impossible without another path out, and a rise means the call deposited or donated
        // mid-draw. nonReentrant already shuts the pool's own entry points during the call.
        if (usdg.balanceOf(address(this)) + amount != before) revert InsuranceStaking_DrawNotPaid();
        accountedBalance = before - amount;
        emit DrawExecuted(id, vault, amount, totalAssets());
    }

    function cancelDraw(uint256 id) external {
        if (msg.sender != governance) revert InsuranceStaking_OnlyGovernance();
        Draw storage d = draws[id];
        if (d.executed || d.cancelled) revert InsuranceStaking_DrawClosed();
        d.cancelled = true;
        emit DrawCancelled(id);
    }
}
