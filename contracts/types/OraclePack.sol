// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;
import {Constants} from "@libraries/Constants.sol";

type OraclePack is uint256;
using OraclePackLibrary for OraclePack global;

/// @title A Panoptic OraclePack. Tracks a set of 8 price observations, 4 EMAs, and a timestamp to compute the internal oracle price(s)
/// @author Axicon Labs Limited
//
//
//
// PACKING RULES FOR A ORACLEPACK:
// =================================================================================================
//  From the LSB to the MSB:
// (0) residual0        12bits  : The last recorded residual.
// (1) residual1        12bits  : The second last recorded residual.
// (2) residual2        12bits  : The third last recorded residual.
// (3) residual3        12bits  : The forth last residual.
// (4) residual4        12bits  : The fifth last residual.
// (5) residual5        12bits  : The sixth last residual.
// (6) residual6        12bits  : The seventh last residual.
// (7) residual7        12bits  : The eight last residual.
// (8) referenceTick    22bits  : The reference tick used to reconstruce the obsercations as: last recorded tick = referenceTick + r0
// (9) lockMode         2 bits  : The externally controllable safe mode override
// (10) eonsEMA         22bits  : The value of the exponential moving average (EMA) tick determined using the longest timescale
// (11) slowEMA         22bits  : The value of the EMA tick determined using the second longest timescale
// (12) fastEMA         22bits  : The value of EMA tick determined using the shortest timescale
// (13) spotEMA         22bits  : The value of spot tick determined using the near instant timescale
// (14) orderMap        24bits  : A map of the ordered residuals (see details below)
// (15) epoch           24bits  : The latest epoch as recorded using a 64s epoch-based timekeeping
// Total                256bits : Total bits used by a OraclePack.
// ===============================================================================================
//
// The bit pattern is therefore:
//
//    timestamp      orderMap      spotEMA      fastEMA       slowEMA      eonsEMA       lockMode    referenceTick      r7           r6                      r0
// |<- 24 bits ->|<- 24 bits ->|<- 22 bits ->|>- 22 bits ->|<- 22 bits >|<- 22 bits ->|<- 2 bits ->|<- 22 bits ->|<- 12bits ->|<- 12 bits ->|<- ... ->|<- 12 bits ->|
//
//
// The data for the last 8 interactions is stored as such:
// LAST UPDATED BLOCK TIMESTAMP (22 bits) -> 22 bits (use 28 bits for the timestamp and truncate the lower 6 bits to create a 64s epoch-based timekeeping)
// [BLOCK.TIMESTAMP]
// (0000000000000000000000) // dynamic
//
// ORDERING of tick indices least --> greatest (24 bits)
// The value of the bit codon ([#]) is a pointer to a tick index in the tick array.
// The position of the bit codon from most to least significant is the ordering of the
// tick index it points to from least to greatest.
//
// rank:  0   1   2   3   4   5   6   7
// slot: [7] [5] [3] [1] [0] [2] [4] [6]
//       111 101 011 001 000 010 100 110
//
//
//
library OraclePackLibrary {
    /*//////////////////////////////////////////////////////////////
                                ENCODING
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant BITMASK_UINT22 = 0x3FFFFF;
    uint256 internal constant BITMASK_UINT88 = 0xFFFFFFFFFFFFFFFFFFFFFF;
    uint256 internal constant UPPER_118BITS_MASK =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC0000000000000000000000000000000;

    uint256 internal constant LOCK_MODE_MASK = ~(uint256(3) << 118);
    uint256 internal constant LOCK_MODE_ON = uint256(3) << 118;
    uint256 internal constant LOCK_MODE_OFF = 0;

    /// @notice Create a new `OraclePack` given the relevant parameters.
    /// @param _currentEpoch The current epoch timestamp
    /// @param _newOrderMap The new order map for the observations
    /// @param _updatedEMAs The updated EMA values
    /// @param _referenceTick The reference tick
    /// @param _currentResiduals The current residual ticks
    /// @param _latestResidual The latest residual tick
    /// @param _lockMode The lock mode state
    /// @return The new OraclePack
    function storeOraclePack(
        uint256 _currentEpoch,
        uint256 _newOrderMap,
        uint256 _updatedEMAs,
        int24 _referenceTick,
        uint96 _currentResiduals,
        int24 _latestResidual,
        uint256 _lockMode
    ) internal pure returns (OraclePack) {
        unchecked {
            return
                OraclePack.wrap(
                    (_currentEpoch << 232) +
                        (_newOrderMap << 208) +
                        (_updatedEMAs << 120) +
                        ((_lockMode & 3) << 118) +
                        (uint256(uint24(_referenceTick) & BITMASK_UINT22) << 96) +
                        uint256(_currentResiduals << 12) +
                        uint256(uint16(uint24(_latestResidual) & 0x0FFF))
                );
        }
    }

    /// @notice Concatenate all oracle ticks into a single uint96.
    /// @param _spotEMA The spot EMA tick
    /// @param _fastEMA The fast EMA tick
    /// @param _slowEMA The slow EMA tick
    /// @param _eonsEMA The eons EMA tick
    /// @return A 96bit word concatenating all 4 input ticks
    function packEMAs(
        int24 _spotEMA,
        int24 _fastEMA,
        int24 _slowEMA,
        int24 _eonsEMA
    ) internal pure returns (uint96) {
        unchecked {
            return
                uint96(
                    (uint256(uint24(_spotEMA)) & BITMASK_UINT22) +
                        ((uint256(uint24(_fastEMA)) & BITMASK_UINT22) << 22) +
                        ((uint256(uint24(_slowEMA)) & BITMASK_UINT22) << 44) +
                        ((uint256(uint24(_eonsEMA)) & BITMASK_UINT22) << 66)
                );
        }
    }

    /// @notice Lock the oracle pack.
    /// @param self The OraclePack to lock
    /// @return The locked OraclePack
    function lock(OraclePack self) internal pure returns (OraclePack) {
        unchecked {
            return OraclePack.wrap((OraclePack.unwrap(self) & LOCK_MODE_MASK) + (LOCK_MODE_ON));
        }
    }

    /// @notice Unlock the oracle pack.
    /// @param self The OraclePack to unlock
    /// @return The unlocked OraclePack
    function unlock(OraclePack self) internal pure returns (OraclePack) {
        unchecked {
            return OraclePack.wrap((OraclePack.unwrap(self) & LOCK_MODE_MASK) + (LOCK_MODE_OFF));
        }
    }

    /*//////////////////////////////////////////////////////////////
                                DECODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the EMAs of `self`.
    /// @param self The OraclePack to retrieve the EMAs from
    /// @return The EMAs of `self`
    function EMAs(OraclePack self) internal pure returns (uint256) {
        unchecked {
            return (OraclePack.unwrap(self) >> 120) & BITMASK_UINT88;
        }
    }

    /// @notice Get the lastTick of `self`.
    /// @param self The OraclePack to retrieve the lastTick from
    /// @return _lastTick The lastTick of `self`
    function lastTick(OraclePack self) internal pure returns (int24 _lastTick) {
        unchecked {
            _lastTick = self.referenceTick() + self.residualTick(0);
        }
    }

    /// @notice Get the spotEMA of `self`.
    /// @param self The OraclePack to retrieve the spotEMA from
    /// @return _spotEMA The spotEMA of `self`
    function spotEMA(OraclePack self) internal pure returns (int24 _spotEMA) {
        unchecked {
            (_spotEMA, , , , ) = getEMAs(self);
        }
    }

    /// @notice Get the fastEMA of `self`.
    /// @param self The OraclePack to retrieve the fastEMA from
    /// @return _fastEMA The fastEMA of `self`
    function fastEMA(OraclePack self) internal pure returns (int24 _fastEMA) {
        unchecked {
            (, _fastEMA, , , ) = getEMAs(self);
        }
    }

    /// @notice Get the slowEMA of `self`.
    /// @param self The OraclePack to retrieve the slowEMA from
    /// @return _slowEMA The slowEMA of `self`
    function slowEMA(OraclePack self) internal pure returns (int24 _slowEMA) {
        unchecked {
            (, , _slowEMA, , ) = getEMAs(self);
        }
    }

    /// @notice Get the eonsEMA of `self`.
    /// @param self The OraclePack to retrieve the eonsEMA from
    /// @return _eonsEMA The eonsEMA of `self`
    function eonsEMA(OraclePack self) internal pure returns (int24 _eonsEMA) {
        unchecked {
            (, , , _eonsEMA, ) = getEMAs(self);
        }
    }

    /// @notice Get the all the EMA ticks of `self`.
    /// @param self The OraclePack to retrieve the EMAs from
    /// @return _spotEMA The spotEMA of `self`
    /// @return _fastEMA The fastEMA of `self`
    /// @return _slowEMA The slowEMA of `self`
    /// @return _eonsEMA The eonsEMA of `self`
    /// @return _medianTick The median tick of `self`
    function getEMAs(
        OraclePack self
    )
        internal
        pure
        returns (int24 _spotEMA, int24 _fastEMA, int24 _slowEMA, int24 _eonsEMA, int24 _medianTick)
    {
        unchecked {
            uint256 _EMAs = self.EMAs();

            _spotEMA = int22toInt24((_EMAs) & BITMASK_UINT22);
            _fastEMA = int22toInt24((_EMAs >> 22) & BITMASK_UINT22);
            _slowEMA = int22toInt24((_EMAs >> 44) & BITMASK_UINT22);
            _eonsEMA = int22toInt24((_EMAs >> 66) & BITMASK_UINT22);

            _medianTick = getMedianTick(self);
        }
    }

    /// @notice Get the order map of `self`.
    /// @param self The OraclePack to retrieve the order map from
    /// @return The order map of `self`
    function orderMap(OraclePack self) internal pure returns (uint24) {
        unchecked {
            return uint24(OraclePack.unwrap(self) >> 208);
        }
    }

    /// @notice Get the reference tick of `self`.
    /// @param self The OraclePack to retrieve the reference tick from
    /// @return The last reference tick of `self`
    function referenceTick(OraclePack self) internal pure returns (int24) {
        unchecked {
            return int22toInt24((OraclePack.unwrap(self) >> 96) & BITMASK_UINT22);
        }
    }

    /// @notice Get the residual tick of `self` at position i.
    /// @param self The OraclePack to retrieve the residual tick from
    /// @param i The position index
    /// @return The residual tick of `self` at position i
    function residualTickOrdered(OraclePack self, uint8 i) internal pure returns (int24) {
        unchecked {
            uint24 _orderMap = self.orderMap();
            uint8 index = uint8((_orderMap >> (i * 3)) & 7);
            return int12toInt24((OraclePack.unwrap(self) >> (index * 12)) & 0x0FFF);
        }
    }

    /// @notice Get the residual tick of `self` at position i.
    /// @param self The OraclePack to retrieve the residual tick from
    /// @param i The position index
    /// @return The residual tick of `self` at position i
    function residualTick(OraclePack self, uint8 i) internal pure returns (int24) {
        unchecked {
            return int12toInt24((OraclePack.unwrap(self) >> (i * 12)) & 0x0FFF);
        }
    }

    /// @notice Get the current residuals of `self`.
    /// @param self The OraclePack to retrieve the current residuals from
    /// @return The current residuals of `self`
    function currentResiduals(OraclePack self) internal pure returns (uint96) {
        unchecked {
            return uint96(OraclePack.unwrap(self));
        }
    }

    /// @notice Get the lock mode  of `self`.
    /// @param self The OraclePack to retrieve the lock mode from
    /// @return The lock mode of `self`
    function lockMode(OraclePack self) internal pure returns (uint8) {
        unchecked {
            return uint8((OraclePack.unwrap(self) >> 118) & 3);
        }
    }

    /// @notice Get the timestamp of `self`.
    /// @dev Returns a timestamp in seconds
    /// @param self The OraclePack to retrieve the timestamp from.
    /// @return The timestamp of `self`
    function timestamp(OraclePack self) internal pure returns (uint24) {
        unchecked {
            return uint24((OraclePack.unwrap(self) >> 232) << 6);
        }
    }

    /// @notice Get the epoch of `self`.
    /// @dev Returns a timestamp in 64s based epochs
    /// @param self The OraclePack to retrieve the epoch from.
    /// @return The epoch of `self`
    function epoch(OraclePack self) internal pure returns (uint24) {
        unchecked {
            return uint24((OraclePack.unwrap(self) >> 232));
        }
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Converts a 12-bit signed integer to a 24-bit signed integer with proper sign extension
    /// @dev Handles two's complement sign extension for 12-bit values stored in larger integer types
    /// @dev The function checks bit 11 (the sign bit for 12-bit integers) and extends the sign
    /// @dev if the number is negative by setting bits 12-15 to 1
    /// @param x The input value containing a 12-bit signed integer in its lower 12 bits
    /// @return The sign-extended 24-bit signed integer (as int24)
    function int12toInt24(uint256 x) internal pure returns (int24) {
        unchecked {
            // Extract only the lower 12 bits
            uint16 u = uint16(x & 0x0FFF);

            // Check if bit 11 is set
            // This is the sign bit for a 12-bit signed integer
            if ((u & 0x0800) != 0) {
                // Number is negative, extend the sign by setting bits 12-15 to 1
                u |= 0xF000;
            }
            return int24(int16(u));
        }
    }

    /// @notice Converts a 22-bit signed integer to a 24-bit signed integer with proper sign extension
    /// @dev Handles two's complement sign extension for 22-bit values stored in larger integer types
    /// @dev The function checks bit 21 (the sign bit for 22-bit integers) and extends the sign
    /// @dev if the number is negative by setting bits 22-31 to 1
    /// @param x The input value containing a 22-bit signed integer in its lower 22 bits
    /// @return The sign-extended 24-bit signed integer (as int24)
    function int22toInt24(uint256 x) internal pure returns (int24) {
        unchecked {
            // Extract only the lower 22 bits
            uint32 u = uint32(x & BITMASK_UINT22);

            // Check if bit 21 is set
            // This is the sign bit for a 22-bit signed integer
            if ((u & 0x200000) != 0) {
                // Number is negative, extend the sign by setting bits 22-31 to 1
                u |= 0xFFC00000;
            }
            return int24(int32(u));
        }
    }

    /// @notice Updates exponential moving averages (EMAs) at multiple timescales with a new tick observation
    /// @dev Implements a cascading time delta cap to prevent excessive convergence after periods of inactivity
    /// @dev EMAs converge at most 75% toward the new tick value using linear approximation: exp(-x) ≈ 1-x
    /// @dev The function modifies timeDelta in cascade: longer periods cap it first, affecting shorter periods
    /// @param oraclePack The packed median data containing current EMA values
    /// @param timeDelta Time elapsed since last update in seconds (at least 64s since observations have to be in different epochs)
    /// @param newTick The new tick observation to update EMAs toward
    /// @param EMAperiods The packed EMA period values for spot, fast, slow, and eons EMAs
    /// @return updatedEMAs The packed 88-bit value containing all four updated EMAs
    function updateEMAs(
        OraclePack oraclePack,
        int256 timeDelta,
        int24 newTick,
        uint96 EMAperiods
    ) internal pure returns (uint256 updatedEMAs) {
        unchecked {
            int256 EMA_PERIOD_SPOT = int24(uint24(EMAperiods));
            int256 EMA_PERIOD_FAST = int24(uint24(EMAperiods >> 24));
            int256 EMA_PERIOD_SLOW = int24(uint24(EMAperiods >> 48));
            int256 EMA_PERIOD_EONS = int24(uint24(EMAperiods >> 72));

            // Extract current EMAs from oraclePack (88 bits starting at bit 120)
            uint256 _EMAs = oraclePack.EMAs();

            // Update eons EMA (bits 87-66)
            int24 _eonsEMA = int22toInt24((_EMAs >> 66) & BITMASK_UINT22);
            if (timeDelta > (3 * EMA_PERIOD_EONS) / 4) timeDelta = (3 * EMA_PERIOD_EONS) / 4;
            _eonsEMA = int24(_eonsEMA + (timeDelta * (newTick - _eonsEMA)) / EMA_PERIOD_EONS);

            // Update slow EMA (bits 65-44)
            int24 _slowEMA = int22toInt24((_EMAs >> 44) & BITMASK_UINT22);
            if (timeDelta > (3 * EMA_PERIOD_SLOW) / 4) timeDelta = (3 * EMA_PERIOD_SLOW) / 4;
            _slowEMA = int24(_slowEMA + (timeDelta * (newTick - _slowEMA)) / EMA_PERIOD_SLOW);

            // Update fast EMA (bits 43-22)
            int24 _fastEMA = int22toInt24((_EMAs >> 22) & BITMASK_UINT22);
            if (timeDelta > (3 * EMA_PERIOD_FAST) / 4) timeDelta = (3 * EMA_PERIOD_FAST) / 4;
            _fastEMA = int24(_fastEMA + (timeDelta * (newTick - _fastEMA)) / EMA_PERIOD_FAST);

            // Update spot EMA (bits 21-0)
            int24 _spotEMA = int22toInt24(_EMAs & BITMASK_UINT22);
            if (timeDelta > (3 * EMA_PERIOD_SPOT) / 4) timeDelta = (3 * EMA_PERIOD_SPOT) / 4;
            _spotEMA = int24(_spotEMA + (timeDelta * (newTick - _spotEMA)) / EMA_PERIOD_SPOT);

            // Pack updated EMAs back into 88-bit format
            updatedEMAs = packEMAs(_spotEMA, _fastEMA, _slowEMA, _eonsEMA);
        }
    }

    /// @notice Calculates the median tick from a packed median data structure
    /// @dev Retrieves the 3rd and 4th ranked values from the sorted 8-slot queue and returns their average
    /// @dev The median is calculated as: referenceTick + (rank3_residual + rank4_residual) / 2
    /// @param oraclePack The packed structure containing:
    ///                   - Order map indicating the rank of each slot
    ///                   - Reference tick for absolute positioning
    ///                   - 8 tick observations stored as 12-bit signed residuals relative to reference tick
    /// @return medianTick The median tick value, representing the middle value of the sorted observations
    function getMedianTick(OraclePack oraclePack) internal pure returns (int24) {
        unchecked {
            int24 rank3 = oraclePack.residualTickOrdered(3);
            int24 rank4 = oraclePack.residualTickOrdered(4);

            int24 _referenceTick = oraclePack.referenceTick();

            return _referenceTick + ((rank3) + (rank4)) / 2;
        }
    }

    /// @notice Inserts a new tick observation into the median data structure and updates EMAs
    /// @dev Updates the sorted queue by finding the correct insertion point for the new tick residual
    /// @dev The function maintains an 8-slot sorted queue using a 24-bit order map where each 3-bit segment
    /// @dev represents the rank of the corresponding slot. Slot 7 is reserved for the new observation.
    /// @param oraclePack The current packed median data structure containing:
    ///                   - Bits 255-232: Current epoch timestamp
    ///                   - Bits 231-208: 24-bit order map (8 slots × 3 bits each)
    ///                   - Bits 207-128: Reserved for EMA data (88 bits): 10mins, 1hour, 8hour and 1day
    ///                   - Bits 127-96:  Reference tick (24 bits)
    ///                   - Bits 95-12:   Previous observations as 12-bit residuals (84 bits)
    ///                   - Bits 11-0:    Most recent observation residual (12 bits)
    /// @param newTick The new tick observation to insert (as a residual relative to reference tick)
    /// @param currentEpoch The current epoch timestamp ((block.timestamp >> 6) & 0xFFFFFF)
    /// @param timeDelta Time difference in seconds between current and last epoch (currentEpoch - recordedEpoch) * 64
    /// @param EMAperiods The packed EMA period values for spot, fast, slow, and eons EMAs
    /// @return newOraclePack The updated oraclePack with the new observation inserted
    function insertObservation(
        OraclePack oraclePack,
        int24 newTick,
        uint256 currentEpoch,
        int256 timeDelta,
        uint96 EMAperiods
    ) internal pure returns (OraclePack newOraclePack) {
        unchecked {
            int24 _referenceTick = oraclePack.referenceTick();
            int24 lastResidual = newTick - _referenceTick;

            // update oracle pack and reference tick if the move is beyond residual threshold
            if (
                (lastResidual > Constants.MAX_RESIDUAL_THRESHOLD) ||
                (lastResidual < -Constants.MAX_RESIDUAL_THRESHOLD)
            ) {
                (_referenceTick, oraclePack) = rebaseOraclePack(oraclePack);
                lastResidual = newTick - _referenceTick;
            }

            uint24 _newOrderMap;
            {
                uint24 _orderMap = oraclePack.orderMap();
                uint256 _oraclePack = OraclePack.unwrap(oraclePack);
                uint24 shift = 1;
                bool below = true;
                uint24 rank;
                int24 entry;
                for (uint8 i; i < 8; ++i) {
                    // read the rank from the existing ordering
                    rank = (_orderMap >> (3 * i)) & 7; // mod 2**3

                    if (rank == 7) {
                        shift -= 1;
                        continue;
                    }

                    // read the corresponding entry
                    entry = int12toInt24((_oraclePack >> (rank * 12)) & 0x0FFF); // mod 2**12
                    if ((below) && (lastResidual > entry)) {
                        shift += 1;
                        below = false;
                    }

                    _newOrderMap = _newOrderMap + ((rank + 1) << (3 * (i + shift - 1)));
                }
            }

            {
                uint256 _EMAs = updateEMAs(oraclePack, timeDelta, newTick, EMAperiods);

                uint8 _lockMode = oraclePack.lockMode();

                uint96 _currentResiduals = oraclePack.currentResiduals();

                newOraclePack = storeOraclePack(
                    currentEpoch,
                    _newOrderMap,
                    _EMAs,
                    _referenceTick,
                    _currentResiduals,
                    lastResidual,
                    _lockMode
                );
            }
        }
    }

    /// @notice Clamps a new tick observation to prevent large price movements that could manipulate the median
    /// @dev Limits the new tick to be within `clampDelta` of the most recent tick observation
    /// @dev This prevents flash loan attacks or other price manipulation attempts from skewing the median calculation
    /// @param newTick The new tick observation from Uniswap TWAP that needs to be clamped
    /// @param _oraclePack The current OraclePack containing the reference tick and most recent observation
    /// @param clampDelta The maximum allowed tick deviation from the last observation
    /// @return clamped The clamped tick value, guaranteed to be within `clampDelta` of the last observation
    function clampTick(
        int24 newTick,
        OraclePack _oraclePack,
        int24 clampDelta
    ) internal pure returns (int24 clamped) {
        unchecked {
            int24 _lastTick = _oraclePack.lastTick();

            // Clamp lastObservedTick to be within clampDelta of lastTick
            if (newTick > _lastTick + clampDelta) {
                clamped = _lastTick + clampDelta;
            } else if (newTick < _lastTick - clampDelta) {
                clamped = _lastTick - clampDelta;
            } else {
                clamped = newTick;
            }
        }
    }

    /// @notice Takes a packed structure representing a sorted 8-slot queue of ticks and returns the median of those values and an updated queue if another observation is warranted.
    /// @dev Also inserts the latest Uniswap observation into the buffer, resorts, and returns if the last entry is at least `period` seconds old.
    /// @param oraclePack The packed structure representing the sorted 8-slot queue of ticks
    /// @param currentTick The current tick as return from slot0
    /// @return _medianTick The median of the provided 8-slot queue of ticks in `oraclePack`
    /// @return _updatedOraclePack The updated 8-slot queue of ticks with the latest observation inserted if the last entry is at least `period` seconds old (returns 0 otherwise)
    function computeInternalMedian(
        OraclePack oraclePack,
        int24 currentTick,
        uint96 EMAperiods,
        int24 clampDelta
    ) internal view returns (int24 _medianTick, OraclePack _updatedOraclePack) {
        unchecked {
            // return the average of the rank 3 and 4 values
            _medianTick = getMedianTick(oraclePack);

            uint256 currentEpoch;
            bool differentEpoch;
            int256 timeDelta;
            {
                currentEpoch = (block.timestamp >> 6) & 0xFFFFFF; // 64-long epoch, taken mod 2**24
                uint256 recordedEpoch = oraclePack.epoch();
                differentEpoch = currentEpoch != recordedEpoch;
                timeDelta = int256(uint256(uint24(currentEpoch - recordedEpoch))) * 64; // take a rought time delta, based on the epochs
            }
            // only proceed if last entry is in a different epoch
            if (differentEpoch) {
                int24 clampedTick = clampTick(currentTick, oraclePack, clampDelta);
                _updatedOraclePack = insertObservation(
                    oraclePack,
                    clampedTick,
                    currentEpoch,
                    timeDelta,
                    EMAperiods
                );
            }
        }
    }

    /// @notice Computes various oracle prices corresponding to a Uniswap pool.
    /// @param self The packed structure representing the sorted 8-slot queue of internal median observations
    /// @param _currentTick The current tick in the Uniswap pool
    /// @param _EMAperiods A packed uint96 containing the EMA period data
    /// @param clampDelta The max change in tick between updates
    /// @return spotEMATick The spot tick, computed from the shortest timescale EMA
    /// @return medianTick The median oracle tick computed from the last 8 observations
    /// @return latestTick The latest observed tick in Panoptic before the current transaction
    /// @return oraclePack The updated value for `s_oraclePack` (0 if not enough time has passed since last observation)
    function getOracleTicks(
        OraclePack self,
        int24 _currentTick,
        uint96 _EMAperiods,
        int24 clampDelta
    )
        internal
        view
        returns (int24 spotEMATick, int24 medianTick, int24 latestTick, OraclePack oraclePack)
    {
        // Extract the spot EMA from the lowest 22 bits of the packed EMAs value
        spotEMATick = self.spotEMA();

        // get the tick at the last protocol interaction
        latestTick = self.lastTick();

        // finally, get the median tick
        (medianTick, oraclePack) = computeInternalMedian(
            self,
            _currentTick,
            _EMAperiods,
            clampDelta
        );
    }

    /// @notice Rebases the median data structure when tick residuals exceed the 12-bit signed integer range
    /// @dev When residuals become too large (>2047 or <-2048), this function shifts the reference tick
    /// @dev to the current median and adjusts all stored residuals relative to the new reference
    /// @dev This maintains precision while keeping residuals within the 12-bit storage constraint
    /// @param oraclePack The current oraclePack with residuals that have exceeded the threshold
    /// @return _newReferenceTick The new reference tick (set to the current median)
    /// @return rebasedOraclePack The updated median data structure with:
    ///                     - New reference tick set to the current median
    ///                     - All residuals recalculated relative to the new reference
    ///                     - All other data (order map, EMAs, epoch) preserved
    function rebaseOraclePack(
        OraclePack oraclePack
    ) internal pure returns (int24 _newReferenceTick, OraclePack rebasedOraclePack) {
        unchecked {
            int24 _referenceTick = oraclePack.referenceTick();

            _newReferenceTick = getMedianTick(oraclePack);
            int24 deltaOffset = _newReferenceTick - _referenceTick;

            uint256 _newResiduals;
            for (uint8 i; i < 8; ++i) {
                int24 _residual = oraclePack.residualTick(i);
                int24 newEntry = _residual - deltaOffset;
                _newResiduals += (uint256(uint16(uint24(newEntry) & 0x0FFF)) & 0x0FFF) << (i * 12);
            }

            rebasedOraclePack = OraclePack.wrap(
                (OraclePack.unwrap(oraclePack) & UPPER_118BITS_MASK) +
                    (uint256(uint24(_newReferenceTick) & BITMASK_UINT22) << 96) +
                    uint96(_newResiduals)
            );
        }
    }
}
