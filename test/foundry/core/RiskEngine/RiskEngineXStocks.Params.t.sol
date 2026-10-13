// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RiskEngineV2} from "@contracts/RiskEngine.sol";
import {RiskEngineParameters} from "@types/RiskEngineParameters.sol";
import {RiskEngineParams} from "../../testUtils/RiskEngineParams.sol";

/// @title Tier parameter pins
/// @notice The engine exposes no parameter getters, so this pins the canonical parameter sets that the
///         build configs and tests share, checks that the xStocks set differs from blue-chip exactly on the
///         intended fields, and that both tiers deploy from the single RiskEngineV2 source with the cross
///         buffers landing on the correct token slot.
contract RiskEngineXStocksParamsTest is Test {
    // Symmetric 75% cross buffers: one xStocks engine serves both token orderings.
    uint256 internal constant CROSS_BUFFER_XSTOCKS = 7_500_000;

    function test_xStocksParameterSet() public pure {
        RiskEngineParameters memory p = RiskEngineParams.xStocks();
        assertEq(p.sellerCollateralRatio, 2_000_000, "seller 20%, as blue-chip");
        assertEq(p.buyerCollateralRatio, 100_000, "buyer 1%, as blue-chip");
        assertEq(p.maintMarginRate, 2_500_000, "maint 25%");
        assertEq(p.maxTicksDelta, 953, "max ticks delta ~10%");
        assertEq(p.bpDecreaseBuffer, 10_750_000, "bp decrease buffer, as blue-chip");
        assertEq(
            p.forceExerciseCost,
            5_000_000,
            "force exercise cost: 50% of extrinsic value, as blue-chip"
        );
        assertEq(p.minRateAtTarget, 0.02 ether / int256(365 days), "rate floor 2%, as blue-chip");
        // EMA timescales 2/4/8/32 min
        assertEq(
            p.emaPeriods,
            uint96(120 + (240 << 24) + (480 << 48) + (1920 << 72)),
            "ema 2/4/8/32 min"
        );
    }

    function test_blueChipParameterSet() public pure {
        RiskEngineParameters memory p = RiskEngineParams.blueChip();
        assertEq(p.sellerCollateralRatio, 2_000_000);
        assertEq(p.buyerCollateralRatio, 100_000);
        assertEq(p.maintMarginRate, 1_000_000);
        assertEq(p.maxTicksDelta, 724);
        assertEq(p.bpDecreaseBuffer, 10_750_000);
        assertEq(p.forceExerciseCost, 5_000_000);
        assertEq(p.minRateAtTarget, 0.02 ether / int256(365 days));
        assertEq(p.emaPeriods, uint96(60 + (120 << 24) + (240 << 48) + (960 << 72)));
        assertEq(p.notionalFee, 3);
        assertEq(p.premiumFee, 250);
        assertEq(p.protocolSplit, 5_000);
        assertEq(p.builderSplit, 4_000);
        assertEq(p.maxTwapDeltaDispatch, 513);
        assertEq(p.maxSpread, 90_000);
        assertEq(p.maxOpenLegs, 26);
    }

    /// @notice Everything outside the intended tier fields (cross buffers, EMA periods, maxTicksDelta,
    ///         maintMarginRate) must match between the two sets.
    function test_xStocksDiffersOnlyOnTierFields() public pure {
        RiskEngineParameters memory x = RiskEngineParams.xStocks(10_000_000, 10_000_000);
        RiskEngineParameters memory b = RiskEngineParams.blueChip();
        assertEq(x.maxClampDelta, b.maxClampDelta);
        assertEq(x.maxTwapDeltaDispatch, b.maxTwapDeltaDispatch);
        assertEq(x.maxSpread, b.maxSpread);
        assertEq(x.loanMarginDivisor, b.loanMarginDivisor);
        assertEq(x.targetPoolUtil, b.targetPoolUtil);
        assertEq(x.saturatedPoolUtil, b.saturatedPoolUtil);
        assertEq(x.maxOpenLegs, b.maxOpenLegs);
        assertEq(x.maxBonus, b.maxBonus);
        assertEq(x.forceExerciseCost, b.forceExerciseCost);
        assertEq(x.bpDecreaseBuffer, b.bpDecreaseBuffer);
        assertEq(x.sellerCollateralRatio, b.sellerCollateralRatio);
        assertEq(x.buyerCollateralRatio, b.buyerCollateralRatio);
        assertEq(x.minRateAtTarget, b.minRateAtTarget);
        assertEq(x.notionalFee, b.notionalFee);
        assertEq(x.premiumFee, b.premiumFee);
        assertEq(x.protocolSplit, b.protocolSplit);
        assertEq(x.builderSplit, b.builderSplit);
    }

    function test_deploysFromSingleSource_crossBuffers() public {
        RiskEngineV2 re = new RiskEngineV2(
            address(0),
            address(0),
            bytes32(0),
            RiskEngineParams.xStocks()
        );
        RiskEngineV2 blueChip = new RiskEngineV2(
            address(0),
            address(0),
            bytes32(0),
            RiskEngineParams.blueChip()
        );

        assertEq(re.CROSS_BUFFER_0(), CROSS_BUFFER_XSTOCKS, "symmetric 75% on token0");
        assertEq(re.CROSS_BUFFER_1(), CROSS_BUFFER_XSTOCKS, "symmetric 75% on token1");
        assertEq(blueChip.CROSS_BUFFER_0(), 9_000_000, "blue-chip 90% on token0");
        assertEq(blueChip.CROSS_BUFFER_1(), 9_000_000, "blue-chip 90% on token1");
        assertEq(re.DECIMALS(), blueChip.DECIMALS());
        assertEq(re.vegoid(), blueChip.vegoid());
        assertEq(
            address(re).code.length,
            address(blueChip).code.length,
            "same bytecode, different immutables"
        );
        assertTrue(
            keccak256(address(re).code) != keccak256(address(blueChip).code),
            "immutables differ"
        );
    }
}
