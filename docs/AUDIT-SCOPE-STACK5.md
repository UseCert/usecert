# UseCert stack 5 — external audit scope

Prepared 2026-09-27. **Stack 5 is the code an audit should cover**: it is what will be deployed
next. Stack 4 (live, `docs/AUDIT-SCOPE.md`) is immutable, and every fix below lives only in
stack 5.

| | |
|---|---|
| Repository | https://github.com/UseCert/usecert, branch **`feat/stack5`** |
| Chain | Robinhood Chain mainnet, chain id 4663 (not yet deployed) |
| Tooling | Solidity 0.8.24, Foundry, OpenZeppelin v5.7.0, optimizer 200 runs, `via_ir` off |
| Tests | 699 in total: 696 pass. 3 fail by design, in `test/AuditPoC.t.sol` from the 2026-09-08 audit. `test/script/DeployMainnetStack5.t.sol` runs the whole stack-5 deploy, the Safe phases A and B, and a first keeper-mode mint |
| Largest contract | CertVault, 24,139 B runtime (EIP-170 limit 24,576) |
| What changed vs stack 4 | 9 source files changed, +1,815 / −211 lines (`git diff a057c8b feat/stack5 -- src/`) |

## Status: no external audit before launch (owner decision, 2026-09-28)

The owner has decided that stack 5 launches **without an external audit**. What it has instead is
an internal review of the staking side (CertStaking v2 and InsuranceStaking v2 as deployed, at
9e05909), written by the AI assistant that helped write the stack-5 fixes: not independent, and
not an audit. It found no Critical or High issue, and nothing that lets anyone take funds out of
either contract; its Medium and Low findings concern who ends up with fees or losses. The
operational mitigations it asked for are live (an hourly fee push, no fee paid into an empty
insurance pool, an alert on any insurance shortfall). The findings that need a contract change are
tracked privately and carried to the next staking deployment. The deployment records keep
`"audited": false`, which stays true until an independent firm has reviewed the code.

This document remains the scope for such a review whenever one is commissioned.

## Contracts

| Contract | Lines | New or changed in stack 5 |
|---|---|---|
| **CertVault** | 2,975 | K2 fee routing, plus these fixes: |
| | | — stale-price guard on instant redemption, and a fresh-price cap with a 4-day timeout on queued claims; |
| | | — partial claims, and cash ring-fenced for queued claims and escrow; |
| | | — a 2-day delay on `setVenueApiKey`, `setVenueMinimums` and `setSettler`, and a notional-bounded `minBase`; |
| | | — a separate `settler` role; |
| | | — `rebalance` gated on an attestation newer than the last order, a minimum interval and a 24 h budget; |
| | | — capacity measured before the deposit, a wider close band, recalls capped at the attested margin; |
| | | — `receiveInsurance` / `insuranceShortfall` / `setInsurancePool`, with fees swept only while funding is recorded and there is no shortfall; |
| | | — the mint fee refunded, and a claim grace period for the owner. |
| **CertOracle** | 911 | Marks carry `observedAt` (signature domain version "2"), minting needs a fresh mark (`maxMarkAge`), signatures are valid at most 60 s, and an instant disable-only `disableAttester`. |
| **SolvencyRegistry** | 373 | Batches must be exactly `latest + 1`, relayed observations must strictly advance, and an instant disable-only `disableAttester`. |
| **CapacityOracle** | 109 | Unchanged logic; documents that the deployer must size `maxAbsoluteCap` per asset. |
| **CertFactory** | 182 | Adds `registeredAt(vault)`. |
| **InsuranceStaking** | 530 | v2: |
| | | — requested shares are escrowed, so the cooldown can't be bypassed by transfers; |
| | | — income vests over 7 days, so no sandwich; |
| | | — draws only to vaults registered for at least `registrationDelay`, not retired, capped at the vault's shortfall, paid through `receiveInsurance`, with a rolling 30-day cap; |
| | | — the deposit cap counts net principal only; |
| | | — the withdrawal window must outlast a draw pause. |
| **CertStaking** | 270 | v2: scaled remainder (no double-count), fundings folded into the running period (no stretching), `minNotify`, and a zero-stake `exit` that doesn't revert. |
| **FeeVault** | 157 | K2, pull-based: `distribute()` credits and `claim(recipient)` pays, so a frozen recipient blocks only itself. |
| **BuybackForwarder** | 82 | New, ownerless. It can only forward its USDG to `CertStaking.notifyRewardAmount`, and carries the 20% buyback leg. |
| BufferBook, Certificate | 188, 36 | Unchanged. |

**Fee split, as it will be deployed:** 70% InsuranceStaking, 20% BuybackForwarder (→ CERT stakers),
5% the ops wallet, 5% the treasury Safe. That is four distinct recipients, pinned in
`test_mainnetSplit_order_and_bps`.

## Stock-token multiplier (option A, total return)

Each feed prices ONE Robinhood stock token, and one token is `uiMultiplier()` shares (ERC-8056,
1e18-scaled; dividends raise it, splits multiply it). A certificate is a synthetic of one token,
dividends included; the venue perp trades shares, so the hedge target is supply x M shares.

- **CertOracle:** new last constructor argument and immutable `stockToken` (zero only off
  mainnet: refused on chain 4663). `multiplier18()` (never reverts; falls back to `markMult18`,
  the multiplier seen with the last mark), `sharePx18()`, `corporateActionWindow()`. Minting
  closes while the token reports `oraclePaused()`, from `MULTIPLIER_PRE_WINDOW` before a staged
  change until `MULTIPLIER_POST_WINDOW` after it and the feed has re-published, and when the mark
  was taken under a multiplier more than `MAX_MULTIPLIER_DRIFT_BPS` away. The basis band compares
  the feed with mark x M. Redemption reads none of it.
- **CertVault:** every order is sized `certs x M` shares at the share price `px / M` (mint opens,
  exits, refunds, rebalance, closeAll's guard price); `HedgeRequested` carries the share base and
  limit; `mintMult18(receiptId)` records M per mint; settleMint bands the keeper's SHARE fill.
  New settler-only `rehedge(maxBase)`: rebalance without the 1% band (dividend top-ups, a split
  the venue did not rescale); in keeper mode it emits `HedgeRequested(0, ...)`.
- Tests: `test/CertVaultMultiplier.t.sol`.

## Deploy parameters that differ from stack 4

| Parameter | Stack 5 value | Why |
|---|---|---|
| InsuranceStaking `withdrawWindow` | ≥ `drawDelay` + 3 d + 1 d (e.g. 6 d with a 2 d delay) | the constructor requires it (M-2) |
| InsuranceStaking `registrationDelay` | ≥ cooldown + window (e.g. 16 d) | a newly registered vault can't be drawn to before stakers can leave |
| CertOracle `maxMarkAge` | e.g. 300 s | minting needs a fresh mark |
| CertStaking `minNotify` | e.g. 1 USDG | stops dust fundings |
| CapacityOracle `maxAbsoluteCap` | sized per asset, not 1e27 | M-8 |

## Off-chain changes (optional scope)

In `deploy/bin/`:
- **`usecert-signer-mainnet.py`:** open interest measured from the venue; refuses to sign on a
  price deviation from the feed or an unexplained notional jump; signs the v2 mark format.
- **`usecert-keeper.py`:** uses a separate settler key.
- **New `usecert-funding-relay`:** records funding with `accrueFunding`, hourly, idempotently.

Stack-5 behaviour is switched on with `STACK=5`.

## Known residuals, accepted and documented in the code

- **Losses:** a loss is shared in arrival order, not pro rata. No claim is trapped.
- **`insuranceShortfall()`:** can briefly overstate after a queued exit in a rising market. The
  extra money stays reserved and returns to the pool at retirement.
- **Mark choice:** a relayer can choose among marks signed within `maxMarkAge`, bounded by the
  basis band.
- **Governance registration:** a Safe-registered contract that lies about its shortfall can take
  up to the rolling cap, but only after a public registration delay.
- **CertStaking:** a late-period funding pays out over the short time left.
- **CERT staking cap:** no per-address cap, because splitting across addresses defeats one.

## Deployment scripts (in scope for review)

- **`script/DeployMainnet.s.sol`:** deploys stack 5 and writes `deployments/4663.stack5.json`,
  marked `"stack": 5`.
- **`script/SafeBatches.s.sol`:** the Safe's batches, in this order:
  1. `batch1`: the registry and the oracles.
  2. `phaseA` (day 0): registration, wiring, and the delayed-change proposals.
  3. `phaseB` (day ≥ 2): the applies. They must match phase A byte for byte, and are refused if
     early or missing.
  4. `openMinting`: sets the capacity cap, one vault first.
  5. `retireStack4`.
- **Runbook:** `docs/STACK5-DEPLOY-RUNBOOK.md`.
- **Known limit:** CapacityOracle has a single `maxAbsoluteCap` ceiling, so per-asset caps (for
  example uTSLA 0k against uSPY M) are enforced by the scripts, not on chain. The Safe could
  raise any vault to the largest row.
