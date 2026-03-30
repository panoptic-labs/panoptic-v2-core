#!/usr/bin/env python3
"""Verify that deployment-info addresses match expected vanity address derivations.

Uses the sub-zero VanityMarket (https://github.com/Philogy/sub-zero-contracts) address
derivation: CREATE2 for the deploy proxy, then CREATE at nonce+1 for the final address.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

DEPLOYER = "0x000000000000b361194cfe6312EE3210d53C15AA"
# keccak256 of the sub-zero deploy proxy initcode (49 bytes)
PROXY_INITCODE_HASH = "1decbcf04b355d500cbc3bd83c892545b4df34bd5b2c9d91b9f7f8165e2095c3"


def _cast_keccak(hex_data: str) -> str:
    result = subprocess.run(
        ["cast", "keccak", hex_data],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip().removeprefix("0x")


def _rlp_create_address(proxy_hex: str, nonce: int) -> str:
    """RLP-encode [proxy, nonce] for CREATE address derivation."""
    if nonce == 0:
        return "d694" + proxy_hex + "80"
    elif nonce <= 0x7F:
        return "d694" + proxy_hex + format(nonce, "02x")
    elif nonce <= 0xFF:
        return "d794" + proxy_hex + "81" + format(nonce, "02x")
    else:
        raise ValueError(f"nonce too large for single-byte RLP: {nonce}")


def compute_vanity_address(deployer: str, salt: str, nonce: int) -> str:
    """Compute the sub-zero VanityMarket deployed address.

    Step 1: proxy = CREATE2(deployer, salt, PROXY_INITCODE_HASH)
    Step 2: deployed = CREATE(proxy, nonce + 1)

    The nonce parameter is a nonce *increment*. Contract nonces start at 1 (EIP-161),
    so the actual CREATE nonce is nonce + 1.
    """
    deployer_hex = deployer.lower().removeprefix("0x").zfill(40)
    salt_hex = salt.lower().removeprefix("0x").zfill(64)

    # CREATE2: keccak256(0xff ++ deployer ++ salt ++ initcode_hash)
    create2_input = "ff" + deployer_hex + salt_hex + PROXY_INITCODE_HASH
    proxy_hash = _cast_keccak("0x" + create2_input)
    proxy = proxy_hash[-40:]

    # CREATE: keccak256(RLP([proxy, nonce + 1]))
    rlp_input = _rlp_create_address(proxy, nonce + 1)
    deployed_hash = _cast_keccak("0x" + rlp_input)
    deployed = deployed_hash[-40:]

    return "0x" + deployed


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify deployment-info addresses against sub-zero VanityMarket derivations."
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

    # Address derivation verification
    print("Address derivation verification:")
    all_contracts = []
    for idx, dc in enumerate(info.get("dataContracts", [])):
        all_contracts.append((f"dataContracts[{idx}]", dc))
    for lc in info.get("logicContracts", []):
        all_contracts.append((lc.get("contractName", "unknown"), lc))

    for label, contract in all_contracts:
        total += 1
        expected = contract["address"].lower()
        computed = compute_vanity_address(args.deployer, contract["salt"], contract["nonce"]).lower()
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
