# UseCert — roadmap

Rewritten 2026-09-21 against the live deployment and the branch tip, replacing the version
written earlier the same day. Several items in that one were already fixed by the time it was
written, and its most urgent finding turned out to be real. Both are recorded below rather
than quietly dropped.

Effort: **S** (minutes), **M** (half a day), **L** (multi-day, or blocked on a decision).

---

## Closed since the last revision

| Item | What it was | Closed by |
|---|---|---|
| **0.0** | `SolvencyRegistryABI` used at two call sites, never imported — branch did not typecheck, `mint()` threw before submitting | `fb5c7cd` |
| **0.1** | Relay addressed to `a.registry` from the API payload instead of the pinned constant | `fb5c7cd` |
| **0.2** | 275px of horizontal scroll at 375px — five `whitespace-nowrap` classes | `fb5c7cd` |
| **2.1** | `/api/attestations` did not exist; minting was off protocol-wide | signer service, live and serving |

**0.0 was mine.** The typecheck caught it *after* I had pushed `4b0fbfa`; I fixed the file on
the server and deployed it without committing the fix. The deployed site worked and the branch
did not, which is the worse way round — anyone checking out the branch could not mint, and
neither `vite dev` nor the rolldown build would have told them why. **See 3.4: a `tsc --noEmit`
gate would have made this impossible.**

---

## Deploy tooling now available

Worth knowing before planning work, because it changes what "deploy fast" costs.

- **`usecert-maintenance on|off|status|allow <ip>|deny <ip>`** — use-cert.com only. A flag file
  checked per request, so flipping it needs no reload, no rebuild, and works when the app
  itself is broken. Returns 503 with `Retry-After`, never 200, so intermediaries do not cache
  it and crawlers do not index it as content. `allow` lets one address through to test the fix
  from the same browser that is seeing the page. qwilon and orion-safe are deliberately out of
  scope — they are separate products.
- **`orion-deploy` / `orion-rollback`** — atomic symlink swap for Orion-Safe. Proven zero
  downtime across a full rebuild; rollback is instant and needs no rebuild.
- **`usecert-signer`** — signs attestations every 30s and serves them at `/api/attestations`.
  Holds the attester key and cannot broadcast: its environment carries `ATTESTER_PK` and not
  the deployer or governance keys.
- **`usecert-backup` / `usecert-restore`** — nightly `pg_dump` of every database, with a
  verify step that reads the archive back rather than trusting an exit code.

UseCert's own front end has **no atomic deploy** — a rebuild replaces `.output` in place and
the service restarts. See 0.5.

---

## Phase 0 — quick wins, deployable in one pass

All small, all independent, none blocked on anyone.

### 0.3 Real provenance in the generated bundle — **S**

`src/chain/contracts.ts:5` reads `Deployment: block 11746408, commit signed-attes` — a
truncated free-text string where a commit hash belongs. `scripts/gen-frontend-abi.py` takes
`{commit}` from the `COMMIT` environment variable, so whatever the deployer typed ends up
presented as provenance.

Make the generator derive it (`git rev-parse HEAD`) and refuse to run on a dirty tree, so the
string cannot be hand-set and cannot claim a commit that does not describe the build.

### 0.4 uSPY certificate plate — **S**

`src/chain/useVaults.ts:177` points uSPY at `/logo.png` with `imgPlaceholder: true`.

**`public/cert-plate-uspx.jpg` already exists.** Either that art is uSPY's and the entry just
needs pointing at it, or the filename is wrong and the plate is genuinely missing — worth a
look before commissioning artwork. Every other vault has a plate.

### 0.5 Atomic deploy for the UseCert front end — **S**

Orion-Safe got this after a rebuild left the site returning 403 for 24 seconds: `react-scripts`
empties the output directory before writing it, and nginx served the gap. UseCert's front end
has the same exposure — `bun run build` replaces `.output` in place and `usecert-web` restarts
on top of it.

The fix is the one already proven next door: build to a staging directory, swap a symlink with
`rename(2)`, keep the previous release for an instant rollback. Until then, `usecert-maintenance
on` before a deploy is the honest stopgap.

### 0.6 Stop the root-owned build artifacts recurring — **S**

`/opt/usecert-web` accumulated 33 root-owned files from a build run as root, which then broke
three consecutive rebuilds with `EACCES` on `.output` and `node_modules/.nitro`. Fixed by hand;
nothing prevents it happening again. A deploy script that refuses to run as root would.

---

## Phase 1 — the honesty sweep

Copy that overstates what exists. Most are small edits; three need an editorial decision, which
is why they have sat.

### 1.1 Finish the collateral rename — **S**

`USDC` remains in five files. The collateral is `tUSDG` here and USDG on mainnet:
`dashboard/store.tsx`, `home/HowItWorks.tsx`, `home/Testimonials.tsx`, `learn/data.ts`,
`roles/RolesAccordion.tsx`.

### 1.2 Drop "the first holdable stock certificates" — **S**

`src/pages/Learn.tsx:40`. False on this chain.

### 1.3 Resolve the custodial-token claim — **M** *(editorial)*

"No custodial stock token exists on Robinhood Chain" — `home/TheGap.tsx:79` and a tooltip in
`home/Compare.tsx:146`. Robinhood Stock Tokens are live, so it is wrong, but `Compare.tsx`
builds a whole comparison column on the premise. Deciding what that column becomes is the work;
the string edit is trivial.

### 1.4 Reattribute the market figures — **M** *(editorial)*

`$213B`, `32.2%`, `$3.6B`, `23/30`, `52%` are presented as Robinhood Chain's and are
Hyperliquid's — `about/Stats.tsx`, `about/Story.tsx`, `home/TheGap.tsx`, `home/WhyNow.tsx`,
`home/Research.tsx`, and `learn/data.ts:35`, where `$213B` is **baked into a live route slug**
(`rwa-perps-213b-none-holdable`). The slug is why this needs a decision: changing it breaks an
existing URL.

### 1.5 Stop describing undeployed machinery in the present tense — **M/L** *(editorial)*

The largest remaining gap. The `fee_on` → `mint_slow` → `insurance_draw` cascade is written as
live in `home/Faq.tsx`, `home/HowItWorks.tsx`, `Legal.tsx`, `vaults/data.ts` and
`learn/data.ts`. `roles/TokenFlow.tsx:7` publishes "80% of protocol fees go to open market token
buyback" for a token that is not deployed.

The dashboard is already clean — its figures are live reads. This is the marketing surface, and
half-doing it leaves the site contradicting itself.

### 1.6 Finish the redemption SLA — **S**

`home/HowItWorks.tsx` and `home/Compare.tsx` were corrected. The rollup escape hatch, and the
same SLA wherever else redemption is described, were not.

---

## Phase 2 — make the app whole

### 2.2 An indexer for the series data — **L**

Narrower than it looks: the flow list is solved (`useFlows.ts` reads Blockscout directly). Still
missing — solvency history (`Overview.tsx:346`, `VaultsView.tsx:230`), funding history
(`OverviewExtras.tsx:192`), and receipt enumeration (`MintRedeem.tsx:857`; there is no
`receiptsOf(address)` on `CertVault`).

### 2.3 Settle `bufferPct` — **S once answered** *(blocked on contracts)*

Whether `bufferCapacity18()` is remaining headroom or total capacity. If it is headroom, the bar
looks fullest exactly when the vault can accept no more mints — the opposite of what a viewer
reads.

### 2.4 `RiskView` stress table — **M**

Modelled, not measured. The header says so, which is honest, but it should either be driven by
real parameters or moved out of the dashboard.

### 2.5 Relay UX when the signer is down — **S**

`fetchSignedAttestations()` returns `null` on failure and the mint proceeds to revert
`CertVault_AtCapacity` — deliberately, because that is the accurate on-chain reason. But the
user sees a failed transaction with no explanation. The mint panel should say the attestation
service is unreachable *before* they sign.

---

## Phase 3 — mainnet prerequisites

### 3.1 Close the C1 audit criticals — **L**

The four criticals are closed in code and the PoCs now fail on the guards rather than on their
assertions. What remains is a re-audit of the **signed-attestation path**, which is new since
C1 and sits directly on the capacity gate.

### 3.2 Real collateral and a real venue — **L**

Mainnet uses USDG, not `tUSDG`, and `testFaucet` disappears. `lighterSim` is a simulator where
`setMarkPrice()` creates any index implicitly — which is why `basisBpsChecked()` returns
`known == false`. Against a real venue that boolean starts meaning something.

**Blocking sub-item, carried from the deploy script's own warning:** uSPY's market index 26 and
uQQQ's 27 are placeholders, recorded as `marketIndexVerified: false`. On the simulator an
unverified index deploys clean; on a real venue it pushes the **wrong market's mark**. Re-read
`market_id` from `api/v1/orderBookDetails` and redeploy those mirrors first.

### 3.3 Attester key custody and rotation — **L**

Rotation exists on-chain with a 2-day notice. What is missing is operational: the signing key
currently sits in a file on the same host that serves the site. The whole mint path depends on
that one key and that one process.

### 3.4 A typecheck gate — **S, and it should be next**

No CI. `vite dev` and the rolldown build do not run `tsc`, which is exactly how a branch with
two `TS2304` errors got recorded and deployed (0.0). `npx tsc --noEmit` catches that class in
seconds.

This is an **S** sitting in Phase 3 because it is a prerequisite, not because it is hard. It is
the single highest-leverage item in this document.

### 3.5 Release provenance — **M**

No signed commits, no CI, no published address book a user can verify against the explorer.
Depends on 0.3.

---

## Suggested order

1. **3.4** — the typecheck gate. It is minutes, and it is the reason 0.0 shipped.
2. **Phase 0** — 0.3, 0.4, 0.5, 0.6 in one pass. All small, all independent.
3. **1.1, 1.2, 1.6** — the copy edits with no decision attached.
4. **1.3 / 1.4 / 1.5 as one editorial session**, since all three are the same question: what
   does the project claim, and in what tense.
5. **3.2's market indices** before anything touches a real venue.
