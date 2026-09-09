// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {LighterCore} from "./LighterCore.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice The deployable Lighter stand-in for Robinhood Chain testnet (chain 46630), where the
///         real venue is absent — `cast code` returns `0x` on both candidate `ZkLighter`
///         addresses, verified live on 2026-09-09.
///
/// @dev This is intentionally a THIN subclass. Everything it does comes from `LighterCore`, which
///      is the same behaviour implementation `test/mocks/MockLighter.sol` runs on, so the venue
///      semantics the 258-test suite certifies are the semantics that get deployed. There is one
///      behaviour implementation and two front ends; this is the testnet front end.
///
///      It deliberately adds NOTHING to `LighterCore`:
///
///      * No configuration setters. `MockLighter`'s `setMarkPrice`, `setRequiredMarginBps` and
///        `setDepositCapTicks` are ungated test conveniences that the real venue does not expose;
///        inheriting them here would put an unauthenticated knob on a deployed contract, which
///        Global Constraint 4 names as exactly how a testnet silently certifies a bad design.
///        Task 5 owns the access-controlled operator surface. Until then this contract runs on
///        `LighterCore`'s defaults, and note that `markPrice` therefore stays 0 for every market,
///        which makes `settleBatch`'s initial-margin check vacuous — see the Task 4 report.
///      * No fault injection. `shouldRevertDrain`, `shouldRevertPendingRead` and
///        `shouldRevertCreateOrder` exist to construct states for the audit PoCs and stay on
///        `MockLighter`.
///      * No `_fundPending()` override, so a withdrawal drawing on unrealised gain fails on this
///        contract's own token balance instead of minting the counterparty's collateral. That is
///        the conservative direction required by Global Constraint 5.
///      * No owner, no gating, no events yet. Tasks 5 through 8 add access control, asynchronous
///        settlement, per-account isolation and events, and this is the file they add them to.
contract LighterSim is LighterCore {
    constructor(IERC20 _collateral, uint16 _collateralAssetIndex, uint8 _sizeDecimals)
        LighterCore(_collateral, _collateralAssetIndex, _sizeDecimals)
    {}
}
