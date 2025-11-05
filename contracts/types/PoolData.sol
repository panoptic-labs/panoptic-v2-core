// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";

type PoolData is uint256;
using PoolDataLibrary for PoolData global;

/// @title A Panoptic Pool Data. Tracks the Uniswap Pool, the minEnforcedTick, and the maxEnforcedTick
/// @author Axicon Labs Limited
//
//
// PACKING RULES FOR A POSITIONBALANCE:
// =================================================================================================
//  From the LSB to the MSB:
// (1) IUniswapV3Pool   160bits : The Uniswap Pool
// (2) minEnforcedTick  24bits  : The current minimum enforced tick for the pool in the SFPM (int24).
// (3) fastOracleTick   24bits  : The current maximum enforced tick for the pool in the SFPM (int24).
// Total                208bits : Total bits used by a PoolData.
// ===============================================================================================
//
// The bit pattern is therefore:
//
//           (3)             (2)            (1)
//    <---- 24 bits ----> <---- 24 bits ----> <---- 160 bits ---->
//   maxEnforcedTick       minEnforcedTick         IUniswapV3Pool
//
//    <--- most significant bit              least significant bit --->
//
library PoolDataLibrary {
    /*//////////////////////////////////////////////////////////////
                                ENCODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new `PoolData` given by UniswapV3Pool, min/maxEnforcedTick.
    /// @param _uniswapV3Pool The Uniswap v3 pool interface
    /// @param _minEnforcedTick The current minimum enforced tick for the pool in the SFPM
    /// @param _maxEnforcedTick The current maximum enforced tick for the pool in the SFPM
    /// @return The new PoolData with the given IUniswapV3Pool and min/maxEnforcedTick
    function storePoolData(
        IUniswapV3Pool _uniswapV3Pool,
        int24 _minEnforcedTick,
        int24 _maxEnforcedTick
    ) internal pure returns (PoolData) {
        unchecked {
            return
                PoolData.wrap(
                    uint160(address(_uniswapV3Pool)) +
                        (uint256(uint24(_minEnforcedTick)) << 160) +
                        (uint256(uint24(_maxEnforcedTick)) << 184)
                );
        }
    }

    /*//////////////////////////////////////////////////////////////
                                DECODING
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the Uniswap pool of `self`.
    /// @param self The PooolData to retrieve the UniswapV3Pool from
    /// @return The UniswapV3Pool of `self`
    function pool(PoolData self) internal pure returns (IUniswapV3Pool) {
        unchecked {
            return IUniswapV3Pool(address(uint160(PoolData.unwrap(self))));
        }
    }

    /// @notice Get the min enforced tick of `self`.
    /// @param self The PoolData to retrieve the min enforced tick from
    /// @return The min enforced tick of `self`
    function minEnforcedTick(PoolData self) internal pure returns (int24) {
        unchecked {
            return int24(uint24(PoolData.unwrap(self) >> 160));
        }
    }

    /// @notice Get the max enforced tick of `self`.
    /// @param self The PoolData to retrieve the max enforced tick from
    /// @return The max enforced tick of `self`
    function maxEnforcedTick(PoolData self) internal pure returns (int24) {
        unchecked {
            return int24(uint24(PoolData.unwrap(self) >> 184));
        }
    }
}
