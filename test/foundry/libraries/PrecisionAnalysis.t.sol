// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PanopticMath} from "@contracts/libraries/PanopticMath.sol";
import {Math} from "@contracts/libraries/Math.sol";

/// @notice Test contract to analyze precision loss in round-trip conversions
contract PrecisionAnalysisTest is Test {
    // Threshold values
    uint160 constant THRESHOLD = type(uint128).max; // 340282366920938463463374607431768211455

    function testRoundTripPrecisionLowPrice() public pure {
        // Test below threshold (sqrtPriceX96 < type(uint128).max)
        // This uses mulDiv192 path

        uint256 amount = 1e18; // 1 token with 18 decimals
        uint160 sqrtPriceX96 = 2 ** 96; // Price = 1.0

        uint256 converted = PanopticMath.convert0to1(amount, sqrtPriceX96);
        uint256 roundTrip = PanopticMath.convert1to0(converted, sqrtPriceX96);

        console.log("=== Low Price Test (sqrtPriceX96 < type(uint128).max) ===");
        console.log("sqrtPriceX96:", sqrtPriceX96);
        console.log("Original amount:", amount);
        console.log("After round-trip:", roundTrip);
        console.log("Absolute loss:", amount - roundTrip);
        console.log("Relative loss (ppm):", ((amount - roundTrip) * 1e6) / amount);
        console.log("");
    }

    function testRoundTripPrecisionHighPrice() public pure {
        // Test above threshold (sqrtPriceX96 >= type(uint128).max)
        // This uses mulDiv128 + mulDiv64 path

        uint256 amount = 1e18;
        uint160 sqrtPriceX96 = type(uint160).max; // Maximum possible price

        uint256 converted = PanopticMath.convert0to1(amount, sqrtPriceX96);
        uint256 roundTrip = PanopticMath.convert1to0(converted, sqrtPriceX96);

        console.log("=== High Price Test (sqrtPriceX96 >= type(uint128).max) ===");
        console.log("sqrtPriceX96:", sqrtPriceX96);
        console.log("Original amount:", amount);
        console.log("After round-trip:", roundTrip);
        console.log("Absolute loss:", amount - roundTrip);
        if (amount > roundTrip) {
            console.log("Relative loss (ppm):", ((amount - roundTrip) * 1e6) / amount);
        }
        console.log("");
    }

    function testRoundTripAtThreshold() public pure {
        // Test at the exact threshold
        uint256 amount = 1e18;
        uint160 sqrtPriceX96 = THRESHOLD - 1; // Just below threshold

        uint256 converted = PanopticMath.convert0to1(amount, sqrtPriceX96);
        uint256 roundTrip = PanopticMath.convert1to0(converted, sqrtPriceX96);

        console.log("=== At Threshold Test (sqrtPriceX96 = type(uint128).max - 1) ===");
        console.log("sqrtPriceX96:", sqrtPriceX96);
        console.log("Original amount:", amount);
        console.log("After round-trip:", roundTrip);
        console.log("Absolute loss:", amount - roundTrip);
        console.log("Relative loss (ppm):", ((amount - roundTrip) * 1e6) / amount);
        console.log("");

        // Just above threshold
        sqrtPriceX96 = THRESHOLD;
        converted = PanopticMath.convert0to1(amount, sqrtPriceX96);
        roundTrip = PanopticMath.convert1to0(converted, sqrtPriceX96);

        console.log("=== Just Above Threshold Test (sqrtPriceX96 = type(uint128).max) ===");
        console.log("sqrtPriceX96:", sqrtPriceX96);
        console.log("Original amount:", amount);
        console.log("After round-trip:", roundTrip);
        console.log("Absolute loss:", amount - roundTrip);
        if (amount > roundTrip) {
            console.log("Relative loss (ppm):", ((amount - roundTrip) * 1e6) / amount);
        }
        console.log("");
    }

    function testRoundTripVariousAmounts() public pure {
        uint160 sqrtPriceX96 = 2 ** 96; // Price = 1.0

        console.log("=== Various Amounts Test (Price = 1.0) ===");
        console.log("sqrtPriceX96:", sqrtPriceX96);
        console.log("");

        uint256[] memory amounts = new uint256[](8);
        amounts[0] = 1; // 1 wei
        amounts[1] = 1e6; // 1 USDC
        amounts[2] = 1e18; // 1 ETH
        amounts[3] = 1000e18; // 1000 ETH
        amounts[4] = 1e6 * 1e18; // 1M tokens
        amounts[5] = type(uint128).max; // Max uint128
        amounts[6] = type(uint192).max; // Max uint192
        amounts[7] = type(uint256).max; // Max uint256

        for (uint i = 0; i < amounts.length; i++) {
            uint256 amount = amounts[i];
            uint256 converted = PanopticMath.convert0to1(amount, sqrtPriceX96);
            uint256 roundTrip = PanopticMath.convert1to0(converted, sqrtPriceX96);

            console.log("Amount:", amount);
            console.log("  Round-trip:", roundTrip);
            console.log("  Loss:", amount - roundTrip);
            if (amount > 0 && amount > roundTrip) {
                console.log("  Loss (ppm):", ((amount - roundTrip) * 1e6) / amount);
            }
            console.log("");
        }
    }

    function testRoundTripVariousAmountsHighPrice() public pure {
        uint160 sqrtPriceX96 = type(uint160).max; // Maximum price

        console.log("=== Various Amounts Test (Max Price) ===");
        console.log("sqrtPriceX96:", sqrtPriceX96);
        console.log("Note: Very large amounts will overflow at extreme prices");
        console.log("");

        // Test reasonable amounts (very large amounts overflow at max price, which is expected)
        uint256[] memory amounts = new uint256[](6);
        amounts[0] = 1; // 1 wei
        amounts[1] = 1e6; // 1 USDC
        amounts[2] = 1e18; // 1 ETH
        amounts[3] = 1000e18; // 1000 ETH
        amounts[4] = 1e6 * 1e18; // 1M tokens
        amounts[5] = 1e9 * 1e18; // 1B tokens (still safe at max price)

        for (uint i = 0; i < amounts.length; i++) {
            uint256 amount = amounts[i];
            uint256 converted = PanopticMath.convert0to1(amount, sqrtPriceX96);
            uint256 roundTrip = PanopticMath.convert1to0(converted, sqrtPriceX96);

            console.log("Amount:", amount);
            console.log("  Round-trip:", roundTrip);
            console.log("  Loss:", amount > roundTrip ? amount - roundTrip : 0);
            if (amount > 0 && amount > roundTrip) {
                console.log("  Loss (ppm):", ((amount - roundTrip) * 1e6) / amount);
            }
            console.log("");
        }
    }

    function testTheoreticalBounds() public pure {
        console.log("=== Theoretical Bounds Analysis ===");
        console.log("");

        // Case 1: sqrtPriceX96 < type(uint128).max
        // Error bound: 2^192 / sqrtPriceX96^2

        uint160[] memory testPrices = new uint160[](4);
        testPrices[0] = 2 ** 96; // sqrt price at price=1
        testPrices[1] = 2 ** 80; // Lower price
        testPrices[2] = 2 ** 120; // Higher price (still < uint128.max)
        testPrices[3] = type(uint128).max; // At threshold

        for (uint i = 0; i < testPrices.length; i++) {
            uint160 sqrtPrice = testPrices[i];

            if (sqrtPrice < type(uint128).max) {
                // Calculate theoretical error bound: 2^192 / sqrtPrice^2
                uint256 sqrtPriceSquared = uint256(sqrtPrice) * uint256(sqrtPrice);
                uint256 errorBound = (2 ** 192) / sqrtPriceSquared;

                console.log("sqrtPriceX96:", sqrtPrice);
                console.log("  Path: mulDiv192 (Case 1)");
                console.log("  Theoretical max error:", errorBound);
                console.log("  Error as fraction: 1 in", sqrtPriceSquared / (2 ** 192));
            } else {
                // Case 2: High precision path
                uint256 priceReduced = Math.mulDiv64(sqrtPrice, sqrtPrice);
                uint256 errorBound = (2 ** 128) / priceReduced;

                console.log("sqrtPriceX96:", sqrtPrice);
                console.log("  Path: mulDiv128 + mulDiv64 (Case 2)");
                console.log("  Theoretical max error:", errorBound);
            }
            console.log("");
        }
    }
}
