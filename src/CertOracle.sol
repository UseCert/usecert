// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {ICertOracle} from "./interfaces/ICertOracle.sol";
import {ECDSA} from "openzeppelin-contracts/utils/cryptography/ECDSA.sol";

/// @notice Price source for one asset. Chainlink is the holder-facing price; the Lighter mark
///         price is a cross-check. Guard breaches pause MINTING only — pxUnguarded() always
///         answers so redemption can never be trapped (Law 2).
contract CertOracle is ICertOracle {
    error CertOracle_StalePrice();
    error CertOracle_NonPositivePrice();
    /// @dev The signed mark-price path. See setMarkPriceSigned.
    error CertOracle_SignatureExpired();
    error CertOracle_BadSignature();
    error CertOracle_StaleNonce();
    error CertOracle_TickOverflow();
    error CertOracle_OnlyAttester();
    /// @dev H-1: the deviation reference is rate-limited. An out-of-band price has been observed
    ///      but has not yet held for a full `pokeConfirmationSeconds`, so the reference may not
    ///      advance onto it yet. The remedy is to wait: poke again once the window has elapsed.
    error CertOracle_ReferenceRateLimited();
    /// @dev H-1 / Task 1: the confirmation window HAS elapsed, but the feed is still reporting the
    ///      same round that armed the candidate, so nothing has independently re-reported the
    ///      dislocation. Distinct from CertOracle_ReferenceRateLimited on purpose: the two have
    ///      different remedies and a caller must be able to tell "wait longer" from "the feed has
    ///      not spoken again". Sharing one error would make a dead feed look like a young one.
    error CertOracle_ReferenceRoundNotAdvanced();
    /// @dev Task 1: a constructor parameter outside its permitted range. Currently only
    ///      `pokeConfirmationSeconds == 0`, at which the `roundId` proof is the only remaining
    ///      gate — and that proof bounds round DISTINCTNESS, not RATE. Zero does NOT let an arm
    ///      and its confirmation land in the same block (that is refused at every window value);
    ///      it degrades the rate limit to one clamped step per block that carries a new feed
    ///      round, which is a rate limit in name only. The measured behaviour is on the
    ///      constructor's check.
    error CertOracle_ConfigOutOfBounds();
    /// @dev M-5: only the rotation authority bound at deploy may propose a new attester.
    error CertOracle_OnlyGovernance();
    /// @dev L-3, and M-5's hard floor: an attester of address(0) would freeze markPx18 and
    ///      CertVault.accrueFunding forever. Never constructible, never installable.
    error CertOracle_ZeroAddress();
    error CertOracle_NoPendingAttester();
    error CertOracle_RotationNotDue();
    /// @dev Task 2: `basisBps()` was asked for a basis on a deployment that has no independent
    ///      second source. There is no number to return. Returning zero is what the old code did
    ///      and it is precisely the defect: zero is also what a PERFECTLY TRACKING mark returns,
    ///      so "no basis exists" was indistinguishable from "the basis is healthy". Callers that
    ///      only want the bit rather than the revert use `basisBpsChecked()`, which reports
    ///      `known == false` here and never reverts.
    ///      NOT a Law 2 concern: no src/ contract reads `basisBps()` (verified — the only src/
    ///      consumer of this oracle is CertVault, which calls px(), pxUnguarded(), mintAllowed()
    ///      and toTickPrice(), and never the basis), so no redemption path can reach this revert.
    error CertOracle_NoIndependentBasis();
    /// @dev Task 2: a single-source deployment configured with a deviation tolerance wider than
    ///      MAX_SINGLE_SOURCE_DEVIATION_BPS. Refused at construction — see that constant.
    error CertOracle_DeviationTooWideForSingleSource();
    /// @dev Task 3: the feed reports more decimals than normalisation can represent. `_tryFeed`
    ///      has bounded `decimals()` at 36 since Finding 2 and treats anything above as an
    ///      unusable feed; `_readFeed`, which `px()` and the constructor use, did NOT, so a feed
    ///      reporting `decimals() >= 96` overflowed `10 ** (d - 18)` and killed both mint paths
    ///      with an anonymous panic (0x11) instead of an error a caller can switch on. Same bound,
    ///      copied deliberately rather than re-derived; the asymmetry was recorded in
    ///      docs/DEPLOYMENT-CHECKLIST.md §2 and this closes it.
    error CertOracle_FeedDecimalsOutOfRange();
    /// @dev Task 13: the `d > 36` bound above closes the EXPONENT half of the asymmetry with
    ///      `_tryFeed` (Task 3) — the PRODUCT half was still open. For `d <= 18`,
    ///      `uint256(answer) * (10 ** (18 - d))` can overflow uint256 on its own: at `d = 0` the
    ///      multiplier is 1e18 and any answer above ~1.1579e59 panics (0x11), anonymously, inside
    ///      both mint paths (`px()` and the constructor, which reads through `_readFeed` too).
    ///      `_tryFeed` has guarded exactly this product since the CRITICAL B re-audit
    ///      (`:376-379`); `_readFeed` never did. A NEW error, not a reuse of
    ///      `CertOracle_FeedDecimalsOutOfRange`: the two conditions are disjoint (`d > 36` versus
    ///      `d <= 18` with an unrepresentable answer) and a caller must be able to tell "the
    ///      feed's scale is absurd" from "the feed's print cannot be normalised at its own scale".
    error CertOracle_AnswerNotNormalisable();

    /// @dev M-5 (Law 3): a rotation is a public commitment with a published effective time.
    event AttesterRotationProposed(address indexed attester, uint256 effectiveAt);
    event AttesterRotated(address indexed previous, address indexed attester);

    /// @notice The immutable notice period every attester rotation must serve.
    /// @dev M-5. The full argument for why the ceiling bounds SPEED rather than magnitude, and why
    ///      it is a constant rather than a per-deployment immutable, lives on
    ///      SolvencyRegistry.ATTESTER_ROTATION_DELAY. It applies unchanged here, with one addition
    ///      specific to this contract: the powers this attester holds are markPx18 (which feeds
    ///      mintAllowed()'s basis band, so it can pause minting or unpause it, and which no
    ///      redemption path reads) and, via CertVault.accrueFunding, the BufferBook ledger (which
    ///      sits under a `min` since M-1 and can therefore only tighten capacity). pxUnguarded()
    ///      — Law 2's price — is not attester-writable at all and is not affected by a rotation.
    uint256 public constant ATTESTER_ROTATION_DELAY = 2 days;

    /// @notice The widest `deviationBps` a SINGLE-SOURCE deployment may be constructed with: 200
    ///         bps (2%).
    /// @dev Task 2. In dual-source mode three guards stand in front of minting — staleness, the
    ///      basis band, and the deviation clamp — and the band is the only one of the three that
    ///      compares two independently sourced numbers, i.e. the only one that checks whether the
    ///      price is TRUE. In single-source mode that guard is gone by construction, so the
    ///      deviation clamp is the ONLY remaining defence, and a deviation clamp is a rate limit:
    ///      it bounds how fast the accepted price may move, never whether the price is right. A
    ///      rate limit standing alone must therefore be a tight one, because its width is now the
    ///      entire per-window budget an attacker gets for free.
    ///
    ///      Why 200. The measured feed-vs-mark basis across 13 live markets was 11.3-49.3 bps, so
    ///      2% is roughly 4x the widest honest dislocation observed and does not fire on ordinary
    ///      venue noise, while a single window concedes far less than the capacity of the thin
    ///      markets this mode exists for (ANTHROPIC: ~$486k of capacity against $4.88M of open
    ///      interest, so the mark is movable and the clamp width is the attacker's budget, not a
    ///      theoretical bound).
    ///
    ///      Why a constant and not an immutable. A per-deployment knob here would be set by the
    ///      same judgement that chose to deploy against an unfeeded market in the first place, and
    ///      the point of this bound is to constrain that judgement rather than defer to it. It is
    ///      deliberately not configurable: a deployment that wants a wider clamp must find a
    ///      second price source instead.
    uint256 public constant MAX_SINGLE_SOURCE_DEVIATION_BPS = 200;

    IAggregatorV3 public immutable feed;
    /// @notice The rotation authority. Immutable, bound to the deployer at construction.
    /// @dev M-5: msg.sender rather than a constructor parameter, matching SolvencyRegistry so the
    ///      two attested-data contracts bind the same role the same way and one deployment rule
    ///      covers both. DEPLOYMENT REQUIREMENT (docs/DEPLOYMENT-CHECKLIST.md): deploy this
    ///      DIRECTLY FROM the governance multisig. An explicit parameter is the C2 cleanup; see
    ///      SolvencyRegistry.governance for why the arity is frozen in this pass.
    address public immutable governance;
    /// @notice Who may write markPx18 and relay the buffer accrual. No longer immutable.
    address public attester;
    /// @notice The proposed next attester and the timestamp from which it may be installed.
    /// @dev Zero means none pending. Re-proposing overwrites and restarts the notice period;
    ///      proposing the incumbent is how a rotation is abandoned.
    address public pendingAttester;
    uint256 public pendingAttesterAt;
    /// @dev market price_decimals; 2 for TSLA and NVDA
    uint8 public immutable priceDecimals;
    uint256 public immutable stalenessSeconds;
    /// @dev max |chainlink - lastGood| in bps before minting pauses
    uint256 public immutable deviationBps;
    /// @dev max |mark - chainlink| in bps before minting pauses
    uint256 public immutable basisBandBps;
    /// @notice How long an out-of-band observation must hold before the deviation reference may
    ///         take one clamped step onto it.
    /// @dev Task 1: the breaker's rate limit, and DELIBERATELY NOT `stalenessSeconds`. See
    ///      pokeLastGood for the full argument. Never zero (CertOracle_ConfigOutOfBounds).
    uint256 public immutable pokeConfirmationSeconds;
    /// @notice True when this deployment declares that `feed` and the venue mark are NOT
    ///         independent price sources — the market has no Chainlink feed and the venue's own
    ///         mark is, directly or through a venue-sourced adapter, the only price available.
    /// @dev Task 2. 28 of the venue's 57 perp markets have no Chainlink feed at all — 20.5% of
    ///      open interest, including XAU (gold, $12.5M OI, the largest single gap), XAG,
    ///      ANTHROPIC ($4.88M OI on $19.3M daily volume), OPENAI and SHEIN. Those markets are in
    ///      scope, so a vault will eventually be deployed where `feed` is venue-derived.
    ///
    ///      Before this flag existed such a deployment failed SILENTLY, which is the whole finding:
    ///        * `basisBpsChecked()` returned `known = true, bps = 0` — it ASSERTED a healthy basis
    ///          it had never computed, because feed and mark were the same number.
    ///        * Two of mintAllowed()'s three guards degenerated for the same reason: the basis
    ///          band compared a number with itself and always passed.
    ///        * Only the deviation clamp survived, and that is a rate limit, not a truth check.
    ///      Nothing in the contracts, the suite or the deployment checklist would have flagged it.
    ///      Moving the venue mark moves a venue-sourced feed and `markPx18` TOGETHER, holding the
    ///      basis at zero, so the degenerate band is not a theoretical concern: it reads healthiest
    ///      exactly while it is being defeated.
    ///
    ///      The flag does not make single-source safe. It makes it HONEST: the basis is reported
    ///      absent rather than zero, the band is dropped rather than pretended, and the one
    ///      remaining guard is bounded at construction (MAX_SINGLE_SOURCE_DEVIATION_BPS).
    ///      DEPLOYMENT REQUIREMENT (docs/DEPLOYMENT-CHECKLIST.md §2): this is a pre-deploy gate no
    ///      contract can check for itself. Nothing on-chain can tell whether the configured `feed`
    ///      is genuinely independent of the venue, so setting it to `false` on a venue-derived feed
    ///      re-creates the exact silent failure this exists to close.
    bool public immutable singleSource;

    uint256 public markPx18;

    /// @notice Highest mark-price nonce accepted so far. Replay protection for setMarkPriceSigned.
    /// @dev Strictly increasing, and deliberately NOT derived from markPx18: writing the same price
    ///      twice is legitimate, so the value cannot carry its own ordering.
    uint64 public markNonce;

    /// @dev EIP-712 domain, built inline rather than inherited. OpenZeppelin's EIP712 base reaches
    ///      ShortStrings, which compiles to the Cancun `mcopy`, and this project targets `shanghai`
    ///      - raising evm_version for every audited contract to import one helper is not a trade
    ///      worth making. Same reasoning, and the same shape, as SolvencyRegistry.
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _NAME_HASH = keccak256("UseCert CertOracle");
    bytes32 private constant _VERSION_HASH = keccak256("1");

    bytes32 public constant SET_MARK_TYPEHASH = keccak256("SetMark(uint256 px18,uint64 nonce,uint64 deadline)");

    /// @notice EIP-712 domain separator for this oracle on this chain.
    /// @dev Recomputed per call, not cached: a cached separator would keep the deploy-time chainId
    ///      and leave every signature valid on both sides of a fork.
    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));
    }
    /// @dev The deviation breaker's reference price. Only the constructor and pokeLastGood write
    ///      it, and pokeLastGood is rate-limited (see H-1 there).
    uint256 public lastGoodPx18;
    /// @dev L-4: ONE meaning, everywhere — the FEED ROUND timestamp (`latestRoundData().updatedAt`)
    ///      of the feed observation that last wrote `lastGoodPx18`. It is NOT the block time of
    ///      that write. The constructor used to record `block.timestamp` here while pokeLastGood
    ///      recorded the feed's `updatedAt`, so one field carried two clocks and any consumer
    ///      computing `block.timestamp - lastGoodAt` got a different answer depending on which
    ///      write it happened to be reading. The feed-round meaning is the one that matches
    ///      `pxUnguarded()`'s contract: its live branch returns the feed's own `updatedAt`, so the
    ///      fallback branch must return the same kind of number or the pair is not comparable.
    /// @dev When an advance is clamped (H-1), `lastGoodPx18` is a bounded step TOWARD the price
    ///      the feed reported at `lastGoodAt` rather than that price itself; `lastGoodAt` still
    ///      records the observation the step was taken from, i.e. how fresh the reference is.
    uint256 public lastGoodAt;

    /// @dev H-1, phase one: an out-of-band price awaiting confirmation. Not the reference — the
    ///      breaker never measures against this, it only decides whether an advance has earned
    ///      the right to happen.
    uint256 public pendingPx18;
    /// @dev H-1: BLOCK timestamp at which `pendingPx18` was first observed. Deliberately a
    ///      different clock from `lastGoodAt` (L-4's lesson: do not overload one field with two
    ///      meanings). It must be block time, not feed time: it measures how long the dislocation
    ///      has survived in the real world, and a feed that lags reports would otherwise shorten
    ///      its own confirmation window.
    uint256 public pendingSince;
    /// @dev H-1 / Task 1: the feed ROUND ID of the observation that armed `pendingPx18`. This is
    ///      the distinctness proof's anchor: a confirmation is only accepted from a round strictly
    ///      greater than this one, so "the price held" means the feed independently re-reported
    ///      it and never that one round was read twice. Written and cleared in lockstep with
    ///      `pendingSince` — see `_clearPending` and the two arming sites in pokeLastGood — so the
    ///      pair can never disagree about whether a candidate is armed.
    uint80 public pendingRoundId;

    constructor(
        address _feed,
        address _attester,
        uint8 _priceDecimals,
        uint256 _stalenessSeconds,
        uint256 _deviationBps,
        uint256 _basisBandBps,
        uint256 _pokeConfirmationSeconds,
        bool _singleSource
    ) {
        // L-3: no constructor in src/ validated its dependencies, so a mistyped address deployed
        // silently and failed later at an arbitrary call site. A zero feed is the sharpest case —
        // _readFeed below would revert on it and take the whole deployment down anyway, but with an
        // anonymous low-level failure rather than a named error.
        if (_feed == address(0) || _attester == address(0)) revert CertOracle_ZeroAddress();
        // Task 1: a zero confirmation window leaves the `roundId` proof as the ONLY gate, and that
        // proof bounds round DISTINCTNESS, not RATE.
        //
        // What zero does NOT do, measured with this guard lifted (fix round 1 review, and two
        // earlier write-ups of this check got it wrong in the same direction): it does not permit
        // an atomic walk. An arm plus a same-block poke carrying a brand-new round reverts
        // CertOracle_ReferenceRateLimited, because arming writes `pendingSince = block.timestamp`
        // and the strict `0 > 0` is false. Ten further fresh rounds inside that same block all
        // revert identically and the reference does not move. A second confirmation in the block
        // of a SUCCESSFUL one reverts the same way, because the confirm path re-arms `pendingSince`
        // to the current block time. So H-1's atomic reference reset stays shut even at zero.
        //
        // What zero DOES do is degrade the rate limit to ONE clamped `deviationBps` step per block
        // that carries a new feed round. Not atomic — but on a fast chain that is roughly 5% of
        // the reference per block: a 20% dislocation was absorbed in four blocks end to end
        // (100 -> 105 -> 110.25 -> 115.7625 -> 120, at deviationBps = 500). A rate limit that
        // concedes a full clamped step every block is a rate limit in name only, and that is the
        // real and sufficient reason to refuse zero. Refuse it at deploy time rather than discover
        // it live.
        if (_pokeConfirmationSeconds == 0) revert CertOracle_ConfigOutOfBounds();
        // Task 2: in single-source mode the deviation clamp is the only guard left standing, so its
        // width is the whole safety budget. Refuse a configuration that leaves it wide. Checked
        // only when `_singleSource` is true, so a dual-source deployment's tolerance is untouched.
        if (_singleSource && _deviationBps > MAX_SINGLE_SOURCE_DEVIATION_BPS) {
            revert CertOracle_DeviationTooWideForSingleSource();
        }
        feed = IAggregatorV3(_feed);
        attester = _attester;
        governance = msg.sender;
        priceDecimals = _priceDecimals;
        stalenessSeconds = _stalenessSeconds;
        deviationBps = _deviationBps;
        basisBandBps = _basisBandBps;
        pokeConfirmationSeconds = _pokeConfirmationSeconds;
        singleSource = _singleSource;

        // L-4: the constructor checked positivity but not staleness, so a vault could be deployed
        // against an already-dead feed and start life with a reference price nobody had quoted for
        // days. Same guard shape as px(), future-timestamp half FIRST so it short-circuits the
        // subtraction (CRITICAL B) — and the same named error, not an arithmetic panic.
        (uint256 p, uint256 t,) = _readFeed();
        if (t > block.timestamp || block.timestamp - t > _stalenessSeconds) revert CertOracle_StalePrice();
        lastGoodPx18 = p;
        // L-4: the feed round timestamp, matching pokeLastGood and pxUnguarded's live branch.
        lastGoodAt = t;
    }

    function setMarkPrice(uint256 px18) external {
        if (msg.sender != attester) revert CertOracle_OnlyAttester();
        markPx18 = px18;
    }

    /// @notice The mark price the attester SIGNED rather than SENT, so the minter pays the gas.
    /// @dev The companion to SolvencyRegistry.attestSigned, and the second half of one logical
    ///      update: the attester writes markPx18 here and the solvency figures there, and on the
    ///      signed path a minter submits both inside their own transaction.
    ///
    /// @dev WHY THIS ONE NEEDS LESS TIMESTAMP MACHINERY THAN THE REGISTRY. markPx18 has no stored
    ///      timestamp and never did, because nothing measures its age - it is a CROSS-CHECK, not a
    ///      clock. Its staleness is caught structurally instead: mintAllowed() bands it against the
    ///      live feed (`diff * 10_000 / p > basisBandBps` fails), so a mark that has drifted away
    ///      from reality closes minting by itself, whatever timestamp anyone attaches to it. Adding
    ///      an `observedAt` here would therefore be ceremony rather than a guard. The `deadline`
    ///      still earns its place: it bounds how long a relayer may sit on any one signature, which
    ///      is what stops a mark being replayed at a moment of the relayer's choosing INSIDE the
    ///      band, where the band would not catch it.
    ///
    /// @dev `nonce` is what replay protection there is. The registry gets it free from a strictly
    ///      increasing batchId; there is no equivalent here, since setting the same mark twice is
    ///      legitimate and markPx18 carries no sequence of its own. So the nonce is explicit, it is
    ///      inside the signed payload, and it must strictly increase - which also means the two
    ///      halves can be submitted independently without one having to know the other's state.
    function setMarkPriceSigned(uint256 px18, uint64 nonce, uint64 deadline, bytes calldata signature) external {
        if (block.timestamp > deadline) revert CertOracle_SignatureExpired();
        if (nonce <= markNonce) revert CertOracle_StaleNonce();

        bytes32 structHash = keccak256(abi.encode(SET_MARK_TYPEHASH, px18, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
        if (ECDSA.recover(digest, signature) != attester) revert CertOracle_BadSignature();

        markNonce = nonce;
        markPx18 = px18;
    }

    /// @notice Start an attester rotation. Governance-gated; effective no sooner than
    ///         ATTESTER_ROTATION_DELAY from now.
    /// @dev M-5: a role change, not a trading power (Law 6). It cannot move collateral, place an
    ///      order, pause anything, or reach a redemption path.
    function proposeAttester(address next) external {
        if (msg.sender != governance) revert CertOracle_OnlyGovernance();
        if (next == address(0)) revert CertOracle_ZeroAddress();
        pendingAttester = next;
        pendingAttesterAt = block.timestamp + ATTESTER_ROTATION_DELAY;
        emit AttesterRotationProposed(next, pendingAttesterAt);
    }

    /// @notice Install a rotation whose notice period has elapsed. Permissionless (Law 6) — see
    ///         SolvencyRegistry.acceptAttester for why anyone may finalise.
    function acceptAttester() external {
        address next = pendingAttester;
        if (next == address(0)) revert CertOracle_NoPendingAttester();
        if (block.timestamp < pendingAttesterAt) revert CertOracle_RotationNotDue();

        address previous = attester;
        attester = next;
        pendingAttester = address(0);
        pendingAttesterAt = 0;
        emit AttesterRotated(previous, next);
    }

    /// @dev Task 1: also returns the round id. The round id is read, not validated: this function's
    ///      callers (the constructor and px()) do not use it, and validating it here would silently
    ///      add a new revert to px().
    /// @dev Task 3: the decimals bound below closes a documented asymmetry with `_tryFeed`. That
    ///      function has bounded `d` at 36 since Finding 2, so pxUnguarded(), basisBps() and
    ///      mintAllowed() were all safe against an absurd `decimals()`; THIS function had no bound,
    ///      so a feed reporting `decimals() >= 96` overflowed `10 ** (d - 18)` and panicked (0x11)
    ///      inside px(), taking both mint paths down with an anonymous arithmetic failure instead of
    ///      a named error. px() is ALLOWED to revert on a malfunctioning feed — it backs minting,
    ///      which must be gated — so the fix is not "return something", it is to revert with the
    ///      error a caller can switch on, exactly as the CRITICAL B guard above does for a future
    ///      timestamp.
    ///
    ///      The bound is 36, COPIED from `_tryFeed` rather than re-derived, because the two
    ///      functions normalising the same feed by different rules is how this class of defect
    ///      appears in the first place. 36 is far beyond any real aggregator and safely below the
    ///      ~78 exponent at which the power itself overflows.
    ///
    ///      The constructor also reads through here, so a feed already reporting out-of-range
    ///      decimals at deploy time is now refused by name instead of panicking — the same
    ///      improvement L-4 made for an already-stale feed.
    ///
    ///      NOT a Law 2 concern, and asserted as a test: redemption prices off pxUnguarded(), which
    ///      goes through `_tryFeed` and falls back to `lastGoodPx18`. `forceExit` never touches
    ///      `_readFeed`. Verified against a feed reporting 96 decimals with a holder mid-position.
    function _readFeed() internal view returns (uint256 px18, uint256 updatedAt, uint80 roundId) {
        (uint80 r, int256 answer,, uint256 t,) = feed.latestRoundData();
        if (answer <= 0) revert CertOracle_NonPositivePrice();
        uint8 d = feed.decimals();
        if (d > 36) revert CertOracle_FeedDecimalsOutOfRange();
        // Task 13: guard the PRODUCT, not a hard-coded magnitude, so the bound tracks `d` exactly
        // like `_tryFeed`'s mirror check at `:376-379` — mirrored here rather than re-derived.
        // Unreachable for `d` in 18..36: at `d == 18` the multiplier is 1 (1e0), so no `answer` up
        // to `int256` max can overflow the product; above 18 the ternary below divides instead of
        // multiplying. Only `d <= 17` can reach this revert.
        if (d <= 18 && uint256(answer) > type(uint256).max / (10 ** (18 - d))) {
            revert CertOracle_AnswerNotNormalisable();
        }
        px18 = d <= 18 ? uint256(answer) * (10 ** (18 - d)) : uint256(answer) / (10 ** (d - 18));
        updatedAt = t;
        roundId = r;
    }

    /// @dev CRITICAL B: `t > block.timestamp` is checked FIRST and reverts the NAMED error.
    ///      Without it, a feed reporting an `updatedAt` in the future underflows
    ///      `block.timestamp - t` and reverts with an anonymous arithmetic panic (0x11) instead.
    ///      px() is allowed — required — to revert on a malfunctioning feed, so the fix here is
    ///      not "return something": it is to revert with the error callers can actually switch
    ///      on. A future timestamp is not "extremely fresh", it is a broken feed.
    function px() external view returns (uint256) {
        (uint256 p, uint256 t,) = _readFeed();
        if (t > block.timestamp || block.timestamp - t > stalenessSeconds) revert CertOracle_StalePrice();
        return p;
    }

    /// @notice Never reverts on guard state. The published last-good-price path for redemption.
    function pxUnguarded() external view returns (uint256, uint256) {
        (bool ok, uint256 p, uint256 t,) = _tryFeed();
        if (ok) return (p, t);
        return (lastGoodPx18, lastGoodAt);
    }

    /// @dev Never lets an external feed failure propagate: pxUnguarded(), basisBps() and
    ///      mintAllowed() all rely on this returning cleanly no matter what the feed does.
    /// @dev Task 1: also returns the round id, used only by pokeLastGood's distinctness proof.
    ///      Every failure tuple returns roundId 0 alongside the zero price and timestamp — an
    ///      `ok == false` return means "this feed observation does not exist", so no member of the
    ///      tuple carries information and callers must key off `ok`, exactly as before.
    function _tryFeed() internal view returns (bool ok, uint256 px18, uint256 updatedAt, uint80 roundId) {
        try feed.latestRoundData() returns (uint80 r, int256 answer, uint256, uint256 t, uint80) {
            if (answer <= 0) return (false, 0, 0, 0);
            // CRITICAL B (C1 final review): the `t > block.timestamp` half of this condition is
            // the fix, and it must come FIRST so it short-circuits the subtraction. Without it,
            // `block.timestamp - t` underflows on a feed reporting a future updatedAt and panics
            // (0x11) — and this is the SUCCESS block of a try, which that try's own catch does
            // not cover, so the panic propagated uncaught through _tryFeed() -> pxUnguarded() ->
            // CertVault._queueExit() and reverted forceExit(), the protocol's last-resort
            // backstop (Law 2), with the lastGoodPx18 fallback that exists for exactly this case
            // sitting unreachable two lines away. `feed` is immutable here and `oracle` is
            // immutable in CertVault, so there was no swap out of it either.
            // A future timestamp is NOT "fresher than fresh": it is a malfunctioning feed, so it
            // is unusable and returns the failure tuple like any other _tryFeed() failure.
            if (t > block.timestamp || block.timestamp - t > stalenessSeconds) return (false, 0, 0, 0);
            try feed.decimals() returns (uint8 d) {
                // Finding 2 (Task 10 review): arithmetic inside a try's success block is NOT
                // covered by that try's own catch. decimals() >= 96 makes 10 ** (d - 18) overflow
                // uint256 and panic uncaught here, propagating through pxUnguarded()/basisBps()/
                // mintAllowed() — all three are documented to never revert. Bound d before doing
                // any exponentiation: 36 is far beyond any real aggregator and safely below the
                // ~78 exponent where the power itself would overflow. Out of range -> the feed is
                // simply unusable, same as any other _tryFeed() failure.
                if (d > 36) return (false, 0, 0, 0);
                // CRITICAL B re-audit, third exposure in this same success block: with d bounded
                // the exponentiation is safe and the d > 18 branch is a division by a non-zero
                // power, but `uint256(answer) * (10 ** (18 - d))` can still overflow — answer is
                // an int256 whose positive range reaches ~5.8e76, and at d = 0 the multiplier is
                // 1e18, so any answer above ~1.15e59 panics uncaught here exactly like the
                // staleness underflow did. Check the product's headroom instead of trusting the
                // feed's magnitude; an answer that cannot be normalised is an unusable feed.
                if (d <= 18) {
                    uint256 scale = 10 ** (18 - d);
                    if (uint256(answer) > type(uint256).max / scale) return (false, 0, 0, 0);
                    px18 = uint256(answer) * scale;
                } else {
                    px18 = uint256(answer) / (10 ** (d - 18));
                }
                return (true, px18, t, r);
            } catch {
                return (false, 0, 0, 0);
            }
        } catch {
            return (false, 0, 0, 0);
        }
    }

    /// @notice |mark - index| in bps. Never reverts.
    /// @dev L-5: the return value ALONE is ambiguous and always has been — 0 means both "the mark
    ///      sits exactly on the index" (healthy) and "the basis could not be computed": the feed
    ///      is unreadable, or normalises to zero, or no mark has ever been attested. A dashboard
    ///      wired to this number renders a dead feed as a perfectly tracking one. The signature is
    ///      kept because it is declared in ICertOracle and asserted by the existing suite; use
    ///      basisBpsChecked() for anything that acts on the value, including display.
    /// @dev Task 2: this is the ONE exception to "never reverts" — a single-source deployment
    ///      reverts CertOracle_NoIndependentBasis rather than returning a meaningless zero. The
    ///      never-reverts guarantee existed to keep a FEED FAILURE from propagating; single-source
    ///      is not a failure, it is a permanent structural property of the deployment fixed at
    ///      construction, so a caller cannot be surprised by it mid-flight and can read
    ///      `singleSource` once to know. Returning zero here would be the L-5 defect restated in a
    ///      form L-5's own fix cannot see: not "0 might mean unknown" but "0 asserts a healthy
    ///      basis that was never computed". Callers that need a total function keep
    ///      basisBpsChecked(), which still never reverts. Verified again for this change: no src/
    ///      contract calls basisBps(), so no redemption path can reach the revert (Law 2).
    function basisBps() external view returns (uint256) {
        if (singleSource) revert CertOracle_NoIndependentBasis();
        (, uint256 bps) = _basis();
        return bps;
    }

    /// @notice basisBps() with the "is this number meaningful" bit attached.
    /// @return known false when the basis could not be computed at all (unreadable feed, an index
    ///         that normalises to zero, no attested mark, or — Task 2 — a single-source deployment
    ///         in which no independent second source exists to compute a basis FROM); the bps
    ///         value is then meaningless.
    /// @return bps  the basis in bps when `known`, else 0.
    /// @dev L-5: chosen over a sentinel return and over a separate basisKnown() view. A sentinel
    ///      would change what the existing basisBps() means to every consumer already reading it,
    ///      including two assertions in the suite, and sentinels get compared with `<` sooner or
    ///      later. A companion boolean view would be two eth_calls that can straddle a block, so a
    ///      consumer could pair `known == true` with a bps computed after the feed died. This is
    ///      one call, atomic, and purely additive: nothing that reads basisBps() today has to
    ///      change. Verified call sites of basisBps(): src/interfaces/ICertOracle.sol (declaration
    ///      only — no src/ consumer calls it; CertVault never reads the basis) and
    ///      test/CertOracle.t.sol. Never reverts, for the same reason basisBps() does not.
    function basisBpsChecked() external view returns (bool known, uint256 bps) {
        return _basis();
    }

    function _basis() internal view returns (bool known, uint256 bps) {
        // Task 2, and the core of the finding. This branch must come FIRST and must return
        // `known = false`: with a venue-derived feed, `markPx18` and `p` are the same number, so
        // the computation below would succeed and report `known = true, bps = 0` — a healthy basis
        // asserted rather than measured. ABSENT is not ZERO. The two states have to be
        // distinguishable by a caller, and that they were not is the bug being closed.
        if (singleSource) return (false, 0);
        (bool ok, uint256 p,,) = _tryFeed();
        if (!ok || p == 0 || markPx18 == 0) return (false, 0);
        uint256 diff = markPx18 > p ? markPx18 - p : p - markPx18;
        return (true, diff * 10_000 / p);
    }

    /// @dev NOT FIXED, recorded deliberately (C1 audit, H-1 follow-on): the basis band below is
    ///      measured against `markPx18`, which is written by the trusted attester with NO
    ///      timestamp and is subject to NO staleness check anywhere in this contract. It fails
    ///      CLOSED — a mark frozen while the index moves widens the basis and returns false — so
    ///      it is not dangerous today, and that is the only reason it is not fixed here. But it
    ///      fails closed only incidentally: a mark frozen at a level that happens to track the
    ///      index keeps minting open against a number nobody has refreshed, so the guard's
    ///      liveness is unproven. That is H-1's mistake in a different field. The fix needs a
    ///      `markAt` plus its own `markStalenessSeconds` — the attester's cadence is not the
    ///      Chainlink heartbeat and must not be conflated with `stalenessSeconds` — which means a
    ///      new constructor parameter and every deployment site with it. It is neither trivial nor
    ///      isolated, so it is scoped separately. Note also that H-1's rate limit leaves this band
    ///      as the guard doing the real work for several windows during a large sustained
    ///      repricing, which raises the stakes on its liveness rather than lowering them.
    ///
    /// @dev TASK 2 — THE GUARD SET IS DELIBERATELY SMALLER IN SINGLE-SOURCE MODE, AND SAYING SO IS
    ///      THE POINT. When `singleSource` is true the basis band is SKIPPED ENTIRELY. It is not a
    ///      guard in that mode: `feed` is venue-derived, so `markPx18` and the feed price are the
    ///      same number reported twice, `diff` is structurally ~0, and the band passes always and
    ///      most convincingly at the moment the venue mark is being pushed — moving the mark moves
    ///      both inputs together and holds the basis at zero. Leaving the band in place would keep
    ///      a check that cannot fail, which is strictly worse than removing it: it reads, to
    ///      anything auditing this function, as a live cross-check.
    ///
    ///      What is left is staleness/readability (`_tryFeed`) plus the deviation clamp, and the
    ///      clamp is a RATE LIMIT, not a truth check — it bounds how fast the accepted price may
    ///      move and says nothing about whether the price is right. That is why
    ///      MAX_SINGLE_SOURCE_DEVIATION_BPS caps it at construction, and why the clamp's REFERENCE
    ///      is required to exist here: `lastGoodPx18 == 0` skips the deviation check in the
    ///      dual-source branch below (harmless there, the band still stands), but in single-source
    ///      mode it would leave NO guard at all beyond "the feed answered". So a missing reference
    ///      fails closed instead. Reachable only when construction itself normalised to zero (see
    ///      test_H1_pokeRejectsAPriceThatNormalisesToZero) and repairable by pokeLastGood's
    ///      bootstrap path, so this costs a real deployment nothing.
    ///
    ///      Also dropped with the band: its `markPx18 != 0` precondition. That check exists only to
    ///      make the band computable, and keeping it while ignoring the mark's VALUE would hand the
    ///      attester a mint pause — by inaction, with no compensating safety benefit, since nothing
    ///      in this mode consults the mark. A gate an attester can trip by going quiet is a pause
    ///      path in all but name (Law 6), and it would restate L-5's mistake in the other
    ///      direction: asserting the mark matters when the contract has stopped reading it.
    ///
    ///      Nothing above changes ANY dual-source behaviour: the `singleSource == false` branch is
    ///      the previous body, in the previous order, with the previous short-circuits.
    function mintAllowed() external view returns (bool) {
        (bool ok, uint256 p,,) = _tryFeed();
        if (!ok || p == 0) return false;
        if (singleSource) {
            // The deviation clamp is the only remaining defence, so its reference must exist.
            if (lastGoodPx18 == 0) return false;
        } else {
            if (markPx18 == 0) return false;
            uint256 diff = markPx18 > p ? markPx18 - p : p - markPx18;
            if (diff * 10_000 / p > basisBandBps) return false;
        }
        if (lastGoodPx18 != 0) {
            uint256 dev = p > lastGoodPx18 ? p - lastGoodPx18 : lastGoodPx18 - p;
            if (dev * 10_000 / lastGoodPx18 > deviationBps) return false;
        }
        return true;
    }

    /// @notice Encode an 18-decimal price into Lighter's uint32 tick domain.
    function toTickPrice(uint256 px18) external view returns (uint32) {
        uint256 tick = px18 * (10 ** priceDecimals) / 1e18;
        if (tick == 0 || tick > type(uint32).max) revert CertOracle_TickOverflow();
        return uint32(tick);
    }

    /// @notice Refresh the last-good snapshot. Still permissionless (Law 6: no owner, no keeper,
    ///         no pause) — but the reference it writes is now RATE-LIMITED.
    ///
    /// @dev H-1 (High, C1 audit). The old body wrote `lastGoodPx18 = p` unconditionally, and its
    ///      NatSpec argued that a permissionless poke "can only ever record the feed's own healthy
    ///      value, so there is nothing to game". That is true of the VALUE and false of the GUARD.
    ///      `_tryFeed` screens for staleness, positivity and normalisability — never for
    ///      deviation — so a post-jump price is "healthy" by that definition, and the poke
    ///      laundered it into the very reference `mintAllowed()` measures deviation against.
    ///      Measured at deviationBps = 500 with a genuine 6% move: mintAllowed() == false, one
    ///      unprivileged pokeLastGood(), mintAllowed() == true, and a mint then went through — all
    ///      available atomically, in the mint's own transaction, to the party the breaker exists
    ///      to stop. A circuit breaker whose reference is resettable by its target is not a
    ///      breaker, it is a gas optimisation.
    ///
    ///      Fix: two-phase confirmation plus a per-advance clamp, so the reference can chase a
    ///      dislocation only at a bounded rate and never inside one transaction.
    ///
    ///      1. IN BAND (|p - ref| <= deviationBps): recorded immediately, exactly as before.
    ///         Nothing is being laundered — the breaker is not tripped on this price, and moving
    ///         the reference onto a price the breaker already accepts cannot flip its verdict.
    ///         Keeping this path unrestricted is deliberate: `lastGoodPx18`/`lastGoodAt` are also
    ///         pxUnguarded()'s fallback, so Law 2's snapshot must stay refreshable in normal
    ///         operation.
    ///      2. OUT OF BAND, unconfirmed: the observation is ARMED (pendingPx18/pendingSince) and
    ///         the reference is left alone. This call cannot revert — it has state to write — so
    ///         it returns having advanced nothing.
    ///      3. OUT OF BAND, armed, still within deviationBps of the armed price, AND both
    ///         confirmation conditions hold — `block.timestamp - pendingSince >
    ///         pokeConfirmationSeconds` and `roundId > pendingRoundId`: CONFIRMED. The reference
    ///         advances by AT MOST deviationBps toward the live price, and re-arms (price, block
    ///         time and round id together), so a further step costs another full window.
    ///      4. OUT OF BAND, armed and held, window not yet elapsed: reverts
    ///         CertOracle_ReferenceRateLimited. Window elapsed but the feed is still on the arming
    ///         round: reverts CertOracle_ReferenceRoundNotAdvanced. If the price instead moved out
    ///         of band relative to the armed price, it has not held, and the candidate is re-armed
    ///         from scratch — a transient spike therefore expires instead of confirming.
    ///
    ///      Why a cooldown and not the per-call clamp alone: the clamp alone does not fix this.
    ///      Nothing rate-limits how many times pokeLastGood can be called in one transaction, so a
    ///      loop of clamped pokes walks the reference to the live price atomically anyway — and
    ///      even a single clamped step clears the breaker for any move up to
    ///      2*deviationBps + deviationBps^2 (10.25% at 500 bps), which covers the measured 6%
    ///      exploit exactly. The time gate is what makes a poke sequence unrepeatable within a
    ///      block; the clamp is what bounds a large move to several windows instead of one.
    ///      Both are kept, and neither needs a key.
    ///
    ///      Why round distinctness is proven from `roundId`, and why the window is its OWN
    ///      immutable (Task 1). This function used to derive distinctness from time: with a strict
    ///      `>` against `stalenessSeconds`, the armed round satisfied `t_arm <= pendingSince` and
    ///      the confirming round had to be fresh, so
    ///      `t_conf >= block.timestamp - stalenessSeconds > pendingSince >= t_arm` and the two
    ///      observations were provably different rounds. The inference was sound but it WELDED the
    ///      breaker's rate limit to the feed-freshness bound, and the two have nothing to do with
    ///      each other. `latestRoundData()` hands us the round identity directly, and the contract
    ///      was discarding it. So the proof is now the direct one — `roundId > pendingRoundId`,
    ///      recorded at arming time — and "the price held" means the feed minted a new round
    ///      reporting that level, which is the actual claim, asserted rather than inferred.
    ///
    ///      Freeing the proof from the clock is what lets the two knobs separate, and they are
    ///      deliberately independent because they answer different questions:
    ///        * `stalenessSeconds` — "how old may a feed observation be and still be usable at
    ///          all?" It is a property of the aggregator's heartbeat. TESTNET-PLAN.md §1 sets it
    ///          to 93_600 (26 h) on mainnet, one hour past Chainlink's 24 h equity heartbeat.
    ///        * `pokeConfirmationSeconds` — "how long must a dislocation persist before the
    ///          breaker's reference concedes one clamped step to it?" It is a risk tolerance, and
    ///          the right value is on the order of an hour, not a day.
    ///      Conflating them priced every clamped step at a full heartbeat: at 93_600 seconds a 20%
    ///      repricing needed four steps and kept minting shut for roughly 4.3 days — a breaker
    ///      that outlasts the event it fired on stops being a safety control and becomes an
    ///      outage. Tightening `stalenessSeconds` to buy back that latency was the only lever, and
    ///      it is the wrong lever: it makes the oracle reject feed data it should still accept,
    ///      trading a liveness problem for a correctness one. Two independent immutables let an
    ///      operator hold the feed bound where the aggregator's cadence puts it and set the
    ///      breaker's patience separately.
    ///
    ///      Note what did NOT get weaker. Removing the timestamp inequality removed an inference,
    ///      not a check: distinctness is still required, now directly, and the rate limit is still
    ///      required, now on its own axis. A poke sequence inside one transaction still cannot
    ///      confirm anything — both arming sites below write `pendingSince = block.timestamp`, so
    ///      `block.timestamp - pendingSince` is 0 for every same-block follow-up and the strict
    ///      `>` refuses it.
    ///
    ///      That same-block refusal holds at EVERY window value, zero included (measured both
    ///      ways), so it is not what makes zero unsafe and it is NOT the reason
    ///      `pokeConfirmationSeconds == 0` is refused at construction. Zero is refused because it
    ///      leaves the `roundId` proof as the only gate, which degrades the rate limit to one
    ///      clamped step per block that carries a new feed round — see the constructor for the
    ///      measured numbers.
    ///
    ///      What the breaker now DEPENDS ON, and cannot check for itself: the feed's `roundId`
    ///      being strictly non-decreasing for the life of the deployment. A Chainlink proxy
    ///      guarantees it (the phase id occupies the high 16 bits of the uint80, so an aggregator
    ///      rotation raises `roundId` rather than resetting it); an underlying aggregator read
    ///      directly, or any feed whose numbering resets or is constant, does not, and then an
    ///      armed candidate can never be confirmed. That fails CLOSED — minting stays paused,
    ///      redemption is untouched via pxUnguarded(), and the in-band path below still refreshes
    ///      the reference when price returns within deviationBps — but it is a pre-deploy gate,
    ///      recorded as one in docs/DEPLOYMENT-CHECKLIST.md §2.
    ///
    ///      Not touched: pxUnguarded() (Law 2's never-reverts guarantee lives there and this
    ///      function is not on its path) and mintAllowed()'s own arithmetic. The breaker is
    ///      unchanged; only the mobility of its reference is.
    ///
    ///      Config caveat: at deviationBps == 0 the clamp permits no advance in either direction,
    ///      so any price change pauses minting until the operator's own tolerance is widened. That
    ///      is the honest reading of a zero-tolerance breaker and it fails closed — whereas before
    ///      this fix, deviationBps == 0 was silently defeated by any poke at all.
    function pokeLastGood() external {
        (bool ok, uint256 p, uint256 t, uint80 rid) = _tryFeed();
        // `p == 0` is part of the same failure class and was previously accepted: _tryFeed can
        // report ok == true with px18 == 0 when a high-decimals feed truncates on normalisation
        // (see test_mintAllowedFalseWhenFeedTruncatesToZero). Writing that into lastGoodPx18 would
        // have DISABLED the deviation breaker outright — mintAllowed() skips the deviation check
        // when `lastGoodPx18 == 0` — and poisoned pxUnguarded()'s fallback with a zero price.
        if (!ok || p == 0) revert CertOracle_StalePrice();

        uint256 ref = lastGoodPx18;
        if (ref == 0) {
            // No reference to protect (only reachable if construction itself normalised to zero),
            // so there is no breaker to launder past. Bootstrap it.
            lastGoodPx18 = p;
            lastGoodAt = t;
            _clearPending();
            return;
        }

        uint256 dev = (p > ref ? p - ref : ref - p) * 10_000 / ref;
        if (dev <= deviationBps) {
            lastGoodPx18 = p;
            lastGoodAt = t;
            _clearPending();
            return;
        }

        // Out of band: this is exactly the price the breaker is holding minting shut on.
        uint256 cand = pendingPx18;
        bool held =
            cand != 0 && (p > cand ? p - cand : cand - p) * 10_000 / cand <= deviationBps;
        if (!held) {
            pendingPx18 = p;
            pendingSince = block.timestamp;
            pendingRoundId = rid;
            return;
        }
        // Task 1: the RATE LIMIT is evaluated first, for two reasons. It is by far the likelier
        // failure — a poke arriving before the window has elapsed is the ordinary case, a poke
        // arriving after it against a feed that has not re-reported is the exception — so the
        // short-circuit puts the usual answer first and skips the `pendingRoundId` load entirely
        // on that path. And it keeps the diagnostic in the order an operator reads it: "not yet"
        // before "and the feed still has not spoken". The two are independent conditions, so the
        // order is a readability and gas choice only; neither can mask the other.
        if (block.timestamp - pendingSince <= pokeConfirmationSeconds) revert CertOracle_ReferenceRateLimited();
        // The distinctness proof, direct rather than inferred from timestamps. `pendingRoundId` is
        // necessarily the round that armed `cand`, because `held` above required `cand != 0` and
        // the two are only ever written together.
        if (rid <= pendingRoundId) revert CertOracle_ReferenceRoundNotAdvanced();

        // Confirmed. Advance by at most deviationBps, in the direction of the move.
        uint256 next;
        if (p > ref) {
            uint256 ceilPx = ref + ref * deviationBps / 10_000;
            next = p < ceilPx ? p : ceilPx;
        } else {
            uint256 down = ref * deviationBps / 10_000;
            uint256 floorPx = down >= ref ? 0 : ref - down;
            next = p > floorPx ? p : floorPx;
        }
        // `next` can never be zero: p >= 1 is checked above and next >= min(p, floorPx) with
        // floorPx only reaching 0 for a deviationBps >= 10_000 configuration, where next == p.
        // A zero reference would switch mintAllowed()'s deviation check off entirely.
        lastGoodPx18 = next;
        lastGoodAt = t;
        // Re-arm from THIS observation: price, block time and round id, written together so the
        // next step needs both a fresh window and a further new round.
        pendingPx18 = p;
        pendingSince = block.timestamp;
        pendingRoundId = rid;
    }

    /// @dev The single disarm path. All three pending fields are cleared together — the guard is
    ///      on `pendingSince` only as a gas short-circuit for the overwhelmingly common
    ///      nothing-armed case, and `pendingSince != 0` holds exactly when a candidate is armed
    ///      because the two arming sites in pokeLastGood write all three in one go.
    function _clearPending() internal {
        if (pendingSince != 0) {
            pendingPx18 = 0;
            pendingSince = 0;
            pendingRoundId = 0;
        }
    }
}
