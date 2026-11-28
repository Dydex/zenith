import { describe, expect, it } from "vitest";

import fixtures from "./__fixtures__/zenithMath.json";
import {
  MAX_SQRT_PRICE,
  MAX_TICK,
  MIN_SQRT_PRICE,
  MIN_TICK,
  Q96,
  liquidityForAmounts,
  positionAmounts,
  positionCost,
  sqrtPriceAtTick,
  tickAtSqrtPrice,
  valueInToken1,
} from "./math";

describe("TickMath port", () => {
  it("matches the protocol's bounds and the unit price", () => {
    expect(sqrtPriceAtTick(0)).toBe(Q96);
    expect(sqrtPriceAtTick(MIN_TICK)).toBe(MIN_SQRT_PRICE);
    expect(sqrtPriceAtTick(MAX_TICK)).toBe(MAX_SQRT_PRICE);
  });

  it("inverts: the tick at a tick's own sqrt price is that tick", () => {
    for (const tick of [MIN_TICK, -200000, -61, -60, -1, 0, 1, 59, 60, 123456, MAX_TICK - 1]) {
      expect(tickAtSqrtPrice(sqrtPriceAtTick(tick))).toBe(tick);
      if (tick > MIN_TICK) expect(tickAtSqrtPrice(sqrtPriceAtTick(tick) - 1n)).toBe(tick - 1);
    }
  });
});

describe("ZenithMath port, against the library deployed on Unichain Sepolia", () => {
  it.each(fixtures)("range $tickLower..$tickUpper", (f) => {
    const sqrt = BigInt(f.sqrtPriceX96);
    const { amount0, amount1 } = positionAmounts(f.tickLower, f.tickUpper, BigInt(f.liquidity), sqrt);
    expect(amount0).toBe(BigInt(f.amount0));
    expect(amount1).toBe(BigInt(f.amount1));
    expect(valueInToken1(amount0, amount1, sqrt)).toBe(BigInt(f.value));
  });
});

describe("liquidity and cost", () => {
  it("a position bought with some amounts never costs more than them", () => {
    const sqrt = sqrtPriceAtTick(37);
    const liquidity = liquidityForAmounts(sqrt, -600, 600, 10n ** 20n, 10n ** 20n);
    const cost = positionCost(-600, 600, liquidity, sqrt);
    expect(cost.amount0 <= 10n ** 20n).toBe(true);
    expect(cost.amount1 <= 10n ** 20n).toBe(true);
    expect(cost.amount0 > 10n ** 20n - 10n ** 18n || cost.amount1 > 10n ** 20n - 10n ** 18n).toBe(true);
  });
});
