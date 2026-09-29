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

## Cutover kit: Monday (deployed) to Thursday (live)

Steps 5 to 13 are run with one tool, `deploy/bin/usecert-s5-cutover`. Each subcommand names its
host and refuses to run anywhere else. Each is idempotent: run it again and it changes nothing.
Faced with state it does not expect, it refuses (exit 2) and says what it saw. It never prints a
private key. The kit sends only two kinds of transaction, both from Montréal: the six bootstraps
(inside `usecert-mainnet-bootstrap`) and `execTransaction`. Nothing else it does touches the chain.

Every subcommand takes `--dry-run`: all reads and checks, no transaction, no `systemctl`, and no
file written outside `--workdir`. Run it before the real command. `--offline` (implies `--dry-run`)
runs anywhere, with no network, against a simulated chain kept in `<workdir>/sim-chain.json`:
`deploy/tests/test_s5_cutover.py` runs the whole sequence below that way.

**Where the kit runs.**

- **Montréal:** the checkout in `/opt/usecert`, as user `usecert`. It holds the kit's commit, and
  `git diff <book commit> HEAD -- src script` must be empty. The phase builders refuse otherwise.
- **France:** a copy of `deploy/` from the same commit, shipped with LF line endings. The kit
  refuses a CRLF copy of itself:
  ```
  git -c core.autocrlf=false archive --format=tar HEAD deploy | ssh usecert-keeper \
    'sudo mkdir -p /opt/keeper/s5-kit /opt/keeper/s5 && sudo tar -x -C /opt/keeper/s5-kit && sudo chown -R keeper:keeper /opt/keeper/s5-kit /opt/keeper/s5'
  K=/opt/keeper/s5-kit/deploy/bin/usecert-s5-cutover     # below: "France$ $K ..."
  ```
- **Workstation:** this contracts checkout, for `site-build` only.

On Montréal, `K=/opt/usecert/deploy/bin/usecert-s5-cutover`.

**Who signs what.** The kit never signs for the Safe. It builds the Safe batches (with forge,
without broadcasting) and a signing page for them. It verifies the owners' signatures, runs the
transaction on a fork, and only then sends `execTransaction`. The deployer pays the gas.
`execTransaction` needs 2 of the 3 owner signatures. The deployer's own signature counts for
nothing.

| Step | Host | Command | Signs / sends |
|---|---|---|---|
| bootstrap | Montréal | `$K bootstrap` | deployer: six `bootstrap()` |
| venue keys | France (keeper) | `$K genkeys` | nothing; keys generated on France |
| phase A build | Montréal | `$K phase-a` | nothing |
| phase A | owners, then Montréal | the signing page; `$K exec-safe` | 2 owners (EIP-712); deployer sends |
| keeper, signer prep | France (root) | `$K keeper-configs`; `$K signer-cutover` | nothing |
| phase B build | Montréal | `$K phase-b` | nothing |
| phase B | owners, then Montréal | the signing page; `$K exec-safe` | 2 owners; deployer sends |
| keepers, relay | France (root) | `$K keeper-configs --start`; `$K funding-relay --enable` | the relay's attester key signs `accrueFunding` hourly |
| open uTSLA | owners, then Montréal | `$K open --vaults uTSLA ...`; `$K exec-safe` | 2 owners; deployer sends |
| site | workstation, then France | `$K site-build`; `usecert-deploy-web`; `$K signer-cutover --switch` | nothing |

### Monday, day 0

**M1. Bootstrap, then verify** (Montréal, **deployer**; money: 1 USDG per vault leaves each buffer).

```
Montréal$ $K bootstrap --dry-run && $K bootstrap
Montréal$ BOOK=/opt/usecert/deployments/4663.stack5.json deploy/bin/usecert-mainnet-verify
```

The kit hands only the vaults that are not yet bootstrapped to `usecert-mainnet-bootstrap`, as a
filtered copy of the book (`/opt/usecert-s5/bootstrap-pending.json`, run through `sudo -n`). Then
it reads back what the venue registered. It writes `/opt/usecert-s5/accounts.json`
(`{"uTSLA": <accountIndex>, ...}`) only if every vault reads `bootstrapped()` true and a non-zero,
distinct `lighterAccountIndex()`. An existing, different `accounts.json` is refused.

*Check:* `cast call <vault> 'lighterAccountIndex()(uint256)'` for one vault equals its entry.

**M2. Venue API keys** (France, as `keeper`; nobody signs).

```
workstation$ scp montreal:/opt/usecert-s5/accounts.json montreal:/opt/usecert/deployments/4663.stack5.json usecert-keeper:/tmp/
France$ sudo -u keeper cp /tmp/accounts.json /tmp/4663.stack5.json /opt/keeper/s5/
France$ sudo -u keeper $K genkeys --dry-run && sudo -u keeper $K genkeys      # API_KEY_INDEX=3 unless --api-key-index
```

This runs `lighter-ops.py genkey /opt/keeper/keys/s5-<sym>-key.json <account> 3` for each vault
that has no key file yet. The file is created O_EXCL, mode 600. An existing key file must be for
the same account and key index, with no group or other permissions. The kit reads only its
`public` field. It writes `/opt/keeper/s5/pubkeys.env`: `API_KEY_INDEX=3` and one `PUBKEY_<SYM>=0x…`
(40 bytes) per vault. It refuses two equal keys. A dry run's file starts with
`# DRY RUN - NOT REAL KEYS`, and the real `phase-a` refuses that file.

*Check:* `grep -ci private /opt/keeper/s5/pubkeys.env` prints `1` (the comment line only).

**M3. Phase A build and signing page** (Montréal; nobody signs yet).

```
workstation$ scp usecert-keeper:/opt/keeper/s5/pubkeys.env montreal:/opt/usecert-s5/pubkeys.env
Montréal$ $K phase-a --dry-run && $K phase-a
```

1. Reads the venue minimums from `api.rh.lighter.xyz/api/v1/orderBookDetails?market_id=<m>`:
   `MINBASE = min_base_amount × 10^size_decimals` and `MINQUOTE = min_quote_amount × 1e18`. This is
   `usecert-keeper-setup`'s arithmetic, done in exact decimals. The kit refuses the row if its
   `market_id` or `size_decimals` differ from the book, if it is not active, or if a value does not
   convert to a whole number.
2. Runs `SafeBatches phaseA()` (build only) with `MAINNET_GOVERNANCE_SAFE`, `MAINNET_SETTLER_ADDR`,
   `API_KEY_INDEX`, `PUBKEY_*`, `MINBASE_*`, `MINQUOTE_*` (and `MAINNET_ONLY` for a one-vault book).
   A refusal from the script is shown as the script's own message.
3. Decodes the MultiSend payload and checks it call by call against what was meant. It must be 8
   calls per vault, in SafeBatches' order: `registerVault(vault, certificate)`, then
   `setBufferThresholds`, `setFeeSink(FeeVault)`, `setInsurancePool(InsuranceStaking)`,
   `enableKeeperHedging()`, then the three `proposeChange` for `setSettler(settler)`,
   `setVenueApiKey(3, PUBKEY)` and `setVenueMinimums(MINBASE, MINQUOTE)`. The proposals file must
   list the same bytes, each with id = keccak256(data). The Transaction Builder file must agree
   with the payload.
4. Writes `/opt/usecert-s5/phaseA/`: `index.html`, one `phaseA-<k>of<n>.hex` per part,
   `phaseA.txbuilder.json`, `phaseA.multisend.json`, `phaseA-proposals.json`, `manifest.json`.
   A payload over 120,000 hex characters is split at call boundaries into consecutive batches at
   consecutive nonces, with one Sign button each (Linux `MAX_ARG_STRLEN` is 128 KiB per argument).
   Phase A is about 18,000 characters, so it is one batch.
5. Prints `SAFE_TX_HASH <part> nonce <n> 0x…` for each part. The Safe computes it
   (`getTransactionHash`), and the kit refuses if its own EIP-712 computation differs. The nonce
   is the Safe's next. The kit refuses a clash with a transaction queued on the Safe transaction
   service, unless `--nonce` is given.

Commit `deployments/4663.stack5.phaseA-proposals.json`. Phase B applies it byte for byte. Running
`phase-a` again with the same inputs keeps that file byte-identical and reports "already this
batch". With other inputs it refuses, unless `--rebuild` is given, and `--rebuild` voids any
signatures already collected.

**M4. Owners sign phase A** (**2 of 3 owners**).

Serve `/opt/usecert-s5/phaseA/` to the owners (the same way as the batch-1 pages). Each owner
connects a wallet, picked with EIP-6963, and signs each part with `eth_signTypedData_v4`. The
domain is `{chainId: 4663, verifyingContract: Safe}`, the call is operation 1 (delegatecall) to
MultiSendCallOnly 1.4.1, and the nonce is the one shown. The page refuses a wallet on another
chain, an account that is not an owner, and an owner list that no longer matches the Safe's
`getOwners()` read through the wallet. The copy box holds lines like
`phaseA-1of1 nonce 5 owner 0x… signature 0x…`. Put every owner's lines in
`/opt/usecert-s5/phaseA/sigs.txt`.

**M5. Execute phase A** (Montréal, **deployer** sends; **go from Chris**).

```
Montréal$ $K exec-safe --batch /opt/usecert-s5/phaseA/phaseA-1of1.hex --nonce 5 --sigs /opt/usecert-s5/phaseA/sigs.txt --dry-run
Montréal$ $K exec-safe --batch /opt/usecert-s5/phaseA/phaseA-1of1.hex --nonce 5 --sigs /opt/usecert-s5/phaseA/sigs.txt
```

In order, the kit:

1. Checks that the manifest's owners and threshold are still the Safe's, and that the Safe's
   nonce is exactly this batch's. A higher nonce means the batch was used: it runs the read-back
   and exits 0 ("already executed").
2. Recomputes the safeTxHash on chain and requires it to equal the page's.
3. Recovers each signature with the ecrecover precompile (by `eth_call`) and requires it to
   recover to the owner it claims. It orders the signatures by owner address, ascending, and runs
   the Safe's `checkSignatures`.
4. Starts `anvil --fork-url $RPC --hardfork shanghai --auto-impersonate` and sends
   `execTransaction` there from the deployer. It requires status 1, the Safe's `ExecutionSuccess`
   carrying this hash, and the full read-back on the fork.
5. Only then, and only without `--dry-run`, sends `execTransaction` to chain 4663 from the
   deployer, and reads back again on chain.

The phase A read-back is 54 checks for six vaults: `isVault` and `registeredAt(vault)` = the
execution block's timestamp, `feeSink()` = FeeVault, `insurancePool()` = InsuranceStaking,
`keeperHedging()` = true, and for each of the 18 recorded proposals
`changeReadyAt(id)` = timestamp + 172800. It prints the time phase B becomes possible.

**M6. France prep** (France, root; nobody signs).

```
France$ sudo $K keeper-configs --book /opt/keeper/s5/4663.stack5.json --dry-run
France$ sudo $K keeper-configs --book /opt/keeper/s5/4663.stack5.json
France$ sudo $K signer-cutover --book /opt/keeper/s5/4663.stack5.json --dry-run
```

`keeper-configs` writes `/opt/keeper/vaults/s5-<sym>.json` for each vault:

- from the book: vault, oracle, market, decimals;
- from the running `s4-uTSLA.json`: `rpc`, `api` (refused unless it is `https://api.rh.lighter.xyz`),
  `cast`, `fill_timeout_sec`, `auto_recall`;
- `start_block`: the vault's deploy block. It is found by binary search on `eth_getCode` and
  accepted only if the deployer sent a transaction in that block. Otherwise the book's
  `blockNumber` is used, which is a lower bound;
- `funding_start_ts`: that block's timestamp;
- `state_file /opt/keeper/state-s5-<sym>.json`, `api_key_file /opt/keeper/keys/s5-<sym>-key.json`
  (it must exist, and its account must be the vault's `lighterAccountIndex()`), `stack 5`,
  `settler_key_file /opt/keeper/keys/s5-settler.key` (mode 600), `auto_rehedge false`.

It also writes:

- `/opt/keeper/book-stack5.json`;
- `/opt/keeper/usecert-keeper-s5.py`, the stack-5 keeper. The stack-4 keepers keep running
  `/opt/keeper/usecert-keeper.py`, untouched;
- per instance, `/etc/systemd/system/usecert-keeper@s5-<sym>.service.d/{50-stack5-settler,60-stack5-code}.conf`.

It does not start anything. It refuses an existing config that differs, a state file without a
config, and `/etc/usecert-keeper/settler.env` (two sources for the settler key).

`signer-cutover` with no flag changes nothing. It checks that the stack-5 oracles' `attester()` is
the stack-4 attester, whose key is in `attester.env`, and that the live unit runs
`book-stack4.json`. It installs `/opt/keeper/usecert-signer-mainnet-s5.py`. Then it runs the
stack-5 signer once beside the live one (`systemd-run --uid=keeper -p EnvironmentFile=attester.env
... --once`). The result must be v2 marks for all six stack-5 oracles, with nothing refused.

### Wednesday, day ≥ 2 (after the time M5 printed)

**W1. Phase B** (Montréal, then **2 of 3 owners**, then **deployer**; **go from Chris**).

```
Montréal$ $K phase-b --dry-run && $K phase-b
    (owners sign /opt/usecert-s5/phaseB/index.html -> /opt/usecert-s5/phaseB/sigs.txt)
Montréal$ $K exec-safe --batch /opt/usecert-s5/phaseB/phaseB-1of1.hex --nonce 6 --sigs /opt/usecert-s5/phaseB/sigs.txt --dry-run
Montréal$ $K exec-safe --batch /opt/usecert-s5/phaseB/phaseB-1of1.hex --nonce 6 --sigs /opt/usecert-s5/phaseB/sigs.txt
```

Before the notice has run, `phase-b` shows SafeBatches' own refusal,
`SafeBatches_PhaseBTooEarly(symbol, setter, readyAt, now)`, with `readyAt` as a UTC time. It also
refuses if `deployments/4663.stack5.phaseA-proposals.json` is not the file in
`/opt/usecert-s5/phaseA/`. The batch must be exactly the 18 recorded proposals, in order, byte for
byte.

The read-back (36 checks) requires that each apply's `changeReadyAt` is consumed (0),
`settler()` is the settler, and `venueMinBase()` and `venueMinNotional18()` are the proposed
minimums.

**W2. Keepers and funding relay** (France, root).

```
France$ sudo $K keeper-configs --book /opt/keeper/s5/4663.stack5.json --start
France$ sudo $K funding-relay --dry-run && sudo $K funding-relay
France$ sudo $K funding-relay --enable
```

`--start` requires three things for every vault before it enables and starts
`usecert-keeper@s5-<sym>`:

- `settler()` = the book's settler = the address `s5-settler.key` derives
  (`0x29f975357cc98A4F4e7E4460440380AB3136d500`);
- keeper hedging on and venue minimums set;
- the venue accepts the vault's API key: `lighter-ops.py check` prints `OK`.

After 20 s, each unit must be active with no restarts. `funding-relay` installs the unit, the timer
and the drop-in `usecert-funding-relay.service.d/50-stack5.conf`, which relays only
`/opt/keeper/vaults/s5-*.json`, with state in `/opt/keeper/funding-relay-state-s5.json`. It
installs `/opt/keeper/usecert-funding-relay`. Then it runs one `--dry-run` pass as `keeper`, which
must cover exactly the six vaults with nothing refused. Before phase B the venue refuses the auth
token, so this step belongs here and not on Monday. `--enable` turns the hourly timer on. The
relay must run at least every 2 days, or `sweepFees` stops.

### Thursday: open one, go live, prove one

**T1. Open uTSLA with a $1,000 cap** (**2 of 3 owners**, **deployer**; **go from Chris**: from here uTSLA can take money).

```
Montréal$ $K open --vaults uTSLA --cap18 1000000000000000000000
    (owners sign /opt/usecert-s5/open-uTSLA/index.html)
Montréal$ $K exec-safe --batch /opt/usecert-s5/open-uTSLA/open-uTSLA-1of1.hex --nonce 7 --sigs /opt/usecert-s5/open-uTSLA/sigs.txt
```

*Read-back:* `CapacityOracle.absoluteCap18(uTSLA vault)` = 1000e18.

**T2. Site build** (workstation, then France).

```
workstation$ git fetch origin && python deploy/bin/usecert-s5-cutover site-build --dry-run
workstation$ python deploy/bin/usecert-s5-cutover site-build
```

It needs `deployments/4663.stack5.json` (the committed book) and `src/` equal to the book's
`commit`. It refuses otherwise, because the ABIs would not be the deployed ones. It runs
`forge build`, then:

1. `git -c core.autocrlf=false archive origin/frontend/total-return` into a staging tree. That
   branch carries the approved option-A copy, and its `src/chain/contracts.ts` is today's stack-4
   bundle.
2. `scripts/gen-frontend-abi.py --chain 4663 --book 4663.stack5.json` writes
   `frontend/usecert-contracts.mainnet.ts` in the contracts repo. It carries the stack-5 addresses,
   the ABIs and `CHAIN.stack = 5`, which is what turns `IS_STACK5` on in `src/chain/deployment.ts`.
3. `scripts/gen-stack5-abi.py <contracts> <staging>` writes `src/chain/contracts.stack5.ts`, the
   stack-5 ABIs plus the pinned stack-4 mark relay. It must run while `src/chain/contracts.ts` is
   still the stack-4 bundle: it reads that bundle's `setMarkPriceSigned` and asserts 4 inputs.
4. The kit copies step 2's file over `src/chain/contracts.ts`.

Those two files are the only ones changed. The kit refuses a `contracts.ts` without
`id: 4663`, `stack: 5` and every vault's addresses, and any text file with CRLF. It writes
`../s5-site-build/usecert-web-stack5-<branch commit>-book<sha>.tar` (sorted members, fixed mtimes),
`.tar.sha256`, and `.MANIFEST.txt` with the git blob id of each generated file.

```
workstation$ scp ../s5-site-build/usecert-web-stack5-*.tar* usecert-keeper:/tmp/
France$ cd /tmp && sha256sum -c usecert-web-stack5-*.tar.sha256
France$ sudo rm -rf /opt/usecert-web-s5-src && sudo mkdir /opt/usecert-web-s5-src && sudo tar -x -C /opt/usecert-web-s5-src -f /tmp/usecert-web-stack5-*.tar
France$ grep -rlI $'\r' /opt/usecert-web-s5-src | wc -l        # 0
```

**T3. Site cutover** (France, root; **go from Chris**).

```
France$ sudo rsync -a --delete --exclude node_modules --exclude .output --exclude .output.prev /opt/usecert-web-s5-src/ /opt/usecert-web/
France$ sudo chown -R usecert:usecert /opt/usecert-web && (cd /opt/usecert-web && sudo -u usecert /home/usecert/.bun/bin/bun install --frozen-lockfile)
France$ sudo /usr/local/bin/usecert-deploy-web          # builds, refuses an unbootable bundle, rolls back a site that does not serve
France$ sudo $K signer-cutover --switch
```

`--switch` installs `usecert-signer-mainnet.service.d/50-stack5.conf` and restarts the signer. The
drop-in sets `STACK=5`, `MARK_SIG_VERSION=2`, `OI_SOURCE=venue`, `SANITY_CHECKS=1` and
`MULTIPLIER_CHECKS=1`, with ExecStart pointing at the `-s5` copy and `book-stack5.json`. The kit
then requires `127.0.0.1:8787/attestations` and `https://use-cert.com/api/attestations` to serve
v2 marks (`markSigVersion` 2, deadline ≤ observedAt + 60) for exactly the six stack-5 oracles,
with nothing refused. If either does not, it removes the drop-in itself and checks that stack 4
serves again. Rollback at any time, one command:

```
France$ sudo $K signer-cutover --rollback        # removes the drop-in; checks 8787 serves the stack-4 oracles again
```

Then step 11's round trip on uTSLA. Then the repo side of step 13: move the books, copy
`book-stack5.json` to its new name in the France health check, and commit the two generated
front-end files to the published front-end branch, so that the release manifest matches GitHub.

## 5. Bootstrap (**deployer EOA**) and source verification

Kit: `usecert-s5-cutover bootstrap` (Monday, M1 above).

```
BOOK=/opt/usecert/deployments/4663.stack5.json deploy/bin/usecert-mainnet-bootstrap
BOOK=/opt/usecert/deployments/4663.stack5.json deploy/bin/usecert-mainnet-verify
```

Each vault must read `bootstrapped=true` and a non-zero `lighterAccountIndex` from the venue.

## 6. Venue inputs for phase A (nobody signs)

Kit: `usecert-s5-cutover genkeys` on France; `phase-a` reads the minimums (M2, M3 above).

On the France keeper host, per vault: `lighter-ops.py genkey KEYFILE <account index> <API_KEY_INDEX>`
→ the public half is `PUBKEY_<SYM>` (the private half never leaves that host). Minimums from
`https://api.rh.lighter.xyz/api/v1/orderBookDetails?market_id=<m>`, as `usecert-keeper-setup` computes
them (`MINBASE = round(min_base_amount × 10^size_decimals)`, `MINQUOTE = min_quote_amount × 1e18`,
$10 today). Phase A refuses a zero MINBASE and minimums the vault would reject.

## 7. Phase A, day 0 (**Safe**)

Kit: `usecert-s5-cutover phase-a`, the signing page, then `exec-safe` (M3 to M5 above).

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

With the kit (M6, W2, T3 above), the order is:

- **Signer.** Checked during the wait (`signer-cutover`: one stack-5 `--once` run beside the live
  signer). It is switched only at site cutover (`--switch`). Port 8787 serves one stack, and the
  stack-4 site reads it until the new site is live. Stack 5 then serves v2 marks (`observedAt`,
  60 s validity) and attestations as `latest + 1` (the deploy attested batch 1).
- **Keepers.** Configured and installed during the wait (`keeper-configs`), and started after
  phase B (`--start`). A stack-5 keeper checks its key against `settler()` at start, and that
  check fails until phase B lands.
- **Funding relay** (hourly `accrueFunding`; fees cannot be swept without it). Installed after
  phase B (`funding-relay`, then `--enable`). Before phase B the venue refuses the auth token made
  with the vault's key, and no vault can hold a position before openMinting anyway.

## 9. Phase B, day ≥ 2 (**Safe**)

Kit: `usecert-s5-cutover phase-b`, then `exec-safe` (W1 above).

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

Kit: `usecert-s5-cutover open --vaults uTSLA --cap18 1000000000000000000000`, then `exec-safe` (T1 above).

```
OPEN_VAULTS=uTSLA OPEN_CAP18=1000000000000000000000 \
  forge script script/SafeBatches.s.sol:SafeBatches --sig 'openMinting()' --rpc-url $RPC
```

This is one `CapacityOracle.setAbsoluteCap`, here a $1,000 first cap (without `OPEN_CAP18` it is
the table's $90k). It refuses a vault where phase B is not visible on chain (`settler`, venue
minimums) or phase A is missing, and any cap above the asset's reviewed row.

The round trip, about $20. It must clear the venue's $10 minimum and its minimum size (0.0200 TSLA on 2026-09-27; `phase-a` prints the day's):

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

Kit: `usecert-s5-cutover site-build`, `usecert-deploy-web`, then `signer-cutover --switch` (T2, T3 above).

1. Move stack 4's book to history: `git mv deployments/4663.json deployments/history/4663.5-stack4-six-vaults-safe-governed.json`,
   then add a row to `deployments/history/README.md`.
2. Promote stack 5's: `git mv deployments/4663.stack5.json deployments/4663.json`. It keeps every
   field the front end and health checks read (`vaults[].vault/certificate/certOracle/bufferBook/replayAggregator`,
   `shared.*`, the real `stalenessSeconds` 93600), plus `"stack": 5` and the new
   `shared.feeVault/buybackForwarder/insuranceStaking/certStaking/settler/cert/opsWallet/treasury`.
3. Copy the book to the France host. Its health check compares the host's books with GitHub.
4. From here the batch builders need `STACK5_BOOK=deployments/4663.json` and
   `STACK4_BOOK=deployments/history/4663.5-...json`.

- **Audit copy at cutover.** Once the site runs stack 5, "the insurance pool" means InsuranceStaking v2. The shared pages that call it *unaudited* (RiskView's junior-tranche lines, Faq, learn/data.ts, RolesAccordion, TokenFlow) must then say it is audited by Sermium (28 Sep 2026), with Chinese entries; the v1 labels (StakeView, CertStakePanel, the Contracts page's v1 rows) stay *unaudited*. The v2 panels already say so.

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
5. **Order on Thursday.** The signer on 8787 moves to stack 5 at site cutover, not before, because
   the live site reads it. A stack-5 mint needs a v2 mark signed within `maxMarkAge` (300 s), and
   until T3 no such mark is published. So uTSLA, though open on chain from T1, cannot actually be
   minted until T3, and the step-11 round trip can only run after T3, with the new site public and
   uTSLA open to anyone up to the $1,000 cap. Accept this, or add a tool that relays a mark from a
   signer `--once` bundle so the round trip can run before T3.
6. **`auto_recall` for the stack-5 keepers** is copied from `s4-uTSLA.json`. Stack 5 caps recalls
   at the attested margin. Confirm that the stack-4 value is wanted.

## Insurance draws: when the Safe may propose one

`proposeDraw` checks eligibility and the cap but not that the vault reports a shortfall, and every
proposal pauses deposits and exits for 5 days (2-day delay + 3-day execution window), executable or
not (staking v2 review L-03). So:

- Propose only against a vault whose `insuranceShortfall()` is non-zero, confirmed after a fresh
  attestation, and for no more than that figure. The health job alerts the moment one appears.
- Once executable, execute it from our side straight away rather than leaving the timing to anyone
  (`executeDraw` is permissionless and pays min(proposal, shortfall at that moment)).
- A proposal that turns out not to be payable (no shortfall at execution, or the vault's
  `receiveInsurance` reverts) is cancelled at once, so exits do not stay paused for nothing.

## Key separation (Sermium M-03)

France keeps the six venue API keys: orders must be placed from a location the venue permits, and
Montreal (Canada) is not one. The settler and, next, the attester move to Montreal, which only
reads the venue's public data and sends chain transactions.

**Settler (staged 2026-09-28, switched on after the first uTSLA round trip):**
- Montreal: `usecert-settler-remote serve` (unit `usecert-settler-remote`, user `usecert`) holds
  the key (`/etc/usecert/settler-remote.env`, root 600, derives 0x29f9…d500). Before `settleMint`
  it reads the receipt from chain and the vault's position from the venue's public account
  endpoint, and refuses unless the position covers every certificate after the settle; plus the
  settle band, a daily budget and a rate limit. Log: `/var/log/usecert-settler-remote.log`.
- The link: France's `keeper` key `/opt/keeper/keys/settle_ed25519` may run only
  `usecert-settler-remote intake` as `settle-intake` on Montreal, only from France's IP; the host
  key is pinned in `/opt/keeper/keys/settle_known_hosts`.
- Switch: `sudo usecert-s5-settler-switch --check`, then `--apply` (rewrites the six keeper configs,
  backups `*.local-settler`, restarts running keepers, confirms "settler: remote"); `--rollback`
  restores. Then, with the owner's go, delete `/opt/keeper/keys/s5-settler.key` on France.

**Attester (rotation built 2026-09-29):** stack 5 gets its own attester 0x1e65…Ba5e, generated on
Montreal (`/etc/usecert/attester-s5.env`, root 600) and never present on France; stack 4 keeps
0x021E…f681 on France until its wind-down. `rotate-attester --to 0x1e655E90A873bdCFcbf051B2aCB4C1588c30Ba5e`
built the Safe batch at nonce 8 (Safe tx 0x54004e12…3e65: proposeAttester on the registry and the six
oracles); after its 2-day notice, `accept-attester` finishes it (permissionless). The stack-5 signer then
runs on Montreal from a copy of the book whose `senders.attester` is the new address (it refuses a key
the chain does not name). Before accepting: move the signer to Montreal (public venue reads) behind France's nginx over
an authenticated link, and split the funding relay: France reads the authenticated funding
records, Montreal cross-checks them against public funding rates and position sizes, bounds the
delta (Sermium L-06) and sends `accrueFunding`.
