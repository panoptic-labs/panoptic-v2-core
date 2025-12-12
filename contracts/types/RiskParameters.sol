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
// (1) safeMode             4 bits  : The safeMode state
// (2) notionalFee          14 bits : The fee to be charged on notional at mint
// (3) premiumFee           14 bits : The fee to be charged on the premium at burn
// (4) protocolSplit        14 bits : The part of the fee that goes to the protocol w/ buildercodes
// (5) builderSplit         14 bits : The part of the fee that goes to the builder w/ buildercodes
// (6) tickDeltaLiquidation 13 bits : The MAX_TWAP_DELTA_LIQUIDATION. Tick deviation = 1.0001**(2**13) = +/- 126%
// (7) maxSpread            22 bits : The MAX_SPREAD, in bps. Max fraction removed = 2**22/(2**22 + 10_000) = 99.76%
// (8) bpDecreaseBuffer     26 bits : The BP_DECREASE_BUFFER, in millitick
// (9) maxLegs              7 bits  : The MAX_OPEN_LEGS (constrained to be <128)
// (9) feeRecipient         128bits : The recipient of the commission fee split
// Total                    256bits  : Total bits used by a RiskParameters.
// ===============================================================================================
//
// The bit pattern is therefore:
//
//          (9)              (8)          (7)              (6)             (5)            (4)          (3)             (2)              (1)
//    <-- 128 bits --><-- 7 bits --><-- 26 bits --><-- 22 bits --><-- 13 bits --><-- 14 bits --><-- 14 bits --> <-- 14 bits --> <-- 14 bits --> <-- 4 bits -->
//        feeRecipient   maxLegs      bpDecrease      maxSpread      tickDelta    builderSplit   protocolSplit    premiumFee    notionalFee         safeMode
//
//    <--- most significant bit                                                                  least significant bit --->
//
library RiskParametersLibrary {
    /*//////////////////////////////////////////////////////////////
                                ENCODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new `RiskParameters` object.
    /// @param _safeMode The safe mode state (uint6)
    /// @param _notionalFee The commission fee (uint14)
    /// @param _premiumFee The commission fee (uint14)
    /// @param _protocolSplit The part of the fee that goes to the protocol w/ buildercodes (uint14)
    /// @param _builderSplit The part of the fee that goes to the builder w/ buildercodes (uint14)
    /// @param _tickDeltaLiquidation The MAX_TWAP_DELTA_LIQUIDATION (uint16)
    /// @param _maxSpread The MAX_SPREAD, in bps (uint24)
    /// @param _bpDecreaseBuffer The BP_DECREASE_BUFFER, in millitick (uint26)
    /// @param _maxLegs The maximum allowed number of legs across all open positions for a user
    /// @param _feeRecipient The recipient of the commission fee split (uint128)
    /// @return result The new RiskParameters object
    function storeRiskParameters(
        uint256 _safeMode,
        uint256 _notionalFee,
        uint256 _premiumFee,
        uint256 _protocolSplit,
        uint256 _builderSplit,
        uint256 _tickDeltaLiquidation,
        uint256 _maxSpread,
        uint256 _bpDecreaseBuffer,
        uint256 _maxLegs,
        uint256 _feeRecipient
    ) internal pure returns (RiskParameters result) {
        assembly {
            result := add(
                add(
                    add(
                        add(_safeMode, shl(4, _notionalFee)),
                        add(shl(18, _premiumFee), shl(32, _protocolSplit))
                    ),
                    add(shl(46, _builderSplit), shl(60, _tickDeltaLiquidation))
                ),
                add(
                    add(shl(73, _maxSpread), add(shl(95, _bpDecreaseBuffer), shl(121, _maxLegs))),
                    shl(128, _feeRecipient)
                )
            )
        }
    }

    /*//////////////////////////////////////////////////////////////
                                DECODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the safeMode state of `self`.
    /// @param self The RiskParameters to retrieve the safeMode state from
    /// @return result The safeMode of `self`
    function safeMode(RiskParameters self) internal pure returns (uint8 result) {
        assembly {
            result := and(self, 0xF)
        }
    }

    /// @notice Get the notionalFee of `self`.
    /// @param self The RiskParameters to retrieve the notionalFee from
    /// @return result The notionalFee of `self`
    function notionalFee(RiskParameters self) internal pure returns (uint16 result) {
        assembly {
            result := and(shr(4, self), 0x3FFF)
        }
    }

    /// @notice Get the premiumFee of `self`.
    /// @param self The RiskParameters to retrieve the premiumFee from
    /// @return result The premiumFee of `self`
    function premiumFee(RiskParameters self) internal pure returns (uint16 result) {
        assembly {
            result := and(shr(18, self), 0x3FFF)
        }
    }

    /// @notice Get the protocolSplit of `self`.
    /// @param self The RiskParameters to retrieve the protocolSplit from
    /// @return result The protocolSplit of `self`
    function protocolSplit(RiskParameters self) internal pure returns (uint16 result) {
        assembly {
            result := and(shr(32, self), 0x3FFF)
        }
    }

    /// @notice Get the builderSplit of `self`.
    /// @param self The RiskParameters to retrieve the builderSplit from
    /// @return result The builderSplit of `self`
    function builderSplit(RiskParameters self) internal pure returns (uint16 result) {
        assembly {
            result := and(shr(46, self), 0x3FFF)
        }
    }

    /// @notice Get the tickDeltaLiquidation of `self`.
    /// @param self The RiskParameters to retrieve the tickDeltaLiquidation from
    /// @return result The tickDeltaLiquidation of `self`
    function tickDeltaLiquidation(RiskParameters self) internal pure returns (uint16 result) {
        assembly {
            result := and(shr(60, self), 0x1FFF)
        }
    }

    /// @notice Get the maxSpread of `self`.
    /// @param self The RiskParameters to retrieve the maxSpread from
    /// @return result The maxSpread of `self`
    function maxSpread(RiskParameters self) internal pure returns (uint24 result) {
        assembly {
            result := and(shr(73, self), 0x3FFFFF)
        }
    }

    /// @notice Get the bpDecreaseBuffer of `self`.
    /// @param self The RiskParameters to retrieve the bpDecreaseBuffer from
    /// @return result The bpDecreaseBuffer of `self`
    function bpDecreaseBuffer(RiskParameters self) internal pure returns (uint32 result) {
        assembly {
            result := and(shr(95, self), 0x3FFFFFF)
        }
    }

    /// @notice Get the maxLegs of `self`.
    /// @param self The RiskParameters to retrieve the maxLegs from
    /// @return result The maxLegs of `self`
    function maxLegs(RiskParameters self) internal pure returns (uint8 result) {
        assembly {
            result := and(shr(121, self), 0x7F)
        }
    }

    /// @notice Get the feeRecipient of `self`.
    /// @param self The RiskParameters to retrieve the feeRecipient from
    /// @return result The feeRecipient of `self`
    function feeRecipient(RiskParameters self) internal pure returns (uint128 result) {
        assembly {
            result := shr(128, self)
        }
    }
}
