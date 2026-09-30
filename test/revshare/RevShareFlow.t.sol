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
