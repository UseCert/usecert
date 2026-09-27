// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice A CertOracle that can misbehave on every view CertMorphoOracle reads: the cases the
///         real CertOracle never produces (it documents pxUnguarded and corporateActionWindow as
///         never reverting), so the adapter's own fallbacks are exercised in isolation.
contract MockCertOracleForMorpho {
    IAggregatorV3 public feed;
    uint256 public stalenessSeconds;

    uint256 public pxValue;
    bool public pxReverts;
    uint256 public unguardedPx;
    uint256 public unguardedAt;
    bool public unguardedReverts;
    bool public window;
    bool public windowReverts;

    constructor(address feed_, uint256 staleness_) {
        feed = IAggregatorV3(feed_);
        stalenessSeconds = staleness_;
    }

    function setPx(uint256 p, bool reverts) external {
        pxValue = p;
        pxReverts = reverts;
    }

    function setUnguarded(uint256 p, uint256 at, bool reverts) external {
        unguardedPx = p;
        unguardedAt = at;
        unguardedReverts = reverts;
    }

    function setWindow(bool w, bool reverts) external {
        window = w;
        windowReverts = reverts;
    }

    function px() external view returns (uint256) {
        require(!pxReverts, "stale");
        return pxValue;
    }

    function pxUnguarded() external view returns (uint256, uint256) {
        require(!unguardedReverts, "broken");
        return (unguardedPx, unguardedAt);
    }

    function corporateActionWindow() external view returns (bool) {
        require(!windowReverts, "broken");
        return window;
    }
}
