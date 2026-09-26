// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice K2: the fixed fee split. The split itself is NOT decided in code (the whitepaper and
///         the site disagree, see docs/K-INSURANCE-STAKING.md); these tests use 80/10/5/5 only as
///         a shape, with neutral names.
contract FeeVaultTest is Test {
    MockERC20 usdg;
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
        usdg = new MockERC20("USDG", "USDG", 6);
        (address[] memory r, uint256[] memory s) = _four();
        fv = new FeeVault(IERC20(address(usdg)), r, s);
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

    // ------------------------------------------------------------------ distribution

    function test_splitIsExactOnARoundBalance() public {
        usdg.mint(address(fv), 1_000e6);
        vm.prank(makeAddr("anyone")); // permissionless
        uint256 out = fv.distribute();
        assertEq(out, 1_000e6);
        assertEq(usdg.balanceOf(a), 800e6);
        assertEq(usdg.balanceOf(b), 100e6);
        assertEq(usdg.balanceOf(c), 50e6);
        assertEq(usdg.balanceOf(d), 50e6);
        assertEq(usdg.balanceOf(address(fv)), 0);
    }

    /// 7 units at 80/10/5/5 floors to 5/0/0/0: two units of dust stay, and they are paid out by
    /// the next distribute() as part of its balance, not lost.
    function test_dustStaysAndIsCarriedIntoTheNextDistribute() public {
        usdg.mint(address(fv), 7);
        fv.distribute();
        assertEq(usdg.balanceOf(a), 5);
        assertEq(usdg.balanceOf(b), 0);
        assertEq(usdg.balanceOf(address(fv)), 2, "the dust stayed");

        usdg.mint(address(fv), 18); // 20 in the vault now
        fv.distribute();
        assertEq(usdg.balanceOf(a), 5 + 16);
        assertEq(usdg.balanceOf(b), 2);
        assertEq(usdg.balanceOf(c), 1);
        assertEq(usdg.balanceOf(d), 1);
        assertEq(usdg.balanceOf(address(fv)), 0, "the carried dust was distributed");
    }

    function test_emptyDistributeIsANoOp() public {
        assertEq(fv.distribute(), 0);
    }

    /// Conservation for any balance: everything sent plus what stays equals what was there, and
    /// what stays is strictly less than one unit per recipient.
    function testFuzz_splitConservesAndDustIsBounded(uint256 bal) public {
        bal = bound(bal, 0, type(uint128).max);
        usdg.mint(address(fv), bal);
        uint256 out = fv.distribute();
        uint256 paid = usdg.balanceOf(a) + usdg.balanceOf(b) + usdg.balanceOf(c) + usdg.balanceOf(d);
        assertEq(paid, out);
        assertEq(paid + usdg.balanceOf(address(fv)), bal);
        assertLt(usdg.balanceOf(address(fv)), 4);
        assertEq(usdg.balanceOf(a), bal * 8_000 / 10_000);
    }
}
