// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {ZenithHook} from "../src/ZenithHook.sol";
import {ZenithTestBase} from "./utils/ZenithTestBase.sol";

contract ZenithShapesTest is ZenithTestBase {
    address internal curator = makeAddr("curator");
    uint256 internal sleeve;

    function setUp() public override {
        super.setUp();
        _addExternalLiquidity(-6000, 6000, 1000e18);
        hook.fund(hook.CONTROL_SLEEVE(), 10e18, 10e18); // curators can only shape against a live control
        hook.deployControl();
        sleeve = _openFundedSleeve(curator, 100e18, 100e18);
    }

    // ------------------------------------------------------------------
    // Setting shapes
    // ------------------------------------------------------------------

    function test_curatorShapeIsExecutedAsHookOwnedPositions() public {
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](2);
        shape[0] = _range(-600, 600, 1e18);
        shape[1] = _range(-120, 120, 2e18);

        vm.prank(curator);
        hook.setShape(sleeve, shape);

        assertEq(_positionLiquidity(sleeve, -600, 600), 1e18, "wide position");
        assertEq(_positionLiquidity(sleeve, -120, 120), 2e18, "narrow position");
        assertEq(hook.getRanges(sleeve).length, 2);

        ZenithHook.Sleeve memory s = hook.getSleeve(sleeve);
        assertLt(s.idle0, 100e18, "token0 deployed from idle");
        assertLt(s.idle1, 100e18, "token1 deployed from idle");
        _assertLedgerEqualsClaims();
    }

    function test_reshapeReplacesOldPositions() public {
        ZenithHook.Range[] memory first = new ZenithHook.Range[](1);
        first[0] = _range(-600, 600, 1e18);
        vm.prank(curator);
        hook.setShape(sleeve, first);

        ZenithHook.Range[] memory second = new ZenithHook.Range[](1);
        second[0] = _range(-1200, -60, 5e17);
        vm.prank(curator);
        hook.setShape(sleeve, second);

        assertEq(_positionLiquidity(sleeve, -600, 600), 0, "old position removed");
        assertEq(_positionLiquidity(sleeve, -1200, -60), 5e17, "new position added");
        _assertRangesMatchPool(sleeve);
        _assertLedgerEqualsClaims();
    }

    function test_emptyShapeReturnsFundsToIdle() public {
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](2);
        shape[0] = _range(-600, 600, 1e18);
        shape[1] = _range(-120, 120, 2e18);
        vm.prank(curator);
        hook.setShape(sleeve, shape);

        vm.prank(curator);
        hook.setShape(sleeve, new ZenithHook.Range[](0));

        ZenithHook.Sleeve memory s = hook.getSleeve(sleeve);
        // With no swaps in between, only rounding is lost: at most one wei per position per token.
        assertApproxEqAbs(s.idle0, 100e18, 2, "token0 back to idle");
        assertApproxEqAbs(s.idle1, 100e18, 2, "token1 back to idle");
        assertLe(s.idle0, 100e18, "rounding never favours the sleeve");
        assertEq(hook.getRanges(sleeve).length, 0);
        _assertLedgerEqualsClaims();
    }

    // ------------------------------------------------------------------
    // Who may shape, and what is a valid shape
    // ------------------------------------------------------------------

    function test_onlyCuratorCanSetShape() public {
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](1);
        shape[0] = _range(-600, 600, 1e18);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ZenithHook.NotCurator.selector);
        hook.setShape(sleeve, shape);
    }

    function test_controlSleeveCannotBeShaped() public {
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](1);
        shape[0] = _range(-600, 600, 1e18);
        uint256 control = hook.CONTROL_SLEEVE(); // read before expectRevert so it does not consume it
        vm.expectRevert(ZenithHook.ControlIsPassive.selector);
        hook.setShape(control, shape);
    }

    function test_rejectsInvalidRanges() public {
        int24 max = TickMath.maxUsableTick(60);
        ZenithHook.Range[5] memory bad = [
            _range(-600, 600, 0), // zero liquidity
            _range(600, -600, 1e18), // inverted
            _range(-590, 600, 1e18), // not aligned to tick spacing
            _range(-600, max + 60, 1e18), // beyond the usable range
            _range(0, 0, 1e18) // empty range
        ];
        for (uint256 i; i < bad.length; ++i) {
            ZenithHook.Range[] memory shape = new ZenithHook.Range[](1);
            shape[0] = bad[i];
            vm.prank(curator);
            vm.expectRevert(abi.encodeWithSelector(ZenithHook.InvalidRange.selector, 0));
            hook.setShape(sleeve, shape);
        }
    }

    function test_rejectsDuplicateRanges() public {
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](2);
        shape[0] = _range(-600, 600, 1e18);
        shape[1] = _range(-600, 600, 2e18);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ZenithHook.DuplicateRange.selector, 1));
        hook.setShape(sleeve, shape);
    }

    function test_rejectsTooManyRanges() public {
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](hook.MAX_RANGES() + 1);
        for (uint256 i; i < shape.length; ++i) {
            int24 offset = int24(int256(i)) * 60;
            shape[i] = _range(-600 - offset, 600 + offset, 1e17);
        }
        vm.prank(curator);
        vm.expectRevert(ZenithHook.TooManyRanges.selector);
        hook.setShape(sleeve, shape);
    }

    function test_cannotSpendMoreThanTheSleeveHolds() public {
        uint256 small = _openFundedSleeve(curator, 1e15, 1e15);
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](1);
        shape[0] = _range(-600, 600, 1e20);
        vm.prank(curator);
        vm.expectRevert(ZenithHook.InsufficientIdle.selector);
        hook.setShape(small, shape);
    }

    // ------------------------------------------------------------------
    // Fees and the control sleeve
    // ------------------------------------------------------------------

    function test_pokeCollectsFeesIntoIdle() public {
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](1);
        shape[0] = _range(-600, 600, 10e18);
        vm.prank(curator);
        hook.setShape(sleeve, shape);
        ZenithHook.Sleeve memory before = hook.getSleeve(sleeve);

        _trade(true, -1e18);
        _trade(false, -1e18);
        hook.poke(sleeve);

        ZenithHook.Sleeve memory afterPoke = hook.getSleeve(sleeve);
        assertGt(afterPoke.fees0, 0, "token0 fees earned");
        assertGt(afterPoke.fees1, 0, "token1 fees earned");
        assertEq(afterPoke.idle0 - before.idle0, afterPoke.fees0, "fees land in idle (token0)");
        assertEq(afterPoke.idle1 - before.idle1, afterPoke.fees1, "fees land in idle (token1)");
        assertEq(_positionLiquidity(sleeve, -600, 600), 10e18, "poke leaves liquidity untouched");
        _assertLedgerEqualsClaims();
    }

    function test_deployControlPutsEverythingFullRange() public {
        hook.fund(hook.CONTROL_SLEEVE(), 50e18, 50e18);
        hook.deployControl();

        ZenithHook.Range[] memory ranges = hook.getRanges(hook.CONTROL_SLEEVE());
        assertEq(ranges.length, 1);
        assertEq(ranges[0].tickLower, TickMath.minUsableTick(60));
        assertEq(ranges[0].tickUpper, TickMath.maxUsableTick(60));
        assertGt(ranges[0].liquidity, 0);

        ZenithHook.Sleeve memory control = hook.getSleeve(hook.CONTROL_SLEEVE());
        assertLt(control.idle0, 1e15, "almost all token0 deployed");
        assertLt(control.idle1, 1e15, "almost all token1 deployed");
        _assertRangesMatchPool(hook.CONTROL_SLEEVE());
        _assertLedgerEqualsClaims();
    }

    function test_redeployingControlCompoundsItsFees() public {
        hook.fund(hook.CONTROL_SLEEVE(), 50e18, 50e18);
        hook.deployControl();
        uint128 liquidityBefore = hook.getRanges(hook.CONTROL_SLEEVE())[0].liquidity;

        _trade(true, -5e18);
        _trade(false, -5e18);
        hook.deployControl();

        ZenithHook.Sleeve memory control = hook.getSleeve(hook.CONTROL_SLEEVE());
        assertGt(control.fees0 + control.fees1, 0, "control earned fees");
        assertGt(hook.getRanges(hook.CONTROL_SLEEVE())[0].liquidity, liquidityBefore, "fees compounded");
        _assertLedgerEqualsClaims();
    }

    // ------------------------------------------------------------------
    // Fuzz: random reshapes between random swaps
    // ------------------------------------------------------------------

    /// @notice Two curators reshape at random between random swaps. After every step the ledger must equal the
    /// claims, every stored range must match the pool exactly, and the other curator's sleeve must be untouched.
    function testFuzz_randomReshapesKeepAccountingExact(uint256 seed) public {
        address other = makeAddr("other-curator");
        uint256 bystander = _openFundedSleeve(other, 100e18, 100e18);
        ZenithHook.Range[] memory fixedShape = new ZenithHook.Range[](1);
        fixedShape[0] = _range(-1200, 1200, 3e18);
        vm.prank(other);
        hook.setShape(bystander, fixedShape);

        for (uint256 step; step < 6; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));

            ZenithHook.Range[] memory shape = _randomShape(seed); // built before prank: it calls the hook
            vm.prank(curator);
            hook.setShape(sleeve, shape);

            bool zeroForOne = (seed >> 200) & 1 == 1;
            int256 amountIn = -int256(bound(seed >> 100, 1e15, 20e18));
            _trade(zeroForOne, amountIn);

            _assertLedgerEqualsClaims();
            _assertRangesMatchPool(sleeve);
            assertEq(_positionLiquidity(bystander, -1200, 1200), 3e18, "other sleeve untouched");
        }

        hook.poke(sleeve);
        hook.poke(bystander);
        _assertLedgerEqualsClaims();
    }
}
