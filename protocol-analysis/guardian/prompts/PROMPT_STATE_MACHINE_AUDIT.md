# Access Control & State Machine Invariants Audit — Guardian.sol

```
You are a senior Solidity security researcher performing an access control and state machine invariants audit.

Scope restriction (hard):
- Analyze ONLY `src/Guardian.sol`.
- Ignore anything outside `src/`.

Objective:
Exhaustively evaluate all state transitions, access control boundaries, and protocol invariants in the Guardian contract to find:
1) State machine violations where an operation executes in an unexpected state
2) Access control gaps where a function is callable by an unintended party
3) Invariant violations where unlock tracking or revocation state drifts from expected values
4) Ordering dependencies where transaction sequencing produces protocol-inconsistent outcomes
5) Asymmetries between guardian admin and builder admin lock paths

Assumptions:
- Full MEV adversary with sandwich capability.
- Attacker can control multiple accounts simultaneously (sybil).
- Attacker may control a builder wallet contract (deploy arbitrary code at the wallet address).
- Attacker may deploy a contract that passes the RiskEngine GUARDIAN() check (returns address(this)).
- Any reachable state IS reached — "unlikely" is not a defense.
- Guardian has NO reentrancy guard — rely on external call safety analysis instead.
- GUARDIAN_ADMIN and TREASURER are immutable EOAs (no upgrade risk, but key compromise is in-scope).

Background context:
- Guardian manages pool locking/unlocking with a 1-hour timelock for unlocks.
- Three roles: GUARDIAN_ADMIN (lock, unlock, revoke, deploy), TREASURER (collect), Builder Admins (lock only).
- Builder authorization chain: msg.sender → riskEngine.getFeeRecipient(builderCode) → IBuilderWallet(wallet).builderAdmin() == msg.sender.
- `lockPool` (guardian admin) clears pending unlocks via `_clearPendingUnlock`. `lockPoolAsBuilder` does NOT.
- `unlockEta[pool]` stores the pending unlock timestamp. Zero means no pending unlock.
- `builderAdminRevoked[admin]` tracks revocation. Checked in `_isAuthorizedBuilder` before external calls.

Deliverables (strict order):

A) State Machine Map

### A1. Pool Unlock Lifecycle
Map the complete state machine for `unlockEta[pool]`:
- States: NO_PENDING_UNLOCK (eta==0), PENDING_UNLOCK (eta!=0, block.timestamp < eta), UNLOCK_READY (eta!=0, block.timestamp >= eta)
- Transitions: requestUnlock, executeUnlock, cancelUnlock, lockPool (guardian), lockPoolAsBuilder (builder)

For each transition, identify:
  a. Entry conditions (preconditions + access control)
  b. State changes (which storage slots are modified, which external calls are made)
  c. Exit conditions (postconditions)
  d. Events emitted

Critical questions:
- `lockPool` calls `_clearPendingUnlock` which cancels any pending unlock. `lockPoolAsBuilder` does NOT. This means a builder lock preserves a pending unlock. Can this lead to a state where a pool is locked but has a matured unlock that can be immediately executed? Trace: builder locks pool → time passes → guardian calls executeUnlock → pool unlocks despite being builder-locked. Is this intentional?
- Can `requestUnlock` be called on a pool that is already unlocked? The function only checks `unlockEta[pool] != 0`. It does NOT check whether the pool is currently locked. What happens if an unlock is requested and executed on an already-unlocked pool?
- `executeUnlock` clears `unlockEta` BEFORE calling `riskEngine.unlockPool()`. If the RiskEngine call reverts, the pending unlock is lost. Is this a problem? (The guardian admin can re-request.)
- Can the same pool be locked by both a guardian admin call and a builder admin call in the same block? Does the second lock have any different effect?

### A2. Builder Admin Revocation Lifecycle
Map the state machine for `builderAdminRevoked[admin]`:
- States: ACTIVE (false), REVOKED (true)
- Transitions: setBuilderAdminRevoked(admin, true), setBuilderAdminRevoked(admin, false)

Critical questions:
- Can a builder admin who is about to be revoked front-run the revocation transaction and lock a pool maliciously? The revocation and the lock are separate transactions with no atomic linkage.
- Can `setBuilderAdminRevoked` be called with the same value twice (revoke an already-revoked admin)? The function does not check the current value. This emits a misleading event.
- If a builder admin is revoked, then the builder wallet's admin is changed to a new address, then the original admin is restored — does the original admin regain lock authority? (Yes, because revocation is keyed on msg.sender, not the wallet.)

B) Access Control Matrix

For EVERY external/public function in Guardian.sol:

| Function | Access Control | Modifier | Can be called by contract? | State modified |
|----------|---------------|----------|---------------------------|----------------|

Specific areas to investigate:
- Are there any functions missing access control that should have it?
- `isBuilderAdmin` and `isPoolUnlockReady` are public view functions. Can they be used as oracles by external contracts in a way that creates manipulation vectors?
- `lockPoolAsBuilder` has no modifier — authorization is checked inline via `_isAuthorizedBuilder`. Verify this check cannot be bypassed.
- `collect` is guarded by `onlyTreasurer`. Verify the treasurer cannot be tricked into calling collect with a malicious RiskEngine address (the function validates via `_requireRecognizedRiskEngine`).

C) Invariant Analysis

### C1. Unlock ETA Semantics
**Invariant:** `unlockEta[pool] != 0` if and only if an unlock was requested and has not yet been executed or cancelled.

Questions:
- After `executeUnlock`, `unlockEta` is cleared to 0 BEFORE the external call. If the external call reverts, the ETA is still cleared. Is this a violation? (The unlock didn't actually happen, but the pending unlock record is gone.)
- After `lockPool` (guardian), any pending unlock is cleared. After `lockPoolAsBuilder`, it is NOT cleared. This creates an asymmetry. Document all paths that clear/preserve `unlockEta`.

### C2. Builder Revocation Blocking
**Invariant:** If `builderAdminRevoked[admin] == true`, then `lockPoolAsBuilder` reverts for that admin regardless of builder code or pool.

Questions:
- The revocation check at line 412 happens BEFORE the external calls to getFeeRecipient and builderAdmin. Is there a TOCTOU concern? (No, since revocation is a storage read with no gap — but verify.)
- Can the revocation check be bypassed by calling through a different entry point? (There is only one: `lockPoolAsBuilder`.)

### C3. RiskEngine Recognition
**Invariant:** Every state-changing operation that touches a RiskEngine validates `riskEngine.GUARDIAN() == address(this)` via `_getRiskEngine` or `_requireRecognizedRiskEngine`.

Questions:
- `lockPool`: calls `_getRiskEngine(pool)` which validates. ✓
- `lockPoolAsBuilder`: calls `_getRiskEngine(pool)` AND `_isAuthorizedBuilder` which also checks `_isRecognizedRiskEngine`. Double-validated. ✓
- `requestUnlock`: calls `_getRiskEngine(pool)`. ✓
- `executeUnlock`: calls `_getRiskEngine(pool)`. ✓
- `cancelUnlock`: calls `_requirePool(pool)` but does NOT call `_getRiskEngine`. It does NOT validate the RiskEngine. Is this acceptable? (cancelUnlock only modifies Guardian storage, not the RiskEngine.)
- `collect`: calls `_requireRecognizedRiskEngine`. ✓
- `deployBuilder`: does NOT validate any RiskEngine (operates on BuilderFactory). ✓

D) Ordering & Frontrunning Analysis

### D1. Builder Revocation Race
- A builder admin observes a `setBuilderAdminRevoked(admin, true)` transaction in the mempool.
- The builder front-runs with `lockPoolAsBuilder(pool, builderCode)` to maliciously lock a pool.
- Impact: pool is locked, users cannot trade until guardian unlocks (1-hour delay).
- Severity assessment: griefing only (no fund loss), but can be repeated if admin is restored.

### D2. Unlock Execution Griefing
- Guardian requests unlock. After 1 hour, guardian submits `executeUnlock`.
- An attacker (or malicious builder) front-runs with `lockPoolAsBuilder` (which does NOT clear the pending unlock).
- Guardian's `executeUnlock` succeeds — it calls `riskEngine.unlockPool()`.
- Question: does the RiskEngine honor an `unlockPool` call when the pool was just locked? Or does the builder's lock take precedence? This depends on RiskEngine implementation.
- If the RiskEngine tracks locks as a counter or flag, the unlock may cancel the builder's lock.

### D3. Lock-Unlock Atomicity
- Guardian calls `lockPool` which clears pending unlock AND locks.
- If `riskEngine.lockPool()` reverts, the pending unlock is already cleared (line 251-252: `_clearPendingUnlock` is called BEFORE `riskEngine.lockPool()`).
- This means a failed lock clears the pending unlock — potential state inconsistency.

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
- Do not dismiss a finding because "the guardian admin is trusted" without analyzing key compromise scenarios.
- Access control modifiers must be verified on EVERY external entry point.
- State machine transitions must be exhaustive: verify all state × transition combinations.
- "This would revert" is only a defense if the revert is BEFORE any state changes.
- Pay special attention to asymmetries between guardian admin and builder admin lock paths.
```
