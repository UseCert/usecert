# Response to the Launch-Readiness Audit, 25 September 2026

Reviewed at front end `abfe8fc`, contracts `6dea84c`.

The audit's verdict — **no-go for mainnet, promising testnet prototype** — is correct and is
not disputed anywhere below. Most of its findings are accurate and several were already open
in `ROADMAP.md`. This file records what has been checked since, what was fixed, and the one
headline finding where the observation is right and the conclusion is not.

---

## 1. "The live testnet is currently not mint-operational" — observation right, conclusion wrong

The audit measured every mirror at ~395,000 seconds of attestation age with zero capacity, and
concluded a "currently dead attestation process" and that "new mints are stopped by zero
capacity". The measurement is exactly reproducible; the inference is not.

**Attestation became on-demand on 2026-09-20.** The attester signs; it no longer broadcasts.
The registry is therefore stale between mints *by design*, capacity reads zero, and the minter
relays a fresh signature inside their own transaction before minting. An idle protocol costs
nothing to keep open — which was the point — but it cannot be distinguished from a dead one by
reading chain state alone, which is what the audit did.

That said, **the path had never been proven end to end**, and the audit was right to demand it.
It has now been run against the live deployment:

| step | transaction |
|---|---|
| faucet `claim()` | `0xf22ad4d0a3963744bc87589fe8f4ad9e38bbe63df7ec160e2e0370ab56647895` |
| `attestSigned` (relayed) | `0x822374c04f315828170a0834bbca2afebee588f1bf9414d5e7545d1332c7f716` |
| `approve` | `0x5d5f6560b68e0cbe9daa28175501d3cf05b939a651e2b04167b53e8e564e66bf` |
| `mintInstant` | `0x72fd4e57e05d60d9885be06a2157474c0b5dce1a9fc7a915bbfdc80658649eac` |
| `redeemInstant` | `0x4c2a6688da6f26a3af42d18ec9d8fba51e8a05baabdde7b56ee0e2f2d62ef46a` |

Measured across the run:

```
before   attestation age 414,264s   capacity 0
after relay               20s       capacity 90,000e18
mint     10 tUSDG  ->  0.0272 uTSLA
redeem   returns collateral, supply back to its opening value
```

**Minting works today**, without any keeper being restored, because the mint restores freshness
itself. The script is committed as `deploy/bin/usecert-smoke` so this is repeatable rather than
a claim.

**One honest correction about that run.** The first version passed the *full* certificate
balance to `redeemInstant`, which redeemed 1.3624 uTSLA that predated the test and took total
supply to zero. It was minted straight back (`0xd56462ca…`) and supply is again 1.3624. The
committed script now redeems only the delta it minted, so the test leaves the deployment as it
found it.

**What the audit is still right about here:** there is no alerting on signer freshness as
distinct from attestation age, and a point-in-time check is not monitoring. The dashboard was
separately corrected on 2026-09-23 to stop reporting this idle state as "minting off" —
`useSignerFreshness` now distinguishes "aged out, a mint refreshes it" from "the attester is
not serving", which is the distinction the audit itself could not make from chain state.

---

## 2. Findings accepted without qualification

* **No mainnet deployment system.** Correct at the audited revision. `script/DeployMainnet.s.sol`
  has since been written and compiles, with five constants in `DeployTestnet` promoted to
  virtual getters so a subclass is possible at all. It deploys no `TestUSDG`, no faucet and no
  simulator, and **four values revert rather than default**: the price feed per mirror, the seed
  collateral, the venue's collateral asset index, and `singleSource`. It has never been run.
* **Solvency figures are trusted attester data, not proven on-chain.** Correct, and the
  distinction between "published on-chain" and "verified on-chain" is the right one. Single
  attester, no proof system, no multi-party verification.
* **`forceExit` is not an enforceable redemption guarantee.** Correct. The vault cannot compel a
  real venue to fill. Copy was corrected on 2026-09-25 to state the SLA — same transaction below
  the instant cap, queued and paid by claim above it, two batch round-trips expected, the
  venue's 14-day priority expiration as the worst case — and to say that the guarantee stops at
  the chain: submitting the transaction at all requires Robinhood Chain to include it.
* **Governance, attester, simulator owner and batch keeper are EOAs.** Correct. Multisig custody
  is unbuilt.
* **`forge fmt --check` red, front-end lint red (1,644 errors), no CI, no release manifest.**
  Correct and open.
* **Address book records `signed-attestation` instead of a commit.** Correct, and partly closed:
  the generator now refuses to print a non-commit as one, and the header carries a git commit
  read at generation time plus the address book's sha256. The deploy-time commit still needs
  `COMMIT=$(git rev-parse HEAD)` set when the script runs.

---

## 3. Findings already closed before the audit landed

Timing rather than disagreement — these were fixed between the audited revision and the report.

* **"uSPY and uQQQ market mappings unverified".** Worse than reported. Checked against Lighter's
  live market list on mainnet: **none of the four match**, including uTSLA and uNVDA, which this
  repository had recorded as venue-verified. The real ids are 112, 128, 129, 110. The dashboard
  now reads "venue market index verified 0/4" and publishes the real ids.
* **Market mapping on uNVDA is worse still:** its venue decimals are 3/3, not the 2/4 copied
  from its neighbours. `_quantiseToVenue` rounds size by `10 ** sizeDecimals`, so that would
  have quantised every NVDA order to the wrong lot.
* **Contracts unverified on the explorer.** All 26 now publish source, including the three
  mirrors whose four core contracts were entirely unverified. Blockscout reports a partial
  match: runtime bytecode agrees, metadata hash does not.
* **No published address book.** `/contracts` now lists all 26 with a link to each verified
  source, generated from the same module the app transacts against.

---

## 4. Open, and honestly open

Nothing below is fixed.

| | |
|---|---|
| P0 | Product and legal copy still overstates in places the audit names — staking, slashing, insurance, fee passthrough, buybacks, "LIVE" on simulated mirrors |
| P0 | `/api/attestations` routing is not in the repository as deployable configuration |
| P0 | No security-header policy: CSP, HSTS, frame protection, Referrer-Policy, Permissions-Policy, X-Content-Type-Options |
| P1 | `forge fmt` red, front-end lint red, no CI, no release manifest, Slither's 97 findings untriaged |
| P1 | Runbooks conflict with code in places |
| mainnet | Venue behaviour unvalidated against the real engine; attestation trust model; qualified collateral; multisig governance; a fresh independent review tied to an immutable artifact |

---

## 5. Where this response disagrees, precisely

Only on the framing of §1. "Not mint-operational" describes a deployment where minting cannot
happen. Minting can happen, and now demonstrably does. What is true is narrower and still worth
saying: **the deployment presents a state that is indistinguishable, from the outside, from a
broken one** — and an auditor reading chain state reached exactly the conclusion an ordinary
user would. That is a real product problem even though it is not a liveness failure, and the
dashboard changes of 2026-09-23 exist because of it.

The audit's closing advice — make the testnet boundaries first-class, publish reproducible
evidence, let the rigor speak — is the right advice and this file is written to it.
