// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ILighter} from "./interfaces/ILighter.sol";
import {ICertOracle} from "./interfaces/ICertOracle.sol";
import {ISolvencyRegistry} from "./interfaces/ISolvencyRegistry.sol";
import {ICapacityOracle} from "./interfaces/ICapacityOracle.sol";
import {Certificate} from "./Certificate.sol";
import {BufferBook} from "./BufferBook.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "openzeppelin-contracts/utils/math/SafeCast.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";

/// @notice One vault per asset. The vault IS a registered Lighter master account and submits its
///         own orders, deposits and withdrawals — there is no privileged trading key anywhere in
///         this contract (Law 6). Certificates are minted at oracle price at delta 1.0, never as
///         pro-rata account shares.
contract CertVault {
    using SafeERC20 for IERC20;

    error CertVault_NotBootstrapped();
    error CertVault_AlreadyBootstrapped();
    error CertVault_MintPaused();
    error CertVault_AtCapacity();
    error CertVault_AboveInstantCap();
    error CertVault_BelowInstantCap();
    error CertVault_BadReceipt();
    error CertVault_FillPriceOutOfBand();
    error CertVault_OnlyGovernance();
    error CertVault_NothingToClaim();
    error CertVault_TargetMarginOutOfBounds();
    /// @dev L-3 (LOW, external C1 audit): every one of these six addresses is immutable, so a
    ///      mistyped one is unrepairable and shows up later as an anonymous low-level failure at
    ///      whichever call site happens to touch it first — a zero `collateral` would have failed
    ///      on the decimals() read below, and a zero `lighter` only at bootstrap(). Named at
    ///      construction instead. Checked BEFORE targetMarginBps so the more basic error wins.
    error CertVault_ZeroAddress();
    /// @dev FINDING 1 follow-on: a deploy-config value that would let arithmetic on the Law 2 path
    ///      panic. See the constructor for which three and why each one matters.
    error CertVault_ConfigOutOfBounds();
    error CertVault_UseQueuedRedeem();
    /// @dev Finding 1 (Task 10 review): a zero amount at any mint/redeem entry point is worthless
    ///      to the caller but, left unguarded, reaches _hedge/_tryHedge as baseAmount == 0 —
    ///      Lighter's documented "close the entire position" primitive (see ILighter.sol). Reject
    ///      it here with a clear, dedicated error before it can ever reach that primitive.
    error CertVault_ZeroAmount();
    /// @dev Finding 1 (Task 10 review): _hedge must never silently submit baseAmount == 0 — that
    ///      is Lighter's close-all primitive, not a no-op. mintInstant/requestMint/rebalance() use
    ///      the revert-capable _hedge, so an amount that rounds to zero after size-decimals
    ///      conversion must revert instead of hedging nothing (an unhedged mint breaks Law 1).
    error CertVault_ZeroHedgeAmount();
    /// @dev C3: an unsettled mint receipt past its settleWindow. Not a dead end — refundMint()
    ///      is permissionless and returns the escrow, so the expiry is a fork, not a trap.
    error CertVault_SettleWindowExpired();
    /// @dev C3: stageRefund()/refundMint() before the window has expired. The holder's own route
    ///      is settleMint(), which is still open, so nothing is stuck behind this. Deliberately
    ///      reused by both refund phases rather than adding a second, synonymous
    ///      "window still active" error: this one already means exactly "too early", and two
    ///      errors for one condition would only force every caller to handle both.
    error CertVault_SettleWindowNotExpired();
    /// @dev M2: claimRedeem cannot pay right now. Deliberately reverts WITHOUT setting r.paid —
    ///      the receipt stays claimable forever, and recallMargin()/_sweepPending() are both
    ///      permissionless, so this is a retryable "not yet", never a gate.
    error CertVault_AwaitingSettlement();
    /// @dev refundMint cannot pay this escrow out of the vault's own balance yet. The mint-side
    ///      twin of CertVault_AwaitingSettlement, and a retryable "not yet" for the same reasons:
    ///      it reverts WITHOUT setting r.settled, so the receipt stays refundable forever, and
    ///      stageRefund() has ALREADY moved this escrow's posted share into marginPendingRecall,
    ///      so the two permissionless entry points recallMargin() (which submits the withdrawal
    ///      and, on a later call, sweeps it home) and seedBuffer() can each create the funding
    ///      condition. NOT _sweepPending(), which is internal and therefore not an escape route of
    ///      its own — only something that calls it is. Having a real escape is the whole point:
    ///      the previous shape of this function reallocated and paid atomically, so the
    ///      reallocation was rolled back by the very revert that made it necessary and no external
    ///      call could ever unstick the escrow. See stageRefund().
    error CertVault_RefundAwaitingSettlement();
    /// @dev refundMint before stageRefund. Escapable by anyone, immediately: stageRefund() is
    ///      permissionless, takes no funding, and cannot revert on it.
    error CertVault_RefundNotStaged();

    event Minted(address indexed user, uint256 amountIn, uint256 certOut, uint256 px18, uint256 fee);
    event MintRequested(uint256 indexed receiptId, address indexed user, uint256 amountIn);
    event MintSettled(uint256 indexed receiptId, uint256 certOut, uint256 fillPx18);
    /// @dev C3: the other side of the settle deadline — escrow returned, no certificates minted.
    event MintRefunded(uint256 indexed receiptId, address indexed user, uint256 amountOut);
    /// @dev Phase 1 of a refund. marginReallocated is what moved from postedMargin into
    ///      marginPendingRecall (so recallMargin() will ask the venue for it); hedgeClosePlaced
    ///      records whether the closing order was ACCEPTED FOR SUBMISSION — the same
    ///      submitted-versus-arrived distinction MarginRecallRequested/MarginRecalled draw below,
    ///      and for the same reason: createOrder only enqueues a priority request, so a true here
    ///      is not a fill. Emitted either way, since the close is fail-open and a close that did
    ///      not go in must never be silently lost.
    event RefundStaged(uint256 indexed receiptId, uint256 marginReallocated, bool hedgeClosePlaced);
    event MarginPosted(uint256 marginPosted, uint256 retainedAsHotBuffer);
    /// @dev Task 8d: margin backing an open position is locked by the venue's initial margin
    ///      requirement until the closing order fills, so submitting a withdrawal and the cash
    ///      actually arriving are two different events, fired from two different functions.
    ///      Requested fires from recallMargin() when a withdrawal is accepted for submission (no
    ///      guarantee cash moves — see fact 4 in the task brief); Recalled fires only once
    ///      getPendingBalance proves cash actually landed (_sweepPending).
    event MarginRecallRequested(uint256 amount);
    event MarginRecalled(uint256 amount, uint256 pendingAfter);
    /// @dev M-3: `side` is DERIVED from venuePositionBase rather than hardcoded, and
    ///      `knownPositionBase` publishes the ledger value the direction was taken from so a
    ///      reader can check the decision against the vault's own books.
    event ClosedAll(uint8 side, int256 knownPositionBase);
    /// @dev M-3: the vault's own order ledger says the position a close-all would meet is already
    ///      flat, so no directional order was submitted. The record of a deliberate refusal to
    ///      guess, not a silent no-op.
    event CloseAllSkippedFlat();

    struct Deps {
        address lighter;
        address oracle;
        address registry;
        address capacity;
        address governance;
    }

    struct VaultConfig {
        address collateral;
        uint16 collateralAssetIndex;
        uint8 routeType;
        uint16 marketIndex;
        uint8 sizeDecimals;
        uint256 mintFeeBps;
        uint256 redeemFeeBps;
        uint256 instantCap18;
        uint256 settleBandBps;
        uint256 targetMarginBps;
    }

    /// @dev C3: requestPx18 and requestedAt are the request's context, and settleMint is banded
    ///      against requestPx18 rather than the settle-time price. Without them a receipt could
    ///      sit indefinitely and then be settled against a price that had moved arbitrarily far
    ///      from the one the user actually requested at — measured at 4_999 bps on a week-old
    ///      receipt, which minted 280.7 certificates against a hedge covering 140.4.
    /// @dev refundStaged and indicativeCerts are the two-phase refund's state. refundStaged is
    ///      what makes stageRefund idempotent-once and what refundMint requires; indicativeCerts
    ///      is the certificate amount requestMint SUBMITTED a hedge order for — not a confirmed
    ///      fill, since orders fill asynchronously in a later batch and nothing here observes that.
    ///      Recorded so a refund can close that exposure rather than guessing it back out of price
    ///      at refund time (the price will have moved; the hedge was sized at the request price).
    ///      The gap between "submitted" and "held" is where stageRefund's open-loop close can
    ///      over-close — see the comment on that close.
    struct MintReceipt {
        address user;
        uint256 escrow;
        bool settled;
        uint256 requestPx18;
        uint64 requestedAt;
        bool refundStaged;
        uint256 indicativeCerts;
    }

    uint8 internal constant ORDER_TYPE_MARKET = 1;
    uint8 internal constant SIDE_BID = 0;
    uint8 internal constant SIDE_ASK = 1;

    uint256 internal constant MIN_TARGET_MARGIN_BPS = 5_000;
    uint256 internal constant MAX_TARGET_MARGIN_BPS = 10_000;

    /// @notice Ceiling on both `cfg.sizeDecimals` and the collateral token's own `decimals()`.
    /// @dev FINDING 1 follow-on. `10 ** cfg.sizeDecimals` is evaluated in _quantiseToVenue and in
    ///      _baseAmount (the latter outside every try/catch _tryHedge owns), and
    ///      `10 ** (decimals - 18)` in _to18/_from18. Both overflow and panic past 77 and 95. That
    ///      is NOT a Law 2 breach — the same panics hit the mint path, so such a vault can never
    ///      issue a certificate and has no holder to strand — it is a vault that deploys looking
    ///      alive and panics anonymously on every call. This bound turns that into a named error at
    ///      construction. Drawn at 18, well inside the panic, because a bound that only just holds
    ///      is not a bound; and at <= 18 _from18 divides rather than multiplies, so it cannot
    ///      overflow at all. See the constructor for the one config bound that IS a Law 2 fix.
    uint8 internal constant MAX_VENUE_DECIMALS = 18;

    /// @notice Ceiling on the price any `quantity x price` valuation in this contract will use, in
    ///         18 decimals. Published, immutable, and deliberately absurd: 1e36 is one million
    ///         million million dollars per certificate.
    /// @dev FINDING 1 (Law 2). `certIn * px18 / 1e18` in _queueExit panicked 0x11 at a live feed
    ///      price around 1e59, and _queueExit is forceExit's body — the last-resort backstop Law 2
    ///      says must always work for a holder with a balance. Every such product now goes through
    ///      _value18(), which is a TOTAL function: it cannot revert for any pair of uint256 inputs.
    ///
    ///      Math.mulDiv ALONE DOES NOT CLOSE THIS, which is the part worth recording rather than
    ///      assuming. Its 512-bit intermediate moves the failure from "the product exceeds uint256"
    ///      to "the QUOTIENT exceeds uint256", i.e. from `certIn * px18 >= 2^256` (~1.16e77) to
    ///      `certIn * px18 >= 1e18 * 2^256` (~1.16e95). That is 18 decades of headroom, and it
    ///      would be enough if the price were bounded — but it is not. pxUnguarded() reads
    ///      CertOracle, whose own normalisation guard admits any answer that fits a uint256 once
    ///      scaled, so px18 can legitimately be as large as ~1.157e77 (an 8-decimal feed reporting
    ///      1.157e67, which is inside int256). At that price mulDiv's quotient overflows for
    ///      certIn >= ~1.003e18 — just over ONE certificate. So the "unreachable for realistic
    ///      supply" argument is false as soon as the feed is hostile or broken, and mulDiv on its
    ///      own would have left forceExit panicking for any holder of two certificates.
    ///
    ///      Hence both: mulDiv for the exact 512-bit intermediate, and this clamp to bound the
    ///      factor mulDiv cannot bound for itself.
    ///
    ///      THE CLAMP IS ECONOMICALLY INERT, and that is why it is acceptable rather than a
    ///      trade-off. Four reasons, in order of strength:
    ///        1. No order can be placed at a price above ~4.3e25 anyway (CertOracle.toTickPrice
    ///           reverts once px18 * 10**priceDecimals / 1e18 leaves the uint32 tick domain — for
    ///           priceDecimals = 2 that is 4.295e25). This ceiling sits ten decades ABOVE the
    ///           highest price the venue itself can represent, so it can only ever engage on a
    ///           price the protocol demonstrably cannot transact at.
    ///        2. No certificate was ever minted at such a price either, for the same reason: both
    ///           mint paths route through the revert-capable _hedge, which calls toTickPrice.
    ///        3. On the queued path owed18 is a CEILING on the payout, not the payout (H-2):
    ///           claimRedeem pays min(owed18, certIn * px_now / 1e18). Clamping a ceiling that was
    ///           already orders of magnitude beyond anything the vault holds changes no payout that
    ///           can actually be funded — at any normal claim-time price the binding term is the
    ///           current value, not the ceiling.
    ///        4. redeemInstant refuses when hotBuffer() < amountOut, so an inflated valuation there
    ///           routes to the queued path instead of paying anything.
    ///      The one state where the clamp changes a number a holder receives is: exit above 1e36,
    ///      claim while still above 1e36, and the vault holding collateral sized to a 1e36 price.
    ///      That collateral does not exist.
    uint256 public constant MAX_VALUATION_PX18 = 1e36;

    /// @notice Ceiling on the quantity side of the same valuation, in 18 decimals.
    /// @dev FINDING 1, belt and braces. With px18 clamped above, Math.mulDiv's own 512-bit guard
    ///      can still trip on a large enough quantity: it panics once `qty18 * px18 >= 1e18 * 2^256`,
    ///      which at px18 = MAX_VALUATION_PX18 needs qty18 >= 2^256 / 1e18, i.e. ~1.16e41
    ///      certificates. This constant is exactly that boundary, expressed so the pair is provably
    ///      safe: qty18 <= type(uint256).max / 1e18 and px18 <= 1e36 give a product of at most
    ///      (2^256 - 1) * 1e18, which is strictly below the 1e18 * 2^256 at which mulDiv panics.
    ///      _value18 is therefore total for EVERY uint256 pair, with no reachability argument
    ///      required — which is the property Law 2 actually needs, since a Law 2 path must not
    ///      depend on a supply bound the contract does not enforce.
    ///      1.16e41 certificates is unreachable in any case: a mint's certOut is floored at
    ///      net18 * 1e18 / px18 with px18 >= 1e16 (toTickPrice's lower tick bound at
    ///      priceDecimals = 2), so it is bounded by 100 * net18, and net18 is bounded by the
    ///      collateral token's own supply and by CapacityOracle's immutable maxAbsoluteCap.
    uint256 public constant MAX_VALUATION_QTY18 = type(uint256).max / (MAX_VALUATION_PX18 / 1e18);

    ILighter public immutable lighter;
    ICertOracle public immutable oracle;
    ISolvencyRegistry public immutable registry;
    ICapacityOracle public immutable capacity;
    address public immutable governance;
    Certificate public immutable certificate;
    BufferBook public immutable buffer;

    VaultConfig public cfg;
    uint8 private immutable _collateralDecimals;

    bool public bootstrapped;
    uint256 private _nextReceiptId = 1;
    mapping(uint256 => MintReceipt) public mintReceipts;

    /// @notice Collateral posted to Lighter as margin, less what has been requested back.
    /// @dev A sizing counter for withdrawals only. It deliberately does NOT track funding, PnL or
    ///      liquidation — the authoritative backing figure is SolvencyRegistry's per-batch
    ///      attestation. Do not use this for solvency.
    uint256 public postedMargin;

    /// @notice Margin allocated to exits (via _queueExit's pro-rata decrement of postedMargin)
    ///         that has not yet been confirmed to have arrived back at the vault.
    /// @dev Two-phase by necessity (Task 8d): margin backing an open position is locked by the
    ///      venue's initial margin requirement and cannot be withdrawn until the closing order
    ///      fills. Increased only in _queueExit (allocation); decreased only in _sweepPending, and
    ///      only by what getPendingBalance proves actually arrived — never on withdrawal
    ///      submission, since the venue performs no balance check and a request can be silently
    ///      refused inside the rollup with no on-chain signal (see recallMargin()).
    uint256 public marginPendingRecall;

    /// @notice Certificates promised to mint receipts that have neither settled nor been staged
    ///         for refund — exposure the vault has already hedged and escrowed for, but which does
    ///         not yet show up in certificate.totalSupply().
    /// @dev C-2 (CRITICAL, external C1 audit). _requireCapacity measured "current" as the last
    ///      ATTESTED notional, which does not move between batches (up to maxAttestationAgeSec,
    ///      300s in the fixture), so every mint inside that window measured against the same
    ///      untouched headroom: maxNotional bounded ONE call and nothing bounded the sum. Measured:
    ///      20 sequential mintInstant calls in a single block minted $199,800 against a $119,000
    ///      cap — 1.68x, limited only by the caller's wallet.
    ///
    ///      This is the same defect, and the same argument, as C2 on rebalance() — whose own
    ///      NatSpec already says "the per-call notional bound alone was decorative, because the
    ///      attestation rebalance() reads does not move between calls". That one was fixed with
    ///      lastRebalancedBatch; the argument was simply never applied to the mint path.
    ///
    ///      Admission control now measures the vault's OWN obligation, which moves with every
    ///      mint and every burn: certificate.totalSupply() covers the instant path and every
    ///      settled receipt, and this counter covers the gap the queued path opens between
    ///      requestMint (escrow taken, hedge submitted, no certificates yet) and settleMint.
    ///      Without it a run of requestMint calls would reproduce C-2 exactly, since totalSupply
    ///      does not move at requestMint either. Increased in requestMint; released in settleMint
    ///      (where supply takes over the same quantity, so total exposure is continuous) or in
    ///      stageRefund (where the promise is abandoned) — never both, since settleMint requires
    ///      !settled and stageRefund requires !settled && !refundStaged.
    ///
    ///      A receipt whose window expired and which nobody has staged keeps its reservation. That
    ///      is the conservative direction (it can only refuse new mints, never admit them) and
    ///      stageRefund is permissionless, so anyone can free it. It is not a Law 2 concern:
    ///      capacity gates minting only, and no redemption path reads this counter.
    uint256 public pendingMintCerts;

    /// @notice Total collateral owed to queued redemption receipts that have not yet been paid.
    /// @dev C1 (final review wave): the number recallMargin() sizes its REQUEST off. It is
    ///      deliberately not the same quantity as marginPendingRecall: that one is the pro-rata
    ///      share of the deposited cost basis, which is the right allocation ledger BETWEEN
    ///      HOLDERS (it keeps them fair to each other and can never exceed what was posted), but
    ///      it is the wrong size for the request, because what a receipt owes grows with price
    ///      while basis does not. Increased in _queueExit, decreased in claimRedeem. In collateral
    ///      units, floored on subtraction — an over-large sweep must never underflow it.
    uint256 public totalOwedOutstanding;

    /// @notice Margin whose position has already been closed by an INSTANT redemption, and which
    ///         therefore no receipt will ever allocate. The sizing term recallMargin() uses to
    ///         bring it home.
    /// @dev M-4 (external C1 audit). redeemInstant closed the hedge but touched neither
    ///      marginPendingRecall nor totalOwedOutstanding, and recallMargin() sizes its request off
    ///      exactly those two — so with both at zero it asked the venue for nothing. Measured:
    ///      after a mint, an instant redeem and the float being spent, $8,992.00 sat at the venue
    ///      against zero outstanding supply while recallMargin() was a no-op and the hot buffer
    ///      stayed at $0.00. Not a Law 2 breach (the queued path still works and repairs the
    ///      counters) but instant redemption stayed dead until somebody queued an exit, and the
    ///      capital backed nothing in the meantime.
    ///
    ///      Deliberately a THIRD counter rather than a reuse of marginPendingRecall, which is what
    ///      _queueExit increments. Those two mean different things and must not be conflated:
    ///      marginPendingRecall is margin allocated to a receipt that is not yet paid — a claim
    ///      one specific holder has on it — and recallMargin()'s two-phase contract ("submission
    ///      is not arrival", proven by test_recallMarginSubmitsAndSweeps) is about that claim.
    ///      This counter is margin nobody has a claim on at all: the exit that freed it was paid
    ///      in full, in the same transaction, out of the float. So it needs no two-phase
    ///      distinction, and recallMargin() may request AND collect it in one call.
    ///
    ///      Increased in redeemInstant, as a TRANSFER out of postedMargin (so the counter sum
    ///      invariant_marginNeverExceedsDeposited checks is unchanged by the move); decreased only
    ///      in _sweepPending, and only by cash that actually arrived and that no receipt
    ///      allocation had already claimed.
    uint256 public marginExcess;

    /// @notice The venue's per-asset withdrawal ceiling (AssetConfig.depositCapTicks upstream).
    /// @dev C1: recallMargin() now deliberately over-requests when a receipt owes more than the
    ///      basis behind it. Over-requesting is safe — the venue fulfils min(request, available)
    ///      and refuses insufficiency silently inside the rollup — but a request above the
    ///      venue's own per-asset cap reverts on-chain, so clamp to it rather than relying on
    ///      recallMargin's fail-open catch to absorb a request we could have sized correctly.
    ///      DEPLOYMENT NOTE: set this at or below type(uint64).max. recallMargin clamps to it
    ///      before SafeCast.toUint64, so a value within uint64 makes that cast unreachable; a
    ///      larger value leaves the (retryable, non-redemption-path) cast revert reachable once
    ///      totalOwedOutstanding passes ~1.8e19 collateral units.
    uint256 public immutable venueWithdrawCap;

    /// @notice The vault's own signed record of the base it has asked the venue to hold, in the
    ///         venue's base ticks (sizeDecimals applied). Negative is short.
    /// @dev M-3 (MEDIUM, external C1 audit). closeAll() hardcoded SIDE_ASK, and `baseAmount == 0`
    ///      defaults to the full position SIZE, not to "go flat" — so against a SHORT the
    ///      governance wind-down of last resort DOUBLED the short. The vault can genuinely be
    ///      short: stageRefund's close is open-loop and its own comment says so.
    ///
    ///      ILighter exposes no position getter — the chain sees roots and blobs, not in-rollup
    ///      state (spec section 3.1) — so the vault cannot read its own venue position and the side
    ///      has to come from a local source of truth. This is that source, in the same shape as
    ///      postedMargin and marginPendingRecall, which are local ledgers for exactly this reason.
    ///
    ///      WHAT IT IS, PRECISELY: the net of every order this contract has SUBMITTED, not of every
    ///      order that has FILLED. Those differ, and the difference is not a defect here — it is
    ///      what makes the counter the right predictor. Priority requests execute in queue order,
    ///      so an order enqueued now acts on the position left by everything enqueued before it; a
    ///      close-all submitted at this instant will therefore meet exactly this counter's value,
    ///      even while the venue's current position still lags a batch behind it.
    ///
    ///      WHERE IT CAN STILL BE WRONG, stated rather than implied. Four things move the venue's
    ///      position without moving this counter, and each can flip its SIGN, which is the only
    ///      part closeAll() uses:
    ///        1. an order accepted on L1 but refused inside the rollup (no on-chain signal — the
    ///           same blindness that makes recallMargin() fail-open);
    ///        2. a partial fill, since the on-chain path has no IOC or reduce-only flag (spec
    ///           section 3.2) and a market order into a thin book can fill short of its size;
    ///        3. liquidation, which flattens the venue position with nothing for the vault to see;
    ///        4. desert mode / escape-hatch settlement.
    ///      So this is a strict improvement on assuming long, not a proof. Under truthful,
    ///      fully-filled execution it equals the venue position exactly; under the four above it
    ///      degrades to the same guess closeAll() made unconditionally before. That is the honest
    ///      C1 answer, and the real fix is an ILighter position getter or a SIGNED attestation —
    ///      both interface changes outside this contract.
    ///
    ///      Deliberately NOT wired into stageRefund's open-loop close or rebalance()'s sign-blind
    ///      trim. Both would be behaviour changes on paths this finding is not about, and
    ///      test_zeroSupplyTrimCannotCloseADanglingShort exists to keep those two gaps visible.
    int256 public venuePositionBase;

    /// @notice How long a mint receipt stays settleable before it can only be refunded.
    /// @dev C3: settleMint bands against the price recorded at requestMint, so a receipt must not
    ///      be allowed to sit indefinitely and be settled against a price that has moved
    ///      arbitrarily far from the one the user requested at.
    uint256 public immutable settleWindow;

    constructor(
        Deps memory d,
        VaultConfig memory c,
        uint256 venueWithdrawCap_,
        uint256 settleWindow_,
        string memory name_,
        string memory symbol_
    ) {
        // L-3: named at construction, before anything else runs.
        if (
            d.lighter == address(0) || d.oracle == address(0) || d.registry == address(0)
                || d.capacity == address(0) || d.governance == address(0) || c.collateral == address(0)
        ) revert CertVault_ZeroAddress();

        lighter = ILighter(d.lighter);
        oracle = ICertOracle(d.oracle);
        registry = ISolvencyRegistry(d.registry);
        capacity = ICapacityOracle(d.capacity);
        governance = d.governance;
        venueWithdrawCap = venueWithdrawCap_;
        settleWindow = settleWindow_;
        cfg = c;
        if (c.targetMarginBps < MIN_TARGET_MARGIN_BPS || c.targetMarginBps > MAX_TARGET_MARGIN_BPS) {
            revert CertVault_TargetMarginOutOfBounds();
        }
        // FINDING 1, from re-tracing forceExit end to end AFTER the valuation fix. Three pieces of
        // deploy config decided whether arithmetic on the redemption path could panic, and none was
        // bounded. They are NOT equally severe and are deliberately not described as though they
        // were — one is a reachable Law 2 breach and two are robustness:
        //
        //  - redeemFeeBps > 10_000 IS A REACHABLE LAW 2 BREACH, and it was measured. `gross18 -
        //    fee18` underflows in both redeemInstant and _queueExit, while minting is entirely
        //    unaffected (it reads mintFeeBps) — so a vault deployed this way mints happily, issues
        //    real certificates to real holders, and then panics 0x11 inside forceExit for every one
        //    of them, with no permissionless way out and no setter to repair it. Measured on a
        //    fixture vault at redeemFeeBps = 10_001: the holder minted 9.9945 certificates and
        //    forceExit reverted with panic 0x11. A fee above 100% is not a fee.
        //  - mintFeeBps > 10_000 underflows `received - fee` in both mint paths. Bounded by the
        //    same line, but it is the harmless direction: it kills minting, so no holder ever
        //    exists to be stranded.
        //  - sizeDecimals and the collateral's own decimals are ROBUSTNESS, not Law 2. Past 77 and
        //    95 respectively, `10 ** cfg.sizeDecimals` (in _quantiseToVenue and _baseAmount) and
        //    `10 ** (decimals - 18)` (in _to18/_from18) overflow and panic — but they panic on the
        //    MINT path too, so such a vault can never issue a certificate and cannot strand a
        //    holder. What the bounds buy is a named error at construction instead of a deployed
        //    contract that looks alive and panics anonymously on every call. Drawn at 18 rather
        //    than at the panic itself, because a bound that only just holds is not a bound: 18 is
        //    above any real venue size_decimals and above every realistic collateral (USDG, USDC,
        //    USDT and DAI are 6 or 18), and at <= 18 _from18 is division-only and so cannot
        //    overflow at all.
        if (c.sizeDecimals > MAX_VENUE_DECIMALS) revert CertVault_ConfigOutOfBounds();
        if (c.mintFeeBps > 10_000 || c.redeemFeeBps > 10_000) revert CertVault_ConfigOutOfBounds();

        uint8 collateralDecimals = IERC20Metadata(c.collateral).decimals();
        if (collateralDecimals > MAX_VENUE_DECIMALS) revert CertVault_ConfigOutOfBounds();
        _collateralDecimals = collateralDecimals;

        certificate = new Certificate(name_, symbol_, address(this));
        buffer = new BufferBook(address(this), 200);
        // M-2: DEFAULTS, not the only possible values — retunable per asset through
        // setBufferThresholds() above. They stay literals here because a fresh vault has no
        // attestation to size them off yet, and because passing them through the constructor would
        // widen CertVault's deployment signature (and CertFactory's, and every fixture's) for four
        // numbers that gate nothing.
        buffer.configure(address(this), 100_000e18, 60_000e18, 30_000e18, 0);
    }

    // ---------------------------------------------------------------- bootstrap

    /// @notice One-time dust deposit so Lighter assigns this contract an account index.
    /// @dev createOrder reverts with AccountIsNotRegistered until the registering deposit has
    ///      been executed by a batch, so this must land before any mint. The vault must already
    ///      hold at least `dust` of collateral (e.g. via seedBuffer) before this is called.
    function bootstrap() external {
        if (bootstrapped) revert CertVault_AlreadyBootstrapped();
        bootstrapped = true;
        uint256 dust = 10 ** _collateralDecimals;
        IERC20(cfg.collateral).forceApprove(address(lighter), dust);
        lighter.deposit(address(this), cfg.collateralAssetIndex, cfg.routeType, dust);
        postedMargin += dust;
    }

    function lighterAccountIndex() public view returns (uint48) {
        return lighter.addressToAccountIndex(address(this));
    }

    /// @notice The vault's own collateral balance — the float that serves instant redemptions.
    function hotBuffer() public view returns (uint256) {
        return IERC20(cfg.collateral).balanceOf(address(this));
    }

    /// @notice The 1% adverse move on the whole book that one unit of the vault's own capital is
    ///         held against, expressed as the multiple that turns capital into supportable
    ///         notional. Published, and a constant rather than a settable parameter.
    /// @dev M-1: the same multiplier BufferBook.capacity18 has always documented and applied
    ///      ("capacity = balance * 100"), lifted here unchanged because the fix changes WHAT is
    ///      multiplied, not the risk statement. Changing both at once would have made every
    ///      capacity figure in the suite move for two reasons at once.
    uint256 public constant BUFFER_COVERAGE_MULTIPLE = 100;

    /// @notice The vault's own loss-absorbing float: collateral it actually holds that is not
    ///         already owed to a queued redemption receipt, in 18 decimals.
    /// @dev M-1: ground truth, and that is the whole point of it. hotBuffer() is an ERC20
    ///      balanceOf and totalOwedOutstanding is this contract's own obligation counter, so
    ///      nothing an attester writes can move this number — unlike BufferBook's ledger, which
    ///      accrueFunding() can set to anything (measured: a published buffer of 500,100,000.01
    ///      against 91,028.00 actually held). It also cannot DRIFT from reality the way the ledger
    ///      does, because it is not a counter that has to be kept in step with the balance: it is
    ///      derived from the balance on every read, so mint fees arriving and instant redemptions
    ///      draining are reflected the instant they happen, with nothing to reconcile.
    ///
    ///      Netted against what is owed because float earmarked for a receipt nobody has claimed
    ///      yet is not loss-absorbing capital. Floored at zero rather than signed: "owes more than
    ///      it holds" is not negative capacity, it is no capacity.
    ///
    ///      RESIDUAL, stated rather than hidden: escrow held for mint receipts that have neither
    ///      settled nor been refunded is NOT netted out (there is no counter for it and adding one
    ///      is more surface than this finding warrants), so during a settle window this reads high
    ///      by up to that escrow. It is bounded by settleWindow, and it is the harmless direction:
    ///      the same escrow is at the venue backing that receipt's own hedge, so it is not capital
    ///      standing behind nothing.
    function freeCollateral18() public view returns (uint256) {
        uint256 have = hotBuffer();
        uint256 owed = totalOwedOutstanding;
        return have > owed ? _to18(have - owed) : 0;
    }

    /// @notice The third leg of CapacityOracle's min() — what the vault's own capital can absorb.
    /// @dev M-1 (MEDIUM, external C1 audit). This leg used to be BufferBook.capacity18() handed
    ///      over raw, which put an unbacked, attester-written number into admission control in the
    ///      direction that WIDENS it: two of the three legs of
    ///      min(depthBps * OI, absoluteCap, bufferCapacity) were attester-written and only the
    ///      immutable absoluteCap was a real bound. The audit's direction 2 was taken — the
    ///      accrual ledger is published as cumulative P&L and is no longer the source of this
    ///      bound — and the replacement is deliberately not "nothing":
    ///
    ///        min( freeCollateral18() * BUFFER_COVERAGE_MULTIPLE , BufferBook.capacity18() )
    ///
    ///      The first term is what actually bounds how much exposure the vault's own capital can
    ///      support: collateral it really holds, at the same 1%-adverse-move coverage the ledger
    ///      leg always claimed to express. The second term is KEPT, and keeping it is not a
    ///      relapse — under a `min` an attester-written figure can only ever make the vault MORE
    ///      conservative. It can no longer admit a mint that real collateral does not support,
    ///      which is the harm; it can still shut new minting, which is a lever the attester
    ///      already holds anyway (a stale attestation yields zero capacity by CapacityOracle's own
    ///      early return) and which is the honest half of the old behaviour: an exhausted ledger
    ///      stops new minting. Redemption is untouched by both terms — no redemption path calls
    ///      this function or reads either input for a gate (Law 2).
    ///
    ///      The first term saturates instead of panicking, because it is the term this contract
    ///      controls and a bound that reverts is not a bound. The second is left able to panic on
    ///      the overflow an attester can force into it: that behaviour is pinned by
    ///      test_ATK_attesterCanBrickMintingViaBufferOverflow, which uses it to prove redemption
    ///      survives a bricked buffer, and it fails in the safe direction (minting shut, exits
    ///      open).
    function bufferCapacity18() public view returns (uint256) {
        uint256 own = freeCollateral18();
        uint256 ceiling = type(uint256).max / BUFFER_COVERAGE_MULTIPLE;
        own = own > ceiling ? type(uint256).max : own * BUFFER_COVERAGE_MULTIPLE;
        uint256 claimed = buffer.capacity18(address(this));
        return own < claimed ? own : claimed;
    }

    /// @notice Retune the published buffer threshold ladder for this vault's asset.
    /// @dev M-2 (MEDIUM, external C1 audit): the four thresholds were hardcoded literals in the
    ///      constructor below (100k / 60k / 30k / 0) for every asset regardless of size, with no
    ///      way to reconfigure — meaningless against a $1.19M book and wrong for one ten times
    ///      larger. They are configuration now, per asset (one vault is one asset), bounded by
    ///      BufferBook's own ordering check.
    ///
    ///      Law 6 is not weakened by this and it is worth being exact about why, rather than
    ///      resting on "governance already exists". These four numbers gate NOTHING: they feed
    ///      holdingFeeBps() and mintSlowed(), which C1 charges and applies nowhere, and the
    ///      threshold level in an event. The one mechanical consequence buffer health still has —
    ///      an exhausted ledger tightening bufferCapacity18() above — is anchored at zero, which
    ///      is not one of these four numbers. So this cannot pause minting, cannot touch any
    ///      redemption path (none of them reads BufferBook at all, Law 2), and cannot move
    ///      collateral. It is the same shape as CapacityOracle.setDepthBps: a published parameter
    ///      inside published bounds.
    function setBufferThresholds(uint256 floor18, uint256 feeOn18, uint256 mintSlow18, uint256 insuranceDraw18)
        external
    {
        if (msg.sender != governance) revert CertVault_OnlyGovernance();
        buffer.configure(address(this), floor18, feeOn18, mintSlow18, insuranceDraw18);
    }

    /// @notice Pre-fund the buffer. Permissionless: it can only ever add value to the vault.
    function seedBuffer(uint256 amount) external {
        IERC20(cfg.collateral).safeTransferFrom(msg.sender, address(this), amount);
        buffer.accrue(address(this), int256(_to18(amount)));
    }

    // ---------------------------------------------------------------- mint

    /// @dev L-8: every figure below is derived from `received` — what the collateral transfer
    ///      actually delivered — and not from `amountIn`, what the caller asked to send. See
    ///      _pullCollateral. The pull therefore happens BEFORE the fee, the certificate amount,
    ///      the instant cap and the capacity check, which is a strict improvement on its own:
    ///      _requireCapacity now runs after any callback collateral has had its chance to
    ///      re-enter, so the outer mint's admission check sees the inner mint's supply instead of
    ///      measuring headroom that a nested call was about to consume.
    function mintInstant(uint256 amountIn) external returns (uint256 certOut) {
        if (amountIn == 0) revert CertVault_ZeroAmount();
        if (!bootstrapped) revert CertVault_NotBootstrapped();
        if (!oracle.mintAllowed()) revert CertVault_MintPaused();

        uint256 px18 = oracle.px();
        uint256 received = _pullCollateral(amountIn);
        uint256 fee = received * cfg.mintFeeBps / 10_000;
        uint256 net18 = _to18(received - fee);
        // L-9: quantised to the venue's own representable size, so the certificates minted and
        // the base amount hedged are THE SAME NUMBER rather than merely ordered. This is C-1's
        // fix applied to the path C-1 did not touch: requestMint has quantised before recording
        // and hedging since C-1, which is why the queued path never had this defect, and
        // mintInstant is where it remained.
        //
        // The audit recommended rounding the HEDGE up instead. Quantising the MINT down is
        // strictly stronger and was chosen for that reason: rounding up leaves the vault
        // over-hedged by up to one tick on every mint — unbacked exposure pointing the other way,
        // needing margin the escrow did not provide — whereas quantising leaves nothing to round.
        // Measured on the attack battery's 25 small mints: 7.088392 certificates against
        // 7.087500 hedged before, exactly equal after.
        certOut = _quantiseToVenue(net18 * 1e18 / px18);

        // FINDING 1: routed through _value18 like every other quantity-times-price product in this
        // file, so no reader has to reconstruct a per-site boundedness argument. This one IS
        // structurally bounded — certOut is floored from net18 * 1e18 / px18, so certOut * px18
        // cannot exceed net18 * 1e18 — but "bounded because of what the previous line did" is
        // exactly the reasoning that left _queueExit panicking, so it is not relied on.
        uint256 notional18 = _value18(certOut, px18);
        if (notional18 > cfg.instantCap18) revert CertVault_AboveInstantCap();
        _requireCapacity(notional18, px18);

        certificate.mint(msg.sender, certOut);
        _postMargin(received - fee);
        // Unchanged in effect, kept explicit: a mint too small to express as one venue tick now
        // quantises certOut to 0 and must revert rather than mint an unhedgeable certificate
        // (test_ATK_dustMintCannotCreateUnhedgedSupply). _hedge's own guard would catch it too;
        // this one names the condition at the point the amount is decided.
        if (certOut == 0) revert CertVault_ZeroHedgeAmount();
        _hedge(certOut, px18, SIDE_BID);

        // The escrow now buys a quantised number of certificates, so a remainder is left over:
        // floor-division and size-decimals dust, at most one venue tick of notional ($0.036 at
        // PX = 355.86 and sizeDecimals = 4). Published into BufferBook rather than retained
        // silently — the same reconciliation, and the same argument, as settleMint's (see there):
        // retained silently it would be value with no owner and no published record, and paying
        // it back would need a transfer out of a buffer that has just been partly posted as
        // margin. Non-negative by construction: certOut is floored from net18 / px18, so its cost
        // cannot exceed net18.
        uint256 hedgeCost18 = _value18(certOut, px18);
        if (net18 > hedgeCost18) buffer.accrue(address(this), SafeCast.toInt256(net18 - hedgeCost18));

        emit Minted(msg.sender, received, certOut, px18, fee);
    }

    function requestMint(uint256 amountIn) external returns (uint256 receiptId) {
        if (amountIn == 0) revert CertVault_ZeroAmount();
        if (!bootstrapped) revert CertVault_NotBootstrapped();
        if (!oracle.mintAllowed()) revert CertVault_MintPaused();

        uint256 px18 = oracle.px();
        // L-8: as in mintInstant, everything below is sized off what arrived, not off what was
        // asked for. The escrow recorded on the receipt is therefore collateral the vault really
        // holds, which is what refundMint has to be able to hand back.
        uint256 received = _pullCollateral(amountIn);
        uint256 fee = received * cfg.mintFeeBps / 10_000;
        uint256 net18 = _to18(received - fee);
        // C-1: floored to the venue's own representable size BEFORE it is recorded or hedged, so
        // r.indicativeCerts is exactly the exposure the order below asks for rather than a figure
        // the venue cannot hold. settleMint mints this number and nothing else, so a certificate
        // that the hedge cannot cover is not merely discouraged, it is unrepresentable. The
        // remainder is escrow with no certificate against it and is reconciled in settleMint.
        uint256 indicative = _quantiseToVenue(net18 * 1e18 / px18);
        uint256 notional18 = _value18(indicative, px18);
        if (notional18 <= cfg.instantCap18) revert CertVault_BelowInstantCap();
        _requireCapacity(notional18, px18);

        receiptId = _nextReceiptId++;
        mintReceipts[receiptId] = MintReceipt({
            user: msg.sender,
            escrow: received - fee,
            settled: false,
            requestPx18: px18,
            requestedAt: uint64(block.timestamp),
            refundStaged: false,
            // Step 1 of the refund fix: record what the _hedge below is about to submit an order
            // for, so stageRefund can close that exposure. Without it a refund left the vault long
            // against certificates that were never minted (measured: totalSupply 0 against a
            // 1,403,641-tick position on a 50k mint), breaching Law 1 with NO permissionless way
            // back — rebalance() could not trim it, because _solvency reported deltaBps == 10_000
            // at zero supply and rebalance() therefore reverted CertVault_InBand. That second
            // half is CRITICAL A and is now fixed: see DELTA_UNBOUNDED_BPS. Both halves matter,
            // so neither this record nor indicativeCerts is redundant.
            indicativeCerts: indicative
        });

        // C-2: reserve this receipt's exposure against the cap for as long as the promise stands.
        // totalSupply does not move at requestMint, so without this a run of requestMint calls in
        // one attestation window would re-observe the same headroom exactly as the instant path
        // did. Released in settleMint or stageRefund; see pendingMintCerts.
        pendingMintCerts += indicative;

        _postMargin(received - fee);
        _hedge(indicative, px18, SIDE_BID);
        emit MintRequested(receiptId, msg.sender, received);
    }

    /// @notice Pull collateral in and report what actually landed.
    /// @dev L-8 (external C1 audit). Both mint paths minted against `amountIn` — the number the
    ///      caller passed — rather than against what `safeTransferFrom` delivered. With
    ///      fee-on-transfer or rebasing collateral the difference is minted out of thin air:
    ///      measured at 0.9% per deposit on a 1%-fee token, $10,000 sent, $9,900 received,
    ///      $9,989.99 of certificates issued. USDG is not fee-on-transfer and USDT ships its fee
    ///      switch disabled, so this is a deployment-error class rather than a live exploit — and
    ///      it is two lines to remove entirely.
    ///
    ///      The `min` against amountIn is the second half of the fix and is not decoration. A
    ///      balance delta measures everything that happened to the vault's balance across the
    ///      transfer, including anything a CALLBACK token did from inside it: with ERC777-style
    ///      collateral, a nested mint's own deposit lands inside the outer call's window and
    ///      would otherwise be credited twice — once to the nested mint and again to the outer
    ///      one. Capping at amountIn makes that impossible, because no mint can ever be credited
    ///      more than its own caller authorised. RESIDUAL, stated rather than hidden: collateral
    ///      that is BOTH fee-on-transfer AND reentrant can still push the delta above amountIn
    ///      while delivering less than it, in which case the cap credits amountIn and the fee is
    ///      over-minted after all. Closing that needs a reentrancy guard on the mint paths, which
    ///      is a wider change than this finding, and the token it needs is doubly disqualified
    ///      from ever being configured as collateral.
    function _pullCollateral(uint256 amountIn) internal returns (uint256 received) {
        IERC20 collateral = IERC20(cfg.collateral);
        uint256 balBefore = collateral.balanceOf(address(this));
        collateral.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 balAfter = collateral.balanceOf(address(this));
        // Floored, not checked-subtracted: a token whose transfer LOWERS the recipient's balance
        // (a negative rebase mid-transfer, a fee taken from the destination) must produce a named
        // error, not an anonymous underflow panic, in a permissionless entry point.
        uint256 delta = balAfter > balBefore ? balAfter - balBefore : 0;
        received = delta < amountIn ? delta : amountIn;
        if (received == 0) revert CertVault_ZeroAmount();
    }

    /// @notice Mint exactly the certificates requestMint hedged, and reconcile whatever escrow is
    ///         left over. Permissionless, and the amount minted is fixed before this call exists.
    /// @dev C-1 (CRITICAL, external C1 audit). This function used to mint `escrow / fillPx18` from
    ///      a fill price the CALLER supplied, bounded only by a settleBandBps band against
    ///      requestPx18. It is permissionless, so whoever called first chose the price, and the
    ///      hedge had already been sized at requestPx18 — the two numbers had no reason to agree.
    ///      Its old NatSpec claimed "the fill price is checkable against the attestation"; nothing
    ///      checked it, and nothing could: this function takes no attestation, batch id or proof,
    ///      and SolvencyRegistry has no per-receipt fill to check against. Measured on a $50,000
    ///      request-path mint at settleBandBps = 500: the hedge went in for 140.364188 uTSLA and
    ///      the band floor minted 147.751777, leaving 7.387589 uTSLA ($2,628.95) unbacked. The
    ///      same discretion griefs in the other direction — a stranger settling at the band
    ///      ceiling minted 133.680179 for the receipt's owner, destroying $2,378.57 of their
    ///      value, with the receipt consumed.
    ///
    ///      The fix removes the discretion rather than bounding it: certOut is r.indicativeCerts,
    ///      the venue-representable amount requestMint actually submitted an order for. Law 1 then
    ///      holds by construction on this path — supply grows by exactly the base the hedge asked
    ///      for, at the venue's own granularity — and it holds no matter who calls, when, or with
    ///      what argument.
    ///
    ///      ESCROW RECONCILIATION. r.escrow bought r.indicativeCerts at r.requestPx18; the
    ///      remainder is floor-division and size-decimals dust (at most one venue tick of
    ///      notional — $0.036 at PX = 355.86 and sizeDecimals = 4). It is credited to BufferBook
    ///      rather than retained silently or paid back. Retained silently it would be value with
    ///      no owner and no published record; paid back it would need a transfer out of a hot
    ///      buffer that does not hold it (requestMint already posted targetMarginBps of the escrow
    ///      to the venue), which would give this permissionless function a funding-dependent
    ///      revert and a new "not yet" state for a sub-cent remainder. Execution variance and
    ///      realised basis are precisely what BufferBook is for.
    ///
    ///      Deliberately reconciled against r.requestPx18 and NOT against fillPx18. The residual
    ///      is then deterministic, non-negative by construction (indicativeCerts is floored from
    ///      escrow/requestPx18, so its cost cannot exceed the escrow) and outside any caller's
    ///      control. Reconciling against a caller-supplied fill would hand a stranger a
    ///      settleBandBps-wide lever over the published buffer, and would double-count with
    ///      accrueFunding(), which is the attester's own channel for relaying real execution
    ///      variance off the venue.
    ///
    ///      fillPx18 is KEPT, still banded against requestPx18, as a sanity bound and as the
    ///      reported fill in MintSettled. It no longer sizes anything. RESIDUAL FINDING: with no
    ///      attested per-receipt fill anywhere in C1, an honest on-chain check of the argument is
    ///      impossible, so it is informational — see the report.
    ///
    /// @dev C3: the band is measured against the receipt's OWN requestPx18, not against
    ///      oracle.pxUnguarded() at settle time. Banding against the settle-time price made the
    ///      band vacuous over time: the reference itself drifts with the market, so a fill
    ///      arbitrarily far from what the user requested at is "in band" as long as it tracks
    ///      wherever the price has since gone. Paired with settleWindow below, so a receipt
    ///      cannot sit indefinitely waiting for a favourable moment.
    /// @dev C-2: no _requireCapacity call here, on purpose. These certificates were admitted, and
    ///      their notional reserved in pendingMintCerts, at requestMint. Re-admitting the same
    ///      exposure would double-count it against the cap; gating on it would make a receipt
    ///      unsettleable because capacity moved after the escrow was already at the venue.
    function settleMint(uint256 receiptId, uint256 fillPx18) external {
        MintReceipt storage r = mintReceipts[receiptId];
        if (r.user == address(0) || r.settled) revert CertVault_BadReceipt();
        if (block.timestamp > uint256(r.requestedAt) + settleWindow) revert CertVault_SettleWindowExpired();
        if (fillPx18 == 0) revert CertVault_FillPriceOutOfBand();

        uint256 refPx = r.requestPx18;
        uint256 diff = fillPx18 > refPx ? fillPx18 - refPx : refPx - fillPx18;
        if (refPx == 0 || diff * 10_000 / refPx > cfg.settleBandBps) revert CertVault_FillPriceOutOfBand();

        r.settled = true;

        uint256 certOut = r.indicativeCerts;
        // C-2: the promise this receipt reserved is now outstanding supply, so hand the reservation
        // over rather than counting it twice. Floored for the same reason the stageRefund clamp is
        // (see there): a counter underflow must never be the thing that reverts a mint path.
        _releasePendingMint(certOut);
        certificate.mint(r.user, certOut);

        uint256 escrow18 = _to18(r.escrow);
        uint256 hedgeCost18 = _value18(certOut, refPx);
        if (escrow18 > hedgeCost18) buffer.accrue(address(this), SafeCast.toInt256(escrow18 - hedgeCost18));

        emit MintSettled(receiptId, certOut, fillPx18);
    }

    /// @notice Phase 1 of a refund: make the escrow's venue-side margin recallable, and close the
    ///         hedge the unsettled mint opened. Permissionless, callable once per receipt after
    ///         the settle window expires.
    /// @dev Deliberately separate from refundMint, and it must stay that way. Solidity has no
    ///      partial commit: a single function that reallocated the counters and then reverted on a
    ///      funding check would roll the reallocation back with it, so the reallocation could
    ///      never run in the one situation it exists for — an escrow the vault cannot currently
    ///      afford. That is precisely how escrow became permanently stranded. This phase touches
    ///      no balances and performs no transfer, so nothing in it can fail on funding, and it can
    ///      therefore be staged long before the vault can afford the payout. (_tryHedge's one
    ///      remaining unguarded read — the lighterAccountIndex() argument evaluated inside its own
    ///      try, which that try's catch does not cover — is now wrapped too; see _tryHedge. It was
    ///      equally an exposure for _queueExit, the Law 2 backstop, which is why it is fixed here
    ///      rather than deferred again.)
    ///
    ///      Law 2: nothing here can hold user value behind it. refundMint's
    ///      CertVault_RefundNotStaged is escaped by this call, which anyone may make. This call's
    ///      own reverts are CertVault_BadReceipt (unknown, already settled, or already staged —
    ///      the three share one error, so a caller cannot tell them apart; the receipt getter
    ///      can) and CertVault_SettleWindowNotExpired, in which case settleMint is still the live
    ///      path.
    function stageRefund(uint256 receiptId) external {
        MintReceipt storage r = mintReceipts[receiptId];
        if (r.user == address(0) || r.settled) revert CertVault_BadReceipt();
        if (block.timestamp <= uint256(r.requestedAt) + settleWindow) revert CertVault_SettleWindowNotExpired();
        if (r.refundStaged) revert CertVault_BadReceipt();

        r.refundStaged = true;

        // C-2: the certificates this receipt promised will never be minted — the window has
        // expired, so settleMint can no longer succeed — so give the capacity reservation back.
        // Floored, never checked-subtracted: nothing in this function may revert (see the NatSpec
        // above), least of all an accounting counter.
        _releasePendingMint(r.indicativeCerts);

        // Symmetric with _queueExit: move this receipt's posted share from the allocation counter
        // into the recall counter so recallMargin() will actually ask the venue for it. requestMint
        // posted targetMarginBps of this escrow via _postMargin and nothing else would ever ask for
        // it back — the certificates were never minted, so no _queueExit will ever allocate this
        // receipt's share, and recallMargin() sizes off counters that never learned about it.
        // This is a TRANSFER between the two counters, capped at postedMargin, so it cannot exceed
        // what was actually deposited and cannot double-count venue headroom (the failure mode
        // that killed three earlier recall designs — see recallMargin's doc comment).
        uint256 posted = r.escrow * cfg.targetMarginBps / 10_000;
        if (posted > postedMargin) posted = postedMargin;
        if (posted > 0) {
            postedMargin -= posted;
            marginPendingRecall += posted;
        }

        // Close the hedge this unsettled mint opened. requestMint submitted an order for
        // r.indicativeCerts at r.requestPx18; the certificates were never minted, so leaving that
        // exposure open makes the vault long against nothing (Law 1). Fail-open, using the exit
        // path's _tryHedge and not _hedge: an unplaceable close must not block the refund, and the
        // event below records that it did not go in.
        //
        // Priced off r.requestPx18, NOT oracle.pxUnguarded(). Two reasons, the first of which is
        // the Law 2 one: pxUnguarded() is documented never to revert but is not actually
        // revert-proof (CertOracle._tryFeed computes `block.timestamp - t` inside a try's SUCCESS
        // block, which that try's catch does not cover, so a feed reporting a future updatedAt
        // panics straight through it) — and an unwrapped external read here would make
        // CertVault_RefundNotStaged permanent, recreating the exact Critical this split exists to
        // fix. r.requestPx18 needs no call at all. Second, it is the more correct number: it is
        // the price this hedge was sized at. It is non-zero for every receipt requestMint creates,
        // since oracle.px() reverts on a non-positive answer, and toTickPrice is inside
        // _tryHedge's try either way.
        //
        // STILL OPEN-LOOP, now with a permissionless way back. ILighter exposes no position
        // getter, so nothing here can net r.indicativeCerts against what the vault actually
        // holds: if closeAll() or a rebalance() trim has already flattened or reduced the
        // position, this ASK opens a SHORT instead of closing a long. That much is unchanged and
        // needs an ILighter change or a vault-side position counter to fix properly.
        //
        // What HAS changed (CRITICAL A, see DELTA_UNBOUNDED_BPS) is the consequence, which is
        // what made it a Critical: rebalance() used to revert CertVault_InBand at zero supply
        // because _solvency reported deltaBps == 10_000 there, so the dangling position could be
        // freed only by governance's closeAll() while the venue's initial-margin lock on it
        // blocked the recall this refund depends on. A zero obligation with a non-zero attested
        // notional is now maximally out of band, so permissionless rebalance() trims it back to
        // flat over successive attested batches. Do not restate "rebalance() is the backstop"
        // unqualified: it is a backstop only from the next attestation onward, and only for the
        // portion the attester reports.
        bool placed = false;
        if (r.indicativeCerts > 0) {
            placed = _tryHedge(r.indicativeCerts, r.requestPx18, SIDE_ASK);
        }

        emit RefundStaged(receiptId, posted, placed);
    }

    /// @notice Phase 2 of a refund: return the escrow on a mint receipt whose settle window has
    ///         expired. Requires stageRefund first.
    /// @dev Permissionless by necessity, not convenience (Law 2 and Law 6): settleMint gains a
    ///      deadline in C3, and a deadline with no refund would strand the user's collateral
    ///      behind an expired receipt — trading one Law 2 breach for another. So the expiry is
    ///      not a dead end: it is a fork, and this is the other branch. Anyone may call it, it
    ///      always pays r.user and never msg.sender, and it marks the receipt settled so it can
    ///      neither be refunded twice nor settled afterwards.
    ///
    ///      The escrow is paid out of the vault's own collateral balance, exactly as claimRedeem
    ///      does. requestMint posted targetMarginBps of it to the venue, so a refund may need
    ///      recallMargin() to have brought that share home first — which is what stageRefund
    ///      makes possible, and why it is a precondition here rather than something this function
    ///      does for itself. The counter reallocation deliberately does NOT live in this function:
    ///      it must survive a failed payout, and anything inside this function does not.
    ///
    ///      r.settled is set only AFTER the funding check, so a refund that cannot be paid this
    ///      second leaves the receipt fully refundable — a "not yet", never a "no".
    function refundMint(uint256 receiptId) external returns (uint256 amountOut) {
        MintReceipt storage r = mintReceipts[receiptId];
        if (r.user == address(0) || r.settled) revert CertVault_BadReceipt();
        if (block.timestamp <= uint256(r.requestedAt) + settleWindow) revert CertVault_SettleWindowNotExpired();
        if (!r.refundStaged) revert CertVault_RefundNotStaged();

        // Collect anything the venue has already released before deciding we cannot pay: without
        // this, a refund would report "awaiting settlement" while the cash sat in the pending
        // balance one permissionless call away.
        _sweepPending();

        amountOut = r.escrow;
        if (IERC20(cfg.collateral).balanceOf(address(this)) < amountOut) {
            // Retryable, not a dead end: stageRefund has already moved this escrow's posted share
            // into marginPendingRecall, and recallMargin() and seedBuffer() are both
            // permissionless. The receipt stays unsettled and staged.
            revert CertVault_RefundAwaitingSettlement();
        }

        r.settled = true;
        IERC20(cfg.collateral).safeTransfer(r.user, amountOut);
        emit MintRefunded(receiptId, r.user, amountOut);
    }

    // ---------------------------------------------------------------- redeem

    /// @dev PRIORITY_EXPIRATION on ZkLighter. The honest worst-case redemption SLA.
    uint64 internal constant PRIORITY_EXPIRATION = 14 days;

    struct RedeemReceipt {
        address user;
        uint256 owed18;
        uint64 enqueuedAt;
        uint64 expiresAt;
        bool paid;
    }

    mapping(uint256 => RedeemReceipt) public redeemReceipts;

    /// @notice The certificates a queued exit burned, per receipt.
    /// @dev H-2: claimRedeem re-values the receipt at claim time and needs the quantity to do it
    ///      with; `owed18` alone is a price and a quantity multiplied together and cannot be
    ///      re-priced. Deliberately a SEPARATE mapping rather than a sixth field on RedeemReceipt:
    ///      the struct's public getter is destructured positionally by the auditor's own evidence
    ///      files (test/AuditPoC.t.sol, test/AttackSuite.t.sol) and by half the suite, so widening
    ///      it would rewrite call sites that must not be touched. Written once, in _queueExit,
    ///      never mutated. A plain SSTORE, so it adds no revert to the exit path.
    mapping(uint256 => uint256) public redeemCertIn;

    event Redeemed(address indexed user, uint256 certIn, uint256 amountOut, uint256 px18);
    event RedeemRequested(uint256 indexed receiptId, address indexed user, uint256 certIn, uint64 expiresAt);
    event RedeemClaimed(uint256 indexed receiptId, uint256 amountOut);
    event ForceExited(uint256 indexed receiptId, address indexed user, uint256 certIn);
    /// @dev Law 2: the closing hedge on the exit path is fail-open (see _tryHedge). This records
    ///      that the burn and receipt went through but the venue-side close did not, so it is
    ///      never silently lost — someone (rebalance(), or a retried close) can true it up later.
    event CloseOrderNotPlaced(uint256 certIn);

    /// @notice Instant redemption from the vault's own collateral balance (the hot buffer).
    /// @dev Deliberately reads NOTHING about buffer P&L health, capacity, or oracle pause state —
    ///      only the hot buffer's raw size, purely to route a holder to the path that will
    ///      actually pay them (Law 2's other paths remain unconditionally open; see
    ///      requestRedeem/forceExit/claimRedeem). Uses pxUnguarded so a stale feed cannot trap a
    ///      holder.
    function redeemInstant(uint256 certIn) external returns (uint256 amountOut) {
        if (certIn == 0) revert CertVault_ZeroAmount();
        (uint256 px18,) = oracle.pxUnguarded();
        // FINDING 1: was `certIn * px18 / 1e18`, which panics 0x11 at an extreme feed price. Second
        // of the three redemption-path instances of that product. Not the Law 2 backstop itself
        // (this path routes to the queue when the float is short) but a panic here is still a
        // redemption reverting on arithmetic, and the fix costs nothing. See _value18.
        uint256 gross18 = _value18(certIn, px18);
        // FINDING 1: mulDiv here too. gross18 can now legitimately be very large (the clamped
        // valuation at an absurd price), and `gross18 * cfg.redeemFeeBps` was a checked
        // multiplication that would have panicked past max / redeemFeeBps — reintroducing the
        // panic one line after removing it. Total for any redeemFeeBps <= 10_000, which the
        // constructor now enforces, and that same bound is what makes `gross18 - fee18` below
        // provably non-underflowing.
        uint256 fee18 = Math.mulDiv(gross18, cfg.redeemFeeBps, 10_000);
        amountOut = _from18(gross18 - fee18);

        if (hotBuffer() < amountOut) revert CertVault_UseQueuedRedeem();

        uint256 supplyBefore = certificate.totalSupply(); // capture BEFORE certificate.burn
        certificate.burn(msg.sender, certIn);
        // L-9's other half: a CLOSE keeps flooring (_baseAmount, via _hedge). Rounding a close up
        // would over-close, leaving the vault short against the supply that remains — the same
        // defect as an under-sized open, pointing the other way. Round in, floor out.
        _hedge(certIn, px18, SIDE_ASK);
        IERC20(cfg.collateral).safeTransfer(msg.sender, amountOut);

        // M-4: the venue-side margin behind the position just closed is now backing nothing, and
        // this path issues no receipt, so nothing downstream would ever ask for it. Move this
        // exit's pro-rata share out of postedMargin and into marginExcess, which recallMargin()
        // does size off. Pro-rata against supplyBefore for exactly the reason _queueExit gives:
        // certIn <= supplyBefore always (the burn above would have reverted otherwise), so the
        // share can never exceed what was actually posted, unlike a price-derived figure that
        // grows with the market. It is a transfer between counters — no balance moves here, and
        // nothing in it can fail on funding.
        // FINDING 1: mulDiv, for the same reason and by the same argument as _queueExit's twin.
        uint256 freed = supplyBefore == 0 ? 0 : Math.mulDiv(postedMargin, certIn, supplyBefore);
        if (freed > 0) {
            postedMargin -= freed;
            marginExcess += freed;
        }

        emit Redeemed(msg.sender, certIn, amountOut, px18);
    }

    /// @notice Queued redemption: burn now, close the hedge through Lighter's priority queue, and
    ///         let the holder pull payment once ready via claimRedeem.
    function requestRedeem(uint256 certIn) external returns (uint256 receiptId) {
        return _queueExit(certIn, false);
    }

    /// @notice Permissionless exit. Works with every off-chain service dead, the buffer empty, and
    ///         the oracle stale (Law 2's backstop).
    function forceExit(uint256 certIn) external returns (uint256 receiptId) {
        return _queueExit(certIn, true);
    }

    function _queueExit(uint256 certIn, bool isForce) internal returns (uint256 receiptId) {
        // Finding 1b (Task 10 review): with no guard here, ANY address holding zero certificates
        // could call forceExit(0)/requestRedeem(0) for free — certificate.burn(msg.sender, 0)
        // succeeds trivially, and the unguarded _tryHedge(0, ...) would forward baseAmount == 0 to
        // Lighter's close-all primitive, wiping the vault's entire hedge. This is not a Law 2
        // gate: a holder redeeming nothing has nothing to redeem, and every non-zero amount below
        // still routes through unconditionally.
        if (certIn == 0) revert CertVault_ZeroAmount();
        (uint256 px18,) = oracle.pxUnguarded();
        // FINDING 1 (CRITICAL, Law 2), THE ONE THIS FIX EXISTS FOR. This was
        // `certIn * px18 / 1e18`. forceExit() is this function, and Law 2 says it must always work
        // for a holder with a balance — but at a live feed price around px18 = 1e59 the plain
        // multiplication overflowed and panicked 0x11, reverting the protocol's last-resort
        // backstop for a holder whose certificates were perfectly good. A previous fix wave hit
        // the identical expression inside claimRedeem's new payout cap, guarded it there, and
        // correctly declined to guess at this twin.
        //
        // Declining to compute is NOT an option here the way it is in _payout18: that function is
        // computing a CAP and can fall back to the uncapped figure, whereas this one is computing
        // the obligation itself, so "no answer" means writing a receipt for zero and paying a
        // burned holder nothing — the sharpest Law 2 breach the contract could contain. So the
        // arithmetic had to be made total instead. See _value18 and MAX_VALUATION_PX18.
        uint256 gross18 = _value18(certIn, px18);
        // FINDING 1: see redeemInstant's twin. Total for any redeemFeeBps <= 10_000 (constructor
        // bound), which also makes the subtraction below provably safe.
        uint256 fee18 = Math.mulDiv(gross18, cfg.redeemFeeBps, 10_000);
        uint256 owed18 = gross18 - fee18;
        // C1: record the obligation the moment it is created, so recallMargin() can size its
        // request off what is actually owed rather than off the deposited cost basis.
        totalOwedOutstanding += _from18(owed18);

        uint256 supplyBefore = certificate.totalSupply(); // capture BEFORE certificate.burn
        certificate.burn(msg.sender, certIn);

        uint64 enqueuedAt = uint64(block.timestamp);
        uint64 expiresAt = enqueuedAt + PRIORITY_EXPIRATION;
        receiptId = _nextReceiptId++;
        redeemReceipts[receiptId] = RedeemReceipt({
            user: msg.sender,
            owed18: owed18,
            enqueuedAt: enqueuedAt,
            expiresAt: expiresAt,
            paid: false
        });
        // H-2: the quantity, so claimRedeem can re-value this receipt at claim time. owed18 above
        // becomes the CEILING on that valuation rather than the payout itself — see claimRedeem.
        redeemCertIn[receiptId] = certIn;

        // Fail-open (Law 2): forceExit is the last-resort backstop and must survive even when the
        // closing order itself cannot be placed. requestRedeem shares this path deliberately —
        // both queued-exit entry points must be equally unstoppable. See _tryHedge.
        if (!_tryHedge(certIn, px18, SIDE_ASK)) emit CloseOrderNotPlaced(certIn);

        // Price-independent by construction: certIn <= supplyBefore always (the burn above would
        // have reverted otherwise), so this holder's share of postedMargin can never exceed what
        // was actually posted — unlike sizing off the current oracle price, which grows with it.
        // FINDING 1: `postedMargin * certIn` was a checked multiplication on the Law 2 path.
        // mulDiv makes it total using nothing but the invariant the burn above already
        // establishes — certIn <= supplyBefore, so postedMargin * certIn <= postedMargin *
        // supplyBefore, and mulDiv panics only past supplyBefore * 2^256, which would need
        // postedMargin >= 2^256. No supply or price bound is required for that argument, and
        // mulDiv floors, so the pro-rata property this comment describes is unchanged.
        uint256 fromMargin = supplyBefore == 0 ? 0 : Math.mulDiv(postedMargin, certIn, supplyBefore);
        postedMargin -= fromMargin;
        // Task 8d: margin behind an open position is locked by the venue's initial margin
        // requirement and cannot be withdrawn until the closing order above fills in a batch —
        // submitting a withdrawal request here would be pointless at best (fact 3 in the task
        // brief: at 50% IMR a full-supply exit is unsatisfiable at every price) and, because the
        // venue performs no balance check and rejects insufficient requests silently inside the
        // rollup (fact 4), indistinguishable on-chain from success. So _queueExit only records the
        // allocation; recallMargin() is the separate, retryable step that actually withdraws once
        // the position has closed.
        if (fromMargin > 0) {
            marginPendingRecall += fromMargin;
        }

        if (isForce) emit ForceExited(receiptId, msg.sender, certIn);
        else emit RedeemRequested(receiptId, msg.sender, certIn, expiresAt);
    }

    /// @notice Pull-payment once the queued exit is ready. Callable by anyone on the holder's
    ///         behalf; always pays the receipt's owner, never msg.sender. Reads nothing but the
    ///         receipt itself and the vault's own balance — no buffer, capacity or oracle gate.
    /// @dev M2: redeemInstant refuses when hotBuffer() < amountOut and routes to the queued path,
    ///      but this function had no equivalent check — so a queued claim could consume the very
    ///      buffer that gate protects, making the gate decorative, and could let a later receipt
    ///      effectively jump an earlier one when funds are scarce. The check below is NOT a gate:
    ///      it reverts before touching r.paid, so the receipt stays claimable forever, and both
    ///      recallMargin() and the sweep inside this function are permissionless, so anyone can
    ///      make the funds arrive. Deliberately NOT FIFO: forcing receipts to be claimed in order
    ///      would let one absent holder block everyone behind them, which WOULD breach Law 2.
    ///
    /// @dev H-2 (HIGH, external C1 audit). THE PRICE. _queueExit locked owed18 at the oracle
    ///      price of the REQUEST, and the closing order fills in a later batch at whatever the
    ///      market has since done. The mint side deliberately does the opposite — settleMint
    ///      exists precisely so a large minter cannot tax the buffer across a gap move (spec §6)
    ///      — and the redemption asymmetry is DIRECTIONAL, not statistical: it pays out whenever
    ///      the price falls after the request, and a holder can watch a move begin before
    ///      queuing. It was a free option on batch latency, written by the vault, exercisable by
    ///      anyone. Measured on a $10,000 position across a -30% gap: the holder was paid
    ///      $9,980.01 for certificates worth $6,993.00, a $2,987.01 loss on one position — landing,
    ///      because this function is deliberately non-FIFO, on whoever redeemed last.
    ///
    ///      NO ATTESTED PER-RECEIPT FILL PRICE EXISTS IN C1. The audit's recommendation was to
    ///      settle at the attested fill price with the request price as a band, mirroring the mint
    ///      side. C-1 established there is no such number anywhere in this system: settleMint
    ///      takes no attestation, batch id or proof, SolvencyRegistry attests portfolio
    ///      aggregates and not fills, and ILighter exposes no fill or position getter. C-1's own
    ///      resolution was to stop pretending otherwise — it removed the caller-supplied fill
    ///      price from the arithmetic and kept it as an informational, banded argument. The same
    ///      limitation applies here, so the same honesty is applied: this function does not ask
    ///      anyone for a fill price.
    ///
    ///      WHAT IT DOES INSTEAD. The receipt is still WRITTEN at the request price — owed18 is
    ///      untouched, and so is every path that produced it — but the payout is CAPPED at what
    ///      the certificates it burned are worth when it is actually paid:
    ///
    ///          payout = min(owed18, certIn * px_now)
    ///
    ///      A cap, deliberately, and not a re-pricing. It is the exact statement of the property
    ///      the audit's own proof-of-concept asserts — a redemption must not pay above the value
    ///      it closes at — and nothing more: while the price has not fallen far enough for the
    ///      cap to bite, the holder is paid owed18 to the wei, fee assessed once at the request
    ///      price, and every "paid in full" test in the suite still measures exactly what it did
    ///      before. The cap is the GROSS current value, not the current value less the redeem fee,
    ///      for the same reason: the fee is earned out of surplus above what the position is
    ///      worth, so where there is no surplus there is no fee to take, and taking one would put
    ///      the payout below the value it closes at rather than at it.
    ///
    ///      One-sided on purpose. The direction that costs the vault is DOWN — a fall between
    ///      request and fill means the close realises less than the receipt promises — so that is
    ///      the direction the payout follows. Upward moves do not raise the payout, because the
    ///      holder burned their certificates at request time and is out of the position; letting
    ///      an upward move raise it would simply be the same free option pointing the other way,
    ///      exercisable by waiting instead of by hurrying. A two-sided band (clamp at
    ///      settleBandBps either way) was considered and rejected: it bounds the option at 5%
    ///      instead of removing it, and 5% of the queue is still the vault's money.
    ///
    ///      IT IS AN APPROXIMATION, AND HERE IS THE ERROR TERM. The claim-time price is not the
    ///      fill price; the fill happens a batch after the request, while a claim can be
    ///      arbitrarily later. So between fill and claim, a move down is charged to the holder
    ///      rather than to the vault, which over-corrects — the capped payout is a conservative
    ///      LOWER BOUND on realisable value, not an estimate of it. That direction is chosen
    ///      deliberately: the shortfall it prevents lands on holders who did not ask to be
    ///      short anything (this function is non-FIFO), while the excess it can charge lands on
    ///      the holder who chose the exit timing, is bounded by their own promptness, and is
    ///      visible to them before they claim. It also makes prompt claiming weakly optimal for
    ///      every holder, which is what actually drains the queue. The residual — a stranger may
    ///      claim ON a holder's behalf during a dip, since this function is deliberately callable
    ///      by anyone, and thereby realise a loss the holder would have waited out — is real, is
    ///      bounded by the ceiling, and is reported rather than papered over.
    ///
    ///      LAW 2 IS UNTOUCHED, and this is the part that had to be got right. The cap can only
    ///      ever LOWER the payout, so no receipt becomes harder to fund than it was:
    ///      every receipt this vault could pay before, it can still pay, and the retryable
    ///      CertVault_AwaitingSettlement branch gets strictly rarer. The oracle read is wrapped
    ///      and falls back to the ceiling, so a dead, hostile or unreadable feed cannot revert a
    ///      payout — and a price of zero is treated as an ABSENCE of a price, not as a valuation
    ///      of zero, which is the one way this could have paid a holder nothing. Nothing here
    ///      needs a privileged actor, a fill report, or a second step. forceExit is not touched
    ///      at all.
    function claimRedeem(uint256 receiptId) external returns (uint256 amountOut) {
        RedeemReceipt storage r = redeemReceipts[receiptId];
        if (r.user == address(0) || r.paid) revert CertVault_NothingToClaim();

        _sweepPending();

        amountOut = _from18(_payout18(receiptId, r.owed18));
        if (hotBuffer() < amountOut) revert CertVault_AwaitingSettlement();

        // C1: retire the obligation before paying it, so recallMargin() stops asking for it.
        // Floored, never checked-subtracted: r.owed18 is fixed at queue time while
        // totalOwedOutstanding is a running counter, and an underflow here would revert a
        // payout — a Law 2 breach in exchange for accounting tidiness.
        // H-2: retire what _queueExit ADDED (_from18(r.owed18)), not what is being paid. The
        // counter is the ledger of obligations created, so a re-valued payout must still close
        // its own entry — otherwise every downward re-valuation would leave a permanent residue
        // in it and recallMargin() would ask the venue for a shortfall that no longer exists.
        uint256 owedCollateral = _from18(r.owed18);
        uint256 applied = owedCollateral < totalOwedOutstanding ? owedCollateral : totalOwedOutstanding;
        totalOwedOutstanding -= applied;

        r.paid = true;
        IERC20(cfg.collateral).safeTransfer(r.user, amountOut);
        emit RedeemClaimed(receiptId, amountOut);
    }

    /// @notice What a queued receipt pays right now: what it was written for, capped at what the
    ///         certificates it burned are worth at the current price.
    /// @dev H-2. The whole design argument lives on claimRedeem; this is the arithmetic. `owed18`
    ///      is passed in rather than re-read so the amount being capped is unmistakably the number
    ///      the receipt was written with.
    ///
    ///      Every branch that cannot produce a valuation returns owed18 UNCAPPED, never zero:
    ///        - the oracle read reverting (it is documented not to, and CertOracle is hardened
    ///          against every input the suite can throw at it, but this is a payout path and the
    ///          cost of the try/catch is nothing);
    ///        - a price of zero, which pxUnguarded() can genuinely return (an ok feed whose
    ///          answer normalises down to 0 at high decimals — see
    ///          test_mintAllowedFalseWhenFeedTruncatesToZero). Zero is the ABSENCE of a price.
    ///          Capping at it would pay a burned holder nothing at all, which is the sharpest
    ///          Law 2 breach this contract could contain;
    ///        - a receipt with no recorded quantity, i.e. any receipt written before this mapping
    ///          existed. There are none on a fresh deployment, and reading a missing quantity as
    ///          zero certificates would cap every such payout at zero, so it defers too;
    ///      In all three the vault keeps the pre-H-2 behaviour, which is the only safe direction:
    ///      a valuation the chain cannot compute must never become a reason not to pay.
    ///
    ///      A FOURTH branch used to sit here — "a price so large that `certIn * px18` does not fit
    ///      in uint256" — and it is gone, replaced by arithmetic that has no such case. FINDING 1
    ///      (the external audit's final wave) is that the same expression in _queueExit had no such
    ///      guard, and that a guard was the wrong answer for it anyway: _queueExit computes the
    ///      obligation, not a cap, so it has nothing safe to fall back TO. Both now call _value18,
    ///      which is total for every uint256 pair. The observable behaviour of this function at an
    ///      extreme price is identical to what the removed branch produced (owed18), for the reason
    ///      that branch already gave: at any price that large the cap cannot bite.
    function _payout18(uint256 receiptId, uint256 owed18) internal view returns (uint256) {
        uint256 certIn = redeemCertIn[receiptId];
        if (certIn == 0) return owed18;

        uint256 px18;
        try oracle.pxUnguarded() returns (uint256 p, uint256) {
            px18 = p;
        } catch {
            return owed18;
        }
        if (px18 == 0) return owed18;

        // FINDING 1: the ad-hoc `px18 > type(uint256).max / certIn` bail-out that used to sit here
        // is GONE, and its removal is the fix rather than a simplification. It was the right
        // instinct in the wrong shape: it made the overflow unreachable by refusing to value the
        // receipt at all, which is fine for a cap (returning owed18 uncapped is the safe direction)
        // but was never a fix for the twin expression in _queueExit, where the same "refuse to
        // compute" would mean paying a burned holder zero. Both now share one total helper, so
        // there is a single overflow argument in this file instead of one guard here and a panic
        // there. The outcome at an extreme price is unchanged: the clamped valuation is
        // astronomically above any receipt written at a tradeable price, so the `min` below still
        // returns owed18 — which the old bail-out returned directly.
        uint256 valueNow18 = _value18(certIn, px18);
        return valueNow18 < owed18 ? valueNow18 : owed18;
    }

    /// @notice Bring exit-allocated margin home from the venue. Permissionless and retryable.
    /// @dev Two-phase by necessity: margin backing an open position is locked by the venue's
    ///      initial margin requirement and cannot be withdrawn until the closing order fills. So
    ///      this is a separate step that anyone may retry until it lands. It is deliberately NOT
    ///      receipt-scoped: a single counter avoids the per-receipt keeper that would otherwise be
    ///      required inside a path that must work with no off-chain services (see task-8d brief —
    ///      a TTL'd per-receipt hold was built and judged fatal for double-counting headroom).
    ///      Fail-open: the venue performs no balance check and rejects insufficient requests
    ///      silently inside the rollup, so a failure here must never revert the caller.
    ///
    ///      C1 (final review wave): this used to request exactly marginPendingRecall — a pro-rata
    ///      share of the DEPOSITED COST BASIS. What a receipt owes grows with price, so nothing
    ///      here ever asked the venue for more than basis and a position's realised gain could
    ///      never come home: a receipt could be permanently unpayable with its certificates
    ///      already burned, the sharpest possible breach of Law 2. Task 8c was right that a
    ///      price-derived request outgrows what was posted, and right to make the ALLOCATION
    ///      pro-rata (that is what keeps holders fair to each other, and it is kept, in
    ///      _queueExit). It was wrong to also make the REQUEST pro-rata. Over-requesting is safe
    ///      and always was: the venue fulfils min(request, available), refuses insufficiency
    ///      silently inside the rollup, this function is already fail-open, and _sweepPending
    ///      floors its counter application at min(swept, marginPendingRecall) — so a larger
    ///      arrival simply lands in the hot buffer, which is exactly where a gain belongs.
    function recallMargin() external {
        _sweepPending();

        uint256 have = hotBuffer();
        uint256 need = totalOwedOutstanding > have ? totalOwedOutstanding - have : 0;
        // A staged mint refund reaches this sizing through marginPendingRecall, not through
        // totalOwedOutstanding: stageRefund() moves the escrow's posted share into that counter,
        // and the `max` below therefore already asks the venue for it. Proven by test, not by
        // reading — see test_recallMarginRequestsTheStagedRefundShare and its negative control
        // test_recallMarginDoesNotRequestUnstagedRefundEscrow.
        // Always recall at least the allocated basis; ask for the shortfall when it is larger,
        // because the venue fulfils min(request, available) and _sweepPending reconciles what
        // actually arrives.
        uint256 want = need > marginPendingRecall ? need : marginPendingRecall;
        if (want > 0) _requestWithdraw(want);

        // M-4: the second sizing term, and the only one that can see margin freed by an INSTANT
        // redemption. It is a separate step from the request above, not folded into `want`, for
        // two reasons.
        //
        // First, it is allowed to COLLECT in the same call. The two-phase shape above —
        // recallMargin() submits, a later recallMargin() sweeps — exists because margin behind an
        // open position is locked by the venue's initial margin requirement, so a request cannot
        // be assumed to have been honoured and marginPendingRecall must survive until
        // getPendingBalance proves cash arrived (Task 8d). marginExcess has no such claim behind
        // it: the exit that freed it was already paid, in full, out of the float. So sweeping
        // straight after the request is not a shortcut here, it is the correct shape — and it is
        // what makes the freed margin reachable in ONE permissionless call by an address holding
        // no certificates and no receipt, which is what M-4 is about.
        //
        // Second, keeping it out of `want` keeps this addition inert for every state that does
        // not have instantly-redeemed margin sitting at the venue: marginExcess is zero unless
        // redeemInstant put something in it, so the allocated-recall path above behaves exactly
        // as it did, including its "submission is not arrival" contract.
        //
        // Fail-open like everything else here: a refused request leaves marginExcess untouched
        // and anyone may retry.
        if (marginExcess > 0 && _requestWithdraw(marginExcess)) _sweepPending();
    }

    /// @dev Ask the venue for `amount` of collateral back. Fail-open: returns false rather than
    ///      reverting, because both callers are permissionless and neither may be blocked by a
    ///      venue refusal (withdrawals disabled, deposit cap, a future rollup rule).
    /// @dev The account-index read is a LOCAL inside its own try, not an argument to the
    ///      withdraw() try. It used to sit in argument position, and argument evaluation happens
    ///      BEFORE the protected call, so that try's catch never covered it — a venue whose
    ///      addressToAccountIndex view reverted (paused behind a proxy, storage layout moved by an
    ///      upgrade) propagated straight out of a function whose entire contract is that it does
    ///      not revert. Exactly the defect already fixed in _tryHedge, in the same argument
    ///      position, for the same reason; this was the last instance of it in the file.
    function _requestWithdraw(uint256 amount) internal returns (bool requested) {
        // Clamp to the venue's own per-asset withdrawal ceiling: over-requesting is safe, but a
        // request above that cap reverts on-chain rather than being silently trimmed in-rollup.
        if (amount > venueWithdrawCap) amount = venueWithdrawCap;
        if (amount == 0) return false;

        uint48 accountIndex;
        try lighter.addressToAccountIndex(address(this)) returns (uint48 idx) {
            accountIndex = idx;
        } catch {
            return false;
        }

        // A request above uint64 is unreachable below ~$18.4T; revert loudly rather than truncate.
        // See venueWithdrawCap's deployment note: a cap within uint64 makes this unreachable.
        uint64 ask = SafeCast.toUint64(amount);

        try lighter.withdraw(accountIndex, cfg.collateralAssetIndex, cfg.routeType, ask) {
            emit MarginRecallRequested(amount);
            return true;
        } catch {
            // Venue refused at request time. Neither counter is reduced — the caller may retry.
            return false;
        }
    }

    /// @notice Wind-down: close the entire position using Lighter's baseAmount == 0 primitive.
    ///         The only governance-gated function in this contract (Law 6: no privileged trading
    ///         key otherwise — this is wind-down, not routine trading).
    function closeAll() external {
        if (msg.sender != governance) revert CertVault_OnlyGovernance();

        // M-3: the SIDE is derived from the vault's own order ledger, not assumed to be ASK.
        // `baseAmount == 0` defaults to the full position SIZE and leaves `isAsk` to the caller, so
        // a hardcoded ASK against a short submitted a full-size sell into a short and doubled it —
        // in the one function whose entire purpose is to get flat. See venuePositionBase for what
        // the ledger is and, more importantly, for the four ways it can still be wrong.
        int256 known = venuePositionBase;
        if (known == 0) {
            // FAIL CLOSED. The vault's own books say the position a close-all order would meet is
            // flat, so there is nothing to close and no direction to pick — and picking one anyway
            // is how this finding happened. Deliberately NOT a revert: the repatriation below is
            // unconditional and useful on its own, and reverting here would remove governance's
            // wind-down entirely in the state where the position is already going to zero (the
            // exit's own closing order is enqueued but not yet filled, which is precisely
            // test_windDownRecoversAllMargin's shape). Emitted so a skipped close is a record and
            // not a silent no-op.
            emit CloseAllSkippedFlat();
        } else {
            uint8 side = known > 0 ? SIDE_ASK : SIDE_BID;
            (uint256 px18,) = oracle.pxUnguarded();
            // Deliberately NOT routed through _hedge/_tryHedge: those now refuse baseAmount == 0
            // (Finding 1, Task 10 review). closeAll() is the one legitimate caller of Lighter's
            // baseAmount == 0 "default to the full position size" primitive, so it calls
            // createOrder directly with a literal 0 here, bypassing the zero-amount guards on
            // purpose — and therefore also bypasses _recordOrder, which sizes off a base amount
            // this order does not carry. The ledger is zeroed explicitly instead: a full-size close
            // on the correct side lands the position at flat.
            lighter.createOrder(
                lighterAccountIndex(), cfg.marketIndex, 0, oracle.toTickPrice(px18), side, ORDER_TYPE_MARKET
            );
            venuePositionBase = 0;
            emit ClosedAll(side, known);
        }
        // C1: a wind-down must also repatriate. Without this, closeAll() closed the position and
        // withdrew nothing, leaving whatever the venue had already released sitting in the
        // pending balance while the receipts it belongs to went unpaid.
        _sweepPending();
    }

    // ---------------------------------------------------------------- solvency & rebalance

    error CertVault_InBand();
    error CertVault_OnlyAttester();
    /// @dev rebalance() cannot size a notional gap without a price. Named so a permissionless
    ///      caller gets an error instead of an anonymous division-by-zero panic; see rebalance().
    error CertVault_NoPrice();
    /// @dev C2: rebalance() reads a per-batch attestation. Acting on the same batch twice is
    ///      acting twice on one piece of information, which is what turned a per-call notional
    ///      bound into no bound at all. Not a Law 2 concern: rebalance() is not a redemption
    ///      path, and it is retryable the moment a new batch is attested (~60s).
    error CertVault_AlreadyRebalancedThisBatch();

    /// @notice The newest attestation batchId rebalance() has already acted on.
    uint64 public lastRebalancedBatch;

    /// @dev Delta tolerance in bps, and the maximum notional a single rebalance() call may move.
    ///      Bounding the latter is what keeps rebalance() permissionless without letting any
    ///      single caller push the vault's position around (Law 6).
    uint256 public constant DELTA_BAND_BPS = 100;
    uint256 public constant MAX_REBALANCE_NOTIONAL_18 = 10_000e18;

    /// @notice Published sentinel deltaBps for "the obligation is zero but the vault still
    ///         carries an attested position" — i.e. hedge-to-obligation ratio with a zero
    ///         denominator, which is unbounded, not 100%.
    /// @dev CRITICAL A (C1 final review). _solvency used to report deltaBps == 10_000 for ANY
    ///      zero-`required` state, so zero certificates outstanding against a live position read
    ///      as dead centre of the band — perfectly hedged — when it is in fact pure unhedged
    ///      directional risk and the single worst state the vault can be in. That is not a
    ///      cosmetic mis-report: it made rebalance() revert CertVault_InBand at exactly the
    ///      moment a trim was needed, so a position left dangling by stageRefund's open-loop
    ///      close (or by a rebalance() trim, or after closeAll()) could be freed by NOTHING
    ///      permissionless — forceExit/requestRedeem need certificates and supply is 0 — leaving
    ///      governance's closeAll() as the sole escape while the venue's initial-margin lock on
    ///      the unwanted position blocked the very recall the refund depended on.
    ///      type(uint256).max rather than a finite "very out of band" number for two reasons: it
    ///      is the honest value of a ratio whose denominator is zero, and it cannot collide with
    ///      any ratio the real computation can produce, so a reader can tell the sentinel from a
    ///      measurement. It is unambiguously above 10_000 + DELTA_BAND_BPS, which is the
    ///      over-hedged side — the direction that makes rebalance() SELL, which is what a zero
    ///      obligation demands.
    uint256 public constant DELTA_UNBOUNDED_BPS = type(uint256).max;

    /// @dev M-1: `buffer18` and `accrual18` are two different quantities and used to be one. See
    ///      _solvency() for which is which and why the split had to happen. `accrual18` is
    ///      appended at the END of the struct deliberately: solvency() returns a struct, so every
    ///      reader in and out of the suite accesses these by name, and appending cannot silently
    ///      re-point an existing field the way inserting would.
    struct Solvency {
        uint256 supply;
        uint256 notional18;
        uint256 margin18;
        int256 buffer18;
        uint256 deltaBps;
        uint64 provenAtBatch;
        uint256 ageSec;
        int256 accrual18;
    }

    /// @notice Public backing figure. Always carries provenAtBatch and ageSec alongside the
    ///         numbers — there is no code path that returns backing without also saying how old
    ///         and whose attestation it rests on (published-honesty requirement, not a nicety).
    ///         Reads SolvencyRegistry's per-batch attestation, never postedMargin, which is a
    ///         withdrawal-sizing counter only and ignores funding, PnL and liquidation.
    function solvency() external view returns (Solvency memory s) {
        (s,,) = _solvency();
    }

    /// @dev Shared core for solvency() and rebalance() so both price off the same oracle read and
    ///      `required` (the dollar value the outstanding supply demands at delta 1.0) is computed
    ///      exactly once, rather than solvency() and rebalance() each re-deriving it separately
    ///      and risking the two drifting apart.
    function _solvency() internal view returns (Solvency memory s, uint256 required, uint256 px18) {
        ISolvencyRegistry.Attestation memory a = registry.latest(address(this));
        (px18,) = oracle.pxUnguarded();

        s.supply = certificate.totalSupply();
        s.notional18 = a.notional18;
        s.margin18 = a.margin18;
        // M-1 (MEDIUM, external C1 audit). THE PUBLISHED BUFFER IS NOW BACKED. This field used to
        // be BufferBook.balance18() — an accrual ledger — published under the name "buffer" beside
        // the attested backing figures, as though it were collateral the vault held. It was not,
        // in two compounding ways, and both were measured:
        //
        //   (a) it drifted from reality under ordinary operation. Mint fees raise the real float
        //       without accruing to the ledger and instant redemptions drain it without accruing
        //       either, and nothing reconciled them: after one mint + instant-redeem cycle the
        //       published buffer read 100,000.00 against 91,028.00 actually held.
        //   (b) accrueFunding() lets the attester write the ledger, so the published figure could
        //       be declared. One call produced a published buffer of 500,100,000.01 against
        //       91,028.00 held.
        //
        // So the two numbers are now published as the two different things they are. `buffer18` is
        // the vault's own collateral balance — an ERC20 balanceOf, ground truth, and the figure
        // Law 3's "the live buffer on-chain" was always claiming to be — and `accrual18` below is
        // the ledger, published as what it actually is: cumulative funding, execution variance and
        // realised basis, relayed by the attester and NOT independently verified on-chain.
        //
        // Deliberately the GROSS float and not freeCollateral18()'s net-of-obligations figure:
        // this field answers "what does the vault hold", the counters answer "what does it owe",
        // and both are published separately (totalOwedOutstanding, marginPendingRecall,
        // marginExcess, postedMargin) rather than pre-netted into one number a reader cannot take
        // apart. SafeCast rather than a bare cast: a bare cast on an absurd balance would publish
        // a NEGATIVE buffer, which is worse than reverting a view that no redemption path calls.
        s.buffer18 = SafeCast.toInt256(_to18(hotBuffer()));
        s.accrual18 = buffer.balance18(address(this));
        s.provenAtBatch = a.batchId;
        s.ageSec = registry.ageSec(address(this));

        // FINDING 1: `supply * px18 / 1e18`. Not a redemption path (only solvency() and
        // rebalance() reach it), so this is not a Law 2 fix — but it is the same product with the
        // same unbounded price, and a panicking published backing figure is its own kind of
        // dishonesty. At a clamped price the trim it feeds sizes a certEquivalent that floors to
        // zero and rebalance() reverts CertVault_InBand, i.e. a named error rather than an
        // anonymous 0x11, which is what a permissionless entry point owes its caller.
        required = _value18(s.supply, px18);
        if (required == 0) {
            // required == 0 (no supply, or px18 == 0) means the vault owes no delta at all. What
            // that implies depends entirely on whether it is nonetheless carrying one:
            //
            //  - attested notional 0 too: nothing to hedge and nothing hedged. Genuinely
            //    at-target; report 10_000 bps so rebalance() reverts CertVault_InBand.
            //  - attested notional non-zero: a live position against a zero obligation. This is
            //    the CRITICAL A case (see DELTA_UNBOUNDED_BPS). It is maximally OUT of band on
            //    the over-hedged side, and reporting it as 10_000 was both a false published
            //    figure and the reason nothing permissionless could trim it.
            //
            // Either way this branch is also what keeps the division below from dividing by zero.
            s.deltaBps = a.notional18 == 0 ? 10_000 : DELTA_UNBOUNDED_BPS;
        } else {
            s.deltaBps = a.notional18 * 10_000 / required;
        }
    }

    /// @notice Permissionless delta trim: pulls the vault's Lighter position back toward the
    ///         notional its outstanding supply requires at delta 1.0. Bounded per call by
    ///         MAX_REBALANCE_NOTIONAL_18 so no single caller can move more than that much size;
    ///         reverts CertVault_InBand() when already within DELTA_BAND_BPS, since there is
    ///         nothing to trim.
    /// @dev Uses the revert-capable _hedge, not the exit path's fail-open _tryHedge: rebalancing
    ///      is not a redemption path, so Law 2 does not require it to succeed. If the order
    ///      cannot be placed (e.g. an extreme price overflowing the tick domain), this call
    ///      reverts and the caller simply does not collect anything for this attempt — Law 6
    ///      permissionlessness means anyone may retry, it does not mean every attempt must
    ///      succeed. No on-chain bounty is paid here: C1 has no fee/reward token to draw one
    ///      from (FeeVault/CERT are C3 concerns) — "permissionless" is itself what makes an
    ///      off-chain keeper incentive possible on top of this function, not inside it.
    /// @dev C2: bounded per call AND per unit of information. The per-call notional bound alone
    ///      was decorative, because the attestation rebalance() reads does not move between
    ///      calls: a stranger could re-observe the same gap 25 times in one block and move 25x
    ///      the bound. Requiring a batchId strictly newer than the last one acted on keeps this
    ///      permissionless (anyone may still call it, Law 6 — deliberately NO access-control
    ///      gate) while making the per-call bound the real per-batch bound it was meant to be.
    function rebalance() external {
        uint64 batchId = registry.latest(address(this)).batchId;
        if (batchId <= lastRebalancedBatch) revert CertVault_AlreadyRebalancedThisBatch();
        lastRebalancedBatch = batchId;

        (Solvency memory s, uint256 required, uint256 px18) = _solvency();

        // CRITICAL A follow-on: the certEquivalent division below divides by px18. Before the
        // fix a zero px18 forced required == 0 and therefore deltaBps == 10_000, so the in-band
        // revert masked it; now that a zero `required` with a live position is out of band, that
        // division is genuinely reachable at px18 == 0 and would panic (0x12) anonymously.
        // pxUnguarded() can report 0 (an ok feed whose answer normalises down to 0 at high
        // decimals — see CertOracle._tryFeed and test_mintAllowedFalseWhenFeedTruncatesToZero),
        // so name the condition rather than leaving a panic in a permissionless entry point.
        // Not a Law 2 concern: rebalance() is not a redemption path, and it is retryable.
        if (px18 == 0) revert CertVault_NoPrice();

        uint256 lo = 10_000 - DELTA_BAND_BPS;
        uint256 hi = 10_000 + DELTA_BAND_BPS;
        if (s.deltaBps >= lo && s.deltaBps <= hi) revert CertVault_InBand();

        // At required == 0 with a non-zero attested notional (CRITICAL A) this is the false
        // branch, so the trim is a SELL of the whole attested notional — bounded by
        // MAX_REBALANCE_NOTIONAL_18 exactly as any other gap is, so a dangling position larger
        // than the bound is walked to flat one attested batch at a time rather than in one call.
        // Convergence, not oscillation: each trim reduces the position, the next batch attests
        // the smaller notional, and the sequence terminates on whichever comes first — an
        // attested notional of 0 (deltaBps back to 10_000, CertVault_InBand) or a remainder whose
        // baseAmount floors to 0 (the dust guard below, also CertVault_InBand). Nothing here can
        // overshoot into the opposite direction on truthful attestations, because the trim is
        // sized off the attested notional itself, never off a fraction of it.
        bool underHedged = s.notional18 < required;
        uint256 gap18 = underHedged ? required - s.notional18 : s.notional18 - required;
        if (gap18 > MAX_REBALANCE_NOTIONAL_18) gap18 = MAX_REBALANCE_NOTIONAL_18;

        uint256 certEquivalent = gap18 * 1e18 / px18;
        // Finding 1a (Task 10 review): either this division or the size-decimals conversion
        // inside _hedge can floor a small-but-real gap to a baseAmount of 0 — Lighter's
        // "close the entire position" primitive, not a no-op. That is ordinary during a
        // wind-down (outstanding notional a few cents wide at sizeDecimals = 4). Treat a
        // dust-sized gap as already in-band rather than ever submitting a zero-amount order.
        if (_baseAmount(certEquivalent) == 0) revert CertVault_InBand();
        _hedge(certEquivalent, px18, underHedged ? SIDE_BID : SIDE_ASK);
    }

    /// @notice Relay accrued funding, execution variance and realised basis into the buffer.
    ///         Permissionless surface, attester-gated caller: only the oracle's attester may push
    ///         a delta, but the resulting balance is readable by anyone via BufferBook (Law 3 —
    ///         nothing here is hidden).
    function accrueFunding(int256 delta18) external {
        if (msg.sender != ICertOracleAttester(address(oracle)).attester()) revert CertVault_OnlyAttester();
        buffer.accrue(address(this), delta18);
    }

    // ---------------------------------------------------------------- internals

    /// @notice Collect any margin the venue has actually released, and only then reduce the
    ///         outstanding recall. getPendingBalance is the sole on-chain proof a withdrawal
    ///         executed (Task 8d, fact 5) — L1 acceptance of the withdraw() call carries none.
    /// @dev min(...) guards against a sweep larger than marginPendingRecall (e.g. funding credited
    ///      by the venue landing in the same pending balance) flooring the counter at 0 instead of
    ///      underflowing.
    /// @dev M1: the withdrawPendingBalance call is wrapped. This is the fourth instance of the
    ///      same pattern on this branch (see _tryHedge, recallMargin, CertOracle._tryFeed): an
    ///      unguarded venue call sitting inside a path that must not revert. Unwrapped, a venue
    ///      refusal here propagated into claimRedeem (blocking a payout outright) and into
    ///      recallMargin (contradicting its own fail-open NatSpec). On failure this returns 0 and
    ///      leaves both counters untouched, so the caller simply retries later; both callers
    ///      already tolerate a zero sweep.
    /// @dev The getPendingBalance read is wrapped too, not just the drain. It is a view, but it is
    ///      still an unguarded venue call sitting inside four paths that must not revert
    ///      (claimRedeem, recallMargin, closeAll and now refundMint) — a venue paused behind a
    ///      proxy, or an asset index deconfigured, would have reverted refundMint with a venue
    ///      error while the buffer was fully funded, i.e. with something other than the retryable
    ///      CertVault_RefundAwaitingSettlement, and would have blocked claimRedeem outright. On
    ///      failure this returns 0 with both counters untouched, which is what this function's own
    ///      NatSpec above already promised and what every caller already tolerates.
    function _sweepPending() internal returns (uint256 swept) {
        uint128 pending;
        try lighter.getPendingBalance(address(this), cfg.collateralAssetIndex) returns (uint128 p) {
            pending = p;
        } catch {
            return 0;
        }
        if (pending == 0) return 0;

        try lighter.withdrawPendingBalance(address(this), cfg.collateralAssetIndex, pending) {
            swept = uint256(pending);
        } catch {
            // Venue refused to release an already-credited pending balance. Nothing arrived, so
            // nothing is applied — the pending balance stays where it is and remains sweepable.
            return 0;
        }

        uint256 applied = swept < marginPendingRecall ? swept : marginPendingRecall;
        marginPendingRecall -= applied;
        // M-4: whatever arrived beyond the allocated recall retires marginExcess next, floored the
        // same way. Order matters and this one is deliberate: marginPendingRecall is money a
        // specific unpaid receipt has a claim on, marginExcess is money nobody does, so an arrival
        // settles the claim first. Anything left over after BOTH is a genuine surplus — venue
        // funding credited into the same pending balance, or a position's realised gain — and it
        // stays in the hot buffer with no counter to touch, exactly as before.
        uint256 surplus = swept - applied;
        if (surplus > 0) {
            uint256 appliedExcess = surplus < marginExcess ? surplus : marginExcess;
            marginExcess -= appliedExcess;
        }
        emit MarginRecalled(applied, marginPendingRecall);
    }

    /// @notice Admission control for the two mint paths. Refuses a mint whose notional would put
    ///         the vault's exposure past what CapacityOracle allows.
    /// @dev C-2: `current` is the MAXIMUM of two figures, and it has to be both.
    ///
    ///      The vault's own obligation — outstanding certificates plus certificates promised to
    ///      unsettled receipts, valued at the price the calling mint is pricing itself off — is
    ///      the half that MOVES. It grows on every mint (instant or requested) and shrinks on
    ///      every burn, so the per-call bound is finally a bound on the sum. Sizing off the
    ///      attested notional alone was the defect: it does not move between batches, so the cap
    ///      was re-observed intact by every mint in the window (measured 1.68x over cap; see
    ///      pendingMintCerts).
    ///
    ///      The attested notional is KEPT as a floor, not discarded. It is the wrong number for
    ///      admission control on its own but it is the right number for solvency reporting, and it
    ///      is the only thing that sees a position the vault's own books have lost track of — a
    ///      hedge left dangling by stageRefund's open-loop close, say, where supply is zero and
    ///      the obligation measure would happily admit fresh mints on top of live directional
    ///      risk. Taking the larger of the two is strictly the safer reading of both.
    ///
    ///      Redemptions compose without touching this function: redeemInstant and _queueExit burn
    ///      before anything else, so the obligation term drops immediately and the freed headroom
    ///      is visible to the next mint. Reading capacity is deliberately confined to the mint
    ///      paths — no redemption path calls this (Law 2).
    /// @dev M-1: the third leg passed to CapacityOracle is bufferCapacity18() — derived from
    ///      collateral the vault actually holds — and no longer BufferBook.capacity18() raw. See
    ///      bufferCapacity18() for the whole argument. Nothing else in this function changed.
    function _requireCapacity(uint256 addNotional18, uint256 px18) internal view {
        uint256 max = capacity.maxNotional18(address(this), bufferCapacity18());
        // FINDING 1: `(totalSupply + pendingMintCerts) * px18 / 1e18`. A mint path, so a revert
        // here is permitted (Laws 2 and 3 gate minting, never redemption) — but supply is NOT
        // bounded relative to the CURRENT price the way a single mint's own certOut is (that one
        // is floored from net18 / px18, so its product back with px18 can never exceed net18;
        // this one values certificates minted at every past price against today's), so this was a
        // genuinely reachable panic in admission control.
        uint256 own18 = _value18(certificate.totalSupply() + pendingMintCerts, px18);
        uint256 attested18 = registry.latest(address(this)).notional18;
        uint256 current = own18 > attested18 ? own18 : attested18;
        // FINDING 1 follow-on: `current + addNotional18 > max` could panic on the ADDITION once
        // `current` was allowed to be large instead of unreachable. Rearranged so the comparison
        // never adds — same predicate, and an over-cap mint gets the named CertVault_AtCapacity it
        // was always meant to get.
        if (current > max || addNotional18 > max - current) revert CertVault_AtCapacity();
    }

    /// @dev Hand a mint receipt's capacity reservation back, floored rather than checked-subtracted.
    ///      Each receipt adds its indicativeCerts exactly once and releases it exactly once, so an
    ///      underflow here would be a bug in this contract — but the two callers are settleMint and
    ///      stageRefund, and stageRefund must never revert (refundMint is gated behind it, so a
    ///      revert there would strand escrow: the Critical the two-phase refund exists to prevent).
    ///      Same clamp, and the same reasoning, as stageRefund's `posted > postedMargin`.
    function _releasePendingMint(uint256 certs) internal {
        uint256 release = certs > pendingMintCerts ? pendingMintCerts : certs;
        pendingMintCerts -= release;
    }

    /// @dev Floor a certificate amount to the venue's own representable size. `_baseAmount` is
    ///      what the venue actually receives, so anything below its granularity is a certificate
    ///      the hedge cannot express — see requestMint, which quantises before recording and
    ///      hedging so settleMint can mint exactly what went to the venue (C-1).
    function _quantiseToVenue(uint256 certAmount18) internal view returns (uint256) {
        uint256 step = 1e18 / (10 ** cfg.sizeDecimals);
        return step == 0 ? certAmount18 : (certAmount18 / step) * step;
    }

    /// @dev Shared size-decimals conversion used by _hedge, _tryHedge and rebalance()'s own
    ///      pre-check, so all three agree on exactly when an amount would floor to Lighter's
    ///      baseAmount == 0 close-all primitive (Finding 1, Task 10 review).
    /// @dev L-2: returns the value UN-NARROWED, and the uint48 narrowing now happens in the two
    ///      callers that can each handle it correctly. It used to `uint48(...)` here, unchecked,
    ///      while withdrawals in this same file use SafeCast — but a bare `SafeCast.toUint48`
    ///      HERE would have been worse than the inconsistency: this helper is the first thing
    ///      _tryHedge does, outside every try/catch it owns, so a revert in it would propagate
    ///      out of the deliberately fail-open exit path and revert forceExit — Law 2's backstop —
    ///      for an overflow. So the split: _hedge (mint/rebalance, revert-capable by design)
    ///      SafeCasts and reverts loudly rather than silently submitting a truncated order, and
    ///      _tryHedge treats out-of-range exactly like any other unplaceable close and returns
    ///      false. The zero-check in both callers still runs on this wide value, so an amount
    ///      that truncates to zero is caught before any cast, as it was before.
    /// @dev FINDING 1, third instance and the one that mattered most after _queueExit's own. This
    ///      was `certAmount18 * (10 ** cfg.sizeDecimals) / 1e18`, a CHECKED multiplication in the
    ///      first statement _tryHedge executes — outside every try/catch that helper owns, which
    ///      the NatSpec above already identifies as the reason a revert here propagates out of the
    ///      fail-open exit path and reverts forceExit. That paragraph was written about the uint48
    ///      narrowing and missed the multiplication sitting next to it.
    ///
    ///      Now total. mulDiv's 512-bit intermediate panics only when the quotient leaves uint256,
    ///      i.e. `certAmount18 * 10**sizeDecimals >= 1e18 * 2^256`; with sizeDecimals bounded at
    ///      MAX_VENUE_DECIMALS = 18 in the constructor the multiplier is at most 1e18, so that
    ///      needs certAmount18 >= 2^256 and is unreachable for a uint256. The constructor bound is
    ///      the other half of this fix and is not decoration: `10 ** cfg.sizeDecimals` panics on
    ///      its own past 78.
    function _baseAmount(uint256 certAmount18) internal view returns (uint256) {
        return Math.mulDiv(certAmount18, 10 ** cfg.sizeDecimals, 1e18);
    }

    /// @dev Submits the vault's own order through Lighter's priority queue. Market order because
    ///      the on-chain path exposes no IOC or post-only flag; price is passed as the guard band.
    ///      Refuses baseAmount == 0 (Finding 1, Task 10 review): that value is Lighter's
    ///      documented "close the entire position" primitive, not a no-op, so silently sending it
    ///      here would close the vault's whole hedge instead of doing nothing. mintInstant,
    ///      requestMint and rebalance() call this revert-capable path deliberately — an unhedged
    ///      mint must not pass silently (Law 1); closeAll() bypasses this helper entirely to reach
    ///      the primitive on purpose.
    function _hedge(uint256 certAmount18, uint256 px18, uint8 side) internal {
        uint256 base = _baseAmount(certAmount18);
        if (base == 0) revert CertVault_ZeroHedgeAmount();
        // L-2: zero-checked on the wide value first (so a truncation to exactly zero still
        // reverts CertVault_ZeroHedgeAmount, unchanged), then narrowed with SafeCast rather than
        // a bare cast. The bare cast's real hazard was never zero — it was a value above 2^48
        // wrapping to a small NON-zero one and silently submitting an order for the wrong size.
        uint48 baseAmount = SafeCast.toUint48(base);
        uint32 tickPx = oracle.toTickPrice(px18);
        lighter.createOrder(lighterAccountIndex(), cfg.marketIndex, baseAmount, tickPx, side, ORDER_TYPE_MARKET);
        _recordOrder(base, side);
    }

    /// @dev M-3: maintain the vault's own signed record of what it has asked the venue to hold.
    ///      Called from both hedge helpers, and only once an order has actually been accepted for
    ///      submission — never for one the venue refused, which is what keeps the ledger a record
    ///      of submissions rather than of attempts.
    ///
    ///      `unchecked` on purpose, and it is a Law 2 decision rather than a gas one: this runs
    ///      inside _tryHedge's success path, which is forceExit's route, and a checked signed
    ///      addition there would put an arithmetic revert back into the backstop for the sake of a
    ///      bookkeeping counter — the exact class of mistake Finding 1 is about. `base` is bounded
    ///      by type(uint48).max in both callers (SafeCast in _hedge, an explicit range check in
    ///      _tryHedge), so wrapping an int256 needs ~4e62 consecutive maximum-size orders.
    function _recordOrder(uint256 base, uint8 side) internal {
        unchecked {
            venuePositionBase =
                side == SIDE_ASK ? venuePositionBase - int256(base) : venuePositionBase + int256(base);
        }
    }

    /// @dev Fail-open counterpart to _hedge, used ONLY by the exit path (_queueExit, i.e.
    ///      requestRedeem/forceExit). forceExit is the documented Law 2 backstop — it must work
    ///      when every off-chain service is dead, the buffer is empty, the oracle is stale, and
    ///      the venue is refusing calls — so no step of placing the closing order may revert the
    ///      transaction. Two things can revert inside _hedge: oracle.toTickPrice() (an external
    ///      view call that reverts CertOracle_TickOverflow when the encoded tick is 0 or exceeds
    ///      uint32, reachable at extreme prices) and lighter.createOrder() (unguarded, can revert
    ///      for any venue reason). A third, lighter.addressToAccountIndex() via
    ///      lighterAccountIndex(), used to sit in argument position where no catch reached it —
    ///      see the comment in the body. All three are wrapped in try/catch here; any failure
    ///      returns false instead of propagating. mintInstant, requestMint and rebalance() deliberately
    ///      keep calling the revert-capable _hedge — minting and rebalancing may be gated, but
    ///      redemption may never be (Laws 2 and 3).
    function _tryHedge(uint256 certAmount18, uint256 px18, uint8 side) internal returns (bool placed) {
        uint256 base = _baseAmount(certAmount18);
        // Finding 1b (Task 10 review): baseAmount == 0 is Lighter's "close the entire position"
        // primitive, not a no-op. _queueExit already rejects certIn == 0 up front, but this stays
        // as defence in depth — nothing here may ever forward a zero to createOrder. Treat it the
        // same as any other unplaceable close: report "not placed" rather than submitting it.
        // L-2: an amount above the venue's uint48 base field is handled here rather than by
        // SafeCast, for the reason given on _baseAmount — this helper must not revert, so an
        // unrepresentable size is just another unplaceable close.
        if (base == 0 || base > type(uint48).max) return false;
        uint48 baseAmount = uint48(base);
        // THIRD unguarded read, surfaced by CRITICAL B's "re-trace forceExit end to end" and the
        // last one left in this helper. lighterAccountIndex() used to be evaluated in ARGUMENT
        // position inside the createOrder try below, and argument evaluation happens BEFORE the
        // protected call, so that try's catch does not cover it — the same class of mistake as
        // arithmetic in a try's success block (CertOracle._tryFeed) and with the same
        // consequence: it is an unguarded external view call on the venue, so a venue whose
        // addressToAccountIndex reverted (paused behind a proxy, storage layout changed by an
        // upgrade) propagated straight out of this deliberately fail-open helper and reverted
        // forceExit, the Law 2 backstop, and stageRefund with it. Reading it into a local first,
        // inside its own try, is the whole fix. _hedge is left alone on purpose: it is the
        // revert-capable path for mint and rebalance, which may be gated (Laws 2 and 3).
        uint48 accountIndex;
        try lighter.addressToAccountIndex(address(this)) returns (uint48 idx) {
            accountIndex = idx;
        } catch {
            return false;
        }
        try oracle.toTickPrice(px18) returns (uint32 tickPx) {
            try lighter.createOrder(accountIndex, cfg.marketIndex, baseAmount, tickPx, side, ORDER_TYPE_MARKET) {
                // M-3: recorded only here, in the branch where the venue actually accepted the
                // order. A refused close (the `catch` below, which is what CloseOrderNotPlaced
                // reports) must leave the ledger alone, or the vault would believe it had closed an
                // exposure it still carries — and closeAll() would then read the wrong sign off it.
                // _recordOrder is unchecked precisely so this line cannot revert inside a fail-open
                // helper; see it.
                _recordOrder(base, side);
                return true;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }

    /// @notice Deposit the target share of freshly received collateral to Lighter as margin.
    /// @dev The retained remainder is the hot buffer that serves instant redemptions. Leverage is
    ///      therefore 10_000 / targetMarginBps, capped at 2x by MIN_TARGET_MARGIN_BPS.
    function _postMargin(uint256 netCollateral) internal returns (uint256 marginPosted) {
        marginPosted = netCollateral * cfg.targetMarginBps / 10_000;
        if (marginPosted == 0) return 0;
        IERC20(cfg.collateral).forceApprove(address(lighter), marginPosted);
        lighter.deposit(address(this), cfg.collateralAssetIndex, cfg.routeType, marginPosted);
        postedMargin += marginPosted;
        emit MarginPosted(marginPosted, netCollateral - marginPosted);
    }

    /// @notice `qty18 * px18 / 1e18`, as a function that cannot revert for any uint256 inputs.
    /// @dev FINDING 1 (Law 2). THE single place this contract multiplies a quantity by a price.
    ///      Every `certIn * px18 / 1e18` and `supply * px18 / 1e18` in the file routes through it,
    ///      so there is one overflow argument to check instead of nine. See MAX_VALUATION_PX18 for
    ///      why mulDiv alone was not enough and why the clamps are economically inert.
    ///
    ///      Arithmetically identical to the plain expression for every non-overflowing input, in
    ///      both the value and the rounding direction: mulDiv floors, `*` then `/` floors, and
    ///      mulDiv's 512-bit intermediate only changes the answer where the plain form had no
    ///      answer at all. So no economics move — only the panics go.
    function _value18(uint256 qty18, uint256 px18) internal pure returns (uint256) {
        if (px18 > MAX_VALUATION_PX18) px18 = MAX_VALUATION_PX18;
        if (qty18 > MAX_VALUATION_QTY18) qty18 = MAX_VALUATION_QTY18;
        return Math.mulDiv(qty18, px18, 1e18);
    }

    function _to18(uint256 amount) internal view returns (uint256) {
        return _collateralDecimals <= 18
            ? amount * (10 ** (18 - _collateralDecimals))
            : amount / (10 ** (_collateralDecimals - 18));
    }

    function _from18(uint256 amount18) internal view returns (uint256) {
        return _collateralDecimals <= 18
            ? amount18 / (10 ** (18 - _collateralDecimals))
            : amount18 * (10 ** (_collateralDecimals - 18));
    }
}

interface ICertOracleAttester {
    function attester() external view returns (address);
}
