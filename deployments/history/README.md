# Earlier mainnet (4663) stacks - history, not current

`deployments/4663.json` is the live stack: stack 4, six keeper-mode vaults governed by the
UseCert 2-of-3 Safe `0x848c…70DF` (uTSLA `0x6330…F4B0` … uMSFT `0xD9cc…489C`). The files here are the address books of the
stacks before it, kept as the record of what those contracts are. None of them is in use.

| file | what it was | why it was replaced |
|---|---|---|
| `4663.1-six-vaults-wrong-market-indices.json` | first mainnet deploy, 2026-09-25 | market indices read from a different exchange (ROADMAP 6.8) |
| `4663.2-six-vaults-onchain-hedging.json` | redeploy with the right indices | on-chain orders are reduce-only; these vaults cannot open a hedge (6.8) |
| `4663.3-one-keeper-mode-utsla.json` | the single keeper-mode vault that proved the design (6.11) | predates `recallMarginUpTo` and `retire()` (6.12, 6.13) |
| `4663.4-six-vaults-keeper-mode-eoa-governance.json` | six keeper-mode vaults on the final code (6.14) | governed by a single EOA; replaced by the Safe-governed stack 4 (6.15) |

Until 2026-09-26 the tracked `4663.json` was still file 1, so the repository described a stack
that was no longer the one the site used. That is fixed: the tracked book is the live one.

It happened again one stack later. Stack 4 went live on 2026-09-26 with its book only on the
France host (`/opt/keeper/book-stack4.json`), and the tracked file stayed on the EOA-governed
stack until the same day, when a regeneration showed every address differing from the site's.
The tracked book is now stack 4, copied from the host with only `commit` recorded.
