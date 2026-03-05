# Loan/Credit (width==0) System Audit Prompt

You are a senior Solidity security researcher performing an exhaustive audit of the loan/credit position system — all positions where `tokenId.width(leg) == 0`.

Scope restriction (hard):

- Analyze ONLY files under `contracts/` (recursive).
- Ignore anything outside `contracts/`.
- If you reference a file outside `contracts/`, mark it "out of scope" and do not rely on it for conclusions.

## Objective

Exhaustively evaluate correctness, solvency implications, and edge cases of width==0 positions:

1. Loan positions (width==0, isLong==0): collateralized borrows that mint CT shares without Uniswap interaction
2. Credit positions (width==0, isLong==1): token reservations that burn CT shares without Uniswap interaction
3. Composite strategies: loan/credit legs paired with width>0 option legs or with each other
4. Solvency and liquidation correctness for all width==0 configurations
5. Interest accrual correctness for loans and credits
6. Protocol health impact: can width==0 positions create systemic risk?

## Assumptions

- Full MEV adversary who can choose position sizes, strikes, tokenTypes, optionRatios, and leg combinations.
- Attacker can control multiple accounts.
- Attacker can combine width==0 legs with width>0 legs in the same tokenId (up to 4 legs).
- Attacker can pair width==0 legs as risk partners via the TokenId partner mechanism.
- The width==0 system skips Uniswap entirely — any assumption about Uniswap-backed state (liquidity, fees, premium) does not apply.

## Background Context

### What Happens When width==0

**SFPM (V3:835-906, V4:791-873):**

- Width==0 legs skip `_createLegInAMM` entirely — no Uniswap `mint`/`burn`/`collect`/`swap`.
- No `s_accountLiquidity` update, no fee tracking, no premium accumulator updates.
- `collectedByLeg[leg]` = 0 for width==0 legs.
- The leg contributes only to `itmAmounts` (for optional ITM swap): negative sign for loans (isLong==0), positive for credits (isLong==1).
- The `PositionTooLarge` check (`amount0/amount1 > int128.max - 4`) does NOT include width==0 legs — they don't contribute to the SFPM's amount accumulators.

**PanopticMath.getAmountsMoved (PM:722-753):**

- When width==0, the width is transiently patched to 2 (`tokenId.addWidth(2, legIndex)` at PM:735) to compute a synthetic notional value.
- This gives a tick range of `strike ± 1*tickSpacing`.
- Ceiling rounding is ALWAYS used for width==0 (`!hasWidth` forces the round-up branch at PM:745).
- The patched width is never stored — only used for accounting.

**PanopticPool:**

- Width==0 legs are skipped in ALL premium-related code:
  - `_mintOptions` premium accumulation (PP:551)
  - `_updateSettlementPostMint` (PP:1160)
  - `_updateSettlementPostBurn` (PP:1290)
  - `_getPremia` (PP:2205)
- Width==0 legs ARE included in `computeExercisedAmounts` (via `getAmountsMoved`) — they drive collateral settlement in CT.
- Width==0 isLong==0 legs are aggregated into `loanAmounts` via `getTotalLoanAmounts` (PM:808) for liquidation bonus clamping (PP:1726).

**CollateralTracker settlement:**

- **Loan (isLong==0)**: `shortAmount = loanNotional`, `longAmount = 0`, `ammDeltaAmount = 0`.
  - `netBorrows = shortAmount = loanNotional`
  - `tokenToPay = 0 - loanNotional = -loanNotional` (negative → CT mints shares to user)
  - User receives CT shares without depositing tokens. `s_assetsInAMM += shortAmount`.
  - Interest accrues on the loan via `s_interestState[owner]`.
- **Credit (isLong==1)**: `longAmount = creditNotional`, `shortAmount = 0`, `ammDeltaAmount = 0`.
  - `netBorrows = -creditNotional`
  - `tokenToPay = +creditNotional` (positive → CT burns user's shares)
  - User surrenders CT shares. `s_creditedShares += creditDelta`.

### Collateral Requirements (RiskEngine)

**Isolated (no partner):**

- Loan (width==0, isLong==0): `120% of notional` — `(MAINT_MARGIN_RATE + DECIMALS) / DECIMALS` where `MAINT_MARGIN_RATE = 2_000_000` (RE:1422-1430)
- Credit (width==0, isLong==1): `0` (RE:1434)

**Partnered composite strategies (RE:1607-1715):**

| Strategy              | Legs                           | Computation                          | Function                                     |
| --------------------- | ------------------------------ | ------------------------------------ | -------------------------------------------- |
| Prepaid Long Option   | width>0 long + credit          | Option req at 100% utilization       | `_computeCreditOptionComposite` (RE:2001)    |
| Cash-Secured Option   | width>0 short + credit         | Option req at 100% utilization       | `_computeCreditOptionComposite` (RE:2001)    |
| Upfront Short Option  | width>0 short + loan           | short req + loan req (sum)           | `_computeLoanOptionComposite` (RE:1984-1991) |
| Option-Protected Loan | width>0 long + loan            | max(long req, loan req)              | `_computeLoanOptionComposite` (RE:1984-1991) |
| Delayed Swap          | loan + credit (diff tokenType) | max(loan\*120% - convertedCredit, 1) | `_computeDelayedSwap` (RE:2030-2074)         |

Partner matching requires: same `asset(leg)` and same `optionRatio(leg)` (RE:1602-1606).

**Credit amounts in margin** (RE:1336-1345, RE:1186-1187):

- Credit legs' notional is added to the user's apparent balance (`balance0 += creditAmounts.rightSlot()`, etc.).
- This effectively reduces the margin requirement by the credit amount.

**Liquidation bonus clamping** (RE:537-548):

- `getTotalLoanAmounts` (PM:808) sums all width==0 isLong==0 notionals.
- Bonus is clamped so that `bonus/MAX_BONUS + loanAmounts <= balance`, preventing the loan-inflated balance from being entirely extractable as a liquidation bonus.

### Other width==0 Properties

- Force exercise is blocked for width==0 legs: `validateIsExercisable` (TokenId:526) returns 0 for positions with only width==0 long legs.
- Force exercise fee computation (`getExerciseFee`, RE:428) skips width==0 legs.
- `validate()` (TokenId:473) does NOT reject width==0 — it is a legal configuration.
- No minimum/maximum size enforced specifically for width==0 legs (not bounded by SFPM's `PositionTooLarge`).

## Deliverables (strict order)

### A) Loan Position (width==0, isLong==0) Deep Dive

#### A.1 Loan Lifecycle Correctness

Trace the complete loan lifecycle and verify correctness at each step:

1. **Mint (borrow)**: User creates a loan leg → CT mints shares → `s_assetsInAMM` increases → interest starts accruing.

   - Are the minted shares exactly proportional to the loan notional?
   - Is the share price unaffected by the loan creation? (Since `totalAssets += s_assetsInAMM` and `totalSupply += mintedShares`, does the ratio stay constant?)
   - Does `s_assetsInAMM` correctly reflect the "virtual" deployment (no actual tokens left the CT)?

2. **Hold (accrue interest)**: Interest accrues on `netBorrows` via borrowIndex.

   - Is the interest formula correct for loans? (Same formula as for option sellers who borrow liquidity?)
   - Can the user avoid interest by closing and re-opening the loan? (Interest is settled at burn via `_accrueInterest`.)
   - What happens if the interest exceeds the user's collateral? (Insolvency → liquidation path.)

3. **Burn (repay)**: User closes the loan → CT burns shares → `s_assetsInAMM` decreases → interest settled.

   - On burn: `shortAmount = loanNotional`, `longAmount = 0`, but now `ammDeltaAmount` reflects the actual tokens received from SFPM (which is 0 for width==0). So `tokenToPay = 0 - (-loanNotional) = +loanNotional`.
   - Wait — on burn, the signs flip. Verify: does the user pay back the correct amount? Is interest included?
   - Does `s_assetsInAMM` decrease by exactly the amount it increased at mint?
   - What about the interest component — does it flow to `s_depositedAssets` correctly?

4. **Liquidation**: Liquidator closes all positions including loan legs.
   - The loan leg's `shortAmount` must be covered by the liquidator (they provide the tokens).
   - The liquidation bonus is clamped by `loanAmounts` (RE:537-548). Verify this clamping is correct.
   - Can the liquidation bonus ever exceed the non-loan portion of the balance?
   - After liquidation, are `s_assetsInAMM` and other accounting variables consistent?

#### A.2 Loan Position Size Bounds

- Width==0 legs bypass the SFPM `PositionTooLarge` check. What is the effective maximum loan size?
- The notional is computed via `getAmountsMoved` with synthetic width=2. For extreme strikes (near MIN/MAX_TICK) and large `positionSize * optionRatio`, can the notional overflow?
- Can an attacker create a loan so large that `s_assetsInAMM` overflows its uint128 storage?
- Can an attacker create a loan larger than `s_depositedAssets`, effectively borrowing more than the pool has?

#### A.3 Loan Interest Accounting

- Loans increase `netBorrows` in `s_interestState`. Interest accrues via `borrowIndex`.
- Can a user manipulate the timing of `_accrueInterest` to minimize interest paid?
- What happens if `unrealizedGlobalInterest` from loan interest exceeds the 106-bit storage in MarketState?
- Do loans correctly increase pool utilization (`s_assetsInAMM / totalAssets`)? This affects the interest rate for ALL borrowers.

### B) Credit Position (width==0, isLong==1) Deep Dive

#### B.1 Credit Lifecycle Correctness

Trace the complete credit lifecycle:

1. **Mint (deposit credit)**: User creates a credit leg → CT burns shares → `s_creditedShares` increases.

   - Does the user need sufficient shares to burn? What happens if they don't?
   - Is `s_creditedShares` increase consistent with the shares burned?
   - Does the credit affect `s_assetsInAMM`? (`longAmount` in settlement — trace this.)
   - What about `s_depositedAssets`? Does it decrease or stay the same?

2. **Hold**: Credit sits in `s_creditedShares`. The user's apparent balance in margin calculations increases by the credit notional (RE:1186-1187).

   - Does the user earn interest on the credited amount? (They gave up shares, which are backed by assets. If the pool earns interest, does the credit holder benefit?)
   - Can the credit's effective value change between mint and burn due to share price movement?

3. **Burn (reclaim credit)**: User closes the credit leg → CT mints shares back → `s_creditedShares` decreases.
   - Are the shares minted back the same as the shares burned? Or does the share price difference create a gain/loss?
   - ROUND-008 found that `s_creditedShares` has a monotonic upward drift (ceil on open, floor on close). Does this create a systematic loss for credit users?
   - What if `s_creditedShares` underflows (more shares reclaimed than credited)? The overshoot haircut at CT:1447-1468 handles this — verify correctness.

#### B.2 Credit as Solvency Shield

- Credit legs add to the user's apparent balance in margin calculations (RE:1186-1187).
- Isolated credit requires 0 collateral (RE:1434).
- **Question**: Can a user create a credit to artificially inflate their apparent balance, enabling them to open undercollateralized option positions?
  - User deposits 100 tokens → has 100 shares.
  - User opens credit for 50 tokens → burns 50 shares → apparent balance increases by 50 tokens in margin calc.
  - Net effect: user deposited 100 tokens, has 50 shares, but margin sees `50 shares' value + 50 credit = 100`.
  - Is this just neutral (user locked up 50 tokens as credit and still has 50 as shares), or can it be gamed?
- What if the credit's notional value changes between the margin calculation and actual settlement?

#### B.3 Credit Without Sufficient Shares

- What happens if a user tries to create a credit when they don't have enough shares?
- The CT `settleMint` would try to burn `sharesToBurn = mulDivRoundingUp(creditNotional, totalSupply, totalAssets)` — if user balance < sharesToBurn, does this revert?
- Can the delegate/revoke sentinel (`type(uint248).max`) interact with credit share burning?

### C) Composite Strategy Analysis

#### C.1 Prepaid Long Option (width>0 long + credit)

- User pays for a long option upfront by crediting tokens.
- Collateral: `_computeCreditOptionComposite` uses 100% utilization for the option requirement (RE:2001).
- **Question**: Is the 100% utilization assumption conservative enough? What if actual utilization is lower — does the user over-collateralize?
- Can the credit amount mismatch the option notional (different optionRatios or strikes)?
- What happens at liquidation — is the credit properly unwound alongside the option?

#### C.2 Cash-Secured Option (width>0 short + credit)

- User secures a short option by depositing tokens as credit.
- Same collateral function as prepaid long. Is this appropriate for a short position?
- The credit reduces the effective collateral required. Does this create a scenario where the short is undercollateralized at extreme prices?

#### C.3 Upfront Short Option (width>0 short + loan)

- User borrows to fund a short option position.
- Collateral: `shortReq + loanReq` (RE:1984-1991, sum of both).
- Is the sum correct? The loan already inflates the balance, so should the requirements be additive?
- Can the loan-inflated balance create a false sense of solvency?

#### C.4 Option-Protected Loan (width>0 long + loan)

- User borrows and hedges with a long option.
- Collateral: `max(longReq, loanReq)` (RE:1984-1991).
- The `max` assumes the option hedge offsets the loan risk. Is this conservative enough?
- What if the option expires out-of-range (worthless) — does the loan requirement still hold?

#### C.5 Delayed Swap (loan + credit, different tokenTypes)

- User borrows token0 and credits token1 (or vice versa).
- Collateral: `max(loan*120% - convertedCredit, 1)` (RE:2038-2074).
- The conversion uses oracle price. Can the attacker manipulate the oracle to make the converted credit appear larger, reducing the requirement?
- At extreme prices, does the conversion produce correct results? (Near MIN/MAX_TICK, one token is worth ~0.)
- The minimum requirement is 1 (not 0). Is this sufficient? Can the delayed swap position become undercollateralized if the conversion rate moves?

#### C.6 3-Leg and 4-Leg Positions with width==0

- Can a 4-leg position have multiple width==0 legs?
- How does partner matching work with >2 legs? (TokenId partner encoding is per-leg.)
- Can width==0 legs be unpaired (no partner) in a multi-leg position? If so, they fall back to isolated requirements.
- Can an attacker construct a 4-leg position with creative partner assignments that produces a lower collateral requirement than intended?

### D) Solvency and Liquidation Edge Cases

#### D.1 Loan-Only Positions

- A position with ONLY loan legs (no options, no credits).
- Solvency: requires 120% of notional. With the loan minting shares (inflating balance), the user starts with exactly 100% + whatever they deposited. Is the 20% margin sufficient to cover:
  - Interest accrual between solvency checks?
  - Share price changes (if other users' liquidations cause protocol loss)?
  - Oracle tick movement affecting cross-collateral conversion?

#### D.2 Loan + Credit (Delayed Swap) Liquidation

- User has a delayed swap position (loan token0 + credit token1).
- Price moves unfavorably — the loan in token0 is worth more than the credit in token1.
- User becomes insolvent. Liquidation:
  - Both legs must be closed.
  - The loan leg requires the liquidator to provide token0 (to repay the borrow).
  - The credit leg returns token1 shares to the user.
  - Is the liquidation bonus correctly computed given the cross-token nature?
  - Does `getTotalLoanAmounts` correctly aggregate only the loan legs?

#### D.3 Width==0 Legs in Multi-Position Liquidation

- User has multiple open positions, some with width==0 legs, some with width>0 legs.
- All must be closed during liquidation.
- Are the width==0 legs correctly accounted for in the aggregate collateral requirement?
- Can the ordering of position closes during liquidation affect the outcome? (E.g., closing a credit first releases shares that could cover a loan's settlement.)

#### D.4 Interest Insolvency

- A loan position accrues interest over time. If the user never tops up collateral:
  - At what point does the position become insolvent?
  - Is the liquidation bonus clamping correct when the insolvency is purely from interest?
  - Does the protocol lose money if the interest exceeds the collateral?

#### D.5 Force Exercise of Mixed Positions

- A position has both width>0 long legs (exercisable) and width==0 legs (not exercisable).
- `validateIsExercisable` (TokenId:526) returns 1 if ANY width>0 long leg exists.
- Can the position be force-exercised? If yes, what happens to the width==0 legs?
- The force exercise closes the ENTIRE position. Does the width==0 leg settlement work correctly in this context?

### E) Protocol Health Impact

#### E.1 Pool Utilization Manipulation via Loans

- Loans increase `s_assetsInAMM` without actually deploying tokens.
- Pool utilization = `(s_assetsInAMM + interest) / totalAssets`.
- A large loan inflates utilization → increases interest rate for ALL borrowers.
- **Question**: Can an attacker take large loans to spike the interest rate, harming other borrowers?
- What is the maximum utilization achievable via loans? (Can `s_assetsInAMM > s_depositedAssets`? What happens to utilization > 100%?)

#### E.2 Share Price Impact

- Loans mint shares (increase `_internalSupply`) and increase `s_assetsInAMM` (increase `totalAssets`).
- If both increase proportionally, share price is unchanged. Verify this is exactly true, not just approximately.
- Credits burn shares (decrease supply via `s_creditedShares` increase) and... what happens to `totalAssets`? If assets don't change but supply decreases, share price INCREASES. Is this correct behavior?

#### E.3 Cascading Effects

- Many users take large loans → utilization spikes → interest rate spikes → some borrowers become insolvent → liquidations → protocol loss → share price drops → more insolvency.
- Is this cascade possible? What circuit breakers exist?
- Does the `SATURATED_POOL_UTIL` (90%) threshold in collateral calculations help?

#### E.4 Width Substitution (width=2) Accuracy

- `getAmountsMoved` patches width to 2 for accounting. This gives a tick range of `strike ± tickSpacing`.
- Is this a reasonable proxy for the loan/credit notional? Does the choice of 2 (vs 1, 3, etc.) matter significantly?
- For pools with large `tickSpacing` (e.g., 200 for low-fee pools), the synthetic range is `±200 ticks` — is this appropriate?
- For pools with `tickSpacing=1`, the range is `±1 tick` — very narrow. Does this produce sensible notionals?

### F) Findings

For each finding:

- ID (LC-NNN)
- Severity (Critical / High / Medium / Low / Informational)
- Category: solvency / liquidation / interest / accounting / manipulation / edge-case
- Complete scenario with concrete numbers (position sizes, token amounts, interest rates)
- Who is harmed and by how much
- Whether the issue is specific to single-leg or multi-leg configurations

### G) Recommendations

For each finding:

1. Minimal code change if applicable
2. Parameter adjustment suggestion with rationale
3. Additional validation checks that should be added
4. Whether the width==0 system should have explicit documentation/warnings for users

## Review Rules

- Every claim about width==0 behavior must trace through ALL affected contracts: TokenId → SFPM (skip) → PanopticPool → RiskEngine → CollateralTracker.
- The width substitution (width→2 in `getAmountsMoved`) is a critical accounting mechanism. Verify every downstream consumer of these amounts handles width==0 correctly.
- Do not assume that "no Uniswap interaction" means "no risk." Width==0 legs still affect solvency, interest, utilization, share price, and liquidation.
- The composite strategy collateral functions (`_computeCreditOptionComposite`, `_computeLoanOptionComposite`, `_computeDelayedSwap`) are complex. Verify each formula against the intended economic behavior.
- For multi-leg positions, verify that partner matching (same asset, same optionRatio) correctly identifies all intended composites and doesn't accidentally match legs that shouldn't be partnered.
- The loan-amount clamping in `getLiquidationBonus` (RE:537-548) is critical — verify it prevents extraction of loan-inflated balance as liquidation bonus.
- Track `s_assetsInAMM`, `s_depositedAssets`, `s_creditedShares`, `_internalSupply`, and `unrealizedInterest` through every width==0 operation. Any inconsistency in these accumulators is a finding.
- Width==0 legs bypass the `PositionTooLarge` check in SFPM. Verify that downstream checks prevent unbounded position sizes.
