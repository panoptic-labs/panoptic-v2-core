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
        $shouldRevertSFPM = false;

        // store the current actor
        $activeUser = msg.sender;

        // generate a random number of legs
        $activeNumLegs = numLegs = bound(numLegs, 1, 4);

        $activeTokenId = _generate_multiple_leg_tokenid(
            numLegs,
            asset_in,
            is_call_in,
            [false, false, false, false], // generate short
            is_otm_in,
            is_atm_in,
            width_in,
            strike_in
        );

        // pre-mint calculations/actions for storage
        for (uint i; i < $activeNumLegs; i++) {
            $activeLegIndex = i;

            emit LogUint256("active leg index: ", $activeLegIndex);

            {
                // get the amount of liquidity being deposited
                $liquidityChunk[$activeLegIndex] = PanopticMath.getLiquidityChunk(
                    $activeTokenId,
                    $activeLegIndex,
                    positionSize
                );

                $sTickLower[$activeLegIndex] = $liquidityChunk[$activeLegIndex].tickLower();
                $sTickUpper[$activeLegIndex] = $liquidityChunk[$activeLegIndex].tickUpper();
                $sLiqAmounts[$activeLegIndex] = $liquidityChunk[$activeLegIndex].liquidity();

                // *** if liquidity amounts is zero then execution should revert ***
                {
                    if ($sLiqAmounts[$activeLegIndex] == 0) $shouldRevertSFPM = true;
                }

                // store the active position details
                {
                    $tickLowerActive = $sTickLower[$activeLegIndex];
                    $tickUpperActive = $sTickUpper[$activeLegIndex];
                    $LiqAmountActive = $sLiqAmounts[$activeLegIndex];
                }

                // emit positional bounds and liquidity
                emit LogInt256("tick lower", $tickLowerActive);
                emit LogInt256("tick upper", $tickUpperActive);
                emit LogUint256("liquidity amounts", $LiqAmountActive);
            }

            // poke if there is pre-existing liq for the user at the positional bounds
            {
                hevm.prank(address(sfpm));
                try pool.burn($tickLowerActive, $tickUpperActive, 0) {} catch {}
            }

            {
                // get the amount of liquidity within that range present in uniswap already
                $positionKey[$activeLegIndex] = keccak256(
                    abi.encodePacked(address(sfpm), $tickLowerActive, $tickUpperActive)
                );
                (uniLiquidityBefore[$activeLegIndex], , , , ) = pool.positions(
                    $positionKey[$activeLegIndex]
                );

                // get SFPM stored account liquidity before
                LeftRightUnsigned accountLiquiditiesBefore = sfpm.getAccountLiquidity(
                    address(pool),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive
                );

                // store the removed and net liquidity for the chunk
                //  before mint
                $removedLiquidityBefore[$activeLegIndex] = accountLiquiditiesBefore.leftSlot();
                $netLiquidityBefore[$activeLegIndex] = accountLiquiditiesBefore.rightSlot();
            }

            {
                // s_accountFeesBase before
                // check s_accountFeesBase is updated correctly
                ($oldFeesBase0[$activeLegIndex], $oldFeesBase1[$activeLegIndex]) = sfpm
                    .getAccountFeesBase(
                        address(pool),
                        $activeUser,
                        $activeTokenId.tokenType($activeLegIndex),
                        $tickLowerActive,
                        $tickUpperActive
                    );

                emit LogInt256("pre-mint feesbase 0", $oldFeesBase0[$activeLegIndex]);
                emit LogInt256("pre-mint feesbase 1", $oldFeesBase1[$activeLegIndex]);
            }

            {
                (
                    ,
                    $feeGrowthInside0LastX128Before[$activeLegIndex],
                    $feeGrowthInside1LastX128Before[$activeLegIndex],
                    ,

                ) = pool.positions(
                    keccak256(abi.encodePacked(address(sfpm), $tickLowerActive, $tickUpperActive))
                );

                // after touch
                emit LogUint256(
                    "pre-mint feeGrowthInside0LastX128",
                    $feeGrowthInside0LastX128Before[$activeLegIndex]
                );
                emit LogUint256(
                    "pre-mint feeGrowthInside1LastX128",
                    $feeGrowthInside1LastX128Before[$activeLegIndex]
                );
            }

            {
                $newFeesBaseRoundDown0[$activeLegIndex] = int128(
                    int256(
                        Math.mulDiv128(
                            $feeGrowthInside0LastX128Before[$activeLegIndex],
                            $netLiquidityBefore[$activeLegIndex]
                        )
                    )
                );
                $newFeesBaseRoundDown1[$activeLegIndex] = int128(
                    int256(
                        Math.mulDiv128(
                            $feeGrowthInside1LastX128Before[$activeLegIndex],
                            $netLiquidityBefore[$activeLegIndex]
                        )
                    )
                );

                emit LogInt256("newFeesBaseRoundDown0", $newFeesBaseRoundDown0[$activeLegIndex]);
                emit LogInt256("newFeesBaseRoundDown1", $newFeesBaseRoundDown1[$activeLegIndex]);

                //
                $amountToCollect0[$activeLegIndex] = int128(
                    Math.max(
                        $newFeesBaseRoundDown0[$activeLegIndex] - $oldFeesBase0[$activeLegIndex],
                        0
                    )
                );
                $amountToCollect1[$activeLegIndex] = int128(
                    Math.max(
                        $newFeesBaseRoundDown1[$activeLegIndex] - $oldFeesBase1[$activeLegIndex],
                        0
                    )
                );

                emit LogInt256("$amountToCollect0", $amountToCollect0[$activeLegIndex]);
                emit LogInt256("$amountToCollect1", $amountToCollect1[$activeLegIndex]);

                // ensure amountToCollect is always positive
                assertWithMsg($amountToCollect0[$activeLegIndex] >= 0, "amountToCollect0 invalid");
                assertWithMsg($amountToCollect1[$activeLegIndex] >= 0, "amountToCollect1 invalid");

                // get the minted amounts (true moved amounts)
                // also get the true collected amounts
                quote_uni_CollectAndMint();
            }

            // get premium gross/owed before (compute with max tick to get value stored in sfpm currently)
            // after check if stored value matches this value
            {
                (
                    $accountPremiumGrossBefore0[$activeLegIndex],
                    $accountPremiumGrossBefore1[$activeLegIndex]
                ) = sfpm.getAccountPremium(
                    address(pool),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive,
                    type(int24).max,
                    0 // short to check gross
                );

                // get gross premium
                emit LogUint256(
                    "$accountPremiumGrossBefore0",
                    $accountPremiumGrossBefore0[$activeLegIndex]
                );
                emit LogUint256(
                    "$accountPremiumGrossBefore1",
                    $accountPremiumGrossBefore1[$activeLegIndex]
                );

                // owed premium
                (
                    $accountPremiumOwedBefore0[$activeLegIndex],
                    $accountPremiumOwedBefore1[$activeLegIndex]
                ) = sfpm.getAccountPremium(
                    address(pool),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive,
                    type(int24).max,
                    1 // long to check owed
                );

                // get owed premium
                emit LogUint256(
                    "$accountPremiumOwedBefore0",
                    $accountPremiumOwedBefore0[$activeLegIndex]
                );
                emit LogUint256(
                    "$accountPremiumOwedBefore1",
                    $accountPremiumOwedBefore1[$activeLegIndex]
                );
            }
        }

        // reverse tick order if swap at mint
        int24 tickLimitLow = swapAtMint ? int24(887272) : int24(-887272);
        int24 tickLimitHigh = swapAtMint ? int24(-887272) : int24(887272);

        hevm.prank($activeUser);
        try
            sfpm.mintTokenizedPosition($activeTokenId, positionSize, tickLimitLow, tickLimitHigh)
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalSwapped) {
            emit LogString("mint was successful");

            // copy return into storage
            $sCollectedByLeg = collectedByLeg;
            $sTotalSwapped = totalSwapped;

            // preform post-mint invariant checks per leg
            for (uint i; i < $activeNumLegs; i++) {
                $activeLegIndex = i;

                emit LogUint256("active leg index: ", $activeLegIndex);

                {
                    $tickLowerActive = $sTickLower[$activeLegIndex];
                    $tickUpperActive = $sTickUpper[$activeLegIndex];
                    $LiqAmountActive = $sLiqAmounts[$activeLegIndex];

                    emit LogInt256("$tickLowerActive", $tickLowerActive);
                    emit LogInt256("$tickUpperActive", $tickUpperActive);
                    emit LogUint256("$LiqAmountActive", $LiqAmountActive);
                }

                // check the liquidity deposited within uniswap
                // ** make netting change
                // {
                //     (uniLiquidityAfter[$activeLegIndex], , , , ) = pool.positions(
                //         $positionKey[$activeLegIndex]
                //     );

                //     emit LogUint256("uni liquidity before", uniLiquidityBefore[$activeLegIndex]);
                //     emit LogUint256("$LiqAmountActive", $sLiqAmounts[$activeLegIndex]);
                //     emit LogUint256("uni liquidity after", uniLiquidityAfter[$activeLegIndex]);

                //     // if multiple chunks touch the same leg the account for this difference
                //     // in the final returned amounts
                //     assertWithMsg(
                //         uniLiquidityBefore[$activeLegIndex] + $sLiqAmounts[$activeLegIndex] ==
                //             uniLiquidityAfter[$activeLegIndex],
                //         "invalid uniswap liq"
                //     );
                // }

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

                    ($newFeesBase0[$activeLegIndex], $newFeesBase1[$activeLegIndex]) = sfpm
                        .getAccountFeesBase(
                            address(pool),
                            $activeUser,
                            $activeTokenId.tokenType($activeLegIndex),
                            $tickLowerActive,
                            $tickUpperActive
                        );

                    emit LogInt256("oldFeesBase0", $oldFeesBase0[$activeLegIndex]);
                    emit LogInt256("oldFeesBase1", $oldFeesBase1[$activeLegIndex]);

                    emit LogInt256("newFeesBase0", $newFeesBase0[$activeLegIndex]);
                    emit LogInt256("newFeesBase1", $newFeesBase1[$activeLegIndex]);

                    emit LogInt256("$newFeesBaseRoundUp0", $newFeesBaseRoundUp0[$activeLegIndex]);
                    emit LogInt256("$newFeesBaseRoundUp1", $newFeesBaseRoundUp1[$activeLegIndex]);

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
                        $sCollectedByLeg[$activeLegIndex].rightSlot()
                    );
                    emit LogUint256(
                        "collectedByLeg token 1",
                        $sCollectedByLeg[$activeLegIndex].leftSlot()
                    );

                    assertWithMsg(
                        $collected0[$activeLegIndex] ==
                            $sCollectedByLeg[$activeLegIndex].rightSlot(),
                        "invalid collected 0"
                    );
                    assertWithMsg(
                        $collected1[$activeLegIndex] ==
                            $sCollectedByLeg[$activeLegIndex].leftSlot(),
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

                // check the balance of their ERC1155 id increased by position size
                {
                    // adjust balances and verify
                    _increment_tokenBalance(positionSize);
                    //_check_tokenBalance();
                }
            }

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMShort[msg.sender].push($activeTokenId);

            // reset the activeTokenId for next iteration
            $activeTokenId = TokenId.wrap(uint256(0));
        } catch Error(string memory reason) {
            emit LogString(reason);

            emit LogBool("should revert ?", $shouldRevertSFPM);

            assertWithMsg($shouldRevertSFPM, "non-expected revert");
        }
    }

    function mint_option_SFPM_multiLong(
        uint8 numLegs,
        uint8 randNumber,
        uint128 positionSize,
        bool swapAtMint
    ) public {
        $shouldRevertSFPM = false;

        // store the current actor
        $activeUser = msg.sender;

        // generate a random number of legs
        $activeNumLegs = bound(numLegs, 1, 4);

        // initialize tokenId
        $activeTokenId = TokenId.wrap(poolId);

        {
            // search for a tokenId that the current actor has sold
            uint256 totalPosLen = userPositionsSFPMShort[$activeUser].length;

            if (totalPosLen == 0) {
                // if no short positions exist for the user then pass
                revert();
            }

            // either bound to the max amount of short tokenId's or active number of legs
            uint256 maxIndex = totalPosLen - 1;
            uint256 maxLoop = maxIndex > $activeNumLegs ? maxIndex : $activeNumLegs;

            for (uint i; i < maxLoop; i++) {
                TokenId currTokenId = userPositionsSFPMLong[$activeUser][maxLoop - i];

                // grab random leg from random tokenId
                uint256 legIndex = bound(randNumber, 0, currTokenId.countLegs() - 1);

                // append the leg to the constructed long leg
                $activeTokenId.addLeg(
                    i,
                    currTokenId.optionRatio(i),
                    currTokenId.asset(i),
                    1, // flip long
                    currTokenId.tokenType(i),
                    currTokenId.riskPartner(i),
                    currTokenId.strike(i),
                    currTokenId.width(i)
                );
            }
        }

        // pre-mint calculations/actions for storage
        for (uint i; i < $activeNumLegs; i++) {
            $activeLegIndex = i;

            emit LogUint256("active leg index: ", $activeLegIndex);

            {
                // get the amount of liquidity being deposited
                $liquidityChunk[$activeLegIndex] = PanopticMath.getLiquidityChunk(
                    $activeTokenId,
                    $activeLegIndex,
                    positionSize
                );

                $sTickLower[$activeLegIndex] = $liquidityChunk[$activeLegIndex].tickLower();
                $sTickUpper[$activeLegIndex] = $liquidityChunk[$activeLegIndex].tickUpper();
                $sLiqAmounts[$activeLegIndex] = $liquidityChunk[$activeLegIndex].liquidity();

                // *** if liquidity amounts is zero then execution should revert ***
                {
                    if ($sLiqAmounts[$activeLegIndex] == 0) $shouldRevertSFPM = true;
                }

                // store the active position details
                {
                    $tickLowerActive = $sTickLower[$activeLegIndex];
                    $tickUpperActive = $sTickUpper[$activeLegIndex];
                    $LiqAmountActive = $sLiqAmounts[$activeLegIndex];
                }

                // emit positional bounds and liquidity
                emit LogInt256("tick lower", $tickLowerActive);
                emit LogInt256("tick upper", $tickUpperActive);
                emit LogUint256("liquidity amounts", $LiqAmountActive);
            }

            // poke if there is pre-existing liq for the user at the positional bounds
            {
                hevm.prank(address(sfpm));
                try pool.burn($tickLowerActive, $tickUpperActive, 0) {} catch {}
            }

            {
                // get the amount of liquidity within that range present in uniswap already
                $positionKey[$activeLegIndex] = keccak256(
                    abi.encodePacked(address(sfpm), $tickLowerActive, $tickUpperActive)
                );
                (uniLiquidityBefore[$activeLegIndex], , , , ) = pool.positions(
                    $positionKey[$activeLegIndex]
                );

                // get SFPM stored account liquidity before
                LeftRightUnsigned accountLiquiditiesBefore = sfpm.getAccountLiquidity(
                    address(pool),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive
                );

                // store the removed and net liquidity for the chunk
                //  before mint
                $removedLiquidityBefore[$activeLegIndex] = accountLiquiditiesBefore.leftSlot();
                $netLiquidityBefore[$activeLegIndex] = accountLiquiditiesBefore.rightSlot();
            }

            {
                // s_accountFeesBase before
                // check s_accountFeesBase is updated correctly
                ($oldFeesBase0[$activeLegIndex], $oldFeesBase1[$activeLegIndex]) = sfpm
                    .getAccountFeesBase(
                        address(pool),
                        $activeUser,
                        $activeTokenId.tokenType($activeLegIndex),
                        $tickLowerActive,
                        $tickUpperActive
                    );

                emit LogInt256("pre-mint feesbase 0", $oldFeesBase0[$activeLegIndex]);
                emit LogInt256("pre-mint feesbase 1", $oldFeesBase1[$activeLegIndex]);
            }

            {
                (
                    ,
                    $feeGrowthInside0LastX128Before[$activeLegIndex],
                    $feeGrowthInside1LastX128Before[$activeLegIndex],
                    ,

                ) = pool.positions(
                    keccak256(abi.encodePacked(address(sfpm), $tickLowerActive, $tickUpperActive))
                );

                // after touch
                emit LogUint256(
                    "pre-mint feeGrowthInside0LastX128",
                    $feeGrowthInside0LastX128Before[$activeLegIndex]
                );
                emit LogUint256(
                    "pre-mint feeGrowthInside1LastX128",
                    $feeGrowthInside1LastX128Before[$activeLegIndex]
                );
            }

            {
                $newFeesBaseRoundDown0[$activeLegIndex] = int128(
                    int256(
                        Math.mulDiv128(
                            $feeGrowthInside0LastX128Before[$activeLegIndex],
                            $netLiquidityBefore[$activeLegIndex]
                        )
                    )
                );
                $newFeesBaseRoundDown1[$activeLegIndex] = int128(
                    int256(
                        Math.mulDiv128(
                            $feeGrowthInside1LastX128Before[$activeLegIndex],
                            $netLiquidityBefore[$activeLegIndex]
                        )
                    )
                );

                emit LogInt256("newFeesBaseRoundDown0", $newFeesBaseRoundDown0[$activeLegIndex]);
                emit LogInt256("newFeesBaseRoundDown1", $newFeesBaseRoundDown1[$activeLegIndex]);

                //
                $amountToCollect0[$activeLegIndex] = int128(
                    Math.max(
                        $newFeesBaseRoundDown0[$activeLegIndex] - $oldFeesBase0[$activeLegIndex],
                        0
                    )
                );
                $amountToCollect1[$activeLegIndex] = int128(
                    Math.max(
                        $newFeesBaseRoundDown1[$activeLegIndex] - $oldFeesBase1[$activeLegIndex],
                        0
                    )
                );

                // get the burned amounts (true moved amounts)
                // also get the true collected amounts
                quote_uni_CollectAndBurn();
            }

            // get premium gross/owed before (compute with max tick to get value stored in sfpm currently)
            // after check if stored value matches this value
            {
                (
                    $accountPremiumGrossBefore0[$activeLegIndex],
                    $accountPremiumGrossBefore1[$activeLegIndex]
                ) = sfpm.getAccountPremium(
                    address(pool),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive,
                    type(int24).max,
                    0 // short to check gross
                );

                // get gross premium
                emit LogUint256(
                    "$accountPremiumGrossBefore0",
                    $accountPremiumGrossBefore0[$activeLegIndex]
                );
                emit LogUint256(
                    "$accountPremiumGrossBefore1",
                    $accountPremiumGrossBefore1[$activeLegIndex]
                );

                // owed premium
                (
                    $accountPremiumOwedBefore0[$activeLegIndex],
                    $accountPremiumOwedBefore1[$activeLegIndex]
                ) = sfpm.getAccountPremium(
                    address(pool),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive,
                    type(int24).max,
                    1 // long to check owed
                );

                // get owed premium
                emit LogUint256(
                    "$accountPremiumOwedBefore0",
                    $accountPremiumOwedBefore0[$activeLegIndex]
                );
                emit LogUint256(
                    "$accountPremiumOwedBefore1",
                    $accountPremiumOwedBefore1[$activeLegIndex]
                );
            }
        }

        // reverse tick order if swap at mint
        int24 tickLimitLow = swapAtMint ? int24(887272) : int24(-887272);
        int24 tickLimitHigh = swapAtMint ? int24(-887272) : int24(887272);

        hevm.prank($activeUser);
        try
            sfpm.mintTokenizedPosition($activeTokenId, positionSize, tickLimitLow, tickLimitHigh)
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalSwapped) {
            emit LogString("mint was successful");

            // copy return into storage
            $sCollectedByLeg = collectedByLeg;
            $sTotalSwapped = totalSwapped;

            // preform post-mint invariant checks per leg
            for (uint i; i < $activeNumLegs; i++) {
                $activeLegIndex = i;

                emit LogUint256("active leg index: ", $activeLegIndex);

                {
                    $tickLowerActive = $sTickLower[$activeLegIndex];
                    $tickUpperActive = $sTickUpper[$activeLegIndex];
                    $LiqAmountActive = $sLiqAmounts[$activeLegIndex];

                    emit LogInt256("$tickLowerActive", $tickLowerActive);
                    emit LogInt256("$tickUpperActive", $tickUpperActive);
                    emit LogUint256("$LiqAmountActive", $LiqAmountActive);
                }

                // check the liquidity deposited within uniswap
                // ** make netting change
                // {
                //     (uniLiquidityAfter[$activeLegIndex], , , , ) = pool.positions(
                //         $positionKey[$activeLegIndex]
                //     );

                //     emit LogUint256("uni liquidity before", uniLiquidityBefore[$activeLegIndex]);
                //     emit LogUint256("$LiqAmountActive", $sLiqAmounts[$activeLegIndex]);
                //     emit LogUint256("uni liquidity after", uniLiquidityAfter[$activeLegIndex]);

                //     // if multiple chunks touch the same leg the account for this difference
                //     // in the final returned amounts
                //     assertWithMsg(
                //         uniLiquidityBefore[$activeLegIndex] + $sLiqAmounts[$activeLegIndex] ==
                //             uniLiquidityAfter[$activeLegIndex],
                //         "invalid uniswap liq"
                //     );
                // }

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
                            $netLiquidityBefore[$activeLegIndex] - $sLiqAmounts[$activeLegIndex],
                        "invalid net liquidity"
                    );

                    // ensure the removed liquidity is incremented
                    assertWithMsg(
                        $removedLiquidityBefore[$activeLegIndex] + $sLiqAmounts[$activeLegIndex] ==
                            $removedLiquidityAfter[$activeLegIndex],
                        "invalid removed liquidity"
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

                    ($newFeesBase0[$activeLegIndex], $newFeesBase1[$activeLegIndex]) = sfpm
                        .getAccountFeesBase(
                            address(pool),
                            $activeUser,
                            $activeTokenId.tokenType($activeLegIndex),
                            $tickLowerActive,
                            $tickUpperActive
                        );

                    emit LogInt256("oldFeesBase0", $oldFeesBase0[$activeLegIndex]);
                    emit LogInt256("oldFeesBase1", $oldFeesBase1[$activeLegIndex]);

                    emit LogInt256("newFeesBase0", $newFeesBase0[$activeLegIndex]);
                    emit LogInt256("newFeesBase1", $newFeesBase1[$activeLegIndex]);

                    emit LogInt256("$newFeesBaseRoundUp0", $newFeesBaseRoundUp0[$activeLegIndex]);
                    emit LogInt256("$newFeesBaseRoundUp1", $newFeesBaseRoundUp1[$activeLegIndex]);

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
                    $amountToCollect0[$activeLegIndex] += int128($amountBurned0[$activeLegIndex]);
                    $amountToCollect1[$activeLegIndex] += int128($amountBurned1[$activeLegIndex]);

                    // ensure amountToCollect is always positive
                    assertWithMsg(
                        $amountToCollect0[$activeLegIndex] >= 0,
                        "amountToCollect0 invalid"
                    );
                    assertWithMsg(
                        $amountToCollect1[$activeLegIndex] >= 0,
                        "amountToCollect1 invalid"
                    );

                    // ensure that the collected amounts never underflow
                    // as the collected amounts are computed in an unchecked block
                    assertWithMsg(
                        $recievedAmount0[$activeLegIndex] >=
                            uint128(int128($amountBurned0[$activeLegIndex])),
                        "collected 0 underflow"
                    );
                    assertWithMsg(
                        $recievedAmount1[$activeLegIndex] >=
                            uint128(int128($amountBurned1[$activeLegIndex])),
                        "collected 1 underflow"
                    );

                    $collected0[$activeLegIndex] =
                        $recievedAmount0[$activeLegIndex] -
                        uint128(int128($amountBurned0[$activeLegIndex]));
                    $collected1[$activeLegIndex] =
                        $recievedAmount1[$activeLegIndex] -
                        uint128(int128($amountBurned1[$activeLegIndex]));

                    emit LogInt256("amountToCollect0", $amountToCollect0[$activeLegIndex]);
                    emit LogInt256("amountToCollect1", $amountToCollect1[$activeLegIndex]);

                    emit LogUint256("receivedAmount0", $recievedAmount0[$activeLegIndex]);
                    emit LogUint256("receivedAmount1", $recievedAmount1[$activeLegIndex]);

                    emit LogInt256("amountBurned0", $amountBurned0[$activeLegIndex]);
                    emit LogInt256("amountBurned1", $amountBurned1[$activeLegIndex]);

                    emit LogUint256("collected0", $collected0[$activeLegIndex]);
                    emit LogUint256("collected1", $collected1[$activeLegIndex]);

                    emit LogUint256(
                        "collectedByLeg token 0",
                        $sCollectedByLeg[$activeLegIndex].rightSlot()
                    );
                    emit LogUint256(
                        "collectedByLeg token 1",
                        $sCollectedByLeg[$activeLegIndex].leftSlot()
                    );

                    assertWithMsg(
                        $collected0[$activeLegIndex] ==
                            $sCollectedByLeg[$activeLegIndex].rightSlot(),
                        "invalid collected 0"
                    );
                    assertWithMsg(
                        $collected1[$activeLegIndex] ==
                            $sCollectedByLeg[$activeLegIndex].leftSlot(),
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

                // check the balance of their ERC1155 id increased by position size
                {
                    // adjust balances and verify
                    _increment_tokenBalance(positionSize);
                    //_check_tokenBalance();
                }
            }

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMLong[msg.sender].push($activeTokenId);

            // reset the activeTokenId for next iteration
            $activeTokenId = TokenId.wrap(uint256(0));
        } catch Error(string memory reason) {
            emit LogString(reason);

            emit LogBool("should revert ?", $shouldRevertSFPM);

            assertWithMsg($shouldRevertSFPM, "non-expected revert");
        }
    }

    /// *** general multiple mints of longs + shorts
    // check for should revert flag and bound so that it is a valid event
    // looks for chunks minted via the panoptic pool
    function mint_option_SFPM_general(
        uint256 numLegs,
        bool[4] memory asset_in,
        bool[4] memory is_call_in,
        bool[4] memory is_long_in,
        bool[4] memory is_otm_in,
        bool[4] memory is_atm_in,
        uint24[4] memory width_in,
        int256[4] memory strike_in,
        uint128 positionSize,
        bool swapAtMint,
        uint8 randSeed
    ) public {
        $shouldRevertSFPM = false;

        // store the current actor
        $activeUser = msg.sender;

        // generate a random number of legs
        $activeNumLegs = bound(numLegs, 1, 4);

        // initialize tokenId
        // ** find matching short chunks for the long legs to increase success rate ??
        $activeTokenId = _generate_multiple_leg_tokenid(
            numLegs,
            asset_in,
            is_call_in,
            is_long_in,
            is_otm_in,
            is_atm_in,
            width_in,
            strike_in
        );

        // if the count of legs is less than 4 then add a chunk minted via the panoptic pool
        if ($activeNumLegs < 4) {
            uint256 totalPPChunks = touchedPanopticChunks.length;

            ChunkWithTokenType memory touchedChunk = touchedPanopticChunks[
                bound(randSeed, 0, touchedPanopticChunks.length - 1)
            ];

            // randomly selected chunk
            $activeTokenId = $activeTokenId.addLeg(
                $activeNumLegs - 1,
                1, // option ratio
                uint256(asset_in[0] ? 1 : 0),
                uint256(is_long_in[0] ? 1 : 0),
                touchedChunk.tokenType,
                $activeNumLegs - 1,
                touchedChunk.strike,
                touchedChunk.width
            );

            // increment active number of legs
            $activeNumLegs++;
        }

        // pre-mint calculations/actions for storage
        for (uint i; i < $activeNumLegs; i++) {
            $activeLegIndex = i;

            emit LogUint256("active leg index: ", $activeLegIndex);

            {
                // get the amount of liquidity being deposited
                $liquidityChunk[$activeLegIndex] = PanopticMath.getLiquidityChunk(
                    $activeTokenId,
                    $activeLegIndex,
                    positionSize
                );

                $sTickLower[$activeLegIndex] = $liquidityChunk[$activeLegIndex].tickLower();
                $sTickUpper[$activeLegIndex] = $liquidityChunk[$activeLegIndex].tickUpper();
                $sLiqAmounts[$activeLegIndex] = $liquidityChunk[$activeLegIndex].liquidity();

                // *** if liquidity amounts is zero then execution should revert ***
                {
                    if ($sLiqAmounts[$activeLegIndex] == 0) $shouldRevertSFPM = true;
                }

                // store the active position details
                {
                    $tickLowerActive = $sTickLower[$activeLegIndex];
                    $tickUpperActive = $sTickUpper[$activeLegIndex];
                    $LiqAmountActive = $sLiqAmounts[$activeLegIndex];
                }

                // emit positional bounds and liquidity
                emit LogInt256("tick lower", $tickLowerActive);
                emit LogInt256("tick upper", $tickUpperActive);
                emit LogUint256("liquidity amounts", $LiqAmountActive);
            }

            // poke if there is pre-existing liq for the user at the positional bounds
            {
                hevm.prank(address(sfpm));
                try pool.burn($tickLowerActive, $tickUpperActive, 0) {} catch {}
            }

            {
                // get the amount of liquidity within that range present in uniswap already
                $positionKey[$activeLegIndex] = keccak256(
                    abi.encodePacked(address(sfpm), $tickLowerActive, $tickUpperActive)
                );
                (uniLiquidityBefore[$activeLegIndex], , , , ) = pool.positions(
                    $positionKey[$activeLegIndex]
                );

                // get SFPM stored account liquidity before
                LeftRightUnsigned accountLiquiditiesBefore = sfpm.getAccountLiquidity(
                    address(pool),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive
                );

                // store the removed and net liquidity for the chunk
                //  before mint
                $removedLiquidityBefore[$activeLegIndex] = accountLiquiditiesBefore.leftSlot();
                $netLiquidityBefore[$activeLegIndex] = accountLiquiditiesBefore.rightSlot();
            }

            {
                // s_accountFeesBase before
                // check s_accountFeesBase is updated correctly
                ($oldFeesBase0[$activeLegIndex], $oldFeesBase1[$activeLegIndex]) = sfpm
                    .getAccountFeesBase(
                        address(pool),
                        $activeUser,
                        $activeTokenId.tokenType($activeLegIndex),
                        $tickLowerActive,
                        $tickUpperActive
                    );

                emit LogInt256("pre-mint feesbase 0", $oldFeesBase0[$activeLegIndex]);
                emit LogInt256("pre-mint feesbase 1", $oldFeesBase1[$activeLegIndex]);
            }

            {
                (
                    ,
                    $feeGrowthInside0LastX128Before[$activeLegIndex],
                    $feeGrowthInside1LastX128Before[$activeLegIndex],
                    ,

                ) = pool.positions(
                    keccak256(abi.encodePacked(address(sfpm), $tickLowerActive, $tickUpperActive))
                );

                // after touch
                emit LogUint256(
                    "pre-mint feeGrowthInside0LastX128",
                    $feeGrowthInside0LastX128Before[$activeLegIndex]
                );
                emit LogUint256(
                    "pre-mint feeGrowthInside1LastX128",
                    $feeGrowthInside1LastX128Before[$activeLegIndex]
                );
            }

            {
                $newFeesBaseRoundDown0[$activeLegIndex] = int128(
                    int256(
                        Math.mulDiv128(
                            $feeGrowthInside0LastX128Before[$activeLegIndex],
                            $netLiquidityBefore[$activeLegIndex]
                        )
                    )
                );
                $newFeesBaseRoundDown1[$activeLegIndex] = int128(
                    int256(
                        Math.mulDiv128(
                            $feeGrowthInside1LastX128Before[$activeLegIndex],
                            $netLiquidityBefore[$activeLegIndex]
                        )
                    )
                );

                emit LogInt256("newFeesBaseRoundDown0", $newFeesBaseRoundDown0[$activeLegIndex]);
                emit LogInt256("newFeesBaseRoundDown1", $newFeesBaseRoundDown1[$activeLegIndex]);

                $amountToCollect0[$activeLegIndex] = int128(
                    Math.max(
                        $newFeesBaseRoundDown0[$activeLegIndex] - $oldFeesBase0[$activeLegIndex],
                        0
                    )
                );
                $amountToCollect1[$activeLegIndex] = int128(
                    Math.max(
                        $newFeesBaseRoundDown1[$activeLegIndex] - $oldFeesBase1[$activeLegIndex],
                        0
                    )
                );

                if ($activeTokenId.isLong($activeLegIndex) == 1) {
                    quote_uni_CollectAndBurn();
                } else {
                    quote_uni_CollectAndMint();
                }
            }

            // get premium gross/owed before (compute with max tick to get value stored in sfpm currently)
            // after check if stored value matches this value
            {
                (
                    $accountPremiumGrossBefore0[$activeLegIndex],
                    $accountPremiumGrossBefore1[$activeLegIndex]
                ) = sfpm.getAccountPremium(
                    address(pool),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive,
                    type(int24).max,
                    0 // short to check gross
                );

                // get gross premium
                emit LogUint256(
                    "$accountPremiumGrossBefore0",
                    $accountPremiumGrossBefore0[$activeLegIndex]
                );
                emit LogUint256(
                    "$accountPremiumGrossBefore1",
                    $accountPremiumGrossBefore1[$activeLegIndex]
                );

                // owed premium
                (
                    $accountPremiumOwedBefore0[$activeLegIndex],
                    $accountPremiumOwedBefore1[$activeLegIndex]
                ) = sfpm.getAccountPremium(
                    address(pool),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive,
                    type(int24).max,
                    1 // long to check owed
                );

                // get owed premium
                emit LogUint256(
                    "$accountPremiumOwedBefore0",
                    $accountPremiumOwedBefore0[$activeLegIndex]
                );
                emit LogUint256(
                    "$accountPremiumOwedBefore1",
                    $accountPremiumOwedBefore1[$activeLegIndex]
                );
            }
        }

        // reverse tick order if swap at mint
        int24 tickLimitLow = swapAtMint ? int24(887272) : int24(-887272);
        int24 tickLimitHigh = swapAtMint ? int24(-887272) : int24(887272);

        hevm.prank($activeUser);
        try
            sfpm.mintTokenizedPosition($activeTokenId, positionSize, tickLimitLow, tickLimitHigh)
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalSwapped) {
            emit LogString("mint was successful");

            assertWithMsg(false, "check x x x xx x x ");

            // copy return into storage
            $sCollectedByLeg = collectedByLeg;
            $sTotalSwapped = totalSwapped;

            // preform post-mint invariant checks per leg
            for (uint i; i < $activeNumLegs; i++) {
                $activeLegIndex = i;

                emit LogUint256("active leg index: ", $activeLegIndex);

                {
                    $tickLowerActive = $sTickLower[$activeLegIndex];
                    $tickUpperActive = $sTickUpper[$activeLegIndex];
                    $LiqAmountActive = $sLiqAmounts[$activeLegIndex];

                    emit LogInt256("$tickLowerActive", $tickLowerActive);
                    emit LogInt256("$tickUpperActive", $tickUpperActive);
                    emit LogUint256("$LiqAmountActive", $LiqAmountActive);
                }

                // check the liquidity deposited within uniswap
                // ** make netting change
                // {
                //     (uniLiquidityAfter[$activeLegIndex], , , , ) = pool.positions(
                //         $positionKey[$activeLegIndex]
                //     );

                //     emit LogUint256("uni liquidity before", uniLiquidityBefore[$activeLegIndex]);
                //     emit LogUint256("$LiqAmountActive", $sLiqAmounts[$activeLegIndex]);
                //     emit LogUint256("uni liquidity after", uniLiquidityAfter[$activeLegIndex]);

                //     // if multiple chunks touch the same leg the account for this difference
                //     // in the final returned amounts
                //     assertWithMsg(
                //         uniLiquidityBefore[$activeLegIndex] + $sLiqAmounts[$activeLegIndex] ==
                //             uniLiquidityAfter[$activeLegIndex],
                //         "invalid uniswap liq"
                //     );
                // }

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

                    if ($activeTokenId.isLong($activeLegIndex) == 1) {
                        // check the liquidity tracked is the same as the liquidity computed
                        assertWithMsg(
                            $netLiquidityAfter[$activeLegIndex] ==
                                $netLiquidityBefore[$activeLegIndex] -
                                    $sLiqAmounts[$activeLegIndex],
                            "invalid net liquidity"
                        );

                        // ensure the removed liquidity is incremented
                        assertWithMsg(
                            $removedLiquidityBefore[$activeLegIndex] +
                                $sLiqAmounts[$activeLegIndex] ==
                                $removedLiquidityAfter[$activeLegIndex],
                            "invalid removed liquidity"
                        );
                    } else {
                        // check the liquidity tracked is the same as the liquidity computed
                        assertWithMsg(
                            $netLiquidityAfter[$activeLegIndex] ==
                                $sLiqAmounts[$activeLegIndex] +
                                    $netLiquidityBefore[$activeLegIndex],
                            "invalid net liquidity"
                        );

                        // ensure the removed liquidity remains the same
                        assertWithMsg(
                            $removedLiquidityBefore[$activeLegIndex] -
                                $sLiqAmounts[$activeLegIndex] ==
                                $removedLiquidityAfter[$activeLegIndex],
                            "invalid removed liquidity"
                        );
                    }
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

                    ($newFeesBase0[$activeLegIndex], $newFeesBase1[$activeLegIndex]) = sfpm
                        .getAccountFeesBase(
                            address(pool),
                            $activeUser,
                            $activeTokenId.tokenType($activeLegIndex),
                            $tickLowerActive,
                            $tickUpperActive
                        );

                    emit LogInt256("oldFeesBase0", $oldFeesBase0[$activeLegIndex]);
                    emit LogInt256("oldFeesBase1", $oldFeesBase1[$activeLegIndex]);

                    emit LogInt256("newFeesBase0", $newFeesBase0[$activeLegIndex]);
                    emit LogInt256("newFeesBase1", $newFeesBase1[$activeLegIndex]);

                    emit LogInt256("$newFeesBaseRoundUp0", $newFeesBaseRoundUp0[$activeLegIndex]);
                    emit LogInt256("$newFeesBaseRoundUp1", $newFeesBaseRoundUp1[$activeLegIndex]);

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
                    if ($activeTokenId.isLong($activeLegIndex) == 1) {
                        $amountToCollect0[$activeLegIndex] += int128(
                            $amountBurned0[$activeLegIndex]
                        );
                        $amountToCollect1[$activeLegIndex] += int128(
                            $amountBurned1[$activeLegIndex]
                        );
                    }

                    // ensure amountToCollect is always positive
                    assertWithMsg(
                        $amountToCollect0[$activeLegIndex] >= 0,
                        "amountToCollect0 invalid"
                    );
                    assertWithMsg(
                        $amountToCollect1[$activeLegIndex] >= 0,
                        "amountToCollect1 invalid"
                    );

                    if ($activeTokenId.isLong($activeLegIndex) == 1) {
                        // ensure that the collected amounts never underflow
                        // as the collected amounts are computed in an unchecked block
                        assertWithMsg(
                            $recievedAmount0[$activeLegIndex] >=
                                uint128(int128($amountBurned0[$activeLegIndex])),
                            "collected 0 underflow"
                        );
                        assertWithMsg(
                            $recievedAmount1[$activeLegIndex] >=
                                uint128(int128($amountBurned1[$activeLegIndex])),
                            "collected 1 underflow"
                        );

                        $collected0[$activeLegIndex] =
                            $recievedAmount0[$activeLegIndex] -
                            uint128(int128($amountBurned0[$activeLegIndex]));
                        $collected1[$activeLegIndex] =
                            $recievedAmount1[$activeLegIndex] -
                            uint128(int128($amountBurned1[$activeLegIndex]));

                        emit LogInt256("amountBurned0", $amountBurned0[$activeLegIndex]);
                        emit LogInt256("amountBurned1", $amountBurned1[$activeLegIndex]);
                    } else {
                        $collected0[$activeLegIndex] = $recievedAmount0[$activeLegIndex];
                        $collected1[$activeLegIndex] = $recievedAmount1[$activeLegIndex];
                    }

                    emit LogInt256("amountToCollect0", $amountToCollect0[$activeLegIndex]);
                    emit LogInt256("amountToCollect1", $amountToCollect1[$activeLegIndex]);

                    emit LogUint256("receivedAmount0", $recievedAmount0[$activeLegIndex]);
                    emit LogUint256("receivedAmount1", $recievedAmount1[$activeLegIndex]);

                    emit LogUint256("collected0", $collected0[$activeLegIndex]);
                    emit LogUint256("collected1", $collected1[$activeLegIndex]);

                    emit LogUint256(
                        "collectedByLeg token 0",
                        $sCollectedByLeg[$activeLegIndex].rightSlot()
                    );
                    emit LogUint256(
                        "collectedByLeg token 1",
                        $sCollectedByLeg[$activeLegIndex].leftSlot()
                    );

                    assertWithMsg(
                        $collected0[$activeLegIndex] ==
                            $sCollectedByLeg[$activeLegIndex].rightSlot(),
                        "invalid collected 0"
                    );
                    assertWithMsg(
                        $collected1[$activeLegIndex] ==
                            $sCollectedByLeg[$activeLegIndex].leftSlot(),
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

                // check the balance of their ERC1155 id increased by position size
                {
                    // adjust balances and verify
                    _increment_tokenBalance(positionSize);
                    //_check_tokenBalance();
                }
            }

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMix[msg.sender].push($activeTokenId);

            // reset the activeTokenId for next iteration
            $activeTokenId = TokenId.wrap(uint256(0));
        } catch Error(string memory reason) {
            emit LogString(reason);

            emit LogBool("should revert ?", $shouldRevertSFPM);

            assertWithMsg($shouldRevertSFPM, "non-expected revert");
        }
    }

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

            // check the balance of their ERC1155 id increased by position size
            {
                // adjust balances and verify
                _increment_tokenBalance(positionSize);
                //_check_tokenBalance();
            }

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

            // check the balance of their ERC1155 id increased by position size
            {
                // adjust balances and verify
                _increment_tokenBalance(positionSize);
                //_check_tokenBalance();
            }

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

            // check the balance of their ERC1155 id increased by position size
            {
                // adjust balances and verify
                _increment_tokenBalance(positionSize);
                //_check_tokenBalance();
            }

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

            // check the balance of their ERC1155 id increased by position size
            {
                // adjust balances and verify
                _increment_tokenBalance(positionSize);
                //_check_tokenBalance();
            }

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

            // check the balance of their ERC1155 id increased by position size
            {
                // adjust balances and verify
                _increment_tokenBalance(positionSize);
                //_check_tokenBalance();
            }

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

    /// burn

    function burn_option_SFPM_general(
        uint256 numLegs,
        uint128 positionSize,
        bool swapAtMint,
        bool isLong,
        bool isMix,
        uint256 randSeed
    ) public {
        $shouldRevertSFPM = false;

        // store the current actor
        $activeUser = msg.sender;

        // grab a random tokenId owned by the current interactor ***
        if (isMix && userPositionsSFPMix[$activeUser].length != 0) {
            // burn mix
            uint256 randIndex = bound(randSeed, 0, userPositionsSFPMix[$activeUser].length - 1);
            $activeTokenId = userPositionsSFPMix[$activeUser][randIndex];

            // delete from owner
            userPositionsSFPMix[$activeUser][randIndex] = TokenId.wrap(0);
        } else if (isLong && userPositionsSFPMLong[$activeUser].length != 0) {
            // burn a long
            uint256 randIndex = bound(randSeed, 0, userPositionsSFPMLong[$activeUser].length - 1);
            $activeTokenId = userPositionsSFPMLong[$activeUser][randIndex];

            // delete from owner
            userPositionsSFPMLong[$activeUser][randIndex] = TokenId.wrap(0);
        } else {
            if (userPositionsSFPMShort[$activeUser].length == 0) {
                revert();
            }

            // burn a short
            uint256 randIndex = bound(randSeed, 0, userPositionsSFPMShort[$activeUser].length - 1);
            $activeTokenId = userPositionsSFPMShort[$activeUser][randIndex];

            // delete from owner
            userPositionsSFPMShort[$activeUser][randIndex] = TokenId.wrap(0);
        }

        // pre-mint calculations/actions for storage
        for (uint i = $activeNumLegs; i > 0; i--) {
            $activeLegIndex = i;

            emit LogUint256("active leg index: ", $activeLegIndex);

            {
                // get the amount of liquidity being deposited
                $liquidityChunk[$activeLegIndex] = PanopticMath.getLiquidityChunk(
                    $activeTokenId,
                    $activeLegIndex,
                    positionSize
                );

                $sTickLower[$activeLegIndex] = $liquidityChunk[$activeLegIndex].tickLower();
                $sTickUpper[$activeLegIndex] = $liquidityChunk[$activeLegIndex].tickUpper();
                $sLiqAmounts[$activeLegIndex] = $liquidityChunk[$activeLegIndex].liquidity();

                // *** if liquidity amounts is zero then execution should revert ***
                {
                    if ($sLiqAmounts[$activeLegIndex] == 0) $shouldRevertSFPM = true;
                }

                // store the active position details
                {
                    $tickLowerActive = $sTickLower[$activeLegIndex];
                    $tickUpperActive = $sTickUpper[$activeLegIndex];
                    $LiqAmountActive = $sLiqAmounts[$activeLegIndex];
                }

                // emit positional bounds and liquidity
                emit LogInt256("tick lower", $tickLowerActive);
                emit LogInt256("tick upper", $tickUpperActive);
                emit LogUint256("liquidity amounts", $LiqAmountActive);
            }

            // poke if there is pre-existing liq for the user at the positional bounds
            {
                hevm.prank(address(sfpm));
                try pool.burn($tickLowerActive, $tickUpperActive, 0) {} catch {}
            }

            {
                // get the amount of liquidity within that range present in uniswap already
                $positionKey[$activeLegIndex] = keccak256(
                    abi.encodePacked(address(sfpm), $tickLowerActive, $tickUpperActive)
                );
                (uniLiquidityBefore[$activeLegIndex], , , , ) = pool.positions(
                    $positionKey[$activeLegIndex]
                );

                // get SFPM stored account liquidity before
                LeftRightUnsigned accountLiquiditiesBefore = sfpm.getAccountLiquidity(
                    address(pool),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive
                );

                // store the removed and net liquidity for the chunk
                //  before mint
                $removedLiquidityBefore[$activeLegIndex] = accountLiquiditiesBefore.leftSlot();
                $netLiquidityBefore[$activeLegIndex] = accountLiquiditiesBefore.rightSlot();
            }

            {
                // s_accountFeesBase before
                // check s_accountFeesBase is updated correctly
                ($oldFeesBase0[$activeLegIndex], $oldFeesBase1[$activeLegIndex]) = sfpm
                    .getAccountFeesBase(
                        address(pool),
                        $activeUser,
                        $activeTokenId.tokenType($activeLegIndex),
                        $tickLowerActive,
                        $tickUpperActive
                    );

                emit LogInt256("pre-mint feesbase 0", $oldFeesBase0[$activeLegIndex]);
                emit LogInt256("pre-mint feesbase 1", $oldFeesBase1[$activeLegIndex]);
            }

            {
                (
                    ,
                    $feeGrowthInside0LastX128Before[$activeLegIndex],
                    $feeGrowthInside1LastX128Before[$activeLegIndex],
                    ,

                ) = pool.positions(
                    keccak256(abi.encodePacked(address(sfpm), $tickLowerActive, $tickUpperActive))
                );

                // after touch
                emit LogUint256(
                    "pre-mint feeGrowthInside0LastX128",
                    $feeGrowthInside0LastX128Before[$activeLegIndex]
                );
                emit LogUint256(
                    "pre-mint feeGrowthInside1LastX128",
                    $feeGrowthInside1LastX128Before[$activeLegIndex]
                );
            }

            {
                $newFeesBaseRoundDown0[$activeLegIndex] = int128(
                    int256(
                        Math.mulDiv128(
                            $feeGrowthInside0LastX128Before[$activeLegIndex],
                            $netLiquidityBefore[$activeLegIndex]
                        )
                    )
                );
                $newFeesBaseRoundDown1[$activeLegIndex] = int128(
                    int256(
                        Math.mulDiv128(
                            $feeGrowthInside1LastX128Before[$activeLegIndex],
                            $netLiquidityBefore[$activeLegIndex]
                        )
                    )
                );

                emit LogInt256("newFeesBaseRoundDown0", $newFeesBaseRoundDown0[$activeLegIndex]);
                emit LogInt256("newFeesBaseRoundDown1", $newFeesBaseRoundDown1[$activeLegIndex]);

                //
                $amountToCollect0[$activeLegIndex] = int128(
                    Math.max(
                        $newFeesBaseRoundDown0[$activeLegIndex] - $oldFeesBase0[$activeLegIndex],
                        0
                    )
                );
                $amountToCollect1[$activeLegIndex] = int128(
                    Math.max(
                        $newFeesBaseRoundDown1[$activeLegIndex] - $oldFeesBase1[$activeLegIndex],
                        0
                    )
                );

                if ($activeTokenId.isLong($activeLegIndex) == 0) {
                    quote_uni_CollectAndBurn();
                } else {
                    quote_uni_CollectAndMint();
                }
            }

            // get premium gross/owed before (compute with max tick to get value stored in sfpm currently)
            // after check if stored value matches this value
            {
                (
                    $accountPremiumGrossBefore0[$activeLegIndex],
                    $accountPremiumGrossBefore1[$activeLegIndex]
                ) = sfpm.getAccountPremium(
                    address(pool),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive,
                    type(int24).max,
                    0 // short to check gross
                );

                // get gross premium
                emit LogUint256(
                    "$accountPremiumGrossBefore0",
                    $accountPremiumGrossBefore0[$activeLegIndex]
                );
                emit LogUint256(
                    "$accountPremiumGrossBefore1",
                    $accountPremiumGrossBefore1[$activeLegIndex]
                );

                // owed premium
                (
                    $accountPremiumOwedBefore0[$activeLegIndex],
                    $accountPremiumOwedBefore1[$activeLegIndex]
                ) = sfpm.getAccountPremium(
                    address(pool),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $tickLowerActive,
                    $tickUpperActive,
                    type(int24).max,
                    1 // long to check owed
                );

                // get owed premium
                emit LogUint256(
                    "$accountPremiumOwedBefore0",
                    $accountPremiumOwedBefore0[$activeLegIndex]
                );
                emit LogUint256(
                    "$accountPremiumOwedBefore1",
                    $accountPremiumOwedBefore1[$activeLegIndex]
                );
            }
        }

        // reverse tick order if swap at mint
        int24 tickLimitLow = swapAtMint ? int24(887272) : int24(-887272);
        int24 tickLimitHigh = swapAtMint ? int24(-887272) : int24(887272);

        hevm.prank($activeUser);
        try
            sfpm.burnTokenizedPosition($activeTokenId, positionSize, tickLimitLow, tickLimitHigh)
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalSwapped) {
            emit LogString("burn was successful");

            // copy return into storage
            $sCollectedByLeg = collectedByLeg;
            $sTotalSwapped = totalSwapped;

            // preform post-mint invariant checks per leg
            for (uint i = $activeNumLegs; i > 0; i--) {
                $activeLegIndex = i;

                emit LogUint256("active leg index: ", $activeLegIndex);

                {
                    $tickLowerActive = $sTickLower[$activeLegIndex];
                    $tickUpperActive = $sTickUpper[$activeLegIndex];
                    $LiqAmountActive = $sLiqAmounts[$activeLegIndex];

                    emit LogInt256("$tickLowerActive", $tickLowerActive);
                    emit LogInt256("$tickUpperActive", $tickUpperActive);
                    emit LogUint256("$LiqAmountActive", $LiqAmountActive);
                }

                // check the liquidity deposited within uniswap
                // ** make netting change
                // {
                //     (uniLiquidityAfter[$activeLegIndex], , , , ) = pool.positions(
                //         $positionKey[$activeLegIndex]
                //     );

                //     emit LogUint256("uni liquidity before", uniLiquidityBefore[$activeLegIndex]);
                //     emit LogUint256("$LiqAmountActive", $sLiqAmounts[$activeLegIndex]);
                //     emit LogUint256("uni liquidity after", uniLiquidityAfter[$activeLegIndex]);

                //     // if multiple chunks touch the same leg the account for this difference
                //     // in the final returned amounts
                //     assertWithMsg(
                //         uniLiquidityBefore[$activeLegIndex] + $sLiqAmounts[$activeLegIndex] ==
                //             uniLiquidityAfter[$activeLegIndex],
                //         "invalid uniswap liq"
                //     );
                // }

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

                    if ($activeTokenId.isLong($activeLegIndex) == 0) {
                        // check the liquidity tracked is the same as the liquidity computed
                        assertWithMsg(
                            $netLiquidityAfter[$activeLegIndex] ==
                                $netLiquidityBefore[$activeLegIndex] -
                                    $sLiqAmounts[$activeLegIndex],
                            "invalid net liquidity"
                        );

                        // ensure the removed liquidity is incremented
                        assertWithMsg(
                            $removedLiquidityBefore[$activeLegIndex] ==
                                $removedLiquidityAfter[$activeLegIndex],
                            "invalid removed liquidity"
                        );
                    } else {
                        // check the liquidity tracked is the same as the liquidity computed
                        assertWithMsg(
                            $netLiquidityAfter[$activeLegIndex] ==
                                $sLiqAmounts[$activeLegIndex] +
                                    $netLiquidityBefore[$activeLegIndex],
                            "invalid net liquidity"
                        );

                        // ensure the removed liquidity remains the same
                        assertWithMsg(
                            $removedLiquidityBefore[$activeLegIndex] -
                                $sLiqAmounts[$activeLegIndex] ==
                                $removedLiquidityAfter[$activeLegIndex],
                            "invalid removed liquidity"
                        );
                    }
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

                    ($newFeesBase0[$activeLegIndex], $newFeesBase1[$activeLegIndex]) = sfpm
                        .getAccountFeesBase(
                            address(pool),
                            $activeUser,
                            $activeTokenId.tokenType($activeLegIndex),
                            $tickLowerActive,
                            $tickUpperActive
                        );

                    emit LogInt256("oldFeesBase0", $oldFeesBase0[$activeLegIndex]);
                    emit LogInt256("oldFeesBase1", $oldFeesBase1[$activeLegIndex]);

                    emit LogInt256("newFeesBase0", $newFeesBase0[$activeLegIndex]);
                    emit LogInt256("newFeesBase1", $newFeesBase1[$activeLegIndex]);

                    emit LogInt256("$newFeesBaseRoundUp0", $newFeesBaseRoundUp0[$activeLegIndex]);
                    emit LogInt256("$newFeesBaseRoundUp1", $newFeesBaseRoundUp1[$activeLegIndex]);

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
                    if ($activeTokenId.isLong($activeLegIndex) == 0) {
                        $amountToCollect0[$activeLegIndex] += int128(
                            $amountBurned0[$activeLegIndex]
                        );
                        $amountToCollect1[$activeLegIndex] += int128(
                            $amountBurned1[$activeLegIndex]
                        );
                    }

                    // ensure amountToCollect is always positive
                    assertWithMsg(
                        $amountToCollect0[$activeLegIndex] >= 0,
                        "amountToCollect0 invalid"
                    );
                    assertWithMsg(
                        $amountToCollect1[$activeLegIndex] >= 0,
                        "amountToCollect1 invalid"
                    );

                    if ($activeTokenId.isLong($activeLegIndex) == 0) {
                        // ensure that the collected amounts never underflow
                        // as the collected amounts are computed in an unchecked block
                        assertWithMsg(
                            $recievedAmount0[$activeLegIndex] >=
                                uint128(int128($amountBurned0[$activeLegIndex])),
                            "collected 0 underflow"
                        );
                        assertWithMsg(
                            $recievedAmount1[$activeLegIndex] >=
                                uint128(int128($amountBurned1[$activeLegIndex])),
                            "collected 1 underflow"
                        );

                        $collected0[$activeLegIndex] =
                            $recievedAmount0[$activeLegIndex] -
                            uint128(int128($amountBurned0[$activeLegIndex]));
                        $collected1[$activeLegIndex] =
                            $recievedAmount1[$activeLegIndex] -
                            uint128(int128($amountBurned1[$activeLegIndex]));

                        emit LogInt256("amountBurned0", $amountBurned0[$activeLegIndex]);
                        emit LogInt256("amountBurned1", $amountBurned1[$activeLegIndex]);
                    } else {
                        $collected0[$activeLegIndex] = $recievedAmount0[$activeLegIndex];
                        $collected1[$activeLegIndex] = $recievedAmount1[$activeLegIndex];
                    }

                    emit LogInt256("amountToCollect0", $amountToCollect0[$activeLegIndex]);
                    emit LogInt256("amountToCollect1", $amountToCollect1[$activeLegIndex]);

                    emit LogUint256("receivedAmount0", $recievedAmount0[$activeLegIndex]);
                    emit LogUint256("receivedAmount1", $recievedAmount1[$activeLegIndex]);

                    emit LogUint256("collected0", $collected0[$activeLegIndex]);
                    emit LogUint256("collected1", $collected1[$activeLegIndex]);

                    emit LogUint256(
                        "collectedByLeg token 0",
                        $sCollectedByLeg[$activeLegIndex].rightSlot()
                    );
                    emit LogUint256(
                        "collectedByLeg token 1",
                        $sCollectedByLeg[$activeLegIndex].leftSlot()
                    );

                    assertWithMsg(
                        $collected0[$activeLegIndex] ==
                            $sCollectedByLeg[$activeLegIndex].rightSlot(),
                        "invalid collected 0"
                    );
                    assertWithMsg(
                        $collected1[$activeLegIndex] ==
                            $sCollectedByLeg[$activeLegIndex].leftSlot(),
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

                {
                    // adjust balances and verify
                    _decrement_tokenBalance(positionSize);
                    //_check_tokenBalance();
                }
            }

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMix[msg.sender].push($activeTokenId);

            // reset the activeTokenId for next iteration
            $activeTokenId = TokenId.wrap(uint256(0));
        } catch Error(string memory reason) {
            emit LogString(reason);

            emit LogBool("should revert ?", $shouldRevertSFPM);

            assertWithMsg($shouldRevertSFPM, "non-expected revert");
        }
    }

    // transfer

    function transfer_tokenId(
        uint256 positionSize,
        address randUser,
        bool transferToPP, // transfer to panoptic pool flag
        bool isLong,
        bool isMix,
        uint256 randSeed,
        bytes calldata data
    ) public {
        $shouldRevertSFPM = false;

        $activeUser = msg.sender;

        if (transferToPP) {
            randUser = address(panopticPool);
        }

        // grab a random tokenId owned by the current interactor ***
        if (isMix && userPositionsSFPMix[$activeUser].length != 0) {
            // burn mix
            uint256 randIndex = bound(randSeed, 0, userPositionsSFPMix[$activeUser].length - 1);
            $activeTokenId = userPositionsSFPMix[$activeUser][randIndex];

            // delete from owner and give to recipient
            userPositionsSFPMix[$activeUser][randIndex] = TokenId.wrap(0);
            userPositionsSFPMix[randUser].push($activeTokenId);
        } else if (isLong && userPositionsSFPMLong[$activeUser].length != 0) {
            // burn a long
            uint256 randIndex = bound(randSeed, 0, userPositionsSFPMLong[$activeUser].length - 1);
            $activeTokenId = userPositionsSFPMLong[$activeUser][randIndex];

            // delete from owner and give to recipient
            userPositionsSFPMLong[$activeUser][randIndex] = TokenId.wrap(0);
            userPositionsSFPMLong[randUser].push($activeTokenId);
        } else {
            if (userPositionsSFPMShort[$activeUser].length == 0) {
                revert();
            }

            // burn a short
            uint256 randIndex = bound(randSeed, 0, userPositionsSFPMShort[$activeUser].length - 1);
            $activeTokenId = userPositionsSFPMShort[$activeUser][randIndex];

            // delete from owner and give to recipient
            userPositionsSFPMShort[$activeUser][randIndex] = TokenId.wrap(0);
            userPositionsSFPMShort[randUser].push($activeTokenId);
        }

        // check internal balance of that tokenId
        tokenBalanceSenderBefore = sfpm.balanceOf($activeUser, TokenId.unwrap($activeTokenId));
        tokenBalanceRecipientBefore = sfpm.balanceOf(randUser, TokenId.unwrap($activeTokenId));

        $activeNumLegs = $activeTokenId.countLegs();
        for (uint256 i = 0; i < $activeNumLegs; i++) {
            $activeLegIndex = i;

            // the chunk being transferred
            $liquidityChunk[$activeLegIndex] = PanopticMath.getLiquidityChunk(
                $activeTokenId,
                $activeLegIndex,
                uint128(positionSize)
            );

            {
                // construct the positionKey for the from and to addresses
                positionKey_from[$activeLegIndex] = keccak256(
                    abi.encodePacked(
                        address(pool),
                        $activeUser,
                        $activeTokenId.tokenType($activeLegIndex),
                        $liquidityChunk[$activeLegIndex].tickLower(),
                        $liquidityChunk[$activeLegIndex].tickUpper()
                    )
                );
                positionKey_to[$activeLegIndex] = keccak256(
                    abi.encodePacked(
                        address(pool),
                        randUser,
                        $activeTokenId.tokenType($activeLegIndex),
                        $liquidityChunk[$activeLegIndex].tickLower(),
                        $liquidityChunk[$activeLegIndex].tickUpper()
                    )
                );
            }

            {
                // store feesbase before sender
                (
                    $senderFeesBaseBefore0[$activeLegIndex],
                    $senderFeesBaseBefore1[$activeLegIndex]
                ) = sfpm.getAccountFeesBase(
                    address(pool),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $liquidityChunk[$activeLegIndex].tickLower(),
                    $liquidityChunk[$activeLegIndex].tickUpper()
                );

                // store feesbase before receiver (should be 0)
                (
                    $recipientFeesBaseBefore0[$activeLegIndex],
                    $recipientFeesBaseBefore1[$activeLegIndex]
                ) = sfpm.getAccountFeesBase(
                    address(pool),
                    randUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $liquidityChunk[$activeLegIndex].tickLower(),
                    $liquidityChunk[$activeLegIndex].tickUpper()
                );
            }

            {
                // store account liquidity before sender (should not be 0 ~)
                accountLiquiditiesSenderBefore[$activeLegIndex] = sfpm.getAccountLiquidity(
                    address(pool),
                    $activeUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $liquidityChunk[$activeLegIndex].tickLower(),
                    $liquidityChunk[$activeLegIndex].tickUpper()
                );

                // store account liquidity before recipient (should be 0 ~)
                accountLiquiditiesRecipientBefore[$activeLegIndex] = sfpm.getAccountLiquidity(
                    address(pool),
                    randUser,
                    $activeTokenId.tokenType($activeLegIndex),
                    $liquidityChunk[$activeLegIndex].tickLower(),
                    $liquidityChunk[$activeLegIndex].tickUpper()
                );
            }

            // if not sending the entre liq amount or transferring long
            if (
                ($liquidityChunk[$activeLegIndex].liquidity() !=
                    LeftRightUnsigned.unwrap(accountLiquiditiesSenderBefore[$activeLegIndex])) ||
                (LeftRightUnsigned.unwrap(accountLiquiditiesRecipientBefore[$activeLegIndex]) != 0)
            ) {
                $shouldRevertSFPM = true;
            }
        }

        try
            sfpm.safeTransferFrom(
                $activeUser,
                randUser,
                TokenId.unwrap($activeTokenId),
                positionSize,
                data
            )
        {
            for (uint256 i = 0; i < $activeNumLegs; i++) {
                $activeLegIndex = i;

                {
                    // store feesbase before sender
                    (
                        $senderFeesBaseAfter0[$activeLegIndex],
                        $senderFeesBaseAfter1[$activeLegIndex]
                    ) = sfpm.getAccountFeesBase(
                        address(pool),
                        $activeUser,
                        $activeTokenId.tokenType($activeLegIndex),
                        $liquidityChunk[$activeLegIndex].tickLower(),
                        $liquidityChunk[$activeLegIndex].tickUpper()
                    );

                    // store feesbase before receiver (should be 0)
                    (
                        $recipientFeesBaseAfter0[$activeLegIndex],
                        $recipientFeesBaseAfter1[$activeLegIndex]
                    ) = sfpm.getAccountFeesBase(
                        address(pool),
                        randUser,
                        $activeTokenId.tokenType($activeLegIndex),
                        $liquidityChunk[$activeLegIndex].tickLower(),
                        $liquidityChunk[$activeLegIndex].tickUpper()
                    );
                }

                {
                    // store account liquidity before sender (should not be 0 ~)
                    accountLiquiditiesSenderAfter[$activeLegIndex] = sfpm.getAccountLiquidity(
                        address(pool),
                        $activeUser,
                        $activeTokenId.tokenType($activeLegIndex),
                        $liquidityChunk[$activeLegIndex].tickLower(),
                        $liquidityChunk[$activeLegIndex].tickUpper()
                    );

                    // store account liquidity before recipient (should be 0 ~)
                    accountLiquiditiesRecipientAfter[$activeLegIndex] = sfpm.getAccountLiquidity(
                        address(pool),
                        randUser,
                        $activeTokenId.tokenType($activeLegIndex),
                        $liquidityChunk[$activeLegIndex].tickLower(),
                        $liquidityChunk[$activeLegIndex].tickUpper()
                    );
                }

                /// checks
                {
                    // check feesbase after sender == 0
                    assertWithMsg(
                        $senderFeesBaseAfter0[$activeLegIndex] == 0,
                        "non zero fees base 0 of sender"
                    );
                    assertWithMsg(
                        $senderFeesBaseAfter1[$activeLegIndex] == 0,
                        "non zero fees base 1 of sender"
                    );

                    // check feesbase after receiver (should be  = from feesbase)
                    assertWithMsg(
                        $recipientFeesBaseAfter0[$activeLegIndex] ==
                            $senderFeesBaseBefore0[$activeLegIndex],
                        "non zero fees base 0 of sender"
                    );
                    assertWithMsg(
                        $recipientFeesBaseAfter1[$activeLegIndex] ==
                            $senderFeesBaseBefore1[$activeLegIndex],
                        "non zero fees base 1 of sender"
                    );

                    // check acc liq sender = 0
                    assertWithMsg(
                        LeftRightUnsigned.unwrap(accountLiquiditiesSenderAfter[$activeLegIndex]) ==
                            0,
                        "invalid sender liquidity"
                    );

                    // check acc liq receiver = acc liq sender
                    assertWithMsg(
                        LeftRightUnsigned.unwrap(
                            accountLiquiditiesRecipientAfter[$activeLegIndex]
                        ) ==
                            LeftRightUnsigned.unwrap(
                                accountLiquiditiesSenderBefore[$activeLegIndex]
                            ),
                        "invalid recipient liquidity"
                    );
                }

                {
                    // delete and update record of token ownership
                    tokenBalances[$activeTokenId][randUser] += positionSize;
                    tokenBalances[$activeTokenId][$activeUser] -= positionSize;

                    assertWithMsg(
                        tokenBalances[$activeTokenId][randUser] ==
                            tokenBalances[$activeTokenId][randUser],
                        "invalid tracked erc1155 balance recipient"
                    );
                    assertWithMsg(
                        tokenBalances[$activeTokenId][$activeUser] ==
                            tokenBalances[$activeTokenId][$activeUser],
                        "invalid tracked erc1155 balance sender"
                    );
                }
            }

            assertWithMsg(false, "success");

            // inverse
            assertWithMsg(!$shouldRevertSFPM, "should have reverted");

            // transfer should fail if trying to transfer bal > before bal
        } catch Error(string memory reason) {
            emit LogString(reason);

            emit LogBool("should revert ?", $shouldRevertSFPM);

            assertWithMsg($shouldRevertSFPM, "non-expected revert");
        }
    }

    // transferFrom with insufficient approval
    // safeTransferFrom
    // batchTransferFrom
}
