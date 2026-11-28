import { encodeAbiParameters, hexToBigInt, keccak256, type Hex } from "viem";

import { deployment } from "../generated/deployment";

const d = deployment.unichain;

export const poolKey = {
  currency0: d.token0,
  currency1: d.token1,
  fee: d.fee,
  tickSpacing: d.tickSpacing,
  hooks: d.hook,
} as const;

export const poolId: Hex = keccak256(
  encodeAbiParameters(
    [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
    [poolKey.currency0, poolKey.currency1, poolKey.fee, poolKey.tickSpacing, poolKey.hooks],
  ),
);

/** StateLibrary: pools live in the PoolManager's mapping at slot 6; liquidity sits 3 slots into the pool state. */
const stateSlot = keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [poolId, 6n]));
export const slot0Slot = stateSlot;
export const liquiditySlot = `0x${(hexToBigInt(stateSlot) + 3n).toString(16).padStart(64, "0")}` as Hex;

/** Unpacks slot0: sqrtPriceX96 in the low 160 bits, then a signed 24-bit tick. */
export function decodeSlot0(word: Hex) {
  const v = hexToBigInt(word);
  const sqrtPriceX96 = v & ((1n << 160n) - 1n);
  let tick = Number((v >> 160n) & 0xffffffn);
  if (tick >= 0x800000) tick -= 0x1000000;
  return { sqrtPriceX96, tick };
}

export const decodeLiquidity = (word: Hex) => hexToBigInt(word) & ((1n << 128n) - 1n);
