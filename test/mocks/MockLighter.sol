// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ILighter} from "../../src/interfaces/ILighter.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Test double reproducing Lighter's asynchronous priority-queue semantics.
/// @dev Orders NEVER fill in the calling transaction. Call settleBatch() to fill.
///
///      M3 (final review wave): this mock used to model NO position PnL at all — fills were
///      price-agnostic and marginBalance moved only on deposit/withdraw, so a position's gain
///      never existed and no test could ever observe a vault trying (and failing) to bring one
///      home. That blind spot is exactly why C1 shipped. It now marks positions to market:
///      every fill records/updates a volume-weighted entry price, equity() is
///      marginBalance + unrealised PnL, and withdraw() fulfils against equity() rather than
///      against the cash balance alone.
contract MockLighter is ILighter {
    struct Order {
        uint16 marketIndex;
        uint48 baseAmount;
        uint32 price;
        uint8 isAsk;
        uint8 orderType;
    }

    error AccountIsNotRegistered();
    error MarketIndexTooHigh();
    error BadOrderType();
    error InsufficientMargin();
    error ZeroBaseAmount();
    error AboveDepositCap();
    /// @dev M1: models the venue refusing to drain an already-credited pending balance (paused
    ///      withdrawals, a rollup rule, a future guard). CertVault._sweepPending must survive it.
    error DrainRefused();

    IERC20 public immutable collateral;
    uint16 public immutable collateralAssetIndex;
    uint8 public immutable sizeDecimals;
    uint8 private immutable _collateralDecimals;

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
    /// @dev M1: when set, withdrawPendingBalance reverts DrainRefused().
    bool public shouldRevertDrain;

    Order[] private _queue;
    mapping(address => mapping(uint16 => uint128)) private _pending;
    /// @dev Every market this mock has ever filled, so unrealisedPnl() can sum across them.
    uint16[] private _markets;
    mapping(uint16 => bool) private _tracked;
    /// @dev Sum of all credited-but-undrained pending balances, used to keep the mock's real token
    ///      holdings sufficient to honour them (see _fundPending).
    uint256 private _pendingTotal;

    constructor(IERC20 _collateral, uint16 _collateralAssetIndex, uint8 _sizeDecimals) {
        collateral = _collateral;
        collateralAssetIndex = _collateralAssetIndex;
        sizeDecimals = _sizeDecimals;
        _collateralDecimals = IERC20Metadata(address(_collateral)).decimals();
    }

    function setRequiredMarginBps(uint256 bps) external {
        requiredMarginBps = bps;
    }

    function setDepositCapTicks(uint256 cap) external {
        depositCapTicks = cap;
    }

    function setMarkPrice(uint16 marketIndex, uint256 px18) external {
        markPrice[marketIndex] = px18;
    }

    function setShouldRevertDrain(bool v) external {
        shouldRevertDrain = v;
    }

    function deposit(address to, uint16, uint8, uint256 amount) external payable {
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
    ) external {
        if (accountIndex == 0) revert AccountIsNotRegistered();
        if (marketIndex > 254) revert MarketIndexTooHigh();
        if (orderType > 1) revert BadOrderType();
        _queue.push(Order(marketIndex, baseAmount, price, isAsk, orderType));
    }

    // ----------------------------------------------------------------- M3: mark-to-market

    /// @notice Unrealised PnL across every market this account holds, in collateral token units.
    /// @dev `positionBase * (markPrice - entryPrice) / 10**sizeDecimals` gives an 18-decimal
    ///      figure; it is scaled to the collateral's own decimals here so it can be added to
    ///      marginBalance directly.
    function unrealisedPnl() public view returns (int256 pnl) {
        for (uint256 i = 0; i < _markets.length; ++i) {
            pnl += _toCollateral(_pnl18(_markets[i]));
        }
    }

    /// @notice What this account can actually draw on: cash margin plus the position's mark-to-
    ///         market gain (or minus its loss). Floored at zero.
    function equity() public view returns (uint256) {
        int256 e = int256(marginBalance) + unrealisedPnl();
        return e <= 0 ? 0 : uint256(e);
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
    function withdraw(uint48 accountIndex, uint16 assetIndex, uint8, uint64 baseAmount) external {
        if (accountIndex == 0) revert AccountIsNotRegistered();
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

    function cancelAllOrders(uint48) external {
        delete _queue;
    }

    function getPendingBalance(address owner, uint16 assetIndex) external view returns (uint128) {
        return _pending[owner][assetIndex];
    }

    function withdrawPendingBalance(address owner, uint16 assetIndex, uint128 baseAmount) external {
        if (shouldRevertDrain) revert DrainRefused();
        _pending[owner][assetIndex] -= baseAmount;
        _pendingTotal = uint256(baseAmount) >= _pendingTotal ? 0 : _pendingTotal - uint256(baseAmount);
        collateral.transfer(owner, baseAmount);
    }

    /// @notice Fill every queued order at the current mark price. Emulates one batch executing.
    /// @dev Fills that increase |position| must be covered by requiredMarginBps of the resulting
    ///      notional, valued at markPrice — the way a real venue would reject an under-margined
    ///      order rather than silently fill it. The margin check deliberately still reads
    ///      marginBalance (cash), not equity(): a real venue's initial-margin requirement is met
    ///      with posted collateral, and every fill in the suite happens at the mark it is valued
    ///      against, so an increase carries no PnL of its own to credit.
    function settleBatch() external {
        for (uint256 i = 0; i < _queue.length; ++i) {
            Order memory o = _queue[i];
            int256 previous = positionBase[o.marketIndex];
            int256 signed = o.isAsk == 1 ? -int256(uint256(o.baseAmount)) : int256(uint256(o.baseAmount));
            int256 resulting;
            if (o.baseAmount == 0) {
                // baseAmount == 0 means close the entire position
                resulting = 0;
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

    function queuedOrderCount() external view returns (uint256) {
        return _queue.length;
    }

    function lastOrder() external view returns (uint16, uint48, uint32, uint8, uint8) {
        Order memory o = _queue[_queue.length - 1];
        return (o.marketIndex, o.baseAmount, o.price, o.isAsk, o.orderType);
    }

    // ------------------------------------------------------------------------- internals

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

    /// @dev A withdrawal that draws on the position's gain asks this mock for tokens no single
    ///      account ever deposited — on a real venue they are the losing counterparty's
    ///      collateral. A one-account mock has no counterparty, so the shortfall is minted here.
    ///      Without this, a genuinely-payable receipt would fail on the mock's own token balance
    ///      rather than on anything the contract under test did.
    function _fundPending() internal {
        uint256 held = collateral.balanceOf(address(this));
        if (held >= _pendingTotal) return;
        try IMockMintable(address(collateral)).mint(address(this), _pendingTotal - held) {} catch {}
    }
}

interface IMockMintable {
    function mint(address to, uint256 amount) external;
}
