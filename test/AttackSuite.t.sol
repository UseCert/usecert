// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultFixture} from "./helpers/VaultFixture.sol";
import {CertVault} from "../src/CertVault.sol";
import {Certificate} from "../src/Certificate.sol";
import {CertOracle} from "../src/CertOracle.sol";
import {CertFactory} from "../src/CertFactory.sol";
import {SolvencyRegistry} from "../src/SolvencyRegistry.sol";
import {CapacityOracle} from "../src/CapacityOracle.sol";
import {BufferBook} from "../src/BufferBook.sol";
import {MockLighter} from "./mocks/MockLighter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

// ---------------------------------------------------------------- hostile tokens

/// @notice ERC20 that hands control to an attacker on every transfer, before balances settle.
///         Models ERC777/ERC1363-style callback collateral.
contract ReentrantToken is ERC20 {
    address public hook;
    bool public armed;
    uint256 public depth;

    constructor() ERC20("Hostile", "HOST") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function arm(address h) external {
        hook = h;
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (armed && hook != address(0) && depth == 0) {
            depth = 1;
            (bool ok,) = hook.call(abi.encodeWithSignature("reenter()"));
            ok;
            depth = 0;
        }
        super._update(from, to, value);
    }
}

/// @notice ERC20 that keeps 1% of every transfer. Models a stablecoin with its fee switch on.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("FeeCoin", "FEE") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xFEE), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @notice Drives reentrant calls back into the vault mid-transfer.
contract Reenterer {
    CertVault public vault;
    IERC20 public token;
    bytes public payload;
    uint256 public succeeded;
    uint256 public attempts;

    function setup(CertVault v, IERC20 t) external {
        vault = v;
        token = t;
        t.approve(address(v), type(uint256).max);
    }

    function setPayload(bytes calldata p) external {
        payload = p;
    }

    function reenter() external {
        if (payload.length == 0) return;
        attempts++;
        (bool ok,) = address(vault).call(payload);
        if (ok) succeeded++;
    }

    function go(bytes calldata p) external returns (bool) {
        (bool ok,) = address(vault).call(p);
        return ok;
    }
}

// ---------------------------------------------------------------- the battery

contract AttackSuiteTest is VaultFixture {
    address internal eve = makeAddr("eve");
    address internal mallory = makeAddr("mallory");

    // ============================================================ 1. ACCESS CONTROL

    /// @notice Every privileged entry point, called by an unauthorised address.
    function test_ATK_accessControlSweep() public {
        vm.startPrank(eve);

        vm.expectRevert(CertVault.CertVault_OnlyGovernance.selector);
        vault.closeAll();

        vm.expectRevert(CertVault.CertVault_OnlyAttester.selector);
        vault.accrueFunding(1e18);

        vm.expectRevert(CertOracle.CertOracle_OnlyAttester.selector);
        oracle.setMarkPrice(1e18);

        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_OnlyAttester.selector);
        reg.attest(address(vault), 99, 1, 1, 1);

        vm.expectRevert(CapacityOracle.CapacityOracle_OnlyGovernance.selector);
        cap.setDepthBps(2000);

        vm.expectRevert(CapacityOracle.CapacityOracle_OnlyGovernance.selector);
        cap.setAbsoluteCap(address(vault), type(uint256).max);

        vm.expectRevert(Certificate.Certificate_OnlyVault.selector);
        cert.mint(eve, 1e18);

        vm.expectRevert(Certificate.Certificate_OnlyVault.selector);
        cert.burn(alice, 1e18);

        vm.expectRevert(BufferBook.BufferBook_OnlyVault.selector);
        book.accrue(address(vault), 1e30);

        vm.expectRevert(BufferBook.BufferBook_OnlyVault.selector);
        book.configure(address(vault), 0, 0, 0, 0);

        vm.stopPrank();
        emit log("HOLDS: all 10 privileged entry points reject an unauthorised caller");
    }

    /// @notice Governance cannot escape the immutable capacity ceiling.
    function test_ATK_governanceCannotExceedAbsoluteCapCeiling() public {
        vm.prank(gov);
        vm.expectRevert(CapacityOracle.CapacityOracle_CapAboveCeiling.selector);
        cap.setAbsoluteCap(address(vault), MAX_ABSOLUTE_CAP + 1);

        vm.prank(gov);
        vm.expectRevert(CapacityOracle.CapacityOracle_DepthOutOfBounds.selector);
        cap.setDepthBps(3001);

        emit log("HOLDS: immutable ceilings bound governance in both directions");
    }

    // ============================================================ 2. REENTRANCY

    function _deployHostileStack(address collateral)
        internal
        returns (CertVault v, Certificate c, MockLighter l)
    {
        l = new MockLighter(IERC20(collateral), ASSET_IDX, 4);
        SolvencyRegistry r = new SolvencyRegistry(attester);
        CapacityOracle cp =
            new CapacityOracle(address(r), gov, 1000, 100, 3000, 300, MAX_ABSOLUTE_CAP);
        v = new CertVault(
            CertVault.Deps({
                lighter: address(l),
                oracle: address(oracle),
                registry: address(r),
                capacity: address(cp),
                governance: gov
            }),
            CertVault.VaultConfig({
                collateral: collateral,
                collateralAssetIndex: ASSET_IDX,
                routeType: 0,
                marketIndex: MARKET,
                sizeDecimals: 4,
                mintFeeBps: 10,
                redeemFeeBps: 10,
                instantCap18: 10_000e18,
                settleBandBps: 500,
                targetMarginBps: 9_000
            }),
            VENUE_WITHDRAW_CAP,
            SETTLE_WINDOW,
            "Hostile TSLA",
            "hTSLA"
        );
        c = Certificate(v.certificate());
        vm.prank(gov);
        cp.setAbsoluteCap(address(v), 5_000_000e18);
        vm.prank(attester);
        r.attest(address(v), 1, 0, 0, 1_190_000e18);
        l.setMarkPrice(MARKET, PX);
    }

    /// @notice Callback collateral, reentering mintInstant from inside mintInstant's own pull.
    function test_ATK_reentrancyOnMint() public {
        ReentrantToken t = new ReentrantToken();
        (CertVault v, Certificate c, MockLighter l) = _deployHostileStack(address(t));

        Reenterer r = new Reenterer();
        r.setup(v, IERC20(address(t)));
        t.mint(address(r), 500_000e6);
        t.mint(address(this), 200_000e6);
        t.approve(address(v), type(uint256).max);

        v.seedBuffer(100_000e6);
        v.bootstrap();
        l.settleBatch();

        r.setPayload(abi.encodeWithSelector(CertVault.mintInstant.selector, uint256(1_000e6)));
        t.arm(address(r));

        bool ok = r.go(abi.encodeWithSelector(CertVault.mintInstant.selector, uint256(1_000e6)));
        t.disarm();

        emit log_named_uint("reentrant attempts     ", r.attempts());
        emit log_named_uint("reentrant successes    ", r.succeeded());
        emit log_named_decimal_uint("attacker certificates  ", c.balanceOf(address(r)), 18);
        emit log_named_decimal_uint("attacker collateral out", 500_000e6 - t.balanceOf(address(r)), 6);
        emit log_named_string("outer call succeeded", ok ? "yes" : "no");

        // Value in must still cover value out: reentrancy must not mint free certificates.
        uint256 spent = 500_000e6 - t.balanceOf(address(r));
        uint256 got18 = c.balanceOf(address(r)) * PX / 1e18;
        assertLe(got18 / 1e12, spent, "REENTRANCY: minted more value than was paid in");
        emit log("HOLDS: reentrant mint pays full collateral for every certificate");
    }

    /// @notice Reentering the payout paths (claimRedeem / redeemInstant) mid-transfer.
    function test_ATK_reentrancyOnPayoutPaths() public {
        ReentrantToken t = new ReentrantToken();
        (CertVault v, Certificate c, MockLighter l) = _deployHostileStack(address(t));

        Reenterer r = new Reenterer();
        r.setup(v, IERC20(address(t)));
        t.mint(address(r), 500_000e6);
        t.mint(address(this), 500_000e6);
        t.approve(address(v), type(uint256).max);
        v.seedBuffer(200_000e6);
        v.bootstrap();
        l.settleBatch();

        r.go(abi.encodeWithSelector(CertVault.mintInstant.selector, uint256(5_000e6)));
        l.settleBatch();
        uint256 certs = c.balanceOf(address(r));

        // Queue an exit, then try to double-claim it from inside its own payout.
        r.go(abi.encodeWithSelector(CertVault.requestRedeem.selector, certs / 2));
        uint256 receiptId = 1; // first receipt this vault issued

        uint256 balBefore = t.balanceOf(address(r));
        r.setPayload(abi.encodeWithSelector(CertVault.claimRedeem.selector, receiptId));
        t.arm(address(r));
        r.go(abi.encodeWithSelector(CertVault.claimRedeem.selector, receiptId));
        t.disarm();

        uint256 received = t.balanceOf(address(r)) - balBefore;
        (, uint256 owed18,,,) = v.redeemReceipts(receiptId);

        emit log_named_uint("reentrant claim attempts ", r.attempts());
        emit log_named_uint("reentrant claim successes", r.succeeded());
        emit log_named_decimal_uint("owed by receipt          ", owed18 / 1e12, 6);
        emit log_named_decimal_uint("actually received        ", received, 6);

        assertLe(received, owed18 / 1e12, "REENTRANCY: claimed more than the receipt owed");
        emit log("HOLDS: r.paid is set before transfer - no double claim");
    }

    // ============================================================ 3. HOSTILE COLLATERAL

    /// @notice Fee-on-transfer collateral: the vault credits what was SENT, not what ARRIVED.
    function test_ATK_feeOnTransferCollateralOverMints() public {
        FeeOnTransferToken t = new FeeOnTransferToken();
        (CertVault v, Certificate c, MockLighter l) = _deployHostileStack(address(t));

        t.mint(address(this), 500_000e6);
        t.approve(address(v), type(uint256).max);
        v.seedBuffer(100_000e6);
        v.bootstrap();
        l.settleBatch();

        uint256 sent = 10_000e6;
        uint256 mineBefore = t.balanceOf(address(this));
        v.mintInstant(sent);
        uint256 leftMyWallet = mineBefore - t.balanceOf(address(this));
        uint256 arrived = leftMyWallet * 99 / 100; // the token keeps 1% in flight

        uint256 minted = c.totalSupply();
        uint256 backedBy = arrived; // what the vault really got, in token units

        emit log_named_decimal_uint("collateral sent    ", sent, 6);
        emit log_named_decimal_uint("collateral arrived ", arrived, 6);
        emit log_named_decimal_uint("certificates minted", minted, 18);
        emit log_named_decimal_uint("value minted       ", minted * PX / 1e18 / 1e12, 6);

        assertLe(minted * PX / 1e18 / 1e12, backedBy, "FEE-ON-TRANSFER: minted value exceeds collateral received");
    }

    // ============================================================ 4. RECEIPT CONFUSION

    /// @notice Mint and redeem receipts share one id counter. Try to cross the streams.
    function test_ATK_receiptTypeConfusion() public {
        vm.prank(alice);
        uint256 mintId = vault.requestMint(50_000e6);

        vm.prank(alice);
        vault.mintInstant(5_000e6);
        uint256 aliceCerts = cert.balanceOf(alice);
        vm.prank(alice);
        uint256 redeemId = vault.requestRedeem(aliceCerts);

        assertTrue(mintId != redeemId, "ids collided");

        // A redeem receipt is not settleable as a mint.
        vm.expectRevert(CertVault.CertVault_BadReceipt.selector);
        vault.settleMint(redeemId, PX);

        // A mint receipt is not claimable as a redeem.
        vm.expectRevert(CertVault.CertVault_NothingToClaim.selector);
        vault.claimRedeem(mintId);

        // Neither is a refund.
        vm.expectRevert(CertVault.CertVault_BadReceipt.selector);
        vault.stageRefund(redeemId);

        emit log("HOLDS: shared id counter, disjoint mappings, no cross-type confusion");
    }

    /// @notice Double-settle, double-refund, double-claim.
    function test_ATK_doubleSpendOnReceipts() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        vault.settleMint(id, PX);
        vm.expectRevert(CertVault.CertVault_BadReceipt.selector);
        vault.settleMint(id, PX);

        vm.prank(alice);
        vault.mintInstant(5_000e6);
        uint256 bal = cert.balanceOf(alice);
        vm.prank(alice);
        uint256 rid = vault.requestRedeem(bal);
        vault.claimRedeem(rid);
        vm.expectRevert(CertVault.CertVault_NothingToClaim.selector);
        vault.claimRedeem(rid);

        emit log("HOLDS: settled/paid flags block replay on every receipt path");
    }

    // ============================================================ 5. ATOMIC / FLASH-LOAN SHAPE

    /// @notice Mint and redeem in one transaction, the shape a flash loan would take.
    function test_ATK_atomicMintRedeemRoundTrip() public {
        usdg.mint(eve, 500_000e6);
        vm.startPrank(eve);
        usdg.approve(address(vault), type(uint256).max);

        uint256 before = usdg.balanceOf(eve);
        vault.mintInstant(10_000e6);
        vault.redeemInstant(cert.balanceOf(eve));
        uint256 afterBal = usdg.balanceOf(eve);
        vm.stopPrank();

        emit log_named_decimal_uint("round-trip cost (USDG)", before - afterBal, 6);
        assertLt(afterBal, before, "ATOMIC ARB: round trip must not be profitable");
        emit log("HOLDS: mint fee + redeem fee make the atomic round trip strictly lossy");
    }

    /// @notice Donate collateral straight to the vault and look for a share-price style break.
    function test_ATK_donationAttack() public {
        vm.prank(alice);
        vault.mintInstant(10_000e6);
        uint256 certsBefore = cert.balanceOf(alice);

        usdg.mint(eve, 100_000e6);
        vm.prank(eve);
        usdg.transfer(address(vault), 100_000e6); // pure donation

        vm.prank(alice);
        uint256 out = vault.redeemInstant(certsBefore);

        emit log_named_decimal_uint("alice redeemed for", out, 6);
        // Certificates price off the oracle, never off vault balance: a donation must not move it.
        assertApproxEqRel(out, certsBefore * PX / 1e18 / 1e12 * 9_990 / 10_000, 1e15);
        emit log("HOLDS: oracle-priced, not NAV-priced - donation cannot move redemption value");
    }

    // ============================================================ 6. ORACLE ABUSE

    function test_ATK_oracleHostileInputs() public {
        vm.prank(alice);
        vault.mintInstant(10_000e6); // alice needs certificates to exit with

        // Negative price
        feed.set(-1, block.timestamp);
        vm.expectRevert(CertOracle.CertOracle_NonPositivePrice.selector);
        oracle.px();
        assertFalse(oracle.mintAllowed(), "negative price must pause mint");

        // Feed reverts entirely
        feed.set(int256(PX / 1e10), block.timestamp);
        feed.setShouldRevert(true);
        assertFalse(oracle.mintAllowed(), "dead feed must pause mint");
        (uint256 fallbackPx,) = oracle.pxUnguarded();
        assertGt(fallbackPx, 0, "LAW 2: pxUnguarded must still answer");
        vm.prank(alice);
        vault.forceExit(1e15); // must not revert with a dead feed
        feed.setShouldRevert(false);

        // Absurd decimals
        feed.setDecimals(200);
        assertFalse(oracle.mintAllowed(), "absurd decimals must pause mint");
        (uint256 px2,) = oracle.pxUnguarded();
        assertGt(px2, 0, "LAW 2: still answers on absurd decimals");
        feed.setDecimals(8);

        // Future timestamp
        feed.set(int256(PX / 1e10), block.timestamp + 10_000);
        vm.expectRevert(CertOracle.CertOracle_StalePrice.selector);
        oracle.px();
        vm.prank(alice);
        vault.forceExit(1e15); // Law 2 backstop survives a broken feed

        emit log("HOLDS: every hostile feed input pauses mint and leaves forceExit open");
    }

    // ============================================================ 7. GRIEFING / DoS

    /// @notice A stranger cannot block redemption by any permissionless call.
    function test_ATK_cannotGriefRedemption() public {
        vm.prank(alice);
        vault.mintInstant(10_000e6);
        uint256 certs = cert.balanceOf(alice);

        // Eve tries everything permissionless she can reach.
        vm.startPrank(eve);
        vault.recallMargin();
        oracle.pokeLastGood();
        try vault.rebalance() {} catch {}
        vm.stopPrank();
        _drainHotBuffer();

        vm.prank(alice);
        uint256 rid = vault.forceExit(certs);
        assertGt(rid, 0, "LAW 2: forceExit must always issue a receipt");
        emit log("HOLDS: no permissionless call blocks the exit path");
    }

    /// @notice Unbounded attester input reaching an unchecked multiplication.
    function test_ATK_attesterCanBrickMintingViaBufferOverflow() public {
        vm.prank(alice);
        vault.mintInstant(10_000e6); // supply exists before the brick

        vm.prank(attester);
        vault.accrueFunding(int256(2 ** 250)); // buffer * 100 now overflows uint256

        vm.expectRevert(); // panic 0x11 inside BufferBook.capacity18
        book.capacity18(address(vault));

        vm.prank(alice);
        vm.expectRevert();
        vault.mintInstant(1_000e6);

        // Redemption must survive it.
        emit log("Law 2 check with a bricked buffer:");
        vm.prank(alice);
        vault.forceExit(1e15);
        emit log("  forceExit still works");

        assertTrue(true);
    }

    /// @notice Systematic downward rounding of the hedge on every mint.
    function test_ATK_hedgeRoundsDownEveryMint() public {
        usdg.mint(eve, 500_000e6);
        vm.startPrank(eve);
        usdg.approve(address(vault), type(uint256).max);

        uint256 totalCerts;
        for (uint256 i = 0; i < 25; i++) {
            totalCerts += vault.mintInstant(101e6 + i);
        }
        vm.stopPrank();
        lighter.settleBatch();

        uint256 hedged = uint256(lighter.positionBase(MARKET)); // base ticks, 4 decimals
        uint256 hedged18 = hedged * 1e18 / 1e4;

        emit log_named_decimal_uint("certificates minted", totalCerts, 18);
        emit log_named_decimal_uint("certificates hedged", hedged18, 18);
        emit log_named_decimal_uint("shortfall (certs)  ", totalCerts - hedged18, 18);
        emit log_named_decimal_uint("shortfall value  $ ", (totalCerts - hedged18) * PX / 1e18, 18);

        assertGe(hedged18, totalCerts, "ROUNDING: hedge must not systematically undershoot supply");
    }

    // ============================================================ 8. ZERO / DUST

    function test_ATK_zeroAmountSweep() public {
        vm.startPrank(eve);
        vm.expectRevert(CertVault.CertVault_ZeroAmount.selector);
        vault.mintInstant(0);
        vm.expectRevert(CertVault.CertVault_ZeroAmount.selector);
        vault.requestMint(0);
        vm.expectRevert(CertVault.CertVault_ZeroAmount.selector);
        vault.redeemInstant(0);
        vm.expectRevert(CertVault.CertVault_ZeroAmount.selector);
        vault.requestRedeem(0);
        vm.expectRevert(CertVault.CertVault_ZeroAmount.selector);
        vault.forceExit(0);
        vm.stopPrank();

        int256 posBefore = lighter.positionBase(MARKET);
        assertEq(posBefore, 0, "no position yet");
        emit log("HOLDS: every entry point refuses 0 before it can reach the close-all primitive");
    }

    /// @notice A dust mint must not mint certificates it cannot hedge.
    function test_ATK_dustMintCannotCreateUnhedgedSupply() public {
        usdg.mint(eve, 1_000e6);
        vm.startPrank(eve);
        usdg.approve(address(vault), type(uint256).max);
        vm.expectRevert(CertVault.CertVault_ZeroHedgeAmount.selector);
        vault.mintInstant(100); // 0.0001 USDG
        vm.stopPrank();
        emit log("HOLDS: dust mint reverts rather than minting an unhedgeable certificate");
    }

    // ============================================================ 9. FACTORY

    function test_ATK_factoryGuards() public {
        CertFactory f = new CertFactory(address(lighter), address(reg), address(cap), gov);

        vm.prank(eve);
        vm.expectRevert(CertFactory.CertFactory_UnknownVault.selector);
        f.enable(address(vault));

        vm.prank(eve);
        vm.expectRevert(CertFactory.CertFactory_OnlyGovernance.selector);
        f.deployVault(
            address(oracle),
            CertVault.VaultConfig({
                collateral: address(usdg),
                collateralAssetIndex: ASSET_IDX,
                routeType: 0,
                marketIndex: MARKET,
                sizeDecimals: 4,
                mintFeeBps: 10,
                redeemFeeBps: 10,
                instantCap18: 1e18,
                settleBandBps: 500,
                targetMarginBps: 9_000
            }),
            VENUE_WITHDRAW_CAP,
            SETTLE_WINDOW,
            "x",
            "x"
        );
        emit log("HOLDS: factory rejects unknown vaults and non-governance deploys");
    }

    /// @notice A vault cannot be deployed above 2x leverage, by anyone, ever.
    function test_ATK_cannotDeployOverLeveredVault() public {
        vm.prank(gov);
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
                instantCap18: 1e18,
                settleBandBps: 500,
                targetMarginBps: 4_999
            }),
            VENUE_WITHDRAW_CAP,
            SETTLE_WINDOW,
            "x",
            "x"
        );
        emit log("HOLDS: MIN_TARGET_MARGIN_BPS is enforced at construction, with no setter after");
    }
}
