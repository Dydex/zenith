"""Attacks candidate scoring rules with strategies that use only past information.

Per unit of in-range liquidity, every position in a pool earns the same result over an interval (fees minus
losses to rebalancing), so a curator's only lever is how much liquidity it keeps in range, and when. Here a
sleeve is its daily in-range liquidity L_t, in units of the control's liquidity, and phi_t is the control's
daily skill per unit of liquidity, from the mainnet data.

A rule is gameable if a strategy with no information about the future earns a positive average score.
"""
import json
import math
import pathlib
import random
import statistics
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import analyze

PERIOD = 7  # settlement period, days
SEED = 11


def daily_phi(study, pools):
    series = {}
    for vault in study["vaults"]:
        name = vault["pool_name"]
        if name in series:
            continue
        blocks = sorted(b for (p, b) in pools if p == vault["pool"] and b % analyze.DAY == 0)
        days = [b for b in blocks if b - analyze.DAY in set(blocks)]
        out = []
        for stop in days:
            start = stop - analyze.DAY
            r0, f00, f10 = pools[vault["pool"], start]
            r1, f01, f11 = pools[vault["pool"], stop]
            value = (lambda x, y, p: x + y / p) if vault["numeraire"] == 0 else (lambda x, y, p: x * p + y)
            p1 = r1 * r1
            after = value(1 / r1 + ((f01 - f00) % 2**256) / 2**128, r1 + ((f11 - f10) % 2**256) / 2**128, p1)
            out.append((after - value(1 / r0, r0, p1)) / value(1 / r0, r0, r0 * r0))
        series[name] = out
    return series


# ---------------------------------------------------------------- strategies: L_t from history only


def strategies(rng):
    def static(k):
        return lambda past, day, mean: k

    def double_down(past, day, mean):
        return 2.0 if past and past[-1] < mean else 0.5

    def momentum(past, day, mean):
        recent = past[-7:]
        return 2.0 if recent and statistics.fmean(recent) > mean else 0.5

    def calm_seeker(past, day, mean):  # forecasts losses from recent volatility: a real, legitimate skill
        recent = past[-14:]
        if len(recent) < 14:
            return 1.0
        return 2.0 if statistics.pstdev(recent) < statistics.pstdev(past[-120:]) else 0.5

    return {
        "static 1x": static(1.0), "static 5x": static(5.0), "static 30x": static(30.0), "idle": static(0.0),
        "double down after a bad day": double_down, "momentum": momentum,
        "random size": lambda past, day, mean: rng.uniform(0, 2),
        "ramp up within period": lambda past, day, mean: 0.5 + 1.5 * day / (PERIOD - 1),
        "ramp down within period": lambda past, day, mean: 2.0 - 1.5 * day / (PERIOD - 1),
        "volatility timing (plausible skill)": calm_seeker,
    }


FORESIGHT = {"perfect foresight": 1.0, "60% foresight": 0.6}


# ---------------------------------------------------------------- rules


def rules():
    """Each rule scores one period: L, phi (this period), previous-period mean L, long-run mean phi before it."""
    return {
        "per capital (d x control)": lambda L, phi, prev, hist: sum(l * p for l, p in zip(L, phi)) - sum(phi),
        "baseline = liquidity at period start": lambda L, phi, prev, hist: sum((l - L[0]) * p for l, p in zip(L, phi)),
        "baseline = period average (ex post)": lambda L, phi, prev, hist: sum(
            (l - statistics.fmean(L)) * p for l, p in zip(L, phi)
        ),
        "baseline = previous period average": lambda L, phi, prev, hist: sum((l - prev) * p for l, p in zip(L, phi)),
        "previous average, demeaned by long-run phi": lambda L, phi, prev, hist: sum(
            (l - prev) * (p - hist) for l, p in zip(L, phi)
        ),
        "liquidity at period start, demeaned by long-run phi": lambda L, phi, prev, hist: sum(
            (l - L[0]) * (p - hist) for l, p in zip(L, phi)
        ),
    }


def simulate(series):
    rng = random.Random(SEED)
    plans = strategies(rng)
    out = {}
    for rule_name, rule in rules().items():
        for plan_name in list(plans) + list(FORESIGHT):
            scores, scale = [], []
            for phis in series.values():
                past, prev = [], None
                for start in range(120, len(phis) - PERIOD + 1, PERIOD):
                    phi = phis[start : start + PERIOD]
                    history = phis[:start]
                    hist = statistics.fmean(history)
                    if plan_name in FORESIGHT:
                        accuracy = FORESIGHT[plan_name]
                        L = [(2.0 if (p > hist) == (rng.random() < accuracy) else 0.0) for p in phi]
                    else:
                        L, seen = [], list(history)
                        for day in range(PERIOD):
                            L.append(plans[plan_name](seen, day, hist))
                            seen.append(phi[day])
                    prev = statistics.fmean(L) if prev is None else prev
                    scores.append(rule(L, phi, prev, hist))
                    scale.append(statistics.pstdev(phi) * math.sqrt(PERIOD))
                    prev = statistics.fmean(L)
            unit = statistics.fmean(scale)
            mean = statistics.fmean(scores)
            t = mean / (statistics.pstdev(scores) / math.sqrt(len(scores))) if statistics.pstdev(scores) else 0.0
            out[rule_name, plan_name] = (mean / unit, t, len(scores))
    return out


def main():
    study, pools, _, _ = analyze.load()
    series = daily_phi(study, pools)
    result = simulate(series)
    plans = list(strategies(random.Random(SEED))) + list(FORESIGHT)
    lines = [
        "# Scoring-rule attack",
        "",
        "Generated by `scripts/scoring.py`. Mean score per weekly period, in units of one period's typical",
        "control move, with its t-statistic. A no-skill strategy should score near zero; |t| above 3 means the rule",
        f"pays or punishes it systematically. Data: {sum(len(s) for s in series.values()):,} pool-days on "
        f"{len(series)} pools.",
        "",
        "| Strategy | " + " | ".join(rules()) + " |",
        "|---|" + "--:|" * len(rules()),
    ]
    for plan in plans:
        cells = []
        for rule_name in rules():
            mean, t, n = result[rule_name, plan]
            flag = " **gameable**" if abs(t) > 3 and plan not in FORESIGHT and plan != "volatility timing (plausible skill)" else ""
            cells.append(f"{mean:+.3f} (t {t:+.1f}){flag}")
        lines.append(f"| {plan} | " + " | ".join(cells) + " |")
    report = "\n".join(lines) + "\n"
    (analyze.ROOT / "SCORING.md").write_text(report)
    (analyze.ROOT / "scoring.json").write_text(
        json.dumps({f"{r} | {p}": v for (r, p), v in result.items()}, indent=1) + "\n"
    )
    print(report)


if __name__ == "__main__":
    main()
