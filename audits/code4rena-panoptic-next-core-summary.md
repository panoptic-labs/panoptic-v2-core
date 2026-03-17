# Panoptic: Next Core Findings & Analysis Report

*Source: [code4rena.com/reports/2025-12-panoptic-next-core](https://code4rena.com/reports/2025-12-panoptic-next-core)*

#### 2026-03-09

> **Note:** This report was extracted from the Code4rena website. For the complete report with all hyperlinks, contributor attributions, and proof-of-concept details, please visit the original source above.
>
> Due to the extreme length of the full report (~200KB+), this file contains the complete structure and all findings in summarized form. For the full detailed write-ups of each finding including all code snippets and PoCs, refer to the original linked submissions.

---

## Summary

The C4 analysis yielded an aggregated total of **22 unique vulnerabilities**:

- **3 HIGH** severity 
- **19 MEDIUM** severity
- **108 QA reports** (LOW/informational)

All in-scope findings were mitigated. The mitigation review surfaced 1 new Low severity issue.

## Scope

- **Repository:** [code-423n4/2025-12-panoptic](https://github.com/code-423n4/2025-12-panoptic)
- **Commit hash:** `29980a740b67f3e5d9df9d96264a246b51fc7b6b`
- **12 smart contracts**, 6,356 lines of Solidity code
- **Audit period:** December 19, 2025 – January 07, 2026

---

## High Risk Findings (3)

| ID | Title | Status |
|---|---|---|
| H-01 | BuilderWallet `init()` is unprotected/re-initializable, enabling takeover and theft of builder fees | ✅ Mitigated |
| H-02 | Cross-contract reentrancy in liquidation enables conversion of phantom shares to real shares, draining `CollateralTracker` assets | ✅ Mitigated |
| H-03 | Commission fees can always be bypassed | ✅ Mitigated |

## Medium Risk Findings (19)

| ID | Title | Status |
|---|---|---|
| M-01 | Liquidations can be permanently blocked via `getLiquidationBonus()` unsigned underflow | ✅ Mitigated |
| M-02 | `_getRequiredCollateralAtTickSinglePosition()` fails to accumulate credits across multiple legs | ✅ Mitigated |
| M-03 | TWAP misweights EMAs in RiskEngine, anchoring liquidation price to slow EMA | ✅ Mitigated |
| M-04 | Incorrect `UPPER_118BITS_MASK` mask clears EMAs and lockMode | ✅ Mitigated |
| M-05 | Division-by-zero in long-leg collateral for `tickSpacing==1 pools` | ✅ Mitigated |
| M-06 | `dispatchFrom()` liveness DoS via `StaleOracle` | ✅ Mitigated |
| M-07 | Liquidator can receive an inflated bonus against PLPs | ✅ Mitigated |
| M-08 | Wide-range short legs can revert solvency checks (`Errors.InvalidTick`) | Informative |
| M-09 | Incorrect collateral calculation for delayed swap strategies | ✅ Mitigated |
| M-10 | PLPs can withdraw assets needed by long positions, locking buyers | ✅ Mitigated |
| M-11 | An attacker can manipulate oracle easily | Disputed |
| M-12 | Self-settlement via `dispatchFrom` bypasses refund mechanism | ✅ Mitigated |
| M-13 | Intra-epoch `rateAtTarget` updates allow compounding interest rate errors | ✅ Mitigated |
| M-14 | State-price mismatch in liquidation | Acknowledged |
| M-15 | Commission share-burn distribution is JIT-capturable when `builderCode == 0` | Informative |
| M-16 | Force exercise lacks caller-side bounds for exercise fee | Informative |
| M-17 | High divergence check in `isSafeMode` is unreachable dead code | Informative |
| M-18 | Solvency tick divergence blind spot in `RiskEngine.getSolvencyTicks` | ✅ Mitigated |
| M-19 | Withdrawing before bad debt increases losses for remaining LPs | Disputed |

## Mitigation Review

| Original Issue | Status | Commit |
|---|---|---|
| H-01 | ✅ Confirmed | `249fb90` |
| H-02 | ✅ Confirmed | `8d603d3` |
| H-03 | ✅ Confirmed | `5bff34b` |
| M-01 | ✅ Confirmed | `a5cfcd6` |
| M-02 | ✅ Confirmed | `4ef0998` |
| M-03 | ✅ Confirmed | `bebe915` |
| M-04 | ✅ Confirmed | `d434388` |
| M-05 | ✅ Confirmed | `6b154d9` |
| M-06 | ✅ Confirmed | `069c00b` |
| M-07 | ✅ Confirmed | `fb73717` |
| M-09 | ✅ Confirmed | `949a3f4` |
| M-10 | ✅ Confirmed | `b3b005e` |
| M-12 | ✅ Confirmed | `8d603d3` |
| M-13 | ✅ Confirmed | `14bb7cc` |
| M-18 | ✅ Confirmed | `30f90cc` |

**New finding from mitigation review:** Attacker can DoS liquidation by manipulating `currentTick` where the target position appears solvent (Low severity).

---

## Disclosures

C4 audits incentivize the discovery of exploits, vulnerabilities, and bugs in smart contracts. Security researchers are rewarded at an increasing rate for finding higher-risk issues. Audit submissions are judged by a knowledgeable security researcher and disclosed to sponsoring developers. C4 does not conduct formal verification regarding the provided code but instead provides final verification.

C4 does not provide any guarantee or warranty regarding the security of this project. All smart contract software should be used at the sole risk and responsibility of users.
