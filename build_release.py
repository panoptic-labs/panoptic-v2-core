import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description="Build deterministic deployment artifacts.")
parser.add_argument("config", nargs="?", default="build-config.json", type=Path,
                    help="build-config JSON file (default: build-config.json)")
parser.add_argument("output", nargs="?", default=None, type=Path,
                    help="output deployment-info JSON path (default: derived from config name)")
parser.add_argument("--dry-run", action="store_true",
                    help="print build summary without running external tools or writing files")
args = parser.parse_args()

CONFIG_PATH = args.config
if args.output is not None:
    OUTPUT_PATH = args.output
else:
    OUTPUT_PATH = Path(
        "deployment-info.json"
        if CONFIG_PATH.name == "build-config.json"
        else f"deployment-info-{CONFIG_PATH.stem.removeprefix('build-config-')}.json"
    )
dry_run = args.dry_run


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
    encoded = subprocess.run(
        [
            "cast",
            "abi-encode",
            signature,
            *[_format_abi_arg(type_name, value) for type_name, value in zip(types, values)],
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()

    return encoded.removeprefix("0x")


metadata = None
if not dry_run:
    print("\033[95mCompiling metadata...\033[0m")
    subprocess.run(["bun", "run", "./metadata/compiler.js"], check=True)

metadata_path = Path("metadata/out/MetadataPackage.json")
if metadata_path.exists():
    with open(metadata_path, "r") as file:
        metadata = json.load(file)
    if not dry_run:
        print("\033[92mOK\033[0m")
elif dry_run:
    print("\033[93mWARNING: metadata/out/MetadataPackage.json not found, data contract details unavailable\033[0m")
else:
    raise FileNotFoundError("metadata/out/MetadataPackage.json not found after compilation")

print("\033[95mBuilding contracts...\033[0m" if not dry_run else "\033[95m--- DRY RUN ---\033[0m")

with open(CONFIG_PATH, "r") as file:
    config = json.load(file)

# propagate metadata to environment
if metadata is not None:
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

deploymentInfo = {"dataContracts": [], "logicContracts": []}

if metadata is not None:
    for deployment, code in zip(config["dataContracts"], metadata["bytecodes"]):
        deploymentInfo["dataContracts"].append(
            {
                "address": deployment["address"],
                "salt": deployment["salt"],
                "nonce": deployment["nonce"],
                "initcode": "0x" + code,
            }
        )

if dry_run:
    print(f"\n\033[96mConfig:\033[0m {CONFIG_PATH}")
    print(f"\033[96mOutput:\033[0m {OUTPUT_PATH}")
    print(f"\n\033[96mData contracts ({len(config['dataContracts'])}):\033[0m")
    for idx, dc in enumerate(config["dataContracts"]):
        print(f"  [{idx}] {dc['address']}")
    print(f"\n\033[96mLogic contracts ({len(config['logicContracts'])}):\033[0m")
    for contract_name, options in config["logicContracts"].items():
        line = f"  {contract_name:<40} {options['deployment']['address']}  runs={options['optimizeRuns']}"
        if "links" in options:
            line += f"  links={options['links']}"
        if "constructorArgs" in options:
            line += f"  args=({','.join(options['constructorArgs'][1])})"
        print(line)
    print(f"\n\033[95mDry run complete, no files written.\033[0m")
    sys.exit(0)

for contract_name, options in config["logicContracts"].items():
    subprocess.run(["forge", "clean"], check=True)

    artifact_name = options.get("artifactName", contract_name)

    command = [
        "forge",
        "build",
        options["path"],
        "--deny-warnings",
        "--use",
        "0.8.28",
        "--evm-version",
        "cancun",
        "--optimize",
        "true",
        "--optimizer-runs",
        str(options["optimizeRuns"]),
    ]

    if "links" in options:
        for lib in options["links"]:
            lib_options = config["logicContracts"][lib]
            lib_artifact_name = lib_options.get("artifactName", lib)
            command.append("--libraries")
            command.append(
                lib_options["path"]
                + ":"
                + lib_artifact_name
                + ":"
                + lib_options["deployment"]["address"]
            )

    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)

    with open(
        os.path.join("out", os.path.basename(options["path"]), f"{artifact_name}.json"),
        "r",
    ) as output_json_file:
        deploymentInfo["logicContracts"].append(
            {
                "address": options["deployment"]["address"],
                "contractName": contract_name,
                "initcode": json.load(output_json_file)["bytecode"]["object"],
                "nonce": options["deployment"]["nonce"],
                "salt": options["deployment"]["salt"],
            }
        )

    if "constructorArgs" in options:
        for i, arg in enumerate(options["constructorArgs"][0]):
            if type(arg) is str:
                if arg[0] == "@":
                    options["constructorArgs"][0][i] = config["logicContracts"][
                        arg[1:]
                    ]["deployment"]["address"]
                elif arg[0] == "$":
                    options["constructorArgs"][0][i] = config["env"][arg[1:]]
        deploymentInfo["logicContracts"][len(deploymentInfo["logicContracts"]) - 1][
            "initcode"
        ] += _abi_encode(options["constructorArgs"][1], options["constructorArgs"][0])

    print(f"\033[96m{contract_name}: \033[92mOK\033[0m")

with open(OUTPUT_PATH, "w+") as output_file:
    json.dump(deploymentInfo, output_file)
    print(f"\033[95minitcodes written to {OUTPUT_PATH}\033[0m")
