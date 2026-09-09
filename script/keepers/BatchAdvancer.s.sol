// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {KeeperScript} from "./KeeperScript.sol";
import {LighterSim} from "../../src/sim/LighterSim.sol";

/// @title  BatchAdvancer — the keeper that makes the simulated venue settle.
///
/// @notice THE SEVENTH WORKER THE DESIGN SPEC NEVER NEEDED. On mainnet Lighter advances its own
///         batches; nothing in UseCert calls `settleBatch` because nothing in UseCert is the venue.
///         On testnet 46630 the venue is `src/sim/LighterSim.sol` and NOTHING ADVANCES ITS BATCHES
///         AT ALL. Without this process:
///
///           - no order ever fills, so a mint's hedge is submitted and never opened;
///           - `CertVault.bootstrap()`'s registering deposit never executes, so
///             `addressToAccountIndex[vault]` stays 0 and `createOrder` reverts
///             `AccountIsNotRegistered` — every mint reverts as one atomic transaction;
///           - no queued withdrawal ever arrives, so `recallMargin` never completes.
///
///         The deploy script calls `settleBatch()` once itself, as the simulator's owner, which is
///         what makes `bootstrap()` land. Everything after deployment is this keeper's job.
///
/// @dev    IT MUST SIGN AS THE ADDRESS THE DEPLOYMENT REGISTERED. Task 7 gated `settleBatch` to the
///         simulator's `owner` or its owner-settable `keeper`, because a permissionless settler
///         picks the block — and therefore the mark — at which someone ELSE's queued order fills.
///         `script/DeployTestnet.s.sol` calls `LighterSim.setKeeper(BATCH_KEEPER)` and records that
///         address in the address book as `.shared.batchKeeper`.
///
///         An unregistered keeper simply reverts `LighterSim_OnlyOwnerOrKeeper()`, and NOTHING
///         ON-CHAIN TELLS YOU THE TWO DISAGREE — the symptom is every `settleBatch` reverting,
///         which is indistinguishable from the keeper process being dead. So this script refuses to
///         broadcast at all unless `vm.addr(BATCH_KEEPER_PK)` matches both the book and
///         `LighterSim.keeper()` on the live chain, and says which one it is when they differ.
///         `docs/TESTNET-RUNBOOK.md` carries the matching troubleshooting row.
///
/// @dev    NO IN-SCRIPT INFINITE LOOP AND NO DAEMON. A Foundry script runs once and exits; it
///         cannot wait on wall-clock time. An external loop re-invokes it:
///
///             while true; do
///               forge script script/keepers/BatchAdvancer.s.sol \
///                 --rpc-url robinhood_testnet --broadcast --slow;
///               sleep 30;
///             done
///
///         RECOMMENDED INTERVAL: 30 s. It is not driven by any protocol deadline — an unsettled
///         order is not a starvation risk the way a stale attestation is — but it IS the latency a
///         tester experiences between "I minted" and "the hedge exists", and between "I asked to
///         exit" and "the collateral came back". 30 s keeps that inside a human's attention span
///         while staying far above the chain's block time. The bounded multi-round drain below is
///         what makes a longer interval survivable rather than cumulative.
contract BatchAdvancer is KeeperScript {
    /// @dev How many `settleBatch()` calls one invocation will make at most.
    ///
    ///      `LighterCore.SETTLE_BATCH_MAX` is 64 orders per call and `MAX_QUEUE` is 512, so a full
    ///      queue needs 8 calls to drain — deliberately, so a large queue is drained by repeated
    ///      calls rather than in one transaction that might not fit in a block. A keeper that sent
    ///      exactly one call per invocation would fall permanently behind a queue growing faster
    ///      than its interval, so it drains to empty and then stops. 512 / 64 = 8 is the ceiling;
    ///      the loop exits early the moment the queue is clear, which is the ordinary case.
    ///
    ///      THIS IS NOT THE FORBIDDEN IN-SCRIPT LOOP. It is bounded, it terminates on queue state
    ///      rather than on time, and it does not wait: the invocation still ends.
    uint256 internal constant DEFAULT_MAX_ROUNDS = 8;

    /// @dev `BATCH_KEEPER_PK` — must derive the address `LighterSim.setKeeper` was given at
    ///      deployment. See `KeeperScript._signerKey()` for why this is behind a seam.
    function _signerKey() internal view virtual override returns (uint256) {
        return vm.envUint("BATCH_KEEPER_PK");
    }

    function run() external {
        Book memory book = _book();
        _requireBookMatchesChain(book);

        LighterSim sim = LighterSim(book.lighterSim);

        uint256 pk = _signerKey();
        address signer = vm.addr(pk);

        // THE MISMATCH CASE, CAUGHT BEFORE A SINGLE TRANSACTION IS SENT. Two separate checks
        // because they fail for two different reasons and the fix differs:
        //
        //   book vs signer   -> the keeper process is running the wrong key, or against a book from
        //                       a previous deployment. Fix the process (or re-run the deployment).
        //   chain vs signer  -> the book and the process agree, but the simulator has a different
        //                       keeper on file. Only the simulator's owner can call `setKeeper`, so
        //                       this needs the deployer key, not a keeper restart.
        require(
            signer == book.batchKeeper,
            "BATCH_KEEPER_PK does not derive .shared.batchKeeper from the address book - settleBatch would revert LighterSim_OnlyOwnerOrKeeper"
        );
        address onChainKeeper = sim.keeper();
        require(
            signer == onChainKeeper || signer == sim.owner(),
            "LighterSim.keeper() on chain is neither the signer nor the owner - the deployment and this process disagree; only the sim owner can setKeeper"
        );
        require(
            onChainKeeper == book.batchKeeper,
            "LighterSim.keeper() on chain != .shared.batchKeeper - the address book is stale or was hand-edited"
        );

        console2.log("BatchAdvancer: signing as", signer);
        console2.log("BatchAdvancer: queue length before", sim.queueLength());
        console2.log("BatchAdvancer: settle cursor before", sim.settleCursor());

        uint256 maxRounds = vm.envOr("MAX_SETTLE_ROUNDS", DEFAULT_MAX_ROUNDS);
        require(maxRounds != 0, "MAX_SETTLE_ROUNDS=0 would advance nothing");

        uint256 rounds;
        for (uint256 i = 0; i < maxRounds; ++i) {
            // Called UNCONDITIONALLY the first time round, exactly as the deploy script does:
            // `settleBatch()` on an empty queue is harmless, and conditioning the call on the
            // current queue state would couple this keeper to whether the simulator's registration
            // path happens to be synchronous or asynchronous today. As shipped it is SYNCHRONOUS —
            // `LighterCore.deposit` still assigns `addressToAccountIndex` inline, and the
            // asynchronous-registration change (planned as Task 6) is not in this tree. The
            // unconditional call is forward-compatible rather than currently load-bearing, which is
            // why it stays as it is.
            vm.broadcast(pk);
            sim.settleBatch();
            ++rounds;

            // Drained: the queue and the cursor are reset together the moment settlement reaches
            // the end, so an empty queue is the terminal state and not a transient one.
            if (sim.queueLength() == 0 || sim.settleCursor() >= sim.queueLength()) break;
        }

        console2.log("BatchAdvancer: settleBatch calls sent", rounds);
        console2.log("BatchAdvancer: queue length after", sim.queueLength());

        // Loud, not fatal. Hitting the ceiling means the queue is growing faster than this keeper
        // drains it, which is an interval problem (or a stuck order) an operator needs to see —
        // but aborting the run would discard work already broadcast.
        if (rounds == maxRounds && sim.queueLength() != 0) {
            console2.log("BatchAdvancer: WARNING - queue not drained within MAX_SETTLE_ROUNDS; shorten the interval");
        }
    }
}
