# UseCert: non-custodial synthetic equity certificates on Robinhood Chain

**Version 1.0 — 2026-09-08**

Covers the C1 protocol as implemented on branch `feat/contracts-c1`.
Companion document: [HOW-IT-WORKS.md](HOW-IT-WORKS.md) — the same material without the mathematics.
Normative deployment constraints: [DEPLOYMENT-CHECKLIST.md](DEPLOYMENT-CHECKLIST.md).

---

## Abstract

UseCert issues transferable ERC-20 certificates that track individual equity prices, backed by
perpetual-futures positions the issuing contract opens and manages itself. Each certificate is
minted at oracle price against a hedge of identical notional, so the protocol holds no directional
exposure and each certificate's backing is a published, per-batch-verifiable quantity rather than an
issuer's promise.

The design differs from custodial stock tokens in that no entity holds the underlying and no
entity's balance sheet stands behind the token; it differs from perp-account share wrappers in that
certificates are minted at delta 1.0 against oracle price rather than as pro-rata claims on an
account's net asset value, so a certificate tracks the equity rather than the trading history of the
account hedging it.

The protocol has no owner, no keeper key with trading or withdrawal authority, no pause switch and
no upgrade path. The redemption path is permissionless code that reads no health signal, no capacity
limit and no governance state, and terminates in the host rollup's own escape hatch.

This paper states the design laws the implementation is held to, derives the two constraints the
venue imposes that shape the whole architecture, specifies the issuance, collateral, redemption,
solvency and capacity mechanisms, and gives a complete account of the security review history —
including eight Critical-severity defects found and closed (two external, six internal), and the
three structural reasons a passing test suite could not see several of them.

---

## Contents

1. [Positioning](#1-positioning)
2. [Design laws](#2-design-laws)
3. [Notation](#3-notation)
4. [The venue](#4-the-venue)
5. [Architecture](#5-architecture)
6. [Issuance](#6-issuance)
7. [Collateral and margin policy](#7-collateral-and-margin-policy)
8. [Redemption](#8-redemption)
9. [Solvency and verification](#9-solvency-and-verification)
10. [Capacity](#10-capacity)
11. [Economics](#11-economics)
12. [Trust and threat model](#12-trust-and-threat-model)
13. [Security review history](#13-security-review-history)
14. [Limitations and open problems](#14-limitations-and-open-problems)
15. [Roadmap](#15-roadmap)
16. [References](#16-references)

---

## 1. Positioning

### 1.1 The market as it actually is

Robinhood Chain is an Arbitrum Orbit L2 (chain ID 4663) that reached mainnet on 2026-07-01. Two
classes of equity-linked instrument already exist on it:

- **Robinhood Stock Tokens** — plain ERC-20s with per-asset Chainlink feeds, tradeable on Uniswap
  and Pleiades, with roughly $12M already deposited into DeFi protocols.
- **Arcus `pTokens`** (from 2026-08-25) — perp accounts wrapped as transferable ERC-20s at fixed
  leverage, including equity names.

Claims that no holdable stock token exists on this chain, or that UseCert would be the first, are
therefore false and are not made here. Several such claims appear in the project's earlier source
documents and on the current front-end; §14.4 lists them as blocking copy corrections.

### 1.2 The gap that does exist

Robinhood Stock Tokens are, in substance, **debt securities issued by Robinhood Assets (Jersey)
Limited**. The holder's position is a claim on an issuer that holds the shares. Three consequences
follow: the holder bears issuer credit risk, the instrument is unavailable to US persons and to
holders in a range of other jurisdictions, and the backing is only as verifiable as the issuer
chooses to make it.

Arcus `pTokens` remove the custodian but change the instrument. A pro-rata claim on a perp account
is valued at that account's NAV, which embeds the account's funding history, its execution quality
and its leverage. It tracks the account, not the equity.

UseCert's claim is therefore narrow and, we believe, defensible:

> **Equity price exposure with no custodian, no issuer credit risk, and no geographic gate —
> fully synthetic, backed by on-chain perpetual positions and margin that any third party can
> verify from public chain data.**

### 1.3 Why the instrument requires vault-level accounting

The distinction from a share wrapper is the design's central mechanical choice. A wrapper cannot
satisfy a delta-1.0 backing law, because its unit of account *is* the hedging account's NAV: funding
paid, slippage suffered and basis realised all flow directly into the token's value.

UseCert mints against oracle price at delta 1.0 and absorbs funding, execution variance and realised
basis into a separate, published ledger at the vault level. The certificate tracks the equity; the
vault carries the frictions and publishes them. This is strictly more work and strictly more
honest, and it is why §11 exists as a section.

---

## 2. Design laws

Six laws. Every mechanism in this paper exists to satisfy one of them, and the security review
history in §13 is largely a record of places where the code did not.

**Law 1 — Every certificate is fully delta-backed.**
Per asset, the vault targets delta 1.0. Provable **per venue batch (~60s)**, not per block, and
every published solvency figure carries its own age.

**Law 2 — Redemption is never gated.**
Burn implies closed exposure implies collateral at oracle price. Enforced by on-chain order and
withdrawal requests that *the vault contract itself* submits, with the venue's 14-day priority
expiration as the censorship backstop and the rollup's escape hatch beyond it. **No redemption path
reads buffer health, capacity, mint permission, or any governance state.**

**Law 3 — Funding is buffered, then fee'd, never hidden.**
Positive funding fattens a buffer; negative funding draws it down; past a published threshold it
passes through as a published, capped holding fee. All parameters and the live buffer on-chain.
*As implemented in C1 this is a cliff, not a ramp, and the buffer and the ledger are two separate
published fields — see §11.2 and §11.3, both of which are corrections forced by the audit.*

**Law 4 — Holders are senior.**
Staked `$CERT` absorbs buffer exhaustion before holder backing is touched. The draw order is
immutable. *The junior tranche ships in C3; in C1 the threshold is a published number with no
consumer.*

**Law 5 — Mirror the underlying market honestly.**
Corporate actions and pricing follow the venue's market specification. Certificates never claim
custody, dividends, or shareholder rights.

**Law 6 — No privileged trading key exists.**
The hedge is placed by the vault contract's own code. There is no keeper key with authority to trade
or to withdraw, so there is nothing to compromise. Every off-chain worker either reads chain data or
calls a function any third party could call instead.

An explicitly **dropped** law from the project's earlier Hyperliquid-targeted design: *"precompile
reads are the single source of truth; no off-chain accounting is load-bearing."* Position state on
this venue lives inside a rollup and is not readable on-chain at all (§4.2). It is replaced by the
proof system of §9.

---

## 3. Notation

| Symbol | Meaning |
| --- | --- |
| $q$ | Certificates outstanding for an asset |
| $P$ | Current price; $P_0$ the price at mint |
| $N$ | Perp position notional at the venue |
| $M$ | Margin posted at the venue |
| $B$ | Hot buffer — collateral held by the vault, not at the venue |
| $\tau$ | `targetMarginBps` / 10 000 — the fraction of net collateral posted as margin (default 0.90) |
| $\phi$ | Fee rate (`mintFeeBps` or `redeemFeeBps` / 10 000; both 0.001 in the reference configuration) |
| $\mu$ | Initial margin fraction required by the venue for the market (0.50 on both C1 markets) |
| $m$ | Maintenance margin fraction (0.03) |
| $s$ | Redeemed share of supply, $s \in (0, 1]$ |

All on-chain quantities are held in 18-decimal fixed point internally and converted at the
collateral token's own decimals at the boundary.

---

## 4. The venue

Lighter is the only perpetuals venue on Robinhood Chain; Perpetra routes order flow to it and
therefore inherits every constraint below. Uniswap and Pleiades are spot-only.

Lighter is a **zk-rollup settling to Robinhood Chain**. Matching, positions, funding and liquidations
execute inside its circuits. On Robinhood Chain sits the `ZkLighter` contract
(`0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d`), which custodies deposits, holds the canonical state
root, maintains the priority-request queue, and records the `commit → verify → execute` batch
lifecycle at approximately one batch per minute.

All venue facts in this section were verified against `elliottech/lighter-contracts` @ `75c2a73` on
2026-09-07.

### 4.1 What a contract can do

Every operation below is `external` on `ZkLighter` (delegating to `AdditionalZkLighter`) and derives
the acting account from `msg.sender`. **No function restricts callers to EOAs**; the only `_hasCode`
check asserts that *system* addresses are contracts.

| Operation | Contract-callable | Entry point |
| --- | --- | --- |
| Deposit collateral, registering the account | Yes | `deposit(_to, _assetIndex, RouteType, _amount)` |
| Open or increase a position | Yes | `createOrder(_accountIndex, _marketIndex, _baseAmount, _price, _isAsk, _orderType)` — `_isAsk` may be 0 or 1 |
| Close or reduce a position | Yes | the same `createOrder` |
| Withdraw collateral | Yes | `withdraw(_accountIndex, _assetIndex, RouteType, _baseAmount)` |
| Cancel all orders | Yes | `cancelAllOrders(_accountIndex)` |
| Register an off-chain API key | Yes | `changePubKey(...)` |
| **Read live position, margin or funding** | **No** | in-rollup state; the chain sees roots and blobs only |

This last row is load-bearing for the entire design and recurs throughout §8, §9 and §14.

Each operation enqueues a priority request, which charges **no protocol fee** (gas only), stamps
`expirationTimestamp = block.timestamp + PRIORITY_EXPIRATION` with `PRIORITY_EXPIRATION = 14 days`,
and caps pubdata at 100 bytes.

**The 14 days is a censorship deadline, not expected latency.** Normal processing is one batch. If
the sequencer fails to process a request within 14 days, `activateDesertMode()` freezes the rollup
and holders exit by proving ownership against posted blobs. Redemption SLAs must therefore be quoted
as *"~1 batch expected, 14 days worst case, then the escape hatch"* and never as a guaranteed 60
seconds.

An earlier revision of this design used an off-chain keeper with a trading key, because Lighter's
*documentation* implied a contract could not open a position. The contract source disproved it. The
resulting architecture is materially simpler and satisfies Law 6 structurally rather than
operationally.

### 4.2 Constraints on the on-chain order path

- `_orderType` is `LimitOrder` or `MarketOrder` only. **No IOC, post-only, or reduce-only flag.**
  Correctness must come from vault-side sizing.
- `_baseAmount == 0` means "the full position **size**" and leaves `_isAsk` to the caller. It is
  **not** a "go flat" primitive: a zero-amount ASK against a short is a full-size sell and *doubles*
  the position. §13.2 records the defect this caused.
- `_price` is `uint32`, bounded by 1 and $2^{32}-1$, so price encoding depends on each market's
  `price_decimals`. At `price_decimals = 2` the representable domain is roughly \$0.01 to \$42.9M.
- `_marketIndex ≤ 254`; `_baseAmount ≤ 2^{48}-1`.
- Per-asset config gates deposits and withdrawals via `tickSize`, `minDepositTicks`,
  `depositCapTicks` and `withdrawalsEnabled`. A global deposit cap can reject a deposit outright —
  a real liveness consideration for minting at scale.

### 4.3 Two facts that shaped the architecture

**Fact A — `withdraw` performs no balance check.** It validates `withdrawalsEnabled`,
`_baseAmount != 0`, `_baseAmount ≤ depositCapTicks` and the route type, then enqueues. An
insufficient request is rejected **inside the rollup, with no on-chain signal and no rollback**. So
a `try/catch` around the call catches nothing meaningful: the call succeeds and the cash simply never
arrives. `getPendingBalance` — already released funds — is the only on-chain evidence a withdrawal
executed.

**Fact B — the vault inherits the market's margin fraction.** `defaultInitialMarginFraction` and
`minInitialMarginFraction` are *market-level* parameters. There is no per-account leverage setter and
no update-leverage transaction type anywhere in the contract set. The IMF is a floor on *required*
margin, never a ceiling on *posted* margin, so an over-margined position is expressible and nothing
sweeps the excess — but the requirement itself cannot be lowered.

### 4.4 Market data

Live, 2026-09-07 (`api/v1/orderBookDetails`):

| Market | `market_id` | Open interest | Daily volume | Mark vs index | Fees |
| --- | --- | --- | --- | --- | --- |
| TSLA | 16 | ~3,353 sh (~\$1.19M) | \$1.81M | 0.8 bps | **0 / 0** |
| NVDA | 15 | ~12,389 sh (~\$2.88M) | \$2.09M | 7 bps | **0 / 0** |

Both markets: `price_decimals` 2, `size_decimals` 4, minimum notional \$10, `order_quote_limit`
\$25M, `force_reduce_only` false, RFQ enabled. Margin fractions, of `ASSET_MARGIN_TICK = 10 000`:
default IMR 5000, minimum IMR 500, MMR 300, CMR 200.

Base collateral on this instance is **USDG**, not USDC. The contracts are asset-index generic, so
this is a deployment mapping rather than a code question; a thin `Zap` at the edge accepts USDC and
swaps, sitting explicitly outside the solvency perimeter.

---

## 5. Architecture

```
[User]  mint(collateral) / redeem(certificate)
   |
   v
CertVault[asset]  — IS a registered Lighter master account           CertFactory
   |  · holds the hot collateral buffer                               registry of the
   |  · mints/burns Certificate at CertOracle px ± fee                 deployment's vaults
   |  · submits its OWN hedge orders on-chain                          (it cannot deploy
   |  · submits its own closes and withdrawals                          them — §13.3)
   |  · accrues to BufferBook; reads SolvencyRegistry
   |
   +--> ZkLighter.deposit(...)     → margin credited in-rollup
   +--> ZkLighter.createOrder(...) → position opened / closed
   +--> ZkLighter.withdraw(...)    → queued, then pull-payment
   |
   +--< state root + blobs, per batch (~60s) → SolvencyRegistry proof input

No keeper trading key. No pool operator. The vault's own code is the only authority.
```

| Contract | Runtime | Role |
| --- | --- | --- |
| `CertVault` | 17,559 B | Issuance, redemption, margin policy, venue interaction. One per asset |
| `Certificate` | 2,196 B | The ERC-20. Mint and burn restricted to its vault |
| `CertOracle` | 4,420 B | Price, with staleness / deviation / basis / feed-sanity guards, and tick encoding |
| `SolvencyRegistry` | 1,732 B | Per-batch attestations of `{notional, margin, openInterest}` |
| `CapacityOracle` | 2,033 B | Admission control as a formula (§10) |
| `BufferBook` | 2,192 B | Cumulative P&L ledger and published thresholds |
| `CertFactory` | 2,323 B | Registry of `{vault, certificate}` pairs |

Deferred to later phases: `InsuranceStaking` and `CERT` (C3), `FeeVault` (fee split 80/10/5/5:
buyback / staker pay / treasury / ops).

### 5.1 Why not a pool wrapper

Lighter's Public Pool account type structurally cannot withdraw the assets it holds, only trade —
an attractive property. It was rejected because pool creation is **whitelisted by the protocol**,
the operator must hold a **minimum ownership share**, and pools **do not support isolated margin**.
Since a contract can hold its own master account, Law 6 is obtained more cheaply: not "the trading
account cannot withdraw", but *no separate trading account exists*.

---

## 6. Issuance

Two paths, split on a size threshold (`instantCap`), because the risk each carries is different.

### 6.1 Instant path

For $A \le$ `instantCap`, in a single transaction:

$$
q_{\text{out}} = \frac{A(1-\phi)}{P}, \qquad
M \mathrel{+}= \tau A (1-\phi), \qquad
B \mathrel{+}= (1-\tau) A (1-\phi)
$$

and the vault submits its own bid for $q_{\text{out}}$ at the encoded tick price, **in the same
transaction**. Nothing can fail to submit the hedge; if the order cannot be placed, the mint reverts
atomically and the user's collateral is untouched.

Four gates precede all of it, any of which stops the mint: oracle health, capacity (§10), a
non-exhausted accrual ledger, and a non-zero certificate amount after fees and venue quantisation.

The residual risk is **mint-to-fill**: the fill lands one batch later, so the realised price differs
from $P$ by a few basis points. That variance accrues to `BufferBook` (§11), not to the minter.

### 6.2 Request/settle path

For $A >$ `instantCap`, execution risk is removed from the buffer:

1. `requestMint` escrows the collateral, submits the order, and records **the request price and
   timestamp** on the receipt.
2. `settleMint` mints at the fill price, banded against **the request price** rather than the
   settle-time price, within `settleBandBps` (500).
3. `stageRefund` then `refundMint` returns the escrow in full once `settleWindow` (1 day) expires
   on an unsettled receipt.

Banding against the request price and bounding the window are both audit fixes: without them a
receipt could sit indefinitely and settle against an arbitrarily moved price. Measured on a
week-old receipt: 280.7 certificates minted against a hedge covering 140.4 — a 4,999 bps divergence.

The refund is deliberately **two functions**. `stageRefund` reallocates the escrow's venue-side
margin into the recall counter and closes the hedge the request opened; it touches no balances and
therefore cannot fail on funding. `refundMint` performs the payout and may revert retryably. The
reason is given in §13.2: a single function that reallocated and then reverted on a funding check
rolled the reallocation back with it, which is precisely how escrow became permanently stranded.
Solidity has no partial commit, so the phases must be separate entry points.

---

## 7. Collateral and margin policy

### 7.1 The hedge is exact at any leverage

At delta 1.0, $q P = N$. A price move therefore changes the position and the aggregate holder claim
by the same amount:

$$
\frac{\partial N}{\partial P} = q = \frac{\partial (qP)}{\partial P}
$$

so the vault's net exposure is zero for any $M$. **Leverage does not break the hedge.** What
leverage buys is liquidation risk, and liquidation is the one failure that genuinely breaks the
product: once the position is force-closed, the vault holds cash with no hedge and a subsequent
recovery impairs holders irreversibly.

The liquidation threshold for a long financed at $\tau$ of notional, at maintenance fraction $m$, is
the return $r$ solving $\tau q P_0 + q P_0 r = m q P_0 (1+r)$, i.e.

$$
r^{*} = -\,\frac{\tau - m}{1 - m}
$$

| $\tau$ | Leverage | $r^{*}$ at $m = 0.03$ |
| --- | --- | --- |
| 1.00 | 1.00× | −100% (unreachable) |
| **0.90** | **1.11×** | **−89.7%** |
| 0.50 | 2.00× | −48.5% |
| 0.20 | 5.00× | −17.5% |

On a \$1–3M book a single earnings gap reaches the 5× row, so the target is as close to 1× as the
redemption float permits.

### 7.2 The split, and its immutable bounds

Collateral is split at mint: $\tau$ to the venue as margin, $1-\tau$ retained as the hot buffer that
serves instant redemptions. Default $\tau = 0.90$.

`MIN_TARGET_MARGIN_BPS = 5000` and `MAX_TARGET_MARGIN_BPS = 10000` are **contract constants checked
in the constructor, with no setter**. No deployment can produce a vault levered beyond 2×, and
governance cannot re-lever one afterwards. Rebalancing margin against buffer is a permissionless
`rebalance()` responsibility, bounded per call and once per attested batch.

The rejected alternative was posting only the venue's required margin (~50%) and keeping the rest
local. That is generous on instant-redemption capacity and runs the venue position at 2×, trading
the product's one credible claim for redemption convenience on a book thin enough that a gap is
plausible.

### 7.3 Why redemption is inherently two-phase

This is the sharpest venue-imposed constraint in the design, and the reason §8 has the shape it has.

Withdrawable margin at Lighter is not cash-in-minus-cash-out. Reproduced on nine live accounts to
$10^{-6}$:

$$
\text{available} = \text{collateral} + \sum \text{cross uPnL} - \text{cross IMR} + \sum_{\text{isolated}} \max(0, \cdot)
$$

Unrealised P&L *is* credited — but **the initial margin requirement is subtracted**, and by Fact B
(§4.3) that requirement is the market's 50%, not something the vault can lower.

For a full-supply exit at $\tau = 0.9$ and redemption fee $\phi$:

$$
\text{available} = \tau q P_0 + q(P - P_0) - q P \mu, \qquad
\text{requested} = \tau q P (1-\phi)
$$

$$
\operatorname{sign}(\text{available} - \text{requested}) = \operatorname{sign}\Big( P\big(1 - \mu - \tau(1-\phi)\big) - (1-\tau) P_0 \Big)
$$

At $\mu = 0.50$ the coefficient of $P$ is $-0.3991 < 0$: the withdrawal is **unsatisfiable at every
price**, and 55.5% short at flat price. Partial exits are safe, at flat price, only while the
redeemed share satisfies

$$
s \le \frac{\tau - \mu}{\tau(1-\phi)} = \frac{0.9 - 0.5}{0.8991} \approx \mathbf{44.5\%}
$$

The unsafe region is precisely the mass-exit and last-holder case that Law 2 exists to guarantee.

**No resizing fixes this.** Margin backing an open position is locked by the IMR and frees only when
the position closes. Redemption is therefore necessarily: **close, wait for the fill batch, then
withdraw.** Combined with Fact A — an unsatisfiable withdrawal fails silently in-rollup — the recall
must also be *retryable* and reconciled against confirmed arrival rather than against request
acceptance.

Three alternative designs were built and rejected on measurement: resizing the withdrawal by price
with a global clamp (one early redeemer at a risen price requests 8,982 of 8,992 available — other
holders' margin); a per-receipt margin-hold lifecycle with a TTL (double-counts headroom, provably
capping withdrawable margin at half of deposits, and requires a keeper inside the one path that must
work with no off-chain services); and treating L1 acceptance as evidence cash moved (on rollup
rejection this spends the receipt's budget and the claim reverts permanently).

---

## 8. Redemption

Law 2 is absolute, so redemption has three tiers and the last requires nobody's cooperation.

### 8.1 Tier 1 — instant

Burn, pay from the hot buffer at $P(1-\phi)$. Reads no buffer threshold, no capacity, no mint
permission. If the buffer cannot cover the payout it reverts `CertVault_UseQueuedRedeem` and the
holder uses tier 2. This is a fast path declining while the unconditional path stays open beside it,
not a gate.

### 8.2 Tier 2 — queued, with two-phase recall

1. `requestRedeem` burns the certificates, records the obligation, and submits a closing order on
   the side derived from the vault's own signed order ledger.
2. `recallMargin()` — **permissionless, retryable, fail-open** — asks the venue to release
   collateral once the close has filled.
3. `_sweepPending()` collects what the venue has actually released and reduces the outstanding
   recall counter by **the amount that arrived**, never by the amount requested (Fact A).
4. `claimRedeem` pays the holder by pull payment.

Two properties are worth stating explicitly because both were defects first.

**The request is sized on what is owed, not on what was deposited.** The obligation grows with
price; the cost basis does not. A request sized on basis can never repatriate the position's gain.
Measured at 2× price: a receipt owed 7,102.97 while the hot buffer plus every dollar the contract
could ever recall totalled 3,559.54 — a permanently unpayable receipt, with the certificates
already burned. Over-requesting is safe: the venue fulfils what it can, the sweep floors its counter
application, and a larger arrival simply lands in the hot buffer, which is where a gain belongs.

**A claim that cannot yet be funded reverts retryably without consuming the receipt.** The receipt
stays claimable indefinitely, and both `recallMargin()` and the sweep are permissionless, so nobody
is trapped. FIFO ordering was deliberately **not** implemented: forcing receipts to be claimed in
order would let one absent holder block everyone behind them, which would breach Law 2 rather than
serve it.

The honest SLA that follows is **two batch round-trips**, one for the close and one for the
withdrawal — not the single round-trip earlier documents claimed.

### 8.3 Tier 3 — force exit, and the escape hatch

`forceExit(certIn)` drives the same on-chain path with no privileged caller. Any holder can run it.
It reads no permission and no health signal, and it works with every off-chain service dead.

If the sequencer censors the request, the venue's own 14-day `PRIORITY_EXPIRATION` elapses,
`activateDesertMode()` freezes the rollup, and holders exit by proving ownership against posted
blobs, with positions settling at last mark price. The procedure is published in advance.

**Totality of the exit path.** Every quantity-times-price product in the vault is a total function:
512-bit `mulDiv` plus a published price clamp, `MAX_VALUATION_PX18 = 1e36`, sitting ten decades above
the highest price the venue's `uint32` tick domain can represent, paired with a quantity clamp
`MAX_VALUATION_QTY18` chosen so the pair is provably non-overflowing. This closes an audit finding
in which an absurd feed price (~$10^{59}$) overflowed and reverted `forceExit` — the backstop — for
a holder whose certificates were sound. No price any feed can report can revert a redemption.

---

## 9. Solvency and verification

### 9.1 What the venue provides

Lighter's **Public Account Tree** holds each account's aggregated asset value, position sizes,
funding data and ownership. It is merkleized with Poseidon2, its root is committed on-chain and
zk-verified each batch, and it is *fully reconstructible from the blob data posted on-chain* by
replaying per-batch Account Delta Trees.

### 9.2 The published figure

`CertVault.solvency()` returns:

| Field | Nature |
| --- | --- |
| `supply` | Certificates outstanding — contract state |
| `notional18`, `margin18` | From the latest attestation |
| `buffer18` | **The vault's own ERC-20 balance — ground truth** |
| `deltaBps` | Deviation from delta 1.0 |
| `provenAtBatch`, `ageSec` | Which batch, and how stale |
| `accrual18` | **The `BufferBook` ledger — attester-relayed cumulative P&L, not independently verified** |

There is no code path that returns backing without also returning its age and provenance.

The separation of `buffer18` from `accrual18` is an audit fix (M-1) and the most instructive one in
the project. The two were a single field published as "the buffer", and it was the ledger. A ledger
of claimed P&L is not a pile of money: measured, 100,000.01 published against 91,028.00 actually
held after one mint-and-redeem cycle, and — because an attester writes it — 500,100,000.01
published against 91,028.00 held after a single `accrueFunding` call.

### 9.3 Three verification routes, and the staged choice

| Route | On-chain cost | Engineering cost |
| --- | --- | --- |
| **A.** Off-chain reconstruction, the on-chain root as anchor | zero | days — tooling only |
| **B.** Poseidon2-Goldilocks Merkle path verified in Solidity | ~400–650k gas | days–weeks; no circuit, no trusted setup |
| **C.** Custom SNARK circuit and verifier | ~250–350k gas, flat | weeks; circuit, prover service, deployment |

**C1 ships route A. C2 upgrades to route B. Route C is rejected** — and note that Lighter's own
circuit proves *asset balance in desert mode only*, never position notional, so it could not serve
solvency even if shared.

Route A is not a fudge: the Account Delta Tree blobs are on-chain, so any third party can reconstruct
the tree and check our figures today, with no new contracts. What it does not provide is a contract
that *refuses to operate* on bad backing. That arrives with route B.

Route B's parameters are pinned from `elliottech/poseidon_crypto`: Goldilocks field
$p = 2^{64} - 2^{32} + 1$, `WIDTH = 12`, `RATE = 8`, `D = 7`, `ROUNDS_F = 8`, `ROUNDS_P = 22`, and
`HashTwoToOne` consumes $2 \times 4$ field elements — exactly `RATE`, so **one permutation per Merkle
node**. Per permutation: 118 S-boxes × 4 multiplications = 472 field multiplications plus the
internal linear layer. Because all operands are below $2^{64}$, each multiplication is a single
`MULMOD` at 8 gas. **This estimate is analytical, not measured**, and replacing it with a Foundry
benchmark is an open item that gates the route-B commitment.

Notably, Lighter itself does **not** verify Merkle paths on-chain: `performDesert` hashes the claim
into a single commitment and proves it inside a PLONK/BN254 SNARK. There is no Merkle verification
primitive anywhere in their contracts, so nothing is directly reusable — but the pattern is proven
and their verifier is deployed.

### 9.4 Honest phrasing, staged

- **C1:** *"independently verifiable every batch (~60s)"* — with the reconstruction tool published.
- **C2:** *"proven on-chain every batch (~60s), age published."*
- **Never** *"provable every block"*, at any stage.

### 9.5 Attester properties

Attestation is a single key in C1, and its powers are deliberately narrow: it cannot trade, cannot
withdraw, and cannot widen capacity (§10). Loss and compromise are both handled:

- **Lost.** Minting eventually stops as `ageSec` passes the maximum; **redemption is untouched**,
  since no redemption path reads an attestation for any gate. Governance proposes a replacement and
  anyone may install it once an immutable 2-day notice period elapses.
- **Compromised.** `setAbsoluteCap(vault, 0)` shuts new minting in one transaction while rotation
  serves its notice separately. Inflated open interest cannot widen minting past
  $\min(\text{absoluteCap}, 100 \times \text{freeCollateral})$, `absoluteCap` is itself bounded by an
  immutable ceiling, and the accrual ledger sits under a `min` and can only tighten.

Governance itself is immutable, and nothing else in C1 is rotatable.

---

## 10. Capacity

The C1 markets carry \$1–3M of open interest (§4.4). A vault of any real size becomes a dominant
share of it, which moves the price it hedges into and distorts the funding it depends on. But the
market is expected to grow, so capacity is written as a **formula, not a constant** — no redeploy,
no migration, no hardcoded ceiling:

$$
\text{maxNotional} = \min\big(\ \delta \cdot \text{OI},\quad \text{absoluteCap},\quad \text{bufferCapacity}\ \big)
$$

$$
\text{bufferCapacity} = \min\big(\ 100 \cdot \text{freeCollateral},\quad \texttt{BufferBook.capacity18}\ \big)
$$

- $\delta$ (`depthBps`) starts at **10%**, governance-adjustable **inside immutable bounds**
  (1%–30%). Governance can never remove the cap.
- `OI` arrives in the same per-batch attestation that feeds solvency, so it is derived from chain
  data rather than self-reported.
- `freeCollateral` is an ERC-20 balance less the vault's own obligation counter — ground truth,
  derived rather than accrued, and unmovable by any attester. The multiple 100 corresponds to a 1%
  adverse move on the whole book.
- The ledger's own claim is kept **only under the `min`**: an attester can make the vault more
  conservative, and an exhausted ledger still halts new minting, but no attester can admit a mint
  that real collateral does not support.

That last constraint is an audit fix. Previously the third leg was the accrual ledger alone, putting
an unbacked, attester-writable number into admission control *in the direction that widens it*: two
of three legs were attester-written and only the immutable cap was a real bound.

Both mint paths revert with a distinct error at capacity, so the interface can say *"at capacity"*
rather than *"failed"*. **Redemption is never capped.**

Two consequences accepted openly:

- **C1 is a capped pilot.** At 10% of a \$1.19M TSLA book, roughly **\$120k of uTSLA**. Launch
  planning and marketing must say so.
- **perpRFQ is the size valve.** Both markets have `rfq_enabled`; market makers quote large blocks,
  which is how large mints get filled without walking the book. It requires address whitelisting, so
  it is a C2 item, and it is the main reason capacity can rise faster than visible order-book depth.

`maxNotional`, current utilisation, $\delta$ and live open interest are published on the public
dashboard beside the solvency figure. Capacity is a fact about the market, not an embarrassment.

---

## 11. Economics

### 11.1 Flows

| Flow | Direction | Destination |
| --- | --- | --- |
| Mint fee (`mintFeeBps`, 10 bps) | From minter | Protocol |
| Redemption fee (`redeemFeeBps`, 10 bps) | From redeemer | Protocol |
| Venue trading fees | — | **Zero maker and taker on both C1 markets** |
| Funding | Either direction, continuous | `BufferBook` |
| Execution variance (fill vs oracle) | Either direction | `BufferBook` |
| Realised basis | Either direction | `BufferBook` |
| Protocol fee split | — | 80 / 10 / 5 / 5 — buyback / staker pay / treasury / ops (`FeeVault`, later phase) |

### 11.2 The buffer as implemented — a cliff, not a ramp

Law 3 describes a graduated response across four published thresholds (`floor`, `fee_on`,
`mint_slow`, `insurance_draw`). **C1 does not implement the graduation, and this paper says so
rather than describing the softer-sounding version:**

- `holdingFeeBps()` is computed and published, and **nothing charges it**;
- `mintSlowed()` is read by nothing outside its own unit tests — `instantCap18` is immutable deploy
  config with no setter, so it does not taper;
- `insuranceDrawNeeded()` is a published number with no consumer until C3.

What actually happens as the ledger degrades is **nothing at all**, until it crosses zero — at
which point capacity goes to zero and new minting halts outright. The thresholds are *signals* in
C1: readable views and a `ThresholdCrossed` event, configurable per asset so a \$100k floor is not
applied to a \$1.19M book. Wiring the fee and the taper is C2 work.

**Redemption reads none of it, at any level, ever.**

### 11.3 The buffer versus the ledger

Restating §9.2 because it is an economic claim as much as an accounting one: the figure published as
the buffer is the vault's own token balance, and the ledger is published beside it, labelled as what
it is — cumulative P&L relayed by an attester and not verified on-chain. Conflating the two
overstates backing under ordinary operation and can be made to overstate it arbitrarily by a
compromised key.

### 11.4 Seniority

The draw order is immutable: buffer, then staked `$CERT`, then — never — holder backing. In C1 only
the first step exists; the junior tranche ships in C3. The published order is therefore a
commitment about C3's design, not a claim about C1's protections, and it should be read that way.

---

## 12. Trust and threat model

### 12.1 What must be trusted

| Assumption | Why it cannot be removed in C1 |
| --- | --- |
| **Lighter as a venue** — its solvency, its sequencer, its circuits | It is the only perps venue on the chain. Single-venue dependency is the protocol's largest irreducible risk |
| **The Chainlink feed** for the asset | It is what mint and redeem price against |
| **The attester's honesty for `notional`, `margin`, `openInterest` and the ledger** | Route A publishes independently checkable figures but does not verify them on-chain. Route B removes this for the first three |
| **Deploy-time configuration** | There is no owner and no upgrade path, so an item got wrong is wrong permanently. This is why the deployment checklist is normative |
| **The collateral token's behaviour** — no transfer callbacks, not fee-on-transfer, not rebasing, `decimals() ≤ 18`, no blocklist reaching the vault | There are no reentrancy guards; every payout path is checks-effects-interactions and the audit's attack battery confirmed the ordering holds under callback collateral, but that is a property of the token, not of the vault |

### 12.2 What need not be trusted

Any off-chain service; the front-end; governance for anything on the redemption path; the operator's
infrastructure; and the attester for anything redemption depends on.

### 12.3 Failure modes

| Failure | Response |
| --- | --- |
| Operator infrastructure compromised | No trading or withdrawal authority exists off-chain (Law 6). Worst case is griefing permissionless calls others can also make |
| All off-chain services offline | Instant mint and redeem keep working — self-contained on-chain transactions. Delta drifts until someone claims the `rebalance()` bounty; `forceExit` keeps redemption open |
| Oracle stale or deviant | Minting pauses; redemption uses the published last-good procedure |
| Chainlink-vs-mark basis blowout | Minting pauses; realised basis to the ledger; band published |
| Venue deposit cap reached | Minting pauses with a clear reason; redemption unaffected |
| Sequencer censorship | 14-day expiry, then desert mode; holders exit against posted blobs |
| Market delisted or halted | Per-asset wind-down: minting off, position closed on the side derived from the vault's own ledger, redemption continues against margin |
| Attester key lost or compromised | §9.5 |
| Feed prints an absurd price | Every valuation is a total function; no price reverts a redemption (§8.3) |
| Buffer exhausted | New minting stops; every redemption path stays open; holder backing untouched |
| **Position liquidated** | **The one failure that genuinely breaks the product.** Mitigated structurally by ~1.1× target leverage under bounds with no setter (§7) |

The last row is the honest answer to *what is the real risk here*: not a compromise, but a market
event that force-closes the hedge while holders still hold claims.

---

## 13. Security review history

We publish this in full. A clean report proves less than a detailed record of what was broken, how
it was found, and what made it invisible.

### 13.1 The external review

An independent audit of the C1 contracts reported **2 Critical, 2 High, 6 Medium and 9 Low
findings, plus 2 attacks that broke through the existing test suite**, delivered as runnable
proof-of-concept tests committed to the repository unmodified.

All are closed except two, both documented and accepted:

- a **redemption staleness** property, which is a direct consequence of Law 2 — redemption must not
  read a health signal, and a staleness gate is a health signal;
- a **magnitude bound on `accrueFunding`**, unsatisfiable while the auditor's own tests require the
  unbounded behaviour. The harm was closed differently, by backing the published buffer with a real
  balance and labelling the ledger separately (§9.2).

Two of the auditor's tests **still fail, and their files were left byte-identical deliberately.**
Both demonstrate a defect by exercising it, so once the defect is fixed they fail one line *earlier*
than their own assertion:

| Test | Now fails with | Why that is evidence of the fix |
| --- | --- | --- |
| `test_A1` | `CertVault_AtCapacity()` | The cumulative cap binds on the 12th of 20 unguarded mints, so the test cannot reach its overshoot assertion. A directed test admits 11 of 20 — \$109,890 ≤ \$119,000 |
| `test_A3` | `CertVault_MintPaused()` | The mint the test needs to succeed is now correctly refused. The property is proven at oracle level with the same numbers |

Each needs a one-line correction from the auditor (a `vm.expectRevert`). Editing an auditor's
evidence to make a suite green is not something the audited party should do.

### 13.2 Critical defects found by internal review

Six Critical-severity defects were found by whole-branch review waves *before* the external audit,
each invisible to the per-task reviews that preceded them. Each was reproduced with a
proof-of-concept test before being fixed, and each fix was proved load-bearing by reverting it and
observing the specific failure.

| Defect | Measurement |
| --- | --- |
| **`settleMint` did not validate the fill price** | `settleMint(id, 1)` minted **4.995 × 10²²** certificates against a \$49,950 escrow |
| **`rebalance()` could be spammed within one attested batch** | 25 calls in one block moved 250,000e18 of notional against a 119,000e18 ceiling. Now bounded to one rebalance per new batch, still permissionless |
| **`settleMint` had no deadline** | A week-old receipt minted 280.7 certificates against a hedge covering 140.4 |
| **Realised gain could never be recalled** | Owed 7,102.97; hot buffer plus everything recallable, 3,559.54. A permanently unpayable receipt with certificates already burned |
| **`refundMint` could strand escrow permanently** | Reproduced after 20 recall cycles plus a governance wind-down. Root cause: the reallocation was atomic with the payout, so it rolled back exactly when it was needed |
| **A sign-blind trim at zero supply** | The attested notional is unsigned, so a correction that flattens a dangling long *enlarges* a dangling short: −1,403,641 → −2,246,668 |

And one from the audit's own class, found by re-tracing `forceExit` end to end after the reported
finding was closed: 512-bit `mulDiv` **alone** was insufficient — it still panicked at
$P \approx 1.157 \times 10^{77}$ for a holder of 1.003 certificates. The shipped fix is `mulDiv`
*plus* the published price clamp of §8.3.

A further defect deserves separate mention because it concerns the venue's semantics rather than
arithmetic: **`closeAll()` hardcoded the sell side.** Since `_baseAmount == 0` means full position
*size* and leaves direction to the caller (§4.2), the governance wind-down of last resort would have
**doubled a short** instead of closing it. The vault can genuinely be short, because the refund
path's hedge close is open-loop — nothing on-chain can read the vault's position. `closeAll()` now
derives its side from `venuePositionBase`, a signed local ledger of every order the vault has
submitted, and submits nothing where that ledger reads flat. The ledger cannot observe in-rollup
order refusal, partial fills, liquidation or desert-mode settlement, each of which can flip its
sign, so this is a strict improvement on assuming long — **not a proof.**

### 13.3 Three structural blind spots — the finding that matters most

Three separate times, the reason a defect survived was the same: **the test suite could not observe
it.** We consider this the most transferable result of the whole exercise.

**1. A tautological invariant.** The supply invariant accumulated minted amounts from the vault's own
return values and compared them to the vault's own supply — measuring the vault against its own
transcript. No over-mint could falsify it. The fuzzer had been reproducing a Critical continuously
while reporting green.

**2. An unfalsifiable law.** Law 1 was never asserted at all, despite the specification promising
it. Worse, written literally as $q P \le N + M$ it is *unfalsifiable*: margin **buys** the notional,
so the sum double-counts at roughly 1.9× the collateral in. It passed 8,192 fuzz calls during a
\$752 over-mint. There are now four invariants, including one that measures backing against the
venue's own figures rather than the vault's arithmetic, verified at up to 1,500 runs × depth 100 —
150,000 calls.

**3. An unmodelled venue.** Two instances. The mock enforced no margin requirement, so the vault
opened ~\$355k of notional against **\$1** of venue margin and every test passed; when enforcement
landed, **nine existing tests immediately reverted.** Separately the mock modelled no mark-to-market
P&L, which is why the unrecallable-gain Critical was invisible — and adding P&L broke **zero**
tests, proving Law 1 was unobservable rather than merely untested.

A fourth, of the same family, concerns the toolchain rather than the mock: **Foundry does not
enforce EIP-170 in `forge test`**, so an undeployable contract sat green in a passing suite.
`CertFactory` measured 28,205 B against the 24,576 B runtime ceiling — **3,629 B over**. The cause is
structural: a contract that can `new X` carries X's entire *creation* code inside its own *runtime*
code, and `CertVault`'s initcode is 25,743 B, over the runtime limit on its own. **No contract can
ever deploy a `CertVault` via `new`**, so no leaner factory, lower optimiser setting or helper
contract could have recovered it. `CertFactory` became a registry over vaults deployed by script;
its margin went from −3,629 B to **+22,253 B**. `forge build --sizes` is now a normative
pre-deployment check, and a green test suite is explicitly *not* evidence for it.

### 13.4 Current verification status

Verified 2026-09-08 on branch `feat/contracts-c1`:

| | |
| --- | --- |
| Tests | **258 total — 256 pass, 2 fail** (the two auditor PoCs of §13.1) |
| Invariants | 4, all passing, to 150,000 fuzz calls |
| Contract sizes | All 7 under EIP-170; largest is `CertVault` at 17,559 B (+7,017 B) |
| Commits since the audit landed | 14 |

---

## 14. Limitations and open problems

### 14.1 The structural limitation

Every residual risk in this design traces to one fact: **`ILighter` exposes no position getter, and
the attested notional is unsigned.** The vault cannot read what it holds at the venue. Consequences:

- the refund path's hedge close is open-loop and can over-close;
- `closeAll()` derives its side from a local ledger that cannot see in-rollup refusal, partial
  fills, liquidation or desert-mode settlement;
- a zero-supply correction is sign-blind unless the local ledger is consulted.

The real fix is either a venue-side position getter or a **signed** attestation. Both are outside
this repository's control; the signed attestation is the tractable one.

### 14.2 Accepted design trade-offs

- **Redemption reads no staleness.** A deliberate consequence of Law 2, reported by the audit and
  accepted rather than closed.
- **Route A verification.** Backing is independently checkable, not on-chain verified. Route B
  closes it.
- **`settleMint`'s `fillPx18` argument is informational**, banded against the request price and
  sizing nothing. No attested per-receipt fill price exists anywhere in C1.
- **`markPx18` has no staleness check.** The basis band's liveness is an operational assumption
  about the attester's cadence, not a contract guarantee.
- **The holding fee is published, not charged** (§11.2).
- **One property moved from code-enforced to process-enforced** when the factory became a registry:
  `registerVault` does not verify that a vault's immutable dependencies match the factory's. It is a
  read-back item in the deployment checklist.

### 14.3 Open verification items

| Item | What it blocks |
| --- | --- |
| `baseAmount == 0` direction semantics, against Lighter source | Confidence in `closeAll()`. The conservative reading is what the mock models, so a vault correct against the mock is correct either way |
| A Foundry gas measurement for route B | The C2 route-B commitment |
| USDG asset index, `tickSize`, `minDepositTicks`, `depositCapTicks`; USDG/USDC pool depth | `Zap` and deposit sizing. The API endpoints are gated; read from the live contract |
| Blob retention and availability window | Route A's durability claim |
| Buffer thresholds and initial $\delta$, fitted to real funding, basis and OI history | Mainnet parameters |
| Whether an API key can be scoped to trading without withdrawal | The optional latency path only; C1 does not depend on it |
| perpRFQ whitelisting — process, and whether a contract address is eligible | The C2 capacity valve |
| Whether open interest can be proven per batch from blob data rather than trusted from the API | Otherwise $\delta$ must be governed conservatively |
| Byte-for-byte comparison of the live `ZkLighter` against `75c2a73` | Confidence in every venue fact in §4 |

### 14.4 Not yet built

All six off-chain services; the deployment script (now load-bearing, since the factory no longer
deploys vaults); the published tree-reconstruction tool, which is what makes "independently
verifiable" true for a third party; on-chain proof verification (C2); the holding fee and cap taper
(C2); and `CERT` with `InsuranceStaking` (C3).

**An ABI break to communicate:** `CertFactory`'s `VaultDeployed` event is now `VaultRegistered`,
with the same three fields. Any indexer subscribing to the old topic must change.

### 14.5 Blocking copy corrections

The backend cannot ship truthfully behind the current front-end text. Blocking: the
"provable/solvency every block" claim, which must become "proven on-chain every batch (~60s), age
published"; "no custodial stock token exists on Robinhood Chain"; "the first holdable stock tokens";
four market statistics borrowed from a different chain; "deposit USDC" without stating that backing
margin is the venue's base asset; a redemption promise without its real SLA; a "C1 LIVE" badge on
something not live; and the addition of basis risk, single-venue dependency and ~60s solvency
latency to the stated boundaries.

---

## 15. Roadmap

| Phase | Contents |
| --- | --- |
| **C1** — a capped pilot, honestly labelled | The seven contracts; `uTSLA` and `uNVDA`; route-A solvency; delta-keeper, solvency-prover, fill-reporter; the published reconstruction tool; a public dashboard showing solvency **and capacity**. No off-chain trading key |
| **C2** — capacity | Route-B on-chain proofs; perpRFQ whitelisting for size; `uSPX` / `uQQQ`; DEX seeding; lending integrations; the holding fee and cap taper; the optional latency path only if an API key can be proven unable to withdraw |
| **C3** | `CERT` genesis, `InsuranceStaking`, the funding-surplus flywheel |
| **C4** | Structured wrappers — DCA and covered-call-style vaults — on the certificate base |

If mint TVL misses its day-30 threshold, the vault engine persists as internal infrastructure and
marketing rotates.

---

## 16. References

Venue and chain facts verified 2026-09-07; protocol status verified 2026-09-08.

- Lighter contract source — `elliottech/lighter-contracts` @
  `75c2a73a5c25c9a6a36b66ba73aaf71267232b42` (`ZkLighter.sol`, `AdditionalZkLighter.sol`,
  `Config.sol`, `Storage.sol`, `lib/TxTypes.sol`)
- Poseidon2 parameters — `elliottech/poseidon_crypto/hash/poseidon2_goldilocks`
- Lighter whitepaper — state tree, priority transactions, account types, escape hatch —
  <https://assets.lighter.xyz/whitepaper.pdf>
- Lighter documentation, including Public Pools and the market list —
  <https://docs.lighter.xyz/llms-full.txt>
- Live venue metadata — `https://api.rh.lighter.xyz/info`, `api/v1/orderBookDetails`
- Robinhood Chain mainnet on Arbitrum Orbit — <https://blog.arbitrum.io/robinhood-chain-mainnet/>
- Robinhood Stock Tokens documentation — <https://docs.robinhood.com/chain/stock-tokens/>
- Stock tokens in DeFi (~\$12M) —
  <https://cryptobriefing.com/robinhood-chain-stock-tokens-defi-deposits/>
- Arcus `pTokens` —
  <https://www.theblock.co/news/defi/2026-08-25-robinhood-chain-dex-arcus-ptokens-perps-erc-20s-412696>
- Perpetra — <https://www.perpetradex.com/>

Internal:

- [`docs/superpowers/specs/2026-09-07-usecert-robinhood-backend-design.md`](superpowers/specs/2026-09-07-usecert-robinhood-backend-design.md)
  — the design authority
- [`docs/DEPLOYMENT-CHECKLIST.md`](DEPLOYMENT-CHECKLIST.md) — normative deployment constraints
- [`docs/HOW-IT-WORKS.md`](HOW-IT-WORKS.md) — the same material in plain language
- `test/AuditPoC.t.sol`, `test/AttackSuite.t.sol` — the external audit's evidence, unmodified

---

*This paper describes software that has not been deployed to mainnet. Certificates confer no
custody, no dividends and no shareholder rights. Nothing here is an offer, a solicitation, or
investment advice.*
