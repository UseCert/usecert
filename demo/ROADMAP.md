# UseCert — roadmap to mainnet

Ordered so the cheap things land first. Effort is **S** (under an hour), **M** (half a day
to a day), **L** (multi-day, or blocked on a decision or on infrastructure).

Derived from `INTEGRATION-STAGE2.md §7`, `INTEGRATION-STAGE3.md §4`, and a review of
`frontend/testnet-wiring` on 2026-09-21. **Several items those documents list are already
done** — the `USDC` sweep is 90% complete, `StakingView` / `KeepersView` are removed, and
the flow list now reads Blockscout. They are not repeated here.

---

## Phase 0 — quick wins on the current branch

All small, all independent, none blocked on anyone. **0.0 is a one-line fix and it is the
most urgent item in this document.**

### 0.0 `SolvencyRegistryABI` is used but never imported — **S** — ✅ done 2026-09-21

`src/chain/useActions.ts` references `SolvencyRegistryABI` at lines **477** and **493**, inside
`refreshAttestationIfStale()`. It is not in the import list and not declared in the file. The
branch does not typecheck:

```
src/chain/useActions.ts(477,12): error TS2304: Cannot find name 'SolvencyRegistryABI'.
src/chain/useActions.ts(493,12): error TS2304: Cannot find name 'SolvencyRegistryABI'.
```

At runtime this is a `ReferenceError`, and `mint()` **awaits** `refreshAttestationIfStale()`
before it routes — so every mint throws before a transaction is ever submitted. Introduced in
`4b0fbfa`, the commit that added the relay.

Nothing caught it because the two failures mask each other: attestations are stale (2.1), so
`CapacityOracle` returns a cap of zero, so the mint button is disabled, so the broken path is
never entered. Fix 2.1 alone and minting reopens straight onto this. Found by driving the
mint with capacity forced open, and confirmed with `tsc --noEmit`.

```
 import {
   CertVaultABI,
   CertificateABI,
   SHARED,
+  SolvencyRegistryABI,
   TestFaucetABI,
   TestUSDGABI,
 } from "./contracts";
```

**Also add a typecheck to CI.** `vite dev` and the rolldown build do not run `tsc`, which is
why a branch with two TS2304 errors was recordable and deployable. `npx tsc --noEmit` catches
this class of bug in seconds. See 3.4.

### 0.1 Pin the relay's contract address — **S** — ✅ done 2026-09-21

`src/chain/useActions.ts:491` sends the relay transaction to `a.registry`, taken from the
`/api/attestations` JSON, instead of the pinned `SHARED.solvencyRegistry`. The `ageSec` read
six lines above uses the pinned constant, and `attestationFor()` already validates `a.vault`
against the local mirror list — so this is the one field in the payload that is trusted
without checking.

Not a drain path: the calldata is fixed to `attestSigned`, which is nonpayable, and users
hold no allowance to the registry. But whoever controls that endpoint can point a user's
signed transaction at an arbitrary contract, and there is no reason to allow it.

```
address: SHARED.solvencyRegistry,   // and drop `registry` from SignedAttestation,
                                    // or assert equality and bail on mismatch
```

### 0.2 Fix the mobile horizontal scroll — **S** — ✅ done 2026-09-21

Five `whitespace-nowrap` classes replaced width constraints. Measured at 375×812 on the
branch tip: `document.scrollWidth` is **650px against a 375px viewport — 275px of sideways
scroll**, and three headings render clipped.

| File | Rendered width |
|---|---|
| `src/components/Footer.tsx:116` | 634px ← drives the page overflow |
| `src/pages/home/Testimonials.tsx:42` | 407px |
| `src/pages/home/Testimonials.tsx:48` | 605px content in a 343px box |
| `src/pages/home/Faq.tsx:44` | 364px |
| `src/pages/home/WhyUseCert.tsx:15` | 441px content in a 343px box |

The intent — one line on desktop — only needs to apply above the breakpoint. Use
`lg:whitespace-nowrap` and restore the `max-w-[Nch]` each of these previously had.

### 0.3 Real provenance in the generated bundle — **S** — ✅ done 2026-09-23

`src/chain/contracts.ts:5` read `Deployment: block 11746408, commit signed-attes` — a
truncated placeholder where a commit hash belongs. The `commit` field is whatever `COMMIT=`
was set to at deploy time (`DeployTestnet.s.sol:1218`), so it accepts any string; the string
it carried was `signed-attestation`, and `[:12]` rendered it as `signed-attes`. Twelve
lowercase characters in the slot where a commit prefix goes reads as a commit prefix.

Fixed in the generator, which now prints three facts the address book cannot set:

```
// Deployment:   block 11746408
// Address book: deployments/46630.json, sha256 4753f2955d93 (first 12)
// Deployed at:  unrecorded (address book carries 'signed-attestation', which is not a commit hash)
// Generated at: commit <git sha>[-dirty]
```

`Generated at` comes from `git rev-parse HEAD` in the generator and is marked `-dirty` when
the tree has uncommitted changes, so a non-reproducible build says so. The address-book
digest pins the exact address set and is recomputable with `sha256sum deployments/46630.json`.
`Deployed at` prints only when the book holds something matching `^[0-9a-f]{40}$`, and
otherwise says it is unrecorded and quotes what it found — the two commits are different
facts, and truncating a label into the shape of a hash is how the old line came to be wrong.

**The deploy-time half is still open**: recording a real commit there means setting `COMMIT`
to `git rev-parse HEAD` when the deploy script runs. Until then the header honestly reports
it as unrecorded rather than inventing it.

### 0.4 `cert-plate-uspy.jpg` — **S → blocked on artwork**

`src/chain/useVaults.ts:177` points uSPY at `/logo.png` with `imgPlaceholder: true`. Every
other routed vault has a plate in `public/`.

**Not a code item, and not an S.** There is no uSPY plate and there never has been — no file
matching `*spy*` exists in either repo, and `git log --all --diff-filter=A -- 'public/cert-plate-*'`
lists only `uaapl`, `unvda`, `uqqq`, `uspx` and `utsla`. The obvious candidate does not work:
`cert-plate-uspx.jpg` is engraved **uSPX**, "MICRO S&P 500® INDEX", serial `USPX-10-000518`
— the abandoned uSPX mirror's certificate, not uSPY's. Shipping it would put another
certificate's ticker and serial on uSPY's artwork, which is exactly what the comment at
`useVaults.ts:158` forbids.

The code side is already correct and is not what is missing: `imgPlaceholder` is true, the
neutral mark is used, and both surfaces that render it say why in plain words
(`VaultsView.tsx:128`, `MintRedeem.tsx:881`). What is missing is one image in the same
register as the other four. Either commission it, or decide uSPY ships with the neutral mark
and drop the item.

---

## Phase 1 — the honesty sweep

The remaining copy gaps. Most are small edits; two need an editorial decision about what the
project claims, which is why they have sat.

### 1.1 Finish the collateral rename — **S** — ✅ done 2026-09-23

All four occurrences of `USDC` outside the dashboard now read `tUSDG`:

- `src/pages/home/HowItWorks.tsx` — "LP uTSLA against tUSDG"
- `src/pages/home/Testimonials.tsx` — "LP'd it against tUSDG"
- `src/pages/learn/data.ts` — "cannot be LP'd against tUSDG"
- `src/pages/roles/RolesAccordion.tsx` — "build uTSLA/tUSDG pairs"

`tUSDG`, not `USDG`. These were first written as `USDG` on the reasoning that they describe
what a certificate composes with, which on mainnet is USDG — and reading the deployed pages
showed that was wrong. Every neighbouring sentence on those same pages already says `tUSDG`
("Deposit tUSDG", "plus tUSDG margin", "redeems to tUSDG"), so "deposit tUSDG" followed by
"LP against USDG" invites a reader to think there are two stablecoins here. The site
describes this deployment; on this deployment there is one, and it is `tUSDG`.

The one deliberate `USDG` outside the dashboard is `src/pages/Roadmap.tsx` — "Mainnet uses
USDG" — which is a statement about mainnet and is correct.

### 1.2 Drop "the first holdable stock certificates" — **S** — ✅ done 2026-09-23

`src/pages/Learn.tsx:40`. False on this chain — Robinhood Stock Tokens are live (see 1.3),
and nothing here has reached mainnet, so there is no first to claim.

**Three more of the same claim were not in the item and are also gone**, because correcting
one instance of a false claim while three identical ones stand is not a correction:

- `src/pages/Learn.tsx:40` — "the first holdable stock certificates" → "holdable stock certificates"
- `src/pages/roles/Hero.tsx:10` — "the first stock certificates" → "stock certificates"
- `src/pages/home/Testimonials.tsx:19` — "the first equity-shaped asset on Robinhood Chain" → describes the asset instead of ranking it
- `src/pages/roles/RolesAccordion.tsx:34` — "the first equity-shaped asset … before everyone else's" → the same, without the race

### 1.3 Resolve the custodial-token claim — **M** *(editorial)*

"No custodial stock token exists on Robinhood Chain" is body copy at
`src/pages/home/TheGap.tsx:79` and a tooltip title at `src/pages/home/Compare.tsx:146`.
Robinhood Stock Tokens are live, so the claim is wrong — but `Compare.tsx` builds an entire
comparison column on the premise (`{ name: "Custodial Stock Tokens", … }`). Removing the
sentence means deciding what that column becomes. That is the actual work; the string edit
is trivial.

### 1.4 Reattribute the market figures — **M** *(editorial)*

`$213B`, `32.2%`, `$3.6B`, `23/30`, `52%` are presented as Robinhood Chain's. They are
Hyperliquid's:

- `src/pages/about/Stats.tsx:7` — animated counter
- `src/pages/about/Story.tsx:12` — "Robinhood Chain did $213B … out-trading Bitcoin"
- `src/pages/home/TheGap.tsx:7` — "$213B … on Robinhood Chain … 32.2% of all chain volume"
- `src/pages/home/WhyNow.tsx:15`
- `src/pages/home/Research.tsx:10` and `:13`
- `src/pages/learn/data.ts:35` — **baked into a live route slug**, `rwa-perps-213b-none-holdable`

The slug is the reason this needs a decision rather than a find-and-replace: changing it
breaks an existing URL.

### 1.5 Stop describing undeployed machinery in the present tense — **M/L** *(editorial)*

The largest remaining honesty gap. The buffer → `fee_on` → `mint_slow` → `insurance_draw`
cascade is written as live in `src/pages/home/Faq.tsx`, `src/pages/home/HowItWorks.tsx`,
`src/pages/Legal.tsx`, `FUNDING_PARA` in `src/pages/vaults/data.ts` and
`src/pages/learn/data.ts`. `src/pages/roles/TokenFlow.tsx:7` publishes "80% of protocol fees
go to open market token buyback" for a token that is not deployed.

The dashboard is already clean — its figures are live reads. This is the marketing surface,
and half-doing it leaves the site contradicting itself.

### 1.6 Finish the redemption SLA — **S** — ✅ done 2026-09-25

`home/HowItWorks.tsx` and `home/Compare.tsx` already carried it. Three other places described
redemption with no timing at all, each reading as an unconditional promise of immediacy:

| where | said | now also says |
|---|---|---|
| `home/Faq.tsx` | "redeemable at oracle price any time" | same transaction below the instant cap, queued and paid by claim above it |
| `roles/RolesAccordion.tsx` | "redeems whenever you want out" | the same cap distinction |
| `Legal.tsx` (terms of service) | "Redemption is never gated and settles at oracle price" | the full SLA — two batch round-trips expected, the venue's 14-day priority expiration as the worst case, and "queued is not refused" |

"Any time" was never wrong about *availability* — redemption really is never refused — but it
was silent about *speed*, which is the part a holder plans around.

**The rollup escape hatch turned out to be absent rather than half-written.** Nothing on the
site mentioned it. Rather than describe an Arbitrum Orbit mechanism this project has never
exercised, the terms now state the boundary, which is the part that is actually known:
`forceExit` is gated on nothing UseCert controls, but submitting the transaction at all
requires Robinhood Chain to include it, and that is the chain's concern, not something UseCert
can promise on its behalf.

Verified as served rather than by grep: `/legal/terms-of-service` carries the SLA, the 14-day
worst case and the boundary; the FAQ and Holder caveats are in the DOM on `/` and `/roles`.
Worth recording for next time — the How-it-works copy is inside an **accordion**, so a
collapsed row is absent from the server-rendered HTML. Grepping the page suggested the SLA was
missing there; expanding the row in a browser showed it rendering correctly. The grep was
measuring the wrong thing, not finding a bug.

---

## Phase 2 — make the app whole

### 2.1 Ship `/api/attestations` — **M** — ✅ done 2026-09-20 (the signer has been live since)

**This is the highest-value item in the document.** There is no API implementation anywhere
in the repo, and the endpoint 404s on the deployed host.

Observed against the live testnet on 2026-09-21: attestations were **~9.6 hours stale on all
four vaults**, every vault read `ATTESTATION STALE (>300S) · MINTING OFF`, the health chip
read `DEGRADED`, and the mint panel showed `MINTING HALTED · MINT CEILING IS ZERO`. Minting
is currently impossible protocol-wide.

`src/chain/attestation.ts` documents exactly this failure happening before, for 11.6 hours on
2026-09-20, when the attester wallet ran dry. The signature-relay design fixes the *cost*
problem — an idle protocol no longer pays to stay open — but it moves the liveness dependency
onto an endpoint that does not exist yet. Until it ships, `fetchSignedAttestations()` returns
`null`, no relay is ever sent, and mints revert `CertVault_AtCapacity`.

Needs: the signer service, key custody for the attester, the route, and monitoring on
`ageSec` so a stall pages someone instead of being discovered by a user.

### 2.2 An indexer for the series data — **L**

Narrower than the docs suggest: the flow list is solved (`src/chain/useFlows.ts` reads the
public Blockscout REST API directly, no proxy). Still missing and pointing at the same gap:

- solvency history — `Overview.tsx:346`, `VaultsView.tsx:230`
- funding history, the 48 hourly bars — `OverviewExtras.tsx:192`, `VaultsView.tsx:243`
- receipt enumeration — `MintRedeem.tsx:857`; there is no `receiptsOf(address)` on `CertVault`

### 2.3 Settle `bufferPct` — **S once answered** *(blocked on contracts)*

Stage 1 asked and stage 2 could not resolve whether `bufferCapacity18()` is remaining
headroom or total capacity. The bar is currently labelled by its formula with both absolutes
beside it. If it is headroom, the bar looks fullest exactly when the vault can accept no
more mints — the opposite of what a viewer will read.

### 2.4 `RiskView` stress table — **M**

Modelled analysis, not a chain read. The header hint says "Modelled, not measured", which is
honest, but the table should either be driven by real parameters or moved out of the
dashboard.

---

## Phase 3 — mainnet prerequisites

### 3.1 Close the C1 audit criticals — **L**

`src/pages/dashboard/Overview.tsx:200` records that C1 is an audit identifier and that the
audit "reported open criticals". Nothing ships to mainnet before those are closed and the
result is published.

### 3.2 Real collateral and a real venue — **L** — 🟡 mainnet targets now measured (2026-09-25)

Mainnet uses USDG, not `tUSDG`, and the `testFaucet` path disappears. `lighterSim`
(`0x563f…1c39`) is a simulator — on testnet `setMarkPrice()` creates any index implicitly,
which is why `basisBpsChecked()` returns `known == false`. Against a real venue that boolean
starts meaning something, and the UI needs to be correct when it flips.

**The venue is NOT missing on mainnet, and an earlier reading of this item said it was.**
`LighterSim`'s NatSpec records `cast code` returning `0x` on the candidate `ZkLighter`
addresses — that was measured on **testnet 46630**, and was generalised to mainnet without
being checked. Measured on **mainnet 4663** on 2026-09-25, everything the protocol needs is
already deployed:

| what | address | state |
|---|---|---|
| ZkLighter proxy | `0x94bab9693ba2f6358507effcbd372b0660afff9d` | 1,367 B |
| ZkLighter implementation | `0x82DE5B1161C93afDFE21bA0D5343f01Cd7401d90` | 23,168 B |
| USDG | `0x5fc5360d0400a0fd4f2af552add042d716f1d168` | symbol `USDG`, 6 decimals |
| Robinhood deposit router | `0x8062df5b3220ad1f528365650a3eb3e8c7b0dad1` | 1,367 B |

All four return `0x` on testnet, which is exactly why the simulator exists. USDG's 6 decimals
match what `CertVault` reads at construction.

**`ILighter` is correct against the real contract.** All seven selectors UseCert calls are
present in the deployed implementation — `addressToAccountIndex`, `deposit`, `createOrder`,
`withdraw`, `cancelAllOrders`, `getPendingBalance`, `withdrawPendingBalance` — and live view
calls against the proxy decode rather than revert. The ABI is not the risk.

**What remains is behaviour, not shape.** `LighterCore` is this project's *model* of Lighter's
semantics: asynchronous settlement, partial fills, order rejection, margin accounting. Matching
selectors say nothing about any of that, and the model has never met the real engine. It is
testable with one small real deposit, which is the cheapest way to find out and should come
before anything else in this item.

### 3.2b Every market index is wrong — **S, and blocking** — 🔴 found 2026-09-25

Read from Lighter's live market list on mainnet
(`mainnet.zklighter.elliot.ai/api/v1/orderBookDetails`, 235 active markets):

| mirror | deployed `marketIndex` | real `market_id` | had been recorded as |
|---|---|---|---|
| uTSLA | 16 | **112** | venue-verified |
| uSPY | 26 | **128** | chosen |
| uQQQ | 27 | **129** | chosen |
| uNVDA | 15 | **110** | venue-verified |

**All four are wrong, including the two this repo called verified.** TSLA 16 and NVDA 15 were
read from the venue's list on 2026-09-07; against the live venue they are not those markets.
The earlier reading has gone stale or came from a different instance. Nothing misbehaves on
testnet, where `setMarkPrice()` creates any index implicitly — which is precisely what let a
wrong index deploy clean and stay unnoticed.

`marketIndex` is immutable on `CertVault`, so correcting it is a redeploy per mirror, not a
setter. That work belongs to the mainnet deployment, where the real ids above are now known.

Also worth recording: **SPX exists on the real venue as market 42**, and `uSPX` was retired
from this project on the stated grounds that the venue had no SPX perp. That premise was true
of the simulator, not of Lighter.

Front end corrected the same day: `MARKET_INDEX_VERIFIED` is now `false` for all four and the
dashboard reads "venue market index verified 0/4" instead of 2/4, with the real ids published
in the caveat note.

### 3.3 Attester key custody and rotation — **L**

`SolvencyRegistry` has `AttesterRotationProposed` / `AttesterRotated` and a
`SolvencyRegistry_RotationNotDue` guard, so rotation exists on-chain. What is missing is the
operational side: where the signing key lives, who can rotate it, and what happens between
proposal and effect. Compounds with 2.1 — the whole mint path now depends on that signer.

### 3.4 Release provenance — **M**

No commits on this branch are signed, and there is no CI. Before mainnet: signed commits or
tags, a build that pins the contract bundle to a real commit hash (0.3), and a published
address book that a user can verify against the explorer.

---

### 3.5 Publish verified sources on the explorer — **S** — ✅ done 2026-09-25 (26/26)

Every contract in the deployment is now verified on Blockscout. `git grep` the address and
the explorer shows you the source it was compiled from.

**This item had been recorded as "mostly done — three remain". It was not.** That count only
ever considered the shared contracts and the uTSLA mirror. uSPY, uQQQ and uNVDA each have five
contracts and **none of their four core contracts were verified** — including the `Certificate`
tokens holders actually own. The true starting position was 14 of 26, not 23 of 26.

Twelve contracts verified this pass: `CertVault`, `CertOracle`, `Certificate` and `BufferBook`
for each of uSPY, uQQQ and uNVDA.

**Recovering the constructor arguments.** Neither broadcast file in this repo is usable — one
holds an Anvil run, the other the previous deployment — so the chain was the only source. For
`CertVault` and `CertOracle` the creation input is `creationCode || abi.encode(args)`, and the
artifact supplies the creation code, so the tail is the arguments.

`Certificate` and `BufferBook` could not be recovered that way at all: `CertVault` creates both
with `CREATE` from inside its own constructor (`CertVault.sol:465-466`), so their arguments
appear in no transaction's calldata. They were **derived** from values that are themselves on
chain rather than guessed — `Certificate(name_, symbol_, address(this))` where `name_` and
`symbol_` are the last two fields of the vault's own recovered arguments, and
`BufferBook(address(this), 200)` where 200 is a literal at the call site. That the explorer
accepted all six is the check on that derivation: a wrong argument fails to match the deployed
bytecode.

**Two measurement traps worth recording, because both produced a confident wrong answer.**

`is_verified` on the v2 API is not reliable. `TestUSDG`, and every `ReplayAggregator`, return
`is_verified: false` while the same endpoint serves their full source. Counting that flag gave
17 unverified when the real number was 12. Presence of `source_code` is the signal that matches
what a reader actually gets.

And the submission script reported **12 of 12 FAILED** while all twelve succeeded: it grepped
forge's output for "successfully verified", and a successful submission prints a GUID and a URL
instead. The status was only settled by re-reading the explorer, which is the thing that was
being claimed in the first place.

**Still outstanding:** Blockscout reports these as a **partial match**, so the metadata hash
differs even though the runtime bytecode agrees. A full match needs the exact compiler metadata
settings used at deploy. Keeping a real broadcast record for the live deployment would make the
next verification a one-liner, and is the same provenance gap as 0.3 and 3.4.
