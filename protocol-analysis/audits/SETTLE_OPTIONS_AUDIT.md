# `_settleOptions` Audit Findings

## 1. Dust Premium Evasion via Rounding-to-Zero (Low/Medium)

**Objective**: (i) Withdraw more value than entitled (by paying less)

**Mechanism**: When `(accumulator_delta * liquidity) < 2^64`, the integer division in `_getPremia` truncates to 0, yet `s_options[owner][tokenId][leg]` unconditionally advances to the latest accumulator. The premium that rounded to 0 is permanently erased. Repeated calls accumulate the loss.

**Affected paths**: All — `dispatch` (self), `dispatchFrom` (self or third-party). Third-party settlement can only erase long-leg dust; self-settlement erases both long and short.

**Who loses**: Sellers — the long premium that should have flowed into `s_settledTokens` never arrives.

**Viability**: Scales inversely with position liquidity and directly with fee generation rate. Most viable with low-decimal tokens, small positions, and cheap gas (L2s).

**Proposed mitigation**: Only advance `s_options` when premium is nonzero.

```solidity
// In _updateSettlementPostBurn, at the s_options update block (~line 1440):
} else {
    if (tokenId.isLong(leg) != 0 || msg.sender == owner) {
+       // Only advance the accumulator snapshot if premium was actually realized.
+       // Otherwise dust rounds to 0 and the owed amount is permanently lost.
+       if (premiaByLeg[leg].rightSlot() != 0 || premiaByLeg[leg].leftSlot() != 0) {
            s_options[owner][tokenId][leg] = LeftRightUnsigned
                .wrap(0)
                .addToRightSlot(uint128(premiumAccumulatorsByLeg[leg][0]))
                .addToLeftSlot(uint128(premiumAccumulatorsByLeg[leg][1]));

            emit PremiumSettled(owner, tokenId, leg, premiaByLeg[leg]);
+       }
    }
}
```

---

## 2. Solvency Buffer Bypass via Self-DispatchFrom (Medium)

**Objective**: (ii) Operate below intended margin buffer

**Mechanism**: `dispatch` enforces `bpDecreaseBuffer` in the post-settlement solvency check. A user who is below this buffer can bypass it by self-settling through `dispatchFrom` (setting `account = msg.sender`), which uses `NO_BUFFER` for both pre- and post-operation solvency checks.

**Impact**: The user collects short premium (or pays long premium) while operating in the margin danger zone the buffer was designed to exclude. Doesn't cause insolvency but undermines the safety margin.

**Proposed mitigation**: Use a meaningful buffer for the post-settle solvency check in `dispatchFrom`, or disallow self-settlement through this path.

```solidity
// In dispatchFrom, at the post-operation solvency check (~line 1571):
+   (RiskParameters riskParametersPost, ) = getRiskParameters(0);
    _validateSolvency(
        account,
        positionIdListToFinal,
-       NO_BUFFER,
+       riskParametersPost.bpDecreaseBuffer(),
        premiaAsCollateral,
        0
    );
```

Alternatively, block self-settlement through `dispatchFrom`:

```solidity
// In dispatchFrom, at the settle branch (~line 1545):
    if (toLength == finalLength) {
+       if (msg.sender == account) revert Errors.InvalidSender();
        ...
        _settlePremium(account, tokenId, twapTick, currentTick);
```

---

## 3. Spot Tick Manipulation in dispatch Settle Path (Low)

**Objective**: (i) or (ii) — bias premium computation

**Mechanism**: When settling via `dispatch`, `currentTick = getCurrentTick()` is the raw AMM spot tick with no TWAP-spot delta guard. The `cumulativeTickDeltas` check is ineffective for pure settlement (start and end ticks are both spot in the same tx, so delta ≈ 0). Premium is computed at this manipulable tick via `_getPremia(... atTick = currentTick ...)`.

By contrast, `dispatchFrom` enforces `abs(currentTick - twapTick) <= tickDeltaDispatch`.

**Impact**: An attacker who sandwiches their own `dispatch` call can shift spot to bias the premium calculation in their favor. Bounded by the post-settlement solvency check at oracle ticks, but a marginal advantage may be extractable.

**Proposed mitigation**: Use `type(int24).max` as the `atTick` for settlement (only use last-settled accumulator values, not live fee growth). This removes tick sensitivity entirely.

```solidity
// In _settleOptions (~line 1132):
    (realizedPremia, ) = _updateSettlementPostBurn(
        owner,
        tokenId,
        emptyCollectedByLegs,
        positionSize,
        riskParameters,
-       LeftRightSigned.wrap(1).addToLeftSlot(1 + (int128(currentTick) << 2))
+       LeftRightSigned.wrap(1).addToLeftSlot(1 + (int128(type(int24).max) << 2))
    );
```

Note: evaluate whether this changes the semantics of `_getPremia` in ways that affect other callers. If `type(int24).max` triggers a different code path in `SFPM.getAccountPremium`, verify it returns the last-settled value as intended.

---

## 4. Third-Party Commission Fee Imposition (Low)

**Objective**: (ii) — erode collateral

**Mechanism**: A third party settling via `dispatchFrom` forces the target to pay commission at the default `builderCode=0` fee rate, even if the position owner's preferred builder offers lower fees. Each settlement charges `mulDivRoundingUp(abs(premium), premiumFee, DECIMALS)` — rounding up.

**Impact**: Negligible per-call (rounding dust + fee differential), but may matter if a builder offers significantly reduced fees and a griefer force-settles repeatedly.

**Proposed mitigation**: Consider storing the `builderCode` used at mint in `s_positionBalance` and reusing it for settlements on that position.

---

## 5. SFPM Accumulator Monotonicity Assumption (Informational)

**Objective**: (i) — if violated, massive value extraction

**Mechanism**: `_getPremia` computes `(currentAccumulator - storedAccumulator)` in an `unchecked` block. If the SFPM accumulator ever decreases (due to a bug, upgrade, or unforeseen edge case), this underflows to a massive `uint256`, producing incorrect premia.

**Impact**: Catastrophic if triggered, but requires an SFPM-level defect.

**Proposed mitigation**: Add a defensive check before the unchecked subtraction.

```solidity
// In _getPremia (~line 2216), before the unchecked block:
+   if (premiumAccumulatorsByLeg[leg][0] < premiumAccumulatorLast.rightSlot() ||
+       premiumAccumulatorsByLeg[leg][1] < premiumAccumulatorLast.leftSlot())
+       revert Errors.UnderOverFlow();
    unchecked {
        ...
    }
```
