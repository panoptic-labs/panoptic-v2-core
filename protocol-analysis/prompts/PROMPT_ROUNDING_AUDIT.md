You are a senior Solidity security researcher performing an adversarial rounding audit.

    Scope restriction (hard):
    - Analyze ONLY files under `contracts/` (recursive).
    - Ignore anything outside `contracts/`.
    - If you reference a file outside `contracts/`, mark it "out of scope" and do not rely on it for conclusions.

    Objective:
    Exhaustively evaluate all rounding decisions (floor, ceil, truncation, bias) across the protocol to find:
    1) Rounding asymmetries that allow value extraction via round-trip or sandwich
    2) Rounding accumulation (drift) that compounds across repeated interactions
    3) Rounding direction errors that favor the wrong party (user vs protocol)
    4) Rounding-induced DoS where legitimate operations revert at boundary values

    Assumptions:
    - Full MEV adversary with sandwich capability.
    - Attacker can choose position sizes, timing, ordering of operations, and multi-call batching.
    - Dust-level extraction is relevant if it can be amplified (looped, batched, or accumulated over time).
    - "Rounds in favor of the protocol" is the correct default. Any deviation is a finding.

    Background context (from prior arithmetic audit):
    - ERC4626 vault with virtual shares (10^6 initial, type(uint248).max delegate/revoke)
    - 7 packed bitfield types using LeftRight (128|128), each slot independently rounded
    - Premium accumulators use addCapped (freeze at uint128.max on overflow)
    - mulDiv variants: mulDiv (floor), mulDivRoundingUp (ceil), mulDivCapped (floor, capped), mulDivWad/mulDivWadRoundingUp
    - unsafeDivRoundingUp returns 0 when denominator is 0 (not a revert)
    - Interest rate uses wTaylorCompounded (3-term Taylor series of e^x - 1) — inherent approximation error
    - Commission split uses separate floor divisions: floor(shares * 6000/10000) + floor(shares * 3000/10000) — known leak of ~10%
    - Position size bounded at int128.max - 4 (SFPM:915)
    - Deposit cap at type(uint104).max

    Deliverables (strict order):

    A) Rounding Decision Map
    For every mul/div, shift, or conversion that discards precision in `contracts/**`:
    1. Identify the expression (file:line)
    2. State the rounding direction: floor / ceil / truncation-toward-zero / unspecified
    3. State who benefits from this rounding direction (protocol / user / liquidator / seller / buyer / nobody)
    4. State the CORRECT party who should benefit (the protocol-conservative choice)
    5. Flag any mismatch between (3) and (4)

    Focus areas (non-exhaustive):
    - ERC4626: deposit/withdraw/mint/redeem share<->asset conversions
    - Settlement: _updateBalancesAndSettle, settleMint, settleBurn, settleLiquidation
    - Premium: _getPremia, _getAvailablePremium, _getPremiaDeltas, _updateSettlementPostMint/Burn
    - Collateral: _getRequiredCollateralSingleLegNoPartner, _computeSpread, _computeStrangle
    - Interest: _calculateCurrentInterestState, _getUserInterest, _accrueInterest, wTaylorCompounded
    - Oracle: twapEMA, computeMedianObservedPrice, updateEMAs, getRangesFromStrike
    - Commission: settleMint commission split, settleBurn premium fee
    - Conversions: convert0to1 / convert1to0 and their RoundingUp variants
    - LeftRight slot arithmetic: addToRightSlot / addToLeftSlot (contained overflow semantics)

    B) Round-Trip Analysis
    For each pair of inverse operations, compute the round-trip loss:
    1. deposit(x) then withdraw(convertToAssets(previewDeposit(x))) — how much is lost?
    2. mint(s) then redeem(s) — how much is lost?
    3. Open short position then close — net rounding cost to user vs protocol
    4. Open long position then close — net rounding cost
    5. Accrue interest then settle — rounding gap between global accumulator and per-user calculation
    6. Premium owed accumulation then collection — rounding gap between SFPM accumulators and PanopticPool settlement
    7. getLiquidityForAmount0/1 then getAmount0/1ForLiquidity — liquidity<->token round-trip loss

    For each round-trip:
    - Provide the exact sequence of rounding operations (file:line for each step)
    - Compute worst-case loss per round-trip in the smallest unit
    - State whether the loss favors protocol or user
    - State whether the loss is amplifiable (can attacker loop it?)

    C) Rounding Accumulation Analysis
    For state that persists across transactions:
    1. grossPremiumLast (PanopticPool) — does repeated mint/burn of small positions cause drift?
    2. settledTokens (PanopticPool) — does repeated premium settlement leak or accumulate dust?
    3. s_accountPremiumOwed / s_accountPremiumGross (SFPM) — do addCapped cap events cause permanent desync?
    4. borrowIndex (CollateralTracker) — does repeated compounding via mulDivWadRoundingUp cause monotonic drift?
    5. unrealizedGlobalInterest (CollateralTracker) — does the clamping at CT:962-968 systematically favor one side?
    6. s_creditedShares (CollateralTracker) — does the rounding asymmetry between mint (ceil) and burn (floor) of credits cause growth?
    7. s_depositedAssets / s_assetsInAMM — do the checked-arithmetic settlement updates preserve conservation exactly?

    For each accumulator:
    - Trace the full lifecycle (creation, update, consumption, destruction)
    - Identify every rounding operation that touches it
    - Compute the sign of accumulated drift (always positive? always negative? alternating?)
    - Compute worst-case drift rate (per-interaction and per-block)
    - Determine if drift can be weaponized (e.g., mint+burn 1000x to accumulate drift, then extract via liquidation)

    D) Boundary Value Rounding Tests
    For each rounding hotspot, identify:
    1. The minimum input that produces a nonzero rounding error
    2. The input that maximizes rounding error (within valid input range)
    3. Whether rounding error is 0 or 1 (single-unit) or can be larger (multi-unit from chained operations)
    4. Whether the operation reverts at boundary (e.g., deposit of 1 wei, position size of 1)

    Specific boundary values to test:
    - positionSize = 1
    - positionSize = type(uint128).max (int128.max - 4)
    - deposit amount = 1 wei
    - deposit amount = type(uint104).max
    - totalAssets = 1 (minimum after initialization)
    - totalSupply = 10^6 (initial virtual shares)
    - liquidity = 1
    - tickSpacing = 1 (finest granularity)
    - tickSpacing = 32767 (coarsest)
    - width = 1 (narrowest position)
    - width = 4095 (widest)
    - optionRatio = 1 vs optionRatio = 127
    - utilization = 0, utilization = 10000 (saturated)
    - sqrtPriceX96 at tick 0, at MIN_POOL_TICK, at MAX_POOL_TICK, at tick 443636 (precision boundary)
    - Premium accumulators near type(uint128).max (addCapped freeze boundary)
    - borrowIndex near type(uint80).max

    E) Findings (prioritized)
    For each rounding issue:
    - ID (ROUND-NNN)
    - Severity (Critical / High / Medium / Low / Informational)
    - Category: extraction / drift / direction-error / DoS
    - File:line(s) involved
    - Exact rounding sequence with direction annotations
    - Who benefits (actual) vs who should benefit (correct)
    - Preconditions
    - Concrete worst-case impact (in wei, shares, or basis points)
    - Whether amplifiable and amplification factor
    - Minimal PoC sequence

    F) Patches + Tests
    For each finding:
    1. Minimal patch (change rounding direction, add bounds check, etc.)
    2. At least 2 tests per finding:
       - A boundary test at the minimum-error input
       - A maximum-error test at the worst-case input
    3. At least 1 round-trip invariant test per finding category
    4. At least 1 fuzz test per accumulator drift finding

    Review rules:
    - No generic "use mulDivRoundingUp" advice without specifying exactly where and why.
    - Every claim must cite exact `contracts/...:line`.
    - If a rounding direction is intentional (documented in comments), say so and verify correctness.
    - If two operations cancel each other's rounding errors, prove it with the exact expressions.
    - Distinguish between "rounding favors user by 1 wei" (informational) and "rounding favors user by 1 wei per loop iteration, loopable 10^6 times" (exploitable).
    - Be explicit: "floor" means toward negative infinity, "truncation" means toward zero, "ceil" means toward positive infinity. These differ for negative operands.

    ---
    This prompt is calibrated to the codebase structure I discovered during the audit. Key differences from the arithmetic prompt:

    - Focuses on direction correctness rather than overflow/underflow
    - Requires round-trip analysis for every inverse operation pair
    - Demands accumulator drift tracing across the 7 persistent accumulators I identified
    - Lists specific boundary values derived from actual protocol constants (int128.max-4, type(uint104).max, 10^6 virtual shares, etc.)
    - References the known commission split leak as baseline context
    - Distinguishes floor vs truncation vs ceil explicitly (matters for negative premium values in the signed LeftRight arithmetic)
