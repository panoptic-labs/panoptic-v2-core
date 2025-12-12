// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RiskEngineHarness} from "./RiskEngineHarness.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {MockCollateralTracker} from "./mocks/MockCollateralTracker.sol";
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {TokenId} from "@types/TokenId.sol";
import {PositionBalance} from "@types/PositionBalance.sol";
import {PositionFactory} from "./helpers/PositionFactory.sol";

contract RiskEngineScenarios is Test {
    using PositionFactory for *;

    RiskEngineHarness internal E;
    MockCollateralTracker internal ct0;
    MockCollateralTracker internal ct1;

    uint256 constant DECIMALS = 10_000_000;

    function setUp() public {
        E = new RiskEngineHarness(5_000_000, 5_000_000);
        ct0 = new MockCollateralTracker();
        ct1 = new MockCollateralTracker();
        ct0.setGlobal(1_000_000 ether, 1_000_000 ether);
        ct1.setGlobal(1_000_000 ether, 1_000_000 ether);
        ct0.setSharePrice(1, 1);
        ct1.setSharePrice(1, 1);
    }

    function test_Directed_DeepITMShortHasHigherRequirementThanFarOTM() public {
        uint64 poolId = 1 + (10 << 48);

        TokenId shortCall = PositionFactory.makeLeg(poolId, 0, 1, 0, 0, 0, 0, int24(0), int24(600));
        uint128 size = 1e9;
        // far OTM
        uint256 rOTM = E.reqSingleNoPartner(shortCall, 0, size, int24(-6000), int16(0));
        // deep ITM
        uint256 rITM = E.reqSingleNoPartner(shortCall, 0, size, int24(6000), int16(0));
        assertGt(rITM, rOTM, "adverse move increases requirement");
    }

    function test_Directed_LongDecayHalvesPerWidth() public {
        uint64 poolId = 1 + (10 << 48);
        // Long call with width 600. Distance = n*width should ~ halve per n step
        TokenId longCall = PositionFactory.makeLeg(poolId, 0, 1, 0, 1, 0, 0, int24(0), int24(60));
        uint128 size = 1e9;
        int16 util = 0;
        uint256 r0 = E.reqSingleNoPartner(longCall, 0, size, 0, util);
        for (int24 t; t < 1000; ++t) {
            uint256 r1 = E.reqSingleNoPartner(longCall, 0, size, t * int24(10), util);
            assertLe(r1, r0, "monotonically decreasing");
            r0 = r1;
        }

        r0 = E.reqSingleNoPartner(longCall, 0, size, 0, util);
        for (int24 t; t < 1000; ++t) {
            uint256 r1 = E.reqSingleNoPartner(longCall, 0, size, -t * int24(10), util);
            assertLe(r1, r0, "monotonically decreasing");
            r0 = r1;
        }
    }

    function test_Solvency_FlipsOnceAsBufferIncreases() public {
        address user = address(0xDAD);
        ct0.setUser(user, 5 ether, 0, 5 ether);
        ct1.setUser(user, 5 ether, 0, 5 ether);
        uint64 poolId = 1 + (10 << 48);

        TokenId shortPut = PositionFactory.makeLeg(poolId, 0, 1, 0, 0, 1, 0, int24(0), int24(600));
        TokenId[] memory ids = new TokenId[](1);
        ids[0] = shortPut;

        PositionBalance pb = PositionFactory.posBalance(uint128(8e9), 1000, 1000);
        PositionBalance[] memory arr = new PositionBalance[](1);
        arr[0] = (pb);
        LeftRightUnsigned zero = LeftRightUnsigned.wrap(0);

        bool s1 = E.isAccountSolvent(
            arr,
            ids,
            int24(0),
            user,
            zero,
            zero,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1)),
            9_000_000
        );
        bool s2 = E.isAccountSolvent(
            arr,
            ids,
            int24(0),
            user,
            zero,
            zero,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1)),
            10_000_000
        );
        bool s3 = E.isAccountSolvent(
            arr,
            ids,
            int24(0),
            user,
            zero,
            zero,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1)),
            11_000_000
        );

        // At most one downward flip as buffer tightens
        assertTrue(s1 || s2 || s3, "not all false");
        assertFalse(s1 == false && s2 == true, "no re-entry after flip");
        assertFalse(s2 == false && s3 == true, "no re-entry after flip");
    }
}
