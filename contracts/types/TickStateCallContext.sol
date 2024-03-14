// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title Panoptic TickStateCallContext packing and unpacking methods.
/// @author Axicon Labs Limited
/// @dev This needs to be recorded and passed through several functions to ultimately be used in:
/// @dev collateralTracker.takeCommissionAddData() and collateralTracker.exercise().
/// @dev Used to identify the user who originally called PanopticPool and avoid redundant Uniswap price queries.
/// @dev PACKING RULES FOR A TickStateCallContext:
/// =================================================================================================
/// @dev From the LSB to the MSB:
/// (1) fastOracleTick    24bits  : The more current oracle price
/// (2) slowOracleTick    24bits  : The more conservative oracle price
/// (3) caller           160bits  : The caller (of PanopticPool)
/// ( )                   46bits  : Zero-bits.
/// Total                256bits  : Total bits used by this information.
/// ===============================================================================================
///
/// The bit pattern is therefore:
///
///         (  )              (3)               (2)              (1)
///    <-- 46 bits -->  <-- 160 bits -->  <-- 24 bits -->  <-- 24 bits -->
///         Zeros            caller          medianTick      currentTick
///
///        <--- most significant bit     least significant bit --->
///
library TickStateCallContext {
    using TickStateCallContext for uint256;

    /*//////////////////////////////////////////////////////////////
                                ENCODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Add the `currentTick` to the `tickStateCallContext` packed data.
    /// @param self the packed uint256 that holds current tick, median tick, and caller.
    /// @param _fastOracleTick The more current oracle price.
    /// @return the tickStateCallContext with added fast oracle tick.
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

    /// @notice Add the `MedianTick` to the `tickStateCallContext` packed data.
    /// @param self the packed uint256 that holds current tick, median tick, and caller.
    /// @param _slowOracleTick The more conservative oracle price.
    /// @return the tickStateCallContext with added slow oracle tick.
    function addSlowOracleTick(
        uint256 self,
        int24 _slowOracleTick
    ) internal pure returns (uint256) {
        unchecked {
            return self + (uint256(uint24(_slowOracleTick)) << 24);
        }
    }

    /// @notice Add the `msg.sender` to the `tickStateCallContext` packed data.
    /// @param self the packed uint256 that holds current tick, median tick, and caller.
    /// @param _caller The user who called the Panoptic Pool.
    /// @return the tickStateCallContext with added msg.sender data.
    function addCaller(uint256 self, address _caller) internal pure returns (uint256) {
        unchecked {
            return self + (uint256(uint160(_caller)) << 48);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                DECODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Return the currentTick for data packed into tickStateCallContext.
    /// @param self the packed uint256 that holds the fast oracle tick, slow oracle tick, and caller.
    /// @return the fast oracle tick of tickStateCallContext.
    function fastOracleTick(uint256 self) internal pure returns (int24) {
        return int24(int256(self));
    }

    /// @notice Return the median tick for data packed into tickStateCallContext.
    /// @param self the packed uint256 that holds the fast oracle tick, slow oracle tick, and caller.
    /// @return the slow oracle tick of tickStateCallContext.
    function slowOracleTick(uint256 self) internal pure returns (int24) {
        return int24(int256(self >> 24));
    }

    /// @notice Return the caller for data packed into tickStateCallContext.
    /// @param self the packed uint256 that holds the fast oracle tick, slow oracle tick, and caller.
    /// @return the caller stored in tickStateCallContext.
    function caller(uint256 self) internal pure returns (address) {
        return address(uint160(self >> 48));
    }
}
