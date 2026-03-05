# Liquidation & Force Exercise Game Theory Audit

     **Auditor**: Claude Opus 4.6 (1M context)
     **Date**: 2026-03-05
     **Scope**: `contracts/` (recursive)

     ---

     ## Key Constants Reference

     | Constant | Value | Meaning |
     |----------|-------|---------|
     | `DECIMALS` (RiskEngine) | 10,000,000 | 0.0001% precision |
     | `NOTIONAL_FEE` | 1 | 0.01% of notional |
     | `PREMIUM_FEE` | 100 | 1% of premium |
     | `SELLER_COLLATERAL_RATIO` | 2,000,000 | 20% at base utilization |
     | `BUYER_COLLATERAL_RATIO` | 1,000,000 | 10% |
     | `MAX_BONUS` | 2,000,000 | 20% of balance cap |
     | `FORCE_EXERCISE_COST` | 102,400 | 1.024% of long notional |
     | `ONE_BPS` | 1,000 | 0.01% of notional |
     | `MAX_TICKS_DELTA` | 953 | ~10% price movement |
     | `MAX_TWAP_DELTA_DISPATCH` | 513 | ~5% TWAP/spot delta |
     | `MAX_CLAMP_DELTA` | 149 | ~1.5% per oracle update |
     | `EMA_PERIODS` | 60/120/240/960s | spot/fast/slow/eons |
     | Oracle epoch | 64 seconds | min time between observations |
     | `BP_DECREASE_BUFFER` | 10,416,667 | ~104.17% buffer on buying power decreases |

     ---

     ## A) Liquidation Attack Surface Map

     ### A.1 Self-Liquidation via Operator

     **Attack sequence:**
     1. Attacker controls Account A (liquidatee) and Account B (liquidator)
     2. A deposits collateral D into CollateralTracker, opens short position with notional N
     3. A grants operator approval to B
     4. Price moves, making A insolvent
     5. B calls `dispatchFrom` (PP:1491) to liquidate A with `positionIdListToFinal = []`
     6. B receives liquidation bonus

     **Feasibility analysis:**

     The bonus formula (RE:530-535):
     ```
     bonus = min(bal * MAX_BONUS / DECIMALS, req - bal)
          = min(bal * 0.2, shortfall)
     ```

     During `settleLiquidation` (CT:1246), account A's **entire** remaining balance is consumed:
     - Virtual shares (`type(uint248).max`) are revoked (CT:1238)
     - Any shortfall between the revoked amount and A's actual balance becomes protocol loss
     - A retains zero value

     **Combined profit/loss for the attacker (A+B):**
     - Capital deployed: D (deposited by A)
     - Commission paid on creation: `N * NOTIONAL_FEE / DECIMALS = N * 0.00001` (CT:1562-1565)
     - After liquidation: A has 0, B has bonus
     - Bonus ≤ `0.2 * bal` where `bal ≤ D` (balance cannot exceed deposit for insolvent accounts)

     **Net result: `bonus - D - commission ≤ 0.2D - D - commission = -0.8D - commission`**

     The attacker **always** loses at least 80% of their deposit plus commission. Self-liquidation is fundamentally unprofitable because the bonus (max 20%) is strictly less than the collateral consumed (100%).

     **Loan clamping** (RE:540-549) further restricts the bonus:
     ```solidity
     if (bonus0 > 0 && (DECIMALS * uint256(bonus0)) / MAX_BONUS + loan0 > bal0) {
         bonus0 = bal0 >= loan0 ? int256((MAX_BONUS * (bal0 - loan0)) / DECIMALS) : 0;
     }
     ```
     This ensures `bonus/0.2 + loanAmounts ≤ bal`, preventing loan-inflated balances from inflating the bonus.

     **Minimum capital**: Any amount (but losses scale linearly)
     **Maximum extractable profit**: **Negative**. Always a loss of ≥ 80% of deposit.
     **Verdict**: NOT VIABLE. No position construction changes this — the 20% cap on bonus is an absolute ceiling.

     ---

     ### A.2 Liquidation Price Manipulation

     **Oracle tick computation path during liquidation (`dispatchFrom`, PP:1499-1529):**

     ```
     twapTick = getTWAP()                          // (6*fastEMA + 3*slowEMA + eonsEMA)/10
     currentTick = getCurrentTick()                 // live Uniswap pool.slot0
     (spotTick, _, latestTick) = _getOracleTicks()  // spotEMA, _, lastTick from s_oraclePack

     atTicks = [spotTick, twapTick, latestTick, currentTick]  // ALL FOUR checked
     ```

     **To liquidate, account must be insolvent at ALL FOUR ticks** (PP:1521-1529, `solvent == 0` required at PP:1584).

     **Single-block manipulation (flash loan):**

     | Tick | Movement possible in 1 block |
     |------|------------------------------|
     | `currentTick` | Fully manipulable (live spot) |
     | `spotTick` (spotEMA, 60s) | Max 149 ticks per epoch (64s min between updates) |
     | `latestTick` | Unchanged (stored from last interaction) |
     | `twapTick` | Barely moves (weighted blend of slow EMAs) |

     Even if the attacker moves `currentTick` by 10,000 ticks, the account must ALSO be insolvent at `twapTick` and `latestTick`, which haven't moved. **Single-block oracle manipulation cannot trigger a false liquidation.**

     **Multi-block manipulation (proposer MEV):**

     The oracle epoch is 64 seconds. Per epoch, a new observation is clamped by `MAX_CLAMP_DELTA = 149` ticks (RE:95, OraclePack:509). EMA movements per epoch:

     | EMA | Period | Max tick movement per epoch | Ticks after 3 epochs (192s) |
     |-----|--------|----------------------------|------------------------------|
     | spot | 60s | ~149 | ~447 |
     | fast | 120s | ~80 | ~240 |
     | slow | 240s | ~40 | ~120 |
     | eons | 960s | ~10 | ~30 |

     After 3 epochs: `twapTick ≈ (6*240 + 3*120 + 30)/10 = 183 ticks` (~1.8% price movement).

     Making someone insolvent with a 1.8% twapTick shift requires them to already be within 1.8% of the margin boundary — i.e., already legitimately close to insolvency.

     **Cost of sustained manipulation**: Moving the Uniswap spot price by ~10% for 3+ minutes (192 seconds) requires maintaining a massive position against arbitrageurs. For a $10M pool, moving price 10% costs ~$1M+ in temporary impermanent loss, plus arbitrageur extraction. The attack would need to extract more than this from the liquidation bonus, which is capped at 20% of the liquidatee's balance.

     **Verdict**: NOT VIABLE on single block. THEORETICALLY POSSIBLE over 3+ minutes on a low-liquidity pool where the target account is already near margin, but economically irrational due to manipulation costs vastly exceeding the capped bonus.

     ---

     ### A.3 Liquidation Sandwiching

     **Attack sequence:**
     1. Attacker sees pending liquidation tx in mempool
     2. Front-run: move Uniswap spot price to increase insolvency
     3. Liquidation executes (or attacker submits their own)
     4. Back-run: reverse price

     **Bonus sensitivity to price manipulation:**

     The bonus is computed using `twapTick` (PP:1735: `Math.getSqrtRatioAtTick(twapTick)`), NOT the current spot tick. Since twapTick is a blended EMA (60/30/10 weighting), it is unaffected by single-block price movements.

     However, `netPaid` (the cost of closing all positions, PP:1715) depends on actual AMM execution at the current tick. Moving the price could:
     - Increase ITM value of shorts → higher netPaid → more protocol loss → lower remaining for bonus
     - **This actually hurts the liquidator**, not helps them

     **What the sandwich CAN extract:**

     The genuine MEV opportunity is standard AMM sandwich profit from the position closing trades. When `_burnAllOptionsFrom` burns positions through the AMM, it creates large swaps. The sandwich profit comes from front-running these swaps, not from manipulating the liquidation bonus.

     **Constraints:**
     - `MIN_SWAP_TICK`/`MAX_SWAP_TICK` tick limits on liquidation burns (PP:1717-1718) mean no slippage protection — burns execute at any price. This makes the AMM swaps during liquidation vulnerable to standard sandwiching.
     - Solvency at 4 ticks still required (protects against triggering false liquidations)
     - The oracle resists same-block manipulation for the bonus computation itself

     **Verdict**: Bonus manipulation via sandwich is NOT VIABLE (twapTick-based). Standard AMM sandwich of position-closing trades IS viable and is standard MEV, not protocol-specific. The unlimited tick limits on liquidation burns increase exposure to standard sandwich MEV.

     ---

     ### A.4 Cascade Liquidation Amplification

     **Mechanism:**
     1. Liquidation of Account A causes protocol loss
     2. `settleLiquidation` (CT:1336-1350) mints `mintedShares` shares to the liquidator
     3. Share supply increases → share price drops → all depositors' collateral value decreases
     4. Other marginal accounts become insolvent
     5. Repeat

     **Share minting formula** (CT:1338-1346):
     ```solidity
     rawMinted = bonus * (totalSupply - liquidateeBalance) / max(1, totalAssets - bonus)
     mintedShares = min(max(rawMinted - liquidateeBalance, 0), totalSupply * DECIMALS)
     ```

     **Cap**: `mintedShares ≤ totalSupply * DECIMALS = totalSupply * 10,000`

     This means a single liquidation can dilute the vault by at most 10,000x the current supply. In practice:
     - `rawMinted ≈ bonus * totalSupply / (totalAssets - bonus)`
     - For `bonus ≈ 0.2 * bal` and `totalAssets >> bonus`: `rawMinted ≈ 0.2 * bal * totalSupply / totalAssets`
     - Share price impact: `newPrice = totalAssets / (totalSupply + mintedShares) ≈ totalAssets / (totalSupply * (1 + 0.2 * bal / totalAssets))`
     - For a single account with `bal = 1%` of totalAssets: share price drops ~0.2%

     **Cascade depth analysis:**

     Each cascade step has diminishing returns:
     - Step 1: Share price drops by `Δ1 = bonus1 / totalAssets`
     - Step 2: Next account's balance decreases by `Δ1 * balance2`, which must exceed its remaining margin buffer
     - The buffer is `balance - requirement`, typically 2-10% of balance
     - Each step can only trigger the NEXT most marginal account

     **Natural damping mechanisms:**
     1. Each subsequent account has more buffer (less marginal)
     2. The 20% bonus cap ensures each liquidation consumes only a fraction of the loss
     3. `totalSupply * DECIMALS` cap prevents catastrophic single-liquidation dilution
     4. Interest rates spike at high utilization, discouraging over-leverage
     5. Safe Mode triggers at high EMA divergence (RE:914-946), imposing 100% collateral requirements

     **Concrete example:**
     - Vault: $10M totalAssets, 10M shares (1:1 price)
     - Account A: $500K balance, $520K requirement (barely insolvent), bonus = $100K
     - Protocol loss: ~$420K (shortfall beyond bonus)
     - Minted shares: ~420K (dilution ~4.2%)
     - New share price: ~$0.96
     - For cascade: next account needs `(balance - requirement) / balance < 4.2%` — only accounts within 4.2% of margin boundary are affected
     - Second liquidation: similar dynamics but bonus is now on a smaller balance

     **Attacker strategy**: Create many accounts all near the margin boundary, trigger the first one, cascade follows.
     - Cost: funding all accounts (each needs ≥20% collateral)
     - For 5 accounts × $500K = $2.5M capital deployed
     - Maximum bonus extraction: 5 × $100K = $500K
     - Net loss: $2.5M - $500K = $2M (still massively unprofitable)

     **Verdict**: Cascades are theoretically possible but the attacker bears the losses. The natural damping from the 20% bonus cap, safe mode triggers, and interest rate spikes make cascades self-limiting. The cap at `totalSupply * DECIMALS` prevents single-liquidation vault destruction.

     ---

     ### A.5 Premium Haircut Timing Attack

     **Mechanism:**

     During liquidation, `_burnAllOptionsFrom` uses `DONOT_COMMIT_LONG_SETTLED` (PP:1719), meaning the long premium is NOT committed to `s_settledTokens` until after `haircutPremia` is computed (InteractionHelper:150-154). This prevents the liquidatee's premium from being front-run.

     **However**: Third-party short sellers with positions in the same chunk as the liquidatee's long legs CAN front-run:

     1. Short seller S has accumulated premium in chunk C from liquidatee L's long position
     2. S sees L's liquidation tx in the mempool
     3. S front-runs by burning their short position (or calling `settlePremium` on L's long)
     4. S collects their share of `s_settledTokens[chunkC]`
     5. L's liquidation executes, `haircutPremia` reduces `s_settledTokens[chunkC]`
     6. The haircut is borne disproportionately by other short sellers who didn't withdraw

     **Trace:**
     - `haircutPremia` (RE:627-806) computes `haircutBase` from `collateralRemaining` (the protocol loss)
     - `InteractionHelper.settleAmounts` (InteractionHelper:150-154) writes: `settledTokens[chunkKey] += (negated_premium - haircut)`
     - The haircut reduces what's ADDED to the accumulator going forward
     - Premium already withdrawn by S is not clawed back

     **Impact analysis:**
     - The premium at stake is proportional to the liquidatee's long position fees
     - For a $1M long position with 5% accumulated premium: ~$50K in premium at risk
     - If S holds 50% of the short side of that chunk, S extracts ~$25K that should have been haircut
     - Other sellers collectively lose ~$25K extra (their haircut share increases)

     **Constraints:**
     - S must have a position in the same liquidity chunk as L's long leg
     - S must have accumulated non-zero premium from that chunk
     - The liquidation must cause protocol loss (otherwise no haircut applied)
     - S must be able to front-run (standard mempool visibility)

     **Verdict**: **VIABLE** but situational. Requires collusion or mempool observation, a position in the specific chunk, and protocol loss during liquidation. The extracted value is bounded by the premium accumulated by the front-runner.

     ---

     ### A.6 Bonus Manipulation via Position Construction

     **Goal**: Maximize `bonus / deposit` ratio.

     **Analysis:**

     The bonus is `min(bal * 0.2, req - bal)`. To maximize the bonus for a given deposit D:
     - Need `req - bal ≥ 0.2 * bal`, i.e., `req ≥ 1.2 * bal`
     - Since `bal ≈ D` and insolvency requires `req > bal`, deep insolvency trivially satisfies this

     **At max**: bonus = `0.2 * bal ≈ 0.2 * D`. This is invariant to position type.

     **Position type effects on collateral efficiency:**

     | Position | Collateral Requirement | Bonus / Capital |
     |----------|----------------------|-----------------|
     | Naked short put | 20% of notional (base util) | ≤ 20% of deposit |
     | Short strangle | 10% of notional (50% efficiency) | ≤ 20% of deposit |
     | Spread (defined risk) | Max loss between strikes | ≤ 20% of deposit |
     | Loan + short | `max(loan, short_req)` | ≤ 20% of deposit |

     The 20% cap applies uniformly regardless of position construction. Strangles allow more notional per unit of capital, but this doesn't increase the bonus-to-deposit ratio.

     **Cross-collateral inflation:**

     The bonus is computed per-token then combined (RE:530-535). The cross-collateral adjustment (RE:565-606) rebalances between tokens but preserves total value:
     ```
     bonus1 += min(surplus1, convert0to1(shortfall0))   // gives token1
     bonus0 -= min(convert1to0(surplus1), shortfall0)    // takes token0
     ```
     The conversions use `atSqrtPriceX96` (twapTick-based). Rounding favors the protocol:
     - `convert0to1` floors (less given)
     - `convert0to1RoundingUp` ceils (more taken)

     **No inflation vector exists.** The cross-collateral mechanism is a zero-sum rebalancing.

     **Verdict**: NOT VIABLE. The 20% MAX_BONUS cap is position-agnostic and cannot be exceeded.

     ---

     ## B) Force Exercise Attack Surface

     ### B.1 Force Exercise Griefing

     **Cost to exercisor** (RE:414-500):
     - In-range: `FORCE_EXERCISE_COST / DECIMALS = 102,400 / 10,000,000 = 1.024%` of long notional
     - Out-of-range: `ONE_BPS / DECIMALS = 1,000 / 10,000,000 = 0.01%` of long notional
     - Plus delta compensation: `(currentValue - oracleValue)` per token for each long leg (RE:482-487)

     **Exercisability requirements** (TokenId:520-536):
     - Must have at least one long leg with `width > 0`
     - `countLongs() > 0 && validateIsExercisable() > 0` (PP:1564)

     **Cost analysis for out-of-range positions:**

     | Notional | Exercise Fee (0.01%) | Gas (ETH mainnet, ~$15) | Gas (L2, ~$0.05) |
     |----------|---------------------|------------------------|-------------------|
     | $10K | $1 | $15 | $0.05 |
     | $100K | $10 | $15 | $0.05 |
     | $1M | $100 | $15 | $0.05 |
     | $10M | $1,000 | $15 | $0.05 |

     For positions < $150K notional on mainnet, gas exceeds the exercise fee. On L2s, the exercise fee dominates for positions > $500.

     **Impact on exercised user:**
     - Position is closed (burned through SFPM)
     - Receives the exercise fee as compensation
     - Loses their option exposure (opportunity cost)
     - Any accumulated but uncollected premium must be accounted for during burn

     **Griefing viability**: For far-OTM positions, the exercise fee is negligible and the exercised user suffers minimal harm (the position had minimal value anyway). For near-ATM positions, the 1.024% fee makes griefing expensive.

     **Liquidity manipulation**: Force-exercising many longs in a chunk removes `removedLiquidity`, which changes the spread premium dynamics. This could:
     - Decrease the premium spread (less removedLiquidity / netLiquidity ratio)
     - Reduce premium owed by shorts in that chunk
     - But the cost of force-exercising many positions makes this uneconomical

     **Verdict**: LOW RISK. The fee structure adequately prices force exercise. Far-OTM griefing is cheap ($0.01% per position) but the positions being exercised have negligible value. Near-ATM griefing is expensive (1.024%). The `MAX_TWAP_DELTA_DISPATCH = 513` check (PP:1543) prevents force exercise during price manipulation.

     ---

     ### B.2 Force Exercise + Liquidation Combo

     **Scenario**: Attacker holds short position S that is barely solvent. Target holds long position L in same chunk, far OTR.

     1. Attacker force-exercises L (cost: 0.01% of L's notional)
     2. Liquidity returns to chunk → `removedLiquidity` decreases
     3. Spread premium dynamics change for chunk

     **Does this affect S's solvency?**

     Solvency depends on:
     - `balance` (from CollateralTracker shares) — **unchanged** by force exercise of another user
     - `requirement` (from position collateral computation) — depends on position structure and utilization at mint time, **unchanged** by force exercise of another user
     - `shortPremium` / `longPremium` — the accumulated premium changes, which could affect available balance

     If the premium dynamics change such that S owes less premium, S's effective balance improves slightly. But this effect is marginal and the cost of force-exercising positions to achieve it is disproportionate.

     **Reverse scenario** (trigger liquidation of others):
     - Force-exercising a long reduces liquidity utilization in the chunk
     - Lower utilization → lower collateral requirements (sell ratio decreases)
     - This makes accounts MORE solvent, not less

     **Verdict**: NOT VIABLE. Force exercise cannot meaningfully manipulate another user's solvency.

     ---

     ### B.3 Force Exercise Cost Function Analysis

     **Cost structure** (RE:490-499):
     ```solidity
     int256 fee = hasLegsInRange ? -int256(FORCE_EXERCISE_COST) : -int256(ONE_BPS);
     exerciseFees = exerciseFees
         .addToRightSlot(int128((longAmounts.rightSlot() * fee) / int256(DECIMALS)))
         .addToLeftSlot(int128((longAmounts.leftSlot() * fee) / int256(DECIMALS)));
     ```

     This is a **binary** fee, not exponential decay:
     - Any leg in-range: 1.024% flat
     - All legs out-of-range: 0.01% flat

     The exponential decay described in the prompt applies to the **long collateral requirement** (RE:1517-1557), not the exercise cost.

     **Delta compensation** (RE:476-487):
     ```
     exerciseFees -= (currentValue - oracleValue)  // per token, per long leg
     ```
     This compensates the exercisee for any price delta between `currentTick` and `oracleTick` on their liquidity chunk. If the price has been manipulated away from the oracle, the exercisor pays the difference.

     **Symmetry**: The fee is applied to `longAmounts`, which is token0/token1 notional. The fee applies to whichever tokens the position holds at the oracle tick. For puts (token1 dominant) and calls (token0 dominant), the fee magnitude scales with the notional value in the respective token.

     **Manipulation via oracle tick**: The delta compensation uses `oracleTick = twapTick` (PP:1795-1796, passed from `dispatchFrom`). `MAX_TWAP_DELTA_DISPATCH = 513` is enforced (PP:1543), preventing large current/TWAP divergence during force exercise. This limits the attacker's ability to manipulate the delta compensation.

     **Break-even distance** (gas vs fee):
     - On ETH mainnet (~200k gas, $15): 0.01% fee covers gas at notional > $150,000
     - On L2 (~200k gas, $0.05): 0.01% fee covers gas at notional > $500
     - On ETH mainnet: 1.024% fee covers gas at notional > $1,500

     **Verdict**: The binary fee structure is robust. The `MAX_TWAP_DELTA_DISPATCH` check prevents cost manipulation. Gas costs on mainnet naturally discourage low-value griefing.

     ---

     ## C) Cross-Collateral Liquidation Edge Cases

     ### C.1 Conversion Rate Manipulation

     **Conversion path during liquidation:**

     | Operation | Price source | Function |
     |-----------|-------------|----------|
     | Bonus computation (RE:511-617) | `atSqrtPriceX96 = getSqrtRatioAtTick(twapTick)` | `convert0to1` / `convert1to0` |
     | Solvency check (RE:1005-1062) | `sqrtPriceX96 = getSqrtRatioAtTick(atTick)` per tick | `convert0to1` / `convert1to0` |
     | Token refund (RE:311-398) | `sqrtPriceX96 = getSqrtRatioAtTick(atTick)` | `convert0to1RoundingUp` / `convert1to0RoundingUp` |

     All conversions use oracle-derived ticks (twapTick or per-tick solvency). Flash loan manipulation of spot price does not affect these.

     **Multi-epoch manipulation of twapTick:**
     - After 3 epochs (192s): twapTick moves ~183 ticks ≈ 1.8% price change
     - This shifts the conversion rate by ~1.8%
     - For an account with $100K surplus in token0 and deficit in token1: ~$1,800 conversion error
     - This is well within the margin buffer (typically ≥20%)

     **crossBufferRatio at high utilization:**

     At >95% utilization: `crossBufferRatio = 0` (RE:2180-2181)
     - Surplus in one token provides ZERO cross-collateral benefit
     - Accounts with split-token requirements and no cross-buffer are effectively uncollateralized in the deficit token

     **Attack**: Push utilization > 95% to eliminate cross-collateral benefit:
     1. Attacker opens large short positions, pushing utilization from 85% to 96%
     2. Other accounts that relied on cross-buffer become undercollateralized
     3. Liquidate them

     **Cost**: The attacker must deploy massive capital (enough to shift utilization by ~10 percentage points). On a $10M vault, this requires ~$1M in additional borrowing. The attacker earns no direct profit from the liquidations (bonus comes from the liquidatees, not from pool utilization).

     **Verdict**: The conversion rate is oracle-protected and manipulation-resistant. The utilization-based cross-buffer elimination IS a leverage vector but requires disproportionate capital to exploit.

     ---

     ### C.2 Per-Token Bonus Rounding

     **Bonus computation** (RE:530-535):
     ```solidity
     bonus0 = Math.min((bal0 * MAX_BONUS) / DECIMALS, req0 > bal0 ? req0 - bal0 : 0).toInt256();
     bonus1 = Math.min((bal1 * MAX_BONUS) / DECIMALS, req1 > bal1 ? req1 - bal1 : 0).toInt256();
     ```

     Both use integer division (floor). The cross-collateral adjustments (RE:576-601):
     ```
     bonus1 += min(surplus, convert0to1(shortfall))        // floor conversion
     bonus0 -= min(convert1to0RoundingUp(surplus), shortfall) // ceil conversion
     ```

     The bonus0 REDUCTION uses `convert1to0RoundingUp` (ceil), meaning MORE is subtracted from bonus0 than the exact conversion. The bonus1 ADDITION uses `convert0to1` (floor), meaning LESS is added.

     **Net effect**: The combined bonus in either token terms is slightly LESS than the exact value. Protocol-conservative rounding throughout.

     **Can bonus exceed available collateral?** No. The loan clamping (RE:540-549) ensures `bonus/0.2 + loans ≤ bal`, and the cross-collateral rebalancing preserves total value with protocol-favorable rounding.

     **When bonus0 > 0 but would require token1 deficit coverage (RE:565-606):**

     The `tokenConversion` path at RE:567-606 handles this correctly:
     - `paid0 > balance0 && paid1 ≤ balance1`: surplus token1 covers token0 deficit
     - `paid1 > balance1 && paid0 ≤ balance0`: surplus token0 covers token1 deficit
     - Both exceeded: no conversion possible, protocol loss in both tokens
     - Neither exceeded: no conversion needed

     The conversion amounts are clamped to the minimum needed:
     ```
     min(balance1 - paid1, convert0to1(paid0 - balance0))
     ```
     preventing over-conversion.

     **Verdict**: No rounding exploit. All rounding is protocol-conservative.

     ---

     ### C.3 Extreme Price Scenarios

     **At `MIN_POOL_TICK` (-887272):**
     - `sqrtPriceX96 = 4,295,128,739` (≈ 5.4e-29 in price terms)
     - Token0 is worth ~0 relative to token1
     - `convert0to1(any_amount) ≈ 0` (multiplying by sqrtPrice^2 / 2^192 ≈ 0)
     - `convert1to0(any_amount) → extremely large` (dividing by sqrtPrice^2 / 2^192)

     **At `MAX_POOL_TICK` (887272):**
     - `sqrtPriceX96 ≈ 1.46e48` (> uint128.max)
     - Uses reduced precision path (PanopticMath:505-515): `mulDiv128` instead of `mulDiv192`
     - Token1 is worth ~0 relative to token0
     - `convert1to0(any_amount) ≈ 0`
     - `convert0to1(any_amount) → extremely large`

     **Solvency check behavior (RE:1049-1061):**

     The check branches on `sqrtPriceX96 < Constants.FP96` (2^96):
     - Below FP96 (token0 pricier): all conversions done in token0 terms
     - Above FP96 (token1 pricier): all conversions done in token1 terms

     At extreme prices, the conversion of the "worthless" token surplus provides near-zero cross-collateral benefit, which is correct behavior — you can't use worthless tokens to offset real obligations.

     **Overflow protection**: For sqrtPriceX96 > uint128.max (above tick ~443,636), the conversion functions switch to reduced-precision math to prevent `sqrtPrice^2` from overflowing uint256.

     **Verdict**: Extreme prices are handled correctly by design. The precision reduction at high ticks prevents overflow. Cross-collateral benefit naturally vanishes for worthless tokens.

     ---

     ## D) Findings

     ### LIQ-001: Premium Haircut Front-Running by Short Sellers

     **Severity**: Medium
     **Category**: timing / MEV

     **Attack sequence:**
     1. Short seller S has position in chunk C, with $25K accumulated premium from liquidatee L's long position
     2. L becomes insolvent (position moved against them)
     3. S observes L's pending liquidation tx in mempool
     4. S front-runs by burning their short position, collecting their $25K share from `s_settledTokens[C]`
     5. L's liquidation executes with `DONOT_COMMIT_LONG_SETTLED` (PP:1719)
     6. `haircutPremia` (RE:627) reduces what's added to `s_settledTokens[C]` by the haircut amount
     7. The haircut is distributed across OTHER short sellers who didn't withdraw

     **Capital required**: S already has an existing short position. No additional capital needed.
     **Expected profit**: Up to S's share of accumulated premium in the chunk (~$25K in example).
     **Who is harmed**: Other short sellers in the same chunk bear a disproportionate share of the haircut.
     **Existing mitigations**:
     - `DONOT_COMMIT_LONG_SETTLED` prevents the liquidatee's own premium from being front-run (PP:1719)
     - But it does NOT prevent third-party shorts from withdrawing their already-accumulated premium before the haircut
     **Effectiveness**: Partial. Protects against liquidatee self-dealing but not third-party timing.
     **Repeatable**: Yes, on every liquidation with protocol loss and accumulated premium in affected chunks.

     ---

     ### LIQ-002: Unlimited Tick Limits on Liquidation Burns Enable Sandwich MEV

     **Severity**: Low
     **Category**: MEV

     **Attack sequence:**
     1. Attacker monitors mempool for liquidation transactions
     2. Front-runs: moves Uniswap spot price (e.g., via flash loan)
     3. Liquidation executes `_burnAllOptionsFrom` with `MIN_SWAP_TICK`/`MAX_SWAP_TICK` limits (PP:1717-1718)
     4. Position closing trades execute at the manipulated price (no slippage protection)
     5. Back-runs: reverses price movement

     **Capital required**: Flash loan (no upfront capital), gas for 3 transactions.
     **Expected profit**: Standard AMM sandwich profit from the position closing trades. For a liquidation closing $1M in positions, typical sandwich extraction is 0.1-1% = $1K-$10K.
     **Who is harmed**: The protocol (increased protocol loss) and PLPs (socialized losses). The liquidatee's collateral is further depleted.
     **Existing mitigations**:
     - The bonus is computed at twapTick, unaffected by sandwich
     - The sandwich only affects netPaid (AMM execution), which increases protocol loss
     **Effectiveness**: No protection for the AMM execution itself.
     **Repeatable**: Yes, on every liquidation that involves AMM swaps.

     **Note**: The unlimited tick limits are intentional for liquidations (ensuring positions can always be closed), but this makes the AMM swaps vulnerable to standard sandwich attacks.

     ---

     ### LIQ-003: Cross-Buffer Elimination via Utilization Manipulation

     **Severity**: Low
     **Category**: price-manipulation

     **Attack sequence:**
     1. Attacker identifies accounts that rely on cross-collateral buffer for solvency
     2. Attacker opens large short positions, pushing vault utilization from ~85% to >95%
     3. `crossBufferRatio` drops to 0 (RE:2180-2181)
     4. Target accounts' cross-collateral benefit disappears
     5. Accounts become undercollateralized, eligible for liquidation

     **Capital required**: Enough to shift utilization by ~10 percentage points. For a $10M vault at 85% utilization: ~$1.5M in additional deposits + short positions.
     **Expected profit**: Liquidation bonuses from newly insolvent accounts (max 20% of their balances).
     **Who is harmed**: Accounts that relied on cross-collateral buffer for solvency.
     **Existing mitigations**:
     - Linear decline from 90% → 95% (not a cliff)
     - Accounts should not rely on cross-buffer for solvency if pool utilization is already near 90%
     - High utilization increases interest rates, making the attack costly to maintain
     - Sell collateral ratio increases to 100% above 90% utilization, further discouraging the attack
     **Effectiveness**: High natural resistance due to economic costs.
     **Repeatable**: Difficult to sustain; interest costs accumulate.

     ---

     ### LIQ-004: Liquidation Cascade via Share Dilution

     **Severity**: Informational
     **Category**: cascade

     **Attack sequence:**
     1. Large liquidation causes protocol loss
     2. `settleLiquidation` mints shares, diluting share price
     3. Other accounts near margin boundary become insolvent
     4. Cascading liquidations

     **Capital required**: The attacker bears 100% of the loss on their liquidated account. For a meaningful cascade: $500K+ across multiple accounts.
     **Expected profit**: Net negative. The attacker loses ≥80% of deployed capital.
     **Who is harmed**: All vault depositors (share dilution). Marginal accounts (forced liquidation).
     **Existing mitigations**:
     - `mintedShares ≤ totalSupply * DECIMALS` cap (CT:1345)
     - 20% bonus cap limits extraction per step
     - Safe Mode triggers (RE:914-946) at high volatility, imposing 100% collateral
     - Interest rate spikes at high utilization
     - Accounts close to margin should be liquidated proactively
     **Effectiveness**: Natural damping is strong. Self-sustaining cascades require extreme market conditions, not attacker action.
     **Repeatable**: Only during genuine market stress.

     ---

     ### LIQ-005: Force Exercise of Near-Worthless Positions as Griefing

     **Severity**: Informational
     **Category**: griefing

     **Attack sequence:**
     1. Attacker scans for far-OTM long positions held by other users
     2. Force-exercises each for 0.01% of notional
     3. On L2s where gas is cheap, this can be done for $0.05 per position

     **Capital required**: Gas costs only. The 0.01% fee is paid TO the exercisee.
     **Expected profit**: None — this is a griefing vector, not profit extraction.
     **Who is harmed**: Long holders who lose their far-OTM exposure (though the position has negligible current value).
     **Existing mitigations**:
     - `MAX_TWAP_DELTA_DISPATCH` prevents force exercise during price manipulation
     - The exercisee receives the 0.01% fee as compensation
     - Far-OTM positions have negligible value, so the harm is minimal
     **Effectiveness**: Adequate for economic harm prevention. The griefing is more of an annoyance than a material loss.
     **Repeatable**: Yes, but impact is negligible.

     ---

     ## E) Economic Bounds

     ### E.1 Self-Liquidation (A.1)

     | Parameter | Value |
     |-----------|-------|
     | Minimum deposit | Any amount |
     | Maximum bonus extraction | 20% of deposit |
     | Commission cost | 0.01% of notional (≈ 0.05% of deposit at 20% collateral ratio) |
     | **Net P&L** | **-80% of deposit** |
     | Break-even | **Impossible** — structurally unprofitable |

     ### E.2 Oracle Manipulation for False Liquidation (A.2)

     | Parameter | Value |
     |-----------|-------|
     | Oracle movement per epoch (twapTick) | ~61 ticks (0.6%) |
     | Oracle movement per 3 epochs (192s) | ~183 ticks (1.8%) |
     | Cost to move Uniswap price 10% for 3 min on $10M pool | ~$1M+ |
     | Max bonus from forced liquidation | 20% of target's balance |
     | **Break-even**: target balance needed | ~$5M (to extract $1M bonus at 20%) |
     | **Feasibility** | Extremely unlikely — target must be within 1.8% of margin AND have $5M+ balance |

     ### E.3 Premium Haircut Front-Running (LIQ-001)

     | Parameter | Value |
     |-----------|-------|
     | Capital required | Existing short position (sunk cost) |
     | Expected extraction | Pro-rata share of accumulated premium in chunk |
     | Maximum extractable | Limited by accumulated `s_settledTokens` in the chunk |
     | Gas cost | ~$15 (mainnet) / ~$0.05 (L2) |
     | **Break-even** | Premium share > gas cost — trivially achievable for non-dust positions |
     | **Scalability** | Limited to chunks where attacker has positions |

     ### E.4 Force Exercise Griefing (LIQ-005)

     | Parameter | Value |
     |-----------|-------|
     | Cost per exercise (far OTM) | 0.01% of notional + gas |
     | Gas (mainnet) | ~$15 |
     | Gas (L2) | ~$0.05 |
     | Break-even for griefing | N/A (pure cost to attacker) |
     | Notional where fee < gas (mainnet) | < $150K |
     | **Parameter sensitivity** | If `ONE_BPS` halved to 500: griefing cost halves, but still uneconomical for attacker |
     | If `FORCE_EXERCISE_COST` halved to 51,200: in-range cost drops to 0.512%, still meaningful deterrent |

     ---

     ## F) Recommendations

     ### F.1 For LIQ-001 (Premium Haircut Front-Running)

     **Minimal code change**: Add a snapshot mechanism that records per-chunk premium state at the beginning of a liquidation, and applies the haircut retroactively to any settlements that occurred in the same block.

     Specifically, add a block-number-based lock in `s_settledTokens`:
     ```solidity
     // In PanopticPool.sol, before _liquidate:
     // Record chunks involved in liquidatee's positions
     // In CollateralTracker.settleBurn:
     // If the chunk has a pending liquidation in the same block, defer the settlement
     ```

     **Alternatively** (simpler but less precise): During `_liquidate`, before `_burnAllOptionsFrom`, record the current `s_settledTokens` values for all affected chunks. After `haircutPremia`, compare with current values and retroactively reduce any excess withdrawals. This requires tracking which chunks were touched during the liquidation.

     **Parameter adjustment**: N/A — this is a structural issue, not a parameter issue.

     **Monitoring**: Alert on `PremiumSettled` events that occur in the same block as `AccountLiquidated` events in the same pool, especially for the same chunks. This pattern indicates potential front-running.

     ---

     ### F.2 For LIQ-002 (Sandwich MEV on Liquidation Burns)

     **Minimal code change**: Not straightforward — liquidation burns must succeed even at unfavorable prices. The `MIN_SWAP_TICK`/`MAX_SWAP_TICK` limits are intentionally permissive.

     **Alternative**: Use a two-step liquidation:
     1. Step 1: Verify insolvency and lock the liquidation (no AMM interaction)
     2. Step 2: Execute position burns in a subsequent transaction with more reasonable tick limits

     This is a significant architectural change and may not be worth the complexity for the marginal MEV protection.

     **Monitoring**: Track the price impact of liquidation burn transactions vs. the preceding and following blocks. Flag cases where the price reverts significantly after a liquidation (indicating sandwich).

     ---

     ### F.3 For LIQ-003 (Cross-Buffer Utilization Manipulation)

     **Parameter adjustment**: Consider making the cross-buffer decline more gradual (e.g., 85% → 100% instead of 90% → 95%) to make the attack more expensive. However, this reduces capital efficiency during normal operation.

     **Monitoring**: Alert when pool utilization crosses 90% threshold, especially if driven by a single account or a small number of accounts. This could indicate deliberate utilization manipulation.

     ---

     ### F.4 For LIQ-004 (Cascade via Share Dilution)

     **No code change recommended.** The existing mitigations (share minting cap, safe mode, interest spikes) are adequate. Cascades are a feature of all leveraged lending systems and the protocol's natural damping mechanisms limit their depth.

     **Monitoring**: Track the ratio of `protocolLossShares` to `totalSupply` per liquidation event. Alert if cumulative protocol loss in a 1-hour window exceeds 5% of totalAssets.

     ---

     ### F.5 General Recommendations

     1. **Oracle freshness**: Consider adding a minimum interaction frequency requirement (e.g., if no oracle update in >30 minutes, require an oracle poke before accepting liquidations). This prevents stale oracle exploitation, though the current design already resists this.

     2. **Liquidation incentive alignment**: The 20% MAX_BONUS cap is well-chosen — high enough to incentivize liquidators, low enough to prevent extraction. No change recommended.

     3. **Force exercise deterrence**: The binary in-range/out-of-range fee is simpler than the prompt suggested. Consider whether a more granular distance-based fee (actual exponential decay) would better price force exercise at intermediate distances.

     ---

     ## Appendix: Oracle Resistance Summary

     | Attack | Oracle ticks affected | Resistance |
     |--------|----------------------|------------|
     | Flash loan (1 block) | Only currentTick | 3 of 4 ticks unaffected |
     | 1-epoch manipulation (64s) | currentTick, spotEMA (~149 ticks) | twapTick, latestTick resist |
     | 3-epoch manipulation (192s) | currentTick, spotEMA (~447), twapTick (~183) | latestTick (stored, stale) still resists |
     | Sustained manipulation (10+ min) | All ticks eventually move | Arbitrageurs correct, Safe Mode triggers |

     The 4-tick solvency check during liquidation (`dispatchFrom` always checks spotTick, twapTick, latestTick, currentTick per PP:1515-1519) is the strongest protection. Unlike normal solvency checks which may use only 1 tick, liquidations always require insolvency at all 4 ticks, making oracle manipulation for false liquidations extremely difficult.
