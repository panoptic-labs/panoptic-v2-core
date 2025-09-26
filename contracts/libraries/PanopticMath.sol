// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
// Interfaces
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
// Libraries
import {Constants} from "@libraries/Constants.sol";
import {Math} from "@libraries/Math.sol";
// OpenZeppelin libraries
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
// Custom types
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {TokenId} from "@types/TokenId.sol";

/// @title Compute general math quantities relevant to Panoptic and AMM pool management.
/// @notice Contains Panoptic-specific helpers and math functions.
/// @author Axicon Labs Limited
library PanopticMath {
    using Math for uint256;

    /// @notice This is equivalent to `type(uint256).max` — used in assembly blocks as a replacement.
    uint256 internal constant MAX_UINT256 = 2 ** 256 - 1;

    /// @notice Masks 16-bit tickSpacing out of 64-bit `[16-bit tickspacing][48-bit poolPattern]` format poolId.
    uint64 internal constant TICKSPACING_MASK = 0xFFFF000000000000;

    uint256 internal constant UPPER_120BITS_MASK =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000000000000000000000000000;

    uint256 internal constant BITMASK_UINT88 = 0xFFFFFFFFFFFFFFFFFFFFFF;
    uint256 internal constant BITMASK_UINT22 = 0x3FFFFF;

    int256 constant EMA_PERIOD_10MINS = 600; // 600 seconds
    int256 constant EMA_PERIOD_1H = 3600; // 600 seconds
    int256 constant EMA_PERIOD_8H = 28800; // 600 seconds
    int256 constant EMA_PERIOD_1D = 86400; // 600 seconds

    /*//////////////////////////////////////////////////////////////
                              UTILITIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Given an address to a Uniswap V3 pool, return its 64-bit ID as used in the `TokenId` of Panoptic.
    // Example:
    //      the 64 bits are the 48 *last* (most significant) bits - and thus corresponds to the *first* 12 hex characters (reading left to right)
    //      of the Uniswap V3 pool address, with the tickSpacing written in the highest 16 bits (i.e, max tickSpacing is 32767)
    //      e.g.:
    //        univ3pool   = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8
    //        tickSpacing = 60
    //      the returned id is then:
    //        poolPattern = 0x00008ad599c3A0ff
    //        tickSpacing = 0x003c000000000000    +
    //        --------------------------------------------
    //        poolId      = 0x003c8ad599c3A0ff
    //
    /// @param univ3pool The address of the Uniswap V3 pool to get the ID of
    /// @param tickSpacing The tick spacing of `univ3pool`
    /// @return A uint64 representing a fingerprint of the Uniswap V3 pool address
    function getPoolId(address univ3pool, int24 tickSpacing) internal pure returns (uint64) {
        unchecked {
            uint64 poolId = uint64(uint160(univ3pool) >> 112);
            poolId += uint64(uint24(tickSpacing)) << 48;
            return poolId;
        }
    }

    /// @notice Increments the pool pattern (first 48 bits) of a poolId by 1.
    /// @param poolId The 64-bit pool ID
    /// @return The provided `poolId` with its pool pattern slot incremented by 1
    function incrementPoolPattern(uint64 poolId) internal pure returns (uint64) {
        unchecked {
            return (poolId & TICKSPACING_MASK) + (uint48(poolId) + 1);
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
        // update hash by taking the XOR of the existing hash with the new tokenId
        uint256 updatedHash = uint248(existingHash) ^
            (uint248(uint256(keccak256(abi.encode(tokenId)))));

        // increment the upper 8 bits (leg counter) if addFlag=true, decrement otherwise
        uint256 newLegCount = addFlag
            ? uint8(existingHash >> 248) + uint8(tokenId.countLegs())
            : uint8(existingHash >> 248) - tokenId.countLegs();

        unchecked {
            return uint256(updatedHash) + (newLegCount << 248);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          ORACLE CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Computes various oracle prices corresponding to a Uniswap pool.
    /// @param univ3pool The Uniswap pool to get the observations from
    /// @param miniMedian The packed structure representing the sorted 8-slot queue of internal median observations
    /// @return currentTick The current tick in the Uniswap pool
    /// @return fastOracleTick The fast oracle tick computed as the median of the past N observations in the Uniswap Pool
    /// @return slowOracleTick The slow oracle tick computed with the method specified in `SLOW_ORACLE_UNISWAP_MODE`
    /// @return latestObservation The latest observation from the Uniswap pool (price at the end of the last block)
    /// @return medianData The updated value for `s_miniMedian` (0 if not enough time has passed since last observation or if `SLOW_ORACLE_UNISWAP_MODE` is true)
    function getOracleTicks(
        IUniswapV3Pool univ3pool,
        uint256 miniMedian
    )
        external
        view
        returns (
            int24 currentTick,
            int24 fastOracleTick,
            int24 slowOracleTick,
            int24 latestObservation,
            uint256 medianData
        )
    {
        (, currentTick, , , , , ) = univ3pool.slot0();

        (slowOracleTick, medianData) = computeInternalMedian(miniMedian, currentTick);

        // Extract the 10-minute EMA from the lowest 22 bits of the packed EMAs value and assign it as the fast oracle price.
        uint256 EMAs = (medianData >> 120) & BITMASK_UINT88;
        fastOracleTick = int22toInt24(EMAs & BITMASK_UINT22);

        // Reconstruct the absolute tick of the last observation by adding the reference tick (bits 96-119) to the latest residual (bits 0-11).
        latestObservation = int24(uint24(medianData >> 96)) + int12toInt24(medianData % 2 ** 12);
    }

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

            // get the median of the `ticks` array (assuming `cardinality` is odd)
            return (int24(Math.sort(ticks)[cardinality / 2]), int24(ticks[0]));
        }
    }

    /// @notice Converts a 12-bit signed integer to a 24-bit signed integer with proper sign extension
    /// @dev Handles two's complement sign extension for 12-bit values stored in larger integer types
    /// @dev The function checks bit 11 (the sign bit for 12-bit integers) and extends the sign
    /// @dev if the number is negative by setting bits 12-15 to 1
    /// @param x The input value containing a 12-bit signed integer in its lower 12 bits
    /// @return The sign-extended 24-bit signed integer (as int24)
    function int12toInt24(uint256 x) internal pure returns (int24) {
        unchecked {
            // Extract only the lower 12 bits
            uint16 u = uint16(x & 0x0FFF);

            // Check if bit 11 is set
            // This is the sign bit for a 12-bit signed integer
            if ((u & 0x0800) != 0) {
                // Number is negative, extend the sign by setting bits 12-15 to 1
                u |= 0xF000;
            }
            return int24(int16(u));
        }
    }

    /// @notice Converts a 22-bit signed integer to a 24-bit signed integer with proper sign extension
    /// @dev Handles two's complement sign extension for 22-bit values stored in larger integer types
    /// @dev The function checks bit 21 (the sign bit for 22-bit integers) and extends the sign
    /// @dev if the number is negative by setting bits 22-31 to 1
    /// @param x The input value containing a 22-bit signed integer in its lower 22 bits
    /// @return The sign-extended 24-bit signed integer (as int24)
    function int22toInt24(uint256 x) internal pure returns (int24) {
        unchecked {
            // Extract only the lower 22 bits
            uint32 u = uint32(x & BITMASK_UINT22);

            // Check if bit 21 is set
            // This is the sign bit for a 22-bit signed integer
            if ((u & 0x200000) != 0) {
                // Number is negative, extend the sign by setting bits 22-31 to 1
                u |= 0xFFC00000;
            }
            return int24(int32(u));
        }
    }

    /// @notice Takes a packed structure representing a sorted 8-slot queue of ticks and returns the median of those values and an updated queue if another observation is warranted.
    /// @dev Also inserts the latest Uniswap observation into the buffer, resorts, and returns if the last entry is at least `period` seconds old.
    /// @param medianData The packed structure representing the sorted 8-slot queue of ticks
    /// @param currentTick The current tick as return from slot0
    /// @return medianTick The median of the provided 8-slot queue of ticks in `medianData`
    /// @return updatedMedianData The updated 8-slot queue of ticks with the latest observation inserted if the last entry is at least `period` seconds old (returns 0 otherwise)
    function computeInternalMedian(
        uint256 medianData,
        int24 currentTick
    ) public view returns (int24 medianTick, uint256 updatedMedianData) {
        unchecked {
            // return the average of the rank 3 and 4 values
            medianTick = getMedianTick(medianData);

            uint256 currentEpoch;
            bool differentEpoch;
            int256 timeDelta;
            {
                currentEpoch = (block.timestamp >> 6) & 0xFFFFFF; // mod 2**24
                uint256 recordedEpoch = medianData >> 232;
                differentEpoch = currentEpoch != recordedEpoch;
                timeDelta = int256((currentEpoch - recordedEpoch) * 64);
            }

            // only proceed if last entry is in a different epoch (takes care of looping edge case in a way that ">" doesn't)
            if (differentEpoch) {
                int24 clampedTick = clampTick(currentTick, medianData);
                updatedMedianData = insertObservation(
                    medianData,
                    clampedTick,
                    currentEpoch,
                    timeDelta
                );
            }
        }
    }

    /// @notice Inserts a new tick observation into the median data structure and updates EMAs
    /// @dev Updates the sorted queue by finding the correct insertion point for the new tick residual
    /// @dev The function maintains an 8-slot sorted queue using a 24-bit order map where each 3-bit segment
    /// @dev represents the rank of the corresponding slot. Slot 7 is reserved for the new observation.
    /// @param medianData The current packed median data structure containing:
    ///                   - Bits 255-232: Current epoch timestamp
    ///                   - Bits 231-208: 24-bit order map (8 slots × 3 bits each)
    ///                   - Bits 207-128: Reserved for EMA data (88 bits): 10mins, 1hour, 8hour and 1day
    ///                   - Bits 127-96:  Reference tick (24 bits)
    ///                   - Bits 95-12:   Previous observations as 12-bit residuals (84 bits)
    ///                   - Bits 11-0:    Most recent observation residual (12 bits)
    /// @param newTick The new tick observation to insert (as a residual relative to reference tick)
    /// @param currentEpoch The current epoch timestamp ((block.timestamp >> 6) & 0xFFFFFF)
    /// @param timeDelta Time difference in seconds between current and last epoch (currentEpoch - recordedEpoch) * 64
    /// @return updatedMedianData The updated packed median data structure with the new observation inserted
    function insertObservation(
        uint256 medianData,
        int24 newTick,
        uint256 currentEpoch,
        int256 timeDelta
    ) internal pure returns (uint256 updatedMedianData) {
        unchecked {
            int24 referenceTick = int24(uint24(medianData >> 96));
            int24 lastResidual = newTick - referenceTick;

            if (
                (lastResidual > Constants.MAX_RESIDUAL_THRESHOLD) ||
                (lastResidual < -Constants.MAX_RESIDUAL_THRESHOLD)
            ) {
                (referenceTick, medianData) = rebaseMedianData(medianData);
                lastResidual = newTick - referenceTick;
            }

            uint24 orderMap = uint24(medianData >> 208);

            uint24 newOrderMap;
            {
                uint24 shift = 1;
                bool below = true;
                uint24 rank;
                int24 entry;
                for (uint8 i; i < 8; ++i) {
                    // read the rank from the existing ordering
                    rank = (orderMap >> (3 * i)) & 7; // mod 2**3

                    if (rank == 7) {
                        shift -= 1;
                        continue;
                    }

                    // read the corresponding entry
                    entry = int12toInt24((medianData >> (rank * 12)) & 0x0FFF); // mod 2**12
                    if ((below) && (lastResidual > entry)) {
                        shift += 1;
                        below = false;
                    }

                    newOrderMap = newOrderMap + ((rank + 1) << (3 * (i + shift - 1)));
                }
            }

            uint256 EMAs = updateEMAs(medianData, timeDelta, newTick);

            updatedMedianData =
                (currentEpoch << 232) +
                (uint256(newOrderMap) << 208) +
                (EMAs << 120) +
                (uint256(uint24(referenceTick)) << 96) +
                uint256(uint96(medianData << 12)) +
                uint256(uint16(uint24(lastResidual) & 0x0FFF));
        }
    }

    /// @notice Calculates the median tick from a packed median data structure
    /// @dev Retrieves the 3rd and 4th ranked values from the sorted 8-slot queue and returns their average
    /// @dev The median is calculated as: referenceTick + (rank3_residual + rank4_residual) / 2
    /// @param medianData The packed structure containing:
    ///                   - Order map indicating the rank of each slot
    ///                   - Reference tick for absolute positioning
    ///                   - 8 tick observations stored as 12-bit signed residuals relative to reference tick
    /// @return medianTick The median tick value, representing the middle value of the sorted observations
    function getMedianTick(uint256 medianData) internal pure returns (int24) {
        int24 rank3 = int12toInt24(
            uint256(medianData >> ((uint24(medianData >> (208 + 3 * 3)) % 8) * 12)) & 0x0FFF
        );
        int24 rank4 = int12toInt24(
            uint256(medianData >> ((uint24(medianData >> (208 + 3 * 4)) % 8) * 12)) & 0x0FFF
        );
        int24 referenceTick = int24(uint24(medianData >> 96));
        return referenceTick + ((rank3) + (rank4)) / 2;
    }

    /// @notice Clamps a new tick observation to prevent large price movements that could manipulate the median
    /// @dev Limits the new tick to be within MAX_MEDIAN_DELTA of the most recent tick observation
    /// @dev This prevents flash loan attacks or other price manipulation attempts from skewing the median calculation
    /// @param newTick The new tick observation from Uniswap TWAP that needs to be clamped
    /// @param _medianData The current median data structure containing the reference tick and most recent observation
    /// @return clamped The clamped tick value, guaranteed to be within MAX_MEDIAN_DELTA of the last observation
    function clampTick(int24 newTick, uint256 _medianData) private pure returns (int24 clamped) {
        unchecked {
            int24 refTick = int24(uint24(_medianData >> 96));
            // Clamp lastObservedTick to be within MAX_MEDIAN_DELTA of lastTick
            int24 lastTick = refTick + int12toInt24(_medianData & 0x0FFF); // mod 2**12
            //int24 lastTick = int24(uint24(medianData));
            int24 maxDelta = Constants.MAX_MEDIAN_DELTA;
            if (newTick > lastTick + maxDelta) {
                clamped = lastTick + maxDelta;
            } else if (newTick < lastTick - maxDelta) {
                clamped = lastTick - maxDelta;
            } else {
                clamped = newTick;
            }
        }
    }

    /// @notice Rebases the median data structure when tick residuals exceed the 12-bit signed integer range
    /// @dev When residuals become too large (>2047 or <-2048), this function shifts the reference tick
    /// @dev to the current median and adjusts all stored residuals relative to the new reference
    /// @dev This maintains precision while keeping residuals within the 12-bit storage constraint
    /// @param data The current median data structure with residuals that have exceeded the threshold
    /// @return newReferenceTick The new reference tick (set to the current median)
    /// @return rebasedData The updated median data structure with:
    ///                     - New reference tick set to the current median
    ///                     - All residuals recalculated relative to the new reference
    ///                     - All other data (order map, EMAs, epoch) preserved
    function rebaseMedianData(
        uint256 data
    ) internal pure returns (int24 newReferenceTick, uint256 rebasedData) {
        int24 referenceTick = int24(uint24(data >> 96));

        newReferenceTick = getMedianTick(data);
        int24 deltaOffset = newReferenceTick - referenceTick;

        uint256 offsetData;
        for (uint8 i; i < 8; ++i) {
            int24 newEntry = int12toInt24((data >> (i * 12)) & 0x0FFF) - deltaOffset;
            offsetData += (uint256(uint16(uint24(newEntry) & 0x0FFF)) & 0x0FFF) << (i * 12);
        }

        rebasedData =
            (data & UPPER_120BITS_MASK) +
            (uint256(uint24(newReferenceTick)) << 96) +
            offsetData;
    }

    /// @notice Updates exponential moving averages (EMAs) at multiple timescales with a new tick observation
    /// @dev Implements a cascading time delta cap to prevent excessive convergence after periods of inactivity
    /// @dev EMAs converge at most 75% toward the new tick value using linear approximation: exp(-x) ≈ 1-x
    /// @dev The function modifies timeDelta in cascade: longer periods cap it first, affecting shorter periods
    /// @param medianData The packed median data containing current EMA values in bits 207-120
    /// @param timeDelta Time elapsed since last update in seconds (will be modified by cascading caps)
    /// @param newTick The new tick observation to update EMAs toward
    /// @return updatedEMAs The packed 88-bit value containing all four updated EMAs
    function updateEMAs(
        uint256 medianData,
        int256 timeDelta,
        int24 newTick
    ) internal pure returns (uint256 updatedEMAs) {
        unchecked {
            // Extract current EMAs from medianData (88 bits starting at bit 120)
            uint256 EMAs = (medianData >> 120) & BITMASK_UINT88;

            // Update 1-day EMA (bits 87-66)
            int24 EMA1D = int22toInt24((EMAs >> 66) & BITMASK_UINT22);
            if (timeDelta > (3 * EMA_PERIOD_1D) / 4) timeDelta = (3 * EMA_PERIOD_1D) / 4;
            EMA1D = int24(EMA1D + (timeDelta * (newTick - EMA1D)) / EMA_PERIOD_1D);

            // Update 8-hour EMA (bits 65-44)
            int24 EMA8H = int22toInt24((EMAs >> 44) & BITMASK_UINT22);
            if (timeDelta > (3 * EMA_PERIOD_8H) / 4) timeDelta = (3 * EMA_PERIOD_8H) / 4;
            EMA8H = int24(EMA8H + (timeDelta * (newTick - EMA8H)) / EMA_PERIOD_8H);

            // Update 1-hour EMA (bits 43-22)
            int24 EMA1H = int22toInt24((EMAs >> 22) & BITMASK_UINT22);
            if (timeDelta > (3 * EMA_PERIOD_1H) / 4) timeDelta = (3 * EMA_PERIOD_1H) / 4;
            EMA1H = int24(EMA1H + (timeDelta * (newTick - EMA1H)) / EMA_PERIOD_1H);

            // Update 10-minute EMA (bits 21-0)
            int24 EMA10m = int22toInt24(EMAs & BITMASK_UINT22);
            if (timeDelta > (3 * EMA_PERIOD_10MINS) / 4) timeDelta = (3 * EMA_PERIOD_10MINS) / 4;
            EMA10m = int24(EMA10m + (timeDelta * (newTick - EMA10m)) / EMA_PERIOD_10MINS);

            // Pack updated EMAs back into 88-bit format
            updatedEMAs =
                (uint256(uint24(EMA10m)) & BITMASK_UINT22) +
                ((uint256(uint24(EMA1H)) & BITMASK_UINT22) << 22) +
                ((uint256(uint24(EMA8H)) & BITMASK_UINT22) << 44) +
                ((uint256(uint24(EMA1D)) & BITMASK_UINT22) << 66);
        }
    }

    /// @notice Calculates a slow-moving, weighted average price from the on-chain EMAs.
    /// @dev Extracts the 1-hour, 8-hour, and 1-day EMA tick values from the packed `medianData`
    /// structure. It then computes and returns a blended average with a 60/30/10 weighting
    /// respectively. This heavily smoothed value is designed to be highly resistant to
    /// manipulation and serves as a robust price feed for critical system functions like solvency checks.
    /// @param medianData The packed `s_miniMedian` storage slot containing the oracle's state,
    /// including the on-chain EMAs.
    /// @return The blended time-weighted average price, represented as an int24 tick.
    function twapEMA(uint256 medianData) external pure returns (int24) {
        // Extract current EMAs from medianData
        (int24 EMA1D, int24 EMA8H, int24 EMA1H, ) = getEMAs(medianData);

        return (6 * EMA1H + 3 * EMA8H + EMA1D) / 10;
    }

    function getEMAs(
        uint256 medianData
    ) internal pure returns (int24 EMA1D, int24 EMA8H, int24 EMA1H, int24 EMA10m) {
        uint256 EMAs = (medianData >> 120) & BITMASK_UINT88;
        EMA1D = int22toInt24((EMAs >> 66) & BITMASK_UINT22);
        EMA8H = int22toInt24((EMAs >> 44) & BITMASK_UINT22);
        EMA1H = int22toInt24((EMAs >> 22) & BITMASK_UINT22);
        EMA10m = int22toInt24(EMAs & BITMASK_UINT22);
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

        uint256 amount = uint256(positionSize) * tokenId.optionRatio(legIndex);
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

    /*//////////////////////////////////////////////////////////////
                         TOKEN CONVERSION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Compute the amount of notional value underlying an option position.
    /// @param tokenId The option position id
    /// @param positionSize The number of contracts of the option
    /// @return longAmounts Left-right packed word where rightSlot = token0 and leftSlot = token1 held against borrowed Uniswap liquidity for long legs
    /// @return shortAmounts Left-right packed word where where rightSlot = token0 and leftSlot = token1 borrowed to create short legs
    function computeExercisedAmounts(
        TokenId tokenId,
        uint128 positionSize
    ) internal pure returns (LeftRightSigned longAmounts, LeftRightSigned shortAmounts) {
        uint256 numLegs = tokenId.countLegs();
        for (uint256 leg = 0; leg < numLegs; ) {
            (LeftRightSigned longs, LeftRightSigned shorts) = _calculateIOAmounts(
                tokenId,
                positionSize,
                leg
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
    /// @return A LeftRight encoded variable containing the amount0 and the amount1 value controlled by this option position's leg
    function getAmountsMoved(
        TokenId tokenId,
        uint128 positionSize,
        uint256 legIndex
    ) internal pure returns (LeftRightUnsigned) {
        uint128 amount0;
        uint128 amount1;

        (int24 tickLower, int24 tickUpper) = tokenId.asTicks(legIndex);

        // effective strike price of the option (avg. price over LP range)
        // geometric mean of two numbers = √(x1 * x2) = √x1 * √x2
        uint256 geometricMeanPriceX96 = Math.mulDiv96(
            Math.getSqrtRatioAtTick(tickLower),
            Math.getSqrtRatioAtTick(tickUpper)
        );

        if (tokenId.asset(legIndex) == 0) {
            amount0 = positionSize * uint128(tokenId.optionRatio(legIndex));
            amount1 = Math.mulDiv96RoundingUp(amount0, geometricMeanPriceX96).toUint128();
        } else {
            amount1 = positionSize * uint128(tokenId.optionRatio(legIndex));
            amount0 = Math.mulDivRoundingUp(amount1, 2 ** 96, geometricMeanPriceX96).toUint128();
        }

        return LeftRightUnsigned.wrap(amount0).toLeftSlot(amount1);
    }

    /// @notice Compute the amount of funds that are moved to or removed from the Panoptic Pool when `tokenId` is created.
    /// @param tokenId The option position identifier
    /// @param positionSize The number of positions minted
    /// @param legIndex The leg index minted in this position, can be {0,1,2,3}
    /// @return longs A LeftRight-packed word containing the total amount of long positions
    /// @return shorts A LeftRight-packed word containing the amount of short positions
    function _calculateIOAmounts(
        TokenId tokenId,
        uint128 positionSize,
        uint256 legIndex
    ) internal pure returns (LeftRightSigned longs, LeftRightSigned shorts) {
        LeftRightUnsigned amountsMoved = getAmountsMoved(tokenId, positionSize, legIndex);

        bool isShort = tokenId.isLong(legIndex) == 0;

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

    /*//////////////////////////////////////////////////////////////
                LIQUIDATION/FORCE EXERCISE CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Compute the pre-haircut liquidation bonuses to be paid to the liquidator and the protocol loss caused by the liquidation (pre-haircut).
    /// @param tokenData0 LeftRight encoded word with balance of token0 in the right slot, and required balance in left slot
    /// @param tokenData1 LeftRight encoded word with balance of token1 in the right slot, and required balance in left slot
    /// @param atSqrtPriceX96 The oracle price used to swap tokens between the liquidator/liquidatee and determine solvency for the liquidatee
    /// @param netPaid The net amount of tokens paid/received by the liquidatee to close their portfolio of positions
    /// @param shortPremium Total owed premium (prorated by available settled tokens) across all short legs being liquidated
    /// @return The LeftRight-packed bonus amounts to be paid to the liquidator for both tokens (may be negative)
    /// @return The LeftRight-packed protocol loss (pre-haircut) for both tokens, i.e., the delta between the user's starting balance and expended tokens
    function getLiquidationBonus(
        LeftRightUnsigned tokenData0,
        LeftRightUnsigned tokenData1,
        uint160 atSqrtPriceX96,
        LeftRightSigned netPaid,
        LeftRightUnsigned shortPremium
    ) external pure returns (LeftRightSigned, LeftRightSigned) {
        int256 bonus0;
        int256 bonus1;
        unchecked {
            // compute bonus as min(collateralBalance/2, required-collateralBalance)
            {
                // compute the ratio of token0 to total collateral requirements
                // evaluate at TWAP price to maintain consistency with solvency calculations
                (uint256 balanceCross, uint256 thresholdCross) = PanopticMath.getCrossBalances(
                    tokenData0,
                    tokenData1,
                    atSqrtPriceX96
                );

                uint256 bonusCross = Math.min(balanceCross / 2, thresholdCross - balanceCross);

                // `bonusCross` and `thresholdCross` are returned in terms of the lowest-priced token
                if (atSqrtPriceX96 < Constants.FP96) {
                    // required0 / (required0 + token0(required1))
                    uint256 requiredRatioX128 = Math.mulDiv(
                        tokenData0.leftSlot(),
                        2 ** 128,
                        thresholdCross
                    );

                    bonus0 = int256(Math.mulDiv128(bonusCross, requiredRatioX128));

                    bonus1 = int256(
                        PanopticMath.convert0to1(
                            Math.mulDiv128(bonusCross, 2 ** 128 - requiredRatioX128),
                            atSqrtPriceX96
                        )
                    );
                } else {
                    // required1 / (token1(required0) + required1)
                    uint256 requiredRatioX128 = Math.mulDiv(
                        tokenData1.leftSlot(),
                        2 ** 128,
                        thresholdCross
                    );

                    bonus1 = int256(Math.mulDiv128(bonusCross, requiredRatioX128));

                    bonus0 = int256(
                        PanopticMath.convert1to0(
                            Math.mulDiv128(bonusCross, 2 ** 128 - requiredRatioX128),
                            atSqrtPriceX96
                        )
                    );
                }
            }

            // negative premium (owed to the liquidatee) is credited to the collateral balance
            // this is already present in the netPaid amount, so to avoid double-counting we remove it from the balance
            int256 balance0 = int256(uint256(tokenData0.rightSlot())) -
                int256(uint256(shortPremium.rightSlot()));
            int256 balance1 = int256(uint256(tokenData1.rightSlot())) -
                int256(uint256(shortPremium.leftSlot()));

            int256 paid0 = bonus0 + int256(netPaid.rightSlot());
            int256 paid1 = bonus1 + int256(netPaid.leftSlot());

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
                        PanopticMath.convert0to1(paid0 - balance0, atSqrtPriceX96)
                    );
                    bonus0 -= Math.min(
                        PanopticMath.convert1to0(balance1 - paid1, atSqrtPriceX96),
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
                        PanopticMath.convert1to0(paid1 - balance1, atSqrtPriceX96)
                    );
                    bonus1 -= Math.min(
                        PanopticMath.convert0to1(balance0 - paid0, atSqrtPriceX96),
                        paid1 - balance1
                    );
                }
            }

            paid0 = bonus0 + int256(netPaid.rightSlot());
            paid1 = bonus1 + int256(netPaid.leftSlot());
            return (
                LeftRightSigned.wrap(0).toRightSlot(int128(bonus0)).toLeftSlot(int128(bonus1)),
                LeftRightSigned.wrap(0).toRightSlot(int128(balance0 - paid0)).toLeftSlot(
                    int128(balance1 - paid1)
                )
            );
        }
    }

    /// @notice Haircut/clawback any premium paid by `liquidatee` on `positionIdList` over the protocol loss threshold during a liquidation.
    /// @dev Note that the storage mapping provided as the `settledTokens` parameter WILL be modified on the caller by this function.
    /// @param liquidatee The address of the user being liquidated
    /// @param positionIdList The list of position ids being liquidated
    /// @param premiasByLeg The premium paid (or received) by the liquidatee for each leg of each position
    /// @param collateralRemaining The remaining collateral after the liquidation (negative if protocol loss)
    /// @param atSqrtPriceX96 The oracle price used to swap tokens between the liquidator/liquidatee and determine solvency for the liquidatee
    /// @param collateral0 The collateral tracker for token0
    /// @param collateral1 The collateral tracker for token1
    /// @param settledTokens The per-chunk accumulator of settled tokens in storage from which to subtract the haircut premium
    /// @return The delta, if any, to apply to the existing liquidation bonus
    function haircutPremia(
        address liquidatee,
        TokenId[] memory positionIdList,
        LeftRightSigned[4][] memory premiasByLeg,
        LeftRightSigned collateralRemaining,
        CollateralTracker collateral0,
        CollateralTracker collateral1,
        uint160 atSqrtPriceX96,
        mapping(bytes32 chunkKey => LeftRightUnsigned settledTokens) storage settledTokens
    ) external returns (LeftRightSigned) {
        unchecked {
            // get the amount of premium paid by the liquidatee
            LeftRightSigned longPremium;
            for (uint256 i = 0; i < positionIdList.length; ++i) {
                TokenId tokenId = positionIdList[i];
                uint256 numLegs = tokenId.countLegs();
                for (uint256 leg = 0; leg < numLegs; ++leg) {
                    if (tokenId.isLong(leg) == 1) {
                        longPremium = longPremium.sub(premiasByLeg[i][leg]);
                    }
                }
            }
            // Ignore any surplus collateral - the liquidatee is either solvent or it converts to <1 unit of the other token
            int256 collateralDelta0 = -Math.min(collateralRemaining.rightSlot(), 0);
            int256 collateralDelta1 = -Math.min(collateralRemaining.leftSlot(), 0);
            LeftRightSigned haircutBase;

            // if the premium in the same token is not enough to cover the loss and there is a surplus of the other token,
            // the liquidator will provide the tokens (reflected in the bonus amount) & receive compensation in the other token
            if (
                longPremium.rightSlot() < collateralDelta0 &&
                longPremium.leftSlot() > collateralDelta1
            ) {
                int256 protocolLoss1 = collateralDelta1;
                (collateralDelta0, collateralDelta1) = (
                    -Math.min(
                        collateralDelta0 - longPremium.rightSlot(),
                        PanopticMath.convert1to0(
                            longPremium.leftSlot() - collateralDelta1,
                            atSqrtPriceX96
                        )
                    ),
                    Math.min(
                        longPremium.leftSlot() - collateralDelta1,
                        PanopticMath.convert0to1(
                            collateralDelta0 - longPremium.rightSlot(),
                            atSqrtPriceX96
                        )
                    )
                );

                // It is assumed the sum of `protocolLoss1` and `collateralDelta1` does not exceed `2^127 - 1` given practical constraints
                // on token supplies and deposit limits
                haircutBase = LeftRightSigned.wrap(longPremium.rightSlot()).toLeftSlot(
                    int128(protocolLoss1 + collateralDelta1)
                );
            } else if (
                longPremium.leftSlot() < collateralDelta1 &&
                longPremium.rightSlot() > collateralDelta0
            ) {
                int256 protocolLoss0 = collateralDelta0;
                (collateralDelta0, collateralDelta1) = (
                    Math.min(
                        longPremium.rightSlot() - collateralDelta0,
                        PanopticMath.convert1to0(
                            collateralDelta1 - longPremium.leftSlot(),
                            atSqrtPriceX96
                        )
                    ),
                    -Math.min(
                        collateralDelta1 - longPremium.leftSlot(),
                        PanopticMath.convert0to1(
                            longPremium.rightSlot() - collateralDelta0,
                            atSqrtPriceX96
                        )
                    )
                );

                // It is assumed the sum of `protocolLoss0` and `collateralDelta0` does not exceed `2^127 - 1` given practical constraints
                // on token supplies and deposit limits
                haircutBase = LeftRightSigned
                    .wrap(int128(protocolLoss0 + collateralDelta0))
                    .toLeftSlot(longPremium.leftSlot());
            } else {
                // for each token, haircut until the protocol loss is mitigated or the premium paid is exhausted
                // the size of `collateralDelta0/1` and `longPremium.rightSlot()/leftSlot()` is limited to `2^127 - 1` given that they originate from LeftRightSigned types
                haircutBase = LeftRightSigned
                    .wrap(int128(Math.min(collateralDelta0, longPremium.rightSlot())))
                    .toLeftSlot(int128(Math.min(collateralDelta1, longPremium.leftSlot())));

                collateralDelta0 = 0;
                collateralDelta1 = 0;
            }

            // total haircut after rounding up prorated haircut amounts for each leg
            LeftRightUnsigned haircutTotal;
            address _liquidatee = liquidatee;
            for (uint256 i = 0; i < positionIdList.length; i++) {
                TokenId tokenId = positionIdList[i];
                LeftRightSigned[4][] memory _premiasByLeg = premiasByLeg;
                for (uint256 leg = 0; leg < tokenId.countLegs(); ++leg) {
                    if (
                        tokenId.isLong(leg) == 1 &&
                        LeftRightSigned.unwrap(_premiasByLeg[i][leg]) != 0
                    ) {
                        // calculate prorated (by target/liquidity) haircut amounts to revoke from settled for each leg
                        // `-premiasByLeg[i][leg]` (and `longPremium` which is the sum of all -premiasByLeg[i][leg]`) is always positive because long premium is represented as a negative delta
                        // `haircutBase` is always positive because all of its possible constituent values (`collateralDelta`, `longPremium`) are guaranteed to be positive
                        // the sum of all prorated haircut amounts for each token is assumed to be less than `2^127 - 1` given practical constraints on token supplies and deposit limits

                        LeftRightSigned haircutAmounts = LeftRightSigned
                            .wrap(
                                int128(
                                    uint128(
                                        Math.unsafeDivRoundingUp(
                                            uint128(-_premiasByLeg[i][leg].rightSlot()) *
                                                uint256(uint128(haircutBase.rightSlot())),
                                            uint128(longPremium.rightSlot())
                                        )
                                    )
                                )
                            )
                            .toLeftSlot(
                                int128(
                                    uint128(
                                        Math.unsafeDivRoundingUp(
                                            uint128(-_premiasByLeg[i][leg].leftSlot()) *
                                                uint256(uint128(haircutBase.leftSlot())),
                                            uint128(longPremium.leftSlot())
                                        )
                                    )
                                )
                            );

                        haircutTotal = haircutTotal.add(
                            LeftRightUnsigned.wrap(uint256(LeftRightSigned.unwrap(haircutAmounts)))
                        );

                        emit PanopticPool.PremiumSettled(
                            _liquidatee,
                            tokenId,
                            leg,
                            LeftRightSigned.wrap(0).sub(haircutAmounts)
                        );

                        bytes32 chunkKey = keccak256(
                            abi.encodePacked(
                                tokenId.strike(leg),
                                tokenId.width(leg),
                                tokenId.tokenType(leg)
                            )
                        );

                        // The long premium is not committed to storage during the liquidation, so we add the entire adjusted amount
                        // for the haircut directly to the accumulator
                        settledTokens[chunkKey] = settledTokens[chunkKey].add(
                            (LeftRightSigned.wrap(0).sub(_premiasByLeg[i][leg])).subRect(
                                haircutAmounts
                            )
                        );
                    }
                }
            }

            if (haircutTotal.rightSlot() != 0)
                collateral0.exercise(_liquidatee, 0, 0, 0, int128(haircutTotal.rightSlot()));
            if (haircutTotal.leftSlot() != 0)
                collateral1.exercise(_liquidatee, 0, 0, 0, int128(haircutTotal.leftSlot()));

            return
                LeftRightSigned.wrap(0).toRightSlot(int128(collateralDelta0)).toLeftSlot(
                    int128(collateralDelta1)
                );
        }
    }

    /// @notice Redistribute the final exercise fee deltas between tokens if necessary according to the available collateral from the exercised user.
    /// @param exercisee The address of the user being exercised
    /// @param exerciseFees Pre-adjustment exercise fees to debit from exercisor (rightSlot = token0 left = token1)
    /// @param atTick The tick at which to convert between token0/token1 when redistributing the exercise fees
    /// @param ct0 The collateral tracker for token0
    /// @param ct1 The collateral tracker for token1
    /// @return The LeftRight-packed deltas for token0/token1 to move from the exercisor to the exercisee
    function getExerciseDeltas(
        address exercisee,
        LeftRightSigned exerciseFees,
        int24 atTick,
        CollateralTracker ct0,
        CollateralTracker ct1
    ) external view returns (LeftRightSigned) {
        uint160 sqrtPriceX96 = Math.getSqrtRatioAtTick(atTick);
        unchecked {
            // if the refunder lacks sufficient token0 to pay back the virtual shares, have the exercisor cover the difference in exchange for token1 (and vice versa)

            int256 balanceShortage = int256(uint256(type(uint248).max)) -
                int256(ct0.balanceOf(exercisee)) -
                int256(ct0.convertToShares(uint128(-exerciseFees.rightSlot())));

            if (balanceShortage > 0) {
                return
                    LeftRightSigned
                        .wrap(0)
                        .toRightSlot(
                            int128(
                                exerciseFees.rightSlot() -
                                    int256(
                                        Math.mulDivRoundingUp(
                                            uint256(balanceShortage),
                                            ct0.totalAssets(),
                                            ct0.totalSupply()
                                        )
                                    )
                            )
                        )
                        .toLeftSlot(
                            int128(
                                int256(
                                    PanopticMath.convert0to1(
                                        ct0.convertToAssets(uint256(balanceShortage)),
                                        sqrtPriceX96
                                    )
                                ) + exerciseFees.leftSlot()
                            )
                        );
            }

            balanceShortage =
                int256(uint256(type(uint248).max)) -
                int256(ct1.balanceOf(exercisee)) -
                int256(ct1.convertToShares(uint128(-exerciseFees.leftSlot())));
            if (balanceShortage > 0) {
                return
                    LeftRightSigned
                        .wrap(0)
                        .toRightSlot(
                            int128(
                                int256(
                                    PanopticMath.convert1to0(
                                        ct1.convertToAssets(uint256(balanceShortage)),
                                        sqrtPriceX96
                                    )
                                ) + exerciseFees.rightSlot()
                            )
                        )
                        .toLeftSlot(
                            int128(
                                exerciseFees.leftSlot() -
                                    int256(
                                        Math.mulDivRoundingUp(
                                            uint256(balanceShortage),
                                            ct1.totalAssets(),
                                            ct1.totalSupply()
                                        )
                                    )
                            )
                        );
            }
        }

        // otherwise, no need to deviate from the original exercise fee deltas
        return exerciseFees;
    }
}
