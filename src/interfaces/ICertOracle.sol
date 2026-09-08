// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

interface ICertOracle {
    function px() external view returns (uint256 px18);
    function pxUnguarded() external view returns (uint256 px18, uint256 updatedAt);
    function mintAllowed() external view returns (bool);
    function basisBps() external view returns (uint256);
    function toTickPrice(uint256 px18) external view returns (uint32);
}
