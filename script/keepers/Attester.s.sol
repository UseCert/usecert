// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {KeeperScript} from "./KeeperScript.sol";
import {VenueTruth} from "./VenueTruth.sol";
import {LighterSim} from "../../src/sim/LighterSim.sol";
import {SolvencyRegistry} from "../../src/SolvencyRegistry.sol";
import {CertOracle} from "../../src/CertOracle.sol";

/// @title  Attester — the keeper without which minting stops five minutes after deployment.
///
/// @notice WHAT BREAKS WITHOUT IT, PRECISELY. `CapacityOracle.maxNotional18` opens with
///
///             if (registry.ageSec(asset) > maxAttestationAgeSec) return 0;
///
///         and `maxAttestationAgeSec` is 300 s, immutable. So five minutes after the deployment's
///         one seed attestation, `maxNotional18` is zero for every vault, `_requireCapacity` refuses
///         every mint with `CertVault_AtCapacity`, and the deployment looks broken. It is not
///         broken; the keeper is not running. `docs/TESTNET-RUNBOOK.md`'s first troubleshooting row
///         is that sentence, because an operator who reads it as a deploy failure will try to
///         "fix" an immutable parameter and then redeploy.
///
///         Redemption is UNAFFECTED (Design Law 2): `forceExit` prices off `pxUnguarded()` and
///         reads no health state. A starved deployment stops taking money in; it never traps money
///         already in.
///
/// @notice ============ THE HONESTY PROBLEM, AND IT IS THE POINT OF THIS FILE =============
///
///         On MAINNET `attest(asset, batchId, notional18, margin18, openInterest18)` is fed by
///         reconstructing Lighter's account tree from posted blob data — figures that are
///         INDEPENDENTLY VERIFIABLE BUT NOT VERIFIED ON-CHAIN. The registry takes the attester's
///         word for them. The only bounds surviving a compromised attester are
///         `CapacityOracle.maxAbsoluteCap` and `maxAttestationAgeSec`.
///
///         On TESTNET the venue is a simulator WE OWN, so this keeper reads the true position
///         straight out of it (`script/keepers/VenueTruth.sol`). There is no reconstruction step,
///         no blob decoding, and no window in which the attester could be wrong without the chain
///         disagreeing.
///
///         THAT MAKES TESTNET SOLVENCY STRICTLY STRONGER THAN MAINNET'S. It is the right call for a
///         testnet and it makes this keeper trivial — and it is exactly the kind of convenience
///         that quietly becomes an implied production claim. A green testnet says NOTHING about
///         whether a single mainnet attester relaying unverified figures is sound. Recorded here,
///         in `VenueTruth`'s NatSpec, and prominently in the runbook.
///         =====================================================================================
///
/// @dev    IT WRITES TWO THINGS PER MIRROR, and both are needed:
///
///           1. `SolvencyRegistry.attest(vault, batchId, notional18, margin18, openInterest18)` —
///              refreshes `ageSec` (the capacity leg) and publishes the backing figures
///              `CertVault.solvency()` returns.
///           2. `CertOracle.setMarkPrice(px18)` — the venue-side price the basis band is measured
///              against. It has NO timestamp and NO staleness check anywhere, so its liveness is an
///              operational assumption on THIS keeper's cadence, not a contract guarantee. A mark
///              left behind a moving feed drifts out of `basisBandBps` and `mintAllowed()` goes
///              false, which is a THIRD way minting stops and a different one from the two above.
///
///         Both are sent by the ATTESTER key — the one `SolvencyRegistry` and every `CertOracle`
///         bound at construction. Governance can rotate it, but only after
///         `ATTESTER_ROTATION_DELAY`; there is no path that repoints these two calls at another key
///         today.
///
/// @dev    NO IN-SCRIPT INFINITE LOOP AND NO DAEMON. An external loop re-invokes it:
///
///             while true; do
///               forge script script/keepers/Attester.s.sol \
///                 --rpc-url robinhood_testnet --broadcast --slow;
///               sleep 60;
///             done
///
///         RECOMMENDED INTERVAL: 60 s, against a 300 s `maxAttestationAgeSec`. That is a 5x margin,
///         and the margin is the whole design: at 240 s a single failed cycle — one RPC timeout, one
///         gas exhaustion, one nonce collision — starves minting before the next cycle lands. 60 s
///         means four consecutive failures are needed before a tester notices. Do not raise it
///         toward 300.
contract Attester is KeeperScript {
    /// @dev `ATTESTER_PK` — the key `SolvencyRegistry` and every `CertOracle` bound at
    ///      construction. See `KeeperScript._signerKey()` for why this is behind a seam.
    function _signerKey() internal view virtual override returns (uint256) {
        return vm.envUint("ATTESTER_PK");
    }

    function run() external {
        Book memory book = _book();
        _requireBookMatchesChain(book);

        LighterSim sim = LighterSim(book.lighterSim);
        SolvencyRegistry registry = SolvencyRegistry(book.solvencyRegistry);

        uint256 pk = _signerKey();
        address signer = vm.addr(pk);

        // Preflight, before anything is sent. `attest` reverts `SolvencyRegistry_OnlyAttester` and
        // `setMarkPrice` reverts `CertOracle_OnlyAttester` for a wrong key, and at 60 s intervals
        // that is a log full of bare selectors. Named reasons instead.
        require(
            signer == book.attester,
            "ATTESTER_PK does not derive .senders.attester from the address book - attest would revert SolvencyRegistry_OnlyAttester"
        );
        require(
            registry.attester() == signer,
            "SolvencyRegistry.attester() on chain != the signer - governance may have rotated the attester (proposeAttester/acceptAttester); update the key"
        );

        console2.log("Attester: signing as", signer);

        uint256 n = book.mirrors.length;
        for (uint256 i = 0; i < n; ++i) {
            Mirror memory m = book.mirrors[i];

            // Per-oracle too: each mirror has its own `CertOracle`, each bound its own attester at
            // construction, and a partially rotated set would fail on the second mirror only.
            require(
                CertOracle(m.certOracle).attester() == signer,
                "CertOracle.attester() on chain != the signer for one of the mirrors"
            );

            // ---------------------------------------------------------- the figures, from the venue
            //
            // PER-ACCOUNT READS. Task 7 gave every account its own margin, position and entry
            // price, and `script/DeployTestnet.s.sol` puts BOTH mirrors on ONE `LighterSim`. The
            // aggregate views (`marginBalance()`, `positionBase(m)`) therefore answer a
            // venue-level question, not "what backs this vault", and attesting from them would
            // credit uTSLA with uSPY's margin. See `VenueTruth` for the exact functions and why.
            uint256 notional18 = VenueTruth.notional18(sim, m.vault, m.marketIndex);
            uint256 margin18 = VenueTruth.margin18(sim, m.vault);
            uint256 markPx18 = VenueTruth.markPx18(sim, m.marketIndex);
            uint256 openInterest18 = _openInterest18(m);

            // `batchId` must STRICTLY INCREASE or `attest` reverts `SolvencyRegistry_StaleBatch`.
            // Derived from the chain, never from a counter in this process: a restarted keeper, a
            // second keeper started by mistake, or a crash between cycles all resume correctly from
            // whatever the registry already holds. The deployment seeds batch 1, so the first
            // keeper cycle writes 2.
            uint64 batchId = registry.latest(m.vault).batchId + 1;

            console2.log(string.concat("Attester: ", m.symbol, " vault"), m.vault);
            _logMirror(m, "batchId", batchId);
            _logMirror(m, "notional18", notional18);
            _logMirror(m, "margin18", margin18);
            _logMirror(m, "markPx18", markPx18);

            vm.broadcast(pk);
            registry.attest(m.vault, batchId, notional18, margin18, openInterest18);

            vm.broadcast(pk);
            CertOracle(m.certOracle).setMarkPrice(markPx18);
        }

        console2.log("Attester: mirrors attested", n);
    }

    /// @dev THE ONE FIGURE THE SIMULATOR CANNOT TELL US, so it is carried forward from the address
    ///      book rather than fabricated.
    ///
    ///      `openInterest18` is the VENUE's open interest in that market — the depth of the book
    ///      the vault would have to trade against. `CapacityOracle.maxNotional18` derives its depth
    ///      leg from it (`oi * depthBps / 10_000`), so it is the number capacity is sized from, and
    ///      `maxAbsoluteCap` is the immutable ceiling that bounds a lying attester's use of it.
    ///
    ///      `LighterSim` does not model an order book at all: it has no resting liquidity and its
    ///      `positionBase(market)` aggregate is the sum of OUR OWN vaults' positions, which is a
    ///      different quantity entirely — using it would collapse testnet capacity to whatever we
    ///      had already minted, and at the first deployment that is zero, which
    ///      `maxNotional18` reads as "no capacity" (`if (oi == 0) return 0`).
    ///
    ///      So the honest options were: fabricate a figure in this script, or carry forward the
    ///      measured venue figure the deployment already recorded. The book's
    ///      `.vaults[i].seedOpenInterest18` is the latter — $900k for TSLA and $50.0M for SPY, read
    ///      from the live venue API on 2026-09-09 and chosen so `openInterest18 * depthBps` equals
    ///      the `absoluteCap18` governance set. Re-attesting it keeps capacity at the size the
    ///      deployment was reviewed at and changes nothing between cycles.
    ///
    ///      STATED PLAINLY: this is the ONE attested field on testnet that is NOT read from venue
    ///      truth. `OPEN_INTEREST_18` overrides it for a tester who wants to watch the depth leg
    ///      bind, and the runbook says what that does to capacity.
    function _openInterest18(Mirror memory m) internal view virtual returns (uint256) {
        uint256 override_ = vm.envOr("OPEN_INTEREST_18", uint256(0));
        return override_ == 0 ? m.seedOpenInterest18 : override_;
    }
}
