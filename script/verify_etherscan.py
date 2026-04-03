#!/usr/bin/env python3
"""Verify deployed contracts on Etherscan using forge verify-contract.

Reads a build config to determine compiler settings, library links, and
constructor arguments for each logic contract, then runs forge verify-contract
for each one.

Usage:
    python3 script/verify_etherscan.py build-config-v4.json --etherscan-api-key $ETHERSCAN_API_KEY
    python3 script/verify_etherscan.py build-config-v3.json --chain-id 1 --etherscan-api-key $ETHERSCAN_API_KEY
    python3 script/verify_etherscan.py build-config-v4.json --dry-run
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path


COMPILER_VERSION = "0.8.28"
EVM_VERSION = "cancun"


def _format_abi_arg(type_name, value):
    if type_name.endswith("[]"):
        inner_type = type_name[:-2]
        return "[" + ",".join(_format_abi_arg(inner_type, item) for item in value) + "]"
    if type_name == "bytes32":
        if isinstance(value, str) and value.startswith("0x"):
            return value
        if isinstance(value, (bytes, bytearray)):
            return "0x" + bytes(value).ljust(32, b"\x00").hex()
        raise TypeError(f"unsupported bytes32 value: {value!r}")
    if type_name == "address":
        return value
    return str(value)


def _abi_encode(types, values):
    signature = "f(" + ",".join(types) + ")"
    result = subprocess.run(
        [
            "cast", "abi-encode", signature,
            *[_format_abi_arg(t, v) for t, v in zip(types, values)],
        ],
        check=True, capture_output=True, text=True,
    )
    return result.stdout.strip()


def _resolve_constructor_args(config, options):
    """Resolve @ and $ references in constructor args and ABI-encode them."""
    if "constructorArgs" not in options:
        return None

    values = list(options["constructorArgs"][0])
    types = options["constructorArgs"][1]

    for i, arg in enumerate(values):
        if isinstance(arg, str):
            if arg.startswith("@"):
                values[i] = config["logicContracts"][arg[1:]]["deployment"]["address"]
            elif arg.startswith("$"):
                values[i] = config["env"][arg[1:]]

    return _abi_encode(types, values)


def main():
    parser = argparse.ArgumentParser(description="Verify contracts on Etherscan via forge verify-contract.")
    parser.add_argument("config", type=Path, help="build-config JSON file")
    parser.add_argument("--chain-id", default="1", help="chain ID (default: 1)")
    parser.add_argument("--etherscan-api-key", default=None, help="Etherscan API key")
    parser.add_argument("--verifier-url", default=None, help="custom verifier URL (e.g. for Blockscout)")
    parser.add_argument("--dry-run", action="store_true", help="print commands without running them")
    parser.add_argument("--contracts", nargs="*", default=None,
                        help="only verify these contract names (default: all)")
    args = parser.parse_args()

    config = json.loads(args.config.read_text())

    # Load metadata for MD_* env vars if needed
    metadata_path = Path("metadata/out/MetadataPackage.json")
    if metadata_path.exists():
        metadata = json.loads(metadata_path.read_text())
        config["env"]["MD_PROPERTIES"] = list(
            map(lambda prop: str.encode(prop), metadata["properties"])
        )
        config["env"]["MD_INDICES"] = list(
            map(
                lambda propIndices: list(map(lambda index: int(index), propIndices)),
                metadata["indices"],
            )
        )
        config["env"]["MD_POINTERS"] = list(
            map(
                lambda propPointers: list(
                    map(
                        lambda pointer: (pointer["size"] << 208)
                        + (pointer["start"] << 160)
                        + int(config["dataContracts"][pointer["codeIndex"]]["address"], 16),
                        propPointers,
                    )
                ),
                metadata["pointers"],
            )
        )

    successes = 0
    failures = 0

    for contract_name, options in config["logicContracts"].items():
        if args.contracts and contract_name not in args.contracts:
            continue

        artifact_name = options.get("artifactName", contract_name)
        address = options["deployment"]["address"]

        command = [
            "forge", "verify-contract",
            address,
            f"{options['path']}:{artifact_name}",
            "--compiler-version", COMPILER_VERSION,
            "--optimizer-runs", str(options["optimizeRuns"]),
            "--evm-version", EVM_VERSION,
            "--chain-id", args.chain_id,
        ]

        if "links" in options:
            for lib in options["links"]:
                lib_options = config["logicContracts"][lib]
                lib_artifact_name = lib_options.get("artifactName", lib)
                command.append("--libraries")
                command.append(
                    f"{lib_options['path']}:{lib_artifact_name}:{lib_options['deployment']['address']}"
                )

        if "constructorArgs" in options:
            encoded = _resolve_constructor_args(config, options)
            if encoded:
                command.extend(["--constructor-args", encoded])

        if args.etherscan_api_key:
            command.extend(["--etherscan-api-key", args.etherscan_api_key])

        if args.verifier_url:
            command.extend(["--verifier-url", args.verifier_url])

        if args.dry_run:
            # Mask API key in output
            display = list(command)
            for i, part in enumerate(display):
                if i > 0 and display[i - 1] == "--etherscan-api-key":
                    display[i] = "$ETHERSCAN_API_KEY"
            print(f"\033[96m{contract_name}\033[0m @ {address}")
            print("  " + " \\\n    ".join(display))
            print()
            continue

        print(f"\033[96m{contract_name}\033[0m @ {address} ... ", end="", flush=True)
        result = subprocess.run(command, capture_output=True, text=True)

        if result.returncode == 0:
            print(f"\033[92mOK\033[0m")
            successes += 1
        else:
            print(f"\033[91mFAILED\033[0m")
            print(f"  {result.stderr.strip()}")
            failures += 1

    if not args.dry_run:
        print(f"\n{successes + failures} contracts, {successes} verified, {failures} failed")
        sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
