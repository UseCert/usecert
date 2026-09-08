// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CertFactory} from "../src/CertFactory.sol";
import {CertVault} from "../src/CertVault.sol";
import {Certificate} from "../src/Certificate.sol";
import {CertOracle} from "../src/CertOracle.sol";
import {SolvencyRegistry} from "../src/SolvencyRegistry.sol";
import {CapacityOracle} from "../src/CapacityOracle.sol";
import {MockLighter} from "./mocks/MockLighter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

contract CertFactoryTest is Test {
    CertFactory factory;
    SolvencyRegistry reg;
    CapacityOracle cap;
    CertOracle oracle;
    MockLighter lighter;
    MockERC20 usdg;
    MockAggregatorV3 feed;

    address gov = makeAddr("gov");
    address attester = makeAddr("attester");

    function setUp() public {
        vm.warp(1_800_000_000);
        usdg = new MockERC20("USDG", "USDG", 6);
        feed = new MockAggregatorV3(8, 355_86000000);
        lighter = new MockLighter(IERC20(address(usdg)), 3, 4);
        reg = new SolvencyRegistry(attester);
        cap = new CapacityOracle(address(reg), gov, 1000, 100, 3000, 300, 1_000_000_000e18);
        oracle = new CertOracle(address(feed), attester, 2, 3600, 500, 100);
        factory = new CertFactory(address(lighter), address(reg), address(cap), gov);
    }

    function _config() internal view returns (CertVault.VaultConfig memory) {
        return CertVault.VaultConfig({
            collateral: address(usdg),
            collateralAssetIndex: 3,
            routeType: 0,
            marketIndex: 16,
            sizeDecimals: 4,
            mintFeeBps: 10,
            redeemFeeBps: 10,
            instantCap18: 10_000e18,
            settleBandBps: 500,
            targetMarginBps: 9_000
        });
    }

    function _deploy() internal returns (address v) {
        vm.prank(gov);
        (v,) = factory.deployVault(address(oracle), _config(), type(uint64).max, 1 days, "UseCert TSLA", "uTSLA");
    }

    function test_deployVaultCreatesPairAndRegisters() public {
        address v = _deploy();
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.vaults(0), v);
        assertEq(Certificate(CertVault(v).certificate()).symbol(), "uTSLA");
    }

    function test_vaultStartsDisabled() public {
        address v = _deploy();
        assertFalse(factory.enabled(v));
    }

    function test_enableRevertsBeforeBootstrapLands() public {
        address v = _deploy();
        vm.expectRevert(CertFactory.CertFactory_NotRegisteredYet.selector);
        factory.enable(v);
    }

    function test_enableRevertsOnUnknownVault() public {
        vm.expectRevert(CertFactory.CertFactory_UnknownVault.selector);
        factory.enable(address(0xBEEF));
    }

    function test_enableSucceedsOnceAccountIndexResolves() public {
        address v = _deploy();
        usdg.mint(address(this), 100e6);
        usdg.approve(v, type(uint256).max);
        CertVault(v).seedBuffer(100e6); // vault must already hold the bootstrap dust
        CertVault(v).bootstrap();
        lighter.settleBatch();

        factory.enable(v); // permissionless
        assertTrue(factory.enabled(v));
    }

    function test_onlyGovernanceMayDeploy() public {
        vm.expectRevert(CertFactory.CertFactory_OnlyGovernance.selector);
        factory.deployVault(address(oracle), _config(), type(uint64).max, 1 days, "UseCert TSLA", "uTSLA");
    }

    /// @notice L-3 (LOW, external C1 audit): every vault this factory deploys inherits its four
    ///         addresses, so a mistyped one here is a mistyped one in every vault.
    function test_constructorRejectsZeroDependencies() public {
        vm.expectRevert(CertFactory.CertFactory_ZeroAddress.selector);
        new CertFactory(address(0), address(reg), address(cap), gov);

        vm.expectRevert(CertFactory.CertFactory_ZeroAddress.selector);
        new CertFactory(address(lighter), address(0), address(cap), gov);

        vm.expectRevert(CertFactory.CertFactory_ZeroAddress.selector);
        new CertFactory(address(lighter), address(reg), address(0), gov);

        vm.expectRevert(CertFactory.CertFactory_ZeroAddress.selector);
        new CertFactory(address(lighter), address(reg), address(cap), address(0));
    }

    /// @notice L-3, and it reaches into the vault: deployVault forwards the oracle argument
    ///         straight into CertVault's constructor, which now names a zero dependency.
    function test_deployVaultRejectsAZeroOracle() public {
        vm.expectRevert(CertVault.CertVault_ZeroAddress.selector);
        vm.prank(gov);
        factory.deployVault(address(0), _config(), type(uint64).max, 1 days, "UseCert TSLA", "uTSLA");
    }

    /// @notice L-1 (LOW, external C1 audit): `enabled` is a PUBLISHED MARKER, not a gate. Nothing
    ///         in src/ reads it — CertVault has no reference to its factory and cannot consult it —
    ///         so this pins the honest behaviour: a vault that was never enabled mints anyway,
    ///         because the sequencing guarantee is enforced by the venue (createOrder reverts
    ///         AccountIsNotRegistered) and not by this boolean.
    /// @dev Asserted rather than left in a report, because the old NatSpec read as though enabling
    ///         were a precondition. If a future change makes the flag load-bearing, this test is
    ///         where that will surface — update it deliberately rather than deleting it.
    function test_enabledFlagGatesNothing() public {
        address v = _deploy();
        usdg.mint(address(this), 200_000e6);
        usdg.approve(v, type(uint256).max);
        CertVault(v).seedBuffer(150_000e6);
        CertVault(v).bootstrap();
        lighter.settleBatch();

        // Deliberately NOT calling factory.enable(v).
        assertFalse(factory.enabled(v), "the vault was enabled after all");

        vm.prank(gov);
        cap.setAbsoluteCap(v, 5_000_000e18);
        vm.prank(attester);
        reg.attest(v, 1, 0, 0, 1_190_000e18);
        vm.prank(attester);
        oracle.setMarkPrice(355.86e18);
        lighter.setMarkPrice(16, 355.86e18);

        uint256 out = CertVault(v).mintInstant(3_558.6e6);
        assertGt(out, 0, "a disabled vault could not mint, so the flag DOES gate something");
    }
}
