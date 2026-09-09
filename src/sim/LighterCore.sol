// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ILighter} from "../interfaces/ILighter.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Shared venue mechanics for every UseCert Lighter stand-in: one behaviour
///         implementation behind two front ends (`MockLighter` for the suite, `LighterSim` for
///         testnet).
///
/// @dev EXTRACTED VERBATIM from `test/mocks/MockLighter.sol` (Task 4). The mechanics below are the
///      semantics the 258-test suite certifies — margin enforcement with `InsufficientMargin()`,
///      mark-to-market PnL with volume-weighted entry-price tracking, asynchronous priority-queue
///      fills (orders NEVER fill in the calling transaction), `getPendingBalance` /
///      `withdrawPendingBalance`, account registration, and `depositCapTicks` refusal. Nothing
///      here was changed: a copy would silently drift from the contract those unit tests certify,
///      which is the whole reason this is an extraction rather than a fork.
///
///      `abstract` is deliberate. LighterCore is not a front end and must never be deployable on
///      its own: once Task 5 puts access control on `LighterSim`, a concrete — and therefore
///      deployable — LighterCore would be a standing bypass of that gating. Deploy `LighterSim`.
///
///      Three things this base deliberately does NOT have, because `LighterSim` would inherit
///      them: the configuration setters (`setMarkPrice`, `setRequiredMarginBps`,
///      `setDepositCapTicks`), the fault-injection flags, and the counterparty-collateral mint in
///      `_fundPending()`. All of those live on `MockLighter`, and none of them exists on the real
///      venue. Global Constraint 5 — the simulator must never be easier than mainnet — is why.
abstract contract LighterCore is ILighter {
    struct Order {
        uint16 marketIndex;
        uint48 baseAmount;
        uint32 price;
        uint8 isAsk;
        uint8 orderType;
        /// @dev Task 5 (C1). The account that submitted this order, so `cancelAllOrders` can cancel
        ///      that account's orders and ONLY that account's. Previously the queue was anonymous
        ///      and `cancelAllOrders` ignored its argument and did `delete _queue`, so any address
        ///      could wipe the vault's hedge. 20 bytes total: still one storage slot.
        uint48 account;
    }

    error AccountIsNotRegistered();
    error MarketIndexTooHigh();
    error BadOrderType();
    error InsufficientMargin();
    error ZeroBaseAmount();
    error AboveDepositCap();
    /// @dev Task 5, item 7 (C1). The caller named an account index that is not its own.
    ///
    ///      This is VENUE FIDELITY, not UseCert access control, which is why it lives on the shared
    ///      core rather than on `LighterSim`: the real `ZkLighter` never takes the acting account on
    ///      trust from calldata, it derives it from the caller via
    ///      `validateAndGetAccountIndexFromAddress`. A simulator that accepts any index is a
    ///      simulator that is EASIER than mainnet, which Global Constraint 5 names as Critical — and
    ///      here it was also an unconditional drain of every depositor's collateral, since
    ///      `withdraw` credits `_pending[msg.sender]` out of a single global `marginBalance`.
    ///
    ///      `MockLighter` inherits this deliberately. The suite must run against the venue's real
    ///      authorisation model, not a looser one.
    error LighterCore_AccountNotCaller();

    IERC20 public immutable collateral;
    uint16 public immutable collateralAssetIndex;
    uint8 public immutable sizeDecimals;
    uint8 internal immutable _collateralDecimals;

    mapping(address => uint48) public addressToAccountIndex;
    uint48 private _nextAccountIndex = 3;

    /// @dev collateral posted as margin, in token units
    uint256 public marginBalance;
    /// @dev signed position size in base ticks (size_decimals applied by caller)
    mapping(uint16 => int256) public positionBase;
    /// @dev mark price scaled to 1e18
    mapping(uint16 => uint256) public markPrice;
    /// @dev M3: volume-weighted entry price per market, scaled to 1e18. Zero when flat.
    mapping(uint16 => uint256) public entryPrice;
    /// @dev required margin as a fraction of resulting notional, in bps. Default 5_000 (2x).
    uint256 public requiredMarginBps = 5_000;
    /// @dev Mirrors AssetConfig.depositCapTicks on the real contract, which withdraw() validates
    ///      `_baseAmount` against. Defaults large so existing tests are unaffected.
    uint256 public depositCapTicks = type(uint64).max;

    /// @dev `internal`, not `private`, only so `MockLighter.queuedOrderCount()` / `lastOrder()`
    ///      can read it. Those two introspection helpers are test-only and stay off this base.
    Order[] internal _queue;
    mapping(address => mapping(uint16 => uint128)) private _pending;
    /// @dev Every market this contract has ever filled, so unrealisedPnl() can sum across them.
    uint16[] internal _markets;
    mapping(uint16 => bool) private _tracked;
    /// @dev Sum of all credited-but-undrained pending balances. `MockLighter._fundPending()`
    ///      reads it to keep the mock's real token holdings sufficient to honour them.
    uint256 internal _pendingTotal;

    constructor(IERC20 _collateral, uint16 _collateralAssetIndex, uint8 _sizeDecimals) {
        collateral = _collateral;
        collateralAssetIndex = _collateralAssetIndex;
        sizeDecimals = _sizeDecimals;
        _collateralDecimals = IERC20Metadata(address(_collateral)).decimals();
    }

    // ------------------------------------------------------------------------ ILighter surface

    function deposit(address to, uint16, uint8, uint256 amount) public payable virtual {
        collateral.transferFrom(msg.sender, address(this), amount);
        marginBalance += amount;
        if (addressToAccountIndex[to] == 0) {
            addressToAccountIndex[to] = _nextAccountIndex++;
        }
    }

    function createOrder(
        uint48 accountIndex,
        uint16 marketIndex,
        uint48 baseAmount,
        uint32 price,
        uint8 isAsk,
        uint8 orderType
    ) public virtual {
        if (accountIndex == 0) revert AccountIsNotRegistered();
        _requireCallerOwnsAccount(accountIndex);
        if (marketIndex > 254) revert MarketIndexTooHigh();
        if (orderType > 1) revert BadOrderType();
        _queue.push(Order(marketIndex, baseAmount, price, isAsk, orderType, accountIndex));
    }

    /// @dev Models AdditionalZkLighter.withdraw() on the real contract: it does NOT check the
    ///      account's balance — sufficiency is decided inside the rollup, not on-chain. It only
    ///      validates baseAmount != 0 and baseAmount <= depositCapTicks before enqueuing a
    ///      priority request. So this must not revert on insufficiency; instead it credits only
    ///      min(baseAmount, equity()) to pending, modelling a rollup batch that fulfills what it
    ///      can and strands the rest — which is how an oversized request would actually behave on
    ///      the real venue.
    ///
    ///      M3: the ceiling is equity(), not marginBalance. A withdrawal that draws on the
    ///      position's gain realises exactly the amount the cash balance cannot cover (moving
    ///      entryPrice toward markPrice so the same gain is never paid twice) and then debits it.
    ///      Task 5, item 7 (C1): `accountIndex` must be the CALLER's. Before this, the only gate
    ///      was `accountIndex != 0`, and the credit went to `_pending[msg.sender]` out of a single
    ///      global `marginBalance` — so any address that had never deposited passed a literal
    ///      non-zero index, took `min(baseAmount, equity())` (every depositor's collateral) and
    ///      drained it with `withdrawPendingBalance`. Two transactions, no registration. Reproduced
    ///      against the deployable artefact before this line existed; see the Task 5 report.
    function withdraw(uint48 accountIndex, uint16 assetIndex, uint8, uint64 baseAmount) public virtual {
        if (accountIndex == 0) revert AccountIsNotRegistered();
        _requireCallerOwnsAccount(accountIndex);
        if (baseAmount == 0) revert ZeroBaseAmount();
        if (baseAmount > depositCapTicks) revert AboveDepositCap();

        uint256 available = equity();
        uint256 fulfilled = baseAmount <= available ? baseAmount : available;
        if (fulfilled > marginBalance) _realiseGain(fulfilled - marginBalance);
        marginBalance -= fulfilled;

        _pendingTotal += fulfilled;
        _fundPending();
        _pending[msg.sender][assetIndex] += uint128(fulfilled);
    }

    /// @notice Cancel every queued order belonging to `accountIndex`, and nothing else.
    /// @dev Task 5, item 7 (C1). This used to ignore its argument entirely and `delete _queue`, so
    ///      any address — registered or not — could wipe the vault's pending hedge. Two things
    ///      changed: the caller must own the account it names, and the cancellation is scoped to
    ///      that account's own orders via `Order.account`. The queue is compacted in place, which
    ///      preserves the relative order of the surviving entries — `settleBatch` fills in queue
    ///      order, so a cancellation must not reshuffle another account's priority.
    function cancelAllOrders(uint48 accountIndex) public virtual {
        if (accountIndex == 0) revert AccountIsNotRegistered();
        _requireCallerOwnsAccount(accountIndex);

        uint256 kept;
        uint256 n = _queue.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_queue[i].account == accountIndex) continue;
            if (kept != i) _queue[kept] = _queue[i];
            ++kept;
        }
        for (uint256 i = n; i > kept; --i) {
            _queue.pop();
        }
    }

    function getPendingBalance(address owner, uint16 assetIndex) public view virtual returns (uint128) {
        return _pending[owner][assetIndex];
    }

    function withdrawPendingBalance(address owner, uint16 assetIndex, uint128 baseAmount) public virtual {
        _pending[owner][assetIndex] -= baseAmount;
        _pendingTotal = uint256(baseAmount) >= _pendingTotal ? 0 : _pendingTotal - uint256(baseAmount);
        collateral.transfer(owner, baseAmount);
    }

    // ------------------------------------------------------------------------ batch settlement

    /// @notice Fill every queued order at the current mark price. Emulates one batch executing.
    /// @dev Fills that increase |position| must be covered by requiredMarginBps of the resulting
    ///      notional, valued at markPrice — the way a real venue would reject an under-margined
    ///      order rather than silently fill it. The margin check deliberately still reads
    ///      marginBalance (cash), not equity(): a real venue's initial-margin requirement is met
    ///      with posted collateral, and every fill in the suite happens at the mark it is valued
    ///      against, so an increase carries no PnL of its own to credit.
    ///
    ///      This lives on the shared base rather than on each front end. It is not a test
    ///      convenience: it is the simulator's central mechanic, `LighterSim` needs it to be a
    ///      venue at all, and duplicating it across two front ends is precisely the drift this
    ///      extraction exists to prevent. `virtual` so Task 6 can make settlement asynchronous in
    ///      one place, and so Task 5 can gate it in one place.
    function settleBatch() public virtual {
        for (uint256 i = 0; i < _queue.length; ++i) {
            Order memory o = _queue[i];
            int256 previous = positionBase[o.marketIndex];
            int256 signed = o.isAsk == 1 ? -int256(uint256(o.baseAmount)) : int256(uint256(o.baseAmount));
            int256 resulting;
            if (o.baseAmount == 0) {
                // M-3 (MEDIUM, external C1 audit). `baseAmount == 0` means "default to the full
                // position SIZE" — the size, not the direction. `isAsk` is still the caller's, so
                // this is an order for |position| units on the side the caller named, and an ASK
                // against a SHORT therefore DOUBLES the short instead of closing it.
                //
                // This mock used to set `resulting = 0` for any zero-amount order, ignoring isAsk
                // entirely, so no test in the suite could observe the difference — and
                // CertVault.closeAll() hardcoded SIDE_ASK. The governance wind-down of last resort
                // was therefore unverified in the one state where its direction matters. That is
                // spec section 9.1's own lesson recurring: venue behaviour the vault depends on has
                // to be modelled here, or the suite certifies a design the venue would reject.
                //
                // REQUIRES CONFIRMATION against Lighter source, which is not in this repo: the
                // reading above comes from the design spec's section 3.1 table. It is the
                // CONSERVATIVE reading — it makes a wrong-side close-all harmful rather than
                // harmless — so a vault that is correct against this mock is correct against
                // either interpretation. See docs/DEPLOYMENT-CHECKLIST.md.
                uint256 magnitude = previous >= 0 ? uint256(previous) : uint256(-previous);
                resulting = o.isAsk == 1 ? previous - int256(magnitude) : previous + int256(magnitude);
            } else {
                resulting = previous + signed;
            }
            _trackMarket(o.marketIndex);
            _applyFill(o.marketIndex, previous, resulting);
            positionBase[o.marketIndex] = resulting;

            uint256 absResulting = resulting >= 0 ? uint256(resulting) : uint256(-resulting);
            uint256 absPrevious = previous >= 0 ? uint256(previous) : uint256(-previous);
            if (absResulting > absPrevious) {
                uint256 notional18 = absResulting * markPrice[o.marketIndex] / (10 ** sizeDecimals);
                uint256 requiredMargin18 = notional18 * requiredMarginBps / 10_000;
                uint256 marginBalance18 = _collateralDecimals <= 18
                    ? marginBalance * (10 ** (18 - _collateralDecimals))
                    : marginBalance / (10 ** (_collateralDecimals - 18));
                if (marginBalance18 < requiredMargin18) revert InsufficientMargin();
            }
        }
        delete _queue;
    }

    // ----------------------------------------------------------------------- mark-to-market

    /// @notice Unrealised PnL across every market this account holds, in collateral token units.
    /// @dev `positionBase * (markPrice - entryPrice) / 10**sizeDecimals` gives an 18-decimal
    ///      figure; it is scaled to the collateral's own decimals here so it can be added to
    ///      marginBalance directly.
    function unrealisedPnl() public view virtual returns (int256 pnl) {
        for (uint256 i = 0; i < _markets.length; ++i) {
            pnl += _toCollateral(_pnl18(_markets[i]));
        }
    }

    /// @notice What this account can actually draw on: cash margin plus the position's mark-to-
    ///         market gain (or minus its loss). Floored at zero.
    function equity() public view virtual returns (uint256) {
        int256 e = int256(marginBalance) + unrealisedPnl();
        return e <= 0 ? 0 : uint256(e);
    }

    // ----------------------------------------------------------------------------- internals

    /// @dev Task 5, item 7 (C1). The venue's `validateAndGetAccountIndexFromAddress`, modelled: an
    ///      account-scoped call may only act on the account the CALLER is registered as.
    ///
    ///      `deposit` is deliberately NOT bound this way. `deposit(to, ...)` legitimately registers
    ///      another address — the vault is registered by whoever funds it, which is how
    ///      `CertVault.bootstrap()` gets an account index at all — and that must keep working.
    ///      Only the account-scoped operations (`withdraw`, `createOrder`, `cancelAllOrders`) are
    ///      bound.
    function _requireCallerOwnsAccount(uint48 accountIndex) internal view {
        if (accountIndex != addressToAccountIndex[msg.sender]) revert LighterCore_AccountNotCaller();
    }

    /// @dev Book-keeps entryPrice across one fill, realising PnL on whatever the fill closes.
    ///      Called with positionBase[m] still holding `prev`.
    function _applyFill(uint16 m, int256 prev, int256 res) internal {
        uint256 fillPx = markPrice[m];
        if (res == 0) {
            _realisePortion(m, prev, fillPx);
            entryPrice[m] = 0;
            return;
        }
        if (prev == 0) {
            entryPrice[m] = fillPx;
            return;
        }

        uint256 absPrev = prev >= 0 ? uint256(prev) : uint256(-prev);
        uint256 absRes = res >= 0 ? uint256(res) : uint256(-res);
        bool sameSign = (prev > 0) == (res > 0);

        if (sameSign && absRes > absPrev) {
            // Position increased: volume-weighted entry over old size and newly filled size.
            entryPrice[m] = (absPrev * entryPrice[m] + (absRes - absPrev) * fillPx) / absRes;
        } else if (sameSign) {
            // Partial close: realise the closed slice, leave the entry of the remainder alone.
            uint256 closed = absPrev - absRes;
            _realisePortion(m, prev > 0 ? int256(closed) : -int256(closed), fillPx);
        } else {
            // Flipped side: the whole old position closed, the remainder is a new entry.
            _realisePortion(m, prev, fillPx);
            entryPrice[m] = fillPx;
        }
    }

    /// @dev Realise `portion` (signed, base ticks) of market `m` at `fillPx` into marginBalance.
    function _realisePortion(uint16 m, int256 portion, uint256 fillPx) internal {
        int256 entry = int256(entryPrice[m]);
        if (entry == 0 || portion == 0) return;
        int256 pnl18 = portion * (int256(fillPx) - entry) / int256(10 ** uint256(sizeDecimals));
        int256 pnl = _toCollateral(pnl18);
        if (pnl > 0) {
            marginBalance += uint256(pnl);
        } else if (pnl < 0) {
            uint256 loss = uint256(-pnl);
            marginBalance = loss >= marginBalance ? 0 : marginBalance - loss;
        }
    }

    /// @dev Convert `need` collateral units of unrealised gain into cash, moving entryPrice toward
    ///      markPrice by exactly that much so the same gain can never be drawn twice.
    function _realiseGain(uint256 need) internal {
        for (uint256 i = 0; i < _markets.length && need > 0; ++i) {
            uint16 m = _markets[i];
            int256 pnl = _toCollateral(_pnl18(m));
            if (pnl <= 0) continue;
            uint256 gain = uint256(pnl);
            uint256 take = need < gain ? need : gain;
            _setRemainingGain(m, gain - take);
            marginBalance += take;
            need -= take;
        }
    }

    /// @dev Rewrite entryPrice[m] so this market's unrealised gain becomes exactly `rem`.
    function _setRemainingGain(uint16 m, uint256 rem) internal {
        int256 pos = positionBase[m];
        if (pos == 0) {
            entryPrice[m] = 0;
            return;
        }
        int256 delta = _from18Inverse(rem) * int256(10 ** uint256(sizeDecimals)) / pos;
        int256 newEntry = int256(markPrice[m]) - delta;
        entryPrice[m] = newEntry <= 0 ? 0 : uint256(newEntry);
    }

    function _pnl18(uint16 m) internal view returns (int256) {
        int256 pos = positionBase[m];
        if (pos == 0) return 0;
        int256 entry = int256(entryPrice[m]);
        if (entry == 0) return 0;
        return pos * (int256(markPrice[m]) - entry) / int256(10 ** uint256(sizeDecimals));
    }

    function _toCollateral(int256 v18) internal view returns (int256) {
        return _collateralDecimals <= 18
            ? v18 / int256(10 ** uint256(18 - _collateralDecimals))
            : v18 * int256(10 ** uint256(_collateralDecimals - 18));
    }

    function _from18Inverse(uint256 vCollateral) internal view returns (int256) {
        return _collateralDecimals <= 18
            ? int256(vCollateral * (10 ** uint256(18 - _collateralDecimals)))
            : int256(vCollateral / (10 ** uint256(_collateralDecimals - 18)));
    }

    function _trackMarket(uint16 m) internal {
        if (_tracked[m]) return;
        _tracked[m] = true;
        _markets.push(m);
    }

    /// @dev Hook called by `withdraw()` once the pending credit has been booked. A NO-OP here, and
    ///      that is the conservative default: on the real venue the tokens backing a gain-drawing
    ///      withdrawal are the losing counterparty's collateral, so a simulator that cannot
    ///      produce them must fail rather than conjure them. `MockLighter` overrides this to mint
    ///      the shortfall, which is a *test* convenience — see the override's comment. Keeping it
    ///      off this base is what stops `LighterSim` from being easier than mainnet.
    function _fundPending() internal virtual {}
}
