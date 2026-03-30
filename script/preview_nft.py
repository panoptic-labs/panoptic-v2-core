#!/usr/bin/env python3

import argparse
import base64
import json
import re
from html import escape
from pathlib import Path


CHAIN_NAMES = {
    1: "Ethereum",
    10: "Optimism",
    30: "Rootstock",
    56: "BNB Smart Chain",
    100: "Gnosis",
    130: "Unichain",
    137: "Polygon",
    169: "Manta",
    238: "Blast",
    250: "Fantom",
    288: "Boba",
    314: "Filecoin",
    324: "ZkSync Era",
    480: "World Chain",
    1116: "Core Blockchain",
    1135: "Lisk",
    1284: "Moonbeam",
    1329: "Sei",
    5000: "Mantle",
    8453: "Base",
    1101: "Polygon zkEVM",
    42220: "CELO",
    42161: "Arbitrum One",
    43114: "Avalanche C-Chain",
    48900: "Zircuit",
    59144: "Linea",
    60808: "BOB",
    34443: "Mode",
    167000: "Taiko",
    534352: "Scroll",
    7777777: "Zora",
}


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate a local preview for a Panoptic Factory NFT from metadata/FactoryNFT.json."
    )
    target_group = parser.add_mutually_exclusive_group(required=True)
    target_group.add_argument(
        "--pool",
        help="PanopticPool address used for the NFT rarity and strategy preview",
    )
    target_group.add_argument(
        "--token-id",
        help="Full NFT tokenId; the low 160 bits are used as the PanopticPool address",
    )
    parser.add_argument("--symbol0", required=True, help="Token0 symbol to render")
    parser.add_argument("--symbol1", required=True, help="Token1 symbol to render")
    parser.add_argument(
        "--fee",
        required=True,
        type=int,
        help="Uniswap fee in hundredths of a bip, e.g. 500 or 3000",
    )
    parser.add_argument(
        "--chain-id",
        type=int,
        default=1,
        help="Chain ID used for the chain label in the preview; defaults to 1",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        help="Output directory for preview files; defaults under metadata/out/previews/",
    )
    return parser.parse_args()


def _sanitize_segment(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-") or "preview"


def _pool_address(args: argparse.Namespace) -> str:
    if args.pool:
        pool_address = args.pool
        if not pool_address.startswith("0x"):
            raise SystemExit("--pool must be a 0x-prefixed address")
        if len(pool_address) != 42:
            raise SystemExit("--pool must be 20 bytes")
        return pool_address

    token_id = int(args.token_id, 0)
    pool_int = token_id & ((1 << 160) - 1)
    return f"0x{pool_int:040x}"


def _default_out_dir(pool_address: str, args: argparse.Namespace) -> Path:
    pool_segment = _sanitize_segment(pool_address.lower())
    symbols_segment = _sanitize_segment(f"{args.symbol0}-{args.symbol1}")
    return Path("metadata/out/previews") / (
        f"{pool_segment}-{symbols_segment}-fee{args.fee}-chain{args.chain_id}"
    )


def _number_of_leading_hex_zeros(pool_int: int) -> int:
    if pool_int == 0:
        return 40
    return len(f"{pool_int:040x}") - len(f"{pool_int:040x}".lstrip("0"))


def _uniswap_fee_to_string(fee: int) -> str:
    if fee % 100 == 0:
        return f"{fee // 100}bps"
    return f"{fee // 100}.{(fee // 10) % 10}{fee % 10}bps"


def _chain_name(chain_id: int) -> str:
    return CHAIN_NAMES.get(chain_id, str(chain_id))


def _max_symbol_width(rarity: int) -> int:
    if rarity < 3:
        return 1600
    if rarity < 9:
        return 1350
    if rarity < 12:
        return 1450
    if rarity < 15:
        return 1350
    if rarity < 19:
        return 1250
    if rarity < 20:
        return 1350
    if rarity < 21:
        return 1450
    if rarity < 23:
        return 1350
    return 1600


def _max_rarity_label_width(rarity: int) -> int:
    if rarity < 3:
        return 210
    if rarity < 6:
        return 220
    if rarity < 9:
        return 210
    if rarity < 12:
        return 220
    if rarity < 15:
        return 260
    if rarity < 19:
        return 225
    if rarity < 20:
        return 260
    if rarity < 21:
        return 220
    if rarity < 22:
        return 210
    if rarity < 23:
        return 220
    return 210


def _max_strategy_label_width(rarity: int) -> int:
    if rarity < 6:
        return 9000
    if rarity <= 22:
        return 3900
    return 9000


def _write_font(text: str, char_offsets: dict[str, int], char_paths: dict[str, str], max_width: int | None = None) -> str:
    offset = 0
    font_group = ""

    for char in text:
        if char not in char_offsets or char not in char_paths:
            raise SystemExit(f"metadata font missing character {char!r}")
        char_offset = int(char_offsets[char])
        offset += char_offset
        font_group = (
            f'<g transform="translate(-{char_offset}, 0)">{font_group}{char_paths[char]}</g>'
        )

    if max_width is not None and offset > max_width:
        scale = (3400 * max_width) // offset
        factor = str(scale) if scale > 99 else f"0{scale}"
    else:
        factor = "34"

    return f'<g transform="scale(0.0{factor}) translate({offset // 2}, 0)">{font_group}</g>'


def _render_svg(metadata: dict, pool_address: str, symbol0: str, symbol1: str, fee: int, chain_id: int) -> tuple[str, int, int]:
    pool_int = int(pool_address, 16)
    rarity = _number_of_leading_hex_zeros(pool_int)
    last_char_val = pool_int & 0xF

    frames = metadata["frames"]
    strategies = metadata["strategies"]
    descriptions = metadata["descriptions"]
    rarities = metadata["rarities"]
    filters = metadata["filters"]
    art = metadata["art"]
    char_offsets = metadata["charOffsets"]
    char_paths = metadata["charPaths"]

    if rarity >= len(rarities) or rarity >= len(filters):
        raise SystemExit(
            f"rarity {rarity} is not supported by metadata/FactoryNFT.json; choose a less rare address"
        )

    frame_index = rarity // 3 if rarity < 18 else 23 - rarity if rarity < 23 else 0
    description_index = last_char_val + 16 * (rarity // 8)

    svg = frames[frame_index]
    svg = svg.replace(
        "<!-- LABEL -->",
        _write_font(
            strategies[last_char_val],
            char_offsets,
            char_paths,
            _max_strategy_label_width(rarity),
        ),
    )
    svg = svg.replace("<!-- TEXT -->", descriptions[description_index])
    svg = svg.replace("<!-- ART -->", art[last_char_val])
    svg = svg.replace("<!-- FILTER -->", filters[rarity])
    svg = svg.replace("<!-- POOLADDRESS -->", pool_address.lower())
    svg = svg.replace("<!-- CHAINID -->", _chain_name(chain_id))
    svg = svg.replace(
        "<!-- RARITY_NAME -->",
        _write_font(rarities[rarity], char_offsets, char_paths, _max_rarity_label_width(rarity)),
    )
    svg = svg.replace("<!-- RARITY -->", _write_font(str(rarity), char_offsets, char_paths))
    svg = svg.replace(
        "<!-- SYMBOL0 -->",
        _write_font(symbol0, char_offsets, char_paths, _max_symbol_width(rarity)),
    )
    svg = svg.replace(
        "<!-- SYMBOL1 -->",
        _write_font(symbol1, char_offsets, char_paths, _max_symbol_width(rarity)),
    )

    return svg, rarity, last_char_val


def _construct_metadata_json(
    metadata: dict,
    pool_address: str,
    symbol0: str,
    symbol1: str,
    fee: int,
    chain_id: int,
    rarity: int,
    last_char_val: int,
    svg: str,
) -> str:
    strategies = metadata["strategies"]
    rarities = metadata["rarities"]

    name = f"{pool_address.lower()}-{strategies[last_char_val]}-{rarity}"
    description = f"Panoptic Pool for the {symbol0}-{symbol1}-{_uniswap_fee_to_string(fee)} market"
    rarity_value = f"{rarity} - {rarities[rarity]}"
    image_data_uri = "data:image/svg+xml;base64," + base64.b64encode(svg.encode()).decode()

    return (
        "{"
        f'"name":{json.dumps(name)}, '
        f'"description":{json.dumps(description)}, '
        '"attributes": ['
        f'{{"trait_type": "Rarity", "value": {json.dumps(rarity_value)}}}, '
        f'{{"trait_type": "Strategy", "value": {json.dumps(strategies[last_char_val])}}}, '
        f'{{"trait_type": "ChainId", "value": {json.dumps(_chain_name(chain_id))}}}'
        "], "
        f'"image": {json.dumps(image_data_uri)}'
        "}"
    )


def _preview_html(pool_address: str, chain_id: int) -> str:
    return f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Panoptic NFT Preview</title>
  <style>
    body {{
      font-family: ui-sans-serif, system-ui, sans-serif;
      background: #111;
      color: #f5f5f5;
      margin: 0;
      padding: 32px;
    }}
    main {{ max-width: 960px; margin: 0 auto; }}
    img {{
      display: block;
      max-width: 100%;
      height: auto;
      background: #fff;
      border-radius: 16px;
      box-shadow: 0 24px 80px rgba(0, 0, 0, 0.35);
    }}
    a {{ color: #7dd3fc; }}
    code {{ background: #1f2937; padding: 2px 6px; border-radius: 6px; }}
  </style>
</head>
<body>
  <main>
    <h1>Panoptic NFT Preview</h1>
    <p>Pool: <code>{escape(pool_address.lower())}</code></p>
    <p>Chain ID: <code>{chain_id}</code></p>
    <p>Open <code>image.svg</code> directly or use the links below.</p>
    <p><img src="./image.svg" alt="Panoptic NFT preview"></p>
    <ul>
      <li><a href="./image.svg">image.svg</a></li>
      <li><a href="./metadata.json">metadata.json</a></li>
      <li><a href="./token-uri.txt">token-uri.txt</a></li>
    </ul>
  </main>
</body>
</html>
"""


def main() -> None:
    args = _parse_args()
    pool_address = _pool_address(args)
    out_dir = args.out_dir or _default_out_dir(pool_address, args)

    factory_nft = json.loads(Path("metadata/FactoryNFT.json").read_text())["metadata"]
    svg, rarity, last_char_val = _render_svg(
        factory_nft, pool_address, args.symbol0, args.symbol1, args.fee, args.chain_id
    )
    metadata_json = _construct_metadata_json(
        factory_nft,
        pool_address,
        args.symbol0,
        args.symbol1,
        args.fee,
        args.chain_id,
        rarity,
        last_char_val,
        svg,
    )
    token_uri = (
        "data:application/json;base64,"
        + base64.b64encode(metadata_json.encode()).decode()
    )

    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "image.svg").write_text(svg)
    (out_dir / "metadata.json").write_text(metadata_json)
    (out_dir / "token-uri.txt").write_text(token_uri)
    (out_dir / "preview.html").write_text(_preview_html(pool_address, args.chain_id))

    print(f"Preview written to {out_dir}")
    print(f"Open {out_dir / 'preview.html'} or {out_dir / 'image.svg'}")


if __name__ == "__main__":
    main()
