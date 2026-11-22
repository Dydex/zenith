"""Fetches daily historical state for every discovered vault and its pool.

Every value is read from two independent providers and must be identical. Results are stored as gzipped CSV,
so analyze.py runs offline. Completed batches are cached, so an interrupted run resumes.
"""
import csv
import gzip
import hashlib
import io
import json
import pathlib
import sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import rpc

ROOT = pathlib.Path(__file__).resolve().parent.parent
CACHE = ROOT / "cache"
DAY = 7_200
VAULT = {"getTotalAmounts": "0xc4a7761e", "getUnderlyingBalances": "0x1322d954"}
POOL = ("0x3850c7bd", "0xf3058399", "0x46141319")  # slot0, feeGrowthGlobal0X128, feeGrowthGlobal1X128

# The first study sampled weekly from each vault's own start block. Those grids are kept so it can be reproduced.
FIRST_STUDY = {
    "0xa6c49fd13e50a30c65e6c8480aada132011d0613": (13105600, 142),
    "0x9bf7b46c7ad5ab62034e9349ab912c0345164322": (12803200, 148),
    "0x5763bf13a2ce7a76784b36aadf2f9098325d4038": (13811200, 128),
    "0x381e7287eb6df7c74b52661f91b1b02269144198": (17742400, 50),
    "0xa9782a2c9c3fb83937f14cdfac9a6d23946c9255": (14476970, 93),
    "0x9ad8d0df2da118dce898b7f5bd9ab749c593a5d9": (17285194, 46),
}


def agreed(chunk):
    path = CACHE / (hashlib.sha256(json.dumps(chunk).encode()).hexdigest() + ".json")
    if path.exists():
        return json.loads(path.read_text())
    first, second = (rpc.batch(url, chunk) for url in rpc.STATE)
    if first != second:
        raise RuntimeError(f"providers disagree in batch {path.name}")
    path.write_text(json.dumps(first))
    return first


def write(name, header, rows):
    text = io.StringIO()
    writer = csv.writer(text, lineterminator="\n")
    writer.writerow(header)
    writer.writerows(rows)
    with open(ROOT / "data" / name, "wb") as raw, gzip.GzipFile("", "wb", fileobj=raw, mtime=0) as packed:
        packed.write(text.getvalue().encode())
    print(name, len(rows), "rows", flush=True)


def main():
    CACHE.mkdir(exist_ok=True)
    study = json.loads((ROOT / "data" / "discovery.json").read_text())
    end = study["to_block"]

    pool_points, vault_points = set(), []
    for vault in study["vaults"]:
        blocks = set(range((vault["first_mint"] // DAY + 1) * DAY, end + 1, DAY))
        if vault["vault"] in FIRST_STUDY:
            start, weeks = FIRST_STUDY[vault["vault"]]
            blocks |= {start + i * 7 * DAY for i in range(weeks + 1)}
        for block in sorted(blocks):
            vault_points.append((vault["vault"], vault["balance_function"], block))
            pool_points.add((vault["pool"], block))
    pool_points = sorted(pool_points)

    calls = [rpc.eth_call(pool, sel, block) for pool, block in pool_points for sel in POOL]
    pool_calls = len(calls)
    for vault, function, block in vault_points:
        calls += [rpc.eth_call(vault, VAULT[function], block), rpc.eth_call(vault, "0x18160ddd", block)]
    calls += [("eth_getBlockByNumber", [hex(b), False]) for b in range((study["from_block"] // DAY + 1) * DAY, end + 1, 30 * DAY)]
    header_count = sum(1 for c in calls if c[0] == "eth_getBlockByNumber")

    state, headers = calls[:-header_count], calls[-header_count:]
    chunks = [state[i : i + 100] for i in range(0, len(state), 100)]
    print(f"{len(state)} calls per provider, {len(chunks)} batches", flush=True)
    replies = []
    with ThreadPoolExecutor(4) as workers:
        for done, reply in enumerate(workers.map(agreed, chunks), 1):
            replies += reply
            if done % 100 == 0:
                print(f"{done}/{len(chunks)}", flush=True)

    rows = []
    for i, (pool, block) in enumerate(pool_points):
        slot0, fee0, fee1 = replies[3 * i : 3 * i + 3]
        rows.append((pool, block, rpc.word(slot0, 0), int(fee0, 16), int(fee1, 16)))
    write("pools.csv.gz", ("pool", "block", "sqrt_price_x96", "fee_growth0_x128", "fee_growth1_x128"), rows)

    rows = []
    for i, (vault, _, block) in enumerate(vault_points):
        amounts, supply = replies[pool_calls + 2 * i : pool_calls + 2 * i + 2]
        if amounts and supply and int(supply, 16) > 0:
            rows.append((vault, block, rpc.word(amounts, 0), rpc.word(amounts, 1), int(supply, 16)))
        else:
            rows.append((vault, block, "", "", ""))
    write("vaults.csv.gz", ("vault", "block", "amount0", "amount1", "total_supply"), rows)

    dates = rpc.batch(rpc.STATE[0], headers)
    write("blocks.csv.gz", ("block", "timestamp"), [(int(d["number"], 16), int(d["timestamp"], 16)) for d in dates])


if __name__ == "__main__":
    main()
