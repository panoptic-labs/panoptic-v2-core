"""Send the upgrade through the real Safes on an anvil fork.

  anvil --fork-url $RPC --fork-block-number <live.json block> --auto-impersonate --port 8546
  python3 script/upgrade-rehearsal/replay_on_anvil.py safe-txns-upgrade-rehearsal/raw-txs.json http://127.0.0.1:8546

raw-txs.json is grouped by sender. Each group becomes one Safe transaction: a MultiSendCallOnly delegatecall
approved on-chain by the first `threshold` owners (approveHash, impersonated) and executed with execTransaction,
exactly what the Transaction Builder submits. Prints the gas each Safe transaction used.
"""
import json, subprocess, sys
raw, rpc = sys.argv[1], sys.argv[2]
MULTISEND = {"1.3.0": "0x40A2aCCbd92BCA938b02010E17A5b8929b49130D"}
MULTISEND_DEFAULT = "0x9641d764fc13c8B624c04430C7356C1C7C8102e2"
ZERO = "0x0000000000000000000000000000000000000000"
IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"

def cast(*a):
    r = subprocess.run(["cast", *a, "--rpc-url", rpc], capture_output=True, text=True)
    if r.returncode: sys.exit(f"cast {' '.join(a)[:200]}\n{r.stderr}")
    return r.stdout.strip()
def send(frm, to, sig, *args):
    return json.loads(cast("send", to, sig, *args, "--from", frm, "--unlocked", "--json", "--gas-limit", "16000000"))

txs = json.load(open(raw))["txs"]
groups = []
for t in txs:
    if not groups or groups[-1][0] != t["from"]: groups.append((t["from"], []))
    groups[-1][1].append(t)

for safe, calls in groups:
    version = cast("call", safe, "VERSION()(string)").strip('"')
    multisend = MULTISEND.get(version, MULTISEND_DEFAULT)
    packed = ""
    for c in calls:
        data = c["data"][2:]
        packed += "00" + c["to"][2:].lower() + "0" * 64 + hex(len(data) // 2)[2:].rjust(64, "0") + data
    payload = subprocess.run(["cast", "calldata", "multiSend(bytes)", "0x" + packed], capture_output=True, text=True, check=True).stdout.strip()
    nonce = cast("call", safe, "nonce()(uint256)").split()[0]
    threshold = int(cast("call", safe, "getThreshold()(uint256)").split()[0])
    owners = sorted(cast("call", safe, "getOwners()(address[])").strip("[]").split(", "), key=lambda a: int(a, 16))[:threshold]
    args = [multisend, "0", payload, "1", "0", "0", "0", ZERO, ZERO]
    h = cast("call", safe, "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)", *args, nonce)
    sigs = "0x"
    for o in owners:
        cast("rpc", "anvil_setBalance", o, "0x56BC75E2D63100000")
        send(o, safe, "approveHash(bytes32)", h)
        sigs += o[2:].lower().rjust(64, "0") + "0" * 64 + "01"
    rc = send(owners[0], safe, "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)", *args, sigs)
    ok = any(l["topics"][0] == "0x442e715f626346e8c54381002da614f62bee8d27386535b2521ec8540898556e" for l in rc["logs"])
    print(f"Safe {safe} (v{version}, nonce {nonce}): {', '.join(c['method'] for c in calls)}")
    print(f"  tx {rc['transactionHash']} status {rc['status']} gas {int(rc['gasUsed'], 16):,} ExecutionSuccess {ok}")
    if not ok: sys.exit("  Safe transaction did not execute")

proxy = next(t for t in txs if t["method"] == "upgradeAndCall")
print("implementation slot:", cast("storage", "0x000000000000ffE5eFdB5AE76b9200263C58b4c0", IMPL_SLOT))
