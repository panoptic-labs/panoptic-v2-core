// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// Libraries
import {Errors} from "@libraries/Errors.sol";
import {Math} from "@libraries/Math.sol";

/// @title Pack two separate data (each of 128bit) into a single 256-bit slot; 256bit-to-128bit packing methods.
/// @author Axicon Labs Limited
/// @notice we want a compact representation of 256 bits of data. So we split it into two separate
/// @notice 128-bit chunks "left" and "right".
/// @notice The background here is that if an integer is explicitly converted to a smaller type,
/// @notice higher-order bits are cut off. For example: uint32 a = 0x12345678; uint16 b = uint16(a); // b will be 0x5678 now
library LeftRight {
    using LeftRight for uint256;
    using Math for uint256;
    using LeftRight for int256;
    uint256 internal constant LEFT_HALF_BIT_MASK =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000000000000000000000000000;
    int256 internal constant LEFT_HALF_BIT_MASK_INT =
        int256(uint256(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000000000000000000000000000));
    int256 internal constant RIGHT_HALF_BIT_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    /*//////////////////////////////////////////////////////////////
                              RIGHT SLOT
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the "right" slot from a uint256 bit pattern.
    /// @param self The uint256 (full 256 bits) to be cut in its right half
    /// @return the right half of self (128 bits)
    function rightSlot(uint256 self) internal pure returns (uint128) {
        return uint128(self);
    }

    /// @notice Get the "right" slot from an int256 bit pattern.
    /// @param self The int256 (full 256 bits) to be cut in its right half
    /// @return the right half self (128 bits)
    function rightSlot(int256 self) internal pure returns (int128) {
        return int128(self);
    }

    // All toRightSlot functions add bits to the right slot without clearing it first
    // Typically, the slot is already clear when writing to it, but if it is not, the bits will be added to the existing bits
    // Therefore, the assumption must not be made that the bits will be cleared while using these helpers
    // Note that the values *within* the slots are allowed to overflow, but overflows are contained and will not leak into the other slot

    /// @notice Write the "right" slot to a uint256.
    /// @param self the original full uint256 bit pattern to be written to
    /// @param right the bit pattern to write into the full pattern in the right half
    /// @return self with incoming right added (not overwritten, but added) to its right 128 bits
    function toRightSlot(uint256 self, uint128 right) internal pure returns (uint256) {
        unchecked {
            // prevent the right slot from leaking into the left one in the case of an overflow
            // ff + 1 = (1)00, but we want just ff + 1 = 00
            return (self & LEFT_HALF_BIT_MASK) + uint256(uint128(self) + right);
        }
    }

    /// @notice Write the "right" slot to an int256.
    /// @param self the original full int256 bit pattern to be written to
    /// @param right the bit pattern to write into the full pattern in the right half
    /// @return self with right added to its right 128 bits
    function toRightSlot(int256 self, uint128 right) internal pure returns (int256) {
        unchecked {
            // prevent the right slot from leaking into the left one in the case of a positive sign change
            // ff + 1 = (1)00, but we want just ff + 1 = 00
            return
                (self & LEFT_HALF_BIT_MASK_INT) +
                (int256(int128(self) + int128(right)) & RIGHT_HALF_BIT_MASK);
        }
    }

    /// @notice Write the "right" slot to an int256.
    /// @param self the original full int256 bit pattern to be written to
    /// @param right the bit pattern to write into the full pattern in the right half
    /// @return self with right added to its right 128 bits
    function toRightSlot(int256 self, int128 right) internal pure returns (int256) {
        // bit mask needed in case rightHalfBitPattern < 0 due to 2's complement
        unchecked {
            // prevent the right slot from leaking into the left one in the case of a positive sign change
            // ff + 1 = (1)00, but we want just ff + 1 = 00
            return
                (self & LEFT_HALF_BIT_MASK_INT) +
                (int256(int128(self) + right) & RIGHT_HALF_BIT_MASK);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              LEFT SLOT
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the "left" half from a uint256 bit pattern.
    /// @param self The uint256 (full 256 bits) to be cut in its left half
    /// @return the left half (128 bits)
    function leftSlot(uint256 self) internal pure returns (uint128) {
        return uint128(self >> 128);
    }

    /// @notice Get the "left" half from an int256 bit pattern.
    /// @param self The int256 (full 256 bits) to be cut in its left half
    /// @return the left half (128 bits)
    function leftSlot(int256 self) internal pure returns (int128) {
        return int128(self >> 128);
    }

    /// @dev All toLeftSlot functions add bits to the left slot without clearing it first
    /// @dev Typically, the slot is already clear when writing to it, but if it is not, the bits will be added to the existing bits
    /// @dev Therefore, the assumption must not be made that the bits will be cleared while using these helpers
    /// @dev Note that the values *within* the slots are allowed to overflow, but overflows are contained and will not leak into the other slot

    /// @notice Write the "left" slot to a uint256 bit pattern.
    /// @param self the original full uint256 bit pattern to be written to
    /// @param left the bit pattern to write into the full pattern in the right half
    /// @return self with left added to its left 128 bits
    function toLeftSlot(uint256 self, uint128 left) internal pure returns (uint256) {
        unchecked {
            return self + (uint256(left) << 128);
        }
    }

    /// @notice Write the "left" slot to an int256 bit pattern.
    /// @param self the original full int256 bit pattern to be written to
    /// @param left the bit pattern to write into the full pattern in the right half
    /// @return self with left added to its left 128 bits
    function toLeftSlot(int256 self, uint128 left) internal pure returns (int256) {
        unchecked {
            return self + (int256(int128(left)) << 128);
        }
    }

    /// @notice Write the "left" slot to an int256 bit pattern.
    /// @param self the original full int256 bit pattern to be written to
    /// @param left the bit pattern to write into the full pattern in the right half
    /// @return self with left added to its left 128 bits
    function toLeftSlot(int256 self, int128 left) internal pure returns (int256) {
        unchecked {
            return self + (int256(left) << 128);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            MATH HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Add two uint256 bit LeftRight-encoded words; revert on overflow or underflow.
    /// @param x the augend
    /// @param y the addend
    /// @return z the sum x + y
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        unchecked {
            // adding leftRight packed uint128's is same as just adding the values explictily
            // given that we check for overflows of the left and right values
            z = x + y;

            // on overflow z will be less than either x or y
            // type cast z to uint128 to isolate the right slot and if it's lower than a value it's comprised of (x)
            // then an overflow has occured
            if (z < x || (uint128(z) < uint128(x))) revert Errors.UnderOverFlow();
        }
    }

    /// @notice Subtract two uint256 bit LeftRight-encoded words; revert on overflow or underflow.
    /// @param x the minuend
    /// @param y the subtrahend
    /// @return z the difference x - y
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        unchecked {
            // subtracting leftRight packed uint128's is same as just subtracting the values explictily
            // given that we check for underflows of the left and right values
            z = x - y;

            // on underflow z will be greater than either x or y
            // type cast z to uint128 to isolate the right slot and if it's higher than a value that was subtracted from (x)
            // then an underflow has occured
            if (z > x || (uint128(z) > uint128(x))) revert Errors.UnderOverFlow();
        }
    }

    /// @notice Add uint256 to an int256 LeftRight-encoded word; revert on overflow or underflow.
    /// @param x the augend
    /// @param y the addend
    /// @return z (int256) the sum x + y
    function add(uint256 x, int256 y) internal pure returns (int256 z) {
        unchecked {
            int256 left = int256(uint256(x.leftSlot())) + y.leftSlot();
            int128 left128 = int128(left);

            if (left128 != left) revert Errors.UnderOverFlow();

            int256 right = int256(uint256(x.rightSlot())) + y.rightSlot();
            int128 right128 = int128(right);

            if (right128 != right) revert Errors.UnderOverFlow();

            return z.toRightSlot(right128).toLeftSlot(left128);
        }
    }

    /// @notice Add two int256 bit LeftRight-encoded words; revert on overflow.
    /// @param x the augend
    /// @param y the addend
    /// @return z the sum x + y
    function add(int256 x, int256 y) internal pure returns (int256 z) {
        unchecked {
            int256 left256 = int256(x.leftSlot()) + y.leftSlot();
            int128 left128 = int128(left256);

            int256 right256 = int256(x.rightSlot()) + y.rightSlot();
            int128 right128 = int128(right256);

            if (left128 != left256 || right128 != right256) revert Errors.UnderOverFlow();

            return z.toRightSlot(right128).toLeftSlot(left128);
        }
    }

    /// @notice Subtract two int256 bit LeftRight-encoded words; revert on overflow.
    /// @param x the minuend
    /// @param y the subtrahend
    /// @return z the difference x - y
    function sub(int256 x, int256 y) internal pure returns (int256 z) {
        unchecked {
            int256 left256 = int256(x.leftSlot()) - y.leftSlot();
            int128 left128 = int128(left256);

            int256 right256 = int256(x.rightSlot()) - y.rightSlot();
            int128 right128 = int128(right256);

            if (left128 != left256 || right128 != right256) revert Errors.UnderOverFlow();

            return z.toRightSlot(right128).toLeftSlot(left128);
        }
    }

    /// @notice Subtract two int256 bit LeftRight-encoded words; revert on overflow.
    /// @notice rectify difference x - y to 0 if negative
    /// @param x the minuend
    /// @param y the subtrahend
    /// @return z the difference x - y
    function subRect(int256 x, int256 y) internal pure returns (int256 z) {
        unchecked {
            int256 left256 = int256(x.leftSlot()) - y.leftSlot();
            int128 left128 = int128(left256);

            int256 right256 = int256(x.rightSlot()) - y.rightSlot();
            int128 right128 = int128(right256);

            if (left128 != left256 || right128 != right256) revert Errors.UnderOverFlow();

            return
                z.toRightSlot(int128(Math.max(right128, 0))).toLeftSlot(
                    int128(Math.max(left128, 0))
                );
        }
    }

    /// @notice Adds two sets of leftRights, freezing both right slots if either overflows, and vice versa
    /// @dev Used for linked accumulators, so if the accumulator for one side overflows for a token, both cease to accumulate
    /// @param x the first augend
    /// @param dx the addend for x
    /// @param y the second augend
    /// @param dy the addend for y
    /// @return z the sum x + y
    function addCapped(
        uint256 x,
        uint256 dx,
        uint256 y,
        uint256 dy
    ) internal pure returns (uint256, uint256) {
        uint128 z_xR = (uint256(x.rightSlot()) + dx.rightSlot()).toUint128Capped();
        uint128 z_xL = (uint256(x.leftSlot()) + dx.leftSlot()).toUint128Capped();
        uint128 z_yR = (uint256(y.rightSlot()) + dy.rightSlot()).toUint128Capped();
        uint128 z_yL = (uint256(y.leftSlot()) + dy.leftSlot()).toUint128Capped();

        bool r_Enabled = !(z_xR == type(uint128).max || z_yR == type(uint128).max);
        bool l_Enabled = !(z_xL == type(uint128).max || z_yL == type(uint128).max);

        return (
            uint256(0).toRightSlot(r_Enabled ? z_xR : x.rightSlot()).toLeftSlot(
                l_Enabled ? z_xL : x.leftSlot()
            ),
            uint256(0).toRightSlot(r_Enabled ? z_yR : y.rightSlot()).toLeftSlot(
                l_Enabled ? z_yL : y.leftSlot()
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                            SAFE CASTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Cast an int256 to an int128, revert on overflow or underflow.
    /// @param self the int256 to be downcasted to int128
    /// @return selfAsInt128 the downcasted integer, now of type int128
    function toInt128(int256 self) internal pure returns (int128 selfAsInt128) {
        if (!((selfAsInt128 = int128(self)) == self)) revert Errors.CastingError();
    }

    /// @notice Downcast uint256 to a uint128, revert on overflow
    /// @param self the uint256 to be downcasted to uint128
    /// @return selfAsUint128 the downcasted uint256 now as uint128
    function toUint128(uint256 self) internal pure returns (uint128 selfAsUint128) {
        if (!((selfAsUint128 = uint128(self)) == self)) revert Errors.CastingError();
    }

    /// @notice Cast a uint256 to an int256, revert on overflow
    /// @param self the uint256 to be downcasted to uint128
    /// @return the incoming uint256 but now of type int256
    function toInt256(uint256 self) internal pure returns (int256) {
        if (self > uint256(type(int256).max)) revert Errors.CastingError();
        return int256(self);
    }
}
