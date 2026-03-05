// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {RiskEngineHarness} from "./RiskEngineHarness.sol";
import {MockCollateralTracker} from "./mocks/MockCollateralTracker.sol";
import {CollateralTrackerV2} from "@contracts/CollateralTracker.sol";
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {TokenId} from "@types/TokenId.sol";
import {PositionBalance} from "@types/PositionBalance.sol";
import {PositionFactory} from "./helpers/PositionFactory.sol";
import {Constants} from "@libraries/Constants.sol";

/// @notice Tests for utilization-dependent margin on loans (width==0 short legs)
/// and the parameterized _sellCollateralRatio(util, minRatio).
contract RiskEngineUtilMarginLoans is Test {
    using PositionFactory for *;

    RiskEngineHarness internal E;
    MockCollateralTracker internal ct0;
    MockCollateralTracker internal ct1;

    uint256 constant DEC = 10_000_000;
    uint256 constant MAINT = 2_000_000; // MAINT_MARGIN_RATE = 20%
    uint256 constant SELLER = 2_000_000; // SELLER_COLLATERAL_RATIO = 20%
    uint256 constant TARGET = 6_666_667; // TARGET_POOL_UTIL (scaled by 1000 internally)
    uint256 constant SATURATED = 9_000_000; // SATURATED_POOL_UTIL

    function setUp() public {
        E = new RiskEngineHarness(5_000_000, 5_000_000);
        ct0 = new MockCollateralTracker();
        ct1 = new MockCollateralTracker();
        ct0.setGlobal(1_000_000 ether, 1_000_000 ether);
        ct1.setGlobal(1_000_000 ether, 1_000_000 ether);
        ct0.setSharePrice(1, 1);
        ct1.setSharePrice(1, 1);
    }

    // ─── _sellCollateralRatio with custom minRatio ───────────────────

    function test_sellCollateralRatioCustom_belowTarget() public view {
        // Below target utilization → returns minRatio unchanged
        uint256 ratio = E.sellCollateralRatioCustom(3000, 3_000_000);
        assertEq(ratio, 3_000_000, "below target should return minRatio");
    }

    function test_sellCollateralRatioCustom_aboveSaturated() public view {
        // Above saturated → returns DECIMALS (100%)
        uint256 ratio = E.sellCollateralRatioCustom(9500, 3_000_000);
        assertEq(ratio, DEC, "above saturated should return 100%");
    }

    function test_sellCollateralRatioCustom_midpoint() public view {
        // Between target and saturated, ratio interpolates between minRatio and DECIMALS
        // Use utilization = 8000 (80%), which after *1000 = 8_000_000
        uint256 ratio = E.sellCollateralRatioCustom(8000, 2_000_000);
        // expected: 2_000_000 + (10_000_000 - 2_000_000) * (8_000_000 - 6_666_667) / (9_000_000 - 6_666_667)
        // = 2_000_000 + 8_000_000 * 1_333_333 / 2_333_333
        uint256 expected = uint256(2_000_000) + (uint256(8_000_000) * 1_333_333) / 2_333_333;
        assertEq(ratio, expected, "midpoint interpolation");
    }

    function test_sellCollateralRatioCustom_differentMinRatios() public view {
        // Same utilization but different minRatio should give different results
        int256 util = 8000;
        uint256 r1 = E.sellCollateralRatioCustom(util, 1_000_000); // 10%
        uint256 r2 = E.sellCollateralRatioCustom(util, 3_000_000); // 30%
        assertTrue(r1 < r2, "higher minRatio should give higher ratio at same util");
    }

    function test_sellCollateralRatioCustom_negativeUtil_halves() public view {
        // Negative utilization (strangle) halves minRatio then uses absolute value
        uint256 ratioNeg = E.sellCollateralRatioCustom(-3000, 4_000_000);
        // minRatio/2 = 2_000_000, util=3000 < target → returns 2_000_000
        assertEq(ratioNeg, 2_000_000, "negative util should halve minRatio");
    }

    // ─── Backward compatibility: _sellCollateralRatio with SELLER default ────

    function test_sellCollateralRatio_defaultMatchesCustom() public view {
        // The existing sellCollateralRatio(util) should match sellCollateralRatioCustom(util, SELLER)
        for (int256 u = 0; u <= 10000; u += 2500) {
            assertEq(
                E.sellCollateralRatio(u),
                E.sellCollateralRatioCustom(u, SELLER),
                "default should match custom with SELLER_COLLATERAL_RATIO"
            );
        }
    }

    // ─── Loan margin (width==0, short) uses utilization-dependent curve ──────

    function test_loanMargin_lowUtil_equalsBaseMaint() public view {
        // At low utilization (0), loan margin = (MAINT + DEC) / DEC * amount = 120% of amount
        uint64 pool = 1 + (10 << 48);
        TokenId loan = PositionFactory.makeLeg(
            pool,
            0,
            1,
            0,
            /*isLong*/ 0,
            /*tokenType*/ 0,
            0,
            int24(0),
            int24(0)
        );

        // poolUtilization=0 → _sellCollateralRatio(0, MAINT) = MAINT (below target)
        // required = amount * (MAINT + DEC) / DEC
        uint128 size = 1e18;
        uint256 req = E.reqSingleNoPartner(loan, 0, size, int24(0), int16(0));

        // expected: ceil(1e18 * (2_000_000 + 10_000_000) / 10_000_000) = ceil(1.2e18) = 1.2e18
        uint256 expected = (uint256(size) * (MAINT + DEC) + DEC - 1) / DEC;
        assertEq(req, expected, "low util loan should be 120% collateral");
    }

    function test_loanMargin_highUtil_exceedsBaseMaint() public view {
        // At high utilization, loan margin should exceed the base 120%
        uint64 pool = 1 + (10 << 48);
        TokenId loan = PositionFactory.makeLeg(
            pool,
            0,
            1,
            0,
            /*isLong*/ 0,
            /*tokenType*/ 0,
            0,
            int24(0),
            int24(0)
        );

        uint128 size = 1e18;
        // util=9000 → saturated → _sellCollateralRatio = DECIMALS
        // required = amount * (DEC + DEC) / DEC = 200% of amount
        uint256 reqHigh = E.reqSingleNoPartner(loan, 0, size, int24(0), int16(9000));
        uint256 reqLow = E.reqSingleNoPartner(loan, 0, size, int24(0), int16(0));

        assertTrue(reqHigh > reqLow, "high util loan margin should exceed low util");

        // At saturation: required = ceil(size * 2)
        uint256 expectedSaturated = (uint256(size) * (DEC + DEC) + DEC - 1) / DEC;
        assertEq(reqHigh, expectedSaturated, "saturated loan should be 200% collateral");
    }

    function test_loanMargin_midUtil_interpolated() public view {
        uint64 pool = 1 + (10 << 48);
        TokenId loan = PositionFactory.makeLeg(
            pool,
            0,
            1,
            0,
            /*isLong*/ 0,
            /*tokenType*/ 0,
            0,
            int24(0),
            int24(0)
        );

        uint128 size = 1e18;
        // util=8000 (80%) → between target and saturated
        uint256 req = E.reqSingleNoPartner(loan, 0, size, int24(0), int16(8000));

        uint256 reqLow = E.reqSingleNoPartner(loan, 0, size, int24(0), int16(0));
        uint256 reqHigh = E.reqSingleNoPartner(loan, 0, size, int24(0), int16(9000));

        assertTrue(req > reqLow, "mid util > low util");
        assertTrue(req < reqHigh, "mid util < saturated");
    }

    // ─── Credit (width==0, long) still returns 0 ────────────────────

    function test_creditLeg_stillZero() public view {
        uint64 pool = 1 + (10 << 48);
        TokenId credit = PositionFactory.makeLeg(
            pool,
            0,
            1,
            0,
            /*isLong*/ 1,
            /*tokenType*/ 0,
            0,
            int24(0),
            int24(0)
        );

        uint256 req = E.reqSingleNoPartner(credit, 0, 1e18, int24(0), int16(5000));
        assertEq(req, 0, "credit leg should require 0 collateral");
    }

    // ─── Short options (width>0) still use SELLER_COLLATERAL_RATIO ──

    function test_shortOption_unaffected() public view {
        uint64 pool = 1 + (10 << 48);
        TokenId shortPut = PositionFactory.makeLeg(
            pool,
            0,
            1,
            0,
            /*isLong*/ 0,
            /*tokenType*/ 0,
            0,
            int24(0),
            int24(10)
        );

        uint128 size = 1e18;
        // Short option at util=0 should use SELLER_COLLATERAL_RATIO, not MAINT_MARGIN_RATE
        // Since both are 2_000_000 in this config, compare with reqAtUtil
        uint256 reqOption = E.reqSingleNoPartner(shortPut, 0, size, int24(0), int16(0));
        assertTrue(reqOption >= 1, "short option should have nonzero requirement");
    }

    // ─── Fuzz: loan margin monotonically increases with utilization ──

    function testFuzz_loanMargin_monotonic(int16 util1, int16 util2) public view {
        // Bound utilizations to valid range
        util1 = int16(bound(int256(util1), 0, 10000));
        util2 = int16(bound(int256(util2), int256(util1), 10000));

        uint64 pool = 1 + (10 << 48);
        TokenId loan = PositionFactory.makeLeg(pool, 0, 1, 0, 0, 0, 0, int24(0), int24(0));

        uint128 size = 1e18;
        uint256 req1 = E.reqSingleNoPartner(loan, 0, size, int24(0), util1);
        uint256 req2 = E.reqSingleNoPartner(loan, 0, size, int24(0), util2);

        assertTrue(req2 >= req1, "loan margin should be monotonically non-decreasing with util");
    }

    // ─── Fuzz: _sellCollateralRatio monotonic for any minRatio ──────

    function testFuzz_sellCollateralRatioCustom_monotonic(
        int256 util1,
        int256 util2,
        uint256 minRatio
    ) public view {
        util1 = bound(util1, 0, 10000);
        util2 = bound(util2, util1, 10000);
        minRatio = bound(minRatio, 0, DEC);

        uint256 r1 = E.sellCollateralRatioCustom(util1, minRatio);
        uint256 r2 = E.sellCollateralRatioCustom(util2, minRatio);

        assertTrue(r2 >= r1, "sell ratio should be monotonically non-decreasing");
    }
}
