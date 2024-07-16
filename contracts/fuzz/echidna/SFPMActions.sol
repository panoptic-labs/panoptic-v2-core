// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "./FuzzHelpers.sol";
import {GeneralActions} from "./GeneralActions.sol";

contract SFPMActions is GeneralActions {
    /// SFPM direct interactions

    ////////////////////////////////////////////////////
    // Mint
    ////////////////////////////////////////////////////

    // mint option sfpm standard mint (store this position in mapping)
    // ** add moved amts check
    function mint_option_SFPM_singleShort(
        bool asset,
        bool is_call,
        bool is_otm,
        bool is_atm,
        uint24 width,
        int256 strike,
        uint128 positionSize
    ) public {
        // store the current actor
        $activeUser = msg.sender;

        tokenIdShort = _generate_single_leg_tokenid(
            asset,
            is_call,
            false,
            is_otm,
            is_atm,
            width,
            strike
        );

        // get the amount of liquidity being deposited
        liquidityChunk = PanopticMath.getLiquidityChunk(tokenIdShort, 0, positionSize);

        // simulate the mint and get the actual moved amounts
        $tickLowerActive = liquidityChunk.tickLower();
        $tickUpperActive = liquidityChunk.tickUpper();
        $LiqAmountActive = liquidityChunk.liquidity();

        ($posLiquidity, , , , ) = pool.positions(
            keccak256(
                abi.encodePacked(
                    address(sfpm),
                    liquidityChunk.tickLower(),
                    liquidityChunk.tickUpper()
                )
            )
        );

        // poke uniswap pool to update tokens owed - needed because swap happens after mint
        // only burn if there is pre-existing liquidity at this chunk
        if ($posLiquidity != 0) {
            hevm.prank(address(sfpm));
            pool.burn($tickLowerActive, $tickUpperActive, 0);
        }

        // get the amount of liquidity within that range present in uniswap already
        bytes32 positionKey = keccak256(
            abi.encodePacked(address(sfpm), liquidityChunk.tickLower(), liquidityChunk.tickUpper())
        );

        (uint128 liquidityBefore, , , , ) = pool.positions(positionKey);

        LeftRightUnsigned accountLiquiditiesBefore = sfpm.getAccountLiquidity(
            address(pool),
            msg.sender,
            tokenIdShort.tokenType(0),
            liquidityChunk.tickLower(),
            liquidityChunk.tickUpper()
        );

        removedLiquidityBefore = accountLiquiditiesBefore.leftSlot();
        netLiquidityBefore = accountLiquiditiesBefore.rightSlot();

        emit LogInt256("liquidityChunk.tickLower()", liquidityChunk.tickLower());
        emit LogInt256("liquidityChunk.tickUpper()", liquidityChunk.tickUpper());

        // s_accountFeesBase before
        // check s_accountFeesBase is updated correctly
        (oldFeesBase0, oldFeesBase1) = sfpm.getAccountFeesBase(
            address(pool),
            msg.sender,
            tokenIdShort.tokenType(0),
            liquidityChunk.tickLower(),
            liquidityChunk.tickUpper()
        );

        (, $feeGrowthInside0LastX128Before, $feeGrowthInside1LastX128Before, , ) = pool.positions(
            keccak256(
                abi.encodePacked(
                    address(sfpm),
                    liquidityChunk.tickLower(),
                    liquidityChunk.tickUpper()
                )
            )
        );

        emit LogUint256("feeGrowthInside0LastX128Before before", $feeGrowthInside0LastX128Before);
        emit LogUint256("feeGrowthInside1LastX128Before before", $feeGrowthInside1LastX128Before);

        {
            //
            int128 newFeesBaseRoundDown0 = int128(
                int256(Math.mulDiv128($feeGrowthInside0LastX128Before, netLiquidityBefore))
            );
            int128 newFeesBaseRoundDown1 = int128(
                int256(Math.mulDiv128($feeGrowthInside1LastX128Before, netLiquidityBefore))
            );

            emit LogInt256("newFeesBaseRoundDown0", newFeesBaseRoundDown0);
            emit LogInt256("newFeesBaseRoundDown1", newFeesBaseRoundDown1);

            emit LogInt256("newFeesBaseRoundDown0", newFeesBaseRoundDown0);
            emit LogInt256("newFeesBaseRoundDown1", newFeesBaseRoundDown1);

            //
            $amountToCollect0 = int128(Math.max(newFeesBaseRoundDown0 - oldFeesBase0, 0));
            $amountToCollect1 = int128(Math.max(newFeesBaseRoundDown1 - oldFeesBase1, 0));

            // get the minted amounts (true moved amounts)
            // also get the true collected amounts
            // @note if the shouldRevert flag is tipped then end execution herwe
            quote_uni_CollectAndMint();
        }

        // get premium gross/owed before (compute with max tick to get value stored in sfpm currently)
        // after check if stored value matches this value
        {
            ($accountPremiumGrossBefore0, $accountPremiumGrossBefore1) = sfpm.getAccountPremium(
                address(pool),
                $activeUser,
                tokenIdShort.tokenType(0),
                liquidityChunk.tickLower(),
                liquidityChunk.tickUpper(),
                type(int24).max,
                0 // short to check gross
            );

            // get gross premium
            emit LogUint256("$accountPremiumGrossBefore0", $accountPremiumGrossBefore0);
            emit LogUint256("$accountPremiumGrossBefore1", $accountPremiumGrossBefore1);
        }

        {
            // owed premium
            ($accountPremiumOwedBefore0, $accountPremiumOwedBefore1) = sfpm.getAccountPremium(
                address(pool),
                $activeUser,
                tokenIdShort.tokenType(0),
                liquidityChunk.tickLower(),
                liquidityChunk.tickUpper(),
                type(int24).max,
                1 // long to check owed
            );

            // get owed premium
            emit LogUint256("$accountPremiumOwedBefore0", $accountPremiumOwedBefore0);
            emit LogUint256("$accountPremiumOwedBefore1", $accountPremiumOwedBefore1);
        }

        {
            emit LogAddress("test interactor", $activeUser);
            emit LogInt256("passed tickLower", liquidityChunk.tickLower());
            emit LogInt256("passed tickUpper", liquidityChunk.tickUpper());
        }

        hevm.prank($activeUser);
        try
            sfpm.mintTokenizedPosition(tokenIdShort, positionSize, int24(-887272), int24(887272))
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalSwapped) {
            // copy return into storage
            $collectedByLeg = collectedByLeg;
            $totalSwapped = totalSwapped;

            // check the net liquidity added
            {
                LeftRightUnsigned accountLiquiditiesAfter = sfpm.getAccountLiquidity(
                    address(pool),
                    $activeUser,
                    tokenIdShort.tokenType(0),
                    liquidityChunk.tickLower(),
                    liquidityChunk.tickUpper()
                );

                removedLiquidityAfter = accountLiquiditiesAfter.leftSlot();
                netLiquidityAfter = accountLiquiditiesAfter.rightSlot();

                emit LogUint256("removedLiquidityBefore", removedLiquidityBefore);
                emit LogUint256("netLiquidityBefore", netLiquidityBefore);

                emit LogUint256("removedLiquidityAfter", removedLiquidityAfter);
                emit LogUint256("netLiquidityAfter", netLiquidityAfter);

                // check the liquidity tracked is the same as the liquidity computed
                assertWithMsg(
                    netLiquidityAfter == $LiqAmountActive + netLiquidityBefore,
                    "invalid net liquidity"
                );

                // ensure the removed liquidity remains the same
                assertWithMsg(
                    removedLiquidityBefore == removedLiquidityAfter,
                    "invalid removed liquidity"
                );
            }

            // check the liquidity deposited within uniswap
            {
                (uint128 liquidityDeployed, , , , ) = pool.positions(positionKey);

                emit LogUint256("liquidityBefore", liquidityBefore);
                emit LogUint256("$LiqAmountActive", $LiqAmountActive);
                emit LogUint256("liquidityDeployed", liquidityDeployed);

                assertWithMsg(
                    liquidityBefore + $LiqAmountActive == liquidityDeployed,
                    "invalid uniswap liq"
                );
            }

            // check stored fees base for this position
            {
                (, $feeGrowthInside0LastX128After, $feeGrowthInside1LastX128After, , ) = pool
                    .positions(
                        keccak256(
                            abi.encodePacked(
                                address(sfpm),
                                liquidityChunk.tickLower(),
                                liquidityChunk.tickUpper()
                            )
                        )
                    );

                emit LogUint256("feeGrowthInside0LastX128After", $feeGrowthInside0LastX128After);
                emit LogUint256("feeGrowthInside1LastX128After", $feeGrowthInside1LastX128After);

                // new fees base
                int128 newFeesBase0 = int128(
                    int256(
                        Math.mulDiv128RoundingUp($feeGrowthInside0LastX128After, netLiquidityAfter)
                    )
                );
                int128 newFeesBase1 = int128(
                    int256(
                        Math.mulDiv128RoundingUp($feeGrowthInside1LastX128After, netLiquidityAfter)
                    )
                );

                // check newly stored feesBase

                (int128 feesBase0, int128 feesBase1) = sfpm.getAccountFeesBase(
                    address(pool),
                    msg.sender,
                    tokenIdShort.tokenType(0),
                    liquidityChunk.tickLower(),
                    liquidityChunk.tickUpper()
                );

                emit LogInt256("oldFeesBase0", oldFeesBase0);
                emit LogInt256("oldFeesBase1", oldFeesBase1);

                emit LogInt256("newFeesBase0", newFeesBase0);
                emit LogInt256("newFeesBase1", newFeesBase1);

                emit LogInt256("feesBase0", feesBase0);
                emit LogInt256("feesBase1", feesBase1);

                assertWithMsg(newFeesBase0 == feesBase0, "invalid fees base 0");
                assertWithMsg(newFeesBase1 == feesBase1, "invalid fees base 1");
            }

            /// compute and verify the amounts to collect
            /// collected the amounts using starting liquidity
            {
                // ensure amountToCollect is always positive
                assertWithMsg($amountToCollect0 >= 0, "amountToCollect0 invalid");
                assertWithMsg($amountToCollect1 >= 0, "amountToCollect1 invalid");

                $collected0 = $amountMinted0 < 0
                    ? $recievedAmount0 - uint128($amountMinted0)
                    : $recievedAmount0;
                $collected1 = $amountMinted1 < 0
                    ? $recievedAmount1 - uint128($amountMinted1)
                    : $recievedAmount1;

                emit LogInt256("amountToCollect0", $amountToCollect0);
                emit LogInt256("amountToCollect1", $amountToCollect1);

                emit LogUint256("receivedAmount0", $recievedAmount0);
                emit LogUint256("receivedAmount1", $recievedAmount1);

                emit LogUint256("amountMinted0", $amountMinted0);
                emit LogUint256("amountMinted1", $amountMinted1);

                emit LogUint256("collected0", $collected0);
                emit LogUint256("collected1", $collected1);

                emit LogUint256("collectedByLeg[0].rightSlot()", $collectedByLeg[0].rightSlot());
                emit LogUint256("collectedByLeg[0].leftSlot()", $collectedByLeg[0].leftSlot());

                assertWithMsg($collected0 == $collectedByLeg[0].rightSlot(), "invalid collected 0");
                assertWithMsg($collected1 == $collectedByLeg[0].leftSlot(), "invalid collected 1");

                {
                    // get premium gross
                    ($accountPremiumGrossAfter0, $accountPremiumGrossAfter1) = sfpm
                        .getAccountPremium(
                            address(pool),
                            $activeUser,
                            tokenIdShort.tokenType(0),
                            liquidityChunk.tickLower(),
                            liquidityChunk.tickUpper(),
                            type(int24).max,
                            0 // to query gross
                        );

                    // get premium owed
                    ($accountPremiumOwedAfter0, $accountPremiumOwedAfter1) = sfpm.getAccountPremium(
                        address(pool),
                        $activeUser,
                        tokenIdShort.tokenType(0),
                        liquidityChunk.tickLower(),
                        liquidityChunk.tickUpper(),
                        type(int24).max,
                        1 // to query owed
                    );

                    {
                        emit LogInt256("passed tickLower", liquidityChunk.tickLower());
                        emit LogInt256("passed tickUpper", liquidityChunk.tickUpper());
                    }

                    // gross
                    emit LogUint256("$accountPremiumGrossAfter0", $accountPremiumGrossAfter0);
                    emit LogUint256("$accountPremiumGrossAfter1", $accountPremiumGrossAfter1);
                    // owed
                    emit LogUint256("$accountPremiumOwedAfter0", $accountPremiumOwedAfter0);
                    emit LogUint256("$accountPremiumOwedAfter1", $accountPremiumOwedAfter1);

                    if ($amountToCollect0 != 0 || $amountToCollect1 != 0) {
                        LeftRightUnsigned deltaPremiumOwed;
                        LeftRightUnsigned deltaPremiumGross;

                        /// assert premia values before and after
                        // add previous s_accountPremiumOwed by new amounts (if previously uint128 max ensure it doesn't overflow)
                        try
                            this.getPremiaDeltasChecked(
                                netLiquidityBefore,
                                removedLiquidityBefore,
                                $collected0,
                                $collected1
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

                        emit LogUint256(
                            "deltaPremiumOwed.rightSlot()",
                            deltaPremiumOwed.rightSlot()
                        );

                        emit LogUint256("deltaPremiumOwed.leftSlot()", deltaPremiumOwed.leftSlot());

                        emit LogUint256(
                            "deltaPremiumGross.rightSlot()",
                            deltaPremiumGross.rightSlot()
                        );
                        emit LogUint256(
                            "deltaPremiumGross.leftSlot()",
                            deltaPremiumGross.leftSlot()
                        );

                        // ensure getAccountPremium up to the current touch(max tick) vals match
                        // against the externally computed premia values
                        (
                            $accountPremiumGrossCalculated0,
                            $accountPremiumGrossCalculated1,
                            $accountPremiumOwedCalculated0,
                            $accountPremiumOwedCalculated1
                        ) = incrementPremiaAccumulator(
                            $accountPremiumGrossBefore0,
                            $accountPremiumGrossBefore1,
                            //
                            deltaPremiumGross.rightSlot(),
                            deltaPremiumGross.leftSlot(),
                            //
                            $accountPremiumOwedBefore0,
                            $accountPremiumOwedBefore1,
                            //
                            deltaPremiumOwed.rightSlot(),
                            deltaPremiumOwed.leftSlot()
                        );

                        emit LogUint256(
                            "$accountPremiumGrossCalculated0",
                            $accountPremiumGrossCalculated0
                        );
                        emit LogUint256(
                            "$accountPremiumGrossCalculated1",
                            $accountPremiumGrossCalculated1
                        );
                        //
                        emit LogUint256(
                            "$accountPremiumOwedCalculated0",
                            $accountPremiumOwedCalculated0
                        );
                        emit LogUint256(
                            "$accountPremiumOwedCalculated1",
                            $accountPremiumOwedCalculated1
                        );

                        // check calculated gross matches up with stored
                        assertWithMsg(
                            $accountPremiumGrossCalculated0 == $accountPremiumGrossAfter0,
                            "invalid gross 0"
                        );
                        assertWithMsg(
                            $accountPremiumGrossCalculated1 == $accountPremiumGrossAfter1,
                            "invalid gross 1"
                        );

                        // check owed matches up with stored
                        assertWithMsg(
                            $accountPremiumOwedCalculated0 == $accountPremiumOwedAfter0,
                            "invalid owed 0"
                        );
                        assertWithMsg(
                            $accountPremiumOwedCalculated1 == $accountPremiumOwedAfter1,
                            "invalid owed 1"
                        );
                    } else {
                        // gross checks
                        assertWithMsg(
                            $accountPremiumGrossBefore0 == $accountPremiumGrossAfter0,
                            "invalid gross 0 -> no collect"
                        );
                        assertWithMsg(
                            $accountPremiumGrossBefore1 == $accountPremiumGrossAfter1,
                            "invalid gross 1 -> no collect"
                        );

                        // owed checks
                        assertWithMsg(
                            $accountPremiumOwedBefore0 == $accountPremiumOwedAfter0,
                            "invalid owed 0 -> no collect"
                        );
                        assertWithMsg(
                            $accountPremiumOwedBefore1 == $accountPremiumOwedAfter1,
                            "invalid owed 1 -> no collect"
                        );
                    }
                }
            }

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMShort[msg.sender].push(tokenIdShort);

            // reset the tokenIdShort for next iteration
            tokenIdShort = TokenId.wrap(uint256(0));
        } catch {
            // @note if it fails ensure the amount of liquidity being minted was valid
            // that the user has enough tokens to cover the mint and the mint is non-zero liq
        }
    }

    // buy attempt (mint a long position)
    // finds a matching short position which was minted by the user
    // or creates one
    // deducts net from existing short position and adds to removed liquidity
    // ** add moved amts check
    function mint_option_SFPM_singleLong(uint256 randIndex, uint128 positionSize) public {
        // store the current actor
        $activeUser = msg.sender;

        {
            // search for a tokenId that the current actor has sold
            uint256 totalPosLen = userPositionsSFPMShort[msg.sender].length;

            if (totalPosLen == 0) {
                // if no short positions exist for the user then pass
                revert();
            }

            // choose an index at random to burn
            uint256 chosenIndex = bound(randIndex, 0, totalPosLen - 1);
            tokenIdLong = userPositionsSFPMShort[msg.sender][chosenIndex];

            // flip from short to long to mint as a long pos
            tokenIdLong = tokenIdLong.flipToBurnToken();

            // flip the isLong bits to make it a long position
            emit LogUint256("totalPosLen", totalPosLen);
            emit LogUint256("tokenIdLong", tokenIdLong.isLong(0));
        }

        // get the amount of liquidity being deposited
        liquidityChunk = PanopticMath.getLiquidityChunk(tokenIdLong, 0, positionSize);

        // simulate the mint and get the actual moved amounts
        $tickLowerActive = liquidityChunk.tickLower();
        $tickUpperActive = liquidityChunk.tickUpper();
        $LiqAmountActive = liquidityChunk.liquidity();

        ($posLiquidity, , , , ) = pool.positions(
            keccak256(
                abi.encodePacked(
                    address(sfpm),
                    liquidityChunk.tickLower(),
                    liquidityChunk.tickUpper()
                )
            )
        );

        // poke uniswap pool to update tokens owed - needed because swap happens after mint
        // only poke if there is pre-existing liquidity at this chunk
        if ($posLiquidity != 0) {
            hevm.prank(address(sfpm));
            pool.burn($tickLowerActive, $tickUpperActive, 0);
        }

        // get the amount of liquidity within that range present in uniswap already
        bytes32 positionKey = keccak256(
            abi.encodePacked(address(sfpm), liquidityChunk.tickLower(), liquidityChunk.tickUpper())
        );

        (uint128 liquidityBefore, , , , ) = pool.positions(positionKey);

        LeftRightUnsigned accountLiquiditiesBefore = sfpm.getAccountLiquidity(
            address(pool),
            msg.sender,
            tokenIdLong.tokenType(0),
            liquidityChunk.tickLower(),
            liquidityChunk.tickUpper()
        );

        removedLiquidityBefore = accountLiquiditiesBefore.leftSlot();
        netLiquidityBefore = accountLiquiditiesBefore.rightSlot();

        emit LogInt256("liquidityChunk.tickLower()", liquidityChunk.tickLower());
        emit LogInt256("liquidityChunk.tickUpper()", liquidityChunk.tickUpper());

        // s_accountFeesBase before
        // check s_accountFeesBase is updated correctly
        (oldFeesBase0, oldFeesBase1) = sfpm.getAccountFeesBase(
            address(pool),
            msg.sender,
            tokenIdLong.tokenType(0),
            liquidityChunk.tickLower(),
            liquidityChunk.tickUpper()
        );

        (, $feeGrowthInside0LastX128Before, $feeGrowthInside1LastX128Before, , ) = pool.positions(
            keccak256(
                abi.encodePacked(
                    address(sfpm),
                    liquidityChunk.tickLower(),
                    liquidityChunk.tickUpper()
                )
            )
        );

        emit LogUint256("feeGrowthInside0LastX128Before before", $feeGrowthInside0LastX128Before);
        emit LogUint256("feeGrowthInside1LastX128Before before", $feeGrowthInside1LastX128Before);

        {
            //
            int128 newFeesBaseRoundDown0 = int128(
                int256(Math.mulDiv128($feeGrowthInside0LastX128Before, netLiquidityBefore))
            );
            int128 newFeesBaseRoundDown1 = int128(
                int256(Math.mulDiv128($feeGrowthInside1LastX128Before, netLiquidityBefore))
            );

            emit LogInt256("newFeesBaseRoundDown0", newFeesBaseRoundDown0);
            emit LogInt256("newFeesBaseRoundDown1", newFeesBaseRoundDown1);

            emit LogInt256("newFeesBaseRoundDown0", newFeesBaseRoundDown0);
            emit LogInt256("newFeesBaseRoundDown1", newFeesBaseRoundDown1);

            //
            $amountToCollect0 = int128(Math.max(newFeesBaseRoundDown0 - oldFeesBase0, 0));
            $amountToCollect1 = int128(Math.max(newFeesBaseRoundDown1 - oldFeesBase1, 0));

            emit LogInt256("amountToCollect0 before", $amountToCollect0);
            emit LogInt256("amountToCollect1 before", $amountToCollect1);

            // get the burned amounts (true moved amounts)
            // also get the true collected amounts
            quote_uni_CollectAndBurn();
        }

        // get premium gross/owed before (compute with max tick to get value stored in sfpm currently)
        // after check if stored value matches this value
        {
            ($accountPremiumGrossBefore0, $accountPremiumGrossBefore1) = sfpm.getAccountPremium(
                address(pool),
                $activeUser,
                tokenIdLong.tokenType(0),
                liquidityChunk.tickLower(),
                liquidityChunk.tickUpper(),
                type(int24).max,
                0 // short to check gross
            );

            // get gross premium
            emit LogUint256("$accountPremiumGrossBefore0", $accountPremiumGrossBefore0);
            emit LogUint256("$accountPremiumGrossBefore1", $accountPremiumGrossBefore1);
        }

        {
            // owed premium
            ($accountPremiumOwedBefore0, $accountPremiumOwedBefore1) = sfpm.getAccountPremium(
                address(pool),
                $activeUser,
                tokenIdLong.tokenType(0),
                liquidityChunk.tickLower(),
                liquidityChunk.tickUpper(),
                type(int24).max,
                1 // long to check owed
            );

            // get owed premium
            emit LogUint256("$accountPremiumGrossBefore0", $accountPremiumOwedBefore0);
            emit LogUint256("$accountPremiumGrossBefore1", $accountPremiumOwedBefore1);
        }

        hevm.prank(msg.sender);
        try
            sfpm.mintTokenizedPosition(tokenIdLong, positionSize, int24(-887272), int24(887272))
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalSwapped) {
            // @note if chunk liquidity is greater than net liquidity throw an invariant failure

            // copy return into storage
            $collectedByLeg = collectedByLeg;
            $totalSwapped = totalSwapped;

            // check the net liquidity added
            {
                LeftRightUnsigned accountLiquiditiesAfter = sfpm.getAccountLiquidity(
                    address(pool),
                    $activeUser,
                    tokenIdLong.tokenType(0),
                    liquidityChunk.tickLower(),
                    liquidityChunk.tickUpper()
                );

                removedLiquidityAfter = accountLiquiditiesAfter.leftSlot();
                netLiquidityAfter = accountLiquiditiesAfter.rightSlot();

                emit LogUint256("$LiqAmountActive", $LiqAmountActive);

                emit LogUint256("removedLiquidityBefore", removedLiquidityBefore);
                emit LogUint256("netLiquidityBefore", netLiquidityBefore);

                emit LogUint256("removedLiquidityAfter", removedLiquidityAfter);
                emit LogUint256("netLiquidityAfter", netLiquidityAfter);

                // check the liquidity tracked is the same as the liquidity computed
                assertWithMsg(
                    netLiquidityAfter == netLiquidityBefore - $LiqAmountActive,
                    "invalid net liquidity"
                );

                // ensure the removed liquidity remains the same
                assertWithMsg(
                    removedLiquidityAfter == removedLiquidityBefore + $LiqAmountActive,
                    "invalid removed liquidity"
                );
            }

            // check the liquidity deposited within uniswap
            {
                (uint128 liquidityDeployed, , , , ) = pool.positions(positionKey);

                emit LogUint256("liquidityBefore", liquidityBefore);
                emit LogUint256("liquidityDeployed", liquidityDeployed);

                assertWithMsg(
                    liquidityBefore - $LiqAmountActive == liquidityDeployed,
                    "invalid uniswap liq"
                );
            }

            // check stored fees base for this position
            {
                (, $feeGrowthInside0LastX128After, $feeGrowthInside1LastX128After, , ) = pool
                    .positions(
                        keccak256(
                            abi.encodePacked(
                                address(sfpm),
                                liquidityChunk.tickLower(),
                                liquidityChunk.tickUpper()
                            )
                        )
                    );

                emit LogUint256("feeGrowthInside0LastX128After", $feeGrowthInside0LastX128After);
                emit LogUint256("feeGrowthInside1LastX128After", $feeGrowthInside1LastX128After);

                // new fees base
                int128 newFeesBase0 = int128(
                    int256(
                        Math.mulDiv128RoundingUp($feeGrowthInside0LastX128After, netLiquidityAfter)
                    )
                );
                int128 newFeesBase1 = int128(
                    int256(
                        Math.mulDiv128RoundingUp($feeGrowthInside1LastX128After, netLiquidityAfter)
                    )
                );

                // check newly stored feesBase

                (int128 feesBase0, int128 feesBase1) = sfpm.getAccountFeesBase(
                    address(pool),
                    msg.sender,
                    tokenIdLong.tokenType(0),
                    liquidityChunk.tickLower(),
                    liquidityChunk.tickUpper()
                );

                emit LogInt256("oldFeesBase0", oldFeesBase0);
                emit LogInt256("oldFeesBase1", oldFeesBase1);

                emit LogInt256("newFeesBase0", newFeesBase0);
                emit LogInt256("newFeesBase1", newFeesBase1);

                emit LogInt256("feesBase0", feesBase0);
                emit LogInt256("feesBase1", feesBase1);

                assertWithMsg(newFeesBase0 == feesBase0, "invalid fees base 0");
                assertWithMsg(newFeesBase1 == feesBase1, "invalid fees base 1");
            }

            /// compute and verify the amounts to collect
            /// collected the amounts using starting liquidity
            {
                $amountToCollect0 += int128($amountBurned0);
                $amountToCollect1 += int128($amountBurned1);

                // ensure amountToCollect is always positive
                assertWithMsg($amountToCollect0 >= 0, "amountToCollect0 invalid");
                assertWithMsg($amountToCollect1 >= 0, "amountToCollect1 invalid");

                $collected0 = $recievedAmount0 - uint128(int128($amountBurned0));
                $collected1 = $recievedAmount1 - uint128(int128($amountBurned1));

                emit LogInt256("amountToCollect0", $amountToCollect0);
                emit LogInt256("amountToCollect1", $amountToCollect1);

                emit LogUint256("receivedAmount0", $recievedAmount0);
                emit LogUint256("receivedAmount1", $recievedAmount1);

                emit LogInt256("amountBurned0", $amountBurned0);
                emit LogInt256("amountBurned1", $amountBurned1);

                emit LogUint256("collected0", $collected0);
                emit LogUint256("collected1", $collected1);

                emit LogUint256("collectedByLeg[0].rightSlot()", $collectedByLeg[0].rightSlot());
                emit LogUint256("collectedByLeg[0].leftSlot()", $collectedByLeg[0].leftSlot());

                assertWithMsg($collected0 == $collectedByLeg[0].rightSlot(), "invalid collected 0");
                assertWithMsg($collected1 == $collectedByLeg[0].leftSlot(), "invalid collected 1");

                {
                    // get premium gross
                    ($accountPremiumGrossAfter0, $accountPremiumGrossAfter1) = sfpm
                        .getAccountPremium(
                            address(pool),
                            $activeUser,
                            tokenIdLong.tokenType(0),
                            liquidityChunk.tickLower(),
                            liquidityChunk.tickUpper(),
                            type(int24).max,
                            0 // to query gross
                        );

                    // get premium owed
                    ($accountPremiumOwedAfter0, $accountPremiumOwedAfter1) = sfpm.getAccountPremium(
                        address(pool),
                        $activeUser,
                        tokenIdLong.tokenType(0),
                        liquidityChunk.tickLower(),
                        liquidityChunk.tickUpper(),
                        type(int24).max,
                        1 // to query owed
                    );

                    // gross
                    emit LogUint256("$accountPremiumGrossAfter0", $accountPremiumGrossAfter0);
                    emit LogUint256("$accountPremiumGrossAfter1", $accountPremiumGrossAfter1);
                    // owed
                    emit LogUint256("$accountPremiumOwedAfter0", $accountPremiumOwedAfter0);
                    emit LogUint256("$accountPremiumOwedAfter1", $accountPremiumOwedAfter1);

                    if ($amountToCollect0 != 0 || $amountToCollect1 != 0) {
                        LeftRightUnsigned deltaPremiumOwed;
                        LeftRightUnsigned deltaPremiumGross;

                        /// assert premia values before and after
                        // add previous s_accountPremiumOwed by new amounts (if previously uint128 max ensure it doesn't overflow)
                        try
                            this.getPremiaDeltasChecked(
                                netLiquidityBefore,
                                removedLiquidityBefore,
                                $collected0,
                                $collected1
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

                        emit LogUint256(
                            "deltaPremiumOwed.rightSlot()",
                            deltaPremiumOwed.rightSlot()
                        );

                        emit LogUint256("deltaPremiumOwed.leftSlot()", deltaPremiumOwed.leftSlot());

                        emit LogUint256(
                            "deltaPremiumGross.rightSlot()",
                            deltaPremiumGross.rightSlot()
                        );
                        emit LogUint256(
                            "deltaPremiumGross.leftSlot()",
                            deltaPremiumGross.leftSlot()
                        );

                        // ensure getAccountPremium up to the current touch(max tick) vals match
                        // against the externally computed premia values
                        (
                            $accountPremiumGrossCalculated0,
                            $accountPremiumGrossCalculated1,
                            $accountPremiumOwedCalculated0,
                            $accountPremiumOwedCalculated1
                        ) = incrementPremiaAccumulator(
                            $accountPremiumGrossBefore0,
                            $accountPremiumGrossBefore1,
                            //
                            deltaPremiumGross.rightSlot(),
                            deltaPremiumGross.leftSlot(),
                            //
                            $accountPremiumOwedBefore0,
                            $accountPremiumOwedBefore1,
                            //
                            deltaPremiumOwed.rightSlot(),
                            deltaPremiumOwed.leftSlot()
                        );

                        emit LogUint256(
                            "$accountPremiumGrossCalculated0",
                            $accountPremiumGrossCalculated0
                        );
                        emit LogUint256(
                            "$accountPremiumGrossCalculated1",
                            $accountPremiumGrossCalculated1
                        );
                        //
                        emit LogUint256(
                            "$accountPremiumOwedCalculated0",
                            $accountPremiumOwedCalculated0
                        );
                        emit LogUint256(
                            "$accountPremiumOwedCalculated1",
                            $accountPremiumOwedCalculated1
                        );

                        // check calculated gross matches up with stored
                        assertWithMsg(
                            $accountPremiumGrossCalculated0 == $accountPremiumGrossAfter0,
                            "invalid gross 0"
                        );
                        assertWithMsg(
                            $accountPremiumGrossCalculated1 == $accountPremiumGrossAfter1,
                            "invalid gross 1"
                        );

                        // check owed matches up with stored
                        assertWithMsg(
                            $accountPremiumOwedCalculated0 == $accountPremiumOwedAfter0,
                            "invalid owed 0"
                        );
                        assertWithMsg(
                            $accountPremiumOwedCalculated1 == $accountPremiumOwedAfter1,
                            "invalid owed 1"
                        );
                    } else {
                        // gross checks
                        assertWithMsg(
                            $accountPremiumGrossBefore0 == $accountPremiumGrossAfter0,
                            "invalid gross 0 -> no collect"
                        );
                        assertWithMsg(
                            $accountPremiumGrossBefore1 == $accountPremiumGrossAfter1,
                            "invalid gross 1 -> no collect"
                        );

                        // owed checks
                        assertWithMsg(
                            $accountPremiumOwedBefore0 == $accountPremiumOwedAfter0,
                            "invalid owed 0 -> no collect"
                        );
                        assertWithMsg(
                            $accountPremiumOwedBefore1 == $accountPremiumOwedAfter1,
                            "invalid owed 1 -> no collect"
                        );
                    }
                }
            }

            // add minted option to mapping of minted SFPM positions (to grab for burn)
            userPositionsSFPMLong[msg.sender].push(tokenIdLong);

            // reset the tokenIdLong for next iteration
            tokenIdLong = TokenId.wrap(uint256(0));
        } catch {
            // @note if it fails ensure the amount of liquidity being minted was valid
            // that chunk lquidity < net liquidity (should be valid)
        }
    }

    /// *** general multiple mints of longs + shorts (random / use helpers)
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
        TokenId tokenIdShort = _generate_single_leg_tokenid(
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
            (int256 moved0, int256 moved1) = _calculate_moved_amounts(tokenIdShort, positionSize);

            emit LogInt256("moved0", moved0);
            emit LogInt256("moved1", moved1);

            // get itm amounts
            (int256 itm0, int256 itm1) = _calculate_itm_amounts(
                tokenIdShort.tokenType(0),
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
        try sfpm.mintTokenizedPosition(tokenIdShort, positionSize, tickLimitLow, tickLimitHigh) {
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
            userPositionsSFPMShort[minter].push(tokenIdShort);
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
        TokenId tokenIdShort = _generate_single_leg_tokenid(
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
            (moved0, moved1) = _calculate_moved_amounts(tokenIdShort, positionSize);

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
        try sfpm.mintTokenizedPosition(tokenIdShort, positionSize, tickLimitLow, tickLimitHigh) {
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
            userPositionsSFPMShort[msg.sender].push(tokenIdShort);
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
        TokenId tokenIdShort = _generate_single_leg_tokenid(
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
            (moved0, moved1) = _calculate_moved_amounts(tokenIdShort, positionSize);

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
        try sfpm.mintTokenizedPosition(tokenIdShort, positionSize, tickLimitLow, tickLimitHigh) {
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
            userPositionsSFPMShort[msg.sender].push(tokenIdShort);
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
        TokenId tokenIdShort = _generate_single_leg_tokenid(
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
            (moved0, moved1) = _calculate_moved_amounts(tokenIdShort, positionSize);

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
        try sfpm.mintTokenizedPosition(tokenIdShort, positionSize, tickLimitLow, tickLimitHigh) {
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
            userPositionsSFPMShort[msg.sender].push(tokenIdShort);
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
        TokenId tokenIdShort = _generate_multiple_leg_tokenid(
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
            ) = _calculate_moved_and_ITM_amounts(tokenIdShort, positionSize, false);

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
        try sfpm.mintTokenizedPosition(tokenIdShort, positionSize, tickLimitHigh, tickLimitLow) {
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
            userPositionsSFPMShort[msg.sender].push(tokenIdShort);
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

    // @note temp disable
    // token composition is over 127 bits on either side should fail
    // function invariant_mint_option_SFPM_PositionTooLarge(
    //     uint256 minter_index,
    //     bool asset,
    //     bool is_call,
    //     bool is_long,
    //     bool is_otm,
    //     bool is_atm,
    //     bool swapAtMint,
    //     uint24 width,
    //     int256 strike,
    //     uint128 positionSize
    // ) public {
    //     minter_index = bound(minter_index, 0, 4);
    //     if (actors[minter_index] == msg.sender) {
    //         minter_index = bound(minter_index + 1, 0, 4);
    //     }

    //     address minter = actors[minter_index];

    //     TokenId tokenId = _generate_single_leg_tokenid(
    //         asset,
    //         is_call,
    //         false,
    //         is_otm,
    //         is_atm,
    //         width,
    //         strike
    //     );

    //     int24 tickLimitLow = swapAtMint ? int24(887272) : int24(-887272);
    //     int24 tickLimitHigh = swapAtMint ? int24(-887272) : int24(887272);

    //     // current balances
    //     uint256 balBefore0 = IERC20(USDC).balanceOf(msg.sender);
    //     uint256 balBefore1 = IERC20(WETH).balanceOf(msg.sender);

    //     hevm.prank(minter);
    //     try sfpm.mintTokenizedPosition(tokenId, positionSize, tickLimitLow, tickLimitHigh) {
    //         // if amount moved is greater than 2 ** 127 bits
    //         // bal before - bal after > 2 ** 127 - 1

    //         // check final balances
    //         uint256 balAfter0 = IERC20(USDC).balanceOf(msg.sender);
    //         uint256 balAfter1 = IERC20(WETH).balanceOf(msg.sender);

    //         uint256 balDelta0 = balBefore0 - balAfter0;
    //         uint256 balDelta1 = balBefore1 - balAfter1;

    //         assertWithMsg(
    //             balDelta0 > uint128(type(int128).max - 4) ||
    //                 balDelta1 > uint128(type(int128).max - 4),
    //             "can't mint a position which exceeds the token limits of 127 bits"
    //         );
    //     } catch {}
    // }

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
        uint128 positionSize
    ) public {
        minter_index = bound(minter_index, 0, 4);
        if (actors[minter_index] == msg.sender) {
            minter_index = bound(minter_index + 1, 0, 4);
        }

        address minter = actors[minter_index];

        TokenId tokenIdShort = _generate_single_leg_tokenid(
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

        (int24 tickLower, int24 tickUpper) = tokenIdShort.asTicks(0);

        // check there is no pre-existing liquidity at this chunk deployed by the minter
        LeftRightUnsigned accountLiquidities = sfpm.getAccountLiquidity(
            address(pool),
            minter,
            tokenIdShort.tokenType(0),
            tickLower,
            tickUpper
        );

        uint256 netLiquidity = accountLiquidities.rightSlot();

        // invoke actions as the chosen minter
        hevm.prank(minter);

        //
        if (netLiquidity != 0) {
            // mint a small amount of liquidity at this chunk
            sfpm.mintTokenizedPosition(tokenIdShort, positionSize, tickLimitLow, tickLimitHigh);
        }

        // then try to purchase an amount larger than this amount (startingLiquidity < chunkLiquidity)
        try sfpm.mintTokenizedPosition(tokenIdLong, positionSize + 1, tickLimitLow, tickLimitHigh) {
            // log liquidity amounts at positionSize and positionSize + 1 (rounding ?? **)
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
        TokenId tokenIdShort = _generate_single_leg_tokenid(
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
        (int256 moved0, int256 moved1) = _calculate_moved_amounts(tokenIdShort, positionSize);

        // get itm amounts
        (int256 itm0, int256 itm1) = _calculate_itm_amounts(
            tokenIdShort.tokenType(0),
            moved0,
            moved1
        );

        (int256 swapAmount, bool zeroForOne) = _compute_swap_amounts(itm0, itm1);

        //hevm.prank(minter);
        fund_and_approve();

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
        try sfpm.mintTokenizedPosition(tokenIdShort, positionSize, tickLimitLow, tickLimitHigh) {
            assertWithMsg(false, "Can't mint an option which defies the slippage bounds");
        } catch {}
    }
}
