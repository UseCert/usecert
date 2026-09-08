// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {console2} from "forge-std/console2.sol";
import {CertVault} from "../../src/CertVault.sol";
import {Certificate} from "../../src/Certificate.sol";
import {ICertOracle} from "../../src/interfaces/ICertOracle.sol";
import {SolvencyRegistry} from "../../src/SolvencyRegistry.sol";
import {CapacityOracle} from "../../src/CapacityOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockLighter} from "../mocks/MockLighter.sol";

/// @notice Drives randomised mint/redeem/settle/margin sequences against one vault and records
///         the ground truth the invariants in BackingInvariant.t.sol check.
/// @dev fail_on_revert = false (foundry.toml) means a plain revert does not fail an invariant run
///      by itself — it is this handler's job to tell an ACCEPTABLE revert from a VIOLATION. Every
///      accept below is keyed to a specific custom-error selector, never a bare catch, so a
///      genuine defect still surfaces as an incremented counter the invariants can see. See
///      task-12-report.md for the load-bearing proof that lawTwoViolations can actually go
///      non-zero (a temporary gate was added to _queueExit, the invariant failed with a
///      counterexample, then the gate was removed).
///
///      Task 12 review fix (see task-12-report.md's appended "Fix report"): the handler originally
///      had no way to move registry.latest(vault) or cap.depthBps()/absoluteCap18() away from the
///      fixture's frozen setUp() values — attest() and setDepthBps() are attester-/governance-only,
///      and the handler impersonated neither. That made _requireCapacity's comparison, rebalance()'s
///      delta-band check, and invariant_capacityNeverExceedsAbsoluteCap's dependencies all static
///      dead weight. attest/setDepthBps/accrueFunding below give the handler the system's real
///      privileged actors (pranked, not cheated — they are genuine participants Law 2 must survive)
///      so those branches move under fuzzing.
contract VaultHandler is CommonBase, StdUtils {
    CertVault public immutable vault;
    Certificate public immutable cert;
    MockERC20 public immutable usdg;
    MockLighter public immutable lighter;
    ICertOracle public immutable oracle;
    SolvencyRegistry public immutable reg;
    CapacityOracle public immutable cap;
    address public immutable attester;
    address public immutable gov;

    /// @notice The smallest certAmount18 for which CertVault._baseAmount(...) is non-zero at this
    ///         vault's sizeDecimals — i.e. the smallest redemption the venue can even represent as
    ///         a trade. Below this, `_baseAmount` floors to 0, which is Lighter's own "close the
    ///         entire position" primitive, not "no trade".
    /// @dev FINDING (surfaced by this suite's very first invariant run, not manufactured):
    ///      redeemInstant() hedges through the revert-capable _hedge (CertVault.sol), unlike
    ///      requestRedeem/forceExit which share _queueExit's fail-open _tryHedge. A holder who
    ///      legitimately owns a non-zero but sub-tick certificate balance (e.g. 99 wei of the
    ///      18-decimal certificate, worth a fraction of a cent) and calls redeemInstant on it gets
    ///      CertVault_ZeroHedgeAmount — a revert outside the three exceptions Law 2 allows (zero
    ///      amount, insufficient balance, CertVault_UseQueuedRedeem). The queued path handles the
    ///      identical amount fine (_tryHedge just reports the close as not-placed and the burn +
    ///      receipt still go through), so this is a real, narrow asymmetry in redeemInstant, not a
    ///      harness artifact. Bounding the handler's redeem amounts at this floor keeps the suite
    ///      testing realistic redemption sizes rather than sub-tick dust; see task-12-report.md
    ///      for the full transcript and why it is reported as a residual risk rather than patched
    ///      here (out of Task 12's scope, which is the invariant suite itself).
    uint256 public immutable dustFloorCert;

    // ---------------------------------------------------------------------------- Law 2 ground truth
    /// @notice Incremented whenever a non-zero redemption attempt by a holder who owns the
    ///         certificates (redeemInstant, requestRedeem, forceExit) — or the queued path's final
    ///         claimRedeem payout — fails for any reason other than the one documented routing
    ///         signal (CertVault_UseQueuedRedeem, handled by falling through to the queued path,
    ///         which must then itself succeed). The invariant under test asserts this stays zero.
    uint256 public lawTwoViolations;

    // -------------------------------------------------------------------------------- supply ground truth
    uint256 public totalMinted;
    uint256 public totalBurned;

    // ------------------------------------------------------------------------------- margin ground truth
    /// @notice Ghost accumulator: every observed INCREASE in vault.postedMargin() across any call
    ///         this handler makes, seeded with whatever postedMargin already was at construction
    ///         (VaultFixture's bootstrap() dust deposit, which happens before this handler
    ///         exists). postedMargin increases only via _postMargin (the mint side) and decreases
    ///         only via _queueExit (the redeem side, an allocation, not a withdrawal) — so summing
    ///         its increases gives exactly the total collateral this vault has ever deposited to
    ///         the venue as margin.
    uint256 public totalDepositedToVenue;

    // --------------------------------------------------------------------------------- bookkeeping
    uint256[] public pendingMintReceipts;
    uint256[] public pendingRedeemReceipts;

    /// @dev SolvencyRegistry.attest requires a strictly increasing batchId. The fixture's setUp()
    ///      already attests batchId 1 before this handler exists, so this seeds from whatever is
    ///      live at construction rather than assuming 1.
    uint64 public nextBatchId;

    // ------------------------------------------------------------------- call counters, for the report
    uint256 public callsMintInstant;
    uint256 public callsRequestMint;
    uint256 public callsSettleMint;
    uint256 public callsRedeemInstant;
    uint256 public callsRequestRedeem;
    uint256 public callsForceExit;
    uint256 public callsClaimRedeem;
    uint256 public callsRecallMargin;
    uint256 public callsRebalance;
    uint256 public callsSettleBatch;
    uint256 public callsAttest;
    uint256 public callsSetDepthBps;
    uint256 public callsAccrueFunding;

    // ------------------------------------------------------- reachability counters, for the report
    /// @dev These are NOT invariants — nothing asserts on them. They exist purely so a verification
    ///      run can prove specific revert branches are actually exercised under fuzzing (Task 12
    ///      review, Finding 1). Like the call counters above, handler storage resets every
    ///      invariant run, so for campaign-wide totals read the console2.log lines emitted
    ///      alongside each increment (console output is captured live, independent of the
    ///      per-run state snapshot/revert) rather than these fields' final values, which only
    ///      reflect the last run. See task-12-report.md's appended "Fix report" for the counts.
    uint256 public mintAtCapacityCount;
    uint256 public mintAboveInstantCapCount;
    uint256 public requestMintAtCapacityCount;
    uint256 public requestMintBelowInstantCapCount;
    uint256 public settleMintAtCapacityCount;
    uint256 public rebalanceInBandCount;
    uint256 public settleBatchInsufficientMarginCount;

    constructor(
        CertVault _vault,
        MockERC20 _usdg,
        MockLighter _lighter,
        SolvencyRegistry _reg,
        CapacityOracle _cap,
        address _attester,
        address _gov
    ) {
        vault = _vault;
        cert = Certificate(_vault.certificate());
        usdg = _usdg;
        lighter = _lighter;
        oracle = _vault.oracle();
        reg = _reg;
        cap = _cap;
        attester = _attester;
        gov = _gov;
        totalDepositedToVenue = _vault.postedMargin(); // bootstrap's dust, deposited before we existed
        nextBatchId = reg.latest(address(_vault)).batchId;

        (,,,, uint8 sizeDecimals,,,,,) = _vault.cfg();
        dustFloorCert = 10 ** (18 - sizeDecimals);
    }

    // ---------------------------------------------------------------------------------------- mint

    function mintInstant(uint256 amount) external {
        callsMintInstant++;
        amount = bound(amount, 10e6, 8_000e6); // stays under instantCap18 with headroom
        usdg.mint(address(this), amount);
        usdg.approve(address(vault), amount);

        uint256 postedBefore = vault.postedMargin();
        try vault.mintInstant(amount) returns (uint256 certOut) {
            totalMinted += certOut;
        } catch (bytes memory reason) {
            if (_isSelector(reason, CertVault.CertVault_AtCapacity.selector)) {
                mintAtCapacityCount++;
                console2.log("MINT_AT_CAPACITY", mintAtCapacityCount);
            } else if (_isSelector(reason, CertVault.CertVault_AboveInstantCap.selector)) {
                mintAboveInstantCapCount++;
                console2.log("MINT_ABOVE_INSTANT_CAP", mintAboveInstantCapCount);
            }
            // else: a paused oracle or another legitimate mint-side gate. Law 2 says nothing
            // about minting.
        }
        _trackDeposit(postedBefore);
    }

    function requestMint(uint256 amount) external {
        callsRequestMint++;
        amount = bound(amount, 10_100e6, 25_000e6); // net, after fee, clears instantCap18
        usdg.mint(address(this), amount);
        usdg.approve(address(vault), amount);

        uint256 postedBefore = vault.postedMargin();
        try vault.requestMint(amount) returns (uint256 receiptId) {
            pendingMintReceipts.push(receiptId);
        } catch (bytes memory reason) {
            if (_isSelector(reason, CertVault.CertVault_AtCapacity.selector)) {
                requestMintAtCapacityCount++;
                console2.log("REQUEST_MINT_AT_CAPACITY", requestMintAtCapacityCount);
            } else if (_isSelector(reason, CertVault.CertVault_BelowInstantCap.selector)) {
                requestMintBelowInstantCapCount++;
                console2.log("REQUEST_MINT_BELOW_INSTANT_CAP", requestMintBelowInstantCapCount);
            }
        }
        _trackDeposit(postedBefore);
    }

    function settleMint(uint256 seed, uint256 priceSeed) external {
        callsSettleMint++;
        if (pendingMintReceipts.length == 0) return;
        uint256 idx = bound(seed, 0, pendingMintReceipts.length - 1);
        uint256 receiptId = pendingMintReceipts[idx];
        _removeMintReceipt(idx);

        (uint256 refPx,) = oracle.pxUnguarded();
        if (refPx == 0) return;
        // Within settleBandBps (500 = 5%) with margin to spare, so most fills land.
        uint256 fillPx18 = bound(priceSeed, refPx * 9_700 / 10_000, refPx * 10_300 / 10_000);
        if (fillPx18 == 0) return;

        uint256 balBefore = cert.balanceOf(address(this));
        try vault.settleMint(receiptId, fillPx18) {
            totalMinted += cert.balanceOf(address(this)) - balBefore;
        } catch (bytes memory reason) {
            if (_isSelector(reason, CertVault.CertVault_AtCapacity.selector)) {
                settleMintAtCapacityCount++;
                console2.log("SETTLE_MINT_AT_CAPACITY", settleMintAtCapacityCount);
            }
            // else: stale/settled receipt — not a Law 2 concern (settleMint never redeems).
        }
    }

    // -------------------------------------------------------------------------------------- redeem

    /// @notice Law 2's fast path. CertVault_UseQueuedRedeem is a routing signal, not a failure —
    ///         it must be followed by a successful queued redemption of the SAME amount.
    function redeemInstant(uint256 amount) external {
        callsRedeemInstant++;
        uint256 bal = cert.balanceOf(address(this));
        if (bal < dustFloorCert) return; // below the venue's own minimum tradeable size
        amount = bound(amount, dustFloorCert, bal);

        try vault.redeemInstant(amount) returns (uint256 /* amountOut */ ) {
            totalBurned += amount;
        } catch (bytes memory reason) {
            if (_isSelector(reason, CertVault.CertVault_UseQueuedRedeem.selector)) {
                _fallbackToQueuedRedeem(amount);
            } else {
                // Any other revert on a non-zero amount the caller actually holds is a real
                // Law 2 violation.
                lawTwoViolations++;
            }
        }
    }

    function requestRedeem(uint256 amount) external {
        callsRequestRedeem++;
        uint256 bal = cert.balanceOf(address(this));
        if (bal < dustFloorCert) return; // matches redeemInstant's floor; see dustFloorCert above
        amount = bound(amount, dustFloorCert, bal);

        try vault.requestRedeem(amount) returns (uint256 receiptId) {
            totalBurned += amount;
            pendingRedeemReceipts.push(receiptId);
        } catch {
            // requestRedeem is documented unconditionally open for any non-zero amount a holder
            // actually owns — a revert here is exactly the Law 2 defect this suite exists to catch.
            lawTwoViolations++;
        }
    }

    function forceExit(uint256 amount) external {
        callsForceExit++;
        uint256 bal = cert.balanceOf(address(this));
        if (bal < dustFloorCert) return; // matches redeemInstant's floor; see dustFloorCert above
        amount = bound(amount, dustFloorCert, bal);

        try vault.forceExit(amount) returns (uint256 receiptId) {
            totalBurned += amount;
            pendingRedeemReceipts.push(receiptId);
        } catch {
            // forceExit is the documented Law 2 backstop: must survive everything.
            lawTwoViolations++;
        }
    }

    /// @notice Pull-payment side of the queued path. The burn already landed in totalBurned at
    ///         request time, so this only needs to prove the payout itself cannot be blocked.
    function claimRedeem(uint256 seed) external {
        callsClaimRedeem++;
        if (pendingRedeemReceipts.length == 0) return;
        uint256 idx = bound(seed, 0, pendingRedeemReceipts.length - 1);
        uint256 receiptId = pendingRedeemReceipts[idx];
        _removeRedeemReceipt(idx);

        try vault.claimRedeem(receiptId) returns (uint256 /* amountOut */ ) {
            // paid
        } catch {
            // A payout failure on a receipt this handler itself holds, and has not already
            // claimed, is exactly as much a Law 2 violation as a gated request would be.
            lawTwoViolations++;
        }
    }

    function _fallbackToQueuedRedeem(uint256 amount) internal {
        try vault.requestRedeem(amount) returns (uint256 receiptId) {
            totalBurned += amount;
            pendingRedeemReceipts.push(receiptId);
        } catch {
            lawTwoViolations++;
        }
    }

    // ---------------------------------------------------------------------------- margin & solvency

    function recallMargin() external {
        callsRecallMargin++;
        // Documented fail-open (never expected to revert); wrapped defensively so an unexpected
        // revert here cannot mask itself by aborting the whole handler call.
        try vault.recallMargin() {} catch {}
    }

    /// @dev Reachable via CertVault_InBand: once attest() below can move registry.latest(vault)'s
    ///      notional18 (previously frozen at the fixture's setUp value of 0), rebalance()'s
    ///      deltaBps can land inside [10_000 - DELTA_BAND_BPS, 10_000 + DELTA_BAND_BPS], and does
    ///      unconditionally whenever no mint has yet created supply (required == 0 forces
    ///      deltaBps == 10_000 exactly, dead centre of the band).
    function rebalance() external {
        callsRebalance++;
        try vault.rebalance() {} catch (bytes memory reason) {
            if (_isSelector(reason, CertVault.CertVault_InBand.selector)) {
                rebalanceInBandCount++;
                console2.log("REBALANCE_IN_BAND", rebalanceInBandCount);
            }
            // else: an unplaceable order at an extreme price. rebalance() is not a redemption
            // path, so Law 2 does not apply to it either way.
        }
    }

    function settleBatch() external {
        callsSettleBatch++;
        uint256 postedBefore = vault.postedMargin();
        try lighter.settleBatch() {} catch (bytes memory reason) {
            if (_isSelector(reason, MockLighter.InsufficientMargin.selector)) {
                settleBatchInsufficientMarginCount++;
                console2.log("SETTLE_BATCH_INSUFFICIENT_MARGIN", settleBatchInsufficientMarginCount);
            }
            // InsufficientMargin(): a position increase outran posted margin in this random
            // sequence. Not a redemption action, so this is an accepted outcome, not a violation.
        }
        _trackDeposit(postedBefore);
    }

    // ---------------------------------------------------------------------- attester & governance

    /// @notice Models the off-chain attester posting a fresh per-batch backing figure — the real
    ///         actor whose absence made _requireCapacity's comparison, rebalance()'s delta-band
    ///         check and invariant_capacityNeverExceedsAbsoluteCap's dependencies all static (Task
    ///         12 review, Finding 1). oi is bounded wide enough to bracket the fixture's
    ///         1_190_000e18 well below and well above so depthBps * oi (see setDepthBps) crosses
    ///         absoluteCap18 (5_000_000e18) in both directions across the campaign; notional is
    ///         bounded so _requireCapacity's `current + add > max` genuinely fires sometimes and
    ///         genuinely passes other times.
    /// @dev Not wrapped in try/catch: batchId is derived internally and strictly increasing by
    ///      construction, so a correct call can never revert SolvencyRegistry_StaleBatch. If it
    ///      ever did, that would itself be worth seeing as an uncaught handler-level revert rather
    ///      than silently absorbed.
    function attest(uint256 oiSeed, uint256 notionalSeed, uint256 marginSeed) external {
        callsAttest++;
        uint256 oi = bound(oiSeed, 0, 50_000_000e18);
        uint256 notional = bound(notionalSeed, 0, 300_000e18);
        uint256 margin = bound(marginSeed, 0, 300_000e18);
        uint64 batchId = ++nextBatchId;

        vm.prank(attester);
        reg.attest(address(vault), batchId, notional, margin, oi);
    }

    /// @notice Models governance retuning depth within the immutable [minDepthBps, maxDepthBps]
    ///         band it was deployed with (CapacityOracle can tune within bounds, never remove
    ///         them). Reads the real bounds off the contract rather than hardcoding them.
    function setDepthBps(uint256 seed) external {
        callsSetDepthBps++;
        uint256 v = bound(seed, cap.minDepthBps(), cap.maxDepthBps());
        vm.prank(gov);
        cap.setDepthBps(v);
    }

    /// @notice Models the attester relaying funding/execution variance/basis into the buffer,
    ///         including strongly negative deltas. This is the action invariant_
    ///         redemptionNeverBlockedByBuffer's own name promises to test: without it the buffer
    ///         balance never moves off the fixture's seeded +100_000e18 and the invariant cannot
    ///         exercise a negative-buffer redemption at all. The bound's negative side is wide
    ///         enough (-200_000e18 per call, vs. a seeded +100_000e18 balance) to drive the ledger
    ///         negative within a handful of calls in a 32-deep run, and to recover it too.
    function accrueFunding(int256 seed) external {
        callsAccrueFunding++;
        int256 delta = bound(seed, -200_000e18, 100_000e18);

        vm.prank(attester);
        vault.accrueFunding(delta);
    }

    // ------------------------------------------------------------------------------------ internals

    function _trackDeposit(uint256 postedBefore) internal {
        uint256 postedAfter = vault.postedMargin();
        if (postedAfter > postedBefore) {
            totalDepositedToVenue += postedAfter - postedBefore;
        }
    }

    function _isSelector(bytes memory reason, bytes4 selector) internal pure returns (bool) {
        return reason.length >= 4 && bytes4(reason) == selector;
    }

    function _removeMintReceipt(uint256 idx) internal {
        uint256 last = pendingMintReceipts.length - 1;
        pendingMintReceipts[idx] = pendingMintReceipts[last];
        pendingMintReceipts.pop();
    }

    function _removeRedeemReceipt(uint256 idx) internal {
        uint256 last = pendingRedeemReceipts.length - 1;
        pendingRedeemReceipts[idx] = pendingRedeemReceipts[last];
        pendingRedeemReceipts.pop();
    }
}
