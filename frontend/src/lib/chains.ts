import { createPublicClient, defineChain, fallback, http } from "viem";
import { unichainSepolia } from "viem/chains";

export const unichain = defineChain({
  ...unichainSepolia,
  blockExplorers: { default: { name: "Uniscan", url: "https://sepolia.uniscan.xyz" } },
});

export const lasna = defineChain({
  id: 5318007,
  name: "Reactive Lasna",
  nativeCurrency: { name: "Lasna REACT", symbol: "lREACT", decimals: 18 },
  rpcUrls: { default: { http: ["https://lasna-rpc.rnk.dev/"] } },
  blockExplorers: { default: { name: "Reactscan", url: "https://lasna.reactscan.net" } },
  testnet: true,
});

/** Public node first: the official endpoint rate-limits bursts. Both allow browser requests. */
export const unichainClient = createPublicClient({
  chain: unichain,
  transport: fallback([
    http("https://unichain-sepolia-rpc.publicnode.com", { batch: true }),
    http("https://sepolia.unichain.org", { batch: true }),
  ]),
  batch: { multicall: true },
});

export const lasnaClient = createPublicClient({ chain: lasna, transport: http("https://lasna-rpc.rnk.dev/") });

/** Unichain Sepolia makes exactly one block a second. */
export const UNICHAIN_BLOCK_SECONDS = 1;

export const txUrl = (hash: string) => `${unichain.blockExplorers.default.url}/tx/${hash}`;
export const addressUrl = (address: string) => `${unichain.blockExplorers.default.url}/address/${address}`;
export const lasnaAddressUrl = (address: string) => `${lasna.blockExplorers.default.url}/address/${address}`;
