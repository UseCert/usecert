// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ILighter} from "./interfaces/ILighter.sol";
import {ICertOracle} from "./interfaces/ICertOracle.sol";
import {ISolvencyRegistry} from "./interfaces/ISolvencyRegistry.sol";
import {ICapacityOracle} from "./interfaces/ICapacityOracle.sol";
import {Certificate} from "./Certificate.sol";
import {BufferBook} from "./BufferBook.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice One vault per asset. The vault IS a registered Lighter master account and submits its
///         own orders, deposits and withdrawals — there is no privileged trading key anywhere in
///         this contract (Law 6). Certificates are minted at oracle price at delta 1.0, never as
///         pro-rata account shares.
contract CertVault {
    using SafeERC20 for IERC20;

    error CertVault_NotBootstrapped();
    error CertVault_AlreadyBootstrapped();
    error CertVault_MintPaused();
    error CertVault_AtCapacity();
    error CertVault_AboveInstantCap();
    error CertVault_BelowInstantCap();
    error CertVault_BadReceipt();

    event Minted(address indexed user, uint256 amountIn, uint256 certOut, uint256 px18, uint256 fee);
    event MintRequested(uint256 indexed receiptId, address indexed user, uint256 amountIn);
    event MintSettled(uint256 indexed receiptId, uint256 certOut, uint256 fillPx18);

    struct Deps {
        address lighter;
        address oracle;
        address registry;
        address capacity;
        address governance;
    }

    struct VaultConfig {
        address collateral;
        uint16 collateralAssetIndex;
        uint8 routeType;
        uint16 marketIndex;
        uint8 sizeDecimals;
        uint256 mintFeeBps;
        uint256 redeemFeeBps;
        uint256 instantCap18;
    }

    struct MintReceipt {
        address user;
        uint256 escrow;
        bool settled;
    }

    uint8 internal constant ORDER_TYPE_MARKET = 1;
    uint8 internal constant SIDE_BID = 0;
    uint8 internal constant SIDE_ASK = 1;

    ILighter public immutable lighter;
    ICertOracle public immutable oracle;
    ISolvencyRegistry public immutable registry;
    ICapacityOracle public immutable capacity;
    address public immutable governance;
    Certificate public immutable certificate;
    BufferBook public immutable buffer;

    VaultConfig public cfg;
    uint8 private immutable _collateralDecimals;

    bool public bootstrapped;
    uint256 private _nextReceiptId = 1;
    mapping(uint256 => MintReceipt) public mintReceipts;

    constructor(Deps memory d, VaultConfig memory c, string memory name_, string memory symbol_) {
        lighter = ILighter(d.lighter);
        oracle = ICertOracle(d.oracle);
        registry = ISolvencyRegistry(d.registry);
        capacity = ICapacityOracle(d.capacity);
        governance = d.governance;
        cfg = c;
        _collateralDecimals = IERC20Metadata(c.collateral).decimals();

        certificate = new Certificate(name_, symbol_, address(this));
        buffer = new BufferBook(address(this), 200);
        buffer.configure(address(this), 100_000e18, 60_000e18, 30_000e18, 0);
    }

    // ---------------------------------------------------------------- bootstrap

    /// @notice One-time dust deposit so Lighter assigns this contract an account index.
    /// @dev createOrder reverts with AccountIsNotRegistered until the registering deposit has
    ///      been executed by a batch, so this must land before any mint. The vault must already
    ///      hold at least `dust` of collateral (e.g. via seedBuffer) before this is called.
    function bootstrap() external {
        if (bootstrapped) revert CertVault_AlreadyBootstrapped();
        bootstrapped = true;
        uint256 dust = 10 ** _collateralDecimals;
        IERC20(cfg.collateral).forceApprove(address(lighter), dust);
        lighter.deposit(address(this), cfg.collateralAssetIndex, cfg.routeType, dust);
    }

    function lighterAccountIndex() public view returns (uint48) {
        return lighter.addressToAccountIndex(address(this));
    }

    /// @notice Pre-fund the buffer. Permissionless: it can only ever add value to the vault.
    function seedBuffer(uint256 amount) external {
        IERC20(cfg.collateral).safeTransferFrom(msg.sender, address(this), amount);
        buffer.accrue(address(this), int256(_to18(amount)));
    }

    // ---------------------------------------------------------------- mint

    function mintInstant(uint256 amountIn) external returns (uint256 certOut) {
        if (!bootstrapped) revert CertVault_NotBootstrapped();
        if (!oracle.mintAllowed()) revert CertVault_MintPaused();

        uint256 px18 = oracle.px();
        uint256 fee = amountIn * cfg.mintFeeBps / 10_000;
        uint256 net18 = _to18(amountIn - fee);
        certOut = net18 * 1e18 / px18;

        uint256 notional18 = certOut * px18 / 1e18;
        if (notional18 > cfg.instantCap18) revert CertVault_AboveInstantCap();
        _requireCapacity(notional18);

        IERC20(cfg.collateral).safeTransferFrom(msg.sender, address(this), amountIn);
        certificate.mint(msg.sender, certOut);
        _hedge(certOut, px18, SIDE_BID);

        emit Minted(msg.sender, amountIn, certOut, px18, fee);
    }

    function requestMint(uint256 amountIn) external returns (uint256 receiptId) {
        if (!bootstrapped) revert CertVault_NotBootstrapped();
        if (!oracle.mintAllowed()) revert CertVault_MintPaused();

        uint256 px18 = oracle.px();
        uint256 fee = amountIn * cfg.mintFeeBps / 10_000;
        uint256 net18 = _to18(amountIn - fee);
        uint256 indicative = net18 * 1e18 / px18;
        uint256 notional18 = indicative * px18 / 1e18;
        if (notional18 <= cfg.instantCap18) revert CertVault_BelowInstantCap();
        _requireCapacity(notional18);

        IERC20(cfg.collateral).safeTransferFrom(msg.sender, address(this), amountIn);
        receiptId = _nextReceiptId++;
        mintReceipts[receiptId] = MintReceipt({user: msg.sender, escrow: amountIn - fee, settled: false});

        _hedge(indicative, px18, SIDE_BID);
        emit MintRequested(receiptId, msg.sender, amountIn);
    }

    /// @notice Mint at the price actually filled, so the vault carries no execution risk on
    ///         large mints. Permissionless — the fill price is checkable against the attestation.
    function settleMint(uint256 receiptId, uint256 fillPx18) external {
        MintReceipt storage r = mintReceipts[receiptId];
        if (r.user == address(0) || r.settled) revert CertVault_BadReceipt();
        r.settled = true;

        uint256 certOut = _to18(r.escrow) * 1e18 / fillPx18;
        certificate.mint(r.user, certOut);
        emit MintSettled(receiptId, certOut, fillPx18);
    }

    // ---------------------------------------------------------------- internals

    function _requireCapacity(uint256 addNotional18) internal view {
        uint256 max = capacity.maxNotional18(address(this), buffer.capacity18(address(this)));
        uint256 current = registry.latest(address(this)).notional18;
        if (current + addNotional18 > max) revert CertVault_AtCapacity();
    }

    /// @dev Submits the vault's own order through Lighter's priority queue. Market order because
    ///      the on-chain path exposes no IOC or post-only flag; price is passed as the guard band.
    function _hedge(uint256 certAmount18, uint256 px18, uint8 side) internal {
        uint48 baseAmount = uint48(certAmount18 * (10 ** cfg.sizeDecimals) / 1e18);
        uint32 tickPx = oracle.toTickPrice(px18);
        lighter.createOrder(lighterAccountIndex(), cfg.marketIndex, baseAmount, tickPx, side, ORDER_TYPE_MARKET);
    }

    function _to18(uint256 amount) internal view returns (uint256) {
        return _collateralDecimals <= 18
            ? amount * (10 ** (18 - _collateralDecimals))
            : amount / (10 ** (_collateralDecimals - 18));
    }

    function _from18(uint256 amount18) internal view returns (uint256) {
        return _collateralDecimals <= 18
            ? amount18 / (10 ** (18 - _collateralDecimals))
            : amount18 * (10 ** (_collateralDecimals - 18));
    }
}
