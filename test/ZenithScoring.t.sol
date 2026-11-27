// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Vm} from "forge-std/Vm.sol";

import {ZenithHook} from "../src/ZenithHook.sol";
import {ZenithTestBase} from "./utils/ZenithTestBase.sol";

/// @notice The scoring rule's promises, on a real PoolManager: sitting still scores zero however concentrated,
/// idle scores zero, good timing scores positive, bad timing negative, and deposits never count as skill.
contract ZenithScoringTest is ZenithTestBase {
    using StateLibrary for IPoolManager;

    /// @dev Rounding in valuation, in token1 wei. The effects measured below are around 1e17 to 1e18.
    uint256 internal constant TOLERANCE = 1e9;

    address internal curator = makeAddr("curator");
    uint256 internal sleeve;
    uint128 internal narrow; // liquidity a 100e18/100e18 sleeve affords across ticks -600..600

    function setUp() public override {
        super.setUp();
        _addExternalLiquidity(-6000, 6000, 1000e18);
        hook.fund(hook.CONTROL_SLEEVE(), 100e18, 100e18);
        hook.deployControl();
        sleeve = _openFundedSleeve(curator, 100e18, 100e18);
        narrow = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(-600), TickMath.getSqrtPriceAtTick(600), 100e18 - 1, 100e18 - 1
        );
    }

    // ------------------------------------------------------------------
    // No skill scores zero
    // ------------------------------------------------------------------

    function test_staticConcentratedCuratorScoresZeroInChop() public {
        _shape(narrow);
        _chop(20e18, 20);
        int256 skill = _pokeAndReadSkill();
        assertGt(skill, 1e17, "the sleeve really earned: about 34x the control per dollar");
        assertApproxEqAbs(hook.getScore(sleeve).excess, 0, TOLERANCE, "sitting still is not skill");
    }

    function test_staticConcentratedCuratorScoresZeroInTrend() public {
        _shape(narrow);
        vm.warp(block.timestamp + 1 days);
        _trade(true, -80e18);
        int256 skill = _pokeAndReadSkill();
        assertLt(skill, -1e17, "the sleeve really lost to the move");
        assertApproxEqAbs(hook.getScore(sleeve).excess, 0, TOLERANCE, "sitting still is not a mistake");
    }

    function test_copyingTheControlScoresZero() public {
        ZenithHook.Range memory control = hook.getRanges(hook.CONTROL_SLEEVE())[0];
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](1);
        shape[0] = control;
        vm.prank(curator);
        hook.setShape(sleeve, shape);
        _chop(20e18, 10);
        _trade(true, -50e18);
        hook.poke(sleeve);
        assertApproxEqAbs(hook.getScore(sleeve).excess, 0, TOLERANCE, "the control's own shape scores zero");
    }

    function test_idleSleeveNeverStartsAPeriod() public {
        _chop(20e18, 10);
        hook.poke(sleeve);
        ZenithHook.Score memory score = hook.getScore(sleeve);
        assertEq(score.periodStart, 0, "no shape, no period");
        assertEq(score.excess, 0, "idle scores nothing");
    }

    function test_depositMidPeriodIsNotSkill() public {
        _shape(narrow);
        _chop(20e18, 5);
        hook.poke(sleeve);
        int256 before = hook.getScore(sleeve).excess;
        hook.fund(sleeve, 50e18, 50e18);
        // The deposit checkpoints before adding the money; the next checkpoint must not count it either.
        hook.poke(sleeve);
        assertApproxEqAbs(hook.getScore(sleeve).excess, before, TOLERANCE, "new money is not skill");
    }

    // ------------------------------------------------------------------
    // Timing is skill
    // ------------------------------------------------------------------

    /// @notice Adding liquidity just before a fee-rich, range-bound stretch beats the control.
    function test_goodTimingScoresPositive() public {
        _shape(narrow / 4);
        vm.warp(block.timestamp + 1 days);
        _shape(narrow);
        _chop(20e18, 20);
        _shape(narrow / 4);
        hook.poke(sleeve);
        assertGt(hook.getScore(sleeve).excess, int256(TOLERANCE), "added liquidity before the fees");
    }

    /// @notice Adding liquidity just before a trend loses to the control.
    function test_badTimingScoresNegative() public {
        _shape(narrow / 4);
        vm.warp(block.timestamp + 1 days);
        _shape(narrow);
        _trade(true, -80e18);
        _shape(narrow / 4);
        hook.poke(sleeve);
        assertLt(hook.getScore(sleeve).excess, -int256(TOLERANCE), "added liquidity before the move");
    }

    // ------------------------------------------------------------------
    // Valuation price
    // ------------------------------------------------------------------

    /// @notice Checkpoints value holdings at the price the block opened at. A swap moves that price only from the
    /// next block, so a price pushed and pushed back inside one block never reaches a score.
    function test_scoresUseTheBlockOpenPrice() public {
        (uint160 open,) = hook.blockOpenPrice();
        swap(key, true, -50e18, ZERO_BYTES);
        (uint160 spot,,,) = manager.getSlot0(key.toId());
        assertLt(spot, open, "the swap moved the pool");
        (uint160 seen,) = hook.blockOpenPrice();
        assertEq(seen, open, "same block: still the open price");

        vm.roll(block.number + 1);
        (seen,) = hook.blockOpenPrice();
        assertEq(seen, spot, "next block: the moved price");
    }

    // ------------------------------------------------------------------
    // Periods
    // ------------------------------------------------------------------

    function test_rollPeriodClosesAndRestarts() public {
        _shape(narrow / 4);
        _shape(narrow);
        _chop(20e18, 10);

        vm.expectRevert(ZenithHook.PeriodNotOver.selector);
        hook.rollPeriod(sleeve);

        vm.warp(block.timestamp + hook.PERIOD());
        hook.rollPeriod(sleeve);
        ZenithHook.Score memory score = hook.getScore(sleeve);
        assertGt(score.lastExcess, 0, "closed period kept its result");
        assertEq(score.excess, 0, "new period starts at zero");
        assertEq(score.startInRange, narrow, "new baseline is the current liquidity");
        assertEq(score.periodStart, block.timestamp);
    }

    function test_rollPeriodRevertsBeforeFirstShape() public {
        vm.expectRevert(ZenithHook.PeriodNotOver.selector);
        hook.rollPeriod(sleeve);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Pokes the sleeve and returns the actual skill its checkpoint measured.
    function _pokeAndReadSkill() internal returns (int256 skill) {
        vm.recordLogs();
        hook.poke(sleeve);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = ZenithHook.Checkpointed.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == topic && uint256(logs[i].topics[1]) == sleeve)
            {
                (skill,) = abi.decode(logs[i].data, (int256, int256));
            }
        }
    }

    function _shape(uint128 liquidity) internal {
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](1);
        shape[0] = _range(-600, 600, liquidity);
        vm.prank(curator);
        hook.setShape(sleeve, shape);
    }

    /// @dev Round trips that leave the price where it started: fees without a lasting move.
    function _chop(uint256 size, uint256 trips) internal {
        for (uint256 i; i < trips; ++i) {
            vm.warp(block.timestamp + 1 hours);
            _trade(true, -int256(size));
            _trade(false, -int256(size));
        }
    }
}
