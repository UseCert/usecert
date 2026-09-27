# K — Insurance staking: design, phases K1 and K2

Status: **K1 and K2 written and tested, neither deployed.** Mainnet deployment needs an external audit, a
legal read (a yield-bearing stake is the most security-like thing UseCert would offer) and the
Safe's 2-of-3.

**`InsuranceStaking` v2 (stack 5)** fixes the internal pre-audit's insurance findings (H-3, H-9,
M-2, M-14, L-3's unclaimable fees, L-14, L-16). It is a new contract for a new deploy; the pool
deployed with stack 4 is immutable and keeps v1's behaviour. The last section of this document,
"v2 (stack 5): what changed, and what a compromised Safe can still do", is the authoritative
statement; the K1 table is updated to match it.

## What it is for

The whitepaper's loss order is fixed: **vault buffer → insurance → (never) holder backing.** In
C1 the middle rung does not exist. `BufferBook.insuranceDrawNeeded()` publishes a number that
nothing consumes. K1 builds that rung.

## The one fact the design is built on

**Anyone can transfer USDG into a vault, and it lands in the vault's own collateral balance**,
which is the `buffer18` figure the solvency math reads (`hotBuffer()` is `balanceOf(this)`).

So insurance can pay out **without changing a single deployed vault.** The insurance contract
transfers USDG to the vault, and that USDG backs holders from that moment.

v2 no longer relies on this. A plain transfer lands as spare balance, which a K2 vault can sweep
out as fees (K2-M-13) and a retired vault sweeps to governance (H-3). v2 therefore pays only
through the vault's own `receiveInsurance(amount)`, which must book it as capital that can never
be swept. The pool needs three functions from a vault (`IInsurableVault`): `retired()`,
`insuranceShortfall()` and `receiveInsurance(uint256)`. The stack-5 `CertVault` implements them;
no earlier vault does, so **a v2 pool can only pay stack-5 vaults.**

The reverse is not true. Today fees stay inside each vault as collateral, and no function can
route them out, apart from `retire()` on an empty vault. **Fee-funded staker yield therefore
needs a new vault version** (phase K2, below).

## K1: `InsuranceStaking.sol` — decisions, with the reason for each

| Decision | K1 choice | Why |
|---|---|---|
| **What is staked** | **USDG**: an ERC-4626 vault over the collateral itself | A draw must deliver collateral. Staked CERT would first have to be *sold* for USDG, in a crisis, into a market that is falling because of that crisis. That is the reflexive loop that ends insurance funds. A CERT tranche can sit *behind* this one later, with a swap route. |
| **How losses are taken** | A **draw** moves USDG from the pool to a registered vault, and every share loses value pro rata | There is no per-user slashing logic to get wrong. The share price is the whole state. |
| **Who can draw** | **Governance (the 2-of-3 Safe) proposes**; anyone executes after a delay | There is no objective on-chain loss oracle yet: the accrual ledger is attester-relayed. A human decision, delayed and published, is the honest trigger until K3. |
| **Draw safety rails** | A draw may only go to a `CertFactory.isVault` address **registered at least `registrationDelay` ago** (at least cooldown + window) that is **not retired**. It pays the smaller of the proposal and the vault's **declared `insuranceShortfall()`** (none declared: it reverts), **through `receiveInsurance`**, with an exact allowance and an exact balance check. Executed draws in **any 30 days** total at most `maxDrawBps` of the assets at the start of those 30 days. The checks run at proposal and again at execution. The draw becomes executable after `drawDelay` and expires `DRAW_EXECUTION_WINDOW` after that. | v1's version of this row said a compromised Safe gets "at most one capped slice, only to a vault where it backs holders". That was false (H-3): it could draw into an empty vault, retire it and sweep the draw to itself, weekly. What v2 guarantees instead is in the v2 section below. |
| **Withdrawals** | `requestWithdraw` **moves the shares into escrow** → wait `cooldown` → redeem them within `withdrawWindow`. `cancelWithdraw` returns them at any time, including after the window has closed. Escrowed shares cannot be transferred, and nothing can be sent into the escrow. | An instant exit makes the stake worthless as insurance: stakers leave the moment a loss looks likely. v1 attached a request to an address while the shares stayed transferable, so rotating shares across staggered requests gave an instant exit (H-9). Escrowed shares still count, earn and absorb draws. |
| **Running from a draw** | While any draw is pending (proposed, not executed, cancelled or expired), **redeems and deposits are paused** | Otherwise a staker whose window happens to be open sees the proposal and leaves before it executes, while a new depositor walks into a loss already announced. The pause is bounded by the draw's expiry, so governance cannot trap stakers indefinitely. |
| **No trapping stakers** | At least `MIN_PROPOSAL_GAP` (7 days) between two draw proposals; `drawDelay + 3 days + 1 day ≤ 7 days`; and **`withdrawWindow ≥ drawDelay + 3 days + 1 day`**, all enforced at construction | Exits pause while a draw is pending. Without a gap, governance could re-propose forever and hold every staker in place. With it, exits reopen for at least a day between cycles. v1 let a pause (5 days) outlast a window (3 days), so a 1-unit proposal timed before a chosen staker's window closed it every time (M-2). Now every window has at least a day unpaused, wherever a proposal lands. |
| **Yield** | Any USDG that reaches the pool other than as a deposit (fees, donations) **vests linearly into the share price over `VESTING_PERIOD` (7 days)**, for every staker including those in cooldown. An arrival nobody has synced counts as wholly unvested. `sync()` starts it vesting; it is permissionless, and every deposit, exit and draw runs it too. A new arrival rolls the unvested remainder into one fresh 7-day schedule. While there are no shares, nothing vests: income waits, then vests to the first stakers. | The contract needs no reward logic. v1 stepped the price on arrival, and the arrival is caller-timed, so deposit → distribute → redeem in one transaction took a share of the fees with no risk (M-14). Fees sent while nobody was staked were absorbed by the virtual shares (L-3). Because of the roll, anyone can stretch vesting by sending dust: income then vests with a time constant of about a week instead of in exactly a week. That moves income later, to stakers who stay, never out of the pool. |
| **Deposit cap** | `depositCap` bounds **net principal**: deposits in, minus principal withdrawn. A withdrawal of `shares` removes `netPrincipal × shares / totalSupply` (rounded down); the last shares out remove the rest. A draw does not reduce it. | The cap bounds what anyone can lose to a bug in an unaudited pool, so it should count money put in, not money earned. v1 capped `totalAssets()`, so income and donations closed the pool to new stakers (L-16). |
| **Transfers during a pause** | Shares that are **not** in escrow stay transferable while a draw is pending | Accepted (L-14). A transfer moves exposure between two stakers and takes nothing out of the pool, and the receiver cannot redeem without its own request and cooldown. |
| **Inflation attack** | OZ ERC-4626 virtual shares, `_decimalsOffset() = 6` | The standard mitigation for the first-depositor donation attack. It is tested. |
| **Upgradeability** | None. Governance, registry, asset and every parameter are immutable. | This matches the rest of the protocol. |

Constructor (v2): `(asset, registry, governance, cooldown, withdrawWindow, drawDelay, maxDrawBps,
depositCap, registrationDelay, name, symbol)`. The bounds, so no deployment can misconfigure it:

* `cooldown > drawDelay`, so a staker who has not already requested a withdrawal cannot finish
  one inside a draw's delay;
* `withdrawWindow ≥ 1 day`, and `withdrawWindow ≥ drawDelay + DRAW_EXECUTION_WINDOW + 1 day` (M-2);
* `drawDelay + DRAW_EXECUTION_WINDOW + 1 day ≤ MIN_PROPOSAL_GAP`, so `drawDelay ≤ 3 days`;
* `registrationDelay ≥ cooldown + withdrawWindow` (H-3);
* `0 < maxDrawBps ≤ 5000`, and `depositCap > 0`;
* no zero addresses.

v2 refuses the stack-4 parameters (window 3 days, delay 2 days). A valid set: cooldown 10 days,
delay 2 days, window 6 days, registration delay 16 days.

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

v1's `InsuranceStaking.executeDraw` paid a vault by plain transfer. That lands in the balance and
in no reserve, so a permissionless `sweepFees()` in the same block could take it out as "fees"
(K2-M-13; in the PoC, 10.50 USDG of a draw was swept, 3.15 of it out of the loss waterfall). v2
pays only through `receiveInsurance`. The stack-5 vault must book what it receives as
non-sweepable capital (the role `bufferCapital` plays) and keep it out of `sweepRetired`. That half
of the fix is in `CertVault`, not in the pool: the pool can only check that exactly the drawn
amount left it. Governance should still have the attester declare the loss before proposing, so
that `insuranceShortfall()` reflects it.

### Deploying K2 is a new stack, not an upgrade

Every contract here is immutable, so there is no upgrade path. Deploying K2 means:

1. deploy a **new vault stack (stack 5)**, with the UseCert 2-of-3 Safe as governance;
2. deploy the `FeeVault` with the split the owner chose;
3. from the Safe, call `setFeeSink(feeVault)` on each new vault. It is set-once, so check the
   address before signing;
4. **migrate holders**: redeem from stack 4 and mint on stack 5. Stack 4 keeps working for
   redemption indefinitely (Law 2), but its fees stay inside it forever apart from `retire()`.

The deploy script does not do step 3 yet. K2 is code and tests only.

## v2 (stack 5): what changed, and what a compromised Safe can still do

For each fix, a test in `test/InsuranceStaking.t.sol` replays the attack and asserts that it no
longer works. The tests are named after the finding, and after the K2 PoCs `H01`, `H02`, `M01`
and `L01`. Removing any one fix makes at least one of them fail; this was checked by mutation.

| Finding | v1 | v2 |
|---|---|---|
| **H-9** cooldown bypass | A request was a number per address; shares stayed transferable | Requested shares are escrowed in the pool; redeem burns from the escrow; `cancelWithdraw` returns them, also after expiry |
| **M-14** atomic sandwich | Income stepped the share price on arrival | Income vests over 7 days; an unsynced arrival is wholly unvested |
| **L-3** fees with no stakers | Absorbed by the virtual shares | Held unvested until there are shares, then vests to them |
| **M-2** window lapses in a pause | Pause 5 days, window 3 days | `withdrawWindow ≥ drawDelay + 3 days + 1 day` |
| **H-3** drain through a vault | Any registered vault, any time, plain transfer, 30% per draw | Registered at least `registrationDelay` ago, not retired, capped at the declared shortfall, paid via `receiveInsurance` with an exact balance check, 30% per rolling 30 days |
| **L-14** `isVault` not re-checked | Checked at proposal only | Re-checked at execution, with the registration age and `retired()` |
| **L-16** income fills the cap | Cap on `totalAssets()` | Cap on net principal |

**The rolling cap, precisely.**

* At every proposal and every execution, the pool sums what executed draws paid in the trailing
  30 days (`drawnInPeriod()`).
* It then allows `drawCap() = maxDrawBps × (totalAssets() + drawn) / 10 000 − drawn`.
* `totalAssets() + drawn` is the pool as it stood at the start of the period, adjusted for the
  deposits, exits and income since then. A percentage cap should follow those.
* It bounds every 30-day window, not just fixed epochs. Take any window: the check at its last
  draw counted every earlier draw in it.
* With no other flows, the draws in any 30 days total at most `maxDrawBps` of the pool at the
  start of those 30 days.

**A compromised Safe can still:**

* register a contract of its own in `CertFactory` (any contract with a matching `certificate()`),
  wait `registrationDelay` in public, and then propose draws to it. That contract can claim any
  shortfall and keep what it pulls. The worst case is therefore `maxDrawBps` of the pool per
  30 days. Before the first such draw there is a public registration at least
  `cooldown + withdrawWindow` old, and each draw waits a public `drawDelay`. Every staker who
  watches `VaultRegistered` has time to request and complete an exit first.
* pause exits and deposits for up to `drawDelay + 3 days` once every 7 days, by proposing draws
  and leaving them to expire. It cannot close any window this way: each keeps at least a day
  unpaused.
* cancel draws, including honest ones.

**It can no longer:**

* draw to a vault registered less than `registrationDelay` ago, to a retired vault, or to a vault
  that declares no shortfall;
* draw more than the vault declares it needs, or more than the rolling cap;
* receive a draw itself through `retire()` and `sweepRetired()` of a stack-5 vault, provided the
  vault keeps insurance capital out of that sweep (the vault's half of H-3);
* hold a staker in place across a whole window;
* touch escrowed shares, the vesting schedule, the deposit cap or any parameter. It has no role in
  the pool besides proposing and cancelling draws.

**Residual, by design.** A staker can still stagger requests across several addresses, each with
its own escrowed shares, so that part of the stake is always inside a window. Those shares did
wait their full cooldown, they absorb every draw until they leave, and a pending draw pauses them
like any other. What escrow removes is using the same shares for every request.
