"""Verify a build config's logic contracts through the Etherscan v2 API on any chain Etherscan lists.

Why not `forge verify-contract`: Foundry refuses chain ids it does not know (e.g. Robinhood Chain 4663) even
with a configured URL, and it takes optimizer runs from the cached artifact rather than the flag. This script
asks forge only for the standard-JSON input, sets `optimizer.runs` per contract from the config, submits to
https://api.etherscan.io/v2/api?chainid=<id> and polls the result. Constructor args are resolved exactly as
build_release.py / verify_etherscan.py do.

Usage:
  ETHERSCAN_API_KEY=... python3 script/verify_etherscan_v2.py build-config-RiskEngine.json --chain-id 4663
  ... --contracts RiskEngineProxy RiskEngineStub
"""
import argparse, json, os, subprocess, sys, time, urllib.parse, urllib.request

COMPILER = "v0.8.28+commit.7893614a"
EVM = "cancun"


def _format_abi_arg(type_name, value):
    if type_name.startswith("(") and type_name.endswith(")"):
        inner, depth, parts, cur = type_name[1:-1], 0, [], ""
        for ch in inner:
            depth += ch == "("
            depth -= ch == ")"
            if ch == "," and depth == 0:
                parts.append(cur); cur = ""
            else:
                cur += ch
        parts.append(cur)
        return "(" + ",".join(_format_abi_arg(t, v) for t, v in zip(parts, value)) + ")"
    if type_name.endswith("[]"):
        return "[" + ",".join(_format_abi_arg(type_name[:-2], v) for v in value) + "]"
    return str(value)


def constructor_args(config, options):
    if "constructorArgs" not in options:
        return ""
    values = list(options["constructorArgs"][0]); types = options["constructorArgs"][1]
    for i, a in enumerate(values):
        if isinstance(a, str) and a.startswith("@"):
            values[i] = config["logicContracts"][a[1:]]["deployment"]["address"]
        elif isinstance(a, str) and a.startswith("$"):
            values[i] = config["env"][a[1:]]
    sig = "f(" + ",".join(types) + ")"
    out = subprocess.run(["cast", "abi-encode", sig, *[_format_abi_arg(t, v) for t, v in zip(types, values)]],
                         check=True, capture_output=True, text=True).stdout.strip()
    return out[2:]


def standard_json(path, name, runs):
    out = subprocess.run(["forge", "verify-contract", "0x0000000000000000000000000000000000000001", f"{path}:{name}",
                          "--compiler-version", "0.8.28", "--evm-version", EVM, "--optimizer-runs", str(runs),
                          "--chain-id", "1", "--show-standard-json-input"], check=True, capture_output=True, text=True).stdout
    j = json.loads(out[out.index("{"):])
    j["settings"]["optimizer"] = {"enabled": True, "runs": runs}
    j["settings"]["evmVersion"] = EVM
    return j


def api(chain_id, key, **params):
    url = f"https://api.etherscan.io/v2/api?chainid={chain_id}"
    data = urllib.parse.urlencode({**params, "apikey": key}).encode()
    for _ in range(6):
        r = json.loads(urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=120).read().decode(), strict=False)
        if "rate limit" in str(r.get("result", "")).lower():
            time.sleep(2); continue
        return r
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config"); ap.add_argument("--chain-id", type=int, required=True)
    ap.add_argument("--contracts", nargs="*"); ap.add_argument("--api-key", default=os.environ.get("ETHERSCAN_API_KEY"))
    a = ap.parse_args()
    if not a.api_key:
        sys.exit("set ETHERSCAN_API_KEY or pass --api-key")
    config = json.load(open(a.config))
    failures = 0
    for cname, opt in config["logicContracts"].items():
        if a.contracts and cname not in a.contracts:
            continue
        addr = opt["deployment"]["address"]; artifact = opt.get("artifactName", cname); path = opt["path"].removeprefix("./")
        status = api(a.chain_id, a.api_key, module="contract", action="getsourcecode", address=addr)
        src = status.get("result", [{}])[0] if isinstance(status.get("result"), list) else {}
        if src.get("SourceCode"):
            print(f"{cname} @ {addr} ... already verified as {src.get('ContractName')}"); continue
        sj = standard_json(path, artifact, opt["optimizeRuns"])
        r = api(a.chain_id, a.api_key, module="contract", action="verifysourcecode", codeformat="solidity-standard-json-input",
                sourceCode=json.dumps(sj), contractaddress=addr, contractname=f"{path}:{artifact}",
                compilerversion=COMPILER, constructorArguements=constructor_args(config, opt))
        if r.get("status") != "1":
            print(f"{cname} @ {addr} ... SUBMIT FAILED: {r.get('result')}"); failures += 1; continue
        guid = r["result"]; verdict = "pending"
        for _ in range(20):
            time.sleep(6)
            s = api(a.chain_id, a.api_key, module="contract", action="checkverifystatus", guid=guid)
            verdict = str(s.get("result"))
            if "Pending" not in verdict:
                break
        ok = verdict.startswith("Pass") or "Already Verified" in verdict
        failures += not ok
        print(f"{cname} @ {addr} ... {'OK' if ok else 'FAILED'}: {verdict}")
        time.sleep(1)
    print(f"\n{failures} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
