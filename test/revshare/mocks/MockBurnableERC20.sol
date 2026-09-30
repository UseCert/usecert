// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";

contract MockBurnableERC20 is ERC20 {
    constructor() ERC20("Token", "TKN") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function burn(uint256 amt) external {
        _burn(msg.sender, amt);
    }
}
