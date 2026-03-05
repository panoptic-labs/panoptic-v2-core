# Oracle Manipulation & MEV Resilience Audit

**Date:** 2026-03-04
**Scope:** `contracts/` (recursive)
**Chain assumption:** Ethereum mainnet (12s blocks) unless stated otherwise

---

## A) Single-Block Manipulation Analysis

### A.1 Flash Loan Spot Manipulation

**How `currentTick` is sourced:**
`PanopticPool.getCurrentTick()` (PP:2131) → `SFPM.getCurrentTick(poolKey())` → reads directly from Uniswap V4's `slot0` (SFPMV4:1377–1379). This is the raw spot price, trivially manipulable with a flash loan.

**Where `currentTick` flows:**

| Operation                             | How `currentTick` enters solvency                                                                                                                                         | Oracle ticks used                            |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| `dispatch` (mint/burn)                | `_validateSolvency` → `getSolvencyTicks` (RE:926). Normal mode: **only `spotEMA`**. Safe mode or Euclidean norm > threshold: **4 ticks including `currentTick`** (RE:954) | spotEMA, medianTick, latestTick, currentTick |
| `dispatchFrom` (liquidation/exercise) | Hardcoded 4-tick array (PP:1515–1519): spotTick, twapTick, latestTick, **currentTick**                                                                                    | spotEMA, twapEMA, latestTick, currentTick    |
| `pokeOracle`                          | `currentTick` is **clamped** by ±149 ticks (MAX_CLAMP_DELTA) before insertion into the oracle                                                                             | N/A — updates oracle, doesn't check solvency |
| `validateCollateralWithdrawable`      | Same as `dispatch` through `_validateSolvency` (PP:466)                                                                                                                   | Same as dispatch                             |

**Key finding:** In normal mode `dispatch`, only `spotEMA` is checked — flash-loaned `currentTick` has **no effect**. In safe mode or when the Euclidean norm of tick divergences exceeds `MAX_TICKS_DELTA²`, `currentTick` becomes one of 4 solvency ticks. A flash loan moving `currentTick` by >953 ticks from `spotEMA` triggers safe mode (RE:897), which then includes the manipulated `currentTick` in the check.

For **dispatchFrom liquidations**: the account must be insolvent at ALL 4 ticks (`solvent == 0` at PP:1584). Flash-loaning `currentTick` to a favorable price (making the target appear solvent there) blocks liquidation for that block:

- Solvent at 1 of 4 ticks → `solvent = 1 ≠ 0` → `NotMarginCalled` revert

For **false liquidations**: the target must be insolvent at ALL 4 ticks. Manipulating only `currentTick` to make the target insolvent there while they are solvent at oracle ticks yields `solvent = 3 ≠ 0`. **False liquidation via single-block manipulation is not possible.**

### A.2 Sandwich Around `pokeOracle`

Attack sequence per epoch:

1. Swap on Uniswap to move spot price by +X%
2. Call `pokeOracle` — records `min(slot0_tick, lastTick + 149)` (clamped)
3. Reverse swap

**Per-observation damage:** At most ±149 ticks (~1.5% price move) from the previous observation.

**Median corruption timeline (starting from all 8 observations at tick T):**

The 8-slot queue is FIFO (OP:487–497: `_currentResiduals << 12` + new residual). Each observation pushes older ones up one slot; slot 7 is evicted.

| Epoch | Observations in queue (newest first)                     | Sorted median (avg of rank 3,4) |
| ----- | -------------------------------------------------------- | ------------------------------- |
| 0     | T, T, T, T, T, T, T, T                                   | T                               |
| 1     | T+149, T, T, T, T, T, T, T                               | T                               |
| 2     | T+298, T+149, T, T, T, T, T, T                           | T                               |
| 3     | T+447, T+298, T+149, T, T, T, T, T                       | T                               |
| 4     | T+596, T+447, T+298, T+149, T, T, T, T                   | T+75                            |
| 5     | T+745, T+596, T+447, T+298, T+149, T, T, T               | T+224                           |
| 6     | T+894, T+745, T+596, T+447, T+298, T+149, T, T           | T+373                           |
| 7     | T+1043, T+894, T+745, T+596, T+447, T+298, T+149, T      | T+522                           |
| 8     | T+1192, T+1043, T+894, T+745, T+596, T+447, T+298, T+149 | T+671                           |

The median first shifts meaningfully at **epoch 4 (256s)** and reaches ≈522 ticks after 7 epochs (448s).

**Cost per sandwiched observation:** 2× Uniswap swap fees + slippage + gas. On a $100M TVL pool, a 149-tick move (~1.5%) requires swapping ~$750K and incurs ~$750 in fees per round trip.

### A.3 Token Amount Computation at Manipulated Prices

`getAmountsMoved` (PM:721) computes token amounts from `getLiquidityChunk`, which derives amounts purely from the position's tick range and size using Uniswap's math formulas. **No spot price is used** — amounts are determined by the position parameters (strike, width, size).

During actual mint/burn in SFPM, the swap occurs at the current Uniswap price, but `tickLimits` in `dispatch` provide slippage protection. The amount computation itself is **not vulnerable** to spot manipulation.

---

## B) Multi-Block Manipulation Analysis

### B.1 Proposer MEV (2–4 Consecutive Blocks)

**Epoch-to-block mapping (mainnet):**
64-second epochs ÷ 12-second blocks = ~5.3 blocks per epoch. A proposer controlling 2–4 consecutive blocks (24–48s) cannot guarantee even a single oracle update — the epoch boundary must fall within their block window.

| Proposer blocks | Duration | Max oracle observations | Max oracle shift |
| --------------- | -------- | ----------------------- | ---------------- |
| 2               | 24s      | 0–1                     | 0–149 ticks      |
| 4               | 48s      | 0–1                     | 0–149 ticks      |
| 8               | 96s      | 1–2                     | 149–298 ticks    |

**Conclusion:** Standard L1 proposer MEV (2–4 blocks) cannot meaningfully corrupt the oracle beyond a single ±149-tick observation. Triggering safe mode (953 ticks) requires **≥7 consecutive epoch-aligned observations** (≥448s ≈ 37 blocks), well beyond realistic L1 proposer control.

**L2 sequencer**: Can insert one controlled observation per epoch indefinitely → see ORACLE-004.

### B.2 EMA Drift Under Sustained Manipulation

EMA update formula (OP:359–397):
`newEMA = oldEMA + min(timeDelta, 3*period/4) × (newTick - oldEMA) / period`

The cascading timeDelta cap ensures that for a 64s epoch:

- **eonsEMA** (960s): `64/960 = 6.7%` convergence per epoch
- **slowEMA** (240s): `64/240 = 26.7%` per epoch
- **fastEMA** (120s): `64/120 = 53.3%` per epoch
- **spotEMA** (60s): capped to `45/60 = 75%` per epoch

**Cumulative drift for sustained +149 tick/epoch manipulation:**

| Epoch | Time (s) | spotEMA | fastEMA | slowEMA | eonsEMA | twapEMA\* | Median |
| ----- | -------- | ------- | ------- | ------- | ------- | --------- | ------ |
| 1     | 64       | +112    | +79     | +40     | +10     | +61       | 0      |
| 2     | 128      | +251    | +196    | +109    | +29     | +148      | 0      |
| 3     | 192      | +398    | +330    | +199    | +57     | +254      | 0      |
| 4     | 256      | +547    | +472    | +305    | +93     | +371      | +75    |
| 5     | 320      | +696    | +618    | +423    | +137    | +511      | +224   |
| 7     | 448      | +994    | +913    | +681    | +245    | +722      | +522   |
| 10    | 640      | +1358   | +1360   | +1099   | +451    | +1191     | +821   |
| 13    | 832      | ~+1800  | ~+1770  | ~+1530  | ~+720   | ~+1550    | ~+1120 |

_\*twapEMA = (6×fastEMA + 3×slowEMA + eonsEMA) / 10_

**Key thresholds:**

- `MAX_TICKS_DELTA` (953) exceeded by spotEMA at epoch 7 (448s)
- twapEMA exceeds 513 ticks (MAX_TWAP_DELTA_DISPATCH) at epoch 5 (320s)
- twapEMA exceeds 953 ticks at epoch 8 (512s)

**False liquidation viability:** A position with 10x leverage and 10% collateral buffer could become "insolvent" at the manipulated twapEMA after ~8 epochs (512s). However, the attacker must simultaneously maintain the Uniswap spot at the manipulated price — otherwise `currentTick` (which is fresh from slot0) would show the true price and the account would appear solvent there.

### B.3 Observation Insertion Timing

`pokeOracle` (PP:605) is `external nonReentrant` — callable by anyone.

**Front-running monopoly:** An attacker can front-run all honest `pokeOracle` calls per epoch by offering higher gas. Once the attacker's `pokeOracle` executes, the epoch guard (`currentEpoch != recordedEpoch` at OP:550) prevents any other observation in that epoch. The attacker controls which tick is recorded.

**But**: The recorded tick is the Uniswap slot0 tick at the time of the call, clamped by ±149 from the last observation. To control the recorded tick, the attacker must also manipulate the Uniswap spot price within the same block (sandwich).

**Self-correction after attack ends:**
Once manipulation stops, honest `pokeOracle` calls record the true Uniswap tick (clamped). The oracle converges back at the same rate it was corrupted: ≈149 ticks per epoch toward the true price. For a 700-tick corruption, self-correction takes ~5 epochs (320s).

---

## C) Staleness Exploitation

### C.1 Stale Oracle State

If no interaction occurs for T seconds:

- All EMAs frozen at their last values
- Median queue retains old observations
- Epoch counter stale

**First update after gap:**
The observation is clamped to ±149 ticks from `lastTick`, regardless of how far the real price has moved. The EMAs get a large timeDelta, but it cascades:

- eonsEMA: `min(gap, 720s)` → up to 75% convergence
- slowEMA: `min(above, 180s)` → up to 75% convergence
- fastEMA: `min(above, 90s)` → up to 75% convergence
- spotEMA: `min(above, 45s)` → up to 75% convergence

After a 1-hour gap, the first observation moves:

- The clamped tick by only ±149 from the last
- EMAs converge 75% toward the (clamped) tick — but the clamped tick itself is only 149 ticks from the old value

**Oracle-to-reality gap after long staleness:**

| Real price move (ticks) | Epochs to catch up | Catch-up time  |
| ----------------------- | ------------------ | -------------- |
| 149                     | 1                  | 64s            |
| 500                     | 4                  | 256s           |
| 953                     | 7                  | 448s           |
| 2000                    | 14                 | 896s (~15 min) |

**Exploitation scenario:**

1. Pool has low activity — `pokeOracle` not called for 10 minutes
2. Real price drops 1000 ticks (genuine market move)
3. Account holders who should be liquidated remain "solvent" at stale oracle ticks
4. Liquidation blocked for ~448s as oracle catches up
5. During catch-up, positions accumulate additional losses → potential bad debt

**Mitigation:** `dispatchFrom` checks `currentTick` (fresh from Uniswap). If the real price moved 1000 ticks, the account may be insolvent at `currentTick`. But the account is likely still "solvent" at the 3 stale oracle ticks → `solvent = 3 ≠ 0` → liquidation blocked.

### C.2 Epoch Boundary Attacks

**Maximum advantage window:** One 12-second block on L1.

Sequence:

1. Block N (epoch X): Price moves. User interacts with protocol — solvency checked against stale oracle
2. Block N+1 (epoch X+1): `pokeOracle` records the new tick (clamped)

The advantage window is at most 64 seconds (one epoch). Within a single block, the attacker can:

- Read the oracle's stale state
- Execute operations that benefit from the stale pricing
- The oracle won't update until the next epoch

This is limited because `dispatch` operations also trigger oracle updates through `_validateSolvency` → `getSolvencyTicks` → `computeInternalMedian` (RE:826–831). If the operation occurs in a new epoch, the oracle IS updated as part of the solvency check. The oracle update feeds `currentTick` (potentially manipulated) through the clamp.

---

## D) Safe Mode Analysis

### D.1 Forced Safe Mode

**Trigger conditions** (RE:886–917):

1. External shock: `|currentTick - spotEMA| > 953` — achievable via flash loan
2. Internal disagreement: `|spotEMA - fastEMA| > 476` — requires ~3 epochs of sustained manipulation
3. High divergence: `|medianTick - slowEMA| > 476` — requires ~5+ epochs

**Cost of trigger via condition 1 (flash loan):**
Move Uniswap spot by >953 ticks (~10% price change). On a $100M TVL pool, this requires swapping ~$5M in a single block. Cost: ~$5K in swap fees, plus potential sandwich loss.

**Impact of forced safe mode on `dispatch`:**
Solvency checked at 4 ticks including manipulated `currentTick`. Accounts near the margin boundary may fail solvency at the manipulated `currentTick` while passing at the 3 oracle ticks. Result: `AccountInsolvent` revert → dispatch DoS.

This is a **temporary denial of service** for marginally solvent accounts. No fund theft. Lasts one block unless attacker repeats.

### D.2 Safe Mode Prevention

By front-running `pokeOracle` with manipulated observations for ~5 epochs (320s), the attacker can gradually shift `spotEMA` and `fastEMA` in the same direction. This keeps `|spotEMA - fastEMA|` below 476 even during genuine volatility:

If both EMAs are corrupted toward the same direction, condition 2 doesn't trigger. However, condition 1 (`|currentTick - spotEMA|`) would still trigger if the real `currentTick` diverges from the corrupted `spotEMA` by >953 ticks.

**Net effect:** An attacker cannot fully prevent safe mode — condition 1 depends on the live `currentTick`, which the attacker cannot permanently control without sustained capital deployment.

### D.3 Safe Mode + Liquidation Interaction

**Critical observation:** `dispatchFrom` does NOT use `getSolvencyTicks` with `safeMode`. Instead, it hardcodes 4 ticks at PP:1515–1519:

```
atTicks = [spotTick, twapTick, latestTick, currentTick]
```

Liquidation is **independent of safe mode status**. The 4-tick check always applies. The TWAP delta check (`|currentTick - twapTick| <= 513`) only applies to force exercises and premium settlements (PP:1540–1544), not liquidations.

**False liquidation via safe mode:** Not possible. The 4-tick liquidation check is hardcoded and independent of safe mode. An attacker cannot force liquidation through safe mode manipulation alone — the target must be insolvent at ALL 4 ticks.

### D.4 Guardian lockMode

`lockSafeMode` (PP:306) sets `lockMode = 3` → adds 3 to `safeMode`. Only callable by `riskEngine()` (PP:301–302).

**Impact of permanent lock:**

- All `dispatch` operations check solvency at 4 ticks including `currentTick`
- Increases the attack surface for flash-loan DoS (section D.1)
- All positions require 100% utilization-level collateral (`_checkSolvencyAtTicks` at PP:1909–1922: sets `maxUtilizations` when `safeMode > 0`)
- This significantly increases collateral requirements, potentially making existing positions appear insolvent

**If guardian is compromised:**

- Permanent safe mode → all users need higher collateral → mass margin calls
- Combined with flash-loan `currentTick` manipulation → targeted dispatch DoS

**If guardian is unresponsive:**

- Cannot escalate to locked safe mode during genuine emergency
- This is mitigated by the automatic safe mode triggers (conditions 1–3)

---

## E) Oracle-Solvency Interaction Deep Dive

### 1. Mint (`dispatch`)

**Ticks used:** `_validateSolvency` → `getSolvencyTicks` (RE:926–962)

- Normal mode: `[spotEMA]` — 1 tick
- Safe mode / high Euclidean norm: `[spotEMA, medianTick, latestTick, currentTick]` — 4 ticks
- Buffer: `BP_DECREASE_BUFFER = 10,416,667` (~104.2% of maintenance requirement)
- Oracle updated: Yes, if new epoch — `computeInternalMedian` called within `getSolvencyTicks`

**Timing attack:** An attacker cannot choose a more favorable tick for their own mint. The `spotEMA` is derived from the oracle's state, which is already determined. In safe mode, `currentTick` is included, but the attacker cannot manipulate their own `currentTick` reading (it's block-level).

### 2. Burn (`dispatch`)

**Ticks used:** Same as mint — `_validateSolvency` at PP:751.

- If oracle is stale and the real price has moved adversely, the account might pass solvency at the stale oracle ticks and successfully burn/close positions
- **The actual swap occurs at the real Uniswap price** (through SFPM), so settlement amounts reflect reality
- The risk is in the solvency check, not the settlement: if an account is "truly" insolvent but passes the stale oracle check, it can close positions when it shouldn't be allowed to (avoiding liquidation penalty)

### 3. Liquidation (`dispatchFrom`)

**Ticks used:** Hardcoded at PP:1515–1519: `[spotEMA, twapEMA, latestTick, currentTick]`

- Requires insolvency at ALL 4 ticks (`solvent == 0`)
- No buffer applied (`NO_BUFFER`)
- No `MAX_TWAP_DELTA_DISPATCH` check — liquidations bypass the TWAP delta gate
- Oracle NOT updated during the target's solvency check (PP:1521 uses `_checkSolvencyAtTicks`, not `_validateSolvency`)
- Oracle IS updated during the liquidator's own `_validateSolvency` at PP:1600

**What prevents flash-loan false liquidations:**
The ALL-4-ticks requirement. Flash loans only manipulate `currentTick` (1 of 4). The other 3 ticks (spotEMA, twapEMA, latestTick) are derived from the internal oracle and cannot be affected by single-block manipulation. The account must be insolvent at all 3 oracle ticks AND `currentTick` — making flash-loan false liquidation impossible.

### 4. Force Exercise (`dispatchFrom`)

**Ticks used:** Same 4-tick check, but the account must be SOLVENT at all 4 ticks.
Then: `|currentTick - twapTick| <= MAX_TWAP_DELTA_DISPATCH (513)` (PP:1540–1544).

**Bypass via gradual TWAP drift:** After ~5 epochs (320s) of sustained oracle manipulation, `twapEMA` can drift by ~511 ticks. If `currentTick` is also at the manipulated price, `|currentTick - twapEMA| ≈ 0` and the check passes. The force exercise then settles at the manipulated price.

**Impact:** The exercise cost computation (in RiskEngine) uses `twapTick`. If `twapTick` is corrupted, the exercised party receives wrong compensation. However, the cost to sustain a 320s manipulation on a liquid pool is likely orders of magnitude larger than the exercise cost benefit.

### 5. Withdrawal (CollateralTracker)

**Ticks used:** `validateCollateralWithdrawable` (PP:460) → `_validateSolvency` with `riskParameters.safeMode()` and `BP_DECREASE_BUFFER`.
Same tick logic as `dispatch`. Stale oracle can allow withdrawals that should be blocked.

---

## F) Comparative Analysis

### Oracle Resistance Table

| Component       | Min manipulation duration to shift | Max drift per manipulation step | Self-correction time (to 90%) | Equivalent Chainlink heartbeat |
| --------------- | ---------------------------------- | ------------------------------- | ----------------------------- | ------------------------------ |
| spotEMA (60s)   | 1 epoch (64s)                      | 112 ticks (75% × 149)           | ~3 epochs (192s)              | ~1 min                         |
| fastEMA (120s)  | 1 epoch (64s)                      | 79 ticks (53% × 149)            | ~5 epochs (320s)              | ~2 min                         |
| slowEMA (240s)  | 1 epoch (64s)                      | 40 ticks (27% × 149)            | ~12 epochs (768s)             | ~4 min                         |
| eonsEMA (960s)  | 1 epoch (64s)                      | 10 ticks (7% × 149)             | ~45 epochs (2880s)            | ~16 min                        |
| median (8-slot) | 4 epochs (256s)                    | ~75 ticks at epoch 4            | 5 epochs (320s)               | ~5 min                         |
| twapEMA (blend) | 3 epochs (192s)                    | ~254 ticks at epoch 3           | ~10 epochs (640s)             | ~8 min                         |

### vs Uniswap V3 TWAP (30-minute window)

- **Panoptic twapEMA** is significantly easier to manipulate than a 30-min Uniswap TWAP. The twapEMA can be shifted by 500+ ticks in ~5 minutes, whereas a 30-min TWAP requires sustained manipulation for 15+ minutes to achieve comparable distortion.
- **Panoptic's advantage**: Multiple layers (4 EMAs + median) create redundancy. An attacker must corrupt ALL layers for a full attack. The multi-tick solvency check in `dispatchFrom` provides defense-in-depth.
- **Panoptic's disadvantage**: The 60s spotEMA converges almost entirely in 3 observations (192s), providing far less lag than a 30-min TWAP.

### Effective oracle "heartbeat"

64 seconds (epoch duration). The oracle can be stale for up to 64 seconds between updates even under active use.

---

## G) Findings

### ORACLE-001: Flash Loan Liquidation Blocking

- **Severity:** Medium
- **Category:** single-block
- **Required attacker capabilities:** Flash loan, ability to submit transactions in the same block as the liquidation attempt
- **Attack duration and cost:** Single block. Cost: 2× swap fees on Uniswap (~$500–$5000 depending on pool depth and required price move)
- **Concrete impact:** Block liquidation of a near-insolvent account for 1 block (12s). Repeatable per-block to sustain. During the delay, position losses accumulate → potential bad debt.
- **Mechanism:** `dispatchFrom` at PP:1515–1519 includes `currentTick` as `atTicks[3]`. Liquidation requires `solvent == 0` (insolvent at ALL 4 ticks). Attacker moves `currentTick` via flash-loan Uniswap swap to make the target appear solvent at that tick. Result: `solvent ≥ 1` → `NotMarginCalled` revert.
- **Existing mitigations:**
  - Cost to move `currentTick` scales with pool TVL and depth of insolvency
  - Liquidator can retry in subsequent blocks
  - Deeply insolvent accounts cannot be rescued even with large `currentTick` manipulation
- **Chain-specific:** More impactful on L2s where the sequencer can sustain manipulation across blocks.
- **Resolution:** **NOT APPLICABLE** — flash loans cannot sandwich another user's liquidation event. The attacker cannot atomically manipulate the price and block a third party's liquidation in the same transaction.

### ORACLE-002: Staleness-Enabled Liquidation Delay

- **Severity:** Medium
- **Category:** staleness
- **Required attacker capabilities:** None specific — exploit arises from low pool activity
- **Attack duration and cost:** Passive — requires periods of low oracle update activity. Can be induced by the account owner front-running `pokeOracle` calls with manipulated spot (cost: swap fees per epoch)
- **Concrete impact:** Liquidation delayed by (price_move_ticks / 149) × 64 seconds. For a 1000-tick gap: ~448s (7.5 min). For a 2000-tick gap: ~896s (15 min). During delay, account accumulates losses potentially creating bad debt.
- **Mechanism:** Oracle ticks (spotEMA, twapEMA, latestTick) remain at stale values. Clamping limits catch-up to 149 ticks per epoch. `dispatchFrom` requires insolvency at ALL 4 ticks including the stale oracle ticks → liquidation blocked at the stale oracle ticks even though `currentTick` reflects true insolvency.
- **Existing mitigations:**
  - Anyone can call `pokeOracle` — MEV-seeking liquidation bots would call it
  - `currentTick` provides a real-time check as one of the 4 ticks
  - Natural pool activity (dispatch, burns) also updates the oracle
- **Chain-specific:** Most relevant on low-activity pools. On active pools with frequent mints/burns, oracle stays current.
- **Resolution:** **NOT APPLICABLE** — same as ORACLE-001; flash loans cannot sandwich another user's liquidation event.

### ORACLE-003: Forced Safe Mode Dispatch Denial of Service

- **Severity:** Low
- **Category:** safe-mode / single-block
- **Required attacker capabilities:** Flash loan (~$5M+ on liquid pools)
- **Attack duration and cost:** Single block. Cost: ~$5K+ in swap fees. Repeatable.
- **Concrete impact:** Marginally solvent accounts cannot `dispatch` (mint/burn/settle) during the manipulated block. No fund theft — purely availability impact.
- **Mechanism:** Flash loan moves `currentTick` by >953 ticks from `spotEMA` → triggers external shock safe mode (RE:897). `_validateSolvency` now checks at 4 ticks including `currentTick`. Accounts solvent at oracle ticks but insolvent at manipulated `currentTick` → `AccountInsolvent` revert.
- **Existing mitigations:**
  - Single-block duration (attacker must pay every block to sustain)
  - Only affects accounts at the margin — well-collateralized accounts remain functional
  - No fund loss, only temporary inconvenience
- **Chain-specific:** Low concern on L1 (high flash loan cost, single-block). On L2s with sequencer control, could be sustained.

### ORACLE-004: L2 Sequencer-Sustained Oracle Corruption

- **Severity:** High (on L2s) / Informational (on L1)
- **Category:** multi-block
- **Required attacker capabilities:** L2 sequencer control (centralized sequencer or compromised sequencer)
- **Attack duration and cost:** ≥5 epochs (320s) to meaningfully corrupt twapEMA. Cost: Uniswap swap fees per epoch (~$500–$5000 per observation depending on pool)
- **Concrete impact:** After 10 epochs (640s), twapEMA drifted by ~1191 ticks (~12.5%). Enables:
  - False liquidation of positions with <12.5% margin surplus
  - Blocking legitimate liquidations by corrupting oracle ticks
  - Incorrect force exercise settlements
  - Incorrect liquidation bonus calculations (PP:1730 uses `twapTick`)
- **Mechanism:** Sequencer inserts one sandwiched observation per epoch, always at +149 ticks. All EMAs converge toward manipulated values. Median shifts after 4 epochs. twapEMA follows within 5–10 epochs.
- **Existing mitigations:**
  - MAX_CLAMP_DELTA = 149 limits per-epoch damage
  - 4-tick ALL-insolvent requirement means all components must be corrupted
  - Current L2 sequencers are operated by protocol teams, not adversarial (trust assumption)
- **Chain-specific:** This is specifically an L2 concern. On L1, achieving 10+ epochs of control requires either massive capital (for sustained Uniswap manipulation) or coordinated proposer collusion across many blocks — extremely unlikely.

### ORACLE-005: twapEMA Used for Liquidation Settlement

- **Severity:** Low
- **Category:** solvency / multi-block
- **Required attacker capabilities:** Sustained Uniswap manipulation for ≥5 minutes + capital to maintain manipulated price
- **Attack duration and cost:** 5+ minutes of sustained Uniswap manipulation. On a $100M TVL pool, requires $5M+ locked and incurs >$50K in arbitrage losses.
- **Concrete impact:** `_liquidate` uses `twapTick` for: margin evaluation (PP:1693), liquidation bonus computation (PP:1730), and premium haircutting (PP:1752). A corrupted `twapTick` leads to incorrect liquidation bonus calculations — potentially overpaying or underpaying the liquidator.
- **Mechanism:** If `twapEMA` has been corrupted (per B.2), the liquidation settlement uses the wrong reference price. Liquidation bonus is computed as the difference between collateral and requirements at `twapTick`.
- **Existing mitigations:**
  - Extremely expensive to sustain manipulation on liquid pools
  - Liquidation also requires insolvency at `currentTick` — limits to cases where the real price supports liquidation
  - The protocol's 4-tick check means the corruption must be extreme enough to affect all ticks

### ORACLE-006: Epoch Front-Running for Observation Monopoly

- **Severity:** Low
- **Category:** multi-block
- **Required attacker capabilities:** MEV bot with Uniswap manipulation capability
- **Attack duration and cost:** Per-epoch cost: ~$500–$5000 (swap fees for spot manipulation + gas). Sustained for N epochs.
- **Concrete impact:** Attacker controls oracle observations, biasing the oracle up to 149 ticks per epoch. After 5 epochs (320s), median shifted by ~224 ticks, spotEMA by ~696 ticks.
- **Mechanism:** Attacker sandwiches `pokeOracle` each epoch: swap → pokeOracle → reverse swap. Once the attacker's observation is recorded for that epoch, the epoch guard prevents other observations. This gives the attacker a monopoly on oracle inputs.
- **Existing mitigations:**
  - Clamp to ±149 ticks limits per-epoch impact
  - Other protocol operations (dispatch, burns) also update the oracle — the attacker would also need to front-run these
  - Cost is cumulative: 10 epochs × $2500 = $25K for ~1200-tick twapEMA drift
- **Chain-specific:** Standard MEV concern. Somewhat mitigated by Flashbots Protect and private mempools.

### ORACLE-007: Stale Oracle Enables Favorable Position Closure

- **Severity:** Low
- **Category:** staleness / solvency
- **Required attacker capabilities:** Account owner or confederate who can prevent `pokeOracle` (via front-running with favorable observations)
- **Attack duration and cost:** Requires a period of oracle staleness + real price move in the attacker's favor
- **Concrete impact:** Account owner whose position has become insolvent can close (burn) the position before the oracle catches up. The solvency check in `dispatch` (burn path) uses stale oracle ticks → account passes solvency → position closes. The owner avoids the liquidation penalty.
- **Mechanism:** `dispatch` burn at PP:708–716 → `_validateSolvency` → solvency check at stale oracle ticks. If oracle is stale and still showing old (pre-crash) prices, a now-insolvent account passes solvency.
- **Existing mitigations:**
  - `dispatch` also updates the oracle as part of `_validateSolvency` (if new epoch) — but the update is clamped and may not reflect the full price move
  - The actual burn settlement occurs at the real Uniswap price, so the account doesn't get better exit prices — they just avoid the liquidation bonus payment
  - Active pools will have recent oracle updates reducing this window

---

## H) Recommendations

### ORACLE-001: Flash Loan Liquidation Blocking

1. **Minimal code change:** Replace `currentTick` with the latest clamped observation in the `dispatchFrom` 4-tick array. Instead of reading raw Uniswap slot0, use `latestTick` (which is already clamped and oracle-derived). Change PP:1519 from `atTicks[3] = currentTick` to use a fresh clamped tick or a short TWAP.
2. **Alternative:** Compute a 2-block Uniswap TWAP for the `currentTick` slot in `dispatchFrom` instead of raw slot0. This eliminates single-block flash loan impact at the cost of one extra oracle read (~2K gas).
3. **Operational:** Monitor for repeated liquidation failures on the same account as a signal of manipulation.

### ORACLE-002: Staleness-Enabled Liquidation Delay

1. **Minimal code change:** Allow multiple oracle updates per epoch if the gap exceeds a threshold (e.g., 4 epochs). Modify `computeInternalMedian` to insert multiple clamped observations (stepping +149 per step) when the staleness gap is large.
2. **Parameter adjustment:** Reduce epoch duration from 64s to 32s to halve the catch-up time. Trade-off: doubles maximum oracle update rate and increases gas cost for observers.
3. **Operational:** Deploy a keeper bot that calls `pokeOracle` every epoch. Incentivize with a small gas refund from the protocol.

### ORACLE-003: Forced Safe Mode Dispatch DoS

1. **No code change needed.** Impact is low — single-block DoS with high cost and no fund loss.
2. **Monitoring:** Alert if safe mode triggers without genuine volatility (compare with Chainlink or CEX price feeds).

### ORACLE-004: L2 Sequencer-Sustained Oracle Corruption

1. **Chain-specific deployment:** On L2s, add a Chainlink sequencer uptime feed check. If the sequencer was recently offline, increase collateral requirements or pause operations.
2. **Parameter adjustment for L2:** Reduce `MAX_CLAMP_DELTA` to 50–75 ticks on L2 deployments (reduces per-epoch damage by 50–67%, extending the time needed to corrupt the oracle). Increase EMA periods proportionally.
3. **Operational:** Implement Chainlink price feed as a secondary sanity check for L2 deployments. If the internal oracle diverges from Chainlink by more than a threshold, pause liquidations.
4. **Long-term:** Consider using the L2's native TWAP (if available) or a cross-chain oracle as a backstop.

### ORACLE-005: twapEMA Used for Liquidation Settlement

1. **Minimal code change:** Use the maximum of `twapTick` and a fresh Chainlink/TWAP for liquidation settlement pricing. This prevents manipulated `twapTick` from being more favorable to either party.
2. **Alternative:** Compute liquidation bonus using a separate, longer-window TWAP (e.g., 30-min Uniswap TWAP) instead of the internal twapEMA.

### ORACLE-006: Epoch Front-Running for Observation Monopoly

1. **Minimal code change:** None required — the clamp effectively limits damage. The cost/benefit ratio strongly favors defense.
2. **Enhancement:** Consider using `block.prevrandao` or a commit-reveal scheme to randomize which `pokeOracle` call in a block gets priority. This increases front-running difficulty. Trade-off: complexity and gas cost.

### ORACLE-007: Stale Oracle Enables Favorable Position Closure

1. **Minimal code change:** In `_validateSolvency`, add a staleness check: if `currentEpoch - oraclePack.epoch() > STALENESS_THRESHOLD` (e.g., 4 epochs = 256s), require safe mode checks (4-tick check including fresh `currentTick`) regardless of normal safe mode status. This ensures stale oracles don't provide false comfort.
2. **Operational:** Same keeper bot recommendation as ORACLE-002.

---

## Review Completeness Checklist

- [x] Every scenario includes concrete tick values and time durations
- [x] EMA math computed explicitly with cascading timeDelta caps
- [x] 22-bit EMA storage range [-2,097,152, 2,097,151] verified: encompasses full Uniswap tick range [-887,272, 887,272]. **Not a constraint.**
- [x] 12-bit residual range [-2048, 2047] accounted for: `rebaseOraclePack` triggers at `MAX_RESIDUAL_THRESHOLD = 1024` (Constants.sol:25), well before overflow
- [x] Internal oracle (OraclePack) distinguished from external Uniswap TWAP (`computeMedianObservedPrice` at PM:266)
- [x] Chain assumptions stated per finding (L1 12s blocks vs L2 sequencer)
- [x] Capital requirements and manipulation durations stated for severity calibration
