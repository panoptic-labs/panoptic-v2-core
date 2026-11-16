// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RiskEngineHarness} from "./RiskEngineHarness.sol";
import {RiskEngineParams} from "../../testUtils/RiskEngineParams.sol";
import {OraclePack, OraclePackLibrary} from "@types/OraclePack.sol";
import {RiskParameters} from "@types/RiskParameters.sol";

contract RiskEngineSafeModeAndOracle is Test {
    RiskEngineHarness internal E;

    function setUp() public {
        E = new RiskEngineHarness(
            2_000_000,
            1_000_000,
            1_000,
            5_000_000,
            9_000_000,
            5_000_000,
            5_000_000
        );
    }

    function _packEMAs(
        int24 slow,
        int24 fast,
        int24 spot,
        int24 median
    ) internal pure returns (OraclePack) {
        // Zero residuals make the median equal to the reference tick.
        return
            OraclePackLibrary.storeOraclePack(
                0,
                0,
                OraclePackLibrary.packEMAs(spot, fast, slow, 0),
                median,
                0,
                0,
                0
            );
    }

    function test_SafeMode_flags_trip_independently() public view {
        int24 K = int24(RiskEngineParams.blueChip().maxTicksDelta);
        // external shock only
        OraclePack p1 = _packEMAs(0, 0, 0, 0);
        uint8 s1 = E.isSafeMode(int24(K + 1), p1);
        assertEq(s1, 1, "external shock only");

        // internal disagreement only: |spot - fast| > K/2
        OraclePack p2 = _packEMAs(0, int24(0), int24(K / 2 + 1), 0);
        uint8 s2 = E.isSafeMode(0, p2);
        assertEq(s2, 1, "internal disagreement only");

        // high divergence only: |median - slow| > K/2
        OraclePack p3 = _packEMAs(int24(0), 0, 0, int24(K / 2 + 1));
        uint8 s3 = E.isSafeMode(0, p3);
        assertEq(s3, 1, "high divergence only");

        // combo: all three ordinary conditions true
        OraclePack p4 = _packEMAs(int24(0), int24(K / 2 + 1), int24(0), int24(K / 2 + 1));
        uint8 s4 = E.isSafeMode(int24(K + 1), p4);
        assertEq(s4, 3, "sum of flags");
    }

    function test_SafeMode_shock_thresholds() public view {
        int24 K = int24(RiskEngineParams.blueChip().maxTicksDelta);
        int24[6] memory deltas = [K - 1, K, K + 1, 2 * K - 1, 2 * K, 2 * K + 1];
        uint8[6] memory expected = [uint8(0), 0, 1, 1, 1, 3];

        for (int24 direction = -1; direction <= 1; direction += 2) {
            int24 spot = direction * 10_000;
            OraclePack pack = _packEMAs(spot, spot, spot, spot);
            assertEq(pack.lockMode(), 0, "signed ticks must not set the guardian lock");
            assertEq(E.isSafeMode(spot, pack), 0, "aligned oracle");

            for (uint256 i; i < deltas.length; ++i) {
                assertEq(
                    E.isSafeMode(spot + direction * deltas[i], pack),
                    expected[i],
                    "shock threshold"
                );
            }
        }
    }

    function test_SafeMode_severeShock_combines_with_flags_and_lock() public view {
        int24 K = int24(RiskEngineParams.blueChip().maxTicksDelta);
        int24 spot = 10_000;
        RiskParameters normal = E.getRiskParameters(spot, _packEMAs(spot, spot, spot, spot), 0);

        // Exercise all combinations of internal disagreement, divergence and guardian lock.
        for (uint8 flags; flags < 8; ++flags) {
            uint8 disagreement = flags & 1;
            uint8 divergence = (flags >> 1) & 1;
            uint8 lockMode = (flags & 4) != 0 ? 3 : 0;
            OraclePack pack = _packEMAs(
                spot,
                spot + int24(uint24(disagreement)) * (K / 2 + 1),
                spot,
                spot + int24(uint24(divergence)) * (K / 2 + 1)
            );
            if (lockMode != 0) pack = pack.lock();

            uint8 otherFlags = disagreement + divergence + lockMode;
            assertEq(E.isSafeMode(spot, pack), otherFlags, "ordinary flags remain additive");
            for (int24 direction = -1; direction <= 1; direction += 2) {
                assertEq(
                    E.isSafeMode(spot + direction * 2 * K, pack),
                    1 + otherFlags,
                    "exactly twice the threshold is not severe"
                );
                int24 currentTick = spot + direction * (2 * K + 1);
                assertEq(E.isSafeMode(currentTick, pack), 3 + otherFlags, "severe shock adds two");

                RiskParameters severe = E.getRiskParameters(currentTick, pack, 0);
                assertEq(severe.safeMode(), 3 + otherFlags, "pool receives the full safe mode");
                assertEq(
                    RiskParameters.unwrap(severe) >> 4,
                    RiskParameters.unwrap(normal) >> 4,
                    "safe mode must not change other risk parameters"
                );
            }
        }
    }

    function test_SafeMode_severeShock_uses_spotEMA() public view {
        int24 delta = 2 * int24(RiskEngineParams.blueChip().maxTicksDelta) + 1;
        int24 spot = 10_000;
        for (int24 direction = -1; direction <= 1; direction += 2) {
            int24 median = spot + direction * delta;
            OraclePack pack = _packEMAs(median, spot, spot, median);
            assertEq(
                E.isSafeMode(median, pack),
                3,
                "spot shock despite current tick matching median"
            );
            assertEq(E.isSafeMode(spot, pack), 0, "median distance alone is not a spot shock");
        }
    }

    function testFuzz_SafeMode_severeShock_with_aligned_oracles(
        int24 spot,
        int24 delta,
        bool down
    ) public view {
        spot = int24(bound(int256(spot), -787_272, 787_272));
        delta = int24(
            bound(int256(delta), 2 * RiskEngineParams.blueChip().maxTicksDelta + 1, 100_000)
        );
        OraclePack pack = _packEMAs(spot, spot, spot, spot);
        int24 currentTick = down ? spot - delta : spot + delta;
        assertEq(E.isSafeMode(currentTick, pack), 3, "severe shock alone reaches level three");
    }

    function test_getSolvencyTicks_switches_mode_on_3D_norm() public view {
        int24 cur = 0;
        // small deltas -> one tick only, spotTick
        {
            (int24[] memory ticksSmall, ) = E.getSolvencyTicks(cur, _packEMAs(0, 0, 1, 0), 0);
            assertEq(ticksSmall.length, 1, "normal mode = 1 tick");
        }
        // large 3D deviation -> 4 ticks
        {
            // make vector squared norm exceed MAX_TICKS_DELTA^2 by spreading across components
            int24 spot = 4000;
            int24 med = 0;
            int24 latest = -4000;
            (int24[] memory ticksLarge, ) = E.getSolvencyTicks(cur, _packEMAs(0, 0, spot, med), 0);
            // Note: your PanopticMath.getOracleTicks may compute latest internally; force via spot/median/current spread
            assertEq(ticksLarge.length, 4, "conservative mode = 4 ticks");
        }
        {
            uint8 safeMode = 1;
            // make vector squared norm exceed MAX_TICKS_DELTA^2 by spreading across components
            (int24[] memory ticksLarge, ) = E.getSolvencyTicks(
                cur,
                _packEMAs(0, 0, 1, 0),
                safeMode
            );
            // Note: your PanopticMath.getOracleTicks may compute latest internally; force via spot/median/current spread
            assertEq(ticksLarge.length, 4, "conservative mode = 4 ticks");
        }
    }

    /// @notice In a calm market whose current tick sits at least the band (`BUYER_COLLATERAL_RATIO / ONE_BPS`)
    /// from spot, the current tick is checked with spot: `isAccountSolvent` skips the collateral test of an account
    /// owing long premium at a tick that far from the current tick, so spot alone would let it pass without buffer.
    function test_getSolvencyTicks_addsCurrentTickOutsideBand() public view {
        int24 band = int24(int256(E.buyerCollateralRatioParam() / 1000));
        OraclePack pack = _packEMAs(0, 0, 0, 0);

        (int24[] memory inside, ) = E.getSolvencyTicks(band - 1, pack, 0);
        assertEq(inside.length, 1, "inside the band: spot only");
        (inside, ) = E.getSolvencyTicks(1 - band, pack, 0);
        assertEq(inside.length, 1, "inside the band below: spot only");

        int24[2] memory edges = [band, -band];
        for (uint256 i; i < 2; ++i) {
            (int24[] memory outside, ) = E.getSolvencyTicks(edges[i], pack, 0);
            assertEq(outside.length, 2, "at the band: spot and current");
            assertEq(outside[0], int24(0), "spot first");
            assertEq(outside[1], edges[i], "then the current tick");
        }

        // past the deviation norm the four-tick check still applies
        int24 far = int24(RiskEngineParams.blueChip().maxTicksDelta) + 1;
        (int24[] memory four, ) = E.getSolvencyTicks(far, pack, 0);
        assertEq(four.length, 4, "beyond the norm: all four ticks");
    }
}
