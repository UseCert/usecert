// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployTestnet} from "../../script/DeployTestnet.s.sol";
import {VerifyTestnet} from "../../script/VerifyTestnet.s.sol";
import {CertOracle} from "../../src/CertOracle.sol";
import {SolvencyRegistry} from "../../src/SolvencyRegistry.sol";
import {CapacityOracle} from "../../src/CapacityOracle.sol";
import {LighterSim} from "../../src/sim/LighterSim.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice A `DeployTestnet` that runs every phase and WRITES NO ADDRESS BOOK.
///
/// @dev THE OMISSION IS THE POINT, TWICE OVER.
///
///      First, `DeployTestnet._writeAddressBook()` writes `deployments/46630.json` UNCONDITIONALLY
///      at a fixed path, and `test/script/DeployTestnet.t.sol` reads that exact file back asserting
///      its own addresses are in it. Two suites writing it would make that test fail
///      intermittently, so this fixture never touches it: the tests below assemble a book in the
///      real format and hand it to the parser through its seam, and the live `anvil` run in
///      `docs/TESTNET-RUNBOOK.md` is what exercises the real file.
///
///      Second, this fixture also omits `_verifyLocalSimulation()`, which is what makes a
///      DELIBERATELY BROKEN DEPLOYMENT constructible at all. That function is the deploy script's
///      abort gate and it would refuse to finish a run with a crossed oracle — correctly, and
///      `test/script/DeployTestnet.t.sol` is where that refusal is asserted. But §9 exists for the
///      state the abort gate did not see, so producing that state on-chain is exactly what a test
///      of `VerifyTestnet` needs.
///
///      Everything else — the phases, their order, every immutable constant, both senders'
///      separation — is inherited rather than copied. Phase 2's two constructions are written out
///      here because they live inline in `run()`'s own frame (`SolvencyRegistry` and `CertOracle`
///      bind `governance = msg.sender` at construction), and that property is asserted by
///      `test/script/DeployTestnet.t.sol`, not here.
///
///      THE THREE INPUTS COME THROUGH THE SCRIPT'S OWN SEAMS, never through `vm.setEnv`: a
///      `setEnv` inside a test function is not rolled back by the post-`setUp` snapshot and an
///      in-test restore does not reliably take effect for the next test.
contract VerifyFixture is DeployTestnet {
    uint256 private immutable _dPk;
    uint256 private immutable _gPk;
    uint256 private immutable _aPk;
    address private immutable _collat;
    address private immutable _keeper;

    constructor(uint256 dPk_, uint256 gPk_, uint256 aPk_, address collat_, address keeper_) {
        _dPk = dPk_;
        _gPk = gPk_;
        _aPk = aPk_;
        _collat = collat_;
        _keeper = keeper_;
    }

    function _senderKeys() internal view override returns (uint256, uint256, uint256) {
        return (_dPk, _gPk, _aPk);
    }

    function _deployCollateral() internal override returns (address) {
        return _collat;
    }

    function _batchKeeperAddress() internal view override returns (address) {
        return _keeper;
    }

    function deployAll() external {
        (uint256 deployerPk, uint256 govPk, uint256 attesterPk) = _senderKeys();
        deployerAddr = vm.addr(deployerPk);
        govAddr = vm.addr(govPk);
        attesterAddr = vm.addr(attesterPk);

        _loadAssets();
        collateral = _deployCollateral();
        batchKeeper = _batchKeeperAddress();

        vm.startBroadcast(deployerPk);
        _phase1_simulators();
        vm.stopBroadcast();

        // Phase 2, inline for the reason in the contract NatSpec.
        vm.startBroadcast(govPk);
        registry = address(new SolvencyRegistry(attesterAddr));
        uint256 n = assets.length;
        for (uint256 i = 0; i < n; ++i) {
            deployed.push(
                AssetDeployment({
                    aggregator: address(0),
                    oracle: address(0),
                    vault: address(0),
                    certificate: address(0),
                    bufferBook: address(0)
                })
            );
        }
        for (uint256 i = 0; i < n; ++i) {
            deployed[i].aggregator = _aggregatorOf(i);
            deployed[i].oracle = address(
                new CertOracle(
                    _aggregatorOf(i),
                    attesterAddr,
                    assets[i].priceDecimals,
                    STALENESS_SECONDS,
                    DEVIATION_BPS,
                    BASIS_BAND_BPS,
                    POKE_CONFIRMATION_SECONDS,
                    SINGLE_SOURCE
                )
            );
        }
        vm.stopBroadcast();

        vm.startBroadcast(deployerPk);
        _phase3_coreAndVaults();
        vm.stopBroadcast();

        vm.startBroadcast(govPk);
        _phase4_governance();
        vm.stopBroadcast();

        vm.startBroadcast(deployerPk);
        _phase5_allowlistMarksAndBootstrap();
        vm.stopBroadcast();

        vm.startBroadcast(attesterPk);
        _phase6_attest();
        vm.stopBroadcast();
    }

    /// @dev The book's `parameters` and per-vault blocks, PRODUCTION-IDENTICAL because they are the
    ///      script's own generators rather than a copy. If a parameter is added to the book, these
    ///      tests parse the same text an operator's book carries — a copy here would drift and the
    ///      drift would look like a passing test.
    function parametersJson() external pure returns (string memory) {
        return _parametersJson();
    }

    function assetJson(uint256 i) external view returns (string memory) {
        return _assetJson(i);
    }
}

/// @notice The crossed-oracle deployment. THE PROPERTY `registerVault` DOES NOT CHECK.
///
/// @dev Each vault is wired to the OTHER mirror's `CertOracle` while the address book still records
///      each asset's own — the exact shape of the defect §9's row 5 exists to catch. The swap is
///      done around `super._phase3_coreAndVaults()` and undone immediately, so the vaults' IMMUTABLE
///      `oracle` is the wrong one and the book is right: nothing on-chain is repairable, because the
///      dependency is immutable on both sides and the remedy is a redeployment.
///
///      `CertFactory.registerVault` accepts this deployment without complaint. It cross-checks the
///      certificate and records the vault; it has no way to know which oracle the vault should have
///      had. The old `deployVault` guaranteed the match structurally by wiring the dependencies from
///      the factory's own immutables, and it cannot exist any more (EIP-170, §0). That is the gap.
contract VerifyFixtureCrossedOracles is VerifyFixture {
    constructor(uint256 d, uint256 g, uint256 a, address c, address k) VerifyFixture(d, g, a, c, k) {}

    function _phase3_coreAndVaults() internal override {
        (deployed[0].oracle, deployed[1].oracle) = (deployed[1].oracle, deployed[0].oracle);
        super._phase3_coreAndVaults();
        (deployed[0].oracle, deployed[1].oracle) = (deployed[1].oracle, deployed[0].oracle);
    }
}

/// @notice A `VerifyTestnet` fed a book through the seam rather than off disk.
/// @dev The seam is the FILE READ, so every line of the real parser still runs — `keyExistsJson`
///      probing, the quoted-bignum reads, the uint16/uint8 range checks. A test that overrode
///      `_book()` and handed in a struct would test nothing.
contract VerifyWithBook is VerifyTestnet {
    string private _json;

    constructor(string memory json_) {
        _json = json_;
    }

    function _bookJson() internal view override returns (string memory) {
        return _json;
    }
}

/// @notice Task 11's tests: `script/VerifyTestnet.s.sol` against a live in-process deployment.
///
/// @dev WHAT THESE PROVE. `VerifyTestnet` reads the chain, so running it in-process against a
///      fixture deployment is not a weaker form of the real thing — the reads are the same reads.
///      What the in-process run cannot show is the RPC and the real file, and the `anvil` run
///      recorded in this task's report is what covers those.
///
///      EVERY NEGATIVE CASE BREAKS ONE THING AND ASSERTS THE MESSAGE THAT NAMES IT. A verifier
///      that fails is worth nothing if it fails with "verification failed"; the operator has to be
///      told which §9 row and what to do. So the expected revert strings here are the full
///      messages, and changing one is a deliberate act rather than a silent drift.
contract VerifyTestnetTest is Test {
    MockERC20 internal collateral;
    VerifyFixture internal fixture;

    /// @dev Well-known throwaway test keys. The SCRIPTS never hardcode a key.
    uint256 internal constant DEPLOYER_PK = 0xD3910;
    uint256 internal constant GOV_PK = 0x60;
    uint256 internal constant ATTESTER_PK = 0xA77E5;

    uint256 internal constant CHAIN_ID = 46_630;

    address internal deployerAddr;
    address internal govAddr;
    address internal attesterAddr;
    address internal batchKeeperAddr = makeAddr("batchKeeper");

    function setUp() public {
        // `ReplayAggregator` stamps round 1 at `block.timestamp` and `CertOracle`'s constructor
        // rejects a feed already older than `stalenessSeconds`. At Foundry's default timestamp of 1
        // the arithmetic works and the figures read as nonsense.
        vm.warp(1_800_000_000);
        vm.chainId(CHAIN_ID);

        deployerAddr = vm.addr(DEPLOYER_PK);
        govAddr = vm.addr(GOV_PK);
        attesterAddr = vm.addr(ATTESTER_PK);

        collateral = new MockERC20("Test USDG", "tUSDG", 6);
        collateral.mint(deployerAddr, 10_000_000e6);
        vm.deal(deployerAddr, 100 ether);
        vm.deal(govAddr, 100 ether);
        vm.deal(attesterAddr, 100 ether);

        fixture = new VerifyFixture(DEPLOYER_PK, GOV_PK, ATTESTER_PK, address(collateral), batchKeeperAddr);
        fixture.deployAll();
    }

    // ---------------------------------------------------------------------------- happy path

    /// @notice The whole of §9 against a good deployment, from the book.
    /// @dev The first half of the assertion is that `run()` does not revert: every §9 item is a
    ///      `require` in there. The second half re-derives the sharpest few here, so a `require`
    ///      accidentally deleted from the script fails a test rather than passing silently.
    function test_verifyPassesOnAGoodDeployment() public {
        _verify(_book(fixture));

        (,, address lighter_, address registry_,,) = fixture.sharedAddresses();
        assertEq(SolvencyRegistry(registry_).governance(), govAddr, "registry.governance");
        assertEq(LighterSim(lighter_).keeper(), batchKeeperAddr, "sim keeper");
        assertFalse(LighterSim(lighter_).strictMode(), "strictMode must be off");
        assertEq(LighterSim(lighter_).accountCount(), fixture.assetCount(), "only the vaults hold accounts");
    }

    // ----------------------------------------------- the property registerVault does not check

    /// @notice §9 row 5, THE REQUIRED TEST. A vault pointed at the wrong `CertOracle`.
    /// @dev `registerVault` accepts this deployment; the factory has no way to know. Every
    ///      dependency is immutable on both sides, so there is no repair — which is why §9 is a
    ///      pre-funding gate and not a monitoring dashboard.
    function test_verifyScriptCatchesAWrongDependency() public {
        VerifyFixture crossed =
            new VerifyFixtureCrossedOracles(DEPLOYER_PK, GOV_PK, ATTESTER_PK, address(collateral), batchKeeperAddr);
        crossed.deployAll();

        // The deployment is otherwise perfect: registered, capped, bootstrapped, attested.
        (,,,, address capacity_, address factory_) = crossed.sharedAddresses();
        DeployTestnet.AssetDeployment memory d = crossed.deploymentOf(0);
        assertTrue(_isVault(factory_, d.vault), "the factory registered the crossed vault without complaint");
        assertTrue(CapacityOracle(capacity_).absoluteCap18(d.vault) != 0, "and governance capped it");

        _verifyExpecting(
            _book(crossed),
            "V9-05: vault.oracle() != vaults[i].certOracle in the book - the vault prices off a different oracle"
        );
    }

    // ------------------------------------------------------ item 4's five simulator preconditions

    /// @notice Precondition 1: `targetMarginBps >= LighterSim.requiredMarginBps()`, PER VAULT.
    /// @dev Reached by RAISING the simulator's requirement above the vaults' 9000, which is the
    ///      realistic version of this misconfiguration: `setRequiredMarginBps` refuses to go below
    ///      the venue floor and `CertVault`'s constructor floors `targetMarginBps` at 5000, so the
    ///      pairing can only be broken from the simulator's side. Every hedge would then be
    ///      silently rejected at settlement while `venuePositionBase` kept claiming it.
    function test_verifyCatchesAVaultBelowTheSimulatorsMarginRequirement() public {
        (,, address lighter_,,,) = fixture.sharedAddresses();
        vm.prank(deployerAddr);
        LighterSim(lighter_).setRequiredMarginBps(9_500);

        _verifyExpecting(
            _book(fixture),
            "V9-P1: cfg.targetMarginBps < LighterSim.requiredMarginBps() - EVERY HEDGE IS SILENTLY REJECTED, the vault mints unhedged"
        );
    }

    /// @notice Precondition 2: a mark price for every market an allowlisted vault trades.
    /// @dev One unmarked market reverts the WHOLE settlement window (`settleBatch`'s pre-pass), and
    ///      at a zero mark the margin gate passes vacuously at any size because notional is
    ///      `|position| * 0`.
    function test_verifyCatchesAnUnsetVenueMark() public {
        (,, address lighter_,,,) = fixture.sharedAddresses();
        DeployTestnet.AssetParams memory a = fixture.paramsOf(1);
        vm.prank(deployerAddr);
        LighterSim(lighter_).setMarkPrice(a.marketIndex, 0);

        _verifyExpecting(
            _book(fixture),
            "V9-P2: LighterSim.markPrice(cfg.marketIndex) is UNSET - settleBatch reverts for the whole batch and margin passes vacuously"
        );
    }

    /// @notice Precondition 3: the keeper is set, and it is the address in the book.
    /// @dev Zero means "owner only", which is INDISTINGUISHABLE ON-CHAIN FROM A DEAD KEEPER: every
    ///      `settleBatch` from the bot's key reverts `LighterSim_OnlyOwnerOrKeeper`.
    function test_verifyCatchesAnUnsetKeeper() public {
        (,, address lighter_,,,) = fixture.sharedAddresses();
        vm.prank(deployerAddr);
        LighterSim(lighter_).setKeeper(address(0));

        _verifyExpecting(
            _book(fixture),
            "V9-13: LighterSim.keeper() is unset - settleBatch reverts LighterSim_OnlyOwnerOrKeeper for the keeper bot"
        );
    }

    /// @notice Precondition 3, the other half: a keeper that is not the one the book names.
    function test_verifyCatchesAKeeperThatIsNotTheBooksKeeper() public {
        (,, address lighter_,,,) = fixture.sharedAddresses();
        vm.prank(deployerAddr);
        LighterSim(lighter_).setKeeper(makeAddr("someOtherBot"));

        _verifyExpecting(
            _book(fixture),
            "V9-13: LighterSim.keeper() != shared.batchKeeper in the book - every settleBatch from that key reverts"
        );
    }

    /// @notice Precondition 4: `strictMode == false`, the deployed default.
    /// @dev `true` turns one account's under-margined order into a whole-batch revert, which stops
    ///      settlement for every vault sharing the simulator.
    function test_verifyCatchesStrictModeLeftOn() public {
        (,, address lighter_,,,) = fixture.sharedAddresses();
        vm.prank(deployerAddr);
        LighterSim(lighter_).setStrictMode(true);

        _verifyExpecting(
            _book(fixture),
            "V9-P4: LighterSim.strictMode() is true - one under-margined order would revert whole batches"
        );
    }

    /// @notice Precondition 5: nothing but the operator's own vaults is allowlisted.
    /// @dev A second allowed address is a second account able to reach `MAX_QUEUE` and share the
    ///      settlement queue — the liveness half of the hazard Task 7's per-account isolation left
    ///      standing, and the reason the allowlist was kept rather than deleted.
    function test_verifyCatchesAStrangerOnTheDepositorAllowlist() public {
        (,, address lighter_,,,) = fixture.sharedAddresses();
        vm.prank(deployerAddr);
        LighterSim(lighter_).setDepositorAllowed(batchKeeperAddr, true);

        _verifyExpecting(
            _book(fixture),
            "V9-P5: LighterSim.depositorAllowed is TRUE for shared.batchKeeper - a non-vault address can hold an account, reach MAX_QUEUE and share the settlement queue"
        );
    }

    /// @notice Precondition 5's stronger half: an address other than the vaults holding an account.
    /// @dev `accountCount()` is the fact that actually bounds the hazard — an allowlisted address
    ///      that never deposited holds no account, no position and no collateral. This one deposits.
    function test_verifyCatchesASecondAccountOnTheVenue() public {
        (,, address lighter_,,,) = fixture.sharedAddresses();
        address stranger = makeAddr("stranger");
        vm.prank(deployerAddr);
        LighterSim(lighter_).setDepositorAllowed(stranger, true);
        collateral.mint(stranger, 1_000e6);
        vm.startPrank(stranger);
        collateral.approve(lighter_, 1_000e6);
        LighterSim(lighter_).deposit(stranger, 3, 0, 1_000e6);
        vm.stopPrank();

        // The stranger is not named in the book, so the per-address probe cannot see it. This is
        // the check that does.
        _verifyExpecting(
            _book(fixture),
            "V9-P5: LighterSim.accountCount() != the number of vaults - an address other than the operator's vaults holds an account"
        );
    }

    // -------------------------------------------------------------------- other sharp §9 rows

    /// @notice §9 row 4, per vault. THE SINGLE MOST LIKELY WAY THE DEPLOYMENT APPEARS BROKEN.
    /// @dev Zero means NO CAPACITY, not unbounded: the vault reads as perfectly deployed and every
    ///      mint reverts `CertVault_AtCapacity`. Governance can undo this one, which is exactly why
    ///      the message says so.
    function test_verifyCatchesAnUnsetAbsoluteCap() public {
        (,,,, address capacity_,) = fixture.sharedAddresses();
        DeployTestnet.AssetDeployment memory d = fixture.deploymentOf(0);
        vm.prank(govAddr);
        CapacityOracle(capacity_).setAbsoluteCap(d.vault, 0);

        _verifyExpecting(
            _book(fixture),
            "V9-04: capacity.absoluteCap18(vault) is UNSET - every mint reverts CertVault_AtCapacity until governance sets it"
        );
    }

    /// @notice §9 rows 1-2: an attester rotation left in flight.
    function test_verifyCatchesAPendingAttesterRotation() public {
        (,,, address registry_,,) = fixture.sharedAddresses();
        vm.prank(govAddr);
        SolvencyRegistry(registry_).proposeAttester(makeAddr("nextAttester"));

        _verifyExpecting(_book(fixture), "V9-02: registry.pendingAttester() != 0 - a rotation is in flight");
    }

    // ------------------------------------------------------------------- the book's own hazards

    /// @notice A book from another chain parses perfectly and every address in it is dead code
    ///         here. Caught before a single assertion is made about their state, so "wrong book"
    ///         never presents as "broken deployment".
    function test_verifyRejectsABookFromAnotherChain() public {
        string memory book = _book(fixture);
        vm.chainId(1);
        _verifyExpecting(book, "V9-00: book chainId != the chain this RPC is on - wrong book or wrong RPC");
    }

    /// @notice A book left in the tree while a later deployment happened elsewhere.
    /// @dev Same parse, addresses that are `0x` on this chain. `vm.etch` cannot un-deploy, so this
    ///      substitutes an address that never had code — which is what a stale book contains.
    function test_verifyRejectsABookNamingAnAddressWithNoCode() public {
        string memory book = _bookWithVaultZeroAt(fixture, makeAddr("neverDeployed"));
        _verifyExpecting(book, "V9-00: no code at the book's vault on this chain - stale book");
    }

    /// @notice A book with no vaults at all. `MAX_MIRRORS` bounds the probe; zero is an error
    ///         rather than a clean run over nothing.
    function test_verifyRejectsABookWithNoVaults() public {
        _verifyExpecting(
            _bookWithNoVaults(fixture), "V9-BOOK: no vaults in the address book - re-run script/DeployTestnet.s.sol"
        );
    }

    // --------------------------------------------------------------------------------- helpers

    function _verify(string memory book) private {
        new VerifyWithBook(book).run();
    }

    /// @dev THE VERIFIER IS CONSTRUCTED FIRST AND ONLY THEN IS THE REVERT EXPECTED.
    ///      `vm.expectRevert` arms the VERY NEXT CALL, and `new VerifyWithBook(...)` is a call — so
    ///      arming before the construction consumes the expectation on the constructor and every
    ///      negative case reports "next call did not revert as expected" while the verifier is
    ///      working perfectly. Measured: that was the first draft of this file.
    function _verifyExpecting(string memory book, string memory message) private {
        VerifyWithBook v = new VerifyWithBook(book);
        vm.expectRevert(bytes(message));
        v.run();
    }

    function _isVault(address factory, address vault) private view returns (bool ok) {
        (, bytes memory ret) = factory.staticcall(abi.encodeWithSignature("isVault(address)", vault));
        ok = abi.decode(ret, (bool));
    }

    /// @dev The address book, in the format `DeployTestnet._writeAddressBook()` writes. The
    ///      `parameters` and per-vault blocks come from the script's OWN generators, so they cannot
    ///      drift from what an operator's book carries; only the outer shell is assembled here.
    ///
    ///      Concatenated one row at a time, not in a few wide `string.concat` calls: a wide concat
    ///      blows the legacy codegen's stack, and `via_ir` is off and must stay off.
    function _book(VerifyFixture f) private view returns (string memory) {
        return _bookWith(f, address(0), true);
    }

    function _bookWithVaultZeroAt(VerifyFixture f, address vault) private view returns (string memory) {
        return _bookWith(f, vault, true);
    }

    function _bookWithNoVaults(VerifyFixture f) private view returns (string memory) {
        return _bookWith(f, address(0), false);
    }

    /// @param overrideVault0 if non-zero, replaces `vaults[0].vault` with this address.
    /// @param withVaults if false, emits an empty `vaults` array.
    function _bookWith(VerifyFixture f, address overrideVault0, bool withVaults)
        private
        view
        returns (string memory out)
    {
        (address collat_,, address lighter_, address registry_, address capacity_, address factory_) =
            f.sharedAddresses();

        out = "{\n";
        out = string.concat(out, '  "chainId": ', vm.toString(block.chainid), ",\n");
        // An UNKNOWN SIBLING KEY, on purpose: the parser must survive the address book growing. A
        // concurrent task is adding a collateral token and a faucet to `shared` right now, and a
        // parser that read the book as a struct would break on the first added field.
        out = string.concat(out, '  "_generatedBy": "test/script/VerifyTestnet.t.sol",\n');
        out = string.concat(out, '  "senders": {\n');
        out = string.concat(out, '    "deployer": "', vm.toString(deployerAddr), '",\n');
        out = string.concat(out, '    "governance": "', vm.toString(govAddr), '",\n');
        out = string.concat(out, '    "attester": "', vm.toString(attesterAddr), '"\n  },\n');
        out = string.concat(out, '  "shared": {\n');
        out = string.concat(out, '    "collateral": "', vm.toString(collat_), '",\n');
        out = string.concat(out, '    "collateralDecimals": 6,\n');
        out = string.concat(out, '    "testFaucet": "', vm.toString(address(0)), '",\n');
        out = string.concat(out, '    "_anAddedKeyTheParserMustIgnore": "see the note above",\n');
        out = string.concat(out, '    "lighterSim": "', vm.toString(lighter_), '",\n');
        out = string.concat(out, '    "solvencyRegistry": "', vm.toString(registry_), '",\n');
        out = string.concat(out, '    "capacityOracle": "', vm.toString(capacity_), '",\n');
        out = string.concat(out, '    "batchKeeper": "', vm.toString(batchKeeperAddr), '",\n');
        out = string.concat(out, '    "certFactory": "', vm.toString(factory_), '"\n  },\n');
        out = string.concat(out, '  "parameters": {\n', f.parametersJson(), "\n  },\n");
        out = string.concat(out, _vaultsJson(f, overrideVault0, withVaults));
    }

    function _vaultsJson(VerifyFixture f, address overrideVault0, bool withVaults)
        private
        view
        returns (string memory out)
    {
        if (!withVaults) return '  "vaults": []\n}\n';
        out = '  "vaults": [\n';
        uint256 n = f.assetCount();
        for (uint256 i = 0; i < n; ++i) {
            string memory row = f.assetJson(i);
            if (i == 0 && overrideVault0 != address(0)) {
                row = _replaceVaultAddress(f, row, overrideVault0);
            }
            out = string.concat(out, row, i + 1 == n ? "\n" : ",\n");
        }
        out = string.concat(out, "  ]\n}\n");
    }

    /// @dev Rebuilds vault 0's row with a substituted `vault` address. Written out rather than done
    ///      with a string search-and-replace because a Solidity string replace over the script's own
    ///      generated JSON is more code, and more fragile, than naming the seven fields the parser
    ///      actually reads.
    function _replaceVaultAddress(VerifyFixture f, string memory, address vault)
        private
        view
        returns (string memory out)
    {
        DeployTestnet.AssetParams memory a = f.paramsOf(0);
        DeployTestnet.AssetDeployment memory d = f.deploymentOf(0);
        out = "    {\n";
        out = string.concat(out, '      "symbol": "', a.symbol, '",\n');
        out = string.concat(out, '      "marketIndex": ', vm.toString(uint256(a.marketIndex)), ",\n");
        out = string.concat(out, '      "priceDecimals": ', vm.toString(uint256(a.priceDecimals)), ",\n");
        out = string.concat(out, '      "sizeDecimals": ', vm.toString(uint256(a.sizeDecimals)), ",\n");
        out = string.concat(out, '      "vault": "', vm.toString(vault), '",\n');
        out = string.concat(out, '      "certificate": "', vm.toString(d.certificate), '",\n');
        out = string.concat(out, '      "bufferBook": "', vm.toString(d.bufferBook), '",\n');
        out = string.concat(out, '      "certOracle": "', vm.toString(d.oracle), '",\n');
        out = string.concat(out, '      "replayAggregator": "', vm.toString(d.aggregator), '",\n');
        out = string.concat(out, '      "seedPrice18": "', vm.toString(a.seedPx18), '",\n');
        out = string.concat(out, '      "absoluteCap18": "', vm.toString(a.absoluteCap18), '",\n');
        out = string.concat(out, '      "seedOpenInterest18": "', vm.toString(a.openInterest18), '"\n    }');
    }
}
