#!/usr/bin/env python3
"""Find the maximum optimizer runs for each contract that stays under the EIP-170 size limit.

For each logic contract in a build config, binary-searches optimizer runs in [1, MAX_RUNS]
and reports the highest value whose deployed runtime bytecode fits in 24,576 bytes.

The report also includes total initcode size, including ABI-encoded constructor arguments,
so large deployment payloads remain visible alongside runtime size.

Usage:
    python3 script/optimize_runs.py build-config-v3.json
    python3 script/optimize_runs.py build-config-v4.json --max-runs 20000000 --margin 256
"""

import argparse
import json
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

EIP170_LIMIT = 24_576  # bytes of runtime bytecode
EIP3860_LIMIT = 49_152  # bytes of initcode


class ForgeBuildError(RuntimeError):
    """Raised when forge build fails for a probe."""

    def __init__(self, command, stdout, stderr):
        self.command = command
        self.stdout = stdout
        self.stderr = stderr
        super().__init__("forge build failed")


@dataclass(frozen=True)
class Measurement:
    runtime_size: int
    initcode_size: int


@dataclass(frozen=True)
class SearchResult:
    kind: str
    runs: int | None
    measurement: Measurement | None


def parse_args():
    parser = argparse.ArgumentParser(description="Find optimal optimizer runs per contract.")
    parser.add_argument("config", type=Path, help="build-config JSON file")
    parser.add_argument(
        "--max-runs",
        type=int,
        default=9_999_999,
        help="upper bound for binary search (default: 9999999)",
    )
    parser.add_argument(
        "--margin",
        type=int,
        default=0,
        help="safety margin in bytes subtracted from the 24576 limit (default: 0)",
    )
    parser.add_argument(
        "--contracts",
        nargs="*",
        default=None,
        help="only optimize these contract names (default: all)",
    )
    return parser.parse_args()


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


def _inject_metadata_env(config):
    metadata_path = Path("metadata/out/MetadataPackage.json")
    if not metadata_path.exists():
        return

    metadata = json.loads(metadata_path.read_text())
    env = config.setdefault("env", {})

    env["MD_PROPERTIES"] = [str.encode(prop) for prop in metadata["properties"]]
    env["MD_INDICES"] = [
        [int(index) for index in prop_indices] for prop_indices in metadata["indices"]
    ]
    env["MD_POINTERS"] = [
        [
            (pointer["size"] << 208)
            + (pointer["start"] << 160)
            + int(config["dataContracts"][pointer["codeIndex"]]["address"], 16)
            for pointer in prop_pointers
        ]
        for prop_pointers in metadata["pointers"]
    ]


def _resolve_constructor_args(options, config):
    constructor_args = options.get("constructorArgs")
    if not constructor_args:
        return ""

    env = config.get("env", {})
    resolved_values = []

    for arg in constructor_args[0]:
        if not isinstance(arg, str):
            resolved_values.append(arg)
            continue

        if arg.startswith("@"):
            contract_name = arg[1:]
            if contract_name not in config["logicContracts"]:
                raise KeyError(f"missing logic contract reference: {contract_name}")
            resolved_values.append(
                config["logicContracts"][contract_name]["deployment"]["address"]
            )
        elif arg.startswith("$"):
            env_name = arg[1:]
            if env_name not in env:
                raise KeyError(f"missing env value for constructor arg: {env_name}")
            resolved_values.append(env[env_name])
        else:
            resolved_values.append(arg)

    return _abi_encode(constructor_args[1], resolved_values)


def _format_measurement(measurement):
    headroom = EIP3860_LIMIT - measurement.initcode_size
    headroom_text = f"{headroom}B"
    if headroom < 0:
        headroom_text = f"{headroom}B OVER"

    return (
        f"runtime={measurement.runtime_size}B, "
        f"init={measurement.initcode_size}B, "
        f"EIP-3860 headroom={headroom_text}"
    )


def _artifact_path(out_dir, contract_path, artifact_name):
    return out_dir / Path(contract_path).name / f"{artifact_name}.json"


def build_and_measure(
    contract_name,
    options,
    runs,
    config,
    out_dir,
    cache_dir,
    measurement_cache,
):
    """Compile a contract and return runtime/initcode sizes in bytes."""
    if runs in measurement_cache:
        return measurement_cache[runs]

    contract_path = options["path"]
    artifact_name = options.get("artifactName", contract_name)
    links = options.get("links", [])

    out_dir.mkdir(parents=True, exist_ok=True)
    cache_dir.mkdir(parents=True, exist_ok=True)

    command = [
        "forge",
        "build",
        contract_path,
        "--deny",
        "warnings",
        "--use",
        "0.8.28",
        "--evm-version",
        "cancun",
        "--optimize",
        "true",
        "--optimizer-runs",
        str(runs),
        "--out",
        str(out_dir),
        "--cache-path",
        str(cache_dir),
    ]

    for lib in links:
        lib_options = config["logicContracts"][lib]
        lib_artifact = lib_options.get("artifactName", lib)
        command += [
            "--libraries",
            f"{lib_options['path']}:{lib_artifact}:{lib_options['deployment']['address']}",
        ]

    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise ForgeBuildError(command, result.stdout, result.stderr)

    artifact_path = _artifact_path(out_dir, contract_path, artifact_name)
    if not artifact_path.exists():
        raise FileNotFoundError(f"expected artifact not found: {artifact_path}")

    artifact = json.loads(artifact_path.read_text())
    deployed_hex = artifact.get("deployedBytecode", {}).get("object", "0x").removeprefix("0x")
    creation_hex = artifact.get("bytecode", {}).get("object", "0x").removeprefix("0x")
    constructor_hex = _resolve_constructor_args(options, config)

    measurement = Measurement(
        runtime_size=len(deployed_hex) // 2,
        initcode_size=(len(creation_hex) + len(constructor_hex)) // 2,
    )
    measurement_cache[runs] = measurement
    return measurement


def find_max_runs(measure, max_runs, limit):
    """Binary search for the highest optimizer runs that keeps runtime bytecode under limit."""
    size_at_max = measure(max_runs)
    if size_at_max.runtime_size <= limit:
        return SearchResult("lower_bound", max_runs, size_at_max)

    size_at_min = measure(1)
    if size_at_min.runtime_size > limit:
        return SearchResult("too_large", None, size_at_min)

    lo, hi = 1, max_runs
    lo_measurement = size_at_min

    while lo + 1 < hi:
        mid = (lo + hi) // 2
        measurement = measure(mid)
        if measurement.runtime_size <= limit:
            lo, lo_measurement = mid, measurement
        else:
            hi = mid

    return SearchResult("exact", lo, lo_measurement)


def _print_build_failure(contract_name, runs, error):
    print(
        f"\033[91mERROR: forge build failed for {contract_name} at runs={runs}\033[0m",
        file=sys.stderr,
    )
    print("Command:", " ".join(error.command), file=sys.stderr)
    if error.stdout.strip():
        print("\nstdout:\n" + error.stdout, file=sys.stderr)
    if error.stderr.strip():
        print("\nstderr:\n" + error.stderr, file=sys.stderr)


def main():
    args = parse_args()
    limit = EIP170_LIMIT - args.margin

    if args.max_runs < 1:
        raise SystemExit("--max-runs must be >= 1")
    if args.margin < 0:
        raise SystemExit("--margin must be >= 0")
    if limit <= 0:
        raise SystemExit(f"--margin must be smaller than {EIP170_LIMIT}")

    config = json.loads(args.config.read_text())
    _inject_metadata_env(config)

    if args.contracts:
        unknown = sorted(set(args.contracts) - set(config["logicContracts"]))
        if unknown:
            raise SystemExit(f"unknown contract(s): {', '.join(unknown)}")

    print(f"Config: {args.config}", flush=True)
    print(
        f"Runtime size limit: {limit} bytes (EIP-170={EIP170_LIMIT}, margin={args.margin})",
        flush=True,
    )
    print(f"Initcode limit: {EIP3860_LIMIT} bytes (EIP-3860)", flush=True)
    print(f"Search range: [1, {args.max_runs}]", flush=True)
    print(flush=True)

    results = []

    for name, options in config["logicContracts"].items():
        if args.contracts and name not in args.contracts:
            continue

        current_runs = options["optimizeRuns"]
        print(f"\033[96m{name}\033[0m (current: {current_runs} runs)", flush=True)

        with tempfile.TemporaryDirectory(prefix=f"optimize_runs_{name}_") as temp_dir:
            temp_root = Path(temp_dir)
            out_dir = temp_root / "out"
            cache_dir = temp_root / "cache"
            measurement_cache = {}
            last_probe = {"runs": None}

            def measure(runs):
                last_probe["runs"] = runs
                return build_and_measure(
                    name,
                    options,
                    runs,
                    config,
                    out_dir,
                    cache_dir,
                    measurement_cache,
                )

            try:
                current_measurement = measure(current_runs)
            except ForgeBuildError as error:
                _print_build_failure(name, current_runs, error)
                raise SystemExit(1) from error
            except (FileNotFoundError, KeyError, TypeError) as error:
                print(
                    f"\033[91mERROR: failed to measure {name} at runs={current_runs}: {error}\033[0m",
                    file=sys.stderr,
                )
                raise SystemExit(1) from error

            runtime_status = "OK" if current_measurement.runtime_size <= limit else "OVER"
            runtime_color = (
                "\033[92m" if current_measurement.runtime_size <= limit else "\033[91m"
            )
            print(
                f"  current: {current_runs} runs -> "
                f"{runtime_color}{runtime_status}\033[0m "
                f"({_format_measurement(current_measurement)})"
            )

            try:
                if current_runs > args.max_runs and current_measurement.runtime_size <= limit:
                    search_result = SearchResult(
                        "lower_bound",
                        current_runs,
                        current_measurement,
                    )
                else:
                    search_result = find_max_runs(measure, args.max_runs, limit)
            except ForgeBuildError as error:
                _print_build_failure(name, last_probe["runs"], error)
                raise SystemExit(1) from error
            except (FileNotFoundError, KeyError, TypeError) as error:
                print(
                    f"\033[91mERROR: failed while searching {name}: {error}\033[0m",
                    file=sys.stderr,
                )
                raise SystemExit(1) from error

            if search_result.kind == "too_large":
                print(
                    "  optimal: \033[91mexceeds runtime limit even at runs=1\033[0m "
                    f"({_format_measurement(search_result.measurement)})"
                )
            elif search_result.kind == "lower_bound":
                print(
                    f"  optimal: \033[92m>= {search_result.runs} runs\033[0m "
                    f"({_format_measurement(search_result.measurement)})"
                )
            else:
                print(
                    f"  optimal: \033[93m{search_result.runs} runs\033[0m "
                    f"({_format_measurement(search_result.measurement)})"
                )

            print()
            results.append(
                {
                    "contract": name,
                    "currentRuns": current_runs,
                    "currentMeasurement": current_measurement,
                    "searchResult": search_result,
                }
            )

    print("\033[95m" + "=" * 122 + "\033[0m")
    print(
        f"{'Contract':<32} {'Current':>10} {'Result':>14} {'Runtime':>10} "
        f"{'Initcode':>10} {'Headroom':>11} {'Delta':>8}"
    )
    print("-" * 122)
    for result in results:
        search_result = result["searchResult"]
        measurement = search_result.measurement

        if search_result.kind == "too_large":
            result_display = "N/A"
            runtime_display = (
                f"{measurement.runtime_size}B" if measurement is not None else "N/A"
            )
            initcode_display = (
                f"{measurement.initcode_size}B" if measurement is not None else "N/A"
            )
            headroom_display = (
                f"{EIP3860_LIMIT - measurement.initcode_size}B"
                if measurement is not None
                else "N/A"
            )
            delta = ""
        else:
            if search_result.kind == "lower_bound":
                result_display = f">= {search_result.runs}"
                delta = ""
            else:
                result_display = str(search_result.runs)
                delta = (
                    "CHANGE"
                    if result["currentRuns"] != search_result.runs
                    else ""
                )

            runtime_display = f"{measurement.runtime_size}B"
            initcode_display = f"{measurement.initcode_size}B"
            headroom_display = f"{EIP3860_LIMIT - measurement.initcode_size}B"

        print(
            f"{result['contract']:<32} "
            f"{result['currentRuns']:>10} "
            f"{result_display:>14} "
            f"{runtime_display:>10} "
            f"{initcode_display:>10} "
            f"{headroom_display:>11} "
            f"{delta:>8}"
        )
    print("-" * 122)


if __name__ == "__main__":
    main()
