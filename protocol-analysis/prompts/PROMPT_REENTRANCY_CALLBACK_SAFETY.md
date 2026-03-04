# Reentrancy & Callback Safety Audit Prompt

You are a senior Solidity security researcher performing an exhaustive reentrancy and callback safety audit.

Scope restriction (hard):

- Analyze ONLY files under `contracts/` (recursive).
- Ignore anything outside `contracts/`.
- If you reference a file outside `contracts/`, mark it "out of scope" and do not rely on it for conclusions.

## Objective

Exhaustively evaluate all reentrancy and callback attack surfaces, focusing on:

1. Cross-contract reentrancy between PanopticPool, CollateralTracker, SFPM, and Uniswap
2. Callback safety in Uniswap mint/swap callbacks
3. Read-only reentrancy (stale state visible to external view calls during execution)
4. Transient storage reentrancy guard completeness and correctness
5. State consistency at every external call boundary
6. Token transfer callbacks (ERC777, hooks, receive/fallback)

## Assumptions

- Attacker can deploy arbitrary contracts as callback recipients.
- Attacker can deploy ERC777-like tokens with transfer hooks (relevant if such tokens are used as Uniswap pool assets).
- Attacker can call any `external`/`public` function at any point during execution via a callback.
- "Protected by reentrancy guard" is only valid if the SAME guard instance covers the re-entry path. Different contract instances have SEPARATE transient storage slots.
- All external calls are potential reentrancy points unless proven otherwise.

## Background Context

### Reentrancy Guard

The protocol uses EIP-1153 transient storage reentrancy guards (`TransientReentrancyGuard.sol`):

- Single slot: `keccak256("panoptic.reentrancy.slot")` — same constant across all contracts
- `_nonReentrantSet()` (line 39): `tload` check + `tstore(slot, address())` — stores the contract's own address
- `_nonReentrantReset()` (line 59): `tstore(slot, 0)`
- `ensureNonReentrantView()` (line 25): reverts if guard is entered (read-only protection)

**Critical architectural detail**: Each contract instance has its OWN transient storage scope. `PanopticPool`, `CollateralTracker0`, `CollateralTracker1`, and `SFPM` are separate contract deployments. Their `nonReentrant` guards are INDEPENDENT — entering PanopticPool's guard does NOT prevent re-entering CollateralTracker.

### Contract Call Graph

```
User → PanopticPool.dispatch() [nonReentrant]
  → SFPM.mintTokenizedPosition() [nonReentrant on SFPM]
    → UniswapPool.mint() [EXTERNAL]
      → SFPM.uniswapV3MintCallback() [no guard — intentionally callable during SFPM nonReentrant]
        → SafeTransferLib.safeTransferFrom() [EXTERNAL - token transfer]
    → UniswapPool.burn() [EXTERNAL]
    → UniswapPool.collect() [EXTERNAL]
    → UniswapPool.swap() [EXTERNAL]
      → SFPM.uniswapV3SwapCallback() [no guard]
        → SafeTransferLib.safeTransferFrom() [EXTERNAL - token transfer]
  → CollateralTracker.settleMint() [nonReentrant on CT]
  → CollateralTracker.delegate() [nonReentrant on CT]
  → CollateralTracker.revoke() [nonReentrant on CT]

User → PanopticPool.dispatchFrom() [nonReentrant]
  → SFPM.burnTokenizedPosition() [nonReentrant on SFPM]
    → (same Uniswap interaction pattern as above)
  → CollateralTracker.settleOptions() [nonReentrant on CT]
  → CollateralTracker.settleLiquidation() [nonReentrant on CT]
  → CollateralTracker.takeCommissionBurnLP() [nonReentrant on CT]
```

### Functions with nonReentrant

**PanopticPool.sol:**

- `pokeOracle()` (PP:605)
- `dispatch(...)` (PP:634)
- `dispatchFrom(...)` (PP:1497)

**CollateralTracker.sol:**

- `transfer`, `transferFrom` (CT:402, 422)
- `deposit`, `mint`, `withdraw`, `redeem` (CT:560, 615, 712, 768, 844)
- `accrueInterest()` (CT:887)
- `delegate`, `revoke` (CT:1227, 1236)
- `settleMint`, `settleOptions`, `takeCommissionBurnLP`, `settleLiquidation` (CT:1250, 1379, 1546, 1625)

**SFPM:**

- `mintTokenizedPosition(...)` (SFPM:645)
- `burnTokenizedPosition(...)` (SFPM:605)

### Uniswap Callbacks

**uniswapV3MintCallback** (SFPM:528):

- Validates `msg.sender` via `CallbackLib.validateCallback` (checks against factory)
- Transfers owed tokens via `SafeTransferLib.safeTransferFrom`

**uniswapV3SwapCallback** (SFPM:561):

- Same validation pattern
- Transfers owed tokens

Both callbacks are called BY Uniswap DURING `mint()`/`swap()` calls, while SFPM's `nonReentrant` guard is already held.

### Token Transfers

All token transfers use `SafeTransferLib` (Solady-style):

- `safeTransferFrom(token, from, to, amount)` — raw `call` with returndata check
- `safeTransfer(token, to, amount)` — raw `call`
- No ERC777 `tokensReceived` hook support — but if the token IS an ERC777, the hook fires regardless

CollateralTracker's own `transfer`/`transferFrom` (ERC20Minimal) are `nonReentrant`.

## Deliverables (strict order)

### A) External Call Inventory

For EVERY external call made during protocol execution, document:

| #   | Caller | Callee | Function | Guard Held | State Modified Before Call | State Modified After Call | Reentrancy Risk |
| --- | ------ | ------ | -------- | ---------- | -------------------------- | ------------------------- | --------------- |

Focus on:

1. All calls from SFPM to Uniswap (`pool.mint`, `pool.burn`, `pool.collect`, `pool.swap`)
2. All calls from PanopticPool to SFPM (`mintTokenizedPosition`, `burnTokenizedPosition`)
3. All calls from PanopticPool to CollateralTracker (`settleMint`, `settleOptions`, etc.)
4. All token transfers (`SafeTransferLib.safeTransferFrom`, `safeTransfer`, `safeTransferETH`)
5. All calls from CollateralTracker to external contracts (token transfers during deposit/withdraw)
6. The `uniswapV3MintCallback` and `uniswapV3SwapCallback` entry points

For each call:

- What state has been modified BEFORE the call that could be exploited if re-entered?
- What state will be modified AFTER the call that an attacker could front-run via reentrancy?
- Is there a checks-effects-interactions violation?

### B) Cross-Contract Reentrancy Analysis

Since each contract has an independent reentrancy guard, analyze these cross-contract paths:

#### B.1 PP → SFPM → Uniswap → callback → ??? → CT

- PanopticPool holds its `nonReentrant` guard.
- It calls SFPM, which holds its own guard.
- SFPM calls Uniswap, which calls back into SFPM (callback).
- The callback transfers tokens. If the token has a transfer hook (ERC777):
  - Can the hook call back into PanopticPool? (PP guard is held → blocks re-entry.)
  - Can the hook call CollateralTracker directly? (CT guard is NOT held during SFPM execution.)
  - If yes: what state is inconsistent? PanopticPool has updated some state but not yet called CT for settlement.

#### B.2 PP → CT (settlement) → token transfer → hook → PP

- PanopticPool calls CT.settleMint(). CT holds its guard.
- CT transfers tokens to/from the user during settlement.
- If the token has a transfer hook: can the hook call PP? (PP guard IS held → blocked.)
- If the hook calls CT? (CT guard IS held → blocked.)
- If the hook calls SFPM directly? (SFPM guard is NOT held after PP's SFPM calls complete.)

#### B.3 CT standalone operations → token transfer → hook → PP/SFPM

- User calls CT.deposit(). CT holds its guard.
- CT calls `SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount)`.
- If this triggers a token hook on `msg.sender` (ERC777 `tokensToSend`):
  - Can the hook call PP.dispatch()? (PP guard is NOT held → could enter!)
  - What state is CT in? It has received the tokens but not yet minted shares.
  - Is this exploitable?

#### B.4 Concurrent CT0 and CT1 operations

- Each CollateralTracker is a separate contract with its own guard.
- Can an attacker exploit the gap between CT0 and CT1 settlement?
- During dispatch, PP calls CT0.settleMint() then CT1.settleMint() (or similar). Between these calls:
  - CT0 settlement is complete, CT0 guard is released.
  - CT1 settlement hasn't started.
  - Can the attacker re-enter CT0 during this window?

### C) Read-Only Reentrancy

#### C.1 View Functions During Execution

- `ensureNonReentrantView()` (line 25) protects view functions from returning stale data during reentrancy.
- Which view functions use this modifier? Which DON'T?
- List all `view`/`pure` functions on PanopticPool, CollateralTracker, and SFPM that read state.
- For each unprotected view function: can it return inconsistent data during a reentrancy callback?

#### C.2 External Integrations

- If an external protocol (e.g., a lending protocol) reads `totalAssets()` or `convertToAssets()` during a PanopticPool operation:
  - Is the data consistent?
  - Can an attacker exploit stale intermediate state visible to external readers?
  - Does `ensureNonReentrantView` protect these functions?

### D) Callback Validation

#### D.1 uniswapV3MintCallback / uniswapV3SwapCallback

- `CallbackLib.validateCallback(msg.sender, FACTORY, decoded.poolFeatures)` — verify this correctly rejects spoofed callbacks.
- Can an attacker deploy a contract at a deterministic CREATE2 address that passes the factory validation?
- Can `decoded.poolFeatures` be manipulated (it comes from the callback `data` parameter)?
- What if the Uniswap pool itself is malicious (attacker-deployed pool with fee/token manipulation)?

#### D.2 Callback Data Integrity

- The `CallbackLib.CallbackData` is encoded by the SFPM and decoded in the callback.
- Can the data be tampered with between encoding and decoding? (Uniswap passes it through unchanged.)
- Does the callback verify that `decoded.payer` is authorized? Or does it blindly transfer from `decoded.payer`?

### E) State Consistency at External Call Boundaries

For each external call identified in Section A, verify the checks-effects-interactions pattern:

1. **Before the call**: Is all critical state already updated? Or is the contract in an intermediate state?
2. **During the call**: What can an attacker observe or do via reentrancy?
3. **After the call**: Does the contract verify that external state (e.g., Uniswap liquidity amounts) matches expectations?

Specific scenarios:

- SFPM calls `pool.mint()`, gets called back in `uniswapV3MintCallback`, transfers tokens, then reads `pool.collect()` amounts. Can the callback manipulate the amounts?
- SFPM calls `pool.burn()` which returns `(amount0, amount1)`. Can these be manipulated between the burn and the subsequent `pool.collect()`?
- PanopticPool updates `s_grossPremiumLast` between SFPM and CT calls. Is this state consistent if re-entered?

### F) Transient Storage Edge Cases

#### F.1 Same-Transaction Multi-Pool Interactions

- If a user interacts with multiple Panoptic pools in the same transaction:
  - Each pool has its own `nonReentrant` guard (separate contract, separate transient storage).
  - Can cross-pool reentrancy be exploited?

#### F.2 Guard Reset Ordering

- `_nonReentrantReset()` uses `tstore(slot, 0)`.
- If a function reverts AFTER the guard is set but BEFORE it's reset, the guard remains set for the rest of the transaction (transient storage persists until tx end).
- Does this cause any DoS? (Subsequent calls in the same tx would fail.)
- Is this exploitable? (Can an attacker intentionally cause a revert to lock the guard?)

#### F.3 Delegatecall Interactions

- If any contract uses `delegatecall`, the transient storage slot would be shared with the caller.
- Are there any `delegatecall` patterns in the codebase? (Multicall, proxies, etc.)

### G) Token-Specific Reentrancy Risks

For each token type that could be used in a Uniswap pool paired with the protocol:

1. **Standard ERC20**: No hooks. `SafeTransferLib` handles return value. Safe.
2. **ERC777**: `tokensToSend` hook on sender, `tokensReceived` hook on receiver. Both fire during `transferFrom`. Can re-enter during any token transfer.
3. **ERC20 with transfer hooks** (e.g., some fee-on-transfer tokens): May call external contracts during transfer.
4. **Rebasing tokens**: Balance changes between operations. Not a reentrancy issue but compounds reentrancy risks.
5. **Tokens with blacklists** (USDC): `transfer` reverts for blacklisted addresses. Can this cause unexpected reverts inside callbacks?
6. **Native ETH wrapping**: CT accepts native ETH (payable deposit/mint). Does the ETH refund path (`safeTransferETH`) create reentrancy via `receive()`?

For each token type, trace the reentrancy path and determine if the guards protect it.

### H) Findings

For each finding:

- ID (REENT-NNN)
- Severity (Critical / High / Medium / Low / Informational)
- Category: cross-contract / callback / read-only / token-hook / guard-bypass
- Complete attack sequence including: which callback triggers the re-entry, which function is re-entered, what state is inconsistent, and what value is extracted
- Proof that the reentrancy guard does NOT protect the path (cite the specific guard instances involved)
- Whether the attack works with standard ERC20 tokens or requires ERC777/hooks

### I) Recommendations

For each finding:

1. Minimal code change (add guard, reorder operations, add validation)
2. Assessment of whether the fix introduces new issues (e.g., does adding a guard cause legitimate operations to fail?)
3. Token whitelist/blacklist recommendations if token-specific

## Review Rules

- Every reentrancy claim must trace the COMPLETE call path: entry → external call → callback → re-entry → state access.
- Every "protected by nonReentrant" claim must verify that the SAME contract instance's guard covers both the entry and re-entry.
- Do not assume `SafeTransferLib` prevents callbacks — it uses raw `call` which WILL trigger ERC777 hooks if the token implements them.
- Do not assume Uniswap pools use only standard ERC20 tokens — anyone can create a pool with any ERC20-compatible token.
- Distinguish between direct reentrancy (re-entering the same function) and cross-function reentrancy (entering a different function on the same or different contract).
- If an attack requires an ERC777 token, state this explicitly and assess whether the protocol is expected to support such tokens.
- The `nonReentrant` modifier reverts on re-entry — verify that this revert is handled gracefully (doesn't leave state corrupted).
- Check that all external calls are the LAST operations in their scope (checks-effects-interactions pattern).
