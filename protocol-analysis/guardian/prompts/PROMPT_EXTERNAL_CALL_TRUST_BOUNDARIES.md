# External Call Trust Boundaries Audit — Guardian.sol

```
You are a senior Solidity security researcher performing a trust boundary analysis of all external contract interactions in Guardian.sol.

Scope restriction (hard):
- Analyze ONLY `src/Guardian.sol`.
- Ignore anything outside `src/`.

## Objective

Guardian's security fundamentally depends on trusting external contracts: RiskEngine, PanopticPool, BuilderWallet, BuilderFactory, and ERC20 tokens. For each external contract, exhaustively evaluate:
1. How Guardian validates it before interaction
2. What damage a malicious or compromised implementation could cause
3. Whether Guardian's validation is sufficient to prevent exploitation
4. What happens if the external contract is upgraded, self-destructed, or otherwise changes behavior

## Assumptions

- Attacker can deploy contracts implementing any interface.
- Attacker can predict CREATE2 addresses.
- Legitimate external contracts can be upgraded (proxy pattern) or self-destructed.
- Legitimate external contracts may have bugs that cause unexpected return values.
- Network conditions may cause external calls to fail (out of gas, revert).

## Deliverables (strict order)

### A) Trust Boundary Map

For each external contract type, document the complete trust relationship:

### A1. RiskEngine Trust Boundary

**How Guardian validates RiskEngine:**
- `_isRecognizedRiskEngine(address riskEngine)` (line 488): checks `riskEngine.code.length > 0` AND `riskEngine.GUARDIAN() == address(this)` via staticcall.
- Called via `_getRiskEngine(pool)` (lockPool, lockPoolAsBuilder, requestUnlock, executeUnlock) and `_requireRecognizedRiskEngine` (collect).

**What a malicious RiskEngine could do:**
1. **lockPool/unlockPool no-op**: A RiskEngine that passes GUARDIAN() check but ignores lockPool/unlockPool calls. Impact: Guardian believes pool is locked/unlocked but it isn't. Off-chain monitoring would see the PoolLocked/PoolUnlocked events but the pool state wouldn't match.
2. **collect token theft**: `riskEngine.collect(token, recipient, amount)` — a malicious RiskEngine could ignore the recipient and send tokens elsewhere. Or it could claim to collect but not actually transfer. Impact: token loss if the RiskEngine is compromised after initial validation.
3. **getFeeRecipient manipulation**: Return an attacker-controlled wallet address. Impact: allows unauthorized builder admin authorization (mitigated by wallet.builderAdmin() check).
4. **GUARDIAN() return manipulation**: A proxy RiskEngine could be upgraded to return a different guardian address, breaking the recognition link. Impact: Guardian can no longer interact with that RiskEngine's pools.
5. **Reentrant lockPool/unlockPool**: The RiskEngine's lockPool could call back into Guardian. (See reentrancy prompt for analysis.)

**Sufficiency of validation:**
- The GUARDIAN() mutual recognition is the primary trust anchor. It proves the RiskEngine was configured to trust THIS Guardian. However, it does NOT prove the RiskEngine is honest — a contract can implement GUARDIAN() → address(this) while having malicious lockPool/collect logic.
- The check is performed on every interaction, so a RiskEngine that is upgraded to break the link is immediately rejected.

### A2. PanopticPool Trust Boundary

**How Guardian validates pools:**
- `_requirePool(pool)` (line 463): checks `address(pool) != address(0)` AND `address(pool).code.length > 0`.
- `pool.riskEngine()` is called to retrieve the RiskEngine, which is then independently validated.

**What a malicious pool could do:**
1. **Return a fake RiskEngine**: `pool.riskEngine()` returns an attacker-controlled address. This is mitigated by the subsequent GUARDIAN() check on the returned RiskEngine.
2. **Return different RiskEngines on different calls**: A pool could return RiskEngine A on the first call and RiskEngine B on the second. Within a single Guardian function, `pool.riskEngine()` is called once and the result is reused, so this is not exploitable within a single tx. Across transactions, the pool's RiskEngine might change — but each interaction independently validates.
3. **Revert on riskEngine() call**: Causes the Guardian function to revert. DoS only.

**Sufficiency of validation:**
- Guardian does NOT verify that a pool is deployed by a canonical factory or registered in any registry. Any contract with a `riskEngine()` function returning a recognized RiskEngine is treated as valid.
- Impact: A fake pool can trigger PoolLocked/PoolUnlocked events but cannot affect real pools. Off-chain systems should verify pool legitimacy independently.

### A3. BuilderWallet Trust Boundary

**How Guardian validates wallets:**
- In `_isAuthorizedBuilder` (line 426): checks `wallet != address(0)` AND `wallet.code.length > 0`.
- Wallet address comes from `riskEngine.getFeeRecipient(builderCode)` — trusted only if the RiskEngine is recognized.

**What a malicious wallet could do:**
1. **Return wrong admin**: `builderAdmin()` returns an address that isn't the real admin. Impact: wrong person gets builder lock authority. But this requires the RiskEngine's getFeeRecipient to point to the malicious wallet, which requires compromising the RiskEngine.
2. **Gas bomb on builderAdmin()**: Consume all gas. Impact: DoS on lockPoolAsBuilder for that builder code.
3. **Self-destruct after deployment**: If the wallet self-destructs, `wallet.code.length == 0` check at line 426 rejects it. The builder admin loses lock authority until a new wallet is deployed.

**Sufficiency of validation:**
- Guardian trusts the wallet's `builderAdmin()` return value completely. If the wallet is compromised (admin transfer), the builder admin changes. Guardian's only recourse is revocation via `setBuilderAdminRevoked`.
- This is by design — the wallet is the authority for who its admin is.

### A4. BuilderFactory Trust Boundary

**How Guardian validates the factory:**
- Set in constructor as immutable. Validated for non-zero and code existence at deployment time.
- NO ongoing validation — the factory address never changes.

**What a malicious factory could do:**
1. **Deploy malicious wallets**: Return a wallet address where `builderAdmin()` returns the attacker. Impact: attacker becomes builder admin for that code.
2. **Return zero address or EOA**: Mitigated by `_requireContract(wallet)` at line 344 after deployment.
3. **Not actually deploy (CREATE2 front-running)**: Return a pre-existing contract at the deterministic address. Guardian checks `wallet.code.length > 0`, which passes. Impact depends on what contract is at that address.

**Sufficiency of validation:**
- The factory is immutable — it cannot be changed after Guardian deployment. If the factory is compromised or has a bug, a new Guardian must be deployed.
- Guardian validates the deployment result (`_requireContract(wallet)`) but does NOT verify the wallet implements IBuilderWallet. A factory could return any contract address.

### A5. ERC20 Token Trust Boundary

**How Guardian validates tokens:**
- In `collect()` (line 361): checks `token != address(0)`.
- In `_balanceOfOrZero` (line 441): uses staticcall for balanceOf, returns 0 on failure.

**What a malicious token could do:**
1. **Lie about balanceOf**: Return an inflated or zero balance. Impact: `collectedAmount` in the TokensCollected event is wrong. Off-chain accounting is incorrect. No on-chain fund impact (the actual transfer is handled by the RiskEngine).
2. **Revert on balanceOf**: `_balanceOfOrZero` returns 0. The event emits amount=0 for a full-balance collect even if tokens were transferred. Inaccurate event.
3. **Return malformed data**: `data.length < 32` check at line 445 catches this. Returns 0. Same impact as revert.

**Sufficiency of validation:**
- Token validation is minimal by design — Guardian doesn't transfer tokens directly. The RiskEngine handles transfers.
- The only risk is event inaccuracy, which affects off-chain monitoring but not on-chain state.

### B) Validation Gap Analysis

For each Guardian function, map which validations are performed:

| Function | Pool validated? | RiskEngine recognized? | Builder authorized? | Token validated? | Notes |
|----------|----------------|----------------------|--------------------|-----------------| ------|
| lockPool | Yes (_requirePool) | Yes (_getRiskEngine) | N/A (guardianAdmin only) | N/A | |
| lockPoolAsBuilder | Yes (_requirePool) | Yes (_getRiskEngine + _isAuthorizedBuilder) | Yes | N/A | Double RiskEngine validation |
| requestUnlock | Yes (via _getRiskEngine) | Yes (_getRiskEngine) | N/A | N/A | |
| executeUnlock | Yes (via _getRiskEngine) | Yes (_getRiskEngine) | N/A | N/A | |
| cancelUnlock | Yes (_requirePool) | **NO** | N/A | N/A | Only validates pool, not RiskEngine |
| setBuilderAdminRevoked | N/A | N/A | N/A | N/A | Only validates admin != address(0) |
| deployBuilder | N/A | N/A | N/A | N/A | Validates builderCode range + admin |
| collect | N/A | Yes (_requireRecognizedRiskEngine) | N/A | Yes (non-zero) | RiskEngine passed directly, not via pool |

**Gap**: `cancelUnlock` validates the pool but does NOT validate its RiskEngine. This is intentional (cancelUnlock only modifies Guardian storage), but should be documented. A pending unlock for a pool whose RiskEngine has since been changed/decommissioned can still be cancelled.

### C) Upgrade & Destruction Scenarios

#### C1. RiskEngine Upgraded (Proxy)
- If a RiskEngine is a proxy and its implementation is upgraded:
  - `GUARDIAN()` might return a different address → Guardian loses access.
  - `lockPool/unlockPool` might behave differently → unexpected pool state.
  - `collect` might steal tokens.
- Guardian re-validates on every call, so a bad upgrade is detected immediately (GUARDIAN() check fails).

#### C2. RiskEngine Self-Destructed
- `riskEngine.code.length == 0` → recognition check fails → Guardian cannot interact.
- Any pending unlocks for pools governed by that RiskEngine become unexecutable (executeUnlock calls _getRiskEngine which would fail).
- **Risk**: Locked pools cannot be unlocked through Guardian if their RiskEngine is destroyed.

#### C3. BuilderWallet Self-Destructed
- `wallet.code.length == 0` at line 426 → authorization fails → builder admin loses lock authority.
- No impact on existing locks or pending unlocks.

#### C4. BuilderFactory Self-Destructed
- `deployBuilder` would succeed (BUILDER_FACTORY has code check only at construction time) but the delegatecall/call to the factory would revert.
- Impact: no new builder wallets can be deployed. Existing wallets unaffected.

### D) Cross-Boundary Attack Scenarios

#### D1. Compromised RiskEngine Token Drain
1. Legitimate RiskEngine is upgraded (proxy) to steal tokens.
2. Treasurer calls `collect(riskEngine, token, recipient, amount)`.
3. Guardian validates GUARDIAN() — if the upgrade preserved this, validation passes.
4. `riskEngine.collect(token, recipient, amount)` — the malicious implementation sends tokens to attacker instead.
5. Guardian emits `TokensCollected` with the expected recipient and amount.
6. Impact: tokens stolen, events are misleading.
7. Mitigation: RiskEngine upgrade governance is outside Guardian's control. Guardian trusts RiskEngine after GUARDIAN() check.

#### D2. Fake Pool Event Pollution
1. Attacker deploys FakePool (riskEngine() → FakeRE) and FakeRE (GUARDIAN() → real Guardian, lockPool → no-op).
2. Attacker calls `lockPoolAsBuilder(FakePool, builderCode)` with valid builder credentials.
3. All checks pass. FakeRE.lockPool(FakePool) does nothing.
4. Guardian emits `PoolLocked(FakePool, attacker)`.
5. Impact: off-chain monitoring receives fake lock events for non-existent pools.
6. Mitigation: off-chain systems should verify pool addresses against a canonical registry.

#### D3. RiskEngine Passed Directly to collect()
- `collect()` receives `riskEngine` as a parameter, NOT derived from a pool.
- An attacker (if they were treasurer) could pass any address that implements GUARDIAN() → address(this).
- The `_requireRecognizedRiskEngine` check validates the address, but any contract returning the right GUARDIAN() value passes.
- **Risk**: If TREASURER key is compromised, attacker can drain tokens from any contract that: (a) implements GUARDIAN() → this Guardian, and (b) implements collect().
- Severity: High (requires TREASURER key compromise, which is an immutable EOA).

### E) Findings

For each finding:
- ID (TRUST-NNN)
- Severity (Critical / High / Medium / Low / Informational)
- Category: validation-gap / upgrade-risk / event-pollution / trust-assumption
- Which trust boundary is violated
- What the attacker must control
- Impact
- Minimal exploit sequence

### F) Recommendations

For each finding:
1. Whether additional validation would mitigate the risk
2. Whether the risk is inherent to the design (accepted trust assumption)
3. Off-chain mitigations (monitoring, alerting, registry verification)

## Review Rules

- For each "Guardian trusts X" statement, evaluate: what if X lies? What if X changes behavior?
- Do not assume external contracts are immutable unless proven (no proxy, no selfdestruct, no delegatecall).
- Event accuracy matters — off-chain systems use events for monitoring and accounting.
- "The attacker would need to compromise the RiskEngine" is a valid statement of risk, not a dismissal. Quantify the damage.
- Distinguish between trust assumptions that are part of the design vs. validation gaps that could be closed.
```
