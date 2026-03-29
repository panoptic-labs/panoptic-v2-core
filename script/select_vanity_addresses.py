#!/usr/bin/env python3

import argparse
import csv
import json
from dataclasses import dataclass, field
from pathlib import Path


COMMON_LOGIC_CONTRACTS = {"PanopticMath", "InteractionHelper", "CollateralTrackerV2"}
DEFAULT_MAX_RARITY = 314649014
PRIORITY = {
    "PanopticFactoryV4": 1000,
    "PanopticFactoryV3": 990,
    "SemiFungiblePositionManagerV4": 950,
    "SemiFungiblePositionManagerV3": 940,
    "PanopticPoolV2": 900,
    "RiskEngine": 850,
    "BuilderFactory": 800,
    "CollateralTrackerV2": 700,
    "InteractionHelper": 600,
    "PanopticMath": 500,
}


@dataclass(order=True)
class VanityEntry:
    sort_index: tuple = field(init=False, repr=False)
    rarity: int
    address: str
    salt: str
    nonce: int

    def __post_init__(self):
        self.sort_index = (-self.rarity, self.address.lower())


@dataclass
class Location:
    config_path: Path
    kind: str
    key: str | int


@dataclass
class Target:
    name: str
    priority: int
    locations: list[Location]


def _normalize_address(address: str) -> str:
    return address.lower()


def _default_configs() -> list[Path]:
    defaults = [Path("build-config-v3.json"), Path("build-config-v4.json")]
    return [path for path in defaults if path.exists()]


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Select vanity address triples from a TSV and apply them to build configs."
    )
    parser.add_argument(
        "configs",
        nargs="*",
        type=Path,
        default=_default_configs(),
        help="build-config JSON files to update; defaults to v3/v4 configs if present",
    )
    parser.add_argument(
        "--vanity-tsv",
        type=Path,
        default=Path("script/vanity-addresses.tsv"),
        help="TSV file containing address / rarity / salt / nonce columns",
    )
    parser.add_argument(
        "--mode",
        choices=("shared", "disjoint"),
        default="shared",
        help="share common deployments across configs or allocate every slot independently",
    )
    parser.add_argument(
        "--exclude-config",
        action="append",
        type=Path,
        default=[],
        help="config whose addresses should be excluded from selection; may be passed multiple times",
    )
    parser.add_argument(
        "--in-place",
        action="store_true",
        help="write the selected address triples back into the config files",
    )
    parser.add_argument(
        "--max-rarity",
        type=int,
        default=DEFAULT_MAX_RARITY,
        help=f"exclude vanity entries with rarity above this cap; defaults to {DEFAULT_MAX_RARITY}",
    )
    return parser.parse_args()


def _load_json(path: Path) -> dict:
    with path.open() as file:
        return json.load(file)


def _load_vanity_entries(path: Path) -> list[VanityEntry]:
    with path.open(newline="") as file:
        reader = csv.DictReader(file, delimiter="\t")
        entries = []
        for row in reader:
            if not row["address"]:
                continue
            entries.append(
                VanityEntry(
                    rarity=int(row["rarity"]),
                    address=row["address"],
                    salt=row["salt"],
                    nonce=int(row["nonce"]),
                )
            )
    return sorted(entries)


def _iter_config_addresses(config: dict):
    for deployment in config["dataContracts"]:
        yield _normalize_address(deployment["address"])
    for options in config["logicContracts"].values():
        yield _normalize_address(options["deployment"]["address"])


def _priority_for(name: str) -> int:
    if name.startswith("dataContracts["):
        index = int(name.removeprefix("dataContracts[").removesuffix("]"))
        return 100 - index
    return PRIORITY.get(name, 0)


def _build_targets(configs: list[tuple[Path, dict]], mode: str) -> list[Target]:
    targets: list[Target] = []

    if mode == "shared":
        shared_data: dict[int, list[Location]] = {}
        for config_path, config in configs:
            for index, _ in enumerate(config["dataContracts"]):
                shared_data.setdefault(index, []).append(Location(config_path, "data", index))
        for index, locations in shared_data.items():
            targets.append(
                Target(
                    name=f"dataContracts[{index}]",
                    priority=_priority_for(f"dataContracts[{index}]"),
                    locations=locations,
                )
            )

        shared_logic: dict[str, list[Location]] = {}
        for config_path, config in configs:
            for name in COMMON_LOGIC_CONTRACTS:
                if name in config["logicContracts"]:
                    shared_logic.setdefault(name, []).append(Location(config_path, "logic", name))
        for name, locations in shared_logic.items():
            targets.append(Target(name=name, priority=_priority_for(name), locations=locations))

    for config_path, config in configs:
        if mode == "disjoint":
            for index, _ in enumerate(config["dataContracts"]):
                name = f"{config_path.name}:dataContracts[{index}]"
                targets.append(
                    Target(name=name, priority=_priority_for(f"dataContracts[{index}]"), locations=[Location(config_path, "data", index)])
                )

        for name in config["logicContracts"]:
            if mode == "shared" and name in COMMON_LOGIC_CONTRACTS:
                continue
            label = name if len(configs) == 1 else f"{config_path.name}:{name}"
            targets.append(
                Target(
                    name=label,
                    priority=_priority_for(name),
                    locations=[Location(config_path, "logic", name)],
                )
            )

    return sorted(targets, key=lambda target: (-target.priority, target.name))


def _apply_entry(config: dict, location: Location, entry: VanityEntry):
    if location.kind == "data":
        deployment = config["dataContracts"][location.key]
    else:
        deployment = config["logicContracts"][location.key]["deployment"]

    deployment["address"] = entry.address
    deployment["salt"] = entry.salt
    deployment["nonce"] = entry.nonce


def main():
    args = _parse_args()

    if not args.configs:
        raise SystemExit("no config files provided")

    configs = [(path, _load_json(path)) for path in args.configs]
    config_map = {path: config for path, config in configs}

    exclude_paths = list(args.exclude_config)
    legacy_config = Path("build-config.json")
    if legacy_config.exists() and legacy_config not in args.configs and legacy_config not in exclude_paths:
        exclude_paths.append(legacy_config)

    excluded_addresses = set()
    for path in exclude_paths:
        excluded_addresses.update(_iter_config_addresses(_load_json(path)))

    entries = [
        entry
        for entry in _load_vanity_entries(args.vanity_tsv)
        if _normalize_address(entry.address) not in excluded_addresses
        and entry.rarity <= args.max_rarity
    ]
    targets = _build_targets(configs, args.mode)

    if len(entries) < len(targets):
        raise SystemExit(
            f"not enough vanity entries after exclusions: need {len(targets)}, found {len(entries)}"
        )

    assignments = list(zip(targets, entries))

    for target, entry in assignments:
        print(f"{target.name}\t{entry.address}\t{entry.rarity}\t{entry.salt}\t{entry.nonce}")
        for location in target.locations:
            _apply_entry(config_map[location.config_path], location, entry)

    if args.in_place:
        for path, config in configs:
            path.write_text(json.dumps(config, indent=2) + "\n")


if __name__ == "__main__":
    main()
