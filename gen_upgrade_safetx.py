"""Generate Safe Transaction Builder JSON for upgrading RiskEngine proxies.

Reads a build config with an `upgrades` list and the deployment-info produced by
`build_release.py` for that config, then writes Safe batches that:

  1. deploy the new implementation through the CREATE3 deployer (mint + deploy),
  2. call `accrueInterest()` on both collateral trackers of every pool listed under the proxy
     (`upgrades[].pools`), so the interval since each tracker's last interaction is priced by the
     engine that was live during it rather than by the new one, and
  3. call `ProxyAdmin.upgradeAndCall(proxy, newImplementation, "")` for each proxy.

Without `--timelock` two files are written, one Safe transaction each, because two different Safes
have to send them:

  - deploy.json    step 1, sent by the deploying Safe (the address embedded in the CREATE3 salt; the
                   deployer rejects a mint from anyone else)
  - upgrade.json   steps 2 and 3, atomic, sent by the Safe that owns the ProxyAdmin

With `--timelock ADDR --delay SECONDS` the ProxyAdmin owner is assumed to be an
OpenZeppelin TimelockController. Three files are written:

  - deploy.json    Safe deploys the implementation (can be executed any time before execute.json)
  - schedule.json  Safe calls TimelockController.scheduleBatch(...) with the accrue + upgrade calls
  - execute.json   Safe calls TimelockController.executeBatch(...) after the delay

The accrue calls ride inside the timelock batch so they execute in the same transaction as the
upgrade, immediately before it. `accrueInterest()` is permissionless and idempotent within a
block, so scheduling it ahead of time is harmless.

`upgrades[].pools` needs `--rpc-url`: the trackers are read from each pool, and each pool is
checked to be bound to the proxy it is listed under. It is a list of pools, or a map from chain id
to that chain's pools (`{"1": [...], "4663": [...]}`) when the same implementation goes to several
chains; `--chain-id` selects the entry.

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

ACCRUE_METHOD = {"inputs": [], "name": "accrueInterest", "payable": False}
ACCRUE_CALLDATA = "0xa6afed95"  # accrueInterest()

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


def _resolve_upgrades(config, deployment_info, rpc_url=None, chain_id=1):
    by_name = {c["contractName"]: c for c in deployment_info["logicContracts"]} if deployment_info else {}
    resolved = []
    for up in config.get("upgrades", []):
        name = up["implementation"]
        if deployment_info is not None and name not in by_name:
            sys.exit(f"ERROR: upgrades[].implementation '{name}' not found in deployment-info")
        impl_addr = by_name[name]["address"] if deployment_info else config["logicContracts"][name]["deployment"]["address"]
        proxy = _checksum(up["proxy"])
        # `pools` is either a list (mainnet) or a map from chain id to the pools bound to the proxy on that chain
        pools = up.get("pools", [])
        if isinstance(pools, dict):
            if str(chain_id) not in pools:
                sys.exit(f"ERROR: upgrades[].pools for {proxy} has no entry for chain {chain_id}")
            pools = pools[str(chain_id)]
        pools = [_checksum(p) for p in pools]
        if pools and not rpc_url:
            sys.exit(f"ERROR: upgrades[].pools for {proxy} needs --rpc-url to read the trackers")
        resolved.append(
            {
                "name": name,
                "proxy": proxy,
                "proxy_admin": proxy_admin_of(proxy),
                "implementation": _checksum(impl_addr),
                "contract": by_name.get(name),
                "pools": [_resolve_pool(p, proxy, rpc_url) for p in pools],
            }
        )
    if not resolved:
        sys.exit("ERROR: config has no `upgrades` entries")
    return resolved


def _resolve_pool(pool, proxy, rpc_url):
    """The pool's two trackers, after checking the pool is bound to `proxy`."""
    engine = _checksum("0x" + _cast("call", pool, "riskEngine()(address)", "--rpc-url", rpc_url)[-40:])
    if engine != proxy:
        sys.exit(f"ERROR: pool {pool} is bound to {engine}, not to the proxy {proxy} it is listed under")
    ct0 = _checksum("0x" + _cast("call", pool, "collateralToken0()(address)", "--rpc-url", rpc_url)[-40:])
    ct1 = _checksum("0x" + _cast("call", pool, "collateralToken1()(address)", "--rpc-url", rpc_url)[-40:])
    return {"pool": pool, "trackers": [ct0, ct1]}


def _accrue_targets(upgrades):
    """Every tracker to accrue, in config order, each once."""
    out = []
    for up in upgrades:
        for p in up["pools"]:
            for ct in p["trackers"]:
                if ct not in out:
                    out.append(ct)
    return out


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
        for p in up["pools"]:
            print(f"  pool {p['pool']}: accrue trackers {p['trackers'][0]}, {p['trackers'][1]}")
        if not up["pools"]:
            print("  \033[93mWARNING: no pools listed for this proxy; no tracker will be accrued before the upgrade\033[0m")

        if live_admin != up["proxy_admin"]:
            ok = False
        if live_impl == up["implementation"]:
            print("  \033[93mWARNING: proxy already points at the new implementation\033[0m")
    return ok


def cmd_generate(args):
    config = json.load(open(args.config))
    deployment_info = json.load(open(args.deployment_info))
    if args.rpc_url and int(_cast("chain-id", "--rpc-url", args.rpc_url)) != args.chain_id:
        sys.exit(f"ERROR: --rpc-url is not chain {args.chain_id}")
    upgrades = _resolve_upgrades(config, deployment_info, args.rpc_url, args.chain_id)
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

    # accrue every listed tracker in the same transaction as, and before, the upgrade: the interval since the
    # tracker's last interaction is then compounded at the rate of the engine that was live during it
    accrue_targets = _accrue_targets(upgrades)
    accrue_txs = [_tx(ct, ACCRUE_METHOD, {}) for ct in accrue_targets]
    accrue_notes = [f"accrueInterest() on {ct} before the upgrade" for ct in accrue_targets]

    upgrade_notes = [
        f"{up['name']}: ProxyAdmin {up['proxy_admin']}.upgradeAndCall({up['proxy']}, {up['implementation']}, 0x)"
        for up in upgrades
    ]

    if not args.timelock:
        # two Safes: the CREATE3 slot is minted by the Safe embedded in the salt, the proxy is upgraded by the
        # ProxyAdmin owner
        deployers = sorted({_checksum(up["contract"]["salt"][:42]) for up in upgrades})
        _write(f"{args.output_dir}/deploy.json", args.chain_id,
               "RiskEngine upgrade step 1: deploy implementation",
               deploy_txs,
               deploy_notes + [f"send from the deploying Safe {', '.join(deployers)}", "run before upgrade.json"])
        txs = accrue_txs + [
            _tx(up["proxy_admin"], UPGRADE_METHOD,
                {"proxy": up["proxy"], "implementation": up["implementation"], "data": "0x"})
            for up in upgrades
        ]
        _write(f"{args.output_dir}/upgrade.json", args.chain_id,
               "RiskEngine upgrade step 2: accrue + upgrade (atomic)",
               txs,
               accrue_notes + upgrade_notes
               + ["send from the Safe that owns the ProxyAdmin", "only valid once deploy.json has run"])
        return

    timelock = _checksum(args.timelock)
    targets = json.dumps(accrue_targets + [up["proxy_admin"] for up in upgrades], separators=(",", ":"))
    values = json.dumps(["0"] * (len(accrue_targets) + len(upgrades)), separators=(",", ":"))
    payloads = json.dumps(
        [ACCRUE_CALLDATA] * len(accrue_targets)
        + [upgrade_calldata(up["proxy"], up["implementation"]) for up in upgrades],
        separators=(",", ":"),
    )
    salt = args.salt
    upgrade_notes = accrue_notes + upgrade_notes

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
    upgrades = _resolve_upgrades(config, deployment_info, args.rpc_url, int(_cast("chain-id", "--rpc-url", args.rpc_url)))
    ok = _onchain_checks(upgrades, args.rpc_url)
    sys.exit(0 if ok else 1)


parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
sub = parser.add_subparsers(dest="cmd", required=True)

g = sub.add_parser("generate", help="write Safe batch JSON for the upgrade")
g.add_argument("config")
g.add_argument("deployment_info")
g.add_argument("output_dir")
g.add_argument("--chain-id", type=int, default=1)
g.add_argument("--rpc-url", help="cross-check ProxyAdmin and current implementation on-chain before generating; required when upgrades[].pools is set")
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
