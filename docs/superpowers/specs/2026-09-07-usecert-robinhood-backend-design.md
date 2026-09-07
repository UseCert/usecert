# UseCert Backend Design — Robinhood Chain (C1)

**Date:** 2026-09-07
**Status:** Approved design, pre-implementation
**Scope:** Backend only (contracts + off-chain services). Front-end exists and is out of scope.

---

## 0. Provenance and what this document changes

This spec derives from two source documents, `Cert Overview.pdf` and `Cert Backend.pdf`, both of
which target **Hyperliquid/HyperEVM** (HIP-3 equity perps, trade.xyz as market operator,
`CoreWriter` for EVM to Core actions, Core read precompiles as the source of truth).

The product is being built on **Robinhood Chain** instead. That is not a port; the execution venue
has a fundamentally different architecture, and three of the original design laws had to be
restated. This document is the authority where it disagrees with the PDFs.

**Current state of the codebase:**

- Front-end: `usecertlah.lovable.app`, repo `sleroy1312-arch/usecertlah` (audited 2026-09-07).
  Lovable-generated React/Vite/TanStack Start. 138 `.tsx` files, no wallet libraries, no contracts,
  no backend, no CI. All dashboard figures are mock data in `src/pages/dashboard/store.tsx`.
- Backend: **does not exist.** The site advertises phase "C1 LIVE"; nothing behind it is built.

---

## 1. Premise corrections

The Hyperliquid documents rest on a market gap that does not exist on Robinhood Chain. These
claims currently appear on the live site and are false there:

| Claim in source docs / on site | Reality on Robinhood Chain |
| --- | --- |
| "No custodial stock token exists here" | Robinhood **Stock Tokens** are live as plain ERC-20s with per-asset Chainlink feeds, tradeable on Uniswap and Pleiades, with ~$12M already posted into DeFi |
| "You cannot simply hold a stock" | You can. Spot Stock Tokens shipped at mainnet (2026-07-01) |
| "The first holdable stock tokens" | Taken by Robinhood itself. Separately, **Arcus pTokens** (2026-08-25) already wrap perp accounts as transferable ERC-20s, including stock names such as `pHOOD3x` |
| `$213B` RWA perp volume / `32.2%` of chain volume / RWA OI passing Bitcoin / 23 of top 30 pairs | These are **Hyperliquid** Q2-2026 figures. They are not Robinhood Chain figures and must not be presented as such |

### 1.1 The defensible claim

Robinhood Stock Tokens are **debt securities issued by Robinhood Assets (Jersey) Limited**,
custodial in substance, and unavailable to US persons.

UseCert's real differentiator is therefore **not** "the first holdable stock token." It is:

> Equity price exposure with no custodian, no issuer credit risk, and no geo-gate — fully
> synthetic, backed by on-chain perp positions and margin that anyone can verify.

The comparison table already on the site states this correctly in its "Custodian & geo-gate:
None, fully synthetic" row. The headline copy must be brought in line with that row.

---

## 2. Design laws (revised)

Laws 1-5 restate the source spec's PART 0 with the amendments the venue forces. Law 6 is new and
is a strict improvement over the original.

1. **Every certificate is fully delta-backed.** Per-asset vault targets delta 1.0:
   `uToken supply x oracle px <= perp position notional + USDG margin`.
   **Amended:** provable **per Lighter batch (~60s)**, not per block. The published solvency figure
   always carries its own age.
2. **Redemption is never gated.** Burn leads to closed exposure leads to USDG at oracle price.
   **Strengthened:** enforced by Lighter's on-chain **priority transaction queue** with a
   contractual execution deadline, and by the **Escape Hatch** if the sequencer fails. This is a
   stronger guarantee than the original `CoreWriter` design, which relied on the vault's own
   liveness.
3. **Funding is buffered, then fee'd, never hidden.** Positive funding fattens the buffer; negative
   funding draws it down; past a published threshold it passes through as a published, capped
   holding fee. All parameters and the live buffer on-chain.
4. **Holders are senior.** Staked `$CERT` absorbs buffer exhaustion before holder backing is
   touched. Draw order is immutable.
5. **Mirror the underlying market honestly.** Corporate actions and pricing follow the venue's
   market spec. Certificates never claim custody, dividends, or shareholder rights.
6. **Keeper containment is structural, not procedural.** The account that executes trades is
   physically incapable of withdrawing assets — a property of the Lighter Public Pool account
   type, not of our access control. The original spec could only promise this by policy.

**Explicitly dropped:** the source spec's "precompile reads are the single source of truth; no
off-chain accounting is load-bearing." It is unachievable here and is replaced by Section 8.

---

## 3. Venue analysis: Lighter

Lighter is the only perpetuals venue on Robinhood Chain. Perpetra routes its order flow to Lighter,
so it inherits every constraint below. Uniswap and Pleiades are spot-only.

Lighter is a **zk-rollup settling to Robinhood Chain**, not an EVM contract. Matching, positions,
funding and liquidations execute inside its circuits. What lives on Robinhood Chain is the
`ZkLighter` contract, which holds deposits, holds the canonical state root, queues priority
requests, and records the `commit -> verify -> execute` batch lifecycle at roughly one batch per
minute.

### 3.1 What a contract can and cannot do

| Operation | Contract-callable on Robinhood Chain? |
| --- | --- |
| Deposit collateral | **Yes** — ordinary contract call |
| **Open / increase** a position | **No** — orders are signed off-chain and matched in-rollup |
| **Close / reduce** a position | **Yes** — reduce-only IOC via the priority queue |
| Withdraw collateral | **Yes** — via the priority queue |
| Redeem public pool shares | **Yes** — via the priority queue |
| Read live position / margin / funding | **No** — in-rollup state; on-chain sees roots and blobs |

### 3.2 The asymmetry, and why it fits

Priority transactions cover **exit** operations only, with enforced execution and an Escape Hatch
backstop. Entry has no trustless primitive.

This maps precisely onto the design laws. Law 2 makes redemption absolute — and redemption is
exactly the side with the trustless, deadline-enforced, censorship-resistant path. Law 3 already
contemplates minting slowing under stress — and minting is the side that depends on keeper
liveness. The guarantee we must never break is the one the venue enforces for us.

### 3.3 Account types

Lighter defines four account types. Type 3, **Public Pool**, is the one that matters: a sub-account
that other accounts can buy into, which *"cannot transfer or withdraw the assets they hold, but
they can trade in the markets."*

That is Law 6, for free, at the protocol level.

Standard accounts are limited to 4 sub-accounts per L1 address. Since each `CertVault` is its own
contract with its own address, per-asset isolation scales without hitting this limit — factory
deployment gives it to us naturally.

---

## 4. Architecture

```
[User]  mint(USDG, asset) / redeem(uToken)
   |
   v
CertVault[asset]  (Robinhood Chain)                     CertFactory
   |  - holds USDG hot buffer for instant settlement     deploys one vault +
   |  - sole participant in the asset's Lighter          one Certificate per asset
   |    Public Pool (owns 100% of shares)
   |  - mints/burns Certificate at CertOracle px +/- fee
   |  - enqueues priority tx for close/withdraw          Certificate[asset] (uTSLA, uNVDA, uSPX)
   |  - BufferBook accrual, SolvencyRegistry attestation      ERC-20, mint/burn only by its vault
   |
   +--> ZkLighter contract  ---- deposit (sync) ------> Lighter Public Pool sub-account
   |                        ---- priority: close ---->   position + margin live in-rollup
   |                        ---- priority: withdraw ->
   |
   +--< state root + blobs (per batch, ~60s) --------- solvency proof input

Keeper (pool operator key): may TRADE ONLY. Cannot withdraw — structurally.
```

### 4.1 The core decision: pool as container, not as product

`CertVault[asset]` is the **sole participant** in a per-asset Lighter Public Pool. The keeper is
the pool operator.

Users never see pool shares. The vault holds 100% of them, and shares are internal plumbing.
`uTSLA` is minted against **oracle price at delta 1.0**, not against pro-rata pool NAV.

This distinction is the entire difference between UseCert and Arcus. Arcus `pTokens` *are*
pro-rata claims on a perp account at a fixed leverage — so their value tracks the account's NAV,
including its funding history and execution quality. A share wrapper cannot satisfy Law 1.
Vault-level delta-1.0 accounting can: the vault absorbs funding and execution variance into
`BufferBook`, and the certificate tracks the stock.

What we get from the pool container:

- Keeper cannot withdraw (Law 6), structurally.
- Share redemption is a **priority transaction**, giving the vault a censorship-resistant exit
  path in addition to position close and withdrawal.
- Pool leaves in the Public Account Tree carry total share counts, which the solvency proof uses.

---

## 5. Contracts (Foundry)

Names match the front-end's architecture display, which is a hard constraint.

```solidity
// Certificate.sol — ERC-20 per asset (uTSLA, uNVDA, uSPX). mint/burn only by its vault.

// CertVault.sol — one per asset, factory-deployed. Owns the Lighter Public Pool sub-account.
//   mintInstant(usdgIn)      : size <= instantCap. px = CertOracle.px(asset), guards applied.
//                              out = (usdgIn - fee) / px. Pays from hot buffer; Certificate.mint.
//                              Emits HedgeRequested for the keeper. Reverts if buffer or oracle
//                              is unhealthy — minting may be gated (Law 3).
//   requestMint(usdgIn)      : size > instantCap. Escrows USDG, issues an ERC-721 MintReceipt.
//   settleMint(receiptId)    : after proven fill, mints Certificate at the ACTUAL fill price.
//                              Vault carries no execution risk on large mints.
//   redeemInstant(uIn)       : size <= instantCap. Burns, pays USDG = uIn*px - fee from the hot
//                              buffer immediately. Never checks buffer health (Law 2).
//   requestRedeem(uIn)       : size > instantCap. Burns immediately, enqueues priority
//                              reduce-only close + withdraw, issues RedeemReceipt.
//   claimRedeem(receiptId)   : pays out once the priority withdrawal lands.
//   forceExit(uIn)           : permissionless. Anyone may enqueue the priority path directly,
//                              bypassing the keeper entirely. The Law 2 backstop.
//   rebalance()              : keeper-called, permissionless with bounty. Trims delta into band.
//                              Bounded notional per call.
//   solvency()               : view -> {supply, notional, margin, buffer, delta,
//                              provenAtBatch, ageSec}

// CertOracle.sol — Chainlink per-asset feed primary; Lighter mark price as cross-check.
//   Guards: staleness, deviation vs last-good, feed-halt flag, and Chainlink-vs-mark basis band.
//   Breach pauses MINTING only. Redemption follows the published last-good-px procedure.

// BufferBook.sol — per-asset funding + execution-variance accrual. Thresholds:
//   {fee_on, mint_slow, insurance_draw}. Holding-fee stream activates past fee_on at a published,
//   capped rate. Also absorbs mint-to-fill slippage on instant mints.

// InsuranceStaking.sol — stake $CERT as junior tranche. Draw order is immutable:
//   buffer -> staked $CERT -> (never) holder backing. Stakers earn mint/redeem bps +
//   funding surplus.

// SolvencyRegistry.sol — accepts and verifies per-batch backing attestations. See Section 8.

// FeeVault.sol — fee split 80/10/5/5 per the overview: buyback / staker pay / treasury / ops.

// CERT.sol — governance and staking token. C3.

// CertFactory.sol — deploys {CertVault, Certificate} pairs, registers the Lighter pool,
//   sets immutable fee bounds and draw order at deploy. Timelocked upgrades.
```

---

## 6. Mint flow

Two paths, split on size, because the risks differ.

**Instant (`size <= instantCap`)** — optimistic, buffered:

1. Pull USDG. Read `CertOracle.px`, apply staleness/deviation/basis guards.
2. `out = (usdgIn - fee) / px`. Mint `Certificate` immediately.
3. Credit USDG to the hot buffer; emit `HedgeRequested(asset, out)`.
4. Keeper opens the long on Lighter within the next batch and deposits margin.
5. Realised fill vs `px` accrues to `BufferBook` as execution variance — positive or negative.

The vault carries mint-to-fill risk here. `instantCap` is therefore sized against the buffer, not
against demand, and drops automatically as buffer health degrades (`mint_slow`).

**Request/settle (`size > instantCap`)** — no execution risk:

1. Escrow USDG, issue `MintReceipt` (ERC-721).
2. Keeper executes; fill is proven against the batch attestation.
3. `settleMint` mints at the **actual fill price**, refunding any unspent escrow.

This is what stops a large minter from taxing the buffer during a gap move.

---

## 7. Redeem flow

Law 2 is absolute, so redemption has three tiers and the last one needs nobody's cooperation.

1. **Instant** (`size <= instantCap`): burn, pay from the hot buffer at oracle px minus fee. Does
   not read buffer health. Typical path.
2. **Queued** (`size > instantCap`): burn immediately, vault enqueues a priority reduce-only close
   plus withdrawal, issues a `RedeemReceipt`, pays on arrival. Bounded by Lighter's enforced
   execution window.
3. **Force exit** (any size, permissionless): `forceExit` lets any holder enqueue the priority
   path directly. If the keeper is dead, malicious, or gone, redemption still completes. If the
   Lighter sequencer also fails, the exchange freezes and holders exit via Escape Hatch, where
   positions settle at last mark price.

No tier consults buffer health. That is the whole point.

---

## 8. Solvency: on-chain proof, per batch

The original spec's guarantee came from precompiles. Here it must be reconstructed.

**What Lighter gives us:** the **Public Account Tree** holds each account's aggregated asset value,
position sizes, funding data, ownership info, and — for public pools — total share counts. It is
merkleized with Poseidon2. Its root is committed on-chain and zk-verified each batch, and the tree
is *"fully reconstructible solely from the blob data posted"* by replaying **Account Delta Trees**
from every batch.

**Design:**

- `solvency-prover` maintains a live reconstruction of the Public Account Tree from blob data and
  produces an inclusion proof for each vault's pool sub-account leaf.
- `SolvencyRegistry.attest(asset, batchId, leaf, proof)` verifies the proof against the
  `ZkLighter` contract's verified root for that batch and stores `{notional, margin, shares}`.
- `CertVault.solvency()` returns backing from the last verified attestation, **always with
  `provenAtBatch` and `ageSec`**.
- Anyone can submit an attestation. It is permissionless and verified, so a stale or lying keeper
  cannot suppress it — a competitor can post the truth.

**Trust properties:** backing is *proven*, not asserted. The submitter is untrusted. What we lose
versus precompiles is only **freshness**: ~60s instead of per-block, and the age is published
rather than hidden.

**Open item (O-1):** whether Poseidon2 inclusion-proof verification is affordable in Robinhood
Chain gas. If not, fallback is off-chain verification with the on-chain root as anchor plus
published reproduction instructions — weaker, and it must then be described honestly as such.

**Front-end consequence:** *"provable on chain every block"* and *"solvency public every block"*
must become *"proven on-chain every batch (~60s), with age published."* Still strictly stronger
than the periodic attestations the comparison table attributes to custodial competitors.

---

## 9. Collateral: USDG, not USDC

Robinhood Chain's Lighter instance uses **USDG** as base collateral. Its multi-asset margin set
(SPY, USO at 50% LTV) carries small per-user and global supply caps and is **not** to be used —
vaults post USDG only.

Every source document and the entire front-end say "USDC."

**Resolution:** the vault is **USDG-native** internally. A thin `Zap.sol` at the edge accepts USDC
and swaps to USDG via Pleiades or Uniswap, with slippage bounds and a fail-closed path. The UX line
"deposit USDC" survives; the accounting, margin, and solvency math are USDG throughout. The zap is
explicitly *outside* the solvency perimeter.

**Open item (O-2):** confirm USDG/USDC depth on-chain. If it is thin, the zap ships disabled and
the copy changes to USDG instead.

---

## 10. Oracle and basis risk

Two prices exist and they are not the same number:

- **Chainlink per-asset feed** — mints and redeems price against this. It is what "oracle price"
  means to a holder.
- **Lighter mark price** — what the hedge actually fills and gets funded against.

Their spread is a real, unhedged risk the source documents never name, because on Hyperliquid both
came from Core. Handling:

- `CertOracle` publishes both plus the live basis.
- Basis beyond a published band pauses minting; redemption continues on the last-good procedure.
- Realised basis accrues to `BufferBook` alongside funding.
- The band and its history go on the public dashboard.

This belongs in "Honest boundaries" as a named risk.

---

## 11. Off-chain services

Studio conventions: Bun, Hono, tRPC v11, Drizzle on Postgres + Timescale, Redis + BullMQ, viem.

| Worker | Job |
| --- | --- |
| `hedge-executor` | Consumes `HedgeRequested`; opens/adjusts longs as pool operator. Trade-only key |
| `delta-keeper` | Band check per batch window; calls `rebalance()`. Permissionless + bounty |
| `funding-sweeper` | Accrues funding and realised basis into `BufferBook`, hourly |
| `solvency-prover` | Reconstructs Public Account Tree from blobs; submits attestations per batch |
| `buffer-watchdog` | Threshold transitions, fee activation, `instantCap` adjustment |
| `chain-indexer` | Flows, receipts, events |

tRPC surface, driven by what the front-end already renders:

```
vaultRouter.list()                    -> vaults, status, phase
vaultRouter.solvency(asset)           -> backing + provenAtBatch + ageSec
vaultRouter.quoteMint(asset, usdg)    -> out, fee, px, path: instant|request
vaultRouter.quoteRedeem(asset, uAmt)  -> usdg, fee, px, path, eta
bufferRouter.state(asset)             -> buffer, thresholds, feeRate, basis
receiptRouter.byWallet(wallet)        -> open mint/redeem receipts
stakeRouter.*                         -> C3
statsRouter.history(asset, range)     -> Timescale series
```

---

## 12. Data model (Drizzle)

```
vaults     /* asset, vaultAddr, certificate, lighterPoolIdx, marketId, status, instantCap */
solvency   /* asset, batchId, ts, supply, notional, margin, buffer, delta, proofOk */  // Timescale
funding    /* asset, ts, fundingRate, basis, accrued, bufferAfter */                   // Timescale
flows      /* asset, kind mint|redeem, path instant|request, user, usdg, uAmount, px,
              fillPx, fee, txHash, ts */
receipts   /* id, asset, kind, user, escrow, status, enqueuedBatch, settledBatch */
stakes     /* wallet, amount, since, rewardsAccrued */
```

---

## 13. Security and failure modes

| Failure | Response |
| --- | --- |
| Keeper key compromised | Pool account cannot withdraw. Worst case: adversarial trading within delta bands. Bounded, and rebalance caps notional per call |
| Keeper offline | Instant mint/redeem continue from the hot buffer. Delta drifts; `mint_slow` engages. `forceExit` keeps redemption open |
| Oracle stale or deviant | Minting pauses. Redemption uses published last-good procedure. Never trapped |
| Chainlink-vs-mark basis blowout | Minting pauses; realised basis to buffer; band published |
| Lighter sequencer censors | Priority queue has an enforced deadline; miss freezes the exchange and opens Escape Hatch |
| Escape Hatch triggered | Positions settle at last mark. Vault reconstructs state, proves ownership, withdraws, and pays holders pro-rata from recovered value. Procedure published in advance |
| Market delisted or halted | Per-asset wind-down: minting off, redemption continues against closing position and margin |
| Buffer exhausted | Holding fee active and capped, then `insurance_draw` burns staked `$CERT`. Holder backing untouched (Law 4) |

Additional: fee bounds immutable at deploy; draw order immutable; timelocked upgrades; fresh
deployer plus multisig per studio OPSEC; invariant tests asserting `backing >= supply x px` across
mint/redeem/rebalance/funding fuzz; and asserting redemption never reverts on buffer state.

---

## 14. Testing and acceptance

Foundry unit and invariant tests, plus integration against **Robinhood Chain testnet Lighter** —
not mocks — before mainnet.

1. Instant mint: certificate minted, hedge opens within band next batch, solvency attestation holds.
2. Request mint: settles at actual fill price; vault absorbs no execution variance.
3. Redeem with buffer at zero and funding deeply negative: **still succeeds**.
4. `forceExit` with the keeper fully offline: holder exits unaided.
5. Funding: positive fattens buffer; negative crosses `fee_on`, holding fee activates with event,
   rate <= cap.
6. Insurance draw consumes staked `$CERT` before holder backing.
7. Oracle stale: minting paused, redemption follows last-good path.
8. Basis breach: minting paused, redemption unaffected.
9. Solvency attestation: valid proof accepted, forged proof rejected, stale attestation surfaces
   correct `ageSec`.
10. Escape Hatch fixture: holders made whole from recovered margin plus close.
11. Delta fuzz across gap moves stays in band post-rebalance.
12. Keeper-compromise simulation extracts no value.

---

## 15. Build order

- **C1** — `CertFactory`, `CertVault`, `Certificate`, `CertOracle`, `BufferBook`,
  `SolvencyRegistry`, `Zap`; `uTSLA` and `uNVDA`; hedge-executor, delta-keeper, solvency-prover;
  public solvency dashboard wired to real data. This is the claim, live.
- **C2** — `uSPX` / `uQQQ`; DEX seeding on Pleiades and Uniswap; lending-market integrations.
- **C3** — `CERT.sol` genesis, `InsuranceStaking`, funding-surplus flywheel.
- **C4** — Structured wrappers (DCA vault, covered-call-style vaults) on the certificate base.

**Kill/persist:** unchanged from the overview. If mint TVL misses threshold by day 30, the vault
engine persists as internal infrastructure and marketing rotates.

---

## 16. Open verification items

Resolve all of these against live contracts and current docs **before writing Solidity**. The
source spec's own warning applies: pin addresses and ABIs from official docs at build time, never
from memory.

- **O-1** Poseidon2 inclusion-proof gas cost on Robinhood Chain. Gates the Section 8 trust model.
- **O-2** USDG/USDC on-chain depth. Gates the zap and the "deposit USDC" copy.
- **O-3** Priority-transaction ABI, exact enforced deadline, and per-request fee on the Robinhood
  Chain deployment.
- **O-4** Whether a **contract** can create and operate a Lighter Public Pool, register an
  operator key via `ChangePubKey`, and be the sole participant. **This is the single highest-risk
  assumption in this document.** If a pool requires an EOA main account, the fallback is a
  minimal-trust operator contract plus a plain sub-account, which costs us Law 6's structural
  guarantee and must then be stated honestly.
- **O-5** Which equity perp markets exist on Robinhood Chain Lighter, their tick sizes, leverage
  caps, funding intervals, and corporate-action handling. Confirm per asset before enabling it.
- **O-6** Blob data retention and availability window, and whether an independent archive is
  needed for tree reconstruction.
- **O-7** Buffer floor and threshold parameters, fitted to historical funding and basis data
  pulled at build.
- **O-8** Whether Lighter API keys support trade-only scoping independently of the Public Pool
  account type (defence in depth for O-4's fallback).

---

## 17. Required copy changes

The backend cannot ship truthfully behind the current front-end. These are blocking:

1. `"provable on chain every block"` / `"solvency public every block"` becomes `"proven on-chain
   every batch (~60s), age published"`.
2. `"NO CUSTODIAL STOCK TOKEN EXISTS ON ROBINHOOD CHAIN"` — remove. Reposition on
   non-custodial / no-issuer-credit / no-geo-gate.
3. `"THE FIRST HOLDABLE STOCK TOKENS"` — remove. It is false on this chain.
4. `$213B` / `32.2%` / `RWA OI passing Bitcoin` / `23 of top 30` — remove or re-source. These are
   Hyperliquid figures.
5. `"Deposit USDC"` — acceptable only while the zap is live; the honest-boundaries page must state
   that backing margin is USDG.
6. Add to Honest boundaries: Chainlink-vs-mark **basis risk**, **Lighter dependency** (single
   venue, sequencer, Escape Hatch semantics), and **~60s solvency latency**.
7. `"C1 LIVE"` — not live until C1 ships.

---

## 18. Sources

Verified 2026-09-07.

- Robinhood Chain mainnet, Arbitrum Orbit — <https://blog.arbitrum.io/robinhood-chain-mainnet/>
- Robinhood Stock Tokens docs — <https://docs.robinhood.com/chain/stock-tokens/>
- Stock tokens in DeFi (~$12M) — <https://cryptobriefing.com/robinhood-chain-stock-tokens-defi-deposits/>
- Lighter whitepaper (state tree, priority transactions, account types, Escape Hatch) —
  <https://assets.lighter.xyz/whitepaper.pdf>
- Lighter Public Pools — <https://docs.lighter.xyz/trading/public-pools>
- Lighter on Robinhood Chain, USDG collateral — <https://docs.lighter.xyz/llms-full.txt>
- Arcus pTokens —
  <https://www.theblock.co/news/defi/2026-08-25-robinhood-chain-dex-arcus-ptokens-perps-erc-20s-412696>
- Perpetra — <https://www.perpetradex.com/>
