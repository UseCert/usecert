# Earlier mainnet (4663) stacks - history, not current

`deployments/4663.json` is the live stack: six keeper-mode vaults deployed 2026-09-26
(uTSLA `0x6b47…56f0` … uMSFT `0xa6f8…F4b7`). The files here are the address books of the
stacks before it, kept as the record of what those contracts are. None of them is in use.

| file | what it was | why it was replaced |
|---|---|---|
| `4663.1-six-vaults-wrong-market-indices.json` | first mainnet deploy, 2026-09-25 | market indices read from a different exchange (ROADMAP 6.8) |
| `4663.2-six-vaults-onchain-hedging.json` | redeploy with the right indices | on-chain orders are reduce-only; these vaults cannot open a hedge (6.8) |
| `4663.3-one-keeper-mode-utsla.json` | the single keeper-mode vault that proved the design (6.11) | predates `recallMarginUpTo` and `retire()` (6.12, 6.13) |

Until 2026-09-26 the tracked `4663.json` was still file 1, so the repository described a stack
that was no longer the one the site used. That is fixed: the tracked book is the live one.
