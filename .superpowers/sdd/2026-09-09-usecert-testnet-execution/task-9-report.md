## Task 9 report: replay-capable mock aggregator, and the feed keeper

### What was built

- `src/sim/ReplayAggregator.sol` — a deployable, `IAggregatorV3`-implementing aggregator for
  Robinhood Chain testnet (46630), where Chainlink is verifiably absent. Owner is immutable, set
  at construction; every write is owner-gated and emits an event.
  - `decimals()`, `latestRoundData()` — exact `IAggregatorV3` surface, unmodified.
  - `description()`, `version()` (fixed at `6`) — the extra Chainlink-shaped surface real RH
    feeds expose (verified live: `decimals()=8`, `description()="RHTSLA / USD"`, `version()=6`).
  - `push(int256 answer)` — one new round at `block.timestamp`.
  - `pushRounds(int256[] answers, uint256[] timestamps)` — owner-only batch replay, one round per
    element, in order. Reverts `ReplayAggregator_EmptyBatch` on a zero-length call and
    `ReplayAggregator_LengthMismatch` on mismatched array lengths.
  - `pushFrozen()` / `pushFrozenAt(uint256)` — the corporate-action-pause shape: `answer` carried
    over unchanged, `roundId` and `updatedAt` still advance.
  - `setDecimals(uint8)`, `setDescription(string)` — owner-only, so a test can flip an
    already-deployed feed into the absurd-decimals pathological state without a second
    constructor call (mirrors why `MockAggregatorV3.setDecimals` exists).
  - **`roundId` strictly increments on every write**, price-changing or not — every write path
    (`push`, `pushRounds`, `pushFrozen`, `pushFrozenAt`) routes through one internal
    `_writeRound` that unconditionally does `_roundId += 1`. This is the property Task 1's
    distinctness proof and the concurrent `pokeLastGood()` `roundId > pendingRoundId` change both
    depend on; `test_roundIdIncrementsOnEveryPush` exercises all four write paths, including two
    consecutive same-price pushes.
  - Constructor writes round 1 itself (not round 0), so a freshly deployed feed already has a
    real, positive `roundId` before any push.

- `script/FeedKeeper.s.sol` — a Foundry script that pushes exactly one round per invocation and
  exits (a script cannot itself wait on wall-clock time), meant to be re-run on an interval by
  something outside Foundry (cron / a shell loop / systemd timer — documented inline with an
  example loop). Two env-driven modes, neither of which invents a price:
  - live mode (default): `FEED_PRICE` (int256, 8-decimals) is pushed as-is.
  - replay mode (`REPLAY_MODE=true`): steps through a fixed 5-element in-script price path via
    `REPLAY_INDEX % 5`, for a demo/test run with no live price source at all.
  - `REPLAY_AGGREGATOR` (address) selects the target; `FeedKeeper_MissingAggregator` reverts on
    the zero address. No HTTP call, no other oracle read, anywhere in the script.

- `test/sim/ReplayAggregator.t.sol` — 16 tests (see below).

### Design decisions

- **No owner transfer.** The brief asked for "an immutable owner set at construction" — there is
  no `setOwner`/`transferOwner`. A lost key means redeploying the aggregator, which is acceptable
  for disposable testnet scaffolding (Global Constraint 4) and keeps the write-gate simple to
  reason about.
- **`push`/`pushFrozen` use `block.timestamp`; arbitrary/future timestamps go through
  `pushRounds`/`pushFrozenAt`.** Rather than adding a third "pushAt(answer, ts)" method not asked
  for in the brief, a future or otherwise arbitrary `updatedAt` is reproduced via `pushRounds`
  with a single-element array (exercised in
  `test_stalenessAndFutureTimestampStatesReproducible`) or via `pushFrozenAt` for the frozen
  case. This keeps the public API to exactly what the brief specifies (`push`, `pushRounds`,
  plus the frozen-state method the brief left to my judgement) without a redundant overload.
- **`startedAt == updatedAt` on every round**, matching `MockAggregatorV3`'s shape rather than
  inventing a separate "round start" clock Chainlink itself doesn't guarantee for a simple feed.
- **`FeedKeeper` pushes only `push()`, never `pushRounds()`.** One invocation, one round, so the
  interval-driven design stays a straight line from "one external trigger" to "one on-chain
  write"; a replay of a multi-round path is what the aggregator's own `pushRounds` is for
  (exercised from tests/scripts that call the aggregator directly), not something the keeper
  needs to orchestrate.

### Tests added (all in `test/sim/ReplayAggregator.t.sol`)

Required by the brief:
- `test_roundIdIncrementsOnEveryPush` — all four write paths, including a same-price push.
- `test_replaySeriesDrivesOracleGuards` — deploys a real `CertOracle` against the aggregator,
  replays a small in-band move (mint stays open) then a >5% jump (deviation breaker trips),
  isolating the breaker by keeping the attested mark on the index price throughout.
- `test_frozenPriceWithAdvancingTimeIsDetectable` — `pushFrozen()` after a 2-hour warp: answer
  unchanged, `updatedAt` and `roundId` both advance, `updatedAt == block.timestamp` (i.e. this is
  a live, freshly-reporting round, not a stale one — the two states are distinguishable).
- `test_stalenessAndFutureTimestampStatesReproducible` — staleness via a warp with no push;
  future `updatedAt` via a single-element `pushRounds`. Both drive `CertOracle.mintAllowed()` to
  `false` and `px()` to `CertOracle_StalePrice`.

Additional coverage:
- `test_matchesRealFeedShape`, `test_constructorWritesRoundOne` — the live-measured shape
  (`decimals()=8`, `description()`, `version()=6`) and that round 1 is written at construction.
- `test_onlyOwnerCanPush`, `test_onlyOwnerCanPushRounds`, `test_onlyOwnerCanPushFrozen`,
  `test_onlyOwnerCanSetDecimalsOrDescription` — every write path gated.
- `test_zeroOwnerReverts`, `test_pushRoundsEmptyReverts`, `test_pushRoundsLengthMismatchReverts`
  — constructor and input validation.
- `test_nonPositiveAnswerReproducible` — `push(0)` and `push(-1)`, driving
  `CertOracle_NonPositivePrice`.
- `test_absurdDecimalsMakesFeedUnusableForGuards` — `setDecimals(200)` (above `CertOracle`'s
  36-decimal usability bound) flips `mintAllowed()` to `false`.
- `test_pushRoundsAppliesEachElementAsItsOwnRound` — a 3-element replay batch lands as rounds
  2-4, final `latestRoundData()` reflects the last element.

### Verification

```
$ forge test
Ran 19 test suites in 2.75s: 272 tests passed, 2 failed, 0 skipped (274 total tests)
Failing tests: test_A1_capacityCapIsPerCallNotCumulative, test_A3_pokeLastGoodDefeatsTheDeviationBreaker
  (both in test/AuditPoC.t.sol — frozen, expected, untouched)
```
274 = the 258-test baseline (256 pass / 2 fail) plus the 16 new `ReplayAggregator` tests, all
passing. No existing test was edited or weakened.

```
$ forge build --sizes | grep ReplayAggregator
| ReplayAggregator   | 2,473            | 3,534             | 22,103             | 45,618              |
```
Runtime size 2,473 B against the 24,576 B EIP-170 cap — runtime margin 22,103 B, comfortably
positive.

`forge fmt --check` on all three new files: clean, no diffs.

### Anything that surprised me

- This worktree's `.superpowers/` planning tree and `lib/` git submodules were not present /
  initialized at start (only present in the main checkout). I ran
  `git submodule update --init --recursive` to pull in `forge-std` and `openzeppelin-contracts`
  so `forge build`/`forge test` would run at all, and created
  `.superpowers/sdd/2026-09-09-usecert-testnet-execution/` inside this worktree (mirroring the
  brief's stated path) to hold this report, since the shared-checkout copy is out of bounds for
  an isolated worktree agent.
- `forge build --sizes` does not list `FeedKeeper` at all (scripts aren't included in the sizes
  table), so there's no runtime-margin number to report for it — it's a one-shot broadcast
  script, never a standalone deployed contract, so EIP-170 doesn't apply to it the way it does to
  `ReplayAggregator`.
- Isolating the deviation breaker in `test_replaySeriesDrivesOracleGuards` required keeping the
  attested mark price on the live index throughout (so the basis-band guard never trips) — a
  reminder that `mintAllowed()` has two independent guards and a naive "just move the feed" test
  can't tell you which one fired.
