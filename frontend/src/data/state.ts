import type { Address } from "viem";

import { erc20Abi } from "viem";
import { poolManagerAbi, zenithHookAbi, zenithSettlerAbi, zenithReactiveAbi } from "../generated/abis";
import { deployment } from "../generated/deployment";
import { lasnaClient, unichainClient } from "../lib/chains";
import { decodeLiquidity, decodeSlot0, liquiditySlot, slot0Slot } from "../lib/pool";

const d = deployment.unichain;
const hook = { address: d.hook, abi: zenithHookAbi } as const;
const settler = { address: d.settler, abi: zenithSettlerAbi } as const;
const manager = { address: d.poolManager, abi: poolManagerAbi } as const;

export interface Range {
  tickLower: number;
  tickUpper: number;
  liquidity: bigint;
}

export interface Sleeve {
  id: number;
  curator: Address;
  idle0: bigint;
  idle1: bigint;
  fees0: bigint;
  fees1: bigint;
  ranges: Range[];
  totalShares: bigint;
  score: {
    held0: bigint;
    held1: bigint;
    inRange: bigint;
    startInRange: bigint;
    indexLast: bigint;
    excess: bigint;
    lastExcess: bigint;
    lastCheckpoint: bigint;
    periodStart: bigint;
  };
  /** Settlement account; absent for the control. */
  account?: {
    bond: bigint;
    cumulative: bigint;
    highWater: bigint;
    lowWater: bigint;
    feeOwed: bigint;
    pending: bigint;
    lastRelease: bigint;
    releaseEnd: bigint;
  };
  bonded?: boolean;
  value?: bigint;
}

export interface ZenithState {
  block: bigint;
  timestamp: bigint;
  sqrtPriceX96: bigint;
  tick: number;
  openSqrtPriceX96: bigint;
  openTick: number;
  poolLiquidity: bigint;
  controlIndex: bigint;
  controlIndexStart: bigint;
  period: bigint;
  shareBps: bigint;
  bondBps: bigint;
  sleeves: Sleeve[];
  keeperBalance: bigint;
}

export async function readState(): Promise<ZenithState> {
  const block = await unichainClient.getBlock({ blockTag: "latest" });
  const blockNumber = block.number!;
  const head = await unichainClient.multicall({
    allowFailure: false,
    blockNumber,
    contracts: [
      { ...manager, functionName: "extsload", args: [slot0Slot] },
      { ...manager, functionName: "extsload", args: [liquiditySlot] },
      { ...hook, functionName: "blockOpenPrice" },
      { ...hook, functionName: "sleeveCount" },
      { ...hook, functionName: "controlIndex" },
      { ...hook, functionName: "controlIndexStart" },
      { ...hook, functionName: "PERIOD" },
      { ...settler, functionName: "SHARE_BPS" },
      { ...settler, functionName: "BOND_BPS" },
    ],
  });
  const [slot0Word, liquidityWord, open, count, controlIndex, controlIndexStart, period, shareBps, bondBps] = head as [
    `0x${string}`,
    `0x${string}`,
    readonly [bigint, number],
    bigint,
    bigint,
    bigint,
    bigint,
    bigint,
    bigint,
  ];
  const { sqrtPriceX96, tick } = decodeSlot0(slot0Word);

  const ids = Array.from({ length: Number(count) }, (_, i) => BigInt(i));
  const perSleeve = await unichainClient.multicall({
    allowFailure: false,
    blockNumber,
    contracts: ids.flatMap((id) => [
      { ...hook, functionName: "getSleeve", args: [id] },
      { ...hook, functionName: "getRanges", args: [id] },
      { ...hook, functionName: "getScore", args: [id] },
      { ...hook, functionName: "totalShares", args: [id] },
      { ...settler, functionName: "accounts", args: [id] },
      { ...settler, functionName: "isBonded", args: [id] },
      { ...settler, functionName: "sleeveValue", args: [id] },
    ]),
  });

  const sleeves: Sleeve[] = ids.map((id, i) => {
    const [s, ranges, score, totalShares, account, bonded, value] = perSleeve.slice(i * 7, i * 7 + 7) as never as [
      { curator: Address; idle0: bigint; idle1: bigint; fees0: bigint; fees1: bigint },
      readonly { tickLower: number; tickUpper: number; liquidity: bigint }[],
      Sleeve["score"],
      bigint,
      readonly [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint],
      boolean,
      bigint,
    ];
    const [bond, cumulative, highWater, lowWater, feeOwed, pending, lastRelease, releaseEnd] = account;
    const isControl = id === 0n;
    return {
      id: Number(id),
      curator: s.curator,
      idle0: s.idle0,
      idle1: s.idle1,
      fees0: s.fees0,
      fees1: s.fees1,
      ranges: ranges.map((r) => ({ tickLower: r.tickLower, tickUpper: r.tickUpper, liquidity: r.liquidity })),
      totalShares,
      score: { ...score },
      account: isControl ? undefined : { bond, cumulative, highWater, lowWater, feeOwed, pending, lastRelease, releaseEnd },
      bonded: isControl ? undefined : bonded,
      value,
    };
  });

  const keeperBalance = await unichainClient.getBalance({ address: d.keeper, blockNumber });

  return {
    block: blockNumber,
    timestamp: block.timestamp,
    sqrtPriceX96,
    tick,
    openSqrtPriceX96: open[0],
    openTick: open[1],
    poolLiquidity: decodeLiquidity(liquidityWord),
    controlIndex,
    controlIndexStart,
    period,
    shareBps,
    bondBps,
    sleeves,
    keeperBalance,
  };
}

export interface LasnaState {
  block: bigint;
  secondsPerBlock: number;
  reactiveBalance: bigint;
  keeper: Address;
}

let lasnaRate: number | null = null;

export async function readLasna(): Promise<LasnaState> {
  const latest = await lasnaClient.getBlock({ blockTag: "latest" });
  if (lasnaRate === null) {
    const earlier = await lasnaClient.getBlock({ blockNumber: latest.number! - 1000n });
    lasnaRate = Number(latest.timestamp - earlier.timestamp) / 1000;
  }
  const [reactiveBalance, keeper] = await Promise.all([
    lasnaClient.getBalance({ address: deployment.lasna.reactive }),
    lasnaClient.readContract({ address: deployment.lasna.reactive, abi: zenithReactiveAbi, functionName: "keeper" }),
  ]);
  return { block: latest.number!, secondsPerBlock: lasnaRate, reactiveBalance, keeper };
}

export interface UserState {
  balance0: bigint;
  balance1: bigint;
  eth: bigint;
  allowance: Record<"hook" | "router" | "settler", { token0: bigint; token1: bigint }>;
  shares: bigint[];
}

export async function readUser(user: Address, sleeveCount: number): Promise<UserState> {
  const t0 = { address: d.token0, abi: erc20Abi } as const;
  const t1 = { address: d.token1, abi: erc20Abi } as const;
  const spenders = { hook: d.hook, router: d.swapRouter, settler: d.settler } as const;
  const calls = [
    { ...t0, functionName: "balanceOf", args: [user] },
    { ...t1, functionName: "balanceOf", args: [user] },
    ...Object.values(spenders).flatMap((spender) => [
      { ...t0, functionName: "allowance", args: [user, spender] },
      { ...t1, functionName: "allowance", args: [user, spender] },
    ]),
    ...Array.from({ length: sleeveCount }, (_, i) => ({
      ...hook,
      functionName: "sharesOf",
      args: [BigInt(i), user],
    })),
  ];
  const r = (await unichainClient.multicall({ allowFailure: false, contracts: calls as never })) as bigint[];
  const eth = await unichainClient.getBalance({ address: user });
  return {
    balance0: r[0],
    balance1: r[1],
    eth,
    allowance: {
      hook: { token0: r[2], token1: r[3] },
      router: { token0: r[4], token1: r[5] },
      settler: { token0: r[6], token1: r[7] },
    },
    shares: r.slice(8),
  };
}
