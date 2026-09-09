# UseCert C1 — deployment checklist

**Status:** normative for every C1 deployment. Created for **L-7** of the external C1 audit, whose
recommendation was to record the vault's reentrancy safety as an explicit deployment constraint
rather than leave it an emergent property of the code. Everything else here is the same class of
thing: a property C1 holds **because of an assumption made at deploy time**, which no contract can
enforce for itself.

There is **no owner, keeper, pause or upgrade path** (Law 6). Every address below is immutable
except the two attesters, which rotate only through a published notice period (M-5). So an item got
wrong here is got wrong permanently, and the remedy is a redeployment.

Each item states the assumption, what depends on it, and what happens if it is violated.

---

## 0. RESOLVED — `CertFactory` is a registry, and vaults are deployed by script

**`CertFactory` no longer deploys vaults, because no contract can.** This section used to record an
open blocker: the factory measured **28,205 B** of runtime against EIP-170's 24,576 B ceiling
(**−3,629 B**) and could not be deployed to any chain that enforces the limit.

The cause was `deployVault`'s `new CertVault(...)`. A contract that can `new X` must carry X's
entire **creation** code inside its own **runtime** code, and `CertVault`'s initcode measures
**25,743 B** — which already exceeds the 24,576 B *runtime* limit on its own. So this was never a
size budget that a leaner factory, a lower `optimizer_runs`, or a separate `CertVaultDeployer`
helper could have won back: **no contract can ever deploy a `CertVault` via `new`.** The limit
follows the bytecode, wherever it is parked.

`CertVault` deploys perfectly well **directly from an EOA, a multisig, or a deployment script**,
where the relevant ceiling is EIP-3860's 49,152 B initcode limit and 25,743 B is comfortably under.

**What changed.** `CertFactory` is now a registry over vaults deployed elsewhere:

| | Before | After |
| --- | --- | --- |
| `CertFactory` runtime | 28,205 B (**−3,629 B**) | **2,323 B** (+22,253 B) |
| `CertFactory` initcode | 28,577 B | 2,671 B |
| `CertVault` | 17,559 B runtime / 25,743 B initcode | unchanged |

- **`registerVault(address vault, address certificate)`** — governance-only. Validates the vault
  (non-zero, has code, not already registered, and its own `certificate()` equals the `certificate`
  argument) and records it in `vaults` and `isVault`, then emits `VaultRegistered`. This is the
  replacement for `deployVault`, and it is what makes `enable()` and every consumer of `vaults` /
  `isVault` work exactly as before.
- **`deployVault(...)`** — **retained as a reverting stub.** The signature and the governance check
  are unchanged and in the same order, so an unauthorised caller still gets
  `CertFactory_OnlyGovernance` (asserted by the external audit's frozen evidence file,
  `test/AttackSuite.t.sol`); an authorised caller gets `CertFactory_UseRegisterVault`, a named
  pointer at the replacement. It never deploys anything.
- **`VaultDeployed` was renamed `VaultRegistered`**, same three fields
  (`vault`, `certificate`, `marketIndex`). The old name would be a lie in the ABI. **Any indexer
  subscribing to `VaultDeployed` must change the topic it watches.**

**No other contract is at risk.** After this change the largest contract in `src/` is `CertVault` at
17,559 B (+7,017 B of margin), and the only remaining contract-deploys-contract sites in `src/` are
`CertVault`'s constructor creating its `Certificate` (3,051 B initcode) and its `BufferBook`
(2,429 B initcode) — both an order of magnitude under the limit, and both already accounted for
inside `CertVault`'s own 17,559 B.

**Foundry does not enforce EIP-170 in tests**, which is why the suite was green throughout the
overrun. `forge build --sizes` is the check, and it must be run — and read — before every
deployment. It exits non-zero when any contract exceeds the runtime limit.

---

## 1. The collateral token — L-7, and the sharpest item on this list

`CertVault.cfg.collateral` is arbitrary at deploy and **there are no reentrancy guards anywhere in
`CertVault`**. Every payout path is written checks-effects-interactions and the audit's attack
battery confirmed the ordering holds even under callback collateral — but that is a property of the
token, not of the vault, so it is recorded here as a constraint rather than relied on as an
invariant.

**The collateral token MUST be all of the following:**

| Requirement | What depends on it |
| --- | --- |
| No transfer callbacks (not ERC-777, no hooks, no `_afterTokenTransfer` reaching a third party) | The absence of reentrancy guards on `redeemInstant`, `claimRedeem` and `refundMint`. CEI ordering makes a callback harmless today; a guard is the belt this deployment does not have |
| **Not fee-on-transfer** | `_pullCollateral` already sizes every mint off the balance delta rather than off `amountIn` (L-8), so a pure fee-on-transfer token is handled. But its documented residual is real: a token that is **both fee-on-transfer and reentrant** can push the delta above `amountIn` while delivering less, and the `min` then credits `amountIn` and over-mints the fee |
| **Not rebasing**, positively or negatively | `hotBuffer()` is an `ERC20.balanceOf`, and `freeCollateral18()`, `Solvency.buffer18` and every payout affordability check are derived from it on each read. A negative rebase mid-transfer is handled by name (`CertVault_ZeroAmount`) rather than by an underflow panic, but a rebasing token still makes `postedMargin` and `totalOwedOutstanding` drift from reality |
| `decimals()` **≤ 18**, immutable, and non-reverting | Now **enforced at construction** (`CertVault_ConfigOutOfBounds`). `_collateralDecimals` is read **once** and is immutable, so a proxy that later changes its reported decimals silently breaks `_to18`/`_from18` in both directions and every 18-decimal figure the vault publishes. At ≤ 18, `_from18` divides rather than multiplies and cannot overflow at all |
| No blocklist / pause that can reach the vault's address | A frozen collateral token blocks `claimRedeem` and `refundMint` outright. Nothing in the vault can route around it, and Law 2 does not survive it |
| No allowance-race quirks | `_postMargin` and `bootstrap()` use `forceApprove`, so a non-standard `approve` return is handled |

USDG satisfies all of these. USDT ships its fee switch disabled, which satisfies row 2 only for as
long as that remains true.

> **If a future deployment needs a token that violates row 1 or row 2, add reentrancy guards to the
> mint and payout paths first.** That is a code change, not a configuration choice.

## 2. The price feed

| Item | Requirement | Violation |
| --- | --- | --- |
| `CertOracle.feed` | A real Chainlink-compatible aggregator. Immutable | — |
| `feed.decimals()` | **Must be ≤ 36, and must not change.** `_tryFeed` bounds `d` at 36 and treats anything above as an unusable feed, so `pxUnguarded()`, `basisBps()` and `mintAllowed()` are safe. **`_readFeed`, which `px()` uses, has no such bound**, so a feed reporting `decimals() >= 96` panics `px()` and therefore both mint paths | Minting dies with an anonymous panic. Redemption is unaffected (Law 2 reads `pxUnguarded()`) |
| Feed answer magnitude | Normalisation is guarded, so an unrepresentable answer makes the feed unusable rather than panicking. **Finding 1** made the vault's own valuation total for every price the feed can return, so an absurd print no longer reverts `forceExit` | — |
| `stalenessSeconds` | Must exceed the feed's real heartbeat with margin. **It no longer doubles as `pokeLastGood`'s confirmation window** (Task 1): the H-1 breaker now proves round distinctness from the feed's own `roundId` and takes its rate limit from `pokeConfirmationSeconds`, so this knob answers one question only — how old may a feed observation be and still be usable | Too small: minting is permanently paused. Too large: a dead feed keeps minting open |
| `pokeConfirmationSeconds` | **Must not be 0** (`CertOracle_ConfigOutOfBounds` at construction). How long an out-of-band price must hold before the H-1 deviation reference concedes one clamped `deviationBps` step. This is a **risk tolerance, not a heartbeat** — order of an hour, and deliberately independent of `stalenessSeconds`; do not set it to the feed bound out of habit, that is the coupling Task 1 removed | Too small: a sustained dislocation is absorbed faster than an operator can react, and at 0 the `roundId` proof is the only gate, which bounds distinctness but not rate. Too large: the breaker outlasts the event it fired on and reads as an outage (at 93_600 a 20% repricing kept minting shut ~4.3 days) |
| `deviationBps` | **Must not be 0.** At zero the H-1 clamp permits no advance in either direction, so any price change pauses minting until an operator widens their own tolerance | Minting locks shut on the first tick |
| `basisBandBps` and `markPx18` | The basis band is measured against `markPx18`, which the attester writes with **no timestamp and no staleness check anywhere** (recorded as not-fixed in `CertOracle.mintAllowed`'s NatSpec). It fails closed, but only incidentally: a mark frozen at a level that happens to track the index keeps minting open against a number nobody has refreshed | The band's liveness is an **operational assumption on the attester's cadence**, not a contract guarantee |

## 3. Venue configuration — every one of these must match Lighter's own per-market config

A mismatch here is not caught by any contract. The vault will trade, and it will trade wrong.

| Field | Requirement | Violation |
| --- | --- | --- |
| `CertOracle.priceDecimals` | Exactly the market's `price_decimals` (2 for TSLA and NVDA) | Every order price is off by a power of ten |
| `VaultConfig.sizeDecimals` | Exactly the market's `size_decimals`, and **≤ 18** (enforced at construction) | Every hedge is mis-sized by a power of ten. `_baseAmount` and `_quantiseToVenue` both key off it, so certificates and hedge would still agree with each other while both disagreed with the venue |
| `VaultConfig.mintFeeBps`, `redeemFeeBps` | **≤ 10_000** — enforced at construction, and `redeemFeeBps` is not a cosmetic bound. Above 10_000 it underflows `gross18 - fee18` in *both* redemption paths while leaving minting untouched, so the vault issues real certificates and then panics inside `forceExit` for every holder, unrepairably. Measured at 10_001 | A reachable Law 2 breach from deploy config alone. Now impossible to deploy |
| `VaultConfig.marketIndex` | The market's index, and `<= 254` | `MarketIndexTooHigh` on every order |
| `VaultConfig.collateralAssetIndex`, `routeType` | The venue's asset index and route for the collateral | Deposits and withdrawals fail or land in the wrong asset |
| **Price stays inside the tick domain** | `toTickPrice` requires `px18 * 10**priceDecimals / 1e18` in `[1, 2**32 - 1]`. At `priceDecimals = 2` that is roughly **$0.01 to $42.9M** | Outside it, minting and `rebalance()` revert `CertOracle_TickOverflow`. Redemption survives: `_tryHedge` fails open and `forceExit` still burns, writes the receipt and reallocates margin |
| `venueWithdrawCap` | **At or below `type(uint64).max`.** `recallMargin` clamps to it before `SafeCast.toUint64`, so a value inside `uint64` makes that cast unreachable | A larger value leaves a (retryable, non-redemption-path) cast revert reachable once `totalOwedOutstanding` passes ~1.8e19 collateral units |
| `depositCapTicks` (venue side) | Deposits must be exact multiples of `tickSize` and under the global cap | Minting pauses with a clear reason; redemption unaffected |

### 3a. Open item — `baseAmount == 0` direction semantics (M-3)

`closeAll()` now derives its side from `CertVault.venuePositionBase` because `baseAmount == 0`
defaults to the full position **size** and leaves `isAsk` to the caller, so a hardcoded ASK against a
short doubles it. **That reading comes from the design spec's section 3.1 table, not from Lighter
source, which is not in this repo.** `MockLighter` models the conservative interpretation — a
wrong-side close-all is harmful — so a vault correct against the mock is correct either way.

**Confirm against Lighter source before mainnet.** And note what the ledger cannot see: in-rollup
order refusal, partial fills, liquidation and desert-mode settlement all move the venue's position
without moving `venuePositionBase`, and each can flip the sign `closeAll()` reads. The derived side
is a strict improvement on assuming long, not a proof.

## 4. Deploy `SolvencyRegistry` and `CertOracle` **from the governance multisig** — M-5

Both contracts bind their **rotation authority to `msg.sender` at construction**:

```
SolvencyRegistry.governance = msg.sender    // immutable
CertOracle.governance       = msg.sender    // immutable
```

**Deploy each one in a transaction sent directly by the governance multisig.** Never from a
deployment script contract, a `CREATE2` factory, or any intermediate contract.

If governance lands on an address nobody controls, attester rotation is unreachable and the
unrecoverable key loss M-5 exists to fix is **terminal again** — exactly the state the finding
reports, with an extra step. Verify `registry.governance()` and `oracle.governance()` immediately
after deployment, before funding anything.

An explicit `_governance` constructor parameter is the C2 cleanup. The arity is frozen in C1 because
`SolvencyRegistry(address)` is depended on verbatim by the external audit's own evidence files.

## 5. Governance parameters, and the order they must be set in

| Item | Requirement |
| --- | --- |
| `CapacityOracle.maxAbsoluteCap` | **The single immutable bound on a compromised or lying attester.** Set it to a real, considered number. `type(uint256).max` removes the only ceiling that survives an attester who writes whatever it likes into `openInterest18` |
| `CapacityOracle.absoluteCap18[vault]` | **Must be set by governance before the vault can mint** — it is zero by default and `min()` makes zero mean "no capacity". There is deliberately no first-call exception for a stranger to bootstrap it |
| `[minDepthBps, maxDepthBps]` | Immutable bounds; governance tunes `depthBps` inside them and can never remove the cap |
| `maxAttestationAgeSec` | Must exceed the attester's real batch cadence with margin. Below it, `maxNotional18` returns 0 and minting is permanently off |
| `VaultConfig.targetMarginBps` | In `[5000, 10000]`, enforced at construction. Leverage is `10000 / targetMarginBps`, so 2x is the ceiling |
| `CertVault.setBufferThresholds` | The constructor installs per-asset **defaults** of 100k / 60k / 30k / 0. Retune them for the asset's real book size (M-2) — a 100k floor is meaningless against a $1.19M book. They gate nothing, so this is a reporting choice, not a safety one |
| Emergency lever | **`setAbsoluteCap(vault, 0)` shuts new minting in one transaction.** This is the instant response to a misbehaving attester; attester *rotation* then serves its 2-day notice period separately. Redemption stays open throughout (Law 2) |

## 6. Bootstrap sequence

**The vault is deployed by the script, not by the factory** (section 0). `CertFactory` is deployed
before the vault only because `registerVault` needs to exist to be called — the vault does not
depend on the factory at all, and holds no reference to it.

1. Deploy `SolvencyRegistry` and `CertOracle` **from the multisig** (section 4).
2. Deploy `CapacityOracle`, then `CertFactory`.
3. **Deploy the vault directly** — `new CertVault(Deps{lighter, oracle, registry, capacity,
   governance}, config, venueWithdrawCap, settleWindow, name, symbol)` from the deployment script or
   the multisig. The vault's constructor deploys its own `Certificate` and `BufferBook`. Read
   `vault.certificate()` back; you need it for the next step. **Do not attempt this through
   `CertFactory.deployVault` — it reverts `CertFactory_UseRegisterVault` by construction.**
   The four `Deps` addresses must be the same four the factory holds
   (`factory.lighter()`, `factory.registry()`, `factory.capacity()`, `factory.governance()`);
   `registerVault` does **not** check this for you, and section 9 is where you verify it.
4. `CertFactory.registerVault(vault, certificate)` — **governance.** Records the vault in `vaults`
   and `isVault`. Required before `enable()` will accept the vault; nothing else in `src/` reads the
   registry, so a vault that is never registered still mints and redeems normally.
5. `setAbsoluteCap(vault, ...)` — governance. Without it the vault cannot mint.
6. Transfer at least `10 ** collateralDecimals` of collateral to the vault (`seedBuffer` is the
   permissionless way) — `bootstrap()` deposits exactly that much as registering dust and will
   revert without it.
7. `bootstrap()` — one-time, permissionless, sets `bootstrapped`.
8. **Wait for the rollup to execute the registering deposit.** `createOrder` reverts
   `AccountIsNotRegistered` until `addressToAccountIndex[vault]` is populated, so every mint reverts
   as one atomic transaction until then — nothing is pulled, posted or minted.
9. Attest once (`attest`) and set the mark price (`setMarkPrice`) so `maxNotional18` and
   `mintAllowed()` are live.
10. `CertFactory.enable(vault)` — **optional and observational only (L-1).** Nothing in `src/` reads
    the `enabled` flag; `CertVault` holds no reference to its factory and cannot consult it. Step 8
    is the real sequencing guarantee and the chain enforces it. Call `enable` if you want the public
    marker; skipping it changes nothing. It requires step 4.

## 7. Assumptions carried by Finding 1's valuation bounds

`_value18` clamps at `MAX_VALUATION_PX18 = 1e36` and `MAX_VALUATION_QTY18 = type(uint256).max / 1e18`
(~1.16e41 certificates) to make every quantity-times-price product a total function. Both sit
decades beyond anything reachable:

- the price clamp is ten decades above the highest price the venue's `uint32` tick domain can
  represent, so it can only engage on a price the protocol cannot transact at;
- the quantity clamp is unreachable given `maxAbsoluteCap` and the tick-domain floor on price.

**Setting `maxAbsoluteCap` absurdly high (section 5) is what would move the quantity bound toward
reachability.** Another reason to set it to a real number.

## 8. What is verified on-chain, and what is not — state this publicly, do not soften it

- `SolvencyRegistry` attestations are **independently verifiable, not verified on-chain.** A single
  attester posts figures reconstructed from Lighter's blob data; anyone can rebuild the tree and
  check them. C2 replaces the attester with a proof check inside `attest()`.
- `BufferBook`'s ledger is **cumulative P&L relayed by the attester and not independently verified**
  (`Solvency.accrual18`). The figure published as the buffer (`Solvency.buffer18`) is the vault's own
  `balanceOf` and is ground truth (M-1).
- `settleMint`'s `fillPx18` argument is **informational**, still banded against the request price. It
  sizes nothing. No attested per-receipt fill price exists anywhere in C1 (C-1, H-2).
- The holding fee is **computed and published but never charged** in C1, and `mint_slow` tapers
  nothing (M-2). What actually happens as the ledger degrades is nothing at all until it crosses
  zero, at which point capacity goes to zero and new minting halts.
- Redemption SLA is **"~1 batch expected, 14 days worst case, then the Escape Hatch"** — never
  "~60s guaranteed".

## 9. Post-deployment verification

Read these back on-chain before funding:

- [ ] `registry.governance()` and `oracle.governance()` are the multisig (section 4)
- [ ] `registry.attester()`, `oracle.attester()` are the intended keys, and both
      `pendingAttester()` are `address(0)`
- [ ] `registry.ATTESTER_ROTATION_DELAY() == oracle.ATTESTER_ROTATION_DELAY() == 2 days`
- [ ] `capacity.maxAbsoluteCap()` is the intended real number, and `absoluteCap18(vault)` is set
- [ ] `vault.governance()`, `vault.lighter()`, `vault.oracle()`, `vault.registry()`,
      `vault.capacity()` are all correct — every one is immutable
- [ ] `vault.lighter()`, `vault.registry()`, `vault.capacity()` and `vault.governance()` each equal
      the factory's own `lighter()`, `registry()`, `capacity()` and `governance()`. **This is the
      one thing the old `deployVault` guaranteed structurally and `registerVault` does not** — the
      factory used to wire these from its own immutables, and now the deployment script does. A
      mismatch is not repairable: every dependency on both sides is immutable, so the remedy is a
      redeployment
- [ ] `factory.isVault(vault)` is true and `factory.vaults(i) == vault` for exactly one `i`, and
      `factory.vaultCount()` equals the number of vaults you actually deployed (section 6, step 4)
- [ ] `vault.certificate()` equals the `certificate` argument you passed to `registerVault` —
      `registerVault` enforces this, so this item is a read-back, not a check
- [ ] `vault.cfg()` decimals and indices match the venue's market config (section 3)
- [ ] `vault.venueWithdrawCap() <= type(uint64).max`
- [ ] `vault.lighterAccountIndex() != 0` (the registering deposit has executed)
- [ ] `oracle.toTickPrice(oracle.px())` returns a sane tick, i.e. the live price is inside the
      uint32 domain at the configured `priceDecimals`
- [ ] a `forceExit` of a dust position succeeds on the live deployment — this is Law 2 and it is
      worth one real transaction
- [ ] `forge build --sizes` was run against the exact commit being deployed and exited **zero**, with
      every contract showing a positive runtime margin (section 0). Foundry does not enforce EIP-170
      in `forge test`, so a green suite is not evidence for this item
