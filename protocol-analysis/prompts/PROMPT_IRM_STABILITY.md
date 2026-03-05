# Interest Rate Model Stability Audit Prompt

You are a senior Solidity security researcher performing an adversarial stability analysis of the adaptive interest rate model (IRM).

Scope restriction (hard):

- Analyze ONLY files under `contracts/` (recursive).
- Ignore anything outside `contracts/`.
- If you reference a file outside `contracts/`, mark it "out of scope" and do not rely on it for conclusions.

## Objective

Exhaustively evaluate the stability, manipulability, and correctness of the adaptive IRM, focusing on:

1. Rate manipulation for profit (can an attacker influence the rate to extract value?)
2. Rate oscillation and instability (can utilization toggling cause harmful rate behavior?)
3. Precision and approximation errors in the mathematical primitives (wTaylorCompounded, wExp)
4. Edge case behavior at parameter bounds (MIN/MAX rate, extreme utilization, long time deltas)
5. Rate-utilization feedback loops (rate change → behavior change → utilization change → rate change)
6. Interest accrual correctness across the full lifecycle (borrow → compound → settle → repay)

## Assumptions

- Full MEV adversary who can time deposits, withdrawals, position opens/closes, and settlements.
- Attacker can control multiple accounts.
- Attacker can manipulate pool utilization by opening/closing large positions.
- The attacker's goal is to either: (a) reduce their own interest payments, (b) increase others' interest payments, (c) extract value from the rate adjustment mechanism, or (d) cause the IRM to malfunction (DoS or incorrect rates).
- Time granularity: the epoch is 4 seconds (uint32 timestamp << 2). The minimum meaningful time delta is 1 epoch.

## Background Context

### IRM Architecture

The IRM is a Morpho-inspired adaptive model with the following components:

**Rate computation (`_borrowRate`, RE:2195):**

1. Compute utilization error: `utilization - TARGET_UTILIZATION` (TARGET = 2/3 WAD)
2. Normalize error: `wDivToZero(error, errNormFactor)` where errNormFactor is `WAD - TARGET` (above target) or `TARGET` (below target)
3. Compute rate adjustment: `rateAtTarget * wExp(ADJUSTMENT_SPEED * error * deltaTime)`
4. Clamp to `[MIN_RATE_AT_TARGET, MAX_RATE_AT_TARGET]`
5. Compute final rate from sigmoid: `rateAtTarget * (CURVE_STEEPNESS * normalizedError) / (1 + |CURVE_STEEPNESS * normalizedError|)`
6. Return `(startRate + endRate) / 2` (trapezoid approximation) and the new `rateAtTarget`

**Interest compounding (`_calculateCurrentInterestState`, CT:992):**

1. `deltaTime = uint32(currentEpoch - previousEpoch) << 2` — time in seconds since last update
2. `(rate, newRateAtTarget) = riskEngine._borrowRate(utilization, rateAtTarget, deltaTime)`
3. `rawInterest = wTaylorCompounded(rate * deltaTime)` — approximates `e^(r*t) - 1`
4. `interestOwed = mulDivWadRoundingUp(assetsInAMM, rawInterest)` — global interest
5. `currentBorrowIndex = mulDivWadRoundingUp(borrowIndex, WAD + rawInterest)` — compound index
6. `rateAtTarget` stored back in MarketState (38-bit field, RE:2195)

**Per-user interest (`_getUserInterest`, CT:1082):**

- `userInterest = mulDivRoundingUp(netBorrows, currentBorrowIndex - userBorrowIndex, userBorrowIndex)`
- User's index is updated to current on settlement

### Constants (all in RiskEngine.sol)

| Constant                 | Value                                             | Line   |
| ------------------------ | ------------------------------------------------- | ------ |
| `CURVE_STEEPNESS`        | 4e18 (4 WAD)                                      | RE:161 |
| `MIN_RATE_AT_TARGET`     | 0.001 ether / 365 days ≈ 31,709,791 (0.1% APR)    | RE:165 |
| `MAX_RATE_AT_TARGET`     | 2.0 ether / 365 days ≈ 63,419,583,967 (200% APR)  | RE:169 |
| `TARGET_UTILIZATION`     | 2e18/3 ≈ 666,666,666,666,666,666 (66.67%)         | RE:173 |
| `INITIAL_RATE_AT_TARGET` | 0.04 ether / 365 days ≈ 1,268,391,679 (4% APR)    | RE:177 |
| `ADJUSTMENT_SPEED`       | 50 ether / 365 days ≈ 1,585,489,599,188 (50/year) | RE:183 |
| `SATURATED_POOL_UTIL`    | 9_000_000 (90% in DECIMALS scale)                 | RE:91  |

### Storage

- `rateAtTarget` is packed in `MarketState` as a 38-bit unsigned field at bits [112..149] (MarketState.sol:16-25).
- `borrowIndex` is packed as an 80-bit unsigned field in MarketState.
- `unrealizedGlobalInterest` is packed as a 106-bit unsigned field.

### Known Findings

- ROUND-001 (Info): wTaylorCompounded floors 2nd/3rd Taylor terms, counteracted by outer ceil
- ROUND-005 (Info): Interest accumulator clamping at CT:962-968 (burntInterestValue > unrealizedGlobalInterest)
- ROUND-007 (Info): borrowIndex monotonic ceil drift ~1 wei per epoch

## Deliverables (strict order)

### A) Rate Manipulation Analysis

#### A.1 Utilization Toggle Attack

- Attacker has large deposits in the CollateralTracker.
- Attacker rapidly opens and closes positions to toggle utilization between above-target and below-target.
- Each toggle causes `rateAtTarget` to adjust via `wExp(ADJUSTMENT_SPEED * error * deltaTime)`.
- **Question**: Does the asymmetric error normalization (WAD-TARGET vs TARGET) cause rateAtTarget to drift in one direction when utilization oscillates symmetrically around TARGET?
- Compute: if utilization alternates between TARGET+ε and TARGET-ε every epoch, what is the net change in `rateAtTarget` after N cycles?
- The exponential `wExp(speed * err * dt)` is multiplicative. Is `wExp(+x) * wExp(-x) == 1`? Or does the asymmetric normalization create a bias? (Note: above target, error is divided by `WAD-TARGET ≈ 0.333 WAD`; below target, by `TARGET ≈ 0.667 WAD`.)

#### A.2 Rate Pumping for Profit

- Attacker is a large depositor (PLP) who earns interest from borrowers.
- Attacker opens large short positions from a second account → utilization spikes → rate spikes.
- Other borrowers (short sellers) now pay higher interest to all PLPs, including the attacker.
- **Question**: Is the attacker's interest cost on their own short positions offset by the increased interest income on their PLP deposits?
- Compute the break-even point: what deposit/borrow ratio does the attacker need for this to be profitable?
- Does the ADJUSTMENT_SPEED constant (50/year) make the rate responsive enough for this to work within practical timeframes?

#### A.3 Rate Suppression

- Attacker is a large borrower who wants to minimize interest.
- Attacker deposits heavily → utilization drops → rate drops.
- **Question**: Is this self-defeating? (The deposit increases totalAssets, reducing utilization, but the attacker's borrow still counts.)
- Can the attacker use a different account for deposits vs borrows to separate the effects?
- What is the capital efficiency of this attack? (How much must be deposited to reduce the rate by X%?)

#### A.4 Rate Sniping via Epoch Timing

- `deltaTime = uint32(currentEpoch - previousEpoch) << 2` — the rate adjustment depends on time elapsed.
- If nobody interacts with the pool for a long time, `deltaTime` grows large.
- The next interaction triggers a large rate adjustment: `wExp(ADJUSTMENT_SPEED * error * LARGE_deltaTime)`.
- Can an attacker wait for a stale pool, then manipulate utilization just before triggering a large rate jump?
- What happens if deltaTime is very large (e.g., 24 hours = 21600 epochs)? Does `ADJUSTMENT_SPEED * error * deltaTime` overflow or produce extreme `wExp` values?

### B) Mathematical Precision Analysis

#### B.1 wTaylorCompounded (Math:1227)

- Approximates `e^x - 1` using 3-term Taylor series: `x + x^2/(2!) + x^3/(3!)`
- **Precision bounds**: For what range of input `x` is the relative error < 1 bps? < 1%? > 10%?
- The input `x = rate * deltaTime` where rate is per-second WAD-scaled.
- At `MAX_RATE_AT_TARGET` (200% APR) with the sigmoid at saturation, what is the maximum per-epoch `rate`? Per-day? Per-year?
- Compute the Taylor approximation error at these maxima.
- Does the error systematically favor one party? (Prior audit says floor, counteracted by outer ceil.)

#### B.2 wExp (Math:1269)

- Used in rate adjustment: `rateAtTarget * wExp(adjustmentSpeed * normalizedError * deltaTime)`
- **Input range**: What are the minimum and maximum inputs to `wExp` in practice?
  - Min: `ADJUSTMENT_SPEED * (-1 WAD) * 1 epoch = -1,585,489,599,188 * 4 ≈ -6.34e12`
  - Max: `ADJUSTMENT_SPEED * (+1 WAD) * large_deltaTime`
  - For deltaTime = 1 day (86400s): `1,585,489,599,188 * 86400 ≈ 1.37e17`
  - For deltaTime = 1 year: `1,585,489,599,188 * 31536000 ≈ 5e19` (> WAD)
- At large positive inputs, `wExp` overflows. What is the maximum safe input? Does the code handle overflow gracefully?
- At large negative inputs, `wExp → 0`. Is the result exactly 0 or some dust? If rateAtTarget \* 0 = 0, does rateAtTarget get stuck at 0 forever?
- **Clamping interaction**: After `wExp`, rateAtTarget is clamped to `[MIN_RATE_AT_TARGET, MAX_RATE_AT_TARGET]`. Does the clamp prevent all overflow issues?

#### B.3 Trapezoid Rate Approximation

- The final rate returned is `(startRate + endRate) / 2` (RE:2259).
- `startRate` is computed from the old `rateAtTarget`; `endRate` from the new `rateAtTarget`.
- For large deltaTime, the rate path is NOT linear between start and end — it's exponential.
- The trapezoid approximation underestimates convex paths and overestimates concave paths.
- **Question**: In which direction is the systematic error? Does it favor borrowers or PLPs?
- Compute the maximum approximation error for realistic rate transitions.

#### B.4 38-bit rateAtTarget Precision

- `rateAtTarget` is stored as a 38-bit unsigned integer (max ≈ 2.75e11).
- At `MAX_RATE_AT_TARGET ≈ 6.34e10`, this uses ~36 bits. Sufficient headroom.
- At `MIN_RATE_AT_TARGET ≈ 3.17e7`, this uses ~25 bits. Only ~13 bits of fractional precision below this.
- **Question**: For rates near `MIN_RATE_AT_TARGET`, does the 38-bit quantization cause meaningful precision loss? Can the rate get "stuck" at MIN due to quantization preventing small upward adjustments?
- When `wExp(adjustment)` returns a value very close to 1 WAD (small adjustment), is the multiplication `rateAtTarget * wExp(adj) / WAD` distinguishable from `rateAtTarget` after 38-bit truncation?

### C) Edge Case Analysis

#### C.1 First Interaction (Pool Initialization)

- `borrowIndex` starts at WAD (1e18), `rateAtTarget` starts at `INITIAL_RATE_AT_TARGET`.
- The first position mint triggers `_accrueInterest`. If `deltaTime = 0` (same epoch as init), what happens?
- If `deltaTime` is very large (pool deployed but not used for days), the first accrual computes interest for the full period. Is this correct behavior? Can it cause unexpected costs for the first user?

#### C.2 Zero Utilization

- No positions open: `assetsInAMM = 0`, utilization = 0.
- `_borrowRate` computes error = `0 - TARGET = -TARGET`.
- `normalizedError = -TARGET / TARGET = -1 WAD`.
- Rate adjustment: `wExp(-ADJUSTMENT_SPEED * 1 WAD * deltaTime)` → rate decreases rapidly toward MIN.
- Over a long idle period, rate reaches MIN_RATE_AT_TARGET and stays there.
- **Question**: When positions are opened again, how quickly does the rate recover? Is the ADJUSTMENT_SPEED sufficient to prevent prolonged underpricing of interest?

#### C.3 100% Utilization

- All deposited assets are deployed in positions: utilization = DECIMALS (10_000_000) or WAD (1e18) depending on scale.
- But utilization in \_borrowRate is WAD-scaled. Can utilization exceed WAD? (If `assetsInAMM + interest > totalAssets` due to timing.)
- `normalizedError = (WAD - TARGET) / (WAD - TARGET) = 1 WAD` (if util = 100%).
- Rate adjustment: `wExp(+ADJUSTMENT_SPEED * 1 WAD * deltaTime)` → rate increases toward MAX.
- If utilization stays at 100% for a day: `wExp(1.37e17)`. Is this within wExp's safe range?

#### C.4 borrowIndex Overflow

- `borrowIndex` is stored as 80 bits (max ~1.2e24), starts at 1e18.
- At sustained MAX_RATE_AT_TARGET (200% APR): index doubles every ~128 days.
- Time to overflow: `log2(1.2e24 / 1e18) ≈ 20` doublings ≈ 2560 days ≈ 7 years.
- But at even higher effective rates (rate \* sigmoid > MAX due to utilization spikes?), could it overflow sooner?
- **Question**: What happens when borrowIndex overflows the 80-bit storage in MarketState? Does the `toUint128()` cast succeed, but `storeMarketState` silently truncates? What downstream effects does this have on interest calculations?

#### C.5 Interest Accrual Gap

- `_accrueInterest` (CT:894) is called on every deposit, withdrawal, and settlement.
- If no user interacts for a long time, interest does not accrue. When the next user interacts, they trigger accrual for the full gap.
- The first user to interact pays gas for the full compound calculation.
- **Question**: Can an attacker exploit this by monitoring for large gaps and front-running interactions to capture the accrual benefit? (E.g., deposit right before a large accrual to capture interest as a PLP.)

#### C.6 Negative Effective Rate

- The IRM should never produce a negative rate. Verify:
  - `rateAtTarget` is uint (cannot be negative) — check.
  - The sigmoid `CURVE_STEEPNESS * normalizedError / (1 + |...|)` is in range (-CURVE_STEEPNESS, +CURVE_STEEPNESS).
  - `rateAtTarget * (1 + sigmoid/CURVE_STEEPNESS)` — if sigmoid is negative enough, can this produce a negative rate?
  - Compute: minimum sigmoid value = `-CURVE_STEEPNESS * WAD / (WAD + CURVE_STEEPNESS * WAD)` = `-4/(1+4)` = -0.8 WAD.
  - So `1 + sigmoid/CURVE_STEEPNESS = 1 - 0.2 = 0.8`. Rate = `rateAtTarget * 0.8`. Always positive.
  - **Verify** this holds in the actual WAD arithmetic with rounding.

### D) Feedback Loop Analysis

Model the following feedback loops and determine stability:

1. **Rate → Utilization → Rate**: High rate → borrowers close positions → utilization drops → rate drops → new borrowers enter → utilization rises → ... Is this a damped oscillation or can it diverge?

2. **Rate → Share price → Solvency → Liquidation → Utilization → Rate**: High rate → interest accrues → some borrowers become insolvent → liquidation → positions closed → utilization drops → rate drops. Can this cascade?

3. **Rate → PLP behavior → Deposit/Withdrawal → Utilization → Rate**: High rate → more deposits (attractive yield) → utilization drops → rate drops → PLPs withdraw → utilization rises → ... What is the equilibrium?

For each loop:

- Is the loop stable (converges to equilibrium) or unstable (can diverge)?
- What is the time constant (how fast does it converge/diverge)?
- Does `ADJUSTMENT_SPEED = 50/year` create appropriate responsiveness?
- Are there parameter combinations where the loop becomes unstable?

### E) Findings

For each finding:

- ID (IRM-NNN)
- Severity (Critical / High / Medium / Low / Informational)
- Category: manipulation / precision / overflow / instability / edge-case
- Concrete numerical example
- Affected parties and impact magnitude
- Existing mitigations

### F) Recommendations

For each finding:

1. Minimal code change if applicable
2. Parameter adjustment suggestion with rationale
3. Bounds/assertions that should be added for safety

## Review Rules

- Every numerical claim must include the actual computation with WAD-scaled values.
- Do not hand-wave about "the rate adjusts" — trace the exact `wExp` input and output for each scenario.
- wTaylorCompounded and wExp operate in WAD (1e18) scale. Keep all computations in this scale.
- Time is in seconds (not epochs) for rate calculations, but in epochs for storage. Be explicit about which scale you're using.
- The 38-bit rateAtTarget storage quantization is critical — always check if a computed adjustment survives the pack/unpack cycle.
- If an attack requires capital, compute the capital efficiency (profit / capital_locked / time).
- Distinguish between attacks that are profitable on mainnet (high gas costs) vs L2s (low gas costs).
