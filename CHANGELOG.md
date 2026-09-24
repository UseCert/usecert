# Revision history

Dated rather than versioned. Nothing here has shipped to mainnet, so a semantic version
number would imply a release process that does not exist yet — see
[use-cert.com/roadmap](https://use-cert.com/roadmap) for what has to be true before one does.

Two projects with independent histories share this repository. Entries are marked
**[front end]** (`main`) or **[contracts]** (`backend/contracts-c1`) where it matters.

---

## 2026-09-24

- **[front end]** A README that says what the project is. The previous one opened with a
  leftover prompt, *"Implement exactly the screenshot and nothing else"*, followed by
  scaffolding boilerplate and a dead `lovable.app` link.
- **[front end]** `LICENSE` added to the default branch. The MIT licence had existed only on
  the contracts branch, so GitHub reported the repository as unlicensed.
- Repository description, website and topics set; organisation profile filled in.

## 2026-09-23

- **[front end]** Public milestones page at `/roadmap`: what is shipped, what is being built,
  and what has to be true before mainnet. No dates, and every shipped item carries a way for
  a reader to check it.
- **[front end]** An aged attestation is no longer reported as an outage. Under on-demand
  attestation nobody pays to keep the registry fresh between mints, so a large `ageSec` is the
  idle state of a working protocol — the dashboard had been publishing *"minting off"* over a
  system where minting worked. It now asks whether a mint could refresh it, per vault, and
  warns only when the attester is genuinely not serving.
- **[front end]** Removed a footer link to the 404 page, a scaffolding leftover that offered
  the error page as a destination.
- **[front end]** Copy: the four remaining `USDC` mentions now read `tUSDG`, the collateral
  that actually exists here; and four claims to be *"the first"* of something are gone.
- **[contracts]** The generated contract bundle carries provenance the address book cannot
  fabricate — a git commit read at generation time, and the address book's `sha256`. The
  header had read `commit signed-attes`, a label truncated into the shape of a hash.
- **[contracts]** The price feed got its failure budget back. Measured cycle was ~567s against
  a 900s staleness limit, so a single dropped push breached it and stopped minting on that
  mirror. Now retried once, and cycling at ~420s.

## 2026-09-22

- **[contracts]** Backups: a separately restorable set per project rather than one dump for
  everything, and an encrypted offsite copy with one week retained.

## 2026-09-21

- **[front end]** Reachable from wallets that are not browser extensions.
- **[front end]** Fixed a missing import that made every mint throw before submitting a
  transaction, pinned the relay's target contract, and removed 275px of horizontal scroll on
  a 375px viewport.
- **[contracts]** Maintenance mode for the site.

## 2026-09-20

- **[contracts]** Attestations the attester **signs** and the minter **relays**, replacing a
  keeper that broadcast on a timer. An idle protocol no longer pays to stay open.
- **[front end]** The mint path relays that signature inside the user's own transaction.
- **[contracts]** Health alerts rewritten to fire on what breaks minting now, rather than on
  the designed idle state.
- **[front end]** Decorative clutter removed across the marketing site and dashboard.

## 2026-09-18

- **[front end]** Corrected the X and Telegram handles.

## 2026-09-16

- **[contracts]** MIT licence.
- **[contracts]** systemd units and a keeper wrapper for the Linux host.

## 2026-09-10

- **[contracts]** `uQQQ` and `uNVDA` mirrors deployed. `uSPX` retired — the venue has no SPX
  perp, so the vault had nothing to hedge against.
- **[front end]** Flow history read from the chain's explorer index.

## 2026-09-09

- **[contracts]** The testnet stack: vault, certificate, oracle, solvency registry, capacity
  oracle, buffer book, a simulated venue, test collateral and a faucet. Deployed to chain
  `46630` and recorded in `deployments/46630.json`.
- **[front end]** Wired to the live deployment, and the invented figures deleted — where a
  number could not be read from the chain, the dashboard stopped showing one.
- **[front end]** Stopped asserting copyright over Robinhood's mark; non-affiliation and the
  testnet notice stated where a visitor connects.

## 2026-09-04 — 2026-09-07

- **[front end]** Initial scaffolding and the marketing site, generated iteratively. Preserved
  on the `lovable/original` branch for provenance.
