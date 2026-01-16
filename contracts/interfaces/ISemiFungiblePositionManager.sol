// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Custom types
// Adjust these import paths to match your project structure
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {TokenId} from "@types/TokenId.sol";

interface ISemiFungiblePositionManager {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a position is destroyed/burned.
    event TokenizedPositionBurnt(
        address indexed recipient,
        TokenId indexed tokenId,
        uint128 positionSize
    );

    /// @notice Emitted when a position is created/minted.
    event TokenizedPositionMinted(
        address indexed caller,
        TokenId indexed tokenId,
        uint128 positionSize
    );

    /*//////////////////////////////////////////////////////////////
                         CORE MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new position `tokenId` containing up to 4 legs.
    /// @dev Both V3 and V4 implementations use `bytes poolKey` to abstract the underlying pool.
    /// @param poolKey The ABI-encoded pool key (V3: address, V4: PoolKey)
    /// @param tokenId The tokenId of the minted position, which encodes information for up to 4 legs
    /// @param positionSize The number of contracts minted, expressed in terms of the asset
    /// @param slippageTickLimitLow The lower bound of an acceptable open interval for the ending price
    /// @param slippageTickLimitHigh The upper bound of an acceptable open interval for the ending price
    /// @return collectedByLeg An array of LeftRight encoded words containing the amount of currency0 and currency1 collected as fees for each leg
    /// @return totalMoved The net amount of currency0 and currency1 moved to/from the Uniswap V4 pool
    /// @return finalTick The tick at the end of the mint/burn operation
    function mintTokenizedPosition(
        bytes calldata poolKey,
        TokenId tokenId,
        uint128 positionSize,
        int24 slippageTickLimitLow,
        int24 slippageTickLimitHigh
    )
        external
        returns (
            LeftRightUnsigned[4] memory collectedByLeg,
            LeftRightSigned totalMoved,
            int24 finalTick
        );

    /// @notice Burn a new position containing up to 4 legs wrapped in a ERC1155 token.
    /// @dev Auto-collect all accumulated fees.
    /// @param poolKey The Uniswap V4 pool key in which to burn `tokenId`
    /// @param tokenId The tokenId of the minted position, which encodes information about up to 4 legs
    /// @param positionSize The number of contracts minted, expressed in terms of the asset
    /// @param slippageTickLimitLow The lower bound of an acceptable open interval for the ending price
    /// @param slippageTickLimitHigh The upper bound of an acceptable open interval for the ending price
    /// @return collectedByLeg An array of LeftRight encoded words containing the amount of currency0 and currency1 collected as fees for each leg
    /// @return totalMoved The net amount of currency0 and currency1 moved to/from the Uniswap V4 pool
    /// @return finalTick The tick at the end of the mint/burn operation
    function burnTokenizedPosition(
        bytes calldata poolKey,
        TokenId tokenId,
        uint128 positionSize,
        int24 slippageTickLimitLow,
        int24 slippageTickLimitHigh
    )
        external
        returns (
            LeftRightUnsigned[4] memory collectedByLeg,
            LeftRightSigned totalMoved,
            int24 finalTick
        );

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Return the liquidity associated with a given liquidity chunk/tokenType for a user on a Uniswap pool.
    /// @param poolKey the poolKey of the UniswapV4 pool
    /// @param owner The address of the account that is queried
    /// @param tokenType The tokenType of the position
    /// @param tickLower The lower end of the tick range for the position
    /// @param tickUpper The upper end of the tick range for the position
    /// @return accountLiquidities The amount of liquidity that held in and removed from Uniswap for that chunk (netLiquidity:removedLiquidity -> rightSlot:leftSlot)
    function getAccountLiquidity(
        bytes calldata poolKey,
        address owner,
        uint256 tokenType,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (LeftRightUnsigned accountLiquidities);

    /// @notice Return the premium associated with a given position, where premium is an accumulator of feeGrowth for the touched position.
    /// @dev If an atTick parameter is provided that is different from `type(int24).max`, then it will update the premium up to the current
    /// block at the provided atTick value. We do this because this may be called immediately after the Uniswap V4 pool has been touched,
    /// so no need to read the feeGrowths from the Uniswap V4 pool.
    /// @param poolKey the poolKey of the UniswapV4 pool
    /// @param owner The address of the account that is queried
    /// @param tokenType The tokenType of the position
    /// @param tickLower The lower end of the tick range for the position
    /// @param tickUpper The upper end of the tick range for the position
    /// @param atTick The current tick. Set `atTick < (type(int24).max = 8388608)` to get latest premium up to the current block
    /// @param isLong Whether the position is long (=1) or short (=0)
    /// @param vegoid The vegoid of the position
    /// @return premium0 The amount of premium (per liquidity X64) for currency0 = `sum(feeGrowthLast0X128)` over every block where the position has been touched
    /// @return premium1 The amount of premium (per liquidity X64) for currency1 = `sum(feeGrowthLast0X128)` over every block where the position has been touched
    function getAccountPremium(
        bytes calldata poolKey,
        address owner,
        uint256 tokenType,
        int24 tickLower,
        int24 tickUpper,
        int24 atTick,
        uint256 isLong,
        uint256 vegoid
    ) external view returns (uint128 premium0, uint128 premium1);

    /// @notice Returns the `poolId` for a given Uniswap pool.
    /// @param id The PoolId of the Uniswap V4 Pool
    /// @param vegoid The vegoid of the pool
    /// @return poolId The unique pool identifier corresponding to a idV4
    function getPoolId(bytes memory id, uint8 vegoid) external view returns (uint64 poolId);

    /// @notice Returns the enforced tick limits for a given pool.
    /// @param poolId The poolId to query
    /// @return minTick The minimum enforced tick
    /// @return maxTick The maximum enforced tick
    function getEnforcedTickLimits(
        uint64 poolId
    ) external view returns (int24 minTick, int24 maxTick);

    /// @notice Returns the current tick of a given Uniswap V4 pool
    /// @param poolKey the poolKey of the UniswapV4 pool
    /// @return currentTick The current tick of the Uniswap pool
    function getCurrentTick(bytes memory poolKey) external view returns (int24 currentTick);

    /// @notice Recomputes and decreases `minEnforcedTick` and/or increases `maxEnforcedTick` for a given V4 pool `key` if certain conditions are met.
    /// @dev This function will only have an effect if both conditions are met:
    /// - The token supply for one of the (non-native) tokens was greater than MIN_ENFORCED_TICKFILL_COST at the last `initializeAMMPool` or `expandEnforcedTickRangeForPool` call for `poolId`
    /// - The token supply for one of the tokens meeting the first condition has *decreased* significantly since the last call
    /// @dev This function *cannot* decrease the absolute value of either enforced tick, i.e., it can only widen the range of possible ticks.
    /// @dev The purpose of this function is to prevent pools created while a large amount of one of the tokens was flash-minted from being stuck in a narrow tick range.
    /// @param poolId The poolId on which to expand the enforced tick range
    function expandEnforcedTickRange(uint64 poolId) external;

    /*//////////////////////////////////////////////////////////////
                            ERC1155 SUPPORT
    //////////////////////////////////////////////////////////////*/

    /// @notice All ERC1155 transfers are disabled.
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external;

    /// @notice All ERC1155 transfers are disabled.
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external;
}
