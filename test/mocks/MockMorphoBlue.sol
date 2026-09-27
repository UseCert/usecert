// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IOracle, MarketParams, MarketParamsLib, Id} from "../../src/periphery/interfaces/IMorphoBlue.sol";

/// @notice Morpho Blue's market registry plus the parts of its lending math that decide
///         solvency: the health check, the liquidation incentive, and liquidation by seized
///         collateral with bad-debt realisation. Transcribed from morpho-blue `Morpho.sol`,
///         `libraries/MathLib.sol` and `libraries/ConstantsLib.sol`, same rounding directions.
/// @dev Deliberately NOT modelled: interest (no IRM calls, a zero-rate market), shares (assets are
///      booked 1:1), token transfers, fees, callbacks, authorisation. None of them bears on whether
///      a price makes a position liquidatable or leaves bad debt, which is all these tests ask.
contract MockMorphoBlue {
    using MarketParamsLib for MarketParams;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant MAX_LIQUIDATION_INCENTIVE_FACTOR = 1.15e18;
    uint256 internal constant LIQUIDATION_CURSOR = 0.3e18;

    mapping(address => bool) public isIrmEnabled;
    mapping(uint256 => bool) public isLltvEnabled;
    mapping(Id => MarketParams) internal _params;
    mapping(Id => uint256) public createdAt;

    struct Position {
        uint256 collateral;
        uint256 borrowed;
    }

    mapping(Id => mapping(address => Position)) public position;
    mapping(Id => uint256) public badDebt;

    function enableIrm(address irm) external {
        isIrmEnabled[irm] = true;
    }

    function enableLltv(uint256 lltv) external {
        require(lltv < WAD, "max LLTV exceeded");
        isLltvEnabled[lltv] = true;
    }

    function createMarket(MarketParams memory p) external {
        Id id = p.id();
        require(isIrmEnabled[p.irm], "IRM not enabled");
        require(isLltvEnabled[p.lltv], "LLTV not enabled");
        require(createdAt[id] == 0, "market already created");
        createdAt[id] = block.timestamp;
        _params[id] = p;
    }

    function idToMarketParams(Id id) external view returns (address, address, address, address, uint256) {
        MarketParams memory p = _params[id];
        return (p.loanToken, p.collateralToken, p.oracle, p.irm, p.lltv);
    }

    function supplyCollateral(MarketParams memory p, uint256 assets, address onBehalf) external {
        Id id = _created(p);
        position[id][onBehalf].collateral += assets;
    }

    function borrow(MarketParams memory p, uint256 assets, address onBehalf) external {
        Id id = _created(p);
        position[id][onBehalf].borrowed += assets;
        require(_isHealthy(p, id, onBehalf, IOracle(p.oracle).price()), "insufficient collateral");
    }

    /// @dev Morpho's repay reads no oracle; nor does this.
    function repay(MarketParams memory p, uint256 assets, address onBehalf) external {
        Id id = _created(p);
        position[id][onBehalf].borrowed -= assets;
    }

    function withdrawCollateral(MarketParams memory p, uint256 assets, address onBehalf) external {
        Id id = _created(p);
        position[id][onBehalf].collateral -= assets;
        require(_isHealthy(p, id, onBehalf, IOracle(p.oracle).price()), "insufficient collateral");
    }

    /// @notice Morpho's `liquidate(marketParams, borrower, seizedAssets, 0, "")` path.
    function liquidate(MarketParams memory p, address borrower, uint256 seizedAssets)
        external
        returns (uint256 repaidAssets)
    {
        Id id = _created(p);
        uint256 collateralPrice = IOracle(p.oracle).price();
        require(!_isHealthy(p, id, borrower, collateralPrice), "position is healthy");

        uint256 lif = liquidationIncentiveFactor(p.lltv);
        repaidAssets = _wDivUp(_mulDivUp(seizedAssets, collateralPrice, ORACLE_PRICE_SCALE), lif);

        Position storage pos = position[id][borrower];
        require(repaidAssets <= pos.borrowed, "repaid exceeds debt");
        pos.borrowed -= repaidAssets;
        pos.collateral -= seizedAssets;
        if (pos.collateral == 0 && pos.borrowed != 0) {
            badDebt[id] += pos.borrowed;
            pos.borrowed = 0;
        }
    }

    function isHealthy(MarketParams memory p, address borrower) external view returns (bool) {
        return _isHealthy(p, p.id(), borrower, IOracle(p.oracle).price());
    }

    function liquidationIncentiveFactor(uint256 lltv) public pure returns (uint256) {
        uint256 f = _wDivDown(WAD, WAD - _wMulDown(LIQUIDATION_CURSOR, WAD - lltv));
        return f < MAX_LIQUIDATION_INCENTIVE_FACTOR ? f : MAX_LIQUIDATION_INCENTIVE_FACTOR;
    }

    /// @notice The largest borrow the health check admits for `collateral` at `collateralPrice`.
    function maxBorrow(uint256 collateral, uint256 collateralPrice, uint256 lltv) public pure returns (uint256) {
        return _wMulDown(_mulDivDown(collateral, collateralPrice, ORACLE_PRICE_SCALE), lltv);
    }

    /// @notice Collateral a liquidator must seize to repay `repaid` at `collateralPrice` (inverse
    ///         of the liquidate formula, rounded down so the repaid amount never exceeds `repaid`).
    function seizeFor(uint256 repaid, uint256 collateralPrice, uint256 lltv) external pure returns (uint256) {
        return _mulDivDown(_wMulDown(repaid, liquidationIncentiveFactor(lltv)), ORACLE_PRICE_SCALE, collateralPrice);
    }

    function _isHealthy(MarketParams memory p, Id id, address borrower, uint256 collateralPrice)
        internal
        view
        returns (bool)
    {
        Position memory pos = position[id][borrower];
        if (pos.borrowed == 0) return true;
        return maxBorrow(pos.collateral, collateralPrice, p.lltv) >= pos.borrowed;
    }

    function _created(MarketParams memory p) internal view returns (Id id) {
        id = p.id();
        require(createdAt[id] != 0, "market not created");
    }

    function _wMulDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return x * y / WAD;
    }

    function _wDivDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return x * WAD / y;
    }

    function _wDivUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return _mulDivUp(x, WAD, y);
    }

    function _mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return x * y / d;
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + (d - 1)) / d;
    }
}
