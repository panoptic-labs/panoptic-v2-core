// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

// Libraries
import {Errors} from "@libraries/Errors.sol";
import {Math} from "@libraries/Math.sol";
import "forge-std/Test.sol";

/// @title Pack two separate data (each of 128bit) into a single 256-bit slot; 256bit-to-128bit packing methods.
/// @author Axicon Labs Limited
/// @notice Simple data type that divides a 256-bit word into two 128-bit slots.
library PackedUintLibrary {
    uint256 constant TWO_POW_119 = 2 ** 119;
    using PackedUintLibrary for uint256;
    /*//////////////////////////////////////////////////////////////
                              PACKING
    //////////////////////////////////////////////////////////////*/

    /// @notice Pack a uint256 into a uint128 using compression
    /// @dev Stores the uint256 N as N = e * 2^n,
    ///    where n is most significant bit and
    ///    e is a X119 number
    ///    we can recover N as:
    ///        N = (e << n) >> 119
    ///    We pack the value of n and e in a uint128 with:
    ///        -n in the lower 8 bits
    ///        -e in bits 8 to 128
    /// @param self The uint256 value to be packed
    /// @return The packed value in a uint128
    function pack(uint256 self) internal pure returns (uint128) {
        if (self == 0) return 0;
        uint8 n = self.mostSignificantBit();
        uint256 e = self.getMantissaX119(n);
        return uint128((e << 8) + n);
    }

    /// @notice Unpack a uint128 into a uint256
    /// @param self The packed uint128 value
    /// @return The unpacked uint256 value
    function unpack(uint128 self) internal pure returns (uint256) {
        if (self == 0) return 0;
        uint8 n = uint8(self & 0xFF);
        uint120 e = uint120(self >> 8);
        return Math.mulDiv(uint256(e), 2 ** n, TWO_POW_119);
    }

    /*//////////////////////////////////////////////////////////////
                       Arithmetic Operations
    //////////////////////////////////////////////////////////////*/

    /// @notice Add two packed uint128 numbers; revert on overflow
    /// @param x The first packed uint128 addend
    /// @param y The second packed uint128 addend
    /// @return The packed uint128 sum of x and y
    function add(uint128 x, uint128 y) internal pure returns (uint128) {
        uint256 unpackedX = unpack(x);
        uint256 unpackedY = unpack(y);
        require((unpackedX < type(uint256).max - unpackedY), "Addition overflow");
        uint256 sum = unpackedX + unpackedY;
        return pack(sum);
    }

    /// @notice Subtract two packed uint128 numbers; revert on underflow
    /// @param x The packed uint128 minuend
    /// @param y The packed uint128 subtrahend
    /// @return The packed uint128 difference of x and y
    function sub(uint128 x, uint128 y) internal pure returns (uint128) {
        uint256 unpackedX = unpack(x);
        uint256 unpackedY = unpack(y);
        require(unpackedX >= unpackedY, "Underflow");
        uint256 difference;
        unchecked {
            difference = unpackedX - unpackedY;
        }
        return pack(difference);
    }

    /// @notice Multiply two packed uint128 numbers; revert on overflow
    /// @param x The first packed uint128 factor
    /// @param y The second packed uint128 factor
    /// @return The packed uint128 product of x and y
    function mul(uint128 x, uint128 y) internal pure returns (uint128) {
        if ((unpack(x) == 0) || (unpack(y) == 0)) return 0;
        uint256 unpackedX = unpack(x);
        uint256 unpackedY = unpack(y);
        require(
            (unpackedY > 0 && unpackedX <= type(uint256).max / unpackedY) ||
                (unpackedX > 0 && unpackedY <= type(uint256).max / unpackedX),
            "Multiplication overflow"
        );
        uint256 product = unpackedX * unpackedY;
        return pack(product);
    }

    /// @notice Divide two packed uint128 numbers; revert on division by zero
    /// @param x The packed uint128 dividend
    /// @param y The packed uint128 divisor
    /// @return The packed uint128 quotient of x divided by y
    function div(uint128 x, uint128 y) internal pure returns (uint128) {
        uint256 unpackedX = unpack(x);
        uint256 unpackedY = unpack(y);
        require(unpackedY != 0, "Division by zero");
        uint256 quotient = unpackedX / unpackedY;
        return pack(quotient);
    }

    /*//////////////////////////////////////////////////////////////
                              MATH HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Find the position of the most significant bit in a uint256
    /// @param self The uint256 value to analyze
    /// @return r The position of the most significant bit (0-255)
    function mostSignificantBit(uint256 self) internal pure returns (uint8 r) {
        unchecked {
            if (self >= 0x100000000000000000000000000000000) {
                self >>= 128;
                r += 128;
            }
            if (self >= 0x10000000000000000) {
                self >>= 64;
                r += 64;
            }
            if (self >= 0x100000000) {
                self >>= 32;
                r += 32;
            }
            if (self >= 0x10000) {
                self >>= 16;
                r += 16;
            }
            if (self >= 0x100) {
                self >>= 8;
                r += 8;
            }
            if (self >= 0x10) {
                self >>= 4;
                r += 4;
            }
            if (self >= 0x4) {
                self >>= 2;
                r += 2;
            }
            if (self >= 0x2) r += 1;
        }
    }

    /// @notice compute the mantissa of the input N, where the mantissa is a X119 number
    /// @dev uses Math.mulDiv, which allows for overflow as long as the final value is less than type(uint256).max
    /// @param self The uint256 value to get the mantissa from
    /// @param n The exponent of that number
    /// @return e The mantissa
    function getMantissaX119(uint256 self, uint8 n) internal pure returns (uint128) {
        return uint128(Math.mulDiv(self, TWO_POW_119, 2 ** n));
    }
}
