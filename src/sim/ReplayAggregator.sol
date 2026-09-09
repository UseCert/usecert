// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @notice A deployable, owner-gated Chainlink-shaped aggregator for testnets where Chainlink is
///         absent. Verified live on 2026-09-09: Robinhood Chain testnet (chain id 46630) returns
///         empty code (`0x`) on all six known mainnet feed proxies, so a deployment there must
///         bring its own price source per asset. This is that source.
/// @dev Global Constraint 4: `src/sim/` is the deliberate exception to Design Law 6 (no owner, no
///      keeper, no pause in the protocol). This contract stands in for a third party (the venue's
///      own price feed), not for UseCert, so it is allowed — required — to be access-controlled.
///      It is disposable testnet scaffolding, never deployed against real collateral.
///
///      `MockAggregatorV3` (test/mocks/MockAggregatorV3.sol) is this contract's test-only sibling:
///      same `IAggregatorV3` surface, same failure shapes. This one differs from it in exactly the
///      ways production scaffolding must: an immutable owner gates every write, every write emits
///      an event, and `roundId` is a real incrementing Chainlink round counter rather than a fixed
///      `1` — because `CertOracle.pokeLastGood()` treats a strictly increasing `roundId` as proof
///      that the feed independently re-reported a price, not that a test re-read the same round.
///      Do not modify `MockAggregatorV3`; it belongs to another concurrent task.
contract ReplayAggregator is IAggregatorV3 {
    error ReplayAggregator_OnlyOwner();
    error ReplayAggregator_ZeroOwner();
    error ReplayAggregator_LengthMismatch();
    error ReplayAggregator_EmptyBatch();

    /// @dev Emitted on every write that advances a round, `pushFrozen()` included — `roundId` is
    ///      the load-bearing field: it must be visibly incrementing on-chain for every push, not
    ///      only for the ones that changed `answer`.
    event RoundPushed(uint80 indexed roundId, int256 answer, uint256 startedAt, uint256 updatedAt);
    event DecimalsSet(uint8 decimals);
    event DescriptionSet(string description);

    /// @notice The only address permitted to write a new round. Immutable — no transfer, no
    ///         second key, matching the brief's "immutable owner set at construction".
    address public immutable owner;

    uint8 private _decimals;
    string private _description;

    uint80 private _roundId;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;

    modifier onlyOwner() {
        if (msg.sender != owner) revert ReplayAggregator_OnlyOwner();
        _;
    }

    /// @param owner_ Immutable write authority. Never address(0).
    /// @param decimals_ Reported decimals; the real Robinhood Chain feeds report 8 (verified live,
    ///        e.g. the TSLA feed at 0x4A1166a659A55625345e9515b32adECea5547C38: decimals() = 8).
    ///        Left settable post-deploy (setDecimals) so a test can reproduce the "absurd
    ///        decimals()" pathological state `CertOracle._tryFeed` guards against.
    /// @param description_ Matches the real feeds' e.g. "RHTSLA / USD" shape.
    /// @param initialAnswer The first round's answer, in `decimals_` units. Round 1 is written by
    ///        the constructor itself so `roundId` starts at a real value, not zero.
    constructor(address owner_, uint8 decimals_, string memory description_, int256 initialAnswer) {
        if (owner_ == address(0)) revert ReplayAggregator_ZeroOwner();
        owner = owner_;
        _decimals = decimals_;
        _description = description_;
        _writeRound(initialAnswer, block.timestamp);
    }

    // ---------------------------------------------------------------------
    // IAggregatorV3
    // ---------------------------------------------------------------------

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _roundId);
    }

    // ---------------------------------------------------------------------
    // Chainlink-shaped extras (not part of IAggregatorV3, but present on every real feed and
    // read by tooling/dashboards that expect the full AggregatorV3Interface shape).
    // ---------------------------------------------------------------------

    /// @notice Human-readable feed name, e.g. "RHTSLA / USD". Owner-settable so a deploy script
    ///         can label a freshly constructed feed without redeploying.
    function description() external view returns (string memory) {
        return _description;
    }

    /// @notice Fixed at 6, matching every Robinhood Chain feed probed live on 2026-09-09.
    function version() external pure returns (uint256) {
        return 6;
    }

    // ---------------------------------------------------------------------
    // Owner-gated writes
    // ---------------------------------------------------------------------

    /// @notice Push a new round at the current block time. The common case: a keeper relaying a
    ///         live price.
    function push(int256 answer_) external onlyOwner {
        _writeRound(answer_, block.timestamp);
    }

    /// @notice Replay a recorded price path: one round per (answer, timestamp) pair, in order.
    ///         Each element is its own round — `roundId` increments once per element, exactly as
    ///         it would have on the real feed as that history was reported live.
    /// @dev Owner-only. Lets a test or a testnet replay run drive `CertOracle`'s guards along a
    ///      real historical path instead of a synthetic one.
    function pushRounds(int256[] calldata answers, uint256[] calldata timestamps) external onlyOwner {
        uint256 n = answers.length;
        if (n == 0) revert ReplayAggregator_EmptyBatch();
        if (n != timestamps.length) revert ReplayAggregator_LengthMismatch();
        for (uint256 i = 0; i < n; i++) {
            _writeRound(answers[i], timestamps[i]);
        }
    }

    /// @notice Reproduce Robinhood's corporate-action pause: the venue freezes the price while
    ///         time keeps advancing. `answer` is carried over unchanged; `roundId` and
    ///         `updatedAt` still advance, because the feed is still alive and still reporting —
    ///         it is just reporting the same number. This is a genuinely different state from
    ///         staleness (where nothing gets reported at all) and `CertOracle` must be able to
    ///         tell them apart, so both must be independently reproducible here.
    function pushFrozen() external onlyOwner {
        _writeRound(_answer, block.timestamp);
    }

    /// @notice Same as `pushFrozen()` but with an explicit `updatedAt`, so a test can place the
    ///         frozen round's timestamp precisely (e.g. in the future, to compose the frozen
    ///         state with the future-timestamp state) rather than only at `block.timestamp`.
    function pushFrozenAt(uint256 updatedAt_) external onlyOwner {
        _writeRound(_answer, updatedAt_);
    }

    /// @notice Flip reported decimals(), e.g. to an absurd value CertOracle._tryFeed must reject
    ///         (it caps usable decimals at 36). Does not itself advance a round — decimals() is
    ///         read independently of latestRoundData() by CertOracle, exactly as on a real feed.
    function setDecimals(uint8 decimals_) external onlyOwner {
        _decimals = decimals_;
        emit DecimalsSet(decimals_);
    }

    function setDescription(string calldata description_) external onlyOwner {
        _description = description_;
        emit DescriptionSet(description_);
    }

    function _writeRound(int256 answer_, uint256 updatedAt_) internal {
        // Strictly increasing on every write, price-changing or not — this is the property Task
        // 1's distinctness proof and CertOracle.pokeLastGood()'s roundId > pendingRoundId check
        // both depend on. Chainlink's own startedAt/updatedAt pair collapses to the same value
        // for a simple feed (see MockAggregatorV3's shape); matched here rather than invented.
        _roundId += 1;
        _answer = answer_;
        _startedAt = updatedAt_;
        _updatedAt = updatedAt_;
        emit RoundPushed(_roundId, answer_, updatedAt_, updatedAt_);
    }
}
