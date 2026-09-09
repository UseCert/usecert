# Integration stage 2 — the dashboard

Feeds the live UseCert deployment on **Robinhood Chain testnet, chain 46630** into the
existing dashboard components through the stage-1 chain layer. No component library was
rewritten: the store keeps publishing the `Vault` / `SeriesPoint` / `FundingBar` shapes the
views already consumed, and what changed is where the numbers come from and what happens
when there is no number.

Verification: `npx tsc --noEmit` exits **0**. `git status` shows no `package-lock.json` and
no `bun.lock` change. No dependency was added, no lifecycle script or CI workflow was
created, `bunfig.toml` is untouched, and `src/chain/contracts.ts` was treated as read-only.

Not done here, by instruction: `StakingView.tsx` and `KeepersView.tsx` (they map to
contracts that do not exist — `InsuranceStaking` and `CERT` are C3, and four of the five
advertised keepers are fiction), and the nine copy items in guide §6.

---

## 1. Files changed

| File | What changed |
| --- | --- |
| `src/pages/dashboard/store.tsx` | **Rewritten.** Live provider: `useLiveVaults`, `useVaultConfigs`, `useUserBalances`, `useConnection`, `useBlockNumber`, `useSwitchChain`, `useDisconnect`. `VaultId` gains `"uspy"`. Every figure nullable. Mock engine, seeded flows and generated series removed. Staking + keeper mocks kept verbatim for the two untouched views. |
| `src/pages/dashboard/Overview.tsx` | Live stat cards (buffer and accrual as two separate cards), one provable solvency point, honest empty state where the 60-point curve was, five-row vault table with greyed rows carrying no figures, flows empty state. Sparklines removed. |
| `src/pages/dashboard/OverviewExtras.tsx` | `TickerStrip` (price + age, no invented 24h change or funding rate), `BackingComposition` (margin + buffer held, accrual in a separate register below the total), `FundingMonitor` (accrual claim + empty state), `NetworkStrip` (all cells now reads or documented constants), `PegMonitor` → oracle monitor driven by `basisBpsChecked()`, `mintAllowed()` and `cfg()`. |
| `src/pages/dashboard/VaultsView.tsx` | Five-vault selector with the three unrouted ones disabled; live hero, stat grid and parameters from `cfg()`; buffer-vs-capacity panel replacing the invented threshold meter and funding-shock simulator; empty states for both charts. |
| `src/pages/dashboard/RiskView.tsx` | Risk posture, waterfall, parameters and attestations driven by chain reads; rows with no on-chain source shown blank instead of invented; buffer-held vs accrual-claimed panel added. |
| `src/pages/dashboard/MintRedeem.tsx` | **Rewritten.** Real approve → routed mint / redeem, `UseQueuedRedeem` fallback, ungated `forceExit`, receipt claiming with retryable `AwaitingSettlement` + `recallMargin`, faucet, bigint quotes, wrong-network banner. |
| `src/pages/dashboard/chrome.tsx` | `TopBar`: real block height, three-state health chip (including "unknown"), attested margin/notional **with its age**, chain 46630 label and a wrong-network switch. |
| `src/pages/dashboard/modals.tsx` | `WalletModal` uses `useConnectors()` / `useConnect()` instead of three hardcoded wallets and a mock account; `WalletButton` uses the real address and `explorerAddressUrl`. |
| `src/pages/dashboard/ActivityView.tsx` | Honest "needs an indexer" empty state; asset filter built from the real vault list; "Load more" hidden while there is nothing to load. |
| `src/pages/dashboard/ui.tsx` | New primitives: `EmptyState`, `AgeLine`, `UnverifiedTag`, `PriceUnavailable`. |
| `src/pages/dashboard/format.ts` | New `fmtOrDash`, `fmtAge`, `fmtCountdown`, `EM_DASH`. Removed `mulberry32` (it existed only to generate the mock series). |
| `src/pages/dashboard/flowMeta.ts` | `uspy` entry added (`/logo.png` + `imgPlaceholder: true`); `uspx` retitled "S&P 500 Index Certificate" so it is not confusable with the live uSPY. |
| `src/pages/dashboard/CommandPalette.tsx` | Footer said "Mainnet"; now "Testnet 46630". (It already only offered `LIVE` vaults.) |
| `src/pages/dashboard/charts.tsx` | Header comment only: both charts are now unmounted because no series exists. Kept unchanged for whenever an indexer can feed them. |
| `src/chain/useVaults.ts` | Three additive edits: `MirrorMeta` exported, `chainVaultMeta(id)` exported (so a loading placeholder cannot invent a routed vault's name or plate), and `supply` / `buffer` / `bufferPct` / `delta` / `change24h` / `funding8h` narrowed back to non-null on `LiveVault`. Plus the stale "stage 2's job" comment on `ChainVaultId` updated. No behaviour changed. |

Untouched: `StakingView.tsx`, `KeepersView.tsx`, `Toasts.tsx`, `flows.tsx`, `hooks.ts`,
`Dashboard.tsx`, `src/chain/contracts.ts`, `src/chain/config.ts`, `src/chain/units.ts`,
`src/chain/useActions.ts`, `src/routes/__root.tsx`, `package.json`.

---

## 2. The five vaults, and how a greyed one renders

`VaultId` is now `"utsla" | "uspy" | "unvda" | "uspx" | "uqqq"`. All five stay in the UI.

| id | `status` | badge | figures |
| --- | --- | --- | --- |
| `utsla` | `LIVE` | LIVE | real, from chain |
| `uspy` | `LIVE` | LIVE | real, from chain |
| `uspx` | `SOON` | SOON | none |
| `uqqq` | `SOON` | SOON | none |
| `unvda` | `UNPLANNED` | **NOT PLANNED** | none |

`SOON` is reused for uSPX and uQQQ because the roadmap does list them, which is what makes
the word defensible. uNVDA is not planned at all, so it gets `UNPLANNED` / "NOT PLANNED"
rather than a promise the project has not made. `STATUS_HINT` supplies the tooltip that
says why there are no figures.

### No numbers at all — enforced by the compiler, not by discipline

This was the priority, so it is a type property rather than a convention. On the store's
`Vault`, every figure is nullable: `price`, `supply`, `buffer`, `bufferPct`, `delta`,
`deltaBps`, `change24h`, `funding8h`, `ageSec`, `hotBuffer`, `bufferCapacity` and
`backing`. An unrouted vault is built by `emptyFigures()`, which sets all of them to
`null`, `solvency` to `[]` and `funding` to `[]`.

A component therefore cannot render a greyed vault's figure without first handling the
`null` — passing one to a formatter is a compile error (negative test 3 below). Every cell
goes through `fmtOrDash(value, format)`, which renders an **em-dash**. There are no zeros,
no stale mock values and no placeholder curve anywhere on a greyed row.

Presentation of a greyed vault: `opacity-40 grayscale`, `pointer-events-none`,
`aria-disabled`, no chevron, no click target, a neutral (not warning-coloured) status pill,
and the status hint as the tooltip. In `VaultsView` the selector buttons for those three are
`disabled`; in `MintRedeem` the asset dropdown marks them `disabled` with a "not deployed"
hint, and `isChainVaultId` is the only door from a `VaultId` into `useCertActions`,
`useVaultConfig` or an address lookup — so the write path cannot be handed `uqqq` by
accident. Selecting one in `VaultsView` shows a panel that says it is not deployed instead
of a stat grid.

`uSPY` keeps stage 1's honesty about artwork: `/logo.png` with `imgPlaceholder: true`,
rendered `object-contain` with a caption saying a neutral mark is used rather than another
certificate's plate. It does not borrow `cert-plate-uspx.jpg`.

The `Record<VaultId, …>` knock-ons were fixed rather than dodged: `FLOW_META` (in
`flowMeta.ts`) gained a `uspy` entry, `positions` is now
`Record<VaultId, number | null>` sourced from `useUserBalances().certificates` with `null`
for the three unrouted ids and for "no wallet connected", and the mock `prices` /
`FLOW_NAMES` maps disappeared with the seeded flow generator they fed.

---

## 3. The four things that would make the UI lie

### 3.1 `bufferHeld` and `accrualClaimedUnverified` are never one figure

They are never added anywhere in the store, and `aggregateTotals` (stage 1) already sums
them separately — `totals.buffer` and `totals.accrualClaimedUnverified`. On screen they are
in different visual registers, and the second is always labelled:

* **Overview** — two separate stat cards. "Buffer Held (ERC-20)" is white on the normal
  panel with the note "collateral the vaults actually hold". "Accrual Claimed" sits on a
  warn-tinted panel, in silver rather than white, with the `UnverifiedTag` badge in the
  card header and the note "attester-relayed P&L · not money · not added to the buffer".
* **BackingComposition** — the headline figure is "attested margin + buffer held" and the
  stacked bar has exactly two segments (margin, buffer held). The accrual claim is below a
  hairline rule, in its own block, tagged unverified, with a sentence saying it is not
  collateral and not in the figure above.
* **FundingMonitor** — the whole panel is tagged unverified; the per-vault figure is
  labelled "cumulative claim, not a rate".
* **VaultsView** — "Buffer held (ERC-20)" is the accented stat; "Accrual claimed" is a
  separate stat carrying `UnverifiedTag`.
* **RiskView** — a dedicated two-up panel, "Buffer held · ERC-20 balance" (measured, green)
  against "Accrual claimed · attester-relayed" (unverified, warn-bordered), with the
  100,000.01-vs-91,028.00 history stated as the reason.

`accrualIsVerified` stays typed as the literal `false` on the way through, and the accrual
is not part of `solvency[0].backing` (stage 1 already excluded it; nothing here adds it).

### 3.2 `ageSec` is on screen wherever backing is

`AgeLine` renders "proven 41s ago" and, when `attestationStale`, appends
"· attestation stale (>300s) · minting off" in warn colour. It also shows `provenAtBatch`
where there is room. It appears in: the Overview header (worst age across routed vaults),
the notional stat card, every row of the Overview vault table, the ticker strip, the
backing-composition headline, the funding panel per vault, the VaultsView hero, the oracle
monitor table, the quote panel in `MintRedeem`, the RiskView posture row, and the top bar
next to the margin/notional figure. `totals.worstAgeSec` is published, never an average.

`MAX_ATTESTATION_AGE_SEC` (300) flows from stage 1 into the store as
`maxAttestationAgeSec` and is displayed in the network strip, the RiskView attestation
table and the VaultsView parameter list. When minting is blocked, the mint panel says
whether the cause is the price, `mintAllowed()`, or an attestation older than 300 s setting
capacity to zero — which is the "healthy deployment looks broken" case.

### 3.3 `priceUnavailable` renders as a state, never `$0.00`

`price` is `null` whenever `oracle.px()` reverted, so a zero cannot be printed by accident.
Everywhere a price appears there is a branch: the `PriceUnavailable` component reads
"Price unavailable · minting paused", with a tooltip explaining that the feed is stale,
deviant or badly fed and that this is designed behaviour. The Overview table shows
"unavailable" in warn colour; the ticker shows "price unavailable · minting paused"; the
oracle monitor shows "unavailable" plus a separate Allowed/Paused pill from
`mintAllowed()`; the VaultsView hero swaps the big price for the same component.

Redemption is stated in the same breath: the mint panel's blocked notice ends "Redemption
is unaffected and still works", the oracle monitor footer repeats it, and the redeem tab is
never disabled by price state — only the mint submit is.

### 3.4 `historyUnavailable` renders an honest empty state

Nothing is interpolated, no value is repeated, and the mock curves are gone (the seeded
generators and `mulberry32` were deleted, not left dormant).

* Overview: the 60-point chart is replaced by the single provable point (backing vs
  obligation, both summed from stage 1's one `SeriesPoint`) plus an `EmptyState` reading
  "No solvency history yet: needs an indexer", explaining that no view function returns a
  series and a curve would have to be invented. When any oracle reverted it also says that
  vault's obligation falls back to the attested `notional18` — different provenance.
* VaultsView: same treatment per vault, plus a funding panel that is entirely an empty
  state.
* FundingMonitor: "No funding history yet: needs an indexer", saying there is no 8-hour
  rate to publish because the only figure the chain gives is a cumulative claim.
* `change24hUnavailable` — every 24h delta, arrow and sparkline was removed rather than
  filled: the ticker, the stat cards and the vault table no longer have a 24h column.
* `funding8hUnavailable` — no funding rate, annualised figure or mini-bars anywhere.
* Flows: `flows` is `[]` with `flowsUnavailable: true`; Overview's strip and ActivityView
  both explain that receipt ids are not enumerable on-chain, there is no
  `receiptsOf(user)`, and the previous list was generated locally.
* `charts.tsx` is left in place, unmounted, with a comment warning not to feed it
  interpolated values.

Two smaller fabrications in the same class were also removed: the "oracle vs market"
spread and 24h volume columns (no market price and no volume exist on this chain — the
table is now driven by `basisBpsChecked()`), and the keeper-derived cells in the network
strip ("keepers online 5/5", "oracle latency 38ms", "block time 0.40s", "indexer lag 0
blocks"), which are now block height, chain id, vaults routed, worst attestation age,
minting allowed, independent basis, and an explicit "Indexer: none".

`basisKnown === false` is rendered as "no independent basis", never as `0.00%`.

---

## 4. The two mappings stage 1 asked me to confirm

### `bufferPct = bufferHeld / bufferCapacity18` — **does not survive as a "percent of target" bar; presentation changed**

It produces a bar, but not one that means what the store's old comment ("percent of
target") implied, and the direction may be inverted:

* the guide calls `bufferCapacity18()` **capacity headroom** (§3.1), and §4 says that on
  `CertVault_AtCapacity` a UI should "show `bufferCapacity18` **and the cap**" — i.e. it is
  not itself the cap;
* if it is headroom, the ratio is unbounded and rises as headroom shrinks, so the bar looks
  *fullest* exactly when the vault can accept no more mints, and stage 1's `clampPct`
  silently pins anything over 100 % at 100 %;
* if it is instead a total capacity figure, the ratio is a sensible 0–100 % fill.

I could not settle which from the ABI alone, so I did not present it as a health gauge. The
percentage is kept but labelled by its formula — "buffer held / bufferCapacity18 = 41.2%"
in VaultsView, "· 41% of capacity18" with a tooltip in the Overview table, "buffer held /
bufferCapacity18" in RiskView — and the two absolute figures (`hotBuffer()`,
`bufferCapacity18()`) plus the held balance are shown next to it, with a line saying to
read the absolutes rather than the bar. The old `ThresholdMeter` went with it: its 20 / 45 /
70 ticks labelled `Insurance_Draw` / `Mint_Slow` / `Fee_On`, its `bufferStatus()` sentences
about a "2 bps/day holding fee" and a "mint slow zone", and the funding-shock simulator all
described mechanisms that are not deployed on these contracts. **Recommendation for stage
3 / the contracts side: confirm whether `bufferCapacity18()` is remaining headroom or total
capacity, and label the bar accordingly.**

### `delta = 1 + deltaBps/10_000` — **not rendered; magnitude only**

`deltaBps` is unsigned on-chain, so the direction of the drift is not published and
`delta` cannot be shown as `0.998` / `1.002` without inventing a sign. Nothing in the UI
renders `Vault.delta` or `totals.delta` any more. Every delta readout uses the raw
`deltaBps` that stage 1 exposed, as a magnitude: "0.42% from target" in the Overview table
("Delta drift" column), "Delta drift from 1.0 · 0.42%" in VaultsView, and "Worst delta
drift" in RiskView with the note "magnitude only — deltaBps is unsigned on-chain". No
arrows, no signs, no colour coding by direction. `totals.delta` is still computed by stage
1's `aggregateTotals`; it is simply not displayed.

---

## 5. Mint and redeem

* **Approval first.** Step 1 in the mint panel is `TestUSDG.approve(vault, amountIn)` at
  **6 decimals** via stage 1's `approve`, which uses `toCollateral`. It is a separate,
  labelled step because both mint paths spend collateral.
* **Size fork, decided before submitting.** `route` is computed with stage 1's `routeMint`
  / `routeRedeem` from `cfg().instantCap18` — read, never hardcoded — and the panel names
  the function that will be called (`mintInstant` / `requestMint` / `redeemInstant` /
  `requestRedeem`) with the cap in dollars. The submit button is disabled while
  `isRoutable` is false (`cfg()` not loaded), so nothing is guessed; the label says the
  button is waiting on `vault.cfg()`. `CertVault_AboveInstantCap` /
  `BelowInstantCap` are classified `routing-bug` and presented as an app bug to report,
  not a user error.
* **`CertVault_UseQueuedRedeem` is not a failure.** `redeem()` returns
  `{ status: "needs-queued" }`; the UI shows an **info** notice ("Instant buffer is thin —
  use the queue") with the contract's own sentence and a button that calls `requestRedeem`.
  No red toast, no failure state, and the pending toast is withdrawn rather than flipped to
  an error.
* **`CertVault_AwaitingSettlement` is retryable, never terminal.** The receipt panel's
  claim path returns `{ status: "awaiting-settlement", retryable: true }` and the UI says
  "Awaiting settlement — retryable, not failed", adds that the receipt stays claimable
  indefinitely, and offers a `recallMargin()` button (also available standalone). Nothing
  in the code marks a receipt failed.
* **Queue timings, published honestly.** Queued redemption says "two batch round-trips
  (one to close, one to withdraw), then you claim", and the 14-day venue priority
  expiration is named as the real worst case. `requestMint` says a keeper calls
  `settleMint`, that this step is not the user's, and that after the 24-hour settle window
  anyone including the user may stage and claim a full refund.
* **`forceExit` is gated on nothing.** Its own button on the redeem tab, enabled by amount
  and wallet only — no buffer level, no capacity, no `mintAllowed`, no price state — with
  the tooltip saying so.
* **The decimals trap.** All quoting is exact `bigint` maths through stage 1's named
  converters: `toCollateral` (6 dp) and `toCert` (18 dp) parse the input **string**,
  `quoteCertOut18` / `quoteCollateralOut6` produce the output, `feeAmount18` produces the
  fee as its own figure (shown separately, never folded into the rate), and
  `scaleCollateralTo18` supplies the mandatory 10¹² factor. `fromCert` / `fromCollateral` /
  `fromPrice18` are used only for display. No generic `format(value, decimals)` was added
  or wanted. The panel states "Collateral is 6 decimals in, certificates 18 decimals out"
  and the quote is labelled indicative because of venue quantisation and the keeper's fill
  price. "Max" truncates rather than rounds, so it cannot ask for more than the wallet
  holds.
* **Faucet.** Wired prominently on the mint screen, since `TestUSDG.mint` is owner-gated
  and `TestFaucet.claim()` is the only source of collateral: drip amount, the faucet's own
  balance (in warn colour when empty, with "an empty faucet is a faucet problem, not a
  minting problem"), and `nextAvailableAt` as a countdown on a disabled button.
* **Wallet and network.** The connect flow is real (`useConnectors` / `useConnect` /
  `useDisconnect`), only chain 46630 is offered, and a wrong-network banner plus a
  `switchChain` button appear in the mint panel and the top bar. Mainnet is still
  deliberately absent, and the modal says why.

---

## 6. Negative tests

A green `tsc` is only evidence if it has been seen to go red. Three deliberate breakages,
each confirmed to fail and then reverted (`tsc` back to 0 after each):

1. **Wrong-typed argument on a write hook.** `actions.claimRedeem(receiptId)` →
   `actions.claimRedeem(receiptStr.trim())` in `MintRedeem.tsx`:
   `error TS2345: Argument of type 'string' is not assignable to parameter of type 'bigint'.`
2. **Bad contract-function name.** `call(mirror.vault, CertVaultABI, "hotBuffer")` →
   `"hotBufffer"` in `useVaults.ts`:
   `error TS2345: Argument of type '"hotBufffer"' is not assignable to parameter of type '"oracle" | "governance" | … | "hotBuffer" | …'`
   — stage 1's `call()` helper still checks read names against the ABI after this stage's
   edits to that file.
3. **A greyed vault's nullable figure sent straight to a formatter.** In the Overview vault
   table, `<Cell value={v.supply} …>` → `{fmtNum(v.supply, 2)}`:
   `error TS2345: Argument of type 'number | null' is not assignable to parameter of type 'number'.`
   This is the one that matters most: it is the compiler, not review, that stops a greyed
   vault from acquiring a number.

There is no proof that anything renders — the app was not run, and no script from its
`package.json` was executed. Correct types, correct contract calls and no fabricated data
are the bar this stage clears.

---

## 7. Left for stage 3

* All nine copy items in guide §6, including the strings that sit next to the new data:
  "Solvency public / every block" and "C1 Live" on the Overview strip, "provable on-chain
  every block" in Design Law 01, "invariant holds, every block", "Backing ≥ Supply × Price"
  in the sidebar, and the missing **"simulated venue"** banner. Item 1 needed `provenAtBatch`
  and `ageSec` in the data model first; they are there now, so it is a string edit at last.
* Disposition of `StakingView` and `KeepersView`, and of the mock state they still run on
  (`tokenLiquid`, `tokenStaked`, `totalStaked`, `rewards`, `cooldowns`, `keepers`,
  `runKeeper`, and the `stake` / `unstake` / `claim` / `fastForward` / `withdraw`
  simulations in the store, which are the only remaining invented numbers in the app). The
  store's file header marks them as such. Note that `KeepersView` advertises five keepers
  and a "5 bps of rebalance" bounty; only `recallMargin()` and `rebalance()` are real, and
  both are already exposed on `useCertActions`.
* The `RiskView` stress-scenario table, which is modelled analysis rather than a chain
  read. Its header hint now says "Modelled, not measured" instead of "Re-run each epoch".
* An event indexer. It is the single unlock for the solvency series, the funding bars, the
  24h change, the flow list and a real receipts screen — five separate empty states point
  at the same missing piece.
* A `cert-plate-uspy.jpg`, so uSPY can stop using the neutral logo.
