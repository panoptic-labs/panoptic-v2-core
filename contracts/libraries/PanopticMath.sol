// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;
// Interfaces
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
// Libraries
import {Constants} from "@libraries/Constants.sol";
import {Math} from "@libraries/Math.sol";
import {EfficientHash} from "@libraries/EfficientHash.sol";
import {Errors} from "@libraries/Errors.sol";
// OpenZeppelin libraries
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
// Custom types
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {TokenId} from "@types/TokenId.sol";
import {RiskParameters} from "@types/RiskParameters.sol";

/// @title Compute general math quantities relevant to Panoptic and AMM pool management.
/// @notice Contains Panoptic-specific helpers and math functions.
/// @author Axicon Labs Limited
library PanopticMath {
    using Math for uint256;

    /// @notice This is equivalent to `type(uint256).max` — used in assembly blocks as a replacement.
    uint256 internal constant MAX_UINT256 = 2 ** 256 - 1;

    /// @notice Masks 16-bit tickSpacing and 8 bits of vegoid out of 64-bit `[16-bit tickspacing][8-bit vegoid][40-bit poolPattern]` format poolId.
    uint64 internal constant TICKSPACING_VEGOID_MASK = 0xFFFFFF0000000000;

    uint256 internal constant PRIME_MODULUS_248 =
        0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff13;

    uint256 internal constant PRIME_MODULUS_124_0 = 0xfffffffffffffffffffffffffffffc5; // 2**124 - 59
    uint256 internal constant PRIME_MODULUS_124_1 = 0xffffffffffffffffffffffffffffd99; // 2**124 - 615

    // Mask for isolating a 124-bit lane
    uint256 internal constant LANE_MASK_124 = 0xfffffffffffffffffffffffffffffff;

    uint256 internal constant UPPER_120BITS_MASK =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000000000000000000000000000;

    uint256 internal constant BITMASK_UINT88 = 0xFFFFFFFFFFFFFFFFFFFFFF;
    uint256 internal constant BITMASK_UINT22 = 0x3FFFFF;

    /*//////////////////////////////////////////////////////////////
                              UTILITIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Increments the pool pattern (first 48 bits) of a poolId by 1.
    /// @param poolId The 64-bit pool ID
    /// @return The provided `poolId` with its pool pattern slot incremented by 1
    function incrementPoolPattern(uint64 poolId) internal pure returns (uint64) {
        unchecked {
            return (poolId & TICKSPACING_VEGOID_MASK) + (uint40(poolId + 1));
        }
    }

    /// @notice Get the number of leading hex characters in an address.
    //     0x0000bababaab...     0xababababab...
    //          ▲                 ▲
    //          │                 │
    //     4 leading hex      0 leading hex
    //    character zeros    character zeros
    //
    /// @param addr The address to get the number of leading zero hex characters for
    /// @return The number of leading zero hex characters in the address
    function numberOfLeadingHexZeros(address addr) external pure returns (uint256) {
        unchecked {
            return addr == address(0) ? 40 : 39 - Math.mostSignificantNibble(uint160(addr));
        }
    }

    /// @notice Returns ERC20 symbol of `token`.
    /// @param token The address of the token to get the symbol of
    /// @return The symbol of `token` or "???" if not supported
    function safeERC20Symbol(address token) external view returns (string memory) {
        // not guaranteed that token supports metadata extension
        // so we need to let call fail and return placeholder if not
        try IERC20Metadata(token).symbol() returns (string memory symbol) {
            return symbol;
        } catch {
            return "???";
        }
    }

    /// @notice Converts `fee` to a string with "bps" appended.
    /// @dev The lowest supported value of `fee` is 1 (`="0.01bps"`).
    /// @param fee The fee to convert to a string (in hundredths of basis points)
    /// @return Stringified version of `fee` with "bps" appended
    function uniswapFeeToString(uint24 fee) internal pure returns (string memory) {
        return
            string.concat(
                Strings.toString(fee / 100),
                fee % 100 == 0
                    ? ""
                    : string.concat(
                        ".",
                        Strings.toString((fee / 10) % 10),
                        Strings.toString(fee % 10)
                    ),
                "bps"
            );
    }

    /// @notice Update an existing account's "positions hash" with a new `tokenId`.
    /// @notice The positions hash contains a fingerprint of all open positions created by an account/user and a count of the legs across those positions.
    /// @dev The "fingerprint" portion of the hash is given by XORing the hashed `tokenId` of each position the user has open together.
    /// @param existingHash The existing position hash representing a list of positions and the count of the legs across those positions
    /// @param tokenId The new position to modify the existing hash with: `existingHash = uint248(existingHash) ^ uint248(hashOf(tokenId))`
    /// @param addFlag Whether to mint (add) the tokenId to the count of positions or burn (subtract) it from the count `(existingHash >> 248) +/- tokenId.countLegs()`
    /// @return newHash The updated position hash with the new tokenId XORed in and the leg count incremented/decremented
    function updatePositionsHash(
        uint256 existingHash,
        TokenId tokenId,
        bool addFlag
    ) internal pure returns (uint256) {
        // update hash by using the homomorphicHash method
        uint256 updatedHash = homomorphicHash(existingHash, TokenId.unwrap(tokenId), addFlag);

        // increment the upper 8 bits (leg counter) if addFlag=true, decrement otherwise
        uint8 numberOfLegs = uint8(tokenId.countLegs());
        if (numberOfLegs == 0) revert Errors.TokenIdHasZeroLegs();

        // unchecked, so reverts if overflow
        uint256 newLegCount = addFlag
            ? uint8(existingHash >> 248) + numberOfLegs
            : uint8(existingHash >> 248) - numberOfLegs;

        unchecked {
            return uint256(updatedHash) + (newLegCount << 248);
        }
    }

    /// @notice Computes a homomorphic hash by adding or subtracting an item from an existing hash
    /// @dev Uses XOR-based homomorphic hashing (XHASH). The hash of the item is XORed with the
    ///      existing hash. Since XOR is its own inverse (A ⊕ B ⊕ B = A), both addition and
    ///      subtraction operations use the same XOR operation. This ensures the operation is
    ///      reversible and order-independent for the same set of items.
    ///      OR
    ///      Uses additive homomorphic hashing (AdHash) over a 248-bit prime field. The hash of the item
    ///      is either added to or subtracted from the existing hash using modular arithmetic.
    ///      Subtraction is implemented as addition of the modular inverse: hash + (PRIME - itemHash) mod PRIME.
    ///      This ensures the operation is reversible and order-independent for the same set of items.
    ///      OR
    ///      Uses LtHash (Lattice-based Hash) with k=2 lanes for improved collision resistance.
    ///      The 248-bit hash space is divided into two 124-bit lanes, each operating under
    ///      modular arithmetic with a 124-bit prime. The item hash is split into two 124-bit
    ///      chunks and each chunk is added/subtracted from its corresponding lane independently.
    ///      Subtraction is implemented as addition of the modular inverse: lane + (PRIME - chunk) mod PRIME.
    ///      This parallel lane approach provides better security properties than single-lane hashing
    ///      while maintaining homomorphic properties (order-independence and reversibility).
    /// @param hash The existing hash value (only lower 248 bits are used)
    /// @param item The item to be hashed and added/subtracted (typically a TokenId cast to uint256)
    /// @param addFlag True to add the item to the hash, false to subtract it
    /// @return The updated homomorphic hash as a uint256 (but only lower 248 bits contain the hash)
    function homomorphicHash(
        uint256 hash,
        uint256 item,
        bool addFlag
    ) internal pure returns (uint256) {
        /*
        {
            // XHASH
            return
                uint248(hash) ^
                (uint248(uint256(EfficientHash.efficientKeccak256(abi.encode(item)))));
        }
        {
            // AdHash
            uint256 itemHash = uint256(EfficientHash.efficientKeccak256(abi.encode(item)));
            return
                addFlag
                    ? addmod(uint248(hash), uint248(itemHash), PRIME_MODULUS_248)
                    : addmod(
                        uint248(hash),
                        PRIME_MODULUS_248 - (itemHash % PRIME_MODULUS_248),
                        PRIME_MODULUS_248
                    );
        }
        */
        unchecked {
            // LtHash, k=2
            uint256 itemHash = uint256(EfficientHash.efficientKeccak256(abi.encode(item)));

            // Pre-calculate the 124-bit chunks for the item to be added/removed
            uint256 item_h0 = itemHash & LANE_MASK_124;
            uint256 item_h1 = (itemHash >> 124) & LANE_MASK_124;

            uint256 lane0 = hash & LANE_MASK_124;
            uint256 newItem_h0 = addFlag
                ? item_h0
                : PRIME_MODULUS_124_0 - (item_h0 % PRIME_MODULUS_124_0);
            uint256 hash0 = addmod(lane0, newItem_h0, PRIME_MODULUS_124_0);

            uint256 lane1 = (hash >> 124) & LANE_MASK_124;
            uint256 newItem_h1 = addFlag
                ? item_h1
                : PRIME_MODULUS_124_1 - (item_h1 % PRIME_MODULUS_124_1);
            uint256 hash1 = addmod(lane1, newItem_h1, PRIME_MODULUS_124_1);

            return hash0 + (hash1 << 124);
        }
    }

    /// @notice Checks if an array of TokenIds contains any duplicate values
    /// @dev Uses assembly for gas optimization. Performs O(n²) comparison by checking each element
    ///      against all subsequent elements. Returns false immediately upon finding the first duplicate.
    ///      Arrays with 0 or 1 elements are considered to have no duplicates.
    /// @param arr The array of TokenIds to check for duplicates
    /// @return True if the array contains no duplicate TokenIds, false if duplicates are found
    function hasNoDuplicateTokenIds(TokenId[] calldata arr) external pure returns (bool) {
        assembly {
            let len := arr.length
            let offset := arr.offset

            // Early return for 0 or 1 elements
            if lt(len, 2) {
                mstore(0x00, 1)
                return(0x00, 0x20)
            }

            // Check for duplicates
            for {
                let i := 0
            } lt(i, len) {
                i := add(i, 1)
            } {
                let val := calldataload(add(offset, mul(i, 0x20)))
                for {
                    let j := add(i, 1)
                } lt(j, len) {
                    j := add(j, 1)
                } {
                    if eq(val, calldataload(add(offset, mul(j, 0x20)))) {
                        mstore(0x00, 0)
                        return(0x00, 0x20)
                    }
                }
            }

            mstore(0x00, 1)
            return(0x00, 0x20)
        }
    }

    /*//////////////////////////////////////////////////////////////
                          ORACLE CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the median of the last `cardinality` average prices over `period` observations from `univ3pool`.
    /// @dev Used when we need a manipulation-resistant TWAP price.
    /// @dev Uniswap observations snapshot the closing price of the last block before the first interaction of a given block.
    /// @dev The maximum frequency of observations is 1 per block, but there is no guarantee that the pool will be observed at every block.
    /// @dev Each period has a minimum length of `blocktime * period`, but may be longer if the Uniswap pool is relatively inactive.
    /// @dev The final price used in the array (of length `cardinality`) is the average of `cardinality` observations spaced by `period` (which is itself a number of observations).
    /// @dev Thus, the minimum total time window is `cardinality * period * blocktime`.
    /// @param univ3pool The Uniswap pool to get the median observation from
    /// @param observationIndex The index of the last observation in the pool
    /// @param observationCardinality The number of observations in the pool
    /// @param cardinality The number of `periods` to in the median price array, should be odd
    /// @param period The number of observations to average to compute one entry in the median price array
    /// @return The median of `cardinality` observations spaced by `period` in the Uniswap pool
    /// @return The latest observation in the Uniswap pool
    function computeMedianObservedPrice(
        IUniswapV3Pool univ3pool,
        uint256 observationIndex,
        uint256 observationCardinality,
        uint256 cardinality,
        uint256 period
    ) internal view returns (int24, int24) {
        unchecked {
            int256[] memory tickCumulatives = new int256[](cardinality + 1);

            uint256[] memory timestamps = new uint256[](cardinality + 1);
            // get the last "cardinality" timestamps/tickCumulatives (if observationIndex < cardinality, the index will wrap back from observationCardinality)
            for (uint256 i = 0; i < cardinality + 1; ++i) {
                (timestamps[i], tickCumulatives[i], , ) = univ3pool.observations(
                    uint256(
                        (int256(observationIndex) - int256(i * period)) +
                            int256(observationCardinality)
                    ) % observationCardinality
                );
            }

            int256[] memory ticks = new int256[](cardinality);
            // use cardinality periods given by cardinality + 1 accumulator observations to compute the last cardinality observed ticks spaced by period
            for (uint256 i = 0; i < cardinality; ++i) {
                ticks[i] =
                    (tickCumulatives[i] - tickCumulatives[i + 1]) /
                    int256(timestamps[i] - timestamps[i + 1]);
            }

            // the `ticks` array descends from the most recent Uniswap observation prior to the sort
            int24 latestTick = int24(ticks[0]);

            // get the median of the `ticks` array (assuming `cardinality` is odd)
            return (int24(Math.sort(ticks)[cardinality / 2]), latestTick);
        }
    }

    /// @notice Computes the TWAP of a Uniswap V3 pool using data from its oracle.
    /// @dev Note that our definition of TWAP differs from a typical mean of prices over a time window.
    /// @dev We instead observe the average price over a series of time intervals, and define the TWAP as the median of those averages.
    /// @param univ3pool The Uniswap pool from which to compute the TWAP
    /// @param twapWindow The time window to compute the TWAP over
    /// @return The final calculated TWAP tick
    function twapFilter(IUniswapV3Pool univ3pool, uint32 twapWindow) external view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](20);

        int256[] memory twapMeasurement = new int256[](19);

        unchecked {
            // construct the time slots
            for (uint256 i = 0; i < 20; ++i) {
                secondsAgos[i] = uint32(((i + 1) * twapWindow) / 20);
            }

            // observe the tickCumulative at the 20 pre-defined time slots
            (int56[] memory tickCumulatives, ) = univ3pool.observe(secondsAgos);

            // compute the average tick per 30s window
            for (uint256 i = 0; i < 19; ++i) {
                twapMeasurement[i] = int24(
                    (tickCumulatives[i] - tickCumulatives[i + 1]) / int56(uint56(twapWindow / 20))
                );
            }

            // sort the tick measurements
            int256[] memory sortedTicks = Math.sort(twapMeasurement);

            // Get the median value
            return int24(sortedTicks[9]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          LIQUIDITY CHUNK MATH
    //////////////////////////////////////////////////////////////*/

    /// @notice For a given option position (`tokenId`), leg index within that position (`legIndex`), and `positionSize` get the tick range spanned and its
    /// liquidity (share ownership) in the Uniswap V3 pool; this is a liquidity chunk.
    //          Liquidity chunk  (defined by tick upper, tick lower, and its size/amount: the liquidity)
    //   liquidity    │
    //         ▲      │
    //         │     ┌▼┐
    //         │  ┌──┴─┴──┐
    //         │  │       │
    //         │  │       │
    //         └──┴───────┴────► price
    //         Uniswap V3 Pool
    /// @param tokenId The option position id
    /// @param legIndex The leg index of the option position, can be {0,1,2,3}
    /// @param positionSize The number of contracts held by this leg
    /// @return A LiquidityChunk with `tickLower`, `tickUpper`, and `liquidity`
    function getLiquidityChunk(
        TokenId tokenId,
        uint256 legIndex,
        uint128 positionSize
    ) internal pure returns (LiquidityChunk) {
        // get the tick range for this leg
        (int24 tickLower, int24 tickUpper) = tokenId.asTicks(legIndex);

        // Get the amount of liquidity owned by this leg in the Uniswap V3 pool in the above tick range
        // Background:
        //
        //  In Uniswap V3, the amount of liquidity received for a given amount of token0 when the price is
        //  not in range is given by:
        //     Liquidity = amount0 * (sqrt(upper) * sqrt(lower)) / (sqrt(upper) - sqrt(lower))
        //  For token1, it is given by:
        //     Liquidity = amount1 / (sqrt(upper) - sqrt(lower))
        //
        //  However, in Panoptic, each position has a asset parameter. The asset is the "basis" of the position.
        //  In TradFi, the asset is always cash and selling a $1000 put requires the user to lock $1000, and selling
        //  a call requires the user to lock 1 unit of asset.
        //
        //  Because Uniswap V3 chooses token0 and token1 from the alphanumeric order, there is no consistency as to whether token0 is
        //  stablecoin, ETH, or an ERC20. Some pools may want ETH to be the asset (e.g. ETH-DAI) and some may wish the stablecoin to
        //  be the asset (e.g. DAI-ETH) so that K asset is moved for puts and 1 asset is moved for calls.
        //  But since the convention is to force the order always we have no say in this.
        //
        //  To solve this, we encode the asset value in tokenId. This parameter specifies which of token0 or token1 is the
        //  asset, such that:
        //     when asset=0, then amount0 moved at strike K =1.0001**currentTick is 1, amount1 moved to strike K is K
        //     when asset=1, then amount1 moved at strike K =1.0001**currentTick is K, amount0 moved to strike K is 1/K
        //
        //  The following function takes this into account when computing the liquidity of the leg and switches between
        //  the definition for getLiquidityForAmount0 or getLiquidityForAmount1 when relevant.

        uint256 amount = positionSize * tokenId.optionRatio(legIndex);
        if (tokenId.asset(legIndex) == 0) {
            return Math.getLiquidityForAmount0(tickLower, tickUpper, amount);
        } else {
            return Math.getLiquidityForAmount1(tickLower, tickUpper, amount);
        }
    }

    /// @notice Extract the tick range specified by `strike` and `width` for the given `tickSpacing`.
    /// @param strike The strike price of the option
    /// @param width The width of the option
    /// @param tickSpacing The tick spacing of the underlying Uniswap V3 pool
    /// @return The lower tick of the liquidity chunk
    /// @return The upper tick of the liquidity chunk
    function getTicks(
        int24 strike,
        int24 width,
        int24 tickSpacing
    ) internal pure returns (int24, int24) {
        (int24 rangeDown, int24 rangeUp) = PanopticMath.getRangesFromStrike(width, tickSpacing);

        unchecked {
            return (strike - rangeDown, strike + rangeUp);
        }
    }

    /// @notice Returns the distances of the upper and lower ticks from the strike for a position with the given width and tickSpacing.
    /// @dev Given `r = (width * tickSpacing) / 2`, `tickLower = strike - floor(r)` and `tickUpper = strike + ceil(r)`.
    /// @param width The width of the leg
    /// @param tickSpacing The tick spacing of the underlying pool
    /// @return The distance of the lower tick from the strike
    /// @return The distance of the upper tick from the strike
    function getRangesFromStrike(
        int24 width,
        int24 tickSpacing
    ) internal pure returns (int24, int24) {
        return (
            (width * tickSpacing) / 2,
            int24(int256(Math.unsafeDivRoundingUp(uint24(width) * uint24(tickSpacing), 2)))
        );
    }

    /// @notice Computes the chunk key for a given leg of a position.
    /// @dev The chunk key uniquely identifies a liquidity chunk by its strike, width, and token type.
    /// @param tokenId The option position
    /// @param leg The leg index within the position
    /// @return chunkKey The keccak256 hash identifying this chunk
    function getChunkKey(TokenId tokenId, uint256 leg) internal pure returns (bytes32 chunkKey) {
        chunkKey = EfficientHash.efficientKeccak256(
            abi.encodePacked(tokenId.strike(leg), tokenId.width(leg), tokenId.tokenType(leg))
        );
    }

    /*//////////////////////////////////////////////////////////////
                         TOKEN CONVERSION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Compute the amount of notional value underlying an option position.
    /// @param tokenId The option position id
    /// @param positionSize The number of contracts of the option
    /// @param opening Whether you need the token0s and token1s moved while opening the position, or while closing
    /// @return longAmounts Left-right packed word where rightSlot = token0 and leftSlot = token1 held against borrowed Uniswap liquidity for long legs
    /// @return shortAmounts Left-right packed word where where rightSlot = token0 and leftSlot = token1 borrowed to create short legs
    function computeExercisedAmounts(
        TokenId tokenId,
        uint128 positionSize,
        bool opening
    ) internal pure returns (LeftRightSigned longAmounts, LeftRightSigned shortAmounts) {
        uint256 numLegs = tokenId.countLegs();
        for (uint256 leg = 0; leg < numLegs; ) {
            (LeftRightSigned longs, LeftRightSigned shorts) = calculateIOAmounts(
                tokenId,
                positionSize,
                leg,
                opening
            );

            longAmounts = longAmounts.add(longs);
            shortAmounts = shortAmounts.add(shorts);
            unchecked {
                ++leg;
            }
        }
    }

    /// @notice Convert an amount of token0 into an amount of token1 given the sqrtPriceX96 in a Uniswap pool defined as `sqrt(1/0)*2^96`.
    /// @dev Uses reduced precision after tick 443636 in order to accommodate the full range of ticks
    /// @param amount The amount of token0 to convert into token1
    /// @param sqrtPriceX96 The square root of the price at which to convert `amount` of token0 into token1
    /// @return The converted `amount` of token0 represented in terms of token1
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

    /// @notice Convert an amount of token0 into an amount of token1 given the sqrtPriceX96 in a Uniswap pool defined as `sqrt(1/0)*2^96`.
    /// @dev Uses reduced precision after tick 443636 in order to accommodate the full range of ticks
    /// @param amount The amount of token0 to convert into token1
    /// @param sqrtPriceX96 The square root of the price at which to convert `amount` of token0 into token1
    /// @return The converted `amount` of token0 represented in terms of token1
    function convert0to1RoundingUp(
        uint256 amount,
        uint160 sqrtPriceX96
    ) internal pure returns (uint256) {
        unchecked {
            // the tick 443636 is the maximum price where (price) * 2**192 fits into a uint256 (< 2**256-1)
            // above that tick, we are forced to reduce the amount of decimals in the final price by 2**64 to 2**128
            if (sqrtPriceX96 < type(uint128).max) {
                return Math.mulDiv192RoundingUp(amount, uint256(sqrtPriceX96) ** 2);
            } else {
                return Math.mulDiv128RoundingUp(amount, Math.mulDiv64(sqrtPriceX96, sqrtPriceX96));
            }
        }
    }

    /// @notice Convert an amount of token1 into an amount of token0 given the sqrtPriceX96 in a Uniswap pool defined as `sqrt(1/0)*2^96`.
    /// @dev Uses reduced precision after tick 443636 in order to accommodate the full range of ticks.
    /// @param amount The amount of token1 to convert into token0
    /// @param sqrtPriceX96 The square root of the price at which to convert `amount` of token1 into token0
    /// @return The converted `amount` of token1 represented in terms of token0
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

    /// @notice Convert an amount of token1 into an amount of token0 given the sqrtPriceX96 in a Uniswap pool defined as `sqrt(1/0)*2^96`.
    /// @dev Uses reduced precision after tick 443636 in order to accommodate the full range of ticks.
    /// @param amount The amount of token1 to convert into token0
    /// @param sqrtPriceX96 The square root of the price at which to convert `amount` of token1 into token0
    /// @return The converted `amount` of token1 represented in terms of token0
    function convert1to0RoundingUp(
        uint256 amount,
        uint160 sqrtPriceX96
    ) internal pure returns (uint256) {
        unchecked {
            // the tick 443636 is the maximum price where (price) * 2**192 fits into a uint256 (< 2**256-1)
            // above that tick, we are forced to reduce the amount of decimals in the final price by 2**64 to 2**128
            if (sqrtPriceX96 < type(uint128).max) {
                return Math.mulDivRoundingUp(amount, 2 ** 192, uint256(sqrtPriceX96) ** 2);
            } else {
                return
                    Math.mulDivRoundingUp(
                        amount,
                        2 ** 128,
                        Math.mulDiv64(sqrtPriceX96, sqrtPriceX96)
                    );
            }
        }
    }

    /// @notice Convert an amount of token0 into an amount of token1 given the sqrtPriceX96 in a Uniswap pool defined as `sqrt(1/0)*2^96`.
    /// @dev Uses reduced precision after tick 443636 in order to accommodate the full range of ticks.
    /// @param amount The amount of token0 to convert into token1
    /// @param sqrtPriceX96 The square root of the price at which to convert `amount` of token0 into token1
    /// @return The converted `amount` of token0 represented in terms of token1
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

    /// @notice Convert an amount of token0 into an amount of token1 given the sqrtPriceX96 in a Uniswap pool defined as `sqrt(1/0)*2^96`.
    /// @dev Uses reduced precision after tick 443636 in order to accommodate the full range of ticks.
    /// @param amount The amount of token0 to convert into token1
    /// @param sqrtPriceX96 The square root of the price at which to convert `amount` of token0 into token1
    /// @return The converted `amount` of token0 represented in terms of token1
    function convert0to1RoundingUp(
        int256 amount,
        uint160 sqrtPriceX96
    ) internal pure returns (int256) {
        unchecked {
            // the tick 443636 is the maximum price where (price) * 2**192 fits into a uint256 (< 2**256-1)
            // above that tick, we are forced to reduce the amount of decimals in the final price by 2**64 to 2**128
            if (sqrtPriceX96 < type(uint128).max) {
                int256 absResult = Math
                    .mulDiv192RoundingUp(Math.absUint(amount), uint256(sqrtPriceX96) ** 2)
                    .toInt256();
                return amount < 0 ? -absResult : absResult;
            } else {
                int256 absResult = Math
                    .mulDiv128RoundingUp(
                        Math.absUint(amount),
                        Math.mulDiv64(sqrtPriceX96, sqrtPriceX96)
                    )
                    .toInt256();
                return amount < 0 ? -absResult : absResult;
            }
        }
    }

    /// @notice Convert an amount of token1 into an amount of token0 given the sqrtPriceX96 in a Uniswap pool defined as `sqrt(1/0)*2^96`.
    /// @dev Uses reduced precision after tick 443636 in order to accommodate the full range of ticks.
    /// @param amount The amount of token1 to convert into token0
    /// @param sqrtPriceX96 The square root of the price at which to convert `amount` of token1 into token0
    /// @return The converted `amount` of token1 represented in terms of token0
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

    /// @notice Convert an amount of token1 into an amount of token0 given the sqrtPriceX96 in a Uniswap pool defined as `sqrt(1/0)*2^96`.
    /// @dev Uses reduced precision after tick 443636 in order to accommodate the full range of ticks.
    /// @param amount The amount of token1 to convert into token0
    /// @param sqrtPriceX96 The square root of the price at which to convert `amount` of token1 into token0
    /// @return The converted `amount` of token1 represented in terms of token0
    function convert1to0RoundingUp(
        int256 amount,
        uint160 sqrtPriceX96
    ) internal pure returns (int256) {
        unchecked {
            // the tick 443636 is the maximum price where (price) * 2**192 fits into a uint256 (< 2**256-1)
            // above that tick, we are forced to reduce the amount of decimals in the final price by 2**64 to 2**128
            if (sqrtPriceX96 < type(uint128).max) {
                int256 absResult = Math
                    .mulDivRoundingUp(Math.absUint(amount), 2 ** 192, uint256(sqrtPriceX96) ** 2)
                    .toInt256();
                return amount < 0 ? -absResult : absResult;
            } else {
                int256 absResult = Math
                    .mulDivRoundingUp(
                        Math.absUint(amount),
                        2 ** 128,
                        Math.mulDiv64(sqrtPriceX96, sqrtPriceX96)
                    )
                    .toInt256();
                return amount < 0 ? -absResult : absResult;
            }
        }
    }

    /// @notice Get a single collateral balance and requirement in terms of the lowest-priced token for a given set of (token0/token1) collateral balances and requirements.
    /// @param tokenData0 LeftRight encoded word with balance of token0 in the right slot, and required balance in left slot
    /// @param tokenData1 LeftRight encoded word with balance of token1 in the right slot, and required balance in left slot
    /// @param sqrtPriceX96 The price at which to compute the collateral value and requirements
    /// @return The combined collateral balance of `tokenData0` and `tokenData1` in terms of (token0 if `price(token1/token0) < 1` and vice versa)
    /// @return The combined required collateral threshold of `tokenData0` and `tokenData1` in terms of (token0 if `price(token1/token0) < 1` and vice versa)
    function getCrossBalances(
        LeftRightUnsigned tokenData0,
        LeftRightUnsigned tokenData1,
        uint160 sqrtPriceX96
    ) internal pure returns (uint256, uint256) {
        // convert values to the highest precision (lowest price) of the two tokens (token0 if price token1/token0 < 1 and vice versa)
        if (sqrtPriceX96 < Constants.FP96) {
            return (
                tokenData0.rightSlot() +
                    PanopticMath.convert1to0(tokenData1.rightSlot(), sqrtPriceX96),
                tokenData0.leftSlot() +
                    PanopticMath.convert1to0RoundingUp(tokenData1.leftSlot(), sqrtPriceX96)
            );
        }

        return (
            PanopticMath.convert0to1(tokenData0.rightSlot(), sqrtPriceX96) + tokenData1.rightSlot(),
            PanopticMath.convert0to1RoundingUp(tokenData0.leftSlot(), sqrtPriceX96) +
                tokenData1.leftSlot()
        );
    }

    /// @notice Compute the notional value (for `tokenType = 0` and `tokenType = 1`) represented by a given leg in an option position.
    /// @param tokenId The option position identifier
    /// @param positionSize The number of option contracts held in this position (each contract can control multiple tokens)
    /// @param legIndex The leg index of the option contract, can be {0,1,2,3}
    /// @param opening Whether this position is being opened or closed
    /// @return A LeftRight encoded variable containing the amount0 and the amount1 value controlled by this option position's leg
    function getAmountsMoved(
        TokenId tokenId,
        uint128 positionSize,
        uint256 legIndex,
        bool opening
    ) internal pure returns (LeftRightUnsigned) {
        uint128 amount0;
        uint128 amount1;

        bool hasWidth = tokenId.width(legIndex) != 0;
        // if the width is zero, add 1 to the width to allow liquidity amounts to be computes
        /// @dev this is just for accounting purposes, the actual tokenId will remain with a width = 0
        if (!hasWidth) {
            tokenId = tokenId.addWidth(2, legIndex);
        }

        LiquidityChunk liquidityChunk = getLiquidityChunk(tokenId, legIndex, positionSize);

        // Shorts round UP to ensure user pays enough (conservative for protocol)
        // Longs round DOWN to ensure user receives correct amount (conservative for protocol)
        if (
            (tokenId.isLong(legIndex) == 0 && opening) ||
            (tokenId.isLong(legIndex) != 0 && !opening) ||
            !hasWidth
        ) {
            amount0 = uint128(Math.getAmount0ForLiquidityUp(liquidityChunk));
            amount1 = uint128(Math.getAmount1ForLiquidityUp(liquidityChunk));
        } else {
            amount0 = uint128(Math.getAmount0ForLiquidity(liquidityChunk));
            amount1 = uint128(Math.getAmount1ForLiquidity(liquidityChunk));
        }
        return LeftRightUnsigned.wrap(amount0).addToLeftSlot(amount1);
    }

    /// @notice Compute the amount of funds that are moved to or removed from the Panoptic Pool when `tokenId` is created.
    /// @param tokenId The option position identifier
    /// @param positionSize The number of positions minted
    /// @param legIndex The leg index minted in this position, can be {0,1,2,3}
    /// @param opening Whether this position is being opened or closed
    /// @return longs A LeftRight-packed word containing the total amount of long positions
    /// @return shorts A LeftRight-packed word containing the amount of short positions
    function calculateIOAmounts(
        TokenId tokenId,
        uint128 positionSize,
        uint256 legIndex,
        bool opening
    ) internal pure returns (LeftRightSigned longs, LeftRightSigned shorts) {
        LeftRightUnsigned amountsMoved = getAmountsMoved(tokenId, positionSize, legIndex, opening);

        bool isShort = tokenId.isLong(legIndex) == 0;

        if (tokenId.tokenType(legIndex) == 0) {
            if (isShort) {
                // if option is short, increment shorts by contracts
                shorts = LeftRightSigned.wrap(0).addToRightSlot(
                    Math.toInt128(amountsMoved.rightSlot())
                );
            } else {
                // is option is long, increment longs by contracts
                longs = LeftRightSigned.wrap(0).addToRightSlot(
                    Math.toInt128(amountsMoved.rightSlot())
                );
            }
        } else {
            if (isShort) {
                // if option is short, increment shorts by notional
                shorts = LeftRightSigned.wrap(0).addToLeftSlot(
                    Math.toInt128(amountsMoved.leftSlot())
                );
            } else {
                // if option is long, increment longs by notional
                longs = LeftRightSigned.wrap(0).addToLeftSlot(
                    Math.toInt128(amountsMoved.leftSlot())
                );
            }
        }
    }
}
