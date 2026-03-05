# Main Invariants

## SFPM (SemiFungiblePositionManager)

- Fees collected from Uniswap during any given operation should not exceed the amount of fees earned by the liquidity owned by the user performing the operation.
- Fees paid to a given user should not exceed the amount of fees earned by the liquidity owned by that user.

## CollateralTracker

### Asset Accounting

- `totalAssets()` must equal `s_depositedAssets + s_assetsInAMM + unrealizedGlobalInterest` at all times
- `totalSupply()` must equal `_internalSupply + s_creditedShares` at all times
- `s_depositedAssets` should never underflow below 1 (the initial virtual asset)
- The share price (`totalAssets() / totalSupply()`) must be non-decreasing over time (except for rounding in favor of the protocol and during liquidations with protocol loss)

### Interest Accrual

- The global `borrowIndex` must be monotonically increasing over time and start at 1e18 (WAD)
- For any user with `netBorrows > 0`, their `userBorrowIndex` must be ≤ the current global `borrowIndex`
- Interest owed by a user must equal: `netBorrows * (currentBorrowIndex - userBorrowIndex) / userBorrowIndex`
- `unrealizedGlobalInterest` must never exceed the sum of all individual users' interest owed
- After `_accrueInterest()`, the user's `userBorrowIndex` must equal the current global `borrowIndex` (unless insolvent and unable to pay)

### Credited Shares

- `s_creditedShares` represents shares for long positions and can only increase when positions are created and decrease when closed
- When a long position is closed, if `creditDelta > s_creditedShares`, the difference must be paid by the option owner as a rounding haircut
- The rounding haircut from Uniswap position management should not exceed a few wei per position

### Deposits and Withdrawals

- Users with open positions (`numberOfLegs > 0`) cannot transfer shares via `transfer()` or `transferFrom()`
- Users with open positions can only withdraw if they provide `positionIdList` and remain solvent after withdrawal
- Deposits must not exceed `type(uint104).max` (2^104 - 1)
- Withdrawals must leave at least 1 asset in `s_depositedAssets` (cannot fully drain the pool)

## RiskEngine

### Solvency Checks

- An account is solvent if and only if: `balance0 + convert(scaledSurplus1) >= maintReq0` AND `balance1 + convert(scaledSurplus0) >= maintReq1` (where conversion direction depends on price)
- The maintenance requirement includes: position collateral requirements + accrued interest owed + long premia owed - short premia owed - credit amounts
- Cross-collateralization uses a `crossBufferRatio` that is constant below 90% utilization, linearly decreases to zero between 90–95%, and is zero above 95% (higher utilization = less conservative buffer)
- Solvency must be checked at the oracle tick, not the current tick, to prevent manipulation

### Collateral Requirements

- Collateral requirements must scale with pool utilization (higher utilization = higher requirements)
- The "global utilization" used for margin calculations is the maximum utilization across all of a user's positions at the time they were minted

### Liquidation Bonuses

- Liquidation bonus = `min(collateralBalance / 2, required - collateralBalance)`
- The bonus is computed cross-collaterally using both tokens converted to the same denomination
- If the liquidatee has insufficient balance in one token, excess balance in the other token can be used to mitigate protocol loss through token conversion
- If premium was paid to sellers during liquidation, it must be clawed back (haircut) if it would cause protocol loss to exceed the remaining collateral

### Premium Haircutting

- If `collateralRemaining < 0` (protocol loss exists), premium paid to sellers during the liquidation must be proportionally clawed back
- The haircut is applied per-leg based on the ratio of protocol loss to premium paid
- After haircutting, the adjusted bonus must not result in protocol loss exceeding the initial collateral balance

### Force Exercise Costs

- Base force exercise cost = 1.024% (`FORCE_EXERCISE_COST = 102_400 / 10_000_000`) of notional for in-range positions
- Cost for out-of-range positions = 1 bps (`ONE_BPS = 1000 / 10_000_000`)
- The cost must account for token deltas between current and oracle prices for all long legs
- Only long legs (not short legs) contribute to force exercise costs

### Interest Rate Model

- Interest rate must be bounded: `MIN_RATE_AT_TARGET ≤ rate ≤ MAX_RATE_AT_TARGET`
- Rate adjusts continuously based on utilization error: `targetUtilization - currentUtilization`
- The adaptive rate (`rateAtTarget`) compounds at speed `ADJUSTMENT_SPEED * error` per second
- Initial `rateAtTarget` = 4% APR (`INITIAL_RATE_AT_TARGET`)
- Target utilization = 66.67% (`TARGET_UTILIZATION = 2/3 in WAD`)

### Oracle Safety

- The maximum allowed delta between fast and slow oracle ticks = 953 ticks (~10% price move)
- During force exercises and premium settlements, current tick must be within 513 ticks of the TWAP (~5% deviation)
- If oracle deltas exceed thresholds, the protocol enters safe mode using more conservative price estimates
- The median tick buffer can only be updated if sufficient time has elapsed since the last observation

## PanopticPool

### Entry Points

- All user actions must originate from `dispatch()` or `dispatchFrom()` entry points
- `dispatchFrom()` requires the caller to have operator approval from the account owner
- Each dispatch call can execute exactly multiple action (mint, burn, mint, mint, burn etc.) and allows transiently insolvent states

### Position Management

- Users can mint up to `MAX_OPEN_LEGS = 26` position legs total across all their positions (configurable per-pool via `RiskParameters.maxLegs`)
- Commission is split between protocol and builder (if builder code present) according to `PROTOCOL_SPLIT` and `BUILDER_SPLIT`
- Option sellers must pay back exact `shortAmounts` of tokens when positions are burned
- Option buyers must add back exact liquidity amounts that were removed when positions are burned

### Solvency Requirements

- Users must remain solvent (per RiskEngine) after any mint, burn, or withdrawal operation
- Solvency is checked at the fast oracle tick, or at several oracle ticks if they diverge beyond the threshold

### Premium Settlement

- Option sellers should not receive unsettled premium (premium not yet collected from Uniswap or paid by long holders)
- Sellers' share of settled premium must be proportional to their share of liquidity in the chunk
- Premium distribution ratio: `min(settled / owed, 1)` applies to all sellers in a chunk
- Long premium can be settled against solvent buyers to force payment

### Liquidations

- Liquidations can only occur when `RiskEngine.isAccountSolvent()` returns false at the oracle tick
- The liquidator must close all positions held by the liquidatee
- Liquidation bonus paid to liquidator must not exceed the liquidatee's pre-liquidation collateral balance
- If the liquidation results in protocol loss, shares are minted to the liquidator to cover the difference
- It is acceptable for protocol loss to occur even if the liquidatee has residual token balance, if that balance is insufficient when converted

### Premium Haircutting Invariant

- If premium is paid to sellers during a liquidation AND protocol loss exists after the liquidation, the premium must be haircut (clawed back) to reduce protocol loss
- After haircutting, protocol loss must be minimized but may still be positive if premium clawback is insufficient

### Position Size Limits

- Individual position sizes are limited by the available liquidity in the Uniswap pool
- The maximum spread ratio (removed/net liquidity) is capped at `MAX_SPREAD = 90_000` (i.e., removedLiquidity/netLiquidity ≤ 9x)
- Position sizes must not cause integer overflows in any token amount or liquidity calculations

## Cross-Contract Invariants

### Oracle Consistency

- The oracle tick used for solvency checks must come from PanopticPool's oracle management
- All operations in a single transaction must use consistent oracle tick(s)
- The oracle must account for volatility via EMA and median filters to prevent manipulation
