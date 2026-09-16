// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";

/// @notice The deployable test collateral for Robinhood Chain testnet (chain 46630), standing in
///         for USDG.
///
/// @dev THIS CONTRACT IS THE REASON A TESTNET DEPLOYMENT WAS NOT POSSIBLE. `script/DeployTestnet`
///      had to take its collateral as an already-deployed address out of band, because `src/sim/`
///      held three simulators and no token, and `test/mocks/MockERC20.sol` is a test mock a
///      deployment script cannot reach. Everything else in the deployment was proven end to end
///      against a local chain; this was the missing address.
///
///      ------------------------------------------------------------------------------------------
///      SIX DECIMALS. THIS IS THE ONE VALUE IN THE SYSTEM WITH NO RECOVERY PATH.
///
///      USDG on the real chain has 6 decimals, and `CertVault` reads
///      `IERC20Metadata(collateral).decimals()` exactly ONCE, at construction, into an immutable.
///      Deploy this token with any other number and every published figure in the system is wrong
///      by a power of ten — 10^12 at the plausible mistake of 18 — with no migration: the vault
///      would have to be redeployed, and a redeployed vault mints a NEW certificate token while
///      holders' balances sit in the old one.
///
///      So it is not a constructor parameter. `decimals()` is a `pure` override returning the
///      literal 6, which means there is no deployment of this contract that has any other value,
///      and no argument a deploy script can get wrong. The deploy script's
///      `require(decimals() == 6)` read-back therefore cannot fail — which is the point of putting
///      the constant here rather than in the script's calldata.
///
///      `test/sim/TestCollateralAndFaucet.t.sol::test_decimalsAreSixOnADeployedInstance` asserts it
///      against a deployed instance rather than by reading this comment.
///      ------------------------------------------------------------------------------------------
///
///      `src/sim/` is disposable testnet scaffolding and is the deliberate exception to Design Law
///      6 (no owner, keeper, pause or upgrade in the protocol contracts). An owner here is
///      REQUIRED, not merely allowed: a public mint on the collateral of a solvency-sensitive
///      system would mean anyone could fabricate the asset the vault's backing is denominated in,
///      and no solvency figure the testnet produced would mean anything. The owner mints; the
///      faucet holds a float and hands it out. See `TestFaucet`.
contract TestUSDG is ERC20 {
    /// @dev A mint was attempted by an address that is not the owner. A public mint on this token
    ///      would make every solvency figure the testnet produces unfalsifiable.
    error TestUSDG_NotOwner();
    /// @dev A zero owner would make the supply permanently unmintable, so the token would be
    ///      deployed and useless. Fail loudly at construction instead.
    error TestUSDG_OwnerIsZero();

    /// @notice The only address that may mint. Immutable, for the same reason `LighterSim.owner` is:
    ///         a transfer path is one more thing that can go wrong on a disposable artefact, and
    ///         redeploying test collateral costs nothing.
    address public immutable owner;

    constructor(address _owner) ERC20("UseCert Test USDG", "tUSDG") {
        if (_owner == address(0)) revert TestUSDG_OwnerIsZero();
        owner = _owner;
    }

    /// @notice Always 6. See the header: this is the value with no recovery path.
    /// @dev `pure`, not `view`, and a literal, not storage — so there is no deployment of this
    ///      contract for which it is anything else.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint test collateral. Owner only.
    /// @dev The deployment mints the deployer's seed collateral and the faucet's float with this.
    function mint(address to, uint256 amount) external {
        if (msg.sender != owner) revert TestUSDG_NotOwner();
        _mint(to, amount);
    }
}
