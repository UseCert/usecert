# UseCert — external audit scope

Prepared 2026-09-27 for an independent audit. Everything below is read from the deployment
records in `deployments/` and checked on chain.

| | |
|---|---|
| Chain | Robinhood Chain **mainnet**, chain id **4663** |
| Explorer | https://robinhoodchain.blockscout.com |
| Repository | https://github.com/UseCert/usecert, branch `backend/contracts-c1` |
| Language / tooling | Solidity 0.8.24, Foundry, OpenZeppelin |
| Deployed source | vault stack at `91f7f2df0654c1535411cd583dde84b573b46a37`; InsuranceStaking at `095093bf940f44cf68ae1dff34c4b328ec21d48d`; CertStaking at `7f305c7c1eeb5815b49f1b70c776dd3fcea70588` |
| Source verification | Sourcify: every UseCert contract is an exact or runtime-exact match |
| In-scope size | 4,209 lines deployed (9 contracts) + 109 lines new (FeeVault) + the K2 diff to CertVault |

## 1. In scope — deployed

| Contract | Lines | Instances | What it does |
|---|---|---|---|
| **CertVault** | 2,212 | 6 | One vault per stock. Takes USDG, mints the certificate at the oracle price (delta 1.0, not pro-rata shares), and hedges it with a short perp on Lighter. The vault is itself a registered Lighter master account and submits its own orders, deposits and withdrawals. Keeper mode: a keeper opens the hedge off chain and settles the mint. Mint paths `mintInstant` and `requestMint` → `settleMint` (or `stageRefund` / `refundMint`); redeem paths `redeemInstant` and `requestRedeem` → `claimRedeem`, plus `forceExit`. Also `recallMarginUpTo` / `recallMargin`, `rebalance`, `closeAll`, `accrueFunding`, `seedBuffer`, `retire` / `sweepRetired`, `bootstrap`, `setVenueMinimums`, `setVenueApiKey`, `enableKeeperHedging`. |
| **Certificate** | 36 | 6 | Plain ERC-20 (uTSLA, uSPY, uQQQ, uNVDA, uAAPL, uMSFT). Transfers are unrestricted; only its vault can mint or burn. |
| **CertOracle** | 786 | 6 | The price for one asset. Chainlink is the holder-facing price; the Lighter mark price is a cross-check (deviation and basis bands, staleness). A guard breach pauses **minting only**: `pxUnguarded()` always answers, so redemption can never be trapped. The mark is set by `setMarkPrice` / `setMarkPriceSigned`; also `pokeLastGood` and a two-step attester rotation (`proposeAttester` / `acceptAttester`). |
| **BufferBook** | 188 | 6 | Per-asset accrual ledger for funding, execution variance and realised basis, with published thresholds (`configure`, `accrue`, vault-only). A cumulative P&L counter, **not** a measure of collateral held (see prior finding M-1 in the source). |
| **SolvencyRegistry** | 285 | 1 | Per-batch attested backing and open interest for each vault's Lighter account. A single attester signs on demand; the minter relays the signature in their own transaction (`attest`, `attestSigned`); two-step attester rotation. The claim is "independently verifiable", not "verified on chain". |
| **CapacityOracle** | 100 | 1 | Mint capacity as a formula: `min(depthBps × openInterest, absoluteCap, bufferCapacity)`. A stale attestation gives zero capacity, which pauses minting and never redemption. Governance tunes within immutable bounds (`setDepthBps`, `setAbsoluteCap`). |
| **CertFactory** | 171 | 1 | Registry of {vault, certificate} pairs and each vault's Lighter account index (`registerVault`, `enable`). Deploys nothing, holds no funds, gates nothing. |
| **InsuranceStaking** | 261 | 1 | ERC-4626 over USDG (share offset 6, so shares have 12 decimals). Stakers insure the vaults. Exits: `requestWithdraw`, a cooldown (deployed: 10 days), then a withdraw window (3 days); `cancelWithdraw`. Draws to cover a vault shortfall: `proposeDraw` (Safe only) → delay (2 days) → `executeDraw` within a 3-day window, or `cancelDraw`. Draws are capped per proposal at `maxDrawBps` (deployed: **30%**; the code allows at most 50%), at least 7 days apart, go only to registered vaults, and pause deposits and exits while pending. Immutable cap: 10,000 USDG. |
| **CertStaking** | 170 | 1 | Stake CERT, earn USDG. A StakingRewards variant: permissionless `notifyRewardAmount`, balance-delta crediting, reward accrued while nobody is staked carried into the next stream (`unallocated`), a 1e36 precision and 1e18-scaled rate, an immutable cap of 10,000,000 CERT. `stake`, `withdraw`, `getReward`, `exit`. No owner, no pause, no upgrade. |

## 2. In scope — not yet deployed (K2)

Branch `feat/k2-fee-routing` (`c23d9f2`); design in `docs/K-INSURANCE-STAKING.md`.

| Contract | Lines | What it does |
|---|---|---|
| **CertVault (K2 changes)** | diff vs `91f7f2d` | `feesAccrued`; a pull-only `sweepFees()` to a set-once `setFeeSink`. `spareCollateral` subtracts totalOwedOutstanding, escrowOutstanding, retainedBacking, bufferCapital and the declared deficit, so fees can never be paid from backing. |
| **FeeVault** | 109 | Ownerless. `distribute()` (anyone may call) splits the balance by fixed basis points set in the constructor: **70% InsuranceStaking, 20% buyback fund, 5% keeper/ops gas, 5% treasury Safe**. No setters; changing the split means a new FeeVault and a new vault stack. |

## 3. Deployed addresses

### Shared

| Role | Address |
|---|---|
| SolvencyRegistry | `0xAe6ae0939f2885fC0Ecf8b8af0082fa729a8bbB7` |
| CapacityOracle | `0xB6Ce5cD62c62c99c7312c76A4da169C95E5B0d1a` |
| CertFactory | `0x08117b198FCCeEC01427B13A4c9df908a3edd71E` |
| InsuranceStaking | `0xDbdA46671E0e97860493Ce149ad7B726407dAFb1` |
| CertStaking | `0x6491f2a764F65982641F3C63AeB6895cC33ba0Ae` |

### Per vault (stack 4)

| Asset | Lighter market | CertVault | Certificate | CertOracle | BufferBook | Chainlink feed |
|---|---|---|---|---|---|---|
| uTSLA | 16 | `0x6330B3C6612DBbf5D81A6BafB6319F39D46Df4B0` | `0x6195e1b053E905f0Cb5B6Fb7fE7E71D9191d25d5` | `0xdb1eF0e62F0954E8dC5dd1Bcc8126FbD30978121` | `0xd23F54EA91d6A78CCA95941778Ec7ED14B17dF64` | `0x4A1166a659A55625345e9515b32adECea5547C38` |
| uSPY | 26 | `0x4C1E083E1c0c726C6305ec684D9218dc83033dcd` | `0x0A9959243E65B9dc4C5B270b95Ce2B14cb0b4c85` | `0x94e58cBB9920dCBDF676132774fCd5248e455A85` | `0x0BF0a43Fdfb07983C00e7ddCA4FaeeC95Bc64422` | `0x319724394D3A0e3669269846abE664Cd621f9f6A` |
| uQQQ | 25 | `0x09777bfEB5a37cD5F642861fb166e7a9D2A4e615` | `0x1f773C4a8EBB1b32C56B87fcB4Dfdf15B76Dcf7b` | `0x013Dd75efD3F5485f2939aD5b6a986Fa815fe541` | `0x8d7045526e9770CEB057146436aea7DFEB599e86` | `0x80901d846d5D7B030F26B480776EE3b29374C2ae` |
| uNVDA | 15 | `0x2cA05803C37807bdB07075f6dA231C8B998e0bF3` | `0xB0ce8b0e84b5216cf64f9f45B597D013266D0fAf` | `0x9990de261434F2e7356b3C957f7ED4B9Fb86322F` | `0xC61C68a78C3042335f36bC560c1B701e5aF98a1a` | `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` |
| uAAPL | 10 | `0x1386cdA161593379B820542D347C75b43458f6ed` | `0x8fd48622a79Ef0B5b085A6BA01CB9b342Dc6c37f` | `0x2172701e2fd9C4c15A3297091Bd04045B015f05f` | `0xdaD9aE68Fc466FCF9f53c485E697544EDD1498C0` | `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` |
| uMSFT | 14 | `0xD9ccc6edD94779dB28C8743088b70560B728489C` | `0xd44818cb6348e6f42992F695525Ff103075d066B` | `0x325fc656A411EF1bc2f3621b2d045e2b42CC5450` | `0xBF0068E3F2c683595fcb07F35F68F76236CfB23B` | `0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E` |

**About the feed column.** The deployment record names it `replayAggregator` (the testnet
stand-in in `src/sim/`). On mainnet these are **Chainlink's own feeds**, not ours: checked on
chain 2026-09-27, e.g. `0x4A11…7C38` answers `description() = "RHTSLA / USD"`, `version() = 6`,
`phaseId() = 1`, 8 decimals, and each is owned by Chainlink's 4-of-9 Safe `0xeE27…9C52`. The
field name is a legacy label only.

## 4. Privileged roles

| Role | Holder |
|---|---|
| Governance | 2-of-3 Safe `0x848c91323f720DEf985adbCC85FA40E3405B70DF` |
| Attester (solvency and mark signatures) | EOA `0x021EeE925f9a7F0e9de1dBB5211D62466404f681` |
| Deployer (operational steps only) | EOA `0x6381577a72266E6b89eE9E96dF604CC3cd3f8e92` |
| Keepers | one per vault, off chain (hedge, settle, refund, recall) |

## 5. External dependencies (trusted, out of scope)

| Dependency | Address |
|---|---|
| USDG, collateral, 6 decimals | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| Lighter | `0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d` |
| Chainlink price feeds | listed in section 3 |
| CERT (staking token) | `0xb01356A005403C38c0fb01bd0aAfe51e81Ab9B07` |
| Safe contracts | — |

## 6. Optional off-chain scope

- `deploy/bin/usecert-signer-mainnet.py`: the attestation signer. It signs on request and never
  broadcasts.
- `deploy/bin/usecert-keeper.py`: the hedge keeper.

Both run on one host. A compromise of the attester key is the central off-chain risk.

## 7. Prior reviews and known state

- **2026-09-08 audit** of the C1 backend: 2 Critical, 2 High, 6 Medium, 9 Low. Both Criticals
  were in the mint path. `test/AuditPoC.t.sol` and `test/AttackSuite.t.sol` encode them, so
  `forge test` is **red by design** for the proof-of-concept tests. Fixes are recorded in
  `demo/ROADMAP.md`.
- **2026-09-25 launch-readiness audit** and its response: `demo/AUDIT-RESPONSE-2026-09-25.md`.
- **2026-09-27 internal pre-audit**, by the same team that wrote the code. It is **not** an
  independent audit.
- **Running the tests:** `test/script/DeployTestnet.t.sol` rewrites `deployments/46630.json`,
  so restore it afterwards (`git checkout deployments/46630.json`).
