// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {RiskEngineV2} from "@contracts/RiskEngine.sol";
import {RiskEngineParameters} from "@types/RiskEngineParameters.sol";

/// @notice Canonical tier parameter sets used by the deployment scripts and the tests. Mirror the production build
/// configs; a change here must be reflected in the configs and vice versa.
library RiskEngineParams {
    /// @dev Blue-chip ("medium") tier as deployed: 90% cross buffers on both sides.
    function blueChip() internal pure returns (RiskEngineParameters memory) {
        return blueChip(9_000_000, 9_000_000);
    }

    /// @dev Blue-chip tier with explicit cross buffers (scaled by DECIMALS).
    function blueChip(
        uint256 crossBuffer0,
        uint256 crossBuffer1
    ) internal pure returns (RiskEngineParameters memory) {
        return
            RiskEngineParameters({
                crossBuffer0: crossBuffer0,
                crossBuffer1: crossBuffer1,
                emaPeriods: uint96(60 + (120 << 24) + (240 << 48) + (960 << 72)),
                maxTicksDelta: 724,
                maxClampDelta: 149,
                maxTwapDeltaDispatch: 513,
                maxSpread: 90_000,
                bpDecreaseBuffer: 10_750_000,
                sellerCollateralRatio: 2_000_000,
                buyerCollateralRatio: 100_000,
                maintMarginRate: 1_000_000,
                loanMarginDivisor: 4,
                forceExerciseCost: 5_000_000,
                targetPoolUtil: 6_666_667,
                saturatedPoolUtil: 9_000_000,
                maxOpenLegs: 26,
                maxBonus: 2_000_000,
                notionalFee: 3,
                premiumFee: 250,
                protocolSplit: 5_000,
                builderSplit: 4_000,
                minRateAtTarget: 0.02 ether / int256(365 days)
            });
    }

    /// @dev xStocks tier: 2/4/8/32 min EMAs, ~10% tick delta (953), 25% maintenance margin, symmetric 75% cross
    /// buffers. Everything else as blue-chip.
    function xStocks() internal pure returns (RiskEngineParameters memory p) {
        return xStocks(7_500_000, 7_500_000);
    }

    /// @dev xStocks tier with explicit cross buffers (scaled by DECIMALS).
    function xStocks(
        uint256 crossBuffer0,
        uint256 crossBuffer1
    ) internal pure returns (RiskEngineParameters memory p) {
        p = blueChip(crossBuffer0, crossBuffer1);
        p.emaPeriods = uint96(120 + (240 << 24) + (480 << 48) + (1920 << 72));
        p.maxTicksDelta = 953;
        p.maintMarginRate = 2_500_000;
    }
}
