// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CertVault} from "../../src/CertVault.sol";
import {Certificate} from "../../src/Certificate.sol";
import {CertOracle} from "../../src/CertOracle.sol";
import {SolvencyRegistry} from "../../src/SolvencyRegistry.sol";
import {CapacityOracle} from "../../src/CapacityOracle.sol";
import {LighterCore} from "../../src/sim/LighterCore.sol";
import {LighterSim} from "../../src/sim/LighterSim.sol";
import {TestUSDG} from "../../src/sim/TestUSDG.sol";
import {TestFaucet} from "../../src/sim/TestFaucet.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice Task 8: a REAL `CertVault` on a REAL `LighterSim`, collateralised by the deployable
///         `TestUSDG`, used to produce the two states the rest of this task exists for.
///
/// @dev TWO THINGS ARE PROVEN HERE THAT NOTHING ELSE IN THE REPO COULD PRODUCE.
///
///      1. **`docs/DEPLOYMENT-CHECKLIST.md`'s deposit-cap row.** It says: "Deposits must be exact
///         multiples of `tickSize` and under the global cap | Minting pauses with a clear reason;
///         redemption unaffected." Before this task `LighterCore.deposit` validated neither, so
///         that row described a state no test in this repo could reach — it was a claim, not a
///         property. Both halves are asserted below, and the second half is the one that matters:
///         redemption must survive a venue that refuses deposits, because Design Law 2 says every
///         non-zero redemption stays possible in any venue state.
///
///      2. **The deployable collateral actually works.** Every existing vault test runs on
///         `test/mocks/MockERC20.sol`, which a deployment script cannot reach. This file builds the
///         same stack on `src/sim/TestUSDG.sol` — the contract the deployment will really use — and
///         mints and redeems through it. `decimals()` is asserted directly in
///         `test/sim/TestCollateralAndFaucet.t.sol`; this is the end-to-end half, and it is the
///         evidence that the 6 is right rather than merely present, because a wrong number here
///         would move every figure below by a factor of 10^12.
contract DepositCapMintPauseTest is Test {
    uint16 constant ASSET_IDX = 3;
    uint8 constant SIZE_DECIMALS = 4;
    uint16 constant MARKET = 16; // TSLA on the real venue
    uint256 constant PX = 355.86e18;
    uint256 constant SETTLE_WINDOW = 1 days;
    uint256 constant VENUE_WITHDRAW_CAP = type(uint64).max;
    uint256 constant MAX_ABSOLUTE_CAP = 1_000_000_000e18;
    uint256 constant SIM_IMF = 5_000; // == LighterSim.VENUE_IMF_BPS

    /// @dev 3_558.6 tUSDG at 355.86 is 9.99 certificates: the same figure the rest of the suite
    ///      uses, and it is only that figure if the collateral has 6 decimals.
    uint256 constant MINT_IN = 3_558.6e6;

    TestUSDG usdg;
    TestFaucet faucet;
    MockAggregatorV3 feed;
    LighterSim sim;
    SolvencyRegistry reg;
    CapacityOracle cap;
    CertOracle oracle;
    CertVault vault;
    Certificate cert;

    address attester = makeAddr("attester");
    address gov = makeAddr("gov");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_800_000_000);
        usdg = new TestUSDG(address(this));
        faucet = new TestFaucet(IERC20(address(usdg)), 10_000e6, 1 days);
        feed = new MockAggregatorV3(8, 355_86000000);
        sim = new LighterSim(IERC20(address(usdg)), ASSET_IDX, SIZE_DECIMALS, SIM_IMF, address(this));
        reg = new SolvencyRegistry(attester);
        cap = new CapacityOracle(address(reg), gov, 1000, 100, 3000, 300, MAX_ABSOLUTE_CAP);
        oracle = new CertOracle(address(feed), attester, 2, 3600, 500, 100, 3600, false);

        vault = new CertVault(
            CertVault.Deps({
                lighter: address(sim),
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
                sizeDecimals: SIZE_DECIMALS,
                mintFeeBps: 10,
                redeemFeeBps: 10,
                instantCap18: 10_000e18,
                settleBandBps: 500,
                targetMarginBps: 9_000
            }),
            VENUE_WITHDRAW_CAP,
            SETTLE_WINDOW,
            "UseCert TSLA",
            "uTSLA"
        );
        cert = Certificate(vault.certificate());

        vm.prank(gov);
        cap.setAbsoluteCap(address(vault), 5_000_000e18);
        vm.startPrank(attester);
        oracle.setMarkPrice(PX);
        reg.attest(address(vault), 1, 0, 0, 1_190_000e18);
        vm.stopPrank();

        sim.setMarkPrice(MARKET, PX);
        sim.setDepositorAllowed(address(vault), true);

        // The faucet is how a tester gets collateral on the real testnet, so alice is funded
        // through it here rather than by a direct mint: the path the runbook documents is the path
        // this test exercises.
        usdg.mint(address(faucet), 1_000_000e6);
        vm.prank(alice);
        faucet.claim();

        usdg.mint(address(this), 5_000_000e6);
        usdg.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        usdg.approve(address(vault), type(uint256).max);

        vault.seedBuffer(100_000e6);
        vault.bootstrap();
        sim.settleBatch();
    }

    /// @notice The deployable collateral carries a real mint and a real redeem end to end.
    /// @dev If `TestUSDG.decimals()` were 18 rather than 6, `MINT_IN` would be 3.5586e-12
    ///      certificates instead of 9.99 and this assertion would be off by 10^12. That is the
    ///      whole hazard, made visible as an arithmetic assertion rather than a comment.
    function test_vaultBuiltOnTestUSDGMintsAndRedeems() public {
        assertEq(usdg.decimals(), 6, "the deployable collateral is not 6-decimal");

        vm.prank(alice);
        vault.mintInstant(MINT_IN);
        sim.settleBatch();

        uint256 minted = cert.balanceOf(alice);
        // 3_558.6 tUSDG less the 10 bps mint fee, at 355.86 per certificate.
        assertApproxEqRel(minted, 9.99e18, 0.002e18, "the mint is off by more than the fee");
        assertGt(sim.positionBaseOf(sim.addressToAccountIndex(address(vault)), MARKET), 0, "no hedge opened");

        vm.prank(alice);
        vault.redeemInstant(minted);
        assertEq(cert.balanceOf(alice), 0, "the redemption did not burn");
        assertGt(usdg.balanceOf(alice), 0, "the redemption paid nothing");
    }

    /// @notice **THE CHECKLIST ROW, MADE TESTABLE.** When the venue's deposit cap binds, minting
    ///         stops with the venue's own named reason — and redemption keeps working.
    ///
    /// @dev `CertVault._postMargin` deposits `netCollateral * targetMarginBps / 10_000` to the
    ///      venue on the mint path, with no `try`. That is deliberate: mint is the revert-capable
    ///      path (Laws 2 and 3 permit it to be gated), so a venue refusing the margin post must
    ///      refuse the mint rather than leave the vault holding an unhedged certificate. What the
    ///      checklist asks for is that the refusal be LEGIBLE and that it not reach redemption.
    ///
    ///      Both halves are asserted, and the second is the Law 2 half: alice already holds
    ///      certificates when the cap binds, and she must still be able to get out.
    function test_mintPausesCleanlyWhenTheVenueDepositCapBinds() public {
        // A first mint while the venue is open, so there is a holder to redeem later.
        vm.prank(alice);
        vault.mintInstant(MINT_IN);
        sim.settleBatch();
        uint256 held = cert.balanceOf(alice);
        assertGt(held, 0);

        // The venue's global deposit cap drops below what a margin post needs.
        sim.setDepositCapTicks(1_000e6);

        // Minting stops, with the VENUE's named error rather than an unnamed panic or a silent
        // partial state. This is what "pauses with a clear reason" has to mean to be worth a row.
        vm.prank(alice);
        vm.expectRevert(LighterCore.AboveDepositCap.selector);
        vault.mintInstant(MINT_IN);

        // Nothing half-happened: no certificates, and no collateral taken.
        assertEq(cert.balanceOf(alice), held, "a refused mint still minted");

        // REDEMPTION IS UNAFFECTED — Design Law 2, and the half the row exists to promise.
        vm.prank(alice);
        vault.redeemInstant(held);
        assertEq(cert.balanceOf(alice), 0, "redemption was blocked by the venue's deposit cap");
        assertGt(usdg.balanceOf(alice), 0, "the redemption paid nothing");
    }

    /// @notice `forceExit`, the Law 2 backstop, also survives a venue refusing deposits.
    /// @dev The instant path above is served from the buffer. This is the queued path, and Global
    ///      Constraint 3 says it must never revert for a holder with a balance in any venue state.
    function test_forceExitSurvivesABindingDepositCap() public {
        vm.prank(alice);
        vault.mintInstant(MINT_IN);
        sim.settleBatch();
        uint256 held = cert.balanceOf(alice);

        sim.setDepositCapTicks(1); // one tick: the venue refuses essentially everything

        vm.prank(alice);
        uint256 id = vault.forceExit(held);
        assertGt(id, 0, "forceExit did not queue");
        assertEq(cert.balanceOf(alice), 0, "forceExit did not burn");
    }

    /// @notice A coarse tick size stops minting too, and for a reason that names the amount.
    /// @dev This is why `LighterCore.depositTickSize` defaults to 1 rather than to a guess at the
    ///      venue's real, still-unread value: a margin post is `netCollateral * targetMarginBps /
    ///      10_000` and is not a round number in any coarse tick, so a wrong tick would present as
    ///      a testnet that cannot mint at all, with nothing in any document to explain it.
    ///      Recorded as a test so the reason survives the next person who reads the default and
    ///      assumes it is a placeholder.
    function test_mintPausesCleanlyWhenTheTickSizeBinds() public {
        sim.setDepositTickSize(1e6); // 1 tUSDG granularity

        // 3_558.6 * 0.999 (fee) * 0.9 (target margin) is not a whole number of tUSDG.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LighterCore.LighterCore_DepositNotTickMultiple.selector, 3_199_537_260, 1e6)
        );
        vault.mintInstant(MINT_IN);

        assertEq(cert.balanceOf(alice), 0, "a refused mint still minted");
    }
}
