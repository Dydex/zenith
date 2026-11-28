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

## Contracts

| Contract | Role |
|---|---|
| [`ZenithHook`](src/ZenithHook.sol) | Sleeves, curator shapes, depositor shares and skill scoring for one pool |
| [`ZenithSettler`](src/ZenithSettler.sol) | Curator bonds and symmetric settlement of each period; the receiver for Reactive Network callbacks |
| [`ZenithMath`](src/ZenithMath.sol) | Position valuation and deposit maths, linked as a library so the hook stays under the 24 KB size limit |
| [`ZenithKeeper`](src/ZenithKeeper.sol) | Receives Reactive Network callbacks on the hook's chain and runs the scheduled work: settle, release, forced close |
| [`ZenithReactive`](src/ZenithReactive.sol) | Reactive contract on Reactive Network: turns Cron ticks and deposits into callbacks to the keeper |

## Security

We attacked Zenith's own rules: price pushes, wash trading, and depositors timing their entry around swaps and settlements. Each attack is a test against the real contracts, with the numbers it produced, in the [threat model](docs/threat-model.md). Two were real holes and are fixed; the known limitations are listed there too.

## Partner integration: Reactive Network

Zenith settles curator scores, fees and bonds in periods, releases slashes over time and closes sleeves whose bond falls short. None of that should depend on someone remembering to call it, and none of it should need a keeper bot we run. Reactive Network does it:

- [`ZenithReactive`](src/ZenithReactive.sol) runs on **Reactive Lasna**, on Reactive Omni. It subscribes through the system contract to a Cron tick (Cron1000, every 1,000 Reactive blocks, about 18 minutes) and to the hook's `SleeveFunded` event on Unichain Sepolia.
- On each tick it asks for a callback to [`ZenithKeeper`](src/ZenithKeeper.sol) on **Unichain Sepolia** (chain 1301), which sweeps every sleeve: it settles those whose period is over, releases vested slashes to depositors and force-closes any whose bond no longer covers them. A sweep that runs low on gas stops before a sleeve it might not finish and resumes there next tick; one sleeve failing never blocks the others.
- On a deposit it asks the keeper to check that sleeve's bond at once, because a larger sleeve needs a larger bond.
- Callbacks arrive through Unichain Sepolia's callback proxy (`0x775c9B990ADe401060B78D0e98684eEf8d2466C1`), which writes the requesting reactive contract's address into each one. The keeper accepts them only from that proxy and only from its own reactive contract, fixed when it was deployed. It holds a little ETH to pay for them.
- Everything the keeper does is a public function anyone can call, so Zenith keeps working if Reactive stops. Reactive makes sure the work is always done, on time, by no one in particular.

Built on Reactive's [reactive-lib-omni](https://github.com/Reactive-Network/reactive-lib-omni) and tested with the system contract and callback proxy simulated, including the whole loop from a Cron tick to a settled sleeve ([`test/ZenithReactive.t.sol`](test/ZenithReactive.t.sol)). Deployed on Unichain Sepolia and Reactive Lasna, with Cron callbacks arriving live (see [Live deployment](#live-deployment)).

## Live deployment

The hook, settler and library were deployed on Nov 27, 2026, and the Reactive automation on Nov 28. Every contract's source is verified on [Sourcify](https://sourcify.dev/).

**Unichain Sepolia** (chain 1301), on Uniswap's official v4 PoolManager [`0x00B0…62AC`](https://sepolia.uniscan.xyz/address/0x00B036B58a818B1BC34d502D3fE730Db729e62AC):

| Contract | Address |
|---|---|
| ZenithHook | [`0x8EFc0b2F3E00722a9b8e653367252c720f446080`](https://sepolia.uniscan.xyz/address/0x8EFc0b2F3E00722a9b8e653367252c720f446080) |
| ZenithSettler | [`0x67C62E59253bC15b2792720f1867bF6a5e57c073`](https://sepolia.uniscan.xyz/address/0x67C62E59253bC15b2792720f1867bF6a5e57c073) |
| ZenithKeeper | [`0x008972e31A14f4dC2Adddf362661Fa08aB657029`](https://sepolia.uniscan.xyz/address/0x008972e31A14f4dC2Adddf362661Fa08aB657029) |
| ZenithMath | [`0x608800d3fAEf9F452a382f8C53586B56c5453739`](https://sepolia.uniscan.xyz/address/0x608800d3fAEf9F452a382f8C53586B56c5453739) |
| Demo tokens (zUSD, zETH) | [`0x45aeE45c5381aB9EE52b6FF7A160D5343D6ac72e`](https://sepolia.uniscan.xyz/address/0x45aeE45c5381aB9EE52b6FF7A160D5343D6ac72e), [`0xD93dD7c1aaf14536307f2656c72Af4C676059AB3`](https://sepolia.uniscan.xyz/address/0xD93dD7c1aaf14536307f2656c72Af4C676059AB3) |

**Reactive Lasna** (chain 5318007):

| Contract | Address |
|---|---|
| ZenithReactive | [`0x45aeE45c5381aB9EE52b6FF7A160D5343D6ac72e`](https://lasna.reactscan.net/address/0x45aeE45c5381aB9EE52b6FF7A160D5343D6ac72e) |

The pool (0.3% fee, tick spacing 60) holds the control sleeve and one curator sleeve with a two-range shape, funded, bonded and traded through by [`script/Demo.s.sol`](script/Demo.s.sol). Full records are in [`deployments/`](deployments/) and [`broadcast/`](broadcast/).

**The loop runs live.** The first Cron callback reached the keeper on Nov 28 in [`0x2637…3a4f`](https://sepolia.uniscan.xyz/tx/0x2637218a8d85105c0a4e486d37382e19fec6d99f2110b1a47a7f591e584e3a4f): Reactive's relayer called the callback proxy, the proxy called `ZenithKeeper.tick`, and the keeper swept the pool's one curator sleeve (`Swept(1, 0, 0, 0)`: visited, nothing due yet). Each tick since leaves the same trace on the [keeper](https://sepolia.uniscan.xyz/address/0x008972e31A14f4dC2Adddf362661Fa08aB657029).

Our first keeper and reactive contract were built on Reactive's legacy library. Reactive had since moved to Reactive Omni, Lasna never registered that contract's subscriptions, and it never reacted, so both were rebuilt on [reactive-lib-omni](https://github.com/Reactive-Network/reactive-lib-omni) and redeployed. The originals are still on chain; their records and the reason are in [`deployments/legacy/`](deployments/legacy/).

## Roadmap

- [x] Sleeve registry with a passive control sleeve, bound to one pool
- [x] ERC-6909 idle-balance ledger per sleeve (fuzz-tested: ledger always equals claims)
- [x] Curator shapes executed as hook-owned positions, one salt per sleeve (fuzz-tested against random swaps)
- [x] Fee attribution test: each sleeve, and the control, matches a standalone v4 position to the wei (fuzz-tested, mutation-checked)
- [x] Stateful invariant tests: the ledger equals the claims, stored positions match the pool, curators never hold funds, the hook holds no loose tokens, and fees never decrease (deep run: 256 runs of 128 random actions, all held)
- [x] Mainnet evidence, reproducible offline
- [x] Benchmark requirement pinned by test: a static narrow range must not count as skill
- [x] Scoring rule chosen by attacking six candidates with history-only strategies on mainnet data ([evidence](evidence/README.md#choosing-the-scoring-rule))
- [x] Depositor shares: deposits buy, and withdrawals return, the same fraction of every position and idle balance, neutral to the curator's score
- [x] Skill scoring in the hook: liquidity changes since period start, times the control's per-liquidity result above its long-run average (static and idle curators score zero on a real PoolManager; timing scores; deposits never count)
- [x] Symmetric curator fee with a bond: 20% of new highs in cumulative excess to the curator, 20% of new lows from its bond to depositors, a 5% minimum bond, and forced close when it falls short ([`ZenithSettler`](src/ZenithSettler.sol))
- [x] Deploy script (mined hook address, CREATE2) and an end-to-end demo script, run on a local node
- [x] Settlement price clamp: scores and bonds valued at the block-open price, recorded in `beforeSwap` with no delta or fee override
- [x] Attack tests: price pushes around settlement, forced close and bonding; wash trading; deposit and slash sandwiches ([threat model](docs/threat-model.md)). Two were real holes and are fixed
- [x] Slashed bond released to depositors over the next period
- [x] Reactive Network automation: reactive contract, keeper and the full callback loop, tested with a simulated proxy (worst-case sleeve 693k gas cold, within the keeper's 1M allowance)
- [x] Live deployment on Unichain Sepolia and Reactive Lasna, verified on Sourcify, with Reactive Cron callbacks reaching the keeper
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

The deploy script mines a hook address that carries the permission flags, deploys the hook through the CREATE2 factory, deploys the settler, and initialises the pool. On Unichain Sepolia it uses Uniswap's official PoolManager; on a local node it deploys a fresh one. Addresses are written to `deployments/<chain id>.json`. The demo script then runs one full flow against that deployment: an ordinary LP, the funded control, a curator sleeve with a two-range shape, swaps in both directions and fee collection.

```bash
anvil &
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil key>
forge script script/Demo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil key>
```

On testnet, deploy Zenith to Unichain Sepolia, then the Reactive automation in three steps: the reactive contract on Reactive Lasna, the keeper (which must know the reactive contract's address) next to the hook, and finally the link from the reactive contract to the keeper:

```bash
forge script script/Deploy.s.sol --rpc-url https://sepolia.unichain.org --broadcast --account <name>
forge script script/DeployReactive.s.sol --rpc-url https://lasna-rpc.rnk.dev/ --broadcast --account <name>
forge script script/DeployKeeper.s.sol --rpc-url https://sepolia.unichain.org --broadcast --account <name>
forge script script/SetKeeper.s.sol --rpc-url https://lasna-rpc.rnk.dev/ --broadcast --account <name>
```

To check that the tests can actually catch bugs, run the mutation check. It plants one deliberate bug at a time in the hook or settler (accounting, scoring, settlement and each attack defence) and expects the relevant tests to fail on each:

```bash
script/mutation.sh
```
