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
//    <---- 128 bits ----><---- 24 bits ----><---- 16 bits ----><---- 16 bits ----> <---- 16 bits ----> <---- 16 bits ----> <---- 8 bits ---->
//          feeRecipient                         builderSplit         protocolSplit     premiumFee          notionalFee         safeMode
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
    /// @param _protocolSplit The part of the fee that goes to the protocol w/ buildercodes
    /// @param _builderSplit The part of the fee that goes to the builder w/ buildercodes
    /// @param _feeRecipient The recipient of the commission fee split
    /// @return The new RiskParameters object
    function storeRiskParameters(
        uint8 _safeMode,
        uint16 _notionalFee,
        uint16 _premiumFee,
        uint16 _protocolSplit,
        uint16 _builderSplit,
        uint128 _feeRecipient
    ) internal pure returns (RiskParameters) {
        unchecked {
            return
                RiskParameters.wrap(
                    _safeMode +
                        (uint256(_notionalFee) << 8) +
                        (uint256(_premiumFee) << 24) +
                        (uint256(_protocolSplit) << 40) +
                        (uint256(_builderSplit) << 56) +
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
    function notionalFee(RiskParameters self) internal pure returns (uint16) {
        unchecked {
            return uint16(RiskParameters.unwrap(self) >> 8);
        }
    }

    /// @notice Get the premiumFee of `self`.
    /// @param self The RiskParameters to retrieve the premiumFee from
    /// @return The premiumFee of `self`
    function premiumFee(RiskParameters self) internal pure returns (uint16) {
        unchecked {
            return uint16(RiskParameters.unwrap(self) >> 24);
        }
    }

    /// @notice Get the protocolSplit of `self`.
    /// @param self The RiskParameters to retrieve the protocolSplit from
    /// @return The protocolSplit of `self`
    function protocolSplit(RiskParameters self) internal pure returns (uint16) {
        unchecked {
            return uint16(RiskParameters.unwrap(self) >> 40);
        }
    }

    /// @notice Get the builderSplit of `self`.
    /// @param self The RiskParameters to retrieve the builderSplit from
    /// @return The builderSplit of `self`
    function builderSplit(RiskParameters self) internal pure returns (uint16) {
        unchecked {
            return uint16(RiskParameters.unwrap(self) >> 56);
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
