# Zenith

**Curated liquidity that pays curators for skill, not market luck.**

Zenith is a Uniswap v4 hook for curated liquidity, built for the Uniswap Hook Incubator (UHI11) hookathon, Nov 16 – Dec 3, 2026.

> Status: in active development. This README describes what is built so far; anything not yet built is listed under Roadmap.

## The idea

Curated LP vaults are judged on total return, which mostly measures which tokens a vault held while prices moved, and their operators usually take a cut of trading fees whether or not they added anything. Neither measures how well a vault made markets.

In Zenith, curators never hold funds. A curator posts a liquidity shape and the hook executes it in that curator's own sleeve of a shared pool, next to a passive control sleeve that is never touched. Every sleeve faces the same swaps. The scoring being built will measure each sleeve's market-making skill against the control and pay curators only for the excess.

## Evidence

We found 57 managed-vault contracts on three mainnet ETH/stablecoin pools (2021 to 2024) and studied the six with meaningful size and history:

- **None showed statistically significant skill over a passive LP.**
- **In at least four, the operator or protocol still took a cut of every fee collected.**
- **Skill explained only 14% of the weekly variation in total return against passive.**

Method, limits, corrections and an offline re-run are in [evidence/](evidence/README.md).

## Partner integration: Reactive Network (planned)

Zenith settles curator scores, fees and bonds in periods. Reactive Network closes each period automatically, with no keeper bot:

- The hook runs on **Unichain Sepolia** (chain 1301), next to the Uniswap v4 PoolManager.
- A reactive contract on **Reactive Lasna** subscribes to a Cron tick to close each settlement period on schedule, and to the hook's own events for urgent actions such as a curator's bond running out.
- Callbacks arrive through Unichain Sepolia's callback proxy (`0x775c9B990ADe401060B78D0e98684eEf8d2466C1`). The receiving contract accepts a call only from that proxy and only when it was requested by Zenith's own reactive contract.
- Reactive bills callbacks to the receiving contract in native ETH, so settlement is handled by a small, separately funded settler contract rather than the hook itself.

## Roadmap

- [x] Sleeve registry with a passive control sleeve, bound to one pool
- [x] ERC-6909 idle-balance ledger per sleeve (fuzz-tested: ledger always equals claims)
- [x] Curator shapes executed as hook-owned positions, one salt per sleeve (fuzz-tested against random swaps)
- [x] Fee attribution test: each sleeve, and the control, matches a standalone v4 position to the wei (fuzz-tested, mutation-checked)
- [x] Stateful invariant tests: the ledger equals the claims, stored positions match the pool, curators never hold funds, the hook holds no loose tokens, and fees never decrease (deep run: 256 runs of 128 random actions, all held)
- [x] Mainnet evidence, reproducible offline
- [x] Benchmark requirement pinned by test: a static narrow range must not count as skill
- [x] Scoring rule chosen by attacking six candidates with history-only strategies on mainnet data ([evidence](evidence/README.md#choosing-the-scoring-rule))
- [x] Skill scoring in the hook: liquidity changes since period start, times the control's per-liquidity result above its long-run average (static and idle curators score zero on a real PoolManager; timing scores; deposits never count)
- [ ] Symmetric curator fee with a bond
- [x] Deploy script (mined hook address, CREATE2) and an end-to-end demo script, run on a local node
- [ ] Settlement price clamp and forced-close safety
- [ ] Attack tests (wash trading, price pushes, idle curators)
- [ ] Reactive Network settlement on Unichain Sepolia and Reactive Lasna
- [ ] Twin-pool demo, gas report, frontend

## Build and test

```bash
git clone --recursive https://github.com/Dydex/zenith.git
forge build
forge test
```

Requires [Foundry](https://book.getfoundry.sh/).

For the deep settings used as evidence (10,000 fuzz runs, and 256 invariant runs of 128 random actions each):

```bash
FOUNDRY_PROFILE=deep forge test
```

## Deploy and demo

The deploy script mines a hook address that carries the permission flags, deploys the hook through the CREATE2 factory and initialises the pool. On Unichain Sepolia it uses Uniswap's official PoolManager; on a local node it deploys a fresh one. Addresses are written to `deployments/<chain id>.json`. The demo script then runs one full flow against that deployment: an ordinary LP, the funded control, a curator sleeve with a two-range shape, swaps in both directions and fee collection.

```bash
anvil &
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil key>
forge script script/Demo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil key>
```

To check that the fee tests can actually catch accounting bugs, run the mutation check. It plants one deliberate bug at a time in the hook and expects the twin fee tests to fail on each:

```bash
script/mutation.sh
```
