# Interest Rate Model (IRM) Stability Audit

**Date**: 2026-03-03
**Scope**: `contracts/` only — RiskEngine.sol, CollateralTracker.sol, Math.sol, MarketState.sol
**Adversary Model**: Full MEV attacker, multi-account, can manipulate pool utilization

---

## A) Rate Manipulation Analysis

### A.1 Utilization Toggle Attack — Asymmetric Error Normalization Drift

**Error normalization asymmetry:**

The error normalization factor differs above and below target:

- Above target: `errNormFactor = WAD - TARGET = WAD/3 ≈ 3.33e17`
- Below target: `errNormFactor = TARGET = 2WAD/3 ≈ 6.67e17`

For symmetric utilization oscillation of ±ε around `TARGET_UTILIZATION`:

| Direction    | Utilization | Normalized Error                      |
| ------------ | ----------- | ------------------------------------- |
| Above target | TARGET + ε  | `err = ε × WAD / (WAD/3) = +3ε`       |
| Below target | TARGET − ε  | `err = (−ε) × WAD / (2WAD/3) = −1.5ε` |

The normalized errors are **not symmetric**: `|+3ε| ≠ |−1.5ε|`. The net per cycle is `+1.5ε`.

**Numerical example** (ε = 0.1 WAD, dt = 4s per half-cycle):

```
ADJUSTMENT_SPEED = 1,585,489,599,188 (WAD-scaled, per second)

Above target:
  speed = wMulToZero(1,585,489,599,188, 3×0.1e18) = 475,646,879,756
  linearAdaptation_up = 475,646,879,756 × 4 = 1,902,587,519,024

Below target:
  speed = wMulToZero(1,585,489,599,188, −1.5×0.1e18) = −237,823,439,878
  linearAdaptation_down = −237,823,439,878 × 4 = −951,293,759,512

Net exponent per cycle = 1,902,587,519,024 − 951,293,759,512 = 951,293,759,512
In natural units: 951,293,759,512 / 1e18 ≈ 9.51×10⁻⁷

Per day (10,800 cycles): exp(9.51e-7 × 10800) = exp(0.01027) ≈ 1.0103 (+1.03%/day)
Per year: exp(0.01027 × 365) ≈ 42.5× increase
```

**Is this exploitable?** No. Each cycle requires opening AND closing a position of sufficient size to swing utilization by 10%. At `NOTIONAL_FEE = 1 bps`:

```
Fee per cycle = 2 × 0.01% × notional ≈ $200 (for $1M notional)
Fee per day = $200 × 10,800 = $2.16M
```

The fee cost vastly exceeds any interest rate manipulation profit. The asymmetry is also **by design** in Morpho-style adaptive IRMs — rates respond more aggressively to high utilization to protect PLPs.

**Conclusion**: Mathematically real drift (+1.03%/day for 10% swing), economically non-exploitable due to notional fees.

---

### A.2 Rate Pumping for Profit

**Attack model**: Account A (large PLP deposit D), Account B (opens shorts of notional X to spike utilization).

**Break-even analysis**:

```
Attacker income (A as PLP):  rate × assetsInAMM × (D / totalAssets)
Attacker cost (B as borrower): rate × X × (B's share of borrows)

For net profit: D × utilization > X  →  D > X / utilization
```

Additional constraints:

1. **ADJUSTMENT_SPEED = 50/year**: Per-epoch rate adjustment via `rateAtTarget` is minuscule. At max error, `rateAtTarget` changes by `wExp(2.6e16) ≈ 1.0263 per 4.5-hour window` — about 2.6% per 4.5h.
2. **Sigmoid is instantaneous but bounded**: `_curve` provides immediate 0.25×–4× multiplier on `rateAtTarget`, but this is already reflected in the existing rate.
3. **Attacker pays interest on own borrows**: Account B's interest cost offsets Account A's yield.
4. **Notional fees**: Opening/closing positions costs 1 bps of notional each way.

**Capital efficiency**: To increase the rate by Δr for third-party borrows B_other:

```
Profit ≈ Δr × B_other × D/totalAssets − r_new × X
```

This requires `D >> X` and `B_other >> X`, meaning the pool must have substantial third-party borrows for the attacker to extract meaningful value. The attacker's own interest cost and fee expenditure dominate.

**Conclusion**: Theoretically possible, practically unviable. Capital-inefficient; fees and own-interest costs exceed marginal income.

---

### A.3 Rate Suppression

**Attack model**: Attacker is a large borrower. Deposits heavily from second account to lower utilization.

**Analysis**: Self-defeating. The attacker's deposit:

1. Lowers utilization → lowers rate → reduces attacker's interest cost
2. But the deposit also earns PLP yield at the (now lower) rate
3. Capital locked as deposit has opportunity cost

**Maximum immediate rate reduction** (pushing utilization to 0):

```
At utilization=0, err=-1 WAD:
  _curve(rateAtTarget, -1) = 0.25 × rateAtTarget (75% reduction)
```

But this requires depositing enough to make utilization ≈ 0, i.e., deposit > totalAssets. Capital locked ≈ pool TVL.

**Temporal component**: `rateAtTarget` decreases at ADJUSTMENT_SPEED. Per 4.5-hour window with err=−1:

```
rateAtTarget *= wExp(−2.6e16) ≈ 0.974  (−2.6% per window)
```

To halve rateAtTarget: `ln(0.5) / ln(0.974) ≈ 26 windows ≈ 5 days`

**Capital efficiency**: Deposit $X to save `(r_old − r_new) × borrows / year`. At moderate pool sizes, the savings are a fraction of the locked capital per year. Strictly less efficient than simply repaying debt.

**Conclusion**: Not exploitable. Self-defeating economics; direct debt repayment is always more capital-efficient.

---

### A.4 Rate Sniping via Epoch Timing

**Key mitigation**: `IRM_MAX_ELAPSED_TIME = 16384 seconds (≈ 4.5 hours)` at RE:92.

```solidity
int256 elapsed = Math.min(
    int256(epochTime) - int256(previousTime),
    IRM_MAX_ELAPSED_TIME
);
```

**Maximum single-step rate adjustment** (max error, max elapsed):

```
linearAdaptation = ADJUSTMENT_SPEED × 16384 = 1,585,489,599,188 × 16384 = 25,967,861,934,899,200
In WAD: 2.60e16 / 1e18 = 0.026

wExp(2.60e16) ≈ 1.0263 WAD  →  +2.63% adjustment
wExp(−2.60e16) ≈ 0.974 WAD  →  −2.57% adjustment
```

The cap effectively bounds the rate sniping attack. Even if a pool is idle for days, the rate adjustment treats only 4.5 hours as elapsed.

**Interest vs. rate adjustment timing**: `_calculateCurrentInterestState` uses the full `deltaTime` (not capped) for interest compounding (CT:1010), but uses the capped average rate from `_borrowRate`. For stale pools where `deltaTime >> 16384`:

- Rate adjustment: capped at 4.5 hours → moderate rateAtTarget change
- Interest compounding: uses avgRate × fullDeltaTime

This means the average rate used for compounding is the rate averaged over only the first 4.5 hours, but applied for the full idle period. For rising rates (high utilization), this **underestimates** interest since the rate would have continued rising beyond 4.5h. This mildly favors borrowers.

**Conclusion**: Rate sniping is effectively mitigated. Max single-step adjustment capped at ≈2.6%.

---

## B) Mathematical Precision Analysis

### B.1 wTaylorCompounded (Math:1227)

```solidity
function wTaylorCompounded(uint256 x, uint256 n) internal pure returns (uint256) {
  uint256 firstTerm = x * n;
  uint256 secondTerm = mulDiv(firstTerm, firstTerm, 2 * WAD);
  uint256 thirdTerm = mulDiv(secondTerm, firstTerm, 3 * WAD);
  return firstTerm + secondTerm + thirdTerm;
}
```

Approximates `e^(x×n) − 1` via 3-term Taylor: `z + z²/2 + z³/6` where `z = x × n`.

**Truncation error**: The omitted 4th term is `z⁴/24`. Relative error ≈ `z³/24`.

| z (natural units) | Relative Error | Scenario               |
| ----------------- | -------------- | ---------------------- |
| 0.001             | 4.2×10⁻¹¹      | Max rate, 1 epoch (4s) |
| 0.022             | 4.4×10⁻⁷       | Max rate, 1 day        |
| 0.134             | 1×10⁻⁴ (1 bps) | Threshold              |
| 0.153             | 1.5×10⁻⁴       | Max rate, 1 week       |
| 0.621             | 1×10⁻² (1%)    | Threshold              |
| 0.657             | 1.2×10⁻²       | Max rate, 1 month      |
| 2.0               | 0.33 (33%)     | Max rate, 3 months     |
| 8.0               | 21.3 (2,133%)  | Max rate, 1 year       |

**Maximum rate per second** (at MAX_RATE_AT_TARGET, 100% utilization):

```
max_rate = 4 × MAX_RATE_AT_TARGET = 4 × 63,419,583,967 = 253,678,335,868

z per epoch  = 253,678,335,868 × 4 = 1.01e12  → z/WAD = 1.01e-6   ✓ exact
z per day    = 253,678,335,868 × 86,400 = 2.19e16  → z/WAD = 0.022   ✓ < 1bps error
z per week   = 253,678,335,868 × 604,800 = 1.53e17  → z/WAD = 0.153   ✓ < 2bps error
z per month  = 253,678,335,868 × 2,592,000 = 6.57e17  → z/WAD = 0.657   ⚠ ~1.2% error
z per year   = 253,678,335,868 × 31,536,000 = 8.0e18  → z/WAD = 8.0     ✗ 2133% error
```

**Direction of error**: wTaylorCompounded always **underestimates** (truncates positive higher-order terms), but the outer `mulDivWadRoundingUp` in `_calculateCurrentInterestState` (CT:1020) partially counteracts by rounding interest upward. Net direction: slight underestimate for large z, effectively neutral for small z.

**Practical impact**: For normal operation (accruals at least weekly), error < 2 bps. For stale pools uninteracted for >1 month at max rate, error exceeds 1%. This is a theoretical concern since high-utilization pools are unlikely to remain idle for months.

---

### B.2 wExp (Math:1269)

```solidity
function wExp(int256 x) internal pure returns (int256) {
  if (x < LN_WEI_INT) return 0; // -41.45 WAD
  if (x >= WEXP_UPPER_BOUND) return WEXP_UPPER_VALUE; // 93.86 WAD → ~5.77e40 WAD
  int256 q = (x + roundingAdjustment) / LN_2_INT;
  int256 r = x - q * LN_2_INT;
  int256 expR = WAD_INT + r + (r * r) / WAD_INT / 2; // 2nd-order Taylor
  if (q >= 0) return expR << uint256(q);
  else return expR >> uint256(-q);
}
```

**Input range** in `_newRateAtTarget`:

```
linearAdaptation = speed × elapsed
  where speed = wMulToZero(ADJUSTMENT_SPEED, err), |err| ≤ 1 WAD
        elapsed ≤ IRM_MAX_ELAPSED_TIME = 16384

Max |linearAdaptation| = ADJUSTMENT_SPEED × 16384 = 2.60e16

In WAD: ±0.026 — well within bounds (LN_WEI_INT = -41.45 WAD, WEXP_UPPER_BOUND = 93.86 WAD)
```

**Precision at max input**: After decomposition, `q=0, r=±2.6e16`:

```
expR = 1e18 + 2.6e16 + (2.6e16)² / 2e18 = 1e18 + 2.6e16 + 338 ≈ 1.026e18
True exp(0.026) = 1.02634e18
Relative error: 0.033% — negligible.
```

**Can wExp return 0?** Only if `x < LN_WEI_INT = -41.45e18`. Max negative input is `-2.6e16`, which is vastly above this threshold. **rateAtTarget can never be driven to 0 via wExp**.

**Can wExp overflow?** Clipped to `WEXP_UPPER_VALUE` at inputs ≥ 93.86 WAD. Max input is 0.026 WAD. No overflow possible.

**Clamping interaction**: After `wExp`, `_newRateAtTarget` clamps to `[MIN_RATE_AT_TARGET, MAX_RATE_AT_TARGET]`. Since wExp's output is always positive and bounded, and the subsequent `wMulToZero` with a positive `startRateAtTarget` always returns non-negative, the clamp operates correctly.

**Conclusion**: wExp is safe and sufficiently precise for all inputs within the IRM's operating range.

---

### B.3 Rate Averaging Approximation

The code uses **composite trapezoidal rule with N=2** (not simple trapezoid):

```solidity
// RE:2252-2259
endRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation);
midRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation / 2);
avgRateAtTarget = (startRateAtTarget + endRateAtTarget + 2 * midRateAtTarget) / 4;
```

This approximates:

```
avgRateAtTarget ≈ (f(0) + 2f(T/2) + f(T)) / 4
```

where `f(t) = startRateAtTarget × exp(speed×err×t)`.

**Error direction**: The exponential function `exp(ct)` is always convex (regardless of sign of c). For convex functions, the trapezoidal rule **overestimates** the integral. This means:

- `avgRateAtTarget` is slightly **too high**
- Interest is slightly **overcharged**
- **Favors PLPs** (lenders) over borrowers

**Error magnitude** at max adjustment (c = 0.026):

```
True average (normalized):  (exp(0.026) − 1) / 0.026 = 1.01311
Trap average (normalized):  (1 + 2×exp(0.013) + exp(0.026)) / 4 = 1.01313
Relative error: (1.01313 − 1.01311) / 1.01311 ≈ +0.002%
```

Less than 1 bps per 4.5-hour window. Negligible.

**Conclusion**: Systematic overestimate of ≈0.002% per update, favoring PLPs. Practically immaterial.

---

### B.4 38-bit rateAtTarget Precision

**Storage bounds**:

```
38-bit max: 2³⁸ − 1 = 274,877,906,943
MAX_RATE_AT_TARGET ≈ 63,419,583,967  → 36 bits (headroom: 2 bits)
MIN_RATE_AT_TARGET ≈ 31,709,791      → 25 bits (headroom: 13 bits)
```

**Quantization step**: At any value V, the quantization step is 1 (the integer itself). The fractional precision depends on V.

**Smallest detectable adjustment at MIN_RATE_AT_TARGET**:

For `wMulToZero(rateAtTarget, wExp(x))` to differ from `rateAtTarget`:

```
rateAtTarget × (wExp(x) − WAD) / WAD ≥ 1
Δ = wExp(x) − WAD ≥ WAD / rateAtTarget

At MIN: Δ ≥ 1e18 / 31,709,791 ≈ 31,536,001
→ wExp(x) ≥ WAD + 31,536,001
→ x ≈ 31,536,001 (since wExp(x) ≈ WAD + x for small x)
→ linearAdaptation ≈ 31,536,001
→ speed ≈ 7,884,000 per second
→ err ≈ 7,884,000 × WAD / ADJUSTMENT_SPEED ≈ 4.97e9
→ normalized error ≈ 5e-9 WAD ≈ 0.0000005%
```

An error of 5×10⁻⁷ % is trivially detectable. The 38-bit precision does not cause any "stuck at MIN" condition.

**Conclusion**: 38-bit storage provides adequate precision. No quantization-induced stalling.

---

## C) Edge Case Analysis

### C.1 First Interaction (Pool Initialization)

At initialization (CT:299):

```solidity
s_marketState = MarketStateLibrary.storeMarketState(WAD, block.timestamp >> 2, 0, 0);
```

- `borrowIndex = WAD = 1e18`
- `rateAtTarget = 0` (sentinel for "first interaction")
- When `startRateAtTarget == 0`, `_borrowRate` returns `INITIAL_RATE_AT_TARGET` directly (RE:2216-2219)

**deltaTime = 0 (same epoch)**: `_calculateCurrentInterestState` returns early at CT:1014 check. No interest. Correct.

**Large deltaTime (pool idle for days after init)**:

- Rate adjustment: `startRateAtTarget = 0 → INITIAL_RATE_AT_TARGET` directly (no exponential adjustment)
- Interest compounding: `wTaylorCompounded(INITIAL_RATE × fullDeltaTime)` for the full period
- If no positions exist: `_assetsInAMM = 0 → interestOwed = 0`. No issue.
- If positions exist: interest accrues at INITIAL_RATE for the full delay. This is correct — the rate is INITIAL by definition until someone triggers an update.

**Conclusion**: No edge case issues. First interaction handled correctly via the `startRateAtTarget == 0` sentinel.

---

### C.2 Zero Utilization Recovery

At zero utilization, the rate decreases maximally:

```
err = (0 − TARGET) / TARGET = −1 WAD
speed = ADJUSTMENT_SPEED × (−1) = −1,585,489,599,188
linearAdaptation (4.5h) = −25,967,861,934,899,200
wExp(−2.60e16) ≈ 0.974 WAD

rateAtTarget decreases by ≈2.6% per 4.5-hour window.
```

**Time to reach MIN from INITIAL** (periodic interactions every 4.5h):

```
ln(MIN/INITIAL) / ln(0.974) = ln(31,709,791 / 1,268,391,679) / ln(0.974)
= ln(0.025) / (−0.0263) = (−3.689) / (−0.0263) ≈ 140 windows ≈ 26 days
```

**Recovery from MIN to INITIAL** (utilization at 100%):

```
wExp(+2.60e16) ≈ 1.0263 per window
ln(INITIAL/MIN) / ln(1.0263) = ln(40) / 0.026 ≈ 142 windows ≈ 26 days
```

**Recovery from MIN to MAX**: `ln(MAX/MIN) / 0.026 ≈ 293 windows ≈ 55 days`

**During recovery at MIN, effective rate at 100% utilization**:

```
rate = 4 × MIN_RATE_AT_TARGET = 4 × 0.001/year = 0.4% APR
```

This is very low for a fully utilized pool. Borrowers would enjoy below-market rates for weeks during recovery. This is a design trade-off inherent to the Morpho adaptive IRM — slow adjustment prevents manipulation but causes sluggish recovery.

**Conclusion**: Recovery from MIN takes ≈26 days to reach INITIAL. Prolonged underpricing is possible but is a known characteristic of the adaptive IRM design.

---

### C.3 100% Utilization

**Can utilization exceed WAD?** `_poolUtilizationWadView` (CT:1209):

```solidity
Math.mulDivRoundingUp(
    uint256(s_assetsInAMM) + uint256(s_marketState.unrealizedInterest()),
    WAD,
    totalAssets()
)
```

Since `totalAssets = s_depositedAssets + s_assetsInAMM + unrealizedInterest`, if `s_depositedAssets = 0`, the numerator equals the denominator and the result is exactly WAD. With `mulDivRoundingUp`, it could be WAD+1 due to rounding. This yields `err` slightly above +1 WAD — dust-level, no meaningful impact on the curve output.

**wExp at sustained 100% utilization**: Already analyzed in B.2. Max input `2.6e16` is well within bounds.

**wTaylorCompounded at 100% utilization**: At max effective rate (800% APR), per-day z = 0.022 WAD. Excellent Taylor accuracy for normal interaction frequencies.

**Conclusion**: 100% utilization is handled safely. Marginal rounding above WAD is inconsequential.

---

### C.4 borrowIndex Overflow

`borrowIndex` is stored as 80 bits (max `2⁸⁰ ≈ 1.209e24`), starts at `WAD = 1e18`.

**Time to overflow**:

```
Ratio needed: 2⁸⁰ / WAD = 1,208,925
At 800% APR (continuous): t = ln(1,208,925) / 8 = 14.0 / 8 = 1.75 years
At 200% APR: t = 14.0 / 2 = 7 years
At 100% APR: t = 14.0 years
At  50% APR: t = 28 years
At  10% APR: t = 140 years
```

**What happens on overflow**: `storeMarketState` (MarketState:59) does **not mask** `_borrowIndex` to 80 bits:

```solidity
assembly {
    result := add(
        add(add(_borrowIndex, shl(80, _marketEpoch)), shl(112, _rateAtTarget)),
        shl(150, _unrealizedInterest)
    )
}
```

If `currentBorrowIndex > 2⁸⁰`, excess bits overflow into `marketEpoch` via `add`. The stored borrowIndex wraps to its lower 80 bits (potentially 0).

**Cascade of effects**:

1. `borrowIndex()` reads lower 80 bits → could read 0 or wrapped value
2. Next `_getUserInterest`: `currentBorrowIndex - userBorrowIndex` underflows (checked arithmetic) → **revert**
3. Any call to `_accrueInterest` reverts → **permanent pool DoS**

**Existing mitigation**: None explicit. The `toUint128()` at CT:1030 only catches values > 2¹²⁸ (not > 2⁸⁰). The comment in MarketState acknowledges the limitation: "2\*\*80 = 1.75 years at 800% interest".

**Practical reachability**: 800% sustained APR for 1.75 years is extreme — such a pool would have been effectively abandoned long before (borrowers paying 800% interest would be liquidated). At 100% APR, it takes 14 years. At moderate rates (20-50% APR), 28-70 years — beyond reasonable pool lifetime.

**Conclusion**: Silent storage corruption of adjacent fields when borrowIndex exceeds 80 bits. Ultimately causes permanent pool DoS via checked arithmetic revert. Reachable only under sustained extreme rates (1.75 years at 800% APR). Known limitation per comment.

---

### C.5 Interest Accrual Gap — Front-running

**Question**: Can an attacker deposit before a large accrual to capture interest?

**Answer**: No. All user-facing functions call `_accrueInterest` before processing the user action:

- `deposit()` → `_accrueInterest()` at CT:403
- `withdraw()` → `_accrueInterest()` at CT:713
- `transfer()` → `_accrueInterest()` at CT:423

The attacker's deposit triggers accrual first, updating `unrealizedGlobalInterest` in `s_marketState`. Then `totalAssets()` reflects the accrued interest, and the share price incorporates it. The attacker's shares are priced **after** accrual — they cannot capture pre-existing unrealized interest.

**Transient storage protection** (CT:1183): `_poolUtilizationWad()` uses `tload/tstore` to track the maximum utilization within a transaction, preventing flash-deposit manipulation of the interest rate within a single tx.

**Conclusion**: Not exploitable. Accrual always occurs before share minting. Gas cost burden on first interactor is a UX issue, not a security issue.

---

### C.6 Negative Effective Rate

**Curve function** (RE:2272):

```
if err < 0:  coeff = WAD − WAD/CURVE_STEEPNESS = 1e18 − 0.25e18 = 0.75e18
             rate = (0.75×err + 1) × rateAtTarget
if err ≥ 0:  coeff = CURVE_STEEPNESS − WAD = 3e18
             rate = (3×err + 1) × rateAtTarget
```

**At minimum (err = −1 WAD)**:

```
rate = (0.75 × (−1) + 1) × rateAtTarget = 0.25 × rateAtTarget
```

Since `rateAtTarget ≥ MIN_RATE_AT_TARGET > 0`, the rate is always positive:

```
min absolute rate = 0.25 × MIN_RATE_AT_TARGET ≈ 0.25 × 31,709,791 ≈ 7,927,448 > 0
```

**WAD arithmetic verification**: `wMulToZero` rounds toward zero. For the negative intermediate `coeff × err`:

- `wMulToZero(0.75e18, −1e18) = −7.5e35 / 1e18 = −7.5e17` (exact, no rounding)
- `−7.5e17 + 1e18 = 2.5e17 > 0`
- `wMulToZero(2.5e17, rateAtTarget) = 2.5e17 × rateAtTarget / 1e18 ≥ 0`

For intermediate errors, the expression `coeff × err + WAD` is minimized at `err = −1`:

- `0.75 × (−1) + 1 = 0.25 > 0` ✓

**Conclusion**: Rate is always strictly positive. Verified in both mathematical and WAD-arithmetic terms.

---

## D) Feedback Loop Analysis

### D.1 Rate → Utilization → Rate

```
High rate → borrowers close positions → utilization ↓ → rate ↓ → new borrowers enter →
utilization ↑ → rate ↑ → equilibrium
```

**Stability**: **Stable** (negative feedback). Higher rates discourage borrowing, which lowers utilization, which lowers rates.

**Time constant**: The rate adjusts at `ADJUSTMENT_SPEED = 50/year`. The characteristic time for rate adjustment is `1/50 year ≈ 7.3 days`. With the IRM_MAX_ELAPSED_TIME cap, each discrete step adjusts by at most 2.6%, giving a half-life of:

```
ln(2) / 0.0263 ≈ 26 windows ≈ 5 days
```

**Can it diverge?** No. The damping is inherent:

- Exponential rate adjustment means the absolute change decreases as rate approaches the bound
- MIN/MAX clamps prevent runaway
- The 4.5-hour cap prevents discrete-time instability (no single step can cause > 2.6% change)
- ADJUSTMENT_SPEED of 50/year is well below the Nyquist limit for epoch-level sampling

---

### D.2 Rate → Solvency → Liquidation → Utilization → Rate

```
High rate → interest erodes collateral → insolvency → liquidation →
positions closed → utilization ↓ → rate ↓ → stabilizes
```

**Stability**: **Stable** (self-correcting cascade).

Liquidation removes the most leveraged positions first, reducing outstanding borrows and utilization. The rate decrease protects remaining positions.

**Time constant**: Depends on external factors (liquidator behavior). The protocol component (rate adjustment) has the same 5-day half-life. The liquidation component depends on liquidator bot latency (typically seconds to minutes).

**Worst case (death spiral)**: If ALL borrowers become simultaneously insolvent, mass liquidation closes all positions, utilization drops to 0, rate drops to MIN. The pool loses depositor value due to unpaid interest (handled by the insolvency mechanism at CT:932-949). This is an extreme market event, not a protocol instability.

**Conclusion**: Self-limiting. Liquidation acts as a natural circuit breaker.

---

### D.3 Rate → PLP Deposits/Withdrawals → Utilization → Rate

```
High rate → attractive yield → PLPs deposit → utilization ↓ → rate ↓
Low rate → unattractive yield → PLPs withdraw → utilization ↑ → rate ↑
```

**Stability**: **Stable** (negative feedback). Market-driven equilibrium.

**Time constant**: Dominated by human/bot PLP behavior (external). Rate mechanism component: same 5-day half-life.

**Parameter sensitivity**: If `ADJUSTMENT_SPEED` were much higher (e.g., 500/year), rates could overshoot, causing oscillation in PLP behavior. At 50/year, per-epoch changes are so small (< 0.001%) that overshooting is impossible.

---

### D.4 Combined Loop Stability Summary

| Loop                      | Type              | Stability | Time Constant | Risk                   |
| ------------------------- | ----------------- | --------- | ------------- | ---------------------- |
| Rate–Utilization          | Negative feedback | Stable    | ~5 days       | None                   |
| Rate–Solvency–Liquidation | Self-correcting   | Stable    | Hours–days    | Death spiral (extreme) |
| Rate–PLP–Deposit          | Negative feedback | Stable    | Days–weeks    | None                   |

All loops are stable under the current parameter set. `ADJUSTMENT_SPEED = 50/year` provides appropriate responsiveness without risk of oscillatory instability.

---

## E) Findings

### IRM-001: Asymmetric Error Normalization Causes Upward rateAtTarget Drift

- **Severity**: Informational
- **Category**: manipulation
- **Description**: The error normalization factor is `WAD/3` above target vs `2WAD/3` below target. For symmetric utilization oscillation ±ε around target, the net normalized error per cycle is `+1.5ε`, causing rateAtTarget to drift upward multiplicatively by `exp(ADJUSTMENT_SPEED × 1.5ε × dt / WAD)` per cycle.
- **Numerical example**: At ε=0.1 WAD, drift = +1.03%/day or ~42× per year.
- **Affected parties**: Borrowers pay slightly more if utilization oscillates symmetrically.
- **Impact magnitude**: Economically non-exploitable due to notional fees ($2.16M/day for 10% swing). The asymmetry is by design in Morpho-style adaptive IRMs.
- **Existing mitigations**: Notional fees make artificial toggling prohibitively expensive.

### IRM-002: wTaylorCompounded Precision Degradation for Stale Pools

- **Severity**: Low
- **Category**: precision
- **Description**: `wTaylorCompounded` (Math:1227) uses a 3-term Taylor series for `e^z − 1`. Relative error ≈ `z³/24`, which exceeds 1% when `z = rate × deltaTime > 0.62 WAD`. At max rate (800% APR) this corresponds to ≈1 month of continuous non-interaction.
- **Numerical example**: 3 months at 800% APR: `z = 2 WAD`, Taylor gives 5.33, true = 6.39. **16.6% underestimate**.
- **Affected parties**: PLPs receive less interest than mathematically owed for very stale high-rate pools.
- **Impact magnitude**: Low — requires extreme scenario (max rate + months without interaction). Normal pools with weekly interactions have <2 bps error.
- **Existing mitigations**: Any user interaction triggers accrual, resetting deltaTime.

### IRM-003: borrowIndex 80-bit Overflow Causes Silent Storage Corruption and Pool DoS

- **Severity**: Low
- **Category**: overflow / edge-case
- **Description**: `borrowIndex` is stored as 80 bits in `MarketState`. `storeMarketState` (MarketState:59) does not mask `_borrowIndex` to 80 bits, using `add` instead of `or` with masking. When the index exceeds `2⁸⁰`, excess bits overflow into the `marketEpoch` field. On the next read, `borrowIndex()` returns the truncated lower 80 bits. If the truncated value < a user's stored `userBorrowIndex`, the checked subtraction in `_getUserInterest` (CT:1084) reverts, permanently DoS'ing the pool.
- **Numerical example**: At 800% APR sustained, overflow occurs after ≈1.75 years. At 100% APR, after ≈14 years.
- **Affected parties**: All pool users — the pool becomes permanently unusable.
- **Impact magnitude**: Catastrophic if triggered, but requires sustained extreme rates for >1.75 years. Acknowledged in MarketState comments.
- **Existing mitigations**: `toUint128()` prevents values > 2¹²⁸ but not > 2⁸⁰. No explicit 80-bit check.

### IRM-004: Trapezoidal Rate Averaging Overestimates Interest

- **Severity**: Informational
- **Category**: precision
- **Description**: The composite trapezoidal rule (N=2) at RE:2257-2259 overestimates the integral of the convex exponential `rateAtTarget` path. This causes `avgRateAtTarget` to be slightly too high, overcharging interest.
- **Numerical example**: At max adjustment (c=0.026), overestimate = +0.002% (< 1 bps).
- **Affected parties**: Borrowers pay marginally more, PLPs receive marginally more.
- **Impact magnitude**: Negligible — less than 1 bps per update window.
- **Existing mitigations**: None needed; error is immaterial.

### IRM-005: Slow Recovery from MIN_RATE_AT_TARGET

- **Severity**: Informational
- **Category**: edge-case / instability
- **Description**: After extended zero-utilization periods, `rateAtTarget` decays to `MIN_RATE_AT_TARGET` (0.1% APR). Recovery to `INITIAL_RATE_AT_TARGET` (4% APR) requires ≈26 days at maximum upward adjustment speed. During recovery at 100% utilization, the effective rate is only ≈0.4% APR — severely underpriced.
- **Numerical example**: Pool idle for 26+ days → rateAtTarget reaches MIN. Fully utilized afterward: effective rate = 4 × MIN = 0.4% APR for the first day, increasing by 2.6% per 4.5-hour window.
- **Affected parties**: PLPs earn below-market returns during recovery; borrowers get subsidized rates.
- **Impact magnitude**: Low in practice — pools transitioning from zero to full utilization are rare, and the rate recovers continuously.
- **Existing mitigations**: By design in Morpho-style IRM. Slow adjustment prevents manipulation at the cost of sluggish recovery.

### IRM-006: IRM Rate Adjustment Underestimates Interest for Stale Pools

- **Severity**: Informational
- **Category**: precision / edge-case
- **Description**: `IRM_MAX_ELAPSED_TIME` (16384s) caps rate adjustment time but not interest compounding time. For idle periods > 4.5h at non-target utilization, the average rate used for compounding reflects only the first 4.5h of rate evolution, while interest compounds for the full period. For rising rates (high utilization), this systematically underestimates total interest.
- **Numerical example**: Pool idle 24h at 100% utilization. Rate adjustment uses 4.5h avg, but interest compounds for 24h. The remaining 19.5h of rate increases are not captured.
- **Affected parties**: PLPs receive slightly less interest; borrowers pay slightly less.
- **Impact magnitude**: Small — the rate changes by at most 2.6% per 4.5h window, so the missed evolution for a 24h period is bounded.
- **Existing mitigations**: By design — the cap is a safety feature preventing extreme single-step adjustments.

---

## F) Recommendations

### For IRM-002 (wTaylorCompounded precision):

1. **Minimal code change**: Add a 4th Taylor term in `wTaylorCompounded`:

   ```solidity
   uint256 fourthTerm = mulDiv(thirdTerm, firstTerm, 4 * WAD);
   return firstTerm + secondTerm + thirdTerm + fourthTerm;
   ```

   This extends the < 1% error threshold from z ≈ 0.62 to z ≈ 1.1, covering 2 months at max rate.

2. **Alternative**: Cap `deltaTime` in `_calculateCurrentInterestState` to a maximum (e.g., 1 week = 604,800s) to keep z < 0.15 at max rate. This ensures Taylor error stays below 2 bps.

3. **Assertion**: Add a check that `rate * deltaTime < TAYLOR_SAFE_BOUND` (e.g., 0.5 WAD) and revert or cap if exceeded.

### For IRM-003 (borrowIndex overflow):

1. **Minimal code change**: Add a 80-bit mask in `storeMarketState`:

   ```solidity
   // Mask _borrowIndex to 80 bits to prevent overflow into epoch
   let safeBorrowIndex := and(_borrowIndex, 0xFFFFFFFFFFFFFFFFFFFF)
   result := add(
       add(add(safeBorrowIndex, shl(80, _marketEpoch)), shl(112, _rateAtTarget)),
       shl(150, _unrealizedInterest)
   )
   ```

   This prevents silent corruption but causes incorrect interest calculations when the index wraps. A more robust approach:

2. **Preferred**: Add a revert check before storing:

   ```solidity
   require(currentBorrowIndex <= type(uint80).max, "borrowIndex overflow");
   ```

   at CT:978 (before `storeMarketState`). This converts silent corruption into a clean failure, giving governance time to migrate the pool.

3. **Parameter adjustment**: Consider increasing the borrowIndex field to 96 bits (by reducing unrealizedInterest to 90 bits), which extends the overflow time at 800% APR from 1.75 years to ≈112 years.

### For IRM-005 (slow recovery from MIN):

1. **Parameter adjustment**: Increasing `ADJUSTMENT_SPEED` to 100/year would halve recovery time (13 days to INITIAL from MIN) while still maintaining manipulation resistance. However, this doubles the per-window adjustment to ≈5.2%, which could slightly increase oscillation risk.

2. **Alternative**: Set a minimum floor for the initial interaction rate after extended idle periods, bypassing the slow recovery.

### For IRM-006 (rate underestimate for stale pools):

1. No code change recommended. The `IRM_MAX_ELAPSED_TIME` cap is a reasonable safety measure. The underestimate is conservative (favors borrowers) and bounded. Accepting this as a known trade-off is appropriate.
