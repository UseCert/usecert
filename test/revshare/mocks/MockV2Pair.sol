// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice The parts of a Uniswap V2 pair the buyback uses: reserves, a 0.3%-fee swap and the
///         UQ112x112 cumulative prices, updated on every sync exactly as UniswapV2Pair._update does.
contract MockV2Pair {
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function sync() public {
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint32 ts = uint32(block.timestamp);
        uint32 elapsed = ts - blockTimestampLast;
        if (elapsed > 0 && reserve0 != 0 && reserve1 != 0) {
            price0CumulativeLast += (uint256(reserve1) << 112) / reserve0 * elapsed;
            price1CumulativeLast += (uint256(reserve0) << 112) / reserve1 * elapsed;
        }
        reserve0 = uint112(b0);
        reserve1 = uint112(b1);
        blockTimestampLast = ts;
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        (uint112 r0, uint112 r1,) = (reserve0, reserve1, blockTimestampLast);
        if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 in0 = b0 > r0 - amount0Out ? b0 - (r0 - amount0Out) : 0;
        uint256 in1 = b1 > r1 - amount1Out ? b1 - (r1 - amount1Out) : 0;
        require(in0 > 0 || in1 > 0, "INSUFFICIENT_INPUT");
        uint256 a0 = b0 * 1000 - in0 * 3;
        uint256 a1 = b1 * 1000 - in1 * 3;
        require(a0 * a1 >= uint256(r0) * r1 * 1_000_000, "K");
        sync();
    }
}
