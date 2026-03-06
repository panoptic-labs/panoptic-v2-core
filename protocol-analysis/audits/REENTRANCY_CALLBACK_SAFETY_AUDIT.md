# Reentrancy & Callback Safety Audit

**Date:** 2026-03-04
**Scope:** All files under `contracts/` (recursive)
**Auditor:** Claude Opus 4.6

---

## A) External Call Inventory

### A.1 — SFPM External Calls (V3 Variant)

| #   | Caller                                          | Callee                     | Function                             | Guard Held      | State Modified Before                        | State Modified After                       | Reentrancy Risk                                   |
| --- | ----------------------------------------------- | -------------------------- | ------------------------------------ | --------------- | -------------------------------------------- | ------------------------------------------ | ------------------------------------------------- |
| 1   | `initializeAMMPool` (357)                       | IUniswapV3Factory          | `getPool()`                          | None            | None                                         | `s_addressToPoolData`, `s_poolIdToAddress` | LOW — view call to immutable factory              |
| 2   | `mintTokenizedPosition` → `_mint` (ERC1155:222) | `msg.sender` (if contract) | `onERC1155Received()`                | SFPM            | `balanceOf[to][id]` updated                  | All AMM interactions                       | MEDIUM — callback before AMM work (see REENT-001) |
| 3   | `_mintLiquidity` (1182)                         | IUniswapV3Pool             | `mint()`                             | SFPM            | `s_accountLiquidity` updated (1010)          | `s_accountFeesBase`, premium accumulators  | MEDIUM — triggers mintCallback                    |
| 4   | `uniswapV3MintCallback` (539)                   | ERC20 token                | `transferFrom()` via SafeTransferLib | SFPM            | (callback context)                           | None                                       | LOW — tokens to verified pool                     |
| 5   | `_burnLiquidity` (1209)                         | IUniswapV3Pool             | `burn()`                             | SFPM            | `s_accountLiquidity` updated                 | `s_accountFeesBase`, premium accumulators  | LOW — no callback                                 |
| 6   | `_collectAndWritePositionData` (1269)           | IUniswapV3Pool             | `collect()`                          | SFPM            | `s_accountLiquidity` updated, mint/burn done | Premium accumulators, `s_accountFeesBase`  | LOW — sends tokens to PP                          |
| 7   | `swapInAMM` (784)                               | IUniswapV3Pool             | `swap()`                             | SFPM            | All leg processing done                      | `totalSwapped` return value                | MEDIUM — triggers swapCallback                    |
| 8   | `uniswapV3SwapCallback` (582)                   | ERC20 token                | `transferFrom()` via SafeTransferLib | SFPM            | (callback context)                           | None                                       | LOW                                               |
| 9   | `Multicall.multicall` (15)                      | `address(this)`            | `delegatecall(data[i])`              | Inherits caller | Depends on batch                             | Depends on batch                           | See F.3                                           |

### A.2 — SFPM External Calls (V4 Variant)

| #   | Caller                                      | Callee          | Function              | Guard Held | State Modified Before        | State Modified After | Risk                            |
| --- | ------------------------------------------- | --------------- | --------------------- | ---------- | ---------------------------- | -------------------- | ------------------------------- |
| 1   | `mintTokenizedPosition` → `_mint`           | `msg.sender`    | `onERC1155Received()` | SFPM       | `balanceOf` updated          | All AMM work         | MEDIUM                          |
| 2   | `_unlockAndCreatePositionInAMM` (532)       | POOL_MANAGER_V4 | `unlock()`            | SFPM       | ERC1155 balance updated      | All position state   | KEY — triggers `unlockCallback` |
| 3   | `unlockCallback` → `_createLegInAMM` (1067) | POOL_MANAGER_V4 | `modifyLiquidity()`   | SFPM       | `s_accountLiquidity` updated | Premium accumulators | LOW — no user callback          |
| 4   | `unlockCallback` → `swapInAMM` (742)        | POOL_MANAGER_V4 | `swap()`              | SFPM       | All legs done                | Return value         | LOW — no user callback          |
| 5   | `unlockCallback` (893/899)                  | POOL_MANAGER_V4 | `burn()`/`mint()`     | SFPM       | All legs + swap done         | None                 | LOW — ERC6909 claims            |

**V4 is inherently safer:** `modifyLiquidity()` and `swap()` do not trigger user-facing callbacks. Token settlement is batched through the PoolManager's ERC6909 claim system.

### A.3 — PanopticPool External Calls

| #   | Caller                                              | Callee     | Function                           | Guard Held | State Modified Before                    | State Modified After                                            | Risk                                 |
| --- | --------------------------------------------------- | ---------- | ---------------------------------- | ---------- | ---------------------------------------- | --------------------------------------------------------------- | ------------------------------------ |
| 1   | `dispatch` (648)                                    | RiskEngine | `getRiskParameters()`              | PP         | None                                     | N/A (view)                                                      | NONE                                 |
| 2   | `dispatch` → `_mintOptions` (785)                   | SFPM       | `mintTokenizedPosition()`          | PP         | None in PP                               | s_settledTokens, s_grossPremiumLast, s_options, s_positionsHash | **KEY** — triggers Uniswap callbacks |
| 3   | `dispatch` → `_updateSettlementPostMint` (1192)     | SFPM       | `getAccountPremium()`              | PP         | s_settledTokens, s_positionsHash updated | s_grossPremiumLast, s_options                                   | View call                            |
| 4   | `dispatch` → `_payCommissionAndWriteData` (850-869) | CT0, CT1   | `settleMint()`                     | PP         | All PP state updated                     | s_positionBalance                                               | **Sequential CT calls**              |
| 5   | `dispatch` → `_burnOptions` (982)                   | SFPM       | `burnTokenizedPosition()`          | PP         | None for this position                   | Same as mint                                                    | Triggers callbacks                   |
| 6   | `dispatch` → `_settleBurn` (1007-1029)              | CT0, CT1   | `settleBurn()`                     | PP         | Premium settlement done                  | CT state                                                        | Sequential                           |
| 7   | `dispatchFrom` → `_liquidate` (1704)                | CT0, CT1   | `delegate()`                       | PP         | None                                     | `balanceOf` += 2^248-1                                          | No external calls                    |
| 8   | `dispatchFrom` → `_liquidate` (1771-1776)           | CT0, CT1   | `settleLiquidation()`              | PP         | All burns/haircut done                   | Token transfers, share adjustments                              | **See REENT-003**                    |
| 9   | `dispatchFrom` → `_forceExercise` (1811-1838)       | CT0, CT1   | `delegate()`/`refund()`/`revoke()` | PP         | Various                                  | Share transfers                                                 | No token transfers                   |
| 10  | `pokeOracle` (1612-1613)                            | CT0, CT1   | `accrueInterest()`                 | PP         | None                                     | s_marketState                                                   | No token transfers                   |

### A.4 — CollateralTracker External Calls

| #   | Caller                                        | Callee      | Function                              | Guard Held | State Modified Before                      | State Modified After            | Risk                                                     |
| --- | --------------------------------------------- | ----------- | ------------------------------------- | ---------- | ------------------------------------------ | ------------------------------- | -------------------------------------------------------- |
| 1   | `deposit` (572, V3 path)                      | ERC20 token | `transferFrom()` via SafeTransferLib  | CT         | Interest accrued, shares computed          | `_mint`, `s_depositedAssets +=` | **CEI violation** — transfer before mint (see REENT-005) |
| 2   | `deposit` (589, V4 path)                      | PoolManager | `unlock()` via `_settleCurrencyDelta` | CT         | Shares minted, `s_depositedAssets` updated | N/A                             | Correct CEI                                              |
| 3   | `withdraw` (737, V3 path)                     | ERC20 token | `transferFrom()` via SafeTransferLib  | CT         | Shares burned, `s_depositedAssets -=`      | N/A                             | **Correct CEI**                                          |
| 4   | `withdraw` w/ positions (789)                 | PP          | `validateCollateralWithdrawable()`    | CT         | Shares burned, `s_depositedAssets -=`      | N/A                             | PP view w/ `ensureNonReentrantView`                      |
| 5   | `transfer`/`transferFrom` (408/428)           | PP          | `numberOfLegs()`                      | CT         | None                                       | Share transfer                  | PP view w/ `ensureNonReentrantView`                      |
| 6   | `settleLiquidation` (1270, V3 negative bonus) | ERC20 token | `transferFrom()` via SafeTransferLib  | CT + PP    | `balanceOf` checked                        | `_mint`, `s_depositedAssets +=` | **CEI violation** — transfer before mint (see REENT-003) |
| 7   | `settleLiquidation` (1356, positive bonus)    | Liquidator  | `safeTransferETH()`                   | CT + PP    | All share adjustments done                 | N/A                             | ETH `receive()` callback (see REENT-004)                 |
| 8   | `_accrueInterest` (1058)                      | RiskEngine  | `updateInterestRate()`                | CT         | Interest state partially updated           | s_marketState                   | No direct callback                                       |

---

## B) Cross-Contract Reentrancy Analysis

### B.1 — PP → SFPM → Uniswap → callback → token hook → CT

**Call trace (V3 path):**

```
PP.dispatch() [PP guard SET]
  → SFPM.mintTokenizedPosition() [SFPM guard SET]
    → pool.mint()
      → uniswapV3MintCallback()
        → SafeTransferLib.safeTransferFrom(token, payer, pool)
          → token.transferFrom() ← ERC777 hook fires here
            → [ATTACKER CODE]
```

**Guard state at hook:** PP=HELD, SFPM=HELD, CT0=FREE, CT1=FREE

**What can the attacker call on CT?**

| CT Function                     | Callable?                                                                               | Outcome                                                         |
| ------------------------------- | --------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| `deposit()` / `mint()`          | **YES** — CT guard not held                                                             | Deposits at stale share price (`s_assetsInAMM` not yet updated) |
| `withdraw()` / `redeem()`       | **NO** — calls `PP.numberOfLegs()` → `ensureNonReentrantView` → REVERTS (PP guard held) |
| `transfer()` / `transferFrom()` | **NO** — calls `PP.numberOfLegs()` → REVERTS                                            |
| `accrueInterest()`              | **YES** — no PP view call                                                               | Interest accrual with stale utilization                         |

**State inconsistency:** PP has not yet called `_updateSettlementPostMint()` or `ct.settleMint()`. CT's `s_assetsInAMM` does not reflect the new position. Share pricing via `previewDeposit()` uses `totalAssets()` → `s_depositedAssets + s_assetsInAMM + unrealizedInterest`, which is stale.

**Impact:** An attacker depositing during this window receives shares priced without accounting for the position being minted. The delta is bounded by the single position size relative to total pool assets — typically negligible.

**Verdict: LOW** — Deposit is possible but withdrawal is blocked. The attacker is stuck with marginally mispriced shares that correct once the transaction completes.

### B.2 — PP → CT (settlement) → token transfer → hook → SFPM

**Call trace (liquidation, negative bonus, V3):**

```
PP.dispatchFrom() [PP guard SET]
  → ct0.settleLiquidation() [CT0 guard SET]
    → SafeTransferLib.safeTransferFrom(token, liquidator, PP)
      → [ATTACKER CODE via hook]
```

**Guard state at hook:** PP=HELD, CT0=HELD, CT1=FREE, SFPM=FREE

**Can attacker call SFPM?** SFPM's `mintTokenizedPosition` / `burnTokenizedPosition` are callable (SFPM guard free), but these operate on behalf of `msg.sender` (the attacker), not the PP. The attacker would be creating positions for themselves — not exploiting the PP's state. Additionally, Panoptic pools are registered in SFPM, so the attacker cannot fake being a PanopticPool for settlement.

**Verdict: NOT EXPLOITABLE** — SFPM functions do not allow the attacker to manipulate PP's pending liquidation.

### B.3 — CT standalone → token transfer → hook → PP

**Call trace (V3 path):**

```
ct.deposit() [CT guard SET]
  → SafeTransferLib.safeTransferFrom(token, sender, PP)
    → [ATTACKER CODE via hook]
```

**Guard state at hook:** CT=HELD, PP=FREE, SFPM=FREE

**Can attacker call PP.dispatch()?** Yes, PP guard is free. However, `dispatch()` eventually calls `ct.settleMint()` which requires `onlyPanopticPool` AND `nonReentrant`. CT's guard is held → **REVERTS**.

**Can attacker call PP.pokeOracle()?** Yes, but `pokeOracle()` calls `ct.accrueInterest()` → CT guard is held → **REVERTS**.

**Verdict: NOT EXPLOITABLE** — All meaningful PP operations that touch CT are blocked by CT's held guard.

### B.4 — Concurrent CT0 and CT1 Operations

**Between CT0 and CT1 settlement in dispatch:**

The transition from `ct0.settleMint()` to `ct1.settleMint()` is a sequential internal call sequence with **no external call between them** and **no callback opportunity**. `settleMint()` and `settleBurn()` perform only internal share accounting (`_mint`, `_burn`, `_transferFrom` on ERC20Minimal) — no token transfers, no hooks.

**During liquidation (settleLiquidation):** CT0's `settleLiquidation` CAN perform a V3 token transfer (line 1270) that could trigger a hook. During this hook, CT1's guard is free. The attacker could call `ct1.deposit()` at a pre-liquidation-settlement price. However, they cannot call `ct1.withdraw()` (PP guard blocks it via `ensureNonReentrantView`), so they are locked into the deposit.

**Verdict: LOW** — Same analysis as B.1. Deposit possible, withdrawal blocked, marginal price impact.

---

## C) Read-Only Reentrancy

### C.1 — View Functions Protected by `ensureNonReentrantView`

| Contract          | Function                                  | Protected?                                                |
| ----------------- | ----------------------------------------- | --------------------------------------------------------- |
| PanopticPool      | `validateCollateralWithdrawable()` (464)  | **YES**                                                   |
| PanopticPool      | `numberOfLegs()` (2103)                   | **YES**                                                   |
| PanopticPool      | `getCurrentTick()` (2131)                 | No                                                        |
| PanopticPool      | `getTWAP()` (2126)                        | No                                                        |
| PanopticPool      | `getOracleTicks()` (2070)                 | No                                                        |
| PanopticPool      | `getAssetsOf()` (413)                     | No                                                        |
| CollateralTracker | `totalAssets()` (503)                     | No                                                        |
| CollateralTracker | `convertToAssets()` / `convertToShares()` | No                                                        |
| CollateralTracker | `previewDeposit()` / `previewWithdraw()`  | No                                                        |
| CollateralTracker | `maxWithdraw()` / `maxRedeem()`           | No (but internally calls `PP.numberOfLegs()` → protected) |
| CollateralTracker | `assetsOf()`                              | No                                                        |
| SFPM              | `getAccountLiquidity()`                   | No                                                        |
| SFPM              | `getAccountPremium()`                     | No                                                        |
| SFPM              | `getAccountFeesBase()`                    | No                                                        |
| SFPM              | `getCurrentTick()`                        | No                                                        |

### C.2 — External Integration Risk

**Scenario:** An external lending protocol uses CT shares as collateral and reads `totalAssets()` or `convertToAssets()` during a Panoptic operation.

These functions are NOT protected by `ensureNonReentrantView`. During mid-operation callbacks (e.g., ERC777 hook in SFPM's Uniswap callback), `s_assetsInAMM` is stale — it hasn't been updated for the position being minted/burned. An external protocol reading `convertToAssets(shares)` would get a value based on pre-operation CT state.

**However:**

1. The CT's `reentrancyGuardEntered()` (line 71) is public — external protocols CAN check this.
2. The staleness is bounded by the size of the single operation relative to total pool assets.
3. The `ensureNonReentrantView` modifier exists and protects the two critical cross-contract view calls (`numberOfLegs` and `validateCollateralWithdrawable`).

**Design rationale:** Protecting all CT view functions would break legitimate internal calls during operations (e.g., PP calling `ct.assetsOf()` during solvency checks while PP's guard is held). The selective protection on PP's withdrawal-gating views is the correct design choice.

**Verdict: INFORMATIONAL** — External integrators should check `reentrancyGuardEntered()` before relying on CT pricing. This is a documentation recommendation, not a code fix.

---

## D) Callback Validation

### D.1 — `uniswapV3MintCallback` / `uniswapV3SwapCallback`

**Validation mechanism (CallbackLib:35-43):**

```solidity
function validateCallback(address sender, IUniswapV3Factory factory, PoolFeatures memory features) {
  if (factory.getPool(features.token0, features.token1, features.fee) != sender)
    revert Errors.InvalidUniswapCallback();
}
```

This queries the canonical factory at runtime — it does NOT compute CREATE2 addresses. An attacker deploying a contract at a predicted address would not pass this check because the factory wouldn't return their address for `getPool()`.

**Can `decoded.poolFeatures` be manipulated?** The callback data is ABI-encoded by SFPM, passed to `pool.mint()`/`pool.swap()`, and returned verbatim by the Uniswap pool. The pool is verified as canonical. Data integrity is maintained.

**Can `decoded.payer` be spoofed?** The `payer` is set to `msg.sender` at encoding time (SFPM:1169-1178 for mint, SFPM:754-755 for swap). The callback verifies `msg.sender` is the canonical pool. The payer cannot be manipulated unless the Uniswap pool itself is compromised.

**Verdict: SECURE.**

### D.2 — `unlockCallback` (V4)

**Validation:** Direct address comparison: `msg.sender != address(POOL_MANAGER_V4)` (immutable). Even stronger than V3 factory query.

**Verdict: SECURE.**

### D.3 — Malicious Pool Risk

If an attacker creates a Uniswap V3 pool with malicious token contracts, the SFPM's `initializeAMMPool` would register it. However, the Panoptic Factory (out of scope) controls which pools get PanopticPool deployments. Users interacting with a legitimate PanopticPool are only exposed to the underlying Uniswap pool's token risk, which is a known trust assumption.

---

## E) State Consistency at External Call Boundaries

### E.1 — SFPM `_mintLiquidity` → `pool.mint()` → callback

**Before call:** `s_accountLiquidity[positionKey]` updated (line 1010).
**During callback:** Internal bookkeeping reflects post-mint state, but pool hasn't finalized. View functions would return `s_accountLiquidity` for the new position while premium accumulators are stale.
**After call:** `s_accountFeesBase` and premium accumulators updated.

**CEI violation present but mitigated:** The reentrancy guard prevents any state-mutating re-entry. View functions can read stale premium data during the callback, but this is transient within a single transaction.

### E.2 — SFPM `pool.burn()` → `pool.collect()` manipulation

Can `(amount0, amount1)` from `burn()` be manipulated between burn and collect? **No.** Both calls are sequential within the same external call frame, and the SFPM's reentrancy guard prevents any interleaving. The Uniswap pool's own accounting ensures consistency.

### E.3 — PP `s_grossPremiumLast` between SFPM and CT calls

PP updates `s_grossPremiumLast` in `_updateSettlementPostMint()` (between SFPM call completion and CT settlement calls). If re-entered at this point (which requires a callback from CT settlement), the premium state is consistent because SFPM operations are complete. CT settlement functions (`settleMint`/`settleBurn`) do not perform token transfers, so no callback opportunity exists here.

---

## F) Transient Storage Edge Cases

### F.1 — Multi-Pool Interactions

Each PanopticPool is a separate contract with its own transient storage. Cross-pool reentrancy is theoretically possible but requires:

1. A callback during Pool A's operation that calls Pool B
2. Pool B operating on shared state with Pool A

Since Panoptic pools are independent (separate CT vaults, separate SFPM position tracking), cross-pool reentrancy does not create exploitable state inconsistency.

### F.2 — Guard Reset Ordering

If a function reverts after `_nonReentrantSet()` but before `_nonReentrantReset()`, Solidity's revert semantics revert the transient storage write (the `tstore` in `_nonReentrantSet`). **The guard does NOT remain set.** Transient storage follows the same revert semantics as regular storage within a call frame.

**Exception:** If a `try`/`catch` catches the revert at an outer frame, the inner `tstore` is reverted but the outer guard state depends on when the outer `_nonReentrantSet` was called. The protocol does not use `try`/`catch` around guarded functions, so this is not a concern.

**Verdict: SAFE** — No DoS or guard-locking vector exists.

### F.3 — Delegatecall Interactions (Multicall)

`Multicall.sol:15` uses `address(this).delegatecall(data[i])`. Since `delegatecall` executes in the caller's storage context, the transient storage slot is shared between the multicall batching contract and the delegated function. This means:

- Call 1 in the batch: `dispatch()` acquires guard → executes → releases guard
- Call 2 in the batch: `dispatch()` acquires guard → executes → releases guard

Each subcall independently acquires/releases the guard. This is the intended behavior — users can batch multiple position operations via multicall.

**No proxy patterns** are used in the core contracts. The `delegatecall` in CT lines 366-387 is to a library (InteractionHelper), which shares CT's transient storage — but the library calls (`startPool`, `wrapUnderlyingToken`, `unwrapUnderlyingToken`) are initialization-time only and do not interact with the reentrancy guard.

### F.4 — PRICE_TRANSIENT_SLOT

PP uses a second transient slot `PRICE_TRANSIENT_SLOT` (PP:135) to accumulate tick deltas across multicall batches. It is:

- `tload`'d at the start of `dispatch()` (line 641-644)
- `tstore`'d at the end of `dispatch()` (line 743-746)
- Checked against `2 * tickDeltaDispatch` (line 736-739)

This intentionally persists across multicall calls to enforce a cumulative price impact limit. It does not interact with the reentrancy guard slot and poses no reentrancy risk. It is reset naturally at transaction end (transient storage semantics).

---

## G) Token-Specific Reentrancy Risks

### G.1 — ERC777 Tokens

ERC777 tokens fire `tokensToSend` (on sender) and `tokensReceived` (on receiver) hooks during `transferFrom`. `SafeTransferLib` uses raw `call`, which WILL trigger these hooks.

**All ERC777 callback points during SFPM operations** are protected by the SFPM reentrancy guard. The attacker cannot re-enter SFPM. They can call unguarded contracts (CT), but as analyzed in B.1, only `deposit()`/`mint()` are callable and the attacker cannot withdraw.

**All ERC777 callback points during CT operations** are protected by the CT reentrancy guard. PP operations that touch CT are blocked (CT guard held). The attacker cannot call PP operations that don't touch CT either (PP.dispatch → ... → CT.settleMint → REVERTS).

**Verdict:** ERC777 hooks are neutralized by the reentrancy guard architecture. The only residual risk is stale-price deposits (see Findings).

### G.2 — Fee-on-Transfer Tokens

Fee-on-transfer tokens cause the received amount to be less than the transferred amount. This breaks vault accounting (`s_depositedAssets` tracks the nominal amount, not the received amount). This is a **token compatibility issue**, not a reentrancy concern. Fee-on-transfer tokens do not create additional callback surfaces.

### G.3 — Native ETH / WETH

CT has `payable` functions: `deposit`, `mint`, `withdraw`(positions), `settleLiquidation`.

- **No WETH wrapping:** The protocol does not wrap/unwrap WETH. V4 pools with native ETH use the PoolManager's `settle{value:}()` and `take()` directly.
- **ETH refund via `safeTransferETH`:** At CT:1356, `SafeTransferLib.safeTransferETH(liquidator, msg.value)` sends excess ETH back. This forwards all gas and triggers `receive()`/`fallback()` on the liquidator.
- **Guard state during refund:** PP=HELD, CT=HELD. The liquidator's `receive()` cannot re-enter CT or PP. The only risk is calling other contracts, but all state updates are complete at this point.
- **V4 deposit ETH surplus refund:** At CT:464, `SafeTransferLib.safeTransferETH(account, surplus)` after all state updates. CT guard is held. Safe.

**Verdict: LOW** — `safeTransferETH` enables callbacks but state is consistent and guards are held.

### G.4 — Rebasing Tokens

The protocol uses internal accounting (`s_depositedAssets`, `s_assetsInAMM`) rather than `balanceOf` checks. Rebasing tokens would cause accounting drift but do not create reentrancy-specific risks. Uniswap V3/V4 similarly does not support rebasing tokens.

### G.5 — Blacklist Tokens (USDC)

If a token blacklists an address involved in a callback transfer, the `transferFrom` reverts. This causes the entire operation to revert, which is correct behavior (atomic failure). No partial-state corruption can occur because the reentrancy guard's `tstore` is reverted along with everything else.

---

## H) Findings

### REENT-001 — ERC1155 `_mint` Callback Before AMM Interaction

- **Severity:** Low
- **Category:** callback
- **Location:** SFPM V3:646, V4:629 — `_mint()` before `_createPositionInAMM()`
- **Description:** `_mint(msg.sender, tokenId, positionSize)` triggers `onERC1155Received()` on `msg.sender` BEFORE `tokenId.validate()` or any AMM interaction. The recipient gets a callback with an ERC1155 token minted but no position created.
- **Attack path:** User (contract) → `mintTokenizedPosition()` → `_mint()` → `onERC1155Received()` callback → attacker has ERC1155 token but no AMM position exists yet.
- **Guard analysis:** SFPM guard is held → cannot re-enter `mint`/`burn`. SFPM `safeTransferFrom` and `safeBatchTransferFrom` are disabled (always revert) → token cannot be transferred during callback.
- **Impact:** Minimal. The callback gives the attacker read access to a state where ERC1155 balance is incremented but no AMM state has changed. If subsequent operations revert, the entire transaction reverts. The token is non-transferable during the callback.
- **Requires ERC777:** No — requires `msg.sender` to be a contract.

### REENT-002 — Cross-Contract Stale-Price Deposit via ERC777 Hook (V3 only)

- **Severity:** Low
- **Category:** cross-contract / token-hook
- **Location:** SFPM V3 `uniswapV3MintCallback` (539) → `SafeTransferLib.safeTransferFrom` → ERC777 hook → CT.deposit()
- **Description:** During SFPM's Uniswap callback, if the underlying token is ERC777, the `transferFrom` hook gives the attacker control. CT's guard is not held. The attacker can call `CT.deposit()` at a share price that does not reflect the position being minted (CT's `s_assetsInAMM` is stale).
- **Attack path:** Attacker → PP.dispatch() → SFPM.mintTokenizedPosition() → pool.mint() → mintCallback → token.transferFrom() → ERC777 hook → CT.deposit(assets) → receives shares at stale price.
- **Guard analysis:** PP guard: HELD (blocks CT.withdraw via `ensureNonReentrantView`). SFPM guard: HELD. CT guard: NOT HELD → deposit succeeds. But CT.withdraw() calls `PP.numberOfLegs()` which has `ensureNonReentrantView` → REVERTS. Attacker cannot extract value in the same transaction.
- **Impact:** Attacker receives shares at a marginally incorrect price. The delta is bounded by `positionSize / totalAssets`. In practice, for reasonable pool sizes, this is negligible (sub-basis-point). Post-transaction, state is consistent and the attacker holds correctly-priced shares.
- **Requires ERC777:** Yes.

### REENT-003 — Cross-Contract CT1 Deposit During CT0 Liquidation Settlement (V3 only)

- **Severity:** Low
- **Category:** cross-contract / token-hook
- **Location:** CT `settleLiquidation` (1270-1275) — negative bonus token transfer
- **Description:** During `ct0.settleLiquidation()` (negative bonus, V3 path), the `safeTransferFrom` at line 1270 can trigger an ERC777 hook. CT1's guard is NOT held. An attacker could deposit into CT1 at a pre-liquidation-settlement price.
- **Attack path:** Liquidator (attacker contract) → PP.dispatchFrom() → \_liquidate() → ct0.settleLiquidation() → token.transferFrom() → ERC777 hook → ct1.deposit() → shares at pre-settlement price.
- **Guard analysis:** PP=HELD (blocks CT1 withdraw), CT0=HELD, CT1=FREE (deposit succeeds), SFPM=FREE.
- **Impact:** Same as REENT-002 — marginally mispriced shares, withdrawal blocked during transaction.
- **Requires ERC777:** Yes.

### REENT-004 — ETH `receive()` Callback in settleLiquidation Refund

- **Severity:** Low
- **Category:** token-hook
- **Location:** CT:1356 — `SafeTransferLib.safeTransferETH(liquidator, msg.value)`
- **Description:** When a liquidator attaches `msg.value` expecting a negative bonus but the bonus is non-negative, the ETH is refunded via `safeTransferETH`. This forwards all gas, triggering the liquidator's `receive()`. All state updates are complete at this point.
- **Guard analysis:** PP=HELD, CT=HELD. No state-mutating re-entry is possible into PP or CT.
- **Impact:** None exploitable. The callback occurs after all state changes. The liquidator's `receive()` can only call external contracts that see fully consistent state.
- **Requires ERC777:** No — requires liquidator to be a contract with `receive()`.

### REENT-005 — CT deposit() V3 CEI Ordering

- **Severity:** Informational (design choice)
- **Category:** callback
- **Location:** CT:569-584 — V3 path: `safeTransferFrom` at 572 before `_mint` at 580
- **Description:** In the V3 deposit path, the token transfer occurs before shares are minted and `s_depositedAssets` is updated. During a token hook, CT has received tokens but not minted shares.
- **Guard analysis:** CT guard is held → re-entry into CT blocked. PP operations that call CT settlement → blocked. The inconsistent intermediate state cannot be exploited.
- **Impact:** None. The "transfer-first" pattern ensures funds arrive before accounting. CT's guard prevents all exploitation paths.
- **Requires ERC777:** Yes (for the hook to fire).

### REENT-006 — Unprotected CT View Functions (Read-Only Reentrancy)

- **Severity:** Informational
- **Category:** read-only
- **Location:** CT `totalAssets()` (503), `convertToAssets()`/`convertToShares()`, `assetsOf()` — no `ensureNonReentrantView`
- **Description:** CT's ERC4626 view functions are callable during mid-operation callbacks and may return stale pricing (e.g., `s_assetsInAMM` not yet updated). External protocols using CT shares as collateral could read incorrect values.
- **Guard analysis:** These functions are intentionally unprotected. Protecting them would break internal calls (PP calls `ct.assetsOf()` during solvency checks while PP's guard is held). The public `reentrancyGuardEntered()` function allows external callers to check guard status.
- **Impact:** External integrators reading CT pricing during a Panoptic operation get stale data. No direct exploitation within the protocol itself.

### REENT-007 — SFPM View Functions Lack `ensureNonReentrantView`

- **Severity:** Informational
- **Category:** read-only
- **Location:** SFPM `getAccountLiquidity()`, `getAccountPremium()`, `getAccountFeesBase()`
- **Description:** SFPM view functions do not use `ensureNonReentrantView`. During the `uniswapV3MintCallback`, `s_accountLiquidity` is updated but premium accumulators are not. External readers see intermediate state.
- **Impact:** Same as REENT-006 — only affects external integrators. The protocol's own consumers (PanopticPool) call these functions within the same transaction after all SFPM operations complete, so they see consistent state.

---

## I) Recommendations

### For REENT-001 (ERC1155 callback ordering)

- **No code change needed.** The reentrancy guard and disabled transfers make this safe. If desired, move `tokenId.validate()` before `_mint()` for defense-in-depth:
  ```solidity
  tokenId.validate();
  _mint(msg.sender, TokenId.unwrap(tokenId), positionSize);
  ```
- **Risk of fix:** None — validation is a pure check with no side effects.

### For REENT-002 / REENT-003 (Cross-contract stale-price deposit)

- **Option A (minimal):** Document that ERC777 tokens introduce marginal share pricing risk. The protocol's V4 path is inherently safe (no user-facing callbacks during settlement).
- **Option B (hardening):** Add `ensureNonReentrantView` check on CT's `deposit()`/`mint()` that reads the PP's guard status via a cross-contract call. This would require CT to import a reference to PP's `reentrancyGuardEntered()`.
  ```solidity
  if (panopticPool().reentrancyGuardEntered()) revert Errors.Reentrancy();
  ```
- **Risk of Option B:** Adds gas cost to every deposit. May break legitimate use cases where users deposit into CT during a multicall that also interacts with PP (though this scenario is unlikely since PP.dispatch does its own CT settlement).

### For REENT-004 (ETH receive callback)

- **No code change needed.** All state updates complete before the ETH transfer. The guard is held.

### For REENT-005 (CT deposit CEI ordering)

- **No code change needed.** The "transfer-first" pattern is safe given the reentrancy guard. Reordering to mint-first would require handling the case where the token transfer fails after shares are minted.

### For REENT-006 / REENT-007 (Unprotected view functions)

- **Documentation recommendation:** Document that external protocols integrating with CT (ERC4626) or SFPM should check `reentrancyGuardEntered()` before relying on pricing data in same-transaction compositions.
- **No code change** — protecting all view functions would break the protocol's own internal cross-contract calls.

### General Token Recommendations

- **ERC777 tokens** introduce the only non-trivial reentrancy paths (REENT-002, REENT-003). If the protocol intends to support ERC777 tokens, the findings above represent accepted risk. If not, document this as an unsupported token type.
- **Fee-on-transfer tokens** break vault accounting (not a reentrancy issue). Document as unsupported.
- **Rebasing tokens** are incompatible with internal accounting. Document as unsupported.

---

## Architecture Assessment

The reentrancy protection is **well-designed and layered:**

1. **Per-contract transient storage guards** prevent direct re-entry into the same contract.
2. **`ensureNonReentrantView`** on `PP.numberOfLegs()` and `PP.validateCollateralWithdrawable()` blocks the most dangerous cross-contract path: CT withdrawal/transfer during mid-operation state inconsistency.
3. **`onlyPanopticPool`** on CT settlement functions prevents direct attacker calls.
4. **No token transfers in `settleMint`/`settleBurn`** eliminates callback opportunities during the most sensitive CT state transitions.
5. **V4 architecture** eliminates user-facing callbacks during liquidity operations entirely.

The primary residual risk is cross-contract stale-price deposits via ERC777 hooks (REENT-002/003), which is bounded, requires exotic token types, and cannot be escalated to value extraction within the same transaction due to `ensureNonReentrantView` blocking withdrawals.

**No critical or high-severity reentrancy vulnerabilities were identified.**
