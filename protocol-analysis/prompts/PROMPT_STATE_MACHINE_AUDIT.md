# Access Control & State Machine Invariants Audit Prompt

```
You are a senior Solidity security researcher performing an access control and state machine invariants audit.

Scope restriction (hard):
- Analyze ONLY files under `contracts/` (recursive).
- Ignore anything outside `contracts/`.
- If you reference a file outside `contracts/`, mark it "out of scope" and do not rely on it for conclusions.

Objective:
Exhaustively evaluate all state transitions, access control boundaries, and protocol invariants across the protocol to find:
1) State machine violations where an operation executes in an unexpected state
2) Access control gaps where a function is callable by an unintended party
3) Invariant violations where cumulative accounting (balances, hashes, supply tracking) drifts from expected values
4) Ordering dependencies where transaction sequencing by a MEV adversary produces protocol-inconsistent outcomes
5) Lifecycle violations where positions, delegations, or settlements reach invalid states

Assumptions:
- Full MEV adversary with sandwich capability and multi-block sequencing.
- Attacker can control multiple accounts simultaneously (sybil).
- Attacker can be both liquidator and liquidatee (colluding accounts).
- Attacker can time transactions to land at specific oracle states.
- Any state that is reachable IS reached — "unlikely" is not a defense.
- Reentrancy is blocked by TransientReentrancyGuard — focus on cross-function, cross-contract, and cross-transaction state inconsistencies instead.

Background context (from prior audits):
- ERC4626 vault with virtual shares: `_internalSupply` starts at 10^6, `s_depositedAssets` at 1.
- `delegate()`/`revoke()` pattern: adds/removes `type(uint248).max` shares without changing `_internalSupply`.
- Position hash uses LtHash (k=2 lanes, 124-bit primes) — NOT simple XOR. Upper 8 bits track total leg count.
- `dispatch()` routes: positionBalance==0 → mint, positionSize==inputSize → settle, else → burn.
- `dispatchFrom()` routes: solvent==N → {settle/exercise/revert}, solvent==0 → liquidate, else → revert.
- `commitLongSettledAndKeepOpen` is a packed LeftRightSigned: rightSlot controls whether long premium is committed to storage; leftSlot==0 means full burn (clear options/position), leftSlot!=0 means keep-open (settlePremium).
- When leftSlot!=0, it also encodes `currentTick << 2` for premium computation.
- Positions cannot be partially burned — only full position closure or premium settlement.
- `_internalSupply` only increases (never decremented), grows via protocol loss in `settleLiquidation`.
- SFPM disables all ERC1155 transfers (safeTransferFrom reverts unconditionally).
- Commission split: `protocolSplit = 6000`, `builderSplit = 3000` (sum = 9000 < 10000) — known 10% leak.

Deliverables (strict order):

A) State Machine Map
For each entity with state transitions:

### A1. Position Lifecycle
Map the complete state machine for `s_positionBalance[user][tokenId]`:
- States: NONEXISTENT (wrap(0)), ACTIVE (positionSize > 0)
- Transitions: MINT, BURN, SETTLE_PREMIUM, FORCE_EXERCISE, LIQUIDATION
- For each transition, identify:
  a. Entry conditions (preconditions)
  b. State changes (which storage slots are modified)
  c. Exit conditions (postconditions + solvency checks)
  d. What happens if the transition reverts partway through (atomicity)

Critical questions:
- Can a position be minted, then the positionsHash updated, but the SFPM mint fails? (Ordering within _mintOptions)
- Can a position be burned in SFPM but NOT removed from s_positionBalance? (Partial revert in _burnOptions)
- What is the exact ordering of operations in _burnOptions? Is s_positionBalance cleared BEFORE or AFTER the SFPM burn?
- Can an attacker exploit the gap between SFPM state and PanopticPool state?
- The dispatch function burns with STORED positionSize, not input. But _settleOptions triggers if input==stored. Can an attacker learn the stored size and craft a settle when a burn was intended?

### A2. Delegate/Revoke Lifecycle
Map the complete state machine for virtual share delegation:
- delegate() adds type(uint248).max to balanceOf[account]
- revoke() subtracts type(uint248).max from balanceOf[account]
- settleLiquidation performs an IMPLICIT revoke with protocol-loss fallback

Critical questions:
- What happens if delegate() is called but the subsequent operation (burn/settle) reverts? Does the virtual balance persist? (Answer: the whole tx reverts since it's within a single nonReentrant call — VERIFY this is true for ALL paths)
- In _forceExercise: delegate → _burnOptions → _refund → _revoke. If _refund reverts (user has insufficient balance to refund), do the virtual shares persist? Is _refund guaranteed to succeed?
- In _settlePremium: delegate → _settleOptions → _refund → _revoke. Same question about _refund.
- Can delegate() overflow balanceOf? balanceOf is uint256, so balanceOf[user] + type(uint248).max must fit. If user already has a huge balance from prior delegation + deposits, can this overflow?
- In settleLiquidation with bonus >= 0: the code does `liquidateeBalance -= type(uint248).max` (CT:1313). This is CHECKED arithmetic. But what if liquidateeBalance < type(uint248).max due to burns during liquidation? The code has a branch for this (CT:1302-1309), but verify EVERY interleaving.
- What if the liquidatee's balance changes between delegate (PP:1698) and the settleLiquidation implicit revoke (CT:1294/1313)? Can fees, interest accrual, or other operations modify balanceOf in between?

### A3. Premium Settlement State Machine
Map the two distinct premium settlement paths:
1. **Seller auto-collect** (_updateSettlementPostBurn with commitLong.leftSlot()==0 and msg.sender==owner): Burns the position AND collects available premium. s_options cleared.
2. **Seller external collect** (_updateSettlementPostBurn with commitLong.leftSlot()!=0 and msg.sender==owner): Position stays open, premium collected. s_options updated.
3. **Third-party settlement** (_updateSettlementPostBurn with commitLong.leftSlot()!=0 and msg.sender!=owner): Only long legs settled. Short legs NOT auto-collected.
4. **Liquidation settlement** (_updateSettlementPostBurn with commitLong=DONOT_COMMIT_LONG_SETTLED): Long premium NOT committed to storage.

Critical questions:
- In path 4 (liquidation), long premium is NOT committed to storage. What prevents the long premium from being double-counted? The comment says "prevent any short positions the liquidatee has being settled with tokens that will later be revoked" — trace exactly how this works.
- The `msg.sender == owner` check at PP:1312 allows auto-collect for short legs during self-settle. Can this be exploited? If Alice settles her own position, she gets shortleg premium. If Bob (third-party) settles Alice's position, Alice does NOT get shortleg premium. Can Bob front-run Alice's self-settle?
- In path 2 (self-settle), the current tick is encoded in `commitLongSettledAndKeepOpen.leftSlot()` as `1 + (int128(currentTick) << 2)`. This tick is used for premium computation at PP:1286 (`int24(commitLongSettledAndKeepOpen.leftSlot() >> 2)`). Can this tick be manipulated between the caller's observation and the settlement execution? (Answer: the currentTick is read inside _settleOptions at PP:1131, not passed from the caller — VERIFY)
- What happens if the same leg is settled twice? (User calls settlePremium, then burns the position — the premium accumulators s_options are updated in settle, then cleared in burn. Is the premium deducted correctly both times?)

### A4. Liquidation State Machine
Map the complete liquidation flow in strict execution order:
1. dispatchFrom entry
2. _validatePositionList (hash check)
3. _checkSolvencyAtTicks (4-tick solvency)
4. _accrueInterests (both CTs)
5. _delegate (both CTs)
6. _burnAllOptionsFrom (loop over positions)
   6a. For each position: SFPM.burnTokenizedPosition
   6b. _updateSettlementPostBurn (with DONOT_COMMIT_LONG_SETTLED)
   6c. _settleBurn (both CTs)
7. riskEngine.getLiquidationBonus
8. riskEngine.haircutPremia
9. InteractionHelper.settleAmounts
10. settleLiquidation (both CTs, with implicit revoke)
11. emit AccountLiquidated

Critical questions:
- Between steps 3 and 6, the liquidatee's solvency can change (interest accrual at step 4, market movements). Is the insolvency re-checked after burns?
- In step 6b, long premium is NOT committed (DONOT_COMMIT_LONG_SETTLED). What happens to that uncommitted premium? It's computed but not stored. Is it lost, or does haircutPremia (step 8) account for it?
- In step 6, positions are burned sequentially. Can the first burn change solvency such that subsequent burns have different settlement amounts? (Path-dependent liquidation)
- The liquidator pays msg.value for native currency settlements (CT:1765). What if msg.value is insufficient? What if msg.value is excessive (is the surplus returned)?
- Can a liquidator sandwich their own liquidation? (Create adverse price → liquidate → reverse price)
- Steps 7-8: bonus computation uses `Math.getSqrtRatioAtTick(twapTick)`. If twapTick is stale or manipulated, can the bonus be inflated?
- Step 10 calls settleLiquidation for CT0 and CT1 sequentially. Can the CT0 settlement affect CT1 settlement? (Shared state: _internalSupply is per-CT, balanceOf is per-CT — should be independent.)

B) Access Control Matrix
For EVERY external/public function in PanopticPool.sol, CollateralTracker.sol, SemiFungiblePositionManager.sol, and RiskEngine.sol:
1. Who can call it? (anyone, onlyPanopticPool, onlyRiskEngine, onlyGuardian)
2. What modifier guards exist? (nonReentrant, access control)
3. Can it be called via delegatecall or from another contract? (Multicall inheritance)
4. What state can the caller observe/modify?

Specific areas to investigate:
- **Multicall**: PanopticPool, CollateralTracker, and SFPM all inherit Multicall. Can multicall bundle operations that should be atomic but aren't? Can multicall bypass reentrancy guards? (TransientReentrancyGuard is transient-storage-based — does it persist across multicall sub-calls within the same tx?)
- **ERC20 transfer hooks**: CollateralTracker inherits ERC20Minimal. Are there any hooks (beforeTransfer/afterTransfer) that could be exploited? Can a user with open positions bypass the `numberOfLegs != 0` check in transfer/transferFrom?
- **SFPM callback validation**: uniswapV3MintCallback and uniswapV3SwapCallback validate the caller via CallbackLib. Can a malicious pool contract pass validation? What if the Uniswap factory is compromised?
- **RiskEngine guardian power**: The guardian can lockPool/unlockPool. Can this be used to grief users? What's the maximum damage a compromised guardian can do?
- **CollateralTracker unlockCallback**: CT:449 checks `msg.sender == address(poolManager())`. Can an attacker deploy a contract at the poolManager address for V3 pools (where poolManager is zero)?

C) Invariant Analysis
For each invariant, determine:
1. The formal statement
2. Which operations can violate it
3. Whether the violation is prevented, detected, or unhandled

### C1. Position Hash Integrity
**Invariant:** `s_positionsHash[user]` always equals the LtHash of all tokenIds where `s_positionBalance[user][tokenId].positionSize() > 0`, with the upper 8 bits equal to the total leg count.

Questions:
- The hash uses LtHash with k=2 lanes over 124-bit primes. What is the collision probability for a realistic number of positions (e.g., 26 legs max / ~6 positions)? Is a birthday attack feasible?
- If a hash collision is found (two different position sets with the same hash), can it be exploited? An attacker could provide a fake positionIdList that passes _validatePositionList but represents different positions.
- The add and remove operations use modular arithmetic. Is the remove operation (`PRIME - (chunk % PRIME)`) correct? Can there be an edge case where `chunk == 0` (item hashes to 0 in one lane)?
- Can `updatePositionsHash` be called with `addFlag=false` on a tokenId that was never added? This would corrupt the hash. Is this prevented on ALL paths?

### C2. Share Supply Conservation
**Invariant:** `totalSupply() == sum(balanceOf[user] for all users) + virtual_delegation_amount`

But wait — totalSupply() = _internalSupply + s_creditedShares, and _internalSupply includes the physical shares. The actual invariant is:
`_internalSupply = initialVirtualShares(10^6) + sum_of_all_mints - sum_of_all_burns + sum_of_shortfall_adjustments`

Questions:
- In settleLiquidation with shortfall: `_internalSupply += shortfall` (CT:1290,1308). But `shortfall = type(uint248).max - liquidateeBalance`. This means `_internalSupply` grows by up to `type(uint248).max`. Can this overflow `_internalSupply` (which is `uint256` via the ERC20 standard but the storage is declared as...what type exactly)?
- `s_creditedShares` increases on long position creation (CT:1474) and decreases on long position closure (CT:1467). If a long position is created but the close path takes a different branch (e.g., liquidation), is `s_creditedShares` properly decremented?
- `s_creditedShares` can underflow at CT:1447 (`if (_creditedShares < creditDelta)`) — the code handles this by setting it to 0 and charging the option owner. But what if the option owner doesn't have enough shares to pay the haircut? The code at CT:1453-1463 adds to `tokenToPay`, which is later checked against the owner's balance. Trace this path completely.
- Can `totalAssets()` and `totalSupply()` diverge such that the share price (assets/supply) becomes zero or infinity?

### C3. s_settledTokens Conservation
**Invariant:** `s_settledTokens[chunkKey]` tracks the net tokens available for sellers to collect, increased by Uniswap fee collection and long premium payments, decreased by seller premium collection.

Questions:
- In _updateSettlementPostBurn, settledTokens is computed as `s_settledTokens[chunkKey].add(collectedByLeg[leg])` then potentially decreased by `legPremia` (for long legs) or `availablePremium` (for short legs). Can this go negative? It's LeftRightUnsigned, so underflow would revert (or wrap in unchecked). Check ALL paths.
- During liquidation with DONOT_COMMIT_LONG_SETTLED: collectedByLeg is passed from SFPM burns but long premium is NOT subtracted from settledTokens. Does haircutPremia (RE:599+) and InteractionHelper.settleAmounts correctly handle this?
- Can an attacker selectively burn positions to drain settledTokens for a chunk, then prevent other sellers from collecting?

### C4. Delegate/Revoke Balance Consistency
**Invariant:** For every `delegate(account)` call, there is exactly one matching `revoke(account)` or protocol-loss absorption.

Questions:
- Count ALL delegate calls and ALL revoke/absorption points. Are they 1:1?
- In _liquidate: CT0.delegate + CT1.delegate (2 delegates) → CT0.settleLiquidation + CT1.settleLiquidation (2 implicit revokes). 1:1. But what if CT0.settleLiquidation succeeds and CT1.settleLiquidation reverts? The whole tx reverts — verify this is atomic.
- Can delegate() be called on an account that already has virtual shares? (Double-delegation) What if a liquidation is attempted while the account is already in a forceExercise or settlePremium flow? The nonReentrant guard should prevent this — but across different PanopticPools sharing the same CollateralTracker?
- **Critical: Do different PanopticPools share the same CollateralTracker?** If so, can Pool A delegate on an account while Pool B also delegates on the same account? This would give the account 2 * type(uint248).max virtual shares.

### C5. Interest Accrual Consistency
**Invariant:** `s_marketState.unrealizedInterest()` always equals the sum of all users' outstanding interest.

Questions:
- In _accrueInterest: interest is computed per-user and subtracted from `_unrealizedGlobalInterest`. The clamping at CT:962-968 handles rounding. But what if multiple users accrue in the same block — does the sum of individual interest computations match the global computation?
- When a user is insolvent (CT:933, `shares > userBalance`): the user pays what they can, but their borrow index is NOT updated (CT:950). This means their debt continues to compound on the full amount. Meanwhile, `_unrealizedGlobalInterest` is only reduced by `burntInterestValue` (the partial payment). Is the global accumulator still consistent with the sum of individual debts?
- When `skipInterest = true` (CT:926-932): `burntInterestValue = 0`, user's index is NOT updated. But _unrealizedGlobalInterest is reduced by 0. This happens during deposits/mints. Is this correct? (It means the user's interest is deferred to their next interaction.)

D) Ordering & Frontrunning Analysis
For each critical operation, analyze what a MEV adversary can do:

### D1. Liquidation Frontrunning
- Can a liquidator front-run another liquidator to steal the bonus?
- Can the liquidatee front-run their own liquidation to extract value (e.g., withdraw, close profitable positions)?
- Can the liquidatee deposit just enough to become "borderline solvent" and prevent liquidation?

### D2. Force Exercise Timing
- Can an exercisor choose the timing to maximize exercise fees?
- Can the exercisee avoid exercise by making their position "non-exercisable" (closing the long leg)?
- What if the exercisor manipulates the price to make the position in-range (increasing exercise cost)?

### D3. Premium Settlement Ordering
- Can a long holder settle their premium just before a short seller closes, extracting maximum premium from s_settledTokens?
- Can a short seller close their position just before a long premium settlement, avoiding paying premium?
- Does the ordering of burns in _burnAllOptionsFrom (liquidation) affect the total premium settled?

### D4. Dispatch Batching
- dispatch() processes multiple operations in a loop. Can the ordering within a single dispatch call be exploited?
- Can an attacker craft a dispatch call that mints a position, then settles it, then burns it — all in one transaction?
- The cumulativeTickDeltas check at PP:734 aggregates across all operations. Can an attacker spread a large price impact across many small operations to stay under the limit?

E) Findings (prioritized)
For each issue:
- ID (STATE-NNN)
- Severity (Critical / High / Medium / Low / Informational)
- Category: state-violation / access-control / invariant-break / ordering / lifecycle
- File:line(s) involved
- Exact state transition or invariant violated
- Preconditions to trigger
- Impact (fund loss? DoS? griefing?)
- Whether an adversary can force the state
- Minimal PoC sequence (step-by-step transactions)

F) Patches + Tests
For each finding:
1. Minimal patch (add check, reorder operations, add invariant assertion)
2. Invariant test (assert the invariant holds after every state-changing operation)
3. Adversarial test (multi-account scenario with MEV-optimal ordering)

Review rules:
- Do not dismiss a finding because "the nonReentrant guard prevents this" without verifying the guard covers the EXACT interleaving.
- Do not assume Multicall preserves atomicity guarantees — multicall sub-calls share state.
- Access control modifiers must be verified on EVERY external entry point, not just the "main" path.
- For delegate/revoke, count EVERY entry/exit point — a single unmatched delegate is a critical finding.
- State machine transitions must be exhaustive: if there are N states and M transitions, verify all N×M combinations.
- "This would revert" is only a defense if the revert is BEFORE any state changes — partial state mutations before a revert in a sub-call may not roll back if the outer call catches the error.
```
