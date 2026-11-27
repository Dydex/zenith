// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ZenithHook} from "../src/ZenithHook.sol";
import {ZenithTestBase} from "./utils/ZenithTestBase.sol";

/// @notice Depositor shares: in-kind deposits at the sleeve's ratio, and pro-rata withdrawals of idle tokens and
/// positions alike, without the curator's involvement or effect on its score.
contract ZenithSharesTest is ZenithTestBase {
    address internal curator = makeAddr("curator");
    address internal alice = makeAddr("alice");
    uint256 internal sleeve;

    function setUp() public override {
        super.setUp();
        _addExternalLiquidity(-6000, 6000, 1000e18);
        hook.fund(hook.CONTROL_SLEEVE(), 100e18, 100e18);
        hook.deployControl();
        sleeve = hook.openSleeve(curator);
        _give(alice, 1000e18);
    }

    function test_firstDepositSetsTheRatioAndLaterDepositsMatchIt() public {
        vm.prank(alice);
        (uint256 first, uint128 a0, uint128 a1) = hook.fund(sleeve, 30e18, 10e18);
        assertEq(a0, 30e18);
        assertEq(a1, 10e18);

        // Offer far more token1 than the 3:1 ratio needs: only the matching amount is taken.
        uint256 before1 = currency1.balanceOf(alice);
        vm.prank(alice);
        (uint256 second, uint128 b0, uint128 b1) = hook.fund(sleeve, 3e18, 50e18);
        // The maxima are padded by a few wei so per-range rounding can never charge more than offered.
        assertLe(b0, 3e18, "never more than offered");
        assertApproxEqAbs(b0, 3e18, 2, "token0 limits the deposit");
        assertApproxEqAbs(b1, 1e18, 2, "token1 taken at the sleeve's ratio");
        assertEq(before1 - currency1.balanceOf(alice), b1, "only what was used was pulled");
        assertApproxEqRel(second, first / 10, 1e12, "a tenth of the holdings, a tenth of the shares");
        _assertLedgerEqualsClaims();
    }

    function test_withdrawReturnsAFractionOfIdleAndPositions() public {
        vm.prank(alice);
        (uint256 shares,,) = hook.fund(sleeve, 100e18, 100e18);
        _shape(-600, 600, 1000e18);
        uint128 deployed = hook.getRanges(sleeve)[0].liquidity;
        ZenithHook.Sleeve memory s = hook.getSleeve(sleeve);

        uint256 before0 = currency0.balanceOf(alice);
        vm.prank(alice);
        (uint256 out0, uint256 out1) = hook.withdraw(sleeve, shares / 4, alice);

        assertEq(hook.getRanges(sleeve)[0].liquidity, deployed - deployed / 4, "a quarter of the position removed");
        assertApproxEqRel(out0, 25e18, 1e12, "a quarter of all token0");
        assertApproxEqRel(out1, 25e18, 1e12, "a quarter of all token1");
        assertEq(currency0.balanceOf(alice) - before0, out0, "tokens reached the owner");
        assertEq(hook.getSleeve(sleeve).idle0, s.idle0 - s.idle0 / 4, "a quarter of idle token0 left");
        _assertRangesMatchPool(sleeve);
        _assertLedgerEqualsClaims();
    }

    function test_fullExitEmptiesTheSleeve() public {
        vm.prank(alice);
        (uint256 shares,,) = hook.fund(sleeve, 100e18, 100e18);
        _shape(-600, 600, 1000e18);
        _trade(true, -5e18);

        vm.prank(alice);
        hook.withdraw(sleeve, shares, alice);

        assertEq(hook.getRanges(sleeve).length, 0, "positions closed");
        assertEq(hook.totalShares(sleeve), 0);
        ZenithHook.Sleeve memory s = hook.getSleeve(sleeve);
        assertEq(s.idle0, 0);
        assertEq(s.idle1, 0);
        assertEq(_positionLiquidity(sleeve, -600, 600), 0, "nothing left in the pool");
        _assertLedgerEqualsClaims();
    }

    function test_onlyShareOwnersCanWithdraw() public {
        vm.prank(alice);
        (uint256 shares,,) = hook.fund(sleeve, 100e18, 100e18);
        vm.prank(curator);
        vm.expectRevert(ZenithHook.InsufficientShares.selector);
        hook.withdraw(sleeve, 1, curator);
        vm.prank(alice);
        vm.expectRevert(ZenithHook.InsufficientShares.selector);
        hook.withdraw(sleeve, shares + 1, alice);
        vm.prank(alice);
        vm.expectRevert(ZenithHook.InsufficientShares.selector);
        hook.withdraw(sleeve, 0, alice);
    }

    function test_flowsDoNotMoveTheCuratorsScore() public {
        vm.prank(alice);
        (uint256 shares,,) = hook.fund(sleeve, 100e18, 100e18);
        _shape(-600, 600, 1000e18);
        for (uint256 i; i < 5; ++i) {
            _trade(true, -10e18);
            _trade(false, -10e18);
        }
        hook.poke(sleeve);
        int256 before = hook.getScore(sleeve).excess;

        vm.prank(alice);
        hook.withdraw(sleeve, shares / 2, alice);
        vm.prank(alice);
        hook.fund(sleeve, 20e18, 20e18);
        for (uint256 i; i < 5; ++i) {
            _trade(true, -10e18);
            _trade(false, -10e18);
        }
        hook.poke(sleeve);
        // The curator never changed its shape, so depositors coming and going must not create skill or blame.
        assertApproxEqAbs(hook.getScore(sleeve).excess, before, 1e9, "flows are not timing");
    }

    /// @notice A later deposit buys into the positions, not just the idle balance: every range grows by the
    /// deposit's fraction, so the new money earns fees from the moment it arrives and takes none it did not earn.
    function test_depositAddsTheSameFractionToEveryPosition() public {
        vm.prank(alice);
        (uint256 shares,,) = hook.fund(sleeve, 100e18, 100e18);
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](2);
        shape[0] = _range(-600, 600, 600e18);
        shape[1] = _range(-1200, -600, 100e18);
        vm.prank(curator);
        hook.setShape(sleeve, shape);
        ZenithHook.Sleeve memory s = hook.getSleeve(sleeve);

        vm.prank(alice);
        (uint256 added,,) = hook.fund(sleeve, 10e18, 10e18);

        assertApproxEqRel(added, shares / 10, 1e15, "about a tenth more shares");
        uint256 supply = hook.totalShares(sleeve);
        ZenithHook.Range[] memory ranges = hook.getRanges(sleeve);
        for (uint256 i; i < 2; ++i) {
            assertEq(ranges[i].liquidity, shape[i].liquidity + shape[i].liquidity * added / shares, "range grew");
            assertApproxEqRel(uint256(ranges[i].liquidity) * shares, uint256(shape[i].liquidity) * supply, 1e9);
        }
        assertApproxEqRel(hook.getSleeve(sleeve).idle0, uint256(s.idle0) * supply / shares, 1e9, "idle grew too");
        _assertRangesMatchPool(sleeve);
        _assertLedgerEqualsClaims();
    }

    /// @notice Whatever the shape, price and offer, a deposit never charges more than offered, keeps the ledger
    /// whole, and an immediate round trip returns no more than was paid.
    function testFuzz_depositIntoPositionsIsBoundedAndRoundTripsSafely(
        uint256 shapeSeed,
        uint256 offer0,
        uint256 offer1,
        bool moved
    ) public {
        vm.prank(alice);
        hook.fund(sleeve, 100e18, 100e18);
        ZenithHook.Range[] memory shape = _randomShape(shapeSeed);
        vm.prank(curator);
        try hook.setShape(sleeve, shape) {} catch {}
        if (moved) _trade(shapeSeed % 2 == 0, -int256(bound(shapeSeed >> 8, 1e15, 30e18)));

        uint128 max0 = uint128(bound(offer0, 0, 300e18));
        uint128 max1 = uint128(bound(offer1, 0, 300e18));
        address bob = makeAddr("bob");
        _give(bob, 1000e18);
        vm.prank(bob);
        try hook.fund(sleeve, max0, max1) returns (uint256 shares, uint128 paid0, uint128 paid1) {
            assertLe(paid0, max0, "never more token0 than offered");
            assertLe(paid1, max1, "never more token1 than offered");
            _assertRangesMatchPool(sleeve);
            _assertLedgerEqualsClaims();

            vm.prank(bob);
            (uint256 out0, uint256 out1) = hook.withdraw(sleeve, shares, bob);
            assertLe(out0, paid0, "no token0 gained by a round trip");
            assertLe(out1, paid1, "no token1 gained by a round trip");
            _assertLedgerEqualsClaims();
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), ZenithHook.ZeroDeposit.selector, "only an empty deposit may fail");
        }
    }

    function _shape(int24 lower, int24 upper, uint128 liquidity) internal {
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](1);
        shape[0] = _range(lower, upper, liquidity);
        vm.prank(curator);
        hook.setShape(sleeve, shape);
    }

    function _give(address to, uint256 amount) internal {
        for (uint256 i; i < 2; ++i) {
            MockERC20 token = MockERC20(Currency.unwrap(i == 0 ? currency0 : currency1));
            token.mint(to, amount);
            vm.prank(to);
            token.approve(address(hook), type(uint256).max);
        }
    }
}
