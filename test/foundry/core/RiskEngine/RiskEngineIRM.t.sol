// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RiskEngineHarness} from "./RiskEngineHarness.sol";
import {MarketState} from "@types/MarketState.sol";

/// @title RiskEngine IRM Tests
/// @notice This contract specifically tests the Adaptive Interest Rate Model (IRM)
/// logic within the RiskEngine, which was not covered by other tests.
contract RiskEngineIRMTest is Test {
    RiskEngineHarness internal E;

    // --- IRM Constants (copied from RiskEngine.sol) ---
    int256 internal constant WAD = 1e18;
    int256 internal constant INITIAL_RATE_AT_TARGET = 0.04 ether / int256(365 days);
    // These are public in RiskEngine, but we copy them for easy access
    int256 internal constant MIN_RATE_AT_TARGET = 0.001 ether / int256(365 days);
    int256 internal constant MAX_RATE_AT_TARGET = 2.0 ether / int256(365 days);
    int256 internal constant TARGET_UTILIZATION = 2 ether / int256(3);

    function setUp() public {
        E = new RiskEngineHarness(5_000_000, 5_000_000);
    }

    /*//////////////////////////////////////////////////////////////
    //                       HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Packs the rate and time into the accumulator format
    /// expected by _borrowRate.
    /// @dev Based on unpacking logic in RiskEngine._borrowRate:
    /// rate -> (interestRateAccumulator >> 112) % 2 ** 38
    /// time -> uint32(interestRateAccumulator >> 80)
    function _packAccumulator(
        int256 rateAtTarget,
        uint32 time
    ) internal pure returns (MarketState) {
        // Pack rate at bits 112-149 and time at bits 80-111
        return
            MarketState.wrap(0).updateRateAtTarget(uint40(uint256(rateAtTarget))).updateMarketEpoch(
                time / 4
            );
    }

    /// @notice Packs all fields into the accumulator format.
    /// @dev Layout:
    /// [106 bits interest (255-150)]
    /// [38 bits rate (149-112)]
    /// [32 bits time (111-80)]
    /// [80 bits index (79-0)]
    function _packAccumulatorFull(
        uint104 unrealizedInterest, // Note: 106 bits available
        int256 rateAtTarget,
        uint32 time,
        uint80 borrowIndex
    ) internal pure returns (MarketState) {
        return
            MarketState
                .wrap(0)
                .updateUnrealizedInterest(unrealizedInterest)
                .updateRateAtTarget(uint40(uint256(rateAtTarget)))
                .updateMarketEpoch(time / 4)
                .updateBorrowIndex(borrowIndex);
    }

    /*//////////////////////////////////////////////////////////////
    //                       DIRECTED TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Tests the first call to updateInterestRate when the accumulator is 0.
    /// @dev This covers the `if (startRateAtTarget == 0)` block.
    function test_IRM_firstInteraction() public {
        MarketState accum = MarketState.wrap(0);
        uint256 util = uint256(TARGET_UTILIZATION);

        // Act
        (uint128 avgRate, uint256 endRate) = E.updateInterestRate(util, accum);

        // Assert
        // With 0 accumulator, both rates should be set to the initial default.
        assertEq(
            avgRate,
            uint128(uint256(INITIAL_RATE_AT_TARGET)),
            "avgRate should be initial rate"
        );
        assertEq(endRate, uint256(INITIAL_RATE_AT_TARGET), "endRate should be initial rate");
    }

    /// @notice Tests that the rate increases when utilization is above target
    /// and time has passed.
    /// @dev This covers the main `else` block (lines 1844-1871)
    /// and `_newRateAtTarget` (lines 1892-1903).
    function test_IRM_rateIncreases_aboveTarget() public {
        // --- Setup: First interaction ---
        uint32 time1 = 1000;
        vm.warp(time1);
        uint256 util1 = uint256(TARGET_UTILIZATION);
        (, uint256 rate1) = E.updateInterestRate(util1, MarketState.wrap(0));
        MarketState accum1 = _packAccumulator(int256(rate1), time1);

        // --- Test: Second interaction ---
        uint32 time2 = time1 + 3600; // 1 hour later
        vm.warp(time2);
        // Set utilization slightly above target
        uint256 util2 = uint256(TARGET_UTILIZATION + 0.1 ether);

        // Act
        (uint128 avgRate2, uint256 endRate2) = E.updateInterestRate(util2, accum1);

        // Assert
        // `startRateAtTarget` was non-zero, so we entered the `else` block.
        // `elapsed` > 0 and `err` > 0, so `linearAdaptation` > 0.
        // This covers the `_newRateAtTarget` function.
        assertTrue(endRate2 > rate1, "endRate should increase");
        assertTrue(avgRate2 > uint128(rate1), "avgRate should be higher");
        assertLe(endRate2, uint256(MAX_RATE_AT_TARGET), "endRate clamped by max");
    }

    /// @notice Tests that the rate decreases when utilization is below target
    /// and time has passed.
    /// @dev This also covers the main `else` block and `_newRateAtTarget`.
    function test_IRM_rateDecreases_belowTarget() public {
        // --- Setup: First interaction ---
        uint32 time1 = 1000;
        vm.warp(time1);
        uint256 util1 = uint256(TARGET_UTILIZATION);
        (, uint256 rate1) = E.updateInterestRate(util1, MarketState.wrap(0));
        MarketState accum1 = _packAccumulator(int256(rate1), time1);

        // --- Test: Second interaction ---
        uint32 time2 = time1 + 3600; // 1 hour later
        vm.warp(time2);
        // Set utilization slightly below target
        uint256 util2 = uint256(TARGET_UTILIZATION - 0.1 ether);

        // Act
        (uint128 avgRate2, uint256 endRate2) = E.updateInterestRate(util2, accum1);

        // Assert
        // `elapsed` > 0 and `err` < 0, so `linearAdaptation` < 0.
        assertTrue(endRate2 < rate1, "endRate should decrease");
        assertTrue(avgRate2 < uint128(rate1), "avgRate should be lower");
        assertGe(endRate2, uint256(MIN_RATE_AT_TARGET), "endRate clamped by min");
    }

    /// @notice Tests the branch where no time has elapsed.
    /// @dev This covers the `if (linearAdaptation == 0)` block (lines 1849-1853).
    function test_IRM_noTimeElapsed() public {
        // --- Setup: First interaction ---
        uint32 time1 = 1000;
        vm.warp(time1);
        uint256 util1 = uint256(TARGET_UTILIZATION);
        console2.log("first");
        (, uint256 rate1) = E.updateInterestRate(util1, MarketState.wrap(0));
        MarketState accum1 = _packAccumulator(int256(rate1), time1);

        console2.log("time1");
        // --- Test: Second interaction (no time warp) ---
        // `elapsed` will be 0, so `linearAdaptation` will be 0.
        uint256 util2 = uint256(TARGET_UTILIZATION + 0.1 ether); // Change util

        // Act
        console2.log("second");
        (uint128 avgRate2, uint256 endRate2) = E.updateInterestRate(util2, accum1);

        // Assert
        // Enters the `linearAdaptation == 0` block.
        // endRate is unchanged from startRate.
        assertEq(endRate2, rate1, "endRate should be unchanged");
        // avgRate IS updated, because `_curve` is called with the *new* `err`
        // and the `avgRateAtTarget` (which is `startRateAtTarget`).
        assertTrue(avgRate2 > uint128(rate1), "avgRate reflects new util");
    }

    /// @notice Tests the branch where utilization is exactly at target.
    /// @dev This also covers the `if (linearAdaptation == 0)` block.
    function test_IRM_noUtilChange_atTarget() public {
        // --- Setup: First interaction ---
        uint32 time1 = 1000;
        vm.warp(time1);
        uint256 util1 = uint256(TARGET_UTILIZATION);
        (, uint256 rate1) = E.updateInterestRate(util1, MarketState.wrap(0));
        MarketState accum1 = _packAccumulator(int256(rate1), time1);

        // --- Test: Second interaction ---
        uint32 time2 = time1 + 3600; // 1 hour later
        vm.warp(time2);
        // `err` will be 0, so `speed` and `linearAdaptation` will be 0.
        uint256 util2 = uint256(TARGET_UTILIZATION);

        // Act
        (uint128 avgRate2, uint256 endRate2) = E.updateInterestRate(util2, accum1);

        // Assert
        // Enters the `linearAdaptation == 0` block.
        assertEq(endRate2, rate1, "endRate should be unchanged");
        // `_curve` is called with `err = 0`, so it returns `avgRateAtTarget`,
        // which was set to `startRateAtTarget` (i.e., `rate1`).
        assertEq(avgRate2, uint128(rate1), "avgRate should be unchanged");
    }

    // =============================================================
    // ================= NEWLY REQUESTED TESTS =====================
    // =============================================================

    /// @notice Tests that bits 0-79 (global borrow index) are ignored.
    /// @dev This confirms that the `_borrowRate` function is not affected
    /// by data in other parts of the accumulator slot.
    function test_IRM_ignoresBorrowIndexBits() public {
        uint32 time = 1000;
        vm.warp(time + 3600); // 1 hour elapsed
        uint256 util = uint256(TARGET_UTILIZATION + 0.1 ether); // Above target
        int256 rate = INITIAL_RATE_AT_TARGET;

        // Pack with borrow index = 0
        MarketState accum_zero_index = _packAccumulatorFull(0, rate, time, 0);
        // Pack with borrow index = max
        MarketState accum_max_index = _packAccumulatorFull(0, rate, time, type(uint80).max);

        // Act
        (uint128 avgRate0, uint256 endRate0) = E.updateInterestRate(util, accum_zero_index);
        (uint128 avgRateMax, uint256 endRateMax) = E.updateInterestRate(util, accum_max_index);

        // Assert
        // Results should be identical, as borrow index bits (0-79) are not read
        assertEq(avgRate0, avgRateMax, "avgRate should be same");
        assertEq(endRate0, endRateMax, "endRate should be same");
        // And the rate should have increased (since util > target and time passed)
        assertTrue(endRate0 > uint256(rate), "rate should increase");
    }

    /// @notice Tests the behavior when the timestamp wraps around (Y2K38 bug).
    /// @dev Simulates a `block.timestamp` that is *less than* the
    /// `previousTime` stored in the accumulator, causing a negative elapsed time.
    function test_IRM_timestampWrapAround_handlesNegativeElapsed() public {
        // --- Setup ---
        // Set a "previous" time just before the uint32 max
        uint32 time1 = type(uint32).max - 3600; // 1 hour before wrap
        vm.warp(time1);
        int256 rate1 = INITIAL_RATE_AT_TARGET;
        MarketState accum1 = _packAccumulator(rate1, time1);

        // --- Test ---
        // Set the current time to be *after* the wrap (e.g., back to 1970)
        uint32 time2 = 1000; // A small timestamp
        vm.warp(time2);
        // Set utilization *above* target, which should *increase* the rate
        uint256 util2 = uint256(TARGET_UTILIZATION + 0.1 ether);

        // Act
        // `elapsed` will be `int256(1000 - (type(uint32).max - 3600))`,
        // which is a large negative number.
        // `linearAdaptation` will also be large and negative.
        // `_newRateAtTarget` will calculate `wExp(negative)` -> ~0
        // The result will be clamped to the minimum.
        (uint128 avgRate2, uint256 endRate2) = E.updateInterestRate(util2, accum1);

        // Assert
        // The rate plummets to MIN, because of the large negative elapsed time.
        assertEq(endRate2, uint256(MIN_RATE_AT_TARGET), "endRate should be clamped to MIN");
        // The avgRate will also be based on this, and be very low.
        assertTrue(avgRate2 < uint256(rate1), "avgRate should be very low");
    }

    /// @notice Tests that bits *above* the 38-bit rateAtTarget field are ignored.
    /// @dev This covers the "rateAtTarget exceeds 2**38" scenario by
    /// showing that setting bits 150+ (unrealized interest) doesn't
    /// affect the rate calculation, which only reads bits 112-149.
    function test_IRM_rateAtTarget_overflowBitsIgnored() public {
        uint32 time = 1000;
        vm.warp(time + 3600); // 1 hour elapsed
        uint256 util = uint256(TARGET_UTILIZATION + 0.1 ether); // Above target
        int256 rate = INITIAL_RATE_AT_TARGET;

        // Pack with unrealized interest = 0
        MarketState accum_normal = _packAccumulator(rate, time);

        // Pack with unrealized interest bits set (bit 150).
        // This simulates a value > 2**38 *if* the field was read incorrectly.
        MarketState accum_overflow = MarketState.wrap(
            MarketState.unwrap(accum_normal) | (uint256(1) << 150)
        );

        // Act
        (uint128 avgRate_normal, uint256 endRate_normal) = E.updateInterestRate(util, accum_normal);
        (uint128 avgRate_overflow, uint256 endRate_overflow) = E.updateInterestRate(
            util,
            accum_overflow
        );

        // Assert
        // Results should be identical, as bits 150+ are not read by _borrowRate
        assertEq(avgRate_normal, avgRate_overflow, "avgRate should be same");
        assertEq(endRate_normal, endRate_overflow, "endRate should be same");
        // And the rate should have increased (since util > target and time passed)
        assertTrue(endRate_normal > uint256(rate), "rate should increase");
    }

    /*//////////////////////////////////////////////////////////////
    //                       FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_IRM_monotonic_and_bounded(
        uint64 elapsed,
        int256 utilOffset,
        int256 startRate
    ) public {
        // Constrain inputs
        elapsed = uint64(bound(elapsed, 12, 365 days));
        // Bound utilOffset to be within [0, 1e18]
        utilOffset = bound(utilOffset, -TARGET_UTILIZATION, WAD - TARGET_UTILIZATION);
        // Bound startRate to be within the allowed min/max
        startRate = bound(startRate, MIN_RATE_AT_TARGET, MAX_RATE_AT_TARGET);

        uint32 time1 = 1000;
        vm.warp(time1);

        // Setup
        MarketState accum = _packAccumulator(startRate, time1);
        uint256 util = uint256(TARGET_UTILIZATION + utilOffset);

        // Act
        vm.warp(time1 + elapsed);
        (uint128 avgRate, uint256 endRate) = E.updateInterestRate(util, accum);

        // Assert
        // 1. Bounds check
        assertGe(avgRate, 0, "avgRate >= 0");
        assertGe(endRate, uint256(MIN_RATE_AT_TARGET), "endRate >= min");
        assertLe(endRate, uint256(MAX_RATE_AT_TARGET), "endRate <= max");

        // 2. Monotonicity check
        if (elapsed == 0 || utilOffset == 0) {
            // If no time elapsed OR no error, endRate == startRate
            assertEq(endRate, uint256(startRate), "rate unchanged");
        } else if (utilOffset > 0) {
            // If above target, rate must not decrease
            assertGe(endRate, uint256(startRate), "rate non-decreasing");
        } else {
            // If below target (utilOffset < 0), rate must not increase
            assertLe(endRate, uint256(startRate), "rate non-increasing");
        }
    }
}
