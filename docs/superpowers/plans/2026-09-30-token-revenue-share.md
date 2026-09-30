# Stack 6 Token Revenue Share Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the three stack-6 revenue-share contracts from `docs/superpowers/specs/2026-09-30-token-revenue-share-design.md`: RevenueRouter (insurance-first fee split), Buyback (hourly guarded buys, 50/50 burn and stake), and TokenStaking (Staking v3, weighted 7-day vesting, 7-day exit cooldown).

**Architecture:** Three small immutable contracts with no owner and no pause. Vault fees land in RevenueRouter, which credits insurance / Buyback / ops / treasury by a coverage-dependent split (pull model, like FeeVault). Buyback spends its USDG in capped hourly tranches on the token's Uniswap-V2-style pair, guarded by its own 30-minute average price, burns half of what it buys and funds TokenStaking with the other half. TokenStaking streams each funding over a weighted ~7-day window and pays nothing to stake that is leaving.

**Tech Stack:** Solidity 0.8.24, Foundry (forge 1.x), OpenZeppelin v5 (`openzeppelin-contracts/`), `evm_version = shanghai`, optimizer 200 runs, `via_ir = false`.

## Global Constraints

- Solidity `pragma solidity 0.8.24;`, SPDX `MIT` for `src/`, `UNLICENSED` for `test/` (as the repo does).
- Imports only from `openzeppelin-contracts/…` and `forge-std/…` (the repo's remappings). No new dependencies.
- No owner, no pause, no upgrade path in any of the three contracts. The only governance actions: RevenueRouter `proposeTarget`/`applyTarget` (bounds [200, 1000] bps, 2-day delay) and Buyback `proposePool`/`applyPool` (once, 2-day delay).
- Router split, exactly: coverage < target → 50/30/10/10 (insurance/token/ops/treasury); coverage ≥ target → 0/80/10/10; insurance pool with zero shares → 0/30/10/60.
- Buyback: `BUY_INTERVAL = 1 hours`, TWAP window `[30 minutes, 2 hours]`, price guard 200 bps (≥ 98% of the average-price amount), tranche `min(TRANCHE_MAX, 1% of the pair's USDG reserve, balance)`, caller reward `min(CALLER_REWARD_MAX, 1% of the tranche)`.
- TokenStaking: `DURATION = 7 days` weighted end `now + (R·(end−now) + X·DURATION)/(R+X)`; `COOLDOWN = 7 days`; stake in cooldown earns nothing.
- Commits carry no AI or co-author trailer (repo rule).
- Do not edit `test/AuditPoC.t.sol` or `test/AttackSuite.t.sol`. After any `forge test` run, restore `deployments/` with `git checkout -- deployments/` if it changed.
- One deviation from the spec, decided here: the token's `burn` support is a constructor argument (`tokenHasBurn`), not probed at construction — a probe of a state-changing `burn(0)` is unreliable across token implementations. Task 3 updates the spec line.

## File Structure

| File | Responsibility |
|---|---|
| `src/revshare/TokenStaking.sol` | Staking v3: stake, weighted-vesting rewards, cooldown exits |
| `src/revshare/RevenueRouter.sol` | Coverage-dependent split of vault fees; pull-based claims; target setting |
| `src/revshare/Buyback.sol` | Pair set once; hourly guarded buys; 50/50 burn and stake |
| `src/revshare/interfaces/IRevShare.sol` | The narrow interfaces the three use (vault, oracle, factory, insurance pool, V2 pair, staking funding) |
| `test/revshare/mocks/MockV2Pair.sol` | A Uniswap-V2-compatible pair (reserves, 0.3% fee swap, cumulative prices) |
| `test/revshare/mocks/MockBurnableERC20.sol` | An 18-decimal token with `burn(uint256)` |
| `test/revshare/mocks/MockRevShareVault.sol` | A vault/oracle/factory/insurance stand-in for the router |
| `test/revshare/TokenStaking.t.sol` | Staking unit, attack and fuzz tests |
| `test/revshare/RevenueRouter.t.sol` | Router split, pull, target-delay tests |
| `test/revshare/Buyback.t.sol` | Buyback pool-setting, guard, tranche, split tests |
| `test/revshare/RevShareFlow.t.sol` | End to end: router → buyback → staking, and the attack tests |
| `test/revshare/RevShareFork.t.sol` | Fork test against a real graduated V2 pair on Robinhood Chain |

---

### Task 1: TokenStaking (Staking v3)

**Files:**
- Create: `src/revshare/interfaces/IRevShare.sol`
- Create: `test/revshare/mocks/MockBurnableERC20.sol`
- Create: `src/revshare/TokenStaking.sol`
- Test: `test/revshare/TokenStaking.t.sol`

**Interfaces:**
- Produces: `TokenStaking(IERC20 token)`; `stake(uint256)`, `requestUnstake(uint256)`, `withdraw()`, `getReward()`, `notifyRewardAmount(uint256)`, views `earned(address) returns (uint256)`, `totalStaked() returns (uint256)`, `balanceOf(address)`, `unstaking(address) returns (uint256 amount, uint64 readyAt)`, `periodFinish()`, `rewardRate()`, `DURATION()`, `COOLDOWN()`, `token()`.
- Produces in `IRevShare.sol`: `interface ITokenStaking { function totalStaked() external view returns (uint256); function notifyRewardAmount(uint256 amount) external; }` (used by Buyback).

- [ ] **Step 1: Write the interfaces file**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice The narrow views and calls the stack-6 revenue-share contracts need from their neighbours.
interface ITokenStaking {
    function totalStaked() external view returns (uint256);
    function notifyRewardAmount(uint256 amount) external;
}

interface IRevShareVault {
    function certificate() external view returns (address);
    function oracle() external view returns (address);
}

interface IPxOracle {
    function pxUnguarded() external view returns (uint256 px18, uint256 observedAt);
}

interface IVaultFactory {
    function vaultCount() external view returns (uint256);
    function vaults(uint256 i) external view returns (address);
}

interface IInsurancePool {
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IUniswapV2PairLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}
```

- [ ] **Step 2: Write the burnable token mock**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";

contract MockBurnableERC20 is ERC20 {
    constructor() ERC20("Token", "TKN") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function burn(uint256 amt) external {
        _burn(msg.sender, amt);
    }
}
```

- [ ] **Step 3: Write the failing tests**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockBurnableERC20} from "./mocks/MockBurnableERC20.sol";
import {TokenStaking} from "../../src/revshare/TokenStaking.sol";

contract TokenStakingTest is Test {
    MockBurnableERC20 tkn;
    TokenStaking st;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address funder = address(0xF00D);

    function setUp() public {
        vm.warp(1_000_000);
        tkn = new MockBurnableERC20();
        st = new TokenStaking(tkn);
        for (uint256 i = 0; i < 3; i++) {
            address a = [alice, bob, funder][i];
            tkn.mint(a, 100_000_000e18);
            vm.prank(a);
            tkn.approve(address(st), type(uint256).max);
        }
    }

    function _fund(uint256 x) internal {
        vm.prank(funder);
        st.notifyRewardAmount(x);
    }

    function test_fundingStreamsOverAWeek() public {
        vm.prank(alice);
        st.stake(1_000e18);
        _fund(700e18);
        assertEq(st.periodFinish(), block.timestamp + 7 days);
        skip(7 days);
        assertApproxEqAbs(st.earned(alice), 700e18, 1e6);
    }

    function test_twoStakersShareByStake() public {
        vm.prank(alice);
        st.stake(1_000e18);
        vm.prank(bob);
        st.stake(3_000e18);
        _fund(400e18);
        skip(7 days);
        assertApproxEqAbs(st.earned(alice), 100e18, 1e6);
        assertApproxEqAbs(st.earned(bob), 300e18, 1e6);
    }

    /// Sermium M-01: staking one hour before a large late funding must capture < 1% of it.
    function test_jitCaptureOfALateFundingIsBelowOnePercent() public {
        vm.prank(alice);
        st.stake(1_000_000e18);
        _fund(70e18);                                      // the base weekly stream
        skip(7 days - 1 hours);
        vm.prank(bob);
        st.stake(9_000_000e18);                            // the attacker, an hour before the end
        _fund(1_000e18);                                   // the large late funding
        skip(1 hours);
        vm.prank(bob);
        st.requestUnstake(9_000_000e18);                   // stops earning at once
        uint256 fromFunding = st.earned(bob);
        assertLt(fromFunding, 10e18, "attacker captured >= 1% of the funding");
    }

    /// Sermium L-01: a dust funding every hour must not hold back vesting by more than 1%.
    function test_dustFundingsBarelyDelayVesting() public {
        vm.prank(alice);
        st.stake(1_000e18);
        _fund(700e18);
        for (uint256 i = 0; i < 168; i++) {
            skip(1 hours);
            _fund(1);
        }
        assertGt(st.earned(alice), 693e18, "more than 1% still unvested after a week");
    }

    function test_cooldownStakeEarnsNothingAndWithdrawsAfterSevenDays() public {
        vm.prank(alice);
        st.stake(1_000e18);
        vm.prank(bob);
        st.stake(1_000e18);
        _fund(700e18);
        skip(1 days);
        vm.prank(bob);
        st.requestUnstake(1_000e18);
        uint256 bobAt = st.earned(bob);
        skip(6 days);
        assertEq(st.earned(bob), bobAt, "stake in cooldown kept earning");
        vm.prank(bob);
        vm.expectRevert(TokenStaking.TokenStaking_CooldownNotOver.selector);
        st.withdraw();
        skip(1 days);
        uint256 before = tkn.balanceOf(bob);
        vm.prank(bob);
        st.withdraw();
        assertEq(tkn.balanceOf(bob) - before, 1_000e18);
    }

    function test_rewardAccruedWithNobodyStakedIsCarried() public {
        _fund(700e18);
        skip(3 days);
        vm.prank(alice);
        st.stake(1_000e18);
        _fund(1e18);                                        // folds the carried amount back in
        skip(8 days);
        assertApproxEqAbs(st.earned(alice), 701e18, 1e9);
    }

    function test_getRewardPays() public {
        vm.prank(alice);
        st.stake(1_000e18);
        _fund(700e18);
        skip(7 days);
        uint256 before = tkn.balanceOf(alice);
        vm.prank(alice);
        st.getReward();
        assertApproxEqAbs(tkn.balanceOf(alice) - before, 700e18, 1e6);
    }

    function test_zeroAmountsRefused() public {
        vm.expectRevert(TokenStaking.TokenStaking_ZeroAmount.selector);
        st.stake(0);
        vm.expectRevert(TokenStaking.TokenStaking_ZeroAmount.selector);
        st.notifyRewardAmount(0);
    }

    /// Solvency: what the contract owes never exceeds what it holds.
    function testFuzz_solvency(uint96 a, uint96 b, uint96 f1, uint96 f2, uint32 dt1, uint32 dt2) public {
        a = uint96(bound(a, 1, 10_000_000e18));
        b = uint96(bound(b, 1, 10_000_000e18));
        f1 = uint96(bound(f1, 1, 1_000_000e18));
        f2 = uint96(bound(f2, 1, 1_000_000e18));
        vm.prank(alice);
        st.stake(a);
        _fund(f1);
        skip(bound(dt1, 0, 30 days));
        vm.prank(bob);
        st.stake(b);
        _fund(f2);
        skip(bound(dt2, 0, 30 days));
        uint256 owed = st.earned(alice) + st.earned(bob) + st.totalStaked() + st.remainingReward() + st.carried();
        assertLe(owed, tkn.balanceOf(address(st)));
    }
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `forge test --match-path test/revshare/TokenStaking.t.sol -vv`
Expected: compilation FAIL (`TokenStaking.sol` does not exist).

- [ ] **Step 5: Write TokenStaking**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

/// @title TokenStaking - stack-6 Staking v3: stake the token, earn the token
/// @notice Each funding vests over a weighted window: the stream's end moves to
///         now + (R·(end−now) + X·DURATION)/(R+X), R the reward still to stream and X the new
///         funding. A large funding therefore streams over close to a full week however late it
///         lands (Sermium M-01), and a dust funding barely moves the end (L-01). Leaving takes
///         COOLDOWN, and stake that is leaving earns nothing (the rolling-escrow advantage of M-2).
///         No owner, no pause, no stake cap (L-04). Funding is permissionless.
/// @dev Accounting is in `PRECISION`-scaled token units: rewardRate is tokens·PRECISION per
///      second; `carriedScaled` holds reward that streamed while nothing was staked plus every
///      rounding remainder, and is folded into the next funding. Invariant (fuzzed):
///      earned(all) + totalStaked + totalUnstaking + remainingReward + carried <= balance.
contract TokenStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error TokenStaking_ZeroAmount();
    error TokenStaking_InsufficientStake();
    error TokenStaking_CooldownNotOver();
    error TokenStaking_NothingUnstaking();

    event Staked(address indexed user, uint256 amount);
    event UnstakeRequested(address indexed user, uint256 amount, uint64 readyAt);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event RewardAdded(address indexed funder, uint256 received, uint256 rewardRate, uint256 periodFinish);

    uint256 public constant DURATION = 7 days;
    uint256 public constant COOLDOWN = 7 days;
    uint256 public constant PRECISION = 1e18;

    IERC20 public immutable token;

    uint256 public totalStaked;
    uint256 public totalUnstaking;
    mapping(address => uint256) public balanceOf;

    struct Unstake {
        uint256 amount;
        uint64 readyAt;
    }

    mapping(address => Unstake) public unstaking;

    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public carriedScaled;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    constructor(IERC20 token_) {
        token = token_;
    }

    // ------------------------------------------------------------------ views
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        uint256 t = lastTimeRewardApplicable();
        if (t <= lastUpdateTime) return rewardPerTokenStored;
        return rewardPerTokenStored + rewardRate * (t - lastUpdateTime) / totalStaked;
    }

    function earned(address a) public view returns (uint256) {
        return balanceOf[a] * (rewardPerToken() - userRewardPerTokenPaid[a]) / PRECISION + rewards[a];
    }

    function remainingReward() public view returns (uint256) {
        if (block.timestamp >= periodFinish) return 0;
        return rewardRate * (periodFinish - block.timestamp) / PRECISION;
    }

    /// @notice Reward carried for the next funding: streamed while nothing was staked, plus rounding.
    function carried() public view returns (uint256) {
        uint256 c = carriedScaled;
        if (totalStaked == 0) {
            uint256 t = lastTimeRewardApplicable();
            if (t > lastUpdateTime) c += rewardRate * (t - lastUpdateTime);
        }
        return c / PRECISION;
    }

    // ------------------------------------------------------------------ bookkeeping
    function _update(address a) internal {
        uint256 t = lastTimeRewardApplicable();
        if (t > lastUpdateTime) {
            uint256 streamed = rewardRate * (t - lastUpdateTime);
            if (totalStaked == 0) {
                carriedScaled += streamed;
            } else {
                rewardPerTokenStored += streamed / totalStaked;
                carriedScaled += streamed % totalStaked;
            }
        }
        lastUpdateTime = t > lastUpdateTime ? t : lastUpdateTime;
        if (a != address(0)) {
            rewards[a] = earned(a);
            userRewardPerTokenPaid[a] = rewardPerTokenStored;
        }
    }

    // ------------------------------------------------------------------ staking
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert TokenStaking_ZeroAmount();
        _update(msg.sender);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        balanceOf[msg.sender] += received;
        totalStaked += received;
        emit Staked(msg.sender, received);
    }

    /// @notice Move `amount` of active stake into the cooldown. It stops earning at once. A new
    ///         request adds to the pending one and restarts its clock.
    function requestUnstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert TokenStaking_ZeroAmount();
        if (amount > balanceOf[msg.sender]) revert TokenStaking_InsufficientStake();
        _update(msg.sender);
        balanceOf[msg.sender] -= amount;
        totalStaked -= amount;
        totalUnstaking += amount;
        Unstake storage u = unstaking[msg.sender];
        u.amount += amount;
        u.readyAt = uint64(block.timestamp + COOLDOWN);
        emit UnstakeRequested(msg.sender, amount, u.readyAt);
    }

    function withdraw() external nonReentrant {
        Unstake memory u = unstaking[msg.sender];
        if (u.amount == 0) revert TokenStaking_NothingUnstaking();
        if (block.timestamp < u.readyAt) revert TokenStaking_CooldownNotOver();
        delete unstaking[msg.sender];
        totalUnstaking -= u.amount;
        token.safeTransfer(msg.sender, u.amount);
        emit Withdrawn(msg.sender, u.amount);
    }

    function getReward() external nonReentrant {
        _update(msg.sender);
        uint256 r = rewards[msg.sender];
        if (r == 0) return;
        rewards[msg.sender] = 0;
        token.safeTransfer(msg.sender, r);
        emit RewardPaid(msg.sender, r);
    }

    // ------------------------------------------------------------------ funding
    function notifyRewardAmount(uint256 amount) external nonReentrant {
        if (amount == 0) revert TokenStaking_ZeroAmount();
        _update(address(0));
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 x = token.balanceOf(address(this)) - before;

        uint256 remainingScaled = block.timestamp < periodFinish ? rewardRate * (periodFinish - block.timestamp) : 0;
        uint256 left = block.timestamp < periodFinish ? periodFinish - block.timestamp : 0;
        uint256 r = remainingScaled / PRECISION;
        uint256 incoming = x + carriedScaled / PRECISION;
        uint256 duration = (r + incoming) == 0 ? DURATION : (r * left + incoming * DURATION) / (r + incoming);
        if (duration == 0) duration = 1;

        uint256 totalScaled = remainingScaled + x * PRECISION + carriedScaled;
        rewardRate = totalScaled / duration;
        carriedScaled = totalScaled - rewardRate * duration;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + duration;
        emit RewardAdded(msg.sender, x, rewardRate, periodFinish);
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `forge test --match-path test/revshare/TokenStaking.t.sol -vv`
Expected: 9 tests PASS (the fuzz test with the default 512 runs). If `test_rewardAccruedWithNobodyStakedIsCarried` misses by more than `1e9`, print `st.carried()` before the second funding with `console2.log` and check `_update` books the empty-pool stream into `carriedScaled`.

- [ ] **Step 7: Restore deployments and commit**

```bash
git checkout -- deployments/
git add src/revshare/interfaces/IRevShare.sol src/revshare/TokenStaking.sol test/revshare/mocks/MockBurnableERC20.sol test/revshare/TokenStaking.t.sol
git commit -m "feat(revshare): TokenStaking - weighted 7-day vesting per funding, 7-day exit cooldown that earns nothing"
```

---

### Task 2: RevenueRouter

**Files:**
- Create: `test/revshare/mocks/MockRevShareVault.sol`
- Create: `src/revshare/RevenueRouter.sol`
- Test: `test/revshare/RevenueRouter.t.sol`

**Interfaces:**
- Consumes: `IRevShareVault`, `IPxOracle`, `IVaultFactory`, `IInsurancePool` from `src/revshare/interfaces/IRevShare.sol` (Task 1).
- Produces: `RevenueRouter(IERC20 asset, uint8 assetDecimals, IVaultFactory factory, IInsurancePool insurance, address buyback, address ops, address treasury, address governance)`; `distribute() returns (uint256 credited)`, `claim(address) returns (uint256)`, `shares() returns (uint256 insBps, uint256 tokenBps, uint256 opsBps, uint256 treasuryBps)`, `openValue18() returns (uint256)`, `owed(address) returns (uint256)`, `totalOwed()`, `targetBps()`, `proposeTarget(uint256)`, `applyTarget()`, constants `MIN_TARGET_BPS = 200`, `MAX_TARGET_BPS = 1000`, `TARGET_DELAY = 2 days`.

- [ ] **Step 1: Write the router's stand-ins**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {MockERC20} from "../../mocks/MockERC20.sol";

/// @notice One certificate + oracle + vault, a factory listing vaults, and an insurance pool whose
///         assets and shares the test sets directly.
contract MockPxOracle {
    uint256 public px;

    function setPx(uint256 p) external {
        px = p;
    }

    function pxUnguarded() external view returns (uint256, uint256) {
        return (px, block.timestamp);
    }
}

contract MockRevShareVault {
    address public certificate;
    address public oracle;

    constructor(address c, address o) {
        certificate = c;
        oracle = o;
    }
}

contract MockVaultFactory {
    address[] public vaults;

    function add(address v) external {
        vaults.push(v);
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }
}

contract MockInsurancePool {
    uint256 public totalAssets;
    uint256 public totalSupply;

    function set(uint256 assets, uint256 supply) external {
        totalAssets = assets;
        totalSupply = supply;
    }
}
```

- [ ] **Step 2: Write the failing tests**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPxOracle, MockRevShareVault, MockVaultFactory, MockInsurancePool} from "./mocks/MockRevShareVault.sol";
import {RevenueRouter} from "../../src/revshare/RevenueRouter.sol";
import {IVaultFactory, IInsurancePool} from "../../src/revshare/interfaces/IRevShare.sol";

contract RevenueRouterTest is Test {
    MockERC20 usdg;
    MockERC20 cert;
    MockPxOracle oracle;
    MockVaultFactory factory;
    MockInsurancePool pool;
    RevenueRouter router;
    address buyback = address(0xB8);
    address ops = address(0x0B5);
    address treasury = address(0x7E);
    address gov = address(0x60);

    function setUp() public {
        vm.warp(1_000_000);
        usdg = new MockERC20("USDG", "USDG", 6);
        cert = new MockERC20("uTSLA", "uTSLA", 18);
        oracle = new MockPxOracle();
        oracle.setPx(350e18);
        factory = new MockVaultFactory();
        factory.add(address(new MockRevShareVault(address(cert), address(oracle))));
        pool = new MockInsurancePool();
        router = new RevenueRouter(usdg, 6, IVaultFactory(address(factory)), IInsurancePool(address(pool)),
                                   buyback, ops, treasury, gov);
    }

    function _income(uint256 amt) internal {
        usdg.mint(address(router), amt);
        router.distribute();
    }

    function test_belowTargetSplit_50_30_10_10() public {
        cert.mint(address(1), 100e18);          // 100 certs x $350 = $35,000 open; 5% target = $1,750
        pool.set(1_000e6, 1e12);                // $1,000 of cover < target
        _income(1_000e6);
        assertEq(router.owed(address(pool)), 500e6);
        assertEq(router.owed(buyback), 300e6);
        assertEq(router.owed(ops), 100e6);
        assertEq(router.owed(treasury), 100e6);
    }

    function test_atTargetSplit_0_80_10_10() public {
        cert.mint(address(1), 100e18);
        pool.set(1_750e6, 1e12);                // exactly at target
        _income(1_000e6);
        assertEq(router.owed(address(pool)), 0);
        assertEq(router.owed(buyback), 800e6);
        assertEq(router.owed(ops), 100e6);
        assertEq(router.owed(treasury), 100e6);
    }

    function test_emptyPoolShareGoesToTreasury() public {
        cert.mint(address(1), 100e18);
        pool.set(0, 0);
        _income(1_000e6);
        assertEq(router.owed(address(pool)), 0);
        assertEq(router.owed(buyback), 300e6);
        assertEq(router.owed(treasury), 600e6);
    }

    function test_noOpenCertificatesMeansTargetMet() public {
        pool.set(0, 1e12);                      // depositors exist, nothing open
        _income(1_000e6);
        assertEq(router.owed(buyback), 800e6);
    }

    function test_claimPaysOnlyTheRecipient() public {
        pool.set(0, 1e12);
        _income(1_000e6);
        uint256 paid = router.claim(buyback);
        assertEq(paid, 800e6);
        assertEq(usdg.balanceOf(buyback), 800e6);
        assertEq(router.owed(buyback), 0);
    }

    function test_nothingCreditedTwice() public {
        pool.set(0, 1e12);
        _income(1_000e6);
        router.distribute();                    // no new income
        assertEq(router.totalOwed(), 1_000e6);
    }

    function test_targetChangeNeedsGovernanceBoundsAndTwoDays() public {
        vm.expectRevert(RevenueRouter.RevenueRouter_OnlyGovernance.selector);
        router.proposeTarget(300);
        vm.startPrank(gov);
        vm.expectRevert(RevenueRouter.RevenueRouter_TargetOutOfBounds.selector);
        router.proposeTarget(1_001);
        vm.expectRevert(RevenueRouter.RevenueRouter_TargetOutOfBounds.selector);
        router.proposeTarget(199);
        router.proposeTarget(300);
        vm.stopPrank();
        vm.expectRevert(RevenueRouter.RevenueRouter_TargetNotReady.selector);
        router.applyTarget();
        skip(2 days);
        router.applyTarget();                   // permissionless once due
        assertEq(router.targetBps(), 300);
    }

    function testFuzz_sharesSumToIncomeLessDust(uint64 income, uint64 cover, uint64 certs) public {
        cert.mint(address(1), uint256(certs));
        pool.set(cover, 1e12);
        usdg.mint(address(router), income);
        uint256 credited = router.distribute();
        assertLe(income - credited, 3);
        assertEq(router.totalOwed(), credited);
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `forge test --match-path test/revshare/RevenueRouter.t.sol -vv`
Expected: compilation FAIL (`RevenueRouter.sol` does not exist).

- [ ] **Step 4: Write RevenueRouter**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";
import {IRevShareVault, IPxOracle, IVaultFactory, IInsurancePool} from "./interfaces/IRevShare.sol";

/// @title RevenueRouter - stack 6's fee sink: insurance first, then the token
/// @notice distribute() splits the income nobody has been credited yet by how well the insurance
///         pool covers the certificates outstanding:
///           cover <  target: 50% insurance, 30% token side, 10% ops, 10% treasury
///           cover >= target:  0% insurance, 80% token side, 10% ops, 10% treasury
///           pool has no shares: its share goes to the treasury (Sermium L-02: no first-depositor prize)
///         target = targetBps x the value of every registered vault's certificates. Pull-based like
///         FeeVault: distribute() only books; claim(recipient) pays one recipient.
/// @dev No owner. Recipients are immutable. The only setting is targetBps, within
///      [MIN_TARGET_BPS, MAX_TARGET_BPS], by governance, after TARGET_DELAY.
contract RevenueRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error RevenueRouter_ZeroAddress();
    error RevenueRouter_OnlyGovernance();
    error RevenueRouter_TargetOutOfBounds();
    error RevenueRouter_TargetNotReady();
    error RevenueRouter_NoPendingTarget();

    event Credited(address indexed recipient, uint256 amount);
    event Distributed(uint256 amount, uint256 dustKept, uint256 insBps, uint256 tokenBps);
    event Claimed(address indexed recipient, address indexed caller, uint256 amount);
    event TargetProposed(uint256 bps, uint256 readyAt);
    event TargetApplied(uint256 bps);

    uint256 public constant TOTAL_BPS = 10_000;
    uint256 public constant MIN_TARGET_BPS = 200;
    uint256 public constant MAX_TARGET_BPS = 1_000;
    uint256 public constant TARGET_DELAY = 2 days;
    uint256 public constant MAX_VAULTS = 16;

    IERC20 public immutable asset;
    uint256 public immutable assetScale;                 // 10 ** (18 - assetDecimals)
    IVaultFactory public immutable factory;
    IInsurancePool public immutable insurance;
    address public immutable buyback;
    address public immutable ops;
    address public immutable treasury;
    address public immutable governance;

    uint256 public targetBps = 500;
    uint256 public pendingTargetBps;
    uint256 public pendingTargetAt;

    mapping(address => uint256) public owed;
    uint256 public totalOwed;

    constructor(IERC20 asset_, uint8 assetDecimals, IVaultFactory factory_, IInsurancePool insurance_,
                address buyback_, address ops_, address treasury_, address governance_) {
        if (address(asset_) == address(0) || address(factory_) == address(0) || address(insurance_) == address(0)
            || buyback_ == address(0) || ops_ == address(0) || treasury_ == address(0) || governance_ == address(0)) {
            revert RevenueRouter_ZeroAddress();
        }
        asset = asset_;
        assetScale = 10 ** (18 - assetDecimals);
        factory = factory_;
        insurance = insurance_;
        buyback = buyback_;
        ops = ops_;
        treasury = treasury_;
        governance = governance_;
    }

    // ------------------------------------------------------------------ views
    /// @notice The value of every registered vault's certificates, 18-decimal USD.
    function openValue18() public view returns (uint256 v) {
        uint256 n = factory.vaultCount();
        if (n > MAX_VAULTS) n = MAX_VAULTS;
        for (uint256 i = 0; i < n; i++) {
            IRevShareVault vault = IRevShareVault(factory.vaults(i));
            (uint256 px18,) = IPxOracle(vault.oracle()).pxUnguarded();
            v += Math.mulDiv(IERC20(vault.certificate()).totalSupply(), px18, 1e18);
        }
    }

    function shares() public view returns (uint256 insBps, uint256 tokenBps, uint256 opsBps, uint256 treasuryBps) {
        if (insurance.totalSupply() == 0) return (0, 3_000, 1_000, 6_000);
        uint256 target = Math.mulDiv(openValue18(), targetBps, TOTAL_BPS) / assetScale;
        if (insurance.totalAssets() < target) return (5_000, 3_000, 1_000, 1_000);
        return (0, 8_000, 1_000, 1_000);
    }

    function uncredited() public view returns (uint256) {
        uint256 bal = asset.balanceOf(address(this));
        return bal > totalOwed ? bal - totalOwed : 0;
    }

    // ------------------------------------------------------------------ split and pay
    function distribute() external nonReentrant returns (uint256 credited) {
        uint256 fresh = uncredited();
        if (fresh == 0) return 0;
        (uint256 insBps, uint256 tokenBps, uint256 opsBps, uint256 treasuryBps) = shares();
        credited += _credit(address(insurance), fresh, insBps);
        credited += _credit(buyback, fresh, tokenBps);
        credited += _credit(ops, fresh, opsBps);
        credited += _credit(treasury, fresh, treasuryBps);
        totalOwed += credited;
        emit Distributed(credited, fresh - credited, insBps, tokenBps);
    }

    function _credit(address to, uint256 fresh, uint256 bps) internal returns (uint256 amount) {
        if (bps == 0) return 0;
        amount = Math.mulDiv(fresh, bps, TOTAL_BPS);
        if (amount == 0) return 0;
        owed[to] += amount;
        emit Credited(to, amount);
    }

    function claim(address recipient) external nonReentrant returns (uint256 amount) {
        amount = owed[recipient];
        if (amount == 0) return 0;
        owed[recipient] = 0;
        totalOwed -= amount;
        asset.safeTransfer(recipient, amount);
        emit Claimed(recipient, msg.sender, amount);
    }

    // ------------------------------------------------------------------ the one setting
    function proposeTarget(uint256 bps) external {
        if (msg.sender != governance) revert RevenueRouter_OnlyGovernance();
        if (bps < MIN_TARGET_BPS || bps > MAX_TARGET_BPS) revert RevenueRouter_TargetOutOfBounds();
        pendingTargetBps = bps;
        pendingTargetAt = block.timestamp + TARGET_DELAY;
        emit TargetProposed(bps, pendingTargetAt);
    }

    function applyTarget() external {
        if (pendingTargetAt == 0) revert RevenueRouter_NoPendingTarget();
        if (block.timestamp < pendingTargetAt) revert RevenueRouter_TargetNotReady();
        targetBps = pendingTargetBps;
        pendingTargetBps = 0;
        pendingTargetAt = 0;
        emit TargetApplied(targetBps);
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `forge test --match-path test/revshare/RevenueRouter.t.sol -vv`
Expected: 8 tests PASS.

- [ ] **Step 6: Restore deployments and commit**

```bash
git checkout -- deployments/
git add src/revshare/RevenueRouter.sol test/revshare/mocks/MockRevShareVault.sol test/revshare/RevenueRouter.t.sol
git commit -m "feat(revshare): RevenueRouter - insurance-first split (50/30/10/10 below target, 0/80/10/10 at it), empty pool to treasury, delayed bounded target"
```

---

### Task 3: Buyback

**Files:**
- Create: `test/revshare/mocks/MockV2Pair.sol`
- Create: `src/revshare/Buyback.sol`
- Test: `test/revshare/Buyback.t.sol`
- Modify: `docs/superpowers/specs/2026-09-30-token-revenue-share-design.md` (the burn line)

**Interfaces:**
- Consumes: `IUniswapV2PairLike`, `ITokenStaking` (Task 1); `TokenStaking` (Task 1) in tests.
- Produces: `Buyback(IERC20 usdg, IERC20 token, ITokenStaking staking, address governance, bool tokenHasBurn, uint256 trancheMax, uint256 callerRewardMax)`; `proposePool(address)`, `applyPool()`, `buy() returns (uint256 received)`, views `pair()`, `lastBuyAt()`, `lastObsTime()`, constants `BUY_INTERVAL = 1 hours`, `TWAP_MIN = 30 minutes`, `TWAP_MAX = 2 hours`, `GUARD_BPS = 200`, `POOL_DELAY = 2 days`, `DEAD = 0x000000000000000000000000000000000000dEaD`.

- [ ] **Step 1: Write the V2 pair mock**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice The parts of a Uniswap V2 pair the buyback uses: reserves, a 0.3%-fee swap and the
///         UQ112x112 cumulative prices, updated on every sync exactly as UniswapV2Pair._update does.
contract MockV2Pair {
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function sync() public {
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint32 ts = uint32(block.timestamp);
        uint32 elapsed = ts - blockTimestampLast;
        if (elapsed > 0 && reserve0 != 0 && reserve1 != 0) {
            price0CumulativeLast += (uint256(reserve1) << 112) / reserve0 * elapsed;
            price1CumulativeLast += (uint256(reserve0) << 112) / reserve1 * elapsed;
        }
        reserve0 = uint112(b0);
        reserve1 = uint112(b1);
        blockTimestampLast = ts;
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        (uint112 r0, uint112 r1,) = (reserve0, reserve1, blockTimestampLast);
        if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 in0 = b0 > r0 - amount0Out ? b0 - (r0 - amount0Out) : 0;
        uint256 in1 = b1 > r1 - amount1Out ? b1 - (r1 - amount1Out) : 0;
        require(in0 > 0 || in1 > 0, "INSUFFICIENT_INPUT");
        uint256 a0 = b0 * 1000 - in0 * 3;
        uint256 a1 = b1 * 1000 - in1 * 3;
        require(a0 * a1 >= uint256(r0) * r1 * 1_000_000, "K");
        sync();
    }
}
```

- [ ] **Step 2: Write the failing tests**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockBurnableERC20} from "./mocks/MockBurnableERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {TokenStaking} from "../../src/revshare/TokenStaking.sol";
import {Buyback} from "../../src/revshare/Buyback.sol";
import {ITokenStaking} from "../../src/revshare/interfaces/IRevShare.sol";

contract BuybackTest is Test {
    MockERC20 usdg;
    MockBurnableERC20 tkn;
    TokenStaking st;
    MockV2Pair pair;
    Buyback bb;
    address gov = address(0x60);
    address keeper = address(0xCA11);
    address staker = address(0x57A);

    function setUp() public {
        vm.warp(1_000_000);
        usdg = new MockERC20("USDG", "USDG", 6);
        tkn = new MockBurnableERC20();
        st = new TokenStaking(tkn);
        bb = new Buyback(usdg, tkn, ITokenStaking(address(st)), gov, true, 200e6, 0.5e6);
        pair = new MockV2Pair(address(usdg), address(tkn));
        usdg.mint(address(pair), 100_000e6);                 // 100k USDG
        tkn.mint(address(pair), 10_000_000e18);              // 10M tokens: $0.01 each
        pair.sync();
        tkn.mint(staker, 1_000e18);
        vm.prank(staker);
        tkn.approve(address(st), type(uint256).max);
        vm.prank(staker);
        st.stake(1_000e18);
        usdg.mint(address(bb), 1_000e6);
    }

    function _setPool() internal {
        vm.prank(gov);
        bb.proposePool(address(pair));
        skip(2 days);
        bb.applyPool();
    }

    function _observeThenWait() internal {
        bb.buy();                                            // first call only records an observation
        skip(31 minutes);
        pair.sync();                                         // time passes in the pair's accumulators
    }

    function test_noPoolNoBuy() public {
        vm.expectRevert(Buyback.Buyback_NoPool.selector);
        bb.buy();
    }

    function test_poolIsSetOnceAfterTwoDays() public {
        vm.expectRevert(Buyback.Buyback_OnlyGovernance.selector);
        bb.proposePool(address(pair));
        vm.prank(gov);
        bb.proposePool(address(pair));
        vm.expectRevert(Buyback.Buyback_PoolNotReady.selector);
        bb.applyPool();
        skip(2 days);
        bb.applyPool();
        assertEq(address(bb.pair()), address(pair));
        vm.prank(gov);
        vm.expectRevert(Buyback.Buyback_PoolAlreadySet.selector);
        bb.proposePool(address(pair));
    }

    function test_poolMustPairTheTokenWithUsdg() public {
        MockV2Pair wrong = new MockV2Pair(address(usdg), address(new MockBurnableERC20()));
        vm.prank(gov);
        bb.proposePool(address(wrong));
        skip(2 days);
        vm.expectRevert(Buyback.Buyback_WrongPool.selector);
        bb.applyPool();
    }

    function test_buySpendsATrancheBurnsHalfStakesHalf() public {
        _setPool();
        _observeThenWait();
        uint256 supplyBefore = tkn.totalSupply();
        vm.prank(keeper);
        uint256 got = bb.buy();
        assertGt(got, 0);
        assertEq(usdg.balanceOf(address(bb)), 1_000e6 - 200e6, "spent more or less than a tranche");
        assertEq(usdg.balanceOf(keeper), 0.5e6, "caller reward");
        assertEq(supplyBefore - tkn.totalSupply(), got / 2, "half burnt");
        assertEq(tkn.balanceOf(address(bb)), 0, "buyback holds tokens after a buy");
        assertApproxEqAbs(tkn.balanceOf(address(st)) - 1_000e18, got - got / 2, 1, "half to staking");
    }

    function test_oneBuyPerHour() public {
        _setPool();
        _observeThenWait();
        bb.buy();
        skip(59 minutes);
        vm.expectRevert(Buyback.Buyback_TooSoon.selector);
        bb.buy();
    }

    function test_trancheIsCappedAtOnePercentOfTheUsdgReserve() public {
        MockV2Pair thin = new MockV2Pair(address(usdg), address(tkn));
        usdg.mint(address(thin), 5_000e6);                   // 1% = 50 USDG < 200
        tkn.mint(address(thin), 500_000e18);
        thin.sync();
        vm.prank(gov);
        bb.proposePool(address(thin));
        skip(2 days);
        bb.applyPool();
        bb.buy();
        skip(31 minutes);
        thin.sync();
        bb.buy();
        assertEq(usdg.balanceOf(address(bb)), 1_000e6 - 50e6);
    }

    function test_manipulatedPriceReverts() public {
        _setPool();
        _observeThenWait();
        usdg.mint(address(pair), 20_000e6);                   // someone pumps the token just before
        vm.prank(address(0xBAD));
        pair.swap(pair.token0() == address(tkn) ? 1_500_000e18 : 0, pair.token0() == address(tkn) ? 0 : 1_500_000e18,
                  address(0xBAD), "");
        vm.expectRevert(Buyback.Buyback_PriceGuard.selector);
        bb.buy();
    }

    function test_staleObservationOnlyRecords() public {
        _setPool();
        bb.buy();
        skip(3 hours);
        pair.sync();
        uint256 before = usdg.balanceOf(address(bb));
        bb.buy();                                            // too old: records, buys nothing
        assertEq(usdg.balanceOf(address(bb)), before);
    }

    function test_noStakersMeansAllIsBurnt() public {
        vm.prank(staker);
        st.requestUnstake(1_000e18);
        _setPool();
        _observeThenWait();
        uint256 supplyBefore = tkn.totalSupply();
        uint256 got = bb.buy();
        assertEq(supplyBefore - tkn.totalSupply(), got);
    }

    function test_tokenWithoutBurnGoesToDead() public {
        Buyback nb = new Buyback(usdg, tkn, ITokenStaking(address(st)), gov, false, 200e6, 0.5e6);
        usdg.mint(address(nb), 1_000e6);
        vm.prank(gov);
        nb.proposePool(address(pair));
        skip(2 days);
        nb.applyPool();
        nb.buy();
        skip(31 minutes);
        pair.sync();
        uint256 got = nb.buy();
        assertEq(tkn.balanceOf(nb.DEAD()), got / 2);
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `forge test --match-path test/revshare/Buyback.t.sol -vv`
Expected: compilation FAIL (`Buyback.sol` does not exist).

- [ ] **Step 4: Write Buyback**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";
import {IUniswapV2PairLike, ITokenStaking} from "./interfaces/IRevShare.sol";

interface IBurnable {
    function burn(uint256 amount) external;
}

/// @title Buyback - turns the token side's USDG into burnt and staked tokens
/// @notice Before the token graduates it only holds USDG. Governance sets the token/USDG pair
///         once, after POOL_DELAY. Then anyone may call buy() once per BUY_INTERVAL: it spends
///         min(trancheMax, 1% of the pair's USDG reserve, balance), refuses unless the swap
///         returns at least (1 - GUARD_BPS) of what the pair's own average price over the last
///         30 minutes to 2 hours implies, burns half of the tokens and funds TokenStaking with
///         the other half (all burnt when nothing is staked). The caller keeps a small reward.
/// @dev No owner, no pause. Never holds tokens after a buy. The average price is taken from the
///      pair's UQ112x112 cumulative prices, with the counterfactual accumulation since the pair's
///      last update, exactly as UniswapV2OracleLibrary.currentCumulativePrices does.
contract Buyback is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error Buyback_ZeroAddress();
    error Buyback_OnlyGovernance();
    error Buyback_PoolAlreadySet();
    error Buyback_NoPendingPool();
    error Buyback_PoolNotReady();
    error Buyback_WrongPool();
    error Buyback_NoPool();
    error Buyback_TooSoon();
    error Buyback_ObservationTooRecent();
    error Buyback_PriceGuard();
    error Buyback_NothingToSpend();

    event PoolProposed(address pair, uint256 readyAt);
    event PoolSet(address pair);
    event Observed(uint256 cumulative, uint256 at);
    event Bought(address indexed caller, uint256 usdgSpent, uint256 tokensReceived, uint256 avgTokensPerUsdgX112,
                 uint256 burnt, uint256 toStakers, uint256 callerReward);

    uint256 public constant BUY_INTERVAL = 1 hours;
    uint256 public constant TWAP_MIN = 30 minutes;
    uint256 public constant TWAP_MAX = 2 hours;
    uint256 public constant GUARD_BPS = 200;
    uint256 public constant POOL_DELAY = 2 days;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable usdg;
    IERC20 public immutable token;
    ITokenStaking public immutable staking;
    address public immutable governance;
    bool public immutable tokenHasBurn;
    uint256 public immutable trancheMax;
    uint256 public immutable callerRewardMax;

    IUniswapV2PairLike public pair;
    bool public usdgIsToken0;
    address public pendingPair;
    uint256 public pendingPairAt;

    uint256 public lastObsCumulative;
    uint256 public lastObsTime;
    uint256 public lastBuyAt;

    constructor(IERC20 usdg_, IERC20 token_, ITokenStaking staking_, address governance_, bool tokenHasBurn_,
                uint256 trancheMax_, uint256 callerRewardMax_) {
        if (address(usdg_) == address(0) || address(token_) == address(0) || address(staking_) == address(0)
            || governance_ == address(0)) revert Buyback_ZeroAddress();
        usdg = usdg_;
        token = token_;
        staking = staking_;
        governance = governance_;
        tokenHasBurn = tokenHasBurn_;
        trancheMax = trancheMax_;
        callerRewardMax = callerRewardMax_;
    }

    // ------------------------------------------------------------------ the pool, once
    function proposePool(address p) external {
        if (msg.sender != governance) revert Buyback_OnlyGovernance();
        if (address(pair) != address(0)) revert Buyback_PoolAlreadySet();
        if (p == address(0)) revert Buyback_ZeroAddress();
        pendingPair = p;
        pendingPairAt = block.timestamp + POOL_DELAY;
        emit PoolProposed(p, pendingPairAt);
    }

    function applyPool() external {
        if (address(pair) != address(0)) revert Buyback_PoolAlreadySet();
        if (pendingPair == address(0)) revert Buyback_NoPendingPool();
        if (block.timestamp < pendingPairAt) revert Buyback_PoolNotReady();
        IUniswapV2PairLike p = IUniswapV2PairLike(pendingPair);
        address t0 = p.token0();
        address t1 = p.token1();
        bool ok = (t0 == address(usdg) && t1 == address(token)) || (t0 == address(token) && t1 == address(usdg));
        if (!ok) revert Buyback_WrongPool();
        pair = p;
        usdgIsToken0 = t0 == address(usdg);
        pendingPair = address(0);
        pendingPairAt = 0;
        emit PoolSet(address(p));
    }

    // ------------------------------------------------------------------ price
    /// @dev Cumulative "tokens per USDG" in UQ112x112 seconds, including the time since the pair's
    ///      last update at its current reserves.
    function _cumulative() internal view returns (uint256 cum, uint256 rUsdg, uint256 rToken) {
        (uint112 r0, uint112 r1, uint32 last) = pair.getReserves();
        (rUsdg, rToken) = usdgIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        cum = usdgIsToken0 ? pair.price0CumulativeLast() : pair.price1CumulativeLast();
        uint32 elapsed = uint32(block.timestamp) - last;
        if (elapsed > 0 && rUsdg != 0) cum += (rToken << 112) / rUsdg * elapsed;
    }

    function _observe(uint256 cum) internal {
        lastObsCumulative = cum;
        lastObsTime = block.timestamp;
        emit Observed(cum, block.timestamp);
    }

    // ------------------------------------------------------------------ buy
    function buy() external nonReentrant returns (uint256 received) {
        if (address(pair) == address(0)) revert Buyback_NoPool();
        if (lastBuyAt != 0 && block.timestamp < lastBuyAt + BUY_INTERVAL) revert Buyback_TooSoon();
        (uint256 cum, uint256 rUsdg, uint256 rToken) = _cumulative();
        uint256 age = block.timestamp - lastObsTime;
        if (lastObsTime == 0 || age > TWAP_MAX) {
            _observe(cum);
            return 0;
        }
        if (age < TWAP_MIN) revert Buyback_ObservationTooRecent();
        uint256 avgX112 = (cum - lastObsCumulative) / age;

        uint256 spend = Math.min(Math.min(trancheMax, rUsdg / 100), usdg.balanceOf(address(this)));
        if (spend == 0) revert Buyback_NothingToSpend();
        uint256 reward = Math.min(callerRewardMax, spend / 100);
        uint256 amountIn = spend - reward;

        uint256 expected = Math.mulDiv(amountIn, avgX112, 1 << 112);
        uint256 inWithFee = amountIn * 997;
        uint256 out = inWithFee * rToken / (rUsdg * 1000 + inWithFee);
        if (out * 10_000 < expected * (10_000 - GUARD_BPS)) revert Buyback_PriceGuard();

        uint256 before = token.balanceOf(address(this));
        usdg.safeTransfer(address(pair), amountIn);
        (uint256 o0, uint256 o1) = usdgIsToken0 ? (uint256(0), out) : (out, uint256(0));
        pair.swap(o0, o1, address(this), "");
        received = token.balanceOf(address(this)) - before;

        (cum,,) = _cumulative();
        _observe(cum);
        lastBuyAt = block.timestamp;

        uint256 toStakers = staking.totalStaked() == 0 ? 0 : received - received / 2;
        uint256 burnt = received - toStakers;
        if (tokenHasBurn) IBurnable(address(token)).burn(burnt);
        else token.safeTransfer(DEAD, burnt);
        if (toStakers > 0) {
            token.forceApprove(address(staking), toStakers);
            staking.notifyRewardAmount(toStakers);
            token.forceApprove(address(staking), 0);
        }
        if (reward > 0) usdg.safeTransfer(msg.sender, reward);
        emit Bought(msg.sender, spend, received, avgX112, burnt, toStakers, reward);
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `forge test --match-path test/revshare/Buyback.t.sol -vv`
Expected: 10 tests PASS. If `test_buySpendsATrancheBurnsHalfStakesHalf` fails on "half burnt", check the burn amount is `received - toStakers` (`received / 2` when stakers exist) and the assertion uses `got / 2`.

- [ ] **Step 6: Record the burn decision in the spec**

In `docs/superpowers/specs/2026-09-30-token-revenue-share-design.md`, replace
`- Of the tokens received: 50% burnt (the token's \`burn\` if it has one, detected at construction,`
with
`- Of the tokens received: 50% burnt (the token's \`burn\` if the constructor's \`tokenHasBurn\` says it has one,`
and keep the rest of the sentence (`otherwise sent to \`0x…dEaD\`)…`).

- [ ] **Step 7: Restore deployments and commit**

```bash
git checkout -- deployments/
git add src/revshare/Buyback.sol test/revshare/mocks/MockV2Pair.sol test/revshare/Buyback.t.sol docs/superpowers/specs/2026-09-30-token-revenue-share-design.md
git commit -m "feat(revshare): Buyback - pool set once after 2 days, hourly capped tranches, 30-minute average-price guard, half burnt and half staked"
```

---

### Task 4: End-to-end flow and attack tests

**Files:**
- Test: `test/revshare/RevShareFlow.t.sol`

**Interfaces:**
- Consumes: `RevenueRouter` (Task 2), `Buyback` (Task 3), `TokenStaking` (Task 1), mocks from Tasks 1–3.

- [ ] **Step 1: Write the tests**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockBurnableERC20} from "./mocks/MockBurnableERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockPxOracle, MockRevShareVault, MockVaultFactory, MockInsurancePool} from "./mocks/MockRevShareVault.sol";
import {TokenStaking} from "../../src/revshare/TokenStaking.sol";
import {Buyback} from "../../src/revshare/Buyback.sol";
import {RevenueRouter} from "../../src/revshare/RevenueRouter.sol";
import {ITokenStaking, IVaultFactory, IInsurancePool} from "../../src/revshare/interfaces/IRevShare.sol";

contract RevShareFlowTest is Test {
    MockERC20 usdg;
    MockBurnableERC20 tkn;
    TokenStaking st;
    MockV2Pair pair;
    Buyback bb;
    RevenueRouter router;
    MockInsurancePool pool;
    address gov = address(0x60);
    address alice = address(0xA11CE);

    function setUp() public {
        vm.warp(1_000_000);
        usdg = new MockERC20("USDG", "USDG", 6);
        tkn = new MockBurnableERC20();
        st = new TokenStaking(tkn);
        bb = new Buyback(usdg, tkn, ITokenStaking(address(st)), gov, true, 200e6, 0.5e6);
        pair = new MockV2Pair(address(usdg), address(tkn));
        usdg.mint(address(pair), 100_000e6);
        tkn.mint(address(pair), 10_000_000e18);
        pair.sync();
        MockVaultFactory f = new MockVaultFactory();
        MockERC20 cert = new MockERC20("uTSLA", "uTSLA", 18);
        MockPxOracle o = new MockPxOracle();
        o.setPx(350e18);
        f.add(address(new MockRevShareVault(address(cert), address(o))));
        pool = new MockInsurancePool();
        pool.set(0, 1e12);                                   // depositors, nothing open: target met
        router = new RevenueRouter(usdg, 6, IVaultFactory(address(f)), IInsurancePool(address(pool)),
                                   address(bb), address(0x0B5), address(0x7E), gov);
        vm.prank(gov);
        bb.proposePool(address(pair));
        skip(2 days);
        bb.applyPool();
        tkn.mint(alice, 1_000e18);
        vm.prank(alice);
        tkn.approve(address(st), type(uint256).max);
        vm.prank(alice);
        st.stake(1_000e18);
    }

    function test_feesBecomeBurntAndStakedTokens() public {
        usdg.mint(address(router), 1_000e6);                 // a week of vault fees
        router.distribute();
        router.claim(address(bb));                            // 800 USDG to the buyback
        uint256 supply0 = tkn.totalSupply();
        bb.buy();                                             // observation
        for (uint256 i = 0; i < 4; i++) {
            skip(1 hours);
            pair.sync();
            bb.buy();
        }
        assertEq(usdg.balanceOf(address(bb)), 0, "800 USDG spent in four 200-USDG tranches");
        assertGt(supply0 - tkn.totalSupply(), 0, "tokens burnt");
        skip(8 days);
        assertGt(st.earned(alice), 0, "stakers earn the staked half");
    }

    /// A sandwich within one block: the attacker moves the price, buy() runs, the attacker unwinds.
    function test_sandwichReverts() public {
        usdg.mint(address(bb), 1_000e6);
        bb.buy();
        skip(31 minutes);
        pair.sync();
        usdg.mint(address(pair), 30_000e6);
        pair.swap(pair.token0() == address(tkn) ? 2_000_000e18 : 0, pair.token0() == address(tkn) ? 0 : 2_000_000e18,
                  address(0xBAD), "");
        vm.expectRevert(Buyback.Buyback_PriceGuard.selector);
        bb.buy();
    }

    /// First depositor after income: an empty insurance pool is paid nothing.
    function test_emptyInsurancePoolGetsNoPrize() public {
        pool.set(0, 0);
        usdg.mint(address(router), 1_000e6);
        router.distribute();
        assertEq(router.owed(address(pool)), 0);
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `forge test --match-path test/revshare/RevShareFlow.t.sol -vv`
Expected: 3 tests PASS. (These use only code from Tasks 1–3; a failure here is a bug in one of them — fix it there, not here.)

- [ ] **Step 3: Run the whole revshare suite and the repo suite**

Run: `forge test --match-path 'test/revshare/*' -vv` — Expected: all revshare tests PASS.
Run: `forge test` — Expected: the repo's existing result is unchanged (its known, deliberate failures in `test/AuditPoC.t.sol` stay as they are); nothing new fails.
Then: `git checkout -- deployments/`

- [ ] **Step 4: Commit**

```bash
git add test/revshare/RevShareFlow.t.sol
git commit -m "test(revshare): end to end - fees to burnt and staked tokens; a sandwich and an empty pool get nothing"
```

---

### Task 5: Fork test against a real graduated pair

**Files:**
- Test: `test/revshare/RevShareFork.t.sol`

**Interfaces:**
- Consumes: `Buyback`, `TokenStaking` (Tasks 1, 3).

- [ ] **Step 1: Find CERT's graduated pair on Robinhood Chain**

CERT (`0xb01356A005403C38c0fb01bd0aAfe51e81Ab9B07`) graduated from its curve (`0x22e3Ed7B6af646467201431663B69588c6646c3B`). Its pair is the contract that received CERT from the curve at graduation and answers `token0()`/`token1()`:

```bash
cast logs --rpc-url https://rpc.mainnet.chain.robinhood.com --from-block 0 --address 0xb01356A005403C38c0fb01bd0aAfe51e81Ab9B07 "Transfer(address indexed,address indexed,uint256)" 0x00000000000000000000000022e3ed7b6af646467201431663b69588c6646c3b | grep -A2 topics | tail -20
```

For each recipient `R` in the output: `cast call R "token0()(address)"` and `cast call R "token1()(address)"`. The pair is the one whose tokens are CERT and the curve's quote token. Record its address as `PAIR` and the quote token as `QUOTE`. If the quote token is not USDG, the fork test below still exercises the swap maths and the accumulators: pass `QUOTE` as the "usdg" constructor argument.

- [ ] **Step 2: Write the fork test (skipped unless `FORK_PAIR` is set)**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {TokenStaking} from "../../src/revshare/TokenStaking.sol";
import {Buyback} from "../../src/revshare/Buyback.sol";
import {ITokenStaking, IUniswapV2PairLike} from "../../src/revshare/interfaces/IRevShare.sol";

/// Run: FORK_PAIR=0x... FORK_QUOTE=0x... FORK_TOKEN=0x... forge test --match-path test/revshare/RevShareFork.t.sol \
///        --fork-url https://rpc.mainnet.chain.robinhood.com -vv
contract RevShareForkTest is Test {
    function test_buyOnARealPair() public {
        address p = vm.envOr("FORK_PAIR", address(0));
        if (p == address(0)) return;                          // not configured: nothing to check
        IERC20 quote = IERC20(vm.envAddress("FORK_QUOTE"));
        IERC20 tkn = IERC20(vm.envAddress("FORK_TOKEN"));
        TokenStaking st = new TokenStaking(tkn);
        Buyback bb = new Buyback(quote, tkn, ITokenStaking(address(st)), address(this), false, 1e6, 0);
        bb.proposePool(p);
        skip(2 days);
        bb.applyPool();
        deal(address(quote), address(bb), 10e6);
        bb.buy();                                             // observation
        skip(31 minutes);
        uint256 got = bb.buy();
        assertGt(got, 0, "the real pair returned nothing");
        assertEq(tkn.balanceOf(bb.DEAD()) >= got, true, "no burn function: all to dead (nobody staked)");
    }
}
```

- [ ] **Step 3: Run it against the pair from Step 1**

Run: `FORK_PAIR=<PAIR> FORK_QUOTE=<QUOTE> FORK_TOKEN=0xb01356A005403C38c0fb01bd0aAfe51e81Ab9B07 forge test --match-path test/revshare/RevShareFork.t.sol --fork-url https://rpc.mainnet.chain.robinhood.com -vv`
Expected: PASS. Without the variables the test passes trivially (it returns early); that is intended so the default suite needs no network.

- [ ] **Step 4: Commit**

```bash
git checkout -- deployments/
git add test/revshare/RevShareFork.t.sol
git commit -m "test(revshare): fork test - a guarded buy on a real graduated V2 pair on Robinhood Chain"
```
