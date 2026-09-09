#!/usr/bin/env python3
"""Compare Solidity bytecode with appended CBOR metadata.

The final two bytes of Solidity bytecode encode the CBOR metadata payload length.
This script strips that payload, decodes the common metadata keys, and reports
whether differences are executable-code differences or metadata-only drift.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from typing import Any


BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def clean_hex(value: str) -> bytes:
    value = value.strip()
    if value.startswith("@"):
        with open(value[1:], "r", encoding="utf-8") as handle:
            value = handle.read().strip()
    if value.startswith("0x"):
        value = value[2:]
    value = "".join(value.split())
    if len(value) % 2:
        raise ValueError("hex string has odd length")
    return bytes.fromhex(value)


def base58_encode(data: bytes) -> str:
    number = int.from_bytes(data, "big")
    encoded = ""
    while number:
        number, remainder = divmod(number, 58)
        encoded = BASE58_ALPHABET[remainder] + encoded
    leading_zeroes = 0
    for byte in data:
        if byte == 0:
            leading_zeroes += 1
        else:
            break
    return "1" * leading_zeroes + (encoded or "1")


def read_len(data: bytes, pos: int, additional: int) -> tuple[int, int]:
    if additional < 24:
        return additional, pos
    if additional == 24:
        return data[pos], pos + 1
    if additional == 25:
        return int.from_bytes(data[pos : pos + 2], "big"), pos + 2
    if additional == 26:
        return int.from_bytes(data[pos : pos + 4], "big"), pos + 4
    if additional == 27:
        return int.from_bytes(data[pos : pos + 8], "big"), pos + 8
    raise ValueError(f"unsupported CBOR additional info {additional}")


def decode_cbor_item(data: bytes, pos: int = 0) -> tuple[Any, int]:
    if pos >= len(data):
        raise ValueError("unexpected end of CBOR data")
    initial = data[pos]
    pos += 1
    major = initial >> 5
    additional = initial & 0x1F

    if major == 0:
        return read_len(data, pos, additional)
    if major == 2:
        length, pos = read_len(data, pos, additional)
        return data[pos : pos + length], pos + length
    if major == 3:
        length, pos = read_len(data, pos, additional)
        return data[pos : pos + length].decode("utf-8"), pos + length
    if major == 5:
        length, pos = read_len(data, pos, additional)
        result: dict[Any, Any] = {}
        for _ in range(length):
            key, pos = decode_cbor_item(data, pos)
            value, pos = decode_cbor_item(data, pos)
            result[key] = value
        return result, pos
    raise ValueError(f"unsupported CBOR major type {major}")


@dataclass(frozen=True)
class Metadata:
    bytecode: bytes
    stripped: bytes
    trailer: bytes
    cbor_length: int
    decoded: dict[Any, Any]


def split_metadata(bytecode: bytes) -> Metadata:
    if len(bytecode) < 2:
        raise ValueError("bytecode is shorter than metadata length suffix")
    cbor_length = int.from_bytes(bytecode[-2:], "big")
    trailer_start = len(bytecode) - 2 - cbor_length
    if trailer_start < 0:
        raise ValueError(
            f"invalid CBOR length {cbor_length}; bytecode is only {len(bytecode)} bytes"
        )
    trailer = bytecode[trailer_start:-2]
    decoded_any, end = decode_cbor_item(trailer)
    if end != len(trailer):
        raise ValueError(f"CBOR decoder stopped at {end}, trailer is {len(trailer)} bytes")
    if not isinstance(decoded_any, dict):
        raise ValueError("CBOR metadata payload is not a map")
    return Metadata(bytecode, bytecode[:trailer_start], trailer, cbor_length, decoded_any)


def solc_version(value: Any) -> str | None:
    if isinstance(value, bytes) and len(value) == 3:
        return ".".join(str(part) for part in value)
    if isinstance(value, str):
        return value
    return None


def bytecode_hash_info(decoded: dict[Any, Any]) -> tuple[str, bytes | None]:
    for key in ("ipfs", "bzzr1"):
        value = decoded.get(key)
        if isinstance(value, bytes):
            return key, value
    return "none", None


def describe(label: str, metadata: Metadata) -> None:
    hash_type, digest = bytecode_hash_info(metadata.decoded)
    solc = solc_version(metadata.decoded.get("solc")) or "unknown"
    cid = None
    if hash_type == "ipfs" and digest:
        cid = base58_encode(digest)

    print(f"{label}:")
    print(f"  bytecode bytes: {len(metadata.bytecode)}")
    print(f"  stripped bytes: {len(metadata.stripped)}")
    print(f"  CBOR length: {metadata.cbor_length}")
    print(f"  solc version: {solc}")
    print(f"  bytecodeHash type: {hash_type}")
    print(f"  embedded multihash hex: {digest.hex() if digest else ''}")
    print(f"  CIDv0: {cid or ''}")
    print(f"  decoded keys: {', '.join(str(key) for key in metadata.decoded.keys())}")


def first_diff(left: bytes, right: bytes) -> int | None:
    for index, (left_byte, right_byte) in enumerate(zip(left, right)):
        if left_byte != right_byte:
            return index
    if len(left) != len(right):
        return min(len(left), len(right))
    return None


def window(data: bytes, offset: int, radius: int = 12) -> str:
    start = max(0, offset - radius)
    end = min(len(data), offset + radius)
    return data[start:end].hex()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deployed-bytecode", required=True, help="0x hex or @file")
    parser.add_argument("--local-bytecode", required=True, help="0x hex or @file")
    parser.add_argument(
        "--patch-local-library-address",
        help=(
            "Patch the PUSH20 library self-address at the start of local deployed bytecode "
            "before comparing. Useful for Solidity library artifacts, which contain zeroes "
            "locally and the deployed library address on-chain."
        ),
    )
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = parser.parse_args()

    deployed = split_metadata(clean_hex(args.deployed_bytecode))
    local_bytes = clean_hex(args.local_bytecode)
    if args.patch_local_library_address:
        address = clean_hex(args.patch_local_library_address)
        if len(address) != 20:
            raise ValueError("--patch-local-library-address must be exactly 20 bytes")
        if not local_bytes.startswith(b"\x73"):
            raise ValueError("local bytecode does not start with PUSH20; cannot patch library address")
        local_bytes = local_bytes[:1] + address + local_bytes[21:]
    local = split_metadata(local_bytes)
    full_diff = first_diff(deployed.bytecode, local.bytecode)
    stripped_diff = first_diff(deployed.stripped, local.stripped)

    if args.json:
        def as_json(metadata: Metadata) -> dict[str, Any]:
            hash_type, digest = bytecode_hash_info(metadata.decoded)
            return {
                "bytecodeBytes": len(metadata.bytecode),
                "strippedBytes": len(metadata.stripped),
                "cborLength": metadata.cbor_length,
                "solcVersion": solc_version(metadata.decoded.get("solc")),
                "bytecodeHashType": hash_type,
                "multihashHex": digest.hex() if digest else None,
                "cidv0": base58_encode(digest) if hash_type == "ipfs" and digest else None,
            }

        print(json.dumps({
            "deployed": as_json(deployed),
            "local": as_json(local),
            "fullBytecodeMatches": full_diff is None,
            "strippedBytecodeMatches": stripped_diff is None,
            "firstFullDiff": full_diff,
            "firstStrippedDiff": stripped_diff,
        }, indent=2))
        return 0 if stripped_diff is None else 1

    describe("deployed", deployed)
    describe("local", local)
    print("comparison:")
    print(f"  full bytecode matches: {full_diff is None}")
    print(f"  stripped bytecode matches: {stripped_diff is None}")
    if full_diff is not None:
        print(f"  first full diff offset: {full_diff}")
        print(f"  deployed full window: {window(deployed.bytecode, full_diff)}")
        print(f"  local full window:    {window(local.bytecode, full_diff)}")
    if stripped_diff is not None:
        print(f"  first stripped diff offset: {stripped_diff}")
        print(f"  deployed stripped window: {window(deployed.stripped, stripped_diff)}")
        print(f"  local stripped window:    {window(local.stripped, stripped_diff)}")
    elif full_diff is not None:
        print("  diagnosis: executable runtime matches; difference is confined to metadata")
    return 0 if stripped_diff is None else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
