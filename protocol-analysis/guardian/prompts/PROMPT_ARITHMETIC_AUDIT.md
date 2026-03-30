# Arithmetic Safety Audit — Guardian.sol

````
You are a senior Solidity security researcher performing an adversarial arithmetic audit.

Scope restriction (hard):
- Analyze ONLY `src/Guardian.sol`.
- Ignore anything outside `src/`.

Objective:
Evaluate all integer arithmetic, casting, and boundary risks that can lead to:
1. Incorrect state (wrong unlock timestamp, wrong builder code)
2. Bypass of validation checks
3. DoS via arithmetic panic/revert

Assumptions:
- Full MEV adversary.
- Arithmetic edge cases are exploitable unless proven otherwise.
- Solidity ^0.8 checked math applies unless `unchecked` or assembly is involved.

Deliverables (strict order):

A) Arithmetic Hotspot Inventory

Guardian has minimal arithmetic. Enumerate every hotspot:

### Hotspot 1: Unlock ETA Computation (line 280)
```solidity
uint256 eta = block.timestamp + UNLOCK_DELAY;
````

- UNLOCK_DELAY = 1 hours = 3600
- Operands: block.timestamp (uint256, current block time), 3600 (constant)
- Overflow analysis: block.timestamp is ~1.7 billion (10 digits) as of 2025. uint256 max is ~1.15 \* 10^77. Overflow is impossible in any realistic timeframe.
- Status: **Safe by invariant** (block.timestamp is bounded by physical time).

### Hotspot 2: Builder Code Range Check (line 336)

```solidity
if (builderCode == 0 || builderCode > type(uint48).max) revert InvalidBuilderCode();
```

- `type(uint48).max` = 281474976710655 (2^48 - 1)
- This check ensures builderCode is in range [1, 2^48 - 1].
- The subsequent cast at line 341: `uint48(builderCode)` is safe because the range check guarantees no truncation.
- Status: **Safe by guard** (line 336 enforces range before cast at line 341).

### Hotspot 3: Builder Code Cast (line 341)

```solidity
uint48 builderCode48 = uint48(builderCode);
```

- Narrowing cast from uint256 to uint48.
- Safe because of the range check at line 336.
- Verify: `uint48(x)` truncates to lower 48 bits. If x <= type(uint48).max, truncation is lossless.
- Status: **Safe by guard** (line 336).

### Hotspot 4: Timestamp Comparison (line 294)

```solidity
if (block.timestamp < eta) revert UnlockNotReady(eta);
```

- Both operands are uint256. No arithmetic performed, just comparison.
- Status: **Safe** (no arithmetic operation).

### Hotspot 5: Balance Subtraction in collect (implicit)

```solidity
collectedAmount = _balanceOfOrZero(token, address(riskEngine));
```

- No subtraction or arithmetic here — the balance is read and used directly as the event amount.
- The pre-collect balance is emitted as `collectedAmount`. If the RiskEngine's actual transfer amount differs from its balanceOf, the event is inaccurate but no arithmetic error occurs.
- Status: **Safe** (no arithmetic, but potential event inaccuracy — see reentrancy/callback prompt).

B) Per-Hotspot Range Proof

| #   | Expression               | Min    | Max           | Safe? | Invariant/Guard         |
| --- | ------------------------ | ------ | ------------- | ----- | ----------------------- |
| 1   | block.timestamp + 3600   | ~1.7e9 | ~1.7e9 + 3600 | Yes   | Physical time bound     |
| 2   | builderCode range check  | 1      | 2^48 - 1      | Yes   | Line 336 guard          |
| 3   | uint48(builderCode)      | 1      | 2^48 - 1      | Yes   | Line 336 guard          |
| 4   | block.timestamp < eta    | N/A    | N/A           | Yes   | Comparison only         |
| 5   | \_balanceOfOrZero return | 0      | 2^256 - 1     | Yes   | No arithmetic performed |

C) Findings (prioritized)
For each exploitable or DoS issue:

- ID (ARITH-NNN)
- Severity
- File:line
- Vulnerable expression
- Why checks fail (or are bypassed)
- Preconditions
- Minimal attack sequence
- Concrete impact

D) Contract-wide Arithmetic Invariants

1. **UNLOCK_DELAY addition never overflows**: block.timestamp + 3600 cannot overflow uint256.

   - Established: line 280
   - Consumed: line 294
   - Breaks if: block.timestamp approaches uint256 max (physically impossible)

2. **Builder code cast is lossless**: uint48(builderCode) == builderCode when builderCode <= type(uint48).max.
   - Established: line 336
   - Consumed: line 341
   - Breaks if: range check at line 336 is removed or weakened

E) Patches + Tests
For each finding:

1. Minimal patch (tight edits only).
2. Boundary tests: 0, 1, type(uint48).max, type(uint48).max + 1, type(uint256).max for builder code.
3. Timestamp tests: current timestamp, timestamp + UNLOCK_DELAY, block.timestamp == eta, block.timestamp == eta - 1.

Review rules:

- No generic "check overflow" advice.
- Every claim must cite exact `src/Guardian.sol:line`.
- If a path is uncertain, label "unproven" and show missing link.
- Guardian's arithmetic surface is intentionally small — be thorough but proportionate.

```

```
