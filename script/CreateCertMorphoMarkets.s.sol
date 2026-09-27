// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CertMorphoOracle} from "../src/periphery/CertMorphoOracle.sol";
import {IMorphoBlue, MarketParams, MarketParamsLib, Id} from "../src/periphery/interfaces/IMorphoBlue.sol";

interface ICertVaultBinding {
    function oracle() external view returns (address);
    function certificate() external view returns (address);
}

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @title CreateCertMorphoMarkets - A2: lending against UseCert certificates on Morpho Blue (4663)
/// @notice For each certificate in a stack-5 address book: deploy one CertMorphoOracle and create
///         the Morpho Blue market (loan USDG, collateral = the certificate, oracle = the adapter,
///         irm = AdaptiveCurveIrm, lltv = 38.5%). Market creation is permissionless; nobody needs
///         to own anything afterwards (the adapter has no owner).
///
/// @dev NOTHING IS SENT BY DEFAULT. Two locks, both needed for a transaction to leave:
///        1. `CERT_MORPHO_BROADCAST=true` - without it the script never calls vm.startBroadcast,
///           so even `forge script --broadcast` has nothing to send. The adapters are deployed and
///           the markets created in the local simulation only, which is the dry run: it proves
///           every createMarket would succeed against the live core and prints each adapter's
///           quote and each market id.
///        2. `forge script ... --broadcast` itself.
///      Live mode also refuses any chain but 4663.
///
///      env:
///        CERT_MORPHO_BOOK       path of the stack-5 book (deployments/4663.stack5.json after the
///                               vault deploy). Must carry "stack": 5 and "chainId": 4663.
///        CERT_MORPHO_BROADCAST  "true" to broadcast (default false)
///        CERT_MORPHO_ONLY       one symbol (e.g. uSPY): create exactly that market. One small real
///                               round trip before the other five.
///
///      Dry run:  CERT_MORPHO_BOOK=deployments/4663.stack5.json \
///                forge script script/CreateCertMorphoMarkets.s.sol --rpc-url $ROBINHOOD_MAINNET_RPC
///
/// @dev WHY 38.5% AND NOT 62.5%. Robinhood's own stock tokens trade as Morpho collateral at 62.5%
///      against USDG. A certificate is that token plus layers the token does not have: the vault's
///      hedge on a separate venue (reduce-only L1 orders, a geo-restricted API), a keeper and a
///      settler, stack-5 code that is not externally audited, and no secondary market - a
///      liquidator's exit is a vault redemption, which is queued (up to 4 days) whenever the feed
///      is stale, i.e. every weekend. And the oracle prices the certificate at px, blind to vault
///      solvency. Morpho's math for a position sitting exactly at LLTV:
///        LIF = min(1.15, 1 / (1 - 0.3 x (1 - LLTV)))
///        38.5%: LIF 1.15   -> bad debt only past a 55.7% collateral drop (1 - 0.385 x 1.15)
///        62.5%: LIF 1.127  -> past 29.6%
///        77%:   LIF 1.074  -> past 17.3%
///      The measured worst weekend move is 1.77% (CertMorphoOracle's notes); the 38.5% margin is
///      for what the measurement cannot see - a vault or venue failure that the price does not
///      show - and for a liquidator paid to wait out a queued redemption. Revisit 62.5% after the
///      external audit and a track record of redemptions at px.
contract CreateCertMorphoMarkets is Script {
    using MarketParamsLib for MarketParams;

    error CreateCertMorphoMarkets_WrongBook(string why);
    error CreateCertMorphoMarkets_Preflight(string symbol, string why);

    address internal constant MORPHO = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// @dev The only non-zero IRM Morpho's owner has enabled on 4663 (EnableIrm, block 286).
    address internal constant ADAPTIVE_CURVE_IRM = 0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1;
    uint256 internal constant LLTV = 0.385e18;
    uint256 internal constant CHAIN_ID = 4663;

    // Haircut schedule (see CertMorphoOracle's notes for the measurement behind each number).
    uint256 internal constant STEP1_AGE = 26 hours;
    uint256 internal constant STEP1_BPS = 300;
    uint256 internal constant STEP2_AGE = 66 hours;
    uint256 internal constant STEP2_BPS = 600;
    uint256 internal constant STEP3_AGE = 96 hours;
    uint256 internal constant STEP3_BPS = 1_500;
    uint256 internal constant CORPORATE_ACTION_BPS = 500;

    struct Row {
        string symbol;
        address vault;
        address certificate;
        address certOracle;
    }

    struct Created {
        string symbol;
        CertMorphoOracle oracle;
        MarketParams params;
        Id id;
        uint256 price;
    }

    function run() external returns (Created[] memory) {
        string memory path = vm.envString("CERT_MORPHO_BOOK");
        bool live = vm.envOr("CERT_MORPHO_BROADCAST", false);
        string memory only = vm.envOr("CERT_MORPHO_ONLY", string(""));
        return _execute(vm.readFile(path), live, only);
    }

    // ---------------------------------------------------------------- seams (overridden in tests)

    function _morpho() internal view virtual returns (address) {
        return MORPHO;
    }

    function _usdg() internal view virtual returns (address) {
        return USDG;
    }

    function _irm() internal view virtual returns (address) {
        return ADAPTIVE_CURVE_IRM;
    }

    function _lltv() internal pure virtual returns (uint256) {
        return LLTV;
    }

    // ----------------------------------------------------------------------------- the work

    function _execute(string memory json, bool live, string memory only) internal returns (Created[] memory out) {
        Row[] memory rows = _rowsFromJson(json, only);
        _preflight(rows);

        if (live) {
            if (block.chainid != CHAIN_ID) revert CreateCertMorphoMarkets_WrongBook("live mode is 4663 only");
            vm.startBroadcast();
        } else {
            console2.log("DRY RUN: CERT_MORPHO_BROADCAST is not true; nothing below is broadcast.");
        }

        out = new Created[](rows.length);
        IMorphoBlue morpho = IMorphoBlue(_morpho());
        for (uint256 i; i < rows.length; ++i) {
            CertMorphoOracle adapter =
                new CertMorphoOracle(rows[i].certOracle, rows[i].certificate, _usdg(), haircuts(rows[i].certOracle));
            MarketParams memory p = MarketParams({
                loanToken: _usdg(),
                collateralToken: rows[i].certificate,
                oracle: address(adapter),
                irm: _irm(),
                lltv: _lltv()
            });
            morpho.createMarket(p);
            out[i] = Created(rows[i].symbol, adapter, p, p.id(), adapter.price());
        }

        if (live) vm.stopBroadcast();

        for (uint256 i; i < out.length; ++i) {
            (address loan, address coll, address orc, address irm, uint256 lltv) = morpho.idToMarketParams(out[i].id);
            if (
                loan != _usdg() || coll != out[i].params.collateralToken || orc != address(out[i].oracle)
                    || irm != _irm() || lltv != _lltv()
            ) {
                revert CreateCertMorphoMarkets_Preflight(out[i].symbol, "market not recorded as created");
            }
            (uint256 px18, uint256 hBps, uint256 age, CertMorphoOracle.Source src) = out[i].oracle.quote();
            console2.log("---", out[i].symbol);
            console2.log("  adapter   ", address(out[i].oracle));
            console2.log("  collateral", out[i].params.collateralToken);
            console2.log("  market id ");
            console2.logBytes32(Id.unwrap(out[i].id));
            console2.log("  price() 1e36-scaled", out[i].price);
            console2.log("  px18 / haircut bps / stale age s / source", px18, hBps, age);
            console2.log("    source (0 fresh, 1 stale feed, 2 fallback)", uint256(src));
        }
    }

    /// @notice The deploy-time schedule. Step 1 is never earlier than the CertOracle's own
    ///         staleness bound (93,600 s = 26 h on 4663, so the two coincide).
    function haircuts(address certOracle) public view returns (CertMorphoOracle.Haircuts memory h) {
        uint256 s = _staleness(certOracle);
        h = CertMorphoOracle.Haircuts({
            step1Age: s > STEP1_AGE ? s : STEP1_AGE,
            step1Bps: STEP1_BPS,
            step2Age: STEP2_AGE,
            step2Bps: STEP2_BPS,
            step3Age: STEP3_AGE,
            step3Bps: STEP3_BPS,
            corporateActionBps: CORPORATE_ACTION_BPS
        });
    }

    function _staleness(address certOracle) internal view returns (uint256) {
        (bool ok, bytes memory r) = certOracle.staticcall(abi.encodeWithSignature("stalenessSeconds()"));
        if (!ok || r.length < 32) revert CreateCertMorphoMarkets_Preflight("?", "stalenessSeconds() unreadable");
        return abi.decode(r, (uint256));
    }

    /// @dev Every check that can fail is run before the first deploy, so a bad row stops the
    ///      script with nothing half-created.
    function _preflight(Row[] memory rows) internal view {
        IMorphoBlue morpho = IMorphoBlue(_morpho());
        if (_morpho().code.length == 0) revert CreateCertMorphoMarkets_Preflight("-", "no Morpho core at the address");
        if (!morpho.isIrmEnabled(_irm())) revert CreateCertMorphoMarkets_Preflight("-", "IRM not enabled");
        if (!morpho.isLltvEnabled(_lltv())) revert CreateCertMorphoMarkets_Preflight("-", "LLTV not enabled");
        if (IDecimals(_usdg()).decimals() != 6) {
            revert CreateCertMorphoMarkets_Preflight("-", "USDG is not 6 decimals");
        }
        for (uint256 i; i < rows.length; ++i) {
            Row memory r = rows[i];
            if (r.vault.code.length == 0 || r.certificate.code.length == 0 || r.certOracle.code.length == 0) {
                revert CreateCertMorphoMarkets_Preflight(r.symbol, "an address in the book has no code");
            }
            // The book is data; the vault is the source of truth for which oracle prices which token.
            if (ICertVaultBinding(r.vault).oracle() != r.certOracle) {
                revert CreateCertMorphoMarkets_Preflight(r.symbol, "vault.oracle() != book certOracle");
            }
            if (ICertVaultBinding(r.vault).certificate() != r.certificate) {
                revert CreateCertMorphoMarkets_Preflight(r.symbol, "vault.certificate() != book certificate");
            }
            if (IDecimals(r.certificate).decimals() != 18) {
                revert CreateCertMorphoMarkets_Preflight(r.symbol, "certificate is not 18 decimals");
            }
            // Stack 5 only: a stack-4 CertOracle has no corporateActionWindow(), and the adapter
            // would read that as a permanent corporate action.
            (bool ok, bytes memory ret) = r.certOracle.staticcall(abi.encodeWithSignature("corporateActionWindow()"));
            if (!ok || ret.length < 32) {
                revert CreateCertMorphoMarkets_Preflight(
                    r.symbol, "certOracle has no corporateActionWindow() (not stack 5)"
                );
            }
        }
    }

    /// @dev `.stack` must be 5 and `.chainId` 4663 (the stack-4 book has no `stack` key and is
    ///      refused). `only` non-empty keeps exactly that symbol.
    function _rowsFromJson(string memory json, string memory only) internal view returns (Row[] memory rows) {
        if (!vm.keyExistsJson(json, ".stack") || vm.parseJsonUint(json, ".stack") != 5) {
            revert CreateCertMorphoMarkets_WrongBook("not a stack-5 book");
        }
        if (vm.parseJsonUint(json, ".chainId") != CHAIN_ID) {
            revert CreateCertMorphoMarkets_WrongBook("chainId != 4663");
        }

        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".vaults[", vm.toString(n), "]"))) ++n;
        if (n == 0) revert CreateCertMorphoMarkets_WrongBook("no vaults");

        Row[] memory all = new Row[](n);
        uint256 kept;
        bool filter = bytes(only).length != 0;
        for (uint256 i; i < n; ++i) {
            string memory k = string.concat(".vaults[", vm.toString(i), "]");
            Row memory r = Row({
                symbol: vm.parseJsonString(json, string.concat(k, ".symbol")),
                vault: vm.parseJsonAddress(json, string.concat(k, ".vault")),
                certificate: vm.parseJsonAddress(json, string.concat(k, ".certificate")),
                certOracle: vm.parseJsonAddress(json, string.concat(k, ".certOracle"))
            });
            if (filter && keccak256(bytes(r.symbol)) != keccak256(bytes(only))) continue;
            all[kept++] = r;
        }
        if (kept == 0) revert CreateCertMorphoMarkets_WrongBook("CERT_MORPHO_ONLY matches no vault");
        rows = new Row[](kept);
        for (uint256 i; i < kept; ++i) {
            rows[i] = all[i];
        }
    }
}
