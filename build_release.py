import json
import os
import subprocess
import sys
from pathlib import Path

CONFIG_PATH = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("build-config.json")
default_output_name = (
    "deployment-info.json"
    if CONFIG_PATH.name == "build-config.json"
    else f"deployment-info-{CONFIG_PATH.stem.removeprefix('build-config-')}.json"
)
OUTPUT_PATH = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(default_output_name)


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

print("\033[95mCompiling metadata...")

subprocess.run(["bun", "run", "./metadata/compiler.js"], check=True)

with open("metadata/out/MetadataPackage.json", "r") as file:
    metadata = json.load(file)

print("\033[92mOK")

print("\033[95mBuilding contracts...")

with open(CONFIG_PATH, "r") as file:
    config = json.load(file)

# propagate metadata to environment
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
for deployment, code in zip(config["dataContracts"], metadata["bytecodes"]):
    deploymentInfo["dataContracts"].append(
        {
            "address": deployment["address"],
            "salt": deployment["salt"],
            "nonce": deployment["nonce"],
            "initcode": "0x" + code,
        }
    )

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

    print(f"\033[96m{contract_name}:", "\033[92mOK")

with open(OUTPUT_PATH, "w+") as output_file:
    json.dump(deploymentInfo, output_file)
    print(f"\033[95minitcodes written to {OUTPUT_PATH}")
