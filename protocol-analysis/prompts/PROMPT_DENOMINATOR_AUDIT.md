You are a senior Solidity security researcher performing a denominator-sensitivity audit.

Scope restriction (hard):

- Analyze ONLY files under `contracts/` (recursive).
- Ignore anything outside `contracts/`.
- If you reference a file outside `contracts/`, mark it "out of scope" and do not rely on it for conclusions.

Objective:
Exhaustively evaluate all division operations and ratio computations across the protocol to find:

1. Division-by-zero paths that revert or silently produce wrong results
2. Division-by-epsilon (denominator→1) paths that produce extreme/unbounded quotients
3. Ratio singularities where small changes to the denominator produce large output swings (sensitivity)
4. Denominator manipulation by an adversary choosing position parameters, timing, or ordering
5. Cascading denominator collapse where one degenerate ratio feeds into another

Assumptions:

- Full MEV adversary with sandwich capability.
- Attacker can choose position sizes, liquidity amounts, timing, ordering of operations.
- Attacker can arrange for extreme but valid protocol states (e.g., nearly-empty pools, single-wei liquidity, etc.).
- A denominator that CAN reach zero/epsilon WILL reach it if the attacker benefits.
- "Handled by upstream checks" is only valid if you can prove the check is unconditional and cannot be bypassed through any call path.

Background context (from prior audits):

- ERC4626 vault with virtual shares (10^6 initial supply, 1 initial asset). `totalAssets()` = `s_depositedAssets + s_assetsInAMM + unrealizedInterest`. Min value = 1 (post-init).
- `totalSupply()` = `_internalSupply + s_creditedShares`. Min value = 10^6 (post-init, before deposits).
- `unsafeDivRoundingUp(a, b)` returns 0 (not revert) when `b == 0` — assembly `div` returns 0
- `mulDiv(a, b, 0)` reverts via `require(denominator > 0)`
- `mulDivCapped(a, b, 0)` reverts via `require(denominator > 0)`
- Premium base formula: `collected * totalLiquidity * 2^64 / netLiquidity^2` (SFPM:1334-1343)
- Available premium formula: `premOwed * settledTokens / max(accumulated, type(uint256).max)` — uses sentinel when accumulated==0 (PP:2282)
- grossPremiumLast update: `(C*R + L*T) / totalLiquidity` — totalLiquidity used as divisor (PP:1240)
- Liquidation mintedShares: `mulDivCapped(bonus, supply-liqBal, max(1, totalAssets-bonus))` — max(1,...) guard (CT:1343)
- Collateral ratios use `DECIMALS` (10000) and `80000` as static denominators (safe)
- Interest: `_getUserInterest` divides by `userBorrowIndex` (CT:1086) — must be nonzero for any borrower
- Position size bounded at int128.max - 4, deposit cap at type(uint104).max

Deliverables (strict order):

A) Division Inventory
For every division operation (/, mulDiv, mulDivXX, unsafeDivRoundingUp, right-shifts on non-constant values) in `contracts/**`:

1. Identify the expression and its denominator (file:line)
2. Classify the denominator:
   - CONSTANT (e.g., DECIMALS, 2^64, WAD) → safe, skip detailed analysis
   - STATE-DEPENDENT (e.g., totalAssets, netLiquidity) → analyze reachable range
   - USER-CONTROLLED (e.g., positionSize, optionRatio) → analyze manipulation potential
3. For non-constant denominators, determine:
   a. Can it be zero? Under what conditions?
   b. Can it be 1 (or near-1)? Under what conditions?
   c. What is the maximum quotient when the denominator is minimized?
   d. Is there an explicit guard (require/revert/if-check/clamp)?
   e. If guarded, is the guard on EVERY call path or just some?

Focus areas (these are the known denominator hotspots from prior analysis):

### ERC4626 Denominators

- `totalAssets()` as denominator in convertToShares, previewDeposit, previewWithdraw, \_accrueInterest shares computation, \_updateBalancesAndSettle, settleMint, settleBurn
- `totalSupply()` as denominator in convertToAssets, previewMint, previewRedeem, \_accrueInterest asset conversion
- Can `totalAssets()` reach 0 post-initialization? (s_depositedAssets can be drained, but init sets it to 1; does interest or settlement ever subtract past 0?)
- Can `totalSupply()` reach 0 post-initialization? (\_internalSupply starts at 10^6, only modified by \_mint/\_burn and \_internalSupply adjustments in settleLiquidation)

### Premium System Denominators

- `netLiquidity^2` in premium base calculation (SFPM:1337-1342). netLiquidity is `currentLiquidity.rightSlot()`. Guard: `currentLiquidity.rightSlot() > 0` check at SFPM:1065. But is this check present on ALL paths that reach \_getPremiaDeltas?
- `totalLiquidity` in grossPremiumLast updates (PP:1240, PP:1405). Guard: totalLiquidity is `netLiquidity + removedLiquidity`. Can both be 0 simultaneously?
- `totalLiquidity^2` in gross premium denominator (SFPM:1377). Same concern.
- `accumulated0 == 0 ? type(uint256).max : accumulated0` sentinel in \_getAvailablePremium (PP:2282). What happens when accumulated is exactly 1? `premOwed * settled / 1` can produce extremely large values — is this capped correctly?
- `longPremium.rightSlot()` and `longPremium.leftSlot()` as denominators in haircutPremia (RE:742, RE:759). Guard: `longPremium.rightSlot() != 0` check at RE:734. Correct for that slot, but verify both slots are independently guarded.

### Interest Rate Denominators

- `userBorrowIndex` in \_getUserInterest (CT:1086). Initial value is WAD (1e18). Can it ever be 0? What about 1? (borrowIndex starts at 1e18 and only grows via mulDivWadRoundingUp, so minimum is 1e18 — VERIFY).
- `WAD - TARGET_UTILIZATION` and `TARGET_UTILIZATION` in \_borrowRate error normalization (RE:2203-2204). These are constants — verify they're nonzero.
- `totalAssets()` in pool utilization calculation (CT:1175, CT:1216). Can reach 1 (init value). At 1, utilization = `assetsInAMM * 10000 / 1` which can be > 10000 (100%).
- `CURVE_STEEPNESS` and rate model denominators (RE:2276-2280). Constants — verify.

### Liquidation Denominators

- `max(1, totalAssets() - bonus)` in settleLiquidation mintedShares (CT:1343). When bonus ≈ totalAssets, denominator → 1, quotient → totalSupply (unbounded by assets). The max(1,...) prevents zero but allows extreme amplification.
- `totalLiquidity` in grossPremiumLast post-burn update (PP:1387, PP:1405). During liquidation, all positions are burned. Can the last burn leave totalLiquidity == 0? If so, the ternary at PP:1387 `totalLiquidity != 0 ? ... : ...` handles it.

### Conversion Denominators

- `sqrtPriceX96^2` in convert0to1 (PM:507). sqrtPriceX96 minimum is `MIN_POOL_SQRT_RATIO + 1` ≈ 4295128740. Squared ≈ 1.8e19. Non-degenerate.
- `highPriceX96 - lowPriceX96` in getLiquidityForAmount0 (Math:398). This is the sqrt price difference. For tickSpacing=1 and adjacent ticks, this is very small. Can it be 0? Only if tickLower == tickUpper, which is prevented by TokenId validation.
- `lowPriceX96` in getAmount0ForLiquidity (Math:346). Minimum at MIN_POOL_TICK: sqrtPrice ≈ 4295128740. Non-zero but small — check for amplification.
- `vegoid` in premium spread formula: `removedLiquidity / vegoid` (SFPM:1351). vegoid ∈ [1,255] from TokenId. At vegoid=1, full spread. At vegoid=255, minimal spread.

### Oracle Denominators

- `timestamps[i] - timestamps[i+1]` in computeMedianObservedPrice (PM:289). Can two consecutive observations have the same timestamp? If so, division by zero.
- EMA divisor of 10 in twapEMA (RE:817): `(6*fast + 3*slow + eonsEMA) / 10`. Constant, safe.

B) Sensitivity Analysis
For each non-constant denominator that can reach small (but nonzero) values:

1. Compute the denominator's reachable minimum value
2. Compute the corresponding maximum quotient
3. Determine if the maximum quotient overflows, is capped (by mulDivCapped/toUint128Capped), or propagates unguarded
4. Determine if an adversary can manipulate the denominator to its minimum
5. If the quotient feeds into downstream operations, trace the amplification chain

Specific sensitivity scenarios to analyze:

- **Liquidity vacuum:** Attacker removes all but 1 unit of netLiquidity in a chunk, then triggers premium collection → `collected * total * 2^64 / 1` → huge premium accumulator delta → what downstream effects?
- **Asset drain:** Through repeated borrows/settlements, can `totalAssets()` be driven to 1? Then `convertToShares(1)` = `1 * supply / 1` = `supply` — minting supply-many shares for 1 wei.
- **Interest amplification:** If `assetsInAMM >> totalAssets` (possible through settlement timing?), pool utilization > 100% → interest rate model behavior?
- **Accumulated premium → 0 sentinel:** When `accumulated0 == 0`, the sentinel `type(uint256).max` makes `premOwed * settled / type(uint256).max → 0`. But what if `accumulated0 == 1`? Then `premOwed * settled / 1` = full premium. Is this reachable? What are the preconditions?
- **Liquidation bonus ≈ totalAssets:** The denominator `totalAssets - bonus` → 0. With max(1,...) guard, quotient → bonus _ (supply - liqBal) / 1. This could mint up to `totalSupply _ DECIMALS` shares. Is this the intended behavior?
- **Oracle stale timestamps:** Can `timestamps[i] == timestamps[i+1]` in the Uniswap oracle, causing division by zero in TWAP computation?
- **Tiny netLiquidity with large collectedAmounts:** If netLiquidity = 1 and collected = 1e18, then `premium_base = 1e18 * (1 + R) * 2^64 / 1 ≈ 1.8e37`. Does this overflow mulDiv? Does it get capped by toUint128Capped?

C) Call-Path Analysis
For each critical denominator, enumerate ALL call paths that reach the division:

1. Which external functions lead to this division?
2. For each path, is there a guard on the denominator BEFORE the division?
3. Are there paths where the guard is absent (e.g., internal function called from a new context)?
4. Can reentrancy or cross-function interaction bypass a guard?

Critical paths to trace:

- `_getPremiaDeltas` ← `_updateStoredPremia` ← `_collectAndWritePositionData` ← `_createLegInAMM` — the `currentLiquidity.rightSlot() > 0` guard is at SFPM:1065, BEFORE calling \_collectAndWritePositionData. But is this the ONLY path to \_getPremiaDeltas?
- `_getAvailablePremium` ← `_updateSettlementPostBurn` / `_calculateAccumulatedPremia` — does the accumulated==0 sentinel handle all edge cases?
- `convertToShares` / `convertToAssets` ← called from 15+ locations — is totalAssets()/totalSupply() guaranteed nonzero on every path?
- `grossPremiumLast` updates ← called from \_updateSettlementPostMint (PP:1234) and \_updateSettlementPostBurn (PP:1387). The burn path has a `totalLiquidity != 0` guard. The mint path divides by `totalLiquidity` at PP:1240 — is this always nonzero during a mint?

D) Findings (prioritized)
For each issue:

- ID (DENOM-NNN)
- Severity (Critical / High / Medium / Low / Informational)
- Category: div-by-zero / div-by-epsilon / sensitivity / manipulation / cascade
- File:line(s) involved
- Exact expression with denominator identified
- Reachable denominator range and the conditions to reach the extreme
- Impact when denominator is at its extreme (revert? Wrong result? Value extraction?)
- Whether an adversary can force the extreme state
- Minimal PoC sequence

E) Patches + Tests
For each finding:

1. Minimal patch (add guard, add clamp, add cap, restructure formula)
2. Test for denominator == 0 (should revert gracefully or be prevented)
3. Test for denominator == minimum reachable nonzero value (should produce bounded output)
4. Test for adversarial denominator manipulation (sandwich, multi-step)

Review rules:

- Do not dismiss a finding because "this state is unlikely." If it's reachable, it's a finding.
- Do not assume upstream guards without tracing EVERY call path.
- Constant denominators (DECIMALS, WAD, 2^64, etc.) can be noted once and then skipped.
- For `unsafeDivRoundingUp(a, 0)` = 0: this IS a finding if the caller expects a revert or nonzero result.
- For `mulDiv(a, b, 0)`: this reverts, which is correct IF the caller handles the revert. If it's in a view function used for solvency checks, a revert = DoS.
- A denominator that is "always nonzero" per comments but lacks a formal require() is a finding unless you can prove it from invariants.
- If a denominator CAN be very small (but nonzero), the quotient amplification matters even if no overflow occurs — trace what happens downstream with the inflated value.

---

Design notes for this prompt:

This prompt differs from the rounding audit in that:

- It focuses on the DENOMINATOR specifically, not the rounding direction
- It requires call-path tracing for every guard (guards only work if they're on every path)
- It demands sensitivity analysis (what quotient magnitudes are reachable?)
- It targets ratio singularities where `f(x) = N/x` has a pole at x=0
- It explicitly asks about cascading denominators (one degenerate ratio feeding into another)
- It references the specific denominator hotspots discovered during prior audits
- It asks about `unsafeDivRoundingUp(a, 0) → 0` which is a known non-standard behavior in Math.sol

The key denominators ranked by risk (from prior analysis):

1. `netLiquidity^2` (SFPM:1337) — can approach 0 if all liquidity is removed, guarded at SFPM:1065 but only on one call path
2. `totalAssets() - bonus` in liquidation (CT:1343) — max(1,...) guard prevents zero but allows quotient amplification
3. `totalAssets()` in ERC4626 (CT:521 etc.) — init guarantees ≥1, but verify no path can drain it to 0
4. `accumulated` in available premium (PP:2282) — sentinel for 0, but no protection against 1
5. `totalLiquidity` in grossPremiumLast (PP:1240) — must be nonzero during mint, verify
6. `userBorrowIndex` in interest (CT:1086) — starts at WAD, only grows, should be safe
7. `timestamps[i] - timestamps[i+1]` in oracle (PM:289) — can Uniswap timestamps collide?
