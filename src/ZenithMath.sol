// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @title ZenithMath
/// @notice Position valuation for ZenithHook, deployed as a separate library so the hook stays under the 24 KB
/// contract size limit.
library ZenithMath {
    /// @notice Tokens in a position of `liquidity` between two ticks at the given price, rounded down.
    function amounts(int24 tickLower, int24 tickUpper, uint128 liquidity, uint160 sqrtPriceX96)
        external
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 lower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint160 inside = sqrtPriceX96 < lower ? lower : (sqrtPriceX96 > upper ? upper : sqrtPriceX96);
        amount0 = SqrtPriceMath.getAmount0Delta(inside, upper, liquidity, false);
        amount1 = SqrtPriceMath.getAmount1Delta(lower, inside, liquidity, false);
    }

    /// @notice Value in token1 at the given price.
    function value(uint256 amount0, uint256 amount1, uint160 sqrtPriceX96) external pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96) + amount1;
    }

    /// @notice The widest usable range for a tick spacing, and the most liquidity the amounts afford there. One
    /// wei of margin is left on each side because adding liquidity rounds the required amounts up.
    function fullRange(int24 tickSpacing, uint160 sqrtPriceX96, uint256 amount0, uint256 amount1)
        external
        pure
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        tickLower = TickMath.minUsableTick(tickSpacing);
        tickUpper = TickMath.maxUsableTick(tickSpacing);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0 > 0 ? amount0 - 1 : 0,
            amount1 > 0 ? amount1 - 1 : 0
        );
    }

    /// @notice Shares for an in-kind deposit at a sleeve's current ratio. Shares round down and the amounts taken
    /// round up, so existing holders never lose to rounding. Returns zero shares if the deposit buys nothing.
    function proportional(uint256 supply, uint256 held0, uint256 held1, uint256 max0, uint256 max1)
        external
        pure
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        shares = type(uint256).max;
        if (held0 > 0) shares = FullMath.mulDiv(max0, supply, held0);
        if (held1 > 0) {
            uint256 by1 = FullMath.mulDiv(max1, supply, held1);
            if (by1 < shares) shares = by1;
        }
        if (shares == type(uint256).max || shares == 0) return (0, 0, 0);
        // Rounding the amounts up can never exceed the maxima, because shares were rounded down from them.
        amount0 = FullMath.mulDivRoundingUp(shares, held0, supply);
        amount1 = FullMath.mulDivRoundingUp(shares, held1, supply);
    }
}
