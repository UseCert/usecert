// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {ReplayAggregator} from "../src/sim/ReplayAggregator.sol";

/// @notice Keeps a deployed `ReplayAggregator` fresh on testnet. Without this, `stalenessSeconds`
///         starves minting within minutes of deploy — because Chainlink is absent on Robinhood
///         Chain testnet (46630) and nothing else advances the feed — and a tester who hits that
///         will read a stale-feed revert as a deploy failure rather than as "the keeper wasn't
///         running".
/// @dev A Foundry script runs once per invocation and exits; it cannot itself wait on wall-clock
///      time. "Advances the aggregator on an interval" means this script is meant to be
///      RE-INVOKED periodically by something outside Foundry — a shell loop, cron, a systemd
///      timer:
///
///          while true; do \
///            FEED_PRICE=36662040000 forge script script/FeedKeeper.s.sol \
///              --rpc-url robinhood_testnet --broadcast; \
///            sleep 60; \
///          done
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
contract FeedKeeper is Script {
    error FeedKeeper_MissingAggregator();

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
        address aggregator = vm.envAddress("REPLAY_AGGREGATOR");
        if (aggregator == address(0)) revert FeedKeeper_MissingAggregator();

        bool replay = vm.envOr("REPLAY_MODE", false);

        int256 price;
        if (replay) {
            int256[] memory path = _replayPath();
            uint256 idx = vm.envOr("REPLAY_INDEX", uint256(0)) % path.length;
            price = path[idx];
        } else {
            price = vm.envInt("FEED_PRICE");
        }

        vm.startBroadcast();
        ReplayAggregator(aggregator).push(price);
        vm.stopBroadcast();
    }
}
