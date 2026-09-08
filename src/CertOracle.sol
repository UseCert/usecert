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
    ///      but has not yet held for a full staleness window, so the reference may not advance
    ///      onto it yet. Poke again once the window has elapsed.
    error CertOracle_ReferenceRateLimited();

    IAggregatorV3 public immutable feed;
    address public immutable attester;
    /// @dev market price_decimals; 2 for TSLA and NVDA
    uint8 public immutable priceDecimals;
    uint256 public immutable stalenessSeconds;
    /// @dev max |chainlink - lastGood| in bps before minting pauses
    uint256 public immutable deviationBps;
    /// @dev max |mark - chainlink| in bps before minting pauses
    uint256 public immutable basisBandBps;

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

    constructor(
        address _feed,
        address _attester,
        uint8 _priceDecimals,
        uint256 _stalenessSeconds,
        uint256 _deviationBps,
        uint256 _basisBandBps
    ) {
        feed = IAggregatorV3(_feed);
        attester = _attester;
        priceDecimals = _priceDecimals;
        stalenessSeconds = _stalenessSeconds;
        deviationBps = _deviationBps;
        basisBandBps = _basisBandBps;

        // L-4: the constructor checked positivity but not staleness, so a vault could be deployed
        // against an already-dead feed and start life with a reference price nobody had quoted for
        // days. Same guard shape as px(), future-timestamp half FIRST so it short-circuits the
        // subtraction (CRITICAL B) — and the same named error, not an arithmetic panic.
        (uint256 p, uint256 t) = _readFeed();
        if (t > block.timestamp || block.timestamp - t > _stalenessSeconds) revert CertOracle_StalePrice();
        lastGoodPx18 = p;
        // L-4: the feed round timestamp, matching pokeLastGood and pxUnguarded's live branch.
        lastGoodAt = t;
    }

    function setMarkPrice(uint256 px18) external {
        if (msg.sender != attester) revert CertOracle_OnlyAttester();
        markPx18 = px18;
    }

    function _readFeed() internal view returns (uint256 px18, uint256 updatedAt) {
        (, int256 answer,, uint256 t,) = feed.latestRoundData();
        if (answer <= 0) revert CertOracle_NonPositivePrice();
        uint8 d = feed.decimals();
        px18 = d <= 18 ? uint256(answer) * (10 ** (18 - d)) : uint256(answer) / (10 ** (d - 18));
        updatedAt = t;
    }

    /// @dev CRITICAL B: `t > block.timestamp` is checked FIRST and reverts the NAMED error.
    ///      Without it, a feed reporting an `updatedAt` in the future underflows
    ///      `block.timestamp - t` and reverts with an anonymous arithmetic panic (0x11) instead.
    ///      px() is allowed — required — to revert on a malfunctioning feed, so the fix here is
    ///      not "return something": it is to revert with the error callers can actually switch
    ///      on. A future timestamp is not "extremely fresh", it is a broken feed.
    function px() external view returns (uint256) {
        (uint256 p, uint256 t) = _readFeed();
        if (t > block.timestamp || block.timestamp - t > stalenessSeconds) revert CertOracle_StalePrice();
        return p;
    }

    /// @notice Never reverts on guard state. The published last-good-price path for redemption.
    function pxUnguarded() external view returns (uint256, uint256) {
        (bool ok, uint256 p, uint256 t) = _tryFeed();
        if (ok) return (p, t);
        return (lastGoodPx18, lastGoodAt);
    }

    /// @dev Never lets an external feed failure propagate: pxUnguarded(), basisBps() and
    ///      mintAllowed() all rely on this returning cleanly no matter what the feed does.
    function _tryFeed() internal view returns (bool ok, uint256 px18, uint256 updatedAt) {
        try feed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 t, uint80) {
            if (answer <= 0) return (false, 0, 0);
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
            if (t > block.timestamp || block.timestamp - t > stalenessSeconds) return (false, 0, 0);
            try feed.decimals() returns (uint8 d) {
                // Finding 2 (Task 10 review): arithmetic inside a try's success block is NOT
                // covered by that try's own catch. decimals() >= 96 makes 10 ** (d - 18) overflow
                // uint256 and panic uncaught here, propagating through pxUnguarded()/basisBps()/
                // mintAllowed() — all three are documented to never revert. Bound d before doing
                // any exponentiation: 36 is far beyond any real aggregator and safely below the
                // ~78 exponent where the power itself would overflow. Out of range -> the feed is
                // simply unusable, same as any other _tryFeed() failure.
                if (d > 36) return (false, 0, 0);
                // CRITICAL B re-audit, third exposure in this same success block: with d bounded
                // the exponentiation is safe and the d > 18 branch is a division by a non-zero
                // power, but `uint256(answer) * (10 ** (18 - d))` can still overflow — answer is
                // an int256 whose positive range reaches ~5.8e76, and at d = 0 the multiplier is
                // 1e18, so any answer above ~1.15e59 panics uncaught here exactly like the
                // staleness underflow did. Check the product's headroom instead of trusting the
                // feed's magnitude; an answer that cannot be normalised is an unusable feed.
                if (d <= 18) {
                    uint256 scale = 10 ** (18 - d);
                    if (uint256(answer) > type(uint256).max / scale) return (false, 0, 0);
                    px18 = uint256(answer) * scale;
                } else {
                    px18 = uint256(answer) / (10 ** (d - 18));
                }
                return (true, px18, t);
            } catch {
                return (false, 0, 0);
            }
        } catch {
            return (false, 0, 0);
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
        (bool ok, uint256 p,) = _tryFeed();
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
        (bool ok, uint256 p,) = _tryFeed();
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
    ///      3. OUT OF BAND, armed, still within deviationBps of the armed price, and
    ///         `block.timestamp - pendingSince > stalenessSeconds`: CONFIRMED. The reference
    ///         advances by AT MOST deviationBps toward the live price, and re-arms, so a further
    ///         step costs another full window.
    ///      4. OUT OF BAND, armed and held, window not yet elapsed: reverts
    ///         CertOracle_ReferenceRateLimited. If the price instead moved out of band relative to
    ///         the armed price, it has not held, and the candidate is re-armed from scratch — a
    ///         transient spike therefore expires instead of confirming.
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
    ///      Why the window is `stalenessSeconds` (no new constructor parameter — the signature is
    ///      load-bearing for every deployer and fixture): with a STRICT `>` comparison the
    ///      confirming observation is provably a different, fresher feed round than the arming
    ///      one. The armed round satisfied `t_arm <= pendingSince`; the confirming round must be
    ///      fresh, so `t_conf >= block.timestamp - stalenessSeconds > pendingSince >= t_arm`.
    ///      "The price held" therefore means the feed independently re-reported it, not that one
    ///      round was read twice. Operators who want minting to reopen faster after a real
    ///      repricing tighten stalenessSeconds, which is the same knob that governs how fresh the
    ///      feed must be to be usable at all.
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
        (bool ok, uint256 p, uint256 t) = _tryFeed();
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
            return;
        }
        if (block.timestamp - pendingSince <= stalenessSeconds) revert CertOracle_ReferenceRateLimited();

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
        pendingPx18 = p;
        pendingSince = block.timestamp;
    }

    function _clearPending() internal {
        if (pendingSince != 0) {
            pendingPx18 = 0;
            pendingSince = 0;
        }
    }
}
