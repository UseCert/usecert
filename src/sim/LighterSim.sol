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

    event RequiredMarginBpsSet(uint256 previous, uint256 current);
    event MarkPriceSet(uint16 indexed marketIndex, uint256 previous, uint256 current);
    event DepositCapTicksSet(uint256 previous, uint256 current);

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
