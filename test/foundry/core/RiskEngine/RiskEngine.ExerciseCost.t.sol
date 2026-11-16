// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RiskEngineParams} from "../../testUtils/RiskEngineParams.sol";
import {RiskEngineHarness} from "./RiskEngineHarness.sol";
import {PositionFactory} from "./helpers/PositionFactory.sol";
import {Math} from "@libraries/Math.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {LeftRightSigned} from "@types/LeftRight.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {PositionBalance} from "@types/PositionBalance.sol";
import {TokenId} from "@types/TokenId.sol";

/// @notice Pins the extrinsic-value force-exercise fee in `exerciseCost`.
/// @dev fee(t) = FORCE_EXERCISE_COST * D^2 / (2W) bps of the leg's notional, D = distance to the nearer range edge,
/// floored at NOTIONAL_FEE bps out of range and at max(NOTIONAL_FEE, tickSpacing / 2) bps in range (~the pool fee
/// tier), bounded at FORCE_EXERCISE_COST, evaluated at the oracle tick.
/// Only the width>0 long leg with the lowest fee value (compared in the cheaper token at the oracle tick, token0 at or
/// below tick 0 and token1 above; the first one on ties) is charged the fee; the composition-delta reversal between the
/// current and oracle ticks is still applied to every long leg.
contract RiskEngineExerciseCostTest is Test {
    RiskEngineHarness internal E;

    int24 internal constant TS = 10;
    uint64 internal constant POOL_ID = 1 + (uint64(uint24(TS)) << 48);
    uint64 internal constant POOL_ID_WIDE = 1 + (uint64(200) << 48); // tickSpacing = 200
    uint256 internal constant ONE_BPS = 1000;
    uint256 internal FLOOR; // NOTIONAL_FEE bps, in DECIMALS units (out of range)
    uint256 internal IN_RANGE_FLOOR; // max(FLOOR, tickSpacing / 2 bps) for POOL_ID (tickSpacing 10 -> 5 bps)
    uint128 internal constant SIZE = 1e18;

    uint256 internal DECIMALS;
    uint256 internal SHARE;

    function setUp() public {
        E = new RiskEngineHarness(5_000_000, 5_000_000);
        DECIMALS = E.DECIMALS();
        SHARE = RiskEngineParams.blueChip().forceExerciseCost;
        FLOOR = uint256(RiskEngineParams.blueChip().notionalFee) * ONE_BPS;
        IN_RANGE_FLOOR = Math.max(FLOOR, (uint256(uint24(TS)) * ONE_BPS) / 2);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Single long call leg on token0 (asset 0, tokenType 0).
    function _long(uint64 poolId, int24 strike, int24 width) internal pure returns (TokenId) {
        return PositionFactory.makeLeg(poolId, 0, 1, 0, 1, 0, 0, strike, width);
    }

    function _bounds(TokenId id) internal pure returns (int256 tL, int256 tU) {
        (int24 rangeDown, int24 rangeUp) = PanopticMath.getRangesFromStrike(
            id.width(0),
            id.tickSpacing()
        );
        tL = int256(id.strike(0)) - rangeDown;
        tU = int256(id.strike(0)) + rangeUp;
    }

    /// @notice Single long put leg on token1 (asset 0, tokenType 1).
    function _long1(uint64 poolId, int24 strike, int24 width) internal pure returns (TokenId) {
        return PositionFactory.makeLeg(poolId, 0, 1, 0, 1, 1, 0, strike, width);
    }

    function _notional(TokenId id) internal pure returns (int256) {
        (LeftRightSigned longs, ) = PanopticMath.calculateIOAmounts(id, SIZE, 0, true);
        return longs.rightSlot();
    }

    function _notional1(TokenId id) internal pure returns (int256) {
        (LeftRightSigned longs, ) = PanopticMath.calculateIOAmounts(id, SIZE, 0, true);
        return longs.leftSlot();
    }

    /// @notice Full (token0, token1) exercise cost with current == oracle tick.
    function _fee(TokenId id, int24 t) internal view returns (LeftRightSigned) {
        return E.exerciseCost(t, t, id, PositionFactory.posBalance(SIZE, 0, 0));
    }

    /// @notice Composition delta (current - oracle) of leg `leg`, as charged by the engine.
    function _delta(
        TokenId id,
        uint256 leg,
        int24 spot,
        int24 oracle
    ) internal pure returns (int256 d0, int256 d1) {
        LiquidityChunk chunk = PanopticMath.getLiquidityChunk(id, leg, SIZE);
        (uint256 c0, uint256 c1) = Math.getAmountsForLiquidity(spot, chunk);
        (uint256 o0, uint256 o1) = Math.getAmountsForLiquidity(oracle, chunk);
        d0 = int256(c0) - int256(o0);
        d1 = int256(c1) - int256(o1);
    }

    /// @notice token0 fee with current == oracle tick, so the composition-delta term is zero.
    function _fee0(TokenId id, int24 t) internal view returns (int256) {
        return E.exerciseCost(t, t, id, PositionFactory.posBalance(SIZE, 0, 0)).rightSlot();
    }

    /// @notice Closed-form fee rate in DECIMALS units, independent of the contract's code path.
    function _rate(TokenId id, int256 t) internal view returns (int256 fee) {
        (int256 tL, int256 tU) = _bounds(id);
        fee = int256(FLOOR);
        if (t >= tL && t < tU) {
            fee = Math.max(fee, (int256(id.tickSpacing()) * int256(ONE_BPS)) / 2);
            int256 W = tU - tL;
            int256 D = Math.min(t - tL, tU - t);
            int256 ex = (D * D * int256(SHARE)) / (2 * W * 10_000);
            if (ex > int256(SHARE)) ex = int256(SHARE);
            if (ex > fee) fee = ex;
        }
    }

    function _expected0(TokenId id, int256 t) internal view returns (int256) {
        return -(_notional(id) * _rate(id, t)) / int256(DECIMALS);
    }

    /// @notice Mirror of the engine's comparison value: |fee| denominated in the cheaper token at tick `t`
    /// (token0 at or below tick 0, token1 above), each slot converted at the oracle price.
    function _value(int256 fee0, int256 fee1, int24 t) internal pure returns (uint256) {
        uint160 sqrtP = Math.getSqrtRatioAtTick(t);
        if (t > 0) return PanopticMath.convert0to1(uint256(-fee0), sqrtP) + uint256(-fee1);
        return uint256(-fee0) + PanopticMath.convert1to0(uint256(-fee1), sqrtP);
    }

    /// @notice Expected fee for a two-leg position (one leg per token) from the legs' standalone fees:
    /// the lower `_value` wins, the first-listed leg on ties; `token0First` gives the order in the tokenId.
    function _pick(
        int256 fee0,
        int256 fee1,
        int24 t,
        bool token0First
    ) internal pure returns (int256 exp0, int256 exp1) {
        uint256 v0 = _value(fee0, 0, t);
        uint256 v1 = _value(0, fee1, t);
        bool token0Wins = token0First ? v0 <= v1 : v0 < v1;
        if (token0Wins) exp0 = fee0;
        else exp1 = fee1;
    }

    function _bps(int256 fee, int256 notional) internal view returns (int256) {
        // fee is negative; return |fee| / notional in bps, rounded to nearest (the fee itself rounds toward zero)
        return (-fee * 10_000 + notional / 2) / notional;
    }

    /*//////////////////////////////////////////////////////////////
                             EDGES AND FLOOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Out-of-range ticks pay FLOOR; in-range ticks near the edge pay the in-range floor (~fee tier).
    function test_edges_floors() public view {
        TokenId id = _long(POOL_ID, 0, 400); // W = 4000 ticks
        (int256 tL, int256 tU) = _bounds(id);
        int256 n = _notional(id);
        int256 floorFee = -(n * int256(FLOOR)) / int256(DECIMALS);
        int256 inRangeFloorFee = -(n * int256(IN_RANGE_FLOOR)) / int256(DECIMALS);

        assertEq(_fee0(id, int24(tL - 1)), floorFee, "just below lower edge");
        assertEq(_fee0(id, int24(tL)), inRangeFloorFee, "at lower edge (in range)");
        assertEq(_fee0(id, int24(tL + 1)), inRangeFloorFee, "just inside lower edge");
        assertEq(_fee0(id, int24(tU - 1)), inRangeFloorFee, "just inside upper edge");
        assertEq(_fee0(id, int24(tU)), floorFee, "at upper edge (out of range)");
        assertEq(_fee0(id, int24(tU + 1)), floorFee, "just above upper edge");
    }

    /// @notice Far out of range pays exactly the floor (NOTIONAL_FEE bps).
    function test_outOfRange_floor() public view {
        TokenId id = _long(POOL_ID, 0, 400);
        int256 n = _notional(id);
        assertEq(_bps(_fee0(id, -100_000), n), 3, "deep OTM below");
        assertEq(_bps(_fee0(id, 100_000), n), 3, "deep ITM above");
    }

    /*//////////////////////////////////////////////////////////////
                              PEAK AND SHAPE
    //////////////////////////////////////////////////////////////*/

    /// @notice At the strike the fee is SHARE * W/8 bps of notional.
    function test_peak_atStrike_isShareTimesWidthOverEight() public view {
        TokenId id = _long(POOL_ID, 0, 400); // W = 4000 -> W/8 = 500 bps -> 250 bps at 50%
        int256 n = _notional(id);
        int256 fee = _fee0(id, 0);

        int256 expectedBps = (int256(SHARE) * 4000) / (8 * int256(DECIMALS / 10_000) * 10_000);
        assertEq(_bps(fee, n), expectedBps, "peak bps = SHARE * W / 8");
        assertEq(fee, _expected0(id, 0), "matches closed form");
    }

    /// @notice Symmetric around the strike.
    function test_symmetric_aroundStrike() public view {
        TokenId id = _long(POOL_ID, 0, 400);
        for (int24 d = 10; d < 2000; d += 190) {
            assertEq(_fee0(id, d), _fee0(id, -d), "fee(strike + d) == fee(strike - d)");
        }
    }

    /// @notice Strictly increasing from the edge to the strike once above the floor.
    function test_monotonic_edgeToStrike() public view {
        TokenId id = _long(POOL_ID, 0, 400);
        (int256 tL, ) = _bounds(id);
        int256 prev = _fee0(id, int24(tL));
        for (int256 t = tL + 100; t <= 0; t += 100) {
            int256 cur = _fee0(id, int24(t));
            assertLe(cur, prev, "fee magnitude non-decreasing toward the strike");
            prev = cur;
        }
    }

    /// @notice Narrow leg: W/8 bps is below the floors everywhere, so only the floors apply.
    function test_narrowLeg_floorEverywhere() public view {
        TokenId id = _long(POOL_ID, 0, 1); // W = 10 ticks -> peak 1.25 bps * 50% < 3 bp
        int256 n = _notional(id);
        (int256 tL, int256 tU) = _bounds(id);
        for (int256 t = tL - 2; t <= tU + 2; ++t) {
            bool inRange = t >= tL && t < tU;
            assertEq(
                _bps(_fee0(id, int24(t)), n),
                inRange ? int256(IN_RANGE_FLOOR / ONE_BPS) : int256(FLOOR / ONE_BPS),
                "narrow leg pays the applicable floor"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 BOUND
    //////////////////////////////////////////////////////////////*/

    /// @notice For W > 80_000 ticks the quadratic exceeds 100% of notional; the fee is bounded at SHARE.
    function test_bound_veryWideLeg() public view {
        TokenId id = _long(POOL_ID_WIDE, 0, 4000); // W = 800_000 ticks
        (int256 tL, int256 tU) = _bounds(id);
        assertGt(tU - tL, 80_000, "setup: leg must be wide enough to hit the bound");

        int256 n = _notional(id);
        int256 fee = _fee0(id, 0);
        assertEq(fee, -(n * int256(SHARE)) / int256(DECIMALS), "bounded at SHARE of notional");

        // unbounded quadratic would have exceeded the share
        int256 W = tU - tL;
        assertGt(((W / 2) * (W / 2) * int256(SHARE)) / (2 * W * 10_000), int256(SHARE), "setup");
    }

    /*//////////////////////////////////////////////////////////////
                              ORACLE TICK
    //////////////////////////////////////////////////////////////*/

    /// @notice Expected (token0, token1) fees: rate at the oracle tick, minus the (spot - oracle) composition delta.
    function _expectedWithDelta(
        TokenId id,
        int24 spot,
        int24 oracle
    ) internal view returns (int256 exp0, int256 exp1) {
        LiquidityChunk chunk = PanopticMath.getLiquidityChunk(id, 0, SIZE);
        (uint256 c0, uint256 c1) = Math.getAmountsForLiquidity(spot, chunk);
        (uint256 o0, uint256 o1) = Math.getAmountsForLiquidity(oracle, chunk);
        exp0 = _expected0(id, oracle) - (int256(c0) - int256(o0));
        exp1 = -(int256(c1) - int256(o1));
    }

    /// @notice The fee rate is set by the oracle tick, not spot; spot only enters via the composition delta.
    function test_oracleTick_drivesFee() public view {
        TokenId id = _long(POOL_ID, 0, 400);
        (int256 tL, ) = _bounds(id);
        int24 spotOutside = int24(tL - 500);
        PositionBalance pb = PositionFactory.posBalance(SIZE, 0, 0);

        LeftRightSigned got = E.exerciseCost(spotOutside, 0, id, pb);
        (int256 exp0, int256 exp1) = _expectedWithDelta(id, spotOutside, 0);

        assertEq(got.rightSlot(), exp0, "token0: peak fee at oracle tick plus delta");
        assertEq(got.leftSlot(), exp1, "token1: delta only");

        // the same spot with the oracle also outside would pay just the floor
        LeftRightSigned floor = E.exerciseCost(spotOutside, spotOutside, id, pb);
        assertEq(_bps(floor.rightSlot(), _notional(id)), 3, "oracle outside -> floor");
    }

    /*//////////////////////////////////////////////////////////////
                           LEG FILTERING / SUMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Short legs and width-0 legs contribute nothing.
    function test_shortAndLoanLegs_ignored() public view {
        PositionBalance pb = PositionFactory.posBalance(SIZE, 0, 0);
        TokenId shortLeg = PositionFactory.makeLeg(POOL_ID, 0, 1, 0, 0, 0, 0, 0, 400);
        TokenId credit = PositionFactory.makeLeg(POOL_ID, 0, 1, 0, 1, 0, 0, 0, 0);
        assertEq(LeftRightSigned.unwrap(E.exerciseCost(0, 0, shortLeg, pb)), 0, "short leg");
        assertEq(LeftRightSigned.unwrap(E.exerciseCost(0, 0, credit, pb)), 0, "credit leg");
    }

    /// @notice Two long legs: only the cheaper one is charged, at its own rate; the fees are not summed.
    function test_twoLegs_cheapestLegFee() public view {
        TokenId a = _long(POOL_ID, 0, 400); // wide, in range at t = 0 (peak rate)
        TokenId b = _long(POOL_ID, 5000, 20); // narrow, out of range at t = 0 (floor rate)
        TokenId both = TokenId.wrap(0).addPoolId(POOL_ID).addLeg(0, 1, 0, 1, 0, 0, 0, 400).addLeg(
            1,
            1,
            0,
            1,
            0,
            1,
            5000,
            20
        );
        assertEq(_fee0(both, 0), _fee0(b, 0), "cheapest leg's fee only");
        assertEq(_fee0(both, 0), _expected0(b, 0), "matches closed form for the narrow leg");
        assertTrue(_fee0(both, 0) != _fee0(a, 0) + _fee0(b, 0), "per-leg fees must not add");
    }

    /// @notice Bundling wide legs at the strike next to a narrow leg does not raise the fee above the narrow leg's.
    function test_bundledWideLegs_doNotRaiseFee() public view {
        TokenId narrow = _long(POOL_ID, 0, 24); // W = 240 ticks
        TokenId wide = _long(POOL_ID, 0, 4000); // W = 40_000 ticks -> 2500 bps at the strike

        // narrow leg first, then three wide legs on distinct chunks, all centered at the strike
        TokenId bundle = TokenId
            .wrap(0)
            .addPoolId(POOL_ID)
            .addLeg(0, 1, 0, 1, 0, 0, 0, 24)
            .addLeg(1, 1, 0, 1, 0, 1, 0, 4000)
            .addLeg(2, 1, 0, 1, 0, 2, 0, 3990)
            .addLeg(3, 1, 0, 1, 0, 3, 0, 3980);

        int256 bundleFee = _fee0(bundle, 0);
        assertEq(bundleFee, _fee0(narrow, 0), "bundle pays the narrow leg's fee");
        assertEq(bundleFee, _expected0(narrow, 0), "matches closed form for the narrow leg");
        assertGt(-_fee0(wide, 0), -bundleFee, "a lone wide leg at the strike would have cost more");

        // the narrow leg wins regardless of its position in the leg list
        TokenId bundleLast = TokenId
            .wrap(0)
            .addPoolId(POOL_ID)
            .addLeg(0, 1, 0, 1, 0, 0, 0, 4000)
            .addLeg(1, 1, 0, 1, 0, 1, 0, 3990)
            .addLeg(2, 1, 0, 1, 0, 2, 0, 3980)
            .addLeg(3, 1, 0, 1, 0, 3, 0, 24);
        assertEq(_fee0(bundleLast, 0), bundleFee, "leg order does not matter");
    }

    /// @notice Equal widths: the cheaper leg is charged whichever one is listed first.
    function test_ties_cheaperLegCharged() public view {
        TokenId otm = _long(POOL_ID, 5000, 400); // out of range at t = 0 (floor rate)
        TokenId atm = _long(POOL_ID, 0, 400); // at its strike (peak rate)
        TokenId otmFirst = TokenId
            .wrap(0)
            .addPoolId(POOL_ID)
            .addLeg(0, 1, 0, 1, 0, 0, 5000, 400)
            .addLeg(1, 1, 0, 1, 0, 1, 0, 400);
        TokenId atmFirst = TokenId
            .wrap(0)
            .addPoolId(POOL_ID)
            .addLeg(0, 1, 0, 1, 0, 0, 0, 400)
            .addLeg(1, 1, 0, 1, 0, 1, 5000, 400);
        assertEq(_fee0(otmFirst, 0), _fee0(otm, 0), "cheaper leg charged (listed first)");
        assertEq(_fee0(atmFirst, 0), _fee0(otm, 0), "cheaper leg charged (listed second)");
        assertGt(-_fee0(atm, 0), -_fee0(otm, 0), "setup: the at-the-money leg is dearer");
    }

    /// @notice A same-width leg with `optionRatio` 127 at its strike, listed first, must not set the fee:
    /// the blocking leg (ratio 1, out of range) pays its own honest floor fee.
    function test_padding_sameWidthRatio127First_blockingLegFee() public view {
        TokenId blocking = _long(POOL_ID, 5000, 60); // W = 600, out of range at t = 0
        TokenId padded = PositionFactory.makeLeg(POOL_ID, 0, 127, 0, 1, 0, 0, 0, 60); // at its strike
        TokenId both = TokenId.wrap(0).addPoolId(POOL_ID).addLeg(0, 127, 0, 1, 0, 0, 0, 60).addLeg(
            1,
            1,
            0,
            1,
            0,
            1,
            5000,
            60
        );

        int256 honest = _fee0(blocking, 0);
        assertEq(_fee0(both, 0), honest, "blocking leg's fee, not the padded leg's");
        assertEq(_bps(honest, _notional(blocking)), 3, "honest fee is the floor");
        // the padded leg alone would have cost far more than the blocking leg's notional allows
        assertGt(-_fee0(padded, 0), -honest * 1000, "setup: padded leg is >1000x the honest fee");
    }

    /// @notice A narrower leg with `optionRatio` 127 on an out-of-range chunk must not set the fee either:
    /// its floor-rate fee on 127x notional exceeds the blocking leg's honest fee, in or out of range.
    function test_padding_narrowerRatio127_blockingLegFee() public view {
        TokenId blocking = _long(POOL_ID, 0, 60); // W = 600
        TokenId both = TokenId.wrap(0).addPoolId(POOL_ID).addLeg(0, 1, 0, 1, 0, 0, 0, 60).addLeg(
            1,
            127,
            0,
            1,
            0,
            1,
            5000,
            30
        ); // narrower, out of range, 127x notional
        TokenId bothReversed = TokenId
            .wrap(0)
            .addPoolId(POOL_ID)
            .addLeg(0, 127, 0, 1, 0, 0, 5000, 30)
            .addLeg(1, 1, 0, 1, 0, 1, 0, 60);

        // blocking leg at its strike (peak rate) and out of range (floor rate)
        int24[2] memory ticks = [int24(0), int24(-5000)];
        for (uint256 k = 0; k < ticks.length; ++k) {
            int256 honest = _fee0(blocking, ticks[k]);
            assertEq(_fee0(both, ticks[k]), honest, "blocking leg's fee (padded leg second)");
            assertEq(
                _fee0(bothReversed, ticks[k]),
                honest,
                "blocking leg's fee (padded leg first)"
            );
        }
        assertEq(_bps(_fee0(blocking, -5000), _notional(blocking)), 3, "setup: floor out of range");
        assertGt(
            -_fee0(blocking, 0),
            -_fee0(blocking, -5000),
            "setup: dearer at the strike than out of range"
        );
    }

    /// @notice Legs on both tokens: the fee charged is the cheaper leg's, compared at the oracle price.
    function test_crossToken_cheaperLegByValue() public view {
        // token0 leg out of range (floor rate) vs. narrower token1 leg at its strike (peak rate)
        TokenId otm0 = _long(POOL_ID, 5000, 400);
        TokenId atm1 = _long1(POOL_ID, 0, 100);
        TokenId both = TokenId
            .wrap(0)
            .addPoolId(POOL_ID)
            .addLeg(0, 1, 0, 1, 0, 0, 5000, 400)
            .addLeg(1, 1, 0, 1, 1, 1, 0, 100);
        int256 fee0 = _fee0(otm0, 0);
        int256 fee1 = -(_notional1(atm1) * _rate(atm1, 0)) / int256(DECIMALS);
        uint256 value0 = _value(fee0, 0, 0);
        uint256 value1 = _value(0, fee1, 0);
        assertTrue(value0 != value1, "setup: legs differ in value");

        LeftRightSigned got = _fee(both, 0);
        if (value0 < value1) {
            assertEq(got.rightSlot(), fee0, "token0 leg is cheaper and charged");
            assertEq(got.leftSlot(), 0, "token1 leg not charged");
        } else {
            assertEq(got.leftSlot(), fee1, "token1 leg is cheaper and charged");
            assertEq(got.rightSlot(), 0, "token0 leg not charged");
        }
    }

    /// @notice Legs on both tokens: at each oracle tick the leg with the lower fee value (in the cheaper token at that
    /// tick) is charged in its own token; the other token pays nothing. Which leg that is depends on the price.
    function test_crossToken_cheaperLegAtEachTick() public view {
        TokenId wide0 = _long(POOL_ID, 0, 400); // token0, W = 4000
        TokenId narrow1 = _long1(POOL_ID, 0, 20); // token1, W = 200

        TokenId both = TokenId.wrap(0).addPoolId(POOL_ID).addLeg(0, 1, 0, 1, 0, 0, 0, 400).addLeg(
            1,
            1,
            0,
            1,
            1,
            1,
            0,
            20
        );

        int24[3] memory ticks = [int24(0), int24(50_000), int24(-50_000)];
        bool sawToken0;
        bool sawToken1;
        for (uint256 k = 0; k < ticks.length; ++k) {
            LeftRightSigned got = _fee(both, ticks[k]);
            int256 fee0 = _fee0(wide0, ticks[k]);
            int256 fee1 = -(_notional1(narrow1) * _rate(narrow1, ticks[k])) / int256(DECIMALS);
            uint256 value0 = _value(fee0, 0, ticks[k]);
            uint256 value1 = _value(0, fee1, ticks[k]);
            assertTrue(value0 != value1, "setup: legs differ in value");
            if (value0 < value1) {
                sawToken0 = true;
                assertEq(got.rightSlot(), fee0, "token0 leg is cheaper and charged");
                assertEq(got.leftSlot(), 0, "token1 leg not charged");
            } else {
                sawToken1 = true;
                assertEq(got.leftSlot(), fee1, "token1 leg is cheaper and charged");
                assertEq(got.rightSlot(), 0, "token0 leg not charged");
            }
        }
        assertTrue(sawToken0 && sawToken1, "setup: the cheaper leg changes with the price");
    }

    /// @notice The composition delta is still reversed for every long leg, while only the cheapest leg pays the fee.
    function test_compositionDelta_sumsAllLegs() public view {
        TokenId a = _long(POOL_ID, 0, 400); // wide
        TokenId b = _long(POOL_ID, 0, 20); // narrow
        TokenId both = TokenId.wrap(0).addPoolId(POOL_ID).addLeg(0, 1, 0, 1, 0, 0, 0, 400).addLeg(
            1,
            1,
            0,
            1,
            0,
            1,
            0,
            20
        );
        PositionBalance pb = PositionFactory.posBalance(SIZE, 0, 0);

        int24 oracle = 0;
        int24 spot = -300; // inside the wide leg, below the narrow one

        LeftRightSigned got = E.exerciseCost(spot, oracle, both, pb);

        (int256 dA0, int256 dA1) = _delta(both, 0, spot, oracle);
        (int256 dB0, int256 dB1) = _delta(both, 1, spot, oracle);

        assertEq(
            got.rightSlot(),
            _expected0(b, oracle) - dA0 - dB0,
            "token0: narrow fee minus both deltas"
        );
        assertEq(got.leftSlot(), -dA1 - dB1, "token1: both deltas only");
        assertTrue(dA0 != 0 && dA1 != 0, "setup: wide leg has a non-zero delta");
        assertTrue(_notional(a) != 0, "setup");
    }

    /*//////////////////////////////////////////////////////////////
                       COMPARISON DENOMINATION
    //////////////////////////////////////////////////////////////*/

    // The helpers below take a packed `a` = [t, strike0, strike1, ratio0, ratio1, size, asset, w0, w1] (to stay
    // under the stack limit) describing a pair of long legs: a token0 call (ratio0, strike0, w0) and a token1 put
    // (ratio1, strike1, w1), both sized in `asset`, evaluated at tick `t` with current == oracle.

    function _packed(
        int24 t,
        int24[2] memory strikes,
        uint256[2] memory ratios,
        uint128 size,
        uint256 asset,
        int24[2] memory widths
    ) internal pure returns (int256[9] memory a) {
        a[0] = t;
        a[1] = strikes[0];
        a[2] = strikes[1];
        a[3] = int256(ratios[0]);
        a[4] = int256(ratios[1]);
        a[5] = int256(uint256(size));
        a[6] = int256(asset);
        a[7] = widths[0];
        a[8] = widths[1];
    }

    function _pb(int256[9] memory a) internal pure returns (PositionBalance) {
        return PositionFactory.posBalance(uint128(uint256(a[5])), 0, 0);
    }

    /// @notice The pair as one tokenId, in the order given by `token0First`.
    function _pair(int256[9] memory a, bool token0First) internal pure returns (TokenId id) {
        id = TokenId.wrap(0).addPoolId(POOL_ID);
        uint256 i0 = token0First ? 0 : 1; // index of the token0 leg
        uint256 i1 = 1 - i0; // index of the token1 leg
        id = id.addLeg(i0, uint256(a[3]), uint256(a[6]), 1, 0, i0, int24(a[1]), int24(a[7]));
        id = id.addLeg(i1, uint256(a[4]), uint256(a[6]), 1, 1, i1, int24(a[2]), int24(a[8]));
    }

    /// @notice Standalone fees of the two legs: the token0 leg's in `fee0`, the token1 leg's in `fee1` (negative).
    function _legFees(int256[9] memory a) internal view returns (int256 fee0, int256 fee1) {
        TokenId leg0 = TokenId.wrap(0).addPoolId(POOL_ID);
        leg0 = leg0.addLeg(0, uint256(a[3]), uint256(a[6]), 1, 0, 0, int24(a[1]), int24(a[7]));
        TokenId leg1 = TokenId.wrap(0).addPoolId(POOL_ID);
        leg1 = leg1.addLeg(0, uint256(a[4]), uint256(a[6]), 1, 1, 0, int24(a[2]), int24(a[8]));
        fee0 = E.exerciseCost(int24(a[0]), int24(a[0]), leg0, _pb(a)).rightSlot();
        fee1 = E.exerciseCost(int24(a[0]), int24(a[0]), leg1, _pb(a)).leftSlot();
    }

    /// @notice Asserts the engine charges exactly (`exp0`, `exp1`) for the pair with the given leg order.
    function _assertPairCharges(
        int256[9] memory a,
        bool token0First,
        int256 exp0,
        int256 exp1
    ) internal view {
        LeftRightSigned got = E.exerciseCost(
            int24(a[0]),
            int24(a[0]),
            _pair(a, token0First),
            _pb(a)
        );
        assertEq(
            got.rightSlot(),
            exp0,
            token0First ? "token0 first: token0 slot" : "token1 first: token0 slot"
        );
        assertEq(
            got.leftSlot(),
            exp1,
            token0First ? "token0 first: token1 slot" : "token1 first: token1 slot"
        );
    }

    /// @notice Deep negative tick: token0 is the cheaper token, so legs are compared in token0. Compared in token1 the
    /// token0 leg's fee would truncate onto the token1 leg's (a tie, won by the first-listed leg) even though the
    /// token1 leg is ~6% cheaper; compared in token0 the engine sees the difference and charges the token1 leg
    /// whichever leg is listed first.
    function test_crossToken_deepNegativeTick_comparedInToken0() public view {
        int24 t = -200_000;
        // sized in token0: 4x token0 call out of range (floor rate); width-20 token1 put centred on the oracle tick (peak rate)
        int256[9] memory a = _packed(t, [int24(0), t], [uint256(4), 1], 3e12, 0, [int24(400), 20]);
        (int256 fee0, int256 fee1) = _legFees(a);
        uint160 sqrtP = Math.getSqrtRatioAtTick(t);

        // setup: in token1 the two fees are indistinguishable; in token0 the token1 leg is cheaper
        assertEq(
            PanopticMath.convert0to1(uint256(-fee0), sqrtP),
            uint256(-fee1),
            "setup: token1-denominated values tie"
        );
        uint256 fee1InToken0 = PanopticMath.convert1to0(uint256(-fee1), sqrtP);
        assertLt(
            fee1InToken0 * 100,
            uint256(-fee0) * 95,
            "setup: token1 leg >5% cheaper in token0"
        );

        _assertPairCharges(a, true, 0, fee1);
        _assertPairCharges(a, false, 0, fee1);
    }

    /// @notice Deep positive tick: the mirror image (tokens swapped, legs sized in token1). token1 is the cheaper
    /// token, so legs are compared in token1; compared in token0 the token1 leg's fee would truncate onto the
    /// token0 leg's.
    function test_crossToken_deepPositiveTick_comparedInToken1() public view {
        int24 t = 200_000;
        // sized in token1: width-20 token0 call centred on the oracle tick (peak rate); 4x token1 put out of range (floor rate)
        int256[9] memory a = _packed(t, [t, int24(0)], [uint256(1), 4], 3e12, 1, [int24(20), 400]);
        (int256 fee0, int256 fee1) = _legFees(a);
        uint160 sqrtP = Math.getSqrtRatioAtTick(t);

        assertEq(
            PanopticMath.convert1to0(uint256(-fee1), sqrtP),
            uint256(-fee0),
            "setup: token0-denominated values tie"
        );
        uint256 fee0InToken1 = PanopticMath.convert0to1(uint256(-fee0), sqrtP);
        assertLt(
            fee0InToken1 * 100,
            uint256(-fee1) * 95,
            "setup: token0 leg >5% cheaper in token1"
        );

        _assertPairCharges(a, true, fee0, 0);
        _assertPairCharges(a, false, fee0, 0);
    }

    /// @notice Tick 0 takes the token0 branch (price 1: the two denominations agree and the branch must not revert).
    function test_crossToken_tickZero_token0Branch() public view {
        // token0 leg out of range (floor rate) vs. token1 leg at its strike (peak rate)
        int256[9] memory a = _packed(
            0,
            [int24(5000), 0],
            [uint256(1), 1],
            SIZE,
            0,
            [int24(400), 100]
        );
        (int256 fee0, int256 fee1) = _legFees(a);
        assertEq(_value(fee0, 0, 0), uint256(-fee0), "token0 slot passes through at tick 0");
        assertEq(_value(0, fee1, 0), uint256(-fee1), "token1 slot converts 1:1 at tick 0");
        assertTrue(_value(fee0, 0, 0) != _value(0, fee1, 0), "setup: legs differ in value");
        (int256 exp0, int256 exp1) = _pick(fee0, fee1, 0, true);
        _assertPairCharges(a, true, exp0, exp1);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice Anywhere in or out of range, the fee matches the closed form and stays within [floor, SHARE].
    function testFuzz_matchesClosedForm_andBounded(int24 t, uint16 widthSeed) public view {
        int24 width = int24(uint24(bound(widthSeed, 1, 4000)));
        TokenId id = _long(POOL_ID, 0, width);
        (int256 tL, int256 tU) = _bounds(id);
        t = int24(bound(t, tL - 1000, tU + 1000));

        int256 fee = _fee0(id, t);
        int256 n = _notional(id);

        assertEq(fee, _expected0(id, t), "closed form");
        assertLe(-fee, (n * int256(SHARE)) / int256(DECIMALS), "never above SHARE of notional");
        assertGe(-fee, (n * int256(FLOOR)) / int256(DECIMALS), "never below the floor");
    }

    /// @notice One long leg per token, anywhere in the tick range: the engine charges exactly the leg the
    /// cheaper-token comparison selects (the first one on ties), in both leg orders, and never reverts converting
    /// at extreme prices.
    function testFuzz_crossToken_pickMatchesCheaperTokenComparison(
        int24 t,
        int24 strike0,
        int24 strike1,
        uint8 ratio0,
        uint8 ratio1,
        uint128 size
    ) public view {
        // the top bit of `ratio0` picks the asset the legs are sized in
        int256[9] memory a = _packed(
            int24(bound(t, -800_000, 800_000)),
            [
                int24((bound(strike0, -400_000, 400_000) / TS) * TS),
                int24((bound(strike1, -400_000, 400_000) / TS) * TS)
            ],
            [bound(ratio0 & 0x7f, 1, 127), bound(ratio1, 1, 127)],
            uint128(bound(size, 1e6, 1e18)),
            ratio0 >> 7,
            [int24(400), 100]
        );
        (int256 fee0, int256 fee1) = _legFees(a);
        vm.assume(fee0 < 0 && fee1 < 0);

        for (uint256 k = 0; k < 2; ++k) {
            (int256 exp0, int256 exp1) = _pick(fee0, fee1, int24(a[0]), k == 0);
            _assertPairCharges(a, k == 0, exp0, exp1);
        }
    }
}
