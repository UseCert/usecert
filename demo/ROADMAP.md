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

### 3.2 Real collateral and a real venue — **L** — 🟡 deployed against both; the engine is still unreached (see 6.7)

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

### 3.2b Every market index is wrong — **S** — ✅ closed on mainnet 2026-09-25

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

### 4.3 Commit the `/api/attestations` route as deployable config — **S** — ✅ done 2026-09-25

Closed by **5.5**, which went further than this item asked: the corrective re-audit specified an
edge policy the first audit had not. See there for what was installed and how each clause was
proven.

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

### 5.3 Race and expiry handling — **S** — ✅ done 2026-09-25

The re-audit asked for deliberate handling of `StaleBatch`, `StaleNonce` and expiry instead of a
blind retry. Writing it turned up a worse bug than the one requested.

**`waitForTransactionReceipt` does not throw on a revert.** It returns a receipt whose `status`
is `"reverted"`. The refresh path awaited it and moved on — so a relay that lost a race was
indistinguishable from one that worked, and the mint went out behind it and reverted too. **The
user paid for both** and was told the contract rejected the action. Measured rather than reasoned
about: a replayed attestation forced past gas estimation mines with receipt status **0**, which is
exactly the case where the wallet simulated cleanly and someone else landed first.

**Losing a race is not an error.** Two people minting off one bundle is the ordinary case, and the
loser's revert means the winner's transaction landed — which is what the second mint wanted. So a
failed relay asks **the chain** whether it is fresh rather than parsing the revert: state is ground
truth, the error name is a report about it, and a receipt does not carry the reason anyway. Fresh
→ the mint proceeds as if it had won.

Not fresh → **one** retry on a newly fetched bundle, and then the mint is **not sent**. A retry
loop here is a loop of wallet prompts. `no-bundle` is excluded from the retry on purpose — the
signer just said it has nothing for this vault, and asking again 200ms later is not a strategy —
and a dismissed wallet prompt is rethrown rather than retried, because retrying it means prompting
again.

**Deadline headroom 10s → 25s.** Ten seconds is enough for ONE transaction and this path now sends
up to two before the mint: a bundle with twelve seconds left passed the old test, funded the mark
relay, and expired under the registry relay. 25s is measured, not guessed — the signer was sampled
live and republishes every 30s against 60s validity, so remaining life is always ≥ 30s and the
guard is a bound rather than a common path.

The four race reverts now carry copy that says the true thing — nothing is broken, somebody else
was first — rather than "the contract rejected this action (`SolvencyRegistry_StaleBatch`)". The
two expiry cases are `retryable`, not `user`.

**Verified by producing both races on purpose.** The first attempt *measured the wrong thing*: it
fetched the bundle twice, and the signer rolls over every 30 seconds, so the "replay" was a
different valid bundle and succeeded. Capturing one bundle and replaying **that** gave the real
selectors — `0x42ca6d9e` and `0xa31577df`, which are `SolvencyRegistry_StaleBatch` and
`CertOracle_StaleNonce` exactly — so the copy is keyed to the names that actually fire rather than
the ones that looked right. Receipt status 0 confirmed on a mined revert. Happy path re-run end to
end after deploying: mark nonce 4 → 5, attestation refreshed, mint and redeem clean, supply
returned to 1.3624 exactly.

### 5.4 The five user-visible states — **M** — partly done

The dashboard already distinguishes *stale-but-refreshable* from *signer unavailable* (2026-09-23)
and 5.1 made the button agree with it. Still owed: *mark/oracle unhealthy* as distinct from a true
capacity constraint, and **submitted vs confirmed** — a transaction hash is not a completed mint.
The runbook and monitor still carry "MINTING HALTED" language that the on-demand design
contradicts.

### 5.5 Version and harden the signer path — **M** — ✅ done 2026-09-25, *and it closes 4.3*

The route worked and lived nowhere: four lines inside `sites-available/use-cert.com`, one
`nginx -t` away from being gone with nothing to restore them from. Both audits called it P0, and
it is the same gap the header policy had.

`deploy/nginx/usecert-api-attestations.conf` now holds the route **and** its failure path — a
named location is server-context, and splitting them would put half the behaviour back outside
the repository. `deploy/nginx/20-signer-limits.conf` holds the zones and log format, which have
to be in the HTTP context. The site file now just includes the snippet.

What the policy actually does, with what the re-audit asked for in brackets:

* **[methods]** GET/HEAD/OPTIONS; anything else is **405**, not `limit_except`'s 403 — "this
  endpoint does not do that" is the answer a client can act on. OPTIONS is answered at the edge
  rather than waking the signer to say nothing.
* **[rate]** per-IP 10 r/s burst 30, plus a global 200 r/s ceiling, plus 12 concurrent
  connections — a per-IP limit does not protect a single Node process holding a key from a
  distributed flood, and a rate limit does not bound slow readers at all. `nodelay` on both:
  queueing a request for a 60-second signature can deliver one that is already expired.
* **[429 vs 503]** 429 for "you asked too often", 503 for "the signer is down". nginx's default
  for a throttled request is 503, which conflates the two — the difference between a client that
  backs off and one that retries into the same wall.
* **[loopback]** unchanged and now **verified** rather than assumed.
* **[deterministic 503]** `proxy_intercept_errors` plus a named location, so a fault is always
  one JSON shape instead of whatever the process printed.
* **[telemetry]** a dedicated access log separating upstream time from total time — a slow signer
  and a slow client are different incidents and one number cannot tell them apart.

**Installing it found two things review would not have.** `limit_req_status` was already set in
`00-hardening.conf`, and a second declaration is a hard `nginx -t` failure rather than an
override — caught before any reload. And the endpoint was sending `cache-control: no-store`
**twice** plus an `Access-Control-Allow-Origin: *` that was nobody's decision: `add_header`
appends rather than replaces, so the Node signer's own headers were going out alongside ours.
Both are now hidden and re-set deliberately. The wildcard is kept — these signatures are public
by construction and a third-party relay UI is a legitimate use — but it is now a choice recorded
here rather than a default inherited from an upstream process.

**Every clause was made to fire**, because a policy nobody has tested is a policy nobody knows
the behaviour of. GET/HEAD 200, OPTIONS 204, POST/PUT/DELETE 405. Eighty rapid requests → 25
served, 55 refused with 429, and a 200 again after backing off — a limit that never reopens is an
outage. Port 8787 from the public address → connection refused. And the signer was **stopped**:
the endpoint returned exactly `{"error":"signer_unavailable","attestations":[],"stale":true}` with
`Retry-After: 5`, valid JSON the client can branch on, with no stack trace, no `ECONNREFUSED` and
no nginx version leaked — then 200 again on restart. The access log settles the OPTIONS claim on
its own: `urt=-` where nothing reached the upstream, `urt=0.001` where it did.

*Still open, and the reason this is 5.5 and not the whole of it:* **alerting**. Monitoring still
watches registry age rather than signer readiness, and nothing pages before the 60-second
validity budget expires. Tracked in 5.4.

### 5.6 Runtime-validate the signer payload — **S** — open

`attestationFor` pins the registry and now the oracle, and `isRelayable` checks the deadline. The
integers, addresses, signature shapes and ranges are still trusted as typed. A malformed response
should produce a clean user error, not calldata.


---

## Phase 6 — mainnet, deployed 25 September 2026

**UseCert is live on Robinhood Chain mainnet (4663).** Six mirrors, deployed, bootstrapped and
registered at the real Lighter venue. This section records what it took and what is still true
about the risk, because a deployment is not an endorsement of readiness — the two external
audits' NO-GO verdicts are unchanged and their open items are listed below.

### 6.1 The four unanswered inputs, answered — ✅ 2026-09-25

`DeployMainnet.s.sol` refused to guess four values. Three turned out not to be judgement calls
at all, only unmeasured ones.

**Price feeds — they exist.** Chainlink deployed feeds for ~95 tokenized equities when Robinhood
Chain's mainnet launched on 2026-07-01. All six we need are live, 8 decimals, 86,400s heartbeat
(inside `MAINNET_STALENESS_SECONDS = 93,600`), verified on chain by reading `decimals()`,
`description()` and `latestRoundData()` from each:

| | |
|---|---|
| TSLA | `0x4A1166a659A55625345e9515b32adECea5547C38` |
| SPY | `0x319724394D3A0e3669269846abE664Cd621f9f6A` |
| QQQ | `0x80901d846d5D7B030F26B480776EE3b29374C2ae` |
| NVDA | `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` |
| AAPL | `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` |
| MSFT | `0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E` |

**One thing to keep watching.** These are **total-return** feeds — underlying spot × a dividend
multiplier read from the Robinhood token contract — while Lighter marks **spot**. Measured against
the live venue marks the divergence was **12–46 bps** against a **500 bps** basis band, so roughly
a tenth of the budget. It widens with dividends. That is a thing to monitor, not a thing that is
solved.

**`singleSource` = false**, and it is forced rather than chosen: `true` caps `deviationBps` at 200
and construction reverts at our 500.

**`collateralAssetIndex` = 3**, and **the first answer was wrong**. `api/v1/orderBooks` is public
and carries `quote_asset_id` per market; all six report 0, so 0 went in and was written up as
"measured, not assumed". The dry run reverted `AdditionalZkLighter_InvalidAssetIndex`. The order
book's quote asset id and `deposit()`'s asset index are **different numberings** — reading one and
calling it the other was measuring the wrong thing and describing it as a measurement. Settled by
`eth_call` of `deposit(deployer, i, 0, 1e6)` across i = 0..24: 0 and 2 reject the index, 1 and
4..24 reject the amount, and 3 alone reached the ERC-20 transfer and failed only on allowance.
Granting 1 USDG turned that inference into a pass. The allowance was revoked immediately.

### 6.2 forge cannot deploy against this venue — ✅ worked around 2026-09-25

`CertVault.bootstrap()` calls `lighter.deposit(...)`, which delegates to
`0xDa2B59fFB41485a6f21E14e479AE7B7AB29a997c` — an Arbitrum **Stylus (WASM)** contract that
foundry's EVM cannot execute. It aborts `NotActivated` after ~963M gas, which is the signature of
that rather than of a contract fault: the USDG transfer completes first and the venue's balance
visibly increments.

**`--skip-simulation` does not help**, and the name is misleading. `forge script` ALWAYS executes
the script locally to collect the transactions to send; the flag only skips the separate on-chain
simulation pass. A script calling `bootstrap()` therefore never broadcasts anything — it dies
building the list. Confirmed by running it: nothing sent, no address book, not one wei moved.

So bootstrap left the script. `deploy/bin/usecert-mainnet-bootstrap` sends the six directly and
reads back `lighterAccountIndex()` rather than `bootstrapped()`, because the flag flipping only
proves we called it — the account index becoming non-zero is what proves the venue registered
anything. Three inherited §9 assertions had to become virtual seams to make this possible
(`_verifyCollateralAndFaucet`, `_verifyVenueWiring`, `_bootstrapsInScript`); every one is
**replaced** on mainnet rather than dropped, because the testnet versions assert things about
`TestUSDG`, a faucet and `LighterSim` that would revert against the real venue.

### 6.3 What is actually on chain — ✅ 2026-09-25

```
registry   0x0A82423F30036766160E82eDC0B173Aed77b03E8
capacity   0xE93c79FDf3DB76E9bF77D7fA7034216D5a61ea09
factory    0x6627a1F40B1da972F0C9Dbe8705ecC590178221A
collateral 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168  (real USDG, 6dp)
venue      0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d  (real Lighter proxy)
```

| mirror | vault | Lighter account |
|---|---|---|
| uTSLA | `0xFE4e5Ad7e07918D6D6fb87bd0706f85B09B1524c` | 32989 |
| uSPY | `0x74abEbFC54b396544B8C74E0dFC7988E788517AE` | 32990 |
| uQQQ | `0x143d7aE7F69e777D6Da8582A2b041eff30d3ee55` | 32991 |
| uNVDA | `0x6645c349Cc2e182d5bbA46341E87393Ccc341592` | 32992 |
| uAAPL | `0x9C2658A1D78f92a28B772Ca3B523C4939d83B4d6` | 32993 |
| uMSFT | `0x0F1B97efb2387cBa900D1cC3784dbB8250c5E069` | 32994 |

Cost: **0.0042 ETH** of gas and **6 USDG** of seed (1 per vault), from 0.01 ETH and 50 USDG sent.

> **Corrected the same evening.** This section said *"the first time this protocol has touched
> the real Lighter engine"*, and that claim was too strong. What is proven is that the vault
> called Lighter's **L1 contract** and the contract responded: it assigned each vault an account
> index and emitted events carrying that index, the vault address and asset index 3. What is
> **not** proven is that anything reached Lighter's matching engine — see 6.7, which is the
> finding that matters more than the deployment.

**Mint capacity is currently zero, by arithmetic.** `bootstrap()` consumes exactly
`10 ** decimals` as registering dust, so a 1 USDG seed leaves the ERC-20 buffer at 0 and
`bufferCapacity18()` — which reads `freeCollateral18()`, the real balance — is 0. Nothing is
misstated; there is simply nothing to mint against until more is seeded. 44 USDG remain.

### 6.4 Source published — ✅ 27/27 on Sourcify

**Not Blockscout.** `robinhoodchain.blockscout.com` sits behind Cloudflare bot protection: the
verification submit and the read-back both return a "Just a moment..." challenge page instead of
JSON, which is why forge reported "Failed to deserialize" and why the first read-back said 0/27.
**That number measured nothing** — it was an HTML challenge being parsed as an absent field.
Working around a bot challenge is not on the table, so verification went to Sourcify.

Sourcify gives a **stronger** result than testnet ever got: the 15 script-created contracts are
`exact_match` on **both** creation and runtime bytecode, where testnet Blockscout only managed a
partial match (runtime agreed, metadata hash did not). The 12 nested `Certificate` and
`BufferBook` contracts are exact on runtime with no creation match, which is correct rather than
short: built inside `CertVault`'s constructor, they have no creation transaction of their own.

### 6.5 The address book described the real venue as a simulator — ✅ caught 2026-09-25

`_writeAddressBook` is inherited and writes the venue under the key **`lighterSim`**. True on
testnet, where the venue is a simulator this repository deploys. On mainnet that slot held
Lighter's real proxy — and 3.6's derivation decides whether to tell users *"the perp venue is a
simulator this project runs"* by testing for **exactly that key's presence**. Left alone, the
mainnet site would have described the real venue as a simulation: the precise inverse of the
claim. It also wrote `testFaucet` as the zero address plus drip/float fields, and the generator's
`if shared.get(key)` treats a zero-address STRING as present, so the faucet UI would have
switched on.

Renamed to `lighter`, faucet and batch-keeper rows removed, raw deploy output kept at
`/root/4663.json.raw-from-deploy`.

### 6.6 Still open, and unchanged by deploying — **OPEN**

Deploying answered the engineering questions. It answered none of the governance ones.

| | |
|---|---|
| 🔴 | **Governance and attester are single EOAs.** No multisig, no threshold custody, no rotation drill. Both audits call this a mainnet blocker and they are right. |
| 🔴 | **No trade has been placed.** Bootstrap is a registering deposit, not a fill. Nothing has opened, closed, or been liquidated at the real venue. |
| 🔴 | **No keepers are running on mainnet.** No attester cadence, no batch monitoring, no alerting. |
| 🔴 | **The front end still points at testnet.** No mainnet bundle has been generated or deployed. |
| 🔴 | **USDG is unqualified as collateral** (P2-6) and the C1 attestation trust model is unchanged (P2-5). |
| 🔴 | **No independent review of the deployed system** (P2-8), no release provenance (3.4 / P3-1), no CI (4.5). |

**The audits' mainnet verdict is NO-GO and this deployment does not change it.** What exists is a
deployed, verified, venue-registered stack with zero mint capacity and no public interface —
which is the right shape for proving the machinery works before anything is at stake, and the
wrong thing to describe as a launch.

**Next, in order:** place one small real trade through a mirror and watch what the venue does
(P2-1); seed enough buffer for a single end-to-end mint; stand up the keepers; then generate the
mainnet front-end bundle. Governance custody before any of it carries value.


### 6.7 The venue's sequencer does not know our accounts — **SUPERSEDED by 6.8**

> **Wrong premise, kept for the record.** Everything below was measured against
> `mainnet.zklighter.elliot.ai`, which serves **Lighter** (USDC). Robinhood Chain runs a separate
> exchange, **Robinhood Chain Lighter** (USDG), at `api.rh.lighter.xyz`. On the right API the
> accounts had existed all along. See 6.8.

The deployment works. The integration is one step short, and it took minting on mainnet to find
out.

**What was run.** 3 USDG seeded into each buffer (capacity 300 USDG a mirror, `mintAllowed` true
on all six, basis 11–45 bps inside a 500 bps band), attestations refreshed, then **8 USDG minted
on uTSLA** — sized above Lighter's `minBaseAmount` of 0.0150 TSLA so the hedge could not be
refused for size. It produced 0.0214 uTSLA. `redeemInstant` then reverted
`CertVault_UseQueuedRedeem`, correctly: instant payout needs free collateral the vault does not
have while its margin sits at the venue. `requestRedeem` succeeded, burned the certificates, and
took the vault's ledger flat.

**Then the round trip stopped.** `claimRedeem(1)` reverts `CertVault_AwaitingSettlement`.
`recallMargin()` succeeds three times in a row and moves nothing. 7.947432 USDG is owed on
receipt #1, the vault holds 3.8072, and the difference has not come back from the venue.

**Why.** Lighter's API returns `account not found` for every vault address, while the venue's own
L1 contract maps each vault to an account index (32989–32994) and emitted events carrying them.
Both are true: an L1 deposit **assigns an index in the contract's registry**, and that is not the
same as the account existing in the **sequencer's** state, where matching and balances live. So
the deposits, the order submission and the withdrawal request all reached the contract; none of
them reached the engine.

**The measurement error worth recording.** The first write-up of the mint said *"the venue took a
real position"*, on the strength of `venuePositionBase` moving 0 → 214 and `postedMargin` moving
1 → 8.19. **Both are the vault's own ledger** — `int256 public venuePositionBase` is a state
variable, and its own NatSpec calls it "the vault's own order ledger" and lists four ways it can
be wrong. Reading our accounting and reporting it as the venue's behaviour is the same mistake
the first audit made about attestation staleness, made in the opposite direction. The venue's
**events** are the evidence; the vault's counters are not.

**What is actually needed:** sequencer-side account registration with Lighter — credentials, a
signed registration, or whatever their onboarding requires. It cannot be derived from the chain,
so it is the one genuinely external blocker. Until it is done: no mint on mainnet can be exited,
and **no public interface should be pointed at these contracts.**

**Funds are accounted for, not lost.** 8 USDG left the deployer for the vault and the venue
contract; 18 USDG remain in the wallet; 3.8072 sit in the uTSLA vault; 7.947432 are owed on an
unclaimable receipt; 3 USDG each are seeded in the other five buffers.

### 6.8 On-chain orders are reduce-only: the vault cannot open a hedge — **BLOCKING, design decision** — found 2026-09-25

The finding every other Phase 6 item was circling, and it came from the venue's own execution
record rather than from inference.

**How it was reached, in order, including the wrong turns.**

1. *Wrong exchange.* The market indices (112/128/129/110/113/115) and the account lookups came
   from `mainnet.zklighter.elliot.ai` — Lighter's USDC exchange. Robinhood Chain Lighter is a
   separate venue at `api.rh.lighter.xyz`, with its own market numbering: TSLA 16, SPY 26, QQQ 25,
   NVDA 15, AAPL 10, MSFT 14, all 2/4 decimals. **None of the six deployed indices exists there.**
   3.2b had it backwards: testnet's 16/26/27/15 were nearly right and were "corrected" to wrong.
   `marketIndex` is immutable, so the stack was redeployed with the right indices, gated by
   `deploy/bin/usecert-mainnet-preflight`, which refuses any deploy whose markets the venue does
   not list and was made to fail on the old values before it was trusted.
2. *Price cap.* Hedges were market orders priced at the oracle exactly. The total-return feed read
   $371.75 against a best ask of $372.62; a buy capped below every ask cannot fill.
3. *Order size.* The venue's `min_quote_amount` is $10. The 8 USDG test mint hedged $7.97.
4. *Silent withdrawals.* The venue calls sit in `try/catch`; at a wallet's estimated gas the call
   starves and is swallowed. Measured: no withdrawal at 142,503 gas, a withdrawal at 300,000.

Items 2–4 are fixed in `39a4505` (see its message). With all of them fixed, **a correctly priced,
correctly sized buy from a plain wallet still did not fill**, and Lighter's record of it says:

```
"ae": {"code":21738, "message":"invalid reduce only direction"}
```

**Orders sent through the L1 contract are reduce-only.** They are the censorship-resistant exit
path; they cannot open a position. Opening one requires an order signed off chain with an API key.
`CertVault` hedges a mint by calling `createOrder` on the L1 contract, so **no mint on this venue
can ever be hedged as designed.** The testnet simulator accepted anything and hid it.

**What survives.** Exits are reduce-only by nature, so redemption and `forceExit` closing the
hedge on-chain — the trustless half of the design — is exactly what the venue supports.

**The design change it needs.** The vault registers an API key on its own venue account through
the L1 `changePubKey`, which resolves the account from `msg.sender` and so is callable by a
contract; an off-chain keeper holding that key opens hedges after mints; closes stay on-chain.
That puts a key in the trade path, which the audits already flagged as the central risk, and it is
unverified whether an API key can move collateral OUT of the account (L2 transfers). Both need
answering before building it. **Not started; it is a decision about the trust model.**

**Funds.** 50 USDG sent. 16.89 in the wallet, recovered by redeeming the two uTSLA positions and
withdrawing the wallet's own test deposits. ~33 USDG is stuck across both stacks' buffers and
venue dust: `CertVault` has no function that releases collateral no certificate claims, which is
the design's protection against an owner draining it, and the reason it cannot be recovered.
The cause was seeding twelve vaults before proving that one could hedge.


### 6.9 The hybrid works technically, and is blocked by jurisdiction — **BLOCKING, legal** — 2026-09-26

Phase A of the keeper design (6.8), run from the deployer wallet before any contract change:

* **Key registration through the L1 contract works.** A Lighter API key registered with
  `changePubKey(33016, 3, pubKey)` - the only registration path a contract can use - was
  recognised by the venue (`check_client` OK). So a vault CAN hold a trading key.
* **Opening a position off-chain was refused before it reached the book:**
  `code 20558, "You are accessing Lighter from a restricted jurisdiction."` The server is OVH
  Montréal.
* Lighter's own terms, section 6, *"For both the Points Program and perpetual futures trading on
  Lighter on Robinhood Chain"*, restrict: BY, **CA**, CN, CU, IR, MM, KP, RU, SG, SS, SD, **CH**,
  SY, UA, AE, **GB**, **US**, VE.

This is not a server problem. Moving the keeper would only change where the order comes from, not
who is trading: if the operating entity is in a restricted region - and Switzerland is on the
list - running the keeper elsewhere would be circumventing the venue's terms. It is not done here
and should not be. **Whether UseCert can hedge on this venue at all is a legal question for the
operator, not an engineering one.**

The on-chain side (deposits, key registration, reduce-only closes, withdrawals) was not blocked.
All test funds were returned: wallet 16.89 USDG, venue account empty. The API key registered on
the wallet's venue account controls an empty account.


### 6.10 The hybrid, proven end to end on the live venue — ✅ 2026-09-26

The keeper design of 6.8, run on the real exchange from the two places it will really live.
Operating entity: Brazil. Keeper host: OVH **Roubaix, France** (141.94.203.130), neither
restricted. Montréal keeps everything else.

| step | where | result |
|---|---|---|
| deposit 12 USDG | Montréal, L1 | credited, `0x7c86dc66…` |
| **open** 0.0300 TSLA, market, API-key signed | **France**, off chain | **long 0.0300 @ 372.91 within 10s** |
| **close**, reduce-only market sell | Montréal, **L1 contract** | **flat within 10s**, `0xcfadeb71…`, no key involved |
| withdraw 11.9955 | Montréal, L1 | back in the wallet in ~6 min |

Round trip cost **0.0045 USDG** (the spread; taker fee is 0). Wallet 16.894864 → 16.890364 USDG.

Before spending anything, a free check: an order from France against an EMPTY account reached the
matching engine as a genuine opening order (`ReduceOnly: 0`) with no jurisdiction refusal.

This settles every open question about the venue: a key registered on-chain opens positions off
chain, and the chain alone can close them. **What remains is wiring**, not discovery: the keeper
orchestrator (event watching, settlement with the attester key) stays in Montréal and delegates only
order placement to France, then one keeper-mode vault proves mint → hedge → redeem.


### 6.11 The first fully hedged UseCert certificate, minted and redeemed — ✅ 2026-09-26

One keeper-mode vault (uTSLA, `0xD57cb3C6A282583D63F09fdde9E9135a949Bd4D9`, venue account 33202),
deployed alone with `MAINNET_ONLY=uTSLA`, key generated on the France host, keeper running there.

| step | who | result |
|---|---|---|
| `requestMint` 12.5 USDG | user | escrowed, **0 certificates** - correct, no hedge yet |
| order 335 base, cap 375.46 | **keeper, France** | filled **335 @ 373.00 within 5s** |
| `settleMint` | keeper (attester key) | **0.0335 uTSLA** issued; vault ledger 335 = venue position 0.0335 |
| `requestRedeem` | user | vault's own reduce-only close: **flat within 10s**, no key |
| recall + `claimRedeem` | anyone + user | **+12.441074 USDG** back in the wallet |

Nobody touched the hedge by hand. Cost of the round trip: mint and redeem fees plus the spread,
~0.06 USDG.

**Three things the cycle found, all fixed or recorded:**

* *Stale build.* The first broadcast died with `type check failed for "offset (usize)"` while
  forge decoded CertVault's constructor: the artifact on disk predated the last source change, so
  forge split the deploy data at the old code's length. A clean rebuild fixed it. The failed runs
  had still written simulated addresses into the address book, which was restored each time.
* **The recall over-asks, and the venue refuses the whole thing.** The vault requested the margin
  its books say it posted, 12.238750; the account held 12.234730 after the round trip's spread.
  Lighter answered `21304 "not enough asset balance"` and paid **nothing** - it does not pay
  `min(request, balance)`, which `recallMargin` assumed. Earlier recalls only worked because no
  trading had happened and the books matched exactly. Worked around by depositing 1 USDG to the
  vault's venue account (0.01 and 0.10 are below Lighter's minimum deposit); fix in 6.12.
* *Gas.* Every send used an explicit limit; see 5.3's starvation guard.


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

**Ahead of all of it, and blocking everything else: 6.8.** On-chain orders on Robinhood Chain
Lighter are reduce-only, so the vault cannot open a hedge. The fix is a design change — an
off-chain keeper with an API key opens hedges, closes stay on-chain — and it changes the trust
model, so it is a decision rather than a task. Nothing else on mainnet moves until it is made.

After that: P1 work on the testnet pilot — 5.4 (remaining user-visible states, signer-readiness
alerting), 5.6 (runtime payload validation), 4.5 (a green enforced baseline) — and governance
custody before anything carries value. 5.1's acceptance evidence — one recorded wallet
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
