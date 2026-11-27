# Threat model

Zenith pays curators for skill measured against a passive control, and takes part of a bond when they fall behind it. Anything that moves money on a score is a target, so we attacked our own rules before anyone else could. Each attack below is a test in [`test/ZenithAttacks.t.sol`](../test/ZenithAttacks.t.sol), run end to end against the real hook, settler and PoolManager. The numbers are from those tests (token amounts, 18 decimals).

Two of these were real holes in the code as it stood on Nov 26: the deposit sandwich, which we demonstrated, and the slash sandwich, which follows from the same arithmetic. Both are now fixed, and each defence has a planted bug in [`script/mutation.sh`](../script/mutation.sh) to prove the tests catch it if it regresses.

## Who can attack

| Actor | What they control |
|---|---|
| Curator | Its sleeve's shape, its own trades in the pool, when it acts within a period |
| Depositor | When it deposits and withdraws, and how much |
| Anyone | Swaps, donations, calling `poke`, `settle`, `release` and `forceClose` |

Curators never hold depositors' funds: the hook executes shapes in the sleeve's own positions, and an invariant test checks that no tokens or claims ever reach a curator.

## Attacks and defences

### 1. Pushing the price around settlement

**Attack.** A curator that has cut its liquidity since the period began moves the price just before settlement. At the pushed price its smaller position seems to have lost less than the control, so the score rises and a fee is paid. It then moves the price back, all in one transaction.

**Defence.** The hook records the pool price before the first swap of each block (`beforeSwap`). Every checkpoint, rebase and bond check values holdings at that block-open price, so nothing done inside the block can move a score. The hook returns no delta and no fee override, so the pool routes exactly like a hookless one.

**Result.** `test_pricePushAroundSettlementEarnsNoFee`:

| Settlement | Excess |
|---|---|
| Without a push | −0.000000000000000004 |
| After a push in the same block | −0.79 |
| After the same push held into the next block | **+37.10** |

A push inside the block earns nothing; the lower score comes from the fees the push itself paid to the pool. The third row shows why the clamp matters: without it, the same push would have been worth 37 tokens of excess. A push now has to survive a whole block open to arbitrage.

### 2. Pushing the price to force-close a sleeve, or to shape without enough bond

**Attack.** A sleeve's bond must be at least 5% of its value. Someone pushes the price so a bonded sleeve looks under-bonded and calls `forceClose`, or an under-bonded curator pushes it so its sleeve looks small enough to shape.

**Defence.** `ZenithSettler.sleeveValue` uses the block-open price too.

**Result.** `test_pricePushCannotForceCloseABondedSleeve` and `test_pricePushCannotLetAnUnderBondedCuratorShape`. Neither works inside the block. A forced close succeeds only once the moved price has held for a block, at which point the sleeve really is under-bonded.

### 3. Wash trading through one's own range

**Attack.** A curator adds liquidity, then trades back and forth through its own range so its sleeve collects fees that look like good timing.

**Defence.** None is needed in the code. The curator pays every fee in full, gets back only its sleeve's share of them, and is paid 20% of the resulting excess.

**Result.** `test_washTradingCostsTheCuratorMoreThanItEarns`. Twenty round trips of 50 tokens, each ending at the exact starting price, raise the excess by 3.38 and earn a fee of 0.68. The curator ends **5.29 tokens poorer**.

### 4. Deposit sandwich around a large swap (fixed today)

**Attack.** Deposit heavily just before a large swap and withdraw just after, to take the fees that existing depositors' positions earn.

**What we found.** Deposits used to land as idle tokens while buying shares of everything, positions included. In a probe with a deposit ten times the sleeve, the existing depositor kept only 0.021 of the 0.226 in fees it earned alone: **the attacker took 91%**.

**Defence.** A deposit now adds the same fraction of liquidity to every range, mirroring how a withdrawal removes it. The new money is in the pool, earning fees, from the moment it arrives.

**Result.** `test_depositSandwichEarnsNoMoreThanDirectLiquidity`:

| Existing depositor's exit value | Amount |
|---|---|
| No attacker | 200.2508 |
| Attacker adds the same liquidity directly to the pool | 200.0268 |
| Attacker deposits through Zenith | 200.0268 (2 wei apart) |

Depositing through Zenith is now exactly as good as being any other liquidity provider in that range. Just-in-time liquidity still dilutes every LP in a v4 pool, Zenith's and everyone else's; Zenith no longer adds a way to do it without providing liquidity.

A fuzz test (`testFuzz_depositIntoPositionsIsBoundedAndRoundTripsSafely`, 10,000 runs) checks random shapes, prices and offers: a deposit never charges more than offered and an immediate round trip never returns more than was paid. It found a 3-wei overcharge on very large deposits, now fixed.

### 5. Slash sandwich around a scheduled settlement (fixed today)

**Attack.** Settlement runs on a known schedule. Deposit heavily just before a settlement that slashes the curator, then leave, taking compensation meant for the depositors who bore the loss.

**Defence.** The settler holds a slash and releases it evenly over the next period, in the same way Yearn v3 vaults unlock profits gradually. Anyone can call `release`; Reactive Network will call it on a schedule.

**Result.** `test_slashSandwichTakesAlmostNothing`. Against a slash of 0.1288, an attacker who deposits ten times the sleeve and stays an hour gains 0.00066: **0.5%** of the slash. Released all at once, it would have taken its share of the sleeve, about 90%; the mutation check plants exactly that bug and this test catches it.

## Argued, not yet tested

- **Griefing another sleeve.** Trading heavily can lower the score of a sleeve whose liquidity is below its period-start level, as in row two of attack 1. The attacker pays the pool's fee on all of that volume (0.9 tokens for the 300-token push) to cause a slash of 20% of the drop (about 0.16), and gains nothing.
- **Donations.** `donate` pays in-range positions directly. A curator donating to its own range pays all in-range LPs to get back its share, which is wash trading with no trade. Scores are taken from holdings, never from `feesAccrued`, so a donation cannot be misread.
- **Period-boundary timing.** A curator can cut liquidity just before a period closes, so the next period's baseline is low. Liquidity added later is then scored against the control's long-run average, which makes the period a bet on beating that average. The high- and low-water marks pay gains and slash losses alike, so the bet has no expected edge.

## Known limitations

- **A price held across a block.** The clamp makes in-block pushes free of effect, not multi-block ones. A push that survives a block is exposed to arbitrage for that block. On a chain with private ordering, a well-funded attacker could still try it, and the attack tests show the size of the prize.
- **Leaving before a settlement.** A depositor who withdraws before settlement neither pays its share of that period's curator fee nor receives its share of a slash. Funds handle this with fee equalisation; Zenith does not yet.
- **One pool per hook, token1 bonds and a fixed 7-day period** are design choices for the hookathon, not limits of the method.
