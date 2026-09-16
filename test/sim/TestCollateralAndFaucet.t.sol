// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TestUSDG} from "../../src/sim/TestUSDG.sol";
import {TestFaucet} from "../../src/sim/TestFaucet.sol";
import {LighterSim} from "../../src/sim/LighterSim.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Task 8, items 3 and 4: the deployable 6-decimal test collateral, and a faucet that is
///         not the venue.
///
/// @dev THE COLLATERAL TOKEN WAS THE DEPLOYMENT BLOCKER. `script/DeployTestnet.s.sol` had to take
///      its collateral as an already-deployed address out of band, because `src/sim/` held three
///      simulators and no token, and `test/mocks/MockERC20.sol` is a test mock a deployment script
///      cannot reach. Everything else in the deployment had been proven end to end against a local
///      chain.
contract TestCollateralAndFaucetTest is Test {
    uint16 constant ASSET_IDX = 3;
    uint8 constant SIZE_DECIMALS = 4;
    uint256 constant IMF = 5_000;

    uint256 constant DRIP = 10_000e6; // 10_000 tUSDG, enough for a meaningful mint
    uint256 constant INTERVAL = 1 days;

    TestUSDG usdg;
    TestFaucet faucet;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        usdg = new TestUSDG(address(this));
        faucet = new TestFaucet(IERC20(address(usdg)), DRIP, INTERVAL);
        // Topping up is a plain transfer in. There is no `fund()` to call and no accounting to keep
        // in step, so a top-up cannot be done wrongly.
        usdg.mint(address(faucet), 10 * DRIP);
    }

    // ---------------------------------------------------------------------------------------
    // The one value with no recovery path.
    // ---------------------------------------------------------------------------------------

    /// @notice **`decimals()` IS 6, ASSERTED AGAINST A DEPLOYED INSTANCE.**
    ///
    /// @dev USDG on the real chain has 6 decimals and `CertVault` reads
    ///      `IERC20Metadata(collateral).decimals()` exactly ONCE, at construction, into an
    ///      immutable. Deploy this token with any other number and every published figure in the
    ///      system is wrong by a power of ten — 10^12 at the plausible mistake of 18 — with no
    ///      migration path, because the vault would have to be redeployed and a redeployed vault
    ///      mints a NEW certificate token while holders' balances sit in the old one.
    ///
    ///      Asserted through `IERC20Metadata`, which is the interface `CertVault` reads it through,
    ///      rather than through the concrete type — so this pins what the vault will actually see.
    function test_decimalsAreSixOnADeployedInstance() public {
        assertEq(usdg.decimals(), 6, "TestUSDG.decimals() is not 6");
        assertEq(IERC20Metadata(address(usdg)).decimals(), 6, "the metadata interface disagrees");

        // And there is no deployment of this contract with any other value: `decimals()` is a pure
        // override returning a literal, not a constructor argument a script could get wrong.
        TestUSDG second = new TestUSDG(alice);
        assertEq(second.decimals(), 6, "a second deployment reported different decimals");
    }

    /// @notice The deployment script's read-back is satisfied. This is the check that currently
    ///         forces the collateral address to be injected from out of band.
    /// @dev `script/DeployTestnet.s.sol` asserts
    ///      `IERC20Metadata(collateral).decimals() == COLLATERAL_DECIMALS` with
    ///      `COLLATERAL_DECIMALS = 6`. Pinned here so the integration cannot regress silently from
    ///      this side of it.
    function test_satisfiesTheDeployScriptsCollateralReadBack() public view {
        assertEq(IERC20Metadata(address(usdg)).decimals(), 6);
    }

    /// @notice Minting is owner-gated. A public mint on the collateral of a solvency-sensitive
    ///         system would make every figure the testnet produces unfalsifiable.
    function test_mintIsOwnerGated() public {
        vm.prank(alice);
        vm.expectRevert(TestUSDG.TestUSDG_NotOwner.selector);
        usdg.mint(alice, 1e6);

        usdg.mint(alice, 1e6); // owner
        assertEq(usdg.balanceOf(alice), 1e6);
    }

    /// @notice A zero owner would leave the supply permanently unmintable — deployed and useless.
    function test_constructorRejectsAZeroOwner() public {
        vm.expectRevert(TestUSDG.TestUSDG_OwnerIsZero.selector);
        new TestUSDG(address(0));
    }

    // ---------------------------------------------------------------------------------------
    // The faucet.
    // ---------------------------------------------------------------------------------------

    /// @notice One drip per address per interval, and the refusal says when the next one is due.
    function test_faucetRateLimits() public {
        vm.prank(alice);
        faucet.claim();
        assertEq(usdg.balanceOf(alice), DRIP, "the first claim did not pay");

        // Immediately again: refused, with the timestamp a UI needs.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TestFaucet.TestFaucet_TooSoon.selector, block.timestamp + INTERVAL));
        faucet.claim();

        // One second short of the interval is still too soon. Off-by-one matters here: a limit
        // that is satisfied a second early is a limit an automated claimer walks straight through.
        vm.warp(block.timestamp + INTERVAL - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TestFaucet.TestFaucet_TooSoon.selector, 1_800_000_000 + INTERVAL));
        faucet.claim();

        vm.warp(1_800_000_000 + INTERVAL);
        vm.prank(alice);
        faucet.claim();
        assertEq(usdg.balanceOf(alice), 2 * DRIP, "the interval elapsed and the claim was refused");
    }

    /// @notice The limit is PER ADDRESS: alice's claim does not delay bob's.
    function test_faucetRateLimitIsPerAddress() public {
        vm.prank(alice);
        faucet.claim();

        vm.prank(bob);
        faucet.claim();

        assertEq(usdg.balanceOf(alice), DRIP);
        assertEq(usdg.balanceOf(bob), DRIP);
        assertEq(faucet.nextAvailableAt(alice), block.timestamp + INTERVAL);
        assertEq(faucet.nextAvailableAt(bob), block.timestamp + INTERVAL);
    }

    /// @notice A first claim is always immediate: an address that has never claimed is not on
    ///         cooldown from block zero.
    function test_firstClaimIsImmediate() public view {
        assertEq(faucet.nextAvailableAt(alice), 0, "a fresh address is on cooldown");
    }

    /// @notice The rate limit is keyed on the CALLER and there is no recipient argument to
    ///         circumvent it with.
    /// @dev A `claim(address to)` would let one address claim every interval on behalf of a
    ///      different recipient and collect the proceeds, which is a rate limit in name only.
    function test_faucetHasNoRecipientArgumentToBypassTheLimitWith() public {
        (bool ok,) = address(faucet).call(abi.encodeWithSignature("claim(address)", bob));
        assertFalse(ok, "the faucet accepts a recipient argument");
    }

    /// @notice The faucet is ALLOWED to run dry, and says so by name.
    /// @dev "The testnet faucet is empty" and "the token is broken" are different operator actions,
    ///      so the empty state is a named error rather than a failed transfer. And an empty faucet
    ///      is the intended terminal state of a contract with no sweep: every token that left did
    ///      so through `claim`, one drip and one log at a time.
    function test_faucetRunsDryWithANamedError() public {
        assertEq(faucet.dripsRemaining(), 10, "the float is not what setUp put in");

        for (uint256 i = 0; i < 10; ++i) {
            address claimer = address(uint160(0x1000 + i));
            vm.prank(claimer);
            faucet.claim();
        }
        assertEq(faucet.dripsRemaining(), 0);

        address late = address(0x2000);
        vm.prank(late);
        vm.expectRevert(abi.encodeWithSelector(TestFaucet.TestFaucet_Empty.selector, 0, DRIP));
        faucet.claim();

        // And a top-up is a plain transfer in, with no accounting to resynchronise.
        usdg.mint(address(faucet), DRIP);
        vm.prank(late);
        faucet.claim();
        assertEq(usdg.balanceOf(late), DRIP);
    }

    /// @notice A drip is logged with the cooldown it creates, so a consumer never has to know
    ///         `interval` to render one.
    function test_dripIsLogged() public {
        vm.expectEmit(true, true, true, true, address(faucet));
        emit TestFaucet.Dripped(alice, DRIP, block.timestamp + INTERVAL, 9 * DRIP);
        vm.prank(alice);
        faucet.claim();
    }

    /// @notice A configuration that would be useless or unlimited is refused at construction.
    function test_constructorRejectsABadConfig() public {
        vm.expectRevert(TestFaucet.TestFaucet_BadConfig.selector);
        new TestFaucet(IERC20(address(0)), DRIP, INTERVAL);

        vm.expectRevert(TestFaucet.TestFaucet_BadConfig.selector);
        new TestFaucet(IERC20(address(usdg)), 0, INTERVAL);

        // A zero interval is an unlimited faucet: one address drains the float in one transaction.
        vm.expectRevert(TestFaucet.TestFaucet_BadConfig.selector);
        new TestFaucet(IERC20(address(usdg)), DRIP, 0);
    }

    /// @notice **THE SEPARATION TEST.** The faucet is not the venue, and the venue cannot mint
    ///         collateral.
    ///
    /// @dev A prior round shipped a simulator whose `_fundPending()` conjured the tokens a
    ///      gain-drawing withdrawal needed, and the consequence was a venue that could ALWAYS pay
    ///      — which is exactly the state solvency exists to detect, made unobservable.
    ///      `LighterCore._fundPending()` is a no-op for that reason and the mint override lives on
    ///      `MockLighter` alone. Putting the faucet on `LighterSim` would reintroduce the same
    ///      confusion through a different door: an operator reading the venue's token balance could
    ///      no longer tell collateral depositors brought from collateral the venue made up.
    ///
    ///      So this asserts three things: the simulator exposes no mint-shaped function, it has no
    ///      faucet-shaped one either, and the faucet holds no account on it.
    function test_faucetIsNotTheVenue() public {
        LighterSim sim = new LighterSim(IERC20(address(usdg)), ASSET_IDX, SIZE_DECIMALS, IMF, address(this));

        bytes[6] memory mints = [
            abi.encodeWithSignature("mint(address,uint256)", alice, uint256(1e6)),
            abi.encodeWithSignature("mint(uint256)", uint256(1e6)),
            abi.encodeWithSignature("claim()"),
            abi.encodeWithSignature("drip()"),
            abi.encodeWithSignature("faucet()"),
            // The hook whose override on `MockLighter` is the "venue can always pay" mechanism.
            abi.encodeWithSignature("fundPending()")
        ];
        for (uint256 i = 0; i < mints.length; ++i) {
            (bool ok,) = address(sim).call(mints[i]);
            assertFalse(ok, "the venue exposes a way to produce collateral");
        }

        // The sanity half: the probe encoding is right, because the same `mint` call succeeds
        // against the token and the same `claim` succeeds against the faucet.
        (bool tokenOk,) = address(usdg).call(abi.encodeWithSignature("mint(address,uint256)", alice, uint256(1e6)));
        assertTrue(tokenOk, "probe encoding is wrong: the token refused a mint from its owner");
        vm.prank(bob);
        (bool faucetOk,) = address(faucet).call(abi.encodeWithSignature("claim()"));
        assertTrue(faucetOk, "probe encoding is wrong: the faucet refused a first claim");

        // And the faucet is not a tenant of the venue: it holds no account, so nothing it holds is
        // part of the venue's balance sheet.
        assertEq(sim.addressToAccountIndex(address(faucet)), 0, "the faucet holds a venue account");
        assertEq(sim.accountCount(), 0, "the venue registered someone during this test");
    }

    /// @notice The faucet has no owner and no way out other than `claim`, so its balance plus its
    ///         `Dripped` stream is a closed account.
    /// @dev A drainable faucet is a faucet whose balance is not evidence of anything, and an
    ///      owner-drainable pool of the same collateral the venue holds looks like a second venue
    ///      balance sheet to anything reading the chain.
    function test_faucetHasNoOwnerAndNoSweep() public {
        bytes[7] memory escapes = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("sweep(address)", alice),
            abi.encodeWithSignature("rescue(address,uint256)", alice, uint256(1)),
            abi.encodeWithSignature("withdraw(uint256)", uint256(1)),
            abi.encodeWithSignature("withdrawAll()"),
            abi.encodeWithSignature("setDripAmount(uint256)", uint256(1)),
            abi.encodeWithSignature("transferOwnership(address)", alice)
        ];
        for (uint256 i = 0; i < escapes.length; ++i) {
            (bool ok,) = address(faucet).call(escapes[i]);
            assertFalse(ok, "the faucet has a privileged path");
        }
    }

    /// @notice Both new contracts deploy and fit EIP-170. `forge test` does not enforce it.
    function test_bothNewContractsAreDeployableUnderEip170() public {
        assertGt(address(usdg).code.length, 0, "TestUSDG did not deploy");
        assertLt(address(usdg).code.length, 24_576, "TestUSDG exceeds EIP-170");
        assertGt(address(faucet).code.length, 0, "TestFaucet did not deploy");
        assertLt(address(faucet).code.length, 24_576, "TestFaucet exceeds EIP-170");
    }
}
