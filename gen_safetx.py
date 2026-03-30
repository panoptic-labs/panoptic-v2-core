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
args = parser.parse_args()

with open(args.deployment_info, "r") as file:
    deploymentInfo = json.load(file)

os.makedirs(args.output_dir, exist_ok=True)

for idx, contract in enumerate(deploymentInfo["dataContracts"]):
    safeTx = {
        "chainId": args.chain_id,
        "meta": {
            "name": f"Deploy data contract {idx} at {contract["address"]}",
            "sourceHash": hashlib.sha256(json.dumps(contract, sort_keys=True).encode()).hexdigest(),
        },
        "transactions": [
            {
                "to": "0x000000000000b361194cfe6312EE3210d53C15AA",
                "value": "0",
                "data": None,
                "contractMethod": {
                    "inputs": [
                        {
                            "internalType": "address",
                            "name": "to",
                            "type": "address"
                        },
                        {
                            "internalType": "uint256",
                            "name": "id",
                            "type": "uint256"
                        },
                        {
                            "internalType": "uint8",
                            "name": "nonce",
                            "type": "uint8"
                        }
                    ],
                    "name": "mint",
                    "payable": False
                },
                "contractInputsValues": {
                    "to": args.recipient,
                    "id": str(int(contract["salt"], 16)),
                    "nonce": str(contract["nonce"])
                }
            },
            {
                "to": "0x000000000000b361194cfe6312EE3210d53C15AA",
                "value": "0",
                "data": None,
                "contractMethod": {
                    "inputs": [
                        {
                            "internalType": "uint256",
                            "name": "id",
                            "type": "uint256"
                        },
                        {
                            "internalType": "bytes",
                            "name": "initcode",
                            "type": "bytes"
                        }
                    ],
                    "name": "deploy",
                    "payable": True
                },
                "contractInputsValues": {
                    "id": str(int(contract["salt"], 16)),
                    "initcode": contract["initcode"]
                }
            }
        ]
    }

    with open(f"{args.output_dir}/dataDeploy_{idx}.json", "w") as output_file:
        json.dump(safeTx, output_file, indent=2)

for idx, contract in enumerate(deploymentInfo["logicContracts"]):
    safeTx = {
        "chainId": args.chain_id,
        "meta": {
            "name": f"Deploy contract {contract["contractName"]} at {contract["address"]}",
            "sourceHash": hashlib.sha256(json.dumps(contract, sort_keys=True).encode()).hexdigest(),
        },
        "transactions": [
            {
                "to": "0x000000000000b361194cfe6312EE3210d53C15AA",
                "value": "0",
                "data": None,
                "contractMethod": {
                    "inputs": [
                        {
                            "internalType": "address",
                            "name": "to",
                            "type": "address"
                        },
                        {
                            "internalType": "uint256",
                            "name": "id",
                            "type": "uint256"
                        },
                        {
                            "internalType": "uint8",
                            "name": "nonce",
                            "type": "uint8"
                        }
                    ],
                    "name": "mint",
                    "payable": False
                },
                "contractInputsValues": {
                    "to": args.recipient,
                    "id": str(int(contract["salt"], 16)),
                    "nonce": str(contract["nonce"])
                }
            },
            {
                "to": "0x000000000000b361194cfe6312EE3210d53C15AA",
                "value": "0",
                "data": None,
                "contractMethod": {
                    "inputs": [
                        {
                            "internalType": "uint256",
                            "name": "id",
                            "type": "uint256"
                        },
                        {
                            "internalType": "bytes",
                            "name": "initcode",
                            "type": "bytes"
                        }
                    ],
                    "name": "deploy",
                    "payable": True
                },
                "contractInputsValues": {
                    "id": str(int(contract["salt"], 16)),
                    "initcode": contract["initcode"]
                }
            }
        ]
    }

    with open(f"{args.output_dir}/deploy_{idx}_{contract["contractName"]}.json", "w") as output_file:
        json.dump(safeTx, output_file, indent=2)

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
