"""Reads how the vaults in the main sample charge, from their own contracts at historical blocks.

Only fee balances that are non-zero on-chain count as proof that an operator took a cut. A vault without such
a getter is recorded as "not proven", not as "no fee".
"""
import json
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import analyze
import rpc

RATES = ["protocolFee()", "managerFeeBPS()", "gelatoFeeBPS()", "arrakisFeeBPS()"]
ACCRUED = ["accruedProtocolFees0()", "accruedProtocolFees1()", "managerBalance0()", "managerBalance1()",
           "gelatoBalance0()", "gelatoBalance1()"]


def text(value):
    if not value:
        return None
    data = bytes.fromhex(value[2:])
    offset = int.from_bytes(data[:32], "big")
    size = int.from_bytes(data[offset : offset + 32], "big")
    return data[offset + 32 : offset + 32 + size].decode(errors="replace")


def main():
    study, pools, states, _ = analyze.load()
    getters = ["name()"] + RATES + ACCRUED
    selectors = {g: subprocess.check_output(["cast", "sig", g], text=True).strip() for g in getters}
    out = {}
    for summary, rows in analyze.study_sample(study, pools, states):
        block = rows[len(rows) // 2]["start"]
        calls = [rpc.eth_call(summary["vault"], selectors[g], block) for g in getters]
        first, second = (rpc.batch(url, calls) for url in rpc.STATE)
        assert first == second, "providers disagree"
        got = dict(zip(getters, first))
        accrued = {g[:-2]: str(int(got[g], 16)) for g in ACCRUED if got[g] and int(got[g], 16)}
        out[summary["vault"]] = {
            "name": text(got["name()"]), "block": block,
            "rates": {g[:-2]: int(got[g], 16) for g in RATES if got[g] and int(got[g], 16)},
            "accrued": accrued, "cut_proven": bool(accrued),
        }
    (analyze.ROOT / "data" / "fees.json").write_text(json.dumps(out, indent=1) + "\n")
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
