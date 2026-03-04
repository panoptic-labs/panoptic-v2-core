# Liquidation & Force Exercise Game Theory Audit

**Date:** 2026-03-03
**Scope:** `contracts/` (recursive)
**Focus:** Economic attack surface of liquidation and force exercise mechanisms

---

## A) Liquidation Attack Surface Map

### A.1 Self-Liquidation via Operator

**Attack Scenario:**

1. Attacker controls Account A (liquidatee) and Account B (liquidator = `msg.sender`)
2. A deposits `D` tokens as collateral
3. A creates a position (paying commission `C = notional × notionalFee / DECIMALS`)
4. A's effective balance = `D - C`
5. Price moves (or attacker manipulates), A becomes insolvent at all 4 oracle ticks
6. B calls `dispatchFrom()` to liquidate A at PP:1592
7. B receives the liquidation bonus; A is wiped

**Bonus Computation (RE:520-521):**

```
bonus = min(bal/2, max(0, req - bal))
```

**Concrete Numbers:**

- Deposit `D = 10,000 USDC`, notionalFee = 50 bps (14-bit uint, configurable)
- Commission `C = 10,000 × 50/10,000,000 × notional_multiplier`
- Effective balance ≈ `9,950 USDC` (assuming notional ≈ deposit)
- **Best case for attacker (deep insolvency):** `bonus = bal/2 ≈ 4,975 USDC`
- **Attacker's P&L:** `bonus - D = 4,975 - 10,000 = -5,025 USDC`

**Marginal insolvency:**

- If `req = bal + ε`: `bonus = ε` (negligible)
- Commission already consumed ≈ 5-50 bps of notional

**Verdict: NOT PROFITABLE**

The bonus cap at `bal/2` (RE:520) is the decisive protection. An attacker controlling both accounts always loses at least `bal/2 + commission`. The remaining shortfall is socialized as protocol loss to PLPs, but the attacker cannot capture more than `bal/2` through self-liquidation.

**Cross-collateral enhancement:** Even exploiting the cross-collateral conversion at RE:539-574, the total bonus value (converted at `twapTick`) cannot exceed `bal/2` in aggregate value because both token bonuses originate from the same pool of collateral.

**Mitigation effectiveness:** The `min(bal/2, ...)` cap is a strong structural defense. No parameter changes can make self-liquidation profitable for a single actor.

---

### A.2 Liquidation Price Manipulation

**Critical context:** Liquidation requires insolvency at **ALL 4 ticks** simultaneously (PP:1584, `solvent == 0`):

1. `spotTick` — Spot EMA (60s period)
2. `twapTick` — Weighted blend: `(6 × fastEMA + 3 × slowEMA + eonsEMA) / 10` (RE:817)
3. `latestTick` — Most recent clamped observation
4. `currentTick` — Live Uniswap pool tick

**Note:** `twapTick` is NOT the Uniswap TWAP. It is an internally-computed EMA blend from the Panoptic oracle (RE:814-818). This is a stronger defense than using Uniswap's accumulator-based TWAP.

**Oracle Resistance Layers:**

| Defense                  | Mechanism                                                      | Reference                 |
| ------------------------ | -------------------------------------------------------------- | ------------------------- |
| Per-observation clamping | ±149 ticks max deviation from last observation                 | RE:95, OraclePack:509-526 |
| 64-second epochs         | 1 observation per 64s minimum                                  | OraclePack:548            |
| Spot EMA (60s)           | `spotEMA += timeDelta × (newTick - spotEMA) / 60`              | OraclePack:359            |
| Fast EMA (120s)          | 40% max convergence per observation                            | OraclePack:359            |
| Slow EMA (240s)          | 20% max convergence per observation                            | OraclePack:359            |
| Eons EMA (960s)          | 5% max convergence per observation                             | OraclePack:359            |
| Cascading timeDelta cap  | Each EMA caps timeDelta to `0.75 × period` for downstream EMAs | OraclePack:374-397        |

**Single-block (flash loan) attack:**

- `currentTick`: Can be moved arbitrarily via flash loan
- `spotTick (spotEMA)`: Moves at most `0.75 × 149 ≈ 112 ticks` per observation. Cannot be moved in the same block as the flash loan because the observation was already recorded at the start of the epoch.
- `twapTick`: Blend of fast/slow/eons EMAs, moves even slower. Per-observation movement ≈ `0.75 × 149 × (6×0.533 + 3×0.267 + 0.05)/10 ≈ 45 ticks`.
- `latestTick`: Clamped to ±149 ticks from prior observation.

**Conclusion:** A flash loan can manipulate `currentTick` but not the other 3. Since ALL 4 must show insolvency, **flash-loan-triggered liquidations are impossible** against accounts solvent at the internal oracle ticks.

**Multi-block proposer MEV:**

- To move `spotEMA` by X ticks: need sustained manipulation over ≈ `X / 112` observations × 64s
- To move `twapTick` by X ticks: need ≈ `X / 45` observations × 64s
- For an account marginally solvent by 100 ticks (≈1% price): need ≈ 2-3 observations (128-192 seconds) for spotEMA, ≈ 3 observations (192 seconds) for twapTick
- **Minimum time for proposer attack: ~3-4 minutes** of sustained manipulation
- On Ethereum L1: requires 3-4 minutes of consecutive block production (extremely rare, ~15 consecutive blocks)
- On L2s (single sequencer): theoretically easier but still requires sustained capital commitment

**Capital cost of sustained manipulation:**

- Must maintain a distorted Uniswap pool price for 3+ minutes
- Requires continuous capital lock-up in the pool (not just flash loan)
- For a deep-liquidity pool: cost of moving price by 1% for 3 minutes ≈ millions in opportunity cost
- **Attack is economically infeasible for normal pools**

**Edge case — shallow pool:** In a low-liquidity pool, moving the price is cheaper. However, positions in low-liquidity pools are typically smaller, limiting the extractable bonus (which is capped at `bal/2`).

---

### A.3 Liquidation Sandwiching

**Attack:**

1. Attacker sees pending liquidation tx in mempool
2. Front-run: move Uniswap price to maximize protocol loss
3. Liquidation executes (or attacker replaces the original liquidator)
4. Back-run: reverse price movement

**Analysis of what the attacker can influence:**

The **bonus** is computed at `twapTick` (RE:1730: `Math.getSqrtRatioAtTick(twapTick)`), which is an EMA blend that cannot be moved within a single block. The bonus itself is sandwiching-resistant.

However, `netPaid` (PP:1716-1722) depends on the actual Uniswap burn, which happens at `currentTick`. Position burning removes liquidity from Uniswap, and the token composition of what's received depends on where `currentTick` is relative to the position's range.

**Sandwiching netPaid:**

- If the attacker moves the price such that a position that was in-range is now out-of-range, the burn returns 100% of one token and 0% of the other
- This changes the token composition of `netPaid`
- Since `collateralRemaining = balance - netPaid - bonus` per token (RE:584-586), shifting the token composition can create protocol loss in one token while showing surplus in the other
- The cross-collateral conversion in `getLiquidationBonus` (RE:539-574) partially mitigates this, but the conversion is at `twapTick` which may differ from the manipulated spot

**Extractable value:**

- The attacker can only profit if they can capture the price reversion. But the liquidation itself removes liquidity from Uniswap (burns), so the AMM state changes.
- The excess protocol loss from composition manipulation is socialized to PLPs, not captured by the sandwicher directly.
- The liquidator bonus is already capped at `bal/2` regardless of manipulation.

**Net assessment:** Low value extraction. The sandwicher can increase protocol loss (harming PLPs) but cannot increase their own bonus beyond `bal/2`. The main risk is to PLPs, not a profit center for attackers.

**Mitigation effectiveness:**

- Bonus at `twapTick`: Strong protection against bonus manipulation.
- `MIN_SWAP_TICK`/`MAX_SWAP_TICK` tick limits on burns: Prevents ITM swaps during liquidation.
- The remaining risk (netPaid composition manipulation) is bounded by the position's notional value and the cross-collateral conversion.

---

### A.4 Cascade Liquidation Amplification

**Mechanism:**

1. Liquidation of Account A causes protocol loss → shares minted in `settleLiquidation` (CT:1349)
2. `_internalSupply` increases → `totalSupply()` increases → share price = `totalAssets()/totalSupply()` decreases
3. All PLP balances (in asset terms) decrease
4. Accounts using CT shares as collateral see their balance decrease
5. Marginally-solvent accounts may become insolvent → further liquidations

**Cap on per-liquidation dilution (CT:1345):**

```
mintedShares = Math.min(rawMinted - liquidateeBalance, _totalSupply * DECIMALS)
```

Where `DECIMALS = 10_000` (CT:118).

Maximum dilution per liquidation = `totalSupply * 10,000`, i.e., share price can decrease to `totalAssets / (totalSupply * 10,001)`, reducing share price by factor ≈ `1/10,001` ≈ 99.99% in the extreme case. **This cap is too generous — see LIQ-005 and recommendation F.5.**

**Natural damping:**

1. Each liquidation removes the most-insolvent account, reducing systemic risk
2. After liquidation, remaining accounts that were marginally solvent may have slightly reduced collateral but the insolvent account is gone
3. The bonus cap limits the size of protocol loss per event
4. The haircut mechanism (`haircutPremia` at RE:599) recovers premium from the liquidatee, reducing net protocol loss

**Maximum cascade depth:**

- Each liquidation reduces the total system collateral by `protocol_loss`
- Protocol loss = `balance - paid` where `paid = bonus + netPaid` (RE:584)
- In the worst case (deep insolvency, no haircut recovery), protocol loss ≈ position notional loss
- The cascade stops when remaining accounts have sufficient buffer above their requirements

**Strategic cascade trigger:**

- An attacker could theoretically identify the most-leveraged account and liquidate it first to maximize the cascade
- But the attacker gains at most `bal/2` from the first liquidation and must themselves remain solvent (PP:1600-1606)
- The cascading losses are socialized to ALL PLPs, including the attacker if they hold CT shares

**Concrete example:**

- Pool has $10M total assets, $10M total supply (1:1 share price)
- Worst-case liquidation creates $100K protocol loss
- 10,000 shares minted → new supply = $10.01M
- New share price = $10M / $10.01M ≈ $0.999
- 0.1% decline per $100K loss
- To cascade: need marginally-solvent accounts with <0.1% buffer → unlikely in practice

**Verdict: Theoretical but impractical.** The cap on minted shares and the `bal/2` bonus cap provide natural bounds. Cascade requires multiple accounts to be within fractions of a percent of insolvency simultaneously.

---

### A.5 Premium Haircut Timing Attack

**Question:** Can a seller arrange to settle their premium BEFORE the liquidation to avoid haircut?

**Analysis:**

`haircutPremia` (RE:599-778) processes only the **liquidatee's** `premiasByLeg`. It does not touch other accounts' settled premium. The haircut is computed from:

- `premiasByLeg` — premium attributed to the liquidatee's positions
- `collateralRemaining` — protocol loss from the liquidation

**Can a third-party seller front-run to settle?**
A short seller (third party) can call `dispatchFrom` to trigger `_settlePremium` on a long buyer's position. But:

1. `_settlePremium` requires the position owner to be **solvent at all 4 ticks** (PP:1536)
2. If the position owner is the about-to-be-liquidated account, they're already insolvent → cannot settle premium
3. If it's a different account's position in the same chunk, their premium settlement doesn't affect the liquidatee's `premiasByLeg`

**Can the liquidatee front-run their own liquidation?**
The liquidatee is insolvent at all 4 ticks → they cannot call any `dispatchFrom` operation other than getting liquidated (PP:1584-1592 path). They cannot settle premium.

**Indirect effect via `s_settledTokens`:**
`InteractionHelper.settleAmounts` (PP:1757) updates `s_settledTokens` after the haircut. If a third party settles premium for their own position in the same chunk _before_ the liquidation, this modifies `s_settledTokens` and could affect the `_calculateAccumulatedPremia` output for the liquidatee.

However, the premium accumulators use a continuous accumulation model. Settling one account's premium doesn't change the accumulator values — it only changes that account's last-known accumulator checkpoint. The liquidatee's `premiasByLeg` is computed from the accumulator difference, which is unaffected by third-party settlements.

**Verdict: NOT EXPLOITABLE.** The haircut mechanism operates exclusively on the liquidatee's premium. Third-party settlements do not affect the liquidatee's premium calculations or the haircut amounts.

---

### A.6 Bonus Manipulation via Position Construction

**Goal:** Maximize `bonus/collateral` ratio.

**Formula:** `bonus = min(bal/2, max(0, req - bal))`

**Analysis:**

The ratio is maximized when both conditions bind:

- `req - bal` is maximized (deep insolvency)
- `bal/2` is the binding cap

When `req ≥ 2 × bal`: `bonus = bal/2`, which is the maximum regardless of position type.

**Position types and their `req/bal` at insolvency:**

| Strategy               | Collateral Requirement                                              | Max `req/bal` at Insolvency        |
| ---------------------- | ------------------------------------------------------------------- | ---------------------------------- |
| Naked short put        | `SELLER_COLLATERAL_RATIO × notional`                                | High (unbounded on price movement) |
| Defined risk spread    | Lower initial req, but `req` increases as short leg goes ITM        | Moderate                           |
| Strangle (short)       | Sum of two naked short requirements                                 | High                               |
| Credit loans (width=0) | `MAINT_MARGIN_RATE × notional` (RE:133: 2_000_000/10_000_000 = 20%) | Moderate                           |

All positions converge to `bonus = bal/2` when deeply insolvent, so position construction does not change the maximum extractable bonus.

**Cross-collateral token arbitrage:**
The bonus is computed per-token then cross-converted (RE:539-574). The conversion uses `atSqrtPriceX96` from `twapTick`. Could an attacker construct positions with deliberate token imbalance?

- Deposit token0 only
- Create positions requiring mostly token1 collateral
- When insolvent: `bonus0 = min(bal0/2, req0 - bal0)`, `bonus1 = 0` (no bal1)
- Cross-conversion: If `paid0 > balance0` and `paid1 ≤ balance1` is impossible because balance1 = 0

In practice, the cross-conversion adjusts bonuses to minimize protocol loss, not to maximize liquidator extraction. The total value transferred to the liquidator is bounded by `bal_total / 2` in aggregate.

**Verdict for options/spreads:** Position construction alone cannot circumvent the `bal/2` cap. The cap applies per-token and the cross-collateral conversion preserves the aggregate constraint.

**However: Loans (width=0, isLong=0) inflate `bal` — see LIQ-008.** Loan creation mints shares to the user (CT:1498-1500, via `tokenToPay = -shortAmount`), inflating `assetsAndInterest(user)`. Unlike credits (width=0, isLong=1), which are offset by `creditAmounts` in `_getMargin` (RE:1158), loans have **no corresponding subtraction**. This inflates the `bal/2` cap in the bonus formula, enabling profitable self-liquidation when combined with far-OTM shorts. See LIQ-008 for full analysis.

---

## B) Force Exercise Attack Surface

### B.1 Force Exercise Griefing

**Cost structure (RE:406-492):**

```
fee = hasLegsInRange ? -FORCE_EXERCISE_COST : -ONE_BPS
    = hasLegsInRange ? -102,400 : -1,000
```

Scaled by `DECIMALS = 10,000,000`:

- **In-range:** 102,400 / 10,000,000 = **1.024%** of notional
- **Out-of-range:** 1,000 / 10,000,000 = **0.01%** of notional (1 bps)

**Note:** The cost is **binary** — there is no exponential decay. Any long leg with `width > 0` that is in-range triggers the 1.024% cost; otherwise 0.01% applies for all out-of-range legs. The comment at RE:482-485 references right-shifting but the current code (RE:486) implements a binary choice.

**Validation check (PP:1564):**

```solidity
if (tokenId.countLongs() == 0 || tokenId.validateIsExercisable() == 0) revert;
```

Position must have at least one long leg with `width > 0`.

**Additionally:** `MAX_TWAP_DELTA_DISPATCH` check (PP:1543): `|currentTick - twapTick| ≤ 513 ticks` — cannot force-exercise during high volatility.

**Griefing economics for out-of-range positions:**

| Position Notional | Exercise Cost (1 bps) | Gas Cost (est.) | Total Cost    |
| ----------------- | --------------------- | --------------- | ------------- |
| $10,000           | $1.00                 | ~$5-50          | ~$6-51        |
| $100,000          | $10.00                | ~$5-50          | ~$15-60       |
| $1,000,000        | $100.00               | ~$5-50          | ~$105-150     |
| $10,000,000       | $1,000.00             | ~$5-50          | ~$1,005-1,050 |

**Impact on victim:**

1. Position forcibly closed — loses strategic exposure
2. Receives exercise fee (trivial for OTM)
3. If position was part of a spread, remaining legs have different risk profile
4. Must re-enter position (paying commission again)

**Scalability:** An attacker can iterate over many positions cheaply. 100 positions at $100K notional each = $1,000 total cost to close $10M worth of positions.

**Who can be targeted:**

- Any account with a solvent position containing long legs with width > 0
- The `positionIdListTo` must match the account's position hash — attacker must know the exact position list

**Verdict: VIABLE GRIEFING VECTOR.** The 1 bps cost for out-of-range positions is economically cheap. The victim's loss is the position itself (strategic value, re-entry cost), which far exceeds the 1 bps compensation.

---

### B.2 Force Exercise + Liquidation Combo

**Scenario:**

- Attacker holds short position S, barely solvent
- Victim holds long position L in same chunk, out of range
- Attacker's co-conspirator force-exercises L

**Mechanism:**
When long L is force-exercised (burned):

- L's liquidity was previously removed from Uniswap (buying a long = removing liquidity)
- Burning L re-adds liquidity to Uniswap
- `removedLiquidity` for that chunk decreases
- `netLiquidity` for that chunk increases
- The effective liquidity ratio changes

**Effect on attacker's short position S:**

- Premium accumulator growth rate depends on `removedLiquidity / netLiquidity` ratio
- Reducing `removedLiquidity` (by exercising L) reduces the spread premium multiplier
- S's premium obligation may decrease, improving solvency margin

**Can this prevent S's liquidation?**

- If S is marginally insolvent, reducing the premium burden by removing L could tip S back to solvent
- But premium is accrued continuously; the change affects future accrual, not the already-accumulated premium
- The already-accumulated premium is stored in `s_grossPremiumLast` and wouldn't change retroactively
- The margin computation in `_getMargin` includes accumulated premium via `shortPremia/longPremia`

**Practical assessment:**
The effect is marginal and forward-looking only. Already-accrued premium (which is what determines current solvency) is not affected by force-exercising another position in the same chunk. The attack does not work for preventing an imminent liquidation.

**Can this trigger liquidation of OTHERS?**

- Force-exercising L changes the chunk's liquidity distribution
- If other accounts depend on L's liquidity for their premium calculations, there could be second-order effects
- But the premium accumulators are global — removing one long doesn't retroactively change other accounts' accumulated premium

**Verdict: NOT EXPLOITABLE for immediate solvency manipulation.** Accumulated premium is already locked in. The effect is on future premium accrual only, which is too slow to exploit in a single transaction.

---

### B.3 Force Exercise Cost Function Analysis

**Binary structure (RE:486):**

```
fee = hasLegsInRange ? -102,400 : -1,000   (out of DECIMALS = 10,000,000)
```

**At what distance does the cost become negligible?**

- The cost is always exactly 1 bps for ANY out-of-range position, regardless of distance
- 1 bps is negligible for large positions: $1 per $10,000 notional
- At $100K+ notional, the gas cost may exceed the exercise fee

**Is the cost symmetric for calls vs puts?**
The base fee is symmetric (same formula for both token types). However, the `exerciseFees.sub(currentValue - oracleValue)` adjustment (RE:474-479) is asymmetric:

- If `currentTick` has moved in the direction favorable to the exercisor, `currentValue > oracleValue` and the fee adjustment is subtracted (exercisor pays less)
- If moved unfavorably, the adjustment adds cost
- This creates an incentive for the exercisor to time the exercise when the price has moved favorably for them

**Can the exercisor manipulate the oracle tick to influence the delta?**
The `oracleTick` used in `exerciseCost` is `twapTick` (PP:1804), which is the EMA blend. Manipulating this requires sustained multi-block MEV (same constraints as A.2). Not practical for single-block manipulation.

**However:** `currentTick` is the live Uniswap tick, which CAN be manipulated via flash loan. The `currentValue - oracleValue` delta at RE:477-478 uses `currentTick` for `currentValue`. An exercisor could:

1. Flash-loan to move `currentTick` in a direction that reduces `currentValue` relative to `oracleValue`
2. Execute force exercise (getting a favorable delta adjustment, reducing their cost or even getting paid)
3. Revert the flash loan

**Concrete example:** Position is a long put (token1 liquidity below current price, now out of range above). If exercisor moves `currentTick` DOWN (toward the position):

- `currentValue1` increases (more token1 in range)
- `oracleValue1` stays the same
- `currentValue1 - oracleValue1 > 0` → subtracted from exerciseFees → exercisor pays less

This effectively allows the exercisor to reduce or eliminate the exercise fee using flash loans, because the delta adjustment is based on `currentTick` (manipulable) vs `oracleTick` (resistant).

**Severity assessment:** The exercisor can reduce their out-of-pocket cost but cannot extract more than the delta between current and oracle values. Since the position is out-of-range, the delta is bounded by the position's notional value. The victim still loses their position.

---

## C) Cross-Collateral Liquidation Edge Cases

### C.1 Exchange Rate Manipulation

**Conversion rate:** All cross-collateral conversions use `atSqrtPriceX96 = Math.getSqrtRatioAtTick(twapTick)` (RE:1730, PP:1730).

The `twapTick` is the EMA blend `(6×fast + 3×slow + eons)/10` (RE:817). Manipulating this requires sustained multi-block MEV as analyzed in A.2.

**Can crossBufferRatio dropping to 0 cause false liquidation?**
When pool utilization > 95%, `crossBufferRatio = 0` (RE:2152-2153). This means:

- `scaledSurplusToken0 = 0` and `scaledSurplusToken1 = 0` (RE:1010-1019)
- Solvency check becomes: `bal0 >= maintReq0 AND bal1 >= maintReq1` (no cross-collateral help)
- An account that was solvent due to cross-collateral buffer becomes insolvent

**Is this a false liquidation?** No — it's by design. At >95% utilization, the protocol removes cross-collateral flexibility as a safety measure. However, an attacker could:

1. Push utilization above 95% by depositing and borrowing heavily
2. This removes cross-collateral buffer for all accounts
3. Accounts relying on cross-collateral become insolvent
4. Attacker liquidates them, collecting bonus

**Cost:** Pushing utilization to 95%+ requires massive capital. The interest rate model (adaptive IRM) makes this extremely expensive — rates spike near saturation.

**Verdict: Theoretically possible but economically impractical.** The IRM's exponential rate increase near saturation makes the capital cost prohibitive.

### C.2 Per-Token Bonus Rounding and Cross-Collateral Conversion

**Scenario:** `bonus0 > 0` but after cross-conversion, `bonus1 < 0`.

Looking at RE:539-556 (token0 deficit):

```
bonus1 += min(balance1 - paid1, convert0to1(paid0 - balance0))
bonus0 -= min(convert1to0RoundingUp(balance1 - paid1), paid0 - balance0)
```

The conversion uses `RoundingUp` for the subtracted amount (RE:553), ensuring the liquidatee pays at least the full converted value. This is protocol-favorable rounding.

**Can rounding cause combined bonus > available collateral?**

- `bonus0` decreases (converts to token1 at unfavorable rate for liquidatee)
- `bonus1` increases (receives token1)
- The `min()` caps ensure we don't convert more than available surplus
- Rounding up on the subtracted side means the total value extracted might be 1 wei more than the surplus in some cases

**Magnitude:** At most 1-2 wei per conversion, negligible.

**Verdict: No material rounding exploit.** The min() caps and rounding direction are correctly protocol-favorable.

### C.3 Extreme Price Scenarios

**At `MIN_POOL_TICK` (-887272) or `MAX_POOL_TICK` (887272):**

`sqrtPriceX96 = Math.getSqrtRatioAtTick(tick)`:

- At `MIN_POOL_TICK`: `sqrtPriceX96 ≈ 4295128739` (very small, token0 ≈ worthless relative to token1)
- At `MAX_POOL_TICK`: `sqrtPriceX96 ≈ 1461446703485210103287273052203988822378723970341` (very large, token1 ≈ worthless relative to token0)

**`convert0to1` at `MAX_POOL_TICK`:**

- `amount1 = amount0 × price²/2^192` → very large multiplier → could overflow for large `amount0`
- `PanopticMath.convert0to1` likely uses `mulDiv` with overflow protection

**`convert1to0` at `MIN_POOL_TICK`:**

- `amount0 = amount1 × 2^192/price²` → very large multiplier → could overflow for large `amount1`

**In the solvency check (RE:1021-1033):**

```solidity
if (sqrtPriceX96 < Constants.FP96) {  // FP96 = 2^96
    // token1 is "cheaper", use token0 as numeraire
    bal0 + convert1to0(scaledSurplus1) >= maintReq0
```

At extreme ticks, `convert1to0(scaledSurplus1)` could be astronomically large (if token1 is nearly worthless in token0 terms, a small surplus in token1 converts to near-zero token0). The `mulDiv` operations should handle this correctly through Solidity's overflow protection, but the converted values become meaningless.

**Practical concern:** Accounts with positions at extreme ticks may have solvency computations that are numerically unstable. However, Uniswap v4 pools at extreme ticks have essentially zero liquidity, so this is an academic concern.

**Verdict: No practical exploit.** The math handles extremes through mulDiv, and real pools don't operate at extreme ticks.

---

## D) Findings

### LIQ-001: Force Exercise Cost Too Low for OTM Positions

- **Severity:** Low
- **Category:** Griefing
- **Attack sequence:**
  1. Attacker identifies target account with out-of-range long positions (public on-chain data)
  2. Attacker reconstructs the target's `positionIdList` from emitted events
  3. Attacker calls `dispatchFrom()` with `positionIdListTo = [full list]`, `positionIdListToFinal = [full list minus target position]`
  4. Force exercise executes; attacker pays 1 bps of long notional as fee
- **Capital required:** 1 bps of target position's notional + gas (e.g., $10 for a $100K position)
- **Expected profit/loss:** Attacker loses the fee. This is a griefing attack, not profit-extracting.
- **Who is harmed:** The position holder. They lose their position (strategic value) and receive only 1 bps compensation. If the position was part of a spread, the remaining legs may have unintended risk exposure.
- **Existing mitigations:**
  - `MAX_TWAP_DELTA_DISPATCH` check prevents force exercise during volatile markets
  - Position must have long legs with width > 0
  - Account must be solvent at all 4 ticks
- **Mitigation effectiveness:** These prevent exploitation during extreme conditions but don't prevent cheap griefing during normal markets.
- **Repeatable:** Yes, can target many positions sequentially.

### LIQ-002: Force Exercise Delta Adjustment Manipulable via Flash Loan

- **Severity:** Low
- **Category:** MEV
- **Attack sequence:**
  1. Exercisor identifies an out-of-range long position to force-exercise
  2. In same tx, flash-loan to move `currentTick` toward the position's range
  3. This increases `currentValue` relative to `oracleValue` in `exerciseCost` (RE:457-465)
  4. The delta `currentValue - oracleValue` is subtracted from exercise fees (RE:474-479)
  5. Net exercise cost is reduced (possibly to near-zero or negative in extreme cases)
  6. Revert flash loan position
- **Capital required:** Flash loan fees only (~0.05% of loaned amount)
- **Expected profit/loss:** Saves the 1 bps exercise fee; for $1M notional, saves ~$100
- **Who is harmed:** The exercised position holder receives less compensation
- **Existing mitigations:**
  - The delta adjustment is bounded by the position's value difference between current and oracle ticks
  - The `currentValue - oracleValue` delta cannot exceed the position's full notional
- **Mitigation effectiveness:** The position holder still loses their position, which is the primary harm. The fee reduction is secondary.
- **Repeatable:** Yes.

### LIQ-003: Binary Force Exercise Cost (Comment/Code Mismatch)

- **Severity:** Informational
- **Category:** Code quality
- **Details:** Comments at RE:482-485 describe a right-shifting (exponential decay) mechanism for the exercise cost, but the implementation at RE:486 uses a binary choice: `hasLegsInRange ? -FORCE_EXERCISE_COST : -ONE_BPS`. There is no exponential decay based on distance from range. The prompt also describes "decaying exponentially for out-of-range" which does not match the code.
- **Impact:** The binary cost structure means positions that are 1 tick OTM pay the same 1 bps as positions that are 10,000 ticks OTM. Positions just barely out of range should arguably pay more than distant OTM positions.
- **Who is harmed:** Positions barely OTM are under-protected relative to deeply OTM positions.

### LIQ-004: Liquidation Cascade Amplification (Bounded)

- **Severity:** Low
- **Category:** Cascade
- **Attack sequence:**
  1. Attacker identifies the most-leveraged account in the pool
  2. Attacker liquidates it (if insolvent at all 4 ticks)
  3. Protocol loss from liquidation dilutes share price via `settleLiquidation` (CT:1349)
  4. Other marginally-solvent accounts may become insolvent
  5. Attacker liquidates the next most-leveraged account, repeating
- **Capital required:** Sufficient collateral to remain solvent after each liquidation (PP:1600)
- **Expected profit/loss:** Each liquidation yields at most `bal/2` bonus. Net P&L depends on bonus vs. dilution of attacker's own PLP position.
- **Who is harmed:** All PLPs through share dilution. Accounts that become insolvent through the cascade lose their positions and collateral.
- **Existing mitigations:**
  - `mintedShares` cap at `totalSupply * DECIMALS` (CT:1345)
  - Bonus cap at `bal/2` (RE:520-521)
  - Premium haircut recovers some loss (RE:599)
- **Mitigation effectiveness:** Strong. Per-liquidation dilution is bounded. In practice, cascades require multiple accounts to be within fractions of a percent of insolvency simultaneously.
- **Repeatable:** In theory, but each step reduces the pool of vulnerable accounts.

### LIQ-005: settleLiquidation Dilution Cap Too Generous

- **Severity:** Medium
- **Category:** Self-liquidation / price-manipulation
- **Details:** At CT:1345, the cap is `_totalSupply * DECIMALS` where `DECIMALS = 10_000`. This allows minting up to 10,000× the current total supply in a single liquidation event, enabling near-total (99.99%) share price dilution.
- **Attack scenario (extreme):**
  1. Pool has very low `totalAssets()` (e.g., most assets borrowed/deployed)
  2. Liquidation generates large bonus relative to `totalAssets()`
  3. At CT:1341: `Math.max(1, int256(totalAssets()) - bonus)` → denominator collapses to 1
  4. `rawMinted = bonus × (totalSupply - liquidateeBalance) / 1` → enormous
  5. Capped at `totalSupply * 10,000` → 10,000× dilution → 99.99% share price loss
- **Capital required:** Must create a scenario where `bonus ≥ totalAssets()`. Requires the liquidatee to dominate the pool (≈2× totalAssets in balance), which is only possible in small or early-stage pools.
- **Who is harmed:** All PLPs through catastrophic dilution. In the extreme case, share price drops to `totalAssets / (totalSupply × 10,001)`.
- **Existing mitigations:** The cap itself is the only mitigation. The `bal/2` bonus cap (RE:520) limits the size of the bonus, but when `totalAssets` is small the denominator still collapses.
- **Why 10,000× is excessive:** In all realistic liquidation scenarios (diversified PLP base), `rawMinted` is far below `_totalSupply × 1`. The cap only binds in the catastrophic case where `totalAssets ≈ bonus`, and at that point the pool is already failing. Reducing the cap limits attacker extraction in colluding liquidator/liquidatee scenarios without affecting legitimate liquidation mechanics.
- **Note:** Previously identified as ARITH-002 in prior audit. Confirming it persists and recommending a tighter cap.

### LIQ-006: Oracle TWAP is EMA Blend, Not Uniswap TWAP

- **Severity:** Informational
- **Category:** Documentation
- **Details:** `getTWAP()` (PP:2126) returns `twapEMA()` (RE:814) which is `(6×fastEMA + 3×slowEMA + eonsEMA)/10`. This is an internal EMA blend, not the Uniswap pool's TWAP accumulator. The naming may cause confusion in security reviews. The EMA blend is more manipulation-resistant than a raw TWAP for short time horizons but converges slower to true price after legitimate price changes.

### LIQ-007: Cross-Collateral Buffer Cliff at 95% Utilization

- **Severity:** Low
- **Category:** Self-liquidation
- **Attack sequence:**
  1. Attacker identifies accounts that are solvent only due to cross-collateral buffer
  2. Attacker pushes pool utilization above 95% by creating large positions
  3. `crossBufferRatio` drops to 0 (RE:2152-2153)
  4. Target accounts become insolvent without cross-collateral support
  5. Attacker liquidates them
- **Capital required:** Enormous — must push utilization from current level to 95%+
- **Expected profit/loss:** Gains bonus from liquidated accounts minus interest costs at >95% utilization (extremely high due to IRM)
- **Who is harmed:** Accounts relying on cross-collateral buffer
- **Existing mitigations:** Adaptive IRM makes maintaining >95% utilization extremely expensive. The linear decay from 90% to 95% (RE:2143-2157) provides gradual degradation rather than a cliff.
- **Mitigation effectiveness:** Strong. The IRM is the primary defense, making this economically irrational.
- **Repeatable:** Only while utilization remains >95%.

### LIQ-008: Loan-Inflated Liquidation Bonus Enables Profitable Self-Liquidation

- **Severity:** High
- **Category:** Self-liquidation
- **Details:** Loans (width=0, isLong=0) inflate the `bal` used in the liquidation bonus formula `bonus = min(bal/2, max(0, req-bal))` at RE:520-521. When a loan is created, shares are minted to the user (CT:1498-1500), increasing `assetsAndInterest(user)`. Unlike credits (width=0, isLong=1) which are offset by `creditAmounts` in `_getMargin` (RE:1158-1159), loans have no corresponding offset — the loan notional is embedded in the share balance with no `loanAmounts` subtraction.
- **Root cause:** Asymmetric accounting between credits and loans in `_getTotalRequiredCollateral` (RE:1308-1317). Credits are tracked via `creditAmounts` and added back to balance in `_getMargin`, making them neutral. Loans inflate balance through share minting with no corresponding offset, inflating the `bal/2` bonus cap.
- **Attack sequence:**
  1. Attacker deposits D in CT0
  2. Creates loan L ≈ 3D (width=0, isLong=0): shares minted, `bal₀ ≈ 4D`, `req₀ = 1.2L = 3.6D`
  3. Creates far-OTM short put with initial req ≈ 0.4D (10% of notional 4D), exhausting solvency slack
  4. Price crashes → short goes deep ITM: put req grows to ~4D (100% of notional, from `r1 ≈ amountMoved` at RE:1466-1469)
  5. Total `req₀ = 3.6D + 4D = 7.6D`, `bal₀ = 4D`
  6. Accomplice (Account B) calls `dispatchFrom()` to liquidate Account A
  7. `bonus₀ = min(4D/2, 7.6D - 4D) = min(2D, 3.6D) = 2D`
  8. **Attacker profit: 2D - D = +D (100% return on deposit)**
- **Capital required:** D (deposit) + gas. Loan requires no additional capital (shares minted virtually). Total real capital = D.
- **Expected profit:** Up to D (100% of deposit) at optimal loan ratio L ≈ 3D.
- **Who is harmed:** PLPs absorb the protocol loss. The excess bonus (2D - D/2 = 1.5D beyond what a non-loan account would receive) comes from PLP share dilution via `settleLiquidation`.
- **Existing mitigations:** None. The `bal/2` cap at RE:520 is the only bonus limiter, and loans inflate `bal` unchecked.
- **Key constraint:** The attacker needs the short's collateral requirement to grow significantly from OTM to deep ITM. The Reg-T formula (RE:1457-1488) provides 10× growth: from `r0 ≈ 10% of notional` (far OTM) to `r1 ≈ 100% of notional` (deep ITM). The optimal loan size balances solvency slack (for a larger short notional) against bal inflation (for a larger bonus cap).
- **Profit by loan size (D=1000, short at 10% initial / 100% ITM ratio):**

  | Loan L | Solvency slack | Max short notional | ITM req | Total req | Bonus                  | P&L     |
  | ------ | -------------- | ------------------ | ------- | --------- | ---------------------- | ------- |
  | 4D     | 0.2D           | 2D                 | 2D      | 6.8D      | min(2.5D, 1.8D) = 1.8D | +0.8D   |
  | 3D     | 0.4D           | 4D                 | 4D      | 7.6D      | min(2D, 3.6D) = 2D     | **+1D** |
  | 2D     | 0.6D           | 6D                 | 6D      | 8.4D      | min(1.5D, 5.4D) = 1.5D | +0.5D   |
  | 0      | D              | 10D                | 10D     | 10D       | min(0.5D, 9D) = 0.5D   | -0.5D   |

- **Repeatable:** Yes. Attacker can repeat with fresh accounts.
- **Cross-token variant:** The same-token attack (loan and short in the same token) is the primary threat. A cross-token variant (loan in token0, swap to token1 via ITM position, short in token1) is **naturally hedged**: for the token1 short to go ITM, the token1 price must drop, but the bonus is denominated in token1 — so the bonus depreciates as the insolvency deepens. At best break-even (around a 33% price drop), net negative after frictions. See LIQ-009 for details.

### LIQ-009: Cross-Token Loan Migration Not Caught by Per-Token Clamp (Naturally Hedged)

- **Severity:** Informational
- **Category:** Self-liquidation
- **Details:** The per-token loan clamp (LIQ-008 fix) tracks `loanAmounts` per token. If a user takes a loan in token0 and swaps to token1 via an ITM position (with `tickLimitLow > tickLimitHigh` at creation), the loan-derived value migrates to token1. The clamp correctly zeros `bonus₀` (loanAmounts₀ > bal₀ after swap), but `bonus₁` is unclamped (`loanAmounts₁ = 0`). Critically, no ITM swap occurs during liquidation burns (PP:1718-1719 uses `MIN_SWAP_TICK`/`MAX_SWAP_TICK` → `invertedLimits = false` → SFPM:882-887 skips swap), so the swap from creation is NOT reversed.
- **Why this is not exploitable:** The bonus₁ is denominated in token1, which must depreciate for the token1 short to go ITM. This creates a natural hedge:

  | ETH price (from 2000) | Put status    | bonus₁ (ETH)    | bonus₁ (USDC) | P&L (D=1000)       |
  | --------------------- | ------------- | --------------- | ------------- | ------------------ |
  | 2000                  | OTM           | can't liquidate | —             | —                  |
  | 1500                  | Marginal ITM  | ≤0.5 ETH        | ≤750          | ≤-250              |
  | 1333                  | ITM           | 0.75 ETH        | 1000          | **0** (break-even) |
  | 1000                  | Deep ITM      | 0.75 ETH        | 750           | -250               |
  | 500                   | Very deep ITM | 0.75 ETH        | 375           | -625               |

  The deeper the insolvency, the less the bonus is worth. For the opposite direction (short call goes ITM when token1 rises), the call's `tokenType=0` creates insolvency in token0, where the per-token clamp catches it.

- **A cross-token converted clamp** (adding `convert0to1(loanAmounts₀)` to the token1 clamp) was considered but rejected: it would use `atSqrtPriceX96` (the depressed twap price), over-converting at the very price that makes the attack unprofitable, and would over-correct for legitimate users with real deposits in both tokens.
- **Recommendation:** No additional code change. The per-token clamp (LIQ-008 fix) handles the primary same-token attack. The cross-token variant is naturally hedged by price dynamics to break-even at best, net negative after commissions, interest, and gas.

---

## E) Economic Bounds

### LIQ-001 Break-Even Analysis (Force Exercise Griefing)

| Parameter                      | Value                           | Impact            |
| ------------------------------ | ------------------------------- | ----------------- |
| Position notional              | $100K                           | Cost = $10 + gas  |
| Position notional              | $1M                             | Cost = $100 + gas |
| Gas (L1, ~500K gas, 30 gwei)   | ~$15                            | Floor cost        |
| Gas (L2, ~500K gas, 0.01 gwei) | ~$0.005                         | Negligible        |
| Break-even for attacker        | N/A (griefing, always net loss) | —                 |

**Parameter sensitivity:**

- If `ONE_BPS` were halved to 500: griefing cost halved, still viable
- If `ONE_BPS` were increased to `FORCE_EXERCISE_COST/2` ≈ 51,200: cost = 0.5% of notional, significantly increases griefing cost ($500 per $100K position)
- **Key parameter:** `ONE_BPS` at RE:486 is the critical constant. Current value makes far-OTM force exercise extremely cheap.

### LIQ-002 Break-Even (Flash Loan Delta Manipulation)

- Flash loan cost: ~0.05% of borrowed amount (e.g., Aave)
- Saving: up to 1 bps of exercised position notional
- Break-even: flash loan amount where 0.05% × loan < 0.01% × position_notional
- For $1M position: saves $100. Need flash loan cost < $100. At 0.05%: can borrow up to $200K profitably.
- **Result:** Profitable for medium-large positions on deep-liquidity pools where small flash loans can move the price meaningfully.

### LIQ-004 Break-Even (Cascade)

- Per-liquidation: bonus ≤ bal/2, protocol loss ≤ full shortfall
- Dilution per event: ≤ `protocol_loss / totalAssets`
- To cause 1% cascade dilution: need `protocol_loss = 0.01 × totalAssets`
- For $10M pool: need $100K protocol loss → requires $200K+ collateral in the liquidated account
- Attacker's own dilution: proportional to their PLP share
- If attacker holds 10% of PLP: loses 0.1% from dilution, gains bonus ≤ $100K
- **Profit potential is positive only if attacker's PLP exposure is small relative to bonus received**

### LIQ-005 Break-Even (settleLiquidation Dilution Cap)

- Requires `bonus > totalAssets()`. Since `bonus ≤ bal/2` and `bal < totalAssets()` normally, this requires most assets to be deployed (high utilization) AND a large liquidation relative to remaining pool.
- Practically requires: >99% utilization + liquidation of a major position holder
- IRM makes this untenable: interest rates approach infinity near 100% utilization.
- **With reduced cap (100× instead of 10,000×):** Worst-case dilution drops from 99.99% to 99%. In the catastrophic scenario, PLPs retain ~1% instead of ~0.01%. More importantly, attacker extraction from a colluding liquidator/liquidatee pair is reduced by 100×.

### LIQ-008 Break-Even (Loan-Inflated Bonus)

- **Minimum deposit for attack:** Any D > 0 (but gas + commission must be covered)
- **Optimal loan ratio:** L ≈ 3D maximizes profit at +D (100% return)
- **Required price movement:** The far-OTM short must go deep ITM. For a short put at strike K with price starting at 2K (50% OTM): price must fall to ≈ 0 for maximum `r1 ≈ amountMoved`. Partial ITM still profitable if req growth exceeds the `req-bal > D` threshold.
- **Time requirement:** The attack requires real price movement or multi-block MEV to make the short deeply ITM. The loan + short can be created in a single block. Liquidation occurs in a later block after the price moves.
- **Gas costs:** ~$20-50 on L1 for the creation + liquidation transactions. Negligible on L2s.
- **Commission friction:** Commission on the short option ≈ 10-50 bps of notional. For notional = 4D and fee = 20 bps: commission = 0.008D. Negligible relative to D profit.
- **Interest friction:** Loan accrues interest. At moderate utilization (~70%), interest rates are manageable. Attack executed within minutes to hours has negligible interest cost. Longer time horizons (waiting for natural price movement) have meaningful but sub-D interest costs.
- **Comparison to no-loan baseline:** Without the loan, the same deposit D yields bonus = D/2 and P&L = -D/2 (loss). The loan converts a -D/2 loss into a +D profit — a 3D swing.

### LIQ-007 Break-Even (Cross-Buffer Manipulation)

- Cost: interest on capital needed to push utilization from X% to 95%
- For a $10M pool at 80% utilization: need to create $1.5M in additional positions
- Interest at 90%+ utilization: exponentially increasing, likely >100% APR
- Per-minute cost at 95%+ utilization: potentially $100s+ for a $10M pool
- Must maintain for several minutes for oracle to reflect the changed collateral
- **Result:** Cost massively exceeds potential bonus from liquidating buffer-dependent accounts

---

## F) Recommendations

### F.1 For LIQ-001 (Force Exercise Griefing)

**1. Parameter adjustment (recommended):**
Increase `ONE_BPS` from 1,000 to a value that scales with distance from range. Even without exponential decay, a higher floor (e.g., 10,000 = 10 bps) would 10× the griefing cost.

**2. Minimal code change (alternative):**
Implement the distance-based decay that the comments at RE:482-485 describe. For each long leg, compute the number of half-ranges away from the current tick, and right-shift the base fee accordingly:

```solidity
// Pseudocode — at RE:486
int256 fee = -int256(FORCE_EXERCISE_COST);
if (!hasLegsInRange) {
    int256 shifts = distanceFromRange / halfRangeWidth;
    fee = fee >> Math.min(shifts, 10); // Decay to floor of -1 bps
}
```

This preserves the 1.024% cost for in-range, but makes barely-OTM positions cost more than deeply-OTM ones.

**3. Monitoring:**
Track force exercise events. Alert on patterns of systematic force-exercise targeting (same `msg.sender` exercising many different accounts in short succession).

### F.2 For LIQ-002 (Flash Loan Delta Manipulation)

**1. Minimal code change:**
Use `twapTick` (oracleTick) instead of `currentTick` for computing `currentValue` in `exerciseCost` (RE:457-459). This eliminates the flash-loan-manipulable component:

```solidity
// At RE:457-459, replace:
(currentValue0, currentValue1) = Math.getAmountsForLiquidity(currentTick, liquidityChunk);
// With:
(currentValue0, currentValue1) = Math.getAmountsForLiquidity(oracleTick, liquidityChunk);
```

Since both sides would use `oracleTick`, the delta becomes zero, and the fee becomes purely the base rate. However, this removes the intentional design of compensating the exercisee for unfavorable price impact.

**Alternative:** Use a TWAP-averaged position value rather than point-in-time values, or apply a minimum floor to the exercise fee that cannot be reduced by the delta adjustment.

### F.3 For LIQ-003 (Comment/Code Mismatch)

**1. Documentation:**
Update comments at RE:482-485 to reflect the current binary implementation, or implement the described exponential decay. Misleading comments create security review blind spots.

### F.4 For LIQ-004 (Cascade Amplification)

No code change recommended. Existing mitigations (minted shares cap, bonus cap, haircut) are adequate. The theoretical cascade requires implausibly correlated account solvency.

**Monitoring suggestion:** Track the count and aggregate protocol loss of liquidations within rolling time windows. Alert if cumulative protocol loss exceeds a threshold (e.g., 1% of totalAssets within 1 hour).

### F.5 For LIQ-005 (settleLiquidation Dilution Cap)

**Recommended code change at CT:1345:**
Reduce the cap multiplier from `DECIMALS` (10,000) to 100:

```solidity
// Before (CT:1345):
mintedShares = rawMinted > liquidateeBalance
    ? Math.min(rawMinted - liquidateeBalance, _totalSupply * DECIMALS)
    : 0;

// After:
uint256 MAX_DILUTION_FACTOR = 100;
mintedShares = rawMinted > liquidateeBalance
    ? Math.min(rawMinted - liquidateeBalance, _totalSupply * MAX_DILUTION_FACTOR)
    : 0;
```

**Rationale:**

- In all realistic liquidation scenarios (diversified PLP base), `rawMinted` is far below `_totalSupply × 1`, so 100× headroom is extremely generous for legitimate use.
- Worst-case dilution drops from 99.99% to 99% — both are catastrophic for PLPs, but the tighter cap limits attacker extraction from colluding liquidator/liquidatee pairs by 100×.
- The scenario where this cap binds (`totalAssets ≈ bonus`) already represents pool failure; limiting the minting prevents the failure from being maximally exploited.

**Alternative:** Define the constant explicitly rather than reusing `DECIMALS`, to make the cap's purpose clear and avoid confusion with the unrelated fee-scaling `DECIMALS`.

### F.7 For LIQ-008 (Loan-Inflated Bonus)

**Implemented fix: Two-part defense — reduced bonus cap (`MAX_BONUS`) + per-token loan clamp.**

#### Part A — Reduced Bonus Cap: `MAX_BONUS = 2_000_000` (20%)

The original `bal/2` (50%) cap was replaced with a configurable `MAX_BONUS` constant:

```solidity
/// @notice Max possible bonus during liquidations (currently 20% of balance)
/// @dev bonus formula is min(MAX_BONUS * balance / DECIMALS, required - balance)
uint256 public constant MAX_BONUS = 2_000_000;  // 20% of DECIMALS (10_000_000)
```

**Rationale:** The original 50% cap was far above DeFi norms:

| Protocol           | Liquidation Bonus |
| ------------------ | ----------------- |
| Aave v2/v3         | 5-15%             |
| Compound v2        | 8%                |
| MakerDAO           | ~13%              |
| Euler              | 0-20% (dynamic)   |
| Morpho             | 3-8%              |
| **Panoptic (old)** | **up to 50%**     |
| **Panoptic (new)** | **up to 20%**     |

20% matches Euler's ceiling and provides ample incentive for automated liquidation bots while reducing protocol loss by 60% on large deep-insolvency liquidations. For marginal insolvency (the common case), `req - bal` is the binding constraint regardless of the cap.

**Defense-in-depth against loan attacks:** Even without the loan clamp, `MAX_BONUS = 20%` raises the loan profitability threshold. With the old 50% cap, loans > D were profitable. With the 20% cap:

- Profit requires `L > D × (DECIMALS/MAX_BONUS - 1) = D × 4`, i.e., L > 4D
- At 83% LTV (max L ≈ 5D): barely achievable, marginal profit
- Combined with the loan clamp: impenetrable

#### Part B — Per-Token Loan Clamp

**New helper `PanopticMath.getTotalLoanAmounts`** computes total loan notional per token:

```solidity
function getTotalLoanAmounts(
  PositionBalance[] memory positionBalanceArray,
  TokenId[] memory positionIdList
) internal pure returns (LeftRightUnsigned loanAmounts) {
  unchecked {
    for (uint256 i; i != positionBalanceArray.length; ++i) {
      TokenId tokenId = positionIdList[i];
      uint128 positionSize = positionBalanceArray[i].positionSize();
      for (uint256 index = 0; index != tokenId.countLegs(); ++index) {
        if (tokenId.width(index) == 0 && tokenId.isLong(index) == 0) {
          loanAmounts = loanAmounts.add(
            PanopticMath.getAmountsMoved(tokenId, positionSize, index, false)
          );
        }
      }
    }
  }
}
```

**In `PanopticPool._liquidate`**, `loanAmounts` is computed and passed to `getLiquidationBonus` as a new parameter.

**In `getLiquidationBonus`**, the bonus is computed then clamped:

```solidity
// Initial bonus with MAX_BONUS cap:
bonus0 = Math.min((bal0 * MAX_BONUS) / DECIMALS, req0 > bal0 ? req0 - bal0 : 0).toInt256();
bonus1 = Math.min((bal1 * MAX_BONUS) / DECIMALS, req1 > bal1 ? req1 - bal1 : 0).toInt256();

// Loan-adjusted clamp (uses MAX_BONUS consistently):
uint256 loan0 = loanAmounts.rightSlot();
uint256 loan1 = loanAmounts.leftSlot();
if (bonus0 > 0 && (DECIMALS * uint256(bonus0)) / MAX_BONUS + loan0 > bal0) {
    bonus0 = bal0 >= loan0 ? int256(((bal0 - loan0) * MAX_BONUS) / DECIMALS) : int256(0);
}
if (bonus1 > 0 && (DECIMALS * uint256(bonus1)) / MAX_BONUS + loan1 > bal1) {
    bonus1 = bal1 >= loan1 ? int256(((bal1 - loan1) * MAX_BONUS) / DECIMALS) : int256(0);
}
```

The clamp check `(DECIMALS * bonus) / MAX_BONUS + loans > bal` is equivalent to `bonus > (bal - loans) * MAX_BONUS / DECIMALS`, ensuring the bonus never exceeds 20% of the real (non-loan) deposit. The fallback uses the same `MAX_BONUS` parameter for consistency.

**Why clamp BEFORE cross-conversion (not after):**
The cross-conversion at RE:537-574 computes `paid = bonus + netPaid` and decides whether to convert surplus from one token to cover deficit in the other. If bonus is still loan-inflated when cross-conversion runs:

- `paid` is inflated → triggers incorrect conversion decisions
- Cross-conversion adjusts `bonus1` based on inflated `bonus0`
- Clamping `bonus0` after would leave `bonus1` inconsistent

Clamping first ensures cross-conversion operates on correct bonus values. The `balance` at RE:526 retains the loan amount intentionally — it cancels with the loan repayment in `netPaid` for correct protocol loss accounting. The cross-conversion surplus calculation also naturally cancels loans: `surplus₀ = balance₀ - paid₀ = (bal₀) - (bonus₀ + netPaid₀)` where loan L₀ in `bal₀` cancels with loan repayment +L₀ in `netPaid₀`.

**Why per-token clamp only (no cross-token conversion):**
A cross-token converted clamp (adding `convert0to1(loanAmounts₀)` to the token1 clamp) was considered but rejected. The cross-token attack (loan in token0, swap to token1 via ITM position, short in token1) is naturally hedged: the token1 price must drop for the short to go ITM, but the bonus is in token1 — so the bonus depreciates as insolvency deepens. Break-even at best (see LIQ-009). No ITM swap occurs during liquidation burns (SFPM uses `MIN_SWAP_TICK`/`MAX_SWAP_TICK` → `invertedLimits = false`), so the creation-time swap is not reversed, but the natural hedge limits exploitation.

**Design properties:**

- Guard check `(DECIMALS * bonus) / MAX_BONUS + loans > bal` uses only unsigned additions — no underflow risk.
- Fallback `((bal - loans) * MAX_BONUS) / DECIMALS` is guarded by `bal >= loans`.
- When `bal < loans` (interest consumed entire deposit): bonus = 0.
- Does NOT modify `balance` for protocol loss (RE:526): loan in `bal` cancels with loan repayment in `netPaid`.
- Does NOT affect solvency checks: `isAccountSolvent` (RE:977) uses full `bal`.
- No-loan accounts unaffected: clamp condition with loanAmounts=0 reduces to `bonus > bal * MAX_BONUS / DECIMALS`, which is never true since bonus was computed as `min(bal * MAX_BONUS / DECIMALS, ...)`.

**Verification against attack scenarios (with MAX_BONUS = 20%):**

| Scenario                                    | Old bonus (50% cap) | New bonus (20% cap + clamp)       | P&L      |
| ------------------------------------------- | ------------------- | --------------------------------- | -------- |
| D=1000, L=3000, same token                  | 2000                | 200                               | **-800** |
| D=1000, L=4000, same token                  | 1800                | 200                               | **-800** |
| D=1000, L=3000, cross-token (natural hedge) | 0.75 ETH            | 0.75 ETH (clamp inactive, hedged) | ≤0       |
| D=1000, L=0 (no loan)                       | 500                 | 200                               | -800     |

### F.6 For LIQ-007 (Cross-Buffer Cliff)

No code change recommended. The IRM's exponential rate increase near saturation provides adequate economic defense. The linear decay from 90% to 95% is appropriately gradual.

**Monitoring suggestion:** Alert when pool utilization exceeds 90% to flag potential manipulation attempts.

---

## Appendix: Oracle Tick Computation Path During Liquidation

```
dispatchFrom() [PP:1491]
├── twapTick = getTWAP() → twapEMA() [RE:814]
│   └── (6 × fastEMA + 3 × slowEMA + eonsEMA) / 10
├── currentTick = getCurrentTick() [PP:2131]
│   └── SFPM.getCurrentTick() → Uniswap pool slot0.tick
├── (spotTick, _, latestTick) = _getOracleTicks(currentTick) [PP:1512]
│   └── oraclePack.getOracleTicks(currentTick, EMA_PERIODS, MAX_CLAMP_DELTA) [OraclePack:534]
│       ├── If new 64s epoch: insert clamped observation (±149 ticks max from last)
│       ├── Update EMAs (cascading timeDelta cap at 75% of period)
│       ├── spotTick = spotEMA (60s period)
│       └── latestTick = last clamped observation
├── atTicks = [spotTick, twapTick, latestTick, currentTick] [PP:1515-1519]
├── solvent = _checkSolvencyAtTicks(account, atTicks) [PP:1521]
│   └── For each tick: isAccountSolvent() [RE:977]
│       ├── _getMargin() → tokensRequired, balance
│       ├── crossBufferRatio(utilization) → scaled surplus
│       └── Cross-asset solvency: bal + convert(surplus) >= maintReq
└── If solvent == 0 → _liquidate() [PP:1592]
    ├── Bonus at twapTick [PP:1730]: getLiquidationBonus()
    ├── Haircut: haircutPremia() [PP:1748]
    └── Settlement: settleLiquidation() [CT:1246]
```

**Oracle manipulation resistance summary:**

- `currentTick`: Freely manipulable via flash loan (1 of 4 ticks)
- `latestTick`: Clamped to ±149 ticks from prior observation, updated once per 64s epoch
- `spotTick (spotEMA)`: 60s EMA, moves ≤112 ticks per observation
- `twapTick (EMA blend)`: Moves ≤45 ticks per observation, requires multi-minute sustained manipulation
- **All 4 must show insolvency** → flash loans alone cannot trigger liquidation
