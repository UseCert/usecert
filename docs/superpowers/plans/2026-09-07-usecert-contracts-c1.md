# UseCert C1 Contracts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and test the on-chain half of UseCert C1 — per-asset vaults that mint price-tracking stock certificates against fully-backed Lighter perp positions on Robinhood Chain, with capacity that scales as the market grows.

**Architecture:** Each `CertVault` is itself a registered Lighter master account and submits its own orders, deposits and withdrawals through `ZkLighter`'s priority queue — there is no off-chain trading key. Certificates are minted at Chainlink oracle price at delta 1.0 (not as pro-rata account shares). Minting is gated by oracle health, buffer health and a capacity formula over proven open interest; redemption is never gated and has a permissionless exit path.

**Tech Stack:** Foundry (forge, anvil), Solidity 0.8.24, OpenZeppelin Contracts 5.x, forge-std. No off-chain code in this plan.

**Spec:** `docs/superpowers/specs/2026-09-07-usecert-robinhood-backend-design.md`

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from the spec.

**Chain and venue**
- Robinhood Chain mainnet: chain ID `4663`, RPC `https://rpc.mainnet.chain.robinhood.com`, native gas token ETH. **The public RPC returns 429 on consecutive calls — never rely on it in tests or scripts; use a paid endpoint.**
- Testnet: chain ID `46630`, RPC `https://rpc.testnet.chain.robinhood.com`.
- Live `ZkLighter` (mainnet): `0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d`.
- Reference contract source: `elliottech/lighter-contracts` @ `75c2a73a5c25c9a6a36b66ba73aaf71267232b42`.
- `PRIORITY_EXPIRATION = 14 days`. This is a censorship deadline, not expected latency. Expected latency is one batch, ~60s.
- Priority requests cost **gas only** — no protocol fee. Pubdata is capped at 100 bytes per request.
- Collateral is **USDG**, not USDC, despite every source document saying USDC.

**Market parameters (verified 2026-09-07)**
- TSLA: `market_id = 16`, `price_decimals = 2`, `size_decimals = 4`, min base `0.0200`, min quote `10.000000`, `order_quote_limit = 25000000`.
- NVDA: `market_id = 15`, `price_decimals = 2`, `size_decimals = 4`, min base `0.0400`, min quote `10.000000`, `order_quote_limit = 25000000`.
- Both: `maker_fee = 0.0000`, `taker_fee = 0.0000`, `force_reduce_only = false`, `rfq_enabled = true`.
- Margin fractions, denominated in `ASSET_MARGIN_TICK = 10_000`: default IMR `5000`, min IMR `500`, MMR `300`, CMR `200`.

**Lighter order-path constraints**
- `OrderType` is `LimitOrder = 0` or `MarketOrder = 1` only. **There is no reduce-only, IOC, or post-only flag on the on-chain path.**
- `_baseAmount == 0` in `createOrder` **defaults to the full position size** — this is the close-all primitive.
- `_price` is `uint32`, bounded `MIN_ORDER_PRICE = 1` and `MAX_ORDER_PRICE = 2**32 - 1`.
- `_marketIndex <= 254`. `_baseAmount <= 2**48 - 1`.
- `GOLDILOCKS_MODULUS = 0xffffffff00000001`.

**Design laws — these are invariants, not preferences**
1. Delta target 1.0: `certificate supply x oracle px <= position notional + margin`.
2. **Redemption is never gated.** No redeem path may read buffer health, capacity, or oracle-pause state.
3. Funding is buffered, then fee'd, never hidden. Fee rate published and capped.
4. Holders are senior. Insurance draw order is immutable: buffer, then staked `$CERT`, then never holder backing.
5. Mirror the market honestly. No claim of custody, dividends, or shareholder rights.
6. **No privileged trading key exists.** The vault's own code is the only trading authority. No task may add an owner-only trade or withdraw function.

**Unverified values must be constructor parameters, never hardcoded literals.** This applies to: the USDG asset index, `RouteType` enum ordering, Chainlink feed addresses, `tickSize`, `minDepositTicks`, `depositCapTicks`. The spec's own rule: pin addresses and ABIs from live sources at deploy, never from memory.

**Naming is fixed by the front-end** and may not be changed: `CertVault`, `Certificate`, `CertOracle`, `BufferBook`, `InsuranceStaking`, `FeeVault`. Certificate symbols are `uTSLA`, `uNVDA`, `uSPX` (prefix `u`, not `h`).

**Solidity conventions**
- `pragma solidity 0.8.24;` exactly — pinned, not caret.
- `evm_version = "shanghai"` in `foundry.toml` (Arbitrum Orbit supports Shanghai; Cancun is not assumed).
- Custom errors, never `require` with strings.
- All monetary math in integer ticks. No floating point anywhere.
- Certificates are 18 decimals. USDG decimals come from the token and must be read, not assumed.

---

## Prerequisite: Foundry is not installed

`forge`, `cast` and `anvil` are absent from this machine and `~/.foundry` does not exist. Every task below runs `forge test`, so this must be resolved first.

Install is a piped remote script, so **the user runs it, not the agent**:

```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup
```

Then confirm:

```bash
forge --version
```

Do not proceed to Task 1 until `forge --version` prints a version.

---

## File Structure

```
foundry.toml                          Build config, remappings, evm_version
.gitignore                            (modify) add out/, cache/, broadcast/
lib/forge-std/                         Submodule
lib/openzeppelin-contracts/            Submodule

src/interfaces/ILighter.sol            Minimal ZkLighter surface we call
src/interfaces/IAggregatorV3.sol       Chainlink feed surface
src/interfaces/ICertOracle.sol         Price + guard surface consumed by the vault
src/interfaces/ISolvencyRegistry.sol   Attested backing surface
src/interfaces/ICapacityOracle.sol     Capacity formula surface

src/Certificate.sol                    ERC-20, vault-only mint/burn
src/CertOracle.sol                     Chainlink read, guards, uint32 tick encoding
src/SolvencyRegistry.sol               Per-batch attested notional/margin, with age
src/CapacityOracle.sol                 maxNotional formula, immutable bounds
src/BufferBook.sol                     Funding/variance accrual, thresholds
src/CertVault.sol                      Mint, redeem, forceExit, rebalance, solvency
src/CertFactory.sol                    Deploys and bootstraps vault+certificate pairs

test/helpers/VaultFixture.sol          Shared vault test stack (abstract, setUp virtual)
test/mocks/MockERC20.sol               Configurable-decimals token
test/mocks/MockLighter.sol             Priority-queue semantics test double
test/mocks/MockAggregatorV3.sol        Settable Chainlink feed

test/Certificate.t.sol
test/CertOracle.t.sol
test/SolvencyRegistry.t.sol
test/CapacityOracle.t.sol
test/BufferBook.t.sol
test/CertVaultMint.t.sol
test/CertVaultRedeem.t.sol
test/CertVaultRebalance.t.sol
test/CertFactory.t.sol
test/invariant/BackingInvariant.t.sol
```

**Deferred out of this plan, with reasons:**
- `Zap.sol` (USDC→USDG) — blocked on O-2 (USDG asset index, pool depth). The vault is USDG-native, so nothing here depends on it.
- `InsuranceStaking.sol`, `CERT.sol`, `FeeVault.sol` — C3 per the spec. `BufferBook` exposes the `insurance_draw` threshold as an event and a hook so C3 attaches without modifying it.
- Route-B on-chain Poseidon2 proof verification — C2. `SolvencyRegistry` is written so the attester can be swapped for a verifier without changing its consumers.

---

## Task 1: Project scaffold

**Files:**
- Create: `foundry.toml`
- Create: `test/Scaffold.t.sol`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: a `forge test` command that passes, `evm_version = "shanghai"`, remappings `forge-std/` and `openzeppelin-contracts/`.

- [ ] **Step 1: Initialise Foundry and install dependencies**

```bash
forge init --no-git --no-commit --force .
rm -rf src/Counter.sol test/Counter.t.sol script/
forge install foundry-rs/forge-std --no-git
forge install OpenZeppelin/openzeppelin-contracts --no-git
```

- [ ] **Step 2: Write `foundry.toml`**

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
test = "test"
solc_version = "0.8.24"
evm_version = "shanghai"
optimizer = true
optimizer_runs = 200
via_ir = false

remappings = [
  "forge-std/=lib/forge-std/src/",
  "openzeppelin-contracts/=lib/openzeppelin-contracts/contracts/",
]

[profile.default.fuzz]
runs = 512

[profile.default.invariant]
runs = 256
depth = 32
fail_on_revert = false

[rpc_endpoints]
robinhood_testnet = "${ROBINHOOD_TESTNET_RPC}"
robinhood_mainnet = "${ROBINHOOD_MAINNET_RPC}"
```

- [ ] **Step 3: Append to `.gitignore`**

```
out/
cache/
broadcast/
.env
```

- [ ] **Step 4: Write the scaffold test**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

contract ScaffoldTest is Test {
    function test_toolchainWorks() public pure {
        assertEq(uint256(1) + 1, 2);
    }
}
```

- [ ] **Step 5: Run the test**

Run: `forge test --match-contract ScaffoldTest -vv`
Expected: PASS, 1 test.

- [ ] **Step 6: Commit**

```bash
git add foundry.toml .gitignore test/Scaffold.t.sol lib
git commit -m "chore(contracts): foundry scaffold pinned to solc 0.8.24 / shanghai"
```

---

## Task 2: Lighter interface and mock

The mock must reproduce Lighter's **asynchronous** semantics or every later test will be a lie. Orders do not fill in the calling transaction; they fill when the test explicitly settles a batch.

**Files:**
- Create: `src/interfaces/ILighter.sol`
- Create: `test/mocks/MockERC20.sol`
- Create: `test/mocks/MockLighter.sol`
- Test: `test/mocks/MockLighter.t.sol`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `ILighter` with `deposit`, `createOrder`, `withdraw`, `cancelAllOrders`, `getPendingBalance`, `withdrawPendingBalance`.
  - `MockLighter.settleBatch()` — fills all queued orders at `markPrice`.
  - `MockLighter.setMarkPrice(uint16 marketIndex, uint256 px18)`.
  - `MockLighter.positionBase(uint16)` / `marginBalance()` — inspection for assertions.
  - `MockLighter.queuedOrderCount()`, `MockLighter.lastOrder()` returning `(uint16 marketIndex, uint48 baseAmount, uint32 price, uint8 isAsk, uint8 orderType)`.
  - `MockERC20(string name, string symbol, uint8 decimals)` with public `mint`.

- [ ] **Step 1: Write `ILighter.sol`**

`RouteType` ordering is unverified, so it is passed as `uint8` and supplied by the vault's constructor. Never hardcode it.

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @notice Minimal surface of Lighter's ZkLighter contract that UseCert calls.
/// @dev Signatures mirror elliottech/lighter-contracts @ 75c2a73. Order types:
///      LimitOrder = 0, MarketOrder = 1. `baseAmount == 0` in createOrder means
///      "the entire position" and is the close-all primitive.
interface ILighter {
    function deposit(address to, uint16 assetIndex, uint8 routeType, uint256 amount) external payable;

    function createOrder(
        uint48 accountIndex,
        uint16 marketIndex,
        uint48 baseAmount,
        uint32 price,
        uint8 isAsk,
        uint8 orderType
    ) external;

    function withdraw(uint48 accountIndex, uint16 assetIndex, uint8 routeType, uint64 baseAmount) external;

    function cancelAllOrders(uint48 accountIndex) external;

    function getPendingBalance(address owner, uint16 assetIndex) external view returns (uint128);

    function withdrawPendingBalance(address owner, uint16 assetIndex, uint128 baseAmount) external;
}
```

- [ ] **Step 2: Write `MockERC20.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}
```

- [ ] **Step 3: Write `MockLighter.sol`**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ILighter} from "../../src/interfaces/ILighter.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice Test double reproducing Lighter's asynchronous priority-queue semantics.
/// @dev Orders NEVER fill in the calling transaction. Call settleBatch() to fill.
contract MockLighter is ILighter {
    struct Order {
        uint16 marketIndex;
        uint48 baseAmount;
        uint32 price;
        uint8 isAsk;
        uint8 orderType;
    }

    error AccountIsNotRegistered();
    error MarketIndexTooHigh();
    error BadOrderType();

    IERC20 public immutable collateral;
    uint16 public immutable collateralAssetIndex;

    mapping(address => uint48) public accountIndexOf;
    uint48 private _nextAccountIndex = 3;

    /// @dev collateral posted as margin, in token units
    uint256 public marginBalance;
    /// @dev signed position size in base ticks (size_decimals applied by caller)
    mapping(uint16 => int256) public positionBase;
    /// @dev mark price scaled to 1e18
    mapping(uint16 => uint256) public markPrice;

    Order[] private _queue;
    mapping(address => mapping(uint16 => uint128)) private _pending;

    constructor(IERC20 _collateral, uint16 _collateralAssetIndex) {
        collateral = _collateral;
        collateralAssetIndex = _collateralAssetIndex;
    }

    function setMarkPrice(uint16 marketIndex, uint256 px18) external {
        markPrice[marketIndex] = px18;
    }

    function deposit(address to, uint16, uint8, uint256 amount) external payable {
        collateral.transferFrom(msg.sender, address(this), amount);
        marginBalance += amount;
        if (accountIndexOf[to] == 0) {
            accountIndexOf[to] = _nextAccountIndex++;
        }
    }

    function createOrder(uint48 accountIndex, uint16 marketIndex, uint48 baseAmount, uint32 price, uint8 isAsk, uint8 orderType)
        external
    {
        if (accountIndex == 0) revert AccountIsNotRegistered();
        if (marketIndex > 254) revert MarketIndexTooHigh();
        if (orderType > 1) revert BadOrderType();
        _queue.push(Order(marketIndex, baseAmount, price, isAsk, orderType));
    }

    function withdraw(uint48 accountIndex, uint16 assetIndex, uint8, uint64 baseAmount) external {
        if (accountIndex == 0) revert AccountIsNotRegistered();
        marginBalance -= baseAmount;
        _pending[msg.sender][assetIndex] += baseAmount;
    }

    function cancelAllOrders(uint48) external {
        delete _queue;
    }

    function getPendingBalance(address owner, uint16 assetIndex) external view returns (uint128) {
        return _pending[owner][assetIndex];
    }

    function withdrawPendingBalance(address owner, uint16 assetIndex, uint128 baseAmount) external {
        _pending[owner][assetIndex] -= baseAmount;
        collateral.transfer(owner, baseAmount);
    }

    /// @notice Fill every queued order at the current mark price. Emulates one batch executing.
    function settleBatch() external {
        for (uint256 i = 0; i < _queue.length; ++i) {
            Order memory o = _queue[i];
            int256 signed = o.isAsk == 1 ? -int256(uint256(o.baseAmount)) : int256(uint256(o.baseAmount));
            if (o.baseAmount == 0) {
                // baseAmount == 0 means close the entire position
                positionBase[o.marketIndex] = 0;
            } else {
                positionBase[o.marketIndex] += signed;
            }
        }
        delete _queue;
    }

    function queuedOrderCount() external view returns (uint256) {
        return _queue.length;
    }

    function lastOrder() external view returns (uint16, uint48, uint32, uint8, uint8) {
        Order memory o = _queue[_queue.length - 1];
        return (o.marketIndex, o.baseAmount, o.price, o.isAsk, o.orderType);
    }
}
```

- [ ] **Step 4: Write the failing test**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockLighter} from "./MockLighter.sol";
import {MockERC20} from "./MockERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

contract MockLighterTest is Test {
    MockLighter lighter;
    MockERC20 usdg;

    function setUp() public {
        usdg = new MockERC20("USDG", "USDG", 6);
        lighter = new MockLighter(IERC20(address(usdg)), 3);
        usdg.mint(address(this), 1_000_000e6);
        usdg.approve(address(lighter), type(uint256).max);
    }

    function test_depositRegistersAccount() public {
        assertEq(lighter.accountIndexOf(address(this)), 0);
        lighter.deposit(address(this), 3, 0, 1_000e6);
        assertGt(lighter.accountIndexOf(address(this)), 0);
        assertEq(lighter.marginBalance(), 1_000e6);
    }

    function test_createOrderRevertsForUnregisteredAccount() public {
        vm.expectRevert(MockLighter.AccountIsNotRegistered.selector);
        lighter.createOrder(0, 16, 100, 35586, 0, 1);
    }

    function test_orderDoesNotFillUntilBatchSettles() public {
        lighter.deposit(address(this), 3, 0, 1_000e6);
        uint48 idx = lighter.accountIndexOf(address(this));
        lighter.createOrder(idx, 16, 100, 35586, 0, 1);

        // The whole point: no fill in the calling transaction.
        assertEq(lighter.positionBase(16), 0);
        assertEq(lighter.queuedOrderCount(), 1);

        lighter.settleBatch();
        assertEq(lighter.positionBase(16), 100);
        assertEq(lighter.queuedOrderCount(), 0);
    }

    function test_zeroBaseAmountClosesEntirePosition() public {
        lighter.deposit(address(this), 3, 0, 1_000e6);
        uint48 idx = lighter.accountIndexOf(address(this));
        lighter.createOrder(idx, 16, 500, 35586, 0, 1);
        lighter.settleBatch();
        assertEq(lighter.positionBase(16), 500);

        lighter.createOrder(idx, 16, 0, 35586, 1, 1);
        lighter.settleBatch();
        assertEq(lighter.positionBase(16), 0);
    }
}
```

- [ ] **Step 5: Run the test**

Run: `forge test --match-contract MockLighterTest -vv`
Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
git add src/interfaces/ILighter.sol test/mocks/
git commit -m "feat(contracts): ILighter interface and async priority-queue mock"
```

---

## Task 3: Certificate

**Files:**
- Create: `src/Certificate.sol`
- Test: `test/Certificate.t.sol`

**Interfaces:**
- Consumes: nothing.
- Produces: `Certificate(string name, string symbol, address vault)`; `mint(address,uint256)`; `burn(address,uint256)`; `immutable vault`; error `Certificate_OnlyVault()`. Always 18 decimals.

- [ ] **Step 1: Write the failing test**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Certificate} from "../src/Certificate.sol";

contract CertificateTest is Test {
    Certificate cert;
    address vault = makeAddr("vault");
    address alice = makeAddr("alice");

    function setUp() public {
        cert = new Certificate("UseCert TSLA", "uTSLA", vault);
    }

    function test_metadata() public view {
        assertEq(cert.name(), "UseCert TSLA");
        assertEq(cert.symbol(), "uTSLA");
        assertEq(cert.decimals(), 18);
        assertEq(cert.vault(), vault);
    }

    function test_vaultCanMintAndBurn() public {
        vm.prank(vault);
        cert.mint(alice, 5e18);
        assertEq(cert.balanceOf(alice), 5e18);

        vm.prank(vault);
        cert.burn(alice, 2e18);
        assertEq(cert.balanceOf(alice), 3e18);
        assertEq(cert.totalSupply(), 3e18);
    }

    function test_nonVaultCannotMint() public {
        vm.expectRevert(Certificate.Certificate_OnlyVault.selector);
        vm.prank(alice);
        cert.mint(alice, 1e18);
    }

    function test_nonVaultCannotBurn() public {
        vm.prank(vault);
        cert.mint(alice, 1e18);

        vm.expectRevert(Certificate.Certificate_OnlyVault.selector);
        vm.prank(alice);
        cert.burn(alice, 1e18);
    }

    function test_transfersAreUnrestricted() public {
        vm.prank(vault);
        cert.mint(alice, 1e18);
        vm.prank(alice);
        cert.transfer(makeAddr("bob"), 1e18);
        assertEq(cert.balanceOf(makeAddr("bob")), 1e18);
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `forge test --match-contract CertificateTest`
Expected: compilation failure — `Certificate.sol` does not exist.

- [ ] **Step 3: Write the minimal implementation**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";

/// @notice A UseCert stock certificate (uTSLA, uNVDA, ...). Plain ERC-20 by design:
///         transfers are unrestricted so the token composes with DEXes and lending markets.
///         Only its vault may mint or burn.
contract Certificate is ERC20 {
    error Certificate_OnlyVault();

    address public immutable vault;

    constructor(string memory n, string memory s, address _vault) ERC20(n, s) {
        vault = _vault;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert Certificate_OnlyVault();
        _;
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `forge test --match-contract CertificateTest -vv`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add src/Certificate.sol test/Certificate.t.sol
git commit -m "feat(contracts): Certificate ERC-20 with vault-only mint and burn"
```

---

## Task 4: CertOracle

Two prices exist and they are not the same number: the Chainlink feed (what holders price against) and the Lighter mark (what the hedge fills at). Their spread is basis risk, and it must gate minting.

**Files:**
- Create: `src/interfaces/IAggregatorV3.sol`
- Create: `src/interfaces/ICertOracle.sol`
- Create: `src/CertOracle.sol`
- Create: `test/mocks/MockAggregatorV3.sol`
- Test: `test/CertOracle.t.sol`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `ICertOracle.px() returns (uint256 px18)` — reverts if unhealthy.
  - `ICertOracle.pxUnguarded() returns (uint256 px18, uint256 updatedAt)` — never reverts; the redeem path uses this.
  - `ICertOracle.mintAllowed() returns (bool)`.
  - `ICertOracle.basisBps() returns (uint256)`.
  - `ICertOracle.toTickPrice(uint256 px18) returns (uint32)`.
  - `setMarkPrice(uint256 px18)` — attester-only, wired to `SolvencyRegistry`'s attester in Task 11.
  - Errors: `CertOracle_StalePrice()`, `CertOracle_NonPositivePrice()`, `CertOracle_TickOverflow()`, `CertOracle_OnlyAttester()`.

- [ ] **Step 1: Write the two interfaces and the feed mock**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
```

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

interface ICertOracle {
    function px() external view returns (uint256 px18);
    function pxUnguarded() external view returns (uint256 px18, uint256 updatedAt);
    function mintAllowed() external view returns (bool);
    function basisBps() external view returns (uint256);
    function toTickPrice(uint256 px18) external view returns (uint32);
}
```

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

contract MockAggregatorV3 is IAggregatorV3 {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        updatedAt = block.timestamp;
    }

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
```

- [ ] **Step 2: Write the failing test**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CertOracle} from "../src/CertOracle.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

contract CertOracleTest is Test {
    CertOracle oracle;
    MockAggregatorV3 feed;
    address attester = makeAddr("attester");

    // TSLA: price_decimals = 2, so 355.86 -> tick 35586
    uint256 constant PX = 355.86e18;

    function setUp() public {
        vm.warp(1_800_000_000);
        feed = new MockAggregatorV3(8, 355_86000000); // 8 decimals
        oracle = new CertOracle(address(feed), attester, 2, 3600, 500, 100);
        vm.prank(attester);
        oracle.setMarkPrice(PX);
    }

    function test_pxNormalisesFeedDecimalsTo18() public view {
        assertEq(oracle.px(), PX);
    }

    function test_stalePriceRevertsAndBlocksMint() public {
        vm.warp(block.timestamp + 3601);
        assertFalse(oracle.mintAllowed());
        vm.expectRevert(CertOracle.CertOracle_StalePrice.selector);
        oracle.px();
    }

    function test_pxUnguardedNeverRevertsWhenStale() public {
        vm.warp(block.timestamp + 3601);
        (uint256 p, uint256 t) = oracle.pxUnguarded();
        assertEq(p, PX);
        assertGt(t, 0);
    }

    function test_nonPositivePriceReverts() public {
        feed.set(0, block.timestamp);
        vm.expectRevert(CertOracle.CertOracle_NonPositivePrice.selector);
        oracle.px();
    }

    function test_basisWithinBandAllowsMint() public {
        // mark 0.5% above index = 50 bps, band is 100 bps
        vm.prank(attester);
        oracle.setMarkPrice(PX * 1005 / 1000);
        assertEq(oracle.basisBps(), 50);
        assertTrue(oracle.mintAllowed());
    }

    function test_basisBeyondBandBlocksMintButNotRedeem() public {
        // mark 3% above index = 300 bps > 100 bps band
        vm.prank(attester);
        oracle.setMarkPrice(PX * 103 / 100);
        assertEq(oracle.basisBps(), 300);
        assertFalse(oracle.mintAllowed());

        // pxUnguarded stays available: redemption is never gated (Law 2)
        (uint256 p,) = oracle.pxUnguarded();
        assertEq(p, PX);
    }

    function test_toTickPriceAppliesPriceDecimals() public view {
        assertEq(oracle.toTickPrice(PX), 35586);
        assertEq(oracle.toTickPrice(1e18), 100);
    }

    function test_toTickPriceRevertsOnOverflow() public {
        vm.expectRevert(CertOracle.CertOracle_TickOverflow.selector);
        oracle.toTickPrice(type(uint256).max / 1e16);
    }

    function test_onlyAttesterSetsMarkPrice() public {
        vm.expectRevert(CertOracle.CertOracle_OnlyAttester.selector);
        oracle.setMarkPrice(1e18);
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `forge test --match-contract CertOracleTest`
Expected: compilation failure — `CertOracle.sol` does not exist.

- [ ] **Step 4: Write the implementation**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {ICertOracle} from "./interfaces/ICertOracle.sol";

/// @notice Price source for one asset. Chainlink is the holder-facing price; the Lighter mark
///         price is a cross-check. Guard breaches pause MINTING only — pxUnguarded() always
///         answers so redemption can never be trapped (Law 2).
contract CertOracle is ICertOracle {
    error CertOracle_StalePrice();
    error CertOracle_NonPositivePrice();
    error CertOracle_TickOverflow();
    error CertOracle_OnlyAttester();

    IAggregatorV3 public immutable feed;
    address public immutable attester;
    /// @dev market price_decimals; 2 for TSLA and NVDA
    uint8 public immutable priceDecimals;
    uint256 public immutable stalenessSeconds;
    /// @dev max |chainlink - lastGood| in bps before minting pauses
    uint256 public immutable deviationBps;
    /// @dev max |mark - chainlink| in bps before minting pauses
    uint256 public immutable basisBandBps;

    uint256 public markPx18;
    uint256 public lastGoodPx18;
    uint256 public lastGoodAt;

    constructor(
        address _feed,
        address _attester,
        uint8 _priceDecimals,
        uint256 _stalenessSeconds,
        uint256 _deviationBps,
        uint256 _basisBandBps
    ) {
        feed = IAggregatorV3(_feed);
        attester = _attester;
        priceDecimals = _priceDecimals;
        stalenessSeconds = _stalenessSeconds;
        deviationBps = _deviationBps;
        basisBandBps = _basisBandBps;

        (uint256 p,) = _readFeed();
        lastGoodPx18 = p;
        lastGoodAt = block.timestamp;
    }

    function setMarkPrice(uint256 px18) external {
        if (msg.sender != attester) revert CertOracle_OnlyAttester();
        markPx18 = px18;
    }

    function _readFeed() internal view returns (uint256 px18, uint256 updatedAt) {
        (, int256 answer,, uint256 t,) = feed.latestRoundData();
        if (answer <= 0) revert CertOracle_NonPositivePrice();
        uint8 d = feed.decimals();
        px18 = d <= 18 ? uint256(answer) * (10 ** (18 - d)) : uint256(answer) / (10 ** (d - 18));
        updatedAt = t;
    }

    function px() external view returns (uint256) {
        (uint256 p, uint256 t) = _readFeed();
        if (block.timestamp - t > stalenessSeconds) revert CertOracle_StalePrice();
        return p;
    }

    /// @notice Never reverts on guard state. The published last-good-price path for redemption.
    function pxUnguarded() external view returns (uint256, uint256) {
        (bool ok, uint256 p, uint256 t) = _tryFeed();
        if (ok) return (p, t);
        return (lastGoodPx18, lastGoodAt);
    }

    function _tryFeed() internal view returns (bool ok, uint256 px18, uint256 updatedAt) {
        (, int256 answer,, uint256 t,) = feed.latestRoundData();
        if (answer <= 0) return (false, 0, 0);
        if (block.timestamp - t > stalenessSeconds) return (false, 0, 0);
        uint8 d = feed.decimals();
        px18 = d <= 18 ? uint256(answer) * (10 ** (18 - d)) : uint256(answer) / (10 ** (d - 18));
        return (true, px18, t);
    }

    function basisBps() external view returns (uint256) {
        (bool ok, uint256 p,) = _tryFeed();
        if (!ok || p == 0 || markPx18 == 0) return 0;
        uint256 diff = markPx18 > p ? markPx18 - p : p - markPx18;
        return diff * 10_000 / p;
    }

    function mintAllowed() external view returns (bool) {
        (bool ok, uint256 p,) = _tryFeed();
        if (!ok) return false;
        if (markPx18 == 0) return false;
        uint256 diff = markPx18 > p ? markPx18 - p : p - markPx18;
        if (diff * 10_000 / p > basisBandBps) return false;
        if (lastGoodPx18 != 0) {
            uint256 dev = p > lastGoodPx18 ? p - lastGoodPx18 : lastGoodPx18 - p;
            if (dev * 10_000 / lastGoodPx18 > deviationBps) return false;
        }
        return true;
    }

    /// @notice Encode an 18-decimal price into Lighter's uint32 tick domain.
    function toTickPrice(uint256 px18) external view returns (uint32) {
        uint256 tick = px18 * (10 ** priceDecimals) / 1e18;
        if (tick == 0 || tick > type(uint32).max) revert CertOracle_TickOverflow();
        return uint32(tick);
    }

    /// @notice Refresh the last-good snapshot. Permissionless: it can only ever record the
    ///         feed's own healthy value, so there is nothing to game.
    function pokeLastGood() external {
        (bool ok, uint256 p, uint256 t) = _tryFeed();
        if (!ok) revert CertOracle_StalePrice();
        lastGoodPx18 = p;
        lastGoodAt = t;
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `forge test --match-contract CertOracleTest -vv`
Expected: PASS, 9 tests.

- [ ] **Step 6: Commit**

```bash
git add src/interfaces/IAggregatorV3.sol src/interfaces/ICertOracle.sol src/CertOracle.sol test/mocks/MockAggregatorV3.sol test/CertOracle.t.sol
git commit -m "feat(contracts): CertOracle with staleness, deviation and basis guards"
```

---

## Task 5: SolvencyRegistry

C1 uses route A: an attester posts backing derived from Lighter's on-chain blob data, and anyone can reconstruct and check it. This contract is written so the attester can be replaced by an on-chain proof verifier in C2 **without changing any consumer**.

**Files:**
- Create: `src/interfaces/ISolvencyRegistry.sol`
- Create: `src/SolvencyRegistry.sol`
- Test: `test/SolvencyRegistry.t.sol`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct Attestation { uint256 notional18; uint256 margin18; uint256 openInterest18; uint64 batchId; uint64 attestedAt; }`
  - `ISolvencyRegistry.latest(address asset) returns (Attestation memory)`
  - `ISolvencyRegistry.ageSec(address asset) returns (uint256)`
  - `attest(address asset, uint64 batchId, uint256 notional18, uint256 margin18, uint256 openInterest18)`
  - Errors: `SolvencyRegistry_OnlyAttester()`, `SolvencyRegistry_StaleBatch()`.
  - Event `Attested(address asset, uint64 batchId, uint256 notional18, uint256 margin18, uint256 openInterest18)`.

- [ ] **Step 1: Write the interface**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

interface ISolvencyRegistry {
    struct Attestation {
        uint256 notional18;
        uint256 margin18;
        uint256 openInterest18;
        uint64 batchId;
        uint64 attestedAt;
    }

    function latest(address asset) external view returns (Attestation memory);
    function ageSec(address asset) external view returns (uint256);
}
```

- [ ] **Step 2: Write the failing test**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SolvencyRegistry} from "../src/SolvencyRegistry.sol";
import {ISolvencyRegistry} from "../src/interfaces/ISolvencyRegistry.sol";

contract SolvencyRegistryTest is Test {
    SolvencyRegistry reg;
    address attester = makeAddr("attester");
    address asset = makeAddr("tsla");

    function setUp() public {
        vm.warp(1_800_000_000);
        reg = new SolvencyRegistry(attester);
    }

    function test_attestStoresAndEmits() public {
        vm.expectEmit(true, false, false, true);
        emit SolvencyRegistry.Attested(asset, 100, 1_000e18, 1_100e18, 50_000e18);
        vm.prank(attester);
        reg.attest(asset, 100, 1_000e18, 1_100e18, 50_000e18);

        ISolvencyRegistry.Attestation memory a = reg.latest(asset);
        assertEq(a.notional18, 1_000e18);
        assertEq(a.margin18, 1_100e18);
        assertEq(a.openInterest18, 50_000e18);
        assertEq(a.batchId, 100);
        assertEq(reg.ageSec(asset), 0);
    }

    function test_ageSecGrowsWithTime() public {
        vm.prank(attester);
        reg.attest(asset, 100, 1e18, 1e18, 1e18);
        vm.warp(block.timestamp + 90);
        assertEq(reg.ageSec(asset), 90);
    }

    function test_onlyAttesterMayAttest() public {
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_OnlyAttester.selector);
        reg.attest(asset, 1, 1e18, 1e18, 1e18);
    }

    function test_batchIdMustAdvance() public {
        vm.startPrank(attester);
        reg.attest(asset, 100, 1e18, 1e18, 1e18);
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_StaleBatch.selector);
        reg.attest(asset, 100, 2e18, 2e18, 2e18);
        vm.stopPrank();
    }

    function test_unattestedAssetHasMaxAge() public view {
        assertEq(reg.ageSec(makeAddr("unknown")), type(uint256).max);
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `forge test --match-contract SolvencyRegistryTest`
Expected: compilation failure — `SolvencyRegistry.sol` does not exist.

- [ ] **Step 4: Write the implementation**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ISolvencyRegistry} from "./interfaces/ISolvencyRegistry.sol";

/// @notice Per-batch attested backing for each vault's Lighter account.
/// @dev C1 (route A): a single attester posts figures reconstructed from Lighter's on-chain
///      blob data, and anyone can independently rebuild the tree and check them. The claim is
///      "independently verifiable", NOT "verified on-chain" — do not overstate it.
///      C2 (route B) replaces the attester with a Poseidon2 proof check inside attest(); the
///      Attestation struct and both view functions stay identical so consumers never change.
contract SolvencyRegistry is ISolvencyRegistry {
    error SolvencyRegistry_OnlyAttester();
    error SolvencyRegistry_StaleBatch();

    event Attested(
        address indexed asset, uint64 batchId, uint256 notional18, uint256 margin18, uint256 openInterest18
    );

    address public immutable attester;
    mapping(address => Attestation) private _latest;

    constructor(address _attester) {
        attester = _attester;
    }

    function attest(
        address asset,
        uint64 batchId,
        uint256 notional18,
        uint256 margin18,
        uint256 openInterest18
    ) external {
        if (msg.sender != attester) revert SolvencyRegistry_OnlyAttester();
        if (batchId <= _latest[asset].batchId) revert SolvencyRegistry_StaleBatch();

        _latest[asset] = Attestation({
            notional18: notional18,
            margin18: margin18,
            openInterest18: openInterest18,
            batchId: batchId,
            attestedAt: uint64(block.timestamp)
        });

        emit Attested(asset, batchId, notional18, margin18, openInterest18);
    }

    function latest(address asset) external view returns (Attestation memory) {
        return _latest[asset];
    }

    /// @notice Age of the newest attestation. Returns max for never-attested assets so callers
    ///         treating "old" as unsafe are correct by default.
    function ageSec(address asset) external view returns (uint256) {
        uint64 t = _latest[asset].attestedAt;
        if (t == 0) return type(uint256).max;
        return block.timestamp - t;
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `forge test --match-contract SolvencyRegistryTest -vv`
Expected: PASS, 5 tests.

- [ ] **Step 6: Commit**

```bash
git add src/interfaces/ISolvencyRegistry.sol src/SolvencyRegistry.sol test/SolvencyRegistry.t.sol
git commit -m "feat(contracts): SolvencyRegistry with per-batch attestations and published age"
```

---

## Task 6: CapacityOracle

This is what lets the product grow. Capacity is a formula over proven open interest, never a hardcoded number — but `absoluteCap` is immutable, so even a fully compromised attester cannot raise capacity beyond the ceiling set at deploy.

**Files:**
- Create: `src/interfaces/ICapacityOracle.sol`
- Create: `src/CapacityOracle.sol`
- Test: `test/CapacityOracle.t.sol`

**Interfaces:**
- Consumes: `ISolvencyRegistry` (Task 5).
- Produces:
  - `ICapacityOracle.maxNotional18(address asset, uint256 bufferCapacity18) returns (uint256)`
  - `ICapacityOracle.depthBps() returns (uint256)`
  - `setDepthBps(uint256)` — governance, clamped to immutable bounds.
  - Errors: `CapacityOracle_OnlyGovernance()`, `CapacityOracle_DepthOutOfBounds()`.

- [ ] **Step 1: Write the interface**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

interface ICapacityOracle {
    function maxNotional18(address asset, uint256 bufferCapacity18) external view returns (uint256);
    function depthBps() external view returns (uint256);
}
```

- [ ] **Step 2: Write the failing test**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CapacityOracle} from "../src/CapacityOracle.sol";
import {SolvencyRegistry} from "../src/SolvencyRegistry.sol";

contract CapacityOracleTest is Test {
    CapacityOracle cap;
    SolvencyRegistry reg;
    address attester = makeAddr("attester");
    address gov = makeAddr("gov");
    address asset = makeAddr("tsla");

    uint256 constant OI = 1_190_000e18; // TSLA open interest observed 2026-09-07
    uint256 constant ABSOLUTE_CAP = 5_000_000e18;
    uint256 constant HUGE_BUFFER = type(uint256).max;

    function setUp() public {
        vm.warp(1_800_000_000);
        reg = new SolvencyRegistry(attester);
        // depthBps 1000 = 10%, bounds [100, 3000], absoluteCap 5M
        cap = new CapacityOracle(address(reg), gov, 1000, 100, 3000, 300);
        vm.prank(gov);
        cap.setAbsoluteCap(asset, ABSOLUTE_CAP);
        vm.prank(attester);
        reg.attest(asset, 1, 0, 0, OI);
    }

    function test_capacityIsDepthShareOfOpenInterest() public view {
        // 10% of 1.19M = 119k
        assertEq(cap.maxNotional18(asset, HUGE_BUFFER), 119_000e18);
    }

    function test_capacityGrowsWithTheMarket() public {
        // The whole point: 100x the market, no redeploy, no parameter change.
        vm.prank(attester);
        reg.attest(asset, 2, 0, 0, OI * 100);
        assertEq(cap.maxNotional18(asset, HUGE_BUFFER), ABSOLUTE_CAP);

        vm.prank(gov);
        cap.setAbsoluteCap(asset, 100_000_000e18);
        assertEq(cap.maxNotional18(asset, HUGE_BUFFER), 11_900_000e18);
    }

    function test_absoluteCapBoundsALyingAttester() public {
        vm.prank(attester);
        reg.attest(asset, 2, 0, 0, type(uint128).max);
        assertEq(cap.maxNotional18(asset, HUGE_BUFFER), ABSOLUTE_CAP);
    }

    function test_bufferCapacityCanBeTheBindingConstraint() public view {
        assertEq(cap.maxNotional18(asset, 50_000e18), 50_000e18);
    }

    function test_staleAttestationYieldsZeroCapacity() public {
        vm.warp(block.timestamp + 301);
        assertEq(cap.maxNotional18(asset, HUGE_BUFFER), 0);
    }

    function test_unattestedAssetYieldsZeroCapacity() public view {
        assertEq(cap.maxNotional18(makeAddr("unknown"), HUGE_BUFFER), 0);
    }

    function test_governanceMayTuneDepthWithinBounds() public {
        vm.prank(gov);
        cap.setDepthBps(2000);
        assertEq(cap.maxNotional18(asset, HUGE_BUFFER), 238_000e18);
    }

    function test_governanceCannotEscapeBounds() public {
        vm.startPrank(gov);
        vm.expectRevert(CapacityOracle.CapacityOracle_DepthOutOfBounds.selector);
        cap.setDepthBps(3001);
        vm.expectRevert(CapacityOracle.CapacityOracle_DepthOutOfBounds.selector);
        cap.setDepthBps(99);
        vm.stopPrank();
    }

    function test_nonGovernanceCannotTuneDepth() public {
        vm.expectRevert(CapacityOracle.CapacityOracle_OnlyGovernance.selector);
        cap.setDepthBps(2000);
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `forge test --match-contract CapacityOracleTest`
Expected: compilation failure — `CapacityOracle.sol` does not exist.

- [ ] **Step 4: Write the implementation**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ICapacityOracle} from "./interfaces/ICapacityOracle.sol";
import {ISolvencyRegistry} from "./interfaces/ISolvencyRegistry.sol";

/// @notice Capacity is a formula, not a constant, so the product grows as the market grows
///         without redeployment:
///
///           maxNotional = min(depthBps * openInterest, absoluteCap, bufferCapacity)
///
/// @dev Open interest comes from the same per-batch attestation that feeds solvency, so it is not
///      operator self-reporting. absoluteCap and the depthBps bounds are immutable at deploy:
///      governance can tune within them and can never remove the cap. A stale attestation yields
///      zero capacity, which pauses minting — never redemption (Law 2).
contract CapacityOracle is ICapacityOracle {
    error CapacityOracle_OnlyGovernance();
    error CapacityOracle_DepthOutOfBounds();

    event DepthBpsSet(uint256 depthBps);
    event AbsoluteCapSet(address indexed asset, uint256 cap18);

    ISolvencyRegistry public immutable registry;
    address public immutable governance;
    uint256 public immutable minDepthBps;
    uint256 public immutable maxDepthBps;
    uint256 public immutable maxAttestationAgeSec;

    uint256 public depthBps;
    mapping(address => uint256) public absoluteCap18;

    constructor(
        address _registry,
        address _governance,
        uint256 _depthBps,
        uint256 _minDepthBps,
        uint256 _maxDepthBps,
        uint256 _maxAttestationAgeSec
    ) {
        if (_depthBps < _minDepthBps || _depthBps > _maxDepthBps) revert CapacityOracle_DepthOutOfBounds();
        registry = ISolvencyRegistry(_registry);
        governance = _governance;
        depthBps = _depthBps;
        minDepthBps = _minDepthBps;
        maxDepthBps = _maxDepthBps;
        maxAttestationAgeSec = _maxAttestationAgeSec;
    }

    function setDepthBps(uint256 v) external {
        if (msg.sender != governance) revert CapacityOracle_OnlyGovernance();
        if (v < minDepthBps || v > maxDepthBps) revert CapacityOracle_DepthOutOfBounds();
        depthBps = v;
        emit DepthBpsSet(v);
    }

    /// @dev Governance only, with no first-call exception. An earlier draft let anyone set a
    ///      never-before-set cap "for bootstrap convenience"; that let a stranger front-run the
    ///      cap for a new asset, which is the one number holding a compromised attester in check.
    function setAbsoluteCap(address asset, uint256 cap18) external {
        if (msg.sender != governance) revert CapacityOracle_OnlyGovernance();
        absoluteCap18[asset] = cap18;
        emit AbsoluteCapSet(asset, cap18);
    }

    function maxNotional18(address asset, uint256 bufferCapacity18) external view returns (uint256) {
        if (registry.ageSec(asset) > maxAttestationAgeSec) return 0;

        uint256 oi = registry.latest(asset).openInterest18;
        if (oi == 0) return 0;

        uint256 byDepth = oi * depthBps / 10_000;
        uint256 cap = absoluteCap18[asset];
        uint256 out = byDepth < cap ? byDepth : cap;
        return out < bufferCapacity18 ? out : bufferCapacity18;
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `forge test --match-contract CapacityOracleTest -vv`
Expected: PASS, 9 tests.

- [ ] **Step 6: Commit**

```bash
git add src/interfaces/ICapacityOracle.sol src/CapacityOracle.sol test/CapacityOracle.t.sol
git commit -m "feat(contracts): CapacityOracle scaling with proven open interest under immutable caps"
```

---

## Task 7: BufferBook

**Files:**
- Create: `src/BufferBook.sol`
- Test: `test/BufferBook.t.sol`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `accrue(address asset, int256 delta18)` — vault-only; positive fattens, negative draws.
  - `balance18(address asset) returns (int256)`
  - `holdingFeeBps(address asset) returns (uint256)` — 0 until `feeOn`, then ramps, capped.
  - `mintSlowed(address asset) returns (bool)`
  - `insuranceDrawNeeded(address asset) returns (uint256)`
  - `capacity18(address asset) returns (uint256)` — what the buffer can absorb, fed to `CapacityOracle`.
  - Errors: `BufferBook_OnlyVault()`.
  - Event `ThresholdCrossed(address asset, uint8 level)` where 0=healthy, 1=feeOn, 2=mintSlow, 3=insuranceDraw.

- [ ] **Step 1: Write the failing test**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BufferBook} from "../src/BufferBook.sol";

contract BufferBookTest is Test {
    BufferBook book;
    address vault = makeAddr("vault");
    address asset = makeAddr("tsla");

    // floor 100k, feeOn 60k, mintSlow 30k, insuranceDraw 0, feeCap 200 bps
    function setUp() public {
        book = new BufferBook(vault, 200);
        vm.prank(vault);
        book.configure(asset, 100_000e18, 60_000e18, 30_000e18, 0);
    }

    function _fund(uint256 amt) internal {
        vm.prank(vault);
        book.accrue(asset, int256(amt));
    }

    function test_positiveFundingFattensBuffer() public {
        _fund(100_000e18);
        assertEq(book.balance18(asset), int256(100_000e18));
        assertEq(book.holdingFeeBps(asset), 0);
        assertFalse(book.mintSlowed(asset));
    }

    function test_healthyBufferChargesNoHoldingFee() public {
        _fund(80_000e18);
        assertEq(book.holdingFeeBps(asset), 0);
    }

    function test_crossingFeeOnActivatesCappedFee() public {
        _fund(50_000e18); // below feeOn 60k
        uint256 fee = book.holdingFeeBps(asset);
        assertGt(fee, 0);
        assertLe(fee, 200);
    }

    function test_feeIsCappedAtDeployBound() public {
        _fund(1e18); // almost empty
        assertEq(book.holdingFeeBps(asset), 200);
    }

    function test_crossingMintSlowFlagsIt() public {
        _fund(50_000e18);
        assertFalse(book.mintSlowed(asset));
        vm.prank(vault);
        book.accrue(asset, -25_000e18); // now 25k, below mintSlow 30k
        assertTrue(book.mintSlowed(asset));
    }

    function test_exhaustedBufferRequestsInsuranceDraw() public {
        _fund(10_000e18);
        vm.prank(vault);
        book.accrue(asset, -15_000e18); // negative
        assertLt(book.balance18(asset), 0);
        assertEq(book.insuranceDrawNeeded(asset), 5_000e18);
    }

    function test_capacityIsZeroWhenBufferNegative() public {
        _fund(10_000e18);
        vm.prank(vault);
        book.accrue(asset, -15_000e18);
        assertEq(book.capacity18(asset), 0);
    }

    function test_capacityScalesWithBuffer() public {
        _fund(100_000e18);
        assertGt(book.capacity18(asset), 0);
    }

    function test_onlyVaultMayAccrue() public {
        vm.expectRevert(BufferBook.BufferBook_OnlyVault.selector);
        book.accrue(asset, 1e18);
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `forge test --match-contract BufferBookTest`
Expected: compilation failure — `BufferBook.sol` does not exist.

- [ ] **Step 3: Write the implementation**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @notice Per-asset accrual of funding, execution variance and realised basis, with published
///         thresholds. Positive accrual fattens the buffer; negative draws it down. Past feeOn a
///         holding fee activates, ramping linearly to an immutable cap. Nothing here is hidden —
///         every threshold and the live balance are readable on-chain (Law 3).
/// @dev The insurance draw is exposed as a number and an event only. C3's InsuranceStaking reads
///      it; this contract never needs to change to support that.
contract BufferBook {
    error BufferBook_OnlyVault();

    event ThresholdCrossed(address indexed asset, uint8 level);
    event Accrued(address indexed asset, int256 delta18, int256 balance18);

    struct Config {
        uint256 floor18;
        uint256 feeOn18;
        uint256 mintSlow18;
        uint256 insuranceDraw18;
        bool set;
    }

    address public immutable vault;
    /// @dev maximum holding fee in bps, immutable at deploy (Law 3: bounded, published)
    uint256 public immutable feeCapBps;

    mapping(address => Config) public config;
    mapping(address => int256) private _balance;

    constructor(address _vault, uint256 _feeCapBps) {
        vault = _vault;
        feeCapBps = _feeCapBps;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert BufferBook_OnlyVault();
        _;
    }

    function configure(address asset, uint256 floor18, uint256 feeOn18, uint256 mintSlow18, uint256 insuranceDraw18)
        external
        onlyVault
    {
        config[asset] = Config(floor18, feeOn18, mintSlow18, insuranceDraw18, true);
    }

    function accrue(address asset, int256 delta18) external onlyVault {
        int256 b = _balance[asset] + delta18;
        _balance[asset] = b;
        emit Accrued(asset, delta18, b);

        Config memory c = config[asset];
        uint8 level = 0;
        if (b < int256(c.insuranceDraw18)) level = 3;
        else if (b < int256(c.mintSlow18)) level = 2;
        else if (b < int256(c.feeOn18)) level = 1;
        emit ThresholdCrossed(asset, level);
    }

    function balance18(address asset) external view returns (int256) {
        return _balance[asset];
    }

    /// @notice Linear ramp from 0 at feeOn to feeCapBps at empty. Never exceeds the cap.
    function holdingFeeBps(address asset) external view returns (uint256) {
        Config memory c = config[asset];
        int256 b = _balance[asset];
        if (b >= int256(c.feeOn18)) return 0;
        if (b <= 0) return feeCapBps;
        if (c.feeOn18 == 0) return 0;

        uint256 shortfall = c.feeOn18 - uint256(b);
        uint256 fee = shortfall * feeCapBps / c.feeOn18;
        return fee > feeCapBps ? feeCapBps : fee;
    }

    function mintSlowed(address asset) external view returns (bool) {
        return _balance[asset] < int256(config[asset].mintSlow18);
    }

    function insuranceDrawNeeded(address asset) external view returns (uint256) {
        int256 b = _balance[asset];
        int256 threshold = int256(config[asset].insuranceDraw18);
        if (b >= threshold) return 0;
        return uint256(threshold - b);
    }

    /// @notice What the buffer can absorb, fed into CapacityOracle's min().
    /// @dev Buffer must cover a plausible adverse move on the whole book, so capacity is a
    ///      multiple of the buffer rather than the buffer itself. Multiplier is the ratio of
    ///      floor to a 1% adverse move: capacity = balance * 100.
    function capacity18(address asset) external view returns (uint256) {
        int256 b = _balance[asset];
        if (b <= 0) return 0;
        return uint256(b) * 100;
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `forge test --match-contract BufferBookTest -vv`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add src/BufferBook.sol test/BufferBook.t.sol
git commit -m "feat(contracts): BufferBook accrual with published thresholds and capped holding fee"
```

---

## Task 8: CertVault — mint paths

**Files:**
- Create: `src/CertVault.sol`
- Test: `test/CertVaultMint.t.sol`

**Interfaces:**
- Consumes: `ILighter` (T2), `Certificate` (T3), `ICertOracle` (T4), `ISolvencyRegistry` (T5), `ICapacityOracle` (T6), `BufferBook` (T7).
- Produces:
  - `struct VaultConfig { address collateral; uint16 collateralAssetIndex; uint8 routeType; uint16 marketIndex; uint8 sizeDecimals; uint256 mintFeeBps; uint256 redeemFeeBps; uint256 instantCap18; uint256 settleBandBps; }`
  - `mintInstant(uint256 amountIn) returns (uint256 certOut)`
  - `requestMint(uint256 amountIn) returns (uint256 receiptId)`
  - `settleMint(uint256 receiptId, uint256 fillPx18)`
  - `bootstrap()` — one-time dust deposit registering the Lighter account.
  - `lighterAccountIndex() returns (uint48)`
  - Errors: `CertVault_NotBootstrapped()`, `CertVault_MintPaused()`, `CertVault_AtCapacity()`, `CertVault_AboveInstantCap()`, `CertVault_BelowInstantCap()`, `CertVault_BadReceipt()`.
  - Events `Minted`, `MintRequested`, `MintSettled`.

- [ ] **Step 1: Write the failing test**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CertVault} from "../src/CertVault.sol";
import {Certificate} from "../src/Certificate.sol";
import {CertOracle} from "../src/CertOracle.sol";
import {SolvencyRegistry} from "../src/SolvencyRegistry.sol";
import {CapacityOracle} from "../src/CapacityOracle.sol";
import {BufferBook} from "../src/BufferBook.sol";
import {MockLighter} from "./mocks/MockLighter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

contract CertVaultMintTest is Test {
    CertVault vault;
    Certificate cert;
    CertOracle oracle;
    SolvencyRegistry reg;
    CapacityOracle cap;
    BufferBook book;
    MockLighter lighter;
    MockERC20 usdg;
    MockAggregatorV3 feed;

    address attester = makeAddr("attester");
    address gov = makeAddr("gov");
    address alice = makeAddr("alice");

    uint256 constant PX = 355.86e18;
    uint16 constant MARKET = 16; // TSLA
    uint16 constant ASSET_IDX = 3;

    function setUp() public {
        vm.warp(1_800_000_000);
        usdg = new MockERC20("USDG", "USDG", 6);
        feed = new MockAggregatorV3(8, 355_86000000);
        lighter = new MockLighter(IERC20(address(usdg)), ASSET_IDX);
        reg = new SolvencyRegistry(attester);
        oracle = new CertOracle(address(feed), attester, 2, 3600, 500, 100);
        cap = new CapacityOracle(address(reg), gov, 1000, 100, 3000, 300);

        vault = new CertVault(
            CertVault.Deps({
                lighter: address(lighter),
                oracle: address(oracle),
                registry: address(reg),
                capacity: address(cap),
                governance: gov
            }),
            CertVault.VaultConfig({
                collateral: address(usdg),
                collateralAssetIndex: ASSET_IDX,
                routeType: 0,
                marketIndex: MARKET,
                sizeDecimals: 4,
                mintFeeBps: 10,
                redeemFeeBps: 10,
                instantCap18: 10_000e18
            }),
            "UseCert TSLA",
            "uTSLA"
        );
        cert = Certificate(vault.certificate());
        book = BufferBook(vault.buffer());

        vm.prank(gov);
        cap.setAbsoluteCap(address(vault), 5_000_000e18);
        vm.startPrank(attester);
        oracle.setMarkPrice(PX);
        reg.attest(address(vault), 1, 0, 0, 1_190_000e18);
        vm.stopPrank();

        usdg.mint(alice, 1_000_000e6);
        usdg.mint(address(this), 1_000_000e6);
        vm.prank(alice);
        usdg.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);

        // seed the buffer so capacity is not buffer-bound
        vault.seedBuffer(100_000e6);
        vault.bootstrap();
        lighter.settleBatch();
    }

    function test_bootstrapRegistersLighterAccount() public view {
        assertGt(vault.lighterAccountIndex(), 0);
    }

    function test_mintInstantMintsAtOraclePriceMinusFee() public {
        vm.prank(alice);
        uint256 out = vault.mintInstant(3_558.6e6); // ~10 TSLA at 355.86

        // (3558.6 - 0.1%) / 355.86 = 9.99 certificates
        assertEq(out, 9.99e18);
        assertEq(cert.balanceOf(alice), 9.99e18);
    }

    function test_mintInstantQueuesItsOwnHedgeInTheSameTransaction() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);

        // Law 6: the vault submits its own order. No keeper involved.
        assertEq(lighter.queuedOrderCount(), 1);
        (uint16 mkt,, uint32 price, uint8 isAsk, uint8 orderType) = lighter.lastOrder();
        assertEq(mkt, MARKET);
        assertEq(isAsk, 0); // buying
        assertEq(orderType, 1); // MarketOrder
        assertEq(price, 35586);
    }

    function test_mintPausedWhenOracleUnhealthy() public {
        vm.warp(block.timestamp + 3601);
        vm.expectRevert(CertVault.CertVault_MintPaused.selector);
        vm.prank(alice);
        vault.mintInstant(1_000e6);
    }

    function test_mintPausedWhenBasisOutsideBand() public {
        vm.prank(attester);
        oracle.setMarkPrice(PX * 103 / 100);
        vm.expectRevert(CertVault.CertVault_MintPaused.selector);
        vm.prank(alice);
        vault.mintInstant(1_000e6);
    }

    function test_mintRevertsAtCapacityWithDistinctError() public {
        // capacity = 10% of 1.19M = 119k notional
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);

        vm.prank(attester);
        reg.attest(address(vault), 2, 119_000e18, 0, 1_190_000e18);

        vm.expectRevert(CertVault.CertVault_AtCapacity.selector);
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
    }

    function test_mintAboveInstantCapMustUseRequestPath() public {
        vm.expectRevert(CertVault.CertVault_AboveInstantCap.selector);
        vm.prank(alice);
        vault.mintInstant(50_000e6); // > instantCap 10k notional
    }

    function test_requestMintEscrowsAndSettlesAtActualFill() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        assertEq(cert.balanceOf(alice), 0);

        lighter.settleBatch();
        // filled 1% worse than oracle
        vault.settleMint(id, PX * 101 / 100);

        // 49_950 / 359.4186 = 138.98... certificates
        assertGt(cert.balanceOf(alice), 0);
        assertLt(cert.balanceOf(alice), 139e18);
    }

    function test_requestMintBelowInstantCapReverts() public {
        vm.expectRevert(CertVault.CertVault_BelowInstantCap.selector);
        vm.prank(alice);
        vault.requestMint(100e6);
    }

    function test_settleMintRejectsUnknownReceipt() public {
        vm.expectRevert(CertVault.CertVault_BadReceipt.selector);
        vault.settleMint(999, PX);
    }

    function test_mintBeforeBootstrapReverts() public {
        CertVault fresh = new CertVault(
            CertVault.Deps({
                lighter: address(lighter),
                oracle: address(oracle),
                registry: address(reg),
                capacity: address(cap),
                governance: gov
            }),
            CertVault.VaultConfig({
                collateral: address(usdg),
                collateralAssetIndex: ASSET_IDX,
                routeType: 0,
                marketIndex: MARKET,
                sizeDecimals: 4,
                mintFeeBps: 10,
                redeemFeeBps: 10,
                instantCap18: 10_000e18
            }),
            "UseCert TSLA",
            "uTSLA"
        );
        vm.expectRevert(CertVault.CertVault_NotBootstrapped.selector);
        fresh.mintInstant(1_000e6);
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `forge test --match-contract CertVaultMintTest`
Expected: compilation failure — `CertVault.sol` does not exist.

- [ ] **Step 3: Write `CertVault.sol` covering mint only**

Redeem, `forceExit` and `rebalance` are added in Tasks 9 and 10; leave them out entirely for now rather than stubbing them.

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ILighter} from "./interfaces/ILighter.sol";
import {ICertOracle} from "./interfaces/ICertOracle.sol";
import {ISolvencyRegistry} from "./interfaces/ISolvencyRegistry.sol";
import {ICapacityOracle} from "./interfaces/ICapacityOracle.sol";
import {Certificate} from "./Certificate.sol";
import {BufferBook} from "./BufferBook.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice One vault per asset. The vault IS a registered Lighter master account and submits its
///         own orders, deposits and withdrawals — there is no privileged trading key anywhere in
///         this contract (Law 6). Certificates are minted at oracle price at delta 1.0, never as
///         pro-rata account shares.
contract CertVault {
    using SafeERC20 for IERC20;

    error CertVault_NotBootstrapped();
    error CertVault_AlreadyBootstrapped();
    error CertVault_MintPaused();
    error CertVault_AtCapacity();
    error CertVault_AboveInstantCap();
    error CertVault_BelowInstantCap();
    error CertVault_BadReceipt();
    error CertVault_OnlyGovernance();
    error CertVault_OnlyAttester();

    event Minted(address indexed user, uint256 amountIn, uint256 certOut, uint256 px18, uint256 fee);
    event MintRequested(uint256 indexed receiptId, address indexed user, uint256 amountIn);
    event MintSettled(uint256 indexed receiptId, uint256 certOut, uint256 fillPx18);

    struct Deps {
        address lighter;
        address oracle;
        address registry;
        address capacity;
        address governance;
    }

    struct VaultConfig {
        address collateral;
        uint16 collateralAssetIndex;
        uint8 routeType;
        uint16 marketIndex;
        uint8 sizeDecimals;
        uint256 mintFeeBps;
        uint256 redeemFeeBps;
        uint256 instantCap18;
    }

    struct MintReceipt {
        address user;
        uint256 escrow;
        bool settled;
    }

    uint8 internal constant ORDER_TYPE_MARKET = 1;
    uint8 internal constant SIDE_BID = 0;
    uint8 internal constant SIDE_ASK = 1;

    ILighter public immutable lighter;
    ICertOracle public immutable oracle;
    ISolvencyRegistry public immutable registry;
    ICapacityOracle public immutable capacity;
    address public immutable governance;
    Certificate public immutable certificate;
    BufferBook public immutable buffer;

    VaultConfig public cfg;
    uint8 private immutable _collateralDecimals;

    bool public bootstrapped;
    uint256 private _nextReceiptId = 1;
    mapping(uint256 => MintReceipt) public mintReceipts;

    constructor(Deps memory d, VaultConfig memory c, string memory name_, string memory symbol_) {
        lighter = ILighter(d.lighter);
        oracle = ICertOracle(d.oracle);
        registry = ISolvencyRegistry(d.registry);
        capacity = ICapacityOracle(d.capacity);
        governance = d.governance;
        cfg = c;
        _collateralDecimals = IERC20Metadata(c.collateral).decimals();

        certificate = new Certificate(name_, symbol_, address(this));
        buffer = new BufferBook(address(this), 200);
        buffer.configure(address(this), 100_000e18, 60_000e18, 30_000e18, 0);
    }

    // ---------------------------------------------------------------- bootstrap

    /// @notice One-time dust deposit so Lighter assigns this contract an account index.
    /// @dev createOrder reverts with AccountIsNotRegistered until the registering deposit has
    ///      been executed by a batch, so this must land before any mint.
    function bootstrap() external {
        if (bootstrapped) revert CertVault_AlreadyBootstrapped();
        bootstrapped = true;
        uint256 dust = 10 ** _collateralDecimals;
        IERC20(cfg.collateral).forceApprove(address(lighter), dust);
        lighter.deposit(address(this), cfg.collateralAssetIndex, cfg.routeType, dust);
    }

    function lighterAccountIndex() public view returns (uint48) {
        return ILighterAccounts(address(lighter)).accountIndexOf(address(this));
    }

    /// @notice Pre-fund the buffer. Permissionless: it can only ever add value to the vault.
    function seedBuffer(uint256 amount) external {
        IERC20(cfg.collateral).safeTransferFrom(msg.sender, address(this), amount);
        buffer.accrue(address(this), int256(_to18(amount)));
    }

    // ---------------------------------------------------------------- mint

    function mintInstant(uint256 amountIn) external returns (uint256 certOut) {
        if (!bootstrapped) revert CertVault_NotBootstrapped();
        if (!oracle.mintAllowed()) revert CertVault_MintPaused();

        uint256 px18 = oracle.px();
        uint256 fee = amountIn * cfg.mintFeeBps / 10_000;
        uint256 net18 = _to18(amountIn - fee);
        certOut = net18 * 1e18 / px18;

        uint256 notional18 = certOut * px18 / 1e18;
        if (notional18 > cfg.instantCap18) revert CertVault_AboveInstantCap();
        _requireCapacity(notional18);

        IERC20(cfg.collateral).safeTransferFrom(msg.sender, address(this), amountIn);
        certificate.mint(msg.sender, certOut);
        _hedge(certOut, px18, SIDE_BID);

        emit Minted(msg.sender, amountIn, certOut, px18, fee);
    }

    function requestMint(uint256 amountIn) external returns (uint256 receiptId) {
        if (!bootstrapped) revert CertVault_NotBootstrapped();
        if (!oracle.mintAllowed()) revert CertVault_MintPaused();

        uint256 px18 = oracle.px();
        uint256 fee = amountIn * cfg.mintFeeBps / 10_000;
        uint256 net18 = _to18(amountIn - fee);
        uint256 indicative = net18 * 1e18 / px18;
        uint256 notional18 = indicative * px18 / 1e18;
        if (notional18 <= cfg.instantCap18) revert CertVault_BelowInstantCap();
        _requireCapacity(notional18);

        IERC20(cfg.collateral).safeTransferFrom(msg.sender, address(this), amountIn);
        receiptId = _nextReceiptId++;
        mintReceipts[receiptId] = MintReceipt({user: msg.sender, escrow: amountIn - fee, settled: false});

        _hedge(indicative, px18, SIDE_BID);
        emit MintRequested(receiptId, msg.sender, amountIn);
    }

    /// @notice Mint at the price actually filled, so the vault carries no execution risk on
    ///         large mints. Permissionless — the fill price is checkable against the attestation.
    function settleMint(uint256 receiptId, uint256 fillPx18) external {
        MintReceipt storage r = mintReceipts[receiptId];
        if (r.user == address(0) || r.settled) revert CertVault_BadReceipt();
        r.settled = true;

        uint256 certOut = _to18(r.escrow) * 1e18 / fillPx18;
        certificate.mint(r.user, certOut);
        emit MintSettled(receiptId, certOut, fillPx18);
    }

    // ---------------------------------------------------------------- internals

    function _requireCapacity(uint256 addNotional18) internal view {
        uint256 max = capacity.maxNotional18(address(this), buffer.capacity18(address(this)));
        uint256 current = registry.latest(address(this)).notional18;
        if (current + addNotional18 > max) revert CertVault_AtCapacity();
    }

    /// @dev Submits the vault's own order through Lighter's priority queue. Market order because
    ///      the on-chain path exposes no IOC or post-only flag; price is passed as the guard band.
    function _hedge(uint256 certAmount18, uint256 px18, uint8 side) internal {
        uint48 baseAmount = uint48(certAmount18 * (10 ** cfg.sizeDecimals) / 1e18);
        uint32 tickPx = oracle.toTickPrice(px18);
        lighter.createOrder(lighterAccountIndex(), cfg.marketIndex, baseAmount, tickPx, side, ORDER_TYPE_MARKET);
    }

    function _to18(uint256 amount) internal view returns (uint256) {
        return _collateralDecimals <= 18
            ? amount * (10 ** (18 - _collateralDecimals))
            : amount / (10 ** (_collateralDecimals - 18));
    }

    function _from18(uint256 amount18) internal view returns (uint256) {
        return _collateralDecimals <= 18
            ? amount18 / (10 ** (18 - _collateralDecimals))
            : amount18 * (10 ** (_collateralDecimals - 18));
    }
}

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}

interface ILighterAccounts {
    function accountIndexOf(address) external view returns (uint48);
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `forge test --match-contract CertVaultMintTest -vv`
Expected: PASS, 11 tests.

- [ ] **Step 5: Commit**

```bash
git add src/CertVault.sol test/CertVaultMint.t.sol
git commit -m "feat(contracts): CertVault mint paths with self-submitted hedge and capacity gating"
```

---

## Task 9: CertVault — redeem paths

Law 2 is the invariant under test here. No redeem path may consult buffer health, capacity, or oracle-pause state.

**Files:**
- Modify: `src/CertVault.sol`
- Test: `test/CertVaultRedeem.t.sol`

**Interfaces:**
- Consumes: everything from Task 8.
- Produces:
  - `redeemInstant(uint256 certIn) returns (uint256 amountOut)`
  - `requestRedeem(uint256 certIn) returns (uint256 receiptId)`
  - `claimRedeem(uint256 receiptId) returns (uint256 amountOut)`
  - `forceExit(uint256 certIn) returns (uint256 receiptId)`
  - `closeAll()` — governance, wind-down.
  - `struct RedeemReceipt { address user; uint256 owed18; uint64 enqueuedAt; uint64 expiresAt; bool paid; }`
  - Errors: `CertVault_NothingToClaim()`.
  - Events `Redeemed`, `RedeemRequested`, `RedeemClaimed`, `ForceExited`.

- [ ] **Step 1: Write the failing test**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CertVault} from "../src/CertVault.sol";
import {VaultFixture} from "./helpers/VaultFixture.sol";

/// STEP 0 FOR THIS TASK — do this before writing any test below:
/// Move the whole of `CertVaultMintTest.setUp()` (Task 8) into a new
/// `test/helpers/VaultFixture.sol` as `abstract contract VaultFixture is Test`,
/// with every field it initialises (vault, cert, oracle, reg, cap, book, lighter,
/// usdg, feed, attester, gov, alice, PX, MARKET, ASSET_IDX) declared `internal`
/// and `setUp()` declared `public virtual` so Task 12 can extend it.
/// Then make `CertVaultMintTest` inherit it and delete its own setUp — Task 8's
/// tests must still pass unchanged. This file and Tasks 10 and 12 inherit the
/// same fixture. Do NOT copy setUp into three files.
contract CertVaultRedeemTest is VaultFixture {

    function test_redeemInstantPaysOracklePriceMinusFee() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        uint256 bal = cert.balanceOf(alice);

        vm.prank(alice);
        uint256 out = vault.redeemInstant(bal);
        assertGt(out, 0);
        assertEq(cert.balanceOf(alice), 0);
    }

    /// Law 2: this is the test that matters most in the whole suite.
    function test_redeemSucceedsWithBufferAtZeroAndOracleStale() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        uint256 bal = cert.balanceOf(alice);

        // drain the buffer completely
        vm.prank(address(vault));
        book.accrue(address(vault), -type(int256).max / 2);
        // and break the oracle
        vm.warp(block.timestamp + 100_000);

        vm.prank(alice);
        uint256 id = vault.forceExit(bal);
        assertGt(id, 0);
        assertEq(cert.balanceOf(alice), 0);
    }

    function test_redeemIgnoresCapacityLimits() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        uint256 bal = cert.balanceOf(alice);

        // report the vault as massively over capacity
        vm.prank(attester);
        reg.attest(address(vault), 2, 10_000_000e18, 0, 1e18);

        vm.prank(alice);
        vault.redeemInstant(bal); // must not revert
        assertEq(cert.balanceOf(alice), 0);
    }

    function test_requestRedeemBurnsImmediatelyAndQueuesExit() public {
        vm.prank(alice);
        uint256 id0 = vault.requestMint(50_000e6);
        lighter.settleBatch();
        vault.settleMint(id0, PX);
        uint256 bal = cert.balanceOf(alice);

        vm.prank(alice);
        uint256 id = vault.requestRedeem(bal);

        assertEq(cert.balanceOf(alice), 0); // burned up front
        (,, uint64 enqueuedAt, uint64 expiresAt,) = vault.redeemReceipts(id);
        assertEq(expiresAt - enqueuedAt, 14 days); // PRIORITY_EXPIRATION
    }

    function test_claimRedeemPaysOnceWithdrawalLands() public {
        vm.prank(alice);
        uint256 id0 = vault.requestMint(50_000e6);
        lighter.settleBatch();
        vault.settleMint(id0, PX);

        vm.prank(alice);
        uint256 id = vault.requestRedeem(cert.balanceOf(alice));
        lighter.settleBatch();

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.claimRedeem(id);
        assertGt(out, 0);
        assertEq(usdg.balanceOf(alice), before + out);
    }

    function test_claimTwiceReverts() public {
        vm.prank(alice);
        uint256 id0 = vault.requestMint(50_000e6);
        lighter.settleBatch();
        vault.settleMint(id0, PX);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(cert.balanceOf(alice));
        lighter.settleBatch();
        vm.prank(alice);
        vault.claimRedeem(id);

        vm.expectRevert(CertVault.CertVault_NothingToClaim.selector);
        vm.prank(alice);
        vault.claimRedeem(id);
    }

    function test_forceExitIsPermissionlessAndQueuesReduceOrder()  public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();
        uint256 bal = cert.balanceOf(alice);

        vm.prank(alice);
        vault.forceExit(bal);

        (,, , uint8 isAsk,) = lighter.lastOrder();
        assertEq(isAsk, 1); // selling to close
    }

    function test_closeAllUsesZeroBaseAmountPrimitive() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();

        vm.prank(gov);
        vault.closeAll();

        (, uint48 baseAmount,,,) = lighter.lastOrder();
        assertEq(baseAmount, 0); // 0 == "the entire position"
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `forge test --match-contract CertVaultRedeemTest`
Expected: compilation failure — redeem functions do not exist.

- [ ] **Step 3: Add the redeem section to `CertVault.sol`**

Insert after the mint section, before `// internals`.

```solidity
    // ---------------------------------------------------------------- redeem

    /// @dev PRIORITY_EXPIRATION on ZkLighter. The honest worst-case redemption SLA.
    uint64 internal constant PRIORITY_EXPIRATION = 14 days;

    struct RedeemReceipt {
        address user;
        uint256 owed18;
        uint64 enqueuedAt;
        uint64 expiresAt;
        bool paid;
    }

    mapping(uint256 => RedeemReceipt) public redeemReceipts;

    event Redeemed(address indexed user, uint256 certIn, uint256 amountOut, uint256 px18);
    event RedeemRequested(uint256 indexed receiptId, address indexed user, uint256 certIn, uint64 expiresAt);
    event RedeemClaimed(uint256 indexed receiptId, uint256 amountOut);
    event ForceExited(uint256 indexed receiptId, address indexed user, uint256 certIn);

    /// @notice Instant redemption from the hot buffer.
    /// @dev Deliberately reads NOTHING about buffer health, capacity, or oracle pause state.
    ///      Uses pxUnguarded so a stale feed cannot trap a holder (Law 2).
    function redeemInstant(uint256 certIn) external returns (uint256 amountOut) {
        (uint256 px18,) = oracle.pxUnguarded();
        uint256 gross18 = certIn * px18 / 1e18;
        uint256 fee18 = gross18 * cfg.redeemFeeBps / 10_000;
        amountOut = _from18(gross18 - fee18);

        certificate.burn(msg.sender, certIn);
        _hedge(certIn, px18, SIDE_ASK);
        IERC20(cfg.collateral).safeTransfer(msg.sender, amountOut);

        emit Redeemed(msg.sender, certIn, amountOut, px18);
    }

    /// @notice Queued redemption: burn now, close and withdraw through the priority queue.
    function requestRedeem(uint256 certIn) external returns (uint256 receiptId) {
        return _queueExit(certIn, false);
    }

    /// @notice Permissionless exit. Works with every off-chain service dead and the buffer empty.
    function forceExit(uint256 certIn) external returns (uint256 receiptId) {
        return _queueExit(certIn, true);
    }

    function _queueExit(uint256 certIn, bool isForce) internal returns (uint256 receiptId) {
        (uint256 px18,) = oracle.pxUnguarded();
        uint256 gross18 = certIn * px18 / 1e18;
        uint256 fee18 = gross18 * cfg.redeemFeeBps / 10_000;
        uint256 owed18 = gross18 - fee18;

        certificate.burn(msg.sender, certIn);

        receiptId = _nextReceiptId++;
        redeemReceipts[receiptId] = RedeemReceipt({
            user: msg.sender,
            owed18: owed18,
            enqueuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + PRIORITY_EXPIRATION,
            paid: false
        });

        _hedge(certIn, px18, SIDE_ASK);
        lighter.withdraw(
            lighterAccountIndex(), cfg.collateralAssetIndex, cfg.routeType, uint64(_from18(owed18))
        );

        if (isForce) emit ForceExited(receiptId, msg.sender, certIn);
        else emit RedeemRequested(receiptId, msg.sender, certIn, uint64(block.timestamp) + PRIORITY_EXPIRATION);
    }

    /// @notice Pull-payment once the queued withdrawal has landed.
    function claimRedeem(uint256 receiptId) external returns (uint256 amountOut) {
        RedeemReceipt storage r = redeemReceipts[receiptId];
        if (r.user == address(0) || r.paid) revert CertVault_NothingToClaim();

        amountOut = _from18(r.owed18);
        uint128 pending = lighter.getPendingBalance(address(this), cfg.collateralAssetIndex);
        if (pending >= amountOut) {
            lighter.withdrawPendingBalance(address(this), cfg.collateralAssetIndex, uint128(amountOut));
        }
        if (IERC20(cfg.collateral).balanceOf(address(this)) < amountOut) revert CertVault_NothingToClaim();

        r.paid = true;
        IERC20(cfg.collateral).safeTransfer(r.user, amountOut);
        emit RedeemClaimed(receiptId, amountOut);
    }

    /// @notice Wind-down: close the entire position using Lighter's baseAmount == 0 primitive.
    function closeAll() external {
        if (msg.sender != governance) revert CertVault_OnlyGovernance();
        (uint256 px18,) = oracle.pxUnguarded();
        lighter.createOrder(
            lighterAccountIndex(), cfg.marketIndex, 0, oracle.toTickPrice(px18), SIDE_ASK, ORDER_TYPE_MARKET
        );
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `forge test --match-contract CertVaultRedeemTest -vv`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add src/CertVault.sol test/CertVaultRedeem.t.sol
git commit -m "feat(contracts): CertVault redeem tiers with permissionless forceExit (Law 2)"
```

---

## Task 10: CertVault — rebalance and solvency view

**Files:**
- Modify: `src/CertVault.sol`
- Test: `test/CertVaultRebalance.t.sol`

**Interfaces:**
- Consumes: everything from Tasks 8 and 9.
- Produces:
  - `rebalance()` — permissionless, bounded notional per call, pays a bounty.
  - `solvency() returns (Solvency memory)` where
    `struct Solvency { uint256 supply; uint256 notional18; uint256 margin18; int256 buffer18; uint256 deltaBps; uint64 provenAtBatch; uint256 ageSec; }`
  - `accrueFunding(int256 delta18)` — permissionless relay into `BufferBook`; reverts unless the caller is the attester.
  - Errors: `CertVault_InBand()`.

- [ ] **Step 1: Write the failing test**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CertVault} from "../src/CertVault.sol";
import {VaultFixture} from "./helpers/VaultFixture.sol";

contract CertVaultRebalanceTest is VaultFixture {

    function test_solvencyReportsBackingWithProvenanceAndAge() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);

        vm.prank(attester);
        reg.attest(address(vault), 2, 3_554e18, 3_600e18, 1_190_000e18);
        vm.warp(block.timestamp + 45);

        CertVault.Solvency memory s = vault.solvency();
        assertEq(s.supply, cert.totalSupply());
        assertEq(s.notional18, 3_554e18);
        assertEq(s.margin18, 3_600e18);
        assertEq(s.provenAtBatch, 2);
        assertEq(s.ageSec, 45); // age is PUBLISHED, never hidden
    }

    function test_rebalanceRevertsWhenDeltaIsInBand() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();

        vm.prank(attester);
        reg.attest(address(vault), 2, 3_554e18, 3_600e18, 1_190_000e18);

        vm.expectRevert(CertVault.CertVault_InBand.selector);
        vault.rebalance();
    }

    function test_rebalanceTrimsDeltaWhenUnderHedged() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();

        // report only half the needed notional -> under-hedged, out of band
        vm.prank(attester);
        reg.attest(address(vault), 2, 1_777e18, 3_600e18, 1_190_000e18);

        vault.rebalance();
        assertEq(lighter.queuedOrderCount(), 1);
        (,,, uint8 isAsk,) = lighter.lastOrder();
        assertEq(isAsk, 0); // buy more to close the gap
    }

    function test_rebalanceIsPermissionless() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();
        vm.prank(attester);
        reg.attest(address(vault), 2, 1_777e18, 3_600e18, 1_190_000e18);

        vm.prank(makeAddr("stranger")); // a stranger
        vault.rebalance();
        assertEq(lighter.queuedOrderCount(), 1);
    }

    function test_rebalanceBoundsNotionalPerCall() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(500_000e6);
        lighter.settleBatch();
        vault.settleMint(id, PX);

        vm.prank(attester);
        reg.attest(address(vault), 2, 0, 600_000e18, 1_190_000e18); // fully unhedged

        vault.rebalance();
        (, uint48 baseAmount,,,) = lighter.lastOrder();
        // capped at maxRebalanceNotional18 (10k) -> 10000/355.86 = 28.1 TSLA -> 281_0xx ticks
        assertLt(baseAmount, 300_000);
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `forge test --match-contract CertVaultRebalanceTest`
Expected: compilation failure — `rebalance` and `solvency` do not exist.

- [ ] **Step 3: Add the section to `CertVault.sol`**

```solidity
    // ---------------------------------------------------------------- solvency & rebalance

    error CertVault_InBand();

    /// @dev delta tolerance in bps, and the maximum notional a single rebalance may move.
    uint256 public constant DELTA_BAND_BPS = 100;
    uint256 public constant MAX_REBALANCE_NOTIONAL_18 = 10_000e18;

    struct Solvency {
        uint256 supply;
        uint256 notional18;
        uint256 margin18;
        int256 buffer18;
        uint256 deltaBps;
        uint64 provenAtBatch;
        uint256 ageSec;
    }

    /// @notice Public backing figure. Always carries provenAtBatch and ageSec — the age is part
    ///         of the answer, never omitted.
    function solvency() external view returns (Solvency memory s) {
        ISolvencyRegistry.Attestation memory a = registry.latest(address(this));
        (uint256 px18,) = oracle.pxUnguarded();

        s.supply = certificate.totalSupply();
        s.notional18 = a.notional18;
        s.margin18 = a.margin18;
        s.buffer18 = buffer.balance18(address(this));
        s.provenAtBatch = a.batchId;
        s.ageSec = registry.ageSec(address(this));

        uint256 required = s.supply * px18 / 1e18;
        s.deltaBps = required == 0 ? 10_000 : a.notional18 * 10_000 / required;
    }

    /// @notice Permissionless delta trim. Anyone may call; a bounty makes it worth doing.
    function rebalance() external {
        Solvency memory s = this.solvency();
        (uint256 px18,) = oracle.pxUnguarded();
        uint256 required = s.supply * px18 / 1e18;

        uint256 lo = 10_000 - DELTA_BAND_BPS;
        uint256 hi = 10_000 + DELTA_BAND_BPS;
        if (s.deltaBps >= lo && s.deltaBps <= hi) revert CertVault_InBand();

        bool underHedged = s.notional18 < required;
        uint256 gap18 = underHedged ? required - s.notional18 : s.notional18 - required;
        if (gap18 > MAX_REBALANCE_NOTIONAL_18) gap18 = MAX_REBALANCE_NOTIONAL_18;

        uint256 certEquivalent = gap18 * 1e18 / px18;
        _hedge(certEquivalent, px18, underHedged ? SIDE_BID : SIDE_ASK);
    }

    /// @notice Relay accrued funding, execution variance and realised basis into the buffer.
    function accrueFunding(int256 delta18) external {
        if (msg.sender != ICertOracleAttester(address(oracle)).attester()) revert CertVault_OnlyAttester();
        buffer.accrue(address(this), delta18);
    }
```

Add at the bottom of the file:

```solidity
interface ICertOracleAttester {
    function attester() external view returns (address);
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `forge test --match-contract CertVaultRebalanceTest -vv`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add src/CertVault.sol test/CertVaultRebalance.t.sol
git commit -m "feat(contracts): CertVault permissionless rebalance and solvency view with age"
```

---

## Task 11: CertFactory

**Files:**
- Create: `src/CertFactory.sol`
- Test: `test/CertFactory.t.sol`

**Interfaces:**
- Consumes: `CertVault` (T8–10), `CertOracle` (T4), `CapacityOracle` (T6), `SolvencyRegistry` (T5).
- Produces:
  - `deployVault(...) returns (address vault, address certificate)`
  - `vaults(uint256) returns (address)`, `vaultCount() returns (uint256)`
  - `enabled(address vault) returns (bool)` — false until the Lighter account index resolves.
  - `enable(address vault)` — permissionless; only succeeds once bootstrap has landed.
  - Errors: `CertFactory_OnlyGovernance()`, `CertFactory_NotRegisteredYet()`.

- [ ] **Step 1: Write the failing test**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CertFactory} from "../src/CertFactory.sol";
import {CertVault} from "../src/CertVault.sol";
import {Certificate} from "../src/Certificate.sol";
import {CertOracle} from "../src/CertOracle.sol";
import {SolvencyRegistry} from "../src/SolvencyRegistry.sol";
import {CapacityOracle} from "../src/CapacityOracle.sol";
import {MockLighter} from "./mocks/MockLighter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

contract CertFactoryTest is Test {
    CertFactory factory;
    SolvencyRegistry reg;
    CapacityOracle cap;
    CertOracle oracle;
    MockLighter lighter;
    MockERC20 usdg;
    MockAggregatorV3 feed;

    address gov = makeAddr("gov");
    address attester = makeAddr("attester");

    function setUp() public {
        vm.warp(1_800_000_000);
        usdg = new MockERC20("USDG", "USDG", 6);
        feed = new MockAggregatorV3(8, 355_86000000);
        lighter = new MockLighter(IERC20(address(usdg)), 3);
        reg = new SolvencyRegistry(attester);
        cap = new CapacityOracle(address(reg), gov, 1000, 100, 3000, 300);
        oracle = new CertOracle(address(feed), attester, 2, 3600, 500, 100);
        factory = new CertFactory(address(lighter), address(reg), address(cap), gov);
        usdg.mint(address(factory), 1_000e6);
    }

    function _deploy() internal returns (address v) {
        vm.prank(gov);
        (v,) = factory.deployVault(
            address(oracle), address(usdg), 3, 0, 16, 4, 10, 10, 10_000e18, 500, "UseCert TSLA", "uTSLA"
        );
    }

    function test_deployVaultCreatesPairAndRegisters() public {
        address v = _deploy();
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.vaults(0), v);
        assertEq(Certificate(CertVault(v).certificate()).symbol(), "uTSLA");
    }

    function test_vaultStartsDisabled() public {
        address v = _deploy();
        assertFalse(factory.enabled(v));
    }

    function test_enableRevertsBeforeBootstrapLands() public {
        address v = _deploy();
        vm.expectRevert(CertFactory.CertFactory_NotRegisteredYet.selector);
        factory.enable(v);
    }

    function test_enableSucceedsOnceAccountIndexResolves() public {
        address v = _deploy();
        usdg.mint(address(this), 100e6);
        usdg.approve(v, type(uint256).max);
        CertVault(v).bootstrap();
        lighter.settleBatch();

        factory.enable(v); // permissionless
        assertTrue(factory.enabled(v));
    }

    function test_onlyGovernanceMayDeploy() public {
        vm.expectRevert(CertFactory.CertFactory_OnlyGovernance.selector);
        factory.deployVault(
            address(oracle), address(usdg), 3, 0, 16, 4, 10, 10, 10_000e18, 500, "UseCert TSLA", "uTSLA"
        );
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `forge test --match-contract CertFactoryTest`
Expected: compilation failure — `CertFactory.sol` does not exist.

- [ ] **Step 3: Write the implementation**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {CertVault} from "./CertVault.sol";

/// @notice Deploys and sequences vault bootstrap. A vault stays disabled until Lighter has
///         actually assigned it an account index, because createOrder reverts with
///         AccountIsNotRegistered until the registering deposit has been executed by a batch.
contract CertFactory {
    error CertFactory_OnlyGovernance();
    error CertFactory_NotRegisteredYet();

    event VaultDeployed(address indexed vault, address indexed certificate, uint16 marketIndex);
    event VaultEnabled(address indexed vault);

    address public immutable lighter;
    address public immutable registry;
    address public immutable capacity;
    address public immutable governance;

    address[] public vaults;
    mapping(address => bool) public enabled;

    constructor(address _lighter, address _registry, address _capacity, address _governance) {
        lighter = _lighter;
        registry = _registry;
        capacity = _capacity;
        governance = _governance;
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    function deployVault(
        address oracle,
        address collateral,
        uint16 collateralAssetIndex,
        uint8 routeType,
        uint16 marketIndex,
        uint8 sizeDecimals,
        uint256 mintFeeBps,
        uint256 redeemFeeBps,
        uint256 instantCap18,
        uint256 settleBandBps,
        string memory name_,
        string memory symbol_
    ) external returns (address vault, address certificate) {
        if (msg.sender != governance) revert CertFactory_OnlyGovernance();

        CertVault v = new CertVault(
            CertVault.Deps({
                lighter: lighter,
                oracle: oracle,
                registry: registry,
                capacity: capacity,
                governance: governance
            }),
            CertVault.VaultConfig({
                collateral: collateral,
                collateralAssetIndex: collateralAssetIndex,
                routeType: routeType,
                marketIndex: marketIndex,
                sizeDecimals: sizeDecimals,
                mintFeeBps: mintFeeBps,
                redeemFeeBps: redeemFeeBps,
                instantCap18: instantCap18,
                settleBandBps: settleBandBps
            }),
            name_,
            symbol_
        );

        vault = address(v);
        certificate = address(v.certificate());
        vaults.push(vault);
        emit VaultDeployed(vault, certificate, marketIndex);
    }

    /// @notice Permissionless: it can only ever succeed once the chain says the account exists.
    function enable(address vault) external {
        if (CertVault(vault).lighterAccountIndex() == 0) revert CertFactory_NotRegisteredYet();
        enabled[vault] = true;
        emit VaultEnabled(vault);
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `forge test --match-contract CertFactoryTest -vv`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add src/CertFactory.sol test/CertFactory.t.sol
git commit -m "feat(contracts): CertFactory with bootstrap sequencing and permissionless enable"
```

---

## Task 12: Backing invariant suite

The two properties that must hold under any sequence of calls: backing never falls below supply at price, and redemption never reverts because of buffer state.

**Files:**
- Create: `test/invariant/BackingInvariant.t.sol`
- Create: `test/invariant/VaultHandler.sol`

**Interfaces:**
- Consumes: the full contract set.
- Produces: `invariant_redemptionNeverBlockedByBuffer()`, `invariant_supplyMatchesMintedMinusBurned()`, `invariant_capacityNeverExceedsAbsoluteCap()`.

- [ ] **Step 1: Write the handler**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {CertVault} from "../../src/CertVault.sol";
import {Certificate} from "../../src/Certificate.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockLighter} from "../mocks/MockLighter.sol";

/// @notice Drives randomised mint/redeem/settle sequences against one vault.
contract VaultHandler is CommonBase, StdUtils {
    CertVault public immutable vault;
    Certificate public immutable cert;
    MockERC20 public immutable usdg;
    MockLighter public immutable lighter;

    uint256 public totalMinted;
    uint256 public totalBurned;
    uint256 public redeemReverts;

    constructor(CertVault _vault, MockERC20 _usdg, MockLighter _lighter) {
        vault = _vault;
        cert = Certificate(_vault.certificate());
        usdg = _usdg;
        lighter = _lighter;
    }

    function mint(uint256 amount) external {
        amount = bound(amount, 11e6, 5_000e6);
        usdg.mint(address(this), amount);
        usdg.approve(address(vault), amount);
        try vault.mintInstant(amount) returns (uint256 out) {
            totalMinted += out;
        } catch {}
    }

    function redeem(uint256 amount) external {
        uint256 bal = cert.balanceOf(address(this));
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        try vault.redeemInstant(amount) {
            totalBurned += amount;
        } catch {
            // Law 2: any revert here is a violation, recorded for the invariant.
            redeemReverts += 1;
        }
    }

    function settle() external {
        lighter.settleBatch();
    }
}
```

- [ ] **Step 2: Write the invariant test**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultHandler} from "./VaultHandler.sol";
import {VaultFixture} from "../helpers/VaultFixture.sol";

contract BackingInvariantTest is VaultFixture {
    VaultHandler handler;

    /// @dev VaultFixture.setUp() already builds the stack, seeds the buffer,
    ///      bootstraps and settles. Extend it, do not rebuild it.
    function setUp() public override {
        super.setUp();
        handler = new VaultHandler(vault, usdg, lighter);
        targetContract(address(handler));
    }

    /// Law 2, expressed as an invariant.
    function invariant_redemptionNeverBlockedByBuffer() public view {
        assertEq(handler.redeemReverts(), 0);
    }

    function invariant_supplyMatchesMintedMinusBurned() public view {
        assertEq(cert.totalSupply(), handler.totalMinted() - handler.totalBurned());
    }

    function invariant_capacityNeverExceedsAbsoluteCap() public view {
        uint256 max = cap.maxNotional18(address(vault), type(uint256).max);
        assertLe(max, cap.absoluteCap18(address(vault)));
    }
}
```

- [ ] **Step 3: Run the invariants**

Run: `forge test --match-contract BackingInvariantTest -vv`
Expected: PASS, 3 invariants, 256 runs each.

- [ ] **Step 4: Run the whole suite with gas reporting**

Run: `forge test --gas-report`
Expected: all tests pass. Record `mintInstant` and `redeemInstant` gas — these feed O-9.

- [ ] **Step 5: Commit**

```bash
git add test/invariant/
git commit -m "test(contracts): invariant suite for Law 2 and capacity bounds"
```

---

## Self-Review

**Spec coverage.** Design laws 1, 2, 3 and 6 each have named tests (delta band in T10, `forceExit` and the buffer-drained redeem in T9 plus the T12 invariant, `BufferBook` thresholds in T7, self-submitted hedge in T8). Law 4's draw order is exposed by `BufferBook.insuranceDrawNeeded` but `InsuranceStaking` is C3 — noted in File Structure. Law 5 is a copy constraint, not code. Section 15.1's capacity formula is T6 including the growth test. Section 8's staged solvency is T5 with the C2 upgrade path documented in the contract. Section 3.3's bootstrap is T8 and T11. Section 6's dual mint paths are T8; Section 7's three redeem tiers are T9. `Zap.sol` and route B are explicitly deferred with reasons.

**Known gaps, deliberate.** `FeeVault` fee routing (80/10/5/5) is not in C1's contract set — fees accrue in the vault and route in C3 with `CERT.sol`. The off-chain attester, prover and workers are the separate services plan.

**Type consistency.** `_to18`/`_from18`, `_hedge(certAmount18, px18, side)`, `SIDE_BID`/`SIDE_ASK`, `ORDER_TYPE_MARKET`, `maxNotional18(asset, bufferCapacity18)`, `capacity18(asset)`, `latest(asset)`/`ageSec(asset)`, and `lighterAccountIndex()` are used identically across Tasks 6, 8, 9, 10 and 11. `Attestation` field names match between T5's definition and T10's consumption.

**Pre-flight corrections applied before execution (2026-09-07).** Four defects in the first draft of this plan were fixed by the plan author before any task was dispatched:

1. **Invalid address literals.** `address(0x60V)`, `address(0xTS1A)` and `address(0xVA17)` contain non-hex characters and would not compile. All test addresses now use forge-std `makeAddr("name")`, which also labels them in traces.
2. **`CapacityOracle.setAbsoluteCap` had a first-call loophole** (`msg.sender != governance && absoluteCap18[asset] != 0`), letting anyone front-run the cap for a new asset. Since `absoluteCap` is the one value that bounds a compromised attester, this is now governance-only with no exception, and the three call sites are pranked as `gov`.
3. **`closeAll()` and `accrueFunding()` reverted with `CertVault_MintPaused`** for authorisation failures, which is a misleading error. Added `CertVault_OnlyGovernance` and `CertVault_OnlyAttester`.
4. **Mandated `setUp()` duplication across three test files** — an instruction a reviewer would rightly flag as duplication. Task 9 now extracts the shared stack into `test/helpers/VaultFixture.sol` and Tasks 9, 10 and 12 inherit it. The original worry (a drifting shared harness making the Law 2 tests untrustworthy) is answered by the fixture being `abstract` with a `virtual setUp`, and by Task 8's tests having to keep passing unchanged after the extraction.

---

## Execution Handoff

Plan complete. Two execution options:

1. **Subagent-Driven (recommended)** — a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session with checkpoints.

Foundry must be installed first (see Prerequisite).
