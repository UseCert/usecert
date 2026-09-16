// SPDX-License-Identifier: MIT
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
    /// @dev M4: the immutable ceiling on absoluteCap18. Well above the caps this suite sets
    ///      (5M, and 100M in test_capacityGrowsWithTheMarket) so those still exercise what they
    ///      always did, and the new ceiling test has a clear value to exceed.
    uint256 constant MAX_ABSOLUTE_CAP = 1_000_000_000e18;

    function setUp() public {
        vm.warp(1_800_000_000);
        reg = new SolvencyRegistry(attester);
        // depthBps 1000 = 10%, bounds [100, 3000], absoluteCap 5M
        cap = new CapacityOracle(address(reg), gov, 1000, 100, 3000, 300, MAX_ABSOLUTE_CAP);
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

    /// @notice M4: absoluteCap18 is the single number bounding a compromised or lying attester,
    ///         so governance must not be able to set it to any value instantly. The ceiling is
    ///         immutable at deploy — governance tunes beneath it and can never remove it.
    function test_setAbsoluteCapRejectsAboveCeiling() public {
        vm.startPrank(gov);
        vm.expectRevert(CapacityOracle.CapacityOracle_CapAboveCeiling.selector);
        cap.setAbsoluteCap(asset, MAX_ABSOLUTE_CAP + 1);
        vm.expectRevert(CapacityOracle.CapacityOracle_CapAboveCeiling.selector);
        cap.setAbsoluteCap(asset, type(uint256).max);

        // At the ceiling exactly is fine, and the cap really did not move on the rejected calls.
        assertEq(cap.absoluteCap18(asset), ABSOLUTE_CAP);
        cap.setAbsoluteCap(asset, MAX_ABSOLUTE_CAP);
        assertEq(cap.absoluteCap18(asset), MAX_ABSOLUTE_CAP);
        vm.stopPrank();
    }

    /// @notice The ceiling must actually bind the formula, not just the setter: with the cap
    ///         pinned at the ceiling, a lying attester's open interest still cannot lift capacity
    ///         above it.
    function test_ceilingBoundsCapacityEvenAtTheMaximumCap() public {
        vm.prank(gov);
        cap.setAbsoluteCap(asset, MAX_ABSOLUTE_CAP);
        vm.prank(attester);
        reg.attest(asset, 2, 0, 0, type(uint128).max);
        assertEq(cap.maxNotional18(asset, HUGE_BUFFER), MAX_ABSOLUTE_CAP);
    }

    function test_extremeOpenInterestClampsInsteadOfReverting() public {
        // Attest an extreme openInterest18 that would overflow in naive multiplication
        vm.prank(attester);
        reg.attest(asset, 3, 0, 0, type(uint256).max);
        // Should return exactly ABSOLUTE_CAP without reverting, demonstrating Math.mulDiv safety
        assertEq(cap.maxNotional18(asset, HUGE_BUFFER), ABSOLUTE_CAP);
    }

    /// @notice L-3 (LOW, external C1 audit): no constructor in src/ validated its dependencies. A
    ///         zero registry makes maxNotional18 revert on every call, which reverts both mint
    ///         paths through _requireCapacity; a zero governance freezes both levers forever.
    /// @dev LOAD-BEARING: remove the CapacityOracle_ZeroAddress check and both calls below deploy
    ///      successfully instead of reverting.
    function test_constructorRejectsZeroDependencies() public {
        vm.expectRevert(CapacityOracle.CapacityOracle_ZeroAddress.selector);
        new CapacityOracle(address(0), gov, 1000, 100, 3000, 300, MAX_ABSOLUTE_CAP);

        vm.expectRevert(CapacityOracle.CapacityOracle_ZeroAddress.selector);
        new CapacityOracle(address(reg), address(0), 1000, 100, 3000, 300, MAX_ABSOLUTE_CAP);
    }
}
