// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {DeployTestnet} from "./DeployTestnet.s.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {CertVault} from "../src/CertVault.sol";

/// @notice Deploys UseCert to Robinhood Chain MAINNET (chain 4663).
///
/// @dev WHAT THIS IS, AND WHAT IT IS NOT.
///
///      It is `DeployTestnet` with the six answers that differ on mainnet, and nothing else.
///      Every phase, every ordering constraint, every post-deploy assertion is inherited
///      unchanged — deliberately. A parallel mainnet script would drift from the testnet one
///      silently, and the testnet one is the only version any test has ever exercised.
///
///      It is NOT a licence to deploy. Running this needs answers that are not in this file and
///      cannot be guessed: see `_collateralAssetIndex` and `_singleSource` below, both of which
///      revert rather than return a plausible number. `deploy/mainnet/SWITCHING.md` lists what
///      else must be true first, of which the important one is that `LighterCore` is this
///      project's MODEL of the venue's behaviour and has never met the real engine.
///
///      THE THREE THINGS THAT ARE NOT DEPLOYED HERE, and must not be:
///
///        * `TestUSDG` — the collateral is real USDG at the address below. `_deployCollateral`
///          returns it rather than constructing anything.
///        * `TestFaucet` — a faucet on mainnet is a mint of free money. `_phase1_simulators` is
///          overridden to skip it.
///        * `LighterSim` — the venue is Lighter's real `ZkLighter` proxy. The simulator exists
///          only because Lighter is absent on testnet.
///
///      Addresses and market data measured 2026-09-25 and recorded, with provenance, in
///      `deploy/mainnet/4663.plan.json`. They are literals here for the same reason every other
///      parameter in the parent is a literal: a script parsing JSON for safety-critical
///      immutables turns a mistyped key into a zero, and `absoluteCap18 = 0` deploys clean.
contract DeployMainnet is DeployTestnet {
    // ------------------------------------------------------------------------------ external
    //
    // Live on chain 4663, and all four return `0x` on testnet 46630 — which is the whole reason
    // `src/sim/LighterSim.sol` exists.

    /// @dev Global Dollar. `symbol()` returns "USDG" and `decimals()` returns 6, matching
    ///      `COLLATERAL_DECIMALS`, which `CertVault` reads ONCE at construction.
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    /// @dev Lighter's venue. The PROXY, never the implementation: implementations rotate on
    ///      upgrade and the proxy is the stable address.
    address internal constant ZK_LIGHTER = 0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d;

    uint256 internal constant MAINNET_CHAIN_ID = 4663;

    /// @dev 26 hours. The parent's 900 is a testnet reachability value and its own note says it
    ///      must not be carried over — long enough here to span a weekend close plus a holiday.
    uint256 internal constant MAINNET_STALENESS_SECONDS = 93_600;

    error DeployMainnet_AnswerRequired(string what);

    // ------------------------------------------------------------------- overridable parameters

    function _chainId() internal view override returns (uint256) {
        return MAINNET_CHAIN_ID;
    }

    function _stalenessSeconds() internal view override returns (uint256) {
        return MAINNET_STALENESS_SECONDS;
    }

    /// @dev REVERTS ON PURPOSE. The parent's 3 is LighterSim's own numbering and means nothing
    ///      to Lighter; a wrong asset index deposits margin against the wrong asset. It is not
    ///      exposed by any public endpoint checked on 2026-09-25 (`api/v1/assets` and
    ///      `api/v1/info` both 403), so it has to be read from the venue and pasted here.
    ///      A plausible default would be the most expensive kind of guess.
    function _collateralAssetIndex() internal view override returns (uint16) {
        revert DeployMainnet_AnswerRequired(
            "collateralAssetIndex: read USDG's asset index from the venue and set it here"
        );
    }

    /// @dev REVERTS ON PURPOSE. This declares the price feed and the venue mark economically
    ///      independent. On testnet it was `false` while both keepers ran on our own keys, which
    ///      made the declaration organisational rather than economic. On mainnet it is a claim
    ///      about whatever real feed is wired, and only a human who knows that feed can make it.
    function _singleSource() internal view override returns (bool) {
        revert DeployMainnet_AnswerRequired(
            "singleSource: answer honestly against the real feed being wired, then set it here"
        );
    }

    /// @dev No free collateral. The parent mints its own seed because the deployer owns
    ///      `TestUSDG`; here the float is real USDG that somebody has to send. Seeding is done
    ///      separately and deliberately, so this returns zero and `_phase5` skips it.
    function _seedCollateral() internal view override returns (uint256) {
        return vm.envUint("MAINNET_SEED_COLLATERAL");
    }

    /// @dev The real venue advances its own batches; there is no keeper role to register.
    function _requiresBatchKeeper() internal view override returns (bool) {
        return false;
    }

    // ---------------------------------------------------------------------------------- senders

    /// @dev DISTINCT ENV NAMES, and that is the point.
    ///
    ///      The parent reads `DEPLOYER_PK` / `GOV_PK` / `ATTESTER_PK`, and those are exactly the
    ///      names already exported on the operations host for the TESTNET keeper. Inheriting them
    ///      would mean a mainnet deploy run in the wrong shell picks up testnet keys and broadcasts
    ///      real transactions from them - and the first sign would be a deployment owned by an
    ///      address whose key is in a keeper env file.
    ///
    ///      `MAINNET_*` cannot collide. If they are unset, `vm.envUint` reverts and nothing is
    ///      broadcast, which is the correct outcome for a shell that was not prepared for this.
    ///
    ///      Keys live in `/etc/usecert/mainnet-deployer.env`, root-owned 0600, and are never in
    ///      this repository. See `deploy/mainnet/SWITCHING.md` for how a run loads them.
    function _senderKeys()
        internal
        view
        override
        returns (uint256 deployerPk, uint256 govPk, uint256 attesterPk)
    {
        return (
            vm.envUint("MAINNET_DEPLOYER_PK"),
            vm.envUint("MAINNET_GOV_PK"),
            vm.envUint("MAINNET_ATTESTER_PK")
        );
    }

    /// @dev The batch keeper is a LighterSim concept: the simulator needs a registered key to
    ///      settle its own batches. The real venue settles its own, so there is no such role.
    function _batchKeeperAddress() internal view override returns (address) {
        return address(0);
    }

    // ---------------------------------------------------------------------------------- seams

    /// @dev The collateral already exists. Nothing is constructed.
    function _deployCollateral() internal override returns (address) {
        return USDG;
    }

    /// @dev No simulator, no faucet, and no price feeds of our own making.
    ///
    ///      The parent's phase 1 deploys `TestUSDG`, a `TestFaucet`, a `LighterSim` sized to the
    ///      first asset's `sizeDecimals`, and one `ReplayAggregator` per mirror. The simulator
    ///      sizing is itself a testnet-only constraint: one sim cannot serve two different size
    ///      decimals, and the real venue has six distinct decimal pairs across its markets.
    ///
    ///      What replaces them here: the real collateral, the real venue, and a REAL price feed
    ///      per mirror, which this project does not deploy and must be told. `_pushAggregator`
    ///      still has to be called once per asset in order — later phases index the array by
    ///      mirror, and skipping it is how an earlier version of this override panicked with an
    ///      array out-of-bounds after `SolvencyRegistry` rather than saying what was missing.
    function _phase1_simulators() internal override {
        collateral = _deployCollateral();
        lighter = ZK_LIGHTER;
        testFaucet = address(0);
        for (uint256 i = 0; i < assets.length; ++i) {
            _pushAggregator(_feedFor(assets[i].symbol));
        }
    }

    /// @dev The real aggregator for one mirror, read from the environment.
    ///
    ///      REVERTS when unset, like the other answers this file refuses to guess. A feed is the
    ///      single input that decides what every certificate is worth; a wrong or absent one is
    ///      not a degraded deployment, it is a differently-priced asset. `_readFeed` also does not
    ///      bound `decimals()`, so the feed must report 8 — a deployment-time constraint with no
    ///      runtime check behind it.
    function _feedFor(string memory symbol) internal view returns (address) {
        string memory key = string.concat("MAINNET_FEED_", symbol);
        address feed = vm.envOr(key, address(0));
        if (feed == address(0)) {
            revert DeployMainnet_AnswerRequired(
                string.concat(key, ": set a real 8-decimal price aggregator for this mirror")
            );
        }
        return feed;
    }

    /// @dev The parent allowlists each vault on `LighterSim` before bootstrapping, then seeds
    ///      each buffer from minted collateral. Neither applies: the real venue has no
    ///      owner-gated depositor allowlist for us to call, and there is no free collateral.
    ///
    ///      Bootstrapping still has to happen, so it is done here without the two testnet steps.
    function _phase5_allowlistMarksAndBootstrap() internal override {
        uint256 seed = _seedCollateral();
        require(seed > 0, "MAINNET: seed collateral must be non-zero; bootstrap deposits from it");
        for (uint256 i = 0; i < assets.length; ++i) {
            IERC20(collateral).approve(deployed[i].vault, seed);
            CertVault(deployed[i].vault).seedBuffer(seed);
            CertVault(deployed[i].vault).bootstrap();
        }
    }

    // ------------------------------------------------------------------------------- the mirrors
    //
    // Market indices, price decimals and size decimals read from Lighter's live market list on
    // 2026-09-25 (`mainnet.zklighter.elliot.ai/api/v1/orderBookDetails`, 210 active markets).
    //
    // EVERY ONE DIFFERS FROM THE TESTNET DEPLOYMENT, including the two the address book recorded
    // as venue-verified. `marketIndex` is immutable on `CertVault`, so these are the only chance
    // to get them right — a wrong index hedges a different company, silently, because on the
    // simulator `setMarkPrice()` creates any index implicitly.
    //
    // uNVDA's decimals are 3/3 where the other three are 2/4. The testnet book carries 2/4 for it,
    // copied from its neighbours; `_quantiseToVenue` rounds size by `10 ** sizeDecimals`, so that
    // would quantise every NVDA order to the wrong lot. The catalogue in
    // `deploy/mainnet/lighter-markets.json` has six distinct decimal pairs — never copy a
    // neighbour's.
    //
    // Caps, open interest and buffer thresholds are carried over from the testnet parameters and
    // are the values most worth arguing about before a real deployment: they size how much real
    // money can be minted against each mirror.
    function _loadAssets() internal override {
        assets.push(
            AssetParams({
                name: "UseCert TSLA",
                symbol: "uTSLA",
                feedDescription: "TSLA / USD",
                marketIndex: 112,
                priceDecimals: 2,
                sizeDecimals: 4,
                seedPx18: 366.62e18,
                absoluteCap18: 90_000e18,
                openInterest18: 900_000e18,
                bufferFloor18: 100_000e18,
                bufferFeeOn18: 60_000e18,
                bufferMintSlow18: 30_000e18
            })
        );
        assets.push(
            AssetParams({
                name: "UseCert SPY",
                symbol: "uSPY",
                feedDescription: "SPY / USD",
                marketIndex: 128,
                priceDecimals: 2,
                sizeDecimals: 4,
                seedPx18: 650e18,
                absoluteCap18: 5_000_000e18,
                openInterest18: 50_000_000e18,
                bufferFloor18: 100_000e18,
                bufferFeeOn18: 60_000e18,
                bufferMintSlow18: 30_000e18
            })
        );
        assets.push(
            AssetParams({
                name: "UseCert QQQ",
                symbol: "uQQQ",
                feedDescription: "QQQ / USD",
                marketIndex: 129,
                priceDecimals: 2,
                sizeDecimals: 4,
                seedPx18: 716.31e18,
                absoluteCap18: 3_050_000e18,
                openInterest18: 30_500_000e18,
                bufferFloor18: 100_000e18,
                bufferFeeOn18: 60_000e18,
                bufferMintSlow18: 30_000e18
            })
        );
        assets.push(
            AssetParams({
                name: "UseCert NVDA",
                symbol: "uNVDA",
                feedDescription: "NVDA / USD",
                marketIndex: 110,
                // 3 and 3, NOT the 2 and 4 its neighbours use. See the note above.
                priceDecimals: 3,
                sizeDecimals: 3,
                seedPx18: 223.67e18,
                absoluteCap18: 311_000e18,
                openInterest18: 3_110_000e18,
                bufferFloor18: 100_000e18,
                bufferFeeOn18: 60_000e18,
                bufferMintSlow18: 30_000e18
            })
        );
    }
}
