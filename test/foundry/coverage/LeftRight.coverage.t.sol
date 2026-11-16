// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Errors} from "@libraries/Errors.sol";
import {LeftRightSigned, LeftRightUnsigned, LeftRightLibrary} from "@types/LeftRight.sol";

/// @dev Exposes the mixed-sign `sub` overload, which the shared LeftRightHarness does not.
contract LeftRightSubHarness {
    function sub(LeftRightSigned x, LeftRightUnsigned y) external pure returns (LeftRightSigned) {
        return LeftRightLibrary.sub(x, y);
    }
}

/// @notice Fills the coverage gaps left in `contracts/types/LeftRight.sol` by the rest of the suite:
/// the `UnderOverFlow` revert of `sub(LeftRightSigned, LeftRightUnsigned)`.
contract LeftRightCoverageTest is Test {
    LeftRightSubHarness internal harness;

    function setUp() public {
        harness = new LeftRightSubHarness();
    }

    function _signed(int128 right, int128 left) internal pure returns (LeftRightSigned) {
        return LeftRightSigned.wrap(0).addToRightSlot(right).addToLeftSlot(left);
    }

    function _unsigned(uint128 right, uint128 left) internal pure returns (LeftRightUnsigned) {
        return LeftRightUnsigned.wrap(0).addToRightSlot(right).addToLeftSlot(left);
    }

    function test_subSignedUnsigned_success(
        int128 xRight,
        int128 xLeft,
        uint128 yRight,
        uint128 yLeft
    ) public view {
        int256 right = int256(xRight) - int256(uint256(yRight));
        int256 left = int256(xLeft) - int256(uint256(yLeft));
        vm.assume(right >= type(int128).min && left >= type(int128).min);

        LeftRightSigned z = harness.sub(_signed(xRight, xLeft), _unsigned(yRight, yLeft));

        assertEq(z.rightSlot(), right, "right");
        assertEq(z.leftSlot(), left, "left");
    }

    function test_subSignedUnsigned_revertsOnRightUnderflow(int128 xRight, uint128 yRight) public {
        vm.assume(int256(xRight) - int256(uint256(yRight)) < type(int128).min);

        vm.expectRevert(Errors.UnderOverFlow.selector);
        harness.sub(_signed(xRight, 0), _unsigned(yRight, 0));
    }

    function test_subSignedUnsigned_revertsOnLeftUnderflow(int128 xLeft, uint128 yLeft) public {
        vm.assume(int256(xLeft) - int256(uint256(yLeft)) < type(int128).min);

        vm.expectRevert(Errors.UnderOverFlow.selector);
        harness.sub(_signed(0, xLeft), _unsigned(0, yLeft));
    }

    function test_subSignedUnsigned_revertsAtBoundary() public {
        // int128.min - 1 is the smallest underflow in either slot
        vm.expectRevert(Errors.UnderOverFlow.selector);
        harness.sub(_signed(type(int128).min, 0), _unsigned(1, 0));

        vm.expectRevert(Errors.UnderOverFlow.selector);
        harness.sub(_signed(0, type(int128).min), _unsigned(0, 1));

        // int128.min itself is representable
        LeftRightSigned z = harness.sub(_signed(type(int128).min + 1, 0), _unsigned(1, 0));
        assertEq(z.rightSlot(), type(int128).min);
    }
}
