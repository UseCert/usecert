# Integration stage 1 — the chain layer

Wires this front-end to the live UseCert deployment on **Robinhood Chain testnet, chain
46630**. This stage adds the chain layer only: config, units, read hooks, write hooks and
the wagmi provider. **No dashboard component and no copy was changed** — those are stages
2 and 3.

Verification: `npx tsc --noEmit` exits **0**. `bun.lock` is unmodified and there is no
`package-lock.json`.

---

## 1. Files

| File | Status | What it is |
| --- | --- | --- |
| `src/chain/contracts.ts` | pre-existing, untouched | Generated from the Foundry artifacts. Treated as read-only. |
| `src/chain/config.ts` | **new** | wagmi config for chain 46630, `injected()` connector, http transport. |
| `src/chain/units.ts` | **new** | The four decimal domains, one named function each. |
| `src/chain/useVaults.ts` | **new** | Batched live reads, shaped to the existing dashboard interfaces. |
| `src/chain/useActions.ts` | **new** | Write hooks, size routing, revert decoding. |
| `src/routes/__root.tsx` | **modified** | `WagmiProvider` added around the existing `QueryClientProvider`. |
| `package.json` | **modified** | `wagmi` and `viem` added to `dependencies`. |

Nothing else was touched. Specifically: no lifecycle scripts, no CI workflow, no
`bunfig.toml` change, no `bun.lock` change, no dependency other than `wagmi` and `viem`.

### Dependencies

`wagmi@^3.7.7` and `viem@^2.56.3` were added to `package.json` only. The lockfile is
updated by whoever next runs `bun install` — bun is not installed in this environment and
`bun.lock` must not be hand-edited. To make `tsc` resolve the types here, both packages
were installed into `node_modules` out-of-band (built in a scratch directory and copied
in) so that npm never rewrote the bun-installed tree; the repo's own `react` 19.2.8 and
`@tanstack/react-query` 5.102.8 were left exactly as they were.

Both versions clear the 24-hour supply-chain guard in `bunfig.toml` comfortably —
wagmi 3.7.7 published 2026-08-27, viem 2.56.3 published 2026-09-02 — so **no
`minimumReleaseAgeExcludes` entry was added**, and none is needed.

---

## 2. `src/chain/config.ts`

* Chain 46630 only. Mainnet 4663 is deliberately absent (guide §1, §7): that chain ID has
  never been verified from the contracts repo.
* The chain definition is derived from the generated `CHAIN` constant via `defineChain`,
  not redeclared.
* **Nothing touches `window` at module scope.** The app is server-rendered (TanStack
  Start), so `createConfig` is not called at import time. Instead `getWagmiConfig()`
  builds it lazily and memoises it; `__root.tsx` calls that inside the component. The
  config sets `ssr: true` and uses `cookieStorage`, and the `injected()` connector only
  reaches for `window.ethereum` when actually used in the browser.
* Helpers: `isSupportedChain(chainId)` for gating the app and offering a switch, plus
  `explorerTxUrl` / `explorerAddressUrl`.

---

## 3. `src/chain/units.ts` — the units API, and why every function is separate

There are four decimal domains and they are not interchangeable. The trap is that
`mintInstant(amountIn)` takes **6-decimal** collateral and returns **18-decimal**
certificates, and `redeemInstant(certIn)` is the reverse — so one shared
`formatUnits(v, 18)` is wrong on about half the numbers in this app.

**There is deliberately no `format(value, decimals)` export.** A generic formatter puts
the decimal count at the call site, where it is a parameter someone can get wrong and
nobody reviews. Each domain therefore gets its own name, and choosing the wrong domain has
to be spelled out to be done:

| Function | Domain | Used for |
| --- | --- | --- |
| `fromCollateral` / `toCollateral` | **6** dp | `amountIn`, `amountOut`, `hotBuffer()`, tUSDG balances, `approve` |
| `fromCert` / `toCert` | **18** dp | `certIn`, `certOut`, cert balances, `totalSupply` |
| `fromPrice18` / `toPrice18` | **18** dp | `px()`, `*Px18`, `notional18`, `margin18`, `buffer18`, `accrual18`, `instantCap18`, `bufferCapacity18` |
| `fromFeed8` | **8** dp | raw aggregator answers (debug only — read prices through `CertOracle`) |
| `fromBps` | bps → **percent** | `mintFeeBps`, `deltaBps`, `basisBps` |
| `fromBpsFraction` | bps → **fraction** | when a multiplier is wanted rather than a label |

`fromPrice18` and `fromCert` are both 18 decimals and are still separate functions on
purpose: they are separate *value classes*, and keeping them apart is what stops a
certificate quantity being formatted as a price or a price being fed into `toCert`.
`fromBps` and `fromBpsFraction` are separate because returning `0.1` and `0.001` for the
same input is exactly the factor-of-100 slip this file exists to catch.

**Precision — documented in the file itself.** The `from*` functions return a JS `number`
because the existing UI works in `number`, and a double cannot hold 18 decimals exactly.
So `from*` results are **display-only**, and every value sent to a contract is built with
`parseUnits` from the user's input **string** — never round-tripped through a float
(`toCert(String(fromCert(v)))` silently truncates).

Exact-arithmetic helpers stay in `bigint` throughout: `scaleCollateralTo18` /
`scale18ToCollateral` (the mandatory 10¹² factor between the collateral and 18-decimal
domains), `quoteCertOut18`, `quoteCollateralOut6` and `feeAmount18`. The quotes keep the
fee as a separate figure so the UI can show it rather than fold it into the rate.

---

## 4. `src/chain/useVaults.ts`

One batched `useReadContracts` per render covering every deployed mirror, exactly the
eight calls specified: `vault.solvency()`, `vault.hotBuffer()`,
`vault.bufferCapacity18()`, `oracle.px()`, `oracle.mintAllowed()`,
`oracle.basisBpsChecked()`, `certificate.totalSupply()` and `registry.ageSec(vault)`.
`allowFailure` stays at wagmi's default on purpose — see price, below.

`LiveVault` is declared as `Omit<Vault, "id" | "price"> & {...}` against the real `Vault`
interface imported from `src/pages/dashboard/store.tsx`, so if the store's shape drifts
the compiler fails **here** rather than in a component. Extra hooks: `useLiveVault(id)`,
`useVaultConfigs()` / `useVaultConfig(id)` (`cfg()`, for `instantCap18` and the fee bps —
read, never hardcoded), `useUserBalances(address)` (collateral, cert balances, faucet
state) and a pure `aggregateTotals(vaults)`.

### 4.1 `buffer18` and `accrual18` — surfaced as two distinct fields

They are on a `backing` sub-object, and they are never summed:

```ts
backing: {
  bufferHeld: number;                 // solvency.buffer18 — the vault's OWN ERC-20
                                      // balance. Ground truth. Signed.
  accrualClaimedUnverified: number;   // solvency.accrual18 — attester-relayed cumulative
                                      // P&L. NOT money. Nothing on-chain verifies it.
                                      // Genuinely goes negative.
  accrualIsVerified: false;           // literal type `false`, always present
  margin: number;                     // solvency.margin18  (from the attestation)
  notional: number;                   // solvency.notional18 (from the attestation)
  provenAtBatch: number;
}
```

The names carry the distinction so a component cannot pick the wrong one by accident, and
`accrualIsVerified: false` is typed as the literal `false` so anything destructuring the
accrual has its verification status in hand and cannot render the number bare. These were
one field once, published as "the buffer", and it was the ledger — measured drifting
100,000.01 published against 91,028.00 actually held.

Consequences carried through the rest of the file: `Vault.buffer` maps to `bufferHeld`
only, and `aggregateTotals` sums `bufferHeld` into `buffer` while summing the accrual
separately as `accrualClaimedUnverified`, so no total can quietly absorb it. The single
solvency point's `backing` is `margin18 + buffer18` — accrual is **not** in it.

### 4.2 `ageSec` is always on the shape

`ageSec: number` is a required field on `LiveVault`, sourced from
`registry.ageSec(vault)` with `vault.solvency().ageSec` as fallback and also exposed
separately as `ageSecFromVault` for cross-checking. There is no code path in this file
that returns backing without it. `attestationStale` is derived at the documented
`maxAttestationAgeSec` of 300 s, past which capacity is zero and minting is off — the
single most likely reason a healthy-looking deployment refuses to mint.
`aggregateTotals` publishes `worstAgeSec` (the maximum across mirrors), not an average.

### 4.3 `basisBpsChecked()` — the boolean is returned, not collapsed

```ts
basisKnown: boolean;        // the `known` half, kept
basisBps: number | null;    // null when known === false — NOT 0
```

`basisKnown === false` means there is no independent basis to compute at all. Typing
`basisBps` as nullable is what stops "unverifiable" being silently rendered as "perfect",
which is what collapsing it to `0` would do.

### 4.4 Price — a state, not an error

`oracle.px()` reverts when the oracle is unhealthy, and that is designed behaviour. With
`allowFailure` on, that entry comes back `status: "failure"` and the rest of the batch
survives. It is modelled as:

```ts
price: number | null;
priceUnavailable: boolean;   // true when px() reverted
mintAllowed: boolean;
```

so the UI can say "minting paused" rather than show a crash or, worse, a zero price.
`raw.px18` is `bigint | null` for the same reason. When price is unavailable the single
solvency point's `obligation` falls back to the attested `notional18`, which is noted in
the code as having different provenance.

### 4.5 History — not fabricated

`Vault.solvency` wants 60 points and `Vault.funding` 48 bars. **No view function on these
contracts returns history**, so none was invented:

* `solvency` holds exactly **one real point**, computed from the current reads.
* `funding` is an **empty array**.
* `historyUnavailable: true` (literal type) is on every vault, for stage 2 to render an
  honest empty state.

Two further values have no on-chain source and are flagged the same way rather than
guessed: `change24h` is `0` with `change24hUnavailable: true`, and `funding8h` is `0` with
`funding8hUnavailable: true` (`accrual18` is a cumulative claim, not a rate). Inventing a
curve would make the dashboard lie, which is the one thing this project cannot do.

### 4.6 Two mappings stage 2 should confirm

* **`bufferPct`** is computed as `bufferHeld / bufferCapacity18 × 100`. The store's
  comment says "percent of target"; capacity is the closest on-chain analogue. Confirm the
  label matches this meaning.
* **`delta`** is `1 + deltaBps / 10_000`. `deltaBps` is **unsigned**, so the *direction* of
  the drift from delta 1.0 is not published on-chain — only its magnitude. `deltaBps` is
  exposed raw (in percent) so stage 2 can render the honest form rather than implying a
  sign.

---

## 5. `src/chain/useActions.ts`

`useCertActions(id)` covers `approve` (on `TestUSDG`, **6 decimals**),
`approveCertificate`, `mintInstant`, `requestMint`, `mint` (routed), `redeemInstant`,
`requestRedeem`, `redeem` (routed), `redeemWithFallback`, `forceExit`, `claimRedeem`,
`stageRefund`, `refundMint`, plus the two genuinely permissionless keeper calls
`recallMargin` and `rebalance`. `useFaucetActions()` covers the faucet's `claim`.

`forceExit` is gated on **nothing** — no buffer level, no capacity, no `mintAllowed`, no
governance state. Design Law 2; the code carries a comment saying not to add a
precondition.

### 5.1 The mint size fork is enforced before submitting

```ts
routeMint(amountIn6, instantCap18)    // scaleCollateralTo18(amountIn6) <= cap ? instant : request
routeRedeem(certIn18, instantCap18)   // certIn is already 18 dp, like the cap
```

`amountIn` is 6-decimal and `instantCap18` is 18-decimal, so the scale is mandatory —
comparing them directly is off by 10¹². `instantCap18` comes from `vault.cfg()`, never
hardcoded. If `cfg()` has not loaded, `mint`/`redeem` **refuse and throw** rather than
guess, because guessing means a revert at the wallet
(`CertVault_AboveInstantCap` / `CertVault_BelowInstantCap`). `isRoutable` exposes that
state so the UI can disable the button instead.

### 5.2 The two behaviours that are not errors

Both are modelled as return values, not thrown errors:

```ts
type RedeemResult =
  | { status: "instant"; hash }
  | { status: "queued";  hash }
  | { status: "needs-queued"; reason: DecodedRevert };   // CertVault_UseQueuedRedeem

type ClaimResult =
  | { status: "claimed"; hash }
  | { status: "awaiting-settlement"; retryable: true; reason: DecodedRevert };
```

* **`CertVault_UseQueuedRedeem`** — the fast path declining because the hot buffer is
  thin. `redeemInstant` and `redeem` catch it and return `needs-queued`, so the caller can
  route to `requestRedeem`. `redeemWithFallback` submits that second transaction itself
  (two wallet prompts); both are provided so the UI chooses whether to ask first.
  Predicate: `isUseQueuedRedeem(err)`.
* **`CertVault_AwaitingSettlement`** on `claimRedeem` — returned as
  `awaiting-settlement` with `retryable: true` typed as the literal `true`. Never
  terminal: the receipt stays claimable forever, and `recallMargin()` is exposed to push
  it along. Predicate: `isAwaitingSettlement(err)`. Nothing here can mark a receipt
  failed.

### 5.3 Revert decoding

`decodeRevert(err)` walks the viem error chain for `ContractFunctionRevertedError`, reads
the custom error name out of the ABI-decoded data (these contracts use custom errors only
— no revert strings) and returns:

```ts
{ name, args, message, kind, cause }
```

`kind` classifies the outcome so the UI can pick a presentation rather than defaulting to
a red toast: `"not-an-error"`, `"retryable"`, `"no-op"`, `"routing-bug"`,
`"operator-only"`, `"user"`, `"rejected"`, `"unknown"`. All the user-reachable errors from
guide §4 are mapped, plus the keeper no-ops (`CertVault_InBand`,
`CertVault_AlreadyRebalancedThisBatch`), the oracle errors, and the ERC-20 errors.
`TestFaucet_TooSoon` uses its `availableAt` argument to name the time in the sentence.
`CertVault_OnlyGovernance` / `CertVault_OnlyAttester` are classified `operator-only` —
reaching one means the app called an operator function. Wallet dismissal is separated out
as `"rejected"` so it is not reported as a contract failure.

### 5.4 Type safety of the calls

Both the writes and the reads are checked against the ABIs at compile time, and this was
verified by deliberately breaking each and confirming `tsc` fails:

* Writes call `mutateAsync` directly with the `as const` ABI, so wagmi infers
  `functionName` and `args` per function. An earlier draft wrapped it in a helper typed
  `Parameters<typeof mutateAsync>[0]`, which instantiated wagmi's generics at their
  constraints and silently **erased** that checking — passing a `string` where a `bigint`
  was required compiled clean. The wrapper was removed.
* Reads are built dynamically from `MIRRORS`, so `useReadContracts` cannot infer
  per-index result types. They go through a small `call()` helper typed with
  `ContractFunctionName<abi, "view" | "pure">`, which keeps the half inference would drop:
  a typo in a read's function name is a compile error. Results are decoded by index
  through narrow helpers (`asBigint`, `asBool`, `asSolvency`, `asBasis`) that validate the
  runtime shape and return `null` rather than coercing.

---

## 6. The `VaultId` collision — for stage 2 to resolve deliberately

**`store.tsx` and the deployment disagree about which vaults exist, and neither is a
subset of the other.**

```ts
// src/pages/dashboard/store.tsx — mock data, NOT changed in this stage
type VaultId = "utsla" | "unvda" | "uspx" | "uqqq";

// src/chain/useVaults.ts — what is actually deployed
type ChainVaultId = "utsla" | "uspy";
```

* `utsla` is the **only** id in both.
* `unvda`, `uspx` and `uqqq` are **not deployed**. There is no vault, no certificate token
  and no oracle for them on chain 46630. Every figure the dashboard currently shows for
  them is mock data.
* `uspy` **is** deployed (market 26) and is **not in the store's union**.

This stage did **not** touch `store.tsx`. `ChainVaultId` is declared separately in
`useVaults.ts` and `"uspy"` added there, so the chain layer is honest about the deployment
while the mock store keeps compiling untouched. Consequences for stage 2:

1. The union has to be reconciled — add `"uspy"`, and decide what happens to `unvda`,
   `uspx` and `uqqq`. Removing them is a change to `Record<VaultId, ...>` maps
   (`FLOW_NAMES`, `positions`, `prices`), so it is not a one-line edit.
2. `LiveVault` widens `price` to `number | null` (hence `Omit<Vault, "id" | "price">`).
   Any component reading `vault.price` needs a `priceUnavailable` branch — it cannot
   assume a number.
3. `store.tsx`'s `Keeper` list advertises five keepers. Per guide §3.6, only
   `recallMargin()` and `rebalance()` are real and callable from a user's wallet; the
   other four are fiction. Both real ones are exposed on `useCertActions`.
4. There is no `cert-plate-uspy.jpg` in `public/`. uSPY currently points at `/logo.png`
   with `imgPlaceholder: true` rather than borrowing the uSPX plate, which would put a
   uSPX plate under a uSPY heading. Asset work belongs to the copy stage.

---

## 7. Out of scope for this stage

Not built, by instruction — recorded so nothing is assumed done:

* **Receipts screen.** Receipt ids are not enumerable on-chain and there is no
  `receiptsOf(user)`; it can only be built from event logs (guide §3.4). No event indexing
  was added here.
* **Dashboard rewiring.** No component was changed; the mock `DashboardProvider` is still
  what renders. Stage 2.
* **Copy.** None of the nine blocking items in guide §6 were touched, including the
  "simulated venue" banner. Stage 3.
* **Wallet connect UI.** The provider and connector are wired; the connect button still
  calls the store's mock `connect()`.
