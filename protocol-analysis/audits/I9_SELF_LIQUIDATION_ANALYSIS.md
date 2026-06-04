# I9 Self-Liquidation Analysis

Date: 2026-05-18

Scope:

- `contracts/RiskEngine.sol`
- `contracts/PanopticPool.sol`
- `contracts/CollateralTracker.sol`
- `contracts/libraries/PanopticMath.sol`
- `test/foundry/core/Misc.t.sol`

Question: can a single actor controlling both borrower and liquidator make positive combined PnL from opening a position, becoming liquidatable, and self-liquidating, valued at the protocol TWAP?

## Assumptions

- "Combined PnL" means borrower wallet plus borrower CT assets plus liquidator wallet plus liquidator CT assets, converted at the TWAP used by liquidation.
- Uniswap manipulation costs, fees, and external inventory costs are attacker costs unless a vector can inflate `req - bal` without actually moving the market or paying interest.
- The analysis is based on the current working tree. In this tree `getLiquidationBonus` takes `creditAmounts` and adds them back to `paid` to avoid credit double-counting.
- The target invariant is I9 only. Some paths can still create PLP/protocol loss, but that is not by itself an I9 violation if the combined borrower plus liquidator loses more value.

## Summary Table

| Vector                                 | Severity                                     |                                                   Est. leak (% notional) | Net of costs?                                   |
| -------------------------------------- | -------------------------------------------- | -----------------------------------------------------------------------: | ----------------------------------------------- |
| A. TWAP/current premium gap            | Plausible needs PoC                          | Gross bounded by 20% of required; no confirmed net-positive construction | Unknown                                         |
| B. Internal oracle staleness           | Theoretical                                  |                                         Gross bounded by 20% of required | Likely no after sustained-price costs           |
| C. Interest dual-counting              | Refuted                                      |                                                                        0 | No                                              |
| D. Utilization-driven interest accrual | Refuted as no-loss I9 vector                 |                          0 net in model; bonus can recycle paid interest | No                                              |
| E. Credit-amount mismatch              | Refuted in current tree                      |                                                                        0 | No                                              |
| F. Cross-conversion rounding           | Refuted                                      |            0; rounding is value-conservative or 1 wei against liquidator | No                                              |
| G. MAX_BONUS crossover                 | Theoretical                                  |                                              Gross up to 20% of required | No confirmed net-positive path                  |
| H. int128 truncation                   | Theoretical                                  |                                       Only above `2^127 - 1` token units | Not practical without pathological assets       |
| I. Paired self-conversion              | Refuted by harness                           |                                             Tested combined PnL negative | No                                              |
| J. Premium-as-collateral timing        | Plausible needs PoC                          |                           Gross bounded by 20% of required, then haircut | Unknown                                         |
| K. Mint/liquidation tick mismatch      | Refuted absent real market movement          |                                                                        0 | No                                              |
| L. Pure-loan bonus recycling           | Refuted as I9, confirmed as PLP-loss surface |                         Gross bonus up to 40% of loan at max loan margin | No for same actor under required initial equity |

## Code Facts Used

- Bonus is `min(MAX_BONUS * required / DECIMALS, max(required - balance, 0))` at `RiskEngine.sol:532-536`.
- `tokenData.balance` includes short premium and credit amounts, while `getLiquidationBonus` subtracts `shortPremium` from spendable balance and adds `creditAmounts` to `paid` at `RiskEngine.sol:542-555`.
- Cross-token conversion is executed only when one token has a shortage and the other has surplus at `RiskEngine.sol:560-607`.
- Margin subtracts payable interest from balance first. Only the insolvent-interest residue is added to requirements at `RiskEngine.sol:1164-1191`.
- Liquidation eligibility requires the account to be insolvent at spot EMA, TWAP, latest internal observation, and current Uniswap tick at `PanopticPool.sol:1588-1669`.
- Liquidation computes premia at `currentTick`, margin at `twapTick`, and bonus conversion at `twapTick` at `PanopticPool.sol:1760-1816`.
- Protocol loss is materialized by minting CT shares to the liquidator when liquidatee shares cannot cover the bonus at `CollateralTracker.sol:1323-1364`.

## A. TWAP/current premium gap

1. Name: TWAP/current premium gap.

2. Mechanism: Liquidation premia are computed at `currentTick`, but margin requirements and cross-token bonus conversion use `twapTick`. A manipulated current tick can change `shortPremium` before it enters `tokenData.balance`, while the bonus still uses TWAP-priced requirements. The gap is real at `PanopticPool.sol:1760-1816`, but liquidation must still pass the four-tick insolvency gate at `PanopticPool.sol:1588-1669`.

3. Preconditions: A position whose available short premium is sensitive to current tick; enough market power to move current tick without immediately moving the internal TWAP; borrower insolvent at spot EMA, TWAP, latest, and current ticks.

4. PoC sketch:

   1. Open a short position near a range where current-tick premium accounting changes materially.
   2. Move current tick to reduce `shortPremium` credited to the borrower while keeping TWAP high enough to keep `req` elevated.
   3. Ensure the account is insolvent at all four liquidation ticks.
   4. Self-liquidate and compare combined borrower plus liquidator value at TWAP.

5. Expected leak: Gross bonus is bounded by `min(0.2 * req, req - bal)`. If the only manipulated term is short premium, the upper gross lift is at most the omitted premium until the 20% cap binds. No construction found where this lift exceeds the cost of moving spot plus the borrower's position loss.

6. Cost/gating factors: Current tick manipulation must survive the four-tick insolvency check. Burn settlement executes against the real pool path, so adverse current price movement is not just an accounting change. Third-party liquidators can take the same liquidation once the account is margin-called.

7. Severity: Plausible needs PoC. The tick-source mismatch is real, but I did not find a no-loss way to isolate it into positive combined PnL.

## B. Internal oracle staleness

1. Name: Internal oracle staleness.

2. Mechanism: The internal oracle stores an 8-slot observation queue and EMAs. New observations are epoch-gated and clamped by `MAX_CLAMP_DELTA`, so an attacker can only move TWAP by holding or repeatedly poking controlled prices. This can raise or lower `req`, but not without sustained market exposure.

3. Preconditions: Ability to maintain a displaced Uniswap price across oracle update epochs; enough position notional that a 20% of required bonus could matter; borrower insolvent at every liquidation tick.

4. PoC sketch:

   1. Open a large position whose requirement increases when TWAP moves in one direction.
   2. Hold the Uniswap price in that direction and call `pokeOracle` across multiple epochs.
   3. Once TWAP catches up, self-liquidate.
   4. Compare bonus received to the economic loss from holding the manipulated price and closing the position.

5. Expected leak: Gross bonus remains at most `0.2 * req`. If notional is `N` and requirement is approximately `rN`, gross payout is at most `0.2rN`. The manipulation must create enough adverse valuation to make the account insolvent, so the borrower-side loss is of the same order as the inflated shortfall.

6. Cost/gating factors: Sustained AMM manipulation, arbitrage leakage, Uniswap fees, oracle clamp delay, and front-running risk. Liquidation cannot use a single-block false price because the account must be insolvent at current and internal oracle ticks.

7. Severity: Theoretical. It is an oracle-manipulation cost problem, not a no-loss `req - bal` inflation path in the inspected code.

## C. Interest dual-counting

1. Name: Interest dual-counting.

2. Mechanism: The suspected dual count would be interest both lowering balance and raising requirement. Current code avoids that for solvent interest: it subtracts interest from balance and zeroes the interest requirement. It only adds interest to requirement when interest exceeds available balance, and then caps the added amount to the available balance.

3. Preconditions: Borrower with accrued interest on CT borrow state.

4. PoC sketch:

   1. Open a width-zero loan.
   2. Let interest accrue.
   3. Read `assetsAndInterest`.
   4. Call `getMargin` and inspect whether the same owed interest appears in both reduced balance and increased requirement.

5. Expected leak: 0 from dual-counting. For `interest <= balance`, `balance' = balance - interest` and `req' = req`. For `interest > balance`, `balance' = 0` and `req' = req + balance`, not `req + fullInterest`.

6. Cost/gating factors: Interest paid by the borrower is a real transfer to CT accounting before or during burn.

7. Severity: Refuted. The current code path does not double-count ordinary payable interest.

## D. Utilization-driven interest accrual

1. Name: Utilization interest spike.

2. Mechanism: An attacker can try to raise utilization to increase borrow interest, making `req - bal` larger. However, the larger shortfall comes from interest that the borrower actually owes and generally pays through share burn. For existing positions, collateral requirements use utilization stored in `PositionBalance`; a later pool-utilization spike does not freely reprice old position requirements unless the account adds a new high-utilization position and passes solvency at that higher global utilization.

3. Preconditions: Large borrow position, ability to raise CT utilization for time, and enough time for interest to accrue.

4. PoC sketch:

   1. Borrow `L` through a width-zero short.
   2. Raise pool utilization with auxiliary positions.
   3. Wait for the borrow index to increase.
   4. Self-liquidate and measure whether bonus exceeds the borrower's paid interest and lost collateral.

5. Expected leak: 0 net in the simple loan model. With initial equity `E = mL + delta` and interest `I`, liquidation shortfall is approximately `I - delta`; the bonus can recycle at most that shortfall, while the borrower paid or lost `I`. Net is at most `-delta` before fees.

6. Cost/gating factors: Capital to raise utilization, time, interest actually charged to the borrower, and third-party liquidation risk.

7. Severity: Refuted as a no-loss I9 vector. It can increase gross bonus, but the increase is tied to real interest loss.

## E. Credit-amount mismatch

1. Name: Credit mismatch.

2. Mechanism: The older concern was that a credit claim appears in `tokenData.balance` and again as negative `netPaid`, causing surplus to be overstated. Current code passes `creditAmounts` into `getLiquidationBonus` and adds it to `paid`, cancelling the negative `netPaid` representation for surplus measurement.

3. Preconditions: Width-zero long credit paired with a deficit in the other token.

4. PoC sketch:

   1. Build two otherwise identical liquidation scenarios, one with ordinary token0 collateral and one with a token0 credit of the same notional.
   2. Liquidate both.
   3. Compare liquidator gain and assert the credit branch does not pay an extra credit-sized bonus.

5. Expected leak: 0 in current tree. `surplus = (shares + credit) - (bonus + netPaid + credit)`, and for credit close `netPaid = -credit`, so the credit is counted once.

6. Cost/gating factors: None after the current credit accounting change.

7. Severity: Refuted. `test_Success_liquidationCreditAmounts_singleCountsCreditedTokenPayout` covers this and passed.

## F. Cross-conversion rounding asymmetry

1. Name: Conversion rounding asymmetry.

2. Mechanism: In the token0-shortage arm, the code adds token1 using `convert0to1` rounded down and subtracts token0 using `convert1to0RoundingUp`. The token1-shortage arm mirrors that pattern. This is conservative for the liquidator, because the asset added is rounded down and the asset removed is rounded up.

3. Preconditions: One token shortage, the other token surplus, and amounts small enough for conversion rounding to matter.

4. PoC sketch:

   1. Call `getLiquidationBonus` with a one-token deficit and a one-token surplus.
   2. Sweep small deficit/surplus values around 1 wei at multiple ticks.
   3. Compare final bonus vector value to exact rational conversion.

5. Expected leak: 0. The rounding tail is at most 1 converted wei per arm and is protocol-conservative, not attacker-positive.

6. Cost/gating factors: Complete liquidation burns all positions, so the same account cannot repeatedly harvest micro-rounding. Splitting across many accounts costs more gas than the rounding tail.

7. Severity: Refuted.

## G. MAX_BONUS crossover

1. Name: Cap crossover inflation.

2. Mechanism: Once `req - bal >= 0.2 * req`, the bonus cap binds and scales with required collateral. The attacker would need to raise `req` faster than borrower loss. For price-sensitive options, higher `req` follows real adverse price exposure; for loans, utilization used in margin is stored at mint or must be introduced by a new position that passes solvency.

3. Preconditions: Large position whose requirement can be increased after mint, and enough collateral to pass mint-time checks.

4. PoC sketch:

   1. Mint near the solvency boundary.
   2. Move price or try to alter utilization so `req` rises.
   3. Enter the cap-bound region.
   4. Self-liquidate and compare combined value.

5. Expected leak: Gross bonus can be `0.2 * req`, but the borrower must first absorb the loss that moved the account into the cap-bound region. For a pure loan minted at maximum loan margin, initial equity needed to pass a buffered mint is greater than the 40% of loan gross bonus.

6. Cost/gating factors: Initial collateral, adverse market movement, and no free repricing of old positions from later utilization.

7. Severity: Theoretical. No positive I9 construction found.

## H. int128 truncation

1. Name: int128 truncation.

2. Mechanism: The return packs `bonus` and `collateralRemaining` into `int128`. `bonus` is safe under the current cap because `0.2 * uint128.max < int128.max`. `collateralRemaining` can theoretically exceed `int128.max` if a token balance approaches `uint128.max` and paid is low or negative.

3. Preconditions: Token amounts near or above `2^127` raw units in one CT, plus a liquidation path that leaves very large positive collateral remaining.

4. PoC sketch:

   1. Use a pathological/mock asset with enormous supply and balances.
   2. Construct tokenData balance near `uint128.max`.
   3. Call `getLiquidationBonus` with low paid amounts.
   4. Observe whether positive collateral remaining wraps negative when cast to `int128`.

5. Expected leak: Not quantified for normal assets. The threshold is about `1.7e38` raw units, so ordinary ERC20 supplies and all current tests are far below it.

6. Cost/gating factors: Requires pathological token economics and huge balances; not a practical route for deployed standard assets.

7. Severity: Theoretical.

## I. Self-conversion via paired positions

1. Name: Paired self-conversion.

2. Mechanism: A borrower can be short one token and have surplus in the other, causing the conversion branch to pay the bonus in the surplus token. The conversion branch is value-preserving or conservative at TWAP and does not create value by itself.

3. Preconditions: Cross-margined account with one-token shortage and opposite-token surplus.

4. PoC sketch:

   1. Deposit only token1.
   2. Open a large token0 loan/short position.
   3. Move price until token0 side is deficient and token1 has surplus.
   4. Liquidate from an affiliate and value borrower plus liquidator at TWAP.

5. Expected leak: The existing harness observed a positive liquidator transfer but negative combined entity value. In the representative cross-collateralized run, liquidator value was `+1,117,099` token1 units, liquidatee value was `-14,588,011`, and combined borrower plus liquidator value was `-13,470,912`.

6. Cost/gating factors: Borrower absorbs the position loss; protocol loss can be emitted, but it did not overcome borrower loss in the tested construction.

7. Severity: Refuted by harness. `test_Success_loanBonusClamp_crossCollateralized_zeroBonus` now asserts combined self-liquidation PnL is non-positive.

## J. Premium-as-collateral timing

1. Name: Premium timing mismatch.

2. Mechanism: Short premium is first included in margin balance, then removed from spendable balance before comparing against `paid`, because the burn settlement already includes realized premium. That avoids direct double-counting. The remaining concern is timing: `shortPremium` is computed before burn at current tick and `premiasByLeg` from the burn are later haircut against `collateralRemaining`.

3. Preconditions: Large pending/settled premium, controllable current tick, and a liquidation with protocol loss where haircut accounting matters.

4. PoC sketch:

   1. Create a short position whose fees/premium accrue in a range controlled by the attacker.
   2. Manipulate current tick so pre-burn `shortPremium` understates or overstates the premium actually realized on burn.
   3. Liquidate and inspect `haircutPremia` output versus actual premium paid.
   4. Measure combined borrower plus liquidator value.

5. Expected leak: Gross effect is bounded by the premium discrepancy and then by the bonus cap. I did not find a construction where the discrepancy becomes combined self-profit rather than premium haircut or borrower-side loss.

6. Cost/gating factors: Requires fee generation or price movement, burn-time settlement, haircut logic, and third-party liquidation exposure.

7. Severity: Plausible needs PoC. This is the least-refuted accounting/timing surface after the credit fix.

## K. Mint check vs liquidation check tick mismatch

1. Name: Mint/liquidation tick mismatch.

2. Mechanism: Mint validates solvency through the oracle tick set selected by `_validateSolvency`, while liquidation requires insolvency at spot EMA, TWAP, latest, and current tick. A position that was safe at mint cannot become liquidatable without either market movement, oracle evolution after market movement, interest accrual, or a later account action.

3. Preconditions: Divergent oracle ticks around mint and liquidation, plus a position whose solvency flips across those ticks.

4. PoC sketch:

   1. Try to mint when current tick is favorable but TWAP is unfavorable.
   2. Avoid moving the market after mint.
   3. Attempt liquidation solely because the oracle tick set differs.

5. Expected leak: 0 absent market movement or time-based interest. If divergence is large, safe mode expands solvency checks instead of reducing them.

6. Cost/gating factors: Tick limits on mint, safe mode, post-action solvency validation, and four-tick liquidation validation.

7. Severity: Refuted absent real market movement.

## L. Pure-loan bonus recycling

1. Name: Pure-loan bonus recycling.

2. Mechanism: Pure loans can pay a liquidation bonus based on required collateral even when principal is recoverable. That can create `ProtocolLossRealized` if the borrower has insufficient post-principal equity to fund the bonus. This is an LP-loss surface, but the borrower had to post or lose the equity that made the account liquidatable.

3. Preconditions: Width-zero short loan, account close to or inside maintenance shortfall, and an affiliate liquidator.

4. PoC sketch:

   1. Deposit equity `E`.
   2. Open loan `L`.
   3. Let interest or other real loss reduce effective equity below required margin.
   4. Affiliate-liquidate and measure borrower plus liquidator.

5. Expected leak: Gross bonus for a low-util loan is approximately `0.1L - E_remaining` before the 20% cap. At max loan margin, required can be `2L` and gross cap is `0.4L`, but mint-time buffered solvency requires equity greater than that cap. The tested cross-collateralized loan scenario emitted protocol loss but still had combined borrower plus liquidator PnL below zero.

6. Cost/gating factors: Initial equity, interest/time, position loss, and third-party liquidation risk.

7. Severity: Refuted as I9. Confirmed as a separate PLP-loss accounting surface, not as positive combined self-liquidation profit in the tested cases.

## Verification

Command run:

```text
forge test --match-path test/foundry/core/Misc.t.sol --match-test 'loanBonusClamp|liquidationCreditAmounts' -vv
```

Result: 6 passed, 0 failed.

Relevant evidence:

- `test_Success_liquidationCreditAmounts_singleCountsCreditedTokenPayout` passed, covering the current credit single-counting path.
- `test_Success_loanBonusClamp_crossCollateralized_zeroBonus` passed after adding an assertion that borrower plus liquidator combined value is non-positive at oracle TWAP.
- The representative cross-collateralized run emitted protocol loss in CT0, but combined borrower plus liquidator value remained negative.

## Conclusion

I did not confirm an I9 violation in the current tree. The strongest remaining PoC targets are the TWAP/current premium timing surfaces, especially where pre-burn `shortPremium` and burn-time `premiasByLeg` diverge. Credit double-counting and ordinary interest dual-counting are refuted in the current implementation.

The important distinction is that protocol loss can occur without implying self-liquidation profit. The cross-collateralized tests show a liquidator can receive value, including minted CT shares, while the borrower side loses substantially more when valued at the liquidation TWAP.

Facts that would change this assessment:

- A premium construction where `shortPremium` can be understated without equivalent borrower loss or haircut.
- A way to apply a high stored utilization to a large existing portfolio without passing solvency at that higher requirement.
- A deployed asset or configuration where raw token amounts can approach the `int128` packing boundary.
