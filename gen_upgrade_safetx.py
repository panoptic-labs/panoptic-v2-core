"""Generate Safe Transaction Builder JSON for upgrading RiskEngine proxies.

Reads a build config with an `upgrades` list and the deployment-info produced by
`build_release.py` for that config, then writes Safe batches that:

  1. deploy the new implementation through the CREATE3 deployer (mint + deploy), and
  2. call `ProxyAdmin.upgradeAndCall(proxy, newImplementation, "")` for each proxy.

Without `--timelock` both steps land in a single atomic Safe transaction (`upgrade.json`).

With `--timelock ADDR --delay SECONDS` the ProxyAdmin owner is assumed to be an
OpenZeppelin TimelockController. Three files are written:

  - deploy.json    Safe deploys the implementation (can be executed any time before execute.json)
  - schedule.json  Safe calls TimelockController.scheduleBatch(...) with the upgrade calls
  - execute.json   Safe calls TimelockController.executeBatch(...) after the delay

Because CREATE3 addresses depend only on the salt, schedule.json can be submitted before the
implementation bytecode exists on-chain; deploy.json then only needs to run before execute.json.
That is the "blind" path for security fixes.

The ProxyAdmin address is derived offline: RiskEngineProxy creates it in its constructor, so it
is CREATE(proxy, nonce=1). Pass `--rpc-url` to cross-check against the live ERC-1967 admin slot.

Usage:
  python3 gen_upgrade_safetx.py generate build-config-RiskEngine-upgrade.json deployment-info-RiskEngine-upgrade.json safe-txns-upgrade
  python3 gen_upgrade_safetx.py generate ... --timelock 0xTimelock --delay 172800
  python3 gen_upgrade_safetx.py check build-config-RiskEngine-upgrade.json --rpc-url $RPC
"""

import argparse
import json
import os
import subprocess
import sys

DEPLOYER = "0x000000000000b361194cfe6312EE3210d53C15AA"
IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"

MINT_METHOD = {
    "inputs": [
        {"internalType": "address", "name": "to", "type": "address"},
        {"internalType": "uint256", "name": "id", "type": "uint256"},
        {"internalType": "uint8", "name": "nonce", "type": "uint8"},
    ],
    "name": "mint",
    "payable": False,
}

DEPLOY_METHOD = {
    "inputs": [
        {"internalType": "uint256", "name": "id", "type": "uint256"},
        {"internalType": "bytes", "name": "initcode", "type": "bytes"},
    ],
    "name": "deploy",
    "payable": True,
}

UPGRADE_METHOD = {
    "inputs": [
        {"internalType": "address", "name": "proxy", "type": "address"},
        {"internalType": "address", "name": "implementation", "type": "address"},
        {"internalType": "bytes", "name": "data", "type": "bytes"},
    ],
    "name": "upgradeAndCall",
    "payable": True,
}

SCHEDULE_BATCH_METHOD = {
    "inputs": [
        {"internalType": "address[]", "name": "targets", "type": "address[]"},
        {"internalType": "uint256[]", "name": "values", "type": "uint256[]"},
        {"internalType": "bytes[]", "name": "payloads", "type": "bytes[]"},
        {"internalType": "bytes32", "name": "predecessor", "type": "bytes32"},
        {"internalType": "bytes32", "name": "salt", "type": "bytes32"},
        {"internalType": "uint256", "name": "delay", "type": "uint256"},
    ],
    "name": "scheduleBatch",
    "payable": False,
}

EXECUTE_BATCH_METHOD = {
    "inputs": [
        {"internalType": "address[]", "name": "targets", "type": "address[]"},
        {"internalType": "uint256[]", "name": "values", "type": "uint256[]"},
        {"internalType": "bytes[]", "name": "payloads", "type": "bytes[]"},
        {"internalType": "bytes32", "name": "predecessor", "type": "bytes32"},
        {"internalType": "bytes32", "name": "salt", "type": "bytes32"},
    ],
    "name": "executeBatch",
    "payable": True,
}

ZERO32 = "0x" + "00" * 32


def _cast(*args):
    return subprocess.run(["cast", *args], check=True, capture_output=True, text=True).stdout.strip()


def _checksum(addr):
    return _cast("to-check-sum-address", addr)


def proxy_admin_of(proxy):
    """RiskEngineProxy deploys its ProxyAdmin in the constructor => CREATE(proxy, nonce 1)."""
    out = _cast("compute-address", proxy, "--nonce", "1")
    return out.split()[-1]


def upgrade_calldata(proxy, implementation):
    return _cast("calldata", "upgradeAndCall(address,address,bytes)", proxy, implementation, "0x")


def _tx(to, method, values):
    return {"to": to, "value": "0", "data": None, "contractMethod": method, "contractInputsValues": values}


def _deploy_txs(contract):
    salt_int = str(int(contract["salt"], 16))
    recipient = contract["salt"][:42]
    return [
        _tx(DEPLOYER, MINT_METHOD, {"to": recipient, "id": salt_int, "nonce": str(contract["nonce"])}),
        _tx(DEPLOYER, DEPLOY_METHOD, {"id": salt_int, "initcode": contract["initcode"]}),
    ]


def _write(path, chain_id, name, transactions, notes):
    payload = {"chainId": str(chain_id), "meta": {"name": name, "notes": notes}, "transactions": transactions}
    with open(path, "w") as f:
        json.dump(payload, f, indent=2)
    print(f"\033[92m{path}\033[0m: {name} ({len(transactions)} transactions)")
    for n in notes:
        print(f"  - {n}")


def _resolve_upgrades(config, deployment_info):
    by_name = {c["contractName"]: c for c in deployment_info["logicContracts"]} if deployment_info else {}
    resolved = []
    for up in config.get("upgrades", []):
        name = up["implementation"]
        if deployment_info is not None and name not in by_name:
            sys.exit(f"ERROR: upgrades[].implementation '{name}' not found in deployment-info")
        impl_addr = by_name[name]["address"] if deployment_info else config["logicContracts"][name]["deployment"]["address"]
        proxy = _checksum(up["proxy"])
        resolved.append(
            {
                "name": name,
                "proxy": proxy,
                "proxy_admin": proxy_admin_of(proxy),
                "implementation": _checksum(impl_addr),
                "contract": by_name.get(name),
            }
        )
    if not resolved:
        sys.exit("ERROR: config has no `upgrades` entries")
    return resolved


def _onchain_checks(upgrades, rpc_url):
    ok = True
    for up in upgrades:
        admin_slot = _cast("storage", up["proxy"], ADMIN_SLOT, "--rpc-url", rpc_url)
        impl_slot = _cast("storage", up["proxy"], IMPL_SLOT, "--rpc-url", rpc_url)
        live_admin = _checksum("0x" + admin_slot[-40:])
        live_impl = _checksum("0x" + impl_slot[-40:])
        owner = _checksum("0x" + _cast("call", live_admin, "owner()(address)", "--rpc-url", rpc_url)[-40:])
        new_code = _cast("code", up["implementation"], "--rpc-url", rpc_url)
        has_code = new_code not in ("0x", "")

        print(f"\n\033[96m{up['name']}\033[0m  proxy {up['proxy']}")
        print(f"  ProxyAdmin (derived) : {up['proxy_admin']}")
        print(f"  ProxyAdmin (on-chain): {live_admin}  {'OK' if live_admin == up['proxy_admin'] else 'MISMATCH'}")
        print(f"  ProxyAdmin owner     : {owner}")
        print(f"  current impl         : {live_impl}")
        print(f"  new impl             : {up['implementation']}  {'(code present)' if has_code else '(no code yet)'}")

        if live_admin != up["proxy_admin"]:
            ok = False
        if live_impl == up["implementation"]:
            print("  \033[93mWARNING: proxy already points at the new implementation\033[0m")
    return ok


def cmd_generate(args):
    config = json.load(open(args.config))
    deployment_info = json.load(open(args.deployment_info))
    upgrades = _resolve_upgrades(config, deployment_info)
    os.makedirs(args.output_dir, exist_ok=True)

    if args.rpc_url and not _onchain_checks(upgrades, args.rpc_url):
        sys.exit("\nERROR: on-chain ProxyAdmin mismatch, refusing to generate")

    deploy_txs, deploy_notes = [], []
    seen = set()
    for up in upgrades:
        if up["implementation"] in seen:
            continue
        seen.add(up["implementation"])
        deploy_txs.extend(_deploy_txs(up["contract"]))
        deploy_notes.append(f"deploy {up['name']} -> {up['implementation']}")

    upgrade_notes = [
        f"{up['name']}: ProxyAdmin {up['proxy_admin']}.upgradeAndCall({up['proxy']}, {up['implementation']}, 0x)"
        for up in upgrades
    ]

    if not args.timelock:
        txs = deploy_txs + [
            _tx(up["proxy_admin"], UPGRADE_METHOD,
                {"proxy": up["proxy"], "implementation": up["implementation"], "data": "0x"})
            for up in upgrades
        ]
        _write(f"{args.output_dir}/upgrade.json", args.chain_id, "RiskEngine upgrade (deploy + upgrade, atomic)",
               txs, deploy_notes + upgrade_notes)
        return

    timelock = _checksum(args.timelock)
    targets = json.dumps([up["proxy_admin"] for up in upgrades], separators=(",", ":"))
    values = json.dumps(["0"] * len(upgrades), separators=(",", ":"))
    payloads = json.dumps([upgrade_calldata(up["proxy"], up["implementation"]) for up in upgrades], separators=(",", ":"))
    salt = args.salt

    _write(f"{args.output_dir}/deploy.json", args.chain_id, "RiskEngine upgrade step 1: deploy implementation",
           deploy_txs, deploy_notes + ["run any time before execute.json"])
    _write(f"{args.output_dir}/schedule.json", args.chain_id, "RiskEngine upgrade step 2: schedule in timelock",
           [_tx(timelock, SCHEDULE_BATCH_METHOD,
                {"targets": targets, "values": values, "payloads": payloads,
                 "predecessor": ZERO32, "salt": salt, "delay": str(args.delay)})],
           upgrade_notes + [f"timelock {timelock}, delay {args.delay}s, salt {salt}"])
    _write(f"{args.output_dir}/execute.json", args.chain_id, "RiskEngine upgrade step 3: execute after delay",
           [_tx(timelock, EXECUTE_BATCH_METHOD,
                {"targets": targets, "values": values, "payloads": payloads,
                 "predecessor": ZERO32, "salt": salt})],
           upgrade_notes + ["only valid once the timelock delay has elapsed and deploy.json has run"])


def cmd_check(args):
    config = json.load(open(args.config))
    deployment_info = json.load(open(args.deployment_info)) if args.deployment_info else None
    upgrades = _resolve_upgrades(config, deployment_info)
    ok = _onchain_checks(upgrades, args.rpc_url)
    sys.exit(0 if ok else 1)


parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
sub = parser.add_subparsers(dest="cmd", required=True)

g = sub.add_parser("generate", help="write Safe batch JSON for the upgrade")
g.add_argument("config")
g.add_argument("deployment_info")
g.add_argument("output_dir")
g.add_argument("--chain-id", type=int, default=1)
g.add_argument("--rpc-url", help="cross-check ProxyAdmin and current implementation on-chain before generating")
g.add_argument("--timelock", help="TimelockController that owns the ProxyAdmin; emits deploy/schedule/execute files")
g.add_argument("--delay", type=int, default=0, help="timelock delay in seconds (must be >= timelock minDelay)")
g.add_argument("--salt", default=ZERO32, help="timelock operation salt (bytes32); change to re-schedule identical calls")
g.set_defaults(func=cmd_generate)

c = sub.add_parser("check", help="print live proxy/ProxyAdmin/implementation state")
c.add_argument("config")
c.add_argument("--deployment-info", default=None)
c.add_argument("--rpc-url", required=True)
c.set_defaults(func=cmd_check)

args = parser.parse_args()
if args.cmd == "generate" and args.timelock and args.delay <= 0:
    sys.exit("ERROR: --delay must be > 0 when --timelock is set")
args.func(args)
