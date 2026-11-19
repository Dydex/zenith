# Zenith

**Curated liquidity that pays curators for skill, not market luck.**

Zenith is a Uniswap v4 hook for curated liquidity, built for the Uniswap Hook Incubator (UHI11) hookathon, Nov 16 – Dec 3, 2026.

> Status: in active development. This README describes what is built so far; anything not yet built is listed under Roadmap.

## The idea

Curated LP vaults are judged and paid on total value. That mostly measures which tokens a vault held while prices moved, not how well it made markets.

In Zenith, curators never hold funds. A curator posts a liquidity shape and the hook executes it in that curator's own sleeve of a shared pool, next to a passive control sleeve that is never touched. Every sleeve faces the same swaps, so the comparison is fair. The hook scores each sleeve's market-making skill against the control and pays curators only for the excess.

## Partner integration: Reactive Network (planned)

Zenith settles curator scores, fees and bonds in periods. Reactive Network closes each period automatically, with no keeper bot:

- The hook runs on **Unichain Sepolia** (chain 1301), next to the Uniswap v4 PoolManager.
- A reactive contract on **Reactive Lasna** subscribes to a Cron tick to close each settlement period on schedule, and to the hook's own events for urgent actions such as a curator's bond running out.
- Callbacks arrive through Unichain Sepolia's callback proxy (`0x775c9B990ADe401060B78D0e98684eEf8d2466C1`). The receiving contract accepts a call only from that proxy and only when it was requested by Zenith's own reactive contract.
- Reactive bills callbacks to the receiving contract in native ETH, so settlement is handled by a small, separately funded settler contract rather than the hook itself.

## Roadmap

- [x] Sleeve registry with a passive control sleeve, bound to one pool
- [x] ERC-6909 idle-balance ledger per sleeve (fuzz-tested: ledger always equals claims)
- [ ] Per-sleeve positions executed from curator shapes
- [ ] Fee attribution test: each sleeve matches a standalone v4 position to the wei
- [ ] Skill scoring against the control, scaled to deployed liquidity
- [ ] Symmetric curator fee with a bond
- [ ] Settlement price clamp and forced-close safety
- [ ] Attack tests (wash trading, price pushes, idle curators)
- [ ] Reactive Network settlement on Unichain Sepolia and Reactive Lasna
- [ ] Twin-pool demo, gas report, frontend

## Build and test

```bash
git clone --recursive <repo-url>
forge build
forge test
```

Requires [Foundry](https://book.getfoundry.sh/).
