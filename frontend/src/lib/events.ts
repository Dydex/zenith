import { decodeEventLog, hexToBigInt, type Abi, type Address, type Hex } from "viem";

import { poolManagerAbi, zenithHookAbi, zenithKeeperAbi, zenithSettlerAbi } from "../generated/abis";
import { deployment } from "../generated/deployment";
import { poolId } from "./pool";

/**
 * Event history comes from Blockscout's Unichain Sepolia API: free, keyless, open to browsers, and archival.
 * The public RPC prunes old logs, and the official one rate-limits bursts, so neither can rebuild a pool's history.
 */
const BLOCKSCOUT = "https://unichain-sepolia.blockscout.com/api";
/** Blockscout returns at most this many logs per request; a full page means there may be more. */
const PAGE = 1000;

export type Source = "hook" | "settler" | "keeper" | "pool";

export interface ChainEvent {
  source: Source;
  eventName: string;
  args: Record<string, unknown>;
  blockNumber: bigint;
  logIndex: number;
  transactionHash: Hex;
  timestamp: number;
}

interface Stream {
  source: Source;
  abi: Abi;
  address: Address;
  topic1?: Hex;
  from: bigint;
}

const streams: Stream[] = [
  { source: "hook", abi: zenithHookAbi as Abi, address: deployment.unichain.hook, from: BigInt(deployment.unichain.deployBlock) },
  { source: "settler", abi: zenithSettlerAbi as Abi, address: deployment.unichain.settler, from: BigInt(deployment.unichain.deployBlock) },
  { source: "keeper", abi: zenithKeeperAbi as Abi, address: deployment.unichain.keeper, from: BigInt(deployment.unichain.keeperBlock) },
  { source: "pool", abi: poolManagerAbi as Abi, address: deployment.unichain.poolManager, topic1: poolId, from: BigInt(deployment.unichain.deployBlock) },
];

interface RawLog {
  blockNumber: Hex;
  logIndex: Hex;
  transactionHash: Hex;
  timeStamp: Hex;
  data: Hex;
  topics: (Hex | null)[];
}

async function fetchPage(stream: Stream, from: bigint): Promise<RawLog[]> {
  const url = new URL(BLOCKSCOUT);
  url.search = new URLSearchParams({
    module: "logs",
    action: "getLogs",
    fromBlock: from.toString(),
    toBlock: "latest",
    address: stream.address,
    ...(stream.topic1 ? { topic1: stream.topic1 } : {}),
  }).toString();
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Blockscout ${response.status}`);
  const body = (await response.json()) as { message: string; result: RawLog[] | string | null };
  if (Array.isArray(body.result)) return body.result;
  if (body.message === "No logs found" || body.result === null) return [];
  throw new Error(`Blockscout: ${body.message}`);
}

function decode(stream: Stream, raw: RawLog): ChainEvent | null {
  try {
    const topics = raw.topics.filter((t): t is Hex => t !== null) as [Hex, ...Hex[]];
    const { eventName, args } = decodeEventLog({ abi: stream.abi, data: raw.data, topics });
    return {
      source: stream.source,
      eventName: eventName as string,
      args: (args ?? {}) as Record<string, unknown>,
      blockNumber: hexToBigInt(raw.blockNumber),
      logIndex: Number(hexToBigInt(raw.logIndex)),
      transactionHash: raw.transactionHash,
      timestamp: Number(hexToBigInt(raw.timeStamp)),
    };
  } catch {
    return null; // an event this app does not know about
  }
}

const key = (e: ChainEvent) => `${e.transactionHash}:${e.logIndex}`;

/** Every Zenith event so far, fetched once and then only from the last block seen. */
class EventLog {
  private events: ChainEvent[] = [];
  private seen = new Set<string>();
  private next = new Map<Source, bigint>(streams.map((s) => [s.source, s.from]));

  async update(): Promise<ChainEvent[]> {
    const fresh = await Promise.all(streams.map((s) => this.pull(s)));
    const added = fresh.flat().filter((e) => !this.seen.has(key(e)));
    if (added.length > 0) {
      for (const e of added) this.seen.add(key(e));
      this.events = [...this.events, ...added].sort((a, b) =>
        a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1,
      );
    }
    return this.events;
  }

  private async pull(stream: Stream): Promise<ChainEvent[]> {
    const found: ChainEvent[] = [];
    let from = this.next.get(stream.source)!;
    for (;;) {
      const page = await fetchPage(stream, from);
      for (const raw of page) {
        const e = decode(stream, raw);
        if (e) found.push(e);
      }
      if (page.length < PAGE) break;
      // A full page: continue from its last block (duplicates are dropped by key).
      from = hexToBigInt(page[page.length - 1].blockNumber);
    }
    const last = found.length > 0 ? found[found.length - 1].blockNumber : from - 1n;
    // Re-read the last block next time, in case it was still being indexed.
    this.next.set(stream.source, last > from ? last : from);
    return found;
  }
}

export const eventLog = new EventLog();
