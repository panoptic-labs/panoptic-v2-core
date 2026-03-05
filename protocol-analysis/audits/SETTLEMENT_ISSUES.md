# Settlement Issues To Fix (`_settleOptions` Paths)

This file summarizes issues found around settlement via:

- `dispatch(...)` (self)
- `dispatchFrom(...) -> _settlePremium(...)` (self/others)

## 1) Forced Fee Amplification via Repeated Third-Party Settlement

- **Where:** `dispatchFrom` settle branch on another account.
- **Issue:** A third party can repeatedly force tiny settlements; premium fee is rounded up per call, so splitting settlement across many calls increases effective total fees paid by victim.
- **Risk:** Economic grief/value extraction from victim (`Objective i` + liveness grief `Objective iii`).
- **Simple mitigation:**
  - Make premium-fee charging frequency-invariant (accumulate fee basis and charge once per position/account window).
  - Add a minimum settle amount threshold before charging fee.
  - Optionally add cooldown/rate limit for third-party settle on same position.

## 2) Gross-Only Third-Party Settlement (No Short Credit in Same Call)

- **Where:** `dispatchFrom -> _settlePremium -> _settleOptions` when caller is not owner.
- **Issue:** Third-party settlement path settles long-side payment without concurrently realizing short-side inflow for the target position in that call path.
- **Risk:** Boundary solvency/liveness grief near insolvency (txs can be forced into revert conditions; no persistent insolvency bypass due final solvency checks) (`Objective iii`).
- **Simple mitigation:**
  - For third-party settle, net long/short premia atomically for the selected position.
  - Or enforce max settle delta per call to reduce one-shot collateral pressure.

## 3) Caller-Directed Position Targeting in `dispatchFrom`

- **Where:** `dispatchFrom` chooses `tokenId = positionIdListTo[toLength - 1]`.
- **Issue:** Caller can reorder a valid position list and repeatedly target a specific victim position.
- **Risk:** Strategic griefing / selective extraction pressure (`Objective iii`, can support `Objective i` when combined with fee rounding).
- **Simple mitigation:**
  - Require canonical ordering of `positionIdListTo` (e.g., sorted ascending tokenId) and verify it on-chain.
  - Or pass explicit `tokenId` and validate inclusion + policy constraints.

## 4) Dust Premium Clipping from Floor Rounding + Snapshot Advance

- **Where:** Premium computation floors on `/ 2**64`, while settlement snapshot can still advance even when computed premium is zero.
- **Issue:** Frequent settlement can drop sub-unit premium repeatedly.
- **Risk:** Small premium evasion over many calls (`Objective i`), usually low per event but accumulative.
- **Simple mitigation:**
  - Track per-leg remainder carry (fixed-point dust bucket) and roll it into next settlement.
  - Alternatively enforce a minimum delta before allowing snapshot advancement.

## 5) `dispatchFrom` Stale Oracle Gate Can Be Used for Strategic Settlement DoS

- **Where:** `dispatchFrom` checks `abs(currentTick - twapTick)` against limit.
- **Issue:** Under active price manipulation windows, legitimate settle calls can be forced to revert.
- **Risk:** Temporary strategic DoS (`Objective iii`), not permanent.
- **Simple mitigation:**
  - Add fallback settlement mode under stale conditions (reduced-size settle or alternate tick policy).
  - Keep current strict mode for liquidation/exercise but relax for pure premium settlement.

## 6) Refund Conversion Rounding-Up Bias (Hardening)

- **Where:** `dispatchFrom` refund path through `riskEngine.getRefundAmounts`.
- **Issue:** Conversion helpers use rounding-up in shortage substitution paths; small but systematic rounding bias is possible.
- **Risk:** Minor extraction/grief in edge conditions (`Objective i`/`iii`, low confidence, hardening item).
- **Simple mitigation:**
  - Add bounded rounding-loss assertions per settlement.
  - Track cumulative rounding debt/credit and settle it explicitly.

---

## Minimal Implementation Priority

1. Fix forced fee amplification (Issue 1).
2. Fix/contain gross-only third-party settle behavior (Issue 2).
3. Enforce canonical list ordering or explicit target policy (Issue 3).
4. Add dust carry accumulator (Issue 4).
