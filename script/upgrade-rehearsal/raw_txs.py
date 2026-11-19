"""Flatten the Safe batches of an upgrade (deploy.json, then upgrade.json) into raw calls (from, to, data) for
replay on a fork.

  python3 script/upgrade-rehearsal/raw_txs.py safe-txns-upgrade safe-txns-upgrade-rehearsal/raw-txs.json $RPC

`from` is the account that must send each call on-chain: the Safe embedded in the CREATE3 salt for the
deployer's mint/deploy, the ProxyAdmin owner for upgradeAndCall, and the ProxyAdmin owner for the
permissionless accrueInterest() calls (they ride in its batch).
"""
import json, subprocess, sys
batches, out, rpc = sys.argv[1], sys.argv[2], sys.argv[3]
DEPLOYER = "0x000000000000b361194cfe6312EE3210d53C15AA"
def cast(*a):
    return subprocess.run(["cast", *a], check=True, capture_output=True, text=True).stdout.strip()
txs = [t for f in ("deploy.json", "upgrade.json") for t in json.load(open(f"{batches}/{f}"))["transactions"]]
admin = next(t["to"] for t in txs if t["contractMethod"]["name"] == "upgradeAndCall")
owner = cast("call", admin, "owner()(address)", "--rpc-url", rpc)
raw = []
for t in txs:
    m = t["contractMethod"]
    sig = f"{m['name']}({','.join(i['type'] for i in m['inputs'])})"
    data = cast("calldata", sig, *[t["contractInputsValues"][i["name"]] for i in m["inputs"]])
    if t["to"].lower() == DEPLOYER.lower():
        sender = cast("to-check-sum-address", "0x" + hex(int(t["contractInputsValues"]["id"]))[2:].rjust(64, "0")[:40])
    else:
        sender = owner
    raw.append({"from": sender, "to": t["to"], "data": data, "method": m["name"]})
    print(f"{m['name']:16} from {sender} to {t['to']} ({len(data)//2-1} bytes)")
json.dump({"txs": raw}, open(out, "w"), indent=1)
