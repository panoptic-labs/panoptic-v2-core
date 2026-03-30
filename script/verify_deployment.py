#!/usr/bin/env python3
"""Verify that deployment-info addresses match expected CREATE3 derivations."""

import argparse
import json
import subprocess
import sys
from pathlib import Path

DEPLOYER = "0x000000000000b361194cfe6312EE3210d53C15AA"
# keccak256(hex"67363d3d37363d34f03d5260086018f3") — Solady CREATE3 proxy bytecode hash
PROXY_BYTECODE_HASH = "21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f"


def _cast_keccak(hex_data: str) -> str:
    result = subprocess.run(
        ["cast", "keccak", hex_data],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip().removeprefix("0x")


def compute_create3_address(deployer: str, salt: str) -> str:
    """Compute the CREATE3-deployed address from deployer and salt.

    Step 1: proxy = CREATE2(deployer, salt, PROXY_BYTECODE_HASH)
    Step 2: deployed = CREATE(proxy, nonce=1)
    """
    deployer_hex = deployer.lower().removeprefix("0x").zfill(40)
    salt_hex = salt.lower().removeprefix("0x").zfill(64)

    # CREATE2: keccak256(0xff ++ deployer ++ salt ++ bytecode_hash)
    create2_input = "0xff" + deployer_hex + salt_hex + PROXY_BYTECODE_HASH
    proxy_hash = _cast_keccak("0x" + create2_input)
    proxy = proxy_hash[-40:]  # last 20 bytes

    # CREATE (RLP): keccak256(0xd6 ++ 0x94 ++ proxy ++ 0x01)
    rlp_input = "d694" + proxy + "01"
    deployed_hash = _cast_keccak("0x" + rlp_input)
    deployed = deployed_hash[-40:]

    return "0x" + deployed


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify deployment-info addresses against CREATE3 derivations."
    )
    parser.add_argument(
        "deployment_info",
        help="path to deployment-info JSON",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=None,
        help="build-config JSON to cross-check addresses, salts, and nonces",
    )
    parser.add_argument(
        "--rpc-url",
        default=None,
        help="RPC URL for on-chain bytecode verification (checks if contracts are deployed)",
    )
    parser.add_argument(
        "--deployer",
        default=DEPLOYER,
        help=f"deployer contract address (default: {DEPLOYER})",
    )
    return parser.parse_args()


def main():
    args = _parse_args()

    with open(args.deployment_info, "r") as f:
        info = json.load(f)

    failures = 0
    total = 0

    # Cross-check against build config
    if args.config:
        config = json.loads(args.config.read_text())

        for idx, dc in enumerate(info.get("dataContracts", [])):
            if idx >= len(config.get("dataContracts", [])):
                print(f"\033[91mFAIL\033[0m  dataContracts[{idx}]: not in config")
                failures += 1
                continue
            cfg_dc = config["dataContracts"][idx]
            mismatches = []
            if dc["address"].lower() != cfg_dc["address"].lower():
                mismatches.append(f"address ({dc['address']} vs {cfg_dc['address']})")
            if dc["salt"].lower() != cfg_dc["salt"].lower():
                mismatches.append(f"salt ({dc['salt']} vs {cfg_dc['salt']})")
            if dc["nonce"] != cfg_dc["nonce"]:
                mismatches.append(f"nonce ({dc['nonce']} vs {cfg_dc['nonce']})")
            if mismatches:
                print(f"\033[91mFAIL\033[0m  dataContracts[{idx}]: {', '.join(mismatches)}")
                failures += 1
            else:
                print(f"\033[92mOK\033[0m    dataContracts[{idx}] ({dc['address']})")
            total += 1

        config_logic = config.get("logicContracts", {})
        for lc in info.get("logicContracts", []):
            name = lc.get("contractName", "unknown")
            total += 1
            if name not in config_logic:
                print(f"\033[91mFAIL\033[0m  {name}: not in config")
                failures += 1
                continue
            cfg_lc = config_logic[name]["deployment"]
            mismatches = []
            if lc["address"].lower() != cfg_lc["address"].lower():
                mismatches.append(f"address ({lc['address']} vs {cfg_lc['address']})")
            if lc["salt"].lower() != cfg_lc["salt"].lower():
                mismatches.append(f"salt ({lc['salt']} vs {cfg_lc['salt']})")
            if lc["nonce"] != cfg_lc["nonce"]:
                mismatches.append(f"nonce ({lc['nonce']} vs {cfg_lc['nonce']})")
            if mismatches:
                print(f"\033[91mFAIL\033[0m  {name}: {', '.join(mismatches)}")
                failures += 1
            else:
                print(f"\033[92mOK\033[0m    {name} ({lc['address']})")

        print()

    # CREATE3 address verification
    print("CREATE3 address verification:")
    all_contracts = []
    for idx, dc in enumerate(info.get("dataContracts", [])):
        all_contracts.append((f"dataContracts[{idx}]", dc))
    for lc in info.get("logicContracts", []):
        all_contracts.append((lc.get("contractName", "unknown"), lc))

    for label, contract in all_contracts:
        total += 1
        expected = contract["address"].lower()
        computed = compute_create3_address(args.deployer, contract["salt"]).lower()
        if computed == expected:
            print(f"\033[92mOK\033[0m    {label}: {expected}")
        else:
            print(f"\033[91mFAIL\033[0m  {label}: expected {expected}, computed {computed}")
            failures += 1

    # On-chain bytecode check
    if args.rpc_url:
        print(f"\nOn-chain verification ({args.rpc_url}):")
        for label, contract in all_contracts:
            total += 1
            result = subprocess.run(
                ["cast", "code", contract["address"], "--rpc-url", args.rpc_url],
                capture_output=True, text=True,
            )
            code = result.stdout.strip()
            if result.returncode != 0:
                print(f"\033[91mFAIL\033[0m  {label}: RPC error — {result.stderr.strip()}")
                failures += 1
            elif code == "0x" or code == "":
                print(f"\033[93mWARN\033[0m  {label}: no code at {contract['address']} (not yet deployed)")
            else:
                print(f"\033[92mOK\033[0m    {label}: code present at {contract['address']} ({len(code)//2 - 1} bytes)")

    print(f"\n{total} checks, {failures} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
