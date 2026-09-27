// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {BuybackForwarder, ICertStakingFunding} from "../src/BuybackForwarder.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice USDG with the issuer's freeze: a blocked address can neither send nor receive.
contract FreezableERC20 is MockERC20 {
    error Frozen(address account);

    mapping(address => bool) public frozen;

    constructor() MockERC20("USDG", "USDG", 6) {}

    function setFrozen(address account, bool f) external {
        frozen[account] = f;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (frozen[from]) revert Frozen(from);
        if (frozen[to]) revert Frozen(to);
        super._update(from, to, value);
    }
}

/// @notice The funding surface of the next CertStaking version: notifyRewardAmount pulls from the
///         caller (as CertStaking does), and minNotify is settable.
contract MockCertStaking is ICertStakingFunding {
    IERC20 public immutable rewardToken;
    uint256 public minNotify;
    uint256 public totalNotified;
    uint256 public notifyCount;

    constructor(IERC20 rewardToken_, uint256 min_) {
        rewardToken = rewardToken_;
        minNotify = min_;
    }

    function setMinNotify(uint256 m) external {
        minNotify = m;
    }

    function notifyRewardAmount(uint256 amount) external {
        require(amount > 0 && amount >= minNotify, "below min");
        rewardToken.transferFrom(msg.sender, address(this), amount);
        totalNotified += amount;
        notifyCount++;
    }
}

/// @notice The earlier CertStaking shape: no minNotify.
contract StakingWithoutMin {
    IERC20 public immutable rewardToken;

    constructor(IERC20 t) {
        rewardToken = t;
    }

    function notifyRewardAmount(uint256) external {}
}

/// @notice K2: the fixed fee split, credited by distribute() and paid by claim(). Most tests use
///         80/10/5/5 only as a shape, with neutral names; test_mainnetSplit_order_and_bps pins
///         the deployment's recipient order and shares.
contract FeeVaultTest is Test {
    FreezableERC20 usdg;
    FeeVault fv;

    address a = makeAddr("recipientA");
    address b = makeAddr("recipientB");
    address c = makeAddr("recipientC");
    address d = makeAddr("recipientD");

    function _four() internal view returns (address[] memory r, uint256[] memory s) {
        r = new address[](4);
        s = new uint256[](4);
        (r[0], r[1], r[2], r[3]) = (a, b, c, d);
        (s[0], s[1], s[2], s[3]) = (8_000, 1_000, 500, 500);
    }

    function setUp() public {
        usdg = new FreezableERC20();
        (address[] memory r, uint256[] memory s) = _four();
        fv = new FeeVault(IERC20(address(usdg)), r, s);
    }

    function _claimAll() internal {
        fv.claim(a);
        fv.claim(b);
        fv.claim(c);
        fv.claim(d);
    }

    function _sumOwed() internal view returns (uint256) {
        return fv.owed(a) + fv.owed(b) + fv.owed(c) + fv.owed(d);
    }

    // ------------------------------------------------------------------ construction

    function test_configIsReadable() public view {
        assertEq(fv.recipientCount(), 4);
        (address r0, uint256 s0) = fv.recipientAt(0);
        (address r3, uint256 s3) = fv.recipientAt(3);
        assertEq(r0, a);
        assertEq(s0, 8_000);
        assertEq(r3, d);
        assertEq(s3, 500);
        assertEq(address(fv.asset()), address(usdg));
    }

    /// CertVault.setFeeSink reads `asset()` through an interface returning an address; the
    /// selector and the ABI word must match that call exactly.
    function test_assetIsCallableAsAnAddressGetter() public view {
        (bool ok, bytes memory ret) = address(fv).staticcall(abi.encodeWithSignature("asset()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (address)), address(usdg));
    }

    function test_rejectsSharesThatDoNotSumToExactly10000() public {
        (address[] memory r, uint256[] memory s) = _four();
        s[3] = 499; // 9_999
        vm.expectRevert(FeeVault.FeeVault_SharesDoNotSumTo10000.selector);
        new FeeVault(IERC20(address(usdg)), r, s);
        s[3] = 501; // 10_001
        vm.expectRevert(FeeVault.FeeVault_SharesDoNotSumTo10000.selector);
        new FeeVault(IERC20(address(usdg)), r, s);
    }

    function test_rejectsZeroAddresses() public {
        (address[] memory r, uint256[] memory s) = _four();
        vm.expectRevert(FeeVault.FeeVault_ZeroAddress.selector);
        new FeeVault(IERC20(address(0)), r, s);
        r[2] = address(0);
        vm.expectRevert(FeeVault.FeeVault_ZeroAddress.selector);
        new FeeVault(IERC20(address(usdg)), r, s);
    }

    function test_rejectsZeroAndNineRecipients() public {
        vm.expectRevert(FeeVault.FeeVault_BadRecipientCount.selector);
        new FeeVault(IERC20(address(usdg)), new address[](0), new uint256[](0));

        address[] memory r = new address[](9);
        uint256[] memory s = new uint256[](9);
        for (uint256 i = 0; i < 9; i++) {
            r[i] = address(uint160(0x1000 + i));
            s[i] = i == 0 ? 2_000 : 1_000;
        }
        vm.expectRevert(FeeVault.FeeVault_BadRecipientCount.selector);
        new FeeVault(IERC20(address(usdg)), r, s);
    }

    function test_acceptsOneAndEightRecipients() public {
        address[] memory one = new address[](1);
        uint256[] memory full = new uint256[](1);
        one[0] = a;
        full[0] = 10_000;
        new FeeVault(IERC20(address(usdg)), one, full);

        address[] memory r = new address[](8);
        uint256[] memory s = new uint256[](8);
        for (uint256 i = 0; i < 8; i++) {
            r[i] = address(uint160(0x1000 + i));
            s[i] = 1_250;
        }
        new FeeVault(IERC20(address(usdg)), r, s);
    }

    function test_rejectsLengthMismatchZeroShareAndDuplicate() public {
        (address[] memory r, uint256[] memory s) = _four();
        uint256[] memory three = new uint256[](3);
        (three[0], three[1], three[2]) = (8_000, 1_000, 1_000);
        vm.expectRevert(FeeVault.FeeVault_LengthMismatch.selector);
        new FeeVault(IERC20(address(usdg)), r, three);

        s[2] = 0;
        s[3] = 1_000;
        vm.expectRevert(FeeVault.FeeVault_ZeroShare.selector);
        new FeeVault(IERC20(address(usdg)), r, s);

        (r, s) = _four();
        r[3] = a;
        vm.expectRevert(FeeVault.FeeVault_DuplicateRecipient.selector);
        new FeeVault(IERC20(address(usdg)), r, s);
    }

    // ------------------------------------------------------------------ distribute + claim

    function test_distributeCreditsAndMovesNothing_thenClaimPays() public {
        usdg.mint(address(fv), 1_000e6);
        vm.prank(makeAddr("anyone")); // permissionless
        uint256 out = fv.distribute();
        assertEq(out, 1_000e6);
        assertEq(fv.owed(a), 800e6);
        assertEq(fv.owed(b), 100e6);
        assertEq(fv.owed(c), 50e6);
        assertEq(fv.owed(d), 50e6);
        assertEq(fv.totalOwed(), 1_000e6);
        assertEq(usdg.balanceOf(address(fv)), 1_000e6, "distribute moved tokens");
        assertEq(usdg.balanceOf(a), 0);

        // Anyone may claim for a recipient; the tokens go to the recipient, never the caller.
        address caller = makeAddr("keeper");
        vm.prank(caller);
        assertEq(fv.claim(a), 800e6);
        assertEq(usdg.balanceOf(a), 800e6);
        assertEq(usdg.balanceOf(caller), 0);
        assertEq(fv.owed(a), 0);
        assertEq(fv.totalOwed(), 200e6);

        fv.claim(b);
        fv.claim(c);
        fv.claim(d);
        assertEq(usdg.balanceOf(b), 100e6);
        assertEq(usdg.balanceOf(c), 50e6);
        assertEq(usdg.balanceOf(d), 50e6);
        assertEq(usdg.balanceOf(address(fv)), 0);
        assertEq(fv.totalOwed(), 0);
    }

    function test_claimForANonRecipientOrTwiceIsANoOp() public {
        usdg.mint(address(fv), 1_000e6);
        fv.distribute();
        assertEq(fv.claim(makeAddr("stranger")), 0);
        assertEq(fv.claim(a), 800e6);
        assertEq(fv.claim(a), 0);
        assertEq(usdg.balanceOf(a), 800e6);
    }

    /// A second distribute with no new income credits nothing: what is owed is not re-split.
    function test_repeatedDistributeDoesNotRecreditOwedIncome() public {
        usdg.mint(address(fv), 1_000e6);
        fv.distribute();
        assertEq(fv.distribute(), 0);
        assertEq(fv.distribute(), 0);
        assertEq(fv.owed(a), 800e6);
        assertEq(fv.totalOwed(), 1_000e6);

        usdg.mint(address(fv), 100e6); // only the new income is split
        assertEq(fv.distribute(), 100e6);
        assertEq(fv.owed(a), 880e6);
        assertEq(fv.owed(d), 55e6);
        assertEq(fv.totalOwed(), 1_100e6);
    }

    // ------------------------------------------------------------------ L-2: a frozen recipient

    /// The finding: one recipient that cannot receive used to stall every distribute(). Now it
    /// fails only its own claim; its credit stays booked for it, the others are paid, and later
    /// income keeps flowing.
    function test_frozenRecipientBlocksOnlyItsOwnClaim() public {
        usdg.setFrozen(b, true);
        usdg.mint(address(fv), 1_000e6);
        fv.distribute();

        vm.expectRevert(abi.encodeWithSelector(FreezableERC20.Frozen.selector, b));
        fv.claim(b);
        assertEq(fv.owed(b), 100e6, "the failed claim must leave the credit booked");
        assertEq(fv.totalOwed(), 1_000e6);

        fv.claim(a);
        fv.claim(c);
        fv.claim(d);
        assertEq(usdg.balanceOf(a), 800e6);
        assertEq(usdg.balanceOf(c), 50e6);
        assertEq(usdg.balanceOf(d), 50e6);

        // Future income: distribute still works and b's share is never re-split to the others.
        usdg.mint(address(fv), 500e6);
        assertEq(fv.distribute(), 500e6);
        assertEq(fv.owed(a), 400e6);
        assertEq(fv.owed(b), 150e6);
        fv.claim(a);
        assertEq(usdg.balanceOf(a), 1_200e6);
        assertEq(usdg.balanceOf(address(fv)), fv.totalOwed());

        // Unfrozen, b is paid everything it was credited while frozen.
        usdg.setFrozen(b, false);
        assertEq(fv.claim(b), 150e6);
        assertEq(usdg.balanceOf(b), 150e6);
    }

    /// A paused / globally frozen token fails every claim, but nothing is lost: distribute keeps
    /// booking, and every claim pays once the token works again.
    function test_frozenVaultFailsClaimsButDistributeStillBooks() public {
        usdg.mint(address(fv), 1_000e6);
        usdg.setFrozen(address(fv), true);
        assertEq(fv.distribute(), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(FreezableERC20.Frozen.selector, address(fv)));
        fv.claim(a);
        usdg.setFrozen(address(fv), false);
        _claimAll();
        assertEq(usdg.balanceOf(a), 800e6);
        assertEq(usdg.balanceOf(address(fv)), 0);
    }

    // ------------------------------------------------------------------ dust

    /// 7 units at 80/10/5/5 floors to 5/0/0/0: two units stay uncredited, and the next
    /// distribute() splits them as part of the new income, not lost.
    function test_dustStaysUncreditedAndIsCarriedIntoTheNextDistribute() public {
        usdg.mint(address(fv), 7);
        assertEq(fv.distribute(), 5);
        assertEq(fv.owed(a), 5);
        assertEq(fv.owed(b), 0);
        assertEq(fv.uncredited(), 2, "the dust stayed uncredited");
        fv.claim(a); // claiming does not disturb the dust

        usdg.mint(address(fv), 18); // 20 uncredited now
        assertEq(fv.distribute(), 20);
        assertEq(fv.owed(a), 16);
        assertEq(fv.owed(b), 2);
        assertEq(fv.owed(c), 1);
        assertEq(fv.owed(d), 1);
        assertEq(fv.uncredited(), 0, "the carried dust was credited");
        _claimAll();
        assertEq(usdg.balanceOf(a), 5 + 16);
        assertEq(usdg.balanceOf(address(fv)), 0);
    }

    function test_emptyDistributeIsANoOp() public {
        assertEq(fv.distribute(), 0);
        assertEq(fv.totalOwed(), 0);
    }

    // ------------------------------------------------------------------ fuzz

    /// Conservation for any balance: credited plus uncredited equals what arrived, and the
    /// uncredited part is strictly less than one unit per recipient.
    function testFuzz_splitConservesAndDustIsBounded(uint256 bal) public {
        bal = bound(bal, 0, type(uint128).max);
        usdg.mint(address(fv), bal);
        uint256 out = fv.distribute();
        assertEq(_sumOwed(), out);
        assertEq(fv.totalOwed(), out);
        assertEq(out + fv.uncredited(), bal);
        assertLt(fv.uncredited(), 4);
        assertEq(fv.owed(a), bal * 8_000 / 10_000);
    }

    /// Any interleaving of income, distributes, claims and freezes: the vault never owes more
    /// than it holds, totalOwed is exactly the sum of what each recipient is owed, and every
    /// unit that arrived is either paid out, owed, or (under 4 units) uncredited dust.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_repeatedDistributesNeverOverCredit(uint256 seed) public {
        address[4] memory rs = [a, b, c, d];
        uint256 minted;
        for (uint256 step = 0; step < 32; step++) {
            uint256 rnd = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = rnd % 5;
            if (op == 0) {
                uint256 amt = (rnd >> 8) % 1_000_000e6;
                usdg.mint(address(fv), amt);
                minted += amt;
            } else if (op == 1) {
                fv.distribute();
            } else if (op == 2) {
                address r = rs[(rnd >> 8) % 4];
                try fv.claim(r) {} catch {}
            } else if (op == 3) {
                address r = rs[(rnd >> 8) % 4];
                usdg.setFrozen(r, !usdg.frozen(r));
            } else {
                fv.distribute();
                fv.distribute(); // a back-to-back repeat must credit nothing new
            }
            uint256 held = usdg.balanceOf(address(fv));
            assertEq(fv.totalOwed(), _sumOwed(), "totalOwed != sum(owed)");
            assertLe(fv.totalOwed(), held, "over-credited");
            uint256 paid = usdg.balanceOf(a) + usdg.balanceOf(b) + usdg.balanceOf(c) + usdg.balanceOf(d);
            assertEq(paid + held, minted, "units created or destroyed");
        }
        fv.distribute();
        assertLt(fv.uncredited(), 4, "more than dust left uncredited after a distribute");
    }

    // ------------------------------------------------------------------ the mainnet split

    /// The deployment's recipients IN ORDER, with the owner's 70/20/5/5 (2026-09-26): stakers
    /// (InsuranceStaking), the buyback leg (a BuybackForwarder into CertStaking), keeper and ops
    /// gas (an EOA), the treasury (the 2-of-3 Safe). The forwarder is a real contract, so all
    /// four recipients are distinct and the constructor accepts them (pre-audit L-1), and the
    /// 20% reaches CERT stakers with no key in the path (L-15). Addresses other than the
    /// forwarder are placeholders; the order and the bps are what this pins.
    function test_mainnetSplit_order_and_bps() public {
        address insuranceStaking = makeAddr("InsuranceStaking");
        address opsWallet = makeAddr("keeperOpsGasEOA");
        address treasurySafe = makeAddr("treasurySafe2of3");
        MockCertStaking certStaking = new MockCertStaking(IERC20(address(usdg)), 1e6);
        BuybackForwarder forwarder = new BuybackForwarder(IERC20(address(usdg)), certStaking);

        address[] memory r = new address[](4);
        uint256[] memory s = new uint256[](4);
        (r[0], r[1], r[2], r[3]) = (insuranceStaking, address(forwarder), opsWallet, treasurySafe);
        (s[0], s[1], s[2], s[3]) = (7_000, 2_000, 500, 500);
        FeeVault mainnet = new FeeVault(IERC20(address(usdg)), r, s);

        assertEq(mainnet.recipientCount(), 4);
        uint256[4] memory wantBps = [uint256(7_000), 2_000, 500, 500];
        for (uint256 i = 0; i < 4; i++) {
            (address ri, uint256 si) = mainnet.recipientAt(i);
            assertEq(ri, r[i]);
            assertEq(si, wantBps[i]);
        }

        usdg.mint(address(mainnet), 12_345_678); // 12.345678 USDG of fees
        assertEq(mainnet.distribute(), 12_345_675);
        assertEq(mainnet.owed(insuranceStaking), 8_641_974);
        assertEq(mainnet.owed(address(forwarder)), 2_469_135);
        assertEq(mainnet.owed(opsWallet), 617_283);
        assertEq(mainnet.owed(treasurySafe), 617_283);
        assertEq(mainnet.uncredited(), 3, "floored dust stays for the next distribute");

        // The buyback leg end to end, driven by a stranger: claim into the forwarder, forward
        // into CertStaking.
        vm.startPrank(makeAddr("anyKeeper"));
        mainnet.claim(address(forwarder));
        assertEq(forwarder.forward(), 2_469_135);
        vm.stopPrank();
        assertEq(certStaking.totalNotified(), 2_469_135);
        assertEq(usdg.balanceOf(address(certStaking)), 2_469_135);
        assertEq(usdg.balanceOf(address(forwarder)), 0);
    }

    /// The configuration L-1 found: buyback and ops as the same address. Still refused, which is
    /// why the buyback leg is a forwarder.
    function test_mainnetSplit_withSharedBuybackAndOpsAddressIsRefused() public {
        address deployer = makeAddr("deployerEOA");
        address[] memory r = new address[](4);
        uint256[] memory s = new uint256[](4);
        (r[0], r[1], r[2], r[3]) = (makeAddr("InsuranceStaking"), deployer, deployer, makeAddr("treasurySafe2of3"));
        (s[0], s[1], s[2], s[3]) = (7_000, 2_000, 500, 500);
        vm.expectRevert(FeeVault.FeeVault_DuplicateRecipient.selector);
        new FeeVault(IERC20(address(usdg)), r, s);
    }
}

/// @notice The buyback leg: BuybackForwarder funds CertStaking and can do nothing else.
contract BuybackForwarderTest is Test {
    MockERC20 usdg;
    MockCertStaking staking;
    BuybackForwarder fwd;

    uint256 constant MIN = 100e6;

    function setUp() public {
        usdg = new MockERC20("USDG", "USDG", 6);
        staking = new MockCertStaking(IERC20(address(usdg)), MIN);
        fwd = new BuybackForwarder(IERC20(address(usdg)), staking);
    }

    function test_constructorBindsAndChecks() public {
        assertEq(address(fwd.usdg()), address(usdg));
        assertEq(address(fwd.staking()), address(staking));

        vm.expectRevert(BuybackForwarder.BuybackForwarder_ZeroAddress.selector);
        new BuybackForwarder(IERC20(address(0)), staking);
        vm.expectRevert(BuybackForwarder.BuybackForwarder_ZeroAddress.selector);
        new BuybackForwarder(IERC20(address(usdg)), ICertStakingFunding(address(0)));

        MockERC20 other = new MockERC20("X", "X", 6);
        vm.expectRevert(BuybackForwarder.BuybackForwarder_WrongRewardToken.selector);
        new BuybackForwarder(IERC20(address(other)), staking);

        // A staking contract without minNotify (the earlier CertStaking) is refused at deploy,
        // not discovered when every forward() reverts.
        StakingWithoutMin old = new StakingWithoutMin(IERC20(address(usdg)));
        vm.expectRevert();
        new BuybackForwarder(IERC20(address(usdg)), ICertStakingFunding(address(old)));
    }

    function test_belowMinSkipsAndMovesNothing() public {
        usdg.mint(address(fwd), MIN - 1);
        vm.expectEmit(address(fwd));
        emit BuybackForwarder.Skipped(MIN - 1, MIN);
        assertEq(fwd.forward(), 0);
        assertEq(usdg.balanceOf(address(fwd)), MIN - 1);
        assertEq(staking.notifyCount(), 0);
        assertEq(usdg.allowance(address(fwd), address(staking)), 0);
    }

    function test_zeroBalanceSkipsEvenWithZeroMin() public {
        staking.setMinNotify(0);
        assertEq(fwd.forward(), 0);
        assertEq(staking.notifyCount(), 0);
    }

    function test_atOrAboveMinFundsStakingAndLeavesNothingBehind() public {
        usdg.mint(address(fwd), MIN);
        address caller = makeAddr("anyone");
        vm.prank(caller);
        assertEq(fwd.forward(), MIN);
        assertEq(staking.totalNotified(), MIN);
        assertEq(usdg.balanceOf(address(staking)), MIN);
        assertEq(usdg.balanceOf(address(fwd)), 0);
        assertEq(usdg.balanceOf(caller), 0);
        assertEq(usdg.allowance(address(fwd), address(staking)), 0);

        usdg.mint(address(fwd), 1_234e6);
        assertEq(fwd.forward(), 1_234e6);
        assertEq(staking.totalNotified(), MIN + 1_234e6);
        assertEq(usdg.balanceOf(address(fwd)), 0);
        assertEq(usdg.allowance(address(fwd), address(staking)), 0);
    }

    /// The only function is forward(); every other call - the usual rescue, owner and sweep
    /// shapes, or plain ETH - reverts, and no token moves.
    function test_hasNoOtherWayToMoveFunds() public {
        usdg.mint(address(fwd), 1_000e6);
        address thief = makeAddr("thief");
        bytes[7] memory calls = [
            abi.encodeWithSignature("rescue(address,address,uint256)", address(usdg), thief, 1_000e6),
            abi.encodeWithSignature("withdraw(uint256)", 1_000e6),
            abi.encodeWithSignature("sweep(address,address)", address(usdg), thief),
            abi.encodeWithSignature("transferOwnership(address)", thief),
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature(
                "execute(address,bytes)", address(usdg), abi.encodeCall(IERC20.transfer, (thief, 1))
            ),
            bytes("")
        ];
        vm.startPrank(thief);
        vm.deal(thief, 1 ether);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok,) = address(fwd).call(calls[i]);
            assertFalse(ok);
        }
        (bool sent,) = address(fwd).call{value: 1}("");
        assertFalse(sent, "accepts ETH");
        vm.stopPrank();
        assertEq(usdg.balanceOf(address(fwd)), 1_000e6);
        assertEq(usdg.balanceOf(thief), 0);
        assertEq(usdg.allowance(address(fwd), thief), 0);
    }

    /// Any calldata from any caller: either it is forward() and the funds reach the bound staking
    /// contract, or it reverts. The caller never ends up with tokens or an allowance.
    function testFuzz_anyCallEitherFundsStakingOrReverts(address caller, bytes calldata data, uint96 bal) public {
        vm.assume(caller != address(fwd) && caller != address(staking));
        usdg.mint(address(fwd), bal);
        vm.prank(caller);
        (bool ok,) = address(fwd).call(data);
        bool isForward = data.length >= 4 && bytes4(data) == BuybackForwarder.forward.selector;
        if (!ok || !isForward) {
            // A revert or a view: nothing moved.
            assertEq(usdg.balanceOf(address(fwd)), bal);
        }
        assertEq(usdg.balanceOf(caller), 0);
        assertEq(usdg.allowance(address(fwd), caller), 0);
        assertEq(usdg.allowance(address(fwd), address(staking)), 0);
        assertEq(usdg.balanceOf(address(fwd)) + usdg.balanceOf(address(staking)), bal);
    }
}
