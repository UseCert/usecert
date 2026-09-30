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
