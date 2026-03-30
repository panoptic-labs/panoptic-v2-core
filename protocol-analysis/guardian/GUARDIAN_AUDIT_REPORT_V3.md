# PanopticGuardian Security Audit Report (V3)

**Scope:** `contracts/PanopticGuardian.sol`, `contracts/Builder.sol` (BuilderWallet, BuilderFactory)
**Branch:** `feat/guardian-contract`
**Commits reviewed:** `5d134780` through `6fa18827`
**Date:** 2026-03-30

---

## Executive Summary

The PanopticGuardian contract manages pool locking/unlocking with a 1-hour timelock, builder admin authorization, wallet deployment, and protocol fee collection. The audit covers the **current state** after commit `636cae30` ("removed contract-related checks") and `6fa18827` ("add execute, receive, and ERC-1271 to BuilderWallet").

**Overall Verdict: CONDITIONAL PASS** — No critical or high-severity vulnerabilities. The contract's security fundamentally relies on correct trust boundaries at the RiskEngine level (`onlyGuardian`) and Pool level (`onlyRiskEngine`), which are intact. Several low-severity and informational findings are detailed below.

---

## Architecture & Trust Model

### Roles

| Role             | Address Type         | Authority                                     |
| ---------------- | -------------------- | --------------------------------------------- |
| `GUARDIAN_ADMIN` | Immutable (multisig) | Lock, unlock, revoke builders, deploy wallets |
| `TREASURER`      | Immutable (multisig) | Collect tokens from RiskEngines               |
| Builder Admin    | Dynamic (per-wallet) | Lock pools only (no unlock)                   |

### Trust Chain

```
GUARDIAN_ADMIN ─→ PanopticGuardian ─→ RiskEngine ─→ PanopticPool
                                        │
                                        ├─ lockPool(pool)    [onlyGuardian]
                                        ├─ unlockPool(pool)  [onlyGuardian]
                                        └─ collect(...)      [onlyGuardian]
```

The key security property: even if the Guardian is tricked into calling a fake RiskEngine, no real pool is affected because the real RiskEngine checks `msg.sender == GUARDIAN` and the real Pool checks `msg.sender == riskEngine()`.

### Validation Removal Context

Commit `636cae30` removed all Guardian-side validation:

- `_requirePool` (zero address + code length checks)
- `_requireRecognizedRiskEngine` (GUARDIAN() mutual recognition)
- `_isRecognizedRiskEngine` inside `_isAuthorizedBuilder`
- `_requireContract` after `deployBuilder`
- Pool validation in `isBuilderAdmin` view function

**Rationale:** These checks were redundant given the downstream `onlyGuardian` / `onlyRiskEngine` modifiers. The old `_isRecognizedRiskEngine` check was bypassable by deploying a contract that returns `GUARDIAN() == address(realGuardian)`.

---

## Consolidated Findings

### G-01 | Medium | Removed `_requireRecognizedRiskEngine` from `collect()` — Reduced Defense-in-Depth

**File:** `PanopticGuardian.sol:260-277`

**Description:** `collect()` accepts `riskEngine` as a **direct parameter** (not derived from a pool). Commit `636cae30` removed the `_requireRecognizedRiskEngine` validation that verified `riskEngine.GUARDIAN() == address(this)` via staticcall. This is the only function where the RiskEngine address is caller-supplied rather than pool-derived.

**Why this is not Critical/High:** A compromised TREASURER can drain tokens from any real RiskEngine regardless of whether the check exists — real RiskEngines pass validation. The old check was also bypassable (attacker deploys contract returning `GUARDIAN() == realGuardian`).

**Residual risk:** Without the check, the TREASURER can call `.collect()` on **any** contract that happens to have a matching function signature, using the PanopticGuardian as `msg.sender`. While the Guardian holds no tokens itself, it may hold privileged roles on other contracts. The check provided a safeguard against accidental misconfiguration (wrong address passed to `collect`).

**Recommendation:** Restore a lightweight validation or accept the risk given TREASURER is an immutable multisig:

```solidity
// Option: validate riskEngine has code (minimal gas, catches obvious errors)
if (address(riskEngine).code.length == 0) revert ZeroAddress();
```

---

### G-02 | Medium | RiskEngine Destruction Permanently Locks Pools

**File:** Architectural (affects `lockPool`, `executeUnlock`)

**Description:** `pool.riskEngine()` returns an immutable address from the Clone's bytecode. If that RiskEngine is bricked (proxy upgrade failure, or self-destruct pre-Dencun), all Guardian calls to `lockPool`/`unlockPool` revert. Pools locked at the time become **permanently locked** with no on-chain recovery path.

**Preconditions:** RiskEngine contract becomes non-functional (proxy bricked, code cleared). The current RiskEngine is not upgradeable and has no `SELFDESTRUCT`, so this is primarily a concern for future proxy-based deployments.

**Impact:** Permanent DoS on affected pools. Users in safe mode cannot trade normally.

**Recommendation:** Document this as an accepted architectural risk. Consider an emergency bypass at the Pool level for catastrophic RiskEngine failure, or ensure RiskEngine implementations are never upgradeable.

---

### G-03 | Low | Builder Revocation Front-Running Allows Last-Minute Pool Locks

**File:** `PanopticGuardian.sol:164-171` and `213-223`

**Description:** A builder admin who sees a pending `setBuilderAdminRevoked(admin, true)` in the mempool can front-run with multiple `lockPoolAsBuilder` calls, locking arbitrary pools before revocation takes effect. The Guardian admin must then `requestUnlock` + wait 1 hour + `executeUnlock` for each affected pool.

**Impact:** Temporary griefing. Pools enter safe mode (protective, not destructive). No fund loss. The 1-hour unlock timelock creates operational friction.

**Recommendation:** Accept as design trade-off. The guardian admin can use private mempools (Flashbots Protect) for revocation transactions. Alternatively, add batch unlock support to reduce operational overhead.

---

### G-04 | Low | `lockPoolAsBuilder` Preserves Pending Unlocks — Intentional but Exploitable Asymmetry

**File:** `PanopticGuardian.sol:164-171`

**Description:** Unlike `lockPool` (guardian admin), `lockPoolAsBuilder` does NOT call `_clearPendingUnlock`. This means a builder lock preserves a matured unlock ETA. A guardian admin can `executeUnlock` immediately after a builder lock, negating the builder's emergency lock. Conversely, a builder cannot block a pre-existing unlock schedule.

**Per NatSpec:** This is intentional — "Builder locks are subordinate to the guardian admin's unlock lifecycle."

**Edge case:** A builder detects an exploit and locks a pool, but a previously-scheduled `executeUnlock` immediately re-opens it.

**PoC sequence:**

1. Guardian admin calls `requestUnlock(pool)` — `unlockEta[pool] = now + 1h`
2. 30 minutes later, builder detects an issue, calls `lockPoolAsBuilder(pool, builderCode)` — pool is locked, but `unlockEta[pool]` is unchanged
3. 30 more minutes later (ETA matures), guardian admin calls `executeUnlock(pool)` — pool is unlocked despite the builder's lock

**Recommendation:** Document this trade-off prominently. Consider whether builder locks should at minimum emit a warning event when a pending unlock exists.

---

### G-05 | Low | Event Pollution via Fake Pool Chains in `lockPoolAsBuilder`

**File:** `PanopticGuardian.sol:164-171`

**Description:** With all validation removed, an attacker can deploy FakePool → FakeRiskEngine → FakeWallet and call `lockPoolAsBuilder(FakePool, 1)`. All authorization checks pass (attacker controls the full chain). The `PoolLocked(FakePool, attacker)` event is emitted from the legitimate PanopticGuardian address. No real pool is affected (the real RiskEngine's `onlyGuardian` and the real Pool's `onlyRiskEngine` prevent cross-contamination).

**Impact:** Off-chain monitoring noise. Indexers that don't filter by known pool addresses will see spurious events.

**Recommendation:** Off-chain systems should verify pool addresses against a canonical registry (e.g., PanopticFactory deployment records).

---

### G-06 | Informational | `isBuilderAdmin` Now Reverts Instead of Returning False for Invalid Pools

**File:** `PanopticGuardian.sol:286-293`

**Description:** The old code returned `false` for `address(0)` or codeless pool addresses. The new code calls `_getRiskEngine(pool)` which reverts on invalid addresses (ABI decode failure). This is a **breaking behavioral change** for off-chain integrations.

**Recommendation:** Restore the graceful handling:

```solidity
function isBuilderAdmin(
  address account,
  PanopticPoolV2 pool,
  uint256 builderCode
) external view returns (bool) {
  if (address(pool) == address(0) || address(pool).code.length == 0) return false;
  IRiskEngine riskEngine = _getRiskEngine(pool);
  return _isAuthorizedBuilder(account, riskEngine, builderCode);
}
```

---

### ~~G-07~~ | ~~Informational~~ | ~~Stale NatSpec on `_getRiskEngine`~~ — RESOLVED

**File:** `PanopticGuardian.sol:356-361`

**Description:** NatSpec previously read _"Returns a pool's RiskEngine after validating both contracts and guardian wiring."_ The function performs zero validation.

**Resolution:** NatSpec updated to _"Returns the RiskEngine address embedded in a pool's immutable clone arguments."_

---

### G-08 | Informational | Loss of Descriptive Error Messages

**File:** Multiple functions

**Description:** The removal of `_requirePool`, `_requireContract`, and `_requireRecognizedRiskEngine` means invalid inputs now produce opaque ABI decode reverts instead of clean custom errors (`ZeroAddress()`, `NotContract()`, `RiskEngineDoesNotRecognizeGuardian()`).

**Recommendation:** Consider adding a minimal zero-address guard in `_getRiskEngine`:

```solidity
function _getRiskEngine(PanopticPoolV2 pool) internal pure returns (IRiskEngine riskEngine) {
  if (address(pool) == address(0)) revert ZeroAddress();
  riskEngine = pool.riskEngine();
}
```

---

### G-09 | Informational | `requestUnlock` Does Not Verify Pool Is Currently Locked

**File:** `PanopticGuardian.sol:175-183`

**Description:** The guardian admin can queue an unlock for a pool that is already unlocked. If the RiskEngine's `unlockPool` rejects this (reverts), the ETA is already cleared (CEI ordering), wasting the 1-hour wait.

---

### G-10 | Informational | Builder Admin Restoration Has No Timelock

**File:** `PanopticGuardian.sol:213-223`

**Description:** `setBuilderAdminRevoked(admin, false)` is instant, while pool unlocks require a 1-hour delay. A compromised guardian admin could instantly restore a revoked builder, who could then immediately lock pools.

---

### G-11 | Informational | `collect()` Event Inaccuracy for Fee-on-Transfer Tokens

**File:** `PanopticGuardian.sol:268-276`

**Description:** The `amount == 0` path snapshots the balance before calling `riskEngine.collect()`. For fee-on-transfer tokens, the emitted `collectedAmount` overstates the actual received amount. This is documented in NatSpec.

---

### G-12 | Informational | No Arithmetic Vulnerabilities

The contract's arithmetic surface is minimal and safe:

- `block.timestamp + UNLOCK_DELAY`: overflow impossible (uint256 with ~10-digit timestamp + 3600)
- `uint48(builderCode)`: protected by prior range check at line 236
- All other operations are pure comparisons

---

## Reentrancy Assessment

**No exploitable reentrancy paths exist.** The contract has no reentrancy guard, but immutable access control (`GUARDIAN_ADMIN`, `TREASURER`) naturally blocks re-entry to all privileged functions. The only publicly-callable function (`lockPoolAsBuilder`) modifies no state before its external call. The downstream call chain (RiskEngine → Pool) terminates at simple storage writes with no callbacks.

The CEI inversions in `lockPool` (clears ETA before `riskEngine.lockPool()`) and `executeUnlock` (clears ETA before `riskEngine.unlockPool()`) are **intentional and safe** — they provide defense-in-depth against hypothetical reentrancy, and revert atomicity prevents state loss.

---

## BuilderWallet Additions (commit 6fa18827)

The `execute()`, `receive()`, and `isValidSignature()` additions are **clean and secure**:

- **`execute()`**: Arbitrary external call, gated by `builderAdmin`. Uses `.call()` (not `.delegatecall()`), so wallet storage cannot be corrupted by target contracts. Cannot re-enter Guardian admin functions (msg.sender = wallet ≠ GUARDIAN_ADMIN). Cannot pass `lockPoolAsBuilder` auth (wallet ≠ builderAdmin).
- **`receive()`**: Allows ETH reception. Required for DeFi interactions.
- **`isValidSignature()`**: Standard ERC-1271 using OpenZeppelin's `SignatureChecker`. Correct magic values.

---

## State Machine Map

### Pool Unlock Lifecycle

```
                    requestUnlock()
  NO_PENDING ─────────────────────────→ PENDING_UNLOCK
  (eta == 0)          [guardianAdmin]   (eta != 0, now < eta)
      ↑                                       │
      │                                       │ (time passes)
      │                                       ▼
      │     cancelUnlock()              UNLOCK_READY
      ├──────────────────── ←───────── (eta != 0, now >= eta)
      │     [guardianAdmin]                   │
      │                                       │ executeUnlock()
      │     lockPool()                        │ [guardianAdmin]
      ├──────────────────── ←─────────────────┘
      │     [guardianAdmin]
      │     (clears pending)
      │
      │     lockPoolAsBuilder()
      │     [builderAdmin]
      │     (does NOT clear pending)
      │
```

### Builder Admin Revocation

```
  ACTIVE ←────────────────────→ REVOKED
  (revoked == false)            (revoked == true)
         setBuilderAdminRevoked()
         [guardianAdmin, instant both ways]
```

---

## Access Control Matrix

| Function                 | Access Control         | Modifier                             | Callable by Contract?              | State Modified               |
| ------------------------ | ---------------------- | ------------------------------------ | ---------------------------------- | ---------------------------- |
| `lockPool`               | Guardian admin         | `onlyGuardianAdmin`                  | Yes (if contract is admin)         | `unlockEta[pool]` cleared    |
| `lockPoolAsBuilder`      | Builder admin (inline) | None (inline `_isAuthorizedBuilder`) | Yes (if contract is builder admin) | None in Guardian             |
| `requestUnlock`          | Guardian admin         | `onlyGuardianAdmin`                  | Yes                                | `unlockEta[pool]` set        |
| `executeUnlock`          | Guardian admin         | `onlyGuardianAdmin`                  | Yes                                | `unlockEta[pool]` cleared    |
| `cancelUnlock`           | Guardian admin         | `onlyGuardianAdmin`                  | Yes                                | `unlockEta[pool]` cleared    |
| `setBuilderAdminRevoked` | Guardian admin         | `onlyGuardianAdmin`                  | Yes                                | `builderAdminRevoked[admin]` |
| `deployBuilder`          | Guardian admin         | `onlyGuardianAdmin`                  | Yes                                | External (factory)           |
| `collect`                | Treasurer              | `onlyTreasurer`                      | Yes                                | None in Guardian             |
| `isBuilderAdmin`         | None (view)            | —                                    | Yes                                | None                         |
| `isPoolUnlockReady`      | None (view)            | —                                    | Yes                                | None                         |

---

## Summary Table

| ID   | Severity          | Category          | Title                                                  | Status       |
| ---- | ----------------- | ----------------- | ------------------------------------------------------ | ------------ |
| G-01 | Medium            | Trust Boundary    | `collect()` accepts unvalidated `riskEngine` parameter | Open         |
| G-02 | Medium            | Availability      | RiskEngine destruction permanently locks pools         | Open         |
| G-03 | Low               | Frontrunning      | Builder revocation front-running griefing              | Open         |
| G-04 | Low               | State Machine     | Builder lock preserves pending unlocks (intentional)   | Open         |
| G-05 | Low               | Event Integrity   | Event pollution via fake pool chains                   | Open         |
| G-06 | Informational     | UX/Integration    | `isBuilderAdmin` behavior change                       | Open         |
| G-07 | ~~Informational~~ | ~~Documentation~~ | ~~Stale NatSpec on `_getRiskEngine`~~                  | **Resolved** |
| G-08 | Informational     | UX                | Loss of descriptive error messages                     | Open         |
| G-09 | Informational     | State Machine     | `requestUnlock` on unlocked pool                       | Open         |
| G-10 | Informational     | Design            | No timelock on builder admin restoration               | Open         |
| G-11 | Informational     | Event Accuracy    | `collect()` event inaccuracy for FoT tokens            | Open         |
| G-12 | Informational     | Arithmetic        | No arithmetic issues found                             | N/A          |
