// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// foundry
import "forge-std/Test.sol";
// internal
import {Errors} from "../../../contracts/libraries/Errors.sol";
import {PositionBalanceHarness} from "./harnesses/PositionBalanceHarness.sol";
import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";

/**
 * Test Position Balance using Foundry and Fuzzing.
 *
 * @author Axicon Labs Limited
 */
contract PositionBalanceTest is Test {
    // harness
    PositionBalanceHarness harness;

    function setUp() public {
        harness = new PositionBalanceHarness();
    }

    function test_Success_storeBalanceData(
        uint128 y,
        uint16 z,
        uint16 u,
        int24 w,
        uint32 v,
        uint40 t,
        bool b
    ) public view {
        uint32 utilizations = uint32(z) + (uint32(u) << 16);
        PositionBalance x = harness.storeBalanceData(y, utilizations, w, v, t, b);
        assertEq(harness.positionSize(x), y);
        assertEq(harness.utilizations(x), utilizations);
        assertEq(harness.utilization0(x), int256(uint256(z)));
        assertEq(harness.utilization1(x), int256(uint256(u)));
        assertEq(harness.tickAtMint(x), w);
        assertEq(harness.timestampAtMint(x), v);
        assertEq(harness.blockAtMint(x), t % 2 ** 39);
        assertEq(harness.swapAtMint(x), b);
    }

    function test_Success_storeBalanceData_utilizations(
        uint128 y,
        uint32 z,
        int24 w,
        uint32 v,
        uint40 t,
        bool b
    ) public view {
        PositionBalance x = harness.storeBalanceData(y, z, w, v, t, b);
        assertEq(harness.positionSize(x), y);
        assertEq(harness.utilizations(x), z);
        assertEq(harness.tickAtMint(x), w);
        assertEq(harness.timestampAtMint(x), v);
        assertEq(harness.blockAtMint(x), t % 2 ** 39);
        assertEq(harness.swapAtMint(x), b);
    }
}
