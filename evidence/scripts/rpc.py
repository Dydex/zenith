"""Small JSON-RPC client for public Ethereum archive endpoints. No API key needed."""
import json
import time
import urllib.error
import urllib.request

# Both serve historical state and accept batches of 100. Only LOGS serves 10,000-block eth_getLogs ranges.
STATE = ["https://rpc.mevblocker.io", "https://eth-mainnet.public.blastapi.io"]
LOGS = "https://rpc.mevblocker.io"


def batch(url, calls, tries=12):
    """Runs (method, params) calls. An EVM revert becomes None; any other error is retried, never recorded."""
    results = {}
    last_error = None
    for attempt in range(tries):
        pending = [i for i in range(len(calls)) if i not in results]
        body = [{"jsonrpc": "2.0", "id": i, "method": calls[i][0], "params": calls[i][1]} for i in pending]
        request = urllib.request.Request(
            url, json.dumps(body).encode(), {"Content-Type": "application/json", "User-Agent": "research-client"}
        )
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                reply = json.load(response)
            if not isinstance(reply, list):
                raise ValueError(str(reply)[:160])
            for item in reply:
                if item.get("id") not in pending:
                    continue
                if item.get("result") is not None:
                    results[item["id"]] = None if item["result"] == "0x" and calls[item["id"]][0] == "eth_call" else item["result"]
                elif "error" in item:
                    message = str(item["error"]).lower()
                    if "revert" in message or "invalid opcode" in message:
                        results[item["id"]] = None
                    else:
                        last_error = message[:160]
        except (urllib.error.URLError, ValueError, OSError) as error:
            last_error = str(error)
        if len(results) == len(calls):
            return [results[i] for i in range(len(calls))]
        time.sleep(min(1.5 * 2**attempt, 20))
    raise RuntimeError(f"{url}: {last_error}")


def eth_call(to, data, block):
    return ("eth_call", [{"to": to, "data": data}, hex(block)])


def word(value, index):
    return int(value[2 + 64 * index : 2 + 64 * (index + 1)], 16)
