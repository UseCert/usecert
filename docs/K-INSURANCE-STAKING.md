# K — Insurance staking: design, phase K1

Status: **K1 written and tested, not deployed.** Mainnet deployment needs an external audit, a
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
* **K2 (a new vault version, stack 5, Safe redeploy and migration):** vaults forward a share of
  mint and redeem fees to a `FeeVault`, which splits them. The split, set by the owner on
  2026-09-26, is 70/20/5/5: stakers (sent to `InsuranceStaking`) / a buyback fund held in USDG
  until a CERT market exists / keeper and operations gas / the treasury (the 2-of-3 Safe).
* **Funding surplus** only exists when funding is *received*. The vaults are long, and today
  longs *pay* (for example 0.0004%/h on TSLA). So this leg is currently a cost, not a yield.

## Phases

| Phase | What | Needs |
|---|---|---|
| **K1** | `InsuranceStaking` contract and tests (this document) | — done, not deployed |
| **K1-deploy** | Deploy with the Safe as governance and `CertFactory` as the registry; site panel (deposit / cooldown / redeem / pending draws) | external audit, legal read, owner decision |
| **K2** | `FeeVault` plus a vault version that forwards fees | new stack, migration plan |
| **K3** | An objective draw trigger (for example a redemption provably unpayable for N days) replaces the governance proposal | the K2 vault, audit |
| **K4** | A CERT tranche behind the USDG tranche, with a defined swap route | CERT liquidity |
