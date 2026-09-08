# UseCert — how it works

**A plain-language walkthrough of the whole backend.**

Date: 2026-09-08 · Covers: C1 contracts as built on branch `feat/contracts-c1` · Companion
document: [WHITEPAPER.md](WHITEPAPER.md)

This document is for anyone who needs to understand what we built and why, without reading
Solidity. It uses real numbers from the test fixture throughout, so you can follow the money.
Nothing here is aspirational: where something is *not* built, it says so in bold.

---

## Contents

1. [The idea in one page](#1-the-idea-in-one-page)
2. [The problem it actually solves](#2-the-problem-it-actually-solves)
3. [The cast](#3-the-cast)
4. [Money in: minting a certificate](#4-money-in-minting-a-certificate)
5. [Where the money sits, and why](#5-where-the-money-sits-and-why)
6. [Money out: three ways to redeem](#6-money-out-three-ways-to-redeem)
7. [How the price is decided](#7-how-the-price-is-decided)
8. [How you check we are solvent](#8-how-you-check-we-are-solvent)
9. [How big this can get](#9-how-big-this-can-get)
10. [Funding: who pays to hold the hedge](#10-funding-who-pays-to-hold-the-hedge)
11. [What can go wrong](#11-what-can-go-wrong)
12. [What we deliberately did not build](#12-what-we-deliberately-did-not-build)
13. [What we found by attacking it ourselves](#13-what-we-found-by-attacking-it-ourselves)
14. [Where it stands today](#14-where-it-stands-today)
15. [Glossary](#15-glossary)

---

## 1. The idea in one page

You give the protocol $10,000 of stablecoin. It gives you back **24.975 uTSLA** — an ordinary
ERC-20 token whose value tracks the Tesla share price, one-for-one.

Behind the scenes, the protocol does not buy Tesla shares. It cannot: there is no share custodian
here. Instead it opens a **long perpetual futures position** on Tesla, of exactly the same size as
the certificates it just issued, on the only perps venue on Robinhood Chain (Lighter). It posts
your stablecoin as margin for that position.

That is the whole trick:

> **Certificates outstanding × share price = perp position notional.**
> Whatever the share price does, the position gains or loses exactly what the certificate holders'
> claims gain or lose. The two cancel. The protocol is never taking a directional bet.

When you want out, you burn your uTSLA and the protocol closes that much of the position, pulls the
collateral back off the venue, and pays you the current oracle price. There is no queue you can be
refused from, no "redemptions paused", and no approval step: the function that does it,
`forceExit`, can be called by anyone holding certificates and reads no permission, no buffer level
and no capacity limit.

Three things make this different from just holding a token someone issued you:

| | A custodial stock token | UseCert |
| --- | --- | --- |
| Who holds the asset | An issuing company, in a brokerage account | Nobody. There is no asset — the exposure is synthetic |
| What you own | A debt claim on that company | A claim on on-chain collateral and an on-chain position |
| If the issuer fails | You are a creditor | There is no issuer to fail. The vault is a contract with no owner |
| Can you be refused | Yes — geography, KYC, issuer discretion | No. The redemption path is permissionless code |
| Can you check the backing | Only if they publish it | Yes, per batch (~60s), from public chain data |

And the honest flip side, stated up front because it is stated in the code too:

- Backing is **independently verifiable, not verified on-chain** in C1. See §8.
- Redemption is fast in the expected case but the guaranteed worst case is **14 days**, then a
  rollup-level escape hatch. See §6.
- The market we hedge in is small. C1 is a **capped pilot** — roughly $120k of uTSLA. See §9.

---

## 2. The problem it actually solves

It is worth being precise here, because the original project documents got this wrong and the live
front-end still does.

**What is not the problem.** "There is no way to hold a stock token on this chain." There is.
Robinhood Stock Tokens shipped at mainnet and trade on Uniswap and Pleiades. A competitor, Arcus,
already wraps perp accounts as transferable ERC-20s. Claiming to be first is simply false here, and
we removed that claim.

**What is the problem.** Those Robinhood Stock Tokens are debt securities issued by *Robinhood
Assets (Jersey) Limited*. In substance:

- someone holds the shares for you, and you hold their promise;
- if that someone has a bad day, you are an unsecured creditor;
- and you cannot buy them at all if you are a US person, or in a long list of other places.

So the defensible claim — the only one we will make — is:

> **Equity price exposure with no custodian, no issuer credit risk, and no geo-gate. Fully
> synthetic, backed by on-chain positions and margin that anyone can verify.**

The difference from Arcus is also precise, and it is the reason for the whole design. Arcus tokens
are **shares in a perp account**: their value is that account's net asset value, including its
funding history and how well its trades filled. Ours are minted at **oracle price at delta 1.0**:
the certificate tracks the stock, and the vault absorbs funding and execution quality itself, into a
published ledger. A share wrapper cannot promise "1 uTSLA ≈ 1 TSLA". Vault-level accounting can.

---

## 3. The cast

Seven contracts. Names are fixed by the front-end's architecture display.

| Contract | Size | What it does, in one line |
| --- | --- | --- |
| **`CertVault`** | 17,559 B | The whole engine. Holds collateral, mints and burns certificates, and **is itself a registered Lighter trading account** that submits its own orders |
| **`Certificate`** | 2,196 B | The ERC-20 you hold (`uTSLA`, `uNVDA`). Only its vault can mint or burn it |
| **`CertOracle`** | 4,420 B | Decides the price. Chainlink feed as primary, Lighter's mark price as a cross-check, with staleness / deviation / basis guards |
| **`SolvencyRegistry`** | 1,732 B | Receives the per-batch backing figures (position notional, margin, market open interest) |
| **`CapacityOracle`** | 2,033 B | Decides how much the vault is allowed to hold, as a formula over proven market depth |
| **`BufferBook`** | 2,192 B | The running P&L ledger: funding received or paid, execution variance, realised basis |
| **`CertFactory`** | 2,323 B | A **registry** of the deployment's vaults. It does not deploy them — see §13, it cannot |

All seven are comfortably under Ethereum's 24,576-byte contract limit. There is **no owner, no
keeper, no pause switch and no upgrade path.** Governance can set a small number of published
parameters inside immutable bounds, and that is all it can ever do.

### The off-chain workers — and what they are not allowed to do

Six background services are specified. **None is built yet** (see §14). The important property is
what they *are*:

| Worker | Job |
| --- | --- |
| `solvency-prover` | Rebuilds Lighter's account tree from public blob data and posts the backing figures |
| `delta-keeper` | Watches for drift and calls the public `rebalance()` function |
| `funding-sweeper` | Records funding and realised basis into `BufferBook` |
| `fill-reporter` | Reports fills so large mints can settle |
| `buffer-watchdog` | Watches the published thresholds |
| `chain-indexer` | Feeds the dashboard: flows, receipts, events |

**Not one of them holds authority to trade or to move funds.** Every worker either reads chain data,
or calls a function that anyone else — you, a competitor, a bot — could call instead. If all six
died tonight, instant minting and every redemption path keep working, because they are self-contained
on-chain transactions. That is a design law, not a happy accident (§12).

---

## 4. Money in: minting a certificate

Two doors, split on size, because the risks are different.

### The small door: `mintInstant` — one transaction, hedge included

Say you mint **10,000 USDG** of uTSLA with TSLA at **$400.00**. Fee is 0.10%.

| Step | What happens | Number |
| --- | --- | --- |
| 1 | Your collateral is pulled in | 10,000.00 USDG |
| 2 | Mint fee | −10.00 |
| 3 | Net collateral | 9,990.00 |
| 4 | Certificates minted to you, at the oracle price | **24.975 uTSLA** |
| 5 | 90% of the net is deposited to Lighter as margin | 8,991.00 → venue |
| 6 | 10% is retained locally as the **hot buffer** | 999.00 → stays in the vault |
| 7 | The vault submits its **own** buy order for 24.975 TSLA | notional $9,990 |

Everything above is one transaction. Note step 7: nobody has to remember to hedge. There is no bot
whose failure leaves the vault naked, because placing the order is part of the same transaction that
issues the certificates. If the order cannot be submitted, the whole mint reverts and you keep your
money.

Before any of that, four gates are checked, and any one of them stops the mint:

- the oracle must be healthy (fresh, not deviant, basis inside band);
- the vault must be under its capacity limit (§9);
- the accrual ledger must not be exhausted (§10);
- and the certificate amount must be non-zero after fees and rounding.

**Minting can be paused. Redeeming cannot.** That asymmetry is deliberate and it is everywhere in
this codebase.

The one risk you carry: your order fills in the *next* batch, about a minute later, so the realised
fill price is not exactly the oracle price you minted at. The difference — a few basis points, in
either direction — is absorbed by the vault into `BufferBook`, not passed to you.

### The big door: `requestMint` → `settleMint` — no execution risk for the vault

Above the instant cap (**$10,000** in the current configuration), a large mint would otherwise let
one person push the price they are minting at and hand the cost to everyone else. So it becomes
two steps:

1. **`requestMint`** — your collateral is escrowed, and you receive a receipt. The vault submits the
   order and records **the price at that moment** on the receipt.
2. **`settleMint`** — once the fill is known, the certificates are minted, and the fill price is
   checked against **the price you requested at**, not against the price now. Anything outside a
   published band (5%) is rejected.

And because an escrow that can get stuck is worse than a slow mint, there is a third step for the
bad case:

3. **`stageRefund` → `refundMint`** — after the settle window (1 day) expires, anyone can stage
   your refund, and then you get your escrow back in full.

The refund is deliberately split into two functions. Staging makes the escrow's margin recallable
from the venue and closes the hedge the request opened; paying out happens separately, and can be
retried. This looks like over-engineering until you see why (§13): a single function that did both
would roll back the recall whenever the payout failed — which is exactly the case it existed for.
It stranded a user's escrow permanently.

---

## 5. Where the money sits, and why

This is the part most people get wrong, including our own first implementation, so it is worth
slowing down.

Your 9,990 USDG ends up in two places: **8,991 as margin at the venue**, and **999 in the vault as
the hot buffer**. Why 90/10?

### The counter-intuitive bit: leverage does not break the hedge

You might assume the vault must post 100% margin to be "fully backed". It does not, and here is why.
At delta 1.0, certificates × price = position notional. So:

- price rises 10% → the position gains 10% of notional; holders' claims rise by the same 10% of
  notional. **Net zero.**
- price falls 10% → the position loses 10%; claims fall by the same amount. **Net zero.**

The hedge is exact at *any* leverage. Work the numbers from §4 forward:

| TSLA price | Your claim (24.975 uTSLA) | Margin equity at venue | Hot buffer | Total available |
| --- | --- | --- | --- | --- |
| $400 (mint) | 9,990.00 | 8,991.00 | 999.00 | **9,990.00** |
| $440 (+10%) | 10,989.00 | 9,990.00 | 999.00 | **10,989.00** |
| $360 (−10%) | 8,991.00 | 7,992.00 | 999.00 | **8,991.00** |

It matches to the cent in every row. That is what "delta 1.0" means in practice.

### So what does leverage cost? Liquidation risk — and that is fatal

What leverage buys is the chance of being **force-closed**. And liquidation is the one failure that
genuinely breaks the product: once the venue closes the position, the vault is sitting on cash with
no hedge. If the price then recovers, holders are impaired and nothing can undo it.

| Margin posted | Leverage | Adverse move needed to liquidate |
| --- | --- | --- |
| 100% | 1.0× | a total wipeout — unreachable |
| **90% (our default)** | **1.11×** | **~90%** |
| 50% (the venue's own default) | 2.0× | ~48% |
| 20% | 5.0× | ~18% — a single earnings gap reaches this |

On a market with roughly $1–3M of open interest, an earnings gap is a real, scheduled event. So the
target is as close to 1× as the need for a redemption float allows.

The bounds are **contract constants with no setter**: `MIN_TARGET_MARGIN_BPS = 5000` and
`MAX_TARGET_MARGIN_BPS = 10000`. No deployment can produce a vault levered beyond 2×, and governance
cannot re-lever one afterwards. It is not a parameter someone can turn up later.

### And the hot buffer is what makes instant redemption possible

Margin backing an open position is **locked** by the venue's initial margin requirement. You cannot
withdraw it while the position is open — it frees only once the position closes. That is a fact
about the venue, not a design choice, and it shapes everything in §6. The hot buffer is the float
that lets small redemptions settle in one transaction anyway.

---

## 6. Money out: three ways to redeem

The design law is: **redemption is never gated.** Not by buffer health, not by capacity, not by
oracle health, not by governance. Three tiers, and the last one needs nobody's cooperation.

### Tier 1 — `redeemInstant`: one transaction

Small size. You burn certificates, and you are paid from the hot buffer at oracle price minus a
0.10% fee. It reads no buffer threshold, no capacity, no `mintAllowed`.

If the hot buffer happens to be too thin to cover you, it reverts with a named error —
`CertVault_UseQueuedRedeem` — pointing you at tier 2. **This is not an exception to the law.** It is
a fast path declining, with the slow path unconditionally open beside it.

### Tier 2 — `requestRedeem` → `claimRedeem`: two round-trips

Larger size. Your certificates are burned immediately, and the amount you are owed is recorded.
Then, because of the venue fact in §5:

1. the vault submits an order to **close** that much of the position;
2. one batch later, the position is closed and the margin is no longer locked;
3. anyone calls `recallMargin()` and the vault asks the venue to release the collateral;
4. the released collateral arrives, and `claimRedeem` pays you.

Note the honest SLA that follows: **two batch round-trips, not one.** One for the close, one for the
withdrawal. Our earlier documents said one, and that was wrong.

There is a subtlety worth flagging because it took two attempts to get right. The vault asks the
venue for the amount it actually **owes**, not the amount it originally **deposited**. Those diverge
as soon as the price moves: if TSLA doubles, the position's gain is real money that belongs to
holders, and a request sized on the deposit can never bring it home. In an earlier version a holder
was owed 7,102.97 USDG while every dollar the contract could ever recall totalled 3,559.54. Asking
for more than is available is safe — the venue fulfils what it can and the rest simply stays put —
so the vault now asks for what it owes.

`recallMargin()` is permissionless and retryable, and the counter is reduced **only when the money
actually arrives**, verified against the venue's own pending-balance reading. Never on the basis
that a request was accepted, because acceptance carries no information about whether the money
moved.

### Tier 3 — `forceExit`: the backstop, and the reason to trust the rest

`forceExit` drives the entire exit path with **no privileged caller**. Any holder can run it. It
reads no permission and no health signal. If every off-chain service is dead, if governance has
vanished, if the front-end is gone — you still get out.

And if the venue's sequencer refuses to process the request at all? Then the clock the venue itself
runs takes over: after **14 days** (`PRIORITY_EXPIRATION`), anyone can call `activateDesertMode()`,
which freezes the rollup, and holders exit by proving ownership directly against the data posted
on-chain.

So the published SLA is exactly this, and must never be shortened in marketing copy:

> **One batch expected. 14 days worst case. Then the escape hatch.**

We spent real effort making sure tier 3 cannot break. The audit found one way: at an absurd feed
price, an internal multiplication overflowed and `forceExit` — the backstop — reverted for a holder
whose certificates were perfectly good. Every quantity-times-price product in the vault is now a
total function, using 512-bit arithmetic plus a published price clamp sitting ten decades above the
highest price the venue can even represent. There is no price any feed can report that reverts a
redemption.

---

## 7. How the price is decided

There are **two** prices, and they are not the same number. Our source documents never named this,
because on the chain they were written for both came from the same place.

| Price | Where it comes from | What it is used for |
| --- | --- | --- |
| **Chainlink feed** | A per-asset oracle | What mints and redeems price against. This is what "oracle price" means to you |
| **Lighter mark price** | The venue's own internal mark | What the hedge actually fills against, and what funding is charged on |

The gap between them is called the **basis**, and it is a real risk nobody is hedging. `CertOracle`
publishes both prices and the live basis, and applies four guards:

- **staleness** — the feed round must be recent enough (1 hour in the current config);
- **deviation** — the price cannot jump more than a published band (5%) from the last accepted one;
- **basis band** — Chainlink and mark must not diverge more than a published band (1%);
- **feed sanity** — a feed reporting impossible decimals or an unusable answer is treated as broken.

A breach of any of these **pauses minting only**. Redemption continues on the published last-good
procedure. Again: mint pauses, redeem never does.

One residual, recorded rather than hidden: the mark price is written by an attester with **no
timestamp**, so nothing on-chain can tell a fresh mark from a stale one. The band fails closed only
incidentally. It is in the deployment checklist as an operational assumption about the attester's
cadence, not as a contract guarantee.

---

## 8. How you check we are solvent

This is the promise the whole product rests on, so here is precisely what it is and is not.

`CertVault.solvency()` returns eight numbers, and **there is no code path that returns backing
without also saying how old it is and whose attestation it rests on**:

| Field | Meaning |
| --- | --- |
| `supply` | Certificates outstanding |
| `notional18` | The perp position's notional value, from the attestation |
| `margin18` | Margin at the venue, from the attestation |
| `buffer18` | Collateral the vault **actually holds** — an ERC-20 balance. Ground truth |
| `deltaBps` | How far from perfectly hedged, in basis points |
| `provenAtBatch` | Which Lighter batch this rests on |
| `ageSec` | **How old it is, in seconds** |
| `accrual18` | The P&L ledger — funding, execution variance, realised basis |

Two of those fields used to be one, published as "the buffer", and it was the ledger. That was
wrong in a way worth understanding, because it is the most instructive bug in the project: a ledger
that accumulates claimed P&L is **not** a pile of money. Measured, they drifted from 100,000.01
published against 91,028.00 actually held after a single mint-and-redeem cycle. And because an
attester writes the ledger, it could be declared outright — 500,100,000.01 published against
91,028.00 held. Now the two are separate fields with honest labels: one is a balance, one is a
claim.

### What "verifiable" means in C1 — and what it does not

Lighter is a zk-rollup. Its account tree — every account's balances, positions and funding — is
merkleized, its root is committed on-chain and zero-knowledge-verified every batch, and it is
**fully reconstructible from the blob data posted on-chain**. That is the foundation.

- **C1, what we ship now:** an attester rebuilds that tree from public blob data and posts the
  figures. Anyone can rebuild it too and check us, today, with no new contracts. The submitter is a
  single key, and the contract does not verify the arithmetic. Honest phrasing:
  **"independently verifiable every batch (~60s)."**
- **C2, next:** the Merkle path is verified *inside* `attest()`, in Solidity, against Lighter's own
  on-chain verified root. Then the contract itself refuses bad backing. Honest phrasing:
  **"proven on-chain every batch (~60s), age published."**

The engineering for C2 is scoped: Poseidon2 over the Goldilocks field, one permutation per Merkle
node, an estimated 400–650k gas for a depth-32 path — cents on an L2, once per batch per asset.
That estimate is analytical, from round structure and opcode costs, and is flagged as needing a real
measurement before we commit to it.

**Never "provable every block", at any stage.** Positions live inside the rollup; the chain sees
roots and blobs. About 60 seconds is the floor, and we publish the age instead of hiding it.

If the attester key is lost, minting eventually stops but **redemption is untouched** — no
redemption path reads an attestation for any gate. And the key is repairable: governance proposes a
replacement and anyone can install it once an immutable 2-day notice period elapses. If the key is
*compromised*, the immediate response is one transaction, `setAbsoluteCap(vault, 0)`, which shuts
new minting instantly while rotation serves its notice separately.

---

## 9. How big this can get

Here is the uncomfortable fact we designed around rather than around which we marketed. Live market
data, 2026-09-07:

| Market | Open interest | Daily volume | Fees |
| --- | --- | --- | --- |
| TSLA | ~3,353 shares (~$1.19M) | $1.81M | **0% maker, 0% taker** |
| NVDA | ~12,389 shares (~$2.88M) | $2.09M | **0% maker, 0% taker** |

**These books are thin.** A vault of any real size becomes a dominant share of the open interest,
which moves the price it is hedging into and distorts the funding it depends on.

But the market is expected to grow, so capacity is written as a **formula, not a constant** — no
redeploy, no migration, no hardcoded ceiling:

```
maxNotional(asset) = min(
    depthBps × openInterest(asset),   ← scales automatically as the market grows
    absoluteCap(asset),               ← a governance ceiling, itself under an immutable bound
    bufferCapacity(asset)             ← what the vault's own capital can actually absorb
)
```

Each leg matters:

- `openInterest` comes from the same per-batch attestation that feeds solvency, so it is derived
  from chain data rather than self-reported.
- `depthBps` starts at **10%** and governance can tune it only inside immutable bounds
  (1%–30%). Governance can never remove the cap.
- `bufferCapacity` is itself `min(collateral the vault holds × 100, the accrual ledger's claim)`.
  The first term is an ERC-20 balance minus what is owed to queued receipts — it cannot drift and
  no attester can move it. The second is kept only under the `min`, so an attester can make the
  vault more conservative but can never admit a mint that real collateral does not support.

That last point was an audit fix. Before it, two of the three legs were attester-written *in the
direction that widens capacity*, and only one real bound survived.

**What this means concretely: C1 is a capped pilot.** At 10% of a $1.19M TSLA book, that is roughly
**$120,000 of uTSLA**. The launch copy has to say so. A solvency dashboard showing a $120k vault
next to marketing about the deepest book on-chain is worse than saying nothing at all.

The route to size is `perpRFQ` — market makers quoting large blocks off-book, which both markets
support. It needs address whitelisting, so it is a C2 item, and it is the main reason capacity can
rise faster than visible order-book depth.

Capacity, utilisation, `depthBps` and live open interest all go on the public dashboard next to the
solvency figure. Capacity is a fact about the market, not an embarrassment.

---

## 10. Funding: who pays to hold the hedge

A perpetual futures position pays or receives **funding** continuously, depending on which side the
market is crowded on. Over a year that is a real cost or a real income, and somebody has to carry
it.

The design: positive funding **fattens a buffer**; negative funding **draws it down**; past a
published threshold it becomes a published, capped holding fee. Four thresholds are published —
`floor`, `fee_on`, `mint_slow`, `insurance_draw` — and they are configurable per asset, so a
$100k floor is not applied to a $1.19M book by accident.

**Now the honest part, because the code does not do the graduated version.** In C1:

- the holding fee rate is **computed and published, and nothing charges it**;
- `mint_slow` tapers nothing — the instant cap is fixed deploy config with no setter;
- `insurance_draw` is a published number with no consumer until the staking token ships in C3.

So what actually happens as the ledger degrades is: **nothing at all** — until it crosses zero, at
which point capacity goes to zero and **new minting halts outright**. A cliff, not a ramp. The
thresholds are *signals* in C1: readable views and an event. Wiring the fee and the taper is C2
work.

We labelled this rather than quietly shipping the softer-sounding description, because the original
text ("drops as buffer health degrades") described behaviour that did not exist anywhere in the
code.

And through all of it: **no redemption path reads any of this, at any level, ever.**

---

## 11. What can go wrong

| Failure | What happens |
| --- | --- |
| Our servers are compromised | **No off-chain key can trade or withdraw.** Worst case is griefing functions that anyone can call anyway |
| All our services go offline | Instant mint and redeem keep working — they are self-contained transactions. Delta drifts until someone claims the `rebalance()` bounty. `forceExit` keeps redemption open |
| Oracle goes stale or prints something deviant | Minting pauses. Redemption uses the published last-good procedure. Nobody is trapped |
| Chainlink and the venue's mark diverge | Minting pauses; the realised basis goes to the ledger; the band is published |
| The venue's deposit cap is hit | Minting pauses with a clear reason. Redemption unaffected |
| The sequencer censors our requests | 14-day expiry, then anyone freezes the rollup and holders exit against posted data |
| The market is delisted or halted | Per-asset wind-down: minting off, position closed, redemption continues against margin |
| The attester key is lost | Minting eventually stops; **redemption never depended on it**. Rotate behind the 2-day notice |
| The attester key is compromised | One transaction sets capacity to zero. What the key can do is already ceiling-bounded, and the ledger can only ever tighten capacity |
| The feed prints an absurd price | Every valuation is now a total function. No price can revert a redemption |
| The buffer is exhausted | New minting stops; **every redemption path stays open**. Holder backing is never touched (that is what the junior tranche is for, in C3) |
| The position gets liquidated | **This is the one that actually hurts**, which is why margin is ~1.1× and the bound is a constant with no setter. §5 |

The last row is the honest answer to "what is the real risk here". Not a hack — a market event that
force-closes the hedge while holders still have claims.

---

## 12. What we deliberately did not build

A shorter list than the built one, but it explains more.

**No trading key.** The vault places its own orders through an on-chain call. There is no bot with
authority to trade, so there is nothing to steal. An earlier design revision had exactly that bot,
based on the venue's *documentation* saying a contract could not open a position. Reading the actual
contract source disproved it: the order function is `external`, accepts both directions, and derives
the account from the caller. The design got materially simpler and more trustless as a result.

**No pool wrapper.** We considered running inside a Lighter "Public Pool", whose accounts
structurally cannot withdraw. Attractive, but pool operators are whitelisted by the protocol, the
operator must hold a minimum share, and pools have no isolated margin. Since a contract can hold its
own account, we get something better than "the trading account cannot withdraw": **no separate
trading account exists at all.**

**No owner, no pause, no upgrade.** Every address is immutable except the two attesters, and those
rotate only through an immutable 2-day notice period. This is why the deployment checklist exists
and is normative: a property this design holds *because of an assumption made at deploy time* cannot
be repaired later. Getting one wrong means redeploying.

**No FIFO redemption queue.** Deliberately. Forcing receipts to be claimed in order would let one
absent holder block everyone behind them — which would breach the redemption law rather than
protect it.

**No reduce-only or IOC orders**, because the venue's on-chain path does not offer them.
Correctness has to come from the vault's own sizing instead.

---

## 13. What we found by attacking it ourselves

This section exists because it is the strongest thing we can say about the code. A clean audit
report proves less than a detailed record of what was broken and how it was found.

### The external audit

An independent review found **2 Critical, 2 High, 6 Medium and 9 Low findings, plus 2 attacks that
broke through the test suite**, and delivered them as runnable proof-of-concept tests in the repo.

Every finding is now closed except two, both documented and accepted:
one is a redemption staleness property that is a deliberate consequence of the never-gate-redemption
law, and one is a magnitude bound that is unsatisfiable while the auditor's own tests require the
unbounded behaviour — the harm was closed a different way instead, by backing the published buffer
with a real balance.

Two of the auditor's tests **still fail, and we left them byte-identical on purpose.** Both
demonstrate a bug by exercising it, so once the bug is fixed they fail one line *earlier* than their
own assertion:

| Test | Now fails with | Why that is the proof |
| --- | --- | --- |
| `test_A1` | `CertVault_AtCapacity()` | The cap now binds on the 12th of 20 mints, so the test cannot reach its overshoot assertion |
| `test_A3` | `CertVault_MintPaused()` | The mint the test needs to succeed is now correctly refused |

Each needs a one-line correction from the auditor. Editing an auditor's evidence to make it green is
not something the party being audited should do, so both properties are proven by separate directed
tests with the same numbers.

### The defects our own review waves found first

Before the external audit, internal whole-branch reviews found **six further Critical-severity
defects** the per-task reviews had all missed. The instructive ones:

- **A price the caller picks.** `settleMint` did not validate the fill price. `settleMint(id, 1)`
  minted **4.995 × 10²²** certificates against a $49,950 escrow.
- **A hedge with no margin.** The vault opened ~$355k of notional against **$1** of venue margin,
  and every test passed — because the mock did not enforce margin. When enforcement landed, **nine
  existing tests immediately reverted.** That is the measure of how real the gap was.
- **A gain that could never come home.** §6 covers it: owed 7,102.97, recallable 3,559.54.
- **Escrow stranded permanently.** Reproduced after 20 recall cycles *plus* a governance wind-down.
  The root cause is a nice piece of Solidity: the fix that made the money recallable was in the same
  function as the payout, and Solidity has no partial commit — so the reallocation rolled back
  every time the payout failed, which was precisely when it was needed.
- **A trim that made things worse.** The attested notional is unsigned, so a correction that
  flattened a dangling long *enlarged* a dangling short. Measured −1,403,641 → −2,246,668.
- **A wind-down that doubled the position.** `closeAll()` hardcoded the sell side. At the venue,
  a zero-amount order means "full position **size**" and leaves the *direction* to the caller — so
  the governance wind-down of last resort would have doubled a short instead of closing it.

### The lesson that showed up three separate times

Every time, the answer was the same: **the tests could not see it.**

1. The supply invariant measured the vault against **its own transcript**, so no over-mint could
   ever falsify it. The fuzzer had been reproducing a Critical continuously while reporting green.
2. The delta-1.0 law was **never asserted at all**, despite the spec promising it — and written
   literally it is *unfalsifiable*: it passed 8,192 fuzz calls during a $752 over-mint, because
   margin buys the notional and the naive sum double-counts.
3. **Foundry does not enforce the 24,576-byte contract size limit in tests**, so an undeployable
   contract sat green in a passing suite. `CertFactory` was **3,629 bytes over** and could not have
   been deployed to any chain that enforces the limit.

That last one had a structural cause worth knowing: a contract that can `new` another must carry the
other's entire creation code inside its own runtime code. `CertVault`'s creation code is 25,743
bytes — over the runtime limit on its own — so **no contract can ever deploy a `CertVault`**. No
leaner factory would have won that back. The factory became a registry, vaults are deployed by
script, and its margin went from **−3,629 bytes to +22,253**.

The suite now has four invariants, including one that measures backing against the venue's own
figures rather than the vault's arithmetic, verified at up to 150,000 fuzz calls.

---

## 14. Where it stands today

**Verified 2026-09-08 on branch `feat/contracts-c1`:**

| | Status |
| --- | --- |
| Tests | **258 total — 256 pass, 2 fail** (both the auditor's unsatisfiable PoCs, §13) |
| Invariants | 4, all passing, up to 1,500 runs × depth 100 |
| Contract sizes | All 7 under the limit. Largest is `CertVault` at 17,559 B (+7,017 B margin) |
| Audit findings | All closed except 2 documented-and-accepted |
| Commits since the audit landed | 14 |

**Built:** all seven C1 contracts, the mint and redeem paths in all their tiers, the margin split,
two-phase recall, two-phase refund, the capacity formula, the oracle guards, attester rotation, and
a normative deployment checklist.

**Not built yet:**

| | |
| --- | --- |
| All six off-chain services | Specified in an 8-task plan; no code |
| The deployment script | And it is now load-bearing, since the factory no longer deploys vaults |
| The published reconstruction tool | The thing that makes "independently verifiable" true for outsiders |
| On-chain proof verification | C2. Route and gas cost scoped; needs a real measurement |
| The holding fee and taper | C2 — currently published, not charged (§10) |
| `CERT` token and staking | C3 — the junior tranche |

**Open items that block specific things:**

- The venue's exact `baseAmount == 0` direction semantics need confirming against Lighter source
  (not in this repo). The conservative reading is what the tests model, so a vault correct against
  the mock is correct either way.
- The base-asset index and tick sizes for USDG must be read from the live contract; the API
  endpoints are gated.
- The buffer thresholds and the initial `depthBps` need fitting to real funding and open-interest
  history before mainnet.
- **An ABI break to communicate:** the factory's `VaultDeployed` event is now `VaultRegistered`. Any
  indexer watching the old topic must change. The front-end owner needs telling.

**And eight copy changes on the live front-end are blocking**, because the backend cannot ship
truthfully behind the current text: the "every block" solvency claim, the "no custodial stock token
exists" claim, the "first holdable stock tokens" claim, four borrowed market statistics from a
different chain, the redemption SLA, and the "C1 LIVE" badge on something that is not live.

---

## 15. Glossary

| Term | Meaning |
| --- | --- |
| **Certificate / uTSLA** | The ERC-20 you hold. Tracks one share of the underlying |
| **Delta 1.0** | Perfectly hedged: certificates × price exactly equals position notional |
| **Perp / perpetual** | A futures contract with no expiry, kept honest by funding payments |
| **Funding** | The continuous payment between long and short holders of a perp |
| **Margin** | Collateral posted at the venue to support a position |
| **IMR / MMR** | Initial and maintenance margin requirement — what you must post, and below what you get liquidated |
| **Hot buffer** | Collateral kept in the vault rather than at the venue, to settle instant redemptions |
| **Accrual ledger** | The running P&L record: funding, execution variance, realised basis. **Not** a pile of money |
| **Basis** | The gap between the Chainlink price and the venue's mark price |
| **Batch** | Lighter's settlement unit, roughly 60 seconds |
| **Attester** | The key that posts per-batch figures. Cannot trade, cannot withdraw, cannot widen capacity |
| **Priority request** | An on-chain instruction to the rollup, with a 14-day censorship deadline |
| **Desert mode / escape hatch** | The rollup-level freeze that lets holders exit against posted data if the sequencer stops |
| **EIP-170** | Ethereum's 24,576-byte limit on deployed contract code |
| **bps** | Basis points. 100 bps = 1% |

---

*Numbers in §4, §5, §7 and §9 come from the test fixture and from live market data on 2026-09-07.
Mainnet parameters are not final — see the open items in §14.*
