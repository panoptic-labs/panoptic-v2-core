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
// (1) positionSize     128bits : The size of this position (uint128).
// (2) poolUtilization0 16bits  : The pool utilization of token0, stored as (10000 * inAMM0)/totalAssets0 (uint16).
// (3) poolUtilization1 16bits  : The pool utilization of token1, stored as (10000 * inAMM1)/totalAssets1 (uint16).
// (4) tickAtMint       24bits  : The tick at mint (int24).
// (5) timestampAtMint 32bits  : The block.timestamp at mint (uint32).
// (6) blockAtMint      40bits  : The block.number at mint (uint40).
// Total                256bits : Total bits used by a PositionBalance.
// ===============================================================================================
//
// The bit pattern is therefore:
//
//           (6)            (5)             (4)             (3)             (2)             (1)
//    <-- 40 bits --> <-- 32 bits --> <-- 24 bits --> <-- 16 bits --> <-- 16 bits --> <-- 128 bits -->
//     blockAtMint     timestampAtMint   tickAtMint     utilization1    utilization0    positionSize
//
//    <--- most significant bit                                                             least significant bit --->
//
library PositionBalanceLibrary {
    /*//////////////////////////////////////////////////////////////
                                ENCODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new `PositionBalance` given by positionSize, utilizations, and its tickData.
    /// @param _positionSize The amount of option minted
    /// @param _utilizations Packed data containing pool utilizations for token0 and token1 at mint
    /// @param _tickAtMint the ticks at the end of the mint
    /// @param _timestampAtMint the timestamp at mint
    /// @param _blockNumberAtMint the block number at mint
    /// @return The new PositionBalance with the given positionSize, utilization, and tick/block data
    function storeBalanceData(
        uint128 _positionSize,
        uint32 _utilizations,
        int24 _tickAtMint,
        uint32 _timestampAtMint,
        uint40 _blockNumberAtMint
    ) internal pure returns (PositionBalance) {
        unchecked {
            return
                PositionBalance.wrap(
                    (uint256(_blockNumberAtMint) << 216) +
                        (uint256(_timestampAtMint) << 184) +
                        (uint256(uint24(_tickAtMint)) << 160) +
                        (uint256(_utilizations) << 128) +
                        uint256(_positionSize)
                );
        }
    }

    /*//////////////////////////////////////////////////////////////
                                DECODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the blockAtMint of `self`.
    /// @param self The PositionBalance to retrieve the blockAtMint from
    /// @return The blockAtMint of `self`
    function blockAtMint(PositionBalance self) internal pure returns (uint40) {
        unchecked {
            return uint40(PositionBalance.unwrap(self) >> 216);
        }
    }

    /// @notice Get the timestamp at mint of `self`.
    /// @param self The PositionBalance to retrieve the timestamp from
    /// @return The timestamp at mint of `self`
    function timestampAtMint(PositionBalance self) internal pure returns (uint32) {
        unchecked {
            return uint32(PositionBalance.unwrap(self) >> 184);
        }
    }

    /// @notice Get the current tick of `self`.
    /// @param self The PositionBalance to retrieve the current tick from
    /// @return The current tick of `self`
    function tickAtMint(PositionBalance self) internal pure returns (int24) {
        unchecked {
            return int24(int256(PositionBalance.unwrap(self) >> 160));
        }
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

    /// @notice Unpack all data from `self`.
    /// @param self The PositionBalance to get all data from
    /// @return _blockAtMint `block.number` at mint
    /// @return _timestampAtMint `block.timestamp` at mint
    /// @return _tickAtMint `currentTick` at mint
    /// @return utilization0AtMint Utilization of token0 at mint
    /// @return utilization1AtMint Utilization of token1 at mint
    /// @return _positionSize Size of the position
    function unpackAll(
        PositionBalance self
    )
        external
        pure
        returns (
            uint40 _blockAtMint,
            uint32 _timestampAtMint,
            int24 _tickAtMint,
            int256 utilization0AtMint,
            int256 utilization1AtMint,
            uint128 _positionSize
        )
    {
        _blockAtMint = self.blockAtMint();
        _timestampAtMint = self.timestampAtMint();

        _tickAtMint = self.tickAtMint();

        utilization0AtMint = self.utilization0();
        utilization1AtMint = self.utilization1();

        _positionSize = self.positionSize();
    }
}
