// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {VaultFixture} from "./helpers/VaultFixture.sol";
import {CertVault} from "../src/CertVault.sol";

/// @notice Keeper mode: hedges are OPENED off chain by the keeper and CLOSED on chain.
/// @dev Exists because on Robinhood Chain Lighter every order sent through the L1 contract is
///      reduce-only (venue execution record: code 21738, "invalid reduce only direction"). A
///      contract cannot open a position on chain at all. Each test below pins one claim the
///      design makes; the simulator underneath does NOT enforce reduce-only, so these tests
///      assert what the VAULT sends, which is the part under our control.
contract CertVaultKeeperHedgingTest is VaultFixture {
    bytes internal constant PUBKEY =
        hex"012258abd09aa219c49c168c88d3fdb0c4f1004757709ae2400824c2ed19534cb4e3e038864c6076";

    bytes32 internal constant HEDGE_REQUESTED = keccak256("HedgeRequested(uint256,uint256,uint8,uint256)");

    function _enable() internal {
        vm.prank(gov);
        vault.enableKeeperHedging();
    }

    function _indicative(uint256 id) internal view returns (uint256 indicative) {
        (,,,,,, indicative) = vault.mintReceipts(id);
    }

    // ----------------------------------------------------------------------------- the switch

    function test_offByDefault_requestMintStillSendsItsOwnOrder() public {
        assertFalse(vault.keeperHedging());
        uint256 before = lighter.queuedOrderCount();
        vm.prank(alice);
        vault.requestMint(50_000e6);
        assertEq(lighter.queuedOrderCount(), before + 1, "default behaviour changed for every existing deployment");
    }

    function test_enableIsGovernanceOnlyAndOneWay() public {
        vm.expectRevert(CertVault.CertVault_OnlyGovernance.selector);
        vm.prank(alice);
        vault.enableKeeperHedging();

        _enable();
        assertTrue(vault.keeperHedging());

        vm.expectRevert(CertVault.CertVault_KeeperHedgingAlreadyEnabled.selector);
        vm.prank(gov);
        vault.enableKeeperHedging();
    }

    // ------------------------------------------------------------------------------- opening

    /// The mint escrows, sends NO order to the venue (it would be discarded as reduce-only while
    /// the ledger recorded it), mints NOTHING, and hands the keeper a priced work order.
    function test_keeperMode_requestMintIssuesAWorkOrderAndNothingElse() public {
        _enable();
        uint256 ordersBefore = lighter.queuedOrderCount();
        int256 ledgerBefore = vault.venuePositionBase();

        vm.recordLogs();
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(lighter.queuedOrderCount(), ordersBefore, "an opening order was sent on chain");
        assertEq(cert.balanceOf(alice), 0, "certificates issued before any hedge exists");
        assertEq(vault.venuePositionBase(), ledgerBefore, "ledger recorded a position that does not exist yet");

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] != HEDGE_REQUESTED) continue;
            found = true;
            assertEq(uint256(logs[i].topics[1]), id, "work order names the wrong receipt");
            (uint256 base, uint8 side, uint256 limitPx18) = abi.decode(logs[i].data, (uint256, uint8, uint256));
            assertEq(base, _indicative(id) * 1e4 / 1e18, "work order size is not the receipt's hedge");
            assertEq(side, 0, "an opening hedge is a buy");
            // A market order's price is its worst acceptable fill; a buy capped at the oracle
            // never fills when the ask sits above it. +1% band.
            assertEq(limitPx18, PX * 10_100 / 10_000, "work order is not priced at the band");
        }
        assertTrue(found, "no HedgeRequested work order emitted");
    }

    function test_keeperMode_mintInstantRefusesToOpenOnChain() public {
        _enable();
        vm.expectRevert(CertVault.CertVault_OpenRequiresKeeper.selector);
        vm.prank(alice);
        vault.mintInstant(1_000e6);
    }

    function test_keeperMode_requestMintBelowTheVenueMinimumRefusesBeforeTakingEscrow() public {
        _enable();
        // The notional minimum cannot bite here: this fixture's instant cap is $10k, so every
        // requestMint is above it, and the setter refuses a notional minimum above $1,000 so it
        // cannot be used to price out every mint. The BASE minimum is the one that bites: this
        // mint hedges 1,403,641 base units (140.3641 TSLA at sizeDecimals 4).
        vm.prank(gov);
        vault.setVenueMinimums(2_000_000, 0);

        uint256 balBefore = usdg.balanceOf(alice);
        vm.expectRevert(CertVault.CertVault_BelowVenueMinimum.selector);
        vm.prank(alice);
        vault.requestMint(50_000e6);
        assertEq(usdg.balanceOf(alice), balBefore);
    }

    // -------------------------------------------------------------------------------- settling

    /// Settling is the claim that the off-chain hedge FILLED, so only the keeper makes it, and the
    /// position enters the vault's ledger then and not before.
    function test_keeperMode_onlyTheAttesterSettlesAndSettlingRecordsThePosition() public {
        _enable();
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        uint256 indicative = _indicative(id);
        int256 ledgerBefore = vault.venuePositionBase();

        vm.expectRevert(CertVault.CertVault_OnlyAttester.selector);
        vault.settleMint(id, PX);

        vm.prank(attester);
        vault.settleMint(id, PX);

        assertEq(cert.balanceOf(alice), indicative);
        assertEq(vault.venuePositionBase(), ledgerBefore + int256(indicative * 1e4 / 1e18));
    }

    // ---------------------------------------------------------------------------------- exits

    /// The trustless half survives: a redemption still closes ON CHAIN, and it is a sell, which is
    /// exactly what the venue's reduce-only L1 orders allow.
    function test_keeperMode_redemptionStillClosesOnChain() public {
        _enable();
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);
        vm.prank(attester);
        vault.settleMint(id, PX);

        // Read first: vm.prank applies to the NEXT external call, and cert.balanceOf inside the
        // argument list would consume it.
        uint256 certs = cert.balanceOf(alice);
        uint256 before = lighter.queuedOrderCount();
        vm.prank(alice);
        vault.requestRedeem(certs);

        assertEq(lighter.queuedOrderCount(), before + 1, "redemption did not close on chain");
        (,,, uint8 isAsk,) = lighter.lastOrder();
        assertEq(isAsk, 1, "an exit must be a sell");
    }

    /// An unsettled receipt never entered the ledger and the chain cannot know whether the keeper
    /// opened its hedge, so a reduce-only sell here could cut into OTHER holders' hedge. The
    /// refund returns the escrow and sends no close.
    function test_keeperMode_refundSendsNoOnChainClose() public {
        _enable();
        vm.prank(alice);
        uint256 id = vault.requestMint(50_000e6);

        vm.warp(block.timestamp + SETTLE_WINDOW + 1);
        uint256 before = lighter.queuedOrderCount();
        vault.stageRefund(id);
        assertEq(lighter.queuedOrderCount(), before, "refund sent a sell that can cut other holders' hedge");
    }

    // ------------------------------------------------------------------------------ the key

    function test_setVenueApiKeyIsGovernanceOnlyAndLandsOnTheVaultsOwnAccount() public {
        vm.expectRevert(CertVault.CertVault_OnlyGovernance.selector);
        vm.prank(alice);
        vault.setVenueApiKey(3, PUBKEY);

        vm.prank(gov);
        vault.setVenueApiKey(3, PUBKEY);
        assertEq(lighter.apiKeyOf(vault.lighterAccountIndex(), 3), PUBKEY);
    }
}
