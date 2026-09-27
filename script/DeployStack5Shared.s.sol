// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {DeployMainnet} from "./DeployMainnet.s.sol";
import {SolvencyRegistry} from "../src/SolvencyRegistry.sol";
import {CapacityOracle} from "../src/CapacityOracle.sol";
import {CertFactory} from "../src/CertFactory.sol";

/// @notice Stack 5, the half that needs no price oracle: CapacityOracle, CertFactory,
///         InsuranceStaking v2, CertStaking v2, BuybackForwarder and FeeVault, from the deployer.
/// @dev WHY THIS EXISTS. Every CertOracle refuses a stale Chainlink price in its constructor, and
///      the RH stock feeds do not update at weekends, so the six oracles (and therefore the
///      vaults) cannot be created until the feeds move. Nothing in this file reads an oracle:
///      the pool needs the vault registry, the registry needs SolvencyRegistry and the capacity
///      oracle, and SolvencyRegistry is created by the Safe on its own (batch 1, registry part).
///      So the staking side can go live first. `DeployMainnet` later REUSES every address this
///      prints (MAINNET_CAPACITY_ORACLE, MAINNET_CERT_FACTORY, MAINNET_INSURANCE_STAKING,
///      MAINNET_CERT_STAKING, MAINNET_BUYBACK_FORWARDER, MAINNET_FEE_VAULT) and re-checks each.
///
///      Same constants, same code paths and the same S9 read-backs as `DeployMainnet`: this is a
///      subclass that runs only `_deployCapacityAndFactory()` and `_deployStack5Shared()`.
///
///      env: MAINNET_DEPLOYER_PK, MAINNET_ATTESTER_ADDR, MAINNET_GOVERNANCE_SAFE,
///           MAINNET_SAFE_REGISTRY, COMMIT; optional MAINNET_OPS_WALLET, MAINNET_TREASURY_SAFE.
///
///         forge script script/DeployStack5Shared.s.sol:DeployStack5Shared --rpc-url $RPC [--broadcast --slow]
contract DeployStack5Shared is DeployMainnet {
    function run() public override {
        if (block.chainid != 4663) revert DeployTestnet_WrongChain(block.chainid, 4663);
        _commit(); // the mainnet commit guard: a 40-char lowercase hash or revert

        uint256 deployerPk = vm.envUint("MAINNET_DEPLOYER_PK");
        deployerAddr = vm.addr(deployerPk);
        attesterAddr = vm.envAddress("MAINNET_ATTESTER_ADDR");
        govAddr = _externalGovernance();
        require(govAddr != address(0) && govAddr.code.length > 0, "SHARED: MAINNET_GOVERNANCE_SAFE must be the Safe");
        require(deployerAddr != govAddr && deployerAddr != attesterAddr, "SENDERS: deployer collides");

        _loadAssets(); // the per-asset M-8 rows, for the CapacityOracle ceiling
        collateral = USDG;
        lighter = ZK_LIGHTER;
        registry = vm.envAddress("MAINNET_SAFE_REGISTRY");
        require(registry.code.length > 0, "SHARED: SolvencyRegistry has no code - execute its Safe batch first");
        require(SolvencyRegistry(registry).governance() == govAddr, "SHARED: registry.governance != Safe");
        require(SolvencyRegistry(registry).attester() == attesterAddr, "SHARED: registry.attester != attester");

        opsWallet = _opsWalletAddr();
        treasury = _treasuryAddr();
        require(treasury.code.length > 0, "FEES: treasury has no code - it must be a Safe");
        require(opsWallet != address(0) && opsWallet != treasury, "FEES: ops wallet zero or == treasury");
        require(USDG.code.length > 0 && CERT.code.length > 0 && ZK_LIGHTER.code.length > 0, "MAINNET: dependency missing");

        vm.startBroadcast(deployerPk);
        _deployCapacityAndFactory();
        _deployStack5Shared();
        vm.stopBroadcast();

        // The same read-backs DeployMainnet runs, plus the two shared contracts' wiring.
        _verifyFeeVault();
        _verifyStakings();
        CapacityOracle c = CapacityOracle(capacity);
        require(c.maxAbsoluteCap() == _maxAbsoluteCap(), "S9 SHARED: capacity ceiling != the reviewed table");
        require(c.maxAbsoluteCap() < 1_000_000_000e18, "S9 SHARED M-8: ceiling is the stack-4 1e27 again");
        CertFactory f = CertFactory(factory);
        require(f.registry() == registry && f.capacity() == capacity, "S9 SHARED: factory wiring");
        require(f.lighter() == lighter && f.governance() == govAddr, "S9 SHARED: factory lighter/governance");

        console2.log("export MAINNET_CAPACITY_ORACLE=", capacity);
        console2.log("export MAINNET_CERT_FACTORY=", factory);
        console2.log("export MAINNET_INSURANCE_STAKING=", insuranceStaking);
        console2.log("export MAINNET_CERT_STAKING=", certStaking);
        console2.log("export MAINNET_BUYBACK_FORWARDER=", buybackForwarder);
        console2.log("export MAINNET_FEE_VAULT=", feeVault);
    }
}
