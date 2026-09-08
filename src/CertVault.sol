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
    ///      so the permissionless recallMargin() / _sweepPending() / seedBuffer trio can each
    ///      create the funding condition. That last clause is the whole point: the previous shape
    ///      of this function reallocated and paid atomically, so the reallocation was rolled back
    ///      by the very revert that made it necessary and no external call could ever unstick the
    ///      escrow. See stageRefund().
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
    ///      records whether the closing order for the unsettled mint's hedge actually went in,
    ///      since that step is fail-open and must never be silently lost when it does not.
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
    ///      is the certificate amount requestMint actually hedged, recorded so a refund can close
    ///      exactly that exposure rather than guessing it back out of price at refund time (the
    ///      price will have moved, and the hedge was sized at the request price).
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

    /// @notice Total collateral owed to queued redemption receipts that have not yet been paid.
    /// @dev C1 (final review wave): the number recallMargin() sizes its REQUEST off. It is
    ///      deliberately not the same quantity as marginPendingRecall: that one is the pro-rata
    ///      share of the deposited cost basis, which is the right allocation ledger BETWEEN
    ///      HOLDERS (it keeps them fair to each other and can never exceed what was posted), but
    ///      it is the wrong size for the request, because what a receipt owes grows with price
    ///      while basis does not. Increased in _queueExit, decreased in claimRedeem. In collateral
    ///      units, floored on subtraction — an over-large sweep must never underflow it.
    uint256 public totalOwedOutstanding;

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
        _collateralDecimals = IERC20Metadata(c.collateral).decimals();

        certificate = new Certificate(name_, symbol_, address(this));
        buffer = new BufferBook(address(this), 200);
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

    /// @notice Pre-fund the buffer. Permissionless: it can only ever add value to the vault.
    function seedBuffer(uint256 amount) external {
        IERC20(cfg.collateral).safeTransferFrom(msg.sender, address(this), amount);
        buffer.accrue(address(this), int256(_to18(amount)));
    }

    // ---------------------------------------------------------------- mint

    function mintInstant(uint256 amountIn) external returns (uint256 certOut) {
        if (amountIn == 0) revert CertVault_ZeroAmount();
        if (!bootstrapped) revert CertVault_NotBootstrapped();
        if (!oracle.mintAllowed()) revert CertVault_MintPaused();

        uint256 px18 = oracle.px();
        uint256 fee = amountIn * cfg.mintFeeBps / 10_000;
        uint256 net18 = _to18(amountIn - fee);
        certOut = net18 * 1e18 / px18;

        uint256 notional18 = certOut * px18 / 1e18;
        if (notional18 > cfg.instantCap18) revert CertVault_AboveInstantCap();
        _requireCapacity(notional18);

        IERC20(cfg.collateral).safeTransferFrom(msg.sender, address(this), amountIn);
        certificate.mint(msg.sender, certOut);
        _postMargin(amountIn - fee);
        _hedge(certOut, px18, SIDE_BID);

        emit Minted(msg.sender, amountIn, certOut, px18, fee);
    }

    function requestMint(uint256 amountIn) external returns (uint256 receiptId) {
        if (amountIn == 0) revert CertVault_ZeroAmount();
        if (!bootstrapped) revert CertVault_NotBootstrapped();
        if (!oracle.mintAllowed()) revert CertVault_MintPaused();

        uint256 px18 = oracle.px();
        uint256 fee = amountIn * cfg.mintFeeBps / 10_000;
        uint256 net18 = _to18(amountIn - fee);
        uint256 indicative = net18 * 1e18 / px18;
        uint256 notional18 = indicative * px18 / 1e18;
        if (notional18 <= cfg.instantCap18) revert CertVault_BelowInstantCap();
        _requireCapacity(notional18);

        IERC20(cfg.collateral).safeTransferFrom(msg.sender, address(this), amountIn);
        receiptId = _nextReceiptId++;
        mintReceipts[receiptId] = MintReceipt({
            user: msg.sender,
            escrow: amountIn - fee,
            settled: false,
            requestPx18: px18,
            requestedAt: uint64(block.timestamp),
            refundStaged: false,
            // Step 1 of the refund fix: record exactly what the _hedge below is about to open, so
            // stageRefund can close that same exposure. Without it a refund left the vault long
            // against certificates that were never minted (measured: totalSupply 0 against a
            // 1,403,641-tick position on a 50k mint), breaching Law 1 until rebalance() — a
            // bounded, attester-dependent trim — happened to grind it down.
            indicativeCerts: indicative
        });

        _postMargin(amountIn - fee);
        _hedge(indicative, px18, SIDE_BID);
        emit MintRequested(receiptId, msg.sender, amountIn);
    }

    /// @notice Mint at the price actually filled, so the vault carries no execution risk on
    ///         large mints. Permissionless — the fill price is checkable against the attestation.
    /// @dev C3: the band is measured against the receipt's OWN requestPx18, not against
    ///      oracle.pxUnguarded() at settle time. Banding against the settle-time price made the
    ///      band vacuous over time: the reference itself drifts with the market, so a fill
    ///      arbitrarily far from what the user requested at is "in band" as long as it tracks
    ///      wherever the price has since gone. Paired with settleWindow below, so a receipt
    ///      cannot sit indefinitely waiting for a favourable moment.
    function settleMint(uint256 receiptId, uint256 fillPx18) external {
        MintReceipt storage r = mintReceipts[receiptId];
        if (r.user == address(0) || r.settled) revert CertVault_BadReceipt();
        if (block.timestamp > uint256(r.requestedAt) + settleWindow) revert CertVault_SettleWindowExpired();
        if (fillPx18 == 0) revert CertVault_FillPriceOutOfBand();

        uint256 refPx = r.requestPx18;
        uint256 diff = fillPx18 > refPx ? fillPx18 - refPx : refPx - fillPx18;
        if (refPx == 0 || diff * 10_000 / refPx > cfg.settleBandBps) revert CertVault_FillPriceOutOfBand();

        r.settled = true;

        uint256 certOut = _to18(r.escrow) * 1e18 / fillPx18;
        _requireCapacity(certOut * fillPx18 / 1e18);
        certificate.mint(r.user, certOut);
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
    ///      no balances and performs no transfer, so it always succeeds, and it can therefore be
    ///      staged long before the vault can afford the payout.
    ///
    ///      Law 2: nothing here can hold user value behind it. refundMint's
    ///      CertVault_RefundNotStaged is escaped by this call, which anyone may make; this call's
    ///      own reverts are "already staged" and "window still open", and in the latter case
    ///      settleMint is still the live path.
    function stageRefund(uint256 receiptId) external {
        MintReceipt storage r = mintReceipts[receiptId];
        if (r.user == address(0) || r.settled) revert CertVault_BadReceipt();
        if (block.timestamp <= uint256(r.requestedAt) + settleWindow) revert CertVault_SettleWindowNotExpired();
        if (r.refundStaged) revert CertVault_BadReceipt();

        r.refundStaged = true;

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

        // Close the hedge this unsettled mint opened. requestMint hedged r.indicativeCerts at the
        // request price; the certificates were never minted, so leaving it open makes the vault
        // long against nothing (Law 1). Fail-open, using the exit path's _tryHedge and not _hedge:
        // an unplaceable close must not block the refund, the event below records that it did not
        // go in, and rebalance() remains the backstop.
        bool placed = false;
        if (r.indicativeCerts > 0) {
            (uint256 px18,) = oracle.pxUnguarded();
            placed = _tryHedge(r.indicativeCerts, px18, SIDE_ASK);
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
            // into marginPendingRecall, and recallMargin(), _sweepPending() and seedBuffer are all
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
        uint256 gross18 = certIn * px18 / 1e18;
        uint256 fee18 = gross18 * cfg.redeemFeeBps / 10_000;
        amountOut = _from18(gross18 - fee18);

        if (hotBuffer() < amountOut) revert CertVault_UseQueuedRedeem();

        certificate.burn(msg.sender, certIn);
        _hedge(certIn, px18, SIDE_ASK);
        IERC20(cfg.collateral).safeTransfer(msg.sender, amountOut);

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
        uint256 gross18 = certIn * px18 / 1e18;
        uint256 fee18 = gross18 * cfg.redeemFeeBps / 10_000;
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

        // Fail-open (Law 2): forceExit is the last-resort backstop and must survive even when the
        // closing order itself cannot be placed. requestRedeem shares this path deliberately —
        // both queued-exit entry points must be equally unstoppable. See _tryHedge.
        if (!_tryHedge(certIn, px18, SIDE_ASK)) emit CloseOrderNotPlaced(certIn);

        // Price-independent by construction: certIn <= supplyBefore always (the burn above would
        // have reverted otherwise), so this holder's share of postedMargin can never exceed what
        // was actually posted — unlike sizing off the current oracle price, which grows with it.
        uint256 fromMargin = supplyBefore == 0 ? 0 : postedMargin * certIn / supplyBefore;
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
    function claimRedeem(uint256 receiptId) external returns (uint256 amountOut) {
        RedeemReceipt storage r = redeemReceipts[receiptId];
        if (r.user == address(0) || r.paid) revert CertVault_NothingToClaim();

        _sweepPending();

        amountOut = _from18(r.owed18);
        if (hotBuffer() < amountOut) revert CertVault_AwaitingSettlement();

        // C1: retire the obligation before paying it, so recallMargin() stops asking for it.
        // Floored, never checked-subtracted: r.owed18 is fixed at queue time while
        // totalOwedOutstanding is a running counter, and an underflow here would revert a
        // payout — a Law 2 breach in exchange for accounting tidiness.
        uint256 applied = amountOut < totalOwedOutstanding ? amountOut : totalOwedOutstanding;
        totalOwedOutstanding -= applied;

        r.paid = true;
        IERC20(cfg.collateral).safeTransfer(r.user, amountOut);
        emit RedeemClaimed(receiptId, amountOut);
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
        // reading — see test_recallMarginRequestsTheStagedRefundShare / ..._DoesNotRequestUnstaged.
        // Always recall at least the allocated basis; ask for the shortfall when it is larger,
        // because the venue fulfils min(request, available) and _sweepPending reconciles what
        // actually arrives.
        uint256 want = need > marginPendingRecall ? need : marginPendingRecall;
        // Clamp to the venue's own per-asset withdrawal ceiling: over-requesting is safe, but a
        // request above that cap reverts on-chain rather than being silently trimmed in-rollup.
        if (want > venueWithdrawCap) want = venueWithdrawCap;
        if (want == 0) return;

        // A request above uint64 is unreachable below ~$18.4T; revert loudly rather than truncate.
        uint64 amount = SafeCast.toUint64(want);

        try lighter.withdraw(lighterAccountIndex(), cfg.collateralAssetIndex, cfg.routeType, amount) {
            emit MarginRecallRequested(want);
        } catch {
            // Venue refused at request time (withdrawals disabled, deposit cap, future rule).
            // marginPendingRecall is intentionally NOT reduced — the caller may retry.
        }
    }

    /// @notice Wind-down: close the entire position using Lighter's baseAmount == 0 primitive.
    ///         The only governance-gated function in this contract (Law 6: no privileged trading
    ///         key otherwise — this is wind-down, not routine trading).
    function closeAll() external {
        if (msg.sender != governance) revert CertVault_OnlyGovernance();
        (uint256 px18,) = oracle.pxUnguarded();
        // Deliberately NOT routed through _hedge/_tryHedge: those now refuse baseAmount == 0
        // (Finding 1, Task 10 review). closeAll() is the one legitimate caller of Lighter's
        // baseAmount == 0 "close the entire position" primitive, so it calls createOrder directly
        // with a literal 0 here, bypassing the zero-amount guards on purpose.
        lighter.createOrder(
            lighterAccountIndex(), cfg.marketIndex, 0, oracle.toTickPrice(px18), SIDE_ASK, ORDER_TYPE_MARKET
        );
        // C1: a wind-down must also repatriate. Without this, closeAll() closed the position and
        // withdrew nothing, leaving whatever the venue had already released sitting in the
        // pending balance while the receipts it belongs to went unpaid.
        _sweepPending();
    }

    // ---------------------------------------------------------------- solvency & rebalance

    error CertVault_InBand();
    error CertVault_OnlyAttester();
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

    struct Solvency {
        uint256 supply;
        uint256 notional18;
        uint256 margin18;
        int256 buffer18;
        uint256 deltaBps;
        uint64 provenAtBatch;
        uint256 ageSec;
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
        s.buffer18 = buffer.balance18(address(this));
        s.provenAtBatch = a.batchId;
        s.ageSec = registry.ageSec(address(this));

        required = s.supply * px18 / 1e18;
        // required == 0 (no supply, or px18 == 0) means there is nothing to hedge: report fully
        // at-target (10_000 bps == 100%) rather than dividing by zero.
        s.deltaBps = required == 0 ? 10_000 : a.notional18 * 10_000 / required;
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

        uint256 lo = 10_000 - DELTA_BAND_BPS;
        uint256 hi = 10_000 + DELTA_BAND_BPS;
        if (s.deltaBps >= lo && s.deltaBps <= hi) revert CertVault_InBand();

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
    function _sweepPending() internal returns (uint256 swept) {
        uint128 pending = lighter.getPendingBalance(address(this), cfg.collateralAssetIndex);
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
        emit MarginRecalled(applied, marginPendingRecall);
    }

    function _requireCapacity(uint256 addNotional18) internal view {
        uint256 max = capacity.maxNotional18(address(this), buffer.capacity18(address(this)));
        uint256 current = registry.latest(address(this)).notional18;
        if (current + addNotional18 > max) revert CertVault_AtCapacity();
    }

    /// @dev Shared size-decimals conversion used by _hedge, _tryHedge and rebalance()'s own
    ///      pre-check, so all three agree on exactly when an amount would floor to Lighter's
    ///      baseAmount == 0 close-all primitive (Finding 1, Task 10 review).
    function _baseAmount(uint256 certAmount18) internal view returns (uint48) {
        return uint48(certAmount18 * (10 ** cfg.sizeDecimals) / 1e18);
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
        uint48 baseAmount = _baseAmount(certAmount18);
        if (baseAmount == 0) revert CertVault_ZeroHedgeAmount();
        uint32 tickPx = oracle.toTickPrice(px18);
        lighter.createOrder(lighterAccountIndex(), cfg.marketIndex, baseAmount, tickPx, side, ORDER_TYPE_MARKET);
    }

    /// @dev Fail-open counterpart to _hedge, used ONLY by the exit path (_queueExit, i.e.
    ///      requestRedeem/forceExit). forceExit is the documented Law 2 backstop — it must work
    ///      when every off-chain service is dead, the buffer is empty, the oracle is stale, and
    ///      the venue is refusing calls — so no step of placing the closing order may revert the
    ///      transaction. Two things can revert inside _hedge: oracle.toTickPrice() (an external
    ///      view call that reverts CertOracle_TickOverflow when the encoded tick is 0 or exceeds
    ///      uint32, reachable at extreme prices) and lighter.createOrder() (unguarded, can revert
    ///      for any venue reason). Both are wrapped in try/catch here; either failure returns
    ///      false instead of propagating. mintInstant, requestMint and rebalance() deliberately
    ///      keep calling the revert-capable _hedge — minting and rebalancing may be gated, but
    ///      redemption may never be (Laws 2 and 3).
    function _tryHedge(uint256 certAmount18, uint256 px18, uint8 side) internal returns (bool placed) {
        uint48 baseAmount = _baseAmount(certAmount18);
        // Finding 1b (Task 10 review): baseAmount == 0 is Lighter's "close the entire position"
        // primitive, not a no-op. _queueExit already rejects certIn == 0 up front, but this stays
        // as defence in depth — nothing here may ever forward a zero to createOrder. Treat it the
        // same as any other unplaceable close: report "not placed" rather than submitting it.
        if (baseAmount == 0) return false;
        try oracle.toTickPrice(px18) returns (uint32 tickPx) {
            try lighter.createOrder(lighterAccountIndex(), cfg.marketIndex, baseAmount, tickPx, side, ORDER_TYPE_MARKET)
            {
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
