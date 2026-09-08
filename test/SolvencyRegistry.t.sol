// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SolvencyRegistry} from "../src/SolvencyRegistry.sol";
import {ISolvencyRegistry} from "../src/interfaces/ISolvencyRegistry.sol";

contract SolvencyRegistryTest is Test {
    SolvencyRegistry reg;
    address attester = makeAddr("attester");
    address asset = makeAddr("tsla");

    function setUp() public {
        vm.warp(1_800_000_000);
        reg = new SolvencyRegistry(attester);
    }

    function test_attestStoresAndEmits() public {
        vm.expectEmit(true, false, false, true);
        emit SolvencyRegistry.Attested(asset, 100, 1_000e18, 1_100e18, 50_000e18);
        vm.prank(attester);
        reg.attest(asset, 100, 1_000e18, 1_100e18, 50_000e18);

        ISolvencyRegistry.Attestation memory a = reg.latest(asset);
        assertEq(a.notional18, 1_000e18);
        assertEq(a.margin18, 1_100e18);
        assertEq(a.openInterest18, 50_000e18);
        assertEq(a.batchId, 100);
        assertEq(reg.ageSec(asset), 0);
    }

    function test_ageSecGrowsWithTime() public {
        vm.prank(attester);
        reg.attest(asset, 100, 1e18, 1e18, 1e18);
        vm.warp(block.timestamp + 90);
        assertEq(reg.ageSec(asset), 90);
    }

    function test_onlyAttesterMayAttest() public {
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_OnlyAttester.selector);
        reg.attest(asset, 1, 1e18, 1e18, 1e18);
    }

    function test_batchIdMustAdvance() public {
        vm.startPrank(attester);
        reg.attest(asset, 100, 1e18, 1e18, 1e18);
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_StaleBatch.selector);
        reg.attest(asset, 100, 2e18, 2e18, 2e18);
        vm.stopPrank();
    }

    function test_unattestedAssetHasMaxAge() public {
        assertEq(reg.ageSec(makeAddr("unknown")), type(uint256).max);
    }
}
