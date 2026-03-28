# Consolidated Security Audit Report — Guardian.sol (v2)

**Contract:** `src/Guardian.sol` (519 lines, Solidity ^0.8.30)
**Branch:** `docs/protocol-analysis`
**Date:** 2026-03-27
**Methodology:** 6 independent audit passes (state machine, reentrancy, arithmetic, diff review, builder auth chain, trust boundaries) followed by synthesis deduplication and manual validation.

---

## Executive Summary

No **Critical**, **High**, or **Medium** severity findings were identified. The Guardian contract exhibits a well-designed security posture with strong access control via immutable role addresses, correct CEI (checks-effects-interactions) patterns, and safe arithmetic.

**Finding counts:** 0 Critical, 0 High, 0 Medium, 3 Low, 7 Informational

The contract's primary trust dependency is on external RiskEngine contracts, which is inherent to the delegated architecture and explicitly documented. All intentional design decisions (pre-collect balance snapshot in `collect`, builder lock subordination to admin unlocks, immutable roles) have been verified against the codebase and NatSpec.

---

## Findings

### G-001 — Event Pollution via Fake Pool/RiskEngine Chain in `lockPoolAsBuilder`

|                |                                                  |
| -------------- | ------------------------------------------------ |
| **Severity**   | Low                                              |
| **Category**   | Event Pollution / Validation Gap                 |
| **File:Lines** | `src/Guardian.sol:276-283`                       |
| **Passes**     | Builder Auth Chain, Trust Boundaries, Reentrancy |

**Description:**
`lockPoolAsBuilder` is the only permissionless state-changing entry point. An attacker can deploy a fake pool (returning a fake RiskEngine whose `GUARDIAN()` returns the real Guardian address), a fake builder wallet (returning the attacker as admin), and call `lockPoolAsBuilder`. All checks pass. The `PoolLocked` event is emitted for the fake pool address. No real pool is affected, but off-chain monitoring may trigger false alerts.

**Exploit Scenario:**

1. Attacker deploys `FakeRE` (`GUARDIAN()` returns real Guardian, `getFeeRecipient()` returns `FakeWallet`, `lockPool()` is a no-op).
2. Attacker deploys `FakeWallet` (`builderAdmin()` returns attacker).
3. Attacker deploys `FakePool` (`riskEngine()` returns `FakeRE`).
4. Attacker calls `lockPoolAsBuilder(FakePool, 1)`.
5. `PoolLocked(FakePool, attacker)` is emitted for a non-existent pool.

**Suggested Fix:**
Off-chain indexers should maintain a whitelist of known pool addresses and flag events for unrecognized pools. On-chain, the RiskEngine's `lockPool` implementation should validate that the pool is one it manages.

---

### G-002 — Builder Admin Revocation Front-Running

|                |                                     |
| -------------- | ----------------------------------- |
| **Severity**   | Low                                 |
| **Category**   | Ordering / MEV                      |
| **File:Lines** | `src/Guardian.sol:276-283, 327-337` |
| **Passes**     | State Machine                       |

**Description:**
A builder admin who observes a pending `setBuilderAdminRevoked(admin, true)` transaction in the mempool can front-run it with `lockPoolAsBuilder(pool, builderCode)` to maliciously lock pools before revocation takes effect. Impact is griefing only — pool is locked for at minimum 1 hour, no fund loss.

**Exploit Scenario:**

1. Guardian admin submits `setBuilderAdminRevoked(attacker, true)` to public mempool.
2. Attacker front-runs with `lockPoolAsBuilder(pool, builderCode)`.
3. Pool is locked. Revocation confirms in the next transaction.
4. Guardian must wait 1 hour to unlock.

**Suggested Fix:**
Inherent to any 2-transaction revocation pattern. Mitigate by using Flashbots Protect, a private mempool, or a multicall that atomically revokes and locks in a single transaction.

---

### G-003 — Silent Denial of Builder Lock Authority on Wallet Misconfiguration

|                |                            |
| -------------- | -------------------------- |
| **Severity**   | Low                        |
| **Category**   | Failure Mode / UX          |
| **File:Lines** | `src/Guardian.sol:434-449` |
| **Passes**     | Builder Auth Chain         |

**Description:**
If a canonical builder wallet's `builderAdmin()` reverts (due to upgrade issue, storage corruption, or pause), the try-catch in `_isAuthorizedBuilder` silently returns `false`. `lockPoolAsBuilder` reverts with `NotAuthorizedBuilder()`, which doesn't indicate whether the failure is "you are not authorized" vs. "the wallet is broken." During a time-critical emergency, a builder admin cannot distinguish authorization failure from wallet misconfiguration.

**Suggested Fix:**
Add a diagnostic view function `diagnoseBuilderAuth(account, pool, builderCode)` that returns a descriptive enum indicating which step failed (revoked, unrecognized RiskEngine, wallet not deployed, wallet reverted, admin mismatch). Alternatively, use descriptive custom errors in `_isAuthorizedBuilder`.

---

### G-004 — `collect()` Full-Balance Path Event Amount Is a Pre-Transfer Snapshot

|                |                                                                      |
| -------------- | -------------------------------------------------------------------- |
| **Severity**   | Informational                                                        |
| **Category**   | Event Accuracy (Documented Design Choice)                            |
| **File:Lines** | `src/Guardian.sol:378-386`                                           |
| **Passes**     | Arithmetic, Reentrancy, State Machine, Diff Review, Trust Boundaries |

**Description:**
When `amount == 0`, `collect()` snapshots the RiskEngine's token balance via `_balanceOfOrZero` before calling `riskEngine.collect(token, recipient)`, then emits that pre-collect balance as `collectedAmount`. The emitted amount may diverge from the actual transfer for fee-on-transfer tokens or if the RiskEngine's balance changes between the snapshot and the transfer. This is a deliberate design choice (commit `277012a`) and is accurately documented in the NatSpec (lines 362-366). Off-chain systems should rely on ERC-20 `Transfer` events for precise amounts.

---

### G-005 — Builder Lock Intentionally Does Not Cancel Pending Unlocks

|                |                                                                          |
| -------------- | ------------------------------------------------------------------------ |
| **Severity**   | Informational                                                            |
| **Category**   | State Machine (Documented Design Choice)                                 |
| **File:Lines** | `src/Guardian.sol:276-283` (`lockPoolAsBuilder`), `254-258` (`lockPool`) |
| **Passes**     | State Machine, Diff Review                                               |

**Description:**
`lockPool` (guardian admin) clears pending unlocks via `_clearPendingUnlock` before locking. `lockPoolAsBuilder` (builder admin) intentionally does not (commit `e24c6f7`). This means a builder's emergency lock does not reset a pending unlock — if the unlock ETA matures, `executeUnlock` can still be called. This is by design: builder locks are subordinate to the guardian admin's unlock lifecycle, ensuring builders cannot unilaterally block the admin's unlock schedule. The asymmetry is documented in the NatSpec (lines 268-273). The guardian admin has full visibility via `PoolLocked` events and can `cancelUnlock` if they choose to honor the builder's lock.

---

### G-006 — `requestUnlock` Does Not Verify Pool Is Locked

|                |                            |
| -------------- | -------------------------- |
| **Severity**   | Informational              |
| **Category**   | State Machine              |
| **File:Lines** | `src/Guardian.sol:288-296` |
| **Passes**     | State Machine              |

**Description:**
`requestUnlock` checks only that `unlockEta[pool] == 0` (no pending unlock). It does not verify whether the pool is actually locked on the RiskEngine. An unlock request can be created for an already-unlocked pool. When `executeUnlock` fires, the RiskEngine's `unlockPool` is called on an unlocked pool — the RiskEngine handles this (no-op or revert), and in either case the entire transaction reverts or is harmless. Guardian's own state remains consistent. The function is `onlyGuardianAdmin`, and the admin is expected to be aware of pool state. Adding a lock-state check would require extending the `IRiskEngine` interface.

---

### G-007 — Immutable Roles and Factory Cannot Be Rotated

|                |                                         |
| -------------- | --------------------------------------- |
| **Severity**   | Informational                           |
| **Category**   | Upgrade Risk (Documented Design Choice) |
| **File:Lines** | `src/Guardian.sol:205-212, 227-237`     |
| **Passes**     | Trust Boundaries, Diff Review           |

**Description:**
`GUARDIAN_ADMIN`, `TREASURER`, and `BUILDER_FACTORY` are all immutable. Key compromise or factory bugs require redeploying the Guardian and updating all RiskEngine pointers. This is an accepted design trade-off — immutability prevents governance attacks. The NatSpec (lines 129-132) documents the recommendation that both `GUARDIAN_ADMIN` and `TREASURER` should be multisig wallets with appropriate signer thresholds.

---

### G-008 — Idempotent `setBuilderAdminRevoked` Emits Duplicate Events

|                |                            |
| -------------- | -------------------------- |
| **Severity**   | Informational              |
| **Category**   | Event Accuracy             |
| **File:Lines** | `src/Guardian.sol:327-337` |
| **Passes**     | State Machine              |

**Description:**
`setBuilderAdminRevoked(admin, true)` called twice emits `BuilderAdminRevoked(admin)` twice. Calling `setBuilderAdminRevoked(admin, false)` on an already-active admin emits `BuilderAdminRestored(admin)` even though no state changed. The function is `onlyGuardianAdmin`, so duplicates require admin action. Off-chain indexers should handle these events idempotently.

**Suggested Fix:**
Add an early return if the current value matches the target:

```solidity
if (builderAdminRevoked[admin] == revoked) return;
```

---

### G-009 — Constructor Allows `guardianAdmin == treasurer`

|                |                            |
| -------------- | -------------------------- |
| **Severity**   | Informational              |
| **Category**   | Role Separation            |
| **File:Lines** | `src/Guardian.sol:227-237` |
| **Passes**     | Diff Review                |

**Description:**
The constructor does not prevent deploying with the same address for `guardianAdmin` and `treasurer`. If both roles share a key, a single compromise grants both lock/unlock authority and token collection authority. This may be intentional for early-stage deployments where a single multisig manages all operations.

---

### G-010 — Broad Revocation Scope Prevents Per-BuilderCode Granularity

|                |                                 |
| -------------- | ------------------------------- |
| **Severity**   | Informational                   |
| **Category**   | Design                          |
| **File:Lines** | `src/Guardian.sol:214-215, 427` |
| **Passes**     | Builder Auth Chain              |

**Description:**
`builderAdminRevoked` is keyed on `address` only, not `(address, builderCode)`. Revoking an admin disables all their builder codes across all RiskEngines simultaneously. This is more secure (single call for full revocation in emergencies) but less flexible (cannot selectively revoke one builder code while preserving others). Accepted design trade-off.

---

## Findings Removed During Validation

Three findings from the initial synthesis were removed after manual review:

1. **`collect()` delegates transfer without post-transfer verification (was Medium)** — Removed. This is the fundamental trust model of the protocol. Guardian is an orchestrator that delegates to RiskEngines validated via `GUARDIAN()` mutual recognition. If a RiskEngine is compromised, no amount of post-transfer checking in Guardian can help — the RiskEngine controls the tokens and could manipulate any verification. This is an inherent architectural property, not a code deficiency.

2. **RiskEngine `lockPool`/`unlockPool` may silently no-op (was Medium)** — Removed. Same reasoning. There is no standard interface to query pool lock state, and a compromised RiskEngine could lie about it regardless. Guardian cannot independently verify RiskEngine behavior — this is the explicit trust boundary of the design.

3. **`_isAuthorizedBuilder` try-catch uses CALL instead of STATICCALL (was Informational)** — Removed as a false positive. Solidity ^0.8.30 compiles `try` on `view` functions to `STATICCALL`. The opcode is determined by the callee's declared mutability in the interface (`getFeeRecipient` and `builderAdmin` are both `view`), regardless of whether `try` is used. The finding's premise was incorrect.

---

## Overall Risk Assessment

The Guardian contract is **well-designed and secure** for its intended purpose. Key strengths:

- **Strong access control:** Immutable `GUARDIAN_ADMIN` and `TREASURER` addresses provide natural reentrancy protection — privileged functions cannot be re-entered through external callbacks since `msg.sender` would not match the immutable addresses.
- **Correct CEI patterns:** `lockPool` and `executeUnlock` clear `unlockEta` before external calls, preventing double-execution. `lockPoolAsBuilder` modifies no state before its external call.
- **Minimal arithmetic surface:** One addition (overflow-impossible), one narrowing cast (range-guarded). No unchecked blocks or assembly.
- **Defensive external call handling:** Raw `staticcall` with proper return data validation for recognition checks and balance queries. Try-catch for builder authorization with fail-closed semantics.
- **No reentrancy guard needed:** The contract's access control model (immutable addresses for privileged functions, no state mutation before external calls in the permissionless path) makes a reentrancy guard unnecessary.

**Residual risks accepted by design:**

1. Guardian trusts RiskEngines to faithfully execute `lockPool`, `unlockPool`, and `collect`. A compromised RiskEngine that preserves the `GUARDIAN()` return value can cause arbitrary damage. This is inherent to the delegated architecture.
2. Immutable roles cannot be rotated — key compromise requires Guardian redeployment and RiskEngine pointer updates.
3. No on-chain pool registry — off-chain systems must independently verify pool legitimacy when processing Guardian events.

**Publication readiness: PASS** — no fund-safety issues. All intentional design decisions are documented in NatSpec. The three Low findings are operational concerns (event pollution, MEV griefing, error UX) that do not affect fund safety.
