// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {IOracle} from "./interfaces/IMorphoBlue.sol";

/// @dev The CertOracle views this adapter reads. All of them exist on src/CertOracle.sol (stack 5);
///      ICertOracle declares only the vault's subset, so the adapter carries its own.
interface ICertOracleForMorpho {
    function px() external view returns (uint256);
    function pxUnguarded() external view returns (uint256 px18, uint256 updatedAt);
    function corporateActionWindow() external view returns (bool);
    function feed() external view returns (IAggregatorV3);
    function stalenessSeconds() external view returns (uint256);
}

interface IERC20DecimalsLike {
    function decimals() external view returns (uint8);
}

/// @title CertMorphoOracle
/// @notice Morpho Blue `IOracle` for ONE UseCert certificate (collateral) against USDG (loan),
///         priced from that certificate's CertOracle. One adapter per market; no owner, no
///         setters, every parameter immutable.
///
/// @dev WHY A HAIRCUT AND NOT A REVERT. Morpho Blue calls `price()` in `borrow`,
///      `withdrawCollateral` and `liquidate` (and nowhere else: `repay`, `supply` and
///      `supplyCollateral` never read the oracle). One number serves both "may this account borrow
///      more" and "may this account be liquidated", so an oracle cannot pause borrowing while
///      leaving liquidation open. Reverting when the feed is stale - which it is every weekend,
///      because CertOracle.px() refuses a round older than `stalenessSeconds` (93,600 s on 4663) -
///      would freeze liquidations for the whole closure and hand Monday's gap straight to the
///      lenders. So `price()` keeps answering when stale, from the LAST print, marked DOWN by a
///      haircut that grows with how long the print has been stale:
///        - borrowing against a stale price is worth less (the weekend free option shrinks);
///        - a position close to LLTV becomes liquidatable during the closure rather than after the
///          gap, and a liquidator is paid for carrying a certificate it cannot redeem instantly;
///        - repayment is never blocked (Morpho's repay does not read the oracle at all).
///      The only revert is "no non-zero price exists anywhere" (CertOracle's feed AND its
///      last-good fallback both empty). That cannot happen on a deployed CertOracle, whose
///      constructor seeds `lastGoodPx18`, and it is deliberate: a price of 0 would let a liquidator
///      seize all collateral for nothing, so refusing is the lesser failure.
///
/// @dev THE STALE PRICE IS THE FEED'S LAST PRINT, not `pxUnguarded()`'s fallback. Past
///      staleness pxUnguarded() returns `lastGoodPx18`, which is the MINT breaker's reference: it
///      moves only when someone pokes, and a move wider than `deviationBps` is clamped, so it can
///      lag the feed in either direction and its timestamp can be days old. The adapter reads the
///      feed's last round itself (the same normalisation CertOracle uses), so the price is
///      continuous across the fresh -> stale boundary apart from the haircut. pxUnguarded() is the
///      fallback only when the feed cannot be read at all, and then the haircut is never below
///      step 1.
///
/// @dev THE SCHEDULE, measured. Every round of the six mainnet feeds (RHTSLA, RHSPY, RHQQQ,
///      RHNVDA, RHAAPL, RHMSFT / USD, 8 decimals) from 2026-06-22 to 2026-09-25: 78 market
///      closures. The last round lands between 11:25 and 23:45 UTC on Friday (Thursday before
///      a Friday holiday); the feed restarts at 00:00 UTC on the next trading day.
///        - two-day weekends: gaps of 48.3-60.6 h; three-day weekends (3 July, Labor Day):
///          73.1-91.5 h; outside closures the longest gap is the 24 h heartbeat (quiet SPY days),
///          which is why nothing is cut before 26 h;
///        - price change across a closure: median 0.4%, largest 1.77% (QQQ, 24-27 July), so the
///          sample p99 IS its max, 1.77%. Thirteen calm weekends; the tail of a single stock
///          (TSLA, NVDA) over years is several times that, which is what step 3 and the LLTV cover.
///      Deploy defaults (script/CreateCertMorphoMarkets.s.sol), ages since the feed's last round:
///        age <= 26 h (px() fresh) .................... 0
///        26 h < age <= 66 h (any two-day weekend) ...... 3%   ~1.7x the largest measured move
///        66 h < age <= 96 h (three-day weekends only) .. 6%   66 h clears every two-day gap by 5.4 h
///        age > 96 h (longer than any closure seen) ..... 15%  not a closure: a dead feed or a halt
///      plus 5% (compounded) while CertOracle.corporateActionWindow() is true.
///      Bounds, checked here: step 1 no earlier than the CertOracle's own `stalenessSeconds` (so
///      a price px() still accepts is never cut), ages strictly increasing and at most 30 days,
///      haircuts non-decreasing, step 1 above zero, none above 50%.
///
/// @dev CORPORATE ACTIONS. CertOracle.corporateActionWindow() is true while the stock token
///      reports its oracle paused, from one hour before a staged multiplier change until an hour
///      after it AND the feed has re-published. In that window the feed and the token's
///      multiplier can disagree (a split priced per share before the token rescales), so the
///      adapter compounds `corporateActionBps` on top of any staleness haircut. A haircut guards
///      lenders against an OVER-stated price only; an under-stated one liquidates borrowers early,
///      and no oracle-side rule can guard both.
///
/// @dev SCALING. Morpho wants collateral priced in loan units, 1e36-scaled, per 1 unit of each:
///      price = px18 x 10^(36 + loanDecimals - collateralDecimals) / 1e18. For an 18-decimal
///      certificate against 6-decimal USDG that is px18 x 1e6: $371.77 -> 3.7177e26, exactly what
///      the live RH-stock/USDG oracles on 4663 answer for TSLA.
///
/// @dev WHAT THIS ORACLE DOES NOT SEE. It prices the certificate at the vault oracle's px, i.e.
///      the stock token's total-return price. It does not see the vault's own solvency (its
///      hedge, its venue margin). A certificate whose vault is short of backing still prices at
///      px here. That is a lender risk carried by the LLTV, not by this contract.
contract CertMorphoOracle is IOracle {
    error CertMorphoOracle_ZeroAddress();
    error CertMorphoOracle_DecimalsOutOfRange();
    error CertMorphoOracle_ScheduleOutOfBounds();
    /// @dev Neither the feed nor CertOracle's fallback holds a usable non-zero price.
    error CertMorphoOracle_NoPrice();

    enum Source {
        Fresh, // CertOracle.px() answered
        StaleFeed, // px() refused; the feed's last round, haircut by its age
        Fallback // the feed is unreadable; CertOracle.pxUnguarded(), haircut by its age
    }

    struct Haircuts {
        uint256 step1Age;
        uint256 step1Bps;
        uint256 step2Age;
        uint256 step2Bps;
        uint256 step3Age;
        uint256 step3Bps;
        uint256 corporateActionBps;
    }

    uint256 public constant BPS = 10_000;
    /// @notice No single haircut may exceed 50%.
    uint256 public constant MAX_HAIRCUT_BPS = 5_000;
    /// @notice No step may start later than 30 days after the last print.
    uint256 public constant MAX_STEP_AGE = 30 days;
    /// @notice Largest px18 accepted as a price ($1e18 per certificate). Anything larger is treated
    ///         as unreadable, which also keeps px18 x SCALE x BPS far inside uint256.
    uint256 public constant MAX_PX18 = 1e36;

    ICertOracleForMorpho public immutable certOracle;
    IAggregatorV3 public immutable feed;
    address public immutable collateralToken;
    address public immutable loanToken;
    /// @notice 10^(36 + loanDecimals - collateralDecimals - 18): multiplies a px18 into Morpho's scale.
    uint256 public immutable SCALE;
    /// @notice The CertOracle's staleness bound, read at construction (immutable there too).
    uint256 public immutable oracleStalenessSeconds;

    uint256 public immutable step1Age;
    uint256 public immutable step1Bps;
    uint256 public immutable step2Age;
    uint256 public immutable step2Bps;
    uint256 public immutable step3Age;
    uint256 public immutable step3Bps;
    uint256 public immutable corporateActionBps;

    constructor(address certOracle_, address collateralToken_, address loanToken_, Haircuts memory h) {
        if (certOracle_ == address(0) || collateralToken_ == address(0) || loanToken_ == address(0)) {
            revert CertMorphoOracle_ZeroAddress();
        }
        certOracle = ICertOracleForMorpho(certOracle_);
        IAggregatorV3 f = ICertOracleForMorpho(certOracle_).feed();
        if (address(f) == address(0)) revert CertMorphoOracle_ZeroAddress();
        feed = f;
        collateralToken = collateralToken_;
        loanToken = loanToken_;

        uint256 cd = IERC20DecimalsLike(collateralToken_).decimals();
        uint256 ld = IERC20DecimalsLike(loanToken_).decimals();
        // 36 + ld - cd is the decimals of Morpho's price; px18 already carries 18 of them.
        if (36 + ld < cd + 18 || 36 + ld - cd - 18 > 36) revert CertMorphoOracle_DecimalsOutOfRange();
        SCALE = 10 ** (36 + ld - cd - 18);

        uint256 s = ICertOracleForMorpho(certOracle_).stalenessSeconds();
        oracleStalenessSeconds = s;
        if (
            h.step1Age < s || h.step1Age >= h.step2Age || h.step2Age >= h.step3Age || h.step3Age > MAX_STEP_AGE
                || h.step1Bps == 0 || h.step1Bps > h.step2Bps || h.step2Bps > h.step3Bps || h.step3Bps > MAX_HAIRCUT_BPS
                || h.corporateActionBps > MAX_HAIRCUT_BPS
        ) revert CertMorphoOracle_ScheduleOutOfBounds();
        step1Age = h.step1Age;
        step1Bps = h.step1Bps;
        step2Age = h.step2Age;
        step2Bps = h.step2Bps;
        step3Age = h.step3Age;
        step3Bps = h.step3Bps;
        corporateActionBps = h.corporateActionBps;
    }

    /// @inheritdoc IOracle
    function price() external view returns (uint256) {
        (uint256 p18, uint256 hBps,,) = quote();
        return p18 * SCALE * (BPS - hBps) / BPS;
    }

    /// @notice The price before scaling, the haircut applied, the stale age (0 when fresh) and the
    ///         source. For monitoring; `price()` is exactly `px18 x SCALE x (1 - haircut)`.
    function quote() public view returns (uint256 px18, uint256 haircutBps, uint256 staleAge, Source source) {
        bool fresh;
        try certOracle.px() returns (uint256 p) {
            if (p != 0 && p <= MAX_PX18) {
                px18 = p;
                fresh = true;
            }
        } catch {}

        if (!fresh) {
            uint256 t;
            bool ok;
            (ok, px18, t) = _readFeed();
            if (ok) {
                source = Source.StaleFeed;
            } else {
                source = Source.Fallback;
                (px18, t) = _fallback();
            }
            // A timestamp in the future is a broken observation: treat it as the oldest possible.
            staleAge = t > block.timestamp ? type(uint256).max : block.timestamp - t;
            haircutBps = haircutForAge(staleAge);
            // px() refused, so the observation is not trusted as fresh whatever its age says
            // (a non-positive answer, absurd decimals): never less than step 1.
            if (haircutBps < step1Bps) haircutBps = step1Bps;
        }

        if (_inCorporateAction()) {
            // Compounded: 1 - (1 - h)(1 - c). Both are <= 50%, so the result stays below 75%.
            haircutBps = haircutBps + corporateActionBps - haircutBps * corporateActionBps / BPS;
        }
    }

    /// @notice The staleness haircut for a print `age` seconds old (0 up to and including step1Age).
    function haircutForAge(uint256 age) public view returns (uint256) {
        if (age > step3Age) return step3Bps;
        if (age > step2Age) return step2Bps;
        if (age > step1Age) return step1Bps;
        return 0;
    }

    /// @dev The feed's last round, normalised to 18 decimals exactly as CertOracle does. Never
    ///      reverts; `ok` false for a reverting feed, a non-positive answer, a zero or future
    ///      timestamp, decimals above 36, or a value that does not normalise into (0, MAX_PX18].
    function _readFeed() internal view returns (bool ok, uint256 p18, uint256 t) {
        try feed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) return (false, 0, 0);
            try feed.decimals() returns (uint8 d) {
                if (d > 36) return (false, 0, 0);
                uint256 a = uint256(answer);
                if (d <= 18) {
                    uint256 k = 10 ** (18 - d);
                    if (a > MAX_PX18 / k) return (false, 0, 0);
                    p18 = a * k;
                } else {
                    p18 = a / (10 ** (d - 18));
                }
                if (p18 == 0 || p18 > MAX_PX18) return (false, 0, 0);
                return (true, p18, updatedAt);
            } catch {
                return (false, 0, 0);
            }
        } catch {
            return (false, 0, 0);
        }
    }

    function _fallback() internal view returns (uint256 p18, uint256 t) {
        try certOracle.pxUnguarded() returns (uint256 p, uint256 at) {
            if (p == 0 || p > MAX_PX18) revert CertMorphoOracle_NoPrice();
            return (p, at);
        } catch {
            revert CertMorphoOracle_NoPrice();
        }
    }

    /// @dev A CertOracle that cannot answer counts as inside the window (the cautious reading, as
    ///      CertOracle itself treats a stock token that cannot answer as paused).
    function _inCorporateAction() internal view returns (bool) {
        try certOracle.corporateActionWindow() returns (bool w) {
            return w;
        } catch {
            return true;
        }
    }
}
