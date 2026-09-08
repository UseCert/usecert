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
        lighter = new MockLighter(IERC20(address(usdg)), 3, 4);
        usdg.mint(address(this), 1_000_000e6);
        usdg.approve(address(lighter), type(uint256).max);
    }

    function test_depositRegistersAccount() public {
        assertEq(lighter.addressToAccountIndex(address(this)), 0);
        lighter.deposit(address(this), 3, 0, 1_000e6);
        assertGt(lighter.addressToAccountIndex(address(this)), 0);
        assertEq(lighter.marginBalance(), 1_000e6);
    }

    function test_createOrderRevertsForUnregisteredAccount() public {
        vm.expectRevert(MockLighter.AccountIsNotRegistered.selector);
        lighter.createOrder(0, 16, 100, 35586, 0, 1);
    }

    function test_orderDoesNotFillUntilBatchSettles() public {
        lighter.deposit(address(this), 3, 0, 1_000e6);
        uint48 idx = lighter.addressToAccountIndex(address(this));
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
        uint48 idx = lighter.addressToAccountIndex(address(this));
        lighter.createOrder(idx, 16, 500, 35586, 0, 1);
        lighter.settleBatch();
        assertEq(lighter.positionBase(16), 500);

        lighter.createOrder(idx, 16, 0, 35586, 1, 1);
        lighter.settleBatch();
        assertEq(lighter.positionBase(16), 0);
    }

    // ---------------------------------------------------------------------------------------
    // M3 (final review wave): this mock modelled NO position PnL, so a vault's gain never
    // existed and no test could observe C1 (a receipt the vault could never pay because it
    // never asked the venue for more than the deposited basis). The tests below are the proof
    // that mark-to-market is live, not dead code — every one of them fails on the pre-M3 mock,
    // which valued withdrawals against marginBalance alone.
    // ---------------------------------------------------------------------------------------

    /// @dev 10 units long (100_000 ticks at sizeDecimals = 4) entered at 100, backed by 1_000
    ///      USDG of cash margin.
    function _openTenLongAtHundred() internal returns (uint48 idx) {
        lighter.deposit(address(this), 3, 0, 1_000e6);
        idx = lighter.addressToAccountIndex(address(this));
        lighter.setMarkPrice(16, 100e18);
        lighter.createOrder(idx, 16, 100_000, 10_000, 0, 1);
        lighter.settleBatch();
        assertEq(lighter.entryPrice(16), 100e18);
        assertEq(lighter.unrealisedPnl(), 0); // entered at the mark: no gain yet
    }

    function test_equityTracksMarkToMarketGain() public {
        _openTenLongAtHundred();

        lighter.setMarkPrice(16, 150e18); // +50%
        // 100_000 ticks * (150 - 100) / 10**4 = 500e18 -> 500 USDG
        assertEq(lighter.unrealisedPnl(), 500e6);
        assertEq(lighter.equity(), 1_500e6);
        assertEq(lighter.marginBalance(), 1_000e6); // cash itself is untouched
    }

    function test_equityTracksMarkToMarketLoss() public {
        _openTenLongAtHundred();

        lighter.setMarkPrice(16, 50e18); // -50%
        assertEq(lighter.unrealisedPnl(), -500e6);
        assertEq(lighter.equity(), 500e6);
    }

    /// @notice The mechanism C1's fix depends on: a withdrawal larger than the cash balance but
    ///         within equity is fulfilled in full out of the position's gain.
    function test_withdrawFulfilsAgainstEquityNotCash() public {
        uint48 idx = _openTenLongAtHundred();
        lighter.setMarkPrice(16, 150e18);

        lighter.withdraw(idx, 3, 0, 1_400e6); // > marginBalance (1_000e6), < equity (1_500e6)

        assertEq(lighter.getPendingBalance(address(this), 3), 1_400e6);
        assertEq(lighter.marginBalance(), 0); // all cash drawn
        assertEq(lighter.equity(), 100e6); // 500 gain less the 400 realised into the payout

        uint256 before = usdg.balanceOf(address(this));
        lighter.withdrawPendingBalance(address(this), 3, 1_400e6);
        assertEq(usdg.balanceOf(address(this)), before + 1_400e6); // the gain really arrives
    }

    /// @notice The same gain must never be paid twice: closing after a partial draw realises only
    ///         what is left.
    function test_closingFillRealisesOnlyTheUndrawnGain() public {
        uint48 idx = _openTenLongAtHundred();
        lighter.setMarkPrice(16, 150e18);
        lighter.withdraw(idx, 3, 0, 1_400e6);
        lighter.withdrawPendingBalance(address(this), 3, 1_400e6);

        lighter.createOrder(idx, 16, 0, 15_000, 1, 1); // close everything
        lighter.settleBatch();

        assertEq(lighter.positionBase(16), 0);
        assertEq(lighter.entryPrice(16), 0);
        assertEq(lighter.marginBalance(), 100e6); // the undrawn remainder, not another 500
        assertEq(lighter.unrealisedPnl(), 0);
    }

    function test_withdrawStillStrandsWhatEquityCannotCover() public {
        uint48 idx = _openTenLongAtHundred();
        lighter.setMarkPrice(16, 150e18);

        lighter.withdraw(idx, 3, 0, 5_000e6); // far above equity: must not revert

        assertEq(lighter.getPendingBalance(address(this), 3), 1_500e6); // min(request, equity)
        assertEq(lighter.equity(), 0);
    }

    /// @notice M1's fixture hook: the venue refusing to drain an already-credited pending balance.
    function test_drainCanBeMadeToRevert() public {
        uint48 idx = _openTenLongAtHundred();
        lighter.withdraw(idx, 3, 0, 100e6);

        lighter.setShouldRevertDrain(true);
        vm.expectRevert(MockLighter.DrainRefused.selector);
        lighter.withdrawPendingBalance(address(this), 3, 100e6);

        lighter.setShouldRevertDrain(false);
        lighter.withdrawPendingBalance(address(this), 3, 100e6); // and it works again
        assertEq(lighter.getPendingBalance(address(this), 3), 0);
    }

    // ---------------------------------------------------------------------------------------
    // M-3 (MEDIUM, external C1 audit). `baseAmount == 0` defaults to the full position SIZE, and
    // `isAsk` remains the caller's. This mock used to set `resulting = 0` for ANY zero-amount
    // order, ignoring isAsk entirely — so CertVault.closeAll()'s hardcoded SIDE_ASK looked correct
    // in every test, including against a short, where it in fact doubles the position. Modelling
    // the direction is what makes the vault-side fix testable at all, so it is done here first.
    //
    // REQUIRES CONFIRMATION: the direction semantics come from the design spec's section 3.1
    // table, not from Lighter source (not in this repo). This is the conservative reading — it
    // makes a wrong-side close-all harmful — so a vault correct against this mock is correct
    // against either interpretation.
    // ---------------------------------------------------------------------------------------

    /// @notice A full-size ASK against a SHORT doubles it. The behaviour no test could see before.
    /// @dev LOAD-BEARING: restore `resulting = 0` for `baseAmount == 0` and this fails on the final
    ///      assertion with the position at 0 instead of -1_000.
    function test_zeroBaseAmountAskAgainstAShortDoublesIt() public {
        lighter.deposit(address(this), 3, 0, 1_000_000e6);
        uint48 idx = lighter.addressToAccountIndex(address(this));
        lighter.setMarkPrice(16, 100e18);

        // Open a short of 500 ticks.
        lighter.createOrder(idx, 16, 500, 10_000, 1, 1);
        lighter.settleBatch();
        assertEq(lighter.positionBase(16), -500, "the short did not open");

        // A close-all on the WRONG side: an ask for the full size of a short is another sell.
        lighter.createOrder(idx, 16, 0, 10_000, 1, 1);
        lighter.settleBatch();
        assertEq(lighter.positionBase(16), -1_000, "a full-size ask against a short did not double it");
    }

    /// @notice And a full-size BID against a short is what actually closes it.
    function test_zeroBaseAmountBidAgainstAShortClosesIt() public {
        lighter.deposit(address(this), 3, 0, 1_000_000e6);
        uint48 idx = lighter.addressToAccountIndex(address(this));
        lighter.setMarkPrice(16, 100e18);

        lighter.createOrder(idx, 16, 500, 10_000, 1, 1);
        lighter.settleBatch();
        assertEq(lighter.positionBase(16), -500);

        lighter.createOrder(idx, 16, 0, 10_000, 0, 1);
        lighter.settleBatch();
        assertEq(lighter.positionBase(16), 0, "the correct side did not close the short");
    }

    /// @notice The symmetric wrong-side case on a long, so the model is pinned in both directions.
    function test_zeroBaseAmountBidAgainstALongDoublesIt() public {
        lighter.deposit(address(this), 3, 0, 1_000_000e6);
        uint48 idx = lighter.addressToAccountIndex(address(this));
        lighter.setMarkPrice(16, 100e18);

        lighter.createOrder(idx, 16, 500, 10_000, 0, 1);
        lighter.settleBatch();
        assertEq(lighter.positionBase(16), 500);

        lighter.createOrder(idx, 16, 0, 10_000, 0, 1);
        lighter.settleBatch();
        assertEq(lighter.positionBase(16), 1_000, "a full-size bid against a long did not double it");
    }
}
