// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployTestnet} from "../script/DeployTestnet.s.sol";

/// ROADMAP 6.22: a mainnet book must carry the commit it was deployed from.
contract CommitHarness is DeployTestnet {
    function commit() external view returns (string memory) {
        return _commit();
    }
}

contract CommitGuardTest is Test {
    CommitHarness h;

    function setUp() public {
        h = new CommitHarness();
    }

    function test_mainnet_unset_reverts() public {
        vm.chainId(4663);
        vm.setEnv("COMMIT", "");
        vm.expectRevert(bytes("COMMIT must be a 40-char lowercase hash on mainnet: COMMIT=$(git rev-parse HEAD)"));
        h.commit();
    }

    function test_mainnet_malformed_reverts() public {
        vm.chainId(4663);
        vm.setEnv("COMMIT", "signed-attestation");
        vm.expectRevert(bytes("COMMIT must be a 40-char lowercase hash on mainnet: COMMIT=$(git rev-parse HEAD)"));
        h.commit();
        vm.setEnv("COMMIT", "91F7F2DF0654C1535411CD583DDE84B573B46A37"); // uppercase: not what rev-parse prints
        vm.expectRevert(bytes("COMMIT must be a 40-char lowercase hash on mainnet: COMMIT=$(git rev-parse HEAD)"));
        h.commit();
    }

    function test_mainnet_hash_passes() public {
        vm.chainId(4663);
        vm.setEnv("COMMIT", "91f7f2df0654c1535411cd583dde84b573b46a37");
        assertEq(h.commit(), "91f7f2df0654c1535411cd583dde84b573b46a37");
    }

    function test_testnet_keeps_marker() public {
        vm.chainId(46630);
        vm.setEnv("COMMIT", "");
        assertEq(h.commit(), "UNKNOWN - COMMIT env unset; record it by hand before publishing");
    }
}
