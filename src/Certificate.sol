// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";

/// @notice A UseCert stock certificate (uTSLA, uNVDA, ...). Plain ERC-20 by design:
///         transfers are unrestricted so the token composes with DEXes and lending markets.
///         Only its vault may mint or burn.
contract Certificate is ERC20 {
    error Certificate_OnlyVault();
    /// @dev L-3 (LOW, external C1 audit): no constructor in src/ validated its dependencies, so a
    ///      mistyped address deployed silently and failed later at an arbitrary call site. A zero
    ///      vault here is the worst of them — mint and burn would be permanently unreachable, so
    ///      the certificate could never be issued or redeemed.
    error Certificate_ZeroAddress();

    address public immutable vault;

    constructor(string memory n, string memory s, address _vault) ERC20(n, s) {
        if (_vault == address(0)) revert Certificate_ZeroAddress();
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
