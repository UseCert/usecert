# UseCert testnet runbook — Robinhood Chain testnet (chain 46630)

**Audience: an operator who did not build this.** No prior knowledge of the contracts is assumed.
Follow it top to bottom for a first deployment; jump to §8 if something has stopped working.

---

## 0. THE ONE THING TO READ BEFORE ANYTHING ELSE

**A deployed UseCert system stops accepting mints about five minutes after deployment unless three
keeper processes are running.** That is by design and it is not a bug in the deployment.

It looks exactly like a broken deployment. It is not. Three separate immutable parameters make the
system depend on an external heartbeat:

| Parameter | Value | What starves without a keeper | Which keeper feeds it |
| --- | --- | --- | --- |
| `maxAttestationAgeSec` | **300 s** | `CapacityOracle.maxNotional18` returns **0**, so every mint reverts `CertVault_AtCapacity` | `script/keepers/Attester.s.sol` |
| `stalenessSeconds` | **900 s** | `CertOracle.mintAllowed()` goes **false** (the price feed is dead) | `script/FeedKeeper.s.sol` |
| `basisBandBps` | **500 bps** | `CertOracle.mintAllowed()` goes **false** again, on a *fresh* feed, once the feed and the **venue mark** drift ~5% apart — a ~6% move is enough | `script/FeedKeeper.s.sol` (it advances the aggregator **and** `LighterSim.setMarkPrice`), then `script/keepers/Attester.s.sol` copies the mark |
| — (no timer) | — | nothing advances the venue simulator's batches, so **no order ever fills and no withdrawal ever arrives** | `script/keepers/BatchAdvancer.s.sol` |

**Every one of those parameters is immutable.** There is no setter, no owner and no upgrade path
(Design Law 6). If minting has stopped, **do not go looking for a parameter to change** — there
isn't one, and the attempt ends in an unnecessary redeployment into exactly the same state.

**Redemption is never affected.** `forceExit` prices off `pxUnguarded()` and reads no health state
(Design Law 2). A starved deployment stops taking money **in**; it never traps money already in.
That is a deliberate asymmetry, and it is why a stopped keeper is an availability problem and not a
solvency one.

---

## 1. TESTNET SOLVENCY IS STRONGER THAN MAINNET'S. DO NOT REPORT IT AS EVIDENCE ABOUT MAINNET.

This deserves its own section because it is the single most misreadable thing about this deployment.

`SolvencyRegistry.attest(asset, batchId, notional18, margin18, openInterest18)` is the call that
publishes what backs each certificate.

* **On mainnet** those figures come from reconstructing Lighter's account tree off posted blob data.
  They are **independently verifiable but not verified on-chain** — the registry takes the attester's
  word for them. The only bounds that survive a compromised or lying attester are
  `CapacityOracle.maxAbsoluteCap` (an immutable ceiling) and `maxAttestationAgeSec`.
* **On testnet** the venue is `src/sim/LighterSim.sol`, a simulator **we deploy and own**. So
  `script/keepers/Attester.s.sol` does not reconstruct anything: it reads the true position straight
  out of the simulator's storage. There is no window in which the attester can be wrong without the
  chain disagreeing.

That is the right call for a testnet, and it makes the attester trivial. **It also means testnet
solvency is strictly stronger than mainnet's.** A green testnet says nothing whatsoever about
whether a single mainnet attester relaying unverified figures is sound. Never quote testnet
attestation behaviour as evidence for the production design.

**One field is the exception, and it is stated plainly rather than buried.** `openInterest18` is the
*venue's* open interest — the depth of the book the vault would trade against — and the simulator
does not model an order book at all. So the attester **carries it forward from the address book's
`seedOpenInterest18`** ($900k for uTSLA, $50.0M for uSPY, measured from the venue API on 2026-09-09)
rather than reading it from the chain. It is the one attested number on testnet that is not venue
truth. `OPEN_INTEREST_18` overrides it if you want to watch the depth leg bind; halving it halves
`maxNotional18`'s depth leg.

A second, smaller honesty note: `singleSource` is `false`, which **declares** that the price feed and
the venue mark are independent sources. On testnet that independence is **organisational** (two keys),
not economic — we operate both. Testnet proves the basis band is *wired*, not that it *works*.

---

## 2. What you need before you start

1. **Foundry.** `forge --version`. The repo pins `solc 0.8.24` and `via_ir = false`; do not change
   either.
2. **Submodules.** `git submodule update --init --recursive`, or nothing compiles.
3. **`jq`.** Every `cast` block below reads addresses out of the address book with it. Without it,
   `jq: command not found` and every variable is empty, which presents as `cast` errors about
   `[TO]` having an "odd number of digits" rather than as a missing tool.
4. **Four private keys.** See §3 — they must be four *different* keys, two of them can never be
   changed after deployment, and the deploy script now **refuses to run** if any two coincide.
5. **Native gas on all four.** See §4.1.
6. **Nothing else.** In particular **you do not need to deploy or supply a collateral token.**
   `script/DeployTestnet.s.sol` deploys its own 6-decimal `src/sim/TestUSDG.sol` and its
   `src/sim/TestFaucet.sol` in phase 1, from `DEPLOYER_PK` (who becomes `TestUSDG.owner`), and mints
   both the deployer's seed collateral and the faucet's opening float itself. **It reads no
   `COLLATERAL` and no `TEST_FAUCET` env var** — earlier revisions of this document told you to
   export both, and the script ignored them silently. There is no way to point it at a collateral
   token it did not itself deploy.

   **Six decimals is still not a detail**, which is why the check survives: `CertVault` reads
   `collateral.decimals()` once, at construction, into an immutable, and an 18-decimal token makes
   every published figure wrong by 10^12 forever, with no setter to repair it. `TestUSDG.decimals()`
   is a `pure` literal `6`, so it cannot be deployed wrong; the script's `require` is defence in
   depth over its own deployment, **not** validation of a token you supplied.

   Testers get their collateral from the deployed faucet — **§4.2**, which is the only way to obtain
   any, because `TestUSDG.mint` is owner-gated to the deployer.

---

## 3. The keys, and why they must be separate

| Env var | Role | What it does | Can it be changed later? |
| --- | --- | --- | --- |
| `DEPLOYER_PK` | deployer / venue operator | deploys the simulator and the aggregators, is `LighterSim.owner`, runs the allowlist / mark / keeper-registration / bootstrap steps, and signs **both** of the feed keeper's pushes — the aggregator's `push` and the simulator's `setMarkPrice`, which it owns either side of | it is the simulator's **immutable** owner — no transfer path, redeploy instead |
| `GOV_PK` | governance | **constructs `SolvencyRegistry` and every `CertOracle` itself**, sets the absolute caps and the buffer ladder | **NO. Permanently bound.** |
| `ATTESTER_PK` | attester | the only key that may call `SolvencyRegistry.attest` and `CertOracle.setMarkPrice`; runs the attester keeper | only by a governance rotation that serves a **2-day** immutable notice period |
| `BATCH_KEEPER` (address) + `BATCH_KEEPER_PK` | batch keeper | the only non-owner key that may call `LighterSim.settleBatch`; runs the batch advancer | yes — `LighterSim.setKeeper`, from `DEPLOYER_PK` |

**Why separation is not optional.** `SolvencyRegistry` and `CertOracle` both execute
`governance = msg.sender` in their constructors, and that field is **immutable**. The deploy script
therefore constructs them under `GOV_PK` in `run()`'s own frame, as bare `CREATE`s from the
governance EOA. Collapse governance into the deployer and "governance is a multisig" stops being
true: the emergency `setAbsoluteCap(vault, 0)` lever ends up on the same key that ran the
deployment. Collapse governance into the attester and governance compromise immediately yields
attester powers. The script refuses to run if any two of the three senders are equal.

`BATCH_KEEPER` is a **fourth** key rather than the deployer's, because the batch keeper is a
long-running process on a box somewhere and the deployer key is the venue's owner. Keeping them
apart means a compromised keeper box cannot reconfigure the simulator.

**And the script now enforces that, rather than only asking for it.** It used to check `BATCH_KEEPER`
was merely non-zero, so `BATCH_KEEPER=$deployerAddr` passed every check and the separation this
section promises quietly did not exist. It is now checked pairwise against all three senders
(`SENDERS: batchKeeper == deployer` / `== governance` / `== attester`), exactly like the three
senders are checked against each other.

> Handle the keys yourself. Nothing in this repository writes, logs, or derives a key: every script
> reads its own one key from the environment, and only that one.

---

## 4. THE TWO FAUCETS

**There are two, they are unrelated, and confusing them wastes an afternoon.** They are documented
together here for exactly that reason.

| | §4.1 native gas | §4.2 test collateral |
| --- | --- | --- |
| What it hands out | the chain's native token, for gas | `TestUSDG` (tUSDG), the collateral vaults accept |
| Who runs it | Robinhood, at a public URL | **this deployment** — `src/sim/TestFaucet.sol`, deployed by `script/DeployTestnet.s.sol` |
| When | **before** you deploy (§5) | **after** you deploy — its address is an output |
| How | a web page | `cast send $FAUCET 'claim()'` |

A tester with gas but no tUSDG cannot mint anything, and a tester with tUSDG but no gas cannot send
a transaction. You need both.

### 4.1 Native gas

Native gas comes from **https://faucet.testnet.chain.robinhood.com/**.

Fund **all four** addresses:

```bash
cast wallet address --private-key "$DEPLOYER_PK"
cast wallet address --private-key "$GOV_PK"
cast wallet address --private-key "$ATTESTER_PK"
cast wallet address --private-key "$BATCH_KEEPER_PK"
```

The attester and the batch keeper spend continuously — the attester sends 2 transactions per mirror
per cycle at 60 s, the batch advancer 1+ per cycle at 30 s, and the feed keeper 2 per mirror per
cycle at 60 s (it advances the aggregator **and** the venue mark — §7.3). **Budget for them and
check their balances in the daily health check (§7.4).** A keeper that runs out of gas presents as a
dead keeper: minting stops, with §8's first row as the symptom.

Set the RPC once:

```bash
export ROBINHOOD_TESTNET_RPC=https://rpc.testnet.chain.robinhood.com
cast chain-id --rpc-url robinhood_testnet   # must print 46630
```

### 4.2 Test collateral — `TestFaucet`, and it is the ONLY source

**Read this before telling anyone the testnet is ready.** `src/sim/TestUSDG.sol`'s `mint` is
owner-gated to `DEPLOYER_PK`, so **`TestFaucet.claim()` is the only way any tester can obtain
collateral.** There is no public mint, and no other path. A deployment whose faucet is empty is a
deployment where nobody but the deployer can mint a certificate — and nothing on-chain looks wrong.

It is deployed by the deploy script (§5), not by you. Come back here once §5 has run.

**Its address is `.shared.testFaucet` in the address book:**

```bash
BOOK=deployments/46630.json
FAUCET=$(jq -r '.shared.testFaucet' $BOOK)
TOKEN=$(jq -r  '.shared.collateral' $BOOK)
```

**Claim, from any address that has gas:**

```bash
cast send $FAUCET 'claim()' --rpc-url robinhood_testnet --private-key "$YOUR_PK"

# what you got (6 decimals)
cast call $TOKEN 'balanceOf(address)(uint256)' $(cast wallet address --private-key "$YOUR_PK") \
  --rpc-url robinhood_testnet
```

`claim()` is **permissionless** — a faucet with an allowlist is a distribution list — and pays
`msg.sender`, never a `to` argument, because a recipient parameter would make the rate limit
bypassable by one address naming a different recipient each call.

**The numbers, as deployed** (`script/DeployTestnet.s.sol`'s `FAUCET_*` constants; also recorded in
the book as `.shared.faucetDripAmount`, `.shared.faucetIntervalSeconds` and
`.shared.faucetOpeningFloat`, and readable on chain):

| | Value | On-chain read |
| --- | --- | --- |
| Drip per claim | **10 000 tUSDG** (`10_000e6`) | `cast call $FAUCET 'dripAmount()(uint256)'` |
| Cooldown per address | **1 day** (`86400 s`) | `cast call $FAUCET 'interval()(uint256)'` |
| Opening float | **1 000 000 tUSDG** = exactly **100 drips** | `cast call $FAUCET 'dripsRemaining()(uint256)'` |

**The two errors you will see:**

* `TestFaucet_TooSoon(uint256 availableAt)` — this address already claimed inside the cooldown. The
  error **carries the timestamp** at which it may claim again, so nothing has to recompute it:
  `cast call $FAUCET 'nextAvailableAt(address)(uint256)' $ADDR`. A first-ever claim is always
  immediate (`lastClaimAt == 0`). The fix is to wait, or to use another address.
* `TestFaucet_Empty(uint256 held, uint256 requested)` — the float is exhausted. Named rather than
  left as a failed transfer, because "the faucet is empty" and "the token is broken" are different
  operator actions. See the top-up below.

**THE FLOAT IS FINITE AND THERE IS NO PRIVILEGED REFILL PATH.** `TestFaucet` has **no owner, no
`fund()`, no `rescue`, no `sweep` and no `setDripAmount`** — deliberately, so that its balance plus
its `Dripped` event stream is a closed account, and so that it never looks like a second venue
balance sheet to anything reading the chain. Consequences:

* **Topping it up is a plain ERC-20 `transfer` in**, sent by whoever holds `TestUSDG.owner` (the
  deployer, who can `mint` first). There is no call to make on the faucet and no accounting to keep
  in step, so a top-up cannot be done wrongly:

  ```bash
  # from DEPLOYER_PK, which is TestUSDG.owner
  cast send $TOKEN 'mint(address,uint256)' $FAUCET 1000000000000 \
    --rpc-url robinhood_testnet --private-key "$DEPLOYER_PK"   # 1 000 000 tUSDG = 100 more drips
  ```
* **Changing the drip or the cooldown means deploying another faucet** and topping that one up
  instead. Both are immutable, set at construction. On a testnet this costs nothing.
* **An empty faucet cannot be un-emptied by anyone but the token owner.** Watch
  `dripsRemaining()` — it is in §7.4's health check for that reason.

---

## 5. Deploy

```bash
export DEPLOYER_PK=0x...
export GOV_PK=0x...
export ATTESTER_PK=0x...
export BATCH_KEEPER=0x...          # the ADDRESS the batch keeper will sign with
export COMMIT=$(git rev-parse HEAD)

forge script script/DeployTestnet.s.sol \
  --rpc-url robinhood_testnet --broadcast --slow
```

* `--slow` is required: the run spans three senders and later transactions depend on earlier ones
  having landed.
* `COMMIT` is recorded in the address book so the EIP-170 size claim stays checkable later. It is
  taken from an env var rather than shelled out, because `ffi` is deliberately not enabled in a run
  that handles three private keys.
* **`BATCH_KEEPER` must be a fourth, distinct address.** The script refuses to run if it is zero
  (`DeployTestnet_MissingBatchKeeper`) or if it equals the deployer, governance or the attester
  (`SENDERS: batchKeeper == …`) — see §3 for why. It is the only one of the four that is rotatable
  afterwards, via `LighterSim.setKeeper` from `DEPLOYER_PK`.
* **No collateral or faucet address is supplied.** The run deploys its own 6-decimal `TestUSDG` and
  its `TestFaucet` and mints both floats — see §2 item 6 and §4.2. Setting `COLLATERAL` or
  `TEST_FAUCET` does nothing at all.

The run writes **`deployments/46630.json`** — the address book.

> **NEVER HAND-EDIT THE ADDRESS BOOK.** Every deployment produces a new vault **and a new
> certificate token**. An edited map silently repoints a UI at a new token while real balances sit in
> the old one — holders' certificates simply stop being visible, with nothing on-chain wrong. If it
> is out of date, re-run the deployment. Both keepers read this file for every address they use, so
> a wrong entry is a wrong keeper.

**What the deploy script's own `require`s do and do not prove.** `forge script --broadcast` simulates
the entire run first and only then sends the transactions it collected, so every `require` in that
script asserts the *local simulation*. They are an abort gate — a misconfiguration stops the run
before a single transaction is sent — not an on-chain check. §6 is the on-chain check.

---

## 6. Verify

```bash
forge script script/VerifyTestnet.s.sol --rpc-url robinhood_testnet
```

It reads `deployments/46630.json` and re-asserts `docs/DEPLOYMENT-CHECKLIST.md` §9 against the live
chain. Read-only; no `--broadcast`. **Run it before starting the keepers and after every
redeployment.**

Also run the size gate at least once per deployed commit — `forge test` does **not** enforce
EIP-170, so a green suite is not evidence:

```bash
forge build --sizes     # every deployable contract must show a positive runtime margin
```

If `script/VerifyTestnet.s.sol` is not in the tree yet, the equivalent minimum by hand is the
health check in §7 — but the verify script is the discharge of §9 and the health check is not.

---

## 7. Start the keepers

All three are **Foundry scripts driven by an external loop**. A Foundry script runs once and exits;
it cannot wait on wall-clock time. There is no daemon to install, and none of them loops internally
on time. Use cron, a systemd timer, or a shell `while` — whichever you already operate.

### 7.1 The attester — interval **60 s**

```bash
export ATTESTER_PK=0x...
while true; do
  forge script script/keepers/Attester.s.sol \
    --rpc-url robinhood_testnet --broadcast --slow
  sleep 60
done
```

Reads the vault's own position and margin out of the simulator, then per mirror sends
`SolvencyRegistry.attest(...)` and `CertOracle.setMarkPrice(...)`.

**Why 60 s against a 300 s deadline, and do not raise it.** The 5x margin *is* the design. At 240 s a
single failed cycle — one RPC timeout, one gas exhaustion, one nonce collision — starves minting
before the next cycle can land. At 60 s it takes four consecutive failures. Note also that
`CertOracle.markPx18` has **no timestamp and no staleness check anywhere**: its liveness is an
operational assumption on this keeper's cadence, not a contract guarantee, and a mark left behind a
moving feed drifts out of `basisBandBps` and closes the mint gate a third way.

`batchId` is read from the chain each cycle (`latest(vault).batchId + 1`), never from a counter in
the process, so a restarted keeper resumes correctly and a second keeper started by mistake cannot
write a stale batch — it will simply lose the race and revert `SolvencyRegistry_StaleBatch`.

### 7.2 The batch advancer — interval **30 s**

```bash
export BATCH_KEEPER_PK=0x...      # MUST derive .shared.batchKeeper from the address book
while true; do
  forge script script/keepers/BatchAdvancer.s.sol \
    --rpc-url robinhood_testnet --broadcast --slow
  sleep 30
done
```

Calls `LighterSim.settleBatch()`. On mainnet Lighter advances its own batches; here nothing does, so
without this process **no order ever fills, no mint's hedge is ever opened, and no queued withdrawal
ever arrives.**

**30 s is a user-experience number, not a protocol deadline.** An unsettled order is not a
starvation risk the way a stale attestation is — but it is the latency a tester feels between "I
minted" and "the hedge exists", and between "I asked to exit" and "the collateral came back". One
invocation drains up to 8 batches (the simulator settles at most 64 orders per call, with a 512-order
queue), so a slower interval degrades gracefully rather than falling permanently behind. If you see
`WARNING - queue not drained within MAX_SETTLE_ROUNDS`, shorten the interval.

**It must sign as the registered keeper.** `settleBatch` is gated to the simulator's owner or its
owner-settable keeper, because a permissionless settler would pick the block — and therefore the mark
— at which someone else's queued order fills. The script refuses to broadcast unless
`vm.addr(BATCH_KEEPER_PK)` matches both the address book **and** `LighterSim.keeper()` on chain, and
says which side disagrees. See §8's keeper-mismatch row for why that check exists.

### 7.3 The feed keeper — interval **at most 300 s; 60 s recommended**

```bash
export ROBINHOOD_TESTNET_RPC=https://rpc.testnet.chain.robinhood.com
export DEPLOYER_PK=0x...          # owns BOTH the aggregators and the simulator
TSLA_AGG=$(jq -r '.vaults[0].replayAggregator' deployments/46630.json)
SPY_AGG=$(jq -r  '.vaults[1].replayAggregator' deployments/46630.json)

while true; do
  REPLAY_AGGREGATOR=$TSLA_AGG FEED_PRICE=36662040000 \
    forge script script/FeedKeeper.s.sol --rpc-url robinhood_testnet --broadcast --slow
  REPLAY_AGGREGATOR=$SPY_AGG FEED_PRICE=65000000000 \
    forge script script/FeedKeeper.s.sol --rpc-url robinhood_testnet --broadcast --slow
  sleep 60
done
```

#### It pushes TWO prices per invocation, and that is load-bearing

**`script/FeedKeeper.s.sol` advances the aggregator AND calls
`LighterSim.setMarkPrice(marketIndex, px18)` with the same price.** Both are `onlyOwner` on
contracts `DEPLOYER_PK` owns, so this is one extra transaction, not a second key.

**Do not "simplify" it back to one call.** Before it advanced the venue mark, nothing on the box ever
moved `LighterSim.markPrice` again after deployment — it is `onlyOwner` and was set exactly once,
from `seedPx18`. `CertOracle.markPx18` is written only by the attester, and the attester's only
source is `LighterSim.markPrice`, so the two legs of the basis band were a moving feed against a
frozen mark. **One feed push of +6% closed the mint gate permanently.** Measured:

```
BEFORE  mintAllowed: true   basis: (true, 0)
push FEED_PRICE=38862040000  (+6.0%)
AFTER   px 388.62e18   markPx18 366.62e18   basis (true, 566)   mintAllowed: false
```

Restarting the attester does **not** fix that — it rewrites the same frozen mark. Nor is it the
deviation leg: walking `lastGoodPx18` forward with permissionless `pokeLastGood()` brought deviation
to 95 bps and `mintAllowed()` was still `false` with `basis = 566` the sole cause. And the mint gate
is the smaller half: `settleBatch` **fills queued orders at `markPrice`**, so a frozen mark means
every hedge forever fills at the deployment-day price while `CertOracle.px()` follows the feed, and
`solvency().deltaBps` drifts without limit.

#### Invocation

One invocation drives **one mirror**, so it needs **one per mirror** — the mirrors have genuinely
different prices and a single `FEED_PRICE` cannot serve both.

* `REPLAY_AGGREGATOR` now **selects** the mirror rather than being the only address the script
  knows. It is matched against `.vaults[i].replayAggregator` in the address book, and the simulator
  address and market index come from that same record, so the selector cannot disagree with the
  market it drives. An aggregator that is not in the book is a named abort, not a fallback to
  mirror 0.
* `FEED_PRICE` is an `int256` in the aggregator's own decimals (**8**, matching the real feeds). It
  is normalised to 1e18 for the venue mark using the aggregator's own `decimals()`, read on chain.
  A zero or negative `FEED_PRICE` is refused **before either call** — a zero venue mark kills the
  simulator's whole mark-to-market layer.
* `REPLAY_MODE=true` with `REPLAY_INDEX` steps a fixed in-script price path instead, for a
  deterministic demo with no live price source. Both legs still move together.
* `DEPLOYER_PK` is read from the environment now, like the other two keepers' keys, rather than
  passed as `--private-key`. The script preflights `ReplayAggregator.owner()` **and**
  `LighterSim.owner()` against it and names which one disagrees.

It never invents a price: there is no HTTP call, because a Foundry script has no such capability
during a broadcast run. Feed it a number you already decided on — a real mainnet Chainlink print for
TSLA / SPY is the intended source.

**The push interval must sit well inside `stalenessSeconds` (900 s), so push at least every ~300 s.**
60 s is recommended for the same 5x-margin reason as the attester.

**A caveat this keeper cannot remove.** Pushing a price more than `deviationBps` (500 bps) away from
`lastGoodPx18` in one step still closes the gate on the **deviation** leg, which is a different
guard and a deliberate one. Advancing in steps inside the band, or calling the permissionless
`pokeLastGood()` (two-phase, `pokeConfirmationSeconds` = 300 s), is how a large real move is
tracked. §7.4 tells the two legs apart.

### 7.4 Health check — what a healthy deployment looks like

Run this against any mirror. All four reads must hold **continuously**, not just after a
redeployment:

```bash
BOOK=deployments/46630.json
VAULT=$(jq -r '.vaults[0].vault'      $BOOK)
ORACLE=$(jq -r '.vaults[0].certOracle' $BOOK)
REG=$(jq -r '.shared.solvencyRegistry' $BOOK)
CAP=$(jq -r '.shared.capacityOracle'   $BOOK)
SIM=$(jq -r '.shared.lighterSim'       $BOOK)
FAUCET=$(jq -r '.shared.testFaucet'    $BOOK)
BUF=$(cast call $VAULT 'bufferCapacity18()(uint256)' --rpc-url robinhood_testnet)

cast call $REG    'ageSec(address)(uint256)'                 $VAULT      --rpc-url robinhood_testnet
cast call $CAP    'maxNotional18(address,uint256)(uint256)'  $VAULT $BUF --rpc-url robinhood_testnet
cast call $ORACLE 'mintAllowed()(bool)'                      --rpc-url robinhood_testnet
cast call $ORACLE 'basisBpsChecked()(bool,uint256)'          --rpc-url robinhood_testnet
cast call $FAUCET 'dripsRemaining()(uint256)'                --rpc-url robinhood_testnet

# the two legs of the basis, side by side - if basisBpsChecked is above 500, this is why.
# pxUnguarded, not px(): px() REVERTS CertOracle_StalePrice on exactly the feed you are diagnosing.
cast call $ORACLE 'pxUnguarded()(uint256,uint256)'           --rpc-url robinhood_testnet
cast call $ORACLE 'markPx18()(uint256)'                      --rpc-url robinhood_testnet
cast call $SIM    'markPrice(uint16)(uint256)'               16 --rpc-url robinhood_testnet
```

| Read | Healthy | Starved |
| --- | --- | --- |
| `registry.ageSec(vault)` | **< 300**, and typically < 120 | ≥ 300 and climbing |
| `capacity.maxNotional18(vault, buffer)` | **non-zero** (90 000e18 for uTSLA, 5 000 000e18 for uSPY at the shipped caps) | **0** |
| `oracle.mintAllowed()` | **true** | false |
| `oracle.basisBpsChecked()` | `(true, ≤ 500)` | `(false, …)`, or bps above 500 |
| `faucet.dripsRemaining()` | **non-zero** | **0** — nobody but the deployer can mint (§4.2) |

**An empty faucet is a silent "nobody can mint".** Every protocol read above can be perfectly green
while no tester can obtain a single tUSDG, because `TestUSDG.mint` is owner-gated and `claim()` is
the only other way in. It has no privileged refill path, so the fix is a plain transfer in — §4.2.

**The pair of reads that tells the failures apart** — this is the diagnostic, and it matters because
all of them present as "minting stopped":

* `maxNotional18 == 0` **and** `mintAllowed() == true` → the **attester** is dead. Capacity starved
  at 300 s; the feed is still inside its 900 s window.
* `maxNotional18 != 0` **and** `mintAllowed() == false` → **two different causes read
  BYTE-IDENTICALLY here, and `basisBpsChecked()` is what separates them.** Take it before you touch
  anything:
  * `basisBpsChecked()` returns `(true, ≤ 500)` → the **feed keeper is dead**. The feed went stale
    at 900 s (`stalenessSeconds`); the attestation is still fresh. Restart §7.3.
  * `basisBpsChecked()` returns `(true, > 500)` → the feed keeper is **alive but only advancing one
    leg**, or the two prices genuinely disagree. The feed is fresh and the *basis band* is what is
    shut. **This is not a stale-feed problem and restarting the attester will not fix it** — see
    §8's basis row. Compare `oracle.pxUnguarded()`, `oracle.markPx18()` and
    `sim.markPrice(market)`: the `cast` block above prints all three, and which pair disagrees tells
    you whether the feed keeper's mark leg or the attester's copy is the one that stopped.
  * `basisBpsChecked()` returns `(false, 0)` → the feed did not answer at all, or `markPx18` is
    zero, or `singleSource` is `true` (it is `false` on this deployment, so `(false, …)` here means
    the feed leg failed).
* both bad → every keeper is down, or the whole box is.

Also confirm the batch advancer is alive: `cast call $SIM 'queueLength()(uint256)'` should be 0 or
very small at rest. A queue length that only ever grows means the batch advancer is dead or its key
is mismatched.

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| **Minting stopped a few minutes after deploy. Everything reads as deployed and `CertVault_AtCapacity` (`0x26fa45d8`) on every mint.** | **The keepers are not running.** `maxAttestationAgeSec` is 300 s and `maxNotional18` returns 0 past it. | **Start the keepers (§7). DO NOT try to change immutable parameters to chase this** — `maxAttestationAgeSec`, `stalenessSeconds`, `deviationBps` and the rest have no setters, and an operator who concludes the deployment is broken and redeploys lands in exactly the same state. Verified live: with the attester stopped, capacity went 90 000e18 → 0 at `ageSec = 413`; one attester cycle restored it to 90 000e18 with nothing else touched. |
| Minting stopped, `maxNotional18 != 0` but `mintAllowed() == false`, **and `basisBpsChecked()` reads `(true, ≤ 500)`.** | The **feed keeper** is dead: the aggregator passed `stalenessSeconds` (900 s). Same visible symptom as the attester row, different keeper. | Restart §7.3. **Take `basisBpsChecked()` first** — with a basis above 500 this is the basis-band row further down instead, and the remedies are different. §7.4 has the three-way differential. |
| **Every `settleBatch` reverts `LighterSim_OnlyOwnerOrKeeper` (`0x…`).** | **The keeper address in the address book is not the one the keeper process is signing with.** Nothing on-chain tells you they disagree — the symptom is identical to a dead keeper. | `BatchAdvancer` now refuses to broadcast in this state and names which side is wrong. If it is the process: fix `BATCH_KEEPER_PK`. If `LighterSim.keeper()` on chain disagrees with the book: only the simulator's **owner** (`DEPLOYER_PK`) can call `setKeeper`, so this is a deployer action, not a keeper restart. |
| `bootstrap()` reverts `LighterSim_DepositorNotAllowed(vault)`. | **The vault is not on the simulator's registration allowlist.** Owner-gated state with no counterpart on the real venue (which registers anyone), so no earlier document describes it and the error explains nothing on its own. | `LighterSim.setDepositorAllowed(vault, true)` from `DEPLOYER_PK`, **before** `bootstrap()`. The deploy script does this; you only hit it if you are bootstrapping a vault by hand. |
| Every mint reverts `AccountIsNotRegistered`, as one atomic transaction. | The vault's registering deposit has been submitted but **not settled**. Registration is asynchronous on the simulator. | Run the batch advancer once (§7.2). `vault.lighterAccountIndex()` must be non-zero afterwards. |
| `CertVault_AtCapacity` on a **fresh** deployment that otherwise reads perfectly — registered, bootstrapped, attested, `mintAllowed() == true`. | `CapacityOracle.absoluteCap18(vault)` is **0**, and `maxNotional18`'s `min()` reads 0 as "no capacity". Setting it is governance-gated and deliberately not part of the permissionless bootstrap. | `CapacityOracle.setAbsoluteCap(vault, cap)` from `GOV_PK`. The deploy script does this and reads it back; if you hit it, the deployment did not complete. |
| Attester reverts `SolvencyRegistry_OnlyAttester` or `CertOracle_OnlyAttester`. | Wrong key, or governance rotated the attester. | The script preflights this and names it. Check `SolvencyRegistry.attester()` and each `CertOracle.attester()` on chain. A rotation serves a 2-day immutable notice; there is no faster path. |
| Attester reverts `SolvencyRegistry_StaleBatch`. | Two attester processes are running against the same registry, or the book points at the wrong vault. | Run exactly one. `batchId` is derived from the chain, so a single keeper can never do this to itself. |
| Attester reverts `VenueTruth_VaultNotRegistered(vault)`. | The vault in the book holds no account on the simulator — usually a **stale or hand-edited address book**, occasionally a deployment that never bootstrapped. | Re-run §6's verify. Do not "fix" this by editing the book. The refusal is deliberate: attesting honest-looking zeros against a wrong vault key is worse than stopping. |
| Attester reverts `VenueTruth_MarkPriceUnset(marketIndex)`. | The venue mark was never set for that market. `settleBatch` refuses this state too. | `LighterSim.setMarkPrice(marketIndex, px18)` from `DEPLOYER_PK`. At a zero mark the entire mark-to-market layer is dead — notional is `|position| × 0`, the margin gate passes vacuously at any size, and PnL is permanently zero — so the refusal is protecting you. |
| A keeper reverts `ADDRESS BOOK: chainId != the chain this RPC is on`. | The book is from another chain, or the RPC points somewhere else. Every address in it is dead code here. | Point `--rpc-url` at 46630, or re-run the deployment. |
| A keeper reverts `ADDRESS BOOK: no vaults` or `… columns disagree …`. | The book is truncated or was hand-edited. | Re-run the deployment. |
| `BatchAdvancer` logs `WARNING - queue not drained within MAX_SETTLE_ROUNDS`. | The queue is growing faster than the keeper drains it, or one order is stuck. | Shorten the interval, or raise `MAX_SETTLE_ROUNDS`. If it persists, inspect `queueLength()` / `settleCursor()`; the simulator's owner has scoped cancel and purge hatches. |
| A keeper's transactions stop landing with no revert. | Out of native gas. | §4.1. Add balance monitoring on the attester, batch-keeper and deployer addresses. |
| A tester cannot mint and has **zero tUSDG**, while every read in §7.4 is green. | They never claimed from the collateral faucet, or it is empty. `TestUSDG.mint` is owner-gated to the deployer, so **`TestFaucet.claim()` is the only way in** — and this is invisible in every protocol read. | §4.2. Check `faucet.dripsRemaining()`. Note this is a *different* faucet from the native-gas one in §4.1. |
| `claim()` reverts `TestFaucet_TooSoon(availableAt)`. | That address already claimed inside the 1-day cooldown. Rate limiting is per `msg.sender` and cannot be bypassed with a recipient argument. | Wait until `availableAt` (the error carries it; `nextAvailableAt(addr)` also returns it), or use another address. §4.2. |
| `claim()` reverts `TestFaucet_Empty(held, requested)`. | The float is exhausted — 100 drips shipped, and there is **no privileged refill path**: no owner, no `fund()`, no sweep. | Transfer tUSDG in as a plain ERC-20 `transfer` from `TestUSDG.owner` (the deployer, who can `mint` first). Nothing needs calling on the faucet. §4.2. |
| `claim()` succeeds but the tokens are useless for minting. | The faucet is pointed at a token no vault here accepts — a faucet from a *previous* deployment. | Re-read `.shared.testFaucet` from the current `deployments/46630.json`; the deploy script's §9 read-back asserts `faucet.token() == collateral` for the run that wrote the book. |
| **Minting stopped, `maxNotional18 != 0`, `mintAllowed() == false`, and `basisBpsChecked()` reads `(true, > 500)`.** | **The venue mark has stopped tracking the feed**, so the two legs of `basisBandBps` have drifted apart. **NOT a stale feed** — this reads byte-identically to the dead-feed row above and `basisBpsChecked()` is the only thing that separates them (§7.4). The mark's chain of custody is: `script/FeedKeeper.s.sol` → `LighterSim.setMarkPrice` → the attester copies it → `CertOracle.markPx18`. A feed keeper advancing only the aggregator leaves `LighterSim.markPrice` frozen at `seedPx18`, and then **`CertOracle.markPx18` is frozen too, no matter how often the attester runs.** | **Do NOT restart the attester — it is provably a no-op**, measured: it rewrites the same frozen `LighterSim.markPrice`. Nor is it the deviation leg (walking `lastGoodPx18` forward with `pokeLastGood()` to 95 bps left `mintAllowed()` false with `basis = 566` the sole cause). **Fix: (1)** confirm the feed keeper is the current `script/FeedKeeper.s.sol`, which pushes the aggregator **and** `LighterSim.setMarkPrice` in the same invocation (§7.3) — an older single-leg version, or a hand-rolled `cast send … push`, is the usual cause; **(2)** re-align the mark now with `cast send $SIM 'setMarkPrice(uint16,uint256)' $MARKET $PX18` from `DEPLOYER_PK` (the mark is 1e18-scaled, the feed 8-decimal), then let the attester's next cycle copy it; **(3)** if it recurs while the keeper is running, the price you are pushing and the mark genuinely disagree — align the sources. Note the mint gate is the *smaller* half: `settleBatch` fills at `markPrice`, so a frozen mark also makes every hedge fill at the deployment-day price while `px()` moves, and `solvency().deltaBps` drifts without limit. |
| Minting stopped, `basisBpsChecked()` reads `(true, ≤ 500)`, but `mintAllowed()` is still false and the last feed push was a large jump. | The **deviation** leg, not the basis leg: the pushed price is more than `deviationBps` (500 bps) from `lastGoodPx18`. A deliberate guard, not a keeper fault. | Call the permissionless `pokeLastGood()` — two-phase, `pokeConfirmationSeconds` = 300 s — or advance the feed in steps inside the band. §7.3's caveat. |
| Redemption fails. | Should be impossible. | **This is a Design Law 2 breach and is a serious finding, not an ops issue.** `forceExit` must never revert for a holder with a balance, at any price, in any oracle or buffer state. Capture the transaction and escalate; do not work around it. |

---

## 9. Env var reference

| Script | Required | Optional |
| --- | --- | --- |
| `script/DeployTestnet.s.sol` | `DEPLOYER_PK`, `GOV_PK`, `ATTESTER_PK`, `BATCH_KEEPER` | `COMMIT` |
| `script/keepers/Attester.s.sol` | `ATTESTER_PK` | `ADDRESS_BOOK`, `OPEN_INTEREST_18` |
| `script/keepers/BatchAdvancer.s.sol` | `BATCH_KEEPER_PK` | `ADDRESS_BOOK`, `MAX_SETTLE_ROUNDS` (default 8) |
| `script/FeedKeeper.s.sol` | `DEPLOYER_PK`, `REPLAY_AGGREGATOR`, and `FEED_PRICE` unless `REPLAY_MODE=true` | `ADDRESS_BOOK`, `REPLAY_MODE`, `REPLAY_INDEX` |
| all | `ROBINHOOD_TESTNET_RPC` (used by the `robinhood_testnet` alias in `foundry.toml`) | |

> **`COLLATERAL` and `TEST_FAUCET` are NOT read by anything.** Earlier revisions of this document
> listed `COLLATERAL` as required and `TEST_FAUCET` as optional, and told you to export both in §5.
> The deploy script reads neither — it deploys its own 6-decimal `TestUSDG` and its `TestFaucet` —
> and **nothing aborts if you set them**, so a run looks clean while `.shared.collateral` points at a
> token you have never seen. Do not set them; they mean nothing.

`ADDRESS_BOOK` defaults to `deployments/<chainId>.json`. Override it only to run a keeper from
outside the repository root — never to point a keeper at a book for a different deployment.

Neither `Attester` nor `BatchAdvancer` takes any **address** as an argument or an env var. Every
address comes from the address book, on purpose: a hand-typed vault address is one copy-paste away
from attesting a previous deployment's vault, which produces a stream of perfectly valid attestations
against an asset key nothing is minting while the live vault starves.

`FeedKeeper` takes exactly one address, `REPLAY_AGGREGATOR`, and it is a **mirror selector rather
than an injected address**: it must match a `.vaults[i].replayAggregator` in the book or the script
aborts by name, and the simulator address and market index it needs for the mark leg are read from
that same record. So the one address it accepts cannot disagree with the market it drives.

---

## 10. Parameters that are testnet-only and must not be carried to mainnet

| Parameter | Testnet | Mainnet | Why they differ |
| --- | --- | --- | --- |
| `stalenessSeconds` | **900** | **93 600** (26 h) | Mainnet sits just above the real Chainlink feeds' 24 h heartbeat so the 24/5 market gap, the weekend and a corporate-action pause do not read as a dead feed. 900 on mainnet would pause minting every weekend; 93 600 on testnet would let a dead keeper certify a stale price for a day. |
| `pokeConfirmationSeconds` | **300** | ~1 h | Short on testnet so a tester can watch the two-phase poke complete inside a session. |
| `instantCap18` | **1 000e18** | capacity-derived | Deliberately low so testers cross into the queued mint/redeem path on purpose. |
| `singleSource` | **false** | per market | Must be `true` for any market with no Chainlink feed — 28 of the venue's 57 perp markets. Set `false` against a venue-derived feed and the deployment fails **silently**: `basisBpsChecked()` returns `(true, 0)`, a healthy basis asserted and never computed. |
| the whole attester design | reads the simulator directly | reconstructs blob data | §1. Do not report the testnet arrangement as evidence about mainnet. |
