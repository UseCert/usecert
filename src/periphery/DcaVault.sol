// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

/// @dev The slice of CertFactory DcaVault reads.
interface IDcaCertFactory {
    function isVault(address vault) external view returns (bool);
}

/// @dev The slice of CertVault DcaVault reads and calls. The mintReceipts getter is positional and
///      frozen (see CertVault.MintReceipt), so decoding it here is stable.
interface IDcaCertVault {
    function requestMint(uint256 amountIn) external returns (uint256 receiptId);
    function mintReceipts(uint256 receiptId)
        external
        view
        returns (
            address user,
            uint256 escrow,
            bool settled,
            uint256 requestPx18,
            uint64 requestedAt,
            bool refundStaged,
            uint256 indicativeCerts
        );
    function mintFee(uint256 receiptId) external view returns (uint256);
    function certificate() external view returns (address);
    function venueMinNotional18() external view returns (uint256);
    function cfg()
        external
        view
        returns (
            address collateral,
            uint16 collateralAssetIndex,
            uint8 routeType,
            uint16 marketIndex,
            uint8 sizeDecimals,
            uint256 mintFeeBps,
            uint256 redeemFeeBps,
            uint256 instantCap18,
            uint256 settleBandBps,
            uint256 targetMarginBps
        );
}

/// @title DcaVault - dollar-cost averaging into UseCert certificates
/// @notice A user schedules a fixed USDG amount per period into one registered CertVault. Anyone
///         may execute a due period; it calls the vault's requestMint, and the certificates (or,
///         if the keeper never settles, the refunded escrow and fee) are delivered to the user by
///         a permissionless `forward`.
///
/// @dev CUSTODY: allowance, not deposit. The user's USDG stays in the user's wallet until the
///      moment a period executes; `execute` pulls exactly one period's amount and hands exactly
///      that amount to CertVault.requestMint in the same transaction, and checks that its own
///      balance is unchanged across the call. So there is no pooled principal here to steal,
///      mis-account or strand, no withdraw path to get wrong, and the user can stop everything
///      without this contract's cooperation by revoking the allowance. A deposit design would
///      hold every user's future periods in one balance for the whole schedule; it buys nothing
///      except not needing the allowance, and the allowance is exactly the right shape of consent.
///
///      What this contract DOES hold, briefly, is what CertVault delivers to the receipt's user -
///      which is this contract, because requestMint records msg.sender and mints / refunds to it
///      (it has no beneficiary argument). Per receipt that is exactly one of:
///        - settled by the settler (settleMint, inside the settle window): `indicativeCerts`
///          certificates, minted to this contract;
///        - refunded after the window (stageRefund + refundMint, both permissionless on the
///          vault): `escrow + mintFee` USDG, paid to this contract.
///      The two are told apart without ambiguity: settleMint requires the window to be OPEN and
///      stageRefund requires it to be CLOSED, so `settled && !refundStaged` is a mint and
///      `settled && refundStaged` is a refund. `forward` pays that exact amount to the receipt's
///      owner, once, and deletes the record.
///
///      NOTHING CAN GET STUCK. (1) Every receipt ends settled: settleMint in the window, or the
///      vault's own permissionless refund after it (CertVault's Law 2). (2) `forward` is
///      permissionless and takes no input but the receipt id, so any party can deliver. (3) The
///      balance is always sufficient: the only inflows of certificates and of refunded USDG are
///      the vault's settlement / refund of receipts recorded here, each of exactly the amount
///      `forward` later sends, and each record is forwarded at most once; `execute` nets to zero
///      in USDG (checked); and this contract never redeems, so the vault never burns from it.
///      (4) If the owner cannot receive (a frozen USDG address), the owner may name another
///      recipient with `forwardTo`. Tokens sent to this contract by anyone else belong to no
///      record and are not recoverable: there is no owner to recover them.
///
///      SKIPS. A period is executable only inside its window `[due, due + window]`, with
///      window <= period, set by the user. Everything that makes the vault unmintable -
///      mintAllowed false (stale mark, corporate action, the weekend), capacity exhausted, a
///      retired vault, a venue minimum not met - makes requestMint REVERT, which reverts the
///      whole execution, pull included: the user is not charged and the period stays due until
///      its window closes (deferral, bounded by the window). A period whose window closes
///      unexecuted is missed for good; it is never caught up later at another price, and the
///      next execution reports it (PeriodsMissed). No try/catch anywhere, on purpose: a caught
///      failure is where a keeper could starve the call of gas and get a period marked done.
///
///      KEEPER TIP. Optional and opt-in: the user fixes a per-execution `tip` at creation (0 for
///      none), capped at min(MAX_TIP, 1% of the amount). It is paid from the user's wallet directly
///      to whoever executed, and only when a mint request was actually made. It is not returned if
///      the vault later refunds that mint: it paid for the execution transaction, which happened.
///      This contract itself takes no fee of any kind; the vault's mint fee is the only protocol
///      fee, and a refund returns it.
///
///      No owner, no pause, no upgrade, no admin setter. Every state change emits an event.
contract DcaVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------------------ errors

    error DcaVault_ZeroAddress();
    error DcaVault_UnsupportedToken();
    error DcaVault_UnknownVault();
    error DcaVault_WrongCollateral();
    error DcaVault_BelowVenueMinimum();
    error DcaVault_BadPeriod();
    error DcaVault_BadWindow();
    error DcaVault_BadPeriodCount();
    error DcaVault_BadStart();
    error DcaVault_TipTooHigh();
    error DcaVault_UnknownSchedule();
    error DcaVault_NotScheduleOwner();
    error DcaVault_Cancelled();
    error DcaVault_NotDue();
    error DcaVault_AlreadyExecuted();
    error DcaVault_WindowClosed();
    error DcaVault_Finished();
    error DcaVault_BadPull();
    error DcaVault_BadMint();
    error DcaVault_UnknownReceipt();
    error DcaVault_NotFinal();

    // ------------------------------------------------------------------------------ events

    event ScheduleCreated(
        uint256 indexed scheduleId,
        address indexed owner,
        address indexed vault,
        uint256 amount,
        uint256 start,
        uint256 period,
        uint256 window,
        uint256 periods,
        uint256 tip
    );
    event Executed(
        uint256 indexed scheduleId,
        uint256 indexed periodIndex,
        uint256 indexed receiptId,
        address vault,
        uint256 amount,
        address keeper,
        uint256 tip
    );
    /// @notice Periods `fromIndex..toIndex` (inclusive) closed their window unexecuted. Nothing was
    ///         charged for them.
    event PeriodsMissed(uint256 indexed scheduleId, uint256 fromIndex, uint256 toIndex);
    event Cancelled(uint256 indexed scheduleId, uint256 nextPeriodIndex);
    event CertificatesForwarded(
        address indexed vault, uint256 indexed receiptId, address indexed to, uint256 scheduleId, uint256 certs
    );
    event RefundForwarded(
        address indexed vault, uint256 indexed receiptId, address indexed to, uint256 scheduleId, uint256 amount
    );

    // ------------------------------------------------------------------------------ constants

    uint256 public constant MIN_PERIOD = 1 days;
    /// @notice The shortest execution window a period may have.
    uint256 public constant MIN_WINDOW = 1 hours;
    /// @notice The most periods one schedule may have (about 27 years of daily buys).
    uint256 public constant MAX_PERIODS = 10_000;
    /// @notice How far ahead a schedule may start.
    uint256 public constant MAX_START_DELAY = 365 days;
    /// @notice Headroom over the vault's venue minimum notional a period's net amount must clear,
    ///         in bps, so the vault's quantisation dust does not turn every period into a miss.
    uint256 public constant MIN_HEADROOM_BPS = 100;
    /// @notice The tip may be at most this share of the period amount, in bps (1%).
    uint256 public constant MAX_TIP_BPS = 100;

    // ------------------------------------------------------------------------------ immutables

    IDcaCertFactory public immutable factory;
    IERC20 public immutable usdg;
    /// @notice Absolute ceiling on a per-execution tip: one whole USDG.
    uint256 public immutable MAX_TIP;
    uint256 private immutable _unit18;

    // ------------------------------------------------------------------------------ state

    struct Schedule {
        address owner;
        uint64 start; // due time of period 0
        uint32 period; // seconds between due times
        uint32 window; // seconds after a due time the period stays executable
        address vault;
        uint32 periods; // total number of periods
        uint32 next; // first period index not yet executed or missed
        bool cancelled;
        uint128 amount; // USDG per period
        uint128 tip; // USDG to the executor per execution
    }

    struct Pending {
        address owner;
        uint64 scheduleId;
        uint256 amount; // what execute handed to requestMint
    }

    uint256 public nextScheduleId = 1;
    mapping(uint256 => Schedule) public schedules;
    /// @notice Receipts this contract holds for users, by vault and the vault's receipt id.
    mapping(address => mapping(uint256 => Pending)) public pending;

    constructor(address factory_, address usdg_) {
        if (factory_ == address(0) || usdg_ == address(0)) revert DcaVault_ZeroAddress();
        uint8 dec = IERC20Metadata(usdg_).decimals();
        if (dec > 18) revert DcaVault_UnsupportedToken();
        factory = IDcaCertFactory(factory_);
        usdg = IERC20(usdg_);
        MAX_TIP = 10 ** dec;
        _unit18 = 10 ** (18 - dec);
    }

    // ------------------------------------------------------------------------------ schedules

    /// @notice Schedule `periods` buys of `amount` USDG into `vault`, the first due at `start`
    ///         (0 = now) and then every `period` seconds, each executable for `window` seconds
    ///         after it falls due. Approve this contract for amount + tip per period; nothing is
    ///         taken now. The schedule ends at start + periods x period.
    function createSchedule(
        address vault,
        uint256 amount,
        uint256 period,
        uint256 window,
        uint256 periods,
        uint256 start,
        uint256 tip
    ) external nonReentrant returns (uint256 id) {
        if (!factory.isVault(vault)) revert DcaVault_UnknownVault();
        (address collateral,,,,, uint256 feeBps,,,,) = IDcaCertVault(vault).cfg();
        if (collateral != address(usdg)) revert DcaVault_WrongCollateral();
        if (amount == 0 || amount > type(uint128).max) revert DcaVault_BelowVenueMinimum();
        // Net of the vault's fee, with headroom for its quantisation. The vault's own check at
        // execution stays authoritative; a period that fails it reverts uncharged.
        uint256 net18 = (amount - amount * feeBps / 10_000) * _unit18;
        uint256 min18 = IDcaCertVault(vault).venueMinNotional18();
        if (net18 == 0 || net18 * 10_000 < min18 * (10_000 + MIN_HEADROOM_BPS)) revert DcaVault_BelowVenueMinimum();
        if (period < MIN_PERIOD || period > type(uint32).max) revert DcaVault_BadPeriod();
        if (window < MIN_WINDOW || window > period) revert DcaVault_BadWindow();
        if (periods == 0 || periods > MAX_PERIODS) revert DcaVault_BadPeriodCount();
        if (start == 0) start = block.timestamp;
        if (start < block.timestamp || start > block.timestamp + MAX_START_DELAY) revert DcaVault_BadStart();
        if (tip > MAX_TIP || tip * 10_000 > amount * MAX_TIP_BPS) revert DcaVault_TipTooHigh();

        id = nextScheduleId++;
        schedules[id] = Schedule({
            owner: msg.sender,
            start: uint64(start),
            period: uint32(period),
            window: uint32(window),
            vault: vault,
            periods: uint32(periods),
            next: 0,
            cancelled: false,
            amount: uint128(amount),
            tip: uint128(tip)
        });
        emit ScheduleCreated(id, msg.sender, vault, amount, start, period, window, periods, tip);
    }

    /// @notice Stop a schedule for good. Owner only. Receipts already requested are unaffected and
    ///         still forward to the owner.
    function cancel(uint256 id) external nonReentrant {
        Schedule storage s = schedules[id];
        if (s.owner == address(0)) revert DcaVault_UnknownSchedule();
        if (msg.sender != s.owner) revert DcaVault_NotScheduleOwner();
        if (s.cancelled) revert DcaVault_Cancelled();
        s.cancelled = true;
        emit Cancelled(id, s.next);
    }

    /// @notice Execute the period that is due now. Permissionless. Pulls the period's amount from
    ///         the owner, requests the mint, and pays the owner's tip (if any) to the caller.
    ///         Reverts - charging nothing - if no period is inside its window, if it was already
    ///         executed, or if the vault refuses the mint.
    function execute(uint256 id) external nonReentrant returns (uint256 receiptId) {
        Schedule storage s = schedules[id];
        if (s.owner == address(0)) revert DcaVault_UnknownSchedule();
        if (s.cancelled) revert DcaVault_Cancelled();
        if (block.timestamp < s.start) revert DcaVault_NotDue();
        uint256 k = (block.timestamp - s.start) / s.period;
        if (k >= s.periods) revert DcaVault_Finished();
        if (k < s.next) revert DcaVault_AlreadyExecuted();
        if (block.timestamp > uint256(s.start) + k * s.period + s.window) revert DcaVault_WindowClosed();

        if (k > s.next) emit PeriodsMissed(id, s.next, k - 1);
        s.next = uint32(k + 1);

        address owner = s.owner;
        IDcaCertVault vault = IDcaCertVault(s.vault);
        uint256 amount = s.amount;
        uint256 tip = s.tip;

        // Exactly `amount` in, exactly `amount` out to the vault: this contract's USDG balance is
        // the same after as before, so no other user's delivered-but-unforwarded refund is touched.
        uint256 balBefore = usdg.balanceOf(address(this));
        usdg.safeTransferFrom(owner, address(this), amount);
        if (usdg.balanceOf(address(this)) != balBefore + amount) revert DcaVault_BadPull();
        usdg.forceApprove(address(vault), amount);
        receiptId = vault.requestMint(amount);
        usdg.forceApprove(address(vault), 0);
        if (usdg.balanceOf(address(this)) != balBefore) revert DcaVault_BadPull();

        (address user,,,,,,) = vault.mintReceipts(receiptId);
        if (user != address(this) || pending[address(vault)][receiptId].owner != address(0)) {
            revert DcaVault_BadMint();
        }
        pending[address(vault)][receiptId] = Pending({owner: owner, scheduleId: uint64(id), amount: amount});

        if (tip != 0) usdg.safeTransferFrom(owner, msg.sender, tip);

        emit Executed(id, k, receiptId, address(vault), amount, msg.sender, tip);
    }

    // ------------------------------------------------------------------------------ delivery

    /// @notice Deliver a finished receipt's certificates, or its refund, to its owner.
    ///         Permissionless. Reverts DcaVault_NotFinal while the vault has neither settled nor
    ///         refunded it (a refund after the settle window is itself permissionless on the vault:
    ///         stageRefund, then refundMint).
    function forward(address vault, uint256 receiptId) external nonReentrant returns (uint256) {
        address owner = pending[vault][receiptId].owner;
        if (owner == address(0)) revert DcaVault_UnknownReceipt();
        return _forward(vault, receiptId, owner);
    }

    /// @notice As forward, to a recipient of the owner's choosing (e.g. when the owner's address
    ///         cannot receive USDG). Owner only.
    function forwardTo(address vault, uint256 receiptId, address to) external nonReentrant returns (uint256) {
        address owner = pending[vault][receiptId].owner;
        if (owner == address(0)) revert DcaVault_UnknownReceipt();
        if (msg.sender != owner) revert DcaVault_NotScheduleOwner();
        if (to == address(0)) revert DcaVault_ZeroAddress();
        return _forward(vault, receiptId, to);
    }

    function _forward(address vault, uint256 receiptId, address to) internal returns (uint256 out) {
        Pending memory p = pending[vault][receiptId];
        (, uint256 escrow, bool settled,,, bool refundStaged, uint256 certs) =
            IDcaCertVault(vault).mintReceipts(receiptId);
        if (!settled) revert DcaVault_NotFinal();
        delete pending[vault][receiptId];

        if (!refundStaged) {
            // settleMint: exactly indicativeCerts were minted to this contract.
            out = certs;
            IERC20(IDcaCertVault(vault).certificate()).safeTransfer(to, out);
            emit CertificatesForwarded(vault, receiptId, to, p.scheduleId, out);
        } else {
            // refundMint: exactly escrow + mintFee was paid to this contract. Never more than was
            // put in (the vault credits at most what it received).
            out = escrow + IDcaCertVault(vault).mintFee(receiptId);
            if (out > p.amount) out = p.amount;
            usdg.safeTransfer(to, out);
            emit RefundForwarded(vault, receiptId, to, p.scheduleId, out);
        }
    }

    // ------------------------------------------------------------------------------ views

    /// @notice The period `execute` would run now, if any.
    /// @return ok True if a period is inside its window and not yet executed (the vault, the
    ///         allowance and the balance may still refuse it).
    /// @return periodIndex That period, or the next one to fall due.
    /// @return dueAt Its due time (0 once the schedule has run out of periods).
    function nextExecution(uint256 id) external view returns (bool ok, uint256 periodIndex, uint256 dueAt) {
        Schedule memory s = schedules[id];
        if (s.owner == address(0) || s.cancelled) return (false, 0, 0);
        if (block.timestamp < s.start) return (false, s.next, s.start);
        uint256 k = (block.timestamp - s.start) / s.period;
        if (k < s.next) k = s.next;
        if (k >= s.periods) return (false, k, 0);
        dueAt = uint256(s.start) + k * s.period;
        ok = block.timestamp >= dueAt && block.timestamp <= dueAt + s.window;
        periodIndex = k;
    }

    /// @notice The owner's total USDG per execution (amount + tip): the allowance a period needs.
    function perExecution(uint256 id) external view returns (uint256) {
        Schedule memory s = schedules[id];
        return uint256(s.amount) + s.tip;
    }
}
