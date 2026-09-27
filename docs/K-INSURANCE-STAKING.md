# K — Insurance staking: design, phases K1 and K2

Status: **K1 and K2 written and tested, neither deployed.** Mainnet deployment needs an external audit, a
legal read (a yield-bearing stake is the most security-like thing UseCert would offer) and the
Safe's 2-of-3.

## What it is for

The whitepaper's loss order is fixed: **vault buffer → insurance → (never) holder backing.** In
C1 the middle rung does not exist. `BufferBook.insuranceDrawNeeded()` publishes a number that
nothing consumes. K1 builds that rung.

## The one fact the design is built on

**Anyone can transfer USDG into a vault, and it lands in the vault's own collateral balance**,
which is the `buffer18` figure the solvency math reads (`hotBuffer()` is `balanceOf(this)`).

So insurance can pay out **without changing a single deployed vault.** The insurance contract
transfers USDG to the vault, and that USDG backs holders from that moment.

The reverse is not true. Today fees stay inside each vault as collateral, and no function can
route them out, apart from `retire()` on an empty vault. **Fee-funded staker yield therefore
needs a new vault version** (phase K2, below).

## K1: `InsuranceStaking.sol` — decisions, with the reason for each

| Decision | K1 choice | Why |
|---|---|---|
| **What is staked** | **USDG**: an ERC-4626 vault over the collateral itself | A draw must deliver collateral. Staked CERT would first have to be *sold* for USDG, in a crisis, into a market that is falling because of that crisis. That is the reflexive loop that ends insurance funds. A CERT tranche can sit *behind* this one later, with a swap route. |
| **How losses are taken** | A **draw** moves USDG from the pool to a registered vault, and every share loses value pro rata | There is no per-user slashing logic to get wrong. The share price is the whole state. |
| **Who can draw** | **Governance (the 2-of-3 Safe) proposes**; anyone executes after a delay | There is no objective on-chain loss oracle yet: the accrual ledger is attester-relayed. A human decision, delayed and published, is the honest trigger until K3. |
| **Draw safety rails** | A draw may only go to `CertFactory.isVault` addresses. Each draw is capped at `maxDrawBps` of pool assets, checked at proposal *and* at execution. It becomes executable after `drawDelay` and expires `DRAW_EXECUTION_WINDOW` after that. | A compromised or mistaken Safe can take at most one capped slice, only to a vault (where the USDG backs holders), and only after a public delay. |
| **Withdrawals** | `requestWithdraw` → wait `cooldown` → redeem within `withdrawWindow` | An instant exit makes the stake worthless as insurance: stakers leave the moment a loss looks likely. |
| **Running from a draw** | While any draw is pending (proposed, not executed, cancelled or expired), **redeems and deposits are paused** | Otherwise a staker whose window happens to be open sees the proposal and leaves before it executes, while a new depositor walks into a loss already announced. The pause is bounded by the draw's expiry, so governance cannot trap stakers indefinitely. |
| **No trapping stakers** | At least `MIN_PROPOSAL_GAP` (7 days) between two draw proposals, and `drawDelay + 3 days + 1 day ≤ 7 days` is enforced at construction | Exits pause while a draw is pending. Without a gap, governance could re-propose forever and hold every staker in place. With it, exits reopen for at least a day between cycles. |
| **Yield** | Any USDG transferred to the pool raises the share price for every staker, including those in cooldown | The contract needs no reward logic. The cooldown blunts a deposit-before-reward sandwich: the sandwicher carries the draw risk for at least `cooldown`. |
| **Inflation attack** | OZ ERC-4626 virtual shares, `_decimalsOffset() = 6` | The standard mitigation for the first-depositor donation attack. It is tested. |
| **Upgradeability** | None. Governance, registry, asset and every parameter are immutable. | This matches the rest of the protocol. |

Constructor bounds, so no deployment can misconfigure it:

* `cooldown > drawDelay`, so a staker who has not already requested a withdrawal cannot finish
  one inside a draw's delay;
* `withdrawWindow ≥ 1 day`;
* `0 < maxDrawBps ≤ 5000`;
* no zero addresses.

## Where yield comes from — honestly

* **K1:** from **nothing automatic.** Yield exists only when something sends USDG to the pool,
  for example governance forwarding treasury income. At today's volume that is roughly zero.
  No emissions: the design rules them out.
* **K2 (a new vault version, stack 5, Safe redeploy and migration):** vaults let anyone sweep
  their fee income to a `FeeVault`, which splits it. **The split, set by the owner on
  2026-09-26, is 70/20/5/5** (see K2 below). The 70% addressed to `InsuranceStaking` raises
  its share price.
* **Funding surplus** only exists when funding is *received*. The vaults are long, and today
  longs *pay* (for example 0.0004%/h on TSLA). So this leg is currently a cost, not a yield.

## Phases

| Phase | What | Needs |
|---|---|---|
| **K1** | `InsuranceStaking` contract and tests (this document) | — done, not deployed |
| **K1-deploy** | Deploy with the Safe as governance and `CertFactory` as the registry; site panel (deposit / cooldown / redeem / pending draws) | external audit, legal read, owner decision |
| **K2** | `FeeVault` plus a vault version whose fees can be swept to it (below) | — written and tested, not deployed. Deploying needs the recipient addresses, a new stack and a migration plan |
| **K3** | An objective draw trigger (for example a redemption provably unpayable for N days) replaces the governance proposal | the K2 vault, audit |
| **K4** | A CERT tranche behind the USDG tranche, with a defined swap route | CERT liquidity |

## K2: fee routing — what changed, and why each rule is the way it is

### What changed

* **`CertVault`** counts every fee at the moment it is taken, in `feesAccrued`: both mint paths
  (`mintInstant`, `requestMint`, keeper mode included), `redeemInstant` and `_queueExit`
  (`requestRedeem` / `forceExit`). No mint or redemption moves any fee out of the vault.
* **`sweepFees()`**, permissionless, moves `min(feesAccrued, spareCollateral())` to `feeSink`
  and emits `FeesSwept`. With no sink set it **reverts** with `CertVault_NoFeeSink`, so nobody can
  mistake "nowhere to send it" for "sent". A sweep with nothing spare returns 0 and moves nothing.
* **`setFeeSink(address)`**: governance only, **once**, never zero. This is a setter and not a
  constructor argument because `CertVault`'s constructor arity is frozen: the auditor's evidence
  files construct it. It is set-once for the same reason `enableKeeperHedging()` is one-way.
* Four new counters that `spareCollateral()` reads: `escrowOutstanding`, `retainedBacking`,
  `bufferCapital` (plus `feesAccrued`). With no sink set, every existing behaviour and event is
  unchanged. The counters are written, but nothing reads them except the sweep.
* **`FeeVault`**: no owner. It is built with 1 to 8 recipients, each with a non-zero share in
  basis points. The shares must sum to exactly 10 000, and zero addresses and duplicates are
  refused. Permissionless `distribute()` splits the whole balance. Each share is floored, and the
  leftover (fewer units than there are recipients) stays for the next call.

### Why pull, never push

Law 2 says no redemption, claim, refund or `forceExit` may fail or wait because of fees. A push
would put an external transfer, and a revert, on those paths. It would also move cash at the
moment the balance is being drawn on. So the fee paths only count, and the only additions on the
redemption paths are two bookkeeping steps that cannot revert. `_accrueFee` saturates instead of
overflowing. `_releaseBacking` is the same floored `mulDiv` `_queueExit` already uses for
`postedMargin`, so it cannot underflow. The transfer happens in a separate call that nobody has
to make.

### What a sweep may touch, and why that list is complete

Every claim on a vault is paid out of the vault's own balance, out of collateral at the venue,
or out of both. A sweep can only move the balance. So it is enough to hold back the balance-side
part of every claim. `spareCollateral()` is the balance minus, floored at zero at each step:

| Held back | What it covers | Exact or conservative |
|---|---|---|
| `totalOwedOutstanding` | every unpaid queued redemption | conservative: held back **in full**, although part of it is still being recalled from the venue |
| `escrowOutstanding` | every open mint receipt's escrow, until `settleMint` or `refundMint` | conservative: held back **in full**, although `requestMint` posted 50–100% of it to the venue |
| `retainedBacking` | the float of every outstanding certificate: the share of its net collateral that `_postMargin` did **not** send to the venue | exact up to rounding in the holders' favour. The venue share and the hedge P&L are at the venue, where no sweep can reach |
| `bufferCapital` | the vault's own first-loss capital (`seedBuffer`, less the bootstrap dust sent to the venue) | so a sweep only ever moves fee income, never the buffer |
| the declared deficit | how far the attester-relayed BufferBook ledger has fallen below `bufferCapital`: losses beyond what the capital and mint dust absorb | rounded up. It is the only on-chain signal that the venue side is short |

These are all the parties the vault can owe: holders, queued claimants, and depositors whose
receipts are unsettled or awaiting refund. Two things add to that list: the protocol's own
capital, and losses somebody has declared. Nothing else is ever paid out of the balance, apart
from `sweepRetired` on an empty, retired vault. The tests pin each row: removing any single term
makes at least one test in `test/CertVaultFees.t.sol` fail. That was checked by mutation.

**What this does not see:** venue-side losses nobody has declared. The chain cannot read the
venue position, so fees can leave before a loss nobody has relayed would have been charged to
them. This is the trust boundary `solvency()` already has. It is also why `feesAccrued` caps a
sweep, and the balance does not.

**The attester's lever works one way only.** Declaring a loss blocks sweeps. No declaration can
release holder backing, because none of the first four rows depends on the ledger.

**`feesAccrued` counts fees assessed, not fees realised.** A queued redemption's fee is assessed
at the request price. If the price then falls, `claimRedeem`'s H-2 cap can pay less than was
owed, and part of that fee was never realised. The counter does not un-assess it. That cash never
reached the balance, so `spareCollateral()` cannot see it and holders are not affected. The
overstated ceiling can let a sweep take some other surplus instead (a realised gain, a
donation), up to the assessed amount.

**Two side effects the owner should know about.** Neither is a Law 2 issue:

* A sweep can make an instant redemption that fee cash would have covered go to the queue
  instead. Fees were never a promise of instant liquidity, and the queue is always open.
* Fees currently count in `freeCollateral18()`, so they raise mint capacity. Sweeping them lowers
  it by the same amount. `freeCollateral18()` still does not net out `escrowOutstanding`. Wiring
  that in would change mint admission control, which K2 is not about.

### The split: decided — 70/20/5/5 (owner, 2026-09-26)

| Share | Recipient | Notes |
|---|---|---|
| **70%** | `InsuranceStaking` | Pays stakers for taking the first loss; raises the share price. |
| **20%** | A buyback fund | Held in USDG until a CERT market exists to buy on (K4). It must be an address that cannot revert a transfer: a Safe-controlled account, not a contract that can be paused. |
| **5%** | A keeper and operations gas wallet | Pays the gas for settlements, refunds and recalls. |
| **5%** | The treasury, the 2-of-3 Safe `0x848c…70DF` | |

It replaced three published versions that disagreed: the whitepaper's 80/10/5/5 (buyback /
stakers / treasury / ops), the Roles page's, and the Learn page's (stakers / buffer / keepers /
treasury). All of them now say 70/20/5/5. `test_ownerSplit_70_20_5_5` pins it: 12.345678 USDG
splits to exactly 8.641974 / 2.469135 / 0.617283 / 0.617283, with 3 units of dust carried
forward.

**Decided 2026-09-26 (owner):** the buyback fund and the ops wallet are both the deployer,
`0x6381577a72266E6b89eE9E96dF604CC3cd3f8e92`. An EOA cannot revert a USDG transfer, so it
satisfies point 3. The buyback leg reaches CERT stakers only when the fund **calls**
`CertStaking.notifyRewardAmount`. `FeeVault` must never pay `CertStaking` directly: a plain
transfer into it is not credited, and nothing could ever stream it.

3. **Recipients that cannot be frozen out.** One recipient whose transfer reverts stalls every
   `distribute()`, and `FeeVault` has no owner to route around it. Suitable recipients: the Safe
   and `InsuranceStaking`.

### Interplay with K1 draws — for K3

`InsuranceStaking.executeDraw` pays a vault by plain transfer. That lands in the balance and in
no reserve. If the loss behind the draw was **declared** (through `accrueFunding`), the deficit
term already holds back fees against it. A draw then frees only the fees above the deficit, which
matches the loss order: fees absorb first, insurance absorbs next. If the loss was **not**
declared, the draw can free previously held fees, which then flow back out through the split. So
governance should have the attester declare a loss before it proposes a draw. K3 should make the
draw pay through `seedBuffer`, so drawn capital is `bufferCapital` and can never be swept.

### Deploying K2 is a new stack, not an upgrade

Every contract here is immutable, so there is no upgrade path. Deploying K2 means:

1. deploy a **new vault stack (stack 5)**, with the UseCert 2-of-3 Safe as governance;
2. deploy the `FeeVault` with the split the owner chose;
3. from the Safe, call `setFeeSink(feeVault)` on each new vault. It is set-once, so check the
   address before signing;
4. **migrate holders**: redeem from stack 4 and mint on stack 5. Stack 4 keeps working for
   redemption indefinitely (Law 2), but its fees stay inside it forever apart from `retire()`.

The deploy script does not do step 3 yet. K2 is code and tests only.
