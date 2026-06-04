# Pure Loan Liquidation Economics Audit

Date: 2026-05-11

Scope:

- `RiskEngine.getLiquidationBonus`
- width-zero loan and credit margin paths in `RiskEngine`
- liquidation call path in `PanopticPool`
- liquidation settlement in `CollateralTracker`

This report analyzes the current working tree. In this tree, `getLiquidationBonus` uses a required-collateral-based cap and does not consume `loanAmounts`.

## Executive Summary

Pure loan and loan/credit portfolios are not economically equivalent to option portfolios, but the current liquidation bonus formula treats their required collateral as a valid bonus base. That creates materially different economics from the older loan-net clamp described in stale tests and prior notes.

Main verdict:

- Standalone credits are not a liquidation risk by themselves because they create no requirement.
- Standalone loans can become liquidatable through interest or utilization-dependent maintenance changes. The current formula can pay a bonus from the borrower's remaining real equity, and can socialize bonus shortfall even when principal repayment itself is covered.
- Loan-heavy accounts can recover a large part of their margin/interest through a self- or affiliate-liquidation path because bonus is based on `required`, not on non-loan equity.
- Credit legs are counted as margin balance before burn and also appear as negative `netPaid` when closed. In cross-token liquidation math, this can double-count credit claims when measuring surplus available for conversion.
- `loanAmounts` is currently dead input to `getLiquidationBonus`; the call path still computes it, but it no longer constrains the bonus.

Findings:

| ID     | Severity | Title                                                                                                                             |
| ------ | -------- | --------------------------------------------------------------------------------------------------------------------------------- |
| PLL-01 | High     | Required-based bonus lets pure loan liquidations pay out loan-margin deficit, not non-loan equity                                 |
| PLL-02 | High     | Bonus can create protocol loss even when pure loan principal is fully repayable                                                   |
| PLL-03 | High     | Credit claims can be double-counted in cross-token conversion during liquidation                                                  |
| PLL-04 | Medium   | `loanAmounts` is computed and passed but ignored, leaving stale tests/comments and no loan-specific invariant                     |
| PLL-05 | Medium   | Cross-token loan portfolios can convert surplus loan-funded balance into bonus in the other token                                 |
| PLL-06 | Medium   | Delayed swaps use option seller collateral ratio, not loan maintenance margin, and are more price-sensitive than standalone loans |
| PLL-07 | Low      | Current tree cannot run tests because `RiskEngine.sol` has a malformed NatSpec parameter                                          |

## Current Mechanics

### Constants and margin

`MAINT_MARGIN_RATE = 1_000_000` and `MAX_BONUS = 2_000_000`, both scaled by `DECIMALS = 10_000_000`. At low utilization, standalone loans require 110% of borrowed notional. At high utilization, `_sellCollateralRatio` ramps the loan margin up to 100%, so loans can require up to 200% of borrowed notional.

For a width-zero short leg:

```text
loan_margin = _sellCollateralRatio(poolUtilization, MAINT_MARGIN_RATE)
required = ceil(loan_notional * (1 + loan_margin))
```

For a width-zero long leg:

```text
required = 0
creditAmounts += credit_notional
```

`getMargin` adds `creditAmounts` to the account's available balance. It also subtracts accrued interest from the share-derived balance before building `tokenData`.

### Liquidation bonus

The current `getLiquidationBonus` formula is:

```text
bonus_i = min(MAX_BONUS * required_i / DECIMALS, max(required_i - balance_i, 0))
```

Then it computes:

```text
paid_i = bonus_i + netPaid_i
collateralRemaining_i = balance_i - paid_i
```

If one token has a shortage and the other has surplus, the function shifts bonus between token sides using oracle conversion.

Important: `loanAmounts` is accepted by the function signature but ignored by the implementation.

### Pure loan close

Closing a short loan produces positive `netPaid` in the borrowed token because the liquidatee repays principal. Ignoring fees and rounding:

```text
netPaid = loan_notional
balance_before_liquidation = loan_notional + real_equity
collateralRemaining_before_bonus = real_equity
collateralRemaining_after_bonus = real_equity - bonus
```

This is the central distinction from option liquidation: principal can be repayable while the bonus itself creates the protocol loss.

## Findings

### PLL-01 | High | Required-based bonus lets pure loan liquidations pay out loan-margin deficit, not non-loan equity

Affected code:

- `RiskEngine.sol` computes `MAX_BONUS * required` and `required - balance` at lines 529-534.
- `RiskEngine.sol` leaves `loanAmounts` unnamed/unused at lines 506-513.
- `PanopticPool.sol` still computes and passes `loanAmounts` at lines 1803-1815.

For a single-token pure loan with notional `L`, real equity `E`, and loan maintenance margin `m`:

```text
balance = L + E
required = (1 + m) * L
deficit = required - balance = mL - E
bonus = min(0.2 * (1 + m)L, max(mL - E, 0))
```

At low utilization, `m = 10%`, so the cap is `22% of L`, while the maximum loan deficit is only `10% of L` as long as principal is still present. The cap never binds. The liquidator receives exactly the maintenance deficit:

```text
bonus = 0.1L - E
```

Concrete example at 1:1 asset/share price:

```text
loan L = 1,000
real equity E = 40
required = 1,100
balance = 1,040
deficit = 60
bonus = min(220, 60) = 60
after repaying principal and bonus: 1,040 - 1,000 - 60 = -20
```

The account had enough balance to repay principal. The protocol loss is caused by paying the bonus.

This is not the older loan-net invariant. A loan-net invariant would cap bonus by non-loan equity, for example by requiring `bonus <= f(balance - loan)` before and after cross-token conversion. The current formula instead permits a bonus that scales with loan notional.

Impact:

- The bonus can be much larger than the borrower's remaining real equity.
- Borrowers can recover accrued interest or maintenance margin via affiliate liquidation once the account becomes liquidatable.
- The economics no longer match tests/comments that describe a loan-balance clamp.

Recommendation:

- Do not use a per-token post-close-equity cap as the primary invariant. It prevents PLP-funded bonus in same-token loans, but it also zeroes the incentive for cross-margined loans where the borrowed token is short and the account has surplus value in the other token.
- Instead, separate liquidator reimbursement from liquidation profit. A negative bonus in the borrowed token and a positive payout in the surplus token can be value-neutral reimbursement for missing principal. The cap should apply to the net value of the final bonus vector:

```text
netLiquidatorProfit = value(positive bonus slots) - value(abs(negative bonus slots))
```

- A minimal no-PLP-loss invariant is:

```text
netLiquidatorProfit <= globalPostCloseEquity
globalPostCloseEquity = value(max(balance_i - max(netPaid_i, 0), 0) across both tokens)
```

- A stricter incentive cap is:

```text
netLiquidatorProfit <= MAX_BONUS * globalPostCloseEquity / DECIMALS
```

- Apply the cap after cross-token conversion, not just before.
- If the required-based formula is intentional, document explicitly that pure loan liquidation bonus may be paid from PLPs once real equity falls below the bonus amount.

### PLL-02 | High | Bonus can create protocol loss even when pure loan principal is fully repayable

Affected code:

- `CollateralTracker.settleLiquidation` transfers the liquidatee's remaining shares and mints shares for any bonus shortfall at lines 1323-1364.

For pure loans, the protocol's first objective is principal recovery. If `balance >= loan_notional`, principal is covered. Under the current formula, the bonus can still exceed real equity.

At low utilization:

```text
bonus = 0.1L - E
real collateral after principal repayment = E
protocol loss from bonus occurs when bonus > E
0.1L - E > E
E < 0.05L
```

So for a loan requiring 10% maintenance margin, the lower half of the liquidation zone creates protocol loss solely from the bonus.

At high utilization, `m` can reach 100%:

```text
required = 2L
bonus cap = 0.4L
if E = 0, bonus = min(0.4L, 1.0L) = 0.4L
```

A fully principal-covered but zero-equity borrower can still create a 40% of notional bonus claim.

Impact:

- Liquidators are incentivized, but PLPs can fund the incentive even when loan principal was recoverable.
- This turns liquidation from a recovery mechanism into a value transfer from PLPs to the liquidator in deeply under-margin but principal-covered states.
- Affiliate/self-liquidation can recycle interest previously paid by the borrower back out as liquidation bonus.

Recommendation:

- Cap the liquidator's net profit to global post-repayment equity, not to the local token's post-repayment equity.
- Keep cross-token reimbursement for principal substitution separate from profit. A liquidator who supplies missing token0 should be reimbursed in token1 if the account has token1 surplus.
- Add an accounting-level assertion in tests: for pure loans with no options and no premium, protocol loss should be impossible whenever global post-close equity can cover the chosen net-profit cap.

### PLL-03 | High | Credit claims can be double-counted in cross-token conversion during liquidation

Affected code:

- `RiskEngine._getMargin` adds `creditAmounts` to balance at lines 1172-1173.
- Credit close produces negative `netPaid` through the burn settlement path.
- `RiskEngine.getLiquidationBonus` measures surplus as `balance_surplus - paid_surplus`, where `paid = bonus + netPaid`, at lines 562-585.

Credit positions are correctly counted as assets for solvency: a width-zero long credit is a claim recoverable on close. However, liquidation bonus math receives:

```text
balance = share_balance + creditAmounts
netPaid = -creditAmounts
```

Then cross-token conversion computes available surplus as:

```text
balance - paid
= (share_balance + credit) - (bonus - credit)
= share_balance + 2 * credit - bonus
```

That can overstate conversion capacity by one credit notional.

Concrete 1:1 example:

```text
token1 credit C = 100
token1 share balance after opening credit = 0
tokenData1.balance = 100
burning credit gives netPaid1 = -100

token0 has a liquidation shortage of 150
bonus1 starts at 0
conversion sees token1 surplus = 100 - (-100) = 200
conversion can add 150 to bonus1

actual token1 available after burn = 100
settling bonus1 = 150 transfers 100 and mints/protocol-loses 50
getLiquidationBonus reports token1 collateralRemaining = 50
```

Impact:

- Cross-token conversion can hide protocol loss from `collateralRemaining`.
- `haircutPremia` sees overstated remaining collateral and may not claw back premium that should offset the loss.
- This affects delayed swaps and any loan/credit portfolio with a deficit in one token and a credit claim in the other.

Recommendation:

- Pass credit amounts separately into `getLiquidationBonus`, or pass a balance measure that excludes credit claims when `netPaid` already includes credit repayment.
- Alternatively, recompute liquidation surplus from actual post-burn balances, not pre-burn `tokenData`.
- Add a regression test where a token1 credit is used to convert a token0 shortage and assert that reported `collateralRemaining` matches actual settleable collateral after burn.

### PLL-04 | Medium | `loanAmounts` is computed and passed but ignored, leaving stale tests/comments and no loan-specific invariant

Affected code:

- `PanopticMath.getTotalLoanAmounts` is still documented as a liquidation clamp helper.
- `PanopticPool._liquidate` still computes `loanAmounts`.
- `RiskEngine.getLiquidationBonus` ignores the parameter.
- `Misc.t.sol` still has tests/comments describing the removed clamp.

The current tree has two conflicting models:

1. The call path computes loan amounts and older tests describe a clamp that prevents loan-inflated balances.
2. The implementation ignores loan amounts and instead uses `required` as the bonus base.

This is an audit risk because reviewers and test authors can read the stale helper and assume the invariant still exists.

Recommendation:

- Either restore use of `loanAmounts` or remove it from the public interface and all call sites.
- Update the old loan bonus tests to assert the new intended invariant.
- Add NatSpec stating the exact pure-loan liquidation policy.

### PLL-05 | Medium | Cross-token loan portfolios can convert surplus loan-funded balance into bonus in the other token

Affected code:

- Cross-token conversion in `getLiquidationBonus` at lines 562-585.

Independent two-token loan portfolios apply the same required-based formula per token. If one side is short and the other side has surplus, the conversion block can increase the surplus-side bonus.

Because `loanAmounts` is ignored, the surplus-side balance can include loan proceeds. The function does not distinguish:

```text
surplus funded by external deposit
surplus funded by borrowed notional
surplus funded by a credit claim
```

Impact:

- A deficit in token0 can be paid as bonus in token1 even when token1 surplus is loan-funded.
- This is bounded by reported surplus, but reported surplus may itself be inflated by credits as described in PLL-03.

Recommendation:

- Apply a post-conversion cap to the net value of the final bonus vector, not to each token independently.
- For cross-token conversion, allow reimbursement of missing principal from the surplus token, but cap any profit above reimbursement by aggregate post-repayment equity excluding loan proceeds and excluding credit claims already represented in `netPaid`.

### PLL-06 | Medium | Delayed swaps use option seller collateral ratio, not loan maintenance margin, and are more price-sensitive than standalone loans

Affected code:

- `_computeDelayedSwap` uses `SELLER_COLLATERAL_RATIO + DECIMALS` at lines 2106-2110.
- Standalone loans use `MAINT_MARGIN_RATE` through `_sellCollateralRatio` at lines 1470-1480.

A delayed swap is a width-zero short loan in one token paired with a width-zero long credit in the other token. It is pure loan/credit exposure, but the required amount is:

```text
required = max((1 + seller_ratio) * loan - converted_credit, 1)
```

At low utilization, seller ratio is 20%, while standalone loan maintenance margin is 10%. The delayed-swap requirement is also price-sensitive because `converted_credit` is valued at `atTick`.

Impact:

- Delayed swaps can become liquidatable through oracle price movement, unlike same-token standalone loans.
- The liquidation bonus scales with the delayed-swap requirement. If the credit leg devalues, required collateral can grow quickly.
- Combined with PLL-03, adverse price movement can trigger a deficit in the loan token while the credit token is over-counted as conversion surplus.

Recommendation:

- Decide whether delayed swaps should use loan maintenance margin or seller option margin. If seller margin is intentional, document that delayed swaps are risked as synthetic token-transfer/options-like exposure.
- Add tests for delayed swap liquidation at favorable, neutral, and adverse oracle ticks.

### PLL-07 | Low | Current tree cannot run tests because `RiskEngine.sol` has a malformed NatSpec parameter

Validation attempted:

```text
forge test --match-test 'loanBonusClamp' -vv
```

Result:

```text
Error (3881): Documented parameter "The" not found in the parameter list of the function.
contracts/RiskEngine.sol:497:5
```

Cause:

```solidity
/// @param  The net loan amounts. Not consumed by the current bonus formula; reserved for future use.
...
LeftRightUnsigned
```

Recommendation:

- Name the parameter in implementation NatSpec and function signature, or remove the `@param` line.
- Re-run the loan/liquidation tests after the compile blocker is fixed.

## Scenario Analysis

### Scenario A: standalone loan, low utilization

Assumptions:

```text
loan L = 1,000
loan margin m = 10%
real equity E = 40
price = 1:1
no premium
no credit
```

Computed:

```text
balance = 1,040
required = 1,100
bonus = 60
netPaid = 1,000
collateralRemaining = -20
```

Interpretation:

- Principal is fully repayable.
- The liquidation bonus creates protocol loss.
- The liquidator receives more than remaining real equity.

### Scenario B: standalone loan, high utilization

Assumptions:

```text
loan L = 1,000
loan margin m = 100%
real equity E = 0
```

Computed:

```text
balance = 1,000
required = 2,000
deficit = 1,000
bonus cap = 400
bonus = 400
netPaid = 1,000
collateralRemaining = -400
```

Interpretation:

- Principal is exactly repayable.
- PLPs fund a liquidation bonus equal to 40% of loan notional.

### Scenario C: standalone credit

Assumptions:

```text
credit C = 100
no loan
no options
```

Computed:

```text
required = 0
bonus = 0
```

Interpretation:

- A standalone credit should not be liquidatable from the loan/credit mechanics.
- Credit only becomes relevant when paired with another token deficit or loan exposure.

### Scenario D: cross-token credit conversion

Assumptions:

```text
token1 credit C = 100
token1 shares after credit open = 0
token0 liquidation shortage after local bonus = 150
price = 1:1
```

Computed by current formula:

```text
tokenData1.balance = 100
netPaid1 = -100
reported token1 surplus = 200
bonus1 can increase by 150
actual token1 available after burn = 100
settlement shortfall = 50
```

Interpretation:

- The credit claim is counted once in `tokenData.balance` and once through negative `netPaid`.
- Reported collateral remaining can disagree with actual settleable collateral.

### Scenario E: delayed swap

Assumptions:

```text
token0 loan L0 = 1,000
token1 credit C1 = 100
seller ratio = 20%
price = 1:1
```

Computed margin requirement:

```text
required0 = 1.2 * 1,000 - 100 = 1,100
required1 = 0
```

If token1 devalues in token0 terms, `converted_credit` falls and `required0` rises. The account can become liquidatable from oracle movement even with no width-positive option legs.

## Recommended Test Plan

Add pure-function tests for `getLiquidationBonus`:

- `test_pureLoan_bonusEqualsMaintenanceDeficit_lowUtil`
- `test_pureLoan_bonusCanExceedRealEquity`
- `test_pureLoan_highUtil_bonusCreatesProtocolLoss`
- `test_twoTokenLoans_crossConversionUsesLoanFundedSurplus`
- `test_creditConversion_doesNotDoubleCountCredit`
- `test_delayedSwap_adverseTick_bonusAndRemainingCollateral`

Add end-to-end Foundry tests:

- Open a single-token pure loan, accrue interest until real equity is below half the maintenance margin, liquidate, and assert protocol loss is caused by bonus.
- Open a high-utilization loan, accrue to zero real equity, liquidate, and assert bonus mint/dilution path.
- Open token0 loan plus token1 credit delayed swap, move oracle price, liquidate, and compare `collateralRemaining` against actual post-burn `CollateralTracker` balances.
- Repeat delayed swap with credit value above, equal to, and below the loan-side requirement.

Regression invariants:

```text
For pure loan portfolios with no premium:
if balance_i >= positiveNetPaid_i and bonus_i > balance_i - positiveNetPaid_i,
then settlement must record protocol loss equal to the excess.

For credit portfolios:
reported collateralRemaining_i must not exceed actual post-burn settleable collateral after accounting for bonus.

For loan-aware liquidation:
bonus_i after all cross-token conversion must satisfy the chosen real-equity cap.
```

## Mitigation Options

Option 1: restore loan-net bonus cap.

```text
cap_i = MAX_BONUS * max(balance_i - loanAmounts_i, 0) / DECIMALS
bonus_i = min(bonus_i, cap_i)
```

Apply this after cross-token conversion as well. This is closest to the older comments/tests.

Option 2: cap by global post-close real equity.

```text
globalPostCloseEquity = value(max(balance_i - max(netPaid_i, 0), 0) across both tokens)
netLiquidatorProfit = value(positive bonus slots) - value(abs(negative bonus slots))
netLiquidatorProfit <= globalPostCloseEquity
```

This directly prevents the bonus from creating protocol loss when the portfolio has enough aggregate value after principal repayment. It still permits cross-token reimbursement when the borrowed token is short. A percentage cap can be layered on top:

```text
netLiquidatorProfit <= MAX_BONUS * globalPostCloseEquity / DECIMALS
```

Option 3: normalize credit accounting.

Pass `creditAmounts` or a `creditAdjustedBalance` into `getLiquidationBonus` and ensure each credit claim is counted exactly once:

```text
surplus_i = share_balance_i_after_burn - bonus_i
```

or equivalently:

```text
surplus_i = tokenDataBalance_i - creditAmounts_i - bonus_i - positiveNonCreditPaid_i
```

Option 4: accept required-based economics.

If the required-based formula is desired, the protocol should document that pure loan liquidations may mint/dilute PLPs to pay a bonus even when principal is covered, and tests should assert that behavior explicitly.

## Open Questions

- Is the required-based cap intended to replace the loan-net clamp, or is the current unused `loanAmounts` parameter an intermediate state?
- Should delayed swaps be risked as loan exposure (`MAINT_MARGIN_RATE`) or synthetic transfer/option exposure (`SELLER_COLLATERAL_RATIO`)?
- Should liquidation bonus ever be allowed to create protocol loss for a pure loan when principal is fully repayable?
- Should `haircutPremia` consume actual post-burn balances instead of `collateralRemaining` from pre-burn `tokenData`?
