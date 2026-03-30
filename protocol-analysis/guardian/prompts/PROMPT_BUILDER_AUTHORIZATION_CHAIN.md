# Builder Authorization Chain Audit — Guardian.sol

````
You are a senior Solidity security researcher performing a deep audit of the builder admin authorization mechanism in Guardian.sol.

Scope restriction (hard):
- Analyze ONLY `src/Guardian.sol`.
- Ignore anything outside `src/`.

## Objective

The builder authorization chain is Guardian's most complex trust path:

  msg.sender → riskEngine.getFeeRecipient(builderCode) → IBuilderWallet(wallet).builderAdmin() == msg.sender

Exhaustively evaluate this chain for:
1. Authorization bypass — can an unauthorized caller pass the checks?
2. Spoofing — can an attacker deploy contracts that satisfy the chain?
3. Revocation bypass — can a revoked admin circumvent the revocation check?
4. Failure mode safety — do all error paths (try-catch, staticcall failures) default to denial?
5. TOCTOU — can authorization state change between check and use?

## Assumptions

- Attacker can deploy arbitrary contracts at arbitrary addresses (CREATE2 / CREATE3).
- Attacker may control a contract that returns `address(this)` for `GUARDIAN()` calls.
- Attacker may control a BuilderWallet that returns an arbitrary address for `builderAdmin()`.
- Attacker knows all builder codes and can predict deterministic wallet addresses.
- RiskEngine's `getFeeRecipient` returns the canonical wallet for a builder code — the attacker cannot change this unless they control the RiskEngine.

## Background Context

### The Authorization Function: _isAuthorizedBuilder (lines 407-435)

```solidity
function _isAuthorizedBuilder(address caller, IRiskEngine riskEngine, uint256 builderCode)
    internal view returns (bool)
{
    // Step 1: Reject zero caller, zero code, revoked callers
    if (caller == address(0) || builderCode == 0 || builderAdminRevoked[caller]) return false;

    // Step 2: Verify RiskEngine recognizes this Guardian
    if (!_isRecognizedRiskEngine(address(riskEngine))) return false;

    // Step 3: Resolve canonical wallet from RiskEngine
    address wallet;
    try riskEngine.getFeeRecipient(builderCode) returns (address resolvedWallet) {
        wallet = resolvedWallet;
    } catch { return false; }

    // Step 4: Validate wallet is a deployed contract
    if (wallet == address(0) || wallet.code.length == 0) return false;

    // Step 5: Check wallet's admin matches caller
    try IBuilderWallet(wallet).builderAdmin() returns (address builderAdmin) {
        return builderAdmin == caller;
    } catch { return false; }
}
````

### The Entry Point: lockPoolAsBuilder (lines 264-272)

```solidity
function lockPoolAsBuilder(IPanopticPoolV2 pool, uint256 builderCode) external {
  _requirePool(pool);
  IRiskEngine riskEngine = _getRiskEngine(pool); // validates pool → riskEngine → GUARDIAN() chain
  if (!_isAuthorizedBuilder(msg.sender, riskEngine, builderCode)) revert NotAuthorizedBuilder();
  riskEngine.lockPool(pool);
  emit PoolLocked(pool, msg.sender);
}
```

## Deliverables (strict order)

### A) Authorization Chain Trace

For each step in the chain, document:

1. What is checked
2. What external call is made
3. What the attacker controls
4. How a failure is handled

### A1. Pool → RiskEngine Resolution

- `_getRiskEngine(pool)` calls `pool.riskEngine()` to get the RiskEngine address.
- The RiskEngine is then validated via `_requireRecognizedRiskEngine`.
- **Attack vector**: Can an attacker deploy a malicious pool contract whose `riskEngine()` returns an attacker-controlled address that passes the GUARDIAN() check?
  - The attacker deploys contract A (fake pool) where `riskEngine()` returns contract B.
  - Contract B implements `GUARDIAN()` returning the real Guardian's address.
  - Contract B implements `getFeeRecipient(builderCode)` returning contract C (attacker wallet).
  - Contract C implements `builderAdmin()` returning the attacker's address.
  - Result: attacker calls `lockPoolAsBuilder(fakePool, anyCode)` — this would lock `fakePool` on contract B.
  - **Question**: Does `riskEngine.lockPool(fakePool)` on a fake RiskEngine matter? It only calls the fake RiskEngine's lockPool, which the attacker controls. No real pool is affected.
  - **BUT**: What if the attacker's fake RiskEngine's lockPool calls back into the real Guardian? Trace this path.

### A2. RiskEngine → Wallet Resolution

- `riskEngine.getFeeRecipient(builderCode)` returns a wallet address.
- Wrapped in try-catch — revert → false (denial). Safe.
- **Attack vector**: If the RiskEngine is legitimate but the wallet for a given builderCode hasn't been deployed yet, can the attacker front-run the deployment and deploy their own contract at that address?
  - This depends on whether the BuilderFactory uses CREATE2 with the builderCode as salt. If so, the address is deterministic and the attacker cannot deploy at the same address (the factory's initcode hash differs).
  - If the factory uses CREATE (nonce-based), the attacker also cannot deploy at the factory's predicted address.
  - **Conclusion**: Address squatting is not feasible if the factory is the sole deployer. But verify: can the attacker call `BuilderFactory.deployBuilder` directly? (Guardian calls it with `onlyGuardianAdmin`, but the factory itself may not have access control.)

### A3. Wallet → Admin Verification

- `IBuilderWallet(wallet).builderAdmin()` returns the admin address.
- Compared against `caller` (msg.sender).
- **Attack vector**: If the wallet is a legitimate contract, can the attacker become its admin?
  - This depends on the wallet contract's admin transfer logic — out of scope for Guardian audit.
  - Guardian's only defense is the revocation mechanism (`builderAdminRevoked`).

### B) Spoofing Analysis

#### B1. Fake Pool + Fake RiskEngine Chain

- Attacker deploys: FakePool (riskEngine() → FakeRE), FakeRE (GUARDIAN() → real Guardian address, getFeeRecipient() → FakeWallet, lockPool() → no-op), FakeWallet (builderAdmin() → attacker).
- Attacker calls: `lockPoolAsBuilder(FakePool, 1)`.
- Result: All checks pass. `FakeRE.lockPool(FakePool)` is called. No real pool is affected.
- **Impact**: None — the attacker only interacts with their own contracts. The real pools, real RiskEngines, and real wallets are not touched.
- **BUT**: Does the `PoolLocked` event emission (line 271) cause off-chain monitoring to react to a fake lock? If monitoring triggers on PoolLocked events without verifying the pool is legitimate, this could cause false alerts.

#### B2. Real Pool + Legitimate Builder Code

- Can an attacker use a legitimate builder code to lock a real pool they shouldn't be able to lock?
- The builder admin check requires `builderWallet.builderAdmin() == msg.sender`. Unless the attacker IS the builder admin, this fails.
- If the attacker compromises the builder wallet's admin key, they can lock pools — this is by design (builder admins have lock authority).

#### B3. Builder Code Enumeration

- Can an attacker enumerate all valid builder codes to find one whose wallet has been compromised?
- `getFeeRecipient(builderCode)` is a view function — enumerable. But knowing the wallet address doesn't grant lock authority; the attacker must also be the wallet's admin.

### C) Revocation Analysis

#### C1. Revocation Check Ordering

- `builderAdminRevoked[caller]` is checked at line 412, BEFORE any external calls.
- No TOCTOU: the storage read is atomic with the function execution. By the time `riskEngine.lockPool()` is called, the revocation check has already passed.
- **BUT**: Can the guardian admin revoke an admin in a separate transaction that lands AFTER the builder's `lockPoolAsBuilder` transaction? Yes — this is the front-running race documented in the state machine prompt.

#### C2. Revocation Scope

- Revocation is keyed on `msg.sender` address, NOT on (admin, builderCode) or (admin, riskEngine).
- A revoked admin is blocked for ALL builder codes on ALL RiskEngines.
- **Question**: Is this too broad? Could a legitimate builder admin be wrongfully blocked from one RiskEngine because they were revoked for misbehavior on another?

#### C3. Revocation Permanence

- Revocation can be reversed by `setBuilderAdminRevoked(admin, false)`.
- There is no cooldown or governance delay on restoration.
- **Risk**: A compromised guardian admin key could revoke all builders, or restore a malicious builder.

### D) try-catch Failure Modes

#### D1. getFeeRecipient Failure

- If `riskEngine.getFeeRecipient(builderCode)` reverts: catch → return false. **Safe.**
- If it returns invalid ABI data: Solidity's `try` with `returns (address)` will revert on decode failure → catch. **Safe.**
- If it consumes all gas: the try-catch may fail due to out-of-gas, which would propagate as a revert of the entire transaction. **Not caught by try-catch.** Impact: DoS on lockPoolAsBuilder for that builder code.

#### D2. builderAdmin Failure

- Same analysis as D1. Revert → false. Invalid data → catch. Gas bomb → tx revert.

#### D3. Gas Bomb Mitigation

- Guardian does not set gas limits on external calls.
- A malicious RiskEngine or wallet could consume all available gas in getFeeRecipient or builderAdmin.
- This is a DoS vector: the attacker deploys a wallet/RiskEngine that gas-bombs when queried.
- Impact: Legitimate builders cannot use `lockPoolAsBuilder` for pools governed by that RiskEngine.
- Severity: Low — the guardian admin can still use `lockPool` directly.

### E) Cross-Function Authorization Consistency

- `lockPoolAsBuilder` uses `_isAuthorizedBuilder` for authorization.
- `isBuilderAdmin` (view function, line 379) also uses `_isAuthorizedBuilder`.
- Verify these two paths use IDENTICAL logic. Differences could allow an attacker to appear authorized in one but not the other.
- **Difference**: `isBuilderAdmin` calls `pool.riskEngine()` directly WITHOUT `_requireRecognizedRiskEngine`. It relies on `_isAuthorizedBuilder` to check recognition. Meanwhile, `lockPoolAsBuilder` calls `_getRiskEngine(pool)` which DOES validate recognition BEFORE calling `_isAuthorizedBuilder` (which checks it again). Double-validation in one path, single-validation in the other — but both paths DO validate. Functionally equivalent.

### F) Findings

For each finding:

- ID (AUTH-NNN)
- Severity (Critical / High / Medium / Low / Informational)
- Category: bypass / spoofing / revocation / failure-mode / toctou
- The exact step in the authorization chain that is vulnerable
- Preconditions (what the attacker must control)
- Impact (what the attacker achieves)
- Minimal exploit sequence

### G) Recommendations

For each finding:

1. Minimal code change
2. Whether the fix affects legitimate builder operations
3. Alternative mitigations if the primary fix is too restrictive

## Review Rules

- Trace the COMPLETE authorization chain for every attack scenario — partial analysis is insufficient.
- "The attacker would need to control the RiskEngine" is NOT a sufficient dismissal — quantify how difficult this is and what damage it enables.
- The try-catch pattern silently denies — verify that no legitimate operation is silently denied due to a misconfigured or temporarily unavailable external contract.
- Revocation is the ONLY mechanism to remove builder authority after the wallet is deployed. Analyze its completeness.
- Pay attention to the difference between "no real impact" (attacker interacts with their own fake contracts) and "event/log pollution" (off-chain systems react to fake events).

```

```
