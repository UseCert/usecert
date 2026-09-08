// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @notice Per-asset accrual of funding, execution variance and realised basis, with published
///         thresholds. Positive accrual fattens the buffer; negative draws it down. Past feeOn a
///         holding fee activates, ramping linearly to an immutable cap. Nothing here is hidden —
///         every threshold and the live balance are readable on-chain (Law 3).
/// @dev The insurance draw is exposed as a number and an event only. C3's InsuranceStaking reads
///      it; this contract never needs to change to support that.
contract BufferBook {
    error BufferBook_OnlyVault();

    event ThresholdCrossed(address indexed asset, uint8 level);
    event Accrued(address indexed asset, int256 delta18, int256 balance18);

    struct Config {
        uint256 floor18;
        uint256 feeOn18;
        uint256 mintSlow18;
        uint256 insuranceDraw18;
        bool set;
    }

    address public immutable vault;
    /// @dev maximum holding fee in bps, immutable at deploy (Law 3: bounded, published)
    uint256 public immutable feeCapBps;

    mapping(address => Config) public config;
    mapping(address => int256) private _balance;

    constructor(address _vault, uint256 _feeCapBps) {
        vault = _vault;
        feeCapBps = _feeCapBps;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert BufferBook_OnlyVault();
        _;
    }

    function configure(address asset, uint256 floor18, uint256 feeOn18, uint256 mintSlow18, uint256 insuranceDraw18)
        external
        onlyVault
    {
        config[asset] = Config(floor18, feeOn18, mintSlow18, insuranceDraw18, true);
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

    function balance18(address asset) external view returns (int256) {
        return _balance[asset];
    }

    /// @notice Linear ramp from 0 at feeOn to feeCapBps at empty. Never exceeds the cap.
    function holdingFeeBps(address asset) external view returns (uint256) {
        Config memory c = config[asset];
        int256 b = _balance[asset];
        if (b >= int256(c.feeOn18)) return 0;
        if (b <= 0) return feeCapBps;
        if (c.feeOn18 == 0) return 0;

        uint256 shortfall = c.feeOn18 - uint256(b);
        uint256 fee = (shortfall * feeCapBps + c.feeOn18 / 2) / c.feeOn18;
        return fee > feeCapBps ? feeCapBps : fee;
    }

    function mintSlowed(address asset) external view returns (bool) {
        return _balance[asset] < int256(config[asset].mintSlow18);
    }

    function insuranceDrawNeeded(address asset) external view returns (uint256) {
        int256 b = _balance[asset];
        int256 threshold = int256(config[asset].insuranceDraw18);
        if (b >= threshold) return 0;
        return uint256(threshold - b);
    }

    /// @notice What the buffer can absorb, fed into CapacityOracle's min().
    /// @dev Buffer must cover a plausible adverse move on the whole book, so capacity is a
    ///      multiple of the buffer rather than the buffer itself. Multiplier is the ratio of
    ///      floor to a 1% adverse move: capacity = balance * 100.
    function capacity18(address asset) external view returns (uint256) {
        int256 b = _balance[asset];
        if (b <= 0) return 0;
        return uint256(b) * 100;
    }
}
