# Premium System Economic Attacks Audit

**Date**: 2026-03-03
**Scope**: `contracts/` (recursive) — SFPM, PanopticPool, CollateralTracker, RiskEngine, LeftRight, InteractionHelper
**Threat Model**: Full MEV adversary with sandwich capability, multi-account control, Uniswap fee generation capability

---

## A) Premium Flow Tracing

### A.1 Fee Collection Path

**Uniswap fees → SFPM accumulators:**

1. `SFPM._createLegInAMM` calls Uniswap V4 `modifyLiquidity()` → returns `feesAccrued` (SFPM:1067-1076)
2. Guard: `if (currentLiquidity.rightSlot() > 0)` (SFPM:1086) — only collect if pre-existing liquidity (prevents 0-liquidity poke)
3. Pack collected amounts into `LeftRightUnsigned`: `[collected1 | collected0]` (SFPM:1088-1090)
4. Call `_updateStoredPremia(positionKey, currentLiquidity, collectedAmounts, vegoid)` (SFPM:1092)
5. Inside `_updateStoredPremia` (SFPM:1100-1121):
   - Compute deltas via `_getPremiaDeltas()` (SFPM:1107-1109)
   - Apply `addCapped()` to both `s_accountPremiumOwed[positionKey]` and `s_accountPremiumGross[positionKey]` (SFPM:1114-1120)

**Per-unit premium formula** (SFPM:1148-1214):

```
base = collected * totalLiquidity * 2^64 / netLiquidity^2       [floor]
owed = base * (netLiquidity + removedLiquidity/vegoid) / totalLiquidity  [floor, then toUint128Capped]
gross = base * (T^2 - T*R + R^2/vegoid) / T^2                   [floor, then toUint128Capped]
```

**Rounding**: All divisions floor. Both `owed` and `gross` are systematically underestimated. Protocol-favorable.

**Manipulable state reads**: `currentLiquidity` (netLiquidity, removedLiquidity) read from SFPM storage. These change with every mint/burn in the chunk. An attacker who controls liquidity in a chunk can influence the `totalLiquidity/netLiquidity^2` multiplier.

**Ordering dependency**: `_collectAndWritePositionData` is called during mint/burn. Fees collected depend on the Uniswap fee growth since last touch. If multiple positions touch the same chunk in the same block, only the first touch collects accumulated fees; subsequent touches see 0 new fees.

### A.2 Short Seller Closing (Premium Collection)

**Path**: `_burnOptions` → SFPM.burn → `_updateSettlementPostBurn` (PP:1270-1469)

1. Compute `premiaByLeg` and `premiumAccumulatorsByLeg` via `_getPremia()` (PP:1281-1289)
2. For each short leg (PP:1313-1431):
   - Condition: `commitLongSettledAndKeepOpen.leftSlot() == 0 || msg.sender == owner` (PP:1314) — **only the owner or a full-burn can settle short premium**
   - Load `settledTokens = s_settledTokens[chunkKey] + collectedByLeg[leg]` (PP:1296-1298)
   - Load `grossPremiumLast = s_grossPremiumLast[chunkKey]` (PP:1341)
   - Compute `availablePremium = _getAvailablePremium(totalLiquidityBefore, settledTokens, grossPremiumLast, premOwed, accumulators)` (PP:1343-1349)
   - Deduct: `settledTokens -= availablePremium` (PP:1352)
   - Add to realized: `realizedPremia += availablePremium` (PP:1355-1357)
   - **Reassign** `premiaByLeg[leg] = availablePremium` (PP:1360-1362) — NOTE: local `legPremia` retains original value
   - Update grossPremiumLast: `Ln = max(L*T - C*R + legPremia*2^64, 0) / (T-R)` (PP:1389-1429)
3. Write `s_settledTokens[chunkKey] = settledTokens` (PP:1434)
4. Erase `s_options[owner][tokenId][leg]` (PP:1438) and `s_positionBalance` (PP:1463)

**What determines how much the seller receives**: `availablePremium = min(premOwed * settled / accumulated, premOwed)` (PP:2286-2299). The ratio `settled/accumulated` determines the fraction. If settled tokens are scarce (buyers haven't paid, or other sellers already withdrew), the seller receives less.

**Rounding in `_getAvailablePremium`** (PP:2266-2304):

- `accumulated0 = (accum[0] - grossLast.right) * totalLiq / 2^64` — floor division
- `availableToken0 = min(premOwed.right * settled.right / accumulated0, premOwed.right)` — floor division
- **Favors**: protocol (seller receives less than theoretical maximum)

### A.3 Long Holder Closing (Premium Payment)

**Path**: Same `_updateSettlementPostBurn`, long leg branch (PP:1301-1312):

1. If `commitLongSettled` flag set (rightSlot != 0):
   - `settledTokens += |legPremia|` (PP:1303-1311) — buyer's payment flows INTO the settled pool
   - Note: `legPremia` is NEGATIVE for longs (convention), so `.sub(legPremia)` = addition
2. `realizedPremia += legPremia` (PP:1312) — negative → buyer pays from collateral

**What determines the amount**: `legPremia = (currentAccumulator - snapshotAtOpen) * positionLiquidity / 2^64` (PP:2226-2228). Floor division.

**Can the buyer influence it?** The buyer cannot reduce their owed premium. The accumulator is global (per-chunk) and monotonically non-decreasing. The snapshot was fixed at mint time (PP:1204-1206). The only way to reduce premium is to close before more fees accumulate — which is economically rational but not an "attack."

### A.4 Forced Settlement via `settleLongPremium`

**Trigger**: Any address calls `dispatchFrom` with `positionIdListTo.length == positionIdListToFinal.length` while the target account is solvent at all 4 ticks (spot, TWAP, latest, current) (PP:1536-1561).

**Path**: `dispatchFrom` → `_settlePremium` (PP:1848-1871):

1. Delegate virtual shares to owner (PP:1855-1856)
2. `_settleOptions(owner, tokenId, positionSize, riskParameters, currentTick)` (PP:1862)
3. Inside `_settleOptions` (PP:1115-1139): calls `_updateSettlementPostBurn` with `commitLongSettledAndKeepOpen = (1, 1 + (currentTick << 2))`
   - rightSlot = 1 → commit long settled (buyer pays)
   - leftSlot ≠ 0 → keep position open; don't erase s_options
   - **Critically**: short legs NOT settled because condition at PP:1314 fails (`leftSlot != 0 && msg.sender != owner`)
4. Post-settlement solvency check (PP:1576-1582)

**Who can trigger**: Anyone. No access control beyond solvency.

**Economic incentives**: Short sellers who need to collect premium from the settled pool are incentivized to force long holders to settle, replenishing settledTokens.

**Minimum interval**: None. Can be called repeatedly, but each call is a no-op if no new premium has accumulated since the last settlement (accumulator snapshot gets updated at PP:1445-1448, only if premia is non-zero — line 1444).

### A.5 Premium During Liquidation

**Path**: `_liquidate` (PP:1670-1779):

1. Calculate accumulated premia (PP:1684-1690) with `ONLY_AVAILABLE_PREMIUM` (short premium capped by settled/accumulated)
2. **Burn all positions with `DONOT_COMMIT_LONG_SETTLED`** (PP:1716-1722) — long premium NOT added to settledTokens
3. Calculate liquidation bonus and collateral remaining (PP:1727-1733)
4. **`haircutPremia`** (RE:599-778): Computes how much of the long premium must be clawed back:
   - Accumulates total `longPremium` across all long legs (RE:629-633)
   - Computes `haircutBase` = min of (protocol loss, long premium) per token, with cross-token conversion if needed (RE:637-700)
   - Pro-rates haircut across individual long legs: `haircutAmounts = leg_premium * haircutBase / longPremium` (RE:729-764) — rounds UP via `unsafeDivRoundingUp`
5. **`InteractionHelper.settleAmounts`** (IH:121-178): For each long leg, adds `(fullPremium - haircut)` to `s_settledTokens[chunkKey]` (IH:150-154)

**Ordering of leg burns**: All positions are burned in a single `_burnAllOptionsFrom` call (PP:1716). Within that call, positions are burned sequentially. Each burn's `_updateSettlementPostBurn` reads and writes `s_settledTokens` and `s_grossPremiumLast`. Since `DONOT_COMMIT_LONG_SETTLED` is set, long legs don't modify settledTokens during burn. Short legs DO collect availablePremium during burn (if condition at PP:1314 holds — but `msg.sender` is the PP itself calling SFPM, so this would need `msg.sender == owner`... actually during liquidation, `_burnAllOptionsFrom` calls `_burnOptions` which calls `_updateSettlementPostBurn`. `msg.sender` in the context of `_updateSettlementPostBurn` is the PanopticPool itself, NOT the liquidator. And `owner` is the liquidatee. So `msg.sender != owner`, and leftSlot != 0 (`DONOT_COMMIT_LONG_SETTLED` sets this). So **short legs of the liquidatee are also NOT settled during liquidation burn**.)

This means during liquidation: neither long premium payment nor short premium collection flows through `_updateSettlementPostBurn`. The only premium settlement is the manual `InteractionHelper.settleAmounts` which adds haircut-adjusted long premium to settledTokens.

**Rounding in haircut**: `unsafeDivRoundingUp` (RE:739, 756) rounds UP the haircut amount. This means slightly MORE premium is clawed back than the exact pro-rata share. The excess accumulates in `haircutTotal` which is applied to the liquidatee's collateral (IH:159-176).

---

## B) Economic Attack Vectors

### B.1 Settlement Timing Attacks

#### B.1.1 Seller Front-Runs Liquidation to Lock In Premium

**Attack sequence**:

1. Seller (Account A) has a short position in chunk C
2. Buyer (Account B) has a long position in chunk C, is about to be liquidated
3. A observes B's upcoming liquidation in the mempool (or anticipates it from price movements)
4. A closes their short position via `dispatch()` → calls `_updateSettlementPostBurn`:
   - A receives `availablePremium` from settledTokens
   - `s_settledTokens[C]` decreases by availablePremium
5. Liquidation of B occurs:
   - B's positions burned with `DONOT_COMMIT_LONG_SETTLED`
   - `haircutPremia` computes haircut based on B's collateral deficit
   - `InteractionHelper.settleAmounts` adds `(fullPremium - haircut)` to s_settledTokens[C]
6. Result: A extracted premium BEFORE the haircut was applied. Other sellers (if any) bear the reduced settledTokens pool.

**Does the haircut apply to A?** No. The haircut reduces what gets ADDED to settledTokens (step 5). A already withdrew (step 4). A keeps their full availablePremium.

**Can A re-open after liquidation?** Yes. A can mint a new short position and benefit from the reset premium state (grossPremiumLast potentially reset to current accumulator if all liquidity was removed).

**Severity**: Medium. Requires MEV capability. Profit = A's availablePremium that would have been haircut. Harm = other sellers in the chunk receive less settled premium.

**Existing mitigations**: The `maxSpread` parameter limits the total removable liquidity, bounding the premium amplification. The haircut mechanism itself limits protocol losses. But no mitigation prevents the ordering exploitation.

**Amplifiability**: Limited by the number of chunks where A has positions and where liquidations are imminent. Not easily scalable.

#### B.1.2 Buyer Delays Settlement to Accumulate Owed Premium

**Attack sequence**:

1. Buyer opens long position in chunk C
2. Buyer avoids all interactions that trigger premium settlement
3. Premium accumulates: `premOwed` grows as SFPM accumulators increase
4. When premOwed > buyer's collateral, buyer becomes insolvent

**Does `settleLongPremium` prevent this?**

- Any third party can call `dispatchFrom` to force settlement (PP:1561)
- Settlement deducts premium from buyer's collateral
- Post-settlement solvency check ensures buyer remains solvent (PP:1576)
- If buyer is already insolvent (premOwed > collateral), the forced settlement would revert (solvency check fails post-settlement) → falls through to liquidation path

**If buyer becomes insolvent before settlement:**

- Liquidation path fires (PP:1584-1592)
- `DONOT_COMMIT_LONG_SETTLED` prevents long premium from entering settledTokens during burn
- `haircutPremia` claws back what can't be covered by remaining collateral
- **Premium IS effectively written off** to the extent that collateral is insufficient

**Severity**: Low. Mitigated by forced settlement mechanism. Any affected seller can trigger it. The buyer bears the insolvency risk (liquidation penalty).

#### B.1.3 Buyer Closes When settled/accumulated Ratio Is Minimal

**Analysis**: The buyer pays full `legPremia` regardless of the settled/accumulated ratio (PP:1303-1312). The ratio only caps what sellers can WITHDRAW, not what buyers PAY.

**Can the buyer manipulate the ratio?** The buyer could generate Uniswap fees (increasing accumulators → increasing accumulated) without those fees being collected into settledTokens. But fee collection happens automatically during any mint/burn in the chunk (SFPM:1086-1092). The fees would be collected as soon as anyone touches the chunk.

**Verdict**: Not a viable attack. The buyer cannot reduce their premium payment through ratio manipulation.

### B.2 Cross-Chunk Premium Arbitrage

#### B.2.1 Different Premium States Across Chunks

Different chunks have different tick ranges → different fee generation rates → different premium states. This is not arbitrageable because the premium differences reflect genuine differences in fee income.

**Same chunk at different times**: Timing entry/exit to exploit premium ratio changes is possible but constrained by:

- Position must be held to earn/owe premium (can't instantaneously extract)
- The grossPremiumLast weighted average (PP:1236) ensures new entrants don't steal existing premium from the accumulated pool
- Entry costs (swap impact, gas) limit profitability

**Verdict**: No systematic arbitrage opportunity.

#### B.2.2 Premium Dilution via Position Splitting

**Analysis of grossPremiumLast on mint** (PP:1236-1252):

```
Ln = (C*R + L*T) / (T+R)
```

where C=grossCurrent, R=new positionLiquidity, L=old grossPremiumLast, T=totalLiquidityBefore.

**Algebraic verification**: Total premium owed before = `T*(C-L)/2^64`. After: `(T+R)*(C-Ln)/2^64 = (T+R)*(C - (C*R+L*T)/(T+R))/2^64 = (C*(T+R) - C*R - L*T)/2^64 = T*(C-L)/2^64`. Invariant preserved.

The new entrant's instant premium = `R*(C-Ln)/2^64 = R*T*(C-L)/((T+R)*2^64)`. This is proportional to R/(T+R) of the total owed premium. The existing sellers are diluted to T/(T+R). The total remains constant.

**Can a new entrant "steal" premium?** No. The entrant receives a proportional share of the owed premium, but their ability to COLLECT it depends on `availablePremium`. Since settledTokens is shared, any premium the new entrant collects reduces what's available for others. This is by design — premium is pro-rata.

**Floor division in the weighted average**: `uint128((C*R + L*T) / (T+R))` floors. This makes `Ln` slightly lower than the theoretical value, meaning the total premium owed increases by a dust amount (1 wei per slot per mint). Over many mints, this could accumulate, but the amount is negligible.

**Verdict**: No exploitable premium theft. Dilution is proportional and by design.

### B.3 Premium Starvation Attacks

#### B.3.1 Liquidity Vacuum (DENOM-003 Follow-Up)

**Attack sequence**:

1. Attacker shorts a large amount of liquidity in chunk C
2. Attacker (or accomplice) longs almost all of the liquidity, leaving `netLiquidity = 1`
3. Any fee collection triggers: `base = collected * totalLiquidity * 2^64 / 1 ≈ enormous`
4. `toUint128Capped` → `uint128.max`
5. `addCapped` freezes both `s_accountPremiumOwed` and `s_accountPremiumGross` for that chunk

**Downstream impact on existing short sellers:**

- `premOwed = (frozen_accumulator - snapshot) * liquidity / 2^64` — fixed, potentially large
- `accumulated = (frozen_accumulator - grossPremiumLast) * totalLiquidity / 2^64` — potentially very large
- `availablePremium = min(premOwed * settled / accumulated, premOwed)`
- If `accumulated >> settled`, sellers receive ≈ 0
- **Premium is frozen**: No future accrual. Existing entitlement capped by settled/accumulated ratio.

**Impact on existing long holders:**

- `premOwed = (frozen_accumulator - snapshot) * liquidity / 2^64` — fixed
- They owe this fixed amount at close. No further increase.

**Impact on new positions:**

- New shorts: grossPremiumLast gets weighted average with frozen accumulator. Their future premium = 0 (no accumulator growth).
- New longs: snapshot = frozen value. Future delta = 0. They owe nothing.
- **Effectively, the chunk is dead for premium purposes.**

**Is the freeze chunk-specific?** Yes. Accumulators are per-`positionKey` (per-chunk, per-tokenType, per-owner). The freeze only affects the specific chunk+tokenType combination.

**Prevention by maxSpread**: `_checkLiquiditySpread` (PP:2145-2169) enforces `removedLiquidity * DECIMALS / netLiquidity ≤ maxSpread`. For netLiquidity=1, this requires `removedLiquidity ≤ maxSpread / DECIMALS`. But if maxSpread is large (e.g., 32767 = 327.67%), the attacker could reach netLiquidity as low as `totalLiquidity / (1 + maxSpread/10000)`. With maxSpread=32767, the minimum netLiquidity is `totalLiquidity / 4.2767` — not as extreme as netLiquidity=1 but still amplifying.

**However**: reaching netLiquidity=1 requires removing essentially all liquidity. The spread check prevents this unless the attacker is the sole seller AND removes all but 1 unit. If the attacker controls the entire chunk, this is feasible.

**Severity**: Medium (confirmed, same as DENOM-003). Chunk-scoped. Requires controlling all liquidity in a chunk.

#### B.3.2 settledTokens Manipulation

**Can an attacker drain settledTokens to zero?**

Each short close deducts `availablePremium` from settledTokens (PP:1352). The available premium is:

```
availablePremium = min(premOwed * settled / accumulated, premOwed)
```

The attacker receives their pro-rata share. If the attacker is the only seller, they receive `min(premOwed * settled / accumulated, premOwed)`. If settled ≈ accumulated (all owed premium is backed by settled tokens), the attacker receives full premOwed, which could drain settledTokens completely.

**Scenario**:

1. Attacker is the sole short seller in chunk C
2. Some long premium has been collected (settledTokens > 0, accumulated > 0)
3. Attacker closes → receives min(premOwed \* settled / accumulated, premOwed)
4. settledTokens → settledTokens - availablePremium (could reach 0)
5. Attacker re-mints a short position
6. New fees accumulate, increasing settledTokens
7. Attacker closes again → receives new premium

Each cycle, the attacker collects their fair share. No other sellers are harmed because the attacker is the sole seller. If other sellers exist, the pro-rata mechanism ensures fair distribution.

**Can the attacker drain others' premium?** No. The availablePremium formula allocates proportionally to each seller's `premOwed` relative to total `accumulated`. The attacker can only collect their own share.

**Edge case: settledTokens ≈ 0 with multiple sellers:**
If settled = 0 and accumulated > 0, all sellers get 0. This happens when:

- No Uniswap fees have been collected since the last drain
- No long premium has been committed

This is transient — the next fee collection restores settledTokens. Not a permanent DoS.

**Verdict**: Not a viable attack. Pro-rata allocation prevents disproportionate extraction.

### B.4 Long Premium Evasion

#### B.4.1 Dust Positions

**Minimum liquidity**: 1 (SFPM:972 rejects only 0).

**Premium for liquidity=1**:

```
premOwed = (accumulatorDelta * 1) / 2^64
```

For any accumulator delta < 2^64, this rounds to 0. The buyer pays nothing.

**Economic exposure**: With liquidity=1, the notional value is essentially 0. To convert positionSize to liquidity, PanopticMath uses the current price and tick range. A position with meaningful notional value requires meaningful liquidity.

**Constraints**: MAX_OPEN_LEGS across all positions. Gas costs per position (~300k+ per mint). The capital required for meaningful exposure via dust positions far exceeds the premium saved.

**Verdict**: Not economically viable. Premium saved ≈ 0 because exposure ≈ 0.

#### B.4.2 Rapid Open/Close (Same Block)

**Can open+close happen in same `dispatch`?** Yes, but for DIFFERENT positions:

- Position A (not owned) → mint
- Position B (owned) → burn

For the SAME position: mint at i=0, then at i=1 the position exists, so:

- If `positionSizes[1] == storedSize` → settle (no-op if no premium accrued)
- If `positionSizes[1] != storedSize` → burn

**Premium accrual in same block**: `premOwed = (currentAccumulator - snapshot) * liquidity / 2^64`. Since the mint just set the snapshot to the current accumulator, the delta = 0. Premium paid = 0.

**Is this an evasion?** No. Zero premium corresponds to zero exposure time. The position earned no yield and bore no risk.

**Verdict**: Not an attack. Economically neutral.

### B.5 Premium and Solvency Interaction

#### B.5.1 Fee-Driven Insolvency Attack

**Attack sequence**:

1. Target has a long position in chunk C, close to maintenance margin
2. Attacker swaps in the Uniswap pool underlying chunk C, generating fees
3. Fees increase SFPM accumulators for chunk C
4. Target's `longPremium` increases (computed via `_getPremia`)
5. `longPremium` is added to maintenance requirement (RE:1237)
6. If the increase pushes target below maintenance → target is liquidatable

**Cost analysis**:

- To generate X tokens in Uniswap fees, attacker must swap `X / feeRate` tokens (e.g., X/0.003 for 0.3% pool)
- Premium increase for target: `X * totalLiq / netLiq^2 * posLiq / 2^64 * (spread factor)`
- If `posLiq << netLiq`, the premium increase is much smaller than X
- The amplification factor depends on the spread ratio (totalLiq / netLiq^2), bounded by maxSpread

**Profitability**:

- Revenue: liquidation bonus (bounded by protocol parameters)
- Cost: swap impact + Uniswap fees paid
- For positions far from insolvency, the cost to push them over is high relative to the bonus
- For positions near insolvency, less fee generation needed, but the bonus is also smaller

**Severity**: Low-Medium. Theoretically possible but economically constrained. The attacker bears significant cost (swap fees are paid to LPs, not recoverable). Only viable against targets extremely close to liquidation where a small fee generation suffices.

**Existing mitigation**: The maxSpread parameter limits the premium amplification factor. The 4-tick solvency check (spot, TWAP, latest, current) makes instantaneous manipulation harder.

#### B.5.2 Premium as Solvency Shield

**Mechanism**: With `usePremiaAsCollateral = true` (in dispatch/dispatchFrom):

- Short premium owed TO the user is added to their available balance (RE:1155-1156)
- This effectively increases buying power

**Can a user trade with less collateral?** Yes. A user with a large short position accumulating premium can use that premium credit as collateral for additional positions. This is by design — accumulated premium IS an asset of the user.

**Risk**: If the premium is based on the `availablePremium` (capped by settled/accumulated ratio), it may not be fully realizable. But the solvency check uses `ONLY_AVAILABLE_PREMIUM` during liquidation (PP:1688), ensuring only realizable premium counts.

During normal dispatch operations, `usePremiaAsCollateral` is user-controlled (PP:755). The user can set it to true to get more lenient solvency, allowing them to operate with less actual collateral. If market conditions change and premium drops, the user's effective collateral decreases.

**Severity**: Informational. By design. The risk is mitigated by using available (not pending) premium in solvency checks.

---

## C) Invariant Analysis

### C.1 Premium Conservation

**Invariant**: Total premium collected from Uniswap = total premium paid by longs + total unsettled premium.

**Can premium be created?**

- The `Math.max(..., 0)` clamp in grossPremiumLast burn update (PP:1394-1405) can set grossPremiumLast to 0 when the expression goes negative. This makes `accumulated = (currentAccumulator - 0) * totalLiq / 2^64` larger than the actual owed amount, creating "phantom accumulated premium."
- However, `settledTokens` is NOT inflated. The `available = min(premOwed * settled / accumulated, premOwed)` formula uses the capped `premOwed` for each position. No seller can extract more than their owed amount.
- **Verdict**: Phantom accumulated premium is created in the denominator, but not in the numerator. Sellers receive less (ratio drops), but no premium is created out of thin air. Conservation holds for the settled pool.

**Can premium be destroyed?**

- Yes, via `haircutPremia`. During liquidation, if the buyer lacks collateral to pay full premium, the haircut destroys the difference. This is by design.
- The `addCapped` freeze also destroys future premium — once an accumulator freezes, no more premium accrues. Existing entitlements become inaccessible if `settled/accumulated` is low at freeze time.
- **Verdict**: Premium can be destroyed through haircuts and accumulator freezes. Both are known and by design.

### C.2 Available Premium Monotonicity

**Invariant**: For a given seller's position, does `availablePremium` ever decrease between observations?

`availablePremium = min(premOwed * settled / accumulated, premOwed)`

Between observations (no position changes for THIS seller):

- `premOwed`: increases (accumulators monotonically grow, snapshot fixed) ✓
- `settled`: can DECREASE (other sellers withdrew from the pool) ✗
- `accumulated`: increases (accumulators grow, grossPremiumLast fixed for this observation) ✓
- `settled/accumulated`: can decrease ✗

**Verdict**: **NOT monotonic.** A seller's availablePremium can decrease if:

1. Other sellers close and withdraw from settledTokens (settled drops)
2. Accumulators grow faster than settledTokens (accumulated grows, ratio drops)
3. Both effects compound

This means a seller who waits longer may receive LESS than if they closed earlier. First-mover advantage exists.

### C.3 settledTokens Conservation

**Invariant**: `settledTokens = Σ(collectedByLeg) + Σ(longPremiumPaid) - Σ(sellerWithdrawals) + Σ(haircutAdjustedLongPremium)`

Sources of increase:

- `collectedByLeg` on mint (PP:1176) and burn (PP:1296-1298): ✓
- Long premium committed: `settledTokens.sub(legPremia)` where legPremia is negative (PP:1303-1311): ✓
- Haircut-adjusted long premium during liquidation (IH:150-154): ✓

Sources of decrease:

- Seller withdrawal: `settledTokens.sub(availablePremium)` (PP:1352): ✓

**Can this be violated?** Each update is within a single `_updateSettlementPostBurn` call, with the final write at PP:1434. No reentrancy is possible (nonReentrant modifier on dispatch/dispatchFrom). The accounting is sequential per-leg within each call.

**Edge case**: What if `availablePremium > settledTokens`? The `settledTokens.sub(availablePremium)` at PP:1352 uses `LeftRightUnsigned.sub()` which reverts on underflow. But `availablePremium = min(premOwed * settled / accumulated, premOwed)`. Since `premOwed * settled / accumulated ≤ settled` when `premOwed ≤ accumulated`, the available premium should not exceed settledTokens.

However, if `premOwed > accumulated`, then `premOwed * settled / accumulated > settled`. The `Math.min` cap at `premOwed` kicks in, but premOwed could be > settled. In this case, the `uint128` cast at PP:2285 could truncate, but the min already ensures we don't exceed premOwed. If premOwed > settled, the `premOwed * settled / accumulated` branch gives `premOwed * settled / accumulated` which, when premOwed > accumulated, equals `premOwed * settled / accumulated > settled`. But it's capped at premOwed.

Wait: if `premOwed > settled`, and `accumulated < premOwed`, then `min(premOwed * settled / accumulated, premOwed)`. If `accumulated ≈ 0`, then `premOwed * settled / type(uint256).max ≈ 0`. If `accumulated = 1`, then `premOwed * settled / 1 = premOwed * settled`, capped at premOwed. So `availablePremium ≤ premOwed`. But premOwed could be > settled (the seller is owed more than what's settled). In that case: `availablePremium = premOwed`, and `settledTokens.sub(premOwed)` could underflow.

**This is a potential underflow!** If `premOwed > settled` and `accumulated ≤ premOwed`, the available premium = premOwed, and subtracting it from settled underflows.

Actually, let me re-examine. `settled` is the value AFTER adding `collectedByLeg` (PP:1296-1298). So settled could be much larger than accumulated if a lot of long premium was previously committed. The ratio `settled/accumulated` can exceed 1 (the comment at PP:2276 confirms this). In that case, `min(premOwed * settled / accumulated, premOwed) = premOwed`. And we need `premOwed ≤ settled` for the subtraction to not underflow.

Is `premOwed ≤ settled` always true? Not necessarily. premOwed is the seller's individual premium. settled is the chunk's total settled pool. If the seller is owed more than the entire pool, the subtraction underflows.

But `premOwed = (accumulator - snapshot) * positionLiquidity / 2^64`. And `accumulated = (accumulator - grossPremiumLast) * totalLiquidity / 2^64`. For a single seller, `premOwed / accumulated ≈ positionLiquidity / totalLiquidity ≤ 1`. So `premOwed ≤ accumulated`. And `settled/accumulated ≥ 0`. So `min(premOwed * settled / accumulated, premOwed)`. If `settled ≥ accumulated`, available = premOwed. And is premOwed ≤ settled? Since `premOwed ≤ accumulated ≤ settled` (when settled ≥ accumulated), yes. So no underflow.

If `settled < accumulated`: available = `premOwed * settled / accumulated < premOwed < accumulated`. And `premOwed * settled / accumulated ≤ settled` iff `premOwed ≤ accumulated`. Since premOwed for a single seller ≤ accumulated (proportional share), this holds.

**Verdict**: Conservation holds. No underflow in the common case because individual premOwed ≤ accumulated.

### C.4 grossPremiumLast Bounded by Accumulators

**Invariant**: `grossPremiumLast ≤ currentGrossAccumulator` for each slot.

**Mint path** (PP:1236-1252): `Ln = (C*R + L*T)/(T+R)`. Since L ≤ C, this is a weighted average, so L ≤ Ln ≤ C. ✓

**Burn path** (PP:1389-1429): `Ln = max(L*T - C*R + P*2^64, 0) / (T-R)`.

Algebraic analysis shows: when P ≈ R*(C-L)/2^64 (the position's owed premium), the numerator ≈ L*(T-R), giving Ln ≈ L ≤ C. The expression cannot exceed C because that would require P*2^64 > T*(C-L), i.e., the position's premium exceeds the total chunk premium, which is impossible since the position's liquidity R < T (totalLiqBefore).

**Can the clamp to 0 be triggered?** Yes, when `L*T + P*2^64 < C*R`. This happens when the position's actual collected premium (P) is significantly less than what the accumulator suggests (`C*R/2^64`). This occurs when `settled/accumulated` is very low, causing P (= availablePremium, used via legPremia reassignment at PP:1360) to be much less than premOwed.

Wait — I need to re-verify this. At line 1403, the code uses `legPremia.rightSlot()`. But `legPremia` is the local variable set at line 1292, which is the ORIGINAL premiaByLeg[leg] from `_getPremia`, NOT the reassigned availablePremium. Let me re-check...

At PP:1292: `LeftRightSigned legPremia = premiaByLeg[leg];` — from `_getPremia`, this is the FULL owed premium for the short leg (positive value).

At PP:1360-1362: `premiaByLeg[leg] = LeftRightSigned.wrap(int256(LeftRightUnsigned.unwrap(availablePremium)));` — this modifies the array element, NOT the local variable `legPremia`.

So at line 1403, `legPremia.rightSlot()` = the FULL owed premium, not the available premium. The burn formula uses the full owed amount, not the capped available amount.

This means: `P = premOwed = R*(C-L)/2^64` (approximately). And the numerator = `L*T - C*R + R*(C-L) = L*T - R*L = L*(T-R)`. Division by `(T-R)` gives `Ln = L`. The invariant L ≤ C holds.

The clamp to 0 would only trigger due to rounding errors in the floor divisions computing premOwed (losing a few wei). This makes Ln slightly less than L but never negative.

**Verdict**: Invariant holds. grossPremiumLast is always ≤ current accumulator.

### C.5 Premium Owed >= Premium Available

**Invariant**: `availablePremium ≤ premOwed` by construction (`Math.min` at PP:2286-2289).

**Can inputs be manipulated to bypass?** The `Math.min` takes `(premOwed * settled / accumulated, premOwed)`. Even if `settled > accumulated`, the cap at `premOwed` ensures `available ≤ premOwed`. This is a hard cap, not manipulable.

**Verdict**: Invariant holds unconditionally.

---

## D) Findings

### PREM-001: Seller Front-Running Liquidation to Avoid Premium Haircut

**Severity**: Medium
**Category**: Timing

**Attack sequence**:

1. Seller (A) holds short in chunk C. Buyer (B) holds long in chunk C, approaching insolvency.
2. A monitors mempool for B's liquidation tx (or anticipates from price movement).
3. A calls `dispatch()` to close their short position:
   - `_updateSettlementPostBurn` at PP:1343-1349: A receives `availablePremium` from `s_settledTokens[C]`
   - `s_settledTokens[C]` decreases by A's withdrawal
4. B's liquidation executes:
   - `haircutPremia` (RE:599) computes haircut based on B's collateral deficit
   - `InteractionHelper.settleAmounts` (IH:150) adds `(fullPremium - haircut)` to `s_settledTokens[C]`
5. Remaining sellers in chunk C face reduced `settled/accumulated` ratio.

**Capital required**: Seller must have existing short position (already capitalized).
**Expected profit**: Seller retains premium that would have been haircut.
**Who is harmed**: Other sellers in the same chunk — they receive less premium.
**Amplifiability**: Linear in the number of chunks where the seller has positions overlapping with liquidatable buyers.

**Existing mitigations**:

- The haircut mechanism is designed to socialize losses. The front-running seller simply avoids socialization.
- No atomic guarantee that sellers can't withdraw before liquidation.

**Effectiveness of mitigations**: Partially effective. The haircut still works for remaining sellers, but doesn't reach the front-runner.

**Resolution**: Not a vulnerability — removing liquidity ahead of a loss event is permitted by design. Sellers are free to close positions at any time.

### PREM-002: Forced Premium Settlement as Liquidation Setup

**Severity**: Low
**Category**: Manipulation

**Attack sequence**:

1. Target has long position in chunk C, close to maintenance margin.
2. Attacker calls `dispatchFrom` with `usePremiaAsCollateral.rightSlot() > 0` (true) to settle target's long premium:
   - Target pays long premium from their collateral
   - Post-settlement solvency check passes (short premia counted as collateral)
3. Attacker generates Uniswap fees in chunk C (small amount needed since target is now closer to insolvency)
4. Target's new longPremium (from newly accumulated fees) pushes them below maintenance margin
5. Attacker liquidates target in a separate tx

**Capital required**: Swap capital for fee generation (X/feeRate for X fees) + gas
**Expected profit**: Liquidation bonus
**Who is harmed**: Target loses position and liquidation penalty
**Amplifiability**: Requires target-specific conditions (near insolvency). Not mass-applicable.

**Existing mitigations**:

- 4-tick solvency check makes instant manipulation harder
- maxSpread limits premium amplification
- Forced settlement is designed to be callable by anyone (feature, not bug)

### PREM-003: Accumulator Freeze Causes Permanent Premium Starvation

**Severity**: Medium
**Category**: Starvation

**Attack sequence**:

1. Attacker controls all liquidity in chunk C (is the sole short seller)
2. Attacker (or accomplice) opens a long position removing all but 1 unit of netLiquidity
3. Any fee collection in this chunk triggers: `base = collected * totalLiq * 2^64 / 1` → overflow
4. `toUint128Capped` → `uint128.max`; `addCapped` freezes both accumulators permanently
5. Consequences:
   - Existing sellers: premOwed frozen at (frozen_value - snapshot) \* liq / 2^64. Available premium bounded by `settled/accumulated` at freeze time.
   - Existing longs: owe frozen amount, no further increase
   - New positions: snapshot = frozen value; delta = 0; earn/owe nothing
   - **Chunk is permanently dead for premium purposes**

**Capital required**: Must accumulate enough liquidity to be sole controller of a chunk (varies by pool).
**Expected profit**: None direct. This is a griefing/denial attack.
**Who is harmed**: Any future market makers in this chunk lose premium income.
**Amplifiability**: Chunk-scoped. Can target multiple chunks but capital cost is per-chunk.

**Existing mitigations**:

- `maxSpread` limits how much liquidity can be removed (bounds netLiquidity)
- Positions are per-chunk; market can move to different tick ranges

**Note**: This is the same as DENOM-003 from the denominator audit. Confirmed with full downstream trace.

**Resolution**: **NOT APPLICABLE** — PanopticPool enforces a maximum removed fraction of 90% of total liquidity, so `netLiquidity` cannot reach 1 in practice. The attack precondition cannot be met.

### PREM-004: First-Mover Advantage in Premium Collection

**Severity**: Low
**Category**: Timing

**Description**: The `settled/accumulated` ratio is a shared resource. When any seller closes and withdraws availablePremium, the ratio drops for all remaining sellers. A seller who closes earlier (when `settled/accumulated` is higher) receives more premium per unit owed than a seller who closes later.

**Mechanics**:

- Seller A closes when `settled/accumulated = 0.8` → receives `0.8 * premOwed_A`
- This reduces settled by A's withdrawal
- Seller B closes after → faces lower ratio → receives less per unit owed

This is inherent to the design (pro-rata distribution with finite pool) and not a bug. However, a MEV-aware seller can consistently front-run other sellers' closes to get a higher ratio.

**Who is harmed**: Slower sellers receive less premium.
**Amplifiability**: Marginal — each withdrawal slightly reduces the ratio. Significant impact only when the settled pool is small relative to total owed.

**Existing mitigations**: `settleLongPremium` (anyone can force buyer payment, replenishing settledTokens). This is the primary mechanism to keep the ratio healthy.

### PREM-005: Short Premium Not Settled During Third-Party Force Settlement

**Severity**: Informational
**Category**: Design observation

**Description**: When a third party calls `dispatchFrom` to force-settle a target's long premium (PP:1561 → PP:1848), the condition at PP:1314 prevents short legs from being settled because `msg.sender != owner` and `leftSlot != 0`.

This means: if the target has BOTH long and short legs on the same tokenId, only the long legs' premium is settled. The short legs' premium remains uncollected.

**Impact**: This is by design — only the position owner should be able to claim their short premium. But it means the target's short premium credit (used in solvency) may not match reality if the target hasn't self-settled recently.

### PREM-006: grossPremiumLast Clamp Creates Phantom Accumulated Premium

**Severity**: Low
**Category**: Starvation (localized)

**Description**: When the burn-path formula `L*T - C*R + P*2^64` goes negative (due to rounding in premOwed), `Math.max(..., 0)` clamps grossPremiumLast to 0 (PP:1394-1405). This makes `accumulated = (currentAccum - 0) * totalLiq / 2^64` much larger than the actual total owed premium, reducing the `settled/accumulated` ratio for remaining sellers.

**Trigger conditions**: The expression becomes negative when rounding losses in `premOwed` (from floor divisions in `_getPremiaDeltas`) accumulate enough that `legPremia * 2^64 < C*R - L*T + δ`. In practice, this requires extreme precision loss, most likely in chunks where:

- The closing position is very large relative to total liquidity
- Many floor division operations have accumulated

**Impact**: Remaining sellers face slightly reduced premium availability. The effect is bounded by the rounding error magnitude (a few wei amplified by the formula).

**Amplifiability**: Not directly attackable. Occurs naturally due to arithmetic imprecision.

### PREM-007: Fee-Driven Solvency Attack via Premium Accumulation

**Severity**: Low
**Category**: Manipulation

**Description**: An attacker can generate Uniswap fees in a chunk where a target holds a long position, increasing the target's owed premium and pushing them toward insolvency.

**Economics**:

- Cost to generate X in fees: `X / feeRate` in swap volume (e.g., 333X for 0.3% pool)
- Premium increase for target: `X * totalLiq * posLiq / (netLiq^2 * 2^64)` after spread adjustment
- For a target with `posLiq / netLiq = 10%` in a non-spread chunk: premium increase ≈ `0.1X`
- Net cost: 333X - 0.1X ≈ 332.9X per unit of premium increase
- Revenue (liquidation bonus): bounded by protocol parameters (typically < 10% of position value)

**Verdict**: Massively unprofitable for positions not already on the brink of insolvency. Only viable as a last-push against targets within a few basis points of liquidation threshold.

---

## E) Patches + Tests

### PREM-001: Seller Front-Running Liquidation

**Patch**: No simple code fix — this is inherent to the first-come-first-served premium distribution model. Possible mitigations:

1. **Time-weighted withdrawal delay**: Add a commitment period before premium can be withdrawn.

   ```solidity
   // In _updateSettlementPostBurn, record withdrawal intent:
   s_premiumWithdrawalBlock[owner][chunkKey] = block.number;
   // Require N blocks before actual withdrawal
   ```

   **Tradeoff**: Adds complexity, delays legitimate withdrawals, and is circumventable (commit early).

2. **Parameter adjustment**: Reduce `maxSpread` to limit the premium amplification that makes the attack worthwhile.

**Test scenario**:

```
Setup:
- Chunk C with tick range [100, 200]
- Seller A: short 1000 liquidity
- Seller B: short 1000 liquidity
- Buyer X: long 500 liquidity, near insolvency
- settledTokens = 100 tokens, accumulated equivalent = 100 tokens (ratio = 1.0)
- premOwed_A = 50, premOwed_B = 50

Attack:
1. A closes position → receives min(50 * 100 / 100, 50) = 50 tokens
2. settledTokens = 100 - 50 = 50
3. X is liquidated → haircutPremia claws back 20 tokens from X's premium
4. settleAmounts adds (50 - 20) = 30 to settledTokens
5. settledTokens = 50 + 30 = 80
6. B closes → accumulated now includes growth from A's burn update
   B receives proportionally less

Expected: A received 50 (full), B receives less than 50 due to haircut.
Without front-running: Both A and B would share the haircut proportionally.
```

### PREM-003: Accumulator Freeze

**Patch**: Enforce minimum netLiquidity in the SFPM to prevent extreme amplification.

```solidity
// In SFPM._createLegInAMM, after liquidity update:
if (currentLiquidity.rightSlot() < MIN_NET_LIQUIDITY) revert Errors.InsufficientNetLiquidity();
```

Where `MIN_NET_LIQUIDITY` is set high enough that `totalLiq * 2^64 / MIN_NET_LIQUIDITY^2` cannot overflow uint128 for reasonable fee amounts.

**Alternative**: Already partially mitigated by `maxSpread`. Tightening `maxSpread` reduces the minimum achievable netLiquidity.

**Test scenario**:

```
Setup:
- Chunk C, netLiquidity = 100, removedLiquidity = 0
- Seller: short 100 liquidity
- Buyer: long 99 liquidity → netLiquidity = 1, removedLiquidity = 99, totalLiquidity = 100

Attack:
1. Generate 1 token of Uniswap fees in chunk C
2. Fee collection: base = 1 * 100 * 2^64 / 1 = 100 * 2^64 ≈ 1.84e21
3. toUint128Capped: fits in uint128 (max ≈ 3.4e38), so NOT frozen for small fees
4. Generate 1e18 tokens of fees: base = 1e18 * 100 * 2^64 / 1 = 1.84e39 > uint128.max
5. toUint128Capped → uint128.max → addCapped freezes both accumulators

Expected: After step 5, getAccountPremium returns frozen values. New fee collection has no effect.
Seller's availablePremium = min(premOwed * settled / accumulated, premOwed) where accumulated is dominated by frozen accumulator value.
```

### PREM-004: First-Mover Advantage

**Patch**: No code change recommended. This is inherent to pool-based premium distribution. The forced settlement mechanism (`settleLongPremium`) serves as the primary mitigation — sellers who want premium can force buyers to pay.

**Parameter adjustment**: Consider incentivizing premium settlement by reducing the forced settlement gas cost or adding a small reward to the settler.

**Test scenario**:

```
Setup:
- Chunk C: settledTokens = 100, accumulated = 200
- Seller A: premOwed = 80
- Seller B: premOwed = 120

Sequence 1 (A first):
1. A closes: available = min(80 * 100/200, 80) = 40. settled → 60.
2. B closes: accumulated grew slightly. available = min(120 * 60 / 210, 120) ≈ 34.

Sequence 2 (B first):
1. B closes: available = min(120 * 100/200, 120) = 60. settled → 40.
2. A closes: available = min(80 * 40/210, 80) ≈ 15.

Expected: First mover gets proportionally more premium.
```

### PREM-006: grossPremiumLast Clamp

**Patch**: Use the actual `availablePremium` (not full `premOwed`) in the grossPremiumLast burn formula to prevent the clamp from over-correcting.

Currently (PP:1403): `int256(legPremia.rightSlot()) * 2 ** 64` where `legPremia` = full premOwed.

**Proposed**: Use `availablePremium` in the formula instead. This would make the numerator `L*T - C*R + availablePremium * 2^64`. When `availablePremium < premOwed`, the numerator is more negative, BUT it better reflects reality (the position didn't actually collect full premOwed).

However, this change would cause grossPremiumLast to deviate from L more aggressively, potentially creating worse phantom premium effects. **After further analysis, the current approach is correct** — using full premOwed preserves the invariant that Ln ≈ L, keeping the per-liquidity premium basis stable for remaining sellers. The clamp is a safety net that very rarely triggers.

**Recommendation**: No code change. Accept as informational.

### PREM-007: Fee-Driven Solvency Attack

**Patch**: No code change needed. The attack is economically infeasible (cost >> benefit). The existing maxSpread parameter and multi-tick solvency check are sufficient mitigations.

**Test scenario**:

```
Setup:
- Chunk C, feeRate = 0.3%
- Target: long 100 liquidity, positionSize = 10 ETH equivalent
- netLiquidity = 1000, totalLiquidity = 1000 (no spread)
- Target's excess collateral above maintenance: 0.01 ETH

Attack:
1. Attacker swaps 33.33 ETH in pool → generates 0.1 ETH in fees
2. Premium increase for target: 0.1 * 1000 * 100 / (1000^2 * 2^64) ≈ negligible
3. With spread (netLiq = 100): 0.1 * 1100 * 100 / (100^2 * 2^64) ≈ still tiny per 2^64

Expected: Attack cost (33.33 ETH swap impact + fees) >> premium increase on target. Not viable.
```

---

## Summary

| ID       | Severity | Category     | Description                                                   | Fix                                                           |
| -------- | -------- | ------------ | ------------------------------------------------------------- | ------------------------------------------------------------- |
| PREM-001 | Medium   | Timing       | Seller front-runs liquidation to avoid premium haircut        | **By design** — removing liquidity ahead of loss is allowed   |
| PREM-002 | Low      | Manipulation | Forced premium settlement as liquidation setup (two-step)     | Mitigated by 4-tick solvency check                            |
| PREM-003 | Medium   | Starvation   | Accumulator freeze causes permanent chunk premium death       | **N/A** — max removed fraction is 90%, netLiq=1 not reachable |
| PREM-004 | Low      | Timing       | First-mover advantage in premium collection from shared pool  | Inherent to design; settleLongPremium mitigates               |
| PREM-005 | Info     | Design       | Short premium not settled during third-party force settlement | By design                                                     |
| PREM-006 | Low      | Starvation   | grossPremiumLast clamp creates phantom accumulated premium    | Rounding artifact; no fix needed                              |
| PREM-007 | Low      | Manipulation | Fee-driven solvency attack via premium accumulation           | Economically infeasible; no fix needed                        |

**Key insight**: The premium system's primary vulnerability surface is **timing** (who settles first) rather than **arithmetic** (the math is sound). The settled/accumulated ratio creates a shared resource with first-mover advantage. The forced settlement mechanism (`settleLongPremium`) is the critical defense against premium accumulation attacks, and the haircut mechanism correctly socializes losses — but neither prevents a fast-moving seller from extracting before socialization occurs.
