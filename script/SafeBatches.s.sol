// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {DeployMainnet} from "./DeployMainnet.s.sol";
import {SolvencyRegistry} from "../src/SolvencyRegistry.sol";
import {CertOracle} from "../src/CertOracle.sol";
import {CertVault} from "../src/CertVault.sol";
import {CertFactory} from "../src/CertFactory.sol";
import {CapacityOracle} from "../src/CapacityOracle.sol";
import {Certificate} from "../src/Certificate.sol";

/// @title SafeBatches — everything the governance Safe signs for a stack-5 mainnet deployment.
///
/// @notice It broadcasts NOTHING. Each entry point reads the chain and the address book, refuses if
///         the chain is not in the state the batch assumes, and writes a Safe Transaction Builder
///         file (Safe app -> Transaction Builder -> drag the JSON in) plus the equivalent
///         MultiSendCallOnly payload for `deploy/bin/usecert-safe-propose`. Owners review and sign
///         in the Safe app as always.
///
///         ORDER (docs/STACK5-DEPLOY-RUNBOOK.md):
///           batch1()        before the deploy   the Safe CREATES SolvencyRegistry and the six
///                                               CertOracles, so it is their immutable governance.
///           [DeployMainnet, then usecert-mainnet-bootstrap]
///           phaseA()        day 0               register, set-once sinks, keeper mode, proposals.
///           phaseB()        day >= 2            the three delayed applies, same calldata.
///           openMinting()   per vault           the capacity cap: the only thing that opens mints.
///           retireStack4()  after stack 5 lives stack 4's empty vaults: retire + sweepRetired.
///
///         Files land in `deployments/` (the only directory forge may write here), which is
///         git-ignored: they are review artefacts, reproducible from the book and the chain.
///
///         env: MAINNET_GOVERNANCE_SAFE always; batch1 MAINNET_ATTESTER_ADDR, MAINNET_FEED_<SYM>;
///         phaseA API_KEY_INDEX, PUBKEY_<SYM>, MINBASE_<SYM>, MINQUOTE_<SYM>; openMinting
///         OPEN_VAULTS (e.g. "uTSLA" or "all"), optional OPEN_CAP18; retireStack4 optional
///         VENUE_AMOUNT_<SYM> and STACK4_BOOK. MAINNET_ONLY as for the deploy. STACK5_BOOK once the
///         stack-5 book has been promoted to 4663.json.
contract SafeBatches is DeployMainnet {
    address internal constant MULTISEND_141 = 0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526;
    address internal constant CREATECALL_141 = 0x9b35Af71d77eaf8d7e40252370304687390A1A52;
    address internal constant MULTISEND_CALLONLY_141 = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    bytes4 internal constant PERFORM_CREATE = bytes4(keccak256("performCreate(uint256,bytes)"));
    bytes4 internal constant MULTI_SEND = bytes4(keccak256("multiSend(bytes)"));

    /// @dev Same bound CertVault.setVenueMinimums applies (MAX_VENUE_MIN_NOTIONAL_18).
    uint256 internal constant VENUE_MIN_NOTIONAL_CEILING_18 = 1_000e18;

    error SafeBatches_WrongChain(uint256 chainId);
    /// @dev Phase B: a phase-A proposal has no `changeReadyAt` on chain. Phase A was not executed,
    ///      or this proposal was already applied, or cancelled.
    error SafeBatches_ProposalNotOnChain(string symbol, string setter, bytes32 id);
    /// @dev Phase B built before a proposal's two-day notice has run.
    error SafeBatches_PhaseBTooEarly(string symbol, string setter, uint256 readyAt, uint256 nowTs);
    /// @dev A batch whose preconditions (earlier batches, bootstrap) are not on chain yet.
    error SafeBatches_NotReady(string symbol, string what);

    // --------------------------------------------------------------- the batch being built

    address[] internal _txTo;
    bytes[] internal _txData;

    // Phase-A proposals, in the order they are proposed and later applied.
    string[] internal _pSymbol;
    string[] internal _pSetter;
    address[] internal _pVault;
    bytes[] internal _pData;

    // What the stack-5 book says.
    address internal bFactory;
    address internal bCapacity;
    address internal bFeeVault;
    address internal bInsurance;
    address internal bSettler;
    address[] internal bVault;
    address[] internal bCert;

    // ------------------------------------------------------------------------------ seams
    //
    // Env reads behind virtual functions so an in-process test can answer them by subclassing
    // rather than by writing the process environment (see CommitGuard.t.sol for why).

    function _batchSafe() internal view virtual returns (address) {
        return _externalGovernance();
    }

    function _batch1Attester() internal view virtual returns (address) {
        return vm.envAddress("MAINNET_ATTESTER_ADDR");
    }

    function _apiKeyIndex() internal view virtual returns (uint8) {
        return uint8(vm.envUint("API_KEY_INDEX"));
    }

    function _pubKeyOf(string memory sym) internal view virtual returns (bytes memory) {
        return vm.envBytes(string.concat("PUBKEY_", sym));
    }

    /// @dev Venue minimums as read off the venue's market list (min_base_amount in base units at
    ///      the market's size decimals; min_quote_amount in 18 decimals). Never typed in.
    function _minBaseOf(string memory sym) internal view virtual returns (uint256) {
        return vm.envUint(string.concat("MINBASE_", sym));
    }

    function _minQuoteOf(string memory sym) internal view virtual returns (uint256) {
        return vm.envUint(string.concat("MINQUOTE_", sym));
    }

    function _openVaults() internal view virtual returns (string memory) {
        return vm.envString("OPEN_VAULTS");
    }

    /// @dev 0 = each asset's own reviewed cap. Non-zero caps every opened vault lower (a first,
    ///      small opening); it can never raise a vault above its reviewed row.
    function _openCap18() internal view virtual returns (uint256) {
        return vm.envOr("OPEN_CAP18", uint256(0));
    }

    function _venueAmountOf(string memory sym) internal view virtual returns (uint256) {
        return vm.envOr(string.concat("VENUE_AMOUNT_", sym), uint256(0));
    }

    /// @dev Stack 4's book: `deployments/4663.json` until cutover, then wherever it was moved
    ///      (STACK4_BOOK=deployments/history/...).
    function _stack4BookPath() internal view virtual returns (string memory) {
        return vm.envOr("STACK4_BOOK", string("deployments/4663.json"));
    }

    /// @dev The stack-5 book the batches READ (this contract never writes one): the deploy's
    ///      `4663.stack5.json`, or `STACK5_BOOK=deployments/4663.json` once it has been promoted.
    function _bookPath() internal view virtual override returns (string memory) {
        return vm.envOr("STACK5_BOOK", super._bookPath());
    }

    /// @dev `forge script script/SafeBatches.s.sol` with no `--sig` would otherwise run the inherited
    ///      DEPLOY, with this file's env overrides. The deploy is `script/DeployMainnet.s.sol`.
    function run() public virtual override {
        require(_allowDeployFromBatches(), "SafeBatches: pick a batch with --sig; the deploy is DeployMainnet.s.sol");
        super.run();
    }

    function _allowDeployFromBatches() internal view virtual returns (bool) {
        return false;
    }

    function _outPath(string memory name) internal view virtual returns (string memory) {
        return string.concat("deployments/4663.stack5.", name, ".json");
    }

    // ============================================================================== batch 1

    /// @notice Batch 1: the Safe creates SolvencyRegistry and one CertOracle per asset, so that it
    ///         is their `governance` (both bind msg.sender at construction, immutably).
    /// @dev A Safe cannot CREATE directly; it delegatecalls Safe's CreateCall library, inside which
    ///      CREATE runs in the Safe's context. One Safe transaction: a delegatecall to MultiSend
    ///      1.4.1 whose entries are delegatecalls to CreateCall 1.4.1. Stack 5's oracles take
    ///      `maxMarkAge` (MAX_MARK_AGE, 300 s) - the constructor arguments are exactly
    ///      DeployMainnet's, from the same asset table and constants.
    ///
    ///         forge script script/SafeBatches.s.sol:SafeBatches --sig 'batch1()' --rpc-url $RPC
    function batch1() external {
        if (block.chainid != MAINNET_CHAIN_ID) revert SafeBatches_WrongChain(block.chainid);
        address safe = _batchSafe();
        address attester = _batch1Attester();
        require(safe.code.length > 0, "SafeBatches: the Safe has no code on this chain");
        require(MULTISEND_141.code.length > 0 && CREATECALL_141.code.length > 0, "SafeBatches: Safe libraries missing");

        bytes[] memory inits = batch1InitCodes(attester);
        uint64 nonce = vm.getNonce(safe);
        bytes memory packed;
        for (uint256 k = 0; k < inits.length; ++k) {
            packed = _entry(packed, inits[k]);
            string memory what = k == 0 ? "registry" : string.concat("oracle ", assets[k - 1].symbol);
            console2.log(string.concat("CREATE ", what, " ->"), vm.computeCreateAddress(safe, nonce + uint64(k)));
        }

        bytes memory data = abi.encodeWithSelector(MULTI_SEND, packed);
        console2.log("SAFE_TX_TO", MULTISEND_141);
        console2.log("SAFE_TX_OPERATION 1");
        console2.log("SAFE_TX_NONCE_OF_ACCOUNT", uint256(nonce));
        console2.log("SAFE_TX_DATA_BYTES", data.length);
        console2.log(string.concat("SAFE_TX_DATA ", vm.toString(data)));
        console2.log("THEN: export MAINNET_SAFE_REGISTRY and MAINNET_SAFE_ORACLE_<SYM> to the addresses above,");
        console2.log("      after checking each has code and governance() == the Safe.");
    }

    /// @notice The creation code batch 1 runs, registry first, then one oracle per asset in table
    ///         order. Public so a test can execute exactly these bytes as the Safe.
    function batch1InitCodes(address attester) public returns (bytes[] memory inits) {
        _freshAssets();
        uint256 n = assets.length;
        inits = new bytes[](n + 1);
        inits[0] = abi.encodePacked(type(SolvencyRegistry).creationCode, abi.encode(attester));
        for (uint256 i = 0; i < n; ++i) {
            address feed = _feedFor(assets[i].symbol);
            require(feed.code.length > 0, string.concat("SafeBatches: no feed for ", assets[i].symbol));
            inits[i + 1] = abi.encodePacked(
                type(CertOracle).creationCode,
                abi.encode(
                    feed,
                    attester,
                    assets[i].priceDecimals,
                    _stalenessSeconds(),
                    DEVIATION_BPS,
                    BASIS_BAND_BPS,
                    POKE_CONFIRMATION_SECONDS,
                    _singleSource(),
                    MAX_MARK_AGE
                )
            );
        }
    }

    /// @dev One MultiSend entry: operation 1 (delegatecall) to CreateCall.performCreate(0, init).
    function _entry(bytes memory packed, bytes memory init) internal pure returns (bytes memory) {
        bytes memory call = abi.encodeWithSelector(PERFORM_CREATE, uint256(0), init);
        return abi.encodePacked(packed, uint8(1), CREATECALL_141, uint256(0), uint256(call.length), call);
    }

    // ============================================================================== phase A

    /// @notice PHASE A, day 0, after the deploy and the bootstrap. Per vault, in this order:
    ///
    ///           registerVault           CertFactory. Starts the 16-day InsuranceStaking
    ///                                   registration clock (H-3) - registeredAt is stamped now.
    ///           setBufferThresholds     immediate; reporting only (M-2).
    ///           setFeeSink(FeeVault)    set-once, immediate.
    ///           setInsurancePool(pool)  set-once, immediate.
    ///           enableKeeperHedging     one-way, immediate. Safe now: absoluteCap18 is 0 until
    ///                                   openMinting, so no mint of either kind can be admitted.
    ///           proposeChange x 3       setSettler(SETTLER), setVenueApiKey(i, key),
    ///                                   setVenueMinimums(base, quote). Starts the 2-day clock.
    ///
    ///         NOT here: setAbsoluteCap. That is openMinting, after phase B, one vault first.
    ///
    ///         Writes `4663.stack5.phaseA.json` (Transaction Builder) and
    ///         `4663.stack5.phaseA-proposals.json`: every proposal's exact calldata and id
    ///         (keccak256 of the calldata, CertVault's key). Phase B applies THOSE bytes.
    function phaseA() external {
        if (block.chainid != MAINNET_CHAIN_ID) revert SafeBatches_WrongChain(block.chainid);
        address safe = _batchSafe();
        _loadStack5Book(safe);

        for (uint256 i = 0; i < assets.length; ++i) {
            _phaseAChecks(i, safe);
            _phaseAImmediate(i);
            _phaseAProposals(i);
        }

        _writeTxBuilder(
            "phaseA",
            "UseCert stack 5 - phase A (day 0)",
            "registerVault, setBufferThresholds, setFeeSink, setInsurancePool, enableKeeperHedging and three proposeChange per vault. Opens no minting.",
            safe
        );
        _writeProposals(safe);
    }

    function _phaseAChecks(uint256 i, address safe) internal view {
        CertVault v = CertVault(bVault[i]);
        string memory sym = assets[i].symbol;
        require(v.governance() == safe, "PHASE A: vault governance is not the Safe");
        if (v.lighterAccountIndex() == 0) revert SafeBatches_NotReady(sym, "not bootstrapped - run usecert-mainnet-bootstrap");
        if (CertFactory(bFactory).isVault(bVault[i])) revert SafeBatches_NotReady(sym, "already registered - phase A ran");
        if (v.feeSink() != address(0)) revert SafeBatches_NotReady(sym, "feeSink already set");
        if (v.insurancePool() != address(0)) revert SafeBatches_NotReady(sym, "insurancePool already set");
        if (v.keeperHedging()) revert SafeBatches_NotReady(sym, "keeper hedging already on");
    }

    function _phaseAImmediate(uint256 i) internal {
        address vault = bVault[i];
        _add(bFactory, abi.encodeCall(CertFactory.registerVault, (vault, bCert[i])));
        _add(
            vault,
            abi.encodeCall(
                CertVault.setBufferThresholds,
                (assets[i].bufferFloor18, assets[i].bufferFeeOn18, assets[i].bufferMintSlow18, 0)
            )
        );
        _add(vault, abi.encodeCall(CertVault.setFeeSink, (bFeeVault)));
        _add(vault, abi.encodeCall(CertVault.setInsurancePool, (bInsurance)));
        _add(vault, abi.encodeCall(CertVault.enableKeeperHedging, ()));
    }

    function _phaseAProposals(uint256 i) internal {
        string memory sym = assets[i].symbol;
        bytes memory pub = _pubKeyOf(sym);
        require(pub.length == 40, "PHASE A: API public key must be 40 bytes");
        uint256 minBase = _minBaseOf(sym);
        uint256 minQuote = _minQuoteOf(sym);
        // The apply will check these at the oracle price of the day it lands; refuse now a proposal
        // that would revert then, rather than find out two days later.
        _requireMinimumsInBounds(i, minBase, minQuote);

        _propose(i, "setSettler", abi.encodeCall(CertVault.setSettler, (bSettler)));
        _propose(i, "setVenueApiKey", abi.encodeCall(CertVault.setVenueApiKey, (_apiKeyIndex(), pub)));
        _propose(i, "setVenueMinimums", abi.encodeCall(CertVault.setVenueMinimums, (minBase, minQuote)));
    }

    /// @dev CertVault.setVenueMinimums' bound (M-7), at the current oracle price. minBase must be
    ///      non-zero: the venue always has a minimum, and openMinting reads a non-zero minBase as the
    ///      proof that phase B landed.
    function _requireMinimumsInBounds(uint256 i, uint256 minBase, uint256 minQuote) internal view {
        string memory sym = assets[i].symbol;
        if (minBase == 0) revert SafeBatches_NotReady(sym, "MINBASE is 0 - read min_base_amount off the venue");
        if (minQuote > VENUE_MIN_NOTIONAL_CEILING_18 || minBase > type(uint48).max) {
            revert SafeBatches_NotReady(sym, "venue minimums out of bounds");
        }
        (uint256 px18,) = CertOracle(address(CertVault(bVault[i]).oracle())).pxUnguarded();
        uint256 notional18 = minBase * (1e18 / (10 ** uint256(assets[i].sizeDecimals))) * px18 / 1e18;
        if (px18 == 0 || notional18 > VENUE_MIN_NOTIONAL_CEILING_18) {
            revert SafeBatches_NotReady(sym, "MINBASE implies more than $1,000 at the oracle price");
        }
    }

    function _propose(uint256 i, string memory setter, bytes memory data) internal {
        _add(bVault[i], abi.encodeCall(CertVault.proposeChange, (data)));
        _pSymbol.push(assets[i].symbol);
        _pSetter.push(setter);
        _pVault.push(bVault[i]);
        _pData.push(data);
    }

    function _writeProposals(address safe) internal {
        string memory out = "{\n";
        out = string.concat(out, _jStr("  ", "_what", "Stack-5 phase-A proposals. Phase B applies exactly these calldata; id = keccak256(data) = CertVault's changeReadyAt key."));
        out = string.concat(out, _jNum("  ", "chainId", block.chainid));
        out = string.concat(out, _jAddr("  ", "safe", safe));
        out = string.concat(out, _jStr("  ", "book", _bookPath()));
        out = string.concat(out, _jNum("  ", "builtAt", block.timestamp));
        out = string.concat(out, _jNum("  ", "governanceDelay", CertVault(bVault[0]).GOVERNANCE_DELAY()));
        out = string.concat(out, _jNum("  ", "count", _pData.length));
        out = string.concat(out, '  "proposals": [\n');
        for (uint256 k = 0; k < _pData.length; ++k) {
            out = string.concat(out, _proposalJson(k), k + 1 == _pData.length ? "\n" : ",\n");
        }
        out = string.concat(out, "  ]\n}\n");
        string memory path = _outPath("phaseA-proposals");
        vm.writeFile(path, out);
        console2.log("proposals ->", path);
    }

    function _proposalJson(uint256 k) internal view returns (string memory) {
        return string.concat(
            '    {"symbol": "', _pSymbol[k], '", "setter": "', _pSetter[k],
            '", "vault": "', vm.toString(_pVault[k]),
            '", "id": "', vm.toString(keccak256(_pData[k])),
            '", "data": "', vm.toString(_pData[k]), '"}'
        );
    }

    // ============================================================================== phase B

    /// @notice PHASE B, day >= 2: the three applies per vault, with the SAME calldata phase A
    ///         proposed, read back from `4663.stack5.phaseA-proposals.json`.
    /// @dev REFUSES unless, for every proposal, `changeReadyAt(keccak256(data))` is non-zero (it
    ///      is on chain: phase A executed and nothing consumed or cancelled it) and not in the
    ///      future (the notice has run). A phase B built early would otherwise be signed, queued,
    ///      and revert CertVault_ChangeNotReady at execution. Also refuses if phase A's immediate
    ///      calls are not on chain.
    function phaseB() external {
        if (block.chainid != MAINNET_CHAIN_ID) revert SafeBatches_WrongChain(block.chainid);
        address safe = _batchSafe();
        _loadStack5Book(safe);
        for (uint256 i = 0; i < assets.length; ++i) {
            _requirePhaseAImmediateOnChain(i);
        }

        string memory rec = vm.readFile(_outPath("phaseA-proposals"));
        require(vm.parseJsonUint(rec, ".chainId") == block.chainid, "PHASE B: proposals file is for another chain");
        require(vm.parseJsonAddress(rec, ".safe") == safe, "PHASE B: proposals file is for another Safe");
        uint256 n = vm.parseJsonUint(rec, ".count");
        require(n == assets.length * 3, "PHASE B: proposals file does not cover every vault");

        for (uint256 k = 0; k < n; ++k) {
            _phaseBOne(rec, k);
        }

        _writeTxBuilder(
            "phaseB",
            "UseCert stack 5 - phase B (day >= 2)",
            "setSettler, setVenueApiKey and setVenueMinimums per vault, applying the phase-A proposals byte for byte. Opens no minting.",
            safe
        );
    }

    function _phaseBOne(string memory rec, uint256 k) internal {
        string memory key = string.concat(".proposals[", vm.toString(k), "]");
        string memory sym = vm.parseJsonString(rec, string.concat(key, ".symbol"));
        string memory setter = vm.parseJsonString(rec, string.concat(key, ".setter"));
        address vault = vm.parseJsonAddress(rec, string.concat(key, ".vault"));
        bytes memory data = vm.parseJsonBytes(rec, string.concat(key, ".data"));
        bytes32 id = vm.parseJsonBytes32(rec, string.concat(key, ".id"));

        require(keccak256(data) == id, "PHASE B: a recorded id is not keccak256 of its calldata");
        require(vault == bVault[_indexOf(sym)], "PHASE B: a recorded vault is not the book's");

        uint256 readyAt = CertVault(vault).changeReadyAt(id);
        if (readyAt == 0) revert SafeBatches_ProposalNotOnChain(sym, setter, id);
        if (readyAt > block.timestamp) revert SafeBatches_PhaseBTooEarly(sym, setter, readyAt, block.timestamp);

        _add(vault, data);
    }

    function _requirePhaseAImmediateOnChain(uint256 i) internal view {
        CertVault v = CertVault(bVault[i]);
        string memory sym = assets[i].symbol;
        if (!CertFactory(bFactory).isVault(bVault[i])) revert SafeBatches_NotReady(sym, "not registered - phase A not executed");
        if (v.feeSink() != bFeeVault) revert SafeBatches_NotReady(sym, "feeSink is not the book's FeeVault");
        if (v.insurancePool() != bInsurance) revert SafeBatches_NotReady(sym, "insurancePool is not the book's InsuranceStaking");
        if (!v.keeperHedging()) revert SafeBatches_NotReady(sym, "keeper hedging off - phase A not executed");
        if (v.lighterAccountIndex() == 0) revert SafeBatches_NotReady(sym, "not bootstrapped");
    }

    // ========================================================================= open minting

    /// @notice setAbsoluteCap for the vaults in OPEN_VAULTS ("uTSLA", "uSPY,uQQQ", or "all").
    ///         This is the ONLY step that lets a vault take money, so it is its own batch: the
    ///         runbook opens ONE vault, proves a small real round trip, and only then opens the
    ///         rest ("prove one before many").
    /// @dev Refuses a vault on which phase B is not visibly applied (settler, venue minimums) or
    ///      phase A's immediate calls are missing, so no vault can be opened that could accept a
    ///      mint nobody can settle. Cap = the asset's reviewed row, or OPEN_CAP18 if lower.
    function openMinting() external {
        if (block.chainid != MAINNET_CHAIN_ID) revert SafeBatches_WrongChain(block.chainid);
        address safe = _batchSafe();
        _loadStack5Book(safe);

        string memory list = _openVaults();
        bool all = keccak256(bytes(list)) == keccak256("all");
        string[] memory syms = vm.split(list, ",");
        string memory tag = all ? "all" : "";
        uint256 count = all ? assets.length : syms.length;

        for (uint256 j = 0; j < count; ++j) {
            uint256 i = all ? j : _indexOf(syms[j]);
            if (!all) tag = string.concat(tag, j == 0 ? "" : "-", assets[i].symbol);
            _requireReadyToOpen(i);
            uint256 cap = _openCapFor(i);
            _add(bCapacity, abi.encodeCall(CapacityOracle.setAbsoluteCap, (bVault[i], cap)));
            console2.log(string.concat("  open ", assets[i].symbol, " cap18"), cap);
        }

        _writeTxBuilder(
            string.concat("open-", tag),
            string.concat("UseCert stack 5 - open minting: ", tag),
            "CapacityOracle.setAbsoluteCap for the listed vaults. This is what lets them take deposits.",
            safe
        );
    }

    function _requireReadyToOpen(uint256 i) internal view {
        _requirePhaseAImmediateOnChain(i);
        CertVault v = CertVault(bVault[i]);
        string memory sym = assets[i].symbol;
        if (v.settler() != bSettler) revert SafeBatches_NotReady(sym, "settler not applied - phase B not executed");
        if (v.venueMinBase() == 0) revert SafeBatches_NotReady(sym, "venue minimums not applied - phase B not executed");
        if (v.retired()) revert SafeBatches_NotReady(sym, "vault is retired");
    }

    function _openCapFor(uint256 i) internal view returns (uint256 cap) {
        uint256 row = _maxAbsoluteCapOf(assets[i].symbol);
        cap = assets[i].absoluteCap18;
        uint256 lower = _openCap18();
        if (lower != 0) {
            require(lower <= cap, "OPEN: OPEN_CAP18 above the asset's reviewed cap - it may only lower it");
            cap = lower;
        }
        require(cap != 0, "OPEN: zero cap opens nothing");
        require(cap <= row, "OPEN: cap above the asset's reviewed M-8 row");
        require(cap <= CapacityOracle(bCapacity).maxAbsoluteCap(), "OPEN: cap above the deployed ceiling");
    }

    // ======================================================================= stack-4 wind-down

    /// @notice After stack 5 is live: retire() every EMPTY stack-4 vault and sweepRetired() its
    ///         capital to the Safe. Reads stack 4's book (`deployments/4663.json`, or the history
    ///         copy it was moved to at cutover).
    /// @dev retire() refuses unless no certificate, open mint receipt, owed redemption or hedge
    ///      position exists, and so does this builder, so a batch that would revert is never
    ///      queued. sweepRetired(VENUE_AMOUNT_<SYM>) requests that much back from the venue as well
    ///      (the venue balance as read off the venue; default 0 sweeps only what the vault holds);
    ///      a venue withdrawal lands in the vault, so run it again with 0 once it has arrived.
    function retireStack4() external {
        if (block.chainid != MAINNET_CHAIN_ID) revert SafeBatches_WrongChain(block.chainid);
        address safe = _batchSafe();
        string memory book = vm.readFile(_stack4BookPath());
        require(!vm.keyExistsJson(book, ".stack"), "RETIRE: that book is stack 5 or later - point at stack 4's");
        require(vm.parseJsonUint(book, ".chainId") == block.chainid, "RETIRE: book is for another chain");
        require(vm.parseJsonAddress(book, ".senders.governance") == safe, "RETIRE: book's governance is not the Safe");

        for (uint256 i = 0; vm.keyExistsJson(book, string.concat(".vaults[", vm.toString(i), "]")); ++i) {
            string memory k = string.concat(".vaults[", vm.toString(i), "]");
            string memory sym = vm.parseJsonString(book, string.concat(k, ".symbol"));
            address vault = vm.parseJsonAddress(book, string.concat(k, ".vault"));
            _retireOne(sym, vault, safe);
        }

        _writeTxBuilder(
            "retire-stack4",
            "UseCert stack 4 - retire and sweep",
            "retire() and sweepRetired() on every empty stack-4 vault. Capital returns to the Safe.",
            safe
        );
    }

    function _retireOne(string memory sym, address vault, address safe) internal {
        CertVault v = CertVault(vault);
        require(v.governance() == safe, "RETIRE: vault governance is not the Safe");
        if (!v.retired()) {
            if (
                Certificate(address(v.certificate())).totalSupply() != 0 || v.openMintReceipts() != 0
                    || v.totalOwedOutstanding() != 0 || v.venuePositionBase() != 0
            ) revert SafeBatches_NotReady(sym, "not empty - holders, receipts, claims or a position remain");
            _add(vault, abi.encodeCall(CertVault.retire, ()));
        }
        _add(vault, abi.encodeCall(CertVault.sweepRetired, (_venueAmountOf(sym))));
    }

    // =============================================================================== shared

    /// @dev Reads the stack-5 book and checks it against the asset table and the Safe.
    function _loadStack5Book(address safe) internal {
        require(safe.code.length > 0, "SafeBatches: the Safe has no code on this chain");
        _freshAssets();
        string memory book = vm.readFile(_bookPath());
        require(
            vm.keyExistsJson(book, ".stack") && vm.parseJsonUint(book, ".stack") == 5,
            "SafeBatches: the book is not a stack-5 book"
        );
        require(vm.parseJsonUint(book, ".chainId") == block.chainid, "SafeBatches: the book is for another chain");
        require(vm.parseJsonAddress(book, ".senders.governance") == safe, "SafeBatches: the book's governance is not the Safe");
        bFactory = vm.parseJsonAddress(book, ".shared.certFactory");
        bCapacity = vm.parseJsonAddress(book, ".shared.capacityOracle");
        bFeeVault = vm.parseJsonAddress(book, ".shared.feeVault");
        bInsurance = vm.parseJsonAddress(book, ".shared.insuranceStaking");
        bSettler = vm.parseJsonAddress(book, ".shared.settler");
        require(bSettler != address(0), "SafeBatches: the book records no settler");
        delete bVault;
        delete bCert;
        for (uint256 i = 0; i < assets.length; ++i) {
            string memory k = string.concat(".vaults[", vm.toString(i), "]");
            require(
                keccak256(bytes(vm.parseJsonString(book, string.concat(k, ".symbol")))) == keccak256(bytes(assets[i].symbol)),
                "SafeBatches: book and asset table disagree on order"
            );
            bVault.push(vm.parseJsonAddress(book, string.concat(k, ".vault")));
            bCert.push(vm.parseJsonAddress(book, string.concat(k, ".certificate")));
        }
        require(
            !vm.keyExistsJson(book, string.concat(".vaults[", vm.toString(assets.length), "]")),
            "SafeBatches: the book has more vaults than the asset table (MAINNET_ONLY mismatch?)"
        );
    }

    function _freshAssets() internal {
        delete assets;
        _loadAssets();
    }

    function _indexOf(string memory sym) internal view returns (uint256) {
        for (uint256 i = 0; i < assets.length; ++i) {
            if (keccak256(bytes(assets[i].symbol)) == keccak256(bytes(sym))) return i;
        }
        revert SafeBatches_NotReady(sym, "no such asset in the table");
    }

    function _add(address to, bytes memory data) internal {
        _txTo.push(to);
        _txData.push(data);
    }

    /// @dev The Safe Transaction Builder's import format (Safe app -> Apps -> Transaction Builder
    ///      -> drag and drop). Raw calldata, no ABI: `contractMethod` null. Also writes the same calls
    ///      as one MultiSendCallOnly 1.4.1 delegatecall (`<name>.multisend.json`: to, operation, data)
    ///      for usecert-safe-propose, which takes the data as a hex file: `jq -r .data`.
    function _writeTxBuilder(string memory name, string memory title, string memory description, address safe)
        internal
    {
        string memory out = string.concat(
            '{\n  "version": "1.0",\n  "chainId": "', vm.toString(block.chainid),
            '",\n  "createdAt": ', vm.toString(block.timestamp * 1000),
            ',\n  "meta": {\n    "name": "', title,
            '",\n    "description": "', description
        );
        out = string.concat(
            out,
            '",\n    "txBuilderVersion": "1.16.5",\n    "createdFromSafeAddress": "', vm.toString(safe),
            '",\n    "createdFromOwnerAddress": ""\n  },\n  "transactions": [\n'
        );
        bytes memory packed;
        for (uint256 k = 0; k < _txTo.length; ++k) {
            out = string.concat(
                out,
                '    {"to": "', vm.toString(_txTo[k]), '", "value": "0", "data": "', vm.toString(_txData[k]),
                '", "contractMethod": null, "contractInputsValues": null}',
                k + 1 == _txTo.length ? "\n" : ",\n"
            );
            packed = abi.encodePacked(packed, uint8(0), _txTo[k], uint256(0), uint256(_txData[k].length), _txData[k]);
        }
        out = string.concat(out, "  ]\n}\n");
        string memory path = _outPath(name);
        vm.writeFile(path, out);

        bytes memory data = abi.encodeWithSelector(MULTI_SEND, packed);
        string memory side = _outPath(string.concat(name, ".multisend"));
        vm.writeFile(
            side,
            string.concat(
                '{"to": "', vm.toString(MULTISEND_CALLONLY_141), '", "operation": 1, "calls": ', vm.toString(_txTo.length),
                ', "data": "', vm.toString(data), '"}\n'
            )
        );
        console2.log(string.concat("Transaction Builder file (", vm.toString(_txTo.length), " calls) ->"), path);
        console2.log("MultiSendCallOnly payload (to, operation 1, data) ->", side);
        console2.log("SAFE_TX_TO", MULTISEND_CALLONLY_141);
        console2.log("SAFE_TX_OPERATION 1");
        console2.log("SAFE_TX_CALLS", _txTo.length);
    }

    // ---------------------------------------------------------------- accessors, for tests

    function builtCount() external view returns (uint256) {
        return _txTo.length;
    }

    function builtAt(uint256 k) external view returns (address to, bytes memory data) {
        return (_txTo[k], _txData[k]);
    }
}
