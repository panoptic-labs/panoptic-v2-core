# Final Diff Security Review — Pre-Publication Sign-Off

- **Scope:** `git diff dev5..9d0080da -- contracts/` (23 files, +1265/−705 lines)
- **Reviewer model:** Claude Opus 4.6 (1M context)
- **Date:** 2026-02-23

---

## A) Fix Verification Matrix

### S-159

- **File:Line(s):** `SFPM.sol:362`, `SFPMv4.sol:348`
- **Root cause fixed?:** YES — reverts on `vegoid==0` before state writes
- **All instances?:** YES — both V3 and V4
- **Regressions?:** None
- **Edge cases?:** Trivial (`uint8` equality)
- **Verdict:** PASS

---

### S-357

- **File:Line(s):** `CT.sol:1227-1238,1246-1368`
- **Root cause fixed?:** YES — `revoke()` simplified; shortfall absorption moved to `settleLiquidation()` inline; `mulDivCapped` + cap at `_totalSupply*DECIMALS`
- **All instances?:** YES — `revoke()` only called from non-liquidation paths
- **Regressions?:** Medium: relies on invariant that no shares burned from delegatee during delegation window
- **Edge cases?:** `bonus==0`, `totalAssets<=bonus`, `liquidateeBalance==0` all handled
- **Verdict:** PASS

---

### S-382

- **File:Line(s):** `RE.sol:1493`
- **Root cause fixed?:** YES — `unsafeDivRoundingUp(positionWidth, 2)` ensures `distanceFromStrike >= 1`
- **All instances?:** YES — single occurrence
- **Regressions?:** None — slightly more conservative for odd widths
- **Edge cases?:** `positionWidth=1 → distanceFromStrike=1`; `positionWidth=0` handled by separate branch at `RE.sol:1395`
- **Verdict:** PASS

---

### S-441

- **File:Line(s):** `PP.sol:1536-1544`
- **Root cause fixed?:** YES — TWAP delta check moved inside `solvent==numberOfTicks` (force-exercise) branch; liquidation path (`solvent==0`) bypasses it
- **All instances?:** YES — constant renamed to `MAX_TWAP_DELTA_DISPATCH` throughout
- **Regressions?:** None — 4-tick solvency check (including live `currentTick`) prevents stale-oracle false liquidations
- **Edge cases?:** Partial solvency (`0 < solvent < numberOfTicks`) correctly reverts `NotMarginCalled`
- **Verdict:** PASS

---

### S-570

- **File:Line(s):** `CT.sol` (removed)
- **Root cause fixed?:** YES — `donate()` function and `Donate` event completely removed
- **All instances?:** YES — zero matches for `"donate"` in `contracts/`
- **Regressions?:** None
- **Edge cases?:** N/A
- **Verdict:** PASS

---

### S-596

- **File:Line(s):** `RE.sol:1625`
- **Root cause fixed?:** YES — condition changed from `index < partnerIndex` to `_isLong == 1`; spread requirement now attributed to long leg per documented interface
- **All instances?:** YES — single call site to `_computeSpread`
- **Regressions?:** None
- **Edge cases?:** Two-leg spread where long has higher index now works correctly
- **Verdict:** PASS

---

### S-624

- **File:Line(s):** `SFPM.sol:449`
- **Root cause fixed?:** YES — `>> 112` changed to `>> 120`, extracting true most-significant 40 bits of address
- **All instances?:** YES — V4 uses different hash-based approach (correct). Factory uses `>> 120` consistently
- **Regressions?:** None — new deployments only
- **Edge cases?:** Collision loop at `SFPM.sol:380` handles hash collisions
- **Verdict:** PASS

---

### S-678

- **File:Line(s):** `TokenId.sol:507-510`
- **Root cause fixed?:** YES — bounds check `riskPartnerIndex > (numLegs - 1)` added before mutual-partner check
- **All instances?:** YES — `validate()` is the single entry point
- **Regressions?:** None
- **Edge cases?:** All `numLegs` values 1-4 correctly bounded; check occurs before accessing `self.riskPartner(riskPartnerIndex)`
- **Verdict:** PASS

---

### S-763

- **File:Line(s):** `RE.sol:515-521`
- **Root cause fixed?:** YES — per-token bonus with ternary `req > bal ? req - bal : 0` prevents underflow
- **All instances?:** YES — replaces cross-margin bonus entirely
- **Regressions?:** Economic behavior change (per-token vs cross-token bonus)
- **Edge cases?:** `req==bal → bonus=0`; `bal==0 → bonus=0`; `bal==1, req=100 → bonus=0` (correct)
- **Verdict:** PASS

---

### S-920

- **File:Line(s):** `RE.sol:907`
- **Root cause fixed?:** YES — `highDivergence` threshold changed from `MAX_TICKS_DELTA * 2` (1906) to `MAX_TICKS_DELTA / 2` (476)
- **All instances?:** YES — single occurrence
- **Regressions?:** Safe mode triggers more frequently (conservative)
- **Edge cases?:** Integer division `953/2 = 476` is correct
- **Verdict:** PASS

---

### S-966

- **File:Line(s):** `CT.sol:1568-1576,1659-1667`
- **Root cause fixed?:** YES — `if (balanceOf[_optionOwner] < sharesToBurn) revert NotEnoughTokens(...)` added before commission burn
- **All instances?:** YES — both `settleMint` and `settleBurn`
- **Regressions?:** None — adds clean revert where previously silent under-charge or unhelpful underflow occurred
- **Edge cases?:** `sharesToBurn==0` handled gracefully by `_burn/_transferFrom`
- **Verdict:** PASS

---

### S-993

- **File:Line(s):** `RE.sol:816`
- **Root cause fixed?:** YES — destructuring corrected from `(eonsEMA, slowEMA, fastEMA,,)` to `(, fastEMA, slowEMA, eonsEMA,)` matching `getEMAs()` return order
- **All instances?:** YES — single call site
- **Regressions?:** TWAP now more responsive (60% fast weight vs previously 60% slow) — behavioral change, not regression
- **Edge cases?:** All-equal EMAs produce identical output
- **Verdict:** PASS

---

### S-1032

- **File:Line(s):** `PP.sol` (bytecode golfing)
- **Root cause fixed?:** N/A — labeled "DO NOT FIX"
- **All instances?:** N/A
- **Regressions?:** Verified: execution order preserved; state mutations identical; scoping changes affect only local variable lifetimes; `haircutPremia` drops unused liquidatee param
- **Edge cases?:** Loop optimizations (`< n → != n`) are semantically equivalent for forward-only loops
- **Verdict:** PASS

---

### S-1049

- **File:Line(s):** `RE.sol:2042-2046`
- **Root cause fixed?:** YES — return changed from `max(required, convertedCredit)` to `required - convertedCredit` with floor at 1
- **All instances?:** YES — single `_computeDelayedSwap` function
- **Regressions?:** Substantially reduces collateral for delayed swap strategies (intentional)
- **Edge cases?:** `required==convertedCredit → 1`; `convertedCredit==0 → full requirement`; subtraction guarded by `if`
- **Verdict:** PASS

---

### S-1215

- **File:Line(s):** `CT.sol:664-666,683-685,819-820`
- **Root cause fixed?:** YES — `maxWithdraw` and `maxRedeem` subtract `s_creditedShares/creditedAssets` from available pool
- **All instances?:** YES — all 3 withdrawal-limit functions
- **Regressions?:** None — only restricts withdrawals
- **Edge cases?:** `s_creditedShares==0 → no change`; `creditedAssets >= available → returns 0` (correct under protocol loss)
- **Verdict:** PASS

---

### S-1221

- **File:Line(s):** `RE.sol:2226-2230`
- **Root cause fixed?:** YES — `epochTime = block.timestamp & ~uint256(3)` aligns current time to 4-second epoch, matching stored `previousTime`
- **All instances?:** YES — single IRM computation site
- **Regressions?:** `IRM_MAX_ELAPSED_TIME` increased to 16384s (faster convergence after inactivity)
- **Edge cases?:** `elapsed==0 → no rate change`; first update uses `INITIAL_RATE_AT_TARGET`; negative elapsed impossible (monotonic timestamps)
- **Verdict:** PASS

**All 16 fixes verified. No incomplete or regressive fixes found.**

---

## B) Removal & Refactor Safety

### B1. TransientReentrancyGuard Replacement

The solmate `TransientReentrancyGuard` was replaced with a custom implementation at `contracts/libraries/TransientReentrancyGuard.sol`.

- **Semantic equivalence:** Confirmed. Core `nonReentrant` modifier uses identical set-check-body-reset logic with transient storage.
- **Differences:** Cosmetic and additive:
  - Different slot constant (`keccak256("panoptic.reentrancy.slot")`)
  - Custom error (`Errors.Reentrancy()` vs string revert)
  - Added `ensureNonReentrantView` modifier
  - Added `reentrancyGuardEntered()` getter

**Function coverage — CollateralTracker (14 guarded):**  
`transfer`, `transferFrom`, `deposit`, `mint`, `withdraw` (both overloads), `redeem`, `accrueInterest`, `delegate`, `revoke`, `settleLiquidation`, `refund`, `settleMint`, `settleBurn`

**Function coverage — PanopticPool:**

- `nonReentrant`: `pokeOracle`, `dispatch`, `dispatchFrom`
- `ensureNonReentrantView`: `validateCollateralWithdrawable`, `numberOfLegs`

**Function coverage — SFPM (2 nonReentrant):**  
`burnTokenizedPosition`, `mintTokenizedPosition`

- **Unguarded state-changers reviewed:** `initialize()`, `unlockCallback`, `lockSafeMode`, `unlockSafeMode`, `approve` — all safe with gating/one-shot controls.
- **Cross-contract lock collision:** None; transient storage is per-contract address.
- **Read-only reentrancy:** Guarded where needed; unprotected views expose only existing on-chain data.

### B2. Bytecode Golfing

| Change                                                                                                | Semantic equivalence | Notes                                                                   |
| ----------------------------------------------------------------------------------------------------- | -------------------- | ----------------------------------------------------------------------- |
| Loop `< n → != n` (6 files)                                                                           | YES                  | Forward-only loops with `++i`; equivalent for all non-negative lengths  |
| Direct CT calls → internal wrappers (`_delegate`, `_revoke`, `_refund`, `_settleMint`, `_settleBurn`) | YES                  | Wrapper dispatch on `isCollateralToken0` reduces duplicate inline calls |
| `haircutPremia` drops `liquidatee` param                                                              | YES                  | Param was unused                                                        |
| Multiple `view → pure` promotions in RiskEngine                                                       | YES                  | Promoted functions were already state-independent                       |
| Variable scoping changes in `_liquidate`                                                              | YES                  | Affects local lifetimes only                                            |

**No semantic change from bytecode golfing optimizations.**

### B3. PositionBalance Restructuring

**New layout (verified, 256 bits, no gap/overlap):**

- `[255]` `swapAtMint` (1 bit)
- `[216:254]` `blockAtMint` (39 bits)
- `[184:215]` `timestampAtMint` (32 bits)
- `[160:183]` `tickAtMint` (`int24`)
- `[144:159]` `utilization1` (`uint16`)
- `[128:143]` `utilization0` (`uint16`)
- `[0:127]` `positionSize` (`uint128`)

- **All readers updated:** old accessors removed; zero matches for removed symbols.
- **All writers verified (3 sites):**
  1. `PP.sol:815` (`_mintOptions`) — correct arguments/packing
  2. `PP.sol:1913` (`_checkSolvencyAtTicks`) — zeroes tick/block/swap fields in safe-mode path (correct)
  3. `RE.sol:1202` (`_getGlobalUtilization`) — zeroes all except utilizations (correct)
- **`positionData()` type at `PP.sol:2120`:** matches `unpackAll()` exactly.
- **Migration:** none required (non-upgradeable, clone deployments).
- **Stale docs:** `PP.sol:209-211` still reflects old layout (cosmetic only).

---

## C) Diff-Introduced Vulnerability Scan

### C1. Arithmetic Safety

| Location           | Change                                              | Overflow/underflow possible?                 | Verdict        |
| ------------------ | --------------------------------------------------- | -------------------------------------------- | -------------- |
| `CT.sol:1285-1287` | `_internalSupply += shortfall` moved to `unchecked` | No (practically unreachable overflow bounds) | Safe           |
| `CT.sol:1337-1347` | `mintedShares` calc in `unchecked`                  | No (`rawMinted > liquidateeBalance` guard)   | Safe (bug fix) |
| `CT.sol:1601-1603` | `tokenPaid += int128(uint128(commissionFee))`       | No (bounded cast/addition)                   | Safe           |
| `PP.sol:1638-1653` | cumulative tick delta in `unchecked`                | Bounded int24 deltas over ≤26 legs           | Safe           |
| `RE.sol:1315`      | `credits = ...` → `credits += ...`                  | No overflow; bounded accumulation            | Safe (bug fix) |
| `RE.sol:2042-2046` | `required - convertedCredit`                        | Guarded by `if (required > convertedCredit)` | Safe (bug fix) |
| `Math.sol:371`     | `currentTick <= tickLower` → `<`                    | Boundary behavior equivalent                 | Safe           |
| `PM.sol:459`       | `width >= 4096` in new `getChunkKey` overload       | Correct 12-bit validation                    | Safe           |

### C2. Access Control

- Removed `donate()` removes share-price manipulation vector.
- SFPM visibility `internal → public` adds getter only.
- Simplified `delegate/revoke` depends on delegation invariant; acceptable but fragile.
- Removed TWAP check only for liquidation path is intentional.

### C3. State Consistency

- `settleLiquidation` ordering is intentional and consistent.
- Commission event now emits correct splits (bug fix).
- Premium accumulator guard preserves dust amounts (bug fix).
- `unlockPool` event boolean corrected (bug fix).

### C4. External Interaction Safety

- `pokeOracle()` / `_accrueInterests()` caller-open but gas-only impact.
- `getChunkData` exposes already-on-chain data only.
- `settleLiquidation` reentrancy window guarded; external V4 call occurs post-state updates.

### C5. Economic Safety (Summary)

| Parameter                            | Concern  | Key risk                                                                     |
| ------------------------------------ | -------- | ---------------------------------------------------------------------------- |
| `BP_DECREASE_BUFFER` `4/3 → 25/24`   | HIGH     | Very narrow maintenance cushion                                              |
| `crossBufferRatio` `50-90% → 90-95%` | HIGH     | Sharp cliff near saturation                                                  |
| EMA periods halved                   | MODERATE | Easier EMA manipulation, partially offset by tighter high-divergence trigger |
| `VEGOID` `4 → 8`                     | MODERATE | Lower long premium at high util (design choice)                              |
| `TARGET_POOL_UTIL` `50% → 66.67%`    | LOW      | Better IRM alignment                                                         |
| Others                               | LOW/INFO | No clear exploitable dynamics                                                |

### C6. Cross-Contract Consistency

**IRiskEngine ↔ RiskEngine mismatches (3):**

| #   | Interface declaration               | Implementation                                     | Impact                          |
| --- | ----------------------------------- | -------------------------------------------------- | ------------------------------- |
| 1   | `GUARDIAN()` (`IRiskEngine.sol:67`) | Internal immutable + `guardian()` lowercase getter | Selector mismatch; call reverts |
| 2   | `FACTORY()` (`IRiskEngine.sol:129`) | Not on RiskEngine                                  | Call reverts                    |
| 3   | `OWNER()` (`IRiskEngine.sol:132`)   | Not on RiskEngine                                  | Call reverts                    |

Other checks:

- `ISemiFungiblePositionManager` signatures match both SFPMs (10/10).
- `InteractionHelper.doApprovals` signature matches usage.
- `Errors.sol` usage/removals are consistent.
- Factory → CT initialize flow is correct.

---

## D) Integration & Interaction Analysis

### D1. SFPM ↔ PanopticPool

- Callback return values correctly consumed by `_mintOptions/_burnOptions`.
- Premium settlement paths correctly use SFPM collected values.
- New `LiquidityChunkUpdated` event is informational only.

### D2. CollateralTracker ↔ PanopticPool ↔ RiskEngine

- `view → pure` refactor is safe at all call sites.
- New `safeMode` param is passed correctly in solvency checks.
- `haircutPremia` call-site adjusted correctly.
- Collateral requirement reductions are bug-fix corrections, not accidental relaxations.

### D3. Factory → Deployment

- Factory change is error rename only; CREATE2 behavior unaffected.
- Clone deployment with immutable args remains correct; CT uses initialize pattern.

---

## E) Invariant Checklist

1. **Share conservation:** PRESERVED  
   Evidence: `_mint/_burn` and delegation/liquidation accounting maintain `totalSupply() == Σ balanceOf[user]`.

2. **Position hash integrity:** PRESERVED  
   Evidence: Hash updates occur before external calls where required; correctly skipped in `_settleOptions`.

3. **Settled token conservation:** PRESERVED  
   Evidence: Checked arithmetic and saturating subtraction patterns prevent underflow.

4. **Delegation symmetry:** PRESERVED  
   Evidence: Delegate/revoke/absorption pairs remain symmetric across core flows.

5. **Solvency gate:** PRESERVED  
   Evidence: Buffer enforced consistently; safe mode forces 4-tick checks.

6. **Oracle freshness:** PRESERVED  
   Evidence: 4-tick liquidation check prevents stale-oracle false liquidations.

7. **Interest conservation:** PRESERVED  
   Evidence: Accrual clamping + epoch alignment + credited-share withdrawal protections are consistent.

---

## F) Findings

### FINAL-001 — IRiskEngine interface mismatches

- **Severity:** Medium
- **Category:** Integration
- **File:Lines:** `IRiskEngine.sol:67,129,132`
- **Issue:** `GUARDIAN()`, `FACTORY()`, `OWNER()` declared but not implemented by RiskEngine selectors.
- **Impact:** Integration call reverts.
- **Fix:** Remove entries from interface or implement/forward corresponding functions.
- **Resolution:** **WILL NOT ADDRESS**.

### FINAL-002 — BP_DECREASE_BUFFER may be insufficient for volatile pairs

- **Severity:** Medium
- **Category:** Economic
- **File:Lines:** `RE.sol:85`
- **Issue:** `25/24` buffer can allow underwater transition after small adverse move.
- **Impact:** Faster protocol-loss realization in volatility spikes.
- **Fix:** Consider `13/12` or accept with explicit monitoring and governance playbook.
- **Resolution:** **ACCEPTED RISK** — different risk engines are deployed for different asset pairs, allowing per-pair buffer tuning.

### FINAL-003 — crossBufferRatio cliff compounds with tight BP buffer

- **Severity:** Medium
- **Category:** Economic
- **File:Lines:** `RE.sol:2117-2158`
- **Issue:** Sharp cross-margin decay from 90% to 95% utilization.
- **Impact:** Cascading liquidation risk near saturation.
- **Fix:** Smooth decay window (e.g., start at 80%) or explicitly accept/document risk.
- **Resolution:** **NOT APPLICABLE** — utilization is set at origination and does not float, so cascading liquidation from utilization shifts cannot occur.

### FINAL-004 — Commission split leak persists (pre-existing)

- **Severity:** Low
- **Category:** Economic (pre-existing)
- **File:Lines:** `CT.sol:1582-1598`
- **Issue:** Rounding leaves remainder with option owner under builder-code path.
- **Impact:** Minor fee leakage.
- **Fix:** Burn full `sharesToBurn`, then split; or compute residual leg as remainder.

### FINAL-005 — Stale inline docs for PositionBalance layout

- **Severity:** Informational
- **Category:** Regression (documentation)
- **File:Lines:** `PanopticPool.sol:209-211`
- **Issue:** Comment still reflects old layout.
- **Impact:** Developer confusion only.
- **Fix:** Update comment.

---

## G) Publication Readiness Assessment

**Verdict: CONDITIONAL PASS**

All 16 fixes are implemented correctly with no regressions found. Reentrancy guard replacement is semantically equivalent, PositionBalance refactor is sound, and core invariants are preserved.

**Required before publication:**

1. Fix `FINAL-001` (IRiskEngine mismatch).
2. Fix `FINAL-005` (stale PositionBalance comment).

**Accepted/documented risks:** 3. `FINAL-002` + `FINAL-003` (tight buffer + utilization cliff). 4. `FINAL-004` (pre-existing low-severity commission leak).

### Confidence Levels

| Section                            | Confidence | Notes                                               |
| ---------------------------------- | ---------- | --------------------------------------------------- |
| Fix verification (A)               | High       | All 16 fixes traced and edge-checked                |
| Reentrancy analysis (B1)           | High       | Entry points + transient storage isolation verified |
| PositionBalance restructuring (B3) | High       | Bit layout + reader/writer coverage verified        |
| Arithmetic safety (C1)             | High       | New unchecked paths bounded                         |
| Economic parameters (C5)           | Medium     | No multi-agent stress simulation included           |
| Cross-contract interfaces (C6)     | High       | Signature comparisons completed                     |
| Invariant preservation (E)         | High       | Traced across all changed paths                     |

### Additional Assurance Recommended

1. Formal verification for `settleLiquidation` arithmetic (`S-357` rewrite).
2. Historical-volatility economic simulation for `BP_DECREASE_BUFFER + crossBufferRatio`.
3. Integration tests for `delegate → burn-all → settleLiquidation` edge cases.
4. Fuzz tests for new `getChunkKey` overload consistency vs TokenId-based overload.
