// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;
import "forge-std/Test.sol";

// Foundry
// Internal
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {BitMath} from "v3-core/libraries/BitMath.sol";
import {Errors} from "@libraries/Errors.sol";
import {PanopticMathHarness} from "./harnesses/PanopticMathHarness.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {TokenId} from "@types/TokenId.sol";
import {OraclePack, OraclePackLibrary} from "@types/OraclePack.sol";
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {Math} from "@libraries/Math.sol";
import {Constants} from "@libraries/Constants.sol";
// Uniswap
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {FixedPoint96} from "v3-core/libraries/FixedPoint96.sol";
import {FixedPoint128} from "v3-core/libraries/FixedPoint128.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
// Test util
import {PositionUtils} from "../testUtils/PositionUtils.sol";
import {UniPoolPriceMock} from "../testUtils/PriceMocks.sol";
import {UniPoolObservationMock} from "../testUtils/PriceMocks.sol";

import {LiquidityChunk, LiquidityChunkLibrary} from "@types/LiquidityChunk.sol";

/**
 * Test the PanopticMath functionality with Foundry and Fuzzing.
 *
 * @author Axicon Labs Limited
 */
contract PanopticMathTest is Test, PositionUtils {
    using Math for uint256;
    // harness
    PanopticMathHarness harness;

    // store a few different mainnet pairs - the pool used is part of the fuzz
    IUniswapV3Pool constant USDC_WETH_5 =
        IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
    IUniswapV3Pool constant WBTC_ETH_30 =
        IUniswapV3Pool(0xCBCdF9626bC03E24f779434178A73a0B4bad62eD);
    IUniswapV3Pool constant USDC_WETH_30 =
        IUniswapV3Pool(0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8);
    IUniswapV3Pool[3] public pools = [USDC_WETH_5, WBTC_ETH_30, USDC_WETH_30];

    function setUp() public {
        harness = new PanopticMathHarness();
    }

    // Constants for computeInternalMedian tests
    int24 internal constant REFERENCE_TICK = 200000;
    uint256 internal constant INITIAL_EPOCH = 5;

    int24 internal constant MAX_CLAMP_DELTA = 149;

    /*//////////////////////////////////////////////////////////////
                    COMPUTE INTERNAL MEDIAN HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Encodes a set of offsets into the packed oraclePack format for testing.
    function _encodeOraclePack(int16[] memory offsets) internal pure returns (OraclePack) {
        // Assume the input offsets are sorted and create a simple orderMap (0->0, 1->1, etc.)
        uint256 data;
        data |= INITIAL_EPOCH << 232;
        data |= uint256(0xFAC688) << 208; // orderMap for a pre-sorted list
        data |= uint256(uint24(REFERENCE_TICK)) << 96;
        for (uint8 i = 0; i < 8; i++) {
            // Mask with 0xFFF to pack as a 12-bit value
            data |= (uint256(uint16(offsets[i])) & 0x0FFF) << (i * 12);
        }
        return OraclePack.wrap(data);
    }

    /// @notice Decodes the packed data and returns the full tick values IN SORTED ORDER.
    /// This is the key to verifying the orderMap logic is correct.
    function _decodeSortedTicks(OraclePack dataPack) internal view returns (int24[] memory) {
        uint256 data = OraclePack.unwrap(dataPack);
        int24[] memory sortedTicks = new int24[](8);
        int24 refTick = int24(uint24(data >> 96));
        for (uint8 i = 0; i < 8; i++) {
            // i = sorted rank
            uint256 offsetData = (data >> (i * 12)) % 2 ** 12;
            sortedTicks[i] = refTick + harness.int12toInt24(offsetData);
        }
        return sortedTicks;
    }

    /// @notice Generates a standard list of offsets for testing. [0, 10, 20, 30, 40, 50, 60, 70]
    function _generateSortedOffsets(int256 seed) internal pure returns (int16[] memory) {
        int16[] memory offsets = new int16[](8);
        int16 seedStart = seed != 0 ? int16(int256(bound(seed, -1970, 1970))) : int16(0);
        offsets[0] = seedStart;
        offsets[1] = seedStart + 10;
        offsets[2] = seedStart + 20;
        offsets[3] = seedStart + 30;
        offsets[4] = seedStart + 40;
        offsets[5] = seedStart + 50;
        offsets[6] = seedStart + 60;
        offsets[7] = seedStart + 70;
        return offsets;
    }

    // use storage as temp to avoid stack to deeps
    IUniswapV3Pool selectedPool;
    int24 tickSpacing;
    int24 currentTick;

    int24 minTick;
    int24 maxTick;
    int24 lowerBound;
    int24 upperBound;
    int24 strikeOffset;

    function test_Success_getLiquidityChunk_asset0(
        uint256 optionRatioSeed,
        uint16 isLong,
        uint16 tokenType,
        int24 strike,
        int24 width,
        uint64 positionSize
    ) public {
        vm.assume(positionSize != 0);
        TokenId tokenId;

        // contruct a tokenId
        {
            uint16 optionRatio = uint16(bound(optionRatioSeed, 1, 127));

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            isLong = isLong & MASK;
            tokenType = tokenType & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(positionSize, 0, 2)]; // reuse position size as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContextFull(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // Set current tick and pool price
            currentTick = int24(bound(currentTick, minTick, maxTick));

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = TokenId.wrap(uint256(uint24(tickSpacing)) << 48);
            tokenId = tokenId.addLeg(0, optionRatio, 0, isLong, tokenType, 0, strike, width);
        }

        (int24 tickLower, int24 tickUpper) = tokenId.asTicks(0);

        uint160 sqrtPriceBottom = (tokenId.width(0) == 4095)
            ? TickMath.getSqrtRatioAtTick(tokenId.strike(0))
            : TickMath.getSqrtRatioAtTick(tickLower);

        uint256 amount = uint256(positionSize) * tokenId.optionRatio(0);
        uint128 legLiquidity = LiquidityAmounts.getLiquidityForAmount0(
            sqrtPriceBottom,
            TickMath.getSqrtRatioAtTick(tickUpper),
            amount
        );

        LiquidityChunk expectedLiquidityChunk = LiquidityChunkLibrary.createChunk(
            tickLower,
            tickUpper,
            legLiquidity
        );
        LiquidityChunk returnedLiquidityChunk = harness.getLiquidityChunk(tokenId, 0, positionSize);

        assertEq(
            LiquidityChunk.unwrap(expectedLiquidityChunk),
            LiquidityChunk.unwrap(returnedLiquidityChunk)
        );
    }

    function test_Success_getLiquidityChunk_asset1(
        uint256 optionRatioSeed,
        uint16 isLong,
        uint16 tokenType,
        int24 strike,
        int24 width,
        uint64 positionSize
    ) public {
        vm.assume(positionSize != 0);
        TokenId tokenId;

        // contruct a tokenId
        {
            uint256 optionRatio = bound(optionRatioSeed, 1, 127);

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            isLong = isLong & MASK;
            tokenType = tokenType & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(positionSize, 0, 2)]; // reuse position size as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContextFull(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // Set current tick and pool price
            currentTick = int24(bound(currentTick, minTick, maxTick));

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = TokenId.wrap(uint256(uint24(tickSpacing)) << 48);
            tokenId = tokenId.addLeg(0, optionRatio, 1, isLong, tokenType, 0, strike, width);
        }

        (int24 tickLower, int24 tickUpper) = tokenId.asTicks(0);

        uint160 sqrtPriceTop = (tokenId.width(0) == 4095)
            ? TickMath.getSqrtRatioAtTick(tokenId.strike(0))
            : TickMath.getSqrtRatioAtTick(tickUpper);

        uint256 amount = uint256(positionSize) * tokenId.optionRatio(0);
        uint128 legLiquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtRatioAtTick(tickLower),
            sqrtPriceTop,
            amount
        );

        LiquidityChunk expectedLiquidityChunk = LiquidityChunkLibrary.createChunk(
            tickLower,
            tickUpper,
            legLiquidity
        );
        LiquidityChunk returnedLiquidityChunk = harness.getLiquidityChunk(tokenId, 0, positionSize);

        assertEq(
            LiquidityChunk.unwrap(expectedLiquidityChunk),
            LiquidityChunk.unwrap(returnedLiquidityChunk)
        );
    }

    function test_Success_getTicks_normalTickRange(
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 poolSeed
    ) public {
        // bound fuzzed tick
        selectedPool = pools[bound(poolSeed, 0, 2)];
        tickSpacing = selectedPool.tickSpacing();

        // Width must be > 0 < 4096
        int24 width = int24(uint24(bound(widthSeed, 1, 4095)));

        // The position must not extend outside of the max/min tick
        int24 strike = int24(
            bound(
                strikeSeed,
                TickMath.MIN_TICK + (width * tickSpacing) / 2,
                TickMath.MAX_TICK - (width * tickSpacing) / 2
            )
        );

        vm.assume(strike + (((width * tickSpacing) / 2) % tickSpacing) == 0);
        vm.assume(strike - (((width * tickSpacing) / 2) % tickSpacing) == 0);

        // Test the asTicks function
        (int24 tickLower, int24 tickUpper) = harness.getTicks(strike, width, tickSpacing);

        // Ensure tick values returned are correct
        assertEq(tickLower, strike - (width * tickSpacing) / 2);
        assertEq(tickUpper, strike + (width * tickSpacing) / 2);
    }

    function test_Success_computeExercisedAmounts_emptyOldTokenId(
        uint256 optionRatioSeed,
        uint16 isLong,
        uint16 asset,
        uint16 tokenType,
        int24 strike,
        int24 width,
        uint64 positionSize,
        bool opening
    ) public {
        vm.assume(positionSize != 0);
        TokenId tokenId;

        // contruct a tokenId
        {
            uint256 optionRatio = bound(optionRatioSeed, 1, 127);

            vm.assume(positionSize * uint128(optionRatio) < type(uint56).max);

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            isLong = isLong & MASK;
            asset = asset & MASK;
            tokenType = tokenType & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(positionSize, 0, 2)]; // reuse position size as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContextFull(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // Set current tick and pool price
            currentTick = int24(bound(currentTick, minTick, maxTick));

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = TokenId.wrap(uint256(uint24(tickSpacing)) << 48);
            tokenId = tokenId.addLeg(0, optionRatio, asset, isLong, tokenType, 0, strike, width);
        }

        (LeftRightSigned expectedLongs, LeftRightSigned expectedShorts) = harness
            ._calculateIOAmounts(tokenId, positionSize, 0, opening);

        (LeftRightSigned returnedLongs, LeftRightSigned returnedShorts) = harness
            .computeExercisedAmounts(tokenId, positionSize, opening);

        assertEq(LeftRightSigned.unwrap(expectedLongs), LeftRightSigned.unwrap(returnedLongs));
        assertEq(LeftRightSigned.unwrap(expectedShorts), LeftRightSigned.unwrap(returnedShorts));
    }

    function test_Success_numberOfLeadingHexZeros(address addr) public view {
        uint256 expectedData = addr == address(0)
            ? 40
            : 39 - Math.mostSignificantNibble(uint160(addr));
        assertEq(expectedData, harness.numberOfLeadingHexZeros(addr));
    }

    function test_Success_updatePositionsHash_add(
        uint256 optionRatioSeed,
        uint16 isLong,
        uint16 asset,
        uint16 tokenType,
        int24 strike,
        int24 width,
        uint256 existingHash
    ) public {
        TokenId tokenId;

        // contruct a tokenId
        {
            uint256 optionRatio = bound(optionRatioSeed, 1, 127);

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            isLong = isLong & MASK;
            asset = asset & MASK;
            tokenType = tokenType & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(optionRatio, 0, 2)]; // reuse optionRatio as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContextFull(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // Set current tick and pool price
            currentTick = int24(bound(currentTick, minTick, maxTick));

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = TokenId.wrap(uint256(uint24(tickSpacing)) << 48);
            tokenId = tokenId.addLeg(0, optionRatio, asset, isLong, tokenType, 0, strike, width);
        }

        uint248 updatedHash = uint248(
            PanopticMath.homomorphicHash(existingHash, TokenId.unwrap(tokenId), true)
        );
        vm.assume((existingHash >> 248) < 255);
        uint256 expectedHash = uint256(updatedHash) + (((existingHash >> 248) + 1) << 248);

        uint256 returnedHash = harness.updatePositionsHash(existingHash, tokenId, true);

        assertEq(expectedHash, returnedHash);
    }

    function test_Success_updatePositionsHash_update(
        uint256 optionRatioSeed,
        uint16 isLong,
        uint16 asset,
        uint16 tokenType,
        int24 strike,
        int24 width,
        uint256 existingHash
    ) public {
        TokenId tokenId;

        // contruct a tokenId
        {
            uint256 optionRatio = bound(optionRatioSeed, 1, 127);

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            isLong = isLong & MASK;
            asset = asset & MASK;
            tokenType = tokenType & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(optionRatio, 0, 2)]; // reuse optionRatio as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContextFull(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // Set current tick and pool price
            currentTick = int24(bound(currentTick, minTick, maxTick));

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = TokenId.wrap(uint256(uint24(tickSpacing)) << 48);
            tokenId = tokenId.addLeg(0, optionRatio, asset, isLong, tokenType, 0, strike, width);
        }

        uint256 expectedHash;
        uint256 returnedHash;
        unchecked {
            uint248 updatedHash = uint248(
                PanopticMath.homomorphicHash(existingHash, TokenId.unwrap(tokenId), false)
            );
            vm.assume((existingHash >> 248) > 0);

            expectedHash = uint256(updatedHash) + (((existingHash >> 248) - 1) << 248);

            returnedHash = harness.updatePositionsHash(existingHash, tokenId, false);
        }

        assertEq(expectedHash, returnedHash);
    }

    function test_Success_getLastMedianObservation(
        uint256 observationIndex,
        int256[100] memory ticks,
        uint256[100] memory timestamps,
        uint256 observationCardinality,
        uint256 cardinality,
        uint256 period
    ) public {
        // skip because out of gas
        vm.skip(true);
        cardinality = bound(cardinality, 1, 50);
        cardinality = cardinality * 2 - 1;
        period = bound(period, 1, 100 / cardinality);
        observationCardinality = bound(observationCardinality, cardinality * period + 1, 65535);
        UniPoolObservationMock mockPool = new UniPoolObservationMock(observationCardinality);
        observationIndex = bound(observationIndex, 0, observationCardinality - 1);
        int56 tickCum;
        for (uint256 i = 0; i < cardinality + 1; ++i) {
            ticks[i] = int24(bound(ticks[i], type(int24).min, type(int24).max));
            if (i == 0) {
                timestamps[i] = bound(timestamps[i], 0, type(uint32).max - (cardinality - i));

                // assume tickCum will not overflow
                vm.assume(tickCum + ticks[i] * int256(timestamps[i]) < type(int56).max);

                tickCum += int56(ticks[i] * int256(timestamps[i]));
            } else {
                timestamps[i] = bound(
                    timestamps[i],
                    timestamps[i - 1] + 1,
                    type(uint32).max - (cardinality - i)
                );

                // assume tickCum will not overflow
                vm.assume(tickCum + ticks[i] * int256(timestamps[i]) < type(int56).max);

                tickCum += int56(ticks[i] * int256(timestamps[i] - timestamps[i - 1]));
            }

            mockPool.setObservation(
                uint256(
                    (int256(uint256(observationIndex)) -
                        (int256(cardinality) - int256(i)) *
                        int256(period)) + int256(uint256(observationCardinality))
                ) % observationCardinality,
                uint32(timestamps[i]),
                tickCum
            );
        }

        // use bubble sort to get the median tick
        // note: the 4th tick is not actually deconstructed anywhere, but it is used as the base accumulator value.
        int256[] memory sortedTicks = new int256[](cardinality);
        for (uint16 i = 0; i < cardinality; ++i) {
            sortedTicks[i] = ticks[i + 1];
        }
        sortedTicks = Math.sort(sortedTicks);
        for (uint16 i = 0; i < cardinality; ++i) {
            console2.log(
                "sortedTicks["
                "]: ",
                sortedTicks[i]
            );
        }
        assertEq(
            harness.computeMedianObservedPrice(
                IUniswapV3Pool(address(mockPool)),
                observationIndex,
                observationCardinality,
                cardinality,
                period
            ),
            sortedTicks[sortedTicks.length / 2]
        );
    }

    function test_Success_twapFilter(uint32 twapWindow) public {
        twapWindow = uint32(bound(twapWindow, 100, 10000));

        selectedPool = pools[bound(twapWindow, 0, 2)]; // reuse twapWindow as seed

        uint32[] memory secondsAgos = new uint32[](20);
        int256[] memory twapMeasurement = new int256[](19);

        for (uint32 i = 0; i < 20; ++i) {
            secondsAgos[i] = ((i + 1) * twapWindow) / uint32(20);
        }

        (int56[] memory tickCumulatives, ) = selectedPool.observe(secondsAgos);

        // compute the average tick per 30s window
        for (uint32 i = 0; i < 19; ++i) {
            twapMeasurement[i] =
                (tickCumulatives[i] - tickCumulatives[i + 1]) /
                int56(uint56(twapWindow / 20));
        }

        // sort the tick measurements
        int256[] memory sortedTicks = Math.sort(twapMeasurement);

        // Get the median value
        int256 twapTick = sortedTicks[9];

        assertEq(twapTick, harness.twapFilter(selectedPool, twapWindow));
    }

    function test_Success_convert0to1_PriceX192_Uint(
        uint256 amount,
        uint256 sqrtPriceSeed
    ) public view {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, type(uint128).max - 1)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(priceX192, amount, type(uint256).max);
            uint256 prod0 = priceX192 * amount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < 2 ** 192);
        }

        assertEq(
            harness.convert0to1(amount, sqrtPrice),
            FullMath.mulDiv(amount, priceX192, 2 ** 192)
        );
    }

    function test_Fail_convert0to1_PriceX192_Uint_overflow(
        uint256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, type(uint128).max - 1)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        // make sure the final result does overflow
        unchecked {
            uint256 mm = mulmod(priceX192, amount, type(uint256).max);
            uint256 prod0 = priceX192 * amount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) >= 2 ** 192);
        }

        vm.expectRevert();
        harness.convert0to1(amount, sqrtPrice);
    }

    function test_Success_convert0to1RoundingUp_PriceX192_Uint(
        uint256 amount,
        uint256 sqrtPriceSeed
    ) public view {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, type(uint128).max - 1)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(priceX192, amount, type(uint256).max);
            uint256 prod0 = priceX192 * amount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < 2 ** 192);
            uint256 nr_res = FullMath.mulDiv(amount, priceX192, 2 ** 192);
            vm.assume(nr_res < type(uint256).max || mulmod(amount, priceX192, 2 ** 192) == 0);
        }

        assertEq(
            harness.convert0to1RoundingUp(amount, sqrtPrice),
            FullMath.mulDivRoundingUp(amount, priceX192, 2 ** 192)
        );
    }

    function test_Fail_convert0to1RoundingUp_PriceX192_Uint_overflow(
        uint256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, type(uint128).max - 1)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        // make sure the final result does overflow
        unchecked {
            uint256 mm = mulmod(priceX192, amount, type(uint256).max);
            uint256 prod0 = priceX192 * amount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) >= 2 ** 192);
        }

        vm.expectRevert();
        harness.convert0to1RoundingUp(amount, sqrtPrice);
    }

    function test_Success_convert0to1_PriceX192_Int(
        int256 amount,
        uint256 sqrtPriceSeed
    ) public view {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, type(uint128).max - 1)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(priceX192, absAmount, type(uint256).max);
            uint256 prod0 = priceX192 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < 2 ** 192);
        }
        vm.assume(FullMath.mulDiv(absAmount, priceX192, 2 ** 192) <= uint256(type(int256).max));
        assertEq(
            harness.convert0to1(amount, sqrtPrice),
            (amount < 0 ? -1 : int(1)) * int(FullMath.mulDiv(absAmount, priceX192, 2 ** 192))
        );
    }

    function test_Fail_convert0to1_PriceX192_Int_overflow(
        int256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, type(uint128).max - 1)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does overflow
        unchecked {
            uint256 mm = mulmod(priceX192, absAmount, type(uint256).max);
            uint256 prod0 = priceX192 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) >= 2 ** 192);
        }

        vm.expectRevert();
        harness.convert0to1(amount, sqrtPrice);
    }

    function test_Fail_convert0to1_PriceX192_Int_CastingError(
        int256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, type(uint128).max - 1)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does overflow
        unchecked {
            uint256 mm = mulmod(priceX192, absAmount, type(uint256).max);
            uint256 prod0 = priceX192 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < 2 ** 192);
        }

        vm.assume(FullMath.mulDiv(absAmount, priceX192, 2 ** 192) > uint256(type(int256).max));
        vm.expectRevert(Errors.CastingError.selector);
        harness.convert0to1(amount, sqrtPrice);
    }

    function test_Success_convert1to0_PriceX192_Uint(
        uint256 amount,
        uint256 sqrtPriceSeed
    ) public view {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, type(uint128).max - 1)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(amount, 2 ** 192, type(uint256).max);
            uint256 prod0 = 2 ** 192 * amount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < priceX192);
        }

        assertEq(
            harness.convert1to0(amount, sqrtPrice),
            FullMath.mulDiv(amount, 2 ** 192, priceX192)
        );
    }

    function test_Fail_convert1to0_PriceX192_Uint_overflow(
        uint256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, type(uint128).max - 1)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        // make sure the final result does overflow
        unchecked {
            uint256 mm = mulmod(amount, 2 ** 192, type(uint256).max);
            uint256 prod0 = 2 ** 192 * amount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) >= priceX192);
        }

        vm.expectRevert();
        harness.convert1to0(amount, sqrtPrice);
    }

    function test_Success_convert1to0RoundingUp_PriceX192_Uint(
        uint256 amount,
        uint256 sqrtPriceSeed
    ) public view {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, type(uint128).max - 1)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(amount, 2 ** 192, type(uint256).max);
            uint256 prod0 = 2 ** 192 * amount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < priceX192);
            uint256 nr_res = FullMath.mulDiv(amount, 2 ** 192, priceX192);
            vm.assume(nr_res < type(uint256).max || mulmod(amount, 2 ** 192, priceX192) == 0);
        }

        assertEq(
            harness.convert1to0RoundingUp(amount, sqrtPrice),
            FullMath.mulDivRoundingUp(amount, 2 ** 192, priceX192)
        );
    }

    function test_Fail_convert1to0RoundingUp_PriceX192_Uint_overflow(
        uint256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, type(uint128).max - 1)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        // make sure the final result does overflow
        unchecked {
            uint256 mm = mulmod(amount, 2 ** 192, type(uint256).max);
            uint256 prod0 = 2 ** 192 * amount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) >= priceX192);
        }

        vm.expectRevert();
        harness.convert1to0RoundingUp(amount, sqrtPrice);
    }

    function test_Success_convert1to0_PriceX192_Int(
        int256 amount,
        uint256 sqrtPriceSeed
    ) public view {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, type(uint128).max - 1)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(absAmount, 2 ** 192, type(uint256).max);
            uint256 prod0 = 2 ** 192 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < priceX192);
        }

        vm.assume(FullMath.mulDiv(absAmount, 2 ** 192, priceX192) <= uint256(type(int256).max));
        assertEq(
            harness.convert1to0(amount, sqrtPrice),
            (amount < 0 ? -1 : int(1)) * int(FullMath.mulDiv(absAmount, 2 ** 192, priceX192))
        );
    }

    function test_Fail_convert1to0_PriceX192_Int_overflow(
        int256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, type(uint128).max - 1)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(2 ** 192, absAmount, type(uint256).max);
            uint256 prod0 = 2 ** 192 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) >= priceX192);
        }

        vm.expectRevert();
        harness.convert1to0(amount, sqrtPrice);
    }

    function test_Fail_convert1to0_PriceX192_Int_CastingError(
        int256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, TickMath.MIN_SQRT_RATIO, type(uint128).max - 1)
        );

        uint256 priceX192 = uint256(sqrtPrice) ** 2;

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(2 ** 192, absAmount, type(uint256).max);
            uint256 prod0 = 2 ** 192 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < priceX192);
        }

        vm.assume(FullMath.mulDiv(absAmount, 2 ** 192, priceX192) > uint256(type(int256).max));
        vm.expectRevert(Errors.CastingError.selector);
        harness.convert1to0(amount, sqrtPrice);
    }

    function test_Success_convert0to1_PriceX128_Uint(
        uint256 amount,
        uint256 sqrtPriceSeed
    ) public view {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, type(uint128).max, TickMath.MAX_SQRT_RATIO)
        );

        uint256 priceX128 = FullMath.mulDiv(sqrtPrice, sqrtPrice, 2 ** 64);

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(priceX128, amount, type(uint256).max);
            uint256 prod0 = priceX128 * amount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < 2 ** 128);
        }

        assertEq(
            harness.convert0to1(amount, sqrtPrice),
            FullMath.mulDiv(amount, priceX128, 2 ** 128)
        );
    }

    function test_Fail_convert0to1_PriceX128_Uint_overflow(
        uint256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, type(uint128).max, TickMath.MAX_SQRT_RATIO)
        );

        uint256 priceX128 = FullMath.mulDiv(sqrtPrice, sqrtPrice, 2 ** 64);

        // make sure the final result does overflow
        unchecked {
            uint256 mm = mulmod(priceX128, amount, type(uint256).max);
            uint256 prod0 = priceX128 * amount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) >= 2 ** 128);
        }

        vm.expectRevert();
        harness.convert0to1(amount, sqrtPrice);
    }

    function test_Success_convert0to1_PriceX128_Int(
        int256 amount,
        uint256 sqrtPriceSeed
    ) public view {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, type(uint128).max, TickMath.MAX_SQRT_RATIO)
        );

        uint256 priceX128 = FullMath.mulDiv(sqrtPrice, sqrtPrice, 2 ** 64);

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(priceX128, absAmount, type(uint256).max);
            uint256 prod0 = priceX128 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < 2 ** 128);
        }

        vm.assume(FullMath.mulDiv(absAmount, priceX128, 2 ** 128) <= uint256(type(int256).max));
        assertEq(
            harness.convert0to1(amount, sqrtPrice),
            (amount < 0 ? -1 : int(1)) * int(FullMath.mulDiv(absAmount, priceX128, 2 ** 128))
        );
    }

    function test_Fail_convert0to1_PriceX128_Int_overflow(
        int256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, type(uint128).max, TickMath.MAX_SQRT_RATIO)
        );

        uint256 priceX128 = FullMath.mulDiv(sqrtPrice, sqrtPrice, 2 ** 64);

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does overflow
        unchecked {
            uint256 mm = mulmod(priceX128, absAmount, type(uint256).max);
            uint256 prod0 = priceX128 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) >= 2 ** 128);
        }

        vm.expectRevert();
        harness.convert0to1(amount, sqrtPrice);
    }

    function test_Fail_convert0to1_PriceX128_Int_CastingError(
        int256 amount,
        uint256 sqrtPriceSeed
    ) public {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, type(uint128).max, TickMath.MAX_SQRT_RATIO)
        );

        uint256 priceX128 = FullMath.mulDiv(sqrtPrice, sqrtPrice, 2 ** 64);

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does overflow
        unchecked {
            uint256 mm = mulmod(priceX128, absAmount, type(uint256).max);
            uint256 prod0 = priceX128 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < 2 ** 128);
        }

        vm.assume(FullMath.mulDiv(absAmount, priceX128, 2 ** 128) > uint256(type(int256).max));
        vm.expectRevert(Errors.CastingError.selector);
        harness.convert0to1(amount, sqrtPrice);
    }

    function test_Success_convert1to0_PriceX128_Uint(
        uint256 amount,
        uint256 sqrtPriceSeed
    ) public view {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, type(uint128).max, TickMath.MAX_SQRT_RATIO)
        );

        uint256 priceX128 = FullMath.mulDiv(sqrtPrice, sqrtPrice, 2 ** 64);

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(2 ** 128, amount, type(uint256).max);
            uint256 prod0 = 2 ** 128 * amount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < priceX128);
        }

        assertEq(
            harness.convert1to0(amount, sqrtPrice),
            FullMath.mulDiv(amount, 2 ** 128, priceX128)
        );
    }

    function test_Success_convert1to0_PriceX128_Int(
        int256 amount,
        uint256 sqrtPriceSeed
    ) public view {
        // above this tick we use 128-bit precision because of overflow issues
        uint160 sqrtPrice = uint160(
            bound(sqrtPriceSeed, type(uint128).max, TickMath.MAX_SQRT_RATIO)
        );

        uint256 priceX128 = FullMath.mulDiv(sqrtPrice, sqrtPrice, 2 ** 64);

        uint256 absAmount = Math.absUint(amount);

        // make sure the final result does not overflow
        unchecked {
            uint256 mm = mulmod(2 ** 128, absAmount, type(uint256).max);
            uint256 prod0 = 2 ** 128 * absAmount;
            vm.assume((mm - prod0) - (mm < prod0 ? 1 : 0) < priceX128);
        }

        vm.assume(FullMath.mulDiv(absAmount, 2 ** 128, priceX128) <= uint256(type(int256).max));
        assertEq(
            harness.convert1to0(amount, sqrtPrice),
            (amount < 0 ? -1 : int(1)) * int(FullMath.mulDiv(absAmount, 2 ** 128, priceX128))
        );
    }

    function _test_Fuzz_getAmountsMoved0_legacy(
        uint256 optionRatioSeed,
        uint16 isLong,
        uint16 tokenType,
        int24 strike,
        int24 width,
        uint128 positionSize,
        bool opening
    ) public {
        // contruct a tokenId
        {
            $optionRatio = bound(optionRatioSeed, 1, 127);

            // the following are all 1 bit so mask them:
            $MASK = 0x1; // takes first 1 bit of the uint16
            isLong = isLong & $MASK;
            tokenType = tokenType & $MASK;

            // bound fuzzed tick
            selectedPool = pools[bound($optionRatio, 0, 2)]; // reuse optionRatio as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));

            int24 rangeDown;
            int24 rangeUp;
            (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(tickSpacing));

            (, currentTick, , , , , ) = selectedPool.slot0();

            lowerBound = int24(-887272 + rangeDown);
            upperBound = int24(887272 - rangeUp);

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing);

            $tokenId = TokenId.wrap(uint256(uint24(tickSpacing)) << 48);
            $tokenId = $tokenId.addLeg(0, $optionRatio, 0, isLong, tokenType, 0, strike, width);
            console2.log("strike", strike);
        }
        $tokenId.validate();

        // get the tick range for this leg in order to get the strike price (the underlying price)
        ($tickLower, $tickUpper) = $tokenId.asTicks(0);

        positionSize = uint128(
            bound(positionSize, 0, positionSize / uint128($tokenId.optionRatio(0)))
        );
        vm.assume(positionSize != 0);

        // set amount 0 - LEGACY
        uint256 amount0 = positionSize * uint128($tokenId.optionRatio(0));

        uint256 amount1 = Math.mulDivRoundingUp(
            uint256(amount0),
            Math.mulDiv(
                Math.getSqrtRatioAtTick($tickLower),
                Math.getSqrtRatioAtTick($tickUpper),
                2 ** 96
            ),
            2 ** 96
        );
        vm.assume(amount0 < type(uint128).max);
        vm.assume(amount1 < type(uint128).max);
        LeftRightUnsigned legacyContractsNotional = LeftRightUnsigned
            .wrap(0)
            .addToRightSlot(amount0.toUint128())
            .addToLeftSlot(amount1.toUint128());

        // set amount0 - UNISWAP MATH
        $contracts = positionSize * $tokenId.optionRatio(0);

        uint160 lowPriceX96 = Math.getSqrtRatioAtTick($tickLower);
        uint160 highPriceX96 = Math.getSqrtRatioAtTick($tickUpper);

        uint256 liquidity = Math.mulDiv(
            $contracts,
            Math.mulDiv96(highPriceX96, lowPriceX96),
            highPriceX96 - lowPriceX96
        );

        if (isLong == 0) {
            amount0 = Math.mulDivRoundingUp(
                Math.mulDivRoundingUp(
                    uint256(liquidity) << 96,
                    highPriceX96 - lowPriceX96,
                    highPriceX96
                ),
                1,
                lowPriceX96
            );

            amount1 = Math.mulDiv96RoundingUp(liquidity, highPriceX96 - lowPriceX96);
        } else {
            amount0 = Math.mulDiv(
                Math.mulDiv(uint256(liquidity) << 96, highPriceX96 - lowPriceX96, highPriceX96),
                1,
                lowPriceX96
            );

            amount1 = Math.mulDiv96(liquidity, highPriceX96 - lowPriceX96);
        }
        vm.assume(amount0 < type(uint128).max);
        vm.assume(amount1 < type(uint128).max);
        LeftRightUnsigned expectedContractsNotional = LeftRightUnsigned
            .wrap(0)
            .addToRightSlot(amount0.toUint128())
            .addToLeftSlot(amount1.toUint128());

        // set amount0 - PANOPTIC MATH
        LeftRightUnsigned returnedContractsNotional = harness.getAmountsMoved(
            $tokenId,
            positionSize,
            0,
            opening
        );
        assertEq(
            expectedContractsNotional.rightSlot(),
            returnedContractsNotional.rightSlot(),
            "CORRECT: amount 0 not equal"
        );
        assertEq(
            expectedContractsNotional.leftSlot(),
            returnedContractsNotional.leftSlot(),
            "CORRECT: amount 1 not equal"
        );

        if (amount0 != $contracts) {
            assertGe(
                legacyContractsNotional.rightSlot(),
                returnedContractsNotional.rightSlot(),
                "LEGACY: amount 0 not equal"
            );
            if (legacyContractsNotional.leftSlot() > 0) {
                assertGe(
                    legacyContractsNotional.leftSlot(),
                    returnedContractsNotional.leftSlot(),
                    "LEGACY: amount 1 not equal"
                );
            }
        }
    }

    uint256 $optionRatio;
    uint8 $MASK;
    TokenId $tokenId;
    int24 $tickLower;
    int24 $tickUpper;
    uint256 $contracts;

    // skip
    function _test_Fuzz_getAmountsMoved1_legacy(
        uint256 optionRatioSeed,
        uint16 isLong,
        uint16 tokenType,
        int24 strike,
        int24 width,
        uint128 positionSize,
        bool opening
    ) public {
        // contruct a tokenId
        {
            $optionRatio = bound(optionRatioSeed, 1, 127);

            // the following are all 1 bit so mask them:
            $MASK = 0x1; // takes first 1 bit of the uint16
            isLong = isLong & $MASK;
            tokenType = tokenType & $MASK;

            // bound fuzzed tick
            selectedPool = pools[bound($optionRatio, 0, 2)]; // reuse optionRatio as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));

            int24 rangeDown;
            int24 rangeUp;
            (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(tickSpacing));

            (, currentTick, , , , , ) = selectedPool.slot0();

            lowerBound = int24(-887272 + rangeDown);
            upperBound = int24(887272 - rangeUp);

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing);

            $tokenId = TokenId.wrap(uint256(uint24(tickSpacing)) << 48);
            $tokenId = $tokenId.addLeg(0, $optionRatio, 1, isLong, tokenType, 0, strike, width);
            console2.log("strike", strike);
        }
        $tokenId.validate();

        // get the tick range for this leg in order to get the strike price (the underlying price)
        ($tickLower, $tickUpper) = $tokenId.asTicks(0);

        positionSize = uint128(
            bound(positionSize, 0, positionSize / uint128($tokenId.optionRatio(0)))
        );
        vm.assume(positionSize != 0);

        // set amount 1 - LEGACY
        uint256 amount1 = positionSize * uint128($tokenId.optionRatio(0));
        console2.log("tL", Math.getSqrtRatioAtTick($tickLower));
        console2.log("tU", Math.getSqrtRatioAtTick($tickUpper));

        vm.assume(
            Math.mulDiv(
                Math.getSqrtRatioAtTick($tickLower),
                Math.getSqrtRatioAtTick($tickUpper),
                2 ** 96
            ) > 0
        );
        uint256 amount0 = Math.mulDivRoundingUp(
            uint256(amount1),
            2 ** 96,
            Math.mulDiv(
                Math.getSqrtRatioAtTick($tickLower),
                Math.getSqrtRatioAtTick($tickUpper),
                2 ** 96
            )
        );

        vm.assume(amount0 < type(uint128).max);
        vm.assume(amount1 < type(uint128).max);
        LeftRightUnsigned legacyContractsNotional = LeftRightUnsigned
            .wrap(0)
            .addToRightSlot(amount0.toUint128())
            .addToLeftSlot(amount1.toUint128());

        // set amount0 - UNISWAP MATH
        $contracts = positionSize * $tokenId.optionRatio(0);

        uint160 lowPriceX96 = Math.getSqrtRatioAtTick($tickLower);
        uint160 highPriceX96 = Math.getSqrtRatioAtTick($tickUpper);

        uint256 liquidity = Math.mulDiv($contracts, 2 ** 96, highPriceX96 - lowPriceX96);
        if (isLong == 0) {
            amount0 = Math.mulDivRoundingUp(
                Math.mulDivRoundingUp(
                    uint256(liquidity) << 96,
                    highPriceX96 - lowPriceX96,
                    highPriceX96
                ),
                1,
                lowPriceX96
            );

            amount1 = Math.mulDiv96RoundingUp(liquidity, highPriceX96 - lowPriceX96);
        } else {
            amount0 = Math.mulDiv(
                Math.mulDiv(uint256(liquidity) << 96, highPriceX96 - lowPriceX96, highPriceX96),
                1,
                lowPriceX96
            );

            amount1 = Math.mulDiv96(liquidity, highPriceX96 - lowPriceX96);
        }

        vm.assume(amount0 < type(uint128).max);
        vm.assume(amount1 < type(uint128).max);
        LeftRightUnsigned expectedContractsNotional = LeftRightUnsigned
            .wrap(0)
            .addToRightSlot(amount0.toUint128())
            .addToLeftSlot(amount1.toUint128());

        // set amount0 - PANOPTIC MATH
        LeftRightUnsigned returnedContractsNotional = harness.getAmountsMoved(
            $tokenId,
            positionSize,
            0,
            opening
        );
        assertEq(
            expectedContractsNotional.rightSlot(),
            returnedContractsNotional.rightSlot(),
            "CORRECT: amount 0 not equal"
        );
        assertEq(
            expectedContractsNotional.leftSlot(),
            returnedContractsNotional.leftSlot(),
            "CORRECT: amount 1 not equal"
        );

        if (amount1 != $contracts) {
            assertGe(
                legacyContractsNotional.leftSlot(),
                returnedContractsNotional.leftSlot(),
                "LEGACY: amount 0 not equal"
            );
            if (legacyContractsNotional.rightSlot() > 0) {
                assertGe(
                    legacyContractsNotional.rightSlot(),
                    returnedContractsNotional.rightSlot(),
                    "LEGACY: amount 1 not equal"
                );
            }
        }
    }

    // // _calculateIOAmounts
    function test_Success_calculateIOAmounts_shortTokenType0(
        uint256 optionRatioSeed,
        uint16 asset,
        int24 strike,
        int24 width,
        uint64 positionSize,
        bool opening
    ) public {
        vm.assume(positionSize != 0);
        TokenId tokenId;

        // contruct a tokenId
        {
            uint256 optionRatio = bound(optionRatioSeed, 1, 1);

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            asset = asset & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(optionRatio, 0, 2)]; // reuse optionRatio as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContextFull(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // Set current tick and pool price
            currentTick = int24(bound(currentTick, minTick, maxTick));

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = TokenId.wrap(uint256(uint24(tickSpacing)) << 48);
            tokenId = tokenId.addLeg(0, optionRatio, asset, 0, 0, 0, strike, width);
        }

        LeftRightUnsigned contractsNotional = harness.getAmountsMoved(
            tokenId,
            positionSize,
            0,
            opening
        );
        vm.assume(int256(uint256(contractsNotional.rightSlot())) < type(int128).max);

        LeftRightSigned expectedShorts = LeftRightSigned.wrap(0).addToRightSlot(
            Math.toInt128(contractsNotional.rightSlot())
        );
        (LeftRightSigned returnedLongs, LeftRightSigned returnedShorts) = harness
            ._calculateIOAmounts(tokenId, positionSize, 0, opening);

        assertEq(LeftRightSigned.unwrap(expectedShorts), LeftRightSigned.unwrap(returnedShorts));
        assertEq(0, LeftRightSigned.unwrap(returnedLongs));
    }

    function test_Success_calculateIOAmounts_longTokenType0(
        uint16 asset,
        int24 strike,
        int24 width,
        uint64 positionSize,
        bool opening
    ) public {
        vm.assume(positionSize != 0);
        TokenId tokenId;

        // contruct a tokenId
        {
            uint256 optionRatio = 1;

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            asset = asset & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(optionRatio, 0, 2)]; // reuse optionRatio as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContextFull(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // Set current tick and pool price
            currentTick = int24(bound(currentTick, minTick, maxTick));

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = TokenId.wrap(uint256(uint24(tickSpacing)) << 48);
            tokenId = tokenId.addLeg(0, optionRatio, asset, 1, 0, 0, strike, width);
        }

        // contractSize = positionSize * uint128(tokenId.optionRatio(legIndex));
        (int24 legLowerTick, int24 legUpperTick) = tokenId.asTicks(0);

        positionSize = uint64(
            PositionUtils.getContractsForAmountAtTick(
                currentTick,
                legLowerTick,
                legUpperTick,
                1,
                uint128(positionSize)
            )
        );

        LeftRightUnsigned contractsNotional = harness.getAmountsMoved(
            tokenId,
            positionSize,
            0,
            opening
        );
        vm.assume(int256(uint256(contractsNotional.rightSlot())) < type(int128).max);

        LeftRightSigned expectedLongs = LeftRightSigned.wrap(0).addToRightSlot(
            Math.toInt128(contractsNotional.rightSlot())
        );
        (LeftRightSigned returnedLongs, LeftRightSigned returnedShorts) = harness
            ._calculateIOAmounts(tokenId, positionSize, 0, opening);

        assertEq(LeftRightSigned.unwrap(expectedLongs), LeftRightSigned.unwrap(returnedLongs));
        assertEq(0, LeftRightSigned.unwrap(returnedShorts));
    }

    function test_Success_calculateIOAmounts_shortTokenType1(
        uint256 optionRatioSeed,
        uint16 asset,
        int24 strike,
        int24 width,
        uint64 positionSize,
        bool opening
    ) public {
        positionSize = uint64(bound(positionSize, 1, type(uint64).max));
        TokenId tokenId;

        // contruct a tokenId
        {
            uint256 optionRatio = bound(optionRatioSeed, 1, 127);

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            asset = asset & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(optionRatio, 0, 2)]; // reuse optionRatio as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContextFull(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = TokenId.wrap(uint256(uint24(tickSpacing)) << 48);
            tokenId = tokenId.addLeg(0, optionRatio, asset, 0, 1, 0, strike, width);
        }

        LeftRightUnsigned contractsNotional = harness.getAmountsMoved(
            tokenId,
            positionSize,
            0,
            opening
        );
        vm.assume(int256(uint256(contractsNotional.leftSlot())) < type(int128).max);

        LeftRightSigned expectedShorts = LeftRightSigned.wrap(0).addToLeftSlot(
            Math.toInt128(contractsNotional.leftSlot())
        );
        (LeftRightSigned returnedLongs, LeftRightSigned returnedShorts) = harness
            ._calculateIOAmounts(tokenId, positionSize, 0, opening);

        assertEq(LeftRightSigned.unwrap(expectedShorts), LeftRightSigned.unwrap(returnedShorts));
        assertEq(0, LeftRightSigned.unwrap(returnedLongs));
    }

    function test_Success_calculateIOAmounts_longTokenType1(
        uint256 optionRatioSeed,
        uint16 asset,
        int24 strike,
        int24 width,
        uint64 positionSize,
        bool opening
    ) public {
        vm.assume(positionSize != 0);
        TokenId tokenId;

        // contruct a tokenId
        {
            uint256 optionRatio = bound(optionRatioSeed, 1, 127);

            // max bound position size * optionRatio can be to avoid overflows
            vm.assume(positionSize * uint128(optionRatio) < type(uint56).max);

            // the following are all 1 bit so mask them:
            uint8 MASK = 0x1; // takes first 1 bit of the uint16
            asset = asset & MASK;

            // bound fuzzed tick
            selectedPool = pools[bound(optionRatio, 0, 2)]; // reuse optionRatio as seed
            tickSpacing = selectedPool.tickSpacing();

            width = int24(bound(width, 1, 2048));
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (, currentTick, , , , , ) = selectedPool.slot0();
            (strikeOffset, minTick, maxTick) = PositionUtils.getContextFull(
                uint256(uint24(tickSpacing)),
                currentTick,
                width
            );

            lowerBound = int24(minTick + oneSidedRange - strikeOffset);
            upperBound = int24(maxTick - oneSidedRange - strikeOffset);

            // bound strike
            strike = int24(bound(strike, lowerBound / tickSpacing, upperBound / tickSpacing));
            strike = int24(strike * tickSpacing + strikeOffset);

            tokenId = TokenId.wrap(uint256(uint24(tickSpacing)) << 48);
            tokenId = tokenId.addLeg(0, optionRatio, asset, 1, 1, 0, strike, width);
        }

        LeftRightUnsigned contractsNotional = harness.getAmountsMoved(
            tokenId,
            positionSize,
            0,
            opening
        );

        vm.assume(int256(uint256(contractsNotional.leftSlot())) < type(int128).max);
        LeftRightSigned expectedLongs = LeftRightSigned.wrap(0).addToLeftSlot(
            Math.toInt128(contractsNotional.leftSlot())
        );

        (LeftRightSigned returnedLongs, LeftRightSigned returnedShorts) = harness
            ._calculateIOAmounts(tokenId, positionSize, 0, opening);

        assertEq(LeftRightSigned.unwrap(expectedLongs), LeftRightSigned.unwrap(returnedLongs));
        assertEq(0, LeftRightSigned.unwrap(returnedShorts));
    }

    // mul div as ticks
    function test_Success_getRangesFromStrike_1bps_1TickWide() public {
        int24 width = 1;
        tickSpacing = 1;

        (int24 rangeDown, int24 rangeUp) = harness.getRangesFromStrike(width, tickSpacing);

        assertEq(rangeDown, 0, "rangeDown");
        assertEq(rangeUp, 1, "rangeUp");
    }

    function test_Success_getRangesFromStrike_allCombos(
        uint256 widthSeed,
        uint256 tickSpacingSeed,
        int24 strike
    ) public view {
        // bound the width (1 -> 4094)
        uint24 widthBounded = uint24(bound(widthSeed, 1, 4094));

        // bound the tickSpacing
        uint24 tickSpacingBounded = uint24(bound(tickSpacingSeed, 1, 1000));

        // get a valid strike
        strike = int24((strike / int24(tickSpacingBounded)) * int24(tickSpacingBounded));

        // validate bounds
        vm.assume(strike > TickMath.MIN_TICK && strike < TickMath.MAX_TICK);

        // invoke
        (int24 rangeDown, int24 rangeUp) = harness.getRangesFromStrike(
            int24(widthBounded),
            int24(tickSpacingBounded)
        );

        // if width is odd and tickSpacing is odd
        // then actual range will not be a whole number
        if (widthBounded % 2 == 1 && tickSpacingBounded % 2 == 1) {
            uint256 mulDivRangeDown = Math.mulDiv(widthBounded, tickSpacingBounded, 2);

            uint256 mulDivRangeUp = Math.mulDivRoundingUp(widthBounded, tickSpacingBounded, 2);

            // ensure range is rounded down if width * tickSpacing is odd
            assertEq(uint24(rangeDown), mulDivRangeDown);

            // ensure range is rounded up if width * tickSpacing is odd
            assertEq(uint24(rangeUp), mulDivRangeUp);
        } else {
            // else even -> rangeDown and rangeUp are both just (width * ts) / 2
            int24 range = int24((widthBounded * tickSpacingBounded) / 2);

            assertEq(strike - rangeDown, strike - range);
            assertEq(strike + rangeUp, strike + range);
        }
    }

    function test_success_toInt24() public view {
        assertEq(int24(-1), harness.int12toInt24(2 ** 12 - 1));
        assertEq(int24(-1), harness.int12toInt24(2 ** 13 - 1));
        assertEq(int24(-1), harness.int12toInt24(2 ** 14 - 1));
        assertEq(int24(-1), harness.int12toInt24(2 ** 15 - 1));
        assertEq(int24(-1), harness.int12toInt24(2 ** 16 - 1));
    }

    /*//////////////////////////////////////////////////////////////
                        COMPUTE INTERNAL MEDIAN TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice This test ensures the order map is correct when the new tick is the new MINIMUM value.
    function test_SUCCESS_OrderMapIsCorrect_InsertNewTick(int256 x) public {
        // ARRANGE

        int24 deltaTick = int24(bound(x, -149, 149));

        OraclePack initialData = _encodeOraclePack(_generateSortedOffsets(x));

        // Set up the mock pool to return a new tick with an offset of -100, smaller than any existing value.
        int56 tickCumulative = int56(
            REFERENCE_TICK +
                harness.int12toInt24(OraclePack.unwrap(initialData) % 2 ** 12) +
                deltaTick
        ) * 64;

        int24 deltaOffset = harness.int12toInt24(OraclePack.unwrap(initialData) % 2 ** 12);
        int24 oldReferenceTick = int24(uint24(OraclePack.unwrap(initialData) >> 96));
        // ACT
        vm.warp(10 * 64);
        (, OraclePack updatedData) = harness.computeInternalMedian(
            initialData,
            REFERENCE_TICK +
                harness.int12toInt24(OraclePack.unwrap(initialData) % 2 ** 12) +
                deltaTick
        );

        // ASSERT
        int24[] memory finalTicks = _decodeSortedTicks(updatedData);

        int24 newReferenceTick = int24(uint24(OraclePack.unwrap(updatedData) >> 96));
        int24 deltaReference = newReferenceTick - oldReferenceTick;

        // The oldest value (40) is dropped, and the new value (-100) is inserted.
        // Expected sorted list: [-100, -40, -30, -20, -10, 10, 20, 30]
        int24[] memory expectedTicks = new int24[](8);
        expectedTicks[0] = newReferenceTick + deltaOffset - deltaReference + deltaTick; // New minimum
        expectedTicks[1] = REFERENCE_TICK + _generateSortedOffsets(x)[0];
        expectedTicks[2] = REFERENCE_TICK + _generateSortedOffsets(x)[1];
        expectedTicks[3] = REFERENCE_TICK + _generateSortedOffsets(x)[2];
        expectedTicks[4] = REFERENCE_TICK + _generateSortedOffsets(x)[3];
        expectedTicks[5] = REFERENCE_TICK + _generateSortedOffsets(x)[4];
        expectedTicks[6] = REFERENCE_TICK + _generateSortedOffsets(x)[5];
        expectedTicks[7] = REFERENCE_TICK + _generateSortedOffsets(x)[6];

        assertEq(
            keccak256(abi.encode(finalTicks)),
            keccak256(abi.encode(expectedTicks)),
            "New minimum value not sorted correctly!"
        );
    }

    /// @notice This test ensures the order map is correct when the new tick is the new MINIMUM value.
    function test_SUCCESS_OrderMapIsCorrect_InsertNew_cap(int256 x) public {
        // ARRANGE

        // deltaTick would lead to capping
        int24 deltaTick = int24(
            bound(x, MAX_CLAMP_DELTA + 1, Constants.MAX_RESIDUAL_THRESHOLD - 1)
        );

        deltaTick = x % 2 == 0 ? -deltaTick : deltaTick;

        OraclePack initialData = _encodeOraclePack(_generateSortedOffsets(x));

        // Set up the mock pool to return a new tick with an offset of -100, smaller than any existing value.
        int56 tickCumulative = int56(
            REFERENCE_TICK +
                harness.int12toInt24(OraclePack.unwrap(initialData) % 2 ** 12) +
                deltaTick
        ) * 64;

        // ACT
        vm.warp(10 * 64);
        (, OraclePack updatedData) = harness.computeInternalMedian(
            initialData,
            REFERENCE_TICK +
                harness.int12toInt24(OraclePack.unwrap(initialData) % 2 ** 12) +
                deltaTick
        );

        // ASSERT
        int24[] memory finalTicks = _decodeSortedTicks(updatedData);

        // The oldest value (40) is dropped, and the new value (-100) is inserted.
        // Expected sorted list: [-100, -40, -30, -20, -10, 10, 20, 30]
        int24[] memory expectedTicks = new int24[](8);
        expectedTicks[0] = REFERENCE_TICK + _generateSortedOffsets(x)[0] + deltaTick; // New minimum

        assertEq(
            finalTicks[0],
            expectedTicks[0] - deltaTick + (x % 2 == 0 ? int24(-1) : int24(1)) * MAX_CLAMP_DELTA,
            "New minimum value not sorted correctly!"
        );
    }

    /// @notice This test ensures the order map is correct when the new tick is the new MINIMUM value.
    function test_SUCCESS_OrderMapIsCorrect_InsertNew_rebase(int256 x) public {
        // ARRANGE

        // deltaTick would lead to capping
        int24 deltaTick = x % 2 == 0 ? MAX_CLAMP_DELTA : -MAX_CLAMP_DELTA;

        uint256 n = uint24((Constants.MAX_RESIDUAL_THRESHOLD / MAX_CLAMP_DELTA)) + 1;

        OraclePack updatedData = _encodeOraclePack(_generateSortedOffsets(0));

        int24 referenceTick = int24(uint24(OraclePack.unwrap(updatedData) >> 96));
        for (uint256 i; i < n; ++i) {
            // Set up the mock pool to return a new tick with an offset of -100, smaller than any existing value.
            int56 tickCumulative = int56(
                REFERENCE_TICK +
                    harness.int12toInt24(OraclePack.unwrap(updatedData) % 2 ** 12) +
                    deltaTick
            ) * 64;

            // ACT
            vm.warp(block.timestamp + 128);
            vm.roll(block.number + 1);
            (, OraclePack _updatedData) = harness.computeInternalMedian(
                updatedData,
                REFERENCE_TICK +
                    harness.int12toInt24(OraclePack.unwrap(updatedData) % 2 ** 12) +
                    deltaTick
            );
            updatedData = _updatedData;
        }

        int24 newReferenceTick = int24(uint24(OraclePack.unwrap(updatedData) >> 96));

        assertTrue(referenceTick != newReferenceTick, "FAIL: reference tick not updated");
    }

    /// @notice This test ensures no update occurs if the block timestamp is in the same epoch.
    function test_NoUpdateInSameEpoch() public {
        // ARRANGE
        OraclePack initialData = _encodeOraclePack(_generateSortedOffsets(0));

        // ACT: Set timestamp to be in the same epoch as the initial data.
        vm.warp(INITIAL_EPOCH * 64 + 1); // e.g., timestamp >> 6 will still be 5
        (, OraclePack updatedData) = harness.computeInternalMedian(initialData, REFERENCE_TICK);

        // ASSERT: The function should return 0 for updatedOraclePack.
        assertEq(OraclePack.unwrap(updatedData), 0, "Update should not happen in the same epoch");
    }
}
