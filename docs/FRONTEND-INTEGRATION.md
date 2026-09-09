# UseCert — front-end integration guide

**Target:** Robinhood Chain **testnet, chain 46630** · deployment block 11,667,691 · commit `d75114f`

Everything you need to wire a UI to the live contracts. Addresses, ABIs and decimals come from
[`frontend/usecert-contracts.ts`](../frontend/usecert-contracts.ts), which is **generated** from the
Foundry artifacts and the address book — never hand-edit it:

```bash
forge build && python scripts/gen-frontend-abi.py
```

Companion documents: [HOW-IT-WORKS.md](HOW-IT-WORKS.md) for what the product is,
[TESTNET-RUNBOOK.md](TESTNET-RUNBOOK.md) for operating the deployment,
[DEPLOYMENT-CHECKLIST.md](DEPLOYMENT-CHECKLIST.md) (normative) for what the addresses guarantee.

---

## 0. Read this before you write any code

Four things in this system will produce a plausible-looking UI that is wrong. They are not edge
cases; you will hit all four.

### 0.1 `solvency()` returns **eight** fields, and two of them are not the same kind of number

```solidity
struct Solvency {
    uint256 supply;         // certificates outstanding
    uint256 notional18;     // perp position notional, FROM THE ATTESTATION
    uint256 margin18;       // margin at the venue, FROM THE ATTESTATION
    int256  buffer18;       // ← the vault's OWN ERC-20 balance. Ground truth. SIGNED.
    uint256 deltaBps;       // distance from delta 1.0
    uint64  provenAtBatch;  // which venue batch this rests on
    uint256 ageSec;         // ← HOW OLD IT IS
    int256  accrual18;      // ← attester-relayed cumulative P&L. NOT money. SIGNED.
}
```

`buffer18` and `accrual18` **used to be one field**, published as "the buffer", and it was the
ledger. Measured drifting **100,000.01 published against 91,028.00 actually held** after a single
mint-and-redeem cycle — and because an attester writes the ledger, it could be declared outright
(500,100,000.01 published against 91,028.00 held).

So: render them as two different things. `buffer18` is collateral the vault holds. `accrual18` is a
claim about funding and execution variance that **nothing on-chain verifies**. Label the second as
unverified, or the UI reintroduces the exact defect the audit fixed.

Both are typed `int256`, but they are not symmetric. `buffer18` **cannot** be negative: it is
`SafeCast.toInt256(_to18(hotBuffer()))` over a `uint256` balance (`CertVault.sol:1568-1570`), so the
view reverts rather than publish a negative — do not build a "negative buffer" UI state, it is
unreachable. `accrual18` genuinely does go negative, meaning a net cumulative loss.

**And a negative `accrual18` silently turns minting off.** `BufferBook.capacity18` returns 0 when
`balance18 <= 0` (`BufferBook.sol:183-187`), which forces `vault.bufferCapacity18()` to 0, which
forces `maxNotional18` to 0. Collateral held is irrelevant to this: a vault sitting on $100,000 of
tUSDG will refuse every mint. Together with a stale `ageSec` (§0.2) these are the **two** reasons a
healthy-looking deployment refuses to mint, and this is the one with no visible symptom.

Never sum them. One is a stock, the other a flow-integral, and they are not commensurable — but the
decisive argument is arithmetic, not conceptual: `seedBuffer` (`CertVault.sol:595-598`) both
transfers collateral in **and** accrues `+_to18(amount)`, so the genesis seed appears in `buffer18`
and in `accrual18` at once. On the live deployment that is why both read ~$100,000 per mirror.
Adding them double-counts the same dollars.

### 0.2 `ageSec` must be on screen wherever backing is

There is no code path in the vault that returns backing without also returning its age. That is
deliberate. A solvency figure with no age is the claim this project spent the most effort not
making — the honest phrasing is *"independently verifiable every batch (~60s), age published"*,
never *"provable every block"*.

If `ageSec` exceeds `maxAttestationAgeSec` (**300 s** here), capacity is zero and minting is off.
That is the single most likely reason a healthy-looking deployment refuses to mint.

### 0.3 `basisBpsChecked()` returns a **tuple**, and the boolean is the point

```solidity
function basisBpsChecked() external view returns (bool known, uint256 bps)
```

`known == false` means **there is no independent basis to compute** — the deployment declared its
feed and the venue mark to be the same source. That is categorically different from `bps == 0`,
which means "two independent sources agree exactly".

Read only the number and you silently turn *"unverifiable"* into *"perfect"*. Use `basisBps()`
(which reverts `CertOracle_NoIndependentBasis` in single-source mode) only if you want the revert.

This deployment has `singleSource: false`. But note the address book's own caveat: on testnet that
independence is **organisational** (two keys) rather than economic — both keepers are operated by
the same party. It is not evidence about mainnet.

### 0.4 Four decimal domains, and mixing them is the largest hidden cost

| Value class | Decimals | Examples |
| --- | --- | --- |
| Collateral | **6** | `amountIn`, `amountOut`, `hotBuffer()`, `TestUSDG` balances, `postedMargin`, `marginExcess`, `totalOwedOutstanding` |
| Certificate | **18** | `certIn`, `certOut`, `uTSLA`/`uSPY` balances, `supply` |
| Prices and 18-dec figures | **18** | `px()`, `*Px18`, `notional18`, `buffer18`, `accrual18`, `instantCap18`, `freeCollateral18()`, `bufferCapacity18()`, `maxNotional18()` |
| Feed answers | **8** | `ReplayAggregator.latestRoundData().answer` |
| Basis points | 10 000 = 100% | `deltaBps`, `mintFeeBps`, `basisBandBps` |

`CertVault` reads its collateral's `decimals()` **once, at construction, into an immutable**. Six is
not a detail — a wrong value puts every published figure out by 10¹² with no repair short of
redeploying and reissuing the certificate token.

**The trap:** `mintInstant(amountIn)` takes **6-decimal collateral** and returns **18-decimal
certificates**. `redeemInstant(certIn)` is the reverse. A single shared `formatUnits(v, 18)` helper
across the app will be wrong on roughly half your numbers.

### 0.5 `bufferCapacity18()` is not the capacity, and cannot drive a progress bar

Three legs gate a mint, and `CapacityOracle.maxNotional18` takes the **minimum** of them
(`CapacityOracle.sol:89-99`): a depth leg (`depthBps` x attested open interest), an absolute cap
(`absoluteCap18`), and `vault.bufferCapacity18()`. Only the minimum matters, and on this deployment
the buffer leg is never it. Measured on chain 46630:

| | `bufferCapacity18()` | `absoluteCap18` | **binds** |
| --- | --- | --- | --- |
| uTSLA | $9,999,004 | $90,000 | **$90,000** |
| uSPY | $9,999,900 | $5,000,000 | **$5,000,000** |

So `bufferCapacity18()` overstates uTSLA's real room by **111x**. It is also not "headroom": it is a
notional-exposure ceiling, `min(freeCollateral18() x 100, max(0, accrual18) x 100)`
(`CertVault.sol:563-569`), and it **rises** as the vault mints, because `_postMargin` retains
`1 - targetMarginBps` of every mint as float (`CertVault.sol:1925-1931`).

**Do not build a fullness bar from it.** While the own-capital leg binds, the identity

```
freeCollateral18() / bufferCapacity18() == 1 / BUFFER_COVERAGE_MULTIPLE == 1.0000%
```

holds at *every* fill level by construction — verified to six decimals on both live mirrors. A bar
built on it is a constant that never reaches 100%. Pairing it with the 6-decimal `hotBuffer()`
instead is worse: that is the §0.4 trap, and it renders 0.0000% forever.

The one indicator that is bounded in [0, 1] and reaches 1 exactly when the contract reverts is
`_requireCapacity` itself (`CertVault.sol:1755-1771`):

```
used = max( (certificate.totalSupply() + vault.pendingMintCerts()) * oracle.px() / 1e18,
            vault.solvency().notional18 )
cap  = capacityOracle.maxNotional18(vaultAddress, vault.bufferCapacity18())
utilisation = used / cap        // CertVault_AtCapacity fires at exactly 1
```

`CapacityOracleABI` and `BufferBookABI` are exported from `frontend/usecert-contracts.ts` for this
purpose; the addresses are `SHARED.capacityOracle` and per-mirror `bufferBook`.

---

## 1. Setup

```
npm i wagmi viem @tanstack/react-query
```

`react-query` is likely already present. Import the chain definition rather than redefining it:

```ts
import { CHAIN, SHARED, MIRRORS, CertVaultABI, CertOracleABI,
         CertificateABI, TestUSDGABI, TestFaucetABI,
         SolvencyRegistryABI, DECIMALS } from './usecert-contracts';
```

**Gate the whole app on chain 46630** and offer a switch. Do **not** add mainnet (4663) to the
chain list — that chain ID has never been verified from this repo, and pointing a UI at an
unverified chain ID is how a user signs against the wrong network.

If the app is server-rendered (TanStack Start), the wallet connector must be client-gated — it
touches `window.ethereum`.

---

## 2. Addresses

Import them; do not paste them. Every deployment produces a **new vault and a new certificate
token**, so a hardcoded address silently points the UI at a dead token while real balances sit
elsewhere.

| Shared | Address |
| --- | --- |
| TestUSDG (collateral, 6 dp) | `0xA8e07CEB71d8c0A5728c6BEB84eDC6Bb135BEb72` |
| TestFaucet | `0x8d2cc305eFC069e32d089Da2E56d61d057AcD1dC` |
| SolvencyRegistry | `0xC7EDB3563F5b193408a9C3Ad6D7455f3246cD66B` |

| uTSLA — market 16 | uSPY — market 26 |
| --- | --- |
| vault `0x76A76B1dbc252C2c17698A9aB0a0143dAabCE9Cc` | vault `0xc640348F977425A7cc4A38f4e4f0CADc69eB5a98` |
| cert `0xc216b649c6DcDa8f0dA0C202D2611d026D7e6e74` | cert `0x25E1eD7f992C23D5AE025B1216865dE165d02576` |
| oracle `0xB8195b7447d53349E3E69Bf800d3dD623104CDae` | oracle `0x1Fe58fdA586AbeCe2e8E6b8c8a02C8f40a23e450` |

**Do not wire `LighterSim` or the `ReplayAggregator`s.** Read prices through `CertOracle`, which
applies the staleness, deviation and basis guards; reading the aggregator directly bypasses all
three. Both are simulator scaffolding that disappears when the real venue arrives.

---

## 3. Screens

### 3.1 Overview / dashboard — reads only

One `solvency()` call per mirror gives you most of a dashboard. Multicall the rest.

| What to show | Call |
| --- | --- |
| Backing, delta, age | `vault.solvency()` — see §0.1 |
| Price | `oracle.px()` (18 dp) |
| Can users mint? | `oracle.mintAllowed()` |
| Basis | `oracle.basisBpsChecked()` — see §0.3 |
| Instant-redeem float | `vault.hotBuffer()` (6 dp) |
| Remaining mint capacity | `capacityOracle.maxNotional18(vault, vault.bufferCapacity18())` — **not** `bufferCapacity18()` alone, see below |
| Attestation freshness | `registry.ageSec(vaultAddress)` |
| Supply, user balance | `certificate.totalSupply()`, `.balanceOf(user)` |

`px()` **reverts** when the oracle is unhealthy (stale, deviant, bad feed). Handle that as a state,
not an error toast: it is the designed behaviour and it is why `pxUnguarded()` exists for the
redemption path.

### 3.2 Mint — the size fork is enforced on-chain, so mirror it in the UI

`instantCap18` here is **1 000 × 10¹⁸ = $1,000**. Read it from `vault.cfg()` rather than hardcoding.

```
amountIn (6 dp)  ≤ instantCap  →  mintInstant(amountIn)          one transaction
                 >  instantCap  →  requestMint(amountIn)          escrow + receipt
```

Both paths need an ERC-20 approval first:

```ts
await usdg.write.approve([vaultAddress, amountIn]);   // 6 decimals
await vault.write.mintInstant([amountIn]);
```

`mintInstant` **reverts** `CertVault_AboveInstantCap` above the cap, and `requestMint` reverts
`CertVault_BelowInstantCap` below it. Route on the amount before submitting or every large mint
fails at the wallet.

Expected certificates out, for a quote:

```
certOut ≈ amountIn × (10_000 − mintFeeBps) / 10_000 / px    // then scale 6 dp → 18 dp
```

`mintFeeBps` is **10** (0.10%). Show the fee; do not fold it silently into the rate.

**The request path is two steps and the second is not yours.** `settleMint(receiptId, fillPx18)`
is called once the fill is known — by a keeper, not the user. The UI's job is to show the receipt
as pending and then settled. If the settle window (**86 400 s**) expires unsettled, anyone may call
`stageRefund(receiptId)` then `refundMint(receiptId)` and the user gets the full escrow back. Both
are permissionless: **the UI can offer the user a button for their own refund.**

### 3.3 Redeem — three tiers, and the third is the product's whole claim

```
certIn ≤ instantCap  →  redeemInstant(certIn)     one transaction, paid from the hot buffer
certIn >  instantCap  →  requestRedeem(certIn)     burns now, pays by claim
any size, any state   →  forceExit(certIn)         permissionless, reads no health signal
```

`redeemInstant` reverts **`CertVault_UseQueuedRedeem`** when the hot buffer cannot cover the payout.
That is not a failure — it is the fast path declining. **Catch it and route to `requestRedeem`
automatically.** Presenting it as an error is the single most likely way to make a working
deployment look broken.

Queued and forced redemptions both return a `receiptId` and then need:

```ts
await vault.write.claimRedeem([receiptId]);
```

`claimRedeem` reverts `CertVault_AwaitingSettlement` if the money has not arrived from the venue
yet. **Retryable, not terminal** — the receipt stays claimable forever, and anyone may call
`vault.recallMargin()` to push it along. Show "awaiting settlement, retry" plus a
`recallMargin()` button; never mark the receipt failed.

Two documented timings to publish honestly, both from
[TESTNET-RUNBOOK.md](TESTNET-RUNBOOK.md): a queued redemption is **two batch round-trips**, one for
the close and one for the withdrawal — not one. And `recallMargin` reaches freed margin in **two
calls across a batch**, not one.

**Never gate `forceExit` on anything.** It reads no buffer level, no capacity, no `mintAllowed`, and
no governance state. That is Design Law 2 and it is the product's central promise.

### 3.4 Receipts — this screen cannot be built from reads

`mintReceipts(id)` and `redeemReceipts(id)` are public getters, but **receipt ids are not
enumerable on-chain**. There is no `receiptsOf(user)`. You must index events:

| Event | Meaning |
| --- | --- |
| `MintRequested(uint256 indexed receiptId, address indexed user, uint256 amountIn)` | open a pending mint |
| `MintSettled(uint256 indexed receiptId, uint256 certOut, uint256 fillPx18)` | it minted |
| `RefundStaged(uint256 indexed receiptId, uint256 marginReallocated, bool hedgeClosePlaced)` | refund armed |
| `MintRefunded(uint256 indexed receiptId, address indexed user, uint256 amountOut)` | escrow returned |
| `RedeemRequested(uint256 indexed receiptId, address indexed user, uint256 certIn, uint64 expiresAt)` | open a pending redeem |
| `ForceExited(uint256 indexed receiptId, address indexed user, uint256 certIn)` | forced exit opened |
| `RedeemClaimed(uint256 indexed receiptId, uint256 amountOut)` | paid |

`user` is indexed on the opening events, so `getLogs` filtered by user reconstructs a wallet's
receipts. `expiresAt` on `RedeemRequested` carries the venue's 14-day priority expiration — that is
the real worst case and it should be visible.

For a demo, indexing the last N blocks client-side is enough. For anything durable you want a real
indexer; that is the strongest argument for the backend the design spec specifies.

### 3.5 Getting collateral — the faucet, or nobody can mint anything

`TestUSDG.mint` is owner-gated to the deployer, so `TestFaucet.claim()` is **the only way a tester
obtains collateral.** Wire it prominently.

| | |
| --- | --- |
| Drip | **10 000 tUSDG** per claim (`10_000_000_000` at 6 dp) |
| Cooldown | **86 400 s** per address |
| Float | 1 000 000 tUSDG = **100 drips**, and there is no privileged refill — topping up is a plain ERC-20 transfer from the token owner |

Show `nextAvailableAt(user)` as a countdown. `claim()` reverts `TestFaucet_TooSoon` inside the
cooldown and `TestFaucet_Empty` when the float is gone — display the faucet's own balance so an
empty faucet does not present as "minting is broken".

### 3.6 Keepers panel — only two of these are real

`vault.recallMargin()` and `vault.rebalance()` are genuinely permissionless and a UI may offer them.
`rebalance()` reverts `CertVault_InBand` when there is nothing to do and
`CertVault_AlreadyRebalancedThisBatch` once per attested batch — both are normal states, not errors.

Everything else keeper-shaped (attesting, advancing venue batches, pushing the feed) is **operator
only** and cannot be called from a user's wallet. If the existing UI advertises five keepers with
run counts, four of them are fiction.

---

## 4. Decoding reverts

The contracts use **custom errors only** — no revert strings. The generated module includes every
error in the ABI so `viem` can decode them. Map the ones a user can actually hit:

| Error | What to say |
| --- | --- |
| `CertVault_UseQueuedRedeem` | *Not an error.* Route to `requestRedeem`. |
| `CertVault_AwaitingSettlement` | "Funds still arriving from the venue — retry, or call `recallMargin`." |
| `CertVault_AtCapacity` | "This vault is at capacity." Show `capacityOracle.maxNotional18(vault, vault.bufferCapacity18())`, **never** `bufferCapacity18()` — the latter reads ~$10,000,000 on the live uTSLA mirror while the vault refuses a $100 mint. |
| `CertVault_MintPaused` | "Minting paused: the oracle is unhealthy." Redemption still works — say so. |
| `CertVault_AboveInstantCap` / `BelowInstantCap` | A routing bug in the UI, not a user error. |
| `CertVault_SettleWindowExpired` | Offer `stageRefund` → `refundMint`. |
| `CertVault_RefundNotStaged` | Call `stageRefund(receiptId)` first — permissionless. |
| `CertVault_ZeroAmount` | Amount rounded to zero after fees and venue quantisation. |
| `TestFaucet_TooSoon` / `TestFaucet_Empty` | Countdown / "faucet needs topping up". |

`CertVault_OnlyGovernance` and `CertVault_OnlyAttester` should be unreachable from a UI. If a user
sees one, the app called an operator function.

---

## 5. Live parameters

Read these from `vault.cfg()` and the oracle rather than hardcoding. Recorded here so you can sanity-check.

| Parameter | Value | Note |
| --- | --- | --- |
| `instantCap18` | `1_000e18` | the size fork |
| `mintFeeBps` / `redeemFeeBps` | 10 / 10 | 0.10% each |
| `settleWindow` | 86 400 s | then refundable |
| `settleBandBps` | 500 | fill-vs-request price band |
| `targetMarginBps` | 9 000 | ~1.11× leverage |
| `stalenessSeconds` | 900 | **testnet only** — mainnet is 93 600 |
| `deviationBps` | 500 | |
| `basisBandBps` | 500 | testnet; mainnet reasoning sets 150 |
| `maxAttestationAgeSec` | 300 | past this, capacity is 0 |
| `depthBps` | 1 000 | vault ≤ 10% of open interest |
| uTSLA cap | `90_000e18` | **$90 000** |
| uSPY cap | `5_000_000e18` | **$5 000 000** |

---

## 6. Copy that must change before this ships

Nine blocking items. Eight are from the design spec; the ninth exists because of what this
deployment actually is.

1. **"provable on chain every block"** → *"proven on-chain every batch (~60s), age published"*.
   Needs `provenAtBatch` and `ageSec` in the data model first — it is not a string edit.
2. **"NO CUSTODIAL STOCK TOKEN EXISTS ON ROBINHOOD CHAIN"** — remove. Robinhood Stock Tokens are live.
3. **"THE FIRST HOLDABLE STOCK TOKENS"** — remove. False on this chain.
4. **`$213B` / `32.2%` / "RWA OI passing Bitcoin" / "23 of top 30"** — Hyperliquid figures, not this
   chain's. One is baked into a live route slug, so this is not a string edit either.
5. **"Deposit USDC"** — the collateral is USDG on mainnet and tUSDG here. Say so.
6. **"REDEMPTION: Always, at oracle price"** — needs the real SLA: one batch expected, **14 days**
   worst case, then the rollup escape hatch.
7. **Honest Boundaries** must name Chainlink-vs-mark basis risk, single-venue dependency, and
   ~60 s solvency latency.
8. **"C1 LIVE"** — not live until C1 ships.
9. **A prominent "simulated venue" banner.** Every number this dashboard shows on testnet is
   **simulator output** — the real venue does not exist on chain 46630. The attester reads true
   position out of a simulator we control, which makes **testnet solvency stronger than mainnet's**.
   Rendering that under copy saying "provable on-chain" and "you never have to take our word for it"
   is the most misleading thing this UI could do.

---

## 7. What is deliberately not here

- **No mainnet chain config.** Chain 4663's ID has never been verified from this repo.
- **No `LighterSim` or aggregator bindings.** Read through `CertOracle`.
- **No staking.** `InsuranceStaking` and `CERT` are C3 and do not exist. Any staking screen maps to
  no contract.
- **No `FeeVault`.** Also unbuilt.
- **No lifecycle scripts.** The consuming repo is monitored for having no `postinstall`/`prepare`
  and no CI, deliberately. That is why this is a committed generated module and not a package with
  a codegen hook.
