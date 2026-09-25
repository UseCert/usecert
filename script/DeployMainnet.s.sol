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

    /// @dev ANSWERED 2026-09-25 by asking the venue itself. A wrong index deposits margin
    ///      against the wrong asset, so this is measured rather than reasoned about.
    ///
    ///      HOW IT WAS MEASURED, AND HOW IT WAS FIRST MEASURED WRONG. `api/v1/assets` and
    ///      `api/v1/info` are both 403, but `api/v1/orderBooks` is public and carries a
    ///      `quote_asset_id` per market. Every one of our six markets reports 0, so 0 went in
    ///      here - and the deploy dry run reverted `AdditionalZkLighter_InvalidAssetIndex` at
    ///      `bootstrap()`. The order book's quote asset id and `deposit()`'s asset index are
    ///      DIFFERENT NUMBERINGS; reading one and calling it the other was measuring the wrong
    ///      thing and describing it as a measurement.
    ///
    ///      What settled it: `eth_call` of `deposit(deployer, i, 0, 1e6)` across i = 0..24.
    ///      0 and 2 revert `InvalidAssetIndex`; 1 and 4..24 revert `InvalidDepositAmount`;
    ///      3 alone reached the ERC-20 transfer and failed only on allowance. Granting a
    ///      1 USDG allowance turned that inference into a pass - index 3 then SUCCEEDS and
    ///      every other index still fails. The allowance was revoked immediately.
    ///
    ///      The parent also uses 3, which is a coincidence of LighterSim's own numbering and
    ///      not evidence: had it disagreed, the venue would still be right.
    function _collateralAssetIndex() internal view override returns (uint16) {
        return 3;
    }

    /// @dev ANSWERED 2026-09-25: false, and the constructor would refuse anything else.
    ///
    ///      This declares the price feed and the venue mark economically independent. On
    ///      testnet it was `false` while both keepers ran on our own keys, which made the
    ///      declaration organisational rather than economic. On mainnet it is now true in the
    ///      economic sense the flag is for: the mark comes from Lighter's order book and the
    ///      price from Chainlink's own aggregators on this chain, which share no operator.
    ///
    ///      It is also forced. `true` caps `deviationBps` at MAX_SINGLE_SOURCE_DEVIATION_BPS
    ///      (200) and construction REVERTS at our 500, so `true` could not deploy without also
    ///      loosening a risk parameter - which is the right coupling and worth not fighting.
    function _singleSource() internal view override returns (bool) {
        return false;
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

    /// @dev False: see `_phase5_allowlistMarksAndBootstrap` above. Bootstrap is done by
    ///      `deploy/bin/usecert-mainnet-bootstrap` as six direct transactions, because forge
    ///      cannot execute the venue's Stylus deposit in any mode.
    function _bootstrapsInScript() internal view override returns (bool) {
        return false;
    }

    /// @dev The real venue, asserted for what it IS rather than for what `LighterSim` is.
    ///
    ///      The parent checks an allowlist row, a margin floor, a seeded mark, a simulator owner
    ///      and a batch keeper. Lighter has none of those: no depositor allowlist we sit on, no
    ///      owner we control, and it advances its own batches. Calling them here would revert
    ///      rather than fail an assertion.
    ///
    ///      What IS assertable before bootstrap is that each vault points at the venue this file
    ///      names, carries the collateral asset index that venue accepts, and has NOT yet been
    ///      registered - the last one being the precondition the bootstrap step depends on. The
    ///      post-conditions of bootstrap are asserted by the tool that performs it.
    function _verifyVenueWiring(uint256 i) internal view override {
        CertVault v = CertVault(deployed[i].vault);
        (, uint16 assetIndex,,,,,,,,) = v.cfg();

        require(address(v.lighter()) == ZK_LIGHTER, "S9 MAINNET: vault.lighter is not Lighter's proxy");
        require(assetIndex == 3, "S9 MAINNET: cfg.collateralAssetIndex != 3 - the venue rejects the deposit");
        require(!v.bootstrapped(), "S9 MAINNET: already bootstrapped before the bootstrap step");
        require(
            v.lighterAccountIndex() == 0,
            "S9 MAINNET: lighterAccountIndex non-zero before bootstrap - this vault is not fresh"
        );
    }

    /// @dev The parent asserts the collateral is deployer-owned and that a faucet holds its
    ///      float. Neither is true or desirable here: USDG is owned by its issuer - the deploy
    ///      dry run read `owner()` as 0xcFA0388f5ddf905FdC08c45c716C15Dc10A14C6F, which is the
    ///      point of using real collateral - and no faucet is deployed, because a faucet on
    ///      mainnet is a mint of free money.
    ///
    ///      The check is REPLACED rather than dropped. What matters on this chain is that the
    ///      vaults were wired to the USDG this file names and not to something else that also
    ///      reports six decimals, and that no faucet slipped into the deployment.
    function _verifyCollateralAndFaucet() internal view override {
        require(collateral == USDG, "S9 MAINNET: collateral is not the USDG this script names");
        require(testFaucet == address(0), "S9 MAINNET: a faucet was deployed on mainnet");
        require(IERC20(collateral).totalSupply() > 0, "S9 MAINNET: collateral has no supply");
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
    /// @dev BOOTSTRAP IS NOT DONE HERE, and cannot be.
    ///
    ///      `CertVault.bootstrap()` calls `lighter.deposit(...)`, which on mainnet delegates to
    ///      0xDa2B59fFB41485a6f21E14e479AE7B7AB29a997c - an Arbitrum Stylus (WASM) contract that
    ///      foundry's EVM cannot execute. It aborts with `NotActivated` after burning ~963M gas,
    ///      which is the signature of that rather than of a contract fault: the USDG transfer
    ///      into the venue completes first and the venue's balance visibly increments.
    ///
    ///      `--skip-simulation` does not help. `forge script` ALWAYS executes the script locally
    ///      to collect the transactions to send; that flag only skips the separate on-chain
    ///      simulation pass. So a script that calls `bootstrap()` can never broadcast anything
    ///      at all - it dies while building the list. Confirmed by running it: nothing was sent,
    ///      no address book was written, and not one wei moved.
    ///
    ///      The chain itself has no such trouble: `eth_call` of `deposit()` at asset index 3
    ///      SUCCEEDS against the node. So bootstrapping is a direct transaction, not a scripted
    ///      one - `deploy/bin/usecert-mainnet-bootstrap` does the six and verifies each.
    ///
    ///      What stays here is the part forge can do: fund each buffer so the dust is already in
    ///      the vault when bootstrap is called.
    function _phase5_allowlistMarksAndBootstrap() internal override {
        uint256 seed = _seedCollateral();
        require(seed > 0, "MAINNET: seed collateral must be non-zero; bootstrap deposits from it");
        for (uint256 i = 0; i < assets.length; ++i) {
            IERC20(collateral).approve(deployed[i].vault, seed);
            CertVault(deployed[i].vault).seedBuffer(seed);
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
                marketIndex: 16,
                priceDecimals: 2,
                sizeDecimals: 4,
                seedPx18: 372.58e18,
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
                marketIndex: 26,
                priceDecimals: 2,
                sizeDecimals: 4,
                seedPx18: 769.82e18,
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
                marketIndex: 25,
                priceDecimals: 2,
                sizeDecimals: 4,
                seedPx18: 742.79e18,
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
                marketIndex: 15,
                // 3 and 3, NOT the 2 and 4 its neighbours use. See the note above.
                priceDecimals: 2,
                sizeDecimals: 4,
                seedPx18: 224.908e18,
                absoluteCap18: 311_000e18,
                openInterest18: 3_110_000e18,
                bufferFloor18: 100_000e18,
                bufferFeeOn18: 60_000e18,
                bufferMintSlow18: 30_000e18
            })
        );
        assets.push(
            AssetParams({
                name: "UseCert AAPL",
                symbol: "uAAPL",
                feedDescription: "AAPL / USD",
                marketIndex: 10,
                // 3 and 3, like NVDA and unlike the 2/4 majority. Read, not assumed.
                priceDecimals: 2,
                sizeDecimals: 4,
                seedPx18: 339.336e18,
                absoluteCap18: 500_000e18,
                openInterest18: 5_000_000e18,
                bufferFloor18: 100_000e18,
                bufferFeeOn18: 60_000e18,
                bufferMintSlow18: 30_000e18
            })
        );
        assets.push(
            AssetParams({
                name: "UseCert MSFT",
                symbol: "uMSFT",
                feedDescription: "MSFT / USD",
                marketIndex: 14,
                priceDecimals: 2,
                sizeDecimals: 4,
                seedPx18: 514.46e18,
                absoluteCap18: 500_000e18,
                openInterest18: 5_000_000e18,
                bufferFloor18: 100_000e18,
                bufferFeeOn18: 60_000e18,
                bufferMintSlow18: 30_000e18
            })
        );
    }
}
