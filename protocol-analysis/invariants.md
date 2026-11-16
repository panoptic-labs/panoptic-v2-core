# Main Invariants

This is the shared spec for the protocol: reviews, fuzz and invariant tests, and formal verification all work from the same statements. Each entry states a property against an **independent reference** (ideal arithmetic, a conservation law, a monotonicity or bound) wherever one exists. It does not restate the code.

## Conventions

- **ID**: `RE-*` RiskEngine, `CT-*` CollateralTracker, `PP-*` PanopticPool, `SF-*` SFPM, `X-*` cross-contract. Older IDs from `audits/BONUS_INVARIANTS_AUDIT.md` (I1, I2, I3, I6, I9, C1–C7) are kept as aliases.
- **Kind**:
  - `safety`: a violation loses funds or breaks accounting.
  - `econ`: an economic soundness property.
  - `design`: a deliberate behaviour that a future change must not silently drop.
  - `param`: an expected parameter value or shape.
- **Status**:
  - `holds`: argued or proved for the current tree.
  - `proved(...)`: proved by Halmos at full 104-bit width in the named scenario, trusting `mulDiv` (see Formal verification).
  - `proved(exhaustive)`: checked at every value of a finite input domain by a plain Foundry test.
  - `partial(...)`: some Halmos regions proved, the rest unfinished; no counterexample found.
  - `tol(ε)`: holds within a stated rounding tolerance.
  - `limit`: a documented, accepted limitation.
  - `open`: not yet argued or proved.
  - `stale?`: carried over without re-checking against the current tree.
- Units: ratios are scaled by `DECIMALS = 10_000_000`. Utilization is stored in bps (0–10_000) and multiplied by 1_000 before it is compared with ratio-scaled params.
- "Rounds against the account" means every rounding choice makes the account look less solvent, or the liquidator or user receive less.

RiskEngine entries were re-checked against the current tree (branch `fix/credits-and-fe-cost`, 2026-10-23). The other sections were only spot-checked and are marked where it matters.

---

## Review notes (2026-10-23)

### Corrected stale entries from the previous version

| Old statement                                                          | Current behaviour                                                                                                                                                  |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Liquidation bonus = `min(bal/2, req − bal)`                            | Per-token floor `min(MAX_BONUS·req/D, max(req−bal,0))`, scaled globally to backable collateral, then cross-converted, then capped per token at backable. See RE-L. |
| Force exercise: flat 1.024% in range, 1 bp out of range, all long legs | Extrinsic-value fee on the **cheapest** long leg only (valued at the oracle tick), floored at `notionalFee` and capped at `FORCE_EXERCISE_COST`. See RE-F.         |
| Cross buffer constant below 90%, zero above 95%                        | Breakpoints are `SATURATED_POOL_UTIL` and `(SATURATED_POOL_UTIL + 100%)/2`. These are deployment params, not fixed values.                                         |
| `crossBufferRatio` is "less conservative" at high utilization          | It is **more** conservative: less cross-margin is allowed as utilization rises.                                                                                    |
| Global utilization (max at mint) drives requirements                   | Each position is priced at **its own** mint utilization. The account-wide max only feeds the cross buffer.                                                         |
| Safe mode prices at 100% util with no cross-margin                     | Safe mode is soft: index-0 sentinel plus a 91% floor on the account max utilization.                                                                               |
| Fixed 953 / 513 tick thresholds                                        | `MAX_TICKS_DELTA` (immutable) and `tickDeltaDispatch` (risk param).                                                                                                |
| I1: liquidatable ⇒ bonus > 0                                           | False by design in bad debt: the bonus is 0 once backable collateral is 0. Restated as RE-L3.                                                                      |
| Maintenance requirement includes "− short premia − credits"            | Short premia and credits are added to the **balance** side. A credit in a token that also has a loan is added back to the requirement.                             |

### Questions raised by this pass (owner decision needed)

1. ~~`_computeLoanOptionComposite` comment vs code~~ **Resolved: the comment is stale.** The sum is intended: an upfront short option (short option + loan) requires `short + loan`, and an option-protected loan requires `max(loan, long)`. Fix the comment in `_getRequiredCollateralSingleLegPartner` at the next RiskEngine upgrade.
2. ~~PanopticPool safe-mode comment~~ **Resolved: the comment is stale but can't be fixed.** PanopticPool is immutable. RE-O4 is the source of truth.
3. ~~Per-position view versus account margin~~ **Resolved: keep the floor.** The contract is documented as RE-M8. Still to do: confirm the SDK and hedger subtract these values from the raw vault balance, not from `D + C`.

---

## RiskEngine

### Margin requirement (`_getMargin`, `_getTotalRequiredCollateral`, per-leg functions)

Notation for one token `t`:

- `A_t` = vault assets of the user
- `I_t` = interest owed
- `SP_t` = short premia counted as collateral
- `LP_t` = long premia owed
- `C_t` = gross credits (long width-0 legs)
- `L_t` = gross loans (short width-0 legs)
- `R_t` = sum of per-leg requirements

| ID    | Kind   | Statement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Status                                                                                     |
| ----- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------ | --- | ----- |
| RE-M1 | safety | **Margin identity.** Over the integers, `bal_t − req_t = (A_t − I_t) + SP_t + C_t − (R_t + LP_t + [L_t>0]·C_t)`, except that `bal_t` saturates at 0 when `I_t > A_t`, with the remainder carried into `req_t`. Interest is counted once: it is never both spendable and owed.                                                                                                                                                                                                                                                                                                                                                                    | holds (`47910804`)                                                                         |
| RE-M2 | safety | **Loan-funded credits are re-margined.** If `L_t > 0`, credits in token `t` add nothing to `bal_t − req_t`. A loan can never fund a credit that reduces the requirement.                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | holds (`072c5555`)                                                                         |
| RE-M3 | safety | **No downward narrowing.** Every narrowing cast in the margin path either reverts or saturates **upward** on the requirement side (`toUint128Capped`). An overflowing requirement must never wrap to a small value, and an account must never become unliquidatable through overflow. Loans above `int128.max` revert with `PositionTooLarge`. Balance-side casts revert (`toUint128`).                                                                                                                                                                                                                                                          | open (FV target)                                                                           |
| RE-M4 | econ   | **Monotone in size.** For a fixed tick, utilization and leg shape, each leg's requirement is non-decreasing in `positionSize`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | open                                                                                       |
| RE-M5 | econ   | **Monotone in utilization.** `_sellCollateralRatio(u, r)` is non-decreasing in `u`, equals `r` below `TARGET_POOL_UTIL`, equals `DECIMALS` above `SATURATED_POOL_UTIL`, and is linear in between. A strangle (`u<0`) uses `r/2` at `                                                                                                                                                                                                                                                                                                                                                                                                             | `proved(exhaustive)`, all utilizations 0–10,000 (`RiskEngine.RatioCurvesExhaustive.t.sol`) | `.  | holds |
| RE-M6 | econ   | **Loan margin ramp.** Loan requirement = `ceil(amount·(DECIMALS + m(u))/DECIMALS)` with `m(u)` running from `MAINT_MARGIN_RATE` (low util) to `DECIMALS/LOAN_MARGIN_DIVISOR` (saturated), non-decreasing in `u`. The requirement is always ≥ the loaned amount.                                                                                                                                                                                                                                                                                                                                                                                  | `proved(exhaustive)`, all utilizations 0–10,000 (`RiskEngine.RatioCurvesExhaustive.t.sol`) |
| RE-M7 | econ   | **Positive floor.** Every width>0 leg priced unpartnered requires ≥ 1. A spread requires ≥ 1.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | holds                                                                                      |
| RE-M8 | design | **Per-position view is conservative against the raw balance.** `getPerPositionCollateralRequirements` returns each position's requirement net of its own credit, floored at 0. In a token with a loan, credits are not netted. Read against the raw vault balance `D`, the view's headroom `D − Σ view_i` = engine headroom `− Σ_{no-loan tokens} max(C_i − R_i, 0)`: exact unless a position's credit exceeds its own requirement, and never higher than the engine. A reader that uses `D + C` instead counts netted credits twice and overstates buying power. Off-chain only (`getFullPositionsData` → SDK, hedger); solvency never uses it. | holds; pinned (`test_perPositionView_*` in `RiskEngine.LoanCreditNetting.t.sol`)           |
| RE-M9 | design | **Each position at its own utilization.** Each position's requirement uses the utilization recorded at its mint. Only `crossBufferRatio` uses the account max.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | holds                                                                                      |

### Partnered strategies

Reference: the unpartnered requirement of the same legs, and the strategy's defined max loss.

| ID    | Kind   | Statement                                                                                                                                                                                                                                                                                                                           | Status                                  |
| ----- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| RE-P1 | econ   | **Partnering never costs more**, except cash-secured or prepaid positions. The requirement of a partnered pair is ≤ the sum of its legs' unpartnered requirements. Strangle, synthetic, spread and loan-composite all satisfy this. The credit composite intentionally prices the option leg at 100% utilization and can exceed it. | open                                    |
| RE-P2 | safety | **Spread ≥ max loss.** For a vertical or calendar spread, the requirement is ≥ the true max loss at any price, or the unpartnered sum is lower and binds. The calendar term `Δwidth·tickSpacing/80_000` must over-estimate `contractSize·(1/(√r1+1) − 1/(√r2+1))`.                                                                  | open (FV target; independent reference) |
| RE-P3 | safety | **Synthetic: the long leg is free only at the same strike.** A synthetic is recognised only when the strikes are equal. Otherwise both legs are priced unpartnered.                                                                                                                                                                 | holds                                   |
| RE-P4 | safety | **Partner validity.** Partner handling applies only when `asset` and `optionRatio` match. Any other pairing falls back to unpartnered pricing, never to 0.                                                                                                                                                                          | holds                                   |
| RE-P5 | design | **Each pair is charged once.** In every partnered branch exactly one leg of the pair carries the requirement and the other returns 0. The exception is a strangle, where each leg carries its own halved requirement.                                                                                                               | holds                                   |

### Solvency (`isAccountSolvent`)

| ID    | Kind   | Statement                                                                                                                                                                                                                               | Status                                                                                     |
| ----- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| RE-S1 | safety | **Definition.** `maintReq_t = ceil(req_t·buffer/D)`. Surplus `s_t = max(bal_t − maintReq_t, 0)·xbuf(u_t)/D`. Solvent iff for both `t`: `bal_t + conv(s_{¬t}) ≥ maintReq_t`. The comparison is made in the cheaper token's denomination. | holds                                                                                      |
| RE-S2 | safety | **Rounding against the account.** Converted requirements round up. Converted balances and surpluses round down.                                                                                                                         | holds                                                                                      |
| RE-S3 | econ   | **Monotonicity.** Solvency is non-decreasing in `bal_t` and non-increasing in `req_t` and in `buffer`.                                                                                                                                  | open: Halmos times out comparing two divisions (see Formal verification)                   |
| RE-S4 | econ   | **Cross buffer shape.** `crossBufferRatio(u, b)` is non-increasing in `u`: `= b` below `SAT`, `= 0` above `(SAT+D)/2`, linear in between.                                                                                               | `proved(exhaustive)`, all utilizations 0–10,000 (`RiskEngine.RatioCurvesExhaustive.t.sol`) |
| RE-S5 | safety | **No cross-margin from a deficit.** A token in deficit contributes 0 surplus. Cross-collateral can only move value from surplus to deficit.                                                                                             | holds                                                                                      |
| RE-S6 | safety | **Token symmetry (C5).** Swapping token0 and token1 (and inverting the price) mirrors the result.                                                                                                                                       | solvency pinned by test; bonus `proved(cross-margin, price 1, 6/6)`                        |

### Oracle and solvency ticks

| ID    | Kind   | Statement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | Status                     |
| ----- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------- | -------- | --------------- | ---------- | -------------- | ----------------------------------------------- | ----- |
| RE-O1 | safety | **Safe-mode level.** `safeMode = [                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | cur−spotEMA                | > Δ] + [ | spotEMA−fastEMA | > Δ/2] + [ | median−slowEMA | > Δ/2] + lockMode`, with `Δ = MAX_TICKS_DELTA`. | holds |
| RE-O2 | safety | **More ticks when stressed.** If `safeMode > 0` or `‖(spot−med, latest−med, cur−med)‖₂ > Δ`, solvency is checked at all 4 ticks (spot, median, latest, current). Otherwise only at spot. The tick set only grows under stress.                                                                                                                                                                                                                                                                                                                                                                                                                           | holds                      |
| RE-O3 | safety | **Manipulation resistance.** Solvency for mint, burn and withdraw is never decided at the current tick alone when the oracle disagrees with it beyond Δ.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | holds (follows from RE-O2) |
| RE-O4 | design | **Safe mode is soft.** In safe mode the account max utilization is floored at `SAFE_MODE_UTIL_FLOOR` (91%), and each position keeps its own mint utilization. Safe mode slows new risk and must not by itself make a position liquidatable. Liquidation uses `safeMode = 0`.                                                                                                                                                                                                                                                                                                                                                                             | holds                      |
| RE-O5 | design | **Sentinel can't be faked by a real position.** `_isSafeModeSentinel` matches only `blockAtMint == 0 ∧ timestampAtMint == 0 ∧ u0 = u1 = 100%`. A minted position always has `blockAtMint ≠ 0`.                                                                                                                                                                                                                                                                                                                                                                                                                                                           | holds                      |
| RE-O6 | design | **Sentinel position effect.** The position at index 0 is priced at 100%/100% in safe mode, and the list order is chosen by the caller. A single-position seller can't withdraw or mint during safe mode. The sentinel must stay for live pools. The sentinel also carries a zero mint tick, so `_getRequiredCollateralAtTickSinglePosition` counts the whole notional of every width-positive short at index 0 as minted without cash (its same-token credits are re-margined in full); the hide direction is closed and an account routes around the over-trigger by listing a credit or long first. Entries at index ≥ 1 keep their mint tick (RE-O5). | limit                      |

### Liquidation bonus (`getLiquidationBonus`, `_scaleFloorsToBackable`)

Notation:

- `balance_t = bal_t − shortPremium_t`
- `backable_t = balance_t − netPaid_t − credit_t`
- `B = max(backable_0 + conv(backable_1), 0)`, valued at TWAP

| ID     | Kind   | Statement                                                                                                                                                                                                                                                                                                                                                                              | Status                                                                                                                                                                                  |
| ------ | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| RE-L1  | safety | **I9: no self-liquidation profit.** For any actor controlling both liquidatee and liquidator, combined TWAP value change ≤ 0. The engine's part is `bonus_value ≤ B`.                                                                                                                                                                                                                  | engine part `proved(cross-margin, 6/6)`, `partial(bad debt, 3/6)`, `proved(credit present)`; full I9 pinned by `Misc.t.sol` `test_Success_loanBonusClamp_crossCollateralized_zeroBonus` |
| RE-L2  | safety | **A credit counts exactly once, like a deposit.** Holding a credit of notional K (+K to balance, −K to netPaid, +K to credits) gives the same bonus as depositing K. Because the cap subtracts credits, the credit is not counted a second time (the `94fab92f` fix).                                                                                                                  | `partial(cross-margin, 5/6)`                                                                                                                                                            |
| RE-L3  | econ   | **I1 restated: incentive when backable.** If the account is short and `B > 0`, then `bonus_value > 0`, provided `req_t ≥ ⌈DECIMALS / MAX_BONUS⌉` (5 wei at `MAX_BONUS = 20%`). Below that the floor `MAX_BONUS·req/DECIMALS` rounds to 0 (dust; counterexample `bal0 = 2`, `req0 = 4`). If `B = 0`, the bonus is 0 by design, and the deep-bad-debt incentive is an external backstop. | `proved(single-token account, req ≥ 5)`; dust counterexample below                                                                                                                      |
| RE-L4  | econ   | **I6: continuity.** The bonus is continuous in `bal_t` at the solvency boundary (`bal → req⁻`) and at the bad-debt boundary (`B → 0⁺`). No snap-back floor. Discrete form checked: one more wei of balance moves the total bonus by at most 2 wei.                                                                                                                                     | `proved(cross-margin, 6/6)`, `partial(bad debt, 4/6)`                                                                                                                                   |
| RE-L5  | econ   | **I3: monotone in distress.** Per token, the pre-cap floor is non-decreasing in `req_t − bal_t` at fixed `req_t`.                                                                                                                                                                                                                                                                      | holds per token (argued); Halmos times out comparing two divisions; aggregate `tol(1 wei)`                                                                                              |
| RE-L6  | safety | **Per-token cap.** After conversion, `bonus_t ≤ max(backable_t, 0)` for both tokens. There is no lower bound: a bonus can be negative, meaning the liquidator pays that token and is paid in the other.                                                                                                                                                                                | `proved(cross-margin, bal1/netPaid1)`, `proved(bad debt, req0/req1)`                                                                                                                    |
| RE-L7  | safety | **Cross-conversion is value-neutral.** The conversion arm moves value between tokens at TWAP without creating it: `bonus_value` after conversion ≤ before + 1 wei (C1). It only acts when exactly one token is short (`¬(paid0>bal0 ∧ paid1>bal1)`).                                                                                                                                   | tol(1 wei)                                                                                                                                                                              |
| RE-L8  | safety | **I2: loss only when exhausted.** If protocol loss is realized in any token, the liquidatee's post-liquidation balance is ≤ 0 in every token.                                                                                                                                                                                                                                          | tol(≤ legs wei per token), BONUS-I2-01                                                                                                                                                  |
| RE-L9  | econ   | **C3: homogeneity.** Scaling (req, bal, netPaid, credits, premia) by k scales the bonus by k, up to rounding.                                                                                                                                                                                                                                                                          | holds                                                                                                                                                                                   |
| RE-L11 | safety | **Liquidation cannot revert.** `getLiquidationBonus` does not revert for any inputs the pool can produce, so an insolvent account can always be liquidated. Precondition: every `netPaid` slot satisfies `                                                                                                                                                                             | netPaid_t                                                                                                                                                                               | < 2^126`(PP-L6). Without it, Halmos finds a revert:`netPaid0 ≈ −2^127`pushes backable collateral past`int128`and`toInt128()` reverts. | `partial(bad debt, 3/6 at full int128 width under PP-L6)`; fails without PP-L6 |
| RE-L10 | design | **No swap.** A liquidation settles in-kind at the current tick. The only TWAP-versus-spot difference is the cross-token bonus conversion.                                                                                                                                                                                                                                              | holds                                                                                                                                                                                   |

### Premium haircut (`haircutPremia`)

| ID    | Kind   | Statement                                                                                                                                                                                                                                       | Status           |
| ----- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| RE-H1 | safety | **Haircut bounded by premium paid.** Each long leg's haircut is ≤ the premium it paid, plus 1 wei of rounding. Total haircut is ≤ `longPremium_t`, plus a number of wei equal to the number of legs.                                            | tol (C6)         |
| RE-H2 | safety | **Haircut bounded by loss.** In the same-token case the haircut base is `min(loss_t, longPremium_t)`. Cross-token, premium in the surplus token covers the other token's loss at TWAP, and the liquidator is compensated through `bonusDeltas`. | open             |
| RE-H3 | safety | **No haircut without loss.** If `collateralRemaining ≥ 0` in both tokens, the haircut is 0.                                                                                                                                                     | holds            |
| RE-H4 | safety | **The unchecked block is safe.** The function is fully `unchecked`. All products fit under the stated bound (≤ 2^127 sums from LeftRight slots).                                                                                                | open (FV target) |

### Force exercise (`exerciseCost`)

| ID    | Kind   | Statement                                                                                                                                                                                                                                                                                | Status     |
| ----- | ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | --------------------- | -------------------- |
| RE-F1 | econ   | **Only the cheapest leg is charged.** The fee is charged on exactly one long leg with width > 0: the one whose fee has the lowest value in the cheaper token at the oracle tick (the first on ties). Adding a long leg can only lower the fee, never raise it. Width-0 legs are ignored. | holds      |
| RE-F2 | econ   | **Fee bounds.** The charged leg pays `fee/D` of notional with `notionalFee·1bp ≤ fee ≤ FORCE_EXERCISE_COST`. In range: `fee ≥ tickSpacing/2` bps and `fee ≥ D²·FEC/(2W·10⁴)` (the extrinsic-value estimate). Out of range: `fee = notionalFee` bps.                                      | holds      |
| RE-F3 | safety | **Oracle tick only.** The fee depends on the oracle tick only. Moving spot can't reduce it. The current-versus-oracle composition delta is reversed for every long leg, so the exercisee is not hurt by spot manipulation.                                                               | holds      |
| RE-F4 | design | The exercise path requires solvency at all 4 ticks and `                                                                                                                                                                                                                                 | cur − twap | ≤ tickDeltaDispatch`. | holds (PanopticPool) |

### Refunds (`getRefundAmounts`)

| ID    | Kind   | Statement                                                                                                                                                                                                                                                                                                          | Status |
| ----- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------ |
| RE-R1 | safety | **Value-preserving substitution.** If the payor lacks shares in one token, the shortfall is replaced by the other token at `atTick`, rounded up in the payor's favour. In value at `atTick`, the result is ≥ `fees` and differs by at most the rounding. When there is no shortfall, `fees` is returned unchanged. | open   |

### Interest rate model

| ID    | Kind   | Statement                                                                                                                                                            | Status                                     |
| ----- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| RE-I1 | safety | `MIN_RATE_AT_TARGET ≤ rateAtTarget ≤ MAX_RATE_AT_TARGET (200% APR)` after any update.                                                                                | holds (`Math.bound` in `_newRateAtTarget`) |
| RE-I2 | econ   | Rate = `curve(rateAtTarget, err)`, with `rateAtTarget/4 ≤ rate ≤ 4·rateAtTarget` (`CURVE_STEEPNESS = 4`). It is non-decreasing in utilization at a fixed state.      | open                                       |
| RE-I3 | param  | Initial `rateAtTarget` = 4% APR. Target utilization = 2/3. Adjustment speed = 50/yr. The elapsed time used per update is capped at `IRM_MAX_ELAPSED_TIME = 16384` s. | holds                                      |

---

### Formal verification (Halmos)

Checks live in `test/foundry/core/RiskEngine/halmos/LiquidationBonus.halmos.t.sol`.
Run one check with:
`FOUNDRY_PROFILE=halmos halmos --forge-build-out out-halmos --contract LiquidationBonusHalmos --function <check>`
(build first with `FOUNDRY_PROFILE=halmos forge build --ast --extra-output storageLayout metadata`).

- **Trusted, not proved:** the `mulDiv` family. The `halmos` profile remaps `@libraries/Math.sol` to `halmos/summaries/Math.sol`. There, each variant takes an exact shortcut when one applies and otherwise falls back to the original code.
- **Scope:** price fixed at 1 (`sqrtPriceX96 = 2^96`). Inputs are full width: 104-bit balances and `netPaid`, `int128` for no-revert.
- **Method:** a check over many symbolic inputs does not finish, so each property is proved region by region. `_region(bal, netPaid, req)` splits on balance versus requirement and on the sign and size of `netPaid`. Regions 0–5 partition the inputs, so a property is `proved` once all six regions pass. A region that does not finish under 55s is split again into four sub-regions (`_sub`: sign of total backable, sign of the other token's backable). A sub-region that no input can reach is proved empty by a matching `check_empty_*`.
- **Known limit:** monotonicity properties that compare two floor divisions (RE-S3, RE-L5, and the ratio curves) time out even with a constant divisor, because the solver bit-blasts 256-bit division. Finite-domain ones are proved by exhaustion instead.

### Asset accounting

- CT-A1 `totalAssets() = s_depositedAssets + s_assetsInAMM + unrealizedInterest`. (holds)
- CT-A2 `totalSupply() = _internalSupply + s_creditedShares`. (holds)
- CT-A3 `s_depositedAssets ≥ 1`. It is initialized to 1 and withdrawals can't drain it. (stale?)
- CT-A4 Share price is non-decreasing, except for protocol loss realized in a liquidation and rounding in the protocol's favour. (stale?)
- CT-A5 Deposits and mints are ≤ `type(uint104).max` assets. (holds)

### Interest

- CT-I1 `borrowIndex` starts at 1e18 and is non-decreasing.
- CT-I2 For any user with `netBorrows > 0`, `userBorrowIndex ≤ borrowIndex`.
- CT-I3 Interest owed is `netBorrows·(borrowIndex − userBorrowIndex)/userBorrowIndex`, rounded against the borrower.
- CT-I4 `unrealizedGlobalInterest ≤ Σ_users interestOwed`. It is reduced when interest is paid or burnt for an insolvent user.
- CT-I5 After `_accrueInterest`, `userBorrowIndex = borrowIndex`, unless the user is insolvent and can't pay.
- CT-I6 `assetsAndInterest` agrees with what `_accrueInterest` would charge, so the margin view and settlement agree (feeds RE-M1).

### Credited shares

- CT-C1 `s_creditedShares` increases only when a long position opens and decreases only when it closes.
- CT-C2 On close, if `creditDelta > s_creditedShares`, the owner pays the difference as a rounding haircut of a few wei per position.
- CT-C3 A loan plus a credit in the same token never creates value: see RE-M2. `netBorrows` nets to zero for the pair.

### Transfers and withdrawals

- CT-W1 An account with open legs can't `transfer` or `transferFrom` shares.
- CT-W2 An account with open legs can withdraw only with `positionIdList`, and only if it stays solvent afterwards (RE-O2 tick set).

## PanopticPool (spot-checked)

### Entry points

- PP-E1 Every user action goes through `dispatch` or `dispatchFrom`. `dispatchFrom` requires operator approval.
- PP-E2 One dispatch can run many actions and may pass through insolvent states in between, but it must end solvent at the RE-O2 tick set, with the buffer applied.

### Liquidation, force exercise and settle gate (`dispatchFrom`)

- PP-L1 Liquidation requires insolvency at **all four** ticks (spot, twap, latest, current), with no buffer and premia counted as collateral.
- PP-L2 If the account is solvent at all four ticks, only settle (same list) or force exercise (list one shorter) is allowed, and only when `|cur − twap| ≤ tickDeltaDispatch`. The callee must remain solvent afterwards.
- PP-L3 Mixed results (solvent at some ticks but not all) revert. Liquidation and exercise are both refused.
- PP-L4 A liquidation closes every position of the liquidatee.
- PP-L6 **Obligation from RE-L11.** Every `netPaid` slot the pool passes to `getLiquidationBonus` satisfies `|netPaid_t| < 2^126`. Expected to hold because deposits are capped at 2^104 and Uniswap amounts are bounded by real token supply. Not yet argued formally.
- PP-L5 If the bonus exceeds the liquidatee's collateral, the shortfall is minted to the liquidator as protocol loss. This is bounded by RE-L1 and RE-L8.

### Positions

- PP-P1 Open legs per account ≤ `riskParameters.maxLegs()` (default 26), enforced in `_updatePositionsHash`.
- PP-P2 The removed/net liquidity spread is ≤ `MAX_SPREAD` at mint (long) and at burn (short).
- PP-P3 On burn, sellers return exactly `shortAmounts` and buyers add back exactly the removed liquidity.
- PP-P4 Commission is split between protocol and builder per `PROTOCOL_SPLIT` and `BUILDER_SPLIT`. The builder wallet is derived deterministically.

### Premium

- PP-S1 Sellers never receive unsettled premium (premium not yet collected from Uniswap or paid by longs).
- PP-S2 Within a chunk, sellers share settled premium in proportion to their liquidity, scaled by `min(settled/owed, 1)`.
- PP-S3 Premium accounting survives keep-open settles. `grossPremiumLast` stays consistent (ticket #432).

## SFPM

- SF-1 Fees collected in any operation are ≤ the fees earned by the caller's owned liquidity.
- SF-2 Fees paid to a user are ≤ the fees earned by that user's liquidity.

## Cross-contract

- X-1 Every solvency decision in one transaction uses one consistent oracle snapshot.
- X-2 `PositionBalance` utilization fields are written once at mint and never change. RE-M9 depends on this.
- X-3 The `RiskEngine` is a pure function of its inputs plus CT views: no storage writes outside guardian `lockPool`, `unlockPool` and `collect`.
