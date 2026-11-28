// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ZenithHook} from "../src/ZenithHook.sol";
import {ZenithSettler} from "../src/ZenithSettler.sol";
import {ZenithTestBase} from "./utils/ZenithTestBase.sol";

/// @notice The circuit breaker. A sleeve's value per share against the control's moves only with performance, price
/// exposure included; when it falls 5% below the best it has done, the sleeve goes to full range and its curator is
/// locked out. Pay stays on skill: the breaker only limits how far depositors can fall behind passive.
contract ZenithBreakerTest is ZenithTestBase {
    using StateLibrary for IPoolManager;

    ZenithSettler internal settler;
    address internal curator = makeAddr("curator");
    uint256 internal sleeve;

    function setUp() public override {
        super.setUp();
        settler = new ZenithSettler(hook);
        hook.setSettler(address(settler));
        _addExternalLiquidity(-12000, 12000, 1000e18);
        hook.fund(hook.CONTROL_SLEEVE(), 100e18, 100e18);
        hook.deployControl();
        sleeve = _openFundedSleeve(curator, 100e18, 100e18);
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));
        token1.mint(curator, 1000e18);
        vm.startPrank(curator);
        token1.approve(address(settler), type(uint256).max);
        settler.postBond(sleeve, 50e18);
        vm.stopPrank();
    }

    /// @notice A curator parks everything in a range below the price, a one-sided bet that the price will fall into
    /// it, and the price keeps falling through it. The breaker trips once the sleeve is 5% behind the control, moves it
    /// to full range, and the rest of the fall costs depositors what it costs a passive LP, not what the bet would.
    function test_aOneSidedBetTripsTheBreaker() public {
        _betBelowThePrice();
        _fallUntilDue();
        assertTrue(settler.observe(sleeve), "five percent behind its best against the control");
        uint256 snap = vm.snapshotState();

        settler.trip(sleeve);
        _assertFullRange(sleeve);
        (, bool passive) = settler.breakers(sleeve);
        assertTrue(passive);
        // The keeper rebalances a step a tick, arbitrage restoring the price in between, as the fall goes on.
        for (uint256 i; i < 20; ++i) {
            if (settler.unbalanced(sleeve)) settler.rebalance(sleeve);
            _trade(true, -15e18);
            _arbitrageBack();
        }
        assertFalse(settler.unbalanced(sleeve), "walked into full range");
        uint256 withBreaker = settler.relativeValue(sleeve);

        vm.revertToState(snap);
        for (uint256 i; i < 20; ++i) {
            _trade(true, -15e18);
            _arbitrageBack();
        }
        uint256 without = settler.relativeValue(sleeve);

        console2.log("against the control, with the breaker   ", withBreaker);
        console2.log("against the control, without the breaker", without);
        assertGt(withBreaker, without, "the breaker cut the loss");
    }

    /// @notice Fees a sleeve has earned but not yet collected count towards its value. The control collects its fees
    /// at every checkpoint and a curator's sleeve only at its own, so without them a sleeve earning well would look
    /// behind and could trip.
    function test_uncollectedFeesCount() public {
        _shapeNarrow();
        for (uint256 i; i < 10; ++i) {
            _trade(true, -20e18);
            _trade(false, -20e18);
        }
        hook.poke(hook.CONTROL_SLEEVE()); // the control collects; the curator's sleeve does not
        assertGt(settler.relativeValue(sleeve), 1e18, "a narrow range earns more fees per dollar than full range");
    }

    /// @notice A tripped sleeve is passive: its curator cannot shape it and nobody can deposit into it, but its
    /// depositors can always leave.
    function test_aTrippedSleeveLocksTheCuratorOutButNotTheDepositors() public {
        _betBelowThePrice();
        _fallUntilDue();
        settler.trip(sleeve);

        ZenithHook.Range[] memory shape = new ZenithHook.Range[](1);
        shape[0] = _range(-600, 600, 1e18);
        vm.prank(curator);
        vm.expectRevert(ZenithHook.NotBonded.selector);
        hook.setShape(sleeve, shape);

        vm.expectRevert(ZenithHook.NotBonded.selector);
        hook.fund(sleeve, 10e18, 10e18);

        hook.withdraw(sleeve, hook.sharesOf(sleeve, address(this)) / 2, address(this));
        _assertLedgerEqualsClaims();
    }

    /// @notice Ordinary trading around a concentrated range never trips the breaker.
    function test_normalTradingNeverTrips() public {
        _shapeNarrow();
        for (uint256 i; i < 20; ++i) {
            _trade(true, -20e18);
            _trade(false, -20e18);
            settler.observe(sleeve);
        }
        vm.expectRevert(ZenithSettler.NotTripping.selector);
        settler.trip(sleeve);
    }

    /// @notice The breaker trips on a fall from the best a sleeve has done against the control, not from where it
    /// started: a sleeve that got ahead and then gives back 5% trips, so no depositor falls much more than 5% behind
    /// passive from when they joined.
    function test_itTripsFiveFromTheBestNotFromTheStart() public {
        uint256 start = _shapeNarrowAndObserve();
        for (uint256 i; i < 30; ++i) {
            _trade(true, -20e18);
            _trade(false, -20e18);
            settler.observe(sleeve);
        }
        (uint256 peak,) = settler.breakers(sleeve);
        assertGt(peak, start, "the narrow range earned more fees than the control: it got ahead");

        _betBelowThePrice();
        _fallUntilDue();
        uint256 atTrip = settler.relativeValue(sleeve);
        settler.trip(sleeve);
        console2.log("start, peak, at the trip", start, peak, atTrip);
        assertLt(atTrip * 10_000, peak * 9_500, "at least 5% below its best");
        assertGt(atTrip * 10_000, peak * 9_300, "and not much more: a tick's worth of overshoot");
    }

    /// @notice Pushing the price inside a block cannot trip a sleeve: both values are taken at the block-open price.
    function test_aPriceSpikeCannotTripInsideTheBlock() public {
        _betBelowThePrice();
        _trade(true, -200e18); // most of the way to the threshold
        assertFalse(settler.observe(sleeve), "not yet");

        swap(key, true, -200e18, ZERO_BYTES); // a spike in the same block
        vm.expectRevert(ZenithSettler.NotTripping.selector);
        settler.trip(sleeve);
    }

    /// @notice The swap that rebalances a tripped sleeve is bounded in price, which bounds what a sandwich could take;
    /// whatever a thin pool cannot take that step stays idle for the next.
    function test_theRebalancingSwapIsBounded() public {
        _betBelowThePrice();
        _fallUntilDue();
        (, int24 before,,) = manager.getSlot0(key.toId());
        settler.trip(sleeve);
        (, int24 afterTrip,,) = manager.getSlot0(key.toId());
        int24 moved = afterTrip > before ? afterTrip - before : before - afterTrip;
        assertLe(moved, 100, "within the swap's bound");
        _assertLedgerEqualsClaims();
    }

    /// @notice A curator moved to full range for a short bond resumes once it bonds again.
    function test_resumingAfterABondClose() public {
        uint256 thin = _openFundedSleeve(curator, 100e18, 100e18);
        vm.prank(curator);
        settler.postBond(thin, 10.5e18); // just over 5% of a 200-token sleeve
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](1);
        shape[0] = _range(-600, 600, 1e21);
        vm.prank(curator);
        hook.setShape(thin, shape);

        _trade(false, -400e18); // token0 rallies: the sleeve is worth more in token1, and the bond falls short
        settler.forceClose(thin);
        _assertFullRange(thin);

        vm.prank(curator);
        vm.expectRevert(ZenithSettler.CannotResume.selector);
        settler.resume(thin);

        vm.prank(curator);
        settler.postBond(thin, 20e18);
        vm.prank(curator);
        settler.resume(thin);
        vm.prank(curator);
        hook.setShape(thin, shape); // managing again
        assertEq(hook.getRanges(thin)[0].tickLower, -600);
    }

    /// @notice After a breaker trip the curator cannot resume while depositors remain; once they have all left it
    /// can, and the breaker starts afresh.
    function test_resumingAfterATripNeedsAFreshStart() public {
        _betBelowThePrice();
        _fallUntilDue();
        settler.trip(sleeve);

        vm.prank(curator);
        vm.expectRevert(ZenithSettler.CannotResume.selector);
        settler.resume(sleeve);

        hook.withdraw(sleeve, hook.sharesOf(sleeve, address(this)), address(this));
        vm.prank(curator);
        settler.resume(sleeve);
        (uint256 peak, bool passive) = settler.breakers(sleeve);
        assertEq(peak, 0, "reset");
        assertFalse(passive);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev An arbitrageur trading part of a move back, as happens between blocks.
    function _arbitrageBack() internal {
        _trade(false, -5e18);
    }

    /// @dev Sells token0 into the pool, a block at a time, until the breaker is due, as a falling market would.
    function _fallUntilDue() internal {
        for (uint256 i; i < 20 && !settler.observe(sleeve); ++i) {
            _trade(true, -20e18);
        }
    }

    /// @dev All of the sleeve's token1 in a range just below the price: it buys token0 as the price falls.
    function _betBelowThePrice() internal {
        ZenithHook.Sleeve memory s = hook.getSleeve(sleeve);
        ZenithHook.Range[] memory current = hook.getRanges(sleeve);
        uint256 free1 = s.idle1;
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        for (uint256 i; i < current.length; ++i) {
            (, uint256 y) = _amounts(current[i], sqrtPriceX96);
            free1 += y;
        }
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](1);
        shape[0] = _range(
            -3000,
            -60,
            LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(-3000), TickMath.getSqrtPriceAtTick(-60), free1 * 9 / 10
            )
        );
        vm.prank(curator);
        hook.setShape(sleeve, shape);
        vm.roll(block.number + 1);
        settler.observe(sleeve); // as the keeper does on every tick
    }

    function _shapeNarrow() internal {
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](1);
        shape[0] = _range(
            -600,
            600,
            LiquidityAmounts.getLiquidityForAmounts(
                SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(-600), TickMath.getSqrtPriceAtTick(600), 90e18, 90e18
            )
        );
        vm.prank(curator);
        hook.setShape(sleeve, shape);
        vm.roll(block.number + 1);
        settler.observe(sleeve);
    }

    function _shapeNarrowAndObserve() internal returns (uint256 start) {
        _shapeNarrow();
        settler.observe(sleeve);
        (start,) = settler.breakers(sleeve);
    }

    function _amounts(ZenithHook.Range memory r, uint160 sqrtPriceX96) internal pure returns (uint256, uint256) {
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(r.tickLower),
            TickMath.getSqrtPriceAtTick(r.tickUpper),
            r.liquidity
        );
    }
}
