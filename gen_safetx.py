import argparse
import hashlib
import json
import os

parser = argparse.ArgumentParser(description="Generate Safe transaction JSON batches from deployment info.")
parser.add_argument("deployment_info", nargs="?", default="deployment-info.json",
                    help="path to deployment-info JSON (default: deployment-info.json)")
parser.add_argument("output_dir", nargs="?", default="./safe-txns",
                    help="output directory for Safe JSON files (default: ./safe-txns)")
parser.add_argument("--chain-id", default="1",
                    help="chain ID for Safe transactions (default: 1)")
parser.add_argument("--recipient", default="0x82BF455e9ebd6a541EF10b683dE1edCaf05cE7A1",
                    help="recipient address for mint transactions")
parser.add_argument("--check-duplicates-against", default=None, metavar="PATH",
                    help="path to another deployment-info JSON; warns if any addresses overlap")
parser.add_argument("--exclude-addresses-from", default=None, metavar="PATH",
                    help="path to another deployment-info JSON; exclude overlapping contracts from output")
parser.add_argument("--gas-limit", default=30_000_000, type=int,
                    help="max estimated gas per batch (default: 30000000)")
args = parser.parse_args()

with open(args.deployment_info, "r") as file:
    deploymentInfo = json.load(file)

os.makedirs(args.output_dir, exist_ok=True)

# Build set of addresses to exclude (already deployed via another config)
excluded_addresses = set()
if args.exclude_addresses_from:
    with open(args.exclude_addresses_from, "r") as f:
        other_info = json.load(f)
    for c in other_info.get("dataContracts", []):
        excluded_addresses.add(c["address"].lower())
    for c in other_info.get("logicContracts", []):
        excluded_addresses.add(c["address"].lower())


DEPLOYER = "0x000000000000b361194cfe6312EE3210d53C15AA"

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

# Per-contract gas overhead (Safe multicall base, mint, storage)
BASE_GAS_PER_CONTRACT = 80_000
# Gas per byte of initcode (deployment cost)
GAS_PER_BYTE = 200


def _estimate_gas(contract):
    initcode_bytes = len(contract["initcode"]) // 2 - 1  # hex to bytes, minus 0x
    return BASE_GAS_PER_CONTRACT + initcode_bytes * GAS_PER_BYTE


def _make_tx_pair(contract):
    salt_int = str(int(contract["salt"], 16))
    return [
        {
            "to": DEPLOYER,
            "value": "0",
            "data": None,
            "contractMethod": MINT_METHOD,
            "contractInputsValues": {
                "to": args.recipient,
                "id": salt_int,
                "nonce": str(contract["nonce"]),
            },
        },
        {
            "to": DEPLOYER,
            "value": "0",
            "data": None,
            "contractMethod": DEPLOY_METHOD,
            "contractInputsValues": {
                "id": salt_int,
                "initcode": contract["initcode"],
            },
        },
    ]


def _write_batch(batch_idx, name, contracts_with_names):
    transactions = []
    total_gas = 0
    contract_names = []
    for label, contract in contracts_with_names:
        transactions.extend(_make_tx_pair(contract))
        total_gas += _estimate_gas(contract)
        contract_names.append(label)

    safeTx = {
        "version": "1.0",
        "chainId": args.chain_id,
        "meta": {
            "name": name,
            "contracts": contract_names,
        },
        "transactions": transactions,
    }

    filename = f"{args.output_dir}/batch_{batch_idx}.json"
    with open(filename, "w") as output_file:
        json.dump(safeTx, output_file, indent=2)

    print(f"\033[92m{filename}\033[0m: {name}")
    for label in contract_names:
        print(f"  - {label}")
    print(f"  {len(contracts_with_names)} contracts, {len(transactions)} transactions, ~{total_gas:,} gas\n")


# Collect all contracts with labels, respecting exclusions
entries = []  # list of (label, contract_dict, gas)

for idx, contract in enumerate(deploymentInfo["dataContracts"]):
    if contract["address"].lower() in excluded_addresses:
        print(f"\033[90mSKIPPED: data contract {idx} at {contract['address']} (excluded)\033[0m")
        continue
    entries.append((f"dataContracts[{idx}]", contract))

for contract in deploymentInfo["logicContracts"]:
    if contract["address"].lower() in excluded_addresses:
        print(f"\033[90mSKIPPED: {contract['contractName']} at {contract['address']} (excluded)\033[0m")
        continue
    entries.append((contract["contractName"], contract))

# Split into batches that fit within gas limit
batches = []
current_batch = []
current_gas = 0

for label, contract in entries:
    gas = _estimate_gas(contract)
    if current_batch and current_gas + gas > args.gas_limit:
        batches.append(current_batch)
        current_batch = []
        current_gas = 0
    current_batch.append((label, contract))
    current_gas += gas

if current_batch:
    batches.append(current_batch)

# Write batches
for idx, batch in enumerate(batches):
    labels = [label for label, _ in batch]
    # Generate a descriptive name from the batch contents
    has_data = any(l.startswith("dataContracts") for l in labels)
    logic_names = [l for l in labels if not l.startswith("dataContracts")]
    if has_data and not logic_names:
        name = f"Data contracts"
    elif has_data:
        name = f"Data contracts + {', '.join(logic_names)}"
    else:
        name = ", ".join(logic_names)
    _write_batch(idx, name, batch)

# Check for duplicate addresses against another deployment-info file
if args.check_duplicates_against:
    with open(args.check_duplicates_against, "r") as f:
        other_info = json.load(f)

    def _collect_addresses(info):
        addrs = {}
        for i, c in enumerate(info.get("dataContracts", [])):
            addrs[c["address"].lower()] = f"dataContracts[{i}]"
        for c in info.get("logicContracts", []):
            addrs[c["address"].lower()] = c.get("contractName", "unknown")
        return addrs

    current = _collect_addresses(deploymentInfo)
    other = _collect_addresses(other_info)
    overlap = set(current) & set(other)

    if overlap:
        print(f"\033[93mWARNING: {len(overlap)} overlapping address(es) with {args.check_duplicates_against}:\033[0m")
        for addr in sorted(overlap):
            print(f"  {addr}  ({current[addr]} / {other[addr]})")
    else:
        print(f"No overlapping addresses with {args.check_duplicates_against}")
