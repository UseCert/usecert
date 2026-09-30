// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {MockERC20} from "../../mocks/MockERC20.sol";

/// @notice One certificate + oracle + vault, a factory listing vaults, and an insurance pool whose
///         assets and shares the test sets directly.
contract MockPxOracle {
    uint256 public px;

    function setPx(uint256 p) external {
        px = p;
    }

    function pxUnguarded() external view returns (uint256, uint256) {
        return (px, block.timestamp);
    }
}

contract MockRevShareVault {
    address public certificate;
    address public oracle;

    constructor(address c, address o) {
        certificate = c;
        oracle = o;
    }
}

contract MockVaultFactory {
    address[] public vaults;

    function add(address v) external {
        vaults.push(v);
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }
}

contract MockInsurancePool {
    uint256 public totalAssets;
    uint256 public totalSupply;

    function set(uint256 assets, uint256 supply) external {
        totalAssets = assets;
        totalSupply = supply;
    }
}
