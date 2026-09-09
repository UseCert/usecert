# Integration stage 3 — the copy, and the last invented numbers

Stage 1 built the chain layer, stage 2 made the data honest. This stage does the two things
those left: it removes the numbers that were still fabricated, and it corrects the words
around the honest ones.

Verification: `npx tsc --noEmit` exits **0**. `bun.lock`, `bunfig.toml` and `package.json`
are untouched, no dependency was added, no lifecycle script or CI workflow was created, and
`src/chain/contracts.ts` was treated as read-only. No `package.json` script was ever run.

---

## 1. The fabricated numbers are gone

### 1.1 `StakingView` and `KeepersView` — removed, not emptied

Both were untouched by stage 2 and both rendered figures that existed nowhere but the
store. Neither maps to a deployed contract: `InsuranceStaking` and `CERT` are C3, and of
the five keepers `KeepersView` advertised, only `recallMargin()` and `rebalance()` are real
(both already exposed on `useCertActions` and reachable from the mint screen).

Keeping a shell would have meant keeping a nav entry, a header and a layout whose entire
content was the removed figures, so the smaller honest change was deletion:

| Deleted | What it was showing |
| --- | --- |
| `src/pages/dashboard/StakingView.tsx` | `4.82M` total staked, `1,250` staked, `3,500` liquid, `42.18` rewards ticking up `+0.006` every 2 s, a 7-day cooldown with a "Fast-Forward (Demo)" button, and an `80 / 10 / 5 / 5` protocol-fee split — for a token that does not exist. |
| `src/pages/dashboard/KeepersView.tsx` | Five keeper cards with a green pulsing "Active" chip, `41,204` / `41,198` / `41,201` / `41,210` runs today, a `46m` countdown, "BUFFER HEALTHY · NO FEES ACTIVE", a "5 bps of rebalance" bounty, and a "Run Now (Demo)" button that incremented a counter in React state. |

Store state deleted with them (`src/pages/dashboard/store.tsx`): `tokenLiquid`,
`tokenStaked`, `totalStaked`, `rewards`, `cooldowns`, `keepers`, `makeKeepers()`,
`runKeeper`, `stake`, `unstake`, `claim`, `fastForward`, `withdraw`, the `executeMock`
helper that faked a pending→confirmed toast for all of them, the 2-second interval that
kept the keeper cards and the reward counter moving, `COOLDOWN_MS`, and the `Keeper` and
`Cooldown` interfaces. The provider now publishes nothing that is not a contract read.

`ViewId` lost `"staking"` and `"keepers"`, which made the compiler find every remaining
reference: `Dashboard.tsx`'s router cases and imports, `chrome.tsx`'s `NAV_ITEMS` (and the
mobile tab bar's `grid-cols-7`, now `grid-cols-5`), and `CommandPalette.tsx`'s nav list.

Two more mock devices went with them:

* **`TxConfirmModal`** (`modals.tsx`, ~130 lines) — a review → "Confirming…" → green
  checkmark flow that displayed a transaction hash for a transaction that was never
  submitted. Its only caller was `StakingView`.
* **`randHash()`** (`format.ts`) — the generator that minted those hashes. It joins
  `mulberry32` in the file's do-not-reintroduce note.

`FlowType` was narrowed from six members to `"MINT" | "REDEEM" | "CLAIM"`, which removed
the "Stakes" filter tab from `ActivityView` and the `Shield` / `ShieldOff` / `Check` icons
for stake, unstake and staking-withdraw flows from `flows.tsx`. The activity table's
hardcoded `USDC` column header now reads `{collateralSymbol}` (tUSDG), and the asset filter
no longer offers a "Token" option.

### 1.2 The stress-scenario table — the numbers were invented too

`RiskView`'s `SCENARIOS` was a figure stage 2 kept, and it is not supportable. It published
`−41% of buffer`, `−12%`, `−9%` and `0%` against shocks of `−30% annualised funding, 30
days`, `−20% overnight gap` and `45% of supply redeemed in 24h`. Nothing on-chain publishes
a stress result, there is no stress model in `D:/cert/docs` (`grep -rn -i "stress" docs/*.md`
returns nothing), and "Modelled, not measured" discloses a model that was never run.

The table is now **Failure Modes**, three columns instead of four, and carries no
magnitudes at all: each row names a mechanism that exists on chain 46630
(`CertVault_UseQueuedRedeem` routing, `mintAllowed()` going false, `ageSec` passing
`maxAttestationAgeSec`, `forceExit` being gated on nothing) rather than quantifying an
outcome. A footer line says no stress model has been run against this deployment.

Two related fabrications in the same view: the `Keeper heartbeat` row in
Controls & Attestations (an em-dash for a mechanism with no heartbeat at all) is gone, and
the header claim "Every parameter that governs the vaults, the buffer and the insurance
tranche - published, live, and stress-tested" now says only what is true — every parameter
the deployed contracts publish is read live, and where there is no on-chain source the row
is blank.

### 1.3 The public vault pages had a fake live feed

Found while applying the same test outside the dashboard, and it is the worst instance in
the repo. `src/pages/vaults/DetailSections.tsx` rendered a panel headed
**"Live vault snapshot · Powers the public dashboard"** with a pulsing green "Live" dot and
four figures:

* an oracle price from `data.ts` (`412.38` for uTSLA, `188.42` for uNVDA) run through
  `TickingPrice`, a memoised component that jittered it with `Math.random()` every 1.6 s so
  it looked like a feed;
* a circulating supply (`128,540`, `204,318`) as a string literal;
* a hardcoded `100.00%` backing ratio;
* a hardcoded `1.000` delta.

It rendered for **uNVDA**, which has no vault, no certificate and no oracle on chain 46630.

`TickingPrice`, the `snapshot` field on `VaultData` and both snapshot objects are deleted.
The section is now the certificate plate for every vault, with a status badge
("Deployed on testnet 46630" / "Roadmap C2") and, for the deployed ones, a line saying the
figures are read on the dashboard with the age of the attestation behind each, plus the
existing link there. No number on that page comes from `data.ts` any more.

Two animated `Counter` captions on the same pages were false rather than merely unsourced:

* "**100.00%** — Backing ratio, supply x price covered *every block since deployment*" (a
  historical claim with no history behind it) → "Backing ratio target, enforced in the
  vault's solvency math at each attestation".
* "**0** — Redemptions ever gated, queued, or delayed" / "**0** — Redemption gates or queue
  mechanisms in the vault design" → "Conditions that can refuse a redemption — forceExit is
  gated on nothing. Above the instant cap redemption is queued, not refused." The old
  wording contradicted `requestRedeem`, the receipt queue and `CertVault_UseQueuedRedeem`,
  all of which exist.

---

## 2. Copy accuracy

### 2.1 "every block" → per attestation

Solvency is proven per attestation, not per block: the attester runs on a ~60 s cadence and
`maxAttestationAgeSec` is 300 s, past which capacity is zero and minting is off. The live
`AgeLine` component already prints the real age of the current proof, so the surrounding
words now match it. Thirty-two occurrences across twelve files (plus one inside the deleted
`StakingView`, which promised rewards "Accrue every block"):

| File | Was | Now |
| --- | --- | --- |
| `dashboard/Overview.tsx` | "Solvency public / every block" | "Solvency proven per attestation · age published" |
| `dashboard/RiskView.tsx` (Design Law 01) | "provable on-chain every block" | "Proven on-chain per attestation, with the age of that attestation published next to every figure — not proven every block" |
| `dashboard/chrome.tsx` (sidebar) | "Backing ≥ Supply × Price" | "Backing ≥ supply × price, per attestation" |
| `components/Footer.tsx` | "Provable every block"; "Solvency public every block" | "Proven on-chain every attestation (~60s), with the age of the proof published"; "Solvency proven every attestation, age published" |
| `home/Compare.tsx` | "verify every block"; "Solvency public every block" | "verify at every attestation"; "Solvency proven every attestation" |
| `home/HowItWorks.tsx` | "public every block" ×2 | "proven on-chain at every attestation (~60s), with the age of the proof published" |
| `home/WhyUseCert.tsx` | "Backed every block"; "provable on chain every block" | "Backed, and proven"; "proven on chain every attestation" |
| `about/Story.tsx` | "hold every block, in public?" | "hold at every attestation, in public, with the age of the proof next to it?" |
| `roles/RolesAccordion.tsx` | "oracle-priced every block" | "oracle-priced from the same feed the vaults use" |
| `vaults/data.ts`, `vaults/DetailSections.tsx` | "band check every block window" ×5; "checked every block window" | "band check on each attested batch" / "checked each attested batch" |
| `learn/data.ts` | "provable every block"; "printed on the solvency dashboard every block"; "the thresholds, and the fee schedule every block"; "five jobs, running every block"; "A snapshot keeper publishes the full solvency state every block … a live fact and not a monthly attestation" | per-attestation phrasings; the last one now says an attester publishes each venue batch (~60 s) with the age alongside, so solvency here is proven on a ~60-second cadence rather than in a monthly report |

`grep -rn -i "every block" src/` now returns only three hits, all of them comments
explaining why the phrase was removed, plus Design Law 01's explicit negation.

### 2.2 "C1 Live" — removed in both places

C1 is the identifier of an **audit**, and that audit reported two criticals in the mint
path. Whatever the badge was meant to convey, "C1 Live" next to a pulsing green dot reads
as a passed audit, and guide §6 item 8 says it must not appear until C1 ships.

* `dashboard/Overview.tsx` — the top strip's `<PulseDot /> C1 Live` is now
  `<PulseDot /> Testnet 46630`, a fact the app can support (it is what the chain layer is
  configured for).
* `home/Hero.tsx` — the hero's "Phase: ▮▮▯ **C1 Live**" is now "C1 on testnet", which
  states deployment status without asserting a release or a clean audit.

### 2.3 Undeployed mechanisms are no longer described as live

Stage 2 deleted the `ThresholdMeter`, the holding-fee thresholds and the funding-shock
simulator. The prose next to them was still there:

* **Design Law 03** was "Funding buffered, then fee'd, never hidden … past the published
  threshold, passes through as a transparent holding fee." It now says funding accrues to
  and from the buffer the vault holds and that the fee-passthrough threshold the law was
  written around is **not deployed** on chain 46630 — nothing takes over when the buffer is
  exhausted.
* **Design Law 04** asserted "Staked CERT is the junior tranche and absorbs buffer
  exhaustion." It now says that is the design and that the tranche does not exist here,
  matching the loss waterfall, which already showed the leg unsized.
* **Design Law 02** kept its promise (redemption is never gated) but now names how: a thin
  buffer routes redemption through the queue and stops minting, never redemption, and
  `forceExit` is gated on nothing.
* **Honest Boundaries** (guide §6 item 7) gained the three boundaries the guide asks for
  and did not have: ~60 s solvency latency with the 300 s staleness limit named, basis risk
  via `basisBpsChecked()` reporting when it cannot compute a basis, and single-venue
  dependency — with the note that the venue is a simulator on this testnet. Its named-risks
  line no longer promises a fee passthrough or an insurance tranche.

`grep -rn -i "ThresholdMeter\|Fee_On\|Mint_Slow\|Insurance_Draw"` over `src/pages/dashboard`
now returns only `VaultsView`'s existing line saying no such threshold behaviour is
deployed.

### 2.4 One guarantee that was simply false

`home/HowItWorks.tsx` promised that redemption is "never gated, **never queued**, never
paused for convenience" and that the collateral "returns to you in the same transaction".
Above the vault's instant cap it does not: `requestRedeem` burns now and pays by claim over
two batch round-trips, with the venue's 14-day priority expiration as the real worst case —
which `MintRedeem` already publishes. The sentence now says both halves, and keeps the part
that is true: redemption is never *refused*, and `forceExit` is gated on nothing.
`home/Compare.tsx`'s "Always, at oracle price" comparison cell gained "instant under the
cap, queued above it".

### 2.5 The simulated venue: one line, no banner

Per the project owner's ruling there is no banner and no alarm language. One calm sentence
sits directly under the Overview's top strip, above the ticker, where a reader of the
dashboard's first screen will pass it:

> On testnet the perp venue is simulated, so the attested margin and notional below
> describe a simulated position.

It is stated once more in prose, in the Honest Boundaries single-venue item, because that
is the list where a reader goes looking for it. `RiskView`'s parameter table already
labelled the venue market index "simulated venue on testnet" (stage 2).

---

## 3. Verification

`npx tsc --noEmit` exits **0**, and `npx tsc --noEmit --noUnusedLocals` reports only one
pre-existing error in `src/routes/__root.tsx` (an unused `NotFoundComponent` from before
this stage), so none of the deletions left a dangling import.

Negative test, to show the check is live rather than merely quiet: putting `"staking"` back
into `chrome.tsx`'s `NAV_ITEMS` produces

```
src/pages/dashboard/chrome.tsx(19,5): error TS2322: Type '"staking"' is not assignable to type 'ViewId'.
```

which is the property that matters here — the two removed views cannot come back by
accident, and neither can a nav entry pointing at nothing. Reverted, `tsc` is back to 0.

Nothing was rendered. The app was not started and no script from `package.json` was
executed, so there is no evidence about layout — in particular the mobile tab bar's move
from seven columns to five and the vault detail page's replaced media block were not seen.

---

## 4. Still not honest, and why it is not fixed here

Five of the nine copy items in guide §6 are outside this stage's brief and remain. All five
are on the marketing site, none of them on the dashboard:

* **§6.2 — "no custodial stock token exists on Robinhood Chain."** It is still there, in
  `home/TheGap.tsx:79` as body copy and in `home/Compare.tsx:146` as a tooltip title
  ("Custodial stock tokens do not exist on Robinhood Chain"). The guide says to remove it
  because Robinhood Stock Tokens are live. `Compare.tsx` also builds a whole comparison
  column on the premise (`{ name: "Custodial Stock Tokens", … }`), so removing the claim
  means deciding what that column becomes — an editorial call, not a string edit.
* **§6.3 — "the first holdable stock tokens."** `Learn.tsx:40` says "the first holdable
  stock certificates on Robinhood Chain". False on this chain per the guide.
* **§6.4 — the Hyperliquid market figures.** `$213B`, `32.2%`, `$3.6B` RWA open interest
  "passing Bitcoin", `23/30`, `52%` of weekly volume. They appear in
  `about/Stats.tsx`, `home/TheGap.tsx`, `home/WhyNow.tsx`, `home/Research.tsx` and
  `about/Story.tsx`, several as animated counters, and they are attributed to Robinhood
  Chain. The guide says they are Hyperliquid's, and one is baked into a live route slug, so
  this needs the owner's decision on the slug, not a string edit.
* **§6.5 — "Deposit USDC".** The collateral is USDG on mainnet and tUSDG here. 39
  occurrences of `USDC` remain outside the dashboard, across eleven files in `home/`,
  `learn/`, `vaults/`, `roles/`, `Vaults.tsx` and `Legal.tsx`. I changed it only in the four
  sentences I was already rewriting for cadence
  (`Footer`, `home/Compare`, `home/HowItWorks`, Design Laws 01/02 → "collateral margin"),
  which leaves the site internally inconsistent until someone does the whole sweep. The
  dashboard itself is clean: it reads `collateralSymbol` ("tUSDG") throughout.
* **§6.6 — the redemption SLA.** Partly fixed, because one instance was not a missing
  caveat but a false statement about the user's money: `home/HowItWorks.tsx` said
  "USDC at oracle price returns to you in the same transaction. Redemption is never gated,
  **never queued**, never paused for convenience", which contradicts `requestRedeem`, the
  receipt queue and the 14-day venue priority expiration that `MintRedeem` already
  publishes. It now says the collateral returns in the same transaction below the instant
  cap, is queued and paid by claim above it (two batch round-trips expected, 14 days worst
  case), and that redemption is never *refused* because `forceExit` is gated on nothing.
  `home/Compare.tsx`'s "Always, at oracle price" cell gained "instant under the cap, queued
  above it". The rest of §6.6 — the rollup escape hatch, and the same SLA wherever else
  redemption is described — is not done.

Two more things I could not honestly resolve:

* **The marketing site still describes the funding/fee/staking machinery as if it were
  live.** `home/Faq.tsx`, `home/HowItWorks.tsx`, `Legal.tsx`, `vaults/data.ts`'s shared
  `FUNDING_PARA` and `learn/data.ts` all describe the buffer → `fee_on` → `mint_slow` →
  `insurance_draw` cascade in the present tense, and `roles/TokenFlow.tsx` publishes an
  `80 / 10 / 5 / 5` fee split for a token that is not deployed. I fixed this inside the
  dashboard, where the figures next to the words are live reads, and stopped there:
  rewriting the product narrative on a dozen marketing pages is an editorial decision about
  what the project is promising, not a wiring task, and half-doing it would leave the site
  contradicting itself. It is the largest remaining honesty gap in the repo.
* **`bufferPct`.** Stage 1 asked and stage 2 could not settle whether `bufferCapacity18()`
  is remaining headroom or total capacity, so the bar is labelled by its formula with both
  absolutes shown next to it. That is still the state, and it still needs an answer from
  the contracts side — if it is headroom, the bar looks fullest exactly when the vault can
  accept no more mints.

Unchanged from stage 2's list: the solvency series, funding bars, 24h change, flow list and
receipts screen all wait on an event indexer, and `uSPY` still uses `/logo.png` because
there is no `cert-plate-uspy.jpg`.
