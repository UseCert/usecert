// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {ICertOracle} from "./interfaces/ICertOracle.sol";

/// @notice Price source for one asset. Chainlink is the holder-facing price; the Lighter mark
///         price is a cross-check. Guard breaches pause MINTING only — pxUnguarded() always
///         answers so redemption can never be trapped (Law 2).
contract CertOracle is ICertOracle {
    error CertOracle_StalePrice();
    error CertOracle_NonPositivePrice();
    error CertOracle_TickOverflow();
    error CertOracle_OnlyAttester();
    /// @dev H-1: the deviation reference is rate-limited. An out-of-band price has been observed
    ///      but has not yet held for a full `pokeConfirmationSeconds`, so the reference may not
    ///      advance onto it yet. The remedy is to wait: poke again once the window has elapsed.
    error CertOracle_ReferenceRateLimited();
    /// @dev H-1 / Task 1: the confirmation window HAS elapsed, but the feed is still reporting the
    ///      same round that armed the candidate, so nothing has independently re-reported the
    ///      dislocation. Distinct from CertOracle_ReferenceRateLimited on purpose: the two have
    ///      different remedies and a caller must be able to tell "wait longer" from "the feed has
    ///      not spoken again". Sharing one error would make a dead feed look like a young one.
    error CertOracle_ReferenceRoundNotAdvanced();
    /// @dev Task 1: a constructor parameter outside its permitted range. Currently only
    ///      `pokeConfirmationSeconds == 0`, at which the `roundId` proof is the only remaining
    ///      gate — and that proof bounds round DISTINCTNESS, not RATE. Zero does NOT let an arm
    ///      and its confirmation land in the same block (that is refused at every window value);
    ///      it degrades the rate limit to one clamped step per block that carries a new feed
    ///      round, which is a rate limit in name only. The measured behaviour is on the
    ///      constructor's check.
    error CertOracle_ConfigOutOfBounds();
    /// @dev M-5: only the rotation authority bound at deploy may propose a new attester.
    error CertOracle_OnlyGovernance();
    /// @dev L-3, and M-5's hard floor: an attester of address(0) would freeze markPx18 and
    ///      CertVault.accrueFunding forever. Never constructible, never installable.
    error CertOracle_ZeroAddress();
    error CertOracle_NoPendingAttester();
    error CertOracle_RotationNotDue();

    /// @dev M-5 (Law 3): a rotation is a public commitment with a published effective time.
    event AttesterRotationProposed(address indexed attester, uint256 effectiveAt);
    event AttesterRotated(address indexed previous, address indexed attester);

    /// @notice The immutable notice period every attester rotation must serve.
    /// @dev M-5. The full argument for why the ceiling bounds SPEED rather than magnitude, and why
    ///      it is a constant rather than a per-deployment immutable, lives on
    ///      SolvencyRegistry.ATTESTER_ROTATION_DELAY. It applies unchanged here, with one addition
    ///      specific to this contract: the powers this attester holds are markPx18 (which feeds
    ///      mintAllowed()'s basis band, so it can pause minting or unpause it, and which no
    ///      redemption path reads) and, via CertVault.accrueFunding, the BufferBook ledger (which
    ///      sits under a `min` since M-1 and can therefore only tighten capacity). pxUnguarded()
    ///      — Law 2's price — is not attester-writable at all and is not affected by a rotation.
    uint256 public constant ATTESTER_ROTATION_DELAY = 2 days;

    IAggregatorV3 public immutable feed;
    /// @notice The rotation authority. Immutable, bound to the deployer at construction.
    /// @dev M-5: msg.sender rather than a constructor parameter, matching SolvencyRegistry so the
    ///      two attested-data contracts bind the same role the same way and one deployment rule
    ///      covers both. DEPLOYMENT REQUIREMENT (docs/DEPLOYMENT-CHECKLIST.md): deploy this
    ///      DIRECTLY FROM the governance multisig. An explicit parameter is the C2 cleanup; see
    ///      SolvencyRegistry.governance for why the arity is frozen in this pass.
    address public immutable governance;
    /// @notice Who may write markPx18 and relay the buffer accrual. No longer immutable.
    address public attester;
    /// @notice The proposed next attester and the timestamp from which it may be installed.
    /// @dev Zero means none pending. Re-proposing overwrites and restarts the notice period;
    ///      proposing the incumbent is how a rotation is abandoned.
    address public pendingAttester;
    uint256 public pendingAttesterAt;
    /// @dev market price_decimals; 2 for TSLA and NVDA
    uint8 public immutable priceDecimals;
    uint256 public immutable stalenessSeconds;
    /// @dev max |chainlink - lastGood| in bps before minting pauses
    uint256 public immutable deviationBps;
    /// @dev max |mark - chainlink| in bps before minting pauses
    uint256 public immutable basisBandBps;
    /// @notice How long an out-of-band observation must hold before the deviation reference may
    ///         take one clamped step onto it.
    /// @dev Task 1: the breaker's rate limit, and DELIBERATELY NOT `stalenessSeconds`. See
    ///      pokeLastGood for the full argument. Never zero (CertOracle_ConfigOutOfBounds).
    uint256 public immutable pokeConfirmationSeconds;

    uint256 public markPx18;
    /// @dev The deviation breaker's reference price. Only the constructor and pokeLastGood write
    ///      it, and pokeLastGood is rate-limited (see H-1 there).
    uint256 public lastGoodPx18;
    /// @dev L-4: ONE meaning, everywhere — the FEED ROUND timestamp (`latestRoundData().updatedAt`)
    ///      of the feed observation that last wrote `lastGoodPx18`. It is NOT the block time of
    ///      that write. The constructor used to record `block.timestamp` here while pokeLastGood
    ///      recorded the feed's `updatedAt`, so one field carried two clocks and any consumer
    ///      computing `block.timestamp - lastGoodAt` got a different answer depending on which
    ///      write it happened to be reading. The feed-round meaning is the one that matches
    ///      `pxUnguarded()`'s contract: its live branch returns the feed's own `updatedAt`, so the
    ///      fallback branch must return the same kind of number or the pair is not comparable.
    /// @dev When an advance is clamped (H-1), `lastGoodPx18` is a bounded step TOWARD the price
    ///      the feed reported at `lastGoodAt` rather than that price itself; `lastGoodAt` still
    ///      records the observation the step was taken from, i.e. how fresh the reference is.
    uint256 public lastGoodAt;

    /// @dev H-1, phase one: an out-of-band price awaiting confirmation. Not the reference — the
    ///      breaker never measures against this, it only decides whether an advance has earned
    ///      the right to happen.
    uint256 public pendingPx18;
    /// @dev H-1: BLOCK timestamp at which `pendingPx18` was first observed. Deliberately a
    ///      different clock from `lastGoodAt` (L-4's lesson: do not overload one field with two
    ///      meanings). It must be block time, not feed time: it measures how long the dislocation
    ///      has survived in the real world, and a feed that lags reports would otherwise shorten
    ///      its own confirmation window.
    uint256 public pendingSince;
    /// @dev H-1 / Task 1: the feed ROUND ID of the observation that armed `pendingPx18`. This is
    ///      the distinctness proof's anchor: a confirmation is only accepted from a round strictly
    ///      greater than this one, so "the price held" means the feed independently re-reported
    ///      it and never that one round was read twice. Written and cleared in lockstep with
    ///      `pendingSince` — see `_clearPending` and the two arming sites in pokeLastGood — so the
    ///      pair can never disagree about whether a candidate is armed.
    uint80 public pendingRoundId;

    constructor(
        address _feed,
        address _attester,
        uint8 _priceDecimals,
        uint256 _stalenessSeconds,
        uint256 _deviationBps,
        uint256 _basisBandBps,
        uint256 _pokeConfirmationSeconds
    ) {
        // L-3: no constructor in src/ validated its dependencies, so a mistyped address deployed
        // silently and failed later at an arbitrary call site. A zero feed is the sharpest case —
        // _readFeed below would revert on it and take the whole deployment down anyway, but with an
        // anonymous low-level failure rather than a named error.
        if (_feed == address(0) || _attester == address(0)) revert CertOracle_ZeroAddress();
        // Task 1: a zero confirmation window leaves the `roundId` proof as the ONLY gate, and that
        // proof bounds round DISTINCTNESS, not RATE.
        //
        // What zero does NOT do, measured with this guard lifted (fix round 1 review, and two
        // earlier write-ups of this check got it wrong in the same direction): it does not permit
        // an atomic walk. An arm plus a same-block poke carrying a brand-new round reverts
        // CertOracle_ReferenceRateLimited, because arming writes `pendingSince = block.timestamp`
        // and the strict `0 > 0` is false. Ten further fresh rounds inside that same block all
        // revert identically and the reference does not move. A second confirmation in the block
        // of a SUCCESSFUL one reverts the same way, because the confirm path re-arms `pendingSince`
        // to the current block time. So H-1's atomic reference reset stays shut even at zero.
        //
        // What zero DOES do is degrade the rate limit to ONE clamped `deviationBps` step per block
        // that carries a new feed round. Not atomic — but on a fast chain that is roughly 5% of
        // the reference per block: a 20% dislocation was absorbed in four blocks end to end
        // (100 -> 105 -> 110.25 -> 115.7625 -> 120, at deviationBps = 500). A rate limit that
        // concedes a full clamped step every block is a rate limit in name only, and that is the
        // real and sufficient reason to refuse zero. Refuse it at deploy time rather than discover
        // it live.
        if (_pokeConfirmationSeconds == 0) revert CertOracle_ConfigOutOfBounds();
        feed = IAggregatorV3(_feed);
        attester = _attester;
        governance = msg.sender;
        priceDecimals = _priceDecimals;
        stalenessSeconds = _stalenessSeconds;
        deviationBps = _deviationBps;
        basisBandBps = _basisBandBps;
        pokeConfirmationSeconds = _pokeConfirmationSeconds;

        // L-4: the constructor checked positivity but not staleness, so a vault could be deployed
        // against an already-dead feed and start life with a reference price nobody had quoted for
        // days. Same guard shape as px(), future-timestamp half FIRST so it short-circuits the
        // subtraction (CRITICAL B) — and the same named error, not an arithmetic panic.
        (uint256 p, uint256 t,) = _readFeed();
        if (t > block.timestamp || block.timestamp - t > _stalenessSeconds) revert CertOracle_StalePrice();
        lastGoodPx18 = p;
        // L-4: the feed round timestamp, matching pokeLastGood and pxUnguarded's live branch.
        lastGoodAt = t;
    }

    function setMarkPrice(uint256 px18) external {
        if (msg.sender != attester) revert CertOracle_OnlyAttester();
        markPx18 = px18;
    }

    /// @notice Start an attester rotation. Governance-gated; effective no sooner than
    ///         ATTESTER_ROTATION_DELAY from now.
    /// @dev M-5: a role change, not a trading power (Law 6). It cannot move collateral, place an
    ///      order, pause anything, or reach a redemption path.
    function proposeAttester(address next) external {
        if (msg.sender != governance) revert CertOracle_OnlyGovernance();
        if (next == address(0)) revert CertOracle_ZeroAddress();
        pendingAttester = next;
        pendingAttesterAt = block.timestamp + ATTESTER_ROTATION_DELAY;
        emit AttesterRotationProposed(next, pendingAttesterAt);
    }

    /// @notice Install a rotation whose notice period has elapsed. Permissionless (Law 6) — see
    ///         SolvencyRegistry.acceptAttester for why anyone may finalise.
    function acceptAttester() external {
        address next = pendingAttester;
        if (next == address(0)) revert CertOracle_NoPendingAttester();
        if (block.timestamp < pendingAttesterAt) revert CertOracle_RotationNotDue();

        address previous = attester;
        attester = next;
        pendingAttester = address(0);
        pendingAttesterAt = 0;
        emit AttesterRotated(previous, next);
    }

    /// @dev Task 1: also returns the round id. Every guard is byte-for-byte the one that was here
    ///      before — `answer <= 0` first, then the unchanged decimals normalisation. The round id
    ///      is read, not validated: this function's callers (the constructor and px()) do not use
    ///      it, and validating it here would silently add a new revert to px().
    function _readFeed() internal view returns (uint256 px18, uint256 updatedAt, uint80 roundId) {
        (uint80 r, int256 answer,, uint256 t,) = feed.latestRoundData();
        if (answer <= 0) revert CertOracle_NonPositivePrice();
        uint8 d = feed.decimals();
        px18 = d <= 18 ? uint256(answer) * (10 ** (18 - d)) : uint256(answer) / (10 ** (d - 18));
        updatedAt = t;
        roundId = r;
    }

    /// @dev CRITICAL B: `t > block.timestamp` is checked FIRST and reverts the NAMED error.
    ///      Without it, a feed reporting an `updatedAt` in the future underflows
    ///      `block.timestamp - t` and reverts with an anonymous arithmetic panic (0x11) instead.
    ///      px() is allowed — required — to revert on a malfunctioning feed, so the fix here is
    ///      not "return something": it is to revert with the error callers can actually switch
    ///      on. A future timestamp is not "extremely fresh", it is a broken feed.
    function px() external view returns (uint256) {
        (uint256 p, uint256 t,) = _readFeed();
        if (t > block.timestamp || block.timestamp - t > stalenessSeconds) revert CertOracle_StalePrice();
        return p;
    }

    /// @notice Never reverts on guard state. The published last-good-price path for redemption.
    function pxUnguarded() external view returns (uint256, uint256) {
        (bool ok, uint256 p, uint256 t,) = _tryFeed();
        if (ok) return (p, t);
        return (lastGoodPx18, lastGoodAt);
    }

    /// @dev Never lets an external feed failure propagate: pxUnguarded(), basisBps() and
    ///      mintAllowed() all rely on this returning cleanly no matter what the feed does.
    /// @dev Task 1: also returns the round id, used only by pokeLastGood's distinctness proof.
    ///      Every failure tuple returns roundId 0 alongside the zero price and timestamp — an
    ///      `ok == false` return means "this feed observation does not exist", so no member of the
    ///      tuple carries information and callers must key off `ok`, exactly as before.
    function _tryFeed() internal view returns (bool ok, uint256 px18, uint256 updatedAt, uint80 roundId) {
        try feed.latestRoundData() returns (uint80 r, int256 answer, uint256, uint256 t, uint80) {
            if (answer <= 0) return (false, 0, 0, 0);
            // CRITICAL B (C1 final review): the `t > block.timestamp` half of this condition is
            // the fix, and it must come FIRST so it short-circuits the subtraction. Without it,
            // `block.timestamp - t` underflows on a feed reporting a future updatedAt and panics
            // (0x11) — and this is the SUCCESS block of a try, which that try's own catch does
            // not cover, so the panic propagated uncaught through _tryFeed() -> pxUnguarded() ->
            // CertVault._queueExit() and reverted forceExit(), the protocol's last-resort
            // backstop (Law 2), with the lastGoodPx18 fallback that exists for exactly this case
            // sitting unreachable two lines away. `feed` is immutable here and `oracle` is
            // immutable in CertVault, so there was no swap out of it either.
            // A future timestamp is NOT "fresher than fresh": it is a malfunctioning feed, so it
            // is unusable and returns the failure tuple like any other _tryFeed() failure.
            if (t > block.timestamp || block.timestamp - t > stalenessSeconds) return (false, 0, 0, 0);
            try feed.decimals() returns (uint8 d) {
                // Finding 2 (Task 10 review): arithmetic inside a try's success block is NOT
                // covered by that try's own catch. decimals() >= 96 makes 10 ** (d - 18) overflow
                // uint256 and panic uncaught here, propagating through pxUnguarded()/basisBps()/
                // mintAllowed() — all three are documented to never revert. Bound d before doing
                // any exponentiation: 36 is far beyond any real aggregator and safely below the
                // ~78 exponent where the power itself would overflow. Out of range -> the feed is
                // simply unusable, same as any other _tryFeed() failure.
                if (d > 36) return (false, 0, 0, 0);
                // CRITICAL B re-audit, third exposure in this same success block: with d bounded
                // the exponentiation is safe and the d > 18 branch is a division by a non-zero
                // power, but `uint256(answer) * (10 ** (18 - d))` can still overflow — answer is
                // an int256 whose positive range reaches ~5.8e76, and at d = 0 the multiplier is
                // 1e18, so any answer above ~1.15e59 panics uncaught here exactly like the
                // staleness underflow did. Check the product's headroom instead of trusting the
                // feed's magnitude; an answer that cannot be normalised is an unusable feed.
                if (d <= 18) {
                    uint256 scale = 10 ** (18 - d);
                    if (uint256(answer) > type(uint256).max / scale) return (false, 0, 0, 0);
                    px18 = uint256(answer) * scale;
                } else {
                    px18 = uint256(answer) / (10 ** (d - 18));
                }
                return (true, px18, t, r);
            } catch {
                return (false, 0, 0, 0);
            }
        } catch {
            return (false, 0, 0, 0);
        }
    }

    /// @notice |mark - index| in bps. Never reverts.
    /// @dev L-5: the return value ALONE is ambiguous and always has been — 0 means both "the mark
    ///      sits exactly on the index" (healthy) and "the basis could not be computed": the feed
    ///      is unreadable, or normalises to zero, or no mark has ever been attested. A dashboard
    ///      wired to this number renders a dead feed as a perfectly tracking one. The signature is
    ///      kept because it is declared in ICertOracle and asserted by the existing suite; use
    ///      basisBpsChecked() for anything that acts on the value, including display.
    function basisBps() external view returns (uint256) {
        (, uint256 bps) = _basis();
        return bps;
    }

    /// @notice basisBps() with the "is this number meaningful" bit attached.
    /// @return known false when the basis could not be computed at all (unreadable feed, an index
    ///         that normalises to zero, or no attested mark); the bps value is then meaningless.
    /// @return bps  the basis in bps when `known`, else 0.
    /// @dev L-5: chosen over a sentinel return and over a separate basisKnown() view. A sentinel
    ///      would change what the existing basisBps() means to every consumer already reading it,
    ///      including two assertions in the suite, and sentinels get compared with `<` sooner or
    ///      later. A companion boolean view would be two eth_calls that can straddle a block, so a
    ///      consumer could pair `known == true` with a bps computed after the feed died. This is
    ///      one call, atomic, and purely additive: nothing that reads basisBps() today has to
    ///      change. Verified call sites of basisBps(): src/interfaces/ICertOracle.sol (declaration
    ///      only — no src/ consumer calls it; CertVault never reads the basis) and
    ///      test/CertOracle.t.sol. Never reverts, for the same reason basisBps() does not.
    function basisBpsChecked() external view returns (bool known, uint256 bps) {
        return _basis();
    }

    function _basis() internal view returns (bool known, uint256 bps) {
        (bool ok, uint256 p,,) = _tryFeed();
        if (!ok || p == 0 || markPx18 == 0) return (false, 0);
        uint256 diff = markPx18 > p ? markPx18 - p : p - markPx18;
        return (true, diff * 10_000 / p);
    }

    /// @dev NOT FIXED, recorded deliberately (C1 audit, H-1 follow-on): the basis band below is
    ///      measured against `markPx18`, which is written by the trusted attester with NO
    ///      timestamp and is subject to NO staleness check anywhere in this contract. It fails
    ///      CLOSED — a mark frozen while the index moves widens the basis and returns false — so
    ///      it is not dangerous today, and that is the only reason it is not fixed here. But it
    ///      fails closed only incidentally: a mark frozen at a level that happens to track the
    ///      index keeps minting open against a number nobody has refreshed, so the guard's
    ///      liveness is unproven. That is H-1's mistake in a different field. The fix needs a
    ///      `markAt` plus its own `markStalenessSeconds` — the attester's cadence is not the
    ///      Chainlink heartbeat and must not be conflated with `stalenessSeconds` — which means a
    ///      new constructor parameter and every deployment site with it. It is neither trivial nor
    ///      isolated, so it is scoped separately. Note also that H-1's rate limit leaves this band
    ///      as the guard doing the real work for several windows during a large sustained
    ///      repricing, which raises the stakes on its liveness rather than lowering them.
    function mintAllowed() external view returns (bool) {
        (bool ok, uint256 p,,) = _tryFeed();
        if (!ok || p == 0) return false;
        if (markPx18 == 0) return false;
        uint256 diff = markPx18 > p ? markPx18 - p : p - markPx18;
        if (diff * 10_000 / p > basisBandBps) return false;
        if (lastGoodPx18 != 0) {
            uint256 dev = p > lastGoodPx18 ? p - lastGoodPx18 : lastGoodPx18 - p;
            if (dev * 10_000 / lastGoodPx18 > deviationBps) return false;
        }
        return true;
    }

    /// @notice Encode an 18-decimal price into Lighter's uint32 tick domain.
    function toTickPrice(uint256 px18) external view returns (uint32) {
        uint256 tick = px18 * (10 ** priceDecimals) / 1e18;
        if (tick == 0 || tick > type(uint32).max) revert CertOracle_TickOverflow();
        return uint32(tick);
    }

    /// @notice Refresh the last-good snapshot. Still permissionless (Law 6: no owner, no keeper,
    ///         no pause) — but the reference it writes is now RATE-LIMITED.
    ///
    /// @dev H-1 (High, C1 audit). The old body wrote `lastGoodPx18 = p` unconditionally, and its
    ///      NatSpec argued that a permissionless poke "can only ever record the feed's own healthy
    ///      value, so there is nothing to game". That is true of the VALUE and false of the GUARD.
    ///      `_tryFeed` screens for staleness, positivity and normalisability — never for
    ///      deviation — so a post-jump price is "healthy" by that definition, and the poke
    ///      laundered it into the very reference `mintAllowed()` measures deviation against.
    ///      Measured at deviationBps = 500 with a genuine 6% move: mintAllowed() == false, one
    ///      unprivileged pokeLastGood(), mintAllowed() == true, and a mint then went through — all
    ///      available atomically, in the mint's own transaction, to the party the breaker exists
    ///      to stop. A circuit breaker whose reference is resettable by its target is not a
    ///      breaker, it is a gas optimisation.
    ///
    ///      Fix: two-phase confirmation plus a per-advance clamp, so the reference can chase a
    ///      dislocation only at a bounded rate and never inside one transaction.
    ///
    ///      1. IN BAND (|p - ref| <= deviationBps): recorded immediately, exactly as before.
    ///         Nothing is being laundered — the breaker is not tripped on this price, and moving
    ///         the reference onto a price the breaker already accepts cannot flip its verdict.
    ///         Keeping this path unrestricted is deliberate: `lastGoodPx18`/`lastGoodAt` are also
    ///         pxUnguarded()'s fallback, so Law 2's snapshot must stay refreshable in normal
    ///         operation.
    ///      2. OUT OF BAND, unconfirmed: the observation is ARMED (pendingPx18/pendingSince) and
    ///         the reference is left alone. This call cannot revert — it has state to write — so
    ///         it returns having advanced nothing.
    ///      3. OUT OF BAND, armed, still within deviationBps of the armed price, AND both
    ///         confirmation conditions hold — `block.timestamp - pendingSince >
    ///         pokeConfirmationSeconds` and `roundId > pendingRoundId`: CONFIRMED. The reference
    ///         advances by AT MOST deviationBps toward the live price, and re-arms (price, block
    ///         time and round id together), so a further step costs another full window.
    ///      4. OUT OF BAND, armed and held, window not yet elapsed: reverts
    ///         CertOracle_ReferenceRateLimited. Window elapsed but the feed is still on the arming
    ///         round: reverts CertOracle_ReferenceRoundNotAdvanced. If the price instead moved out
    ///         of band relative to the armed price, it has not held, and the candidate is re-armed
    ///         from scratch — a transient spike therefore expires instead of confirming.
    ///
    ///      Why a cooldown and not the per-call clamp alone: the clamp alone does not fix this.
    ///      Nothing rate-limits how many times pokeLastGood can be called in one transaction, so a
    ///      loop of clamped pokes walks the reference to the live price atomically anyway — and
    ///      even a single clamped step clears the breaker for any move up to
    ///      2*deviationBps + deviationBps^2 (10.25% at 500 bps), which covers the measured 6%
    ///      exploit exactly. The time gate is what makes a poke sequence unrepeatable within a
    ///      block; the clamp is what bounds a large move to several windows instead of one.
    ///      Both are kept, and neither needs a key.
    ///
    ///      Why round distinctness is proven from `roundId`, and why the window is its OWN
    ///      immutable (Task 1). This function used to derive distinctness from time: with a strict
    ///      `>` against `stalenessSeconds`, the armed round satisfied `t_arm <= pendingSince` and
    ///      the confirming round had to be fresh, so
    ///      `t_conf >= block.timestamp - stalenessSeconds > pendingSince >= t_arm` and the two
    ///      observations were provably different rounds. The inference was sound but it WELDED the
    ///      breaker's rate limit to the feed-freshness bound, and the two have nothing to do with
    ///      each other. `latestRoundData()` hands us the round identity directly, and the contract
    ///      was discarding it. So the proof is now the direct one — `roundId > pendingRoundId`,
    ///      recorded at arming time — and "the price held" means the feed minted a new round
    ///      reporting that level, which is the actual claim, asserted rather than inferred.
    ///
    ///      Freeing the proof from the clock is what lets the two knobs separate, and they are
    ///      deliberately independent because they answer different questions:
    ///        * `stalenessSeconds` — "how old may a feed observation be and still be usable at
    ///          all?" It is a property of the aggregator's heartbeat. TESTNET-PLAN.md §1 sets it
    ///          to 93_600 (26 h) on mainnet, one hour past Chainlink's 24 h equity heartbeat.
    ///        * `pokeConfirmationSeconds` — "how long must a dislocation persist before the
    ///          breaker's reference concedes one clamped step to it?" It is a risk tolerance, and
    ///          the right value is on the order of an hour, not a day.
    ///      Conflating them priced every clamped step at a full heartbeat: at 93_600 seconds a 20%
    ///      repricing needed four steps and kept minting shut for roughly 4.3 days — a breaker
    ///      that outlasts the event it fired on stops being a safety control and becomes an
    ///      outage. Tightening `stalenessSeconds` to buy back that latency was the only lever, and
    ///      it is the wrong lever: it makes the oracle reject feed data it should still accept,
    ///      trading a liveness problem for a correctness one. Two independent immutables let an
    ///      operator hold the feed bound where the aggregator's cadence puts it and set the
    ///      breaker's patience separately.
    ///
    ///      Note what did NOT get weaker. Removing the timestamp inequality removed an inference,
    ///      not a check: distinctness is still required, now directly, and the rate limit is still
    ///      required, now on its own axis. A poke sequence inside one transaction still cannot
    ///      confirm anything — both arming sites below write `pendingSince = block.timestamp`, so
    ///      `block.timestamp - pendingSince` is 0 for every same-block follow-up and the strict
    ///      `>` refuses it.
    ///
    ///      That same-block refusal holds at EVERY window value, zero included (measured both
    ///      ways), so it is not what makes zero unsafe and it is NOT the reason
    ///      `pokeConfirmationSeconds == 0` is refused at construction. Zero is refused because it
    ///      leaves the `roundId` proof as the only gate, which degrades the rate limit to one
    ///      clamped step per block that carries a new feed round — see the constructor for the
    ///      measured numbers.
    ///
    ///      What the breaker now DEPENDS ON, and cannot check for itself: the feed's `roundId`
    ///      being strictly non-decreasing for the life of the deployment. A Chainlink proxy
    ///      guarantees it (the phase id occupies the high 16 bits of the uint80, so an aggregator
    ///      rotation raises `roundId` rather than resetting it); an underlying aggregator read
    ///      directly, or any feed whose numbering resets or is constant, does not, and then an
    ///      armed candidate can never be confirmed. That fails CLOSED — minting stays paused,
    ///      redemption is untouched via pxUnguarded(), and the in-band path below still refreshes
    ///      the reference when price returns within deviationBps — but it is a pre-deploy gate,
    ///      recorded as one in docs/DEPLOYMENT-CHECKLIST.md §2.
    ///
    ///      Not touched: pxUnguarded() (Law 2's never-reverts guarantee lives there and this
    ///      function is not on its path) and mintAllowed()'s own arithmetic. The breaker is
    ///      unchanged; only the mobility of its reference is.
    ///
    ///      Config caveat: at deviationBps == 0 the clamp permits no advance in either direction,
    ///      so any price change pauses minting until the operator's own tolerance is widened. That
    ///      is the honest reading of a zero-tolerance breaker and it fails closed — whereas before
    ///      this fix, deviationBps == 0 was silently defeated by any poke at all.
    function pokeLastGood() external {
        (bool ok, uint256 p, uint256 t, uint80 rid) = _tryFeed();
        // `p == 0` is part of the same failure class and was previously accepted: _tryFeed can
        // report ok == true with px18 == 0 when a high-decimals feed truncates on normalisation
        // (see test_mintAllowedFalseWhenFeedTruncatesToZero). Writing that into lastGoodPx18 would
        // have DISABLED the deviation breaker outright — mintAllowed() skips the deviation check
        // when `lastGoodPx18 == 0` — and poisoned pxUnguarded()'s fallback with a zero price.
        if (!ok || p == 0) revert CertOracle_StalePrice();

        uint256 ref = lastGoodPx18;
        if (ref == 0) {
            // No reference to protect (only reachable if construction itself normalised to zero),
            // so there is no breaker to launder past. Bootstrap it.
            lastGoodPx18 = p;
            lastGoodAt = t;
            _clearPending();
            return;
        }

        uint256 dev = (p > ref ? p - ref : ref - p) * 10_000 / ref;
        if (dev <= deviationBps) {
            lastGoodPx18 = p;
            lastGoodAt = t;
            _clearPending();
            return;
        }

        // Out of band: this is exactly the price the breaker is holding minting shut on.
        uint256 cand = pendingPx18;
        bool held =
            cand != 0 && (p > cand ? p - cand : cand - p) * 10_000 / cand <= deviationBps;
        if (!held) {
            pendingPx18 = p;
            pendingSince = block.timestamp;
            pendingRoundId = rid;
            return;
        }
        // Task 1: the RATE LIMIT is evaluated first, for two reasons. It is by far the likelier
        // failure — a poke arriving before the window has elapsed is the ordinary case, a poke
        // arriving after it against a feed that has not re-reported is the exception — so the
        // short-circuit puts the usual answer first and skips the `pendingRoundId` load entirely
        // on that path. And it keeps the diagnostic in the order an operator reads it: "not yet"
        // before "and the feed still has not spoken". The two are independent conditions, so the
        // order is a readability and gas choice only; neither can mask the other.
        if (block.timestamp - pendingSince <= pokeConfirmationSeconds) revert CertOracle_ReferenceRateLimited();
        // The distinctness proof, direct rather than inferred from timestamps. `pendingRoundId` is
        // necessarily the round that armed `cand`, because `held` above required `cand != 0` and
        // the two are only ever written together.
        if (rid <= pendingRoundId) revert CertOracle_ReferenceRoundNotAdvanced();

        // Confirmed. Advance by at most deviationBps, in the direction of the move.
        uint256 next;
        if (p > ref) {
            uint256 ceilPx = ref + ref * deviationBps / 10_000;
            next = p < ceilPx ? p : ceilPx;
        } else {
            uint256 down = ref * deviationBps / 10_000;
            uint256 floorPx = down >= ref ? 0 : ref - down;
            next = p > floorPx ? p : floorPx;
        }
        // `next` can never be zero: p >= 1 is checked above and next >= min(p, floorPx) with
        // floorPx only reaching 0 for a deviationBps >= 10_000 configuration, where next == p.
        // A zero reference would switch mintAllowed()'s deviation check off entirely.
        lastGoodPx18 = next;
        lastGoodAt = t;
        // Re-arm from THIS observation: price, block time and round id, written together so the
        // next step needs both a fresh window and a further new round.
        pendingPx18 = p;
        pendingSince = block.timestamp;
        pendingRoundId = rid;
    }

    /// @dev The single disarm path. All three pending fields are cleared together — the guard is
    ///      on `pendingSince` only as a gas short-circuit for the overwhelmingly common
    ///      nothing-armed case, and `pendingSince != 0` holds exactly when a candidate is armed
    ///      because the two arming sites in pokeLastGood write all three in one go.
    function _clearPending() internal {
        if (pendingSince != 0) {
            pendingPx18 = 0;
            pendingSince = 0;
            pendingRoundId = 0;
        }
    }
}
