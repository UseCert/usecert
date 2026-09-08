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

    event Minted(address indexed user, uint256 amountIn, uint256 certOut, uint256 px18, uint256 fee);
    event MintRequested(uint256 indexed receiptId, address indexed user, uint256 amountIn);
    event MintSettled(uint256 indexed receiptId, uint256 certOut, uint256 fillPx18);
    event MarginPosted(uint256 marginPosted, uint256 retainedAsHotBuffer);
    event MarginWithdrawRequested(uint256 amount, uint256 postedMarginAfter);
    event MarginWithdrawFailed(uint256 amount);

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

    struct MintReceipt {
        address user;
        uint256 escrow;
        bool settled;
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

    constructor(Deps memory d, VaultConfig memory c, string memory name_, string memory symbol_) {
        lighter = ILighter(d.lighter);
        oracle = ICertOracle(d.oracle);
        registry = ISolvencyRegistry(d.registry);
        capacity = ICapacityOracle(d.capacity);
        governance = d.governance;
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
        mintReceipts[receiptId] = MintReceipt({user: msg.sender, escrow: amountIn - fee, settled: false});

        _postMargin(amountIn - fee);
        _hedge(indicative, px18, SIDE_BID);
        emit MintRequested(receiptId, msg.sender, amountIn);
    }

    /// @notice Mint at the price actually filled, so the vault carries no execution risk on
    ///         large mints. Permissionless — the fill price is checkable against the attestation.
    function settleMint(uint256 receiptId, uint256 fillPx18) external {
        MintReceipt storage r = mintReceipts[receiptId];
        if (r.user == address(0) || r.settled) revert CertVault_BadReceipt();
        if (fillPx18 == 0) revert CertVault_FillPriceOutOfBand();

        (uint256 refPx,) = oracle.pxUnguarded();
        uint256 diff = fillPx18 > refPx ? fillPx18 - refPx : refPx - fillPx18;
        if (refPx == 0 || diff * 10_000 / refPx > cfg.settleBandBps) revert CertVault_FillPriceOutOfBand();

        r.settled = true;

        uint256 certOut = _to18(r.escrow) * 1e18 / fillPx18;
        _requireCapacity(certOut * fillPx18 / 1e18);
        certificate.mint(r.user, certOut);
        emit MintSettled(receiptId, certOut, fillPx18);
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
        (uint256 px18,) = oracle.pxUnguarded();
        uint256 gross18 = certIn * px18 / 1e18;
        uint256 fee18 = gross18 * cfg.redeemFeeBps / 10_000;
        uint256 owed18 = gross18 - fee18;

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
        if (fromMargin > 0) {
            // Computed before the try, not inside it: a silently truncated withdrawal amount
            // would be worse than a revert, and this is unreachable below ~$18.4 trillion.
            uint64 fromMargin64 = SafeCast.toUint64(fromMargin);
            // forceExit is the Law 2 backstop and must work even if the venue itself refuses the
            // withdrawal (withdrawals disabled, deposit cap, or a future rule) — so this call must
            // never be able to revert the transaction. The burn and the receipt stand regardless;
            // claimRedeem pays from the hot buffer when the margin round-trip has not returned.
            try lighter.withdraw(lighterAccountIndex(), cfg.collateralAssetIndex, cfg.routeType, fromMargin64) {
                emit MarginWithdrawRequested(fromMargin, postedMargin);
            } catch {
                // Restore the counter: without this a refused withdrawal would permanently
                // understate postedMargin and shrink every later holder's share.
                postedMargin += fromMargin;
                emit MarginWithdrawFailed(fromMargin);
            }
        }

        if (isForce) emit ForceExited(receiptId, msg.sender, certIn);
        else emit RedeemRequested(receiptId, msg.sender, certIn, expiresAt);
    }

    /// @notice Pull-payment once the queued exit is ready. Callable by anyone on the holder's
    ///         behalf; always pays the receipt's owner, never msg.sender. Reads nothing but the
    ///         receipt itself and the vault's own balance — no buffer, capacity or oracle gate.
    function claimRedeem(uint256 receiptId) external returns (uint256 amountOut) {
        RedeemReceipt storage r = redeemReceipts[receiptId];
        if (r.user == address(0) || r.paid) revert CertVault_NothingToClaim();

        uint128 pending = lighter.getPendingBalance(address(this), cfg.collateralAssetIndex);
        if (pending > 0) {
            lighter.withdrawPendingBalance(address(this), cfg.collateralAssetIndex, pending);
        }

        amountOut = _from18(r.owed18);
        r.paid = true;
        IERC20(cfg.collateral).safeTransfer(r.user, amountOut);
        emit RedeemClaimed(receiptId, amountOut);
    }

    /// @notice Wind-down: close the entire position using Lighter's baseAmount == 0 primitive.
    ///         The only governance-gated function in this contract (Law 6: no privileged trading
    ///         key otherwise — this is wind-down, not routine trading).
    function closeAll() external {
        if (msg.sender != governance) revert CertVault_OnlyGovernance();
        (uint256 px18,) = oracle.pxUnguarded();
        lighter.createOrder(
            lighterAccountIndex(), cfg.marketIndex, 0, oracle.toTickPrice(px18), SIDE_ASK, ORDER_TYPE_MARKET
        );
    }

    // ---------------------------------------------------------------- solvency & rebalance

    error CertVault_InBand();
    error CertVault_OnlyAttester();

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
    function rebalance() external {
        (Solvency memory s, uint256 required, uint256 px18) = _solvency();

        uint256 lo = 10_000 - DELTA_BAND_BPS;
        uint256 hi = 10_000 + DELTA_BAND_BPS;
        if (s.deltaBps >= lo && s.deltaBps <= hi) revert CertVault_InBand();

        bool underHedged = s.notional18 < required;
        uint256 gap18 = underHedged ? required - s.notional18 : s.notional18 - required;
        if (gap18 > MAX_REBALANCE_NOTIONAL_18) gap18 = MAX_REBALANCE_NOTIONAL_18;

        uint256 certEquivalent = gap18 * 1e18 / px18;
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

    function _requireCapacity(uint256 addNotional18) internal view {
        uint256 max = capacity.maxNotional18(address(this), buffer.capacity18(address(this)));
        uint256 current = registry.latest(address(this)).notional18;
        if (current + addNotional18 > max) revert CertVault_AtCapacity();
    }

    /// @dev Submits the vault's own order through Lighter's priority queue. Market order because
    ///      the on-chain path exposes no IOC or post-only flag; price is passed as the guard band.
    function _hedge(uint256 certAmount18, uint256 px18, uint8 side) internal {
        uint48 baseAmount = uint48(certAmount18 * (10 ** cfg.sizeDecimals) / 1e18);
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
        uint48 baseAmount = uint48(certAmount18 * (10 ** cfg.sizeDecimals) / 1e18);
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
