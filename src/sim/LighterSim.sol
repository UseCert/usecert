// SPDX-License-Identifier: MIT
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
///      * `settleBatch` fails closed on an unset mark instead of margining a position at zero,
///        and (Task 7) is callable only by the owner or a nominated `keeper`.
///      * `strictMode` and the registration allowlist are `onlyOwner` too.
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
    /// @dev Task 7, item 2. `settleBatch` was called by neither the owner nor the keeper.
    ///
    ///      Leaving settlement permissionless was defensible while there was a single global
    ///      position and `setMarkPrice` was owner-only: a caller timing a fill had no counterparty
    ///      leg to profit from. Task 7 gives accounts SEPARATE positions, and at that point a
    ///      caller choosing which block — and therefore which mark — someone else's queued order
    ///      fills at is a real griefing vector against that account. Rate-limiting was considered
    ///      and rejected: it adds a liveness hazard for no gain.
    error LighterSim_OnlyOwnerOrKeeper();
    /// @dev Task 7, item 5. `ownerCancelAccountOrders(0)` is refused because `accountIndex == 0` is
    ///      the reserved `OperatorCancelledOrders` topic for a whole-queue purge, and index 0 is
    ///      never a real account. Without this, a scoped drop of the (non-existent) account 0 would
    ///      emit an indexed topic indistinguishable from a real purge.
    error LighterSim_AccountIndexZeroIsReservedForPurge();

    event RequiredMarginBpsSet(uint256 previous, uint256 current);
    event MarkPriceSet(uint16 indexed marketIndex, uint256 previous, uint256 current);
    event DepositCapTicksSet(uint256 previous, uint256 current);
    /// @dev Task 8, item 2. The venue's deposit granularity. See `setDepositTickSize`.
    event DepositTickSizeSet(uint256 previous, uint256 current);
    event DepositorAllowedSet(address indexed depositor, bool allowed);
    /// @dev Emitted by the queue escape hatch. `accountIndex == 0` means the whole queue was
    ///      purged, and Task 7's `LighterSim_AccountIndexZeroIsReservedForPurge` is what makes that
    ///      convention TRUE rather than merely documented.
    event OperatorCancelledOrders(uint48 indexed accountIndex, uint256 cancelled);
    /// @dev Task 7, item 2. The address allowed to settle batches alongside the owner.
    event KeeperSet(address indexed previous, address indexed current);
    /// @dev Task 7, item 3. `settleBatch`'s compatibility switch. See `LighterCore.strictMode`.
    event StrictModeSet(bool previous, bool current);

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
    ///      ceiling WAS `equity()`, which WAS GLOBAL — `marginBalance` and `positionBase` were not
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
    ///      What it actually buys. On the single-vault testnet deployment Task 10 performs, the
    ///      approved set is `{vault}`. That reduces the account set to one, which closes Critical 1
    ///      (no attacker account can exist to name) AND Critical 2's entry condition (no attacker
    ///      account can queue the poison order) at once.
    ///
    ///      SIMULATOR-ONLY. This restriction has no counterpart on the real venue and must never be
    ///      read as modelling one.
    ///
    ///      TASK 7 REWROTE THE NOTE THAT USED TO STAND HERE, and the rewrite is the point. The old
    ///      note told a future implementer that Task 7 "supersedes" this mapping and that it
    ///      "should be deleted, not kept as defence in depth". That was wrong in one way and
    ///      imprecise in another, and the Task 5 fix-round re-review found both:
    ///
    ///        * WRONG, because the allowlist was load-bearing for INTEGRITY, not merely for
    ///          liveness. `settleBatch` read `previous = positionBase[o.marketIndex]` with NO
    ///          account scoping, and `baseAmount == 0` means "the full position size on the side
    ///          the caller named" — so a SECOND ALLOWLISTED ADDRESS on a live deployment was a
    ///          hedge-destruction path, not merely a second depositor. Deleting the allowlist on
    ///          the strength of the equity half alone would have opened that path deliberately.
    ///        * IMPRECISE, because "when Task 7 lands" had to be read as "when BOTH halves of
    ///          Task 7 land": per-account `equity()` AND per-order rejection in `settleBatch`.
    ///          Either one without the other leaves a second account able to reach the first one's
    ///          pool or its settlement.
    ///
    ///      Both halves have now landed. `marginBalanceOf`, `positionBaseOf` and `entryPriceOf` are
    ///      keyed by account, `equity(accountIndex)` takes an account and has no global overload,
    ///      the initial-margin check reads the submitting account's own cash, and `settleBatch`
    ///      rejects one order rather than the batch. A second registered account can no longer
    ///      reach the first one's collateral, its position, or its settlement.
    ///
    ///      SO THIS MAPPING STAYS, and now genuinely as defence in depth rather than as the only
    ///      gate. Three reasons, none of them "it was already here":
    ///
    ///        1. It is HARDER than the venue, never easier, which Global Constraint 5 explicitly
    ///           allows: it refuses registrations the venue would accept and refuses nothing the
    ///           venue refuses. A vault certified here is certified against a strictly more
    ///           restrictive counterparty than the one it will meet.
    ///        2. The residual multi-tenant hazards are LIVENESS, and the allowlist is what keeps
    ///           them out of a stranger's reach: an order on a market with no mark still trips the
    ///           whole-batch `LighterSim_MarkPriceUnset` pre-pass below, and `MAX_QUEUE` is a
    ///           shared resource. Both need a second account to be reachable at all.
    ///        3. Three rounds on this contract have each shipped a remedy that held on the paths
    ///           that had been tested and nowhere else. Removing a live gate in the very change
    ///           that claims to replace it is how that pattern continues.
    ///
    ///      Deliberately on `LighterSim` and NOT on `LighterCore`: `MockLighter` must stay
    ///      unrestricted so the existing suite runs against the venue's real registration model.
    mapping(address => bool) public depositorAllowed;

    /// @notice The one address besides the owner that may call `settleBatch`.
    ///
    /// @dev Task 7, item 2. Settlement used to be permissionless, which the Task 5 review judged
    ///      defensible only because there was a SINGLE GLOBAL POSITION and `setMarkPrice` was
    ///      owner-only, so a caller timing a fill had no counterparty leg to profit from. This task
    ///      gives accounts separate positions and that stops being true: whoever calls
    ///      `settleBatch` chooses which block, and therefore which mark, someone else's queued
    ///      order fills at. Rate-limiting was considered and rejected — it adds a liveness hazard
    ///      for no gain.
    ///
    ///      A keeper as well as the owner because Task 12's batch advancer is a bot with its own
    ///      key while the owner is a person; making the owner the only settler would put a liveness
    ///      requirement on a human. Zero by default, and zero means "owner only" rather than
    ///      "anyone" — the fail-closed reading, and the one a forgotten deployment step gets.
    address public keeper;

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

    /// @notice Set the venue's deposit granularity: `deposit` then refuses any amount that is not
    ///         an exact multiple of it.
    ///
    /// @dev Task 8, item 2. Owner-gated like every other configuration knob here, for the reason in
    ///      this contract's header: an ungated simulator knob is how a testnet silently certifies a
    ///      bad design.
    ///
    ///      Zero is refused rather than accepted-and-bricking: at zero every deposit would revert
    ///      on a division by zero, which is a panic with no name in it and no way for an operator
    ///      to tell it from a bug in the vault.
    ///
    ///      There is no upper floor to enforce, and no "raise only" rule, because the DEFAULT (1)
    ///      is already the loosest possible value — a tick of 1 accepts every amount. So no
    ///      setting reachable through this function can make the simulator more permissive than
    ///      the configuration the suite certifies, which is what Global Constraint 5 asks for. See
    ///      `LighterCore.depositTickSize` for why the default is the identity rather than a guess
    ///      at the venue's real, still-unread value.
    function setDepositTickSize(uint256 tick) external onlyOwner {
        if (tick == 0) revert LighterCore_TickSizeIsZero();
        uint256 previous = depositTickSize;
        depositTickSize = tick;
        emit DepositTickSizeSet(previous, tick);
    }

    /// @notice Nominate (or clear, with the zero address) the keeper allowed to settle batches.
    /// @dev Task 7, item 2. Clearing it leaves the owner as the only settler, which is the
    ///      fail-closed direction: settlement stops, nothing is mis-settled.
    function setKeeper(address newKeeper) external onlyOwner {
        address previous = keeper;
        keeper = newKeeper;
        emit KeeperSet(previous, newKeeper);
    }

    /// @notice Turn `settleBatch`'s revert-on-first-failure behaviour on or off.
    /// @dev Task 7, item 3. See `LighterCore.strictMode`. Owner-gated and default OFF: reverting a
    ///      whole batch because one account's order is under-margined is not venue behaviour, and
    ///      it is the denial of service fix round 1 had to ship an owner hatch for. This exists so
    ///      the three pre-Task-7 tests that pin the margin gate as a REVERT keep asserting exactly
    ///      what they asserted, instead of being softened to match the new default.
    function setStrictMode(bool on) external onlyOwner {
        bool previous = strictMode;
        strictMode = on;
        emit StrictModeSet(previous, on);
    }

    /// @notice Approve, or revoke, an address's permission to hold an account on this simulator.
    /// @dev See `depositorAllowed` for why a registration allowlist exists on a contract that
    ///      stands in for a venue which registers anyone, and why Task 7 KEPT it — as defence in
    ///      depth once per-account isolation landed, rather than as the only gate it used to be.
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
    /// @dev FIX ROUND 1, CRITICAL 2 — a liveness escape hatch, kept by Task 7 as a narrower one.
    ///
    ///      WHY IT EXISTED. `settleBatch` used to refuse a batch as a WHOLE: on
    ///      `InsufficientMargin` in `LighterCore.settleBatch`, and on the
    ///      `LighterSim_MarkPriceUnset` pre-pass below. One unsettleable order therefore blocked
    ///      every other account's fills, and Task 5's per-account `cancelAllOrders` binding meant
    ///      only that order's own account could withdraw it. An account with zero collateral
    ///      queueing one oversized market order made settlement revert for everyone — including the
    ///      vault and the owner — permanently, with no operator path to clear it and no way back
    ///      short of redeploying. `requiredMarginBps` can only be raised, so it was no help either.
    ///      Reproduced in `test/sim/DrainPoC.t.sol` before this function existed; Task 12's batch
    ///      advancer would have reverted forever.
    ///
    ///      TASK 7 SHIPPED THE STRUCTURAL FIX, so the `InsufficientMargin` half of that jam can no
    ///      longer form: `LighterCore.settleBatch` rejects the individual order, emits
    ///      `OrderRejected` naming it, and continues. What remains reachable is the
    ///      `LighterSim_MarkPriceUnset` pre-pass, which is deliberately still whole-batch — an
    ///      unset mark is an OPERATOR misconfiguration rather than an account's doing, and settling
    ///      any order while the price book is incomplete is the silent state that hid a Critical in
    ///      this project's external audit. So the hatch STAYS, for exactly that case and for
    ///      anything the next round finds: the owner's two ways out of a markless jam are to set
    ///      the mark the log names, or to drop the order that should not fill at all.
    ///
    ///      This is ADDITIONAL, not a relaxation: `cancelAllOrders` keeps its per-account scoping
    ///      for every non-owner caller, and this path is reachable only by `owner`. It also has no
    ///      counterpart on the real venue, so — like the allowlist — it errs in the direction of a
    ///      more privileged, more restrictive counterparty rather than a more permissive one.
    ///
    /// @dev Task 7, item 5. `accountIndex == 0` is REFUSED. `OperatorCancelledOrders` documents
    ///      index 0 as meaning "the whole queue was purged", and index 0 is never a real account,
    ///      so a scoped drop naming it would emit an indexed topic a log reader could not tell from
    ///      a real purge. One line makes the documented convention true.
    function ownerCancelAccountOrders(uint48 accountIndex) external onlyOwner {
        if (accountIndex == 0) revert LighterSim_AccountIndexZeroIsReservedForPurge();
        emit OperatorCancelledOrders(accountIndex, _cancelOrdersOf(accountIndex));
    }

    /// @notice Drop the entire queue, as the operator. The blunt instrument, for a queue that is
    ///         stuck for a reason the operator cannot attribute to one account.
    /// @dev Same rationale as `ownerCancelAccountOrders`. Emitted with `accountIndex == 0`, which
    ///      is never a real account index — and which `ownerCancelAccountOrders` now refuses — so a
    ///      log reader can tell a purge from a scoped drop.
    ///
    ///      Task 7 routes it through `LighterCore._purgeQueue` rather than doing `delete _queue`
    ///      here. Two reasons, both from the re-review's item 4: `queuedOrdersOf` has to come down
    ///      with the orders it counts, or a purge would lock every purged account out of
    ///      `createOrder` up to `MAX_ORDERS_PER_ACCOUNT` forever; and the cost of the walk is now
    ///      bounded by `MAX_QUEUE`, so the hatch meant to rescue an oversized queue cannot itself
    ///      be priced out of a block by one.
    function ownerPurgeQueue() external onlyOwner {
        emit OperatorCancelledOrders(0, _purgeQueue());
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
    ///
    /// @dev TASK 7 CHANGED TWO THINGS, and left the third alone on purpose.
    ///
    ///      GATED (item 2). `owner` or `keeper` only. Settlement was permissionless, which the
    ///      Task 5 review judged defensible only while there was a single global position: a
    ///      caller timing a fill had no counterparty leg to profit from. Accounts now have separate
    ///      positions, so whoever calls this picks which block — and therefore which mark —
    ///      someone else's queued order fills at. See `keeper`.
    ///
    ///      WINDOWED (item 4). The pre-pass scans only the orders this call will actually settle,
    ///      `[settleCursor, settleCursor + SETTLE_BATCH_MAX)`, not the whole array. Two
    ///      consequences, both wanted: the pre-pass stays O(SETTLE_BATCH_MAX) like the settlement
    ///      loop it guards, and a markless order sitting beyond the window no longer refuses a
    ///      window it is not part of.
    ///
    ///      STILL WHOLE-BATCH within that window, and that is deliberate — but NOT for the reason
    ///      this comment used to give.
    ///
    ///      THE REASON IT USED TO GIVE WAS FALSE, and fix round 1 (Task 7 review, Minor 1)
    ///      disproved it. It claimed that "at a zero mark the entry-price book is corrupted for
    ///      every order in the window", so no order could safely be skipped individually. It is
    ///      not: `_applyFill` reads `markPrice[m]` for the ORDER'S OWN market and `entryPriceOf`
    ///      is keyed `[account][market]`, so a zero mark on market X cannot reach market Y's
    ///      entry. `test_aZeroMarkCorruptsOnlyItsOwnMarketsEntryBook` measures exactly that on
    ///      `MockLighter`, which has no pre-pass and therefore lets the markless order settle:
    ///      the priced market keeps its entry and a live PnL layer while only the unmarked
    ///      market's book goes dead. Skipping just the offending order would corrupt nothing.
    ///
    ///      THE REASON THAT ACTUALLY HOLDS is that rejection CONSUMES the order. `settleBatch`
    ///      decrements `queuedOrdersOf` and drops the order from the queue whether it fills or is
    ///      rejected — deliberately, because a rejection that left the order behind would be a jam
    ///      by another name. So per-order rejection of a markless order would SILENTLY DESTROY THE
    ///      VAULT'S HEDGE ORDER on a deployment where the operator forgot one `setMarkPrice`,
    ///      instead of blocking loudly until the mark is set. Whole-batch is the fail-closed
    ///      direction: an unset mark is an OPERATOR misconfiguration, not an account's action, so
    ///      unlike `InsufficientMargin` it is not something to attribute to one order and discard.
    ///
    ///      AN INCIDENTAL BENEFIT, worth recording because nothing else states it: because the
    ///      pre-pass refuses any order on an unmarked market, `_trackMarket` — whose only caller is
    ///      `LighterCore.settleBatch`, downstream of this guard — can only ever grow `_markets` to
    ///      the set of MARKED markets. That keeps `equity()`'s and `_realiseGain`'s O(`_markets`)
    ///      loops, both on `withdraw`'s path, as small as the operator's own configuration.
    ///      `MockLighter` has no such guard, so there an attacker could enqueue orders across the
    ///      whole 0..254 market range and push `_markets` toward 255, making every `withdraw` cost
    ///      multiple megagas. That is a test front end and not deployed, but it is the reason this
    ///      guard's placement is load-bearing beyond its stated purpose.
    ///
    ///      The residual liveness cost — one markless order refuses its window until the owner sets
    ///      the mark or drops the order — is what `ownerCancelAccountOrders` and the registration
    ///      allowlist are the answer to, and it is recorded as a known residual in this task's
    ///      report rather than left implied.
    function settleBatch() public virtual override {
        if (msg.sender != owner && msg.sender != keeper) revert LighterSim_OnlyOwnerOrKeeper();
        uint256 n = _queue.length;
        uint256 from = settleCursor;
        uint256 stop = n - from > SETTLE_BATCH_MAX ? from + SETTLE_BATCH_MAX : n;
        for (uint256 i = from; i < stop; ++i) {
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
