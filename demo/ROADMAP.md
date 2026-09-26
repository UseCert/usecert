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

### 2.4 `RiskView` stress table — **M** — ✅ done 2026-09-25

Two halves, and only one had been done. The invented magnitudes were already gone — "−41% of
buffer" against a "−30% annualised funding" shock, none of it from a model anyone ran. What
remained was honest prose with **no numbers at all**, which is neither of the two outcomes this
item asked for: driven by real parameters, or moved out of the dashboard.

It is now driven by real parameters. Each row prints the threshold that decides it, read from
the contract that enforces it:

| row | threshold | source |
|---|---|---|
| Oracle stale or deviant | `900s` | `CertOracle.stalenessSeconds` |
| Gap in the underlying | `500 bps` | `CertOracle.basisBandBps` |
| Attestation goes stale | `300s` | registry / `maxAttestationAgeSec` |
| Redemption run | `$1K` | vault `cfg().instantCap18` |
| Accrual ledger / funding | `<= 0 (now $100K)` | `BufferBook.balance18` |

`stalenessSeconds`, `deviationBps` and `basisBandBps` had existed in this codebase **only as
prose in comments** while the table named them in sentences. They are now three more calls per
mirror — `CALLS_PER_MIRROR` 13 → 16 — because a threshold a reader cannot check is
indistinguishable from one that was made up.

The accrual-ledger row is deliberately not a magnitude: the threshold there is a *sign*, so the
cell reads `<= 0` with the live worst balance beside it as the distance to it.

Every mirror on this deployment is configured identically, so one number per row is honest —
but that is a fact about this deployment rather than a guarantee, so the helper checks and
prints "varies by mirror" if they ever diverge.

Verified two ways: the rendered table shows 900s / 500 bps / 300s / $1K / `<= 0 (now $100K)`,
and `cast call` reads 900, 500 and 500 directly from all four `CertOracle`s. The footnote now
points a reader at the contracts instead of asking to be trusted.

---

## Phase 3 — mainnet prerequisites

### 3.1 Close the C1 audit criticals — **L** — ✅ closed and published 2026-09-25

Two halves: close them, and publish the result. Both are done, and the publishing half was
the one still outstanding.

**Measured this pass**, not remembered — the suite was re-run to confirm the `DeployTestnet`
virtual seams added the same day changed nothing:

| suite | result |
|---|---|
| everything except the auditor's | **456 of 456 pass** |
| `AttackSuite` | **17 of 17 pass** |
| `AuditPoC` | **5 of 8 pass** — and all eight were written to FAIL |

The reported Critical (the overflow in `_queueExit`) is fixed. So is the EIP-170 blocker the
audit escalated, which would have left `CertFactory` undeployable on any chain — closed by
making it a registry rather than a deployer.

**The three failures are not equivalent, and the site no longer lets them read as if they
were.** `test_A1` and `test_A3` fail by REVERTING during setup — `CertVault_AtCapacity` and
`CertVault_MintPaused` — which is the guard stopping the exploit before the assertion is
reached. The audit recorded both as left untouched by instruction.

`test_A5` is different and worth stating plainly: it fails on its own property,
`margin must be recallable without a queued receipt: 0 <= 0`. The audit's fix report claims it
passes, and it did — until the venue became **asynchronous** the day after. A single
permissionless `recallMargin()` cannot get the money home when the withdrawal is requested and
arrives later. **The margin is recoverable**, in two steps, and `test_recallMarginSubmitsAndSweeps`
in `CertVaultRecall.t.sol` proves it. What is lost is the one-call property, and with it the
absence of a keeper dependency the fix existed to remove.

Published on `/roadmap`: the milestone now carries the numbers and names the A5 distinction
instead of asserting "every critical finding is closed", which is true and tells a reader
nothing they can weigh. `Overview.tsx` also still described the audit as having open criticals
in the present tense; that is now dated.

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

### 3.4 Release provenance — **M** — 🟡 two of three done

Three parts, and they had very different shapes.

| part | state |
|---|---|
| A build that pins the bundle to a real commit hash | ✅ done — 0.3 |
| A published address book a user can verify | ✅ done 2026-09-25 — `/contracts` |
| Signed commits or tags, and CI | ⛔ needs a signing key and a decision that are Chris's |

**The address book found a worse problem than the one it was meant to solve.** The milestones
page told readers "every address is in the dashboard and on the explorer" as the way to check
that four mirrors are live. **No contract address was rendered anywhere on this site** — the
only address that ever linked to the explorer was the reader's own connected wallet. A
verification instruction that cannot be followed is worse than none: it borrows the credibility
of being checkable without supplying it. That line now points at `/contracts`.

`/contracts` lists all 26 with a link to each one's verified source. The addresses come from
the **same generated module the app transacts against**, not a list maintained beside it, so
the page cannot drift from the contracts the dashboard is actually using — which is precisely
the failure it exists to prevent. It also states the two caveats a reader would otherwise have
to discover for themselves: the partial-match status, and that no mirror's venue market index
matches the live venue.

Verified as served: 26 distinct addresses, 26 explorer links, and the set compared against
`deployments/46630.json` in both directions — nothing on the page absent from the book, nothing
in the book missing from the page.

**What remains is not code.** Signing needs a key and a decision about who holds it; CI is
excluded from the front-end repo by a deliberate, monitored property (no lifecycle scripts, no
CI), so any check has to live on the contracts side or in a separate runner.

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

---

### 3.6 Claims that derive from the deployment — **M** — ✅ done 2026-09-25

The word "testnet" appears 64 times in the front end, "tUSDG" 62 and "faucet" 82. Every one was
typed by someone who knew which chain they were on at the time. Switching to mainnet is a
one-file change — `contracts.ts` is regenerated and the chain id, RPC, explorer and all 26
addresses follow — but the **copy did not follow**, so the switch plan was a manual sweep of
~290 strings. That is not a plan, it is a list of things to forget under pressure.

`src/chain/deployment.ts` reads those facts from the generated bundle instead: which chain,
whether the venue is a simulator, whether a faucet exists, what the collateral is called,
whether anything holds real value, and the disclosure that follows from all of it. **Absence is
the signal** — `testFaucet` and `lighterSim` are null in the mainnet address book, and the
generator now omits null keys rather than writing the literal string `'None'` into the bundle,
which would have typechecked, read like an address, and been passed to a contract call.

**What building it both ways caught.** Against a mainnet-shaped bundle the app **failed to
compile**, with seven errors in four files. `SHARED` is a generated object literal, so
`SHARED.testFaucet` off-mainnet is not `undefined`, it is a type error — and nothing
typechecks against a bundle it never sees. So `claim()` now refuses with a named reason instead
of calling a contract that is not there; the three faucet reads are omitted rather than polling
a missing address every 20 seconds; and the TestFaucet and LighterSim rows on `/contracts` are
appended only where those contracts exist.

Verified both ways. Real bundle: unchanged, `tsc` clean, and the live site still reads
"Testnet 46630", still lists both rows, still carries the simulated-venue disclosure. Mainnet
shape: `tsc` clean, production build clean, and every derived value flips on its own — tUSDG
to USDG, the faucet sentence to "collateral you already hold or acquire", the disclosure to
empty because on mainnet it would be false.

Four surfaces are wired so far (the roadmap page, the connect prompt, the store's collateral
symbol, the Overview chip). The remaining literals are mechanical and follow separately; the
mechanism they need now exists, which is what 1.5 was actually blocked on.

---

## Phase 4 — from the launch-readiness audit, 25 September 2026

Full response in `demo/AUDIT-RESPONSE-2026-09-25.md`. Its verdict — no-go for mainnet,
promising testnet prototype — is accepted.

### 4.1 Security headers, source-controlled — **S** — ✅ done 2026-09-25

The audit reported no source-controlled CSP, HSTS, anti-framing, MIME-sniffing, referrer or
permissions policy. Half wrong about the **live site**, which already served HSTS, nosniff,
X-Frame-Options and Referrer-Policy — and entirely right about the **repository**, where none
of it existed. A header living only on one host is one bad reload from being gone.

`deploy/nginx/10-security-headers.conf` is now committed and installed. Added: **CSP** and
**Permissions-Policy**. Tightened: X-Frame-Options `SAMEORIGIN` → `DENY`, HSTS given
`includeSubDomains`. `preload` deliberately not set — a one-way door enforced by browser
vendors belongs in a decision, not a config change.

Every CSP source earns its place: the Google Fonts stylesheet and its files, the chain RPC,
and the Blockscout index `useFlows` reads directly. `frame-ancestors 'none'` is the one that
matters — it stops a clickjacking frame around a page asking people to sign transactions.
`'unsafe-inline'` on `script-src` stays and is documented as a real weakening: the hydration
payload is an inline script, and removing it needs per-request nonces through SSR.
`'unsafe-eval'` is **not** granted, so a connector that wants it fails loudly.

Installing it found two things review would not have: the old snippet was still included in the
same server block, which would have sent every shared header **twice**; and a location block
re-included the old file, which matters because nginx drops server-level `add_header` entirely
in any location that sets its own.

Verified as served on `/`, `/dashboard`, `/contracts`, `/api/attestations` and on a 404, with
no header sent twice, and the dashboard still loading chain data under the CSP — block height,
prices and attestation age all render, so `connect-src` is right. Three Permissions-Policy
features were dropped after the browser logged them unrecognised: a policy that fills the
console with warnings teaches an operator to ignore it.

### 4.2 Prove the live mint path — **S** — ✅ done 2026-09-25

The audit's headline finding. See `AUDIT-RESPONSE-2026-09-25.md` §1 and
`deploy/bin/usecert-smoke`: minting works today with no keeper restored, with transaction
hashes recorded. The observation (stale attestations, zero capacity) was right; the conclusion
(a dead attestation process) was not — that is the on-demand design.

### 4.3 Commit the `/api/attestations` route as deployable config — **S** — open

The route works and is proxied on the host, but the configuration is not in the repository, so
nothing here proves the client and the signer are connected.

### 4.4 Product and legal copy — **M** — open, *and it is 1.3 / 1.4 / 1.5*

The audit independently reached the same conclusion as this document's Phase 1 editorial items:
staking, slashing, insurance, fee passthrough and buybacks are described as live, and simulated
mirrors are labelled `LIVE`. Still an editorial call about what the project claims.

### 4.5 Green enforced baseline — **M/L** — open

`forge fmt --check` red, front-end lint red (1,644 errors), no CI, no release manifest, 97
Slither findings untriaged.

### 4.6 A deploy that cannot ship a bundle Node will not run — **S** — ✅ done 2026-09-25

Not from the audit — from taking the site down while doing 3.6. `bun run build` on its own
produces an artifact that **cannot boot, and says nothing**. The vite config carries
`defaultPreset: "cloudflare-module"`; on a bare host std-env detects no provider and nitro
emits a Cloudflare Worker module. Node loads it, runs nothing, and **exits zero** — so systemd
reports "activating" forever, `/var/log/usecert/web.log` stays **empty**, and the site 502s
with nothing anywhere naming the cause. The only record of it was a comment inside the systemd
unit, which is not a file anyone opens while running a build.

`deploy/bin/usecert-deploy-web` sets `NITRO_PRESET=node-server` and then **checks** it, because
setting it is not proof: `.output/nitro.json` records the preset nitro actually used. It also
verifies the server entry exists, walks the emitted modules to confirm every chunk they import
is on disk (a half-written `.output` resolves at request time, so the unit comes up "active"
and then 500s on the first render), restarts only after all of that passes, probes five routes,
and asserts the served dashboard names the chain that was just built.

**Each guard was made to fire, and two were wrong the first time.**

Refusing to restart is not the same as leaving the host in a good state: a rejected build has
already overwritten `.output`, so the process serves from memory while the bytes on disk cannot
boot, and the next reboot takes the site down with no deploy to blame.

Worse, the backup was refreshed unconditionally, on the assumption that whatever is deployed
must be fine. Running the preset guard **twice** disproved that: the second run saved the
already-broken `.output` over the last good backup, then "rolled back" onto it and reported
success. The backup is now only refreshed from a build that passes the same test a new one has
to pass, and restoring an unrunnable backup is refused out loud rather than reported as a
recovery.

Verified from a deliberately poisoned host — `.output` and `.output.prev` both holding
Cloudflare builds — which recovered on the next deploy while warning it had no known-good
fallback; then a refused build restored a runnable one and the service was **restarted onto it**
to prove it boots, rather than trusting the file that says which preset it is.


---

## Phase 5 — from the corrective re-audit, 25 September 2026

Four further reviews, synthesised in *UseCert Corrected Launch-Readiness Re-Audit*. They
**withdraw** the stale-attestation finding rather than soften it — *"continuous on-chain backing
attestations are not required by the implemented on-demand registry design"* — and then land two
High-severity defects that the earlier round missed and that this repository had not found either.
Full response in `demo/AUDIT-RESPONSE-2026-09-25.md` §6. Mainnet verdict remains **NO-GO** and is
not disputed.

### 5.1 The Mint button could not be pressed in the state it was meant to clear — **S** — ✅ done 2026-09-25

`MintRedeem` computed `capacityHalted` as `capIsZero`, full stop, and that disables submit. Zero
capacity is also the **ordinary idle condition**: the attestation ages out, `maxNotional18` reads
zero, and `mint()` relays a fresh signature to clear it. The control that triggers the refresh was
disabled by the state the refresh exists to remove — directly beneath a panel reading "Attestation
idle · your mint refreshes it". The copy was right and the button contradicted it.

**No user could ever have minted from the idle state.** That is why 4.2's evidence was a `cast`
transcript, and why that evidence did not show the problem: it proved the contract path and was
read as proving the product. The claim in `AUDIT-RESPONSE` §1 has been corrected in place rather
than quietly edited.

The block is lifted for exactly one case — a stale attestation is the **only** binding leg, **and**
the signer has a bundle covering that specific vault. It reads `bindingLegs`, which is the same
predicate `CapacityNotice` already used to choose between "idle" and "halted", because a control
and its own caption asking the same question two different ways is how they disagreed to begin
with. An unknown signer state is not a yes.

*Still open:* the acceptance criterion is a browser journey with a real wallet from `ageSec > 300`
through to a confirmed mint. Not run. The panel and the gate now share one predicate, so the panel
rendering "Attestation idle" **is** the gate being open — but that is an inference from shared
code, and it is recorded as one.

### 5.2 Only half of each signed bundle was relayed — **S** — ✅ done 2026-09-25

The signer produces **two** signatures per vault from one observation: `attestSig` for
`SolvencyRegistry.attestSigned` and `markSig` for `CertOracle.setMarkPriceSigned`. The app fetched
both — its own type declares `markPx18`, `markNonce`, `markSig` — and relayed only the first. The
registry relay reopens capacity; the oracle keeps whatever mark it was last given, so the basis
cross-check runs against a stale price and `mintAllowed()` can close on a divergence that is not
real. Refreshing half a bundle buys freshness for the number an auditor reads and not for the
number the mint gate uses.

**Not theoretical:** at the time of the fix the oracle held `markNonce` **1** while the signer had
moved to **2**. The mark had been drifting for as long as the omission existed.

Both halves of one bundle are now relayed and confirmed before the mint, mark first. The mark is
skipped when the oracle already holds that nonce or newer — `CertOracle_StaleNonce` would refuse
it, and two mints off one bundle is the ordinary case. Both targets are **pinned** to the generated
address book, and `attestationFor` now rejects a payload naming a different `certOracle`, as it
already did for the registry. `deploy/bin/usecert-smoke` relays both and was re-run from the
audit's own starting condition (`ageSec` 7,260, capacity 0) with every hash recorded.

### 5.3 Race and expiry handling — **S** — open

On `StaleBatch`, `StaleNonce` or near-expiry, refetch state and bundle **once**, with deadline
headroom, then show a specific message. Do not blindly retry the mint. Today a lost race surfaces
as a raw revert.

### 5.4 The five user-visible states — **M** — partly done

The dashboard already distinguishes *stale-but-refreshable* from *signer unavailable* (2026-09-23)
and 5.1 made the button agree with it. Still owed: *mark/oracle unhealthy* as distinct from a true
capacity constraint, and **submitted vs confirmed** — a transaction hash is not a completed mint.
The runbook and monitor still carry "MINTING HALTED" language that the on-demand design
contradicts.

### 5.5 Version and harden the signer path — **M** — open, *and it is 4.3*

`/api/attestations` routing still is not in the repository. The re-audit adds specifics: loopback
upstream, GET/HEAD/OPTIONS only, bounded per-IP and global rate limits, deterministic 429/503,
telemetry — and alerting on signer readiness before the 60-second validity budget expires, rather
than on registry age alone.

### 5.6 Runtime-validate the signer payload — **S** — open

`attestationFor` pins the registry and now the oracle, and `isRelayable` checks the deadline. The
integers, addresses, signature shapes and ranges are still trusted as typed. A malformed response
should produce a clean user error, not calldata.


---

## Keeping the public page in sync

**This file is not the only roadmap.** `/roadmap` on use-cert.com publishes a reader-facing
version, and on 2026-09-25 it was found three items stale: this file had been updated on every
pass and the page it summarises had not been touched since it was written.

Anything marked done here that a reader would notice — a new capability, a claim that changed,
a Before-mainnet item whose premise moved — belongs in `src/pages/Roadmap.tsx` in the same
pass. Not everything qualifies: correcting copy is maintenance, not a milestone.

Two kinds of drift are worth watching for specifically, because both happened:

* A **Before-mainnet item whose premise changed.** "A real venue" said the venue is a
  simulator, full stop. Lighter is live on mainnet and the interface matches it, so the item
  was overstating the gap while understating what is actually untested.
* A **claim that got worse rather than better.** The market-index item said two of four were
  chosen. The live venue says none of the four match, including the two recorded as verified.

---

## Suggested order

Phase 0 and Phase 1's small items are done. What remains divides cleanly.

**Blocked on a decision, not on work.** 1.3 / 1.4 / 1.5 are one editorial session rather than
three, since all three are the same question — what does the project claim, and in what tense.
2.3 needs a contracts answer on `bufferPct`. 0.4 needs artwork that does not exist.

1.5 is now narrower than the other two: 3.6 built the mechanism, so the per-chain claims follow
the deployment on their own and what remains is the **wording**, not the plumbing.

**Ahead of all of it.** The corrective re-audit's remaining P0 items (5.3, 5.5) gate a public
testnet pilot, not mainnet, and they are small. 5.1's acceptance evidence — one recorded wallet
journey from an aged-out attestation through to a confirmed mint — is the single cheapest piece of
evidence this project is missing, and it is the one that would have caught 5.1 before an auditor
did.

**Blocked on nothing, and next.** `DeployMainnet.s.sol`: the mainnet inputs are measured and
recorded in `deploy/mainnet/4663.plan.json`, the generator refuses to emit a bundle without a
deployment, and there is no script to produce one. It is the only thing standing between the
preparation and a switch.

**Large, and honest about it.** 2.2 (an indexer) and 3.3 (key custody) are multi-day and not
shortenable. 3.4 needs a signing decision before any of it can be automated.

**Before any mainnet deploy, whatever the order:** validate `LighterCore` against the real
engine with one small deposit. Everything else in Phase 3 assumes the venue behaves the way
this project modelled it, and nothing has tested that assumption.
