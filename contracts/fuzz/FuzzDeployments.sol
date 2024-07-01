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
        address recipient,
        uint256 fullOrSelfFuzz
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

            // attempt a full withdrawal every 3rd attempt, and a self-withdrawal every 5th attempt, to ensure we're testing those cases
            if (fullOrSelfFuzz % 3 == 0) fuzzNumerator = fuzzDenominator;
            if (fullOrSelfFuzz % 5 == 0) recipient = msg.sender;

            uint256 fuzzedSharesToRedeem0 = (shareBal0 * fuzzNumerator) / fuzzDenominator;
            uint256 fuzzedSharesToRedeem1 = (shareBal1 * fuzzNumerator) / fuzzDenominator;

            uint256 fuzzedAssetsToWithdraw0 = (assetBal0 * fuzzNumerator) / fuzzDenominator;
            uint256 fuzzedAssetsToWithdraw1 = (assetBal1 * fuzzNumerator) / fuzzDenominator;

            if (fuzzedAssetsToWithdraw0 > 0) {
                hevm.prank(msg.sender);
                try collToken0.redeem(fuzzedSharesToRedeem0, recipient, msg.sender) {
                    assertWithMsg(false, "Collateral could be removed with open positions");
                } catch {}

                hevm.prank(msg.sender);
                try collToken0.withdraw(fuzzedAssetsToWithdraw0, recipient, msg.sender) {
                    assertWithMsg(false, "Collateral could be removed with open positions");
                } catch {}
            }

            if (fuzzedAssetsToWithdraw1 > 0) {
                hevm.prank(msg.sender);
                try collToken1.redeem(fuzzedSharesToRedeem1, recipient, msg.sender) {
                    assertWithMsg(false, "Collateral could be removed with open positions");
                } catch {}

                hevm.prank(msg.sender);
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
        address recipient,
        uint256 fullOrNotFuzz
    ) public {
        uint256 numOfPositions = panopticPool.numberOfPositions(msg.sender);
        emit LogAddress("Caller", msg.sender);
        emit LogUint256("Positions opened for user", numOfPositions);

        if (numOfPositions > 0) {
            uint256 bal0 = collToken0.balanceOf(msg.sender);
            uint256 bal1 = collToken1.balanceOf(msg.sender);

            if (fuzzNumerator > fuzzDenominator)
                (fuzzNumerator, fuzzDenominator) = (fuzzDenominator, fuzzNumerator);

            uint256 fuzzedAmtToTransfer0 = (bal0 * fuzzNumerator) / fuzzDenominator;
            uint256 fuzzedAmtToTransfer1 = (bal1 * fuzzNumerator) / fuzzDenominator;

            // attempt a full withdrawal every 4th attempt, to ensure we're testing that case too
            if (fullOrNotFuzz % 4 == 0) (fuzzedAmtToTransfer0, fuzzedAmtToTransfer1) = (bal0, bal1);

            if (fuzzedAmtToTransfer0 > 0) {
                hevm.prank(msg.sender);
                try collToken0.transfer(recipient, fuzzedAmtToTransfer0) {
                    assertWithMsg(
                        false,
                        "Collateral could be removed via transfer with open positions"
                    );
                } catch {}

                hevm.prank(msg.sender);
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
                hevm.prank(msg.sender);
                try collToken1.transfer(recipient, fuzzedAmtToTransfer1) {
                    assertWithMsg(
                        false,
                        "Collateral could be removed via transfer with open positions"
                    );
                } catch {}

                hevm.prank(msg.sender);
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
        CollateralTracker collToken,
        uint256 amountToWithdraw
    ) public {
        _attempt_collateral_overremoval(collToken0, msg.sender, true, amountToWithdraw);
        _attempt_collateral_overremoval(collToken1, msg.sender, false, amountToWithdraw);
    }

    function _attempt_collateral_overremoval(
        CollateralTracker collToken,
        address withdrawer,
        bool isToken0,
        uint256 amountToWithdraw
    ) public {
        TokenId[] memory withdrawersOpenPositions = userPositions[withdrawer];
        // return early if user has no open positions
        if (withdrawersOpenPositions.length == 0) return;

        amountToWithdraw = bound(
            amountToWithdraw,
            1,
            _max_assets_withdrawable(collToken, collToken.balanceOf(withdrawer))
        );
        try panopticPool.validateCollateralWithdrawable(withdrawer, withdrawersOpenPositions) {
            // Do nothing: the user _can_ withdraw their collateral, so there's nothing to test
        } catch {
            // if validateCollateralWithdrawable says we should not be able to withdraw,
            // then we should fail here:
            hevm.prank(withdrawer);
            try
                collToken.withdraw(
                    amountToWithdraw,
                    withdrawer,
                    withdrawer,
                    withdrawersOpenPositions
                )
            {
                assertWithMsg(
                    false,
                    "User was able to withdraw despite validateCollateralWithdrawable saying they could not"
                );
            } catch {}
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
        uint256 amountOver,
        bool nonOwnerCall
    ) public {
        _attempt_withdrawal_gt_pool_assets_via_withdraw(
            collToken0,
            owner,
            recipient,
            amountOver,
            nonOwnerCall
        );
        _attempt_withdrawal_gt_pool_assets_via_withdraw(
            collToken1,
            owner,
            recipient,
            amountOver,
            nonOwnerCall
        );

        _attempt_withdrawal_gt_pool_assets_via_redeem(
            collToken0,
            owner,
            recipient,
            amountOver,
            nonOwnerCall
        );
        _attempt_withdrawal_gt_pool_assets_via_redeem(
            collToken1,
            owner,
            recipient,
            amountOver,
            nonOwnerCall
        );
    }

    function _attempt_withdrawal_gt_pool_assets_via_withdraw(
        CollateralTracker collToken,
        address owner,
        address recipient,
        uint256 amountOver,
        bool nonOwnerCall
    ) internal {
        (uint256 ct_s_poolAssets, , ) = collToken.getPoolData();
        amountOver = bound(amountOver, 1, type(uint256).max - ct_s_poolAssets);
        uint256 numOfPositions = panopticPool.numberOfPositions(owner);
        TokenId[] memory withdrawersOpenPositions = userPositions[owner];

        hevm.prank(owner);
        if (nonOwnerCall) {
            collToken.approve(recipient, collToken.convertToShares(ct_s_poolAssets + amountOver));
            hevm.prank(recipient);
        }

        if (numOfPositions == 0) {
            try collToken.withdraw(ct_s_poolAssets + amountOver, recipient, owner) {
                assertWithMsg(false, "User withdrew > collateralTokens poolAssets");
            } catch {
                if (
                    collToken.convertToShares(ct_s_poolAssets + amountOver) >
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

            nonOwnerCall ? hevm.prank(recipient) : hevm.prank(owner);
            try
                collToken.withdraw(ct_s_poolAssets + amountOver, recipient, owner, new TokenId[](0))
            {
                assertWithMsg(false, "User withdrew > collateralTokens poolAssets");
            } catch {
                if (
                    collToken.convertToShares(ct_s_poolAssets + amountOver) >
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
            try
                collToken.withdraw(
                    ct_s_poolAssets + amountOver,
                    recipient,
                    owner,
                    withdrawersOpenPositions
                )
            {
                assertWithMsg(false, "User withdrew > collateralTokens poolAssets");
            } catch {
                if (
                    collToken.convertToShares(ct_s_poolAssets + amountOver) >
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
        uint256 amountOver,
        bool nonOwnerCall
    ) internal {
        (uint256 ct_s_poolAssets, , ) = collToken.getPoolData();
        amountOver = bound(amountOver, 1, type(uint256).max - ct_s_poolAssets);

        uint256 numOfPositions = panopticPool.numberOfPositions(owner);
        if (numOfPositions == 0) {
            hevm.prank(owner);
            if (nonOwnerCall) {
                collToken.approve(
                    recipient,
                    collToken.convertToShares(ct_s_poolAssets) + amountOver
                );
                hevm.prank(recipient);
            }

            try
                collToken.redeem(
                    collToken.convertToShares(ct_s_poolAssets) + amountOver,
                    recipient,
                    owner
                )
            {
                assertWithMsg(false, "User redeemed > the poolAssets of collToken");
            } catch {
                if (
                    collToken.convertToShares(ct_s_poolAssets + amountOver) >
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
        uint256 amountOver,
        bool nonOwnerCall
    ) public {
        _attempt_overwithdrawal_via_withdraw(
            collToken0,
            owner,
            recipient,
            amountOver,
            nonOwnerCall
        );
        _attempt_overwithdrawal_via_withdraw(
            collToken1,
            owner,
            recipient,
            amountOver,
            nonOwnerCall
        );

        uint256 numOfPositions = panopticPool.numberOfPositions(owner);
        if (numOfPositions == 0) {
            _attempt_overwithdrawal_via_redeem(
                collToken0,
                owner,
                recipient,
                amountOver,
                nonOwnerCall
            );
            _attempt_overwithdrawal_via_redeem(
                collToken1,
                owner,
                recipient,
                amountOver,
                nonOwnerCall
            );

            _attempt_overtransfer(collToken0, owner, recipient, amountOver, nonOwnerCall);
            _attempt_overtransfer(collToken1, owner, recipient, amountOver, nonOwnerCall);
        }
    }

    function _attempt_overwithdrawal_via_withdraw(
        CollateralTracker collToken,
        address owner,
        address recipient,
        uint256 amountOver,
        bool nonOwnerCall
    ) internal {
        uint256 ownersAssets = collToken.convertToAssets(collToken.balanceOf(owner));
        amountOver = bound(amountOver, 1, type(uint256).max - ownersAssets);
        uint256 numOfPositions = panopticPool.numberOfPositions(owner);
        TokenId[] memory withdrawersOpenPositions = userPositions[owner];

        hevm.prank(owner);
        // every other attempt, make it a non-owner call:
        if (nonOwnerCall) {
            collToken.approve(recipient, collToken.convertToShares(ownersAssets) + amountOver);
            hevm.prank(recipient);
        }

        if (numOfPositions == 0) {
            try collToken.withdraw(ownersAssets + amountOver, recipient, owner) {
                assertWithMsg(false, "User withdrew > their balance");
            } catch {}

            nonOwnerCall ? hevm.prank(recipient) : hevm.prank(owner);
            try collToken.withdraw(ownersAssets + amountOver, recipient, owner, new TokenId[](0)) {
                assertWithMsg(false, "User withdrew > their balance");
            } catch {}
        } else {
            try
                collToken.withdraw(
                    ownersAssets + amountOver,
                    recipient,
                    owner,
                    withdrawersOpenPositions
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
        uint256 amountOver,
        bool nonOwnerCall
    ) internal {
        uint256 ownersShares = collToken.balanceOf(owner);
        amountOver = bound(amountOver, 1, type(uint256).max - ownersShares);

        hevm.prank(owner);
        if (nonOwnerCall) {
            collToken.approve(recipient, ownersShares + amountOver);
            hevm.prank(recipient);
        }

        try collToken.redeem(ownersShares + amountOver, recipient, owner) {
            assertWithMsg(false, "User redeemed > their balance");
        } catch {}
    }

    function _attempt_overtransfer(
        CollateralTracker collToken,
        address owner,
        address recipient,
        uint256 amountOver,
        bool nonOwnerCall
    ) internal {
        uint256 ownersShares = collToken.balanceOf(owner);
        amountOver = bound(amountOver, 1, type(uint256).max - ownersShares);
        hevm.prank(owner);
        if (nonOwnerCall) {
            try collToken.transfer(recipient, ownersShares + amountOver) {
                assertWithMsg(false, "User transferred > their balance");
            } catch {}
        } else {
            collToken.approve(recipient, ownersShares + amountOver);
            hevm.prank(recipient);
            try collToken.transferFrom(owner, recipient, ownersShares + amountOver) {
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
        address receiver,
        uint256 tooLargeDepositAmount,
        bool depositToSelf
    ) public {
        _attempt_overdeposit(true, msg.sender, receiver, tooLargeDepositAmount, depositToSelf);
        _attempt_overdeposit(false, msg.sender, receiver, tooLargeDepositAmount, depositToSelf);
    }

    function _attempt_overdeposit(
        bool isToken0,
        address depositor,
        address receiver,
        uint256 tooLargeDepositAmount,
        bool depositToSelf
    ) internal {
        CollateralTracker collToken = isToken0 ? collToken0 : collToken1;
        uint256 maxDeposit = type(uint104).max;
        tooLargeDepositAmount = bound(tooLargeDepositAmount, maxDeposit + 1, type(uint256).max);

        if (depositToSelf) {
            receiver = depositor;
        }

        uint256 depositorBalance = IERC20(collToken.asset()).balanceOf(depositor);
        uint256 shortfallForDeposit = tooLargeDepositAmount - depositorBalance;
        isToken0
            ? deal_USDC(depositor, shortfallForDeposit, true)
            : deal_WETH(depositor, shortfallForDeposit);
        hevm.prank(depositor);
        IERC20(collToken.asset()).approve(address(collToken), type(uint256).max);

        hevm.prank(depositor);
        try collToken.deposit(tooLargeDepositAmount, receiver) {
            assertWithMsg(false, "Deposit over maximum allowed did not revert");
        } catch {
            emit LogString(
                "Invariant succeeded, likely because we enforced the max deposit amount correctly"
            );
        }
    }

    /// @custom:property PANO-SYS-013 Users can't mint more than the maximum allowed amount, 2^104
    function invariant_never_allow_overmint(
        address minter,
        address receiver,
        uint256 tooLargeMintAmount,
        bool mintToSelf
    ) public {
        _attempt_overmint(true, minter, receiver, tooLargeMintAmount, mintToSelf);
        _attempt_overmint(false, minter, receiver, tooLargeMintAmount, mintToSelf);
    }

    function _attempt_overmint(
        bool isToken0,
        address minter,
        address receiver,
        uint256 tooLargeMintAmount,
        bool mintToSelf
    ) internal {
        CollateralTracker collToken = isToken0 ? collToken0 : collToken1;
        uint256 maxMint = collToken.previewDeposit(type(uint104).max);
        tooLargeMintAmount = bound(tooLargeMintAmount, maxMint + 1, type(uint256).max);

        if (mintToSelf) {
            receiver = minter;
        }

        uint256 minterBalance = IERC20(collToken.asset()).balanceOf(minter);
        uint256 shortfallForMint = collToken.previewDeposit(tooLargeMintAmount) - minterBalance;
        isToken0 ? deal_USDC(minter, shortfallForMint, true) : deal_WETH(minter, shortfallForMint);

        hevm.prank(minter);
        IERC20(collToken.asset()).approve(address(collToken), type(uint256).max);
        hevm.prank(minter);
        try collToken.mint(tooLargeMintAmount, receiver) {
            assertWithMsg(false, "Mint over maximum allowed did not revert");
        } catch {
            uint256 minterBalance = IERC20(collToken.asset()).balanceOf(minter);
            emit LogString(
                "Invariant succeeded, likely because we enforced the max mint amount correctly"
            );
        }
    }

    /// @custom:property PANO-SYS-014 Users can't deposit/mint more than their balance
    function invariant_no_mint_nor_deposit_over_balance(
        address receiver,
        uint256 amountOver,
        bool viaMint
    ) public {
        _attempt_deposit_over_balance(collToken0, msg.sender, receiver, amountOver, viaMint);
        _attempt_deposit_over_balance(collToken1, msg.sender, receiver, amountOver, viaMint);
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
        uint256 tooLargeShares = collToken.convertToShares(tooLargeAmount);

        hevm.prank(depositor);
        if (viaMint) {
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
    function deposit_to_ct(bool token0, uint256 assets, bool viaMint) public {
        if (token0) {
            emit LogString("Attempting to deposit/mint token0");
            _deposit_and_check(collToken0, viaMint, assets, msg.sender);
        } else {
            emit LogString("Attempting to deposit/mint token1");
            _deposit_and_check(collToken1, viaMint, assets, msg.sender);
        }
    }

    function _deposit_and_check(
        CollateralTracker collToken,
        bool viaMint,
        uint256 assets,
        address depositor
    ) internal {
        uint256 depositorBalBefore = IERC20(collToken.asset()).balanceOf(depositor);
        uint256 poolBalBefore = IERC20(collToken.asset()).balanceOf(address(panopticPool));
        uint256 sharesBefore = collToken.balanceOf(depositor);

        assets = bound(assets, 1, MAX_DEPOSIT);

        // Limit the maximum amount of collateral to deposit
        if (collToken.convertToAssets(collToken.balanceOf(depositor)) > 10 * MAX_DEPOSIT) {
            return;
        }
        assets = bound(assets, MIN_DEPOSIT, min(MAX_DEPOSIT, depositorBalBefore / 10));
        uint256 shares = collToken.previewDeposit(assets);

        hevm.prank(depositor);
        if (viaMint) {
            collToken.mint(shares, depositor);
        } else {
            collToken.deposit(assets, depositor);
        }

        uint256 poolBalAfter = IERC20(collToken.asset()).balanceOf(address(panopticPool));
        assertWithMsg(
            poolBalAfter - poolBalBefore == assets,
            "Pool token balance incorrect after deposit"
        );
        uint256 depositorBalAfter = IERC20(collToken.asset()).balanceOf(depositor);
        assertWithMsg(
            depositorBalBefore - depositorBalAfter == assets,
            "User token balance incorrect after deposit"
        );
        uint256 sharesAfter = collToken.balanceOf(depositor);
        assertWithMsg(
            sharesAfter - sharesBefore == shares,
            "User shares balance incorrect after deposit"
        );
    }

    /// @custom:property PANO-WIT-001 The Panoptic pool balance must decrease by the withdrawn amount when a withdrawal is made
    /// @custom:property PANO-WIT-002 The user balance must increase by the withdrawn amount when a withdrawal is made
    function withdraw_from_ct(
        bool token0,
        bool viaRedeem,
        uint256 assets,
        address withdrawer
    ) public {
        uint256 numOfPositions = panopticPool.numberOfPositions(withdrawer);
        if (numOfPositions > 0) {
            if (token0) {
                emit LogString("Attempting to withdraw token0 with open positions");
                _withdraw_with_open_positions_and_check(collToken0, assets, withdrawer, true);
            } else {
                emit LogString("Attempting to withdraw token1 with open positions");
                _withdraw_with_open_positions_and_check(collToken1, assets, withdrawer, false);
            }
        } else {
            if (token0) {
                emit LogString("Attempting to withdraw/redeem token0 without open positions");
                _regular_withdraw_and_check(collToken0, viaRedeem, assets, withdrawer);
            } else {
                emit LogString("Attempting to withdraw/redeem token1 without open positions");
                _regular_withdraw_and_check(collToken1, viaRedeem, assets, withdrawer);
            }
        }
    }

    function _regular_withdraw_and_check(
        CollateralTracker collToken,
        bool viaRedeem,
        uint256 assetsToWithdraw,
        address withdrawer
    ) internal {
        uint256 withdrawerAssetsBefore = IERC20(collToken.asset()).balanceOf(withdrawer);
        uint256 poolAssetsBefore = IERC20(collToken.asset()).balanceOf(address(panopticPool));
        uint256 withdrawerSharesBefore = collToken.balanceOf(withdrawer);

        assetsToWithdraw = bound(
            assetsToWithdraw,
            1,
            collToken.convertToAssets(collToken.balanceOf(withdrawer))
        );

        uint256 sharesToWithdraw = collToken.previewWithdraw(assetsToWithdraw);

        hevm.prank(withdrawer);
        if (viaRedeem) {
            try collToken.redeem(sharesToWithdraw, withdrawer, withdrawer) {
                uint256 poolAssetsAfter = IERC20(collToken.asset()).balanceOf(
                    address(panopticPool)
                );
                uint256 withdrawerAssetsAfter = IERC20(collToken.asset()).balanceOf(withdrawer);
                uint256 withdrawerSharesAfter = collToken.balanceOf(withdrawer);
                assertWithMsg(
                    poolAssetsBefore - poolAssetsAfter == assetsToWithdraw,
                    "Pool asset balance incorrect after redemption"
                );
                assertWithMsg(
                    withdrawerAssetsAfter - withdrawerAssetsBefore == assetsToWithdraw,
                    "User balance incorrect after deposit"
                );
                assertWithMsg(
                    withdrawerSharesBefore - withdrawerSharesAfter == sharesToWithdraw,
                    "User share balance incorrect after redemption"
                );
            } catch {
                assertWithMsg(false, "Failed to withdraw for unknown reason");
            }
        } else {
            try collToken.withdraw(assetsToWithdraw, withdrawer, withdrawer) {
                uint256 poolAssetsAfter = IERC20(collToken.asset()).balanceOf(
                    address(panopticPool)
                );
                uint256 withdrawerAssetsAfter = IERC20(collToken.asset()).balanceOf(withdrawer);
                uint256 withdrawerSharesAfter = collToken.balanceOf(withdrawer);
                assertWithMsg(
                    poolAssetsBefore - poolAssetsAfter == assetsToWithdraw,
                    "Pool asset balance incorrect after withdrawal"
                );
                assertWithMsg(
                    withdrawerAssetsAfter - withdrawerAssetsBefore == assetsToWithdraw,
                    "User balance incorrect after deposit"
                );
                assertWithMsg(
                    withdrawerSharesBefore - withdrawerSharesAfter == sharesToWithdraw,
                    "User share balance incorrect after withdrawal"
                );
            } catch {
                assertWithMsg(false, "Failed to redeem for unknown reason");
            }
        }
    }

    uint256 internal constant FAST_ORACLE_CARDINALITY = 3;
    uint256 internal constant FAST_ORACLE_PERIOD = 1;

    bool internal constant SLOW_ORACLE_UNISWAP_MODE = false;
    uint256 internal constant SLOW_ORACLE_CARDINALITY = 7;
    uint256 internal constant SLOW_ORACLE_PERIOD = 5;

    uint256 internal constant MEDIAN_PERIOD = 60;

    uint256 internal constant BP_DECREASE_BUFFER = 13_333;
    int256 internal constant MAX_SLOW_FAST_DELTA = 1800;

    function _withdraw_with_open_positions_and_check(
        CollateralTracker collToken,
        uint256 assetsToWithdraw,
        address withdrawer,
        bool isToken0
    ) internal {
        // check whether current positions are solvent; assertFalse if not
        TokenId[] memory withdrawersOpenPositions = userPositions[withdrawer];
        try
            panopticPool.validateCollateralWithdrawable(withdrawer, withdrawersOpenPositions)
        {} catch {
            assertWithMsg(
                false,
                "User is not solvent even prior to withdrawing-with-open-positions"
            );
        }

        // attempt withdrawal, and assert assets & shares were deducted/incremented appropriately
        uint256 withdrawerAssetsBefore = IERC20(collToken.asset()).balanceOf(withdrawer);
        uint256 poolAssetsBefore = IERC20(collToken.asset()).balanceOf(address(panopticPool));
        uint256 withdrawerSharesBefore = collToken.balanceOf(withdrawer);

        /* NOTE: We are moving away from approaches requiring us to calc the exact max amount withdrawable;
         instead, we just handle the unhappy path by ensuring that a revert in withdraw matches to a revert
         from validateCollateralWithdrawable
        // 1. Figure out how many assets we can legally withdraw:
        uint256 maxAssetsWithdrawable = _get_assets_withdrawable(
            withdrawer,
            isToken0
        );
        */
        // Bound the fuzzed assets-to-withdraw to max assets withdrawable:
        // the smaller of the s_poolAssets and the user's assets in the CT
        assetsToWithdraw = bound(assetsToWithdraw, 1, _max_assets_withdrawable(collToken, withdrawerSharesBefore));
        // Figure out how many shares we expect to see burnt:
        uint256 expectedSharesBurnt = collToken.previewWithdraw(assetsToWithdraw);

        hevm.prank(withdrawer);

        try collToken.withdraw(assetsToWithdraw, withdrawer, withdrawer, withdrawersOpenPositions) {
            // assert assets & shares were deducted/incremented appropriately:
            uint256 poolAssetsAfter = IERC20(collToken.asset()).balanceOf(address(panopticPool));
            uint256 withdrawerAssetsAfter = IERC20(collToken.asset()).balanceOf(withdrawer);
            uint256 withdrawerSharesAfter = collToken.balanceOf(withdrawer);
            assertWithMsg(
                poolAssetsBefore - poolAssetsAfter == assetsToWithdraw,
                "Pool asset balance incorrect after withdrawal"
            );
            assertWithMsg(
                withdrawerAssetsAfter - withdrawerAssetsBefore == assetsToWithdraw,
                "User balance incorrect after deposit"
            );
            assertWithMsg(
                withdrawerSharesBefore - withdrawerSharesAfter == expectedSharesBurnt,
                "User share balance incorrect after withdrawal"
            );

            // show we are still solvent:
            try
                panopticPool.validateCollateralWithdrawable(withdrawer, withdrawersOpenPositions)
            {} catch {
                assertWithMsg(
                    false,
                    "User not solvent after seemingly legal withdrawal-with-open-positions"
                );
            }
        } catch {
            bool withdrawalCausesInsolvency = false;
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
                uint256 miniMedian;
                unchecked {
                    miniMedian =
                        (uint256(block.timestamp) << 216) +
                        // magic number which adds (7,5,3,1,0,2,4,6) order and minTick in positions 7, 5, 3 and maxTick in 6, 4, 2
                        // see comment on s_miniMedian initialization for format of this magic number
                        (uint256(0xF590A6F276170D89E9F276170D89E9F276170D89E9000000000000)) +
                        (uint256(uint24(currentTick)) << 24) + // add to slot 4
                        (uint256(uint24(currentTick))); // add to slot 3
                }
                (, uint256 medianData) = PanopticMath.computeInternalMedian(
                    observationIndex,
                    observationCardinality,
                    MEDIAN_PERIOD,
                    miniMedian,
                    pool
                );
                if (medianData != 0) miniMedian = medianData;

                (slowOracleTick, medianData) = PanopticMath.computeInternalMedian(
                    observationIndex,
                    observationCardinality,
                    MEDIAN_PERIOD,
                    miniMedian,
                    pool
                );
            }

            // Check the user's solvency at the fast tick; revert if not solvent
            bool solventAtFast = _checkSolvencyAtTick(
                withdrawer,
                withdrawersOpenPositions,
                currentTick,
                fastOracleTick,
                BP_DECREASE_BUFFER
            );
            if (!solventAtFast) withdrawalCausesInsolvency = true;

            // If one of the ticks is too stale, we fall back to the more conservative tick, i.e, the user must be solvent at both the fast and slow oracle ticks.
            if (Math.abs(int256(fastOracleTick) - slowOracleTick) > MAX_SLOW_FAST_DELTA)
                if (
                    !_checkSolvencyAtTick(
                        withdrawer,
                        withdrawersOpenPositions,
                        currentTick,
                        slowOracleTick,
                        BP_DECREASE_BUFFER
                    )
                ) withdrawalCausesInsolvency = true;

            // aaaand, putting it all together - if we reverted for some unknown reason, we failed an assertion, but
            // if we just reverted because the withdrawal causes insolvency, everything is fine:
            assertWithMsg(
                withdrawalCausesInsolvency,
                "Withdrawal reverted for reason other than causing insolvency"
            );
        }
    }

    function _max_assets_withdrawable(CollateralTracker collToken, uint256 withdrawerSharesBefore) internal view returns(uint256 maxAssetsWithdrawable) {
        (uint256 ct_s_poolAssets, , ) = collToken.getPoolData();
        uint256 withdrawersAssetsInCT = collToken.convertToAssets(withdrawerSharesBefore);
        maxAssetsWithdrawable =  ct_s_poolAssets < withdrawersAssetsInCT ? ct_s_poolAssets : withdrawersAssetsInCT;
    }

    bool internal constant ONLY_AVAILABLE_PREMIUM = false;

    function _checkSolvencyAtTick(
        address account,
        TokenId[] memory positionIdList,
        int24 currentTick,
        int24 atTick,
        uint256 buffer
    ) internal view returns (bool) {
        (int128 premium0, int128 premium1, uint256[2][] memory positionBalanceArray) = panopticPool
            .calculateAccumulatedFeesBatch(account, ONLY_AVAILABLE_PREMIUM, positionIdList);

        LeftRightUnsigned tokenData0 = collToken0.getAccountMarginDetails(
            account,
            atTick,
            positionBalanceArray,
            premium0
        );
        LeftRightUnsigned tokenData1 = collToken1.getAccountMarginDetails(
            account,
            atTick,
            positionBalanceArray,
            premium1
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

    function transfer_ct_shares(
        bool token0,
        uint256 shares,
        address sender,
        address recipient,
        bool transferFromSender
    ) public {
        if (sender == recipient) {
            return;
        }
        if (token0) {
            emit LogString("Attempting to transfer/transferFrom token0");
            _transfer_and_check(collToken0, shares, sender, recipient, transferFromSender);
        } else {
            emit LogString("Attempting to transfer/transferFrom token1");
            _transfer_and_check(collToken1, shares, sender, recipient, transferFromSender);
        }
    }

    function _transfer_and_check(
        CollateralTracker collToken,
        uint256 shares,
        address sender,
        address recipient,
        bool transferFromSender
    ) internal {
        uint256 senderSharesBefore = collToken.balanceOf(sender);
        uint256 recipientSharesBefore = collToken.balanceOf(recipient);

        uint256 sharesToTransfer = bound(shares, 1, senderSharesBefore);

        hevm.prank(sender);
        if (transferFromSender) {
            try collToken.transfer(recipient, sharesToTransfer) {
                uint senderSharesAfter = collToken.balanceOf(sender);
                uint recipientSharesAfter = collToken.balanceOf(recipient);
                assertWithMsg(
                    senderSharesBefore - senderSharesAfter == sharesToTransfer,
                    "Sender shares balance incorrect after transfer"
                );
                assertWithMsg(
                    recipientSharesAfter - recipientSharesBefore == sharesToTransfer,
                    "Recipient shares balance incorrect after transfer"
                );
            } catch {
                // Loudly error for any reversion reason other than having open positions
                uint256 numOfPositions = panopticPool.numberOfPositions(sender);
                if (numOfPositions == 0)
                    assertWithMsg(false, "unknown reversion when trying to transfer");
            }
        } else {
            collToken.approve(recipient, sharesToTransfer);
            hevm.prank(recipient);
            try collToken.transferFrom(sender, recipient, sharesToTransfer) {
                uint senderSharesAfter = collToken.balanceOf(sender);
                uint recipientSharesAfter = collToken.balanceOf(recipient);
                assertWithMsg(
                    senderSharesBefore - senderSharesAfter == sharesToTransfer,
                    "Sender shares balance incorrect after transfer"
                );
                assertWithMsg(
                    recipientSharesAfter - recipientSharesBefore == sharesToTransfer,
                    "Recipient shares balance incorrect after transfer"
                );
            } catch {
                uint256 numOfPositions = panopticPool.numberOfPositions(sender);
                if (numOfPositions == 0)
                    assertWithMsg(false, "unknown reversion when trying to transfer");
            }
        }
    }

    // Deal USDC or WETH to the contracts occassionally, to check if this messes with things such as being
    // able to withdraw greater than the internally-accounted s_poolAssets
    function deal_to_contracts(uint amount1, uint amount2, bool whichAmount) public {
        deal_USDC(address(panopticPool), whichAmount ? amount1 : amount2, true);
        deal_WETH(address(panopticPool), whichAmount ? amount2 : amount1);

        deal_USDC(address(collToken0), whichAmount ? amount1 : amount2, true);
        deal_WETH(address(collToken0), whichAmount ? amount2 : amount1);

        deal_USDC(address(collToken1), whichAmount ? amount1 : amount2, true);
        deal_WETH(address(collToken1), whichAmount ? amount2 : amount1);

        deal_USDC(address(pool), whichAmount ? amount1 : amount2, true);
        deal_WETH(address(pool), whichAmount ? amount2 : amount1);
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
