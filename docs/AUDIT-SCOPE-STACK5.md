# UseCert stack 5 — external audit scope

Prepared 2026-09-27. **Stack 5 is the code an audit should cover**: it is what will be deployed
next. Stack 4 (live, `docs/AUDIT-SCOPE.md`) is immutable, and every fix below lives only in
stack 5.

| | |
|---|---|
| Repository | https://github.com/UseCert/usecert, branch **`feat/stack5`** |
| Chain | Robinhood Chain mainnet, chain id 4663 (not yet deployed) |
| Tooling | Solidity 0.8.24, Foundry, OpenZeppelin v5.7.0, optimizer 200 runs, `via_ir` off |
| Tests | 678 in total: 675 pass. 3 fail by design, in `test/AuditPoC.t.sol` from the 2026-09-08 audit |
| Largest contract | CertVault, 23,458 B runtime (EIP-170 limit 24,576) |
| What changed vs stack 4 | 9 source files changed, +1,815 / −211 lines (`git diff a057c8b feat/stack5 -- src/`) |

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
