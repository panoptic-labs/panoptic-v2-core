// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.18;

// Interfaces
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
// Inherited implementations
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Multicall} from "@multicall/Multicall.sol";
// Libraries
import {Constants} from "@libraries/Constants.sol";
import {TickStateCallContext} from "@types/TickStateCallContext.sol";
import {Errors} from "@libraries/Errors.sol";
import {FeesCalc} from "@libraries/FeesCalc.sol";
import {InteractionHelper} from "@libraries/InteractionHelper.sol";
import {Math} from "@libraries/Math.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
// Custom types
import {LeftRight} from "@types/LeftRight.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {TokenId} from "@types/TokenId.sol";

/// @title The Panoptic Pool: Create permissionless options on top of a concentrated liquidity AMM like Uniswap v3.
/// @author Axicon Labs Limited
/// @notice Manages positions, collateral, liquidations and forced exercises.
/// @dev All liquidity deployed to/from the AMM is owned by this smart contract.
contract PanopticPool is ERC1155Holder, Multicall {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an account is liquidated.
    /// @dev Need to unpack bonusAmounts to get raw numbers, which are always positive.
    /// @param liquidator Address of the caller whom is liquidating the distressed account.
    /// @param liquidatee Address of the distressed/liquidatable account.
    /// @param bonusAmounts LeftRight encoding for the the bonus paid for token 0 (right slot) and 1 (left slot) from the Panoptic Pool to the liquidator.
    /// The token0 bonus is in the right slot, and token1 bonus is in the left slot.
    /// @param tickAt Tick at which the position was liquidated.
    event AccountLiquidated(
        address indexed liquidator,
        address indexed liquidatee,
        int256 bonusAmounts,
        int24 tickAt
    );

    /// @notice Emitted when a position is force exercised.
    /// @dev Need to unpack exerciseFee to get raw numbers, represented as a negative value (fee debited).
    /// @param exercisor Address of the account that forces the exercise of the position.
    /// @param user Address of the owner of the liquidated position
    /// @param tokenId TokenId of the liquidated position.
    /// @param exerciseFee LeftRight encoding for the cost paid by the exercisor to force the exercise of the token.
    /// The token0 fee is in the right slot, and token1 fee is in the left slot.
    /// @param tickAt Tick at which the position was exercised.
    event ForcedExercised(
        address indexed exercisor,
        address indexed user,
        uint256 indexed tokenId,
        int256 exerciseFee,
        int24 tickAt
    );

    /// @notice Emitted when an option is burned.
    /// @dev Is not emitted when a position is liquidated or force exercised.
    /// @param recipient User that burnt the option.
    /// @param positionSize The number of contracts burnt, expressed in terms of the asset.
    /// @param tokenId TokenId of the burnt option.
    /// @param tickAtBurn Tick at which the option was burned.
    /// @param premia LeftRight packing for the amount of premia collected for token0 and token1.
    /// The token0 premia is in the right slot, and token1 premia is in the left slot.
    event OptionBurnt(
        address indexed recipient,
        uint128 positionSize,
        uint256 indexed tokenId,
        int24 tickAtBurn,
        int256 premia
    );

    /// @notice Emitted when an option is minted.
    /// @dev Cannot add liquidity to an existing position
    /// @param recipient User that minted the option.
    /// @param positionSize The number of contracts minted, expressed in terms of the asset.
    /// @param tokenId TokenId of the created option.
    /// @param tickAtMint Tick at which the option was minted.
    /// @param poolUtilizations Packing of the pool utilization (how much funds are in the Panoptic pool versus the AMM pool at the time of minting),
    /// right 64bits for token0 and left 64bits for token1, defined as (inAMM * 10_000) / totalAssets().
    /// Where totalAssets is the total tracked assets in the AMM and PanopticPool minus fees and donations to the Panoptic pool.
    event OptionMinted(
        address indexed recipient,
        uint128 positionSize,
        uint256 indexed tokenId,
        int24 tickAtMint,
        uint128 poolUtilizations
    );

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    // enables packing of types within int128|int128 or uint128|uint128 containers
    using LeftRight for uint256;
    using LeftRight for int256;
    // allows construction of the data which represents an option position
    using TokenId for uint256;
    // data type which has methods that define a leg within an option position
    using LiquidityChunk for uint256;
    // library for container that holds current tick, median tick, and caller
    using TickStateCallContext for uint256;

    /*//////////////////////////////////////////////////////////////
                         IMMUTABLES & CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // specifies what the MIN/MAX slippage ticks are:
    /// @dev has to be one above MIN because of univ3pool.swap's strict "<" check
    int24 internal constant MIN_SWAP_TICK = Constants.MIN_V3POOL_TICK + 1;
    /// @dev has to be one below MAX because of univ3pool.swap's strict "<" check
    int24 internal constant MAX_SWAP_TICK = Constants.MAX_V3POOL_TICK - 1;

    // Flags used as arguments to premia caluculation functions
    /// @dev 'COMPUTE_ALL_PREMIA' calculates premia for all legs of a position
    bool internal constant COMPUTE_ALL_PREMIA = true;
    /// @dev 'COMPUTE_LONG_PREMIA' calculates premia for only the long legs of a position
    bool internal constant COMPUTE_LONG_PREMIA = false;

    /// @dev Only include the share of (settled) premium that is available to collect when calling `_calculateAccumulatedPremia`
    bool internal ONLY_AVAILABLE_PREMIUM = false;

    /// @dev Boolean flag to determine wether a position is added (true) or not (!ADD = false)
    bool internal constant ADD = true;

    /// @dev The window to calculate the TWAP used for solvency checks
    /// Currently calculated by dividing this value into 20 periods, averaging them together, then taking the median
    /// May be configurable on a pool-by-pool basis in the future, but hardcoded for now
    uint32 internal constant TWAP_WINDOW = 600;

    // The maximum allowed delta between the currentTick and the Uniswap TWAP tick during a liquidation (~5% down, ~5.26% up)
    // Prevents manipulation of the currentTick to liquidate positions at a less favorable price
    int256 internal constant MAX_TWAP_DELTA_LIQUIDATION = 513;

    // The minimum amount of time, in seconds, permitted between mini/median TWAP updates.
    uint256 internal constant MEDIAN_PERIOD = 60;

    /// @dev The maximum allowed ratio for a single chunk, defined as: totalLiquidity / netLiquidity
    /// The long premium spread multiplier that corresponds with the MAX_SPREAD value depends on VEGOID,
    /// which can be explored in this calculator: https://www.desmos.com/calculator/mdeqob2m04
    uint64 internal constant MAX_SPREAD = 9 * (2 ** 32);

    /// @dev The maximum allowed number of opened positions
    uint64 internal constant MAX_POSITIONS = 32;

    // multiplier (x10k) for the collateral requirement in the event of a buying power decrease, such as minting or force exercising
    uint256 internal constant BP_DECREASE_BUFFER = 13_333;

    // multiplier (x10k) for the collateral requirement in the general case
    uint256 internal constant NO_BUFFER = 10_000;

    // Panoptic ecosystem contracts - addresses are set in the constructor

    /// @notice The "engine" of Panoptic - manages AMM liquidity and executes all mints/burns/exercises
    SemiFungiblePositionManager internal immutable sfpm;

    /*//////////////////////////////////////////////////////////////
                                STORAGE 
    //////////////////////////////////////////////////////////////*/

    /// @dev The Uniswap v3 pool that this instance of Panoptic is deployed on
    IUniswapV3Pool internal s_univ3pool;

    /// @dev The tick spacing of the underlying Uniswap v3 pool
    int24 internal s_tickSpacing;

    /// @notice Mini-median storage slot
    /// @dev The data for the last 8 interactions is stored as such:
    /// LAST UPDATED BLOCK TIMESTAMP (40 bits)
    /// [BLOCK.TIMESTAMP]
    // (00000000000000000000000000000000) // dynamic
    //
    /// @dev ORDERING of tick indices least --> greatest (24 bits)
    /// The value of the bit codon ([#]) is a pointer to a tick index in the tick array.
    /// The position of the bit codon from most to least significant is the ordering of the
    /// tick index it points to from least to greatest.
    //
    /// @dev [7] [5] [3] [1] [0] [2] [4] [6]
    /// 111 101 011 001 000 010 100 110
    //
    // [Constants.MIN_V3POOL_TICK] [7]
    // 111100100111011000010111
    //
    // [Constants.MAX_V3POOL_TICK] [0]
    // 000011011000100111101001
    //
    // [Constants.MIN_V3POOL_TICK] [6]
    // 111100100111011000010111
    //
    // [Constants.MAX_V3POOL_TICK] [1]
    // 000011011000100111101001
    //
    // [Constants.MIN_V3POOL_TICK] [5]
    // 111100100111011000010111
    //
    // [Constants.MAX_V3POOL_TICK] [2]
    // 000011011000100111101001
    //
    ///  @dev [CURRENT TICK] [4]
    /// (000000000000000000000000) // dynamic
    //
    ///  @dev [CURRENT TICK] [3]
    /// (000000000000000000000000) // dynamic
    uint256 internal s_miniMedian;

    /// @dev ERC4626 vaults that users collateralize their positions with
    /// Each token has its own vault, listed in the same order as the tokens in the pool
    /// In addition to collateral deposits, these vaults also handle various collateral/bonus/exercise computations
    /// underlying collateral token0
    CollateralTracker internal s_collateralToken0;
    /// @dev underlying collateral token1
    CollateralTracker internal s_collateralToken1;

    /// @dev Nested mapping that tracks the option formation: address => tokenId => leg => premiaGrowth
    // premia growth is taking a snapshot of the chunk premium in SFPM, which is measuring the amount of fees
    // collected for every chunk per unit of liquidity (net or short, depending on the isLong value of the specific leg index)
    mapping(address account => mapping(uint256 tokenId => mapping(uint256 leg => uint256 premiaGrowth)))
        internal s_options;

    /// @dev Per-chunk `last` value that gives the aggregate amount of premium owed to all sellers when multiplied by the total amount of liquidity `totalLiquidity`
    /// totalGrossPremium = totalLiquidity * (grossPremium(perLiquidityX64) - lastGrossPremium(perLiquidityX64)) / 2**64
    /// Used to compute the denominator for the fraction of premium available to sellers to collect
    /// LeftRight - right slot is token0, left slot is token1
    mapping(bytes32 chunkKey => uint256 lastGrossPremium) internal s_grossPremiumLast;

    /// @dev per-chunk accumulator for tokens owed to sellers that have been settled and are now available
    /// This number increases when buyers pay long premium and when tokens are collected from Uniswap
    /// It decreases when sellers close positions and collect the premium they are owed
    /// LeftRight - right slot is token0, left slot is token1
    mapping(bytes32 chunkKey => uint256 settledTokens) internal s_settledTokens;

    /// @dev Tracks the amount of liquidity for a user+tokenId (right slot) and the initial pool utilizations when that position was minted (left slot)
    ///    poolUtilizations when minted (left)    liquidity=ERC1155 balance (right)
    ///        token0          token1
    ///  |<-- 64 bits -->|<-- 64 bits -->|<---------- 128 bits ---------->|
    ///  |<-------------------------- 256 bits -------------------------->|
    mapping(address account => mapping(uint256 tokenId => uint256 balanceAndUtilizations))
        internal s_positionBalance;

    /// @dev numPositions (32 positions max)    user positions hash
    ///  |<-- 8 bits -->|<------------------ 248 bits ------------------->|
    ///  |<---------------------- 256 bits ------------------------------>|
    /// @dev Tracks the position list hash i.e keccak256(XORs of abi.encodePacked(positionIdList)).
    /// The order and content of this list is emitted in an event every time it is changed
    /// If the user has no positions, the hash is not the hash of "[]" but just bytes32(0) for consistency.
    /// The accumulator also tracks the total number of positions (ie. makes sure the length of the provided positionIdList matches);
    /// @dev The purpose of the positionIdList is to reduce storage usage when a user has more than one active position
    /// instead of having to manage an unwieldy storage array and do lots of loads, we just store a hash of the array
    /// this hash can be cheaply verified on every operation with a user provided positionIdList - and we can use that for operations
    /// without having to every load any other data from storage
    mapping(address account => uint256 positionsHash) internal s_positionsHash;

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice During construction: sets the address of the panoptic factory smart contract and the SemiFungiblePositionMananger (SFPM).
    /// @param _sfpm The address of the SemiFungiblePositionManager (SFPM) contract.
    constructor(SemiFungiblePositionManager _sfpm) {
        sfpm = _sfpm;
    }

    /// @notice Creates a method for creating a Panoptic Pool on top of an existing Uniswap v3 pair.
    /// @dev Must be called first before any transaction can occur. Must also deploy collateralReference first.
    /// @param univ3pool Address of the target Uniswap v3 pool.
    /// @param tickSpacing TickSpacing of the UniswapV3Pool.
    /// @param currentTick Current tick in the UniswapV3Pool.
    /// @param token0 Address of the pool's token0.
    /// @param token1 Address of the pool's token1.
    /// @param collateralTracker0 Interface for collateral token0.
    /// @param collateralTracker1 Interface for collateral token1.
    function startPool(
        IUniswapV3Pool univ3pool,
        int24 tickSpacing,
        int24 currentTick,
        address token0,
        address token1,
        CollateralTracker collateralTracker0,
        CollateralTracker collateralTracker1
    ) external {
        // reverts if the Uniswap pool has already been initialized
        if (address(s_univ3pool) != address(0)) revert Errors.PoolAlreadyInitialized();

        // Store the univ3Pool variable
        s_univ3pool = IUniswapV3Pool(univ3pool);

        // Store the tickSpacing variable
        s_tickSpacing = tickSpacing;

        // Store the median data
        unchecked {
            s_miniMedian =
                (uint256(block.timestamp) << 216) +
                // magic number which adds (7,5,3,1,0,2,4,6) order and minTick in positions 7, 5, 3 and maxTick in 6, 4, 2
                // see comment on s_miniMedian initialization for format of this magic number
                (uint256(0xF590A6F276170D89E9F276170D89E9F276170D89E9000000000000)) +
                (uint256(uint24(currentTick)) << 24) + // add to slot 4
                (uint256(uint24(currentTick))); // add to slot 3
        }

        // Store the collateral token0
        s_collateralToken0 = collateralTracker0;
        s_collateralToken1 = collateralTracker1;

        // consolidate all 4 approval calls to one library delegatecall in order to reduce bytecode size
        // approves:
        // SFPM: token0, token1
        // CollateralTracker0 - token0
        // CollateralTracker1 - token1
        InteractionHelper.doApprovals(sfpm, collateralTracker0, collateralTracker1, token0, token1);
    }

    /*//////////////////////////////////////////////////////////////
                             QUERY HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the total number of contracts owned by user for a specified position.
    /// @param user Address of the account to be checked.
    /// @param tokenId TokenId of the option position to be checked.
    /// @return balance Number of contracts of tokenId owned by the user.
    /// @return poolUtilization0 The utilization of token0 in the Panoptic pool at mint.
    /// @return poolUtilization1 The utilization of token1 in the Panoptic pool at mint.
    function optionPositionBalance(
        address user,
        uint256 tokenId
    ) external view returns (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) {
        // Extract the data stored in s_positionBalance for the provided user + tokenId
        uint256 balanceData = s_positionBalance[user][tokenId];

        // Return the unpacked data: balanceOf(user, tokenId) and packed pool utilizations at the time of minting
        balance = balanceData.rightSlot();

        // pool utilizations are packed into a single uint128

        // the 64 least significant bits are the utilization of token0, so we can simply cast to uint64 to extract it
        // (cutting off the 64 most significant bits)
        poolUtilization0 = uint64(balanceData.leftSlot());

        // the 64 most significant bits are the utilization of token1, so we can shift the number to the right by 64 to extract it
        // (shifting away the 64 least significant bits)
        poolUtilization1 = uint64(balanceData.leftSlot() >> 64);
    }

    /// @notice Compute the total amount of premium accumulated for a list of positions.
    /// @dev Can be costly as it reads information from 2 ticks for each leg of each tokenId.
    /// @param user Address of the user that owns the positions.
    /// @param positionIdList List of positions. Written as [tokenId1, tokenId2, ...].
    /// @param includePendingPremium true = include premium that is owed to the user but has not yet settled, false = only include premium that is available to collect.
    /// @return premium0 Premium for token0 (negative = amount is owed).
    /// @return premium1 Premium for token1 (negative = amount is owed).
    /// @return balances A list of balances and pool utilization for each position, of the form [[tokenId0, balances0], [tokenId1, balances1], ...].
    function calculateAccumulatedFeesBatch(
        address user,
        bool includePendingPremium,
        uint256[] calldata positionIdList
    ) external view returns (int128 premium0, int128 premium1, uint256[2][] memory) {
        // Get the current tick of the Uniswap pool
        (, int24 currentTick, , , , , ) = s_univ3pool.slot0();

        // Compute the accumulated premia for all tokenId in positionIdList (includes short+long premium)
        (int256 premia, uint256[2][] memory balances) = _calculateAccumulatedPremia(
            user,
            positionIdList,
            COMPUTE_ALL_PREMIA,
            includePendingPremium,
            currentTick
        );

        // Return the premia as (token0, token1)
        return (premia.rightSlot(), premia.leftSlot(), balances);
    }

    /// @notice Compute the total value of the portfolio defined by the positionIdList at the given tick.
    /// @dev The return values do not include the value of the accumulated fees.
    /// @dev value0 and value1 are related to one another according to: value1 = value0 * price(atTick).
    /// @param user Address of the user that owns the positions.
    /// @param atTick Tick at which the portfolio value is evaluated.
    /// @param positionIdList List of positions. Written as [tokenId1, tokenId2, ...].
    /// @return value0 Portfolio value in terms of token0 (negative = loss, when compared with starting value).
    /// @return value1 Portfolio value in terms of token1 (negative = loss, when compared to starting value).
    function calculatePortfolioValue(
        address user,
        int24 atTick,
        uint256[] calldata positionIdList
    ) external view returns (int256 value0, int256 value1) {
        (value0, value1) = FeesCalc.getPortfolioValue(
            s_univ3pool,
            atTick,
            s_positionBalance[user],
            positionIdList
        );
    }

    /// @notice Calculate the accumulated premia owed from the option buyer to the option seller.
    /// @param user The holder of options.
    /// @param positionIdList The list of all option positions held by user.
    /// @param computeAllPremia Whether to compute accumulated premia for all legs held by the user (true), or just owed premia for long legs (false).
    /// @param includePendingPremium true = include premium that is owed to the user but has not yet settled, false = only include premium that is available to collect.
    /// @return portfolioPremium The computed premia of the user's positions, where premia contains the accumulated premia for token0 in the right slot and for token1 in the left slot.
    /// @return balances A list of balances and pool utilization for each position, of the form [[tokenId0, balances0], [tokenId1, balances1], ...].
    function _calculateAccumulatedPremia(
        address user,
        uint256[] calldata positionIdList,
        bool computeAllPremia,
        bool includePendingPremium,
        int24 atTick
    ) internal view returns (int256 portfolioPremium, uint256[2][] memory balances) {
        uint256 pLength = positionIdList.length;
        balances = new uint256[2][](pLength);

        address c_user = user;
        // loop through each option position/tokenId
        for (uint256 k = 0; k < pLength; ) {
            uint256 tokenId = positionIdList[k];

            balances[k][0] = tokenId;
            balances[k][1] = s_positionBalance[c_user][tokenId];
            // if position exists, then compute premia for that position
            if (balances[k][1].rightSlot() != 0) {
                // increment the allPositionsPremia accumulator
                (
                    int256[4] memory premiaByLeg,
                    uint256[2][4] memory premiumAccumulatorsByLeg
                ) = _getPremia(
                        tokenId,
                        balances[k][1].rightSlot(),
                        c_user,
                        computeAllPremia,
                        atTick
                    );

                uint256 numLegs = tokenId.countLegs();
                for (uint256 leg = 0; leg < numLegs; ) {
                    if (premiaByLeg[leg] > 0 && !includePendingPremium) {
                        bytes32 chunkKey = keccak256(
                            abi.encodePacked(
                                tokenId.strike(leg),
                                tokenId.width(leg),
                                tokenId.tokenType(leg)
                            )
                        );

                        uint256 availablePremium = _getAvailablePremium(
                            _getTotalLiquidity(tokenId, leg, s_tickSpacing),
                            s_settledTokens[chunkKey],
                            s_grossPremiumLast[chunkKey],
                            uint256(premiaByLeg[leg]),
                            premiumAccumulatorsByLeg[leg]
                        );
                        portfolioPremium = portfolioPremium.add(int256(availablePremium));
                    } else {
                        portfolioPremium = portfolioPremium.add(premiaByLeg[leg]);
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
        return (portfolioPremium, balances);
    }

    /// @notice Check for slippage violation given the incoming tick limits and extract current price information from the AMM.
    /// @dev If the current price is beyond the slippage bounds a reversion is thrown.
    /// @param tickLimitLow The lower slippage limit on the tick.
    /// @param tickLimitHigh The upper slippage limit on the tick.
    /// @return currentTick The current price tick in the AMM.
    /// @return medianTick The median price in the mini-TWAP storage.
    /// @return tickLimitLow Adjusted value for the lower tick limit.
    /// @return tickLimitHigh Adjusted value for the upper tick limit.
    function _getPriceAndCheckSlippageViolation(
        int24 tickLimitLow,
        int24 tickLimitHigh
    ) internal view returns (int24 currentTick, int24 medianTick, int24, int24) {
        // Extract the current tick price
        (, currentTick, , , , , ) = s_univ3pool.slot0();

        medianTick = getMedian();

        if (tickLimitLow == tickLimitHigh) {
            // since the tick limits are the same, default to max range
            return (currentTick, medianTick, MIN_SWAP_TICK, MAX_SWAP_TICK);
        } else {
            // ensure tick limits are ordered correctly (the SFPM uses the order as a flag for whether to do ITM swaps or not)
            if (tickLimitLow > tickLimitHigh) {
                (tickLimitLow, tickLimitHigh) = (tickLimitHigh, tickLimitLow);
            }
            return (currentTick, medianTick, tickLimitLow, tickLimitHigh);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          MINT/BURN INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates the current options of the user, and mints a new position.
    /// @param positionIdList the list of currently held positions by the user, where the newly minted position(token) will be the last element in 'positionIdList'.
    /// @param positionSize The size of the position to be minted, expressed in terms of the asset.
    /// @param effectiveLiquidityLimitX32 Maximum amount of "spread" defined as totalLiquidity/netLiquidity for a new position.
    /// denominated as X32 = (ratioLimit * 2**32). Set to 0 for no limit / only short options.
    /// @param tickLimitLow The lower tick slippagelimit.
    /// @param tickLimitHigh The upper tick slippagelimit.
    function mintOptions(
        uint256[] calldata positionIdList,
        uint128 positionSize,
        uint64 effectiveLiquidityLimitX32,
        int24 tickLimitLow,
        int24 tickLimitHigh
    ) external {
        _mintOptions(
            positionIdList,
            positionSize,
            effectiveLiquidityLimitX32,
            tickLimitLow,
            tickLimitHigh
        );
    }

    /// @notice Burns the entire balance of tokenId of the caller(msg.sender).
    /// @dev Will exercise if necessary, and will revert if user does not have enough collateral to exercise.
    /// @param tokenId The tokenId of the option position to be burnt.
    /// @param newPositionIdList The new positionIdList without the token being burnt.
    /// @param tickLimitLow Price slippage limit when burning an ITM option.
    /// @param tickLimitHigh Price slippage limit when burning an ITM option.
    function burnOptions(
        uint256 tokenId,
        uint256[] calldata newPositionIdList,
        int24 tickLimitLow,
        int24 tickLimitHigh
    ) external {
        (int24 medianTick, int24 newTick, , , ) = _burnOptions(
            tokenId,
            msg.sender,
            tickLimitLow,
            tickLimitHigh
        );

        // check that the provided positionIdList matches the positions in memory
        _validatePositionList(msg.sender, newPositionIdList, 0);
        if (!_checkSolvency(msg.sender, newPositionIdList, newTick, medianTick, NO_BUFFER))
            revert Errors.NotEnoughCollateral();
    }

    /// @notice Burns the entire balance of all tokenIds provided in positionIdList of the caller(msg.sender).
    /// @dev Will exercise if necessary, and will revert if user does not have enough collateral to exercise.
    /// @param positionIdList The list of tokenIds for the option positions to be burnt.
    /// @param newPositionIdList The new positionIdList without the token being burnt.
    /// @param tickLimitLow Price slippage limit when burning an ITM option.
    /// @param tickLimitHigh Price slippage limit when burning an ITM option.
    function burnOptions(
        uint256[] calldata positionIdList,
        uint256[] calldata newPositionIdList,
        int24 tickLimitLow,
        int24 tickLimitHigh
    ) external {
        (int24 medianTick, int24 newTick, , , ) = _burnAllOptionsFrom(
            msg.sender,
            tickLimitLow,
            tickLimitHigh,
            positionIdList
        );

        // check that the provided positionIdList matches the positions in memory
        _validatePositionList(msg.sender, newPositionIdList, 0);
        if (!_checkSolvency(msg.sender, newPositionIdList, newTick, medianTick, NO_BUFFER))
            revert Errors.NotEnoughCollateral();
    }

    /*//////////////////////////////////////////////////////////////
                         POSITION MINTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates the current options of the user, and mints a new position.
    /// @param positionIdList the list of currently held positions by the user, where the newly minted position(token) will be the last element in 'positionIdList'.
    /// @param positionSize The size of the position to be minted, expressed in terms of the asset.
    /// @param effectiveLiquidityLimitX32 Maximum amount of "spread" defined as totalLiquidity/netLiquidity for a new position.
    /// denominated as X32 = (ratioLimit * 2**32). Set to 0 for no limit / only short options.
    /// @param tickLimitLow The lower tick slippagelimit.
    /// @param tickLimitHigh The upper tick slippagelimit.
    function _mintOptions(
        uint256[] calldata positionIdList,
        uint128 positionSize,
        uint64 effectiveLiquidityLimitX32,
        int24 tickLimitLow,
        int24 tickLimitHigh
    ) internal {
        // the new tokenId will be the last element in 'positionIdList'
        uint256 tokenId;
        unchecked {
            tokenId = positionIdList[positionIdList.length - 1];
        }

        // do duplicate checks and the checks related to minting and positions
        _validatePositionList(msg.sender, positionIdList, 1);
        _doMintChecks(tokenId);

        uint256 tickStateCallContext;
        {
            // checks that the current tick is within the limits provided
            int24 currentTick;
            int24 medianTick;
            (
                currentTick,
                medianTick,
                tickLimitLow,
                tickLimitHigh
            ) = _getPriceAndCheckSlippageViolation(tickLimitLow, tickLimitHigh);

            // Pack the current tick, median tick, and caller into a single uint256
            tickStateCallContext = uint256(0)
                .addCurrentTick(currentTick)
                .addMedianTick(medianTick)
                .addCaller(msg.sender);
        }
        // Mint in the SFPM and update state of collateral
        (uint128 poolUtilizations, int24 newTick) = _mintInSFPMAndUpdateCollateral(
            tokenId,
            tickStateCallContext,
            positionSize,
            tickLimitLow,
            tickLimitHigh
        );

        updateMedian(newTick);

        // calculate and write position Data
        _addUserOption(tokenId, effectiveLiquidityLimitX32);

        // update the users options balance of position 'tokenId'
        // note: user can't mint same position multiple times, so set the positionSize instead of adding
        _setUserOptionsBalance(msg.sender, tokenId, positionSize, poolUtilizations);

        if (
            !_checkSolvency(
                msg.sender,
                positionIdList,
                newTick,
                tickStateCallContext.medianTick(),
                BP_DECREASE_BUFFER
            )
        ) revert Errors.NotEnoughCollateral();

        emit OptionMinted(
            msg.sender,
            positionSize,
            tokenId,
            tickStateCallContext.currentTick(),
            poolUtilizations
        );
    }

    /// @notice Check user health (collateral status).
    /// @dev Moves the required liquidity and checks for user health.
    /// @param tokenId The option position to be minted.
    /// @param tickStateCallContext Container that holds current tick, median tick, and caller.
    /// @param positionSize The size of the position, expressed in terms of the asset.
    /// @param tickLimitLow The lower slippage limit on the tick.
    /// @param tickLimitHigh The upper slippage limit on the tick.
    /// @return poolUtilizations Packing of the pool utilization (how much funds are in the Panoptic pool versus the AMM pool) at the time of minting,
    /// right 64bits for token0 and left 64bits for token1.
    function _mintInSFPMAndUpdateCollateral(
        uint256 tokenId,
        uint256 tickStateCallContext,
        uint128 positionSize,
        int24 tickLimitLow,
        int24 tickLimitHigh
    ) internal returns (uint128 poolUtilizations, int24) {
        // Mint position by using the SFPM. totalSwapped will reflect tokens swapped because of minting ITM.
        // Switch order of tickLimits to create "swapAtMint" flag
        (uint256[4] memory collectedByLeg, int256 totalSwapped, int24 newTick) = sfpm
            .mintTokenizedPosition(tokenId, positionSize, tickLimitHigh, tickLimitLow);

        // cache tickSpacing
        int24 tickSpacing = s_tickSpacing;

        // update premium settlement info
        _updateSettlementPostMint(tokenId, collectedByLeg, positionSize, tickSpacing);

        // pay commission based on total moved amount (long + short)
        // write data about inAMM in collateralBase
        poolUtilizations = _payCommissionAndWriteData(
            tickStateCallContext.updateCurrentTick(newTick),
            tokenId,
            positionSize,
            totalSwapped,
            tickSpacing
        );

        return (poolUtilizations, newTick);
    }

    /// @notice Pay the commission fees for creating the options and update internal state.
    /// @dev Computes long+short amounts, extracts pool utilizations.
    /// @param tickStateCallContext Container that holds current tick, median tick, and caller.
    /// @param tokenId The option position
    /// @param positionSize The size of the position, expressed in terms of the asset
    /// @param totalSwapped How much was swapped (if in-the-money position).
    /// @param tickSpacing The tick spacing of the underlying Uniswap v3 pool.
    /// @return poolUtilizations Packing of the pool utilization (how much funds are in the Panoptic pool versus the AMM pool at the time of minting),
    /// right 64bits for token0 and left 64bits for token1, defined as (inAMM * 10_000) / totalAssets().
    /// Where totalAssets is the total tracked assets in the AMM and PanopticPool minus fees and donations to the Panoptic pool.
    function _payCommissionAndWriteData(
        uint256 tickStateCallContext,
        uint256 tokenId,
        uint128 positionSize,
        int256 totalSwapped,
        int24 tickSpacing
    ) internal returns (uint128) {
        // compute how much of tokenId is long and short positions
        (int256 longAmounts, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
            tokenId,
            positionSize,
            tickSpacing
        );

        int128 utilization0 = s_collateralToken0.takeCommissionAddData(
            tickStateCallContext,
            longAmounts.rightSlot(),
            shortAmounts.rightSlot(),
            totalSwapped.rightSlot()
        );
        int128 utilization1 = s_collateralToken1.takeCommissionAddData(
            tickStateCallContext,
            longAmounts.leftSlot(),
            shortAmounts.leftSlot(),
            totalSwapped.leftSlot()
        );

        // return pool utilizations as a uint128 (pool Utilization is always < 10000)
        unchecked {
            return (uint128(utilization0) + uint128(utilization1 << 64));
        }
    }

    /// @notice Store user option data. Track fees collected for the options.
    /// @dev Computes and stores the option data for each leg.
    /// @param mintTokenId The id of the minted option position.
    /// @param effectiveLiquidityLimitX32 Maximum amount of "spread" defined as totalLiquidity/netLiquidity for a new position
    /// denominated as X32 = (ratioLimit * 2**32). Set to 0 for no limit / only short options.
    function _addUserOption(uint256 mintTokenId, uint64 effectiveLiquidityLimitX32) internal {
        // Update the position list hash (hash = XOR of all keccak256(tokenId)). Remove hash by XOR'ing again
        _updatePositionsHash(msg.sender, mintTokenId, ADD);

        uint256 numLegs = mintTokenId.countLegs();
        // compute upper and lower tick and liquidity
        for (uint256 leg = 0; leg < numLegs; ) {
            // Extract base fee (AMM swap/trading fees) for the position and add it to s_options
            // (ie. the (feeGrowth * liquidity) / 2**128 for each token)
            (int24 tickLower, int24 tickUpper) = mintTokenId.asTicks(leg, s_tickSpacing);
            uint256 isLong = mintTokenId.isLong(leg);
            {
                (uint128 premiumAccumulator0, uint128 premiumAccumulator1) = sfpm.getAccountPremium(
                    address(s_univ3pool),
                    address(this),
                    TokenId.tokenType(mintTokenId, leg),
                    tickLower,
                    tickUpper,
                    type(int24).max,
                    isLong
                );

                // update the premium accumulators
                s_options[msg.sender][mintTokenId][leg] = uint256(0)
                    .toRightSlot(premiumAccumulator0)
                    .toLeftSlot(premiumAccumulator1);
            }
            // verify base Liquidity limit only if new position is long
            if (isLong == 1) {
                // Move this into a new function
                _checkLiquiditySpread(
                    mintTokenId,
                    leg,
                    tickLower,
                    tickUpper,
                    uint64(Math.min(effectiveLiquidityLimitX32, MAX_SPREAD))
                );
            }
            unchecked {
                ++leg;
            }
        }
    }

    /// @notice Set a new option balance for user of option position 'tokenId'.
    /// @param user The user/account to update the balance of.
    /// @param tokenId The option position in question.
    /// @param positionSize The size of the option position in 'tokenId' owned by '_user'.
    /// @param poolUtilizationAtMint The pool utilization ratio when the original position was minted.
    function _setUserOptionsBalance(
        address user,
        uint256 tokenId,
        uint128 positionSize,
        uint128 poolUtilizationAtMint
    ) internal {
        s_positionBalance[user][tokenId] = uint256(0).toLeftSlot(poolUtilizationAtMint).toRightSlot(
            positionSize
        );
    }

    /// @notice Validate the incoming list of positions for the user as it relates to minting.
    /// @dev reverts If the validation fails.
    /// @param mintTokenId The candidate option position to validate.
    function _doMintChecks(uint256 mintTokenId) internal view {
        // make sure the tokenId is for this Panoptic pool
        if (mintTokenId.univ3pool() != sfpm.getPoolId(address(s_univ3pool)))
            revert Errors.InvalidTokenIdParameter(0);
        // disallow user to mint exact same position
        // in order to do it, user should burn it first and then mint
        if (s_positionBalance[msg.sender][mintTokenId] != 0) revert Errors.PositionAlreadyMinted();
    }

    /*//////////////////////////////////////////////////////////////
                         POSITION BURNING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Helper to burn option during a liquidation from an account _owner.
    /// @param owner the owner of the option position to be liquidated.
    /// @param tickLimitLow Price slippage limit when burning an ITM option
    /// @param tickLimitHigh Price slippage limit when burning an ITM option
    /// @param positionIdList the option position to liquidate.
    function _burnAllOptionsFrom(
        address owner,
        int24 tickLimitLow,
        int24 tickLimitHigh,
        uint256[] calldata positionIdList
    )
        internal
        returns (
            int24 medianTick,
            int24 newTick,
            int256 netPaid,
            int256 premiasOwed,
            int256[4][] memory premiasByLeg
        )
    {
        premiasByLeg = new int256[4][](positionIdList.length);
        for (uint256 i = 0; i < positionIdList.length; ) {
            int256 paidAmounts;
            int256 premiaOwed;
            (medianTick, newTick, paidAmounts, premiaOwed, premiasByLeg[i]) = _burnOptions(
                positionIdList[i],
                owner,
                tickLimitLow,
                tickLimitHigh
            );
            premiaOwed = premiasOwed.add(premiaOwed);
            netPaid = netPaid.add(paidAmounts);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Helper to burn an option position held by '_owner'.
    /// @param tokenId the option position to burn.
    /// @param owner the owner of the option position to be burned.
    /// @param tickLimitLow Price slippage limit when burning an ITM option
    /// @param tickLimitHigh Price slippage limit when burning an ITM option
    /// @return medianTick the median tick for that pool
    /// @return newTick the final tick after all positions have been closed
    /// @return paidAmounts The amount of tokens paid when closing the option
    /// @return premiaOwed The amount of premia owed to the user
    /// @return premiaByLeg The amount of premia owed to the user for each leg of the position
    function _burnOptions(
        uint256 tokenId,
        address owner,
        int24 tickLimitLow,
        int24 tickLimitHigh
    )
        internal
        returns (
            int24 medianTick,
            int24 newTick,
            int256 paidAmounts,
            int256 premiaOwed,
            int256[4] memory premiaByLeg
        )
    {
        // Ensure that the current price is within the tick limits
        int24 currentTick;
        (currentTick, medianTick, tickLimitLow, tickLimitHigh) = _getPriceAndCheckSlippageViolation(
            tickLimitLow,
            tickLimitHigh
        );

        uint128 positionSize = s_positionBalance[owner][tokenId].rightSlot();

        // burn position and do exercise checks
        (premiaOwed, premiaByLeg, newTick, paidAmounts) = _burnAndHandleExercise(
            tokenId,
            positionSize,
            owner,
            tickLimitLow,
            tickLimitHigh
        );

        // erase position data
        _updatePositionDataBurn(owner, tokenId);
        // emit event
        emit OptionBurnt(owner, positionSize, tokenId, currentTick, premiaOwed);
    }

    /// @notice Update the internal tracking of the owner's position data upon burning a position.
    /// @param owner The owner of the option position.
    /// @param burnTokenId The option position to burn.
    function _updatePositionDataBurn(address owner, uint256 burnTokenId) internal {
        // reset balances and delete stored option data
        delete (s_positionBalance[owner][burnTokenId]);

        uint256 numLegs = burnTokenId.countLegs();
        for (uint256 leg = 0; leg < numLegs; ) {
            if (burnTokenId.isLong(leg) == 0) {
                // Check the liquidity spread, make sure that closing the option does not exceed the MAX_SPREAD allowed
                (int24 tickLower, int24 tickUpper) = burnTokenId.asTicks(leg, s_tickSpacing);
                _checkLiquiditySpread(burnTokenId, leg, tickLower, tickUpper, MAX_SPREAD);
            }
            delete (s_options[owner][burnTokenId][leg]);
            unchecked {
                ++leg;
            }
        }

        // Update the position list hash (hash = XOR of all keccak256(tokenId)). Remove hash by XOR'ing again
        _updatePositionsHash(owner, burnTokenId, !ADD);
    }

    /// @notice Burns and handles the exercise of options.
    /// @param tokenId The option position to burn.
    /// @param positionSize The size of the option position, expressed in terms of the asset.
    /// @param tickLimitLow The lower slippage limit on the tick.
    /// @param tickLimitHigh The upper slippage limit on the tick.
    /// @param owner The owner of the option position.
    function _burnAndHandleExercise(
        uint256 tokenId,
        uint128 positionSize,
        address owner,
        int24 tickLimitLow,
        int24 tickLimitHigh
    )
        internal
        returns (
            int256 realizedPremia,
            int256[4] memory premiaByLeg,
            int24 newTick,
            int256 paidAmounts
        )
    {
        // burn the option in sfpm, switch order of tickLimits to create "swapAtMint" flag
        int256 totalSwapped;
        uint256[4] memory collectedByLeg;
        (collectedByLeg, totalSwapped, newTick) = sfpm.burnTokenizedPosition(
            tokenId,
            positionSize,
            tickLimitHigh,
            tickLimitLow
        );

        updateMedian(newTick);

        int256 longAmounts;
        int256 shortAmounts;
        {
            int24 tickSpacing = s_tickSpacing;
            uint256 _tokenId = tokenId;
            uint128 _positionSize = positionSize;
            (realizedPremia, premiaByLeg) = _updateSettlementPostBurn(
                owner,
                _tokenId,
                collectedByLeg,
                _positionSize,
                tickSpacing
            );

            // compute option amounts if exercise was necessary
            (longAmounts, shortAmounts) = PanopticMath.computeExercisedAmounts(
                _tokenId,
                _positionSize,
                tickSpacing
            );
        }
        // exercise the option and take the commission and addData

        {
            int128 paid0 = s_collateralToken0.exercise(
                owner,
                longAmounts.rightSlot(),
                shortAmounts.rightSlot(),
                totalSwapped.rightSlot(),
                realizedPremia.rightSlot()
            );
            paidAmounts = paidAmounts.toRightSlot(paid0);
        }

        {
            int128 paid1 = s_collateralToken1.exercise(
                owner,
                longAmounts.leftSlot(),
                shortAmounts.leftSlot(),
                totalSwapped.leftSlot(),
                realizedPremia.leftSlot()
            );
            paidAmounts = paidAmounts.toLeftSlot(paid1);
        }

        return (realizedPremia, premiaByLeg, newTick, paidAmounts);
    }

    /*//////////////////////////////////////////////////////////////
                    LIQUIDATIONS & FORCED EXERCISES
    //////////////////////////////////////////////////////////////*/

    /// @notice Liquidates a distressed account. Will burn all positions and will issue a bonus to the liquidator.
    /// @dev Will revert if: account is not margin called or if the user liquidates themselves.
    /// @param liquidatee Address of the distressed account.
    /// @param positionIdList List of positions owned by the user. Written as [tokenId1, tokenId2, ...].
    /// @param positionIdListLiquidator List of positions owned by the liquidator.
    /// @param delegations LeftRight amounts of token0 and token1 (token0:token1 right:left) delegated to the liquidatee by the liquidator so the option can be smoothly exercised.
    function liquidate(
        address liquidatee,
        uint256[] calldata positionIdList,
        uint256[] calldata positionIdListLiquidator,
        uint256 delegations
    ) external {
        address _liquidatee = liquidatee;
        _validatePositionList(_liquidatee, positionIdList, 0);

        // Assert the account we are liquidating is actually insolvent
        int24 twapTick = getUniV3TWAP();

        uint256 tokenData0;
        uint256 tokenData1;
        int256 premia;
        {
            (, int24 currentTick, , , , , ) = s_univ3pool.slot0();

            // Enforce maximum delta between TWAP and currentTick to prevent extreme price manipulation
            if (Math.abs(currentTick - twapTick) > MAX_TWAP_DELTA_LIQUIDATION)
                revert Errors.StaleTWAP();

            uint256[2][] memory positionBalanceArray = new uint256[2][](positionIdList.length);
            (premia, positionBalanceArray) = _calculateAccumulatedPremia(
                _liquidatee,
                positionIdList,
                COMPUTE_ALL_PREMIA,
                ONLY_AVAILABLE_PREMIUM,
                currentTick
            );
            tokenData0 = s_collateralToken0.getAccountMarginDetails(
                _liquidatee,
                twapTick,
                positionBalanceArray,
                premia.rightSlot()
            );

            tokenData1 = s_collateralToken1.getAccountMarginDetails(
                _liquidatee,
                twapTick,
                positionBalanceArray,
                premia.leftSlot()
            );

            (uint256 balanceCross, uint256 thresholdCross) = _getSolvencyBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(twapTick)
            );

            if (balanceCross >= thresholdCross) revert Errors.NotMarginCalled();
        }

        // Perform the specified delegation from `msg.sender` to `liquidatee`
        // Works like a transfer, so the liquidator must possess all the tokens they are delegating, resulting in no net supply change
        // If not enough tokens are delegated for the positions of `liquidatee` to be closed, the liquidation will fail
        s_collateralToken0.delegate(msg.sender, _liquidatee, delegations.rightSlot());
        s_collateralToken1.delegate(msg.sender, _liquidatee, delegations.leftSlot());

        // burn all options from the liquidatee
        (, int24 finalTick, int256 netExchanged, , ) = _burnAllOptionsFrom(
            _liquidatee,
            Constants.MIN_V3POOL_TICK,
            Constants.MAX_V3POOL_TICK,
            positionIdList
        );

        // compute bonus amounts using latest tick data
        (int256 liquidationBonus0, int256 liquidationBonus1) = PanopticMath.getLiquidationBonus(
            tokenData0,
            tokenData1,
            Math.getSqrtRatioAtTick(twapTick),
            Math.getSqrtRatioAtTick(finalTick),
            netExchanged,
            premia
        );

        // revoke the delegated amount plus the bonus amount.
        {
            s_collateralToken0.revoke(
                msg.sender,
                _liquidatee,
                uint256(int256(uint256(delegations.rightSlot())) + liquidationBonus0)
            );
            s_collateralToken1.revoke(
                msg.sender,
                _liquidatee,
                uint256(int256(uint256(delegations.leftSlot())) + liquidationBonus1)
            );
        }
        {
            // check that the provided positionIdList matches the positions in memory
            _validatePositionList(msg.sender, positionIdListLiquidator, 0);
            if (
                positionIdListLiquidator.length > 0 &&
                !_checkSolvency(
                    msg.sender,
                    positionIdListLiquidator,
                    finalTick,
                    finalTick,
                    BP_DECREASE_BUFFER
                )
            ) revert Errors.NotEnoughCollateral();

            int256 bonusAmounts = int256(0).toRightSlot(int128(liquidationBonus0)).toLeftSlot(
                int128(liquidationBonus1)
            );
            emit AccountLiquidated(msg.sender, _liquidatee, bonusAmounts, finalTick);
        }
    }

    /// @notice Force the exercise of a single position. Exercisor will have to pay a small fee do force exercise.
    /// @dev Will revert if: number of touchedId is larger than 1 or if user force exercises their own position
    /// @param account Address of the distressed account
    /// @param touchedId List of position to be force exercised. Can only contain one tokenId, written as [tokenId]
    /// @param positionIdListExercisee Post-burn list of open positions in the exercisee's (account) account
    /// @param positionIdListExercisor List of open positions in the exercisor's (msg.sender) account
    /// @dev The collateral decrease resulting from burning these positions must be greater than the force exercise fee
    function forceExercise(
        address account,
        uint256[] calldata touchedId,
        uint256[] calldata positionIdListExercisee,
        uint256[] calldata positionIdListExercisor
    ) external {
        // revert if multiple positions are specified
        // the reason why the singular touchedId is an array is so it composes well with the rest of the system
        // '_calculateAccumulatedPremia' expects a list of positions to be touched, and this is the only way to pass a single position
        if (touchedId.length != 1) revert Errors.InputListFail();

        // validate the exercisor's position list (the exercisee's list will be evaluated after their position is force exercised)
        _validatePositionList(msg.sender, positionIdListExercisor, 0);

        int24 twapTick = getUniV3TWAP();

        // on forced exercise, the price *must* be outside the position's range for at least 1 leg
        touchedId[0].validateIsExercisable(twapTick, s_tickSpacing);

        // compute the notional value of the short legs (the maximum amount of tokens required to exercise - premia)
        // and the long legs (from which the exercise cost is computed)
        (int256 longAmounts, int256 delegatedAmounts) = PanopticMath.computeExercisedAmounts(
            touchedId[0],
            s_positionBalance[account][touchedId[0]].rightSlot(),
            s_tickSpacing
        );

        (, int24 currentTick, , , , , ) = s_univ3pool.slot0();

        {
            // add the premia to the delegated amounts to ensure the user has enough collateral to exercise
            (int256 positionPremia, ) = _calculateAccumulatedPremia(
                account,
                touchedId,
                COMPUTE_LONG_PREMIA,
                ONLY_AVAILABLE_PREMIUM,
                currentTick
            );

            // long premia is represented as negative so subtract it to increase it for the delegated amounts
            delegatedAmounts = delegatedAmounts.sub(positionPremia);
        }
        int256 exerciseFees;
        {
            uint128 positionBalance = s_positionBalance[account][touchedId[0]].rightSlot();

            // Compute the exerciseFee, this will decrease the further away the price is from the forcedExercised position
            /// @dev use the medianTick to prevent price manipulations based on swaps.
            exerciseFees = s_collateralToken0.exerciseCost(
                currentTick,
                getMedian(),
                touchedId[0],
                positionBalance,
                longAmounts
            );
        }

        // The protocol delegates some virtual shares to ensure the burn can be settled.
        s_collateralToken0.delegate(account, uint128(delegatedAmounts.rightSlot()));
        s_collateralToken1.delegate(account, uint128(delegatedAmounts.leftSlot()));

        // Exercise the option
        // Note: tick limits are not applied here since it is not the exercisor's position being liquidated
        _burnAllOptionsFrom(account, 0, 0, touchedId);

        int256 refundAmounts = delegatedAmounts.add(exerciseFees);

        // redistribute token composition of refund amounts if user doesn't have enough of one token to pay
        refundAmounts = PanopticMath.getRefundAmounts(
            account,
            refundAmounts,
            twapTick,
            s_collateralToken0,
            s_collateralToken1
        );

        // settle difference between delegated amounts (from the protocol) and exercise fees/substituted tokens
        s_collateralToken0.refund(
            account,
            msg.sender,
            refundAmounts.rightSlot() - delegatedAmounts.rightSlot()
        );
        s_collateralToken1.refund(
            account,
            msg.sender,
            refundAmounts.leftSlot() - delegatedAmounts.leftSlot()
        );

        // refund the protocol any virtual shares after settling the difference with the exercisor
        s_collateralToken0.refund(account, uint128(delegatedAmounts.rightSlot()));
        s_collateralToken1.refund(account, uint128(delegatedAmounts.leftSlot()));

        // update the current tick after any ITM swaps
        (, currentTick, , , , , ) = s_univ3pool.slot0();

        // validate the exercisee's position list and assert their solvency
        _validatePositionList(account, positionIdListExercisee, 0);

        if (
            positionIdListExercisee.length > 0 &&
            !_checkSolvency(account, positionIdListExercisee, currentTick, twapTick, NO_BUFFER)
        ) revert Errors.ExerciseeNotSolvent();

        // the exercisor's position list is validated above
        // we need to assert their solvency against their collateral requirement plus a buffer
        // force exercises involve a collateral decrease with open positions, so there is a higher standard for solvency
        // a similar buffer is also invoked when minting options, which also decreases the available collateral
        if (
            positionIdListExercisor.length > 0 &&
            !_checkSolvency(
                msg.sender,
                positionIdListExercisor,
                currentTick,
                twapTick,
                BP_DECREASE_BUFFER
            )
        ) revert Errors.NotEnoughCollateral();

        emit ForcedExercised(msg.sender, account, touchedId[0], exerciseFees, currentTick);
    }

    /*//////////////////////////////////////////////////////////////
                            SOLVENCY CHECKS
    //////////////////////////////////////////////////////////////*/

    /// @notice check whether an account is solvent at a given `atTick` with a collateral requirement of `buffer`/10_000 multiplied by the requirement of `positionIdList`.
    /// @param account The account to check solvency for.
    /// @param positionIdList The list of positions to check solvency for.
    /// @param currentTick The current tick of the Uniswap pool (needed for fee calculations).
    /// @param atTick The tick to check solvency at.
    /// @param buffer The buffer to apply to the collateral requirement.
    function _checkSolvency(
        address account,
        uint256[] calldata positionIdList,
        int24 currentTick,
        int24 atTick,
        uint256 buffer
    ) internal view returns (bool) {
        (
            int256 portfolioPremium,
            uint256[2][] memory positionBalanceArray
        ) = _calculateAccumulatedPremia(
                account,
                positionIdList,
                COMPUTE_ALL_PREMIA,
                ONLY_AVAILABLE_PREMIUM,
                currentTick
            );

        uint256 tokenData0 = s_collateralToken0.getAccountMarginDetails(
            account,
            atTick,
            positionBalanceArray,
            portfolioPremium.rightSlot()
        );
        uint256 tokenData1 = s_collateralToken1.getAccountMarginDetails(
            account,
            atTick,
            positionBalanceArray,
            portfolioPremium.leftSlot()
        );

        (uint256 balanceCross, uint256 thresholdCross) = _getSolvencyBalances(
            tokenData0,
            tokenData1,
            Math.getSqrtRatioAtTick(atTick)
        );

        return balanceCross > (thresholdCross * buffer) / 10_000;
    }

    /// @notice Get parameters related to the solvency state of the account associated with the incoming tokenData.
    /// @param tokenData0 Leftright encoded word with balance of token0 in the right slot, and required balance in left slot.
    /// @param tokenData1 Leftright encoded word with balance of token1 in the right slot, and required balance in left slot.
    /// @param sqrtPriceX96 The current sqrt(price) of the AMM.
    /// @return balanceCross The current cross-collateral balance of the option positions.
    /// @return thresholdCross The cross-collateral threshold balance under which the account is insolvent.
    function _getSolvencyBalances(
        uint256 tokenData0,
        uint256 tokenData1,
        uint160 sqrtPriceX96
    ) internal pure returns (uint256 balanceCross, uint256 thresholdCross) {
        unchecked {
            // the cross-collateral balance, computed in terms of liquidity X*√P + Y/√P
            // We use mulDiv to compute Y/√P + X*√P while correctly handling overflows
            balanceCross =
                ((uint256(tokenData1.rightSlot()) * 2 ** 96) / sqrtPriceX96) +
                Math.mulDiv96(tokenData0.rightSlot(), sqrtPriceX96);
            // the amount of cross-collateral balance needed for the account to be solvent, computed in terms of liquidity
            thresholdCross =
                ((uint256(tokenData1.leftSlot()) * 2 ** 96) / sqrtPriceX96) +
                Math.mulDiv96(tokenData0.leftSlot(), sqrtPriceX96);
        }
    }

    /*//////////////////////////////////////////////////////////////
                 POSITIONS HASH GENERATION & VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Makes sure that the positions in the incoming user's list match the existing active option positions.
    /// @dev Check whether the list of positionId 1) has duplicates and 2) matches the length stored in the positionsHash.
    /// @param account The owner of the incoming list of positions.
    /// @param positionIdList The existing list of active options for the owner.
    /// @param offset Changes depending on whether this is a new mint or a liquidation (=1 if new mint, 0 if liquidation).
    function _validatePositionList(
        address account,
        uint256[] calldata positionIdList,
        uint256 offset
    ) internal view {
        uint256 pLength;
        uint256 currentHash = s_positionsHash[account];

        unchecked {
            pLength = positionIdList.length - offset;
        }
        // note that if pLength == 0 even if a user has existing position(s) the below will fail b/c the fingerprints will mismatch
        // Check that position hash (the fingerprint of option positions) matches the one stored for the '_account'
        uint256 fingerprintIncomingList;

        for (uint256 i = 0; i < pLength; ) {
            fingerprintIncomingList = PanopticMath.updatePositionsHash(
                fingerprintIncomingList,
                positionIdList[i],
                ADD
            );
            unchecked {
                ++i;
            }
        }

        // revert if fingerprint for provided '_positionIdList' does not match the one stored for the '_account'
        if (fingerprintIncomingList != currentHash) revert Errors.InputListFail();
    }

    /// @notice Updates the hash for all positions owned by an account. This fingerprints the list of all incoming options with a single hash.
    /// @dev The outcome of this function will be to update the hash of positions.
    /// This is done as a duplicate/validation check of the incoming list O(N).
    /// @dev The positions hash is stored as the XOR of the keccak256 of each tokenId. Updating will XOR the existing hash with the new tokenId.
    /// The same update can either add a new tokenId (when minting an option), or remove an existing one (when burning it) - this happens through the XOR.
    /// @param account The owner of the options.
    /// @param tokenId The option position.
    /// @param addFlag Pass addFlag=true when this is adding a position, needed to ensure the number of positions increases or decreases.
    function _updatePositionsHash(address account, uint256 tokenId, bool addFlag) internal {
        // Get the current position hash value (fingerprint of all pre-existing positions created by '_account')
        // Add the current tokenId to the positionsHash as XOR'd
        // since 0 ^ x = x, no problem on first mint
        // Store values back into the user option details with the updated hash (leaves the other parameters unchanged)
        uint256 newHash = PanopticMath.updatePositionsHash(
            s_positionsHash[account],
            tokenId,
            addFlag
        );
        if ((newHash >> 248) > MAX_POSITIONS) revert Errors.TooManyPositionsOpen();
        s_positionsHash[account] = newHash;
    }

    /*//////////////////////////////////////////////////////////////
                          ONBOARD MEDIAN TWAP
    //////////////////////////////////////////////////////////////*/

    /// @notice Updates the mini twap of the PanopticPool, called externally
    function pokeMedian() external {
        // Get the current tick of the Uniswap pool
        (, int24 currentTick, , , , , ) = s_univ3pool.slot0();

        // update the miniTWAP
        updateMedian(currentTick);
    }

    /// @notice Computes The mini twap of the PanopticPool.
    /// @return medianTick The median value over the last 8 interactions.
    function getMedian() internal view returns (int24 medianTick) {
        uint256 medianData = s_miniMedian;
        unchecked {
            uint24 medianIndex3 = uint24(medianData >> (192 + 3 * 3)) % 8;
            uint24 medianIndex4 = uint24(medianData >> (192 + 3 * 4)) % 8;

            // return the average of the rank 3 and 4 values
            medianTick =
                (int24(uint24(medianData >> (medianIndex3 * 24))) +
                    int24(uint24(medianData >> (medianIndex4 * 24)))) /
                2;
        }
    }

    /// @notice Updates the mini twap of the PanopticPool.
    /// @param currentTick The currentTick.
    function updateMedian(int24 currentTick) internal {
        uint256 oldMedianData = s_miniMedian;
        unchecked {
            // only proceed if last entry is at least MEDIAN_PERIOD seconds old
            if (block.timestamp >= uint256(uint40(oldMedianData >> 216)) + MEDIAN_PERIOD) {
                uint24 orderMap = uint24(oldMedianData >> 192);

                uint24 newOrderMap;
                uint24 shift = 1;
                bool below = true;
                uint24 rank;
                int24 entry;
                for (uint8 i; i < 8; ++i) {
                    // read the rank from the existing ordering
                    rank = (orderMap >> (3 * i)) % 8;

                    if (rank == 7) {
                        shift -= 1;
                        continue;
                    }

                    // read the corresponding entry
                    entry = int24(uint24(oldMedianData >> (rank * 24)));
                    if ((below) && (currentTick > entry)) {
                        shift += 1;
                        below = false;
                    }

                    newOrderMap = newOrderMap + ((rank + 1) << (3 * (i + shift - 1)));
                }
                s_miniMedian =
                    (block.timestamp << 216) +
                    (uint256(newOrderMap) << 192) +
                    uint256(uint192(oldMedianData << 24)) +
                    uint256(uint24(currentTick));
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                QUERIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the address of the AMM pool connected to this Panoptic pool.
    /// @return univ3pool AMM pool corresponding to this Panoptic pool.
    function univ3pool() external view returns (IUniswapV3Pool) {
        return s_univ3pool;
    }

    /// @notice Get the collateral token corresponding to token0 of the AMM pool.
    /// @return collateralToken Collateral token corresponding to token0 in the AMM.
    function collateralToken0() external view returns (CollateralTracker collateralToken) {
        return s_collateralToken0;
    }

    /// @notice Get the collateral token corresponding to token1 of the AMM pool.
    /// @return collateralToken collateral token corresponding to token1 in the AMM.
    function collateralToken1() external view returns (CollateralTracker) {
        return s_collateralToken1;
    }

    /// @notice get the number of positions for an account
    /// @param user the account to get the positions hash of
    /// @return _numberOfPositions number of positions in the account
    function numberOfPositions(address user) public view returns (uint256 _numberOfPositions) {
        _numberOfPositions = (s_positionsHash[user] >> 248);
    }

    /// @notice Compute the TWAP price from the last 600s = 10mins.
    /// @return twapTick The TWAP price in ticks.
    function getUniV3TWAP() internal view returns (int24 twapTick) {
        twapTick = PanopticMath.twapFilter(s_univ3pool, TWAP_WINDOW);
    }

    /// @notice return the array of the last 8 price values stored internally.
    /// @return priceArray the series of prices used to compute the median price.
    /// @return medianTick the median tick of the current price array.
    function getPriceArray() external view returns (int24[] memory priceArray, int24 medianTick) {
        uint256 medianData = s_miniMedian;

        priceArray = new int24[](8);
        unchecked {
            for (uint256 i = 0; i < 8; ++i) {
                priceArray[7 - i] = int24(uint24(medianData >> (24 * i)));
            }
        }
        medianTick = getMedian();
        return (priceArray, medianTick);
    }

    /*//////////////////////////////////////////////////////////////
                  PREMIA & PREMIA SPREAD CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensure the effective liquidity in a given chunk is above a certain threshold.
    /// @param tokenId The id of the option position.
    /// @param leg The leg of the option position (used to check if long or short).
    /// @param tickLower The lower tick of the chunk.
    /// @param tickUpper The upper tick of the chunk.
    /// @param effectiveLiquidityLimitX32 Maximum amount of "spread" defined as totalLiquidity/netLiquidity for a new position
    /// denominated as X32 = (ratioLimit * 2**32). Set to 0 for no limit / only short options.
    function _checkLiquiditySpread(
        uint256 tokenId,
        uint256 leg,
        int24 tickLower,
        int24 tickUpper,
        uint64 effectiveLiquidityLimitX32
    ) internal view {
        uint256 accountLiquidities = sfpm.getAccountLiquidity(
            address(s_univ3pool),
            address(this),
            tokenId.tokenType(leg),
            tickLower,
            tickUpper
        );

        uint128 netLiquidity = accountLiquidities.rightSlot();
        uint128 totalLiquidity = accountLiquidities.leftSlot();
        // compute and return effective liquidity. Return if short=net=0, which is closing short position
        if ((totalLiquidity == 0) && (netLiquidity == 0)) return;

        uint256 effectiveLiquidityFactorX32;
        unchecked {
            effectiveLiquidityFactorX32 = (uint256(totalLiquidity) * 2 ** 32) / netLiquidity;
        }

        // put a limit on how much new liquidity in one transaction can be deployed into this leg
        // the effective liquidity measures how many times more the newly added liquidity is compared to the existing/base liquidity
        if (effectiveLiquidityFactorX32 > uint256(effectiveLiquidityLimitX32))
            revert Errors.EffectiveLiquidityAboveThreshold();
    }

    /// @notice Compute the premia collected for a single option position 'tokenId'.
    /// @param tokenId The option position.
    /// @param positionSize The number of contracts (size) of the option position.
    /// @param owner The holder of the tokenId option.
    /// @param computeAllPremia Whether to compute accumulated premia for all legs held by the user (true), or just owed premia for long legs (false).
    /// @param atTick The tick at which the premia is calculated -> use (atTick < type(int24).max) to compute it
    /// up to current block. atTick = type(int24).max will only consider fees as of the last on-chain transaction.
    function _getPremia(
        uint256 tokenId,
        uint128 positionSize,
        address owner,
        bool computeAllPremia,
        int24 atTick
    )
        internal
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
                    s_tickSpacing
                );
                uint256 tokenType = tokenId.tokenType(leg);

                (premiumAccumulatorsByLeg[leg][0], premiumAccumulatorsByLeg[leg][1]) = sfpm
                    .getAccountPremium(
                        address(s_univ3pool),
                        address(this),
                        tokenType,
                        liquidityChunk.tickLower(),
                        liquidityChunk.tickUpper(),
                        atTick,
                        isLong
                    );

                unchecked {
                    uint256 premiumAccumulatorLast = s_options[owner][tokenId][leg];

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
                        premiaByLeg[leg] = premiaByLeg[leg].mul(-1);
                    }
                }
            }
            unchecked {
                ++leg;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        AVAILABLE PREMIUM LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds collected tokens to settled accumulator and adjusts grossPremiumLast for any liquidity added
    /// @dev Always called after `mintTokenizedPosition`
    /// @param tokenId The option position that was minted.
    /// @param collectedByLeg The amount of tokens collected in the corresponding chunk for each leg of the position.
    /// @param positionSize The size of the position, expressed in terms of the asset.
    /// @param tickSpacing The tick spacing of the underlying Uniswap v3 pool.
    function _updateSettlementPostMint(
        uint256 tokenId,
        uint256[4] memory collectedByLeg,
        uint128 positionSize,
        int24 tickSpacing
    ) internal {
        uint256 numLegs = tokenId.countLegs();
        for (uint256 leg = 0; leg < numLegs; ++leg) {
            bytes32 chunkKey = keccak256(
                abi.encodePacked(tokenId.strike(leg), tokenId.width(leg), tokenId.tokenType(leg))
            );
            // add any tokens collected from Uniswap in a given chunk to the settled tokens available for withdrawal by sellers
            s_settledTokens[chunkKey] = s_settledTokens[chunkKey].add(collectedByLeg[leg]);

            if (tokenId.isLong(leg) == 0) {
                uint256 liquidityChunk = PanopticMath.getLiquidityChunk(
                    tokenId,
                    leg,
                    positionSize,
                    tickSpacing
                );

                // new totalLiquidity (total sold) = removedLiquidity + netLiquidity (R + N)
                uint256 totalLiquidity = _getTotalLiquidity(tokenId, leg, tickSpacing);

                // We need to adjust the grossPremiumLast value such that the result of
                // (grossPremium - adjustedGrossPremiumLast)*updatedTotalLiquidityPostMint/2**64 is equal to (grossPremium - grossPremiumLast)*totalLiquidityBeforeMint/2**64
                // G: total gross premium
                // T: totalLiquidityBeforeMint
                // R: positionLiquidity
                // C: current grossPremium value
                // L: current grossPremiumLast value
                // Ln: updated grossPremiumLast value
                // T * (C - L) = G
                // (T + R) * (C - Ln) = G
                //
                // T * (C - L) = (T + R) * (C - Ln)
                // (TC - TL) / (T + R) = C - Ln
                // Ln = C - (TC - TL)/(T + R)
                // Ln = (CT + CR - TC + TL)/(T+R)
                // Ln = (CR + TL)/(T+R)

                uint256[2] memory grossCurrent;
                (grossCurrent[0], grossCurrent[1]) = sfpm.getAccountPremium(
                    address(s_univ3pool),
                    address(this),
                    tokenId.tokenType(leg),
                    liquidityChunk.tickLower(),
                    liquidityChunk.tickUpper(),
                    type(int24).max,
                    0
                );

                unchecked {
                    // L
                    uint256 grossPremiumLast = s_grossPremiumLast[chunkKey];
                    // R
                    uint256 positionLiquidity = liquidityChunk.liquidity();
                    // T (totalLiquidity is (T + R) after minting)
                    uint256 totalLiquidityBefore = totalLiquidity - positionLiquidity;

                    s_grossPremiumLast[chunkKey] = uint256(0)
                        .toRightSlot(
                            uint128(
                                (grossCurrent[0] *
                                    positionLiquidity +
                                    grossPremiumLast.rightSlot() *
                                    totalLiquidityBefore) / (totalLiquidity)
                            )
                        )
                        .toLeftSlot(
                            uint128(
                                (grossCurrent[1] *
                                    positionLiquidity +
                                    grossPremiumLast.leftSlot() *
                                    totalLiquidityBefore) / (totalLiquidity)
                            )
                        );
                }
            }
        }
    }

    /// @notice Query the amount of premium available for withdrawal given a certain `premiumOwed` for a chunk
    /// @dev Based on the ratio between `settledTokens` and the total premium owed to sellers in a chunk
    /// @dev The ratio is capped at 1 (it can be greater than one if some seller forfeits enough premium)
    /// @param totalLiquidity The updated total liquidity amount for the chunk
    /// @param settledTokens LeftRight accumulator for the amount of tokens that have been settled (collected or paid)
    /// @param grossPremiumLast The `last` values used with `premiumAccumulators` to compute the total premium owed to sellers
    /// @param premiumOwed The amount of premium owed to sellers in the chunk
    /// @param premiumAccumulators The current values of the premium accumulators for the chunk
    /// @return availablePremium The amount of premium available for withdrawal
    function _getAvailablePremium(
        uint256 totalLiquidity,
        uint256 settledTokens,
        uint256 grossPremiumLast,
        uint256 premiumOwed,
        uint256[2] memory premiumAccumulators
    ) internal pure returns (uint256) {
        unchecked {
            // long premium only accumulates as it is settled, so compute the ratio
            // of total settled tokens in a chunk to total premium owed to sellers and multiply
            // cap the ratio at 1 (it can be greater than one if some seller forfeits enough premium)
            uint256 accumulated0 = ((premiumAccumulators[0] - grossPremiumLast.rightSlot()) *
                totalLiquidity) / 2 ** 64;
            uint256 accumulated1 = ((premiumAccumulators[1] - grossPremiumLast.leftSlot()) *
                totalLiquidity) / 2 ** 64;

            return (
                uint256(0)
                    .toRightSlot(
                        uint128(
                            Math.min(
                                (uint256(premiumOwed.rightSlot()) * settledTokens.rightSlot()) /
                                    (accumulated0 == 0 ? type(uint256).max : accumulated0),
                                premiumOwed.rightSlot()
                            )
                        )
                    )
                    .toLeftSlot(
                        uint128(
                            Math.min(
                                (uint256(premiumOwed.leftSlot()) * settledTokens.leftSlot()) /
                                    (accumulated1 == 0 ? type(uint256).max : accumulated1),
                                premiumOwed.leftSlot()
                            )
                        )
                    )
            );
        }
    }

    /// @notice Query the total amount of liquidity sold in the corresponding chunk for a position leg
    /// @dev totalLiquidity (total sold) = removedLiquidity + netLiquidity (in AMM)
    /// @param tokenId The option position
    /// @param leg The leg of the option position to get `totalLiquidity for
    //// @param tickSpacing The tick spacing of the underlying Uniswap v3 pool
    function _getTotalLiquidity(
        uint256 tokenId,
        uint256 leg,
        int24 tickSpacing
    ) internal view returns (uint256 totalLiquidity) {
        unchecked {
            // totalLiquidity (total sold) = removedLiquidity + netLiquidity

            (int24 tickLower, int24 tickUpper) = tokenId.asTicks(leg, tickSpacing);
            uint256 tokenType = tokenId.tokenType(leg);
            uint256 accountLiquidities = sfpm.getAccountLiquidity(
                address(s_univ3pool),
                address(this),
                tokenType,
                tickLower,
                tickUpper
            );

            // removed + net
            totalLiquidity = accountLiquidities.rightSlot() + accountLiquidities.leftSlot();
        }
    }

    /// @notice Updates settled tokens and grossPremiumLast for a chunk after a burn and returns premium info
    /// @dev Always called after `burnTokenizedPosition`
    /// @param owner The owner of the option position that was burnt
    /// @param tokenId The option position that was burnt
    /// @param collectedByLeg The amount of tokens collected in the corresponding chunk for each leg of the position
    /// @param positionSize The size of the position, expressed in terms of the asset
    /// @param tickSpacing The tick spacing of the underlying Uniswap v3 pool
    /// @return realizedPremia The amount of premia owed to the user
    /// @return premiaByLeg The amount of premia owed to the user for each leg of the position
    function _updateSettlementPostBurn(
        address owner,
        uint256 tokenId,
        uint256[4] memory collectedByLeg,
        uint128 positionSize,
        int24 tickSpacing
    ) internal returns (int256 realizedPremia, int256[4] memory premiaByLeg) {
        uint256 numLegs = tokenId.countLegs();
        uint256[2][4] memory premiumAccumulatorsByLeg;

        // compute accumulated fees
        (premiaByLeg, premiumAccumulatorsByLeg) = _getPremia(
            tokenId,
            positionSize,
            owner,
            COMPUTE_ALL_PREMIA,
            type(int24).max
        );

        for (uint256 leg = 0; leg < numLegs; ) {
            bytes32 chunkKey = keccak256(
                abi.encodePacked(tokenId.strike(leg), tokenId.width(leg), tokenId.tokenType(leg))
            );

            // collected from Uniswap
            uint256 settledTokens = s_settledTokens[chunkKey].add(collectedByLeg[leg]);

            int256 legPremia = premiaByLeg[leg];

            // (will be) paid by long legs
            if (tokenId.isLong(leg) == 1) {
                settledTokens = uint256(int256(settledTokens).sub(legPremia));
                realizedPremia = realizedPremia.add(legPremia);
            } else {
                uint256 positionLiquidity = PanopticMath
                    .getLiquidityChunk(tokenId, leg, positionSize, tickSpacing)
                    .liquidity();

                uint256 grossPremiumLast = s_grossPremiumLast[chunkKey];

                // new totalLiquidity (total sold) = removedLiquidity + netLiquidity (T - R)
                uint256 totalLiquidity = _getTotalLiquidity(tokenId, leg, tickSpacing);
                // T (totalLiquidity is (T - R) after burning)
                uint256 totalLiquidityBefore = totalLiquidity + positionLiquidity;

                uint256 availablePremium = _getAvailablePremium(
                    totalLiquidity + positionLiquidity,
                    settledTokens,
                    grossPremiumLast,
                    uint256(legPremia),
                    premiumAccumulatorsByLeg[leg]
                );

                // subtract settled tokens sent to seller
                settledTokens = settledTokens.sub(availablePremium);

                // add available premium to amount that should be settled
                realizedPremia = realizedPremia.add(int256(availablePremium));

                // We need to adjust the grossPremiumLast value such that the result of
                // (grossPremium - adjustedGrossPremiumLast)*updatedTotalLiquidityPostBurn/2**64 is equal to
                // (grossPremium - grossPremiumLast)*totalLiquidityBeforeBurn/2**64 - premiumOwedToPosition
                // G: total gross premium (- premiumOwedToPosition)
                // T: totalLiquidityBeforeMint
                // R: positionLiquidity
                // C: current grossPremium value
                // L: current grossPremiumLast value
                // Ln: updated grossPremiumLast value
                // T * (C - L) = G
                // (T - R) * (C - Ln) = G - P
                //
                // T * (C - L) = (T - R) * (C - Ln) + P
                // (TC - TL - P) / (T - R) = C - Ln
                // Ln = C - (TC - TL - P) / (T - R)
                // Ln = (TC - CR - TC + LT + P) / (T-R)
                // Ln = (LT - CR + P) / (T-R)

                unchecked {
                    uint256[2][4] memory _premiumAccumulatorsByLeg = premiumAccumulatorsByLeg;
                    uint256 _leg = leg;

                    // if there's still liquidity, compute the new grossPremiumLast
                    // otherwise, we just reset grossPremiumLast to the current grossPremium
                    s_grossPremiumLast[chunkKey] = totalLiquidity != 0
                        ? uint256(0)
                            .toRightSlot(
                                uint128(
                                    uint256(
                                        Math.max(
                                            (int256(
                                                grossPremiumLast.rightSlot() * totalLiquidityBefore
                                            ) -
                                                int256(
                                                    _premiumAccumulatorsByLeg[_leg][0] *
                                                        positionLiquidity
                                                )) + int256(legPremia.rightSlot() * 2 ** 64),
                                            0
                                        )
                                    ) / totalLiquidity
                                )
                            )
                            .toLeftSlot(
                                uint128(
                                    uint256(
                                        Math.max(
                                            (int256(
                                                grossPremiumLast.leftSlot() * totalLiquidityBefore
                                            ) -
                                                int256(
                                                    _premiumAccumulatorsByLeg[_leg][1] *
                                                        positionLiquidity
                                                )) + int256(legPremia.leftSlot()) * 2 ** 64,
                                            0
                                        )
                                    ) / totalLiquidity
                                )
                            )
                        : uint256(0)
                            .toRightSlot(uint128(premiumAccumulatorsByLeg[_leg][0]))
                            .toLeftSlot(uint128(premiumAccumulatorsByLeg[_leg][1]));
                }
            }

            // update settled tokens in storage with all local deltas
            s_settledTokens[chunkKey] = settledTokens;

            unchecked {
                ++leg;
            }
        }
    }
}
