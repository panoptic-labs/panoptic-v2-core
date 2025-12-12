// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @title Library of Constants used in Panoptic.
/// @author Axicon Labs Limited
/// @notice This library provides constants used in Panoptic.
library Constants {
    /// @notice Fixed point multiplier: 2**96
    uint256 internal constant FP96 = 0x1000000000000000000000000;

    /// @notice Minimum possible price tick in a Uniswap V3 pool
    int24 internal constant MIN_POOL_TICK = -887272;

    /// @notice Maximum possible price tick in a Uniswap V3 pool
    int24 internal constant MAX_POOL_TICK = 887272;

    /// @notice Minimum possible sqrtPriceX96 in a Uniswap V3 pool
    uint160 internal constant MIN_POOL_SQRT_RATIO = 4295128739;

    /// @notice Maximum possible sqrtPriceX96 in a Uniswap V3 pool
    uint160 internal constant MAX_POOL_SQRT_RATIO =
        1461446703485210103287273052203988822378723970342;

    /// @notice The maximum amount of change, in ticks, permitted before TICK_OFFSET is updated.
    int24 internal constant MAX_RESIDUAL_THRESHOLD = 1024;
}
