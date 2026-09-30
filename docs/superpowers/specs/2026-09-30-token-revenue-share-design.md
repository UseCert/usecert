# Stack 6: token revenue share — design

Date: 2026-09-30. Status: design, owner-delegated decisions. Scope: the revenue-share contracts of
stack 6 only (fee routing, buyback and burn, token staking). The stack-6 CertVault changes that
Sermium's audit asks for (M-02, L-05, L-06, I-11) are a separate spec.

## Why

Stack 5 sends vault fees through FeeVault 70/20/5/5: 70% to the insurance pool, 20% to a
"buyback" leg that in fact forwards USDG to CertStaking, 5% ops, 5% treasury. Nothing is ever
bought, and on 2026-09-30 both CERT staking pools hold zero stake, so the token leg reaches nobody.
FeeVault's recipients and every vault's fee sink are immutable, so a stronger revenue share needs
new contracts and new vaults: stack 6, relaunched with a new token after stacks 4 and 5 wind down.

## Decisions

| Question | Decision |
|---|---|
| Mechanism | Hybrid: fees buy the token on the market; half is burnt, half is streamed to stakers |
| Size of the token share | Insurance first, up to a coverage target; then 80% of fees to the token side |
| Burn / stake | 50 / 50 of every buyback |
| Market | The token launches on a bonding-curve launchpad; the buyback buys from its DEX pool after graduation |
| Buy mechanism | On chain, in capped hourly tranches, guarded by the pool's own 30-minute average price |
| Token address | A constructor argument (the new token; CERT is retired with stacks 4 and 5) |

## Components

Three contracts, each with one job, no owner, no pause, no upgrade. The only privileged role is
the governance Safe, for the two bounded, delayed settings named below.

### 1. RevenueRouter (replaces FeeVault)

Every stack-6 vault's fee sink. Pull-based like FeeVault: `distribute()` credits, `claim(recipient)`
pays, both permissionless, so a frozen recipient cannot block the others.

The split of each distribution depends on how well insurance is funded:

- `coverage = InsuranceStaking.totalAssets()`
- `target = targetBps x open value`, where open value is the sum over the registered stack-6 vaults
  of `certificate.totalSupply() x oracle.pxUnguarded()`, the vaults being those registered in the
  stack-6 CertFactory the router is constructed with (at most 12; bounded gas)

| State | Insurance | Token side (Buyback) | Ops | Treasury (Safe) |
|---|---|---|---|---|
| coverage < target | 50% | 30% | 10% | 10% |
| coverage >= target | 0% | 80% | 10% | 10% |
| insurance pool has no shares | 0% (to treasury) | 30% | 10% | 60% |

The third row closes the first-depositor prize (Sermium L-02): income never reaches an empty pool.

`targetBps` starts at 500 (5%). The Safe may change it within [200, 1000] only through
`proposeTarget` / `applyTarget` with a 2-day public delay. Nothing else is settable; recipients are
constructor arguments.

### 2. Buyback

Holds USDG credited by the router and turns it into burnt and staked tokens.

- Before graduation it only accumulates.
- `proposePool(pair)` / `applyPool()`: the Safe sets the token's DEX pair once, after a 2-day public
  delay. `applyPool` checks the pair holds exactly the token and USDG. The pool can never change.
- `buy()` is permissionless, at most once per `BUY_INTERVAL` (1 hour). It spends
  `min(TRANCHE_MAX (200 USDG), 1% of the pair's USDG reserve, balance)`.
- Price guard: the contract keeps its own observation of the pair's `price0CumulativeLast` /
  `price1CumulativeLast`. A buy needs an observation between 30 minutes and 2 hours old; the average
  price since then is the reference, and the swap must return at least 98% of the tokens that price
  implies, or it reverts. The call then records a fresh observation. A stale observation (over
  2 hours) only records a new one and buys nothing, so the first buy after a gap waits 30 minutes.
- The swap goes straight to the pair (`transfer` in, `swap` out; amounts from the pair's reserves
  and its 0.3% fee), no router.
- Of the tokens received: 50% burnt (the token's `burn` if the constructor's `tokenHasBurn` says it has one,
  otherwise sent to `0x…dEaD`); 50% sent to Staking v3 via `notifyRewardAmount`. If Staking v3 has
  no stake at that moment, that half is burnt too: no reward for being the first staker.
- The caller receives `min(0.5 USDG, 1% of the tranche)` from the tranche for the gas; our own job
  calls it hourly anyway.
- Event per buy: USDG spent, tokens received, average price, burnt, to stakers, caller reward.
- It can never send USDG anywhere except the pair and the caller reward, never change the pair, and
  never hold tokens after a buy.

### 3. Staking v3

Stake the token, earn the token.

- Each funding vests linearly: `notifyRewardAmount(x)` sets the stream to
  `remaining + x` ending at `now + (remaining x (end - now) + x x DURATION) / (remaining + x)`,
  `DURATION` = 7 days. A funding therefore streams over close to a full week whenever it is large,
  so staking one hour before it lands earns about 1/168 of it (Sermium M-01), and a dust funding
  moves the end by almost nothing (L-01).
- Exits: `requestUnstake(amount)` starts a 7-day cooldown; stake in cooldown earns nothing and is
  withdrawn with `withdraw()` after it. Rewards stay claimable at any time (`getReward`).
- Reward accrued while nothing is staked is carried into the stream, as CertStaking v2 does
  (Buyback burns rather than funding an empty pool, so this only arises from direct donations).
- No stake cap (L-04), no owner, no pause. Funding is permissionless (any donation just streams).
- Solvency invariant, fuzzed: sum of earned + stream remaining + carried <= token balance − staked.

## Data flow

```
stack-6 vaults --sweepFees--> RevenueRouter --claim--> InsuranceStaking (below target)
                                            --claim--> Buyback --buy()/hour--> DEX pair
                                                                  |-> 50% burn
                                                                  '-> 50% Staking v3 (7-day vesting)
                                            --claim--> ops, treasury (Safe)
```

## Failure handling

| Condition | Behaviour |
|---|---|
| Token not graduated / pool not set | USDG accumulates in Buyback; nothing is lost |
| Pool price moved or manipulated | `buy()` reverts on the 2% guard; next hour retries |
| Thin pool | Tranche capped at 1% of the USDG reserve |
| Observation stale | The call records a new observation; buying resumes 30 minutes later |
| Token paused or frozen by its issuer | `buy()` reverts; USDG accumulates |
| A recipient cannot receive | Its credit stays in the router (pull model); others unaffected |
| No stakers | Staking half is burnt |
| Insurance pool empty | Insurance share to treasury |

## Testing

- Unit tests per contract, including every row of the failure table.
- Fuzz: router shares always sum to the amount distributed less dust; staking solvency invariant;
  Buyback never holds tokens after `buy()`.
- Attack tests that must fail: one-hour JIT staking before a large funding (expected capture
  <= 1%); dust funding every hour (vesting delay < 1%); a sandwich of `buy()` within one block
  (reverts on the guard); a first depositor after income (no prize).
- Fork test against a real graduated launchpad V2 pair on Robinhood Chain (CERT's pool is one) for
  the swap maths and the price accumulators.

## Out of scope

Stack-6 CertVault fixes (separate spec), the new token's own tokenomics and launch, the front end,
and the wind-down of stacks 4 and 5 (in progress, `usecert-s5-cutover wind-down`).
