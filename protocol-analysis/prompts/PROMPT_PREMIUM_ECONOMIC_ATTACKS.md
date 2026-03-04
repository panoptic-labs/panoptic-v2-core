# Premium System Economic Attacks Audit Prompt

You are a senior Solidity security researcher performing an adversarial economic audit of the premium accumulation, settlement, and distribution system.

Scope restriction (hard):

- Analyze ONLY files under `contracts/` (recursive).
- Ignore anything outside `contracts/`.
- If you reference a file outside `contracts/`, mark it "out of scope" and do not rely on it for conclusions.

## Objective

Exhaustively evaluate the economic attack surface of the premium system, focusing on:

1. Manipulation of the settled/accumulated premium ratio to extract disproportionate premium
2. Premium settlement timing attacks (front-running, delaying, or sequencing settlements)
3. Cross-chunk premium arbitrage using position construction
4. Premium starvation or denial — preventing sellers from collecting earned premium
5. Long premium evasion — strategies for buyers to avoid or minimize premium payments
6. Interaction between premium and liquidation/force exercise flows

## Assumptions

- Full MEV adversary with sandwich capability.
- Attacker can control multiple accounts simultaneously (buyers, sellers, bystanders).
- Attacker can choose position sizes, chunks, timing, and ordering of operations.
- Attacker can observe pending transactions and front-run/back-run.
- Uniswap fee generation can be influenced by the attacker (via swaps in the underlying pool).
- Premium dust (1-wei level) is only a finding if amplifiable to meaningful amounts.

## Background Context (from prior audits)

### Premium Architecture

The premium system has three layers:

**Layer 1 — SFPM Accumulators (per-chunk global state):**

- `s_accountPremiumOwed[chunkKey]` and `s_accountPremiumGross[chunkKey]` — monotonically non-decreasing accumulators updated via `addCapped` (LeftRight.sol:299-321)
- Updated in `_getPremiaDeltas` (SFPM:1129) using formula: `collected * totalLiquidity * 2^64 / netLiquidity^2`
- Freeze permanently at uint128.max via `addCapped` if overflow would occur (ROUND-006)

**Layer 2 — PanopticPool per-position tracking:**

- `s_grossPremiumLast[chunkKey]` (PP:201) — tracks the last gross premium snapshot for the chunk
- Updated on mint at PP:1236: `(grossCurrent * posLiq + grossLast * totalLiqBefore) / totalLiq`
- Updated on burn at PP:1389: `max(grossLast * totalLiq - grossCurrent * removedLiq + premia * 2^64, 0) / totalLiq`
- `s_settledTokens[chunkKey]` (PP:207) — accumulated settled tokens available for premium distribution
- `_calculateAccumulatedPremia` (PP:509) — computes accumulated and owed premium per position
- `_getAvailablePremium` (PP:2266) — `min(premOwed * settledTokens / accumulated, premOwed)` with sentinel for accumulated==0

**Layer 3 — CollateralTracker settlement:**

- Premium flows through `_updateBalancesAndSettle` (CT:1403) as part of `realizedPremium`
- Short sellers receive premium; long holders pay premium
- Premium is part of the solvency equation (maintenance requirement includes long premia owed minus short premia owed)

### Key Invariants (from prior audits)

- SFPM accumulators are monotonically non-decreasing (addCapped only adds)
- `availablePremium <= premiumOwed` (capped by Math.min at PP:2283)
- `settledTokens` increases by `collectedByLeg` on every mint/burn, decreases by `availablePremium` on seller close
- grossPremiumLast uses floor division, creating systematic underestimate (ROUNDING_AUDIT C.1)
- The `accumulated==0` sentinel (PP:2282) maps to `type(uint256).max` denominator, making available premium 0
- When `accumulated==1`, `premOwed * settled / 1` is capped at `premOwed` (DENOMINATOR_AUDIT B3)

### Known Findings

- DENOM-003 (Medium): Liquidity vacuum (netLiq=1) saturates premium accumulators → cascading premium starvation
- ROUND-006 (Low): addCapped freeze creates permanent premium desync at uint128.max
- ROUND-008 (Low): s_creditedShares monotonic growth affects share price used in premium settlement

## Deliverables (strict order)

### A) Premium Flow Tracing

For the complete lifecycle of premium from Uniswap fee generation to final distribution, trace:

1. **Fee collection path**: Uniswap fees → `_collectAndWritePositionData` (SFPM) → `_getPremiaDeltas` → accumulator update. What determines the per-unit premium attributed to each position?

2. **Premium settlement path (short seller closing)**: `_updateSettlementPostBurn` (PP:1270) → `_getAvailablePremium` → `settledTokens` update → CT settlement. What determines how much of the owed premium the seller actually receives?

3. **Premium settlement path (long holder closing)**: Same burn path, but the buyer pays premium. What determines the amount? Can the buyer influence it?

4. **Premium settlement path (forced settlement via `settleLongPremium`)**: `_settlePremium` (PP:1561 area) — a third party forces a solvent long holder to pay owed premium. When is this triggered? Who can trigger it? What are the economic incentives?

5. **Premium during liquidation**: All positions are burned → premium flows during each leg burn → haircut if protocol loss. How does the ordering of leg burns affect premium distribution?

For each path, identify:

- Every rounding operation and who it favors
- Every state read that could be manipulated by the attacker
- Every ordering dependency (does the result change if operations happen in a different sequence?)

### B) Economic Attack Vectors

#### B.1 Settlement Timing Attacks

**Scenario: Seller front-runs liquidation to lock in premium**

- Seller has a short position in a chunk where a buyer is about to be liquidated.
- The liquidation will trigger `haircutPremia`, clawing back premium paid to sellers.
- If the seller settles (closes their position) BEFORE the liquidation, do they keep the premium?
- Trace the exact state changes: does closing the short update `s_settledTokens`? Does the subsequent liquidation's haircut still apply?
- If the seller re-opens a new position after the liquidation, do they benefit from the reset premium state?

**Scenario: Buyer delays settlement to accumulate owed premium**

- A long holder deliberately avoids any interaction that would trigger premium settlement.
- Meanwhile, `s_accountPremiumOwed` keeps growing as fees accumulate.
- When the owed premium exceeds the buyer's collateral, can they avoid paying by going insolvent?
- Does `settleLongPremium` (forced settlement) prevent this? What is the minimum interval between forced settlements? Can anyone trigger it or only specific actors?
- If the buyer becomes insolvent before anyone forces settlement, is the owed premium written off during liquidation?

**Scenario: Buyer closes position when settled/accumulated ratio is minimal**

- `availablePremium = min(premOwed * settled / accumulated, premOwed)`
- If `settled << accumulated`, the buyer pays very little premium.
- Can the buyer monitor the ratio and time their close to minimize payment?
- Can the buyer manipulate the ratio by generating Uniswap fees (increasing accumulated) without those fees being collected into settledTokens?

#### B.2 Cross-Chunk Premium Arbitrage

**Scenario: Profiting from premium state differences across chunks**

- Two chunks with identical strike/width but different premium accumulation states (one has high settled/accumulated, the other low).
- Attacker shorts in the high-ratio chunk (expects to collect more premium) and longs in the low-ratio chunk (expects to pay less).
- Is this achievable? Different chunks means different tick ranges, so the fee generation differs.
- What about the same chunk at different times? Attacker times entry/exit to exploit premium ratio changes.

**Scenario: Premium dilution via position splitting**

- Attacker mints many small short positions in a chunk to dilute the per-position premium.
- Each position earns premium proportional to its liquidity share.
- Does the `grossPremiumLast` weighted-average update (PP:1236) create any advantage for later entrants vs earlier entrants?
- Can a new short position entering a chunk "steal" accumulated premium from existing shorts?

#### B.3 Premium Starvation Attacks

**Scenario: Liquidity vacuum (DENOM-003 follow-up)**

- Attacker removes all but 1 unit of netLiquidity in a chunk.
- `premium_base = collected * totalLiquidity * 2^64 / netLiquidity^2` → enormous premium delta.
- Accumulators saturate via `addCapped` → permanent freeze.
- Trace the FULL downstream impact:
  - What happens to existing short sellers in this chunk? Can they collect any premium after the freeze?
  - What happens to existing long holders? Do they still owe premium?
  - Can new positions be opened in the frozen chunk? What premium do they see?
  - Is the freeze chunk-specific or does it affect other chunks?

**Scenario: settledTokens manipulation**

- `settledTokens` is increased by `collectedByLeg` on every mint/burn and decreased by `availablePremium` on seller close.
- Can an attacker drain `settledTokens` to near-zero by repeatedly opening and closing short positions that collect available premium?
- If `settledTokens ≈ 0`, then `availablePremium ≈ 0` for all sellers. Is this a viable DoS?
- What happens to the premium that was collected from Uniswap but cannot be distributed because `settledTokens` is zero?

#### B.4 Long Premium Evasion

**Scenario: Dust positions to avoid premium**

- Buyer opens a very small long position (positionSize ≈ 1).
- Premium owed = `(accumulator_delta * liquidity) / 2^64`. For small liquidity, this rounds to 0.
- Can the buyer hold a meaningful economic position while paying zero premium by using many dust positions?
- What are the constraints? (MAX_OPEN_LEGS = 26, gas costs, minimum liquidity from SFPM:972)

**Scenario: Premium evasion via rapid open/close**

- Buyer opens a long, immediately closes it in the same block (or batch).
- During this window, how much premium accrues? Is it possible for the premium to be 0 due to no fee collection?
- The `dispatch` function allows multiple actions in one call. Can the buyer open and close in a single dispatch, paying no premium?

#### B.5 Premium and Solvency Interaction

**Scenario: Premium manipulation to trigger insolvency**

- Owed premium is part of the maintenance requirement.
- Can an attacker force premium to accumulate on a target's long positions (by generating Uniswap fees in the chunk), pushing the target into insolvency?
- What is the cost to the attacker (they must swap in the Uniswap pool to generate fees)?
- Is this profitable if combined with a liquidation bonus?

**Scenario: Premium as solvency shield**

- Short premium owed TO the user reduces their maintenance requirement.
- Can a user construct positions where the short premium credit exceeds the actual collateral requirement, effectively trading with less collateral than intended?
- Does the `usePremiaAsCollateral` flag in `dispatchFrom` affect this?

### C) Invariant Analysis

For each invariant below, determine if it can be violated through premium manipulation:

1. **Premium conservation**: Total premium collected from Uniswap = total premium paid by longs + total unsettled premium. Can premium be created or destroyed?

2. **Available premium monotonicity**: For a given seller's position, does `availablePremium` ever decrease between two observations (assuming no position changes)?

3. **settledTokens conservation**: `Σ(collectedByLeg on burns) - Σ(availablePremium on seller close) = current settledTokens`. Can this be violated?

4. **grossPremiumLast bounded by accumulators**: `grossPremiumLast <= current grossAccumulator` for each slot. Can the burn-path update (PP:1389) violate this? (The `Math.max(..., 0)` clamp suggests it's possible for the expression to go negative.)

5. **Premium owed >= premium available**: By construction (Math.min cap). But can the inputs to `_getAvailablePremium` be manipulated such that the Math.min is ineffective?

### D) Findings

For each finding:

- ID (PREM-NNN)
- Severity (Critical / High / Medium / Low / Informational)
- Category: timing / arbitrage / starvation / evasion / manipulation
- Attack sequence (step-by-step with specific function calls and line references)
- Capital required and expected profit/loss
- Who is harmed and by how much
- Existing mitigations and their effectiveness
- Whether amplifiable (can the attacker loop or scale the attack?)

### E) Patches + Tests

For each finding:

1. Minimal code change if applicable
2. Parameter adjustment if the issue is in constants or thresholds
3. At least 1 concrete test scenario per finding (with specific position sizes, tick ranges, and expected premium values)

## Review Rules

- Every premium computation must be traced through all three layers (SFPM accumulator → PP settlement → CT balance update).
- Do not confuse `premiumOwed` (what the buyer should pay based on accumulators) with `availablePremium` (what the seller can actually collect based on settled tokens). These can diverge significantly.
- Do not assume Uniswap fee generation is exogenous — the attacker can generate fees by swapping in the pool.
- Every claim about premium ordering must account for the fact that `dispatch` can batch multiple operations, and `dispatchFrom` settles all positions atomically.
- Be explicit about which token (token0 vs token1) is involved — the premium system uses LeftRight with separate slots for each token.
- If an attack requires controlling multiple positions in the same chunk, state the minimum capital to achieve the required liquidity shares.
