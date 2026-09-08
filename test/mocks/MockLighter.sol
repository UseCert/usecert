// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ILighter} from "../../src/interfaces/ILighter.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

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

    IERC20 public immutable collateral;
    uint16 public immutable collateralAssetIndex;

    mapping(address => uint48) public addressToAccountIndex;
    uint48 private _nextAccountIndex = 3;

    /// @dev collateral posted as margin, in token units
    uint256 public marginBalance;
    /// @dev signed position size in base ticks (size_decimals applied by caller)
    mapping(uint16 => int256) public positionBase;
    /// @dev mark price scaled to 1e18
    mapping(uint16 => uint256) public markPrice;

    Order[] private _queue;
    mapping(address => mapping(uint16 => uint128)) private _pending;

    constructor(IERC20 _collateral, uint16 _collateralAssetIndex) {
        collateral = _collateral;
        collateralAssetIndex = _collateralAssetIndex;
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

    function withdraw(uint48 accountIndex, uint16 assetIndex, uint8, uint64 baseAmount) external {
        if (accountIndex == 0) revert AccountIsNotRegistered();
        marginBalance -= baseAmount;
        _pending[msg.sender][assetIndex] += baseAmount;
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
    function settleBatch() external {
        for (uint256 i = 0; i < _queue.length; ++i) {
            Order memory o = _queue[i];
            int256 signed = o.isAsk == 1 ? -int256(uint256(o.baseAmount)) : int256(uint256(o.baseAmount));
            if (o.baseAmount == 0) {
                // baseAmount == 0 means close the entire position
                positionBase[o.marketIndex] = 0;
            } else {
                positionBase[o.marketIndex] += signed;
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
