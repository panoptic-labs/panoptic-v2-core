// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.24;

// Custom types
import {TokenId} from "@types/TokenId.sol";

type PositionBalance is uint256;
using PositionBalanceLibrary for PositionBalance global;

/// @title A Panoptic Liquidity Chunk. Tracks Tick Range and Liquidity Information for a "chunk." Used to track movement of chunks.
/// @author Axicon Labs Limited
///
/// @notice A liquidity chunk is an amount of `liquidity` (an amount of WETH, e.g.) deployed between two ticks: `tickLower` and `tickUpper`
/// into a concentrated liquidity AMM.
//
//                liquidity
//                    ▲      liquidity chunk
//                    │        │
//                    │    ┌───▼────┐   ▲
//                    │    │        │   │ liquidity/size
//      Other AMM     │  ┌─┴────────┴─┐ ▼ of chunk
//      liquidity  ───┼──┼─►          │
//                    │  │            │
//                    └──┴─▲────────▲─┴──► price ticks
//                         │        │
//                         │        │
//                    tickLower     │
//                              tickUpper
//
/// @notice Track Tick Range Information. Lower and Upper ticks including the liquidity deployed within that range.
/// @notice This is used to track information about a leg in the Option Position identified by `TokenId.sol`.
/// @notice We pack this tick range info into a uint256.
//
// PACKING RULES FOR A LIQUIDITYCHUNK:
// =================================================================================================
//  From the LSB to the MSB:
// (1) Liquidity        128bits  : The liquidity within the chunk (uint128).
// ( ) (Zero-bits)       80bits  : Zero-bits to match a total uint256.
// (2) tick Upper        24bits  : The upper tick of the chunk (int24).
// (3) tick Lower        24bits  : The lower tick of the chunk (int24).
// Total                256bits  : Total bits used by a chunk.
// ===============================================================================================
//
// The bit pattern is therefore:
//
//           (3)             (2)             ( )                (1)
//    <-- 24 bits -->  <-- 24 bits -->  <-- 80 bits -->   <-- 128 bits -->
//        tickLower       tickUpper         Zeros             Liquidity
//
//        <--- most significant bit        least significant bit --->
//
library PositionBalanceLibrary {
    /// @notice AND mask to strip the `tickLower` value from a packed LiquidityChunk.
    uint256 internal constant CLEAR_TL_MASK =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    /// @notice AND mask to strip the `tickUpper` value from a packed LiquidityChunk.
    uint256 internal constant CLEAR_TU_MASK =
        0xFFFFFF000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    /*//////////////////////////////////////////////////////////////
                                ENCODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new `PositionBalance` given by positionSize, utilizations, and its tickData.
    /// @param positionSize The amount of option minted
    /// @param utilizations packing of two uint16 utilizations into a 32 bit word
    /// @param tickData packing of 4 int25s into a single uint96
    /// @return The new PositionBalance with the given positionSize, utilization, and tickData
    function storeBalanceData(
        uint128 positionSize,
        uint32 utilizations,
        uint96 tickData
    ) internal pure returns (PositionBalance) {
        unchecked {
            return
                PositionBalance.wrap(
                    (uint256(tickData) << 160) +
                        (uint256(utilizations) << 128) +
                        uint256(positionSize)
                );
        }
    }

    function createTickData(
        int24 currentTick,
        int24 fastOracleTick,
        int24 slowOracleTick,
        int24 lastObservedTick
    ) internal pure returns (uint96) {
        return
            uint96(
                uint24(currentTick) +
                    (uint24(fastOracleTick) << 24) +
                    (uint24(slowOracleTick) << 48) +
                    (uint24(lastObservedTick) << 72)
            );
    }

    /*//////////////////////////////////////////////////////////////
                                DECODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the last observed tick of `self`.
    /// @param self The PositionBalance to get the requested tick
    /// @return The last observed tick of self
    function lastObservedTick(PositionBalance self) internal pure returns (int24) {
        unchecked {
            return int24(int256(PositionBalance.unwrap(self) >> 232));
        }
    }

    /// @notice Get the slow oracle tick of `self`.
    /// @param self The PositionBalance to get the requested tick
    /// @return The slow oracle tick of self
    function slowOracleTick(PositionBalance self) internal pure returns (int24) {
        unchecked {
            return int24(int256(PositionBalance.unwrap(self) >> 208));
        }
    }

    /// @notice Get the last observed tick of `self`.
    /// @param self The PositionBalance to get the last observed tick
    /// @return The fast oracle tick of self
    function fastOracleTick(PositionBalance self) internal pure returns (int24) {
        unchecked {
            return int24(int256(PositionBalance.unwrap(self) >> 184));
        }
    }

    /// @notice Get the current tick of `self`.
    /// @param self The PositionBalance to get the requested tick
    /// @return The current tick of self
    function currentTick(PositionBalance self) internal pure returns (int24) {
        unchecked {
            return int24(int256(PositionBalance.unwrap(self) >> 160));
        }
    }

    /// @notice Get token1 utilization of `self`.
    /// @param self The PositionBalance to get utilization
    /// @return The token1 utilization, stored in bips
    function utilization1(PositionBalance self) internal pure returns (int256) {
        unchecked {
            return int256((PositionBalance.unwrap(self) >> 144) % 2 ** 16);
        }
    }

    /// @notice Get token0 utilization of `self`.
    /// @param self The PositionBalance to get utilization
    /// @return The token0 utilization, stored in bips
    function utilization0(PositionBalance self) internal pure returns (int256) {
        unchecked {
            return int256((PositionBalance.unwrap(self) >> 128) % 2 ** 16);
        }
    }

    /// @notice Get both token0 and token1 utilizations of `self`.
    /// @param self The PositionBalance to get utilization
    /// @return The token utilizations, stored in bips
    function utilizations(PositionBalance self) internal pure returns (uint32) {
        unchecked {
            return uint32(PositionBalance.unwrap(self) >> 128);
        }
    }

    /// @notice Get the positionSize of `self`.
    /// @param self The PositionBalance to get the size from
    /// @return The positionSize of `self`
    function positionSize(PositionBalance self) internal pure returns (uint128) {
        unchecked {
            return uint128(PositionBalance.unwrap(self));
        }
    }
}
