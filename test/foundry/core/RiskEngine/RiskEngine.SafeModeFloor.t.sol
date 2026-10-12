// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RiskEngineHarness} from "./RiskEngineHarness.sol";
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {TokenId} from "@types/TokenId.sol";
import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";
import {PositionFactory} from "./helpers/PositionFactory.sol";

/// @title Safe-mode utilization floor pins
/// @notice In safe mode the pool overwrites index 0 of the position list with a sentinel (100%/100% utilization,
///         zero block and timestamp). `_getGlobalUtilization` skips that entry and floors the account-wide
///         maximum at SAFE_MODE_UTIL_FLOOR, so the cross-buffer ramp is already partly engaged. Per-position
///         requirements are unaffected; the sentinel is priced like any other entry.
contract RiskEngineSafeModeFloor is Test {
    RiskEngineHarness internal E;

    uint64 constant POOL_ID = 1 + (10 << 48);
    uint128 constant SIZE = 1e12;
    uint16 constant MAX_UTIL = 10_000;
    uint16 constant FLOOR_BPS = 9_100; // SATURATED (90%) + (100% - 90%) / 10

    LeftRightUnsigned internal constant ZERO = LeftRightUnsigned.wrap(0);

    function setUp() public {
        E = new RiskEngineHarness(9_000_000, 9_000_000);
    }

    /// @dev What the pool writes at index 0 while safe mode is on (see PanopticPool._checkSolvencyAtTicks).
    function _sentinel(uint128 size) internal pure returns (PositionBalance) {
        uint32 maxUtilizations = uint32(MAX_UTIL) | (uint32(MAX_UTIL) << 16);
        return PositionBalanceLibrary.storeBalanceData(size, maxUtilizations, 0, 0, 0, false);
    }

    /// @dev A caller-built entry with unset metadata but a real utilization: must not read as safe mode.
    function _unsetMetadata(uint16 util) internal pure returns (PositionBalance) {
        return
            PositionBalanceLibrary.storeBalanceData(
                SIZE,
                uint32(util) | (uint32(util) << 16),
                0,
                0,
                0,
                false
            );
    }

    function _shortCall() internal pure returns (TokenId) {
        return PositionFactory.makeLeg(POOL_ID, 0, 1, 0, 0, 0, 0, int24(0), int24(1000));
    }

    function test_floorValue() public view {
        assertEq(E.safeModeUtilFloor(), 9_100_000, "90% + 10% / 10");
        assertEq(E.safeModeUtilFloor() / 1_000, FLOOR_BPS);
    }

    /// @notice An empty position list must not revert and yields zero utilizations.
    function test_emptyListDoesNotRevert() public view {
        PositionBalance[] memory none = new PositionBalance[](0);
        TokenId[] memory noIds = new TokenId[](0);

        PositionBalance g = E.globalUtilization(none);
        assertEq(g.utilization0(), 0);
        assertEq(g.utilization1(), 0);

        (LeftRightUnsigned req, LeftRightUnsigned credits, ) = E.totalRequiredCollateral(
            none,
            noIds,
            int24(0),
            ZERO
        );
        assertEq(LeftRightUnsigned.unwrap(req), 0);
        assertEq(LeftRightUnsigned.unwrap(credits), 0);
    }

    /// @notice Safe mode with a single position: the list is just the sentinel, so the loop is skipped and the
    ///         result is the floor on both sides.
    function test_safeModeSinglePosition() public view {
        PositionBalance[] memory bals = new PositionBalance[](1);
        bals[0] = _sentinel(SIZE);
        assertTrue(E.isSafeModeSentinel(bals[0]));

        PositionBalance g = E.globalUtilization(bals);
        assertEq(g.utilization0(), int256(uint256(FLOOR_BPS)), "floored util0");
        assertEq(g.utilization1(), int256(uint256(FLOOR_BPS)), "floored util1");
    }

    /// @notice The sentinel is still a position: it is priced at its stored 100% utilization like any other entry,
    ///         and the per-position view reconciles with the total.
    function test_safeModeSentinelStillPriced() public view {
        TokenId[] memory ids = new TokenId[](1);
        ids[0] = _shortCall();
        PositionBalance[] memory bals = new PositionBalance[](1);
        bals[0] = _sentinel(SIZE);

        PositionBalance[] memory real = new PositionBalance[](1);
        real[0] = PositionFactory.posBalance(SIZE, MAX_UTIL, MAX_UTIL);

        (LeftRightUnsigned viaSentinel, , ) = E.totalRequiredCollateral(bals, ids, int24(0), ZERO);
        (LeftRightUnsigned viaReal, , ) = E.totalRequiredCollateral(real, ids, int24(0), ZERO);
        assertEq(
            viaSentinel.rightSlot(),
            viaReal.rightSlot(),
            "priced at 100% like a real 100% position"
        );
        assertGt(viaSentinel.rightSlot(), 0);

        LeftRightUnsigned[] memory per = E.getPerPositionCollateralRequirements(
            bals,
            ids,
            int24(0)
        );
        assertEq(per[0].rightSlot(), viaSentinel.rightSlot(), "per-position reconciles");
    }

    /// @notice Real maximum below the floor is lifted to the floor.
    function test_safeModeMaxBelowFloorIsFloored() public view {
        PositionBalance[] memory bals = new PositionBalance[](3);
        bals[0] = _sentinel(SIZE);
        bals[1] = PositionFactory.posBalance(SIZE, 5_000, 7_000);
        bals[2] = PositionFactory.posBalance(SIZE, 6_000, 8_900);

        PositionBalance g = E.globalUtilization(bals);
        assertEq(g.utilization0(), int256(uint256(FLOOR_BPS)), "6000 -> floor");
        assertEq(g.utilization1(), int256(uint256(FLOOR_BPS)), "8900 -> floor");
    }

    /// @notice Real maximum above the floor is kept; the sentinel's own 100% is not part of the maximum.
    function test_safeModeMaxAboveFloorIsKept() public view {
        PositionBalance[] memory bals = new PositionBalance[](3);
        bals[0] = _sentinel(SIZE);
        bals[1] = PositionFactory.posBalance(SIZE, 9_500, 5_000);
        bals[2] = PositionFactory.posBalance(SIZE, 9_200, 9_300);

        PositionBalance g = E.globalUtilization(bals);
        assertEq(g.utilization0(), 9_500, "real max above floor kept");
        assertEq(g.utilization1(), 9_300, "real max above floor kept");
        assertLt(
            g.utilization0(),
            int256(uint256(MAX_UTIL)),
            "sentinel's 100% excluded from the max"
        );
    }

    /// @notice Mixed sides: one side floored, the other kept.
    function test_safeModeFloorAppliesPerSide() public view {
        PositionBalance[] memory bals = new PositionBalance[](2);
        bals[0] = _sentinel(SIZE);
        bals[1] = PositionFactory.posBalance(SIZE, 2_000, 9_400);

        PositionBalance g = E.globalUtilization(bals);
        assertEq(g.utilization0(), int256(uint256(FLOOR_BPS)));
        assertEq(g.utilization1(), 9_400);
    }

    /// @notice Index 0 with zero block/timestamp but a real utilization is a caller-built entry, not safe mode:
    ///         it counts towards the maximum and no floor is applied.
    function test_unsetMetadataWithRealUtilizationIsNotSafeMode() public view {
        PositionBalance[] memory bals = new PositionBalance[](2);
        bals[0] = _unsetMetadata(5_000);
        bals[1] = PositionFactory.posBalance(SIZE, 3_000, 4_000);
        assertFalse(E.isSafeModeSentinel(bals[0]));

        PositionBalance g = E.globalUtilization(bals);
        assertEq(g.utilization0(), 5_000, "index 0 counted, no floor");
        assertEq(g.utilization1(), 5_000, "index 0 counted, no floor");

        // 100%/100% with real metadata is a real saturated position, not a sentinel either
        assertFalse(E.isSafeModeSentinel(PositionFactory.posBalance(SIZE, MAX_UTIL, MAX_UTIL)));
        // and one side at 100% is not enough
        assertFalse(
            E.isSafeModeSentinel(
                PositionBalanceLibrary.storeBalanceData(
                    SIZE,
                    uint32(MAX_UTIL) | (uint32(5_000) << 16),
                    0,
                    0,
                    0,
                    false
                )
            )
        );
    }

    /// @notice The sentinel is only recognised at index 0.
    function test_sentinelOnlyRecognisedAtIndexZero() public view {
        PositionBalance[] memory bals = new PositionBalance[](2);
        bals[0] = PositionFactory.posBalance(SIZE, 3_000, 3_000);
        bals[1] = _sentinel(SIZE);

        PositionBalance g = E.globalUtilization(bals);
        assertEq(g.utilization0(), int256(uint256(MAX_UTIL)), "treated as a real 100% position");
        assertEq(g.utilization1(), int256(uint256(MAX_UTIL)));
    }

    /// @notice At the floor the cross buffer is exactly 80% of normal: the floor sits 1/5 of the way down a ramp
    ///         that runs from 90% to 95% utilization, for any cross buffer.
    function test_crossBufferAtFloorIsEightyPercent() public view {
        int256 floorUtil = int256(uint256(FLOOR_BPS));
        assertEq(E.crossBufferRatio(floorUtil, 9_000_000), 7_200_000, "90% buffer -> 72%");
        assertEq(E.crossBufferRatio(floorUtil, 7_500_000), 6_000_000, "75% buffer -> 60%");
        assertEq(E.crossBufferRatio(floorUtil, 10_000_000), 8_000_000, "100% buffer -> 80%");
        // just below saturation the buffer is untouched; at the cutoff it is gone
        assertEq(E.crossBufferRatio(8_999, 9_000_000), 9_000_000);
        assertEq(E.crossBufferRatio(9_500, 9_000_000), 0);
    }

    /// @notice End to end through the solvency path: the returned global utilization carries the floor.
    function test_totalRequiredCollateralReturnsFlooredGlobal() public view {
        TokenId[] memory ids = new TokenId[](2);
        ids[0] = _shortCall();
        ids[1] = _shortCall();
        PositionBalance[] memory bals = new PositionBalance[](2);
        bals[0] = _sentinel(SIZE);
        bals[1] = PositionFactory.posBalance(SIZE, 4_000, 4_000);

        (, , PositionBalance g) = E.totalRequiredCollateral(bals, ids, int24(0), ZERO);
        assertEq(g.utilization0(), int256(uint256(FLOOR_BPS)));
        assertEq(g.utilization1(), int256(uint256(FLOOR_BPS)));
    }

    /// @notice In safe mode only index 0 (the sentinel, i.e. the pool's first position) is priced at 100%; every
    ///         other position keeps its own utilization at mint.
    function test_safeModeOnlyIndexZeroAtHundredPercent() public view {
        TokenId[] memory ids = new TokenId[](2);
        ids[0] = _shortCall();
        ids[1] = _shortCall();
        PositionBalance[] memory bals = new PositionBalance[](2);
        bals[0] = _sentinel(SIZE);
        bals[1] = PositionFactory.posBalance(SIZE, 5_000, 5_000);

        LeftRightUnsigned[] memory per = E.getPerPositionCollateralRequirements(
            bals,
            ids,
            int24(0)
        );

        // reference: the same two legs as real positions at 100% and at 50%
        TokenId[] memory one = new TokenId[](1);
        one[0] = _shortCall();
        PositionBalance[] memory atMax = new PositionBalance[](1);
        atMax[0] = PositionFactory.posBalance(SIZE, MAX_UTIL, MAX_UTIL);
        PositionBalance[] memory atHalf = new PositionBalance[](1);
        atHalf[0] = PositionFactory.posBalance(SIZE, 5_000, 5_000);
        (LeftRightUnsigned reqMax, , ) = E.totalRequiredCollateral(atMax, one, int24(0), ZERO);
        (LeftRightUnsigned reqHalf, , ) = E.totalRequiredCollateral(atHalf, one, int24(0), ZERO);

        assertEq(per[0].rightSlot(), reqMax.rightSlot(), "index 0 at 100%");
        assertEq(per[1].rightSlot(), reqHalf.rightSlot(), "index 1 at its own 50%");
        assertLt(per[1].rightSlot(), per[0].rightSlot(), "not dragged to 100%");
    }

    /// @notice A real position can never be mistaken for the sentinel: it always has a non-zero block number
    ///         (and timestamp) at mint, whatever its size, utilizations, tick or swap flag.
    function testFuzz_realPositionNeverDetectedAsSentinel(
        uint128 size,
        uint16 util0,
        uint16 util1,
        int24 tick,
        uint32 timestampAtMint,
        uint40 blockAtMint,
        bool swapAtMint
    ) public view {
        blockAtMint = uint40(bound(blockAtMint, 1, (1 << 39) - 1)); // field is 39 bits, never 0 on-chain
        PositionBalance pb = PositionBalanceLibrary.storeBalanceData(
            size,
            uint32(util0) | (uint32(util1) << 16),
            tick,
            timestampAtMint,
            blockAtMint,
            swapAtMint
        );
        assertFalse(E.isSafeModeSentinel(pb));
    }

    /// @notice With unset metadata, the marker is recognised only when both utilizations are exactly 100%.
    function testFuzz_sentinelRequiresBothUtilizationsAtMax(
        uint16 util0,
        uint16 util1
    ) public view {
        PositionBalance pb = PositionBalanceLibrary.storeBalanceData(
            SIZE,
            uint32(util0) | (uint32(util1) << 16),
            0,
            0,
            0,
            false
        );
        bool expected = util0 == MAX_UTIL && util1 == MAX_UTIL;
        assertEq(E.isSafeModeSentinel(pb), expected);
    }

    /// @notice Invariant: flagging a list as safe mode (index 0 replaced by the sentinel of the same size) never
    ///         lowers the total requirement, and the global utilization becomes exactly
    ///         max(floor, max over the non-sentinel entries). Index 0's own utilization is lost to the overwrite,
    ///         so when it carried the account's maximum the cross buffer can be *larger* in safe mode than normal.
    function testFuzz_safeModeRequirementAndGlobalUtilization(uint16[4] memory utils) public view {
        TokenId[] memory ids = new TokenId[](4);
        PositionBalance[] memory normal = new PositionBalance[](4);
        PositionBalance[] memory safe = new PositionBalance[](4);
        int256 maxRest;
        for (uint256 i; i < 4; ++i) {
            uint16 u = uint16(bound(utils[i], 0, 10_000));
            ids[i] = _shortCall();
            normal[i] = PositionFactory.posBalance(SIZE, u, u);
            safe[i] = normal[i];
            if (i > 0 && int256(uint256(u)) > maxRest) maxRest = int256(uint256(u));
        }
        safe[0] = _sentinel(SIZE);

        (LeftRightUnsigned reqNormal, , ) = E.totalRequiredCollateral(normal, ids, int24(0), ZERO);
        (LeftRightUnsigned reqSafe, , PositionBalance gSafe) = E.totalRequiredCollateral(
            safe,
            ids,
            int24(0),
            ZERO
        );

        assertGe(
            reqSafe.rightSlot(),
            reqNormal.rightSlot(),
            "safe-mode requirement never below normal"
        );
        int256 expected = maxRest > int256(uint256(FLOOR_BPS))
            ? maxRest
            : int256(uint256(FLOOR_BPS));
        assertEq(gSafe.utilization0(), expected, "global util = max(floor, rest)");
        assertEq(gSafe.utilization1(), expected, "global util = max(floor, rest)");
    }
}
