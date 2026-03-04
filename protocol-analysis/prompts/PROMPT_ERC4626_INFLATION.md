# ERC4626 Inflation & Share Price Manipulation Audit Prompt

You are a senior Solidity security researcher performing a targeted audit of ERC4626 inflation attack vectors and share price manipulation in the CollateralTracker vault.

Scope restriction (hard):

- Analyze ONLY files under `contracts/` (recursive).
- Ignore anything outside `contracts/`.
- If you reference a file outside `contracts/`, mark it "out of scope" and do not rely on it for conclusions.

## Objective

Exhaustively evaluate all vectors for manipulating the CollateralTracker share price, including:

1. Classic ERC4626 inflation attacks (first depositor, donation-based)
2. Share price manipulation via direct token donation
3. Share price manipulation via credited shares (s_creditedShares)
4. Share price manipulation via interest accrual timing
5. Virtual share/asset mechanism completeness — do the virtual 10^6 shares and 1 virtual asset fully mitigate inflation?
6. delegate/revoke mechanism correctness — does the type(uint248).max sentinel create edge cases?
7. Non-standard ERC4626 behaviors that could trip external integrators

## Assumptions

- Full MEV adversary who can front-run deposits, withdrawals, and settlements.
- Attacker can send tokens directly to the CollateralTracker address (bypassing `deposit()`).
- Attacker can interact with the Uniswap pool to influence `s_assetsInAMM` and fee generation.
- Attacker can open/close positions to manipulate `s_creditedShares`, `s_depositedAssets`, and `s_assetsInAMM`.
- The attacker's goal is to either: (a) steal depositor funds via share price manipulation, (b) cause depositors to receive fewer shares than they should, (c) inflate their own share count to drain the vault, or (d) manipulate the share price to affect solvency calculations.

## Background Context

### CollateralTracker ERC4626 Implementation

**Initialization** (CT:285-300):

```solidity
function initialize() external {
  if (s_initialized) revert Errors.AlreadyInitialized();
  s_initialized = true;
  _internalSupply = 10 ** 6; // Virtual shares
  s_depositedAssets = 1; // Virtual asset (1 token unit)
  s_marketState = MarketStateLibrary.storeMarketState(WAD, block.timestamp >> 2, 0, 0);
}
```

**Core accounting:**

```
totalAssets() = s_depositedAssets + s_assetsInAMM + s_marketState.unrealizedInterest()  // CT:505
totalSupply() = _internalSupply + s_creditedShares                                        // CT:513
sharePrice   = totalAssets() / totalSupply()
```

**Share/asset conversions:**

- `convertToShares(assets)`: `mulDiv(assets, totalSupply(), totalAssets())` — floor (CT:521)
- `convertToAssets(shares)`: `mulDiv(shares, totalAssets(), totalSupply())` — floor (CT:528)
- `previewDeposit(assets)`: `mulDiv(assets, totalSupply(), totalAssets())` — floor (CT:548)
- `previewMint(shares)`: `mulDivRoundingUp(shares, totalAssets(), totalSupply())` — ceil (CT:606)
- `previewWithdraw(assets)`: `mulDivRoundingUp(assets, supply, totalAssets())` — ceil (CT:698)
- `previewRedeem(shares)`: `convertToAssets(shares)` — floor (CT:528/831)

**State variables affecting share price:**

- `s_depositedAssets` (uint128): tokens deposited by PLPs, initialized to 1
- `s_assetsInAMM` (uint128): tokens deployed to Uniswap by option sellers
- `unrealizedInterest` (106-bit in MarketState): accumulated but unsettled interest
- `_internalSupply` (uint256): "real" shares from deposits, initialized to 10^6
- `s_creditedShares` (uint256): virtual shares for long positions

**Deposit cap:** `type(uint104).max` (~2e31) enforced at CT:563/598.

**Withdrawal floor:** `maxWithdraw` returns `depositedAssets > 0 ? depositedAssets - 1 : 0` (CT:662, 681), preserving 1 virtual asset.

### delegate / revoke Mechanism

- `delegate(delegatee)` (CT:1227): `balanceOf[delegatee] += type(uint248).max`
- `revoke(delegatee)` (CT:1236): `balanceOf[delegatee] -= type(uint248).max`
- Both are `onlyPanopticPool nonReentrant`
- The `type(uint248).max` value (~4.5e74) is a sentinel marking "active position holder"
- This sentinel is NOT included in `totalSupply()` (only `_internalSupply` counts)
- Purpose: prevents transfer of shares while positions are open (transfer checks `balanceOf` which is inflated by the sentinel)

### Known Findings

- ROUND-003 (Medium): settleLiquidation mintedShares potential underflow
- ROUND-008 (Low): s_creditedShares monotonic growth 0-1 share per long lifecycle
- ROUND-009 (Info): 1-wei deposit can mint 0 shares (standard ERC4626 behavior, mitigated by virtual shares)
- DENOM-004 (Low): settleLiquidation quotient amplification capped at totalSupply\*DECIMALS

## Deliverables (strict order)

### A) Classic Inflation Attack Analysis

#### A.1 First Depositor Attack

The classic attack: first depositor deposits 1 wei, then donates a large amount to inflate the share price, causing the next depositor's deposit to round to 0 shares.

**With Panoptic's mitigations:**

- Initial state: `totalAssets = 1`, `totalSupply = 10^6`
- Share price: `1 / 10^6 = 0.000001` tokens per share
- First real depositor deposits X tokens: `shares = X * 10^6 / 1 = X * 10^6`
- After deposit: `totalAssets = 1 + X`, `totalSupply = 10^6 + X*10^6`

**Question 1**: Can the attacker front-run the first depositor?

- Attacker deposits 1 wei: gets `1 * 10^6 / 1 = 10^6` shares
- Attacker donates D tokens directly to CT address
- Now: `totalAssets = 1 + 1 + D = 2 + D`, `totalSupply = 10^6 + 10^6 = 2*10^6`
- Victim deposits V: `shares = V * 2*10^6 / (2 + D)`
- For shares to round to 0: need `V * 2*10^6 < 2 + D`, i.e., `D > V * 2*10^6 - 2`
- For a victim depositing 1 ETH (1e18): attacker needs to donate `1e18 * 2e6 = 2e24` tokens (~2M ETH)
- **Compute**: what is the minimum donation needed to steal 1% of a victim's deposit? 10%? 50%?

**Question 2**: Does the donation actually increase `totalAssets()`?

- `totalAssets() = s_depositedAssets + s_assetsInAMM + unrealizedInterest`
- A direct token transfer does NOT update `s_depositedAssets`.
- So `totalAssets()` does NOT increase from donations!
- **Verify**: is there ANY code path where tokens sent directly to the CT affect `totalAssets()`?
- If not: the classic inflation attack via donation is completely neutralized. Confirm this.

#### A.2 Donation via Other Paths

If direct donation doesn't work, are there indirect paths?

1. **Uniswap fee donation**: Can the attacker generate Uniswap fees that accrue to the CT without going through the standard fee collection path?
2. **Interest manipulation**: Can the attacker manipulate `unrealizedInterest` to inflate `totalAssets`?
   - Interest is added via `_accrueInterest` (CT:894). Can the attacker trigger large interest accrual?
   - Interest requires borrowers (open positions). The attacker would need to borrow and pay interest.
3. **Settlement manipulation**: Can the attacker manipulate `s_depositedAssets` or `s_assetsInAMM` through settlement?
   - These are only modified through `_updateBalancesAndSettle` (CT:1403) and settlement functions.
   - All settlement functions are `onlyPanopticPool`.

#### A.3 Vault Deflation Attack

The reverse: can an attacker decrease `totalAssets()` without decreasing `totalSupply()`?

- Decrease `s_depositedAssets`: only through withdrawals and settlement (both protected)
- Decrease `s_assetsInAMM`: only through position burns returning assets
- Decrease `unrealizedInterest`: through clamping at CT:962-968 (natural, bounded)
- **Protocol loss**: `settleLiquidation` can increase `_internalSupply` (mint shares without backing) → decreases share price. This is by-design protocol loss socialization.

### B) Share Price Manipulation via s_creditedShares

`s_creditedShares` is part of `totalSupply()` but has no corresponding asset backing:

#### B.1 creditedShares Inflation

- `s_creditedShares` increases when long positions are opened: `mulDivRoundingUp(longAmount, supply, assets)` (CT:1430/1475)
- `s_creditedShares` decreases when long positions are closed: `mulDiv(longAmount, supply, assets)` (CT:1435/1468)
- The ceil/floor asymmetry means each open/close cycle adds 0-1 to `s_creditedShares` (ROUND-008)
- **Question**: Can an attacker rapidly open/close long positions to inflate `s_creditedShares`, diluting all shareholders?
- Compute the cost per cycle (commission fees, gas) vs the dilution achieved (1 share out of totalSupply)
- At what `totalSupply` does the dilution become negligible? (With 10^6 virtual shares + real deposits, 1 share of dilution is ~1/10^6 minimum)

#### B.2 creditedShares and Share Price

- Higher `s_creditedShares` → higher `totalSupply` → lower `convertToAssets(shares)` → PLPs receive fewer assets per share
- But `s_creditedShares` also has a corresponding liability: when the long position is closed, the credited shares are removed
- **Is there a window** between share crediting (long open) and share decrediting (long close) where the inflated supply can be exploited?
- Scenario: Attacker opens long → `s_creditedShares` increases → share price drops → attacker deposits at lower price → attacker closes long → `s_creditedShares` decreases → share price recovers → attacker withdraws at higher price
- **Compute**: profit vs cost (commission on the long position)

#### B.3 creditedShares Underflow

- When closing a long, if `creditDelta > s_creditedShares`, the overshoot is handled at CT:1447-1468
- The option owner pays a haircut: `mulDivRoundingUp(overshoot, totalAssets, totalSupply)` (CT:1455)
- Can the attacker exploit this haircut mechanism? E.g., force another user's long close to trigger a haircut by manipulating `s_creditedShares` via their own positions?

### C) Interest Accrual Timing Attacks

#### C.1 Interest Front-Running

- `accrueInterest()` (CT:887) is public and can be called by anyone.
- Interest increases `totalAssets()` (via `unrealizedInterest`) → increases share price.
- **Scenario**: Attacker deposits, triggers `accrueInterest()` to realize pending interest, then withdraws at a higher share price.
- Is this profitable? Interest is continuously accruing anyway — the attacker just forces it to be recognized.
- The real question: is there a window where interest has accrued in the borrowIndex but NOT in `unrealizedGlobalInterest`? If so, the share price is temporarily too low.

#### C.2 Interest Sandwich

- Attacker deposits a large amount (share price is X).
- Time passes, interest accrues.
- Attacker withdraws (share price is X + interest).
- The attacker captures interest proportional to their share of the pool.
- This is standard vault behavior and not a bug — but does the interest accrue correctly? Does the attacker capture MORE than their fair share due to timing?
- **Check**: is interest applied to `s_depositedAssets` or to `totalAssets()`? If it only goes to `unrealizedInterest`, the share price increase is proportional and fair.

#### C.3 Stale Interest State

- If `_accrueInterest()` hasn't been called for a long time, `unrealizedInterest` is stale (too low).
- `totalAssets()` is understated → share price is too low → deposits get more shares than they should.
- When interest is finally accrued, share price jumps → the depositor captured a disproportionate share of the interest.
- **Compute**: maximum interest accrual lag vs maximum unfair share capture.
- Is this mitigated by `_accrueInterest()` being called at the start of every deposit/withdrawal? (CT:564 calls `_accrueInterest` in the `deposit` function? Check.)

### D) delegate/revoke Edge Cases

#### D.1 Sentinel Arithmetic

- `delegate`: `balanceOf[delegatee] += type(uint248).max`
- `revoke`: `balanceOf[delegatee] -= type(uint248).max`
- If a user has real balance R and is delegated: `balanceOf = R + type(uint248).max`
- Addition overflow: `R + type(uint248).max` must fit in uint256. Since R < type(uint104).max (deposit cap) and type(uint248).max < type(uint256).max, this is safe.
- **But**: can a user be delegated multiple times? If `delegate` is called twice: `balanceOf = R + 2 * type(uint248).max`. Does this overflow uint256? `2 * type(uint248).max ≈ 2^249 < 2^256`. Still safe. But does the protocol track delegation count?
- What happens if `revoke` is called more times than `delegate`? Underflow in `balanceOf -= type(uint248).max`.

#### D.2 Transfer Blocking

- The sentinel inflates `balanceOf` to > type(uint248).max.
- Transfer checks: `balanceOf[from] >= amount`. Even without an explicit transfer block, transferring type(uint248).max tokens is impossible (nobody has that many shares).
- **But**: what if the transfer check uses a different threshold? Or what if `transferFrom` with a specific allowance bypasses the balance check?
- Trace the exact transfer path in ERC20Minimal and verify the block is robust.

#### D.3 Liquidation Shortfall

- During liquidation, `revoke` is called but the liquidatee may not have enough balance to cover `type(uint248).max`.
- CT:1282-1312 handles this shortfall by adjusting `_internalSupply`.
- **Verify**: does the shortfall calculation correctly account for the sentinel? Can the shortfall be manipulated by the liquidatee (e.g., transferring shares away before liquidation)?
- Shares cannot be transferred while delegated (sentinel blocks it). But what if the liquidatee deposited into the CT from a different account? Does the delegation prevent ALL transfers from the delegated account?

### E) Non-Standard ERC4626 Behavior

Catalog all deviations from the ERC4626 standard that could cause issues for integrators:

1. **Transfer restrictions**: Accounts with open positions (delegated) cannot transfer. Standard ERC4626 does not have transfer restrictions.
2. **Non-standard totalSupply**: Includes `s_creditedShares` which are not user-owned shares but protocol-internal accounting.
3. **Virtual shares/assets**: The 10^6 virtual shares and 1 virtual asset permanently dilute the first depositors. Is this documented?
4. **Interest inclusion in totalAssets**: `unrealizedInterest` is included. This means `totalAssets` can change between blocks without any user action (just time passing).
5. **Deposit cap**: `type(uint104).max`. Standard ERC4626 returns `type(uint256).max` for `maxDeposit`.
6. **Withdrawal with solvency check**: The `withdraw(assets, receiver, owner, positionIdList)` overload requires position validation. This is non-standard.
7. **payable deposit/mint**: Accepts native ETH. Non-standard for ERC4626.

For each deviation: can an integrator's incorrect assumption about standard behavior lead to fund loss?

### F) Comprehensive Share Price Bounds

Compute the theoretical bounds on share price manipulation:

1. **Maximum share price increase per block**: Via interest accrual, fee collection, or settlement. What is the maximum single-block share price increase?
2. **Maximum share price decrease per block**: Via protocol loss (liquidation), credited shares inflation, or withdrawal. What is the maximum single-block decrease?
3. **Minimum share price**: Given virtual shares (10^6) and virtual asset (1), the minimum share price is `1 / 10^6` = 0.000001 tokens per share. Can this be violated?
4. **Maximum share price**: `type(uint104).max / 10^6 ≈ 2e25` tokens per share. Can this be exceeded?

### G) Findings

For each finding:

- ID (VAULT-NNN)
- Severity (Critical / High / Medium / Low / Informational)
- Category: inflation / deflation / donation / timing / delegation / integration
- Complete attack sequence with concrete numbers
- Capital required and expected profit
- Existing mitigations and whether they are sufficient
- Whether the attack works against a mature vault (large totalAssets) or only against a fresh vault

### H) Recommendations

For each finding:

1. Minimal code change if applicable
2. Documentation recommendations for integrators
3. Parameter adjustment suggestions

## Review Rules

- Every share price computation must use the EXACT formula: `totalAssets() / totalSupply()` with the actual components (`s_depositedAssets + s_assetsInAMM + unrealizedInterest`) / (`_internalSupply + s_creditedShares`).
- Do not assume direct token transfers affect `totalAssets()` — verify by reading the code.
- Every "protected by virtual shares" claim must include the quantitative analysis: how large a donation/manipulation is needed to cause X% loss to a depositor?
- Distinguish between attacks on a fresh vault (no deposits yet) and a mature vault (millions in TVL).
- If an attack requires front-running a specific transaction, compute the MEV profit vs gas cost.
- The `type(uint248).max` sentinel is unusual — verify every arithmetic operation on `balanceOf` handles it correctly (no overflow, no underflow, no unexpected comparisons).
- Check that `_internalSupply` can never be 0 post-initialization (since `totalSupply()` includes it and is used as a denominator).
