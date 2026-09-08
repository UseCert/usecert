// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @notice Minimal surface of Lighter's ZkLighter contract that UseCert calls.
/// @dev Signatures mirror elliottech/lighter-contracts @ 75c2a73. Order types:
///      LimitOrder = 0, MarketOrder = 1. `baseAmount == 0` in createOrder means
///      "the entire position" and is the close-all primitive.
interface ILighter {
    /// @dev Real auto-generated getter for `mapping(address => uint48) public addressToAccountIndex;`
    ///      declared at Storage.sol:125 in elliottech/lighter-contracts @ 75c2a73. Returns 0 until
    ///      the account has executed a registering deposit.
    function addressToAccountIndex(address) external view returns (uint48);

    function deposit(address to, uint16 assetIndex, uint8 routeType, uint256 amount) external payable;

    function createOrder(
        uint48 accountIndex,
        uint16 marketIndex,
        uint48 baseAmount,
        uint32 price,
        uint8 isAsk,
        uint8 orderType
    ) external;

    function withdraw(uint48 accountIndex, uint16 assetIndex, uint8 routeType, uint64 baseAmount) external;

    function cancelAllOrders(uint48 accountIndex) external;

    function getPendingBalance(address owner, uint16 assetIndex) external view returns (uint128);

    function withdrawPendingBalance(address owner, uint16 assetIndex, uint128 baseAmount) external;
}
