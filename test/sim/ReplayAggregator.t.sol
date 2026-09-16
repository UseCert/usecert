// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReplayAggregator} from "../../src/sim/ReplayAggregator.sol";
import {CertOracle} from "../../src/CertOracle.sol";

contract ReplayAggregatorTest is Test {
    ReplayAggregator agg;
    address owner = makeAddr("owner");
    address stranger = makeAddr("stranger");
    address attester = makeAddr("attester");

    // The live TSLA read this contract's shape is sized against: decimals() = 8,
    // description() = "RHTSLA / USD", version() = 6, answer = 36_662_040_000 (= $366.6204).
    int256 constant INITIAL_ANSWER = 36_662_040_000;
    uint256 constant INITIAL_PX18 = 366.6204e18;

    function setUp() public {
        vm.warp(1_800_000_000);
        agg = new ReplayAggregator(owner, 8, "RHTSLA / USD", INITIAL_ANSWER);
    }

    // ---------------------------------------------------------------------
    // Chainlink-shaped surface
    // ---------------------------------------------------------------------

    function test_matchesRealFeedShape() public view {
        assertEq(agg.decimals(), 8);
        assertEq(agg.description(), "RHTSLA / USD");
        assertEq(agg.version(), 6);
        (, int256 answer,,,) = agg.latestRoundData();
        assertEq(answer, INITIAL_ANSWER);
    }

    function test_constructorWritesRoundOne() public view {
        (uint80 roundId,, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = agg.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answeredInRound, 1);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
    }

    // ---------------------------------------------------------------------
    // Required: roundId strictly increments on every write (Task 1 depends on this)
    // ---------------------------------------------------------------------

    function test_roundIdIncrementsOnEveryPush() public {
        (uint80 r0,,,,) = agg.latestRoundData();

        // Same price, still a new round.
        vm.prank(owner);
        agg.push(INITIAL_ANSWER);
        (uint80 r1,,,,) = agg.latestRoundData();
        assertEq(r1, r0 + 1, "unchanged-price push must still advance roundId");

        // Different price.
        vm.prank(owner);
        agg.push(INITIAL_ANSWER + 1);
        (uint80 r2,,,,) = agg.latestRoundData();
        assertEq(r2, r1 + 1);

        // pushRounds: one round per element.
        int256[] memory a = new int256[](3);
        uint256[] memory t = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            a[i] = INITIAL_ANSWER;
            t[i] = block.timestamp + i + 1;
        }
        vm.prank(owner);
        agg.pushRounds(a, t);
        (uint80 r3,,,,) = agg.latestRoundData();
        assertEq(r3, r2 + 3);

        // pushFrozen: no price change at all, roundId still moves.
        vm.prank(owner);
        agg.pushFrozen();
        (uint80 r4,,,,) = agg.latestRoundData();
        assertEq(r4, r3 + 1);

        // pushFrozenAt: same.
        vm.prank(owner);
        agg.pushFrozenAt(block.timestamp + 100);
        (uint80 r5,,,,) = agg.latestRoundData();
        assertEq(r5, r4 + 1);
    }

    // ---------------------------------------------------------------------
    // Owner gating — every write
    // ---------------------------------------------------------------------

    function test_onlyOwnerCanPush() public {
        vm.prank(stranger);
        vm.expectRevert(ReplayAggregator.ReplayAggregator_OnlyOwner.selector);
        agg.push(1);
    }

    function test_onlyOwnerCanPushRounds() public {
        int256[] memory a = new int256[](1);
        uint256[] memory t = new uint256[](1);
        a[0] = 1;
        t[0] = block.timestamp;
        vm.prank(stranger);
        vm.expectRevert(ReplayAggregator.ReplayAggregator_OnlyOwner.selector);
        agg.pushRounds(a, t);
    }

    function test_onlyOwnerCanPushFrozen() public {
        vm.prank(stranger);
        vm.expectRevert(ReplayAggregator.ReplayAggregator_OnlyOwner.selector);
        agg.pushFrozen();

        vm.prank(stranger);
        vm.expectRevert(ReplayAggregator.ReplayAggregator_OnlyOwner.selector);
        agg.pushFrozenAt(block.timestamp);
    }

    function test_onlyOwnerCanSetDecimalsOrDescription() public {
        vm.prank(stranger);
        vm.expectRevert(ReplayAggregator.ReplayAggregator_OnlyOwner.selector);
        agg.setDecimals(18);

        vm.prank(stranger);
        vm.expectRevert(ReplayAggregator.ReplayAggregator_OnlyOwner.selector);
        agg.setDescription("evil");
    }

    function test_zeroOwnerReverts() public {
        vm.expectRevert(ReplayAggregator.ReplayAggregator_ZeroOwner.selector);
        new ReplayAggregator(address(0), 8, "x", 1);
    }

    function test_pushRoundsEmptyReverts() public {
        int256[] memory a = new int256[](0);
        uint256[] memory t = new uint256[](0);
        vm.prank(owner);
        vm.expectRevert(ReplayAggregator.ReplayAggregator_EmptyBatch.selector);
        agg.pushRounds(a, t);
    }

    function test_pushRoundsLengthMismatchReverts() public {
        int256[] memory a = new int256[](2);
        uint256[] memory t = new uint256[](1);
        vm.prank(owner);
        vm.expectRevert(ReplayAggregator.ReplayAggregator_LengthMismatch.selector);
        agg.pushRounds(a, t);
    }

    // ---------------------------------------------------------------------
    // Required: reproduce the pathological states CertOracle's guards exist for
    // ---------------------------------------------------------------------

    function test_frozenPriceWithAdvancingTimeIsDetectable() public {
        (, int256 beforeAnswer,, uint256 beforeUpdatedAt,) = agg.latestRoundData();

        vm.warp(block.timestamp + 2 hours);
        vm.prank(owner);
        agg.pushFrozen();

        (uint80 roundId, int256 answer,, uint256 updatedAt,) = agg.latestRoundData();
        assertEq(answer, beforeAnswer, "frozen push must not change the answer");
        assertGt(updatedAt, beforeUpdatedAt, "frozen push must still advance updatedAt");
        assertGt(roundId, 1, "frozen push must still advance roundId");

        // Distinct from staleness: this feed has just reported (updatedAt == block.timestamp),
        // it simply reported the same number it always does.
        assertEq(updatedAt, block.timestamp);
    }

    function test_stalenessAndFutureTimestampStatesReproducible() public {
        CertOracle oracle = new CertOracle(address(agg), attester, 2, 3600, 500, 100, 3600, false);

        // Staleness: no new round for longer than stalenessSeconds.
        vm.warp(block.timestamp + 3601);
        assertFalse(oracle.mintAllowed());
        vm.expectRevert(CertOracle.CertOracle_StalePrice.selector);
        oracle.px();

        // Future updatedAt: a round timestamped ahead of block.timestamp.
        int256[] memory a = new int256[](1);
        uint256[] memory t = new uint256[](1);
        a[0] = INITIAL_ANSWER;
        t[0] = block.timestamp + 1 days;
        vm.prank(owner);
        agg.pushRounds(a, t);

        assertFalse(oracle.mintAllowed());
        vm.expectRevert(CertOracle.CertOracle_StalePrice.selector);
        oracle.px();
    }

    function test_nonPositiveAnswerReproducible() public {
        CertOracle oracle = new CertOracle(address(agg), attester, 2, 3600, 500, 100, 3600, false);

        vm.prank(owner);
        agg.push(0);
        assertFalse(oracle.mintAllowed());
        vm.expectRevert(CertOracle.CertOracle_NonPositivePrice.selector);
        oracle.px();

        vm.prank(owner);
        agg.push(-1);
        (, int256 answer,,,) = agg.latestRoundData();
        assertEq(answer, -1);
        assertFalse(oracle.mintAllowed());
        vm.expectRevert(CertOracle.CertOracle_NonPositivePrice.selector);
        oracle.px();
    }

    function test_absurdDecimalsMakesFeedUnusableForGuards() public {
        CertOracle oracle = new CertOracle(address(agg), attester, 2, 3600, 500, 100, 3600, false);
        vm.prank(attester);
        oracle.setMarkPrice(INITIAL_PX18);
        assertTrue(oracle.mintAllowed());

        // CertOracle._tryFeed bounds usable decimals at 36; above that the feed becomes
        // unusable for every guard, though px()/_readFeed (which has no such bound) can still
        // revert with an arithmetic panic rather than a named error — that asymmetry is
        // CertOracle's, not this aggregator's; our job is only to make the state reproducible.
        vm.prank(owner);
        agg.setDecimals(200);
        assertEq(agg.decimals(), 200);
        assertFalse(oracle.mintAllowed());
    }

    // ---------------------------------------------------------------------
    // Required: replay a recorded series and watch mintAllowed() transition
    // ---------------------------------------------------------------------

    function test_replaySeriesDrivesOracleGuards() public {
        CertOracle oracle = new CertOracle(address(agg), attester, 2, 3600, 500, 100, 3600, false);

        vm.prank(attester);
        oracle.setMarkPrice(INITIAL_PX18);
        assertTrue(oracle.mintAllowed(), "healthy at construction");

        // Round 2: a small in-band move (+0.5%), mark kept in step. Both guards stay satisfied.
        vm.prank(owner);
        agg.push(36_845_000_000); // $368.45
        vm.warp(block.timestamp + 60);
        vm.prank(attester);
        oracle.setMarkPrice(368.45e18);
        assertTrue(oracle.mintAllowed(), "small in-band move keeps minting open");

        // Round 3: a >5% jump from the deviation breaker's reference. lastGoodPx18 has never
        // been poked, so it is still the construction-time price (~366.6204). The mark is kept
        // exactly on the new index price, so the basis band is satisfied — this isolates the
        // deviation breaker as the guard that trips.
        vm.prank(owner);
        agg.push(40_000_000_000); // $400.00, ~9.1% away from ~366.6204
        vm.warp(block.timestamp + 60);
        vm.prank(attester);
        oracle.setMarkPrice(400e18);
        assertFalse(oracle.mintAllowed(), "deviation breaker trips on the jump");
    }

    // ---------------------------------------------------------------------
    // pushRounds as a genuine replay: several rounds in one call, in order
    // ---------------------------------------------------------------------

    function test_pushRoundsAppliesEachElementAsItsOwnRound() public {
        int256[] memory a = new int256[](3);
        uint256[] memory t = new uint256[](3);
        a[0] = 36_700_000_000;
        t[0] = block.timestamp + 10;
        a[1] = 36_750_000_000;
        t[1] = block.timestamp + 20;
        a[2] = 36_800_000_000;
        t[2] = block.timestamp + 30;

        vm.prank(owner);
        agg.pushRounds(a, t);

        (uint80 roundId, int256 answer,, uint256 updatedAt,) = agg.latestRoundData();
        assertEq(roundId, 4); // round 1 from the constructor + 3 replayed rounds
        assertEq(answer, a[2]);
        assertEq(updatedAt, t[2]);
    }
}
