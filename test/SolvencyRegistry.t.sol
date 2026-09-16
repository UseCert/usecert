// SPDX-License-Identifier: MIT
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

    // ---------------------------------------------------------------------------------------
    // M-5 (MEDIUM, external C1 audit). Every privileged address was immutable with no rotation,
    // so losing the attester key was TERMINAL for minting: attestations stop, ageSec passes
    // CapacityOracle.maxAttestationAgeSec, capacity goes to zero permanently, and rebalance() dies
    // with it because batchId stops advancing. Redemption survived (Law 2), but the vault could
    // only be replaced, never repaired.
    //
    // The fix is a governance-gated rotation behind an IMMUTABLE notice period. The delay is the
    // ceiling, and it is the ceiling on SPEED rather than on magnitude because what a newly
    // installed attester can do is already bounded elsewhere (maxAbsoluteCap in M-4, the
    // real-collateral capacity leg in M-1) and because governance already holds an INSTANT lever
    // against a bad attester in setAbsoluteCap(asset, 0).
    // ---------------------------------------------------------------------------------------

    address internal recovered = makeAddr("recoveredAttester");

    /// @dev The fixture deploys this contract, so the test IS governance — that is the binding
    ///      rule (msg.sender at construction), asserted here rather than assumed.
    function test_governanceIsTheDeployer() public view {
        assertEq(reg.governance(), address(this));
    }

    function test_attesterRotationIsNotInstant() public {
        reg.proposeAttester(recovered);
        assertEq(reg.pendingAttester(), recovered);
        assertEq(reg.pendingAttesterAt(), block.timestamp + reg.ATTESTER_ROTATION_DELAY());
        // Still the incumbent: proposing is not installing.
        assertEq(reg.attester(), attester);

        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_RotationNotDue.selector);
        reg.acceptAttester();

        // One second short is still short. The window cannot be rounded off.
        vm.warp(block.timestamp + reg.ATTESTER_ROTATION_DELAY() - 1);
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_RotationNotDue.selector);
        reg.acceptAttester();
    }

    /// @notice The finding's own scenario: the key is gone, and the registry is repaired rather
    ///         than replaced.
    function test_attesterRotationRecoversFromKeyLoss() public {
        vm.prank(attester);
        reg.attest(asset, 100, 1e18, 1e18, 1e18);

        // The key is lost. Nothing can advance the batch, so ageSec runs away — which is what takes
        // CapacityOracle's capacity to zero and takes rebalance() with it.
        vm.warp(block.timestamp + 10 days);
        assertGt(reg.ageSec(asset), 300, "the attestation was supposed to have gone stale");

        reg.proposeAttester(recovered);
        vm.warp(block.timestamp + reg.ATTESTER_ROTATION_DELAY());

        // Permissionless finalisation (Law 6): a stranger closes the rotation out.
        vm.expectEmit(true, true, false, false);
        emit SolvencyRegistry.AttesterRotated(attester, recovered);
        vm.prank(makeAddr("stranger"));
        reg.acceptAttester();

        assertEq(reg.attester(), recovered);
        assertEq(reg.pendingAttester(), address(0), "the proposal was not consumed");
        assertEq(reg.pendingAttesterAt(), 0);

        // The new key works, and the old one is dead.
        vm.prank(recovered);
        reg.attest(asset, 101, 2e18, 2e18, 2e18);
        assertEq(reg.ageSec(asset), 0, "the registry was not actually repaired");

        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_OnlyAttester.selector);
        vm.prank(attester);
        reg.attest(asset, 102, 3e18, 3e18, 3e18);
    }

    function test_onlyGovernanceMayProposeARotation() public {
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_OnlyGovernance.selector);
        vm.prank(makeAddr("eve"));
        reg.proposeAttester(makeAddr("eveAttester"));

        // Not even the incumbent attester may rotate itself.
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_OnlyGovernance.selector);
        vm.prank(attester);
        reg.proposeAttester(recovered);
    }

    /// @notice Rotation may never install address(0). That would brick attestation permanently and
    ///         be unrecoverable — the exact failure M-5 exists to remove, reintroduced by the fix.
    function test_rotationCannotInstallTheZeroAddress() public {
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_ZeroAddress.selector);
        reg.proposeAttester(address(0));
    }

    /// @notice L-3: and the constructor refuses it too.
    function test_constructorRejectsAZeroAttester() public {
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_ZeroAddress.selector);
        new SolvencyRegistry(address(0));
    }

    function test_acceptRevertsWithNothingPending() public {
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_NoPendingAttester.selector);
        reg.acceptAttester();
    }

    /// @notice A mistaken proposal is corrected by proposing again, which RESTARTS the notice
    ///         period rather than inheriting the elapsed part of it. There is no cancel function
    ///         and this is why one is not needed.
    function test_reproposingRestartsTheNoticePeriod() public {
        address wrong = makeAddr("typo");
        reg.proposeAttester(wrong);
        vm.warp(block.timestamp + reg.ATTESTER_ROTATION_DELAY() - 1);

        reg.proposeAttester(recovered);
        assertEq(reg.pendingAttester(), recovered, "the correction did not overwrite the mistake");
        assertEq(reg.pendingAttesterAt(), block.timestamp + reg.ATTESTER_ROTATION_DELAY());

        // The nearly-elapsed first window buys the second proposal nothing.
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_RotationNotDue.selector);
        reg.acceptAttester();

        vm.warp(block.timestamp + reg.ATTESTER_ROTATION_DELAY());
        reg.acceptAttester();
        assertEq(reg.attester(), recovered);
    }

    /// @notice The ceiling is a constant: there is no setter, on any path, for anyone.
    function test_theNoticePeriodHasNoSetter() public view {
        assertEq(reg.ATTESTER_ROTATION_DELAY(), 2 days);
    }
}
