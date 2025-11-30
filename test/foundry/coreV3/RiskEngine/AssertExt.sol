// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

contract AssertExt is Test {
    function assertMonotoneNondecreasing(uint256 a, uint256 b, string memory msg_) internal {
        assertGe(b, a, msg_);
    }

    function assertMonotoneNonincreasing(uint256 a, uint256 b, string memory msg_) internal {
        assertLe(b, a, msg_);
    }

    function assertApproxLe(uint256 got, uint256 target, uint256 tol, string memory msg_) internal {
        if (got > target) {
            assertLe(got - target, tol, msg_);
        }
    }

    function assertFlipOnce(bool s1, bool s2, bool s3, string memory ctx) internal {
        // true,true,true or true,true,false or true,false,false or false,false,false are ok
        // false,true,false and false,false,true are forbidden
        assertFalse((s1 == false && s2 == true), string.concat(ctx, ": no false->true at step2"));
        assertFalse((s2 == false && s3 == true), string.concat(ctx, ": no false->true at step3"));
    }
}
