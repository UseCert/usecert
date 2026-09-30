// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice The narrow views and calls the stack-6 revenue-share contracts need from their neighbours.
interface ITokenStaking {
    function totalStaked() external view returns (uint256);
    function notifyRewardAmount(uint256 amount) external;
}

interface IRevShareVault {
    function certificate() external view returns (address);
    function oracle() external view returns (address);
}

interface IPxOracle {
    function pxUnguarded() external view returns (uint256 px18, uint256 observedAt);
}

interface IVaultFactory {
    function vaultCount() external view returns (uint256);
    function vaults(uint256 i) external view returns (address);
}

interface IInsurancePool {
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IUniswapV2PairLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}
