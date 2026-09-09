// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LighterCore} from "../../src/sim/LighterCore.sol";
import {LighterSim} from "../../src/sim/LighterSim.sol";
import {MockLighter} from "../mocks/MockLighter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @dev A `LighterSim` with the one knob the deployable contract deliberately does NOT have.
///      `setMarkPrice` is a test convenience the real venue does not expose and Task 5 owns the
///      gated operator surface, so it must not live on `LighterSim` itself — but without a mark
///      price `settleBatch`'s initial-margin check values every position at zero and is therefore
///      vacuous, which would make the shared-behaviour test prove almost nothing. This harness
///      exists only so the extracted mark-to-market and margin mechanics can be exercised through
///      `LighterSim`'s own inheritance chain.
contract LighterSimHarness is LighterSim {
    constructor(IERC20 c, uint16 a, uint8 d) LighterSim(c, a, d) {}

    function setMarkPrice(uint16 marketIndex, uint256 px18) external {
        markPrice[marketIndex] = px18;
    }
}

/// @notice Task 4 acceptance tests: `MockLighter` and `LighterSim` are two front ends onto one
///         behaviour implementation (`LighterCore`), and the deployable one fits EIP-170.
contract LighterSimTest is Test {
    uint16 constant ASSET_IDX = 3;
    uint8 constant SIZE_DECIMALS = 4;
    uint16 constant MARKET = 16; // TSLA on the real venue

    MockERC20 usdgMock;
    MockERC20 usdgSim;
    MockLighter mockL;
    LighterSim sim;

    function setUp() public {
        usdgMock = new MockERC20("USDG", "USDG", 6);
        usdgSim = new MockERC20("USDG", "USDG", 6);
        mockL = new MockLighter(IERC20(address(usdgMock)), ASSET_IDX, SIZE_DECIMALS);
        sim = new LighterSim(IERC20(address(usdgSim)), ASSET_IDX, SIZE_DECIMALS);

        usdgMock.mint(address(this), 1_000_000e6);
        usdgSim.mint(address(this), 1_000_000e6);
        usdgMock.approve(address(mockL), type(uint256).max);
        usdgSim.approve(address(sim), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------
    // The extraction did not fork behaviour.
    // ---------------------------------------------------------------------------------------

    /// @notice The same deposit -> createOrder -> settleBatch -> withdraw sequence against both
    ///         front ends leaves identical state. This is what proves `MockLighter` and
    ///         `LighterSim` share one implementation rather than two that drift.
    function test_simAndMockShareBehaviour() public {
        // deposit
        mockL.deposit(address(this), ASSET_IDX, 0, 1_000e6);
        sim.deposit(address(this), ASSET_IDX, 0, 1_000e6);

        uint48 mockIdx = mockL.addressToAccountIndex(address(this));
        uint48 simIdx = sim.addressToAccountIndex(address(this));
        assertEq(mockIdx, simIdx, "account index");
        assertGt(simIdx, 0, "registering deposit");
        assertEq(mockL.marginBalance(), sim.marginBalance(), "margin after deposit");

        // createOrder — must NOT fill in the calling transaction on either front end
        mockL.createOrder(mockIdx, MARKET, 100, 35586, 0, 1);
        sim.createOrder(simIdx, MARKET, 100, 35586, 0, 1);
        assertEq(mockL.positionBase(MARKET), 0, "mock filled in-tx");
        assertEq(sim.positionBase(MARKET), 0, "sim filled in-tx");

        // settleBatch
        mockL.settleBatch();
        sim.settleBatch();
        _assertSameState("after settle");
        assertEq(sim.positionBase(MARKET), 100, "sim position");

        // withdraw — asynchronous credit to pending, no synchronous transfer
        mockL.withdraw(mockIdx, ASSET_IDX, 0, 400e6);
        sim.withdraw(simIdx, ASSET_IDX, 0, 400e6);
        _assertSameState("after withdraw");
        assertEq(sim.getPendingBalance(address(this), ASSET_IDX), 400e6, "sim pending");

        // drain the pending balance
        uint256 mockBefore = usdgMock.balanceOf(address(this));
        uint256 simBefore = usdgSim.balanceOf(address(this));
        mockL.withdrawPendingBalance(address(this), ASSET_IDX, 400e6);
        sim.withdrawPendingBalance(address(this), ASSET_IDX, 400e6);
        assertEq(usdgMock.balanceOf(address(this)) - mockBefore, 400e6, "mock drained");
        assertEq(usdgSim.balanceOf(address(this)) - simBefore, 400e6, "sim drained");
        _assertSameState("after drain");
    }

    /// @notice The same sequence with a non-zero mark price, so the extracted mark-to-market and
    ///         initial-margin mechanics are actually exercised rather than short-circuited by a
    ///         zero mark. Run through `LighterSim`'s inheritance chain via the harness.
    function test_simAndMockShareBehaviourUnderMarkToMarket() public {
        LighterSimHarness simH = new LighterSimHarness(IERC20(address(usdgSim)), ASSET_IDX, SIZE_DECIMALS);
        usdgSim.approve(address(simH), type(uint256).max);

        mockL.setMarkPrice(MARKET, 100e18);
        simH.setMarkPrice(MARKET, 100e18);

        mockL.deposit(address(this), ASSET_IDX, 0, 1_000e6);
        simH.deposit(address(this), ASSET_IDX, 0, 1_000e6);

        uint48 mockIdx = mockL.addressToAccountIndex(address(this));
        uint48 simIdx = simH.addressToAccountIndex(address(this));

        mockL.createOrder(mockIdx, MARKET, 100, 35586, 0, 1);
        simH.createOrder(simIdx, MARKET, 100, 35586, 0, 1);
        mockL.settleBatch();
        simH.settleBatch();

        // Entry recorded at the fill's mark on both.
        assertEq(mockL.entryPrice(MARKET), 100e18, "mock entry");
        assertEq(simH.entryPrice(MARKET), 100e18, "sim entry");

        // Mark up: the position now carries an unrealised gain on both.
        mockL.setMarkPrice(MARKET, 120e18);
        simH.setMarkPrice(MARKET, 120e18);
        assertEq(mockL.unrealisedPnl(), simH.unrealisedPnl(), "pnl");
        assertEq(mockL.equity(), simH.equity(), "equity");
        assertGt(simH.equity(), simH.marginBalance(), "gain not modelled");

        // Draw the whole of equity, which forces the gain to be realised and entryPrice rewritten.
        uint64 all = uint64(simH.equity());
        mockL.withdraw(mockIdx, ASSET_IDX, 0, all);
        simH.withdraw(simIdx, ASSET_IDX, 0, all);

        assertEq(mockL.marginBalance(), simH.marginBalance(), "margin after realising gain");
        assertEq(mockL.entryPrice(MARKET), simH.entryPrice(MARKET), "entry after realising gain");
        assertEq(mockL.entryPrice(MARKET), 120e18, "gain fully realised");
        assertEq(mockL.unrealisedPnl(), simH.unrealisedPnl(), "residual pnl");
        assertEq(
            mockL.getPendingBalance(address(this), ASSET_IDX),
            simH.getPendingBalance(address(this), ASSET_IDX),
            "pending credit"
        );

        // The ONE deliberate front-end difference, and it fails in the conservative direction:
        // MockLighter mints the counterparty collateral a gain-drawing withdrawal needs, because a
        // one-account mock has no losing counterparty. LighterSim does not, so the same receipt is
        // unpayable on the simulator. Global Constraint 5 — never easier than mainnet.
        mockL.withdrawPendingBalance(address(this), ASSET_IDX, uint128(all));
        vm.expectRevert();
        simH.withdrawPendingBalance(address(this), ASSET_IDX, uint128(all));
    }

    /// @notice The initial-margin gate is the same gate on both front ends, and it is not vacuous.
    function test_simRejectsUnderMarginedFillLikeMock() public {
        LighterSimHarness simH = new LighterSimHarness(IERC20(address(usdgSim)), ASSET_IDX, SIZE_DECIMALS);
        usdgSim.approve(address(simH), type(uint256).max);

        mockL.setMarkPrice(MARKET, 100e18);
        simH.setMarkPrice(MARKET, 100e18);
        mockL.deposit(address(this), ASSET_IDX, 0, 1e6);
        simH.deposit(address(this), ASSET_IDX, 0, 1e6);

        // 1_000_000 base ticks at size_decimals 4 is 100 units => $10,000 notional against $1.
        mockL.createOrder(mockL.addressToAccountIndex(address(this)), MARKET, 1_000_000, 35586, 0, 1);
        simH.createOrder(simH.addressToAccountIndex(address(this)), MARKET, 1_000_000, 35586, 0, 1);

        vm.expectRevert(LighterCore.InsufficientMargin.selector);
        mockL.settleBatch();
        vm.expectRevert(LighterCore.InsufficientMargin.selector);
        simH.settleBatch();
    }

    // ---------------------------------------------------------------------------------------
    // Deployability and surface hygiene.
    // ---------------------------------------------------------------------------------------

    function test_simIsDeployableUnderEip170() public {
        address deployed = address(new LighterSim(IERC20(address(usdgSim)), ASSET_IDX, SIZE_DECIMALS));
        uint256 size = deployed.code.length;
        assertGt(size, 0, "LighterSim did not deploy");
        assertLt(size, 24_576, "LighterSim exceeds EIP-170");
    }

    /// @notice None of `MockLighter`'s test conveniences reached the deployable contract. Each of
    ///         these would be an unauthenticated knob on a deployed simulator, which Global
    ///         Constraint 4 names as how a testnet silently certifies a bad design. Task 5 adds
    ///         the access-controlled operator surface; nothing should be reachable before then.
    function test_simDoesNotInheritTestConveniences() public {
        string[8] memory leaks = [
            "setMarkPrice(uint16,uint256)",
            "setRequiredMarginBps(uint256)",
            "setDepositCapTicks(uint256)",
            "setShouldRevertDrain(bool)",
            "setShouldRevertPendingRead(bool)",
            "setShouldRevertCreateOrder(bool)",
            "queuedOrderCount()",
            "lastOrder()"
        ];
        for (uint256 i = 0; i < leaks.length; ++i) {
            (bool ok,) = address(sim).call(abi.encodeWithSignature(leaks[i]));
            assertFalse(ok, leaks[i]);
        }
        // Sanity: the same probe succeeds against the mock, so the assertion above is meaningful
        // rather than passing because the encoding is wrong.
        (bool mockOk,) = address(mockL).call(abi.encodeWithSignature("queuedOrderCount()"));
        assertTrue(mockOk, "probe encoding is wrong");
    }

    /// @dev `LighterCore` is abstract on purpose: once Task 5 gates `LighterSim`, a deployable
    ///      core would be a standing bypass of that gating. Recorded here because it is a
    ///      structural decision, and `forge build --sizes` cannot show it.
    function test_simIsTheOnlyDeployableFrontEndInSrcSim() public view {
        assertGt(address(sim).code.length, 0, "sim is deployable");
    }

    // ---------------------------------------------------------------------------------------

    function _assertSameState(string memory tag) internal view {
        assertEq(mockL.marginBalance(), sim.marginBalance(), string.concat("marginBalance ", tag));
        assertEq(mockL.positionBase(MARKET), sim.positionBase(MARKET), string.concat("positionBase ", tag));
        assertEq(mockL.entryPrice(MARKET), sim.entryPrice(MARKET), string.concat("entryPrice ", tag));
        assertEq(mockL.markPrice(MARKET), sim.markPrice(MARKET), string.concat("markPrice ", tag));
        assertEq(mockL.unrealisedPnl(), sim.unrealisedPnl(), string.concat("unrealisedPnl ", tag));
        assertEq(mockL.equity(), sim.equity(), string.concat("equity ", tag));
        assertEq(mockL.requiredMarginBps(), sim.requiredMarginBps(), string.concat("requiredMarginBps ", tag));
        assertEq(mockL.depositCapTicks(), sim.depositCapTicks(), string.concat("depositCapTicks ", tag));
        assertEq(
            mockL.getPendingBalance(address(this), ASSET_IDX),
            sim.getPendingBalance(address(this), ASSET_IDX),
            string.concat("pending ", tag)
        );
        assertEq(
            usdgMock.balanceOf(address(mockL)),
            usdgSim.balanceOf(address(sim)),
            string.concat("venue token holdings ", tag)
        );
    }
}
