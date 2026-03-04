# Oracle Manipulation & MEV Resilience Audit Prompt

You are a senior Solidity security researcher performing an adversarial audit of the oracle system's resistance to price manipulation and MEV attacks.

Scope restriction (hard):

- Analyze ONLY files under `contracts/` (recursive).
- Ignore anything outside `contracts/`.
- If you reference a file outside `contracts/`, mark it "out of scope" and do not rely on it for conclusions.

## Objective

Exhaustively evaluate the oracle system's resistance to:

1. Single-block spot price manipulation (flash loans, sandwich attacks)
2. Multi-block manipulation (proposer MEV, consecutive block control)
3. Oracle staleness exploitation (acting on outdated prices)
4. Safe mode bypass or weaponization (forcing/preventing safe mode to enable attacks)
5. Oracle tick divergence exploitation (manipulating the gap between fast/slow/median/spot)
6. Oracle-dependent solvency manipulation (using oracle behavior to trigger false liquidations or prevent legitimate ones)

## Assumptions

- Full MEV adversary: can reorder, insert, and censor transactions within a block.
- Multi-block MEV: proposer can control 2-4 consecutive blocks on Ethereum mainnet (realistic with PBS/MEV-Boost). On L2s, sequencer controls all ordering.
- Flash loans provide unlimited single-block capital for Uniswap spot price manipulation.
- Attacker can call `pokeOracle` (PP:605) to insert observations at chosen times.
- Attacker can interact with the Uniswap pool directly (swaps) to move the spot price.
- Uniswap TWAP (used in `computeMedianObservedPrice`, PM:266) is the external oracle dependency.

## Background Context

### Oracle Architecture

The protocol uses a custom internal oracle (NOT Uniswap TWAP directly for solvency). The oracle is a single `uint256` packed as `OraclePack` with:

**8-Slot Sorted Median Queue** (bits 0-95 of OraclePack):

- 8 observations, each stored as a 12-bit signed residual relative to `referenceTick`
- Residual range: [-2048, 2047] ticks. If an observation exceeds this, `rebaseOraclePack` (OP:611) shifts the reference.
- `orderMap` (bits 208-231): 8 x 3-bit rank indices maintaining sort order for median extraction.
- New observations are inserted via `insertObservation` (OP:434), overwriting slot 7 and updating `orderMap`.

**4 Cascading EMAs** (bits 120-207):

- `spotEMA` (22 bits, period 60s = 1 min) — fastest, tracks spot most closely
- `fastEMA` (22 bits, period 120s = 2 min)
- `slowEMA` (22 bits, period 240s = 4 min)
- `eonsEMA` (22 bits, period 960s = 16 min) — slowest, most resistant to manipulation
- Updated in `updateEMAs` (OP:359) with capped `timeDelta` per EMA (3/4 of period max)
- EMA periods defined in `RiskEngine.EMA_PERIODS` (RE:69): `uint96(60 + (120 << 24) + (240 << 48) + (960 << 72))`

**Tick Clamping:**

- `clampTick` (OP:509): limits new observation to `±MAX_CLAMP_DELTA` (RE:95, value=149) ticks from the previous observation
- This means per-observation, the oracle can move at most 149 ticks (~1.5% price move)
- With 64-second epochs, maximum oracle drift ≈ 149 ticks / 64s ≈ 2.33 ticks/second

**Epoch System:**

- `epoch = block.timestamp >> 6` (64-second epochs)
- New observations can only be inserted when `epoch > oraclePack.epoch()` (OP:548 guard in `computeInternalMedian`)
- This limits observation insertion to at most 1 per 64-second epoch

### Tick Consumption in Solvency

**Normal mode** (`safeMode == 0` and oracle ticks agree):

- Solvency checked at 1 tick: `spotTick` (the spot EMA)
- `getSolvencyTicks` (RE:926) returns a single-element array

**Safe mode** (triggered when any of these conditions hold):

1. `|currentTick - spotEMA| > MAX_TICKS_DELTA (953)` — external shock (RE:897)
2. `|spotEMA - fastEMA| > 476` — internal disagreement (RE:902)
3. `|medianTick - slowEMA| > 476` — high divergence (RE:907)
4. `lockMode > 0` — guardian override (RE:909-912)

When safe mode triggers OR Euclidean norm of tick vector exceeds `MAX_TICKS_DELTA`:

- Solvency checked at ALL 4 ticks: `spotTick`, `medianTick`, `latestTick`, `currentTick` (RE:942-953)
- Account must be solvent at EVERY tick to pass

**Dispatch TWAP check:**

- For force exercises and premium settlements: `|currentTick - twapTick| <= MAX_TWAP_DELTA_DISPATCH (513)` (PP:1540-1544)
- `twapTick = (6*fastEMA + 3*slowEMA + eonsEMA) / 10` (RE:814)
- This check does NOT apply to liquidations

### Oracle Initialization (PP:327-355)

- All 4 EMAs initialized to `currentTick`
- Median queue filled with sentinel values
- First real observation overwrites slot 7

### Key Constants

| Constant                | Value                  | Location                |
| ----------------------- | ---------------------- | ----------------------- |
| MAX_TICKS_DELTA         | 953 (~10% price)       | RE:72                   |
| MAX_TWAP_DELTA_DISPATCH | 513 (~5% price)        | RE:76                   |
| MAX_CLAMP_DELTA         | 149 (~1.5% price)      | RE:95                   |
| Epoch duration          | 64 seconds             | OP:232 (timestamp >> 6) |
| EMA periods             | 60/120/240/960 seconds | RE:69                   |

## Deliverables (strict order)

### A) Single-Block Manipulation Analysis

#### A.1 Flash Loan Spot Manipulation

- Attacker uses a flash loan to move the Uniswap spot price by X%.
- The protocol reads `currentTick` from Uniswap's `slot0()`.
- **Question**: Which operations use `currentTick` directly vs oracle ticks?
  - `dispatch` reads `currentTick` at entry (PP:759). Trace where this value flows.
  - `pokeOracle` inserts an observation derived from `currentTick` (after clamping).
  - Solvency checks use oracle ticks, not `currentTick` directly. But `currentTick` is one of the 4 safe-mode ticks.
- If safe mode is active, solvency is checked at `currentTick` among others. Can flash-loan manipulation of `currentTick` cause an account to appear insolvent at this one tick?
- What if the account is solvent at the 3 oracle ticks but insolvent at the manipulated `currentTick`? The check requires solvency at ALL ticks.

#### A.2 Sandwich Around pokeOracle

- Attacker sandwiches a `pokeOracle` call:
  1. Swap to move spot price
  2. `pokeOracle` records the manipulated tick (clamped by MAX_CLAMP_DELTA)
  3. Reverse the swap
- After this, the oracle has incorporated a manipulated observation (up to ±149 ticks from last).
- How many such sandwiched observations are needed to move the median? (Need to corrupt 5 of 8 sorted slots.)
- How long does this take? (1 observation per 64-second epoch minimum.)
- Cost to the attacker per sandwiched observation (swap fees, slippage).

#### A.3 Token Amount Computation at Manipulated Prices

- `getAmountsMoved` (PanopticMath) computes token amounts using Uniswap's sqrt price math.
- If these are computed at a manipulated `currentTick`, do they affect settlement amounts?
- Trace: during `_createLegInAMM` (SFPM), which price is used for amount calculations — the pool's actual price or a protocol-determined price?

### B) Multi-Block Manipulation Analysis

#### B.1 Proposer MEV (2-4 Consecutive Blocks)

- Proposer controls transaction ordering in N consecutive blocks (12-48 seconds on mainnet).
- In each block, proposer:
  1. Moves Uniswap spot price in one direction
  2. Calls `pokeOracle` to record the manipulated tick
  3. Optionally performs other operations
- With MAX_CLAMP_DELTA = 149 per observation:
  - After 1 epoch (64s, may span 5 blocks): oracle moves by up to 149 ticks
  - After 4 epochs (256s): up to 596 ticks — close to MAX_TICKS_DELTA (953)
  - After 7 epochs (448s, ~7.5 min): up to 1043 ticks — exceeds MAX_TICKS_DELTA
- **Question**: How many consecutive epochs must the attacker control to:
  - Move the median tick by X ticks?
  - Trigger safe mode?
  - Prevent safe mode from triggering when it should?
  - Make a solvent account appear insolvent (or vice versa)?

#### B.2 EMA Drift Under Sustained Manipulation

- If the attacker sustains a price manipulation for T seconds:
  - `spotEMA` (60s period) converges to the manipulated price in ~3-4 periods (180-240s)
  - `fastEMA` (120s period) in ~360-480s
  - `slowEMA` (240s period) in ~720-960s
  - `eonsEMA` (960s period) in ~2880-3840s
- The `twapEMA` (RE:814) weights: 60% fast + 30% slow + 10% eons.
- **Compute**: for a sustained manipulation of D ticks for T seconds, what is the resulting shift in each EMA and in `twapEMA`?
- At what T does `twapEMA` shift enough to enable a false liquidation?

#### B.3 Observation Insertion Timing

- Observations can only be inserted once per epoch (64s).
- Who can call `pokeOracle`? (Anyone — PP:605 is `external nonReentrant`.)
- Can the attacker prevent others from calling `pokeOracle` in an epoch? (By front-running with their own call.)
- If the attacker controls `pokeOracle` timing, they control which ticks are recorded.
- **Scenario**: Attacker front-runs all `pokeOracle` calls for N epochs, always recording a tick favorable to them. Meanwhile, the true market price is moving in the opposite direction. How long until the oracle self-corrects?

### C) Staleness Exploitation

#### C.1 Stale Oracle State

- If no one calls `pokeOracle` or interacts with the pool for T seconds:
  - The EMAs remain frozen at their last values
  - The median queue retains old observations
  - `epoch` in the OraclePack remains at the old value
- **Question**: Can an attacker exploit stale oracle state?
  - Move the Uniswap price significantly while the oracle is stale
  - Then interact with the protocol — the solvency check uses stale oracle ticks that don't reflect the true price
  - The first `pokeOracle` after the gap only moves the oracle by MAX_CLAMP_DELTA — the oracle lags significantly behind reality
- How long a gap creates actionable staleness? (Where the oracle-to-real divergence enables profitable manipulation.)

#### C.2 Epoch Boundary Attacks

- At the epoch boundary (when `block.timestamp >> 6` increments), a new observation can be inserted.
- Can the attacker time their manipulation to straddle the epoch boundary?
  - Block N (epoch X): move price, interact with protocol using stale oracle
  - Block N+1 (epoch X+1): pokeOracle records the manipulated price
- What is the maximum advantage window?

### D) Safe Mode Analysis

#### D.1 Forced Safe Mode

- Can an attacker force safe mode to trigger, causing solvency to be checked at 4 ticks instead of 1?
- If accounts are designed to be solvent at the `spotTick` but barely insolvent at `currentTick` (the Uniswap spot), forcing safe mode creates a new attack surface.
- **Compute**: move `currentTick` by >953 ticks from `spotEMA` → triggers external shock → safe mode. Cost of this move via Uniswap swap.

#### D.2 Safe Mode Prevention

- Can an attacker prevent safe mode from triggering when it should?
- By calling `pokeOracle` frequently with clamped ticks, the EMAs converge toward the manipulated price, potentially keeping `|spotEMA - fastEMA| < 476` even during genuine volatility.

#### D.3 Safe Mode + Liquidation Interaction

- Liquidations do NOT check `MAX_TWAP_DELTA_DISPATCH` — they can proceed regardless of spot/TWAP divergence.
- But if safe mode is active, liquidation solvency is checked at 4 ticks.
- **Scenario**: Attacker triggers safe mode by moving `currentTick`, then liquidates a target that is solvent at 3 of 4 ticks but insolvent at the manipulated `currentTick`. Is this a viable false-liquidation vector?

#### D.4 Guardian lockMode

- `lockSafeMode` (RE:234) sets lockMode, adding +3 to safeMode.
- Only callable by the designated guardian via PanopticPool (PP:306).
- If the guardian is compromised or unresponsive:
  - Compromised: attacker locks safe mode permanently, forcing 4-tick checks → combined with spot manipulation enables false liquidations
  - Unresponsive: genuine emergency cannot be escalated to locked safe mode
- What is the impact of permanent safe mode on normal protocol operations?

### E) Oracle-Solvency Interaction Deep Dive

For each solvency-critical operation, trace exactly which tick(s) determine the outcome:

1. **Mint (dispatch)**: Solvency checked after minting. Which tick(s)? Can the attacker choose a favorable tick by timing?

2. **Burn (dispatch)**: Solvency checked after burning. Which tick(s)? If an account is insolvent but the oracle doesn't reflect it yet, can the account close positions at favorable prices?

3. **Liquidation (dispatchFrom)**: Solvency checked to confirm insolvency. Which tick(s)? The `MAX_TWAP_DELTA_DISPATCH` check does NOT apply. What prevents flash-loan-triggered false liquidations?

4. **Force exercise (dispatchFrom)**: `MAX_TWAP_DELTA_DISPATCH` check DOES apply. What is the effective protection? Can the attacker bypass it by gradually drifting the TWAP?

5. **Withdrawal (CT)**: If `positionIdList` is provided, solvency is checked. Which tick(s)? Same oracle state as other operations?

### F) Comparative Analysis

Compare the oracle's resistance to manipulation against known oracle designs:

- Uniswap V3 TWAP (30-minute window): how much more/less resistant is this oracle to multi-block manipulation?
- Chainlink-style push oracles: what is the effective "heartbeat" of this oracle?
- What is the minimum sustained manipulation duration needed to corrupt each oracle component?

Provide a table:
| Component | Min manipulation duration | Max drift per manipulation | Self-correction time |
|---|---|---|---|
| spotEMA | ? | ? | ? |
| fastEMA | ? | ? | ? |
| slowEMA | ? | ? | ? |
| eonsEMA | ? | ? | ? |
| median (8-slot) | ? | ? | ? |
| twapEMA | ? | ? | ? |

### G) Findings

For each finding:

- ID (ORACLE-NNN)
- Severity (Critical / High / Medium / Low / Informational)
- Category: single-block / multi-block / staleness / safe-mode / solvency
- Required attacker capabilities (flash loan only? Proposer MEV? Sustained capital?)
- Attack duration and cost (in gas, swap fees, capital lockup)
- Concrete impact (false liquidation of $X position, blocking liquidation for Y minutes, etc.)
- Existing mitigations and their effectiveness
- Chain-specific considerations (Ethereum mainnet vs L2s with centralized sequencers)

### H) Recommendations

For each finding:

1. Minimal code change if applicable
2. Parameter adjustment with rationale (e.g., reduce MAX_CLAMP_DELTA, increase EMA periods)
3. Operational recommendations (monitoring, guardian responsiveness requirements)
4. Chain-specific deployment considerations

## Review Rules

- Every manipulation scenario must include concrete tick values and time durations.
- EMA math must be computed explicitly: `newEMA = oldEMA + timeDelta * (newTick - oldEMA) / period`, capped at `3*period/4` for `timeDelta`.
- The 22-bit EMA storage (range [-2^21, 2^21-1] = [-2097152, 2097151]) must be accounted for — is this a constraint?
- The 12-bit residual storage (range [-2048, 2047]) must be accounted for — rebase events at the boundary.
- Do not confuse the internal oracle (OraclePack) with the external Uniswap TWAP (`computeMedianObservedPrice` in PanopticMath.sol:266). They are separate systems.
- State which chain assumptions you're making (12s blocks on mainnet, variable on L2).
- If an attack requires >$1M capital or >10 minutes of sustained manipulation, state this explicitly so the severity can be calibrated.
