/* function _withdraw_with_open_positions_and_check(
    CollateralTracker collToken,
    uint256 shares,
    address withdrawer
) internal {

    // TODO: check whether current positions are solvent; assertFalse if not
    uint256 BP_DECREASE_BUFFER = 13_333;
    TokenId[] withdrawers_open_positions = userPositions[withdrawer];
    assertWithMsg(_is_solvent(withdrawer, withdrawers_open_positions, BP_DECREASE_BUFFER), "User is not solvent even prior to withdrawing-with-open-positions");

    // then, attempt withdrawal, and assert assets & shares were deducted/incremented appropriately:
    uint256 withdrawer_assets_bal = IERC20(collToken.asset()).balanceOf(withdrawer);
    uint256 pool_assets_bal = IERC20(collToken.asset()).balanceOf(address(panopticPool));
    uint256 withdrawer_shares = collToken.balanceOf(withdrawer);

    // TODO: do we need to scale this down such that we're in-bounds for the actual collateral requirements of open positions?
    uint256 shares_to_withdraw = bound(shares, 1, collToken.balanceOf(withdrawer));
    uint256 assets_to_withdraw = collToken.convertToAssets(shares_to_withdraw);

    hevm.prank(withdrawer);

    try collToken.withdraw(assets_to_withdraw, withdrawer, withdrawer) {
        // assert assets & shares were deducted/incremented appropriately:
        uint256 pool_assets_bal_after = IERC20(collToken.asset()).balanceOf(address(panopticPool));
        uint256 withdrawer_bal_after = IERC20(collToken.asset()).balanceOf(withdrawer);
        uint256 withdrawer_shares_after = collToken.balanceOf(withdrawer);
        assertWithMsg(pool_assets_bal - pool_assets_bal_after == assets_to_withdraw, "Pool asset balance incorrect after redemption");
        assertWithMsg(withdrawer_bal_after - withdrawer_assets_bal == assets_to_withdraw, "User balance incorrect after deposit");
        assertWithMsg(withdrawer_shares_after - withdrawer_shares == shares_to_withdraw, "User share balance incorrect after redemption");

        // then, show we are still solvent:
        assertWithMsg(_is_solvent(withdrawer, withdrawers_open_positions, BP_DECREASE_BUFFER), "User is not solvent after seemingly legal withdrawal-with-open-positions");

    } catch { }
}


function _is_solvent(address user, TokenId[] calldata positionIdList, uint256 buffer) internal view returns (bool) {
    uint256 FAST_ORACLE_CARDINALITY = 3;
    uint256 FAST_ORACLE_PERIOD = 1;

    (
        ,
        int24 currentTick,
        uint16 observationIndex,
        uint16 observationCardinality,
        ,
        ,

    ) = pool.slot0();
    int24 fastOracleTick = PanopticMath.computeMedianObservedPrice(
        pool,
        observationIndex,
        observationCardinality,
        FAST_ORACLE_CARDINALITY,
        FAST_ORACLE_PERIOD
    );

    bool SLOW_ORACLE_UNISWAP_MODE = false;
    uint256 SLOW_ORACLE_CARDINALITY = 7;
    uint256 SLOW_ORACLE_PERIOD = 5;
    uint256 MEDIAN_PERIOD = 60;
    uint256 s_miniMedian;
    (, uint256 medianData) = PanopticMath.computeInternalMedian(
        observationIndex,
        observationCardinality,
        MEDIAN_PERIOD,
        s_miniMedian,
        pool
    );

    if (medianData != 0) s_miniMedian = medianData;

    int24 slowOracleTick;
    if (SLOW_ORACLE_UNISWAP_MODE) {
        slowOracleTick = PanopticMath.computeMedianObservedPrice(
            pool,
            observationIndex,
            observationCardinality,
            SLOW_ORACLE_CARDINALITY,
            SLOW_ORACLE_PERIOD
        );
    } else {
        (slowOracleTick, medianData) = PanopticMath.computeInternalMedian(
            observationIndex,
            observationCardinality,
            MEDIAN_PERIOD,
            s_miniMedian,
            pool
        );
    }

    // Check the user's solvency at the fast tick; revert if not solvent
    bool solventAtFast = _checkSolvencyAtTick(
        user,
        positionIdList,
        currentTick,
        fastOracleTick,
        buffer
    );
    if (!solventAtFast) return false;

    int256 MAX_SLOW_FAST_DELTA = 1800;
    // If one of the ticks is too stale, we fall back to the more conservative tick, i.e, the user must be solvent at both the fast and slow oracle ticks.
    if (Math.abs(int256(fastOracleTick) - slowOracleTick) > MAX_SLOW_FAST_DELTA)
        if (!_checkSolvencyAtTick(user, positionIdList, currentTick, slowOracleTick, buffer))
            return false;
}

/// @notice check whether an account is solvent at a given `atTick` with a collateral requirement of `buffer`/10_000 multiplied by the requirement of `positionIdList`.
/// @param account The account to check solvency for.
/// @param positionIdList The list of positions to check solvency for.
/// @param currentTick The current tick of the Uniswap pool (needed for fee calculations).
/// @param atTick The tick to check solvency at.
/// @param buffer The buffer to apply to the collateral requirement.
function _checkSolvencyAtTick(
    address account,
    TokenId[] calldata positionIdList,
    int24 currentTick,
    int24 atTick,
    uint256 buffer
) internal view returns (bool) {
    bool COMPUTE_ALL_PREMIA = true;
    bool ONLY_AVAILABLE_PREMIUM = false;

    (
        LeftRightSigned portfolioPremium,
        uint256[2][] memory positionBalanceArray
    ) = _calculateAccumulatedPremia(
            account,
            positionIdList,
            COMPUTE_ALL_PREMIA,
            ONLY_AVAILABLE_PREMIUM,
            currentTick
        );

    LeftRightUnsigned tokenData0 = collToken0.getAccountMarginDetails(
        account,
        atTick,
        positionBalanceArray,
        portfolioPremium.rightSlot()
    );
    LeftRightUnsigned tokenData1 = collToken1.getAccountMarginDetails(
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

    // compare balance and required tokens, can use unsafe div because denominator is always nonzero
    unchecked {
        return balanceCross >= Math.unsafeDivRoundingUp(thresholdCross * buffer, 10_000);
    }
}

function _calculateAccumulatedPremia(
    address user,
    TokenId[] calldata positionIdList,
    bool computeAllPremia,
    bool includePendingPremium,
    int24 atTick
) internal view returns (LeftRightSigned portfolioPremium, uint256[2][] memory balances) {
    uint256 pLength = positionIdList.length;
    balances = new uint256[2][](pLength);

    address c_user = user;
    // loop through each option position/tokenId
    for (uint256 k = 0; k < pLength; ) {
        TokenId tokenId = positionIdList[k];

        (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = pool.optionPositionBalance(c_user, tokenId);

        balances[k][0] = TokenId.unwrap(tokenId);
        balances[k][1] = balance;

        (
            LeftRightSigned[4] memory premiaByLeg,
            uint256[2][4] memory premiumAccumulatorsByLeg
        ) = _getPremia(
                tokenId,
                balance,
                c_user,
                computeAllPremia,
                atTick
            );

        uint256 numLegs = tokenId.countLegs();
        for (uint256 leg = 0; leg < numLegs; ) {
            if (tokenId.isLong(leg) == 0 && !includePendingPremium) {
                bytes32 chunkKey = keccak256(
                    abi.encodePacked(
                        tokenId.strike(leg),
                        tokenId.width(leg),
                        tokenId.tokenType(leg)
                    )
                );

                LeftRightUnsigned availablePremium = _getAvailablePremium(
                    _getTotalLiquidity(tokenId, leg),
                    s_settledTokens[chunkKey],
                    s_grossPremiumLast[chunkKey],
                    LeftRightUnsigned.wrap(uint256(LeftRightSigned.unwrap(premiaByLeg[leg]))),
                    premiumAccumulatorsByLeg[leg]
                );
                portfolioPremium = portfolioPremium.add(
                    LeftRightSigned.wrap(int256(LeftRightUnsigned.unwrap(availablePremium)))
                );
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
    return (portfolioPremium, balances);
}

function _getSolvencyBalances(
    LeftRightUnsigned tokenData0,
    LeftRightUnsigned tokenData1,
    uint160 sqrtPriceX96
) internal pure returns (uint256 balanceCross, uint256 thresholdCross) {
    unchecked {
        // the cross-collateral balance, computed in terms of liquidity X*√P + Y/√P
        // We use mulDiv to compute Y/√P + X*√P while correctly handling overflows, round down
        balanceCross =
            Math.mulDiv(uint256(tokenData1.rightSlot()), 2 ** 96, sqrtPriceX96) +
            Math.mulDiv96(tokenData0.rightSlot(), sqrtPriceX96);
        // the amount of cross-collateral balance needed for the account to be solvent, computed in terms of liquidity
        // overstimate by rounding up
        thresholdCross =
            Math.mulDivRoundingUp(uint256(tokenData1.leftSlot()), 2 ** 96, sqrtPriceX96) +
            Math.mulDiv96RoundingUp(tokenData0.leftSlot(), sqrtPriceX96);
    }
}

function _getPremia(
    TokenId tokenId,
    uint128 positionSize,
    address owner,
    bool computeAllPremia,
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
        if ((isLong == 1) || computeAllPremia) {
            LiquidityChunk liquidityChunk = PanopticMath.getLiquidityChunk(
                tokenId,
                leg,
                positionSize
            );
            uint256 tokenType = tokenId.tokenType(leg);

            (premiumAccumulatorsByLeg[leg][0], premiumAccumulatorsByLeg[leg][1]) = sfpm
                .getAccountPremium(
                    address(pool),
                    address(this),
                    tokenType,
                    liquidityChunk.tickLower(),
                    liquidityChunk.tickUpper(),
                    atTick,
                    isLong
                );

            unchecked {
                LeftRightUnsigned premiumAccumulatorLast = s_options[owner][tokenId][leg];

                // if the premium accumulatorLast is higher than current, it means the premium accumulator has overflowed and rolled over at least once
                // we can account for one rollover by doing (acc_cur + (acc_max - acc_last))
                // if there are multiple rollovers or the rollover goes past the last accumulator, rolled over fees will just remain unclaimed
                premiaByLeg[leg] = LeftRightSigned
                    .wrap(0)
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
                    premiaByLeg[leg] = LeftRightSigned.wrap(0).sub(premiaByLeg[leg]);
                }
            }
        }
        unchecked {
            ++leg;
        }
    }
}

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
                .wrap(0)
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
function _getTotalLiquidity(
    TokenId tokenId,
    uint256 leg
) internal view returns (uint256 totalLiquidity) {
    unchecked {
        // totalLiquidity (total sold) = removedLiquidity + netLiquidity

        (int24 tickLower, int24 tickUpper) = tokenId.asTicks(leg);
        uint256 tokenType = tokenId.tokenType(leg);
        LeftRightUnsigned accountLiquidities = sfpm.getAccountLiquidity(
            address(pool),
            address(this),
            tokenType,
            tickLower,
            tickUpper
        );

        // removed + net
        totalLiquidity = accountLiquidities.rightSlot() + accountLiquidities.leftSlot();
    }
} */
