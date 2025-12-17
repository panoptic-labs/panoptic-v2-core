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
    /// @param tokenId The tokenId of the minted position
    /// @param positionSize The number of contracts minted
    /// @param slippageTickLimitLow Lower price bound
    /// @param slippageTickLimitHigh Upper price bound
    /// @return collectedByLeg Fees collected per leg
    /// @return totalMoved Net amount moved to/from AMM
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

    /// @notice Burn an existing position containing up to 4 legs.
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

    // NOTE: To strictly adhere to this interface, your V4 contract needs
    // to add overloads that accept `bytes calldata poolKey`.

    function getAccountLiquidity(
        bytes calldata poolKey,
        address owner,
        uint256 tokenType,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (LeftRightUnsigned accountLiquidities);

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

    function getPoolId(bytes memory id, uint8 vegoid) external view returns (uint64 poolId);

    function getEnforcedTickLimits(uint64 poolId) external view returns (int24, int24);

    function getCurrentTick(bytes memory poolKey) external view returns (int24 currentTick);

    function expandEnforcedTickRange(uint64 poolId) external;

    /*//////////////////////////////////////////////////////////////
                            ERC1155 SUPPORT
    //////////////////////////////////////////////////////////////*/

    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external;

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external;
}
