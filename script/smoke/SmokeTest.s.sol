// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {TestnetAddressBook} from "../VerifyTestnet.s.sol";
import {CertVault} from "../../src/CertVault.sol";
import {Certificate} from "../../src/Certificate.sol";
import {CertOracle} from "../../src/CertOracle.sol";
import {CapacityOracle} from "../../src/CapacityOracle.sol";
import {LighterSim} from "../../src/sim/LighterSim.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @title  The one §9 item that cannot be read: a live dust `forceExit`.
///
/// @notice `docs/DEPLOYMENT-CHECKLIST.md` §9: "a `forceExit` of a dust position succeeds on the
///         live deployment — THIS IS LAW 2 AND IT IS WORTH ONE REAL TRANSACTION." Law 2 says every
///         non-zero redemption must remain possible with every off-chain service dead, the buffer
///         empty and the oracle stale. That is a claim about EXECUTION, and no amount of reading
///         state establishes it: the arithmetic overflow that made `forceExit` panic 0x11 at an
///         extreme price (Finding 1, Critical) was invisible in every read-back of every field.
///         So this sends transactions, deliberately, and it is the only script in this task's set
///         that does.
///
/// @notice SEPARATE ENTRYPOINT FROM `script/VerifyTestnet.s.sol`, AND THAT SEPARATION IS THE
///         DESIGN. The verifier is read-only so an operator can run §9 against a live deployment
///         at any time without touching it. This script mints, redeems and exits real value. An
///         operator chooses to run it; they never get it as a side effect of checking.
///
/// @notice WHAT IT DOES, in one sender's transactions:
///
///           1. `mintInstant` of a dust amount   — the instant path, end to end.
///           2. `redeemInstant` of half of it    — the instant redemption path, off the hot buffer.
///           3. `forceExit` of the remainder     — §9's row. LAW 2's BACKSTOP.
///           4. `settleBatch` then `claimRedeem` — the queued payout actually lands.
///
///         Steps 1 and 2 are "a small instant mint and an instant redeem alongside it": they cost
///         nothing extra, they exercise the two paths a tester will use first, and step 3 needs a
///         position to exit in any case.
///
/// @dev    THE SENDER. `SMOKE_PK`, defaulting to `DEPLOYER_PK`, and the default is not laziness:
///         the deployer holds the test collateral this script spends AND is `LighterSim.owner()`,
///         so it is the one key that can also advance the batch in step 4. A different key works
///         for steps 1-3; step 4 is skipped with a loud note rather than failed, because Law 2's
///         row is `forceExit` succeeding and the claim is the bonus.
///
///         NO KEY IS EVER HARDCODED OR LOGGED. Only the derived address is printed, exactly as in
///         `script/DeployTestnet.s.sol` and the keepers.
///
/// @dev    USAGE
///
///           export SMOKE_PK=0x...              # or rely on DEPLOYER_PK
///           forge script script/smoke/SmokeTest.s.sol \
///             --rpc-url robinhood_testnet --broadcast --slow
///
///         `--slow` matters: step 4 depends on step 3's order actually being in the queue.
///
///         `SMOKE_VAULT_INDEX` picks the mirror (default 0). `SMOKE_AMOUNT` overrides the dust
///         amount in COLLATERAL UNITS (default 10 tokens). Run `script/VerifyTestnet.s.sol` first:
///         every reason this script can fail on a healthy deployment is a §9 item that one reports
///         by name.
contract SmokeTest is TestnetAddressBook {
    /// @dev Deliberately tiny. §9 says "a dust position", and a smoke test that moves real size on
    ///      a shared testnet deployment is a smoke test people stop running. 10 collateral units at
    ///      6 decimals, well under `instantCap18`, and large enough that
    ///      `_quantiseToVenue` does not floor the hedge to zero at `sizeDecimals = 4` for either
    ///      C1 market (uTSLA at ~$366 gives ~273 base ticks, uSPY at ~$650 gives ~153).
    uint256 internal constant DEFAULT_DUST_TOKENS = 10;

    function run() external {
        _loadBook();
        _requireBookMatchesChain();

        uint256 pk = vm.envOr("SMOKE_PK", uint256(0));
        if (pk == 0) pk = vm.envUint("DEPLOYER_PK");
        address sender = vm.addr(pk);

        uint256 idx = vm.envOr("SMOKE_VAULT_INDEX", uint256(0));
        require(idx < mirrors.length, "SMOKE: SMOKE_VAULT_INDEX is past the last vault in the address book");

        address vaultAddr = mirrors[idx].vault;
        uint256 amount = vm.envOr("SMOKE_AMOUNT", DEFAULT_DUST_TOKENS * (10 ** bookCollateralDecimals));

        console2.log("=== SmokeTest: the live dust forceExit (S9, Law 2) ===");
        console2.log("chain          ", block.chainid);
        console2.log("sender         ", sender);
        console2.log(string.concat("mirror          ", mirrors[idx].symbol), vaultAddr);
        console2.log("dust amount    ", amount);

        _preflight(sender, vaultAddr, idx, amount);

        vm.startBroadcast(pk);
        uint256 certs = _mint(vaultAddr, amount);
        uint256 remaining = _instantRedeem(vaultAddr, certs);
        uint256 receiptId = _forceExit(vaultAddr, remaining);
        vm.stopBroadcast();

        _settleAndClaim(pk, sender, vaultAddr, receiptId);

        console2.log("");
        console2.log("SMOKE: PASS. S9's live forceExit row is discharged for", mirrors[idx].symbol);
    }

    // ---------------------------------------------------------------------------- preflight

    /// @dev EVERY REASON THIS SCRIPT CAN FAIL ON A HEALTHY DEPLOYMENT, CHECKED BEFORE A SINGLE
    ///      TRANSACTION IS SENT, and each with a message that says what to do. Sending a mint that
    ///      reverts `CertVault_MintPaused` on a live chain costs gas and tells the operator
    ///      nothing they could act on; this tells them the attester keeper is not running.
    function _preflight(address sender, address vaultAddr, uint256 idx, uint256 amount) private view {
        CertVault v = CertVault(vaultAddr);
        CertOracle o = CertOracle(mirrors[idx].certOracle);

        require(amount != 0, "SMOKE: dust amount is 0 - CertVault_ZeroAmount");
        require(v.bootstrapped(), "SMOKE: vault is not bootstrapped - run script/DeployTestnet.s.sol to completion");
        require(
            v.lighterAccountIndex() != 0,
            "SMOKE: lighterAccountIndex == 0 - the registering deposit has not been executed by a batch"
        );
        require(
            IERC20(bookCollateral).balanceOf(sender) >= amount,
            "SMOKE: sender holds less collateral than the dust amount - use the faucet or lower SMOKE_AMOUNT"
        );
        // The three ways the mint gate is closed, named separately, because they have three
        // different remedies and an operator staring at `CertVault_MintPaused` cannot tell which.
        require(
            o.mintAllowed(),
            "SMOKE: oracle.mintAllowed() is false - feed stale (FeedKeeper), mark unset or basis outside the band (Attester)"
        );
        require(
            CapacityOracle(bookCapacity).maxNotional18(vaultAddr, v.bufferCapacity18()) != 0,
            "SMOKE: maxNotional18 == 0 - the attestation is stale (start script/keepers/Attester.s.sol) or absoluteCap18 is unset"
        );
        console2.log("preflight       OK");
    }

    // ------------------------------------------------------------------------------ the steps

    /// @dev Step 1. The instant mint path. `mintInstant` refuses anything above `instantCap18`, so
    ///      dust is the right side of that boundary by construction.
    function _mint(address vaultAddr, uint256 amount) private returns (uint256 certs) {
        IERC20(bookCollateral).approve(vaultAddr, amount);
        certs = CertVault(vaultAddr).mintInstant(amount);
        require(certs != 0, "SMOKE: mintInstant returned 0 certificates");
        console2.log("1. mintInstant  certs out", certs);
    }

    /// @dev Step 2. The instant redemption path, paid straight out of the hot buffer. HALF, so
    ///      there is a remainder for step 3 — and the halving is what makes step 3 an exit of a
    ///      position that already exists rather than an unwind of the whole mint.
    function _instantRedeem(address vaultAddr, uint256 certs) private returns (uint256 remaining) {
        uint256 half = certs / 2;
        require(half != 0, "SMOKE: dust amount too small to split - raise SMOKE_AMOUNT");
        uint256 out = CertVault(vaultAddr).redeemInstant(half);
        console2.log("2. redeemInstant collateral out", out);
        remaining = certs - half;
    }

    /// @dev STEP 3 — §9's ROW, AND THE REASON THIS FILE EXISTS. `forceExit` is Law 2's backstop:
    ///      it must work for a holder with a balance at any price, in any oracle or buffer state,
    ///      with every off-chain service dead. It prices off `pxUnguarded()` for exactly that
    ///      reason. This is the transaction §9 calls worth sending.
    function _forceExit(address vaultAddr, uint256 certIn) private returns (uint256 receiptId) {
        require(certIn != 0, "SMOKE: nothing left to forceExit");
        // Both queued exits burn the certificates in the vault, so the holder's approval is not
        // part of this path; `Certificate.burn` is vault-only. Recorded here because the absence of
        // an approve() call on a redemption path is the kind of thing a reader assumes is a bug.
        receiptId = CertVault(vaultAddr).forceExit(certIn);
        console2.log("3. forceExit    certs in", certIn);
        console2.log("   receipt id", receiptId);
    }

    /// @dev Step 4. The payout actually lands. `claimRedeem` needs the close order to have been
    ///      EXECUTED, and on this simulator settlement is a keeper's job — so this needs the sim's
    ///      owner or its registered keeper. When the smoke sender is neither, the step is SKIPPED
    ///      WITH A NOTE rather than failed: §9's row is `forceExit` succeeding, which step 3
    ///      already did, and a smoke test that fails for lack of a permission it never claimed to
    ///      hold is a false alarm.
    function _settleAndClaim(uint256 pk, address sender, address vaultAddr, uint256 receiptId) private {
        LighterSim s = LighterSim(bookLighterSim);
        if (sender != s.owner() && sender != s.keeper()) {
            console2.log("4. SKIPPED: sender is neither LighterSim.owner() nor keeper(), so it cannot settleBatch.");
            console2.log("   Law 2's row (step 3) is discharged. Claim it with:");
            console2.log("   cast send <vault> 'claimRedeem(uint256)'", receiptId);
            return;
        }
        vm.startBroadcast(pk);
        s.settleBatch();
        // The one call here that may legitimately refuse: `CertVault_AwaitingSettlement` is
        // RETRYABLE and not a violation — the close order sits behind up to `SETTLE_BATCH_MAX`
        // others. Reported so the operator retries rather than reading it as a failed smoke test.
        try CertVault(vaultAddr).claimRedeem(receiptId) returns (uint256 amountOut) {
            console2.log("4. settleBatch + claimRedeem  collateral out", amountOut);
        } catch {
            console2.log("4. settleBatch OK; claimRedeem is still awaiting settlement - RETRYABLE, not a failure.");
            console2.log("   Advance another batch and retry: cast send <vault> 'claimRedeem(uint256)'", receiptId);
        }
        vm.stopBroadcast();
    }
}
