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
| 🟡 | ~~Governance and attester are single EOAs.~~ **Governance closed 2026-09-26 (6.15):** every governance-bearing contract of stack 4 answers to a 2-of-3 Safe. **The attester is still a single hot key**, and no rotation drill has been run. |
| ✅ | ~~No trade has been placed.~~ **Closed 2026-09-26 (6.11, 6.14):** seven full mint → hedge → redeem cycles on the live venue, one per vault. |
| 🟡 | ~~No keepers are running on mainnet.~~ **Partly closed (6.14):** one hedge keeper per vault and the mainnet signer run in France. Alerting still does not exist. |
| 🟡 | ~~The front end still points at testnet.~~ **Built and served for mainnet from France (6.14)**; live once use-cert.com's DNS points there. |
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

### 6.12 A recall that never asks the venue for more than it holds — ✅ 2026-09-26 (`0742246`, `059cc7d`)

Fixes the second finding of 6.11 for **vaults deployed from now on**. The live uTSLA vault is not
upgradeable and keeps the old behaviour.

* **Contract.** `recallMarginUpTo(cap)` is the same permissionless recall with the request capped
  at `cap`. The caller reads the account's real balance off the venue and passes it. Tested by
  `test_recallMarginUpToNeverAsksForMoreThanTheCap`; removing the cap turns the test red.
* **Keeper.** `auto_recall` calls it only when something owed exceeds what the vault holds. The first
  version capped the request at the venue's whole available balance, and **that was wrong** (next
  point). The cap is now `min(available, owed − held)`. Checked against a stubbed chain and venue:
  owing 3.0 and holding 2.0 with 20.0 free at the venue now asks for 1.0; the old code asked for
  20.0.
* **Found while fixing it: `marginPendingRecall` drifts on the real venue.** OPEN, contract-level.
  `_sweepPending` lowers the counter only for money that arrives through the venue's pending
  balance. Lighter pays withdrawals **directly** to the vault's address, so the counter is never
  lowered. Measured on the live vault after its redemption was paid in full: owed 0, venue holds
  0.996, `marginPendingRecall` = **12.238750**.
  * **Holders are not affected.** Their money is recalled through the `owed − held` term, which
    reads the vault's real balance.
  * **What it does affect:**
    * Plain `recallMargin()` over-asks after the first payout, is refused, and fails open.
    * The published counter overstates.
    * Uncapped, it would have drained the other holders' free margin, which the keeper fix above
      now prevents.
  * **The proper fix** is a shadow of the vault's expected balance, updated at every transfer
    site, so an unexplained arrival can be credited to the counter. It touches every
    collateral-moving function of a non-upgradeable contract, so it is left for the audit
    rather than rushed into this deploy.

### 6.13 `retire()`: recover the protocol's capital from an empty vault — ✅ 2026-09-26 (`91f7f2d`)

**Why it exists.** About 33 USDG sits in the earlier mainnet stacks and cannot come out. A vault
releases collateral only by redeeming certificates, and those vaults have none. That rule (no
owner can take collateral from under holders) is kept. `retire()` is the narrow exception, and it
refuses unless **nobody** has anything in the vault:

* no certificates exist;
* no mint receipt is open (checked by a new `openMintReceipts` counter: +1 on request, −1 on settle
  or refund);
* nothing is owed on redemption receipts;
* the hedge ledger is flat.

After it runs, the vault never mints again, and governance can call `sweepRetired(venueAmount)`
to take back the buffer and the venue balance.

**The audit for it found a real gap.** No existing counter covered an unsettled mint escrow for its
whole life. `pendingMintCerts` is released at `stageRefund` while the escrow is still owed until
`refundMint`. So "the vault is empty" could not be established on chain until `openMintReceipts`
was added.

**Tests.** `CertVaultRetireTest` has 7 cases, 4 of them ways `retire()` could hurt someone.
Mutation-tested: removing either the open-escrow check or the owed-redemption check turns its
test red. The suite shows 496 passed; the 3 failures are the auditor's deliberate PoCs. CertVault
is 20,596 B.

**It cannot help the vaults already deployed**, because they predate it. **The ~33 USDG in the
earlier stacks is lost.** Every vault from the next deploy onwards can be retired.

### 6.14 All six vaults on the final code, keepers and site moved to France — ✅ 2026-09-26

**What was deployed.** One fresh stack of six keeper-mode vaults, with `recallMarginUpTo` and
`retire()`. It was built from the exact committed tree, which was compared byte for byte on the
build host. The old uTSLA vault predates both and stays as it is.

| mirror | vault | venue account | cycle |
|---|---|---|---|
| uTSLA | `0x6b47000D6904215163bB6318B72F4268045256f0` | 33398 | settled 21s, claimed |
| uSPY | `0x006Daf8AF20954a9912e647618e389a3B3F52b3B` | 33399 | settled 31s, claimed |
| uQQQ | `0xd6D198864C2F55822a935813A103C8B2282DdE52` | 33400 | settled 21s, claimed |
| uNVDA | `0x7a858eb23dF5299aa8e3E4857E4F1D335BE9Ec9B` | 33401 | settled 21s, claimed |
| uAAPL | `0x2CD8E6fB3a487ACC7610451232609F0154Fd96B9` | 33403 | settled 21s, claimed |
| uMSFT | `0xa6f8c0166BbC56730C84d03EF1aFdEba95B5F4b7` | 33404 | settled, claimed |

* **Cost and verification.** 0.0013 ETH of gas and 1 USDG of seed per vault. The source is
  verified on Sourcify, **27 of 27** contracts, with an exact runtime match.
* **Run automatically, end to end.** Each cycle was 12.5 USDG. The keeper opened the hedge in
  France and settled it. The vault closed its own hedge on chain. The keeper then recalled the
  shortfall on its own (6.12) and the user claimed. Each round trip cost about 0.03–0.08 USDG.
  Nothing was touched by hand.
* **Per vault in France.** Each vault has its own keeper instance (`usecert-keeper@<symbol>`),
  its own API key generated on that host, and its own state. They share nothing but the attester
  key.

**Found on the way, and fixed:**

* **Recall cap.** The keeper's recall cap was the venue's whole free margin. With the payout drift
  (6.12), the first small redemption would have withdrawn the free margin behind every other
  holder's hedge. It is now capped at the shortfall.
* **Rate limit.** One RPC 429 (six keepers share one IP) while waiting for a fill would have
  left a placed hedge unsettled, needing a human. The keeper now:
  * retries 429s and 5xx responses;
  * never reads "unfilled" into a failed read;
  * resumes settling a fill it has already journaled.
* **Signer.** The testnet signer reads a simulator's view functions, and the real venue has none.
  `usecert-signer-mainnet.py` reads the venue's API, reads every domain and typehash from the
  contracts, and signs after its reads, so a bundle leaves with 59 of its 60 seconds. All 12
  signatures were checked against the live contracts by `eth_call`.
* **Explorer and site.** `explorer.chain.robinhood.com` does not answer, so the site now links to
  `robinhoodchain.blockscout.com`. The site's CSP named testnet hosts. The front end did not know
  uAAPL, uMSFT or keeper mode. A keeper vault refuses `mintInstant`, so every mint and redemption
  is now routed through the receipt.
* **Shipping to the build host.** Git recorded every deploy tool as non-executable, and an
  archive from Windows converts every file to CRLF. Both stopped a deploy at preflight before
  anything was sent.

* **6.5, a second time.** The deploy script still wrote the real venue under `lighterSim` and
  the faucet as the zero address. The first mainnet build of the site therefore listed a
  "LighterSim (venue)" and a TestFaucet row, and said the venue was simulated. 6.5 had fixed the
  stack-1 book by hand, and that fix never reached the writer. It does now:
  * the venue key comes from `_venueBookKey()`, which is `lighter` on mainnet;
  * zero-address rows are omitted;
  * the generator refuses a mainnet book that says `lighterSim`, and treats the zero address as
    "not deployed".

  The 41 deploy-script tests pass. The stack-3 book was corrected, and its raw copy kept.
* **Copy that still said testnet.** Hard-coded testnet copy survived into the mainnet build:
  "on testnet the perp venue is simulated", "Deployed on Robinhood Chain testnet (chain 46630)",
  "no real-world value", "Reading chain 46630", `tUSDG`, and a market-index note quoting another
  exchange's ids. All of it now derives from the deployment, and the rest names USDG. Checked on
  the live site, not by grep: `/`, `/dashboard`, `/contracts`, `/roadmap`, `/vaults`, `/roles`,
  `/learn`, `/about` and both legal pages contain none of `46630`, `tUSDG`, `testnet`, `faucet`,
  `simulat*` or "no real-world value".

**The move to France.** The mainnet site, the signer, the nginx policy and the TLS certificate
run on the France host. `use-cert.com` and `www` point there, on A and AAAA. Resolvers still
holding the old records reach Montréal, which now forwards to France over verified TLS. So every
visitor gets the mainnet site, whichever address they resolve. The old site file is kept at
`/root/use-cert.com.site.before-france`. Montréal keeps the other projects, the shared Supabase
and the testnet stack.

**Still open:**

* The payout drift of 6.12.
* Alerting.
* Governance custody (6.6). *Closed for governance by 6.15: a 2-of-3 Safe. The attester is still one key.*

*Corrected:* an earlier version of this list said the site's activity feed was blocked by a bot
challenge on the explorer's API. That was inferred from a curl, not measured in a browser. In a
browser the feed loads and lists every mint, settle, redemption and claim of the cycles above.

### 6.15 Governance moved to a 2-of-3 Safe, on a new stack 4 — ✅ 2026-09-26

**Why a new stack.** The external "Final Mainnet Checkup — 26 September 2026" found that governance
and the attester were single EOAs, and rated it critical. Governance is immutable in every UseCert
contract: it is set in the constructor. The live stack could therefore never be handed to a
multisig, and a new stack was required.

**The Safe.** `0x848c91323f720DEf985adbCC85FA40E3405B70DF`, Safe 1.4.1 (SafeL2 `0x29fcB43b…C762`,
proxy factory `0x4e1DCf7A…ec67`), threshold 2 of 3. Creation tx
`0xddf4fe3a10b48f91e33db31aad0e6803ed808997880a348864d1c05b29d3e808`.

| owner | note |
|---|---|
| `0x37A94ba80bCaBc9aa435068210360d9CD4Ad1ac4` | |
| `0x0E670BbfFc7ead71e4eb05DFe77016729B6b7C0E` | signed batches 1 and 2 |
| `0x5Ef5a5300803C2e0b45d504b6Bd68c7dce26b62b` | an EIP-7702 smart-account-delegated EOA; signed batches 1 and 2 |

* The Safe web app and the Transaction Service support the chain (network `robinhood`).
* The deployer `0x6381…8e92` is registered as a **proposer only**. It can queue a transaction,
  not sign one.

**Stack 3 retired first.** All six stack-3 vaults were empty. Each was retired with `retire()` and
`sweepRetired`, the first real use of 6.13. **12.379248 USDG** came back in full to the old
governance EOA. The stack-3 keepers were stopped. Minting on the site was paused from retirement
until stack 4 went live.

**Batch 1: the Safe creates the registry and the oracles.** No contract source changed.
`SolvencyRegistry` and `CertOracle` set `governance = msg.sender`, and their constructor arity is
frozen because the auditor's AttackSuite depends on it. So the Safe itself had to create them.

* **Shape.** One Safe transaction: a delegatecall to MultiSend 1.4.1, whose 7 entries delegatecall
  CreateCall 1.4.1. Each CREATE therefore runs in the Safe's context.
* **Simulated first** on a mainnet fork (anvil, pinned pre-Cancun because Robinhood Chain is
  Arbitrum Orbit): `ExecutionSuccess`, 10.8M gas, all 7 contracts at their predicted addresses,
  each with `governance` equal to the Safe.
* **The Safe web app could not display or sign it.** The transaction is 57 KB of nested
  delegatecall, and the app answered "something went wrong". The owners signed the EIP-712 SafeTx
  on a private signing page instead. The page's typed-data hash was checked independently against
  the Safe's own `getTransactionHash` (`0x37feb7c9…`). They are equal.
* **Signed and executed.** Owners `0x5Ef5…` and `0x0E67…` signed. The signatures were verified on
  chain with `checkNSignatures`, and the deployer executed: tx
  `0x720c49acdb18cca5e98f52e1cd41b7664f8d51f772d78e20ddd498c59154a4a2`, `ExecutionSuccess`.

The registry is `0xAe6ae0939f2885fC0Ecf8b8af0082fa729a8bbB7`. The oracles are in the table below.

**The deploy script gained a Safe mode.** New seams in DeployTestnet, off by default. Testnet
deploys are unchanged, and the 41 deploy-script tests pass. In Safe mode:

* governance is the Safe;
* the Safe-created registry and oracles are adopted and verified, not deployed;
* phase 4 is left for the Safe.

One more check depends on phase 4, the mint gate's `maxNotional18`, and it had to be guarded too.
The first broadcast attempt stopped in local simulation. Nothing was sent.

**Stack 4.**

| mirror | oracle (created by the Safe) | vault |
|---|---|---|
| uTSLA | `0xdb1eF0e62F0954E8dC5dd1Bcc8126FbD30978121` | `0x6330B3C6612DBbf5D81A6BafB6319F39D46Df4B0` |
| uSPY | `0x94e58cBB9920dCBDF676132774fCd5248e455A85` | `0x4C1E083E1c0c726C6305ec684D9218dc83033dcd` |
| uQQQ | `0x013Dd75efD3F5485f2939aD5b6a986Fa815fe541` | `0x09777bfEB5a37cD5F642861fb166e7a9D2A4e615` |
| uNVDA | `0x9990de261434F2e7356b3C957f7ED4B9Fb86322F` | `0x2cA05803C37807bdB07075f6dA231C8B998e0bF3` |
| uAAPL | `0x2172701e2fd9C4c15A3297091Bd04045B015f05f` | `0x1386cdA161593379B820542D347C75b43458f6ed` |
| uMSFT | `0x325fc656A411EF1bc2f3621b2d045e2b42CC5450` | `0xD9ccc6edD94779dB28C8743088b70560B728489C` |

* All 15 governance-bearing contracts report `governance` = the Safe, checked on chain.
* Venue accounts: uTSLA 33556, uSPY 33557, uQQQ 33558, uNVDA 33559, uAAPL 33560, uMSFT 33561.
* Cost: 0.00125 ETH of gas and 6 USDG of seed.

**Batch 2: the Safe wires the vaults.** MultiSendCallOnly 1.4.1, 36 plain calls, six per vault:
`registerVault`, `setAbsoluteCap`, `setBufferThresholds`, `setVenueApiKey`, `setVenueMinimums`,
and `enableKeeperHedging` last.

* **A fork could not validate it.** The venue's `changePubKey` runs Lighter's Stylus WASM, which
  anvil cannot execute.
* **Validated against the real chain instead,** with a state-override `eth_call` as the Safe: all
  36 calls succeed. The negative control, the same calls from an address that is not the Safe,
  reverts.
* **Signed and executed.** The same two owners signed it on a second signing page. Tx
  `0x41687077f4df59f69928160808980db7017ce2d3f2ee18ae0324a3dcfca4e8a1`, `ExecutionSuccess`,
  1.86M gas.

**Live.** Keepers `s4-<SYM>` were started in France, with API keys generated there. The venue
accepted all six. The signer was switched to the stack-4 book.

* **uTSLA smoke cycle on stack 4:** settled in 21 s, recall covered in 455 s, claim paid
  12.441074 USDG.
* The site was then switched to stack 4 (front end `f065770`), and **minting reopened**.
* The other five ran afterwards, one after another, with nothing touched by hand. All six
  passed:

  | mirror | hedged and issued | collateral back | claim paid |
  |---|---|---|---|
  | uTSLA | 21 s | 455 s | 12.441074 USDG |
  | uSPY | 42 s | 424 s | 12.422046 USDG |
  | uQQQ | 31 s | 484 s | 12.435059 USDG |
  | uNVDA | 21 s | 421 s | 12.466529 USDG |
  | uAAPL | 31 s | 422 s | 12.450578 USDG |
  | uMSFT | 31 s | 421 s | 12.442986 USDG |

  Each was a 12.5 USDG mint followed by a full redemption.

**Sourcify.** The verify tool verified the 20 contracts the script created. The 7 contracts the
Safe created were submitted directly. All 7 are an exact runtime match. When checked, 4 were also
an exact creation match and 3 were still processing. **27 of 27** are runtime-verified.

**Still open: the attester is a single hot key.** It signs every few seconds, which a multisig
cannot do. Separating the signer and settlement duties is a future contract change. **OPEN.**

Commits: contracts `d5ee46c`, `aaffb74`, `3c6ebf9`; front end `f065770`.

### 6.16 The site in Simplified Chinese — ✅ 2026-09-26

**What a visitor sees.** A language dropdown (EN / 中文) in the site header and in the dashboard's
top bar. The choice is stored per browser. A script in the head holds the first paint, so English
does not flash before the Chinese appears. Switching back to English reloads the page.

**How it works.** English stays the source. Chinese is a dictionary keyed by the exact English
text, `src/i18n/zh-CN.json`. It is applied in two ways:

* **Reveal components.** LetterReveal and eight page splitters cut sentences into word spans for
  their animation. They now call `useT()` / `useReveal()`, translate the whole sentence first, and
  reveal the Chinese character by character.
* **A runtime pass.** A MutationObserver swaps exact English text nodes, and the `placeholder`,
  `title`, `aria-label` and `alt` attributes. Numbers and addresses are lifted out as placeholders
  first, so they are never translated.

A string with no entry stays English rather than being guessed.

**Where the strings came from.** Every page and dashboard state of the live site was crawled:
1,145 text nodes, plus 14 splitter sentences taken from source. That gave 1,058 entries, 69,410
characters. The result is 843 exact strings and 179 value templates. Every template was checked to
use each value exactly once. Product, contract and brand names stay English.

All of it was translated with one glossary:

| English | 中文 |
|---|---|
| certificate | 凭证 |
| vault | 金库 |
| perp | 永续合约 |
| hedge | 对冲 |
| keeper | 执行程序 |
| attestation | 证明 |
| solvency | 偿付能力 |
| buffer | 缓冲金 |
| margin | 保证金 |
| notional | 名义价值 |
| oracle | 预言机 |
| venue | 交易场所 |
| funding | 资金费率 |
| receipt | 回执 |

**Legal pages.** Translated for reading. The binding text is the English one. A note saying so is
pending, with legal copy the owner approves.

**Found while collecting: English strings that are false on mainnet.** They are being fixed in the
English source:

* instant-route copy on keeper vaults;
* the test-faucet panel;
* "test collateral" and "ReplayAggregator" on `/contracts`;
* the connect prompt, which says mainnet is not offered;
* vault pages saying certificates arrive "in the same transaction";
* uAAPL marked as roadmap.

**Concern recorded.** Lighter's terms list China (CN) among the restricted jurisdictions. A Chinese
UI can attract mainland users the venue does not allow. The eligibility wording should apply
equally to the Chinese pages.

Commits: front end `acf0373`, `5f6f97c`.

### 6.17 Commit history replayed onto dated branches — ✅ 2026-09-26

At the owner's request, both histories were replayed with current commit dates onto **new**
branches:

| original branch | replayed branch | commits |
|---|---|---|
| `backend/contracts-c1` | `backend/contracts-c1-2026-09-26` | 63 |
| `frontend/testnet-wiring` | `frontend/mainnet-2026-09-26` | 41 |

* **Same content.** The final trees are byte-identical to the originals. Only the dates differ.
* **Nothing rewritten.** The original branches and hashes were not rewritten or force-pushed.
  Every existing reference, including the external checkup's, still resolves.
* **Hash map.** `deployments/history/commit-replay-2026-09-26.txt` maps every old hash to its
  replayed copy, 104 commits.
* **Update pages.** The unlisted update pages now link the replayed commits: 67 of 67 links are
  new, and GitHub resolves them. Each commit's rendered image was regenerated from its new commit.

**What the dates mean.** On the dated branches, a commit's date is the replay date, not the date
the work was done. The originals keep the true dates.

Commit: `c050b3a`.


### 6.18 A health check that watches mainnet — ✅ 2026-09-26 (`e04baec`)

The only chain health script read testnet from Montréal. Nothing watched the mainnet signer or
the six keepers on France.

`usecert-health-mainnet` runs on France every 5 minutes, plus a daily summary at 07:00 UTC. It
checks only what stops a mint or a redemption:

* **Signer.** 127.0.0.1:8787 answers HEAD 200.
* **Units.** The signer and all six stack-4 keepers are active.
* **Scan lag.** Each keeper's scan is within 3,000 blocks of the head.
* **Receipts.** No receipt is waiting on a human, and none is stuck placing after 15 minutes.
* **Gas.** The attester and the deployer each hold at least 0.002 ETH.
* **Site.** The site returns 200.

It alerts when the set of problems changes, not on every run, and backs off on the shared RPC's
429s. The first run failed on one of those, which is why the backoff exists.

**Verified by breaking it.** A missing signer, a unit that does not exist, a lagging journal, a
stuck receipt, an unsettled receipt and low gas were each reported. On the live host it says
all clear.

**Alerts, 2026-09-26.** Telegram is wired on France: the owner's existing bot config was copied
host to host from Montréal and never printed, and the hashes match. A test summary was delivered.
Montréal's `usecert-health` and `usecert-summary` timers, which checked testnet only, are
disabled. Its site uptime (`usecert-status`), nightly DB backup (`usecert-backup`) and host
updates (`usecert-update`) are unchanged and still enabled.

**Open.** The attester holds 0.0047 ETH and the deployer 0.0034 ETH, both close to the 0.002
floor.

### 6.19 Unfilled mints refunded automatically — ✅ 2026-09-26 (`b1312f1`)

**Before.** If a keeper-mode mint's hedge filled zero on the venue, the receipt sat in escrow.
The holder had to find `stageRefund` and `refundMint` and call them.

**Now.** Both functions are permissionless, and `refundMint` pays `r.user`, never the caller.
The keeper therefore runs them itself once `settleWindow` has passed.

* If the vault is short of cash, the keeper first recalls the posted share with
  `recallMarginUpTo`. The amount is capped at both the venue balance and the shortfall.
* Only receipts the keeper itself saw fill **zero** are touched. Partial or unconfirmed fills stay
  flagged for a human, because refunding one would leave a hedge open with nothing behind it.
* A revert is logged and retried. It never crashes the keeper's pass.

**Tested.** Nine cases run against a stubbed chain and venue in
`deploy/tests/test_keeper_refund.py`, since anvil cannot run the venue's Stylus code:

* the window still open;
* stage, then refund;
* a cash shortfall;
* recall capped by the venue;
* already settled;
* both reverts;
* retry spacing;
* a partial fill left untouched.

**Rolled out one first.** uTSLA was restarted first, then the other five. All six are active on
the new code.

### 6.20 Chinese: dates and hydration — ✅ 2026-09-26 (front end `f0dd1a5`, `95c1ce6`)

* **Stray comma.** The number pattern swallowed a trailing comma, so dates read "9月26,日". A
  comma now counts only as a thousands separator, and 13 templates were re-keyed to match. The
  home page reads 9月26日.
* **Hydration error.** React error #418 appeared on five Chinese pages. The first translation pass
  ran about 170 ms before React had hydrated route chunks that arrive after the load event. It now
  waits until 400 ms pass with no new script, then for an idle callback, capped at 4 s. All seven
  pages probed are clean in both languages.
* **Missing strings.** The five strings the coverage crawl found were added: the idle-attestation
  copy, relative times, and the insufficient-balance message.

### 6.21 My receipts, and the two-step mints the index was losing — ✅ 2026-09-26 (front end `7bd8641`)

**Before.** Receipt ids cannot be listed on chain, and there is no `receiptsOf(user)`. Holders
had to find their ids on an explorer.

**Now.** The claim card lists the connected wallet's mint and redemption receipts on the
selected vault.

* **Which receipts exist** comes from the explorer index, and the list carries the explorer tag.
* **What state each is in** is a chain read of `mintReceipts` / `redeemReceipts`. So a lagging
  index can hide a receipt, but can never show a paid receipt as claimable.
* **Actions.** Each row offers **Claim**, or **Refund now** once a mint's hedge has not filled
  within 15 minutes. The keeper refunds those anyway (6.19).
* **If the index is down,** the panel says so. It never shows an empty list.

**A parser bug it exposed.** The explorer decodes `MintRequested` with the field names
`requestId` / `depositAmount`, not `receiptId` / `amountIn`.

* Every two-step mint lost its receipt id, never reached a wallet's list, and left its
  `MintSettled` unattributed.
* The parser now reads either name. The Activity view shows "MINT SETTLED · joined · receipt 1"
  for each vault where it said "could not be tied to a wallet".

**Verified live** with the deployer wallet on uTSLA, in English and Chinese:

* redeem #2 reads *claimed*;
* mint #1 reads *certificates issued*;
* no page errors.

### 6.22 The tracked book drifted again: stack 4 was never committed — ✅ 2026-09-26 (`210dc33`)

Stack 4, the Safe-governed stack, went live with its address book only on the France host. The
tracked `deployments/4663.json` stayed on the EOA-governed stack: the same drift as `d5ee46c`,
one stack later.

**Found by** regenerating the front-end module from the repo to record the deploy commit.
Every address differed from the site's.

**Fixed.**

* The EOA stack is archived as `history/4663.4-six-vaults-keeper-mode-eoa-governance.json`.
* The tracked book is stack 4, copied from the host.
* `commit` is recorded as `91f7f2d`, the contract source. `src/` is unchanged since, and it
  matched 27/27 on Sourcify. The deploy was run with `COMMIT` unset, so this is recorded by hand,
  with a note naming the deploy scripts `aaffb74` and `3c6ebf9`.
* The host's copy and the front-end header (`d762d4b`) now carry the same commit.

**Closed the same day (`b62f316`).** On 4663, `_commit()` in both DeployTestnet and AddMirror
reverts unless `COMMIT` is a 40-character lowercase hash. The book is written in forge's
simulation pass, before anything is broadcast, so the whole run is refused. `CommitGuardTest`
covers unset, malformed and uppercase values, a real hash, and testnet unchanged. It was first written as four tests and failed one run in a few, because `vm.setEnv` is process-wide and forge runs tests in parallel threads. It is now one sequential test, and it passed 5 of 5 runs.

**Still open.** The France deploy should commit the book it writes, so the tracked file cannot
lag the host.

**Correction, same day (`d3e1880`).** `210dc33` did not track stack 4: it *deleted* the tracked book.
`deployments/.gitignore` ignores `*.json`, and a genuine book must be added with `git add -f`.
The commit therefore recorded the move to `history/` and the deletion, and GitHub had no
mainnet book at all. The book-drift check in 6.28 found it on its first run (its fetch returned
404). The book is now force-added, byte-identical to the host's copy.

### 6.23 Solvency and funding history, and the ops fixes found in the logs — ✅ 2026-09-26 (`a8d1395`; front end `a987964`, `8fc6498`)

**Charts.** Four dashboard panels said "needs an indexer." They now draw data.

* **Solvency.** `usecert-history` on France samples the dashboard's own backing
  (`solvency().margin18 + buffer18`) and obligation (supply × `oracle.px()`) every 5 minutes, and
  serves them same-origin at `/data/history.json`.
  - The chart carries a "Recorded by UseCert" tag. The values are chain reads; the timestamps are
    the server's word.
  - Resampling takes the latest real sample per slot. A gap ends the curve; nothing is
    interpolated.
  - Checked against the live figures: $2.06 + $2.06 = the $4 backing shown, and $0 obligation.
* **Funding.** The venue's last 48 hourly rates per vault market.
  - The API docs don't state units, so they were derived from the data: `rate × price / 100`
    equals the venue's own `value`. TSLA: 0.0004 × $371.9 / 100 = 0.00149.
  - So `rate` is percent per hour, and `direction` names the side that pays.
  - Rates are published signed from the long vault's side. Right now the vaults pay 0.0004%/h
    on TSLA.

**Chart bugs.** These components had never drawn real data before today:

* negative bars ran through the axis labels;
* no scale was shown;
* the last 12 of 48 bars never finished growing;
* the solvency axis clipped whichever series crossed the other, and went below $0.

**Found in the access and service logs.**

* **Deploy downtime.** Every deploy served about 90 s of 502s, because node ignores SIGTERM and
  systemd waited its default stop timeout. With `TimeoutStopSec=5s`, a restart returns 200 in
  6 s.
* **Supabase reported down.** Montréal's uptime check had reported supabase down since the move:
  it checked `use-cert.com/supabase/`, a path that left with the site. It now checks the
  loopback gateway (401 = up).
* **Doc 404s.** Visitors looking for `/docs`, `/whitepaper` and `/tokenomics` got 404s (over
  100 from ordinary browsers). They now 302 to `/learn` and `/roles`.
* **Testnet id in copy.** "not deployed on chain 46630" now names the live chain.

**Copy, approved by the owner and shipped (`843234d`).** `/learn` said "Every hour, a keeper
settles accrued funding into the per-asset buffer." Nothing on this deployment does that. It now
says what happens:

* funding moves in the vault's venue margin account every hour;
* the dashboard charts the venue's hourly rates;
* the buffer's on-chain balance moves only when collateral moves;
* the accrual figure is a claim, not a transfer.

The same false sentence in "Who pays what, when" is fixed too, and the Chinese updated.

**Axis labels (`62c4b35`).** Below $100 the solvency axis now shows cents. The compact format
repeated whole-dollar labels ($2 $2 $1 $1).

### 6.24 Fewer RPC calls, Montréal retired from UseCert, France backed up — ✅ 2026-09-26 (`2522862`, `54d09f5`, `f2198b6`)

**RPC load.** Six keepers, the signer and the recorder share one IP. The public RPC answered 429:
12 keeper passes failed in 6 h, and 2 signer cycles were lost to an unchecked empty `cast`
result.

* **Signer.** Its twelve reads a cycle are now one Multicall3 `aggregate3` call with backoff.
  - Checked against the old path on the live chain before switching: 18 of 18 values and the
    block timestamp are identical, and the served bundles are field-identical.
  - A cycle takes 5–6 s instead of about 20, so a bundle reaches the site with more of its
    60 s left.
* **Keepers.** The idle recall check ran two `cast` calls on every 10 s pass. It is now one
  `eth_call` with backoff; the second read only happens when something is owed.
  `deploy/tests/test_keeper_recall.py` covers 4 cases. Rolled to uTSLA first, then the other
  five.

**Montréal.** Its UseCert services were testnet leftovers serving nobody.

* `usecert-web`, `usecert-signer` (failing every cycle) and `usecert-keeper` are disabled, not
  deleted.
* The status job no longer lists them, and no longer reads testnet: six RPC calls a minute,
  48 s a run, now about 5 s.
* Still there, and needed:
  - use-cert.com mail (the MX record points to Montréal);
  - the forward for stale DNS;
  - monitor.use-cert.com;
  - the uptime monitor, DB backups and host updates.
* The `usecert` database there is empty (no tables). UseCert never used a DB.

**France is backed up.**

* **What and when.** `usecert-backup-france` runs at 02:30 UTC. It archives the state that git
  cannot rebuild: journals, the six venue keys, the attester env, the book, the history, the
  tokens, units and tools.
* **Torn copies can't ship.** Every JSON file is re-parsed from the archive before it is sent.
* **Encryption.** openssl CMS, AES-256, to an RSA-4096 certificate. The private key is on
  neither host; the owner holds it.
* **Transport.** Pushed with a key restricted to one forced command on Montréal. That command
  checks the file is CMS and keeps 14. No shell, no commands, no forwarding: sshd logged the
  refusal.
* **Host key.** Montréal's host key is pinned from the fingerprint already trusted locally.
* **Tested by restoring.** Decrypted with the offline key: 85 files, 6 of 6 venue keys, 6 of 6
  journals, attester env, book.
* **Watched.** `usecert-health-mainnet` alerts if the last confirmed copy is over 36 h old.

### 6.25 Site audit: two missing vault pages, fake 200s, shared links without a picture — ✅ 2026-09-26 (front end, see commit)

**The crawl.** 19 routes, 46 external links, and a phone-width pass. No page errors and no
horizontal overflow. The one failing external link was X returning 403 to bots.

**What it found, and the fixes.**

* **Two vault pages missing.** uSPY and uMSFT, two of the six live vaults, had no page.
  `getVault` fell back to the first vault, so `/vaults/uspy`, `/vaults/umsft` and any made-up
  slug rendered the uTSLA page with a 200. Both now have pages, with no testimonial. Unknown
  vault and article slugs are real 404s.
* **Duplicate titles.** Every article was "Article - UseCert Research" and every vault "Vault
  Detail". Each now has its own title and description.
* **No share image.** Shared links rendered without a picture. There is now a 1200×630
  `og:image` / `twitter:image` and an `apple-touch-icon`.
* **Copy promising too much.** The root and dashboard descriptions said "stake", and the home
  share text said "SPX". Both now name the live six.
* **No sitemap.** `sitemap.xml` (22 URLs, no `/u/`) is in place, and robots.txt points to it.

**Awaiting the owner (artwork and copy).**

* **Third-party brands in artwork.** The uTSLA image is a Hyundai IONIQ 6 with the badge
  visible. The uQQQ image is Times Square, with Roku and AWS billboards readable. Both need
  replacing.
* **Testimonials with no one behind them.** The vault pages show quotes attributed only to
  "Holder" or "DeFi Builder", for vaults nobody holds yet. They read as real testimonials.
* **Undeployed fee language.** The funding paragraph on the vault pages says the remainder
  "becomes a transparent holding fee" past a threshold. No fee pass-through is deployed.

### 6.26 UseCert's own event indexer — ✅ 2026-09-26 (`bf23f37`; front end `6b67658`)

**Before.** Activity, recent flows and My receipts depended only on the public Blockscout
index. It is a third party whose field names had already silently dropped every two-step mint
once (6.21).

**`usecert-indexer`** runs on France, a pass every 12 s.

* **One call covers all six vaults.** Each block range is one `eth_getLogs` over all six vault
  addresses, for the eight flow events.
* **Decoding.** Events are decoded from their signatures by fixed word positions. A log of the
  wrong shape is dropped and counted. Timestamps come from the chain.
* **Output.** One Blockscout-shaped file per vault, served same-origin at `/data/logs/`, with no
  directory listing. The site's single parser therefore stays the source of truth.
* **Start block.** It starts at a fixed block: the public RPC is not an archive node, so a
  deploy block cannot be searched for.
* **Cost.** A caught-up pass is one RPC call.

**Checked against the explorer.** 24 of 24 events, with every transaction, log index, decoded
value and timestamp identical, and 0 dropped.

**Site.** It reads the indexer first. It falls back to Blockscout when the indexer is
unreachable or more than 5 minutes behind, all vaults from one source, and the tag names which
source answered. Verified live:

* normal path: 6 indexer requests, 0 explorer requests;
* with `/data/logs/` blocked: it falls back and shows the same 24 rows under "Explorer index".

**Watched.** `usecert-health-mainnet` alerts if the files go stale.

### 6.27 K1: the insurance contract, written and tested — ✅ 2026-09-26 (`edccc08`), not deployed

`src/InsuranceStaking.sol` builds the middle rung of the loss order: buffer → insurance → never
holder backing. The design and the reason for each decision are in
`docs/K-INSURANCE-STAKING.md`.

* **Staked asset.** Stakers deposit USDG, not CERT. A draw must deliver collateral, and CERT
  would first have to be sold into a falling market.
* **Draws.** A draw sends USDG to a registered vault, where it is the buffer the solvency math
  counts. No deployed vault changes. Rules:
  - proposed by the Safe, executable by anyone after a delay, expiring 3 days later;
  - capped at 50% or less of the pool, checked twice;
  - at least 7 days between proposals.
* **Exits.** A cooldown, then a withdrawal window. Exits and deposits pause while a draw is
  pending, and the proposal gap bounds that pause.
* **Yield.** Only income actually sent to the pool. No emissions.

**Tests.** 21, with the solvency fuzz at 5,000 runs. The full suite passes 518; the 3 failures
are the deliberate AuditPoC ones.

**Not done, and why.**

* **Deployment** waits for an external audit, a legal read, and the owner's decision.
* **Fee-funded yield** needs a new vault version: fees cannot leave today's vaults (K2).
* **An objective draw trigger** is K3.

A test run rewrote `deployments/46630.json` again. It was restored from the pre-run backup, and
the tree is clean.

### 6.28 Closing the list: drift, cleanup, a third backup, a manifest, honest copy, evidence, and K2 — ✅ 2026-09-26

* **Book-drift check (`8312d24`).** Health compares every address the France host runs on with
  `deployments/4663.json` on GitHub.
  - Its first fetch returned 404: `210dc33` had deleted the tracked mainnet book (see the 6.22
    correction). It is restored in `d3e1880`.
  - Falsified: one changed vault address is reported by name.
* **The pre-deploy plan is history (`9d5d1c7`).** Its market indices predate 6.8, and the
  generator now names the live book.
* **Montréal retired from UseCert, with a third backup copy (`1fdae53`).**
  - The testnet directories were archived first (512 MB, read back) and then removed.
  - Found first: the nightly DB backup read a file from one of them. It now carries the newest
    encrypted France archive offsite instead, to the Google Drive crypt: 26 files, France state
    included.
  - The live script also had a `yamale` backup the repo lacked; the repo now matches.
* **Release manifest (`5bb09e4`).** Every deployed script, config and book, and every web
  `src/` and `public/` file, is compared blob-for-blob with GitHub, hourly, at
  `/data/manifest.json`.
  - First run: 3 real differences, all fixed. An uncommitted nginx snippet, a front-end file
    pushed but never deployed, and a stale generated route tree.
  - Now 12 of 12 files and 230 of 230 site files match. Health alerts on any difference.
* **Copy approved by the owner (front end `4bba890`).**
  - Terms: redemption is always queued in keeper mode; no staking; single-venue and
    single-attester dependence named.
  - The vault funding paragraph no longer mentions a fee pass-through that isn't deployed.
  - **Testimonials removed.** They were attributed to roles for vaults nobody held, and one
    claimed a collateral listing that never happened. The home section is now "On-chain record":
    all 12 real mainnet mints and redemptions, each linked to its transactions.
* **Sourcify evidence (`15b9ad4`; front end `4527d3b`).**
  - An hourly job checks every contract in the live book. The browser never calls Sourcify.
  - Result: 27 of 27 UseCert contracts are runtime-exact, and 18 also match their creation
    transaction. The other 9 were created by other contracts. External contracts are labelled.
  - The external integration plan's allowlist named the retired stack. A typed list would have
    shown green for contracts nobody uses.
* **Per-receipt evidence timeline (front end `4527d3b`).** Request confirmed, then settlement,
  refund or claim observed, each with block, log index, time and transaction. It states that
  the off-chain hedge is not proven.
* **K2, fee routing: code and tests only, on its own branch `backend/k2-fee-routing` (`39f2493`
  to `81a5711`), not merged and not deployed.**
  - CertVault counts fees and adds a permissionless, pull-only `sweepFees()` to a set-once
    `feeSink`. The sweep only takes collateral beyond every obligation: owed claims, open mint
    escrow, each certificate's retained float, seeded buffer capital and any declared deficit.
  - `FeeVault` splits fees with an ownerless, fixed split.
  - 27 new tests; the full suite passes 545, with only the 3 deliberate AuditPoC failures.
    CertVault is 22,224 B against the 24,576 B limit.
  - **Deploying K2 means a new stack 5** through the Safe, plus holder migration.
  - **The split, set by the owner the same day: 70/20/5/5.** 70% to stakers in the insurance
    pool, 20% to a buyback fund (USDG until a CERT market exists), 5% to keeper and ops gas, 5%
    to the treasury (the Safe). The whitepaper, the spec, the Roles page and the Learn page had
    published three different splits; all now say this one (front end `65af023`).
* **Monday-gap idea: principle agreed** (owner, 2026-09-26). A free weekly prediction
  leaderboard with no deposit and no bet, rewarded from a marketing budget, once staking is
  live. Not the deposit-and-forfeit-yield version, which is a binary option on equities.

### 6.29 The insurance pool is live on mainnet, with its interface — ✅ 2026-09-26 (`095093b`, `8fb8b54`, `66607ee`; front end `c0187e1`, `65af023`)

**The fee split, set by the owner: 70/20/5/5.**
* 70% to stakers in the insurance pool, 20% to a buyback fund (USDG until a CERT market
  exists), 5% to keeper and ops gas, 5% to the treasury (the Safe).
* The site and docs had published three different splits; all now say this one.
* The K2 branch pins it in a test: 12.345678 USDG splits to exactly 8.641974 / 2.469135 /
  0.617283 / 0.617283.

**A deposit cap before deploying.** `InsuranceStaking` gained an immutable `depositCap`, because
the contract is unaudited and the cap is what bounds the exposure. Income can take the pool past
the cap; only deposits stop. 23 tests.

**Deployed:** `0xDbdA46671E0e97860493Ce149ad7B726407dAFb1`, tx `0x97a2b1e4…7c27`, block
73,180,902, from `095093b`.
* Governance is the 2-of-3 Safe, the registry is CertFactory, and the asset is USDG.
* Parameters: cooldown 10 d, window 3 d, draw delay 2 d, draw cap 30%, deposit cap 10,000 USDG.
* The init code was built locally and signed on the host that holds the deployer key; the key
  never moved. It cost 0.00006 ETH.
* Every constructor parameter was read back from the chain. Sourcify: exact match on creation
  and runtime.
* Recorded in `deployments/4663.insurance.json`.

**Proven with 1 USDG** before anyone else could deposit:
* approve and deposit: 10¹² shares, worth exactly 1.000000 USDG, with 9,999 of room left;
* a withdrawal without a request is refused (`ERC4626ExceededMaxRedeem`);
* a withdrawal request opens the window on 2026-10-06.

**Still to prove:** completing that withdrawal inside its window (2026-10-06 to 2026-10-09).

**Interface.** A sixth dashboard view, "Insurance", reads the pool live:
* assets and room under the cap, value per share, your stake, draws and their history;
* deposit, request, cancel and withdraw, each confirmed on chain before it says so;
* stated on screen: unaudited, capped, no automatic income, and the rules fixed in the contract.
Verified in English and Chinese with no page errors. The ABI module is generated from the
verified artifact.

**Copy that deploying made false, corrected.** Terms, FAQ, Learn, Roles, TokenFlow and the Risk
view all said there was no staking or insurance.
* The Risk waterfall and posture now read the pool's live size.
* The Learn draw paragraph also claimed stress-set sizing and a published expected-loss
  distribution. Neither exists; it now says the Safe decides within the cap.
* A live scan finds no remaining "not deployed" claims.

**Watched.**
* Health alerts on a pending draw. Falsified with a faked pending draw.
* Sourcify evidence covers the pool: 28 UseCert contracts, 19 exact and 9 runtime-exact.
* The release manifest matches after the push: 12 of 12 files, 234 of 234 site files.

**Not done.**
* An external audit.
* Fee income: K2 is a new vault stack.
* Choosing the buyback fund and ops wallet addresses.

### 6.30 CERT staking for a share of the buyback fund, live on mainnet — ✅ 2026-09-26 (`7f305c7`, `520fad2`; front end `7013d48`, `42ceef3`)

**The owner's decision.** CERT staking is a **share of fees, not insurance** (option 2). The
buyback fund's 20% of the 70/20/5/5 split is paid in as USDG and streamed to CERT stakers pro
rata. Staked CERT is never drawn; the insurance layer stays USDG.

**`CertStaking`** uses the standard staking-rewards pattern, with these differences:
* **Funding is permissionless:** no distributor key.
* **Stakes and rewards are credited by balance delta.** CERT's source is not verified.
* **No stranding.** Reward accrued while nobody is staked is carried into the next stream.
* **Precision.** It uses 1e36 and a 1e18-scaled rate, because USDG has 6 decimals and CERT 18.
  At the usual precision a large stake rounded every second's reward to zero, and an unscaled
  rate streamed only 699.75 of 700.
* **An immutable stake cap:** 10,000,000 CERT.
* **Otherwise fixed.** Withdrawals are immediate; there is no owner, pause or upgrade.

**Tests.** 14, including a 3,000-run solvency fuzz: stakes are always covered exactly, and
rewards are always covered.

**Deployed:** `0x6491f2a764F65982641F3C63AeB6895cC33ba0Ae`, block 73,206,833. Parameters read
back; Sourcify exact match. Recorded in `deployments/4663.certstaking.json`.

**Proven on mainnet.**
* Funded 1 USDG (rate 1.6534 units/s, 1 unit of dust carried).
* Staked 1,000 CERT, the owner's, and was credited exactly 1,000. **CERT has no transfer fee.**
* 278 pre-stake units were carried, not lost.
* Earned 153 units in about 90 s; the claim paid 157.
* Withdrew 500 CERT at once. 500 CERT remain staked, so the live pool is not empty.

**Interface.** The Staking tab (formerly Insurance) gains CERT staking.
* It shows total staked and room under the cap, what is streaming now, your stake and your
  reward.
* Actions: stake, claim and withdraw, each confirmed on chain.
* No APR is shown: with rewards funded by hand it would be a forecast.
* "No CERT staking exists" is corrected in the Terms, Learn, Roles and Risk.
* The contract is listed on /contracts with its Sourcify evidence: 29 UseCert contracts, 20
  exact and 9 runtime-exact.

**Caught by the live check.** The staking address had been hand-typed with the wrong checksum,
so every read failed. It now uses `cast`'s checksum.

**Not done.**
* An audit. Promotion needs the legal read: paying CERT holders a share of revenue is the most
  security-like thing here.
* Automatic income: K2.
* The owner sent 10,000 more CERT to the deployer. They are unused, awaiting instruction.

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
