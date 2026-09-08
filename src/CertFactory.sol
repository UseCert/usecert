// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {CertVault} from "./CertVault.sol";

/// @notice Deploys and sequences vault bootstrap. A vault stays disabled until Lighter has
///         actually assigned it an account index, because createOrder reverts with
///         AccountIsNotRegistered until the registering deposit has been executed by a batch.
/// @dev The factory holds no funds and has no upgrade path (Law 6: no owner, keeper or pause). It
///      does not call bootstrap() itself — that needs collateral approved to the vault, which is
///      the deployer's own operational step, not the factory's.
contract CertFactory {
    error CertFactory_OnlyGovernance();
    error CertFactory_NotRegisteredYet();
    error CertFactory_UnknownVault();

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
    function deployVault(
        address oracle,
        CertVault.VaultConfig calldata config,
        string calldata name_,
        string calldata symbol_
    ) external returns (address vault, address certificate) {
        if (msg.sender != governance) revert CertFactory_OnlyGovernance();

        CertVault v = new CertVault(
            CertVault.Deps({
                lighter: lighter, oracle: oracle, registry: registry, capacity: capacity, governance: governance
            }),
            config,
            name_,
            symbol_
        );

        vault = address(v);
        certificate = address(v.certificate());
        isVault[vault] = true;
        vaults.push(vault);
        emit VaultDeployed(vault, certificate, config.marketIndex);
    }

    /// @notice Permissionless: it can only ever succeed once the chain says the account exists,
    ///         so there is nothing to gate. Reverts on an address this factory never deployed
    ///         rather than silently marking an unknown address enabled.
    function enable(address vault) external {
        if (!isVault[vault]) revert CertFactory_UnknownVault();
        if (CertVault(vault).lighterAccountIndex() == 0) revert CertFactory_NotRegisteredYet();
        enabled[vault] = true;
        emit VaultEnabled(vault);
    }
}
