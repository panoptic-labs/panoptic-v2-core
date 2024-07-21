// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "./FuzzHelpers.sol";
import {GeneralActions} from "./GeneralActions.sol";

contract SFPMActions is GeneralActions {
    /// SFPM direct interactions

    ////////////////////////////////////////////////////
    // Mint
    ////////////////////////////////////////////////////

    // mint option sfpm standard mint of full shorts (store this position in mapping)
    // ** add moved amts check
    function mint_option_SFPM_multiShort(
        uint256 numLegs,
        bool[4] memory asset_in,
        bool[4] memory is_call_in,
        bool[4] memory is_otm_in,
        bool[4] memory is_atm_in,
        uint24[4] memory width_in,
        int256[4] memory strike_in,
        uint128 positionSize,
        bool swapAtMint
    ) public {
        // store the current actor
        $activeUser = msg.sender;

        // generate a random number of legs
        $activeNumLegs = numLegs = bound(numLegs, 1, 4);

        $activeTokenId = _generate_multiple_leg_tokenid(
            numLegs,
            asset_in,
            is_call_in,
            false, // generate short
            is_otm_in,
            is_atm_in,
            width_in,
            strike_in
        );

        // pre-mint calculations/actions for storage
        for (uint i; i < $activeNumLegs - 1; i++) {
            $activeLegIndex = $activeNumLegs - 1;

            {
                // get the amount of liquidity being deposited
                $liquidityChunk[i] = PanopticMath.getLiquidityChunk(
                    $activeTokenId,
                    i,
                    positionSize
                );

                $sTickLower[i] = $liquidityChunk[i].tickLower();
                $sTickUpper[i] = $liquidityChunk[i].tickUpper();
                $sLiqAmounts[i] = $liquidityChunk[i].liquidity();

                // store the active position details
                {
                    $tickLowerActive = $sTickLower[i];
                    $tickUpperActive = $sTickUpper[i];
                    $LiqAmountActive = $sLiqAmounts[i];
                }

                // emit positional bounds and liquidity
                emit LogInt256("tick lower", $tickLowerActive);
                emit LogInt256("tick upper", $tickUpperActive);
                emit LogUint256("liquidity amounts", $LiqAmountActive);
            }

            {
                // uniswap liquidity before mint for the chunk
                ($posLiquidity[i], , , , ) = pool.positions(
                    keccak256(abi.encodePacked(address(sfpm), $tickLowerActive, $tickUpperActive))
                );

                // poke uniswap pool to update tokens owed - needed because swap happens after mint
                // only poke if there is pre-existing liquidity at this chunk
                if ($posLiquidity[i] != 0) {
                    hevm.prank(address(sfpm));
                    pool.burn($tickLowerActive, $tickUpperActive, 0);
                }
            }

            {
                // get the amount of liquidity within that range present in uniswap already
                $positionKey[i] = keccak256(
                    abi.encodePacked(address(sfpm), $tickLowerActive, $tickUpperActive)
                );
                (uniLiquidityBefore[i], , , , ) = pool.positions($positionKey[i]);

                // get SFPM stored account liquidity before
                LeftRightUnsigned accountLiquiditiesBefore = sfpm.getAccountLiquidity(
                    address(pool),
                    $activeUser,
                    $activeTokenId.tokenType(i),
                    $tickLowerActive,
                    $tickUpperActive
                );

                // store the removed and net liquidity for the chunk
                //  before mint
                $removedLiquidityBefore[i] = accountLiquiditiesBefore.leftSlot();
                $netLiquidityBefore[i] = accountLiquiditiesBefore.rightSlot();
            }

            {
                // s_accountFeesBase before
                // check s_accountFeesBase is updated correctly
                ($oldFeesBase0[i], $oldFeesBase1[i]) = sfpm.getAccountFeesBase(
                    address(pool),
                    $activeUser,
                    $activeTokenId.tokenType(i),
                    $tickLowerActive,
                    $tickUpperActive
                );

                emit LogInt256("pre-mint feesbase 0", $oldFeesBase0[i]);
                emit LogInt256("pre-mint feesbase 1", $oldFeesBase1[i]);
            }

            {
                (
                    ,
                    $feeGrowthInside0LastX128Before[i],
                    $feeGrowthInside1LastX128Before[i],
                    ,

                ) = pool.positions(
                    keccak256(abi.encodePacked(address(sfpm), $tickLowerActive, $tickUpperActive))
                );

                // after touch
                emit LogUint256(
                    "pre-mint feeGrowthInside0LastX128",
                    $feeGrowthInside0LastX128Before[i]
                );
                emit LogUint256(
                    "pre-mint feeGrowthInside1LastX128",
                    $feeGrowthInside1LastX128Before[i]
                );
            }

            {
                $newFeesBaseRoundDown0[i] = int128(
                    int256(
                        Math.mulDiv128($feeGrowthInside0LastX128Before[i], $netLiquidityBefore[i])
                    )
                );
                $newFeesBaseRoundDown1[i] = int128(
                    int256(
                        Math.mulDiv128($feeGrowthInside1LastX128Before[i], $netLiquidityBefore[i])
                    )
                );

                emit LogInt256("newFeesBaseRoundDown0", $newFeesBaseRoundDown0[i]);
                emit LogInt256("newFeesBaseRoundDown1", $newFeesBaseRoundDown1[i]);

                //
                $amountToCollect0[$activeLegIndex] = int128(
                    Math.max($newFeesBaseRoundDown0[i] - $oldFeesBase0[i], 0)
                );
                $amountToCollect1[$activeLegIndex] = int128(
                    Math.max($newFeesBaseRoundDown0[i] - $oldFeesBase1[i], 0)
                );

                emit LogInt256("$amountToCollect0", $amountToCollect0[$activeLegIndex]);
                emit LogInt256("$amountToCollect1", $amountToCollect1[$activeLegIndex]);

                // get the minted amounts (true moved amounts)
                // also get the true collected amounts
                // @note if the shouldRevert flag is tipped then end execution here
                quote_uni_CollectAndMint();
            }

            // get premium gross/owed before (compute with max tick to get value stored in sfpm currently)
            // after check if stored value matches this value
            {
                ($accountPremiumGrossBefore0[i], $accountPremiumGrossBefore1[i]) = sfpm
                    .getAccountPremium(
                        address(pool),
                        $activeUser,
                        $activeTokenId.tokenType(i),
                        $tickLowerActive,
                        $tickUpperActive,
                        type(int24).max,
                        0 // short to check gross
                    );

                // get gross premium
                emit LogUint256("$accountPremiumGrossBefore0", $accountPremiumGrossBefore0[i]);
                emit LogUint256("$accountPremiumGrossBefore1", $accountPremiumGrossBefore1[i]);

                // owed premium
                ($accountPremiumOwedBefore0[i], $accountPremiumOwedBefore1[i]) = sfpm
                    .getAccountPremium(
                        address(pool),
                        $activeUser,
                        $activeTokenId.tokenType(i),
                        $tickLowerActive,
                        $tickUpperActive,
                        type(int24).max,
                        1 // long to check owed
                    );

                // get owed premium
                emit LogUint256("$accountPremiumOwedBefore0", $accountPremiumOwedBefore0[i]);
                emit LogUint256("$accountPremiumOwedBefore1", $accountPremiumOwedBefore1[i]);
            }
        }

        // reverse tick order if swap at mint
        int24 tickLimitLow = swapAtMint ? int24(887272) : int24(-887272);
        int24 tickLimitHigh = swapAtMint ? int24(-887272) : int24(887272);

        hevm.prank($activeUser);
        try
            sfpm.mintTokenizedPosition($activeTokenId, positionSize, tickLimitLow, tickLimitHigh)
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalSwapped) {
            // copy return into storage
            $sCollectedByLeg = collectedByLeg;
            $sTotalSwapped[$activeLegIndex] = totalSwapped;

            // preform post-mint invariant checks per leg
            for (uint i; i < $activeNumLegs - 1; i++) {
                $activeLegIndex = $activeNumLegs - 1;

                {
                    $tickLowerActive = $sTickLower[$activeLegIndex];
                    $tickUpperActive = $sTickUpper[$activeLegIndex];
                    $LiqAmountActive = $sLiqAmounts[$activeLegIndex];
                }

                // check the net liquidity added
                {
                    LeftRightUnsigned accountLiquiditiesAfter = sfpm.getAccountLiquidity(
                        address(pool),
                        $activeUser,
                        $activeTokenId.tokenType($activeLegIndex),
                        $tickLowerActive,
                        $tickUpperActive
                    );

                    $removedLiquidityAfter[$activeLegIndex] = accountLiquiditiesAfter.leftSlot();
                    $netLiquidityAfter[$activeLegIndex] = accountLiquiditiesAfter.rightSlot();

                    emit LogUint256(
                        "removedLiquidityBefore",
                        $removedLiquidityBefore[$activeLegIndex]
                    );
                    emit LogUint256("netLiquidityBefore", $netLiquidityBefore[$activeLegIndex]);

                    emit LogUint256(
                        "removedLiquidityAfter",
                        $removedLiquidityAfter[$activeLegIndex]
                    );
                    emit LogUint256("netLiquidityAfter", $netLiquidityAfter[$activeLegIndex]);

                    // check the liquidity tracked is the same as the liquidity computed
                    assertWithMsg(
                        $netLiquidityAfter[$activeLegIndex] ==
                            $sLiqAmounts[$activeLegIndex] + $netLiquidityBefore[$activeLegIndex],
                        "invalid net liquidity"
                    );

                    // ensure the removed liquidity remains the same
                    assertWithMsg(
                        $removedLiquidityBefore[$activeLegIndex] ==
                            $removedLiquidityAfter[$activeLegIndex],
                        "invalid removed liquidity"
                    );
                }

                // check the liquidity deposited within uniswap
                {
                    (uniLiquidityAfter[$activeLegIndex], , , , ) = pool.positions(
                        $positionKey[$activeLegIndex]
                    );

                    emit LogUint256("liquidityBefore", uniLiquidityBefore[$activeLegIndex]);
                    emit LogUint256("$LiqAmountActive", $sLiqAmounts[$activeLegIndex]);
                    emit LogUint256("liquidityDeployed", uniLiquidityAfter[$activeLegIndex]);

                    assertWithMsg(
                        uniLiquidityBefore[$activeLegIndex] + $sLiqAmounts[$activeLegIndex] ==
                            uniLiquidityAfter[$activeLegIndex],
                        "invalid uniswap liq"
                    );
                }

                // check stored fees base for this position
                {
                    (
                        ,
                        $feeGrowthInside0LastX128After[$activeLegIndex],
                        $feeGrowthInside1LastX128After[$activeLegIndex],
                        ,

                    ) = pool.positions(
                        keccak256(
                            abi.encodePacked(address(sfpm), $tickLowerActive, $tickUpperActive)
                        )
                    );

                    emit LogUint256(
                        "feeGrowthInside0LastX128After",
                        $feeGrowthInside0LastX128After[$activeLegIndex]
                    );
                    emit LogUint256(
                        "feeGrowthInside1LastX128After",
                        $feeGrowthInside1LastX128After[$activeLegIndex]
                    );

                    // new fees base
                    $newFeesBaseRoundUp0[$activeLegIndex] = int128(
                        int256(
                            Math.mulDiv128RoundingUp(
                                $feeGrowthInside0LastX128After[$activeLegIndex],
                                $netLiquidityAfter[$activeLegIndex]
                            )
                        )
                    );
                    $newFeesBaseRoundUp1[$activeLegIndex] = int128(
                        int256(
                            Math.mulDiv128RoundingUp(
                                $feeGrowthInside1LastX128After[$activeLegIndex],
                                $netLiquidityAfter[$activeLegIndex]
                            )
                        )
                    );

                    // check newly stored feesBase

                    ($newFeesBase0[$activeLegIndex], $newFeesBase0[$activeLegIndex]) = sfpm
                        .getAccountFeesBase(
                            address(pool),
                            msg.sender,
                            $activeTokenId.tokenType(0),
                            $tickLowerActive,
                            $tickUpperActive
                        );

                    emit LogInt256("oldFeesBase0", $oldFeesBase0[$activeLegIndex]);
                    emit LogInt256("oldFeesBase1", $oldFeesBase1[$activeLegIndex]);

                    emit LogInt256("newFeesBase0", $newFeesBase0[$activeLegIndex]);
                    emit LogInt256("newFeesBase1", $newFeesBase1[$activeLegIndex]);

                    emit LogInt256("$newFeesBaseRoundUp0", $newFeesBaseRoundUp0[$activeLegIndex]);
                    emit LogInt256("$newFeesBaseRoundUp0", $newFeesBase1[$activeLegIndex]);

                    assertWithMsg(
                        $newFeesBaseRoundUp0[$activeLegIndex] == $newFeesBase0[$activeLegIndex],
                        "invalid fees base 0"
                    );
                    assertWithMsg(
                        $newFeesBaseRoundUp1[$activeLegIndex] == $newFeesBase1[$activeLegIndex],
                        "invalid fees base 1"
                    );
                }

                /// compute and verify the amounts to collect
                {
                    // ensure amountToCollect is always positive
                    assertWithMsg(
                        $amountToCollect0[$activeLegIndex] >= 0,
                        "amountToCollect0 invalid"
                    );
                    assertWithMsg(
                        $amountToCollect1[$activeLegIndex] >= 0,
                        "amountToCollect1 invalid"
                    );

                    $collected0[$activeLegIndex] = $recievedAmount0[$activeLegIndex];
                    $collected1[$activeLegIndex] = $recievedAmount1[$activeLegIndex];

                    emit LogInt256("amountToCollect0", $amountToCollect0[$activeLegIndex]);
                    emit LogInt256("amountToCollect1", $amountToCollect1[$activeLegIndex]);

                    emit LogUint256("receivedAmount0", $recievedAmount0[$activeLegIndex]);
                    emit LogUint256("receivedAmount1", $recievedAmount1[$activeLegIndex]);

                    emit LogUint256("amountMinted0", $amountMinted0[$activeLegIndex]);
                    emit LogUint256("amountMinted1", $amountMinted1[$activeLegIndex]);

                    emit LogUint256("collected0", $collected0[$activeLegIndex]);
                    emit LogUint256("collected1", $collected1[$activeLegIndex]);

                    emit LogUint256(
                        "collectedByLeg token 0",
                        $collectedByLeg[$activeLegIndex].rightSlot()
                    );
                    emit LogUint256(
                        "collectedByLeg token 1",
                        $collectedByLeg[$activeLegIndex].leftSlot()
                    );

                    assertWithMsg(
                        $collected0[$activeLegIndex] ==
                            $collectedByLeg[$activeLegIndex].rightSlot(),
                        "invalid collected 0"
                    );
                    assertWithMsg(
                        $collected1[$activeLegIndex] == $collectedByLeg[$activeLegIndex].leftSlot(),
                        "invalid collected 1"
                    );

                    {
                        // get premium gross
                        (
                            $accountPremiumGrossAfter0[$activeLegIndex],
                            $accountPremiumGrossAfter1[$activeLegIndex]
                        ) = sfpm.getAccountPremium(
                            address(pool),
                            $activeUser,
                            $activeTokenId.tokenType($activeLegIndex),
                            $tickLowerActive,
                            $tickUpperActive,
                            type(int24).max,
                            0 // to query gross
                        );

                        // get premium owed
                        (
                            $accountPremiumOwedAfter0[$activeLegIndex],
                            $accountPremiumOwedAfter1[$activeLegIndex]
                        ) = sfpm.getAccountPremium(
                            address(pool),
                            $activeUser,
                            $activeTokenId.tokenType($activeLegIndex),
                            $tickLowerActive,
                            $tickUpperActive,
                            type(int24).max,
                            1 // to query owed
                        );

                        // gross
                        emit LogUint256(
                            "$accountPremiumGrossAfter0",
                            $accountPremiumGrossAfter0[$activeLegIndex]
                        );
                        emit LogUint256(
                            "$accountPremiumGrossAfter1",
                            $accountPremiumGrossAfter1[$activeLegIndex]
                        );
                        // owed
                        emit LogUint256(
                            "$accountPremiumOwedAfter0",
                            $accountPremiumOwedAfter0[$activeLegIndex]
                        );
                        emit LogUint256(
                            "$accountPremiumOwedAfter1",
                            $accountPremiumOwedAfter1[$activeLegIndex]
                        );

                        if (
                            $amountToCollect0[$activeLegIndex] != 0 ||
                            $amountToCollect1[$activeLegIndex] != 0
                        ) {
                            LeftRightUnsigned deltaPremiumOwed;
                            LeftRightUnsigned deltaPremiumGross;

                            /// assert premia values before and after
                            // add previous s_accountPremiumOwed by new amounts (if previously uint128 max ensure it doesn't overflow)
                            try
                                this.getPremiaDeltasChecked(
                                    $netLiquidityBefore[$activeLegIndex],
                                    $removedLiquidityBefore[$activeLegIndex],
                                    $collected0[$activeLegIndex],
                                    $collected1[$activeLegIndex]
                                )
                            returns (
                                LeftRightUnsigned deltaPremiumOwedR,
                                LeftRightUnsigned deltaPremiumGrossR
                            ) {
                                // pass
                                deltaPremiumOwed = deltaPremiumOwedR;
                                deltaPremiumGross = deltaPremiumGrossR;
                            } catch {
                                assertWithMsg(false, "fail  in premia calc");
                            }

                            emit LogUint256("deltaPremiumOwed 0", deltaPremiumOwed.rightSlot());
                            emit LogUint256("deltaPremiumOwed 1", deltaPremiumOwed.leftSlot());
                            //
                            emit LogUint256("deltaPremiumGross 0", deltaPremiumGross.rightSlot());
                            emit LogUint256("deltaPremiumGross 1", deltaPremiumGross.leftSlot());

                            // ensure getAccountPremium up to the current touch(max tick) vals match
                            // against the externally computed premia values
                            (
                                $accountPremiumGrossCalculated0[$activeLegIndex],
                                $accountPremiumGrossCalculated1[$activeLegIndex],
                                $accountPremiumOwedCalculated0[$activeLegIndex],
                                $accountPremiumOwedCalculated1[$activeLegIndex]
                            ) = incrementPremiaAccumulator(
                                $accountPremiumGrossBefore0[$activeLegIndex],
                                $accountPremiumGrossBefore1[$activeLegIndex],
                                //
                                deltaPremiumGross.rightSlot(),
                                deltaPremiumGross.leftSlot(),
                                //
                                $accountPremiumOwedBefore0[$activeLegIndex],
                                $accountPremiumOwedBefore1[$activeLegIndex],
                                //
                                deltaPremiumOwed.rightSlot(),
                                deltaPremiumOwed.leftSlot()
                            );

                            emit LogUint256(
                                "$accountPremiumGrossCalculated0",
                                $accountPremiumGrossCalculated0[$activeLegIndex]
                            );
                            emit LogUint256(
                                "$accountPremiumGrossCalculated1",
                                $accountPremiumGrossCalculated1[$activeLegIndex]
                            );
                            //
                            emit LogUint256(
                                "$accountPremiumOwedCalculated0",
                                $accountPremiumOwedCalculated0[$activeLegIndex]
                            );
                            emit LogUint256(
                                "$accountPremiumOwedCalculated1",
                                $accountPremiumOwedCalculated1[$activeLegIndex]
                            );

                            // check calculated gross matches up with stored
                            assertWithMsg(
                                $accountPremiumGrossCalculated0[$activeLegIndex] ==
                                    $accountPremiumGrossAfter0[$activeLegIndex],
                                "invalid gross 0"
                            );
                            assertWithMsg(
                                $accountPremiumGrossCalculated1[$activeLegIndex] ==
                                    $accountPremiumGrossAfter1[$activeLegIndex],
                                "invalid gross 1"
                            );

                            // check owed matches up with stored
                            assertWithMsg(
                                $accountPremiumOwedCalculated0[$activeLegIndex] ==
                                    $accountPremiumOwedAfter0[$activeLegIndex],
                                "invalid owed 0"
                            );
                            assertWithMsg(
                                $accountPremiumOwedCalculated1[$activeLegIndex] ==
                                    $accountPremiumOwedAfter1[$activeLegIndex],
                                "invalid owed 1"
                            );
                        } else {
                            // gross checks
                            assertWithMsg(
                                $accountPremiumGrossBefore0[$activeLegIndex] ==
                                    $accountPremiumGrossAfter0[$activeLegIndex],
                                "invalid gross 0 -> no collect"
                            );
                            assertWithMsg(
                                $accountPremiumGrossBefore1[$activeLegIndex] ==
                                    $accountPremiumGrossAfter1[$activeLegIndex],
                                "invalid gross 1 -> no collect"
                            );

                            // owed checks
                            assertWithMsg(
                                $accountPremiumOwedBefore0[$activeLegIndex] ==
                                    $accountPremiumOwedAfter0[$activeLegIndex],
                                "invalid owed 0 -> no collect"
                            );
                            assertWithMsg(
                                $accountPremiumOwedBefore1[$activeLegIndex] ==
                                    $accountPremiumOwedAfter1[$activeLegIndex],
                                "invalid owed 1 -> no collect"
                            );
                        }
                    }
                }
            }

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMShort[msg.sender].push($activeTokenId);

            // reset the activeTokenId for next iteration
            $activeTokenId = TokenId.wrap(uint256(0));
        } catch {
            // @note if it fails ensure the amount of liquidity being minted was valid
            // that the user has enough tokens to cover the mint and the mint is non-zero liq
            // also ensure shouldRevert flag is not tipped to be true
        }
    }

    // buy attempt (mint a long position)
    // finds a matching short position which was minted by the user
    // either multiple within the same tokenId or randomly in other tokenId
    // ** add moved amts check
    // function mint_option_SFPM_multiLong(uint256 randIndex, uint128 positionSize) public {
    //     // store the current actor
    //     $activeUser = msg.sender;

    //     {
    //         // search for a tokenId that the current actor has sold
    //         uint256 totalPosLen = userPositionsSFPMShort[msg.sender].length;

    //         if (totalPosLen == 0) {
    //             // if no short positions exist for the user then pass
    //             revert();
    //         }

    //         // choose an index at random to burn
    //         uint256 chosenIndex = bound(randIndex, 0, totalPosLen - 1);
    //         // @note modify to use tokenIdActive
    //         tokenIdLong = userPositionsSFPMShort[msg.sender][chosenIndex];

    //         // flip from short to long to mint as a long pos
    //         tokenIdLong = tokenIdLong.flipToBurnToken();

    //         // flip the isLong bits to make it a long position
    //         emit LogUint256("totalPosLen", totalPosLen);
    //         emit LogUint256("tokenIdLong", tokenIdLong.isLong(0));
    //     }

    //     /// @note set up array storage for liqChunks of 4 legs
    //     /// store tickLower/Upper by leg
    //     /// store liquidity amounts by leg
    //     {
    //         // get the amount of liquidity being deposited
    //         liquidityChunk = PanopticMath.getLiquidityChunk(tokenIdLong, 0, positionSize);

    //         // simulate the mint and get the actual moved amounts
    //         $tickLowerActive = liquidityChunk.tickLower();
    //         $tickUpperActive = liquidityChunk.tickUpper();
    //         $LiqAmountActive = liquidityChunk.liquidity();
    //     }

    //     // @note store true posLiquidity per leg
    //     ($posLiquidity, , , , ) = pool.positions(
    //         keccak256(
    //             abi.encodePacked(
    //                 address(sfpm),
    //                 liquidityChunk.tickLower(),
    //                 liquidityChunk.tickUpper()
    //             )
    //         )
    //     );

    //     // poke uniswap pool to update tokens owed - needed because swap happens after mint
    //     // only poke if there is pre-existing liquidity at this chunk
    //     if ($posLiquidity != 0) {
    //         hevm.prank(address(sfpm));
    //         pool.burn($tickLowerActive, $tickUpperActive, 0);
    //     }

    //     // @note store liquidity before, removed liquidity before, and net liquidity before
    //     // of all legs
    //     {
    //         // get the amount of liquidity within that range present in uniswap already
    //         bytes32 positionKey = keccak256(
    //             abi.encodePacked(
    //                 address(sfpm),
    //                 liquidityChunk.tickLower(),
    //                 liquidityChunk.tickUpper()
    //             )
    //         );

    //         (uint128 liquidityBefore, , , , ) = pool.positions(positionKey);

    //         LeftRightUnsigned accountLiquiditiesBefore = sfpm.getAccountLiquidity(
    //             address(pool),
    //             msg.sender,
    //             tokenIdLong.tokenType(0),
    //             liquidityChunk.tickLower(),
    //             liquidityChunk.tickUpper()
    //         );

    //         removedLiquidityBefore = accountLiquiditiesBefore.leftSlot();
    //         netLiquidityBefore = accountLiquiditiesBefore.rightSlot();
    //     }

    //     emit LogInt256("liquidityChunk.tickLower()", liquidityChunk.tickLower());
    //     emit LogInt256("liquidityChunk.tickUpper()", liquidityChunk.tickUpper());

    //     // @note get old feesBase per chunk/leg
    //     // s_accountFeesBase before
    //     // check s_accountFeesBase is updated correctly
    //     (oldFeesBase0, oldFeesBase1) = sfpm.getAccountFeesBase(
    //         address(pool),
    //         msg.sender,
    //         tokenIdLong.tokenType(0),
    //         liquidityChunk.tickLower(),
    //         liquidityChunk.tickUpper()
    //     );

    //     // @note function to update latest feeGrowthValues for current chunk
    //     // store in size of 4 array
    //     (, $feeGrowthInside0LastX128Before, $feeGrowthInside1LastX128Before, , ) = pool.positions(
    //         keccak256(
    //             abi.encodePacked(
    //                 address(sfpm),
    //                 liquidityChunk.tickLower(),
    //                 liquidityChunk.tickUpper()
    //             )
    //         )
    //     );

    //     emit LogUint256("feeGrowthInside0LastX128Before before", $feeGrowthInside0LastX128Before);
    //     emit LogUint256("feeGrowthInside1LastX128Before before", $feeGrowthInside1LastX128Before);

    //     // @note store amountsToCollect per chunk/leg
    //     {
    //         //
    //         int128 newFeesBaseRoundDown0 = int128(
    //             int256(Math.mulDiv128($feeGrowthInside0LastX128Before, netLiquidityBefore))
    //         );
    //         int128 newFeesBaseRoundDown1 = int128(
    //             int256(Math.mulDiv128($feeGrowthInside1LastX128Before, netLiquidityBefore))
    //         );

    //         emit LogInt256("newFeesBaseRoundDown0", newFeesBaseRoundDown0);
    //         emit LogInt256("newFeesBaseRoundDown1", newFeesBaseRoundDown1);

    //         emit LogInt256("newFeesBaseRoundDown0", newFeesBaseRoundDown0);
    //         emit LogInt256("newFeesBaseRoundDown1", newFeesBaseRoundDown1);

    //         //
    //         $amountToCollect0 = int128(Math.max(newFeesBaseRoundDown0 - oldFeesBase0, 0));
    //         $amountToCollect1 = int128(Math.max(newFeesBaseRoundDown1 - oldFeesBase1, 0));
    //     }

    //     emit LogInt256("amountToCollect0 before", $amountToCollect0);
    //     emit LogInt256("amountToCollect1 before", $amountToCollect1);

    //     {
    //         // get the burned amounts (true moved amounts)
    //         // also get the true collected amounts
    //         quote_uni_CollectAndBurn();
    //     }

    //     // @note helper to get gross and owed premium
    //     // get premium gross/owed before (compute with max tick to get value stored in sfpm currently)
    //     // after check if stored value matches this value
    //     {
    //         ($accountPremiumGrossBefore0, $accountPremiumGrossBefore1) = sfpm.getAccountPremium(
    //             address(pool),
    //             $activeUser,
    //             tokenIdLong.tokenType(0),
    //             liquidityChunk.tickLower(),
    //             liquidityChunk.tickUpper(),
    //             type(int24).max,
    //             0 // short to check gross
    //         );

    //         // get gross premium
    //         emit LogUint256("$accountPremiumGrossBefore0", $accountPremiumGrossBefore0);
    //         emit LogUint256("$accountPremiumGrossBefore1", $accountPremiumGrossBefore1);
    //     }

    //     {
    //         // owed premium
    //         ($accountPremiumOwedBefore0, $accountPremiumOwedBefore1) = sfpm.getAccountPremium(
    //             address(pool),
    //             $activeUser,
    //             tokenIdLong.tokenType(0),
    //             liquidityChunk.tickLower(),
    //             liquidityChunk.tickUpper(),
    //             type(int24).max,
    //             1 // long to check owed
    //         );

    //         // get owed premium
    //         emit LogUint256("$accountPremiumGrossBefore0", $accountPremiumOwedBefore0);
    //         emit LogUint256("$accountPremiumGrossBefore1", $accountPremiumOwedBefore1);
    //     }

    //     hevm.prank(msg.sender);
    //     try
    //         sfpm.mintTokenizedPosition(tokenIdLong, positionSize, int24(-887272), int24(887272))
    //     returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalSwapped) {
    //         // @note if chunk liquidity is greater than net liquidity throw an invariant failure

    //         // copy return into storage
    //         $collectedByLeg = collectedByLeg;
    //         $totalSwapped = totalSwapped;

    //         // check the net liquidity added
    //         {
    //             LeftRightUnsigned accountLiquiditiesAfter = sfpm.getAccountLiquidity(
    //                 address(pool),
    //                 $activeUser,
    //                 tokenIdLong.tokenType(0),
    //                 liquidityChunk.tickLower(),
    //                 liquidityChunk.tickUpper()
    //             );

    //             removedLiquidityAfter = accountLiquiditiesAfter.leftSlot();
    //             netLiquidityAfter = accountLiquiditiesAfter.rightSlot();

    //             emit LogUint256("$LiqAmountActive", $LiqAmountActive);

    //             emit LogUint256("removedLiquidityBefore", removedLiquidityBefore);
    //             emit LogUint256("netLiquidityBefore", netLiquidityBefore);

    //             emit LogUint256("removedLiquidityAfter", removedLiquidityAfter);
    //             emit LogUint256("netLiquidityAfter", netLiquidityAfter);

    //             // check the liquidity tracked is the same as the liquidity computed
    //             assertWithMsg(
    //                 netLiquidityAfter == netLiquidityBefore - $LiqAmountActive,
    //                 "invalid net liquidity"
    //             );

    //             // ensure the removed liquidity remains the same
    //             assertWithMsg(
    //                 removedLiquidityAfter == removedLiquidityBefore + $LiqAmountActive,
    //                 "invalid removed liquidity"
    //             );
    //         }

    //         // @note
    //         // check the liquidity deposited within uniswap
    //         {
    //             (uint128 liquidityDeployed, , , , ) = pool.positions(positionKey);

    //             emit LogUint256("liquidityBefore", liquidityBefore);
    //             emit LogUint256("liquidityDeployed", liquidityDeployed);

    //             assertWithMsg(
    //                 liquidityBefore - $LiqAmountActive == liquidityDeployed,
    //                 "invalid uniswap liq"
    //             );
    //         }

    //         // check stored fees base for this position
    //         {
    //             /// @note move to helper get currentFeeGrowth()
    //             (, $feeGrowthInside0LastX128After, $feeGrowthInside1LastX128After, , ) = pool
    //                 .positions(
    //                     keccak256(
    //                         abi.encodePacked(
    //                             address(sfpm),
    //                             liquidityChunk.tickLower(),
    //                             liquidityChunk.tickUpper()
    //                         )
    //                     )
    //                 );

    //             emit LogUint256("feeGrowthInside0LastX128After", $feeGrowthInside0LastX128After);
    //             emit LogUint256("feeGrowthInside1LastX128After", $feeGrowthInside1LastX128After);

    //             /// @note compute newFeesBase per leg
    //             // new fees base
    //             int128 newFeesBase0 = int128(
    //                 int256(
    //                     Math.mulDiv128RoundingUp($feeGrowthInside0LastX128After, netLiquidityAfter)
    //                 )
    //             );
    //             int128 newFeesBase1 = int128(
    //                 int256(
    //                     Math.mulDiv128RoundingUp($feeGrowthInside1LastX128After, netLiquidityAfter)
    //                 )
    //             );

    //             /// @note get stored feesBase per leg
    //             // check newly stored feesBase
    //             (int128 feesBase0, int128 feesBase1) = sfpm.getAccountFeesBase(
    //                 address(pool),
    //                 msg.sender,
    //                 tokenIdLong.tokenType(0),
    //                 liquidityChunk.tickLower(),
    //                 liquidityChunk.tickUpper()
    //             );

    //             emit LogInt256("oldFeesBase0", oldFeesBase0);
    //             emit LogInt256("oldFeesBase1", oldFeesBase1);

    //             emit LogInt256("newFeesBase0", newFeesBase0);
    //             emit LogInt256("newFeesBase1", newFeesBase1);

    //             emit LogInt256("feesBase0", feesBase0);
    //             emit LogInt256("feesBase1", feesBase1);

    //             assertWithMsg(newFeesBase0 == feesBase0, "invalid fees base 0");
    //             assertWithMsg(newFeesBase1 == feesBase1, "invalid fees base 1");
    //         }

    //         /// compute and verify the amounts to collect
    //         /// collected the amounts using starting liquidity
    //         {
    //             $amountToCollect0 += int128($amountBurned0);
    //             $amountToCollect1 += int128($amountBurned1);

    //             // ensure amountToCollect is always positive
    //             assertWithMsg($amountToCollect0 >= 0, "amountToCollect0 invalid");
    //             assertWithMsg($amountToCollect1 >= 0, "amountToCollect1 invalid");

    //             emit LogInt256("amountToCollect0", $amountToCollect0);
    //             emit LogInt256("amountToCollect1", $amountToCollect1);

    //             emit LogUint256("receivedAmount0", $recievedAmount0);
    //             emit LogUint256("receivedAmount1", $recievedAmount1);

    //             emit LogInt256("amountBurned0", $amountBurned0);
    //             emit LogInt256("amountBurned1", $amountBurned1);

    //             // ensure that the collected amounts never underflow
    //             // as the collected amounts are computed in an unchecked block
    //             assertWithMsg(
    //                 $recievedAmount0 >= uint128(int128($amountBurned0)),
    //                 "collected 0 underflow"
    //             );
    //             assertWithMsg(
    //                 $recievedAmount1 >= uint128(int128($amountBurned1)),
    //                 "collected 1 underflow"
    //             );

    //             $collected0 = $recievedAmount0 - uint128(int128($amountBurned0));
    //             $collected1 = $recievedAmount1 - uint128(int128($amountBurned1));

    //             emit LogUint256("collected0", $collected0);
    //             emit LogUint256("collected1", $collected1);

    //             emit LogUint256("collectedByLeg[0].rightSlot()", $collectedByLeg[0].rightSlot());
    //             emit LogUint256("collectedByLeg[0].leftSlot()", $collectedByLeg[0].leftSlot());

    //             assertWithMsg($collected0 == $collectedByLeg[0].rightSlot(), "invalid collected 0");
    //             assertWithMsg($collected1 == $collectedByLeg[0].leftSlot(), "invalid collected 1");

    //             // @note move to helper getOwedGrossPremium(leg) -> will have activeTokenId and LiqChunk
    //             {
    //                 // get premium gross
    //                 ($accountPremiumGrossAfter0, $accountPremiumGrossAfter1) = sfpm
    //                     .getAccountPremium(
    //                         address(pool),
    //                         $activeUser,
    //                         tokenIdLong.tokenType(0),
    //                         liquidityChunk.tickLower(),
    //                         liquidityChunk.tickUpper(),
    //                         type(int24).max,
    //                         0 // to query gross
    //                     );

    //                 // get premium owed
    //                 ($accountPremiumOwedAfter0, $accountPremiumOwedAfter1) = sfpm.getAccountPremium(
    //                     address(pool),
    //                     $activeUser,
    //                     tokenIdLong.tokenType(0),
    //                     liquidityChunk.tickLower(),
    //                     liquidityChunk.tickUpper(),
    //                     type(int24).max,
    //                     1 // to query owed
    //                 );

    //                 // gross
    //                 emit LogUint256("$accountPremiumGrossAfter0", $accountPremiumGrossAfter0);
    //                 emit LogUint256("$accountPremiumGrossAfter1", $accountPremiumGrossAfter1);
    //                 // owed
    //                 emit LogUint256("$accountPremiumOwedAfter0", $accountPremiumOwedAfter0);
    //                 emit LogUint256("$accountPremiumOwedAfter1", $accountPremiumOwedAfter1);

    //                 /// @note modify to be per leg check
    //                 /// make all subfunctions internal
    //                 if ($amountToCollect0 != 0 || $amountToCollect1 != 0) {
    //                     LeftRightUnsigned deltaPremiumOwed;
    //                     LeftRightUnsigned deltaPremiumGross;

    //                     /// assert premia values before and after
    //                     // add previous s_accountPremiumOwed by new amounts (if previously uint128 max ensure it doesn't overflow)
    //                     try
    //                         this.getPremiaDeltasChecked(
    //                             netLiquidityBefore,
    //                             removedLiquidityBefore,
    //                             $collected0,
    //                             $collected1
    //                         )
    //                     returns (
    //                         LeftRightUnsigned deltaPremiumOwedR,
    //                         LeftRightUnsigned deltaPremiumGrossR
    //                     ) {
    //                         // pass
    //                         deltaPremiumOwed = deltaPremiumOwedR;
    //                         deltaPremiumGross = deltaPremiumGrossR;
    //                     } catch {
    //                         assertWithMsg(false, "fail  in premia calc");
    //                     }

    //                     emit LogUint256(
    //                         "deltaPremiumOwed.rightSlot()",
    //                         deltaPremiumOwed.rightSlot()
    //                     );

    //                     emit LogUint256("deltaPremiumOwed.leftSlot()", deltaPremiumOwed.leftSlot());

    //                     emit LogUint256(
    //                         "deltaPremiumGross.rightSlot()",
    //                         deltaPremiumGross.rightSlot()
    //                     );
    //                     emit LogUint256(
    //                         "deltaPremiumGross.leftSlot()",
    //                         deltaPremiumGross.leftSlot()
    //                     );

    //                     // ensure getAccountPremium up to the current touch(max tick) vals match
    //                     // against the externally computed premia values
    //                     (
    //                         $accountPremiumGrossCalculated0,
    //                         $accountPremiumGrossCalculated1,
    //                         $accountPremiumOwedCalculated0,
    //                         $accountPremiumOwedCalculated1
    //                     ) = incrementPremiaAccumulator(
    //                         $accountPremiumGrossBefore0,
    //                         $accountPremiumGrossBefore1,
    //                         //
    //                         deltaPremiumGross.rightSlot(),
    //                         deltaPremiumGross.leftSlot(),
    //                         //
    //                         $accountPremiumOwedBefore0,
    //                         $accountPremiumOwedBefore1,
    //                         //
    //                         deltaPremiumOwed.rightSlot(),
    //                         deltaPremiumOwed.leftSlot()
    //                     );

    //                     emit LogUint256(
    //                         "$accountPremiumGrossCalculated0",
    //                         $accountPremiumGrossCalculated0
    //                     );
    //                     emit LogUint256(
    //                         "$accountPremiumGrossCalculated1",
    //                         $accountPremiumGrossCalculated1
    //                     );
    //                     //
    //                     emit LogUint256(
    //                         "$accountPremiumOwedCalculated0",
    //                         $accountPremiumOwedCalculated0
    //                     );
    //                     emit LogUint256(
    //                         "$accountPremiumOwedCalculated1",
    //                         $accountPremiumOwedCalculated1
    //                     );

    //                     // check calculated gross matches up with stored
    //                     assertWithMsg(
    //                         $accountPremiumGrossCalculated0 == $accountPremiumGrossAfter0,
    //                         "invalid gross 0"
    //                     );
    //                     assertWithMsg(
    //                         $accountPremiumGrossCalculated1 == $accountPremiumGrossAfter1,
    //                         "invalid gross 1"
    //                     );

    //                     // check owed matches up with stored
    //                     assertWithMsg(
    //                         $accountPremiumOwedCalculated0 == $accountPremiumOwedAfter0,
    //                         "invalid owed 0"
    //                     );
    //                     assertWithMsg(
    //                         $accountPremiumOwedCalculated1 == $accountPremiumOwedAfter1,
    //                         "invalid owed 1"
    //                     );
    //                 } else {
    //                     // gross checks
    //                     assertWithMsg(
    //                         $accountPremiumGrossBefore0 == $accountPremiumGrossAfter0,
    //                         "invalid gross 0 -> no collect"
    //                     );
    //                     assertWithMsg(
    //                         $accountPremiumGrossBefore1 == $accountPremiumGrossAfter1,
    //                         "invalid gross 1 -> no collect"
    //                     );

    //                     // owed checks
    //                     assertWithMsg(
    //                         $accountPremiumOwedBefore0 == $accountPremiumOwedAfter0,
    //                         "invalid owed 0 -> no collect"
    //                     );
    //                     assertWithMsg(
    //                         $accountPremiumOwedBefore1 == $accountPremiumOwedAfter1,
    //                         "invalid owed 1 -> no collect"
    //                     );
    //                 }
    //             }
    //         }

    //         // add minted option to mapping of minted SFPM positions (to grab for burn)
    //         userPositionsSFPMLong[msg.sender].push(tokenIdLong);

    //         // reset the tokenIdLong for next iteration
    //         tokenIdLong = TokenId.wrap(uint256(0));
    //     } catch {
    //         // @note if it fails ensure the amount of liquidity being minted was valid
    //         // that chunk lquidity < net liquidity (should be valid)
    //         // shouldRevert flag should also not be true
    //     }
    // }

    /// *** general multiple mints of longs + shorts
    // check for should revert flag and bound so that it is a valid event

    // mint SFPM Swap At Mint = true, and ITM = true
    function mint_option_SFPM_swapT_ITMT(
        uint256 minter_index,
        bool asset,
        bool is_call,
        bool is_long,
        uint24 width,
        int256 strike,
        uint128 positionSize
    ) public {
        minter_index = bound(minter_index, 0, 4);
        if (actors[minter_index] == msg.sender) {
            minter_index = bound(minter_index + 1, 0, 4);
        }

        address minter = actors[minter_index];

        // must be
        TokenId $activeTokenId = _generate_single_leg_tokenid(
            asset,
            is_call,
            false,
            false,
            false,
            width,
            strike
        );

        int256 totalMoved0;
        int256 totalMoved1;

        int24 tickLimitLow = int24(887272);
        int24 tickLimitHigh = int24(-887272);

        {
            // get moved amounts
            // moved amounts is faulty function
            // reverts for some reason
            (int256 moved0, int256 moved1) = _calculate_moved_amounts($activeTokenId, positionSize);

            emit LogInt256("moved0", moved0);
            emit LogInt256("moved1", moved1);

            // get itm amounts
            (int256 itm0, int256 itm1) = _calculate_itm_amounts(
                $activeTokenId.tokenType(0),
                moved0,
                moved1
            );

            emit LogInt256("itm0", itm0);
            emit LogInt256("itm1", itm1);

            (int256 swapAmount, bool zeroForOne) = _compute_swap_amounts(itm0, itm1);

            hevm.prank(minter);
            fund_and_approve();

            (int256 swap0, int256 swap1, int24 tickAfterSwap) = _execute_swap_simulation(
                minter,
                zeroForOne,
                swapAmount
            );

            emit LogInt256("swap0", swap0);
            emit LogInt256("swap1", swap1);

            // total moved
            totalMoved0 = moved0 + swap0;
            totalMoved1 = moved1 + swap1;

            emit LogInt256("totalMoved0", totalMoved0);
            emit LogInt256("totalMoved1", totalMoved1);
        }

        // current balances
        int256 balBefore0 = int256(IERC20(USDC).balanceOf(minter));
        int256 balBefore1 = int256(IERC20(WETH).balanceOf(minter));

        emit LogInt256("bal before 0", balBefore0);
        emit LogInt256("bal before 1", balBefore1);

        // then try to purchase an amount larger than this amount (startingLiquidity < chunkLiquidity)
        hevm.prank(minter);
        try sfpm.mintTokenizedPosition($activeTokenId, positionSize, tickLimitLow, tickLimitHigh) {
            // check final balances
            int256 balAfter0 = int256(IERC20(USDC).balanceOf(minter));
            int256 balAfter1 = int256(IERC20(WETH).balanceOf(minter));

            emit LogInt256("bal after 0", balAfter0);
            emit LogInt256("bal after 1", balAfter1);

            assertApproxEqRel(
                balBefore0 - totalMoved0,
                balAfter0,
                1e21, // 1e+21 -> assert value is within 0.01%
                "bal 0 delta invalid"
            );

            assertApproxEqRel(
                balBefore1 - totalMoved1,
                balAfter1,
                1e21, // 1e+21 -> assert value is within 0.01%
                "bal 1 delta invalid"
            );

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMShort[minter].push($activeTokenId);
        } catch {}
    }

    // mint SFPM regular mint Swap At Mint = false, and ITM = false
    function mint_option_SFPM_swapF_ITMF(
        uint256 minter_index,
        bool asset,
        bool is_call,
        bool is_long,
        uint24 width,
        int256 strike,
        uint128 positionSize
    ) public {
        if (actors[minter_index] == msg.sender) {
            minter_index = bound(minter_index + 1, 0, 4);
        }

        address minter = actors[minter_index];

        // must be
        TokenId $activeTokenId = _generate_single_leg_tokenid(
            asset,
            is_call,
            false,
            true,
            false,
            width,
            strike
        );

        (, currentTick, , , , , ) = pool.slot0();

        emit LogInt256("pre-mint Tick", currentTick);

        int256 moved0;
        int256 moved1;

        int24 tickLimitLow = int24(-887272);
        int24 tickLimitHigh = int24(887272);

        {
            // get moved amounts
            // moved amounts is faulty function
            // reverts for some reason
            (moved0, moved1) = _calculate_moved_amounts($activeTokenId, positionSize);

            emit LogInt256("moved0", moved0);
            emit LogInt256("moved1", moved1);
        }

        // current balances
        int256 balBefore0 = int256(IERC20(USDC).balanceOf(minter));
        int256 balBefore1 = int256(IERC20(WETH).balanceOf(minter));

        emit LogInt256("bal before 0", balBefore0);
        emit LogInt256("bal before 1", balBefore1);

        // then try to purchase an amount larger than this amount (startingLiquidity < chunkLiquidity)
        hevm.prank(minter);
        try sfpm.mintTokenizedPosition($activeTokenId, positionSize, tickLimitLow, tickLimitHigh) {
            // check final balances
            int256 balAfter0 = int256(IERC20(USDC).balanceOf(minter));
            int256 balAfter1 = int256(IERC20(WETH).balanceOf(minter));

            emit LogInt256("bal after 0", balAfter0);
            emit LogInt256("bal after 1", balAfter1);

            assertApproxEqRel(
                balBefore0 - moved0,
                balAfter0,
                1e21, // 1e+21 -> assert value is within 0.01%
                "bal 0 delta invalid"
            );

            assertApproxEqRel(
                balBefore1 - moved1,
                balAfter1,
                1e21, // 1e+21 -> assert value is within 0.01%
                "bal 1 delta invalid"
            );

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMShort[msg.sender].push($activeTokenId);
        } catch {}
    }

    // swap at mint true, and ITM false
    function mint_option_SFPM_swapT_ITMF(
        bool asset,
        bool is_call,
        bool is_long,
        uint24 width,
        int256 strike,
        uint128 positionSize
    ) public {
        TokenId $activeTokenId = _generate_single_leg_tokenid(
            asset,
            is_call,
            false,
            true,
            false,
            width,
            strike
        );

        int256 moved0;
        int256 moved1;

        int24 tickLimitLow = int24(887272);
        int24 tickLimitHigh = int24(-887272);

        {
            // get moved amounts
            (moved0, moved1) = _calculate_moved_amounts($activeTokenId, positionSize);

            emit LogInt256("moved0", moved0);
            emit LogInt256("moved1", moved1);
        }

        // current balances
        int256 balBefore0 = int256(IERC20(USDC).balanceOf(msg.sender));
        int256 balBefore1 = int256(IERC20(WETH).balanceOf(msg.sender));

        emit LogInt256("bal before 0", balBefore0);
        emit LogInt256("bal before 1", balBefore1);

        // then try to purchase an amount larger than this amount (startingLiquidity < chunkLiquidity)
        hevm.prank(msg.sender);
        try sfpm.mintTokenizedPosition($activeTokenId, positionSize, tickLimitLow, tickLimitHigh) {
            // check final balances
            int256 balAfter0 = int256(IERC20(USDC).balanceOf(msg.sender));
            int256 balAfter1 = int256(IERC20(WETH).balanceOf(msg.sender));

            emit LogInt256("bal after 0", balAfter0);
            emit LogInt256("bal after 1", balAfter1);

            assertApproxEqRel(
                balBefore0 - moved0,
                balAfter0,
                1e21, // 1e+21 -> assert value is within 0.01%
                "bal 0 delta invalid"
            );

            assertApproxEqRel(
                balBefore1 - moved1,
                balAfter1,
                1e21, // 1e+21 -> assert value is within 0.01%
                "bal 1 delta invalid"
            );

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMShort[msg.sender].push($activeTokenId);
        } catch {}
    }

    // swap at mint false, and itm true
    function mint_option_SFPM_swapF_ITMT(
        bool asset,
        bool is_call,
        bool is_long,
        uint24 width,
        int256 strike,
        uint128 positionSize
    ) public {
        TokenId $activeTokenId = _generate_single_leg_tokenid(
            asset,
            is_call,
            false,
            false,
            false,
            width,
            strike
        );

        int256 moved0;
        int256 moved1;

        int24 tickLimitLow = int24(-887272);
        int24 tickLimitHigh = int24(887272);

        {
            // get moved amounts
            (moved0, moved1) = _calculate_moved_amounts($activeTokenId, positionSize);

            emit LogInt256("moved0", moved0);
            emit LogInt256("moved1", moved1);
        }

        // current balances
        int256 balBefore0 = int256(IERC20(USDC).balanceOf(msg.sender));
        int256 balBefore1 = int256(IERC20(WETH).balanceOf(msg.sender));

        emit LogInt256("bal before 0", balBefore0);
        emit LogInt256("bal before 1", balBefore1);

        // then try to purchase an amount larger than this amount (startingLiquidity < chunkLiquidity)
        hevm.prank(msg.sender);
        try sfpm.mintTokenizedPosition($activeTokenId, positionSize, tickLimitLow, tickLimitHigh) {
            // check final balances
            int256 balAfter0 = int256(IERC20(USDC).balanceOf(msg.sender));
            int256 balAfter1 = int256(IERC20(WETH).balanceOf(msg.sender));

            emit LogInt256("bal after 0", balAfter0);
            emit LogInt256("bal after 1", balAfter1);

            assertApproxEqRel(
                balBefore0 - moved0,
                balAfter0,
                1e21, // 1e+21 -> assert value is within 0.01%
                "bal 0 delta invalid"
            );

            assertApproxEqRel(
                balBefore1 - moved1,
                balAfter1,
                1e21, // 1e+21 -> assert value is within 0.01%
                "bal 1 delta invalid"
            );

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMShort[msg.sender].push($activeTokenId);
        } catch {}
    }

    // swap at mint true, and itm true (netting swap 2 legs of differing token type)
    function mint_option_SFPM_nettingSwap(
        bool asset0,
        bool asset1,
        bool isATM0,
        bool isATM1,
        uint24 width0,
        uint24 width1,
        int256 strike0,
        int256 strike1,
        uint128 positionSize
    ) public {
        // generate double leg shorts
        // dynamic numeraire and token type
        TokenId $activeTokenId = _generate_multiple_leg_tokenid(
            2,
            [asset0, asset1, false, false],
            [true, false, false, false],
            [false, false, false, false],
            [false, false, false, false],
            [isATM0, isATM1, false, false],
            [width0, width1, 0, 0],
            [strike0, strike1, 0, 0]
        );

        int256 totalMoved0;
        int256 totalMoved1;

        int24 tickLimitLow = int24(-887272);
        int24 tickLimitHigh = int24(887272);

        {
            (
                int256 moved0,
                int256 moved1,
                int256 itm0,
                int256 itm1
            ) = _calculate_moved_and_ITM_amounts($activeTokenId, positionSize, false);

            emit LogInt256("moved0", moved0);
            emit LogInt256("moved1", moved1);
            emit LogInt256("itm0", itm0);
            emit LogInt256("itm1", itm1);

            (int256 swapAmount, bool zeroForOne) = _compute_swap_amounts(itm0, itm1);

            emit LogInt256("swapAmount", swapAmount);
            emit LogBool("zeroForOne", zeroForOne);

            (int256 swap0, int256 swap1, int24 tickAfterSwap) = _execute_swap_simulation(
                msg.sender,
                zeroForOne,
                swapAmount
            );

            emit LogInt256("swap0", swap0);
            emit LogInt256("swap1", swap1);

            // total moved
            totalMoved0 = moved0 + swap0;
            totalMoved1 = moved1 + swap1;

            emit LogInt256("totalMoved0", totalMoved0);
            emit LogInt256("totalMoved1", totalMoved1);
        }

        // current balances
        int256 balBefore0 = int256(IERC20(USDC).balanceOf(msg.sender));
        int256 balBefore1 = int256(IERC20(WETH).balanceOf(msg.sender));

        emit LogInt256("bal before 0", balBefore0);
        emit LogInt256("bal before 1", balBefore1);

        // get price before swap
        (currentSqrtPriceX96, , , , , , ) = pool.slot0();

        hevm.prank(msg.sender);
        try sfpm.mintTokenizedPosition($activeTokenId, positionSize, tickLimitHigh, tickLimitLow) {
            // check final balances
            int256 balAfter0 = int256(IERC20(USDC).balanceOf(msg.sender));
            int256 balAfter1 = int256(IERC20(WETH).balanceOf(msg.sender));

            emit LogInt256("bal after 0", balAfter0);
            emit LogInt256("bal after 1", balAfter1);

            assertApproxEqRel(
                balBefore0 - totalMoved0,
                balAfter0,
                1e21, // 1e+21 -> assert value is within 0.01%
                "bal 0 delta invalid"
            );

            assertApproxEqRel(
                balBefore1 - totalMoved1,
                balAfter1,
                1e21, // 1e+21 -> assert value is within 0.01%
                "bal 1 delta invalid"
            );

            int256 convertedMoved1to0 = PanopticMath.convert1to0(totalMoved1, currentSqrtPriceX96);
            emit LogInt256("value of total moved 1 to 0", convertedMoved1to0);

            // disabled as on low liq pools the swap won't occur at a single price (tick liquidity will roll over)
            // ensure that only token 0 was moved as this was a netting swap
            // assertWithMsg(totalMoved0 == convertedMoved1to0, "invalid conversion");

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMShort[msg.sender].push($activeTokenId);
        } catch {}
    }

    // mint SFPM position size = 0
    function invariant_mint_option_SFPM_posSize0(
        uint256 minter_index,
        bool asset,
        bool is_call,
        bool is_long,
        bool is_otm,
        bool is_atm,
        bool swapAtMint,
        uint24 width,
        int256 strike
    ) public {
        minter_index = bound(minter_index, 0, 4);
        if (actors[minter_index] == msg.sender) {
            minter_index = bound(minter_index + 1, 0, 4);
        }

        address minter = actors[minter_index];

        // pos size 0
        uint128 positionSize = 0;
        TokenId tokenId = _generate_single_leg_tokenid(
            asset,
            is_call,
            false,
            is_otm,
            is_atm,
            width,
            strike
        );

        int24 tickLimitLow = swapAtMint ? int24(887272) : int24(-887272);
        int24 tickLimitHigh = swapAtMint ? int24(-887272) : int24(887272);

        // if positionSize == 0 then should fail
        if (positionSize == 0) {
            hevm.prank(minter);
            try sfpm.mintTokenizedPosition(tokenId, positionSize, tickLimitLow, tickLimitHigh) {
                assertWithMsg(false, "can't mint option with position size of 0");
            } catch {}
        }
    }

    // token composition is over 127 bits on either side should fail
    function invariant_mint_option_SFPM_PositionTooLarge(
        uint256 minter_index,
        bool asset,
        bool is_call,
        bool is_long,
        bool is_otm,
        bool is_atm,
        bool swapAtMint,
        uint24 width,
        int256 strike,
        uint128 positionSize
    ) public {
        minter_index = bound(minter_index, 0, 4);
        if (actors[minter_index] == msg.sender) {
            minter_index = bound(minter_index + 1, 0, 4);
        }

        address minter = actors[minter_index];

        TokenId tokenId = _generate_single_leg_tokenid(
            asset,
            is_call,
            false,
            is_otm,
            is_atm,
            width,
            strike
        );

        int24 tickLimitLow = swapAtMint ? int24(887272) : int24(-887272);
        int24 tickLimitHigh = swapAtMint ? int24(-887272) : int24(887272);

        // current balances
        uint256 balBefore0 = IERC20(USDC).balanceOf(minter);
        uint256 balBefore1 = IERC20(WETH).balanceOf(minter);

        hevm.prank(minter);
        try sfpm.mintTokenizedPosition(tokenId, positionSize, tickLimitLow, tickLimitHigh) {
            // if amount moved is greater than 2 ** 127 bits
            // bal before - bal after > 2 ** 127 - 4

            // check final balances
            uint256 balAfter0 = IERC20(USDC).balanceOf(minter);
            uint256 balAfter1 = IERC20(WETH).balanceOf(minter);

            uint256 balDelta0 = balBefore0 - balAfter0;
            uint256 balDelta1 = balBefore1 - balAfter1;

            //--
            emit LogUint256("balBefore0", balBefore0);
            emit LogUint256("balBefore1", balBefore1);
            //
            emit LogUint256("balAfter0", balAfter0);
            emit LogUint256("balAfter1", balAfter1);
            //
            emit LogUint256("balDelta0", balDelta0);
            emit LogUint256("balDelta1", balDelta1);
            //
            emit LogUint256("max", uint128(type(int128).max - 4));

            assertWithMsg(
                !(balDelta0 > uint128(type(int128).max - 4) ||
                    balDelta1 > uint128(type(int128).max - 4)),
                "can't mint a position which exceeds the token limits of 127 bits"
            );
        } catch {}
    }

    // attempt to purchase more liquidity than exists at the chunk
    function invariant_mint_option_SFPM_NotEnoughLiquidity(
        uint256 minter_index,
        bool asset,
        bool is_call,
        bool is_long,
        bool is_otm,
        bool is_atm,
        bool swapAtMint,
        uint24 width,
        int256 strike,
        uint128 positionSize,
        uint128 sizeIncrement
    ) public {
        minter_index = bound(minter_index, 0, 4);
        if (actors[minter_index] == msg.sender) {
            minter_index = bound(minter_index + 1, 0, 4);
        }

        $activeUser = actors[minter_index];

        TokenId $activeTokenId = _generate_single_leg_tokenid(
            asset,
            is_call,
            false,
            is_otm,
            is_atm,
            width,
            strike
        );
        TokenId tokenIdLong = _generate_single_leg_tokenid(
            asset,
            is_call,
            true,
            is_otm,
            is_atm,
            width,
            strike
        );

        int24 tickLimitLow = swapAtMint ? int24(887272) : int24(-887272);
        int24 tickLimitHigh = swapAtMint ? int24(-887272) : int24(887272);

        (int24 tickLower, int24 tickUpper) = $activeTokenId.asTicks(0);

        // check there is no pre-existing liquidity at this chunk deployed by the minter
        LeftRightUnsigned accountLiquidities = sfpm.getAccountLiquidity(
            address(pool),
            $activeUser,
            $activeTokenId.tokenType(0),
            tickLower,
            tickUpper
        );

        //
        if (accountLiquidities.rightSlot() != 0) {
            // mint a small amount of liquidity at this chunk
            sfpm.mintTokenizedPosition($activeTokenId, positionSize, tickLimitLow, tickLimitHigh);
        }

        // invoke actions as the chosen minter
        hevm.prank($activeUser);
        // then try to purchase an amount larger than this amount (startingLiquidity < chunkLiquidity)
        try
            sfpm.mintTokenizedPosition(
                tokenIdLong,
                positionSize + sizeIncrement,
                tickLimitLow,
                tickLimitHigh
            )
        {
            uint256 shortLiq = PanopticMath
                .getLiquidityChunk($activeTokenId, 0, positionSize)
                .liquidity();
            uint256 longLiq = PanopticMath
                .getLiquidityChunk(tokenIdLong, 0, positionSize + sizeIncrement)
                .liquidity();

            emit LogUint256("shortLiq", shortLiq);
            emit LogUint256("longLiq", longLiq);

            // continue because the position size generated is of the same size
            if (shortLiq == longLiq) {
                revert();
            }

            assertWithMsg(false, "Can't purchase more chunk liquidity than is available!");
        } catch {}
    }

    // can't mint a position that defies the slippage bounds
    function invariant_mint_option_SFPM_PriceBoundFail(
        bool asset,
        bool is_call,
        bool is_long,
        bool is_otm,
        bool is_atm,
        bool swapAtMint,
        uint24 width,
        int256 strike,
        uint128 positionSize,
        bool slippageDirection,
        int24 randTick
    ) public {
        TokenId $activeTokenId = _generate_single_leg_tokenid(
            asset,
            is_call,
            false,
            is_otm,
            is_atm,
            width,
            strike
        );

        // get moved amounts
        // moved amounts is faulty function
        // reverts for some reason
        (int256 moved0, int256 moved1) = _calculate_moved_amounts($activeTokenId, positionSize);

        // get itm amounts
        (int256 itm0, int256 itm1) = _calculate_itm_amounts(
            $activeTokenId.tokenType(0),
            moved0,
            moved1
        );

        (int256 swapAmount, bool zeroForOne) = _compute_swap_amounts(itm0, itm1);

        (, , /*int256 swap0*/ /*int256 swap1*/ int24 tickAfterSwap) = _execute_swap_simulation(
            msg.sender,
            zeroForOne,
            swapAmount
        );

        int24 tickLimitLow;
        int24 tickLimitHigh;

        // get the currentTick after this position would have been minted via sim and
        if (slippageDirection) {
            // set invalid tickLow
            // sets to a lower tickLimitLow
            tickLimitLow = randTick % tickAfterSwap;

            // set valid tickHigh
            tickLimitHigh = int24(887272);
        } else {
            // set valid tickLow
            tickLimitLow = int24(-887272);

            // set invalid tickHigh
            tickLimitHigh = tickAfterSwap + int24(Math.abs(randTick));
        }

        // flip ticks for swap at mint signal
        if (swapAtMint) {
            (tickLimitLow, tickLimitHigh) = (tickLimitHigh, tickLimitLow);
        }

        // then try to purchase an amount larger than this amount (startingLiquidity < chunkLiquidity)
        try sfpm.mintTokenizedPosition($activeTokenId, positionSize, tickLimitLow, tickLimitHigh) {
            assertWithMsg(false, "Can't mint an option which defies the slippage bounds");
        } catch {}
    }
}
