// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "./FuzzHelpers.sol";

contract FuzzDeployments is FuzzHelpers {
    constructor() {
        // Actors
        // We have 5 actors
        // The addresses need to be the same than in the echidna.yaml
        // See sender: ["0xa11ce", "0xb0b", "0xcafe", "0xda210", "0xedda"]
        actors = new address[](5);
        actors[0] = address(0xa11ce);
        actors[1] = address(0xb0b);
        actors[2] = address(0xcafe);
        actors[3] = address(0xda210);
        actors[4] = address(0xedda);

        pool_manipulator = address(0xfaded);

        for (uint i = 0; i < actors.length; i++) {
            userPositions[actors[i]] = new TokenId[](0);
        }

        userPositions[pool_manipulator] = new TokenId[](0);

        univ3factory = IUniswapV3Factory(deployer.factory());
        emit LogAddress("UniV3 Factory", address(univ3factory));

        sfpm = new SemiFungiblePositionManager(univ3factory);
        emit LogAddress("Panoptic SFPM", address(sfpm));

        panopticHelper = new PanopticHelper(sfpm);
        emit LogAddress("Panoptic Helper", address(panopticHelper));

        // Import the Panoptic Pool reference (for cloning)
        poolReference = address(new PanopticPoolWrapper(sfpm));
        emit LogAddress("Panoptic Pool reference", address(poolReference));

        // Import the Collateral Tracker reference (for cloning)
        collateralReference = address(
            new CollateralTracker(10, 2_000, 1_000, -1_024, 5_000, 9_000, 20_000)
        );
        emit LogAddress("Panoptic Collateral reference", address(collateralReference));

        dnft = IDonorNFT(address(new DonorNFT()));
        emit LogAddress("DonorNFT", address(dnft));

        panopticFactory = new PanopticFactory(
            address(WETH),
            sfpm,
            univ3factory,
            dnft,
            poolReference,
            collateralReference
        );
        emit LogAddress("Panoptic Factory", address(panopticFactory));

        panopticFactory.initialize(address(this));
        DonorNFT(address(dnft)).changeFactory(address(panopticFactory));

        swapperc = new SwapperC();
        emit LogAddress("Panoptic Swapper", address(swapperc));

        emit LogAddress("USDC Token", address(USDC));
        emit LogAddress("WETH Token", address(WETH));
        emit LogAddress("USDC/WETH 5 pool", address(USDC_WETH_5));
        emit LogAddress("UniV3 router", address(router));

        initialize();

        deal_USDC(pool_manipulator, 1000000000 ether, true);
        deal_WETH(pool_manipulator, 1000000 ether);
        hevm.prank(pool_manipulator);
        IERC20(USDC).approve(address(pool), type(uint256).max);
        hevm.prank(pool_manipulator);
        IERC20(WETH).approve(address(pool), type(uint256).max);
        hevm.prank(pool_manipulator);
        IERC20(USDC).approve(address(swapperc), type(uint256).max);
        hevm.prank(pool_manipulator);
        IERC20(WETH).approve(address(swapperc), type(uint256).max);

        for (uint i = 0; i < 100; i++) {
            _perform_swap_with_delay(
                uint160(uint256(bytes32(keccak256(abi.encode(1, i))))),
                uint256(bytes32(keccak256(abi.encode(i))))
            );
        }
    }

    function initialize() internal {
        // initalize current pool we are deploying
        pool = USDC_WETH_5;
        poolFee = pool.fee();
        poolTickSpacing = pool.tickSpacing();

        assert(pool.token0() == address(USDC));
        assert(pool.token1() == address(WETH));

        // give test contract a sufficient amount of tokens to deploy a new pool
        deal_USDC(address(this), 10000000 ether, true);
        deal_WETH(address(this), 10000 ether);

        // Check: Make sure the correct balance is set to the contract
        assert(USDC.balanceOf(address(this)) == 10000000 ether);
        assert(WETH.balanceOf(address(this)) == 10000 ether);

        // approve factory to move tokens, on behalf of the test contract
        USDC.approve(address(panopticFactory), type(uint256).max);
        WETH.approve(address(panopticFactory), type(uint256).max);

        // approve sfpm to move tokens, on behalf of the test contract
        USDC.approve(address(sfpm), type(uint256).max);
        WETH.approve(address(sfpm), type(uint256).max);

        // approve self
        USDC.approve(address(this), type(uint256).max);
        WETH.approve(address(this), type(uint256).max);

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();

        sfpm.initializeAMMPool(pool.token0(), pool.token1(), poolFee);
        poolId = sfpm.getPoolId(address(pool));

        panopticPool = PanopticPoolWrapper(
            address(
                panopticFactory.deployNewPool(
                    pool.token0(),
                    pool.token1(),
                    poolFee,
                    bytes32(uint256(uint160(address(this))) << 96)
                )
            )
        );

        collToken0 = panopticPool.collateralToken0();
        collToken1 = panopticPool.collateralToken1();

        hevm.prank(address(collToken0));
        IERC20(collToken0.asset()).approve(address(pool), type(uint256).max);
        hevm.prank(address(collToken0));
        IERC20(collToken1.asset()).approve(address(pool), type(uint256).max);

        hevm.prank(address(collToken1));
        IERC20(collToken0.asset()).approve(address(pool), type(uint256).max);
        hevm.prank(address(collToken1));
        IERC20(collToken1.asset()).approve(address(pool), type(uint256).max);
    }

    ////////////////////////////////////////////////////
    // Funds and pool manipulation
    ////////////////////////////////////////////////////

    /// @dev Mint USDC and WETH to the sender and approve all the system contracts
    function fund_and_approve() public {
        deal_USDC(msg.sender, 10000000 ether, true);
        deal_WETH(msg.sender, 10000 ether);

        hevm.prank(msg.sender);
        IERC20(USDC).approve(address(router), type(uint256).max);
        hevm.prank(msg.sender);
        IERC20(WETH).approve(address(router), type(uint256).max);
        hevm.prank(msg.sender);
        IERC20(USDC).approve(address(panopticPool), type(uint256).max);
        hevm.prank(msg.sender);
        IERC20(WETH).approve(address(panopticPool), type(uint256).max);
        hevm.prank(msg.sender);
        IERC20(USDC).approve(address(collToken0), type(uint256).max);
        hevm.prank(msg.sender);
        IERC20(WETH).approve(address(collToken1), type(uint256).max);
    }

    /// @dev This function does a back to back swap. It is uses the generate premium. It's adapted from test/foundry/core/PanopticPool.t.sol
    function twoWaySwap(uint256 swapSize, uint256 numberOfSwaps, uint256 recipient) public {
        recipient = bound(recipient, 0, 4); // Index to the actors array
        swapSize = bound(swapSize, 10 ** 18, 10 ** 20);
        numberOfSwaps = bound(numberOfSwaps, 1, 15);

        address token0 = collToken0.asset();
        address token1 = collToken1.asset();

        for (uint256 i = 0; i < numberOfSwaps; ++i) {
            hevm.prank(msg.sender);
            router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams(
                    token0,
                    token1,
                    poolFee,
                    actors[recipient],
                    block.timestamp,
                    swapSize,
                    0,
                    0
                )
            );

            hevm.prank(msg.sender);
            router.exactOutputSingle(
                ISwapRouter.ExactOutputSingleParams(
                    token1,
                    token0,
                    poolFee,
                    actors[recipient],
                    block.timestamp,
                    (swapSize * (1_000_000 - poolFee)) / 1_000_000,
                    type(uint256).max,
                    0
                )
            );
        }

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();
    }

    ////////////////////////////////////////////////////
    // Minting
    ////////////////////////////////////////////////////

    function mint_option_basic(
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
            // already working
            // for (uint256 i = 0; i < $numLegs; ++i) {
            //     assertWithMsg($isLongs[i] != 1, "success!");
            // }

            assertWithMsg(!$shouldRevert, "mintOptions: missing revert");
        } catch (bytes memory reason) {
            emit LogBytes("Reason", reason);

            assertWithMsg($shouldRevert, "mintOptions: unexpected revert");

            // reverse test state changes (i.e. positionidlist)
            revert();
        }

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

    function perform_swap(uint160 target_sqrt_price) public {
        uint160 price;

        (price, , , , , , ) = pool.slot0();

        // bound the price between 10 and 500000 and 50% of the current price
        target_sqrt_price = uint160(
            bound(
                price,
                uint256(
                    Math.max(
                        int256(Math.mulDiv(price, 7_071, 10_000)),
                        112028621795169773357271145775104
                    )
                ),
                uint256(
                    Math.min(
                        int256(Math.mulDiv(price, 14_142, 10_000)),
                        25054084147398268684193622782902272
                    )
                )
            )
        );

        int24 TWAPtick_before = PanopticMath.twapFilter(pool, 600);
        emit LogUint256("price before swap", uint256(price));

        hevm.prank(pool_manipulator);
        swapperc.swapTo(pool, target_sqrt_price);

        update_twap();

        (price, , , , , , ) = pool.slot0();
        emit LogUint256("price after swap", uint256(price));
    }

    function _perform_swap_with_delay(uint160 target_sqrt_price, uint256 delay) internal {
        // bound the price between 10 and 500000
        target_sqrt_price = uint160(
            bound(
                target_sqrt_price,
                112028621795169773357271145775104,
                25054084147398268684193622782902272
            )
        );

        uint160 price;

        int24 currentTick;
        (price, currentTick, , , , , ) = pool.slot0();

        emit LogInt256("tick before swap", currentTick);
        emit LogUint256("price before swap", uint256(price));

        uint256 delay_on = (delay % 2 == 0) ? 1 : 0;
        uint256 delay_block = bound(delay, 0, 150);

        emit LogUint256("number of block delayed", delay_block);

        hevm.prank(pool_manipulator);
        swapperc.swapTo(pool, target_sqrt_price);
        hevm.warp(block.timestamp + delay_on * delay_block * 12);
        hevm.roll(block.number + delay_on * delay_block);

        // Do another random mint+burn
        delay_on = ((delay >> 4) % 2) == 0 ? 1 : 0;
        if (delay_on == 1) {
            hevm.prank(pool_manipulator);
            swapperc.mint(pool, -10, 10, 10 ** 18);
            hevm.prank(pool_manipulator);
            swapperc.burn(pool, -10, 10, 10 ** 18);
        }

        (price, currentTick, , , , , ) = pool.slot0();
        emit LogInt256("tick after swap", currentTick);
        emit LogUint256("price after swap", uint256(price));
    }

    function perform_swap_no_delay(uint160 target_sqrt_price) public {
        // bound the price between 10 and 500000
        target_sqrt_price = uint160(
            bound(
                target_sqrt_price,
                112028621795169773357271145775104,
                25054084147398268684193622782902272
            )
        );

        uint160 price;

        int24 currentTick;
        (price, currentTick, , , , , ) = pool.slot0();

        emit LogInt256("tick before swap", currentTick);
        emit LogUint256("price before swap", uint256(price));
        int24 TWAPtick_before = PanopticMath.twapFilter(pool, 600);
        emit LogInt256("TWAP tick before", TWAPtick_before);

        hevm.prank(pool_manipulator);
        swapperc.swapTo(pool, target_sqrt_price);

        (price, currentTick, , , , , ) = pool.slot0();
        emit LogInt256("tick after swap", currentTick);
        emit LogUint256("price after swap", uint256(price));
        int24 TWAPtick_after = PanopticMath.twapFilter(pool, 600);
        emit LogInt256("TWAP tick after", TWAPtick_after);
    }

    function update_twap() public {
        int24 TWAPtick_before = PanopticMath.twapFilter(pool, 600);
        emit LogInt256("TWAP tick before", TWAPtick_before);

        // update twaps
        //for (uint256 i = 0; i < 20; ++i) {
        hevm.warp(block.timestamp + 1000);
        hevm.roll(block.number + 100);
        hevm.prank(pool_manipulator);
        swapperc.mint(pool, -10, 10, 10 ** 18);
        hevm.prank(pool_manipulator);
        swapperc.burn(pool, -10, 10, 10 ** 18);
        //}

        int24 TWAPtick_after = PanopticMath.twapFilter(pool, 600);
        emit LogInt256("TWAP tick after", TWAPtick_after);
    }

    ////////////////////////////////////////////////////
    // Burning
    ////////////////////////////////////////////////////

    /// @custom:property PANO-BURN-001 Zero sized positions can not be burned
    /// @custom:property PANO-BURN-002 Current liquidity must be greater than the liquidity in the chunk for the position
    /// @custom:property PANO-BURN-002 Position opened counter must decrease when a position is burned
    /// @custom:precondition The user has a position open
    function burn_one_option(uint256 pos_idx, bool is_covered) public {
        address caller = msg.sender;
        uint256 positions_opened = panopticPool.numberOfPositions(caller);
        require(positions_opened > 0);
        pos_idx = bound(pos_idx, 0, userPositions[caller].length - 1);

        emit LogString("Burning one option");
        emit LogAddress("Caller", caller);
        emit LogUint256("Positions opened for user", panopticPool.numberOfPositions(caller));
        emit LogUint256("Positions to be burned", pos_idx);

        TokenId position = userPositions[caller][pos_idx];
        TokenId[] memory positions_new = _get_list_without_tokenid(userPositions[caller], position);

        (uint128 posSize, , ) = panopticPool.optionPositionBalance(caller, position);
        LiquidityChunk liquidityChunk = PanopticMath.getLiquidityChunk(position, 0, posSize);
        LeftRightUnsigned currentLiquidity = sfpm.getAccountLiquidity(
            address(pool),
            address(panopticPool),
            position.tokenType(0),
            liquidityChunk.tickLower(),
            liquidityChunk.tickUpper()
        );

        emit LogUint256("Position size", posSize);
        emit LogUint256("Position isLong", position.isLong(0));
        emit LogUint256("Current Liquidity", currentLiquidity.rightSlot());
        emit LogUint256("LiqChunk Liquidity", liquidityChunk.liquidity());
        emit LogInt256("LiqChunk tickUpper", liquidityChunk.tickUpper());
        emit LogInt256("LiqChunk tickLower", liquidityChunk.tickLower());
        int24 tickLimitLow = is_covered ? int24(-887272) : int24(887272);
        int24 tickLimitHigh = is_covered ? int24(887272) : int24(-887272);

        if (posSize == 0) {
            hevm.prank(caller);
            try panopticPool.burnOptions(position, positions_new, tickLimitLow, tickLimitHigh) {
                assertWithMsg(false, "A zero-sized position was burned.");
            } catch {}
            return;
        }

        if (position.isLong(0) == 0 && currentLiquidity.rightSlot() < liquidityChunk.liquidity()) {
            hevm.prank(caller);
            try panopticPool.burnOptions(position, positions_new, tickLimitLow, tickLimitHigh) {
                assertWithMsg(false, "A short position with not enough liquidity was burned.");
            } catch {}
            return;
        }

        int256 balanceBefore = int256(_get_assets_in_token0(caller, currentTick));
        emit LogInt256("User Balance before burning in token0 terms", balanceBefore);

        hevm.prank(caller);
        panopticPool.burnOptions(position, positions_new, tickLimitLow, tickLimitHigh);

        assertWithMsg(
            panopticPool.numberOfPositions(caller) == positions_opened - 1,
            "Burning a position did not decrease the position counter"
        );

        int256 balanceAfter = int256(_get_assets_in_token0(caller, currentTick));
        emit LogInt256("User Balance after burning in token0 terms", balanceAfter);

        emit LogInt256("Delta balance", balanceAfter - balanceBefore);

        userPositions[caller] = positions_new;
    }

    /// @custom:property PANO-BURN-003 After burning all options, the number of positions of the user must be zero
    /// @custom:precondition The user has at least one position open
    function burn_all_options(bool is_covered) public {
        address caller = msg.sender;
        TokenId[] memory emptyList;

        if (userPositions[caller].length < 1) {
            emit LogString("No current positions");
            revert();
        }
        int24 tickLimitLow = is_covered ? int24(-887272) : int24(887272);
        int24 tickLimitHigh = is_covered ? int24(887272) : int24(-887272);

        hevm.prank(caller);
        try
            panopticPool.burnOptions(userPositions[caller], emptyList, tickLimitLow, tickLimitHigh)
        {
            delete userPositions[caller];
            assertWithMsg(
                panopticPool.numberOfPositions(caller) == 0,
                "Not all positions were burned"
            );
        } catch {}
    }

    ////////////////////////////////////////////////////
    // Liquidation
    ////////////////////////////////////////////////////

    /// @custom:property PANO-LIQ-001 The position to liquidate must have a balance below the threshold
    /// @custom:property PANO-LIQ-002 After liquidation, user must have zero open positions
    /// @custom:precondition The liquidatee has a liquidatable position open
    function try_liquidate_option(uint256 i_liquidated) public {
        i_liquidated = bound(i_liquidated, 0, 4);

        address liquidatee = actors[i_liquidated];
        address liquidator = msg.sender;
        uint256 canary_index = bound(i_liquidated, 0, 4);
        if (actors[canary_index] == msg.sender || actors[canary_index] == liquidatee) {
            canary_index = bound(i_liquidated + 1, 0, 4);
        }

        address canary = actors[canary_index];

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
            deposit_to_ct(true, lb0);
            hevm.prank(liquidator);
            deposit_to_ct(false, lb1);
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
        log_account_collaterals(canary);
        log_trackers_status();

        LeftRightUnsigned canaryBalances;
        {
            uint256 c0b = collToken0.convertToAssets(collToken0.balanceOf(canary));
            uint256 c1b = collToken1.convertToAssets(collToken1.balanceOf(canary));

            canaryBalances = LeftRightUnsigned.wrap(0).toRightSlot(uint128(c0b)).toLeftSlot(
                uint128(c1b)
            );
        }
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

        liqResults.liquidatorValueBefore0 = _get_assets_in_token0(liquidator, currentTickOld);
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

        hevm.prank(liquidator);
        panopticPool.liquidate(liquidator_positions, liquidatee, delegations, liquidated_positions);

        currentTickOld = currentTick;
        (, currentTick, , , , , ) = pool.slot0();

        emit LogInt256("final tick", currentTick);
        _calculate_liquidation_bonus(TWAPtick, currentTick);

        burnSimResults.delegated0 = uint256(
            int256(
                collToken0.convertToShares(
                    uint256(int256(uint256(uint96(burnSimResults.delegated0))) + liqResults.bonus0)
                )
            )
        );
        burnSimResults.delegated1 = uint256(
            int256(
                collToken1.convertToShares(
                    uint256(int256(uint256(uint96(burnSimResults.delegated0))) + liqResults.bonus1)
                )
            )
        );

        liqResults.sharesD0 =
            burnSimResults.shareDelta0 -
            (int256(collToken0.balanceOf(liquidatee)) - liqResults.sharesD0);
        liqResults.sharesD1 =
            burnSimResults.shareDelta1 -
            (int256(collToken1.balanceOf(liquidatee)) - liqResults.sharesD1);
        liqResults.liquidatorValueAfter0 = _get_assets_in_token0(liquidator, currentTick); // currentTickOld

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
        /*
    assertLt(
        abs(
            (int256(liqResults.liquidatorValueAfter0) -
                int256(liqResults.liquidatorValueBefore0)) - liqResults.bonusCombined0
        ),
        10,
        "Liquidator did not receive correct bonus"
    );
        premium was haircut during protoco*/
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
        /*
    assertLt(
        abs(
            liqResults.protocolLoss0Actual -
                (liqResults.protocolLoss0Expected -
                    Math.min(burnSimResults.longPremium0, liqResults.protocolLoss0Expected))
        ),
        10,
        "Not all premium was haircut during protocol loss"
    );
    */
        log_account_collaterals(liquidator);
        log_account_collaterals(liquidatee);
        log_account_collaterals(canary);
        log_trackers_status();

        {
            uint256 c0a = collToken0.convertToAssets(collToken0.balanceOf(canary));
            uint256 c1a = collToken1.convertToAssets(collToken1.balanceOf(canary));
            emit LogUint256("balanceBefore0", canaryBalances.rightSlot());
            emit LogUint256("balanceBefore1", canaryBalances.leftSlot());
            emit LogUint256("balanceAfter0", c0a);
            emit LogUint256("balanceAfter1", c1a);
            //assertWithMsg(c0a < canaryBalances.rightSlot(), "protocol loss token0");
            //assertWithMsg(c1a < canaryBalances.leftSlot(), "protocol loss token1");
        }
    }

    /////////////////////////////////////////////////////////////
    // System Invariants
    /////////////////////////////////////////////////////////////

    /// @custom:property PANO-SYS-001 The max withdrawal amount of users with open positions is zero
    /// @custom:property PANO-SYS-002 Users can't withdraw collateral with open positions
    /// @custom:precondition The user has a position open
    function invariant_collateral_removal() public {
        // If user has positions open, they cannot remove collateral
        uint256 numOfPositions = panopticPool.numberOfPositions(msg.sender);
        emit LogAddress("Caller", msg.sender);
        emit LogUint256("Positions opened for user", numOfPositions);

        if (numOfPositions > 0) {
            uint256 bal0 = collToken0.convertToAssets(collToken0.balanceOf(msg.sender));
            uint256 bal1 = collToken1.convertToAssets(collToken0.balanceOf(msg.sender));
            emit LogUint256("Balance in token0", bal0);
            emit LogUint256("Balance in token1", bal1);

            assertWithMsg(
                collToken0.maxWithdraw(msg.sender) == 0,
                "It is possible to withdraw assets when the user has open positions"
            );
            assertWithMsg(
                collToken1.maxWithdraw(msg.sender) == 0,
                "It is possible to withdraw assets when the user has open positions"
            );

            if (bal0 > 0) {
                try collToken0.withdraw(bal0, msg.sender, msg.sender) {
                    assertWithMsg(false, "Collateral could be removed with open positions");
                } catch {}
            }
            if (bal1 > 0) {
                try collToken1.withdraw(bal1, msg.sender, msg.sender) {
                    assertWithMsg(false, "Collateral could be removed with open positions");
                } catch {}
            }
        }
    }

    /// @custom:property PANO-SYS-003 Users can't have an open position but no collateral
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

    /// @custom:property PANO-SYS-004 The owed premia is not less than the available premia
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

    /////////////////////////////////////////////////////////////
    // External function wrappers
    /////////////////////////////////////////////////////////////

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        require(msg.sender == address(pool));

        address caller = abi.decode(data, (address));

        if (amount0Delta > 0) {
            hevm.prank(caller);
            USDC.transfer(msg.sender, uint256(amount0Delta));
        } else {
            hevm.prank(caller);
            WETH.transfer(msg.sender, uint256(amount1Delta));
        }
    }

    function wrapper_pokeMedian() public {
        hevm.prank(msg.sender);
        panopticPool.pokeMedian();
    }

    function wrapper_swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) public {
        hevm.prank(msg.sender);
        pool.swap(
            recipient,
            zeroForOne,
            amountSpecified,
            sqrtPriceLimitX96,
            abi.encode(msg.sender)
        );
    }

    ////////////////////////////////////////////////////
    // Interaction with collateral trackers
    ////////////////////////////////////////////////////

    /// @custom:property PANO-DEP-001 The Panoptic pool balance must increase by the deposited amount when a deposit is made
    /// @custom:property PANO-DEP-002 The user balance must decrease by the deposited amount when a deposit is made
    function deposit_to_ct(bool token0, uint256 amount) public {
        address depositor = msg.sender;

        uint256 bal0 = IERC20(collToken0.asset()).balanceOf(depositor);
        uint256 bal1 = IERC20(collToken1.asset()).balanceOf(depositor);

        uint256 pool_bal0 = IERC20(collToken0.asset()).balanceOf(address(panopticPool));
        uint256 pool_bal1 = IERC20(collToken1.asset()).balanceOf(address(panopticPool));

        amount = bound(amount, 1, MAX_DEPOSIT);

        if (token0) {
            // Limit the maximum amount of collateral to deposit
            if (collToken0.convertToAssets(collToken0.balanceOf(depositor)) > 10 * MAX_DEPOSIT) {
                return;
            }
            amount = bound(amount, MIN_DEPOSIT, min(MAX_DEPOSIT, bal0 / 10));
            hevm.prank(depositor);
            collToken0.deposit(amount, depositor);

            uint256 pool_bal0_after = IERC20(collToken0.asset()).balanceOf(address(panopticPool));
            assertWithMsg(
                pool_bal0_after - pool_bal0 == amount,
                "Pool token0 balance incorrect after deposit"
            );
            uint256 bal0_after = IERC20(collToken0.asset()).balanceOf(depositor);
            assertWithMsg(
                bal0 - bal0_after == amount,
                "User token0 balance incorrect after deposit"
            );
        } else {
            // Limit the maximum amount of collateral to deposit
            if (collToken1.convertToAssets(collToken1.balanceOf(depositor)) > 10 * MAX_DEPOSIT) {
                return;
            }
            amount = bound(amount, MIN_DEPOSIT, min(MAX_DEPOSIT, bal1 / 10));
            hevm.prank(depositor);
            collToken1.deposit(amount, depositor);

            uint256 pool_bal1_after = IERC20(collToken1.asset()).balanceOf(address(panopticPool));
            assertWithMsg(
                pool_bal1_after - pool_bal1 == amount,
                "Pool token1 balance incorrect after deposit"
            );
            uint256 bal1_after = IERC20(collToken1.asset()).balanceOf(depositor);
            assertWithMsg(
                bal1 - bal1_after == amount,
                "User token0 balance incorrect after deposit"
            );
        }
    }

    /// @custom:property PANO-WIT-001 The Panoptic pool balance must decrease by the withdrawn amount when a withdrawal is made
    /// @custom:property PANO-WIT-002 The user balance must increase by the withdrawn amount when a withdrawal is made
    function withdraw_from_ct(bool token0, uint256 amount) public {
        address withdrawer = msg.sender;

        uint256 bal0 = IERC20(collToken0.asset()).balanceOf(withdrawer);
        uint256 bal1 = IERC20(collToken1.asset()).balanceOf(withdrawer);

        uint256 pool_bal0 = IERC20(collToken0.asset()).balanceOf(address(panopticPool));
        uint256 pool_bal1 = IERC20(collToken1.asset()).balanceOf(address(panopticPool));

        if (token0) {
            amount = bound(amount, 1, collToken0.convertToAssets(collToken0.balanceOf(withdrawer)));
            hevm.prank(withdrawer);
            collToken0.withdraw(amount, withdrawer, withdrawer);

            uint256 pool_bal0_after = IERC20(collToken0.asset()).balanceOf(address(panopticPool));
            assertWithMsg(
                pool_bal0 - pool_bal0_after == amount,
                "Pool token0 balance incorrect after withdrawal"
            );
            uint256 bal0_after = IERC20(collToken0.asset()).balanceOf(withdrawer);
            assertWithMsg(
                bal0_after - bal0 == amount,
                "User token0 balance incorrect after deposit"
            );
        } else {
            amount = bound(amount, 1, collToken1.convertToAssets(collToken1.balanceOf(withdrawer)));
            hevm.prank(withdrawer);
            collToken1.withdraw(amount, withdrawer, withdrawer);

            uint256 pool_bal1_after = IERC20(collToken1.asset()).balanceOf(address(panopticPool));
            assertWithMsg(
                pool_bal1 - pool_bal1_after == amount,
                "Pool token1 balance incorrect after withdrawal"
            );
            uint256 bal1_after = IERC20(collToken1.asset()).balanceOf(withdrawer);
            assertWithMsg(
                bal1_after - bal1 == amount,
                "User token0 balance incorrect after deposit"
            );
        }
    }

    function redeem_from_ct(bool token0, uint256 amount) public {
        if (token0) {
            amount = bound(amount, 1, collToken0.balanceOf(msg.sender));
            hevm.prank(msg.sender);
            collToken0.redeem(amount, msg.sender, msg.sender);
        } else {
            amount = bound(amount, 1, collToken1.balanceOf(msg.sender));
            hevm.prank(msg.sender);
            collToken1.redeem(amount, msg.sender, msg.sender);
        }
    }

    /////////////////////////////////////////////////////////////
    // Legacy functions (deactivated)
    /////////////////////////////////////////////////////////////

    /// Adapted from test/foundry/core/PanopticPool.t.sol
    /// Because Echidna does not handle vm.deal for ERC20
    function editCollateral(CollateralTracker ct, address owner, uint256 newShares) internal {
        int256 shareDelta = int256(newShares) - int256(ct.balanceOf(owner));
        int256 assetDelta = convertToAssets(ct, shareDelta);
        hevm.store(
            address(ct),
            bytes32(uint256(7)),
            bytes32(
                uint256(
                    LeftRightSigned.unwrap(
                        LeftRightSigned
                            .wrap(int256(uint256(hevm.load(address(ct), bytes32(uint256(7))))))
                            .add(LeftRightSigned.wrap(assetDelta))
                    )
                )
            )
        );

        if (ct.asset() == address(USDC)) {
            alter_USDC(
                address(ct),
                uint256(int256(IERC20(ct.asset()).balanceOf(address(ct))) + assetDelta)
            );
        } else {
            alter_WETH(
                address(ct),
                uint256(int256(IERC20(ct.asset()).balanceOf(address(ct))) + assetDelta)
            );
        }

        deal_Generic(address(ct), 1, owner, newShares, true, 0); // deal(address(ct), owner, newShares, true);
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
}
