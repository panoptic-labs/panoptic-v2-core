// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RiskEngine} from "@contracts/RiskEngine.sol";
import {RiskEngineXStocks} from "@contracts/RiskEngineXStocks.sol";

/// @title RiskEngineXStocks parameter pins
/// @notice Asserts the conservative ("xstocks") parameter set differs from the blue-chip
///         `RiskEngine` exactly on the 7 intended parameters, and that the cross-buffer
///         constructor args land on the correct token slot.
contract RiskEngineXStocksParamsTest is Test {
    RiskEngineXStocks internal re;
    RiskEngine internal blueChip;

    // CROSS_BUFFER_0 = token0 (wSPCXx) = 75%, CROSS_BUFFER_1 = token1 (USDC) = 90%
    uint256 internal constant CROSS_BUFFER_TOKEN = 7_500_000;
    uint256 internal constant CROSS_BUFFER_USDC = 9_000_000;

    function setUp() public {
        re = new RiskEngineXStocks(CROSS_BUFFER_TOKEN, CROSS_BUFFER_USDC, address(0), address(0));
        blueChip = new RiskEngine(10_000_000, 10_000_000, address(0), address(0));
    }

    function test_conservativeConstants() public view {
        assertEq(re.SELLER_COLLATERAL_RATIO(), 3_300_000, "seller 33%");
        assertEq(re.BUYER_COLLATERAL_RATIO(), 1_500_000, "buyer 15%");
        assertEq(re.MAINT_MARGIN_RATE(), 2_500_000, "maint 25%");
        assertEq(re.MAX_TICKS_DELTA(), 953, "max ticks delta ~10%");
        // EMA timescales 2/4/8/32 min
        assertEq(
            re.EMA_PERIODS(),
            uint96(120 + (240 << 24) + (480 << 48) + (1920 << 72)),
            "ema 2/4/8/32 min"
        );
    }

    function test_crossBufferTokenOrdering() public view {
        // wSPCXx (0x8e2e..) < USDC (0xA0b8..) => token0 = wSPCXx, token1 = USDC
        assertEq(re.CROSS_BUFFER_0(), CROSS_BUFFER_TOKEN, "token0 = wSPCXx side = 75%");
        assertEq(re.CROSS_BUFFER_1(), CROSS_BUFFER_USDC, "token1 = USDC side = 90%");
    }

    function test_blueChipUnchanged() public view {
        assertEq(blueChip.SELLER_COLLATERAL_RATIO(), 2_000_000);
        assertEq(blueChip.BUYER_COLLATERAL_RATIO(), 1_000_000);
        assertEq(blueChip.MAINT_MARGIN_RATE(), 1_000_000);
        assertEq(blueChip.MAX_TICKS_DELTA(), 724);
        assertEq(blueChip.EMA_PERIODS(), uint96(60 + (120 << 24) + (240 << 48) + (960 << 72)));
    }

    /// @notice Everything outside the 7 intended parameters must match the blue-chip engine.
    function test_nonParameterConstantsMatchBlueChip() public view {
        assertEq(re.DECIMALS(), blueChip.DECIMALS());
        assertEq(re.NOTIONAL_FEE(), blueChip.NOTIONAL_FEE());
        assertEq(re.PREMIUM_FEE(), blueChip.PREMIUM_FEE());
        assertEq(re.MAX_BONUS(), blueChip.MAX_BONUS());
        assertEq(re.SATURATED_POOL_UTIL(), blueChip.SATURATED_POOL_UTIL());
        assertEq(re.TARGET_POOL_UTIL(), blueChip.TARGET_POOL_UTIL());
        assertEq(re.VEGOID(), blueChip.VEGOID());
        assertEq(re.MAX_OPEN_LEGS(), blueChip.MAX_OPEN_LEGS());
    }
}
