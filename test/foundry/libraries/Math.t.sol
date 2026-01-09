// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {MathHarness} from "./harnesses/MathHarness.sol";
import {Errors} from "@libraries/Errors.sol";
import {Math} from "@libraries/Math.sol";
import {LiquidityChunk, LiquidityChunkLibrary} from "@types/LiquidityChunk.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
import {Tick} from "v3-core/libraries/Tick.sol";
import "forge-std/Test.sol";
import "forge-std/StdError.sol";

/**
 * Test the Core Math library using Foundry and Fuzzing.
 *
 * @author Axicon Labs Limited
 */
contract MathTest is Test {
    MathHarness harness;

    function setUp() public {
        harness = new MathHarness();
    }

    function test_Success_min24_A_LT_B(int24 a, int24 b) public view {
        vm.assume(a < b);
        assertEq(harness.min24(a, b), a);
    }

    function test_Success_min24_A_GE_B(int24 a, int24 b) public view {
        vm.assume(a >= b);
        assertEq(harness.min24(a, b), b);
    }

    function test_Success_max24_A_GT_B(int24 a, int24 b) public view {
        vm.assume(a > b);
        assertEq(harness.max24(a, b), a);
    }

    function test_Success_max24_A_LE_B(int24 a, int24 b) public view {
        vm.assume(a <= b);
        assertEq(harness.max24(a, b), b);
    }

    function test_Success_abs_X_GT_0(int256 x) public view {
        vm.assume(x > 0);
        assertEq(harness.abs(x), x);
    }

    function test_Success_abs_X_LE_0(int256 x) public view {
        vm.assume(x <= 0 && x != type(int256).min);
        assertEq(harness.abs(x), -x);
    }

    function test_Fail_abs_Overflow() public {
        // Should be Panic(0x11), but Foundry decodes panics incorrectly at the top level
        vm.expectRevert();
        harness.abs(type(int256).min);
    }

    function test_Success_toUint128(uint256 toDowncast) public view {
        vm.assume(toDowncast <= type(uint128).max);
        assertEq(harness.toUint128(toDowncast), toDowncast);
    }

    function test_Success_toUint128Capped(uint256 toDowncast) public view {
        vm.assume(toDowncast <= type(uint128).max);
        assertEq(harness.toUint128Capped(toDowncast), toDowncast);
    }

    function test_Success_Cap_toUint128Capped(uint256 toDowncast) public view {
        vm.assume(toDowncast > type(uint128).max);
        assertEq(harness.toUint128Capped(toDowncast), type(uint128).max);
    }

    function test_Fail_toUint128_Overflow(uint256 toDowncast) public {
        vm.assume(toDowncast > type(uint128).max);
        vm.expectRevert(Errors.CastingError.selector);
        harness.toUint128(toDowncast);
    }

    function test_Success_toInt128(uint128 toCast) public view {
        vm.assume(toCast <= uint128(type(int128).max));
        assertEq(uint128(harness.toInt128(toCast)), toCast);
    }

    function test_Fail_toInt128_Overflow(uint128 toCast) public {
        vm.assume(toCast > uint128(type(int128).max));
        vm.expectRevert(Errors.CastingError.selector);
        harness.toInt128(toCast);
    }

    // CASTING
    function test_Success_ToInt256(uint256 x) public {
        if (x > uint256(type(int256).max)) {
            vm.expectRevert(Errors.CastingError.selector);
            harness.toInt256(x);
        } else {
            int256 y = harness.toInt256(x);
            assertEq(y, int256(x));
        }
    }

    function test_Success_ToInt128(int256 x) public {
        if (x > type(int128).max || x < type(int128).min) {
            vm.expectRevert(Errors.CastingError.selector);
            harness.toInt128(x);
        } else {
            int128 y = harness.toInt128(x);
            assertEq(int128(x), y);
        }
    }

    function test_Success_sort(int256[] memory data) public view {
        vm.assume(data.length != 0);
        // Compare against an alternative sorting implementation
        // Bubble sort
        uint256 l = data.length;
        for (uint256 i = 0; i < l; i++) {
            for (uint256 j = i + 1; j < l; j++) {
                if (data[i] > data[j]) {
                    int256 temp = data[i];
                    data[i] = data[j];
                    data[j] = temp;
                }
            }
        }

        assertEq(abi.encodePacked(data), abi.encodePacked(harness.sort(data)));
    }

    function test_Success_mulDiv64(uint96 a, uint96 b) public view {
        uint256 expectedResult = FullMath.mulDiv(a, b, 2 ** 64);
        uint256 returnedResult = harness.mulDiv64(a, b);

        assertEq(expectedResult, returnedResult);
    }

    function test_Fail_mulDiv64() public {
        uint256 input = type(uint256).max;

        vm.expectRevert();
        harness.mulDiv64(input, input);
    }

    function test_Success_mulDiv96(uint96 a, uint96 b) public view {
        uint256 expectedResult = FullMath.mulDiv(a, b, 2 ** 96);
        uint256 returnedResult = harness.mulDiv96(a, b);

        assertEq(expectedResult, returnedResult);
    }

    function test_Fail_mulDiv96() public {
        uint256 input = type(uint256).max;

        vm.expectRevert();
        harness.mulDiv96(input, input);
    }

    function test_Success_mulDiv128(uint128 a, uint128 b) public view {
        uint256 expectedResult = FullMath.mulDiv(a, b, 2 ** 128);
        uint256 returnedResult = harness.mulDiv128(a, b);

        assertEq(expectedResult, returnedResult);
    }

    function test_Fail_mulDiv128() public {
        uint256 input = type(uint256).max;

        vm.expectRevert();
        harness.mulDiv128(input, input);
    }

    function test_Success_mulDiv128RoundingUp(uint128 a, uint128 b) public view {
        uint256 expectedResult = FullMath.mulDivRoundingUp(a, b, 2 ** 128);
        uint256 returnedResult = harness.mulDiv128RoundingUp(a, b);

        assertEq(expectedResult, returnedResult);
    }

    function test_Success_mulDiv192(uint128 a, uint128 b) public view {
        uint256 expectedResult = FullMath.mulDiv(a, b, 2 ** 192);
        uint256 returnedResult = harness.mulDiv192(a, b);

        assertEq(expectedResult, returnedResult);
    }

    function test_success_mulDiv192RoundingUp(uint128 a, uint128 b) public view {
        uint256 expectedResult = FullMath.mulDivRoundingUp(a, b, 2 ** 192);
        uint256 returnedResult = harness.mulDiv192RoundingUp(a, b);

        assertEq(expectedResult, returnedResult);
    }

    function test_Fail_mulDiv192() public {
        uint256 input = type(uint256).max;

        vm.expectRevert();
        harness.mulDiv192(input, input);
    }

    function test_Success_mulDivWad_Simple(uint128 a, uint128 b) public view {
        uint256 expectedResult = FullMath.mulDiv(a, b, 1e18);
        uint256 returnedResult = harness.mulDivWad(a, b);
        assertEq(expectedResult, returnedResult);
    }

    function test_Fail_mulDivWad_Overflow() public {
        uint256 a = 2 ** 128;
        uint256 b = 2 ** 128 * 1_000_000_000_000_000_000;

        vm.expectRevert();
        harness.mulDivWad(a, b);
    }

    function test_Success_mulDivCapped(uint256 a, uint256 b, uint256 c, uint256 power) public view {
        power = bound(power, 0, 255);
        vm.assume(c != 0);

        try harness.mulDiv(a, b, c) returns (uint256 res) {
            assertEq(Math.min(2 ** power - 1, res), Math.mulDivCapped(a, b, c, power));
        } catch {
            console2.log("A");
            assertEq(Math.mulDivCapped(a, b, c, power), 2 ** power - 1);
        }
    }

    function test_Success_unsafeDivRoundingUp(uint256 a, uint256 b) public view {
        uint256 divRes;
        uint256 modRes;
        assembly ("memory-safe") {
            divRes := div(a, b)
            modRes := mod(a, b)
        }
        unchecked {
            assertEq(harness.unsafeDivRoundingUp(a, b), modRes > 0 ? divRes + 1 : divRes);
        }
    }

    function test_Fail_getSqrtRatioAtTick() public {
        int24 x = int24(887273);
        vm.expectRevert();
        harness.getSqrtRatioAtTick(x);
        vm.expectRevert();
        harness.getSqrtRatioAtTick(-x);
    }

    function test_Success_getSqrtRatioAtTick(int24 x) public view {
        x = int24(bound(x, int24(-887271), int24(887271)));
        uint160 uniV3Result = TickMath.getSqrtRatioAtTick(x);
        uint160 returnedResult = harness.getSqrtRatioAtTick(x);
        assertEq(uniV3Result, returnedResult);
    }

    function test_getApproxTickWithMaxAmount(uint256 amount, uint256 ts_seed) public pure {
        int24 ts = int24(int256(bound(ts_seed, 1, 32767)));

        amount = bound(amount, 2_100 * 10 ** 18, 10 ** 26);

        uint128 lMax = Math.getMaxLiquidityPerTick(ts);
        int24 res = Math.getApproxTickWithMaxAmount(amount, ts, lMax);

        assertGt(
            amount,
            Math.getAmount0ForLiquidity(
                LiquidityChunkLibrary.createChunk(res + 2 - ts, res + 2, lMax)
            )
        );
        assertLt(
            amount,
            Math.getAmount0ForLiquidity(
                LiquidityChunkLibrary.createChunk(res - 2 - ts, res - 2, lMax)
            )
        );
    }

    function test_Success_getMaxLiquidityPerTick(int256 x) public pure {
        x = bound(x, 1, 32767);
        console2.log("Math act", Math.getMaxLiquidityPerTick(int24(x)));
        assertEq(
            Tick.tickSpacingToMaxLiquidityPerTick(int24(x)),
            Math.getMaxLiquidityPerTick(int24(x))
        );
    }

    function test_Success_log_Sqrt1p0001MantissaRect(uint256 x) public pure {
        x = bound(x, TickMath.MIN_SQRT_RATIO, 2 ** 96 - 1);

        // abs(max_error) ≈ 1.70234
        assertApproxEqAbs(
            int256(Math.log_Sqrt1p0001MantissaRect(x << 32, 13)),
            -TickMath.getTickAtSqrtRatio(uint160(x)),
            2
        );
    }

    function test_Success_getAmount0ForLiquidity(uint128 a) public view {
        a = uint128(bound(a, uint128(1), uint128(2 ** 128 - 1)));
        uint256 uniV3Result = LiquidityAmounts.getAmount0ForLiquidity(
            TickMath.getSqrtRatioAtTick(int24(-14)),
            TickMath.getSqrtRatioAtTick(int24(10)),
            a
        );

        uint256 returnedResult = harness.getAmount0ForLiquidity(
            LiquidityChunkLibrary.createChunk(int24(-14), int24(10), a)
        );

        assertEq(uniV3Result, returnedResult);
    }

    function test_Success_getAmount1ForLiquidity(uint128 a) public view {
        uint256 uniV3Result = LiquidityAmounts.getAmount1ForLiquidity(
            TickMath.getSqrtRatioAtTick(int24(-14)),
            TickMath.getSqrtRatioAtTick(int24(10)),
            a
        );

        uint256 returnedResult = harness.getAmount1ForLiquidity(
            LiquidityChunkLibrary.createChunk(int24(-14), int24(10), a)
        );

        assertEq(uniV3Result, returnedResult);
    }

    function test_Success_getAmountsForLiquidity(uint128 a) public view {
        (uint256 uniV3Result0, uint256 uniV3Result1) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtRatioAtTick(int24(2)),
            TickMath.getSqrtRatioAtTick(int24(-14)),
            TickMath.getSqrtRatioAtTick(int24(10)),
            a
        );

        (uint256 returnedResult0, uint256 returnedResult1) = harness.getAmountsForLiquidity(
            int24(2),
            LiquidityChunkLibrary.createChunk(int24(-14), int24(10), a)
        );

        assertEq(uniV3Result0, returnedResult0);
        assertEq(uniV3Result1, returnedResult1);
    }

    function test_Success_getLiquidityForAmount0(uint112 a) public view {
        uint256 uniV3Result = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtRatioAtTick(int24(-14)),
            TickMath.getSqrtRatioAtTick(int24(10)),
            a
        );

        uint256 returnedResult = harness
            .getLiquidityForAmount0(int24(-14), int24(10), a)
            .liquidity();

        assertEq(uniV3Result, returnedResult);
    }

    function test_Success_getLiquidityForAmount1(uint112 a) public view {
        uint256 uniV3Result = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtRatioAtTick(int24(-14)),
            TickMath.getSqrtRatioAtTick(int24(10)),
            a
        );

        uint256 returnedResult = harness
            .getLiquidityForAmount1(int24(-14), int24(10), a)
            .liquidity();

        assertEq(uniV3Result, returnedResult);
    }

    function test_wTaylorCompounded_maxLimits() public {
        // Test with very small nx values where approximation should be nearly exact

        ///  MAX_RATE_AT_TARGET = 8.0 ether / int256(365 days) = 253678335870;
        ///  MAX deltaTime per Block = 12s
        uint256 x1 = 253678335870; //
        uint256 n1 = 12; //
        uint256 result1 = Math.wTaylorCompounded(x1, n1);
        uint256 expected1 = 3044144663838; //= (exp(12*253678335870/1e18)-1)*1e18

        // After 1 term, result is exacte
        assertEq(result1, expected1); // 0.0001% tolerance

        // update every block for 1 year

        uint256 borrowIndex = 1e18;
        for (uint256 i; i < (365 * 24 * 3600) / 12; i++) {
            uint256 rawInterest = Math.wTaylorCompounded(x1, n1);
            borrowIndex = Math.mulDivWadRoundingUp(borrowIndex, 1e18 + rawInterest);
        }
        assertLt(borrowIndex, 2980957987505564024832); // in Python: Decimal(1*10**18*(1 + 3044144663838/10**18)**(365*24*3600/12)) = 2980957987505564024832, less than because exponential argument > WAD
        assertEq(borrowIndex, 2980957987023695398473); // this is the actual value

        // update every block until it is larger than 2**80
        uint256 iterations;
        borrowIndex = 1e18;
        while (borrowIndex < 2 ** 80) {
            uint256 rawInterest = Math.wTaylorCompounded(x1, n1);
            borrowIndex = Math.mulDivWadRoundingUp(borrowIndex, 1e18 + rawInterest);
            iterations++;
        }
        assertEq(iterations, 4600723, "Update at every block"); // Overflow after 4600723/365/243600*12 = 1.75years at the max possible rate if the price is updated at every block

        // update every block until it is larger than 2**80
        iterations = 0;
        borrowIndex = 1e18;
        n1 = 12 * 5;
        while (borrowIndex < 2 ** 80) {
            uint256 rawInterest = Math.wTaylorCompounded(x1, n1);
            borrowIndex = Math.mulDivWadRoundingUp(borrowIndex, 1e18 + rawInterest);
            iterations++;
        }
        assertEq(iterations, 920145, "Update every 1min"); // Overflow after 920145/365/24/3600*5*12 = 1.75years at the max possible rate if the price is updated at every block

        // update every block until it is larger than 2**80
        iterations = 0;
        borrowIndex = 1e18;
        n1 = 12 * 5 * 60;
        while (borrowIndex < 2 ** 80) {
            uint256 rawInterest = Math.wTaylorCompounded(x1, n1);
            borrowIndex = Math.mulDivWadRoundingUp(borrowIndex, 1e18 + rawInterest);
            iterations++;
        }
        assertEq(iterations, 15336, "Update every 1h"); // Overflow after = 15336/365/24*3600*5*12*60 = 1.75years at the max possible rate if the price is updated at every block

        // update every block until it is larger than 2**80
        iterations = 0;
        borrowIndex = 1e18;
        n1 = 12 * 5 * 60 * 24;
        while (borrowIndex < 2 ** 80) {
            uint256 rawInterest = Math.wTaylorCompounded(x1, n1);
            borrowIndex = Math.mulDivWadRoundingUp(borrowIndex, 1e18 + rawInterest);
            iterations++;
        }
        assertEq(iterations, 639, "Update every 1d"); // Overflow after 639/365 = 1.75years at the max possible rate if the price is updated at every block

        // update every block until it is larger than 2**80
        iterations = 0;
        borrowIndex = 1e18;
        n1 = 12 * 5 * 60 * 24 * 30;
        while (borrowIndex < 2 ** 80) {
            uint256 rawInterest = Math.wTaylorCompounded(x1, n1);
            borrowIndex = Math.mulDivWadRoundingUp(borrowIndex, 1e18 + rawInterest);
            iterations++;
        }
        assertEq(iterations, 22, "Update every month"); // Overflow after 22/12 = 1.83years at the max possible rate if the price is updated at every block

        // update every block until it is larger than 2**80
        iterations = 0;
        borrowIndex = 1e18;
        n1 = 12 * 5 * 60 * 24 * 30 * 6;
        while (borrowIndex < 2 ** 80) {
            uint256 rawInterest = Math.wTaylorCompounded(x1, n1);
            borrowIndex = Math.mulDivWadRoundingUp(borrowIndex, 1e18 + rawInterest);
            iterations++;
        }
        assertEq(iterations, 5, "Update every 6 months"); // Overflow after 5/12*6 = 2.5years at the max possible rate if the price is updated at every block

        // update every block until it is larger than 2**80
        iterations = 0;
        borrowIndex = 1e18;
        n1 = 12 * 5 * 60 * 24 * 365;
        while (borrowIndex < 2 ** 80) {
            uint256 rawInterest = Math.wTaylorCompounded(x1, n1);
            borrowIndex = Math.mulDivWadRoundingUp(borrowIndex, 1e18 + rawInterest);
            iterations++;
        }
        assertEq(iterations, 3, "Update every year"); // Overflow after 3years at the max possible rate if the price is updated at every block
    }

    function test_wTaylorCompounded_minLimits() public {
        // Test with very small nx values where approximation should be nearly exact

        ///  MIN_RATE_AT_TARGET = 0.001 ether / int256(365 days) = 31709792;
        ///  MAX deltaTime per Block = 12s
        uint256 x1 = 31709792; //
        uint256 n1 = 12; //
        uint256 result1 = Math.wTaylorCompounded(x1, n1);
        uint256 expected1 = 380517504; //= (exp(12*31709792/1e18)-1)*1e18

        // After 1 term, result is exacte
        assertEq(result1, expected1); // 0.0001% tolerance

        // update every block for 1 year

        uint256 borrowIndex = 1e18;
        for (uint256 i; i < (365 * 24 * 3600) / 12; i++) {
            uint256 rawInterest = Math.wTaylorCompounded(x1, n1);
            borrowIndex = Math.mulDivWadRoundingUp(borrowIndex, 1e18 + rawInterest);
        }
        assertGt(borrowIndex, 1001000499881267328); // in Python: Decimal(1*10**18*(1 + 380517504/10**18)**(365*24*3600/12)) = 2980957987505564024832, greater because exponential argument < WAD
        assertEq(borrowIndex, 1001000500168344949); // this is the actual value
    }

    function test_wTaylorCompounded_SmallValues() public {
        // Test with very small nx values where approximation should be nearly exact

        uint256 x1 = 1; //
        uint256 n1 = 1; //
        uint256 result1 = Math.wTaylorCompounded(x1, n1);
        uint256 expected1 = 1; // nx = 1e13, very close to first term

        // For such small values, result should be equal to nx (first term)
        assertEq(result1, expected1); // 0.0001% tolerance

        // Case 2: x = 1000, n = 1 → nx = 0.01
        uint256 x2 = 1e9; // 1e-9 * WAD
        uint256 n2 = 1;
        uint256 result2 = Math.wTaylorCompounded(x2, n2);
        uint256 expected2 = x2; // nx = 1e13

        assertEq(result2, expected2); // 0.0001% tolerance

        // Case 3: Largest value for which output = n*x
        uint256 x3 = 1414213562; // √2 * 1e-9 WAD
        uint256 n3 = 1;
        uint256 result3 = Math.wTaylorCompounded(x3, n3);
        uint256 expected3 = x3; //

        assertEq(result3, expected3); // output = input exactly

        // Case 3: Largest value for which output = n*x
        uint256 x4 = 1414213563; // (√2 * 1e-9 + 1) WAD
        uint256 n4 = 1;
        uint256 result4 = Math.wTaylorCompounded(x4, n4);
        uint256 expected4 = x4 + 1; //

        assertEq(result4, expected4); // output = input + 1
    }

    function test_wTaylorCompounded_LargeValues() public {
        // Test with larger nx values (1.0 - 5.0) to understand degradation

        // Case 1: nx = 1.0
        uint256 x1 = 1e18; // 1.0 * WAD
        uint256 n1 = 1;
        uint256 result1 = Math.wTaylorCompounded(x1, n1);
        // nx=1e18, (nx)²/(2*WAD) = 5e17, (nx)³/(6*WAD²) = 166666666666666666
        uint256 expected1 = 1e18 + 5e17 + 166666666666666666; // 1.666666666666666666 * WAD
        uint256 exact1 = 1718281828459045235;

        assertEq(result1, expected1);
        assertApproxEqRel(result1, exact1, 516e14); // within 0.0516%

        // Case 1: nx = 10
        uint256 x2 = 1e19; // 10 * WAD
        uint256 n2 = 1;
        uint256 result2 = Math.wTaylorCompounded(x2, n2);
        // nx=10, first=10, second=50, third≈166.67
        uint256 expected2 = 10e18 + 50e18 + 166666666666666666666; // 226.666... * WAD
        uint256 exact2 = 22025465794806716516957;

        assertEq(result2, expected2);
        assertApproxEqRel(result2, exact2, 9898e14); // within 98.98%, so pretty bad
    }

    function test_wTaylorCompounded_VeryLargeInputs() public {
        // Test behavior near uint256 limits

        // Case 1: Maximum safe single input (√uint256_max ≈ 2^128)

        uint256 maxVal = 88567974649812873576190202090484573885; // ~2^128
        uint256 x1 = maxVal + 1;
        uint256 n1 = 1;

        vm.expectRevert(stdError.arithmeticError);
        harness.wTaylorCompounded(maxVal + 1, 1);

        // Case 2: At largest possible valuem should work
        uint256 result2 = Math.wTaylorCompounded(maxVal, 1);

        uint256 expectedFirst2 = type(uint256).max;
        assertApproxEqRel(result2, expectedFirst2, 1);
        assertLt(result2, type(uint256).max);
    }

    function testFuzz_wTaylorCompounded_MonotonicInX(uint256 x1, uint256 x2) public {
        // Verify output increases with x when n is fixed

        // Bound inputs to avoid overflow issues
        x1 = bound(x1, 0, 88567974649812873576190202090484573885); // Max safe value from your previous test
        x2 = bound(x2, 0, 88567974649812873576190202090484573885);

        // Ensure x1 ≠ x2 for meaningful comparison
        vm.assume(x1 != x2);

        // Calculate results for both x values with same n
        uint256 result1 = Math.wTaylorCompounded(x1, 1);
        uint256 result2 = Math.wTaylorCompounded(x2, 1);

        // Verify monotonicity: if x1 < x2, then result1 < result2
        if (x1 < x2) {
            assertLt(result1, result2, "Function should be strictly increasing in x");
        } else {
            // x1 > x2 (since we assumed x1 != x2)
            assertGt(result1, result2, "Function should be strictly increasing in x");
        }
    }

    function testFuzz_wTaylorCompounded_MonotonicInN(uint256 x1, uint256 n) public {
        // Verify output increases with n when x is fixed

        // First bound n to reasonable range
        n = bound(n, 1, 1e20); // Much smaller range to avoid extreme cases

        // Then bound x1 based on n to avoid overflow
        uint256 maxSafeX = 88567974649812873576190202090484573885 / (2 * n);

        // Ensure maxSafeX is at least 1, otherwise skip this test case
        vm.assume(maxSafeX >= 1);

        x1 = bound(x1, 1, maxSafeX);

        // Calculate results for both n values with same x
        uint256 result1 = Math.wTaylorCompounded(x1, n);
        uint256 result2 = Math.wTaylorCompounded(x1, n + 1);

        assertLt(result1, result2, "Function should be strictly increasing in n");
    }
}
