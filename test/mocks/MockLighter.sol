// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ILighter} from "../../src/interfaces/ILighter.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Test double reproducing Lighter's asynchronous priority-queue semantics.
/// @dev Orders NEVER fill in the calling transaction. Call settleBatch() to fill.
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
    /// @dev required margin as a fraction of resulting notional, in bps. Default 5_000 (2x).
    uint256 public requiredMarginBps = 5_000;
    /// @dev Mirrors AssetConfig.depositCapTicks on the real contract, which withdraw() validates
    ///      `_baseAmount` against. Defaults large so existing tests are unaffected.
    uint256 public depositCapTicks = type(uint64).max;

    Order[] private _queue;
    mapping(address => mapping(uint16 => uint128)) private _pending;

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

    /// @dev Models AdditionalZkLighter.withdraw() on the real contract: it does NOT check the
    ///      account's balance — sufficiency is decided inside the rollup, not on-chain. It only
    ///      validates baseAmount != 0 and baseAmount <= depositCapTicks before enqueuing a
    ///      priority request. So this must not revert on insufficient marginBalance; instead it
    ///      credits only min(baseAmount, marginBalance) to pending, modelling a rollup batch that
    ///      fulfills what it can and strands the rest — which is how an oversized request would
    ///      actually behave on the real venue.
    function withdraw(uint48 accountIndex, uint16 assetIndex, uint8, uint64 baseAmount) external {
        if (accountIndex == 0) revert AccountIsNotRegistered();
        if (baseAmount == 0) revert ZeroBaseAmount();
        if (baseAmount > depositCapTicks) revert AboveDepositCap();

        uint256 fulfilled = baseAmount <= marginBalance ? baseAmount : marginBalance;
        marginBalance -= fulfilled;
        _pending[msg.sender][assetIndex] += uint128(fulfilled);
    }

    function cancelAllOrders(uint48) external {
        delete _queue;
    }

    function getPendingBalance(address owner, uint16 assetIndex) external view returns (uint128) {
        return _pending[owner][assetIndex];
    }

    function withdrawPendingBalance(address owner, uint16 assetIndex, uint128 baseAmount) external {
        _pending[owner][assetIndex] -= baseAmount;
        collateral.transfer(owner, baseAmount);
    }

    /// @notice Fill every queued order at the current mark price. Emulates one batch executing.
    /// @dev Fills that increase |position| must be covered by requiredMarginBps of the resulting
    ///      notional, valued at markPrice — the way a real venue would reject an under-margined
    ///      order rather than silently fill it.
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
}
