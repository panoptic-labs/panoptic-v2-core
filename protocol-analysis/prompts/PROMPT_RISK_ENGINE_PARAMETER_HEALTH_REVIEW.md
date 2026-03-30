# RiskEngine Launch Parameter Health Review Prompt

```
You are a senior DeFi risk analyst and Solidity researcher performing a launch-parameter health review.

Scope restriction (hard):
- Primary target: `RiskEngine.sol`.
- You MAY read other files under `contracts/` only to trace formulas, call paths, and how RiskEngine outputs are consumed. Key downstream consumers: `PanopticPool.sol`, `CollateralTracker.sol`, `SemiFungiblePositionManager.sol`, `libraries/Math.sol`.
- Focus on launch calibration quality (stability, resilience, economic behavior), not governance takeover or key-compromise security.

Objective:
Evaluate whether the CURRENT `RiskEngine.sol` parameter choices are appropriate for protocol launch, considering normal conditions, stress regimes, and edge cases.

Important framing:
- Treat current parameters as the launch candidate set.
- Do not center the report on "who can change parameters."
- Center on: protocol health, solvency robustness, liquidation behavior, premium fairness, utilization dynamics, and failure modes under stress.

Deployment context (fill in before running):
- Target chain/L2: ___ (affects block time, gas cost for liquidations, MEV landscape)
- Launch asset pairs: ___ (affects appropriate volatility assumptions)
- Expected TVL range: ___ (affects whether rounding/dust issues are material)
- Comparable protocol benchmarks: ___ (e.g., Aave v3, Morpho Blue, Euler v2 IRM parameters)

If deployment context fields are left blank, state your assumptions explicitly at the top of the report and flag any conclusion that would change materially under different assumptions. Default to conservative assumptions (high-vol assets, moderate TVL, L2 with ~2s block times).

Assumptions:
- Markets can be volatile, gap, and mean-revert.
- Users can be highly leveraged and behaviors can cluster (crowded positioning).
- MEV/order effects can amplify stress, but this is an economic stability review first.
- Any reachable market regime should be considered eventually reachable.

Methodology (follow this order before producing deliverables):
1. Read `RiskEngine.sol` end-to-end. Extract every `constant`, `immutable`, and dynamically computed value. Do not rely on the parameter names listed below — they may be incomplete or renamed.
2. Check recent git history (`git log --oneline -20 -- contracts/RiskEngine.sol`) for parameter changes and commit messages that explain calibration rationale.
3. Trace each parameter's consumption path through `PanopticPool`, `CollateralTracker`, and `SFPM` to understand where it binds behavior.
4. Only then produce the deliverables below.

Architecture context (critical for tracing parameter flow):
- Parameters are packed into `RiskParameters` (a 256-bit bitfield) via `getRiskParameters()` and passed cross-contract: `RiskEngine → PanopticPool → CollateralTracker`.
- `safeMode` is dynamically computed from oracle ticks, not a static parameter. It is the arithmetic sum of three boolean conditions (externalShock, internalDisagreement, highDivergence — each contributing 0 or 1) plus the guardian `lockMode` (0 or 3). This yields values in the range 0–6. It is NOT a bitfield — it is an additive integer.
- `rateAtTarget` is stored in a 38-bit field inside the `MarketState` packed type — the 38-bit field can represent up to ~867% annualized. Verify whether this ceiling provides adequate headroom above `MAX_RATE_AT_TARGET`, and whether the effective max rate (rateAtTarget × CURVE_STEEPNESS) introduces any additional constraint.
- IRM uses `wTaylorCompounded` (Taylor series approximation of `e^(r*t) - 1`, using 3 non-zero terms: x + x²/2 + x³/6) for interest compounding in `CollateralTracker`, and `wExp` for rate adaptation in `RiskEngine`. Truncation error matters at high rates and long elapsed times. Note: a separate `sTaylorCompounded` function (4 non-zero terms) exists in `Math.sol` but is used elsewhere — verify which function is called for interest accrual.
- Interest accrual happens inside `CollateralTracker` but rate computation lives in `RiskEngine`. The `deltaTime` for compounding in `CollateralTracker` is NOT capped by `IRM_MAX_ELAPSED_TIME` — only rate adaptation is capped.
- `CROSS_BUFFER_0` and `CROSS_BUFFER_1` are immutables set per-pool at deployment (not global constants). All other risk parameters are global constants.
- Margin calculations use the stored utilization from mint time (not current utilization). This is a deliberate design choice that prevents cascading liquidations from utilization spikes — assess whether this creates any adverse secondary effects.

Required parameter coverage:
You must inventory and assess all relevant RiskEngine parameters, including (but not limited to):
- Oracle/safe mode: `EMA_PERIODS`, `MAX_TICKS_DELTA`, `MAX_CLAMP_DELTA`, `MAX_TWAP_DELTA_DISPATCH`
- Guardian/liveness: `GUARDIAN` (address, immutable), `lockMode` (guardian-set state that adds 0 or 3 to safeMode)
- Fee/split: `NOTIONAL_FEE`, `PREMIUM_FEE`, `PROTOCOL_SPLIT`, `BUILDER_SPLIT`, `BUILDER_FACTORY`, `BUILDER_INIT_CODE_HASH`
- Margin/collateral: `SELLER_COLLATERAL_RATIO`, `BUYER_COLLATERAL_RATIO`, `MAINT_MARGIN_RATE`, `BP_DECREASE_BUFFER`, `CROSS_BUFFER_0`, `CROSS_BUFFER_1`, `TARGET_POOL_UTIL`, `SATURATED_POOL_UTIL`, `MAX_OPEN_LEGS`
- Liquidation: `MAX_BONUS` (caps liquidation bonus as a fraction of remaining balance), `FORCE_EXERCISE_COST`, `MAX_SPREAD`, `VEGOID`
- IRM: `CURVE_STEEPNESS`, `MIN_RATE_AT_TARGET`, `MAX_RATE_AT_TARGET`, `TARGET_UTILIZATION`, `INITIAL_RATE_AT_TARGET`, `ADJUSTMENT_SPEED`, `IRM_MAX_ELAPSED_TIME`
- Scaling/precision constants that affect behavior: `DECIMALS`, `WAD`, `ONE_BPS`, `TEN_BPS`, `LN2_SCALED`, `MAX_UTILIZATION`

IMPORTANT: Verify all parameter values directly from the source code. Do not trust the names listed above as exhaustive — scan RiskEngine.sol for any constants or immutables not listed here. The values above may be outdated relative to the code you are reviewing.

Deliverables (strict order):

A) Parameter Sheet (exhaustive)
For each parameter provide:
1. Name and current value (read from source code, not from this prompt)
2. Units/scaling and human-readable interpretation
3. Subsystem it controls (oracle, margin, liquidation, IRM, etc.)
4. Mutability class: `constant` (global, compile-time), `immutable` (per-pool, set at deployment), or `dynamic` (computed at call time)
5. Directional effect when increased/decreased

Output format:
- Single table:
  `Parameter | Current Value | Human-Readable | Units | Mutability | Subsystem | Increase Effect | Decrease Effect | Notes`

B) Mechanism Map
For each parameter, identify exactly where it feeds into behavior:
1. Function/formula path(s) — include the specific function names and file locations
2. Intermediate variable(s) it influences
3. Final protocol outcome(s) impacted
4. If the parameter is packed into `RiskParameters` or `MarketState`, note the bit-width and any precision loss from packing

At minimum map to:
- Solvency decisioning (including utilization-at-mint mechanics)
- Liquidation bonus computation and protocol loss behavior (`MAX_BONUS` caps, cross-asset conversion)
- Force exercise pricing (in-range vs OTM fee structure)
- Premium settlement and utilization-linked spread dynamics (VEGOID interaction)
- Interest-rate evolution (rate adaptation vs interest compounding — trace both paths separately)
- Safe-mode activation and tick-selection conservatism (how many ticks are checked at each safeMode level)
- Fee routing (protocol vs builder wallet paths, including the intentional user rebate when PROTOCOL_SPLIT + BUILDER_SPLIT < 10,000)

C) Baseline Health Assessment
Assess behavior under "normal" market conditions:
1. Collateral efficiency vs safety buffer
2. Borrow cost responsiveness around target utilization
3. Premium transfer fairness between longs/shorts
4. Probability of unnecessary liquidations vs delayed liquidations
5. Expected user UX friction from conservative thresholds

Quantitative expectations (mandatory — compute from actual code values):
- Compute the actual annualized borrow rate at target utilization, at 0%, and at 100% with current parameters and INITIAL_RATE_AT_TARGET.
- Compute the full rate range at MIN_RATE_AT_TARGET and MAX_RATE_AT_TARGET (multiply by 1/CURVE_STEEPNESS and CURVE_STEEPNESS to get bounds).
- Compute the actual collateral required for a 1 ETH short put at ATM, 10% OTM, and 30% OTM (at below-target utilization, and at saturated utilization).
- Express `MAX_TICKS_DELTA` as a percentage price deviation.
- Express `MAX_TWAP_DELTA_DISPATCH` as a percentage price deviation (asymmetric: up vs down).
- Express `MAX_CLAMP_DELTA` as a percentage price deviation per epoch, and compute the time for the oracle to track a MAX_TICKS_DELTA-sized move.
- Compute the effective init-maint margin gap from BP_DECREASE_BUFFER at base SCR and at saturated SCR. Express as a percentage of notional and as an approximate underlying price move for a delta-0.5 option.
- Compute the MAX_BONUS cap as a percentage and how it changes the liquidation bonus formula relative to the uncapped min(balance/2, shortfall).

D) Stress & Edge-Case Analysis
Run qualitative AND quantitative stress scenarios with current parameters:
1. Fast volatility shock (tick jumps near/through safe-mode thresholds — work through the EMA lag dynamics)
2. Choppy market causing repeated threshold crossings (mode flapping risk — note absence of hysteresis)
3. Utilization surge to saturated region (cross-buffer decay behavior — distinguish effects on existing vs new positions due to utilization-at-mint)
4. Correlated liquidation wave with cross-asset shortfalls (trace through MAX_BONUS cap, cross-token conversion, premium haircut)
5. Long inactivity gap then rate update (`IRM_MAX_ELAPSED_TIME` caps rate ADAPTATION but not interest COMPOUNDING — quantify both effects separately)
6. Deep ITM/OTM force exercise edge behavior (`FORCE_EXERCISE_COST` vs `ONE_BPS`, range logic, price impact reversal)
7. Extreme spread/premium cases near `MAX_SPREAD` and high utilization (long premium multiplier at limit)
8. Rounding and precision boundary effects (small balances, near-zero deltas — verify rounding direction is protocol-favorable)
9. Guardian lockMode override during active positions (lockMode adds 3 → safeMode ≥ 3 — what operations are blocked vs permitted?)
10. Builder code fee routing (PROTOCOL_SPLIT + BUILDER_SPLIT < 10,000 is an intentional user rebate — verify the remainder stays in CollateralTracker and benefits the minting user; quantify economic impact at scale)
11. `rateAtTarget` hitting 38-bit storage ceiling (verify headroom between MAX_RATE_AT_TARGET and the 38-bit maximum; check whether the uint40 intermediate cast preserves precision)
12. Taylor expansion error accumulation (`wTaylorCompounded` uses 3 non-zero terms — compute the compounding error over various time gaps at MAX_RATE_AT_TARGET × CURVE_STEEPNESS, and identify the threshold where error becomes material >1%)
13. `CROSS_BUFFER` asymmetry (token0 and token1 can have different cross-buffers — model behavior under extreme price ratios and directional surplus)
14. MAX_BONUS interaction with partially-collateralized positions (does the bonus cap create scenarios where liquidation is unprofitable, leading to delayed liquidation?)

For each scenario:
- Preconditions
- Parameters that dominate outcomes
- Expected behavior with current values (include numerical worked example for at least 6 scenarios)
- Failure mode / unhealthy behavior (if any)
- Severity for launch readiness

E) Sensitivity & Coupling Matrix
Identify first-order and coupled sensitivities:
1. Single-parameter sensitivity (high/medium/low) with justification
2. Critical parameter pairs that create nonlinear cliffs
3. Regimes where "safe alone, unsafe in combination"

Minimum coupled pairs to analyze:
- `MAX_TICKS_DELTA` + `MAX_CLAMP_DELTA` (oracle tracking lag vs detection threshold)
- `MAX_TICKS_DELTA` + `MAX_CLAMP_DELTA` + `lockMode` (guardian can override independently — verify it can only increase protection)
- `SELLER_COLLATERAL_RATIO` + `MAINT_MARGIN_RATE` (option margin vs loan margin — additive burden for mixed portfolios)
- `TARGET_POOL_UTIL` + `SATURATED_POOL_UTIL` (slope of SCR ramp — compute the percentage SCR increase per 1% utilization increase)
- `CROSS_BUFFER_0/1` + utilization-driven logic (cross-buffer decays to 0 at a utilization cutoff — identify the cutoff and its interaction with SATURATED_POOL_UTIL)
- `ADJUSTMENT_SPEED` + `IRM_MAX_ELAPSED_TIME` (max single-step rate adaptation — compute exp(speed × err × cap / WAD) and the time to traverse MIN→MAX)
- `MAX_RATE_AT_TARGET` + utilization shock regimes (max effective rate = MAX_RATE_AT_TARGET × CURVE_STEEPNESS — is this punitive or protective?)
- `PROTOCOL_SPLIT` + `BUILDER_SPLIT` (verify sum < 10,000 is intentional; model the incentive structure for builders vs direct users)
- `MAX_OPEN_LEGS` + `MAX_SPREAD` (position complexity × liquidity removal limits — compute worst-case gas for solvency checks)
- `FORCE_EXERCISE_COST` + `MAX_SPREAD` (exercise incentive vs spread cap — at what spread level does force exercise become economically rational?)
- `BP_DECREASE_BUFFER` + `SELLER_COLLATERAL_RATIO` (effective init-maint gap at base and saturated utilization)
- `MAX_BONUS` + `SELLER_COLLATERAL_RATIO` (does the bonus cap ensure liquidation is always profitable for the liquidator given the margin level?)

F) Launch Readiness Verdict
Give a clear verdict:
- `GREEN` (launch-ready),
- `YELLOW` (launchable with monitoring/guardrails),
- `RED` (recalibration required pre-launch).

Include:
1. Top 5 launch risks linked to specific parameters
2. Why each risk matters economically
3. What metric would confirm or falsify concern after launch
4. What has changed since the last review (if prior audit output is available for comparison)

G) Recalibration Recommendations
For each non-GREEN item:
1. Parameter(s) to tune
2. Suggested direction/range with numerical bounds (not just "increase/decrease")
3. Tradeoff analysis (capital efficiency, liquidation latency, protocol loss, UX)
4. Whether change should be immediate pre-launch or staged post-launch
5. Whether the change requires redeployment (constants) or can be applied per-pool (immutables)

H) Validation Plan (must be actionable)
Define tests/monitoring needed before and right after launch:
1. Deterministic boundary tests for threshold edges (list specific parameter boundary values to test)
2. Scenario tests for liquidation, solvency, and IRM dynamics (Foundry fork tests or fuzz tests where appropriate)
3. Pre-launch simulation: Monte Carlo or historical replay expectations (define input distributions and target metrics)
4. Invariants to monitor live (solvency consistency, liquidation shortfall frequency, safe-mode duty cycle, rate volatility)
5. Alert thresholds that indicate miscalibration

I) Comparative Benchmarking
Compare key parameters against established DeFi protocols:
1. IRM parameters vs Aave v3, Morpho Blue, Euler v2 (curve steepness, target utilization, rate bounds, adjustment speed). Note: Panoptic's IRM is derived from Morpho Blue's adaptive IRM — call out differences and their rationale.
2. Collateral ratios vs Opyn, Lyra, or comparable on-chain options protocols. Note: Panoptic's lower margin (vs 100-200% in other options protocols) is justified by continuous premium settlement and utilization-dependent ramp — verify this justification holds.
3. Oracle safety thresholds vs Uniswap TWAP manipulation cost at realistic liquidity levels (quantify the capital needed to move price by `MAX_TICKS_DELTA` ticks for pools at $1M, $10M, and $100M TVL)
4. Fee structure competitiveness vs existing options DEXes
5. Init-maint buffer (BP_DECREASE_BUFFER) vs Aave V3 LTV/LT gap and Euler V2 buffer fraction

Review rules:
- No vague statements like "seems reasonable"; every conclusion must tie to a parameter path and expected outcome.
- Always express units clearly (bps, 1e7-scale, WAD, ticks, seconds, token units).
- Flag dead/low-impact parameters explicitly.
- If a parameter's bit-packing introduces precision loss, flag it explicitly with the truncation bound.
- If uncertain, state what missing data prevents a stronger conclusion and what to measure.
- Keep focus on protocol health and economic resilience, not key-compromise threat modeling.
- Cross-reference any numerical claims against the actual code — do not propagate values from this prompt without verifying them in the source.
```
