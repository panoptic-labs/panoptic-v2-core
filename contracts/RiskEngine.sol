// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;
// Interfaces
import {CollateralTracker} from "./CollateralTracker.sol";
import {PanopticPool} from "./PanopticPool.sol";
// Libraries
import {Constants} from "@libraries/Constants.sol";
import {Errors} from "@libraries/Errors.sol";
import {Math} from "@libraries/Math.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";
// Custom types
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";
import {RiskParameters, RiskParametersLibrary} from "@types/RiskParameters.sol";
import {TokenId} from "@types/TokenId.sol";
import {OraclePack} from "@types/OraclePack.sol";
import {MarketState} from "@types/MarketState.sol";

/// @title Panoptic Risk Engine: The central risk assessment and solvency calculator for the Panoptic Protocol.
/// @author Axicon Labs Limited
/// @notice This contract serves as the central logic hub for calculating collateral requirements, account solvency, and liquidation parameters.
/// @dev This contract does not hold funds or state regarding user balances. Instead, it provides the mathematical framework to:
/// 1. Calculate collateral requirements for complex option strategies (Spreads, Strangles, Synthetic positions).
/// 2. Manage the internal pricing Oracle, utilizing volatility safeguards, EMAs, and median filters to prevent manipulation.
/// 3. Compute the Adaptive Interest Rate based on pool utilization (PID controller logic).
///
/// Key responsibilities:
/// - Verifying if an account is solvent (`isAccountSolvent`).
/// - Calculating the cost to force-exercise a position (`exerciseCost`).
/// - Determining liquidation bonuses (`getLiquidationBonus`).
/// - Calculating dynamic collateral ratios based on pool utilization.
contract RiskEngine {
    using Math for uint256;

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

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Decimals for computation (1 millitick (1/1000th of a basis point) precision: 1e-7 = 0.00001%).
    /// @dev uint type for composability with unsigned integer based mathematical operations.
    uint256 internal constant DECIMALS = 10_000_000;

    int16 internal constant MAX_UTILIZATION = 10_000;
    uint256 internal constant LN2_SCALED = 6931472;

    uint256 internal constant ONE_BPS = 1000;
    uint256 internal constant TEN_BPS = 10000;

    //int256 constant EMA_PERIOD_SPOT = 120; // 2 minutes
    //int256 constant EMA_PERIOD_FAST = 240; // 4 minutes
    //int256 constant EMA_PERIOD_SLOW = 600; // 10 minutes
    //int256 constant EMA_PERIOD_EONS = 1800; // 30 minutes

    uint96 constant EMA_PERIODS = uint96(120 + (240 << 24) + (600 << 48) + (1800 << 72));
    /// @notice The maximum allowed cumulative delta between the fast & slow oracle tick, the current & slow oracle tick, and the last-observed & slow oracle tick.
    /// @dev Falls back on the more conservative (less solvent) tick during times of extreme volatility, where the price moves ~10% in <4 minutes.
    int256 internal constant MAX_TICKS_DELTA = 953;

    /// @notice The maximum allowed delta between the currentTick and the Uniswap TWAP tick during a liquidation (~5% down, ~5.26% up).
    /// @dev Mitigates manipulation of the currentTick that causes positions to be liquidated at a less favorable price.
    uint16 internal constant MAX_TWAP_DELTA_LIQUIDATION = 513;

    /// @notice The maximum allowed ratio for a single chunk, defined as `removedLiquidity / netLiquidity`.
    /// @dev The long premium spread multiplier that corresponds with the MAX_SPREAD value depends on VEGOID,
    /// which can be explored in this calculator: [https://www.desmos.com/calculator/mdeqob2m04](https://www.desmos.com/calculator/mdeqob2m04).
    uint24 internal constant MAX_SPREAD = 90_000;

    /// @notice Multiplier in basis points for the collateral requirement in the event of a buying power decrease, such as minting or force exercising another user.
    /// @dev must fit inside a uint26
    uint32 internal constant BP_DECREASE_BUFFER = 13_333_333;

    /// @notice Decimals for WAD calculations.
    int256 internal constant WAD = 1e18;

    /// @notice Constant, in seconds, used to determine the max elapsed time between adaptive interest rate updates.
    /// @dev the time elapsed will be capped at IRM_MAX_ELAPSED_TIME
    int256 public constant IRM_MAX_ELAPSED_TIME = 4096;

    bytes32 internal constant BUILDER_SALT = keccak256("panoptic.builder");

    /// @notice The maximum amount of change, in ticks, permitted between internal median updates.
    int24 internal constant MAX_CLAMP_DELTA = 149;

    /// @notice Parameter used to modify the [equation](https://www.desmos.com/calculator/mdeqob2m04) of the utilization-based multiplier for long premium.
    // ν = 1/VEGOID = multiplicative factor for long premium (Eqns 1-5)
    // Similar to vega in options because the liquidity utilization is somewhat reflective of the implied volatility (IV),
    // and vegoid modifies the sensitivity of the streamia to changes in that utilization,
    // much like vega measures the sensitivity of traditional option prices to IV.
    // The effect of vegoid on the long premium multiplier can be explored here: https://www.desmos.com/calculator/mdeqob2m04
    uint8 internal constant VEGOID = 4;

    /*//////////////////////////////////////////////////////////////
                            RISK PARAMETERS
    //////////////////////////////////////////////////////////////*/
    /// @notice The notional fee, in basis points, collected from PLPs at option mint.
    /// @dev can never exceed 10000, so this value must fit inside a uint14 due to RiskParameters packing
    uint16 constant NOTIONAL_FEE = 10;

    /// @notice The premium fee, in basis points, collected from the premium paid/received.
    /// @dev can never exceed 10000, so this value must fit inside a uint14 due to RiskParameters packing
    uint16 constant PREMIUM_FEE = 0;

    /// @notice The protocol split, in basis points, when a builder code is present.
    /// @dev can never exceed 10000, so this value must fit inside a uint14 due to RiskParameters packing
    uint16 constant PROTOCOL_SPLIT = 6_500;

    /// @notice The builder split, in basis points, when a builder code is present
    /// @dev can never exceed 10000, so this value must fit inside a uint14 due to RiskParameters packing
    uint16 constant BUILDER_SPLIT = 2_500;

    /// @notice Required collateral ratios for selling options, fraction of 1, scaled by 10_000_000.
    /// @dev i.e 20% -> 0.2 * 10_000_000 = 2_000_000.
    uint256 constant SELLER_COLLATERAL_RATIO = 2_000_000;

    /// @notice Required collateral ratios for buying options, fraction of 1, scaled by 10_000_000.
    /// @dev i.e 10% -> 0.1 * 10_000_000 = 1_000_000.
    uint256 constant BUYER_COLLATERAL_RATIO = 1_000_000;

    /// @notice Required collateral margin for loans in excess of notional, fraction of 1, scaled by 10_000_000.
    uint256 constant MAINT_MARGIN_RATE = 2_000_000;

    /// @notice Basal cost (in bps of notional) to force exercise an out-of-range position.
    uint256 constant FORCE_EXERCISE_COST = 102_400;

    // Targets a pool utilization (balance between buying and selling)
    /// @notice Target pool utilization below which buying+selling is optimal, fraction of 1, scaled by 10_000_000.
    /// @dev i.e 50% -> 0.5 * 10_000_000 = 5_000_000.
    uint256 constant TARGET_POOL_UTIL = 5_000_000;

    /// @notice Pool utilization above which selling is 100% collateral backed, fraction of 1, scaled by 10_000_000.
    /// @dev i.e 90% -> 0.9 * 10_000_000 = 9_000_000.
    uint256 constant SATURATED_POOL_UTIL = 9_000_000;

    uint256 immutable CROSS_BUFFER_0;
    uint256 immutable CROSS_BUFFER_1;

    address immutable BUILDER_FACTORY;
    bytes32 immutable BUILDER_INIT_CODE_HASH;

    uint256 constant MAX_OPEN_LEGS = 33;

    /*//////////////////////////////////////////////////////////////
                            IRM PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Curve steepness (scaled by WAD).
    /// @dev Curve steepness = 4.
    int256 public constant CURVE_STEEPNESS = 4 ether;

    /// @notice Minimum rate at target per second (scaled by WAD).
    /// @dev Minimum rate at target = 0.1% (minimum rate = 0.025%).
    int256 public constant MIN_RATE_AT_TARGET = 0.001 ether / int256(365 days);

    /// @notice Maximum rate at target per second (scaled by WAD).
    /// @dev Maximum rate at target = 200% (maximum rate = 800%).
    int256 public constant MAX_RATE_AT_TARGET = 2.0 ether / int256(365 days);

    /// @notice Target utilization (scaled by WAD).
    /// @dev Target utilization = 90%.
    int256 public constant TARGET_UTILIZATION = 2 ether / int256(3);

    /// @notice Initial rate at target per second (scaled by WAD).
    /// @dev Initial rate at target = 4% (rate between 1% and 16%).
    int256 public constant INITIAL_RATE_AT_TARGET = 0.04 ether / int256(365 days);

    /// @notice Adjustment speed per second (scaled by WAD).
    /// @dev The speed is per second, so the rate moves at a speed of ADJUSTMENT_SPEED * err each second (while being
    /// continuously compounded).
    /// @dev Adjustment speed = 50/year.
    int256 public constant ADJUSTMENT_SPEED = 50 ether / int256(365 days);

    /*//////////////////////////////////////////////////////////////
                  INITIALIZATION & PARAMETER SETTINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set immutable parameters for the Collateral Tracker.
    constructor(
        uint256 _crossBuffer0,
        uint256 _crossBuffer1,
        address _guardian,
        address _builderFactory
    ) {
        CROSS_BUFFER_0 = _crossBuffer0;
        CROSS_BUFFER_1 = _crossBuffer1;
        GUARDIAN = _guardian;
        BUILDER_FACTORY = _builderFactory;
        BUILDER_INIT_CODE_HASH = keccak256(
            abi.encodePacked(type(BuilderWallet).creationCode, abi.encode(BUILDER_FACTORY))
        );
    }

    /*//////////////////////////////////////////////////////////////
                                GUARDIAN
    //////////////////////////////////////////////////////////////*/

    /// @notice Address allowed to override the automatically computed safe mode.
    /// @dev Guardian can only increase the effective safe mode, never relax it.
    address public immutable GUARDIAN;

    /// @notice Emitted when the guardian updates the enforced safe mode.
    /// @param lockMode True when safe mode is forcibly locked, false when the lock is lifted.
    event GuardianSafeModeUpdated(bool lockMode);

    /// @notice Restricts a function to be callable only by the guardian address.
    modifier onlyGuardian() {
        _onlyGuardian();
        _;
    }

    /// @dev Reverts unless the caller is the guardian.
    function _onlyGuardian() internal view {
        if (msg.sender != address(GUARDIAN)) revert Errors.NotGuardian();
    }

    /// @notice Forces a PanopticPool into locked safe mode.
    /// @dev Sets the pool’s internal oracle pack into permanent safe-mode override
    ///      until explicitly unlocked by the guardian.
    /// @param pool The PanopticPool to lock.
    function lockPool(PanopticPool pool) external onlyGuardian {
        emit GuardianSafeModeUpdated(true);
        pool.lockSafeMode();
    }

    /// @notice Removes the forced safe-mode lock on a PanopticPool.
    /// @dev Restores the pool to using only the automatically computed safe-mode level.
    /// @param pool The PanopticPool to unlock.
    function unlockPool(PanopticPool pool) external onlyGuardian {
        emit GuardianSafeModeUpdated(true);
        pool.unlockSafeMode();
    }

    /// @notice Returns the address of the guardian
    /// @return The guardian address that can override safe mode
    function guardian() external returns (address) {
        return GUARDIAN;
    }

    function _computeBuilderWallet(uint256 builderCode) internal view returns (address wallet) {
        if (builderCode == 0) return address(0);

        bytes32 salt = bytes32(builderCode);

        bytes32 h = keccak256(
            abi.encodePacked(bytes1(0xff), BUILDER_FACTORY, salt, BUILDER_INIT_CODE_HASH)
        );

        wallet = address(uint160(uint256(h)));
    }

    /*//////////////////////////////////////////////////////////////
                                TRANSFERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Collects a specific amount of tokens from this contract
    /// @param token The address of the ERC20 token to collect
    /// @param recipient The address to send the tokens to
    /// @param amount The amount of tokens to collect
    function collect(address token, address recipient, uint256 amount) public onlyGuardian {
        if (amount == 0) revert Errors.BelowMinimumRedemption();

        SafeTransferLib.safeTransfer(token, recipient, amount);

        emit TokensCollected(token, recipient, amount);
    }

    /// @notice Collects all available tokens of a specific type from this contract
    /// @param token The address of the ERC20 token to collect
    /// @param recipient The address to send the tokens to
    function collect(address token, address recipient) external onlyGuardian {
        // Get the full balance
        uint256 balance = SafeTransferLib.balanceOfOrZero(token, address(this));
        collect(token, recipient, balance);
    }

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
    ) external view returns (LeftRightSigned) {
        uint160 sqrtPriceX96 = Math.getSqrtRatioAtTick(atTick);
        // keep everything checked to catch any under/overflow or miscastings
        {
            // if the refunder lacks sufficient currency0 to pay back the virtual shares, have the caller cover the difference in exchange for currency1 (and vice versa)
            int128 fees0 = fees.rightSlot();
            uint256 feeShares0 = ct0.convertToShares(fees0 < 0 ? uint128(-fees0) : uint128(fees0));

            // Liability (>0) adds to shortage; Asset (<0) subtracts from shortage
            int256 balanceShortage = int256(uint256(type(uint248).max)) -
                int256(ct0.balanceOf(payor)) +
                (fees0 > 0 ? int256(feeShares0) : -int256(feeShares0));

            if (balanceShortage > 0) {
                return
                    LeftRightSigned
                        .wrap(0)
                        .addToRightSlot(
                            int128(
                                fees.rightSlot() -
                                    int256(
                                        Math.mulDivRoundingUp(
                                            uint256(balanceShortage),
                                            ct0.totalAssets(),
                                            ct0.totalSupply()
                                        )
                                    )
                            )
                        )
                        .addToLeftSlot(
                            int128(
                                int256(
                                    PanopticMath.convert0to1RoundingUp(
                                        ct0.convertToAssets(uint256(balanceShortage)),
                                        sqrtPriceX96
                                    )
                                ) + fees.leftSlot()
                            )
                        );
            }

            int128 fees1 = fees.leftSlot();
            uint256 feeShares1 = ct1.convertToShares(fees1 < 0 ? uint128(-fees1) : uint128(fees1));

            // Liability (>0) adds to shortage; Asset (<0) subtracts from shortage
            balanceShortage =
                int256(uint256(type(uint248).max)) -
                int256(ct1.balanceOf(payor)) +
                (fees1 > 0 ? int256(feeShares1) : -int256(feeShares1));

            if (balanceShortage > 0) {
                return
                    LeftRightSigned
                        .wrap(0)
                        .addToRightSlot(
                            int128(
                                int256(
                                    PanopticMath.convert1to0RoundingUp(
                                        ct1.convertToAssets(uint256(balanceShortage)),
                                        sqrtPriceX96
                                    )
                                ) + fees.rightSlot()
                            )
                        )
                        .addToLeftSlot(
                            int128(
                                fees.leftSlot() -
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

        // otherwise, no need to deviate from the original deltas
        return fees;
    }

    /// @notice Get the cost of exercising an option. Used during a forced exercise.
    /// @notice This one computes the cost of calling the forceExercise function on a position:
    /// - The forceExercisor will have to *pay* the exercisee because their position will be closed "against their will"
    /// - The cost must be larger when the position is in-range, and should be minimal when it is out of range
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
    ) external view returns (LeftRightSigned exerciseFees) {
        // keep everything checked to catch any under/overflow or miscastings
        LeftRightSigned longAmounts;
        // we find whether the price is within any leg; any in-range leg will have a cost. Otherwise, the force-exercise fee is 1bps
        bool hasLegsInRange;
        for (uint256 leg = 0; leg < tokenId.countLegs(); ++leg) {
            // short legs are not counted - exercise is intended to be based on long legs
            if (tokenId.isLong(leg) == 0) continue;

            // credit/loans are not counted
            if (tokenId.width(leg) == 0) continue;

            // compute notional moved, add to tally.
            (LeftRightSigned longs, ) = PanopticMath.calculateIOAmounts(
                tokenId,
                positionBalance.positionSize(),
                leg,
                true
            );
            longAmounts = longAmounts.add(longs);

            {
                (int24 rangeDown, int24 rangeUp) = PanopticMath.getRangesFromStrike(
                    tokenId.width(leg),
                    tokenId.tickSpacing()
                );

                int24 _strike = tokenId.strike(leg);

                if ((currentTick < _strike + rangeUp) && (currentTick >= _strike - rangeDown)) {
                    hasLegsInRange = true;
                }
            }

            uint256 currentValue0;
            uint256 currentValue1;
            uint256 oracleValue0;
            uint256 oracleValue1;

            {
                LiquidityChunk liquidityChunk = PanopticMath.getLiquidityChunk(
                    tokenId,
                    leg,
                    positionBalance.positionSize()
                );

                (currentValue0, currentValue1) = Math.getAmountsForLiquidity(
                    currentTick,
                    liquidityChunk
                );

                (oracleValue0, oracleValue1) = Math.getAmountsForLiquidity(
                    oracleTick,
                    liquidityChunk
                );
            }

            // reverse any token deltas between the current and oracle prices for the chunk the exercisee had to mint in Uniswap
            // the outcome of current price crossing a long chunk will always be less favorable than the status quo, i.e.,
            // if the current price is moved downward such that some part of the chunk is between the current and market prices,
            // the chunk composition will swap token1 for token0 at a price (token0/token1) more favorable than market (token1/token0),
            // forcing the exercisee to provide more value in token0 than they would have provided in token1 at market, and vice versa.
            // (the excess value provided by the exercisee could then be captured in a return swap across their newly added liquidity)
            exerciseFees = exerciseFees.sub(
                LeftRightSigned
                    .wrap(0)
                    .addToRightSlot(int128(uint128(currentValue0)) - int128(uint128(oracleValue0)))
                    .addToLeftSlot(int128(uint128(currentValue1)) - int128(uint128(oracleValue1)))
            );
        }

        // NOTE: we HAVE to start with a negative number as the base exercise cost because when shifting a negative number right by n bits,
        // the result is rounded DOWN and NOT toward zero
        // this divergence is observed when n (the number of half ranges) is > 10 (ensuring the floor is not zero, but -1 = 1bps at that point)
        // subtract 1 from max half ranges from strike so fee starts at FORCE_EXERCISE_COST when moving OTM
        int256 fee = hasLegsInRange ? -int256(FORCE_EXERCISE_COST) : -int256(ONE_BPS);

        // store the exercise fees in the exerciseFees variable
        exerciseFees = exerciseFees
            .addToRightSlot(int128((longAmounts.rightSlot() * fee) / int256(DECIMALS)))
            .addToLeftSlot(int128((longAmounts.leftSlot() * fee) / int256(DECIMALS)));
    }

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
        // keep everything checked to catch any under/overflow or miscastings
        {
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
                    uint256 bonus0U = Math.mulDiv128(bonusCross, requiredRatioX128);
                    bonus0 = int256(bonus0U);

                    bonus1 = int256(PanopticMath.convert0to1(bonusCross - bonus0U, atSqrtPriceX96));
                } else {
                    // required1 / (token1(required0) + required1)
                    uint256 requiredRatioX128 = Math.mulDiv(
                        tokenData1.leftSlot(),
                        2 ** 128,
                        thresholdCross
                    );
                    uint256 bonus1U = Math.mulDiv128(bonusCross, requiredRatioX128);
                    bonus1 = int256(bonus1U);

                    bonus0 = int256(PanopticMath.convert1to0(bonusCross - bonus1U, atSqrtPriceX96));
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
                        PanopticMath.convert1to0RoundingUp(balance1 - paid1, atSqrtPriceX96),
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
                        PanopticMath.convert0to1RoundingUp(balance0 - paid0, atSqrtPriceX96),
                        paid1 - balance1
                    );
                }
                // recompute netPaid based on new bonus amounts
                paid0 = bonus0 + int256(netPaid.rightSlot());
                paid1 = bonus1 + int256(netPaid.leftSlot());
            }

            return (
                LeftRightSigned.wrap(0).addToRightSlot(int128(bonus0)).addToLeftSlot(
                    int128(bonus1)
                ),
                LeftRightSigned.wrap(0).addToRightSlot(int128(balance0 - paid0)).addToLeftSlot(
                    int128(balance1 - paid1)
                )
            );
        }
    }

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
        )
    {
        unchecked {
            LeftRightSigned haircutBase;
            LeftRightSigned longPremium;

            /// Get haircutBase, longPremium, bonusDelta

            // Ignore any surplus collateral - the liquidatee is either solvent or it converts to <1 unit of the other token
            {
                int256 collateralDelta0 = -Math.min(collateralRemaining.rightSlot(), 0);
                int256 collateralDelta1 = -Math.min(collateralRemaining.leftSlot(), 0);
                // get the amount of premium paid by the liquidatee

                for (uint256 i = 0; i < positionIdList.length; ++i) {
                    TokenId tokenId = positionIdList[i];
                    uint256 numLegs = tokenId.countLegs();
                    for (uint256 leg = 0; leg < numLegs; ++leg) {
                        if (tokenId.isLong(leg) == 1) {
                            longPremium = longPremium.sub(premiasByLeg[i][leg]);
                        }
                    }
                }

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
                    haircutBase = LeftRightSigned.wrap(longPremium.rightSlot()).addToLeftSlot(
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
                        .addToLeftSlot(longPremium.leftSlot());
                } else {
                    // for each token, haircut until the protocol loss is mitigated or the premium paid is exhausted
                    // the size of `collateralDelta0/1` and `longPremium.rightSlot()/leftSlot()` is limited to `2^127 - 1` given that they originate from LeftRightSigned types
                    haircutBase = LeftRightSigned
                        .wrap(int128(Math.min(collateralDelta0, longPremium.rightSlot())))
                        .addToLeftSlot(int128(Math.min(collateralDelta1, longPremium.leftSlot())));

                    collateralDelta0 = 0;
                    collateralDelta1 = 0;
                }
                bonusDeltas = LeftRightSigned
                    .wrap(0)
                    .addToRightSlot(Math.toInt128(collateralDelta0))
                    .addToLeftSlot(Math.toInt128(collateralDelta1));
            }

            // liquidatee
            // positionIdList
            // premiaByLeg
            // haircutBase
            // longPremium
            // settledTokens
            {
                haircutPerLeg = new LeftRightSigned[4][](positionIdList.length);
                // total haircut after rounding up prorated haircut amounts for each leg
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

                            LeftRightSigned haircutAmounts;

                            // Only calculate rightSlot if both numerator and denominator exist
                            if (
                                _premiasByLeg[i][leg].rightSlot() != 0 &&
                                longPremium.rightSlot() != 0
                            ) {
                                haircutAmounts = haircutAmounts.addToRightSlot(
                                    int128(
                                        uint128(
                                            Math.unsafeDivRoundingUp(
                                                uint128(-_premiasByLeg[i][leg].rightSlot()) *
                                                    uint256(uint128(haircutBase.rightSlot())),
                                                uint128(longPremium.rightSlot())
                                            )
                                        )
                                    )
                                );
                            }

                            // Only calculate leftSlot if both numerator and denominator exist
                            if (
                                _premiasByLeg[i][leg].leftSlot() != 0 && longPremium.leftSlot() != 0
                            ) {
                                haircutAmounts = haircutAmounts.addToLeftSlot(
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
                            }

                            haircutTotal = haircutTotal.add(
                                LeftRightUnsigned.wrap(
                                    uint256(LeftRightSigned.unwrap(haircutAmounts))
                                )
                            );

                            haircutPerLeg[i][leg] = haircutAmounts;
                        }
                    }
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                     ORACLE LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Computes and returns all oracle ticks.
    /// @param currentTick The current tick in the Uniswap pool
    /// @param _oraclePack The packed `s_oraclePack` storage slot containing the oracle's state,
    /// @return spotTick The spot oracle tick, sourced from the shortest EMA.
    /// @return medianTick The median tick, calculated as the median of the 8 stored price points in the internal oracle.
    /// @return latestTick The reconstructed absolute tick of the latest observation stored in the internal oracle.
    /// @return oraclePack The current value of the 8-slot internal observation queue (`s_oraclePack`)
    function getOracleTicks(
        int24 currentTick,
        OraclePack _oraclePack
    )
        external
        view
        returns (int24 spotTick, int24 medianTick, int24 latestTick, OraclePack oraclePack)
    {
        (spotTick, medianTick, latestTick, oraclePack) = _oraclePack.getOracleTicks(
            currentTick,
            EMA_PERIODS,
            MAX_CLAMP_DELTA
        );
    }

    /// @notice Calculates a slow-moving, weighted average price from the on-chain EMAs.
    /// @dev Extracts the fast, slow, and eons EMA tick values from the packed `oraclePack`
    /// structure. It then computes and returns a blended average with a 60/30/10 weighting
    /// respectively. This heavily smoothed value is designed to be highly resistant to
    /// manipulation and serves as a robust price feed for critical system functions like solvency checks.
    /// @param oraclePack The packed `s_oraclePack` storage slot containing the oracle's state,
    /// including the on-chain EMAs.
    /// @return The blended time-weighted average price, represented as an int24 tick.
    function twapEMA(OraclePack oraclePack) external pure returns (int24) {
        // Extract current EMAs from oraclePack
        (int256 eonsEMA, int256 slowEMA, int256 fastEMA, , ) = oraclePack.getEMAs();
        return int24((6 * fastEMA + 3 * slowEMA + eonsEMA) / 10);
    }

    /// @notice Takes a packed structure representing a sorted 8-slot queue of ticks and returns the median of those values and an updated queue if another observation is warranted.
    /// @dev Also inserts the latest Uniswap observation into the buffer, resorts, and returns if the last entry is at least `period` seconds old.
    /// @param oraclePack The packed structure representing the sorted 8-slot queue of ticks
    /// @param currentTick The current tick as return from slot0
    /// @return medianTick The median of the provided 8-slot queue of ticks in `oraclePack`
    /// @return updatedOraclePack The updated 8-slot queue of ticks with the latest observation inserted if the last entry is at least `period` seconds old (returns 0 otherwise)
    function computeInternalMedian(
        OraclePack oraclePack,
        int24 currentTick
    ) external view returns (int24 medianTick, OraclePack updatedOraclePack) {
        return oraclePack.computeInternalMedian(currentTick, EMA_PERIODS, MAX_CLAMP_DELTA);
    }

    /*//////////////////////////////////////////////////////////////
                     HEALTH AND COLLATERAL TRACKING
    //////////////////////////////////////////////////////////////*/

    /// @notice Computes and returns the risk parameters for the pool
    /// @param currentTick The current tick of the pool
    /// @param oraclePack The oracle pack containing historical price data
    /// @param builderCode The builder code for determining fee recipient
    /// @return The computed risk parameters including safe mode status and fee configuration
    function getRiskParameters(
        int24 currentTick,
        OraclePack oraclePack,
        uint256 builderCode
    ) external view returns (RiskParameters) {
        uint8 safeMode = isSafeMode(currentTick, oraclePack);

        uint128 feeRecipient = uint256(uint160(_computeBuilderWallet(builderCode))).toUint128();

        return
            RiskParametersLibrary.storeRiskParameters(
                safeMode,
                NOTIONAL_FEE,
                PREMIUM_FEE,
                PROTOCOL_SPLIT,
                BUILDER_SPLIT,
                MAX_TWAP_DELTA_LIQUIDATION,
                MAX_SPREAD,
                BP_DECREASE_BUFFER,
                MAX_OPEN_LEGS,
                feeRecipient
            );
    }

    /// @notice Computes the fee recipient address from a builder code
    /// @param builderCode The builder code to compute the fee recipient from
    /// @return feeRecipient The computed fee recipient address
    function getFeeRecipient(uint256 builderCode) external view returns (address feeRecipient) {
        feeRecipient = _computeBuilderWallet(builderCode);

        // Optional: enforce whitelist by checking that the contract actually exists
        if (builderCode != 0) {
            if (feeRecipient.code.length == 0) revert Errors.InvalidBuilderCode();
        }
    }

    /// @notice Checks for significant oracle deviation to determine if Safe Mode should be active.
    /// @param currentTick The current tick of the pool
    /// @param oraclePack The oracle pack containing historical price data
    /// @dev Safe Mode is triggered if ANY of three conditions are met:
    ///      1. "External Shock": The live spot price deviates too far from the responsive spot EMA
    ///      2. "Internal Disagreement": The fast EMA deviates too far from the more stable slow EMA, indicating high volatility
    ///      3. "High Divergence": The EMAs show significant divergence from each other
    /// @return safeMode A number representing whether the protocol is in Safe Mode.
    function isSafeMode(
        int24 currentTick,
        OraclePack oraclePack
    ) public pure returns (uint8 safeMode) {
        // Extract the relevant EMAs from oraclePack
        (int24 spotEMA, int24 fastEMA, int24 slowEMA, , int24 medianTick) = oraclePack.getEMAs();

        unchecked {
            // can never miscart because all math is int24 or below
            // Condition 1: Check for a sudden deviation of the spot price from the spot EMA.
            // This is your primary defense against a flash crash or single-block manipulation.
            bool externalShock = Math.abs(currentTick - spotEMA) > MAX_TICKS_DELTA;

            // Condition 2: Check for high internal volatility by comparing the spot and fast EMAs.
            // If the spot EMA is moving much faster than the fast EMA, it signals an unstable market.
            // We use a smaller threshold here (e.g., half of the main delta) to be more sensitive to internal stress.
            bool internalDisagreement = Math.abs(spotEMA - fastEMA) > (MAX_TICKS_DELTA / 2);

            // Condition 3: Check for high internal divergence due to staleness by comparing the median and slow EMAs.
            // If the median tick is deviating too much from the slow EMA, it signals an unstable market.
            // We use a larger threshold here (e.g., twice of the main delta) to be less sensitive to lag.
            bool highDivergence = Math.abs(medianTick - slowEMA) > (MAX_TICKS_DELTA * 2);

            // check lock mode, add value = 3 to returned safeMode.
            uint8 lockMode = oraclePack.lockMode();

            safeMode =
                uint8(externalShock ? 1 : 0) +
                uint8(internalDisagreement ? 1 : 0) +
                uint8(highDivergence ? 1 : 0) +
                lockMode;
        }
    }

    /// @notice Determines which ticks to check for solvency based on market volatility
    /// @param currentTick The current tick of the pool
    /// @param _oraclePack The oracle pack containing historical price data
    /// @return atTicks Array of ticks at which to check solvency
    /// @return oraclePack The oracle pack (potentially updated)
    function getSolvencyTicks(
        int24 currentTick,
        OraclePack _oraclePack
    ) external view returns (int24[] memory, OraclePack) {
        (int24 spotTick, int24 medianTick, int24 latestTick, OraclePack oraclePack) = _oraclePack
            .getOracleTicks(currentTick, EMA_PERIODS, MAX_CLAMP_DELTA);

        int24[] memory atTicks;

        // Fall back to a conservative approach if there's high deviation between internal ticks:
        // Check solvency at the medianTick, currentTick, and latestTick instead of just the spotTick.
        // Deviation is measured as the magnitude of a 3D vector:
        // (spotTick - medianTick, latestTick - medianTick, currentTick - medianTick)
        // This approach is more conservative than checking each tick difference individually,
        // as the Euclidean norm is always greater than or equal to the maximum of the individual differences.
        if (
            int256(spotTick - medianTick) ** 2 +
                int256(latestTick - medianTick) ** 2 +
                int256(currentTick - medianTick) ** 2 >
            MAX_TICKS_DELTA ** 2
        ) {
            // High deviation detected; check against all four ticks.
            atTicks = new int24[](4);
            atTicks[0] = spotTick;
            atTicks[1] = medianTick;
            atTicks[2] = latestTick;
            atTicks[3] = currentTick;
        } else {
            // Normal operation; check against the spot tick = 10 mins EMA.
            atTicks = new int24[](1);
            atTicks[0] = spotTick;
        }

        return (atTicks, oraclePack);
    }

    /// @notice Get the collateral status/margin details of an account/user.
    /// @dev NOTE: It's up to the caller to confirm from the returned result that the account has enough collateral.
    /// @dev This can be used to check the health: how many tokens a user has compared to the margin threshold.
    /// @param user The account to check collateral/margin health for
    /// @param positionBalanceArray The list of all open positions held by the `optionOwner`, stored as `[balance/poolUtilizationAtMint, ...]`
    /// @param atTick The tick at which to evaluate the account's positions
    /// @param positionIdList The list of all option positions held by `user`
    /// @param shortPremia The total amount of premium (prorated by available settled tokens) owed to the short legs of `user`
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
    ) external view returns (bool) {
        (
            LeftRightUnsigned tokenData0,
            LeftRightUnsigned tokenData1,
            PositionBalance globalUtilizations
        ) = _getMargin(
                positionBalanceArray,
                positionIdList,
                atTick,
                user,
                shortPremia,
                longPremia,
                ct0,
                ct1
            );
        uint160 sqrtPriceX96 = Math.getSqrtRatioAtTick(atTick);

        uint256 maintReq0 = Math.mulDivRoundingUp(tokenData0.leftSlot(), buffer, DECIMALS);
        uint256 maintReq1 = Math.mulDivRoundingUp(tokenData1.leftSlot(), buffer, DECIMALS);

        uint256 bal0 = tokenData0.rightSlot();
        uint256 bal1 = tokenData1.rightSlot();

        uint256 scaledSurplusToken0 = Math.mulDiv(
            bal0 > maintReq0 ? bal0 - maintReq0 : 0,
            _crossBufferRatio(globalUtilizations.utilization0(), CROSS_BUFFER_0),
            DECIMALS
        );
        uint256 scaledSurplusToken1 = Math.mulDiv(
            bal1 > maintReq1 ? bal1 - maintReq1 : 0,
            _crossBufferRatio(globalUtilizations.utilization1(), CROSS_BUFFER_1),
            DECIMALS
        );

        if (sqrtPriceX96 < Constants.FP96) {
            bool isSolvent0 = bal0 + PanopticMath.convert1to0(scaledSurplusToken1, sqrtPriceX96) >=
                maintReq0;
            bool isSolvent1 = PanopticMath.convert1to0(bal1, sqrtPriceX96) + scaledSurplusToken0 >=
                PanopticMath.convert1to0RoundingUp(maintReq1, sqrtPriceX96);
            return isSolvent0 && isSolvent1;
        } else {
            bool isSolvent0 = PanopticMath.convert0to1(bal0, sqrtPriceX96) + scaledSurplusToken1 >=
                PanopticMath.convert0to1RoundingUp(maintReq0, sqrtPriceX96);
            bool isSolvent1 = bal1 + PanopticMath.convert0to1(scaledSurplusToken0, sqrtPriceX96) >=
                maintReq1;
            return isSolvent0 && isSolvent1;
        }
    }

    /// @notice Compute margin inputs for a user at a given tick.
    /// @dev Purely informational: does not make a solvency decision.
    ///      Returns per-asset maintenance requirement (left slot) and available balance including settled premia (right slot).
    ///      Units:
    ///        - Requirements are in raw token units
    ///        - Balances are in raw token units
    ///        - Ratios elsewhere in the engine use DECIMALS = 10_000_000
    /// @param user Account to evaluate
    /// @param positionBalanceArray Array of [balanceOrUtilAtMint] for all open positions of `user`
    /// @param atTick Tick at which exposures are valued
    /// @param positionIdList The list of all option positions held by `user`
    /// @param shortPremia Total short premia owed to `user` (right slot = token0 credit, left slot = token1 credit)
    /// @param longPremia Total long premia owed by `user`   (right slot = token0 debit,  left slot = token1 debit)
    /// @param ct0 CollateralTracker for token0
    /// @param ct1 CollateralTracker for token1
    /// @return tokenData0 LeftRightUnsigned for token0 with left = maintenance requirement, right = available balance
    /// @return tokenData1 LeftRightUnsigned for token1 with left = maintenance requirement, right = available balance
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
        )
    {
        if (positionIdList.length != positionBalanceArray.length) revert Errors.LengthMismatch();
        return
            _getMargin(
                positionBalanceArray,
                positionIdList,
                atTick,
                user,
                shortPremia,
                longPremia,
                ct0,
                ct1
            );
    }

    /// @notice Internal workhorse for margin computation.
    /// @dev Aggregates balances, accrued interest, and per-position requirements to produce
    ///      LeftRightUnsigned pairs for token0 and token1 where:
    ///        - left slot = total maintenance requirement in that token
    ///        - right slot = total available balance in that token including settled short premia
    ///      Caller is responsible for any cross-asset conversion, haircuts, and final solvency logic.
    /// @param user Account to evaluate
    /// @param positionBalanceArray Array of [balanceOrUtilAtMint] for all open positions of `user`
    /// @param atTick Tick at which exposures are valued
    /// @param positionIdList The list of all option positions held by `user`
    /// @param shortPremia Total short premia owed to `user` (right slot = token0 credit, left slot = token1 credit)
    /// @param longPremia Total long premia owed by `user`   (right slot = token0 debit,  left slot = token1 debit)
    /// @param ct0 CollateralTracker for token0
    /// @param ct1 CollateralTracker for token1
    /// @return tokenData0 LeftRightUnsigned for token0 with left = maintenance requirement, right = available balance
    /// @return tokenData1 LeftRightUnsigned for token1 with left = maintenance requirement, right = available balance
    function _getMargin(
        PositionBalance[] calldata positionBalanceArray,
        TokenId[] calldata positionIdList,
        int24 atTick,
        address user,
        LeftRightUnsigned shortPremia,
        LeftRightUnsigned longPremia,
        CollateralTracker ct0,
        CollateralTracker ct1
    )
        internal
        view
        returns (
            LeftRightUnsigned tokenData0,
            LeftRightUnsigned tokenData1,
            PositionBalance globalUtilizations
        )
    {
        LeftRightUnsigned tokensRequired;
        LeftRightUnsigned creditAmounts;
        (tokensRequired, creditAmounts, globalUtilizations) = _getTotalRequiredCollateral(
            positionBalanceArray,
            positionIdList,
            atTick,
            longPremia
        );
        uint256 balance0;
        uint256 balance1;
        uint256 interest0;
        uint256 interest1;
        unchecked {
            (balance0, interest0) = ct0.assetsAndInterest(user);
            (balance1, interest1) = ct1.assetsAndInterest(user);

            // Insolvent-interest case: a user cannot pay more interest than their balance.
            // Cap interest to available balance and zero the balance so we don't treat the same funds
            // as both spendable collateral and interest payment.
            // The capped interest is later added to collateral requirements.
            if (interest0 > balance0) {
                interest0 = balance0; // Cap interest
                balance0 = 0; // Zero balance
            } else {
                balance0 -= interest0; // Subtract interest from balance
                interest0 = 0; // Zero interest (nothing to add to requirements)
            }
            if (interest1 > balance1) {
                interest1 = balance1;
                balance1 = 0;
            } else {
                balance1 -= interest1; // Subtract interest from balance
                interest1 = 0; // Zero interest (nothing to add to requirements)
            }
        }
        unchecked {
            balance0 += shortPremia.rightSlot();
            balance1 += shortPremia.leftSlot();

            balance0 += creditAmounts.rightSlot();
            balance1 += creditAmounts.leftSlot();
            tokensRequired = tokensRequired.addToRightSlot(uint128(interest0)).addToLeftSlot(
                uint128(interest1)
            );
        }
        tokenData0 = LeftRightUnsigned.wrap(balance0.toUint128()).addToLeftSlot(
            tokensRequired.rightSlot()
        );

        tokenData1 = LeftRightUnsigned.wrap(balance1.toUint128()).addToLeftSlot(
            tokensRequired.leftSlot()
        );
    }

    /// @notice Gets the highest pool utilization (for token0 and token1) from an array of positions.
    /// @dev Iterates through all of a user's positions to find the maximum `utilization0` and maximum `utilization1`
    /// recorded at the time of minting. These "global" max utilizations are then used for
    /// portfolio-level margin calculations, ensuring a more conservative risk assessment.
    /// @param positionBalanceArray The array of a user's `PositionBalance` structs.
    /// @return globalUtilizations A packed PositionBalance that contains only the utilization data, recoverable as .utilization0() and .utilization1()
    function _getGlobalUtilization(
        PositionBalance[] calldata positionBalanceArray
    ) internal pure returns (PositionBalance globalUtilizations) {
        int256 utilization0;
        int256 utilization1;
        uint256 pLength = positionBalanceArray.length;

        for (uint256 i; i < pLength; ) {
            PositionBalance positionBalance = positionBalanceArray[i];

            int256 _utilization0 = positionBalance.utilization0();
            int256 _utilization1 = positionBalance.utilization1();

            // utilizations are always positive, so can compare directly here
            utilization0 = _utilization0 > utilization0 ? _utilization0 : utilization0;
            utilization1 = _utilization1 > utilization1 ? _utilization1 : utilization1;
            unchecked {
                ++i;
            }
        }

        unchecked {
            // can never miscast because utilization < 10_000
            globalUtilizations = PositionBalanceLibrary.storeBalanceData(
                0,
                uint32(uint256(utilization0) + (uint256(utilization1) << 16)),
                0
            );
        }
    }

    /// @notice Get the total required amount of collateral tokens of a user/account across all active positions to stay above the margin requirement.
    /// @dev Returns the token amounts required for the entire account with active positions in `positionIdList` (list of tokenIds).
    /// @param positionBalanceArray The list of all open positions held by the `optionOwner`, stored as `[balance/poolUtilizationAtMint, ...]`
    /// @param positionIdList The list of all option positions held by `owner`
    /// @param atTick The tick at which to evaluate the account's positions
    /// @return tokensRequired The amount of token0 (right) and token1 (left) required to stay above the margin threshold for all active positions of user
    /// @return creditAmounts The amount of credit token0 (right) and token1 (left) in the user's portfolio
    function _getTotalRequiredCollateral(
        PositionBalance[] calldata positionBalanceArray,
        TokenId[] calldata positionIdList,
        int24 atTick,
        LeftRightUnsigned longPremia
    )
        internal
        view
        returns (
            LeftRightUnsigned tokensRequired,
            LeftRightUnsigned creditAmounts,
            PositionBalance globalUtilizations
        )
    {
        // get the global utilizations, which is the max utilizations for all open positions
        globalUtilizations = _getGlobalUtilization(positionBalanceArray);
        // add long premia to tokens required
        tokensRequired = tokensRequired.add(longPremia);

        for (uint256 i; i < positionBalanceArray.length; ) {
            uint256 _tokenRequired0;
            uint256 _credits0;
            uint256 _tokenRequired1;
            uint256 _credits1;
            {
                TokenId tokenId = positionIdList[i];
                PositionBalance positionBalance = positionBalanceArray[i];
                uint128 positionSize = positionBalance.positionSize();
                int24 _atTick = atTick;

                unchecked {
                    // can never miscast because utilization < 10_000
                    // Use the global utilizations for all positions
                    int16 utilization0 = int16(globalUtilizations.utilization0());
                    (_tokenRequired0, _credits0) = _getRequiredCollateralAtTickSinglePosition(
                        tokenId,
                        positionSize,
                        _atTick,
                        utilization0,
                        true
                    );
                }
                unchecked {
                    // can never miscast because utilization < 10_000
                    // Use the global utilizations for all positions
                    int16 utilization1 = int16(globalUtilizations.utilization1());
                    (_tokenRequired1, _credits1) = _getRequiredCollateralAtTickSinglePosition(
                        tokenId,
                        positionSize,
                        _atTick,
                        utilization1,
                        false
                    );
                }
            }
            tokensRequired = tokensRequired
                .addToRightSlot(_tokenRequired0.toUint128())
                .addToLeftSlot(_tokenRequired1.toUint128());
            creditAmounts = creditAmounts.addToRightSlot(_credits0.toUint128()).addToLeftSlot(
                _credits1.toUint128()
            );
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Get the required amount of collateral tokens corresponding to a specific single position `tokenId` at a price `atTick`.
    /// @param tokenId The option position
    /// @param positionSize The size of the option position
    /// @param atTick The tick at which to evaluate the account's positions
    /// @param poolUtilization The utilization of the collateral vault (balance of buying and selling)
    /// @param underlyingIsToken0 Cached `s_underlyingIsToken0` value for this CollateralTracker instance
    /// @return tokenRequired Total required tokens for all legs of the specified tokenId.
    function _getRequiredCollateralAtTickSinglePosition(
        TokenId tokenId,
        uint128 positionSize,
        int24 atTick,
        int16 poolUtilization,
        bool underlyingIsToken0
    ) internal view returns (uint256 tokenRequired, uint256 credits) {
        uint256 numLegs = tokenId.countLegs();

        unchecked {
            for (uint256 index = 0; index < numLegs; ++index) {
                // bypass the collateral calculation if tokenType doesn't match the requested token (underlyingIsToken0)
                if (tokenId.tokenType(index) != (underlyingIsToken0 ? 0 : 1)) continue;

                if (tokenId.width(index) == 0 && tokenId.isLong(index) == 1) {
                    LeftRightUnsigned amountsMoved = PanopticMath.getAmountsMoved(
                        tokenId,
                        positionSize,
                        index,
                        false
                    );
                    credits = tokenId.tokenType(index) == 0
                        ? amountsMoved.rightSlot()
                        : amountsMoved.leftSlot();
                }
                // Increment the tokenRequired accumulator
                tokenRequired += _getRequiredCollateralSingleLeg(
                    tokenId,
                    index,
                    positionSize,
                    atTick,
                    poolUtilization
                );
            }
        }
    }

    /// @notice Calculate the required amount of collateral for a single leg `index` of position `tokenId`.
    /// @param tokenId The option position
    /// @param index The leg index (associated with a liquidity chunk) to compute the required collateral for
    /// @param positionSize The size of the position
    /// @param atTick The tick at which to evaluate the account's positions
    /// @param poolUtilization The pool utilization: how much funds are in the Panoptic pool versus the AMM pool
    /// @return required The required amount collateral needed for this leg `index`
    function _getRequiredCollateralSingleLeg(
        TokenId tokenId,
        uint256 index,
        uint128 positionSize,
        int24 atTick,
        int16 poolUtilization
    ) internal view returns (uint256 required) {
        return
            tokenId.riskPartner(index) == index // does this leg have a risk partner? Affects required collateral
                ? _getRequiredCollateralSingleLegNoPartner(
                    tokenId,
                    index,
                    positionSize,
                    atTick,
                    poolUtilization
                )
                : _getRequiredCollateralSingleLegPartner(
                    tokenId,
                    index,
                    positionSize,
                    atTick,
                    poolUtilization
                );
    }

    /// @notice Calculate the required amount of collateral for leg `index` of position `tokenId` when the leg does not have a risk partner.
    /// @param tokenId The option position
    /// @param index The leg index (associated with a liquidity chunk) to consider a partner for
    /// @param positionSize The size of the position
    /// @param atTick The tick at which to evaluate the account's positions
    /// @param poolUtilization The pool utilization: ratio of how much funds are in the Panoptic pool versus the AMM pool
    /// @return required The required amount collateral needed for this leg `index`
    function _getRequiredCollateralSingleLegNoPartner(
        TokenId tokenId,
        uint256 index,
        uint128 positionSize,
        int24 atTick,
        int16 poolUtilization
    ) internal view returns (uint256 required) {
        // extract the tokenType (token0 or token1)
        uint256 tokenType = tokenId.tokenType(index);

        // compute the total amount of funds moved for that position
        // Since this is a collateral check, we want the amounts moved upon closure, not upon opening
        LeftRightUnsigned amountsMoved = PanopticMath.getAmountsMoved(
            tokenId,
            positionSize,
            index,
            false
        );

        // amount moved is right slot if tokenType=0, left slot otherwise
        uint128 amountMoved = tokenType == 0 ? amountsMoved.rightSlot() : amountsMoved.leftSlot();

        uint256 isLong = tokenId.isLong(index);
        unchecked {
            // if the width is 0, then this is a loan/credit
            if (tokenId.width(index) == 0) {
                if (isLong == 0) {
                    // buying power requirement for a Loan position is 100% + MAINT_MARGIN_RATE
                    required = Math.mulDivRoundingUp(
                        amountMoved,
                        MAINT_MARGIN_RATE + DECIMALS,
                        DECIMALS
                    );
                } else {
                    // buying power requirement for a Credit position is 0
                    // this is not netted against other legs unless it has a partner
                    required = 0;
                }
            } else {
                // required collateral is at least 1
                required = 1;

                uint256 baseCollateralRatio;
                {
                    uint256 baseRequired;
                    // start with base requirement, which is based on isLong value
                    (baseRequired, baseCollateralRatio) = _getRequiredCollateralAtUtilization(
                        amountMoved,
                        isLong,
                        poolUtilization
                    );
                    required += baseRequired;
                }
                (int24 tickLower, int24 tickUpper) = tokenId.asTicks(index);
                int24 strike = tokenId.strike(index);

                if (isLong == 0) {
                    // if position is short, check whether the position is out-the-money

                    // if position is ITM or ATM, then the collateral requirement depends on price:

                    // We must first get the ratio of strike to price for calls (or price to strike for puts).
                    // Both of these ratios decrease as the position becomes deeper ITM.
                    // We must clamp the difference between atTick and strike to the min & max Uniswap ticks,
                    // to conform with what getSqrtRatioAtTick can support.
                    // This is acceptable because a higher ratio will result in an increased slope for the collateral requirement.
                    // (- and * 2 in tick space are / and ^ 2 in price space so sqrtRatioAtTick(2 *(a - b)) = a/b (*2^96)
                    uint160 ratio = tokenType == 1 // tokenType
                        ? Math.getSqrtRatioAtTick(
                            int24(
                                Math.bound(
                                    2 * (atTick - strike),
                                    Constants.MIN_POOL_TICK,
                                    Constants.MAX_POOL_TICK
                                )
                            )
                        ) // puts ->  price/strike
                        : Math.getSqrtRatioAtTick(
                            int24(
                                Math.bound(
                                    2 * (strike - atTick),
                                    Constants.MIN_POOL_TICK,
                                    Constants.MAX_POOL_TICK
                                )
                            )
                        ); // calls -> strike/price

                    // Following Reg-T guidelines, the collateral requirement is the max of:
                    //    - 10% of the notional value at the strike price (r0)
                    //    - 20% of the underlying price MINUS the out-the-money amount (r1)
                    // Note that we over-estimate the capital composition between the LP position's range.

                    uint256 r0 = required / 2;

                    uint256 r1;
                    {
                        uint256 p0 = amountMoved + Math.mulDiv96RoundingUp(required, ratio);
                        uint256 p1 = Math.mulDiv96RoundingUp(amountMoved, ratio);

                        r1 = p0 > p1 ? p0 - p1 : 0;
                    }
                    uint256 r2;

                    if ((atTick < tickUpper) && (atTick >= tickLower)) {
                        // position is in-range (ie. current tick is between upper+lower tick): we draw a line between the
                        // collateral requirement at the lowerTick and the one at the upperTick. We use that interpolation as
                        // the collateral requirement when in-range, which always over-estimates the amount of token required
                        // Specifically:

                        uint160 scaleFactor = Math.getSqrtRatioAtTick((tickUpper - tickLower));
                        r2 =
                            Math.mulDivRoundingUp(
                                amountMoved * (DECIMALS - baseCollateralRatio),
                                (scaleFactor - ratio),
                                DECIMALS * (scaleFactor + Constants.FP96)
                            ) +
                            r0;
                    }
                    required = Math.max(Math.max(r2, r1), r0);
                } else {
                    uint256 positionWidth = uint256(uint24(tickUpper - tickLower));

                    uint256 distanceFromStrike = Math.max(
                        positionWidth / 2,
                        atTick > strike
                            ? uint256(uint24(atTick - strike))
                            : uint256(uint24(strike - atTick))
                    );

                    // Calculate the exponent: distance / width

                    uint256 expValue;
                    {
                        uint256 scaledRatio = (distanceFromStrike * DECIMALS) / (positionWidth);
                        // Divide by ln(2) to get the number of doublings
                        // LN2_SCALED = ln(2) * DECIMALS
                        uint256 shifts = scaledRatio / LN2_SCALED;
                        uint256 remainder = scaledRatio % LN2_SCALED;

                        // Calculate e^(remainder/DECIMALS) - now always less than e^(ln(2)) = 2
                        // This means Taylor expansion is very accurate
                        uint256 expFractional = Math.sTaylorCompounded(remainder, DECIMALS);
                        // Combine: e^x = 2^shifts * e^remainder
                        // We divide by DECIMALS at the end to maintain precision
                        if (shifts < 128) {
                            // Prevent overflow
                            expValue = (expFractional << shifts);
                        } else {
                            expValue = type(uint128).max; // Cap at uint128 max value
                        }
                    }
                    // Apply the exponential decay to required collateral
                    uint256 _required = required;
                    required = Math.min(
                        required,
                        (DECIMALS * _required * positionWidth) /
                            (distanceFromStrike * expValue) +
                            TEN_BPS
                    );
                }
            }
        }
    }

    /// @notice Calculate the required amount of collateral for leg `index` for position `tokenId` accounting for its partner leg.
    /// @dev If the two `isLong` fields are different (i.e., a short leg and a long leg are partnered) but the tokenTypes are the same, this is a spread.
    /// @dev A spread is a defined risk position which has a max loss given by difference between the long and short strikes.
    /// @dev If the two `isLong` fields are the same but the tokenTypes are different (one is a call, the other a put, e.g.), this is a strangle -
    /// a strangle benefits from enhanced capital efficiency because only one side can be ITM at any given time.
    /// @param tokenId The option position
    /// @param index The leg index (associated with a liquidity chunk) to consider a partner for
    /// @param positionSize The size of the position
    /// @param atTick The tick at which to evaluate the account's positions
    /// @param poolUtilization The pool utilization: how much funds are in the Panoptic pool versus the AMM pool
    /// @return required The required amount of collateral needed for this leg `index`
    function _getRequiredCollateralSingleLegPartner(
        TokenId tokenId,
        uint256 index,
        uint128 positionSize,
        int24 atTick,
        int16 poolUtilization
    ) internal view returns (uint256) {
        // extract partner index (associated with another liquidity chunk)
        uint256 partnerIndex = tokenId.riskPartner(index);

        // In the following, we check whether the risk partner of this leg is itself
        // or another leg in this position.
        // Handles case where riskPartner(i) != i ==> leg i has a risk partner that is another leg
        // @dev In summary, the allowed risk partners:
        //
        // PURE OPTIONS
        // -Short Strangles/Straddles (short put + short call) = each leg's basic requirement is 50% less
        // -Vertical Spreads and Calendar Spreads (short put + long put) or (short call + long call) = requirement is max loss
        // -Synthetic Stocks (short put + long call) or (short call + long put) = requirement is short leg only
        //
        // FUNDED OPTIONS
        // -Prepaid long option (long put or call + credit) "Purchases pre-pays for the cost of the option" = requirement is max(long - credit, 1)
        // -Upfront short option (short put or call + loan) "Upfront payment to seller" = requirement is max(loan, short option)
        // -Option-protected loan (long put or call + loan) "Get a loan with an embedded long option for capital protection" = requirement is max(loan, short option)
        // -Cash-Secured Option (short put or call + credit) "Allocate collateral to that specific option" = requirement is max(short - credit, 1)
        //
        // TOKEN TRANSFERS
        // - Delayed Swap (credit at one strike, loan at another; different amounts = effective swap) = requirement is max(loan0 - convert1to0(credit), 1) or max(loan1 - convert0to1(credit), 1)
        {
            // only proceed if the partners have the same asset
            if (
                tokenId.asset(partnerIndex) == tokenId.asset(index) &&
                tokenId.optionRatio(partnerIndex) == tokenId.optionRatio(index)
            ) {
                // witdh of associated legs, true if greater than 0 (ie. it is an option leg)
                bool _width = tokenId.width(index) > 0;
                bool widthP = tokenId.width(partnerIndex) > 0;
                // long/short status of associated legs
                uint256 _isLong = tokenId.isLong(index);
                uint256 isLongP = tokenId.isLong(partnerIndex);

                // token type status of associated legs (call/put)
                uint256 _tokenType = tokenId.tokenType(index);
                uint256 tokenTypeP = tokenId.tokenType(partnerIndex);

                // if both legs are options
                if (_width && widthP) {
                    if (_tokenType != tokenTypeP) {
                        if (_isLong == 0 && isLongP == 0) {
                            // STRANGLES: different token types, both short
                            return
                                _computeStrangle(
                                    tokenId,
                                    index,
                                    positionSize,
                                    atTick,
                                    poolUtilization
                                );
                        } else if (
                            _isLong != isLongP &&
                            tokenId.strike(index) == tokenId.strike(partnerIndex)
                        ) {
                            // SYNTHETIC STOCK: different token types, one is long and the other is short. MUST BE AT THE SAME STRIKE
                            return
                                // return the collateral requirement of the short leg only (the long leg comes for free™)
                                _isLong == 0
                                    ? _getRequiredCollateralSingleLegNoPartner(
                                        tokenId,
                                        index,
                                        positionSize,
                                        atTick,
                                        poolUtilization
                                    )
                                    : 0;
                        }
                    } else {
                        if (_isLong != isLongP) {
                            // SPREADS: same token type, one is long and the other is short
                            return
                                // only return the requirement once for the first leg it encounters
                                index < partnerIndex
                                    ? _computeSpread(
                                        tokenId,
                                        positionSize,
                                        index,
                                        partnerIndex,
                                        atTick,
                                        poolUtilization
                                    )
                                    : 0;
                        }
                    }
                } else if (_width != widthP) {
                    if (_tokenType == tokenTypeP) {
                        if (isLongP == 1) {
                            // CASH-SECURED OPTION
                            // PREPAID LONG OPTION
                            // only compute it once for the option leg
                            return
                                _width
                                    ? _computeCreditOptionComposite(
                                        tokenId,
                                        positionSize,
                                        index,
                                        atTick
                                    )
                                    : 0;
                        } else {
                            // OPTION-PROTECTED LOAN
                            // UPFRONT SHORT OPTION
                            // only compute it once for the option leg
                            return
                                _width
                                    ? _computeLoanOptionComposite(
                                        tokenId,
                                        positionSize,
                                        index,
                                        partnerIndex,
                                        atTick,
                                        poolUtilization
                                    )
                                    : 0;
                        }
                    }
                } else {
                    if (_tokenType != tokenTypeP) {
                        // TOKEN TRANSFERS
                        if (_isLong != isLongP) {
                            // DELAYED SWAP
                            // only compute it once for the loan side
                            return
                                _isLong == 0
                                    ? _computeDelayedSwap(
                                        tokenId,
                                        positionSize,
                                        index,
                                        partnerIndex,
                                        atTick
                                    )
                                    : 0;
                        }
                    }
                }
            }
        }

        // otherwise, not a list of allowed strategies. Return the single-leg collateral requirement
        return
            _getRequiredCollateralSingleLegNoPartner(
                tokenId,
                index,
                positionSize,
                atTick,
                poolUtilization
            );
    }

    /// @notice Get the base collateral requirement for a position of notional value `amount` at the current Panoptic pool `utilization` level.
    /// @param amount The amount to multiply by the base collateral ratio
    /// @param isLong Whether the position is long (=1) or short (=0)
    /// @param utilization The utilization of the Panoptic pool (balance between sellers and buyers)
    /// @return required The base collateral requirement corresponding to the incoming `amount`
    function _getRequiredCollateralAtUtilization(
        uint128 amount,
        uint256 isLong,
        int16 utilization
    ) internal view returns (uint256 required, uint256 baseCollateralRatio) {
        // if position is short, use sell collateral ratio

        if (isLong == 0) {
            // compute the sell collateral ratio, which depends on the pool utilization
            baseCollateralRatio = _sellCollateralRatio(utilization);

            // compute required as amount*collateralRatio
            // can use unsafe because denominator is always nonzero
            unchecked {
                required = Math.unsafeDivRoundingUp(amount * baseCollateralRatio, DECIMALS);
            }
        } else if (isLong == 1) {
            // if options is long, use buy collateral ratio
            // compute the buy collateral ratio, which depends on the pool utilization
            baseCollateralRatio = _buyCollateralRatio();

            // compute required as amount*collateralRatio
            // can use unsafe because denominator is always nonzero
            unchecked {
                required = Math.unsafeDivRoundingUp(amount * baseCollateralRatio, DECIMALS);
            }
        }
    }

    /// @notice Calculates the total collateral requirement for a defined-risk spread position.
    /// @dev A spread's collateral is the minimum of its defined max loss or the sum of its legs' individual (unpartnered) requirements.
    /// @dev This provides capital efficiency, as deep OTM spreads may require less collateral than their max loss due to OTM decay on the long leg.
    /// @param tokenId The option position
    /// @param positionSize The size of the position
    /// @param index The leg index of the LONG leg in the spread position
    /// @param partnerIndex The index of the partnered SHORT leg in the spread position
    /// @param atTick the tick the requirement is evaluated at
    /// @param poolUtilization The pool utilization: how much funds are in the Panoptic pool versus the AMM pool
    /// @return spreadRequirement The required amount of collateral needed for the spread
    function _computeSpread(
        TokenId tokenId,
        uint128 positionSize,
        uint256 index,
        uint256 partnerIndex,
        int24 atTick,
        int16 poolUtilization
    ) internal view returns (uint256 spreadRequirement) {
        spreadRequirement = 1;

        uint256 splitRequirement;
        unchecked {
            uint256 _required = _getRequiredCollateralSingleLegNoPartner(
                tokenId,
                index,
                positionSize,
                atTick,
                poolUtilization
            );
            uint256 requiredPartner = _getRequiredCollateralSingleLegNoPartner(
                tokenId,
                partnerIndex,
                positionSize,
                atTick,
                poolUtilization
            );
            splitRequirement = _required + requiredPartner;
        }

        uint128 moved0;
        uint128 moved1;
        uint128 moved0Partner;
        uint128 moved1Partner;
        uint256 tokenType = tokenId.tokenType(index);
        {
            // compute the total amount of funds moved for the position's current leg
            // Since this is returning a collateral requirement, we want to return the amounts moved upon closure, not opening
            LeftRightUnsigned amountsMoved = PanopticMath.getAmountsMoved(
                tokenId,
                positionSize,
                index,
                false
            );
            unchecked {
                // This is a CALENDAR SPREAD adjustment, where the collateral requirement is the max loss of the position
                // real formula is contractSize * (1/(sqrt(r1)+1) - 1/(sqrt(r2)+1))
                // Taylor expand to get a rough approximation of: contractSize * ∆width * tickSpacing / 40000
                // This is strictly larger than the real one, so OK to use that for a collateral requirement.
                TokenId _tokenId = tokenId;
                int24 deltaWidth = _tokenId.width(index) - _tokenId.width(partnerIndex);

                // TODO check if same strike and same width is allowed -> Think not from TokenId.sol?
                if (deltaWidth < 0) deltaWidth = -deltaWidth;

                if (tokenType == 0) {
                    spreadRequirement +=
                        (amountsMoved.rightSlot() *
                            uint256(int256(deltaWidth * _tokenId.tickSpacing()))) /
                        80000;
                } else {
                    spreadRequirement +=
                        (amountsMoved.leftSlot() *
                            uint256(int256(deltaWidth * _tokenId.tickSpacing()))) /
                        80000;
                }
            }

            moved0 = amountsMoved.rightSlot();
            moved1 = amountsMoved.leftSlot();

            {
                // compute the total amount of funds moved for the position's partner leg
                LeftRightUnsigned amountsMovedPartner = PanopticMath.getAmountsMoved(
                    tokenId,
                    positionSize,
                    partnerIndex,
                    false
                );

                moved0Partner = amountsMovedPartner.rightSlot();
                moved1Partner = amountsMovedPartner.leftSlot();
            }
        }

        // compute the max loss of the spread

        // if asset is NOT the same as the tokenType, the required amount is simply the difference in notional values
        // ie. asset = 1, tokenType = 0:
        if (tokenId.asset(index) != tokenType) {
            unchecked {
                // always take the absolute values of the difference of amounts moved
                if (tokenType == 0) {
                    spreadRequirement += moved0 < moved0Partner
                        ? moved0Partner - moved0
                        : moved0 - moved0Partner;
                } else {
                    spreadRequirement += moved1 < moved1Partner
                        ? moved1Partner - moved1
                        : moved1 - moved1Partner;
                }
            }
        } else {
            unchecked {
                uint256 notional;
                uint256 notionalP;
                uint128 contracts;
                if (tokenType == 1) {
                    notional = moved0;
                    notionalP = moved0Partner;
                    contracts = moved1;
                } else {
                    notional = moved1;
                    notionalP = moved1Partner;
                    contracts = moved0;
                }
                // the required amount is the amount of contracts multiplied by (notional1 - notional2)/max(notional1, notional2)
                // can use unsafe because denominator is always nonzero
                spreadRequirement += (notional < notionalP)
                    ? Math.unsafeDivRoundingUp((notionalP - notional) * contracts, notionalP)
                    : Math.unsafeDivRoundingUp((notional - notionalP) * contracts, notional);
            }
        }

        spreadRequirement = Math.min(splitRequirement, spreadRequirement);
    }

    /// @notice Calculate the required amount of collateral for a strangle leg.
    /// @dev The base collateral requirement is halved for short strangles.
    /// @dev A strangle can only have only one of its legs ITM at any given time, so this reduces the total risk and collateral requirement.
    /// @param tokenId The option position
    /// @param positionSize The size of the position
    /// @param index The leg index (associated with a liquidity chunk) to consider a partner for
    /// @param atTick The tick at which to evaluate the account's positions
    /// @param poolUtilization The pool utilization: how much funds are in the Panoptic pool versus the AMM pool
    /// @return strangleRequired The required amount of collateral needed for the strangle leg
    function _computeStrangle(
        TokenId tokenId,
        uint256 index,
        uint128 positionSize,
        int24 atTick,
        int16 poolUtilization
    ) internal view returns (uint256 strangleRequired) {
        // If both tokenTypes are the same, then this is a short strangle.
        // A strangle is an options strategy in which the investor holds a position
        // in both a call and a put option with different strike prices,
        // but with the same expiration date and underlying asset.

        /// collateral requirement is for short strangles depicted:
        /**
                    Put side of a short strangle, BPR = 100% - (100% - SCR/2)*(price/strike)
           BUYING
           POWER
           REQUIREMENT
                         ^                    .
                         |           <- ITM   .  OTM ->
                  100% - |--__                .
                         |    ¯¯--__          .
                         |          ¯¯--__    .
                 SCR/2 - |                ¯¯--______ <------ base collateral is half that of a single-leg
                         +--------------------+--->   current
                         0                  strike     price
         */
        unchecked {
            // A negative pool utilization is used to denote a position which is a strangle
            // add 1 to handle poolUtilization = 0
            poolUtilization = -(poolUtilization == 0 ? int16(1) : poolUtilization);

            return
                strangleRequired = _getRequiredCollateralSingleLegNoPartner(
                    tokenId,
                    index,
                    positionSize,
                    atTick,
                    poolUtilization
                );
        }
    }

    function _computeLoanOptionComposite(
        TokenId tokenId,
        uint128 positionSize,
        uint256 index,
        uint256 partnerIndex,
        int24 atTick,
        int16 poolUtilization
    ) internal view returns (uint256) {
        // compute both token requirements. Can directly compare them because they have the same tokenType
        uint256 _required = _getRequiredCollateralSingleLegNoPartner(
            tokenId,
            index,
            positionSize,
            atTick,
            poolUtilization
        );
        uint256 requiredPartner = _getRequiredCollateralSingleLegNoPartner(
            tokenId,
            partnerIndex,
            positionSize,
            atTick,
            poolUtilization
        );

        unchecked {
            if (tokenId.isLong(index) == 0) {
                return _required + requiredPartner;
            } else {
                // return the max of the requirement between a loan and the long option position
                return Math.max(_required, requiredPartner);
            }
        }
    }

    function _computeCreditOptionComposite(
        TokenId tokenId,
        uint128 positionSize,
        uint256 index,
        int24 atTick
    ) internal view returns (uint256) {
        // can only be called when partnerIndex is the credit
        // required amount for the option leg
        // Assume 100% utilization, which means
        //  - 100% collateralization for sold options (cash account requirement)
        uint256 _required = _getRequiredCollateralSingleLegNoPartner(
            tokenId,
            index,
            positionSize,
            atTick,
            MAX_UTILIZATION
        );

        return _required;
    }

    function _computeDelayedSwap(
        TokenId tokenId,
        uint128 positionSize,
        uint256 index,
        uint256 partnerIndex,
        int24 atTick
    ) internal view returns (uint256) {
        unchecked {
            // can only be called when partnerIndex is the credit
            LeftRightUnsigned amountsMoved = PanopticMath.getAmountsMoved(
                tokenId,
                positionSize,
                index,
                false
            );

            LeftRightUnsigned amountsMovedP = PanopticMath.getAmountsMoved(
                tokenId,
                positionSize,
                partnerIndex,
                false
            );

            uint256 loanAmount = tokenId.tokenType(index) == 0
                ? amountsMoved.rightSlot()
                : amountsMoved.leftSlot();
            uint256 required = Math.mulDivRoundingUp(
                loanAmount,
                SELLER_COLLATERAL_RATIO + DECIMALS,
                DECIMALS
            );

            uint256 creditAmount = tokenId.tokenType(partnerIndex) == 0
                ? amountsMovedP.rightSlot()
                : amountsMovedP.leftSlot();

            uint256 convertedCredit = tokenId.tokenType(partnerIndex) == 0
                ? PanopticMath.convert0to1RoundingUp(creditAmount, Math.getSqrtRatioAtTick(atTick))
                : PanopticMath.convert1to0RoundingUp(creditAmount, Math.getSqrtRatioAtTick(atTick));

            if (required > convertedCredit) {
                return required;
            } else {
                return convertedCredit;
            }
        }
    }

    /// @notice Get the base collateral requirement for a short leg at a given pool utilization.
    /// @dev This is computed at the time the position is minted.
    /// @param utilization The pool utilization of this collateral vault at the time the position is minted
    /// @return sellCollateralRatio The sell collateral ratio at `utilization`
    function _sellCollateralRatio(
        int256 utilization
    ) internal view returns (uint256 sellCollateralRatio) {
        // the sell ratio is on a straight line defined between two points (x0,y0) and (x1,y1):
        //   (x0,y0) = (targetPoolUtilization,min_sell_ratio) and
        //   (x1,y1) = (saturatedPoolUtilization,max_sell_ratio)
        // the line's formula: y = a * (x - x0) + y0, where a = (y1 - y0) / (x1 - x0)
        /*
            SELL
            COLLATERAL
            RATIO
                          ^
                          |                  max ratio = 100%
                   100% - |                _------
                          |             _-¯
                          |          _-¯
                    20% - |---------¯
                          |         .       . .
                          +---------+-------+-+--->   POOL_
                                   50%    90% 100%     UTILIZATION
        */

        uint256 min_sell_ratio = SELLER_COLLATERAL_RATIO;
        /// if utilization is less than zero, this is the calculation for a strangle, which gets 2x the capital efficiency at low pool utilization
        if (utilization < 0) {
            unchecked {
                min_sell_ratio /= 2;
                utilization = -utilization;
            }
        }

        unchecked {
            utilization *= 1_000;
        }
        // return the basal sell ratio if pool utilization is lower than target
        if (uint256(utilization) < TARGET_POOL_UTIL) {
            return min_sell_ratio;
        }

        // return 100% collateral ratio if utilization is above saturated pool utilization
        if (uint256(utilization) > SATURATED_POOL_UTIL) {
            return DECIMALS;
        }

        unchecked {
            return
                min_sell_ratio +
                ((DECIMALS - min_sell_ratio) * (uint256(utilization) - TARGET_POOL_UTIL)) /
                (SATURATED_POOL_UTIL - TARGET_POOL_UTIL);
        }
    }

    /// @notice Get the base collateral requirement for a long leg at a given pool utilization.
    /// @dev This is computed at the time the position is minted.
    /// @return buyCollateralRatio The buy collateral ratio at `utilization`
    function _buyCollateralRatio() internal view returns (uint256 buyCollateralRatio) {
        return BUYER_COLLATERAL_RATIO;
    }

    /// @notice Get the cross buffer ration for a given utilization
    /// @dev This is computed using the global utilization of the user.
    /// @param utilization The pool utilization of this collateral vault at the time the position is minted
    /// @return crossBufferRatio The cross buffer ratio at `utilization`
    function _crossBufferRatio(
        int256 utilization,
        uint256 crossBuffer
    ) internal view returns (uint256 crossBufferRatio) {
        // linear from crossBuffer to 0 between 50% and 90%
        // the buy ratio is on a straight line defined between two points (x0,y0) and (x1,y1):
        //   (x0,y0) = (targetPoolUtilization, crossBuffer) and
        //   (x1,y1) = (saturatedPoolUtilization, 0)
        // note that y1<y0 so the slope is negative:
        // aka the cross buffer starts high and drops to zero with increased utilization
        // the line's formula: y = a * (x - x0) + y0, where a = (y1 - y0) / (x1 - x0)
        // but since a<0, we rewrite as:
        // y = a' * (x0 - x) + y0, where a' = (y0 - y1) / (x1 - x0)

        /*
          CROSS
          BUFFER
          RATIO
                 ^
                 |   cross_buffer = 80%
           80% - |----------_
                 |         . ¯-_
                 |         .    ¯-_
           0% -  +---------+-------∓---+--->   POOL_
                          50%     90% 100%      UTILIZATION
         */
        unchecked {
            uint256 utilizationScaled = uint256(utilization * 1_000);
            // return the basal cross buffer ratio if pool utilization is lower than target
            if (utilizationScaled < TARGET_POOL_UTIL) {
                return crossBuffer;
            }

            // return 0 if pool utilization is above saturated pool utilization
            if (utilizationScaled > SATURATED_POOL_UTIL) {
                return 0;
            }

            return ((crossBuffer * (SATURATED_POOL_UTIL - utilizationScaled)) /
                (SATURATED_POOL_UTIL - TARGET_POOL_UTIL));
        }
    }

    /*//////////////////////////////////////////////////////////////
                  ADAPTIVE INTEREST RATE MODEL
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates the current interest rate based on utilization
    /// @param utilization The current pool utilization
    /// @param interestRateAccumulator The current state of the interest rate accumulator
    /// @return The calculated interest rate per second
    function interestRate(
        uint256 utilization,
        MarketState interestRateAccumulator
    ) external view returns (uint128) {
        (uint256 avgRate, ) = _borrowRate(utilization, interestRateAccumulator);
        return uint128(avgRate);
    }

    /// @notice Calculates both the average interest rate and the new rate at target
    /// @param utilization The current pool utilization
    /// @param interestRateAccumulator The current state of the interest rate accumulator
    /// @return The average interest rate
    /// @return The new rate at target
    function updateInterestRate(
        uint256 utilization,
        MarketState interestRateAccumulator
    ) external view returns (uint128, uint256) {
        (uint256 avgRate, int256 endRateAtTarget) = _borrowRate(
            utilization,
            interestRateAccumulator
        );
        return (uint128(avgRate), uint256(endRateAtTarget));
    }

    /// @dev Returns avgRate and endRateAtTarget.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    function _borrowRate(
        uint256 utilization,
        MarketState interestRateAccumulator
    ) internal view returns (uint256, int256) {
        unchecked {
            // Safe "unchecked" cast because the utilization is smaller than 1 (scaled by WAD).
            int256 _utilization = int256(utilization);
            int256 errNormFactor = int256(_utilization) > TARGET_UTILIZATION
                ? WAD - TARGET_UTILIZATION
                : TARGET_UTILIZATION;
            int256 err = Math.wDivToZero(_utilization - TARGET_UTILIZATION, errNormFactor);

            // 38-bit rateAtTarget, 32-bit epoch<<2 in accumulator
            int256 startRateAtTarget = int256(uint256(interestRateAccumulator.rateAtTarget()));

            // convert from epoch to time. Used to avoid Y2K38
            uint256 previousTime = interestRateAccumulator.marketEpoch() << 2;

            int256 avgRateAtTarget;
            int256 endRateAtTarget;

            if (startRateAtTarget == 0) {
                // First interaction.
                avgRateAtTarget = INITIAL_RATE_AT_TARGET;
                endRateAtTarget = INITIAL_RATE_AT_TARGET;
            } else {
                // The speed is assumed constant between two updates, but it is in fact not constant because of interest.
                // So the rate is always underestimated.
                int256 speed = Math.wMulToZero(ADJUSTMENT_SPEED, err);
                // Safe "unchecked" cast because block.timestamp - market.lastUpdate <= block.timestamp <= type(int256).max.
                // Cap the elapsed time to prevent IRM drift
                int256 elapsed = Math.min(
                    int256(block.timestamp) - int256(previousTime),
                    IRM_MAX_ELAPSED_TIME
                );
                int256 linearAdaptation = speed * elapsed;

                if (linearAdaptation == 0) {
                    // If linearAdaptation == 0, avgRateAtTarget = endRateAtTarget = startRateAtTarget;
                    avgRateAtTarget = startRateAtTarget;
                    endRateAtTarget = startRateAtTarget;
                } else {
                    // Formula of the average rate that should be returned to Morpho Blue:
                    // avg = 1/T * ∫_0^T curve(startRateAtTarget*exp(speed*x), err) dx
                    // The integral is approximated with the trapezoidal rule:
                    // avg ~= 1/T * Σ_i=1^N [curve(f((i-1) * T/N), err) + curve(f(i * T/N), err)] / 2 * T/N
                    // Where f(x) = startRateAtTarget*exp(speed*x)
                    // avg ~= Σ_i=1^N [curve(f((i-1) * T/N), err) + curve(f(i * T/N), err)] / (2 * N)
                    // As curve is linear in its first argument:
                    // avg ~= curve([Σ_i=1^N [f((i-1) * T/N) + f(i * T/N)] / (2 * N), err)
                    // avg ~= curve([(f(0) + f(T))/2 + Σ_i=1^(N-1) f(i * T/N)] / N, err)
                    // avg ~= curve([(startRateAtTarget + endRateAtTarget)/2 + Σ_i=1^(N-1) f(i * T/N)] / N, err)
                    // With N = 2:
                    // avg ~= curve([(startRateAtTarget + endRateAtTarget)/2 + startRateAtTarget*exp(speed*T/2)] / 2, err)
                    // avg ~= curve([startRateAtTarget + endRateAtTarget + 2*startRateAtTarget*exp(speed*T/2)] / 4, err)
                    endRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation);
                    int256 midRateAtTarget = _newRateAtTarget(
                        startRateAtTarget,
                        linearAdaptation / 2
                    );
                    avgRateAtTarget =
                        (startRateAtTarget + endRateAtTarget + 2 * midRateAtTarget) /
                        4;
                }
            }
            // Safe "unchecked" cast because avgRateAtTarget >= 0.
            return (uint256(_curve(avgRateAtTarget, err)), endRateAtTarget);
        }
    }

    /// @dev Returns the rate for a given `_rateAtTarget` and an `err`.
    /// The formula of the curve is the following:
    /// r = ((1-1/C)*err + 1) * rateAtTarget if err < 0
    ///     ((C-1)*err + 1) * rateAtTarget else.
    function _curve(int256 _rateAtTarget, int256 err) private pure returns (int256) {
        // Non negative because 1 - 1/C >= 0, C - 1 >= 0.
        unchecked {
            int256 coeff = err < 0
                ? WAD - Math.wDivToZero(WAD, CURVE_STEEPNESS)
                : CURVE_STEEPNESS - WAD;
            // Non negative if _rateAtTarget >= 0 because if err < 0, coeff <= 1.
            return Math.wMulToZero(Math.wMulToZero(coeff, err) + WAD, _rateAtTarget);
        }
    }

    /// @dev Returns the new rate at target, for a given `startRateAtTarget` and a given `linearAdaptation`.
    /// The formula is: max(min(startRateAtTarget * exp(linearAdaptation), maxRateAtTarget), minRateAtTarget).
    function _newRateAtTarget(
        int256 startRateAtTarget,
        int256 linearAdaptation
    ) private pure returns (int256) {
        // Non negative because MIN_RATE_AT_TARGET > 0.
        return
            Math.bound(
                Math.wMulToZero(startRateAtTarget, Math.wExp(linearAdaptation)),
                MIN_RATE_AT_TARGET,
                MAX_RATE_AT_TARGET
            );
    }

    /*//////////////////////////////////////////////////////////////
                             QUERY HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the stored VEGOID parameter
    function vegoid() external view returns (uint8) {
        return uint8(VEGOID);
    }
}

/*//////////////////////////////////////////////////////////////
                       BUILDER WALLETS
//////////////////////////////////////////////////////////////*/

interface IERC20 {
    function balanceOf(address) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);
}

contract BuilderWallet {
    address public immutable FACTORY;
    address public builderAdmin;

    constructor(address factory) {
        FACTORY = factory;
    }

    function init(address _builderAdmin) external {
        builderAdmin = _builderAdmin;
    }

    function sweep(address token, address to) external {
        if (msg.sender != builderAdmin) revert Errors.NotBuilder();

        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) return;

        bool ok = IERC20(token).transfer(to, bal);
        if (!ok) {
            // `from` is this wallet, `balance` is pre-transfer token balance
            revert Errors.TransferFailed(token, address(this), bal, bal);
        }
    }
}

library Create2Lib {
    function deploy(
        uint256 value,
        bytes32 salt,
        bytes memory code
    ) internal returns (address addr) {
        assembly {
            addr := create2(value, add(code, 0x20), mload(code), salt)
        }
        require(addr != address(0), "CREATE2 failed");
    }
}

contract BuilderFactory {
    using Create2Lib for uint256;

    address public immutable OWNER;

    constructor(address owner) {
        if (owner == address(0)) revert Errors.ZeroAddress();
        OWNER = owner;
    }

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal {
        require(msg.sender == OWNER, "NOT_OWNER");
    }

    /**
     * @notice Deploys a BuilderWallet contract using CREATE2.
     * @param builderCode The uint256 used as the CREATE2 salt (must match caller's referral code).
     * @param builderAdmin The EOA/multisig allowed to sweep tokens from the wallet.
     * @return wallet The deployed wallet address (deterministic).
     */
    function deployBuilder(
        uint48 builderCode,
        address builderAdmin
    ) external onlyOwner returns (address wallet) {
        bytes32 salt = bytes32(uint256(builderCode));

        // Constructor args are part of the init code and therefore part of the CREATE2 address.
        bytes memory initCode = abi.encodePacked(
            type(BuilderWallet).creationCode,
            abi.encode(address(this))
        );

        wallet = Create2Lib.deploy(0, salt, initCode);
        // now set the admin in storage (not part of init code)
        BuilderWallet(wallet).init(builderAdmin);
    }

    /**
     * @notice Computes the CREATE2 address for (builderCode, builderAdmin).
     * @dev Must match the formula used in the RiskEngine.
     */
    function predictBuilderWallet(uint48 builderCode) external view returns (address) {
        bytes32 salt = bytes32(uint256(builderCode));

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(BuilderWallet).creationCode, abi.encode(address(this)))
        );

        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash));

        return address(uint160(uint256(h)));
    }
}
