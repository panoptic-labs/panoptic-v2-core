// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {LeftRightSigned} from "@types/LeftRight.sol";

/// @title Library of Constants used in Panoptic.
/// @author Axicon Labs Limited
/// @notice This library provides constants used in Panoptic.
library Constants {
    /// @notice Fixed point multiplier: 2**96
    uint256 internal constant FP96 = 0x1000000000000000000000000;

    /// @notice Minimum possible price tick in a Uniswap V3 pool
    int24 internal constant MIN_V3POOL_TICK = -887272;

    /// @notice Maximum possible price tick in a Uniswap V3 pool
    int24 internal constant MAX_V3POOL_TICK = 887272;

    /// @notice Minimum possible sqrtPriceX96 in a Uniswap V3 pool
    uint160 internal constant MIN_V3POOL_SQRT_RATIO = 4295128739;

    /// @notice Maximum possible sqrtPriceX96 in a Uniswap V3 pool
    uint160 internal constant MAX_V3POOL_SQRT_RATIO =
        1461446703485210103287273052203988822378723970342;

    /// @notice Maximum amount of assets permitted for a single collateral deposit
    uint256 internal constant MAX_DEPOSIT_ASSETS = type(uint104).max;

    /// @notice LeftRight-packed token0:token1 right:left quantities of virtual assets to delegate during liquidations/force exercises
    /// @dev `LeftRightSigned.wrap(0).toRightSlot(MAX_DEPOSIT_ASSETS * 10_000).toLeftSlot(MAX_DEPOSIT_ASSETS * 10_000)`
    int128 internal constant STANDARD_DELEGATION = MAX_DEPOSIT_ASSETS * 10_000;
}
