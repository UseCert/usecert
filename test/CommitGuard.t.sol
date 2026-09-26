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

/// ONE test on purpose. vm.setEnv writes the process environment, which forge's parallel test
/// threads share: split across functions, one case's COMMIT overwrote another's mid-run and the
/// suite failed one run in a few. Sequential cases in a single function cannot race.
contract CommitGuardTest is Test {
    bytes constant REASON = bytes("COMMIT must be a 40-char lowercase hash on mainnet: COMMIT=$(git rev-parse HEAD)");

    function test_commit_guard() public {
        CommitHarness h = new CommitHarness();

        vm.chainId(4663);
        vm.setEnv("COMMIT", "");
        vm.expectRevert(REASON);
        h.commit(); // unset

        vm.setEnv("COMMIT", "signed-attestation");
        vm.expectRevert(REASON);
        h.commit(); // not a hash

        vm.setEnv("COMMIT", "91F7F2DF0654C1535411CD583DDE84B573B46A37");
        vm.expectRevert(REASON);
        h.commit(); // uppercase: not what rev-parse prints

        vm.setEnv("COMMIT", "91f7f2df0654c1535411cd583dde84b573b46a37");
        assertEq(h.commit(), "91f7f2df0654c1535411cd583dde84b573b46a37"); // a real hash passes

        vm.chainId(46630);
        vm.setEnv("COMMIT", "");
        assertEq(h.commit(), "UNKNOWN - COMMIT env unset; record it by hand before publishing"); // testnet unchanged
    }
}
