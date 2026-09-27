// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreateCertMorphoMarkets} from "../../script/CreateCertMorphoMarkets.s.sol";
import {CertOracle} from "../../src/CertOracle.sol";
import {CertMorphoOracle} from "../../src/periphery/CertMorphoOracle.sol";
import {MarketParams, MarketParamsLib, Id} from "../../src/periphery/interfaces/IMorphoBlue.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockUIMultiplierToken} from "../mocks/MockUIMultiplierToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMorphoBlue} from "../mocks/MockMorphoBlue.sol";

contract MockVaultBinding {
    address public oracle;
    address public certificate;

    constructor(address o, address c) {
        oracle = o;
        certificate = c;
    }
}

/// @dev The script with its three chain addresses pointed at mocks. Everything else - the book
///      parsing, the preflight, the schedule, the deploy-and-create loop - is the script's own code.
contract CreateCertMorphoMarketsHarness is CreateCertMorphoMarkets {
    address internal immutable m;
    address internal immutable u;
    address internal immutable i;

    constructor(address morpho_, address usdg_, address irm_) {
        m = morpho_;
        u = usdg_;
        i = irm_;
    }

    function _morpho() internal view override returns (address) {
        return m;
    }

    function _usdg() internal view override returns (address) {
        return u;
    }

    function _irm() internal view override returns (address) {
        return i;
    }

    function execute(string memory json, bool live, string memory only) external returns (Created[] memory) {
        return _execute(json, live, only);
    }

    function rows(string memory json, string memory only) external view returns (Row[] memory) {
        return _rowsFromJson(json, only);
    }
}

contract CreateCertMorphoMarketsTest is Test {
    uint256 internal constant T0 = 1_790_362_944;
    address internal constant IRM = 0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1;

    MockMorphoBlue internal morpho;
    MockERC20 internal usdg;
    CreateCertMorphoMarketsHarness internal script;

    string[6] internal symbols = ["uTSLA", "uSPY", "uQQQ", "uNVDA", "uAAPL", "uMSFT"];
    int256[6] internal px8 =
        [int256(371_77000000), 769_82000000, 742_79000000, 224_90800000, 339_33600000, 514_46000000];
    address[6] internal vaults;
    address[6] internal certs;
    address[6] internal oracles;

    function setUp() public {
        vm.warp(T0);
        morpho = new MockMorphoBlue();
        morpho.enableIrm(IRM);
        morpho.enableLltv(0.385e18);
        morpho.enableLltv(0.625e18);
        morpho.enableLltv(0.77e18);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        script = new CreateCertMorphoMarketsHarness(address(morpho), address(usdg), IRM);
        for (uint256 k; k < 6; ++k) {
            MockAggregatorV3 f = new MockAggregatorV3(8, px8[k]);
            MockUIMultiplierToken t = new MockUIMultiplierToken(1e18);
            oracles[k] = address(
                new CertOracle(address(f), makeAddr("attester"), 2, 93_600, 500, 100, 3600, false, 300, address(t))
            );
            certs[k] = address(new MockERC20(symbols[k], symbols[k], 18));
            vaults[k] = address(new MockVaultBinding(oracles[k], certs[k]));
        }
    }

    function _book(uint256 chainId, bool withStack) internal view returns (string memory j) {
        j = string.concat('{"chainId": ', vm.toString(chainId), withStack ? ', "stack": 5' : "", ', "vaults": [');
        for (uint256 k; k < 6; ++k) {
            j = string.concat(
                j,
                k == 0 ? "" : ", ",
                '{"symbol": "',
                symbols[k],
                '", "vault": "',
                vm.toString(vaults[k]),
                '", "certificate": "',
                vm.toString(certs[k])
            );
            j = string.concat(j, '", "certOracle": "', vm.toString(oracles[k]), '", "marketIndex": 16}');
        }
        j = string.concat(j, "]}");
    }

    function test_dry_run_creates_six_markets() public {
        CreateCertMorphoMarkets.Created[] memory c = script.execute(_book(4663, true), false, "");
        assertEq(c.length, 6);
        for (uint256 k; k < 6; ++k) {
            assertEq(c[k].symbol, symbols[k]);
            MarketParams memory p = c[k].params;
            assertEq(p.loanToken, address(usdg));
            assertEq(p.collateralToken, certs[k]);
            assertEq(p.oracle, address(c[k].oracle));
            assertEq(p.irm, IRM);
            assertEq(p.lltv, 0.385e18);
            assertEq(Id.unwrap(c[k].id), keccak256(abi.encode(p)));
            assertGt(morpho.createdAt(c[k].id), 0, "created");
            (address loan, address coll, address orc, address irm, uint256 lltv) = morpho.idToMarketParams(c[k].id);
            assertEq(loan, address(usdg));
            assertEq(coll, certs[k]);
            assertEq(orc, address(c[k].oracle));
            assertEq(irm, IRM);
            assertEq(lltv, 0.385e18);

            CertMorphoOracle a = c[k].oracle;
            assertEq(address(a.certOracle()), oracles[k]);
            assertEq(a.collateralToken(), certs[k]);
            assertEq(a.loanToken(), address(usdg));
            assertEq(c[k].price, uint256(px8[k]) * 1e10 * 1e6, "px18 x 1e6");
            assertEq(a.step1Age(), 26 hours);
            assertEq(a.step1Bps(), 300);
            assertEq(a.step2Age(), 66 hours);
            assertEq(a.step2Bps(), 600);
            assertEq(a.step3Age(), 96 hours);
            assertEq(a.step3Bps(), 1_500);
            assertEq(a.corporateActionBps(), 500);
        }
    }

    function test_only_creates_exactly_one() public {
        CreateCertMorphoMarkets.Created[] memory c = script.execute(_book(4663, true), false, "uSPY");
        assertEq(c.length, 1);
        assertEq(c[0].symbol, "uSPY");
        assertEq(c[0].params.collateralToken, certs[1]);
    }

    function test_only_unknown_symbol_refused() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CreateCertMorphoMarkets.CreateCertMorphoMarkets_WrongBook.selector, "CERT_MORPHO_ONLY matches no vault"
            )
        );
        script.rows(_book(4663, true), "uXYZ");
    }

    function test_book_without_stack5_marker_refused() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CreateCertMorphoMarkets.CreateCertMorphoMarkets_WrongBook.selector, "not a stack-5 book"
            )
        );
        script.rows(_book(4663, false), "");
    }

    function test_live_stack4_book_refused() public {
        // The committed stack-4 book, same vault layout, no "stack" key.
        string memory json = vm.readFile("deployments/4663.json");
        vm.expectRevert(
            abi.encodeWithSelector(
                CreateCertMorphoMarkets.CreateCertMorphoMarkets_WrongBook.selector, "not a stack-5 book"
            )
        );
        script.rows(json, "");
    }

    function test_wrong_chain_book_refused() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CreateCertMorphoMarkets.CreateCertMorphoMarkets_WrongBook.selector, "chainId != 4663"
            )
        );
        script.rows(_book(46630, true), "");
    }

    function test_vault_binding_mismatch_refused_before_any_deploy() public {
        (oracles[2], oracles[3]) = (oracles[3], oracles[2]); // the book swaps two oracles
        vm.expectRevert(
            abi.encodeWithSelector(
                CreateCertMorphoMarkets.CreateCertMorphoMarkets_Preflight.selector,
                "uQQQ",
                "vault.oracle() != book certOracle"
            )
        );
        script.execute(_book(4663, true), false, "");
    }

    function test_certificate_mismatch_refused() public {
        certs[5] = certs[4];
        vm.expectRevert(
            abi.encodeWithSelector(
                CreateCertMorphoMarkets.CreateCertMorphoMarkets_Preflight.selector,
                "uMSFT",
                "vault.certificate() != book certificate"
            )
        );
        script.execute(_book(4663, true), false, "");
    }

    function test_irm_and_lltv_must_be_enabled() public {
        MockMorphoBlue bare = new MockMorphoBlue();
        CreateCertMorphoMarketsHarness s = new CreateCertMorphoMarketsHarness(address(bare), address(usdg), IRM);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreateCertMorphoMarkets.CreateCertMorphoMarkets_Preflight.selector, "-", "IRM not enabled"
            )
        );
        s.execute(_book(4663, true), false, "");
        bare.enableIrm(IRM);
        bare.enableLltv(0.625e18); // not the one the script uses
        vm.expectRevert(
            abi.encodeWithSelector(
                CreateCertMorphoMarkets.CreateCertMorphoMarkets_Preflight.selector, "-", "LLTV not enabled"
            )
        );
        s.execute(_book(4663, true), false, "");
    }

    function test_live_mode_refuses_other_chains() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CreateCertMorphoMarkets.CreateCertMorphoMarkets_WrongBook.selector, "live mode is 4663 only"
            )
        );
        script.execute(_book(4663, true), true, "");
    }

    function test_live_mode_on_4663_broadcasts_the_same_plan() public {
        vm.chainId(4663);
        CreateCertMorphoMarkets.Created[] memory c = script.execute(_book(4663, true), true, "uNVDA");
        assertEq(c.length, 1);
        assertGt(morpho.createdAt(c[0].id), 0);
        assertEq(c[0].params.collateralToken, certs[3]);
    }

    function test_rerun_creates_a_second_market_so_run_once() public {
        script.execute(_book(4663, true), false, "uTSLA");
        // A second run deploys a NEW adapter, so it is a new market id, not a duplicate: the
        // operator must not run twice. Morpho itself refuses only identical params.
        CreateCertMorphoMarkets.Created[] memory c = script.execute(_book(4663, true), false, "uTSLA");
        assertGt(morpho.createdAt(c[0].id), 0);
    }
}
