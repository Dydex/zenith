"""Finds managed vaults: every direct Mint owner on three pools that answers a vault balance function.

No minimum mint count and no size filter. Those are analysis choices, made visibly in analyze.py.
"""
import collections
import json
import pathlib
import sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import rpc

ROOT = pathlib.Path(__file__).resolve().parent.parent
START, END = 12_369_621, 20_300_000  # Uniswap v3 factory deployment to early July 2024
SPAN = 10_000
MINT = "0x7a53080ba414158be7ec69b987b5fb7d07dee101fe85488f0853ae16239d0bde"
NFT_MANAGER = "0xc36442b4a4522e871399cd717abdd847ab11fe88"
POOLS = {
    "USDC/WETH 0.05%": "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640",
    "USDC/WETH 0.3%": "0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8",
    "WETH/USDT 0.05%": "0x11b815efB8f581194ae79006d24E0d814B7697F6",
}
SELECTORS = {"getTotalAmounts": "0xc4a7761e", "getUnderlyingBalances": "0x1322d954"}


def mint_owners(pool):
    starts = list(range(START, END, SPAN))

    def fetch(chunk):
        calls = [
            ("eth_getLogs", [{"address": pool, "topics": [MINT],
                              "fromBlock": hex(b), "toBlock": hex(min(b + SPAN - 1, END))}])
            for b in chunk
        ]
        replies = rpc.batch(rpc.LOGS, calls)
        assert all(r is not None for r in replies), "log query failed"
        return [("0x" + log["topics"][1][-40:], int(log["blockNumber"], 16)) for r in replies for log in r]

    count, first, last = collections.Counter(), {}, {}
    chunks = [starts[i : i + 5] for i in range(0, len(starts), 5)]
    with ThreadPoolExecutor(3) as workers:
        for done, found in enumerate(workers.map(fetch, chunks), 1):
            for owner, block in found:
                count[owner] += 1
                first[owner] = min(block, first.get(owner, block))
                last[owner] = max(block, last.get(owner, block))
            if done % 20 == 0:
                print(f"  {pool[:8]} {done}/{len(chunks)}", flush=True)
    count.pop(NFT_MANAGER, None)
    return count, first, last


def main():
    pools, vaults = {}, []
    for name, pool in POOLS.items():
        count, first, last = mint_owners(pool)
        owners = sorted(count)
        calls = []
        for owner in owners:
            calls += [rpc.eth_call(owner, s, last[owner]) for s in SELECTORS.values()]
            calls += [rpc.eth_call(owner, s, last[owner]) for s in ("0x18160ddd", "0x0dfe1681", "0xd21220a7", "0x16f0115b")]
        replies = []
        for i in range(0, len(calls), 96):
            replies += rpc.batch(rpc.STATE[0], calls[i : i + 96])
        found = 0
        for i, owner in enumerate(owners):
            total, underlying, supply, token0, token1, vault_pool = replies[6 * i : 6 * i + 6]
            if not supply or not (total or underlying):
                continue
            address = lambda value: "0x" + value[-40:] if value else None
            vaults.append({
                "vault": owner, "pool": pool, "pool_name": name, "numeraire": 1 if "USDT" in name else 0,
                "balance_function": "getTotalAmounts" if total else "getUnderlyingBalances",
                "mints": count[owner], "first_mint": first[owner], "last_mint": last[owner],
                "token0": address(token0), "token1": address(token1), "pool_getter": address(vault_pool),
            })
            found += 1
        pools[name] = {"pool": pool, "direct_mint_owners": len(owners), "vaults_found": found}
        print(name, pools[name], flush=True)
    (ROOT / "data" / "discovery.json").write_text(
        json.dumps({"from_block": START, "to_block": END, "pools": pools, "vaults": vaults}, indent=1) + "\n"
    )


if __name__ == "__main__":
    main()
