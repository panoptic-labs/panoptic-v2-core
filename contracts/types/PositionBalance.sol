// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

type PositionBalance is uint256;
using PositionBalanceLibrary for PositionBalance global;

/// @title A Panoptic Position Balance. Tracks the Position Size, the Pool Utilizations at mint, and the current/fastOracle/slowOracle/latestObserved ticks at mint.
/// @author Axicon Labs Limited
//
//
// PACKING RULES FOR A POSITIONBALANCE:
// =================================================================================================
//  From the LSB to the MSB:
// (1) positionSize       128bits : The size of this position (uint128).
// (2) poolUtilization0   16bits  : The pool utilization of token0, stored as (10000 * inAMM0)/totalAssets0 (uint16).
// (3) poolUtilization1   16bits  : The pool utilization of token1, stored as (10000 * inAMM1)/totalAssets1 (uint16).
// (4) maxLongPremiaX80   96bits  : The maximum amount of long premia to be paid, computed as a function of the amount of tokens moved in that position.
// Total                  256bits : Total bits used by a PositionBalance.
// ===============================================================================================
//
// The bit pattern is therefore:
//
//        (4)             (3)             (2)             (1)
//   <-- 96 bits --> <-- 16 bits --> <-- 16 bits --> <-- 128 bits -->
//  maxLongPremiaX80   utilization1    utilization0    positionSize
//
//    <--- most significant bit                            least significant bit --->
//
library PositionBalanceLibrary {
    /*//////////////////////////////////////////////////////////////
                                ENCODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new `PositionBalance` given by positionSize, utilizations, and its tickData.
    /// @param _positionSize The amount of option minted
    /// @param _utilizations Packed data containing pool utilizations for token0 and token1 at mint
    /// @param _maxLongPremiaX80 The maximum amount of long premia to be paid
    /// @return The new PositionBalance with the given positionSize, utilization, and tickData
    function storeBalanceData(
        uint128 _positionSize,
        uint32 _utilizations,
        uint96 _maxLongPremiaX80
    ) internal pure returns (PositionBalance) {
        unchecked {
            return
                PositionBalance.wrap(
                    (uint256(_maxLongPremiaX80) << 160) +
                        (uint256(_utilizations) << 128) +
                        uint256(_positionSize)
                );
        }
    }

    /// @notice Concatenate all oracle ticks into a single uint96.
    /// @param _currentTick The current tick
    /// @param _fastOracleTick The fast oracle tick
    /// @param _slowOracleTick The slow oracle tick
    /// @param _lastObservedTick The last observed tick
    /// @return A 96bit word concatenating all 4 input ticks
    function packTickData(
        int24 _currentTick,
        int24 _fastOracleTick,
        int24 _slowOracleTick,
        int24 _lastObservedTick
    ) internal pure returns (uint96) {
        unchecked {
            return
                uint96(uint24(_currentTick)) +
                (uint96(uint24(_fastOracleTick)) << 24) +
                (uint96(uint24(_slowOracleTick)) << 48) +
                (uint96(uint24(_lastObservedTick)) << 72);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                DECODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the tickData of `self`.
    /// @param self The PositionBalance to retrieve the tickData from
    /// @return The packed tickData (currentTick, fastOracleTick, slowOracleTick, lastObservedTick)
    function tickData(PositionBalance self) internal pure returns (uint96) {
        unchecked {
            return uint96(PositionBalance.unwrap(self) >> 160);
        }
    }

    /// @notice Unpack the current, last observed, and fast/slow oracle ticks from a 96-bit tickData encoding.
    /// @param _tickData The packed tickData to unpack ticks from
    /// @return The current tick contained in `_tickData`
    /// @return The fast oracle tick contained in `_tickData`
    /// @return The slow oracle tick contained in `_tickData`
    /// @return The last observed tick contained in `_tickData`
    function unpackTickData(uint96 _tickData) internal pure returns (int24, int24, int24, int24) {
        PositionBalance self = PositionBalance.wrap(uint256(_tickData) << 160);
        return (
            int24(int256(PositionBalance.unwrap(self) >> 160)),
            int24(int256(PositionBalance.unwrap(self) >> 184)),
            int24(int256(PositionBalance.unwrap(self) >> 208)),
            int24(int256(PositionBalance.unwrap(self) >> 232))
        );
    }

    /// @notice Get token0 utilization of `self`.
    /// @param self The PositionBalance to retrieve the token0 utilization from
    /// @return The token0 utilization in basis points
    function utilization0(PositionBalance self) internal pure returns (int256) {
        unchecked {
            return int256((PositionBalance.unwrap(self) >> 128) % 2 ** 16);
        }
    }

    /// @notice Get token1 utilization of `self`.
    /// @param self The PositionBalance to retrieve the token1 utilization from
    /// @return The token1 utilization in basis points
    function utilization1(PositionBalance self) internal pure returns (int256) {
        unchecked {
            return int256((PositionBalance.unwrap(self) >> 144) % 2 ** 16);
        }
    }

    /// @notice Get both token0 and token1 utilizations of `self`.
    /// @param self The PositionBalance to retrieve the utilizations from
    /// @return The packed utilizations for token0 and token1 in basis points
    function utilizations(PositionBalance self) internal pure returns (uint32) {
        unchecked {
            return uint32(PositionBalance.unwrap(self) >> 128);
        }
    }

    /// @notice Get the positionSize of `self`.
    /// @param self The PositionBalance to retrieve the positionSize from
    /// @return The positionSize of `self`
    function positionSize(PositionBalance self) internal pure returns (uint128) {
        unchecked {
            return uint128(PositionBalance.unwrap(self));
        }
    }

    /// @notice Get the maxLongPremiaX80  of `self`.
    /// @param self The PositionBalance to retrieve the maxLongPremiaX80 from
    /// @return The maxLongPremiaX80 of `self`
    function maxLongPremia(PositionBalance self) internal pure returns (uint96) {
        unchecked {
            return uint96(PositionBalance.unwrap(self) >> 160);
        }
    }

    /// @notice Unpack all data from `self`.
    /// @param self The PositionBalance to get all data from
    /// @return _maxLongPremia maxLongPremia for this position
    /// @return utilization0AtMint Utilization of token0 at mint
    /// @return utilization1AtMint Utilization of token1 at mint
    /// @return _positionSize Size of the position
    function unpackAll(
        PositionBalance self
    )
        external
        pure
        returns (
            uint96 _maxLongPremia,
            int256 utilization0AtMint,
            int256 utilization1AtMint,
            uint128 _positionSize
        )
    {
        _maxLongPremia = self.maxLongPremia();

        utilization0AtMint = self.utilization0();
        utilization1AtMint = self.utilization1();

        _positionSize = self.positionSize();
    }
}
