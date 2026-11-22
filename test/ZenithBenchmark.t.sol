// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {ZenithHook} from "../src/ZenithHook.sol";
import {ZenithTestBase} from "./utils/ZenithTestBase.sol";

/// @notice Pins a requirement for the scoring rule before it is written. A curator who posts one narrow range and
/// never moves it has no skill, yet comparing it with the control per unit of capital pays it in a choppy market
/// and slashes it in a trend. Per unit of in-range liquidity its excess is zero.
contract ZenithBenchmarkTest is ZenithTestBase {
    using StateLibrary for IPoolManager;

    int256 internal constant CAPITAL = 200e18; // each sleeve: 100e18 of each token at price 1
    /// @dev One part per million of capital: room for rounding in valuation, far below the effect measured.
    int256 internal constant TOLERANCE = CAPITAL / 1e6;

    address internal curator = makeAddr("static-curator");
    uint256 internal sleeve;

    struct Holding {
        int256 amount0;
        int256 amount1;
        int256 liquidity;
    }

    function setUp() public override {
        super.setUp();
        _addExternalLiquidity(-6000, 6000, 1000e18);

        hook.fund(hook.CONTROL_SLEEVE(), 100e18, 100e18);
        hook.deployControl();

        sleeve = _openFundedSleeve(curator, 100e18, 100e18);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(-600), TickMath.getSqrtPriceAtTick(600), 100e18 - 1, 100e18 - 1
        );
        ZenithHook.Range[] memory shape = new ZenithHook.Range[](1);
        shape[0] = _range(-600, 600, liquidity);
        vm.prank(curator);
        hook.setShape(sleeve, shape);
    }

    function test_capitalBenchmarkPaysStaticConcentrationInChop() public {
        (int256 perCapital, int256 perLiquidity) = _measure(20e18, 20, true);
        assertGt(perCapital, CAPITAL / 200, "no skill, yet over 0.5% of capital ahead of the control");
        assertApproxEqAbs(perLiquidity, 0, uint256(TOLERANCE), "per liquidity: no skill, no excess");
    }

    function test_capitalBenchmarkSlashesStaticConcentrationInTrend() public {
        (int256 perCapital, int256 perLiquidity) = _measure(80e18, 1, false);
        assertLt(perCapital, -CAPITAL / 500, "no mistake, yet over 0.2% of capital behind the control");
        assertApproxEqAbs(perLiquidity, 0, uint256(TOLERANCE), "per liquidity: no mistake, no penalty");
    }

    /// @dev Trades, then returns the static sleeve's excess skill under each benchmark.
    function _measure(uint256 size, uint256 trades, bool roundTrip)
        internal
        returns (int256 perCapital, int256 perLiquidity)
    {
        uint256 control = hook.CONTROL_SLEEVE();
        Holding memory controlBefore = _holding(control);
        Holding memory sleeveBefore = _holding(sleeve);

        for (uint256 i; i < trades; ++i) {
            swap(key, true, -int256(size), ZERO_BYTES);
            if (roundTrip) swap(key, false, -int256(size), ZERO_BYTES);
        }
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertTrue(tick >= -600 && tick < 600, "both sleeves stay in range");

        int256 controlSkill = _skillSince(controlBefore, _holding(control));
        int256 sleeveSkill = _skillSince(sleeveBefore, _holding(sleeve));
        perCapital = sleeveSkill - controlSkill; // equal capital, both fully deployed
        perLiquidity = sleeveSkill - controlSkill * sleeveBefore.liquidity / controlBefore.liquidity;
    }

    /// @dev Tokens in the sleeve's single in-range position, plus its idle balance and collected fees.
    function _holding(uint256 id) internal returns (Holding memory) {
        hook.poke(id);
        ZenithHook.Sleeve memory s = hook.getSleeve(id);
        ZenithHook.Range memory r = hook.getRanges(id)[0];
        (uint160 price,,,) = manager.getSlot0(key.toId());
        uint256 in0 = SqrtPriceMath.getAmount0Delta(price, TickMath.getSqrtPriceAtTick(r.tickUpper), r.liquidity, false);
        uint256 in1 = SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(r.tickLower), price, r.liquidity, false);
        return Holding(int256(s.idle0 + in0), int256(s.idle1 + in1), int256(uint256(r.liquidity)));
    }

    /// @dev Skill: today's holdings minus yesterday's holdings, both valued at today's price, in token1.
    function _skillSince(Holding memory before, Holding memory current) internal view returns (int256) {
        (uint160 price,,,) = manager.getSlot0(key.toId());
        int256 priceX96 = int256((uint256(price) * uint256(price)) >> 96);
        return (current.amount0 - before.amount0) * priceX96 / int256(1 << 96) + (current.amount1 - before.amount1);
    }
}
