// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ZenithHook} from "../src/ZenithHook.sol";
import {ZenithSettler} from "../src/ZenithSettler.sol";
import {ZenithTestBase} from "./utils/ZenithTestBase.sol";

/// @notice Bonds and symmetric settlement: a share of new highs in excess is paid to the curator, the same share
/// of new lows is paid from its bond to depositors, and an under-bonded sleeve can be force-closed by anyone.
contract ZenithSettlerTest is ZenithTestBase {
    ZenithSettler internal settler;
    address internal curator = makeAddr("curator");
    uint256 internal sleeve;
    uint128 internal narrow;

    function setUp() public override {
        super.setUp();
        settler = new ZenithSettler(hook);
        hook.setSettler(address(settler));

        _addExternalLiquidity(-6000, 6000, 1000e18);
        hook.fund(hook.CONTROL_SLEEVE(), 100e18, 100e18);
        hook.deployControl();
        sleeve = _openFundedSleeve(curator, 100e18, 100e18);
        narrow = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(-600), TickMath.getSqrtPriceAtTick(600), 100e18 - 1, 100e18 - 1
        );

        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));
        token1.mint(curator, 1000e18);
        vm.prank(curator);
        token1.approve(address(settler), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Wiring and bonds
    // ------------------------------------------------------------------

    function test_settlerIsSetOnceByTheInitializer() public {
        vm.expectRevert(ZenithHook.SettlerAlreadySet.selector);
        hook.setSettler(address(1));
    }

    function test_shapingNeedsABondOfFivePercent() public {
        ZenithHook.Range[] memory shape = _single(narrow);
        vm.prank(curator);
        vm.expectRevert(ZenithHook.NotBonded.selector);
        hook.setShape(sleeve, shape);

        _bond(9e18); // the sleeve is worth 200e18 token1, so 5% is 10e18
        vm.prank(curator);
        vm.expectRevert(ZenithHook.NotBonded.selector);
        hook.setShape(sleeve, shape);

        _bond(1e18);
        vm.prank(curator);
        hook.setShape(sleeve, shape);
        assertEq(hook.getRanges(sleeve).length, 1);
    }

    function test_bondIsHeldAsClaimsBySettler() public {
        _bond(20e18);
        (uint256 bond,,,,,,,) = settler.accounts(sleeve);
        assertEq(bond, 20e18);
        assertEq(manager.balanceOf(address(settler), currency1.toId()), 20e18, "bond held as claims");
        _assertLedgerEqualsClaims(); // the hook's ledger is untouched by bonds
    }

    function test_onlyTheSettlerClosesPeriods() public {
        _bond(20e18);
        _shape(narrow);
        vm.warp(block.timestamp + hook.PERIOD());
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ZenithHook.NotSettler.selector);
        hook.rollPeriod(sleeve);
    }

    function test_onlyTheSettlerMovesMoney() public {
        vm.expectRevert(ZenithHook.NotSettler.selector);
        hook.settle(sleeve, -1e18, address(this), false);
    }

    // ------------------------------------------------------------------
    // Symmetric settlement
    // ------------------------------------------------------------------

    function test_goodPeriodPaysTheCuratorItsShare() public {
        _bond(20e18);
        _goodTiming();
        uint256 before = currency1.balanceOf(curator);

        (int256 excess, uint256 fee, uint256 slashed) = _settle();

        assertGt(excess, 0, "the curator beat the control");
        assertEq(fee, uint256(excess) * settler.SHARE_BPS() / 10_000, "20% of the excess");
        assertEq(slashed, 0);
        assertEq(currency1.balanceOf(curator) - before, fee, "the fee reached the curator");
        _assertLedgerEqualsClaims();
    }

    /// @notice Gain, give part of it back, gain again: paid on the first gain, neither paid nor slashed for the
    /// give-back, and paid on the second gain only above the earlier high.
    function test_waterMarksPayEachGainOnceAndIgnoreTheWobble() public {
        _bond(20e18);
        _goodTiming();
        (int256 first, uint256 firstFee,) = _settle();
        assertGt(first, 0);
        assertEq(firstFee, uint256(first) * settler.SHARE_BPS() / 10_000);

        _trend(40e18);
        (int256 second, uint256 secondFee, uint256 secondSlash) = _settle();
        assertLt(second, 0, "gave some back");
        assertLt(-second, first, "but less than it gained");
        assertEq(secondFee, 0, "no new high, no fee");
        assertEq(secondSlash, 0, "above the low-water mark, no slash");

        _goodTiming();
        (int256 third, uint256 thirdFee,) = _settle();
        assertGt(third, 0);
        int256 aboveHigh = first + second + third - first;
        assertEq(thirdFee, uint256(aboveHigh) * settler.SHARE_BPS() / 10_000, "paid only above the old high");
    }

    function test_badPeriodPaysDepositorsFromTheBond() public {
        _bond(20e18);
        _badTiming();
        uint256 idleBefore = hook.getSleeve(sleeve).idle1;

        (int256 excess, uint256 fee, uint256 slashed) = _settle();

        assertLt(excess, 0, "the curator lost to the control");
        assertEq(slashed, uint256(-excess) * settler.SHARE_BPS() / 10_000, "20% of the shortfall");
        assertEq(fee, 0);
        (uint256 bond,,,,, uint256 pending,,) = settler.accounts(sleeve);
        assertEq(bond, 20e18 - slashed, "taken from the bond");
        assertEq(pending, slashed, "held for release");
        assertEq(hook.getSleeve(sleeve).idle1, idleBefore, "nothing released yet");
        assertEq(manager.balanceOf(address(settler), currency1.toId()), bond + pending, "settler claims match");

        // Released evenly over the next period: half after half of it, the rest at its end.
        vm.warp(block.timestamp + hook.PERIOD() / 2);
        settler.release(sleeve);
        assertEq(hook.getSleeve(sleeve).idle1 - idleBefore, slashed / 2, "half released");
        vm.warp(block.timestamp + hook.PERIOD());
        settler.release(sleeve);
        assertEq(hook.getSleeve(sleeve).idle1 - idleBefore, slashed, "all of it reached the depositors");
        (,,,,, pending,,) = settler.accounts(sleeve);
        assertEq(pending, 0);
        assertEq(manager.balanceOf(address(settler), currency1.toId()), bond, "settler keeps only the bond");
        _assertLedgerEqualsClaims();
    }

    function test_settlementIsNotSkill() public {
        _bond(20e18);
        _goodTiming();
        _settle();
        // Paying the fee moved token1 out of the sleeve at a checkpoint; it must not show up as lost skill.
        ZenithHook.Score memory score = hook.getScore(sleeve);
        hook.poke(sleeve);
        assertEq(hook.getScore(sleeve).excess, score.excess, "a fee payment is not a loss");
    }

    /// @notice The fee is capped at the bond, as the slash is, so a curator can win at most what it has at stake.
    function test_feeIsCappedAtTheBond() public {
        _bond(10e18);
        _shape(narrow);
        vm.warp(block.timestamp + hook.PERIOD());
        // Pretend the period ended far ahead: 1,000 tokens of excess would be a 200-token fee.
        ZenithHook.Score memory score = hook.getScore(sleeve);
        score.lastExcess = 1000e18;
        score.excess = 0;
        vm.mockCall(address(hook), abi.encodeCall(ZenithHook.getScore, (sleeve)), abi.encode(score));
        (, uint256 fee,) = settler.settle(sleeve);
        vm.clearMockedCalls();
        (, int256 cumulative, int256 highWater,, uint256 feeOwed,,,) = settler.accounts(sleeve);
        assertEq(fee + feeOwed, 10e18, "fee paid plus owed is the bond, not 20% of the gain");
        assertEq(highWater, cumulative, "the whole gain counts towards the high-water mark");
    }

    /// @notice A slash is not released into a sleeve nobody holds: a newcomer must not collect what was owed to those
    /// who left. The schedule resumes when someone holds the sleeve again.
    function test_releasePausesWhileNobodyHoldsTheSleeve() public {
        _bond(20e18);
        _badTiming();
        (,, uint256 slashed) = _settle();
        assertGt(slashed, 0);

        hook.withdraw(sleeve, hook.sharesOf(sleeve, address(this)), address(this));
        vm.warp(block.timestamp + hook.PERIOD() / 2);
        assertEq(settler.release(sleeve), 0, "nothing released into an empty sleeve");
        (,,,,, uint256 pending,,) = settler.accounts(sleeve);
        assertEq(pending, slashed, "still owed");

        vm.roll(block.number + 1);
        hook.fund(sleeve, 10e18, 10e18);
        vm.warp(block.timestamp + hook.PERIOD() / 2);
        assertEq(settler.release(sleeve), slashed / 2, "the schedule resumed where it paused");
    }

    // ------------------------------------------------------------------
    // Forced close and leaving
    // ------------------------------------------------------------------

    function test_anyoneCanCloseAnUnderBondedSleeve() public {
        _bond(10e18);
        _shape(narrow);
        vm.expectRevert(ZenithSettler.StillBonded.selector);
        settler.forceClose(sleeve);

        // token0 doubles against token1, so the same bond no longer covers the sleeve's value in token1.
        _trade(false, -400e18);
        assertFalse(settler.isBonded(sleeve), "the move left the bond short");
        vm.prank(makeAddr("anyone"));
        settler.forceClose(sleeve);
        // The sleeve held only token1 after the move: the close swaps half of it through the pool, and the next step
        // places both sides at full range.
        assertTrue(settler.unbalanced(sleeve), "one-sided, so not placed yet");
        vm.roll(block.number + 1);
        settler.rebalance(sleeve);
        _assertFullRange(sleeve);
        assertEq(_positionLiquidity(sleeve, -600, 600), 0, "the curator's range is gone");
        (, bool passive) = settler.breakers(sleeve);
        assertTrue(passive, "the curator is locked out");
        _assertLedgerEqualsClaims();
    }

    function test_bondReturnsOnlyAfterTheCuratorStepsDown() public {
        _bond(20e18);
        _shape(narrow);
        vm.prank(curator);
        vm.expectRevert(ZenithSettler.StillManaging.selector);
        settler.withdrawBond(sleeve, 20e18, curator);

        vm.prank(curator);
        hook.setShape(sleeve, new ZenithHook.Range[](0));
        _settle(); // closes the period in which it still had liquidity
        vm.warp(block.timestamp + hook.PERIOD());
        settler.settle(sleeve);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ZenithSettler.NotCurator.selector);
        settler.withdrawBond(sleeve, 1, curator);

        (uint256 bond,,,,,,,) = settler.accounts(sleeve);
        uint256 before = currency1.balanceOf(curator);
        vm.prank(curator);
        settler.withdrawBond(sleeve, bond, curator);
        assertEq(currency1.balanceOf(curator) - before, bond, "bond returned");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _bond(uint256 amount) internal {
        vm.prank(curator);
        settler.postBond(sleeve, amount);
    }

    function _single(uint128 liquidity) internal pure returns (ZenithHook.Range[] memory shape) {
        shape = new ZenithHook.Range[](1);
        shape[0] = _range(-600, 600, liquidity);
    }

    function _shape(uint128 liquidity) internal {
        ZenithHook.Range[] memory shape = _single(liquidity);
        vm.prank(curator);
        hook.setShape(sleeve, shape);
    }

    /// @dev More liquidity during a fee-rich, range-bound stretch than at the period's start.
    function _goodTiming() internal {
        _shape(narrow / 4);
        vm.warp(block.timestamp + 1 days);
        _shape(narrow);
        for (uint256 i; i < 20; ++i) {
            vm.warp(block.timestamp + 1 hours);
            _trade(true, -20e18);
            _trade(false, -20e18);
        }
        _shape(narrow / 4);
    }

    /// @dev More liquidity just before a trend than at the period's start.
    function _badTiming() internal {
        _trend(80e18);
    }

    function _trend(uint256 size) internal {
        _shape(narrow / 4);
        vm.warp(block.timestamp + 1 days);
        _shape(narrow);
        _trade(true, -int256(size));
        _shape(narrow / 4);
    }

    function _settle() internal returns (int256, uint256, uint256) {
        vm.warp(block.timestamp + hook.PERIOD());
        return settler.settle(sleeve);
    }
}
