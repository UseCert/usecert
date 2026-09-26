// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {DeployMainnet} from "./DeployMainnet.s.sol";
import {SolvencyRegistry} from "../src/SolvencyRegistry.sol";
import {CertOracle} from "../src/CertOracle.sol";
import {CertVault} from "../src/CertVault.sol";
import {CertFactory} from "../src/CertFactory.sol";
import {CapacityOracle} from "../src/CapacityOracle.sol";

/// @title SafeBatches — batch 1 of a Safe-governed mainnet deployment (ROADMAP 6.15).
///
/// @notice `SolvencyRegistry` and `CertOracle` record `governance = msg.sender` in their
///         constructors, immutably, and their constructor arity is frozen (the auditor's
///         AttackSuite depends on it). So for the Safe to BE their governance, the Safe itself has
///         to be the creator. A Safe cannot run CREATE directly; it delegatecalls Safe's own
///         CreateCall library, inside which CREATE executes in the Safe's context - msg.sender in
///         the constructor is the Safe.
///
///         This builds that one Safe transaction: a delegatecall to Safe's MultiSend 1.4.1 whose
///         entries are delegatecalls to CreateCall 1.4.1, creating the registry and one oracle per
///         asset with EXACTLY the constructor arguments DeployMainnet would use (same asset table,
///         same constants, same feeds). It broadcasts nothing. It prints the Safe transaction and
///         the addresses the creations will land at, so they can be checked after execution.
///
///         forge script script/SafeBatches.s.sol:SafeBatches --sig 'batch1()' --rpc-url $RPC
///           env: MAINNET_GOVERNANCE_SAFE, MAINNET_ATTESTER_ADDR, MAINNET_FEED_<SYM>
contract SafeBatches is DeployMainnet {
    address internal constant MULTISEND_141 = 0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526;
    address internal constant CREATECALL_141 = 0x9b35Af71d77eaf8d7e40252370304687390A1A52;
    address internal constant MULTISEND_CALLONLY_141 = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    bytes4 internal constant PERFORM_CREATE = bytes4(keccak256("performCreate(uint256,bytes)"));
    bytes4 internal constant MULTI_SEND = bytes4(keccak256("multiSend(bytes)"));

    function batch1() external {
        require(block.chainid == 4663, "SafeBatches: chain 4663 only");
        address safe = vm.envAddress("MAINNET_GOVERNANCE_SAFE");
        address attester = vm.envAddress("MAINNET_ATTESTER_ADDR");
        require(safe.code.length > 0, "SafeBatches: the Safe has no code on this chain");
        require(MULTISEND_141.code.length > 0 && CREATECALL_141.code.length > 0, "SafeBatches: Safe libraries missing");

        _loadAssets();
        uint256 n = assets.length;
        uint64 nonce = vm.getNonce(safe);

        bytes memory packed;
        packed = _entry(packed, abi.encodePacked(type(SolvencyRegistry).creationCode, abi.encode(attester)));
        console2.log("CREATE registry  ->", vm.computeCreateAddress(safe, nonce));

        for (uint256 i = 0; i < n; ++i) {
            address feed = _feedFor(assets[i].symbol);
            require(feed.code.length > 0, string.concat("SafeBatches: no feed for ", assets[i].symbol));
            bytes memory init = abi.encodePacked(
                type(CertOracle).creationCode,
                abi.encode(
                    feed,
                    attester,
                    assets[i].priceDecimals,
                    _stalenessSeconds(),
                    DEVIATION_BPS,
                    BASIS_BAND_BPS,
                    POKE_CONFIRMATION_SECONDS,
                    _singleSource()
                )
            );
            packed = _entry(packed, init);
            console2.log(string.concat("CREATE oracle ", assets[i].symbol, " ->"), vm.computeCreateAddress(safe, nonce + 1 + uint64(i)));
        }

        bytes memory data = abi.encodeWithSelector(MULTI_SEND, packed);
        console2.log("SAFE_TX_TO", MULTISEND_141);
        console2.log("SAFE_TX_OPERATION 1");
        console2.log("SAFE_TX_NONCE_OF_ACCOUNT", uint256(nonce));
        console2.log("SAFE_TX_DATA_BYTES", data.length);
        console2.log(string.concat("SAFE_TX_DATA ", vm.toString(data)));
    }

    /// @dev One MultiSend entry: operation 1 (delegatecall) to CreateCall.performCreate(0, init).
    function _entry(bytes memory packed, bytes memory init) internal pure returns (bytes memory) {
        bytes memory call = abi.encodeWithSelector(PERFORM_CREATE, uint256(0), init);
        return abi.encodePacked(packed, uint8(1), CREATECALL_141, uint256(0), uint256(call.length), call);
    }

    /// @notice Batch 2: everything governance does after the deploy, as ONE Safe transaction -
    ///         a delegatecall to MultiSendCallOnly 1.4.1 (plain calls only, no delegatecalls
    ///         inside). Per vault, in the order the deploy and keeper setup require:
    ///           phase 4   registerVault, setAbsoluteCap, setBufferThresholds (DeployTestnet)
    ///           keepers   setVenueApiKey, setVenueMinimums, enableKeeperHedging (usecert-keeper-setup)
    ///         enableKeeperHedging is last per vault, so a vault never accepts a mint it cannot hedge.
    ///         Addresses from deployments/4663.json; amounts from this script's own asset table;
    ///         API public keys and venue minimums from env (PUBKEY_<SYM>, MINBASE_<SYM>, MINQUOTE_<SYM>),
    ///         the latter read from the venue's market list, never typed in.
    function batch2() external {
        require(block.chainid == 4663, "SafeBatches: chain 4663 only");
        address safe = vm.envAddress("MAINNET_GOVERNANCE_SAFE");
        string memory book = vm.readFile("deployments/4663.json");
        require(vm.parseJsonAddress(book, ".senders.governance") == safe, "SafeBatches: the book's governance is not the Safe");
        address factory_ = vm.parseJsonAddress(book, ".shared.certFactory");
        address capacity_ = vm.parseJsonAddress(book, ".shared.capacityOracle");
        _loadAssets();

        bytes memory packed;
        for (uint256 i = 0; i < assets.length; ++i) {
            string memory k = string.concat(".vaults[", vm.toString(i), "]");
            require(
                keccak256(bytes(vm.parseJsonString(book, string.concat(k, ".symbol")))) == keccak256(bytes(assets[i].symbol)),
                "SafeBatches: book and asset table disagree on order"
            );
            address vault = vm.parseJsonAddress(book, string.concat(k, ".vault"));
            address cert = vm.parseJsonAddress(book, string.concat(k, ".certificate"));
            require(CertVault(vault).governance() == safe, "SafeBatches: vault governance is not the Safe");
            require(CertVault(vault).lighterAccountIndex() != 0, "SafeBatches: vault not bootstrapped - setVenueApiKey needs its account");
            string memory sym = assets[i].symbol;
            bytes memory pub = vm.envBytes(string.concat("PUBKEY_", sym));
            require(pub.length == 40, "SafeBatches: API public key must be 40 bytes");

            packed = _call(packed, factory_, abi.encodeCall(CertFactory.registerVault, (vault, cert)));
            packed = _call(packed, capacity_, abi.encodeCall(CapacityOracle.setAbsoluteCap, (vault, assets[i].absoluteCap18)));
            packed = _call(packed, vault, abi.encodeCall(
                CertVault.setBufferThresholds, (assets[i].bufferFloor18, assets[i].bufferFeeOn18, assets[i].bufferMintSlow18, 0)
            ));
            packed = _call(packed, vault, abi.encodeCall(CertVault.setVenueApiKey, (uint8(vm.envUint("API_KEY_INDEX")), pub)));
            packed = _call(packed, vault, abi.encodeCall(
                CertVault.setVenueMinimums, (vm.envUint(string.concat("MINBASE_", sym)), vm.envUint(string.concat("MINQUOTE_", sym)))
            ));
            packed = _call(packed, vault, abi.encodeCall(CertVault.enableKeeperHedging, ()));
            console2.log(string.concat("  ", sym, " vault"), vault);
        }
        bytes memory data = abi.encodeWithSelector(MULTI_SEND, packed);
        console2.log("SAFE_TX_TO", MULTISEND_CALLONLY_141);
        console2.log("SAFE_TX_OPERATION 1");
        console2.log("SAFE_TX_CALLS", assets.length * 6);
        console2.log(string.concat("SAFE_TX_DATA ", vm.toString(data)));
    }

    /// @dev One MultiSendCallOnly entry: operation 0 (call), no value.
    function _call(bytes memory packed, address to, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(packed, uint8(0), to, uint256(0), uint256(data.length), data);
    }
}
