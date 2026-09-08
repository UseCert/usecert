// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";

/// @notice A UseCert stock certificate (uTSLA, uNVDA, ...). Plain ERC-20 by design:
///         transfers are unrestricted so the token composes with DEXes and lending markets.
///         Only its vault may mint or burn.
contract Certificate is ERC20 {
    error Certificate_OnlyVault();

    address public immutable vault;

    constructor(string memory n, string memory s, address _vault) ERC20(n, s) {
        vault = _vault;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert Certificate_OnlyVault();
        _;
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }
}
