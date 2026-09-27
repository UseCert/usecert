# Stack 5 mainnet deploy runbook (Robinhood Chain, 4663)

Stack 5 replaces the live stack 4 (`deployments/4663.json`). It is the code in
`docs/AUDIT-SCOPE-STACK5.md`. **Do not start until the stack-5 audit has signed off** and the owner
decisions at the end of this page have been answered.

Every step below says **who signs**. There are three signers, and they never swap roles:

| Signer | Key / where | Signs |
|---|---|---|
| **Deployer EOA** `0x6381…8e92` | `MAINNET_DEPLOYER_PK`, `/etc/usecert/mainnet-deployer.env` on the **Montréal** host | the deploy (phases 1, 3, 5), the six bootstraps |
| **Attester EOA** | `MAINNET_ATTESTER_PK` (same env file, deploy only); the signer's key on France | one attestation and one mark per vault during the deploy |
| **Governance Safe** 2-of-3 `0x848c…70DF` | the Safe owners, in the Safe app | batch 1, phase A, phase B, openMinting, stack-4 retirement |
| **Settler EOA** (new in stack 5) | `KEEPER_SETTLER_KEY_FILE` on the **France** keeper host | nothing during the deploy; afterwards every keeper-mode `settleMint` |

The settler must be a key of its own: not the attester (H-4), not the deployer, not the Safe. The
deploy refuses otherwise. `MAINNET_GOV_PK` is no longer read by anything: governance is the Safe.

The scripts build and check; they never sign for the Safe. Every Safe batch is written as a Safe
**Transaction Builder** file (Safe app → Apps → Transaction Builder → drag the `.json` in) and as a
MultiSendCallOnly payload (`<name>.multisend.json`: `to`, `operation: 1`, `data`) for
`deploy/bin/usecert-safe-propose`, which queues it for the owners.

**Before each step that moves real money (steps 4, 7, 11, 12, 14), stop and get a go from Chris.**

## Waits at a glance

| Clock | Starts | Length | What it gates |
|---|---|---|---|
| Governance delay | phase A executes (`proposeChange`) | **2 days** | `setSettler`, `setVenueApiKey`, `setVenueMinimums` (phase B) |
| Insurance registration | phase A executes (`registerVault` stamps `registeredAt`) | **16 days** | any InsuranceStaking draw to that vault (`registrationDelay`) |
| Mark age | every signed mark | 300 s | minting (`maxMarkAge`) |
| Attestation age | every attestation | 300 s | capacity (`maxAttestationAgeSec`) |
| Funding relay | every `accrueFunding` | 2 days | `sweepFees` (`FEE_SWEEP_MAX_ACCRUAL_AGE`) |
| Insurance income vesting | each fee arrival synced | 7 days | InsuranceStaking share price |

Minting on a vault is possible only after phase B **and** openMinting for that vault.

## 0. Environment

On the Montréal host, in a checkout of the audited commit (the `/opt/usecert` checkout was archived
on 2026-09-26; re-clone it):

```
git clone https://github.com/UseCert/usecert /opt/usecert && cd /opt/usecert
git checkout <AUDITED_COMMIT>
export COMMIT=$(git rev-parse HEAD)          # the deploy refuses a missing/malformed one on 4663
export RPC=https://rpc.mainnet.chain.robinhood.com
set -a; . /etc/usecert/mainnet-deployer.env; set +a    # MAINNET_DEPLOYER_PK, MAINNET_ATTESTER_PK
```

Environment the scripts read (no secret goes on a command line):

| Variable | Used by | Value |
|---|---|---|
| `MAINNET_GOVERNANCE_SAFE` | all | `0x848c91323f720DEf985adbCC85FA40E3405B70DF` (required) |
| `MAINNET_ATTESTER_ADDR` | batch 1 | the attester's address |
| `MAINNET_FEED_<SYM>` | batch 1, deploy | the six Chainlink aggregators (8 decimals), as stack 4 (`deployments/4663.json` `replayAggregator`) |
| `MAINNET_SAFE_REGISTRY`, `MAINNET_SAFE_ORACLE_<SYM>` | deploy | the addresses batch 1 created |
| `MAINNET_DEPLOYER_PK`, `MAINNET_ATTESTER_PK` | deploy | env file only |
| `MAINNET_SEED_COLLATERAL` | deploy | USDG (6 dp) seeded into EACH vault's buffer, e.g. `1000000` = 1 USDG; bootstrap deposits 1 USDG of it |
| `MAINNET_SETTLER_ADDR` | deploy | the settler's address (required) |
| `MAINNET_OPS_WALLET` | deploy | 5% fee leg; default the deployer |
| `MAINNET_TREASURY_SAFE` | deploy | 5% fee leg; default the governance Safe; must be a contract |
| `MAINNET_ONLY` | deploy, batches | one symbol, or unset for all six |
| `API_KEY_INDEX`, `PUBKEY_<SYM>` | phase A | venue API key slot and each vault's 40-byte public key |
| `MINBASE_<SYM>`, `MINQUOTE_<SYM>` | phase A | venue minimums: `min_base_amount × 10^sizeDecimals`, `min_quote_amount × 1e18` |
| `OPEN_VAULTS`, `OPEN_CAP18` | openMinting | `uTSLA`, a comma list, or `all`; optional lower first cap |
| `STACK5_BOOK`, `STACK4_BOOK` | batches | only after the books are moved at cutover (step 13) |
| `VENUE_AMOUNT_<SYM>` | retireStack4 | a stack-4 vault's venue balance, read off the venue |

## 1. Preflight (nobody signs)

```
deploy/bin/usecert-mainnet-preflight script/DeployMainnet.s.sol   # market ids and decimals vs api.rh.lighter.xyz
forge build --sizes                                               # CertVault under 24,576 B
forge test                                                        # 675 + stack-5 script tests pass; 3 AuditPoC fail by design
```

The asset table is stack 4's, unchanged: uTSLA 16, uSPY 26, uQQQ 25, uNVDA 15, uAAPL 10, uMSFT 14,
all price/size decimals 2/4. Per-asset `absoluteCap18` and the reviewed M-8 ceiling rows are the
stack-4 caps: 90k / 5M / 3.05M / 311k / 500k / 500k (USD, 18 dp). The deployed
`CapacityOracle.maxAbsoluteCap` is the largest row (5M with six assets).

If a later step's simulation fails `S9: basis outside the band`, the table's `seedPx18` (the mark
the attester sets at deploy) is too far from today's feed price: update it in a reviewed commit.

## 2. Batch 1: the Safe creates the registry and the six oracles (**Safe**)

`SolvencyRegistry` and `CertOracle` bind `governance = msg.sender` for ever, so the Safe creates
them (delegatecall to CreateCall through MultiSend 1.4.1). Stack-5 oracles take `maxMarkAge` = 300.

```
forge script script/SafeBatches.s.sol:SafeBatches --sig 'batch1()' --rpc-url $RPC
```

It prints `SAFE_TX_TO` (MultiSend 1.4.1), `operation 1`, the data, and the address each creation
will land at. Queue it with `usecert-safe-propose <MultiSend> <datafile> 1 "stack 5 batch 1"`,
owners sign and execute. Then read each created address back from the execution receipt (not
only from the prediction) and check: code present, `governance()` = Safe, `attester()` = the
attester, `maxMarkAge()` = 300, `stalenessSeconds()` = 93600. Export them:

```
export MAINNET_SAFE_REGISTRY=0x...  MAINNET_SAFE_ORACLE_uTSLA=0x...  (one per symbol)
```

## 3. Deploy dry run (nobody signs)

```
export MAINNET_SETTLER_ADDR=0x...  MAINNET_SEED_COLLATERAL=1000000
forge script script/DeployMainnet.s.sol:DeployMainnet --rpc-url $RPC
```

The dry run simulates everything and runs every §9 read-back, including the stack-5 ones
(fee split order and shares, forwarder bound to the new CertStaking, InsuranceStaking and
CertStaking parameters, M-8 ceiling, nothing yet wired). Bootstrap is not in the script (the venue's
deposit is a Stylus contract forge cannot execute).

The simulation writes `deployments/4663.stack5.json`. It never touches `4663.json`, which stays
the live stack-4 book the front end and health checks read.

## 4. Deploy (**deployer EOA**, **attester EOA**)

Needs `6 × MAINNET_SEED_COLLATERAL` USDG and gas on the deployer.

```
forge script script/DeployMainnet.s.sol:DeployMainnet --rpc-url $RPC --broadcast --slow
```

Deploys CapacityOracle (M-8 ceiling), CertFactory, six CertVaults (each deploys its Certificate and
BufferBook), InsuranceStaking v2 (cooldown 10 d, window 6 d, draw delay 2 d, max draw 30%, deposit
cap 10,000 USDG, registration delay 16 d, registry = CertFactory, governance = Safe), CertStaking v2
(CERT, USDG, 7 d, cap 10,000,000 CERT, minNotify 1 USDG), BuybackForwarder(USDG, CertStaking) and
FeeVault(USDG, [InsuranceStaking, BuybackForwarder, ops wallet, treasury], [7000, 2000, 500, 500]);
seeds each buffer; the attester attests batch 1 and sets one mark per vault.

Commit the book (it is not git-ignored): `git add deployments/4663.stack5.json`.

## 5. Bootstrap (**deployer EOA**) and source verification

```
BOOK=/opt/usecert/deployments/4663.stack5.json deploy/bin/usecert-mainnet-bootstrap
BOOK=/opt/usecert/deployments/4663.stack5.json deploy/bin/usecert-mainnet-verify
```

Each vault must read `bootstrapped=true` and a non-zero `lighterAccountIndex` from the venue.

## 6. Venue inputs for phase A (nobody signs)

On the France keeper host, per vault: `lighter-ops.py genkey KEYFILE <account index> <API_KEY_INDEX>`
→ the public half is `PUBKEY_<SYM>` (the private half never leaves that host). Minimums from
`https://api.rh.lighter.xyz/api/v1/orderBookDetails?market_id=<m>`, as `usecert-keeper-setup` computes
them (`MINBASE = round(min_base_amount × 10^size_decimals)`, `MINQUOTE = min_quote_amount × 1e18`,
$10 today). Phase A refuses a zero MINBASE and minimums the vault would reject.

## 7. Phase A, day 0 (**Safe**)

```
forge script script/SafeBatches.s.sol:SafeBatches --sig 'phaseA()' --rpc-url $RPC
```

Refuses unless every vault is bootstrapped, governed by the Safe, unregistered and unwired.
Writes `deployments/4663.stack5.phaseA.json` (48 calls) and `4663.stack5.phaseA-proposals.json`.
Per vault, in order:

1. `CertFactory.registerVault(vault, certificate)`: starts the **16-day** insurance clock.
2. `setBufferThresholds(...)`: reporting only.
3. `setFeeSink(FeeVault)`, set once.
4. `setInsurancePool(InsuranceStaking)`, set once.
5. `enableKeeperHedging()`, one-way. This is safe now: `absoluteCap18` stays 0 until step 11, so the
   vault cannot accept any mint.
6. `proposeChange(setSettler(SETTLER))`, `proposeChange(setVenueApiKey(API_KEY_INDEX, PUBKEY))`,
   `proposeChange(setVenueMinimums(MINBASE, MINQUOTE))`: starts the **2-day** clock.

To queue it instead of dragging the file into the Transaction Builder:

```
python3 -c 'import json;print(json.load(open("deployments/4663.stack5.phaseA.multisend.json"))["data"])' > /tmp/phaseA.hex
deploy/bin/usecert-safe-propose 0x9641d764fc13c8B624c04430C7356C1C7C8102e2 /tmp/phaseA.hex 1 "stack 5 phase A"
```

The same applies to every later batch (`phaseB`, `open-<list>`, `retire-stack4`).

The proposals file records each proposal's exact calldata and id (`keccak256(calldata)`, the key of
`changeReadyAt`). Commit it: phase B applies those bytes. Do not rebuild phase A between building and
executing it. If you do, the file changes and phase B will refuse the executed proposals as not on
chain. That fails closed.

After execution, check each vault: `feeSink`, `insurancePool`, `keeperHedging`,
`CertFactory.registeredAt(vault)` = the execution time, and for every recorded id
`changeReadyAt(id)` = execution time + 172800. Anyone can decode the pending changes from the
`ChangeProposed` events. That is the point of the delay.

## 8. During the wait (France keeper host)

- Signer in stack-5 mode (`STACK=5`): v2 marks (`observedAt`, 60 s validity), attestations as
  `latest + 1` (the deploy attested batch 1).
- Funding relay (`usecert-funding-relay`): hourly `accrueFunding`. Fees cannot be swept without it.
- Keeper with the settler key: `STACK=5`, `KEEPER_SETTLER_KEY_FILE`. At start it checks the key
  against `settler()`. It will fail until phase B lands, which is expected.

## 9. Phase B, day ≥ 2 (**Safe**)

```
forge script script/SafeBatches.s.sol:SafeBatches --sig 'phaseB()' --rpc-url $RPC
```

Reads the proposals file and applies exactly those calldata (18 calls). It refuses unless
phase A's immediate calls are on chain and every recorded proposal is on chain (`changeReadyAt`
non-zero, so not applied or cancelled) and ready (`changeReadyAt` ≤ now). Built early, it reverts
`SafeBatches_PhaseBTooEarly(symbol, setter, readyAt, now)`.

After execution: `settler()` = the settler, `venueMinBase()`/`venueMinNotional18()` = the minimums,
and the venue lists the API key on each vault's account. Restart the keeper; its settler check
must pass.

## 10. Prove one vault before six (**nobody**, then **Safe**)

Every vault is deployed and wired. None can mint. Open **one**.

## 11. Open uTSLA only (**Safe**), then one small real round trip

```
OPEN_VAULTS=uTSLA OPEN_CAP18=1000000000000000000000 \
  forge script script/SafeBatches.s.sol:SafeBatches --sig 'openMinting()' --rpc-url $RPC
```

This is one `CapacityOracle.setAbsoluteCap`, here a $1,000 first cap (without `OPEN_CAP18` it is
the table's $90k). It refuses a vault where phase B is not visible on chain (`settler`, venue
minimums) or phase A is missing, and any cap above the asset's reviewed row.

The round trip, about $20. It must clear the venue's $10 minimum and 0.015 TSLA:

1. `requestMint` from a test wallet. The keeper sees `HedgeRequested` and opens the hedge off chain
   with the vault's API key.
2. On the **venue's own API**, the vault's account shows the position. Only then does the settler
   `settleMint`, and the test wallet holds the certificates.
3. `requestRedeem`. The close goes out on chain (reduce-only); `claimRedeem` pays out.
4. The venue's API shows the position flat, and the USDG is back in the test wallet, net of fees.

Judge success by the venue's records, never by the vault's own ledger. If any step fails, stop:
the other five stay closed and nothing further is at risk.

## 12. Open the other five (**Safe**)

```
OPEN_VAULTS=uSPY,uQQQ,uNVDA,uAAPL,uMSFT forge script script/SafeBatches.s.sol:SafeBatches --sig 'openMinting()' --rpc-url $RPC
OPEN_VAULTS=uTSLA forge script script/SafeBatches.s.sol:SafeBatches --sig 'openMinting()' --rpc-url $RPC   # uTSLA to its $90k row
```

## 13. Cutover (repo, front end)

1. Move stack 4's book to history: `git mv deployments/4663.json deployments/history/4663.5-stack4-six-vaults-safe-governed.json`,
   then add a row to `deployments/history/README.md`.
2. Promote stack 5's: `git mv deployments/4663.stack5.json deployments/4663.json`. It keeps every
   field the front end and health checks read (`vaults[].vault/certificate/certOracle/bufferBook/replayAggregator`,
   `shared.*`, the real `stalenessSeconds` 93600), plus `"stack": 5` and the new
   `shared.feeVault/buybackForwarder/insuranceStaking/certStaking/settler/cert/opsWallet/treasury`.
3. Copy the book to the France host. Its health check compares the host's books with GitHub.
4. From here the batch builders need `STACK5_BOOK=deployments/4663.json` and
   `STACK4_BOOK=deployments/history/4663.5-...json`.

## 14. Stack-4 wind-down

**Vaults.** The stack-4 vaults are empty today. Once stack 5 is live and the front end no longer
offers stack 4 (**Safe**):

```
STACK4_BOOK=... forge script script/SafeBatches.s.sol:SafeBatches --sig 'retireStack4()' --rpc-url $RPC
```

This builds `retire()` and `sweepRetired(VENUE_AMOUNT_<SYM>)` per vault. It refuses any vault with
certificates, open mint receipts, owed claims or a hedge position, exactly as `retire()` would. With
`VENUE_AMOUNT_<SYM>` = the account's balance read off the venue, the sweep requests that withdrawal.
A withdrawal lands in the vault, so run the batch again with 0 once it arrives: an already-retired
vault gets only the sweep. Capital goes to the Safe.

**InsuranceStaking v1** (`0xDbdA…dAFb1`) and **CertStaking v1** (`0x6491…0Ae`) are immutable and are
not migrated. Holders exit themselves. The Safe proposes no further v1 draws. Nothing routes income
to them, since stack-4 vaults have no fee sink. v1 stakers `requestWithdraw`, wait the 10-day
cooldown and redeem in the 3-day window. CERT stakers `withdraw` and `getReward`. The front end
shows v1 as "winding down, exit only" and points new deposits at v2. The open 1-USDG v1 proof
withdrawal (window from 2026-10-06 15:18 UTC) is unaffected.

## Owner decisions still open

1. **M-8 ceiling is shared.** `CapacityOracle` has one `maxAbsoluteCap` for all vaults, and
   `CertFactory` one `capacity`, so the deployed ceiling is the largest reviewed row (uSPY's $5M).
   The per-asset rows are enforced by the scripts, not the chain. The Safe could later raise uTSLA
   from $90k up to $5M without a redeploy. A true per-asset immutable bound needs a contract change
   (per-asset ceilings in CapacityOracle) or one CapacityOracle and CertFactory per vault. Accept,
   or deploy with `MAINNET_ONLY` per vault.
2. **Cap values.** The rows are stack 4's caps (10% of venue open interest on 2026-09-25). Re-measure
   before deploy if they should track today's venue.
3. **InsuranceStaking v2 token name/symbol**: "UseCert Insurance Pool v2" / `ucINS2`, chosen so it
   cannot be confused with v1's `ucINS`.
4. **Ops wallet = deployer.** 5% of fees lands on the hot key that signs deploys. Set
   `MAINNET_OPS_WALLET` to a separate address if that is not wanted. FeeVault is immutable.
