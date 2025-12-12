// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RiskEngineHarness} from "./RiskEngineHarness.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {OraclePack} from "@types/OraclePack.sol";

contract RiskEngineSafeModeAndOracle is Test {
    RiskEngineHarness internal E;

    uint256 internal constant BITMASK_UINT22 = 0x3FFFFF;

    function setUp() public {
        E = new RiskEngineHarness(5_000_000, 5_000_000);
    }

    function _packEMAs(
        int24 slow,
        int24 fast,
        int24 spot,
        int24 median
    ) internal pure returns (OraclePack) {
        // PanopticMath.getEMAs(oraclePack) returns (, slow, fast, spot, median)
        // Use PanopticMath helpers if exposed; otherwise mirror your packing here.
        // For now assume PanopticMath has a pack helper in your codebase; if not, stub as needed.
        uint256 updatedEMAs = (uint256(uint24(spot)) & BITMASK_UINT22) +
            ((uint256(uint24(fast)) & BITMASK_UINT22) << 22) +
            ((uint256(uint24(slow)) & BITMASK_UINT22) << 44);

        // store median as referenceTick
        return OraclePack.wrap((updatedEMAs << 120) + (uint256(uint24(median)) << 96));
    }

    function test_SafeMode_flags_trip_independently() public {
        int24 K = 953; // MAX_TICKS_DELTA in your config, adjust if needed via public const
        // external shock only
        OraclePack p1 = _packEMAs(0, 0, 0, 0);
        uint8 s1 = E.isSafeMode(int24(K + 1), p1);
        assertEq(s1, 1, "external shock only");

        // internal disagreement only: |spot - fast| > K/2
        OraclePack p2 = _packEMAs(0, int24(0), int24(K / 2 + 1), 0);
        uint8 s2 = E.isSafeMode(0, p2);
        assertEq(s2, 1, "internal disagreement only");

        // high divergence only: |median - slow| > 2K
        OraclePack p3 = _packEMAs(int24(0), 0, 0, int24(2 * K + 1));
        uint8 s3 = E.isSafeMode(0, p3);
        assertEq(s3, 1, "high divergence only");

        // combo: two conditions true
        OraclePack p4 = _packEMAs(int24(0), int24(K / 2 + 1), int24(0), int24(2 * K + 1));
        uint8 s4 = E.isSafeMode(int24(K + 1), p4);
        assertEq(s4, 3, "sum of flags");
    }

    function test_getSolvencyTicks_switches_mode_on_3D_norm() public {
        int24 cur = 0;
        // small deltas -> one tick only, spotTick
        {
            (int24[] memory ticksSmall, ) = E.getSolvencyTicks(cur, _packEMAs(0, 0, 1, 0));
            assertEq(ticksSmall.length, 1, "normal mode = 1 tick");
        }
        // large 3D deviation -> 4 ticks
        {
            // make vector squared norm exceed MAX_TICKS_DELTA^2 by spreading across components
            int24 spot = 4000;
            int24 med = 0;
            int24 latest = -4000;
            (int24[] memory ticksLarge, ) = E.getSolvencyTicks(cur, _packEMAs(0, 0, spot, med));
            // Note: your PanopticMath.getOracleTicks may compute latest internally; force via spot/median/current spread
            assertEq(ticksLarge.length, 4, "conservative mode = 4 ticks");
        }
    }
}
