// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

// Interfaces
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {INonfungiblePositionManager} from "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
/// Libraries
import {PeripheryErrors} from "@periphery/PeripheryErrors.sol";

/// @title Facilitates the migration from Uniswap LPing to PLPing.
/// @author Axicon Labs Limited
contract UniswapMigrator {
    /// @notice Canonical NonFungiblePositionManager deployment
    INonfungiblePositionManager immutable NFPM;

    /// @notice Set canonical deployment of NonFungiblePositionManager.
    /// @param _NFPM Address of canonical NonFungiblePositionManager
    constructor(INonfungiblePositionManager _NFPM) {
        NFPM = _NFPM;
    }

    /// @notice Removes all liquidity from `tokenIds` in the NFPM and deposits into collateral vaults.
    /// @dev All positions in `tokenIds` SHOULD be on the same pool.
    /// @dev All positions in `tokenIds` MUST have the same token0/token1.
    /// @dev `amountMins` MUST be the same length as `tokenIds`.
    /// @param tokenIds List of NFPM token ids to remove liquidity from
    /// @param amountMins An array of [amount0Min, amount1Min] for each tokenId
    /// @param ct0 Desired collateral vault to deposit token0 into
    /// @param ct1 Desired collateral vault to deposit token1 into
    function migrate(
        uint256[] calldata tokenIds,
        uint256[2][] calldata amountMins,
        CollateralTracker ct0,
        CollateralTracker ct1
    ) external {
        uint256 amount0Collected;
        uint256 amount1Collected;

        for (uint256 i; i < tokenIds.length; ++i) {
            if (NFPM.ownerOf(tokenIds[i]) != msg.sender)
                revert PeripheryErrors.UnauthorizedMigration();

            (, , , , , , , uint128 liquidity, , , , ) = NFPM.positions(tokenIds[i]);

            NFPM.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenIds[i],
                    liquidity: liquidity,
                    amount0Min: amountMins[i][0],
                    amount1Min: amountMins[i][1],
                    deadline: type(uint32).max
                })
            );

            (uint256 amount0CollectedFromPosition, uint256 amount1CollectedFromPosition) = NFPM
                .collect(
                    INonfungiblePositionManager.CollectParams({
                        tokenId: tokenIds[i],
                        recipient: address(this),
                        amount0Max: type(uint128).max,
                        amount1Max: type(uint128).max
                    })
                );

            unchecked {
                amount0Collected += amount0CollectedFromPosition;
                amount1Collected += amount1CollectedFromPosition;
            }
        }

        if (amount0Collected > 0) {
            IERC20Partial(ct0.asset()).approve(address(ct0), amount0Collected);
            ct0.deposit(amount0Collected, msg.sender);
        }

        if (amount1Collected > 0) {
            IERC20Partial(ct1.asset()).approve(address(ct1), amount1Collected);
            ct1.deposit(amount1Collected, msg.sender);
        }
    }
}
