// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.24;

type PositionBalance is uint256;
using PositionBalanceLibrary for PositionBalance global;

/// @title A Panoptic Position Balance. Tracks the Position Size, the Pool Utilizations at mint, and the current/fastOracle/slowOracle/latestObserved ticks at mint.
/// @author Axicon Labs Limited
//
//
// PACKING RULES FOR A POSITIONBALANCE:
// =================================================================================================
//  From the LSB to the MSB:
// (1) positionSize     128bits : the size of that position  (uint128).
// (2) poolUtilization0 16bits  : the pool utilization of token0, stored as (10000 * inAMM0)/totalAssets0 (uint16)
// (3) poolUtilization1 16bits  : the pool utilization of token1, stored as (10000 * inAMM1)/totalAssets1 (uint16)
// (4) currentTick      24bits  : The currentTick at mint (int24).
// (5) fastOracleTick   24bits  : The fastOracleTick at mint (int24).
// (6) slowOracleTick   24bits  : The slowOracleTick at mint (int24).
// (7) lastObservedTick 24bits  : The lastObservedTick at mint (int24).
// Total                256bits : Total bits used by a PositionBalance.
// ===============================================================================================
//
// The bit pattern is therefore:
//
//           (7)             (6)            (5)             (4)             (3)             (2)             (1)
//    <-- 24 bits --> <-- 24 bits --> <-- 24 bits --> <-- 24 bits --> <-- 16 bits --> <-- 16 bits --> <-- 128 bits -->
//  lastObservedTick   slowOracleTick  fastOracleTick   currentTick    utilization0     utilization1    positionSize
//
//    <--- most significant bit                                                             least significant bit --->
//
library PositionBalanceLibrary {
    /*//////////////////////////////////////////////////////////////
                                ENCODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new `PositionBalance` given by positionSize, utilizations, and its tickData.
    /// @param positionSize The amount of option minted
    /// @param utilizations Packing of two uint16 utilizations into a 32 bit word
    /// @param tickData Packing of 4 int25s into a single uint96
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

    /// @notice Concatenate all oracle ticks into a single uint96.
    /// @param currentTick The current tick
    /// @param fastOracleTick The fast Oracle tick
    /// @param slowOracleTick The slow Oracle tick
    /// @param lastObservedTick The last observed tick
    /// @return A 96bit word concatenating all 4 input ticks
    function packTickData(
        int24 currentTick,
        int24 fastOracleTick,
        int24 slowOracleTick,
        int24 lastObservedTick
    ) internal pure returns (uint96) {
        unchecked {
            return
                uint96(uint24(currentTick)) +
                (uint96(uint24(fastOracleTick)) << 24) +
                (uint96(uint24(slowOracleTick)) << 48) +
                (uint96(uint24(lastObservedTick)) << 72);
        }
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

    /// @notice Get the tickData of `self`.
    /// @param self The PositionBalance to get the ticks
    /// @return The packed tickData
    function tickData(PositionBalance self) internal pure returns (uint96) {
        unchecked {
            return uint96(PositionBalance.unwrap(self) >> 160);
        }
    }

    /// @notice Get the unpacked tickData of uint96 tickData.
    /// @param tickData The packed tickData to get ticks from
    function unpackTickData(
        uint96 tickData
    )
        internal
        pure
        returns (
            int24 currentTick,
            int24 fastOracleTick,
            int24 slowOracleTick,
            int24 lastObservedTick
        )
    {
        PositionBalance self = PositionBalance.wrap(uint256(tickData) << 160);

        currentTick = self.currentTick();
        fastOracleTick = self.fastOracleTick();
        slowOracleTick = self.slowOracleTick();
        lastObservedTick = self.lastObservedTick();
    }

    /// @notice Get the unpacked tickData of `self`.
    /// @param self The PositionBalance to get ticks from
    function unpackTickData(
        PositionBalance self
    )
        internal
        pure
        returns (
            int24 currentTick,
            int24 fastOracleTick,
            int24 slowOracleTick,
            int24 lastObservedTick
        )
    {
        currentTick = self.currentTick();
        fastOracleTick = self.fastOracleTick();
        slowOracleTick = self.slowOracleTick();
        lastObservedTick = self.lastObservedTick();
    }

    /// @notice Get token0 utilization of `self`.
    /// @param self The PositionBalance to get utilization
    /// @return The token0 utilization, stored in bips
    function utilization0(PositionBalance self) internal pure returns (int256) {
        unchecked {
            return int256((PositionBalance.unwrap(self) >> 128) % 2 ** 16);
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

    /// @notice Unpack all data from `self`.
    /// @param self The PositionBalance to get all data from
    /// @return currentTickAtMint currentTick at mint
    /// @return fastOracleTickAtMint fast oracle tick at mint
    /// @return slowOracleTickAtMint slow oracle tick at mint
    /// @return lastObservedTickAtMint last observed tick at mint
    /// @return utilization0AtMint utilization of token0 at mint
    /// @return utilization1AtMint utilization of token1 at mint
    /// @return positionSize size of the position
    function unpackAll(
        PositionBalance self
    )
        external
        pure
        returns (
            int24 currentTickAtMint,
            int24 fastOracleTickAtMint,
            int24 slowOracleTickAtMint,
            int24 lastObservedTickAtMint,
            int256 utilization0AtMint,
            int256 utilization1AtMint,
            uint128 positionSize
        )
    {
        (
            currentTickAtMint,
            fastOracleTickAtMint,
            slowOracleTickAtMint,
            lastObservedTickAtMint
        ) = self.unpackTickData();

        utilization0AtMint = self.utilization0();
        utilization1AtMint = self.utilization1();

        positionSize = self.positionSize();
    }
}
