// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @title Custom Errors library.
/// @author Axicon Labs Limited
/// @notice Contains all custom error messages used in Panoptic.
library Errors {
    /// @notice PanopticPool: The account is not solvent enough to perform the desired action
    error AccountInsolvent(uint256 solvent, uint256 numberOfTicks);

    /// @notice Casting error
    /// @dev e.g. uint128(uint256(a)) fails
    error CastingError();

    /// @notice CollateralTracker: Attempted to withdraw/redeem less than a single asset
    error BelowMinimumRedemption();

    /// @notice SFPM: Mints/burns of zero-liquidity chunks in Uniswap are not supported
    error ChunkHasZeroLiquidity();

    /// @notice CollateralTracker: Collateral token has already been initialized
    error CollateralTokenAlreadyInitialized();

    /// @notice CollateralTracker: The amount of shares (or assets) deposited is larger than the maximum permitted
    error DepositTooLarge();

    /// @notice PanopticPool: The list of provided TokenIds has a duplicate entry
    error DuplicateTokenId();

    /// @notice PanopticPool: The effective liquidity (X32) is greater than min(`MAX_SPREAD`, `USER_PROVIDED_THRESHOLD`) during a long mint or short burn
    /// @dev Effective liquidity measures how much new liquidity is minted relative to how much is already in the pool
    error EffectiveLiquidityAboveThreshold();

    /// @notice CollateralTracker: Attempted to withdraw/redeem more than available liquidity, owned shares, or open positions would allow for
    error ExceedsMaximumRedemption();

    /// @notice PanopticPool: The provided list of option positions is incorrect or invalid
    error InputListFail();

    /// @notice Tick is not between `MIN_TICK` and `MAX_TICK`
    error InvalidTick();

    /// @notice Liquidity in a chunk is above 2**128
    error LiquidityTooHigh();

    /// @notice CollateralTracker: There is not enough available liquidity to fulfill a credit in the PanopticPool
    error InsufficientCreditLiquidity();

    /// @notice RiskEngine: invalid builder code
    error InvalidBuilderCode();

    /// @notice The TokenId provided by the user is malformed or invalid
    /// @param parameterType poolId=0, ratio=1, tokenType=2, risk_partner=3, strike=4, width=5, two identical strike/width/tokenType chunks=6
    error InvalidTokenIdParameter(uint256 parameterType);

    /// @notice A mint or swap callback was attempted from an address that did not match the canonical Uniswap V3 pool with the claimed features
    error InvalidUniswapCallback();

    /// @notice RiskEngine: There is a mismatch between the length of the positionIdList and positionBalanceArray
    error LengthMismatch();

    /// @notice PanopticPool: The Net Liquidity is zero due to small positions and cannot be used to compute the liquiditySpread
    error NetLiquidityZero();

    /// @notice PanopticPool: None of the legs in a position are force-exercisable (they are all either short or ATM long)
    error NoLegsExercisable();

    /// @notice PanopticPool: The leg is not long, so premium cannot be settled through `settleLongPremium`
    error NotALongLeg();

    /// @notice builderWallet: can only be called by the Builder
    error NotBuilder();

    /// @notice PanopticPool: There is not enough available liquidity in the chunk for one of the long legs to be created (or for one of the short legs to be closed)
    error NotEnoughLiquidityInChunk();

    /// @notice CollateralTracker: The user does not own enough assets to open/close a position
    error NotEnoughTokens(address tokenAddress, uint256 assetsRequested, uint256 assetBalance);

    /// @notice RiskEngine: can only be called by the guardian
    error NotGuardian();

    /// @notice PanopticPool: Position is still solvent and cannot be liquidated
    error NotMarginCalled();

    /// @notice CollateralTracker: The caller for a permissioned function is not the Panoptic Pool
    error NotPanopticPool();

    /// @notice Uniswap pool has already been initialized in the SFPM or created in the factory
    error PoolAlreadyInitialized();

    /// @notice The Uniswap Pool has not been created, so it cannot be used in the SFPM or have a PanopticPool created for it by the factory
    error PoolNotInitialized();

    /// @notice CollateralTracker: The user has open/active option positions, so they cannot transfer collateral shares
    error PositionCountNotZero();

    /// @notice PanopticPool: A position with the given token ID is not owned by the user and has positionSize=0
    error PositionNotOwned();

    /// @notice SFPM: The maximum token deltas (excluding swaps) for a position exceed (2^127 - 5) at some valid price
    error PositionTooLarge();

    /// @notice The current tick in the pool (post-ITM-swap) has fallen outside a user-defined open interval slippage range
    error PriceBoundFail(int24 currentTick);

    /// @notice The Price impact of that trade is too large
    error PriceImpactTooLarge();

    /// @notice An oracle price is too far away from another oracle price or the current tick
    /// @dev This is a safeguard against price manipulation during option mints, burns, liquidations, force exercises, and premium settlements
    error StaleOracle();

    /// @notice PanopticPool: The position being minted would increase the total amount of legs open for the account above the maximum
    error TooManyLegsOpen();

    /// @notice ERC20 or SFPM (ERC1155) token transfer did not complete successfully
    error TransferFailed(address token, address from, uint256 amount, uint256 balance);

    /// @notice The tick range given by the strike price and width is invalid
    /// because the upper and lower ticks are not initializable multiples of `tickSpacing`
    /// or one of the ticks exceeds the `MIN_TICK` or `MAX_TICK` bounds
    error InvalidTickBound();

    /// @notice An unlock callback was attempted from an address other than the canonical Uniswap V4 pool manager
    error UnauthorizedUniswapCallback();

    /// @notice An operation in a library has failed due to an underflow or overflow
    error UnderOverFlow();

    /// @notice PanopticPool: The supplied poolId does not match the poolId for that Uniswap Pool
    error WrongPoolId();

    /// @notice SFPM: The poolId's don't match
    error WrongUniswapPool();

    /// @notice PanopticFactory: the zero address was supplied as a parameter
    error ZeroAddress();

    /// @notice CollateralTracker: Mints/burns of a position returns no collateral requirement
    error ZeroCollateralRequirement();

    /// @notice PanopticMath: The supplied tokenId has no valid legs
    error TokenIdHasZeroLegs();
}
