// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {LighterCore} from "./LighterCore.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice The deployable Lighter stand-in for Robinhood Chain testnet (chain 46630), where the
///         real venue is absent — `cast code` returns `0x` on both candidate `ZkLighter`
///         addresses, verified live on 2026-09-09.
///
/// @dev This is a THIN subclass. Every venue mechanic comes from `LighterCore`, which is the same
///      behaviour implementation `test/mocks/MockLighter.sol` runs on, so the venue semantics the
///      suite certifies are the semantics that get deployed. One behaviour implementation, two
///      front ends; this is the testnet front end.
///
///      What it adds is exactly the operator surface a *third party's* venue needs and nothing
///      else. Design Law 6 (no owner, no keeper, no pause) binds the protocol contracts in
///      `src/*.sol`; `src/sim/` is the deliberate exception, because this contract stands in for a
///      counterparty, not for UseCert. An UNGATED simulator knob is how a testnet silently
///      certifies a bad design, so:
///
///      * The three configuration knobs (`setRequiredMarginBps`, `setMarkPrice`,
///        `setDepositCapTicks`) are `onlyOwner`, each emitting before/after values.
///      * `requiredMarginBps` can be RAISED but never lowered below `VENUE_IMF_BPS`, in the
///        constructor as well as in the setter, so a misconfigured sim cannot be deployed at all.
///      * `settleBatch` fails closed on an unset mark instead of margining a position at zero.
///
///      Still deliberately absent, and still for Global Constraint 5:
///
///      * No fault injection. `shouldRevertDrain`, `shouldRevertPendingRead` and
///        `shouldRevertCreateOrder` exist to construct states for the audit PoCs and stay on
///        `MockLighter`.
///      * No `_fundPending()` override, so a withdrawal drawing on unrealised gain fails on this
///        contract's own token balance instead of minting the counterparty's collateral.
contract LighterSim is LighterCore {
    /// @dev An operator knob was called by an address that is not the owner.
    error LighterSim_OnlyOwner();
    /// @dev An initial-margin fraction below what the real venue actually requires. Accepting one
    ///      would let the simulator approve positions Robinhood Chain refuses.
    error LighterSim_MarginBelowVenueFloor();
    /// @dev `settleBatch` reached a market with no mark price. See the modifier-free guard below.
    error LighterSim_MarkPriceUnset(uint16 marketIndex);
    /// @dev A zero owner would leave the mark price permanently unset. That is fail-CLOSED given
    ///      the guard below, but it is still a bricked deployment, so reject it loudly.
    error LighterSim_OwnerIsZero();
    /// @dev `deposit(to, ...)` named an address the owner has not approved for registration. See
    ///      `depositorAllowed`.
    error LighterSim_DepositorNotAllowed(address to);

    event RequiredMarginBpsSet(uint256 previous, uint256 current);
    event MarkPriceSet(uint16 indexed marketIndex, uint256 previous, uint256 current);
    event DepositCapTicksSet(uint256 previous, uint256 current);
    event DepositorAllowedSet(address indexed depositor, bool allowed);
    /// @dev Emitted by the queue escape hatch. `accountIndex == 0` means the whole queue was purged.
    event OperatorCancelledOrders(uint48 indexed accountIndex, uint256 cancelled);

    /// @notice The initial-margin fraction floor, in bps of the resulting notional.
    ///
    /// @dev 5000 is MEASURED, NOT CHOSEN. All 57 live markets on Robinhood Chain testnet
    ///      (chain 46630) report `default_initial_margin_fraction = 5000` — 50% of
    ///      `ASSET_MARGIN_TICK = 10_000`, i.e. 2x maximum leverage — read from the venue API on
    ///      2026-09-09 and recorded in the execution plan's verified-parameters table.
    ///
    ///      This is a FLOOR rather than a default because Lighter's own foreign testnet reports
    ///      500-666 for the same field. Someone reading that number off the wrong deployment and
    ///      configuring the simulator with it would make this contract approve positions at 15-20x
    ///      where the target venue permits 2x, and every test in the suite would stay green.
    ///      Raising the requirement makes the simulator harder than the venue, which is the safe
    ///      direction and is allowed. Lowering it below the venue's own requirement is Global
    ///      Constraint 5's Critical case, so it is made impossible rather than discouraged.
    uint256 public constant VENUE_IMF_BPS = 5_000;

    /// @notice The operator of the simulated venue. Immutable: there is no transfer path, because a
    ///         transferable owner is one more thing that can go wrong on a disposable testnet
    ///         artefact. Redeploy instead.
    address public immutable owner;

    /// @notice Addresses the owner has approved to hold an account on this simulator.
    ///
    /// @dev FIX ROUND 1, CRITICAL 1 — and it is NOT VENUE-FAITHFUL. The real venue registers
    ///      anyone who deposits; this one registers only what the operator approves.
    ///
    ///      Why it is here anyway. Task 5 bound every account-scoped call to its caller, which
    ///      closed the drain for an *unregistered* attacker. It did not close it for one who
    ///      registers first, and registering was free: `deposit(self, _, _, 0)` is a zero-value
    ///      `transferFrom`, which OpenZeppelin permits with no allowance and no balance, so the
    ///      caller got an index and `_requireCallerOwnsAccount` was then satisfied. `withdraw`'s
    ///      ceiling is `equity()`, which is GLOBAL — `marginBalance` and `positionBase` are not
    ///      per-account — so a self-registered address with zero collateral could take every
    ///      depositor's balance. Reproduced against this artefact before this mapping existed; see
    ///      `test/sim/DrainPoC.t.sol`.
    ///
    ///      Why this direction is permitted. Global Constraint 5 forbids a simulator that is EASIER
    ///      than mainnet; this one is HARDER — it refuses registrations the venue would accept, and
    ///      refuses nothing the venue refuses. A vault certified against this contract is certified
    ///      against a strictly more restrictive counterparty than the one it will meet, so no
    ///      approval it earns here is one the venue would withhold. That is the direction Global
    ///      Constraint 5 explicitly allows.
    ///
    ///      What it actually buys. On the single-vault testnet deployment Task 9 performs, the
    ///      approved set is `{vault}`. That reduces the account set to one, which closes Critical 1
    ///      (no attacker account can exist to name) AND Critical 2's entry condition (no attacker
    ///      account can queue the poison order) at once.
    ///
    ///      SIMULATOR-ONLY, AND INTERIM. This restriction has no counterpart on the real venue and
    ///      must never be read as modelling one. Task 7 supersedes it with per-account collateral
    ///      isolation, which makes an open registration harmless rather than merely impossible —
    ///      at which point this mapping should be deleted, not kept as defence in depth, because
    ///      keeping it would leave the simulator permanently diverged from the venue on who may
    ///      hold an account.
    ///
    ///      Deliberately on `LighterSim` and NOT on `LighterCore`: `MockLighter` must stay
    ///      unrestricted so the existing suite runs against the venue's real registration model.
    mapping(address => bool) public depositorAllowed;

    /// @param _requiredMarginBps The initial-margin fraction to run with. Must be >=
    ///        `VENUE_IMF_BPS`; pass `VENUE_IMF_BPS` to match the live venue exactly.
    constructor(
        IERC20 _collateral,
        uint16 _collateralAssetIndex,
        uint8 _sizeDecimals,
        uint256 _requiredMarginBps,
        address _owner
    ) LighterCore(_collateral, _collateralAssetIndex, _sizeDecimals) {
        if (_owner == address(0)) revert LighterSim_OwnerIsZero();
        // Item 4: the floor is enforced at construction as well as in the setter, so there is no
        // window — not even one block — in which the deployed simulator is more permissive than the
        // venue it stands in for.
        if (_requiredMarginBps < VENUE_IMF_BPS) revert LighterSim_MarginBelowVenueFloor();
        owner = _owner;
        requiredMarginBps = _requiredMarginBps;
        emit RequiredMarginBpsSet(0, _requiredMarginBps);
    }

    // ------------------------------------------------------------------ gated operator surface

    function setRequiredMarginBps(uint256 bps) external onlyOwner {
        if (bps < VENUE_IMF_BPS) revert LighterSim_MarginBelowVenueFloor();
        uint256 previous = requiredMarginBps;
        requiredMarginBps = bps;
        emit RequiredMarginBpsSet(previous, bps);
    }

    function setMarkPrice(uint16 marketIndex, uint256 px18) external onlyOwner {
        uint256 previous = markPrice[marketIndex];
        markPrice[marketIndex] = px18;
        emit MarkPriceSet(marketIndex, previous, px18);
    }

    function setDepositCapTicks(uint256 cap) external onlyOwner {
        uint256 previous = depositCapTicks;
        depositCapTicks = cap;
        emit DepositCapTicksSet(previous, cap);
    }

    /// @notice Approve, or revoke, an address's permission to hold an account on this simulator.
    /// @dev See `depositorAllowed` for why a registration allowlist exists on a contract that
    ///      stands in for a venue which registers anyone, and why Task 7 removes it.
    ///
    ///      Revoking does NOT unregister an already-registered address: `addressToAccountIndex` is
    ///      on the core and is the venue's own state. Revocation only stops further deposits to
    ///      that address. The escape hatch below is what deals with an account that already exists
    ///      and is misbehaving.
    function setDepositorAllowed(address depositor, bool allowed) external onlyOwner {
        depositorAllowed[depositor] = allowed;
        emit DepositorAllowedSet(depositor, allowed);
    }

    // -------------------------------------------------------------- gated registration

    /// @notice Post collateral as margin for `to`, registering `to` if it is not registered yet.
    /// @dev Fix round 1, Critical 1. `to` must be owner-approved. The amount check that made
    ///      registration free rather than merely open lives on `LighterCore` alongside the rest of
    ///      the venue mechanics; this override adds only the allowlist, which is simulator-only.
    function deposit(address to, uint16 assetIndex, uint8 routeType, uint256 amount)
        public
        payable
        virtual
        override
    {
        if (!depositorAllowed[to]) revert LighterSim_DepositorNotAllowed(to);
        super.deposit(to, assetIndex, routeType, amount);
    }

    // ------------------------------------------------------------- stuck-queue escape hatch

    /// @notice Drop every queued order belonging to `accountIndex`, as the operator.
    ///
    /// @dev FIX ROUND 1, CRITICAL 2 — a liveness escape hatch, and an INTERIM one.
    ///
    ///      `settleBatch` refuses a batch as a WHOLE: on `InsufficientMargin` in
    ///      `LighterCore.settleBatch`, and on the `LighterSim_MarkPriceUnset` pre-pass above. One
    ///      unsettleable order therefore blocks every other account's fills, and Task 5's
    ///      per-account `cancelAllOrders` binding means only that order's own account can withdraw
    ///      it. An account with zero collateral queueing one oversized market order made settlement
    ///      revert for everyone — including the vault and the owner — permanently, with no operator
    ///      path to clear it and no way back short of redeploying. `requiredMarginBps` can only be
    ///      raised, so it is no help either. Reproduced in `test/sim/DrainPoC.t.sol` before this
    ///      function existed; Task 9's `BatchAdvancer` would have reverted forever.
    ///
    ///      This is ADDITIONAL, not a relaxation: `cancelAllOrders` keeps its per-account scoping
    ///      for every non-owner caller, and this path is reachable only by `owner`. It also has no
    ///      counterpart on the real venue, so — like the allowlist — it errs in the direction of a
    ///      more privileged, more restrictive counterparty rather than a more permissive one.
    ///
    ///      TASK 7 OWNS THE STRUCTURAL FIX: `settleBatch` rejecting an individual order and
    ///      continuing rather than reverting wholesale, at which point a stuck queue cannot form
    ///      and this hatch should go.
    function ownerCancelAccountOrders(uint48 accountIndex) external onlyOwner {
        emit OperatorCancelledOrders(accountIndex, _cancelOrdersOf(accountIndex));
    }

    /// @notice Drop the entire queue, as the operator. The blunt instrument, for a queue that is
    ///         stuck for a reason the operator cannot attribute to one account.
    /// @dev Same rationale as `ownerCancelAccountOrders`. Emitted with `accountIndex == 0`, which
    ///      is never a real account index, so a log reader can tell a purge from a scoped drop.
    function ownerPurgeQueue() external onlyOwner {
        uint256 cancelled = _queue.length;
        delete _queue;
        emit OperatorCancelledOrders(0, cancelled);
    }

    // ---------------------------------------------------------------------- fail-closed settle

    /// @notice Fill the queued batch, refusing outright to settle a market whose mark is unset.
    ///
    /// @dev Items 3 and 8. `markPrice` defaults to 0 for every market, and at a zero mark the
    ///      simulator is not merely missing a margin check — the whole mark-to-market layer is
    ///      DEAD:
    ///
    ///        * `settleBatch`'s notional is `|position| * 0`, so `requiredMargin18` is 0 and the
    ///          `InsufficientMargin` gate passes vacuously for any size at any leverage;
    ///        * `_applyFill` records `entryPrice = 0`, and `_pnl18` early-returns on `entry == 0`,
    ///          so `unrealisedPnl()` is permanently 0 and `equity() == marginBalance`.
    ///
    ///      A deploy script that forgets `setMarkPrice` therefore looks completely clean while
    ///      certifying a vault against a venue with no margin requirement and no PnL. That layer
    ///      exists because unmodelled PnL is precisely what hid a Critical in this project's
    ///      external audit; without this guard the deployed artefact sits in the same epistemic
    ///      state that produced that finding.
    ///
    ///      The guard checks every queued order's market, not only the ones that would increase a
    ///      position and reach the margin branch. That is the conservative reading and it is the
    ///      one the `entryPrice = 0` observation above requires: a decrease settled at a zero mark
    ///      still corrupts the entry-price book. It is a pre-pass rather than an in-loop check so
    ///      the batch is refused as a whole.
    ///
    ///      This override is on `LighterSim` and NOT on `LighterCore` on purpose.
    ///      `test/mocks/MockLighter.t.sol` deliberately settles batches with no mark set — see
    ///      `test_orderDoesNotFillUntilBatchSettles` and `test_zeroBaseAmountClosesEntirePosition`,
    ///      which pin the asynchronous-fill and close-all primitives and have no business caring
    ///      about a price. A core-level guard would force marks into tests that are not about
    ///      marks; a front-end override binds only the artefact that actually gets deployed.
    /// @dev Stays `virtual`: Task 6 makes settlement asynchronous and needs to extend this.
    function settleBatch() public virtual override {
        uint256 n = _queue.length;
        for (uint256 i = 0; i < n; ++i) {
            uint16 m = _queue[i].marketIndex;
            if (markPrice[m] == 0) revert LighterSim_MarkPriceUnset(m);
        }
        super.settleBatch();
    }

    // -------------------------------------------------------------------------------- internals

    modifier onlyOwner() {
        if (msg.sender != owner) revert LighterSim_OnlyOwner();
        _;
    }
}
