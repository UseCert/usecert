# Switching UseCert to Robinhood Chain mainnet

Everything here was measured on **2026-09-25**, not inferred. Where a value is unknown it says
so rather than carrying the testnet one across.

The short version: **the code is ready to switch; the deployment is not ready to happen.** The
front end takes one generated file and derives its chain, RPC, explorer and every address from
it, so switching is mechanical. What is not mechanical is everything in §4.

---

## 1. What already exists on mainnet

All four are live on chain **4663** and return `0x` on testnet 46630 — which is exactly why
`src/sim/LighterSim.sol` exists at all.

| what | address | verified |
|---|---|---|
| ZkLighter proxy (the venue) | `0x94bab9693ba2f6358507effcbd372b0660afff9d` | 1,367 B of proxy |
| ZkLighter implementation | `0x82DE5B1161C93afDFE21bA0D5343f01Cd7401d90` | 23,168 B |
| USDG | `0x5fc5360d0400a0fd4f2af552add042d716f1d168` | `symbol()` → `USDG`, `decimals()` → 6 |
| Robinhood deposit router | `0x8062df5b3220ad1f528365650a3eb3e8c7b0dad1` | 1,367 B |

USDG's 6 decimals match `COLLATERAL_DECIMALS`, which `CertVault` reads **once** at
construction. Wire the **proxy**, never the implementation: implementations rotate on upgrade.

**`ILighter` is correct against the real contract.** All seven selectors UseCert calls are
present in the deployed implementation, and live view calls decode rather than revert:

```
addressToAccountIndex(address)                    0xabf6a038
deposit(address,uint16,uint8,uint256)             0x8a857083
createOrder(uint48,uint16,uint48,uint32,uint8,uint8)  0x3c40c676
withdraw(uint48,uint16,uint8,uint64)              0xd20191bd
cancelAllOrders(uint48)                           0xa4b6f756
getPendingBalance(address,uint16)                 0xd1cbc64f
withdrawPendingBalance(address,uint16,uint128)    0x2f25807e
```

The ABI is not the risk. `LighterCore` is this project's *model* of the venue's **behaviour** —
async settlement, partial fills, order rejection, margin accounting — and that model has never
met the real engine.

## 2. The market indices, and why every deployed one is wrong

Read from Lighter's live market list (`mainnet.zklighter.elliot.ai/api/v1/orderBookDetails`,
235 active markets):

| mirror | testnet deployed | **mainnet real** | price dec | size dec | min base |
|---|---|---|---|---|---|
| uTSLA | 16 | **112** | 2 | 4 | 0.0150 |
| uSPY | 26 | **128** | 2 | 4 | 0.0070 |
| uQQQ | 27 | **129** | 2 | 4 | 0.0075 |
| uNVDA | 15 | **110** | **3** | **3** | 0.025 |

Two things that cost real money if missed:

* **All four indices are wrong**, including uTSLA and uNVDA, which this repo recorded as
  venue-verified. On `LighterSim`, `setMarkPrice()` creates any index implicitly, so a wrong
  index deploys clean and stays silent. Against the real venue it hedges a different stock.
* **uNVDA's decimals differ from its neighbours** — 3 and 3, not 2 and 4. The testnet book
  carries 2 and 4 for it. `_quantiseToVenue` rounds size by `10 ** sizeDecimals`, so shipping
  4 there quantises every NVDA order to the wrong lot.

`marketIndex` is `immutable` on `CertVault`, so correcting it is a redeploy per mirror.

**SPX also exists, as market 42.** `uSPX` was retired from this project because "the venue has
no SPX perp" — true of the simulator, not of Lighter. Worth revisiting on its own merits.

## 2b. Running the deploy

`script/DeployMainnet.s.sol` is `DeployTestnet` with the six answers that differ. Every phase,
ordering constraint and post-deploy assertion is inherited unchanged.

**Keys.** Three wallets, generated on the operations host and stored in
`/etc/usecert/mainnet-deployer.env`, root-owned `0600`. The private keys have never been in a
terminal, a log or this repository.

| role | address |
|---|---|
| deployer | `0x6381577a72266E6b89eE9E96dF604CC3cd3f8e92` |
| governance | `0x0E315779a25c124B7C94a43E7C57636949ca5ff7` |
| attester | `0x021EeE925f9a7F0e9de1dBB5211D62466404f681` |

The script reads `MAINNET_DEPLOYER_PK` / `MAINNET_GOV_PK` / `MAINNET_ATTESTER_PK`, deliberately
NOT the parent's `DEPLOYER_PK` / `GOV_PK` / `ATTESTER_PK`. Those names are already exported on
this host for the testnet keeper, and inheriting them would let a mainnet deploy run in the
wrong shell pick up testnet keys and broadcast real transactions from them.

**Four answers the script refuses to guess.** Each reverts by name rather than defaulting:

```
MAINNET_SEED_COLLATERAL   real USDG per vault, 6 decimals. Cannot be zero:
                          bootstrap() deposits one unit into the venue, so a
                          vault with an empty balance cannot be bootstrapped.
MAINNET_FEED_<symbol>     a real 8-decimal aggregator per mirror. _readFeed does
                          not bound decimals(), so 8 is a deployment constraint
                          with no runtime check behind it.
_collateralAssetIndex     USDG's asset index at the venue. Testnet used 3, which
                          is LighterSim's own numbering. Edit the override.
_singleSource             whether the feed and the venue mark are economically
                          independent, answered against the real feed. Edit it.
```

**Dry run, in order.** Verified 2026-09-25 — each gate names what is missing:

```bash
sudo bash -c 'set -a; . /etc/usecert/mainnet-deployer.env; set +a
  cd /opt/usecert
  forge script script/DeployMainnet.s.sol:DeployMainnet     --rpc-url https://rpc.mainnet.chain.robinhood.com'
```

With no extra environment it stops at `MAINNET_FEED_uTSLA`; with feeds set it stops at
`singleSource`. Add `--broadcast` only when nothing is left to stop it, and set
`COMMIT=$(git rev-parse HEAD)` so the address book records a real commit.

**One earlier version of this script panicked** with `array out-of-bounds` after
`SolvencyRegistry` deployed, because the phase-1 override skipped pushing one aggregator per
mirror and later phases index that array. It now demands a real feed per mirror instead, which
is both the fix and the thing that was actually missing.

## 3. The mechanical switch

1. Answer the three nulls in `deployments/history/4663.0-plan-before-deploy.json` (history since deployment): `singleSource`,
   `collateralAssetIndex`, and a real 8-decimal price feed per mirror. Each is null because it
   is a decision or a measurement, not a value to copy.
2. Deploy with `COMMIT=$(git rev-parse HEAD)` set, so the address book records a real commit
   rather than a label. Do **not** deploy `TestUSDG`, `TestFaucet` or `LighterSim`: collateral
   is the real USDG and the venue is the real proxy.
3. The script writes `deployments/4663.json`. Record it with `git add -f` — address books are
   git-ignored by default because test runs write convincing fakes.
4. `python scripts/gen-frontend-abi.py --chain 4663` → `frontend/usecert-contracts.mainnet.ts`.
   It **refuses** to emit while any protocol address is null, which is the guard between a typo
   and a UI pointed at nothing.
5. Copy that file over the front end's `src/chain/contracts.ts`. **That is the whole switch.**
   `CHAIN_ID`, `usecertChain`, `isSupportedChain`, the wagmi transports and all 26 addresses
   derive from it; nothing else imports a chain id.
6. Sweep the copy — see below.

### The copy sweep is not optional

Measured across the front-end source: **63 mentions of `46630`, 64 of "testnet", 62 of
`tUSDG`, 82 of "faucet", 21 of "simulated"**. Many are comments, but the user-facing ones
become false the moment step 5 lands: there is no faucet on mainnet, the collateral is USDG not
tUSDG, and the venue is not simulated. Shipping the switch without the sweep turns a site whose
main virtue is not overclaiming into one that does.

## 4. What must be true before any of this is worth doing

Not code. None of it is fixed by the steps above.

* **Validate `LighterCore` against the real engine** with one small real deposit. Cheapest way
  to find out, and it gates everything else.
* **`singleSource`** answered honestly against whatever real feed is wired. On testnet it was
  `false` while both keepers ran on our keys, which made the claim organisational rather than
  economic.
* **`collateralAssetIndex`** read from the venue. Testnet used `3`, which was LighterSim's own
  numbering. `api/v1/assets` and `api/v1/info` both return 403, so this needs another route.
* **Re-audit the signed-attestation path.** It landed after the C1 audit and sits directly on
  the gate that admits minting.
* **`test_A5`** — "margin must be recallable without a queued receipt" — currently fails.
* **Attester key custody.** A plain env file on one VPS is not a mainnet answer.
* **Release provenance.** 0 of 130 commits signed, no tags, no CI.

## 5. Cost

Not the obstacle. Measured deployment gas, deduplicated by creation transaction and with the
testnet-only contracts removed: **32,069,684 gas**. At mainnet's measured 0.0436 gwei that is
**~0.0014 ETH**, or ~0.005 ETH with generous headroom.

Running cost is near zero by construction: the entire current keeper burn is simulating a venue
mainnet provides, attestation is on-demand so an idle protocol pays nothing, and mints pay for
their own freshness. What cannot be costed yet is `rebalance()` frequency and real venue
interaction, because the venue has never been touched.

The binding constraint is working capital in USDG for the buffer float, not ETH for gas.
