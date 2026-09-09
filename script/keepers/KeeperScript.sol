// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title  Shared base for the testnet keepers: the address book, and the sender discipline.
///
/// @notice THE KEEPERS TAKE NO ADDRESSES AS ARGUMENTS. Every address comes from
///         `deployments/<chainId>.json`, which `script/DeployTestnet.s.sol` generates and which
///         carries the loud "NEVER HAND-EDIT" warning at its top. That is not a convenience: each
///         redeployment produces a NEW vault and a NEW certificate token, so a keeper invoked with
///         a hand-typed vault address is one copy-paste away from attesting the previous
///         deployment's vault — a stream of perfectly valid attestations against an asset key
///         nothing is minting, while the live vault starves. Reading the book means the keeper and
///         the deployment cannot disagree without the book itself being wrong, and
///         `script/VerifyTestnet.s.sol` checks the book against the chain.
///
/// @dev    A FOUNDRY SCRIPT RUNS ONCE AND EXITS. Neither keeper loops on wall-clock time and
///         neither is a daemon; "on an interval" means an EXTERNAL loop re-invokes the script —
///         cron, a systemd timer, or a shell `while`. See `docs/TESTNET-RUNBOOK.md` for the
///         intervals and the loops. `script/FeedKeeper.s.sol` (Task 9) already establishes this
///         shape and says the same thing in its own NatSpec.
///
/// @dev    THE ONE THING THE ADDRESS BOOK DOES NOT PROVE. `vm.readFile`/`vm.parseJson` read a local
///         file. A book generated against one deployment and left in the tree while a second
///         deployment happened elsewhere parses perfectly and points at dead contracts. Both
///         keepers therefore preflight the specific on-chain fact they depend on — the batch
///         advancer checks `LighterSim.keeper()`, the attester checks `SolvencyRegistry.attester()`
///         and each `CertOracle.attester()` — and abort with a named reason rather than sending a
///         transaction that reverts with a bare selector at 3am.
abstract contract KeeperScript is Script {
    /// @dev One mirror as the keepers need it. A subset of the book's per-vault record: the fields
    ///      a keeper acts on, not everything the front-end adapter reads.
    struct Mirror {
        string symbol;
        address vault;
        address certOracle;
        address replayAggregator;
        uint16 marketIndex;
        /// @dev The deployment's attested open interest. See `Attester._openInterest18` for why
        ///      this is carried forward from the book rather than read off the simulator.
        uint256 seedOpenInterest18;
    }

    /// @dev The shared addresses and senders a keeper needs, plus the mirrors.
    struct Book {
        uint256 chainId;
        address attester;
        address batchKeeper;
        address lighterSim;
        address solvencyRegistry;
        address capacityOracle;
        Mirror[] mirrors;
    }

    /// @dev Where the address book lives. `ADDRESS_BOOK` overrides it — used by the tests, and by
    ///      an operator running a keeper from outside the repo root. Default matches exactly what
    ///      `DeployTestnet._writeAddressBook()` writes, keyed on the chain the keeper is pointed at,
    ///      so a keeper aimed at the wrong RPC fails to find a book rather than driving the wrong
    ///      chain's addresses.
    function _bookPath() internal view virtual returns (string memory) {
        return vm.envOr("ADDRESS_BOOK", string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }

    /// @dev THE INJECTION SEAM, and it is the file read that is behind it rather than the parse.
    ///
    ///      Same reasoning as `DeployTestnet._collateralAddress()`: a test overrides this by
    ///      SUBCLASSING rather than by mutating the process environment. `vm.setEnv` writes
    ///      process-global state Foundry does not roll back between test cases, and Foundry runs
    ///      test contracts in parallel, so an env-mutating test corrupts its neighbours.
    ///
    ///      It is the FILE READ and not `_book()` that is virtual, deliberately, so a test that
    ///      supplies its own book still runs the real parser — every `parseJson` path, every
    ///      length check below — rather than skipping straight to a hand-built struct. And it is
    ///      why the keeper tests do not run `DeployTestnet.run()`: that writes
    ///      `deployments/46630.json` unconditionally, `test/script/DeployTestnet.t.sol` reads that
    ///      exact path back and asserts its own addresses are in it, and a second suite writing it
    ///      in parallel would make that test fail intermittently. The live chain run in
    ///      `docs/TESTNET-RUNBOOK.md` is what exercises the real file.
    function _bookJson() internal view virtual returns (string memory) {
        return vm.readFile(_bookPath());
    }

    /// @dev Parses the address book. Never overridden by a test — see `_bookJson()`.
    function _book() internal view returns (Book memory book) {
        string memory json = _bookJson();

        book.chainId = vm.parseJsonUint(json, ".chainId");
        book.attester = vm.parseJsonAddress(json, ".senders.attester");
        book.batchKeeper = vm.parseJsonAddress(json, ".shared.batchKeeper");
        book.lighterSim = vm.parseJsonAddress(json, ".shared.lighterSim");
        book.solvencyRegistry = vm.parseJsonAddress(json, ".shared.solvencyRegistry");
        book.capacityOracle = vm.parseJsonAddress(json, ".shared.capacityOracle");

        // MIRRORS ARE COUNTED BY PROBING `.vaults[i]`, NOT BY READING A COLUMN WITH `[*]`.
        //
        // `vm.parseJsonAddressArray(json, ".vaults[*].vault")` looked like the obvious way to get
        // both the count and the column in one call, and it is WRONG IN THE SINGLE-MIRROR CASE:
        // Foundry's jsonpath collapses a one-element match to a scalar, so the array parse fails
        // with `expected [`. The deployed configuration has two mirrors, so this would have worked
        // in every test and then broken the day someone deployed a single mirror — a keeper that
        // cannot start against a perfectly valid book. Found by running it, not by reading about it.
        //
        // `keyExistsJson` probes instead. Bounded by MAX_MIRRORS so a malformed book cannot spin.
        uint256 n;
        while (n < MAX_MIRRORS && vm.keyExistsJson(json, _vaultKey(n, "vault"))) {
            ++n;
        }
        require(n != 0, "ADDRESS BOOK: no vaults - re-run script/DeployTestnet.s.sol");
        require(
            !vm.keyExistsJson(json, _vaultKey(n, "vault")),
            "ADDRESS BOOK: more than MAX_MIRRORS vaults - raise the bound rather than truncating the keeper's work"
        );

        book.mirrors = new Mirror[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 market = vm.parseJsonUint(json, _vaultKey(i, "marketIndex"));
            require(market <= type(uint16).max, "ADDRESS BOOK: marketIndex does not fit uint16");
            book.mirrors[i] = Mirror({
                symbol: vm.parseJsonString(json, _vaultKey(i, "symbol")),
                vault: vm.parseJsonAddress(json, _vaultKey(i, "vault")),
                certOracle: vm.parseJsonAddress(json, _vaultKey(i, "certOracle")),
                replayAggregator: vm.parseJsonAddress(json, _vaultKey(i, "replayAggregator")),
                marketIndex: uint16(market),
                // Quoted in the book, not a JSON number: the open-interest figures exceed 2^53 and
                // would lose precision in any JavaScript consumer that parsed them as numbers.
                // Parsed out of the string here for the same reason `DeployTestnet` wrote it as one.
                seedOpenInterest18: vm.parseUint(vm.parseJsonString(json, _vaultKey(i, "seedOpenInterest18")))
            });
        }
    }

    /// @dev The bound on the probe above. Far above the two mirrors `script/DeployTestnet.s.sol`
    ///      deploys and above anything `docs/TESTNET-PLAN.md` §6 contemplates; it exists so a
    ///      truncated or malformed book cannot make the loop run away, and exceeding it is an
    ///      explicit error rather than a silent truncation.
    uint256 internal constant MAX_MIRRORS = 64;

    function _vaultKey(uint256 i, string memory field) private pure returns (string memory) {
        return string.concat(".vaults[", vm.toString(i), "].", field);
    }

    /// @dev The key this keeper signs with, named by the subclass's own env var.
    ///
    ///      A SEAM FOR THE SAME REASON `DeployTestnet._senderKeys()` IS ONE, and this time it is
    ///      not a precaution. `vm.setEnv` was tried first and measured: a `setEnv` inside a test
    ///      function is NOT rolled back when Foundry reverts to the post-`setUp` snapshot, and a
    ///      restore written at the end of that test does not reliably take effect for the next one.
    ///      A test that exercises the wrong-key branch therefore corrupts every test after it, and
    ///      across suites it races. So the tests override this and never touch the environment.
    ///      Production behaviour is unchanged — the default is the env read.
    ///
    ///      THE SCRIPTS NEVER HARDCODE, LOG OR DERIVE A KEY. The operator owns them; a keeper only
    ///      ever asks the environment, and only ever for its own one key. Neither keeper can send a
    ///      transaction the other's key would authorise.
    function _signerKey() internal view virtual returns (uint256);

    /// @dev The book must belong to the chain the keeper is actually pointed at. A book from
    ///      another chain parses perfectly and every address in it is dead code on this one; the
    ///      symptom would be reverts with no obvious cause. Checked before anything is sent.
    function _requireBookMatchesChain(Book memory book) internal view {
        require(book.chainId == block.chainid, "ADDRESS BOOK: chainId != the chain this RPC is on");
        require(book.lighterSim.code.length > 0, "ADDRESS BOOK: lighterSim has no code on this chain");
    }

    /// @dev One line per mirror, so an operator tailing a cron log can see the keeper doing
    ///      something rather than merely exiting 0.
    function _logMirror(Mirror memory m, string memory what, uint256 value) internal pure {
        console2.log(string.concat("  ", m.symbol, " ", what), value);
    }
}
