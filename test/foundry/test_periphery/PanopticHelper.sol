// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
// Interfaces
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {ISemiFungiblePositionManager} from "@contracts/interfaces/ISemiFungiblePositionManager.sol";
// Libraries
import {Constants} from "@libraries/Constants.sol";
import {Math} from "@libraries/Math.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
// Custom types
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {TokenId, TokenIdLibrary} from "@types/TokenId.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";

/// @title Utility contract for token ID construction and advanced queries.
/// @author Axicon Labs Limited
contract PanopticHelper {
    ISemiFungiblePositionManager internal immutable SFPM;

    struct Leg {
        uint64 poolId;
        address UniswapV3Pool;
        uint256 asset;
        uint256 optionRatio;
        uint256 tokenType;
        uint256 isLong;
        uint256 riskPartner;
        int24 strike;
        int24 width;
    }

    /// @notice Construct the PanopticHelper contract
    /// @param _SFPM address of the SemiFungiblePositionManager
    /// @dev the SFPM is used to get the pool ID for a given address
    constructor(ISemiFungiblePositionManager _SFPM) payable {
        SFPM = _SFPM;
    }

    /// @notice Compute the total amount of collateral needed to cover the existing list of active positions in positionIdList.
    /// @param pool The PanopticPool instance to check collateral on
    /// @param account Address of the user that owns the positions
    /// @param atTick At what price is the collateral requirement evaluated at
    /// @param positionIdList List of positions. Written as [tokenId1, tokenId2, ...]
    /// @return collateralBalance the total combined balance of token0 and token1 for a user in terms of tokenType
    /// @return requiredCollateral The combined collateral requirement for a user in terms of tokenType
    function checkCollateral(
        PanopticPool pool,
        address account,
        int24 atTick,
        TokenId[] calldata positionIdList
    ) public view returns (uint256, uint256) {
        // Compute premia for all options (includes short+long premium)
        (
            LeftRightUnsigned shortPremium,
            LeftRightUnsigned longPremium,
            PositionBalance[] memory positionBalanceArray
        ) = pool.getAccumulatedFeesAndPositionsData(account, false, positionIdList);

        PanopticPool _pool = pool;
        // Query the current and required collateral amounts for the two tokens
        (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = pool
            .riskEngine()
            .getMargin(
                positionBalanceArray,
                atTick,
                account,
                positionIdList,
                shortPremium,
                longPremium,
                _pool.collateralToken0(),
                _pool.collateralToken1()
            );

        // convert (using atTick) and return the total collateral balance and required balance in terms of tokenType
        return
            PanopticMath.getCrossBalances(tokenData0, tokenData1, Math.getSqrtRatioAtTick(atTick));
    }

    /// @notice Calculate NAV of user's option portfolio at a given tick.
    /// @param pool The PanopticPool instance to check collateral on
    /// @param account Address of the user that owns the positions
    /// @param atTick The tick to calculate the value at
    /// @param positionIdList A list of all positions the user holds on that pool
    /// @return value0 The amount of token0 owned by portfolio
    /// @return value1 The amount of token1 owned by portfolio
    function getPortfolioValue(
        PanopticPool pool,
        address account,
        int24 atTick,
        TokenId[] calldata positionIdList
    ) external view returns (int256 value0, int256 value1) {
        // Compute premia for all options (includes short+long premium)
        (, , PositionBalance[] memory positionBalanceArray) = pool
            .getAccumulatedFeesAndPositionsData(account, false, positionIdList);

        for (uint256 k = 0; k < positionIdList.length; ) {
            TokenId tokenId = positionIdList[k];
            uint128 positionSize = positionBalanceArray[k].positionSize();
            uint256 numLegs = tokenId.countLegs();
            for (uint256 leg = 0; leg < numLegs; ) {
                LiquidityChunk liquidityChunk = PanopticMath.getLiquidityChunk(
                    tokenId,
                    leg,
                    positionSize
                );

                (uint256 amount0, uint256 amount1) = Math.getAmountsForLiquidity(
                    atTick,
                    liquidityChunk
                );

                if (tokenId.isLong(leg) == 0) {
                    unchecked {
                        value0 += int256(amount0);
                        value1 += int256(amount1);
                    }
                } else {
                    unchecked {
                        value0 -= int256(amount0);
                        value1 -= int256(amount1);
                    }
                }

                unchecked {
                    ++leg;
                }
            }
            unchecked {
                ++k;
            }
        }
    }

    /// @notice Returns the total number of contracts owned by `account` and the pool utilization at mint for a specified `tokenId.
    /// @param pool The PanopticPool instance corresponding to the pool specified in `TokenId`
    /// @param account The address of the account on which to retrieve `balance` and `poolUtilization`
    /// @return balance Number of contracts of `tokenId` owned by the user
    /// @return poolUtilization0 The utilization of token0 in the Panoptic pool at mint
    /// @return poolUtilization1 The utilization of token1 in the Panoptic pool at mint
    function optionPositionInfo(
        PanopticPool pool,
        address account,
        TokenId tokenId
    ) external view returns (uint128, uint16, uint16) {
        TokenId[] memory tokenIdList = new TokenId[](1);
        tokenIdList[0] = tokenId;

        (, , PositionBalance[] memory positionBalanceArray) = pool
            .getAccumulatedFeesAndPositionsData(account, false, tokenIdList);

        PositionBalance balanceAndUtilization = positionBalanceArray[0];

        return (
            balanceAndUtilization.positionSize(),
            uint16(balanceAndUtilization.utilizations()),
            uint16(balanceAndUtilization.utilizations() >> 16)
        );
    }

    /*//////////////////////////////////////////////////////////////
                          ORACLE CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the median of the last `cardinality` average prices over `period` observations from `univ3pool`.
    /// @dev Used when we need a manipulation-resistant TWAP price.
    /// @dev Uniswap observations snapshot the closing price of the last block before the first interaction of a given block.
    /// @dev The maximum frequency of observations is 1 per block, but there is no guarantee that the pool will be observed at every block.
    /// @dev Each period has a minimum length of blocktime * period, but may be longer if the Uniswap pool is relatively inactive.
    /// @dev The final price used in the array (of length `cardinality`) is the average of all observations comprising `period` (which is itself a number of observations).
    /// @dev Thus, the minimum total time window is `cardinality` * `period` * `blocktime`.
    /// @param univ3pool The Uniswap pool to get the median observation from
    /// @param cardinality The number of `periods` to in the median price array, should be odd.
    /// @param period The number of observations to average to compute one entry in the median price array
    /// @return The median of `cardinality` observations spaced by `period` in the Uniswap pool
    function computeMedianObservedPrice(
        IUniswapV3Pool univ3pool,
        uint256 cardinality,
        uint256 period
    ) external view returns (int24) {
        (, , uint16 observationIndex, uint16 observationCardinality, , , ) = univ3pool.slot0();

        (int24 medianTick, ) = PanopticMath.computeMedianObservedPrice(
            univ3pool,
            observationIndex,
            observationCardinality,
            cardinality,
            period
        );
        return medianTick;
    }

    /// @notice Takes a packed structure representing a sorted 8-slot queue of ticks and returns the median of those values.
    /// @dev Also inserts the latest Uniswap observation into the buffer, resorts, and returns if the last entry is at least `period` seconds old.
    /// @param oraclePack The packed structure representing the sorted 8-slot queue of ticks
    /// @param univ3pool The Uniswap pool to retrieve observations from
    /// @return The median of the provided 8-slot queue of ticks in `oraclePack`
    /// @return The updated 8-slot queue of ticks with the latest observation inserted if the last entry is at least `period` seconds old (returns 0 otherwise)
    /*
    function computeInternalMedian(
        uint256 oraclePack,
        IUniswapV3Pool univ3pool
    ) external view returns (int24, uint256) {
        (
            ,
            int24 currentTick,
            uint16 observationIndex,
            uint16 observationCardinality,
            ,
            ,

        ) = univ3pool.slot0();

        (int24 _medianTick, uint256 _oraclePack) = PanopticMath.computeInternalMedian(
            oraclePack,
            currentTick,
            0
        );
        return (_medianTick, _oraclePack);
    }
    */

    /// @notice Computes the twap of a Uniswap V3 pool using data from its oracle.
    /// @dev Note that our definition of TWAP differs from a typical mean of prices over a time window.
    /// @dev We instead observe the average price over a series of time intervals, and define the TWAP as the median of those averages.
    /// @param univ3pool The Uniswap pool from which to compute the TWAP.
    /// @param twapWindow The time window to compute the TWAP over.
    /// @return The final calculated TWAP tick.
    function twapFilter(IUniswapV3Pool univ3pool, uint32 twapWindow) external view returns (int24) {
        return PanopticMath.twapFilter(univ3pool, twapWindow);
    }

    /// @notice Returns the net assets (balance - maintenance margin) of a given account on a given pool.
    /// @dev does not work for very large tick gradients.
    /// @param pool address of the pool
    /// @param account address of the account
    /// @param tick tick to consider
    /// @param positionIdList list of position IDs to consider
    /// @return netEquity the net assets of `account` on `pool`
    function netEquity(
        address pool,
        address account,
        int24 tick,
        TokenId[] calldata positionIdList
    ) internal view returns (int256) {
        (uint256 balanceCross, uint256 requiredCross) = checkCollateral(
            PanopticPool(pool),
            account,
            tick,
            positionIdList
        );

        // convert to token0 to ensure consistent units
        if (tick > 0) {
            balanceCross = PanopticMath.convert1to0(balanceCross, Math.getSqrtRatioAtTick(tick));
            requiredCross = PanopticMath.convert1to0(requiredCross, Math.getSqrtRatioAtTick(tick));
        }

        return int256(balanceCross) - int256(requiredCross);
    }

    /// @notice Returns an estimate of the downside liquidation price for a given account on a given pool.
    /// @dev returns MIN_TICK if the LP is more than 100000 ticks below the current tick.
    /// @param pool address of the pool
    /// @param account address of the account
    /// @param positionIdList list of position IDs to consider
    /// @return liquidationTick the downward liquidation price of `account` on `pool`, if any
    function findLiquidationPriceDown(
        address pool,
        address account,
        TokenId[] calldata positionIdList
    ) public view returns (int24 liquidationTick) {
        // initialize right and left bounds from current tick
        int24 currentTick = SFPM.getCurrentTick(PanopticPool(pool).poolKey());

        int24 x0 = currentTick - 10000;
        int24 x1 = currentTick;
        int24 tol = 100000;
        // use the secant method to find the root of the function netEquity(tick)
        // stopping criterion are netEquity(tick+1) > 0 and netEquity(tick-1) < 0
        // and tick is below currentTick - tol
        // (we have limited ability to calculate collateral for very large tick gradients)
        // in that case, we return the min tick
        while (true) {
            // perform an iteration of the secant method
            (x0, x1) = (
                x1,
                int24(
                    x1 -
                        (int256(netEquity(pool, account, x1, positionIdList)) * (x1 - x0)) /
                        int256(
                            netEquity(pool, account, x1, positionIdList) -
                                netEquity(pool, account, x0, positionIdList)
                        )
                )
            );
            // if price is not within a 100000 tick range of current price, return MIN_TICK
            if (x1 > currentTick + tol || x1 < currentTick - tol) {
                return Constants.MIN_POOL_TICK;
            }
            // stop if price is within 0.01% (1 tick) of LP
            if (
                netEquity(pool, account, x1 + 1, positionIdList) >= 0 ==
                netEquity(pool, account, x1 - 1, positionIdList) <= 0
            ) {
                return x1;
            }
        }
    }

    /// @notice Returns an estimate of the upside liquidation price for a given account on a given pool.
    /// @dev returns MAX_TICK if the LP is more than 100000 ticks above current tick.
    /// @param pool address of the pool
    /// @param account address of the account
    /// @param positionIdList list of position IDs to consider
    /// @return liquidationTick the upward liquidation price of `account` on `pool`, if any
    function findLiquidationPriceUp(
        address pool,
        address account,
        TokenId[] calldata positionIdList
    ) public view returns (int24 liquidationTick) {
        // initialize right and left bounds from current tick
        int24 currentTick = SFPM.getCurrentTick(PanopticPool(pool).poolKey());
        int24 x0 = currentTick;
        int24 x1 = currentTick + 10000;
        int24 tol = 100000;
        // use the secant method to find the root of the function netEquity(tick)
        // stopping criterion are netEquity(tick+1) > 0 and netEquity(tick-1) < 0
        // and tick is within the range of currentTick +- tol
        // (we have limited ability to calculate collateral for very large tick gradients)
        // in that case, we return the corresponding max/min tick
        while (true) {
            // perform an iteration of the secant method
            (x0, x1) = (
                x1,
                int24(
                    x1 -
                        (int256(netEquity(pool, account, x1, positionIdList)) * (x1 - x0)) /
                        int256(
                            netEquity(pool, account, x1, positionIdList) -
                                netEquity(pool, account, x0, positionIdList)
                        )
                )
            );
            // if price is not within a 100000 tick range of current price, stop + return MAX_TICK
            if (x1 > currentTick + tol || x1 < currentTick - tol) {
                return Constants.MAX_POOL_TICK;
            }
            // stop if price is within 0.01% (1 tick) of LP
            if (
                netEquity(pool, account, x1 + 1, positionIdList) >= 0 ==
                netEquity(pool, account, x1 - 1, positionIdList) <= 0
            ) {
                return x1;
            }
        }
    }

    /// @notice initializes a given leg in a tokenId as a call.
    /// @param tokenId tokenId to edit
    /// @param legIndex index of the leg to edit
    /// @param optionRatio relative size of the leg
    /// @param asset asset of the leg
    /// @param isLong whether the leg is long or short
    /// @param riskPartner defined risk partner of the leg
    /// @param strike strike of the leg
    /// @param width width of the leg
    /// @return tokenId with the leg initialized
    function addCallLeg(
        TokenId tokenId,
        uint256 legIndex,
        uint256 optionRatio,
        uint256 asset,
        uint256 isLong,
        uint256 riskPartner,
        int24 strike,
        int24 width
    ) internal pure returns (TokenId) {
        return
            TokenIdLibrary.addLeg(
                tokenId,
                legIndex,
                optionRatio,
                asset,
                isLong,
                0,
                riskPartner,
                strike,
                width
            );
    }

    /// @notice initializes a given leg in a tokenId as a put.
    /// @param tokenId tokenId to edit
    /// @param legIndex index of the leg to edit
    /// @param optionRatio relative size of the leg
    /// @param asset asset of the leg
    /// @param isLong whether the leg is long or short
    /// @param riskPartner defined risk partner of the leg
    /// @param strike strike of the leg
    /// @param width width of the leg
    /// @return tokenId with the leg initialized
    function addPutLeg(
        TokenId tokenId,
        uint256 legIndex,
        uint256 optionRatio,
        uint256 asset,
        uint256 isLong,
        uint256 riskPartner,
        int24 strike,
        int24 width
    ) internal pure returns (TokenId) {
        return
            TokenIdLibrary.addLeg(
                tokenId,
                legIndex,
                optionRatio,
                asset,
                isLong,
                1,
                riskPartner,
                strike,
                width
            );
    }
}
