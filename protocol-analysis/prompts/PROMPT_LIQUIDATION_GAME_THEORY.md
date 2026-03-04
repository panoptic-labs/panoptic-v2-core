# Liquidation & Force Exercise Game Theory Audit Prompt

You are a senior Solidity security researcher performing an adversarial game-theory audit of the liquidation and force exercise mechanisms.

Scope restriction (hard):

- Analyze ONLY files under `contracts/` (recursive).
- Ignore anything outside `contracts/`.
- If you reference a file outside `contracts/`, mark it "out of scope" and do not rely on it for conclusions.

## Objective

Exhaustively evaluate the economic attack surface of the liquidation and force exercise systems, focusing on:

1. Profitable self-liquidation or circular liquidation strategies
2. Price manipulation to trigger or prevent liquidations
3. Liquidation cascades that amplify protocol loss
4. MEV extraction from liquidation and force exercise transactions
5. Premium haircut manipulation to extract value during liquidation
6. Force exercise as a griefing or value extraction vector

## Assumptions

- Full MEV adversary: can sandwich, front-run, back-run, and control transaction ordering within a block.
- Multi-block MEV: proposer can manipulate Uniswap spot price across 2-3 consecutive blocks.
- Attacker can control multiple accounts (liquidatee + liquidator + bystander).
- Attacker can hold positions in multiple chunks simultaneously.
- Uniswap spot price can be moved via flash loans (but TWAP and median oracle resist this to varying degrees).
- Gas costs are relevant but secondary — a profitable attack at >$100 net profit is a finding even if gas-intensive.

## Background Context (from prior audits)

Architecture:

- Liquidations are initiated via `dispatchFrom` (PP:1491), routed to `_liquidate` (PP:1667) when the account is insolvent at all checked ticks.
- Force exercises are routed to `_forceExercise` (PP:1784) when the account is solvent and a single long position is targeted.
- `isAccountSolvent` (RE:977) checks solvency at the oracle tick, with additional ticks checked when fast/slow oracle diverge beyond `MAX_TICKS_DELTA = 953`.
- `MAX_TWAP_DELTA_DISPATCH = 513` is enforced for force exercises and premium settlements, but NOT for liquidations.
- Liquidation bonus: `min(bal/2, req - bal)` per token (RE:520-521), computed cross-collaterally.
- Premium haircut: if protocol loss exists after liquidation, premium paid to sellers during the liquidation is clawed back proportionally via `haircutPremia` (RE:599).
- `settleLiquidation` (CT:1246) handles share minting for protocol loss socialization, capped at `totalSupply * DECIMALS`.
- Force exercise cost: base 1.024% for in-range, decaying exponentially for out-of-range (RE:406, `FORCE_EXERCISE_COST = 102_400`).
- The oracle uses an 8-slot sorted median queue with 12-bit residual ticks and cascading EMAs (fast/slow/eons).
- Position size bounded at int128.max - 4. Deposit cap at type(uint104).max.

Known findings from prior audits:

- ARITH-002 (Medium): `settleLiquidation` mintedShares potential underflow at CT:1338-1344
- DENOM-004 (Low): settleLiquidation quotient amplification when bonus ≈ totalAssets
- Commission split leak ~10% when builder codes active (ARITH-001)

## Deliverables (strict order)

### A) Liquidation Attack Surface Map

For each attack vector below, analyze feasibility, profitability, and mitigations:

#### A.1 Self-Liquidation via Operator

- Attacker creates positions on Account A, grants operator approval to Account B.
- Account B calls `dispatchFrom` to liquidate Account A.
- Does the liquidation bonus transfer from A to B create a net profit for the attacker (who controls both)?
- What is the minimum capital required? Maximum extractable profit?
- Does the commission paid on position creation exceed the bonus received?
- Can the attacker manipulate price to make A just barely insolvent, maximizing the remaining collateral (and thus the bonus)?

#### A.2 Liquidation Price Manipulation

- Since `MAX_TWAP_DELTA_DISPATCH` does NOT apply to liquidations:
  - Can an attacker move the Uniswap spot price via flash loan to make a target insolvent at the current tick?
  - The solvency check uses oracle ticks (fast, slow, median), not spot. How far can the oracle be dragged in 1 block? In N blocks (proposer MEV)?
  - What is the minimum price movement needed to flip a marginally-solvent account to insolvent?
  - Trace the exact oracle tick computation path during liquidation: which tick(s) are used? Can the attacker influence them?

#### A.3 Liquidation Sandwiching

- Attacker sees a pending liquidation in the mempool.
- Front-run: move price to maximize the liquidation bonus (make the account more insolvent).
- Execute: liquidate (or let the original tx execute).
- Back-run: reverse the price movement.
- What are the constraints? Does the oracle resist this? At what time horizon does the oracle catch up to the manipulated price?

#### A.4 Cascade Liquidation Amplification

- Liquidation of Account A causes protocol loss → shares minted → share price drops → `totalAssets` effectively decreases.
- Does this reduced share price cause other accounts to become insolvent?
- Can an attacker trigger a cascade by strategically liquidating the most-leveraged account first?
- What is the maximum cascade depth? Is there a natural damping mechanism?
- How does the `totalSupply * DECIMALS` cap on minted shares interact with cascades?

#### A.5 Premium Haircut Timing Attack

- During liquidation, if premium is paid to sellers and protocol loss exists, the premium is haircut via `haircutPremia` (RE:599).
- Can a seller arrange to settle their premium BEFORE the liquidation (in the same block, front-running the liquidator)?
- If premium is settled before the liquidation, is it still subject to haircut? Or does settlement lock it in?
- Can a seller create a position in a chunk where they know a liquidation is about to happen, collect premium during the liquidation's position closing, and extract that premium before the haircut is applied?

#### A.6 Bonus Manipulation via Position Construction

- The liquidation bonus depends on `req - bal` (shortfall). Can the liquidatee construct positions that maximize the bonus-to-collateral ratio?
- Spread positions, strangles, and multi-leg strategies have different collateral requirements. Which position types maximize the bonus for a given collateral deposit?
- Can the attacker exploit the cross-collateralization formula to inflate the bonus in one token while having excess in the other?

### B) Force Exercise Attack Surface

#### B.1 Force Exercise Griefing

- An attacker force-exercises many out-of-range long positions belonging to different users.
- The cost is `ONE_BPS` (0.01%) per position for far-out-of-range positions — is this cheap enough to be a viable griefing vector?
- What is the economic impact on the exercised user? (They lose their position and receive the exercise cost.)
- Can an attacker force-exercise positions to manipulate the liquidity distribution in a chunk, enabling other attacks?

#### B.2 Force Exercise + Liquidation Combo

- Attacker holds a short position that is barely solvent.
- Another user holds a long position in the same chunk that is out of range.
- If the long is force-exercised, liquidity returns to the chunk → the short position's premium dynamics change.
- Can this be used to manipulate the attacker's solvency status? To avoid liquidation? To trigger liquidation of others?

#### B.3 Force Exercise Cost Function Analysis

- The cost uses exponential decay: `FORCE_EXERCISE_COST * 2^(-shifts)` where shifts depends on distance from range.
- At what distance does the cost become negligible (< gas cost)?
- Is the cost symmetric for calls vs puts (token0 vs token1)?
- Can the cost be manipulated by the exercisor choosing when to exercise (oracle tick influences the delta computation)?

### C) Cross-Collateral Liquidation Edge Cases

For the dual-token collateral system:

1. Account has excess in token0, deficit in token1. The cross-collateral buffer converts excess to cover the deficit.

   - At what exchange rate is the conversion done? (Oracle tick.)
   - Can the attacker manipulate the oracle tick to make the conversion rate unfavorable, triggering a false liquidation?
   - What happens when the `crossBufferRatio` drops to 0 (above 95% utilization)? Does this make cross-collateral liquidation impossible?

2. Account has positions in both CollateralTrackers.

   - The bonus is computed per-token then combined. Can rounding in the per-token computation cause the combined bonus to exceed the actual available collateral?
   - What happens when bonus0 > 0 but bonus1 < 0 (deficit in one token)? Trace the `tokenConversion` path at RE:550-580.

3. Extreme price scenarios.
   - At `MIN_POOL_TICK` or `MAX_POOL_TICK`, one token is worth ~0 relative to the other. How does the cross-collateral system behave? Does `convert0to1` or `convert1to0` produce reasonable values?

### D) Findings

For each finding:

- ID (LIQ-NNN)
- Severity (Critical / High / Medium / Low / Informational)
- Category: self-liquidation / price-manipulation / cascade / MEV / griefing / timing
- Attack sequence (step-by-step with specific function calls)
- Capital required and expected profit/loss for the attacker
- Who is harmed and by how much
- Existing mitigations and their effectiveness
- Whether the attack is repeatable/scalable

### E) Economic Bounds

For each attack that is theoretically possible but constrained:

1. Compute the break-even point (minimum position size, minimum price movement, etc.)
2. Compare against realistic gas costs on target chains
3. Estimate the maximum extractable value under realistic conditions
4. Identify the protocol parameters that most influence the attack's viability (e.g., if `FORCE_EXERCISE_COST` were halved, would an attack become viable?)

### F) Recommendations

For each finding:

1. Minimal code change (if applicable)
2. Parameter adjustment (if the issue is in constants)
3. Monitoring/alerting suggestion (for issues that can't be fully prevented on-chain)

## Review Rules

- No generic "add a check" advice without specifying exactly what, where, and what edge case it handles.
- Every attack sequence must include concrete numbers (position sizes, prices, expected bonus amounts).
- Every claim about oracle behavior must cite the specific oracle computation path and explain why/how the oracle resists or permits the manipulation.
- Do not assume rational behavior from the liquidatee — they may be the attacker.
- Do not assume liquidations happen promptly — the attacker may delay liquidation strategically.
- If an attack requires multi-block MEV (proposer control), state this explicitly and assess feasibility on Ethereum mainnet vs L2s.
- Distinguish between attacks that require collusion (multiple entities) vs single-actor attacks.
