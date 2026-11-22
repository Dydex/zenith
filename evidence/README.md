# Mainnet evidence

**Question:** do managed Uniswap v3 vaults show market-making skill, and does the way they are judged and paid measure it?

## Answer

We found 57 vaults on three ETH/stablecoin pools (May 2021 to July 2024). Six held at least $50,000 for at least 13 managed weeks.

- **None showed statistically significant skill over a passive full-range LP.** One was nominally ahead with weekly sampling, and none with daily sampling.
- **In at least four of the six, the operator or protocol still took a cut of trading fees.** The accrued balances are readable on-chain. The cut does not depend on beating anything.
- **Total return is a poor measure of skill.** Skill explains 14% of the week-to-week variation in a vault's total-return gap to passive, and 3% of the day-to-day variation. Most of the rest comes from which tokens the vault held.

"No significant skill" is not proof of no skill: the samples are short and the intervals are wide. Of the 17 alternative specifications tested, one produces a significantly skilled vault: admitting histories as short as four weeks. Full tables and sensitivity checks are in [RESULTS.md](RESULTS.md).

## Reproduce

Offline, standard-library Python 3:

```bash
python3 evidence/scripts/analyze.py
```

From the chain, with no API key (about 15 minutes; `fees.py` also needs Foundry's `cast`):

```bash
python3 evidence/scripts/discover.py
python3 evidence/scripts/fetch.py
python3 evidence/scripts/fees.py
python3 evidence/scripts/analyze.py
```

## Method

- **Discovery:** every contract that minted directly on USDC/WETH 0.05%, USDC/WETH 0.3% or WETH/USDT 0.05% and answers `getTotalAmounts()` or `getUnderlyingBalances()`.
- **Skill:** a share's value now, minus the value of its previous token balances at the current price, over its previous value. That is fees kept minus losses to rebalancing and adverse selection.
- **Passive:** a fresh full-range position in the same pool over the same interval, earning the pool's own fee growth.
- **Main sample:** weeks with at least $50,000 at both ends, from first mint to four weeks after the last, and at least 13 such weeks.
- **Total return:** compounded, in the stablecoin.
- **Intervals:** 95%, with Newey-West errors (four lags).

The main specification was fixed before this dataset was analysed, though after an earlier, smaller study of some of the same vaults (see Corrections). Vault and pool state was read from two different providers, which had to agree exactly. Log discovery and block timestamps come from one provider.

## Limits

- Six vaults, all on USDC/WETH, mostly in 2021 to 2023. The results do not generalise to all managers.
- "Managed vault" is detected by interface. Some Gelato/Arrakis V1 vaults are close to static, and vaults with other interfaces, or that mint through the position manager, are missed.
- Skill depends on the sampling interval. Token-mix changes inside an interval, from deposits or rebalances, leak price exposure into weekly skill, so daily figures are shown next to weekly ones.
- Vault returns are after the vault's fees. The passive benchmark pays no gas or management fee.
- A full-range benchmark in capital terms is not neutral to concentration, as described next.

## What this changed in Zenith

A concentrated position has several times the liquidity per dollar, so it multiplies both fees and losses. Compared with the control per unit of capital, a curator who posts one narrow range and never moves it looks skilled in a choppy market and negligent in a trend. [`test/ZenithBenchmark.t.sol`](../test/ZenithBenchmark.t.sol) shows this on a real PoolManager and shows that a per-liquidity comparison gives that curator zero. Two requirements follow for the scoring rule:

1. It must not reward or punish concentration by itself.
2. It must checkpoint at every deposit, withdrawal and reshape, so token-mix changes do not count as skill.

## Corrections

An earlier version of this study, not published in this repository, replayed a hand-picked set of vaults and concluded that "0 of 5 beat passive, but 3 of 5 would have been paid". That was wrong in four ways:

- **Sample:** it missed most vaults, including all but one on the 0.3% pool.
- **Arithmetic:** "3 of 5" came from adding weekly percentage differences. Compounded, the same sample gives 2 of 5.
- **Significance:** none of those five was significantly different from passive.
- **Attribution:** a 13.8% weekly loss was blamed on a large deposit. Holders gained 0.14% at the deposit block; the loss followed from a changed token mix during a rally.
