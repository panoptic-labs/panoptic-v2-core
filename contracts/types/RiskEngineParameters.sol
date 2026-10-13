// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Risk parameters chosen per RiskEngine deployment (one source file serves every risk tier).
/// @dev Deployment-time input: the constructor copies each field into a named immutable for the hot path and
/// there are no on-chain getters for them: read a deployment's values from the implementation's verified constructor arguments or the build configs. Reference values for the
/// blue-chip tier are given inline; see the build configs for the xStocks tier.
struct RiskEngineParameters {
    // ---- cross-collateral haircuts, scaled by DECIMALS ----
    uint256 crossBuffer0; // 10_000_000 (100%: token0 balances count in full)
    uint256 crossBuffer1; // 10_000_000
    // ---- oracle / safe mode ----
    uint96 emaPeriods; // 60 + (120 << 24) + (240 << 48) + (960 << 72): 1/2/4/16 min EMAs
    int256 maxTicksDelta; // 724 (~7.5%)
    int24 maxClampDelta; // 149
    uint16 maxTwapDeltaDispatch; // 513
    uint24 maxSpread; // 90_000 bps
    // ---- collateral ----
    uint32 bpDecreaseBuffer; // 10_750_000
    uint256 sellerCollateralRatio; // 2_000_000 (20%)
    uint256 buyerCollateralRatio; // 100_000 (1%)
    uint256 maintMarginRate; // 1_000_000 (10%)
    uint256 loanMarginDivisor; // 4
    uint256 forceExerciseCost; // 5_000_000 (50%)
    uint256 targetPoolUtil; // 6_666_667
    uint256 saturatedPoolUtil; // 9_000_000
    uint256 maxOpenLegs; // 26
    uint256 maxBonus; // 2_000_000
    // ---- fees ----
    uint16 notionalFee; // 3 bps
    uint16 premiumFee; // 250 bps
    uint16 protocolSplit; // 5_000 bps
    uint16 builderSplit; // 4_000 bps
    // ---- interest rate model (per-second, WAD) ----
    int256 minRateAtTarget; // 0.02e18 / 365 days
}
