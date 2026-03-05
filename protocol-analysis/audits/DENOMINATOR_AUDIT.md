# Denominator-Sensitivity Audit Report

**Date:** 2026-02-21
**Scope:** All files under `contracts/` (recursive)
**Auditor:** Automated security analysis

---

## A) Division Inventory (Non-Constant Denominators Only)

Constant denominators (DECIMALS, WAD, 2^64, 2^96, 2^128, 2^192, 10, 2, 4, 80000, etc.) are safe and omitted from detailed analysis.

### A1. SFPM Premium System

| #   | File:Line | Expression                                                      | Denominator        | Classification  |
| --- | --------- | --------------------------------------------------------------- | ------------------ | --------------- |
| 1   | SFPM:1337 | `mulDiv(collected0, totalLiquidity * 2**64, netLiquidity ** 2)` | `netLiquidity^2`   | STATE-DEPENDENT |
| 2   | SFPM:1342 | `mulDiv(collected1, totalLiquidity * 2**64, netLiquidity ** 2)` | `netLiquidity^2`   | STATE-DEPENDENT |
| 3   | SFPM:1354 | `mulDiv(premium0X64_base, numerator, totalLiquidity)`           | `totalLiquidity`   | STATE-DEPENDENT |
| 4   | SFPM:1357 | `mulDiv(premium1X64_base, numerator, totalLiquidity)`           | `totalLiquidity`   | STATE-DEPENDENT |
| 5   | SFPM:1377 | `mulDiv(premium0X64_base, numerator, totalLiquidity ** 2)`      | `totalLiquidity^2` | STATE-DEPENDENT |
| 6   | SFPM:1380 | `mulDiv(premium1X64_base, numerator, totalLiquidity ** 2)`      | `totalLiquidity^2` | STATE-DEPENDENT |

**Guard:** `currentLiquidity.rightSlot() > 0` at SFPM:1065 before `_collectAndWritePositionData` is called, which is the only path to `_getPremiaDeltas`. This guard ensures `netLiquidity > 0`, and since `totalLiquidity = netLiquidity + removedLiquidity >= netLiquidity > 0`, all six denominators are non-zero on the reachable path.

### A2. PanopticPool Premium & Settlement

| #   | File:Line | Expression                                                                                              | Denominator               | Classification  |
| --- | --------- | ------------------------------------------------------------------------------------------------------- | ------------------------- | --------------- |
| 7   | PP:1240   | `(grossCurrent0*posLiq + gPL.rightSlot()*totalLiqBefore) / totalLiquidity`                              | `totalLiquidity`          | STATE-DEPENDENT |
| 8   | PP:1248   | `(grossCurrent1*posLiq + gPL.leftSlot()*totalLiqBefore) / totalLiquidity`                               | `totalLiquidity`          | STATE-DEPENDENT |
| 9   | PP:1405   | `Math.max(...) / totalLiquidity`                                                                        | `totalLiquidity`          | STATE-DEPENDENT |
| 10  | PP:1422   | `Math.max(...) / totalLiquidity`                                                                        | `totalLiquidity`          | STATE-DEPENDENT |
| 11  | PP:2156   | `(removedLiquidity * DECIMALS) / netLiquidity`                                                          | `netLiquidity`            | STATE-DEPENDENT |
| 12  | PP:2222   | `((accum[0] - last.rightSlot()) * liquidity) / 2**64`                                                   | `2^64` (constant)         | CONSTANT        |
| 13  | PP:2272   | `((accum[0] - gPL.rightSlot()) * totalLiquidity) / 2**64`                                               | `2^64` (constant)         | CONSTANT        |
| 14  | PP:2282   | `(premOwed.rightSlot() * settled.rightSlot()) / (accumulated0 == 0 ? type(uint256).max : accumulated0)` | `accumulated0` (sentinel) | STATE-DEPENDENT |
| 15  | PP:2291   | `(premOwed.leftSlot() * settled.leftSlot()) / (accumulated1 == 0 ? type(uint256).max : accumulated1)`   | `accumulated1` (sentinel) | STATE-DEPENDENT |

### A3. CollateralTracker (ERC4626)

| #   | File:Line    | Expression                                                           | Denominator                   | Classification  |
| --- | ------------ | -------------------------------------------------------------------- | ----------------------------- | --------------- |
| 16  | CT:521       | `mulDiv(assets, totalSupply(), totalAssets())`                       | `totalAssets()`               | STATE-DEPENDENT |
| 17  | CT:528       | `mulDiv(shares, totalAssets(), totalSupply())`                       | `totalSupply()`               | STATE-DEPENDENT |
| 18  | CT:548       | `mulDiv(assets, totalSupply(), totalAssets())`                       | `totalAssets()`               | STATE-DEPENDENT |
| 19  | CT:606       | `mulDivRoundingUp(shares, totalAssets(), totalSupply())`             | `totalSupply()`               | STATE-DEPENDENT |
| 20  | CT:698       | `mulDivRoundingUp(assets, supply, totalAssets())`                    | `totalAssets()`               | STATE-DEPENDENT |
| 21  | CT:915-918   | `mulDivRoundingUp(userInterestOwed, totalSupply(), _totalAssets)`    | `_totalAssets`                | STATE-DEPENDENT |
| 22  | CT:936       | `mulDiv(userBalance, _totalAssets, totalSupply())`                   | `totalSupply()`               | STATE-DEPENDENT |
| 23  | CT:1086      | `mulDivRoundingUp(netBorrows, currentBI - userBI, userBorrowIndex)`  | `userBorrowIndex`             | STATE-DEPENDENT |
| 24  | CT:1175      | `mulDivRoundingUp(assetsInAMM+interest, DECIMALS, totalAssets())`    | `totalAssets()`               | STATE-DEPENDENT |
| 25  | CT:1216      | `mulDivRoundingUp(assetsInAMM+interest, WAD, totalAssets())`         | `totalAssets()`               | STATE-DEPENDENT |
| 26  | CT:1343      | `mulDivCapped(bonus, supply-liqBal, max(1, totalAssets()-bonus))`    | `max(1, totalAssets()-bonus)` | STATE-DEPENDENT |
| 27  | CT:1430-1435 | `mulDiv[RoundingUp](longAmount, _totalSupply, _totalAssets)`         | `_totalAssets`                | STATE-DEPENDENT |
| 28  | CT:1457      | `mulDivRoundingUp(creditDelta-credited, _totalAssets, _totalSupply)` | `_totalSupply`                | STATE-DEPENDENT |
| 29  | CT:1483-1498 | `mulDiv[RoundingUp](tokenToPay, _totalSupply, _totalAssets)`         | `_totalAssets`                | STATE-DEPENDENT |
| 30  | CT:1565      | `mulDivRoundingUp(commissionFee, _totalSupply, _totalAssets)`        | `_totalAssets`                | STATE-DEPENDENT |
| 31  | CT:1657      | `mulDivRoundingUp(commissionFee, _totalSupply, _totalAssets)`        | `_totalAssets`                | STATE-DEPENDENT |

### A4. RiskEngine

| #   | File:Line    | Expression                                                                 | Denominator                       | Classification  |
| --- | ------------ | -------------------------------------------------------------------------- | --------------------------------- | --------------- |
| 32  | RE:490-491   | `(longAmounts.rightSlot() * fee) / int256(DECIMALS)`                       | `DECIMALS` (constant)             | CONSTANT        |
| 33  | RE:739       | `unsafeDivRoundingUp(legPremia * haircutBase, longPremium.rightSlot())`    | `longPremium.rightSlot()`         | STATE-DEPENDENT |
| 34  | RE:756       | `unsafeDivRoundingUp(legPremia * haircutBase, longPremium.leftSlot())`     | `longPremium.leftSlot()`          | STATE-DEPENDENT |
| 35  | RE:1503      | `(distanceFromStrike * DECIMALS) / positionWidth`                          | `positionWidth`                   | USER-CONTROLLED |
| 36  | RE:1525      | `(DECIMALS * _required * positionWidth) / (distanceFromStrike * expValue)` | `distanceFromStrike * expValue`   | USER-CONTROLLED |
| 37  | RE:1864-1865 | `unsafeDivRoundingUp((notionalP-notional)*contracts, notionalP/notional)`  | `notionalP` or `notional`         | USER-CONTROLLED |
| 38  | RE:2203-2204 | `wDivToZero(utilization - TARGET, errNormFactor)`                          | `errNormFactor`                   | STATE-DEPENDENT |
| 39  | RE:2277      | `wDivToZero(WAD, CURVE_STEEPNESS)`                                         | `CURVE_STEEPNESS` (constant 4e18) | CONSTANT        |

### A5. Oracle (OraclePack.sol)

| #   | File:Line | Expression                                            | Denominator       | Classification |
| --- | --------- | ----------------------------------------------------- | ----------------- | -------------- |
| 40  | OP:377    | `(timeDelta * (newTick - eonsEMA)) / EMA_PERIOD_EONS` | `EMA_PERIOD_EONS` | CONSTANT (960) |
| 41  | OP:382    | `(timeDelta * (newTick - slowEMA)) / EMA_PERIOD_SLOW` | `EMA_PERIOD_SLOW` | CONSTANT (240) |
| 42  | OP:387    | `(timeDelta * (newTick - fastEMA)) / EMA_PERIOD_FAST` | `EMA_PERIOD_FAST` | CONSTANT (120) |
| 43  | OP:392    | `(timeDelta * (newTick - spotEMA)) / EMA_PERIOD_SPOT` | `EMA_PERIOD_SPOT` | CONSTANT (60)  |

**Note:** Although parameterized, all call paths use the constant `EMA_PERIODS = uint96(60 + (120 << 24) + (240 << 48) + (960 << 72))` from RiskEngine. No external path can supply zero.

### A6. PanopticMath Conversion Functions

| #   | File:Line | Expression                                               | Denominator                  | Classification  |
| --- | --------- | -------------------------------------------------------- | ---------------------------- | --------------- |
| 44  | PM:546    | `mulDiv(amount, 2**192, sqrtPriceX96^2)`                 | `sqrtPriceX96^2`             | STATE-DEPENDENT |
| 45  | PM:548    | `mulDiv(amount, 2**128, mulDiv64(sqrtPrice, sqrtPrice))` | `mulDiv64(sqrtPrice^2)`      | STATE-DEPENDENT |
| 46  | Math:346  | `mulDiv(...) / lowPriceX96`                              | `lowPriceX96`                | STATE-DEPENDENT |
| 47  | Math:398  | `mulDiv(amount0, mulDiv96(highP, lowP), highP - lowP)`   | `highPriceX96 - lowPriceX96` | STATE-DEPENDENT |
| 48  | Math:424  | `mulDiv(amount1, FP96, highP - lowP)`                    | `highPriceX96 - lowPriceX96` | STATE-DEPENDENT |

---

## B) Sensitivity Analysis

### B1. netLiquidity^2 (SFPM:1337-1342) - Premium Base Calculation

**Reachable minimum:** `netLiquidity = 1` (when all but 1 unit of liquidity is removed as long positions).

**Guard analysis:** The guard `currentLiquidity.rightSlot() > 0` (SFPM:1065) prevents netLiquidity == 0. However, netLiquidity == 1 is reachable.

**Maximum quotient at minimum:**

- `collected * totalLiquidity * 2^64 / 1^2`
- With `collected = 1e18` (realistic for high-value tokens) and `totalLiquidity = 2` (1 net + 1 removed):
- Result: `1e18 * 2 * 2^64 / 1 = 3.69e37`
- This fits in uint256 but is enormous per-liquidity premium delta.

**Downstream effect:** Result is capped by `toUint128Capped()` at SFPM:1355, 1358, 1378, 1381. So the premium accumulator delta is capped at `type(uint128).max ≈ 3.4e38`. Combined with `addCapped` in `_updateStoredPremia`, the accumulators saturate at `uint128.max`, freezing premium accumulation for that chunk.

**Adversary capability:** Attacker can create this state by:

1. Short a position (adds net liquidity to chunk)
2. Have another account go long on the same chunk, removing all but 1 unit
3. Trigger fee collection

**Impact:** Premium accumulator freezes at `uint128.max` → permanent premium desync for that chunk. This is the existing ROUND-006 finding from the rounding audit.

**Severity:** Medium (permanent desync, but only for that specific chunk)

### B2. totalLiquidity in grossPremiumLast (PP:1240, PP:1405)

**Mint path (PP:1240):** `totalLiquidity` is computed _after_ adding position liquidity. Since a mint always adds `chunkLiquidity > 0` (enforced by SFPM:972 zero-liquidity check), `totalLiquidity >= chunkLiquidity > 0`. **Safe.**

**Burn path (PP:1405):** The ternary `totalLiquidity != 0 ? ... / totalLiquidity : ...` at PP:1387 explicitly guards against zero. When `totalLiquidity == 0` (last position burned), the fallback resets `grossPremiumLast` to the current accumulator value. **Safe.**

### B3. accumulated == 0 sentinel in \_getAvailablePremium (PP:2282)

**Current behavior:** When `accumulated0 == 0`, the denominator becomes `type(uint256).max`, making the quotient effectively 0. This is correct — no premium accumulated means no premium available.

**Sensitivity at accumulated == 1:** If `accumulated0 == 1`:

- `premOwed * settled / 1 = premOwed * settled`
- This can be very large. However, the result is capped by `Math.min(..., premiumOwed)` at PP:2283.
- So the maximum available premium is `premiumOwed` itself — the function correctly caps it.

**Can accumulated == 1 be reached?**

- `accumulated = (premiumAccumulators[0] - grossPremiumLast.rightSlot()) * totalLiquidity / 2^64`
- This requires `(delta_accum * totalLiquidity)` to be between `2^64` and `2 * 2^64 - 1`.
- With `totalLiquidity = 1` and `delta_accum = 2^64 + k` for small k, accumulated = 1.
- This is reachable with the liquidity vacuum from B1.

**Impact at accumulated == 1:** Available premium = `min(premOwed * settled, premOwed)`. Since `settled >= premOwed` is typical (settled tokens accumulate from Uniswap fees), this returns `premOwed` — the seller gets their full premium. This is actually the correct behavior in an extreme-liquidity scenario.

**Severity:** Informational (capped correctly by `Math.min`)

### B4. totalAssets() in ERC4626 (CT:521 etc.)

**Post-initialization minimum:** `totalAssets() = s_depositedAssets + s_assetsInAMM + unrealizedInterest`. Initialized with `s_depositedAssets = 1`.

**Can totalAssets() reach 0?**

- `s_depositedAssets` starts at 1 and is modified by deposits (+), withdrawals (-), and settlements.
- `maxWithdraw` limits withdrawal to `depositedAssets - 1`, preserving the minimum of 1 in `s_depositedAssets`.
- However, `settleLiquidation` (CT:1280) adds to `s_depositedAssets` for negative bonus, and `_updateBalancesAndSettle` (CT:1506) can subtract `ammDeltaAmount` from `s_depositedAssets`.
- `s_assetsInAMM` can go to 0.
- `unrealizedInterest` can go to 0.

**Key question:** Can `s_depositedAssets` be driven to 0?

- `withdraw` has `s_depositedAssets -= uint128(assets)` (CT:731) but checks `maxWithdraw` which reserves 1.
- `_updateBalancesAndSettle` (CT:1506): `s_depositedAssets = uint256(int256(uint256(s_depositedAssets)) - ammDeltaAmount + realizedPremium).toUint128()` — this is _checked_ via `toUint128()`, so it would revert if negative.

**Conclusion:** `totalAssets() >= 1` post-initialization. **Safe from zero.** The minimum of 1 allows denominator == 1, which produces `shares = assets * totalSupply() / 1 = assets * totalSupply()`. This is bounded by `totalSupply()` being `>= 10^6` and `assets <= type(uint104).max`, so the product fits in uint256.

**Severity:** Informational (minimum of 1 maintained by design)

### B5. max(1, totalAssets() - bonus) in settleLiquidation (CT:1343)

**Expression:** `mulDivCapped(bonus, supply - liqBal, max(1, totalAssets() - bonus))`

**When bonus ≈ totalAssets():** Denominator → 1 (via `max(1,...)`).

- `mintedShares = bonus * (supply - liqBal) / 1 = bonus * (supply - liqBal)`
- This is capped by `Math.min(..., _totalSupply * DECIMALS)` at CT:1345.
- With `DECIMALS = 10_000`, max mintedShares = `totalSupply * 10_000`.

**Impact:** In an extreme liquidation where the bonus equals total assets, the protocol mints up to `totalSupply * 10_000` new shares. This dilutes existing shareholders but is the intended behavior — it represents protocol loss socialization.

**The `mulDivCapped` guard:** Returns `type(uint256).max` on overflow rather than reverting, ensuring the `Math.min` cap is applied.

**Severity:** Low (by-design protocol loss socialization, capped at `totalSupply * DECIMALS`)

### B6. userBorrowIndex (CT:1086)

**Range analysis:**

- Initialized to `WAD` (1e18) at CT:299 via `MarketStateLibrary.storeMarketState(WAD, ...)`
- Updated only via `mulDivWadRoundingUp(currentBorrowIndex, _borrowIndex)` at CT:1029-1031
- Since `_borrowIndex = WAD + rawInterest >= WAD`, the index only grows monotonically.
- Guard at CT:1078: `userBorrowIndex == 0 || currentBorrowIndex == userBorrowIndex` → returns 0.

**Minimum reachable value:** WAD (1e18) — cannot be less.

**Severity:** Safe (minimum is 1e18, guard on zero)

### B7. positionWidth in OTM collateral decay (RE:1503)

**Expression:** `(distanceFromStrike * DECIMALS) / positionWidth`

**Can positionWidth == 0?** `positionWidth = uint256(uint24(tickUpper - tickLower))`. For a valid option position, `tickUpper > tickLower` is enforced by TokenId validation. Width-0 legs have `tokenId.width(index) == 0` which takes a different code path (loan/credit, not option).

**When positionWidth is very small (1 tick):** `tickSpacing = 1` gives `positionWidth = tickSpacing * width`. The minimum non-zero `width` in TokenId is 1, so `positionWidth >= tickSpacing`. For `tickSpacing = 1`, `positionWidth = 1`.

At `positionWidth = 1`, `scaledRatio = distanceFromStrike * DECIMALS`, which is large. This leads to a very high `shifts` count, which caps `expValue` at `type(uint128).max`. The result: `required` approaches `TEN_BPS` (0.1 bps of notional) — an extremely small collateral requirement for far-OTM narrow positions. This is by design.

**Severity:** Safe (minimum positionWidth enforced by tick validation)

### B8. notional/notionalP in spread collateral (RE:1864-1865)

**Expression:** `unsafeDivRoundingUp((notionalP - notional) * contracts, notionalP)`

**Can notionalP == 0?** `notionalP` is computed from `PanopticMath.getAmountsMoved()` for the partner leg. If the partner leg's notional in the non-token-type token is 0, then `notionalP = 0`.

**When does moved0Partner or moved1Partner == 0?** When the partner leg's position is fully in one token (e.g., all token0, no token1). This can happen when the strike is far from the current tick.

**Impact of notionalP == 0:** `unsafeDivRoundingUp(0 * contracts, 0) = div(0, 0) = 0` in assembly. The EVM's `div` returns 0 when dividing by 0. Since the numerator is also 0 (because `notionalP - notional` would be negative and we're on the `notional < notionalP` branch, and if `notionalP = 0` then `notional <= 0` too, but these are unsigned...).

Actually, if `notional < notionalP` and `notionalP = 0`, then `notional` must also be 0. So numerator = `(0 - 0) * contracts = 0`. Division: `unsafeDivRoundingUp(0, 0) = 0 + gt(mod(0,0), 0) = 0 + 0 = 0`. **Returns 0.**

If `notional > notionalP = 0`, we'd be on the other branch: `unsafeDivRoundingUp((notional - 0) * contracts, notional) = contracts` (approximately). This is correct.

**Severity:** Safe in practice (unsafeDivRoundingUp returns 0 for 0/0, and the larger branch avoids 0 denominator)

### B9. errNormFactor in IRM (RE:2203-2206)

**Expression:** `wDivToZero(utilization - TARGET_UTILIZATION, errNormFactor)`

**errNormFactor definition:**

```solidity
int256 errNormFactor = _utilization > TARGET_UTILIZATION
    ? WAD - TARGET_UTILIZATION
    : TARGET_UTILIZATION;
```

**TARGET_UTILIZATION = 2e18 / 3 ≈ 6.67e17.** Both branches are constant non-zero:

- When util > target: `WAD - TARGET = 1e18 - 6.67e17 = 3.33e17`
- When util <= target: `TARGET = 6.67e17`

**Severity:** Safe (constants, always non-zero)

---

## C) Call-Path Analysis

### C1. \_getPremiaDeltas (SFPM:1304)

All paths to `_getPremiaDeltas`:

1. **`_collectAndWritePositionData` (SFPM:1235) → `_updateStoredPremia` (SFPM:1092) → `_getPremiaDeltas` (SFPM:1101)**

   - Guard: `currentLiquidity.rightSlot() > 0` at SFPM:1065 (before calling `_collectAndWritePositionData`)
   - **Guarded: YES**

2. **`getAccountPremium` (SFPM:1433) → `_getPremiaDeltas` (SFPM:1483)**
   - Guard: `netLiquidity != 0` at SFPM:1455 (`atTick < type(int24).max && netLiquidity != 0`)
   - **Guarded: YES**

**Conclusion:** Both paths check `netLiquidity > 0` before reaching the division. **All paths guarded.**

### C2. \_getAvailablePremium (PP:2260)

Paths:

1. **`_calculateAccumulatedPremia` (PP:509) → `_getAvailablePremium` (PP:558)**

   - Called during solvency checks and premium queries.
   - The sentinel `accumulated == 0 ? type(uint256).max : accumulated` handles the zero case.
   - **Guarded: YES (sentinel)**

2. **`_updateSettlementPostBurn` (PP:1268) → `_getAvailablePremium` (PP:1341)**
   - Same sentinel logic.
   - **Guarded: YES (sentinel)**

### C3. totalAssets() / totalSupply() in ERC4626

Every call path goes through `convertToShares()` or `convertToAssets()` or direct `mulDiv`. Post-initialization invariants:

- `totalAssets() >= 1` (preserved by withdraw limits)
- `totalSupply() >= 10^6` (preserved: `_internalSupply` starts at `10^6`, only modified in settlement which adds shortfalls)

**Risk of totalSupply() reaching 0:** `_internalSupply` is only decreased by `_burn()`. But `_burn()` requires the user to have sufficient balance, and `_internalSupply >= 10^6` is the virtual share base. The `_internalSupply` can increase (in `settleLiquidation` shortfall handling) but the question is whether repeated burns can drive it below `10^6`.

`_internalSupply` tracks: initial `10^6` + all `_mint()` - all `_burn()` + shortfall adjustments. Since `_mint` and `_burn` are balanced with deposits/withdrawals, and the virtual `10^6` is never withdrawn, `_internalSupply >= 10^6`. Combined with `s_creditedShares >= 0`, `totalSupply() >= 10^6`.

**Guarded: YES (by initialization invariants)**

### C4. grossPremiumLast update — mint path (PP:1240)

**Path:** `_updateSettlementPostMint` → division by `totalLiquidity` at PP:1240.

`totalLiquidity` is obtained from `_checkLiquiditySpread()` (PP:1163) which returns `netLiquidity + removedLiquidity`. During a mint:

- For short legs (isLong==0): `totalLiquidity` includes the just-minted liquidity. The SFPM enforces `chunkLiquidity > 0` (SFPM:972). So `totalLiquidity >= chunkLiquidity > 0`.
- For long legs: `totalLiquidity` is the pre-existing liquidity minus the removed amount. But long legs require `startingLiquidity >= chunkLiquidity` (SFPM:988), ensuring some net liquidity remains.

**Guarded: YES (by SFPM zero-liquidity check + mint semantics)**

---

## D) Findings

### DENOM-001: Spread Collateral unsafeDivRoundingUp with Zero Notional

- **Severity:** Low
- **Category:** div-by-zero (benign)
- **File:line:** RiskEngine.sol:1864-1865
- **Expression:** `unsafeDivRoundingUp((notionalP - notional) * contracts, notionalP)`
- **Denominator:** `notionalP` (or `notional` on the else branch)
- **Range:** 0 to uint128.max
- **Conditions for zero:** When a spread's partner leg has zero notional value in the cross-token. Occurs when a fully OTM position has no value in the opposite token.
- **Impact:** `unsafeDivRoundingUp(0, 0) = 0` in assembly — returns 0 silently instead of reverting. The comment says "can use unsafe because denominator is always nonzero" but this assumption is **incorrect** for extreme OTM positions.
- **Adversary capability:** Any user can create a spread with a far-OTM partner leg.
- **PoC:** Create a call spread where both legs are so far OTM that `moved0Partner = 0`. The spread collateral computation returns 0 instead of the correct `Math.min(splitRequirement, spreadRequirement)`.
- **Actual risk:** The `Math.min(splitRequirement, spreadRequirement)` at RE:1869 would still enforce the `splitRequirement` from the individual legs. However, if `spreadRequirement` is 0 (from the 0/0 division), and `splitRequirement` is also very low for far-OTM positions, the combined requirement could understate the true risk.

### DENOM-002: Haircut Premia unsafeDivRoundingUp with Zero longPremium

- **Severity:** Informational
- **Category:** div-by-zero (guarded)
- **File:line:** RiskEngine.sol:739, 756
- **Expression:** `unsafeDivRoundingUp(legPremia * haircutBase, longPremium.rightSlot())`
- **Denominator:** `longPremium.rightSlot()` or `longPremium.leftSlot()`
- **Guard:** `longPremium.rightSlot() != 0` at RE:734 and `longPremium.leftSlot() != 0` at RE:751.
- **Impact:** Properly guarded — each slot is independently checked before its division.

### DENOM-003: Liquidity Vacuum Premium Accumulator Saturation

- **Severity:** Medium
- **Category:** div-by-epsilon / sensitivity
- **File:line:** SFPM:1334-1343
- **Expression:** `collected * totalLiquidity * 2^64 / netLiquidity^2`
- **Denominator minimum:** `netLiquidity = 1` (all but 1 unit removed by longs)
- **Maximum quotient:** With collected=1e18, total=2: `1e18 * 2 * 2^64 / 1 ≈ 3.69e37`, capped at uint128.max by `toUint128Capped()`.
- **Impact:** Premium accumulators saturate at uint128.max via `addCapped`. This freezes premium accumulation permanently for the affected chunk. Short sellers in that chunk stop earning premium; long holders stop owing premium.
- **Adversary capability:** Requires controlling enough liquidity to remove all but 1 unit. Attacker needs existing short positions in the chunk to remove from.
- **Cascading:** The frozen accumulator feeds into `_getAvailablePremium` (PP:2271), where `accumulated = (saturated_accum - grossPremiumLast) * totalLiquidity / 2^64`. With a saturated accumulator, `accumulated` becomes extremely large, making the available premium fraction `≈ premOwed * settled / huge_number ≈ 0`. This starves short sellers of available premium.
- **Status:** **NOT APPLICABLE** — PanopticPool enforces a maximum removed fraction of 90% of total liquidity, so `netLiquidity` cannot reach 1 in practice.

### DENOM-004: settleLiquidation Quotient Amplification

- **Severity:** Low
- **Category:** div-by-epsilon
- **File:line:** CT:1339-1346
- **Expression:** `mulDivCapped(bonus, supply - liqBal, max(1, totalAssets() - bonus))`
- **Denominator minimum:** 1 (when `bonus >= totalAssets()`)
- **Maximum quotient:** `bonus * (totalSupply - liquidateeBalance)`, capped at `totalSupply * DECIMALS` (CT:1345).
- **Impact:** Up to `totalSupply * 10_000` new shares minted. This is bounded protocol loss socialization.
- **Adversary capability:** Requires a liquidation where the bonus (positive liquidation payment) approaches total vault assets. This is an extreme insolvency event.
- **Note:** The `mulDivCapped` prevents revert on overflow, and `Math.min` caps the result. By-design behavior.

### DENOM-005: OTM Decay Division by positionWidth

- **Severity:** Informational
- **Category:** div-by-epsilon
- **File:line:** RiskEngine.sol:1503, 1525-1526
- **Expression:** `(distanceFromStrike * DECIMALS) / positionWidth` and `(DECIMALS * required * positionWidth) / (distanceFromStrike * expValue)`
- **Denominator minimum:** `positionWidth >= tickSpacing` (enforced by TokenId validation). For `tickSpacing = 1`, minimum is 1.
- **Maximum quotient at positionWidth=1:** `scaledRatio = distance * 10_000_000` — can be very large. But this feeds into `shifts = scaledRatio / LN2_SCALED`, which creates exponential decay. At large shifts, `expValue` is capped at `type(uint128).max`, driving `required` toward `TEN_BPS`.
- **Impact:** Very narrow OTM positions have minimal collateral requirements (approaching 0.1 bps). This is intentional — far OTM narrow positions have negligible risk.

### DENOM-006: wDivToZero Missing Zero Check

- **Severity:** Informational
- **Category:** div-by-zero (structural)
- **File:line:** Math.sol:1253-1255
- **Expression:** `(x * WAD_INT) / y`
- **Denominator:** `y` (int256, caller-supplied)
- **Guard:** None — relies on callers to ensure `y != 0`.
- **Current callers:**
  1. RE:2206: `errNormFactor` — proven non-zero (see B9).
  2. RE:2277: `CURVE_STEEPNESS` — constant 4e18.
- **Impact:** All current call paths provide non-zero y. But the function itself has no guard, making it fragile if new callers are added.

### DENOM-007: Oracle EMA Period Division — Safe by Construction

- **Severity:** Informational
- **Category:** potential div-by-zero (mitigated)
- **File:line:** OraclePack.sol:377, 382, 387, 392
- **Expression:** `(timeDelta * (newTick - EMA)) / EMA_PERIOD_X`
- **Denominator:** EMA period values extracted from `uint96 EMAperiods` parameter.
- **Guard:** No explicit zero check in `updateEMAs`. The function relies on the caller providing non-zero periods.
- **Mitigation:** The sole caller passes `EMA_PERIODS = uint96(60 + (120 << 24) + (240 << 48) + (960 << 72))` from RiskEngine — all periods are non-zero constants. No external path can supply different values.
- **Risk:** If the architecture changes to allow configurable EMA periods, this becomes a div-by-zero bug.

### DENOM-008: netLiquidity in \_checkLiquiditySpread

- **Severity:** Informational
- **Category:** div-by-zero (guarded)
- **File:line:** PP:2156
- **Expression:** `(removedLiquidity * DECIMALS) / netLiquidity`
- **Guard:** `netLiquidity == 0` is checked at PP:2151 (`if (netLiquidity == 0) revert Errors.NetLiquidityZero()`), with a separate path at PP:2149 for when both net and removed are zero.
- **Impact:** Properly guarded.

---

## E) Patches + Tests

### Patch for DENOM-001 (Spread Zero Notional)

```solidity
// RiskEngine.sol:1862-1865
// Current:
spreadRequirement += (notional < notionalP)
    ? Math.unsafeDivRoundingUp((notionalP - notional) * contracts, notionalP)
    : Math.unsafeDivRoundingUp((notional - notionalP) * contracts, notional);

// Proposed:
if (notional != 0 || notionalP != 0) {
    spreadRequirement += (notional < notionalP)
        ? Math.unsafeDivRoundingUp((notionalP - notional) * contracts, notionalP)
        : Math.unsafeDivRoundingUp((notional - notionalP) * contracts, notional);
}
// When both are zero, the spread requirement is 0 (no cross-token exposure), which is correct.
```

**Test:**

```solidity
function test_DENOM001_ZeroNotionalSpread() public {
  // Create a call spread where both legs are far OTM such that moved0 ≈ 0 for both
  // Verify that spreadRequirement returns a sensible value (0 or splitRequirement)
}
```

### Patch for DENOM-003 (Liquidity Vacuum)

No code patch recommended — the `toUint128Capped` and `addCapped` mechanisms are the intended mitigation. The premium freeze is a known limitation of the accumulator design. A potential improvement would be to add a minimum netLiquidity threshold (e.g., `netLiquidity >= MIN_NET_LIQUIDITY`) in `_checkLiquiditySpread`, but this changes the economic model.

**Test:**

```solidity
function test_DENOM003_LiquidityVacuumPremium() public {
  // 1. Short a position adding 1000 units of liquidity
  // 2. Long 999 units from another account
  // 3. Trigger fee collection with large accumulated fees
  // 4. Verify premium accumulators don't overflow/freeze unexpectedly
  // 5. Verify downstream _getAvailablePremium returns bounded values
}
```

### Patch for DENOM-006 (wDivToZero)

```solidity
// Math.sol:1253
function wDivToZero(int256 x, int256 y) internal pure returns (int256) {
  require(y != 0, "wDivToZero: zero denominator");
  return (x * WAD_INT) / y;
}
```

This is a defensive hardening measure. Current callers are safe, but the explicit check prevents future misuse.

**Test:**

```solidity
function test_DENOM006_wDivToZeroZeroDenom() public {
  vm.expectRevert();
  Math.wDivToZero(1e18, 0);
}
```

---

## Summary Table

| ID        | Severity | Category       | Location     | Denominator         | Adversary Control       | Guarded?                                                      |
| --------- | -------- | -------------- | ------------ | ------------------- | ----------------------- | ------------------------------------------------------------- |
| DENOM-001 | Low      | div-by-zero    | RE:1864-1865 | notional/notionalP  | Yes (position params)   | No (comment claims safe)                                      |
| DENOM-002 | Info     | div-by-zero    | RE:739,756   | longPremium slots   | No                      | Yes (if-check)                                                |
| DENOM-003 | Medium   | div-by-epsilon | SFPM:1337    | netLiquidity^2      | Yes (liquidity removal) | **N/A** — max removed fraction is 90%, netLiq=1 not reachable |
| DENOM-004 | Low      | div-by-epsilon | CT:1343      | totalAssets()-bonus | Indirectly              | Yes (max(1,...) + Math.min)                                   |
| DENOM-005 | Info     | div-by-epsilon | RE:1503,1525 | positionWidth       | Yes (position params)   | Yes (expValue caps result)                                    |
| DENOM-006 | Info     | structural     | Math:1254    | y (parameter)       | N/A                     | No (callers safe)                                             |
| DENOM-007 | Info     | potential      | OP:377-392   | EMA periods         | No (constant)           | No (construction)                                             |
| DENOM-008 | Info     | div-by-zero    | PP:2156      | netLiquidity        | Yes                     | Yes (explicit revert)                                         |
