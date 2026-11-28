// Exact bigint ports of the Uniswap v4 and Zenith maths the app needs, so every figure on screen is computed the
// way the contracts compute it. Checked against the deployed ZenithMath library in math.test.ts.

export const Q96 = 1n << 96n;
export const MIN_TICK = -887272;
export const MAX_TICK = 887272;
export const MIN_SQRT_PRICE = 4295128739n;
export const MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342n;
const MAX_UINT256 = (1n << 256n) - 1n;

const RATIOS: [bigint, bigint][] = [
  [0x2n, 0xfff97272373d413259a46990580e213an],
  [0x4n, 0xfff2e50f5f656932ef12357cf3c7fdccn],
  [0x8n, 0xffe5caca7e10e4e61c3624eaa0941cd0n],
  [0x10n, 0xffcb9843d60f6159c9db58835c926644n],
  [0x20n, 0xff973b41fa98c081472e6896dfb254c0n],
  [0x40n, 0xff2ea16466c96a3843ec78b326b52861n],
  [0x80n, 0xfe5dee046a99a2a811c461f1969c3053n],
  [0x100n, 0xfcbe86c7900a88aedcffc83b479aa3a4n],
  [0x200n, 0xf987a7253ac413176f2b074cf7815e54n],
  [0x400n, 0xf3392b0822b70005940c7a398e4b70f3n],
  [0x800n, 0xe7159475a2c29b7443b29c7fa6e889d9n],
  [0x1000n, 0xd097f3bdfd2022b8845ad8f792aa5825n],
  [0x2000n, 0xa9f746462d870fdf8a65dc1f90e061e5n],
  [0x4000n, 0x70d869a156d2a1b890bb3df62baf32f7n],
  [0x8000n, 0x31be135f97d08fd981231505542fcfa6n],
  [0x10000n, 0x9aa508b5b7a84e1c677de54f3e99bc9n],
  [0x20000n, 0x5d6af8dedb81196699c329225ee604n],
  [0x40000n, 0x2216e584f5fa1ea926041bedfe98n],
  [0x80000n, 0x48a170391f7dc42444e8fa2n],
];

/** TickMath.getSqrtPriceAtTick. */
export function sqrtPriceAtTick(tick: number): bigint {
  if (tick < MIN_TICK || tick > MAX_TICK) throw new Error(`tick ${tick} out of range`);
  const abs = BigInt(Math.abs(tick));
  let ratio = abs & 0x1n ? 0xfffcb933bd6fad37aa2d162d1a594001n : 0x100000000000000000000000000000000n;
  for (const [bit, factor] of RATIOS) if (abs & bit) ratio = (ratio * factor) >> 128n;
  if (tick > 0) ratio = MAX_UINT256 / ratio;
  return (ratio >> 32n) + (ratio % (1n << 32n) === 0n ? 0n : 1n);
}

/** The largest tick whose sqrt price is at or below the given one (TickMath.getTickAtSqrtPrice), by bisection. */
export function tickAtSqrtPrice(sqrtPriceX96: bigint): number {
  let lo = MIN_TICK;
  let hi = MAX_TICK;
  while (lo < hi) {
    const mid = Math.floor((lo + hi + 1) / 2);
    if (sqrtPriceAtTick(mid) <= sqrtPriceX96) lo = mid;
    else hi = mid - 1;
  }
  return lo;
}

export const minUsableTick = (spacing: number) => Math.ceil(MIN_TICK / spacing) * spacing;
export const maxUsableTick = (spacing: number) => Math.floor(MAX_TICK / spacing) * spacing;

const mulDiv = (a: bigint, b: bigint, d: bigint) => (a * b) / d;
const mulDivUp = (a: bigint, b: bigint, d: bigint) => {
  const p = a * b;
  return p / d + (p % d === 0n ? 0n : 1n);
};
const divUp = (a: bigint, b: bigint) => a / b + (a % b === 0n ? 0n : 1n);

/** SqrtPriceMath.getAmount0Delta. */
export function amount0Delta(a: bigint, b: bigint, liquidity: bigint, roundUp: boolean): bigint {
  const [lower, upper] = a < b ? [a, b] : [b, a];
  const n1 = liquidity << 96n;
  const n2 = upper - lower;
  return roundUp ? divUp(mulDivUp(n1, n2, upper), lower) : mulDiv(n1, n2, upper) / lower;
}

/** SqrtPriceMath.getAmount1Delta. */
export function amount1Delta(a: bigint, b: bigint, liquidity: bigint, roundUp: boolean): bigint {
  const [lower, upper] = a < b ? [a, b] : [b, a];
  return roundUp ? mulDivUp(liquidity, upper - lower, Q96) : mulDiv(liquidity, upper - lower, Q96);
}

/** ZenithMath.amounts: the tokens in a position at a price, rounded down. */
export function positionAmounts(tickLower: number, tickUpper: number, liquidity: bigint, sqrtPriceX96: bigint) {
  const lower = sqrtPriceAtTick(tickLower);
  const upper = sqrtPriceAtTick(tickUpper);
  const inside = sqrtPriceX96 < lower ? lower : sqrtPriceX96 > upper ? upper : sqrtPriceX96;
  return {
    amount0: amount0Delta(inside, upper, liquidity, false),
    amount1: amount1Delta(lower, inside, liquidity, false),
  };
}

/** The tokens a new position of this liquidity needs, rounded up as the PoolManager charges them. */
export function positionCost(tickLower: number, tickUpper: number, liquidity: bigint, sqrtPriceX96: bigint) {
  const lower = sqrtPriceAtTick(tickLower);
  const upper = sqrtPriceAtTick(tickUpper);
  const inside = sqrtPriceX96 < lower ? lower : sqrtPriceX96 > upper ? upper : sqrtPriceX96;
  return {
    amount0: amount0Delta(inside, upper, liquidity, true),
    amount1: amount1Delta(lower, inside, liquidity, true),
  };
}

/** ZenithMath.value: token0 and token1 valued in token1 at a price. */
export function valueInToken1(amount0: bigint, amount1: bigint, sqrtPriceX96: bigint): bigint {
  return mulDiv(mulDiv(amount0, sqrtPriceX96, Q96), sqrtPriceX96, Q96) + amount1;
}

/** LiquidityAmounts.getLiquidityForAmounts: the most liquidity these amounts buy in a range. */
export function liquidityForAmounts(
  sqrtPriceX96: bigint,
  tickLower: number,
  tickUpper: number,
  amount0: bigint,
  amount1: bigint,
): bigint {
  const a = sqrtPriceAtTick(tickLower);
  const b = sqrtPriceAtTick(tickUpper);
  const for0 = (lower: bigint, upper: bigint) => mulDiv(mulDiv(amount0, lower, Q96), upper, upper - lower);
  const for1 = (lower: bigint, upper: bigint) => mulDiv(amount1, Q96, upper - lower);
  if (sqrtPriceX96 <= a) return for0(a, b);
  if (sqrtPriceX96 < b) {
    const l0 = for0(sqrtPriceX96, b);
    const l1 = for1(a, sqrtPriceX96);
    return l0 < l1 ? l0 : l1;
  }
  return for1(a, b);
}

/** Price of token0 in token1 as a float, for display only. */
export function priceFromSqrt(sqrtPriceX96: bigint): number {
  const s = Number(sqrtPriceX96) / 2 ** 96;
  return s * s;
}

export const priceAtTick = (tick: number) => 1.0001 ** tick;
export const tickAtPrice = (price: number) => Math.log(price) / Math.log(1.0001);
export const snapTick = (tick: number, spacing: number) => Math.round(tick / spacing) * spacing;
