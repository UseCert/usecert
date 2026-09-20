// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CertOracle} from "../src/CertOracle.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

/// @notice The signed mark-price path — the companion to SolvencyRegistry.attestSigned.
/// @dev The property is the same one: moving who SENDS the transaction must not move what the
///      update is allowed to SAY, or who is allowed to say it.
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

    function setUp() public {
        vm.warp(1_800_000_000);
        attester = vm.addr(attesterPk);
        feed = new MockAggregatorV3(8, int256(PX / 1e10)); // 8 decimals, priced at PX
        oracle = new CertOracle(address(feed), attester, 2, STALENESS, DEVIATION_BPS, 100, POKE_WINDOW, false);
    }

    function _sign(uint256 pk, uint256 px18, uint64 nonce, uint64 deadline) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(oracle.SET_MARK_TYPEHASH(), px18, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", oracle.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ------------------------------------------------------------------ happy path

    function test_relayerMaySubmitAndTheAttesterSpendsNothing() public {
        uint64 deadline = uint64(block.timestamp + 60);
        bytes memory sig = _sign(attesterPk, PX, 1, deadline);

        uint256 attesterBalanceBefore = attester.balance;
        vm.prank(relayer);
        oracle.setMarkPriceSigned(PX, 1, deadline, sig);

        assertEq(oracle.markPx18(), PX, "mark must be written by the relayed signature");
        assertEq(oracle.markNonce(), 1);
        assertEq(attester.balance, attesterBalanceBefore, "the attester must not fund the write");
    }

    // ------------------------------------------------------------------ replay

    function test_sameNonceCannotBeReplayed() public {
        uint64 deadline = uint64(block.timestamp + 60);
        bytes memory sig = _sign(attesterPk, PX, 1, deadline);
        vm.prank(relayer);
        oracle.setMarkPriceSigned(PX, 1, deadline, sig);

        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_StaleNonce.selector);
        oracle.setMarkPriceSigned(PX, 1, deadline, sig);
    }

    /// @dev The nonce must strictly increase, so an OLDER signature cannot be resurrected after a
    ///      newer one has landed — which is the move that would let a relayer pick which of several
    ///      genuine marks is current.
    function test_anEarlierSignatureCannotBeResurrected() public {
        uint64 deadline = uint64(block.timestamp + 60);
        bytes memory first = _sign(attesterPk, PX, 1, deadline);
        bytes memory second = _sign(attesterPk, PX + 5e18, 2, deadline);

        vm.prank(relayer);
        oracle.setMarkPriceSigned(PX + 5e18, 2, deadline, second);

        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_StaleNonce.selector);
        oracle.setMarkPriceSigned(PX, 1, deadline, first);
        assertEq(oracle.markPx18(), PX + 5e18, "the newer mark must stand");
    }

    // ------------------------------------------------------------------ signature

    function test_wrongSignerIsRejected() public {
        uint64 deadline = uint64(block.timestamp + 60);
        bytes memory sig = _sign(0xBAD, PX, 1, deadline);

        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_BadSignature.selector);
        oracle.setMarkPriceSigned(PX, 1, deadline, sig);
    }

    /// @dev If the price could be changed without invalidating the signature, the relayer would be
    ///      choosing the mark and the attester's signature would mean nothing.
    function test_alteredPriceInvalidatesTheSignature() public {
        uint64 deadline = uint64(block.timestamp + 60);
        bytes memory sig = _sign(attesterPk, PX, 1, deadline);

        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_BadSignature.selector);
        oracle.setMarkPriceSigned(PX * 2, 1, deadline, sig);
    }

    function test_expiredSignatureIsRejected() public {
        uint64 deadline = uint64(block.timestamp + 60);
        bytes memory sig = _sign(attesterPk, PX, 1, deadline);
        vm.warp(uint256(deadline) + 1);

        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_SignatureExpired.selector);
        oracle.setMarkPriceSigned(PX, 1, deadline, sig);
    }

    function test_signatureCannotBeMovedToAnotherOracle() public {
        uint64 deadline = uint64(block.timestamp + 60);
        bytes memory sig = _sign(attesterPk, PX, 1, deadline);

        CertOracle twin = new CertOracle(address(feed), attester, 2, STALENESS, DEVIATION_BPS, 100, POKE_WINDOW, false);
        vm.prank(relayer);
        vm.expectRevert(CertOracle.CertOracle_BadSignature.selector);
        twin.setMarkPriceSigned(PX, 1, deadline, sig);
    }

    // ------------------------------------------------------------------ the structural guard

    /// @notice A stale mark relayed inside its deadline still cannot open minting, because the
    ///         basis band measures it against the LIVE feed rather than against a clock.
    /// @dev This is why setMarkPriceSigned carries no `observedAt` while the registry does: the
    ///      registry's figures are only checked by age, so age had to be signed. The mark is
    ///      checked by agreement with the feed, and that check does not care how old it is.
    function test_aMarkThatDriftedFromTheFeedClosesMintingByItself() public {
        uint64 deadline = uint64(block.timestamp + 60);
        // 10% away from the feed, against a 100bps band.
        uint256 drifted = PX * 110 / 100;
        bytes memory sig = _sign(attesterPk, drifted, 1, deadline);

        vm.prank(relayer);
        oracle.setMarkPriceSigned(drifted, 1, deadline, sig);

        assertEq(oracle.markPx18(), drifted, "the write itself is permitted");
        assertFalse(oracle.mintAllowed(), "PROPERTY: a mark off the feed must close minting");
    }

    function test_aMarkOnTheFeedLeavesMintingOpen() public {
        uint64 deadline = uint64(block.timestamp + 60);
        bytes memory sig = _sign(attesterPk, PX, 1, deadline);
        vm.prank(relayer);
        oracle.setMarkPriceSigned(PX, 1, deadline, sig);

        assertTrue(oracle.mintAllowed(), "an honest mark must leave minting open");
    }

    // ------------------------------------------------------------------ coexistence

    function test_directSetMarkPriceStillWorks() public {
        vm.prank(attester);
        oracle.setMarkPrice(PX);
        assertEq(oracle.markPx18(), PX);
        assertEq(oracle.markNonce(), 0, "the direct path must not consume a nonce");
    }

    /// @dev And the two paths must not fight: a direct write leaves the nonce alone, so a signature
    ///      prepared before it is still usable afterwards. A migration can run both at once.
    function test_aSignaturePreparedBeforeADirectWriteStillApplies() public {
        uint64 deadline = uint64(block.timestamp + 60);
        bytes memory sig = _sign(attesterPk, PX, 1, deadline);

        vm.prank(attester);
        oracle.setMarkPrice(PX * 99 / 100);

        vm.prank(relayer);
        oracle.setMarkPriceSigned(PX, 1, deadline, sig);
        assertEq(oracle.markPx18(), PX);
    }
}
