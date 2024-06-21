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
    // Leg generation
    ////////////////////////////////////////////////////

    /// @dev Generate a single leg
    function _generate_single_leg_tokenid(
        bool asset_in,
        bool is_call_in,
        bool is_long_in,
        bool is_otm_in,
        uint24 width_in,
        int256 strike_in
    ) internal returns (TokenId out) {
        out = TokenId.wrap(poolId);

        // Rest of the parameters come from the function parameters
        uint256 asset = asset_in == true ? 1 : 0;
        uint256 call_put = is_call_in == true ? 1 - asset : asset;
        uint256 long_short = is_long_in == true ? 1 : 0;

        int24 width;
        int24 strike;

        if (is_otm_in) {
            (width, strike) = getOTMSW(
                width_in,
                strike_in,
                uint24(poolTickSpacing),
                currentTick,
                call_put
            );
        } else {
            (width, strike) = getITMSW(
                width_in,
                strike_in,
                uint24(poolTickSpacing),
                currentTick,
                call_put
            );
        }

        out = out.addLeg(0, 1, asset, long_short, call_put, 0, strike, width);
        log_tokenid_leg(out, 0);
    }

    function _generate_multiple_leg_tokenid(
        uint256 numLegs,
        bool[4] memory asset_in,
        bool[4] memory is_call_in,
        bool[4] memory is_long_in,
        bool[4] memory is_otm_in,
        uint24[4] memory width_in,
        int256[4] memory strike_in
    ) internal returns (TokenId out) {
        out = TokenId.wrap(poolId);
        numLegs = bound(numLegs, 1, 4);

        // The parameters come from the function parameters
        for (uint256 i = 0; i < numLegs; i++) {
            uint256 asset = asset_in[i] == true ? 1 : 0;
            uint256 call_put = is_call_in[i] == true ? 1 - asset : asset;
            uint256 long_short = is_long_in[i] == true ? 1 : 0;

            int24 width;
            int24 strike;

            if (is_otm_in[i]) {
                (width, strike) = getOTMSW(
                    width_in[i],
                    strike_in[i],
                    uint24(poolTickSpacing),
                    currentTick,
                    call_put
                );
            } else {
                (width, strike) = getITMSW(
                    width_in[i],
                    strike_in[i],
                    uint24(poolTickSpacing),
                    currentTick,
                    call_put
                );
            }

            out = out.addLeg(i, 1, asset, long_short, call_put, 0, strike, width);
            log_tokenid_leg(out, i);
        }
    }

    function _generate_straddle_tokenid(
        bool asset_in,
        bool is_long_in,
        uint24 width_in,
        int256 strike_in
    ) internal returns (TokenId out) {
        out = TokenId.wrap(poolId);

        uint256 asset = asset_in == true ? 1 : 0;
        uint256 long_short = is_long_in == true ? 1 : 0;

        int24 width;
        int24 strike;

        (width, strike) = getOTMSW(width_in, strike_in, uint24(poolTickSpacing), currentTick, 0);

        // Create call
        out = out.addLeg(0, 1, asset, long_short, 1 - asset, 1, strike, width);
        // Create put
        out = out.addLeg(1, 1, asset, long_short, asset, 0, strike, width);

        log_tokenid_leg(out, 0);
        log_tokenid_leg(out, 1);
    }

    function _generate_strangle_tokenid(
        bool asset_in,
        bool is_long_in,
        uint24 width_in,
        int256 strike_in,
        int24 strike_delta
    ) internal returns (TokenId out) {
        out = TokenId.wrap(poolId);

        uint256 asset = asset_in == true ? 1 : 0;
        uint256 long_short = is_long_in == true ? 1 : 0;

        (int24 width_sc, int24 strike_sc) = getOTMSW(
            width_in,
            strike_in,
            uint24(poolTickSpacing),
            currentTick,
            asset
        );
        (, int24 strike_sp) = getOTMSW(
            width_in,
            strike_in,
            uint24(poolTickSpacing),
            currentTick,
            1 - asset
        );

        // Create call
        out = out.addLeg(0, 1, asset, long_short, 1 - asset, 1, strike_sc + strike_delta, width_sc);
        // Create put
        out = out.addLeg(1, 1, asset, long_short, asset, 0, strike_sp - strike_delta, width_sc);

        log_tokenid_leg(out, 0);
        log_tokenid_leg(out, 1);
    }

    ////////////////////////////////////////////////////
    // Minting
    ////////////////////////////////////////////////////

    /// @custom:property PANO-MINT-001 For long positions, the effective liquidity factor must be lower than or equal to the liquidity limit
    /// @custom:property PANO-MINT-002 The position balance for the minted position must equal the position size
    /// @custom:property PANO-MINT-003 Users cannot have more than 32 simultaneous positions opened
    /// @custom:property PANO-MINT-004 The position counter must increase after a successful mint
    function _mint_option(
        address minter,
        TokenId tokenid,
        uint256 posSize,
        uint64 effLiqLim
    ) internal {
        // Mint a position according to tokenid and posSize
        uint256 userCollateral;

        if (tokenid.tokenType(0) == 0) {
            userCollateral = collToken0.convertToAssets(collToken0.balanceOf(minter));
            emit LogUint256("User collateral 0", userCollateral);
        } else {
            userCollateral = collToken1.convertToAssets(collToken1.balanceOf(minter));
            emit LogUint256("User collateral 1", userCollateral);
        }
        posSize = bound(posSize, (userCollateral * 60) / 100, (userCollateral * 400) / 100);
        require(posSize > 0);

        uint256 positionsOpened = panopticPool.numberOfPositions(minter);
        emit LogUint256("Positions opened for user", positionsOpened);

        userPositions[minter].push(tokenid);
        TokenId[] memory posIdList = userPositions[minter];
        TokenId[] memory lastPos = new TokenId[](1);
        lastPos[0] = tokenid;

        if (tokenid.isLong(0) == 1) {
            (int24 tickLower, int24 tickUpper) = tokenid.asTicks(0);
            uint64 effLiqFactor = _get_effective_liq_factor(
                tokenid.tokenType(0),
                tickLower,
                tickUpper
            );

            emit LogUint256("Effective liquidity limit", effLiqLim);
            emit LogUint256("Effective liquidity factor", effLiqFactor);

            hevm.prank(minter);
            try panopticPool.mintOptions(posIdList, uint128(posSize), effLiqLim, 0, 0) {
                // Option was minted
                assertWithMsg(
                    effLiqFactor <= effLiqLim,
                    "A long position with liquidity factor greater than the liquidity limit was minted"
                );
            } catch {
                revert();
            }
        } else {
            hevm.prank(minter);
            panopticPool.mintOptions(posIdList, uint128(posSize), 0, 0, 0);
        }

        assertWithMsg(positionsOpened < 32, "More than 32 positions are minted for user");
        assertWithMsg(
            panopticPool.numberOfPositions(minter) == positionsOpened + 1,
            "Position counter did not increase after minting"
        );

        userBalance[minter][tokenid] = LeftRightUnsigned.wrap(0).toRightSlot(uint128(posSize));

        (uint128 balance, , ) = panopticPool.optionPositionBalance(minter, tokenid);
        assertWithMsg(balance == posSize, "Position size and balance do not match");

        emit LogInt256("Balance after", int256(_get_assets_in_token0(minter, currentTick)));
        emit LogString("Minted a new option");
        emit LogUint256("Position size", posSize);
        emit LogAddress("Minter", minter);
    }

    function mint_option(
        uint256 seller_index,
        bool asset,
        bool is_call,
        bool is_long,
        bool is_otm,
        uint64 effLiqLimit,
        uint24 width,
        int256 strike,
        uint256 posSize
    ) public {
        seller_index = bound(seller_index, 0, 4);
        if (actors[seller_index] == msg.sender) {
            seller_index = bound(seller_index + 1, 0, 4);
        }

        address minter = msg.sender;
        address seller = actors[seller_index];

        (, currentTick, , , , , ) = pool.slot0();

        if (!is_long) {
            // Mint a short position
            _mint_option(
                minter,
                _generate_single_leg_tokenid(asset, is_call, false, is_otm, width, strike),
                posSize,
                0
            );
        } else {
            // Mint a short position first, then a long position
            _mint_option(
                seller,
                _generate_single_leg_tokenid(asset, is_call, false, is_otm, width, strike),
                (12 * posSize) / 10,
                0
            );
            _mint_option(
                minter,
                _generate_single_leg_tokenid(asset, is_call, true, is_otm, width, strike),
                posSize,
                effLiqLimit
            );
        }
    }

    function mint_strategy(
        bool asset,
        bool is_long,
        uint256 strategy,
        uint24 width,
        int256 strike,
        uint256 posSize
    ) public {
        // We have two strategies now, this can be expanded later
        strategy = bound(strategy, 0, 1);

        address minter = msg.sender;

        (, currentTick, , , , , ) = pool.slot0();

        if (strategy == 0) {
            // Mint a strangle
            TokenId strangle = _generate_strangle_tokenid(asset, is_long, width, strike, 10); // Fixed delta of 10, can be changed/fuzzed
            _mint_option(minter, strangle, posSize, 0);
        } else if (strategy == 1) {
            // Mint a straddle
            TokenId straddle = _generate_straddle_tokenid(asset, is_long, width, strike);
            _mint_option(minter, straddle, posSize, 0);
        }
    }

    function perform_swap(uint160 target_sqrt_price) public {
        // bound the price between 10 and 500000
        target_sqrt_price = uint160(
            bound(
                target_sqrt_price,
                112028621795169773357271145775104,
                25054084147398268684193622782902272
            )
        );

        uint160 price;

        (price, , , , , , ) = pool.slot0();

        int24 TWAPtick_before = PanopticMath.twapFilter(pool, 600);
        emit LogInt256("TWAP tick after", TWAPtick_before);

        emit LogUint256("price before swap", uint256(price));

        hevm.prank(pool_manipulator);
        swapperc.swapTo(pool, target_sqrt_price);
        hevm.warp(block.timestamp + 1000);
        hevm.roll(block.number + 100);

        hevm.prank(pool_manipulator);
        swapperc.mint(pool, -10, 10, 10 ** 18);
        hevm.prank(pool_manipulator);
        swapperc.burn(pool, -10, 10, 10 ** 18);

        (price, , , , , , ) = pool.slot0();
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
    function burn_one_option(uint256 pos_idx) public {
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

        if (posSize == 0) {
            hevm.prank(caller);
            try panopticPool.burnOptions(position, positions_new, 0, 0) {
                assertWithMsg(false, "A zero-sized position was burned.");
            } catch {}
            return;
        }

        if (position.isLong(0) == 0 && currentLiquidity.rightSlot() < liquidityChunk.liquidity()) {
            hevm.prank(caller);
            try panopticPool.burnOptions(position, positions_new, 0, 0) {
                assertWithMsg(false, "A short position with not enough liquidity was burned.");
            } catch {}
            return;
        }

        int256 balanceBefore = int256(_get_assets_in_token0(caller, currentTick));
        emit LogInt256("User Balance before burning in token0 terms", balanceBefore);

        hevm.prank(caller);
        panopticPool.burnOptions(position, positions_new, 0, 0);

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
    function burn_all_options() public {
        address caller = msg.sender;
        TokenId[] memory emptyList;

        if (userPositions[caller].length < 1) {
            emit LogString("No current positions");
            revert();
        }

        hevm.prank(caller);
        try
            panopticPool.burnOptions(
                userPositions[caller],
                emptyList,
                type(int24).min,
                type(int24).max
            )
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

    /////////////////////////////////////////////////////////////
    // System Invariants
    /////////////////////////////////////////////////////////////

    /// @custom:property PANO-SYS-001 The max withdrawal or redemption amount of users with open positions is zero, excluding the overloaded withdraw that takes in a positionId list
    /// @custom:property PANO-SYS-002 Users can't withdraw or redeem collateral with open positions, excluding the overloaded withdraw that takes in a positionId list
    /// @custom:precondition The user has a position open
    function invariant_collateral_removal_via_withdrawal_or_redemption(
        uint256 fuzzNumerator,
        uint256 fuzzDenominator,
        address recipient
    ) public {
        uint256 numOfPositions = panopticPool.numberOfPositions(msg.sender);
        emit LogAddress("Caller", msg.sender);
        emit LogUint256("Positions opened for user", numOfPositions);

        if (numOfPositions > 0) {
            uint256 shareBal0 = collToken0.balanceOf(msg.sender);
            uint256 shareBal1 = collToken1.balanceOf(msg.sender);
            uint assetBal0 = collToken0.convertToAssets(shareBal0);
            uint assetBal1 = collToken1.convertToAssets(shareBal1);

            assertWithMsg(
                collToken0.maxWithdraw(msg.sender) == 0 && collToken1.maxWithdraw(msg.sender) == 0,
                "It is possible to withdraw assets when the user has open positions"
            );
            assertWithMsg(
                collToken0.maxRedeem(msg.sender) == 0 && collToken1.maxRedeem(msg.sender) == 0,
                "It is possible to redeem assets when the user has open positions"
            );

            // fuzz a fraction of the total balance to try and withdraw
            if (fuzzNumerator > fuzzDenominator)
                (fuzzNumerator, fuzzDenominator) = (fuzzDenominator, fuzzNumerator);

            // attempt a full withdrawal every 3rd block, and a self-withdrawal every 5th block, to ensure we're testing those cases
            if (block.number % 3 == 0) fuzzNumerator = fuzzDenominator;
            if (block.number % 5 == 0) recipient = msg.sender;

            uint256 fuzzedSharesToRedeem0 = (shareBal0 * fuzzNumerator) / fuzzDenominator;
            uint256 fuzzedSharesToRedeem1 = (shareBal1 * fuzzNumerator) / fuzzDenominator;

            uint256 fuzzedAssetsToWithdraw0 = (assetBal0 * fuzzNumerator) / fuzzDenominator;
            uint256 fuzzedAssetsToWithdraw1 = (assetBal1 * fuzzNumerator) / fuzzDenominator;

            if (fuzzedAssetsToWithdraw0 > 0) {
                try collToken0.redeem(fuzzedSharesToRedeem0, recipient, msg.sender) {
                    assertWithMsg(false, "Collateral could be removed with open positions");
                } catch {}

                try collToken0.withdraw(fuzzedAssetsToWithdraw0, recipient, msg.sender) {
                    assertWithMsg(false, "Collateral could be removed with open positions");
                } catch {}
            }

            if (fuzzedAssetsToWithdraw1 > 0) {
                try collToken1.redeem(fuzzedSharesToRedeem1, recipient, msg.sender) {
                    assertWithMsg(false, "Collateral could be removed with open positions");
                } catch {}

                try collToken1.withdraw(fuzzedAssetsToWithdraw1, recipient, msg.sender) {
                    assertWithMsg(false, "Collateral could be removed with open positions");
                } catch {}
            }
        }
    }

    /// @custom:property PANO-SYS-003 The max transfer amount of users with open positions is zero
    /// @custom:property PANO-SYS-004 Users can't transfer collateral with open positions
    /// @custom:precondition The user has a position open
    function invariant_collateral_removal_via_transfer(
        uint256 fuzzNumerator,
        uint256 fuzzDenominator,
        address recipient
    ) public {
        uint256 numOfPositions = panopticPool.numberOfPositions(msg.sender);
        emit LogAddress("Caller", msg.sender);
        emit LogUint256("Positions opened for user", numOfPositions);

        if (numOfPositions > 0) {
            // NOTE: transferring the actual balance of shares, not a converted amount to assets
            uint256 bal0 = collToken0.balanceOf(msg.sender);
            uint256 bal1 = collToken1.balanceOf(msg.sender);

            if (fuzzNumerator > fuzzDenominator)
                (fuzzNumerator, fuzzDenominator) = (fuzzDenominator, fuzzNumerator);

            uint256 fuzzedAmtToTransfer0 = (bal0 * fuzzNumerator) / fuzzDenominator;
            uint256 fuzzedAmtToTransfer1 = (bal1 * fuzzNumerator) / fuzzDenominator;

            // attempt a full withdrawal every 4th block, to ensure we're testing that case too
            if (block.number % 4 == 0) (fuzzedAmtToTransfer0, fuzzedAmtToTransfer1) = (bal0, bal1);

            if (fuzzedAmtToTransfer0 > 0) {
                try collToken0.transfer(recipient, fuzzedAmtToTransfer0) {
                    assertWithMsg(
                        false,
                        "Collateral could be removed via transfer with open positions"
                    );
                } catch {}
                collToken0.approve(recipient, fuzzedAmtToTransfer0);
                hevm.prank(recipient);
                try collToken0.transferFrom(msg.sender, recipient, fuzzedAmtToTransfer0) {
                    assertWithMsg(
                        false,
                        "Collateral could be removed via transferFrom with open positions"
                    );
                } catch {}
            }
            if (fuzzedAmtToTransfer1 > 0) {
                try collToken1.transfer(recipient, fuzzedAmtToTransfer1) {
                    assertWithMsg(
                        false,
                        "Collateral could be removed via transfer with open positions"
                    );
                } catch {}
                collToken1.approve(recipient, fuzzedAmtToTransfer1);
                hevm.prank(recipient);
                try collToken1.transferFrom(msg.sender, recipient, fuzzedAmtToTransfer1) {
                    assertWithMsg(
                        false,
                        "Collateral could be removed via transferFrom with open positions"
                    );
                } catch {}
            }
        }
    }

    /// @custom:property PANO-SYS-005 Users can't use the overloaded withdraw to withdraw so much that it makes their open positions insolvent
    function invariant_collateral_overremoval_with_open_positions(
        CollateralTracker collToken
    ) public {
        _attempt_collateral_overremoval(collToken0, msg.sender, true);
        _attempt_collateral_overremoval(collToken1, msg.sender, false);
    }

    function _attempt_collateral_overremoval(
        CollateralTracker collToken,
        address withdrawer,
        bool token0Or1
    ) public {
        (, int24 curTick, , , , , ) = pool.slot0();
        (int128 premium0, int128 premium1, uint256[2][] memory positions) = panopticPool
            .calculateAccumulatedFeesBatch(withdrawer, false, userPositions[withdrawer]);

        LeftRightUnsigned tokenData = collToken.getAccountMarginDetails(
            withdrawer,
            curTick,
            positions,
            token0Or1 ? premium0 : premium1
        );
        uint256 marginCallThreshold = tokenData.leftSlot();
        uint256 bal = collToken.balanceOf(withdrawer);
        uint amountToMarginCallThreshold = (bal - marginCallThreshold);
        uint amountOver;
        amountOver = bound(amountOver, 1, bal - amountToMarginCallThreshold);

        // assert is-solvent
        TokenId[] memory withdrawers_open_positions = userPositions[withdrawer];
        try panopticPool.validateCollateralWithdrawable(withdrawer, withdrawers_open_positions) {
            // then, assert we get a revert when trying to withdraw too much:
            try
                collToken.withdraw(
                    amountToMarginCallThreshold + amountOver,
                    withdrawer,
                    withdrawer,
                    withdrawers_open_positions
                )
            {
                assertWithMsg(false, "User was able to withdraw too much");
            } catch {}
        } catch {
            // Do nothing: the msg.sender we were passed was not solvent prior
            // to withdrawal attempt, so nothing to check for this invariant this time around
        }
    }

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

    /// @custom:property PANO-SYS-008 The Collateral Tracker's internal accounting always shows it has less than or equal to its true balance of the underlying token
    function invariant_never_overcount_underlying_token() public {
        (uint256 ct0_s_poolAssets, , ) = collToken0.getPoolData();
        assertWithMsg(
            ct0_s_poolAssets <= IERC20(collToken0.asset()).balanceOf(address(panopticPool)) + 1,
            "CollateralTracker0 has overcounted its token0 assets"
        );

        (uint256 ct1_s_poolAssets, , ) = collToken1.getPoolData();
        assertWithMsg(
            ct1_s_poolAssets <= IERC20(collToken1.asset()).balanceOf(address(panopticPool)) + 1,
            "CollateralTracker1 has overcounted its token1 assets"
        );
    }

    /// @custom:property PANO-SYS-009 No user can ever withdraw greater than the Collateral Tracker's internally-accounted poolAssets
    function invariant_no_withdrawal_gt_pool_assets(
        address owner,
        address recipient,
        uint256 amount_over
    ) public {
        _attempt_withdrawal_gt_pool_assets_via_withdraw(collToken0, owner, recipient, amount_over);
        _attempt_withdrawal_gt_pool_assets_via_withdraw(collToken1, owner, recipient, amount_over);

        _attempt_withdrawal_gt_pool_assets_via_redeem(collToken0, owner, recipient, amount_over);
        _attempt_withdrawal_gt_pool_assets_via_redeem(collToken1, owner, recipient, amount_over);
    }

    function _attempt_withdrawal_gt_pool_assets_via_withdraw(
        CollateralTracker collToken,
        address owner,
        address recipient,
        uint256 amount_over
    ) internal {
        (uint256 ct_s_poolAssets, , ) = collToken.getPoolData();
        amount_over = bound(amount_over, 1, type(uint256).max - ct_s_poolAssets);

        hevm.prank(owner);
        // every other attempt, make it a non-owner call:
        if (block.number % 2 == 0) {
            collToken.approve(recipient, collToken.convertToShares(ct_s_poolAssets + amount_over));
            hevm.prank(recipient);
        }

        uint256 numOfPositions = panopticPool.numberOfPositions(owner);
        if (numOfPositions == 0) {
            try collToken.withdraw(ct_s_poolAssets + amount_over, owner, recipient) {
                assertWithMsg(false, "User withdrew > collateralTokens poolAssets");
            } catch {
                if (
                    collToken.convertToShares(ct_s_poolAssets + amount_over) >
                    collToken.balanceOf(owner)
                ) {
                    emit LogString(
                        "invariant_no_withdrawal_gt_pool_assets succeeded because user didnt have enough shares to attempt overwithdrawal"
                    );
                } else {
                    // NOTE: we could add a deal of the collToken.asset() if we wanted to ensure we hit this case more often
                    emit LogString(
                        "invariant_no_withdrawal_gt_pool_assets succeeded, possibly because we correctly enforced a max withdrawal of ct_s_poolAssets"
                    );
                }
            }

            try
                collToken.withdraw(
                    ct_s_poolAssets + amount_over,
                    owner,
                    recipient,
                    new TokenId[](0)
                )
            {
                assertWithMsg(false, "User withdrew > collateralTokens poolAssets");
            } catch {
                if (
                    collToken.convertToShares(ct_s_poolAssets + amount_over) >
                    collToken.balanceOf(owner)
                ) {
                    emit LogString(
                        "invariant_no_withdrawal_gt_pool_assets succeeded because user didnt have enough shares to attempt overwithdrawal"
                    );
                } else {
                    // NOTE: we could add a deal of the collToken.asset() if we wanted to ensure we hit this case more often
                    emit LogString(
                        "invariant_no_withdrawal_gt_pool_assets succeeded, possibly because we correctly enforced a max withdrawal of ct_s_poolAssets"
                    );
                }
            }
        } else {
            TokenId[] memory withdrawers_open_positions = userPositions[owner];
            try
                collToken.withdraw(
                    ct_s_poolAssets + amount_over,
                    owner,
                    recipient,
                    withdrawers_open_positions
                )
            {
                assertWithMsg(false, "User withdrew > collateralTokens poolAssets");
            } catch {
                if (
                    collToken.convertToShares(ct_s_poolAssets + amount_over) >
                    collToken.balanceOf(owner)
                ) {
                    emit LogString(
                        "invariant_no_withdrawal_gt_pool_assets succeeded because user didnt have enough shares to attempt overwithdrawal"
                    );
                } else {
                    // NOTE: we could add a deal of the collToken.asset() if we wanted to ensure we hit this case more often
                    emit LogString(
                        "invariant_no_withdrawal_gt_pool_assets succeeded, possibly because we correctly enforced a max withdrawal of ct_s_poolAssets"
                    );
                }
            }
        }
    }

    function _attempt_withdrawal_gt_pool_assets_via_redeem(
        CollateralTracker collToken,
        address owner,
        address recipient,
        uint256 amount_over
    ) internal {
        (uint256 ct_s_poolAssets, , ) = collToken.getPoolData();
        amount_over = bound(amount_over, 1, type(uint256).max - ct_s_poolAssets);

        uint256 numOfPositions = panopticPool.numberOfPositions(owner);
        if (numOfPositions == 0) {
            hevm.prank(owner);
            // every other attempt, make it a non-owner call:
            if (block.number % 2 == 0) {
                collToken.approve(
                    recipient,
                    collToken.convertToShares(ct_s_poolAssets) + amount_over
                );
                hevm.prank(recipient);
            }

            try
                collToken.redeem(
                    collToken.convertToShares(ct_s_poolAssets) + amount_over,
                    owner,
                    recipient
                )
            {
                assertWithMsg(false, "User redeemed > the poolAssets of collToken");
            } catch {
                if (
                    collToken.convertToShares(ct_s_poolAssets + amount_over) >
                    collToken.balanceOf(owner)
                ) {
                    emit LogString(
                        "invariant_no_withdrawal_gt_pool_assets succeeded because user didnt have enough shares to attempt overwithdrawal"
                    );
                } else {
                    // NOTE: we could add a deal of the collToken.asset() if we wanted to ensure we hit this case more often
                    emit LogString(
                        "invariant_no_withdrawal_gt_pool_assets succeeded, possibly because we correctly enforced a max redemption of convertToShares(ct_s_poolAssets)"
                    );
                }
            }
        }
    }

    /// @custom:property PANO-SYS-010 No user can ever withdraw, redeem, nor transfer an amount greater than their own balance
    function invariant_never_allow_overremoval(
        address owner,
        address recipient,
        uint256 amount_over
    ) public {
        _attempt_overwithdrawal_via_withdraw(collToken0, owner, recipient, amount_over);
        _attempt_overwithdrawal_via_withdraw(collToken1, owner, recipient, amount_over);

        uint256 numOfPositions = panopticPool.numberOfPositions(owner);
        if (numOfPositions == 0) {
            _attempt_overwithdrawal_via_redeem(collToken0, owner, recipient, amount_over);
            _attempt_overwithdrawal_via_redeem(collToken1, owner, recipient, amount_over);

            _attempt_overtransfer(collToken0, owner, recipient, amount_over);
            _attempt_overtransfer(collToken1, owner, recipient, amount_over);
        }
    }

    function _attempt_overwithdrawal_via_withdraw(
        CollateralTracker collToken,
        address owner,
        address recipient,
        uint256 amount_over
    ) internal {
        uint256 owners_assets = collToken.convertToAssets(collToken.balanceOf(owner));
        amount_over = bound(amount_over, 1, type(uint256).max - owners_assets);

        hevm.prank(owner);
        // every other attempt, make it a non-owner call:
        if (block.number % 2 == 0) {
            collToken.approve(recipient, collToken.convertToShares(owners_assets) + amount_over);
            hevm.prank(recipient);
        }

        uint256 numOfPositions = panopticPool.numberOfPositions(owner);
        if (numOfPositions == 0) {
            try collToken.withdraw(owners_assets + amount_over, owner, recipient) {
                assertWithMsg(false, "User withdrew > their balance");
            } catch {}

            try
                collToken.withdraw(owners_assets + amount_over, owner, recipient, new TokenId[](0))
            {
                assertWithMsg(false, "User withdrew > their balance");
            } catch {}
        } else {
            TokenId[] memory withdrawers_open_positions = userPositions[owner];
            try
                collToken.withdraw(
                    owners_assets + amount_over,
                    owner,
                    recipient,
                    withdrawers_open_positions
                )
            {
                assertWithMsg(false, "User withdrew > their balance");
            } catch {}
        }
    }

    function _attempt_overwithdrawal_via_redeem(
        CollateralTracker collToken,
        address owner,
        address recipient,
        uint256 amount_over
    ) internal {
        uint256 owners_shares = collToken.balanceOf(owner);
        amount_over = bound(amount_over, 1, type(uint256).max - owners_shares);

        hevm.prank(owner);
        // every other attempt, make it a non-owner call:
        if (block.number % 2 == 0) {
            collToken.approve(recipient, owners_shares + amount_over);
            hevm.prank(recipient);
        }

        try collToken.redeem(owners_shares + amount_over, owner, recipient) {
            assertWithMsg(false, "User redeemed > their balance");
        } catch {}
    }

    function _attempt_overtransfer(
        CollateralTracker collToken,
        address owner,
        address recipient,
        uint256 amount_over
    ) internal {
        uint256 owners_shares = collToken.balanceOf(owner);
        amount_over = bound(amount_over, 1, type(uint256).max - owners_shares);
        hevm.prank(owner);
        // every other attempt, make it a owner call:
        if (block.number % 2 == 0) {
            try collToken.transfer(recipient, owners_shares + amount_over) {
                assertWithMsg(false, "User transferred > their balance");
            } catch {}
            // every other attempt, make it a non-owner call:
        } else {
            collToken.approve(recipient, owners_shares + amount_over);
            hevm.prank(recipient);
            try collToken.transferFrom(owner, recipient, owners_shares + amount_over) {
                assertWithMsg(false, "User transferFromed > their balance");
            } catch {}
        }
    }

    /// @custom:property PANO-SYS-011 The pool can never have a utilisation over 100%
    function invariant_never_allow_pool_utilisation_over_100p() public {
        (, , int256 collToken0PU) = collToken0.getPoolData();
        assertWithMsg(
            collToken0PU <= 10000,
            "collToken0 pool utilisation exceeded 10k bps <=> 100%"
        );

        (, , int256 collToken1PU) = collToken1.getPoolData();
        assertWithMsg(
            collToken1PU <= 10000,
            "collToken1 pool utilisation exceeded 10k bps <=> 100%"
        );
    }

    /// @custom:property PANO-SYS-012 Users can't deposit more than the maximum allowed amount, 2^104
    function invariant_never_allow_overdeposit(
        address depositor,
        address receiver,
        uint256 tooLargeDepositAmount
    ) public {
        _attempt_overdeposit(collToken0, depositor, receiver, tooLargeDepositAmount);
        _attempt_overdeposit(collToken1, depositor, receiver, tooLargeDepositAmount);
    }

    function _attempt_overdeposit(
        CollateralTracker collToken,
        address depositor,
        address receiver,
        uint256 tooLargeDepositAmount
    ) internal {
        uint256 maxDeposit = type(uint104).max;
        tooLargeDepositAmount = bound(tooLargeDepositAmount, maxDeposit + 1, type(uint256).max);

        hevm.prank(depositor);
        try collToken.deposit(tooLargeDepositAmount, receiver) {
            assertWithMsg(false, "Deposit over maximum allowed did not revert");
        } catch {
            uint256 depositorBalance = IERC20(collToken.asset()).balanceOf(depositor);
            if (depositorBalance < tooLargeDepositAmount) {
                emit LogString(
                    "Invariant succeeded because user did not have enough assets to overdeposit"
                );
            } else {
                // NOTE: we could add a deal of the collToken.asset() if we wanted to ensure we hit this case more often
                emit LogString(
                    "Invariant succeeded, likely because we enforced the max deposit amount correctly"
                );
            }
        }
    }

    /// @custom:property PANO-SYS-013 Users can't mint more than the maximum allowed amount, 2^104
    function invariant_never_allow_overmint(
        address minter,
        address receiver,
        uint256 tooLargeMintAmount
    ) public {
        _attempt_overmint(collToken0, minter, receiver, tooLargeMintAmount);
        _attempt_overmint(collToken1, minter, receiver, tooLargeMintAmount);
    }

    function _attempt_overmint(
        CollateralTracker collToken,
        address minter,
        address receiver,
        uint256 tooLargeMintAmount
    ) internal {
        uint256 maxMint = type(uint104).max;
        tooLargeMintAmount = bound(tooLargeMintAmount, maxMint + 1, type(uint256).max);

        hevm.prank(minter);
        try collToken.mint(tooLargeMintAmount, receiver) {
            assertWithMsg(false, "Mint over maximum allowed did not revert");
        } catch {
            uint256 minterBalance = IERC20(collToken.asset()).balanceOf(minter);
            if (minterBalance < collToken.convertToAssets(tooLargeMintAmount)) {
                emit LogString(
                    "Invariant succeeded because user did not have enough assets to overmint"
                );
            } else {
                // NOTE: we could add a deal of the collToken.asset() if we wanted to ensure we hit this case more often
                emit LogString(
                    "Invariant succeeded, likely because we enforced the max mint amount correctly"
                );
            }
        }
    }

    /// @custom:property PANO-SYS-014 Users can't deposit/mint more than their balance
    function invariant_no_mint_nor_deposit_over_balance(
        address depositor,
        address receiver,
        uint256 amountOver,
        bool viaMint
    ) public {
        _attempt_deposit_over_balance(collToken0, depositor, receiver, amountOver, viaMint);
        _attempt_deposit_over_balance(collToken1, depositor, receiver, amountOver, viaMint);
    }

    function _attempt_deposit_over_balance(
        CollateralTracker collToken,
        address depositor,
        address receiver,
        uint256 amountOver,
        bool viaMint
    ) internal {
        uint256 depositorBalance = IERC20(collToken.asset()).balanceOf(depositor);
        amountOver = bound(amountOver, 1, type(uint256).max - depositorBalance);
        uint256 tooLargeAmount = depositorBalance + amountOver;

        hevm.prank(depositor);
        if (viaMint) {
            uint256 tooLargeShares = collToken.convertToShares(tooLargeAmount);
            try collToken.mint(tooLargeShares, receiver) {
                assertWithMsg(
                    false,
                    "User minted an amount of shares greater than their balance of the asset"
                );
            } catch {}
        } else {
            try collToken.deposit(tooLargeAmount, receiver) {
                assertWithMsg(
                    false,
                    "User deposited an amount greater than their balance of the asset"
                );
            } catch {}
        }
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

    /// @custom:property PANO-DEP-001 The Panoptic pool balance must increase by the deposited amount when a deposit is made (or the corresponding amount of assets for a given share value when a mint is made)
    /// @custom:property PANO-DEP-002 The user balance must decrease by the deposited amount when a deposit is made (or the corresponding amount of assets for a given share value when a mint is made)
    /// @custom:property PANO-DEP-003 A user's share balance must increase by the amount of shares previewMint returns
    function deposit_to_ct(bool token0, uint256 amount, bool via_mint) public {
        if (token0) {
            emit LogString("Attempting to deposit/mint token0");
            _deposit_and_check(collToken0, via_mint, amount, msg.sender);
        } else {
            emit LogString("Attempting to deposit/mint token1");
            _deposit_and_check(collToken1, via_mint, amount, msg.sender);
        }
    }

    function _deposit_and_check(
        CollateralTracker collToken,
        bool via_mint,
        uint256 amount,
        address depositor
    ) internal {
        uint256 depositor_bal_before = IERC20(collToken.asset()).balanceOf(depositor);
        uint256 pool_bal_before = IERC20(collToken.asset()).balanceOf(address(panopticPool));
        uint256 shares_before = collToken.balanceOf(depositor);

        amount = bound(amount, 1, MAX_DEPOSIT);

        // Limit the maximum amount of collateral to deposit
        if (collToken.convertToAssets(collToken.balanceOf(depositor)) > 10 * MAX_DEPOSIT) {
            return;
        }
        amount = bound(amount, MIN_DEPOSIT, min(MAX_DEPOSIT, depositor_bal_before / 10));
        uint256 shares = collToken.previewDeposit(amount);

        hevm.prank(depositor);
        if (via_mint) {
            collToken.mint(shares, depositor);
        } else {
            collToken.deposit(amount, depositor);
        }

        uint256 pool_bal_after = IERC20(collToken.asset()).balanceOf(address(panopticPool));
        assertWithMsg(
            pool_bal_after - pool_bal_before == amount,
            "Pool token balance incorrect after deposit"
        );
        uint256 depositor_bal_after = IERC20(collToken.asset()).balanceOf(depositor);
        assertWithMsg(
            depositor_bal_before - depositor_bal_after == amount,
            "User token balance incorrect after deposit"
        );
        uint256 shares_after = collToken.balanceOf(depositor);
        assertWithMsg(
            shares_after - shares_before == shares,
            "User shares balance incorrect after deposit"
        );
    }

    /// @custom:property PANO-WIT-001 The Panoptic pool balance must decrease by the withdrawn amount when a withdrawal is made
    /// @custom:property PANO-WIT-002 The user balance must increase by the withdrawn amount when a withdrawal is made
    function withdraw_from_ct(
        bool token0,
        bool via_redeem,
        uint256 shares,
        address withdrawer
    ) public {
        uint256 numOfPositions = panopticPool.numberOfPositions(msg.sender);
        if (numOfPositions > 0) {
            if (token0) {
                emit LogString("Attempting to withdraw token0 with open positions");
                _withdraw_with_open_positions_and_check(collToken0, shares, withdrawer);
            } else {
                emit LogString("Attempting to withdraw token1 with open positions");
                _withdraw_with_open_positions_and_check(collToken1, shares, withdrawer);
            }
        } else {
            if (token0) {
                emit LogString("Attempting to withdraw/redeem token0 without open positions");
                _regular_withdraw_and_check(collToken0, via_redeem, shares, withdrawer);
            } else {
                emit LogString("Attempting to withdraw/redeem token1 without open positions");
                _regular_withdraw_and_check(collToken1, via_redeem, shares, withdrawer);
            }
        }
    }

    function _regular_withdraw_and_check(
        CollateralTracker collToken,
        bool via_redeem,
        uint256 shares,
        address withdrawer
    ) internal {
        uint256 withdrawer_assets_before = IERC20(collToken.asset()).balanceOf(withdrawer);
        uint256 pool_assets_before = IERC20(collToken.asset()).balanceOf(address(panopticPool));
        uint256 withdrawer_shares_before = collToken.balanceOf(withdrawer);

        uint256 shares_to_withdraw = bound(shares, 1, collToken.balanceOf(withdrawer));
        uint256 assets_to_withdraw = collToken.convertToAssets(shares_to_withdraw);

        hevm.prank(withdrawer);
        if (via_redeem) {
            try collToken.redeem(shares_to_withdraw, withdrawer, withdrawer) {
                uint256 pool_assets_after = IERC20(collToken.asset()).balanceOf(
                    address(panopticPool)
                );
                uint256 withdrawer_assets_after = IERC20(collToken.asset()).balanceOf(withdrawer);
                uint256 withdrawer_shares_after = collToken.balanceOf(withdrawer);
                assertWithMsg(
                    pool_assets_before - pool_assets_after == assets_to_withdraw,
                    "Pool asset balance incorrect after redemption"
                );
                assertWithMsg(
                    withdrawer_assets_after - withdrawer_assets_before == assets_to_withdraw,
                    "User balance incorrect after deposit"
                );
                assertWithMsg(
                    withdrawer_shares_after - withdrawer_shares_before == shares_to_withdraw,
                    "User share balance incorrect after redemption"
                );
            } catch {}
        } else {
            try collToken.withdraw(assets_to_withdraw, withdrawer, withdrawer) {
                uint256 pool_assets_after = IERC20(collToken.asset()).balanceOf(
                    address(panopticPool)
                );
                uint256 withdrawer_assets_after = IERC20(collToken.asset()).balanceOf(withdrawer);
                uint256 withdrawer_shares_after = collToken.balanceOf(withdrawer);
                assertWithMsg(
                    pool_assets_before - pool_assets_after == assets_to_withdraw,
                    "Pool asset balance incorrect after redemption"
                );
                assertWithMsg(
                    withdrawer_assets_after - withdrawer_assets_before == assets_to_withdraw,
                    "User balance incorrect after deposit"
                );
                assertWithMsg(
                    withdrawer_shares_after - withdrawer_shares_before == shares_to_withdraw,
                    "User share balance incorrect after redemption"
                );
            } catch {}
        }
    }

    function _withdraw_with_open_positions_and_check(
        CollateralTracker collToken,
        uint256 shares,
        address withdrawer
    ) internal {
        // check whether current positions are solvent; assertFalse if not
        TokenId[] memory withdrawers_open_positions = userPositions[withdrawer];
        try
            panopticPool.validateCollateralWithdrawable(withdrawer, withdrawers_open_positions)
        {} catch {
            assertWithMsg(
                false,
                "User is not solvent even prior to withdrawing-with-open-positions"
            );
        }

        // attempt withdrawal, and assert assets & shares were deducted/incremented appropriately:
        uint256 withdrawer_assets_bal = IERC20(collToken.asset()).balanceOf(withdrawer);
        uint256 pool_assets_bal = IERC20(collToken.asset()).balanceOf(address(panopticPool));
        uint256 withdrawer_shares = collToken.balanceOf(withdrawer);

        // TODO: do we need to scale this down such that we're in-bounds for the actual collateral requirements of open positions?
        uint256 shares_to_withdraw = bound(shares, 1, collToken.balanceOf(withdrawer));
        uint256 assets_to_withdraw = collToken.convertToAssets(shares_to_withdraw);

        hevm.prank(withdrawer);

        try
            collToken.withdraw(
                assets_to_withdraw,
                withdrawer,
                withdrawer,
                withdrawers_open_positions
            )
        {
            // assert assets & shares were deducted/incremented appropriately:
            uint256 pool_assets_bal_after = IERC20(collToken.asset()).balanceOf(
                address(panopticPool)
            );
            uint256 withdrawer_bal_after = IERC20(collToken.asset()).balanceOf(withdrawer);
            uint256 withdrawer_shares_after = collToken.balanceOf(withdrawer);
            assertWithMsg(
                pool_assets_bal - pool_assets_bal_after == assets_to_withdraw,
                "Pool asset balance incorrect after redemption"
            );
            assertWithMsg(
                withdrawer_bal_after - withdrawer_assets_bal == assets_to_withdraw,
                "User balance incorrect after deposit"
            );
            assertWithMsg(
                withdrawer_shares_after - withdrawer_shares == shares_to_withdraw,
                "User share balance incorrect after redemption"
            );

            // show we are still solvent:
            try
                panopticPool.validateCollateralWithdrawable(withdrawer, withdrawers_open_positions)
            {} catch {
                assertWithMsg(
                    false,
                    "User is not solvent after seemingly legal withdrawal-with-open-positions"
                );
            }
        } catch {}
    }

    function transfer_ct_shares(
        bool token0,
        uint256 shares,
        address sender,
        address recipient,
        bool transfer_from_sender
    ) public {
        if (token0) {
            emit LogString("Attempting to transfer/transferFrom token0");
            _transfer_and_check(collToken0, shares, sender, recipient, transfer_from_sender);
        } else {
            emit LogString("Attempting to transfer/transferFrom token1");
            _transfer_and_check(collToken1, shares, sender, recipient, transfer_from_sender);
        }
    }

    function _transfer_and_check(
        CollateralTracker collToken,
        uint256 shares,
        address sender,
        address recipient,
        bool transfer_from_sender
    ) internal {
        uint256 sender_shares = collToken.balanceOf(sender);
        uint256 recipient_shares = collToken.balanceOf(recipient);

        uint256 shares_to_transfer = bound(shares, 1, collToken.balanceOf(sender));

        hevm.prank(sender);
        if (transfer_from_sender) {
            try collToken.transfer(recipient, shares_to_transfer) {
                uint sender_shares_after = collToken.balanceOf(sender);
                uint recipient_shares_after = collToken.balanceOf(recipient);
                assertWithMsg(
                    sender_shares_after - sender_shares == shares_to_transfer,
                    "Sender shares balance incorrect after transfer"
                );
                assertWithMsg(
                    recipient_shares_after - recipient_shares == shares_to_transfer,
                    "Recipient shares balance incorrect after transfer"
                );
            } catch {
                // Loudly error for any reversion reason other than having open positions
                uint256 numOfPositions = panopticPool.numberOfPositions(msg.sender);
                if (numOfPositions == 0)
                    assertWithMsg(false, "unknown reversion when trying to transfer");
            }
        } else {
            collToken.approve(recipient, shares_to_transfer);
            try collToken.transferFrom(sender, recipient, shares_to_transfer) {
                uint sender_shares_after = collToken.balanceOf(sender);
                uint recipient_shares_after = collToken.balanceOf(recipient);
                assertWithMsg(
                    sender_shares_after - sender_shares == shares_to_transfer,
                    "Sender shares balance incorrect after transfer"
                );
                assertWithMsg(
                    recipient_shares_after - recipient_shares == shares_to_transfer,
                    "Recipient shares balance incorrect after transfer"
                );
            } catch {
                uint256 numOfPositions = panopticPool.numberOfPositions(msg.sender);
                if (numOfPositions == 0)
                    assertWithMsg(false, "unknown reversion when trying to transfer");
            }
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
