"""Offline analysis of evidence/data. Standard library only, deterministic.

skill       = value now - value of the previous token balances at today's price, over previous value
              (fees kept, minus losses to rebalancing and adverse selection)
skill gap   = vault skill - skill of a passive full-range position in the same pool over the same interval
total value = compounded return in the stablecoin, including the gain or loss on the tokens held
"""
import csv
import datetime
import gzip
import json
import math
import pathlib
import statistics
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parent.parent
DAY = 7_200
WEEK = 7 * DAY
Q128 = 2**128

# Main specification. Alternatives are reported by sensitivity().
MIN_TVL = 50_000
MIN_INTERVALS = 13
GRACE = 4 * WEEK  # a vault counts as managed until four weeks after its last mint


def load():
    study = json.loads((ROOT / "data" / "discovery.json").read_text())

    def read(name):
        with gzip.open(ROOT / "data" / name, "rt", newline="") as handle:
            return list(csv.DictReader(handle))

    pools = {}
    for r in read("pools.csv.gz"):
        root_price = int(r["sqrt_price_x96"]) / 2**96
        pools[r["pool"], int(r["block"])] = (root_price, int(r["fee_growth0_x128"]), int(r["fee_growth1_x128"]))
    states = defaultdict(dict)
    for r in read("vaults.csv.gz"):
        if r["total_supply"]:
            states[r["vault"]][int(r["block"])] = (int(r["amount0"]), int(r["amount1"]), int(r["total_supply"]))
    times = [(int(r["block"]), int(r["timestamp"])) for r in read("blocks.csv.gz")]
    return study, pools, states, times


def intervals(vault, pools, states, blocks, min_tvl, both_ends=True):
    """Per-interval returns for the vault and a fresh passive full-range position."""
    numeraire = vault["numeraire"]

    def value(x, y, price):
        return x + y / price if numeraire == 0 else x * price + y

    out = []
    state = states[vault["vault"]]
    for start, stop in zip(blocks, blocks[1:]):
        if start not in state or stop not in state:
            continue
        x0, y0, supply0 = state[start]
        x1, y1, supply1 = state[stop]
        root0, grown00, grown10 = pools[vault["pool"], start]
        root1, grown01, grown11 = pools[vault["pool"], stop]
        price0, price1 = root0 * root0, root1 * root1
        size0, size1 = value(x0, y0, price0) / 1e6, value(x1, y1, price1) / 1e6
        if size0 <= 0 or size0 < min_tvl or (both_ends and size1 < min_tvl):
            continue

        before = value(x0 / supply0, y0 / supply0, price0)
        after = value(x1 / supply1, y1 / supply1, price1)
        held = value(x0 / supply0, y0 / supply0, price1)

        p_before = value(1 / root0, root0, price0)
        p_after = value(
            1 / root1 + ((grown01 - grown00) % 2**256) / Q128,
            root1 + ((grown11 - grown10) % 2**256) / Q128,
            price1,
        )
        p_held = value(1 / root0, root0, price1)
        out.append({
            "start": start, "stop": stop, "tvl": size0,
            "skill": (after - held) / before, "total": after / before - 1,
            "passive_skill": (p_after - p_held) / p_before, "passive_total": p_after / p_before - 1,
        })
    return out


def grid(vault, end, step=WEEK, offset=0, window="managed"):
    first = (vault["first_mint"] // DAY + 1) * DAY
    last = end if window == "life" else min(vault["last_mint"] + GRACE, end)
    anchor = offset * DAY
    start = first + (anchor - first) % step
    return list(range(start, last + 1, step))


def mean_interval(values, lags=4):
    """Mean and 95% interval, with Newey-West errors for serial correlation."""
    n = len(values)
    mean = statistics.fmean(values)
    if n < 3:
        return mean, -math.inf, math.inf
    error = [x - mean for x in values]
    variance = sum(e * e for e in error) / n
    for lag in range(1, min(lags, n - 1) + 1):
        variance += 2 * (1 - lag / (lags + 1)) * sum(error[i] * error[i - lag] for i in range(lag, n)) / n
    margin = (1.96 + 2.4 / (n - 1)) * math.sqrt(max(variance, 0) / (n - 1))
    return mean, mean - margin, mean + margin


def compound(values):
    return math.prod(1 + x for x in values) - 1


def summarise(vault, rows, per_year=365.25 / 7):
    gaps = [r["skill"] - r["passive_skill"] for r in rows]
    total_gaps = [r["total"] - r["passive_total"] for r in rows]
    mean, low, high = mean_interval(gaps)
    total, passive = compound([r["total"] for r in rows]), compound([r["passive_total"] for r in rows])
    return {
        "vault": vault["vault"], "pool": vault["pool_name"], "first": rows[0]["start"], "last": rows[-1]["stop"],
        "weeks": len(rows), "median_tvl": statistics.median(r["tvl"] for r in rows),
        "skill": sum(r["skill"] for r in rows), "skill_gap": sum(gaps),
        "skill_gap_year": mean * per_year, "low_year": low * per_year, "high_year": high * per_year,
        "total": total, "passive_total": passive,
        "total_gap_compounded": total - passive, "total_gap_summed": sum(total_gaps),
        "sd_skill": statistics.pstdev(gaps), "sd_total": statistics.pstdev(total_gaps),
        "largest_week": max(abs(g) for g in gaps),
    }


def study_sample(study, pools, states, min_tvl=MIN_TVL, min_count=MIN_INTERVALS, offset=0, window="managed", step=WEEK):
    chosen = []
    for vault in study["vaults"]:
        rows = intervals(vault, pools, states, grid(vault, study["to_block"], step, offset, window), min_tvl)
        if len(rows) >= min_count * (WEEK // step):
            chosen.append((summarise(vault, rows, 365.25 * DAY / step), rows))
    return chosen


def headline(chosen):
    s = [row for row, _ in chosen]
    return {
        "vaults": len(s),
        "beat_passive_skill": sum(r["skill_gap"] > 0 for r in s),
        "beat_significantly": sum(r["low_year"] > 0 for r in s),
        "trail_significantly": sum(r["high_year"] < 0 for r in s),
        "skill_above_holding": sum(r["skill"] > 0 for r in s),
        "gained_value": sum(r["total"] > 0 for r in s),
        "gained_but_trailed_skill": sum(r["total"] > 0 and r["skill_gap"] <= 0 for r in s),
        "beat_passive_total": sum(r["total_gap_compounded"] > 0 for r in s),
        "beat_total_but_trailed_skill": sum(r["total_gap_compounded"] > 0 and r["skill_gap"] <= 0 for r in s),
        "beat_skill_but_trailed_total": sum(r["skill_gap"] > 0 and r["total_gap_compounded"] <= 0 for r in s),
        "skill_steadier": sum(r["sd_skill"] < r["sd_total"] for r in s),
    }


def comparisons(chosen):
    quarters = []
    weekly_skill, weekly_total = [], []
    ranked = defaultdict(list)
    for summary, rows in chosen:
        buckets = defaultdict(list)
        for r in rows:
            weekly_skill.append(r["skill"] - r["passive_skill"])
            weekly_total.append(r["total"] - r["passive_total"])
            buckets[r["start"] // (13 * WEEK)].append(r)
        series = {}
        for quarter, rs in buckets.items():
            if len(rs) < 8:
                continue
            skill = sum(r["skill"] - r["passive_skill"] for r in rs)
            total = compound([r["total"] for r in rs]) - compound([r["passive_total"] for r in rs])
            series[quarter] = skill
            ranked[summary["pool"], quarter].append((skill, total, summary["vault"]))
        quarters += [(series[q], series[q + 1]) for q in series if q + 1 in series]
    cells = [c for group in ranked.values() for c in group]
    contests = [g for g in ranked.values() if len(g) >= 2]
    return {
        "weeks": len(weekly_skill),
        "correlation_skill_total": statistics.correlation(weekly_skill, weekly_total),
        "vault_quarters": len(cells),
        "sign_flips": sum((s > 0) != (t > 0) for s, t, _ in cells),
        "contested_quarters": len(contests),
        "same_best_vault": sum(max(g)[2] == max(g, key=lambda c: c[1])[2] for g in contests),
        "persistence_pairs": len(quarters),
        "persistence_same_sign": sum((a > 0) == (b > 0) for a, b in quarters),
        "persistence_correlation": statistics.correlation(*zip(*quarters)) if len(quarters) > 2 else None,
    }


def token_mix(chosen):
    skill = [r["skill"] - r["passive_skill"] for _, rows in chosen for r in rows]
    total = [r["total"] - r["passive_total"] for _, rows in chosen for r in rows]
    mix = [t - s for s, t in zip(skill, total)]
    return {
        "correlation": statistics.correlation(skill, total),
        "share_not_explained_by_skill": 1 - statistics.correlation(skill, total) ** 2,
        "token_mix_variance_to_total_variance": statistics.pvariance(mix) / statistics.pvariance(total),
    }


# The first version of this study: hand-picked sample, start-of-week size filter, summed weekly differences.
EARLIER = {
    "0xa6c49fd13e50a30c65e6c8480aada132011d0613": (13105600, 142),
    "0x9bf7b46c7ad5ab62034e9349ab912c0345164322": (12803200, 148),
    "0x5763bf13a2ce7a76784b36aadf2f9098325d4038": (13811200, 128),
    "0xa9782a2c9c3fb83937f14cdfac9a6d23946c9255": (14476970, 93),
    "0x9ad8d0df2da118dce898b7f5bd9ab749c593a5d9": (17285194, 46),
}


def earlier_study(study, pools, states):
    known, rows = {v["vault"]: v for v in study["vaults"]}, []
    for address, (start, weeks) in EARLIER.items():
        blocks = [start + i * WEEK for i in range(weeks + 1)]
        rows.append(summarise(known[address], intervals(known[address], pools, states, blocks, MIN_TVL, False)))
    return {
        "vaults": len(rows),
        "beat_passive_skill": sum(r["skill_gap"] > 0 for r in rows),
        "trail_significantly": sum(r["high_year"] < 0 for r in rows),
        "beat_passive_total_summed": sum(r["total_gap_summed"] > 0 for r in rows),
        "beat_passive_total_compounded": sum(r["total_gap_compounded"] > 0 for r in rows),
    }


def sensitivity(study, pools, states):
    cases = [(f"weekly grid offset by {d} day(s)", dict(offset=d)) for d in range(1, 7)]
    cases += [(f"minimum size ${t:,}", dict(min_tvl=t)) for t in (10_000, 25_000, 100_000, 250_000, 1_000_000)]
    cases += [(f"minimum {n} sized weeks", dict(min_count=n)) for n in (4, 8, 26, 52)]
    cases += [("whole life, including after management stops", dict(window="life"))]
    cases += [("daily sampling", dict(step=DAY))]
    out = []
    for name, options in cases:
        chosen = study_sample(study, pools, states, **options)
        out.append({"case": name, **headline(chosen)})
    return out


def render(results, times, fees):
    def when(block):
        near = min(times, key=lambda t: abs(t[0] - block))
        seconds = near[1] + (block - near[0]) * 12
        return datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc).strftime("%b %Y")

    head, daily = results["headline"], results["daily"]
    mix, mix_daily = results["token_mix"], results["token_mix_daily"]
    by_day = {r["vault"]: r for r in results["vaults_daily"]}
    lines = [
        "# Results",
        "",
        "Generated by `scripts/analyze.py`. Do not edit by hand.",
        "",
        f"{results['vaults_found']} vaults found, {head['vaults']} in the main sample.",
        "",
        "## Main sample",
        "",
        "Skill gap is against a passive full-range LP, in percentage points a year, with a 95% interval.",
        "",
        "| Vault | Pool | Measured | Weeks | Median size | Skill gap, weekly | Skill gap, daily | Total return | Passive return | Cut of fees accrued on-chain |",
        "|---|---|---|--:|--:|--:|--:|--:|--:|---|",
    ]
    gap = lambda r: f"{100 * r['skill_gap_year']:+.1f} ({100 * r['low_year']:+.1f} to {100 * r['high_year']:+.1f})"
    for r in results["vaults"]:
        fee = fees[r["vault"]]
        lines.append(
            f"| {fee['name']} `{r['vault']}` | {r['pool']} | {when(r['first'])} to {when(r['last'])} | {r['weeks']} "
            f"| ${r['median_tvl']:,.0f} | {gap(r)} | {gap(by_day[r['vault']]) if r['vault'] in by_day else 'n/a'} "
            f"| {100 * r['total']:+.1f}% | {100 * r['passive_total']:+.1f}% | {'yes' if fee['cut_proven'] else 'not proven'} |"
        )
    c = results["comparisons"]
    lines += [
        "",
        "## Findings",
        "",
        "| | Weekly (main) | Daily |",
        "|---|--:|--:|",
        f"| Vaults with skill above passive | {head['beat_passive_skill']} of {head['vaults']} | {daily['beat_passive_skill']} of {daily['vaults']} |",
        f"| ...significant at 95% | {head['beat_significantly']} | {daily['beat_significantly']} |",
        f"| Significantly worse than passive | {head['trail_significantly']} | {daily['trail_significantly']} |",
        f"| Beat passive on compounded total return | {head['beat_passive_total']} | {daily['beat_passive_total']} |",
        f"| Variation in total-return gap not explained by skill | {100 * mix['share_not_explained_by_skill']:.0f}% | {100 * mix_daily['share_not_explained_by_skill']:.0f}% |",
        "",
        f"Operators' cut of fees proven on-chain: {results['cuts_proven']} of {head['vaults']} vaults.",
        "",
        f"Total return and skill disagree on beating passive in {c['sign_flips']} of {c['vault_quarters']} vault-quarters. "
        f"Skill kept its sign into the next quarter in {c['persistence_same_sign']} of {c['persistence_pairs']} cases.",
        "",
        "## Sensitivity",
        "",
        "One choice changed at a time.",
        "",
        "| Change | Vaults | Skill above passive | Significantly above | Significantly below | Beat passive on total return |",
        "|---|--:|--:|--:|--:|--:|",
    ]
    for r in results["sensitivity"]:
        lines.append(
            f"| {r['case']} | {r['vaults']} | {r['beat_passive_skill']} | {r['beat_significantly']} "
            f"| {r['trail_significantly']} | {r['beat_passive_total']} |"
        )
    return "\n".join(lines) + "\n"


def main():
    study, pools, states, times = load()
    fees = json.loads((ROOT / "data" / "fees.json").read_text())
    chosen = study_sample(study, pools, states)
    by_day = study_sample(study, pools, states, step=DAY)
    results = {
        "specification": {"min_tvl_usd": MIN_TVL, "min_weeks": MIN_INTERVALS, "grace_weeks": GRACE // WEEK},
        "vaults_found": len(study["vaults"]),
        "headline": headline(chosen),
        "daily": headline(by_day),
        "cuts_proven": sum(fees[row["vault"]]["cut_proven"] for row, _ in chosen),
        "comparisons": comparisons(chosen),
        "token_mix": token_mix(chosen),
        "token_mix_daily": token_mix(by_day),
        "earlier_study": earlier_study(study, pools, states),
        "vaults": sorted((row for row, _ in chosen), key=lambda r: -r["median_tvl"]),
        "vaults_daily": [row for row, _ in by_day],
        "sensitivity": sensitivity(study, pools, states),
    }
    (ROOT / "results.json").write_text(json.dumps(results, indent=1) + "\n")
    report = render(results, times, fees)
    (ROOT / "RESULTS.md").write_text(report)
    print(report)
    print("earlier study:", results["earlier_study"])


if __name__ == "__main__":
    main()
