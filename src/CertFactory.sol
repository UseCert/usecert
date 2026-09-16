// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CertVault} from "./CertVault.sol";

/// @notice REGISTRY for {CertVault, Certificate} pairs. It records which addresses are this
///         deployment's vaults and PUBLISHES when each vault's Lighter account index has resolved.
///         It does not deploy vaults and it does not gate anything.
/// @dev The factory holds no funds and has no upgrade path (Law 6: no owner, keeper or pause). It
///      does not call bootstrap() itself — that needs collateral approved to the vault, which is
///      the deployer's own operational step, not the factory's.
///
/// @dev WHY THIS IS A REGISTRY AND NOT A DEPLOYER — EIP-170. This contract used to do
///      `new CertVault(...)` inside deployVault. A contract that can `new X` must carry X's entire
///      creation code inside its own RUNTIME code, and `CertVault`'s initcode measures 25,743 B
///      against EIP-170's 24,576 B runtime ceiling. So the factory measured 28,205 B runtime
///      (−3,629 B of margin) and could not be deployed to any chain that enforces EIP-170 —
///      and, more fundamentally, NO contract can ever deploy `CertVault` via `new`, because the
///      vault's creation code exceeds the runtime limit on its own. Moving the `new` behind a
///      helper contract does not help: the limit follows the bytecode, wherever it is parked.
///
///      `CertVault` deploys fine directly from an EOA or a deployment script, where initcode is
///      capped by EIP-3860 at 49,152 B. So vaults are now deployed by script and handed to
///      registerVault(). The factory's genuine substance was never the `new` call — it is the
///      `vaults` list, the `isVault` gate and the bootstrap `enable()` sequencing, all of which
///      are unchanged. Foundry does not enforce EIP-170 in tests, which is why the suite never
///      caught this; `forge build --sizes` does.
///
/// @dev L-1 (LOW, external C1 audit). THIS CONTRACT'S `enabled` FLAG IS A PUBLISHED MARKER, NOT A
///      SAFETY MECHANISM, and the NatSpec here used to say otherwise ("refuses to enable a vault
///      until its account index resolves", read as though enabling were a precondition for
///      anything). Nothing reads the flag: CertVault has no reference to its factory, so it cannot
///      consult it, and no path in src/ does. The claim is removed rather than left standing, and
///      the spec is corrected with it (section 3.3 and the section 5 contract map).
///
///      WHERE THE REAL GATE IS, so the guarantee is not merely deleted: the vault self-gates on
///      `bootstrapped`, and beyond that it fails closed at the venue — createOrder reverts
///      AccountIsNotRegistered until the rollup has executed the registering deposit, and both
///      mint paths route through the revert-capable _hedge, so a mint attempted before the account
///      resolves reverts as one atomic transaction with nothing pulled, posted or minted. That is
///      the sequencing guarantee, it is enforced by the chain rather than by a boolean here, and
///      it does not depend on anyone having called enable().
///
///      WHY THE FLAG IS KEPT rather than deleted outright, which was the better of the audit's two
///      options on the merits: `enable()`, `enabled()` and CertFactory_UnknownVault are called by
///      the external audit's own evidence file (test/AttackSuite.t.sol, test_ATK_factoryGuards),
///      which this pass must not edit. So what is removed is the false claim — the part that could
///      mislead — and what remains is an honest, permissionless, one-way, published signal that
///      an operator or indexer can use to observe bootstrap completion. Deleting the flag is a C2
///      cleanup. Making it load-bearing was rejected on the merits even setting the frozen file
///      aside: it would mean giving CertVault a factory dependency it does not have and putting a
///      new external call and a new bricking surface on the mint path, in exchange for a gate the
///      chain already enforces.
contract CertFactory {
    error CertFactory_OnlyGovernance();
    error CertFactory_NotRegisteredYet();
    error CertFactory_UnknownVault();
    /// @dev L-3 (LOW, external C1 audit): every vault registered here inherits these four
    ///      addresses from its own deployment, so a mistyped one is a mistyped one in every vault,
    ///      discovered later at an arbitrary call site rather than at deploy.
    error CertFactory_ZeroAddress();
    /// @dev EIP-170: on-chain vault deployment is impossible, not merely inconvenient. See the
    ///      contract NatSpec and deployVault below.
    error CertFactory_UseRegisterVault();
    /// @dev registerVault's four validations, each named so a bad registration fails at the
    ///      registration and not at some later consumer of `vaults`.
    error CertFactory_AlreadyRegistered();
    error CertFactory_NotAContract();
    error CertFactory_CertificateMismatch();

    /// @dev Renamed from VaultDeployed: the factory no longer deploys, so the old name would be a
    ///      lie in the ABI. The payload is deliberately identical field-for-field, so an indexer
    ///      only has to change the topic it subscribes to.
    event VaultRegistered(address indexed vault, address indexed certificate, uint16 marketIndex);
    event VaultEnabled(address indexed vault);

    address public immutable lighter;
    address public immutable registry;
    address public immutable capacity;
    address public immutable governance;

    address[] public vaults;
    mapping(address => bool) public isVault;
    mapping(address => bool) public enabled;

    constructor(address _lighter, address _registry, address _capacity, address _governance) {
        if (
            _lighter == address(0) || _registry == address(0) || _capacity == address(0)
                || _governance == address(0)
        ) revert CertFactory_ZeroAddress();
        lighter = _lighter;
        registry = _registry;
        capacity = _capacity;
        governance = _governance;
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    /// @notice Record an already-deployed vault as one of this deployment's vaults. Governance
    ///         only. This is the replacement for deployVault: the vault is deployed by the
    ///         deployment script (or directly by the multisig) and handed here.
    /// @dev Validates rather than trusts, because `vaults`/`isVault` are what every consumer reads
    ///         and there is no way to unregister (Law 6: no owner, no admin surface beyond this one
    ///         governance check). The `certificate` argument is a caller-supplied cross-check, not
    ///         a value this function takes on faith — it must equal the vault's own
    ///         `certificate()`, so a governance transaction that names the wrong pair reverts
    ///         instead of publishing a mismatched pair forever.
    /// @dev NOT VALIDATED, deliberately: that the vault's own `lighter`, `registry`, `capacity` and
    ///         `governance` immutables match this factory's. Reading four immutables back would
    ///         make this function meaningfully larger for a check the deployment checklist already
    ///         requires be read back on-chain (section 9), and a vault wired to different
    ///         dependencies is a redeployment either way — the factory cannot repair it.
    /// @param vault The deployed CertVault.
    /// @param certificate The Certificate that vault's constructor deployed. Cross-checked.
    function registerVault(address vault, address certificate) external {
        if (msg.sender != governance) revert CertFactory_OnlyGovernance();
        if (vault == address(0) || certificate == address(0)) revert CertFactory_ZeroAddress();
        if (vault.code.length == 0) revert CertFactory_NotAContract();
        if (isVault[vault]) revert CertFactory_AlreadyRegistered();
        if (address(CertVault(vault).certificate()) != certificate) revert CertFactory_CertificateMismatch();

        isVault[vault] = true;
        vaults.push(vault);

        (,,, uint16 marketIndex,,,,,,) = CertVault(vault).cfg();
        emit VaultRegistered(vault, certificate, marketIndex);
    }

    /// @notice REMOVED. Always reverts. Deploy the vault from your deployment script (or directly
    ///         from the multisig) and call {registerVault} instead.
    /// @dev The signature is kept, and the governance check is kept AHEAD of the removal revert, on
    ///      purpose. On-chain deployment of a CertVault is impossible under EIP-170 — the vault's
    ///      creation code (25,743 B) exceeds the 24,576 B runtime limit that any contract embedding
    ///      it would have to fit inside, so this is not a size budget that a smaller factory or a
    ///      helper deployer could win back. See the contract NatSpec.
    ///
    ///      Keeping the governance gate first also keeps the externally observable behaviour for an
    ///      unauthorised caller exactly as it was — CertFactory_OnlyGovernance, not
    ///      CertFactory_UseRegisterVault — which is what the external audit's frozen evidence file
    ///      asserts (test/AttackSuite.t.sol, test_ATK_factoryGuards). An authorised caller gets the
    ///      named pointer at registerVault.
    ///
    ///      Parameters are left unnamed so the selector is unchanged while nothing is read.
    function deployVault(
        address, /* oracle */
        CertVault.VaultConfig calldata, /* config */
        uint256, /* venueWithdrawCap_ */
        uint256, /* settleWindow_ */
        string calldata, /* name_ */
        string calldata /* symbol_ */
    ) external view returns (address, /* vault */ address /* certificate */ ) {
        if (msg.sender != governance) revert CertFactory_OnlyGovernance();
        revert CertFactory_UseRegisterVault();
    }

    /// @notice Publish that a vault's Lighter account index has resolved. Permissionless: it can
    ///         only ever succeed once the chain says the account exists, so there is nothing to
    ///         gate. Reverts on an address this factory never registered rather than silently
    ///         marking an unknown address enabled.
    /// @dev L-1: OBSERVATIONAL ONLY. Calling this is not a precondition for minting, redeeming or
    ///      anything else — see the contract NatSpec for where the sequencing guarantee actually
    ///      lives. Do not add a caller that treats it as one.
    function enable(address vault) external {
        if (!isVault[vault]) revert CertFactory_UnknownVault();
        if (CertVault(vault).lighterAccountIndex() == 0) revert CertFactory_NotRegisteredYet();
        enabled[vault] = true;
        emit VaultEnabled(vault);
    }
}
