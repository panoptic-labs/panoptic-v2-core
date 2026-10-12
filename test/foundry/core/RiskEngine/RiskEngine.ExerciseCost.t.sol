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

/// @notice Pins the per-leg extrinsic-value force-exercise fee in `exerciseCost`.
/// @dev fee(t) = FORCE_EXERCISE_COST * D^2 / (2W) bps of the leg's notional, D = distance to the nearer range edge,
/// floored at NOTIONAL_FEE bps out of range and at max(NOTIONAL_FEE, tickSpacing / 2) bps in range (~the pool fee
/// tier), bounded at FORCE_EXERCISE_COST, evaluated at the oracle tick.
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

    function _notional(TokenId id) internal pure returns (int256) {
        (LeftRightSigned longs, ) = PanopticMath.calculateIOAmounts(id, SIZE, 0, true);
        return longs.rightSlot();
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

    /// @notice Two long legs pay the sum of their individual fees, each at its own rate.
    function test_twoLegs_sumOfPerLegFees() public view {
        TokenId a = _long(POOL_ID, 0, 400); // wide, in range at t = 0
        TokenId b = _long(POOL_ID, 5000, 20); // narrow, out of range at t = 0
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
        assertEq(_fee0(both, 0), _fee0(a, 0) + _fee0(b, 0), "per-leg fees add");
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
}
