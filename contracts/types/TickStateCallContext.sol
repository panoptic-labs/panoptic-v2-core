// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title Panoptic TickStateCallContext packing and unpacking methods.
/// @author Axicon Labs Limited
/// @notice Type that can hold a fast oracle tick, a slow oracle tick, and a caller address.
/// @dev This needs to be recorded and passed through several functions to ultimately be used in:
/// @dev CollateralTracker.takeCommissionAddData() and CollateralTracker.exercise().
/// @dev Used to identify the user who originally called PanopticPool and avoid redundant Uniswap price queries.
// PACKING RULES FOR A TickStateCallContext:
// =================================================================================================
//      From the LSB to the MSB:
// (1) fastOracleTick    24bits  : The more current oracle price
// (2) slowOracleTick    24bits  : The more conservative oracle price
// (3) caller           160bits  : The caller (of PanopticPool)
// ( )                   46bits  : Zero-bits.
// Total                256bits  : Total bits used by this information.
// ===============================================================================================
//
// The bit pattern is therefore:
//
//         (  )              (3)               (2)              (1)
//    <-- 46 bits -->  <-- 160 bits -->  <-- 24 bits -->  <-- 24 bits -->
//         Zeros            caller        fastOracleTick   slowOracleTick
//
//        <--- most significant bit     least significant bit --->
//
library TickStateCallContext {
    using TickStateCallContext for uint256;

    /*//////////////////////////////////////////////////////////////
                                ENCODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Add the fast oracle tick to `self`.
    /// @param self The TickStateCallContext to add the fast oracle tick to
    /// @param _fastOracleTick The fast oracle tick to add to `self`
    /// @return `self` with added fast oracle tick `_fastOracleTick`
    function addFastOracleTick(
        uint256 self,
        int24 _fastOracleTick
    ) internal pure returns (uint256) {
        // typecast currentTick to uint24 as explicit type conversion is not allowed from int24 to uint256
        // the tick is cast to uint256 when added with the tickStateCallContext
        unchecked {
            return self + uint24(_fastOracleTick);
        }
    }

    /// @notice Add the slow oracle tick to `self`.
    /// @param self The TickStateCallContext to add the slow oracle tick to
    /// @param _slowOracleTick The slow oracle tick to add to `self`
    /// @return `self` with added slow oracle tick `_slowOracleTick`
    function addSlowOracleTick(
        uint256 self,
        int24 _slowOracleTick
    ) internal pure returns (uint256) {
        unchecked {
            return self + (uint256(uint24(_slowOracleTick)) << 24);
        }
    }

    /// @notice Add the caller to `self`.
    /// @param self The TickStateCallContext to add the caller to
    /// @param _caller The caller to add to `self`
    /// @return `self` with added caller `_caller`
    function addCaller(uint256 self, address _caller) internal pure returns (uint256) {
        unchecked {
            return self + (uint256(uint160(_caller)) << 48);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                DECODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the fast oracle tick from `self`.
    /// @param self The TickStateCallContext to retrieve the fast oracle tick from.
    /// @return The fast oracle tick of `self`.
    function fastOracleTick(uint256 self) internal pure returns (int24) {
        return int24(int256(self));
    }

    /// @notice Get the slow oracle tick from `self`.
    /// @param self The TickStateCallContext to retrieve the slow oracle tick from.
    /// @return The slow oracle tick of `self`.
    function slowOracleTick(uint256 self) internal pure returns (int24) {
        return int24(int256(self >> 24));
    }

    /// @notice Get the caller from `self`.
    /// @param self The TickStateCallContext to retrieve the caller from.
    /// @return The caller of `self`.
    function caller(uint256 self) internal pure returns (address) {
        return address(uint160(self >> 48));
    }
}
