// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "./FuzzHelpers.sol";
import {CollateralActions} from "./CollateralActions.sol";

contract PanopticPoolActions is CollateralActions {
    /*//////////////////////////////////////////////////////////////
                             OPTION MINTING
    //////////////////////////////////////////////////////////////*/

    function mint_option(
        uint256[4] memory isLongs,
        uint256[4] memory tokenTypes,
        uint256[4] memory widthSeeds,
        int256[4] memory strikeSeeds,
        uint256[4] memory ratioSeeds,
        uint256[4] memory assets,
        bool[4] memory distributions,
        uint256 positionSize,
        uint256 numLegs
    ) public {
        emit LogAddress("actor", msg.sender);

        $numLegs = bound(numLegs, 1, 4);

        $posIdListOld = userPositions[msg.sender];

        userPositions[msg.sender].push(TokenId.wrap(poolId));

        (, currentTick, observationIndex, observationCardinality, , , ) = pool.slot0();

        $fastOracleTick = PanopticMath.computeMedianObservedPrice(
            pool,
            observationIndex,
            observationCardinality,
            3,
            1
        );

        $found = false;
        for (uint256 i = 0; i < $numLegs; ++i) {
            $tokenTypes[i] = bound(tokenTypes[i], 0, 1);
            $isLongs[i] = bound(isLongs[i], 0, 4);
            $isLongs[i] = $isLongs[i] > 1 ? 0 : $isLongs[i];
            $assets[i] = bound(assets[i], 0, 1);
            $ratios[i] = bound(ratioSeeds[i], 1, 127);

            if ($isLongs[i] == 0) {
                ($widths[i], $strikes[i]) = getValidSW(
                    widthSeeds[i],
                    strikeSeeds[i],
                    uint24(poolTickSpacing),
                    currentTick,
                    distributions[0]
                );

                touchedPanopticChunks.push(
                    ChunkWithTokenType($strikes[i], $widths[i], $tokenTypes[i])
                );
            } else {
                // pick a random chunk -- very likely to fail due to no liquidity
                if (touchedPanopticChunks.length == 0) {
                    ($widths[i], $strikes[i]) = getValidSW(
                        widthSeeds[i],
                        strikeSeeds[i],
                        uint24(poolTickSpacing),
                        currentTick,
                        distributions[0]
                    );
                }
                // pick a chunk that has already been interacted with before -- reasonable probability of success
                else if (distributions[3] && false) {
                    ChunkWithTokenType memory __chunk = touchedPanopticChunks[
                        bound(
                            uint256(keccak256(abi.encodePacked(positionSize))),
                            0,
                            touchedPanopticChunks.length - 1
                        )
                    ];

                    $widths[i] = __chunk.width;
                    $strikes[i] = __chunk.strike;
                }
                // pick a chunk with some liquidity and reverse the position size to it
                else {
                    bool found;
                    // look through all chunks starting at a random index until one with liquidity is found
                    for (
                        uint256 j = bound(
                            uint256(keccak256(abi.encodePacked(positionSize))),
                            0,
                            touchedPanopticChunks.length - 1
                        );
                        j < touchedPanopticChunks.length;
                        j++
                    ) {
                        ChunkWithTokenType memory __chunk = touchedPanopticChunks[j];

                        emit LogInt256("chunk strike", __chunk.strike);
                        emit LogInt256("chunk width", __chunk.width);
                        emit LogUint256("chunk token type", __chunk.tokenType);
                        ($tickLower, $tickUpper) = PanopticMath.getTicks(
                            __chunk.strike,
                            __chunk.width,
                            poolTickSpacing
                        );

                        if (
                            sfpm
                                .getAccountLiquidity(
                                    address(pool),
                                    address(panopticPool),
                                    __chunk.tokenType,
                                    $tickLower,
                                    $tickUpper
                                )
                                .rightSlot() > 0
                        ) {
                            $widths[i] = __chunk.width;
                            $strikes[i] = __chunk.strike;
                            found = true;
                            $found = true;
                            break;
                        }
                    }

                    if (!found) {
                        ($widths[i], $strikes[i]) = getValidSW(
                            widthSeeds[i],
                            strikeSeeds[i],
                            uint24(poolTickSpacing),
                            currentTick,
                            distributions[0]
                        );
                    }
                }
            }

            userPositions[msg.sender][userPositions[msg.sender].length - 1] = userPositions[
                msg.sender
            ][userPositions[msg.sender].length - 1].addLeg(
                    i,
                    $ratios[i],
                    $assets[i],
                    $isLongs[i],
                    $tokenTypes[i],
                    i,
                    $strikes[i],
                    $widths[i]
                );
        }

        uint256 userCollateral0 = collToken0.convertToAssets(collToken0.balanceOf(msg.sender));
        uint256 userCollateral1 = collToken1.convertToAssets(collToken1.balanceOf(msg.sender));

        positionSize = uint128(
            distributions[1]
                ? bound(positionSize, 0, 1_000_000_000 * 2 ** 64)
                : bound(positionSize, 0, 2 * 2 ** 64)
        );

        try this.size_for_collateral_solo(positionSize, userCollateral0, userCollateral1) {} catch (
            bytes memory reason
        ) {
            emit LogBytes("Reason", reason);
        }

        positionSize = uint128(
            size_for_collateral_solo(positionSize, userCollateral0, userCollateral1)
        );

        $positionSizeActive = uint128(positionSize);

        $tokenIdActive = userPositions[msg.sender][userPositions[msg.sender].length - 1];

        $sfpmBal = sfpm.balanceOf(address(panopticPool), TokenId.unwrap($tokenIdActive));

        $maxTransfer0 = 0;
        $maxTransfer1 = 0;

        $netTokenTransfers0 = 0;
        $netTokenTransfers1 = 0;

        $shouldRevert = false;

        // and check if should revert due to 0 liquidity
        write_mintburn_transfer_amts();

        // pool has insufficient tokens to mint the option
        $shouldRevert = $shouldRevert
            ? $shouldRevert
            : $maxTransfer0 > int256(USDC.balanceOf(address(panopticPool))) ||
                $maxTransfer1 > int256(WETH.balanceOf(address(panopticPool)));

        emit LogBool("should revert due to insufficient pool tokens", $shouldRevert);

        // position has already been minted
        for (uint256 i = 0; i < userPositions[msg.sender].length - 1; ++i) {
            $shouldRevert = $shouldRevert
                ? $shouldRevert
                : TokenId.unwrap($tokenIdActive) == TokenId.unwrap(userPositions[msg.sender][i]);
            emit LogBool("should revert due to position already minted", $shouldRevert);
        }

        emit LogInt256("Net token transfers 0", $maxTransfer0);
        emit LogInt256("Net token transfers 1", $maxTransfer1);
        emit LogInt256("pool balance 0", int256(USDC.balanceOf(address(panopticPool))));
        emit LogInt256("pool balance 1", int256(WETH.balanceOf(address(panopticPool))));

        // get SFPM swapped/premium collect amounts and expected fast/slow oracle ticks post-mint
        quote_sfpm_mint();
        emit LogInt256("$totalSwapped.rs", $totalSwapped.rightSlot());
        emit LogInt256("$totalSwapped.ls", $totalSwapped.leftSlot());

        ($longAmounts, $shortAmounts) = PanopticMath.computeExercisedAmounts(
            $tokenIdActive,
            $positionSizeActive
        );

        // intrinsic val
        $colDelta0 = -($totalSwapped.rightSlot() -
            ($shortAmounts.rightSlot() - $longAmounts.rightSlot()));
        emit LogInt256("intrinsicDelta0", $colDelta0);
        $colDelta1 = -($totalSwapped.leftSlot() -
            ($shortAmounts.leftSlot() - $longAmounts.leftSlot()));
        emit LogInt256("intrinsicDelta1", $colDelta1);

        $intrinsicDelta0 = $colDelta0;
        $intrinsicDelta1 = $colDelta1;

        // ITM spread + commission
        $commission0 = int256(
            Math.unsafeDivRoundingUp(
                (uint256(Math.abs($colDelta0)) * pool.fee() * 2),
                (10_000 * 100)
            ) +
                Math.unsafeDivRoundingUp(
                    (uint256(uint128($shortAmounts.rightSlot())) +
                        uint128($longAmounts.rightSlot())) * 10,
                    10_000
                )
        );
        $commission1 = int256(
            Math.unsafeDivRoundingUp(
                (uint256(Math.abs($colDelta1)) * pool.fee() * 2),
                (10_000 * 100)
            ) +
                Math.unsafeDivRoundingUp(
                    (uint256(uint128($shortAmounts.leftSlot())) +
                        uint128($longAmounts.leftSlot())) * 10,
                    10_000
                )
        );

        $colDelta0 -= $commission0;
        $colDelta1 -= $commission1;

        ($premia0, $premia1, $posBalanceArray) = panopticPool.calculateAccumulatedFeesBatch(
            msg.sender,
            false,
            $posIdListOld
        );

        ($poolAssets0, $inAMM0, ) = collToken0.getPoolData();
        ($poolAssets1, $inAMM1, ) = collToken1.getPoolData();

        $poolAssets0 = uint256(int256($poolAssets0) + $colDelta0);
        $poolAssets1 = uint256(int256($poolAssets1) + $colDelta1);
        $inAMM0 = uint256(int256($inAMM0) - $shortAmounts.rightSlot() + $longAmounts.rightSlot());
        $inAMM1 = uint256(int256($inAMM1) - $shortAmounts.leftSlot() + $longAmounts.leftSlot());

        $poolUtil0 = ($inAMM0 * 10_000) / $poolAssets0;
        $poolUtil1 = ($inAMM1 * 10_000) / $poolAssets1;

        unchecked {
            $posBalanceArray.push(
                [
                    TokenId.unwrap($tokenIdActive),
                    LeftRightUnsigned.unwrap(
                        LeftRightUnsigned.wrap(0).toRightSlot($positionSizeActive).toLeftSlot(
                            uint128($poolUtil0 + uint128($poolUtil1 << 64))
                        )
                    )
                ]
            );
        }

        $tokenData0 = collToken0.getAccountMarginDetails(
            msg.sender,
            $fastOracleTick,
            $posBalanceArray,
            $premia0
        );
        $tokenData1 = collToken1.getAccountMarginDetails(
            msg.sender,
            $fastOracleTick,
            $posBalanceArray,
            $premia1
        );

        $totalAssets0 = collToken0.totalAssets();
        $totalAssets1 = collToken1.totalAssets();
        $totalSupply0 = collToken0.totalSupply();
        $totalSupply1 = collToken1.totalSupply();
        if (
            !(-$colDelta0 > int256(uint256($tokenData0.rightSlot())) ||
                -$colDelta1 > int256(uint256($tokenData1.rightSlot())))
        ) {
            $balance0ExpectedP = Math.mulDiv(
                uint256(
                    int256(collToken0.balanceOf(msg.sender)) +
                        ($colDelta0 * int256($totalSupply0)) /
                        int256($totalAssets0)
                ),
                uint256(int256($totalAssets0) + $colDelta0 + $commission0),
                uint256(
                    int256($totalSupply0) +
                        ($colDelta0 * int256($totalSupply0)) /
                        int256($totalAssets0)
                )
            );
            $balance1ExpectedP = Math.mulDiv(
                uint256(
                    int256(collToken1.balanceOf(msg.sender)) +
                        ($colDelta1 * int256($totalSupply1)) /
                        int256($totalAssets1)
                ),
                uint256(int256($totalAssets1) + $colDelta1 + $commission1),
                uint256(
                    int256($totalSupply1) +
                        ($colDelta1 * int256($totalSupply1)) /
                        int256($totalAssets1)
                )
            );

            $balanceCross =
                Math.mulDiv(
                    $balance1ExpectedP,
                    2 ** 96,
                    TickMath.getSqrtRatioAtTick($fastOracleTick)
                ) +
                Math.mulDiv96($balance0ExpectedP, TickMath.getSqrtRatioAtTick($fastOracleTick));

            $thresholdCross =
                Math.mulDivRoundingUp(
                    uint256($tokenData1.leftSlot()),
                    2 ** 96,
                    TickMath.getSqrtRatioAtTick($fastOracleTick)
                ) +
                Math.mulDiv96RoundingUp(
                    $tokenData0.leftSlot(),
                    TickMath.getSqrtRatioAtTick($fastOracleTick)
                );
            $shouldRevert = $shouldRevert
                ? $shouldRevert
                : ($thresholdCross * 13_333) / 10_000 > $balanceCross;

            // emit LogUint256("origBal0", $balance0Origin);
            // emit LogUint256("origBal1",$balance1Origin);
            emit LogInt256("colDelta0", $colDelta0);
            emit LogInt256("colDelta1", $colDelta1);
            emit LogUint256("bal0", $balance0ExpectedP);
            emit LogUint256("bal1", $balance1ExpectedP);
            emit LogUint256("req0", uint256($tokenData0.leftSlot()));
            emit LogUint256("req1", uint256($tokenData1.leftSlot()));
            emit LogUint256("balCross", $balanceCross);
            emit LogUint256("thresholdCross", $thresholdCross);
            emit LogInt256("fast tick", $fastOracleTick);
            emit LogBool("revert due to collateral shortfall at fast oracle tick", $shouldRevert);

            if (Math.abs(int256($slowOracleTick) - $fastOracleTick) > 1800) {
                $tokenData0 = collToken0.getAccountMarginDetails(
                    msg.sender,
                    $slowOracleTick,
                    $posBalanceArray,
                    $premia0
                );
                $tokenData1 = collToken1.getAccountMarginDetails(
                    msg.sender,
                    $slowOracleTick,
                    $posBalanceArray,
                    $premia1
                );

                $balanceCross =
                    Math.mulDiv(
                        $balance1ExpectedP,
                        2 ** 96,
                        TickMath.getSqrtRatioAtTick($slowOracleTick)
                    ) +
                    Math.mulDiv96($balance0ExpectedP, TickMath.getSqrtRatioAtTick($slowOracleTick));

                $thresholdCross =
                    Math.mulDivRoundingUp(
                        uint256($tokenData1.leftSlot()),
                        2 ** 96,
                        TickMath.getSqrtRatioAtTick($slowOracleTick)
                    ) +
                    Math.mulDiv96RoundingUp(
                        $tokenData0.leftSlot(),
                        TickMath.getSqrtRatioAtTick($slowOracleTick)
                    );

                $shouldRevert = $shouldRevert ? $shouldRevert : $thresholdCross > $balanceCross;

                emit LogUint256("thresholdCross", $thresholdCross);
                emit LogUint256("req0", uint256($tokenData0.leftSlot()));
                emit LogUint256("req1", uint256($tokenData1.leftSlot()));
                emit LogInt256("slow tick", $slowOracleTick);
                emit LogBool(
                    "revert due to collateral shortfall at slow oracle tick",
                    $shouldRevert
                );
            }
        } else {
            $shouldRevert = true;

            emit LogUint256("$tokenData0.rightSlot()", $tokenData0.rightSlot());
            emit LogUint256("$tokenData1.rightSlot()", $tokenData1.rightSlot());
            emit LogInt256("$colDelta0", $colDelta0);
            emit LogInt256("$colDelta1", $colDelta1);
            emit LogBool("revert due to insufficient collateral to cover delta", $shouldRevert);
        }

        $balance0Origin = int256(collToken0.convertToAssets(collToken0.balanceOf(msg.sender)));
        $balance1Origin = int256(collToken1.convertToAssets(collToken1.balanceOf(msg.sender)));

        // assert(!($found && $positionSizeActive != 0));
        hevm.prank(msg.sender);
        try
            panopticPool.mintOptions(
                userPositions[msg.sender],
                uint128($positionSizeActive),
                type(uint64).max,
                TickMath.MAX_TICK,
                TickMath.MIN_TICK
            )
        {
            for (uint256 i = 0; i < $numLegs; ++i) {
                // assertWithMsg($isLongs[i] != 1, "minted long!");
            }
            $allPositionCount++;
            assertWithMsg(!$shouldRevert, "mintOptions: missing revert");
        } catch (bytes memory reason) {
            emit LogBytes("Reason", reason);

            assertWithMsg($shouldRevert, "mintOptions: unexpected revert");
            $failedPositionCount++;
            // reverse test state changes (i.e. positionidlist)
            revert();
        }

        assertWithMsg(
            sfpm.balanceOf(address(panopticPool), TokenId.unwrap($tokenIdActive)) - $sfpmBal ==
                $positionSizeActive,
            "mintOptions: incorrect amount of SFPM tokens minted"
        );

        $balance0Final = int256(
            Math.mulDiv(collToken0.balanceOf(msg.sender), $totalAssets0, $totalSupply0)
        );
        $balance1Final = int256(
            Math.mulDiv(collToken1.balanceOf(msg.sender), $totalAssets1, $totalSupply1)
        );

        emit LogInt256("Balance 0 expected", $balance0Origin + $colDelta0);
        emit LogInt256("deltaE0", $colDelta0);
        emit LogInt256("Balance 0", $balance0Final);
        assertWithMsg(
            Math.abs(int256($balance0Final) - int256($balance0Origin + $colDelta0)) <= 10,
            "Balance 0 mismatch"
        );

        emit LogInt256("Balance 1 expected", $balance1Origin + $colDelta1);
        emit LogInt256("deltaE1", $colDelta1);
        emit LogInt256("Balance 1", $balance1Final);
        assertWithMsg(
            Math.abs(int256($balance1Final) - int256($balance1Origin + $colDelta1)) <= 10,
            "Balance 1 mismatch"
        );
    }

    /*//////////////////////////////////////////////////////////////
                             OPTION BURNING
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                             FORCE EXERCISE
    //////////////////////////////////////////////////////////////*/

    function force_exercise(uint256 position, bool search) public {
        // assertWithMsg($allPositionCount < 5, "APC > 5");
        $allPositionOwners = new address[](0);
        $allPositions = new TokenId[](0);
        for (uint256 i = 0; i < actors.length; ++i) {
            for (uint256 j = 0; j < userPositions[actors[i]].length; ++j) {
                $allPositionOwners.push(actors[i]);
                $allPositions.push(userPositions[actors[i]][j]);
            }
        }

        // find a position with at least one long leg - reasonably high probability of being exercisable
        if (search) {
            bool isLong;
            for (uint256 i = bound(position, 0, 0); i < $allPositions.length; ++i) {
                for (uint256 j = 0; j < $allPositions[i].countLegs(); ++j) {
                    if ($allPositions[i].isLong(j) == 1) {
                        $tokenIdActive = $allPositions[i];
                        $exercisee = $allPositionOwners[i];
                        isLong = true;
                        break;
                    }
                }
                // if (isLong) assertWithMsg(false, "searchFound");
                if (isLong) break;
            }
            if (!isLong) {
                // assertWithMsg($allPositions.length < 5, "No long positions found");
                ($exercisee, $tokenIdActive) = (
                    $allPositionOwners[bound(position, 0, $allPositions.length - 1)],
                    $allPositions[bound(position, 0, $allPositions.length - 1)]
                );
            }
        } else {
            ($exercisee, $tokenIdActive) = (
                $allPositionOwners[bound(position, 0, $allPositions.length - 1)],
                $allPositions[bound(position, 0, $allPositions.length - 1)]
            );
        }

        ($positionSizeActive, , ) = panopticPool.optionPositionBalance($exercisee, $tokenIdActive);

        $touchedId = [$tokenIdActive];
        $positionListExercisor = userPositions[msg.sender];
        $positionListExercisee = _get_list_without_tokenid(
            userPositions[$exercisee],
            $tokenIdActive
        );

        (, currentTick, , , , , ) = pool.slot0();
        $twapTick = PanopticMath.twapFilter(pool, 600);

        $shouldRevert = false;

        try this.validate_exercisable_ext($tokenIdActive, $twapTick) {
            $shouldRevert = $shouldRevert ? $shouldRevert : false;
        } catch {
            $shouldRevert = $shouldRevert ? $shouldRevert : true;
        }

        $balance0Origin = int256(collToken0.balanceOf(msg.sender));
        $balance1Origin = int256(collToken1.balanceOf(msg.sender));

        $balance0Exercisee = int256(collToken0.balanceOf($exercisee));
        $balance1Exercisee = int256(collToken1.balanceOf($exercisee));

        quote_pp_burn();

        hevm.prank(msg.sender);
        try
            panopticPool.forceExercise(
                $exercisee,
                $touchedId,
                $positionListExercisee,
                $positionListExercisor
            )
        {
            assertWithMsg(false, "force exercise pass");
        } catch (bytes memory reason) {
            emit LogBytes("Reason", reason);
            assertWithMsg($shouldRevert, "Force exercise failed");

            revert();
        }

        ($longAmounts, $shortAmounts) = PanopticMath.computeExercisedAmounts(
            $tokenIdActive,
            $positionSizeActive
        );

        LeftRightSigned exerciseCost = collToken0.exerciseCost(
            currentTick,
            $twapTick,
            $tokenIdActive,
            $positionSizeActive,
            $longAmounts
        );

        // exercise cost (in terms of token0)
        int256 exerciseCostToken0 = exerciseCost.rightSlot() +
            PanopticMath.convert1to0(
                exerciseCost.leftSlot(),
                TickMath.getSqrtRatioAtTick($twapTick)
            );
        // token0 - diff from burn
        int256 cDelta0 = (
            int256(collToken0.balanceOf($exercisee)) - $balance0Exercisee - $colDelta0 > 0
                ? int8(1)
                : -1
        ) *
            int256(
                collToken0.convertToAssets(
                    uint256(
                        Math.abs(int256(collToken0.balanceOf($exercisee)) - $balance0Exercisee) -
                            $colDelta0
                    )
                )
            );
        // token1 - diff from burn
        cDelta0 += PanopticMath.convert1to0(
            (
                int256(collToken1.balanceOf($exercisee)) - $balance1Exercisee - $colDelta1 > 0
                    ? int8(1)
                    : -1
            ) *
                int256(
                    collToken1.convertToAssets(
                        uint256(
                            Math.abs(
                                int256(collToken1.balanceOf($exercisee)) - $balance1Exercisee
                            ) - $colDelta1
                        )
                    )
                ),
            TickMath.getSqrtRatioAtTick($twapTick)
        );

        // ensure that any differences from post-burn balances in the exercisee are:
        // a) matched exactly by a change in the exercisor's balance
        // b) roughly equivalent in value to the force exercise fee
        assertWithMsg(
            (int256(collToken0.balanceOf($exercisee)) - $balance0Exercisee) - $colDelta0 ==
                -(int256(collToken0.balanceOf(msg.sender)) - $balance0Origin),
            "ForceExercise: Exercisor delegation does not match exercisee's token0 delta compared to burn"
        );
        assertWithMsg(
            (int256(collToken1.balanceOf($exercisee)) - $balance1Exercisee) - $colDelta1 ==
                -(int256(collToken1.balanceOf(msg.sender)) - $balance1Origin),
            "ForceExercise: Exercisor delegation does not match exercisee's token1 delta compared to burn"
        );

        assertWithMsg(
            cDelta0 >= 0,
            "ForceExercise: Sanity check - Exercisee token value is lower than before"
        );

        assertWithMsg(
            cDelta0 == exerciseCostToken0,
            "ForceExercise: Token deltas do not match exercise cost"
        );
    }

    /*//////////////////////////////////////////////////////////////
                              LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:property PANO-LIQ-001 The position to liquidate must have a balance below the threshold
    /// @custom:property PANO-LIQ-002 After liquidation, user must have zero open positions
    /// @custom:precondition The liquidatee has a liquidatable position open
    function try_liquidate_option(uint256 i_liquidated) public {
        i_liquidated = bound(i_liquidated, 0, 4);
        address liquidatee = actors[i_liquidated];
        address liquidator = msg.sender;

        if (userPositions[liquidatee].length < 1) {
            emit LogString("No current positions");
            revert();
        }

        // Make sure the liquidator has tokens to delegate
        {
            hevm.prank(liquidator);
            fund_and_approve();

            uint256 lb0 = IERC20(USDC).balanceOf(liquidator);
            uint256 lb1 = IERC20(WETH).balanceOf(liquidator);
            hevm.prank(liquidator);
            deposit_to_ct(true, lb0, false);
            hevm.prank(liquidator);
            deposit_to_ct(false, lb1, false);
        }

        require(liquidatee != liquidator);

        TokenId[] memory liquidated_positions = userPositions[liquidatee];
        TokenId[] memory liquidator_positions = userPositions[liquidator];

        emit LogUint256("liquidator positions length", liquidator_positions.length);
        emit LogUint256("liquidated positions length", liquidated_positions.length);
        emit LogAddress("liquidator", liquidator);
        emit LogAddress("liquidated", liquidatee);

        int24 TWAPtick = PanopticMath.twapFilter(pool, 600);
        (, currentTick, , , , , ) = pool.slot0();
        emit LogInt256("TWAP tick", TWAPtick);
        emit LogInt256("Current tick", currentTick);

        log_account_collaterals(liquidator);
        log_account_collaterals(liquidatee);
        log_trackers_status();

        require(liquidated_positions.length > 0);

        (uint256 balanceCross, uint256 thresholdCross) = _get_solvency_balances(
            liquidatee,
            TWAPtick
        );
        emit LogUint256("Balance cross", balanceCross);
        emit LogUint256("Threshold cross", thresholdCross);

        LeftRightUnsigned delegations = LeftRightUnsigned
            .wrap(uint96(collToken0.convertToAssets(collToken0.balanceOf(liquidator))))
            .toLeftSlot(uint96(collToken1.convertToAssets(collToken1.balanceOf(liquidator))));

        // If the position is not liquidatable, liquidation call must revert
        if (balanceCross > thresholdCross) {
            try
                panopticPool.liquidate(
                    liquidator_positions,
                    liquidatee,
                    delegations,
                    liquidated_positions
                )
            {
                assertWithMsg(
                    false,
                    "A non-liquidatable position (balanceCross >= thresholdCross) was liquidated"
                );
            } catch {
                revert();
            }
        }

        _calculate_margins_and_premia(liquidatee, TWAPtick);

        liqResults.sharesD0 = int256(collToken0.balanceOf(liquidatee));
        liqResults.sharesD1 = int256(collToken1.balanceOf(liquidatee));

        _execute_burn_simulation(liquidatee, liquidator);

        liqResults.liquidatorValueBefore0 = _get_assets_in_token0(liquidator, currentTick);
        {
            (int128 p0, int128 p1, ) = panopticPool.calculateAccumulatedFeesBatch(
                liquidatee,
                false,
                liquidated_positions
            );
            liqResults.premia = LeftRightSigned.wrap(0).toRightSlot(p0).toLeftSlot(p1);
            emit LogInt256("Premium in token 0", p0);
            emit LogInt256("Premium in token 1", p1);
        }

        _calculate_liquidation_bonus(TWAPtick, currentTick);

        burnSimResults.delegated0 = uint256(
            int256(
                collToken0.convertToShares(
                    uint256(
                        int256(
                            uint256(
                                uint96(collToken0.convertToAssets(collToken0.balanceOf(liquidator)))
                            )
                        ) + liqResults.bonus0
                    )
                )
            )
        );
        burnSimResults.delegated1 = uint256(
            int256(
                collToken1.convertToShares(
                    uint256(
                        int256(
                            uint256(
                                uint96(collToken1.convertToAssets(collToken1.balanceOf(liquidator)))
                            )
                        ) + liqResults.bonus1
                    )
                )
            )
        );

        hevm.prank(liquidator);
        panopticPool.liquidate(liquidator_positions, liquidatee, delegations, liquidated_positions);

        log_burn_simulation_results();
        log_liquidation_results();

        liqResults.sharesD0 =
            burnSimResults.shareDelta0 -
            (int256(collToken0.balanceOf(liquidatee)) - liqResults.sharesD0);
        liqResults.sharesD1 =
            burnSimResults.shareDelta1 -
            (int256(collToken1.balanceOf(liquidatee)) - liqResults.sharesD1);
        liqResults.liquidatorValueAfter0 = _get_assets_in_token0(liquidator, currentTick);

        _calculate_bonus(TWAPtick);
        _calculate_protocol_loss_0(currentTick);
        _calculate_protocol_loss_expected_0(TWAPtick, currentTick);

        bytes memory settledLiq;
        (liqResults.settledTokens0, settledLiq) = _calculate_settled_tokens(
            userPositions[liquidatee],
            currentTick
        );
        liqResults.settledTokens = abi.decode(settledLiq, (uint256[2][4][32]));

        delete userPositions[liquidatee];

        log_burn_simulation_results();
        log_liquidation_results();

        emit LogUint256("Number of positions", panopticPool.numberOfPositions(liquidatee));
        assertWithMsg(
            panopticPool.numberOfPositions(liquidatee) == 0,
            "Liquidation did not close all positions"
        );

        if (
            (collToken0.totalSupply() - burnSimResults.totalSupply0 <= 1) &&
            (collToken1.totalSupply() - burnSimResults.totalSupply1 <= 1)
        ) {
            int256 assets = convertToAssets(collToken0, liqResults.sharesD0) +
                PanopticMath.convert1to0(
                    convertToAssets(collToken1, liqResults.sharesD1),
                    TickMath.getSqrtRatioAtTick(currentTick)
                );
            emit LogInt256("Assets", assets);
            emit LogInt256("Bonus combined", liqResults.bonusCombined0);

            assertLt(
                abs(int256(assets) - int256(liqResults.bonusCombined0)),
                10,
                "Liquidatee was debited incorrect bonus value (funds leftover)"
            );
        } else {
            int256 assets = convertToAssets(collToken0, liqResults.sharesD0) +
                PanopticMath.convert1to0(
                    convertToAssets(collToken1, liqResults.sharesD1),
                    TickMath.getSqrtRatioAtTick(currentTick)
                );
            emit LogInt256("Assets", assets);
            emit LogInt256("Bonus combined", liqResults.bonusCombined0);

            assertWithMsg(
                assets <= liqResults.bonusCombined0,
                "Liquidatee was debited incorrectly high bonus value (no funds leftover)"
            );
        }

        emit LogInt256(
            "Delta liquidator value",
            int256(liqResults.liquidatorValueAfter0) - int256(liqResults.liquidatorValueBefore0)
        );
        emit LogInt256("Bonus combined", liqResults.bonusCombined0);
        assertLt(
            abs(
                (int256(liqResults.liquidatorValueAfter0) -
                    int256(liqResults.liquidatorValueBefore0)) - liqResults.bonusCombined0
            ),
            10,
            "Liquidator did not receive correct bonus"
        );

        emit LogInt256(
            "Delta settled tokens",
            int256(burnSimResults.settledTokens0) - int256(liqResults.settledTokens0)
        );
        emit LogInt256(
            "Expected value",
            Math.min(burnSimResults.longPremium0, liqResults.protocolLoss0Expected)
        );
        assertWithMsg(
            int256(burnSimResults.settledTokens0) - int256(liqResults.settledTokens0) ==
                Math.min(burnSimResults.longPremium0, liqResults.protocolLoss0Expected),
            "Incorrect amount of premium was haircut"
        );

        emit LogInt256("Protocol loss actual", liqResults.protocolLoss0Actual);
        emit LogInt256(
            "Expected value",
            liqResults.protocolLoss0Expected -
                Math.min(burnSimResults.longPremium0, liqResults.protocolLoss0Expected)
        );
        assertWithMsg(
            liqResults.protocolLoss0Actual ==
                liqResults.protocolLoss0Expected -
                    Math.min(burnSimResults.longPremium0, liqResults.protocolLoss0Expected),
            "Not all premium was haircut during protocol loss"
        );

        log_account_collaterals(liquidator);
        log_account_collaterals(liquidatee);
        log_trackers_status();
    }

    /// @dev Liquidate by manually editing the storage. This function is not currently used, but we keep it for
    /// potential future usages
    function liquidate_option_via_edit(uint256 i_liquidated) internal {
        i_liquidated = bound(i_liquidated, 0, 4);
        if (userPositions[actors[i_liquidated]].length < 1) {
            emit LogString("No current positions");
            revert();
        }
        address liquidatee = actors[i_liquidated];
        address liquidator = msg.sender;

        int24 TWAPtick = PanopticMath.twapFilter(pool, 600);
        (, int24 curTick, , , , , ) = pool.slot0();
        emit LogInt256("TWAP tick", TWAPtick);
        emit LogInt256("Current tick", curTick);

        require(liquidatee != msg.sender);

        TokenId[] memory liquidated_positions = userPositions[liquidatee];
        TokenId[] memory liquidator_positions = userPositions[liquidator];

        require(liquidated_positions.length > 0);

        (, currentTick, , , , , ) = pool.slot0();
        LeftRightUnsigned lru = LeftRightUnsigned
            .wrap(uint96(collToken0.convertToAssets(collToken0.balanceOf(liquidator))))
            .toLeftSlot(uint96(collToken1.convertToAssets(collToken1.balanceOf(liquidator))));

        editCollateral(collToken0, liquidatee, 0);
        editCollateral(collToken1, liquidatee, 0);

        (uint256 balanceCross, uint256 thresholdCross) = _get_solvency_balances(
            liquidatee,
            TWAPtick
        );
        emit LogUint256("Balance cross after edit", balanceCross);
        emit LogUint256("Threshold cross after edit", thresholdCross);

        if (balanceCross >= thresholdCross) {
            hevm.prank(liquidator);
            try
                panopticPool.liquidate(liquidator_positions, liquidatee, lru, liquidated_positions)
            {
                assertWithMsg(
                    false,
                    "A non-liquidatable position (balanceCross >= thresholdCross) was liquidated"
                );
            } catch {}
            return;
        }

        emit LogUint256("liquidator positions length", liquidator_positions.length);
        emit LogUint256("liquidated positions length", liquidated_positions.length);
        emit LogAddress("liquidator", liquidator);
        emit LogAddress("liquidated", liquidatee);

        hevm.prank(liquidator);
        panopticPool.liquidate(liquidator_positions, liquidatee, lru, liquidated_positions);
    }

    /*//////////////////////////////////////////////////////////////
                                GLOBAL
    //////////////////////////////////////////////////////////////*/

    /// @custom:property PANO-SYS-006 Users can't have an open position but no collateral
    /// @custom:precondition The user has a position open
    function invariant_collateral_for_positions() public {
        // If user has positions open, the collateral must be greater than zero
        uint256 numOfPositions = panopticPool.numberOfPositions(msg.sender);
        emit LogAddress("Caller", msg.sender);
        emit LogUint256("Positions opened for user", numOfPositions);

        int128 premium0;
        int128 premium1;

        if (numOfPositions > 0) {
            uint256 bal0 = collToken0.balanceOf(msg.sender);
            uint256 bal1 = collToken1.balanceOf(msg.sender);
            emit LogUint256("Balance in token0", bal0);
            emit LogUint256("Balance in token1", bal1);

            bal0 = collToken0.convertToAssets(bal0);
            bal1 = collToken1.convertToAssets(bal1);
            emit LogUint256("Balance in token0 to assets", bal0);
            emit LogUint256("Balance in token1 to assets", bal1);

            (premium0, premium1, ) = panopticPool.calculateAccumulatedFeesBatch(
                msg.sender,
                true,
                userPositions[msg.sender]
            );
            emit LogInt256("Premia in token0", premium0);
            emit LogInt256("Premia in token1", premium1);

            assertWithMsg(
                ((int256(bal0) + premium0) > 0) || ((int256(bal1) + premium1) > 0),
                "User has open positions but zero collateral"
            );
        }
    }

    /// @custom:property PANO-SYS-007 The owed premia is not less than the available premia
    /// @custom:precondition The user has a position open
    function invariant_unsettled_premium() public {
        // Owed premia
        (int128 p0o, int128 p1o, ) = panopticPool.calculateAccumulatedFeesBatch(
            msg.sender,
            true,
            userPositions[msg.sender]
        );
        // Available premia
        (int128 p0a, int128 p1a, ) = panopticPool.calculateAccumulatedFeesBatch(
            msg.sender,
            false,
            userPositions[msg.sender]
        );

        emit LogAddress("Sender:", msg.sender);
        assertWithMsg(p0o >= p0a, "Token 0 owed premia is less than available premia");
        assertWithMsg(p1o >= p1a, "Token 1 owed premia is less than available premia");
    }
}
