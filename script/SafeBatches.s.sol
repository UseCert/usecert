// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {DeployMainnet} from "./DeployMainnet.s.sol";
import {SolvencyRegistry} from "../src/SolvencyRegistry.sol";
import {CertOracle} from "../src/CertOracle.sol";

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
}
