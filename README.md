# UseCert

Stock certificates as plain tokens, on [Robinhood Chain](https://robinhood.com/).

A UseCert certificate — `uTSLA`, `uSPY`, `uQQQ`, `uNVDA` — is an ERC-20 you hold like any
other token. It tracks the stock, sits in your wallet, and redeems at oracle price whenever
you want out. There is no funding tab to watch, no margin to top up and no liquidation price.

Underneath, each certificate is backed by a delta-hedged perpetual position plus `tUSDG`
margin. The backing is **attested on-chain per batch, and the age of that proof is published
next to it** — the dashboard says how old the figure is and says so plainly when it is stale.

> ### This is a testnet deployment
>
> UseCert runs on Robinhood Chain **testnet** (chain `46630`). Nothing here holds real-world
> value, the collateral is a test token from a faucet, and **the perp venue is a simulator
> this project runs** — so every margin and position figure describes a simulated position,
> not a market.
>
> What is live, what is being built and what has to be true before mainnet is published at
> [use-cert.com/roadmap](https://use-cert.com/roadmap), without dates and with a way to check
> each claim.

## Links

| | |
|---|---|
| Site | [use-cert.com](https://use-cert.com) |
| Milestones | [use-cert.com/roadmap](https://use-cert.com/roadmap) |
| Dashboard | [use-cert.com/dashboard](https://use-cert.com/dashboard) |
| X | [@use_cert](https://x.com/use_cert) |
| Telegram | [t.me/usecertonchain](https://t.me/usecertonchain) |
| Explorer | [Robinhood Chain testnet](https://explorer.testnet.chain.robinhood.com) |

## What is in this repository

Two projects share this repository on separate branches. They have **independent histories** —
there is no merge base between them, which is deliberate rather than an accident:

| Branch | Contents |
|---|---|
| `main` | The front end: marketing site and the live dashboard. TanStack Start, React, wagmi/viem. |
| `frontend/testnet-wiring` | Where front-end work lands first. Same commit as `main`. |
| `backend/contracts-c1` | The Solidity contracts, deployment scripts and operations tooling. |
| `lovable/original` | The original export the site was scaffolded from. Kept for provenance; not developed. |

## Design decisions worth knowing

**Redemption is gated on nothing.** Exiting reads no health state, needs no keeper and no
fresh attestation. It is the one path with no preconditions — deliberately, so a holder can
always leave.

**Minting pays for its own freshness.** An idle protocol used to fund a keeper around the
clock to keep an attestation fresh. Now the attester signs and whoever mints relays that
signature inside their own transaction, so nobody pays to hold an empty room open.

**The dashboard does not invent data.** Figures are read from the chain. Where a series would
need an indexer that does not exist yet, it says so instead of drawing a plausible curve.

## Contracts

Deployed addresses live in `deployments/46630.json` on `backend/contracts-c1` and are
compiled into the front end by `scripts/gen-frontend-abi.py`, whose generated header records
the address book's `sha256` so a reader can check the bundle against the deployment. Eight
contracts are verified on the explorer.

The contracts were audited by an outside reviewer; every critical finding is closed in code,
and the proof-of-concept exploits are kept in the repository as executable evidence rather
than summarised.

## Development

Requires [Bun](https://bun.sh).

```bash
bun install
bun run dev
```

There are deliberately **no lifecycle scripts** (no `postinstall`, no `prepare`) and no CI in
the front-end tree. Both are monitored properties, not oversights.

## Revision history

[CHANGELOG.md](CHANGELOG.md) — dated rather than versioned, because nothing here has shipped
to mainnet yet.

## Licence

[MIT](LICENSE).
