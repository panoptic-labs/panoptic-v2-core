# RiskEngine Launch Parameter Health Review — V2

> **Review date:** 2026-03-30
> **Branch:** `feat/parameters` > **Commit:** `c3e6c988` > **Model:** Claude Opus 4.6 (1M context)
> **Prior review:** `RISK_ENGINE_PARAMETER_REVIEW.md` (V1)

---

## Assumptions (Deployment Context Not Provided)

| Field                     | Assumed Value                                                      |
| ------------------------- | ------------------------------------------------------------------ |
| **Target chain**          | L2 with ~2s block times (e.g., Arbitrum, Base)                     |
| **Launch asset pairs**    | High-vol (ETH/USDC, WBTC/ETH); conservative volatility assumptions |
| **Expected TVL range**    | $1M–$100M per pool                                                 |
| **Comparable benchmarks** | Morpho Blue IRM, Aave v3 LTV/LT, Euler v2 buffer fractions         |

Conclusions flagged where assumptions would change the assessment are marked with **[ASSUMPTION-SENSITIVE]**.

---

## A) Parameter Sheet

| Parameter                 | Current Value          | Human-Readable                       | Units                    | Mutability    | Subsystem              | Increase Effect                                  | Decrease Effect                                        | Notes                                           |
| ------------------------- | ---------------------- | ------------------------------------ | ------------------------ | ------------- | ---------------------- | ------------------------------------------------ | ------------------------------------------------------ | ----------------------------------------------- |
| `DECIMALS`                | `10_000_000`           | 1 millitick precision                | 1e-7 fractional scale    | constant      | Global scaling         | N/A                                              | N/A                                                    | RiskEngine uses 1e7; CollateralTracker uses 1e4 |
| `MAX_UTILIZATION`         | `10_000`               | 100%                                 | bps                      | constant      | Utilization            | N/A                                              | N/A                                                    |                                                 |
| `LN2_SCALED`              | `6_931_472`            | ln(2) × DECIMALS                     | DECIMALS-scaled          | constant      | OTM decay math         | N/A                                              | N/A                                                    |                                                 |
| `ONE_BPS`                 | `1_000`                | 0.01%                                | 1e-7 scale               | constant      | Force exercise floor   | N/A                                              | N/A                                                    | Floor fee for OTM force exercise                |
| `TEN_BPS`                 | `10_000`               | 0.10%                                | 1e-7 scale               | constant      | OTM collateral floor   | N/A                                              | N/A                                                    | Minimum collateral for OTM decay                |
| `EMA_PERIODS`             | `60 / 120 / 240 / 960` | 1m / 2m / 4m / 16m                   | seconds (packed uint96)  | constant      | Oracle                 | Slower EMA → more lag                            | Faster EMA → more responsive but manipulable           | Spot/fast/slow/eons                             |
| `MAX_TICKS_DELTA`         | `724`                  | ~7.5% price deviation                | ticks                    | constant      | Oracle / safe mode     | Wider trigger → less conservative                | Tighter trigger → more false positives                 |                                                 |
| `MAX_TWAP_DELTA_DISPATCH` | `513`                  | ~5.26% up / ~5.0% down               | ticks                    | constant      | Dispatch protection    | Wider → more MEV exposure                        | Tighter → blocks legitimate exercises                  | Asymmetric by design                            |
| `MAX_SPREAD`              | `90_000`               | 9:1 removed/net ratio                | unitless (bps-like)      | constant      | Liquidity spread       | More long leverage allowed                       | Less spread → lower long premium multiplier            | Packed in 22 bits                               |
| `BP_DECREASE_BUFFER`      | `10_666_667`           | 106.67% multiplier (16/15)           | 1e-7 scale               | constant      | Init-maint margin gap  | Wider gap → more margin of safety                | Narrower gap → tighter liquidation trigger             | Packed in 26 bits; loan LTV 90.9% → LLTV 85%    |
| `WAD`                     | `1e18`                 | 1.0                                  | WAD                      | constant      | IRM scaling            | N/A                                              | N/A                                                    |                                                 |
| `IRM_MAX_ELAPSED_TIME`    | `16_384`               | ~4.55 hours                          | seconds                  | constant      | IRM adaptation cap     | More adaptation per step                         | Less drift risk                                        | 2^14                                            |
| `MAX_CLAMP_DELTA`         | `149`                  | ~1.50% per 64s epoch                 | ticks/epoch              | constant      | Internal oracle        | Faster tracking                                  | Slower tracking → more lag                             |                                                 |
| `VEGOID`                  | `8`                    | ν = 1/8                              | unitless                 | constant      | Long premium spread    | Higher → flatter spread curve                    | Lower → steeper spread → more expensive longs          |                                                 |
| `NOTIONAL_FEE`            | `1`                    | 0.01% (1 bps) at mint; 0.10% at burn | bps (CT DECIMALS=10_000) | constant      | Fee / revenue          | Higher fee → more protocol revenue               | Lower fee → cheaper for users                          | Packed 14 bits                                  |
| `PREMIUM_FEE`             | `100`                  | 1.0% of premium                      | bps (CT DECIMALS=10_000) | constant      | Fee / revenue          | Higher fee → more premium captured               | Lower fee → less drag on premium                       | Packed 14 bits                                  |
| `PROTOCOL_SPLIT`          | `5_000`                | 50% of commission                    | bps                      | constant      | Fee routing            | More to protocol                                 | Less to protocol, more to PLPs/users                   | Packed 14 bits                                  |
| `BUILDER_SPLIT`           | `4_000`                | 40% of commission                    | bps                      | constant      | Fee routing            | More to builder                                  | Less builder incentive                                 | Packed 14 bits                                  |
| `SELLER_COLLATERAL_RATIO` | `2_000_000`            | 20% at base                          | 1e-7 scale               | constant      | Margin                 | Higher margin → safer but less capital-efficient | Lower → more risk of insolvency                        |                                                 |
| `BUYER_COLLATERAL_RATIO`  | `1_000_000`            | 10% at base                          | 1e-7 scale               | constant      | Margin                 | Higher → more costly for buyers                  | Lower → more levered longs                             |                                                 |
| `MAINT_MARGIN_RATE`       | `1_000_000`            | 10% loan margin                      | 1e-7 scale               | constant      | Margin (loans)         | Higher → safer loans                             | Lower → more levered loans                             |                                                 |
| `FORCE_EXERCISE_COST`     | `30_000`               | 0.30% (30 bps) in-range              | 1e-7 scale               | constant      | Force exercise         | Higher → more costly to exercise                 | Lower → cheaper griefing / faster position turnover    | OTM floor = ONE_BPS = 0.01%                     |
| `TARGET_POOL_UTIL`        | `6_666_667`            | 66.67%                               | 1e-7 scale               | constant      | SCR ramp start         | Ramp starts later → more at base SCR             | Earlier ramp start → earlier capital requirements rise |                                                 |
| `SATURATED_POOL_UTIL`     | `9_000_000`            | 90%                                  | 1e-7 scale               | constant      | SCR ramp end (100%)    | Ramp ends later → flatter slope                  | Steeper ramp → faster margin increase                  |                                                 |
| `CROSS_BUFFER_0`          | per-pool               | Cross-collateral buffer for token0   | 1e-7 scale               | **immutable** | Solvency (cross-asset) | More cross-margin benefit                        | Less cross-margin → more conservative                  | Decays to 0 at 95% util                         |
| `CROSS_BUFFER_1`          | per-pool               | Cross-collateral buffer for token1   | 1e-7 scale               | **immutable** | Solvency (cross-asset) | Same as above                                    | Same                                                   | Decays to 0 at 95% util                         |
| `MAX_OPEN_LEGS`           | `26`                   | 26 legs max                          | count                    | constant      | Position complexity    | More complex strategies allowed                  | Less gas risk from solvency checks                     | Packed 7 bits                                   |
| `MAX_BONUS`               | `2_000_000`            | 20% of balance                       | 1e-7 scale               | constant      | Liquidation            | Higher → more liquidator incentive               | Lower → less protocol loss risk but less incentive     |                                                 |
| `CURVE_STEEPNESS`         | `4 ether`              | 4x                                   | WAD                      | constant      | IRM curve shape        | Steeper → more rate variance                     | Flatter → less responsive to util changes              |                                                 |
| `MIN_RATE_AT_TARGET`      | `≈3.17e10` WAD/s       | 0.10% annualized                     | WAD per second           | constant      | IRM floor              | Higher floor → more revenue guarantee            | Lower → rates can drop further                         | Min eff. rate = 0.025%                          |
| `MAX_RATE_AT_TARGET`      | `≈6.34e16` WAD/s       | 200% annualized                      | WAD per second           | constant      | IRM ceiling            | Higher ceiling → more punitive                   | Lower → less rate escalation                           | Max eff. rate = 800%                            |
| `TARGET_UTILIZATION`      | `2/3 ether`            | 66.67%                               | WAD                      | constant      | IRM target             | Higher → larger "below-target" range             | Lower → rates rise sooner                              | Matches TARGET_POOL_UTIL                        |
| `INITIAL_RATE_AT_TARGET`  | `≈1.27e15` WAD/s       | 4% annualized                        | WAD per second           | constant      | IRM bootstrap          | Higher → initial rates are steeper               | Lower → cheaper initial borrowing                      | Rate range: [1%, 16%]                           |
| `ADJUSTMENT_SPEED`        | `≈1.59e15` WAD/s       | 50/year                              | WAD per second           | constant      | IRM adaptation speed   | Faster convergence                               | Slower adaptation → more drift                         |                                                 |
| `GUARDIAN`                | per-deployment         | Guardian EOA/multisig                | address                  | **immutable** | Safe mode override     | N/A                                              | N/A                                                    | Can only increase protection                    |
| `BUILDER_FACTORY`         | per-deployment         | Builder wallet factory               | address                  | **immutable** | Fee routing            | N/A                                              | N/A                                                    |                                                 |
| `BUILDER_INIT_CODE_HASH`  | derived                | CREATE2 hash for wallets             | bytes32                  | **immutable** | Fee routing            | N/A                                              | N/A                                                    |                                                 |

---

## B) Mechanism Map

### B.1 Oracle / Safe Mode

| Parameter                 | Function Path                                                    | Intermediate Variables                              | Final Outcome                                 | Packing                          |
| ------------------------- | ---------------------------------------------------------------- | --------------------------------------------------- | --------------------------------------------- | -------------------------------- |
| `EMA_PERIODS`             | `getOracleTicks()` → `OraclePack.getOracleTicks()`               | spotEMA, fastEMA, slowEMA, eonsEMA                  | Tick selection for solvency                   | Not packed in RiskParameters     |
| `MAX_TICKS_DELTA`         | `isSafeMode()` L925,930,935                                      | externalShock, internalDisagreement, highDivergence | safeMode level (0–6)                          | 4-bit in RiskParameters          |
| `MAX_CLAMP_DELTA`         | `computeInternalMedian()` → `OraclePack.computeInternalMedian()` | Clamped tick delta per epoch                        | Internal median oracle accuracy               | Not packed                       |
| `MAX_TWAP_DELTA_DISPATCH` | `getRiskParameters()` → PanopticPool `_checkTwapDelta()`         | Dispatch tick delta check                           | Force exercise price protection               | 13-bit in RiskParameters         |
| `lockMode`                | `isSafeMode()` L938–944                                          | Adds 0 or 3 to safeMode                             | Guardian override (only increases protection) | 2-bit in OraclePack bits 118–119 |

**Safe mode activation flow:** `isSafeMode()` → `getSolvencyTicks()` → 1 tick (normal) vs 4 ticks (safeMode > 0) → `isAccountSolvent()` checks solvency at all returned ticks.

### B.2 Margin / Collateral

| Parameter                 | Function Path                                                                 | Intermediate Variables                                             | Final Outcome                                         |
| ------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------ | ----------------------------------------------------- |
| `SELLER_COLLATERAL_RATIO` | `_sellCollateralRatio()` L2147–2197 → `_getRequiredCollateralAtUtilization()` | `sellCollateralRatio` (20%–100% linear ramp)                       | Short option margin requirement                       |
| `BUYER_COLLATERAL_RATIO`  | `_buyCollateralRatio()` L2202                                                 | Fixed 10%                                                          | Long option margin requirement                        |
| `MAINT_MARGIN_RATE`       | `_getRequiredCollateralSingleLegNoPartner()` L1486–1494                       | `maintenanceLoanMargin` (10%–100% ramp via `_sellCollateralRatio`) | Loan position margin (100% + ramp)                    |
| `TARGET_POOL_UTIL`        | `_sellCollateralRatio()` L2182                                                | SCR ramp start point                                               | Below this: base SCR; above: linear ramp              |
| `SATURATED_POOL_UTIL`     | `_sellCollateralRatio()` L2187                                                | SCR ramp end point (100%)                                          | Above this: fully collateralized                      |
| `BP_DECREASE_BUFFER`      | `isAccountSolvent()` L1032–1033 via PanopticPool                              | `maintReq *= buffer / DECIMALS`                                    | Init-maint gap for buying-power-decreasing operations |
| `CROSS_BUFFER_0/1`        | `isAccountSolvent()` L1040–1047 → `crossBufferRatio()`                        | `scaledSurplusToken`                                               | Cross-asset surplus scaling for solvency              |

**Utilization-at-mint mechanics:** The `globalUtilizations` in `_getTotalRequiredCollateral()` (L1323) is the **max** utilization across all positions at their respective mint times. This means existing positions are not retroactively affected by utilization spikes — only new positions face higher margins. This prevents cascading liquidations but means positions minted at low utilization retain low SCR even if utilization later surges.

### B.3 Liquidation

| Parameter              | Function Path                    | Intermediate Variables                              | Final Outcome                                  |
| ---------------------- | -------------------------------- | --------------------------------------------------- | ---------------------------------------------- |
| `MAX_BONUS`            | `getLiquidationBonus()` L530–535 | `bonus = min(20% × balance, shortfall)`             | Liquidation incentive cap                      |
| Loan exclusion         | `getLiquidationBonus()` L540–549 | Bonus re-capped to exclude loan-inflated balance    | Prevents over-rewarding on borrowed collateral |
| Cross-token conversion | `getLiquidationBonus()` L567–602 | Surplus token converted to cover shortfall in other | Protocol loss mitigation                       |

**Bonus formula detail:** `bonus0 = min(balance0 × MAX_BONUS / DECIMALS, req0 > balance0 ? req0 - balance0 : 0)`. Additionally clamped: if `bonus / MAX_BONUS × DECIMALS + loanAmounts > balance`, recalculate bonus from `(balance - loanAmounts) × MAX_BONUS / DECIMALS`.

### B.4 Force Exercise

| Parameter             | Function Path             | Intermediate Variables                      | Final Outcome                              |
| --------------------- | ------------------------- | ------------------------------------------- | ------------------------------------------ |
| `FORCE_EXERCISE_COST` | `exerciseCost()` L494     | Base fee = 30 bps (in-range) or 1 bps (OTM) | Cost paid by exercisor to force-close      |
| Price reversal        | `exerciseCost()` L482–487 | Delta between current and oracle valuations | Compensates for unfavorable price movement |

### B.5 Premium Settlement / Spread

| Parameter    | Function Path                          | Intermediate Variables                     | Final Outcome                       |
| ------------ | -------------------------------------- | ------------------------------------------ | ----------------------------------- |
| `VEGOID`     | `SFPM._getPremiaDeltas()`              | `numerator = netLiq + removedLiq / VEGOID` | Long premium multiplier sensitivity |
| `MAX_SPREAD` | PanopticPool `_checkLiquiditySpread()` | `removedLiq × DECIMALS / netLiq` check     | Max leverage/spread ratio per chunk |

At MAX_SPREAD (90,000) with VEGOID=8: the long premium multiplier = `1 + removed/(net × VEGOID)`. At max spread where removed/net = 9, this yields a multiplier of **2.125×** on the base premium.

### B.6 Interest Rate Model

| Parameter                | Function Path                   | Intermediate Variables                                    | Final Outcome                                      |
| ------------------------ | ------------------------------- | --------------------------------------------------------- | -------------------------------------------------- |
| `CURVE_STEEPNESS`        | `_curve()` L2365–2374           | Piecewise linear: rate = rateAtTarget × (1 + coeff × err) | Rate magnification above/below target              |
| `ADJUSTMENT_SPEED`       | `_borrowRate()` L2316           | `speed = ADJUSTMENT_SPEED × err`                          | Rate adaptation velocity                           |
| `IRM_MAX_ELAPSED_TIME`   | `_borrowRate()` L2320–2323      | `elapsed = min(epochDelta, 16384)`                        | Caps adaptation per step; does NOT cap compounding |
| `MIN/MAX_RATE_AT_TARGET` | `_newRateAtTarget()` L2387–2390 | `bound(startRate × exp(adaptation), MIN, MAX)`            | Hard rails on rateAtTarget                         |
| `INITIAL_RATE_AT_TARGET` | `_borrowRate()` L2311           | Used on first interaction only                            | Bootstrap rate                                     |
| `TARGET_UTILIZATION`     | `_borrowRate()` L2295–2298      | `err = (util - target) / normFactor`                      | Error signal for adaptation                        |

**Rate adaptation vs. interest compounding (two distinct paths):**

1. **Rate adaptation** (RiskEngine `_borrowRate()`): `rateAtTarget *= exp(speed × err × elapsed)`, where elapsed is capped at `IRM_MAX_ELAPSED_TIME`.
2. **Interest compounding** (CollateralTracker `_calculateCurrentInterestState()`): `borrowIndex *= (1 + wTaylorCompounded(rate, deltaTime))`, where deltaTime is **uncapped**.

`rateAtTarget` is stored in 38 bits (bits 112–149 of MarketState). Max storable value: `2^38 - 1 = 274,877,906,943` WAD/s ≈ 867% annualized. Headroom above MAX_RATE_AT_TARGET (200%): **4.33×**. The effective max rate = MAX_RATE_AT_TARGET × CURVE_STEEPNESS = 800% annualized, which is the output of `_curve()` and not stored, so the 38-bit ceiling only constrains `rateAtTarget`, not the effective rate.

### B.7 Fee Routing

| Parameter        | Function Path                                                                                        | Final Outcome                                                          |
| ---------------- | ---------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `NOTIONAL_FEE`   | CT `settleMint()` → `commission = notional × 1 / 10_000`                                             | 1 bps at mint; 10 bps at burn (×10 multiplier), min'd with premium fee |
| `PREMIUM_FEE`    | CT `settleBurn()` → `commission = min(10 × notionalFee × notional, premiumFee × premium) / DECIMALS` | 1% of premium or 10 bps of notional, whichever is less                 |
| `PROTOCOL_SPLIT` | CT fee routing → `protocolShare = commission × 50%`                                                  | Goes to RiskEngine address (guardian-withdrawable)                     |
| `BUILDER_SPLIT`  | CT fee routing → `builderShare = commission × 40%`                                                   | Goes to builder wallet via CREATE2                                     |
| **User rebate**  | Remainder: `commission × 10%`                                                                        | Stays in CollateralTracker → benefits minting user/PLPs                |

Sum: PROTOCOL_SPLIT + BUILDER_SPLIT = 9,000 < 10,000 bps. The intentional 10% remainder stays in the vault, effectively reducing the commission for the minting user.

---

## C) Baseline Health Assessment

### C.1 Collateral Efficiency vs. Safety Buffer

At base utilization (<66.67%):

- **Short options:** 20% margin → 5× leverage. Competitive with TradFi Reg-T (20% for naked options).
- **Long options:** 10% margin → 10× leverage.
- **Loans:** 100% + 10% = 110% collateral (10% maintenance margin on loans).

This is significantly more capital-efficient than competing on-chain options protocols (Opyn: 100%+, Lyra: varies 100–200%). The justification is continuous premium settlement and the utilization-dependent ramp to 100%. **This is sound provided liquidation latency is tight enough to catch accounts before they go underwater** — see Stress Section D.

### C.2 Quantitative Rate Expectations

| Utilization     | Rate (initial rateAtTarget=4%) | Rate (MIN rateAtTarget=0.1%) | Rate (MAX rateAtTarget=200%) |
| --------------- | ------------------------------ | ---------------------------- | ---------------------------- |
| 0%              | **1.00%**                      | 0.025%                       | 50.0%                        |
| 66.67% (target) | **4.00%**                      | 0.10%                        | 200.0%                       |
| 100%            | **16.0%**                      | 0.40%                        | **800.0%**                   |

The IRM responds smoothly. At initial calibration (4% target), rates range 1–16%, which is reasonable for DeFi lending. The 800% ceiling at max adaptation is punitive but serves as a protocol-survival mechanism.

### C.3 Quantitative Oracle Thresholds

| Metric                        | Value                    | Interpretation                                         |
| ----------------------------- | ------------------------ | ------------------------------------------------------ |
| `MAX_TICKS_DELTA`             | 724 ticks                | **~7.5%** price deviation triggers safe mode           |
| `MAX_TWAP_DELTA_DISPATCH`     | 513 ticks                | **~5.26% up / ~5.0% down** — dispatch price protection |
| `MAX_CLAMP_DELTA`             | 149 ticks/epoch          | **~1.50%** per 64s epoch maximum oracle tracking speed |
| Oracle lag to track 7.5% move | ceil(724/149) = 5 epochs | **~320 seconds (~5.3 minutes)**                        |

### C.4 Margin Quantitative Examples — 1 ETH Short Put

Assuming 100-tick-wide position (~1% range), priced in token1:

| Scenario     | Utilization | ATM                 | 10% OTM                     | 30% OTM              |
| ------------ | ----------- | ------------------- | --------------------------- | -------------------- |
| Below target | <66.67%     | **0.20 ETH** (20%)  | **~0.003 ETH** (exp. decay) | **~floor (0.1 bps)** |
| Saturated    | 90%         | **1.00 ETH** (100%) | **~0.013 ETH**              | **~floor**           |

The exponential OTM decay is aggressive — positions far OTM require near-zero collateral. This is appropriate: the probability of a 30% OTM option becoming material is very low, and the continuous premium settlement mechanism handles gradual losses.

### C.5 Init-Maint Margin Gap

| Utilization     | SCR  | BP_DECREASE_BUFFER Effect | Gap (% of notional) | Price move for delta-0.5 |
| --------------- | ---- | ------------------------- | ------------------- | ------------------------ |
| <66.67% (base)  | 20%  | ×1.06667 (16/15)          | **1.33%**           | **~2.67%**               |
| 90% (saturated) | 100% | ×1.06667 (16/15)          | **6.67%**           | **~13.3%**               |

The 6.67% buffer over maintenance maps cleanly to lending boundaries: a loan at base utilization has 10% maintenance margin (90.9% LTV), which becomes 85% LLTV after the buffer — a recognizable and conservative threshold. A ~2.67% price move against a delta-0.5 position at base utilization would push a newly minted position from init margin to maint margin. On a 2s L2 with responsive bots, this provides an adequate liquidation window.

### C.6 Premium Transfer Fairness

VEGOID=8 produces a moderate spread between short and long premium. At 50% utilization (removed/net ≈ 1), the long premium multiplier is ~1.125x, meaning longs pay ~12.5% more than shorts earn. At max spread (9:1), longs pay ~2.125x. This graduated approach is fair — it penalizes extreme leverage while keeping costs reasonable at moderate utilization.

### C.7 Fee Competitiveness

- **Mint fee:** 1 bps of notional — extremely low. Competitive.
- **Burn fee:** min(10 bps of notional, 1% of premium) — reasonable.
- **Builder rebate:** 10% of commission returns to vault — a small but meaningful user incentive.
- **Total cost for a round-trip:** ~11 bps of notional in the worst case — well below most DEX options fees (typically 0.1–0.3% per trade).

### Assessment Summary

Under normal conditions, the parameter set delivers:

- High capital efficiency (20% base margin for sellers)
- Responsive IRM that incentivizes target utilization
- Reasonable fee structure
- Fair premium distribution

**Primary concern under baseline:** The init-maint gap at low utilization (1.33% of notional, ~2.67% price move for delta-0.5) is serviceable on L2 but requires responsive liquidation infrastructure.

---

## D) Stress & Edge-Case Analysis

### D.1 Fast Volatility Shock (Safe Mode Threshold)

**Preconditions:** Pool at normal operation, sudden 12% price crash over 30 seconds.

**Dominant parameters:** MAX_TICKS_DELTA (724), EMA_PERIODS (spot=60s), MAX_CLAMP_DELTA (149).

**Expected behavior:**

1. `currentTick` instantly moves ~1,133 ticks (12% crash).
2. SpotEMA lags (60s period) — for an **instant** crash ≥724 ticks (~7.5%), the gap immediately exceeds 724 → **externalShock = true** on the first block.
3. Safe mode activates. Solvency checks now use 4 ticks (spot, median, latest, current).
4. Internal median is clamped at 149 ticks/epoch → lags ~5.3 minutes to track.
5. During lag period, solvency is checked at the more conservative tick among the 4, which protects against under-margined positions.

**Worked example — instant crash:** An instant 8% crash = ~760 ticks.

- At t=0: |currentTick - spotEMA| = 760 > 724 → **externalShock triggered immediately**.
- Safe mode active from the first block.

**Worked example — linear 12% crash over 60s:**

- After 60s: currentTick at 1,133 ticks. SpotEMA moved ~1,133 × (1 - e^(-1)) ≈ 716 ticks.
  - Gap = 1,133 - 716 = **417 ticks < 724** → externalShock NOT triggered via EMA condition alone.
- However, internalDisagreement threshold is now 724/2 = 362 ticks. |spotEMA - fastEMA| = 716 - 358 = **358 < 362** → marginally below threshold.
- The Euclidean norm check in `getSolvencyTicks()` with 724² = 524,176 provides an additional backstop — the 3D vector of tick deviations is likely to exceed this for a 12% move.

**Finding:** The reduction from 953 to 724 significantly improves detection. Instant crashes >7.5% now trigger safe mode immediately. Linear moderate-speed moves (10-12% over 60s) still may not trigger via EMA conditions alone, but the tighter threshold brings the gap much closer and the Euclidean norm backstop is more sensitive.

**Severity:** **YELLOW (improved from prior calibration).** The remaining gap is for linear moves in the 8-12% range over 60-90s — the Euclidean norm backstop partially covers this.

### D.2 Choppy Market / Mode Flapping

**Preconditions:** Market oscillating ±8% with 2-minute period.

**Dominant parameters:** MAX_TICKS_DELTA (724), EMA_PERIODS.

**Expected behavior:** The oscillation amplitude in ticks ≈ 760 ticks. With 60s spot EMA, the EMA oscillation amplitude is reduced by the EMA transfer function. For a 2-min oscillation, the EMA tracks ~71% of the amplitude → EMA amplitude ≈ 540 ticks. The gap |current - spotEMA| peaks at ~220 ticks — well below 724. Note: with the tighter 724 threshold, faster/larger oscillations (±10%, 1-min period) could briefly trigger safe mode, but this is appropriate behavior for such extreme chop.

**Finding:** Safe mode will NOT flap during typical choppy conditions. The EMA smoothing naturally prevents oscillation-driven false positives. **No hysteresis is needed given current thresholds.**

**Severity:** GREEN.

### D.3 Utilization Surge to Saturated Region

**Preconditions:** Pool utilization jumps from 60% to 92% due to a large sell wave.

**Dominant parameters:** TARGET_POOL_UTIL, SATURATED_POOL_UTIL, CROSS_BUFFER decay.

**Expected behavior:**

- **New positions:** SCR ramps to ~82.6% at 92% util. IRM rate escalates, deterring further selling.
- **Existing positions:** Retain their utilization-at-mint SCR (20% if minted at <66.67%). They are NOT retroactively margin-called.
- **Cross buffer:** At 92% util, `crossBufferRatio = CROSS_BUFFER × (95% - 92%) / (95% - 90%) = CROSS_BUFFER × 60%`. Cross-collateral benefit is declining.

**Worked example:** A position minted at 50% util keeps SCR = 20%. Pool surges to 92%. The position's margin requirement stays at 20% of notional (using 50% util SCR). If the position is also on the wrong side of price, the P&L loss plus the thin 20% margin could cause insolvency — but the position would have been more heavily margined if minted at 92%.

**Adverse secondary effect of utilization-at-mint:** An old low-utilization position could become underwater without triggering the elevated SCR intended for high-utilization environments. **However**, the IRM will rapidly push rates up, creating strong economic pressure to close positions and reduce utilization. And the BP_DECREASE_BUFFER still applies to all solvency checks regardless of utilization-at-mint.

**Severity:** YELLOW (known design tradeoff, documented and intentional).

### D.4 Correlated Liquidation Wave

**Preconditions:** Multiple accounts become insolvent simultaneously. Liquidators face gas competition.

**Dominant parameters:** MAX_BONUS (20%), cross-token conversion, premium haircut.

**Worked example:**

- Account A: balance = 100 USDC, required = 150 USDC. Shortfall = 50.
- bonus = min(100 × 20%, 50) = min(20, 50) = **20 USDC** to liquidator.
- Protocol loss = 50 - 20 = **30 USDC** absorbed by premium haircut → PLPs.

If account has loans inflating balance by 40 USDC:

- Effective balance for bonus = 100 - 40 = 60. bonus = min(60 × 20%, 50) = min(12, 50) = **12 USDC**.
- Protocol loss = 50 - 12 = **38 USDC**.

In a cross-asset shortfall (surplus in token0, deficit in token1), the surplus is converted and credited to the liquidator. This mitigates protocol loss but depends on oracle accuracy at the conversion price.

**Severity:** YELLOW — the 20% MAX_BONUS may not always cover liquidation gas costs for small positions, especially during gas spikes on L1. On L2 with low gas, this is less concerning.

### D.5 Long Inactivity Then Rate Update

**Preconditions:** Pool has no interactions for 7 days. Rate was at MAX_RATE_AT_TARGET (200%) with 100% utilization.

**Dominant parameters:** IRM_MAX_ELAPSED_TIME (16,384s), wTaylorCompounded accuracy.

**Rate adaptation (capped):**

- Elapsed = 7 days = 604,800s. Capped to 16,384s.
- Single-step adaptation: `exp(ADJUSTMENT_SPEED × err × 16384 / WAD)`.
- At err = +1: speed = 50/year = 1.586e-6/s. `exp(1.586e-6 × 16384) = exp(0.02597) = 1.0263`.
- rateAtTarget multiplies by only 1.0263 per capped step — **the cap works as intended for adaptation**.

**Interest compounding (uncapped):**

- deltaTime = 604,800s. Effective rate at max: 800% annualized = 2.537e-7/s in per-second terms.
- `wTaylorCompounded(rate, 604800)`:
  - y = rate × time in WAD = 0.1534
  - 3-term Taylor: 0.1534 + 0.01177 + 0.000602 = **0.16577**
  - Actual `e^0.1534 - 1` = **0.16588**
  - Error: **0.07%** — negligible for 1 week at max rate.

For 3 months idle at max rate:

- y = rate × time = 2.537e-7 × 7,776,000 = **1.972**
- 3-term Taylor: 1.972 + 1.944 + 1.278 = **5.194**
- Actual `e^1.972 - 1` = **6.184**
- Error: **(6.184 - 5.194) / 6.184 = 16.0%** — **material underestimation of interest owed**.

**Finding:** For pools idle at extreme rates (>100% annualized) for months, `wTaylorCompounded` underestimates interest by >1%. The crossover to >1% error occurs at approximately:

- y ≈ 0.53 → rate × time in WAD
- At 200% target (800% effective): per-second rate = 8.0/31.5M = 2.537e-7; time = 0.53/2.537e-7 ≈ 2,089,000s ≈ **~24 days**
- At 50% target (200% effective): per-second rate = 2.0/31.5M = 6.34e-8; time = 0.53/6.34e-8 ≈ 8,360,000s ≈ **~97 days**

The error favors borrowers (interest undercharged), which is a mild protocol loss risk.

**Severity:** GREEN — the >1% error crossover requires ~24 days of inactivity at 800% effective rate (or ~97 days at 200%). At such punitive rates, economic pressure to interact with the pool is extreme, making multi-week inactivity implausible. At typical rates (4–16%), even months of inactivity produce <0.1% error.

### D.6 Deep ITM/OTM Force Exercise

**Preconditions:** Position is deep in-the-money; exercisor calls forceExercise.

**Dominant parameters:** FORCE_EXERCISE_COST (30 bps in-range, 1 bps OTM), price reversal compensation.

**Expected behavior (in-range):**

- Base fee: 30 bps of long notional → exercisor pays this to the exercisee.
- Price reversal: exercisor also compensates for the difference between oracle and current price valuations. This can be significant for deep ITM positions where the exercisee's LP position composition has shifted.
- Total cost = 30 bps + price-reversal delta.

**Expected behavior (OTM):**

- Base fee drops to 1 bps (ONE_BPS = 1000 / DECIMALS = 0.01%). This is near-zero, intentionally making it cheap to force-exercise OTM positions and free up liquidity.

**Finding:** The 30 bps in-range fee is moderate. For very deep ITM positions, the price reversal term dominates, making force exercise expensive (as designed). For positions exactly at the range boundary, there's a discontinuity: the fee jumps from 1 bps to 30 bps as the position crosses into range. This is a minor UX concern but not a vulnerability.

**Severity:** GREEN.

### D.7 Extreme Spread Near MAX_SPREAD

**Preconditions:** A chunk has removed/net ratio approaching 90,000 (i.e., 9:1). A new long position pushes it close to the limit.

**Dominant parameters:** MAX_SPREAD (90,000), VEGOID (8).

**Expected behavior:** At removed/net = 9 (= 90,000 in DECIMALS), the long premium multiplier from the SFPM formula:

```
multiplier = 1 + removed/(net × VEGOID) = 1 + 9/(1 × 8) = 2.125x
```

At max spread, longs pay ~2.125× the base premium. This is moderate and acceptable as a market mechanism to deter extreme utilization.

**Severity:** GREEN.

### D.8 Rounding and Precision Boundaries

**Key areas:**

1. **RiskParameters packing:** All values fit their bit-widths with headroom. No precision loss from packing.

   - NOTIONAL_FEE (1) fits in 14 bits (max 16,383): no truncation.
   - BP_DECREASE_BUFFER (10,666,667) fits in 26 bits (max 67,108,863): no truncation.
   - MAX_SPREAD (90,000) fits in 22 bits (max 4,194,303): no truncation.

2. **MarketState rateAtTarget (38 bits):** Max storable = 274,877,906,943. MAX_RATE_AT_TARGET = 63,419,583,967. Headroom: 4.33×. The `uint40` intermediate cast in `updateRateAtTarget()` (40 bits → then masked to 38) provides safe conversion.

3. **Rounding direction:** `mulDivRoundingUp` is used for requirements (rounds up = protocol-favorable). `mulDiv` (rounds down) used for user balances. This is correct and protocol-protective.

4. **Small balance dust:** For positions with near-zero notional, the floor values (TEN_BPS for OTM decay, `required = 1` minimum) prevent zero-collateral positions. Not exploitable.

**Severity:** GREEN.

### D.9 Guardian lockMode Override

**Preconditions:** Guardian calls `lockPool()` while positions are open.

**Expected behavior:**

- `lockMode` set to 3 in OraclePack bits 118–119.
- `isSafeMode()` adds 3 to safeMode → safeMode ≥ 3 regardless of market conditions.
- `getSolvencyTicks()` checks safeMode > 0 → always checks all 4 ticks.
- **Operations affected:** All solvency-checking operations (mint, burn, force exercise) use the more conservative 4-tick check. Minting/burning still works but may be harder to satisfy solvency at all 4 ticks simultaneously.
- **Operations NOT blocked:** Deposits, withdrawals (if sufficient collateral), and liquidations continue. The guardian cannot prevent liquidations.

**Verification:** `lockSafeMode()` → `oraclePack.lock()` which ORs bits 118-119 to `11` (value 3). `unlockSafeMode()` → ANDs out those bits. Guardian can only increase effective safeMode, never decrease it below the automatically computed level. This is **sound** — the guardian is additive-only.

**Severity:** GREEN.

### D.10 Builder Fee Routing Rebate

**Preconditions:** User mints with a valid builderCode.

**Expected behavior:**

- Commission = notional × NOTIONAL_FEE / DECIMALS = notional × 0.01%.
- Protocol gets 50% → sent to RiskEngine address.
- Builder gets 40% → sent to BuilderWallet via CREATE2.
- Remaining 10% → **stays in CollateralTracker**. This benefits the minting user because the shares representing this commission remain in the vault, increasing the value of all shares proportionally. Effectively, the user pays only 90% of the commission.

**Economic impact at scale:** At $100M monthly notional:

- Total commission = $100M × 0.01% = $10,000/month (at mint) + burn fees.
- User rebate = $1,000/month across all users. Per-user impact is small.
- Builder incentive = $4,000/month. This is modest but provides some builder motivation.

**Verification:** The fee shares credited to `s_creditedShares` include only the protocol and builder portions. The remainder is left as surplus in the vault, confirmed by the fee routing code path.

**Severity:** GREEN.

### D.11 rateAtTarget Hitting 38-bit Ceiling

**Headroom analysis:**

- 38-bit max: 274,877,906,943 per-second WAD ≈ **867%** annualized
- MAX_RATE_AT_TARGET: 63,419,583,967 per-second WAD = **200%** annualized
- Ratio: 4.33×

The `_newRateAtTarget()` function bounds the result to `[MIN_RATE_AT_TARGET, MAX_RATE_AT_TARGET]` before storage. The 38-bit ceiling is only reached if the bounding logic fails — which it cannot because `bound()` enforces the constraint before the value is packed.

**uint40 intermediate:** In MarketState `updateRateAtTarget()`, the value is cast through an assembly AND mask to 38 bits (`0x3FFFFFFFFF`). If a value somehow exceeded 38 bits, it would be silently truncated. However, the upstream bound prevents this.

**Severity:** GREEN.

### D.12 Taylor Expansion Error Accumulation

See D.5 for the detailed analysis. Summary table of `wTaylorCompounded` error:

| Duration | Max Rate (800% ann.) | Error                           |
| -------- | -------------------- | ------------------------------- |
| 1 hour   | y ≈ 0.0009           | <0.001%                         |
| 1 day    | y ≈ 0.022            | 0.004%                          |
| 1 week   | y ≈ 0.153            | 0.07%                           |
| ~24 days | y ≈ 0.53             | **~1.0%** (crossover threshold) |
| 1 month  | y ≈ 0.658            | 0.97%                           |
| 3 months | y ≈ 1.97             | **16.0%**                       |

The error always **underestimates** interest (borrower-favorable, protocol-unfavorable).

**Severity:** GREEN — the >1% crossover at max rate requires ~24 days idle, which is implausible given the economic pressure from punitive rates. At typical rates (4–16%), even months of inactivity produce <0.1% error.

### D.13 CROSS_BUFFER Asymmetry

**Preconditions:** Token0 and token1 have different CROSS_BUFFER values. Price ratio is extreme.

**Expected behavior:** Each token's cross-buffer independently scales the surplus in that token before cross-collateral conversion. An asymmetric setting (e.g., CROSS_BUFFER_0 = 100%, CROSS_BUFFER_1 = 50%) means surplus in token0 provides more cross-benefit than surplus in token1.

Under extreme price ratios (e.g., ETH/USDC at $10,000), the cross-buffer in token1 (USDC) has much less impact per unit of surplus than the token0 buffer. This is appropriate if the deployer sets higher buffers for the more volatile asset.

**The 95% utilization cutoff** where cross-buffer drops to 0 is tied to SATURATED_POOL_UTIL:

```
cutoff = (SATURATED_POOL_UTIL + DECIMALS) / 2 = (9_000_000 + 10_000_000) / 2 = 9_500_000 = 95%
```

At very high utilization (>95%), cross-collateral is disabled entirely, forcing each token to be self-sufficient. This is appropriately conservative.

**Severity:** GREEN (per-pool deployment choice).

### D.14 MAX_BONUS and Liquidation Profitability

**Question:** Does the 20% bonus cap create scenarios where liquidation is unprofitable?

**Analysis:** Liquidation profitability for the liquidator = bonus - gas cost. The bonus is `min(20% × balance, shortfall)`.

For the bonus to be zero: the account must have zero balance (fully underwater). In this case, the liquidation still happens (no bonus, but positions are cleared).

For the bonus to be insufficient:

- Scenario: balance = 10 USDC, gas cost = 5 USDC. Bonus = 20% × 10 = 2 USDC < gas cost.
- **Small positions may be unprofitable to liquidate** on gas-expensive chains.

On L2 (gas ~0.01 USDC): any position with balance > 0.05 USDC would be profitable to liquidate.

Additionally, the loan exclusion (`bonus capped to exclude loan-inflated balance`) can further reduce the bonus. If an account has a large loan, the effective balance for bonus calculation drops, potentially making the bonus too small.

**Severity:** GREEN on L2. **[ASSUMPTION-SENSITIVE]** — YELLOW on L1 for small positions.

---

## E) Sensitivity & Coupling Matrix

### E.1 Single-Parameter Sensitivity

| Parameter                 | Sensitivity | Justification                                                                                   |
| ------------------------- | ----------- | ----------------------------------------------------------------------------------------------- |
| `MAX_TICKS_DELTA`         | **HIGH**    | 10% threshold directly gates safe mode. Too high → missed volatility; too low → false positives |
| `SELLER_COLLATERAL_RATIO` | **HIGH**    | 20% base margin is the primary solvency guardrail                                               |
| `BP_DECREASE_BUFFER`      | **HIGH**    | 6.67% multiplier (16/15) defines the liquidation reaction window; maps to 85% LLTV for loans    |
| `CURVE_STEEPNESS`         | **MEDIUM**  | 4× amplifies rate swings; higher → more punitive but also more responsive                       |
| `ADJUSTMENT_SPEED`        | **MEDIUM**  | Controls how fast rates converge to market conditions                                           |
| `MAX_BONUS`               | **MEDIUM**  | Liquidator incentive/protocol loss tradeoff                                                     |
| `MAX_SPREAD`              | **MEDIUM**  | Caps leverage but also premium cost for longs                                                   |
| `VEGOID`                  | **LOW**     | Moderate effect on premium spread curve shape                                                   |
| `FORCE_EXERCISE_COST`     | **LOW**     | 30 bps is small relative to option notional                                                     |
| `NOTIONAL_FEE`            | **LOW**     | 1 bps is near-zero impact on user economics                                                     |
| `MAX_OPEN_LEGS`           | **LOW**     | 26 is generous; gas is the practical constraint                                                 |
| `EMA_PERIODS`             | **MEDIUM**  | Short periods make oracle responsive but potentially exploitable                                |

### E.2 Critical Coupled Pairs

**1. `MAX_TICKS_DELTA` + `MAX_CLAMP_DELTA` (oracle tracking lag vs. detection)**

- Tracking time = ceil(724/149) = 5 epochs = 320s.
- If the oracle can only move 149 ticks per 64s, a flash crash that moves 724+ ticks creates a 5.3-minute lag where the internal median is stale.
- During this lag, solvency checks use the stale median as one of 4 ticks (when safe mode is active). This is conservative (checks at the stale — less favorable — tick).
- **Risk:** Moderate. The lag is designed; the concern is if the lag is too long for fast-moving markets.

**2. `MAX_TICKS_DELTA` + `MAX_CLAMP_DELTA` + `lockMode`**

- Guardian lockMode adds 3 → safeMode ≥ 3.
- This forces the 4-tick check permanently until unlocked.
- The guardian can only increase protection: lock() ORs bits, unlock() ANDs them out. There is no path where the guardian relaxes below the automatically computed level.
- **Verification:** Sound. lockMode is additive only.

**3. `SELLER_COLLATERAL_RATIO` + `MAINT_MARGIN_RATE`**

- For a portfolio with both options and loans, the total margin is additive.
- Short option: SCR = 20%. Loan: 100% + 10% loan margin = 110%.
- A mixed portfolio (option + loan on same token) faces: 20% + 110% = 130% of the combined notional at base utilization.
- At saturated utilization: 100% + 100% + 100% = both converge to 100%, so the penalty narrows.
- **Risk:** Low. The additive burden is appropriate for mixed risk.

**4. `TARGET_POOL_UTIL` + `SATURATED_POOL_UTIL` (SCR ramp slope)**

- Ramp: 20% → 100% over 66.67%–90% utilization = 80pp over 23.33pp.
- **Slope: 3.43% SCR increase per 1% utilization increase.**
- This is moderate. A 5% utilization spike (e.g., 70% → 75%) increases SCR by ~17 percentage points (from 23% to 40%).

**5. `CROSS_BUFFER_0/1` + utilization cutoff**

- Cross buffer decays linearly from SATURATED_POOL_UTIL (90%) to cutoff at 95%.
- At 92% util: 60% of full cross-buffer. At 95%: 0%.
- **Interaction with SATURATED_POOL_UTIL:** The cross-buffer cutoff is derived from SATURATED_POOL_UTIL. Changing SATURATED_POOL_UTIL shifts the cutoff. At the current 90%, the cutoff is 95%.

**6. `ADJUSTMENT_SPEED` + `IRM_MAX_ELAPSED_TIME`**

- Max single-step adaptation: `exp(50/31.5M × 1 × 16384) = exp(0.02597) = 1.0263` → **2.63% per max step**.
- Time to traverse MIN→MAX (0.1% → 200%): `ln(2000) / (50/31.5M) ≈ 4.79M seconds ≈ 55.5 days` at maximum error (err=1 sustained).
- **Risk:** Low. The traversal time is appropriately slow, preventing rate manipulation through temporary utilization spikes.

**7. `MAX_RATE_AT_TARGET` + utilization shock**

- Max effective rate = 200% × 4 = 800% annualized.
- At 800%, daily interest = 2.19%. Over a weekend (2.5 days): 5.5%. Over a week: 15.4%.
- **This is punitive by design** — it forces utilization back toward target. An account paying 800% annually would lose ~2.2% per day, creating strong pressure to close positions.

**8. `PROTOCOL_SPLIT` + `BUILDER_SPLIT`**

- Sum = 9,000 < 10,000. The 10% gap is an intentional user rebate.
- **Incentive structure:** Builder receives 40% of 1 bps = 0.004% of notional per mint. At $10M/month volume per builder, that's $400/month — modest but a growth incentive.
- Without builder code: 100% goes to PLPs (protocol), user gets no rebate. This means using a builder code is strictly better for the user (10% rebate) and the builder (40% of commission).

**9. `MAX_OPEN_LEGS` + `MAX_SPREAD`**

- 26 legs × potential gas for solvency checks. Each leg requires collateral computation including tick-math.
- Worst case gas: 26 legs × 4 ticks (safe mode) × multiple operations per check. This could be 100+ SLOAD/math operations.
- **On L2:** Gas cost is manageable. On L1: potentially expensive for complex portfolios.

**10. `FORCE_EXERCISE_COST` + `MAX_SPREAD`**

- At what spread level does force exercise become economically rational?
- Force exercise cost = 30 bps of notional (in-range).
- Premium at max spread: ~2.125× base premium.
- If premium earned by exercisor exceeds 30 bps cost through arbitrage: exercise is rational.
- At typical premium levels (10–50 bps for short-dated options), force exercise is rational when spread > ~3–5× and price movement creates a favorable reversal opportunity.

**11. `BP_DECREASE_BUFFER` + `SELLER_COLLATERAL_RATIO`**

- At base SCR (20%): init-maint gap = 20% × 6.67% = **1.33% of notional**.
- At saturated SCR (100%): gap = 100% × 6.67% = **6.67% of notional**.
- The gap scales with SCR, which is correct — higher-risk environments (high utilization) get more buffer.

**12. `MAX_BONUS` + `SELLER_COLLATERAL_RATIO`**

- At base SCR: position has 20% margin. If it goes 10% underwater: balance = 10% of notional. Bonus = min(10% × 20%, 10%) = min(2%, 10%) = 2%.
- Liquidator profit = 2% of notional - gas. On L2, profitable for any meaningful position size.
- **At saturated SCR (100%):** Position has 100% margin. If it goes 10% underwater: balance = 90% of notional. Bonus = min(90% × 20%, 10%) = min(18%, 10%) = 10%. Very profitable.
- **Finding:** The bonus is always profitable for the liquidator as long as the position is not fully underwater AND gas < bonus. Sound design.

### E.3 "Safe Alone, Unsafe in Combination"

**Critical regime:** Low utilization (SCR = 20%) + init-maint gap (1.33%) + safe mode NOT active (check only 1 tick).

In this regime:

- Margin is thin (20%).
- The buffer before liquidation trigger is 1.33% of notional (~2.67% price move for delta-0.5).
- Solvency is checked at only 1 tick (spotEMA).
- If the spotEMA lags an actual price move, the 1-tick check may not reflect the true position value.
- A ~3% move in under 60s could push a position past the init-maint gap before solvency checks detect it.

**Mitigant:** The Euclidean norm check in `getSolvencyTicks()` provides a secondary trigger independent of safe mode. If the 3D vector of tick deviations exceeds 724, all 4 ticks are checked even without safe mode. The 16/15 buffer also maps cleanly to lending: 90.9% LTV → 85% LLTV, a well-understood margin of safety.

---

## F) Launch Readiness Verdict

### **YELLOW** — Launchable with monitoring and guardrails.

### Top 5 Launch Risks

| #   | Risk                                                         | Parameters                                                | Why It Matters                                                                                                                                                                                           | Confirming/Falsifying Metric                                                                                                                                                                               |
| --- | ------------------------------------------------------------ | --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Safe mode detection lag for sustained medium-speed moves** | MAX_TICKS_DELTA (724), EMA_PERIODS                        | Instant crashes >7.5% now trigger safe mode immediately (improved from 10%). Linear 8-12% moves over 60-90s may still not trigger via EMA conditions; the Euclidean norm backstop partially covers this. | **Monitor:** safe mode activation count vs. actual volatility events. **Falsify:** if 8%+ moves consistently trigger safe mode within 30s, this concern is invalidated.                                    |
| 2   | **Init-maint gap at low utilization**                        | BP_DECREASE_BUFFER (16/15), SELLER_COLLATERAL_RATIO       | 1.33% of notional gap at base SCR means a ~2.67% move for delta-0.5 positions crosses from init to maint margin. Adequate on L2 with responsive bots. Maps to 90.9% LTV → 85% LLTV for loans.            | **Monitor:** liquidation shortfall rate (fraction of liquidations with protocol loss). **Target:** <1% of liquidations should result in protocol loss.                                                     |
| 3   | **Taylor compounding error at extreme rates + inactivity**   | wTaylorCompounded, IRM_MAX_ELAPSED_TIME                   | At 800% effective rate, >1% error requires ~24 days idle; at 200% effective, ~97 days. Punitive rates make such inactivity implausible. Low practical risk.                                              | **Monitor:** max deltaTime between interactions per pool. **Alert:** if any pool exceeds 7 days without interaction at >100% rate.                                                                         |
| 4   | **Utilization-at-mint allows stale SCR**                     | TARGET_POOL_UTIL, SATURATED_POOL_UTIL, globalUtilizations | Positions minted at low utilization retain low SCR permanently. A utilization surge doesn't retroactively increase margin requirements for these positions.                                              | **Monitor:** distribution of utilization-at-mint for open positions vs. current utilization. **Alert:** if >20% of open interest was minted at <TARGET_POOL_UTIL while current util > SATURATED_POOL_UTIL. |
| 5   | **MAX_BONUS may be insufficient for small positions on L1**  | MAX_BONUS                                                 | 20% of a small balance may not cover liquidation gas on L1. Unprofitable liquidations lead to delayed cleanup and growing protocol loss.                                                                 | **Monitor:** position size distribution. **Alert:** if median position size yields bonus < estimated liquidation gas cost.                                                                                 |

---

## G) Recalibration Recommendations

### G.1 BP_DECREASE_BUFFER (Risk #2) — RESOLVED

**Updated to:** 10,666,667 (16/15 = 6.67% over maintenance).

**Rationale:** At base utilization, loan maintenance margin is 10% (90.9% LTV). With the 16/15 buffer, the LLTV becomes 85% — a clean, recognizable lending boundary. The liquidation reaction window at base SCR is now 1.33% of notional (~2.67% price move for delta-0.5), adequate for L2 with responsive bots.

**Assessment:** Appropriate for launch. No further change needed.

### G.2 Taylor Error Mitigation (Risk #3) — DOWNGRADED

After correcting the unit conversion, the >1% error crossover requires ~24 days of inactivity at the maximum effective rate (800%) or ~97 days at 200%. At such punitive rates, pool inactivity for weeks is economically implausible. **No code change recommended.** Monitor pool interaction frequency post-launch as a precaution.

### G.3 Safe Mode Sensitivity (Risk #1) — PARTIALLY RESOLVED

**Updated to:** MAX_TICKS_DELTA = 724 (~7.5%).

**Improvement:** Instant crashes >7.5% now trigger safe mode immediately (previously required >10%). The internalDisagreement and highDivergence thresholds also tighten to 362 ticks (~3.7%). The Euclidean norm backstop triggers at 724² = 524,176 (more sensitive than prior 908,209).

**Remaining concern:** Linear moderate-speed moves (8-12% over 60-90s) may still not trigger via EMA conditions alone. The Euclidean norm check partially covers this. Monitor post-launch.

**Future option if needed:** Add a raw tick-change-rate check (|currentTick - latestTick| > threshold) independent of EMA smoothing.
**Timing:** Post-launch monitoring; further tightening only if data warrants it.
**Mutability:** Constant — would require redeployment.

### G.4 Utilization-at-Mint Monitoring (Risk #4)

No parameter change recommended — this is an intentional design choice that prevents cascading liquidations. However, implement a monitoring dashboard that tracks the gap between utilization-at-mint and current utilization for all open positions. If the gap exceeds 30pp for a significant portion of open interest, consider adding a "utilization refresh" mechanism in a future version.

**Timing:** Post-launch monitoring only.

---

## H) Validation Plan

### H.1 Deterministic Boundary Tests

| Test                    | Parameters              | Boundary Values                                                            |
| ----------------------- | ----------------------- | -------------------------------------------------------------------------- |
| Safe mode trigger       | MAX_TICKS_DELTA         | currentTick - spotEMA = 724 (no trigger), 725 (trigger), 726 (trigger)     |
| SCR ramp start          | TARGET_POOL_UTIL        | utilization = 6666 (base SCR), 6667 (ramp starts)                          |
| SCR ramp end            | SATURATED_POOL_UTIL     | utilization = 8999 (ramp), 9000 (100% SCR)                                 |
| Cross buffer cutoff     | CROSS_BUFFER            | utilization = 9499 (small buffer), 9500 (zero)                             |
| IRM cap                 | IRM_MAX_ELAPSED_TIME    | elapsed = 16383 (used), 16384 (capped), 16385 (capped)                     |
| rateAtTarget bounds     | MIN/MAX_RATE_AT_TARGET  | startRate approaching 0 → floors at MIN; startRate very high → caps at MAX |
| MAX_BONUS cap           | MAX_BONUS               | balance × 20% < shortfall vs > shortfall                                   |
| Loan exclusion in bonus | MAX_BONUS + loanAmounts | bonus/MAX_BONUS × DECIMALS + loan > balance                                |

### H.2 Scenario Tests (Foundry)

1. **Liquidation cascade test:** Create 10 positions at different utilization levels. Crash price 15%. Verify all underwater positions are liquidatable and protocol loss is bounded.
2. **IRM convergence test:** Set utilization to 100% for 1 week. Verify rateAtTarget converges toward MAX_RATE_AT_TARGET. Then set utilization to 0% for 1 week. Verify it converges toward MIN_RATE_AT_TARGET.
3. **Taylor accuracy test:** Fork test: compare `wTaylorCompounded(rate, time)` against an exact `exp(rate*time) - 1` implementation for time values [1s, 1h, 1d, 1w, 1m] at rates [0.1%, 4%, 100%, 800%].
4. **Cross-buffer decay test:** Set utilization at 89%, 90%, 92%, 95%, 96%. Verify cross-buffer ratio matches expected values.
5. **Safe mode flap test:** Oscillate price ±7% with 3-minute period for 1 hour. Count safe mode transitions. Expected: very few or zero.
6. **Max legs gas test:** Create a position with 26 legs. Trigger solvency check in safe mode (4 ticks). Measure gas. Ensure it fits within L2 block gas limits.

### H.3 Pre-Launch Simulation

**Input distributions:**

- Price: GBM with σ = 50–100% annualized, with occasional 10–20% jumps (Poisson process, λ = 0.5/day)
- Utilization: Mean-reverting around 60%, σ = 15%
- Position sizes: Log-normal, median = $1,000, range $100–$1M
- Liquidation bot latency: Uniform [2s, 60s]

**Target metrics:**

- Protocol loss rate < 0.5% of total notional per year
- Liquidation shortfall rate < 2% of liquidations
- Safe mode duty cycle < 5% of time
- IRM rate volatility (30-day rolling σ of log rate) < 100%

### H.4 Live Monitoring Invariants

| Invariant                       | Alert Threshold                                                           |
| ------------------------------- | ------------------------------------------------------------------------- |
| Solvency consistency            | Any account with negative margin after solvency check passes              |
| Liquidation shortfall frequency | >5% of liquidations result in protocol loss in a 24h window               |
| Safe mode duty cycle            | >20% of blocks in safe mode over 1h window                                |
| Rate volatility                 | rateAtTarget changes by >50% in a single update                           |
| Interest accrual gap            | Any pool without interest accrual for >6 hours while rate > 50%           |
| Utilization divergence          | >30% of open interest at utilization-at-mint diverging >25pp from current |
| Cross-buffer exhaustion         | Cross-buffer at 0 for any token while open interest exists                |

---

## I) Comparative Benchmarking

### I.1 IRM Comparison

| Parameter          | Panoptic V2    | Morpho Blue       | Aave V3 (USDC)       | Euler V2      |
| ------------------ | -------------- | ----------------- | -------------------- | ------------- |
| Curve steepness    | **4×**         | 4×                | ~20× above optimal   | Variable      |
| Target utilization | **66.67%**     | 90% (typical)     | 90%                  | Pool-specific |
| Min rate at target | **0.1%**       | 0.1%              | ~2%                  | Variable      |
| Max rate at target | **200%**       | 200%              | ~100%                | Variable      |
| Adjustment speed   | **50/year**    | 50/year           | Instant (jump model) | Gradual       |
| Max elapsed cap    | **4.55 hours** | None (continuous) | N/A (per-block)      | N/A           |

**Analysis:** Panoptic's IRM is closely derived from Morpho Blue's adaptive IRM with nearly identical parameters. The key difference is the lower target utilization (66.67% vs 90%), which reflects the options protocol's need to keep more liquidity available for the AMM. The `IRM_MAX_ELAPSED_TIME` cap is Panoptic-specific and prevents drift during inactivity — Morpho Blue doesn't need this because its interactions are more frequent.

The CURVE_STEEPNESS of 4× is moderate. Aave uses much steeper curves (~20× above optimal) to enforce a hard utilization ceiling. Panoptic's gentler curve relies more on the adaptive speed to find the right rate over time, rather than imposing an immediate penalty.

### I.2 Collateral Ratios

| Protocol        | Short Option Margin         | Long Option Margin | Margin Model                          |
| --------------- | --------------------------- | ------------------ | ------------------------------------- |
| **Panoptic V2** | **20% base, ramps to 100%** | **10% fixed**      | Continuous settlement, util-dependent |
| Opyn (Squeeth)  | 150%+                       | N/A (perp model)   | Over-collateralized                   |
| Lyra V2         | 100–200%                    | Variable           | Portfolio margin                      |
| Aevo            | 10–50% (centralized)        | 10–50%             | Off-chain risk engine                 |

**Justification for Panoptic's lower margin:** Panoptic's 20% base SCR is justified by:

1. **Continuous premium settlement** — no expiration cliff; losses are settled gradually.
2. **Utilization-dependent ramp** — SCR increases to 100% as risk concentrates.
3. **Cross-collateral buffer** — surplus in one token supports the other.
4. **Liquidation mechanism** — bots can liquidate at any time.

This justification **holds provided liquidation latency is consistently <30 seconds** (see Risk #2). If liquidation delays occur, the 20% base SCR may be insufficient for fast-moving markets.

### I.3 Oracle Manipulation Cost

**Capital needed to move price by MAX_TICKS_DELTA (724 ticks ≈ 7.5%):**

For a Uniswap V4 pool, the manipulation cost scales with TVL and concentrated liquidity depth. Rough estimates:

| Pool TVL | Estimated Manipulation Cost (7.5% move) | Sustained Duration           |
| -------- | --------------------------------------- | ---------------------------- |
| $1M      | ~$100K                                  | Single block (not sustained) |
| $10M     | ~$1M                                    | Single block                 |
| $100M    | ~$10M                                   | Single block                 |

These are single-block manipulation costs (before arbitrage reverts the price). The EMA-based oracle design means a single-block manipulation of 7.5% would be smoothed over 60s (spot EMA period), reducing its impact on solvency ticks to ~16.7% of the raw manipulation on the first block. To sustain a manipulation through the EMA, the attacker would need to hold the price for multiple blocks, increasing cost proportionally.

**Assessment:** For pools with >$10M TVL, oracle manipulation of sufficient magnitude to bypass safe mode is economically infeasible. For smaller pools ($1M), the cost is still significant (~$100K) but not prohibitive for well-funded attackers. **[ASSUMPTION-SENSITIVE]** — small-pool deployment should consider tighter thresholds or higher CROSS_BUFFER values.

### I.4 Fee Structure

| Protocol        | Trading Fee                  | Premium Fee         | Builder Incentive     |
| --------------- | ---------------------------- | ------------------- | --------------------- |
| **Panoptic V2** | **1 bps mint, ≤10 bps burn** | **1% of premium**   | **40% of commission** |
| Lyra V2         | 5–15 bps                     | None (spread-based) | No                    |
| Aevo            | 3–5 bps                      | None                | Referral program      |
| Opyn            | 0 (Uniswap pool fees only)   | N/A                 | No                    |

Panoptic's fee structure is competitive. The 1 bps mint fee is among the lowest. The builder split creates a referral incentive without increasing user costs (due to the 10% rebate).

### I.5 Init-Maint Buffer Comparison

| Protocol        | Init-Maint Gap                           | Equivalent Price Buffer    |
| --------------- | ---------------------------------------- | -------------------------- |
| **Panoptic V2** | **6.67% of maintenance (16/15)**         | **1.33–6.67% of notional** |
| Aave V3         | LTV/LT gap: typically 5–10%              | 5–10% of collateral value  |
| Euler V2        | Buffer fraction: ~5%                     | ~5%                        |
| Morpho Blue     | No explicit buffer (liquidatable at LTV) | 0%                         |

Panoptic's 6.67% buffer is in line with Aave's 5–10% LTV/LT gap and more conservative than Morpho Blue (none). The 16/15 ratio was chosen so that loans (10% maint margin = 90.9% LTV) map to an 85% LLTV — a clean, well-understood lending boundary.

---

## Changes Since V1

This is V2 of the parameter review. The following parameter changes are reflected since the V1 review (`RISK_ENGINE_PARAMETER_REVIEW.md`):

| Change                                         | Commit     | Detail                                                     |
| ---------------------------------------------- | ---------- | ---------------------------------------------------------- |
| Reduced FORCE_EXERCISE_COST                    | `c3e6c988` | Lowered force exercise fee (from prior value to 30 bps)    |
| Reduced MAINT_MARGIN_RATE                      | `c3e6c988` | Lowered loan margin (from prior value to 10%)              |
| Reduced PROTOCOL_SPLIT + BUILDER_SPLIT         | `c3e6c988` | Lowered protocol-builder fee split (now 50%/40%, sum 90%)  |
| Utilization-dependent margin for loans         | `b3f5a0a4` | MAINT_MARGIN_RATE now uses `_sellCollateralRatio()` ramp   |
| Added MAX_BONUS constant                       | `df8e9362` | New 20% cap on liquidation bonus                           |
| Clamped bonus to exclude loan-inflated balance | `19a52902` | Prevents over-rewarding liquidators on borrowed collateral |
| **Reduced MAX_TICKS_DELTA**                    | pending    | 953 → 724 ticks (~10% → ~7.5%); tighter safe mode trigger  |
| **Increased BP_DECREASE_BUFFER**               | pending    | 25/24 → 16/15 (4.17% → 6.67%); loan LTV 90.9% → LLTV 85%   |

---

> **Reviewed at:** `feat/parameters` @ `c3e6c988` > **Review model:** Claude Opus 4.6 (1M context)
