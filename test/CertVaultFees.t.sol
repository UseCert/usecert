// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {VaultFixture} from "./helpers/VaultFixture.sol";
import {CertVault} from "../src/CertVault.sol";
import {Certificate} from "../src/Certificate.sol";
import {BufferBook} from "../src/BufferBook.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {InsuranceStaking, IVaultRegistry} from "../src/InsuranceStaking.sol";
import {MockLighter} from "./mocks/MockLighter.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

contract FeesMockRegistry is IVaultRegistry {
    mapping(address => bool) public isVault;

    function set(address v) external {
        isVault[v] = true;
    }
}

/// @notice K2: fee accounting and the permissionless sweep.
/// @dev Two stacks. The fixture's `vault` carries VaultFixture's 100_000e6 seed, which
///      spareCollateral() holds back as bufferCapital, so its numbers show the steady state. The
///      `bare` vault below has NO seed at all: nothing but the holders' own collateral and the
///      fees is ever in it, so every payout there after a sweep is paid out of the holders' own
///      backing. That is the stack the Law 2 proofs run on, because a seed would hide a sweep
///      that took too much.
contract CertVaultFeesTest is VaultFixture {
    address internal sink = makeAddr("feeSink");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal stranger = makeAddr("stranger");

    CertVault internal bare;
    Certificate internal bareCert;
    MockLighter internal bareLighter;

    function setUp() public override {
        super.setUp();
        address[3] memory users = [alice, bob, carol];
        for (uint256 i = 0; i < 3; i++) {
            usdg.mint(users[i], 1_000_000e6);
        }
        _deployBare();
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(users[i]);
            usdg.approve(address(vault), type(uint256).max);
            usdg.approve(address(bare), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev The fixture's configuration exactly, on its own venue, bootstrapped with a plain
    ///      transfer of the dust rather than seedBuffer, so bufferCapital is 0. Its BufferBook
    ///      ledger is opened by a declared accrual instead: that moves admission control
    ///      (BufferBook.capacity18) and nothing a sweep reads as cash.
    function _deployBare() internal {
        bareLighter = new MockLighter(IERC20(address(usdg)), ASSET_IDX, 4);
        bareLighter.setMarkPrice(MARKET, PX);
        bare = new CertVault(
            CertVault.Deps({
                lighter: address(bareLighter),
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
                targetMarginBps: 9_000
            }),
            VENUE_WITHDRAW_CAP,
            SETTLE_WINDOW,
            "UseCert TSLA bare",
            "uTSLAb"
        );
        bareCert = Certificate(bare.certificate());
        vm.prank(gov);
        cap.setAbsoluteCap(address(bare), 5_000_000e18);
        vm.startPrank(attester);
        reg.attest(address(bare), 1, 0, 0, 1_190_000e18);
        bare.accrueFunding(1_000_000e18);
        vm.stopPrank();
        usdg.transfer(address(bare), 1e6);
        bare.bootstrap();
        bareLighter.settleBatch();
        assertEq(bare.bufferCapital(), 0);
        assertEq(bare.hotBuffer(), 0);
    }

    function _setSink(CertVault v) internal {
        vm.prank(gov);
        v.setFeeSink(sink);
    }

    /// @dev Everything spareCollateral() holds back, ignoring the declared-deficit term (zero in
    ///      every test that uses this).
    function _reserves(CertVault v) internal view returns (uint256) {
        return v.totalOwedOutstanding() + v.escrowOutstanding() + v.retainedBacking() + v.bufferCapital();
    }

    function _escrow(CertVault v, uint256 id) internal view returns (uint256 e) {
        (, e,,,,,) = v.mintReceipts(id);
    }

    function _owed(CertVault v, uint256 id) internal view returns (uint256) {
        (, uint256 owed18,,,) = v.redeemReceipts(id);
        return owed18 / 1e12;
    }

    // ================================================================== setFeeSink

    function test_setFeeSinkIsGovernanceOnly() public {
        vm.expectRevert(CertVault.CertVault_OnlyGovernance.selector);
        vm.prank(alice);
        vault.setFeeSink(sink);
    }

    function test_setFeeSinkIsSetOnceAndNeverZero() public {
        vm.expectRevert(CertVault.CertVault_ZeroAddress.selector);
        vm.prank(gov);
        vault.setFeeSink(address(0));

        _setSink(vault);
        assertEq(vault.feeSink(), sink);

        vm.expectRevert(CertVault.CertVault_FeeSinkAlreadySet.selector);
        vm.prank(gov);
        vault.setFeeSink(makeAddr("another"));
        assertEq(vault.feeSink(), sink);
    }

    function test_sweepRevertsWithoutASinkAndMovesNothing() public {
        vm.prank(alice);
        vault.mintInstant(1_000e6);
        uint256 hot = vault.hotBuffer();
        vm.expectRevert(CertVault.CertVault_NoFeeSink.selector);
        vault.sweepFees();
        assertEq(vault.hotBuffer(), hot);
        assertEq(vault.feesAccrued(), 1e6, "fees still accrue before a sink exists");
    }

    // ================================================================== accrual

    /// 1_000 USDG at 10 bps: fee 1, net 999, 90% of it (899.1) to the venue, 99.9 kept as float.
    function test_mintInstantAccruesItsFeeAndItsFloat() public {
        vm.prank(alice);
        vault.mintInstant(1_000e6);
        assertEq(vault.feesAccrued(), 1e6);
        assertEq(vault.retainedBacking(), 99.9e6);
        assertEq(vault.escrowOutstanding(), 0);
        // The seed (less the bootstrap dust) and the float are held back; the fee is what is left.
        assertEq(vault.bufferCapital(), 99_999e6);
        assertEq(vault.spareCollateral(), 1e6);
        assertEq(vault.sweepableFees(), 1e6);
    }

    function test_requestMintAccruesTheFeeAndEscrowsTheRestUntilSettled() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        assertEq(vault.feesAccrued(), 50e6);
        assertEq(vault.escrowOutstanding(), 49_950e6);
        assertEq(vault.retainedBacking(), 0);

        lighter.settleBatch();
        vault.settleMint(id, PX);
        assertEq(vault.escrowOutstanding(), 0, "a settled escrow is no longer owed back");
        assertEq(vault.retainedBacking(), 49_950e6 - 44_955e6, "the escrow's float became backing");
        assertEq(vault.sweepableFees(), 50e6);
    }

    function test_keeperModeRequestMintAccruesTheSame() public {
        vm.prank(gov);
        vault.enableKeeperHedging();
        vm.prank(alice);
        uint256 id = vault.requestMint(1_000e6);
        assertEq(vault.feesAccrued(), 1e6);
        assertEq(vault.escrowOutstanding(), 999e6);

        vm.prank(attester); // in keeper mode settling is the keeper's claim that the hedge filled
        vault.settleMint(id, PX);
        assertEq(vault.escrowOutstanding(), 0);
        assertEq(vault.retainedBacking(), 99.9e6);
        assertEq(vault.sweepableFees(), 1e6);
    }

    function test_redeemInstantAccruesTheFeeItDeducts() public {
        vm.prank(alice);
        vault.mintInstant(1_000e6);
        uint256 certs = cert.balanceOf(alice);
        uint256 gross18 = certs * PX / 1e18;
        uint256 fee = (gross18 * 10 / 10_000) / 1e12;

        vm.prank(alice);
        uint256 out = vault.redeemInstant(certs);
        assertEq(vault.feesAccrued(), 1e6 + fee);
        assertLe(out + fee, gross18 / 1e12);
        assertEq(vault.retainedBacking(), 0, "the last exit releases all the float");
    }

    function test_queuedExitAccruesTheFeeAtRequestAndOwesTheRest() public {
        vm.prank(alice);
        vault.mintInstant(1_000e6);
        uint256 certs = cert.balanceOf(alice);
        uint256 gross18 = certs * PX / 1e18;
        uint256 fee18 = gross18 * 10 / 10_000;

        vm.prank(alice);
        uint256 id = vault.forceExit(certs);
        assertEq(vault.feesAccrued(), 1e6 + fee18 / 1e12);
        assertEq(_owed(vault, id), (gross18 - fee18) / 1e12);
        assertEq(vault.totalOwedOutstanding(), _owed(vault, id));
    }

    // ================================================================== what a sweep may touch

    function test_sweepSendsTheFeesAndOnlyTheFees() public {
        _setSink(vault);
        vm.prank(alice);
        vault.mintInstant(1_000e6);
        uint256 hot = vault.hotBuffer();

        vm.prank(stranger); // permissionless
        uint256 sent = vault.sweepFees();
        assertEq(sent, 1e6);
        assertEq(usdg.balanceOf(sink), 1e6);
        assertEq(usdg.balanceOf(stranger), 0, "the sweep paid its caller");
        assertEq(vault.hotBuffer(), hot - 1e6);
        assertEq(vault.feesAccrued(), 0);
        assertEq(vault.hotBuffer(), _reserves(vault), "everything left is reserved");

        // Nothing more to take: a second sweep is a successful no-op.
        assertEq(vault.sweepFees(), 0);
        assertEq(usdg.balanceOf(sink), 1e6);
    }

    /// Fees exist, but the only cash in the vault is an open receipt's escrow, the float and the
    /// seed. The sweep must send nothing at all.
    function test_feesExistButSpareIsZero_sweepSendsNothing() public {
        _setSink(vault);
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        assertEq(vault.feesAccrued(), 50e6);
        assertLt(vault.hotBuffer(), _reserves(vault), "setup: the escrow is partly at the venue");
        assertEq(vault.spareCollateral(), 0);

        uint256 hot = vault.hotBuffer();
        assertEq(vault.sweepFees(), 0);
        assertEq(vault.hotBuffer(), hot);
        assertEq(usdg.balanceOf(sink), 0);
        assertEq(vault.feesAccrued(), 50e6, "an unswept fee stays accrued");

        // Settling turns the escrow into backing (float here, margin at the venue): now the fee
        // is spare and the same call sends it.
        lighter.settleBatch();
        vault.settleMint(id, PX);
        assertEq(vault.sweepFees(), 50e6);
    }

    /// Owed queued redemptions are held back in full: with a claim outstanding the sweep cannot
    /// take cash the claim needs, and after the claim is paid the fees become sweepable.
    function test_sweepNeverTouchesWhatAQueuedClaimIsOwed() public {
        _setSink(bare);
        vm.prank(alice);
        bare.mintInstant(5_000e6);
        uint256 certs = bareCert.balanceOf(alice);
        vm.prank(alice);
        uint256 id = bare.requestRedeem(certs);

        assertGt(bare.feesAccrued(), 0);
        assertEq(bare.sweepFees(), 0, "fees exist, but all the cash is owed to the claim");

        bareLighter.settleBatch();
        bare.recallMargin();
        bareLighter.settleBatch();
        uint256 owed = _owed(bare, id);
        vm.prank(stranger);
        assertEq(bare.claimRedeem(id), owed);

        uint256 fees = bare.feesAccrued();
        assertEq(bare.sweepFees(), fees, "once paid, the fees are spare");
        assertEq(bare.feesAccrued(), 0);
    }

    /// THE FLOAT TERM, falsifiably. An instant redemption is paid out of the whole balance, so it
    /// spends other holders' float and the venue owes that back as marginExcess. Until it comes
    /// home, the cash left is less than bob's float, and a sweep must send nothing even though
    /// fees are accrued. Without retainedBacking in the reserve it would send them out of bob's
    /// float.
    function test_sweepNeverSpendsAHoldersFloatWhileTheVenueOwesItBack() public {
        _setSink(bare);
        vm.prank(alice);
        bare.mintInstant(5_000e6);
        vm.prank(bob);
        bare.mintInstant(5_000e6);
        uint256 part = bareCert.balanceOf(alice) / 10;
        vm.prank(alice);
        bare.redeemInstant(part);

        assertGt(bare.feesAccrued(), 0);
        assertLt(bare.hotBuffer(), bare.retainedBacking(), "setup: the redemption spent float");
        assertEq(bare.sweepFees(), 0, "a sweep took a holder's float");

        // The venue returns the freed margin: two permissionless calls around a batch.
        bareLighter.settleBatch();
        bare.recallMargin();
        bareLighter.settleBatch();
        bare.recallMargin();
        assertEq(bare.marginExcess(), 0);
        uint256 fees = bare.feesAccrued();
        assertEq(bare.sweepableFees(), fees, "once home, the fees are spare again");
        assertEq(bare.sweepFees(), fees);
        assertGe(bare.hotBuffer(), bare.retainedBacking());
    }

    /// The seed is first-loss capital, not income: with no fee accrued, a donation-free vault's
    /// seed is never swept, and a declared loss beyond the seed holds fees back one for one.
    function test_declaredDeficitHoldsFeesBack() public {
        _setSink(vault);
        vm.prank(alice);
        vault.mintInstant(1_000e6);
        assertEq(vault.sweepableFees(), 1e6);

        // The attester relays a loss that takes the ledger 0.4 USDG below the capital.
        int256 ledger = book.balance18(address(vault));
        int256 capital18 = int256(vault.bufferCapital() * 1e12);
        vm.prank(attester);
        vault.accrueFunding(capital18 - ledger - 0.4e18);
        assertEq(vault.sweepableFees(), 0.6e6, "the deficit was not held back");

        // A loss larger than every fee: nothing moves.
        vm.prank(attester);
        vault.accrueFunding(-10e18);
        assertEq(vault.sweepFees(), 0);
    }

    function test_seedIsNeverSweptEvenWithFeesOutstanding() public {
        _setSink(vault);
        vm.prank(alice);
        vault.mintInstant(1_000e6);
        vault.sweepFees();
        // A later redemption fee is assessed; the seed and the float stay whatever happens.
        uint256 certs = cert.balanceOf(alice);
        vm.prank(alice);
        vault.redeemInstant(certs / 2);
        // The redemption itself paid out of the seed (Law 2 lets it), so the balance is now below
        // the capital and the fee just assessed has no spare cash behind it.
        assertLt(vault.hotBuffer(), vault.bufferCapital(), "setup: the redemption spent seed");
        assertGt(vault.feesAccrued(), 0);
        uint256 hot = vault.hotBuffer();
        assertEq(vault.sweepFees(), 0, "a sweep reached into the seed");
        assertEq(vault.hotBuffer(), hot);
    }

    // ================================================================== Law 2 after sweeps

    /// Every kind of payout, after sweeps, on the vault with no seed to hide behind: a queued
    /// claim, a forceExit claim, an instant redemption and an expired mint's refund are each paid
    /// in full, and no sweep in between took anything they needed.
    function test_everyPayoutSucceedsInFullAfterSweeps() public {
        _setSink(bare);
        vm.prank(alice);
        bare.mintInstant(5_000e6);
        vm.prank(bob);
        uint256 bobMint = bare.requestMint(40_000e6);
        bareLighter.settleBatch();
        bare.settleMint(bobMint, PX);

        uint256 sweptTotal = bare.sweepFees();
        assertGt(sweptTotal, 0, "setup: the settled mints' fees were spare");

        vm.prank(carol);
        uint256 carolMint = bare.requestMint(20_000e6); // will expire and be refunded
        bareLighter.settleBatch();
        assertEq(bare.sweepFees(), 0, "an open escrow left nothing spare");

        // A small instant redemption, then a sweep attempt in the gap it opens.
        uint256 aliceCerts = bareCert.balanceOf(alice);
        vm.prank(alice);
        uint256 instantOut = bare.redeemInstant(aliceCerts / 10);
        assertGt(instantOut, 0);
        sweptTotal += bare.sweepFees();

        uint256 aliceLeft = bareCert.balanceOf(alice);
        vm.prank(alice);
        uint256 forceId = bare.forceExit(aliceLeft);
        uint256 bobCerts = bareCert.balanceOf(bob);
        vm.prank(bob);
        uint256 queuedId = bare.requestRedeem(bobCerts);
        sweptTotal += bare.sweepFees();

        vm.warp(block.timestamp + SETTLE_WINDOW + 1);
        vm.prank(stranger);
        bare.stageRefund(carolMint);
        sweptTotal += bare.sweepFees();

        for (uint256 i = 0; i < 3; i++) {
            bareLighter.settleBatch();
            bare.recallMargin();
            sweptTotal += bare.sweepFees(); // a keeper sweeping at every chance
        }

        uint256 aliceBefore = usdg.balanceOf(alice);
        uint256 bobBefore = usdg.balanceOf(bob);
        uint256 carolBefore = usdg.balanceOf(carol);
        uint256 forceOwed = _owed(bare, forceId);
        uint256 queuedOwed = _owed(bare, queuedId);
        uint256 escrow = _escrow(bare, carolMint);

        assertEq(bare.claimRedeem(forceId), forceOwed);
        assertEq(bare.claimRedeem(queuedId), queuedOwed);
        assertEq(bare.refundMint(carolMint), escrow);
        assertEq(usdg.balanceOf(alice) - aliceBefore, forceOwed);
        assertEq(usdg.balanceOf(bob) - bobBefore, queuedOwed);
        assertEq(usdg.balanceOf(carol) - carolBefore, escrow);

        // Everything is closed out; what remains is fees nobody is owed.
        assertEq(bare.totalOwedOutstanding(), 0);
        assertEq(bare.escrowOutstanding(), 0);
        assertEq(bare.retainedBacking(), 0);
        assertEq(bareCert.totalSupply(), 0);
        sweptTotal += bare.sweepFees();
        assertEq(usdg.balanceOf(sink), sweptTotal);
    }

    // ================================================================== end to end

    /// mint fee -> sweepFees -> FeeVault.distribute -> InsuranceStaking's share price rises.
    function test_endToEnd_mintFeeRaisesTheStakersSharePrice() public {
        FeesMockRegistry registry = new FeesMockRegistry();
        registry.set(address(vault));
        InsuranceStaking pool = new InsuranceStaking(
            IERC20(address(usdg)), registry, gov, 10 days, 2 days, 1 days, 3_000, "UseCert Insurance", "sUSDG"
        );
        address staker = makeAddr("staker");
        usdg.mint(staker, 10_000e6);
        vm.startPrank(staker);
        usdg.approve(address(pool), type(uint256).max);
        uint256 shares = pool.deposit(10_000e6, staker);
        vm.stopPrank();
        uint256 valueBefore = pool.convertToAssets(shares);

        // A split shape only; the real split is the owner's decision (see the K2 doc).
        address[] memory r = new address[](2);
        uint256[] memory s = new uint256[](2);
        (r[0], r[1]) = (address(pool), makeAddr("treasury"));
        (s[0], s[1]) = (8_000, 2_000);
        FeeVault fv = new FeeVault(IERC20(address(usdg)), r, s);

        vm.prank(gov);
        vault.setFeeSink(address(fv));
        vm.prank(alice);
        vault.mintInstant(5_000e6); // fee: 5 USDG

        vm.startPrank(stranger);
        assertEq(vault.sweepFees(), 5e6);
        assertEq(fv.distribute(), 5e6);
        vm.stopPrank();

        assertEq(usdg.balanceOf(address(pool)), 10_000e6 + 4e6, "the pool's 80% did not arrive");
        uint256 valueAfter = pool.convertToAssets(shares);
        assertGt(valueAfter, valueBefore, "the share price did not rise");
        assertApproxEqAbs(valueAfter - valueBefore, 4e6, 2, "the staker did not get the pool's share");
    }

    // ================================================================== fuzz

    uint256[] internal _redeemIds;
    uint256[] internal _mintIds;

    /// @notice After ANY sequence of mints, redemptions, settlements, recalls and sweeps, on the
    ///         vault with no seed: (1) a sweep never turns a payable claim or refund unpayable,
    ///         and never leaves the balance below what is owed and escrowed; (2) winding
    ///         everything down pays every claim exactly what its receipt says and every refund
    ///         its whole escrow.
    /// @dev Constant price, so the H-2 cap never bites and "paid in full" is exactly owed18.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_vaultCanAlwaysPayEverythingItOwesAfterSweeps(uint256 seed) public {
        _setSink(bare);
        address[3] memory users = [alice, bob, carol];

        for (uint256 step = 0; step < 24; step++) {
            uint256 rnd = uint256(keccak256(abi.encode(seed, step)));
            address u = users[rnd % 3];
            uint256 op = (rnd >> 8) % 8;
            uint256 x = rnd >> 16;

            // Minting may be refused (capacity, Laws 2 and 3 gate minting only); the sequence
            // simply carries on without it.
            if (op == 0) {
                vm.prank(u);
                try bare.mintInstant(500e6 + x % 8_500e6) {} catch {}
            } else if (op == 1) {
                vm.prank(u);
                try bare.requestMint(11_000e6 + x % 30_000e6) returns (uint256 id) {
                    _mintIds.push(id);
                    bareLighter.settleBatch();
                    if (x % 3 != 0) bare.settleMint(id, PX); // one in three is left open
                } catch {}
            } else if (op == 2 || op == 3) {
                uint256 bal = bareCert.balanceOf(u);
                if (bal == 0) continue;
                uint256 amt = bal / (1 + x % 4);
                if (amt == 0) amt = bal;
                if (op == 2) {
                    vm.prank(u);
                    try bare.redeemInstant(amt) {} catch {
                        vm.prank(u);
                        _redeemIds.push(bare.requestRedeem(amt));
                    }
                } else {
                    vm.prank(u);
                    _redeemIds.push(bare.forceExit(amt));
                }
            } else if (op == 4 || op == 5) {
                _checkedSweep();
            } else if (op == 6) {
                bareLighter.settleBatch();
                bare.recallMargin();
            } else {
                // A claim attempt mid-sequence: it may be early, and that is a retryable "not yet".
                if (_redeemIds.length == 0) continue;
                uint256 id = _redeemIds[x % _redeemIds.length];
                (,,,, bool paid) = bare.redeemReceipts(id);
                if (!paid) try bare.claimRedeem(id) {} catch {}
            }
        }

        // ---- Wind everything down.
        for (uint256 i = 0; i < 3; i++) {
            uint256 bal = bareCert.balanceOf(users[i]);
            if (bal == 0) continue;
            vm.prank(users[i]);
            _redeemIds.push(bare.forceExit(bal));
        }
        vm.warp(block.timestamp + SETTLE_WINDOW + 1);
        for (uint256 i = 0; i < _mintIds.length; i++) {
            (,, bool settled,,, bool staged,) = bare.mintReceipts(_mintIds[i]);
            if (!settled && !staged) bare.stageRefund(_mintIds[i]);
        }
        _checkedSweep();
        for (uint256 i = 0; i < 4; i++) {
            bareLighter.settleBatch();
            bare.recallMargin();
            _checkedSweep();
        }

        for (uint256 i = 0; i < _redeemIds.length; i++) {
            (address user,,,, bool paid) = bare.redeemReceipts(_redeemIds[i]);
            if (paid) continue;
            uint256 owed = _owed(bare, _redeemIds[i]);
            uint256 before = usdg.balanceOf(user);
            assertEq(bare.claimRedeem(_redeemIds[i]), owed, "a claim was not paid in full");
            assertEq(usdg.balanceOf(user) - before, owed);
        }
        for (uint256 i = 0; i < _mintIds.length; i++) {
            (, uint256 escrow, bool settled,,,,) = bare.mintReceipts(_mintIds[i]);
            if (settled) continue;
            assertEq(bare.refundMint(_mintIds[i]), escrow, "a refund was not paid in full");
        }
        assertEq(bare.totalOwedOutstanding(), 0);
        assertEq(bare.escrowOutstanding(), 0);
        assertEq(bare.retainedBacking(), 0);
        assertEq(bareCert.totalSupply(), 0);
    }

    /// @dev Sweep, and prove on the spot that it took nothing anyone was owed: every unpaid claim
    ///      and every staged refund the balance could pay before, it can still pay after, and a
    ///      sweep that moved anything left at least everything owed and escrowed behind.
    function _checkedSweep() internal {
        uint256 hotBefore = bare.hotBuffer();
        uint256 sent = bare.sweepFees();
        uint256 hotAfter = bare.hotBuffer();
        assertEq(hotBefore - hotAfter, sent);
        if (sent == 0) return;
        assertGe(hotAfter, _reserves(bare), "a sweep went below the reserves");
        for (uint256 i = 0; i < _redeemIds.length; i++) {
            (,,,, bool paid) = bare.redeemReceipts(_redeemIds[i]);
            if (paid) continue;
            uint256 owed = _owed(bare, _redeemIds[i]);
            if (hotBefore >= owed) assertGe(hotAfter, owed, "a sweep made a payable claim unpayable");
        }
        for (uint256 i = 0; i < _mintIds.length; i++) {
            (, uint256 escrow, bool settled,,,,) = bare.mintReceipts(_mintIds[i]);
            if (settled) continue;
            if (hotBefore >= escrow) assertGe(hotAfter, escrow, "a sweep made a payable refund unpayable");
        }
    }
}
