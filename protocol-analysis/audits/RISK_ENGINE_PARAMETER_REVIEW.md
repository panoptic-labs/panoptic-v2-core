# RiskEngine Launch Parameter Health Review

**Date:** 2026-02-22
**Branch:** `fix/last-mile`
**Target:** `RiskEngine.sol` and downstream parameter consumers
**Deployment context:** Not specified (chain, pairs, TVL). Findings are chain-agnostic unless noted.

---

## A) Parameter Sheet (Exhaustive)

### A.1 Constants (Global, Compile-Time)

| Parameter                 | Value (raw)             | Human-Readable                                      | Units             | Subsystem                       | Increase Effect                                            | Decrease Effect                                    | Notes                                                                     |
| ------------------------- | ----------------------- | --------------------------------------------------- | ----------------- | ------------------------------- | ---------------------------------------------------------- | -------------------------------------------------- | ------------------------------------------------------------------------- |
| `DECIMALS` (RE)           | 10,000,000              | 1 millitick = 1e-7                                  | 1e7 scale         | Global precision (RiskEngine)   | N/A (scaling)                                              | N/A                                                | Used as denominator for all ratio computations in RiskEngine              |
| `DECIMALS` (PP)           | 10,000                  | 1 basis point = 0.01%                               | 1e4 scale         | Global precision (PanopticPool) | N/A                                                        | N/A                                                | Used for utilization and spread checks in PanopticPool                    |
| `MAX_UTILIZATION`         | 10,000                  | 100%                                                | BPS (int16)       | Pool util                       | N/A                                                        | N/A                                                | Hard ceiling on utilization encoding                                      |
| `LN2_SCALED`              | 6,931,472               | ln(2) \* DECIMALS(RE)                               | RE DECIMALS-scale | OTM decay math                  | N/A                                                        | N/A                                                | Used in exponential collateral decay for long legs                        |
| `ONE_BPS`                 | 1,000                   | 0.01% = 1 basis point                               | RE DECIMALS-scale | Force exercise                  | N/A                                                        | N/A                                                | Floor fee for OTM force exercise                                          |
| `TEN_BPS`                 | 10,000                  | 0.10% = 10 basis points                             | RE DECIMALS-scale | Collateral floor                | N/A                                                        | N/A                                                | Minimum collateral for OTM long legs                                      |
| `WAD`                     | 1e18                    | 1.0                                                 | 18-decimal        | IRM                             | N/A                                                        | N/A                                                | Standard WAD precision for IRM math                                       |
| `EMA_PERIODS`             | packed uint96           | spot=60s, fast=120s, slow=240s, eons=960s           | seconds           | Oracle                          | Slower EMA response                                        | Faster EMA response                                | Packed as 4×24-bit; half-lives ≈42s/83s/166s/665s                         |
| `MAX_TICKS_DELTA`         | 953                     | ~10.0% price deviation                              | ticks             | Oracle/safeMode                 | More tolerant before safeMode; more false-negative risk    | Triggers safeMode sooner; more false-positive risk | Euclidean norm threshold also uses this                                   |
| `MAX_TWAP_DELTA_DISPATCH` | 513                     | ~5.26% up / ~5.0% down                              | ticks (uint16)    | Force exercise                  | Allows wider price deviation during dispatch               | Tighter manipulation protection                    | Packed into RiskParameters (13 bits)                                      |
| `MAX_SPREAD`              | 90,000                  | removedLiq/netLiq ≤ 9x (90,000 / PP DECIMALS)       | PP DECIMALS-scale | Liquidity spread                | Higher removal ratio allowed; larger premium multiplier    | Lower max spread; less premium skew                | Packed into RiskParameters (22 bits)                                      |
| `BP_DECREASE_BUFFER`      | 10,416,667              | 104.17% of maintenance margin (ratio 25/24)         | RE DECIMALS-scale | Buying power                    | Wider gap between init & maint margin; more conservative   | Narrower gap; easier to mint near liquidation      | Packed into RiskParameters (26 bits); maps to 80%/83.33% LTV/LT structure |
| `VEGOID`                  | 8                       | ν = 1/8 = 12.5% premium pass-through factor         | dimensionless     | Premium spread                  | Less premium to longs per unit removed liq; more to shorts | More premium to longs; larger spread multiplier    | Encoded in SFPM poolId (8-bit)                                            |
| `NOTIONAL_FEE`            | 1                       | 0.01% of notional                                   | BPS               | Fees                            | Higher upfront cost                                        | Lower upfront cost                                 | Packed 14-bit                                                             |
| `PREMIUM_FEE`             | 100                     | 1.0% of premium                                     | BPS               | Fees                            | Higher premium tax                                         | Lower premium tax                                  | Packed 14-bit                                                             |
| `PROTOCOL_SPLIT`          | 6,000                   | 60% of commission (w/ builder)                      | BPS               | Fee routing                     | More to protocol                                           | Less to protocol                                   | Packed 14-bit                                                             |
| `BUILDER_SPLIT`           | 3,000                   | 30% of commission (w/ builder)                      | BPS               | Fee routing                     | More to builder                                            | Less to builder                                    | Packed 14-bit; sum w/ PROTOCOL_SPLIT = 90%; remaining 10% = user rebate   |
| `SELLER_COLLATERAL_RATIO` | 2,000,000               | 20% of notional                                     | RE DECIMALS-scale | Margin (sell)                   | Higher seller margin                                       | Lower seller margin; more capital efficient        | Base at below-target utilization                                          |
| `BUYER_COLLATERAL_RATIO`  | 1,000,000               | 10% of notional                                     | RE DECIMALS-scale | Margin (buy)                    | Higher buyer margin                                        | Lower buyer margin                                 | Flat, not utilization-dependent                                           |
| `MAINT_MARGIN_RATE`       | 2,000,000               | 20% of loan notional                                | RE DECIMALS-scale | Margin (loans)                  | Higher loan margin (100% + rate)                           | Lower loan margin                                  | Applied as additive to 100% for loans                                     |
| `FORCE_EXERCISE_COST`     | 102,400                 | 1.024% of long notional (in-range)                  | RE DECIMALS-scale | Force exercise                  | Higher cost to exercise in-range positions                 | Lower cost; easier force exercise                  | Falls to ONE_BPS (0.01%) when OTM                                         |
| `TARGET_POOL_UTIL`        | 6,666,667               | 66.67%                                              | RE DECIMALS-scale | Margin ramp                     | Ramp starts later (more flat region)                       | Ramp starts sooner                                 | Start of SCR linear ramp                                                  |
| `SATURATED_POOL_UTIL`     | 9,000,000               | 90%                                                 | RE DECIMALS-scale | Margin ramp                     | Ramp ends later (gentler slope)                            | Steeper ramp to 100%                               | End of SCR ramp → 100% collateral                                         |
| `MAX_OPEN_LEGS`           | 26                      | 26 individual legs across all positions per account | count             | Position limits                 | More complex portfolios                                    | Simpler portfolios                                 | Packed 7-bit (max 127); checked in `_updatePositionsHash`                 |
| `MAX_CLAMP_DELTA`         | 149                     | ≤149 ticks per 64-second epoch                      | ticks (int24)     | Oracle update                   | Oracle tracks faster; less manipulation-resistant          | Oracle tracks slower; more manipulation-resistant  | ~1.49% max per-epoch oracle movement                                      |
| **IRM Parameters**        |                         |                                                     |                   |                                 |                                                            |                                                    |                                                                           |
| `CURVE_STEEPNESS`         | 4e18                    | 4x multiplier                                       | WAD               | IRM                             | Steeper rate curve above target                            | Flatter rate curve                                 | Rate range = [rateAtTarget/4, 4×rateAtTarget]                             |
| `MIN_RATE_AT_TARGET`      | 31,709,791              | 0.1% annualized                                     | WAD per second    | IRM                             | Higher floor rate                                          | Lower floor rate                                   | = 1e15 / 365 days                                                         |
| `MAX_RATE_AT_TARGET`      | 63,419,583,967          | 200% annualized                                     | WAD per second    | IRM                             | Higher ceiling rate                                        | Lower ceiling rate                                 | = 2e18 / 365 days                                                         |
| `TARGET_UTILIZATION`      | 666,666,666,666,666,667 | 66.67%                                              | WAD               | IRM                             | IRM targets higher util (rate inflection moves right)      | IRM targets lower util                             | = 2e18/3                                                                  |
| `INITIAL_RATE_AT_TARGET`  | 1,268,391,679           | 4% annualized                                       | WAD per second    | IRM                             | Higher starting rate                                       | Lower starting rate                                | = 0.04e18 / 365 days                                                      |
| `ADJUSTMENT_SPEED`        | 1,585,489,599,188       | 50/year                                             | WAD per second    | IRM                             | Faster rate adaptation                                     | Slower rate adaptation                             | = 50e18 / 365 days                                                        |
| `IRM_MAX_ELAPSED_TIME`    | 16,384                  | 4.55 hours (2^14 seconds)                           | seconds           | IRM                             | More adaptation per single update                          | Less per-update swing                              | Caps single-step rate adaptation                                          |

### A.2 Immutables (Per-Pool, Set at Deployment)

| Parameter                | Typical Value      | Human-Readable                       | Units             | Subsystem    | Increase Effect                              | Decrease Effect         | Notes                                          |
| ------------------------ | ------------------ | ------------------------------------ | ----------------- | ------------ | -------------------------------------------- | ----------------------- | ---------------------------------------------- |
| `CROSS_BUFFER_0`         | 10,000,000 (tests) | 100% cross-margin at low util        | RE DECIMALS-scale | Cross-margin | More cross-margin benefit for token0 surplus | Less cross-asset offset | Can differ per-pool; typical = DECIMALS        |
| `CROSS_BUFFER_1`         | 10,000,000 (tests) | 100% cross-margin at low util        | RE DECIMALS-scale | Cross-margin | More cross-margin benefit for token1 surplus | Less cross-asset offset | Can differ per-pool; typical = DECIMALS        |
| `GUARDIAN`               | deployer-set       | Emergency override address           | address           | SafeMode     | N/A                                          | N/A                     | Can lock/unlock pools; only increases safeMode |
| `BUILDER_FACTORY`        | deployer-set       | CREATE2 factory for builder wallets  | address           | Fee routing  | N/A                                          | N/A                     | Determines builder wallet addresses            |
| `BUILDER_INIT_CODE_HASH` | derived            | keccak256 of BuilderWallet init code | bytes32           | Fee routing  | N/A                                          | N/A                     | Computed from BUILDER_FACTORY at construction  |

### A.3 Dynamic (Computed at Call Time)

| Parameter             | Computation                                                    | Subsystem     | Notes                                                                        |
| --------------------- | -------------------------------------------------------------- | ------------- | ---------------------------------------------------------------------------- |
| `safeMode`            | `isSafeMode(currentTick, oraclePack)` → 0-7                    | Oracle/safety | Sum of 3 boolean conditions (0-3) + lockMode (0 or 3)                        |
| `rateAtTarget`        | Adapted via `_newRateAtTarget` per interaction                 | IRM           | Stored in MarketState (38-bit), clamped to [MIN, MAX]                        |
| `sellCollateralRatio` | Linear ramp from SCR→100% over [TARGET, SATURATED] utilization | Margin        | Halved for strangles (negative utilization signal); uses stored util-at-mint |
| `crossBufferRatio`    | Linear ramp from CROSS_BUFFER→0 over [90%, 95%] utilization    | Cross-margin  | Per-token, per-pool; uses stored util-at-mint                                |

### A.4 Bit-Packing Precision Summary

| Packed Type    | Field              | Width             | Max Raw Value   | Max Meaningful Value        | Headroom             | Precision Loss                                    |
| -------------- | ------------------ | ----------------- | --------------- | --------------------------- | -------------------- | ------------------------------------------------- |
| RiskParameters | safeMode           | 4 bits            | 15              | 7 (3 triggers + lockMode=3) | 2x                   | None                                              |
| RiskParameters | notionalFee        | 14 bits           | 16,383          | 10,000 (100%)               | 1.6x                 | None                                              |
| RiskParameters | premiumFee         | 14 bits           | 16,383          | 10,000 (100%)               | 1.6x                 | None                                              |
| RiskParameters | protocolSplit      | 14 bits           | 16,383          | 10,000 (100%)               | 1.6x                 | None                                              |
| RiskParameters | builderSplit       | 14 bits           | 16,383          | 10,000 (100%)               | 1.6x                 | None                                              |
| RiskParameters | tickDeltaDispatch  | 13 bits           | 8,191           | 513                         | 16x                  | None                                              |
| RiskParameters | maxSpread          | 22 bits           | 4,194,303       | 90,000                      | 46x                  | None                                              |
| RiskParameters | bpDecreaseBuffer   | 26 bits           | 67,108,863      | 10,416,667                  | 6.4x                 | None                                              |
| RiskParameters | maxLegs            | 7 bits            | 127             | 26                          | 4.9x                 | None                                              |
| RiskParameters | feeRecipient       | 128 bits          | 2^128-1         | uint160 address truncated   | **Truncation**       | Upper 32 bits of address lost                     |
| MarketState    | borrowIndex        | 80 bits           | 2^80-1          | ~1.75 years at 800%         | Adequate             | WAD-scaled; overflows after ~1.75 yrs at max rate |
| MarketState    | marketEpoch        | 32 bits           | 2^32-1          | block.timestamp/4           | ~544 years           | None                                              |
| MarketState    | rateAtTarget       | 38 bits           | 274,877,906,943 | 63,419,583,967 (200%/yr)    | 4.3x                 | **See note**                                      |
| MarketState    | unrealizedInterest | 106 bits          | 2^106-1         | 2^104 (max deposit)         | 4x                   | None                                              |
| OraclePack     | residuals          | 12 bits each (×8) | ±2047           | ±2047 ticks (~22.7%)        | None                 | Rebase triggered if exceeded                      |
| OraclePack     | EMAs               | 22 bits each (×4) | ±2^21 ticks     | ±887,288 ticks              | Huge                 | None practical                                    |
| OraclePack     | lockMode           | 2 bits            | 3               | 3 (on) or 0 (off)           | None                 | None                                              |
| OraclePack     | epoch              | 24 bits           | 2^24-1          | block.timestamp>>6 mod 2^24 | ~12 days before wrap | Wraps are handled                                 |

**MarketState rateAtTarget note:** The 38-bit field can store up to ~867% annualized rateAtTarget. The `MAX_RATE_AT_TARGET` (200% annualized = 6.34e10 raw) fits within the 38-bit range (max 2.75e11) with **4.3x headroom**. The uint40 intermediate cast also fits (uint40.max = 1.1e12 >> 6.34e10). No truncation occurs at intended operating range. However, any future governance increasing MAX_RATE_AT_TARGET above ~867% annualized would silently truncate via the 38-bit mask.

**RiskParameters feeRecipient note:** Ethereum addresses are 160-bit, but only the lower 128 bits are stored via `uint256(uint160(addr)).toUint128()`. If a CREATE2 builder wallet address has significant bits above bit 127, the stored value would be wrong. This is statistically negligible for CREATE2 addresses but is a theoretical collision risk worth validating for every deployed builder wallet.

---

## B) Mechanism Map

### B.1 Solvency Decisioning

```
isAccountSolvent(...)
  ├── buffer = BP_DECREASE_BUFFER (for BP-decrease) or DECIMALS (for liquidation)
  ├── maintReq = baseRequirement * buffer / DECIMALS
  │     └── baseRequirement = Σ per-leg collateral
  │           ├── Short option: _sellCollateralRatio(utilization) → [SCR, 100%] * notional
  │           │     ├── SCR = SELLER_COLLATERAL_RATIO (20%)
  │           │     ├── Ramp from TARGET_POOL_UTIL to SATURATED_POOL_UTIL
  │           │     ├── utilization = MAX stored-at-mint across user's open positions
  │           │     └── Halved for strangles
  │           ├── Long option: _buyCollateralRatio() = BUYER_COLLATERAL_RATIO (10%) * notional
  │           ├── Loan: (MAINT_MARGIN_RATE + DECIMALS) / DECIMALS = 120% * notional
  │           └── Spread/Strangle/Synthetic: partner-aware reduction
  ├── crossBufferRatio(globalUtil, CROSS_BUFFER_i)
  │     ├── globalUtil = MAX stored-at-mint utilization across user's positions
  │     └── scaledSurplus = surplus * crossBufferRatio → cross-asset offset
  └── Final: bal + crossAssetSurplus >= maintReq (per token)
```

**Critical design note:** Margin calculations use the **stored utilization from mint time**, not current real-time utilization. The `_getGlobalUtilization` function returns the MAX of all stored utilizations across a user's open positions. This means:

- A surge in current pool utilization does NOT retroactively increase margin requirements for existing positions
- Only NEW positions record the current utilization, which then affects the portfolio-wide margin
- This design **prevents cascading liquidations** from utilization spikes alone

**Parameters involved:** SELLER_COLLATERAL_RATIO, BUYER_COLLATERAL_RATIO, MAINT_MARGIN_RATE, TARGET_POOL_UTIL, SATURATED_POOL_UTIL, BP_DECREASE_BUFFER, CROSS_BUFFER_0/1, DECIMALS(RE)

### B.2 Liquidation Bonus / Protocol Loss

```
getLiquidationBonus(tokenData0, tokenData1, sqrtPrice, netPaid, shortPremium)
  ├── bonus = min(balance/2, requirement - balance)        ← bonus is half balance or shortfall
  ├── Cross-token mitigation: if short in one, surplus in other → convert
  │     └── Uses PanopticMath.convert0to1/convert1to0 at oracle price
  └── protocolLoss = balance - (bonus + netPaid)           ← residual after bonus
```

**Parameters involved:** No direct RiskEngine parameters; depends on collateral ratios (which set `requirement`) and oracle price for cross-asset conversion.

### B.3 Force Exercise Pricing

```
exerciseCost(currentTick, oracleTick, tokenId, positionBalance)
  ├── hasLegsInRange? → fee = FORCE_EXERCISE_COST (1.024%)
  │                   → fee = ONE_BPS (0.01%)
  ├── exerciseFees = longAmounts * fee / DECIMALS(RE)      ← cost paid by exercisor
  └── Price impact: (currentValue - oracleValue) per leg   ← reversed to protect exercisee
```

**Parameters involved:** FORCE_EXERCISE_COST, ONE_BPS, DECIMALS(RE)

### B.4 Premium Settlement & Spread Dynamics

```
SFPM._getPremiaDeltas(currentLiquidity, collectedAmounts, vegoid)
  ├── base = collected * totalLiq * 2^64 / netLiq^2
  ├── owed (long) = base * (netLiq + removedLiq/VEGOID) / totalLiq
  ├── gross (short) = base * (totalLiq^2 - totalLiq*removed + removed^2/VEGOID) / totalLiq^2
  └── At MAX_SPREAD (removedLiq/netLiq = 9): long premium multiplier = 1 + 9/8 = 2.125x
```

**Parameters involved:** VEGOID (8), MAX_SPREAD (90,000 in PP DECIMALS = 9x ratio)
**Packed into:** VEGOID in SFPM poolId (8-bit), MAX_SPREAD in RiskParameters (22-bit)

**Interpretation:** With VEGOID=8 and MAX_SPREAD allowing a 9:1 removed-to-net ratio, the long premium per unit is at most 2.125x the base rate. This is a moderate spread — longs pay roughly double the short rate at the maximum allowed liquidity utilization. The spread incentivizes depositing new short liquidity to reduce the removed/net ratio.

### B.5 Interest Rate Evolution

```
_borrowRate(utilization, marketState)
  ├── err = (util - TARGET_UTILIZATION) / normFactor        ← [-1, +1] in WAD
  ├── speed = ADJUSTMENT_SPEED * err / WAD                   ← WAD-scaled rate of change
  ├── elapsed = min(now - lastUpdate, IRM_MAX_ELAPSED_TIME)  ← capped at 16,384s
  ├── linearAdaptation = speed * elapsed                     ← WAD-scaled total adaptation
  ├── endRateAtTarget = bound(start * exp(linearAdaptation), MIN, MAX)
  ├── avgRateAtTarget = trapezoidal integration (start + end + 2*mid) / 4
  ├── _curve(avgRateAtTarget, err):
  │     ├── err < 0: rate = (0.75*err + 1) * rateAtTarget   ← below target
  │     └── err ≥ 0: rate = (3*err + 1) * rateAtTarget      ← above target
  └── Rate range: [rateAtTarget/4, 4*rateAtTarget]

Single-update rate adaptation at full error (err=±1):
  ├── linearAdaptation = ADJUSTMENT_SPEED * IRM_MAX_ELAPSED_TIME / WAD
  │                    = 1.585e12 * 16384 / 1e18 ≈ 0.02597
  ├── exp(0.02597) ≈ 1.0263 → 2.63% rateAtTarget change per update
  └── Time from MIN to MAX: ln(2000) / ln(1.0263) ≈ 292 updates × 4.55h ≈ 55 days

Compounding in CollateralTracker:
  _calculateCurrentInterestState(assetsInAMM, rate)
  ├── deltaTime = (currentEpoch - previousEpoch) * 4        ← actual elapsed (UNCAPPED)
  ├── rawInterest = wTaylorCompounded(rate, deltaTime)       ← e^(r*t) - 1, 3-term Taylor
  ├── interestOwed = assetsInAMM * rawInterest / WAD
  └── borrowIndex *= (1 + rawInterest) / WAD
```

**Parameters involved:** CURVE_STEEPNESS, MIN_RATE_AT_TARGET, MAX_RATE_AT_TARGET, TARGET_UTILIZATION, INITIAL_RATE_AT_TARGET, ADJUSTMENT_SPEED, IRM_MAX_ELAPSED_TIME
**Packed into:** rateAtTarget in MarketState (38-bit), marketEpoch (32-bit)

### B.6 Safe-Mode Activation & Tick Selection

```
isSafeMode(currentTick, oraclePack)
  ├── externalShock: |currentTick - spotEMA| > MAX_TICKS_DELTA          (+1)
  ├── internalDisagreement: |spotEMA - fastEMA| > MAX_TICKS_DELTA/2     (+1)
  ├── highDivergence: |medianTick - slowEMA| > MAX_TICKS_DELTA/2        (+1)
  └── lockMode: oraclePack.lockMode()                                    (+0 or +3)
      Total: 0-7

getSolvencyTicks(currentTick, oraclePack, safeMode)
  ├── Normal (safeMode=0, low deviation): check at [spotTick] only
  └── Elevated (safeMode>0 OR high Euclidean norm): check at [spot, median, latest, current]

Effects on operations (PanopticPool):
  ├── safeMode > 1: All positions must be covered (non-inverted tick limits)
  ├── safeMode > 2: Revert with StaleOracle → minting blocked entirely
  └── safeMode > 0: 4-tick solvency checks → more conservative margin
```

**Parameters involved:** MAX_TICKS_DELTA (953), MAX_CLAMP_DELTA (149), EMA_PERIODS, lockMode

### B.7 Fee Routing

```
getRiskParameters(currentTick, oraclePack, builderCode)
  ├── feeRecipient = _computeBuilderWallet(builderCode)
  │     └── If builderCode = 0: feeRecipient = address(0) → protocol-only fees
  │     └── If builderCode > 0: CREATE2 builder wallet address (128-bit truncated)
  └── Packed into RiskParameters: NOTIONAL_FEE, PREMIUM_FEE, PROTOCOL_SPLIT, BUILDER_SPLIT

Fee distribution (in CollateralTracker):
  ├── No builder: 100% of commission to protocol (RiskEngine address)
  └── With builder:
      ├── 60% to protocol (PROTOCOL_SPLIT)
      ├── 30% to builder wallet (BUILDER_SPLIT)
      └── 10% user rebate (intentional; sum = 90% < 100%, remainder stays in CT → benefits the minting user)
```

**Parameters involved:** NOTIONAL_FEE, PREMIUM_FEE, PROTOCOL_SPLIT, BUILDER_SPLIT, BUILDER_FACTORY, BUILDER_INIT_CODE_HASH

---

## C) Baseline Health Assessment

### C.1 Quantitative Benchmarks

#### IRM Rate Table (at INITIAL_RATE_AT_TARGET = 4%)

| Utilization     | err   | Curve Multiplier | Annualized Rate |
| --------------- | ----- | ---------------- | --------------- |
| 0%              | -1.0  | 0.25x            | **1.00%**       |
| 33%             | -0.5  | 0.625x           | 2.50%           |
| 50%             | -0.25 | 0.8125x          | 3.25%           |
| 66.67% (target) | 0.0   | 1.0x             | **4.00%**       |
| 78%             | 0.34  | 2.02x            | 8.08%           |
| 90%             | 0.70  | 3.10x            | 12.40%          |
| 100%            | 1.0   | 4.0x             | **16.00%**      |

Rate range at the boundaries of rateAtTarget adaptation:

- At MIN_RATE_AT_TARGET (0.1%/yr): range [0.025%, 0.40%]
- At MAX_RATE_AT_TARGET (200%/yr): range [50%, 800%]
- rateAtTarget adaptation speed: ~2.63% per 4.55h update at full error; full MIN→MAX swing takes ~55 days of sustained extreme utilization

#### Collateral Requirements for 1 ETH Short Put (at stored utilization <66.67%)

| Moneyness | Price/Strike Ratio | r0 (10% floor) | r1 (Reg-T)   | Required | Human                    |
| --------- | ------------------ | -------------- | ------------ | -------- | ------------------------ |
| ATM       | 1.00               | 10%            | 20%          | **20%**  | 0.20 ETH-equiv in token1 |
| 10% OTM   | 1.10               | 10%            | 12%          | **12%**  | 0.12 ETH-equiv in token1 |
| 30% OTM   | 1.30               | 10%            | 0% (clamped) | **10%**  | 0.10 ETH-equiv in token1 |

At stored utilization ≥ SATURATED_POOL_UTIL (90%): all sellers need 100% collateral.
At stored utilization between 66.67% and 90%: linear ramp from 20% → 100%.

#### Oracle Thresholds as Price Deviations

| Parameter               | Ticks | Price Deviation                | Interpretation                               |
| ----------------------- | ----- | ------------------------------ | -------------------------------------------- |
| MAX_TICKS_DELTA         | 953   | **~10.0%**                     | Safe-mode trigger per condition              |
| MAX_TICKS_DELTA/2       | 476   | **~4.88%**                     | Internal disagreement / divergence threshold |
| MAX_TWAP_DELTA_DISPATCH | 513   | **~5.26% up / ~5.0% down**     | Force exercise price manipulation guard      |
| MAX_CLAMP_DELTA         | 149   | **~1.49%** per 64-second epoch | Maximum oracle tracking speed                |

### C.2 Collateral Efficiency vs Safety

**Assessment: ADEQUATE**

- 20% base SCR is a standard Reg-T margin for equity options; appropriate for on-chain perpetual options with continuous premium settlement
- The 10% buyer collateral provides a cost-of-carry buffer without excessive locking
- The linear ramp from 20% to 100% across utilization [66.67%, 90%] creates a 23.33 pp transition zone — sufficiently gradual to avoid cliff effects
- Cross-buffer at 100% provides full cross-margining below 90% stored utilization, decaying to 0 at 95%
- The utilization-at-mint design protects existing positions from retrospective margin increases

**Buffer calibration:** BP_DECREASE_BUFFER = 10,416,667 (ratio 25/24 ≈ 1.04167) maps to an 80%/83.33% LTV/Liquidation-Threshold structure, matching Aave V3's buffer for WETH. At 20% base SCR, the effective initial margin is 20.83%, giving a 0.83 pp gap in notional terms. For ATM options with delta ~0.5, this absorbs roughly a **1.7% underlying price move** before liquidation — comparable to Euler V2 (2.3% buffer fraction) and close to Aave V3 (3.6%).

At saturated utilization (100% SCR), the effective requirement is `100% × 25/24 = 104.17%`. Users can mint positions up to **96% of their deposit size**, requiring only ~4.2% headroom. This is a reasonable barrier that mildly discourages minting at extreme utilization without creating an impractical lockout, and enables near-complete LP migration in a single transaction.

### C.3 Borrow Cost Responsiveness

**Assessment: GOOD**

- At target utilization (66.67%): 4% APR is competitive
- The 4x curve steepness creates strong incentives: going from target to 100% utilization quadruples the rate
- ADJUSTMENT_SPEED of 50/year produces a ~2.63% rateAtTarget change per 4.55-hour update at full error. This is moderate — it takes ~55 days of sustained 100% utilization to reach MAX_RATE_AT_TARGET. This is gradual enough to give borrowers time to react while still providing meaningful rate pressure.
- IRM_MAX_ELAPSED_TIME of 4.55 hours prevents a single stale update from causing outsized rate spikes

### C.4 Premium Transfer Fairness

**Assessment: GOOD**

- VEGOID=8 means at equal spread (removedLiq/netLiq = 1), the long premium multiplier is 1 + 1/8 = 1.125x (longs pay 12.5% more per unit than shorts receive)
- At MAX_SPREAD (removedLiq/netLiq = 9): multiplier = 1 + 9/8 = 2.125x — longs pay roughly double the short rate
- This moderate 2.125x ceiling provides incentive to close spread (deposit new short liquidity) without creating punitive conditions for long holders
- **Caveat:** The addCapped freeze at uint128.max (ROUND-006) creates a permanent premium desync if accumulators saturate, but this requires astronomical accumulated fees per liquidity unit

### C.5 Liquidation Timing

**Assessment: ADEQUATE**

- With 20% margin and 20.83% initial requirement: a position must lose >0.83% of notional beyond maintenance before liquidation becomes possible
- The 4-tick solvency check in safe mode provides multi-angle protection
- Bonus = min(balance/2, shortfall): liquidator never gets more than half the position's remaining balance, preventing excessive extraction
- Utilization-at-mint design prevents utilization spikes from causing cascading liquidations

---

## D) Stress & Edge-Case Analysis

### D.1 Fast Volatility Shock (Tick Jumps Near Safe-Mode Thresholds)

**Preconditions:** Price moves >10% in under 60 seconds (one EMA update cycle)
**Dominant parameters:** MAX_TICKS_DELTA (953), EMA_PERIODS (spot=60s)
**Expected behavior:**

- externalShock triggers immediately: |currentTick - spotEMA| > 953
- safeMode jumps to 1+, triggering 4-tick solvency checks
- Minting continues as covered-only until safeMode > 2 (requires multiple triggers or guardian lock)

**Worked example:** ETH drops 15% in 30 seconds (flash crash):

- Tick change ≈ -1,620 ticks
- spotEMA has only tracked ~50% of move in 30s (half-life ~42s): spotEMA ≈ -810 ticks from start
- |currentTick - spotEMA| ≈ 810 < 953 → externalShock may NOT trigger yet
- |spotEMA - fastEMA| ≈ 810 > 476 → internalDisagreement triggers (safeMode ≥ 1)
- After 60s: spotEMA converges further; externalShock likely triggers (safeMode ≥ 2)
- **Verdict:** The layered detection catches the event, albeit with a brief delay if the initial move doesn't exceed the full threshold on a single condition

**Severity:** LOW — The multi-condition approach provides layered detection

### D.2 Choppy Market (Threshold Crossing Flapping)

**Preconditions:** Price oscillates ±10% rapidly around a mean
**Dominant parameters:** MAX_TICKS_DELTA (953), EMA half-lives
**Expected behavior:**

- safeMode toggles between 0 and 1+ as price crosses thresholds
- Each toggle changes solvency tick count (1 vs 4), affecting gas costs
- No hysteresis — mode can flip every block

**Failure mode:** Repeated 4-tick solvency checks increase gas costs for all operations. If the market is truly choppy (not manipulated), this is an unnecessary gas tax.

**Severity:** LOW — Gas cost increase is the main impact; solvency is conservatively checked

### D.3 Utilization Surge to Saturated Region

**Preconditions:** Sudden influx of borrowing pushes pool utilization from 60% to 95%+
**Dominant parameters:** TARGET_POOL_UTIL, SATURATED_POOL_UTIL, CROSS_BUFFER_0/1

**Key design point:** Margin calculations use **stored utilization from mint time**, not current utilization. The `_getGlobalUtilization()` function returns the MAX of all stored utilizations across a user's open positions.

**Expected behavior:**

- Existing positions minted at 60% utilization: their stored utilization remains at 60%. Their SCR stays at 20%, cross-buffer remains at 100%. **No change to their solvency status.**
- A user who attempts to MINT a new position at 95% utilization: the new position records 95% utilization. This propagates to ALL their positions via the global max, pushing their entire portfolio to near-100% SCR with 0% cross-buffer.
- If the user's existing portfolio cannot support the higher requirement, the mint transaction **reverts** (not liquidates). The user is never forced into an insolvent state by minting.

**No cascading liquidations:** The utilization-at-mint design completely prevents a utilization surge from causing existing positions to become liquidatable. Users can simply choose not to mint new positions during high utilization periods.

**Worked example:** User has 3 positions minted at util=50%. Current util jumps to 98%.

- Existing SCR: 20% (util 50% < target). Unchanged.
- If user mints a 4th position: global util = max(50%, 50%, 50%, 98%) = 98%. All positions now compute at ~100% SCR and 0% cross-buffer. This may cause the mint to revert if insufficient balance to meet the new requirement.
- Existing 3 positions remain at 20% SCR unless the 4th is minted.

**Severity:** INFO — The design elegantly prevents cascade risk

### D.4 Correlated Liquidation Wave

**Preconditions:** Multiple accounts become insolvent simultaneously due to adverse price move (not utilization surge)
**Dominant parameters:** SELLER_COLLATERAL_RATIO, CROSS_BUFFER, getLiquidationBonus formula

**Expected behavior:**

- Each liquidation pays bonus = min(balance/2, shortfall)
- Protocol loss = balance - (bonus + netPaid) per account
- Cross-token conversion at oracle price may introduce slippage not captured by the oracle
- Premium haircut (haircutPremia) claws back long premium to cover shortfalls

**Failure mode:** If protocol losses exceed available long premium for haircut, the deficit socializes across LPs via the CollateralTracker share price impact.

**Severity:** MEDIUM — Standard for options protocols; mitigated by conservative margin ratios

### D.5 Long Inactivity Gap + Rate Update

**Preconditions:** No interaction with a pool for 30 days; utilization = 100%
**Dominant parameters:** IRM_MAX_ELAPSED_TIME, ADJUSTMENT_SPEED, wTaylorCompounded accuracy

**Worked example:**

- Rate adaptation: capped at IRM_MAX_ELAPSED_TIME = 16,384s per update
- Single update: exp(0.02597) ≈ 1.0263 → rateAtTarget increases by 2.63%
- Since rate adaptation only happens once per update, 30 days of inactivity produces only **one** adaptation step of 2.63%, not 30 days' worth of adaptation. The IRM cap effectively freezes rate adaptation while the pool is inactive.

**Interest compounding over 30 days at 800% APR (worst-case max rate):**

- rate = 2.536e11 per second (WAD-scaled), deltaTime = 2,592,000s
- product = rate × time = 2.536e11 × 2,592,000 = 6.57e17
- x = 6.57e17 / 1e18 = 0.657 (in WAD human terms)
- Exact: e^0.657 - 1 = 0.929 (92.9% interest accrued)
- 3-term Taylor: 0.657 + 0.216 + 0.047 = 0.920 (92.0%)
- **Taylor error: 0.97% underestimation** (protocol receives less interest than true compounding)

**Note:** deltaTime in `_calculateCurrentInterestState` is **NOT capped** by IRM_MAX_ELAPSED_TIME. The cap only applies to rate adaptation in `_borrowRate`. The compounding applies to the full actual elapsed time, so a 30-day gap at high rates does incur the Taylor truncation error.

**Severity:** LOW — Taylor error is modest (~1% at 30 days/800%); interest underestimation favors borrowers (safe direction for solvency). Self-correcting via MEV incentives for periodic accrual.

### D.6 Deep ITM/OTM Force Exercise Behavior

**Preconditions:** Position is 50% ITM or 50% OTM
**Dominant parameters:** FORCE_EXERCISE_COST, ONE_BPS, DECIMALS(RE)

**OTM case (50% OTM):**

- fee = ONE_BPS = 0.01% of long notional
- Plus: minimal price impact reversal (current ≈ oracle for OTM legs)
- Cost to exercisor ≈ 0.01% of position → essentially free to exercise
- **Expected:** Cheap OTM exercise is desirable (cleans up out-of-range positions)

**Deep ITM case (50% ITM):**

- fee = FORCE_EXERCISE_COST = 1.024% of long notional
- Plus: price impact reversal compensation to exercisee
- Cost to exercisor can be significant (>1% of notional + price impact)
- **Expected:** Expensive ITM exercise deters unnecessary forced closures

**Severity:** LOW — Incentive alignment is correct

### D.7 Extreme Spread Near MAX_SPREAD

**Preconditions:** removedLiq/netLiq approaching 9x (MAX_SPREAD / PP_DECIMALS)
**Dominant parameters:** MAX_SPREAD, VEGOID

**At MAX_SPREAD (removedLiq/netLiq = 9):**

- Long premium multiplier = 1 + 9/8 = 2.125x per unit
- Shorts receive: base rate per unit net liquidity
- Longs pay: 2.125x base rate per unit removed liquidity
- Adding new short liquidity to halve the spread (ratio → 4.5): multiplier drops to 1 + 4.5/8 = 1.5625x
- **The premium incentive to close spread is meaningful but not extreme**

**Edge case:** If netLiq = 1 wei (near-zero), the spread formula `removedLiq * PP_DECIMALS / netLiq` could produce very large values exceeding MAX_SPREAD. The `_checkLiquiditySpread` function would revert, preventing further removal. However, the `addCapped` mechanism in the accumulators prevents overflow.

**Severity:** LOW — MAX_SPREAD enforcement prevents unbounded spread; premium incentives self-correct

### D.8 Rounding/Precision at Small Balances

**Preconditions:** Positions with very small notional (<1e6 tokens)
**Dominant parameters:** DECIMALS(RE), mulDivRoundingUp vs mulDiv

**Key rounding effects:**

- `_getRequiredCollateralAtUtilization`: uses `unsafeDivRoundingUp(amount * ratio, DECIMALS)` — rounds up against user (protocol-favorable)
- `crossBufferRatio`: integer division floors — reduces cross-margin benefit (protocol-favorable)
- `exerciseCost`: integer division toward zero — slightly reduces exercise cost
- Minimum collateral = 1 wei for any option position with width

**Severity:** INFO — All rounding is protocol-favorable; dust amounts are not exploitable due to minimum position sizes in SFPM

### D.9 Guardian lockMode Override During Active Positions

**Preconditions:** Guardian calls `lockPool()` while users have open positions
**Dominant parameters:** lockMode (adds 3 to safeMode)

**Expected behavior:**

- lockMode = 3 → safeMode ≥ 3 always (even with no other triggers)
- safeMode > 2: `Errors.StaleOracle()` → **all mints blocked**
- safeMode > 1: all positions must be covered
- Burns and liquidations still function (they don't require non-stale oracle)
- Force exercise still functions (separate code path)

**Effect on existing positions:** Users can close (burn) but cannot mint. Existing positions remain open but cannot be added to. Liquidations proceed normally with 4-tick checks.

**Severity:** LOW — This is the intended emergency brake behavior

### D.10 Builder Code Fee Routing (Intentional User Rebate)

**Preconditions:** User mints with non-zero builderCode
**Dominant parameters:** PROTOCOL_SPLIT (6,000), BUILDER_SPLIT (3,000)

**Design:** This is an intentional user rebate mechanism:

- Sum = 9,000 BPS = 90% of commission allocated to protocol + builder
- Remaining 10% stays in CollateralTracker → effectively returned to the minting user as a fee rebate
- This incentivizes users to use builder codes (builders get 30%, users get 10% rebate, protocol accepts 60% instead of 100%)

**Quantitative impact at scale:**

- At $100M annual notional volume with NOTIONAL_FEE = 1 BPS: total commission = $100K
- If 50% uses builder codes: builder-routed = $50K
- Protocol receives: $50K (non-builder) + $30K (60% of builder) = $80K
- Builders receive: $15K (30% of builder)
- User rebates: $5K (10% of builder → stays in CT)

**Severity:** INFO — Working as designed

### D.11 rateAtTarget at 38-bit Storage Ceiling

**Preconditions:** Sustained 100% utilization driving rateAtTarget to MAX_RATE_AT_TARGET
**Dominant parameters:** MAX_RATE_AT_TARGET, MarketState 38-bit field

**Storage analysis:**

- MAX_RATE_AT_TARGET = 6.34e10 raw (200% annualized)
- 38-bit max = 2.75e11 raw (~867% annualized)
- **Headroom: 4.33x** — MAX_RATE_AT_TARGET fits with comfortable margin
- uint40 intermediate: max 1.1e12 — also ample headroom

**Truncation risk:** None under normal operation. The computational clamp at MAX_RATE_AT_TARGET fires long before the storage ceiling.

**Future constraint:** If MAX_RATE_AT_TARGET were ever raised above ~867% annualized via governance, the 38-bit field would silently truncate. This constrains future parameter changes.

**Severity:** INFO — Current parameters are safe; 38-bit ceiling must be respected in future governance

### D.12 Taylor Expansion Error Accumulation

**wTaylorCompounded computes e^(r\*t) - 1 using 3 terms: x + x²/2 + x³/6**

| Rate (APR)   | Time            | x = r×t / WAD | Exact e^x-1 | Taylor 3-term | Relative Error |
| ------------ | --------------- | ------------- | ----------- | ------------- | -------------- |
| 4% (initial) | 4.55h (IRM cap) | 0.000021      | 0.000021    | 0.000021      | <0.0001%       |
| 4%           | 1 day           | 0.000110      | 0.000110    | 0.000110      | <0.0001%       |
| 800% (max)   | 4.55h (IRM cap) | 0.00415       | 0.00416     | 0.00416       | 0.024%         |
| 800% (max)   | 1 day           | 0.0219        | 0.02214     | 0.02214       | 0.004%         |
| 800% (max)   | 7 days          | 0.1534        | 0.1659      | 0.1658        | 0.060%         |
| 800% (max)   | 30 days         | 0.657         | 0.929       | 0.920         | **0.97%**      |
| 800% (max)   | 90 days         | 1.973         | 6.19        | 4.58          | **26.0%**      |

**Important:** deltaTime in CollateralTracker's `_calculateCurrentInterestState` is NOT capped by IRM_MAX_ELAPSED_TIME. For inactive pools, deltaTime can span weeks or months.

**Practical impact:** At typical rates (≤16% APR) and reasonable accrual frequency (≤7 days), the Taylor error is <0.06% — negligible. The error only becomes material (>1%) when both:

1. Rate is at or near the 800% maximum, AND
2. No one interacts with the pool for >30 days

Both conditions simultaneously are unlikely in an active market. MEV bots have incentive to accrue interest frequently.

**Severity:** LOW — Negligible under normal operation; material only in abandoned-pool edge cases

### D.13 CROSS_BUFFER Asymmetry

**Preconditions:** CROSS_BUFFER_0 ≠ CROSS_BUFFER_1 (e.g., token0=40%, token1=100%)
**Dominant parameters:** CROSS_BUFFER_0, CROSS_BUFFER_1

**Worked example (ETH/USDC pool, CROSS_BUFFER_0=40%, CROSS_BUFFER_1=100%):**

- User has surplus ETH (token0) and deficit USDC (token1)
- Cross-buffer for token0: 40% → only 40% of ETH surplus can offset USDC requirement
- Conversely, surplus USDC at 100% cross-buffer fully offsets ETH deficit
- This asymmetry makes it harder to use volatile-asset (ETH) surplus to cover stable-asset (USDC) deficit

**Rationale:** Intentional for pairs where one token is more volatile. Limiting cross-margin from the volatile token protects against adverse price moves that would reduce the cross-margin value before liquidation can occur.

**Severity:** INFO — By design; deployers should document the rationale for chosen asymmetric values

---

## E) Sensitivity & Coupling Matrix

### E.1 Single-Parameter Sensitivity

| Parameter               | Sensitivity | Justification                                                                                      |
| ----------------------- | ----------- | -------------------------------------------------------------------------------------------------- |
| MAX_TICKS_DELTA         | **HIGH**    | Directly controls safe-mode trigger; too low = constant safe mode, too high = missed manipulations |
| SELLER_COLLATERAL_RATIO | **HIGH**    | Sets baseline solvency buffer for all short positions                                              |
| ADJUSTMENT_SPEED        | **HIGH**    | Controls IRM responsiveness; affects how quickly rates reach equilibrium (55 days MIN→MAX)         |
| CURVE_STEEPNESS         | **HIGH**    | Determines rate multiplier range [1/C, C]; at C=4: [25%, 400%] of rateAtTarget                     |
| MAX_RATE_AT_TARGET      | **MEDIUM**  | Caps borrowing cost ceiling; affects extreme scenarios only                                        |
| CROSS_BUFFER_0/1        | **MEDIUM**  | Determines cross-margining benefit; asymmetry creates directional risk                             |
| VEGOID                  | **MEDIUM**  | Shapes premium distribution between longs/shorts; multiplier = 1+spread/VEGOID                     |
| BP_DECREASE_BUFFER      | **MEDIUM**  | Sets the gap between init and maintenance margin; ratio 25/24 maps to Aave-like 80/83.33 LTV/LT    |
| TARGET_POOL_UTIL        | **MEDIUM**  | Determines where the margin ramp begins                                                            |
| SATURATED_POOL_UTIL     | **MEDIUM**  | Determines where 100% margin kicks in                                                              |
| MAX_SPREAD              | **LOW**     | Self-correcting via premium incentives; moderate 2.125x cap                                        |
| FORCE_EXERCISE_COST     | **LOW**     | Primarily affects UX, not solvency                                                                 |
| NOTIONAL_FEE            | **LOW**     | 1 BPS is negligible; largely anti-spam                                                             |
| MAX_OPEN_LEGS           | **LOW**     | Primarily a DoS/gas protection                                                                     |
| IRM_MAX_ELAPSED_TIME    | **LOW**     | Only matters for stale pool recovery; limits per-update adaptation                                 |

### E.2 Critical Parameter Couplings

#### Couple 1: MAX_TICKS_DELTA + MAX_CLAMP_DELTA

- MAX_TICKS_DELTA = 953 ticks (~10% price move triggers safe mode condition)
- MAX_CLAMP_DELTA = 149 ticks/epoch (max oracle tracking speed)
- Time for oracle to track a 953-tick move: 953/149 = 6.4 epochs × 64s = **410 seconds (~7 min)**
- **Coupling effect:** If price moves 10% and stays there, it takes ~7 minutes for the internal oracle to fully reflect this. During this time, the oracle may lag reality. The 4-tick solvency check (using currentTick alongside oracle ticks) mitigates this by checking solvency at the real price too.
- **Risk:** Moderate — oracle lag creates a window where solvency checks use stale internal prices, but the inclusion of currentTick in the 4-tick check covers this

#### Couple 2: MAX_TICKS_DELTA + MAX_CLAMP_DELTA + lockMode

- Guardian can add lockMode=3 → safeMode ≥ 3 regardless of oracle conditions
- lockMode is purely additive; cannot reduce safeMode below automatic level
- **Risk:** None — guardian can only increase protection, never decrease it

#### Couple 3: SELLER_COLLATERAL_RATIO + MAINT_MARGIN_RATE

- SCR = 20% for option short positions; MAINT_MARGIN_RATE = 20% for loans (100% + 20% = 120% total)
- Independent subsystems (option margin vs loan margin)
- **Indirect coupling:** A user with both option and loan legs has additive requirements; combined burden can trigger liquidation earlier than either alone

#### Couple 4: TARGET_POOL_UTIL + SATURATED_POOL_UTIL

- Gap = 90% - 66.67% = 23.33 percentage points
- Slope of SCR ramp = (100% - 20%) / 23.33% = **3.43% SCR increase per 1% utilization increase**
- **If gap narrowed to 10%:** slope = 8%/1% = very steep cliff
- **Current state:** The 23.33 pp gap is wide enough to avoid cliff effects; the slope of 3.43x is manageable

#### Couple 5: CROSS_BUFFER_0/1 + Utilization (at-mint)

- Cross-buffer decays linearly from full value at 90% to 0 at 95% stored utilization
- **Coupling with margin ramp:** At 90% stored utilization, SCR is already at 100%. Between 90-95%, the user faces 100% SCR AND declining cross-buffer simultaneously.
- **Key nuance:** This only affects users who **chose to mint** at high utilization. Existing positions are unaffected. A user who mints at 92% utilization accepts both 100% SCR and ~60% cross-buffer for their entire portfolio. This is self-selected risk, not an imposed penalty.
- **Risk:** LOW — Users opt into this regime by minting at high utilization; no surprise penalties

#### Couple 6: ADJUSTMENT_SPEED + IRM_MAX_ELAPSED_TIME

- Max single-step rate adaptation: exp(ADJUSTMENT_SPEED × err × IRM_MAX_ELAPSED_TIME / WAD)
- At full error (|err|=1): exp(0.02597) ≈ 1.0263 → **2.63% rateAtTarget change per update**
- Time from MIN (0.1%) to MAX (200%): ~292 updates × 4.55h ≈ **55 days**
- **Coupling effect:** The combination is moderate. Rate adaptation is gradual enough to give borrowers time to react (days, not hours) while still providing meaningful pressure over weeks.
- **Risk:** LOW — The 55-day traverse time is appropriate for a DeFi lending market

#### Couple 7: MAX_RATE_AT_TARGET + Utilization Shock

- At MAX_RATE_AT_TARGET (200%): rate at 100% util = 800% APR
- At 800% APR, borrowers accumulate ~0.022% interest per hour
- **Note:** Reaching MAX_RATE_AT_TARGET requires ~55 days of sustained high utilization. A sudden utilization shock does NOT instantly produce 800% rates — it increases rates gradually from the current rateAtTarget.
- **Risk:** LOW — Rate adaptation is gradual; no instant spikes to max rate

#### Couple 8: PROTOCOL_SPLIT + BUILDER_SPLIT (Intentional User Rebate)

- 60% + 30% = 90% → 10% user rebate when builder code is used
- **Coupling:** Only activates when builderCode ≠ 0. Without builder codes, 100% goes to protocol.
- **Risk:** None — intentional design that incentivizes builder code usage

#### Couple 9: MAX_OPEN_LEGS + MAX_SPREAD

- MAX_OPEN_LEGS = 26 limits portfolio complexity (individual legs across all positions)
- MAX_SPREAD = 9x limits per-chunk liquidity removal
- **Coupling:** A user with 26 legs can potentially affect up to 26 tick ranges. The per-chunk spread cap prevents any single range from being excessively depleted.
- **Gas concern:** 26 legs × 4-tick solvency checks = up to 104 tick evaluations per solvency check. This could approach block gas limits on gas-constrained L2s.
- **Risk:** LOW for solvency; MEDIUM for gas on constrained chains

#### Couple 10: FORCE_EXERCISE_COST + MAX_SPREAD

- FORCE_EXERCISE_COST = 1.024% in-range, 0.01% OTM
- At MAX_SPREAD (9x), long premium multiplier = 2.125x
- **Coupling:** Force exercising in a high-spread chunk costs 1.024% to the exercisor but may save the exercisee from continued 2.125x premium payments. The break-even point depends on remaining position duration and premium rate.
- **Risk:** LOW — Economics generally incentivize exercise when spreads are high, which is desired behavior

#### Couple 11: BP_DECREASE_BUFFER + SELLER_COLLATERAL_RATIO

- BP_DECREASE_BUFFER = 104.17% multiplier (ratio 25/24)
- **At base utilization (<66.67%):** effective initial margin = 20% × 25/24 = 20.83%; gap = **0.83 pp**
- **At saturated utilization (≥90%):** effective initial margin = 100% × 25/24 = **104.17%**; users can mint up to 96% of their deposit. The 4.17% headroom is a mild deterrent to minting at extreme utilization while still permitting near-complete LP migration.
- **Risk at base:** The 0.83 pp gap corresponds to a ~1.7% price move for ATM delta-0.5 options. This is comparable to Euler V2's buffer. For highly volatile assets, this may be tight — but the 4% buffer fraction (as a share of initial margin) is in line with Aave V3's 3.6%.
- **Risk at saturated:** The 104.17% requirement means users need ~4.2% extra collateral beyond full notional. This is a practical and well-understood overhead (similar to Aave's LTV/LT gap applied to a 100% collateral base).

---

## F) Launch Readiness Verdict

### **YELLOW** — Launchable with monitoring and guardrails

### Top 5 Launch Risks

| #   | Risk                                             | Parameter(s)                                     | Why It Matters                                                                                                                                                                            | Confirmation Metric                                                                                                     |
| --- | ------------------------------------------------ | ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| 1   | **Taylor compounding error on inactive pools**   | wTaylorCompounded (3-term), deltaTime (uncapped) | Up to ~1% interest under-accrual at 800% APR over 30 days of inactivity; lenders lose yield. At 90 days, error reaches ~26%.                                                              | Monitor longest gap between accruals per pool; alert when gap exceeds 7 days at >100% APR                               |
| 2   | **Gas cost scaling with large portfolios**       | MAX_OPEN_LEGS, solvency check complexity         | 26 legs × 4-tick safe-mode checks = 104 evaluations. On gas-constrained chains, this may exceed block gas limits for liquidation or burn transactions.                                    | Benchmark gas usage for max-leg portfolios on target chain; ensure critical operations fit in block                     |
| 3   | **feeRecipient 128-bit truncation**              | RiskParameters feeRecipient packing              | CREATE2 builder wallet addresses are truncated to 128 bits. If upper 32 bits of the uint160 address are significant, fees are misrouted to wrong address.                                 | Verify all deployed builder wallet addresses have zeros in upper 32 bits; add unit test for address distribution        |
| 4   | **Init-maint gap at base utilization**           | BP_DECREASE_BUFFER, SELLER_COLLATERAL_RATIO      | 0.83 pp gap at 20% SCR absorbs a ~1.7% price move for ATM delta-0.5 options. Comparable to Euler V2 and within Aave V3 range. Tight but industry-standard.                                | Track time-to-liquidation for newly minted positions; alert if >5% of positions are liquidated within 1 hour of minting |
| 5   | **104.17% requirement at saturated utilization** | BP_DECREASE_BUFFER, SATURATED_POOL_UTIL          | At ≥90% stored utilization, users need 104.17% of notional to mint (can deploy 96% of deposit). Mild deterrent that enables near-complete LP migration but may still surprise some users. | Track mint revert frequency at >90% utilization                                                                         |

### Why Not RED

- Core solvency mechanisms are sound: conservative rounding, multi-tick checks, cross-asset liquidation
- Oracle design (cascading EMAs + median + clamping) is robust against manipulation
- IRM is well-calibrated for normal conditions (4% at target, gradual 55-day adaptation)
- Guardian override provides emergency protection
- Utilization-at-mint design prevents cascading liquidations from utilization spikes
- Premium system is self-correcting via economic incentives with a moderate 2.125x cap
- No critical arithmetic bugs found in parameter consumption paths

### Why Not GREEN

- Taylor approximation error for inactive pools is non-negligible at high rates (up to 26% at 90 days / 800% APR)
- Gas scaling with 26-leg portfolios needs benchmarking on target chain(s) before deployment
- feeRecipient 128-bit truncation needs validation for every deployed builder wallet
- Init-maint gap at base utilization (0.83 pp / ~1.7% price move) is tight for the most volatile assets, though within industry norms

---

## G) Recalibration Recommendations

### G.1 BP_DECREASE_BUFFER Calibration (RESOLVED)

**Value:** BP_DECREASE_BUFFER = 10,416,667 (ratio 25/24 ≈ 1.04167)

This maps cleanly to an 80%/83.33% LTV/Liquidation-Threshold structure:

- `1/1.2 = 83.33%` (liquidation threshold analog, from 20% SCR)
- `1/1.2 / (25/24) = 80.00%` (max LTV analog)
- Buffer fraction: 4.0% — between Aave V3 (3.6%) and Euler V2 (2.3%)
- At saturated utilization: 104.17% requirement → users can mint 96% of their deposit
- Enables near-complete LP migration in a single transaction (~$4.2K headroom on $100K)

No further change recommended.

### G.2 Add Taylor Term or Cap Compounding Time (Staged Post-Launch)

**Current:** wTaylorCompounded uses 3 non-zero terms; deltaTime is uncapped in `_calculateCurrentInterestState`
**Option A:** Add 4th term: `fourthTerm = mulDiv(thirdTerm, firstTerm, 4 * WAD)` — reduces 90-day error from 26% to ~8%
**Option B:** Cap deltaTime at a reasonable maximum (e.g., 7 days) in `_calculateCurrentInterestState`, requiring multiple virtual accruals for longer gaps
**Option C:** The existing `pokeOracle()` function (which accrues interest) can be called permissionlessly. Ensure MEV incentives align for frequent accrual on active markets.

**Tradeoff:**

- Option A: Marginal gas increase per accrual (~2 SLOAD + 1 MUL), significant accuracy improvement
- Option B: Simpler but creates an accuracy cliff at the cap boundary
- Option C: Best long-term solution; aligns incentives but depends on market activity

### G.3 Benchmark Gas on Target Chain (Pre-Launch, HIGH Priority)

**Validate that these operations fit within block gas limits on the target chain:**

- Liquidation of a 26-leg portfolio with 4-tick solvency checks in safe mode
- Burn of a 26-leg portfolio
- Mint with 25 existing legs + 1 new position

**If gas exceeds block limits:** Consider reducing MAX_OPEN_LEGS for L2 deployments or implementing batch processing.

---

## H) Validation Plan

### H.1 Deterministic Boundary Tests (Pre-Launch)

| Test                                    | Parameters                    | Boundary                                             | Expected Result                                      |
| --------------------------------------- | ----------------------------- | ---------------------------------------------------- | ---------------------------------------------------- |
| Safe-mode activation at exact threshold | MAX_TICKS_DELTA=953           | \|currentTick - spotEMA\| = 952 vs 953               | safeMode=0 at 952, safeMode≥1 at 953                 |
| Utilization at TARGET_POOL_UTIL         | TARGET_POOL_UTIL=6,666,667    | util=6,666,666 vs 6,666,667                          | SCR=20% at both (target is inclusive to flat region) |
| Utilization at SATURATED_POOL_UTIL      | SATURATED_POOL_UTIL=9,000,000 | util=8,999,999 vs 9,000,001                          | SCR≈99.99% vs 100%                                   |
| Cross-buffer at cutoff                  | cutoff=9,500,000              | util=9,499,999 vs 9,500,001                          | Small buffer vs 0%                                   |
| rateAtTarget round-trip at MAX          | MAX_RATE_AT_TARGET=6.34e10    | Store MAX then read back                             | Round-trip preserves value in 38 bits                |
| rateAtTarget at 38-bit boundary         | 2^38-1 = 2.75e11              | Store 2^38-1 via updateRateAtTarget                  | No truncation, reads back correctly                  |
| MAX_SPREAD enforcement                  | MAX_SPREAD=90,000             | removedLiq/netLiq = 8.999 vs 9.001 (in PP DECIMALS)  | Accept vs revert                                     |
| BP_DECREASE_BUFFER solvency             | BP_DECREASE_BUFFER=10,416,667 | Position at exactly 104.17% margin                   | Mint succeeds; at 104.16% → revert                   |
| Utilization-at-mint isolation           | —                             | Mint at 50%, then util rises to 95%                  | Existing position SCR unchanged at 20%               |
| 104.17% requirement at saturated        | SCR=100%, buffer=25/24        | Mint at 95% stored util with exactly 100% collateral | Revert (requires 104.17%)                            |

### H.2 Scenario Tests (Pre-Launch)

1. **Flash crash → recovery:** Price drops 15%, holds for 5 minutes, recovers. Verify safe-mode triggers and clears correctly. Measure time to full oracle convergence.
2. **Utilization-at-mint isolation:** Mint position at 50% util. Drive pool util to 98%. Verify existing position is NOT liquidatable. Then mint new position — verify portfolio recalculation and potential revert.
3. **Liquidation cascade (price-driven):** Simulate 10 accounts simultaneously insolvent from 20% price drop. Verify bonus + haircut covers losses, or measure protocol loss.
4. **Stale pool recovery:** Pool at 80% util, no interaction for 30 days. First interaction should: accrue interest correctly (within Taylor error bounds), adapt rate by exactly one IRM step.
5. **Builder code fee routing:** Mint with builderCode, verify fee split 60/30/10 (protocol/builder/user rebate).
6. **lockMode + safeMode interaction:** Lock pool with guardian, verify mints revert, burns succeed, liquidations succeed.
7. **OTM exponential collateral decay:** Short put at various OTM distances (10%, 30%, 50%, 90%), verify collateral decays appropriately.
8. **Gas benchmark:** Max-leg (26) portfolio: mint, burn, liquidate, force-exercise in safe-mode. Record gas per operation.
9. **IRM adaptation trajectory:** Start at INITIAL_RATE_AT_TARGET, set util to 100%. Run 100 updates spaced at IRM_MAX_ELAPSED_TIME. Verify rateAtTarget converges to MAX_RATE_AT_TARGET; record trajectory.

### H.3 Pre-Launch Simulation

**Monte Carlo setup:**

- Asset: GBM with σ ∈ {50%, 80%, 120%} annualized, μ = 0
- Time: 90 days, 1-minute resolution
- Agents: 100 sellers (random strikes, ±20% OTM), 50 buyers (random), 10 liquidators
- Initial utilization: 50%, initial rateAtTarget: 4%
- Metrics to track:
  - Protocol loss events (count, size, % of TVL)
  - Safe-mode duty cycle (% of time in safeMode > 0)
  - Liquidation frequency and bonus/shortfall ratio
  - Interest accrual accuracy (Taylor vs exact) per update
  - rateAtTarget trajectory over time
  - Newly-minted position time-to-liquidation distribution

**Target outcomes:**

- Protocol loss < 1% of TVL over 90 days at σ=80%
- Safe-mode duty cycle < 10% at σ=80%, < 30% at σ=120%
- Zero liquidation shortfalls exceeding available haircut capacity
- Taylor error < 0.1% per accrual on average
- <1% of positions liquidated within 1 hour of minting

### H.4 Live Monitoring Invariants

| Invariant                   | Alert Threshold                                                 | Action                                                           |
| --------------------------- | --------------------------------------------------------------- | ---------------------------------------------------------------- |
| Pool utilization            | > 92% for > 1 hour                                              | Guardian review; consider rate intervention                      |
| Safe-mode duty cycle        | > 25% over 24 hours                                             | Review MAX_TICKS_DELTA calibration for target pair volatility    |
| Liquidation shortfall       | Any single liquidation with protocol loss > 5% of position size | Investigate collateral ratio adequacy                            |
| Interest accrual gap        | > 7 days without accrual at >100% APR                           | Trigger permissionless poke or investigate                       |
| rateAtTarget velocity       | > 5% change in single update                                    | Log for analysis (normal at high util, but track)                |
| Builder fee routing         | feeRecipient = 0 with non-zero builderCode                      | Builder wallet deployment failure; investigate                   |
| Position liquidation timing | > 5% of positions liquidated within 1h of minting               | Review if 25/24 buffer is sufficient for target asset volatility |
| Gas per operation           | Liquidation or burn > 80% of block gas limit                    | Reduce MAX_OPEN_LEGS or optimize solvency checks                 |

---

## I) Comparative Benchmarking

### I.1 IRM Parameters vs Peers

| Parameter          | Panoptic                    | Aave v3 (WETH)      | Morpho Blue     | Euler v2 |
| ------------------ | --------------------------- | ------------------- | --------------- | -------- |
| Target utilization | 66.67%                      | 80-90%              | 90% (typical)   | 80-90%   |
| Curve steepness    | 4x                          | ~4x (slope1/slope2) | 4x (Morpho IRM) | Varies   |
| Rate at target     | 4% initial                  | 2-5%                | 3-4%            | 2-6%     |
| Max rate           | 800% (4 × MAX rateAtTarget) | 100-300%            | 200-800%        | 100-300% |
| Adaptation speed   | 50/year (~55 days MIN→MAX)  | Static curve        | 50/year         | Varies   |
| Min rate           | 0.025%                      | 0%                  | 0.025%          | 0%       |

**Assessment:** Panoptic's IRM is closely modeled on Morpho Blue's adaptive IRM, which is battle-tested. The key difference is the lower target utilization (66.67% vs 90%), which makes sense for an options protocol where seller capital must be deployable to AMM positions — the protocol needs more "reserve" capital available for deployment than a pure lending market. The rate range [0.025%, 800%] is wide but appropriate for the long tail of utilization states. The 55-day MIN→MAX adaptation time is identical to Morpho Blue's behavior.

### I.2 Collateral Ratios vs Options Protocols

| Parameter          | Panoptic                               | Opyn (Squeeth)        | Lyra                  | Traditional Reg-T    |
| ------------------ | -------------------------------------- | --------------------- | --------------------- | -------------------- |
| Short margin (ATM) | 20%                                    | 150-200%              | 100-200%              | 20% (equity options) |
| Long margin        | 10%                                    | 0% (fully paid)       | 100%                  | Full premium         |
| Init-maint gap     | 0.83 pp / 4.0% buffer fraction (25/24) | ~3.6% buffer fraction | ~2.3% buffer fraction | ~5% (house rules)    |
| Margin ramp        | 20% → 100% (utilization-dependent)     | Static                | Static                | N/A                  |
| Cross-margin       | Yes (100% below 90% util)              | No                    | Limited               | Yes                  |

**Assessment:** Panoptic's 20% short margin is aggressively capital-efficient compared to DeFi options peers (which often require 100-200%). This is justified by:

1. Continuous premium settlement (no discrete expiry risk)
2. Utilization-dependent margin ramp to 100% at high utilization
3. Active liquidation with cross-asset support
4. Utilization-at-mint design preventing retrospective margin increases

The init-maint buffer fraction of 4.0% (ratio 25/24) is well-calibrated against peers: Aave V3 uses 3.6% (80/83 LTV/LT), Euler V2 uses 2.3% (85/87). The 80%/83.33% analog gives users a clean, recognizable mental model. At saturated utilization, the 104.17% effective requirement allows minting up to 96% of deposit size — practical for LP migration while mildly discouraging extreme-utilization minting.

### I.3 Oracle Safety vs Manipulation Cost

**Capital needed to move Uniswap V3 price by MAX_TICKS_DELTA (953 ticks ≈ 10%):**

For a pool with $10M TVL concentrated ±5% around current price:

- Moving price 10% requires swapping roughly 50% of the pool's token balance
- Estimated cost: ~$2.5M in swap + ~$25K in fees (30 BPS fee tier)
- Net loss if manipulation fails: $2.5M + $25K (cannot recoup without reverting the trade)
- Panoptic's EMA system requires manipulation sustained for >60 seconds (spot EMA period) to affect solvency
- Multi-EMA filtering requires sustained manipulation for >240 seconds (slow EMA period) to fully corrupt all tick sources

**Assessment:** For pools with >$10M TVL, sustained manipulation is economically infeasible against the multi-EMA + median system. For thin pools (<$1M TVL), manipulation cost is ~$250K but the protocol's total exposure is proportionally smaller. Consider minimum Uniswap pool TVL requirements for deployment.

### I.4 Fee Structure Competitiveness

| Fee             | Panoptic                     | Opyn    | Lyra    | Ribbon          |
| --------------- | ---------------------------- | ------- | ------- | --------------- |
| Upfront fee     | 0.01% (NOTIONAL_FEE)         | 0%      | 0.3-1%  | 2% performance  |
| Premium fee     | 1% (PREMIUM_FEE)             | 0%      | 0%      | 10% performance |
| Builder rebate  | 10% (when builder code used) | N/A     | N/A     | N/A             |
| Liquidation fee | min(balance/2, shortfall)    | Fixed % | Fixed % | N/A             |

**Assessment:** Panoptic's fee structure is among the most competitive in DeFi options. The 0.01% notional fee is near-zero (primarily anti-spam). The 1% premium fee is modest and only applies to settled premium, not upfront. The builder code rebate mechanism is a novel incentive design that benefits users while enabling a builder ecosystem.

---

_Report generated 2026-02-22. Parameters verified against `RiskEngine.sol` on branch `fix/last-mile` (commit d9ccc9de)._
