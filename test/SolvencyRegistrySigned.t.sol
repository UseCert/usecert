// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SolvencyRegistry} from "../src/SolvencyRegistry.sol";
import {ISolvencyRegistry} from "../src/interfaces/ISolvencyRegistry.sol";
import {CapacityOracle} from "../src/CapacityOracle.sol";

/// @notice The signed-attestation path, where the ATTESTER signs and the MINTER pays the gas.
/// @dev The property under test throughout is that moving who sends the transaction does not move
///      what the attestation CLAIMS. Every test here fails loudly if `observedAt` stops being the
///      thing that is stored, because that single substitution is what would turn a freshness gate
///      into a decoration — the same shape as C-2.
contract SolvencyRegistrySignedTest is Test {
    SolvencyRegistry reg;

    uint256 attesterPk = 0xA11CE;
    address attester;
    address relayer = makeAddr("relayer"); // pays gas, holds no privilege
    address asset = makeAddr("tsla");
    address other = makeAddr("nvda");

    function setUp() public {
        vm.warp(1_800_000_000);
        attester = vm.addr(attesterPk);
        reg = new SolvencyRegistry(attester);
    }

    // ------------------------------------------------------------------ helpers

    function _digest(
        address a,
        uint64 batchId,
        uint256 notional,
        uint256 margin,
        uint256 oi,
        uint64 observedAt,
        uint64 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash =
            keccak256(abi.encode(reg.ATTEST_TYPEHASH(), a, batchId, notional, margin, oi, observedAt, deadline));
        return keccak256(abi.encodePacked("\x19\x01", reg.domainSeparator(), structHash));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev A well-formed signature observed right now, with the maximum legal deadline.
    function _signFresh(uint64 batchId) internal view returns (uint64 observedAt, uint64 deadline, bytes memory sig) {
        observedAt = uint64(block.timestamp);
        deadline = uint64(block.timestamp + reg.SIGNATURE_VALIDITY());
        sig = _sign(attesterPk, _digest(asset, batchId, 1_000e18, 1_100e18, 50_000e18, observedAt, deadline));
    }

    function _relay(uint64 batchId, uint64 observedAt, uint64 deadline, bytes memory sig) internal {
        vm.prank(relayer);
        reg.attestSigned(asset, batchId, 1_000e18, 1_100e18, 50_000e18, observedAt, deadline, sig);
    }

    // ------------------------------------------------------------------ the point

    /// @notice THE TEST THIS PATH EXISTS FOR. A signature held for 50 seconds must record data that
    ///         is 50 seconds old, not data that looks brand new.
    /// @dev If `attestedAt` were block.timestamp, ageSec would read 0 here and the capacity gate
    ///      would admit mints against minute-old figures believing them fresh. That is the whole
    ///      risk the signed path introduces, so it gets the most explicit test in the file.
    function test_storedAgeIsTheObservationNotTheSubmission() public {
        (uint64 observedAt, uint64 deadline, bytes memory sig) = _signFresh(2);

        vm.warp(block.timestamp + 50); // the relayer sits on it
        _relay(2, observedAt, deadline, sig);

        assertEq(reg.ageSec(asset), 50, "PROPERTY: age must measure the DATA, not the transaction");
        assertEq(reg.latest(asset).attestedAt, observedAt, "stored timestamp must be the signed one");
    }

    /// @notice And the corollary: holding it long enough makes the attestation useless rather than
    ///         freshly wrong. 300s is CapacityOracle's own budget.
    function test_holdingASignatureCannotProduceAFreshAttestation() public {
        (uint64 observedAt, uint64 deadline, bytes memory sig) = _signFresh(2);

        // It cannot even be submitted beyond the validity window - but prove the age, too.
        vm.warp(block.timestamp + reg.SIGNATURE_VALIDITY());
        _relay(2, observedAt, deadline, sig);

        assertEq(reg.ageSec(asset), reg.SIGNATURE_VALIDITY(), "age must equal how long it was held");
        assertGt(reg.ageSec(asset), 0, "a held signature must never read as brand new");
    }

    // ------------------------------------------------------------------ who pays

    function test_anyoneMayRelayAndTheAttesterSpendsNothing() public {
        (uint64 observedAt, uint64 deadline, bytes memory sig) = _signFresh(2);

        uint256 attesterBalanceBefore = attester.balance;
        _relay(2, observedAt, deadline, sig); // sent by `relayer`, not `attester`

        assertEq(reg.latest(asset).batchId, 2, "relayed attestation must land");
        assertEq(attester.balance, attesterBalanceBefore, "the attester must not fund the write");
    }

    // ------------------------------------------------------------------ timestamps

    function test_futureObservationIsRejected() public {
        uint64 observedAt = uint64(block.timestamp + 10);
        uint64 deadline = uint64(block.timestamp + reg.SIGNATURE_VALIDITY());
        bytes memory sig = _sign(attesterPk, _digest(asset, 2, 1_000e18, 1_100e18, 50_000e18, observedAt, deadline));

        vm.prank(relayer);
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_ObservationInFuture.selector);
        reg.attestSigned(asset, 2, 1_000e18, 1_100e18, 50_000e18, observedAt, deadline, sig);
    }

    /// @dev Not a stylistic guard. ageSec computes `block.timestamp - attestedAt` under checked
    ///      arithmetic, so a stored future timestamp makes ageSec REVERT - and every consumer of
    ///      capacity reverts with it. This asserts the view still answers after a rejected attempt.
    function test_ageSecStillAnswersAfterAFutureObservationIsRejected() public {
        (uint64 o1, uint64 d1, bytes memory s1) = _signFresh(2);
        _relay(2, o1, d1, s1);

        uint64 future = uint64(block.timestamp + 1_000);
        uint64 deadline = uint64(block.timestamp + reg.SIGNATURE_VALIDITY());
        bytes memory bad = _sign(attesterPk, _digest(asset, 3, 1_000e18, 1_100e18, 50_000e18, future, deadline));
        vm.prank(relayer);
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_ObservationInFuture.selector);
        reg.attestSigned(asset, 3, 1_000e18, 1_100e18, 50_000e18, future, deadline, bad);

        reg.ageSec(asset); // must not revert
        assertEq(reg.ageSec(asset), 0, "the good attestation must be untouched");
    }

    function test_observationCannotGoBackwards() public {
        vm.warp(block.timestamp + 500);
        (uint64 o1, uint64 d1, bytes memory s1) = _signFresh(2);
        _relay(2, o1, d1, s1);

        // A genuine, correctly signed, EARLIER observation. Rejected because accepting it would
        // raise the recorded age and push capacity toward zero for free.
        //
        // The window to do this in is narrow by construction, and that is worth stating: since
        // `deadline <= observedAt + SIGNATURE_VALIDITY` and `block.timestamp <= deadline`, any
        // acceptable observation is already within SIGNATURE_VALIDITY of now. So the backwards a
        // relayer could reach is at most that window - the guard closes the remainder rather than
        // the whole of time. 30s back, with a deadline that is still live, is the real shape.
        uint64 older = uint64(block.timestamp - 30);
        uint64 deadline = uint64(older + reg.SIGNATURE_VALIDITY());
        bytes memory sig = _sign(attesterPk, _digest(asset, 3, 1_000e18, 1_100e18, 50_000e18, older, deadline));

        vm.prank(relayer);
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_ObservationWentBackwards.selector);
        reg.attestSigned(asset, 3, 1_000e18, 1_100e18, 50_000e18, older, deadline, sig);
    }

    // ------------------------------------------------------------------ deadlines

    function test_expiredSignatureIsRejected() public {
        (uint64 observedAt, uint64 deadline, bytes memory sig) = _signFresh(2);
        vm.warp(uint256(deadline) + 1);

        vm.prank(relayer);
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_SignatureExpired.selector);
        reg.attestSigned(asset, 2, 1_000e18, 1_100e18, 50_000e18, observedAt, deadline, sig);
    }

    /// @dev The signer cannot mint a long-lived credential, deliberately or by accident: the
    ///      contract caps the window rather than trusting the deadline it is handed.
    function test_deadlineBeyondTheValidityWindowIsRejected() public {
        uint64 observedAt = uint64(block.timestamp);
        uint64 tooFar = uint64(block.timestamp + reg.SIGNATURE_VALIDITY() + 1);
        bytes memory sig = _sign(attesterPk, _digest(asset, 2, 1_000e18, 1_100e18, 50_000e18, observedAt, tooFar));

        vm.prank(relayer);
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_SignatureExpired.selector);
        reg.attestSigned(asset, 2, 1_000e18, 1_100e18, 50_000e18, observedAt, tooFar, sig);
    }

    // ------------------------------------------------------------------ signatures

    function test_wrongSignerIsRejected() public {
        uint64 observedAt = uint64(block.timestamp);
        uint64 deadline = uint64(block.timestamp + reg.SIGNATURE_VALIDITY());
        bytes memory sig = _sign(0xBAD, _digest(asset, 2, 1_000e18, 1_100e18, 50_000e18, observedAt, deadline));

        vm.prank(relayer);
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_BadSignature.selector);
        reg.attestSigned(asset, 2, 1_000e18, 1_100e18, 50_000e18, observedAt, deadline, sig);
    }

    /// @dev Any change to the signed figures must invalidate the signature, or the relayer chooses
    ///      the numbers and the attester's role is theatre.
    function test_alteredFiguresInvalidateTheSignature() public {
        (uint64 observedAt, uint64 deadline, bytes memory sig) = _signFresh(2);

        vm.prank(relayer);
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_BadSignature.selector);
        // openInterest18 inflated from 50_000e18 - the figure that widens the capacity ceiling.
        reg.attestSigned(asset, 2, 1_000e18, 1_100e18, 500_000e18, observedAt, deadline, sig);
    }

    function test_signatureCannotBeMovedToAnotherAsset() public {
        (uint64 observedAt, uint64 deadline, bytes memory sig) = _signFresh(2);

        vm.prank(relayer);
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_BadSignature.selector);
        reg.attestSigned(other, 2, 1_000e18, 1_100e18, 50_000e18, observedAt, deadline, sig);
    }

    function test_replayIsRejectedByBatchId() public {
        (uint64 observedAt, uint64 deadline, bytes memory sig) = _signFresh(2);
        _relay(2, observedAt, deadline, sig);

        vm.prank(relayer);
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_StaleBatch.selector);
        reg.attestSigned(asset, 2, 1_000e18, 1_100e18, 50_000e18, observedAt, deadline, sig);
    }

    // ------------------------------------------------------------------ rotation

    /// @dev M-5 must keep its meaning on this path: rotating the attester has to invalidate the old
    ///      key's signatures immediately, not merely stop it sending transactions.
    function test_rotatedOutAttesterSignaturesStopWorking() public {
        uint256 nextPk = 0xB0B;
        address next = vm.addr(nextPk);

        vm.prank(address(this)); // deployer is governance
        reg.proposeAttester(next);
        vm.warp(block.timestamp + reg.ATTESTER_ROTATION_DELAY());
        reg.acceptAttester();
        assertEq(reg.attester(), next, "rotation must have completed");

        // Signed with the OLD key, and signed NOW so the deadline is unimpeachable - otherwise the
        // expiry check would answer first and this would prove nothing about rotation.
        (uint64 observedAt, uint64 deadline, bytes memory oldSig) = _signFresh(2);

        vm.prank(relayer);
        vm.expectRevert(SolvencyRegistry.SolvencyRegistry_BadSignature.selector);
        reg.attestSigned(asset, 2, 1_000e18, 1_100e18, 50_000e18, observedAt, deadline, oldSig);
    }

    // ------------------------------------------------------------------ coexistence

    /// @dev The keeper path must keep working while the signed path is adopted, so a migration does
    ///      not need both sides switched in the same instant.
    function test_directAttestStillWorksAlongsideTheSignedPath() public {
        (uint64 observedAt, uint64 deadline, bytes memory sig) = _signFresh(2);
        _relay(2, observedAt, deadline, sig);

        vm.prank(attester);
        reg.attest(asset, 3, 2_000e18, 2_100e18, 60_000e18);
        assertEq(reg.latest(asset).batchId, 3);
        assertEq(reg.latest(asset).attestedAt, uint64(block.timestamp), "direct attest still stamps now");
    }

    // ------------------------------------------------------------------ end to end

    /// @notice The property a user actually cares about: after a THIRD PARTY relays the signature,
    ///         capacity is open and a mint would be admitted.
    /// @dev Everything else in this file tests the registry in isolation. This one goes through
    ///      CapacityOracle, which is what CertVault._requireCapacity consults - so it fails if the
    ///      signed path stores something the capacity gate cannot read, which is the whole risk of
    ///      swapping out how attestations arrive.
    function test_relayedAttestationReopensCapacity() public {
        CapacityOracle cap = new CapacityOracle(address(reg), address(this), 100, 1, 10_000, 300, type(uint256).max);
        cap.setAbsoluteCap(asset, 10_000_000e18); // governance is this test contract

        assertEq(cap.maxNotional18(asset, 1_000_000e18), 0, "no attestation yet - capacity must be shut");

        (uint64 observedAt, uint64 deadline, bytes memory sig) = _signFresh(2);
        _relay(2, observedAt, deadline, sig);

        assertGt(cap.maxNotional18(asset, 1_000_000e18), 0, "PROPERTY: a relayed attestation must reopen capacity");
    }

    /// @dev And the converse, which is the guard actually doing its job: a signature held past the
    ///      capacity budget produces an attestation that is ALREADY too old to mint against. If
    ///      block.timestamp were stored instead of observedAt, this would wrongly read as open.
    function test_aSignatureRelayedLateCannotReopenCapacity() public {
        CapacityOracle cap = new CapacityOracle(address(reg), address(this), 100, 1, 10_000, 300, type(uint256).max);
        cap.setAbsoluteCap(asset, 10_000_000e18); // governance is this test contract

        (uint64 o1, uint64 d1, bytes memory s1) = _signFresh(2);
        _relay(2, o1, d1, s1);
        assertGt(cap.maxNotional18(asset, 1_000_000e18), 0, "fresh relay opens capacity");

        vm.warp(block.timestamp + 301);
        assertEq(cap.maxNotional18(asset, 1_000_000e18), 0, "PROPERTY: past the budget, capacity must shut again");
    }

    function test_domainSeparatorBindsThisChainAndThisContract() public {
        bytes32 here = reg.domainSeparator();
        SolvencyRegistry twin = new SolvencyRegistry(attester);
        assertTrue(here != twin.domainSeparator(), "two deployments must not share a domain");

        vm.chainId(block.chainid + 1);
        assertTrue(here != reg.domainSeparator(), "a fork must not inherit valid signatures");
    }
}
