// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";

/// @dev Proves the toolchain, both remappings, and the pinned solc all work
///      before any real contract depends on them.
contract Probe is ERC20 {
    constructor() ERC20("Probe", "PRB") {}
}

contract ScaffoldTest is Test {
    function test_toolchainWorks() public pure {
        assertEq(uint256(1) + 1, 2);
    }

    function test_openzeppelinRemappingResolves() public {
        Probe p = new Probe();
        assertEq(p.symbol(), "PRB");
        assertEq(p.decimals(), 18);
    }
}
