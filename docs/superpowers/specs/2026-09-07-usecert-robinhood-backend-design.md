# UseCert Backend Design — Robinhood Chain (C1)

**Date:** 2026-09-07
**Status:** Approved design, pre-implementation
**Scope:** Backend only (contracts + off-chain services). Front-end exists and is out of scope.

**Revision 2 (same day).** Revision 1 assumed, from Lighter's *documentation*, that opening a
position could not be initiated by a contract, and therefore built the design around a Lighter
Public Pool with an off-chain keeper. Reading the actual contract source
(`elliottech/lighter-contracts` @ `75c2a73`, 2026-09-07) disproved that: `ZkLighter.createOrder` is
`external`, accepts **both** order directions, and derives the account from `msg.sender`. The
architecture below is materially simpler and more trustless as a result, and the Public Pool has
been removed. Section 3.4 records why.

---

## 0. Provenance and what this document changes

This spec derives from two source documents, `Cert Overview.pdf` and `Cert Backend.pdf`, both of
which target **Hyperliquid/HyperEVM** (HIP-3 equity perps, trade.xyz as market operator,
`CoreWriter` for EVM to Core actions, Core read precompiles as the source of truth).

The product ships on **Robinhood Chain** instead. This document is the authority where it disagrees
with the PDFs.

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

## 2. Design laws

Laws 1–5 restate the source spec's PART 0 with the amendments the venue forces. Law 6 is new.

1. **Every certificate is fully delta-backed.** Per-asset vault targets delta 1.0:
   `uToken supply x oracle px <= perp position notional + collateral margin`.
   **Amended:** provable **per Lighter batch (~60s)**, not per block. The published solvency figure
   always carries its own age.
2. **Redemption is never gated.** Burn leads to closed exposure leads to collateral at oracle price.
   Enforced by on-chain `createOrder` + `withdraw` priority requests that **the vault contract
   itself submits**, with `PRIORITY_EXPIRATION = 14 days` as the censorship backstop and Desert
   mode (Escape Hatch) beyond it.
3. **Funding is buffered, then fee'd, never hidden.** Positive funding fattens the buffer; negative
   funding draws it down; past a published threshold it passes through as a published, capped
   holding fee. All parameters and the live buffer on-chain.
   **Amended (C1 audit, M-1 and M-2). Two corrections, both because the code did not do this:**
   - **A cliff ships in C1, not a ramp.** `BufferBook.holdingFeeBps()` and `mintSlowed()` compute
     the graduated response above and **nothing charges or applies either one**. `instantCap18` is
     immutable config with no setter, so it does not taper. What actually happens as the accrual
     ledger degrades is *nothing at all* until it crosses zero, at which point mint capacity goes
     to zero and **new minting halts outright**. The four thresholds
     (`floor`/`fee_on`/`mint_slow`/`insurance_draw`) are published *signals* in C1 — readable
     views and a `ThresholdCrossed` event — and are now configurable per asset
     (`CertVault.setBufferThresholds`, governance, ordering enforced) rather than hardcoded at
     100k/60k/30k/0 for every asset regardless of book size. Wiring the fee and the cap taper is a
     **C2** item. Redemption reads none of this, at any level, ever (Law 2).
   - **"The live buffer on-chain" means collateral, and now is.** Two different quantities were
     published as one. `solvency().buffer18` is the collateral the vault actually holds — an ERC20
     balance, ground truth — and `solvency().accrual18` is the `BufferBook` ledger, published
     beside it as what it is: **cumulative P&L (funding, execution variance, realised basis),
     relayed by the attester and not independently verified on-chain**. The old single field was
     the ledger under the name "buffer": it drifted from the real float under ordinary operation
     (measured 100,000.01 published against 91,028.00 held after one mint + instant-redeem cycle)
     and `accrueFunding()` let the attester declare it outright (measured 500,100,000.01 published
     against 91,028.00 held).
4. **Holders are senior.** Staked `$CERT` absorbs buffer exhaustion before holder backing is
   touched. Draw order is immutable.
5. **Mirror the underlying market honestly.** Corporate actions and pricing follow the venue's
   market spec. Certificates never claim custody, dividends, or shareholder rights.
6. **No privileged trading key exists.** The hedge is placed by the vault contract's own code via
   on-chain `createOrder`. There is no keeper key with authority to trade or withdraw, so there is
   nothing to compromise. The optional off-chain API key (Section 11.1) is a latency optimisation
   that the on-chain path can always override, and it is scoped so it cannot withdraw.

**Explicitly dropped:** the source spec's "precompile reads are the single source of truth; no
off-chain accounting is load-bearing." Position state lives in-rollup and is replaced by the proof
system in Section 8.

---

## 3. Venue analysis: Lighter

Lighter is the only perpetuals venue on Robinhood Chain. Perpetra routes its order flow to Lighter,
so it inherits every constraint below. Uniswap and Pleiades are spot-only.

Lighter is a **zk-rollup settling to Robinhood Chain**. Matching, positions, funding and
liquidations execute inside its circuits. On Robinhood Chain sits the `ZkLighter` contract, which
custodies deposits, holds the canonical state root, maintains the priority request queue, and
records the `commit -> verify -> execute` batch lifecycle at roughly one batch per minute.

### 3.1 What a contract can do — verified against source

All of the following are `external` on `ZkLighter` (delegating to `AdditionalZkLighter`) and derive
the acting account from `msg.sender` via `validateAndGetAccountIndexFromAddress`. **No function
anywhere restricts callers to EOAs**; the sole `_hasCode` check asserts that *system* addresses
(governance, verifier, token) are contracts.

| Operation | Contract-callable | Entry point |
| --- | --- | --- |
| Deposit collateral, registering the account | **Yes** | `deposit(address _to, uint16 _assetIndex, RouteType, uint256 _amount)` — calls `registerDeposit(_to, ...)`, so depositing to a contract address registers it |
| **Open / increase** a position | **Yes** | `createOrder(_accountIndex, _marketIndex, _baseAmount, _price, _isAsk, _orderType)` — `_isAsk` may be 0 or 1 |
| **Close / reduce** a position | **Yes** | same `createOrder`; `_baseAmount == 0` **defaults to full position size** (a clean close-all primitive) |
| Withdraw collateral | **Yes** | `withdraw(_accountIndex, _assetIndex, RouteType, _baseAmount)` |
| Cancel all orders | **Yes** | `cancelAllOrders(_accountIndex)` |
| Register an API key | **Yes** | `changePubKey(_accountIndex, _apiKeyIndex, _pubKey)`; passing `NIL_ACCOUNT_INDEX` resolves to the caller's own master account |
| Redeem public pool shares | Yes | `burnShares(...)` — unused in this design, see 3.4 |
| Read live position / margin / funding | **No** | in-rollup state; the chain sees roots and blobs only |

Every one of these enqueues a priority request via `addPriorityRequest`, which:

- charges **no protocol fee** — gas only;
- stamps `expirationTimestamp = block.timestamp + PRIORITY_EXPIRATION`, where
  `PRIORITY_EXPIRATION = 14 days`;
- emits `NewPriorityRequest`, and caps pubdata at `MAX_PRIORITY_REQUEST_PUBDATA_SIZE = 100` bytes.

**The 14 days is a censorship deadline, not expected latency.** Normal processing is one batch
(~60s). If the sequencer fails to process a request within 14 days, `activateDesertMode()` freezes
the rollup and holders exit by proving ownership against posted blobs. Redemption SLAs must be
quoted as "~1 batch expected, 14 days worst case, then Escape Hatch" — never as ~60s guaranteed.

### 3.2 Constraints on the on-chain order path

The on-chain path is real but blunter than the off-chain API:

- `_orderType` is `LimitOrder` or `MarketOrder` only. **No IOC, post-only, or reduce-only flag.**
  The source spec's "reduce-only flags on redeems" is therefore not available here; correctness
  must come from vault-side sizing plus `_baseAmount == 0` for full closes.
- `_price` is `uint32`, bounded by `MIN_ORDER_PRICE = 1` and `MAX_ORDER_PRICE = 2**32 - 1`, so
  price encoding depends on each market's `price_decimals`.
- `_marketIndex <= MAX_PERPS_MARKET_INDEX = 254`; `_baseAmount <= 2**48 - 1`.
- Per-asset config gates deposits and withdrawals: `tickSize`, `minDepositTicks`, `depositCapTicks`,
  `withdrawalsEnabled`. Deposits must be exact multiples of `tickSize`, and a global
  `depositCapTicks` can reject a deposit outright — a real liveness consideration for minting at
  scale.

### 3.3 Account bootstrap

`createOrder`, `withdraw` and friends revert with `AccountIsNotRegistered` until
`addressToAccountIndex[vault]` is populated, which happens when the rollup executes the
registering deposit. So each vault has a one-time bootstrap: deploy, deposit dust, wait for batch
execution, then trade. `CertFactory` sequences this and refuses to enable a vault until its account
index resolves.

### 3.4 Why the Public Pool was rejected

Revision 1 used a Lighter Public Pool as the execution container, because the Public Pool account
type structurally *"cannot transfer or withdraw the assets they hold, but can trade in the
markets."* That property is attractive, but the docs make pools unusable here:

- **Operators are whitelisted by the protocol.** *"Whitelisted users can create a Public Pool"* —
  pool creation is permissioned, so per-asset vaults would each need Lighter's approval. That is a
  business dependency in the middle of a deployment path.
- **Minimum operator share.** The operator must hold a minimum ownership percentage of the pool,
  which conflicts with the vault being the sole participant.
- **No isolated margin.** *"Public Pools do not support isolated positions."*

Since a contract can hold its own master account and trade directly, none of this is needed. The
vault gets Law 6 more cheaply: not "the trading account cannot withdraw," but "no separate trading
account exists at all."

---

## 4. Architecture

```
[User]  mint(collateral, asset) / redeem(uToken)
   |
   v
CertVault[asset]  — IS a registered Lighter master account          CertFactory
   |  - holds hot collateral buffer for instant settlement           deploys + bootstraps
   |  - mints/burns Certificate at CertOracle px +/- fee             one vault + one
   |  - submits its OWN hedge orders on-chain                       Certificate per asset
   |  - submits its own closes and withdrawals
   |  - BufferBook accrual; reads SolvencyRegistry
   |
   +--> ZkLighter.deposit(vault, assetIdx, Perps, amt)      ---> margin credited in-rollup
   +--> ZkLighter.createOrder(idx, mkt, amt, px, isAsk, typ) ---> position opened / closed
   +--> ZkLighter.withdraw(idx, assetIdx, Perps, amt)        ---> queued, then pull-payment
   |
   +--< state root + blobs (per batch, ~60s) ---------------- SolvencyRegistry proof input

No keeper trading key. No pool operator. The vault's own code is the only authority.
```

### 4.1 Why certificates are not pool shares

`uTSLA` is minted against **oracle price at delta 1.0**, not against pro-rata account NAV.

This is the entire difference between UseCert and Arcus. Arcus `pTokens` *are* pro-rata claims on a
perp account at fixed leverage, so their value tracks that account's NAV including its funding
history and execution quality. A share wrapper cannot satisfy Law 1. Vault-level delta-1.0
accounting can: the vault absorbs funding and execution variance into `BufferBook`, and the
certificate tracks the stock.

---

## 5. Contracts (Foundry)

Names match the front-end's architecture display, which is a hard constraint.

```solidity
// Certificate.sol — ERC-20 per asset (uTSLA, uNVDA, uSPX). mint/burn only by its vault.

// CertVault.sol — one per asset, factory-deployed. IS a Lighter master account.
//   mintInstant(amtIn)       : size <= instantCap. px = CertOracle.px(asset), guards applied.
//                              out = (amtIn - fee) / px. Mints Certificate, credits hot buffer,
//                              and submits its own ZkLighter.createOrder bid in the same tx.
//                              Reverts if the oracle is unhealthy, at capacity, or the accrual
//                              ledger is exhausted — minting may be gated (Law 3). C1 audit
//                              M-2: that gate is a cliff at zero, not the ramp Law 3 described.
//   requestMint(amtIn)       : size > instantCap. Escrows collateral, issues ERC-721 MintReceipt.
//   settleMint(receiptId)    : after the fill is proven, mints at the ACTUAL fill price.
//   redeemInstant(uIn)       : size <= instantCap. Burns, pays from hot buffer at px - fee.
//                              Never reads buffer health (Law 2).
//   requestRedeem(uIn)       : size > instantCap. Burns, submits createOrder ask + withdraw,
//                              issues RedeemReceipt.
//   claimRedeem(receiptId)   : pull-payment once the queued withdrawal lands.
//   forceExit(uIn)           : permissionless. Any holder can drive the full on-chain exit path
//                              without the operator. The Law 2 backstop.
//   closeAll()               : guarded wind-down. createOrder with _baseAmount == 0.
//   rebalance()              : permissionless with bounty. Trims delta into band; bounded notional.
//   solvency()               : view -> {supply, notional, margin, buffer, delta,
//                              provenAtBatch, ageSec, accrual}
//                              C1 audit M-1: `buffer` is collateral actually held (ERC20
//                              balance); `accrual` is BufferBook's attester-relayed P&L ledger.
//                              They were one field, and it was the ledger.

// CertOracle.sol — Chainlink per-asset feed primary; Lighter mark price as cross-check.
//   Guards: staleness, deviation vs last-good, feed-halt flag, Chainlink-vs-mark basis band.
//   Also encodes px into the uint32 tick domain per market price_decimals (Section 3.2).
//   Breach pauses MINTING only. Redemption follows the published last-good-px procedure.

// BufferBook.sol — per-asset funding + execution-variance + basis accrual: a cumulative P&L
//   ledger, NOT a collateral balance. Thresholds {floor, fee_on, mint_slow, insurance_draw},
//   configurable per asset via CertVault.setBufferThresholds and ordering-enforced.
//   C1 audit M-2: the holding fee is COMPUTED AND PUBLISHED BUT NOT CHARGED in C1, and
//   mint_slow tapers nothing. See Law 3.

// InsuranceStaking.sol — stake $CERT as junior tranche. Draw order immutable:
//   buffer -> staked $CERT -> (never) holder backing.

// SolvencyRegistry.sol — accepts and verifies per-batch backing attestations. See Section 8.

// FeeVault.sol — fee split 80/10/5/5: buyback / staker pay / treasury / ops.

// CERT.sol — governance and staking token. C3.

// CertFactory.sol — deploys {CertVault, Certificate}, runs the Section 3.3 bootstrap, refuses to
//   enable a vault until its Lighter account index resolves. Immutable fee bounds and draw order
//   set at deploy. Timelocked upgrades.
```

---

## 6. Mint flow

Two paths, split on size, because the risks differ.

**Instant (`size <= instantCap`)** — one transaction, hedge included:

1. Pull collateral. Read `CertOracle.px`, apply staleness / deviation / basis guards.
2. `out = (amtIn - fee) / px`. Mint `Certificate`.
3. `ZkLighter.deposit` margin (or draw on existing margin) and `ZkLighter.createOrder` a bid for
   `out`, **in the same transaction**. No off-chain actor is involved.
4. Fill lands in the next batch. Realised fill vs `px` accrues to `BufferBook` as execution
   variance, positive or negative.

The vault still carries mint-to-fill risk, because the fill is a batch later than the mint. But
nothing can *fail to submit* the hedge — that was the keeper risk in revision 1 and it is gone.

**Amended (C1 audit, M-2).** This paragraph used to end "`instantCap` is sized against the buffer
and drops as buffer health degrades (`mint_slow`)." **It does not.** `instantCap18` is immutable
deploy config with no setter; `BufferBook.mintSlowed()` is read by nothing outside its own unit
tests. In C1 the instant-cap threshold is a fixed size split and buffer health has exactly one
mechanical consequence anywhere in the mint path: capacity goes to zero once the accrual ledger is
exhausted, and new minting stops. A cliff, not the ramp this line promised. The taper is a C2 item
and Law 3 above records the same correction.

**Request/settle (`size > instantCap`)** — no execution risk:

1. Escrow collateral, issue `MintReceipt` (ERC-721).
2. Vault submits the order; the fill is proven against the batch attestation.
3. `settleMint` mints at the **actual fill price**, refunding unspent escrow.

This stops a large minter from taxing the buffer during a gap move.

---

## 7. Redeem flow

Law 2 is absolute, so redemption has three tiers and the last needs nobody's cooperation.

1. **Instant** (`size <= instantCap`): burn, pay from the hot buffer at oracle px minus fee. Does
   not read buffer health. Typical path, settles in one transaction.
2. **Queued** (`size > instantCap`): burn, vault submits `createOrder` ask plus `withdraw`, issues
   a `RedeemReceipt`, pays by pull-payment on arrival. Expected one batch.
3. **Force exit** (any size, permissionless): `forceExit` drives the same on-chain path with no
   privileged caller. If the sequencer censors, the 14-day `PRIORITY_EXPIRATION` elapses,
   `activateDesertMode()` freezes the rollup, and holders exit by proving ownership against posted
   blobs — positions settling at last mark price.

No tier consults buffer health. **The honest SLA is: one batch expected, 14 days worst case before
the Escape Hatch opens.** That worst case must be published, not buried.

---

## 8. Solvency: on-chain proof, per batch

The original spec's guarantee came from precompiles. Here it is reconstructed.

**What Lighter gives us:** the **Public Account Tree** holds each account's aggregated asset value,
position sizes, funding data and ownership info. It is merkleized with Poseidon2, its root is
committed on-chain and zk-verified each batch, and it is *"fully reconstructible solely from the
blob data posted"* by replaying **Account Delta Trees** from every batch.

**Design:**

- `solvency-prover` maintains a live reconstruction of the Public Account Tree from blob data and
  produces an inclusion proof for each vault's account leaf.
- `SolvencyRegistry.attest(asset, batchId, leaf, proof)` verifies the proof against the
  `ZkLighter` verified root for that batch and stores `{notional, margin}`.
- `CertVault.solvency()` returns backing from the last verified attestation, **always with
  `provenAtBatch` and `ageSec`**.
- Attestation is permissionless and verified, so a stale or lying operator cannot suppress it — a
  competitor can post the truth.

**Trust properties:** backing is *proven*, not asserted; the submitter is untrusted. What we lose
versus precompiles is only **freshness** — ~60s instead of per-block, with the age published rather
than hidden.

### 8.1 O-1 resolved: gas is not the constraint

Investigated 2026-09-07. Two findings changed the answer.

**Lighter does not verify Merkle paths on-chain.** `ZkLighter.performDesert` hashes the claim into
a single value and proves it inside a SNARK:

```solidity
bytes32 commitment = createExitCommitment(stateRoot, accountIndex, ..., totalBaseAmount);
inputs[0] = uint256(commitment) % BN254_MODULUS;
bool success = desertVerifier.Verify(proof, inputs);
```

`DesertVerifier` is a PLONK/BN254 verifier (KZG SRS + verifying-key constants), **not** a Poseidon
or Merkle verifier. There is no Merkle verification primitive anywhere in their contracts, so
nothing is directly reusable — but the *pattern* is proven and their verifier is already deployed.

**A Solidity implementation is cheap.** Exact parameters from
`elliottech/poseidon_crypto/hash/poseidon2_goldilocks`: Goldilocks field
(`p = 2^64 - 2^32 + 1`), `WIDTH = 12`, `RATE = 8`, `D = 7`, `ROUNDS_F = 8`, `ROUNDS_P = 22`, and
`HashTwoToOne` consumes 2 x 4 field elements — exactly `RATE`, so **one permutation per Merkle
node**. Per permutation: 118 S-boxes x 4 multiplications = 472 field multiplications, plus 22 x 12
for the internal linear layer.

Because operands are all below `2^64`, each Goldilocks multiplication is a single `MULMOD`
opcode at 8 gas — no 256-bit modular reduction needed. Estimated **400–650k gas for a depth-32
path**, which on an Orbit L2 is cents, once per batch per asset.

**These figures are analytical, not measured** (see O-1b). They are derived from round structure
and opcode costs, not from a Foundry benchmark.

### 8.2 Three routes, and the staged choice

| Route | On-chain cost | Engineering cost |
| --- | --- | --- |
| **A. Off-chain reconstruction, on-chain root as anchor** | zero | days — tooling only |
| **B. Poseidon2-Goldilocks path verified in Solidity** | ~400–650k gas | days–weeks, no circuit, no trusted setup |
| **C. Custom SNARK circuit + verifier** | ~250–350k gas, flat | weeks; circuit, prover service, deploy |

**C1 ships route A. C2 upgrades to route B. Route C is rejected** unless Lighter shares their
circuit — and note their circuit proves *asset balance in desert mode only*, never position
notional, so it could not serve solvency even if shared.

Route A is not a fudge: the Account Delta Tree blobs are posted on-chain, so any third party can
reconstruct the tree and check our numbers independently, today, with no new contracts. What it
does not provide is a contract that *refuses to operate* on bad backing — that arrives with route B.

**Front-end consequence, staged honestly:**

- C1: *"independently verifiable every batch (~60s)"* — with the reconstruction tool published.
- C2: *"proven on-chain every batch (~60s), age published."*

Never *"provable every block"* at any stage.

---

## 9. Collateral

Robinhood Chain's Lighter instance uses **USDG** as base collateral; the front-end and all source
documents say USDC. The contracts are asset-index generic (`deposit` takes `_assetIndex`, and
`USDC_ASSET_INDEX = 3` is only a named constant in the reference deployment's `Config.sol`), so
this is a deployment-mapping question, not a code question.

The multi-asset margin set (SPY, USO at 50% LTV) carries small per-user and global supply caps and
is **not** to be used — vaults post base collateral only.

**Resolution:** the vault is base-collateral-native. A thin `Zap.sol` at the edge accepts USDC and
swaps via Pleiades or Uniswap, with slippage bounds and a fail-closed path, so the "deposit USDC"
UX line survives while accounting, margin and solvency math use the base asset throughout. The zap
sits explicitly *outside* the solvency perimeter.

**Open item (O-2):** confirm the Robinhood Chain asset index and `tickSize` / `minDepositTicks` /
`depositCapTicks` for the base asset, and USDG/USDC pool depth. If depth is thin, the zap ships
disabled and the copy changes.

### 9.1 The margin split — how collateral is actually held

Added 2026-09-07 after implementation exposed a gap: revision 2 of this spec described the mint
path as "deposit margin and create the order", but never said how much margin, and the first
implementation posted none at all. It opened roughly $355k of notional against $1 of venue margin,
and every test passed because the mock did not enforce margin. Law 1 was unsatisfiable in code
while appearing satisfied in tests.

**The non-obvious part.** The vault is structurally hedged at *any* leverage. Because
`supply x px == position notional` at delta 1.0, a price move changes the position and the holder
claims by the same amount:

- price rises 10% -> position gains 10% of notional, claims rise 10% of notional, net zero
- price falls 10% -> position loses 10%, claims fall 10%, net zero

Leverage does not break the hedge. What leverage buys is **liquidation risk**, and liquidation is
the one failure that genuinely breaks the product: once the position is force-closed the vault
holds cash with no hedge, and a subsequent price recovery impairs holders.

| Margin posted | Leverage | Adverse move to liquidation (3% MMR) |
| --- | --- | --- |
| 100% of notional | 1x | ~-97%, essentially impossible |
| 50% (Lighter's default IMF) | 2x | ~-47% |
| 20% | 5x | ~-17%, an earnings gap reaches this |

On a $1-3M book (Section 15.1) an earnings gap is a real event, so the target is ~1x.

**The decision.** Collateral is split at mint:

- `targetMarginBps` of net collateral is deposited to Lighter as margin. Default **9000** (90%),
  giving ~1.1x leverage, so liquidation needs an ~-88% move.
- The retained remainder is the **hot buffer** — the float that serves instant redemptions.
- Bounds are **contract constants**, not configuration: `MIN_TARGET_MARGIN_BPS = 5000` and
  `MAX_TARGET_MARGIN_BPS = 10000`, checked in the constructor, with **no setter**. No deployment can
  produce a vault levered beyond 2x and governance cannot re-lever one afterwards.
- `redeemInstant` is a convenience fast path: when the hot buffer cannot cover a payout it reverts
  `CertVault_UseQueuedRedeem` and the holder uses the queued path. **This is not a Law 2 exception** —
  `requestRedeem`, `forceExit` and `claimRedeem` stay unconditionally open and read no buffer
  health, no capacity, no `mintAllowed`, and never `px()`.
- Rebalancing margin against hot buffer is a permissionless `rebalance()` responsibility. No new
  trusted actor.

**Verified before committing to this** (2026-09-07, against `elliottech/lighter-contracts` @
`75c2a73`): `defaultInitialMarginFraction` and `minInitialMarginFraction` are *market-level*
parameters in `TxTypes.UpdateMarketPerps`. There is no per-account leverage setter and no
update-leverage transaction type. IMF is a floor on *required* margin, never a ceiling on *posted*
margin — so an over-margined ~1x position is expressible and nothing sweeps the excess.

**Rejected alternative:** post only Lighter's required margin (~50% IMF) and keep the rest local.
That keeps instant-redeem capacity generous but runs the venue position at ~2x, trading the
product's one credible claim — verifiable solvency — for redemption convenience on a book thin
enough that a gap is plausible.

**Test discipline this taught us.** `MockLighter` now enforces margin in `settleBatch()` and
reverts `InsufficientMargin()`. When that enforcement landed, **9 existing tests reverted** — which
is the proof the gap was real. Any future venue behaviour the vault depends on must be modelled in
the mock, or the suite will keep certifying designs the venue would reject.

---

## 10. Oracle and basis risk

Two prices exist and they are not the same number:

- **Chainlink per-asset feed** — what mints and redeems price against, and what "oracle price"
  means to a holder.
- **Lighter mark price** — what the hedge actually fills and gets funded against.

Their spread is a real, unhedged risk the source documents never name, because on Hyperliquid both
came from Core. Handling:

- `CertOracle` publishes both plus the live basis.
- Basis beyond a published band pauses minting; redemption continues on the last-good procedure.
- Realised basis accrues to `BufferBook` alongside funding.
- Band and history go on the public dashboard, and the risk is named in Honest Boundaries.

---

## 11. Off-chain services

Studio conventions: Bun, Hono, tRPC v11, Drizzle on Postgres + Timescale, Redis + BullMQ, viem.

Note what is **not** here: no service holds authority to trade or move funds. Every worker either
reads, or calls a permissionless function anyone else could call.

| Worker | Job |
| --- | --- |
| `delta-keeper` | Band check per batch window; calls permissionless `rebalance()`. Bounty-paid, so third parties can replace it |
| `funding-sweeper` | Accrues funding and realised basis into `BufferBook`, hourly |
| `solvency-prover` | Reconstructs Public Account Tree from blobs; submits permissionless attestations per batch |
| `buffer-watchdog` | Threshold transitions, fee activation, `instantCap` adjustment |
| `fill-reporter` | Proves fills for `settleMint`; permissionless |
| `chain-indexer` | Flows, receipts, events, priority-request lifecycle |

### 11.1 Optional latency path

On-chain `createOrder` costs a batch of latency and cannot express IOC or post-only. For
rebalancing only, the vault may register an off-chain API key via `changePubKey` and let a bot
place cheaper, faster orders. This is strictly optional and constrained:

- The on-chain path always remains available and can `cancelAllOrders`.
- The key must not be able to withdraw (**O-8**). If that cannot be guaranteed, this path is
  dropped rather than compromise Law 6.
- C1 ships **without** it. It is a C2 optimisation at most.

tRPC surface, driven by what the front-end already renders:

```
vaultRouter.list()                    -> vaults, status, phase
vaultRouter.solvency(asset)           -> backing + provenAtBatch + ageSec
vaultRouter.quoteMint(asset, amt)     -> out, fee, px, path: instant|request
vaultRouter.quoteRedeem(asset, uAmt)  -> amt, fee, px, path, eta, worstCase
bufferRouter.state(asset)             -> buffer, thresholds, feeRate, basis
receiptRouter.byWallet(wallet)        -> open mint/redeem receipts
stakeRouter.*                         -> C3
statsRouter.history(asset, range)     -> Timescale series
```

---

## 12. Data model (Drizzle)

```
vaults     /* asset, vaultAddr, certificate, lighterAccountIndex, marketIndex, status,
              instantCap, bootstrapped */
solvency   /* asset, batchId, ts, supply, notional, margin, buffer, delta, proofOk */  // Timescale
funding    /* asset, ts, fundingRate, basis, accrued, bufferAfter */                   // Timescale
flows      /* asset, kind mint|redeem, path instant|request|force, user, amtIn, uAmount,
              px, fillPx, fee, txHash, ts */
receipts   /* id, asset, kind, user, escrow, status, priorityReqId, enqueuedAt,
              expiresAt, settledBatch */
stakes     /* wallet, amount, since, rewardsAccrued */
```

`receipts.expiresAt` carries the 14-day priority expiration so the UI can show a real worst case.

---

## 13. Security and failure modes

| Failure | Response |
| --- | --- |
| Operator infrastructure compromised | No trading or withdrawal authority exists off-chain (Law 6). Worst case is griefing permissionless calls others can also make |
| Off-chain services all offline | Instant mint/redeem keep working — they are self-contained on-chain transactions. Delta drifts until someone claims the `rebalance()` bounty; `forceExit` keeps redemption open |
| Oracle stale or deviant | Minting pauses. Redemption uses published last-good procedure. Never trapped |
| Chainlink-vs-mark basis blowout | Minting pauses; realised basis to buffer; band published |
| `depositCapTicks` reached on the base asset | Minting pauses with a clear reason; redemption unaffected |
| Sequencer censors priority requests | 14-day `PRIORITY_EXPIRATION`, then `activateDesertMode()` freezes the rollup |
| Desert mode / Escape Hatch active | Positions settle at last mark. Vault proves ownership against blobs via `DesertVerifier`, withdraws, pays holders pro-rata. Procedure published in advance |
| Market delisted or halted | Per-asset wind-down: minting off, `closeAll()`, redemption continues against margin |
| Buffer exhausted | **C1 as shipped:** new minting stops (capacity goes to zero); every redemption path stays open (Law 2); the holding fee is published but not charged and `insurance_draw` is a published number with no consumer until C3. **C2/C3:** holding fee active and capped, then `insurance_draw` burns staked `$CERT`. Holder backing untouched either way (Law 4) |

Additional: fee bounds and draw order immutable at deploy; timelocked upgrades; fresh deployer plus
multisig per studio OPSEC; invariant tests asserting `backing >= supply x px` across
mint/redeem/rebalance/funding fuzz, and that redemption never reverts on buffer state.

---

## 14. Testing and acceptance

Foundry unit and invariant tests, plus integration against **Robinhood Chain testnet Lighter** —
not mocks — before mainnet.

1. Bootstrap: deploy, register via deposit, account index resolves, vault enables.
2. Instant mint: certificate minted and `createOrder` enqueued in one tx; fill lands next batch;
   attestation holds.
3. Request mint: settles at actual fill price; vault absorbs no execution variance.
4. Redeem with buffer at zero and funding deeply negative: **still succeeds**.
5. `forceExit` with every off-chain service dead: holder exits unaided.
6. Priority expiration fixture: request unprocessed past 14 days, Desert mode activates, holders
   made whole via `DesertVerifier` path.
7. Funding: positive fattens the ledger; negative crosses `fee_on` and the published holding-fee
   rate activates, `rate <= cap`. **C1 audit M-2: acceptance is that the RATE and the threshold
   signals move — no fee is charged in C1, and the mint that follows a threshold crossing is
   asserted to be identical to the one before it
   (`test_crossingTheThresholdsChangesTheSignalsAndNotTheMint`).**
8. Insurance draw consumes staked `$CERT` before holder backing.
9. Oracle stale: minting paused, redemption follows last-good path.
10. Basis breach: minting paused, redemption unaffected.
11. Price encoding: `uint32` tick conversion correct at market bounds; rejects out-of-range.
12. Deposit tick/cap edges: non-multiple of `tickSize` rejected cleanly; cap breach pauses mint only.
13. Solvency attestation: valid proof accepted, forged proof rejected, stale surfaces correct `ageSec`.
14. Delta fuzz across gap moves stays in band post-rebalance.
15. `closeAll()` with `_baseAmount == 0` fully closes regardless of size.

---

## 15. Build order

- **C1** — `CertFactory`, `CertVault`, `Certificate`, `CertOracle`, `BufferBook`,
  `CapacityOracle`, `SolvencyRegistry` (route A), `Zap`; `uTSLA` and `uNVDA`; delta-keeper,
  solvency-prover, fill-reporter; published reconstruction tool; public dashboard showing solvency
  **and capacity**. No off-chain trading key. A capped pilot, honestly labelled.
- **C2** — capacity expansion: route B on-chain proofs, perpRFQ whitelisting (O-11) for size,
  `uSPX` / `uQQQ`, DEX seeding on Pleiades and Uniswap, lending integrations; optionally the
  Section 11.1 latency path if and only if O-8 resolves cleanly.
- **C3** — `CERT.sol` genesis, `InsuranceStaking`, funding-surplus flywheel.
- **C4** — Structured wrappers (DCA vault, covered-call-style vaults) on the certificate base.

**Kill/persist:** unchanged. If mint TVL misses threshold by day 30, the vault engine persists as
internal infrastructure and marketing rotates.

---

## 15.1 Capacity model — built to grow

Live market data, 2026-09-07 (Lighter `api/v1/orderBookDetails`):

| Market | `market_id` | Open interest | Daily volume | Mark vs index |
| --- | --- | --- | --- | --- |
| TSLA | 16 | ~3,353 sh (~$1.19M) | $1.81M | 0.8 bps |
| NVDA | 15 | ~12,389 sh (~$2.88M) | $2.09M | 7 bps |

Both markets: `price_decimals` 2, `size_decimals` 4, min order 0.02 / 0.04, min notional $10,
`order_quote_limit` $25M, **maker and taker fee 0.0000**, `force_reduce_only` false, RFQ enabled.
Margin fractions (of `ASSET_MARGIN_TICK = 10_000`): default IMR 5000, min IMR 500, MMR 300, CMR 200.

**These books are thin.** A vault of any size becomes a dominant share of open interest, which
moves the price it is hedging into and distorts the funding it depends on. But the market is
expected to grow, so **capacity is a formula, not a constant** — no redeploy, no migration, no
hardcoded ceiling.

### 15.1.1 The formula

Per asset, the vault's own position notional is capped at:

```
maxNotional(asset) = min(
    depthBps    * openInterest(asset),   // scales automatically with the market
    absoluteCap(asset),                  // governance ceiling, immutable bounds
    bufferCapacity(asset)                // what the vault's OWN CAPITAL can actually absorb
)
```

**Amended (C1 audit, M-1) — what the third leg is.** It was `BufferBook.capacity18()`, the accrual
ledger times 100, which put an unbacked and attester-writable number into admission control *in
the direction that widens it*: two of the three legs were then attester-written and only the
immutable `absoluteCap` was a real bound. It is now

```
bufferCapacity(asset) = min(
    freeCollateral18() * 100,   // collateral the vault HOLDS, less what it owes queued receipts
    BufferBook.capacity18()     // the accrual ledger's own claim — one-way, tightening only
)
```

The first term is ground truth (an ERC20 balance and the vault's own obligation counter), it cannot
drift because it is derived rather than accrued, and no attester can move it. The second is kept
deliberately, and only under the `min`: an attester can still make the vault *more* conservative —
and an exhausted ledger still stops new minting, which is the honest half of the old behaviour —
but can no longer admit a mint that real collateral does not support. `100` is the unchanged
coverage multiple (a 1% adverse move on the whole book).

- `openInterest` comes from the same per-batch attestation that feeds `SolvencyRegistry`, so it is
  proven, not self-reported, and cannot be gamed by the operator.
- `depthBps` starts deliberately low (target: vault ≤ 10% of open interest) and is governance-
  adjustable **within immutable min/max bounds set at deploy**. Governance can never remove the cap.
- `mintInstant` and `requestMint` both revert once `maxNotional` is reached, with a distinct error
  so the UI can say *"at capacity"* rather than *"failed"*. Redemption is never capped (Law 2).
- `instantCap` (the instant-settlement size threshold) is **immutable deploy config in C1** and is
  not derived from buffer health — see the amendment in Section 6.

### 15.1.2 Why this is the right shape

As open interest grows from $1M to $100M, capacity grows with it automatically. Nothing needs
redeploying and no parameter needs a human in the loop for the common case. The failure mode is
"minting pauses at capacity," never "vault is under-hedged."

Two consequences to accept openly:

- **C1 is a capped pilot.** At 10% of a $1.19M TSLA book, that is roughly $120k of `uTSLA`. The
  launch plan and the marketing must say so; a solvency dashboard showing a $120k vault while the
  copy claims the deepest book on-chain is worse than saying nothing.
- **perpRFQ is the size valve.** `rfq_enabled` is true on both markets and market makers quote
  large blocks, which is how large mints get filled without walking the book. It requires address
  whitelisting, so it is a C2 item — and it is the main reason capacity can rise faster than
  visible order-book depth.

### 15.1.3 Published, not buried

`maxNotional`, current utilisation, `depthBps`, and live open interest all go on the public
dashboard next to the solvency figure. Capacity is a fact about the market, not an embarrassment,
and publishing it is the same discipline as publishing the buffer.

---

## 16. Verification items

Resolved 2026-09-07 against `elliottech/lighter-contracts` @ `75c2a73` and current docs:

- **O-3 RESOLVED.** Priority-request interface pinned (Section 3.1). No protocol fee, gas only;
  `PRIORITY_EXPIRATION = 14 days`; pubdata capped at 100 bytes; both order directions permitted;
  order types limited to Limit/Market with no reduce-only or IOC flag.
- **O-4 RESOLVED, POSITIVE.** A contract can hold a Lighter master account, place orders both
  directions, withdraw, and register API keys. No EOA restriction exists. The Public Pool — and its
  whitelist gate, minimum operator share, and lack of isolated margin — is not needed (Section 3.4).
- **O-5 MOSTLY RESOLVED.** Live RWA perp markets include TSLA, NVDA, SPY, QQQ, AAPL, AMZN, MSFT,
  GOOGL, META, HOOD, PLTR, COIN, MSTR, AMD, INTC, MU, MRVL, CRCL, SNDK. Both C1 assets exist.
  Still to confirm per asset: market index, tick and price decimals, leverage cap, funding interval,
  corporate-action handling.

- **O-1 RESOLVED.** Gas is not the constraint. See 8.1/8.2: route A for C1, route B for C2, route C
  rejected. No longer blocks Solidity.
- **O-5 COMPLETE for C1 assets.** TSLA `market_id` 16, NVDA `market_id` 15, both active, decimals
  and margin fractions recorded in 15.1. Zero maker and taker fees.
- **O-9 PARTLY RESOLVED.** Trading fees are 0.0000 maker and taker. Standard accounts have 300ms
  taker latency; Premium is opt-in and only relevant for HFT. **Public RPC
  (`https://rpc.mainnet.chain.robinhood.com`, chain ID 4663) rate-limits aggressively — 429 on the
  second consecutive call — so every worker needs a paid endpoint (Alchemy) from day one.**
- **O-10 PARTLY RESOLVED.** Live `ZkLighter` on Robinhood Chain is
  `0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d`, retrieved from `https://api.rh.lighter.xyz/info`.
  Byte-for-byte comparison against `75c2a73` still pending — a build task needing Foundry and exact
  compiler settings.

Still open. None now block starting Solidity; each blocks a specific deliverable:

- **O-1b** Replace the analytical gas estimate in 8.1 with a Foundry measurement. Blocks the C2
  route-B commitment, not C1.
- **O-2** Robinhood Chain base-asset index for USDG plus `tickSize` / `minDepositTicks` /
  `depositCapTicks`, and USDG/USDC pool depth. The asset endpoints are 403-gated, so read these
  from the live contract. Blocks `Zap.sol` and deposit sizing.
- **O-6** Blob retention and availability window; whether an independent archive is needed for tree
  reconstruction. Blocks route A's durability claim.
- **O-7** Buffer floor and thresholds, and the initial `depthBps`, fitted to historical funding,
  basis and open-interest data. Blocks mainnet parameters, not testnet.
- **O-8** Whether an API key can be scoped to trading without withdrawal rights. Gates Section 11.1
  only; C1 does not depend on it.
- **O-11** perpRFQ whitelisting: eligibility, process, and whether a contract address can be
  whitelisted. Gates the C2 capacity valve in 15.1.2.
- **O-12** Live open-interest source for the capacity formula — confirm it can be proven per batch
  from blob data rather than trusted from the API. If it cannot, `depthBps` must be governed
  conservatively instead.

---

## 17. Required copy changes

The backend cannot ship truthfully behind the current front-end. These are blocking:

1. `"provable on chain every block"` / `"solvency public every block"` becomes `"proven on-chain
   every batch (~60s), age published"`.
2. `"NO CUSTODIAL STOCK TOKEN EXISTS ON ROBINHOOD CHAIN"` — remove.
3. `"THE FIRST HOLDABLE STOCK TOKENS"` — remove. It is false on this chain.
4. `$213B` / `32.2%` / `RWA OI passing Bitcoin` / `23 of top 30` — remove or re-source. Hyperliquid
   figures.
5. `"Deposit USDC"` — acceptable only while the zap is live; Honest Boundaries must state that
   backing margin is the venue's base asset.
6. `"REDEMPTION: Always, at oracle price"` — must carry the real SLA: one batch expected, 14 days
   worst case, then Escape Hatch.
7. Add to Honest Boundaries: Chainlink-vs-mark **basis risk**, **Lighter dependency** (single venue,
   sequencer, Desert-mode semantics), and **~60s solvency latency**.
8. `"C1 LIVE"` — not live until C1 ships.

---

## 18. Sources

Verified 2026-09-07.

- Lighter contract source — `elliottech/lighter-contracts` @ `75c2a73a5c25c9a6a36b66ba73aaf71267232b42`
  (`ZkLighter.sol`, `AdditionalZkLighter.sol`, `Config.sol`, `Storage.sol`, `lib/TxTypes.sol`)
- Lighter whitepaper (state tree, priority transactions, account types, Escape Hatch) —
  <https://assets.lighter.xyz/whitepaper.pdf>
- Lighter docs, incl. Public Pools and market list — <https://docs.lighter.xyz/llms-full.txt>
- Robinhood Chain mainnet, Arbitrum Orbit — <https://blog.arbitrum.io/robinhood-chain-mainnet/>
- Robinhood Stock Tokens docs — <https://docs.robinhood.com/chain/stock-tokens/>
- Stock tokens in DeFi (~$12M) — <https://cryptobriefing.com/robinhood-chain-stock-tokens-defi-deposits/>
- Arcus pTokens —
  <https://www.theblock.co/news/defi/2026-08-25-robinhood-chain-dex-arcus-ptokens-perps-erc-20s-412696>
- Perpetra — <https://www.perpetradex.com/>
