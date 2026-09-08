// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {CertVault} from "./CertVault.sol";

/// @notice Deploys {CertVault, Certificate} pairs and PUBLISHES when each vault's Lighter account
///         index has resolved. It does not gate anything.
/// @dev The factory holds no funds and has no upgrade path (Law 6: no owner, keeper or pause). It
///      does not call bootstrap() itself — that needs collateral approved to the vault, which is
///      the deployer's own operational step, not the factory's.
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
    /// @dev L-3 (LOW, external C1 audit): every vault this factory deploys inherits these four
    ///      addresses, so a mistyped one here is a mistyped one in every vault, discovered later at
    ///      an arbitrary call site rather than at deploy.
    error CertFactory_ZeroAddress();

    event VaultDeployed(address indexed vault, address indexed certificate, uint16 marketIndex);
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

    /// @dev Takes CertVault's own VaultConfig struct rather than flattening its ten fields into
    ///      loose parameters: with this repo's `via_ir = false`, a flat signature here overflows
    ///      the EVM's 16-slot stack window (Stack too deep) before the body even runs.
    /// @param venueWithdrawCap_ The venue's per-asset withdrawal ceiling for this vault's
    ///        collateral (C1: recallMargin() clamps its request to it). Per-asset, so it is a
    ///        per-deployment argument rather than a factory-wide immutable.
    /// @param settleWindow_ How long one of this vault's mint receipts stays settleable before it
    ///        can only be refunded (C3).
    function deployVault(
        address oracle,
        CertVault.VaultConfig calldata config,
        uint256 venueWithdrawCap_,
        uint256 settleWindow_,
        string calldata name_,
        string calldata symbol_
    ) external returns (address vault, address certificate) {
        if (msg.sender != governance) revert CertFactory_OnlyGovernance();

        CertVault v = new CertVault(
            CertVault.Deps({
                lighter: lighter, oracle: oracle, registry: registry, capacity: capacity, governance: governance
            }),
            config,
            venueWithdrawCap_,
            settleWindow_,
            name_,
            symbol_
        );

        vault = address(v);
        certificate = address(v.certificate());
        isVault[vault] = true;
        vaults.push(vault);
        emit VaultDeployed(vault, certificate, config.marketIndex);
    }

    /// @notice Publish that a vault's Lighter account index has resolved. Permissionless: it can
    ///         only ever succeed once the chain says the account exists, so there is nothing to
    ///         gate. Reverts on an address this factory never deployed rather than silently marking
    ///         an unknown address enabled.
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
