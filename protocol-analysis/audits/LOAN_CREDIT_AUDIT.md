# Loan/Credit (width==0) System Audit Report

**Date**: 2026-03-05
**Scope**: All files under `contracts/` (recursive)
**Focus**: Width==0 positions — loans (isLong==0) and credits (isLong==1)

---

## Executive Summary

The width==0 (loan/credit) system is architecturally sound. No critical or high-severity vulnerabilities were identified. The loan lifecycle correctly preserves share price invariants, interest accrual is properly structured, and liquidation bonus clamping prevents extraction of loan-inflated balances. Credit positions are correctly treated as balance-neutral operations in solvency calculations.

**3 Medium**, **8 Low**, and **15 Informational** findings were identified across solvency, interest, composite strategies, and protocol health domains. (LC-005 and LC-012 were withdrawn after review.)

The most significant systemic concern is **loan-driven utilization manipulation** (LC-003): loans increase `s_assetsInAMM` without deploying real tokens, which can spike interest rates for all borrowers. This is self-limiting (the attacker pays their own interest) but creates a griefing vector.

---

## Findings

### LC-001 | Medium | Overflow | unrealizedInterest 106-bit silent truncation

**Files**: `types/MarketState.sol:138-144`, `CollateralTracker.sol:1023`

`unrealizedInterest` occupies 106 bits in `MarketState`. The `storeMarketState` function uses `shl(150, _unrealizedInterest)` in assembly — if the accumulated value exceeds 2^106, upper bits are silently truncated without revert. The checked `+=` at CT:1023 prevents uint128 overflow, but values between 2^106 and 2^128 would be stored incorrectly.

**Scenario**: Pool with `s_assetsInAMM` near 2^104 at 800% APR. If no user settles interest for extended periods at maximum rates, the accumulator can approach 2^106, and excess interest would be silently lost.

**Practical likelihood**: Very low. 2^106 ≈ 8.1e31, which exceeds realistic token supplies. Interest settlement occurs frequently and rates self-correct.

**Recommendation**: Add an explicit check in `_calculateCurrentInterestState` that `_unrealizedGlobalInterest < (1 << 106)`, reverting or clamping if exceeded.

---

### LC-002 | Medium | Interest Rate Manipulation | Loan-driven utilization spike

**Files**: `CollateralTracker.sol:1168-1176,1515-1518`, `RiskEngine.sol:167-191`

Loans increase `s_assetsInAMM` without deploying real tokens to Uniswap. Pool utilization = `(s_assetsInAMM + interest) / totalAssets`. An attacker with sufficient capital can take large loans to push utilization toward 90%+, triggering the adaptive IRM to ramp interest rates toward 800%/year maximum for ALL borrowers.

**Scenario**: Pool has 10,000 USDC deposited. Attacker deposits 96,000 USDC, takes loans totaling 80,000 notional. Utilization jumps to ≈89%. With `CURVE_STEEPNESS=4` and `MAX_RATE_AT_TARGET=200%`, rates can reach ~800%/yr. All existing borrowers face dramatically higher interest.

**Mitigations already present**:

- Attacker pays their own interest (self-limiting, insolvent in ~9 days at max rate)
- 120% margin requirement bounds leverage to ~5x
- Adaptive IRM ramps gradually (50x/yr speed, 4.5h elapsed cap)
- `SATURATED_POOL_UTIL` (90%) triggers 100% seller collateral requirement

**Additional analysis — combined loan + withdrawal attack**:

Loans create "phantom utilization" — they increase `s_assetsInAMM` without reducing `s_depositedAssets`, meaning LP withdrawal capacity is unaffected by the loan. Unlike real short options (which physically move tokens from `s_depositedAssets` to Uniswap), loans leave the full `s_depositedAssets` available for withdrawal. If LPs flee after a loan spikes utilization, the only floor on `s_depositedAssets` is the borrower's locked margin.

With a fixed 20% margin, the hard ceiling on loan-driven utilization (even with complete LP flight) is `1/(1 + margin_rate) = 1/1.2 = 83.3%`. This is below `SATURATED_POOL_UTIL` (90%), so existing protections are active at that level. However, the system is stressed at 83.3% utilization with elevated interest rates affecting all borrowers.

**Recommended mitigation (implemented)**: Make the loan maintenance margin utilization-dependent by reusing the existing `_sellCollateralRatio` curve. Parameterize `_sellCollateralRatio` to accept a `minRatio` floor, then call it with `MAINT_MARGIN_RATE` (20%) for loans and `SELLER_COLLATERAL_RATIO` for options:

```solidity
// In _getRequiredCollateralSingleLegNoPartner, for loan legs:
uint256 maintenanceLoanMargin = _sellCollateralRatio(poolUtilization, MAINT_MARGIN_RATE);
required = Math.mulDivRoundingUp(amountMoved, maintenanceLoanMargin + DECIMALS, DECIMALS);

// _sellCollateralRatio generalized:
function _sellCollateralRatio(int256 utilization, uint256 minRatio) internal pure returns (uint256)
```

This ramps the loan margin from 20% to 100% between `TARGET_POOL_UTIL` (66.67%) and `SATURATED_POOL_UTIL` (90%):

| Utilization | Loan margin | Total requirement | Max leverage |
| ----------- | ----------- | ----------------- | ------------ |
| < 66.67%    | 20%         | 120%              | 5.0×         |
| 75%         | 48.6%       | 148.6%            | 2.1×         |
| 80%         | 65.7%       | 165.7%            | 1.5×         |
| 85%         | 82.9%       | 182.9%            | 1.2×         |
| 90%+        | 100%        | 200%              | 1.0×         |

With this change, the equilibrium ceiling for loan+withdrawal drops from 83.3% to ~72.1% (solving the quadratic where `u = 1/(1 + margin_rate(u))`). Attack costs at 90% utilization increase from 1.8× to 9.0× the pool size. The change reuses battle-tested curve logic with minimal code modification (one parameterized function, two call sites).

---

### LC-003 | Medium | ITM Swap Interaction | Width==0 legs alter ITM swap amounts

**Files**: `SemiFungiblePositionManagerV4.sol:792-813`

Width==0 legs contribute to `itmAmounts` in the SFPM. When combined with width>0 legs and inverted tick limits, the width==0 leg's notional is included in the ITM swap computation. This can amplify or cancel the swap amount in ways that may be surprising.

**Scenario**: Position with a short call (width>0, at-the-money) + short loan (width=0, tokenType=0). With inverted tick limits, the loan's `itm0 = -notional` combines with the call's ITM contribution, changing the net swap amount. The user may receive more or fewer tokens than expected from the ITM swap.

**Recommendation**: Document this interaction clearly. Consider whether width==0 legs should be excluded from `itmAmounts` computation, since they don't represent actual AMM liquidity.

---

### LC-004 | Low | Bounds | Width==0 bypasses SFPM PositionTooLarge check

**Files**: `SemiFungiblePositionManagerV4.sol:876-880`

The `PositionTooLarge` check at SFPM:876-880 only examines `amount0`/`amount1` from width>0 legs. Width==0 legs skip the entire `_createLegInAMM` path and the size accumulator. A width==0 leg can have arbitrarily large notional without triggering this safety check.

**Downstream bounds**: `s_assetsInAMM` uses `toUint128()` checked cast (CT:1518), and 120% margin requirement makes extreme-size loans economically infeasible.

**Recommendation**: Consider adding an explicit size check for width==0 legs in the SFPM or PanopticPool, matching the `int128.max - 4` bound used for width>0 legs.

---

### ~~LC-005~~ | WITHDRAWN | ~~Overflow~~ | ~~Silent uint128 truncation for extreme-strike notionals~~

**Files**: `libraries/PanopticMath.sol:747-748`

**WITHDRAWN**: The `uint128()` casts at PM:747-748 are **checked downcasts** under Solidity >=0.8.0 (the casts are not inside an `unchecked` block). If `getAmount0ForLiquidityUp` or `getAmount1ForLiquidityUp` returns a value exceeding `type(uint128).max`, the transaction reverts with a panic. No silent truncation is possible.

---

### LC-006 | Low | Interest | Interest timing manipulation via close/reopen

**Files**: `CollateralTracker.sol:894-983`

A user can close and immediately reopen a loan to reset their borrowIndex, potentially avoiding some interest. However, commission fees (NOTIONAL_FEE = 0.01%) are charged on both operations, and the transient storage utilization mechanism prevents flash-deposit manipulation within a single transaction.

**Recommendation**: No code change needed. The commission cost exceeds interest savings for practical time periods.

---

### LC-007 | Low | Rounding | Systematic 0-1 share loss per credit lifecycle (ROUND-008)

**Files**: `CollateralTracker.sol:1430-1436`

Credit creation uses `mulDivRoundingUp` for `creditDelta` (ceil); credit close uses `mulDiv` (floor). Users lose 0-1 share per open/close cycle. This also causes monotonic growth of `totalSupply` (via `s_creditedShares` accumulating rounding dust), creating permanent micro-dilution for all shareholders.

**Recommendation**: Acceptable as-is. The 1-share rounding is protocol-conservative and the cumulative effect is negligible.

---

### LC-008 | Low | Rounding | Delayed swap credit conversion rounds anti-conservatively

**Files**: `RiskEngine.sol:2066-2068`

In `_computeDelayedSwap`, the converted credit uses `convert0to1RoundingUp` / `convert1to0RoundingUp`. Since `convertedCredit` is subtracted from `required`, rounding UP benefits the user (reduces requirement).

**Impact**: At most 1 wei per conversion.

**Recommendation**: Use `convert0to1` / `convert1to0` (round DOWN) to be protocol-conservative.

---

### LC-009 | Low | Liquidation | Delayed swap bonus imprecision from tick mismatch

**Files**: `RiskEngine.sol:511-617`, `PanopticPool.sol:1735`

Liquidation bonus is computed at `twapTick`, while solvency may have been evaluated at a different tick. For cross-token delayed swap positions, the tick-dependent conversion creates a small discrepancy.

**Recommendation**: Acceptable as-is. The twapTick is deliberately chosen for manipulation resistance. Bounded by `MAX_TWAP_DELTA_DISPATCH`.

---

### LC-010 | Low | Interest | Compounding penalty on insolvent interest reduces PLP reserves

**Files**: `CollateralTracker.sol:932-949`

When interest exceeds a user's shares, all shares are burned but the borrow index is NOT updated (debt continues compounding). PLPs absorb the shortfall through reduced `unrealizedGlobalInterest`. This is an inherent property of lending protocols.

**Recommendation**: Acceptable as-is. The mechanism correctly socializes losses.

---

### LC-011 | Low | Exercise | Force exercise closes loans without loan-specific compensation

**Files**: `PanopticPool.sol:1789-1849`, `RiskEngine.sol:424-429`

When a mixed position (width>0 long + width==0 loan) is force-exercised, the exercise cost only accounts for the width>0 long leg. The loan is simultaneously closed with no additional compensation in the exercise fee.

**Recommendation**: Document this interaction. Users combining loans with exercisable options should understand the forced closure risk.

---

### ~~LC-012~~ | WITHDRAWN | ~~Notional~~ | ~~Width=2 substitution sensitivity for low-tickSpacing pools~~

**Files**: `libraries/PanopticMath.sol:731-736`

**WITHDRAWN**: The `(√P_b − √P_a)` range terms cancel algebraically in the round-trip `positionSize → liquidity → amounts`. The notional is approximately `positionSize * optionRatio` in the asset token and `positionSize * optionRatio * price` in the other token, independent of width or tickSpacing. Narrower ranges produce larger intermediate liquidity values with better relative rounding precision, not worse.

---

### LC-013 | Low | Griefing | Interest rate griefing via loan utilization manipulation

**Files**: `CollateralTracker.sol:1168-1176`, `RiskEngine.sol:167-191`

Related to LC-002. Even though the attack is self-limiting, during the period of elevated utilization (up to ~9 days before attacker becomes insolvent), all existing borrowers pay elevated interest rates. The cost-to-grief ratio depends on pool size and existing utilization.

**Recommendation**: Addressed by the same utilization-dependent loan margin fix as LC-002. The ramp from 20%→100% between 66.67% and 90% utilization increases attack costs by 4.6× at 90% (from 1.8T to 8.26T) and reduces the equilibrium ceiling to ~72.1% under LP flight conditions.

---

### Informational Findings

| ID     | Category      | Description                                                                                                                 | Location               |
| ------ | ------------- | --------------------------------------------------------------------------------------------------------------------------- | ---------------------- |
| LC-I01 | Correctness   | Loan share price preservation is exact (mulDiv floors, protocol-conservative)                                               | CT:1498-1500           |
| LC-I02 | Correctness   | Burn path correctly accrues interest before closing loan                                                                    | CT:1412                |
| LC-I03 | Correctness   | `getTotalLoanAmounts` correctly isolates loan legs (width==0 && isLong==0)                                                  | PM:808-836             |
| LC-I04 | Correctness   | Loan amounts correctly excluded from liquidation bonus                                                                      | RE:537-549             |
| LC-I05 | Correctness   | Credit operations approximately preserve share price (within ROUND-008 bounds)                                              | CT:1430-1436           |
| LC-I06 | Correctness   | Credits correctly excluded from premium system (PP:551, 1161, 1291, 2205)                                                   | PanopticPool.sol       |
| LC-I07 | Correctness   | `s_depositedAssets` unchanged by credits; `s_assetsInAMM` unchanged by credits                                              | CT:1507-1518           |
| LC-I08 | Design        | Credits are balance-neutral in solvency: shares burned = credits added back                                                 | RE:1186-1187,1336-1345 |
| LC-I09 | Design        | Credit-option composites (`_computeCreditOptionComposite`) provide no capital efficiency benefit over standalone evaluation | RE:2001-2020           |
| LC-I10 | Design        | Loans can exceed deposited assets by design; controlled by IRM                                                              | CT:1168-1177           |
| LC-I11 | Design        | Isolated credit requires 0 collateral (correct: credit is a wash on balance)                                                | RE:1432-1434           |
| LC-I12 | Design        | Credits do not earn interest or yield (shares are burned, credit is fixed notional)                                         | Multiple               |
| LC-I13 | Design        | No constraint on number of width==0 legs per position (0-4 valid)                                                           | TokenId.sol:473-518    |
| LC-I14 | Documentation | Comment at RE:1595 says `max(loan, short option)` but code does SUM                                                         | RE:1984-1986           |
| LC-I15 | Documentation | Comment at RE:1596 says `max(loan, short option)` but strategy uses long option                                             | RE:1987-1989           |

---

## Composite Strategy Analysis Summary

| Strategy                  | Legs                           | Computation                          | Correctness                                             |
| ------------------------- | ------------------------------ | ------------------------------------ | ------------------------------------------------------- |
| **Prepaid Long Option**   | width>0 long + credit          | Option req at 100% util              | Correct but no capital efficiency gain (LC-I09)         |
| **Cash-Secured Option**   | width>0 short + credit         | Short req at 100% util               | Correct, more conservative than standalone at low util  |
| **Upfront Short Option**  | width>0 short + loan           | shortReq + loanReq (SUM)             | Correct, conservative (comment says max, code does sum) |
| **Option-Protected Loan** | width>0 long + loan            | max(longReq, loanReq)                | Correct; degrades to loanReq when option worthless      |
| **Delayed Swap**          | loan + credit (diff tokenType) | max(loan\*120% - convertedCredit, 1) | Correct but anti-conservative rounding (LC-008)         |

---

## Accounting Variable Trace

Tracking `s_assetsInAMM`, `s_depositedAssets`, `s_creditedShares`, `_internalSupply`, and `unrealizedInterest` through each width==0 operation:

### Loan Mint (width==0, isLong==0, shortAmount=X)

| Variable            | Change    | Notes                                   |
| ------------------- | --------- | --------------------------------------- |
| `s_assetsInAMM`     | +X        | "Virtual" deployment                    |
| `s_depositedAssets` | 0         | ammDeltaAmount=0                        |
| `s_creditedShares`  | 0         | longAmount=0                            |
| `_internalSupply`   | +shares   | shares = X \* totalSupply / totalAssets |
| `totalAssets()`     | +X        | Via s_assetsInAMM                       |
| `totalSupply()`     | +shares   | Via \_internalSupply                    |
| Share price         | Preserved | Both num/denom increase proportionally  |

### Loan Burn (width==0, isLong==0, shortAmount=X)

| Variable            | Change    | Notes                         |
| ------------------- | --------- | ----------------------------- |
| `s_assetsInAMM`     | -X        | Reversal                      |
| `s_depositedAssets` | 0         | ammDeltaAmount=0              |
| `s_creditedShares`  | 0         | longAmount=0 on burn of short |
| `_internalSupply`   | -shares   | User repays via share burn    |
| Share price         | Preserved | Both decrease proportionally  |

### Credit Mint (width==0, isLong==1, longAmount=Y)

| Variable            | Change        | Notes                          |
| ------------------- | ------------- | ------------------------------ |
| `s_assetsInAMM`     | 0             | shortAmount=0                  |
| `s_depositedAssets` | 0             | ammDeltaAmount=0               |
| `s_creditedShares`  | +ceil(Y\*S/A) | Rounded up                     |
| `_internalSupply`   | -ceil(Y\*S/A) | Shares burned from user        |
| `totalSupply()`     | ~0            | credited + internal cancel out |
| Share price         | ~Preserved    | Within 1 share rounding        |

### Credit Burn (width==0, isLong==1, longAmount=Y)

| Variable            | Change         | Notes              |
| ------------------- | -------------- | ------------------ |
| `s_assetsInAMM`     | 0              | shortAmount=0      |
| `s_depositedAssets` | 0              | ammDeltaAmount=0   |
| `s_creditedShares`  | -floor(Y\*S/A) | Rounded down       |
| `_internalSupply`   | +floor(Y\*S/A) | Shares minted back |
| `totalSupply()`     | +0-1           | ROUND-008 drift    |
| Share price         | ~Preserved     | Micro-dilution     |

---

## Recommendations Summary

### Code Changes (by priority)

1. **LC-008**: Change `convert0to1RoundingUp`/`convert1to0RoundingUp` to floor-rounding variants in `RiskEngine._computeDelayedSwap:2066-2068`
2. **LC-001**: Add explicit `require(_unrealizedGlobalInterest < (1 << 106))` guard in `_calculateCurrentInterestState`
3. **LC-004**: Consider adding a width==0-specific position size bound in PanopticPool (e.g., `require(notional <= int128.max - 4)`)

### Parameter Considerations

5. **LC-002/LC-013** (implemented): Parameterize `_sellCollateralRatio` to accept a `minRatio` floor. Call with `MAINT_MARGIN_RATE` for loans, `SELLER_COLLATERAL_RATIO` for options. This ramps loan margin 20%→100% between `TARGET_POOL_UTIL` and `SATURATED_POOL_UTIL`, reducing equilibrium loan-driven utilization ceiling from 83.3% to ~72.1%

### Documentation

6. **LC-I14/LC-I15**: Fix comments at `RiskEngine.sol:1595-1596` to match actual code behavior
7. **LC-I09**: Document that credit-option composites provide no capital efficiency advantage
8. **LC-003**: Document that width==0 legs participate in ITM swap computations
9. **LC-011**: Document that force exercise closes all legs including width==0
