# Reentrancy & External Call Safety Audit — Guardian.sol

```
You are a senior Solidity security researcher performing an exhaustive reentrancy and external call safety audit.

Scope restriction (hard):
- Analyze ONLY `src/Guardian.sol`.
- Ignore anything outside `src/`.

## Objective

Exhaustively evaluate all reentrancy and external call attack surfaces, focusing on:
1. State consistency at every external call boundary (checks-effects-interactions pattern)
2. Return value handling and try-catch correctness
3. Potential reentrancy through RiskEngine, BuilderWallet, BuilderFactory, or token callbacks
4. staticcall safety and data validation
5. Gas griefing on external calls

## Assumptions

- Guardian has NO reentrancy guard. Every external call is a potential reentrancy point.
- Attacker can deploy arbitrary contracts that conform to IRiskEngine, IBuilderWallet, or IERC20BalanceOf interfaces.
- Attacker can deploy a contract whose GUARDIAN() returns address(this) to pass recognition checks.
- RiskEngine.collect() may trigger token transfers with arbitrary callback behavior.
- All external calls are potential reentrancy points unless proven otherwise.

## Background Context

### Guardian's External Call Graph

```

Guardian.lockPool()
→ pool.riskEngine() [view — reads pool state]
→ riskEngine.GUARDIAN() [staticcall — recognition check]
→ riskEngine.lockPool(pool) [state-changing — locks pool in RiskEngine]

Guardian.lockPoolAsBuilder()
→ pool.riskEngine() [view]
→ riskEngine.GUARDIAN() [staticcall]
→ riskEngine.getFeeRecipient(builderCode) [view, try-catch]
→ builderWallet.builderAdmin() [view, try-catch]
→ riskEngine.lockPool(pool) [state-changing]

Guardian.requestUnlock()
→ pool.riskEngine() [view]
→ riskEngine.GUARDIAN() [staticcall]
(no further external calls — only storage writes)

Guardian.executeUnlock()
→ pool.riskEngine() [view]
→ riskEngine.GUARDIAN() [staticcall]
→ riskEngine.unlockPool(pool) [state-changing]

Guardian.cancelUnlock()
(no external calls beyond \_requirePool's code.length check)

Guardian.deployBuilder()
→ IBuilderFactory.deployBuilder(builderCode48, builderAdmin) [state-changing]

Guardian.collect()
→ riskEngine.GUARDIAN() [staticcall]
→ token.balanceOf(riskEngine) [staticcall, in _balanceOfOrZero]
→ riskEngine.collect(token, recipient) [state-changing — transfers tokens]
OR → riskEngine.collect(token, recipient, amount) [state-changing — transfers tokens]

```

### Key Design Patterns

- `_isRecognizedRiskEngine` (line 488): Uses raw `staticcall` to call `GUARDIAN()` — prevents state changes during validation.
- `_balanceOfOrZero` (line 441): Uses raw `staticcall` for `balanceOf` — prevents state changes, returns 0 on failure.
- `_isAuthorizedBuilder` (lines 407-435): Uses `try-catch` for both `getFeeRecipient` and `builderAdmin` — silently returns false on any failure.

## Deliverables (strict order)

### A) External Call Inventory

For EVERY external call made by Guardian, document:

| # | Caller Function | Callee | Method | Call Type | Guard Held | State Modified Before Call | State Modified After Call | Reentrancy Risk |
|---|----------------|--------|--------|-----------|------------|---------------------------|--------------------------|-----------------|

Focus on:
1. All calls to RiskEngine (lockPool, unlockPool, collect, GUARDIAN, getFeeRecipient)
2. All calls to BuilderWallet (builderAdmin)
3. All calls to BuilderFactory (deployBuilder)
4. All token balance queries (_balanceOfOrZero)
5. Implicit calls via pool.riskEngine()

For each call:
- What state has been modified BEFORE the call that could be exploited if re-entered?
- What state will be modified AFTER the call that an attacker could front-run via reentrancy?
- Is there a checks-effects-interactions violation?

### B) Reentrancy Path Analysis

Since Guardian has NO reentrancy guard, analyze each potential reentrancy path:

#### B.1 collect() → riskEngine.collect() → ??? → Guardian

- `collect()` at line 356: When `amount == 0`:
  1. Reads balance via `_balanceOfOrZero` (staticcall — safe)
  2. Calls `riskEngine.collect(token, recipient)` — this transfers tokens
  3. Emits `TokensCollected` with the pre-collect balance as amount

- If `riskEngine.collect()` calls back into Guardian:
  - Can it call `collect()` again? (Yes, if caller is TREASURER — but TREASURER is immutable and the RiskEngine is the callee, not the caller. The callback would come from the RiskEngine or the token, not from TREASURER.)
  - Can a token transfer hook (ERC777) during the collect trigger a callback to Guardian? The callback would come from the token contract, not from TREASURER, so `onlyTreasurer` blocks re-entry to `collect()`.
  - Can a callback re-enter `lockPool` or other guardian-admin functions? Only if the callback comes from GUARDIAN_ADMIN, which is immutable.
  - **Key insight**: Guardian's access control (immutable addresses) naturally prevents reentrancy to privileged functions. The only unguarded entry point is `lockPoolAsBuilder`, which requires passing the full authorization chain.

#### B.2 lockPool() → riskEngine.lockPool() → ??? → Guardian

- `lockPool()` at line 249: clears pending unlock (line 251), then calls `riskEngine.lockPool(pool)` (line 252).
- State modified BEFORE the external call: `unlockEta[pool]` set to 0.
- If `riskEngine.lockPool()` calls back into Guardian and somehow reaches `executeUnlock` for the same pool — the pending unlock is already cleared, so `executeUnlock` would revert with `NoPendingUnlock`. Safe.
- If the callback reaches `requestUnlock` — it would set a new unlock ETA. This is not harmful since the pool is being locked anyway.

#### B.3 executeUnlock() → riskEngine.unlockPool() → ??? → Guardian

- `executeUnlock()` at line 289: clears `unlockEta[pool]` to 0 (line 296), then calls `riskEngine.unlockPool(pool)` (line 297).
- If the callback reaches `lockPool` for the same pool — this would re-lock the pool and potentially clear a new pending unlock. But there's no new pending unlock to clear (we just cleared it). The lock would succeed, creating a lock-then-unlock-then-lock sequence in one tx.
- If the callback reaches `executeUnlock` again — reverts with `NoPendingUnlock`. Safe.

#### B.4 lockPoolAsBuilder() → riskEngine.lockPool() → ??? → Guardian

- `lockPoolAsBuilder()` at line 264: does NOT modify any storage before the external call to `riskEngine.lockPool()`.
- The authorization checks (`_isAuthorizedBuilder`) are all view calls that don't modify state.
- If `riskEngine.lockPool()` calls back — no inconsistent state to exploit.

#### B.5 deployBuilder() → BuilderFactory.deployBuilder() → ??? → Guardian

- `deployBuilder()` at line 331: calls `IBuilderFactory.deployBuilder()` then validates the returned wallet.
- If the BuilderFactory calls back into Guardian during deployment — no storage has been modified. The only risk is if the callback can interfere with the deployment return value, but that's controlled by the call stack.

### C) staticcall and Return Value Safety

#### C.1 _isRecognizedRiskEngine (line 488-497)

- Uses raw `staticcall` to call `GUARDIAN()`.
- Checks: `success && data.length >= 32 && abi.decode(data, (address)) == address(this)`.
- Can a malicious contract return crafted data? The `staticcall` prevents state changes. The return data is ABI-decoded as an address. If the contract returns `abi.encode(address(this))`, it passes. This is BY DESIGN — the check is mutual recognition.
- Can the staticcall consume excessive gas (gas bomb)? Yes, a malicious contract could run an infinite loop. However, this only affects the caller's gas. In `_getRiskEngine`, this is called on a pool-provided RiskEngine address — a malicious pool could cause the guardian to waste gas. Impact: DoS on that specific pool interaction, not global.

#### C.2 _balanceOfOrZero (line 441-450)

- Uses raw `staticcall` to call `balanceOf`.
- Checks: `success && data.length >= 32`.
- Can a malicious token return a wrong balance? Yes — a lying `balanceOf` would cause `collectedAmount` in the `TokensCollected` event to be incorrect. Impact: off-chain accounting errors, no on-chain fund loss.
- Can the staticcall consume excessive gas? Same concern as above — but this is only called in `collect()` where the RiskEngine is already validated.

#### C.3 _isAuthorizedBuilder try-catch (lines 419-434)

- `riskEngine.getFeeRecipient(builderCode)`: wrapped in try-catch. On revert → returns false. Safe.
- `IBuilderWallet(wallet).builderAdmin()`: wrapped in try-catch. On revert → returns false. Safe.
- Can a malicious wallet's `builderAdmin()` return unexpected data? The `try-catch` with `returns (address builderAdmin)` enforces ABI decoding. If the return data is malformed, it would catch and return false.
- Can a malicious wallet consume excessive gas in `builderAdmin()`? Yes — gas bomb. Impact: DoS on `lockPoolAsBuilder` for that specific builder code.

### D) Checks-Effects-Interactions Violations

For each state-changing function, verify CEI compliance:

| Function | Effects Before External Call | Violation? | Impact |
|----------|----------------------------|------------|--------|
| lockPool | `unlockEta[pool] = 0` (via _clearPendingUnlock) | Potential | If `riskEngine.lockPool()` reverts, pending unlock is already cleared |
| lockPoolAsBuilder | None | No | |
| requestUnlock | `unlockEta[pool] = eta` | No | No external call after storage write (only event emission) |
| executeUnlock | `unlockEta[pool] = 0` | Potential | If `riskEngine.unlockPool()` reverts, pending unlock is cleared but pool remains locked |
| cancelUnlock | `unlockEta[pool] = 0` | No | No external call |
| deployBuilder | None before external call | No | `_requireContract(wallet)` is after, but is a view check |
| collect | None before `riskEngine.collect()` call | No | Balance read is via staticcall, state write (event) is after |

### E) Gas Griefing Analysis

External calls without gas limits that could be exploited:
1. `pool.riskEngine()` — if pool is attacker-controlled, can gas-bomb
2. `riskEngine.GUARDIAN()` via staticcall — same concern
3. `riskEngine.getFeeRecipient()` — same concern (only in builder auth path)
4. `builderWallet.builderAdmin()` — same concern (only in builder auth path)
5. `riskEngine.lockPool/unlockPool/collect` — state-changing, could gas-bomb

Impact: all gas griefing is scoped to the specific pool or builder interaction. An attacker cannot gas-bomb Guardian globally. The attacker would need to control the pool, RiskEngine, wallet, or token contract.

### F) Findings

For each finding:
- ID (REENT-NNN)
- Severity (Critical / High / Medium / Low / Informational)
- Category: reentrancy / callback / return-value / gas-griefing / cei-violation
- Complete attack sequence: entry → external call → callback → re-entry → state access
- Impact assessment
- Whether the attack requires controlling a trusted contract (RiskEngine, pool, token)

### G) Recommendations

For each finding:
1. Minimal code change
2. Assessment of whether the fix introduces new issues
3. Whether a reentrancy guard is warranted given the contract's access control model

## Review Rules

- Every reentrancy claim must trace the COMPLETE call path: entry → external call → callback → re-entry → state access.
- Guardian's access control (immutable addresses for admin/treasurer) naturally prevents reentrancy to most functions. Only `lockPoolAsBuilder` and view functions are callable by arbitrary addresses.
- Do not assume staticcall prevents all attacks — it prevents state changes but not gas consumption.
- "Protected by access control" must specify which immutable address would need to be the callback origin.
- Check that all effects happen BEFORE their corresponding external calls (CEI pattern).
- If an attack requires controlling a RiskEngine or pool contract, state this explicitly and assess feasibility.
```
