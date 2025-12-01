// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

type RiskParameters is uint256;
using RiskParametersLibrary for RiskParameters global;

/// @title A Panoptic Risk Parameters. Tracks the data outputted from the RiskEngine, like the safeMode, commission fees, (etc).
/// @author Axicon Labs Limited
//
//
// PACKING RULES FOR A RISKPARAMETERS:
// =================================================================================================
//  From the LSB to the MSB:
// (1) safeMode             8 bits  : The safeMode state
// (2) notionalFee          24 bits : The fee to be charged on notional at mint
// (3) premiumFee           24 bits : The fee to be charged on the premium at burn
// (4-6) empty              72 bits : empty
// (7) feeRecipient         128bits : The recipient of the commission fee split
// Total                    256bits  : Total bits used by a RiskParameters.
// ===============================================================================================
//
// The bit pattern is therefore:
//
//           (6)                (5)                (4)                   (3)             (2)                    (0)
//    <---- 128 bits ----><---- 24 bits ----><---- 24 bits ----><---- 24 bits ----> <---- 24 bits ----> <---- 24 bits ----> <---- 8 bits ---->
//          feeRecipient                                                             premiumFee          notionalFee         safeMode
//
//    <--- most significant bit                                                                  least significant bit --->
//
library RiskParametersLibrary {
    /*//////////////////////////////////////////////////////////////
                                ENCODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new `RiskParameters` abject .
    /// @param _safeMode The safe mode state
    /// @param _notionalFee The commission fee
    /// @param _premiumFee The commission fee
    /// @param _feeRecipient The recipient of the commission fee split
    /// @return The new RiskParameters object
    function storeRiskParameters(
        uint8 _safeMode,
        uint24 _notionalFee,
        uint24 _premiumFee,
        uint128 _feeRecipient
    ) internal pure returns (RiskParameters) {
        unchecked {
            return
                RiskParameters.wrap(
                    _safeMode +
                        (uint256(_notionalFee) << 8) +
                        (uint256(_premiumFee) << 32) +
                        (uint256(_feeRecipient) << 128)
                );
        }
    }

    /*//////////////////////////////////////////////////////////////
                                DECODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the safeMode state of `self`.
    /// @param self The RiskParameters to retrieve the safeMode state from
    /// @return The safeMode of `self`
    function safeMode(RiskParameters self) internal pure returns (uint8) {
        unchecked {
            return uint8(RiskParameters.unwrap(self));
        }
    }

    /// @notice Get the notionalFee of `self`.
    /// @param self The RiskParameters to retrieve the commissionFee from
    /// @return The notionalFee of `self`
    function notionalFee(RiskParameters self) internal pure returns (uint24) {
        unchecked {
            return uint24(RiskParameters.unwrap(self) >> 8);
        }
    }

    /// @notice Get the premiumFee of `self`.
    /// @param self The RiskParameters to retrieve the commissionFee from
    /// @return The premiumFee of `self`
    function premiumFee(RiskParameters self) internal pure returns (uint24) {
        unchecked {
            return uint24(RiskParameters.unwrap(self) >> 32);
        }
    }

    /// @notice Get the feeRecipient of `self`.
    /// @param self The RiskParameters to retrieve the feeRecipient from
    /// @return The feeRecipient of `self`
    function feeRecipient(RiskParameters self) internal pure returns (uint128) {
        unchecked {
            return uint128(RiskParameters.unwrap(self) >> 128);
        }
    }
}
