// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ILighter} from "../interfaces/ILighter.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Shared venue mechanics for every UseCert Lighter stand-in: one behaviour
///         implementation behind two front ends (`MockLighter` for the suite, `LighterSim` for
///         testnet).
///
/// @dev EXTRACTED VERBATIM from `test/mocks/MockLighter.sol` (Task 4). The mechanics below are the
///      semantics the suite certifies — margin enforcement with `InsufficientMargin()`,
///      mark-to-market PnL with volume-weighted entry-price tracking, asynchronous priority-queue
///      fills (orders NEVER fill in the calling transaction), `getPendingBalance` /
///      `withdrawPendingBalance`, account registration, and `depositCapTicks` refusal.
///
///      `abstract` is deliberate. LighterCore is not a front end and must never be deployable on
///      its own: Task 5 put access control on `LighterSim`, so a concrete — and therefore
///      deployable — LighterCore would be a standing bypass of that gating. Deploy `LighterSim`.
///
///      Three things this base deliberately does NOT have, because `LighterSim` would inherit
///      them: the configuration setters (`setMarkPrice`, `setRequiredMarginBps`,
///      `setDepositCapTicks`), the fault-injection flags, and the counterparty-collateral mint in
///      `_fundPending()`. All of those live on `MockLighter`, and none of them exists on the real
///      venue. Global Constraint 5 — the simulator must never be easier than mainnet — is why.
///
///      ---------------------------------------------------------------------------------------
///      TASK 7. PER-ACCOUNT STATE ISOLATION. This is the structural fix that two prior rounds
///      closed only with interim measures, and it is worth stating what changed and why.
///
///      Margin, positions and entry prices used to be GLOBAL: one `marginBalance`, one
///      `positionBase[market]`, one `entryPrice[market]`, shared by every registered account. Every
///      Critical this simulator has had was a consequence of that single fact rather than of the
///      particular entry point each round patched:
///
///        * `withdraw`'s ceiling was `equity()` — `marginBalance + unrealisedPnl()`, with no
///          account parameter at all — so ANY account could draw the whole pool. Round 0 bound the
///          call to its caller; the caller binding was then satisfied by a self-registration and
///          the drain was unchanged. Round 1 shrank the account set with an allowlist; the drain
///          was still there for anyone inside it.
///        * `settleBatch` read `previous = positionBase[o.marketIndex]` with no account scoping, and
///          `baseAmount == 0` means "the full position size on the side the caller named", so a
///          second account could zero out the vault's entire hedge through settlement.
///        * The initial-margin check valued the resulting notional against the GLOBAL cash balance,
///          so one account's collateral margined another account's position increase.
///
///      All three are now closed at the root rather than at the entry point. `marginBalanceOf`,
///      `positionBaseOf` and `entryPriceOf` are keyed by account index and are the only books the
///      mechanics read or write. `equity(accountIndex)` takes an account and there is deliberately
///      NO no-argument overload of it: a global equity figure has no legitimate consumer, and
///      leaving one callable is how the drain survived two fix rounds.
///
///      `marginBalance()`, `positionBase(market)`, `entryPrice(market)` and `unrealisedPnl()`
///      survive as AGGREGATE VIEWS, computed by summing the per-account books. They are mirrors
///      with no authority — nothing in the mechanics reads them — and they answer the venue-level
///      question ("what does this venue hold in total", "what is the net open interest") that
///      several tests and a log reader legitimately ask. `entryPrice(market)` is the size-weighted
///      mean of the per-account entries, which is the only aggregate of a price that means
///      anything; on the single-account deployments the suite runs it is that account's own entry.
///      ---------------------------------------------------------------------------------------
abstract contract LighterCore is ILighter {
    struct Order {
        uint16 marketIndex;
        uint48 baseAmount;
        uint32 price;
        uint8 isAsk;
        uint8 orderType;
        /// @dev Task 5 (C1). The account that submitted this order, so `cancelAllOrders` can cancel
        ///      that account's orders and ONLY that account's. Previously the queue was anonymous
        ///      and `cancelAllOrders` ignored its argument and did `delete _queue`, so any address
        ///      could wipe the vault's hedge. 20 bytes total: still one storage slot.
        ///
        ///      Task 7 gives it a second, larger job. `settleBatch` now resolves every order
        ///      against `positionBaseOf[o.account]` and margins it against
        ///      `marginBalanceOf[o.account]`, so this field is what makes an order act on its
        ///      submitter's own book. Round 1's note that the attribution "governs cancellation
        ///      only" was the finding that made this task necessary.
        uint48 account;
        /// @dev Task 8. A MONOTONIC identifier, assigned once at `createOrder` and never reused, so
        ///      an indexer can tie an `OrderEnqueued` to the `OrderFilled` or `OrderRejected` that
        ///      resolves it.
        ///
        ///      The queue POSITION cannot do that job, and the pre-Task-8 `OrderRejected` used
        ///      exactly that position as its `orderId`. `_cancelOrdersOf` compacts the array in
        ///      place, so slot `k` names a different order after any cancellation: an operator
        ///      watching a testnet where anything cancels would attribute a rejection to an order
        ///      that had already left the queue. `uint96` because 16 + 48 + 32 + 8 + 8 + 48 + 96 =
        ///      256 bits exactly — the identifier is free, the struct is still one storage slot.
        uint96 id;
    }

    /// @notice One withdrawal priority request, waiting for a batch to execute it.
    ///
    /// @dev TASK 6a. `withdraw` used to decide sufficiency, debit margin and credit the pending
    ///      balance all in the calling transaction. The real `AdditionalZkLighter.withdraw`
    ///      performs NO BALANCE CHECK: it validates flags, enqueues a priority request, and the
    ///      rollup decides what it can pay later — with no on-chain signal and no rollback if it
    ///      cannot. So the request has to be a stored object, and this is it.
    ///
    ///      `owner` is `msg.sender` at request time and NOT derived from `account` at settlement.
    ///      The two are the same address on every path that exists — `withdraw` binds the caller to
    ///      the account it names — but `_pending` is keyed by ADDRESS while the books are keyed by
    ///      INDEX, so recording the address the credit was promised to is what stops a settlement
    ///      from having to re-derive it from a mapping that may have moved on.
    ///
    ///      20 + 6 + 2 + 8 + 12 = 48 bytes: two storage slots, and the second one is half empty
    ///      rather than being packed tighter, because `owner` is a full word-aligned address and
    ///      splitting it would cost more gas to read than the slot saves.
    struct WithdrawalRequest {
        address owner;
        uint48 account;
        uint16 assetIndex;
        uint64 baseAmount;
        uint96 id;
    }

    error AccountIsNotRegistered();
    error MarketIndexTooHigh();
    error BadOrderType();
    error InsufficientMargin();
    error ZeroBaseAmount();
    error AboveDepositCap();
    /// @dev Task 5, item 7 (C1). The caller named an account index that is not its own.
    ///
    ///      This is VENUE FIDELITY, not UseCert access control, which is why it lives on the shared
    ///      core rather than on `LighterSim`: the real `ZkLighter` never takes the acting account on
    ///      trust from calldata, it derives it from the caller via
    ///      `validateAndGetAccountIndexFromAddress`. A simulator that accepts any index is a
    ///      simulator that is EASIER than mainnet, which Global Constraint 5 names as Critical.
    ///
    ///      `MockLighter` inherits this deliberately. The suite must run against the venue's real
    ///      authorisation model, not a looser one.
    error LighterCore_AccountNotCaller();
    /// @dev Fix round 1, Critical 1. `deposit` was callable with `amount == 0`.
    ///
    ///      OpenZeppelin's `transferFrom` permits a zero-value transfer with NO allowance and NO
    ///      balance, so `deposit(self, _, _, 0)` cost nothing, needed nothing, and still ran the
    ///      registration branch below — which handed the caller an account index and therefore
    ///      SATISFIED `_requireCallerOwnsAccount`. `withdraw`'s ceiling was the global `equity()`,
    ///      so a self-registered address with no collateral then took every depositor's balance in
    ///      three transactions: the same end state as the pre-Task-5 drain, one transaction later.
    ///      Task 5's caller binding only ever caught the *unregistered* attacker.
    ///
    ///      A zero-value deposit that registers an account is not venue behaviour worth modelling,
    ///      and it is the specific mechanism that made registration free, so it is refused here on
    ///      the shared core. `MockLighter` inherits the refusal: no test in the suite deposited
    ///      zero, and neither `CertVault.bootstrap()` (which deposits `10 ** decimals`) nor
    ///      `CertVault._postMargin()` (which early-returns on a zero share) can reach it.
    ///
    ///      Task 7 makes it belt-and-braces rather than load-bearing: a free registration is now
    ///      HARMLESS, because a registered account with no collateral has an `equity()` of zero and
    ///      a `positionBaseOf` of zero. The refusal stays because the mechanism it closes is still
    ///      not venue behaviour.
    error LighterCore_ZeroDepositAmount();
    /// @dev Task 7, item 4. The settlement queue is full.
    ///
    ///      `createOrder` used to push with no length bound, and EVERY path that walks the queue is
    ///      O(queue): `settleBatch`, `_cancelOrdersOf`'s compaction, and `LighterSim`'s
    ///      `ownerPurgeQueue`. So a queue long enough to exceed the block gas limit braked
    ///      settlement AND the operator hatch meant to rescue it — on a testnet with a free faucet,
    ///      reachable by anyone who can hold an account. Bounding the array is what makes the
    ///      hatch's worst-case cost a number rather than an unknown.
    error LighterCore_QueueFull();
    /// @dev Task 7, item 4. One account has `MAX_ORDERS_PER_ACCOUNT` orders outstanding.
    ///
    ///      `MAX_QUEUE` alone would be a new denial of service: one account could fill the global
    ///      queue and every other account's `createOrder` — the vault's hedge included — would
    ///      revert. The per-account cap is what makes the global cap safe to have.
    error LighterCore_AccountOrderCapReached();
    /// @dev Task 6a. The withdrawal priority queue is full.
    ///
    ///      Bounded for the same reason the order queue is: `_settleWithdrawals` walks it, and
    ///      `CertVault.recallMargin()` is PERMISSIONLESS, so anyone may submit a withdrawal request
    ///      on the vault's behalf as often as they like. An unbounded queue would make settlement's
    ///      cost a stranger's choice on the one function the whole testnet's liveness runs through.
    ///
    ///      Separate from `LighterCore_QueueFull` although it reuses `MAX_QUEUE`'s value: a full
    ///      withdrawal queue and a full order queue are different operator problems with different
    ///      answers, and `recallMargin` swallows this in a `catch` — a shared selector would make
    ///      the log the only way to tell them apart.
    error LighterCore_WithdrawQueueFull();
    /// @dev Task 6a. One account has `MAX_ORDERS_PER_ACCOUNT` withdrawal requests outstanding.
    ///      Counterpart of `LighterCore_AccountOrderCapReached`, and what stops one account from
    ///      monopolising the withdrawal queue and locking every other account — the vault included
    ///      — out of `withdraw`.
    error LighterCore_AccountWithdrawCapReached();
    /// @dev Task 8, item 2. A deposit that is not an exact multiple of `depositTickSize`.
    ///
    ///      The real venue's per-asset config gates deposits on `tickSize`, `minDepositTicks` and
    ///      `depositCapTicks`, and a non-multiple is refused outright. This simulator accepted any
    ///      amount, so no test could observe a vault whose margin post is unrepresentable in venue
    ///      ticks.
    error LighterCore_DepositNotTickMultiple(uint256 amount, uint256 tickSize);
    /// @dev Task 8, item 2. `deposit` named an asset this venue holds no config for.
    ///
    ///      The `assetIndex` argument used to be IGNORED — the parameter was unnamed — so a vault
    ///      misconfigured with the wrong USDG index deposited successfully here and would revert on
    ///      the real venue. That is Global Constraint 5's exact shape: a simulator easier than
    ///      mainnet, hiding a deployment misconfiguration that has no on-chain recovery, because
    ///      `CertVault.cfg` is immutable and a redeployed vault is a new certificate token.
    error LighterCore_UnknownAssetIndex(uint16 given, uint16 expected);
    /// @dev Task 8, item 2. A zero tick size would brick every deposit on a division by zero rather
    ///      than on a named refusal, so it is refused where it is set.
    error LighterCore_TickSizeIsZero();

    // -------------------------------------------------------------------------------- events
    //
    // TASK 8, ITEM 1. Before this task the venue emitted NOTHING. A full
    // deposit -> createOrder -> settleBatch -> fill -> withdraw -> drain lifecycle produced two
    // logs, both ERC-20 `Transfer`s from the collateral token and zero from this contract —
    // measured with `vm.recordLogs` against the deployable artefact. An indexer could see that
    // tokens moved and nothing about which account they were credited to, which order was
    // submitted, whether it filled or was refused, or at what price.
    //
    // THEY LIVE ON THE CORE, not on the front ends, for the same reason the mechanics do: an event
    // emitted next to the state transition it describes cannot drift from it, and the suite then
    // certifies the same log stream the testnet deployment produces.
    //
    // WHAT IS INDEXED, AND WHY. Task 7 made margin, positions and entry prices PER-ACCOUNT, so
    // `account` is a topic on everything an account does — without it an indexer cannot attribute a
    // single figure, which is the whole point of the per-account rewrite. `marketIndex` is a topic
    // on everything market-scoped, because a consumer follows one mirror (uTSLA market 16, uSPY
    // market 26) and must not have to decode every other market's logs to do it. `orderId` is a
    // topic so one order's enqueue, fill or rejection can be joined without a full scan. Amounts,
    // prices and reasons are NOT indexed: nothing filters on a price, and a topic is a worse place
    // to read a value from than the data section.

    /// @notice Collateral was posted as margin for `to`, credited to venue account `account`.
    /// @dev `account` resolves the registration for this deposit whether or not it was new; see
    ///      `AccountRegistered` for the first-registration edge. `ticks` is `amount /
    ///      depositTickSize`, the unit `depositCapTicks` is measured in.
    event Deposited(
        address indexed to,
        uint48 indexed account,
        uint16 indexed assetIndex,
        uint256 amount,
        uint256 ticks,
        uint256 marginBalanceAfter
    );

    /// @notice A registering deposit reserved a venue account index for `owner`. The index is NOT
    ///         usable yet — it resolves when batch `resolvesAtBatch` settles.
    ///
    /// @dev Indices are assigned from 3 upward and never reused, so this fires at most once per
    ///      address. An indexer needs it to build the address/account map every other event here is
    ///      keyed by, and `CertVault` reads the same view to find its own index.
    ///
    /// @dev TASK 6b ADDED `resolvesAtBatch`, and it is the field that makes the log stream
    ///      self-contained. Registration is now asynchronous — `addressToAccountIndex` returns 0
    ///      until a `settleBatch` has executed the registering deposit — so an event that said only
    ///      "registered" would name a moment that has not arrived. There is deliberately no second
    ///      event at resolution: nothing happens in that transaction beyond the batch itself, so a
    ///      consumer joins this against `BatchSettled(batchId)` for `batchId >= resolvesAtBatch`
    ///      and gets the exact block the index became usable, with no extra on-chain cost and no
    ///      per-batch walk over pending registrations.
    event AccountRegistered(address indexed owner, uint48 indexed account, uint256 resolvesAtBatch);

    /// @notice An order was accepted into the settlement queue. It has NOT filled — orders never
    ///         fill in the calling transaction, which is the venue behaviour this simulator exists
    ///         to model, and the single most misread property of the whole system.
    /// @param queueSlot Where it landed. Informational only: `_cancelOrdersOf` compacts the array,
    ///        so a slot is not an identifier. `orderId` is.
    event OrderEnqueued(
        uint48 indexed account,
        uint16 indexed marketIndex,
        uint96 indexed orderId,
        uint48 baseAmount,
        uint32 price,
        uint8 isAsk,
        uint8 orderType,
        uint256 queueSlot
    );

    /// @notice A queued order filled at the mark, inside batch `batchId`.
    /// @param fillPx18 The mark the fill was priced at, scaled to 1e18. Every fill here happens at
    ///        the mark, which is why an increase carries no PnL of its own to credit.
    /// @param sizeDelta Signed change in the account's position, in base ticks: the FILLED SIZE,
    ///        which is not always the submitted `baseAmount`. A zero `baseAmount` is Lighter's
    ///        close-all primitive and resolves to the submitter's own position size, on the side
    ///        the submitter named — so an ask against a short DOUBLES it, and this field is where
    ///        that becomes visible instead of inferred.
    /// @param resultingBase The account's position in that market after the fill, so a consumer can
    ///        rebuild the position book from logs alone rather than by replaying the arithmetic.
    event OrderFilled(
        uint48 indexed account,
        uint16 indexed marketIndex,
        uint96 indexed orderId,
        uint256 batchId,
        uint256 fillPx18,
        int256 sizeDelta,
        int256 resultingBase
    );

    /// @notice Every unsettled order belonging to `account` left the queue without filling.
    /// @dev Without this an `OrderEnqueued` that is later cancelled has no terminal event at all
    ///      and a consumer waits for a fill forever. `LighterSim.OperatorCancelledOrders` reports
    ///      the operator hatches; this reports the account's own `cancelAllOrders`.
    event OrdersCancelled(uint48 indexed account, uint256 cancelled, uint256 queueLengthAfter);

    /// @notice A withdrawal priority request was accepted into the queue. NOTHING has been credited
    ///         and no book has moved — see `WithdrawalCredited` for the settlement half.
    ///
    /// @dev TASK 6a. This is the ONLY thing the calling transaction now produces, and the gap
    ///      between it and `WithdrawalCredited` is the property this task exists to create. The
    ///      real venue enqueues and returns success whatever the account holds; an insufficient
    ///      request is rejected INSIDE THE ROLLUP with no on-chain signal and no rollback, so the
    ///      caller sees success and the cash never arrives. `getPendingBalance` is the only on-chain
    ///      evidence a withdrawal executed, which is exactly why `CertVault.recallMargin` is
    ///      two-phase and reduces `marginPendingRecall` only on proven arrival.
    ///
    /// @param requestId Monotonic and never reused, so this can be joined to the
    ///        `WithdrawalCredited` / `WithdrawalUnfundable` that resolves it. Counted on its own
    ///        sequence, not on `Order.id`'s, so order ids stay dense.
    /// @param queueSlot Where it landed. Informational: the withdrawal queue is compacted by
    ///        nothing today, but a slot is still not an identifier. `requestId` is.
    event WithdrawalRequested(
        address indexed owner,
        uint48 indexed account,
        uint16 indexed assetIndex,
        uint64 requested,
        uint96 requestId,
        uint256 queueSlot
    );

    /// @notice A queued withdrawal was executed inside batch `batchId` and `credited` was added to
    ///         `owner`'s pending balance.
    ///
    /// @dev NOT a payment. This is the venue saying "asked, and this much was credited". Tokens
    ///      move on `withdrawPendingBalance` — see `WithdrawalFulfilled`.
    ///
    /// @dev TASK 6a RENAMED THIS FROM `WithdrawalEnqueued`, and the rename is the point rather than
    ///      cosmetics: the enqueue and the credit are now two different transactions, so a single
    ///      name could only be wrong about one of them. `WithdrawalRequested` is the enqueue; this
    ///      is the credit. Field list unchanged apart from the appended `batchId`, so an existing
    ///      consumer reads the same six values in the same order and only has to move which
    ///      transaction it expects them in.
    event WithdrawalCredited(
        address indexed owner,
        uint48 indexed account,
        uint16 indexed assetIndex,
        uint64 requested,
        uint256 credited,
        uint256 pendingAfter,
        uint256 batchId
    );

    /// @notice A queued withdrawal was REFUSED WHOLE at settlement because this simulator's own
    ///         token balance could not back the credit it was about to make. Nothing was credited
    ///         and no book moved.
    ///
    /// @dev TASK 6a, AND THE ONE CASE IN THIS FILE THAT FAILS CLOSED. It must not be confused with
    ///      `WithdrawalSilentlyRejected`, which is the opposite decision for a different cause, so
    ///      the distinction is worth stating in full:
    ///
    ///        * A request LARGER THAN THE ACCOUNT'S EQUITY is PARTIALLY FULFILLED — `min(request,
    ///          available)` is credited and the shortfall is announced. That is real venue
    ///          behaviour, and `CertVault.recallMargin` DEPENDS on it: it deliberately over-requests,
    ///          asking the venue for what the vault OWES rather than what it deposited, which was
    ///          the C1 audit fix and is safe only because the venue fulfils `min(request,
    ///          available)` and `_sweepPending` reconciles whatever actually arrives. Measured at
    ///          that audit: a receipt owed 7,102.97 while everything recallable totalled 3,559.54.
    ///          Making withdrawals all-or-nothing would make that receipt unpayable again — the
    ///          sharpest Law 2 breach the audit found, reintroduced through the simulator. So
    ///          partial fulfilment is LOAD-BEARING and stays.
    ///        * A credit THIS CONTRACT CANNOT BACK WITH TOKENS is refused entirely. That is not a
    ///          partial fill, it is a bookkeeping half-application: `withdraw` used to succeed,
    ///          debit `marginBalance`, rewrite `entryPrice` through `_realiseGain` and bump
    ///          `_pendingTotal`, and only the LATER `withdrawPendingBalance` reverted on the token
    ///          transfer — leaving a permanently unsweepable pending credit against books that had
    ///          already moved, which on testnet presents as a vault wedged in `_sweepPending`
    ///          forever. Refusing before anything is written is the fix.
    ///
    /// @param wouldHaveCredited What partial fulfilment had decided on before the funding check
    ///        refused it. Recorded because it is the number an operator needs to size the
    ///        collateral top-up that would let a retry through, and it is not recoverable from any
    ///        other log line.
    event WithdrawalUnfundable(
        address indexed owner,
        uint48 indexed account,
        uint16 indexed assetIndex,
        uint64 requested,
        uint256 wouldHaveCredited,
        uint256 batchId
    );

    /// @notice The withdrawal half of one `settleBatch` call finished.
    /// @dev Task 6a. Separate from `BatchSettled` rather than adding fields to it: the two queues
    ///      are drained independently, with their own cursors and their own `SETTLE_BATCH_MAX`
    ///      window, so one event carrying both would report two unrelated `drained` flags.
    /// @param credited How many requests credited something.
    /// @param refused How many credited nothing — either fulfilled to zero, or refused whole by the
    ///        funding check. `WithdrawalSilentlyRejected` and `WithdrawalUnfundable` say which.
    event WithdrawalsSettled(
        uint256 indexed batchId,
        uint256 fromQueueSlot,
        uint256 toQueueSlot,
        uint256 credited,
        uint256 refused,
        bool queueDrained
    );

    /// @notice A withdrawal was credited for LESS than it asked for, and did not revert.
    ///
    /// @dev THE MOST IMPORTANT EVENT IN THIS FILE for an operator, and deliberately separate from
    ///      `WithdrawalCredited` so it can be filtered on alone.
    ///
    /// @dev TASK 6a MOVED WHEN THIS FIRES — from the `withdraw` transaction to the `settleBatch`
    ///      that executes the request — and deliberately did NOT change its signature, so
    ///      `test_theShortfallEventIsDistinctFromTheEnqueueEvent`'s hashed topic and every existing
    ///      consumer keep working. This is also now the PARTIAL-FULFILMENT event and nothing else:
    ///      the case where the simulator cannot back the credit at all is `WithdrawalUnfundable`,
    ///      which refuses whole. See that event for why conflating the two is severe.
    ///
    ///      `withdraw` must not revert on insufficiency — the real venue does not, it credits what
    ///      it can and STRANDS the rest, and `CertVault._queueExit` is built around exactly that.
    ///      The consequence is that a venue paying nothing at all looks, on-chain, identical to a
    ///      venue paying in full. `shortfall` is the difference an operator otherwise has to infer
    ///      by diffing two storage reads across a block, and a stranded shortfall is the one state
    ///      solvency exists to detect.
    event WithdrawalSilentlyRejected(
        address indexed owner,
        uint48 indexed account,
        uint16 indexed assetIndex,
        uint64 requested,
        uint256 credited,
        uint256 shortfall
    );

    /// @notice A pending balance was drained: collateral actually left the venue.
    event WithdrawalFulfilled(
        address indexed owner,
        uint48 indexed account,
        uint16 indexed assetIndex,
        uint128 amount,
        uint128 pendingAfter
    );

    /// @notice One `settleBatch` call finished.
    ///
    /// @dev `batchId` is the venue's settlement clock and it advances on EVERY call, including one
    ///      that settles nothing. Two reasons it must: Task 12's attester relays a batch id to
    ///      `SolvencyRegistry.attest`, which refuses one that is not strictly newer, so a stalled
    ///      counter stalls attestation and starves `maxNotional18` to zero; and an empty batch is
    ///      the keeper's heartbeat, which is what the runbook's "minting stopped after ~5 minutes"
    ///      row is diagnosed with.
    ///
    /// @param fromQueueSlot First slot this call considered (the cursor on entry).
    /// @param toQueueSlot One past the last slot it considered.
    /// @param filled How many orders filled.
    /// @param rejected How many were refused individually and skipped. Each also emits
    ///        `OrderRejected`.
    /// @param queueDrained Whether the cursor reached the end and the queue was cleared.
    event BatchSettled(
        uint256 indexed batchId,
        uint256 fromQueueSlot,
        uint256 toQueueSlot,
        uint256 filled,
        uint256 rejected,
        bool queueDrained
    );

    /// @notice A queued order was refused at settlement and the rest of the batch continued.
    ///
    /// @dev Task 7, item 3, and the structural fix for fix round 1's Critical 2. `settleBatch` used
    ///      to revert the batch as a WHOLE on the first under-margined order, and Task 5's
    ///      per-account `cancelAllOrders` binding meant only that order's own account could
    ///      withdraw it — so one account with no collateral queueing one oversized order stopped
    ///      settlement for every other account, permanently, and `requiredMarginBps` is only
    ///      raisable. Rejecting the individual order is both the venue-faithful behaviour and the
    ///      fix: a bad order can no longer reach anyone else's fills.
    ///
    /// @dev TASK 8 CHANGED `orderId`, and the change is a correctness fix rather than cosmetics. It
    ///      used to be the refused order's INDEX IN THE QUEUE, which is not an identifier:
    ///      `_cancelOrdersOf` compacts the array in place, so slot `k` names a different order after
    ///      any cancellation and an operator would attribute a rejection to an order that had
    ///      already left. It is now `Order.id`, monotonic and never reused, matching the
    ///      `OrderEnqueued` that introduced the order. `batchId` was added at the same time so a
    ///      rejection names the settlement window that refused it — `OrderRejected` alone could not
    ///      say whether two rejections were one order refused twice or two orders refused once.
    ///
    /// @param account The submitting account, from `Order.account`.
    /// @param marketIndex The market the refused order was on.
    /// @param orderId The refused order's monotonic id, as emitted by `OrderEnqueued`.
    /// @param batchId The `settleBatch` call that refused it.
    /// @param reason The error selector the order would have reverted with in `strictMode`.
    event OrderRejected(
        uint48 indexed account, uint16 indexed marketIndex, uint96 indexed orderId, uint256 batchId, bytes4 reason
    );

    IERC20 public immutable collateral;
    uint16 public immutable collateralAssetIndex;
    uint8 public immutable sizeDecimals;
    uint8 internal immutable _collateralDecimals;

    /// @dev TASK 6b. The account index RESERVED for an address by its registering deposit — the
    ///      venue's internal book, not the published answer.
    ///
    ///      `addressToAccountIndex(owner)` below is the published answer, and it stays 0 until a
    ///      `settleBatch` has executed the registering deposit. The split is the whole of 6b: the
    ///      collateral has to land in SOME account's book in the same transaction that receives the
    ///      tokens (they are held, so `marginBalance()` must account for them), while the INDEX
    ///      must not resolve until the rollup runs. Keeping the reservation internal is what makes
    ///      the second true without making the first a lie.
    ///
    ///      `internal` rather than `private` for no reason but symmetry with the rest of this file;
    ///      nothing outside it reads the reservation, and nothing should — a consumer that wants to
    ///      know whether an account is usable must ask `addressToAccountIndex`, which is the only
    ///      read the real venue offers and the only one that answers the question.
    mapping(address => uint48) internal _accountIndexOf;
    /// @notice The settlement batch at which an address's registering deposit resolves its account
    ///         index. Zero means the address has never made a registering deposit.
    ///
    /// @dev TASK 6b. Set to `batchesSettled + 1` by the registering deposit, so exactly one
    ///      `settleBatch` after the deposit publishes the index — the same "the next batch executes
    ///      the priority request" model `settleBatch` already gives orders.
    ///
    ///      PUBLIC ON PURPOSE, and it is the operator's diagnostic for the whole 6b window: the
    ///      runbook's "the vault is bootstrapped but every mint reverts AccountIsNotRegistered" row
    ///      is answered by comparing this against `batchesSettled`, which is a two-read answer
    ///      instead of an unexplained revert. It has no counterpart on the real venue — there the
    ///      rollup's own queue holds the equivalent — and it must not be read as modelling one.
    mapping(address => uint256) public accountRegistrationBatch;
    uint48 private _nextAccountIndex = 3;
    /// @dev Every account index ever registered, in registration order. Exists so the aggregate
    ///      views (`marginBalance()`, `positionBase()`, `entryPrice()`, `unrealisedPnl()`) can sum
    ///      the per-account books. Read by views only; no mechanic walks it.
    uint48[] internal _accounts;

    /// @dev Task 7. Collateral posted as margin, in token units, PER ACCOUNT. This is the book —
    ///      `marginBalance()` below is a sum of it, kept for the venue-level question and for the
    ///      tests that ask it, and read by nothing that decides anything.
    mapping(uint48 => uint256) public marginBalanceOf;
    /// @dev Task 7. Signed position size in base ticks (size_decimals applied by caller), PER
    ///      ACCOUNT AND MARKET. `settleBatch` resolves `baseAmount == 0` against this, which is
    ///      what closes the hedge-destruction path: a full-size order defaults to the size of the
    ///      SUBMITTER's position, never of the pool's.
    mapping(uint48 => mapping(uint16 => int256)) public positionBaseOf;
    /// @dev Task 7. Volume-weighted entry price per account and market, scaled to 1e18. Zero when
    ///      that account is flat in that market.
    mapping(uint48 => mapping(uint16 => uint256)) public entryPriceOf;
    /// @dev mark price scaled to 1e18. Genuinely venue-wide: one mark per market, not per account.
    mapping(uint16 => uint256) public markPrice;
    /// @dev required margin as a fraction of resulting notional, in bps. Default 5_000 (2x).
    uint256 public requiredMarginBps = 5_000;
    /// @dev Mirrors AssetConfig.depositCapTicks on the real contract, which withdraw() validates
    ///      `_baseAmount` against. Defaults large so existing tests are unaffected.
    ///
    ///      TASK 8, ITEM 2: `deposit` validates against it too, which it did not before. The real
    ///      venue's cap is a GLOBAL deposit cap — that is the whole reason
    ///      `docs/DEPLOYMENT-CHECKLIST.md` carries a row for it — and a simulator that enforced it
    ///      only on the way out could not produce the state that row describes.
    uint256 public depositCapTicks = type(uint64).max;

    /// @notice The venue's deposit granularity: a deposit must be an exact multiple of this.
    ///
    /// @dev Task 8, item 2. Mirrors `AssetConfig.tickSize` on the real contract.
    ///
    ///      DEFAULT 1, AND THAT IS A DELIBERATE CHOICE RATHER THAN A NEUTRAL ONE. The real value is
    ///      open item O-2 in the design spec — the venue's asset endpoints are 403-gated and it has
    ///      never been read — and the C1 plan's rule for exactly this situation is that an
    ///      unverified value must never be a hardcoded literal. A guessed tick would be worse than
    ///      a vacuous one in both directions: too small silently certifies deposits the venue
    ///      refuses, and too large makes every `CertVault._postMargin` revert on a testnet for a
    ///      reason no document explains, because a margin post is `netCollateral *
    ///      targetMarginBps / 10_000` and is not a round number in any tick.
    ///
    ///      So the MECHANISM is enforced and the VALUE is left at the identity until the venue's
    ///      own figure is read, and `LighterSim.setDepositTickSize` can raise it — the conservative
    ///      direction under Global Constraint 5, since a coarser tick refuses strictly more.
    ///      Recorded rather than assumed: at 1 this check is satisfied by every amount, and
    ///      `test_depositRejectsNonTickMultiple` sets a real tick to prove the mechanism is live.
    uint256 public depositTickSize = 1;

    /// @notice How many `settleBatch` calls this venue has completed. The venue's settlement clock.
    /// @dev Task 8, item 1. `BatchSettled`'s id, and what Task 12's attester relays to
    ///      `SolvencyRegistry.attest` — which refuses a batch id that is not strictly newer, so
    ///      this must advance on every call, including one that settles an empty queue.
    uint256 public batchesSettled;

    /// @dev Task 8, item 1. The next `Order.id`. Starts at 1 so that 0 is never a real order and an
    ///      indexed `orderId` topic of zero cannot be mistaken for one — the same convention
    ///      `OperatorCancelledOrders` uses for account index 0.
    uint96 private _nextOrderId = 1;

    /// @notice When set, `settleBatch` reverts on the first order it cannot fill instead of
    ///         rejecting that order and continuing.
    ///
    /// @dev Task 7, item 3. A COMPATIBILITY PATH, not the default, and never the deployed default.
    ///      Three tests written before this task pin `settleBatch` reverting `InsufficientMargin`
    ///      as the way a venue refuses an over-leveraged fill; that assertion is still worth having
    ///      — it is the proof the margin gate is not vacuous — so they run in strict mode rather
    ///      than being rewritten. Reverting the whole batch is NOT venue behaviour and is the
    ///      denial of service fix round 1 had to ship an owner hatch for, which is why it is opt-in.
    ///
    ///      Assigned by the front ends: owner-gated on `LighterSim`, ungated on `MockLighter`
    ///      alongside its other test knobs.
    bool public strictMode;

    /// @notice The hard bound on the settlement queue's length.
    /// @dev Task 7, item 4. Every queue walk is O(this), which is what makes the operator hatch's
    ///      worst case a bounded number: 512 single-slot `Order`s to clear, comfortably inside a
    ///      block. Far above anything the suite or the vault produces — the deepest existing
    ///      sequence queues twelve.
    uint256 public constant MAX_QUEUE = 512;
    /// @notice The bound on one account's outstanding orders.
    /// @dev Task 7, item 4. Stops a single account monopolising `MAX_QUEUE` and locking every other
    ///      account — including the vault — out of `createOrder`.
    uint256 public constant MAX_ORDERS_PER_ACCOUNT = 128;
    /// @notice The most orders one `settleBatch` call will process.
    /// @dev Task 7, item 4. With `settleCursor` below, a queue larger than this is drained by
    ///      repeated calls rather than in one transaction that might not fit in a block.
    uint256 public constant SETTLE_BATCH_MAX = 64;

    /// @notice How far into the queue settlement has already got.
    /// @dev Task 7, item 4. Orders below the cursor are settled and inert; `_cancelOrdersOf` only
    ///      considers entries at or above it, so a cancellation can never rewind a fill. Reset to
    ///      zero — together with the queue itself — the moment the cursor reaches the end.
    uint256 public settleCursor;
    /// @notice How many queued, unsettled orders an account currently has.
    /// @dev Maintained in exactly four places — `createOrder` up, and down in `settleBatch`,
    ///      `_cancelOrdersOf` and `_purgeQueue`, which between them are every way an order leaves
    ///      the queue. `test_queuedOrderCountersTrackTheQueue` pins it against a direct scan.
    mapping(uint48 => uint256) public queuedOrdersOf;

    /// @notice How far into the withdrawal queue settlement has already got.
    /// @dev Task 6a. Exact counterpart of `settleCursor`, on its own queue: the two are drained in
    ///      the same `settleBatch` call but in independent windows, so they cannot share a cursor.
    uint256 public withdrawCursor;
    /// @notice How many queued, unexecuted withdrawal requests an account currently has.
    /// @dev Task 6a. Maintained in exactly two places — `withdraw` up and `_settleWithdrawals` down
    ///      — which are the only two ways a request enters or leaves the queue. Unlike an order, a
    ///      withdrawal request is never cancellable and never purgeable: the real venue's priority
    ///      requests are not withdrawable once submitted, and `_settleWithdrawals` consumes every
    ///      request it reaches whether it credits or refuses, so no request can jam its slot and no
    ///      operator hatch is needed for this queue.
    mapping(uint48 => uint256) public queuedWithdrawalsOf;

    /// @dev `internal`, not `private`, only so `MockLighter.queuedOrderCount()` / `lastOrder()`
    ///      can read it. Those two introspection helpers are test-only and stay off this base.
    Order[] internal _queue;
    /// @dev Task 6a. The withdrawal priority queue. `internal` for symmetry with `_queue`; nothing
    ///      outside this file reads it, and `withdrawQueueLength()` is the view.
    WithdrawalRequest[] internal _withdrawQueue;
    /// @dev Task 6a. The next `WithdrawalRequest.id`. Starts at 1 so 0 is never a real request.
    uint96 private _nextWithdrawalId = 1;
    mapping(address => mapping(uint16 => uint128)) private _pending;
    /// @dev Every market this contract has ever filled, so unrealisedPnl() can sum across them.
    uint16[] internal _markets;
    mapping(uint16 => bool) private _tracked;
    /// @dev Sum of all credited-but-undrained pending balances. `MockLighter._fundPending()`
    ///      reads it to keep the mock's real token holdings sufficient to honour them.
    uint256 internal _pendingTotal;

    constructor(IERC20 _collateral, uint16 _collateralAssetIndex, uint8 _sizeDecimals) {
        collateral = _collateral;
        collateralAssetIndex = _collateralAssetIndex;
        sizeDecimals = _sizeDecimals;
        _collateralDecimals = IERC20Metadata(address(_collateral)).decimals();
    }

    // ------------------------------------------------------------------------ ILighter surface

    /// @notice The venue account index `owner` may act as, or 0 if it has none yet.
    ///
    /// @dev TASK 6a/6b — THE CENTRAL CHANGE OF THIS TASK, and the reason it is a function rather
    ///      than the auto-generated getter of a public mapping it used to be.
    ///
    ///      `deposit()` USED TO ASSIGN THIS INLINE, so an address was registered and immediately
    ///      able to trade in the very transaction that funded it. On the real venue it is not: the
    ///      registering deposit is a PRIORITY REQUEST, and `addressToAccountIndex` returns 0 until
    ///      the rollup executes it. That is why the real `createOrder` reverts
    ///      `AccountIsNotRegistered` for a freshly-funded account, and why
    ///      `docs/DEPLOYMENT-CHECKLIST.md` step 8 calls the wait between `bootstrap()` and the
    ///      first mint "the real sequencing guarantee". A simulator that resolved the index inline
    ///      never opened that window, so no deployment rehearsal ever exercised the guarantee the
    ///      checklist step exists to protect — Global Constraint 5's exact shape, on the deployment
    ///      path.
    ///
    ///      SO THE ANSWER IS NOW GATED ON THE SETTLEMENT CLOCK. The registering deposit reserves an
    ///      index and records the batch that will execute it; this returns 0 until that batch has
    ///      settled. One `settleBatch` after the deposit is enough, which is exactly the sequence
    ///      `test/helpers/VaultFixture.sol` already performs (`bootstrap()` then `settleBatch()`)
    ///      and exactly the sequence the checklist prescribes.
    ///
    ///      WHY LAZY RATHER THAN A PENDING-REGISTRATION QUEUE DRAINED BY `settleBatch`. Both give
    ///      the same observable behaviour; this one costs no extra storage writes, no cursor, no
    ///      new bound on how many registrations one batch must walk, and — decisively —
    ///      nothing at all in `settleBatch`'s stack frame, which is already close to solc 0.8.24's
    ///      limit with `via_ir` forbidden (see `_coversInitialMargin`). A queue would have been a
    ///      new denial-of-service surface on the one function whose liveness the whole testnet
    ///      depends on, bought for no behavioural gain.
    ///
    ///      Returning 0 is what makes the window FAIL CLOSED rather than merely late: 0 is the
    ///      value `createOrder` and `withdraw` refuse with `AccountIsNotRegistered`, and it is what
    ///      `CertVault.lighterAccountIndex()` forwards, so the vault's own mint path reverts
    ///      atomically instead of half-hedging. `virtual` because `ILighter` declares this as a
    ///      function and a front end may need to fault-inject it.
    function addressToAccountIndex(address owner_) public view virtual returns (uint48) {
        uint256 resolvesAt = accountRegistrationBatch[owner_];
        if (resolvesAt == 0 || batchesSettled < resolvesAt) return 0;
        return _accountIndexOf[owner_];
    }

    /// @notice Post `amount` of collateral as margin for `to`, registering `to` if it is new.
    ///
    /// @dev TASK 8, ITEM 2 ADDED THREE REFUSALS, and the ORDER of the checks is load-bearing.
    ///      `LighterCore_ZeroDepositAmount` stays FIRST: `test/sim/DrainPoC.t.sol` pins the
    ///      free-registration closure by depositing zero and reading that exact selector back, and
    ///      a zero amount also satisfies all three new checks vacuously (0 is a multiple of any
    ///      tick and is under any cap), so putting any of them ahead of it would change the
    ///      reported reason for a state that is already refused.
    ///
    ///      All three are enforced on the SHARED CORE, so `MockLighter` inherits them and the whole
    ///      suite runs against the venue's real deposit gates rather than a looser set. That is the
    ///      same placement decision as the caller binding and for the same reason: a refusal the
    ///      venue makes is venue fidelity, not UseCert access control.
    function deposit(address to, uint16 assetIndex, uint8, uint256 amount) public payable virtual {
        // Fix round 1, Critical 1. See LighterCore_ZeroDepositAmount: a zero-value transferFrom
        // succeeds with no allowance and no balance, so this used to be a FREE registration.
        if (amount == 0) revert LighterCore_ZeroDepositAmount();
        // The argument was previously unnamed and therefore ignored. See
        // LighterCore_UnknownAssetIndex: a vault carrying the wrong USDG index is a deployment
        // misconfiguration with no on-chain recovery, and this simulator used to hide it.
        if (assetIndex != collateralAssetIndex) revert LighterCore_UnknownAssetIndex(assetIndex, collateralAssetIndex);
        uint256 tick = depositTickSize;
        if (amount % tick != 0) revert LighterCore_DepositNotTickMultiple(amount, tick);
        uint256 ticks = amount / tick;
        // The cap is denominated in TICKS, which is what `depositCapTicks` names and what
        // `withdraw` already compares against; at the default tick of 1 the two are the same
        // number, so this is the same ceiling on the way in as on the way out.
        if (ticks > depositCapTicks) revert AboveDepositCap();

        collateral.transferFrom(msg.sender, address(this), amount);
        // TASK 6b. The RESERVATION, not the registration. Read `_accountIndexOf` and not the
        // published view: a second deposit made before the batch that resolves the first one must
        // top up the SAME account, and reading the published (still zero) answer here would hand
        // the address a second index and orphan the first deposit's collateral in a book nobody
        // can ever name.
        uint48 idx = _accountIndexOf[to];
        if (idx == 0) {
            idx = _nextAccountIndex++;
            _accountIndexOf[to] = idx;
            // One `settleBatch` from now. See `accountRegistrationBatch`.
            uint256 resolvesAt = batchesSettled + 1;
            accountRegistrationBatch[to] = resolvesAt;
            _accounts.push(idx);
            emit AccountRegistered(to, idx, resolvesAt);
        }
        // Task 7: the collateral lands in `to`'s OWN book. It used to land in a shared pool, which
        // is what made every account's withdrawal ceiling every other account's balance.
        marginBalanceOf[idx] += amount;
        emit Deposited(to, idx, assetIndex, amount, ticks, marginBalanceOf[idx]);
    }

    function createOrder(
        uint48 accountIndex,
        uint16 marketIndex,
        uint48 baseAmount,
        uint32 price,
        uint8 isAsk,
        uint8 orderType
    ) public virtual {
        if (accountIndex == 0) revert AccountIsNotRegistered();
        _requireCallerOwnsAccount(accountIndex);
        if (marketIndex > 254) revert MarketIndexTooHigh();
        if (orderType > 1) revert BadOrderType();
        // Task 7, item 4. Both bounds, and both matter: the global one keeps every queue walk
        // affordable, the per-account one keeps the global one from being a lockout.
        if (_queue.length >= MAX_QUEUE) revert LighterCore_QueueFull();
        if (queuedOrdersOf[accountIndex] >= MAX_ORDERS_PER_ACCOUNT) revert LighterCore_AccountOrderCapReached();
        // `baseAmount == 0` is NOT rejected here. It is Lighter's documented close-all primitive
        // (see ILighter.sol) and `CertVault.closeAll()` is a real caller of it — governance's
        // wind-down of last resort submits a literal 0 on the side its own ledger says it holds. So
        // Task 7 takes the amendment's preferred option and SCOPES the reading instead: in
        // `settleBatch` a zero amount now means "the full size of the SUBMITTING ACCOUNT's
        // position". Rejecting it would have broken the one caller that legitimately needs it.
        uint96 id = _nextOrderId++;
        uint256 slot = _queue.length;
        _queue.push(Order(marketIndex, baseAmount, price, isAsk, orderType, accountIndex, id));
        ++queuedOrdersOf[accountIndex];
        // Task 8, item 1. The submission half of the lifecycle. Emitted AFTER the push so a
        // consumer that reads `queueSlot` reads the slot the order actually occupies.
        emit OrderEnqueued(accountIndex, marketIndex, id, baseAmount, price, isAsk, orderType, slot);
    }

    /// @dev Models AdditionalZkLighter.withdraw() on the real contract: it does NOT check the
    ///      account's balance — sufficiency is decided inside the rollup, not on-chain. It only
    ///      validates baseAmount != 0 and baseAmount <= depositCapTicks before enqueuing a
    ///      priority request. So this must not revert on insufficiency; instead it credits only
    ///      min(baseAmount, equity(accountIndex)) to pending, modelling a rollup batch that
    ///      fulfills what it can and strands the rest.
    ///
    ///      M3: the ceiling is equity, not cash. A withdrawal that draws on the position's gain
    ///      realises exactly the amount the cash balance cannot cover (moving entryPrice toward
    ///      markPrice so the same gain is never paid twice) and then debits it.
    ///
    ///      TASK 7, ITEM 0 — THE REAL FIX, and the whole reason this task exists. The ceiling is
    ///      `equity(accountIndex)`: the CALLER'S OWN cash plus the CALLER'S OWN share of PnL. It
    ///      used to be `equity()`, a global figure with no account parameter at all, so the two
    ///      caller-binding rounds before this one were closing the door on an attacker who was
    ///      already inside: bind the call to its caller and the caller could still name the whole
    ///      pool. Measured before this line existed, against the deployable artefact: an account
    ///      that had deposited 1 USDG withdrew 600_001 USDG and left the simulator at zero.
    /// @dev TASK 6a. THIS FUNCTION NOW ONLY ENQUEUES. It reads no balance, credits nothing and
    ///      mutates no book — every line of the fulfilment that used to be here has moved to
    ///      `_settleWithdrawals`, which a `settleBatch` runs.
    ///
    ///      WHY, in the venue's own terms. The real `AdditionalZkLighter.withdraw` performs NO
    ///      BALANCE CHECK: it validates `baseAmount != 0` and `baseAmount <= depositCapTicks`, then
    ///      enqueues a priority request. Sufficiency is decided inside the rollup, and an
    ///      insufficient request is rejected there with NO ON-CHAIN SIGNAL AND NO ROLLBACK — the
    ///      caller sees success and the cash never arrives. `getPendingBalance` is the only
    ///      on-chain evidence a withdrawal executed at all, which is precisely why
    ///      `CertVault.recallMargin` is two-phase and why `_sweepPending` reduces
    ///      `marginPendingRecall` only by what actually landed.
    ///
    ///      Crediting synchronously — which is what this did — meant `_sweepPending`'s "the money
    ///      may simply never come" path was NEVER EXERCISED by the suite or by a testnet
    ///      rehearsal. That path is the vault's entire defence against a venue that pays nothing,
    ///      and it was certified by nothing.
    ///
    ///      The four validations stay, and stay in this order, because they are the four the real
    ///      contract performs before enqueuing. The two queue bounds are new and are simulator
    ///      self-defence rather than venue fidelity — see `LighterCore_WithdrawQueueFull`.
    ///
    ///      NOTE THAT THE CEILING IS NOT CHECKED HERE, deliberately and importantly. Refusing an
    ///      over-large request at request time would make withdrawals all-or-nothing, and
    ///      `CertVault.recallMargin` deliberately OVER-REQUESTS — it asks for what the vault owes,
    ///      not what it deposited. See `WithdrawalUnfundable` for the measured Law 2 breach that
    ///      reintroduces.
    function withdraw(uint48 accountIndex, uint16 assetIndex, uint8, uint64 baseAmount) public virtual {
        if (accountIndex == 0) revert AccountIsNotRegistered();
        _requireCallerOwnsAccount(accountIndex);
        if (baseAmount == 0) revert ZeroBaseAmount();
        if (baseAmount > depositCapTicks) revert AboveDepositCap();
        if (_withdrawQueue.length >= MAX_QUEUE) revert LighterCore_WithdrawQueueFull();
        if (queuedWithdrawalsOf[accountIndex] >= MAX_ORDERS_PER_ACCOUNT) {
            revert LighterCore_AccountWithdrawCapReached();
        }

        uint96 id = _nextWithdrawalId++;
        uint256 slot = _withdrawQueue.length;
        _withdrawQueue.push(WithdrawalRequest(msg.sender, accountIndex, assetIndex, baseAmount, id));
        ++queuedWithdrawalsOf[accountIndex];
        emit WithdrawalRequested(msg.sender, accountIndex, assetIndex, baseAmount, id, slot);
    }

    /// @notice Cancel every queued order belonging to `accountIndex`, and nothing else.
    /// @dev Task 5, item 7 (C1). This used to ignore its argument entirely and `delete _queue`, so
    ///      any address — registered or not — could wipe the vault's pending hedge. Two things
    ///      changed: the caller must own the account it names, and the cancellation is scoped to
    ///      that account's own orders via `Order.account`. The queue is compacted in place, which
    ///      preserves the relative order of the surviving entries — `settleBatch` fills in queue
    ///      order, so a cancellation must not reshuffle another account's priority.
    function cancelAllOrders(uint48 accountIndex) public virtual {
        if (accountIndex == 0) revert AccountIsNotRegistered();
        _requireCallerOwnsAccount(accountIndex);
        _cancelOrdersOf(accountIndex);
    }

    function getPendingBalance(address owner, uint16 assetIndex) public view virtual returns (uint128) {
        return _pending[owner][assetIndex];
    }

    function withdrawPendingBalance(address owner, uint16 assetIndex, uint128 baseAmount) public virtual {
        _pending[owner][assetIndex] -= baseAmount;
        _pendingTotal = uint256(baseAmount) >= _pendingTotal ? 0 : _pendingTotal - uint256(baseAmount);
        collateral.transfer(owner, baseAmount);
        // Task 8, item 1. The only point in the whole withdrawal path at which collateral actually
        // leaves the venue. Everything before it is a credit against a pending balance.
        emit WithdrawalFulfilled(
            owner, addressToAccountIndex(owner), assetIndex, baseAmount, _pending[owner][assetIndex]
        );
    }

    // ------------------------------------------------------------------------ batch settlement

    /// @notice Fill up to `SETTLE_BATCH_MAX` queued orders at the current mark price, resolving and
    ///         margining each one against its own submitting account.
    ///
    /// @dev Fills that increase |position| must be covered by requiredMarginBps of the resulting
    ///      notional, valued at markPrice — the way a real venue would reject an under-margined
    ///      order rather than silently fill it. The check reads cash margin, not equity: a real
    ///      venue's initial-margin requirement is met with posted collateral, and every fill in the
    ///      suite happens at the mark it is valued against, so an increase carries no PnL of its own
    ///      to credit.
    ///
    ///      This lives on the shared base rather than on each front end. It is not a test
    ///      convenience: it is the simulator's central mechanic, `LighterSim` needs it to be a
    ///      venue at all, and duplicating it across two front ends is precisely the drift the
    ///      LighterCore extraction exists to prevent. `virtual` so Task 6 can make settlement
    ///      asynchronous in one place, and so `LighterSim` can gate it in one place.
    ///
    ///      TASK 7 CHANGED THREE THINGS HERE, and each one closes a reported hole:
    ///
    ///      1. `previous` is `positionBaseOf[o.account][o.marketIndex]`, not a global
    ///         `positionBase[market]`. Combined with the `baseAmount == 0` branch — which means
    ///         "the full position size on the side the caller named" — the global read let ANY
    ///         second account queue `createOrder(idx, market, 0, px, isAsk = 1, 1)` and zero out
    ///         the vault's entire hedge at settlement. Same harm as the pre-Task-5 `delete _queue`,
    ///         reached through settlement instead of cancellation. Reproduced before this change:
    ///         the vault's 100_000-tick hedge went to 0 in one settled batch.
    ///      2. The initial-margin check reads `marginBalanceOf[o.account]`, so an account can only
    ///         open what its OWN collateral covers. Reproduced before this change: an account
    ///         holding 1 USDG opened a $10,000 notional position on the pool's margin.
    ///      3. The order is checked BEFORE anything is written, and a failure rejects that order
    ///         and continues instead of reverting the batch. The old shape applied the fill, wrote
    ///         the position, and then reverted — correct only because the revert unwound it, which
    ///         is exactly why it could not be turned into a skip without reordering. A batch that
    ///         reverts as a whole was fix round 1's Critical 2: one account's poison order stopped
    ///         everyone's settlement permanently. `strictMode` restores the old behaviour for the
    ///         three tests that pin it.
    function settleBatch() public virtual {
        uint256 n = _queue.length;
        uint256 i = settleCursor;
        // Task 7, item 4. A cursor rather than a whole-queue loop, so a long queue is drained by
        // repeated calls instead of by one transaction that may not fit in a block.
        uint256 stop = n - i > SETTLE_BATCH_MAX ? i + SETTLE_BATCH_MAX : n;

        // Task 8, item 1. Advanced BEFORE the loop, so every event this call emits carries the same
        // batch id, and advanced unconditionally, so an empty settlement is still a tick of the
        // venue's clock. See `batchesSettled`.
        uint256 batchId = ++batchesSettled;
        uint256 from = i;
        uint256 filled;
        uint256 rejected;

        for (; i < stop; ++i) {
            Order memory o = _queue[i];
            // Consumed either way: rejected orders leave the queue too, or the rejection would be
            // a jam by another name.
            --queuedOrdersOf[o.account];

            int256 previous = positionBaseOf[o.account][o.marketIndex];
            int256 resulting;
            if (o.baseAmount == 0) {
                // M-3 (MEDIUM, external C1 audit). `baseAmount == 0` means "default to the full
                // position SIZE" — the size, not the direction. `isAsk` is still the caller's, so
                // this is an order for |position| units on the side the caller named, and an ASK
                // against a SHORT therefore DOUBLES the short instead of closing it.
                //
                // This mock used to set `resulting = 0` for any zero-amount order, ignoring isAsk
                // entirely, so no test in the suite could observe the difference — and
                // CertVault.closeAll() hardcoded SIDE_ASK. The governance wind-down of last resort
                // was therefore unverified in the one state where its direction matters.
                //
                // TASK 7: `previous` is now the SUBMITTING ACCOUNT's position. The reading is
                // unchanged; what changed is whose position it reads. A zero-amount order from an
                // account that holds nothing is now a no-op on an empty book instead of a
                // full-size order against someone else's hedge.
                //
                // REQUIRES CONFIRMATION against Lighter source, which is not in this repo: the
                // reading above comes from the design spec's section 3.1 table. It is the
                // CONSERVATIVE reading — it makes a wrong-side close-all harmful rather than
                // harmless — so a vault that is correct against this mock is correct against
                // either interpretation. See docs/DEPLOYMENT-CHECKLIST.md.
                uint256 magnitude = previous >= 0 ? uint256(previous) : uint256(-previous);
                resulting = o.isAsk == 1 ? previous - int256(magnitude) : previous + int256(magnitude);
            } else {
                int256 signed = o.isAsk == 1 ? -int256(uint256(o.baseAmount)) : int256(uint256(o.baseAmount));
                resulting = previous + signed;
            }

            // FIX ROUND 1 (Task 7 review, Important) + TASK 8, ITEM 1, MERGED. The gate itself
            // lives in `_coversInitialMargin` — item 1's batch-scoped locals put this frame over
            // solc 0.8.24's stack limit and `via_ir` is forbidden — and that helper computes
            // POST-REALISATION cash. Both halves are load-bearing; see the helper's own comment.
            //
            // Still checked BEFORE anything is written, so a rejection `continue`s with the books
            // untouched: `_coversInitialMargin` is a `view`.
            if (!_coversInitialMargin(o.account, o.marketIndex, previous, resulting)) {
                if (strictMode) revert InsufficientMargin();
                ++rejected;
                emit OrderRejected(o.account, o.marketIndex, o.id, batchId, InsufficientMargin.selector);
                continue;
            }

            _trackMarket(o.marketIndex);
            _applyFill(o.account, o.marketIndex, previous, resulting);
            positionBaseOf[o.account][o.marketIndex] = resulting;
            ++filled;
            // Task 8, item 1. `resulting - previous` rather than `o.baseAmount`: the two differ for
            // the close-all primitive, and the FILLED size is the one an indexer has to have.
            emit OrderFilled(
                o.account, o.marketIndex, o.id, batchId, markPrice[o.marketIndex], resulting - previous, resulting
            );
        }

        bool drained = i >= _queue.length;
        if (drained) {
            delete _queue;
            settleCursor = 0;
        } else {
            settleCursor = i;
        }
        emit BatchSettled(batchId, from, i, filled, rejected, drained);

        // TASK 6a. The withdrawal queue is drained in the same call, AFTER the fills, and as a
        // separate internal function rather than a second loop in this frame.
        //
        // AFTER THE FILLS on purpose: a fill realises PnL into cash and moves the position, so a
        // withdrawal executed in the same batch must see the book the batch produced, not the one
        // it started from. One batch, executed in order.
        //
        // A SEPARATE FUNCTION because `settleBatch` is close to solc 0.8.24's stack limit and
        // `via_ir` is forbidden — the same constraint that forced `_coversInitialMargin` out of
        // this frame in Task 8. A called function's locals live in its own frame, so this adds
        // nothing to the one above.
        _settleWithdrawals(batchId);
    }

    /// @notice Execute up to `SETTLE_BATCH_MAX` queued withdrawal requests.
    ///
    /// @dev TASK 6a. Everything `withdraw` used to do in the calling transaction happens here, one
    ///      batch later — which is the point of the task.
    ///
    ///      A request is CONSUMED whatever the outcome, exactly as a rejected order is: it leaves
    ///      the queue and its account's counter comes down. The real venue's priority requests are
    ///      not re-queued when the rollup cannot pay them, and a request that survived its own
    ///      refusal would be a jam by another name. This is why the queue needs no operator hatch
    ///      while the order queue does.
    function _settleWithdrawals(uint256 batchId) internal {
        uint256 n = _withdrawQueue.length;
        uint256 i = withdrawCursor;
        uint256 stop = n - i > SETTLE_BATCH_MAX ? i + SETTLE_BATCH_MAX : n;
        uint256 from = i;
        uint256 credited;
        uint256 refused;

        for (; i < stop; ++i) {
            WithdrawalRequest memory w = _withdrawQueue[i];
            --queuedWithdrawalsOf[w.account];
            if (_executeWithdrawal(w, batchId)) {
                ++credited;
            } else {
                ++refused;
            }
        }

        bool drained = i >= _withdrawQueue.length;
        if (drained) {
            delete _withdrawQueue;
            withdrawCursor = 0;
        } else {
            withdrawCursor = i;
        }
        emit WithdrawalsSettled(batchId, from, i, credited, refused, drained);
    }

    /// @notice Execute one withdrawal request: credit `min(request, available)` to the pending
    ///         balance, or refuse the whole request if this contract cannot back that credit.
    ///
    /// @dev TASK 6a, AND THE TWO CASES HERE MUST NOT BE CONFLATED. Conflating them is easy and the
    ///      consequence is a Law 2 breach, so both are spelled out.
    ///
    ///      CASE 1 — THE REQUEST EXCEEDS THE ACCOUNT'S AVAILABLE EQUITY. Partial fulfilment, and it
    ///      STAYS. `min(request, available)` is credited, the shortfall is announced through
    ///      `WithdrawalSilentlyRejected`, and nothing reverts. This is real venue behaviour: the
    ///      rollup fulfils what it can and strands the rest. It is also LOAD-BEARING for the
    ///      protocol, not merely faithful — `CertVault.recallMargin` deliberately over-requests,
    ///      asking the venue for what the vault OWES rather than what it deposited, which was the
    ///      C1 audit fix, and it is safe only because the venue fulfils `min(request, available)`
    ///      and `_sweepPending` reconciles whatever arrives. Measured at that audit: a receipt owed
    ///      7,102.97 while everything recallable totalled 3,559.54. All-or-nothing here makes that
    ///      receipt unpayable, which is the sharpest Law 2 breach the audit found — reintroduced
    ///      through the simulator rather than through the vault.
    ///
    ///      CASE 2 — THIS CONTRACT'S OWN TOKEN BALANCE CANNOT BACK THE CREDIT. Refused WHOLE, with
    ///      nothing credited and no book mutated, and `WithdrawalUnfundable` on the record. This is
    ///      the Task 4 review's finding I2. It is NOT a partial fill: the old code succeeded here,
    ///      debiting `marginBalance`, rewriting `entryPrice` through `_realiseGain` and bumping
    ///      `_pendingTotal`, and only the LATER `withdrawPendingBalance` reverted on the token
    ///      transfer — a permanently unsweepable pending credit against books that had already
    ///      moved, which on testnet presents as a vault wedged in `_sweepPending` forever. A
    ///      bookkeeping half-application, and the one thing in this file that fails closed.
    ///
    ///      THE ORDER OF THE THREE STEPS IS LOAD-BEARING. Fulfilment is decided, then `_fundPending`
    ///      is given its chance to produce the tokens (a no-op on `LighterSim`, a mint on
    ///      `MockLighter`), then the balance is checked — and only after all three does anything get
    ///      written. Checking before `_fundPending` would refuse credits the mock can honour;
    ///      writing before the check is the defect itself.
    ///
    ///      `balanceOf >= _pendingTotal + fulfilled` is exactly the condition that makes
    ///      `withdrawPendingBalance` unable to revert on the transfer, because
    ///      `_pending[owner][asset] <= _pendingTotal` always: every pending balance this contract
    ///      has promised is fully backed by tokens it holds.
    ///
    /// @return credited Whether anything was actually credited. A fulfilment of zero counts as not
    ///         credited and is reported through `WithdrawalSilentlyRejected` for its full amount —
    ///         it is a partial fill of nothing, which is the state a venue paying nothing at all
    ///         produces, and the one mainnet makes indistinguishable from paying in full.
    function _executeWithdrawal(WithdrawalRequest memory w, uint256 batchId) private returns (bool credited) {
        uint256 available = equity(w.account);
        uint256 fulfilled = w.baseAmount <= available ? w.baseAmount : available;

        // CASE 2, decided before a single write. See the doc comment.
        uint256 required = _pendingTotal + fulfilled;
        _fundPending(required);
        if (fulfilled > 0 && collateral.balanceOf(address(this)) < required) {
            emit WithdrawalUnfundable(w.owner, w.account, w.assetIndex, w.baseAmount, fulfilled, batchId);
            return false;
        }

        if (fulfilled > 0) {
            // M3, unchanged and moved verbatim: the ceiling is equity, not cash, so a withdrawal
            // drawing on the position's gain realises exactly the amount cash cannot cover —
            // moving `entryPrice` toward `markPrice` so the same gain is never paid twice — and
            // then debits it.
            uint256 cash = marginBalanceOf[w.account];
            if (fulfilled > cash) _realiseGain(w.account, fulfilled - cash);
            marginBalanceOf[w.account] -= fulfilled;
            _pendingTotal = required;
            _pending[w.owner][w.assetIndex] += uint128(fulfilled);
        }

        emit WithdrawalCredited(
            w.owner, w.account, w.assetIndex, w.baseAmount, fulfilled, _pending[w.owner][w.assetIndex], batchId
        );
        // CASE 1. The venue does not revert when it cannot pay in full: it credits what it can and
        // STRANDS the rest. On-chain that makes "paid nothing" indistinguishable from "paid in
        // full", so the shortfall is announced rather than left to be inferred from two storage
        // reads across a block.
        if (fulfilled < w.baseAmount) {
            emit WithdrawalSilentlyRejected(
                w.owner, w.account, w.assetIndex, w.baseAmount, fulfilled, w.baseAmount - fulfilled
            );
        }
        return fulfilled > 0;
    }

    /// @notice Whether `account` has posted enough cash to cover the initial margin on a fill that
    ///         moves its position from `previous` to `resulting`.
    ///
    /// @dev EXTRACTED IN TASK 8, AND THE REASON IS WORTH RECORDING BECAUSE IT CONSTRAINS FUTURE
    ///      EDITS. This body was inline in `settleBatch` until item 1 added three batch-scoped
    ///      locals (`batchId`, `from`, and the fill/reject counters) to it, at which point the
    ///      function no longer compiled: solc 0.8.24 without `via_ir` ran out of stack slots.
    ///      Global Constraint 1 forbids setting `via_ir` — it changes codegen for every contract in
    ///      the repo, including `CertVault`, whose EIP-170 margin is the deployment's tightest —
    ///      so the fix is fewer live locals in the frame, not a different pipeline. `settleBatch`
    ///      is close to that limit; anything added to it will need the same treatment.
    ///
    ///      THE EXTRACTION ITSELF CHANGES NO BEHAVIOUR, deliberately and in every particular:
    ///
    ///        * Only a fill that INCREASES |position| requires initial margin. A decrease or a
    ///          close returns true without reading a price, which is why this returns `true` rather
    ///          than computing a vacuous zero requirement.
    ///        * The requirement is valued at `markPrice`, against the resulting notional.
    ///        * It reads CASH, not equity. A real venue's initial margin is met with posted
    ///          collateral, and every fill here happens at the mark it is valued against, so an
    ///          increase carries no PnL of its own to credit.
    ///        * Task 7's fix is preserved exactly: the cash is the SUBMITTING account's own, never
    ///          a pool. That one read is what stopped an account holding 1 USDG from opening a
    ///          $10,000 position on everyone else's margin.
    ///
    /// @dev FIX ROUND 1 (Task 7 review, Important) — MERGED INTO THE EXTRACTION, AND THE ONE LINE
    ///      IN THIS FUNCTION THAT MUST NOT BE SIMPLIFIED BACK. The cash read is
    ///      `_cashAfterFillRealisation`, i.e. POST-REALISATION cash, NOT `marginBalanceOf[account]`.
    ///
    ///      Task 7 moved this gate above `_applyFill` — necessary, because a `continue` after a
    ///      write would half-apply a fill — but that also changed the check's INPUT. Reading
    ///      `marginBalanceOf` here reads cash BEFORE `_realisePortion` debits the loss on whatever
    ///      leg the fill closes, so a side-flipping order that both closes a losing leg and GROWS
    ///      the position passed the gate on cash it was about to lose. Measured at this repo's own
    ///      suite parameters: a 1000.01 USDG account, short 100_000 ticks at an entry of 100e18,
    ///      mark moved to 200e18, then a bid of 200_001 — required 1000.01e18 against a pre-fill
    ///      cash18 of exactly 1000.01e18, so it filled, and `_applyFill` then realised -1000 USDG
    ///      leaving 0.01 USDG of cash behind a 2000.02e18 notional long. The pre-Task-7 code read
    ///      the balance AFTER `_applyFill` and reverted `InsufficientMargin` on it.
    ///
    ///      Not a value-theft path — the loss floors at zero cash, `equity()` floors at zero, and
    ///      `_fundPending()` is a no-op on `LighterSim` — but it made the simulator EASIER than the
    ///      venue, which is the one direction Global Constraint 5 forbids, on the deployment path
    ///      that exists today.
    ///
    ///      The gate still rejects without having mutated anything: this function is a `view`, and
    ///      `_cashAfterFillRealisation` shares `_closedPortion`, `_realisedPnlOn` and `_creditDebit`
    ///      with `_applyFill`, so the figure it predicts is the figure the fill will produce.
    ///      Getting this wrong in the other direction is a deviation too, so the suite pins both —
    ///      see `test_aFlipAffordableOnlyOnTheRealisedGainStillFills`.
    ///
    ///      This is why the Task 8 extraction could not be taken as-written on top of the fix: the
    ///      extracted body was behaviour-identical against the PRE-FIX gate, and reinstating its
    ///      `marginBalanceOf` read here would silently reopen the relaxation.
    function _coversInitialMargin(uint48 account, uint16 marketIndex, int256 previous, int256 resulting)
        internal
        view
        returns (bool)
    {
        uint256 absResulting = resulting >= 0 ? uint256(resulting) : uint256(-resulting);
        uint256 absPrevious = previous >= 0 ? uint256(previous) : uint256(-previous);
        if (absResulting <= absPrevious) return true;
        uint256 notional18 = absResulting * markPrice[marketIndex] / (10 ** sizeDecimals);
        uint256 requiredMargin18 = notional18 * requiredMarginBps / 10_000;
        uint256 cash = _cashAfterFillRealisation(account, marketIndex, previous, resulting);
        uint256 cash18 = _collateralDecimals <= 18
            ? cash * (10 ** (18 - _collateralDecimals))
            : cash / (10 ** (_collateralDecimals - 18));
        return cash18 >= requiredMargin18;
    }

    // ----------------------------------------------------------------------- mark-to-market

    /// @notice Unrealised PnL for one account across every market it holds, in collateral units.
    /// @dev `positionBase * (markPrice - entryPrice) / 10**sizeDecimals` gives an 18-decimal
    ///      figure; it is scaled to the collateral's own decimals here so it can be added to that
    ///      account's cash margin directly.
    function unrealisedPnl(uint48 accountIndex) public view virtual returns (int256 pnl) {
        for (uint256 i = 0; i < _markets.length; ++i) {
            pnl += _toCollateral(_pnl18(accountIndex, _markets[i]));
        }
    }

    /// @notice What ONE ACCOUNT can actually draw on: its own cash margin plus its own position's
    ///         mark-to-market gain (or minus its loss). Floored at zero.
    ///
    /// @dev TASK 7, ITEM 0. There is deliberately no no-argument overload. `equity()` with no
    ///      account was `withdraw`'s ceiling for two fix rounds and it is the single line that made
    ///      every one of this simulator's Criticals a total drain rather than a single-account one;
    ///      leaving a global overload callable would leave the next `withdraw`-shaped entry point
    ///      one autocomplete away from reintroducing it. Callers that want the venue-level figure
    ///      sum `marginBalance()` and `unrealisedPnl()`, and neither of those decides anything.
    function equity(uint48 accountIndex) public view virtual returns (uint256) {
        int256 e = int256(marginBalanceOf[accountIndex]) + unrealisedPnl(accountIndex);
        return e <= 0 ? 0 : uint256(e);
    }

    // --------------------------------------------------------------------- aggregate views
    //
    // Task 7. Venue-level mirrors of the per-account books above. Views only: no mechanic reads
    // them, so none of them can be a ceiling, a margin allowance, or a position an order resolves
    // against — which is what each of them used to be.

    /// @notice Total collateral posted as margin across every account, in token units.
    function marginBalance() public view virtual returns (uint256 total) {
        for (uint256 i = 0; i < _accounts.length; ++i) {
            total += marginBalanceOf[_accounts[i]];
        }
    }

    /// @notice Net signed position across every account in one market, in base ticks. The venue's
    ///         open interest, not any one account's exposure.
    function positionBase(uint16 marketIndex) public view virtual returns (int256 net) {
        for (uint256 i = 0; i < _accounts.length; ++i) {
            net += positionBaseOf[_accounts[i]][marketIndex];
        }
    }

    /// @notice Size-weighted mean entry price across every account holding one market, scaled to
    ///         1e18. Zero when no account holds it.
    /// @dev The only aggregate of a price that means anything. On a single-account venue — which is
    ///      every deployment Task 10 performs, and every fixture in the suite — it is exactly that
    ///      account's own entry.
    function entryPrice(uint16 marketIndex) public view virtual returns (uint256) {
        uint256 weighted;
        uint256 size;
        for (uint256 i = 0; i < _accounts.length; ++i) {
            int256 pos = positionBaseOf[_accounts[i]][marketIndex];
            if (pos == 0) continue;
            uint256 abs = pos >= 0 ? uint256(pos) : uint256(-pos);
            weighted += abs * entryPriceOf[_accounts[i]][marketIndex];
            size += abs;
        }
        return size == 0 ? 0 : weighted / size;
    }

    /// @notice Unrealised PnL across every account and market, in collateral token units.
    function unrealisedPnl() public view virtual returns (int256 pnl) {
        for (uint256 i = 0; i < _accounts.length; ++i) {
            pnl += unrealisedPnl(_accounts[i]);
        }
    }

    /// @notice How many accounts have ever registered on this venue.
    function accountCount() public view virtual returns (uint256) {
        return _accounts.length;
    }

    /// @notice How many orders are queued, settled prefix included.
    function queueLength() public view virtual returns (uint256) {
        return _queue.length;
    }

    /// @notice Every credited-but-undrained pending balance, summed.
    ///
    /// @dev Task 6a. The venue's total outstanding promise, and the figure the fail-closed check in
    ///      `_executeWithdrawal` is written against: `collateral.balanceOf(this) >= pendingTotal()`
    ///      is the invariant that makes `withdrawPendingBalance` unable to revert on its transfer.
    ///      Exposed so a test can assert it did not move across a refused withdrawal — which is the
    ///      whole of finding I2 — and so an operator can check the invariant with one read instead
    ///      of summing every account's pending balance.
    function pendingTotal() public view virtual returns (uint256) {
        return _pendingTotal;
    }

    /// @notice How many withdrawal requests are queued, executed prefix included.
    /// @dev Task 6a. Counterpart of `queueLength()`, and the read that lets a test or an operator
    ///      distinguish "the request was never submitted" from "the request is submitted and
    ///      waiting for a batch" — which before this task were the same on-chain state.
    function withdrawQueueLength() public view virtual returns (uint256) {
        return _withdrawQueue.length;
    }

    // ----------------------------------------------------------------------------- internals

    /// @dev Task 5, item 7 (C1). The venue's `validateAndGetAccountIndexFromAddress`, modelled: an
    ///      account-scoped call may only act on the account the CALLER is registered as.
    ///
    ///      `deposit` is deliberately NOT bound this way. `deposit(to, ...)` legitimately registers
    ///      another address — the vault is registered by whoever funds it, which is how
    ///      `CertVault.bootstrap()` gets an account index at all — and that must keep working.
    ///      Only the account-scoped operations (`withdraw`, `createOrder`, `cancelAllOrders`) are
    ///      bound.
    function _requireCallerOwnsAccount(uint48 accountIndex) internal view {
        // TASK 6b. Reads the PUBLISHED index, so an address whose registering deposit has not been
        // settled yet owns no account and can act on none. Deliberately still
        // `LighterCore_AccountNotCaller` rather than `AccountIsNotRegistered` for a caller with no
        // published index: the two are distinct venue refusals — "you are not registered" is about
        // the ACCOUNT NAMED IN CALLDATA (the `accountIndex == 0` check in each entry point, which
        // is the one `CertVault` reaches, because `lighterAccountIndex()` forwards the 0), while
        // this one is about the CALLER not owning the account it named. `test/sim/DrainPoC.t.sol`
        // pins the unregistered-stranger case on this exact selector.
        if (accountIndex != addressToAccountIndex(msg.sender)) revert LighterCore_AccountNotCaller();
    }

    /// @dev The queue-compaction half of `cancelAllOrders`, with NO authorisation of its own.
    ///      Extracted in fix round 1 so `LighterSim`'s owner escape hatch can drop a stuck
    ///      account's orders without duplicating the compaction — the hatch is ADDITIONAL to the
    ///      per-account scoping above, never a relaxation of it: every non-owner path still goes
    ///      through `cancelAllOrders`, which still binds the caller.
    ///
    ///      Compaction in place, not `delete`: `settleBatch` fills in queue order, so removing one
    ///      account's orders must not reshuffle another account's priority.
    ///
    ///      Task 7: the walk starts at `settleCursor`, not at 0. Entries below the cursor are
    ///      already filled, and compacting over them would either rewind a fill or re-settle one.
    ///      That also bounds the cost at `MAX_QUEUE` iterations rather than at the array's length.
    /// @return cancelled How many orders were removed.
    function _cancelOrdersOf(uint48 accountIndex) internal returns (uint256 cancelled) {
        uint256 start = settleCursor;
        uint256 kept = start;
        uint256 n = _queue.length;
        for (uint256 i = start; i < n; ++i) {
            if (_queue[i].account == accountIndex) continue;
            if (kept != i) _queue[kept] = _queue[i];
            ++kept;
        }
        for (uint256 i = n; i > kept; --i) {
            _queue.pop();
        }
        cancelled = n - kept;
        queuedOrdersOf[accountIndex] -= cancelled;
        // Task 8, item 1. The third terminal state an enqueued order can reach, after filled and
        // rejected. Without it a consumer waits for a fill that will never come.
        emit OrdersCancelled(accountIndex, cancelled, _queue.length);
    }

    /// @dev The whole-queue half of `LighterSim.ownerPurgeQueue`, with no authorisation of its own.
    ///      Iterates rather than `delete`ing blind, because `queuedOrdersOf` has to come down with
    ///      the orders it counts — a purge that left the counters standing would lock every purged
    ///      account out of `createOrder` up to `MAX_ORDERS_PER_ACCOUNT` forever. Bounded by
    ///      `MAX_QUEUE`.
    /// @return cancelled How many unsettled orders were removed.
    function _purgeQueue() internal returns (uint256 cancelled) {
        uint256 n = _queue.length;
        for (uint256 i = settleCursor; i < n; ++i) {
            --queuedOrdersOf[_queue[i].account];
            ++cancelled;
        }
        delete _queue;
        settleCursor = 0;
    }

    /// @dev Book-keeps `accountIndex`'s entryPrice across one fill, realising PnL on whatever the
    ///      fill closes. Called with positionBaseOf[accountIndex][m] still holding `prev`.
    ///
    /// @dev FIX ROUND 1 (Task 7 review, Important). WHICH leg a fill closes is now decided in one
    ///      place, `_closedPortion`, because `settleBatch`'s initial-margin gate has to predict the
    ///      same answer this function acts on. The branch structure and every entry-price write
    ///      below are unchanged — only the three `_realisePortion` arguments now come from the
    ///      shared helper instead of being recomputed per branch.
    function _applyFill(uint48 accountIndex, uint16 m, int256 prev, int256 res) internal {
        uint256 fillPx = markPrice[m];
        if (res == 0) {
            _realisePortion(accountIndex, m, _closedPortion(prev, res), fillPx);
            entryPriceOf[accountIndex][m] = 0;
            return;
        }
        if (prev == 0) {
            entryPriceOf[accountIndex][m] = fillPx;
            return;
        }

        uint256 absPrev = prev >= 0 ? uint256(prev) : uint256(-prev);
        uint256 absRes = res >= 0 ? uint256(res) : uint256(-res);
        bool sameSign = (prev > 0) == (res > 0);

        if (sameSign && absRes > absPrev) {
            // Position increased: volume-weighted entry over old size and newly filled size.
            entryPriceOf[accountIndex][m] =
                (absPrev * entryPriceOf[accountIndex][m] + (absRes - absPrev) * fillPx) / absRes;
        } else if (sameSign) {
            // Partial close: realise the closed slice, leave the entry of the remainder alone.
            _realisePortion(accountIndex, m, _closedPortion(prev, res), fillPx);
        } else {
            // Flipped side: the whole old position closed, the remainder is a new entry.
            _realisePortion(accountIndex, m, _closedPortion(prev, res), fillPx);
            entryPriceOf[accountIndex][m] = fillPx;
        }
    }

    /// @dev How much of `prev` (signed, base ticks) a fill to `res` CLOSES, and therefore realises.
    ///
    /// @dev FIX ROUND 1 (Task 7 review, Important). The single source of truth for that decision,
    ///      shared by `_applyFill` — which acts on it — and by `_cashAfterFillRealisation`, which
    ///      predicts it for `settleBatch`'s initial-margin gate. Two copies of this branch table
    ///      would be free to drift, and a gate that predicted a different closed leg than the fill
    ///      applies is the same class of defect as the one this round fixes. `_applyFill` keeps its
    ///      own branch structure for the ENTRY-PRICE writes, which differ per branch; only the
    ///      realised portion is centralised here.
    ///
    ///      Cases, matching `_applyFill` exactly: nothing closes when there was no position, or
    ///      when a same-sign fill grows it (the entry is re-weighted instead); a fill to zero and a
    ///      side flip both close the whole of `prev`; a same-sign shrink closes the difference.
    function _closedPortion(int256 prev, int256 res) internal pure returns (int256) {
        if (prev == 0) return 0;
        if (res == 0) return prev;
        if ((prev > 0) != (res > 0)) return prev; // flipped side
        uint256 absPrev = prev >= 0 ? uint256(prev) : uint256(-prev);
        uint256 absRes = res >= 0 ? uint256(res) : uint256(-res);
        if (absRes >= absPrev) return 0; // grew, or unchanged in size
        uint256 closed = absPrev - absRes;
        return prev > 0 ? int256(closed) : -int256(closed);
    }

    /// @dev The signed PnL, in collateral units, that realising `portion` of `accountIndex`'s
    ///      market `m` at `fillPx` produces. A `view`: the arithmetic half of `_realisePortion`,
    ///      split out so the margin gate can ask the question without answering it.
    function _realisedPnlOn(uint48 accountIndex, uint16 m, int256 portion, uint256 fillPx)
        internal
        view
        returns (int256)
    {
        int256 entry = int256(entryPriceOf[accountIndex][m]);
        if (entry == 0 || portion == 0) return 0;
        int256 pnl18 = portion * (int256(fillPx) - entry) / int256(10 ** uint256(sizeDecimals));
        return _toCollateral(pnl18);
    }

    /// @dev Apply `pnl` to a cash balance. A loss FLOORS AT ZERO rather than underflowing, which is
    ///      the venue's own behaviour — an account cannot be pushed into debt here — and is the
    ///      reason the relaxation this round fixes could not move value even while it existed.
    function _creditDebit(uint256 cash, int256 pnl) internal pure returns (uint256) {
        if (pnl > 0) return cash + uint256(pnl);
        if (pnl == 0) return cash;
        uint256 loss = uint256(-pnl);
        return loss >= cash ? 0 : cash - loss;
    }

    /// @dev What `accountIndex`'s cash margin WILL be once `_applyFill(accountIndex, m, prev, res)`
    ///      has realised whatever that fill closes — computed without writing anything, so
    ///      `settleBatch` can gate on it and still `continue` with the books untouched.
    ///      Reads the same pre-fill `entryPriceOf`/`marginBalanceOf`/`markPrice[m]` that
    ///      `_applyFill` will read, through the same three helpers, so the two agree by
    ///      construction rather than by comment.
    function _cashAfterFillRealisation(uint48 accountIndex, uint16 m, int256 prev, int256 res)
        internal
        view
        returns (uint256)
    {
        return _creditDebit(
            marginBalanceOf[accountIndex],
            _realisedPnlOn(accountIndex, m, _closedPortion(prev, res), markPrice[m])
        );
    }

    /// @dev Realise `portion` (signed, base ticks) of `accountIndex`'s market `m` at `fillPx` into
    ///      that account's own cash margin.
    function _realisePortion(uint48 accountIndex, uint16 m, int256 portion, uint256 fillPx) internal {
        int256 pnl = _realisedPnlOn(accountIndex, m, portion, fillPx);
        if (pnl == 0) return;
        marginBalanceOf[accountIndex] = _creditDebit(marginBalanceOf[accountIndex], pnl);
    }

    /// @dev Convert `need` collateral units of `accountIndex`'s unrealised gain into that account's
    ///      cash, moving its entryPrice toward markPrice by exactly that much so the same gain can
    ///      never be drawn twice.
    function _realiseGain(uint48 accountIndex, uint256 need) internal {
        for (uint256 i = 0; i < _markets.length && need > 0; ++i) {
            uint16 m = _markets[i];
            int256 pnl = _toCollateral(_pnl18(accountIndex, m));
            if (pnl <= 0) continue;
            uint256 gain = uint256(pnl);
            uint256 take = need < gain ? need : gain;
            _setRemainingGain(accountIndex, m, gain - take);
            marginBalanceOf[accountIndex] += take;
            need -= take;
        }
    }

    /// @dev Rewrite entryPriceOf[accountIndex][m] so that account's unrealised gain in that market
    ///      becomes exactly `rem`.
    function _setRemainingGain(uint48 accountIndex, uint16 m, uint256 rem) internal {
        int256 pos = positionBaseOf[accountIndex][m];
        if (pos == 0) {
            entryPriceOf[accountIndex][m] = 0;
            return;
        }
        int256 delta = _from18Inverse(rem) * int256(10 ** uint256(sizeDecimals)) / pos;
        int256 newEntry = int256(markPrice[m]) - delta;
        entryPriceOf[accountIndex][m] = newEntry <= 0 ? 0 : uint256(newEntry);
    }

    function _pnl18(uint48 accountIndex, uint16 m) internal view returns (int256) {
        int256 pos = positionBaseOf[accountIndex][m];
        if (pos == 0) return 0;
        int256 entry = int256(entryPriceOf[accountIndex][m]);
        if (entry == 0) return 0;
        return pos * (int256(markPrice[m]) - entry) / int256(10 ** uint256(sizeDecimals));
    }

    function _toCollateral(int256 v18) internal view returns (int256) {
        return _collateralDecimals <= 18
            ? v18 / int256(10 ** uint256(18 - _collateralDecimals))
            : v18 * int256(10 ** uint256(_collateralDecimals - 18));
    }

    function _from18Inverse(uint256 vCollateral) internal view returns (int256) {
        return _collateralDecimals <= 18
            ? int256(vCollateral * (10 ** uint256(18 - _collateralDecimals)))
            : int256(vCollateral / (10 ** uint256(_collateralDecimals - 18)));
    }

    function _trackMarket(uint16 m) internal {
        if (_tracked[m]) return;
        _tracked[m] = true;
        _markets.push(m);
    }

    /// @dev Hook asking the front end to make this contract's token balance at least `required`.
    ///      A NO-OP here, and that is the conservative default: on the real venue the tokens
    ///      backing a gain-drawing withdrawal are the losing counterparty's collateral, so a
    ///      simulator that cannot produce them must fail rather than conjure them. `MockLighter`
    ///      overrides this to mint the shortfall, which is a *test* convenience — see the
    ///      override's comment. Keeping it off this base is what stops `LighterSim` from being
    ///      easier than mainnet.
    ///
    /// @dev TASK 6a CHANGED THE SIGNATURE AND THE CALL SITE, and both changes are the fix for
    ///      finding I2. It used to take no argument, read `_pendingTotal` itself, and be called
    ///      AFTER `_pendingTotal` had already been incremented and the margin already debited — so
    ///      a failure to produce the tokens was unobservable at the decision point and surfaced
    ///      only when `withdrawPendingBalance` later reverted on the transfer, against books that
    ///      had already moved. It is now called BEFORE anything is written, with the balance the
    ///      caller is about to need, and `_executeWithdrawal` refuses the whole request if the
    ///      balance is still short. Passing `required` rather than letting the hook read a
    ///      half-updated `_pendingTotal` is what makes that ordering expressible at all.
    function _fundPending(uint256 required) internal virtual {}
}
