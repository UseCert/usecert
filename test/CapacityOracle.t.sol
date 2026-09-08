// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CapacityOracle} from "../src/CapacityOracle.sol";
import {SolvencyRegistry} from "../src/SolvencyRegistry.sol";

contract CapacityOracleTest is Test {
    CapacityOracle cap;
    SolvencyRegistry reg;
    address attester = makeAddr("attester");
    address gov = makeAddr("gov");
    address asset = makeAddr("tsla");

    uint256 constant OI = 1_190_000e18; // TSLA open interest observed 2026-09-07
    uint256 constant ABSOLUTE_CAP = 5_000_000e18;
    uint256 constant HUGE_BUFFER = type(uint256).max;

    function setUp() public {
        vm.warp(1_800_000_000);
        reg = new SolvencyRegistry(attester);
        // depthBps 1000 = 10%, bounds [100, 3000], absoluteCap 5M
        cap = new CapacityOracle(address(reg), gov, 1000, 100, 3000, 300);
        vm.prank(gov);
        cap.setAbsoluteCap(asset, ABSOLUTE_CAP);
        vm.prank(attester);
        reg.attest(asset, 1, 0, 0, OI);
    }

    function test_capacityIsDepthShareOfOpenInterest() public view {
        // 10% of 1.19M = 119k
        assertEq(cap.maxNotional18(asset, HUGE_BUFFER), 119_000e18);
    }

    function test_capacityGrowsWithTheMarket() public {
        // The whole point: 100x the market, no redeploy, no parameter change.
        vm.prank(attester);
        reg.attest(asset, 2, 0, 0, OI * 100);
        assertEq(cap.maxNotional18(asset, HUGE_BUFFER), ABSOLUTE_CAP);

        vm.prank(gov);
        cap.setAbsoluteCap(asset, 100_000_000e18);
        assertEq(cap.maxNotional18(asset, HUGE_BUFFER), 11_900_000e18);
    }

    function test_absoluteCapBoundsALyingAttester() public {
        vm.prank(attester);
        reg.attest(asset, 2, 0, 0, type(uint128).max);
        assertEq(cap.maxNotional18(asset, HUGE_BUFFER), ABSOLUTE_CAP);
    }

    function test_bufferCapacityCanBeTheBindingConstraint() public view {
        assertEq(cap.maxNotional18(asset, 50_000e18), 50_000e18);
    }

    function test_staleAttestationYieldsZeroCapacity() public {
        vm.warp(block.timestamp + 301);
        assertEq(cap.maxNotional18(asset, HUGE_BUFFER), 0);
    }

    function test_unattestedAssetYieldsZeroCapacity() public {
        assertEq(cap.maxNotional18(makeAddr("unknown"), HUGE_BUFFER), 0);
    }

    function test_governanceMayTuneDepthWithinBounds() public {
        vm.prank(gov);
        cap.setDepthBps(2000);
        assertEq(cap.maxNotional18(asset, HUGE_BUFFER), 238_000e18);
    }

    function test_governanceCannotEscapeBounds() public {
        vm.startPrank(gov);
        vm.expectRevert(CapacityOracle.CapacityOracle_DepthOutOfBounds.selector);
        cap.setDepthBps(3001);
        vm.expectRevert(CapacityOracle.CapacityOracle_DepthOutOfBounds.selector);
        cap.setDepthBps(99);
        vm.stopPrank();
    }

    function test_nonGovernanceCannotTuneDepth() public {
        vm.expectRevert(CapacityOracle.CapacityOracle_OnlyGovernance.selector);
        cap.setDepthBps(2000);
    }
}
