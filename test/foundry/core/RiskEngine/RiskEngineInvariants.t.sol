// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RiskEngineHarness} from "./RiskEngineHarness.sol";
import {MockCollateralTracker} from "./mocks/MockCollateralTracker.sol";
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {TokenId} from "@types/TokenId.sol";
import {PositionBalance} from "@types/PositionBalance.sol";
import {PositionFactory} from "./helpers/PositionFactory.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";

contract RiskEngineInvariants is Test {
    using PositionFactory for *;

    RiskEngineHarness internal E;
    MockCollateralTracker internal ct0;
    MockCollateralTracker internal ct1;

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
        ct0 = new MockCollateralTracker();
        ct1 = new MockCollateralTracker();
        ct0.setGlobal(1_000_000 ether, 1_000_000 ether);
        ct1.setGlobal(1_000_000 ether, 1_000_000 ether);
        ct0.setSharePrice(1, 1);
        ct1.setSharePrice(1, 1);
    }

    function testFuzz_Invariant_scale_and_util_sign(
        uint128 size,
        int16 util,
        int24 strike,
        int24 width
    ) public {
        size = uint128(bound(size, 1, 1e12));
        width = int24(bound(width, 1, 2000));
        strike = int24(bound(strike, -40000, 40000));
        util = int16(bound(util, -9000, 9500)); // includes negative for strangles

        uint64 pool = 1 + (10 << 48);
        // randomly pick long or short, call or put
        uint256 isLong = uint256(uint160(uint256(keccak256(abi.encodePacked(size)))) & 1);
        uint256 ttype = uint256(
            uint160(uint256(keccak256(abi.encodePacked(size, uint256(1))))) & 1
        );

        TokenId leg = PositionFactory.makeLeg(pool, 0, 1, 0, isLong, ttype, 0, strike, width);
        uint256 r = E.reqSingleNoPartner(leg, 0, size, strike, util);

        // scale by k
        uint128 ksize = size * 3;
        uint256 rScaled = E.reqSingleNoPartner(leg, 0, ksize, strike, util);
        assertApproxEqAbs(rScaled, r * 3, 10, "linear in size");

        // sign of util for short vs strangle is handled internally; requirement must be >= 1 for small sizes when short
        if (isLong == 0) {
            assertGe(r, 1, "short floor");
        }
    }

    function testFuzz_Buffer_monotone_once(uint128 s, uint16 u0, uint16 u1) public {
        s = uint128(bound(s, 1e6, 1e12));
        u0 = uint16(bound(u0, 0, 9000));
        u1 = uint16(bound(u1, 0, 9000));

        address user = address(this);
        ct0.setUser(user, 10 ether, 0, 10 ether);
        ct1.setUser(user, 10 ether, 0, 10 ether);

        uint64 pool = 1 + (10 << 48);
        TokenId t = PositionFactory.makeLeg(pool, 0, 1, 0, 0, 0, 0, 0, 600);
        TokenId[] memory ids = new TokenId[](1);
        ids[0] = t;

        uint256[] memory arr = new uint256[](1);
        arr[0] = PositionBalance.unwrap(PositionFactory.posBalance(s, u0, u1));
        LeftRightUnsigned z = LeftRightUnsigned.wrap(0);

        bool s1 = E.isAccountSolvent(
            user,
            arr,
            0,
            ids,
            z,
            z,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1)),
            9_000_000
        );
        bool s2 = E.isAccountSolvent(
            user,
            arr,
            0,
            ids,
            z,
            z,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1)),
            10_000_000
        );
        bool s3 = E.isAccountSolvent(
            user,
            arr,
            0,
            ids,
            z,
            z,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1)),
            11_000_000
        );
        // no re-entry
        require(!(s1 == false && s2 == true), "flip once at most (1)");
        require(!(s2 == false && s3 == true), "flip once at most (2)");
    }
}
