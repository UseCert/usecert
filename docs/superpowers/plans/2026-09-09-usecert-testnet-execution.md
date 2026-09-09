# UseCert testnet execution plan

**Derived from:** `docs/TESTNET-PLAN.md` (decisions and reconnaissance) — read that for *why*.
This file is the executable task breakdown. **Target: a functional, rolling deployment on
Robinhood Chain testnet, chain ID 46630.**

Baseline: branch `feat/contracts-c1`, commit `756f721`, **258 tests / 256 passing** (the 2 failures
are the external auditor's PoC files, unsatisfiable as written — see below).

---

## Global Constraints

These bind every task. A violation is a review failure regardless of what the task text says.

1. **`pragma solidity 0.8.24;` exactly.** Custom errors only, never `require` strings. Do not modify
   `foundry.toml` — in particular never set `via_ir` and never relax the optimizer or size checks.
2. **`test/AuditPoC.t.sol` and `test/AttackSuite.t.sol` are FROZEN external audit evidence.** Do not
   edit them, for any reason. They currently contribute exactly 2 failures
   (`test_A1_capacityCapIsPerCallNotCumulative`, `test_A3_pokeLastGoodDefeatsTheDeviationBreaker`),
   both proven unsatisfiable as written. **256 passing / 2 failing is the green baseline.** Any
   *additional* failure is a regression you introduced.
   - `AttackSuite.t.sol:178-180` constructs `SolvencyRegistry(attester)` and
     `CapacityOracle(registry, gov, 1000, 100, 3000, 300, MAX_ABSOLUTE_CAP)`. **Those two
     constructor signatures are frozen.** It does *not* construct `CertOracle`, whose signature is
     therefore free to change.
3. **Design Law 2 is absolute.** Every non-zero redemption must remain possible. `forceExit` and
   `pxUnguarded()` must never revert for a holder with a balance, at any price, in any oracle or
   buffer state. No task may add a gate, a revert, or a read of health state to any redemption path.
4. **Design Law 6.** No owner, keeper, pause or upgrade path in the **protocol** contracts —
   `src/*.sol`, explicitly **excluding `src/sim/`**, which is disposable testnet scaffolding.
   `rebalance()`,
   `recallMargin()`, `settleMint()`, `refundMint()`, `stageRefund()`, `forceExit()`, `bootstrap()`
   and `seedBuffer()` stay permissionless. The venue simulator under `src/sim/` is the deliberate
   exception and *must* be access-controlled (Task 5) — it stands in for a third party, not for
   UseCert, and an ungated simulator knob is how testnet silently certifies a bad design.
5. **The simulator must never be easier than mainnet.** Every deviation from real venue behaviour
   must fail in the *conservative* direction. This project has shipped three defects that a passing
   suite could not see because the mock was more permissive than the venue (unmodelled margin,
   unmodelled PnL, unenforced EIP-170). Treat any "testnet passes where mainnet would fail" as
   Critical.
6. **EIP-170.** Every deployable contract, simulators included, must show a positive runtime margin
   under `forge build --sizes`. Foundry does **not** enforce this in `forge test`, so a green suite
   is not evidence. Run it.
7. **No new external dependencies.** OpenZeppelin v5.7.0 and forge-std v1.16.2 only.
8. **Never weaken or delete an existing passing test.** If a test must change because behaviour
   legitimately changed, say so explicitly in your report with the reasoning — do not edit quietly.
9. **Read-only toward the counterparty.** Never clone, run, install, or push to
   `sleroy1312-arch/usecertlah`. No task in this plan touches it.
10. **Commit messages carry no `Co-Authored-By` trailer.** Project rule.

**Verified venue parameters — use these exact values, they were measured live on 2026-09-09:**

| Parameter | Value | Source |
| --- | --- | --- |
| Testnet chain ID | `46630` | `cast chain-id` against `https://rpc.testnet.chain.robinhood.com` |
| Initial margin fraction, all 57 markets | `5000` (50% of `ASSET_MARGIN_TICK = 10_000`) | venue API |
| TSLA | `market_id 16`, `price_decimals 2`, `size_decimals 4` | venue API |
| SPY | `market_id 26`, `price_decimals 2`, `size_decimals 4` | venue API |
| Maker / taker fee | `0.0000` / `0.0000` | venue API |
| Measured feed-vs-mark basis | 11.3–49.3 bps | 13 markets, live |
| Chainlink on testnet 46630 | **absent** | `cast code` → `0x` on six proxies |
| Lighter on testnet 46630 | **absent** | `cast code` → `0x` on both candidate addresses |

---

## Task 1: `roundId`-based round distinctness, and an independent poke window

**Files:** `src/CertOracle.sol`, `src/interfaces/IAggregatorV3.sol`, `test/CertOracle.t.sol`,
`test/helpers/VaultFixture.sol`, `test/CertFactory.t.sol`

### The problem

`pokeLastGood()` (the H-1 deviation-breaker fix) proves that its confirming feed observation is a
*different, fresher round* than its arming observation by comparing timestamps against
`stalenessSeconds`:

> `t_conf >= block.timestamp - stalenessSeconds > pendingSince >= t_arm`

That works, but it welds the breaker's rate limit to the feed-freshness bound. `TESTNET-PLAN.md` §1
sets `stalenessSeconds = 93_600` (26 h) on mainnet, so each clamped `deviationBps` step would cost
26 hours and a 20% repricing would keep minting shut for ~4.3 days.

### The fix

Prove distinctness **directly**, using the round ID the feed already returns and `CertOracle`
currently discards at `src/CertOracle.sol:157` (`_readFeed`) and `:186` (`_tryFeed`).

1. Have `_readFeed` and `_tryFeed` return the `roundId` (first member of `latestRoundData()`,
   `uint80`). Keep every existing guard exactly as it is — the future-timestamp check must stay
   first so it still short-circuits the subtraction, and the `answer <= 0` and decimals handling are
   unchanged.
2. Add `uint80 public pendingRoundId;` recorded when a candidate is armed.
3. Add `uint256 public immutable pokeConfirmationSeconds;` as a **new constructor parameter,
   appended last** so existing argument order is untouched.
4. `pokeLastGood()` confirms a candidate when **both** hold:
   - `block.timestamp - pendingSince > pokeConfirmationSeconds` (the rate limit), and
   - `roundId > pendingRoundId` (**the distinctness proof**, no longer inferred from time).
5. Constructor validation: revert `CertOracle_ConfigOutOfBounds()` if `pokeConfirmationSeconds == 0`
   (a zero window would let a poke sequence confirm within one block, which is exactly what H-1
   fixed).
6. Rewrite the NatSpec block at `src/CertOracle.sol:347-355` that argues for reusing
   `stalenessSeconds`. It is now wrong. Replace it with the `roundId` argument, and state explicitly
   that the two knobs are deliberately independent and why.

### Tests — add to `test/CertOracle.t.sol`

- [ ] `test_pokeConfirmsOnNewRoundIdAfterWindow` — arm, warp past `pokeConfirmationSeconds`, advance
      the mock feed's `roundId` with the same price, and assert the reference advances.
- [ ] `test_pokeRejectsSameRoundIdEvenAfterWindow` — **the distinctness proof.** Arm, warp well past
      the window, but do *not* advance `roundId`. Assert it reverts
      `CertOracle_ReferenceRateLimited` (or a named error) and the reference does **not** move. This
      is the test that replaces the timestamp inequality; without it the fix is unproven.
- [ ] `test_pokeRejectsNewRoundIdBeforeWindow` — advance `roundId` but warp less than the window.
      Must revert.
- [ ] `test_pokeWindowIsIndependentOfStaleness` — construct with `stalenessSeconds = 93_600` and
      `pokeConfirmationSeconds = 3_600`, and assert a poke confirms one hour after arming. **This
      is the whole point of the task** — assert the numbers, not just the absence of a revert.
- [ ] `test_constructorRejectsZeroPokeWindow`.
- [ ] `test_transientSpikeStillExpires` — the existing re-arm-from-scratch behaviour must survive:
      arm at price A, move out of band relative to A, and assert the candidate re-arms rather than
      confirming.

`MockAggregatorV3` needs a settable `roundId` that increments on `set()`. Keep its existing
constructor signature working; add an overload or a separate setter rather than breaking the 13
existing call sites.

### Verification

Update every `new CertOracle(...)` site (13 of them: `test/CertOracle.t.sol` ×11,
`test/helpers/VaultFixture.sol:53`, `test/CertFactory.t.sol:44`) to pass the new parameter. Use
`3600` in the fixture. Full suite must return to **256 passing / 2 failing**, and report the exact
numbers.

---

## Task 2: `SINGLE_SOURCE` oracle mode

**Files:** `src/CertOracle.sol`, `test/CertOracle.t.sol`, plus the construction sites from Task 1.

### The problem

28 of the venue's 57 perp markets have **no Chainlink feed** — 20.5% of open interest, including
XAU (gold, $12.5M OI), ANTHROPIC ($4.88M), XAG, OPENAI and SHEIN. The project has decided to keep
these in scope. With the venue's own mark as the only price source, the current contract fails
**silently**:

- `basisBpsChecked()` returns `known = true, bps = 0` — it *asserts a healthy basis it never
  computed*.
- Two of `mintAllowed()`'s three guards degenerate, because the feed and the cross-check are the
  same number.
- Only the deviation clamp survives, and that is a rate limit, not a truth check.

This is worse than a loud failure: nothing in the contracts, the suite or the deployment checklist
would flag a vault deployed this way.

### The fix

1. Add `bool public immutable singleSource;` as a **new constructor parameter, appended last**
   (after Task 1's). When true, the deployment is declaring that `feed` and the venue mark are not
   independent.
2. `basisBpsChecked()` in single-source mode must return **`known = false`** — absent, not vacuous.
   It must never return `known = true, bps = 0`.
3. `basisBps()` in single-source mode reverts a named `CertOracle_NoIndependentBasis()`, rather than
   returning a meaningless zero.
4. `mintAllowed()` in single-source mode **skips the basis band entirely** (it is not a guard here)
   and keeps staleness and deviation. Document in NatSpec that the guard set is deliberately
   smaller and that the deviation clamp is the only remaining defence.
5. Require a **tightened deviation bound** in single-source mode: revert
   `CertOracle_DeviationTooWideForSingleSource()` at construction if
   `deviationBps > MAX_SINGLE_SOURCE_DEVIATION_BPS`, a new `public constant` set to `200` (2%). A
   venue-priced asset whose only guard is a rate limit must have a tight one.
6. Do **not** change any behaviour when `singleSource == false`. Every existing test must pass
   untouched.

### Tests

- [ ] `test_singleSourceBasisIsAbsentNotZero` — **the core defect.** Assert
      `basisBpsChecked()` returns `known == false`, and assert that in dual-source mode with a
      matching feed and mark it returns `known == true, bps == 0`. The two must be distinguishable;
      that they were not is the bug.
- [ ] `test_singleSourceBasisBpsReverts` — `CertOracle_NoIndependentBasis`.
- [ ] `test_singleSourceMintAllowedIgnoresBasisBand` — set a mark far from the feed and assert
      minting is still allowed, because the band is meaningless here.
- [ ] `test_singleSourceStillEnforcesStalenessAndDeviation` — both guards must still bite.
- [ ] `test_constructorRejectsWideDeviationInSingleSource` — at `201` bps.
- [ ] `test_dualSourceBehaviourUnchanged` — construct with `singleSource = false` and assert
      `basisBpsChecked`, `basisBps` and `mintAllowed` behave exactly as before.

### Verification

Full suite back to **256/2**. Report whether any pre-existing test changed behaviour — the answer
should be none.

---

## Task 3: bound `_readFeed`'s decimals, closing the documented asymmetry

**Files:** `src/CertOracle.sol`, `test/CertOracle.t.sol`

`_tryFeed` bounds the feed's reported decimals at 36 and treats anything above as an unusable feed.
**`_readFeed` — which `px()` uses, and therefore both mint paths — has no such bound.** A feed
reporting `decimals() >= 96` makes `px()` panic, killing minting with an anonymous panic instead of
a named error. `docs/DEPLOYMENT-CHECKLIST.md` §2 records this as a known asymmetry.

Apply the same bound in `_readFeed`, reverting a named error (`CertOracle_FeedDecimalsOutOfRange()`)
rather than panicking. Copy the guard from `_tryFeed`; do not invent a different bound.

**Law 2 check:** confirm by test that `pxUnguarded()` and therefore `forceExit` are unaffected —
redemption must survive a feed this broken. State the result explicitly in your report.

### Tests

- [ ] `test_readFeedRevertsNamedOnAbsurdDecimals` — a feed reporting `decimals() == 96`: `px()`
      reverts `CertOracle_FeedDecimalsOutOfRange`, not a panic.
- [ ] `test_forceExitSurvivesAbsurdFeedDecimals` — the Law 2 proof. A holder with a balance can
      still exit while the feed reports 96 decimals.
- [ ] Update `docs/DEPLOYMENT-CHECKLIST.md` §2's row to record that the asymmetry is closed.

---

## Task 4: extract `LighterCore`, add a deployable `LighterSim`

**Files:** new `src/sim/LighterCore.sol`, new `src/sim/LighterSim.sol`,
`test/mocks/MockLighter.sol`, `test/mocks/MockLighter.t.sol`

### Why extraction rather than promotion

`MockLighter` is the starting point — it already models margin enforcement with
`InsufficientMargin()`, mark-to-market PnL with entry-price tracking, `getPendingBalance` /
`withdrawPendingBalance`, account registration and `depositCapTicks` refusal. That fidelity is why
the C1 audit's unrecallable-gain Critical was findable at all.

But it cannot simply be promoted: **132 `settleBatch` call sites** across the suite, and **3 tests
depend on it reverting `InsufficientMargin`**. Nor can it be copied — a copy silently drifts from
the contract the unit tests certify, which is the same drift problem this project already monitors
in the counterparty's repo.

So: extract the shared venue mechanics into `LighterCore`, have `MockLighter` inherit it and keep
its existing test-only conveniences, and add `LighterSim` as the deployable subclass. **One
behaviour implementation, two front ends.**

### Requirements

1. `LighterCore` holds the state and mechanics: accounts, positions, entry prices, margin, pending
   balances, the order queue, `settleBatch` logic, mark prices, per-market config.
2. `MockLighter extends LighterCore` and keeps every currently-public test hook so **all 258 tests
   compile and behave identically**. This is the acceptance bar for the task.
3. `LighterSim extends LighterCore`, adds nothing permissive, and is the contract deployed to
   testnet. Access control is Task 5 — do not add ad-hoc gating here.
4. `LighterCore` must implement `ILighter` exactly. Any place `MockLighter` currently has a
   convenience signature that the real venue does not expose, note it in your report.
5. **Run `forge build --sizes` and report `LighterCore`, `MockLighter` and `LighterSim` runtime
   bytes with their margins.** `MockLighter` has never been size-checked because it is a test file.
   If `LighterSim` exceeds EIP-170, that is the task's real finding — report it rather than working
   around it with `via_ir`.

### Tests

- [ ] All 258 existing tests still compile and run: **256 pass / 2 fail**, unchanged.
- [ ] `test_simAndMockShareBehaviour` in a new `test/sim/LighterSim.t.sol` — run the same
      deposit → createOrder → settleBatch → withdraw sequence against both and assert identical
      resulting state. This is what proves the extraction did not fork behaviour.
- [ ] `test_simIsDeployableUnderEip170` — assert `address(new LighterSim(...)).code.length > 0` and
      under 24_576.

---

## Task 5: access control on the simulator, and no vacuous margin gate

**Files:** `src/sim/LighterSim.sol`, `src/sim/LighterCore.sol`, `test/sim/LighterSim.t.sol`

**This is the highest-risk item in the whole plan.** Two ways the simulator silently certifies a
design mainnet would reject:

1. **`setRequiredMarginBps` is ungated `external`.** On a public testnet, any address can set it to
   `0` — or to Lighter's foreign-testnet `500` — and the simulator then approves positions the real
   venue refuses. Silently, with no event, every test still green.
2. **`markPrice` defaults to `0`.** At a zero mark, `settleBatch`'s notional is zero and the
   `InsufficientMargin` gate **passes vacuously**. A deploy script that forgets `setMarkPrice` looks
   completely clean and certifies a vault against a venue with no margin requirement at all.

### Requirements

1. Add an `owner` to `LighterSim` (immutable, set at construction) and gate **every** operator knob:
   `setRequiredMarginBps`, `setMarkPrice`, `setDepositCapTicks`, and any other setter. Revert a
   named `LighterSim_OnlyOwner()`. Emit an event from each.
2. **Floor the margin fraction.** `setRequiredMarginBps` must revert
   `LighterSim_MarginBelowVenueFloor()` below `VENUE_IMF_BPS = 5000`, a `public constant` matching
   all 57 live RH markets. Raising it is allowed; lowering it below the real venue's requirement is
   not. Document that 5000 is measured, not chosen.
3. **Make a zero mark fail closed.** `settleBatch` must revert a named
   `LighterSim_MarkPriceUnset(uint16 marketIndex)` when it would evaluate margin for a market whose
   mark is zero — never pass vacuously. Apply this in `LighterCore` so `MockLighter` inherits it
   too; if that breaks existing tests, those tests were relying on the vacuous gate, so fix the
   tests to set a mark and **say so explicitly in your report**.
4. `LighterSim`'s constructor must take the IMF and reject anything below the floor, so a
   misconfigured sim cannot be deployed at all.

### Added by the Task 4 review — routed here, and this is the most urgent item in the plan

**C1 — the deployed simulator is an unconditional drain, and the operator gating above does NOT
close it.** `LighterCore.withdraw(accountIndex, ...)` gates only on `accountIndex == 0` and never
binds `msg.sender`; it then credits `_pending[msg.sender]` out of a single global `marginBalance`.
So any address passes a literal non-zero index, takes `min(baseAmount, equity())` — every
depositor's collateral — and drains it via `withdrawPendingBalance`. No deposit, no registration,
one transaction. `createOrder` and `cancelAllOrders` share the unbound gate, so any address can also
queue orders onto the shared position and `delete _queue` the vault's hedge.

This is **not a regression** — it is identical in the pre-refactor mock — but Task 4 is what made it
deployable, and it is a **fidelity** defect as much as a safety one: the real venue derives the
acting account from `msg.sender` via `validateAndGetAccountIndexFromAddress`. The simulator
diverging from that in the *permissive* direction is a Global Constraint 5 violation.

7. **Bind every account-scoped entry point to its caller.** In `LighterCore`, require
   `accountIndex == addressToAccountIndex[msg.sender]` on `withdraw`, `createOrder` and
   `cancelAllOrders`, reverting a named `LighterCore_AccountNotCaller()`. Make
   `cancelAllOrders(accountIndex)` stop ignoring its argument. This is venue fidelity, so it belongs
   on the core rather than on `LighterSim`, and it must apply to `MockLighter` too. Expect existing
   tests to need a `prank` — list every one you touch and why.
8. **Add the fail-closed mark guard the refactor should have carried (review finding I1).** The
   reviewer established that a `LighterSim`-only override reverting `MarkPriceUnset()` is
   behaviour-neutral for all existing tests, because `test/mocks/MockLighter.t.sol:39-58`
   deliberately settles with no mark set — so the guard cannot go on the core, but it can go on
   `LighterSim`. Item 3 above already requires this; the review confirms independently that it is
   both necessary and free.

**Why C2 is worse than first reported:** at `markPrice == 0`, `_applyFill` records
`entryPrice = 0`, and `_pnl18` early-returns on `entry == 0`. So `unrealisedPnl()` is always 0 and
`equity() == marginBalance` — **the entire mark-to-market layer is dead on the deployed artefact**,
not merely the margin check. That layer exists because unmodelled PnL is precisely what hid the C1
audit Critical. Until items 3 and 8 land, the deployed simulator sits in the exact epistemic state
that produced that finding.

### Tests

- [ ] `test_withdrawRejectsAnUnboundCaller` — **the C1 proof.** A stranger who never deposited calls
      `withdraw` with a non-zero index and must revert `LighterCore_AccountNotCaller`. Assert the
      simulator's collateral balance is unchanged. Then prove the drain existed: assert that the
      same call *succeeded* before the fix by keeping a regression test that pins the new revert.
- [ ] `test_createOrderRejectsAnUnboundCaller`, `test_cancelAllOrdersRejectsAnUnboundCaller`.
- [ ] `test_cancelAllOrdersOnlyTouchesTheCallersQueue` — it currently ignores its argument entirely.
- [ ] `test_setRequiredMarginBpsIsOwnerOnly` — a stranger reverts `LighterSim_OnlyOwner`.
- [ ] `test_marginCannotGoBelowVenueFloor` — owner setting `4999` reverts; `5000` and `9000` succeed.
- [ ] `test_constructorRejectsMarginBelowFloor`.
- [ ] `test_settleBatchRevertsOnUnsetMarkPrice` — **the vacuous-gate proof.** Deposit, create an
      order, call `settleBatch` without ever setting a mark, and assert it reverts
      `LighterSim_MarkPriceUnset` rather than filling an unmargined position.
- [ ] `test_ownerKnobsEmitEvents`.

---

## Task 6: make `withdraw` and account registration asynchronous

**Files:** `src/sim/LighterCore.sol`, `test/mocks/MockLighter.sol`, affected tests

Two places the mock is **easier than mainnet**, both of which let testnet pass where mainnet fails.

### 6a — `withdraw` must not credit in the calling transaction

The real `ZkLighter.withdraw` performs **no balance check**: it validates flags and enqueues a
priority request, and an insufficient request is rejected *inside the rollup* with no on-chain
signal and no rollback. The caller sees success and the cash never arrives. `getPendingBalance` is
the only on-chain evidence a withdrawal executed — this is exactly why `CertVault` has a two-phase
`recallMargin` reconciled against confirmed arrival.

The mock currently credits the pending balance synchronously, so `_sweepPending`'s
"the money may simply never come" path is never exercised on testnet.

**Fix:** `withdraw` enqueues; the pending balance is credited only when `settleBatch` processes the
request. An unfulfillable request must be **consumed with nothing credited**, and emit an event
recording the silent rejection so a testnet observer can see what mainnet would hide.

### 6b — account registration must not resolve in the calling transaction

`deposit()` currently assigns `addressToAccountIndex` inline. On the real venue the index resolves
only when the rollup executes the registering deposit, which is why `createOrder` reverts
`AccountIsNotRegistered` until then — and `docs/DEPLOYMENT-CHECKLIST.md` step 8 calls that wait
**"the real sequencing guarantee"**. A deploy script validated against the current mock has never
exercised the window it exists to protect.

**Fix:** `deposit()` enqueues the registration; `addressToAccountIndex` is populated by
`settleBatch`. `createOrder` and `withdraw` revert `AccountIsNotRegistered` before that.

### Expect existing tests to break, and treat that as the signal

Some of the 256 passing tests will now need a `settleBatch()` between setup and first order. **That
is the same evidence as the margin-enforcement change that broke 9 tests and proved the gap was
real.** Update them minimally, and **list every changed test in your report with the reason**. Do
not weaken an assertion to make it pass.

### Added by the Task 4 review — finding I2, fix it while restructuring `withdraw`

The `_fundPending()` divergence is conservative in *direction* but **fails late and mid-state**.
When a gain-drawing withdrawal exceeds what the simulator can pay, `withdraw` currently **succeeds**
— debiting `marginBalance`, rewriting `entryPrice` through `_realiseGain`, and crediting
`_pending`/`_pendingTotal` — and only the later `withdrawPendingBalance` reverts on the token
transfer. The result is a permanently unsweepable pending credit against books that have already
moved, which on testnet presents as a vault wedged in `_sweepPending` forever: a genuinely
confusing failure to debug.

Since this task restructures `withdraw` into an enqueue-then-fulfil shape anyway, make the decision
point fail closed: a request the simulator cannot fund must be refused, or consumed with nothing
credited and nothing mutated, but never half-applied. Add a test asserting `marginBalance`,
`entryPrice` and `_pendingTotal` are **all** unchanged after such a refusal.

### Tests

- [ ] `test_withdrawCreditsOnlyAfterBatch` — pending balance stays 0 until `settleBatch`.
- [ ] `test_unfulfillableWithdrawIsConsumedSilently` — request above equity: no revert at request
      time, nothing credited after the batch, and the rejection event fired. **This is the mainnet
      behaviour that matters most and the one the mock was hiding.**
- [ ] `test_createOrderRevertsBeforeRegistrationBatch` — deposit, then `createOrder` without a
      batch: `AccountIsNotRegistered`.
- [ ] `test_registrationResolvesAfterBatch`.
- [ ] `test_vaultBootstrapSequenceMatchesChecklistStep8` — mirror the real sequence: transfer
      collateral, `bootstrap()`, assert a mint reverts atomically, `settleBatch()`, assert the mint
      then succeeds.

---

## Task 7: per-account state isolation, so one simulator can serve several vaults

**Files:** `src/sim/LighterCore.sol`, `test/sim/LighterSim.t.sol`

`TESTNET-PLAN.md` §6 requires the simulator to be shared across mirrors while each vault gets its
own `CertOracle` and `CertVault`. The current mock has three cross-vault denial-of-service vectors,
and each would produce failures that *look like vault bugs and are not*:

1. **`settleBatch` reverts wholesale** when one account's order is under-margined, so one vault's
   bad order freezes every other vault's settlement.
2. **`cancelAllOrders` ignores its `accountIndex`** and deletes the global queue — one vault cancels
   everyone's orders.
3. **`marginBalance` is a single shared pool** every depositor draws on.

### Requirements

1. Key margin, positions, entry prices and pending balances **by account index**, not globally.
2. `cancelAllOrders(accountIndex)` must remove only that account's queued orders.
3. `settleBatch` must **reject the individual order** and continue, emitting an event naming the
   order and reason, rather than reverting the batch. Keep a `strictMode` flag (owner-only,
   default off) that restores revert-on-first-failure, because **3 existing tests depend on
   `settleBatch` reverting `InsufficientMargin`** — run those tests in strict mode rather than
   changing them.
4. Bound `settleBatch`'s loop with a cursor so a large queue cannot exceed the block gas limit.

### Amended after the Task 5 review — this task now owns the real fix for the drain

Task 5 bound each account-scoped call to its caller, which was necessary and insufficient. A
reviewer demonstrated the drain still open in three transactions against the post-fix artefact: an
attacker calls `deposit(self, _, _, 0)` — a **zero-value** transfer, which OZ permits without
allowance — is registered for free, and the caller binding is then *satisfied*. `withdraw`'s
ceiling is `equity()`, which is `marginBalance + unrealisedPnl()` with **no account parameter at
all**. Measured: an address holding nothing took both depositors' full 1,000,000e6 and left the
simulator at zero, identical to the pre-fix result.

So the following is not a fidelity improvement, it is the actual remedy:

0. **`withdraw`'s ceiling must be the caller's own account balance plus its own share of PnL —
   never the global pool.** `equity()` must take an account index, and every consumer must pass
   one. This is what makes "a single-vault deployment is safe" a fact rather than an assumption.
   Task 5 shipped an owner-gated registration allowlist as an interim that closes the drain by
   shrinking the account set to `{vault}`; once this item lands, that allowlist becomes defence in
   depth rather than the only thing standing between an attacker and the pool, and whether to keep
   it is then a free choice. Do not remove it in this task.
1. **`settleBatch` must reject the individual order and continue** — see item 3 below. The Task 5
   review found that scoping `cancelAllOrders` to its own account, combined with `settleBatch`
   reverting wholesale, created a **permanent unrecoverable settlement DoS**: a self-registered
   attacker with zero collateral queues one oversized order and every future `settleBatch` reverts
   `InsufficientMargin` forever, with no operator cancel path and `requiredMarginBps` only
   raisable. Pre-fix, anyone could `delete _queue` and unstick it; that escape disappeared. Task 5
   added an owner escape hatch as an interim. **Item 3's per-order rejection is the structural
   fix** and it must land here.
2. **Gate `settleBatch`** (owner, or an owner-settable keeper address). The Task 5 review judged
   leaving it permissionless defensible *today* only because `setMarkPrice` is now owner-only and
   there is a single global position, so a caller timing a fill has no counterparty leg to profit
   from. **The moment this task gives accounts separate positions that stops being true**, and a
   caller choosing which block — and therefore which mark — someone else's queued order fills at
   becomes a real griefing vector. Rate-limiting was considered and rejected: it adds a liveness
   hazard for no gain.

### Tests

- [ ] `test_selfRegisteredStrangerCannotDrainThePool` — **the regression test for the miss.**
      Register via a zero-value deposit, then attempt `withdraw` of the pool. Assert it is bounded
      by the caller's own balance (zero), and assert the simulator's collateral and every other
      account's balance are unchanged.
- [ ] `test_equityIsPerAccount` — two funded accounts, assert each sees only its own.
- [ ] `test_oneAccountsBadOrderCannotBrickSettlement` — the Critical 2 regression: a stranger's
      unmargined order is rejected individually and every other account still settles.
- [ ] `test_twoVaultsShareOneSimWithoutInterference` — two vaults, both mint, one deliberately
      under-margined; assert the healthy vault still settles and its position is correct.
- [ ] `test_cancelAllOrdersOnlyAffectsCallerAccount`.
- [ ] `test_marginIsIsolatedPerAccount` — vault A cannot spend vault B's margin.
- [ ] `test_strictModeStillRevertsOnInsufficientMargin` — the compatibility path.
- [ ] `test_settleBatchCursorBoundsGas` — queue many orders, assert `settleBatch` completes in
      bounded gas and can be called repeatedly to drain.

---

## Task 8: events, deposit-cap enforcement, and a test-collateral faucet

**Files:** `src/sim/LighterCore.sol`, `src/sim/LighterSim.sol`, new `src/sim/TestFaucet.sol`,
`test/sim/LighterSim.t.sol`

1. **Events.** The simulator currently emits essentially nothing, so no indexer or dashboard can
   observe it. Emit on: deposit, registration resolved, order enqueued, order filled (with fill
   price and size), order rejected (with reason), withdrawal enqueued, withdrawal fulfilled,
   withdrawal silently rejected, mark price updated, batch settled (with batch id). Index by account
   and market where a consumer would filter on them.
2. **Deposit cap and tick size.** Enforce that deposits are exact multiples of `tickSize` and under
   `depositCapTicks`, and validate `assetIndex`. The real venue rejects on all three and
   `CertVault`'s mint path is documented to pause cleanly when the cap binds — currently untestable.
3. **Faucet.** A separate `TestFaucet` contract that dispenses the test collateral ERC-20, rate
   limited per address per interval. Keep it **out of** `LighterSim` — the venue does not mint
   collateral and blurring that is how the "venue can always pay" problem started.

### Tests

- [ ] `test_eventsEmittedForFullMintLifecycle` — use `vm.expectEmit` across the whole
      deposit → order → batch → fill sequence.
- [ ] `test_depositRejectsNonTickMultiple`, `test_depositRejectsAboveCap`,
      `test_depositRejectsUnknownAsset`.
- [ ] `test_faucetRateLimits`.
- [ ] `test_faucetIsNotTheVenue` — assert `LighterSim` has no function that mints collateral.

---

## Task 9: replay-capable mock aggregator, and the feed keeper

**Files:** new `src/sim/ReplayAggregator.sol`, new `script/FeedKeeper.s.sol`,
`test/sim/ReplayAggregator.t.sol`

Chainlink is **absent on testnet 46630** (six proxies probed, all `0x`), so the deployment needs its
own aggregator per asset.

1. `ReplayAggregator` implements `IAggregatorV3` faithfully: `latestRoundData()` returning
   `(roundId, answer, startedAt, updatedAt, answeredInRound)`, plus `decimals()` (**8**, matching
   the real RH feeds), `description()` and `version()`.
2. `roundId` **must increment on every price write** — Task 1's distinctness proof depends on it.
3. It must be able to **replay a recorded series**: an owner-only `pushRounds(answers[],
   timestamps[])` so a test can drive a real historical price path, plus a single `push(answer)`.
4. It must be able to reproduce the pathological states the real feeds exhibit, because these are
   the ones `CertOracle`'s guards exist for: a stale round (no update for longer than
   `stalenessSeconds`), a **frozen** price with an advancing timestamp (Robinhood's corporate-action
   pause), a future `updatedAt`, a non-positive answer, and absurd `decimals()`.
5. `script/FeedKeeper.s.sol` advances the aggregator on an interval. Without it,
   `maxAttestationAgeSec` starves minting within minutes of deploy and a tester will read that as a
   deploy failure.

### Tests

- [ ] `test_roundIdIncrementsOnEveryPush` — Task 1 depends on this.
- [ ] `test_replaySeriesDrivesOracleGuards` — push a recorded path and assert `mintAllowed()`
      transitions as expected.
- [ ] `test_frozenPriceWithAdvancingTimeIsDetectable` — the corporate-action pause shape.
- [ ] `test_stalenessAndFutureTimestampStatesReproducible`.

---

## Task 10: `script/DeployTestnet.s.sol` and the address book

**Files:** new `script/DeployTestnet.s.sol`, new `script/config/testnet.json`,
new `test/script/DeployTestnet.t.sol`

`docs/DEPLOYMENT-CHECKLIST.md` is **normative** — read §0, §4, §5, §6 and §9 before writing a line.

### Requirements

1. **Chain-ID guard.** Revert unless `block.chainid == 46630`.
2. **Three senders**, because §4 requires it: `DEPLOYER_PK`, `GOV_PK`, `ATTESTER_PK` from env.
   `SolvencyRegistry` and `CertOracle` bind `governance = msg.sender` at construction and are
   immutable, so they must be deployed **inside `vm.startBroadcast(GOV_PK)`, at depth 1** — never
   from a script contract, or governance lands on an address nobody controls and attester rotation
   is unreachable forever.
3. **Order:** simulators (`LighterSim`, `ReplayAggregator`, test collateral, `TestFaucet`) from the
   deployer → `SolvencyRegistry` and `CertOracle` from governance → `CapacityOracle`, `CertFactory`
   and the vault from the deployer → governance phase (`registerVault`, `setAbsoluteCap`,
   `setBufferThresholds`) → collateral transfer → `bootstrap()` → **`LighterSim` batch advance**
   (Task 6b makes this mandatory) → attester phase (`attest`, `setMarkPrice`) → assert the mint gate
   is actually open.
3a. **`setDepositorAllowed(vault, true)` on `LighterSim`, BEFORE `bootstrap()`.** Task 5's fix
   round added an owner-gated registration allowlist to the simulator as the interim that closes
   the self-registration drain, so **`vault.bootstrap()` reverts `LighterSim_DepositorNotAllowed`
   until the vault is allowed.** It fails closed, which is right, but it is a deployment step that
   exists in no earlier document — `docs/DEPLOYMENT-CHECKLIST.md` was off-limits to the task that
   introduced it. Put it in the script, **and add the corresponding row to the checklist as part of
   this task.** Without it the deployment stops at step 7 with an error nothing explains.
4. **`absoluteCap18` must be set by governance or the vault cannot mint at all** — it is zero by
   default and `min()` makes zero mean no capacity. This is the single most common way this
   deployment will appear broken.
5. **Testnet parameters** (from `TESTNET-PLAN.md` §1 and §3), each as a named constant with a
   comment saying why it differs from mainnet:
   `targetMarginBps = 9000` (**never relax this**), `instantCap18 = 1_000e18`, `settleWindow = 1 days`,
   `settleBandBps = 500`, `stalenessSeconds = 900`, `pokeConfirmationSeconds = 300`,
   `deviationBps = 500` (**never 0** — at zero the clamp permits no advance and minting locks shut
   on the first tick), `basisBandBps = 500`, `depthBps = 1000` within `[100, 3000]`,
   `maxAttestationAgeSec = 300`, `maxAbsoluteCap = 1_000_000_000e18`, `venueWithdrawCap = type(uint64).max`.
   Add a loud comment that `stalenessSeconds = 900` is a **testnet reachability value and must not
   be carried to mainnet**, where §1 sets 93_600.
6. **Assets:** deploy **uTSLA (market 16)** first, then **uSPY (market 26)**. Not NVDA — SPY has a
   Chainlink feed on mainnet and 55× TSLA's capacity. Both `price_decimals 2`, `size_decimals 4`.
7. **Every `docs/DEPLOYMENT-CHECKLIST.md` §9 read-back as a `require()`** with a named message, so a
   bad deploy aborts before broadcasting rather than half-completing.
8. **Address book:** write `deployments/46630.json` with every deployed address, the block number,
   the commit hash, and the parameters used. **Versioned per deployment, never hand-edited** — each
   new mirror is a new vault *and* a new certificate token, and a hand-edited map would silently
   repoint a UI at a new token while balances sit in the old one.

### Tests

- [ ] `test_deployScriptRunsCleanOnAnvil` — run the whole script against a local fork/anvil chain
      with `chainid` overridden, and assert every §9 read-back passes.
- [ ] `test_deployedVaultCanMintAndForceExit` — the end-to-end proof: mint, then `forceExit`, both
      against the freshly deployed stack.
- [ ] `test_scriptRevertsOnWrongChainId`.
- [ ] `test_scriptRevertsIfAbsoluteCapUnset` — prove the most likely misconfiguration is caught.

---

## Task 11: `VerifyTestnet.s.sol`, the smoke test, and the size gate

**Files:** new `script/VerifyTestnet.s.sol`, new `script/smoke/SmokeTest.s.sol`,
new `script/check-sizes.sh`

1. **`VerifyTestnet.s.sol` is separate from the deploy script and this is not redundancy.**
   `forge script --broadcast` simulates the entire run first and only then sends transactions, so a
   `require` inside the deploy script aborts before any transaction is sent (good) but **never
   observes on-chain state** (a real gap against §9's "read these back on-chain"). This script reads
   the address book and re-asserts every §9 item against the live chain.
2. **`SmokeTest.s.sol`** performs the live dust `forceExit` that §9 asks for — "this is Law 2 and it
   is worth one real transaction" — plus a small instant mint and an instant redeem.
3. **`check-sizes.sh`** runs `forge build --sizes`, fails non-zero on any negative margin, and is
   the documented gate before any deploy. §9 requires it because **`forge test` does not enforce
   EIP-170** and a green suite is not evidence.

### Tests

- [ ] `test_verifyScriptCatchesAWrongDependency` — point a vault at the wrong `CertOracle` and
      assert `VerifyTestnet` fails. This is the property `registerVault` does **not** check and
      that §9 exists to catch.
- [ ] `check-sizes.sh` exits non-zero when a contract is oversized (test with a deliberately fat
      throwaway contract, then remove it).

---

## Task 12: the two keepers

**Files:** new `script/keepers/BatchAdvancer.s.sol`, new `script/keepers/Attester.s.sol`,
new `docs/TESTNET-RUNBOOK.md`

Without these the testnet vault stops minting within ~15 minutes of deployment, because
`maxAttestationAgeSec = 300` starves `maxNotional18` to zero and a static aggregator goes stale.

1. **`BatchAdvancer`** — calls `LighterSim.settleBatch()` on an interval. The seventh worker the
   design spec never needed, because on mainnet Lighter advances its own batches.
2. **`Attester`** — calls `SolvencyRegistry.attest(asset, batchId, notional18, margin18,
   openInterest18)` and `CertOracle.setMarkPrice(px18)`. On testnet it reads the simulator's true
   position **directly**, since we control the venue, rather than reconstructing blob data.
   **Record prominently in the runbook that this makes testnet solvency stronger than mainnet's**,
   where a single attester relays figures that are independently verifiable but not verified
   on-chain. Do not let the testnet's convenience become an implied mainnet claim.
3. **`docs/TESTNET-RUNBOOK.md`** — how to get gas from the faucet, the env vars each script needs,
   the deploy command, the verify command, how to run both keepers, and a troubleshooting table
   whose first row is *"minting stopped after ~5 minutes → the keepers are not running; do not
   change immutable parameters to chase this."*

### Tests

- [ ] `test_attesterFiguresMatchSimulatorTruth` — a Foundry test that runs the attester's read logic
      against the simulator and asserts the attested notional and margin equal the simulator's
      actual position and margin.
- [ ] `test_vaultKeepsMintingWithKeepersRunning` — advance time past `maxAttestationAgeSec`, run the
      keeper logic, and assert minting is still permitted. Then advance without the keeper and
      assert capacity goes to zero. **Both halves matter** — the second is what the runbook's
      troubleshooting row describes.

---

## Task 13: close `_readFeed`'s second overflow, the sibling of Task 3's

**Files:** `src/CertOracle.sol`, `test/CertOracle.t.sol`, `docs/DEPLOYMENT-CHECKLIST.md`

Self-reported by Tasks 2+3 and then **confirmed by execution** in the review. This is the same class
as the external audit's Finding 1 ("make every quantity-times-price product a total function"),
which took two passes to close last time — so it is being scoped explicitly rather than left.

### The exposure

`src/CertOracle.sol:315`:

```solidity
px18 = d <= 18 ? uint256(answer) * (10 ** (18 - d)) : uint256(answer) / (10 ** (d - 18));
```

Task 3's new `d > 36` bound at `:314` guards the **exponent**. The **product** is unguarded.
`_tryFeed` guards both (`:376-379`, added in the CRITICAL B re-audit) — `_readFeed` never did.

**Reachable for `d` in 0..17**, where the overflow threshold is `(2**256 - 1) / 10**(18-d)`:
~1.1579e59 at `d = 0`, ~1.1579e67 at `d = 8` (the Chainlink standard, and what every live RH feed
reports), ~1.1579e76 at `d = 17` — all below `int256` max (~5.789e76), so every `d <= 17` has a
reachable range. **Unreachable for `d` in 18..36**: at `d == 18` the multiplier is 1, and above it
the branch divides. So Task 3's guard and this one are **disjoint, not overlapping**.

Confirmed by running it: a feed at `decimals() = 0, answer = 2e59` makes `px()` revert
`panic 0x11` — an anonymous panic on both mint paths — and `new CertOracle(...)` against
`MockAggregatorV3(0, 2e59)` **panics at deploy time** too, the same second-order consequence Task 3
fixed for the decimals case.

**Law 2 is unaffected, and this was verified rather than assumed:** in that exact state
`pxUnguarded()` returns the last-good snapshot, because `_tryFeed:378` returns its failure tuple and
`pxUnguarded:334-336` falls back. Every `src/` redemption reader uses `pxUnguarded()` only
(`src/CertVault.sol:989, 1052, 1265, 1408, 1502`); `px()` is reached at `:599` and `:654` alone,
both mint. So this is a **mint-path availability and error-quality defect**, exactly like Task 3's.

### The fix — verified to compile and to leave the suite unchanged

One error declaration plus one functional line, keeping the ternary intact:

```solidity
// beside CertOracle_FeedDecimalsOutOfRange:
error CertOracle_AnswerNotNormalisable();

// in _readFeed, immediately after the d > 36 bound:
if (d <= 18 && uint256(answer) > type(uint256).max / (10 ** (18 - d))) {
    revert CertOracle_AnswerNotNormalisable();
}
```

Three specification notes, all load-bearing:

1. **A new error is unavoidable — there is nothing to copy.** `_tryFeed` handles this condition by
   *returning its failure tuple*, not by reverting, so unlike Task 3's `d > 36` there is no existing
   name to reuse. **Do not reuse `CertOracle_FeedDecimalsOutOfRange`**: the conditions are disjoint
   (`d <= 18` with a huge answer, versus `d > 36`) and a caller must be able to tell "the feed's
   scale is absurd" from "the feed's print is unrepresentable."
2. **Guard the product, not a magnitude.** Use `type(uint256).max / scale`, mirroring `_tryFeed`'s
   comment at `:369-375`, so the bound tracks `d` rather than hard-coding the `d = 0` threshold.
3. **Two tests plus a boundary assertion, and one doc row.** A `px()` mirror of the existing
   `test_pxUnguardedSurvivesAnAnswerTooLargeToNormalise`, asserting the named error **and** that
   `pxUnguarded()` still returns last-good in the same state (Law 2 restated); a constructor case
   (`MockAggregatorV3(0, 2e59)` refused by name, matching `test_readFeedRevertsNamedOnAbsurdDecimals`);
   and one assertion that `d == 18` is safe, since that is the exact edge of the new condition.

### Also fix, because it is the same row's sibling

`docs/DEPLOYMENT-CHECKLIST.md` §2's **"Feed answer magnitude"** row still claims "Normalisation is
guarded, so an unrepresentable answer makes the feed unusable rather than panicking," with `—` in the
Violation column. That is true of `_tryFeed` and **false of `_readFeed`**. It is a pre-existing
inaccuracy, but it is the direct sibling of the row Task 3 just marked RESOLVED, and after this task
it can finally make the same claim honestly.

### Also add one sentence to the `singleSource` checklist row

With Task 2's loosening, `mintAllowed() == true` while `markPx18 == 0` is reachable for the first
time. Any monitor carrying the implicit invariant "minting open implies a mark is attested" is wrong
in single-source mode. The new checklist row covers the `basisBps()` side well; spell this pairing
out in one sentence.

---

## Deferred to a second wave, after the deployment is rolling

These raise simulator fidelity but are not required for a functional testnet, and each is
independently valuable. They are listed so they are not lost:

- **Insurance fund** replacing `_fundPending`'s silent mint. Today the venue can *always* pay, so no
  test in the suite can construct a venue shortfall — the one state solvency exists to detect.
- **Funding payments**, so the attester layer has something venue-side to read and `BufferBook`'s
  accrual has a real source.
- **Liquidation and partial fills** — the states that move the venue position without moving
  `venuePositionBase`, which `closeAll()`'s M-3 fix depends on and which nothing currently
  exercises.
- **Front-end wiring** (`TESTNET-PLAN.md` §5), which waits on repository access.
