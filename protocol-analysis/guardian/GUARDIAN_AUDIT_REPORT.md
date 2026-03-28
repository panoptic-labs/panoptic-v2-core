# Consolidated Security Audit Report — Guardian.sol

**Contract:** `src/Guardian.sol` (504 lines, Solidity ^0.8.30)
**Branch:** `docs/protocol-analysis`
**Date:** 2026-03-27
**Methodology:** 6 independent audit passes (state machine, reentrancy, arithmetic, diff review, builder auth chain, trust boundaries) followed by synthesis deduplication.

---

## Executive Summary

No **Critical** or **High** severity findings were identified. The Guardian contract exhibits a well-designed security posture with strong access control via immutable role addresses, correct CEI (checks-effects-interactions) patterns, and safe arithmetic. The contract's primary attack surface is its trust relationship with external RiskEngine contracts, which is inherent to the delegated architecture.

**Finding counts:** 0 Critical, 0 High, 4 Medium, 5 Low, 5 Informational

The top 3 areas needing attention:

1. **`collect()` event accuracy** — the full-balance path emits a pre-transfer balance snapshot that may diverge from actual amounts transferred (G-001)
2. **Unconditional event emission** — Guardian emits lock/unlock/collect events without verifying external contracts actually performed the action (G-002, G-003)
3. **Asymmetric lock semantics** — builder locks do not cancel pending unlocks, creating an operational risk where stale unlocks can override emergency builder locks (G-004)

---

## Findings

### G-001 — `collect()` Full-Balance Path Emits Inaccurate Event Amount

|                |                                                                      |
| -------------- | -------------------------------------------------------------------- |
| **Severity**   | Medium                                                               |
| **Category**   | Event Inaccuracy / Trust Assumption                                  |
| **File:Lines** | `src/Guardian.sol:363-371`                                           |
| **Passes**     | Arithmetic, Reentrancy, State Machine, Diff Review, Trust Boundaries |

**Description:**
When `amount == 0`, `collect()` snapshots the RiskEngine's token balance via `_balanceOfOrZero` _before_ calling `riskEngine.collect(token, recipient)`, then emits that pre-collect balance as `collectedAmount` in the `TokensCollected` event. The emitted amount may diverge from the actual transfer in several scenarios: fee-on-transfer tokens, MEV sandwich (attacker deposits/withdraws between snapshot and collect), RiskEngine retaining dust, or `balanceOf` reverting (which yields `collectedAmount = 0` while tokens may still transfer).

The NatSpec at line 351 states "computes the emitted amount from the RiskEngine's observed balance delta," but no delta is actually computed — only the pre-collect balance is used.

**Exploit Scenario:**

1. Treasurer submits `collect(riskEngine, feeToken, recipient, 0)` to the mempool.
2. `_balanceOfOrZero` reads balance as 1000.
3. `riskEngine.collect(feeToken, recipient)` transfers 950 tokens (50 token fee).
4. `TokensCollected` emits `amount = 1000` — overstating by 50.
5. Off-chain accounting records 1000; recipient received 950.

**Suggested Fix:**
Measure actual balance delta:

```solidity
if (amount == 0) {
    uint256 balBefore = _balanceOfOrZero(token, address(riskEngine));
    riskEngine.collect(token, recipient);
    uint256 balAfter = _balanceOfOrZero(token, address(riskEngine));
    collectedAmount = balBefore - balAfter;
}
```

Alternatively, document as a known limitation and advise off-chain systems to rely on ERC-20 `Transfer` events for precise amounts.

> **Note:** Commit `277012a` ("fix: use pre-collect amount when emitting transfer event") suggests this was a deliberate design choice. If so, update the NatSpec to match the implementation and document the trade-off.

---

### G-002 — `collect()` Delegates Token Transfer Without Post-Transfer Verification

|                |                              |
| -------------- | ---------------------------- |
| **Severity**   | Medium                       |
| **Category**   | Trust Assumption             |
| **File:Lines** | `src/Guardian.sol:356-372`   |
| **Passes**     | Reentrancy, Trust Boundaries |

**Description:**
Guardian delegates the entire token transfer to the RiskEngine via `riskEngine.collect(token, recipient, amount)` (or the full-balance overload) with no post-transfer verification. A compromised or buggy RiskEngine (e.g., after a proxy upgrade that preserves the `GUARDIAN()` return value) can: transfer fewer tokens than requested, transfer to a different address, or perform a no-op — while Guardian emits `TokensCollected` with the nominal values.

**Exploit Scenario:**

1. Attacker compromises a RiskEngine proxy admin and upgrades the implementation.
2. New implementation still returns `address(guardian)` from `GUARDIAN()`.
3. New `collect(token, recipient, amount)` sends tokens to the attacker instead of `recipient`.
4. Treasurer calls `Guardian.collect(riskEngine, token, recipient, amount)`.
5. Guardian emits `TokensCollected(token, recipient, amount)` — event is misleading.

**Suggested Fix:**
This is an inherent trust assumption of the delegated architecture. On-chain mitigation would require balance checks before and after the RiskEngine call, adding gas cost and potentially failing for rebasing tokens. **Recommended off-chain mitigation:** monitor ERC-20 `Transfer` events from RiskEngine addresses and alert on recipient/amount mismatches with `TokensCollected`.

---

### G-003 — RiskEngine `lockPool`/`unlockPool` May Silently No-Op; Events Emitted Unconditionally

|                |                                              |
| -------------- | -------------------------------------------- |
| **Severity**   | Medium                                       |
| **Category**   | Trust Assumption / Event Inaccuracy          |
| **File:Lines** | `src/Guardian.sol:252-253, 270-271, 297-299` |
| **Passes**     | Trust Boundaries                             |

**Description:**
Guardian emits `PoolLocked` / `PoolUnlocked` events after calling the RiskEngine, regardless of whether the RiskEngine actually changed the pool's state. A compromised or upgraded RiskEngine that makes `lockPool`/`unlockPool` into no-ops would cause Guardian events to diverge from actual pool state. Off-chain monitoring would believe a pool is locked/unlocked when it is not.

**Exploit Scenario:**

1. RiskEngine proxy is upgraded; `lockPool` becomes a no-op while `GUARDIAN()` is preserved.
2. Guardian admin calls `lockPool(pool)` in response to an emergency.
3. `riskEngine.lockPool(pool)` executes the no-op.
4. Guardian emits `PoolLocked(pool, admin)`.
5. Off-chain systems report "pool locked" — it is not. Emergency response is ineffective.

**Suggested Fix:**
There is no standard way to verify a lock/unlock took effect without knowing the RiskEngine's internal state. This is a fundamental trust assumption. **Recommended off-chain mitigation:** after Guardian emits `PoolLocked`/`PoolUnlocked`, independently verify pool state by querying the RiskEngine or pool. Alert if observed state does not match within a reasonable time.

---

### G-004 — Builder Emergency Lock Does Not Cancel Pending Unlock

|                |                                                                                                       |
| -------------- | ----------------------------------------------------------------------------------------------------- |
| **Severity**   | Medium                                                                                                |
| **Category**   | State Machine / Asymmetric Semantics                                                                  |
| **File:Lines** | `src/Guardian.sol:264-272` (`lockPoolAsBuilder`), `249-253` (`lockPool`), `289-300` (`executeUnlock`) |
| **Passes**     | State Machine, Diff Review                                                                            |

**Description:**
`lockPool` (guardian admin) clears any pending unlock via `_clearPendingUnlock` before locking. `lockPoolAsBuilder` (builder admin) does **not** clear pending unlocks — this was an intentional change in commit `e24c6f7`. The asymmetry means a builder can lock a pool for an emergency while a stale unlock request remains active. When the unlock ETA matures, `executeUnlock` can be called, overriding the builder's emergency lock.

**Exploit Scenario:**

1. Guardian admin calls `requestUnlock(pool)`. `unlockEta[pool]` is set.
2. Emergency occurs. Builder admin calls `lockPoolAsBuilder(pool, builderCode)` — pool is locked, but `unlockEta[pool]` is **not cleared**.
3. Time passes. The stale unlock matures.
4. Guardian admin (or automated keeper, unaware of the builder's emergency lock) calls `executeUnlock(pool)`.
5. `riskEngine.unlockPool(pool)` executes — pool is unlocked despite the builder's emergency lock.

**Suggested Fix:**
Add `_clearPendingUnlock(pool)` to `lockPoolAsBuilder` before the `riskEngine.lockPool` call:

```solidity
function lockPoolAsBuilder(IPanopticPoolV2 pool, uint256 builderCode) external {
  _requirePool(pool);
  IRiskEngine riskEngine = _getRiskEngine(pool);
  if (!_isAuthorizedBuilder(msg.sender, riskEngine, builderCode)) revert NotAuthorizedBuilder();
  _clearPendingUnlock(pool); // <-- add this
  riskEngine.lockPool(pool);
  emit PoolLocked(pool, msg.sender);
}
```

This makes lock semantics symmetric: any lock (guardian or builder) cancels pending unlocks. Alternatively, if the current behavior is intentional (builder locks are intentionally subordinate to admin unlocks), document this explicitly and ensure operational procedures account for it.

---

### G-005 — Event Pollution via Fake Pool/RiskEngine Chain in `lockPoolAsBuilder`

|                |                                                  |
| -------------- | ------------------------------------------------ |
| **Severity**   | Low                                              |
| **Category**   | Event Pollution / Validation Gap                 |
| **File:Lines** | `src/Guardian.sol:264-272`                       |
| **Passes**     | Builder Auth Chain, Trust Boundaries, Reentrancy |

**Description:**
`lockPoolAsBuilder` is the only permissionless state-changing entry point. An attacker can deploy a fake pool (returning a fake RiskEngine whose `GUARDIAN()` returns the real Guardian address), a fake builder wallet (returning the attacker as admin), and call `lockPoolAsBuilder`. All checks pass. The `PoolLocked` event is emitted for the fake pool address. No real pool is affected, but off-chain monitoring may trigger false alerts. Additionally, if the fake pool returns a _real_ RiskEngine, the builder admin can call `riskEngine.lockPool(fakePool)` on the legitimate RiskEngine, potentially polluting the RiskEngine's internal state.

**Exploit Scenario:**

1. Attacker deploys `FakeRE` (`GUARDIAN()` → real Guardian, `getFeeRecipient()` → `FakeWallet`, `lockPool()` → no-op).
2. Attacker deploys `FakeWallet` (`builderAdmin()` → attacker).
3. Attacker deploys `FakePool` (`riskEngine()` → `FakeRE`).
4. Attacker calls `lockPoolAsBuilder(FakePool, 1)`.
5. `PoolLocked(FakePool, attacker)` is emitted — confuses off-chain indexers.

**Suggested Fix:**
Off-chain indexers should maintain a whitelist of known pool addresses and flag events for unrecognized pools. On-chain, a pool registry could be added but introduces operational overhead. Alternatively, the RiskEngine's `lockPool` implementation should validate that the pool is one it manages.

---

### G-006 — Builder Admin Revocation Front-Running

|                |                                     |
| -------------- | ----------------------------------- |
| **Severity**   | Low                                 |
| **Category**   | Ordering / MEV                      |
| **File:Lines** | `src/Guardian.sol:264-272, 315-325` |
| **Passes**     | State Machine                       |

**Description:**
A builder admin who observes a pending `setBuilderAdminRevoked(admin, true)` transaction in the mempool can front-run it with `lockPoolAsBuilder(pool, builderCode)` to maliciously lock pools before revocation takes effect.

**Exploit Scenario:**

1. Guardian admin submits `setBuilderAdminRevoked(attacker, true)` to public mempool.
2. Attacker front-runs with `lockPoolAsBuilder(pool, builderCode)`.
3. Pool is locked. Revocation confirms in the next transaction.
4. Guardian must wait 1 hour to unlock.

**Suggested Fix:**
Inherent to any 2-transaction revocation pattern. Mitigate by using Flashbots Protect, a private mempool, or a multicall that atomically revokes + locks in a single transaction.

---

### G-007 — `requestUnlock` Does Not Verify Pool Is Locked

|                |                            |
| -------------- | -------------------------- |
| **Severity**   | Low                        |
| **Category**   | State Machine              |
| **File:Lines** | `src/Guardian.sol:276-284` |
| **Passes**     | State Machine              |

**Description:**
`requestUnlock` checks only that `unlockEta[pool] == 0` (no pending unlock). It does not verify whether the pool is actually locked on the RiskEngine. An unlock request can be created for an already-unlocked pool. When `executeUnlock` fires, the RiskEngine's `unlockPool` is called on an unlocked pool — behavior depends on the RiskEngine implementation (no-op or revert).

**Exploit Scenario:**

1. Pool is already unlocked.
2. Guardian admin calls `requestUnlock(pool)` — succeeds.
3. After 1 hour, `executeUnlock(pool)` calls `riskEngine.unlockPool()` on an unlocked pool.

**Suggested Fix:**
Requires querying the RiskEngine for the pool's lock state, which is not currently part of the `IRiskEngine` interface. Document as a known limitation; the guardian admin is expected to be aware of pool state.

---

### G-008 — Silent Denial of Builder Lock Authority on Wallet Misconfiguration

|                |                            |
| -------------- | -------------------------- |
| **Severity**   | Low                        |
| **Category**   | Failure Mode / UX          |
| **File:Lines** | `src/Guardian.sol:420-434` |
| **Passes**     | Builder Auth Chain         |

**Description:**
If a canonical builder wallet's `builderAdmin()` reverts (due to upgrade issue, storage corruption, or pause), the try-catch in `_isAuthorizedBuilder` silently returns `false`. `lockPoolAsBuilder` reverts with `NotAuthorizedBuilder()`, which doesn't indicate whether the failure is "you are not authorized" vs. "the wallet is broken." During a time-critical emergency, a builder admin cannot distinguish authorization failure from wallet misconfiguration.

**Suggested Fix:**
Add a diagnostic view function `diagnoseBuilderAuth(account, pool, builderCode)` that returns a descriptive enum indicating which step failed (revoked, unrecognized RiskEngine, wallet not deployed, wallet reverted, admin mismatch). Alternatively, use descriptive custom errors in `_isAuthorizedBuilder`.

---

### G-009 — Immutable Roles and Factory Cannot Be Rotated

|                |                                     |
| -------------- | ----------------------------------- |
| **Severity**   | Low                                 |
| **Category**   | Upgrade Risk                        |
| **File:Lines** | `src/Guardian.sol:201-207, 222-232` |
| **Passes**     | Trust Boundaries, Diff Review       |

**Description:**
`GUARDIAN_ADMIN`, `TREASURER`, and `BUILDER_FACTORY` are all immutable. If any key is compromised, lost, or the factory has a critical bug, the entire Guardian must be redeployed and all RiskEngines must update their `GUARDIAN()` pointer. During the transition window, the old compromised Guardian may still be recognized.

**Suggested Fix:**
This is an accepted design trade-off (immutability prevents governance attacks). Ensure admin and treasurer are multisig wallets with appropriate signer thresholds. Maintain a tested Guardian migration runbook.

---

### G-010 — `_isAuthorizedBuilder` try-catch Uses CALL Instead of STATICCALL

|                |                             |
| -------------- | --------------------------- |
| **Severity**   | Informational               |
| **Category**   | Defensive Hardening         |
| **File:Lines** | `src/Guardian.sol:420, 430` |
| **Passes**     | Reentrancy                  |

**Description:**
`try riskEngine.getFeeRecipient(builderCode)` and `try IBuilderWallet(wallet).builderAdmin()` use Solidity's `try` statement, which compiles to `CALL` (not `STATICCALL`) even though both interface methods are declared `view`. This is inconsistent with the raw `staticcall` pattern used in `_isRecognizedRiskEngine` and `_balanceOfOrZero`. A malicious RiskEngine or wallet could perform state changes during these calls, though no Guardian state is at risk since no storage has been modified at these call sites.

**Suggested Fix:**
Replace the `try` calls with raw `staticcall` + manual ABI decoding, consistent with `_isRecognizedRiskEngine`. This is a hardening measure with no functional impact.

---

### G-011 — Idempotent `setBuilderAdminRevoked` Emits Duplicate Events

|                |                            |
| -------------- | -------------------------- |
| **Severity**   | Informational              |
| **Category**   | Event Accuracy             |
| **File:Lines** | `src/Guardian.sol:315-325` |
| **Passes**     | State Machine              |

**Description:**
`setBuilderAdminRevoked(admin, true)` called twice emits `BuilderAdminRevoked(admin)` twice. Calling `setBuilderAdminRevoked(admin, false)` on an already-active admin emits `BuilderAdminRestored(admin)` even though no state changed. This can mislead off-chain indexers.

**Suggested Fix:**
Add an early return if the current value matches the target:

```solidity
if (builderAdminRevoked[admin] == revoked) return;
```

---

### G-012 — Constructor Allows `guardianAdmin == treasurer`

|                |                            |
| -------------- | -------------------------- |
| **Severity**   | Informational              |
| **Category**   | Role Separation            |
| **File:Lines** | `src/Guardian.sol:222-232` |
| **Passes**     | Diff Review                |

**Description:**
The constructor does not prevent deploying with the same address for `guardianAdmin` and `treasurer`. If both roles share a key, a single compromise grants both lock/unlock authority and token collection authority.

**Suggested Fix:**
Consider adding `if (guardianAdmin == treasurer) revert ...;` or document this as an accepted deployment-time decision.

---

### G-013 — Broad Revocation Scope Prevents Per-BuilderCode Granularity

|                |                             |
| -------------- | --------------------------- |
| **Severity**   | Informational               |
| **Category**   | Design                      |
| **File:Lines** | `src/Guardian.sol:210, 412` |
| **Passes**     | Builder Auth Chain          |

**Description:**
`builderAdminRevoked` is keyed on `address` only, not `(address, builderCode)`. Revoking an admin disables all their builder codes across all RiskEngines simultaneously. This is more secure (single call for full revocation) but less flexible (cannot selectively revoke one builder code).

**Suggested Fix:**
Accepted design trade-off. The broad scope is arguably safer for emergency response.

---

### G-014 — Redundant `_requirePool` in `lockPoolAsBuilder`

|                |                             |
| -------------- | --------------------------- |
| **Severity**   | Informational               |
| **Category**   | Gas Optimization            |
| **File:Lines** | `src/Guardian.sol:265, 267` |
| **Passes**     | Builder Auth Chain          |

**Description:**
`lockPoolAsBuilder` calls `_requirePool(pool)` at line 265, then `_getRiskEngine(pool)` at line 267 which calls `_requirePool(pool)` again internally. The first call is redundant.

**Suggested Fix:**
Remove the `_requirePool(pool)` call at line 265 to save ~200 gas per call.

---

## Overall Risk Assessment

The Guardian contract is **well-designed and secure** for its intended purpose. Key strengths:

- **Strong access control:** Immutable `GUARDIAN_ADMIN` and `TREASURER` addresses provide natural reentrancy protection — privileged functions cannot be re-entered through external callbacks since `msg.sender` would not match the immutable addresses.
- **Correct CEI patterns:** `lockPool` and `executeUnlock` clear `unlockEta` before external calls, preventing double-execution. `lockPoolAsBuilder` modifies no state before its external call.
- **Minimal arithmetic surface:** One addition (overflow-impossible), one narrowing cast (range-guarded). No unchecked blocks or assembly.
- **Defensive external call handling:** Raw `staticcall` with proper return data validation for recognition checks and balance queries. Try-catch for builder authorization with fail-closed semantics.

**Residual risks accepted by design:**

1. Guardian trusts RiskEngines to faithfully execute `lockPool`, `unlockPool`, and `collect`. A compromised RiskEngine that preserves the `GUARDIAN()` return value can cause arbitrary damage.
2. Immutable roles cannot be rotated — key compromise requires Guardian redeployment.
3. No on-chain pool registry — off-chain systems must independently verify pool legitimacy when processing Guardian events.

**Publication readiness: CONDITIONAL PASS** — no fund-safety blockers. Address G-001 (event accuracy documentation or fix) and consider G-004 (asymmetric lock semantics) before publication.
