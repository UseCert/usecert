// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice The slice of Morpho Blue this repo touches, vendored (no dependency, no submodule).
/// @dev Transcribed from morpho-org/morpho-blue `src/interfaces/IMorpho.sol` and `IOracle.sol`
///      (GPL-2.0-or-later upstream; these declarations are interface shapes only, no logic).
///      Checked against the deployed core on Robinhood Chain 4663,
///      0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010, with read-only calls on 2026-09-27:
///      `isIrmEnabled(0x2bD3...0fa1) = true`, `isLltvEnabled(38.5% / 62.5% / 77%) = true`, and a
///      live stock-token/USDG market oracle answering `price() = px x 1e24` for an 8-decimal
///      USD feed, i.e. the 1e36 scaling documented on IOracle below.

/// @dev Morpho's market id: keccak256 of the ABI-encoded MarketParams (5 static words).
type Id is bytes32;

struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @notice Morpho Blue's oracle interface.
interface IOracle {
    /// @notice The price of 1 asset of collateral token quoted in 1 asset of loan token, scaled by
    ///         1e36. Equivalently: the price of 10**(collateral decimals) collateral units quoted
    ///         in 10**(loan decimals) loan units, with 36 + loanDecimals - collateralDecimals
    ///         decimals of precision.
    function price() external view returns (uint256);
}

interface IMorphoBlue {
    function owner() external view returns (address);
    function isIrmEnabled(address irm) external view returns (bool);
    function isLltvEnabled(uint256 lltv) external view returns (bool);
    function createMarket(MarketParams memory marketParams) external;
    function idToMarketParams(Id id)
        external
        view
        returns (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv);
    function market(Id id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );
}

library MarketParamsLib {
    /// @dev Same bytes as Morpho's assembly `keccak256(marketParams, 5 * 32)`: every field is static.
    function id(MarketParams memory p) internal pure returns (Id) {
        return Id.wrap(keccak256(abi.encode(p)));
    }
}
