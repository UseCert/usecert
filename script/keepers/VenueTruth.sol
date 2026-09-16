// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {IERC20Metadata} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {LighterSim} from "../../src/sim/LighterSim.sol";

/// @title  What the venue simulator actually holds for one vault, read straight out of it.
///
/// @notice THE HONESTY BOUNDARY OF THIS WHOLE TASK, SO IT IS STATED HERE AND AGAIN IN THE RUNBOOK.
///
///         On MAINNET, `SolvencyRegistry.attest(asset, batchId, notional18, margin18,
///         openInterest18)` is meant to be fed by reconstructing Lighter's account tree from posted
///         blob data. Those figures are *independently verifiable but not verified on-chain*: the
///         registry takes the attester's word for them, and the only bounds that survive a
///         compromised attester are `CapacityOracle.maxAbsoluteCap` and `maxAttestationAgeSec`.
///
///         On TESTNET the venue is `LighterSim`, which WE DEPLOY AND OWN. So this library does not
///         reconstruct anything — it reads the true position out of the simulator's own storage.
///         That is the right call for a testnet (there is no blob data to reconstruct, and inventing
///         a reconstruction step would only add a way to be wrong), and it makes the attester
///         trivial.
///
///         IT ALSO MAKES TESTNET SOLVENCY STRICTLY STRONGER THAN MAINNET'S, and that is a
///         convenience which must never be read as a production claim. Nothing about a green
///         testnet attestation is evidence that the mainnet attester — a single key relaying
///         unverified figures — is sound. `docs/TESTNET-RUNBOOK.md` records this at the top of the
///         Attester section for exactly that reason.
///
/// @dev    TASK 7 MADE THE SIMULATOR'S BOOKS PER-ACCOUNT, so every read here is per-account. The
///         aggregate views (`marginBalance()`, `positionBase(m)`, `entryPrice(m)`,
///         `unrealisedPnl()`) are venue-level sums across every registered account and are
///         explicitly documented in `LighterCore` as deciding nothing. Attesting a vault's backing
///         from an aggregate would be wrong the moment a second vault shares the simulator — which
///         is the deployed configuration: `script/DeployTestnet.s.sol` puts uTSLA and uSPY on ONE
///         `LighterSim`, so `positionBase(16)` and `marginBalance()` already answer a different
///         question than "what backs this vault". The functions used, and why each:
///
///           - `addressToAccountIndex(vault)`  the vault's own account index; 0 means unregistered.
///           - `positionBaseOf(acct, market)`  THAT ACCOUNT's signed position, in base ticks.
///           - `marginBalanceOf(acct)`         THAT ACCOUNT's posted cash margin, in token units.
///           - `equity(acct)`                  THAT ACCOUNT's cash margin plus its own mark-to-market
///                                             PnL, floored at zero. Task 7 deliberately removed the
///                                             no-argument overload.
///           - `markPrice(market)`             the venue mark. Genuinely venue-wide (one mark per
///                                             market, not per account), so the aggregate read is
///                                             the correct read here and only here.
///           - `sizeDecimals()` / `collateral()` the scaling inputs, taken from the chain rather
///                                             than from the address book, so a stale book cannot
///                                             silently rescale a published figure.
library VenueTruth {
    /// @dev The vault holds no account on the simulator, so there is no per-account book to read.
    ///      DELIBERATELY A REVERT AND NOT A ZERO. Zero notional and zero margin would in fact be
    ///      the truth for an unregistered account — but it is also exactly what a WRONG VAULT
    ///      ADDRESS in the address book produces, and that failure would then be a silent stream of
    ///      honest-looking zero attestations against the wrong asset key. Refusing loudly costs
    ///      nothing: an unregistered vault cannot mint anyway (`createOrder` reverts
    ///      `AccountIsNotRegistered`), so there is no liveness to protect here.
    error VenueTruth_VaultNotRegistered(address vault);

    /// @dev The venue has no mark for this market. `LighterSim.settleBatch` already refuses to
    ///      settle in this state, and for the same reason: at a zero mark the mark-to-market layer
    ///      is dead — notional is `|position| * 0`, so the margin gate passes vacuously at any
    ///      size, and `entryPrice = 0` makes `unrealisedPnl()` permanently zero. Attesting a zero
    ///      notional out of that state would publish "nothing is hedged" for a live position.
    error VenueTruth_MarkPriceUnset(uint16 marketIndex);

    /// @notice The vault's own account index on the simulator. Reverts rather than returning 0.
    function accountIndexOf(LighterSim sim, address vault) internal view returns (uint48 acct) {
        acct = sim.addressToAccountIndex(vault);
        if (acct == 0) revert VenueTruth_VaultNotRegistered(vault);
    }

    /// @notice The venue mark for one market, scaled to 1e18. This is what the attester writes to
    ///         `CertOracle.setMarkPrice`, and it is the one figure in this library that is
    ///         legitimately venue-wide rather than per-account.
    function markPx18(LighterSim sim, uint16 marketIndex) internal view returns (uint256 px18) {
        px18 = sim.markPrice(marketIndex);
        if (px18 == 0) revert VenueTruth_MarkPriceUnset(marketIndex);
    }

    /// @notice The dollar value of THIS VAULT's hedge at the venue's own mark, scaled to 1e18.
    ///
    /// @dev `positionBaseOf` is in base ticks with `sizeDecimals` applied, so `|pos| / 10**sd` is
    ///      the position in whole units and `* markPx18` makes it an 18-decimal notional. Same
    ///      shape as `CertVault._value18(qty18, px18)` on the obligation side, which is what makes
    ///      `solvency().deltaBps` (`notional18 * 10_000 / required`) comparable at all.
    ///
    ///      `Math.mulDiv` rather than `*` then `/`: `|pos| * px18` at a large position and an
    ///      absurd mark is the same unbounded product the external audit's Finding 1 was about.
    ///      This is a script and a revert here is merely a keeper cycle lost, but a keeper that
    ///      panics is a keeper an operator has to debug, so it is made total instead.
    function notional18(LighterSim sim, address vault, uint16 marketIndex) internal view returns (uint256) {
        uint48 acct = accountIndexOf(sim, vault);
        uint256 px18 = markPx18(sim, marketIndex);

        int256 pos = sim.positionBaseOf(acct, marketIndex);
        if (pos == 0) return 0;
        // Absolute value: a short hedge is negative and its NOTIONAL is still positive. The
        // negation is written on the int256 before the cast so `type(int256).min` cannot be laundered
        // into a positive number by a bare `uint256(-pos)` on an unchecked path.
        uint256 abs = pos > 0 ? uint256(pos) : uint256(-pos);

        return Math.mulDiv(abs, px18, 10 ** sim.sizeDecimals());
    }

    /// @notice The margin backing THIS VAULT's hedge, scaled to 1e18.
    ///
    /// @dev THE CONSERVATIVE OF THE TWO PER-ACCOUNT FIGURES, on purpose (Global Constraint 5: every
    ///      deviation from real venue behaviour must fail in the conservative direction).
    ///
    ///        - `marginBalanceOf(acct)` is the cash the account has posted. It ignores the
    ///          position's mark-to-market, so on a losing hedge it OVERSTATES what the venue would
    ///          actually credit.
    ///        - `equity(acct)` is that cash plus the account's own unrealised PnL, floored at zero
    ///          — what the account can genuinely draw on. On a winning hedge it exceeds the posted
    ///          cash.
    ///
    ///      `min` of the two therefore takes the loss and declines the gain: an unrealised drawdown
    ///      lowers the published backing immediately, while an unrealised gain — which is not
    ///      collateral until it is realised, and which `LighterSim` deliberately does NOT fund
    ///      (there is no `_fundPending()` override, so a withdrawal against unrealised gain fails
    ///      on the simulator's real token balance) — does not raise it.
    ///
    ///      `margin18` is a PUBLISHED figure only: it reaches `CertVault.solvency().margin18` and
    ///      nothing else reads it, so this choice cannot gate a mint or a redemption. It is an
    ///      honesty choice, not a safety mechanism, and is documented as such rather than left for
    ///      a reader to infer from `min`.
    function margin18(LighterSim sim, address vault) internal view returns (uint256) {
        uint48 acct = accountIndexOf(sim, vault);

        uint256 cash = sim.marginBalanceOf(acct);
        uint256 drawable = sim.equity(acct);
        uint256 conservative = drawable < cash ? drawable : cash;

        return _to18(sim, conservative);
    }

    /// @dev Collateral decimals read from the token itself, not from the address book and not
    ///      hardcoded at 6. `CertVault` fixes the collateral's decimals immutably at construction;
    ///      a keeper that assumed 6 against an 18-decimal token would publish every backing figure
    ///      off by 10**12 while looking completely healthy.
    function _to18(LighterSim sim, uint256 amount) private view returns (uint256) {
        uint8 d = IERC20Metadata(address(sim.collateral())).decimals();
        return d <= 18 ? amount * (10 ** (18 - d)) : amount / (10 ** (d - 18));
    }
}
