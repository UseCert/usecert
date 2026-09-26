// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {KeeperScript} from "./KeeperScript.sol";
import {VenueTruth} from "./VenueTruth.sol";
import {LighterSim} from "../../src/sim/LighterSim.sol";
import {SolvencyRegistry} from "../../src/SolvencyRegistry.sol";
import {CertOracle} from "../../src/CertOracle.sol";

/// @title  AttesterSign — the attester's figures, SIGNED instead of SENT.
///
/// @notice WHY THIS EXISTS, AND WHAT IT REPLACES. `Attester.s.sol` broadcasts, so the attester pays
///         for every write; and because `CapacityOracle.maxNotional18` returns zero once
///         `registry.ageSec` passes 300 s, it has to keep broadcasting on a timer whether or not
///         anyone is minting. Measured on chain 46630 that is ~0.0284 ETH/day at a 30 s tick, spent
///         almost entirely to keep an idle protocol nominally open. Worse, when the attester wallet
///         ran dry on 2026-09-20 every broadcast failed for 11.6 hours and the only signal was a log
///         line saying "attest FAIL".
///
///         This script computes the SAME figures from the SAME `VenueTruth` reads, and then signs
///         them rather than sending them. A minter submits the signature inside their own
///         transaction via `SolvencyRegistry.attestSigned` / `CertOracle.setMarkPriceSigned`, so an
///         idle protocol costs nothing and whoever wants the mint pays for it.
///
/// @notice IT BROADCASTS NOTHING AND COSTS NOTHING. There is no `vm.broadcast` in this file. It may
///         be run against a live deployment as often as you like, from a wallet holding no gas.
///
/// @notice WHY IT IS A FORGE SCRIPT AND NOT A NODE SERVICE. The figures come from
///         `VenueTruth.notional18/margin18/markPx18` — per-account venue reads that exist because
///         the aggregate views answer a venue-level question and would credit one mirror with
///         another's margin. Reimplementing those reads in JavaScript to sign them would create two
///         sources of truth for the numbers the registry is about to accept, and the failure mode of
///         a divergence is a correctly-signed WRONG attestation. Reusing the library, and building
///         the digest from the contract's own `ATTEST_TYPEHASH` and `domainSeparator()`, means the
///         thing being signed is by construction the thing the contract will verify.
///
/// @dev    Output is one JSON object per line on stdout, prefixed `SIGNED ` so a caller can find it
///         among forge's own logging. `vm.writeJson` is deliberately not used: `fs_permissions` is
///         scoped to `deployments/` and widening it is a security property, not a convenience.
contract AttesterSign is KeeperScript {
    /// @notice How long each signature stays usable. Must not exceed the registry's own
    ///         SIGNATURE_VALIDITY, or the contract rejects what this script produces.
    uint64 internal constant VALIDITY = 60;

    function _signerKey() internal view virtual override returns (uint256) {
        return vm.envUint("ATTESTER_PK");
    }

    function run() external {
        Book memory book = _book();
        _requireBookMatchesChain(book);

        uint256 pk = _signerKey();
        address signer = vm.addr(pk);

        SolvencyRegistry registry = SolvencyRegistry(book.solvencyRegistry);
        LighterSim sim = LighterSim(book.lighterSim);

        // The same named-reason checks the broadcasting attester makes. A signature from the wrong
        // key is not rejected here but at the relayer's expense, three hops away, as
        // `SolvencyRegistry_BadSignature` — so it is worth failing early and saying why.
        require(
            signer == book.attester,
            "ATTESTER_PK does not derive .senders.attester from the address book - attestSigned would revert SolvencyRegistry_BadSignature"
        );
        require(
            registry.attester() == signer,
            "SolvencyRegistry.attester() on chain != the signer - governance may have rotated the attester; update the key"
        );

        uint64 observedAt = uint64(block.timestamp);
        uint64 deadline = observedAt + VALIDITY;

        uint256 n = book.mirrors.length;
        for (uint256 i = 0; i < n; ++i) {
            _signMirror(book.mirrors[i], registry, sim, signer, pk, observedAt, deadline);
        }

        console2.log("AttesterSign: signed", n, "mirrors, nothing broadcast");
    }

    /// @dev One mirror's worth of work, in its own frame. Not a stylistic split: `run()` with all of
    ///      this inline exceeds the EVM's 16-slot reach and fails to compile as "Stack too deep",
    ///      and the alternative fix — turning on `via_ir` — would change the codegen pipeline for
    ///      every contract in the project to make one script fit.
    struct Signed {
        uint256 notional18;
        uint256 margin18;
        uint256 markPx18;
        uint256 openInterest18;
        uint64 batchId;
        uint64 markNonce;
    }

    function _signMirror(
        Mirror memory m,
        SolvencyRegistry registry,
        LighterSim sim,
        address signer,
        uint256 pk,
        uint64 observedAt,
        uint64 deadline
    ) internal {
        CertOracle oracle = CertOracle(m.certOracle);
        require(
            oracle.attester() == signer, "CertOracle.attester() on chain != the signer for one of the mirrors"
        );

        Signed memory s = Signed({
            notional18: VenueTruth.notional18(sim, m.vault, m.marketIndex),
            margin18: VenueTruth.margin18(sim, m.vault),
            markPx18: VenueTruth.markPx18(sim, m.marketIndex),
            openInterest18: _openInterest18(m),
            batchId: registry.latest(m.vault).batchId + 1,
            markNonce: oracle.markNonce() + 1
        });

        // Digests built from the CONTRACTS' own typehashes and domain separators, read from the
        // chain rather than hardcoded here. Hardcoding either would let this script and the
        // contracts drift apart silently after a redeployment, and the symptom would be every relay
        // reverting BadSignature while the figures looked perfectly correct.
        bytes memory attestSig = _sign(
            pk,
            registry.domainSeparator(),
            keccak256(
                abi.encode(
                    registry.ATTEST_TYPEHASH(),
                    m.vault,
                    s.batchId,
                    s.notional18,
                    s.margin18,
                    s.openInterest18,
                    observedAt,
                    deadline
                )
            )
        );
        bytes memory markSig = _sign(
            pk,
            oracle.domainSeparator(),
            keccak256(abi.encode(oracle.SET_MARK_TYPEHASH(), s.markPx18, s.markNonce, deadline))
        );

        // Built in halves and joined. One 20-argument string.concat also exceeds the stack, and
        // this is the readable way out of it rather than another compiler flag.
        string memory head = string.concat(
            'SIGNED {"symbol":"',
            m.symbol,
            '","vault":"',
            vm.toString(m.vault),
            '","certOracle":"',
            vm.toString(m.certOracle),
            '","registry":"',
            vm.toString(address(registry)),
            '","batchId":',
            vm.toString(uint256(s.batchId))
        );
        string memory figures = string.concat(
            ',"notional18":"',
            vm.toString(s.notional18),
            '","margin18":"',
            vm.toString(s.margin18),
            '","openInterest18":"',
            vm.toString(s.openInterest18),
            '","markPx18":"',
            vm.toString(s.markPx18),
            '","markNonce":',
            vm.toString(uint256(s.markNonce))
        );
        string memory tail = string.concat(
            ',"observedAt":',
            vm.toString(uint256(observedAt)),
            ',"deadline":',
            vm.toString(uint256(deadline)),
            ',"attestSig":"',
            vm.toString(attestSig),
            '","markSig":"',
            vm.toString(markSig),
            '"}'
        );
        console2.log(string.concat(head, figures, tail));
    }

    function _sign(uint256 pk, bytes32 domain, bytes32 structHash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Mirrors `Attester._openInterest18` so the signed figure matches what the broadcasting
    ///      keeper would have written. Overridable for the same reason it is there.
    function _openInterest18(Mirror memory m) internal view virtual returns (uint256) {
        uint256 override_ = vm.envOr(string.concat("OI_OVERRIDE_", m.symbol), uint256(0));
        return override_ == 0 ? m.seedOpenInterest18 : override_;
    }
}
