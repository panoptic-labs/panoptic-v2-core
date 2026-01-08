// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Interfaces
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {ISemiFungiblePositionManager} from "@contracts/interfaces/ISemiFungiblePositionManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
// Libraries
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {TokenId} from "@types/TokenId.sol";
import {RiskParameters} from "@types/RiskParameters.sol";
import {EfficientHash} from "@libraries/EfficientHash.sol";

/// @title InteractionHelper - contains helper functions for external interactions such as approvals.
/// @notice Used to delegate logic with multiple external calls.
/// @dev Generally employed when there is a need to save or reuse bytecode size
/// on a core contract.
/// @author Axicon Labs Limited
library InteractionHelper {
    /// @notice Function that performs approvals on behalf of the PanopticPool for CollateralTracker and SemiFungiblePositionManager.
    /// @param sfpm The SemiFungiblePositionManager being approved for both token0 and token1
    /// @param ct0 The CollateralTracker (token0) being approved for token0
    /// @param ct1 The CollateralTracker (token1) being approved for token1
    /// @param token0 The token0 (in Uniswap) being approved for
    /// @param token1 The token1 (in Uniswap) being approved for
    /// @param poolManager The Uniswap V4 pool manager address (zero address if using V3)
    function doApprovals(
        ISemiFungiblePositionManager sfpm,
        CollateralTracker ct0,
        CollateralTracker ct1,
        address token0,
        address token1,
        address poolManager
    ) external {
        if (poolManager == address(0)) {
            // Approve transfers of Panoptic Pool funds by SFPM
            IERC20Partial(token0).approve(address(sfpm), type(uint256).max);
            IERC20Partial(token1).approve(address(sfpm), type(uint256).max);

            // Approve transfers of Panoptic Pool funds by Collateral token
            IERC20Partial(token0).approve(address(ct0), type(uint256).max);
            IERC20Partial(token1).approve(address(ct1), type(uint256).max);
        } else {
            IPoolManager(poolManager).setOperator(address(sfpm), true);
            IPoolManager(poolManager).setOperator(address(ct0), true);
            IPoolManager(poolManager).setOperator(address(ct1), true);
        }
    }

    /// @notice Computes the name of a CollateralTracker based on the token composition and fee of the underlying Uniswap Pool.
    /// @dev Some tokens do not have proper symbols so error handling is required - this logic takes up significant bytecode size, which is why it is in a library.
    /// @param token0 The token0 of the Uniswap Pool
    /// @param token1 The token1 of the Uniswap Pool
    /// @param isToken0 Whether the collateral token computing the name is for token0 or token1
    /// @param fee The fee of the Uniswap pool in hundredths of basis points
    /// @param prefix A constant string appended to the start of the token name
    /// @return The complete name of the collateral token calling this function
    function computeName(
        address token0,
        address token1,
        bool isToken0,
        uint24 fee,
        string memory prefix
    ) external view returns (string memory) {
        string memory symbol0 = PanopticMath.safeERC20Symbol(token0);
        string memory symbol1 = PanopticMath.safeERC20Symbol(token1);

        unchecked {
            return
                string.concat(
                    prefix,
                    " ",
                    isToken0 ? symbol0 : symbol1,
                    " LP on ",
                    symbol0,
                    "/",
                    symbol1,
                    " ",
                    PanopticMath.uniswapFeeToString(fee)
                );
        }
    }

    /// @notice Returns collateral token symbol as `prefix` + `underlying token symbol`.
    /// @param token The address of the underlying token used to compute the symbol
    /// @param prefix A constant string prepended to the symbol of the underlying token to create the final symbol
    /// @return The symbol of the collateral token
    function computeSymbol(
        address token,
        string memory prefix
    ) external view returns (string memory) {
        return string.concat(prefix, PanopticMath.safeERC20Symbol(token));
    }

    /// @notice Returns decimals of underlying token (0 if not present).
    /// @param token The address of the underlying token used to compute the decimals
    /// @return The decimals of the token
    function computeDecimals(address token) external view returns (uint8) {
        // not guaranteed that token supports metadata extension
        // so we need to let call fail and return placeholder if not
        try IERC20Metadata(token).decimals() returns (uint8 _decimals) {
            return _decimals;
        } catch {
            return 0;
        }
    }

    function settleAmounts(
        address liquidatee,
        TokenId[] memory positionIdList,
        LeftRightUnsigned haircutTotal,
        LeftRightSigned[4][] memory haircutPerLeg,
        LeftRightSigned[4][] memory premiasByLeg,
        CollateralTracker ct0,
        CollateralTracker ct1,
        mapping(bytes32 chunkKey => LeftRightUnsigned settledTokens) storage settledTokens
    ) external {
        unchecked {
            for (uint256 i = 0; i < positionIdList.length; i++) {
                TokenId tokenId = positionIdList[i];
                for (uint256 leg = 0; leg < tokenId.countLegs(); ++leg) {
                    if (
                        tokenId.isLong(leg) == 1 &&
                        LeftRightSigned.unwrap(premiasByLeg[i][leg]) != 0
                    ) {
                        bytes32 chunkKey = EfficientHash.efficientKeccak256(
                            abi.encodePacked(
                                tokenId.strike(leg),
                                tokenId.width(leg),
                                tokenId.tokenType(leg)
                            )
                        );

                        emit PanopticPool.PremiumSettled(
                            liquidatee,
                            tokenId,
                            leg,
                            LeftRightSigned.wrap(0).sub(haircutPerLeg[i][leg])
                        );

                        // The long premium is not committed to storage during the liquidation, so we add the entire adjusted amount
                        // for the haircut directly to the accumulator
                        settledTokens[chunkKey] = settledTokens[chunkKey].add(
                            (LeftRightSigned.wrap(0).sub(premiasByLeg[i][leg])).subRect(
                                haircutPerLeg[i][leg]
                            )
                        );
                    }
                }
            }

            if (haircutTotal.rightSlot() != 0)
                ct0.settleBurn(
                    liquidatee,
                    0,
                    0,
                    0,
                    int128(haircutTotal.rightSlot()),
                    RiskParameters.wrap(0)
                );
            if (haircutTotal.leftSlot() != 0)
                ct1.settleBurn(
                    liquidatee,
                    0,
                    0,
                    0,
                    int128(haircutTotal.leftSlot()),
                    RiskParameters.wrap(0)
                );
        }
    }
}
