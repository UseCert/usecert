// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CertOracle} from "../src/CertOracle.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

/// @notice The signed mark-price path — the companion to SolvencyRegistry.attestSigned.
/// @dev The property is the same one: moving who SENDS the transaction must not move what the
///      update is allowed to SAY, or who is allowed to say it.
/// @dev H-6 / L-12: the signed payload is SetMark(px18, nonce, observedAt, deadline) under domain
///      version "2", and the mark now ages from `observedAt`.
contract CertOracleSignedTest is Test {
    CertOracle oracle;
    MockAggregatorV3 feed;

    uint256 attesterPk = 0xA11CE;
    address attester;
    address relayer = makeAddr("relayer");

    uint256 constant PX = 300e18;
    uint256 constant STALENESS = 3600;
    uint256 constant DEVIATION_BPS = 500;
    uint256 constant POKE_WINDOW = 900;
    uint256 constant MARK_AGE = 300;

    function setUp() public {
        vm.warp(1_800_000_000);
        attester = vm.addr(attesterPk);
        feed = new MockAggregatorV3(8, int256(PX / 1e10)); // 8 decimals, priced at PX
        oracle =
            new CertOracle(address(feed), attester, 2, STALENESS, DEVIATION_BPS, 100, POKE_WINDOW, false, MARK_AGE);
    }

    function _sign(uint256 pk, uint256 px18, uint64 nonce, uint64 observedAt, uint64 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _signOn(oracle, pk, px18, nonce, observedAt, deadline);
    }

    function _signOn(CertOracle o, uint256 pk, uint256 px18, uint64 nonce, uint64 observedAt, uint64 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(o.SET_MARK_TYPEHASH(), px18, nonce, observedAt, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", o.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Signs "now" with the longest deadline the contract accepts, and relays it.
    function _relay(uint256 px18, uint64 nonce) internal {
        uint64 obs = uint64(block.timestamp);
        uint64 deadline = obs + 60;
        bytes memory sig = _sign(attesterPk, px18, nonce, obs, deadline);
        vm.prank(relayer);
        oracle.setMarkPriceSigned(px18, nonce, obs, deadline, sig);
    }

    /// @dev Keeps the feed fresh across a warp so only the mark's own age is under test.
    function _warpKeepingFeedFresh(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        feed.set(int256(PX / 1e10), block.timestamp);
    }

    // ------------------------------------------------------------------ the fixed signed format

    /// @notice Pins the exact format the off-chain signer is implemented against.
    function test_signedFormatIsPinned() public view {
        assertEq(
            oracle.SET_MARK_TYPEHASH(),
            keccak256("SetMark(uint256 px18,uint64 nonce,uint64 observedAt,uint64 deadline)"),
            "typehash"
        );
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("UseCert CertOracle"),
                keccak256("2"),
                block.chainid,
                address(oracle)
            )
        );
        assertEq(oracle.domainSeparator(), expected, "domain must be version 2");
        assertEq(oracle.MARK_SIGNATURE_VALIDITY(), 60);
        assertEq(oracle.maxMarkAge(), MARK_AGE);
    }

    /// @dev A v1 signature (old type, old domain version) must not verify on a v2 oracle.
    function test_aVersionOneSignatureIsRejected() public {
        uint64 deadline = uint64(block.timestamp + 60);
        bytes32 v1Domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("UseCert CertOracle"),
                keccak256("1"),
                block.chainid,
                address(oracle)
            )
        );
        bytes32 structHash =
            keccak256(abi.encode(keccak256("SetMark(uint256 px18,uint64 nonce,uint64 deadline)"), PX, 1, deadline));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(attesterPk, keccak256(abi.encodePacked("\x19\x01", v1Domain, structHash)));

        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_BadSignature.selector);
        oracle.setMarkPriceSigned(PX, 1, uint64(block.timestamp), deadline, abi.encodePacked(r, s, v));
    }

    // ------------------------------------------------------------------ happy path

    function test_relayerMaySubmitAndTheAttesterSpendsNothing() public {
        uint64 obs = uint64(block.timestamp);
        uint64 deadline = obs + 60;
        bytes memory sig = _sign(attesterPk, PX, 1, obs, deadline);

        uint256 attesterBalanceBefore = attester.balance;
        vm.prank(relayer);
        oracle.setMarkPriceSigned(PX, 1, obs, deadline, sig);

        assertEq(oracle.markPx18(), PX, "mark must be written by the relayed signature");
        assertEq(oracle.markNonce(), 1);
        assertEq(oracle.markAt(), obs);
        assertEq(attester.balance, attesterBalanceBefore, "the attester must not fund the write");
    }

    /// @dev H-6: the SIGNED observation time is stored, not the relay time, so holding a signature
    ///      does not make its mark look younger.
    function test_H6_markAtIsTheSignedObservationNotTheRelayTime() public {
        uint64 obs = uint64(block.timestamp);
        uint64 deadline = obs + 60;
        bytes memory sig = _sign(attesterPk, PX, 1, obs, deadline);

        vm.warp(block.timestamp + 45);
        vm.prank(relayer);
        oracle.setMarkPriceSigned(PX, 1, obs, deadline, sig);
        assertEq(oracle.markAt(), obs, "PROPERTY: markAt is observedAt, not block.timestamp");
    }

    // ------------------------------------------------------------------ replay

    function test_sameNonceCannotBeReplayed() public {
        uint64 obs = uint64(block.timestamp);
        uint64 deadline = obs + 60;
        bytes memory sig = _sign(attesterPk, PX, 1, obs, deadline);
        vm.prank(relayer);
        oracle.setMarkPriceSigned(PX, 1, obs, deadline, sig);

        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_StaleNonce.selector);
        oracle.setMarkPriceSigned(PX, 1, obs, deadline, sig);
    }

    /// @dev The nonce must strictly increase, so an OLDER signature cannot be resurrected after a
    ///      newer one has landed — which is the move that would let a relayer pick which of several
    ///      genuine marks is current.
    function test_anEarlierSignatureCannotBeResurrected() public {
        uint64 obs = uint64(block.timestamp);
        uint64 deadline = obs + 60;
        bytes memory first = _sign(attesterPk, PX, 1, obs, deadline);
        bytes memory second = _sign(attesterPk, PX + 5e18, 2, obs, deadline);

        vm.prank(relayer);
        oracle.setMarkPriceSigned(PX + 5e18, 2, obs, deadline, second);

        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_StaleNonce.selector);
        oracle.setMarkPriceSigned(PX, 1, obs, deadline, first);
        assertEq(oracle.markPx18(), PX + 5e18, "the newer mark must stand");
    }

    /// @notice H-6: a mark OBSERVED earlier than the one held is refused even under a higher nonce.
    /// @dev Nonces order signatures, observedAt orders observations; a signer issuing concurrently
    ///      could produce a higher nonce over an older reading, and relaying it must not wind the
    ///      mark's age back.
    function test_H6_aMarkObservedBeforeTheHeldOneIsRejected() public {
        uint64 older = uint64(block.timestamp);
        bytes memory oldSig = _sign(attesterPk, PX, 2, older, older + 60);
        vm.warp(block.timestamp + 10);
        uint64 newer = uint64(block.timestamp);
        bytes memory newSig = _sign(attesterPk, PX + 1e18, 1, newer, newer + 60);

        vm.prank(relayer);
        oracle.setMarkPriceSigned(PX + 1e18, 1, newer, newer + 60, newSig);

        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_ObservationWentBackwards.selector);
        oracle.setMarkPriceSigned(PX, 2, older, older + 60, oldSig);
        assertEq(oracle.markAt(), newer, "the newer observation must stand");
        assertEq(oracle.markPx18(), PX + 1e18);
    }

    /// @dev Equal observation times are allowed: both readings are from the same second, and the
    ///      nonce orders them.
    function test_H6_anEqualObservationTimeIsAccepted() public {
        _relay(PX, 1);
        _relay(PX + 1e18, 2);
        assertEq(oracle.markPx18(), PX + 1e18);
    }

    // ------------------------------------------------------------------ signature

    function test_wrongSignerIsRejected() public {
        uint64 obs = uint64(block.timestamp);
        bytes memory sig = _sign(0xBAD, PX, 1, obs, obs + 60);

        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_BadSignature.selector);
        oracle.setMarkPriceSigned(PX, 1, obs, obs + 60, sig);
    }

    /// @dev If the price could be changed without invalidating the signature, the relayer would be
    ///      choosing the mark and the attester's signature would mean nothing.
    function test_alteredPriceInvalidatesTheSignature() public {
        uint64 obs = uint64(block.timestamp);
        bytes memory sig = _sign(attesterPk, PX, 1, obs, obs + 60);

        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_BadSignature.selector);
        oracle.setMarkPriceSigned(PX * 2, 1, obs, obs + 60, sig);
    }

    /// @dev H-6: observedAt is signed, so a relayer cannot make an old signature look younger.
    function test_H6_alteredObservationTimeInvalidatesTheSignature() public {
        uint64 obs = uint64(block.timestamp);
        bytes memory sig = _sign(attesterPk, PX, 1, obs, obs + 60);
        vm.warp(block.timestamp + 30);

        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_BadSignature.selector);
        oracle.setMarkPriceSigned(PX, 1, obs + 30, obs + 60, sig);
    }

    function test_expiredSignatureIsRejected() public {
        uint64 obs = uint64(block.timestamp);
        uint64 deadline = obs + 60;
        bytes memory sig = _sign(attesterPk, PX, 1, obs, deadline);
        vm.warp(uint256(deadline) + 1);

        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_SignatureExpired.selector);
        oracle.setMarkPriceSigned(PX, 1, obs, deadline, sig);
    }

    /// @notice F7: a deadline more than 60 s after observedAt is refused on chain, however validly
    ///         signed. Exactly 60 s is accepted.
    function test_F7_aDeadlineBeyondObservedAtPlusSixtyIsRejected() public {
        uint64 obs = uint64(block.timestamp);
        uint64 tooLong = obs + 61;
        bytes memory sig = _sign(attesterPk, PX, 1, obs, tooLong);

        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_SignatureExpired.selector);
        oracle.setMarkPriceSigned(PX, 1, obs, tooLong, sig);

        // A day-long credential is refused just the same, even relayed in its first second.
        bytes memory daySig = _sign(attesterPk, PX, 1, obs, obs + 1 days);
        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_SignatureExpired.selector);
        oracle.setMarkPriceSigned(PX, 1, obs, obs + 1 days, daySig);

        bytes memory okSig = _sign(attesterPk, PX, 1, obs, obs + 60);
        vm.prank(relayer);
        oracle.setMarkPriceSigned(PX, 1, obs, obs + 60, okSig);
        assertEq(oracle.markNonce(), 1, "exactly observedAt + 60 is accepted");
    }

    function test_H6_aFutureObservationIsRejected() public {
        uint64 obs = uint64(block.timestamp + 1);
        bytes memory sig = _sign(attesterPk, PX, 1, obs, obs + 60);

        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_ObservationInFuture.selector);
        oracle.setMarkPriceSigned(PX, 1, obs, obs + 60, sig);
    }

    function test_signatureCannotBeMovedToAnotherOracle() public {
        uint64 obs = uint64(block.timestamp);
        bytes memory sig = _sign(attesterPk, PX, 1, obs, obs + 60);

        CertOracle twin =
            new CertOracle(address(feed), attester, 2, STALENESS, DEVIATION_BPS, 100, POKE_WINDOW, false, MARK_AGE);
        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_BadSignature.selector);
        twin.setMarkPriceSigned(PX, 1, obs, obs + 60, sig);
    }

    // ------------------------------------------------------------------ the structural guards

    /// @notice A mark relayed inside its deadline but off the live feed cannot open minting: the
    ///         basis band measures it against the LIVE feed.
    /// @dev Still true after H-6; the band and the age bound are complementary. The band catches
    ///      a mark that disagrees with a moving index, the age bound catches a mark that agrees
    ///      with a frozen one.
    function test_aMarkThatDriftedFromTheFeedClosesMintingByItself() public {
        // 10% away from the feed, against a 100bps band.
        uint256 drifted = PX * 110 / 100;
        _relay(drifted, 1);

        assertEq(oracle.markPx18(), drifted, "the write itself is permitted");
        assertFalse(oracle.mintAllowed(), "PROPERTY: a mark off the feed must close minting");
    }

    function test_aMarkOnTheFeedLeavesMintingOpen() public {
        _relay(PX, 1);
        assertTrue(oracle.mintAllowed(), "an honest mark must leave minting open");
    }

    /// @notice H-6 / L-12: an in-band mark older than maxMarkAge closes minting, with the feed
    ///         fresh throughout. The boundary is inclusive. Redemption's price is unaffected.
    function test_H6_aStaleMarkClosesMinting() public {
        _relay(PX, 1);
        assertTrue(oracle.mintAllowed());

        _warpKeepingFeedFresh(MARK_AGE);
        assertTrue(oracle.mintAllowed(), "exactly maxMarkAge old is still open");

        _warpKeepingFeedFresh(1);
        assertFalse(oracle.mintAllowed(), "PROPERTY: a mark older than maxMarkAge must close minting");

        (uint256 p, uint256 t) = oracle.pxUnguarded();
        assertEq(p, PX, "Law 2: redemption's price does not depend on the mark");
        assertEq(t, block.timestamp);
        assertEq(oracle.px(), PX, "px() does not read the mark");

        // A fresh signature reopens it.
        _relay(PX, 2);
        assertTrue(oracle.mintAllowed(), "a fresh mark reopens minting");
    }

    /// @dev The direct path ages from its own block, the same bound.
    function test_H6_aDirectMarkAgesToo() public {
        vm.prank(attester);
        oracle.setMarkPrice(PX);
        assertEq(oracle.markAt(), block.timestamp);
        _warpKeepingFeedFresh(MARK_AGE + 1);
        assertFalse(oracle.mintAllowed(), "a direct mark ages out like a signed one");
    }

    /// @dev The seed-mark case from the finding: a relayer holding a signature for the whole
    ///      validity window gains at most 60 s on top of maxMarkAge, never more.
    function test_H6_aHeldSignatureCannotExtendTheMarksLife() public {
        uint64 obs = uint64(block.timestamp);
        bytes memory sig = _sign(attesterPk, PX, 1, obs, obs + 60);
        _warpKeepingFeedFresh(60);
        vm.prank(relayer);
        oracle.setMarkPriceSigned(PX, 1, obs, obs + 60, sig);
        _warpKeepingFeedFresh(MARK_AGE - 60 + 1);
        assertFalse(oracle.mintAllowed(), "the age counts from observation, not relay");
    }

    /// @dev Single-source mode does not read the mark, so it does not age it either (an age gate
    ///      there would be a pause-by-silence for the attester).
    function test_H6_singleSourceDoesNotAgeTheMark() public {
        MockAggregatorV3 f = new MockAggregatorV3(8, int256(PX / 1e10));
        CertOracle ss = new CertOracle(address(f), attester, 2, STALENESS, 200, 100, POKE_WINDOW, true, MARK_AGE);
        vm.warp(block.timestamp + 2 * MARK_AGE);
        f.set(int256(PX / 1e10), block.timestamp);
        assertTrue(ss.mintAllowed(), "no mark, no age gate in single-source mode");
    }

    function test_H6_maxMarkAgeIsBoundedAtConstruction() public {
        vm.expectRevert(CertOracle.CertOracle_ConfigOutOfBounds.selector);
        new CertOracle(address(feed), attester, 2, STALENESS, DEVIATION_BPS, 100, POKE_WINDOW, false, 29);
        vm.expectRevert(CertOracle.CertOracle_ConfigOutOfBounds.selector);
        new CertOracle(address(feed), attester, 2, STALENESS, DEVIATION_BPS, 100, POKE_WINDOW, false, 3601);
        vm.expectRevert(CertOracle.CertOracle_ConfigOutOfBounds.selector);
        new CertOracle(address(feed), attester, 2, STALENESS, DEVIATION_BPS, 100, POKE_WINDOW, false, 0);

        CertOracle lo = new CertOracle(address(feed), attester, 2, STALENESS, DEVIATION_BPS, 100, POKE_WINDOW, false, 30);
        CertOracle hi =
            new CertOracle(address(feed), attester, 2, STALENESS, DEVIATION_BPS, 100, POKE_WINDOW, false, 3600);
        assertEq(lo.maxMarkAge(), 30);
        assertEq(hi.maxMarkAge(), 3600);
    }

    // ------------------------------------------------------------------ coexistence

    function test_directSetMarkPriceStillWorks() public {
        vm.prank(attester);
        oracle.setMarkPrice(PX);
        assertEq(oracle.markPx18(), PX);
        assertEq(oracle.markNonce(), 0, "the direct path must not consume a nonce");
    }

    /// @dev And the two paths must not fight: a direct write leaves the nonce alone, so a signature
    ///      prepared before it is still usable afterwards, as long as it was observed in the same
    ///      second or later (the direct write records block time).
    function test_aSignaturePreparedBeforeADirectWriteStillApplies() public {
        uint64 obs = uint64(block.timestamp);
        bytes memory sig = _sign(attesterPk, PX, 1, obs, obs + 60);

        vm.prank(attester);
        oracle.setMarkPrice(PX * 99 / 100);

        vm.prank(relayer);
        oracle.setMarkPriceSigned(PX, 1, obs, obs + 60, sig);
        assertEq(oracle.markPx18(), PX);
    }

    // ------------------------------------------------------------------ H-4 kill switch

    function test_H4_disableAttesterIsGovernanceOnly() public {
        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_OnlyGovernance.selector);
        oracle.disableAttester();

        vm.prank(attester);
        vm.expectRevert(CertOracle.CertOracle_OnlyGovernance.selector);
        oracle.disableAttester();
    }

    /// @notice Disabling blocks both mark paths in the same block, and leaves every redemption-
    ///         relevant view answering.
    function test_H4_disableBlocksBothMarkPathsImmediately() public {
        _relay(PX, 1);
        uint64 obs = uint64(block.timestamp);
        bytes memory pending = _sign(attesterPk, PX, 2, obs, obs + 60);

        oracle.disableAttester(); // this test contract deployed the oracle, so it is governance
        assertEq(oracle.attester(), address(0), "attester() reads zero while disabled");

        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_AttesterDisabled.selector);
        oracle.setMarkPriceSigned(PX, 2, obs, obs + 60, pending);

        vm.prank(attester);
        vm.expectRevert(CertOracle.CertOracle_AttesterDisabled.selector);
        oracle.setMarkPrice(PX);

        // Redemption-relevant views are untouched.
        (uint256 p,) = oracle.pxUnguarded();
        assertEq(p, PX, "Law 2: pxUnguarded answers");
        assertEq(oracle.px(), PX);
        assertGt(oracle.toTickPrice(PX), 0);
        oracle.pokeLastGood();

        // The held mark ages out, so minting closes on its own.
        _warpKeepingFeedFresh(MARK_AGE + 1);
        assertFalse(oracle.mintAllowed());
        (p,) = oracle.pxUnguarded();
        assertEq(p, PX, "Law 2: still answering after the mark aged out");
    }

    /// @notice Re-enabling is possible only through the full 2-day rotation.
    function test_H4_reEnableOnlyViaRotation() public {
        oracle.disableAttester();

        // Nothing pending, so there is nothing to accept.
        vm.expectRevert(CertOracle.CertOracle_NoPendingAttester.selector);
        oracle.acceptAttester();

        uint256 nextPk = 0xB0B;
        address next = vm.addr(nextPk);
        oracle.proposeAttester(next);

        vm.warp(block.timestamp + oracle.ATTESTER_ROTATION_DELAY() - 1);
        vm.expectRevert(CertOracle.CertOracle_RotationNotDue.selector);
        oracle.acceptAttester();

        vm.warp(block.timestamp + 1);
        feed.set(int256(PX / 1e10), block.timestamp);
        oracle.acceptAttester();
        assertEq(oracle.attester(), next);

        // The new key works; the disabled one does not.
        uint64 obs = uint64(block.timestamp);
        bytes memory oldKey = _sign(attesterPk, PX, 1, obs, obs + 60);
        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_BadSignature.selector);
        oracle.setMarkPriceSigned(PX, 1, obs, obs + 60, oldKey);

        bytes memory newKey = _sign(nextPk, PX, 1, obs, obs + 60);
        vm.prank(relayer);
        oracle.setMarkPriceSigned(PX, 1, obs, obs + 60, newKey);
        assertTrue(oracle.mintAllowed());
    }

    /// @dev Proposing the incumbent is how a rotation is abandoned. A disable must clear such a
    ///      proposal, or it would reinstall the disabled key when it came due.
    function test_H4_disableClearsAPendingReinstallOfTheSameKey() public {
        oracle.proposeAttester(attester);
        oracle.disableAttester();
        assertEq(oracle.pendingAttester(), address(0));

        vm.warp(block.timestamp + oracle.ATTESTER_ROTATION_DELAY());
        vm.expectRevert(CertOracle.CertOracle_NoPendingAttester.selector);
        oracle.acceptAttester();
        assertEq(oracle.attester(), address(0), "the disabled key stays out");
    }

    /// @dev A rotation to a DIFFERENT key already serving its notice is the recovery in progress,
    ///      and is kept.
    function test_H4_disableKeepsAPendingRotationToANewKey() public {
        address next = makeAddr("next");
        oracle.proposeAttester(next);
        uint256 due = oracle.pendingAttesterAt();
        oracle.disableAttester();
        assertEq(oracle.pendingAttester(), next);
        assertEq(oracle.pendingAttesterAt(), due, "the notice period is not restarted");

        vm.warp(due);
        oracle.acceptAttester();
        assertEq(oracle.attester(), next);
    }

    function test_H4_governanceCannotInstallZeroOrBypassTheDelay() public {
        vm.expectRevert(CertOracle.CertOracle_ZeroAddress.selector);
        oracle.proposeAttester(address(0));
        oracle.disableAttester();
        oracle.disableAttester(); // idempotent
        assertEq(oracle.attester(), address(0));
    }
}
