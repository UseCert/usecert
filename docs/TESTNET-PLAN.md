# UseCert — testnet bring-up plan

**Date:** 2026-09-09 · **Target:** Robinhood Chain testnet, chain ID **46630** · **Status:** plan of
record, decisions settled

Companion: [DEPLOYMENT-CHECKLIST.md](DEPLOYMENT-CHECKLIST.md) (normative for deployment),
[WHITEPAPER.md](WHITEPAPER.md), [HOW-IT-WORKS.md](HOW-IT-WORKS.md).

---

## 0. What reconnaissance established

All verified 2026-09-09 by live command, not inference.

| Fact | Evidence |
| --- | --- |
| Testnet is live at chain ID **46630** | `cast chain-id --rpc-url https://rpc.testnet.chain.robinhood.com` → `46630`; block 116,037,220. It does **not** rate-limit, unlike mainnet's 429-on-second-call |
| **Lighter is not on testnet** | `cast code` → `0x` for both the mainnet `ZkLighter` `0x94bA…fFF9d` **and** the testnet-API-advertised `0x23fF…55e9`. `api.rh-testnet.lighter.xyz/info` → `Bad Gateway` |
| Lighter's own testnet is unusable as a substitute | Live, but 3 markets (ETH/BTC/SOL, **no equities**) and `default_initial_margin_fraction` 500–666 (5–6.7%) against RH mainnet's uniform **5000 (50%)**. A 10× more forgiving margin requirement would certify a design mainnet rejects |
| **Chainlink is on RH mainnet** — 57 live feeds | Chainlink's own registry, `feeds-robinhood-mainnet.json`, 57 entries. TSLA `0x4A1166…7C38` → `"RHTSLA / USD"`, 8 decimals, $366.6204 |
| **Chainlink is not on testnet 46630** | All six probed proxies return `0x`; four registry filename variants 404 |
| SpaceX **has** a feed | `0xB26581…8Bffb` → `"Robinhood SPCX / USD"`, $153.1263, 12.2 bps from the venue mark. This corrects an earlier assumption that pre-IPO names could not have feeds |
| 28 of 57 venue markets have **no** feed | 20.5% of open interest, 26.9% of volume. Largest unfeeded is **XAU (gold) $12.53M** — bigger than ANTHROPIC |
| The venue is far larger than assumed | 57 active perp markets, **$170M open interest, $373M daily volume** |
| Capacity ranking contradicts the C1 asset choice | At 10% depth: SPY **$5.00M**, QQQ $3.05M, BTC $2.10M, ETH $1.70M, XAU $1.25M, ANTHROPIC $486k, NVDA $311k … **TSLA $90k (18th)**. TSLA's OI also fell 24% in two days |

Two facts about the equity feeds drive §1:

- They are **24/5 with no heartbeat during off-hours**, heartbeat 86,400 s. Measured ages mid-week:
  QQQ **23.3 h**, NVDA 13.3 h, TSLA 7.6 h. QQQ was 0.7 h from breaching a 24 h bound *on a Tuesday*.
- Robinhood **pauses the oracle during corporate actions**, freezing it at the pre-pause price.
  `oraclePaused()` and `uiMultiplier()` both **revert** on the aggregator proxy — they live on the
  stock-token contract, which `CertOracle` has no address for. A pause is invisible except as
  growing age.

Measured feed-vs-mark basis, the empirical floor for `basisBandBps`: **11.3–49.3 bps** (SGOV 49.3,
ETH 38.3, TSLA 30.8, QQQ 11.3). The fixture's 100 bps leaves SGOV at half the band.

---

## 1. Decision: `stalenessSeconds` — delegated, and here is the call

### The reframe

The 24/5-feed-versus-24/7-venue conflict is **not a bug to engineer around.** When the underlying
market is closed, nobody knows what a share is worth. The perp keeps trading and the basis drifts.
Minting a certificate at a Friday-close oracle price into a book that has moved all weekend is
precisely the mint-to-fill risk the buffer absorbs — except taken deliberately, in size, with no
price discovery behind it.

**So minting pausing off-hours is the correct behaviour, not a degradation.** That resolves the
conflict the reconnaissance called unresolvable: one side of it was never a requirement.

The asymmetry confirms it. `stalenessSeconds` gates **minting only** — Law 2 means no redemption
path reads it, at any value:

| Setting | Failure mode | Cost |
| --- | --- | --- |
| **Tight** (~26 h) | Minting pauses off-hours and across weekends | A convenience loss. Redemption unaffected |
| **Loose** (~72–96 h) | Minting continues against a stale or deliberately frozen price | A **Law 1** breach. Over-mints against a price nobody is standing behind |

### The call

- **Mainnet shape: `stalenessSeconds = 93_600` (26 hours).** Just above the feed's own 24 h
  heartbeat contract, with two hours of margin. It tracks feed liveness during market hours and
  fails closed off-hours.
- **Testnet: `900` (15 minutes).** We own the mock aggregator, so a tight bound makes the staleness
  edge reachable in a test run instead of requiring a weekend. **This value must not be carried to
  mainnet** — the deploy script carries an explicit guard and comment saying so, because the same
  knob loads the H-1 breaker (below).
- **`basisBandBps = 150`** on mainnet — three times the measured 49.3 bps worst case, so ordinary
  basis does not pause minting while a real dislocation still does. Testnet: `500`, for reachability.

### The coupling, and the fix that dissolves it

`stalenessSeconds` is doubly loaded: H-1 reuses it as `pokeLastGood`'s confirmation window. That
reuse is **deliberate and has a proof behind it** —

> *"with a STRICT `>` comparison the confirming observation is provably a different, fresher feed
> round than the arming one"* — `CertOracle.sol` NatSpec

so the window cannot simply be shortened without losing the distinct-round guarantee. At 26 h, a
20% repricing needs ~4 clamped steps ≈ **4.3 days** of minting shut. Real, but survivable, and
redemption is open throughout.

**The proper fix is to prove distinctness directly instead of inferring it from timestamps.**
`latestRoundData()` already returns `roundId`, and `CertOracle` discards it in both readers
(`CertOracle.sol:157` and `:186`). Store the armed `roundId`, require `roundId_confirm >
roundId_arm`, and the confirmation window becomes independent of the staleness bound — settable to
minutes.

The NatSpec's objection to a new constructor parameter ("the signature is load-bearing for every
deployer and fixture") **no longer holds**, and this was checked rather than assumed: the frozen
audit evidence does not construct `CertOracle` at all. `AttackSuite.t.sol:178-180` builds only
`SolvencyRegistry` and `CapacityOracle`; `AuditPoC.t.sol` builds neither. All 13 `new CertOracle`
sites are ours to update.

Since §2 changes that constructor anyway, both land together.

---

## 2. Decision: venue-priced assets stay in scope — and that makes a silent failure a must-fix

> *"keep all possibility and we will open new mirror as long as a market rises"*

This is no longer a documented trade-off to accept. If a vault will ever be deployed against one of
the 28 unfeeded markets, the following must be closed **before** that deployment, because each fails
silently:

| Hole | Behaviour today with a venue-sourced price |
| --- | --- |
| `basisBpsChecked()` | Returns `known = true, bps = 0` — it **actively asserts a healthy basis it never computed**. Nothing in the contracts, the suite, or the checklist flags a vault deployed this way |
| `mintAllowed()` | Two of its three guards degenerate. The feed and the cross-check are the same source, so the basis band is a no-op that still looks configured |
| The deviation clamp | Becomes the only remaining guard — and it is a **rate limit, not a truth check** |

The economics make this live rather than theoretical: moving the Lighter mark moves a venue-sourced
feed and `markPx18` **together**, holding the basis at zero, and ANTHROPIC's capacity is only ~$486k
against $4.88M of OI.

**Required work:** an explicit `SINGLE_SOURCE` oracle mode, chosen at construction, in which the
basis guard is *absent rather than vacuous*, the deviation clamp is tightened, and the mode is
published on-chain so the UI can label the asset. A venue-priced certificate is a materially
different product — the venue is both the price source and the counterparty — and the front-end must
say so per asset rather than presenting all vaults identically.

**Do not deploy a vault against an unfeeded market until this ships.** The order in §5 reflects that.

---

## 3. Decision: `instantCap18` — a rule, not a constant

The instant path's mint-to-fill variance lands on the hot buffer, which is `1 − targetMarginBps` ≈
**10% of TVL**. An instant cap above the buffer is decorative. The fixture's `10_000e18` exceeds the
*entire* buffer of a $90k TSLA vault.

**Rule: `instantCap18` ≈ 2–3% of the vault's capacity at deploy time**, so roughly four concurrent
instant redemptions are servable from the buffer before the queued path takes over.

| Vault | Capacity | Buffer ≈ | `instantCap18` |
| --- | --- | --- | --- |
| uTSLA | $90k | $9k | **2_000e18** |
| uSPY | $5.00M | $500k | **50_000e18** |
| Testnet (either) | — | — | **1_000e18**, so testers cross into the queued path deliberately |

It is immutable, so it is set from *then-current* capacity and grows conservative as the market
grows. That is the right direction for a convenience path.

---

## 4. Decision: repo access — build for both routes, push to neither yet

> *"i'll have full access soon"*

Verified today: `admin=false, maintain=false, push=true`, sole admin `sleroy1312-arch`. Until admin
lands, every front-end work item is built as a **self-contained adapter** that can either be
branched into their repo or handed over as a package plus an integration brief. Nothing is pushed
there in the meantime.

Two constraints that survive full access:

- **Lovable sync.** All 45 commits in that repo are bot-authored (43 `gpt-engineer-app[bot]`, 2
  Lovable), and its `AGENTS.md` warns that pushed commits sync back into the Lovable editor and that
  rewriting history loses the owner's project history. Hand-written commits may be overwritten by the
  next generation. Coordinate before writing there, admin or not.
- **No lifecycle scripts.** Both drift snapshots assert *"Lifecycle scripts (MUST be none)"* and
  *"CI workflows (MUST be none)"*. A committed generated-TS ABI module preserves that; a wagmi-CLI
  `postinstall` hook destroys it. This constraint is deliberate.

One thing full access *fixes*: deploy keys and webhooks are currently marked `NOT VERIFIABLE` in
`scripts/audit-collab-repo.sh`. Admin closes that blind spot — worth re-running the audit the day it
lands.

---

## 5. The work, in dependency order

Effort is S (<½ day), M (½–2 days), L (2–5 days).

### Phase 0 — `CertOracle` changes, because everything downstream binds it immutably

| | Item | Effort |
| --- | --- | --- |
| 0.1 | `roundId`-based distinctness for `pokeLastGood`, plus an independent `pokeConfirmationSeconds` | M |
| 0.2 | `SINGLE_SOURCE` mode: basis guard absent not vacuous, tightened clamp, published mode flag (§2) | L |
| 0.3 | Bound `_readFeed`'s decimals the way `_tryFeed` already is — closes the documented asymmetry where a feed reporting `decimals() ≥ 96` panics `px()` and kills both mint paths | S |
| 0.4 | Update all 13 `new CertOracle` sites and the fixture | S |

**This phase must land first.** Every dependency is immutable at construction and the vault mints its
own certificate token, so a `CertOracle` change after a vault is deployed means redeploying the vault
and issuing a **new certificate** — with no migration path for holders.

### Phase 1 — the venue simulator

Do **not** promote `MockLighter` in place: 132 `settleBatch` call sites, and 3 tests depend on it
reverting `InsufficientMargin`. Extract a shared `LighterCore` with a deployable `LighterSim` on top,
so the unit suite and the testnet run the same code and cannot drift.

| | Item | Effort |
| --- | --- | --- |
| 1.1 | `LighterCore` / `LighterSim` extraction | L |
| 1.2 | **Gate `setRequiredMarginBps`** and floor it. It is ungated `external` today — on a public testnet any address can set it to 0, silently, no event, every test still green. *This is the top risk on the whole task* | S |
| 1.3 | Make `withdraw()` **asynchronous** — it currently credits the pending balance in the calling transaction, which is easier than mainnet | M |
| 1.4 | Make account registration **asynchronous** — `deposit()` assigns `addressToAccountIndex` inline, which defeats checklist step 8, *"the real sequencing guarantee"* | M |
| 1.5 | Require a non-zero mark price. `markPrice` defaults to 0 → notional 0 → `InsufficientMargin` passes **vacuously**, so a script that forgets `setMarkPrice` certifies against a venue with no margin requirement | S |
| 1.6 | Key all state by account; fix `cancelAllOrders` (ignores its `accountIndex`, wipes the global queue); stop `settleBatch` reverting wholesale on one vault's order. Three cross-vault DoS vectors | L |
| 1.7 | Replace `_fundPending`'s silent mint with an explicit, evented insurance fund — today the venue can *always* pay, so no test can construct a venue shortfall | M |
| 1.8 | Funding payments; per-market IMF table pinned to the live 5000 | M |
| 1.9 | Liquidation and partial fills — the states that flip `venuePositionBase`'s sign, which `closeAll()`'s M-3 fix depends on and nothing currently exercises | L |
| 1.10 | Events for the indexer (zero exist), deposit cap and tick-size enforcement, `forge build --sizes` assertion | M |

Priority-queue expiry ships as **event data only**; desert mode is skipped for testnet.

### Phase 2 — prices on a chain with no Chainlink

| | Item | Effort |
| --- | --- | --- |
| 2.1 | Replay-capable mock aggregator per asset, seeded from real RH mainnet feed history | M |
| 2.2 | A feed keeper to advance it — without one, `maxAttestationAgeSec` starves minting within minutes | S |

### Phase 3 — deployment

| | Item | Effort |
| --- | --- | --- |
| 3.1 | `script/DeployTestnet.s.sol`: chain-ID guard, three-sender split (deployer / governance / attester), registry and oracle deployed **inside `vm.startBroadcast(GOV_PK)` at depth 1** per checklist §4 | M |
| 3.2 | Bootstrap: collateral in **before** `bootstrap()`, then a simulator batch advance **before** any mint | M |
| 3.3 | `script/VerifyTestnet.s.sol` — separate, because the §9 `require`s inside a deploy script assert the **local simulation**, never on-chain state | S |
| 3.4 | Address book `deployments/<chainId>.json`, versioned per deployment — never hand-edited, since each new mirror is a new vault *and* a new certificate token | M |
| 3.5 | Size gate wired into a wrapper, not left to memory | S |
| 3.6 | `smokeTest()`: the live dust `forceExit` §9 asks for | S |

**First vaults: uTSLA (market 16) for continuity with the existing suite, then uSPY (26) — not
NVDA.** SPY has a feed and 55× the capacity.

### Phase 4 — the two keepers that must exist

Without them the testnet vault stops minting within ~15 minutes of deploy, and anyone testing will
read that as a deploy failure and start changing immutable parameters to chase it.

| | Item | Effort |
| --- | --- | --- |
| 4.1 | Batch advancer for the simulator — the seventh worker the spec never needed | S |
| 4.2 | Attester: `attest(...)` + `setMarkPrice(...)`. On testnet it reads the simulator's true position directly instead of reconstructing blobs — **note in the UI that this makes testnet solvency stronger than mainnet's** | M |

### Phase 5 — front-end adapter

| | Item | Effort |
| --- | --- | --- |
| 5.1 | wagmi + viem, SSR-gated; real connector at the two seams that own the fake wallet | M |
| 5.2 | Units adapter — the largest hidden cost, and the thing that decides every displayed number | L |
| 5.3 | Overview + RiskView reads; **surface `provenAtBatch` / `ageSec`**, which the contract provides and the UI has nowhere to put | L |
| 5.4 | MintRedeem: implement the instant-vs-request fork the contract actually enforces | L |
| 5.5 | Chain gate for 46630. **Do not put 4663 in a chains config** — mainnet's chain ID is still unverified | M |
| 5.6 | The eight blocking copy items — **three are structural, not string edits**: the "every block" claim needs `provenAtBatch`/`ageSec` in the data model first; Honest Boundaries is a single hardcoded animated blockquote with no list to append to; and `$213B` is baked into a live route slug (`learn/data.ts:35`) | L |
| 5.7 | **A ninth copy item, not in the spec:** a prominent *simulated venue* banner. Every number a testnet dashboard prints is simulator output, rendered under UI text saying "provable on-chain" and "you never have to take our word for it" | S |
| 5.8 | Decide the fate of `StakingView` (13.8 KB, full cooldown economy, **no contract**), `KeepersView` (five keepers, hardcoded run counts, only `rebalance()` is real), and `Marquee` (advertises `InsuranceStaking` and `FeeVault`, neither of which exists). Wiring the real screens while leaving these live produces a demo where nobody can tell which half is real | M |

**Read the chain directly via viem/wagmi for all live state.** The demo's whole proposition is "you
never have to take our word for it", and a backend reintroduces the trusted intermediary the product
exists to remove. `react-query` is already in the repo, so caching is free.

Two screens direct reads cannot build, and they should be explicitly stubbed for the demo rather
than faked: **historical series** (no view function returns history) and **receipts** — `receiptId`s
are not enumerable on-chain, and no receipts screen exists anywhere in that repo today. That is the
strongest argument for the indexer, and the thing most likely to be discovered late.

---

## 6. The per-asset mirror playbook

> *"we will open new mirror as long as a market rises"*

Adding a mirror must be a parameterised script run, never a hand edit. Per asset:

1. Confirm a **perp market** exists and record `market_id`, `price_decimals`, `size_decimals`.
2. Confirm a **price feed** — or accept `SINGLE_SOURCE` mode (§2) and its per-asset label.
3. Check the price sits inside the `uint32` tick domain at that `price_decimals`.
4. Set `instantCap18` from §3's rule against *current* capacity.
5. Deploy `CertOracle` **from governance**, then the vault from the deployer, then
   `registerVault`, `setAbsoluteCap`, `setBufferThresholds`.
6. Re-run `forge build --sizes`; append to `deployments/<chainId>.json`.

Shared across all mirrors: `SolvencyRegistry`, `CapacityOracle`, `CertFactory`, the simulator.
New per mirror: a `CertOracle`, a `CertVault`, and the `Certificate` + `BufferBook` its constructor
deploys.

Capacity tracks open interest automatically, so a rising market widens an existing mirror with no
redeploy. A *new* mirror is only ever needed for a **new asset**.

---

## 7. What a testnet pass will not prove

Stated plainly, because this project's recurring failure has been a suite certifying what the venue
would reject — three times: unmodelled margin, unmodelled PnL, unenforced EIP-170.

- **`baseAmount == 0` direction semantics.** The simulator inherits the design spec's reading, not
  Lighter's source, which is not in this repo. The reading is conservative, so a vault correct
  against the sim is correct either way — but the testnet run does not confirm it and cannot.
- **Whether the real venue credits a partial pending balance** for a partially-fulfillable
  withdrawal, or consumes the request entirely. Materially different states for `_sweepPending`.
- **The real maintenance-margin fraction.** Only the *initial* fraction (5000) was verified across
  all 57 markets. The liquidation trigger point is unpinned until it is fetched.
- **The real batch cadence.** The ~60 s figure comes from this repo's own docs, never a measurement
  against 46630.
- **Chainlink's behaviour**, at all — there is no Chainlink on testnet, so the 24/5 gap, the
  corporate-action pause, and aggregator rotation are all unexercised. §1's staleness choice is
  therefore validated on mainnet data and *reasoned*, not tested.
- **`uiMultiplier`.** Inferred to be 1 for the 13 measured markets because the basis was 11–49 bps
  rather than a factor of N — but it reverts on the proxy and was never read directly.

## 8. Open questions worth one cheap experiment each

| Question | Experiment |
| --- | --- |
| Will Chainlink deploy feeds for XAU, XAG, ANTHROPIC, OPENAI, SHEIN? XAU is the largest unfeeded market at $12.53M | Email `chainlink_data_feeds@smartcontract.com`, the contact their own RH docs page publishes |
| Will Chainlink deploy *testnet* feeds on 46630? Absent today, but possibly just unrequested | Same email. Would delete Phase 2 entirely |
| Real weekend gap length | A Friday-through-Monday `updatedAt` observation run on the mainnet feeds |
| RH mainnet chain ID | One `cast chain-id` call — and only one, it 429s |
| Testnet faucet capacity | The vault CREATE alone is ~26.5 KB of initcode across ~15–18 transactions and three senders |
