# Adversarial Arithmetic Audit Report: Panoptic Protocol

**Date:** 2026-02-21
**Scope:** `contracts/**/*.sol` (35 files)
**Branch:** `dev6`
**Auditor model:** Claude Opus 4.6 (1M context)

---

## A) ARITHMETIC ATTACK SURFACE MAP

### A.1 Scale Summary

| Category                    | Count | Primary Locations                                                                                                                                                     |
| --------------------------- | ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `unchecked` blocks          | 255+  | Math.sol, PanopticPool.sol, CollateralTracker.sol, RiskEngine.sol, SFPM.sol, LeftRight.sol, TokenId.sol, OraclePack.sol                                               |
| Assembly blocks             | 73    | Math.sol (37), MarketState.sol (9), RiskParameters.sol (11), CollateralTracker.sol (6), PanopticMath.sol (1), V4StateReader.sol (3), TransientReentrancyGuard.sol (3) |
| Narrowing casts             | 200+  | CollateralTracker.sol (40+), RiskEngine.sol (30+), PanopticPool.sol (35+), SFPM.sol (20+), OraclePack.sol (15+)                                                       |
| Signed/unsigned transitions | 80+   | CollateralTracker.sol, RiskEngine.sol, PanopticPool.sol, LeftRight.sol, SFPM.sol                                                                                      |
| Packed bitfield types       | 7     | LeftRight, TokenId, LiquidityChunk, PositionBalance, OraclePack, MarketState, RiskParameters                                                                          |

### A.2 Critical Hotspots by Contract

#### CollateralTracker.sol (1698 lines)

- **ERC4626 share/asset conversion**: `convertToShares`/`convertToAssets` at lines 520-528 — `mulDiv` with `totalSupply()/totalAssets()`, attacker controls deposit timing
- **Interest accrual**: `_accrueInterest` lines 895-984 — compound index via `wTaylorCompounded`, rounding-up propagation
- **Borrow index compounding**: `_calculateCurrentInterestState` lines 1010-1032 — `mulDivWadRoundingUp` in unchecked, `deltaTime` cast `uint32(currentEpoch - previousEpoch) << 2`
- **Settlement math**: `_updateBalancesAndSettle` lines 1403-1528 — mixed sign arithmetic with `tokenToPay = ammDeltaAmount - netBorrows - realizedPremium` in unchecked
- **Liquidation settlement**: `settleLiquidation` lines 1247-1367 — `mintedShares` formula at 1338-1346 uses `mulDivCapped` with `totalAssets() - bonus` in denominator, unchecked subtraction
- **Commission split**: lines 1581-1598, 1672-1689 — `(sharesToBurn * riskParameters.protocolSplit()) / DECIMALS` + `(sharesToBurn * riskParameters.builderSplit()) / DECIMALS` — sum may not equal `sharesToBurn` due to rounding

#### PanopticPool.sol (~2345 lines)

- **Premium accumulation**: `_getPremia` lines 2213-2234 — `((premiumAccumulatorsByLeg[leg][0] - premiumAccumulatorLast.rightSlot()) * liquidityChunk.liquidity()) / 2**64` in unchecked, potential underflow if accumulator resets
- **GrossPremiumLast adjustment**: `_updateSettlementPostMint` lines 1234-1250 — `(grossCurrent0 * positionLiquidity + grossPremiumLast.rightSlot() * totalLiquidityBefore) / totalLiquidity` in unchecked, potential overflow of `uint128 * uint128`
- **Available premium**: `_getAvailablePremium` lines 2267-2297 — `(premiumOwed.rightSlot() * settledTokens.rightSlot()) / accumulated0` in unchecked, division-by-zero guarded only by ternary with `type(uint256).max`
- **Liquidity spread check**: `_checkLiquiditySpread` lines 2154-2157 — `(removedLiquidity * DECIMALS) / netLiquidity` in unchecked

#### SFPM (SemiFungiblePositionManager.sol, ~1450 lines)

- **Premium deltas**: `_getPremiaDeltas` lines 1323-1388 — `totalLiquidity * 2**64` can overflow for large liquidity in `premium0X64_base = Math.mulDiv(collected0, totalLiquidity * 2**64, netLiquidity**2)` (unchecked)
- **Fee base calculation**: `_getFeesBase` lines 1145-1157 — `int128(int256(Math.mulDiv128(...)))` without bounds check — relies on position size limit at line 915
- **Collected amount calculation**: `_collectAndWritePositionData` lines 1280-1287 — `receivedAmount0 - uint128(-movedInLeg.rightSlot())` in unchecked, assumes `receivedAmount0 >= |movedInLeg|`

#### RiskEngine.sol (~2400 lines)

- **Liquidation bonus**: `getLiquidationBonus` lines 500-590 — complex multi-path with `bonus0 = Math.min(bal0 / 2, req0 > bal0 ? req0 - bal0 : 0).toInt256()`
- **Haircut computation**: lines 736-763 — `uint128(-_premiasByLeg[i][leg].rightSlot()) * uint256(uint128(haircutBase.rightSlot()))` in unchecked — negation of negative int128 to uint128
- **Collateral requirement**: `_getRequiredCollateralSingleLegNoPartner` — spread calculation with `uint256(uint24(atTick - strike))` at line 1495 — potential underflow if `atTick < strike` (wrapping to large uint24)
- **Interest rate model**: lines 2060-2275 — `wExp`, `wMulToZero`, `wDivToZero` used in IRM calculations, checked for bounds but Taylor approximation has precision limits
- **twapEMA**: line 817 — `int24((6 * fastEMA + 3 * slowEMA + eonsEMA) / 10)` — truncating division, always rounds toward zero

#### OraclePack.sol

- **int12toInt24 / int22toInt24**: lines 314-347 — manual sign extension for 12-bit and 22-bit signed values stored in unsigned containers
- **EMA update**: `updateEMAs` lines 365-396 — `_eonsEMA + (timeDelta * (newTick - _eonsEMA)) / EMA_PERIOD_EONS` in unchecked, all `int24` with potential for overflow during `timeDelta * (newTick - _eonsEMA)` if timeDelta and tick delta are both large
- **Rebase**: `rebaseOraclePack` lines 611-633 — `_residual - deltaOffset` in unchecked, truncation to 12 bits via `& 0x0FFF`

---

## B) PER-HOTSPOT RANGE PROOF (Key Findings)

### B.1 SFPM `_getPremiaDeltas` — `totalLiquidity * 2**64` overflow

**File:** `SemiFungiblePositionManager.sol:1336`
**Expression:** `totalLiquidity * 2 ** 64`
**Status:** **Safe by invariant**

- `totalLiquidity = netLiquidity + removedLiquidity`, both `uint128`, so `totalLiquidity` max = `2^129 - 2`
- `totalLiquidity * 2^64` max = `(2^129 - 2) * 2^64 ≈ 2^193`, fits in `uint256`
- `netLiquidity ** 2` (line 1337) max = `(2^128 - 1)^2 ≈ 2^256 - 2^129`, fits in `uint256` but barely
- Position size bounded at `int128.max - 4` (SFPM line 915), so practical liquidity is bounded. The `mulDiv` function handles 512-bit intermediate products.
- **Invariant enforced at:** `SemiFungiblePositionManager.sol:915`

### B.2 CollateralTracker `settleLiquidation` — `mintedShares` formula

**File:** `CollateralTracker.sol:1338-1346`
**Expression:**

```solidity
mintedShares = Math.min(
    Math.mulDivCapped(
        uint256(bonus),
        _totalSupply - liquidateeBalance,
        uint256(Math.max(1, int256(totalAssets()) - bonus))
    ) - liquidateeBalance,
    _totalSupply * DECIMALS
);
```

**Status:** **Unproven — potential underflow**

- The outer `- liquidateeBalance` is unchecked. If `mulDivCapped` returns a value smaller than `liquidateeBalance` (possible when `bonus` is small relative to total assets), this underflows to a very large number.
- **Mitigant**: The `Math.min(..., _totalSupply * DECIMALS)` caps the result. But `_totalSupply * DECIMALS` could itself be very large.
- **Impact**: Could mint excessive shares to liquidator, diluting PLPs.
- **Missing bound**: No proof that `mulDivCapped result >= liquidateeBalance`

### B.3 CollateralTracker Commission Split — Shares Leak

**File:** `CollateralTracker.sol:1581-1598`
**Expressions:**

```solidity
_transferFrom(optionOwner, address(riskEngine()),
    (sharesToBurn * riskParameters.protocolSplit()) / DECIMALS);
_transferFrom(optionOwner, address(uint160(riskParameters.feeRecipient())),
    (sharesToBurn * riskParameters.builderSplit()) / DECIMALS);
```

**Status:** **Exploitable — accounting drift (Low severity)**

- `protocolSplit + builderSplit` = 6000 + 3000 = 9000, not 10000. The remaining 1000 bps (10%) of `sharesToBurn` is never transferred and never burned.
- With `feeRecipient != 0`, `floor(sharesToBurn * 6000/10000) + floor(sharesToBurn * 3000/10000)` can be strictly less than `sharesToBurn`, leaving shares in the option owner's balance that should have been removed.
- The `_burn` path (when `feeRecipient == 0`) correctly burns all `sharesToBurn`.
- **Impact**: With builder codes active, option owners retain a small fraction of shares that should have been taken as commission. Over many transactions this compounds.

### B.4 PanopticPool `_updateSettlementPostMint` grossPremiumLast overflow

**File:** `PanopticPool.sol:1237-1248`
**Expression:**

```solidity
uint128(
    (grossCurrent0 * positionLiquidity +
     grossPremiumLast.rightSlot() * totalLiquidityBefore) / totalLiquidity
)
```

**Status:** **Safe by invariant**

- `grossCurrent0` is `uint256` (premium accumulator per X64), `positionLiquidity` is `uint128`
- Multiplication `grossCurrent0 * positionLiquidity` can exceed `uint256` if `grossCurrent0 > 2^128`, which is possible for mature positions with many fee collections
- Adding `grossPremiumLast.rightSlot() * totalLiquidityBefore` (uint128 \* uint128 ≈ uint256) could overflow in unchecked
- **Mitigant**: `addCapped` in SFPM freezes accumulators at `type(uint128).max`, limiting `grossCurrent0`
- **Invariant enforced at:** SFPM `addCapped` (`LeftRight.sol:299-321`)

### B.5 OraclePack EMA Update — int24 overflow during intermediate computation

**File:** `OraclePack.sol:377`
**Expression:** `int24(_eonsEMA + (timeDelta * (newTick - _eonsEMA)) / EMA_PERIOD_EONS)`
**Status:** **Safe by clamping**

- `timeDelta` capped at `3 * EMA_PERIOD / 4` (line 376)
- `newTick` clamped by `clampTick` (line 555) to within `clampDelta` of last tick
- Intermediate `timeDelta * (newTick - _eonsEMA)` computed as `int256`, so no overflow risk
- The `int24()` cast truncates, but values are bounded within tick range
- **Invariant enforced at:** Cascading clamp at `OraclePack.sol:376,381,386,391`

### B.6 RiskEngine `_getRequiredCollateralSingleLegNoPartner` — uint24 wrapping

**File:** `RiskEngine.sol:1495-1496`
**Expression:** `uint256(uint24(atTick - strike))` / `uint256(uint24(strike - atTick))`
**Status:** **Safe by conditional**

- The ternary selects based on `atTick >= strike`, so the subtraction result is always non-negative
- `uint24()` wrapping only occurs for negative values, which the conditional prevents
- **Invariant enforced at:** Conditional at same line

### B.7 FeesCalc `_getAMMSwapFeesPerLiquidityCollected` — Uniswap fee growth underflow

**File:** `FeesCalc.sol:113-114`
**Expression:** `feeGrowthInside0X128 = lowerOut0 - upperOut0`
**Status:** **Safe by design (Uniswap V3 invariant)**

- Uniswap V3 fee growth values are designed to underflow/wrap in uint256
- The difference computation relies on modular arithmetic matching Uniswap's design
- **Invariant:** Uniswap V3 fee growth specification

---

## C) FINDINGS (Prioritized)

### C-1: Commission Split Accounting Leak with Builder Codes

| Field                       | Value                                                                                                                                |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| **ID**                      | ARITH-001                                                                                                                            |
| **Severity**                | Low                                                                                                                                  |
| **Impact Class**            | 1 (value extraction)                                                                                                                 |
| **File:line**               | `CollateralTracker.sol:1581-1598`, `CollateralTracker.sol:1672-1689`                                                                 |
| **Vulnerable expression**   | `(sharesToBurn * protocolSplit) / DECIMALS + (sharesToBurn * builderSplit) / DECIMALS`                                               |
| **Why checks fail**         | `protocolSplit + builderSplit = 9000 < 10000 (DECIMALS)`. The remaining 1000 bps (10%) of shares is neither burned nor transferred.  |
| **Preconditions**           | Builder code present (`feeRecipient != 0`)                                                                                           |
| **Minimal attack sequence** | Open+close positions repeatedly with builder code active                                                                             |
| **Concrete impact**         | Option owner retains ~10% of commission shares. For a 1 bps notional fee on a 1M position, this is ~10 shares leaked per round-trip. |
| **Repeatable**              | Yes, every mint/burn with builder code                                                                                               |

### C-2: `settleLiquidation` mintedShares Underflow Risk

| Field                       | Value                                                                                                                                                                                   |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **ID**                      | ARITH-002                                                                                                                                                                               |
| **Severity**                | Medium                                                                                                                                                                                  |
| **Impact Class**            | 1 (value extraction) / 2 (solvency bypass)                                                                                                                                              |
| **File:line**               | `CollateralTracker.sol:1338-1344`                                                                                                                                                       |
| **Vulnerable expression**   | `Math.mulDivCapped(...) - liquidateeBalance` in unchecked                                                                                                                               |
| **Why checks fail**         | No guarantee that `mulDivCapped result >= liquidateeBalance`. If bonus is small and totalAssets is large relative to bonus, the capped division can return a value < liquidateeBalance. |
| **Preconditions**           | Liquidation where `bonus > 0`, `bonusShares > liquidateeBalance`, and `mulDivCapped(bonus, _totalSupply - liquidateeBalance, totalAssets() - bonus) < liquidateeBalance`                |
| **Minimal attack sequence** | Create position near insolvency, get liquidated with small positive bonus                                                                                                               |
| **Concrete impact**         | `mintedShares` wraps to ~`2^256 - small`, capped to `_totalSupply * DECIMALS`. Liquidator receives up to `_totalSupply * 10_000` new shares — massive dilution.                         |
| **Mitigant**                | The `Math.min` cap limits to `_totalSupply * DECIMALS` which could still be very large                                                                                                  |
| **Repeatable**              | Requires specific liquidation conditions                                                                                                                                                |

### C-3: `tokenPaid` Addition Overflow in `settleMint`/`settleBurn`

| Field                     | Value                                                                                                                                                                        |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **ID**                    | ARITH-003                                                                                                                                                                    |
| **Severity**              | Low                                                                                                                                                                          |
| **Impact Class**          | 3 (DoS)                                                                                                                                                                      |
| **File:line**             | `CollateralTracker.sol:1601`, `CollateralTracker.sol:1692`                                                                                                                   |
| **Vulnerable expression** | `tokenPaid += int128(uint128(commissionFee))` in unchecked                                                                                                                   |
| **Why checks fail**       | If `tokenPaid` is near `int128.max` and `commissionFee` is added, the int128 wraps to negative in unchecked                                                                  |
| **Preconditions**         | Extremely large positions where `tokenPaid` and `commissionFee` together exceed `int128.max`                                                                                 |
| **Concrete impact**       | `tokenPaid` wraps negative, potentially causing incorrect settlement direction                                                                                               |
| **Mitigant**              | Position size bounded at `int128.max - 4` (SFPM:915) which bounds `tokenPaid`. Commission is a small fraction of notional. Likely safe in practice but unproven at boundary. |
| **Status**                | Unproven                                                                                                                                                                     |

### C-4: `_accrueInterest` burntInterestValue exceeds `_unrealizedGlobalInterest`

| Field            | Value                                                                                                                                                                                  |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **ID**           | ARITH-004                                                                                                                                                                              |
| **Severity**     | Informational (mitigated)                                                                                                                                                              |
| **Impact Class** | 1 (accounting drift)                                                                                                                                                                   |
| **File:line**    | `CollateralTracker.sol:962-968`                                                                                                                                                        |
| **Expression**   | `if (burntInterestValue > _unrealizedGlobalInterest) { _unrealizedGlobalInterest = 0; }`                                                                                               |
| **Why**          | The code explicitly handles this with clamping. The comment at lines 956-961 explains the root cause: compound rounding in borrowIndex vs additive accumulation in unrealizedInterest. |
| **Impact**       | Small accounting drift between individual interest payments and global interest tracker, capped at a few wei per interaction. Properly mitigated.                                      |

---

## D) CONTRACT-WIDE ARITHMETIC INVARIANTS

### D.1 Conservation Relations

| Invariant                                                                | Established                     | Consumed                                             | Breaks If                                                                          |
| ------------------------------------------------------------------------ | ------------------------------- | ---------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `totalAssets() = s_depositedAssets + s_assetsInAMM + unrealizedInterest` | `CollateralTracker.sol:503-506` | `convertToShares`, `convertToAssets`, all settlement | Any component overflows its `uint128` slot or wraps                                |
| `totalSupply() = _internalSupply + s_creditedShares`                     | `CollateralTracker.sol:512-514` | All share mint/burn operations                       | creditedShares underflow (handled at :1447), or internalSupply overflow (at :1290) |
| `s_depositedAssets + s_assetsInAMM` tracks all non-interest assets       | Settlement functions            | Solvency checks                                      | `ammDeltaAmount` or `shortAmount` miscalculated                                    |

### D.2 Accumulator Monotonicity

| Invariant                                                                                     | Established                          | Consumed                                                | Breaks If                                                                  |
| --------------------------------------------------------------------------------------------- | ------------------------------------ | ------------------------------------------------------- | -------------------------------------------------------------------------- |
| `s_accountPremiumOwed[key]` and `s_accountPremiumGross[key]` are monotonically non-decreasing | `SFPM.sol:1106-1112` via `addCapped` | `PanopticPool._getPremia:2220-2231` (delta calculation) | Accumulator somehow decreases — prevented by `addCapped` only adding       |
| `borrowIndex` is monotonically non-decreasing                                                 | `CollateralTracker.sol:1027-1031`    | `_getUserInterest:1085`                                 | Interest rate goes negative — prevented by IRM bounds                      |
| Oracle `epoch` is monotonically non-decreasing                                                | `OraclePack.sol:548`                 | Observation insertion guard                             | `block.timestamp` wraps mod `2^24` — happens after ~34 years in 64s epochs |

### D.3 Conversion Round-Trip Bounds

| Invariant                                             | Location                        | Breaks If                                       |
| ----------------------------------------------------- | ------------------------------- | ----------------------------------------------- |
| `convertToShares(convertToAssets(shares)) <= shares`  | `CollateralTracker.sol:520-528` | Floor-floor composition — holds by construction |
| `convertToAssets(convertToShares(assets)) <= assets`  | Same                            | Floor-floor composition — holds by construction |
| `previewMint` rounds up to prevent free share minting | `CollateralTracker.sol:606`     | `mulDivRoundingUp` correctly rounds up          |
| `previewWithdraw` rounds up shares burned             | `CollateralTracker.sol:698`     | `mulDivRoundingUp` correctly rounds up          |

### D.4 Packed Field Range Constraints

| Type            | Field              | Bits    | Valid Range     | Enforced At                                                     |
| --------------- | ------------------ | ------- | --------------- | --------------------------------------------------------------- |
| MarketState     | borrowIndex        | 80      | [1e18, 2^80]    | `CollateralTracker.sol:1031` (.toUint128 then stored as uint80) |
| MarketState     | unrealizedInterest | 106     | [0, 2^106 - 1]  | `MarketState.sol:141` (masked to 106 bits)                      |
| OraclePack      | residuals          | 12 each | [-2048, 2047]   | `OraclePack.sol:447-451` (rebase if > threshold)                |
| OraclePack      | EMAs               | 22 each | [-2^21, 2^21-1] | `OraclePack.sol:116-119` (masked to 22 bits)                    |
| PositionBalance | positionSize       | 128     | [0, 2^128-1]    | `SFPM.sol:915` (bounded at int128.max-4)                        |

---

## E) PATCHES + TESTS

### E.1 Patch for C-1 (Commission Split Leak)

**CollateralTracker.sol:1577-1598** — When `feeRecipient != 0`, the remaining shares (after protocol+builder splits) should be burned:

```solidity
// PATCH: burn remainder to prevent share leak
uint256 protocolShares = (sharesToBurn * riskParameters.protocolSplit()) / DECIMALS;
uint256 builderShares = (sharesToBurn * riskParameters.builderSplit()) / DECIMALS;
uint256 remainder = sharesToBurn - protocolShares - builderShares;
_transferFrom(optionOwner, address(riskEngine()), protocolShares);
_transferFrom(optionOwner, address(uint160(riskParameters.feeRecipient())), builderShares);
if (remainder > 0) _burn(optionOwner, remainder);
```

Same pattern at lines 1672-1689 for `settleBurn`.

### E.2 Patch for C-2 (settleLiquidation underflow)

**CollateralTracker.sol:1338-1346** — Add underflow guard:

```solidity
uint256 rawMinted = Math.mulDivCapped(
    uint256(bonus),
    _totalSupply - liquidateeBalance,
    uint256(Math.max(1, int256(totalAssets()) - bonus))
);
// PATCH: guard against underflow
uint256 mintedShares = rawMinted > liquidateeBalance
    ? Math.min(rawMinted - liquidateeBalance, _totalSupply * DECIMALS)
    : 0;
```

### E.3 Test Suggestions

#### C-1 Tests (Commission Leak):

```solidity
// Test 1: Verify exact accounting
function test_commissionSplitExactAccounting() public {
  // Setup: deploy with builder code active
  // Action: mint position, capture balances before/after
  // Assert: protocolShares + builderShares + burned == sharesToBurn
}

// Test 2: Boundary with max notional
function test_commissionSplitWithMaxNotional() public {
  // Setup: deposit type(uint104).max
  // Action: mint max position with builder code
  // Assert: no share dust remains in option owner
}

// Test 3: Rounding at minimum
function test_commissionSplitRoundingAtBoundary() public {
  // Setup: sharesToBurn = 1
  // Assert: no dust left (0 or 1 share properly handled)
}
```

#### C-2 Tests (Liquidation Underflow):

```solidity
// Test 1: Small bonus, large pool
function test_settleLiquidation_smallBonusLargePool() public {
  // Setup: bonus=1, totalAssets=2^104
  // Assert: mintedShares does not underflow
}

// Test 2: Edge case equality
function test_settleLiquidation_bonusEqualsLiquidateeBalance() public {
  // Assert: correct behavior at equality boundary
}

// Test 3: Max protocol loss
function test_settleLiquidation_maxProtocolLoss() public {
  // Assert: cap at _totalSupply * DECIMALS is effective
}
```

#### Fuzz Invariants:

```solidity
// Fuzz: totalAssets conservation
function invariant_totalAssetsConservation() public {
  assertEq(
    ct.totalAssets(),
    uint256(ct.s_depositedAssets()) + ct.s_assetsInAMM() + ct.s_marketState().unrealizedInterest()
  );
}

// Fuzz: commission split completeness
function fuzz_commissionSplitCompleteness(uint128 sharesToBurn) public {
  uint256 protocolPart = (sharesToBurn * PROTOCOL_SPLIT) / DECIMALS;
  uint256 builderPart = (sharesToBurn * BUILDER_SPLIT) / DECIMALS;
  assertLe(protocolPart + builderPart, sharesToBurn);
  uint256 leak = sharesToBurn - protocolPart - builderPart;
  assertLe(leak, (sharesToBurn * (DECIMALS - PROTOCOL_SPLIT - BUILDER_SPLIT)) / DECIMALS + 2);
}

// Fuzz: liquidation mintedShares bounds
function fuzz_settleLiquidationNoUnderflow(uint256 bonus, uint256 liquidateeBalance) public {
  vm.assume(bonus > 0 && bonus < type(uint104).max);
  vm.assume(liquidateeBalance < type(uint248).max);
  // Verify mulDivCapped result - liquidateeBalance doesn't underflow
}
```

---

## F) RISK CLASSIFICATION SUMMARY

| ID        | Severity      | Impact Class                      | Exploitable? | Repeatable? |
| --------- | ------------- | --------------------------------- | ------------ | ----------- |
| ARITH-001 | Low           | 1 (value extraction)              | Yes          | Yes         |
| ARITH-002 | Medium        | 1/2 (value extraction / solvency) | Conditional  | Conditional |
| ARITH-003 | Low           | 3 (DoS)                           | Unproven     | Unlikely    |
| ARITH-004 | Informational | 1 (accounting drift)              | Mitigated    | N/A         |
