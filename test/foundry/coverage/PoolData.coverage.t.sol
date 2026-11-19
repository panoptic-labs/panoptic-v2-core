// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolData, PoolDataLibrary} from "@types/PoolData.sol";

/// @notice Fills the coverage gaps left in `contracts/types/PoolData.sol` by the rest of the suite:
/// the `_initialized == false` arm of the ternary in `storePoolData`.
contract PoolDataCoverageTest is Test {
    function test_storePoolData_uninitialized(
        uint128 maxLiquidityPerTick,
        uint64 poolId,
        int24 minEnforcedTick,
        int24 maxEnforcedTick
    ) public pure {
        PoolData data = PoolDataLibrary.storePoolData(
            maxLiquidityPerTick,
            poolId,
            minEnforcedTick,
            maxEnforcedTick,
            false
        );

        assertEq(data.maxLiquidityPerTick(), maxLiquidityPerTick, "maxLiquidityPerTick");
        assertEq(data.poolId(), poolId, "poolId");
        assertEq(data.minEnforcedTick(), minEnforcedTick, "minEnforcedTick");
        assertEq(data.maxEnforcedTick(), maxEnforcedTick, "maxEnforcedTick");
        assertFalse(data.initialized(), "initialized");
        // nothing is stored above the 240-bit payload when the flag is unset
        assertEq(PoolData.unwrap(data) >> 240, 0, "upper bits");
    }

    function test_storePoolData_initialized(
        uint128 maxLiquidityPerTick,
        uint64 poolId,
        int24 minEnforcedTick,
        int24 maxEnforcedTick
    ) public pure {
        PoolData data = PoolDataLibrary.storePoolData(
            maxLiquidityPerTick,
            poolId,
            minEnforcedTick,
            maxEnforcedTick,
            true
        );

        assertEq(data.maxLiquidityPerTick(), maxLiquidityPerTick, "maxLiquidityPerTick");
        assertEq(data.poolId(), poolId, "poolId");
        assertEq(data.minEnforcedTick(), minEnforcedTick, "minEnforcedTick");
        assertEq(data.maxEnforcedTick(), maxEnforcedTick, "maxEnforcedTick");
        assertTrue(data.initialized(), "initialized");
        assertEq(PoolData.unwrap(data) >> 240, 1, "upper bits");
    }
}
