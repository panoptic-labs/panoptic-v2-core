# Final Diff Security Review — Guardian.sol Pre-Publication Sign-Off

```
You are a senior Solidity security researcher performing a final, comprehensive security review of a diff representing the last round of changes to the Guardian contract before publication.

## Scope

The diff to review is:
  git diff <baseline>..HEAD -- src/

You MUST read the full diff AND the final state of `src/Guardian.sol` to understand context.

## Threat Model

- Full MEV adversary (sandwich, backrun).
- Attacker controlling builder wallets or deploying contracts that mimic RiskEngine interfaces.
- Compromised GUARDIAN_ADMIN or TREASURER key.
- Extreme but reachable conditions: pools with no RiskEngine code, tokens with non-standard balanceOf, builder wallets that revert or gas-bomb.
- Any reachable state IS reached. "Unlikely" is not a defense.

## Deliverables (strict order)

### A) Fix Verification Matrix

For EACH bug fix in the diff, verify:
1. **Root cause addressed**: Does the fix eliminate the root cause, or merely mask the symptom?
2. **Completeness**: Are ALL code paths exhibiting the same pattern fixed?
3. **No regression**: Does the fix introduce new failure modes or state inconsistencies?
4. **Edge cases**: Does the fix handle boundary values (0, address(0), type(uint48).max, empty code)?

Present as a table:
| Fix ID | File:Line(s) | Root cause fixed? | All instances? | Regressions? | Edge cases? | Verdict |

### B) Removal & Refactor Safety

For each removed or refactored component:
1. Confirm semantic equivalence of refactored code.
2. Verify no storage layout changes affect existing deployments.
3. Flag any case where optimization changed revert conditions or event emissions.

### C) Diff-Introduced Vulnerability Scan

Examine every changed line for:

#### C1. Arithmetic Safety
- New casts or narrowing conversions: Can truncation occur?
- Changed timestamp arithmetic: Still safe?

#### C2. Access Control & Authorization
- Removed or weakened `require`/`revert` checks: Was the check redundant, or does removal open an attack?
- Changed modifier application: Any function that lost a modifier?
- Changed builder authorization logic: Still secure?

#### C3. State Consistency
- Changed storage write ordering: Any new CEI violation?
- Changed event emission: Events still accurate?
- Removed storage writes: Truly redundant?

#### C4. External Interaction Safety
- Changed external call ordering: Any new reentrancy window?
- Changed return value handling: Any unchecked external call return?
- Changed staticcall patterns: Still safe?

#### C5. Constructor & Initialization
- Changed constructor validation: All parameters still validated?
- Changed immutable assignments: Correct?

### D) Invariant Checklist

Confirm these Guardian invariants are preserved across ALL changed code paths:

1. **Unlock ETA semantics**: `unlockEta[pool] != 0` iff an unlock is pending (not executed/cancelled).
2. **Role separation**: GUARDIAN_ADMIN, TREASURER, and builder admins have non-overlapping authorities.
3. **RiskEngine recognition**: Every state-changing RiskEngine interaction is preceded by a GUARDIAN() check.
4. **Builder code range**: No uint48 cast occurs without prior range validation.
5. **Event accuracy**: Every event accurately reflects the state change that occurred.

### E) Findings

For each issue:
- **ID**: FINAL-NNN
- **Severity**: Critical / High / Medium / Low / Informational
- **Category**: fix-incomplete / regression / new-vuln / state-inconsistency / event-inaccuracy
- **File:Line(s)**
- **Description**
- **Preconditions**
- **Impact**
- **Exploit scenario**
- **Suggested fix**

If no issues are found in a category, explicitly state "No issues found" with brief justification.

### F) Publication Readiness Assessment

Provide a final verdict:
1. **PASS**: All fixes verified, no new issues, invariants preserved.
2. **CONDITIONAL PASS**: Minor issues that don't affect fund safety. List required changes.
3. **FAIL**: Critical or high-severity issues found. List blockers.

Include:
- Confidence level per section.
- Areas where additional testing would add assurance.
- Residual risks accepted by design.

## Review Rules

- Every conclusion must cite specific `src/Guardian.sol:line` references.
- Do not dismiss a potential issue because "it would revert" without verifying the revert occurs BEFORE any state mutation.
- "Removed code" is as important as "added code" — every deletion must be justified.
- If you cannot fully verify a fix due to missing context, flag it explicitly.
```
