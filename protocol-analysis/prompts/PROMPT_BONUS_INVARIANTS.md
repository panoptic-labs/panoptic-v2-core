# Liquidation Bonus Invariants Audit Prompt

You are a senior Solidity security researcher performing an adversarial invariant audit of the liquidation bonus mechanism.

Scope restriction (hard):

- Analyze ONLY files under `contracts/` (recursive).
- Ignore anything outside `contracts/`.
- If you reference a file outside `contracts/`, mark it "out of scope" and do not rely on it for conclusions.

## Objective

Formalize and prove or disprove the bonus-formula invariants below against the current implementation. Specifically:

1. State each target invariant as a precise mathematical predicate over the bonus formula's inputs and outputs.
2. Prove the predicate against the code, or produce a concrete counterexample.
3. Enumerate additional invariants the bonus mechanism should satisfy that are not in the target set.
4. Map current Foundry test coverage against each invariant and identify gaps.
5. For each gap or violation, propose the smallest code or test change that closes it.

## Assumptions

- Full MEV adversary: can sandwich, front-run, back-run, and control transaction ordering within a block.
- Multi-block MEV: proposer can manipulate Uniswap spot price across 2-3 consecutive blocks.
- Attacker can control multiple accounts (liquidatee + liquidator + bystander).
- Attacker can hold positions in multiple chunks simultaneously.
- Uniswap spot price can be moved via flash loans; the internal TWAP and 8-slot median oracle resist this to varying degrees.
- Gas costs are relevant but secondary — a profitable attack at >$100 net profit is a finding even if gas-intensive.

## Background Context (from prior audits)

Architecture:

- `getLiquidationBonus` (RE:506-617) computes per-token bonus as `bonus_t = min(MAX_BONUS * req_t / DECIMALS, max(req_t - bal_t, 0))`, then runs a cross-conversion arm at RE:560-606 when one token is in deficit and the other in surplus.
- `getMargin` / `_getMargin` (RE:1082-1200) assemble `bal_t` (including `assetsAndInterest`, short premium, credits) and `req_t` (including the MMR cushion and capped interest).
- `MAX_BONUS = 2_000_000`, `DECIMALS = 10_000_000`, `MMR ≈ 10%`. The bonus is anchored on `req_t = (1+MMR) * loan`, NOT on user collateral.
- The four-tick insolvency gate (PP:1591-1606) requires the account to be insolvent at `{spotTick, twapTick, latestTick, currentTick}` using a single `shortPremium` snapshot at `currentTick` before `_liquidate` (PP:1744-1854) runs.
- `haircutPremia` (RE:620-740) claws back long premium up to `min(protocolLoss, longPremium)` and emits `bonusDeltas` added back to the liquidator's bonus.
- `settleLiquidation` (CT:1253-1382) materializes any residual protocol loss by minting CT shares to the liquidator and emitting `ProtocolLossRealized` (CT:1340-1380).
- TWAP for bonus pricing: `twapEMA = (6*fastEMA + 3*slowEMA + eonsEMA)/10` (RE:843-847).
- Credit accounting: `getTotalCreditAmounts` (PanopticMath:839-867) mirrors the per-tick credit term in `_getRequiredCollateralAtTickSinglePosition`; both sides anchor on `getAmountsMoved(..., false)`.

Known findings from prior audits:

- M-02: prior boundary case where `bonus = 0` at `bal ≈ req` killed liquidator incentive. Fixed by anchoring the bonus on `req` (not collateral). The current formula is the result.
- `I9_SELF_LIQUIDATION_ANALYSIS.md`: 13 candidate vectors enumerated; none confirmed an I9 violation in the current tree. Combined borrower + liquidator P&L was empirically -13,470,912 token1 in the cross-collateralized harness.
- `PURE_LOAN_LIQUIDATION_ECONOMICS_AUDIT.md`: pure-loan bonus recycling produces `ProtocolLossRealized` (LP-loss surface) but not I9 violation.
- Credit double-count fix at commit 94fab92f: addressed `creditAmounts` cancelation in `getLiquidationBonus`.
- `test_Success_creditMirror_tickInvariance` (test/foundry/core/Misc.t.sol) is currently the only Foundry test that pins an invariant of this class (credit-mirror tick invariance).

Protocol stance on the target invariants:

- **I1, I2, I6, and I9 are must-hold**:
  - I1 was the explicit target of the bonus-formula redesign; a regression makes liquidations stall.
  - I2 must hold: `ProtocolLossRealized > 0` ⟹ the borrower's **post-liquidation** balance is `<= 0` on **every** token. Equivalently, if any borrower token balance is strictly positive after liquidation settles, no LP dilution may be emitted. This is a final-state predicate, not a pre-bonus predicate: it is acceptable for the bonus to consume the borrower's pre-bonus equity (`bal_t - netPaid_t - creditAmounts_t > 0`) down to zero before LPs are touched. What is not acceptable is leaving surplus on one token while emitting `ProtocolLossRealized` on another, or leaving any positive balance on the same token where loss is realized. The cross-conversion arm at RE:560-606 and `settleLiquidation` at CT:1253-1382 are the enforcement surface — audit specifically whether conversion caps, TWAP rounding (RE:573-594), or settle-time accounting can strand positive borrower balance on any token while minting fresh CT shares to the liquidator.
  - I6 is the M-02 fix; a regression here re-opens the prior finding.
  - I9 has been empirically verified by harness and prior audit; a regression is critical.
- **I3 is stated, not required**: a non-monotone bonus is acceptable so long as I1, I2, I6, I9 hold.

Score recommendations accordingly: do not propose a fix that strengthens I3 at the cost of I1 or I6. Also do not propose fixes that re-open M-02, and do not propose fixes that weaken I1, I6, or I9 in order to satisfy I2 — if you cannot satisfy I2 without weakening another must-hold invariant, surface the tension explicitly with a concrete trade-off analysis rather than silently picking a side.

## Deliverables (strict order)

### A) Invariant Formalization

For each of I1, I2, I3, I6, I9 below, state:

- the precise mathematical predicate over `bal_t`, `req_t`, `bonus_t`, `netPaid`, `shortPremium`, `creditAmounts`, `atTick`, `protocolLoss`
- the preconditions (account state, tick configuration, position structure) under which the predicate is required to hold
- the expected enforcement site in code, cited as `file:line`
- decidability status: `formal` (provable from the formula), `empirical` (requires harness/fuzz to confirm), or `operational` (relies on off-chain assumptions such as keepers or backstops)

Target invariants:

- **I1** Liquidator-incentive floor: `bonus_value > 0` whenever the account is liquidatable.
- **I2** Protocol-loss safety (final-state form): `ProtocolLossRealized_t > 0` for any token t ⟹ for all tokens s, the borrower's post-liquidation balance `bal_s^{post} <= 0`. Equivalently, the predicate to disprove is `∃ s : bal_s^{post} > 0 ∧ ∃ t : ProtocolLossRealized_t > 0`. `bal_s^{post}` means the borrower's CT-share-denominated balance after `_liquidate`, `haircutPremia`, and `settleLiquidation` have all run. Do NOT use the pre-bonus per-token equity `bal_t - netPaid_t - creditAmounts_t` as the test — that framing is too strong and forbids legitimate consumption of borrower equity by the bonus.
- **I3** Bonus monotone in distress: `bonus_t` is non-decreasing in `(req_t - bal_t) / req_t`.
- **I6** Continuity at the liquidation boundary: `lim_{bal_t -> req_t^-} bonus_t > 0` (no cliff to zero at the M-02 boundary).
- **I9** No self-liquidation profit: for any borrower B and liquidator L controlled by the same actor, combined cash-equivalent P&L valued at TWAP is `<= 0` net of gas and Uniswap fees.

### B) Per-Invariant Proof or Disproof

For each target invariant, assign status `Holds` / `Holds-only-under-stated-assumptions` / `Violated` / `Unproven`. Then:

- If `Holds`: cite the code path(s) that enforce it, with `file:line`. Show the chain of bounds that closes the proof.
- If `Holds-only-under-stated-assumptions`: enumerate every assumption, cite where each is enforced (`file:line`), and label any operational assumption (keeper, backstop, off-chain monitoring) as such.
- If `Violated`: produce a concrete counterexample with tick values, position structure, capital required, and a step-by-step sequence. Compute the resulting violation magnitude.
- If `Unproven`: name the exact missing bound (`file:line` or "absent") and what would need to be added to close it.

For I9 specifically, your starting point is `protocol-analysis/audits/I9_SELF_LIQUIDATION_ANALYSIS.md`. Re-derive its conclusions rather than relying on them; flag any vector in that document you believe was insufficiently refuted.

### C) Additional Invariants

Enumerate any invariants not in {I1, I2, I3, I6, I9} that the bonus mechanism should satisfy. Candidates to consider (do not limit yourself to these):

- Rounding-direction invariants: `convert1to0RoundingUp` vs `convert0to1` at RE:573-594 — does the rounding asymmetry leak in the protocol-conservative direction at all amounts?
- Conservation: `sum_t (bonus_t + protocolLoss_t)` equals what the cross-conversion arm consumes from the deficit side; does the equation balance at every code path?
- Monotonicity in `positionSize`: doubling `positionSize` should at most double `bonus_value` at the same tick.
- `MAX_BONUS` calibration: is `2_000_000 / 10_000_000 = 20%` reachable in practice given the `req_t - bal_t` arm, or is the cap arm dead code?
- Token symmetry: swap token0 ↔ token1 inputs to `getLiquidationBonus` and the outputs mirror.
- `haircutPremia` round-trip: `bonusDeltas + haircutTotal` reconstructs to the original `netPaid` invariant at RE:620+.

For each: predicate, current status (`Holds` / `Violated` / `Unproven`), and recommendation.

### D) Findings (prioritized)

For each violation or unproven path that admits exploitation or value extraction:

- ID (e.g. `BONUS-I2-01`)
- Severity: Critical / High / Medium / Low / Informational. `Critical` requires both (a) a confirmed attack and (b) value extraction beyond gas at realistic parameters.
- Invariant violated
- File:line of the offending code
- Predicate that fails
- Why the current code allows the violation (one paragraph, cite line references)
- Preconditions: market state, position structure, oracle state, capital required
- Minimal attack sequence (numbered steps with tick values)
- Concrete impact: token amounts, percent of position notional, who is harmed and by how much
- Repeatability: single-shot / amplifiable / requires capital lockup

### E) Test Coverage Gap Map

For each invariant in A) and C), state whether a Foundry test currently pins it. Search at minimum:

- `test/foundry/core/Misc.t.sol`
- `test/foundry/core/RiskEngine.t.sol`
- `test/foundry/core/PanopticPool.t.sol`
- `test/foundry/core/CollateralTracker.t.sol`

Format per invariant: `pinned` (with test name) / `partially pinned` (which case is missing) / `unpinned`. For each `unpinned` or `partially pinned` invariant, propose a unit test name and the shape (inputs, assertion form) — do not include full Solidity code. Require at least 1 fuzz invariant per invariant category, with the input space and bound functions named.

The only currently known test of this class is `test_Success_creditMirror_tickInvariance` in `test/foundry/core/Misc.t.sol`. If you find others, list them; if you do not, state so explicitly.

### F) Recommendations

For each invariant, classify as one of:

- `keep-and-encode-as-test` (invariant holds, just needs a test pin)
- `weaken-with-rationale` (invariant does not hold as stated, but a weaker form does; state both)
- `strengthen-formula` (invariant should hold but does not; propose the smallest code change at `file:line` that closes it)
- `drop-as-out-of-scope` (invariant should not be a goal; argue why)

For `strengthen-formula` recommendations, the proposed change must not weaken I1, I6, or I9. If the trade-off is unavoidable, state the trade-off explicitly.

## Review Rules

- No generic invariant advice ("check for overflow", "validate inputs"). Every claim must be specific to the bonus formula and its call sites.
- Every claim must cite exact `contracts/...:line`.
- Unproven paths must be labeled `Unproven` with the missing bound named.
- Be explicit about rounding direction and who benefits (liquidator / liquidatee / LPs / protocol).
- Do not assume liquidations happen promptly — the attacker may delay strategically.
- Do not propose fixes that re-open M-02. If a recommendation reduces `bonus_t` toward zero at the liquidation boundary, flag it explicitly.
- If a finding contradicts the prior I9 audit, you must cite the specific vector in `I9_SELF_LIQUIDATION_ANALYSIS.md` that you believe was insufficiently refuted, and show why.
