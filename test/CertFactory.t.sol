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

/// @dev EIP-170: the factory is a REGISTRY, not a deployer. `new CertVault(...)` inside
///      `deployVault` made the factory's runtime carry the vault's 25,743-byte creation code, so
///      the factory measured 28,205 B against a 24,576 B ceiling and was undeployable — and no
///      contract can ever deploy a CertVault via `new`, because the vault's creation code alone
///      exceeds the runtime limit any such contract would have to fit inside. So every test here
///      that used to call `deployVault` now deploys the vault the way a deployment script does —
///      directly — and hands it to `registerVault`. The properties asserted are the same ones;
///      what changed is who does the CREATE.
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
    address eve = makeAddr("eve");

    function setUp() public {
        vm.warp(1_800_000_000);
        usdg = new MockERC20("USDG", "USDG", 6);
        feed = new MockAggregatorV3(8, 355_86000000);
        lighter = new MockLighter(IERC20(address(usdg)), 3, 4);
        reg = new SolvencyRegistry(attester);
        cap = new CapacityOracle(address(reg), gov, 1000, 100, 3000, 300, 1_000_000_000e18);
        oracle = new CertOracle(address(feed), attester, 2, 3600, 500, 100, 3600, false);
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

    /// @dev What the deployment script does, and what every test that used to call `deployVault`
    ///      does now: CREATE the vault from an account that is not a contract under the EIP-170
    ///      ceiling. Wired from the same four addresses the factory holds as immutables, exactly as
    ///      `deployVault` used to wire them, so the registered vault is the same vault the factory
    ///      would have produced — asserted in test_registrationPathEndToEnd rather than assumed.
    /// @dev The four dependencies are written as locals, NOT read back off the factory, because a
    ///      `factory.lighter()` call inside this helper would be an external call that swallows a
    ///      pending `vm.prank`/`vm.expectRevert` from the caller.
    function _deployDirect(address oracle_, string memory symbol_) internal returns (CertVault v) {
        v = new CertVault(
            CertVault.Deps({
                lighter: address(lighter),
                oracle: oracle_,
                registry: address(reg),
                capacity: address(cap),
                governance: gov
            }),
            _config(),
            type(uint64).max,
            1 days,
            "UseCert TSLA",
            symbol_
        );
    }

    /// @dev Deploy-then-register, the replacement for the old one-call `deployVault`. The
    ///      certificate address is hoisted into a local: evaluated inside `registerVault`'s
    ///      argument list it would be an external call that consumes the `vm.prank`.
    function _deploy() internal returns (address v) {
        CertVault vault = _deployDirect(address(oracle), "uTSLA");
        v = address(vault);
        address certificate = address(vault.certificate());
        vm.prank(gov);
        factory.registerVault(v, certificate);
    }

    /// @notice Same property the old test_deployVaultCreatesPairAndRegisters proved: after the
    ///         factory has taken a vault on, `vaultCount`/`vaults`/`isVault` name that vault and
    ///         its certificate is the one the pair was built with. Only the CREATE moved out.
    function test_registerVaultRecordsThePair() public {
        address v = _deploy();
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.vaults(0), v);
        assertTrue(factory.isVault(v));
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

    /// @notice The unknown-vault gate. Sharper than it was: an unregistered vault is now a real,
    ///         live, fully-deployed CertVault rather than an arbitrary address, because deployment
    ///         and registration are two separate steps and a vault can genuinely exist without
    ///         having been registered. `enable` must still refuse it.
    function test_enableRevertsOnUnknownVault() public {
        vm.expectRevert(CertFactory.CertFactory_UnknownVault.selector);
        factory.enable(address(0xBEEF));

        CertVault unregistered = _deployDirect(address(oracle), "uNVDA");
        vm.expectRevert(CertFactory.CertFactory_UnknownVault.selector);
        factory.enable(address(unregistered));
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

    /// @notice EIP-170: the whole registration path, end to end, on a vault deployed the way a
    ///         script deploys it — register, seed, bootstrap, settle the venue batch, enable — and
    ///         `isVault`, `vaults`, `vaultCount` and `enabled` all agree afterwards.
    function test_registrationPathEndToEnd() public {
        CertVault vault = _deployDirect(address(oracle), "uTSLA");
        address v = address(vault);
        address certificate = address(vault.certificate());

        // Nothing is registered until governance says so.
        assertEq(factory.vaultCount(), 0);
        assertFalse(factory.isVault(v));

        vm.prank(gov);
        factory.registerVault(v, certificate);

        assertTrue(factory.isVault(v));
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.vaults(0), v);
        assertFalse(factory.enabled(v), "registration must not enable");

        usdg.mint(address(this), 100e6);
        usdg.approve(v, type(uint256).max);
        vault.seedBuffer(100e6);
        vault.bootstrap();
        assertTrue(vault.bootstrapped());
        lighter.settleBatch();
        assertGt(vault.lighterAccountIndex(), 0, "the registering deposit did not execute");

        factory.enable(v); // permissionless
        assertTrue(factory.enabled(v));

        // Everything the factory publishes about this vault is consistent, and the pair the
        // factory recorded is the pair that is live.
        assertTrue(factory.isVault(factory.vaults(0)));
        assertTrue(factory.enabled(factory.vaults(0)));
        assertEq(address(CertVault(factory.vaults(0)).certificate()), certificate);

        // The registered vault carries exactly the four dependencies the factory holds, i.e. it is
        // the vault `deployVault` would have produced. Asserted here so _deployDirect's wiring is
        // pinned rather than trusted.
        assertEq(address(vault.lighter()), factory.lighter());
        assertEq(address(vault.registry()), factory.registry());
        assertEq(address(vault.capacity()), factory.capacity());
        assertEq(vault.governance(), factory.governance());
    }

    /// @notice The governance gate on `deployVault`, unchanged and asserted at the same error. This
    ///         is the property the external audit's frozen evidence file depends on
    ///         (test/AttackSuite.t.sol, test_ATK_factoryGuards), so the signature and the order of
    ///         the two reverts inside `deployVault` are load-bearing.
    function test_onlyGovernanceMayDeploy() public {
        vm.prank(eve);
        vm.expectRevert(CertFactory.CertFactory_OnlyGovernance.selector);
        factory.deployVault(address(oracle), _config(), type(uint64).max, 1 days, "UseCert TSLA", "uTSLA");
    }

    /// @notice EIP-170: `deployVault` is removed rather than fixed, because it cannot be fixed —
    ///         a contract that can `new CertVault` must carry the vault's 25,743-byte creation code
    ///         in its own runtime, against a 24,576-byte ceiling. Governance gets a named pointer
    ///         at `registerVault`, not a silent success and not an anonymous revert.
    function test_deployVaultIsRemovedEvenForGovernance() public {
        vm.prank(gov);
        vm.expectRevert(CertFactory.CertFactory_UseRegisterVault.selector);
        factory.deployVault(address(oracle), _config(), type(uint64).max, 1 days, "UseCert TSLA", "uTSLA");
    }

    function test_registerVaultIsGovernanceOnly() public {
        CertVault vault = _deployDirect(address(oracle), "uTSLA");
        address certificate = address(vault.certificate());
        vm.prank(eve);
        vm.expectRevert(CertFactory.CertFactory_OnlyGovernance.selector);
        factory.registerVault(address(vault), certificate);
    }

    /// @notice L-3 (LOW, external C1 audit): every vault this factory registers inherits its four
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

    /// @notice L-3, and it still reaches into the vault. The old
    ///         `test_deployVaultRejectsAZeroOracle` proved this by watching `deployVault` forward a
    ///         zero oracle into `CertVault`'s constructor. The factory no longer constructs
    ///         anything, so the forwarding half of that property is gone — but the property it
    ///         actually protected is not, and it never lived in the factory: a zero oracle cannot
    ///         produce a live vault, because the vault's own constructor names it. So there is
    ///         nothing for governance to register, and the check has simply moved to the step that
    ///         always enforced it.
    function test_aZeroOracleCannotProduceARegisterableVault() public {
        vm.expectRevert(CertVault.CertVault_ZeroAddress.selector);
        _deployDirect(address(0), "uTSLA");
    }

    /// @notice EIP-170: `vaults`/`isVault` are what every consumer reads and there is no way to
    ///         unregister, so `registerVault` validates rather than trusts. A zero address is the
    ///         L-3 class of mistake applied to the registry itself.
    function test_registerVaultRejectsZeroAddresses() public {
        CertVault vault = _deployDirect(address(oracle), "uTSLA");
        address certificate = address(vault.certificate());

        vm.prank(gov);
        vm.expectRevert(CertFactory.CertFactory_ZeroAddress.selector);
        factory.registerVault(address(0), certificate);

        vm.prank(gov);
        vm.expectRevert(CertFactory.CertFactory_ZeroAddress.selector);
        factory.registerVault(address(vault), address(0));

        assertEq(factory.vaultCount(), 0);
    }

    /// @notice An address with no code cannot be a vault. Without this, a governance typo naming an
    ///         EOA would be published in `vaults` permanently, and `enable` would then revert with
    ///         no explanation of why.
    function test_registerVaultRejectsAnAddressWithNoCode() public {
        vm.prank(gov);
        vm.expectRevert(CertFactory.CertFactory_NotAContract.selector);
        factory.registerVault(eve, address(0xBEEF));

        assertEq(factory.vaultCount(), 0);
        assertFalse(factory.isVault(eve));
    }

    /// @notice Registering twice must not push the same vault into `vaults` a second time — an
    ///         indexer reading `vaults` would double-count it, and there is no way to remove it.
    function test_registerVaultRejectsDoubleRegistration() public {
        address v = _deploy();
        assertEq(factory.vaultCount(), 1);

        address certificate = address(CertVault(v).certificate());
        vm.prank(gov);
        vm.expectRevert(CertFactory.CertFactory_AlreadyRegistered.selector);
        factory.registerVault(v, certificate);

        assertEq(factory.vaultCount(), 1, "the vault was recorded twice");
    }

    /// @notice The `certificate` argument is a cross-check, not a value taken on faith. A
    ///         governance transaction that pairs vault A with vault B's certificate — the realistic
    ///         copy-paste error when several vaults are deployed in one session — reverts instead
    ///         of publishing a mismatched pair forever.
    function test_registerVaultRejectsACertificateMismatch() public {
        CertVault a = _deployDirect(address(oracle), "uTSLA");
        CertVault b = _deployDirect(address(oracle), "uNVDA");
        address certA = address(a.certificate());
        address certB = address(b.certificate());
        assertTrue(certA != certB);

        vm.prank(gov);
        vm.expectRevert(CertFactory.CertFactory_CertificateMismatch.selector);
        factory.registerVault(address(a), certB);

        assertEq(factory.vaultCount(), 0);

        // The correct pairing goes through, so the check rejects the mismatch and nothing else.
        vm.prank(gov);
        factory.registerVault(address(a), certA);
        assertTrue(factory.isVault(address(a)));
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

    /// @notice EIP-170 regression guard: registration must not depend on the vault having been
    ///         created by the factory, because it never can be again. A vault deployed by an
    ///         arbitrary account — here, this test contract rather than governance — registers
    ///         fine, and `enable` then works on it end to end.
    function test_registrationDoesNotCareWhoDeployedTheVault() public {
        CertVault vault = _deployDirect(address(oracle), "uTSLA");
        assertTrue(address(vault) != address(factory));
        address certificate = address(vault.certificate());

        vm.prank(gov);
        factory.registerVault(address(vault), certificate);

        usdg.mint(address(this), 100e6);
        usdg.approve(address(vault), type(uint256).max);
        vault.seedBuffer(100e6);
        vault.bootstrap();
        lighter.settleBatch();

        factory.enable(address(vault));
        assertTrue(factory.enabled(address(vault)));
    }
}
