// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

type MarketState is uint256;
using MarketStateLibrary for MarketState global;

/// @title A Panoptic Market State. Tracks the data of a given CollateralTracker market.
/// @author Axicon Labs Limited
//
//
// PACKING RULES FOR A MARKETSTATE:
// =================================================================================================
//  From the LSB to the MSB:
// (0) borrowIndex          80 bits : Global borrow index in WAD (starts at 1e18). 2**80 = 1.75 years at 800% interest
// (1) marketEpoch          32 bits : Last interaction epoch for that market (1 epoch = block.timestamp/4)
// (2) rateAtTarget         38 bits : The rateAtTarget value in WAD (2**38 = 800% interest rate)
// (3) unrealizedInterest   106bits : Accumulated unrealized interest that hasn't been distributed (max deposit is 2**104)
// Total                    256bits  : Total bits used by a MarketState.
// ===============================================================================================
//
// The bit pattern is therefore:
//
//          (3)                 (2)                 (1)                 (0)
//    <---- 106 bits ----><---- 38 bits ----><---- 32 bits ----><---- 80 bits ---->
//     unrealizedInterest    rateAtTarget        marketEpoch        borrowIndex
//
//    <--- most significant bit                              least significant bit --->
//
library MarketStateLibrary {
    // =============================================================
    // CONSTANTS (MASKS)
    // =============================================================
    // We define "Positive Masks" (1s where the data is, 0s elsewhere).
    // We will use NOT(MASK) to clear data.

    // Bits 0-79 (80 bits)
    uint256 internal constant BORROW_INDEX_MASK = (1 << 80) - 1;

    // Bits 80-111 (32 bits)
    uint256 internal constant EPOCH_MASK = ((1 << 32) - 1) << 80;

    // Bits 112-149 (38 bits)
    uint256 internal constant TARGET_RATE_MASK = ((1 << 38) - 1) << 112;

    // Bits 150-255 (106 bits)
    uint256 internal constant UNREALIZED_INTEREST_MASK =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFC0000000000000000000000000000000000000;

    /*//////////////////////////////////////////////////////////////
                                ENCODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new `MarketState` object.
    /// @param _borrowIndex The global index (uint80)
    /// @param _marketEpoch The market's epoch (uint32)
    /// @param _rateAtTarget The rateAtTarget (uint38)
    /// @param _unrealizedInterest The unrealized interest (uint106)
    /// @return result The new MarketState object
    function storeMarketState(
        uint256 _borrowIndex,
        uint256 _marketEpoch,
        uint256 _rateAtTarget,
        uint256 _unrealizedInterest
    ) internal pure returns (MarketState result) {
        assembly {
            result := add(
                add(add(_borrowIndex, shl(80, _marketEpoch)), shl(112, _rateAtTarget)),
                shl(150, _unrealizedInterest)
            )
        }
    }

    /// @notice Update the Global Borrow Index (Lowest 80 bits)
    /// @param self The MarketState to update
    /// @param newIndex The new borrow index value
    /// @return result The updated MarketState with the new borrow index
    function updateBorrowIndex(
        MarketState self,
        uint80 newIndex
    ) internal pure returns (MarketState result) {
        assembly {
            // 1. Clear the lowest 80 bits using not(BORROW_INDEX_MASK)
            let cleared := and(self, not(BORROW_INDEX_MASK))
            // 2. OR with the new value (no shift needed, it's at 0)
            result := or(cleared, newIndex)
        }
    }

    /// @notice Update the Market Epoch (Bits 80-111)
    /// @param self The MarketState to update
    /// @param newEpoch The new market epoch value
    /// @return result The updated MarketState with the new market epoch
    function updateMarketEpoch(
        MarketState self,
        uint32 newEpoch
    ) internal pure returns (MarketState result) {
        assembly {
            // 1. Clear bits 80-111
            let cleared := and(self, not(EPOCH_MASK))
            // 2. Shift new value to 80 and combine
            result := or(cleared, shl(80, newEpoch))
        }
    }

    /// @notice Update the Rate At Target (Bits 112-149)
    /// @param self The MarketState to update
    /// @param newRate The new rate at target value
    /// @return result The updated MarketState with the new rate at target
    function updateRateAtTarget(
        MarketState self,
        uint40 newRate
    ) internal pure returns (MarketState result) {
        assembly {
            // 1. Clear bits 112-149
            let cleared := and(self, not(TARGET_RATE_MASK))

            // 2. Safety: Mask the input to ensure it fits in 38 bits (0x3FFFFFFFFF)
            //    This prevents 'newRate' from corrupting the neighbor if it > 38 bits.
            let safeRate := and(newRate, 0x3FFFFFFFFF)

            // 3. Shift to 112 and combine
            result := or(cleared, shl(112, safeRate))
        }
    }

    /// @notice Update the Unrealized Interest (Bits 150-255)
    /// @param self The MarketState to update
    /// @param newInterest The new unrealized interest value
    /// @return result The updated MarketState with the new unrealized interest
    function updateUnrealizedInterest(
        MarketState self,
        uint128 newInterest
    ) internal pure returns (MarketState result) {
        assembly {
            // 1. Clear bits 150-255
            let cleared := and(self, not(UNREALIZED_INTEREST_MASK))

            // 2. Safety: Mask input to 106 bits
            //    (1 << 106) - 1
            let max106 := sub(shl(106, 1), 1)
            let safeInterest := and(newInterest, max106)

            // 3. Shift to 150 and combine
            result := or(cleared, shl(150, safeInterest))
        }
    }

    /*//////////////////////////////////////////////////////////////
                                DECODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the borrowIndex of `self`.
    /// @param self The MarketState to retrieve the borrowIndex state from
    /// @return result The borrowIndex of `self`
    function borrowIndex(MarketState self) internal pure returns (uint80 result) {
        assembly {
            result := and(self, 0xFFFFFFFFFFFFFFFFFFFF)
        }
    }

    /// @notice Get the marketEpoch of `self`.
    /// @param self The MarketState to retrieve the marketEpoch from
    /// @return result The marketEpoch of `self`
    function marketEpoch(MarketState self) internal pure returns (uint32 result) {
        assembly {
            result := and(shr(80, self), 0xFFFFFFFF)
        }
    }

    /// @notice Get the rateAtTarget of `self`.
    /// @param self The MarketState to retrieve the rateAtTarget from
    /// @return result The rateAtTarget of `self`
    function rateAtTarget(MarketState self) internal pure returns (uint40 result) {
        assembly {
            result := and(shr(112, self), 0x3FFFFFFFFF)
        }
    }

    /// @notice Get the unrealizedInterest of `self`.
    /// @param self The MarketState to retrieve the unrealizedInterest from
    /// @return result The unrealizedInterest of `self`
    function unrealizedInterest(MarketState self) internal pure returns (uint128 result) {
        assembly {
            result := shr(150, self)
        }
    }
}
