// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Interfaces
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
// Libraries
import {Constants} from "@libraries/Constants.sol";
import {Errors} from "@libraries/Errors.sol";
import {Math} from "@libraries/Math.sol";
// Custom types
import {LeftRight} from "@types/LeftRight.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {TokenId} from "@types/TokenId.sol";
import "forge-std/Test.sol";

/// @title Compute general math quantities relevant to Panoptic and AMM pool management.
/// @author Axicon Labs Limited
library PanopticMath {
    // enables packing of types within int128|int128 or uint128|uint128 containers.
    using LeftRight for int256;
    using LeftRight for uint256;
    // represents a single liquidity chunk in Uniswap. Contains tickLower, tickUpper, and amount of liquidity
    using LiquidityChunk for uint256;
    // represents an option position of up to four legs as a sinlge ERC1155 tokenId
    using TokenId for uint256;

    /*//////////////////////////////////////////////////////////////
                              MATH HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Given an address to a Uniswap v3 pool, return its 64-bit ID as used in the `TokenId` of Panoptic.
    /// @dev Example:
    ///      the 64 bits are the 64 *last* (most significant) bits - and thus corresponds to the *first* 16 hex characters (reading left to right)
    ///      of the Uniswap v3 pool address, e.g.:
    ///        univ3pool = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8
    ///      the returned id is then:
    ///        0x8ad599c3A0ff1De0
    ///      which as a uint64 is:
    ///        10004071212772171232.
    ///
    /// @param univ3pool the Uniswap v3 pool to get the ID of
    /// @return a uint64 representing a fingerprint of the uniswap v3 pool address
    function getPoolId(address univ3pool) internal pure returns (uint64) {
        return uint64(uint160(univ3pool) >> 96);
    }

    /// @notice Returns the resultant pool ID for the given 64-bit base pool ID and parameters.
    /// @param basePoolId the 64-bit base pool ID
    /// @param token0 the address of the first token in the pool
    /// @param token1 the address of the second token in the pool
    /// @param fee the fee of the pool in hundredths of a bi
    /// @return finalPoolId the final 64-bit pool id as encoded in the `TokenId` type - composed of the last 64 bits of the address and a hash of the parameters
    function getFinalPoolId(
        uint64 basePoolId,
        address token0,
        address token1,
        uint24 fee
    ) internal pure returns (uint64) {
        unchecked {
            return
                basePoolId +
                (uint64(uint256(keccak256(abi.encodePacked(token0, token1, fee)))) >> 32);
        }
    }

    /// @notice Get the number of leading hex characters in an address.
    ///     0x0000bababaab...     0xababababab...
    ///          ▲                 ▲
    ///          │                 │
    ///     4 leading hex      0 leading hex
    ///    character zeros    character zeros
    ///
    /// @param addr the address to get the number of leading zero hex characters for
    /// @return the number of leading zero hex characters in the address
    function numberOfLeadingHexZeros(address addr) external pure returns (uint256) {
        unchecked {
            return addr == address(0) ? 40 : 39 - Math.mostSignificantNibble(uint160(addr));
        }
    }

    /// @notice Update an existing accounts "positions hash" with a new single position `tokenId`.
    /// @notice The positions hash contains a single fingerprint of all positions created by an account/user as well as a tally of the positions.
    /// @dev the combined hash is the XOR of all individual position hashes.
    /// @param existingHash the existing position hash containing all historical N positions created and the count of the positions
    /// @param tokenId the new position to add to the existing hash: existingHash = uint248(existingHash) ^ hashOf(tokenId)
    /// @param addFlag whether to mint (add) the tokenId to the count of positions or burn (subtract) it from the count (existingHash >> 248) +/- 1
    /// @return newHash the new positionHash with the updated hash
    function updatePositionsHash(
        uint256 existingHash,
        uint256 tokenId,
        bool addFlag
    ) internal pure returns (uint256 newHash) {
        // add the XOR`ed hash of the single option position `tokenId` to the `existingHash`
        // @dev 0 ^ x = x

        unchecked {
            // update hash by taking the XOR of the new tokenId
            uint248 updatedHash = uint248(existingHash) ^
                (uint248(uint256(keccak256(abi.encode(tokenId)))));
            // increment the top 8 bit if addflag=true, decrement otherwise
            newHash = addFlag
                ? uint256(updatedHash) + (((existingHash >> 248) + 1) << 248)
                : uint256(updatedHash) + (((existingHash >> 248) - 1) << 248);
        }
    }

    /// @notice Computes the twap of a Uniswap V3 pool using data from its oracle.
    /// @dev Note that our definition of TWAP differs from a typical mean of prices over a time window
    /// @dev We instead observe the average price over a series of time intervals, and define the TWAP as the median of those averages
    /// @param univ3pool the Uniswap pool upon which to compute the TWAP
    /// @param twapWindow the time window to compute the twap over
    /// @return twapTick the final calculated TWAP tick
    function twapFilter(
        IUniswapV3Pool univ3pool,
        uint32 twapWindow
    ) external view returns (int24 twapTick) {
        uint32[] memory secondsAgos = new uint32[](20);

        int24[] memory twapMeasurement = new int24[](19);

        unchecked {
            // construct the time stots
            for (uint32 i = 0; i < 20; ++i) {
                secondsAgos[i] = ((i + 1) * twapWindow) / uint32(20);
            }

            // observe the tickCumulative at the 20 pre-defined time slots
            (int56[] memory tickCumulatives, ) = univ3pool.observe(secondsAgos);

            // compute the average tick per 30s window
            for (uint32 i = 0; i < 19; ++i) {
                twapMeasurement[i] = int24(
                    (tickCumulatives[i] - tickCumulatives[i + 1]) / int56(uint56(twapWindow / 20))
                );
            }

            // sort the tick measurements
            int24[] memory sortedTicks = Math.sort(twapMeasurement);

            // Get the median value
            twapTick = sortedTicks[10];
        }
    }

    /*//////////////////////////////////////////////////////////////
                         LIQUIDITY CALCULATION
    //////////////////////////////////////////////////////////////*/

    /// @notice For a given option position (`tokenId`), leg index within that position (`legIndex`), and `positionSize` get the tick range spanned and its
    /// liquidity (share ownership) in the Univ3 pool; this is a liquidity chunk.

    ///          Liquidity chunk  (defined by tick upper, tick lower, and its size/amount: the liquidity)
    ///   liquidity    │
    ///         ▲      │
    ///         │     ┌▼┐
    ///         │  ┌──┴─┴──┐
    ///         │  │       │
    ///         │  │       │
    ///         └──┴───────┴────► price
    ///         Uniswap v3 Pool
    /// @param tokenId the option position id
    /// @param legIndex the leg index of the option position, can be {0,1,2,3}
    /// @param positionSize the number of contracts held by this leg
    /// @param tickSpacing the tick spacing of the underlying univ3 pool
    /// @return liquidityChunk a uint256 bit-packed (see `LiquidityChunk.sol`) with `tickLower`, `tickUpper`, and `liquidity`
    function getLiquidityChunk(
        uint256 tokenId,
        uint256 legIndex,
        uint128 positionSize,
        int24 tickSpacing
    ) internal pure returns (uint256 liquidityChunk) {
        // get the tick range for this leg
        (int24 tickLower, int24 tickUpper) = tokenId.asTicks(legIndex, tickSpacing);

        // Get the amount of liquidity owned by this leg in the univ3 pool in the above tick range
        // Background:
        //
        //  In Uniswap v3, the amount of liquidity received for a given amount of token0 when the price is
        //  not in range is given by:
        //     Liquidity = amount0 * (sqrt(upper) * sqrt(lower)) / (sqrt(upper) - sqrt(lower))
        //  For token1, it is given by:
        //     Liquidity = amount1 / (sqrt(upper) - sqrt(lower))
        //
        //  However, in Panoptic, each position has a asset parameter. The asset is the "basis" of the position.
        //  In TradFi, the asset is always cash and selling a $1000 put requires the user to lock $1000, and selling
        //  a call requires the user to lock 1 unit of asset.
        //
        //  Because Uni v3 chooses token0 and token1 from the alphanumeric order, there is no consistency as to whether token0 is
        //  stablecoin, ETH, or an ERC20. Some pools may want ETH to be the asset (e.g. ETH-DAI) and some may wish the stablecoin to
        //  be the asset (e.g. DAI-ETH) so that K asset is moved for puts and 1 asset is moved for calls.
        //  But since the convention is to force the order always we have no say in this.
        //
        //  To solve this, we encode the asset value in tokenId. This parameter specifies which of token0 or token1 is the
        //  asset, such that:
        //     when asset=0, then amount0 moved at strike K =1.0001**currentTick is 1, amount1 moved to strike K is 1/K
        //     when asset=1, then amount1 moved at strike K =1.0001**currentTick is K, amount0 moved to strike K is 1
        //
        //  The following function takes this into account when computing the liquidity of the leg and switches between
        //  the definition for getLiquidityForAmount0 or getLiquidityForAmount1 when relevant.
        //
        //
        uint128 legLiquidity;
        uint256 amount = uint256(positionSize) * tokenId.optionRatio(legIndex);
        if (tokenId.asset(legIndex) == 0) {
            legLiquidity = Math.getLiquidityForAmount0(
                uint256(0).addTickLower(tickLower).addTickUpper(tickUpper),
                amount
            );
        } else {
            legLiquidity = Math.getLiquidityForAmount1(
                uint256(0).addTickLower(tickLower).addTickUpper(tickUpper),
                amount
            );
        }

        // now pack this info into the bit pattern of the uint256 and return it
        liquidityChunk = liquidityChunk.createChunk(tickLower, tickUpper, legLiquidity);
    }

    /// @notice Extract the tick range specified by `strike` and `width` for the given `tickSpacing`, if valid.
    /// @param strike the strike price of the option
    /// @param width the width of the option
    /// @param tickSpacing the tick spacing of the underlying Uniswap v3 pool
    /// @return tickLower the lower tick of the liquidity chunk.
    /// @return tickUpper the upper tick of the liquidity chunk.
    function getTicks(
        int24 strike,
        int24 width,
        int24 tickSpacing
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        unchecked {
            // The max/min ticks that can be initialized are the closest multiple of tickSpacing to the actual max/min tick abs()=887272
            // Dividing and multiplying by tickSpacing rounds down and forces the tick to be a multiple of tickSpacing
            int24 minTick = (Constants.MIN_V3POOL_TICK / tickSpacing) * tickSpacing;
            int24 maxTick = (Constants.MAX_V3POOL_TICK / tickSpacing) * tickSpacing;

            // The width is from lower to upper tick, the one-sided range is from strike to upper/lower
            int24 oneSidedRange = (width * tickSpacing) / 2;

            (tickLower, tickUpper) = (strike - oneSidedRange, strike + oneSidedRange);

            // Revert if the upper/lower ticks are not multiples of tickSpacing
            // Revert if the tick range extends from the strike outside of the valid tick range
            // These are invalid states, and would revert silently later in `univ3Pool.mint`
            if (
                tickLower % tickSpacing != 0 ||
                tickUpper % tickSpacing != 0 ||
                tickLower < minTick ||
                tickUpper > maxTick
            ) revert Errors.TicksNotInitializable();
        }
    }

    /*//////////////////////////////////////////////////////////////
                         TOKEN CONVERSION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Compute the amount of funds that are underlying this option position. This is useful when exercising a position.
    /// @param tokenId the option position id
    /// @param positionSize The number of contracts of this option
    /// @param tickSpacing the tick spacing of the underlying Uniswap v3 pool
    /// @return longAmounts Left-right packed word where the right conains the total contract size and the left total notional
    /// @return shortAmounts Left-right packed word where the right conains the total contract size and the left total notional
    function computeExercisedAmounts(
        uint256 tokenId,
        uint128 positionSize,
        int24 tickSpacing
    ) internal pure returns (int256 longAmounts, int256 shortAmounts) {
        uint256 numLegs = tokenId.countLegs();
        for (uint256 leg = 0; leg < numLegs; ) {
            // Compute the amount of funds that have been removed from the Panoptic Pool
            (int256 longs, int256 shorts) = _calculateIOAmounts(
                tokenId,
                positionSize,
                leg,
                tickSpacing
            );

            longAmounts = longAmounts.add(longs);
            shortAmounts = shortAmounts.add(shorts);

            unchecked {
                ++leg;
            }
        }
    }

    /// @notice Adds required collateral and collateral balance from collateralTracker0 and collateralTracker1 and converts to single values in terms of `tokenType`.
    /// @param tokenData0 LeftRight type container holding the collateralBalance (right slot) and requiredCollateral (left slot) for a user in CollateralTracker0 (expressed in terms of token0)
    /// @param tokenData1 LeftRight type container holding the collateralBalance (right slot) and requiredCollateral (left slot) for a user in CollateralTracker0 (expressed in terms of token1)
    /// @param tokenType the type of token (token0 or token1) to express collateralBalance and requiredCollateral in
    /// @param sqrtPriceX96 the sqrt price at which to convert between token0/token1
    /// @return collateralBalance the total combined balance of token0 and token1 for a user in terms of tokenType
    /// @return requiredCollateral The combined collateral requirement for a user in terms of tokenType
    function convertCollateralData(
        uint256 tokenData0,
        uint256 tokenData1,
        uint256 tokenType,
        uint160 sqrtPriceX96
    ) internal pure returns (uint256, uint256) {
        if (tokenType == 0) {
            return (
                tokenData0.rightSlot() + convert1to0(tokenData1.rightSlot(), sqrtPriceX96),
                tokenData0.leftSlot() + convert1to0(tokenData1.leftSlot(), sqrtPriceX96)
            );
        } else {
            return (
                tokenData1.rightSlot() + convert0to1(tokenData0.rightSlot(), sqrtPriceX96),
                tokenData1.leftSlot() + convert0to1(tokenData0.leftSlot(), sqrtPriceX96)
            );
        }
    }

    /// @notice Adds required collateral and collateral balance from collateralTracker0 and collateralTracker1 and converts to single values in terms of `tokenType`
    /// @param tokenData0 LeftRight type container holding the collateralBalance (right slot) and requiredCollateral (left slot) for a user in CollateralTracker0 (expressed in terms of token0)
    /// @param tokenData1 LeftRight type container holding the collateralBalance (right slot) and requiredCollateral (left slot) for a user in CollateralTracker0 (expressed in terms of token1)
    /// @param tokenType the type of token (token0 or token1) to express collateralBalance and requiredCollateral in
    /// @param tick the tick at which to convert between token0/token1
    /// @return collateralBalance the total combined balance of token0 and token1 for a user in terms of tokenType
    /// @return requiredCollateral The combined collateral requirement for a user in terms of tokenType
    function convertCollateralData(
        uint256 tokenData0,
        uint256 tokenData1,
        uint256 tokenType,
        int24 tick
    ) internal pure returns (uint256, uint256) {
        return
            convertCollateralData(tokenData0, tokenData1, tokenType, Math.getSqrtRatioAtTick(tick));
    }

    /// @notice Compute the notional amount given an incoming total number of `contracts` deployed between `tickLower` and `tickUpper`.
    /// @notice The notional value of an option is the value of the crypto assets that are controlled (rather than the cost of the transaction).
    /// @notice Example: Notional value in an option refers to the value that the option controls.
    /// @notice For example, token ABC is trading for $20 with a particular ABC call option costing $1.50.
    /// @notice One option controls 100 underlying tokens. A trader purchases the option for $1.50 x 100 = $150.
    /// @notice The notional value of the option is $20 x 100 = $2,000 --> (underlying price) * (contract/position size).
    /// @notice Thus, `contracts` refer to "100" in this example. The $20 is the strike price. We get the strike price from `tickLower` and `tickUpper`.
    /// @notice From TradFi: https://www.investopedia.com/terms/n/notionalvalue.asp.
    /// @param contractSize the total number of contracts (position size) between `tickLower` and `tickUpper
    /// @param tickLower the lower price tick of the position. The strike price can be recovered from this + `tickUpper`
    /// @param tickUpper the upper price tick of the position. The strike price can be recovered from this + `tickLower`
    /// @param asset the asset for that leg (token0=0, token1=1)
    /// @return notional the notional value of the option position
    function convertNotional(
        uint128 contractSize,
        int24 tickLower,
        int24 tickUpper,
        uint256 asset
    ) internal pure returns (uint128) {
        unchecked {
            uint256 notional = asset == 0
                ? convert0to1(contractSize, Math.getSqrtRatioAtTick((tickUpper + tickLower) / 2))
                : convert1to0(contractSize, Math.getSqrtRatioAtTick((tickUpper + tickLower) / 2));

            if (notional == 0 || notional > type(uint128).max) revert Errors.InvalidNotionalValue();

            return uint128(notional);
        }
    }

    /// @notice Convert an amount of token0 into an amount of token1 given the sqrtPriceX96 in a Uniswap pool defined as sqrt(1/0)*2^96.
    /// @dev Uses reduced precision after tick 443636 in order to accomodate the full range of ticks
    /// @param amount the amount of token0 to convert into token1
    /// @param sqrtPriceX96 the square root of the price at which to convert `amount` of token0 into token1
    /// @return the converted `amount` of token0 represented in terms of token1
    function convert0to1(uint256 amount, uint160 sqrtPriceX96) internal pure returns (uint256) {
        unchecked {
            // the tick 443636 is the maximum price where (price) * 2**192 fits into a uint256 (< 2**256-1)
            // above that tick, we are forced to reduce the amount of decimals in the final price by 2**64 to 2**128
            if (sqrtPriceX96 < type(uint128).max) {
                return Math.mulDiv192(amount, uint256(sqrtPriceX96) ** 2);
            } else {
                return Math.mulDiv128(amount, Math.mulDiv64(sqrtPriceX96, sqrtPriceX96));
            }
        }
    }

    /// @notice Convert an amount of token1 into an amount of token0 given the sqrtPriceX96 in a Uniswap pool defined as sqrt(1/0)*2^96.
    /// @dev Uses reduced precision after tick 443636 in order to accomodate the full range of ticks
    /// @param amount the amount of token1 to convert into token0
    /// @param sqrtPriceX96 the square root of the price at which to convert `amount` of token1 into token0
    /// @return the converted `amount` of token1 represented in terms of token0
    function convert1to0(uint256 amount, uint160 sqrtPriceX96) internal pure returns (uint256) {
        unchecked {
            // the tick 443636 is the maximum price where (price) * 2**192 fits into a uint256 (< 2**256-1)
            // above that tick, we are forced to reduce the amount of decimals in the final price by 2**64 to 2**128
            if (sqrtPriceX96 < type(uint128).max) {
                return Math.mulDiv(amount, 2 ** 192, uint256(sqrtPriceX96) ** 2);
            } else {
                return Math.mulDiv(amount, 2 ** 128, Math.mulDiv64(sqrtPriceX96, sqrtPriceX96));
            }
        }
    }

    /// @notice Convert an amount of token0 into an amount of token1 given the sqrtPriceX96 in a Uniswap pool defined as sqrt(1/0)*2^96.
    /// @dev Uses reduced precision after tick 443636 in order to accomodate the full range of ticks
    /// @param amount the amount of token0 to convert into token1
    /// @param sqrtPriceX96 the square root of the price at which to convert `amount` of token0 into token1
    /// @return the converted `amount` of token0 represented in terms of token1
    function convert0to1(int256 amount, uint160 sqrtPriceX96) internal pure returns (int256) {
        unchecked {
            // the tick 443636 is the maximum price where (price) * 2**192 fits into a uint256 (< 2**256-1)
            // above that tick, we are forced to reduce the amount of decimals in the final price by 2**64 to 2**128
            if (sqrtPriceX96 < type(uint128).max) {
                int256 absResult = Math
                    .mulDiv192(Math.absUint(amount), uint256(sqrtPriceX96) ** 2)
                    .toInt256();
                return amount < 0 ? -absResult : absResult;
            } else {
                int256 absResult = Math
                    .mulDiv128(Math.absUint(amount), Math.mulDiv64(sqrtPriceX96, sqrtPriceX96))
                    .toInt256();
                return amount < 0 ? -absResult : absResult;
            }
        }
    }

    /// @notice Convert an amount of token0 into an amount of token1 given the sqrtPriceX96 in a Uniswap pool defined as sqrt(1/0)*2^96.
    /// @dev Uses reduced precision after tick 443636 in order to accomodate the full range of ticks
    /// @param amount the amount of token0 to convert into token1
    /// @param sqrtPriceX96 the square root of the price at which to convert `amount` of token0 into token1
    /// @return the converted `amount` of token0 represented in terms of token1
    function convert1to0(int256 amount, uint160 sqrtPriceX96) internal pure returns (int256) {
        unchecked {
            // the tick 443636 is the maximum price where (price) * 2**192 fits into a uint256 (< 2**256-1)
            // above that tick, we are forced to reduce the amount of decimals in the final price by 2**64 to 2**128
            if (sqrtPriceX96 < type(uint128).max) {
                int256 absResult = Math
                    .mulDiv(Math.absUint(amount), 2 ** 192, uint256(sqrtPriceX96) ** 2)
                    .toInt256();
                return amount < 0 ? -absResult : absResult;
            } else {
                int256 absResult = Math
                    .mulDiv(
                        Math.absUint(amount),
                        2 ** 128,
                        Math.mulDiv64(sqrtPriceX96, sqrtPriceX96)
                    )
                    .toInt256();
                return amount < 0 ? -absResult : absResult;
            }
        }
    }

    /// @notice Compute the amount of token0 and token1 moved. Given an option position `tokenId`, leg index `legIndex`, and how many contracts are in the leg `positionSize`.
    /// @param tokenId the option position identifier
    /// @param positionSize the number of option contracts held in this position (each contract can control multiple tokens)
    /// @param legIndex the leg index of the option contract, can be {0,1,2,3}
    /// @param tickSpacing the tick spacing of the underlying UniV3 pool
    /// @return amountsMoved a LeftRight encoded variable containing the amount0 and the amount1 value controlled by this option position's leg
    function getAmountsMoved(
        uint256 tokenId,
        uint128 positionSize,
        uint256 legIndex,
        int24 tickSpacing
    ) internal pure returns (uint256 amountsMoved) {
        // get the tick range for this leg in order to get the strike price (the underlying price)
        (int24 tickLower, int24 tickUpper) = tokenId.asTicks(legIndex, tickSpacing);

        // positionSize: how many option contracts we have.

        uint128 amount0;
        uint128 amount1;
        unchecked {
            if (tokenId.asset(legIndex) == 0) {
                // contractSize: is then the product of how many option contracts we have and the amount of underlying controlled per contract
                amount0 = positionSize * uint128(tokenId.optionRatio(legIndex)); // in terms of the underlying tokens/shares
                // notional is then "how many underlying tokens are controlled (contractSize) * (the price for each token -- strike price):
                amount1 = convertNotional(amount0, tickLower, tickUpper, tokenId.asset(legIndex)); // how many tokens are controlled by this option position
            } else {
                amount1 = positionSize * uint128(tokenId.optionRatio(legIndex));
                amount0 = convertNotional(amount1, tickLower, tickUpper, tokenId.asset(legIndex));
            }
        }
        amountsMoved = amountsMoved.toRightSlot(amount0).toLeftSlot(amount1);
    }

    /// @notice Compute the amount of funds that are moved to and removed from the Panoptic Pool.
    /// @param tokenId the option position identifier
    /// @param positionSize The number of positions minted
    /// @param legIndex the leg index minted in this position, can be {0,1,2,3}
    /// @param tickSpacing the tick spacing of the underlying Uniswap v3 pool
    /// @return longs A LeftRight-packed word containing the total amount of long positions
    /// @return shorts A LeftRight-packed word containing the amount of short positions
    function _calculateIOAmounts(
        uint256 tokenId,
        uint128 positionSize,
        uint256 legIndex,
        int24 tickSpacing
    ) internal pure returns (int256 longs, int256 shorts) {
        // compute amounts moved
        uint256 amountsMoved = getAmountsMoved(tokenId, positionSize, legIndex, tickSpacing);

        bool isShort = tokenId.isLong(legIndex) == 0;

        // if token0
        if (tokenId.tokenType(legIndex) == 0) {
            if (isShort) {
                // if option is short, increment shorts by contracts
                shorts = shorts.toRightSlot(Math.toInt128(amountsMoved.rightSlot()));
            } else {
                // is option is long, increment longs by contracts
                longs = longs.toRightSlot(Math.toInt128(amountsMoved.rightSlot()));
            }
        } else {
            if (isShort) {
                // if option is short, increment shorts by notional
                shorts = shorts.toLeftSlot(Math.toInt128(amountsMoved.leftSlot()));
            } else {
                // if option is long, increment longs by notional
                longs = longs.toLeftSlot(Math.toInt128(amountsMoved.leftSlot()));
            }
        }
    }

    /// @notice Compute the premia collected for a single option position 'tokenId'.
    /// @param tokenId The option position.
    /// @param positionSize The number of contracts (size) of the option position.
    /// @param computeAllPremia Whether to compute accumulated premia for all legs held by the user (true), or just owed premia for long legs (false).
    /// @param atTick The tick at which the premia is calculated -> use (atTick < type(int24).max) to compute it
    /// up to current block. atTick = type(int24).max will only consider fees as of the last on-chain transaction.
    function getPremia(
        bool computeAllPremia,
        SemiFungiblePositionManager sfpm,
        address univ3pool,
        mapping(uint256 => uint256) storage accumulatorLastByLeg,
        int24 tickSpacing,
        int24 atTick,
        uint256 tokenId,
        uint128 positionSize
    )
        external
        view
        returns (int256[4] memory premiaByLeg, uint256[2][4] memory premiumAccumulatorsByLeg)
    {
        uint256 numLegs = tokenId.countLegs();
        for (uint256 leg = 0; leg < numLegs; ) {
            uint256 isLong = tokenId.isLong(leg);
            if ((isLong == 1) || computeAllPremia) {
                uint256 liquidityChunk = PanopticMath.getLiquidityChunk(
                    tokenId,
                    leg,
                    positionSize,
                    tickSpacing
                );

                (premiumAccumulatorsByLeg[leg][0], premiumAccumulatorsByLeg[leg][1]) = sfpm
                    .getAccountPremium(
                        address(univ3pool),
                        address(this),
                        tokenId.tokenType(leg),
                        liquidityChunk.tickLower(),
                        liquidityChunk.tickUpper(),
                        atTick,
                        isLong
                    );

                unchecked {
                    uint256 premiumAccumulatorLast = accumulatorLastByLeg[leg];

                    // if the premium accumulatorLast is higher than current, it means the premium accumulator has overflowed and rolled over at least once
                    // we can account for one rollover by doing (acc_cur + (acc_max - acc_last))
                    // if there are multiple rollovers or the rollover goes past the last accumulator, rolled over fees will just remain unclaimed
                    premiaByLeg[leg] = int256(0)
                        .toRightSlot(
                            int128(
                                int256(
                                    ((premiumAccumulatorsByLeg[leg][0] -
                                        premiumAccumulatorLast.rightSlot()) *
                                        (liquidityChunk.liquidity())) / 2 ** 64
                                )
                            )
                        )
                        .toLeftSlot(
                            int128(
                                int256(
                                    ((premiumAccumulatorsByLeg[leg][1] -
                                        premiumAccumulatorLast.leftSlot()) *
                                        (liquidityChunk.liquidity())) / 2 ** 64
                                )
                            )
                        );

                    if (isLong == 1) {
                        premiaByLeg[leg] = -premiaByLeg[leg];
                    }
                }
            }
            unchecked {
                ++leg;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                       REVOKE/REFUND COMPUTATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Check that the account is liquidatable, get the split of bonus0 and bonus1 amounts.
    /// @param tokenData0 Leftright encoded word with balance of token0 in the right slot, and required balance in left slot.
    /// @param tokenData1 Leftright encoded word with balance of token1 in the right slot, and required balance in left slot.
    /// @param sqrtPriceX96Twap The sqrt(price) of the TWAP tick before liquidation used to evaluate solvency
    /// @param sqrtPriceX96Final The current sqrt(price) of the AMM after liquidating a user.
    /// @param netExchanged The net exchanged value of the closed portfolio
    /// @param premia premium across all positions being liquidated present in tokenData
    /// @return bonus0 bonus amount for token0
    /// @return bonus1 bonus amount for token1
    function getLiquidationBonus(
        uint256 tokenData0,
        uint256 tokenData1,
        uint160 sqrtPriceX96Twap,
        uint160 sqrtPriceX96Final,
        int256 netExchanged,
        int256 premia
    ) external pure returns (int256 bonus0, int256 bonus1, int256) {
        unchecked {
            // compute bonus as min(collateralBalance/2, required-collateralBalance)
            {
                // compute the ratio of token0 to total collateral requirements
                // evaluate at TWAP price to keep consistentcy with solvency calculations
                uint256 required0 = PanopticMath.convert0to1(
                    tokenData0.leftSlot(),
                    sqrtPriceX96Twap
                );
                uint256 required1 = tokenData1.leftSlot();
                uint256 requiredRatioX128 = (required0 << 128) / (required0 + required1);

                (uint256 balanceCross, uint256 thresholdCross) = PanopticMath.convertCollateralData(
                    tokenData0,
                    tokenData1,
                    0,
                    sqrtPriceX96Twap
                );

                uint256 bonusCross = Math.min(balanceCross / 2, thresholdCross - balanceCross);

                // convert that bonus to tokens 0 and 1
                bonus0 = int256(Math.mulDiv128(bonusCross, requiredRatioX128));

                bonus1 = int256(
                    PanopticMath.convert0to1(
                        Math.mulDiv128(bonusCross, 2 ** 128 - requiredRatioX128),
                        sqrtPriceX96Final
                    )
                );
            }

            // negative premium (owed to the liquidatee) is credited to the collateral balance
            // this is already present in the netExchanged amount, so to avoid double-counting we remove it from the balance
            int256 balance0 = int256(uint256(tokenData0.rightSlot())) -
                Math.max(premia.rightSlot(), 0);
            int256 balance1 = int256(uint256(tokenData1.rightSlot())) -
                Math.max(premia.leftSlot(), 0);

            int256 paid0 = bonus0 + int256(netExchanged.rightSlot());
            int256 paid1 = bonus1 + int256(netExchanged.leftSlot());

            // note that "balance0" and "balance1" are the liquidatee's original balances before token delegation by a liquidator
            // their actual balances at the time of computation may be higher, but these are a buffer representing the amount of tokens we
            // have to work with before cutting into the liquidator's funds
            if (!(paid0 > balance0 && paid1 > balance1)) {
                // liquidatee cannot pay back the liquidator fully in either token, so no protocol loss can be avoided
                if ((paid0 > balance0)) {
                    // liquidatee has insufficient token0 but some token1 left over, so we use what they have left to mitigate token0 losses
                    // we do this by substituting an equivalent value of token1 in our refund to the liquidator, plus a bonus, for the token0 we convert
                    // we want to convert the minimum amount of tokens required to achieve the lowest possible protocol loss (to avoid overpaying on the conversion bonus)
                    // the maximum level of protocol loss mitigation that can be achieved is the liquidatee's excess token1 balance: balance1 - paid1
                    // and paid0 - balance0 is the amount of token0 that the liquidatee is missing, i.e the protocol loss
                    // if the protocol loss is lower than the excess token1 balance, then we can fully mitigate the loss and we should only convert the loss amount
                    // if the protocol loss is higher than the excess token1 balance, we can only mitigate part of the loss, so we should convert only the excess token1 balance
                    // thus, the value converted should be min(balance1 - paid1, paid0 - balance0)
                    bonus1 += Math.min(
                        balance1 - paid1,
                        PanopticMath.convert0to1(paid0 - balance0, sqrtPriceX96Final)
                    );
                    bonus0 -= Math.min(
                        PanopticMath.convert1to0(balance1 - paid1, sqrtPriceX96Final),
                        paid0 - balance0
                    );
                }
                if ((paid1 > balance1)) {
                    // liquidatee has insufficient token1 but some token0 left over, so we use what they have left to mitigate token1 losses
                    // we do this by substituting an equivalent value of token0 in our refund to the liquidator, plus a bonus, for the token1 we convert
                    // we want to convert the minimum amount of tokens required to achieve the lowest possible protocol loss (to avoid overpaying on the conversion bonus)
                    // the maximum level of protocol loss mitigation that can be achieved is the liquidatee's excess token0 balance: balance0 - paid0
                    // and paid1 - balance1 is the amount of token1 that the liquidatee is missing, i.e the protocol loss
                    // if the protocol loss is lower than the excess token0 balance, then we can fully mitigate the loss and we should only convert the loss amount
                    // if the protocol loss is higher than the excess token0 balance, we can only mitigate part of the loss, so we should convert only the excess token0 balance
                    // thus, the value converted should be min(balance0 - paid0, paid1 - balance1)
                    bonus0 += Math.min(
                        balance0 - paid0,
                        PanopticMath.convert1to0(paid1 - balance1, sqrtPriceX96Final)
                    );
                    bonus1 -= Math.min(
                        PanopticMath.convert0to1(balance0 - paid0, sqrtPriceX96Final),
                        paid1 - balance1
                    );
                }
            }

            paid0 = bonus0 + int256(netExchanged.rightSlot());
            paid1 = bonus1 + int256(netExchanged.leftSlot());

            return (
                bonus0,
                bonus1,
                int256(0).toRightSlot(int128(balance0 - paid0)).toLeftSlot(int128(balance1 - paid1))
            );
        }
    }

    /// @notice haircut/clawback any premium paid by `liquidatee` on `positionIdList` over the protocol loss threshold during a liquidation.
    /// @dev note that the storage mapping provided as the `settledTokens` parameter WILL be modified on the caller by this function
    /// @param liquidatee the address of the user being liquidated
    /// @param positionIdList the list of position ids being liquidated
    /// @param premiasByLeg the premium paid (or received) by the liquidatee for each leg of each position
    /// @param collateralRemaining the remaining collateral after the liquidation (negative if protocol loss)
    /// @param sqrtPriceX96Final the sqrt price at which to convert between token0/token1 when awarding the bonus
    /// @param collateral0 the collateral tracker for token0
    /// @param collateral1 the collateral tracker for token1
    /// @param settledTokens per-chunk accumulator of settled tokens from which to subtract the haircut premium
    /// @return bonusDelta0 the change in bonus0 for the liquidator
    /// @return bonusDelta1 the change in bonus1 for the liquidator
    function haircutPremia(
        address liquidatee,
        uint256[] memory positionIdList,
        int256[4][] memory premiasByLeg,
        int256 collateralRemaining,
        uint160 sqrtPriceX96Final,
        CollateralTracker collateral0,
        CollateralTracker collateral1,
        mapping(bytes32 chunkKey => uint256 settledTokens) storage settledTokens
    ) external returns (int256, int256) {
        // get the amount of premium paid by the liquidatee
        int256 haircut0;
        int256 haircut1;
        for (uint256 i = 0; i < positionIdList.length; i++) {
            uint256 tokenId = positionIdList[i];
            uint256 numLegs = tokenId.countLegs();
            for (uint256 leg = 0; leg < numLegs; ++leg) {
                if (tokenId.isLong(leg) == 1) {
                    haircut0 += -premiasByLeg[i][leg].rightSlot();
                    haircut1 += -premiasByLeg[i][leg].leftSlot();
                }
            }
        }

        console2.log("collateralRemaining.rightSlot()", collateralRemaining.rightSlot());
        console2.log("collateralRemaining.leftSlot()", collateralRemaining.leftSlot());
        // Ignore any surplus collateral - the liquidatee is either solvent or it converts to <1 unit of the other token
        int256 collateralDelta0 = -Math.min(collateralRemaining.rightSlot(), 0);
        int256 collateralDelta1 = -Math.min(collateralRemaining.leftSlot(), 0);

        console2.log("haircut0F", haircut0);
        console2.log("haircut1F", haircut1);
        console2.log("collateralDelta0", collateralDelta0);
        console2.log("collateralDelta1", collateralDelta1);

        // if the premium in the same token is not enough to cover the loss and there is a surplus of the other token,
        // the liquidator will provide the tokens (reflected in the bonus amount) & receive compensation in the other token
        if (haircut0 < collateralDelta0 && haircut1 > collateralDelta1) {
            int256 protocolLoss1 = collateralDelta1;
            (collateralDelta0, collateralDelta1) = (
                -Math.min(
                    collateralDelta0 - haircut0,
                    PanopticMath.convert1to0(haircut1 - collateralDelta1, sqrtPriceX96Final)
                ),
                Math.min(
                    haircut1 - collateralDelta1,
                    PanopticMath.convert0to1(collateralDelta0 - haircut0, sqrtPriceX96Final)
                )
            );

            haircut1 = protocolLoss1 + collateralDelta1;
        } else if (haircut1 < collateralDelta1 && haircut0 > collateralDelta0) {
            int256 protocolLoss0 = collateralDelta0;
            (collateralDelta0, collateralDelta1) = (
                -Math.min(
                    collateralDelta0 - haircut0,
                    PanopticMath.convert1to0(haircut1 - collateralDelta1, sqrtPriceX96Final)
                ),
                Math.min(
                    haircut1 - collateralDelta1,
                    PanopticMath.convert0to1(collateralDelta0 - haircut0, sqrtPriceX96Final)
                )
            );

            haircut0 = collateralDelta0 + protocolLoss0;
        } else {
            collateralDelta0 = 0;
            collateralDelta1 = 0;
            // for each token, haircut until the protocol loss is mitigated or the premium paid is exhausted
            haircut0 = Math.min(collateralDelta0, haircut0);
            haircut1 = Math.min(collateralDelta1, haircut1);
        }

        if (haircut0 != 0) collateral0.exercise(liquidatee, 0, 0, 0, int128(-haircut0));
        if (haircut1 != 0) collateral1.exercise(liquidatee, 0, 0, 0, int128(-haircut1));

        console2.log("haircut0", haircut0);
        console2.log("haircut1", haircut1);
        for (uint256 i = 0; i < positionIdList.length; i++) {
            int256[4][] memory _premiasByLeg = premiasByLeg;
            uint256 tokenId = positionIdList[i];
            for (uint256 leg = 0; leg < tokenId.countLegs(); ++leg) {
                if (tokenId.isLong(leg) == 1) {
                    bytes32 chunkKey = keccak256(
                        abi.encodePacked(tokenId.strike(0), tokenId.width(0), tokenId.tokenType(0))
                    );

                    // calculate amounts to revoke from settled and subtract from haircut req
                    int256 settled0 = Math.min(-_premiasByLeg[i][leg].rightSlot(), haircut0);
                    int256 settled1 = Math.min(-_premiasByLeg[i][leg].leftSlot(), haircut1);
                    haircut0 -= settled0;
                    haircut1 -= settled1;

                    // The long premium is not commited to storage during the liquidation, so we add the entire adjusted amount
                    // for the haircut directly to the accumulator
                    settled0 = -_premiasByLeg[i][leg].rightSlot() - settled0;

                    settled1 = -_premiasByLeg[i][leg].leftSlot() - settled1;
                    console2.log("settled0", settled0);
                    console2.log("settled1", settled1);

                    settledTokens[chunkKey] = uint256(
                        settledTokens[chunkKey].add(
                            int256(0).toRightSlot(int128(settled0)).toLeftSlot(int128(settled1))
                        )
                    );
                }
            }
        }

        return (collateralDelta0, collateralDelta0);
    }

    /// @notice Returns the original delegated value to a user at a certain tick based on the available collateral from the exercised user.
    /// @param refunder Address of the user the refund is coming from (the force exercisee).
    /// @param refundValues Token values to refund at the given tick(atTick) rightSlot = token0 left = token1.
    /// @param atTick Tick to convert values at. This can be the current tick or some TWAP/median tick.
    /// @param collateral0 CollateralTracker for token0.
    /// @param collateral1 CollateralTracker for token1.
    /// @return refundAmounts The amount of tokens to refund to the user.
    function getRefundAmounts(
        address refunder,
        int256 refundValues,
        int24 atTick,
        CollateralTracker collateral0,
        CollateralTracker collateral1
    ) external view returns (int256 refundAmounts) {
        uint160 sqrtPriceX96 = Math.getSqrtRatioAtTick(atTick);
        unchecked {
            // if the refunder lacks sufficient token0 to pay back the refundee, have them pay back the equivalent value in token1
            // note: it is possible for refunds to be negative when the exercise fee is higher than the delegated amounts. This is expected behavior
            int256 balanceShortage = refundValues.rightSlot() -
                int256(collateral0.convertToAssets(collateral0.balanceOf(refunder)));

            if (balanceShortage > 0) {
                return
                    int256(0)
                        .toRightSlot(int128(refundValues.rightSlot() - balanceShortage))
                        .toLeftSlot(
                            int128(
                                int256(
                                    PanopticMath.convert0to1(uint256(balanceShortage), sqrtPriceX96)
                                ) + refundValues.leftSlot()
                            )
                        );
            }

            balanceShortage =
                refundValues.leftSlot() -
                int256(collateral1.convertToAssets(collateral1.balanceOf(refunder)));

            if (balanceShortage > 0) {
                return
                    int256(0)
                        .toLeftSlot(int128(refundValues.leftSlot() - balanceShortage))
                        .toRightSlot(
                            int128(
                                int256(
                                    PanopticMath.convert1to0(uint256(balanceShortage), sqrtPriceX96)
                                ) + refundValues.rightSlot()
                            )
                        );
            }
        }

        // otherwise, we can just refund the original amounts requested with no problems
        return refundValues;
    }
}
