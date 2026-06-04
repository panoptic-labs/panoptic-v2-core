# Liquidation Bonus Invariants Audit — Final Report

Date: 2026-05-18

Scope (hard): `contracts/` only. References to tests are out-of-scope for invariant proofs but in-scope for gap mapping.

Prompt source: `protocol-analysis/prompts/PROMPT_BONUS_INVARIANTS.md`.

---

## A) Invariant Formalization

Notation: `bal_t = tokenData_t.rightSlot()`, `req_t = tokenData_t.leftSlot()`. `balance_t = bal_t − shortPremium_t`; `paid_t = bonus_t + netPaid_t + credit_t` (post-conversion, post-haircut where indicated). `bonus_value` = TWAP-priced sum of `bonus_t`. `post_balance_s` = liquidatee's CT-share-denominated underlying balance after `_burnAllOptionsFrom` + `settleAmounts` + `settleLiquidation` complete.

### I1 — Liquidator-incentive floor

- **Predicate:** account liquidatable ⇒ `bonus_value > 0` at TWAP.
- **Preconditions:** `_liquidate` reached, i.e. the four-tick gate at `contracts/PanopticPool.sol:1591–1606` returned `solvent == 0`, which requires `req > bal` at every tick.
- **Enforcement site:** `contracts/RiskEngine.sol:532–537` (the `min(MAX_BONUS*req/DEC, max(req-bal,0))` formula).
- **Decidability:** `formal`.

### I2 — Protocol-loss safety (final-state form)

- **Predicate:** `∃ t : ProtocolLossRealized_t > 0` ⇒ `∀ s : post_balance_s ≤ 0`.
- **Preconditions:** `_liquidate` ran to completion, settlement order is `_burnAllOptionsFrom` → `getLiquidationBonus` → `haircutPremia` → `settleAmounts` (mints haircut shares back to liquidatee) → `settleLiquidation` (emits the event).
- **Enforcement site:** cross-conversion arm at `contracts/RiskEngine.sol:560–607` + per-token settlement at `contracts/CollateralTracker.sol:1253–1382` + haircut conversion at `contracts/RiskEngine.sol:666–734`.
- **Decidability:** `formal` for the bonus-formula portion; `formal` for the haircut portion modulo per-leg rounding (which is closed-form bounded).

### I3 — Bonus monotone in distress

- **Predicate:** per-token, `bonus_t` non-decreasing in `(req_t - bal_t)/req_t`; aggregate `bonus_value` at TWAP non-decreasing in aggregate distress at fixed `req`.
- **Preconditions:** holding `req_t` fixed, varying `bal_t`.
- **Enforcement site:** `contracts/RiskEngine.sol:532–537` (per-token), `contracts/RiskEngine.sol:560–607` (aggregate post-conversion).
- **Decidability:** `formal` per-token; aggregate monotonicity is `formal` modulo conversion rounding.

### I6 — Continuity at the liquidation boundary

- **Predicate:** `lim_{bal_t → req_t^-} bonus_t > 0`, no jump-discontinuity to zero.
- **Preconditions:** `req_t > 0`. (If `req_t = 0` the account is not liquidatable, so the limit is vacuous.)
- **Enforcement site:** `contracts/RiskEngine.sol:532–537`, regression-pinned by `test_LiquidationBonus_requiredCapPaysCrossTokenBonusWhenDeficientTokenHasNoBalance` (`test/foundry/core/RiskEngine/RiskEngine.Properties.t.sol:605`).
- **Decidability:** `formal`.

### I9 — No self-liquidation profit

- **Predicate:** for any actor controlling both borrower B and liquidator L, `value_TWAP(ΔWallet_B + ΔCT_B + ΔWallet_L + ΔCT_L) ≤ 0` net of gas and Uniswap fees.
- **Preconditions:** liquidation passes the four-tick gate; oracle is functional within Safe-Mode bounds.
- **Enforcement site:** distributed — cross-conversion arm at `contracts/RiskEngine.sol:560–607`, four-tick gate at `contracts/PanopticPool.sol:1591–1606`, mint check `balance ≥ (1 + MMR) * loan` at mint time.
- **Decidability:** `empirical` (requires harness/fuzz). Pinned by `test_Success_loanBonusClamp_crossCollateralized_zeroBonus` at `test/foundry/core/Misc.t.sol:11459`. Operational dependencies: TWAP/spot oracle integrity, third-party liquidator presence.

---

## B) Per-Invariant Proof or Disproof

### I1 — **Holds**

Bonus formula at `contracts/RiskEngine.sol:532–537`:

```
bonus_t = min(MAX_BONUS * req_t / DECIMALS, max(req_t - bal_t, 0))
```

If account is liquidatable ⇒ four-tick gate (`PanopticPool.sol:1598`) says `solvent == 0` at `twapTick` ⇒ `bal_twap < req_twap` on at least one side (the side that ties solvency to deficit). Since `req_t` is derived from real position parameters (not from balance), `req_t > 0` whenever there are any short legs or width-positive longs with a margin requirement, so `req_t > bal_t` ⇒ `bonus_t > 0` strictly. The cross-conversion arm (`RiskEngine.sol:571–597`) is value-preserving at TWAP modulo ≤ 1 wei rounding (see Additional Invariants below), so `bonus_value > 0` is preserved through the arm.

Pure-loan low-utilization confirmation: at `m = 10%`, deficit `req - bal = mL - E` is positive whenever `E < mL`, and the cap `0.2·req = 0.22·L` does not bind first — bonus = `mL - E > 0`. This is the M-02 fix anchored at `RiskEngine.sol:160–162`.

### I2 — **Holds-only-under-stated-assumptions**

**Bonus-formula arm (RE:560–607) preserves I2 exactly.** Trace by case:

Let `Δ0 = paid0 - balance0`, `Δ1 = paid1 - balance1`.

1. `Δ0 ≤ 0 ∧ Δ1 ≤ 0` (no deficit either side): conversion arm skips both inner ifs. Both `post_balance ≥ 0`. I2 vacuous.
2. `Δ0 > 0 ∧ Δ1 > 0` (deficit both sides): outer `if (!(paid0>balance0 && paid1>balance1))` is false ⇒ no conversion. Both `post_balance < 0`. I2 holds (both ≤ 0).
3. `Δ0 > 0 ∧ Δ1 ≤ 0` (deficit token0, surplus token1): only the first inner branch (RE:562–579) fires.
   - **Surplus-large** (`convert0to1(Δ0) ≤ -Δ1`): `bonus1 += convert0to1(Δ0)`, `bonus0 -= min(convert1to0RoundingUp(-Δ1), Δ0)`. I prove `convert1to0RoundingUp(y) ≥ x` whenever `y > convert0to1(x)`:
     Let `f = floor(x·P/Q)`. `y ≥ f+1` ⇒ `yQ/P ≥ (f+1)Q/P > x·(P/Q)·(Q/P) = x` ⇒ `ceil(yQ/P) ≥ x+1 > x`. So `min(...) = Δ0` ⇒ `post_balance_0 = 0`; `post_balance_1 = (-Δ1) - convert0to1(Δ0) ≥ 0`. Both ≥ 0 ⇒ I2 vacuous.
   - **Surplus-boundary or surplus-small** (`-Δ1 ≤ convert0to1(Δ0)`): `bonus1 += -Δ1` (entire surplus consumed) ⇒ `post_balance_1 = 0`. `bonus0 -= min(convert1to0RoundingUp(-Δ1), Δ0)`. The min ≤ Δ0, so `post_balance_0 ≤ 0`. Both ≤ 0 ⇒ I2 holds.
4. `Δ0 ≤ 0 ∧ Δ1 > 0` (deficit token1, surplus token0): symmetric.

**The rounding asymmetry in the bonus-formula arm is protocol-conservative:** the round-trip loss `convert1to0RoundingUp(convert0to1(x)) ≥ x − 1` (proved above) manifests as deeper loss on the deficit token, never as surplus on the other side.

**Haircut arm (RE:620–734) can break I2 by a bounded rounding overshoot.** This is the only finding I surface against I2 in the current tree.

Trace branch 1 (`longPremium.right < L0 ∧ longPremium.left > L1`, RE:666–692):

- `bonusDelta = (-A, +B)` where `A = min(L0-LP0, convert1to0(LP1-L1))`, `B = min(LP1-L1, convert0to1(L0-LP0))`.
- `haircutBase = (LP0, L1 + B)`.
- Per-leg haircut at RE:765–800 uses `Math.unsafeDivRoundingUp(p_leg * haircutBase / longPremium)` (`Math.sol:1177–1181`). Summing over N long-token-1 legs: `haircutTotal.left = haircutBase.left + ε1`, where `0 ≤ ε1 ≤ N1` (each leg's ceiling adds at most one wei).
- `settleAmounts` then calls `ct1.settleBurn(liquidatee, 0, 0, 0, haircutTotal.left, 0)` (`InteractionHelper.sol:168–176`), which routes through `_updateBalancesAndSettle` with `tokenToPay = -haircutTotal.left` ⇒ **mints `haircutTotal.left * totalSupply / totalAssets` shares to liquidatee** and `s_depositedAssets += haircutTotal.left` (`CollateralTracker.sol:1517–1528`).
- Post-state ⇒ liquidatee's underlying token1 balance increases by `haircutTotal.left ≈ L1 + B + ε1`, **including the rounding overshoot ε1**.

Now consider the **partial-coverage sub-case** where `convert1to0(LP1-L1) < L0 - LP0`:

- `A = convert1to0(LP1-L1) < L0 - LP0` ⇒ `bonus0 -= A < L0`. Combined with haircut mint on token0 (≈ LP0 + ε0):
  - `post_balance_0 = -L0 + A + LP0 + ε0` — strictly negative whenever `L0 > A + LP0 + ε0` (the typical case at any non-trivial scale).
- On token1:
  - `post_balance_1 = -L1 - B + haircutTotal.left ≈ -L1 - B + L1 + B + ε1 = ε1 ≥ 0`.

**When `ε1 > 0` and `post_balance_0 < 0`, I2 is violated**: liquidatee has `ε1` wei of token1 surplus on the CT-share side, while `ProtocolLossRealized > 0` emits on the token0 CT. The branch-2 case (LP1 < L1, LP0 > L0) is symmetric, producing `ε0` wei surplus on token0 with loss on token1.

**Bound on ε per token:** `ε_t ≤ N_t ≤ MAX_OPEN_LEGS = 26` (`RiskEngine.sol:158`). For 18-decimal tokens, 26 wei is well below dust. For a 6-decimal token (USDC), 26 wei = 0.000026 USDC. For a hypothetical 0-decimal token, it would be 26 units.

**Decidability of the assumption "ε = 0":** under exact arithmetic (no per-leg fractional remainders), I2 holds. The protocol assumption is that this rounding overshoot is below any actionable threshold; this is operational, not formal.

### I3 — **Holds-only-under-stated-assumptions** (per-token formal; aggregate operational)

Per-token: `bonus_t = min(c1·req_t, max(req_t - bal_t, 0))` is monotone non-decreasing in `(req_t - bal_t)/req_t` because both arguments to `min` are non-decreasing. Formal.

After cross-conversion, monotonicity is preserved at TWAP modulo `convert1to0RoundingUp` rounding (≤ 1 wei). The prompt accepts I3 is "stated, not required" and non-monotone behavior is acceptable.

### I6 — **Holds**

`lim_{bal_t → req_t^-} bonus_t = min(c1·req_t, 0^+) = 0^+` continuously, with `bonus_t > 0` everywhere `bal_t < req_t` (assuming `req_t > 0`). No cliff to zero. The M-02 boundary case (`bal_t = 0, req_t > 0` on the deficient token while the other token is flush) is the regression that produced the redesign; it is pinned at `test/foundry/core/RiskEngine/RiskEngine.Properties.t.sol:605–622` (`bonusAmounts.rightSlot() == 220` instead of 0).

The proposed-fix discipline at the top of the prompt is consistent with the current implementation: no per-token clamp via `loan` or `balance` reintroduces the M-02 zero-bonus boundary.

### I9 — **Holds-only-under-stated-assumptions**

Re-derived per the prior `I9_SELF_LIQUIDATION_ANALYSIS.md`, verified against the current tree:

- The bonus formula's required-anchored cap (`MAX_BONUS·req/DECIMALS`) is bounded by `req`, which is in turn bounded by `(1 + MMR)·loan` for pure-loan portfolios. The mint-time solvency check at `_validateSolvency` (`PanopticPool.sol:1147–1179`) ensures `balance ≥ (1 + MMR)·loan` at mint, capping the deficit any borrower can build without taking real loss.
- The four-tick gate (`PanopticPool.sol:1591–1606`) forces the account to be insolvent at `{spot, twap, latest, current}` — single-block price manipulation cannot trigger liquidation alone.
- Cross-conversion at TWAP (`Math.getSqrtRatioAtTick(twapTick)` at `PanopticPool.sol:1812`) is value-preserving at TWAP modulo conservative rounding.
- The cross-collateralized harness at `test_Success_loanBonusClamp_crossCollateralized_zeroBonus` (`Misc.t.sol:11360–11460`) confirms combined B+L value ≤ 0 in token1 terms, and `assertLe(combinedSelfNet, int256(0))` pins the assertion in CI.

**Vectors not yet refuted to my satisfaction** from the prior I9 audit:

- **Vector A (TWAP/current premium gap, premium sourced at `currentTick` but bonus priced at `twapTick`).** PP:1760–1816 mixes tick sources: `_calculateAccumulatedPremia` uses `currentTick`, `getMargin` uses `twapTick`, `getLiquidationBonus` uses `twapTick`. A manipulated `currentTick` (within the four-tick gate's tolerance because Safe-Mode masks fall-through cases) can change `shortPremium` feeding `tokenData.balance`. The prior audit labels this "Plausible needs PoC"; my read agrees — the asymmetric tick source is real and the only structural reason the construction wouldn't yield positive net is the four-tick gate's `currentTick` arm. Need a PoC sweep to confirm.
- **Vector J (premium-as-collateral timing).** Same logic, different mechanic. The prior audit labels this as the "least-refuted accounting/timing surface." I concur.

I9 status remains "Holds under stated assumptions" with the operational caveat that Vectors A and J are not formally closed.

---

## C) Additional Invariants

### C1 — Rounding direction of cross-conversion arm (RE:573–594)

- **Predicate:** for any inputs, `bonus0_new + bonus1_new` at TWAP ≤ `bonus0_old + bonus1_old` + 1 wei. Asymmetry `convert0to1` (floor) / `convert1to0RoundingUp` (ceil) leaks ≤ 1 wei toward the protocol (liquidator gets ≤ 1 wei less than face value).
- **Status:** `Holds` formally; protocol-conservative direction.
- **Recommendation:** `keep-and-encode-as-test`. Add a 1-wei sweep fuzz over `(p0-b0, b1-p1, atSqrtPriceX96)`.

### C2 — Conservation: bonus + protocol loss = consumed surplus

- **Predicate:** in branch 3 (token0 deficit, token1 surplus, surplus-large case): `bonus0_consumed_from_borrower + protocolLoss0_emitted = (Δ0 - convert0to1_inverse(Y)) - 0` where Y is the token1 amount added to bonus1. Symmetric for branch 4.
- **Status:** `Holds` modulo rounding (≤ 1 wei from `convert0to1` floor).
- **Recommendation:** `keep-and-encode-as-test`.

### C3 — `positionSize` monotonicity of `bonus_value`

- **Predicate:** doubling `positionSize` at the same tick at most doubles `bonus_value` at TWAP.
- **Status:** `Holds`. Both `req_t` (linear in `positionSize` via `getAmountsMoved`) and `bal_t` (linear via shares/credits) scale linearly. The bonus formula is homogeneous of degree 1 in `(req, bal)`, so it scales linearly. The cross-conversion arm is homogeneous of degree 1 too.
- **Recommendation:** `keep-and-encode-as-test`. Worth a fuzz given the audit prompt explicitly names it.

### C4 — `MAX_BONUS` cap reachability

- **Predicate:** there exists a parameter configuration where `MAX_BONUS·req/DECIMALS = 0.2·req` binds before the `req - bal` arm.
- **Status:** `Holds`. Binds whenever `req - bal ≥ 0.2·req`, i.e., `bal ≤ 0.8·req`. In pure-loan-at-high-util (`m ≈ 100%`, `req = 2L`, `bal = L`), `req - bal = L`, cap = `0.4L`, so cap binds. Not dead code.
- **Recommendation:** none.

### C5 — Token symmetry

- **Predicate:** swap token0 ↔ token1 inputs and outputs mirror.
- **Status:** `Holds`. The function is structurally symmetric (RE:560–597 mirrors RE:580–597). `convert0to1` ↔ `convert1to0`, `convert0to1RoundingUp` ↔ `convert1to0RoundingUp` are inverses.
- **Recommendation:** `keep-and-encode-as-test`. A metamorphic property-test pins it cheaply.

### C6 — `haircutPremia` round-trip identity

- **Predicate:** `Σ_legs haircutPerLeg_t ≤ haircutBase_t + N_t` (haircut overshoot is bounded by per-leg ceiling).
- **Status:** `Holds` formally with explicit bound.
- **Recommendation:** `keep-and-encode-as-test`. Pinning the bound on `ε_t ≤ N_t` would prevent regression to e.g. a `mulDivRoundingUp` that loses the per-leg bound, and lets a future reviewer see the tolerance.

### C7 — Haircut share-mint conservation

- **Predicate:** the `s_depositedAssets += haircutTotal_t` increment at `_updateBalancesAndSettle` (`CollateralTracker.sol:1526–1528`) matches the value of shares minted to liquidatee modulo share-price drift.
- **Status:** `Unproven`. The arithmetic is `s_depositedAssets += haircutTotal` and `sharesMinted = haircutTotal * totalSupply / totalAssets`. At the moment of the call this conserves share price. But the haircut overshoot `ε` means more is added to both `s_depositedAssets` and the liquidatee's shares than the underlying long premium accounting tracks — a tiny over-credit to the borrower and to overall pool assets (paid by haircut overshoot, which has no source).
- **Recommendation:** see Finding BONUS-I2-01 below.

---

## D) Findings (prioritized)

### BONUS-I2-01 — Haircut per-leg rounding overshoot violates I2 final-state form by ≤ MAX_OPEN_LEGS wei per token

- **Severity:** Informational. (Not High/Medium because per-liquidation magnitude is bounded by `MAX_OPEN_LEGS = 26` wei per token at the formula level, and is bounded by long-token-leg count in practice; the protocol loss this enables is too small to extract net of gas.)
- **Invariant violated:** I2 (final-state form): a non-trivial sub-case admits `post_balance_s > 0 ∧ ProtocolLossRealized_t > 0` for some `s ≠ t`.
- **File:line of the offending code:**
  - `contracts/RiskEngine.sol:765–800` — per-leg `Math.unsafeDivRoundingUp(p_leg * haircutBase / longPremium)` is summed without a re-clamp to `haircutBase`.
  - `contracts/RiskEngine.sol:795–799` — `haircutTotal = haircutTotal.add(haircutAmounts)` accumulates without bound.
  - `contracts/libraries/InteractionHelper.sol:159–176` — uses the raw `haircutTotal` as `realizedPremium`, which mints `haircutTotal * totalSupply / totalAssets` shares to liquidatee at `CollateralTracker.sol:1517–1528`.
- **Predicate that fails:** `ε1 = haircutTotal.left - haircutBase.left > 0` and `ε0 = haircutTotal.right - haircutBase.right > 0` are possible whenever any leg's prorated haircut has a non-zero modular remainder. The mint of `ε_t` shares to liquidatee yields `post_balance_t = +ε_t > 0`, simultaneously a paired loss on the other token (when haircut cross-conv partial-coverage applies) realizes `ProtocolLossRealized > 0` on the deficit token.
- **Why the current code allows the violation (one paragraph):** `haircutBase = min(L_t, LP_t)` is a token-level upper bound on the haircut, but the per-leg loop at RE:765–800 prorates with `unsafeDivRoundingUp`, which adds up to 1 wei per leg, producing `haircutTotal_t ≤ haircutBase_t + N_t`. Solidity has no re-clamp `haircutTotal_t = min(haircutTotal_t, haircutBase_t)` after the loop. `settleAmounts` then routes `haircutTotal_t` into `ct.settleBurn`, which executes `s_depositedAssets += haircutTotal_t` and mints the equivalent in shares back to liquidatee at line 1518. This over-credits the liquidatee's CT-share balance by `ε_t` shares, with no offsetting deduction elsewhere.
- **Preconditions:**
  - At least one long leg on the side that gets over-rounded (e.g., long token1 leg for branch 1).
  - Non-zero modular remainder in the per-leg prorating (e.g., `p_leg * haircutBase` not divisible by `longPremium`).
  - Haircut cross-conv partial-coverage on the other token (so that `post_balance_t < 0` simultaneously) — only required if you want both clauses of an I2 disprover to fire in the same liquidation; otherwise the surplus arises on its own as a tiny PLP-funded gift to the borrower.
- **Minimal attack sequence (numbered, with tick values):**
  1. Two-token config, `tick = 0` (price 1:1), to keep arithmetic clean.
  2. Borrower opens a `(width=0, isLong=0, tokenType=0)` token0 loan `L0 = 1,000,000`.
  3. Borrower opens a `(width=1, isLong=1, tokenType=1)` long token1 leg with non-trivial premium accrual against three short-leg counterparties so the per-leg long premium splits in irrational ratios (e.g., `prem_leg1 = 33`, `prem_leg2 = 33`, `prem_leg3 = 34`, total LP1 = 100). The remainder `prem_leg * haircutBase mod LP1` is non-zero ⇒ each leg's `unsafeDivRoundingUp` adds 1 wei.
  4. Price drift moves the account to insolvent at all four ticks, with `L0` (token0 loss after burn) = 200 and the cross-conv arm of `getLiquidationBonus` exhausting available token1 surplus, leaving `L0 = 200, LP0 = 0, L1 = 0, LP1 = 100`. Branch 1 of haircut triggers. `convert1to0(LP1 − L1) = 100 < L0 − LP0 = 200` ⇒ partial coverage.
  5. After haircut: `haircutBase.left = L1 + B = 0 + 100 = 100`. Per-leg sum `= 33 + 33 + 34` rounded-up-pro-rated to 100 yields `34 + 34 + 34 = 102` (a 2-wei overshoot when each leg has a fractional remainder).
  6. `settleAmounts → ct1.settleBurn(liquidatee, 0, 0, 0, 102, 0)`: mints `~102 * sharePrice^{-1}` shares to liquidatee. `s_depositedAssets += 102`.
  7. `settleLiquidation(ct1, bonus1_final)` revokes `type(uint248).max`, transfers `bonusShares` to liquidator. Liquidatee's residual token1 share balance ≈ `+102 wei`.
  8. `settleLiquidation(ct0, bonus0_final)` triggers `ProtocolLossRealized` on token0 for `~100 wei` (the residual token0 unfunded loss).
- **Concrete impact:** ≤ `MAX_OPEN_LEGS = 26` wei per token per liquidation (≤ 26 dollars at 18-decimal tokens worth $1 = 1e18 wei, so well below dust; ≤ 0.000026 dollars at USDC 6-decimal). Borrower over-credit per liquidation: ≤ N wei. PLP under-funding: matching ≤ N wei. Repeatable across liquidations, not within a single one.
- **Repeatability:** amplifiable across many independent liquidations (each liquidation is a fresh account, full close). Per-liquidation gas cost dominates the rounding leak in any practical token configuration.

### Why this is Informational, not Low or Medium

The amount per liquidation is bounded above by a constant (`N · 1 wei`) where `N ≤ MAX_OPEN_LEGS = 26`. Practical exploitation requires capital lockup and gas, which exceed the leaked value by orders of magnitude under any realistic asset's price. The finding is real (the predicate `post_balance_t > 0 ∧ ProtocolLossRealized_s > 0` is satisfiable) but does not admit value extraction. It is reportable for completeness and for the test discipline of pinning `ε_t ≤ N_t`.

---

## E) Test Coverage Gap Map

Searched `test/foundry/core/{Misc.t.sol, RiskEngine.t.sol (none — split into RiskEngine/*.t.sol), PanopticPool.t.sol, CollateralTracker.t.sol}`, plus `test/foundry/core/RiskEngine/{Properties, PropertiesPlus, Scenarios, Gaps, Invariants, SafeModeAndOracle, UtilMarginLoans, IRM}.t.sol`.

| Invariant                                                     | Status             | Pinning test (if any)                                                                                                                                                                                       |
| ------------------------------------------------------------- | ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **I1**                                                        | `partially pinned` | `test_LiquidationBonus_requiredCapPaysCrossTokenBonusWhenDeficientTokenHasNoBalance` (`RiskEngine.Properties.t.sol:605`) pins the M-02 corner. No general fuzz over `(req_t, bal_t)`.                       |
| **I2** (final-state)                                          | `unpinned`         | No test asserts `ProtocolLossRealized_t > 0 ⇒ ∀s, post_balance_s ≤ 0`. The crossCollateralized harness asserts I9 only.                                                                                     |
| **I3**                                                        | `unpinned`         | No test pins monotonicity.                                                                                                                                                                                  |
| **I6**                                                        | `pinned`           | `test_LiquidationBonus_requiredCapPaysCrossTokenBonusWhenDeficientTokenHasNoBalance` pins the M-02 boundary case. No continuity sweep, but the M-02 case is the only failure mode the protocol cares about. |
| **I9**                                                        | `pinned`           | `test_Success_loanBonusClamp_crossCollateralized_zeroBonus` (`Misc.t.sol:11459`, `assertLe(combinedSelfNet, 0)`); also `_put_zeroBonus` and `_orig` variants for breadth (the `_orig` does not assert).     |
| **C1** (rounding direction)                                   | `unpinned`         | None.                                                                                                                                                                                                       |
| **C2** (conservation)                                         | `unpinned`         | None.                                                                                                                                                                                                       |
| **C3** (positionSize monotonicity)                            | `unpinned`         | `testFuzz_LinearityInPositionSize` (`RiskEngine.Properties.t.sol:81`) pins linearity of _requirements_ in positionSize, not of bonus.                                                                       |
| **C4** (MAX_BONUS reachability)                               | `unpinned`         | None.                                                                                                                                                                                                       |
| **C5** (token symmetry)                                       | `partially pinned` | `test_isAccountSolvent_SymmetricAcrossPriceOrderings` (`Properties.t.sol:344`) handles solvency symmetry; nothing covers `getLiquidationBonus` symmetry.                                                    |
| **C6** (haircut bound)                                        | `unpinned`         | None.                                                                                                                                                                                                       |
| **C7** (haircut mint conservation / I2 violation BONUS-I2-01) | `unpinned`         | None. The only known invariant pin near this surface is `test_Success_creditMirror_tickInvariance` (`Misc.t.sol:11646`), which covers credit mirror, not haircut.                                           |

### Proposed unit + fuzz pin shapes

- `test_I1_bonusValueStrictlyPositive_whenAccountLiquidatable` — Direct unit; inputs cover M-02 boundary, both-deficit, single-side deficit. Assertion: `bonus0_value + bonus1_value > 0` at TWAP.
- `testFuzz_I1_bonusValuePositive_overReqBalSweep(uint128 req0, uint128 req1, uint128 bal0, uint128 bal1, int24 atTick)` — Fuzz; bound: when `req0 > bal0 || req1 > bal1` and `req_t > 0` on the deficit side, assert `bonus_value > 0`.
- `test_I2_pureBonusArm_noSurplusWithLoss` — Direct unit on `getLiquidationBonus` returning `collateralRemaining`; assert `collateralRemaining.right < 0 ⇒ collateralRemaining.left ≤ 0` and symmetric.
- `testFuzz_I2_postHaircutSurplusBoundByLegRounding(...)` — Fuzz; integration with end-to-end `_liquidate`; bound: `max(post_balance_0, post_balance_1) ≤ MAX_OPEN_LEGS` whenever `ProtocolLossRealized` emits on the other side.
- `testFuzz_I3_perTokenBonusMonotonic(uint128 req, uint128 bal_a, uint128 bal_b)` — Fuzz; bound: `bal_a < bal_b < req ⇒ bonus(req, bal_a) ≥ bonus(req, bal_b)`.
- `test_I6_continuityAtMaintenanceBoundary` — Sweep `bal` from `0` to `req+1` in unit steps, assert `bonus > 0` everywhere `bal < req`.
- `testFuzz_I9_combinedPnlNonPositive_overSpotTwapCurrentMix(int24 spot, int24 twap, int24 current, ...)` — Fuzz of the four-tick gate + bonus formula; bound: `combinedSelfNet ≤ 0` at TWAP within Safe-Mode envelope. (This pins Vectors A and J at a structural level even without a full PoC.)
- `testFuzz_C1_crossConvRoundingProtocolConservative(...)` — Fuzz; bound: `bonusValueAtTWAP(after conversion) ≤ bonusValueAtTWAP(before) + 1`.
- `testFuzz_C3_bonusValueLinearityInPositionSize(uint128 ps, uint8 mult)` — Bound: `bonusValue(ps * mult) ≤ mult * bonusValue(ps) + mult` (1 wei per scaling for rounding).
- `test_C5_tokenSymmetry_getLiquidationBonus` — Direct: swap `(tokenData0, tokenData1)` and `(netPaid.right, netPaid.left)` etc. and assert outputs swap.
- `testFuzz_C6_haircutOvershootBound(...)` — Bound: `haircutTotal_t ≤ haircutBase_t + N_t` where `N_t = number of long legs contributing to LP_t`.

---

## F) Recommendations

| Invariant | Classification                                           | Action                                                                                                                                                                                                                         |
| --------- | -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **I1**    | `keep-and-encode-as-test`                                | Add `testFuzz_I1_bonusValuePositive_overReqBalSweep` per E. The current formula at RE:532–537 is correct; only test coverage gap.                                                                                              |
| **I2**    | `strengthen-formula` (small) + `keep-and-encode-as-test` | See I2-fix proposal below.                                                                                                                                                                                                     |
| **I3**    | `drop-as-out-of-scope`                                   | The prompt explicitly states I3 is "stated, not required." Cross-conversion arms shift bonus across tokens, breaking per-token monotonicity by construction. Keep the existing implementation; no test pin required beyond C3. |
| **I6**    | `keep-and-encode-as-test`                                | Already pinned at M-02 corner; add the sweep at E to lock continuity across the boundary. The formula at RE:532–537 is the M-02 fix and must not regress.                                                                      |
| **I9**    | `keep-and-encode-as-test`                                | Already pinned by `test_Success_loanBonusClamp_crossCollateralized_zeroBonus`. The two remaining open vectors (A, J — premium timing under TWAP/current tick disagreement) deserve their own PoC fuzz at E.                    |

### I2 strengthening (minimal change, does not weaken I1/I6/I9)

Re-clamp `haircutTotal_t` to `haircutBase_t` after the per-leg loop, so the per-leg rounding overshoot is absorbed inside the function rather than minted as surplus to the borrower:

```solidity
// After RE:805 (end of the per-leg loop), before returning haircutTotal:
haircutTotal = LeftRightUnsigned.wrap(0)
    .addToRightSlot(uint128(Math.min(uint256(uint128(haircutTotal.rightSlot())), uint256(uint128(haircutBase.rightSlot())))))
    .addToLeftSlot(uint128(Math.min(uint256(uint128(haircutTotal.leftSlot())), uint256(uint128(haircutBase.leftSlot())))));
```

This collapses `ε_t` to 0 and makes I2 hold exactly post-haircut. The clamp is monotone-preserving relative to the current behavior:

- **Effect on I1:** None. I1 is about `getLiquidationBonus`, which runs before `haircutPremia`.
- **Effect on I6:** None. Same as I1.
- **Effect on I9:** Strictly non-negative. Removing borrower over-credit can only reduce combined B+L value, not increase it.
- **Effect on PLPs:** Strictly non-negative. The over-mint that currently went to the borrower as a few wei of shares no longer happens, so PLP value is conserved more tightly.
- **Effect on per-leg accounting (`haircutPerLeg`):** None — only `haircutTotal` is changed; per-leg amounts still emit at the rounded-up values for `settleAmounts`'s `s_settledTokens` update. There's a small asymmetry where `sum(haircutPerLeg)` may exceed `haircutTotal`; this only matters if `settleAmounts` re-reads the sum, which it doesn't (it walks per-leg into `s_settledTokens` and uses `haircutTotal` separately for `ct.settleBurn`).

Alternative (more invasive) fix: switch to `unsafeDivRoundingDown` for the per-leg, and use the remainder to choose one leg to absorb the rounding-up. This is more code change and equivalent in effect; the clamp is the smallest change.

**If the team chooses not to fix:** the finding is Informational and can be documented as accepted, since the magnitude is bounded by a small constant `MAX_OPEN_LEGS = 26` per liquidation per token.

---

## Operational Caveats and Out-of-Scope Notes

- The prior `I9_SELF_LIQUIDATION_ANALYSIS.md` Vector A (TWAP/current premium gap) and Vector J (premium-as-collateral timing) remain "Plausible needs PoC." Neither was disproved during this re-derivation; the four-tick gate is the structural reason no positive construction has been built, but I do not consider this a formal closure.
- The `I9_SELF_LIQUIDATION_ANALYSIS.md` Vector L (pure-loan bonus recycling at high utilization, gross bonus up to 40% of loan) was refuted as I9 — the mint check `balance ≥ (1+m)·loan` makes the bonus cap unreachable without prior borrower-side loss. This is consistent with my read, but does generate `ProtocolLossRealized` (an LP-loss surface), which is the I2 surface — and I2 confirms the LP loss is bounded by the deficit (≤ `bonus + netPaid - balance`), not by a self-liquidation profit.
- Test files under `test/foundry/coreV3/*` exist as V3-flavored mirrors; they're listed for completeness but the V2 (core/) tree is the in-scope one for this audit.

## Summary of changes proposed

- One small `min`-clamp at `contracts/RiskEngine.sol` after RE:805 (haircutTotal re-clamp to haircutBase). Tightens I2 to formal.
- Test additions per section E. Approximately 8–10 new tests; one fuzz per invariant category.
- No changes to the bonus formula at RE:532–537, to the cross-conversion arm at RE:560–607, or to `settleLiquidation` at CT:1253–1382.
