// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Interfaces
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";

// Custom types
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {PositionBalance} from "@types/PositionBalance.sol";
import {RiskParameters} from "@types/RiskParameters.sol";
import {TokenId} from "@types/TokenId.sol";
import {OraclePack} from "@types/OraclePack.sol";
import {MarketState} from "@types/MarketState.sol";

/// @title Panoptic Risk Engine Interface
/// @notice Interface for the central risk assessment and solvency calculator for the Panoptic Protocol.
interface IRiskEngine {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a borrow rate is updated.
    event BorrowRateUpdated(
        address indexed collateralToken,
        uint256 avgBorrowRate,
        uint256 rateAtTarget
    );

    /// @notice Emitted when tokens are collected from the contract
    /// @param token The address of the token collected
    /// @param recipient The address receiving the tokens
    /// @param amount The amount of tokens collected
    event TokensCollected(address indexed token, address indexed recipient, uint256 amount);

    /// @notice Emitted when the guardian updates the enforced safe mode.
    /// @param lockMode True when safe mode is forcibly locked, false when the lock is lifted.
    event GuardianSafeModeUpdated(bool lockMode);

    /*//////////////////////////////////////////////////////////////
                        PUBLIC STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Constant, in seconds, used to determine the max elapsed time between adaptive interest rate updates.
    function IRM_MAX_ELAPSED_TIME() external view returns (int256);

    /// @notice Curve steepness (scaled by WAD).
    function CURVE_STEEPNESS() external view returns (int256);

    /// @notice Minimum rate at target per second (scaled by WAD).
    function MIN_RATE_AT_TARGET() external view returns (int256);

    /// @notice Maximum rate at target per second (scaled by WAD).
    function MAX_RATE_AT_TARGET() external view returns (int256);

    /// @notice Target utilization (scaled by WAD).
    function TARGET_UTILIZATION() external view returns (int256);

    /// @notice Initial rate at target per second (scaled by WAD).
    function INITIAL_RATE_AT_TARGET() external view returns (int256);

    /// @notice Adjustment speed per second (scaled by WAD).
    function ADJUSTMENT_SPEED() external view returns (int256);

    /// @notice Address allowed to override the automatically computed safe mode.
    function GUARDIAN() external view returns (address);

    /*//////////////////////////////////////////////////////////////
                                GUARDIAN
    //////////////////////////////////////////////////////////////*/

    /// @notice Forces a PanopticPool into locked safe mode.
    /// @param pool The PanopticPool to lock.
    function lockPool(PanopticPool pool) external;

    /// @notice Removes the forced safe-mode lock on a PanopticPool.
    /// @param pool The PanopticPool to unlock.
    function unlockPool(PanopticPool pool) external;

    /*//////////////////////////////////////////////////////////////
                                TRANSFERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Collects a specific amount of tokens from this contract
    /// @param token The address of the ERC20 token to collect
    /// @param recipient The address to send the tokens to
    /// @param amount The amount of tokens to collect
    function collect(address token, address recipient, uint256 amount) external;

    /// @notice Collects all available tokens of a specific type from this contract
    /// @param token The address of the ERC20 token to collect
    /// @param recipient The address to send the tokens to
    function collect(address token, address recipient) external;

    /*//////////////////////////////////////////////////////////////
                   LIQUIDATION/FORCE EXERCISE CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Substitutes surplus tokens to a caller in exchange for any potential token shortages prior to revoking virtual shares from a payor.
    /// @param payor The address of the user being exercised/settled
    /// @param fees If applicable, fees to debit from caller (rightSlot = currency0 left = currency1), 0 for `settleLongPremium`
    /// @param atTick The tick at which to convert between currency0/currency1 when redistributing the surplus tokens
    /// @param ct0 The collateral tracker for currency0
    /// @param ct1 The collateral tracker for currency1
    /// @return The LeftRight-packed deltas for currency0/currency1 to move from the caller to the payor
    function getRefundAmounts(
        address payor,
        LeftRightSigned fees,
        int24 atTick,
        CollateralTracker ct0,
        CollateralTracker ct1
    ) external view returns (LeftRightSigned);

    /// @notice Get the cost of exercising an option. Used during a forced exercise.
    /// @param currentTick The current price tick
    /// @param oracleTick The price oracle tick
    /// @param tokenId The position to be exercised
    /// @param positionBalance The position data of the position to be exercised
    /// @return exerciseFees The fees for exercising the option position
    function exerciseCost(
        int24 currentTick,
        int24 oracleTick,
        TokenId tokenId,
        PositionBalance positionBalance
    ) external view returns (LeftRightSigned exerciseFees);

    /// @notice Compute the pre-haircut liquidation bonuses to be paid to the liquidator and the protocol loss caused by the liquidation (pre-haircut).
    /// @param tokenData0 LeftRight encoded word with balance of token0 in the right slot, and required balance in left slot
    /// @param tokenData1 LeftRight encoded word with balance of token1 in the right slot, and required balance in left slot
    /// @param atSqrtPriceX96 The oracle price used to swap tokens between the liquidator/liquidatee and determine solvency for the liquidatee
    /// @param netPaid The net amount of tokens paid/received by the liquidatee to close their portfolio of positions
    /// @param shortPremium Total owed premium (prorated by available settled tokens) across all short legs being liquidated
    /// @return The LeftRight-packed bonus amounts to be paid to the liquidator for both tokens
    /// @return The LeftRight-packed protocol loss (pre-haircut) for both tokens
    function getLiquidationBonus(
        LeftRightUnsigned tokenData0,
        LeftRightUnsigned tokenData1,
        uint160 atSqrtPriceX96,
        LeftRightSigned netPaid,
        LeftRightUnsigned shortPremium
    ) external pure returns (LeftRightSigned, LeftRightSigned);

    /// @notice Haircut/clawback any premium paid by `liquidatee` on `positionIdList` over the protocol loss threshold during a liquidation.
    /// @param liquidatee The address of the user being liquidated
    /// @param positionIdList The list of position ids being liquidated
    /// @param premiasByLeg The premium paid (or received) by the liquidatee for each leg of each position
    /// @param collateralRemaining The remaining collateral after the liquidation (negative if protocol loss)
    /// @param atSqrtPriceX96 The oracle price used to swap tokens between the liquidator/liquidatee and determine solvency for the liquidatee
    /// @return bonusDeltas The delta, if any, to apply to the existing liquidation bonus
    /// @return haircutTotal Total premium clawed back from the liquidatee
    /// @return haircutPerLeg Per-position/per-leg haircut amounts
    function haircutPremia(
        address liquidatee,
        TokenId[] memory positionIdList,
        LeftRightSigned[4][] memory premiasByLeg,
        LeftRightSigned collateralRemaining,
        uint160 atSqrtPriceX96
    )
        external
        returns (
            LeftRightSigned bonusDeltas,
            LeftRightUnsigned haircutTotal,
            LeftRightSigned[4][] memory haircutPerLeg
        );

    /*//////////////////////////////////////////////////////////////
                              ORACLE LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Computes and returns all oracle ticks.
    /// @param currentTick The current tick in the Uniswap pool
    /// @param _oraclePack The packed `s_oraclePack` storage slot containing the oracle's state
    /// @return spotTick The fast oracle tick, sourced from the internal 10-minute EMA
    /// @return medianTick The slow oracle tick, calculated as the median of the 8 stored price points in the internal oracle
    /// @return latestTick The reconstructed absolute tick of the latest observation stored in the internal oracle
    /// @return oraclePack The current value of the 8-slot internal observation queue
    function getOracleTicks(
        int24 currentTick,
        OraclePack _oraclePack
    )
        external
        view
        returns (int24 spotTick, int24 medianTick, int24 latestTick, OraclePack oraclePack);

    /// @notice Calculates a slow-moving, weighted average price from the on-chain EMAs.
    /// @param oraclePack The packed `s_oraclePack` storage slot containing the oracle's state
    /// @return The blended time-weighted average price, represented as an int24 tick
    function twapEMA(OraclePack oraclePack) external pure returns (int24);

    /// @notice Takes a packed structure representing a sorted 8-slot queue of ticks and returns the median of those values and an updated queue if another observation is warranted.
    /// @param oraclePack The packed structure representing the sorted 8-slot queue of ticks
    /// @param currentTick The current tick as return from slot0
    /// @return medianTick The median of the provided 8-slot queue of ticks in `oraclePack`
    /// @return updatedOraclePack The updated 8-slot queue of ticks with the latest observation inserted if the last entry is at least `period` seconds old
    function computeInternalMedian(
        OraclePack oraclePack,
        int24 currentTick
    ) external view returns (int24 medianTick, OraclePack updatedOraclePack);

    /*//////////////////////////////////////////////////////////////
                       HEALTH AND COLLATERAL TRACKING
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the risk parameters including safe mode status and fee recipients.
    /// @param currentTick The current tick
    /// @param oraclePack The oracle pack
    /// @param builderCode The builder code to determine fee recipient
    /// @return RiskParameters The packed risk parameters
    function getRiskParameters(
        int24 currentTick,
        OraclePack oraclePack,
        uint256 builderCode
    ) external view returns (RiskParameters);

    /// @notice computes the fee recipient address based on builder code and salt.
    function getFeeRecipient(uint256 builderCode) external pure returns (uint128 feeRecipient);

    /// @notice Checks for significant oracle deviation to determine if Safe Mode should be active.
    /// @param currentTick The current tick
    /// @param oraclePack The oracle pack
    /// @return safeMode A number representing whether the protocol is in Safe Mode
    function isSafeMode(
        int24 currentTick,
        OraclePack oraclePack
    ) external pure returns (uint8 safeMode);

    /// @notice Determines which ticks to check for solvency based on market volatility.
    /// @param currentTick The current tick
    /// @param _oraclePack The oracle pack
    /// @return atTicks Array of ticks to check solvency at
    /// @return oraclePack The oracle pack (potentially updated)
    function getSolvencyTicks(
        int24 currentTick,
        OraclePack _oraclePack
    ) external view returns (int24[] memory atTicks, OraclePack oraclePack);

    /// @notice Get the collateral status/margin details of an account/user.
    /// @param positionBalanceArray The list of all open positions held by the `optionOwner`
    /// @param positionIdList The list of all option positions held by `user`
    /// @param atTick The tick at which to evaluate the account's positions
    /// @param user The account to check collateral/margin health for
    /// @param shortPremia The total amount of premium owed to the short legs of `user`
    /// @param longPremia The total amount of premium owed by the long legs of `user`
    /// @param ct0 The Address of the CollateralTracker for token0
    /// @param ct1 The Address of the CollateralTracker for token1
    /// @param buffer The buffer to apply to the collateral requirement
    /// @return Whether the account is solvent at the given tick
    function isAccountSolvent(
        PositionBalance[] calldata positionBalanceArray,
        TokenId[] calldata positionIdList,
        int24 atTick,
        address user,
        LeftRightUnsigned shortPremia,
        LeftRightUnsigned longPremia,
        CollateralTracker ct0,
        CollateralTracker ct1,
        uint256 buffer
    ) external view returns (bool);

    /// @notice Compute margin inputs for a user at a given tick.
    /// @param positionBalanceArray Array of [balanceOrUtilAtMint] for all open positions of `user`
    /// @param atTick Tick at which exposures are valued
    /// @param user Account to evaluate
    /// @param positionIdList The list of all option positions held by `user`
    /// @param shortPremia Total short premia owed to `user`
    /// @param longPremia Total long premia owed by `user`
    /// @param ct0 CollateralTracker for token0
    /// @param ct1 CollateralTracker for token1
    /// @return tokenData0 LeftRightUnsigned for token0 with left = maintenance requirement, right = available balance
    /// @return tokenData1 LeftRightUnsigned for token1 with left = maintenance requirement, right = available balance
    /// @return globalUtilizations The max utilizations encountered in the position set
    function getMargin(
        PositionBalance[] calldata positionBalanceArray,
        int24 atTick,
        address user,
        TokenId[] calldata positionIdList,
        LeftRightUnsigned shortPremia,
        LeftRightUnsigned longPremia,
        CollateralTracker ct0,
        CollateralTracker ct1
    )
        external
        view
        returns (
            LeftRightUnsigned tokenData0,
            LeftRightUnsigned tokenData1,
            PositionBalance globalUtilizations
        );

    /*//////////////////////////////////////////////////////////////
                        ADAPTIVE INTEREST RATE MODEL
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates the interest rate based on utilization and accumulator state.
    /// @param utilization The current pool utilization
    /// @param interestRateAccumulator The current state of the interest rate accumulator
    /// @return The calculated interest rate
    function interestRate(
        uint256 utilization,
        MarketState interestRateAccumulator
    ) external view returns (uint128);

    /// @notice Calculates the interest rate and the new rate at target.
    /// @param utilization The current pool utilization
    /// @param interestRateAccumulator The current state of the interest rate accumulator
    /// @return The average rate
    /// @return The new rate at target
    function updateInterestRate(
        uint256 utilization,
        MarketState interestRateAccumulator
    ) external view returns (uint128, uint256);

    /*//////////////////////////////////////////////////////////////
                             QUERY HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the stored VEGOID parameter
    function vegoid() external view returns (uint8);
}
