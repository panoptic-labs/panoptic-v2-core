// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

type PoolData is uint256;
using PoolDataLibrary for PoolData global;

/// @title A Panoptic Pool Data. Tracks the Uniswap Pool, the minEnforcedTick, and the maxEnforcedTick
/// @author Axicon Labs Limited
//
//
// PACKING RULES FOR A POOLDATA:
// =================================================================================================
//  From the LSB to the MSB:
// (1) maxLiquidityPerTick  128bits : The max liquidity per tick
// (2) poolId               64bits  : The poolId
// (3) minEnforcedTick      24bits  : The current minimum enforced tick for the pool in the SFPM (int24).
// (4) maxEnforcedTick      24bits  : The current maximum enforced tick for the pool in the SFPM (int24).
// (5) initialized          1bit    : Whether the pool has been initialized
// Total                    241bits : Total bits used by a PoolData.
// ===============================================================================================
//
// The bit pattern is therefore:
//
//        (5)             (4)                   (3)             (2)                    (1)
//    <-- 1 bit --><---- 24 bits ----> <---- 24 bits ----> <---- 64 bits ----> <---- 128 bits ---->
//     initialized    maxEnforcedTick    minEnforcedTick         poolId           maxLiquidityPerTick
//
//    <--- most significant bit                                            least significant bit --->
//
library PoolDataLibrary {
    /*//////////////////////////////////////////////////////////////
                                ENCODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new `PoolData` given by UniswapV3Pool, min/maxEnforcedTick.
    /// @param _maxLiquidityPerTick The max liquidity per tick
    /// @param _poolId The poolId of the Uniswap pool
    /// @param _minEnforcedTick The current minimum enforced tick for the pool in the SFPM
    /// @param _maxEnforcedTick The current maximum enforced tick for the pool in the SFPM
    /// @return The new PoolData with the given IUniswapV3Pool and min/maxEnforcedTick
    function storePoolData(
        uint128 _maxLiquidityPerTick,
        uint64 _poolId,
        int24 _minEnforcedTick,
        int24 _maxEnforcedTick,
        bool _initialized
    ) internal pure returns (PoolData) {
        unchecked {
            return
                PoolData.wrap(
                    _maxLiquidityPerTick +
                        (uint256(_poolId) << 128) +
                        (uint256(uint24(_minEnforcedTick)) << 192) +
                        (uint256(uint24(_maxEnforcedTick)) << 216) +
                        (uint256(_initialized ? 1 : 0) << 240)
                );
        }
    }

    /*//////////////////////////////////////////////////////////////
                                DECODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the maxLiquidityPerTick of `self`.
    /// @param self The PoolData to retrieve the max liquidity from
    /// @return The maxLiquidityPerTick of `self`
    function maxLiquidityPerTick(PoolData self) internal pure returns (uint128) {
        unchecked {
            return uint128(PoolData.unwrap(self));
        }
    }

    /// @notice Get the poolId of `self`.
    /// @param self The PoolData to retrieve the poolId from
    /// @return The poolId of `self`
    function poolId(PoolData self) internal pure returns (uint64) {
        unchecked {
            return uint64(PoolData.unwrap(self) >> 128);
        }
    }

    /// @notice Get the min enforced tick of `self`.
    /// @param self The PoolData to retrieve the min enforced tick from
    /// @return The min enforced tick of `self`
    function minEnforcedTick(PoolData self) internal pure returns (int24) {
        unchecked {
            return int24(uint24(PoolData.unwrap(self) >> 192));
        }
    }

    /// @notice Get the max enforced tick of `self`.
    /// @param self The PoolData to retrieve the max enforced tick from
    /// @return The max enforced tick of `self`
    function maxEnforcedTick(PoolData self) internal pure returns (int24) {
        unchecked {
            return int24(uint24(PoolData.unwrap(self) >> 216));
        }
    }

    /// @notice Get the initialized bool of `self`.
    /// @param self The PoolData to retrieve initialized flag from
    /// @return The initialized flag of `self`
    function initialized(PoolData self) internal pure returns (bool) {
        unchecked {
            return ((PoolData.unwrap(self) >> 240) % 2) > 0;
        }
    }
}
