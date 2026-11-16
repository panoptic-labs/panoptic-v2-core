"""Enumerate every pool bound to the RiskEngine proxy and every account with open positions in them."""
import json, subprocess, sys
RPC, OUT = sys.argv[1], sys.argv[2]
PROXY = "0x000000000000ffE5eFdB5AE76b9200263C58b4c0"
START = 26000000
def cast(*a):
    return subprocess.run(["cast", *a, "--rpc-url", RPC], check=True, capture_output=True, text=True).stdout.strip()
def cksum(a):
    return subprocess.run(["cast", "to-check-sum-address", a], check=True, capture_output=True, text=True).stdout.strip()
def sig(s):
    return subprocess.run(["cast", "keccak", s], check=True, capture_output=True, text=True).stdout.strip()
assert cast("code", PROXY, "--block", str(START)) == "0x", "proxy predates START"
head = int(cast("block-number"))
def logs(topic0, address=None):
    out, lo = [], START
    while lo <= head:
        hi = min(lo + 49999, head)
        a = ["logs", "--from-block", str(lo), "--to-block", str(hi), "--json"]
        if address: a += ["--address", address]
        out += json.loads(cast(*a, topic0))
        lo = hi + 1
    return out
pools = {}
for s in ["PoolDeployed(address,address,address,address,address)", "PoolDeployed(address,bytes32,address,address,address)"]:
    for l in logs(sig(s)):
        engine = "0x" + l["data"][2 + 64 * 2 + 24: 2 + 64 * 3]
        pool = "0x" + l["topics"][1][26:]
        pools[pool] = {"factory": l["address"], "engine": engine, "block": int(l["blockNumber"], 16)}
print("pools deployed since", START, ":", len(pools))
bound = {}
for p, d in pools.items():
    live = "0x" + cast("call", p, "riskEngine()(address)")[-40:]
    print(" ", p, "factory", d["factory"], "engine", live)
    if live.lower() == PROXY.lower(): bound[p] = d
MINT = sig("OptionMinted(address,uint256,uint256)")
BURN = sig("OptionBurnt(address,uint128,uint256,int256[4])")
res = {"block": head, "pools": []}
for p in bound:
    book = {}
    ev = [(int(l["blockNumber"], 16), int(l["logIndex"], 16), t, l) for t in (MINT, BURN) for l in logs(t, p)]
    for _, _, t, l in sorted(ev, key=lambda e: e[:2]):
        who, tid = "0x" + l["topics"][1][26:], int(l["topics"][2], 16)
        s = book.setdefault(who, [])
        if t == MINT: s.append(tid)
        else: s.remove(tid)
    accounts = []
    for who, ids in book.items():
        legs = int(cast("call", p, "numberOfLegs(address)(uint256)", who, "--block", str(head)).split()[0])
        print("   ", who, "positions", len(ids), "legs", legs)
        assert (legs > 0) == (len(ids) > 0), "log replay disagrees with numberOfLegs"
        if ids: accounts.append({"who": cksum(who), "ids": [str(i) for i in ids]})
    print("  pool", p, ":", len(ev), "mint/burn events,", len(book), "accounts ever,", len(accounts), "with open positions")
    res["pools"].append({"pool": cksum(p), "accounts": accounts})
json.dump(res, open(OUT, "w"), indent=2)
print("wrote", OUT, "at block", head)
