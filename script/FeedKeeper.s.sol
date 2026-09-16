// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {KeeperScript} from "./keepers/KeeperScript.sol";
import {console2} from "forge-std/console2.sol";
import {ReplayAggregator} from "../src/sim/ReplayAggregator.sol";
import {LighterSim} from "../src/sim/LighterSim.sol";

/// @notice Keeps a deployed `ReplayAggregator` fresh on testnet **and advances the venue
///         simulator's mark to match it**. Without this, `stalenessSeconds` starves minting within
///         minutes of deploy — because Chainlink is absent on Robinhood Chain testnet (46630) and
///         nothing else advances the feed — and a tester who hits that will read a stale-feed
///         revert as a deploy failure rather than as "the keeper wasn't running".
///
/// @notice ============ IT PUSHES TWO PRICES, NOT ONE, AND THAT IS THE WHOLE POINT ============
///
///         THE BUG THIS SHAPE EXISTS TO PREVENT, measured on `anvil --chain-id 46630` rather than
///         reasoned about. Before this script advanced the venue mark, the two legs of
///         `CertOracle`'s basis band were wired to a moving number and a frozen one:
///
///           - `CertOracle.markPx18` is written ONLY by `script/keepers/Attester.s.sol`.
///           - the attester's value is ONLY `LighterSim.markPrice(market)`
///             (`script/keepers/VenueTruth.markPx18`).
///           - `LighterSim.setMarkPrice` is `onlyOwner` and was called exactly ONCE, at
///             deployment, with `seedPx18`.
///           - this script advanced the AGGREGATOR alone.
///
///         So no process ever moved the venue mark again. `CertOracle.mintAllowed()` in
///         dual-source mode fails closed when the basis exceeds `basisBandBps` (500), and one feed
///         push of +6.0% was enough:
///
///             BEFORE  mintAllowed: true   basis: (true, 0)
///             push FEED_PRICE=38862040000  (+6.0%)
///             AFTER   px 388.62e18  markPx18 366.62e18  basis (true, 566)  mintAllowed: false
///
///         **Terminal, and restarting the attester is provably a no-op** — it rewrites the same
///         frozen mark. Walking `lastGoodPx18` forward with permissionless `pokeLastGood()` cleared
///         the DEVIATION leg to 95 bps and `mintAllowed()` was STILL false, with `basis = 566` the
///         sole cause. Only a human calling `LighterSim.setMarkPrice` from `DEPLOYER_PK` reopened
///         it.
///
///         THE SECOND-ORDER CONSEQUENCE IS WORSE THAN THE MINT GATE. `LighterSim.settleBatch`
///         fills queued orders at `markPrice`. A frozen sim mark means every hedge forever fills at
///         the deployment-day price while `CertOracle.px()` follows the feed, so
///         `solvency().deltaBps` drifts without limit. That is a Global Constraint 5 divergence: a
///         venue whose price does not move is not a conservative deviation, it is a different
///         market.
///
///         Both calls are signed by `DEPLOYER_PK`, which owns the aggregators AND the simulator, so
///         this is one extra transaction per invocation and NOT a new key.
///         =====================================================================================
///
/// @dev    WHY THIS READS THE ADDRESS BOOK NOW, AND WHAT IT STILL TAKES FROM THE ENVIRONMENT.
///         Advancing the mark needs two facts this script did not previously have: the simulator's
///         address and the market index. Both are already in `deployments/<chainId>.json`, so it
///         inherits `KeeperScript` and reads them there rather than growing two more env vars —
///         the reasoning in `KeeperScript`'s NatSpec applies unchanged, and more sharply here,
///         because a hand-typed market index would push the wrong market's mark and leave the
///         intended one frozen with nothing on-chain looking wrong.
///
///         `REPLAY_AGGREGATOR` IS KEPT, as the MIRROR SELECTOR rather than as an injected address.
///         One invocation advances one mirror (the mirrors have genuinely different prices — TSLA
///         and SPY — so a single `FEED_PRICE` cannot serve both), and the aggregator address is how
///         the runbook already selects one. It is now matched against `.vaults[i].replayAggregator`
///         and the simulator and market index come from that same record, so the selector cannot
///         disagree with the market it drives.
///
/// @dev    A FOUNDRY SCRIPT RUNS ONCE PER INVOCATION AND EXITS; it cannot itself wait on
///         wall-clock time. "Advances the aggregator on an interval" means this script is meant to
///         be RE-INVOKED periodically by something outside Foundry — a shell loop, cron, a systemd
///         timer:
///
///             while true; do \
///               REPLAY_AGGREGATOR=$TSLA_AGG FEED_PRICE=36662040000 \
///                 forge script script/FeedKeeper.s.sol \
///                 --rpc-url robinhood_testnet --broadcast --slow; \
///               sleep 60; \
///             done
///
///      It never invents a price. There is no HTTP call and no other oracle read here — a
///      Foundry script has no such capability during a broadcast run, so pretending otherwise
///      would produce a script that cannot run. It only ever pushes a number the caller already
///      decided on, via one of two explicit env-driven modes:
///
///        - live mode (default): push a single price from `FEED_PRICE` (an int256 in the
///          aggregator's own decimals — 8, matching the real feeds).
///        - replay mode (`REPLAY_MODE=true`): step through a fixed, in-script price path —
///          `_replayPath()` below — one element per invocation, selected by `REPLAY_INDEX`. This
///          is for driving a deterministic demo/test path without needing any live price source
///          at all.
contract FeedKeeper is KeeperScript {
    error FeedKeeper_MissingAggregator();

    /// @dev `DEPLOYER_PK` — the key that owns both the aggregators and the simulator. Behind the
    ///      same seam as the other keepers' keys, and for the same measured reason: see
    ///      `KeeperScript._signerKey()`.
    function _signerKey() internal view virtual override returns (uint256) {
        return vm.envUint("DEPLOYER_PK");
    }

    /// @dev The mirror this invocation drives, named by its aggregator. Behind a seam for the same
    ///      reason as `_signerKey()` and `_bookJson()` — a test selects a mirror by SUBCLASSING
    ///      rather than by mutating the process environment, which Foundry does not roll back
    ///      between test cases and which races across parallel suites.
    function _selectedAggregator() internal view virtual returns (address) {
        return vm.envAddress("REPLAY_AGGREGATOR");
    }

    /// @dev The price this invocation pushes to BOTH legs, in the aggregator's own decimals.
    ///      Behind a seam for the same reason as `_signerKey()` and `_selectedAggregator()` — the
    ///      tests drive a price PATH, and doing that through `vm.setEnv` would corrupt every test
    ///      after it (Foundry does not roll `setEnv` back to the post-`setUp` snapshot, and it races
    ///      across parallel suites). Production behaviour is unchanged: the env reads below are the
    ///      only implementation that runs outside a test.
    function _feedPrice() internal view virtual returns (int256) {
        if (vm.envOr("REPLAY_MODE", false)) {
            int256[] memory path = _replayPath();
            uint256 idx = vm.envOr("REPLAY_INDEX", uint256(0)) % path.length;
            return path[idx];
        }
        return vm.envInt("FEED_PRICE");
    }

    /// @dev A fixed 8-decimal price path a tester can step through call-by-call via
    ///      REPLAY_INDEX, with no live price source required. Values are illustrative TSLA-shaped
    ///      prices around the live 2026-09-09 read (36_662_040_000 = $366.6204) used to size
    ///      ReplayAggregator's decimals().
    function _replayPath() internal pure returns (int256[] memory path) {
        path = new int256[](5);
        path[0] = 36_000_000_000; // $360.00
        path[1] = 36_300_000_000; // $363.00
        path[2] = 36_662_040_000; // $366.6204
        path[3] = 35_900_000_000; // $359.00
        path[4] = 36_100_000_000; // $361.00
    }

    function run() external {
        address aggregator = _selectedAggregator();
        if (aggregator == address(0)) revert FeedKeeper_MissingAggregator();

        Book memory book = _book();
        _requireBookMatchesChain(book);

        Mirror memory m = _mirrorFor(book, aggregator);

        int256 price = _feedPrice();

        // A zero or negative price is refused BEFORE either call rather than after the feed push.
        // `setMarkPrice(market, 0)` is the state `settleBatch` and `VenueTruth` both refuse
        // outright: at a zero mark the simulator's whole mark-to-market layer is dead — notional is
        // `|position| * 0`, so the margin gate passes vacuously at any size, and `entryPrice = 0`
        // makes `unrealisedPnl()` permanently zero. Pushing the feed first and then failing on the
        // mark would leave exactly the split this script exists to prevent.
        require(price > 0, "FEED_PRICE must be positive - a zero mark kills the simulator's mark-to-market layer");

        uint256 px18 = _toPx18(aggregator, price);

        uint256 pk = _signerKey();
        address signer = vm.addr(pk);

        // Preflight both owners before anything is sent. `push` and `setMarkPrice` are each
        // `onlyOwner` and revert with a bare selector for a wrong key, and at 60 s intervals that is
        // a cron log full of nothing. Named reasons instead, exactly as the other two keepers do.
        require(
            signer == ReplayAggregator(aggregator).owner(),
            "DEPLOYER_PK does not derive ReplayAggregator.owner() - push would revert ReplayAggregator_NotOwner"
        );
        require(
            signer == LighterSim(book.lighterSim).owner(),
            "DEPLOYER_PK does not derive LighterSim.owner() - setMarkPrice would revert LighterSim_NotOwner"
        );

        console2.log("FeedKeeper: signing as", signer);
        console2.log(string.concat("FeedKeeper: ", m.symbol, " aggregator"), aggregator);
        _logMirror(m, "marketIndex", m.marketIndex);
        _logMirror(m, "px18", px18);

        vm.broadcast(pk);
        ReplayAggregator(aggregator).push(price);

        // THE LEG THAT WAS MISSING. Same price, same block, same key — so the basis the attester
        // will publish on its next cycle is 0 bps rather than however far the feed has walked away
        // from a frozen deployment-day mark. Sent second only so a mark can never lead the feed it
        // is supposed to be tracking.
        vm.broadcast(pk);
        LighterSim(book.lighterSim).setMarkPrice(m.marketIndex, px18);
    }

    /// @dev The book record whose aggregator is the one selected. A revert and not a fallback to
    ///      mirror 0: an aggregator that is not in the book is either a stale address the operator
    ///      copied from a previous deployment or a book that no longer matches the chain, and
    ///      guessing a mirror would advance the WRONG market's mark while leaving the intended one
    ///      frozen — which is this script's own bug class, reintroduced through a convenience.
    function _mirrorFor(Book memory book, address aggregator) internal pure returns (Mirror memory) {
        uint256 n = book.mirrors.length;
        for (uint256 i = 0; i < n; ++i) {
            if (book.mirrors[i].replayAggregator == aggregator) return book.mirrors[i];
        }
        revert(
            "REPLAY_AGGREGATOR is not any .vaults[i].replayAggregator in the address book - stale address, or a book from another deployment"
        );
    }

    /// @dev `FEED_PRICE` is in the AGGREGATOR's decimals; `LighterSim.markPrice` is 1e18. The
    ///      decimals are read off the aggregator on chain rather than hardcoded at 8 — for the same
    ///      reason `VenueTruth._to18` reads the collateral's: a deployment against a
    ///      differently-scaled feed would otherwise set every venue mark off by a power of ten
    ///      while every log line still looked right.
    function _toPx18(address aggregator, int256 price) internal view returns (uint256) {
        uint8 d = ReplayAggregator(aggregator).decimals();
        require(d <= 36, "aggregator decimals() > 36 - CertOracle._tryFeed refuses this feed anyway");
        uint256 raw = uint256(price);
        uint256 px18 = d <= 18 ? raw * (10 ** (18 - d)) : raw / (10 ** (d - 18));
        require(px18 != 0, "FEED_PRICE normalises to a zero px18 - the venue mark must never be set to 0");
        return px18;
    }
}
