// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {LighterCore} from "../../src/sim/LighterCore.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice The TEST front end onto `src/sim/LighterCore.sol`.
///
/// @dev Task 4 extracted every venue mechanic this file used to hold — asynchronous
///      priority-queue fills, margin enforcement with `InsufficientMargin()`, mark-to-market PnL
///      with entry-price tracking, pending balances, account registration, `depositCapTicks`
///      refusal — into `LighterCore`, which `LighterSim` also inherits. Orders still NEVER fill in
///      the calling transaction; call `settleBatch()` to fill. All of that behaviour now lives in
///      exactly one place, so the contract deployed to testnet cannot drift from the one these
///      258 tests certify.
///
///      What remains here is only what must NOT reach a deployed contract:
///
///      1. Ungated configuration setters. The real `ZkLighter` exposes no `setMarkPrice`,
///         `setRequiredMarginBps` or `setDepositCapTicks`; they exist so a test can put the venue
///         into a chosen state in one call. On `LighterSim` they would be unauthenticated knobs.
///      2. Fault injection — `shouldRevertDrain`, `shouldRevertPendingRead`,
///         `shouldRevertCreateOrder`. These construct the venue-misbehaviour states the C1 audit
///         PoCs need and have no counterpart on any real venue.
///      3. Queue introspection — `queuedOrderCount()`, `lastOrder()`. Assertion helpers.
///      4. The `_fundPending()` override that mints the shortfall a gain-drawing withdrawal needs.
///         A one-account mock has no losing counterparty, so it conjures the tokens; a simulator
///         that did the same would be easier than mainnet.
///
///      M3 note, retained because it is the reason the C1 Critical was findable at all: this mock
///      used to model NO position PnL — fills were price-agnostic and marginBalance moved only on
///      deposit/withdraw, so a position's gain never existed and no test could ever observe a
///      vault trying (and failing) to bring one home. `LighterCore` marks positions to market:
///      every fill records/updates a volume-weighted entry price, `equity()` is
///      `marginBalance + unrealisedPnl()`, and `withdraw()` fulfils against `equity()` rather than
///      against the cash balance alone.
contract MockLighter is LighterCore {
    /// @dev M1: models the venue refusing to drain an already-credited pending balance (paused
    ///      withdrawals, a rollup rule, a future guard). CertVault._sweepPending must survive it.
    error DrainRefused();
    /// @dev Models the venue's pending-balance VIEW reverting — a proxy paused behind the read, an
    ///      asset index deconfigured, an upgrade mid-flight. _sweepPending read this unguarded
    ///      until the refund fix, which meant a broken view could revert refundMint (and
    ///      claimRedeem) with a venue error while the buffer was fully funded.
    error PendingReadRefused();
    /// @dev Models the venue refusing an order outright — the exact condition CertVault._tryHedge's
    ///      fail-open catch and the CloseOrderNotPlaced event exist for. Needed to construct the
    ///      state CRITICAL A is about: a closing order that never went in leaves the vault holding
    ///      a position at zero outstanding supply, which nothing on-chain can otherwise produce
    ///      without also flattening the position it is trying to strand.
    error OrderRefused();

    /// @dev M1: when set, withdrawPendingBalance reverts DrainRefused().
    bool public shouldRevertDrain;
    /// @dev When set, getPendingBalance reverts PendingReadRefused().
    bool public shouldRevertPendingRead;
    /// @dev When set, createOrder reverts OrderRefused().
    bool public shouldRevertCreateOrder;

    constructor(IERC20 _collateral, uint16 _collateralAssetIndex, uint8 _sizeDecimals)
        LighterCore(_collateral, _collateralAssetIndex, _sizeDecimals)
    {}

    // ------------------------------------------------------- test-only configuration setters

    function setRequiredMarginBps(uint256 bps) external {
        requiredMarginBps = bps;
    }

    function setDepositCapTicks(uint256 cap) external {
        depositCapTicks = cap;
    }

    function setMarkPrice(uint16 marketIndex, uint256 px18) external {
        markPrice[marketIndex] = px18;
    }

    /// @dev Task 7, item 3. `LighterCore.settleBatch` now rejects an individual under-margined
    ///      order and continues, because reverting the whole batch was fix round 1's Critical 2 —
    ///      one account's poison order stopped every other account's settlement permanently.
    ///      `strictMode` restores the old revert-on-first-failure behaviour for the tests that pin
    ///      the margin gate AS A REVERT, which is still the sharpest available proof that the gate
    ///      is not vacuous. Ungated here, like every other knob on this test front end; owner-gated
    ///      on `LighterSim`, where it is a configuration knob a stranger must not reach.
    function setStrictMode(bool on) external {
        strictMode = on;
    }

    // ----------------------------------------------------------- test-only fault injection

    function setShouldRevertDrain(bool v) external {
        shouldRevertDrain = v;
    }

    function setShouldRevertPendingRead(bool v) external {
        shouldRevertPendingRead = v;
    }

    function setShouldRevertCreateOrder(bool v) external {
        shouldRevertCreateOrder = v;
    }

    function createOrder(
        uint48 accountIndex,
        uint16 marketIndex,
        uint48 baseAmount,
        uint32 price,
        uint8 isAsk,
        uint8 orderType
    ) public override {
        if (shouldRevertCreateOrder) revert OrderRefused();
        super.createOrder(accountIndex, marketIndex, baseAmount, price, isAsk, orderType);
    }

    function getPendingBalance(address owner, uint16 assetIndex) public view override returns (uint128) {
        if (shouldRevertPendingRead) revert PendingReadRefused();
        return super.getPendingBalance(owner, assetIndex);
    }

    function withdrawPendingBalance(address owner, uint16 assetIndex, uint128 baseAmount) public override {
        if (shouldRevertDrain) revert DrainRefused();
        super.withdrawPendingBalance(owner, assetIndex, baseAmount);
    }

    // ------------------------------------------------------------ test-only introspection

    function queuedOrderCount() external view returns (uint256) {
        return _queue.length;
    }

    function lastOrder() external view returns (uint16, uint48, uint32, uint8, uint8) {
        Order memory o = _queue[_queue.length - 1];
        return (o.marketIndex, o.baseAmount, o.price, o.isAsk, o.orderType);
    }

    // -------------------------------------------------------------------------- internals

    /// @dev A withdrawal that draws on the position's gain asks this mock for tokens no single
    ///      account ever deposited — on a real venue they are the losing counterparty's
    ///      collateral. A one-account mock has no counterparty, so the shortfall is minted here.
    ///      Without this, a genuinely-payable receipt would fail on the mock's own token balance
    ///      rather than on anything the contract under test did.
    ///
    ///      This is why the hook is a no-op on `LighterCore` and this override is a test-only
    ///      front-end concern: `LighterSim` must not be able to mint its counterparty's money.
    ///      TASK 6a: takes the balance the caller is about to need instead of reading
    ///      `_pendingTotal`, because the hook is now called BEFORE the pending total is bumped —
    ///      that reordering is what lets `_executeWithdrawal` refuse a credit it cannot back
    ///      instead of half-applying it. Reading `_pendingTotal` here would now under-mint by
    ///      exactly the amount being credited, and the mock would refuse every gain-drawing
    ///      withdrawal it is supposed to honour.
    function _fundPending(uint256 required) internal override {
        uint256 held = collateral.balanceOf(address(this));
        if (held >= required) return;
        try IMockMintable(address(collateral)).mint(address(this), required - held) {} catch {}
    }
}

interface IMockMintable {
    function mint(address to, uint256 amount) external;
}
