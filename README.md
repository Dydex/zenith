# Zenith

**Curated liquidity that pays curators for skill, not market luck.**

Zenith is a Uniswap v4 hook for curated liquidity, built for the Uniswap Hook Incubator (UHI11) hookathon, Nov 16 – Dec 3, 2026.

> Status: in active development. This README describes what is built so far; anything not yet built is listed under Roadmap.

## The idea

Curated LP vaults are judged and paid on total value. That mostly measures which tokens a vault held while prices moved, not how well it made markets.

In Zenith, curators never hold funds. A curator posts a liquidity shape and the hook executes it in that curator's own sleeve of a shared pool, next to a passive control sleeve that is never touched. Every sleeve faces the same swaps, so the comparison is fair. The hook scores each sleeve's market-making skill against the control and pays curators only for the excess.

## Roadmap

- [ ] Per-sleeve positions and ERC-6909 idle-balance ledger
- [ ] Fee attribution test: each sleeve matches a standalone v4 position to the wei
- [ ] Skill scoring against the control, scaled to deployed liquidity
- [ ] Symmetric curator fee with a bond
- [ ] Settlement price clamp and forced-close safety
- [ ] Attack tests (wash trading, price pushes, idle curators)
- [ ] Twin-pool demo, gas report, frontend

## Build and test

```bash
git clone --recursive <repo-url>
forge build
forge test
```

Requires [Foundry](https://book.getfoundry.sh/).
