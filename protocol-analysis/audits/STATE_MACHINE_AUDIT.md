# State Machine & Access Control Audit Report

**Scope:** All files under `contracts/` (36 Solidity files)
**Date:** 2026-02-21
**Auditor Model:** Claude Opus 4.6

---

## A) State Machine Map

### A1. Position Lifecycle

**States:**

- `NONEXISTENT`: `PositionBalance.unwrap(s_positionBalance[user][tokenId]) == 0`
- `ACTIVE`: `s_positionBalance[user][tokenId].positionSize() > 0`

**Transitions:**

#### T1: NONEXISTENT -> ACTIVE (Mint)

**Entry:** `dispatch()` when `positionBalanceData == 0` (PP:684)

Execution order within `_mintOptions` (PP:772-825):

1. **SFPM.mintTokenizedPosition** (PP:783) — external call, creates liquidity in AMM
2. **\_updateSettlementPostMint** (PP:791) — adds tokenId to positionsHash (PP:1156), updates `s_settledTokens`, `s_grossPremiumLast`, writes `s_options[owner][tokenId][leg]` snapshots
3. **\_payCommissionAndWriteData** (PP:802) — calls CT.settleMint for CT0/CT1, charges commission
4. **s_positionBalance[owner][tokenId] = balanceData** (PP:821) — LAST

**Atomicity:** If any step reverts, the entire `dispatch()` tx reverts. No partial state possible.

**Critical Q: Can positionsHash be updated but SFPM mint fail?**
Answer: No. SFPM mint (step 1) executes BEFORE hash update (step 2). Revert at step 1 rolls back everything.

#### T2: ACTIVE -> NONEXISTENT (Burn)

**Entry:** `dispatch()` when `positionBalanceData != 0 && positionSize != positionSizes[i]` (PP:705)

Execution order within `_burnOptions` (PP:963-1029):

1. **SFPM.burnTokenizedPosition** (PP:980) — external call, removes liquidity from AMM
2. **\_updateSettlementPostBurn** (PP:989) — with `commitLongSettledAndKeepOpen = (rightSlot=1, leftSlot=0)`:
   - Updates `s_settledTokens` for each leg (PP:1432)
   - Clears `s_options[owner][tokenId][leg]` (PP:1436)
   - Clears `s_positionBalance[owner][tokenId]` (PP:1457)
   - Removes from positionsHash (PP:1461)
3. **CT.settleBurn** for CT0/CT1 (PP:1005-1028) — settles collateral

**Atomicity:** Full. PP state (step 2) and CT state (step 3) are updated in the same tx. Revert at any point rolls back all changes including the SFPM burn.

**Critical Q: Can a position be burned in SFPM but NOT removed from s_positionBalance?**
Answer: No. SFPM burn (step 1) completes before PP state update (step 2). If step 2 or 3 reverts, SFPM burn is also reverted (all in one tx, no try/catch).

**Critical Q: s_positionBalance is cleared BEFORE or AFTER CT.settleBurn?**
Answer: BEFORE. s_positionBalance is cleared at PP:1457 (inside \_updateSettlementPostBurn at step 2), then CT.settleBurn is called at step 3. If CT.settleBurn reverts, the entire tx reverts, so the clear is also reverted. No inconsistency.

#### T3: ACTIVE -> ACTIVE (Settle Premium — Self)

**Entry:** `dispatch()` when `positionSize == positionSizes[i]` (PP:702)

Calls `_settleOptions` (PP:1113-1137):

- `_updateSettlementPostBurn` with `commitLongSettledAndKeepOpen = (rightSlot=1, leftSlot=1+(currentTick<<2))`
- Long legs: premium committed to `s_settledTokens` (PP:1300-1309)
- Short legs: premium auto-collected since `msg.sender == owner` (PP:1312)
- `s_options` updated to latest accumulators (PP:1440-1443)
- `s_positionBalance` NOT cleared (PP:1455: leftSlot != 0)
- positionsHash NOT updated

Then calls `CT.settleBurn` with `longAmount=0, shortAmount=0, ammDelta=0, realizedPremium` (PP:1135-1136).

#### T4: ACTIVE -> ACTIVE (Settle Premium — Third-Party)

**Entry:** `dispatchFrom()` when `solvent == numberOfTicks && toLength == finalLength` (PP:1542)

Calls `_settlePremium` (PP:1842-1865):

1. **delegate(owner, CT0), delegate(owner, CT1)** (PP:1849-1850)
2. **\_settleOptions** (PP:1856) — same as T3, but `msg.sender != owner`:
   - Long legs: premium committed (same as T3)
   - Short legs: NOT auto-collected (PP:1312: `msg.sender != owner` and leftSlot != 0 → condition fails)
   - Short leg `s_options` NOT updated (PP:1439: `tokenId.isLong(leg) != 0` fails, `msg.sender == owner` fails)
3. **\_getRefundAmounts** → **\_refund** (PP:1858-1861)
4. **revoke(owner, CT0), revoke(owner, CT1)** (PP:1863-1864)

**Finding: Third-party settle does NOT update short-leg s_options accumulators.** This is by design — only the owner or a burn path should collect short premium.

#### T5: ACTIVE -> NONEXISTENT (Force Exercise)

**Entry:** `dispatchFrom()` when `solvent == numberOfTicks && toLength == finalLength+1` (PP:1556)

Calls `_forceExercise` (PP:1778-1835):

1. **delegate(account, CT0), delegate(account, CT1)** (PP:1805-1806)
2. **\_burnOptions** with `COMMIT_LONG_SETTLED` (PP:1815-1822) — full burn, clears all PP state
3. **\_getRefundAmounts** (PP:1825)
4. **\_refund(account, ...)** for CT0/CT1 (PP:1828-1829)
5. **\_revoke(account, CT0), \_revoke(account, CT1)** (PP:1831-1832)

Delegate/revoke pairing: 2 delegates (step 1) → 2 revokes (step 5). **Matched 1:1.**

**Critical Q: Can \_refund revert and leave virtual shares orphaned?**
Answer: If \_refund reverts, the entire dispatchFrom tx reverts, including the delegate. No orphaned shares. The exercisee's virtual-share-augmented balance (initial + 2^248-1 - burned_in_step_2) is always large enough to cover any reasonable refund because 2^248-1 >> any real burned amount.

#### T6: ACTIVE -> NONEXISTENT (Liquidation)

**Entry:** `dispatchFrom()` when `solvent == 0` (PP:1578)

Calls `_liquidate` (PP:1661-1772) — strict execution order:

| Step | Operation                                 | Line    | State Changes                                                 |
| ---- | ----------------------------------------- | ------- | ------------------------------------------------------------- |
| 1    | `_calculateAccumulatedPremia`             | PP:1678 | None (view-like in context)                                   |
| 2    | `riskEngine().getMargin`                  | PP:1685 | None (view)                                                   |
| 3    | `_delegate(liquidatee, CT0)`              | PP:1698 | `balanceOf[liquidatee] += 2^248-1` on CT0                     |
| 4    | `_delegate(liquidatee, CT1)`              | PP:1699 | `balanceOf[liquidatee] += 2^248-1` on CT1                     |
| 5    | `_burnAllOptionsFrom`                     | PP:1710 | For each position: SFPM burn → PP state clear → CT.settleBurn |
| 6    | `riskEngine().getLiquidationBonus`        | PP:1721 | None (pure)                                                   |
| 7    | `riskEngine().haircutPremia`              | PP:1742 | None (pure)                                                   |
| 8    | `bonusAmounts.add(bonusDeltas)`           | PP:1749 | Local variable                                                |
| 9    | `InteractionHelper.settleAmounts`         | PP:1751 | Updates `s_settledTokens`, calls CT.settleBurn for haircut    |
| 10   | `CT0.settleLiquidation{value: msg.value}` | PP:1765 | Implicit revoke on CT0, transfers bonus                       |
| 11   | `CT1.settleLiquidation`                   | PP:1770 | Implicit revoke on CT1, transfers bonus                       |

Delegate/revoke pairing: 2 delegates (steps 3-4) → 2 implicit revokes in settleLiquidation (steps 10-11). **Matched 1:1.**

**Critical Q: Interest accrual during liquidation?**
`_accrueInterests()` (PP:1605) is defined but **NEVER CALLED** from `_liquidate` or anywhere else — it is dead code. Interest is accrued per-user during each `CT.settleBurn` call (via `_updateBalancesAndSettle` → `_accrueInterest` at CT:1410). The first such call also updates the global interest state (`s_marketState`). This means the solvency check at PP:1515 uses the stale (pre-accrual) borrow index. Since interest only increases borrower debt, stale state makes insolvent users appear MORE solvent, potentially delaying liquidation by one epoch (4 seconds). See **STATE-001**.

**Critical Q: Path-dependent liquidation?**
Yes. Positions in `positionIdList` are burned sequentially (PP:928 loop). Each burn modifies `s_settledTokens` and `s_grossPremiumLast`, affecting premium computations for subsequent burns. The liquidator controls the ordering of `positionIdList`. While total `netPaid` is order-independent, the per-leg `premiasByLeg` values differ, which affects `haircutPremia` distribution. See **STATE-002**.

**Critical Q: Can CT0.settleLiquidation succeed while CT1.settleLiquidation reverts?**
No. Both are called sequentially in the same tx (PP:1765-1770). If CT1 reverts, the entire `_liquidate` tx reverts, including CT0's settlement. Atomicity maintained.

**Critical Q: What if msg.value is insufficient/excessive?**

- **Excessive, bonus >= 0:** CT:1354 refunds: `SafeTransferLib.safeTransferETH(liquidator, msg.value)`
- **Excessive, bonus < 0, V3:** ETH sent to CT0 is NOT refunded. CT0 receives ETH via `payable` but only uses `safeTransferFrom` for ERC20. The ETH is stuck. However, V3 pools use ERC20 tokens (not native ETH), so `msg.value` should always be 0. No practical impact. See **STATE-003**.
- **Insufficient, bonus < 0, V4:** `poolManager().settle{value: uint256(delta)}()` at CT:460 would revert if insufficient.

---

### A2. Delegate/Revoke Lifecycle

**Complete inventory of delegate/revoke call sites:**

| Path             | Delegate calls               | Revoke/Absorption calls                                      | Pairing             |
| ---------------- | ---------------------------- | ------------------------------------------------------------ | ------------------- |
| `_forceExercise` | PP:1805 (CT0), PP:1806 (CT1) | PP:1831 (CT0), PP:1832 (CT1)                                 | 2:2 explicit revoke |
| `_liquidate`     | PP:1698 (CT0), PP:1699 (CT1) | PP:1765 CT0.settleLiquidation, PP:1770 CT1.settleLiquidation | 2:2 implicit revoke |
| `_settlePremium` | PP:1849 (CT0), PP:1850 (CT1) | PP:1863 (CT0), PP:1864 (CT1)                                 | 2:2 explicit revoke |

**All paths are 1:1 matched.** No orphaned delegates are possible because:

1. All paths are within a single `nonReentrant` function (`dispatchFrom`)
2. If any operation between delegate and revoke reverts, the entire tx reverts
3. No `try/catch` blocks wrap any intermediate operation

**Critical Q: Can delegate() overflow balanceOf?**
`delegate()` adds `type(uint248).max` (= 2^248-1) to `balanceOf[delegatee]` using checked arithmetic (CT:1229). For overflow: `balanceOf + 2^248-1 > 2^256-1` requires `balanceOf > 2^256 - 2^248 = 255 * 2^248`. Since `_internalSupply` starts at 10^6 and grows only via `_mint` and protocol loss absorption, reaching 255 \* 2^248 is physically impossible. **Safe.**

**Critical Q: Can double-delegation occur?**
Only if delegate() is called twice on the same account without an intervening revoke. This requires two concurrent `dispatchFrom` executions targeting the same account. The `nonReentrant` modifier on PP prevents this within one PP. Different PPs have SEPARATE CTs (each PP is cloned with its own CT0/CT1 addresses), so cross-pool double-delegation on the same CT is **impossible by construction**.

**Critical Q: Can balance change between delegate and settleLiquidation?**
Yes. Between `_delegate` (PP:1698-1699) and `settleLiquidation` (PP:1765-1770), the burns in `_burnAllOptionsFrom` (PP:1710) modify the liquidatee's CT balance via `CT.settleBurn`. After burns, `balanceOf[liquidatee] = initial + 2^248-1 - shares_consumed_by_burns`. In `settleLiquidation`:

- If `balanceOf >= 2^248-1` → simple subtraction (CT:1312)
- If `balanceOf < 2^248-1` → shortfall path, protocol absorbs loss (CT:1301-1308)

This is the intended protocol-loss mechanism. **Correctly handled.**

---

### A3. Premium Settlement State Machine

Four distinct paths through `_updateSettlementPostBurn` (PP:1268):

| Path                  | rightSlot | leftSlot | Long legs                  | Short legs                         | Clears position? |
| --------------------- | --------- | -------- | -------------------------- | ---------------------------------- | ---------------- |
| 1. Self-burn          | 1         | 0        | Committed to settledTokens | Auto-collected                     | Yes              |
| 2. Self-settle        | 1         | !=0      | Committed to settledTokens | Auto-collected (msg.sender==owner) | No               |
| 3. Third-party settle | 1         | !=0      | Committed to settledTokens | NOT collected                      | No               |
| 4. Liquidation burn   | 0         | 0        | NOT committed              | Auto-collected (leftSlot==0)       | Yes              |

**Path 4 deep-dive (liquidation):**
Long premium is computed but NOT stored in `s_settledTokens` (PP:1300: `rightSlot == 0` → condition fails). However, `realizedPremia` IS accumulated (PP:1310) and passed to `CT.settleBurn`. The actual commitment to `s_settledTokens` happens later in `InteractionHelper.settleAmounts` (IH:157), after `haircutPremia` adjusts for protocol loss. This two-phase approach prevents short sellers from being paid with tokens that will later be clawed back during haircut.

**Critical Q: Can the same leg be settled twice?**
After settle (path 2): `s_options[owner][tokenId][leg]` is updated to current accumulators (PP:1440-1443). After a subsequent burn (path 1): premium delta = `currentAccumulator - s_options[leg]` (PP:2220-2222). Since s_options was just updated by settle, the delta is near-zero (only premium accumulated in the same block between settle and burn). **No double-counting.**

**Critical Q: Can Bob front-run Alice's self-settle?**
Bob calls `dispatchFrom(_settlePremium)` for Alice's position. This settles Alice's LONG legs and updates their accumulators. When Alice subsequently self-settles, her long leg premium is near-zero (already paid), but her SHORT leg premium is fully intact (Bob's settle didn't touch short-leg s_options at PP:1439). Net effect on Alice: same total payment, just split across two transactions. **No economic impact.**

**Critical Q: Is currentTick manipulable between observation and settlement?**
The tick used for premium computation in settle path 2 is `int24(commitLongSettledAndKeepOpen.leftSlot() >> 2)`, which is constructed at PP:1131 as `1 + (int128(currentTick) << 2)` where currentTick is read from `getCurrentTick()` at PP:703 inside `dispatch()`. This is the caller's observed tick at the time of calling `dispatch`. It cannot be manipulated after the call begins because it's read from Uniswap's slot0 within the same transaction. For third-party settle via `dispatchFrom`, the tick is read at PP:1494 (`getCurrentTick()`). **Safe within a single tx.**

---

### A4. Liquidation State Machine

(Fully mapped in T6 above.)

**Critical Q: Can a liquidator sandwich their own liquidation?**
Yes — a liquidator can manipulate the Uniswap pool price before calling `dispatchFrom`:

1. Swap to move price → user becomes insolvent at all ticks
2. Liquidate → collect bonus
3. Reverse swap

Mitigations:

- `dispatchFrom` checks `Math.abs(currentTick - twapTick) > MAX_TWAP_DELTA_DISPATCH` (PP:1537), which limits the deviation between current and TWAP price
- TWAP (weighted EMA blend) is resistant to single-block manipulation
- The liquidation bonus is computed at `twapTick` (PP:1724), not `currentTick`
- However, `netPaid` (from burns) is settled at the CURRENT AMM price, which IS manipulable

**Residual risk:** The liquidator can manipulate the burn settlement amounts (via ITM swap at manipulated price) but the bonus is capped by the TWAP-based computation. The net gain is bounded. **Low severity.**

---

## B) Access Control Matrix

### PanopticPool.sol

| Function                               | Line | Visibility | Modifiers                    | Who Can Call    | State-Changing |
| -------------------------------------- | ---- | ---------- | ---------------------------- | --------------- | -------------- |
| `initialize()`                         | 327  | external   | none                         | Anyone (once)   | Yes            |
| `onERC1155Received()`                  | 382  | external   | pure                         | Anyone          | No             |
| `assertMinCollateralValues()`          | 400  | external   | view                         | Anyone          | No             |
| `getAssetsOf()`                        | 410  | public     | view                         | Anyone          | No             |
| `getChunkData()`                       | 425  | external   | view                         | Anyone          | No             |
| `validateCollateralWithdrawable()`     | 460  | external   | view, ensureNonReentrantView | Anyone          | No             |
| `getAccumulatedFeesAndPositionsData()` | 482  | external   | view                         | Anyone          | No             |
| `pokeOracle()`                         | 605  | external   | nonReentrant                 | Anyone          | Yes            |
| `dispatch()`                           | 625  | external   | nonReentrant                 | Anyone          | Yes            |
| `dispatchFrom()`                       | 1485 | external   | payable, nonReentrant        | Anyone          | Yes            |
| `lockSafeMode()`                       | 306  | external   | onlyRiskEngine               | RiskEngine only | Yes            |
| `unlockSafeMode()`                     | 311  | external   | onlyRiskEngine               | RiskEngine only | Yes            |
| `getRiskParameters()`                  | 1973 | public     | view                         | Anyone          | No             |
| `isSafeMode()`                         | 1982 | external   | view                         | Anyone          | No             |
| `getOracleTicks()`                     | 2064 | external   | view                         | Anyone          | No             |
| `numberOfLegs()`                       | 2097 | external   | view, ensureNonReentrantView | Anyone          | No             |
| `positionData()`                       | 2111 | external   | view                         | Anyone          | No             |
| `getTWAP()`                            | 2120 | public     | view                         | Anyone          | No             |
| `getCurrentTick()`                     | 2125 | public     | view                         | Anyone          | No             |

### CollateralTracker.sol

| Function                      | Line | Visibility | Modifiers                               | Who Can Call            | State-Changing |
| ----------------------------- | ---- | ---------- | --------------------------------------- | ----------------------- | -------------- |
| `initialize()`                | 285  | external   | none                                    | Anyone (once)           | Yes            |
| `transfer()`                  | 399  | public     | nonReentrant                            | Anyone (position check) | Yes            |
| `transferFrom()`              | 418  | public     | nonReentrant                            | Anyone (position check) | Yes            |
| `unlockCallback()`            | 449  | external   | none                                    | poolManager() only      | Yes            |
| `deposit()`                   | 557  | external   | payable, nonReentrant                   | Anyone                  | Yes            |
| `mint()`                      | 615  | external   | payable, nonReentrant                   | Anyone                  | Yes            |
| `withdraw()` (standard)       | 708  | external   | nonReentrant                            | Anyone (position check) | Yes            |
| `withdraw()` (with positions) | 762  | external   | nonReentrant                            | Anyone (solvency check) | Yes            |
| `redeem()`                    | 841  | external   | nonReentrant                            | Anyone (position check) | Yes            |
| `accrueInterest()`            | 888  | external   | nonReentrant                            | Anyone                  | Yes            |
| `delegate()`                  | 1228 | external   | onlyPanopticPool, nonReentrant          | PanopticPool only       | Yes            |
| `revoke()`                    | 1236 | external   | onlyPanopticPool, nonReentrant          | PanopticPool only       | Yes            |
| `settleLiquidation()`         | 1247 | external   | payable, onlyPanopticPool, nonReentrant | PanopticPool only       | Yes            |
| `refund()`                    | 1373 | external   | onlyPanopticPool, nonReentrant          | PanopticPool only       | Yes            |
| `settleMint()`                | 1538 | external   | onlyPanopticPool, nonReentrant          | PanopticPool only       | Yes            |
| `settleBurn()`                | 1616 | external   | onlyPanopticPool, nonReentrant          | PanopticPool only       | Yes            |

### SemiFungiblePositionManager.sol

| Function                    | Line | Visibility | Modifiers    | Who Can Call           | State-Changing |
| --------------------------- | ---- | ---------- | ------------ | ---------------------- | -------------- |
| `initializeAMMPool()`       | 347  | external   | none         | Anyone (once per pool) | Yes            |
| `expandEnforcedTickRange()` | ~430 | external   | none         | Anyone                 | Yes            |
| `uniswapV3MintCallback()`   | 528  | external   | none         | Validated Uniswap pool | Yes            |
| `uniswapV3SwapCallback()`   | 561  | external   | none         | Validated Uniswap pool | Yes            |
| `burnTokenizedPosition()`   | 599  | external   | nonReentrant | Token holder only      | Yes            |
| `mintTokenizedPosition()`   | 639  | external   | nonReentrant | Anyone                 | Yes            |
| `safeTransferFrom()`        | 678  | public     | pure         | ALWAYS REVERTS         | No             |
| `safeBatchTransferFrom()`   | 689  | public     | pure         | ALWAYS REVERTS         | No             |

### RiskEngine.sol

| Function                | Line | Visibility | Modifiers    | Who Can Call  | State-Changing |
| ----------------------- | ---- | ---------- | ------------ | ------------- | -------------- |
| `lockPool()`            | 232  | external   | onlyGuardian | Guardian only | Yes (via PP)   |
| `unlockPool()`          | 240  | external   | onlyGuardian | Guardian only | Yes (via PP)   |
| `collect()`             | 275  | public     | onlyGuardian | Guardian only | Yes (transfer) |
| `collect()`             | 286  | external   | onlyGuardian | Guardian only | Yes (transfer) |
| `getLiquidationBonus()` | 502  | external   | pure         | Anyone        | No             |
| `haircutPremia()`       | 599  | external   | pure         | Anyone        | No             |
| `isAccountSolvent()`    | 977  | external   | view         | Anyone        | No             |
| `getSolvencyTicks()`    | 926  | external   | view         | Anyone        | No             |
| `getMargin()`           | 1053 | external   | view         | Anyone        | No             |

### Multicall Analysis

**All three core contracts** (PP, CT, SFPM) inherit `Multicall`, which uses `delegatecall` to batch sub-calls.

**Critical finding: TransientReentrancyGuard correctly resets between multicall sub-calls.**
Each `nonReentrant` function calls `_nonReentrantSet()` (sets guard) and `_nonReentrantReset()` (clears guard). Between multicall delegatecalls, the guard is cleared by the first function's `_nonReentrantReset()`, allowing the second function's `_nonReentrantSet()` to succeed. Sequential nonReentrant calls within multicall are **permitted by design**.

**Critical finding: ensureNonReentrantView prevents read-only reentrancy.**
`PP.numberOfLegs()` (PP:2097) and `PP.validateCollateralWithdrawable()` (PP:464) use `ensureNonReentrantView`, which reverts if PP's transient guard is set. This prevents external contracts (called during a PP state-changing operation) from reading PP's inconsistent intermediate state.

**Critical finding: Cross-contract guard isolation.**
PP's and CT's transient storage guards are on DIFFERENT contracts (different addresses → different transient storage). PP calling CT.delegate (which is nonReentrant on CT) does not conflict with PP's own guard. **No cross-contract guard interference.**

### ERC20 Transfer Restriction

CT's `transfer()` (CT:399) and `transferFrom()` (CT:418) call `PP.numberOfLegs(msg.sender/from)` and revert if the account has ANY open legs. This prevents collateral extraction while positions are open.

**Bypass analysis:** The only way to bypass is if `numberOfLegs` returns 0 while the user actually has positions. `numberOfLegs` reads from `s_positionsHash[user] >> 248` (PP:2098). This is updated atomically with position mint/burn. No intermediate state where legs exist but hash shows 0 (ensureNonReentrantView prevents reading during state transitions).

### Callback Validation

SFPM callbacks (`uniswapV3MintCallback`, `uniswapV3SwapCallback`) validate `msg.sender` via `CallbackLib.validateCallback(msg.sender, FACTORY, decoded.poolFeatures)`. This deterministically computes the expected pool address from the factory and pool parameters. A malicious contract can only pass validation if deployed at the exact CREATE2 address of a legitimate Uniswap pool. **Infeasible without factory compromise (out of scope).**

### Guardian Power Assessment

The guardian (immutable address set in RiskEngine constructor) can:

1. **lockPool/unlockPool** — Toggle safe mode (prevents new mints at level >2, increases collateral requirements)
2. **collect** — Withdraw ANY ERC20 tokens from RiskEngine (accumulated protocol fees)

**Maximum damage from compromised guardian:**

- Deny new position creation (lock all pools)
- Drain accumulated commission fees from RiskEngine
- **CANNOT** access user deposits (in CTs), modify risk parameters (immutable), manipulate oracle, or steal positions

**Severity: Low.** Griefing only, no direct fund loss. Users can still close positions and withdraw.

---

## C) Invariant Analysis

### C1. Position Hash Integrity

**Invariant:** `s_positionsHash[user]` equals the LtHash of all active tokenIds, with upper 8 bits = total leg count.

**LtHash properties:** k=2 lanes, 124-bit primes (PRIME_0 = 2^124-59, PRIME_1 = 2^124-615).

**Collision probability:** For n=6 positions (max ~26 legs): ~n²/2^124 per lane ≈ 2×10^-36. Both lanes: ~4×10^-72. **Cryptographically infeasible.**

**Remove without add:** `_updatePositionsHash(account, tokenId, !ADD, maxLegs)` is only called at PP:1461 inside `_updateSettlementPostBurn` when `commitLongSettledAndKeepOpen.leftSlot() == 0` (full burn path). This path is only reached for positions that were previously minted (which called `_updatePositionsHash(account, tokenId, ADD, maxLegs)` at PP:1156). **Guaranteed matching add/remove.**

**Edge case: item hashes to 0 in one lane.** If `keccak256(tokenId) % PRIME == 0` for one lane, the add operation is a no-op for that lane, and remove would also be a no-op. This maintains consistency but makes that particular tokenId "invisible" in one lane. The other lane still provides collision resistance. Probability: 1/PRIME ≈ 2^-124. **Negligible risk.**

### C2. Share Supply Conservation

**Invariant:** `totalSupply() = _internalSupply + s_creditedShares` (CT:513)

**\_internalSupply modifications:**

- Initialize: `10^6` (CT:292)
- `+= shortfall` in `settleLiquidation` (CT:1289, CT:1307) — only grows

**Type:** `_internalSupply` is `uint256` (declared in ERC20Minimal:32). Growth via `_mint` is checked (ERC20Minimal:130: `_internalSupply += amount`). Growth via protocol loss at CT:1289/1307 is `unchecked`. Can this overflow?

- Maximum single shortfall: `type(uint248).max` ≈ 4.5×10^74
- Starting value: 10^6
- After N liquidations with maximum shortfall: N × 4.5×10^74
- To overflow uint256 (≈1.16×10^77): need ~258 maximum-shortfall liquidations

**Practically infeasible** but theoretically possible over an extremely long protocol lifetime with many devastating liquidations. **Informational.**

**s_creditedShares modifications:**

- `+= creditDelta` on long mint (CT:1473) — unchecked, reverts on overflow via checked context
- `-= creditDelta` on long burn (CT:1466) — checked
- `= 0` when underflow (CT:1447) — option owner pays haircut

**Critical Q: Is s_creditedShares properly decremented during liquidation?**
Yes. Each position burn calls `CT.settleBurn` → `_updateBalancesAndSettle(isCreation=false)` → creditDelta computed and subtracted from `s_creditedShares` (CT:1437-1467). **Correct.**

**Critical Q: Can totalAssets/totalSupply diverge to zero or infinity?**

- `totalAssets = s_depositedAssets + s_assetsInAMM + unrealizedInterest` (CT:505). After initialization: `1 + 0 + 0 = 1`. Always >= 1 since `s_depositedAssets` starts at 1 and `maxWithdraw` reserves 1 (CT:662).
- `totalSupply = _internalSupply + s_creditedShares` (CT:513). After initialization: `10^6 + 0 = 10^6`. `_internalSupply` never decreases. `s_creditedShares` can go to 0 but `_internalSupply >= 10^6` always.
- Share price = assets/supply. Minimum = 1/10^6 = 10^-6 per share. **Cannot reach zero or infinity.**

### C3. s_settledTokens Conservation

**Invariant:** `s_settledTokens[chunkKey]` tracks tokens available for seller premium withdrawal.

**Increases:**

- Uniswap fee collection added at PP:1174, PP:1294 (via `collectedByLeg`)
- Long premium committed at PP:1301-1308 (paths 1-3)
- Haircut-adjusted long premium committed at IH:157 (liquidation path 4)

**Decreases:**

- Seller premium withdrawn at PP:1350 (`settledTokens.sub(availablePremium)`)

**Critical Q: Can settledTokens go negative?**
`settledTokens` is `LeftRightUnsigned`. The `.sub()` at PP:1350 uses the overflow-checked `LeftRightUnsigned.sub()` (LeftRight.sol:173-190) which reverts on underflow. `availablePremium` is computed via `_getAvailablePremium` (PP:2260) which caps at `premiumOwed` via `Math.min` (PP:2280-2283, 2289-2292). The ratio `settledTokens/accumulated` is at most 1 (capped). So `availablePremium <= premiumOwed <= settledTokens` in normal conditions. **Cannot underflow in normal operation.**

However, during liquidation (path 4), the long premium subtraction at PP:1301-1308 uses a `LeftRightSigned.sub(legPremia)` which converts to unsigned. If `legPremia > settledTokens` for a slot, this would wrap. But `legPremia` for long legs is negative (representing premium owed by longs), so `LeftRightSigned.wrap(0).sub(legPremia)` is positive (the amount to ADD). Wait — re-reading PP:1304-1306: the settledTokens are DECREASED by legPremia (`.sub(legPremia)`). Since legPremia for longs is negative, subtracting a negative = adding. So settledTokens INCREASES. **Correct.**

### C4. Delegate/Revoke Balance Consistency

**Invariant:** Every delegate has exactly one matching revoke or protocol-loss absorption.

Fully verified in A2 above. All three paths (forceExercise, liquidation, settlePremium) have matched 1:1 delegate/revoke pairs. Atomicity guaranteed by single-tx execution with no try/catch.

### C5. Interest Accrual Consistency

**Invariant:** `s_marketState.unrealizedInterest()` approximates the sum of all users' outstanding interest.

**Rounding drift:** Multiplicative borrow index growth causes individual interest computations to diverge from the additive global tracker. Handled by clamping at CT:962-963 (`burntInterestValue > _unrealizedGlobalInterest` → set to 0).

**Insolvency case:** When shares > userBalance (CT:933), user pays partial interest. Borrow index NOT updated (CT:950). Global tracker reduced only by partial payment. The unpaid portion remains as phantom debt that compounds on next interaction. This causes `_unrealizedGlobalInterest` to be slightly lower than the true sum of debts. Downstream effect: remaining users' interest settlement causes clamping to 0 slightly early. **Net: tiny protocol loss, properly mitigated by clamping.**

**skipInterest case:** During deposits/mints (CT:926-932), interest is not settled (`burntInterestValue = 0`, user index preserved). Global tracker unchanged. The user's interest is deferred to next interaction. **Correct — user's debt continues compounding.**

---

## D) Ordering & Frontrunning Analysis

### D1. Liquidation Frontrunning

| Attack                                           | Feasibility            | Impact                              | Mitigation                                                                          |
| ------------------------------------------------ | ---------------------- | ----------------------------------- | ----------------------------------------------------------------------------------- |
| Liquidator front-runs liquidator                 | Yes (standard MEV)     | First wins bonus                    | Expected, no fix needed                                                             |
| Liquidatee front-runs by depositing              | Yes                    | Prevents liquidation                | BP_DECREASE_BUFFER creates safety margin                                            |
| Liquidatee front-runs by closing positions       | Yes                    | Hash mismatch → liquidation reverts | Liquidator can retry with updated list                                              |
| Liquidatee withdraws via withdraw-with-positions | Possible if borderline | Extracts value then gets liquidated | validateCollateralWithdrawable solvency check                                       |
| Liquidator sandwiches own liquidation            | Possible               | Manipulates burn settlement         | TWAP-based bonus computation limits gain; tickDeltaDispatch limits single-tx impact |

### D2. Force Exercise Timing

| Attack                                    | Feasibility | Impact                               | Mitigation                                      |
| ----------------------------------------- | ----------- | ------------------------------------ | ----------------------------------------------- |
| Exercisor times for max fees              | Yes         | Higher exercise cost to exercisee    | Fee computation uses TWAP, not spot             |
| Exercisee avoids exercise by closing long | Yes         | Exercise fails (no exercisable legs) | Exercisor can retry; eventual exercise possible |
| Exercisor manipulates price into range    | Possible    | Increases exercise cost              | TWAP deviation check at PP:1537                 |

### D3. Premium Settlement Ordering

| Attack                                | Feasibility           | Impact                               | Mitigation                                                    |
| ------------------------------------- | --------------------- | ------------------------------------ | ------------------------------------------------------------- |
| Long settles just before short closes | Possible              | Drains s_settledTokens               | availablePremium capped at min(owed, available)               |
| Short closes before long settles      | Possible              | Short avoids paying settled premium  | Short's premium is from gross accumulators, not settledTokens |
| Burn ordering in liquidation          | Liquidator-controlled | Affects per-leg haircut distribution | Total haircut unchanged; only distribution differs            |

### D4. Dispatch Batching

**Cumulative tick delta tracking:** Uses transient storage (`PRICE_TRANSIENT_SLOT`), persists across multicall sub-calls within the same tx. Checked at PP:734: `cumulativeTickDeltas.rightSlot() > 2 * tickDeltaDispatch`.

**Can an attacker mint+settle+burn in one dispatch?**
Yes. `positionIdList = [A, A, A]` with appropriate `positionSizes`. First processes mint (positionBalance was 0), second processes settle (positionSize matches), third processes burn (positionSize mismatches). Each operation is valid. Cumulative tick delta tracks total price impact across all operations.

**Impact:** Near-zero. Mint and burn in same block yield negligible premium. User pays commission twice. **No exploit.**

**dispatchFrom does NOT track cumulative tick deltas.** It uses TWAP deviation check instead (PP:1537). This is correct because dispatchFrom's price impact comes from the TARGET account's position burns, not from the caller's operations.

---

## E) Findings

### STATE-001: Dead Code `_accrueInterests()` — Stale Interest in Solvency Checks

| Field             | Value                                                                                                                                                                                                                                                                                                                                                                                           |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Severity**      | Low                                                                                                                                                                                                                                                                                                                                                                                             |
| **Category**      | state-violation                                                                                                                                                                                                                                                                                                                                                                                 |
| **Files**         | PanopticPool.sol:1605-1608, 1515                                                                                                                                                                                                                                                                                                                                                                |
| **Invariant**     | Solvency checks should use up-to-date interest state                                                                                                                                                                                                                                                                                                                                            |
| **Description**   | `_accrueInterests()` is defined at PP:1605 but never called. The solvency check in `dispatchFrom` (PP:1515) uses the last stored borrow index, which may be stale. Interest is only accrued per-user during `CT.settleBurn` calls, which happen AFTER the solvency check.                                                                                                                       |
| **Preconditions** | Interest has accumulated since last interaction; borrow index is stale by at least one epoch (4 seconds)                                                                                                                                                                                                                                                                                        |
| **Impact**        | Insolvent borrowers appear slightly more solvent, delaying liquidation by up to one epoch.                                                                                                                                                                                                                                                                                                      |
| **Adversary**     | Cannot be forced — natural protocol behavior. Liquidators can work around by calling `CT.accrueInterest()` before liquidating via a helper contract.                                                                                                                                                                                                                                            |
| **PoC**           | 1. User opens short position (borrows assets). 2. Time passes with no interactions (borrow index stale). 3. User's actual debt exceeds their balance. 4. Liquidator calls `dispatchFrom(liquidate)`. 5. Solvency check uses stale index → user appears borderline solvent → liquidation may fail. 6. Next epoch: any interaction updates index → user clearly insolvent → liquidation succeeds. |

### STATE-002: Path-Dependent Liquidation Premium Distribution

| Field             | Value                                                                                                                                                                                                                                                                                                                                                                                  |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Severity**      | Low                                                                                                                                                                                                                                                                                                                                                                                    |
| **Category**      | ordering                                                                                                                                                                                                                                                                                                                                                                               |
| **Files**         | PanopticPool.sol:928-950, 1742                                                                                                                                                                                                                                                                                                                                                         |
| **Invariant**     | Premium haircut distribution should be deterministic                                                                                                                                                                                                                                                                                                                                   |
| **Description**   | `_burnAllOptionsFrom` iterates positions in caller-supplied order (PP:928). Each burn modifies `s_settledTokens` and `s_grossPremiumLast`, affecting premium computations for subsequent positions. The `premiasByLeg` values passed to `haircutPremia` (PP:1742) are thus ordering-dependent. While total `netPaid` is ordering-independent, the per-leg haircut distribution varies. |
| **Preconditions** | Liquidatee has multiple positions sharing the same chunk (same strike/width/tokenType)                                                                                                                                                                                                                                                                                                 |
| **Impact**        | Liquidator can choose ordering to maximize or minimize haircut on specific legs. Affects which long holders absorb more protocol loss. No total value extracted.                                                                                                                                                                                                                       |
| **Adversary**     | Liquidator controls `positionIdList` ordering                                                                                                                                                                                                                                                                                                                                          |
| **PoC**           | 1. User has positions P1 and P2 on same chunk, both with long legs. 2. Liquidator orders [P1, P2]: P1's burn updates settledTokens, P2's premium calculation sees updated state → P2 gets different haircut. 3. Liquidator orders [P2, P1]: opposite effect. 4. Total haircut is the same; distribution differs.                                                                       |

### STATE-003: ETH Stuck in V3 CollateralTracker on Negative Bonus Liquidation

| Field             | Value                                                                                                                                                                                                                                                                                                                               |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Severity**      | Informational                                                                                                                                                                                                                                                                                                                       |
| **Category**      | lifecycle                                                                                                                                                                                                                                                                                                                           |
| **Files**         | CollateralTracker.sol:1252-1297, PanopticPool.sol:1765                                                                                                                                                                                                                                                                              |
| **Invariant**     | All ETH sent to CT should be accounted for or refunded                                                                                                                                                                                                                                                                              |
| **Description**   | `settleLiquidation` is `payable` (CT:1247). For V3 pools (`poolManager() == address(0)`) with `bonus < 0`, the code uses `safeTransferFrom` for ERC20 tokens (CT:1270-1275) but does NOT handle or refund any ETH attached to the call. For `bonus >= 0`, ETH is refunded (CT:1354). PP forwards all `msg.value` to CT0 at PP:1765. |
| **Preconditions** | V3 pool; liquidation with negative bonus on CT0; caller sends non-zero msg.value                                                                                                                                                                                                                                                    |
| **Impact**        | ETH sent is permanently stuck in CT0. Practically zero risk since V3 pools use ERC20 tokens, not ETH, and rational liquidators wouldn't send ETH.                                                                                                                                                                                   |
| **Adversary**     | Self-inflicted only (user error)                                                                                                                                                                                                                                                                                                    |

### STATE-004: settleLiquidation mintedShares Underflow in Unchecked Block

| Field             | Value                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Severity**      | Medium                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| **Category**      | invariant-break                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| **Files**         | CollateralTracker.sol:1337-1346                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| **Invariant**     | `mintedShares` should represent the correct number of shares to mint for the liquidator                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| **Description**   | At CT:1343, `Math.mulDivCapped(...) - liquidateeBalance` is in an `unchecked` block. If `mulDivCapped` returns a value less than `liquidateeBalance` (possible when bonus is small relative to totalAssets and liquidateeBalance is non-trivial), the subtraction wraps to a large uint256. `Math.min` with `_totalSupply * DECIMALS` then caps it, but the result is still much larger than intended. This causes excessive share minting, diluting the vault.                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| **Preconditions** | `bonus >= 0`; `bonusShares > liquidateeBalance`; `bonus * (_totalSupply - liquidateeBalance) / max(1, totalAssets - bonus) < liquidateeBalance`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| **Impact**        | Vault dilution up to `_totalSupply * DECIMALS` excess shares. All vault depositors (PLPs) absorb the loss proportionally. Bounded by the cap but still significant.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| **Adversary**     | Triggered naturally during liquidation of accounts with specific bonus/balance ratios. Could be engineered by a colluding liquidator-liquidatee pair.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| **PoC**           | 1. Vault: totalAssets=1000, totalSupply=1000. 2. Liquidatee: liquidateeBalance=100 (after virtual share subtraction), bonus=50. 3. bonusShares = convertToShares(50) = 50 > 0 (proceed). Wait, 50 < 100 so this doesn't trigger... Let me recalculate. 4. Need bonusShares > liquidateeBalance: bonus > liquidateeBalance * totalAssets / totalSupply. With totalAssets=totalSupply, need bonus > liquidateeBalance. So bonus=200, liquidateeBalance=100. 5. mulDivCapped(200, 1000-100, max(1, 1000-200)) = 200*900/800 = 225. 6. mintedShares = min(225-100, 1000*10000) = 125. This is correct. 7. But if bonus=999, totalAssets=1000: mulDivCapped(999, 900, max(1, 1)) = 999*900 = 899100. mintedShares = min(899100-100, 10000000) = 899000. This mints 899000 shares on a vault of 1000 supply — massive dilution. The cap at \_totalSupply\*DECIMALS prevents even worse outcomes but still allows significant dilution. |

### STATE-005: Cumulative Tick Delta Sentinel Allows +1 Extra Tick of Price Impact

| Field           | Value                                                                                                                                                                                                                                                                                                                                                 |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Severity**    | Informational                                                                                                                                                                                                                                                                                                                                         |
| **Category**    | state-violation                                                                                                                                                                                                                                                                                                                                       |
| **Files**       | PanopticPool.sol:649-651                                                                                                                                                                                                                                                                                                                              |
| **Invariant**   | Cumulative tick delta should accurately track total price movement                                                                                                                                                                                                                                                                                    |
| **Description** | The sentinel initialization at PP:649-651 sets `rightSlot = 1` as a non-zero marker. This +1 is never subtracted. The final check at PP:734 compares `cumulativeTickDeltas.rightSlot() > 2 * tickDeltaDispatch`. The +1 sentinel effectively allows the actual cumulative delta to be `2 * tickDeltaDispatch - 1` instead of `2 * tickDeltaDispatch`. |
| **Impact**      | Negligible — 1 tick tolerance on a limit that's typically hundreds of ticks.                                                                                                                                                                                                                                                                          |

### STATE-006: Third-Party Settle Does Not Update Short-Leg Premium Accumulators

| Field           | Value                                                                                                                                                                                                                                                                                                                                                                                          |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Severity**    | Informational                                                                                                                                                                                                                                                                                                                                                                                  |
| **Category**    | state-violation                                                                                                                                                                                                                                                                                                                                                                                |
| **Files**       | PanopticPool.sol:1439                                                                                                                                                                                                                                                                                                                                                                          |
| **Invariant**   | `s_options` should reflect latest accumulators for all settled legs                                                                                                                                                                                                                                                                                                                            |
| **Description** | When a third party calls `dispatchFrom(_settlePremium)` for a position owner, only long legs and short legs where `msg.sender == owner` have their `s_options` accumulators updated (PP:1439). Third-party settles skip short-leg accumulator updates. This means the premium checkpoint for short legs is NOT refreshed, and future closes will compute premium from the ORIGINAL checkpoint. |
| **Impact**      | No economic impact — the short seller collects the same total premium regardless of intermediate settle operations. The premium computation (`currentAccumulator - s_options[leg]`) gives the full delta from the original mint.                                                                                                                                                               |

### STATE-007: `_accrueInterests()` is Dead Code

| Field           | Value                                                                                                                                                                                                                                                                                                                                                   |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Severity**    | Informational                                                                                                                                                                                                                                                                                                                                           |
| **Category**    | lifecycle                                                                                                                                                                                                                                                                                                                                               |
| **Files**       | PanopticPool.sol:1605-1608                                                                                                                                                                                                                                                                                                                              |
| **Description** | `_accrueInterests()` calls `CT0.accrueInterest()` and `CT1.accrueInterest()` but is never invoked from any code path. It appears to be residual from a previous design where global interest was explicitly accrued before liquidation. Current design relies on per-user accrual via `CT.settleBurn` → `_updateBalancesAndSettle` → `_accrueInterest`. |
| **Impact**      | None functionally. Wastes bytecode space.                                                                                                                                                                                                                                                                                                               |

### STATE-008: InteractionHelper.settleAmounts chunkKey Consistency

| Field           | Value                                                                                                                                                                                                                                                                                                |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Severity**    | Informational (VERIFIED SAFE)                                                                                                                                                                                                                                                                        |
| **Category**    | invariant-break                                                                                                                                                                                                                                                                                      |
| **Files**       | InteractionHelper.sol:140-146, PanopticMath.sol:438-441                                                                                                                                                                                                                                              |
| **Description** | `InteractionHelper.settleAmounts` re-implements chunk key computation (IH:140-146) rather than calling `PanopticMath.getChunkKey`. Both implementations are: `keccak256(abi.encodePacked(strike, width, tokenType))`. Currently identical. **Maintenance risk** if one is updated without the other. |

---

## F) Patches + Tests

### Patch for STATE-004: settleLiquidation mintedShares underflow

```solidity
// CollateralTracker.sol, around line 1337
// Replace the unchecked block:
uint256 _totalSupply = totalSupply();
uint256 mintedShares;
unchecked {
    uint256 rawMinted = Math.mulDivCapped(
        uint256(bonus),
        _totalSupply - liquidateeBalance,
        uint256(Math.max(1, int256(totalAssets()) - bonus))
    );
    // Prevent underflow: if rawMinted < liquidateeBalance, no additional minting needed
    mintedShares = rawMinted > liquidateeBalance
        ? Math.min(
            rawMinted - liquidateeBalance,
            _totalSupply * DECIMALS
          )
        : 0;
}
```

### Invariant Test for STATE-004

```solidity
// Test: mintedShares should never exceed a reasonable bound
function test_settleLiquidation_mintedSharesBound(uint256 bonus, uint256 liquidateeBalance) public {
  // Setup vault with known state
  // ...
  // Call settleLiquidation with bonus >= 0
  // Assert: mintedShares <= bonus * totalSupply / totalAssets + 1 (rounding)
  // Assert: totalSupply after <= totalSupply before + mintedShares
  // Assert: mintedShares == 0 when bonus can be covered by existing balance transfer
}
```

### Patch for STATE-001: Accrue interest before solvency check

```solidity
// PanopticPool.sol, inside _liquidate, before _calculateAccumulatedPremia:
// Add explicit interest accrual to ensure fresh borrow index
collateralToken0().accrueInterest();
collateralToken1().accrueInterest();
```

Or remove the dead `_accrueInterests()` function and replace with inline calls where needed.

### Adversarial Test for STATE-002: Path-dependent liquidation

```solidity
function test_liquidation_pathDependence() public {
  // Setup: user with two positions P1, P2 on same chunk, both with long legs
  // Liquidate with order [P1, P2] and record haircut distribution
  // Liquidate with order [P2, P1] and record haircut distribution
  // Assert: total haircut is identical
  // Assert: per-leg haircuts may differ (document as expected behavior)
}
```

---

## Summary Table

| ID        | Severity | Category        | File         | Summary                                                       |
| --------- | -------- | --------------- | ------------ | ------------------------------------------------------------- |
| STATE-001 | Low      | state-violation | PP:1605,1515 | Dead `_accrueInterests()` → stale interest in solvency checks |
| STATE-002 | Low      | ordering        | PP:928-950   | Path-dependent liquidation premium distribution               |
| STATE-003 | Info     | lifecycle       | CT:1252-1297 | ETH stuck in V3 CT on negative bonus liquidation              |
| STATE-004 | Medium   | invariant-break | CT:1337-1346 | mintedShares underflow in unchecked block → vault dilution    |
| STATE-005 | Info     | state-violation | PP:649-651   | Cumulative tick delta sentinel +1 tolerance                   |
| STATE-006 | Info     | state-violation | PP:1439      | Third-party settle skips short-leg accumulator update         |
| STATE-007 | Info     | lifecycle       | PP:1605-1608 | Dead code `_accrueInterests()`                                |
| STATE-008 | Info     | invariant-break | IH:140-146   | chunkKey re-implementation maintenance risk                   |

### Cross-Reference with Prior Findings

- STATE-004 overlaps with ROUND-003 from prior rounding audit (same root cause at CT:1338-1344)
- Commission split leak (ROUND-002) confirmed at CT:1584,1589 — not re-reported as it's already documented
- `addCapped` freeze (ROUND-006) confirmed — premium accumulators permanently desync at uint128.max
- All delegate/revoke paths verified 1:1 matched — no new findings

### Verified Safe Properties

- Position lifecycle atomicity: all transitions are atomic (no try/catch, no partial state)
- Multicall + nonReentrant: correctly allows sequential operations, prevents reentrant callbacks
- ensureNonReentrantView: correctly prevents read-only reentrancy
- Cross-CT independence: CT0 and CT1 have separate state, no interference during liquidation
- Position hash (LtHash): collision-resistant with k=2, 124-bit primes
- SFPM transfer disable: unconditional revert on both transfer variants
- ERC4626 share price: bounded away from 0 (min totalAssets=1, min totalSupply=10^6)
- Cross-pool isolation: different PPs have different CTs, no shared-CT double-delegation possible
