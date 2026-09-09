// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {CertVault} from "../src/CertVault.sol";
import {VaultFixture} from "./helpers/VaultFixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLighter} from "./mocks/MockLighter.sol";
// Task 4: the margin mechanic (and therefore InsufficientMargin) moved to the shared venue base
// that MockLighter and the deployable LighterSim both inherit. Solidity will not resolve an
// inherited error through the derived contract's name, so the selector is read from LighterCore.
import {LighterCore} from "../src/sim/LighterCore.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice Task 8b: proves the vault posts margin behind the perp position it opens on Lighter
///         (Law 1), that leverage stays bounded by contract constants no governance can widen
///         (Law 6), and that the resulting instant-redeem gate does not compromise Law 2's
///         unconditionally-open queued exits.
contract CertVaultMarginTest is VaultFixture {
    function test_mintPostsTargetShareAsMargin() public {
        uint256 amountIn = 3_558.6e6;
        uint256 bufferBefore = vault.hotBuffer();
        uint256 marginBefore = lighter.marginBalance();

        vm.prank(alice);
        vault.mintInstant(amountIn);

        uint256 fee = amountIn * 10 / 10_000; // mintFeeBps = 10
        uint256 net = amountIn - fee;
        uint256 expectedMarginPosted = net * 9_000 / 10_000; // targetMarginBps = 9_000

        assertEq(lighter.marginBalance(), marginBefore + expectedMarginPosted);
        assertEq(vault.hotBuffer(), bufferBefore + amountIn - expectedMarginPosted);
    }

    function test_mintWouldFailWithoutMargin() public {
        lighter.setRequiredMarginBps(5_000);

        vm.prank(alice);
        vault.mintInstant(3_558.6e6);

        // Step 3's fix: margin was posted before the hedge, so settlement does not revert.
        lighter.settleBatch();
        assertGt(lighter.marginBalance(), 0);

        // Load-bearing check: prove InsufficientMargin is a real gate, not a vacuous one. The
        // note that used to stand here said MockLighter tracks marginBalance and positionBase
        // GLOBALLY, so a second small order on the shared `lighter` would be covered by the
        // vault's own margin. Task 7 keys both by account index, so that is no longer true — a
        // second account's order is margined against the second account's own cash. The
        // independent mock below is kept anyway: it reproduces the historical failure exactly and
        // needs no second account to do it. `test_marginIsIsolatedPerAccount` in
        // test/sim/LighterSim.t.sol is the direct test of the per-account gate.
        // So, on an independent mock/account: the SAME-SIZED hedge order the vault above just submitted
        // (99_900 base ticks, the vault's certOut of 9.99e18 at sizeDecimals = 4), backed by only
        // bootstrap-sized dust margin instead of the 90% share _postMargin posts. This is exactly
        // the failure mode recorded in task-8b-report.md: 9 tests reverted with
        // InsufficientMargin() when Step 6 landed before Step 3 wired _postMargin in.
        MockLighter bareLighter = new MockLighter(IERC20(address(usdg)), ASSET_IDX, 4);
        bareLighter.setMarkPrice(MARKET, PX);
        // Task 7, item 3: settleBatch now REJECTS the individual under-margined order and
        // continues, because reverting the whole batch was a settlement denial of service (one
        // account's poison order stopped every other account's fills, permanently). This test's
        // assertion — the margin gate is a real gate, not a vacuous one — is unchanged and is worth
        // keeping in its sharpest form, so it runs in strict mode rather than being softened into
        // "an event was emitted". Nothing about the gate's threshold or its inputs changed.
        bareLighter.setStrictMode(true);
        usdg.mint(address(this), 1e6);
        usdg.approve(address(bareLighter), 1e6);
        bareLighter.deposit(address(this), ASSET_IDX, 0, 1e6); // ~$1 dust margin, no real backing
        uint48 idx = bareLighter.addressToAccountIndex(address(this));
        bareLighter.createOrder(idx, MARKET, 99_900, 35586, 0, 1); // same size as the vault's hedge
        vm.expectRevert(LighterCore.InsufficientMargin.selector);
        bareLighter.settleBatch();
    }

    function test_leverageStaysAtOrBelowTwo() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        lighter.settleBatch();

        int256 pos = lighter.positionBase(MARKET);
        uint256 absPos = pos >= 0 ? uint256(pos) : uint256(-pos);
        uint256 notional18 = absPos * lighter.markPrice(MARKET) / (10 ** 4); // sizeDecimals = 4
        uint256 marginBalance18 = lighter.marginBalance() * 1e12; // USDG has 6 decimals

        uint256 leverage = notional18 * 1e18 / marginBalance18;
        assertLe(leverage, 2e18);
    }

    function test_constructorRejectsTargetMarginBelowFloor() public {
        vm.expectRevert(CertVault.CertVault_TargetMarginOutOfBounds.selector);
        new CertVault(
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
                instantCap18: 10_000e18,
                settleBandBps: 500,
                targetMarginBps: 4_999
            }),
            VENUE_WITHDRAW_CAP,
            SETTLE_WINDOW,
            "UseCert TSLA",
            "uTSLA"
        );
    }

    function test_constructorRejectsTargetMarginAboveCeiling() public {
        vm.expectRevert(CertVault.CertVault_TargetMarginOutOfBounds.selector);
        new CertVault(
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
                instantCap18: 10_000e18,
                settleBandBps: 500,
                targetMarginBps: 10_001
            }),
            VENUE_WITHDRAW_CAP,
            SETTLE_WINDOW,
            "UseCert TSLA",
            "uTSLA"
        );
    }

    /// @notice Law 2 guard for this task: the fast path may route away, but the always-open
    ///         path must always still work. Both halves are required — this test is not
    ///         satisfied by the first assertion alone.
    function test_redeemInstantRoutesToQueuedWhenHotBufferShort() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        uint256 bal = cert.balanceOf(alice);

        // Drain the hot buffer directly, simulating an empty instant-redeem float.
        uint256 buf = vault.hotBuffer();
        vm.prank(address(vault));
        usdg.transfer(makeAddr("sink"), buf);
        assertEq(vault.hotBuffer(), 0);

        vm.prank(alice);
        vm.expectRevert(CertVault.CertVault_UseQueuedRedeem.selector);
        vault.redeemInstant(bal);

        // The always-open path must still work with the hot buffer empty.
        vm.prank(alice);
        uint256 id = vault.forceExit(bal);
        assertGt(id, 0);
        assertEq(cert.balanceOf(alice), 0);
    }

    /// @notice Task 8c: fromMargin is sized pro-rata by burned supply against postedMargin, not by
    ///         the current oracle price (see test_withdrawSizedProRataNotByPrice for the case where
    ///         that distinction actually bites).
    function test_queuedRedeemWithdrawsFromMargin() public {
        vm.prank(alice);
        uint256 id0 = vault.requestMint(50_000e6);
        lighter.settleBatch();
        vault.settleMint(id0, PX);
        uint256 bal = cert.balanceOf(alice);

        uint256 marginBefore = lighter.marginBalance();
        uint256 postedBefore = vault.postedMargin();
        uint256 supplyBefore = cert.totalSupply();
        uint256 expectedFromMargin = postedBefore * bal / supplyBefore;

        vm.prank(alice);
        uint256 id = vault.requestRedeem(bal);

        // Task 8d: the pro-rata share is now *allocated* to marginPendingRecall, not withdrawn
        // from Lighter at request time — margin behind an open position is locked by the venue's
        // initial margin requirement until the closing order fills in a batch, so
        // lighter.marginBalance() is untouched here. See CertVaultRecall.t.sol for the separate,
        // retryable recallMargin() step that actually withdraws once the position has closed.
        assertEq(lighter.marginBalance(), marginBefore);
        assertEq(vault.postedMargin(), postedBefore - expectedFromMargin);
        assertEq(vault.marginPendingRecall(), expectedFromMargin);

        lighter.settleBatch();

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.claimRedeem(id);
        assertGt(out, 0);
        assertEq(usdg.balanceOf(alice), before + out);
    }

    // _setPrice now lives in VaultFixture (final review wave) so CertVaultRecall.t.sol can drive
    // the same price move for C1's payability proof. Its behaviour is unchanged.

    /// @notice Task 8c's core proof: the margin withdrawal request tracks the holder's share of
    ///         what was actually posted, not a recomputation off the (now higher) price.
    function test_withdrawSizedProRataNotByPrice() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        uint256 bal = cert.balanceOf(alice);
        uint256 supplyBefore = cert.totalSupply();
        uint256 postedBefore = vault.postedMargin();
        uint256 marginBefore = lighter.marginBalance();

        uint256 raisedPx = PX * 120 / 100; // +20%
        _setPrice(raisedPx);

        // What the OLD, price-derived sizing would have requested at the raised price — this is
        // strictly more than was ever posted, which is exactly the defect this task fixes.
        uint256 gross18 = bal * raisedPx / 1e18;
        uint256 fee18 = gross18 * 10 / 10_000; // redeemFeeBps = 10
        uint256 owedCollateral = (gross18 - fee18) / 1e12; // 18 -> 6 decimals
        uint256 oldFromMargin = owedCollateral * 9_000 / 10_000; // targetMarginBps = 9_000

        uint256 expectedFromMargin = postedBefore * bal / supplyBefore;
        assertLt(expectedFromMargin, oldFromMargin);

        vm.prank(alice);
        vault.requestRedeem(bal);

        // Task 8d: the pro-rata share is allocated to marginPendingRecall, not withdrawn from
        // Lighter at request time (see _queueExit's doc comment) — so lighter.marginBalance() is
        // untouched here. The core proof this test exists for — sizing tracks what was actually
        // posted, not a recomputation off the raised price — now lives in marginPendingRecall.
        assertEq(lighter.marginBalance(), marginBefore);
        assertEq(vault.marginPendingRecall(), expectedFromMargin);
        assertEq(vault.postedMargin(), 0);
    }

    /// @notice Task 8d: _queueExit no longer calls lighter.withdraw at all — the venue's deposit
    ///         cap is therefore irrelevant to forceExit itself (it only matters to a later
    ///         recallMargin() call; see CertVaultRecall.t.sol's
    ///         test_recallMarginIsRetryableAndFailOpen for that retryability proof). This test
    ///         previously proved forceExit survives a refused withdrawal by restoring postedMargin
    ///         after a caught revert; that restore path no longer exists because there is no
    ///         withdrawal to refuse here. What must still hold: forceExit succeeds unconditionally
    ///         regardless of depositCapTicks, and its pro-rata share is allocated away from
    ///         postedMargin into marginPendingRecall permanently, not restored.
    function test_forceExitSurvivesVenueRefusingWithdraw() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        uint256 bal = cert.balanceOf(alice);
        uint256 postedBefore = vault.postedMargin();

        lighter.setDepositCapTicks(1); // would refuse a real withdrawal request; irrelevant here

        vm.prank(alice);
        uint256 id = vault.forceExit(bal);

        assertGt(id, 0);
        assertEq(cert.balanceOf(alice), 0);
        (address user,,,, bool paid) = vault.redeemReceipts(id);
        assertEq(user, alice);
        assertFalse(paid);
        assertEq(vault.postedMargin(), 0); // fully allocated away, not restored
        assertEq(vault.marginPendingRecall(), postedBefore); // allocation landed in the recall counter
    }

    /// @notice Load-bearing regression: under the old price-derived sizing, fromMargin could
    ///         outgrow postedMargin after a large price move, and forceExit — the Law 2
    ///         backstop — could hard-revert on the venue's depositCapTicks check. The task-8c
    ///         report records verifying this test fails when the old sizing is restored.
    /// @dev SCOPE (C1, final review wave): this test asserts only that forceExit does not revert.
    ///      It does NOT assert the resulting receipt is payable, and that omission is precisely
    ///      why C1 shipped — the vault could queue this exit and then never ask the venue for
    ///      more than the deposited cost basis, leaving a burned holder with an unpayable
    ///      receipt. Payability after a large price rise is covered by
    ///      CertVaultRecall.t.sol's test_receiptIsPayableAfterLargePriceRise, which asserts the
    ///      holder is paid IN FULL. Do not read non-reversion here as payability.
    function test_forceExitSurvivesAfterLargePriceRise() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        uint256 bal = cert.balanceOf(alice);

        _setPrice(PX * 10); // 10x

        vm.prank(alice);
        uint256 id = vault.forceExit(bal);

        assertGt(id, 0);
        assertEq(cert.balanceOf(alice), 0);
    }

    /// @notice Redeeming in unequal parts must not strand margin: each partial redemption
    ///         allocates exactly its pro-rata share of what remains posted to marginPendingRecall,
    ///         and the sum across all parts recovers the original posted margin (up to
    ///         floor-division dust).
    /// @dev Task 8d: this test previously measured the sum via lighter.marginBalance() dropping,
    ///      because _queueExit used to submit a withdrawal per partial redeem. It no longer does
    ///      (margin behind an open position is locked by IMR until the closing order fills — see
    ///      _queueExit's doc comment) — so the conservation proof now runs against
    ///      marginPendingRecall, which accumulates the allocation instead of lighter.marginBalance
    ///      dropping. lighter.marginBalance() is asserted unchanged throughout.
    function test_partialRedemptionsDoNotStrandMargin() public {
        vm.prank(alice);
        vault.mintInstant(3_558.6e6);
        uint256 bal = cert.balanceOf(alice);

        uint256 part1 = bal * 20 / 100;
        uint256 part2 = bal * 35 / 100;
        uint256 part3 = bal - part1 - part2; // remainder: sums exactly to bal

        uint256 originalPosted = vault.postedMargin();
        uint256 marginBefore = lighter.marginBalance();
        uint256 totalAllocated;

        totalAllocated += _redeemPartAndCheck(part1);
        totalAllocated += _redeemPartAndCheck(part2);
        totalAllocated += _redeemPartAndCheck(part3);

        assertEq(cert.balanceOf(alice), 0);
        assertEq(vault.postedMargin(), 0);
        assertEq(vault.marginPendingRecall(), totalAllocated);
        assertEq(lighter.marginBalance(), marginBefore); // untouched — no withdrawal submitted
        assertApproxEqAbs(totalAllocated, originalPosted, 2);
    }

    /// @dev Redeems `certIn` from alice, asserting postedMargin lands exactly where the same
    ///      pro-rata formula the contract uses says it should, and returns the amount allocated to
    ///      marginPendingRecall (Task 8d: allocation, not a venue withdrawal — see _queueExit).
    function _redeemPartAndCheck(uint256 certIn) internal returns (uint256 allocated) {
        uint256 supply = cert.totalSupply();
        uint256 posted = vault.postedMargin();
        uint256 expectedFromMargin = posted * certIn / supply;
        uint256 pendingBefore = vault.marginPendingRecall();

        vm.prank(alice);
        vault.requestRedeem(certIn);

        allocated = vault.marginPendingRecall() - pendingBefore;
        assertEq(allocated, expectedFromMargin);
        assertEq(vault.postedMargin(), posted - expectedFromMargin);
    }

    /// @notice postedMargin must account for bootstrap()'s registering dust deposit too, so the
    ///         counter matches every deposit the vault has ever made to Lighter.
    function test_postedMarginCountsBootstrapDust() public view {
        // VaultFixture.setUp() already called bootstrap(); nothing else has posted margin since.
        assertEq(vault.postedMargin(), 1e6); // dust = 10 ** collateralDecimals, USDG has 6
    }

    /// @notice L-3 (LOW, external C1 audit): all six of CertVault's addresses are immutable, so a
    ///         mistyped one is unrepairable and used to surface later as an anonymous low-level
    ///         failure at whichever call site touched it first — a zero `collateral` on the
    ///         decimals() read in the constructor, a zero `lighter` only at bootstrap().
    /// @dev Every one of the six is exercised, in a loop over the slot being zeroed, so no field
    ///      can be added to either struct and quietly left unvalidated.
    function test_constructorRejectsEveryZeroDependency() public {
        for (uint256 slot = 0; slot < 6; ++slot) {
            CertVault.Deps memory d = CertVault.Deps({
                lighter: slot == 0 ? address(0) : address(lighter),
                oracle: slot == 1 ? address(0) : address(oracle),
                registry: slot == 2 ? address(0) : address(reg),
                capacity: slot == 3 ? address(0) : address(cap),
                governance: slot == 4 ? address(0) : gov
            });
            CertVault.VaultConfig memory c = CertVault.VaultConfig({
                collateral: slot == 5 ? address(0) : address(usdg),
                collateralAssetIndex: ASSET_IDX,
                routeType: 0,
                marketIndex: MARKET,
                sizeDecimals: 4,
                mintFeeBps: 10,
                redeemFeeBps: 10,
                instantCap18: 10_000e18,
                settleBandBps: 500,
                targetMarginBps: 9_000
            });
            vm.expectRevert(CertVault.CertVault_ZeroAddress.selector);
            new CertVault(d, c, VENUE_WITHDRAW_CAP, SETTLE_WINDOW, "UseCert TSLA", "uTSLA");
        }
    }

    // ---------------------------------------------------------------------------------------
    // FINDING 1, from re-tracing forceExit END TO END after the valuation fix. Three pieces of
    // deploy config decided whether Law 2's backstop could revert on arithmetic, and none was
    // bounded. The multiplications themselves are now Math.mulDiv (see _baseAmount, _queueExit and
    // redeemInstant); these bounds are the other half of each argument, and without them the
    // enumeration in the report would have had to read "unreachable if the deployer was sensible".
    // ---------------------------------------------------------------------------------------

    function _deps() internal view returns (CertVault.Deps memory) {
        return CertVault.Deps({
            lighter: address(lighter),
            oracle: address(oracle),
            registry: address(reg),
            capacity: address(cap),
            governance: gov
        });
    }

    function _cfgWith(address collateral, uint8 sizeDecimals_, uint256 mintFeeBps_, uint256 redeemFeeBps_)
        internal
        view
        returns (CertVault.VaultConfig memory)
    {
        return CertVault.VaultConfig({
            collateral: collateral,
            collateralAssetIndex: ASSET_IDX,
            routeType: 0,
            marketIndex: MARKET,
            sizeDecimals: sizeDecimals_,
            mintFeeBps: mintFeeBps_,
            redeemFeeBps: redeemFeeBps_,
            instantCap18: 10_000e18,
            settleBandBps: 500,
            targetMarginBps: 9_000
        });
    }

    /// @notice `10 ** cfg.sizeDecimals` is evaluated in _quantiseToVenue and in _baseAmount (the
    ///         latter being the FIRST statement _tryHedge executes, outside every try/catch that
    ///         helper owns). Past 77 that exponentiation panics on its own.
    /// @dev ROBUSTNESS, NOT LAW 2, and the distinction is asserted rather than blurred: the same
    ///      panic hits the mint path, so a vault configured this way can never issue a certificate
    ///      and therefore has no holder to strand. What it produces without this bound is a
    ///      deployed contract that looks alive and panics anonymously on every call. The one
    ///      config bound that IS a Law 2 fix is redeemFeeBps, below.
    /// @dev LOAD-BEARING: remove the MAX_VENUE_DECIMALS check and both cases below deploy. Both 19
    ///      and 78 are rejected — 19 because that is where the bound is drawn, 78 because that is
    ///      where the panic actually begins, and a bound placed at the panic is a bound that only
    ///      just holds.
    function test_constructorRejectsAnAbsurdSizeDecimals() public {
        vm.expectRevert(CertVault.CertVault_ConfigOutOfBounds.selector);
        new CertVault(_deps(), _cfgWith(address(usdg), 19, 10, 10), VENUE_WITHDRAW_CAP, SETTLE_WINDOW, "x", "x");

        vm.expectRevert(CertVault.CertVault_ConfigOutOfBounds.selector);
        new CertVault(_deps(), _cfgWith(address(usdg), 78, 10, 10), VENUE_WITHDRAW_CAP, SETTLE_WINDOW, "x", "x");
    }

    /// @notice THE ONE REACHABLE LAW 2 BREACH IN THIS GROUP, and it was measured. A redeemFeeBps
    ///         above 10_000 underflows `gross18 - fee18` in both redeemInstant and _queueExit while
    ///         leaving minting untouched (that path reads mintFeeBps) — so the vault mints happily,
    ///         issues real certificates to real holders, and then panics 0x11 inside forceExit for
    ///         every one of them, with no permissionless escape and no setter to repair it.
    /// @dev MEASURED on a fixture vault deployed at redeemFeeBps = 10_001 with the bound removed:
    ///      the holder minted 9.9945 certificates and forceExit reverted with panic 0x11.
    ///      mintFeeBps is bounded by the same line but is the harmless direction — it kills
    ///      minting, so no holder ever exists to be stranded.
    function test_constructorRejectsAFeeAboveOneHundredPercent() public {
        vm.expectRevert(CertVault.CertVault_ConfigOutOfBounds.selector);
        new CertVault(_deps(), _cfgWith(address(usdg), 4, 10_001, 10), VENUE_WITHDRAW_CAP, SETTLE_WINDOW, "x", "x");

        vm.expectRevert(CertVault.CertVault_ConfigOutOfBounds.selector);
        new CertVault(_deps(), _cfgWith(address(usdg), 4, 10, 10_001), VENUE_WITHDRAW_CAP, SETTLE_WINDOW, "x", "x");
    }

    /// @notice Collateral decimals above 18 make _from18 MULTIPLY rather than divide, which is the
    ///         overflow direction on the claimRedeem payout path, and `10 ** (decimals - 18)`
    ///         panics outright past 95. Robustness rather than Law 2, for the same reason as
    ///         sizeDecimals above: _to18 is on the mint path too, so a vault this misconfigured
    ///         never issues a certificate. Bounded at 18, where _from18 is division-only and
    ///         cannot overflow at all. Every realistic collateral is 6 or 18.
    function test_constructorRejectsCollateralDecimalsAboveEighteen() public {
        MockERC20 wide = new MockERC20("WIDE", "WIDE", 24);
        vm.expectRevert(CertVault.CertVault_ConfigOutOfBounds.selector);
        new CertVault(_deps(), _cfgWith(address(wide), 4, 10, 10), VENUE_WITHDRAW_CAP, SETTLE_WINDOW, "x", "x");

        MockERC20 absurd = new MockERC20("HUGE", "HUGE", 96);
        vm.expectRevert(CertVault.CertVault_ConfigOutOfBounds.selector);
        new CertVault(_deps(), _cfgWith(address(absurd), 4, 10, 10), VENUE_WITHDRAW_CAP, SETTLE_WINDOW, "x", "x");
    }

    /// @notice The bounds are ceilings, not narrowings: 18 on both decimals fields still deploys,
    ///         and so does a zero fee. A bound that rejected a legitimate configuration would be a
    ///         worse bug than the one it closed.
    function test_constructorAcceptsTheBoundaryConfiguration() public {
        MockERC20 eighteen = new MockERC20("E18", "E18", 18);
        CertVault v =
            new CertVault(_deps(), _cfgWith(address(eighteen), 18, 0, 0), VENUE_WITHDRAW_CAP, SETTLE_WINDOW, "x", "x");
        assertEq(address(v.certificate()) != address(0), true);
    }
}
