// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeBatches} from "../../script/SafeBatches.s.sol";
import {DeployTestnet} from "../../script/DeployTestnet.s.sol";
import {CertVault} from "../../src/CertVault.sol";
import {Certificate} from "../../src/Certificate.sol";
import {CertOracle} from "../../src/CertOracle.sol";
import {CertFactory} from "../../src/CertFactory.sol";
import {SolvencyRegistry} from "../../src/SolvencyRegistry.sol";
import {CapacityOracle} from "../../src/CapacityOracle.sol";
import {InsuranceStaking} from "../../src/InsuranceStaking.sol";
import {CertStaking} from "../../src/CertStaking.sol";
import {FeeVault} from "../../src/FeeVault.sol";
import {BuybackForwarder} from "../../src/BuybackForwarder.sol";
import {LighterSim} from "../../src/sim/LighterSim.sol";
import {ReplayAggregator} from "../../src/sim/ReplayAggregator.sol";
import {TestUSDG} from "../../src/sim/TestUSDG.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice The mainnet stack-5 scripts (DeployMainnet + SafeBatches) with every environment read
///         answered by subclassing, never by `vm.setEnv` (process-global, shared by forge's parallel
///         test threads; see CommitGuard.t.sol). Keys are anvil's well-known dev keys.
contract S5Harness is SafeBatches {
    uint256 internal constant H_DEPLOYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant H_ATTESTER_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;

    bytes internal constant H_PUBKEY =
        hex"012258abd09aa219c49c168c88d3fdb0c4f1004757709ae2400824c2ed19534cb4e3e038864c6076";

    string internal tag;
    address internal hSafe;
    address internal hSettler;
    address internal hRegistry;
    address[] internal hOracles;
    mapping(bytes32 => address) internal hFeed;
    string internal hOnly;
    string internal hOpen;
    uint256 internal hOpenCap;
    uint256 internal hSeed = 1_000e6;
    string internal hCommit = "91f7f2df0654c1535411cd583dde84b573b46a37";

    constructor(string memory tag_, address safe_, address settler_) {
        tag = tag_;
        hSafe = safe_;
        hSettler = settler_;
    }

    function setAdopted(address registry_, address[] memory oracles_) external {
        hRegistry = registry_;
        hOracles = oracles_;
    }

    function setFeed(string memory sym, address feed) external {
        hFeed[keccak256(bytes(sym))] = feed;
    }

    function setOnly(string memory sym) external {
        hOnly = sym;
    }

    function setOpen(string memory list, uint256 cap) external {
        hOpen = list;
        hOpenCap = cap;
    }

    function setCommit(string memory c) external {
        hCommit = c;
    }

    function _senderKeys() internal pure override returns (uint256, uint256, uint256) {
        return (H_DEPLOYER_PK, 0, H_ATTESTER_PK);
    }

    /// One harness serves both the deploy and the batches; production SafeBatches refuses run().
    function _allowDeployFromBatches() internal pure override returns (bool) {
        return true;
    }

    function _externalGovernance() internal view override returns (address) {
        return hSafe;
    }

    function _externalRegistry() internal view override returns (address) {
        return hRegistry;
    }

    function _externalOracle(uint256 i) internal view override returns (address) {
        return hOracles[i];
    }

    function _feedFor(string memory symbol) internal view override returns (address f) {
        f = hFeed[keccak256(bytes(symbol))];
        require(f != address(0), "harness: no feed");
    }

    function _seedCollateral() internal view override returns (uint256) {
        return hSeed;
    }

    function _settlerAddr() internal view override returns (address) {
        return hSettler;
    }

    function _opsWalletAddr() internal view override returns (address) {
        return deployerAddr;
    }

    function _treasuryAddr() internal view override returns (address) {
        return govAddr;
    }

    function _commitEnv() internal view override returns (string memory) {
        return hCommit;
    }

    function _onlyAsset() internal view override returns (string memory) {
        return hOnly;
    }

    function _bookPath() internal view override returns (string memory) {
        return string.concat("deployments/test-s5-", tag, ".book.json");
    }

    function _outPath(string memory name) internal view override returns (string memory) {
        return string.concat("deployments/test-s5-", tag, ".", name, ".json");
    }

    function _stack4BookPath() internal view override returns (string memory) {
        return string.concat("deployments/test-s5-", tag, ".stack4.json");
    }

    function _batch1Attester() internal pure override returns (address) {
        return vm.addr(H_ATTESTER_PK);
    }

    function _apiKeyIndex() internal pure override returns (uint8) {
        return 3;
    }

    function _pubKeyOf(string memory) internal pure override returns (bytes memory) {
        return H_PUBKEY;
    }

    /// 0.0150 base at 4 size decimals, and $10 minimum notional: the shape of the venue's rows.
    function _minBaseOf(string memory) internal pure override returns (uint256) {
        return 150;
    }

    function _minQuoteOf(string memory) internal pure override returns (uint256) {
        return 10e18;
    }

    function _openVaults() internal view override returns (string memory) {
        return hOpen;
    }

    function _openCap18() internal view override returns (uint256) {
        return hOpenCap;
    }

    function maxAbsoluteCapOf(string memory sym) external pure returns (uint256) {
        return _maxAbsoluteCapOf(sym);
    }
}

/// @notice The production seams, reading the real environment variable names. Only the commit
///         (COMMIT is written by other suites in parallel) and the output paths (no test may write
///         a real-looking 4663 book) are answered here.
contract S5EnvHarness is SafeBatches {
    function _allowDeployFromBatches() internal pure override returns (bool) {
        return true;
    }

    function _commitEnv() internal pure override returns (string memory) {
        return "91f7f2df0654c1535411cd583dde84b573b46a37";
    }

    function _bookPath() internal pure override returns (string memory) {
        return "deployments/test-s5-env.book.json";
    }

    function _outPath(string memory name) internal pure override returns (string memory) {
        return string.concat("deployments/test-s5-env.", name, ".json");
    }
}

/// @notice Stack 5 on "mainnet" (chain id 4663, in process): the Safe creates the registry and
///         oracles (batch 1), the deployer deploys the rest, the vaults are bootstrapped, the Safe
///         executes phase A, two days pass, it executes phase B, then opens ONE vault, a keeper-mode
///         mint round-trips through the settler on a fresh signed v2 mark, and only then are the
///         other five opened.
/// @dev The real USDG, venue proxy and CERT addresses are given simulator code with `deployCodeTo`,
///      so the script runs UNCHANGED against the constants it will use on mainnet. The Safe is an
///      address with code whose calls are made with `vm.prank`: every Safe transaction executed
///      here is read back out of the Transaction Builder file the script wrote, and the
///      MultiSendCallOnly payload is decoded and checked against it call by call.
contract DeployMainnetStack5Test is Test {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant ZK_LIGHTER = 0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d;
    address internal constant CERT = 0xb01356A005403C38c0fb01bd0aAfe51e81Ab9B07;
    address internal constant MULTISEND_141 = 0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526;
    address internal constant CREATECALL_141 = 0x9b35Af71d77eaf8d7e40252370304687390A1A52;

    uint256 internal constant DEPLOYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant ATTESTER_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant SETTLER_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

    string[6] internal SYMS = ["uTSLA", "uSPY", "uQQQ", "uNVDA", "uAAPL", "uMSFT"];
    uint256[6] internal PX = [372.58e18, 769.82e18, 742.79e18, 224.908e18, 339.336e18, 514.46e18];
    uint256[6] internal CAPS = [90_000e18, 5_000_000e18, 3_050_000e18, 311_000e18, 500_000e18, 500_000e18];
    /// @dev Option A: the Robinhood stock tokens (script/DeployMainnet.s.sol), etched with
    ///      MockUIMultiplierToken. SPY carries its real 2026-09-27 multiplier, TSLA exactly 1.
    address[6] internal TOKENS = [
        0x322F0929c4625eD5bAd873c95208D54E1c003b2d,
        0x117cc2133c37B721F49dE2A7a74833232B3B4C0C,
        0xD5f3879160bc7c32ebb4dC785F8a4F505888de68,
        0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC,
        0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9,
        0xe93237C50D904957Cf27E7B1133b510C669c2e74
    ];
    uint256[6] internal MULTS = [uint256(1e18), 1.001717991187472003e18, 1.0015e18, 1.0002e18, 1.0011e18, 1.0019e18];

    address internal safe = makeAddr("safe2of3");
    address internal deployer = vm.addr(DEPLOYER_PK);
    address internal attester = vm.addr(ATTESTER_PK);
    address internal settler = vm.addr(SETTLER_PK);
    address internal alice = makeAddr("alice");

    ReplayAggregator[] internal feeds;
    string internal tag;
    uint256 internal nAssets;

    // What the deploy produced, kept in storage (legacy codegen stack; via_ir stays off).
    address internal fv;
    address internal fwd;
    address internal ins;
    address internal cs;
    address internal registry;
    address internal capacity;
    address internal factory;

    function _record(S5Harness d) internal {
        address stl;
        (fv, fwd, ins, cs, stl) = d.stack5Addresses();
        assertEq(stl, settler, "settler recorded");
        (,,, registry, capacity, factory) = d.sharedAddresses();
    }

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.chainId(4663);
        vm.etch(safe, hex"00");
        vm.etch(MULTISEND_141, hex"00");
        vm.etch(CREATECALL_141, hex"00");

        deployCodeTo("TestUSDG.sol:TestUSDG", abi.encode(address(this)), USDG);
        deployCodeTo(
            "LighterSim.sol:LighterSim", abi.encode(USDG, uint16(3), uint8(4), uint256(5_000), address(this)), ZK_LIGHTER
        );
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("CERT", "CERT", uint8(18)), CERT);

        for (uint256 i = 0; i < 6; ++i) {
            feeds.push(new ReplayAggregator(address(this), 8, SYMS[i], int256(PX[i] / 1e10)));
            deployCodeTo("MockUIMultiplierToken.sol:MockUIMultiplierToken", abi.encode(MULTS[i]), TOKENS[i]);
        }
        vm.deal(deployer, 100 ether);
        vm.deal(attester, 100 ether);
    }

    // ================================================================================ helpers

    function _h() internal returns (S5Harness h) {
        h = new S5Harness(tag, safe, settler);
        for (uint256 i = 0; i < 6; ++i) {
            h.setFeed(SYMS[i], address(feeds[i]));
        }
    }

    function _path(string memory name) internal view returns (string memory) {
        return string.concat("deployments/test-s5-", tag, ".", name, ".json");
    }

    function _book() internal view returns (string memory) {
        return vm.readFile(string.concat("deployments/test-s5-", tag, ".book.json"));
    }

    function _sidecar(string memory p) internal pure returns (string memory) {
        bytes memory b = bytes(p);
        bytes memory stem = new bytes(b.length - 5); // drop ".json"
        for (uint256 i = 0; i < stem.length; ++i) {
            stem[i] = b[i];
        }
        return string.concat(string(stem), ".multisend.json");
    }

    function _rm(string memory p) internal {
        if (vm.exists(p)) vm.removeFile(p);
        string memory side = _sidecar(p);
        if (vm.exists(side)) vm.removeFile(side);
    }

    function _cleanup() internal {
        _rm(string.concat("deployments/test-s5-", tag, ".book.json"));
        _rm(string.concat("deployments/test-s5-", tag, ".stack4.json"));
        _rm(_path("phaseA"));
        _rm(_path("phaseA-proposals"));
        _rm(_path("phaseB"));
        _rm(_path("open-uTSLA"));
        _rm(_path("open-uSPY-uQQQ-uNVDA-uAAPL-uMSFT"));
        _rm(_path("open-all"));
        _rm(_path("retire-stack4"));
    }

    function _createAs(address who, bytes memory init) internal returns (address a) {
        vm.prank(who);
        assembly {
            a := create(0, add(init, 0x20), mload(init))
        }
        require(a != address(0), "create failed");
    }

    /// Batch 1 as the Safe would execute it (the exact init codes the script builds), then the
    /// deploy, then the out-of-script bootstrap. Returns the deploy harness.
    function _deploy(string memory only) internal returns (S5Harness d) {
        S5Harness b1 = _h();
        if (bytes(only).length != 0) b1.setOnly(only);
        b1.batch1(); // the batch the Safe signs: builds, checks libraries, broadcasts nothing
        bytes[] memory inits = b1.batch1InitCodes(attester);
        nAssets = inits.length - 1;
        address reg = _createAs(safe, inits[0]);
        address[] memory oracles = new address[](nAssets);
        for (uint256 i = 0; i < nAssets; ++i) {
            oracles[i] = _createAs(safe, inits[i + 1]);
            assertEq(CertOracle(oracles[i]).governance(), safe, "batch 1: oracle governance is not the Safe");
            assertEq(CertOracle(oracles[i]).maxMarkAge(), 300, "batch 1: oracle maxMarkAge");
            assertTrue(CertOracle(oracles[i]).stockToken() != address(0), "batch 1: oracle has no stock token");
        }
        assertEq(SolvencyRegistry(reg).governance(), safe, "batch 1: registry governance is not the Safe");

        d = _h();
        if (bytes(only).length != 0) d.setOnly(only);
        d.setAdopted(reg, oracles);
        TestUSDG(USDG).mint(deployer, 1_000e6 * nAssets);
        d.run();

        // usecert-mainnet-bootstrap's job on mainnet (a direct transaction, not forge). Here the
        // simulator needs its allowlist row and a venue mark first.
        for (uint256 i = 0; i < nAssets; ++i) {
            DeployTestnet.AssetDeployment memory dep = d.deploymentOf(i);
            LighterSim(ZK_LIGHTER).setDepositorAllowed(dep.vault, true);
            LighterSim(ZK_LIGHTER).setMarkPrice(d.paramsOf(i).marketIndex, PX[i]);
            CertVault(dep.vault).bootstrap();
        }
        LighterSim(ZK_LIGHTER).settleBatch();
    }

    /// Executes every transaction of a Transaction Builder file as the Safe, after checking the
    /// MultiSendCallOnly sidecar encodes exactly the same calls in the same order.
    function _execAsSafe(string memory name) internal returns (uint256 n) {
        string memory p = _path(name);
        string memory j = vm.readFile(p);
        assertEq(vm.parseJsonString(j, ".chainId"), "4663", "tx builder chainId");
        assertEq(vm.parseJsonAddress(j, ".meta.createdFromSafeAddress"), safe, "tx builder Safe");

        string memory side = vm.readFile(_sidecar(p));
        assertEq(vm.parseJsonAddress(side, ".to"), 0x9641d764fc13c8B624c04430C7356C1C7C8102e2, "sidecar: MultiSendCallOnly");
        assertEq(vm.parseJsonUint(side, ".operation"), 1, "sidecar: delegatecall");
        bytes memory ms = vm.parseJsonBytes(side, ".data");
        (address[] memory mTo, bytes[] memory mData) = _decodeMultiSend(ms);

        while (vm.keyExistsJson(j, string.concat(".transactions[", vm.toString(n), "]"))) {
            string memory k = string.concat(".transactions[", vm.toString(n), "]");
            address to = vm.parseJsonAddress(j, string.concat(k, ".to"));
            bytes memory data = vm.parseJsonBytes(j, string.concat(k, ".data"));
            assertEq(vm.parseJsonString(j, string.concat(k, ".value")), "0", "tx builder value");
            assertEq(mTo[n], to, "multisend target differs from the tx builder file");
            assertEq(keccak256(mData[n]), keccak256(data), "multisend calldata differs from the tx builder file");
            vm.prank(safe);
            (bool ok, bytes memory ret) = to.call(data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
            ++n;
        }
        assertEq(n, mTo.length, "multisend and tx builder file have different call counts");
    }

    function _decodeMultiSend(bytes memory call) internal pure returns (address[] memory to, bytes[] memory data) {
        require(bytes4(call) == bytes4(keccak256("multiSend(bytes)")), "not multiSend");
        bytes memory args = new bytes(call.length - 4);
        for (uint256 i = 0; i < args.length; ++i) {
            args[i] = call[i + 4];
        }
        bytes memory packed = abi.decode(args, (bytes));
        uint256 count;
        for (uint256 off = 0; off < packed.length;) {
            uint256 len = _word(packed, off + 53);
            off += 85 + len;
            ++count;
        }
        to = new address[](count);
        data = new bytes[](count);
        uint256 o;
        for (uint256 c = 0; c < count; ++c) {
            require(uint8(packed[o]) == 0, "multisend entry is not a CALL");
            to[c] = address(uint160(_word(packed, o + 1) >> 96));
            require(_word(packed, o + 21) == 0, "multisend entry carries value");
            uint256 len = _word(packed, o + 53);
            bytes memory d = new bytes(len);
            for (uint256 i = 0; i < len; ++i) {
                d[i] = packed[o + 85 + i];
            }
            data[c] = d;
            o += 85 + len;
        }
    }

    function _word(bytes memory b, uint256 off) internal pure returns (uint256 w) {
        assembly {
            w := mload(add(add(b, 32), off))
        }
    }

    function _sign(CertOracle o, uint256 pk, uint256 px18, uint64 nonce, uint64 observedAt, uint64 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(o.SET_MARK_TYPEHASH(), px18, nonce, observedAt, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", o.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _refreshFeeds() internal {
        for (uint256 i = 0; i < 6; ++i) {
            feeds[i].push(int256(PX[i] / 1e10));
        }
    }

    // ============================================================================ the full run

    /// @notice Deploy -> phase A -> +2 days -> phase B -> open ONE vault -> keeper-mode round trip
    ///         through the settler -> open the other five. Every stack-5 wiring item asserted.
    function test_stack5_fullFlow_deploy_phaseA_phaseB_openOne_roundTrip_openRest() public {
        tag = "full";
        S5Harness d = _deploy("");
        assertEq(nAssets, 6, "six vaults");
        _record(d);
        _assertStandalone(d);
        _assertBook(d);

        // ---------------------------------------------------------------- phase A (day 0)
        uint256 t0 = block.timestamp;
        _h().phaseA();
        uint256 nA = _execAsSafe("phaseA");
        assertEq(nA, 6 * 8, "phase A: eight calls per vault");
        _assertProposalsRecorded(t0);

        for (uint256 i = 0; i < 6; ++i) {
            CertVault v = CertVault(d.deploymentOf(i).vault);
            assertEq(v.feeSink(), fv, "feeSink");
            assertEq(v.insurancePool(), ins, "insurancePool");
            assertTrue(v.keeperHedging(), "keeper hedging");
            assertEq(CertFactory(factory).registeredAt(address(v)), t0, "registeredAt: the 16-day clock starts at phase A");
            assertTrue(CertFactory(factory).isVault(address(v)), "registered");
            assertEq(v.settler(), address(0), "settler must wait the delay");
            assertEq(CapacityOracle(capacity).absoluteCap18(address(v)), 0, "phase A must open no minting");
        }

        // ---------------------------------------------------------------- phase B (day 2)
        vm.warp(t0 + 2 days + 1);
        _refreshFeeds();
        _h().phaseB();
        assertEq(_execAsSafe("phaseB"), 6 * 3, "phase B: three applies per vault");
        for (uint256 i = 0; i < 6; ++i) {
            CertVault v = CertVault(d.deploymentOf(i).vault);
            assertEq(v.settler(), settler, "settler applied");
            assertEq(v.venueMinBase(), 150, "venue minBase applied");
            assertEq(v.venueMinNotional18(), 10e18, "venue minNotional applied");
            assertEq(
                LighterSim(ZK_LIGHTER).apiKeyOf(v.lighterAccountIndex(), 3),
                hex"012258abd09aa219c49c168c88d3fdb0c4f1004757709ae2400824c2ed19534cb4e3e038864c6076",
                "venue API key applied"
            );
        }

        // ------------------------------------------------ open ONE vault, prove it, open the rest
        S5Harness o1 = _h();
        o1.setOpen("uTSLA", 0);
        o1.openMinting();
        assertEq(_execAsSafe("open-uTSLA"), 1, "one cap");
        assertEq(CapacityOracle(capacity).absoluteCap18(d.deploymentOf(0).vault), CAPS[0], "uTSLA open at its row");
        for (uint256 i = 1; i < 6; ++i) {
            assertEq(CapacityOracle(capacity).absoluteCap18(d.deploymentOf(i).vault), 0, "only one vault open");
        }

        _roundTrip(d, 0);

        S5Harness o2 = _h();
        o2.setOpen("uSPY,uQQQ,uNVDA,uAAPL,uMSFT", 0);
        o2.openMinting();
        assertEq(_execAsSafe("open-uSPY-uQQQ-uNVDA-uAAPL-uMSFT"), 5, "five caps");
        for (uint256 i = 0; i < 6; ++i) {
            assertEq(CapacityOracle(capacity).absoluteCap18(d.deploymentOf(i).vault), CAPS[i], "per-asset cap = table");
            assertEq(d.maxAbsoluteCapOf(SYMS[i]), CAPS[i], "reviewed row");
        }

        // A stack-5 vault holding certificates cannot be retired by the wind-down builder.
        _writeStack4ShapedBook(d);
        S5Harness r = _h();
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeBatches.SafeBatches_NotReady.selector,
                "uTSLA",
                "not empty - holders, receipts, claims or a position remain"
            )
        );
        r.retireStack4();

        _cleanup();
    }

    function _assertStandalone(S5Harness d) internal view {
        (address collateral,,,,,) = d.sharedAddresses();
        assertEq(collateral, USDG, "collateral is USDG");

        FeeVault f = FeeVault(fv);
        assertEq(f.recipientCount(), 4, "four recipients");
        address[4] memory who = [ins, fwd, deployer, safe];
        uint256[4] memory bps = [uint256(7_000), 2_000, 500, 500];
        for (uint256 k = 0; k < 4; ++k) {
            (address r, uint256 b) = f.recipientAt(k);
            assertEq(r, who[k], "fee recipient");
            assertEq(b, bps[k], "fee bps");
        }
        assertEq(address(f.asset()), USDG, "feeVault asset");

        assertEq(address(BuybackForwarder(fwd).staking()), cs, "forwarder bound to the NEW CertStaking");
        assertEq(address(BuybackForwarder(fwd).usdg()), USDG, "forwarder usdg");

        InsuranceStaking p = InsuranceStaking(ins);
        assertEq(p.cooldown(), 10 days, "cooldown");
        assertEq(p.withdrawWindow(), 6 days, "withdrawWindow");
        assertEq(p.drawDelay(), 2 days, "drawDelay");
        assertEq(p.maxDrawBps(), 3_000, "maxDrawBps");
        assertEq(p.depositCap(), 10_000e6, "depositCap");
        assertEq(p.registrationDelay(), 16 days, "registrationDelay");
        assertEq(address(p.registry()), factory, "insurance registry = CertFactory");
        assertEq(p.governance(), safe, "insurance governance = Safe");
        assertEq(p.asset(), USDG, "insurance asset");

        CertStaking c = CertStaking(cs);
        assertEq(address(c.stakingToken()), CERT, "stakes CERT");
        assertEq(address(c.rewardToken()), USDG, "pays USDG");
        assertEq(c.rewardsDuration(), 7 days, "duration");
        assertEq(c.stakeCap(), 10_000_000e18, "stake cap");
        assertEq(c.minNotify(), 1e6, "minNotify");

        // M-8: the ceiling is a real number (the largest reviewed row), not 1e27.
        assertEq(CapacityOracle(capacity).maxAbsoluteCap(), 5_000_000e18, "maxAbsoluteCap = largest row");
        for (uint256 i = 0; i < 6; ++i) {
            assertEq(CertOracle(d.deploymentOf(i).oracle).stalenessSeconds(), 93_600, "real staleness");
            // Option A: each oracle reads its own asset's Robinhood token, live.
            assertEq(CertOracle(d.deploymentOf(i).oracle).stockToken(), TOKENS[i], "oracle stock token = table");
            assertEq(d.paramsOf(i).stockToken, TOKENS[i], "asset table stock token");
            assertEq(CertOracle(d.deploymentOf(i).oracle).multiplier18(), MULTS[i], "oracle multiplier = token's");
            assertEq(d.paramsOf(i).absoluteCap18, CAPS[i], "stack-4 per-asset cap carried over");
        }
    }

    function _assertBook(S5Harness d) internal view {
        _assertBookShared();
        _assertBookParameters();
        _assertBookVaults(d);
    }

    function _assertBookShared() internal view {
        string memory b = _book();
        assertEq(vm.parseJsonUint(b, ".stack"), 5, "book stack marker");
        assertEq(vm.parseJsonString(b, "._generatedBy"), "script/DeployMainnet.s.sol (stack 5)", "book generatedBy");
        assertEq(vm.parseJsonUint(b, ".chainId"), 4663, "book chainId");
        assertEq(vm.parseJsonString(b, ".commit"), "91f7f2df0654c1535411cd583dde84b573b46a37", "book commit");
        assertEq(vm.parseJsonAddress(b, ".senders.governance"), safe, "book governance");
        // Fields the front end and health checks already read.
        assertEq(vm.parseJsonAddress(b, ".shared.collateral"), USDG, "book collateral");
        assertEq(vm.parseJsonAddress(b, ".shared.lighter"), ZK_LIGHTER, "book lighter");
        assertEq(vm.parseJsonAddress(b, ".shared.solvencyRegistry"), registry, "book registry");
        assertEq(vm.parseJsonAddress(b, ".shared.capacityOracle"), capacity, "book capacity");
        assertEq(vm.parseJsonAddress(b, ".shared.certFactory"), factory, "book factory");
        // The new ones.
        assertEq(vm.parseJsonAddress(b, ".shared.feeVault"), fv, "book feeVault");
        assertEq(vm.parseJsonAddress(b, ".shared.buybackForwarder"), fwd, "book forwarder");
        assertEq(vm.parseJsonAddress(b, ".shared.insuranceStaking"), ins, "book insurance");
        assertEq(vm.parseJsonAddress(b, ".shared.certStaking"), cs, "book certStaking");
        assertEq(vm.parseJsonAddress(b, ".shared.settler"), settler, "book settler");
        assertEq(vm.parseJsonAddress(b, ".shared.cert"), CERT, "book cert");
        assertEq(vm.parseJsonAddress(b, ".shared.opsWallet"), deployer, "book ops wallet");
        assertEq(vm.parseJsonAddress(b, ".shared.treasury"), safe, "book treasury");
    }

    function _assertBookParameters() internal view {
        string memory b = _book();
        // Parameters, including the REAL staleness.
        assertEq(vm.parseJsonUint(b, ".parameters.stalenessSeconds"), 93_600, "book stalenessSeconds");
        assertEq(vm.parseJsonUint(b, ".parameters.maxMarkAge"), 300, "book maxMarkAge");
        assertEq(vm.parseJsonUint(b, ".parameters.governanceDelay"), 2 days, "book governanceDelay");
        assertEq(vm.parseJsonString(b, ".parameters.maxAbsoluteCap18"), "5000000000000000000000000", "book ceiling");
        assertEq(vm.parseJsonUint(b, ".parameters.insuranceStaking.cooldown"), 10 days, "book cooldown");
        assertEq(vm.parseJsonUint(b, ".parameters.insuranceStaking.withdrawWindow"), 6 days, "book window");
        assertEq(vm.parseJsonUint(b, ".parameters.insuranceStaking.drawDelay"), 2 days, "book drawDelay");
        assertEq(vm.parseJsonUint(b, ".parameters.insuranceStaking.maxDrawBps"), 3_000, "book maxDrawBps");
        assertEq(vm.parseJsonString(b, ".parameters.insuranceStaking.depositCap"), "10000000000", "book depositCap");
        assertEq(vm.parseJsonUint(b, ".parameters.insuranceStaking.registrationDelay"), 16 days, "book regDelay");
        assertEq(vm.parseJsonUint(b, ".parameters.certStaking.rewardsDuration"), 7 days, "book duration");
        assertEq(vm.parseJsonString(b, ".parameters.certStaking.minNotify"), "1000000", "book minNotify");
        uint256[] memory bps = vm.parseJsonUintArray(b, ".parameters.feeSplit.bps");
        address[] memory rec = vm.parseJsonAddressArray(b, ".parameters.feeSplit.recipients");
        assertEq(bps.length, 4, "book split length");
        assertEq(rec[0], ins, "book split 0");
        assertEq(rec[1], fwd, "book split 1");
        assertEq(bps[0] + bps[1] + bps[2] + bps[3], 10_000, "book split sums to 10000");
    }

    function _assertBookVaults(S5Harness d) internal view {
        string memory b = _book();

        for (uint256 i = 0; i < 6; ++i) {
            DeployTestnet.AssetDeployment memory dep = d.deploymentOf(i);
            string memory k = string.concat(".vaults[", vm.toString(i), "]");
            assertEq(vm.parseJsonString(b, string.concat(k, ".symbol")), SYMS[i], "book symbol");
            assertEq(vm.parseJsonAddress(b, string.concat(k, ".vault")), dep.vault, "book vault");
            assertEq(vm.parseJsonAddress(b, string.concat(k, ".certificate")), dep.certificate, "book certificate");
            assertEq(vm.parseJsonAddress(b, string.concat(k, ".certOracle")), dep.oracle, "book oracle");
            assertEq(vm.parseJsonAddress(b, string.concat(k, ".bufferBook")), dep.bufferBook, "book bufferBook");
            assertEq(vm.parseJsonAddress(b, string.concat(k, ".replayAggregator")), address(feeds[i]), "book feed");
            assertEq(
                vm.parseJsonString(b, string.concat(k, ".maxAbsoluteCap18")), vm.toString(CAPS[i]), "book per-asset row"
            );
            assertEq(
                vm.parseJsonUint(b, string.concat(k, ".marketIndex")), d.paramsOf(i).marketIndex, "book marketIndex"
            );
        }
    }

    function _assertProposalsRecorded(uint256 t0) internal view {
        string memory r = vm.readFile(_path("phaseA-proposals"));
        assertEq(vm.parseJsonUint(r, ".count"), 18, "18 proposals");
        for (uint256 k = 0; k < 18; ++k) {
            string memory key = string.concat(".proposals[", vm.toString(k), "]");
            bytes memory data = vm.parseJsonBytes(r, string.concat(key, ".data"));
            bytes32 id = vm.parseJsonBytes32(r, string.concat(key, ".id"));
            address vault = vm.parseJsonAddress(r, string.concat(key, ".vault"));
            assertEq(keccak256(data), id, "recorded id is keccak256(calldata)");
            assertEq(CertVault(vault).changeReadyAt(id), t0 + 2 days, "proposal on chain with the 2-day clock");
        }
    }

    /// The first real round trip, on one vault: fresh feed, fresh attestation, a fresh SIGNED v2 mark
    /// relayed by a stranger, a keeper-mode requestMint, and settleMint by the settler (not the
    /// attester, H-4).
    function _roundTrip(S5Harness d, uint256 i) internal {
        DeployTestnet.AssetDeployment memory dep = d.deploymentOf(i);
        CertVault v = CertVault(dep.vault);
        CertOracle o = CertOracle(dep.oracle);

        _refreshFeeds();
        uint256 oi = d.paramsOf(i).openInterest18;
        vm.prank(attester);
        SolvencyRegistry(registry).attest(dep.vault, 2, 0, 0, oi);

        uint64 obs = uint64(block.timestamp);
        bytes memory sig = _sign(o, ATTESTER_PK, PX[i], 1, obs, obs + 60);
        vm.prank(makeAddr("relayer"));
        o.setMarkPriceSigned(PX[i], 1, obs, obs + 60, sig);
        assertEq(o.markAt(), obs, "v2 mark carries its observation time");
        assertTrue(o.mintAllowed(), "mint gate open on a fresh v2 mark");

        TestUSDG(USDG).mint(alice, 100e6);
        vm.startPrank(alice);
        IERC20(USDG).approve(dep.vault, 100e6);
        uint256 id = v.requestMint(100e6);
        vm.stopPrank();
        assertEq(Certificate(dep.certificate).balanceOf(alice), 0, "keeper mode mints nothing before settlement");

        vm.prank(attester);
        vm.expectRevert(CertVault.CertVault_OnlySettler.selector);
        v.settleMint(id, PX[i]);

        vm.prank(settler);
        v.settleMint(id, PX[i]);
        (,,,,,, uint256 indicative) = v.mintReceipts(id);
        assertTrue(indicative > 0, "nothing indicated");
        assertEq(Certificate(dep.certificate).balanceOf(alice), indicative, "settled certificates");
        assertEq(v.venuePositionBase(), int256(indicative * 1e4 / 1e18), "ledger records the keeper's hedge");
    }

    function _writeStack4ShapedBook(S5Harness d) internal {
        string memory out = string.concat(
            '{\n  "chainId": 4663,\n  "senders": {"governance": "', vm.toString(safe), '"},\n  "vaults": [\n'
        );
        for (uint256 i = 0; i < nAssets; ++i) {
            out = string.concat(
                out,
                '    {"symbol": "', SYMS[i], '", "vault": "', vm.toString(d.deploymentOf(i).vault), '"}',
                i + 1 == nAssets ? "\n" : ",\n"
            );
        }
        vm.writeFile(string.concat("deployments/test-s5-", tag, ".stack4.json"), string.concat(out, "  ]\n}\n"));
    }

    /// @notice The same deploy and phase A driven ONLY by the documented environment variables
    ///         (docs/STACK5-DEPLOY-RUNBOOK.md), so a renamed or mis-typed env read fails a test.
    ///         Also pins the two defaults: ops wallet = deployer, treasury = the governance Safe.
    /// @dev The one test in this suite that writes the environment; every name it sets is read by
    ///      no other suite, so parallel threads cannot race on it.
    function test_stack5_envDriven_deployAndPhaseA() public {
        tag = "env";
        S5EnvHarness b1 = new S5EnvHarness();
        vm.setEnv("MAINNET_GOVERNANCE_SAFE", vm.toString(safe));
        vm.setEnv("MAINNET_ATTESTER_ADDR", vm.toString(attester));
        for (uint256 i = 0; i < 6; ++i) {
            vm.setEnv(string.concat("MAINNET_FEED_", SYMS[i]), vm.toString(address(feeds[i])));
        }
        bytes[] memory inits = b1.batch1InitCodes(attester);
        vm.setEnv("MAINNET_SAFE_REGISTRY", vm.toString(_createAs(safe, inits[0])));
        for (uint256 i = 0; i < 6; ++i) {
            vm.setEnv(string.concat("MAINNET_SAFE_ORACLE_", SYMS[i]), vm.toString(_createAs(safe, inits[i + 1])));
        }
        vm.setEnv("MAINNET_DEPLOYER_PK", vm.toString(bytes32(DEPLOYER_PK)));
        vm.setEnv("MAINNET_ATTESTER_PK", vm.toString(bytes32(ATTESTER_PK)));
        vm.setEnv("MAINNET_SEED_COLLATERAL", "1000000000");
        vm.setEnv("MAINNET_SETTLER_ADDR", vm.toString(settler));
        TestUSDG(USDG).mint(deployer, 6_000e6);

        S5EnvHarness d = new S5EnvHarness();
        d.run();
        (address feeVault_,,,, address settler_) = d.stack5Addresses();
        assertEq(settler_, settler, "MAINNET_SETTLER_ADDR");
        (address r2,) = FeeVault(feeVault_).recipientAt(2);
        (address r3,) = FeeVault(feeVault_).recipientAt(3);
        assertEq(r2, deployer, "ops wallet defaults to the deployer");
        assertEq(r3, safe, "treasury defaults to the governance Safe");

        for (uint256 i = 0; i < 6; ++i) {
            DeployTestnet.AssetDeployment memory dep = d.deploymentOf(i);
            LighterSim(ZK_LIGHTER).setDepositorAllowed(dep.vault, true);
            LighterSim(ZK_LIGHTER).setMarkPrice(d.paramsOf(i).marketIndex, PX[i]);
            CertVault(dep.vault).bootstrap();
            vm.setEnv(
                string.concat("PUBKEY_", SYMS[i]),
                "0x012258abd09aa219c49c168c88d3fdb0c4f1004757709ae2400824c2ed19534cb4e3e038864c6076"
            );
            vm.setEnv(string.concat("MINBASE_", SYMS[i]), "150");
            vm.setEnv(string.concat("MINQUOTE_", SYMS[i]), "10000000000000000000");
        }
        LighterSim(ZK_LIGHTER).settleBatch();
        vm.setEnv("API_KEY_INDEX", "3");
        new S5EnvHarness().phaseA();
        assertEq(_execAsSafe("phaseA"), 48, "phase A from env");
        _cleanup();
        _rm("deployments/test-s5-env.book.json");
    }

    // ============================================================================ the refusals

    /// @notice Phase B built before the two-day notice has run is refused, naming the first
    ///         proposal and when it is ready. Built anyway, it would be signed and then revert
    ///         CertVault_ChangeNotReady at execution.
    function test_stack5_phaseB_builtTooEarly_isRefused() public {
        tag = "early";
        _deploy("");
        uint256 t0 = block.timestamp;
        _h().phaseA();
        _execAsSafe("phaseA");

        vm.warp(t0 + 2 days - 1);
        S5Harness b = _h();
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeBatches.SafeBatches_PhaseBTooEarly.selector, "uTSLA", "setSettler", t0 + 2 days, t0 + 2 days - 1
            )
        );
        b.phaseB();

        // And openMinting cannot jump the queue: phase B has not been applied.
        S5Harness o = _h();
        o.setOpen("uTSLA", 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeBatches.SafeBatches_NotReady.selector, "uTSLA", "settler not applied - phase B not executed"
            )
        );
        o.openMinting();

        // At exactly readyAt it builds.
        vm.warp(t0 + 2 days);
        _h().phaseB();
        _cleanup();
    }

    /// @notice Phase B refuses when phase A is not on chain: first its immediate calls, and then a
    ///         single proposal that was cancelled after phase A.
    function test_stack5_phaseB_refusesWithoutPhaseAOnChain() public {
        tag = "nophaseA";
        S5Harness d = _deploy("");
        uint256 t0 = block.timestamp;
        _h().phaseA(); // built and recorded, NOT executed

        vm.warp(t0 + 3 days);
        S5Harness b = _h();
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeBatches.SafeBatches_NotReady.selector, "uTSLA", "not registered - phase A not executed"
            )
        );
        b.phaseB();

        // Execute phase A, then cancel uSPY's API-key proposal: that one proposal is missing.
        vm.warp(t0);
        _execAsSafe("phaseA");
        string memory r = vm.readFile(_path("phaseA-proposals"));
        bytes32 id = vm.parseJsonBytes32(r, ".proposals[4].id");
        assertEq(vm.parseJsonString(r, ".proposals[4].setter"), "setVenueApiKey", "fixture: proposal 4");
        CertVault spy = CertVault(d.deploymentOf(1).vault);
        vm.prank(safe);
        spy.cancelChange(id);

        vm.warp(t0 + 3 days);
        S5Harness b2 = _h();
        vm.expectRevert(
            abi.encodeWithSelector(SafeBatches.SafeBatches_ProposalNotOnChain.selector, "uSPY", "setVenueApiKey", id)
        );
        b2.phaseB();
        _cleanup();
    }

    /// @notice MAINNET_ONLY deploys one vault, and the ceiling is that asset's own row.
    function test_stack5_oneVaultDeploy_ceilingIsThatAssetsRow() public {
        tag = "one";
        S5Harness d = _deploy("uNVDA");
        assertEq(d.assetCount(), 1, "one vault");
        (,,,, address cap,) = d.sharedAddresses();
        assertEq(CapacityOracle(cap).maxAbsoluteCap(), 311_000e18, "ceiling = uNVDA's row");
        assertEq(vm.parseJsonUint(_book(), ".stack"), 5, "book");
        _cleanup();
    }

    /// @notice The wind-down builder retires and sweeps EMPTY vaults to the Safe.
    function test_stack5_retireBuilder_retiresAndSweepsEmptyVaults() public {
        tag = "retire";
        S5Harness d = _deploy("");
        _writeStack4ShapedBook(d);
        uint256 before = IERC20(USDG).balanceOf(safe);
        _h().retireStack4();
        assertEq(_execAsSafe("retire-stack4"), 12, "retire + sweep per vault");
        for (uint256 i = 0; i < 6; ++i) {
            assertTrue(CertVault(d.deploymentOf(i).vault).retired(), "retired");
        }
        assertGt(IERC20(USDG).balanceOf(safe), before, "capital swept to the Safe");
        _cleanup();
    }

    /// @notice The settler must be its own key (H-4), and the mainnet book needs a real commit.
    function test_stack5_deployRefusals() public {
        tag = "refuse";
        S5Harness bad = new S5Harness(tag, safe, attester);
        vm.expectRevert(bytes("SENDERS: settler == attester (H-4)"));
        bad.run();

        S5Harness noSettler = new S5Harness(tag, safe, address(0));
        vm.expectRevert(); // DeployMainnet_AnswerRequired("MAINNET_SETTLER_ADDR: ...")
        noSettler.run();

        S5Harness eoaTreasury = new S5Harness(tag, makeAddr("eoaSafe"), settler);
        vm.expectRevert(bytes("MAINNET: the governance Safe has no code on this chain"));
        eoaTreasury.run();

        SafeBatches production = new SafeBatches();
        vm.expectRevert(bytes("SafeBatches: pick a batch with --sig; the deploy is DeployMainnet.s.sol"));
        production.run();

        vm.chainId(46_630);
        S5Harness wrongChain = new S5Harness(tag, safe, settler);
        vm.expectRevert(abi.encodeWithSelector(DeployTestnet.DeployTestnet_WrongChain.selector, 46_630, 4663));
        wrongChain.run();
        vm.expectRevert(abi.encodeWithSelector(SafeBatches.SafeBatches_WrongChain.selector, 46_630));
        wrongChain.phaseA();
        vm.chainId(4663);

        tag = "refuse-commit";
        S5Harness d = _h();
        d.setCommit("");
        // batch 1 first, so the run gets as far as writing the book.
        S5Harness b1 = _h();
        bytes[] memory inits = b1.batch1InitCodes(attester);
        address reg = _createAs(safe, inits[0]);
        address[] memory oracles = new address[](6);
        for (uint256 i = 0; i < 6; ++i) {
            oracles[i] = _createAs(safe, inits[i + 1]);
        }
        d.setAdopted(reg, oracles);
        TestUSDG(USDG).mint(deployer, 6_000e6);
        vm.expectRevert(bytes("COMMIT must be a 40-char lowercase hash on mainnet: COMMIT=$(git rev-parse HEAD)"));
        d.run();
        _cleanup();
    }
}
