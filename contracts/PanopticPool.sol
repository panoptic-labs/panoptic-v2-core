// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;
// Interfaces
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {ISemiFungiblePositionManager} from "@contracts/interfaces/ISemiFungiblePositionManager.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";
// Inherited implementations
import {Clone} from "clones-with-immutable-args/Clone.sol";
import {Multicall} from "@base/Multicall.sol";
// Libraries
import {Constants} from "@libraries/Constants.sol";
import {EfficientHash} from "@libraries/EfficientHash.sol";
import {Errors} from "@libraries/Errors.sol";
import {InteractionHelper} from "@libraries/InteractionHelper.sol";
import {Math} from "@libraries/Math.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
// Custom types
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";
import {RiskParameters} from "@types/RiskParameters.sol";
import {TokenId} from "@types/TokenId.sol";
import {OraclePack, OraclePackLibrary} from "@types/OraclePack.sol";

/// @title The Panoptic Pool: Create permissionless options on a CLAMM.
/// @author Axicon Labs Limited
/// @notice Manages positions, collateral, liquidations and forced exercises.
contract PanopticPool is Clone, Multicall {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an account is liquidated.
    /// @param liquidator Address of the caller liquidating the distressed account
    /// @param liquidatee Address of the distressed/liquidatable account
    /// @param bonusAmounts LeftRight encoding for the the bonus paid for token 0 (right slot) and 1 (left slot) to the liquidator
    event AccountLiquidated(
        address indexed liquidator,
        address indexed liquidatee,
        LeftRightSigned bonusAmounts
    );

    /// @notice Emitted when a position is force exercised.
    /// @param exercisor Address of the account that forces the exercise of the position
    /// @param user Address of the owner of the liquidated position
    /// @param tokenId TokenId of the liquidated position
    /// @param exerciseFee LeftRight encoding for the cost paid by the exercisor to force the exercise of the token;
    /// the cost for token 0 (right slot) and 1 (left slot) is represented as negative
    event ForcedExercised(
        address indexed exercisor,
        address indexed user,
        TokenId indexed tokenId,
        LeftRightSigned exerciseFee
    );

    /// @notice Emitted when premium is settled independent of a mint/burn (e.g. during `settlePremium`).
    /// @param user Address of the owner of the settled position
    /// @param tokenId TokenId of the settled position
    /// @param legIndex The leg index of `tokenId` that the premium was settled for
    /// @param settledAmounts LeftRight encoding for the amount of premium settled for token0 (right slot) and token1 (left slot)
    event PremiumSettled(
        address indexed user,
        TokenId indexed tokenId,
        uint256 legIndex,
        LeftRightSigned settledAmounts
    );

    /// @notice Emitted when an option is burned.
    /// @param recipient User that burnt the option
    /// @param positionSize The number of contracts burnt, expressed in terms of the asset
    /// @param tokenId TokenId of the burnt option
    /// @param premiaByLeg LeftRight packing for the amount of premia settled for token0 (right) and token1 (left) for each leg of `tokenId`
    event OptionBurnt(
        address indexed recipient,
        uint128 positionSize,
        TokenId indexed tokenId,
        LeftRightSigned[4] premiaByLeg
    );

    /// @notice Emitted when an option is minted.
    /// @param recipient User that minted the option
    /// @param tokenId TokenId of the created option
    /// @param balanceData The `PositionBalance` data for `tokenId` containing the number of contracts, pool utilizations, and ticks at mint
    event OptionMinted(
        address indexed recipient,
        TokenId indexed tokenId,
        PositionBalance balanceData
    );

    /*//////////////////////////////////////////////////////////////
                         IMMUTABLES & CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Lower price bound used when no slippage check is required.
    int24 internal constant MIN_SWAP_TICK = Constants.MIN_POOL_TICK - 1;

    /// @notice Upper price bound used when no slippage check is required.
    int24 internal constant MAX_SWAP_TICK = Constants.MAX_POOL_TICK + 1;

    /// @notice Flag that signals to compute premia for both the short and long legs of a position.
    bool internal constant COMPUTE_PREMIA_AS_COLLATERAL = true;

    /// @notice Flag that indicates only to include the share of (settled) premium that is available to collect when calling `_calculateAccumulatedPremia`.
    bool internal constant ONLY_AVAILABLE_PREMIUM = false;

    /// @notice Flag that signals to commit both collected Uniswap fees and settled long premium to `s_settledTokens`.
    bool internal constant COMMIT_LONG_SETTLED = true;
    /// @notice Flag that signals to only commit collected Uniswap fees to `s_settledTokens`.
    bool internal constant DONOT_COMMIT_LONG_SETTLED = false;

    /// @notice Flag for `_checkSolvency` to indicate that an account should be solvent at all input ticks.
    bool internal constant ASSERT_SOLVENCY = true;

    /// @notice Flag for `_checkSolvency` to indicate that an account should be insolvent at all input ticks.
    bool internal constant ASSERT_INSOLVENCY = false;

    /// @notice Flag that signals to add a new position to the user's positions hash (as opposed to removing an existing position).
    bool internal constant ADD = true;

    /// @notice The maximum allowed number of legs across all open positions for a user.
    uint64 internal constant MAX_OPEN_LEGS = 25;

    /// @notice Multiplier for the collateral requirement in the general case.
    uint24 internal constant NO_BUFFER = 10_000_000;

    /// @notice Decimals for computation (1 bps (1 basis point) precision: 0.01%).
    /// @dev uint type for composability with unsigned integer based mathematical operations.
    uint256 internal constant DECIMALS = 10_000;

    /// @notice Transient storage slot for the tick price
    bytes32 internal constant PRICE_TRANSIENT_SLOT = keccak256("panoptic.price.snapshot");

    /// @notice The "engine" of Panoptic - manages AMM liquidity and executes all mints/burns/exercises.
    ISemiFungiblePositionManager internal immutable SFPM;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Stores a sorted set of 8 price observations used to compute the internal median oracle price.
    // The data for the last 8 interactions is stored as such:
    //
    //    timestamp      orderMap      spotEMA      fastEMA       slowEMA      eonsEMA      reference         r7           r6                      r0
    // |<- 24 bits ->|<- 24 bits ->|<- 22 bits ->|>- 22 bits ->|<- 22 bits >|<- 22 bits ->|<- 24 bits ->|<- 12bits ->|<- 12 bits ->|<- ... ->|<- 12 bits ->|
    //
    // LAST UPDATED BLOCK TIMESTAMP (22 bits) -> 22 bits (use 28 bits for the timestamp and truncate the lower 6 bits to create a 64s epoch-based timekeeping)
    // [BLOCK.TIMESTAMP]
    // (0000000000000000000000) // dynamic
    //
    // ORDERING of tick indices least --> greatest (24 bits)
    // The value of the bit codon ([#]) is a pointer to a tick index in the tick array.
    // The position of the bit codon from most to least significant is the ordering of the
    // tick index it points to from least to greatest.
    //
    // rank:  0   1   2   3   4   5   6   7
    // slot: [7] [5] [3] [1] [0] [2] [4] [6]
    //       111 101 011 001 000 010 100 110
    //
    // [-512] [7]
    // 111000000000
    //
    // [512] [0]
    // 001000000000
    //
    // [-512] [6]
    // 111000000000
    //
    // [512] [1]
    // 001000000000
    //
    // [-512] [5]
    // 111000000000
    //
    // [512] [2]
    // 001000000000
    //
    // [0 = CURRENT TICK] [4]
    // (000000000000) // dynamic
    //
    // [0 = CURRENT TICK] [3]
    // (000000000000) // dynamic
    OraclePack internal s_oraclePack;

    // ERC4626 vaults that users collateralize their positions with
    // Each token has its own vault, listed in the same order as the tokens in the pool
    // In addition to collateral deposits, these vaults also handle various collateral/bonus/exercise computations

    /// @notice Nested mapping that tracks the option formation: address => tokenId => leg => premiaGrowth.
    /// @dev Premia growth is taking a snapshot of the chunk premium in SFPM, which is measuring the amount of fees
    /// collected for every chunk per unit of liquidity (net or short, depending on the isLong value of the specific leg index).
    mapping(address => mapping(TokenId => LeftRightUnsigned[4])) internal s_options;

    /// @notice Per-chunk `last` value that gives the aggregate amount of premium owed to all sellers when multiplied by the total amount of liquidity `totalLiquidity`.
    /// @dev `totalGrossPremium = totalLiquidity * (grossPremium(perLiquidityX64) - lastGrossPremium(perLiquidityX64)) / 2**64`
    /// @dev Used to compute the denominator for the fraction of premium available to sellers to collect.
    /// @dev LeftRight - right slot is token0, left slot is token1.
    mapping(bytes32 chunkKey => LeftRightUnsigned lastGrossPremium) internal s_grossPremiumLast;

    /// @notice Per-chunk accumulator for tokens owed to sellers that have been settled and are now available.
    /// @dev This number increases when buyers pay long premium and when tokens are collected from Uniswap.
    /// @dev It decreases when sellers close positions and collect the premium they are owed.
    /// @dev LeftRight - right slot is token0, left slot is token1.
    mapping(bytes32 chunkKey => LeftRightUnsigned settledTokens) internal s_settledTokens;

    /// @notice Tracks the position size of a tokenId for a given user, and the pool utilizations and oracle tick values at the time of last mint.
    //    <-- 24 bits --> <-- 24 bits --> <-- 24 bits --> <-- 24 bits --> <-- 16 bits --> <-- 16 bits --> <-- 128 bits -->
    //   latestTick         medianTick       spotTick       currentTick     utilization1    utilization0    positionSize
    mapping(address account => mapping(TokenId tokenId => PositionBalance positionBalance))
        internal s_positionBalance;

    /// @notice Tracks the position list hash (i.e `keccak256(XORs of abi.encodePacked(positionIdList))`).
    /// @dev A component of this hash also tracks the total number of legs across all positions (i.e. makes sure the length of the provided positionIdList matches).
    /// @dev The purpose of this system is to reduce storage usage when a user has more than one active position.
    /// @dev Instead of having to manage an unwieldy storage array and do lots of loads, we just store a hash of the array.
    /// @dev This hash can be cheaply verified on every operation with a user provided positionIdList - which can then be used for operations
    /// without having to every load any other data from storage.
    //      numLegs                   user positions hash
    //  |<-- 8 bits -->|<------------------ 248 bits ------------------->|
    //  |<---------------------- 256 bits ------------------------------>|
    mapping(address account => uint256 positionsHash) internal s_positionsHash;

    /*//////////////////////////////////////////////////////////////
                   POOL-SPECIFIC IMMUTABLE PARAMETERS
    //////////////////////////////////////////////////////////////*/

    // The parameters will be encoded in calldata at `_getImmutableArgsOffset()` as follows:
    // abi.encodePacked(address collateralToken0, address collateralToken1, address oracleContract, uint256 poolId, abi.encode(PoolKey poolKey))
    // bytes: 0                    20                   40                   60                   92
    //        |<---- 160 bits ---->|<---- 160 bits ---->|<---- 160 bits ---->|<---- 160 bits ---->|<---- 64 bits ---->|<---- 1280 bits ---->|
    //           collateralToken0     collateralToken1       riskEngine             poolManager          poolId             poolKey

    /// @notice Get the collateral token corresponding to token0 of the Uniswap pool.
    /// @return Collateral token corresponding to token0 in Uniswap
    function collateralToken0() public pure returns (CollateralTracker) {
        return CollateralTracker(_getArgAddress(0));
    }

    /// @notice Get the collateral token corresponding to token1 of the Uniswap pool.
    /// @return Collateral token corresponding to token1 in Uniswap
    function collateralToken1() public pure returns (CollateralTracker) {
        return CollateralTracker(_getArgAddress(20));
    }

    /// @notice Get the address of the risk engine contract used by this Panoptic Pool.
    /// @return The risk engine contract used by this Panoptic Pool
    function riskEngine() public pure returns (IRiskEngine) {
        return IRiskEngine(_getArgAddress(40));
    }

    /// @notice Retrieve the PoolManager associated with that CollateralTracker.
    /// @dev stored as zero if not a Uniswap v4 pool
    /// @return The PoolManager instance associated with that CollateralTracker's uniswap V4 pool
    function poolManager() public pure returns (address) {
        return address(_getArgAddress(60));
    }

    /// @notice Get the Uniswap Pool ID for the Uniswap pool used by this Panoptic.
    /// @return The Pool ID for this Panoptic Pool
    function poolId() public pure returns (uint64) {
        return uint64(_getArgUint64(80));
    }

    /// @notice Get the pool key for the Uniswap pool used by this Panoptic Pool.
    /// @dev For Uniswap v3, this is the address of the UniswapV3Pool
    /// @dev For Uniswap v4, this is Pool Key
    /// @dev For any other AMMs, this is assumed to be an address
    /// @return key The Pool Key for this Panoptic Pool.
    function poolKey() public pure returns (bytes calldata key) {
        uint256 offset = _getImmutableArgsOffset();
        uint256 start = offset + 88;
        uint256 len;
        assembly {
            len := sub(sub(calldatasize(), start), 2)
            key.offset := start
            key.length := len
        }
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts if the associated Risk Engine is not the caller.
    modifier onlyRiskEngine() {
        _onlyRiskEngine();
        _;
    }

    function _onlyRiskEngine() internal view {
        if (msg.sender != address(riskEngine())) revert Errors.NotGuardian();
    }

    /// @notice Force safe mode lock: effective safe mode must be treated as level 3.
    function lockSafeMode() external onlyRiskEngine {
        s_oraclePack = s_oraclePack.lock();
    }

    /// @notice Remove forced safe mode lock.
    function unlockSafeMode() external onlyRiskEngine {
        s_oraclePack = s_oraclePack.unlock();
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Store the address of the canonical SemiFungiblePositionManager (SFPM) contract.
    /// @param _sfpm The address of the SFPM
    constructor(ISemiFungiblePositionManager _sfpm) {
        SFPM = _sfpm;
    }

    /// @notice Initializes the median oracle of a new `PanopticPool` instance with median oracle state and performs initial token approvals.
    /// @dev Must be called first (by the factory contract) before any transaction can occur.
    function initialize() external {
        // reverts if this contract has already been initialized (assuming block.timestamp > 0)
        if (OraclePack.unwrap(s_oraclePack) != 0) revert Errors.PoolAlreadyInitialized();

        int24 currentTick = getCurrentTick();

        // Store the median data
        uint96 EMAs = OraclePackLibrary.packEMAs(
            currentTick,
            currentTick,
            currentTick,
            currentTick
        );
        s_oraclePack = OraclePackLibrary.storeOraclePack(
            block.timestamp >> 6,
            0xf590a6, // orderMap
            EMAs,
            currentTick,
            0xe00200e00200e00200e00000, // current residuals
            0,
            0
        );
        /*
            (uint256((block.timestamp >> 6) % 2 ** 24) << 232) +
            // magic number which adds (7,5,3,1,0,2,4,6) order and minTick in positions 7, 5, 3 and maxTick in 6, 4, 2
            // see comment on s_oraclePack initialization for format of this magic number
            (uint256(0xf590a60000000000000000000000000000800e00200e00200e00000000)) +
            // eonsEMA at bits 207-186
            (uint256(uint24(currentTick) & 0x3FFFFF) << 186) +
            // slowEMA at bits 185-164
            (uint256(uint24(currentTick) & 0x3FFFFF) << 164) +
            // fastEMA at bits 163-142
            (uint256(uint24(currentTick) & 0x3FFFFF) << 142) +
            // spotEMA at bits 141-120
            (uint256(uint24(currentTick) & 0x3FFFFF) << 120) +
            // store currentTick as the reference tick at bits 119-96
            (uint256(uint24(currentTick)) << 96);
           */

        // consolidate all 4 approval calls to one library delegatecall in order to reduce bytecode size
        // approves:
        // SFPM: token0, token1
        // CollateralTracker0 - token0
        // CollateralTracker1 - token1
        InteractionHelper.doApprovals(
            SFPM,
            collateralToken0(),
            collateralToken1(),
            collateralToken0().token0(),
            collateralToken0().token1(),
            poolManager()
        );
    }

    /*//////////////////////////////////////////////////////////////
                              EIP SUPPORT
    //////////////////////////////////////////////////////////////*/

    // note: this contract does not need to accept batch ERC1155 transfers from the SFPM or supply ERC-165 calls
    // thus, `supportsInterface` and `onERC1155BatchReceived` are left unimplemented to reduce contract size

    /// @notice Returns magic value when called by the `SemiFungiblePositionManager` contract to indicate that this contract supports ERC1155.
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                             QUERY HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts if the caller has a lower collateral balance than required to meet the provided `minValue0` and `minValue1`.
    /// @dev Can be used for composable slippage checks with `multicall` (such as for a force exercise or liquidation).
    /// @param minValue0 The minimum acceptable `token0` value of collateral
    /// @param minValue1 The minimum acceptable `token1` value of collateral
    function assertMinCollateralValues(uint256 minValue0, uint256 minValue1) external view {
        CollateralTracker ct0 = collateralToken0();
        CollateralTracker ct1 = collateralToken1();
        if (ct0.assetsOf(msg.sender) < minValue0 || ct1.assetsOf(msg.sender) < minValue1)
            revert Errors.AccountInsolvent(0, 0);
    }

    /// @notice Determines if account is eligible to withdraw or transfer collateral.
    /// @dev Checks whether account is solvent with `BP_DECREASE_BUFFER` according to `_validateSolvency`.
    /// @dev Prevents insolvent and near-insolvent accounts from withdrawing collateral before they are liquidated.
    /// @dev Reverts if account is not solvent with `BP_DECREASE_BUFFER`.
    /// @param user The account to check for collateral withdrawal eligibility
    /// @param positionIdList The list of all option positions held by `user`
    /// @param usePremiaAsCollateral Whether to compute accumulated premia for all legs held by the user for collateral (true), or just owed premia for long legs (false)
    function validateCollateralWithdrawable(
        address user,
        TokenId[] calldata positionIdList,
        bool usePremiaAsCollateral
    ) external view {
        (RiskParameters riskParameters, ) = getRiskParameters(0);
        _validateSolvency(
            user,
            positionIdList,
            riskParameters.bpDecreaseBuffer(),
            usePremiaAsCollateral,
            0
        );
    }

    /// @notice Returns the total amount of premium accumulated for a list of positions and a list containing the corresponding `PositionBalance` information for each position.
    /// @param user Address of the user that owns the positions
    /// @param positionIdList List of positions. Written as `[tokenId1, tokenId2, ...]`
    /// @param includePendingPremium If true, include premium that is owed to the user but has not yet settled; if false, only include premium that is available to collect
    /// @return The total amount of premium owed (which may `includePendingPremium`) to the short legs in `positionIdList` (token0: right slot, token1: left slot)
    /// @return The total amount of premium owed by the long legs in `positionIdList` (token0: right slot, token1: left slot)
    /// @return A list of `PositionBalance` data (balance and pool utilization/oracle ticks at last mint) for each position, of the form `[PositionBalance_0, PositionBalance_1, ...]`
    function getAccumulatedFeesAndPositionsData(
        address user,
        bool includePendingPremium,
        TokenId[] calldata positionIdList
    ) external view returns (LeftRightUnsigned, LeftRightUnsigned, PositionBalance[] memory) {
        // Get the current tick of the Uniswap pool
        int24 currentTick = getCurrentTick();
        // Compute the accumulated premia for all tokenId in positionIdList (includes short+long premium)
        return
            _calculateAccumulatedPremia(
                user,
                positionIdList,
                COMPUTE_PREMIA_AS_COLLATERAL,
                includePendingPremium,
                currentTick
            );
    }

    /// @notice Calculate the accumulated premia owed from the option buyer to the option seller.
    /// @param user The holder of options
    /// @param positionIdList The list of all option positions held by user
    /// @param usePremiaAsCollateral Whether to compute accumulated premia for all legs held by the user for collateral (true), or just owed premia for long legs (false)
    /// @param includePendingPremium If true, include premium that is owed to the user but has not yet settled; if false, only include premium that is available to collect
    /// @param atTick The current tick of the Uniswap pool
    /// @return shortPremium The total amount of premium owed (which may `includePendingPremium`) to the short legs in `positionIdList` (token0: right slot, token1: left slot)
    /// @return longPremium The total amount of premium owed by the long legs in `positionIdList` (token0: right slot, token1: left slot)
    /// @return balances A list of balances and pool utilization for each position, of the form `[[tokenId0, balances0], [tokenId1, balances1], ...]`
    function _calculateAccumulatedPremia(
        address user,
        TokenId[] calldata positionIdList,
        bool usePremiaAsCollateral,
        bool includePendingPremium,
        int24 atTick
    )
        internal
        view
        returns (
            LeftRightUnsigned shortPremium,
            LeftRightUnsigned longPremium,
            PositionBalance[] memory balances
        )
    {
        uint256 pLength = positionIdList.length;
        balances = new PositionBalance[](pLength);

        address c_user = user;
        // loop through each option position/tokenId
        for (uint256 k = 0; k < pLength; ) {
            TokenId tokenId = positionIdList[k];

            {
                PositionBalance positionBalanceData = s_positionBalance[c_user][tokenId];
                if (positionBalanceData.positionSize() == 0) revert Errors.PositionNotOwned();

                balances[k] = positionBalanceData;
            }
            (
                LeftRightSigned[4] memory premiaByLeg,
                uint256[2][4] memory premiumAccumulatorsByLeg
            ) = _getPremia(
                    tokenId,
                    balances[k].positionSize(),
                    c_user,
                    usePremiaAsCollateral,
                    atTick
                );

            uint256 numLegs = tokenId.countLegs();
            for (uint256 leg = 0; leg < numLegs; ) {
                if (tokenId.width(leg) != 0) {
                    if (tokenId.isLong(leg) == 0) {
                        if (!includePendingPremium) {
                            bytes32 chunkKey = PanopticMath.getChunkKey(tokenId, leg);

                            (uint256 totalLiquidity, , ) = _getLiquidities(tokenId, leg);
                            shortPremium = shortPremium.add(
                                _getAvailablePremium(
                                    totalLiquidity,
                                    s_settledTokens[chunkKey],
                                    s_grossPremiumLast[chunkKey],
                                    LeftRightUnsigned.wrap(
                                        uint256(LeftRightSigned.unwrap(premiaByLeg[leg]))
                                    ),
                                    premiumAccumulatorsByLeg[leg]
                                )
                            );
                        } else {
                            shortPremium = shortPremium.add(
                                LeftRightUnsigned.wrap(
                                    uint256(LeftRightSigned.unwrap(premiaByLeg[leg]))
                                )
                            );
                        }
                    } else {
                        longPremium = LeftRightUnsigned.wrap(
                            uint256(
                                LeftRightSigned.unwrap(
                                    LeftRightSigned
                                        .wrap(int256(LeftRightUnsigned.unwrap(longPremium)))
                                        .sub(premiaByLeg[leg])
                                )
                            )
                        );
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

    /*//////////////////////////////////////////////////////////////
                          ONBOARD MEDIAN TWAP
    //////////////////////////////////////////////////////////////*/

    /// @notice Updates the internal oracle.
    function pokeOracle() external {
        int24 currentTick = getCurrentTick();

        (, OraclePack oraclePack) = riskEngine().computeInternalMedian(s_oraclePack, currentTick);

        if (OraclePack.unwrap(oraclePack) != 0) s_oraclePack = oraclePack;
    }

    /*//////////////////////////////////////////////////////////////
                          MINT/BURN INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints or burns each `tokenId` in `positionIdList.
    /// @param positionIdList The list of tokenIds for the option positions to be minted or burnt
    /// @param finalPositionIdList The final positionIdList after all the tokens have been minted/burnt
    /// @param positionSizes The list of positionSize for the position to be minted (0 for burns)
    /// @param tickAndSpreadLimits A Nx3 array containing: the lower [0] and upper [1] bounds of an acceptable open interval for the ending price, and the maximum amount of "spread" defined as `removedLiquidity/netLiquidity` for a new position and
    /// denominated as X10_000 = (`ratioLimit * 10_000`)
    /// @param usePremiaAsCollateral Whether to compute accumulated premia for all legs held by the user for collateral (true), or just owed premia for long legs (false)
    /// @param builderCode The builder code for fee distribution
    function dispatch(
        TokenId[] calldata positionIdList,
        TokenId[] calldata finalPositionIdList,
        uint128[] calldata positionSizes,
        int24[3][] calldata tickAndSpreadLimits,
        bool usePremiaAsCollateral,
        uint256 builderCode
    ) external {
        // if safeMode, enforce covered at mint and exercise at burn
        RiskParameters riskParameters;

        LeftRightSigned cumulativeTickDeltas;
        {
            //assembly tload
            bytes32 slot = PRICE_TRANSIENT_SLOT;
            assembly {
                cumulativeTickDeltas := tload(slot)
            }
        }
        {
            int24 startTick;
            (riskParameters, startTick) = getRiskParameters(builderCode);

            if (cumulativeTickDeltas.rightSlot() == 0) {
                // initializes +1 sentinel
                cumulativeTickDeltas = LeftRightSigned.wrap(0).addToRightSlot(1).addToLeftSlot(
                    startTick
                );
            } else {
                cumulativeTickDeltas = LeftRightSigned
                    .wrap(0)
                    .addToRightSlot(
                        cumulativeTickDeltas.rightSlot() +
                            int128(Math.abs(int24(cumulativeTickDeltas.leftSlot()) - startTick))
                    )
                    .addToLeftSlot(startTick);
            }
        }
        for (uint256 i = 0; i < positionIdList.length; ) {
            TokenId tokenId = positionIdList[i];

            // make sure the tokenId is for this Panoptic pool
            if (tokenId.poolId() != poolId()) revert Errors.WrongPoolId();

            PositionBalance positionBalanceData = s_positionBalance[msg.sender][tokenId];

            int24[2] memory _tickLimits;
            _tickLimits[0] = tickAndSpreadLimits[i][0];
            _tickLimits[1] = tickAndSpreadLimits[i][1];

            // if safe mode is larger than 1, mandate all positions to be minted/burnt as covered
            if (riskParameters.safeMode() > 1) {
                if (_tickLimits[0] > _tickLimits[1]) {
                    (_tickLimits[0], _tickLimits[1]) = (_tickLimits[1], _tickLimits[0]);
                }
            }
            int24 finalTick;
            if (PositionBalance.unwrap(positionBalanceData) == 0) {
                // revert if more than 2 conditions are triggered to prevent the minting of any positions
                if (riskParameters.safeMode() > 2) revert Errors.StaleOracle();
                uint24 effectiveLiquidityLimit = uint24(tickAndSpreadLimits[i][2]);
                (, finalTick) = _mintOptions(
                    tokenId,
                    positionSizes[i],
                    effectiveLiquidityLimit,
                    msg.sender,
                    _tickLimits,
                    riskParameters
                );
            } else {
                uint128 positionSize = positionBalanceData.positionSize();

                if (positionSize == 0) revert Errors.PositionNotOwned();

                // if input positionSize matches the size stored, this is a settlePremium. Otherwise, this is a burn.
                if (positionSize == positionSizes[i]) {
                    finalTick = getCurrentTick();
                    _settleOptions(msg.sender, tokenId, positionSize, riskParameters, finalTick);
                } else {
                    (, , finalTick) = _burnOptions(
                        tokenId,
                        positionSize,
                        _tickLimits,
                        msg.sender,
                        COMMIT_LONG_SETTLED,
                        riskParameters
                    );
                }
            }

            unchecked {
                // update starting tick in leftSlot() and add the cumulative delta to the rightSlot()
                // can never miscast because ticks are int24
                cumulativeTickDeltas = LeftRightSigned
                    .wrap(0)
                    .addToRightSlot(
                        cumulativeTickDeltas.rightSlot() +
                            int128(Math.abs(int24(cumulativeTickDeltas.leftSlot()) - finalTick))
                    )
                    .addToLeftSlot(finalTick);
                ++i;
            }
        }

        unchecked {
            // can never overflow as tickDeltaLiquidation is a int24
            /// @dev revert if the total deviation is more than twice the tickDeltaLiquidation (ie. roundtrips more than the allowed tick liquidation delta per trip)
            if (
                cumulativeTickDeltas.rightSlot() >
                int256(uint256(2 * riskParameters.tickDeltaLiquidation()))
            ) revert Errors.PriceImpactTooLarge();

            {
                //assembly tstore
                bytes32 slot = PRICE_TRANSIENT_SLOT;
                assembly {
                    tstore(slot, cumulativeTickDeltas)
                }
            }
        }
        // Perform solvency check on user's account to ensure they had enough buying power to mint the option
        // Add an initial buffer to the collateral requirement to prevent users from minting their account close to insolvency
        OraclePack oraclePack = _validateSolvency(
            msg.sender,
            finalPositionIdList,
            riskParameters.bpDecreaseBuffer(),
            usePremiaAsCollateral,
            riskParameters.safeMode()
        );
        // Update `s_oraclePack` with a new observation if the last observation is old enough (returned oraclePack is nonzero)
        if (OraclePack.unwrap(oraclePack) != 0) s_oraclePack = oraclePack;
    }

    /*//////////////////////////////////////////////////////////////
                         POSITION MINTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates the current options of the user, and mints a new position.
    /// @param tokenId The tokenId of the newly minted position
    /// @param positionSize The size of the position to be minted, expressed in terms of the asset
    /// @param effectiveLiquidityLimit Maximum amount of "spread" defined as `removedLiquidity/netLiquidity` for a new position and
    /// denominated as X32 = (`ratioLimit * 2^32`)
    /// @param owner The owner of the option position to be minted
    /// @param tickLimits The lower and upper bound of an acceptable open interval for the ending price
    /// @param riskParameters The RiskEngine's core parameters
    function _mintOptions(
        TokenId tokenId,
        uint128 positionSize,
        uint24 effectiveLiquidityLimit,
        address owner,
        int24[2] memory tickLimits,
        RiskParameters riskParameters
    ) internal returns (LeftRightSigned paidAmounts, int24 finalTick) {
        // Mint in the SFPM and update state of collateral
        LeftRightUnsigned[4] memory collectedByLeg;
        LeftRightSigned netAmmDelta;
        (collectedByLeg, netAmmDelta, finalTick) = SFPM.mintTokenizedPosition(
            poolKey(),
            tokenId,
            positionSize,
            tickLimits[0],
            tickLimits[1]
        );

        _updateSettlementPostMint(
            riskParameters,
            tokenId,
            collectedByLeg,
            positionSize,
            effectiveLiquidityLimit,
            owner
        );

        uint32 poolUtilizations;

        (poolUtilizations, paidAmounts) = _payCommissionAndWriteData(
            tokenId,
            positionSize,
            owner,
            netAmmDelta,
            riskParameters
        );

        {
            // update the users options balance of position `tokenId`
            // NOTE: user can't mint same position multiple times, so set the positionSize instead of adding
            PositionBalance balanceData = PositionBalanceLibrary.storeBalanceData(
                positionSize,
                poolUtilizations,
                0
            );
            s_positionBalance[owner][tokenId] = balanceData;

            emit OptionMinted(owner, tokenId, balanceData);
        }
    }

    /// @notice Take the commission fees for minting `tokenId` and settle any other required collateral deltas.
    /// @param tokenId The option position
    /// @param positionSize The size of the position, expressed in terms of the asset
    /// @param owner The owner of the option position to be minted
    /// @param netAmmDelta The amount of tokens moved during creation of the option position
    /// @param riskParameters The RiskEngine's core parameters
    /// @return utilizations Packing of the pool utilization (how much funds are in the Panoptic pool versus the AMM pool at the time of minting),
    /// right 64bits for token0 and left 64bits for token1, defined as `(inAMM * 10_000) / totalAssets()`
    /// where totalAssets is the total tracked assets in the AMM and PanopticPool minus fees and donations to the Panoptic pool
    /// @return paidAmounts The amount of tokens paid when creating that option for token0 (right) and token1 (left)
    function _payCommissionAndWriteData(
        TokenId tokenId,
        uint128 positionSize,
        address owner,
        LeftRightSigned netAmmDelta,
        RiskParameters riskParameters
    ) internal returns (uint32 utilizations, LeftRightSigned paidAmounts) {
        // compute how much of tokenId is long and short positions
        (LeftRightSigned longAmounts, LeftRightSigned shortAmounts) = PanopticMath
            .computeExercisedAmounts(tokenId, positionSize, true);
        {
            (uint32 utilization0, int128 paid0) = collateralToken0().settleMint(
                owner,
                longAmounts.rightSlot(),
                shortAmounts.rightSlot(),
                netAmmDelta.rightSlot(),
                riskParameters
            );
            utilizations = utilization0;
            paidAmounts = paidAmounts.addToRightSlot(paid0);
        }
        {
            (uint32 utilization1, int128 paid1) = collateralToken1().settleMint(
                owner,
                longAmounts.leftSlot(),
                shortAmounts.leftSlot(),
                netAmmDelta.leftSlot(),
                riskParameters
            );
            unchecked {
                // no miscast because utilization is <=10_000
                utilizations += uint32(utilization1 << 16);
            }
            paidAmounts = paidAmounts.addToLeftSlot(paid1);
        }

        // return pool utilizations as two uint16 (pool Utilization is always <= 10_000)
        return (utilizations, paidAmounts);
    }

    /*//////////////////////////////////////////////////////////////
                         POSITION BURNING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Close all options in `positionIdList`.
    /// @param owner The owner of the option position to be closed
    /// @param tickLimitLow The lower bound of an acceptable open interval for the ending price on each option close
    /// @param tickLimitHigh The upper bound of an acceptable open interval for the ending price on each option close
    /// @param commitLongSettled Whether to commit the long premium that will be settled to storage (disabled during liquidations)
    /// @param positionIdList The list of option positions to close
    /// @return netPaid The net amount of tokens paid after closing the positions
    /// @return premiasByLeg The amount of premia settled by the user for each leg of the position
    function _burnAllOptionsFrom(
        address owner,
        int24 tickLimitLow,
        int24 tickLimitHigh,
        bool commitLongSettled,
        TokenId[] calldata positionIdList
    ) internal returns (LeftRightSigned netPaid, LeftRightSigned[4][] memory premiasByLeg) {
        premiasByLeg = new LeftRightSigned[4][](positionIdList.length);
        (RiskParameters riskParameters, ) = getRiskParameters(0);

        for (uint256 i = 0; i < positionIdList.length; ) {
            uint128 positionSize = s_positionBalance[owner][positionIdList[i]].positionSize();

            if (positionSize == 0) revert Errors.PositionNotOwned();

            int24[2] memory tickLimits;
            tickLimits[0] = tickLimitLow;
            tickLimits[1] = tickLimitHigh;
            LeftRightSigned paidAmounts;
            address _owner = owner;
            (paidAmounts, premiasByLeg[i], ) = _burnOptions(
                positionIdList[i],
                positionSize,
                tickLimits,
                _owner,
                commitLongSettled,
                riskParameters
            );
            netPaid = netPaid.add(paidAmounts);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Close a single option position.
    /// @param tokenId The option position to burn
    /// @param positionSize The size of the position to burn
    /// @param tickLimits The lower and upper bound of an acceptable open interval for the ending price on each option close
    /// @param owner The owner of the option position to be burned
    /// @param commitLongSettled Whether to commit the long premium that will be settled to storage (disabled during liquidations)
    /// @param riskParameters The RiskEngine's core risk parameters
    /// @return paidAmounts The net amount of tokens paid after closing the position
    /// @return premiaByLeg The amount of premia settled by the user for each leg of the position
    /// @return finalTick The final tick after burning the options
    function _burnOptions(
        TokenId tokenId,
        uint128 positionSize,
        int24[2] memory tickLimits,
        address owner,
        bool commitLongSettled,
        RiskParameters riskParameters
    )
        internal
        returns (
            LeftRightSigned paidAmounts,
            LeftRightSigned[4] memory premiaByLeg,
            int24 finalTick
        )
    {
        LeftRightUnsigned[4] memory collectedByLeg;
        LeftRightSigned netAmmDelta;
        (collectedByLeg, netAmmDelta, finalTick) = SFPM.burnTokenizedPosition(
            poolKey(),
            tokenId,
            positionSize,
            tickLimits[0],
            tickLimits[1]
        );

        LeftRightSigned realizedPremia;
        (realizedPremia, premiaByLeg) = _updateSettlementPostBurn(
            owner,
            tokenId,
            collectedByLeg,
            positionSize,
            riskParameters,
            LeftRightSigned.wrap(commitLongSettled ? int128(1) : int128(0))
        );

        (LeftRightSigned longAmounts, LeftRightSigned shortAmounts) = PanopticMath
            .computeExercisedAmounts(tokenId, positionSize, false);

        emit OptionBurnt(owner, positionSize, tokenId, premiaByLeg);

        RiskParameters _rp = riskParameters;
        {
            int128 paid0 = collateralToken0().settleBurn(
                owner,
                longAmounts.rightSlot(),
                shortAmounts.rightSlot(),
                netAmmDelta.rightSlot(),
                realizedPremia.rightSlot(),
                _rp
            );
            paidAmounts = paidAmounts.addToRightSlot(paid0);
        }

        {
            int128 paid1 = collateralToken1().settleBurn(
                owner,
                longAmounts.leftSlot(),
                shortAmounts.leftSlot(),
                netAmmDelta.leftSlot(),
                realizedPremia.leftSlot(),
                _rp
            );
            paidAmounts = paidAmounts.addToLeftSlot(paid1);
        }
    }

    /// @notice Validates the solvency of `user`.
    /// @dev Falls back to the most conservative (least solvent) oracle tick if the sum of the squares of the deltas between all oracle ticks exceeds `MAX_TICKS_DELTA^2`, defined in the RiskEngine.
    /// @dev Effectively, this means that the users must be solvent at all oracle ticks if the at least one of the ticks is sufficiently stale.
    /// @param user The account to validate
    /// @param positionIdList The list of positions to validate solvency for
    /// @param buffer The buffer to apply to the collateral requirement for `user`
    /// @param usePremiaAsCollateral Whether to compute accumulated premia for all legs held by the user for collateral (true), or just owed premia for long legs (false)
    /// @return If nonzero (enough time has passed since last observation), the updated value for `s_oraclePack` with a new observation
    function _validateSolvency(
        address user,
        TokenId[] calldata positionIdList,
        uint32 buffer,
        bool usePremiaAsCollateral,
        uint8 safeMode
    ) internal view returns (OraclePack) {
        // check that the provided positionIdList matches the positions in memory
        _validatePositionList(user, positionIdList);

        int24 currentTick = getCurrentTick();

        OraclePack oraclePack;
        int24[] memory atTicks;

        (atTicks, oraclePack) = riskEngine().getSolvencyTicks(currentTick, s_oraclePack);

        if (positionIdList.length != 0) {
            uint256 solvent = _checkSolvencyAtTicks(
                user,
                safeMode,
                positionIdList,
                currentTick,
                atTicks,
                usePremiaAsCollateral,
                uint256(buffer)
            );
            uint256 numberOfTicks = atTicks.length;

            if (solvent != numberOfTicks) revert Errors.AccountInsolvent(solvent, numberOfTicks);
        }
        return oraclePack;
    }

    /*//////////////////////////////////////////////////////////////
                          SETTLEMENTS
    //////////////////////////////////////////////////////////////*/

    function _settleOptions(
        address owner,
        TokenId tokenId,
        uint128 positionSize,
        RiskParameters riskParameters,
        int24 currentTick
    ) internal {
        // call _updateSettlementPostBurn to settle the long premia or the short premia (only for self calling)
        LeftRightUnsigned[4] memory emptyCollectedByLegs;
        LeftRightSigned realizedPremia;
        unchecked {
            // cannot be miscast because currentTick is a int24
            (realizedPremia, ) = _updateSettlementPostBurn(
                owner,
                tokenId,
                emptyCollectedByLegs,
                positionSize,
                riskParameters,
                LeftRightSigned.wrap(1).addToLeftSlot(1 + (int128(currentTick) << 2))
            );
        }
        // deduct the paid premium tokens from the owner's balance
        collateralToken0().settleBurn(owner, 0, 0, 0, realizedPremia.rightSlot(), riskParameters);
        collateralToken1().settleBurn(owner, 0, 0, 0, realizedPremia.leftSlot(), riskParameters);
    }

    /// @notice Adds collected tokens to `s_settledTokens` and adjusts `s_grossPremiumLast` for any liquidity added.
    /// @dev Always called after `mintTokenizedPosition`.
    /// @param tokenId The option position that was minted
    /// @param collectedByLeg The amount of tokens collected in the corresponding chunk for each leg of the position
    /// @param positionSize The size of the position, expressed in terms of the asset
    /// @param effectiveLiquidityLimit Maximum amount of "spread" defined as `removedLiquidity/netLiquidity`
    /// @param owner The owner of the option position to be minted
    function _updateSettlementPostMint(
        RiskParameters riskParameters,
        TokenId tokenId,
        LeftRightUnsigned[4] memory collectedByLeg,
        uint128 positionSize,
        uint24 effectiveLiquidityLimit,
        address owner
    ) internal {
        // ADD the current tokenId to the position list hash (hash = XOR of all keccak256(tokenId))
        // and increase the number of positions counter by 1.
        _updatePositionsHash(owner, tokenId, ADD, riskParameters.maxLegs());

        for (uint256 leg = 0; leg < tokenId.countLegs(); ) {
            if (tokenId.width(leg) != 0) {
                uint256 isLong = tokenId.isLong(leg);
                // if position is long, ensure that removed liquidity does not deplete strike beyond min(MAX_SPREAD, user-provided effectiveLiquidityLimit)
                // new totalLiquidity (total sold) = removedLiquidity + netLiquidity (R + N)
                uint256 totalLiquidity = _checkLiquiditySpread(
                    tokenId,
                    leg,
                    isLong == 0
                        ? riskParameters.maxSpread()
                        : Math.min(effectiveLiquidityLimit, riskParameters.maxSpread())
                );

                bytes32 chunkKey = PanopticMath.getChunkKey(tokenId, leg);

                // add any tokens collected from Uniswap in a given chunk to the settled tokens available for withdrawal by sellers
                s_settledTokens[chunkKey] = s_settledTokens[chunkKey].add(collectedByLeg[leg]);

                LiquidityChunk liquidityChunk = PanopticMath.getLiquidityChunk(
                    tokenId,
                    leg,
                    positionSize
                );

                uint256 grossCurrent0;
                uint256 grossCurrent1;
                {
                    {
                        uint256 tokenType = tokenId.tokenType(leg);
                        uint256 vegoid = tokenId.vegoid();
                        uint256 _isLong = isLong;
                        // can use (type(int24).max flag because premia accumulators were updated during the mintTokenizedPosition step.
                        (grossCurrent0, grossCurrent1) = SFPM.getAccountPremium(
                            poolKey(),
                            address(this),
                            tokenType,
                            liquidityChunk.tickLower(),
                            liquidityChunk.tickUpper(),
                            type(int24).max,
                            _isLong,
                            vegoid
                        );
                    }

                    s_options[owner][tokenId][leg] = LeftRightUnsigned
                        .wrap(uint128(grossCurrent0))
                        .addToLeftSlot(uint128(grossCurrent1));
                }

                // if position is short, adjust `grossPremiumLast` upward to account for the increase in short liquidity
                if (isLong == 0) {
                    unchecked {
                        // L
                        LeftRightUnsigned grossPremiumLast = s_grossPremiumLast[chunkKey];
                        // R
                        uint256 positionLiquidity = liquidityChunk.liquidity();
                        // T (totalLiquidity is (T + R) after minting)
                        uint256 totalLiquidityBefore = totalLiquidity - positionLiquidity;

                        // We need to adjust the grossPremiumLast value such that the result of
                        // (grossPremium - adjustedGrossPremiumLast) * updatedTotalLiquidityPostMint / 2**64 is equal to (grossPremium - grossPremiumLast) * totalLiquidityBeforeMint / 2**64
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

                        s_grossPremiumLast[chunkKey] = LeftRightUnsigned
                            .wrap(
                                uint128(
                                    (grossCurrent0 *
                                        positionLiquidity +
                                        grossPremiumLast.rightSlot() *
                                        totalLiquidityBefore) / totalLiquidity
                                )
                            )
                            .addToLeftSlot(
                                uint128(
                                    (grossCurrent1 *
                                        positionLiquidity +
                                        grossPremiumLast.leftSlot() *
                                        totalLiquidityBefore) / totalLiquidity
                                )
                            );
                    }
                }
            }
            unchecked {
                ++leg;
            }
        }
    }

    /// @notice Updates settled tokens and grossPremiumLast for a chunk after a burn and returns premium info.
    /// @param owner The owner of the option position that was burnt
    /// @param tokenId The option position that was burnt
    /// @param collectedByLeg The amount of tokens collected in the corresponding chunk for each leg of the position
    /// @param positionSize The size of the position, expressed in terms of the asset
    /// @param commitLongSettledAndKeepOpen Whether to commit the long premium that will be settled to storage (rightSlot != 0) and whether the position is being burned (leftSlot == 0)
    /// @return realizedPremia The amount of premia settled by the user
    /// @return premiaByLeg The amount of premia settled by the user for each leg of the position
    function _updateSettlementPostBurn(
        address owner,
        TokenId tokenId,
        LeftRightUnsigned[4] memory collectedByLeg,
        uint128 positionSize,
        RiskParameters riskParameters,
        LeftRightSigned commitLongSettledAndKeepOpen
    ) internal returns (LeftRightSigned realizedPremia, LeftRightSigned[4] memory premiaByLeg) {
        uint256[2][4] memory premiumAccumulatorsByLeg;

        // compute accumulated fees
        (premiaByLeg, premiumAccumulatorsByLeg) = _getPremia(
            tokenId,
            positionSize,
            owner,
            COMPUTE_PREMIA_AS_COLLATERAL,
            commitLongSettledAndKeepOpen.leftSlot() == 0
                ? type(int24).max
                : int24(commitLongSettledAndKeepOpen.leftSlot() >> 2)
        );
        for (uint256 leg = 0; leg < tokenId.countLegs(); ) {
            if (tokenId.width(leg) != 0) {
                LeftRightSigned legPremia = premiaByLeg[leg];
                bytes32 chunkKey = PanopticMath.getChunkKey(tokenId, leg);

                // collected from Uniswap
                LeftRightUnsigned settledTokens = s_settledTokens[chunkKey].add(
                    collectedByLeg[leg]
                );

                // (will be) paid by long legs
                if (tokenId.isLong(leg) == 1) {
                    if (commitLongSettledAndKeepOpen.rightSlot() != 0)
                        settledTokens = LeftRightUnsigned.wrap(
                            uint256(
                                LeftRightSigned.unwrap(
                                    LeftRightSigned
                                        .wrap(int256(LeftRightUnsigned.unwrap(settledTokens)))
                                        .sub(legPremia)
                                )
                            )
                        );
                    realizedPremia = realizedPremia.add(legPremia);
                } else {
                    if (commitLongSettledAndKeepOpen.leftSlot() == 0 || msg.sender == owner) {
                        uint256 positionLiquidity;
                        uint256 totalLiquidity;
                        {
                            LiquidityChunk liquidityChunk = PanopticMath.getLiquidityChunk(
                                tokenId,
                                leg,
                                positionSize
                            );
                            positionLiquidity = liquidityChunk.liquidity();

                            // if position is short, ensure that removed liquidity does not deplete strike beyond MAX_SPREAD when closed
                            // new totalLiquidity (total sold) = removedLiquidity + netLiquidity (T - R)
                            totalLiquidity = _checkLiquiditySpread(
                                tokenId,
                                leg,
                                riskParameters.maxSpread()
                            );
                        }
                        // T (totalLiquidity is (T - R) after burning)
                        uint256 totalLiquidityBefore;
                        unchecked {
                            // cannot overflow because total liquidity is less than uint128
                            totalLiquidityBefore = commitLongSettledAndKeepOpen.leftSlot() == 0
                                ? totalLiquidity + positionLiquidity
                                : totalLiquidity;
                        }
                        LeftRightUnsigned grossPremiumLast = s_grossPremiumLast[chunkKey];

                        LeftRightUnsigned availablePremium = _getAvailablePremium(
                            totalLiquidityBefore,
                            settledTokens,
                            grossPremiumLast,
                            LeftRightUnsigned.wrap(uint256(LeftRightSigned.unwrap(legPremia))),
                            premiumAccumulatorsByLeg[leg]
                        );

                        // subtract settled tokens sent to seller
                        settledTokens = settledTokens.sub(availablePremium);

                        // add available premium to amount that should be settled
                        realizedPremia = realizedPremia.add(
                            LeftRightSigned.wrap(int256(LeftRightUnsigned.unwrap(availablePremium)))
                        );

                        // update the base `premiaByLeg` value to reflect the amount of premium that will actually be settled
                        premiaByLeg[leg] = LeftRightSigned.wrap(
                            int256(LeftRightUnsigned.unwrap(availablePremium))
                        );

                        // We need to adjust the grossPremiumLast value such that the result of
                        // (grossPremium - adjustedGrossPremiumLast) * updatedTotalLiquidityPostBurn / 2**64 is equal to
                        // (grossPremium - grossPremiumLast) * totalLiquidityBeforeBurn / 2**64 - premiumOwedToPosition
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
                            uint256[2][4]
                                memory _premiumAccumulatorsByLeg = premiumAccumulatorsByLeg;
                            uint256 _leg = leg;

                            // if there's still liquidity, compute the new grossPremiumLast
                            // otherwise, we just reset grossPremiumLast to the current grossPremium
                            s_grossPremiumLast[chunkKey] = totalLiquidity != 0
                                ? LeftRightUnsigned
                                    .wrap(
                                        uint128(
                                            uint256(
                                                Math.max(
                                                    (int256(
                                                        grossPremiumLast.rightSlot() *
                                                            totalLiquidityBefore
                                                    ) -
                                                        int256(
                                                            _premiumAccumulatorsByLeg[_leg][0] *
                                                                positionLiquidity
                                                        )) +
                                                        int256(legPremia.rightSlot()) *
                                                        2 ** 64,
                                                    0
                                                )
                                            ) / totalLiquidity
                                        )
                                    )
                                    .addToLeftSlot(
                                        uint128(
                                            uint256(
                                                Math.max(
                                                    (int256(
                                                        grossPremiumLast.leftSlot() *
                                                            totalLiquidityBefore
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
                                : LeftRightUnsigned
                                    .wrap(uint128(premiumAccumulatorsByLeg[_leg][0]))
                                    .addToLeftSlot(uint128(premiumAccumulatorsByLeg[_leg][1]));
                        }
                    }
                }
                // update settled tokens in storage with all local deltas
                s_settledTokens[chunkKey] = settledTokens;

                if (commitLongSettledAndKeepOpen.leftSlot() == 0) {
                    // erase the s_options entry for that leg
                    s_options[owner][tokenId][leg] = LeftRightUnsigned.wrap(0);
                } else {
                    // update the premium accumulator to the latest value: only if it is a long leg (settleLongPremium) OR if owner == msg.sender (autocollect)
                    if (tokenId.isLong(leg) != 0 || msg.sender == owner) {
                        s_options[owner][tokenId][leg] = LeftRightUnsigned
                            .wrap(0)
                            .addToRightSlot(uint128(premiumAccumulatorsByLeg[leg][0]))
                            .addToLeftSlot(uint128(premiumAccumulatorsByLeg[leg][1]));

                        emit PremiumSettled(owner, tokenId, leg, premiaByLeg[leg]);
                    }
                }
            }

            unchecked {
                ++leg;
            }
        }

        if (commitLongSettledAndKeepOpen.leftSlot() == 0) {
            // reset balances and delete stored option data
            s_positionBalance[owner][tokenId] = PositionBalance.wrap(0);

            // REMOVE the current tokenId from the position list hash (hash = XOR of all keccak256(tokenId), remove by XOR'ing again)
            // and decrease the number of positions counter by 1.
            _updatePositionsHash(owner, tokenId, !ADD, riskParameters.maxLegs());
        }
    }

    /*//////////////////////////////////////////////////////////////
                    LIQUIDATIONS & FORCED EXERCISES
    //////////////////////////////////////////////////////////////*/

    /// @notice Dispatches liquidations, forced exercises, or long premium settlements based on account solvency
    /// @dev This function determines the appropriate action based on solvency checks at multiple price points:
    ///      - If insolvent at all ticks: Execute liquidation (burns all positions)
    ///      - If solvent at all ticks: Execute force exercise or settle long premium based on list lengths
    ///      - Otherwise: Revert as account is not fully margin called
    /// @dev The function uses position list lengths to determine the specific operation:
    ///      - Same length lists between positionIdListTo and positionIdListToFinal: Settle long premium
    ///      - Final list one shorter: Force exercise
    ///      - Final list empty: Liquidation
    /// @param positionIdListFrom List of positions held by the caller (msg.sender)
    /// @param account The account being acted upon (liquidated, exercised, or settled)
    /// @param positionIdListTo Current positions of the target account
    /// @param positionIdListToFinal Expected positions after the operation completes
    /// @param usePremiaAsCollateral Packed value indicating whether to use premia as collateral:
    ///        - leftSlot: For the caller (msg.sender)
    ///        - rightSlot: For the target account
    function dispatchFrom(
        TokenId[] calldata positionIdListFrom,
        address account,
        TokenId[] calldata positionIdListTo,
        TokenId[] calldata positionIdListToFinal,
        LeftRightUnsigned usePremiaAsCollateral
    ) external payable {
        // Assert the account we are liquidating is actually insolvent
        int24 twapTick = getTWAP();
        int24 currentTick = getCurrentTick();

        TokenId tokenId;

        uint256 solvent;
        uint256 numberOfTicks;
        {
            _validatePositionList(account, positionIdListTo);

            // Enforce maximum delta between TWAP and currentTick to prevent extreme price manipulation
            int24 spotTick;
            int24 latestTick;
            (spotTick, , latestTick, ) = riskEngine().getOracleTicks(currentTick, s_oraclePack);

            unchecked {
                (RiskParameters riskParameters, ) = getRiskParameters(0);
                int256 MAX_TWAP_DELTA_LIQUIDATION = int256(
                    uint256(riskParameters.tickDeltaLiquidation())
                );
                if (Math.abs(currentTick - twapTick) > MAX_TWAP_DELTA_LIQUIDATION)
                    revert Errors.StaleOracle();
            }

            // Ensure the account is insolvent at twapTick (in place of medianTick), currentTick, spotTick, and latestTick
            int24[] memory atTicks = new int24[](4);
            atTicks[0] = spotTick;
            atTicks[1] = twapTick;
            atTicks[2] = latestTick;
            atTicks[3] = currentTick;

            solvent = _checkSolvencyAtTicks(
                account,
                0,
                positionIdListTo,
                currentTick,
                atTicks,
                COMPUTE_PREMIA_AS_COLLATERAL,
                NO_BUFFER
            );
            numberOfTicks = atTicks.length;
        }
        {
            uint256 toLength = positionIdListTo.length;
            uint256 finalLength = positionIdListToFinal.length;
            // if account is solvent at all ticks, this is a force exercise or a settlePremium.
            if (solvent == numberOfTicks) {
                unchecked {
                    tokenId = positionIdListTo[toLength - 1];
                    if (toLength == finalLength) {
                        // same length, that's a settle
                        {
                            bytes32 toHash = EfficientHash.efficientKeccak256(
                                abi.encodePacked(positionIdListTo)
                            );
                            bytes32 finalHash = EfficientHash.efficientKeccak256(
                                abi.encodePacked(positionIdListToFinal)
                            );
                            if (toHash != finalHash) {
                                revert Errors.InputListFail();
                            }
                        }
                        _settlePremium(account, tokenId, twapTick, currentTick);
                    } else if (toLength == (finalLength + 1)) {
                        // final is one element shorter, that's a force exercise
                        if (tokenId.countLongs() == 0 || tokenId.validateIsExercisable() == 0)
                            revert Errors.NoLegsExercisable();
                        _forceExercise(account, tokenId, twapTick, currentTick);
                    } else if (finalLength == 0) {
                        // if final length was zero, this was intended to be liquidation, but revert because not margin called and solvent at some of the tested ticks
                        revert Errors.NotMarginCalled();
                    } else {
                        // otherwise, wrong input lists
                        revert Errors.InputListFail();
                    }
                    // ensure the callee is still solvent after the operation
                    bool premiaAsCollateral = usePremiaAsCollateral.rightSlot() > 0;
                    _validateSolvency(
                        account,
                        positionIdListToFinal,
                        NO_BUFFER,
                        premiaAsCollateral,
                        0
                    );
                }
            } else if (solvent == 0) {
                // if account is insolvent at all ticks, this is a liquidation

                // if the positions lengths are the same, this was intended as a settlePremia, but revert because account is insolvent
                if (toLength == finalLength) revert Errors.AccountInsolvent(solvent, 4);

                if (positionIdListToFinal.length != 0) revert Errors.InputListFail();
                // if the final position list has a non-zero length, this can't be a complete liquidation, revert
                _liquidate(account, positionIdListTo, twapTick, currentTick);
            } else {
                // otherwise, revert because the account is not fully margin called
                revert Errors.NotMarginCalled();
            }
        }

        // ensure the caller is still solvent after the operation
        _validateSolvency(
            msg.sender,
            positionIdListFrom,
            NO_BUFFER,
            usePremiaAsCollateral.leftSlot() > 0,
            0
        );
    }

    /// @notice Liquidates a distressed account. Will burn all positions and issue a bonus to the liquidator.
    /// @dev Will revert if liquidated account is solvent at one of the oracle ticks or if TWAP tick is too far away from the current tick.
    /// @param liquidatee Address of the distressed account
    /// @param positionIdList List of positions owned by the user. Written as `[tokenId1, tokenId2, ...]`
    function _liquidate(
        address liquidatee,
        TokenId[] calldata positionIdList,
        int24 twapTick,
        int24 currentTick
    ) internal {
        LeftRightUnsigned tokenData0;
        LeftRightUnsigned tokenData1;
        LeftRightUnsigned shortPremium;
        {
            PositionBalance[] memory positionBalanceArray = new PositionBalance[](
                positionIdList.length
            );
            LeftRightUnsigned longPremium;
            (shortPremium, longPremium, positionBalanceArray) = _calculateAccumulatedPremia(
                liquidatee,
                positionIdList,
                COMPUTE_PREMIA_AS_COLLATERAL,
                ONLY_AVAILABLE_PREMIUM,
                currentTick
            );
            (tokenData0, tokenData1, ) = riskEngine().getMargin(
                positionBalanceArray,
                twapTick,
                liquidatee,
                positionIdList,
                shortPremium,
                longPremium,
                collateralToken0(),
                collateralToken1()
            );
        }

        // The protocol delegates some virtual shares to ensure the burn can be settled.
        collateralToken0().delegate(liquidatee);
        collateralToken1().delegate(liquidatee);

        LeftRightSigned bonusAmounts;
        LeftRightUnsigned haircutTotal;
        {
            LeftRightSigned netPaid;
            LeftRightSigned[4][] memory premiasByLeg;
            // burn all options from the liquidatee

            // Do not commit any settled long premium to storage - we will do this after we determine if any long premium must be revoked
            // This is to prevent any short positions the liquidatee has being settled with tokens that will later be revoked
            // NOTE: tick limits are not applied here since it is not the liquidator's position being liquidated
            (netPaid, premiasByLeg) = _burnAllOptionsFrom(
                liquidatee,
                MIN_SWAP_TICK,
                MAX_SWAP_TICK,
                DONOT_COMMIT_LONG_SETTLED,
                positionIdList
            );

            LeftRightSigned collateralRemaining;

            // compute bonus amounts using latest tick data
            (bonusAmounts, collateralRemaining) = riskEngine().getLiquidationBonus(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(twapTick),
                netPaid,
                shortPremium
            );

            // premia cannot be paid if there is protocol loss associated with the liquidatee
            // otherwise, an economic exploit could occur if the liquidator and liquidatee collude to
            // manipulate the fees in a liquidity area they control past the protocol loss threshold
            // such that the PLPs are forced to pay out premia to the liquidator
            // thus, we haircut any premium paid by the liquidatee (converting tokens as necessary) until the protocol loss is covered or the premium is exhausted
            // note that the haircutPremia function also commits the settled amounts (adjusted for the haircut) to storage, so it will be called even if there is no haircut

            // if premium is haircut from a token that is not in protocol loss, some of the liquidation bonus will be converted into that token
            address _liquidatee = liquidatee;
            int24 _twapTick = twapTick;
            TokenId[] memory _positionIdList = positionIdList;
            LeftRightSigned bonusDeltas;
            LeftRightSigned[4][] memory haircutPerLeg;
            (bonusDeltas, haircutTotal, haircutPerLeg) = riskEngine().haircutPremia(
                _liquidatee,
                _positionIdList,
                premiasByLeg,
                collateralRemaining,
                Math.getSqrtRatioAtTick(_twapTick)
            );

            bonusAmounts = bonusAmounts.add(bonusDeltas);

            InteractionHelper.settleAmounts(
                _liquidatee,
                _positionIdList,
                haircutTotal,
                haircutPerLeg,
                premiasByLeg,
                collateralToken0(),
                collateralToken1(),
                s_settledTokens
            );
        }

        // revoke delegated virtual shares and settle any bonus deltas with the liquidator
        // native currency is represented as address(0), so it will always be currency0 alphanumerically
        collateralToken0().settleLiquidation{value: msg.value}(
            msg.sender,
            liquidatee,
            bonusAmounts.rightSlot()
        );
        collateralToken1().settleLiquidation(msg.sender, liquidatee, bonusAmounts.leftSlot());

        emit AccountLiquidated(msg.sender, liquidatee, bonusAmounts);
    }

    /// @notice Force the exercise of a single position. Exercisor will have to pay a fee to the force exercisee.
    /// @param account Address of the distressed account
    /// @param tokenId The position to be force exercised; this position must contain at least one out-of-range long leg
    function _forceExercise(
        address account,
        TokenId tokenId,
        int24 twapTick,
        int24 currentTick
    ) internal {
        CollateralTracker ct0 = collateralToken0();
        CollateralTracker ct1 = collateralToken1();

        uint128 positionSize;

        LeftRightSigned exerciseFees;
        {
            PositionBalance positionBalance = s_positionBalance[account][tokenId];

            positionSize = positionBalance.positionSize();

            if (positionSize == 0) revert Errors.PositionNotOwned();

            // Compute the exerciseFee, this will decrease the further away the price is from the exercised position
            // Include any deltas in long legs between the current and oracle tick in the exercise fee
            exerciseFees = riskEngine().exerciseCost(
                currentTick,
                twapTick,
                tokenId,
                positionBalance
            );
        }

        // The protocol delegates some virtual shares to ensure the burn can be settled.
        ct0.delegate(account);
        ct1.delegate(account);
        {
            int24[2] memory tickLimits;
            tickLimits[0] = MIN_SWAP_TICK;
            tickLimits[1] = MAX_SWAP_TICK;
            (RiskParameters riskParameters, ) = getRiskParameters(0);

            // Exercise the option
            // Turn off ITM swapping to prevent swap at potentially unfavorable price
            _burnOptions(
                tokenId,
                positionSize,
                tickLimits,
                account,
                COMMIT_LONG_SETTLED,
                riskParameters
            );
        }
        // redistribute token composition of refund amounts if user doesn't have enough of one token to pay
        LeftRightSigned refundAmounts = riskEngine().getRefundAmounts(
            account,
            exerciseFees,
            twapTick,
            ct0,
            ct1
        );

        // settle difference between delegated amounts (from the protocol) and exercise fees/substituted tokens
        ct0.refund(account, msg.sender, refundAmounts.rightSlot());
        ct1.refund(account, msg.sender, refundAmounts.leftSlot());
        // revoke the virtual shares that were delegated after settling the difference with the exercisor
        ct0.revoke(account);
        ct1.revoke(account);

        emit ForcedExercised(msg.sender, account, tokenId, exerciseFees);
    }

    /// @notice Settle unpaid premium for one `legIndex` on a position owned by `owner`.
    /// @dev Called by sellers on buyers of their chunk to increase the available premium for withdrawal (before closing their position).
    /// @dev This feature is only available when `owner` is solvent and has the requisite tokens to settle the premium.
    /// @param owner The owner of the option position to make premium payments on
    /// @param tokenId The position to be force exercised; this position must contain at least one out-of-range long leg
    function _settlePremium(
        address owner,
        TokenId tokenId,
        int24 twapTick,
        int24 currentTick
    ) internal {
        CollateralTracker ct0 = collateralToken0();
        CollateralTracker ct1 = collateralToken1();

        // The protocol delegates some virtual shares to ensure the premia can be settled.
        ct0.delegate(owner);
        ct1.delegate(owner);

        (RiskParameters riskParameters, ) = getRiskParameters(0);
        uint128 positionSize = s_positionBalance[owner][tokenId].positionSize();
        if (positionSize == 0) revert Errors.PositionNotOwned();

        _settleOptions(owner, tokenId, positionSize, riskParameters, currentTick);

        LeftRightSigned refundAmounts = riskEngine().getRefundAmounts(
            owner,
            LeftRightSigned.wrap(0),
            twapTick,
            ct0,
            ct1
        );
        // allow the caller to settle tokens owed to the protocol by the settlee in exchange for the surplus token
        ct0.refund(owner, msg.sender, refundAmounts.rightSlot());
        ct1.refund(owner, msg.sender, refundAmounts.leftSlot());

        ct0.revoke(owner);
        ct1.revoke(owner);
    }

    /*//////////////////////////////////////////////////////////////
                            SOLVENCY CHECKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Check whether an account is solvent at a given `atTick` with a collateral requirement of `buffer/10_000` multiplied by the requirement of `positionIdList`.
    /// @dev Reverts if `account` is not solvent at all provided ticks and `expectedSolvent == true`, or if `account` is solvent at all ticks and `!expectedSolvent`.
    /// @param account The account to check solvency for
    /// @param safeMode The current safe mode status
    /// @param positionIdList The list of positions to check solvency for
    /// @param currentTick The current tick of the Uniswap pool (needed for fee calculations)
    /// @param atTicks An array of ticks to check solvency at
    /// @param buffer The buffer to apply to the collateral requirement
    /// @param usePremiaAsCollateral Whether to compute accumulated premia for all legs held by the user for collateral (true), or just owed premia for long legs (false)
    /// @return boolean flag that determines if account is solvent
    function _checkSolvencyAtTicks(
        address account,
        uint8 safeMode,
        TokenId[] calldata positionIdList,
        int24 currentTick,
        int24[] memory atTicks,
        bool usePremiaAsCollateral,
        uint256 buffer
    ) internal view returns (uint256) {
        (
            LeftRightUnsigned shortPremium,
            LeftRightUnsigned longPremium,
            PositionBalance[] memory positionBalanceArray
        ) = _calculateAccumulatedPremia(
                account,
                positionIdList,
                usePremiaAsCollateral,
                ONLY_AVAILABLE_PREMIUM,
                currentTick
            );

        // if safeMode is ON, make the collateral requirements for 100% utilizations: no cross-margining, fully covered positions
        if (safeMode > 0) {
            unchecked {
                // cannot miscast because DECIMAL = 10_000
                uint32 maxUtilizations = uint32(DECIMALS + (DECIMALS << 16));
                positionBalanceArray[0] = PositionBalanceLibrary.storeBalanceData(
                    positionBalanceArray[0].positionSize(),
                    maxUtilizations,
                    0
                );
            }
        }
        uint256 solvent;
        for (uint256 i; i < atTicks.length; ) {
            unchecked {
                if (
                    _isAccountSolvent(
                        account,
                        atTicks[i],
                        positionIdList,
                        positionBalanceArray,
                        shortPremium,
                        longPremium,
                        buffer
                    )
                ) ++solvent;

                ++i;
            }
        }

        return solvent;
    }

    /// @notice Check whether an account is solvent at a given `atTick` with a collateral requirement of `buffer/10_000` multiplied by the requirement of `positionBalanceArray`.
    /// @param account The account to check solvency for
    /// @param atTick The tick to check solvency at
    /// @param positionIdList The list of all option positions held by the user
    /// @param positionBalanceArray A list of balances and pool utilization for each position, of the form `[[tokenId0, balances0], [tokenId1, balances1], ...]`
    /// @param shortPremium The total amount of premium (prorated by available settled tokens) owed to the short legs of `account`
    /// @param longPremium The total amount of premium owed by the long legs of `account`
    /// @param buffer The buffer to apply to the collateral requirement
    /// @return Whether the account is solvent at the given tick
    function _isAccountSolvent(
        address account,
        int24 atTick,
        TokenId[] calldata positionIdList,
        PositionBalance[] memory positionBalanceArray,
        LeftRightUnsigned shortPremium,
        LeftRightUnsigned longPremium,
        uint256 buffer
    ) internal view returns (bool) {
        return
            riskEngine().isAccountSolvent(
                positionBalanceArray,
                positionIdList,
                atTick,
                account,
                shortPremium,
                longPremium,
                collateralToken0(),
                collateralToken1(),
                buffer
            );
    }

    /// @notice Get risk parameters from the risk engine.
    /// @dev Also checks whether the current tick has deviated too much from the previously stored ticks. Computed in the RiskEngine
    function getRiskParameters(
        uint256 builderCode
    ) public view returns (RiskParameters riskParameters, int24 currentTick) {
        currentTick = getCurrentTick();
        riskParameters = riskEngine().getRiskParameters(currentTick, s_oraclePack, builderCode);
    }

    /// @notice Checks whether the current tick has deviated too much from the previously stored ticks. Computed in the RiskEngine
    /// @return Whether the current tick has deviated too much to warrant putting the protocol in safe mode
    function isSafeMode() external view returns (uint8) {
        (RiskParameters riskParameters, ) = getRiskParameters(0);
        return riskParameters.safeMode();
    }

    /*//////////////////////////////////////////////////////////////
                 POSITIONS HASH GENERATION & VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Makes sure that the positions in the incoming user's list match the existing active option positions.
    /// @param account The owner of the incoming list of positions
    /// @param positionIdList The existing list of active options for the owner
    function _validatePositionList(
        address account,
        TokenId[] calldata positionIdList
    ) internal view {
        uint256 pLength = positionIdList.length;

        uint256 fingerprintIncomingList;

        // verify it has no duplicated elements
        if (!PanopticMath.hasNoDuplicateTokenIds(positionIdList)) {
            revert Errors.DuplicateTokenId();
        }

        uint64 _poolId = poolId();
        for (uint256 i = 0; i < pLength; ) {
            TokenId tokenId = positionIdList[i];
            // make sure the tokenId is for this Panoptic pool
            if (tokenId.poolId() != _poolId) revert Errors.WrongPoolId();

            fingerprintIncomingList = PanopticMath.updatePositionsHash(
                fingerprintIncomingList,
                tokenId,
                ADD
            );
            unchecked {
                ++i;
            }
        }

        // revert if fingerprint for provided `_positionIdList` does not match the one stored for the `_account`
        if (fingerprintIncomingList != s_positionsHash[account]) revert Errors.InputListFail();
    }

    /// @notice Updates the hash for all positions owned by an account. This fingerprints the list of all incoming options with a single hash.
    /// @dev The outcome of this function will be to update the hash of positions.
    /// This is done as a duplicate/validation check of the incoming list O(N).
    /// @dev The positions hash is stored as the XOR of the keccak256 of each tokenId. Updating will XOR the existing hash with the new tokenId.
    /// The same update can either add a new tokenId (when minting an option), or remove an existing one (when burning it).
    /// @param account The owner of `tokenId`
    /// @param tokenId The option position
    /// @param addFlag Whether to add `tokenId` to the hash (true) or remove it (false)
    function _updatePositionsHash(
        address account,
        TokenId tokenId,
        bool addFlag,
        uint8 maxLegs
    ) internal {
        // Get the current position hash value (fingerprint of all pre-existing positions created by `_account`)
        // Add the current tokenId to the positionsHash as XOR'd
        // since 0 ^ x = x, no problem on first mint
        // Store values back into the user option details with the updated hash (leaves the other parameters unchanged)
        uint256 newHash = PanopticMath.updatePositionsHash(
            s_positionsHash[account],
            tokenId,
            addFlag
        );
        if ((newHash >> 248) > maxLegs) revert Errors.TooManyLegsOpen();
        s_positionsHash[account] = newHash;
    }

    /*//////////////////////////////////////////////////////////////
                                QUERIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Computes and returns all oracle ticks.
    /// @return currentTick The current tick in the Uniswap pool
    /// @return spotTick The fast oracle tick, sourced from the internal 10-minute EMA.
    /// @return medianTick The slow oracle tick, calculated as the median of the 8 stored price points in the internal oracle.
    /// @return latestTick The reconstructed absolute tick of the latest observation stored in the internal oracle.
    /// @return oraclePack The current value of the 8-slot internal observation queue (`s_oraclePack`)
    function getOracleTicks()
        external
        view
        returns (
            int24 currentTick,
            int24 spotTick,
            int24 medianTick,
            int24 latestTick,
            OraclePack oraclePack
        )
    {
        currentTick = getCurrentTick();
        (spotTick, medianTick, latestTick, ) = riskEngine().getOracleTicks(
            currentTick,
            s_oraclePack
        );
        oraclePack = s_oraclePack;
    }

    /// @notice Get the current number of legs across all open positions for an account.
    /// @param user The account to query
    /// @return Number of legs across the open positions of `user`
    function numberOfLegs(address user) external view returns (uint256) {
        return s_positionsHash[user] >> 248;
    }

    /// @notice Get the `tokenId` position data for `user`.
    /// @param user The account that owns `tokenId`
    /// @param tokenId The position to query
    /// @return `currentTick` at mint
    /// @return Fast oracle tick at mint
    /// @return Slow oracle tick at mint
    /// @return Last observed tick at mint
    /// @return Utilization of token0 at mint
    /// @return Utilization of token1 at mint
    /// @return Size of the position
    function positionData(
        address user,
        TokenId tokenId
    ) external view returns (int24, int24, int24, int24, int256, int256, uint128) {
        return s_positionBalance[user][tokenId].unpackAll();
    }

    /// @notice Get the oracle price used to check solvency in liquidations.
    /// @return twapTick The current oracle price used to check solvency in liquidations
    function getTWAP() public view returns (int24 twapTick) {
        twapTick = riskEngine().twapEMA(s_oraclePack);
    }

    /// @notice Get the current tick of the underlying pool.
    function getCurrentTick() public view returns (int24 currentTick) {
        currentTick = SFPM.getCurrentTick(poolKey());
    }

    /*//////////////////////////////////////////////////////////////
                  PREMIA & PREMIA SPREAD CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensure the effective liquidity in a given chunk is above a certain threshold.
    /// @param tokenId An option position
    /// @param leg A leg index of `tokenId` corresponding to a tickLower-tickUpper chunk
    /// @param effectiveLiquidityLimit Maximum amount of "spread" defined as removedLiquidity/netLiquidity for a new position
    /// denominated as X10_000 = (`ratioLimit * 10_000`)
    /// @return totalLiquidity The total liquidity deposited in that chunk: `totalLiquidity = netLiquidity + removedLiquidity`
    function _checkLiquiditySpread(
        TokenId tokenId,
        uint256 leg,
        uint256 effectiveLiquidityLimit
    ) internal view returns (uint256 totalLiquidity) {
        uint256 netLiquidity;
        uint256 removedLiquidity;
        (totalLiquidity, netLiquidity, removedLiquidity) = _getLiquidities(tokenId, leg);

        // compute and return effective liquidity. Return if short=net=0, which is closing short position
        if (netLiquidity == 0 && removedLiquidity == 0) return totalLiquidity;

        if (netLiquidity == 0) revert Errors.NetLiquidityZero();

        uint256 effectiveLiquidityFactor;
        unchecked {
            // cannot overflow because liquidities are uint128
            effectiveLiquidityFactor = (removedLiquidity * DECIMALS) / netLiquidity;
        }

        // put a limit on how much new liquidity in one transaction can be deployed into this leg
        // the effective liquidity measures how many times more the newly added liquidity is compared to the existing/base liquidity
        if (effectiveLiquidityFactor > effectiveLiquidityLimit)
            revert Errors.EffectiveLiquidityAboveThreshold();
    }

    /// @notice Compute the premia collected for a single option position `tokenId`.
    /// @param tokenId The option position
    /// @param positionSize The number of contracts (size) of the option position
    /// @param owner The holder of the tokenId option
    /// @param usePremiaAsCollateral Whether to compute accumulated premia for all legs held by the user for collateral (true), or just owed premia for long legs (false)
    /// @param atTick The tick at which the premia is calculated -> use (`atTick < type(int24).max`) to compute it
    /// up to current block. `atTick = type(int24).max` will only consider fees as of the last on-chain transaction
    /// @return premiaByLeg The amount of premia owed to the user for each leg of the position
    /// @return premiumAccumulatorsByLeg The amount of premia accumulated for each leg of the position
    function _getPremia(
        TokenId tokenId,
        uint128 positionSize,
        address owner,
        bool usePremiaAsCollateral,
        int24 atTick
    )
        internal
        view
        returns (
            LeftRightSigned[4] memory premiaByLeg,
            uint256[2][4] memory premiumAccumulatorsByLeg
        )
    {
        uint256 numLegs = tokenId.countLegs();
        for (uint256 leg = 0; leg < numLegs; ) {
            uint256 isLong = tokenId.isLong(leg);
            if (tokenId.width(leg) != 0 && (isLong == 1 || usePremiaAsCollateral)) {
                LiquidityChunk liquidityChunk = PanopticMath.getLiquidityChunk(
                    tokenId,
                    leg,
                    positionSize
                );
                {
                    uint256 vegoid = tokenId.vegoid();
                    uint256 tokenType = tokenId.tokenType(leg);
                    int24 _atTick = atTick;
                    (premiumAccumulatorsByLeg[leg][0], premiumAccumulatorsByLeg[leg][1]) = SFPM
                        .getAccountPremium(
                            poolKey(),
                            address(this),
                            tokenType,
                            liquidityChunk.tickLower(),
                            liquidityChunk.tickUpper(),
                            _atTick,
                            isLong,
                            vegoid
                        );
                }
                unchecked {
                    LeftRightUnsigned premiumAccumulatorLast = s_options[owner][tokenId][leg];
                    premiaByLeg[leg] = LeftRightSigned
                        .wrap(0)
                        .addToRightSlot(
                            int128(
                                int256(
                                    ((premiumAccumulatorsByLeg[leg][0] -
                                        premiumAccumulatorLast.rightSlot()) *
                                        (liquidityChunk.liquidity())) / 2 ** 64
                                )
                            )
                        )
                        .addToLeftSlot(
                            int128(
                                int256(
                                    ((premiumAccumulatorsByLeg[leg][1] -
                                        premiumAccumulatorLast.leftSlot()) *
                                        (liquidityChunk.liquidity())) / 2 ** 64
                                )
                            )
                        );
                }

                if (isLong == 1) {
                    premiaByLeg[leg] = LeftRightSigned.wrap(0).sub(premiaByLeg[leg]);
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

    /// @notice Query the amount of premium available for withdrawal given a certain `premiumOwed` for a chunk.
    /// @dev Based on the ratio between `settledTokens` and the total premium owed to sellers in a chunk.
    /// @dev The ratio is capped at 1 (as the base ratio can be greater than one if some seller forfeits enough premium).
    /// @param totalLiquidity The updated total liquidity amount for the chunk
    /// @param settledTokens LeftRight accumulator for the amount of tokens that have been settled (collected or paid)
    /// @param grossPremiumLast The `last` values used with `premiumAccumulators` to compute the total premium owed to sellers
    /// @param premiumOwed The amount of premium owed to sellers in the chunk
    /// @param premiumAccumulators The current values of the premium accumulators for the chunk
    /// @return The amount of token0/token1 premium available for withdrawal
    function _getAvailablePremium(
        uint256 totalLiquidity,
        LeftRightUnsigned settledTokens,
        LeftRightUnsigned grossPremiumLast,
        LeftRightUnsigned premiumOwed,
        uint256[2] memory premiumAccumulators
    ) internal pure returns (LeftRightUnsigned) {
        unchecked {
            // long premium only accumulates as it is settled, so compute the ratio
            // of total settled tokens in a chunk to total premium owed to sellers and multiply
            // cap the ratio at 1 (it can be greater than one if some seller forfeits enough premium)
            uint256 accumulated0 = ((premiumAccumulators[0] - grossPremiumLast.rightSlot()) *
                totalLiquidity) / 2 ** 64;
            uint256 accumulated1 = ((premiumAccumulators[1] - grossPremiumLast.leftSlot()) *
                totalLiquidity) / 2 ** 64;

            return (
                LeftRightUnsigned
                    .wrap(
                        uint128(
                            Math.min(
                                (uint256(premiumOwed.rightSlot()) * settledTokens.rightSlot()) /
                                    (accumulated0 == 0 ? type(uint256).max : accumulated0),
                                premiumOwed.rightSlot()
                            )
                        )
                    )
                    .addToLeftSlot(
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

    /// @notice Query the total amount of liquidity sold in the corresponding chunk for a position leg.
    /// @dev totalLiquidity (total sold) = removedLiquidity + netLiquidity (in AMM).
    /// @param tokenId The option position
    /// @param leg The leg of the option position to get `totalLiquidity` for
    /// @return totalLiquidity The total amount of liquidity sold in the corresponding chunk for a position leg
    /// @return netLiquidity The amount of liquidity available in the corresponding chunk for a position leg
    /// @return removedLiquidity The amount of liquidity removed through buying in the corresponding chunk for a position leg
    function _getLiquidities(
        TokenId tokenId,
        uint256 leg
    )
        internal
        view
        returns (uint256 totalLiquidity, uint128 netLiquidity, uint128 removedLiquidity)
    {
        (int24 tickLower, int24 tickUpper) = tokenId.asTicks(leg);

        LeftRightUnsigned accountLiquidities = SFPM.getAccountLiquidity(
            poolKey(),
            address(this),
            tokenId.tokenType(leg),
            tickLower,
            tickUpper
        );

        netLiquidity = accountLiquidities.rightSlot();
        removedLiquidity = accountLiquidities.leftSlot();

        unchecked {
            totalLiquidity = netLiquidity + removedLiquidity;
        }
    }
}
