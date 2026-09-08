// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @notice Per-asset ACCRUAL LEDGER for funding, execution variance and realised basis, with
///         published thresholds. Positive accrual credits it; negative draws it down. Nothing here
///         is hidden — every threshold and the live ledger balance are readable on-chain (Law 3).
///
/// @dev M-1 (MEDIUM, external C1 audit). WHAT THIS CONTRACT IS, AND WHAT IT IS NOT.
///      It is a cumulative P&L counter. It is not, and never was, a measure of collateral the vault
///      actually holds, and the finding is that it was published and consumed as though it were:
///
///        (a) it drifts from reality under ordinary operation. Mint fees raise the vault's real
///            float without accruing here; instant redemptions drain that float without accruing
///            here. Nothing reconciles them. MEASURED after one mint + instant-redeem cycle:
///            published buffer 100,000.00, collateral actually held 91,028.00.
///        (b) accrueFunding() lets the oracle attester write it, so the published figure could be
///            set to anything at all. MEASURED: one call produced a published buffer of
///            500,100,000.01 against 91,028.00 held.
///
///      Both halves are closed on the CertVault side, in the two places that matter, and the fix
///      is a SEPARATION rather than a reconciliation — the audit's direction 2. The number
///      published as "the buffer" (CertVault.Solvency.buffer18) is now the vault's own collateral
///      balance, ground truth from an ERC20 balanceOf that no accrual can move; this ledger is
///      published beside it as what it actually is, cumulative P&L
///      (CertVault.Solvency.accrual18, and balance18() here). Admission control no longer takes
///      its bound FROM this ledger either — see CertVault.bufferCapacity18(), which derives the
///      capacity leg from real collateral and keeps this ledger only as a one-way tightening
///      term. Reconciling this ledger against real collateral instead (direction 1) would have
///      made it a mirror of balanceOf, which is a figure the chain already publishes and which
///      cannot express a P&L at all.
///
/// @dev The insurance draw is exposed as a number and an event only. C3's InsuranceStaking reads
///      it; this contract never needs to change to support that.
contract BufferBook {
    error BufferBook_OnlyVault();
    /// @dev M-2: the four thresholds are a descending ladder — floor, then fee-on, then mint-slow,
    ///      then the insurance draw — and every reader here (holdingFeeBps, mintSlowed,
    ///      insuranceDrawNeeded, the level in accrue) assumes that ordering. They used to be four
    ///      unvalidated numbers, so a mis-ordered configure() published a ladder whose rungs
    ///      crossed. Now they are configurable per asset (CertVault.setBufferThresholds) and the
    ///      ordering is enforced at the point of configuration rather than assumed by four
    ///      separate readers. Equalities are allowed: collapsing two rungs onto one number is a
    ///      legitimate configuration (the C1 default sets insuranceDraw18 = 0).
    error BufferBook_ThresholdsOutOfOrder();
    /// @dev L-3 (LOW, external C1 audit): a zero vault makes configure() and accrue() permanently
    ///      unreachable, so the ledger could never be written at all.
    error BufferBook_ZeroAddress();

    event ThresholdCrossed(address indexed asset, uint8 level);
    event Accrued(address indexed asset, int256 delta18, int256 balance18);
    /// @dev M-2 (Law 3): the thresholds are per-asset configuration now, so a change to them has
    ///      to be as published as the ledger they describe.
    event Configured(
        address indexed asset, uint256 floor18, uint256 feeOn18, uint256 mintSlow18, uint256 insuranceDraw18
    );

    struct Config {
        uint256 floor18;
        uint256 feeOn18;
        uint256 mintSlow18;
        uint256 insuranceDraw18;
        bool set;
    }

    address public immutable vault;
    /// @dev maximum holding fee in bps, immutable at deploy (Law 3: bounded, published)
    /// @dev M-2: NOT CHARGED ANYWHERE IN C1. holdingFeeBps() below computes a rate and no path
    ///      applies it. See that function.
    uint256 public immutable feeCapBps;

    mapping(address => Config) public config;
    mapping(address => int256) private _balance;

    constructor(address _vault, uint256 _feeCapBps) {
        if (_vault == address(0)) revert BufferBook_ZeroAddress();
        vault = _vault;
        feeCapBps = _feeCapBps;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert BufferBook_OnlyVault();
        _;
    }

    /// @notice Set the published threshold ladder for one asset. Called by the vault at deploy with
    ///         its defaults, and thereafter through CertVault.setBufferThresholds.
    /// @dev M-2: the four thresholds used to be hardcoded literals in the CertVault constructor
    ///         (100k / 60k / 30k / 0) for every asset regardless of size, with no way to
    ///         reconfigure — a 100k floor is meaningless against a $1.19M book and wrong for one
    ///         ten times larger. They are per-asset configuration now. They gate NOTHING (see
    ///         holdingFeeBps and mintSlowed), so this is a reporting parameter and not a lever
    ///         over any path: Law 2 is untouched because no redemption path reads this contract at
    ///         all, and Law 6 is untouched because the one mechanical consequence buffer health
    ///         still has — an exhausted ledger tightening mint capacity, via capacity18() below —
    ///         is anchored at zero, which is not one of these four numbers and cannot be moved.
    function configure(address asset, uint256 floor18, uint256 feeOn18, uint256 mintSlow18, uint256 insuranceDraw18)
        external
        onlyVault
    {
        if (floor18 < feeOn18 || feeOn18 < mintSlow18 || mintSlow18 < insuranceDraw18) {
            revert BufferBook_ThresholdsOutOfOrder();
        }
        config[asset] = Config(floor18, feeOn18, mintSlow18, insuranceDraw18, true);
        emit Configured(asset, floor18, feeOn18, mintSlow18, insuranceDraw18);
    }

    function accrue(address asset, int256 delta18) external onlyVault {
        int256 b = _balance[asset] + delta18;
        _balance[asset] = b;
        emit Accrued(asset, delta18, b);

        Config memory c = config[asset];
        uint8 level = 0;
        if (b < int256(c.insuranceDraw18)) level = 3;
        else if (b < int256(c.mintSlow18)) level = 2;
        else if (b < int256(c.feeOn18)) level = 1;
        emit ThresholdCrossed(asset, level);
    }

    /// @notice The accrual ledger's balance: cumulative funding, execution variance and realised
    ///         basis. NOT a collateral balance — see the contract NatSpec, and read
    ///         CertVault.Solvency.buffer18 for the figure that is.
    function balance18(address asset) external view returns (int256) {
        return _balance[asset];
    }

    /// @notice Linear ramp from 0 at feeOn to feeCapBps at empty. Never exceeds the cap.
    /// @dev M-2 (MEDIUM, external C1 audit): THIS FEE IS NOT CHARGED. Nothing outside this
    ///      contract's own unit tests reads it, no mint or redemption path applies it, and C1 does
    ///      not ship the ramp Law 3 describes. It is kept as a published, computed rate — the
    ///      number a dashboard and C2's fee wiring will use — and the spec has been amended to say
    ///      plainly that a cliff ships where a ramp was specified: what actually happens as the
    ///      ledger degrades is nothing at all until it crosses zero, at which point capacity18()
    ///      returns 0 and new minting halts. See docs/.../design.md Law 3 and section 6.
    function holdingFeeBps(address asset) external view returns (uint256) {
        Config memory c = config[asset];
        int256 b = _balance[asset];
        if (b >= int256(c.feeOn18)) return 0;
        if (b <= 0) return feeCapBps;
        // L-6 (LOW, external C1 audit): `if (c.feeOn18 == 0) return 0;` used to sit here and was
        // unreachable — the two branches above establish feeOn18 > b > 0, so feeOn18 is non-zero by
        // the time control reaches this point and the division below cannot divide by zero. It was
        // removed rather than made reachable: making it reachable would have meant weakening one of
        // the two branches that make it dead, and both of those are load-bearing (b >= feeOn18 is
        // the no-fee case, b <= 0 is the capped case). The guarantee it was pretending to provide is
        // stated here instead, where a reader checking the division will look for it.
        uint256 shortfall = c.feeOn18 - uint256(b);
        uint256 fee = (shortfall * feeCapBps + c.feeOn18 / 2) / c.feeOn18;
        return fee > feeCapBps ? feeCapBps : fee;
    }

    /// @notice Published signal that the ledger is below its mint-slow threshold.
    /// @dev M-2: read by nothing. `instantCap18` is immutable config on CertVault with no setter,
    ///      so it does not "drop as buffer health degrades" the way spec section 6 claimed; the
    ///      spec has been amended rather than the claim left standing. C2 owns the taper.
    function mintSlowed(address asset) external view returns (bool) {
        return _balance[asset] < int256(config[asset].mintSlow18);
    }

    function insuranceDrawNeeded(address asset) external view returns (uint256) {
        int256 b = _balance[asset];
        int256 threshold = int256(config[asset].insuranceDraw18);
        if (b >= threshold) return 0;
        return uint256(threshold - b);
    }

    /// @notice What the ACCRUAL LEDGER claims can be absorbed, as a multiple of its balance.
    /// @dev Multiplier is the ratio of floor to a 1% adverse move on the whole book:
    ///      capacity = balance * 100.
    /// @dev M-1: THIS IS NO LONGER THE CAPACITY LEG. It used to be handed straight to
    ///      CapacityOracle.maxNotional18 as `bufferCapacity18`, which put an attester-written,
    ///      unbacked number into admission control in the direction that WIDENS it — the residual
    ///      trust M-1 is about. CertVault.bufferCapacity18() now derives that leg from collateral
    ///      the vault really holds and takes the LESSER of the two, so this figure can only ever
    ///      make the vault more conservative and can never admit a mint that real collateral does
    ///      not support. Kept, unchanged arithmetically, for exactly two reasons: it is the term
    ///      that still shuts new minting when the ledger goes negative (the honest half of the old
    ///      behaviour, and the only mechanical consequence buffer health has in C1), and it is a
    ///      published figure that readers — including the audit's own evidence files — already
    ///      measure. Its unchecked overflow past ~1.16e75 is likewise deliberate and unchanged:
    ///      test_ATK_attesterCanBrickMintingViaBufferOverflow pins it as the one thing an attester
    ///      can do here (shut minting, never widen it) and proves redemption survives it.
    function capacity18(address asset) external view returns (uint256) {
        int256 b = _balance[asset];
        if (b <= 0) return 0;
        return uint256(b) * 100;
    }
}
