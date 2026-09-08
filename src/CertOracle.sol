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
    uint256 public lastGoodPx18;
    uint256 public lastGoodAt;

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

        (uint256 p,) = _readFeed();
        lastGoodPx18 = p;
        lastGoodAt = block.timestamp;
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

    function px() external view returns (uint256) {
        (uint256 p, uint256 t) = _readFeed();
        if (block.timestamp - t > stalenessSeconds) revert CertOracle_StalePrice();
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
            if (block.timestamp - t > stalenessSeconds) return (false, 0, 0);
            try feed.decimals() returns (uint8 d) {
                // Finding 2 (Task 10 review): arithmetic inside a try's success block is NOT
                // covered by that try's own catch. decimals() >= 96 makes 10 ** (d - 18) overflow
                // uint256 and panic uncaught here, propagating through pxUnguarded()/basisBps()/
                // mintAllowed() — all three are documented to never revert. Bound d before doing
                // any exponentiation: 36 is far beyond any real aggregator and safely below the
                // ~78 exponent where the power itself would overflow. Out of range -> the feed is
                // simply unusable, same as any other _tryFeed() failure.
                if (d > 36) return (false, 0, 0);
                px18 = d <= 18 ? uint256(answer) * (10 ** (18 - d)) : uint256(answer) / (10 ** (d - 18));
                return (true, px18, t);
            } catch {
                return (false, 0, 0);
            }
        } catch {
            return (false, 0, 0);
        }
    }

    function basisBps() external view returns (uint256) {
        (bool ok, uint256 p,) = _tryFeed();
        if (!ok || p == 0 || markPx18 == 0) return 0;
        uint256 diff = markPx18 > p ? markPx18 - p : p - markPx18;
        return diff * 10_000 / p;
    }

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

    /// @notice Refresh the last-good snapshot. Permissionless: it can only ever record the
    ///         feed's own healthy value, so there is nothing to game.
    function pokeLastGood() external {
        (bool ok, uint256 p, uint256 t) = _tryFeed();
        if (!ok) revert CertOracle_StalePrice();
        lastGoodPx18 = p;
        lastGoodAt = t;
    }
}
