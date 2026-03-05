# Panoptic Protocol: Adversarial Rounding Audit

**Date:** 2026-02-21
**Scope:** All files under `contracts/` (recursive)
**Threat Model:** Full MEV adversary with sandwich capability

---

## A) Rounding Decision Map

### A.1 ERC4626 Vault (CollateralTracker.sol)

| #   | Expression                                                                    | File:Line  | Direction | Benefits                          | Should Benefit | Mismatch? |
| --- | ----------------------------------------------------------------------------- | ---------- | --------- | --------------------------------- | -------------- | --------- |
| 1   | `convertToShares`: `mulDiv(assets, totalSupply, totalAssets)`                 | CT:521     | floor     | protocol                          | protocol       | NO        |
| 2   | `convertToAssets`: `mulDiv(shares, totalAssets, totalSupply)`                 | CT:528     | floor     | protocol                          | protocol       | NO        |
| 3   | `previewDeposit`: `mulDiv(assets, totalSupply, totalAssets)`                  | CT:548     | floor     | protocol (user gets fewer shares) | protocol       | NO        |
| 4   | `previewMint`: `mulDivRoundingUp(shares, totalAssets, totalSupply)`           | CT:606     | ceil      | protocol (user pays more assets)  | protocol       | NO        |
| 5   | `previewWithdraw`: `mulDivRoundingUp(assets, supply, totalAssets)`            | CT:698     | ceil      | protocol (more shares burned)     | protocol       | NO        |
| 6   | `previewRedeem`/`convertToAssets`: `mulDiv(shares, totalAssets, totalSupply)` | CT:528/831 | floor     | protocol (user gets fewer assets) | protocol       | NO        |

**Verdict:** All ERC4626 conversions follow the correct protocol-conservative pattern. Deposits/mints round against the depositor; withdrawals/redeems round against the redeemer.

### A.2 Interest Rate System (CollateralTracker.sol)

| #   | Expression                                                                                          | File:Line      | Direction | Benefits                                  | Should Benefit | Mismatch? |
| --- | --------------------------------------------------------------------------------------------------- | -------------- | --------- | ----------------------------------------- | -------------- | --------- |
| 7   | `wTaylorCompounded`: `mulDiv(firstTerm, firstTerm, 2*WAD)` + `mulDiv(secondTerm, firstTerm, 3*WAD)` | Math:1229-1230 | floor     | borrower (less interest computed)         | protocol       | **YES**   |
| 8   | `interestOwed` via `mulDivWadRoundingUp(_assetsInAMM, rawInterest)`                                 | CT:1021        | ceil      | protocol (more global interest)           | protocol       | NO        |
| 9   | `currentBorrowIndex` via `mulDivWadRoundingUp(currentBorrowIndex, _borrowIndex)`                    | CT:1029-1031   | ceil      | protocol (index grows faster)             | protocol       | NO        |
| 10  | `_getUserInterest`: `mulDivRoundingUp(netBorrows, currentIdx - userIdx, userIdx)`                   | CT:1082-1088   | ceil      | protocol (user owes more)                 | protocol       | NO        |
| 11  | Interest shares: `mulDivRoundingUp(userInterestOwed, totalSupply, _totalAssets)`                    | CT:915-919     | ceil      | protocol (more shares burned)             | protocol       | NO        |
| 12  | Insolvency: `mulDiv(userBalance, _totalAssets, totalSupply)`                                        | CT:935-937     | floor     | protocol (credits less to insolvent user) | protocol       | NO        |

**Finding ROUND-001 (Informational):** `wTaylorCompounded` at Math:1227-1233 uses `mulDiv` (floor) for the 2nd and 3rd Taylor terms. This means the raw interest approximation is floored, slightly underestimating `e^(r*t)-1`. However, this is immediately counteracted by the ceil rounding in CT:1021 and CT:1029-1031 where `rawInterest` is applied. The floor in the Taylor series creates a ~1 wei underestimate that is dominated by the ceil in the subsequent multiplication. Net effect: protocol-conservative due to the outer ceil operations.

### A.3 Commission Split (CollateralTracker.sol)

| #   | Expression                                                                           | File:Line    | Direction | Benefits                             | Should Benefit | Mismatch? |
| --- | ------------------------------------------------------------------------------------ | ------------ | --------- | ------------------------------------ | -------------- | --------- |
| 13  | `commissionFee`: `mulDivRoundingUp(commission, notionalFee, DECIMALS)`               | CT:1562-1564 | ceil      | protocol                             | protocol       | NO        |
| 14  | `sharesToBurn` (mint): `mulDivRoundingUp(commissionFee, _totalSupply, _totalAssets)` | CT:1565      | ceil      | protocol                             | protocol       | NO        |
| 15  | Protocol split: `(sharesToBurn * protocolSplit) / DECIMALS`                          | CT:1585      | floor     | option owner (pays less to protocol) | protocol       | **YES**   |
| 16  | Builder split: `(sharesToBurn * builderSplit) / DECIMALS`                            | CT:1590      | floor     | option owner (pays less to builder)  | protocol       | **YES**   |

**Finding ROUND-002 (Low):** Commission split leak. When a builder code is active, lines CT:1585 and CT:1590 each use floor division. If `protocolSplit=6000` and `builderSplit=3000`, total distributed = `floor(S*6000/10000) + floor(S*3000/10000)`. For `sharesToBurn=1`, this distributes 0+0=0 shares while burning 1 from the user. For `sharesToBurn=10`, floor(6)+floor(3)=9, leaking 1 share. The leaked shares remain with the option owner.

- **Impact:** ~10% of commission shares leak back to the option owner per mint when builder codes are active.
- **Amplifiable:** Yes, by splitting large mints into many small ones (but gas cost >> extracted value).
- **Who benefits:** Option owner (actual). Protocol (should benefit).
- **Severity:** Low - the commission is already small, and gas costs exceed the extracted value.

### A.4 Settlement (CollateralTracker.sol: \_updateBalancesAndSettle)

| #   | Expression                                                                                         | File:Line    | Direction | Benefits                              | Should Benefit | Mismatch? |
| --- | -------------------------------------------------------------------------------------------------- | ------------ | --------- | ------------------------------------- | -------------- | --------- |
| 17  | Credit delta (creation, long): `mulDivRoundingUp(longAmount, totalSupply, totalAssets)`            | CT:1430-1431 | ceil      | protocol (more credited)              | protocol       | NO        |
| 18  | Credit delta (close, long): `mulDiv(longAmount, totalSupply, totalAssets)`                         | CT:1435      | floor     | protocol (less uncredited)            | protocol       | NO        |
| 19  | Credit overshoot haircut: `mulDivRoundingUp(creditDelta-creditedShares, totalAssets, totalSupply)` | CT:1455-1461 | ceil      | protocol (user pays more for haircut) | protocol       | NO        |
| 20  | `sharesToBurn` (tokenToPay>0): `mulDivRoundingUp(tokenToPay, totalSupply, totalAssets)`            | CT:1483-1487 | ceil      | protocol                              | protocol       | NO        |
| 21  | `sharesToMint` (tokenToPay<0): `mulDiv(abs(tokenToPay), totalSupply, totalAssets)`                 | CT:1498      | floor     | protocol (user gets fewer shares)     | protocol       | NO        |

**Verdict:** All settlement conversions are protocol-conservative. The asymmetry between credited shares at open (ceil) and close (floor) is discussed in Section C.6.

### A.5 Premium System (PanopticPool.sol + SFPM.sol)

| #   | Expression                                                                | File:Line      | Direction                                 | Benefits                           | Should Benefit  | Mismatch?        |
| --- | ------------------------------------------------------------------------- | -------------- | ----------------------------------------- | ---------------------------------- | --------------- | ---------------- |
| 22  | Premium per leg: `((accum - last) * liquidity) / 2**64`                   | PP:2220-2232   | floor (truncation-toward-zero for signed) | seller (pays less to buyer)        | protocol/seller | NO (intentional) |
| 23  | `_getAvailablePremium`: `(premOwed * settled) / accumulated`              | PP:2281-2282   | floor                                     | seller (gets less)                 | protocol        | NO               |
| 24  | Premium base: `mulDiv(collected, totalLiq * 2^64, net^2)`                 | SFPM:1334-1343 | floor                                     | nobody (base factor)               | -               | -                |
| 25  | Premium owed: `mulDiv(base, numerator, totalLiq).toUint128Capped()`       | SFPM:1353-1358 | floor + cap                               | seller (owed less per liquidity)   | protocol        | NO               |
| 26  | Premium gross: `mulDiv(base, numerator, totalLiq^2).toUint128Capped()`    | SFPM:1376-1381 | floor + cap                               | nobody specific                    | -               | -                |
| 27  | `grossPremiumLast` update (mint): `(C*R + L*T) / totalLiq`                | PP:1237-1250   | floor (unchecked)                         | protocol (less premium attributed) | protocol        | NO               |
| 28  | `grossPremiumLast` update (burn): `max(L*T - C*R + P*2^64, 0) / totalLiq` | PP:1387-1427   | floor + clamp at 0                        | protocol                           | protocol        | NO               |

### A.6 Fee Calculation (SFPM.sol + FeesCalc.sol)

| #   | Expression                                                                  | File:Line      | Direction                              | Benefits                      | Should Benefit | Mismatch? |
| --- | --------------------------------------------------------------------------- | -------------- | -------------------------------------- | ----------------------------- | -------------- | --------- |
| 29  | Stored feesBase (roundUp=true): `mulDiv128RoundingUp(feeGrowth, liquidity)` | SFPM:1149-1153 | ceil                                   | protocol (stored base higher) | protocol       | NO        |
| 30  | Current feesBase (roundUp=false): `mulDiv128(feeGrowth, liquidity)`         | SFPM:1156-1157 | floor                                  | protocol (current base lower) | protocol       | NO        |
| 31  | `amountToCollect = current.subRect(stored)`                                 | SFPM:1251-1252 | rect(floor-ceil) = rect(underestimate) | protocol (collects less)      | protocol       | NO        |
| 32  | `calculateAMMSwapFees`: `mulDiv128(feesPerLiq, liquidity)`                  | FeesCalc:65-66 | floor                                  | protocol                      | protocol       | NO        |

**Verdict:** The fee system is designed so that stored fees are rounded UP and current fees rounded DOWN. This minimizes `delta = current - stored`, creating a small protocol-favorable bias. This is explicitly documented in SFPM:1116-1117.

### A.7 Liquidation (CollateralTracker.sol: settleLiquidation)

| #   | Expression                                                                                  | File:Line    | Direction      | Benefits                                     | Should Benefit | Mismatch? |
| --- | ------------------------------------------------------------------------------------------- | ------------ | -------------- | -------------------------------------------- | -------------- | --------- |
| 33  | `convertToShares(bonusAbs)` (negative bonus): `mulDiv(bonus, supply, assets)`               | CT:1278      | floor          | protocol (fewer shares minted to liquidatee) | protocol       | NO        |
| 34  | `convertToShares(bonus)` (positive bonus): `mulDiv(bonus, supply, assets)`                  | CT:1317      | floor          | protocol (fewer bonus shares)                | protocol       | NO        |
| 35  | `mintedShares` formula: `mulDivCapped(bonus, supply-liqBal, max(1, assets-bonus)) - liqBal` | CT:1339-1344 | floor + capped | protocol (fewer shares minted)               | protocol       | NO        |

**Finding ROUND-003 (Medium):** At CT:1338-1344, the `mintedShares` computation occurs in an `unchecked` block. The subtraction `- liquidateeBalance` at line 1344 can underflow if `mulDivCapped(...)` returns a value less than `liquidateeBalance`. This happens when `bonus` is very small relative to `totalAssets`. The `mulDivCapped` returns a capped floor value, and if `bonus * (supply - liqBal) / (assets - bonus) < liqBal`, the subtraction wraps to a huge uint256. The `Math.min` with `_totalSupply * DECIMALS` provides a cap, but `_totalSupply * 10000` can still be enormous, leading to massive share minting.

- **Preconditions:** `bonus > 0`, `bonusShares > liquidateeBalance`, `totalAssets >> bonus` (common during liquidation with small surplus)
- **Impact:** Potential massive protocol loss through over-minting shares to the liquidator
- **Who benefits:** Liquidator (actual). Protocol (should benefit).
- **Severity:** Medium - requires specific liquidation conditions, but the cap at `totalSupply * DECIMALS` may not prevent significant loss.

### A.8 Token Conversion (PanopticMath.sol)

| #   | Expression                                                              | File:Line | Direction | Benefits | Should Benefit | Mismatch?         |
| --- | ----------------------------------------------------------------------- | --------- | --------- | -------- | -------------- | ----------------- |
| 36  | `convert0to1`: `mulDiv192(amount, sqrtPrice^2)`                         | PM:507    | floor     | -        | -              | Context-dependent |
| 37  | `convert0to1RoundingUp`: `mulDiv192RoundingUp(amount, sqrtPrice^2)`     | PM:527    | ceil      | -        | -              | Context-dependent |
| 38  | `convert1to0`: `mulDiv(amount, 2^192, sqrtPrice^2)`                     | PM:544    | floor     | -        | -              | Context-dependent |
| 39  | `convert1to0RoundingUp`: `mulDivRoundingUp(amount, 2^192, sqrtPrice^2)` | PM:564    | ceil      | -        | -              | Context-dependent |

**Verdict:** Conversion functions provide both floor and ceil variants. Callers select the appropriate variant based on who should benefit. Usage is correct throughout the codebase: collateral requirements use RoundingUp (more required = protocol-conservative), while balance conversions use floor (less received = protocol-conservative).

### A.9 Liquidity <-> Token Amount (Math.sol)

| #   | Expression                                                            | File:Line    | Direction                  | Benefits                          | Should Benefit | Mismatch? |
| --- | --------------------------------------------------------------------- | ------------ | -------------------------- | --------------------------------- | -------------- | --------- |
| 40  | `getAmount0ForLiquidity`: `mulDiv(...) / lowPrice`                    | Math:340-348 | floor/floor = double-floor | protocol (less tokens attributed) | context        | NO        |
| 41  | `getAmount0ForLiquidityUp`: `mulDivRoundingUp(mulDivRoundingUp(...))` | Math:308-317 | ceil/ceil = double-ceil    | user (more tokens attributed)     | context        | NO        |
| 42  | `getAmount1ForLiquidity`: `mulDiv96(liq, priceDiff)`                  | Math:358     | floor                      | protocol                          | context        | NO        |
| 43  | `getAmount1ForLiquidityUp`: `mulDiv96RoundingUp(liq, priceDiff)`      | Math:330     | ceil                       | user                              | context        | NO        |
| 44  | `getLiquidityForAmount0`: `mulDiv(amt, mulDiv96(high,low), high-low)` | Math:395-399 | floor/floor                | protocol (less liquidity)         | protocol       | NO        |
| 45  | `getLiquidityForAmount1`: `mulDiv(amt, FP96, high-low)`               | Math:424     | floor                      | protocol (less liquidity)         | protocol       | NO        |

### A.10 Collateral Requirements (RiskEngine.sol)

| #   | Expression                                                                                    | File:Line     | Direction              | Benefits                             | Should Benefit | Mismatch? |
| --- | --------------------------------------------------------------------------------------------- | ------------- | ---------------------- | ------------------------------------ | -------------- | --------- |
| 46  | `_sellCollateralRatio`: `min_sell + (DECIMALS-min_sell) * (util-target) / (saturated-target)` | RE:2100-2103  | floor                  | user (lower ratio = less collateral) | protocol       | **YES**   |
| 47  | `crossBufferRatio`: `(crossBuffer * (cutoff-util)) / (cutoff-saturated)`                      | RE:2157-2158  | floor                  | user (lower buffer)                  | protocol       | **YES**   |
| 48  | `_getRequiredCollateralSingleLegNoPartner` ITM: uses `getAmountsMoved` with RoundingUp        | RE:~1400-1500 | ceil                   | protocol (more collateral required)  | protocol       | NO        |
| 49  | `exerciseCost`: `(longAmounts * fee) / DECIMALS` (signed, fee < 0)                            | RE:490-491    | truncation-toward-zero | exercisor (pays less)                | protocol       | **YES**   |
| 50  | `_computeSpread` calendar width: `(amount * delta * ts) / 80000`                              | RE:1801-1804  | floor                  | user (less spread req)               | protocol       | **YES**   |
| 51  | `haircutPremia`: `unsafeDivRoundingUp(premia * base, longPremium)`                            | RE:739-743    | ceil                   | protocol (more haircut)              | protocol       | NO        |
| 52  | `isAccountSolvent` surplus: `mulDiv(surplus, crossBuffer, DECIMALS)`                          | RE:1010-1014  | floor                  | protocol (less surplus credit)       | protocol       | NO        |

**Finding ROUND-004 (Informational):** `_sellCollateralRatio` at RE:2100-2103 uses floor division in the linear interpolation, which slightly underestimates the collateral ratio. Similarly, `crossBufferRatio` at RE:2157-2158 floors, slightly reducing the buffer. Both favor the user by 1 unit in the worst case. Given that these are measured in basis points (1/10000), the impact is negligible (0.01% of 1 bps maximum).

### A.11 Pool Utilization (CollateralTracker.sol)

| #   | Expression                                                                                | File:Line    | Direction | Benefits                                          | Should Benefit | Mismatch? |
| --- | ----------------------------------------------------------------------------------------- | ------------ | --------- | ------------------------------------------------- | -------------- | --------- |
| 49  | `_poolUtilizationView`: `mulDivRoundingUp(assetsInAMM + interest, DECIMALS, totalAssets)` | CT:1172-1177 | ceil      | protocol (higher utilization = more conservative) | protocol       | NO        |
| 50  | `_poolUtilizationWadView`: `mulDivRoundingUp(assetsInAMM + interest, WAD, totalAssets)`   | CT:1213-1217 | ceil      | protocol                                          | protocol       | NO        |

---

## B) Round-Trip Analysis

### B.1 deposit(x) then withdraw(convertToAssets(previewDeposit(x)))

**Step 1 - Deposit:**

- `shares = floor(x * totalSupply / totalAssets)` (CT:548)

**Step 2 - Convert back:**

- `assets_back = floor(shares * totalAssets / totalSupply)` (CT:528)

**Step 3 - Withdraw (requires ceil shares):**

- Actually, user calls `redeem(shares)` which gives `assets_back = floor(shares * totalAssets / totalSupply)`

**Round-trip loss:**

```
loss = x - floor(floor(x * S / A) * A / S)
```

- Worst case: loss = 1 wei (when `x * S` is not divisible by `A`)
- Best case: loss = 0 (when division is exact)
- **Direction:** Favors protocol (user loses dust)
- **Amplifiable:** No - each round trip costs gas >> 1 wei

### B.2 mint(s) then redeem(s)

**Step 1 - Mint:**

- `assets = ceil(s * totalAssets / totalSupply)` (CT:606)

**Step 2 - Redeem:**

- `assets_back = floor(s * totalAssets / totalSupply)` (CT:528)

**Round-trip loss:**

```
loss = ceil(s * A / S) - floor(s * A / S) ∈ {0, 1}
```

- **Maximum loss:** 1 wei
- **Direction:** Favors protocol
- **Amplifiable:** No

### B.3 Open short then close

**Opening (mint):**

- Token amounts use `getAmount[0|1]ForLiquidityUp` (ceil) via `getAmountsMoved` (PM:744-745)
- Shares burned via `mulDivRoundingUp` (CT:1483)
- Commission via `mulDivRoundingUp` (CT:1562)

**Closing (burn):**

- Token amounts use `getAmount[0|1]ForLiquidity` (floor) via `getAmountsMoved` (PM:748)
- Shares minted via `mulDiv` (floor) (CT:1498)
- Commission on premium via `mulDivRoundingUp` (CT:1641-1657)

**Round-trip cost to user:** User pays ceil on open, receives floor on close = systematic loss of 0-2 wei per token per leg. Plus commission on both sides.

**Direction:** Favors protocol consistently. **Not amplifiable** (gas >> dust).

### B.4 Open long then close

**Opening:**

- Credit delta: `mulDivRoundingUp(longAmount, supply, assets)` (CT:1430)
- Token amounts: `getAmountForLiquidity` (floor for longs on open) (PM:748)

**Closing:**

- Credit delta: `mulDiv(longAmount, supply, assets)` (CT:1435)
- Haircut if credits overshoot: `mulDivRoundingUp(overshoot, assets, supply)` (CT:1455)

**Round-trip cost:** Credit system creates asymmetry: `ceil(X)` shares credited at open vs `floor(X)` shares uncredited at close. The difference (0-1 share) accumulates in `s_creditedShares` and is addressed in Section C.6.

### B.5 getLiquidityForAmount0 -> getAmount0ForLiquidity round-trip

```
liq = floor(amount0 * mulDiv96(high, low) / (high - low))    // Math:395-399
amt_back = floor(liq << 96 * (high - low) / high) / low      // Math:340-348
```

**Loss:** `amount0 - amt_back >= 0`. Double-floor creates systematic underestimate.

- **Worst case:** 2 wei for amount0 (double division, each losing up to 1)
- **Direction:** Favors protocol (less liquidity deployed = less at risk)

### B.6 Interest accrual then settlement

**Global accumulation (CT:1017-1031):**

- `rawInterest = wTaylorCompounded(rate, dt)` — floor (3-term Taylor)
- `interestOwed = mulDivWadRoundingUp(assetsInAMM, rawInterest)` — ceil
- `borrowIndex = mulDivWadRoundingUp(borrowIndex, WAD + rawInterest)` — ceil

**Per-user settlement (CT:1082-1088):**

- `userInterest = mulDivRoundingUp(netBorrows, idx_diff, userIdx)` — ceil

**Gap analysis:** The global accumulator uses `assetsInAMM * rawInterest / WAD` (ceil), while per-user uses `netBorrows * (currentIdx - userIdx) / userIdx` (ceil). The multiplicative (compound) index grows faster than the additive accumulator, which is why the clamping at CT:962-968 exists.

**Finding ROUND-005 (Informational):** The clamping at CT:962-968 (`if (burntInterestValue > _unrealizedGlobalInterest)`) correctly handles the case where per-user ceil compound interest exceeds the additive global interest floor. This is documented and expected. The drift is bounded by ~1 wei per user per interest accrual event.

### B.7 Premium owed accumulation then collection

**Accumulation (SFPM:1353-1358):**

- `deltaPremiumOwed = mulDiv(base, numerator, totalLiq).toUint128Capped()` — floor + cap

**Collection (PP:2220-2232):**

- `premia = ((accum_now - accum_last) * liquidity) / 2**64` — truncation-toward-zero (signed division in unchecked)

**Available premium (PP:2281-2294):**

- `available = min((premOwed * settled) / accumulated, premOwed)` — floor

**Gap:** Each step floors independently. The accumulated error over N interactions is bounded by N \* 1 (per-unit-liquidity) from the accumulator, multiplied by liquidity, then divided by 2^64 (another floor). Total worst-case gap: `N + 1` per token per chunk.

**Direction:** Always favors protocol (sellers collect less).

---

## C) Rounding Accumulation Analysis

### C.1 grossPremiumLast (PanopticPool.sol)

**Lifecycle:**

- Created at 0 when first position minted in a chunk
- Updated on every mint (PP:1234-1250) via `(C*R + L*T) / totalLiq` — floor
- Updated on every burn (PP:1387-1427) via `max(L*T - C*R + P*2^64, 0) / totalLiq` — floor + clamp

**Drift analysis:**

- Each mint: floor division loses up to 1 per slot per mint
- Each burn: floor division loses up to 1 per slot per burn, plus clamp at 0 can reset accumulated error
- **Sign of drift:** Always non-negative (grossPremiumLast is slightly underestimated)
- **Effect:** Slightly overestimates total gross premium owed `(C - L) * T`, which is protocol-conservative (sellers get slightly more attributed, but this is offset by the available premium cap)

**Worst-case drift rate:** 1 unit per interaction per slot (2 slots = 2 units per interaction)

**Weaponizable?** Theoretically, 1000 mint/burn cycles would accumulate ~1000 units of drift in grossPremiumLast. But this is per-liquidity (X64), so the actual token impact is `drift * totalLiq / 2^64`, which is negligible for any reasonable liquidity.

### C.2 settledTokens (PanopticPool.sol)

**Lifecycle:**

- Created at 0
- Increased by `collectedByLeg` on every mint/burn (PP:1174, 1294)
- Decreased by `availablePremium` on seller close (PP:1350)
- Increased by long premium on buyer close (PP:1301-1309)

**Drift:** `settledTokens` only uses exact `LeftRightUnsigned.add()` and `.sub()` — no division operations touch it directly. The values added/subtracted come from Uniswap collections (exact) and premium calculations (floored). Drift enters only indirectly through the floored premium values.

**Worst-case drift rate:** 0 direct drift (add/sub are exact). Indirect drift through premium rounding: bounded by the premium system drift (Section C.3).

### C.3 s_accountPremiumOwed / s_accountPremiumGross (SFPM.sol)

**Lifecycle:**

- Updated via `_updateStoredPremia` → `addCapped` (SFPM:1106-1112)
- `addCapped` freezes both accumulators if either slot overflows to `uint128.max`

**Drift from addCapped freeze:**

- When one accumulator hits `uint128.max`, both owed and gross freeze for that token
- This creates a **permanent desync**: any premium that would have accrued after the freeze is lost
- The gross accumulator (used for seller premium) and owed accumulator (used for buyer premium) freeze simultaneously, preventing extraction

**Finding ROUND-006 (Low):** If premium accumulation is heavy enough to reach `uint128.max` (~3.4e38), the freeze event causes all subsequent premium for that token in that chunk to be lost. Both owed and gross freeze together (by design), preventing asymmetric extraction. But sellers with existing positions lose future premium accrual.

- **Preconditions:** Extremely high fee accumulation in a single chunk (practically impossible for most tokens, but theoretically reachable for low-decimal tokens with extreme trading volume)
- **Impact:** Future premium loss for all positions in the affected chunk
- **Amplifiable:** Not directly, but a token with 0 decimals could reach this faster
- **Severity:** Low — the simultaneous freeze prevents extraction

### C.4 borrowIndex (CollateralTracker.sol)

**Lifecycle:**

- Initialized at 1e18 (CT:299)
- Updated via `mulDivWadRoundingUp(currentBorrowIndex, WAD + rawInterest)` (CT:1029-1031)
- Stored as uint80 (max ~1.2e24)

**Drift analysis:**

- Each update rounds UP, so the index grows monotonically faster than true compound interest
- The ceil error per update is at most 1 wei (WAD scale)
- Over N updates, accumulated ceil drift ≈ N wei

**Worst-case drift rate:** ~1 wei per 4-second epoch (minimum update interval). Over 1 year (~7.9M epochs), drift ≈ 7.9M wei ≈ 7.9e-12 units. Negligible.

**Finding ROUND-007 (Informational):** borrowIndex rounds up systematically, causing borrowers to owe slightly more than true compound interest. This is protocol-conservative. The drift is ~1 wei per epoch, which over practical timeframes is inconsequential.

### C.5 unrealizedGlobalInterest (CollateralTracker.sol)

**Lifecycle:**

- Part of `s_marketState` packed storage
- Increased by `interestOwed` (ceil) on each epoch (CT:1024)
- Decreased by `burntInterestValue` on each user settlement (CT:962-968)
- Clamped to 0 if burntInterestValue exceeds it (CT:962-963)

**Drift analysis:**

- Increases use ceil (adds more interest than exact), decreases are exact or clamped
- Clamping at 0 can "destroy" accumulated interest (drives it to 0 when it should be slightly positive)
- The clamping event occurs when per-user ceil computation exceeds the additive global accumulator

**Net drift:** The clamping systematically reduces `unrealizedGlobalInterest` toward 0, which means `totalAssets()` is slightly underestimated. This makes shares slightly more valuable (protocol-conservative for withdrawals, slightly anti-depositor for deposits). The magnitude is bounded by the number of concurrent borrowers \* 1 wei.

### C.6 s_creditedShares (CollateralTracker.sol)

**Lifecycle:**

- Increased by `mulDivRoundingUp(longAmount, supply, assets)` on position open (CT:1430, 1474)
- Decreased by `mulDiv(longAmount, supply, assets)` on position close (CT:1435, 1467)

**Asymmetry:** `ceil(X) - floor(X) ∈ {0, 1}` for each open/close cycle. This means `s_creditedShares` grows by 0 or 1 share per long position open/close cycle.

**Finding ROUND-008 (Low):** `s_creditedShares` has a monotonic upward drift of 0-1 share per long position lifecycle. Over many cycles, this inflates `totalSupply()` without corresponding asset backing, diluting all share holders.

- **Drift rate:** 0-1 share per long open/close cycle
- **Impact:** For a pool with 1e6 initial virtual shares and 1e18 totalAssets (mature pool), each extra share dilutes by ~1e12 wei. After 1000 cycles, dilution ≈ 1000 \* 1e12 / 1e18 = 0.001% — negligible.
- **But:** The close path at CT:1447-1468 handles the case where `s_creditedShares < creditDelta` by zeroing the credits and charging the option owner the overshoot via `mulDivRoundingUp` (CT:1455-1461). This prevents `s_creditedShares` from going negative.
- **Weaponizable?** Only by repeatedly opening and closing long positions. Gas cost >> 1 share of value.
- **Severity:** Low — correctly mitigated by the overshoot haircut mechanism.

### C.7 s_depositedAssets / s_assetsInAMM (CollateralTracker.sol)

**Conservation:**

- `s_depositedAssets` is updated via exact integer addition/subtraction (CT:584, 731, 786, 864, 1506-1508)
- `s_assetsInAMM` is updated via exact integer addition/subtraction (CT:1515-1518)

**Drift:** Zero. These accumulators only use checked arithmetic with exact amounts. The `toUint128()` cast at CT:1508 and CT:1517 can revert on overflow but does not cause rounding.

---

## D) Boundary Value Rounding Tests

### D.1 positionSize = 1

- `getLiquidityChunk`: `amount = 1 * optionRatio(leg)`. For `optionRatio=1`, `amount=1`.
- `getLiquidityForAmount0(tL, tU, 1)`: `liq = floor(1 * mulDiv96(high,low) / (high-low))`.
  - At tick 0 (sqrtPrice=2^96), for width=1 (tS=1): `high-low ≈ 5e-5 * 2^96`, so `liq ≈ floor(2^96 / 5e-5) ≈ 1.58e33`. Non-zero. **Does not revert.**
- `getAmount0ForLiquidity` on this liquidity: may return 0 due to double-floor.
  - **Potential DoS:** Position could be created but return 0 tokens, creating a position that cannot be properly settled. However, the `chunkLiquidity == 0` check at SFPM:972 prevents this.

### D.2 positionSize = type(uint128).max (capped at int128.max - 4)

- `amount = (int128.max - 4) * optionRatio`. For `optionRatio=127`, this overflows uint256? No: `(2^127 - 5) * 127 ≈ 2.16e40`, fits in uint256.
- `getLiquidityForAmount0`: `liq = mulDiv(2.16e40, mulDiv96(high,low), high-low)`. Can overflow to > uint128.max → reverts at Math:402.
- **No rounding issue at this boundary** — overflow protection catches it.

### D.3 deposit amount = 1 wei

- `shares = floor(1 * 10^6 / 1) = 10^6` (at initialization when totalAssets=1, totalSupply=10^6)
- After first deposit of X assets: `shares = floor(1 * (10^6 + shares_from_X) / (1 + X))`. For large X, this ≈ 0. **Deposit of 1 wei after significant activity returns 0 shares → reverts at CT:563 (`assets == 0` check does not apply, but the shares check is missing).**

**Finding ROUND-009 (Informational):** A deposit of 1 wei can succeed (no minimum shares check in `deposit`) and mint 0 shares if `totalAssets >> totalSupply`. The assets are transferred but user receives nothing. This is standard ERC4626 behavior and is mitigated by the virtual shares (10^6 initial) which maintain a reasonable share price.

### D.4 deposit amount = type(uint104).max

- `shares = floor(type(uint104).max * totalSupply / totalAssets)`. With virtual shares, `totalSupply ≈ 10^6`, `totalAssets ≈ 1`. Result ≈ `2e31 * 10^6 ≈ 2e37`. Fits in uint256. No rounding issue at this boundary.

### D.5 totalAssets = 1, totalSupply = 10^6 (initialization)

- `convertToShares(1)` = `floor(1 * 10^6 / 1)` = 10^6. No rounding loss.
- `convertToAssets(1)` = `floor(1 * 1 / 10^6)` = 0. **1 share converts to 0 assets.**
- `convertToAssets(10^6)` = `floor(10^6 * 1 / 10^6)` = 1. Exact.

### D.6 Premium accumulators near uint128.max

- `addCapped` at LeftRight:305-308 uses `toUint128Capped()`.
- At `uint128.max - 1`, adding 2 → capped to `uint128.max`, both accumulators freeze for that slot.
- Once frozen, no further accumulation occurs. This is permanent for the chunk.

### D.7 borrowIndex near uint80.max (~1.2e24)

- Stored as part of MarketState (uint80).
- `mulDivWadRoundingUp(1.2e24, WAD + rawInterest)`: if rawInterest ≈ 1e18 (100%/sec, impossible), result ≈ 2.4e24 > uint80.max → `toUint128()` succeeds but `storeMarketState` truncates to 80 bits.
- **Practical concern:** At a sustained 800% APR, borrowIndex doubles every ~32 days. To reach uint80.max from WAD (1e18) requires `log2(1.2e24 / 1e18) ≈ 20` doublings ≈ 640 days at max rate. Overflow would cause silent truncation in `storeMarketState`.

---

## E) Findings (Prioritized)

### ROUND-001: wTaylorCompounded Floor Bias

- **Severity:** Informational
- **Category:** direction-error (mitigated)
- **File:line:** Math.sol:1227-1233
- **Rounding:** `mulDiv` (floor) for 2nd and 3rd Taylor terms
- **Benefits (actual):** Borrower (slightly less interest)
- **Benefits (correct):** Protocol
- **Preconditions:** Any interest accrual
- **Impact:** <1 wei per accrual, fully counteracted by ceil in CT:1021,1029
- **Amplifiable:** No
- **PoC:** N/A (mitigated by outer operations)

### ROUND-002: Commission Split Leak

- **Severity:** Low
- **Category:** extraction
- **File:line:** CT:1585, CT:1590
- **Rounding:** `(shares * split) / DECIMALS` (floor) applied twice
- **Benefits (actual):** Option owner
- **Benefits (correct):** Protocol
- **Preconditions:** Builder code active (protocolSplit + builderSplit < DECIMALS)
- **Impact:** ~10% of commission shares leaked per mint with builder code
- **Amplifiable:** Theoretically (many small mints), but gas >> value
- **PoC:** Mint with `sharesToBurn=1` → `floor(1*6000/10000) + floor(1*3000/10000) = 0`, user retains full share

### ROUND-003: settleLiquidation mintedShares Underflow — RESOLVED

- **Severity:** Medium
- **Category:** extraction
- **File:line:** CT:1338-1346
- **Status:** **RESOLVED** — Ternary guard added: `rawMinted > liquidateeBalance ? Math.min(rawMinted - liquidateeBalance, _totalSupply * DECIMALS) : 0`. The unchecked subtraction now only executes when `rawMinted > liquidateeBalance`, preventing the underflow entirely.
- **Rounding:** `mulDivCapped(...)` (floor) followed by guarded subtraction
- **Benefits (actual):** Protocol (mintedShares = 0 when rawMinted ≤ liquidateeBalance)
- **Benefits (correct):** Protocol
- **Preconditions:** No longer exploitable
- **Impact:** N/A (resolved)
- **Amplifiable:** No

### ROUND-004: Collateral Ratio Floor Division

- **Severity:** Informational
- **Category:** direction-error
- **File:line:** RE:2100-2103, RE:2157-2158
- **Rounding:** Floor division in linear interpolation
- **Benefits (actual):** User (slightly less collateral)
- **Benefits (correct):** Protocol
- **Impact:** 1 unit in 10_000_000 (0.00001%) maximum
- **Amplifiable:** No
- **PoC:** `utilization = TARGET_POOL_UTIL + 1`, exact result is non-integer → floored by 1 unit

### ROUND-005: Interest Accumulator Clamping

- **Severity:** Informational
- **Category:** drift
- **File:line:** CT:962-968
- **Who benefits:** Protocol (after clamp, totalAssets slightly lower)
- **Impact:** ~1 wei per borrower per settlement
- **Amplifiable:** No (gas >> value)

### ROUND-006: Premium Accumulator addCapped Freeze

- **Severity:** Low
- **Category:** drift (permanent desync)
- **File:line:** LeftRight.sol:299-321, SFPM:1106-1112
- **Who benefits:** Nobody (premium lost for all parties in chunk)
- **Correct:** Protocol should freeze both (current behavior is correct)
- **Impact:** Future premium loss in affected chunk
- **Amplifiable:** Only by generating extreme fee volume in a single chunk

### ROUND-007: borrowIndex Monotonic Ceil Drift

- **Severity:** Informational
- **Category:** drift
- **File:line:** CT:1029-1031
- **Who benefits:** Protocol (borrowers owe slightly more)
- **Impact:** ~1 wei per epoch, ~7.9M wei/year. Negligible.
- **Amplifiable:** No

### ROUND-008: s_creditedShares Monotonic Growth

- **Severity:** Low
- **Category:** drift
- **File:line:** CT:1430-1431 (ceil at open), CT:1435 (floor at close)
- **Who benefits:** Protocol initially (more credited), but leads to dilution
- **Impact:** 0-1 share growth per long lifecycle. Negligible dilution.
- **Amplifiable:** Only by repeated open/close of longs. Gas >> extracted value.

### ROUND-009: 1-Wei Deposit Zero Shares

- **Severity:** Informational
- **Category:** DoS (self-inflicted)
- **File:line:** CT:560-565
- **Who benefits:** Nobody (user loses 1 wei)
- **Preconditions:** Large totalAssets relative to totalSupply (post many deposits)
- **Impact:** 1 wei lost. Mitigated by virtual shares.
- **Amplifiable:** No

### ROUND-010: exerciseCost Truncation-Toward-Zero on Negative Fee

- **Severity:** Low
- **Category:** direction-error
- **File:line:** RE:490-491
- **Rounding:** `(longAmounts * fee) / DECIMALS` where `fee` is negative — Solidity signed division truncates toward zero, reducing absolute fee value
- **Benefits (actual):** Exercisor (pays less force-exercise fee)
- **Benefits (correct):** Exercisee/Protocol (force exercise is a penalty mechanism; exercisor should pay more)
- **Impact:** At most 1/DECIMALS of each token per force exercise (~0.01%). For a 100 ETH long leg with 10bps fee, the truncation loses at most 0.01 ETH worth.
- **Amplifiable:** No (one force exercise per position)
- **PoC:** `longAmounts.rightSlot() = 9999`, `fee = -10` (1bps): `(9999 * -10) / 10000 = -99990 / 10000 = -9` (truncated toward zero). Exact would be `-9.999`, so floor(toward -inf) = `-10`. User pays 9 instead of 10 — saves 1 unit.

### ROUND-011: \_computeSpread Calendar Width Floor Division

- **Severity:** Low
- **Category:** direction-error
- **File:line:** RE:1801-1804, RE:1806-1809
- **Rounding:** `(amountsMoved * deltaWidth * tickSpacing) / 80000` — floor division
- **Benefits (actual):** User (lower spread requirement)
- **Benefits (correct):** Protocol (higher spread requirement = more collateral)
- **Impact:** At most 1 unit per leg. For a calendar spread with 1 ETH notional and tickSpacing=60, deltaWidth=1: `1e18 * 60 / 80000 = 750000000000000` exact. No rounding issue at this scale. Only matters for very small amounts.
- **Amplifiable:** No
- **Note:** The complementary notional difference calculation at RE:1864-1865 correctly uses `unsafeDivRoundingUp`.

### ROUND-012: haircutPremia unsafeDivRoundingUp Over-Haircut

- **Severity:** Informational
- **Category:** direction-error (intentional, protocol-conservative)
- **File:line:** RE:739-743, RE:756-761
- **Rounding:** `unsafeDivRoundingUp` rounds UP each per-leg prorated haircut
- **Benefits (actual):** Protocol (more haircut clawed from liquidatee)
- **Benefits (correct):** Protocol
- **Impact:** Each leg's haircut is rounded up by at most 1 token. With 4 legs per position and up to 32 legs total, max over-haircut = 32 tokens.
- **Note:** The `haircutTotal` sum is then cast to `int128` at InteractionHelper:170,179. This cast is safe under the documented assumption (RE:727) that total haircuts < `2^127 - 1`, which holds given deposit caps at `type(uint104).max` (~2e31). No explicit overflow check exists — safety relies on the protocol's deposit cap invariant.
- **Amplifiable:** No

### Additional RiskEngine Rounding Notes (Verified Correct)

- **isAccountSolvent surplus scaling (RE:1010-1018):** `mulDiv(surplus, crossBufferRatio, DECIMALS)` uses floor. This REDUCES cross-collateral credit available to the user, making them appear less solvent → **protocol-conservative**. Correct.
- **maintReq buffer (RE:1004-1005):** `mulDivRoundingUp(tokenData.leftSlot(), buffer, DECIMALS)` rounds UP the maintenance requirement → **protocol-conservative**. Correct.
- **collateral requirements (RE:1398-1507):** All use `mulDivRoundingUp` or `unsafeDivRoundingUp` → **protocol-conservative**. Correct.
- **twapEMA (RE:817):** `(6*fast + 3*slow + eonsEMA) / 10` truncates. This is acceptable — tick-level precision loss of at most 0.9 ticks, well within oracle tolerance.
- **interestRate average (RE:2259):** `(start + end + 2*mid) / 4` truncates. This rounds DOWN the interest rate by at most 1 WAD unit (~1e-18), favoring borrowers by a negligible amount. Acceptable given the adaptive rate model's natural variance.

---

## F) Patches + Tests

### ROUND-002: Commission Split Leak

**Patch:** Burn the undistributed shares rather than leaving them with the user.

```solidity
// CT:1581-1598 — Replace the unchecked block:
unchecked {
    uint256 protocolShares = (sharesToBurn * riskParameters.protocolSplit()) / DECIMALS;
    uint256 builderShares = (sharesToBurn * riskParameters.builderSplit()) / DECIMALS;
    uint256 remainingShares = sharesToBurn - protocolShares - builderShares;

    _transferFrom(optionOwner, address(riskEngine()), protocolShares);
    _transferFrom(optionOwner, address(uint160(riskParameters.feeRecipient())), builderShares);
    // Burn any undistributed dust
    if (remainingShares > 0) _burn(optionOwner, remainingShares);
}
```

**Tests:**

```solidity
// Boundary test: sharesToBurn = 1
function test_commissionSplitBoundary_1share() public {
  // Setup: builder code with protocolSplit=6000, builderSplit=3000
  // Mint with amount that produces sharesToBurn=1
  // Assert: floor(1*6000/10000) + floor(1*3000/10000) = 0
  // With patch: remaining 1 share is burned
}

// Max error test: sharesToBurn = 9999
function test_commissionSplitMaxError() public {
  // sharesToBurn = 9999
  // floor(9999*6000/10000) = 5999
  // floor(9999*3000/10000) = 2999
  // Total distributed = 8998, leaked = 1001
  // With patch: 1001 shares burned
}
```

### ROUND-003: settleLiquidation Underflow — APPLIED

**Patch applied in codebase** at CT:1337-1347:

```solidity
unchecked {
    uint256 rawMinted = Math.mulDivCapped(
        uint256(bonus),
        _totalSupply - liquidateeBalance,
        uint256(Math.max(1, int256(totalAssets()) - bonus))
    );

    mintedShares = rawMinted > liquidateeBalance
        ? Math.min(rawMinted - liquidateeBalance, _totalSupply * DECIMALS)
        : 0;
}
```

**Tests:**

```solidity
// Boundary: bonus = 1 wei, liquidateeBalance = 0
function test_settleLiquidation_minBonus() public {
  // mulDivCapped(1, supply, assets-1) should produce small result
  // Subtraction of 0 should not underflow
}

// Max error: bonus large, liquidateeBalance > mulDivCapped result
function test_settleLiquidation_underflowPrevention() public {
  // Setup so mulDivCapped returns < liquidateeBalance
  // Without patch: underflow to huge number
  // With patch: mintedShares = 0
}
```

### ROUND-008: s_creditedShares Drift (Invariant Test)

```solidity
// Fuzz test: open and close N long positions, verify s_creditedShares drift
function testFuzz_creditedSharesDrift(uint128 positionSize, uint8 numCycles) public {
  numCycles = uint8(bound(numCycles, 1, 50));
  positionSize = uint128(bound(positionSize, 1, type(uint104).max));

  uint256 creditsBefore = ct.s_creditedShares();

  for (uint8 i = 0; i < numCycles; i++) {
    // Open long position
    _mintLong(positionSize);
    // Close long position
    _burnLong(positionSize);
  }

  uint256 creditsAfter = ct.s_creditedShares();
  // Credits should not grow by more than numCycles
  assertLe(creditsAfter - creditsBefore, numCycles, "Credit drift exceeds bound");
}
```

### Round-trip Invariant Tests

```solidity
// ERC4626 round-trip: deposit then redeem
function testFuzz_depositRedeemRoundTrip(uint104 assets) public {
  assets = uint104(bound(assets, 2, type(uint104).max));

  uint256 shares = ct.deposit(assets, address(this));
  uint256 assetsBack = ct.redeem(shares, address(this), address(this));

  // User should never receive more than deposited
  assertLe(assetsBack, assets, "Round-trip returned more than deposited");
  // Loss should be at most 1 wei
  assertLe(assets - assetsBack, 1, "Round-trip loss exceeds 1 wei");
}

// Interest round-trip: accrue then settle
function testFuzz_interestRoundTrip(uint128 borrowAmount, uint32 timeElapsed) public {
  borrowAmount = uint128(bound(borrowAmount, 1e6, type(uint104).max));
  timeElapsed = uint32(bound(timeElapsed, 4, 365 days));

  // Setup borrower
  _setupBorrower(borrowAmount);

  // Advance time
  vm.warp(block.timestamp + timeElapsed);

  // Global interest should be >= sum of per-user interest
  uint256 globalInterest = ct.unrealizedGlobalInterest();
  uint256 userInterest = ct.owedInterest(borrower);

  // Global may be slightly less due to clamping, but not by more than number of settlements
  // (each settlement can clamp at most 1 wei)
}
```
