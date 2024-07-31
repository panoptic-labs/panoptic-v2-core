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

    /// @dev Generate a tokenId with only long legs when tokenId_in had short legs
    function _generate_long_only_tokenid(TokenId tokenId_in) internal returns (TokenId out) {
        if (tokenId_in.countLongs() > 0) {
            out = TokenId.wrap(tokenId_in.poolId());
            uint256 numLegs = tokenId_in.countLegs();
            uint256 _newLegs;

            for (uint256 leg; leg < numLegs; ++leg) {
                if (tokenId_in.isLong(leg) == 1) {
                    {
                        uint256 ratio = tokenId_in.optionRatio(leg);
                        uint256 asset = tokenId_in.asset(leg);
                        uint256 tokenType = tokenId_in.tokenType(leg);
                        int24 strike = tokenId_in.strike(leg);
                        int24 width = tokenId_in.width(leg);
                        out = out.addOptionRatio(ratio, _newLegs);
                        out = out.addAsset(asset, _newLegs);
                        out = out.addTokenType(tokenType, _newLegs);
                        out = out.addStrike(strike, _newLegs);
                        out = out.addWidth(width, _newLegs);
                        out = out.addIsLong(0, _newLegs);
                        out = out.addRiskPartner(_newLegs, _newLegs);
                    }
                    log_tokenid_leg(out, _newLegs);
                    ++_newLegs;
                }
            }
        } else {
            out = TokenId.wrap(0);
        }
    }

    /// @dev Generate a single leg
    function _generate_single_leg_tokenid(
        bool asset_in,
        bool is_call_in,
        bool is_long_in,
        bool is_otm_in,
        bool is_atm,
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

        if (is_atm) {
            (width, strike) = getATMSW(
                width_in,
                strike_in,
                uint24(poolTickSpacing),
                currentTick,
                call_put
            );
        } else if (is_otm_in) {
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
        bool[4] memory is_atm_in,
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

            if (is_atm_in[i]) {
                (width, strike) = getATMSW(
                    width_in[i],
                    strike_in[i],
                    uint24(poolTickSpacing),
                    currentTick,
                    call_put
                );
            } else if (is_otm_in[i]) {
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
        bool is_atm_in,
        uint24 width_in,
        int256 strike_in
    ) internal returns (TokenId out) {
        out = TokenId.wrap(poolId);

        uint256 asset = asset_in == true ? 1 : 0;
        uint256 long_short = is_long_in == true ? 1 : 0;

        int24 width;
        int24 strike;

        if (is_atm_in) {
            (width, strike) = getATMSW(
                width_in,
                strike_in,
                uint24(poolTickSpacing),
                currentTick,
                0
            );
        } else {
            // use the asset_in bool as a way to determine which side of the current price the strike is
            (width, strike) = getOTMSW(
                width_in,
                strike_in,
                uint24(poolTickSpacing),
                currentTick,
                asset
            );
        }

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
        bool is_atm0_in,
        bool is_atm1_in,
        bool is_inverted_in,
        uint256 width_in,
        int256 strike_in,
        int24 strike_delta
    ) internal returns (TokenId out) {
        out = TokenId.wrap(poolId);

        uint256 asset = asset_in == true ? 1 : 0;
        uint256 long_short = is_long_in == true ? 1 : 0;

        int24 width_sc;
        int24 width_sp;
        int24 strike_sc;
        int24 strike_sp;

        if (is_atm0_in) {
            (width_sc, strike_sc) = getATMSW(
                width_in,
                strike_in,
                uint24(poolTickSpacing),
                currentTick,
                asset
            );
        } else {
            if (is_inverted_in) {
                (width_sc, strike_sc) = getITMSW(
                    width_in,
                    strike_in,
                    uint24(poolTickSpacing),
                    currentTick,
                    asset
                );
            } else {
                (width_sc, strike_sc) = getOTMSW(
                    width_in,
                    strike_in,
                    uint24(poolTickSpacing),
                    currentTick,
                    asset
                );
            }
        }

        strike_in = int24(strike_in >> 24);
        width_in = uint24(width_in >> 24);

        if (is_atm1_in) {
            (width_sp, strike_sp) = getATMSW(
                width_in,
                strike_in,
                uint24(poolTickSpacing),
                currentTick,
                1 - asset
            );
        } else {
            if (is_inverted_in) {
                (width_sp, strike_sp) = getITMSW(
                    width_in,
                    strike_in,
                    uint24(poolTickSpacing),
                    currentTick,
                    1 - asset
                );
            } else {
                (width_sp, strike_sp) = getOTMSW(
                    width_in,
                    strike_in,
                    uint24(poolTickSpacing),
                    currentTick,
                    1 - asset
                );
            }

            // add logic for calendar strangles
        }

        // Create call
        out = out.addLeg(0, 1, asset, long_short, 1 - asset, 1, strike_sc + strike_delta, width_sc);
        // Create put
        out = out.addLeg(1, 1, asset, long_short, asset, 0, strike_sp - strike_delta, width_sc);

        log_tokenid_leg(out, 0);
        log_tokenid_leg(out, 1);
    }

    function _generate_spread_tokenid(
        bool asset_in,
        bool tokenType_in,
        bool is_atm0_in,
        bool is_atm1_in,
        bool is_inverted_in,
        bool is_calendar_in,
        uint256 width_in,
        int256 strike_in,
        int24 strike_delta
    ) internal returns (TokenId out) {
        out = TokenId.wrap(poolId);

        uint256 asset = asset_in == true ? 1 : 0;
        uint256 tokenType = tokenType_in == true ? 1 : 0;

        int24 width_short;
        int24 width_long;
        int24 strike_short;
        int24 strike_long;

        if (is_atm0_in) {
            (width_short, strike_short) = getATMSW(
                width_in,
                strike_in,
                uint24(poolTickSpacing),
                currentTick,
                asset
            );
        } else {
            if (is_inverted_in) {
                (width_short, strike_short) = getITMSW(
                    width_in,
                    strike_in,
                    uint24(poolTickSpacing),
                    currentTick,
                    asset
                );
            } else {
                (width_short, strike_short) = getOTMSW(
                    width_in,
                    strike_in,
                    uint24(poolTickSpacing),
                    currentTick,
                    asset
                );
            }
        }

        strike_in = int24(strike_in >> 24);
        width_in = uint24(width_in >> 24);
        if (is_atm1_in) {
            (width_long, strike_long) = getATMSW(
                width_in,
                strike_in,
                uint24(poolTickSpacing),
                currentTick,
                1 - asset
            );
            if (is_calendar_in == false) {
                width_long = width_short;
            }
        } else {
            if (is_inverted_in) {
                (width_long, strike_long) = getITMSW(
                    width_in,
                    strike_in,
                    uint24(poolTickSpacing),
                    currentTick,
                    1 - asset
                );
            } else {
                (width_long, strike_long) = getOTMSW(
                    width_in,
                    strike_in,
                    uint24(poolTickSpacing),
                    currentTick,
                    1 - asset
                );
            }
            if (is_calendar_in == false) {
                width_long = width_short;
            }
        }

        // Create short
        out = out.addLeg(0, 1, asset, 0, tokenType, 1, strike_short + strike_delta, width_short);
        // Create long

        out = out.addLeg(1, 1, asset, 1, tokenType, 0, strike_long - strike_delta, width_long);

        log_tokenid_leg(out, 0);
        log_tokenid_leg(out, 1);
    }

    function getProperSize(
        TokenId tokenId,
        address minter,
        uint256 posSize
    ) internal returns (uint256) {
        (, currentTick, , , , , ) = pool.slot0();

        emit LogInt256("pre-mint Tick", currentTick);

        uint256[2][] memory positionBalance = new uint256[2][](1);

        positionBalance[0][0] = TokenId.unwrap(tokenId);
        positionBalance[0][1] = type(uint48).max;

        LeftRightUnsigned tokenData0 = collToken0.getAccountMarginDetails(
            minter,
            currentTick,
            positionBalance,
            0
        );
        LeftRightUnsigned tokenData1 = collToken1.getAccountMarginDetails(
            minter,
            currentTick,
            positionBalance,
            0
        );

        emit LogUint256("tokenData0-bal", tokenData0.rightSlot());
        emit LogUint256("tokenData0-req", tokenData0.leftSlot());
        emit LogUint256("tokenData1-bal", tokenData1.rightSlot());
        emit LogUint256("tokenData1-req", tokenData1.leftSlot());
        (uint256 balance0, uint256 required0) = PanopticMath.convertCollateralData(
            tokenData0,
            tokenData1,
            0,
            currentTick
        );
        emit LogUint256("balance0", balance0);
        emit LogUint256("required0", required0);
        (uint256 balance1, uint256 required1) = PanopticMath.convertCollateralData(
            tokenData0,
            tokenData1,
            1,
            currentTick
        );
        emit LogUint256("balance1", balance1);
        emit LogUint256("required1", required1);
        emit LogUint256(
            "amountsMoved0",
            PanopticMath.getAmountsMoved(tokenId, type(uint48).max, 0).rightSlot()
        );
        emit LogUint256(
            "amountsMoved1",
            PanopticMath.getAmountsMoved(tokenId, type(uint48).max, 0).leftSlot()
        );
        /* assertWithMsg(required0 > 10, "required is nonzero!"); */
        uint256 size = (required0 * balance0) / type(uint48).max;
        posSize = bound(posSize, (size * 10) / 100, (size * 200) / 100);

        require(posSize > 0);

        emit LogUint256("positionSize", posSize);

        return posSize;
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
        bool is_covered,
        uint64 effLiqLim
    ) internal {
        // Mint a position according to tokenId and posSize

        uint256 userCollateral0 = collToken0.convertToAssets(collToken0.balanceOf(minter));
        emit LogUint256("User collateral 0", userCollateral0);
        uint256 userCollateral1 = collToken1.convertToAssets(collToken1.balanceOf(minter));
        emit LogUint256("User collateral 1", userCollateral1);

        require((userCollateral0 > 0) || (userCollateral1 > 0));
        uint256 positionsOpened = panopticPool.numberOfPositions(minter);
        emit LogUint256("Positions opened for user", positionsOpened);
        emit LogUint256("Positions opened for user - internal", userPositions[minter].length);

        /* assertWithMsg(
            positionsOpened == userPositions[minter].length,
            "number of positions match internal one"
        ); */

        userPositions[minter].push(tokenid);
        TokenId[] memory posIdList = userPositions[minter];
        TokenId[] memory lastPos = new TokenId[](1);
        lastPos[0] = tokenid;

        posSize = getProperSize(tokenid, minter, posSize);

        emit LogInt256("Balance before", int256(_get_assets_in_token0(minter, currentTick)));

        LeftRightUnsigned requiredBalanceBefore;
        {
            (, currentTick, , , , , ) = pool.slot0();
            emit LogInt256("final Tick", currentTick);

            LeftRightUnsigned tokenData0;
            LeftRightUnsigned tokenData1;
            address _m = minter;
            {
                // Compute premia for all options (includes short+long premium)
                (
                    int128 premium0,
                    int128 premium1,
                    uint256[2][] memory positionBalanceArray
                ) = panopticPool.calculateAccumulatedFeesBatch(_m, false, posIdList);

                // Query the current and required collateral amounts for the two tokens
                tokenData0 = collToken0.getAccountMarginDetails(
                    _m,
                    currentTick,
                    positionBalanceArray,
                    premium0
                );
                tokenData1 = collToken1.getAccountMarginDetails(
                    _m,
                    currentTick,
                    positionBalanceArray,
                    premium1
                );
            }
            requiredBalanceBefore = LeftRightUnsigned
                .wrap(0)
                .toRightSlot(uint128(tokenData0.leftSlot()))
                .toLeftSlot(uint128(tokenData1.leftSlot()));
            emit LogUint256("tokenData0-bal", tokenData0.rightSlot());
            emit LogUint256("tokenData0-req", tokenData0.leftSlot());
            emit LogUint256("tokenData1-bal", tokenData1.rightSlot());
            emit LogUint256("tokenData1-req", tokenData1.leftSlot());

            // convert (using atTick) and return the total collateral balance and required balance in terms of tokenType
            (uint256 balance0B, uint256 required0B) = PanopticMath.convertCollateralData(
                tokenData0,
                tokenData1,
                0,
                currentTick
            );

            emit LogUint256("Balance0 before", balance0B);
            emit LogUint256("required0 before", required0B);
        }

        {
            int24 tickLimitLow = is_covered ? int24(-887272) : int24(887272);
            int24 tickLimitHigh = is_covered ? int24(887272) : int24(-887272);
            emit LogInt256("tickLimitLow", tickLimitLow);
            emit LogInt256("tickLimitHigh", tickLimitHigh);
            log_account_collaterals(minter);
            hevm.prank(minter);
            panopticPool.mintOptions(
                posIdList,
                uint128(posSize),
                effLiqLim,
                tickLimitLow,
                tickLimitHigh
            );
            log_account_collaterals(minter);
        }
        // check effective liquidities
        for (uint256 leg; leg < tokenid.countLegs(); ++leg) {
            if (tokenid.isLong(leg) == 1) {
                (int24 tickLower, int24 tickUpper) = tokenid.asTicks(0);
                uint256 tokenType = tokenid.tokenType(leg);
                uint64 effLiqFactor = _get_effective_liq_factor(tokenType, tickLower, tickUpper);

                emit LogUint256("Effective liquidity limit", effLiqLim);
                emit LogUint256("Effective liquidity factor", effLiqFactor);

                // Option was minted, check liquidity factor
                assertWithMsg(
                    effLiqFactor <= effLiqLim,
                    "A long position with liquidity factor greater than the liquidity limit was minted"
                );
            }
        }

        assertWithMsg(positionsOpened < 32, "More than 32 positions are minted for user");
        assertWithMsg(
            panopticPool.numberOfPositions(minter) == positionsOpened + 1,
            "Position counter did not increase after minting"
        );

        userBalance[minter][tokenid] = LeftRightUnsigned.wrap(0).toRightSlot(uint128(posSize));

        (uint128 balance, , ) = panopticPool.optionPositionBalance(minter, tokenid);
        assertWithMsg(balance == posSize, "Position size and balance do not match");

        {
            (, currentTick, , , , , ) = pool.slot0();
            emit LogInt256("final Tick", currentTick);

            LeftRightUnsigned tokenData0;
            LeftRightUnsigned tokenData1;
            address _m = minter;
            {
                // Compute premia for all options (includes short+long premium)
                (
                    int128 premium0,
                    int128 premium1,
                    uint256[2][] memory positionBalanceArray
                ) = panopticPool.calculateAccumulatedFeesBatch(_m, false, posIdList);

                // Query the current and required collateral amounts for the two tokens
                tokenData0 = collToken0.getAccountMarginDetails(
                    _m,
                    currentTick,
                    positionBalanceArray,
                    premium0
                );
                tokenData1 = collToken1.getAccountMarginDetails(
                    _m,
                    currentTick,
                    positionBalanceArray,
                    premium1
                );
            }
            emit LogUint256("tokenData0-bal", tokenData0.rightSlot());
            emit LogUint256("tokenData0-req", tokenData0.leftSlot());
            emit LogUint256("tokenData1-bal", tokenData1.rightSlot());
            emit LogUint256("tokenData1-req", tokenData1.leftSlot());
            assertWithMsg(
                (tokenData0.leftSlot()) >= (requiredBalanceBefore.rightSlot()),
                "tokenData0 required increased after mint"
            );
            assertWithMsg(
                (tokenData1.leftSlot()) >= (requiredBalanceBefore.leftSlot()),
                "tokenData1 required increased after mint"
            );

            // convert (using atTick) and return the total collateral balance and required balance in terms of tokenType
            (uint256 balance0, uint256 required0) = PanopticMath.convertCollateralData(
                tokenData0,
                tokenData1,
                0,
                currentTick
            );
            emit LogUint256("Balance0 after", balance0);
            emit LogUint256("required0 after", required0);

            assertWithMsg(balance0 >= required0, "after: account is not solvent in token0");

            // convert (using atTick) and return the total collateral balance and required balance in terms of tokenType
            (uint256 balance1, uint256 required1) = PanopticMath.convertCollateralData(
                tokenData0,
                tokenData1,
                1,
                currentTick
            );
            emit LogUint256("Balance1 after", balance1);
            emit LogUint256("required1 after", required1);

            assertWithMsg(balance1 >= required1, "after: account is not solvent in token1");

            {
                uint256 sqrtPriceX96 = Math.getSqrtRatioAtTick(currentTick);

                uint256 balanceCross = Math.mulDiv(
                    uint256(tokenData1.rightSlot()),
                    2 ** 96,
                    sqrtPriceX96
                ) + Math.mulDiv96(tokenData0.rightSlot(), sqrtPriceX96);
                // the amount of cross-collateral balance needed for the account to be solvent, computed in terms of liquidity
                // overstimate by rounding up

                uint256 thresholdCross = Math.mulDivRoundingUp(
                    uint256(tokenData1.leftSlot()),
                    2 ** 96,
                    sqrtPriceX96
                ) + Math.mulDiv96RoundingUp(tokenData0.leftSlot(), sqrtPriceX96);
                assertWithMsg(
                    balanceCross >= thresholdCross,
                    "after: account is not solvent in cross token"
                );
            }
        }

        emit LogInt256("Balance after", int256(_get_assets_in_token0(minter, currentTick)));
        emit LogString("Minted a new option");
        emit LogString(is_covered ? "Minted a covered option" : "Minted a settled option");
        emit LogUint256("Position size", posSize);
        emit LogAddress("Minter", minter);
    }

    function mint_option(
        uint256 seller_index,
        bool asset,
        bool is_call,
        bool is_long,
        bool is_otm,
        bool is_atm,
        bool is_covered,
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
                _generate_single_leg_tokenid(asset, is_call, false, is_otm, is_atm, width, strike),
                posSize,
                is_covered,
                0
            );
        } else {
            // Mint a short position first, then a long position
            _mint_option(
                seller,
                _generate_single_leg_tokenid(asset, is_call, false, is_otm, is_atm, width, strike),
                (15 * posSize) / 10,
                false,
                0
            );
            _mint_option(
                minter,
                _generate_single_leg_tokenid(asset, is_call, true, is_otm, is_atm, width, strike),
                posSize,
                is_covered,
                effLiqLimit
            );
        }
    }

    function mint_strategy_undefined(
        uint256 seller_index,
        bool asset,
        bool is_long,
        bool is_covered,
        uint256 strategy,
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

        // We have two strategies now, this can be expanded later
        strategy = bound(strategy, 0, 6);

        (, currentTick, , , , , ) = pool.slot0();

        TokenId tokenId_undefined;
        if (strategy == 0) {
            // Mint a ATM straddle
            tokenId_undefined = _generate_straddle_tokenid(asset, is_long, true, width, strike);
        } else if (strategy == 1) {
            // Mint a OTM straddle
            tokenId_undefined = _generate_straddle_tokenid(asset, is_long, false, width, strike);
        } else if (strategy == 2) {
            // Mint an OTM strangle
            tokenId_undefined = _generate_strangle_tokenid(
                asset,
                is_long,
                false,
                false,
                false,
                width,
                strike,
                10
            ); // Fixed delta of 10, can be changed/fuzzed
        } else if (strategy == 3) {
            // Mint an ATM strangle (may be inverted)
            tokenId_undefined = _generate_strangle_tokenid(
                asset,
                is_long,
                true,
                true,
                false,
                width,
                strike,
                10
            ); // Fixed delta of 10, can be changed/fuzzed
        } else if (strategy == 4) {
            // Mint an inverted OTM strangle
            tokenId_undefined = _generate_strangle_tokenid(
                asset,
                is_long,
                false,
                false,
                true,
                width,
                strike,
                10
            ); // Fixed delta of 10, can be changed/fuzzed
        } else if (strategy == 5) {
            // Mint an inverted ATM strangle
            tokenId_undefined = _generate_strangle_tokenid(
                asset,
                is_long,
                true,
                false,
                true,
                width,
                strike,
                10
            ); // Fixed delta of 10, can be changed/fuzzed
        } else if (strategy == 6) {
            // Mint an inverted ATM strangle
            tokenId_undefined = _generate_strangle_tokenid(
                asset,
                is_long,
                false,
                true,
                true,
                width,
                strike,
                10
            ); // Fixed delta of 10, can be changed/fuzzed
        }

        if (tokenId_undefined.countLongs() > 0) {
            TokenId tokenIdLongs = _generate_long_only_tokenid(tokenId_undefined);
            emit LogUint256(
                "mint_strategy_undefined - tokenIdLongs",
                uint256(TokenId.unwrap(tokenIdLongs))
            );
            _mint_option(seller, tokenIdLongs, (12 * posSize) / 10, false, 0);
        }
        _mint_option(minter, tokenId_undefined, posSize, is_covered, effLiqLimit);
    }

    function mint_strategy_defined(
        uint256 seller_index,
        bool asset,
        bool tokenType,
        bool is_covered,
        uint256 strategy,
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

        // We have two strategies now, this can be expanded later
        strategy = bound(strategy, 0, 9);
        emit LogUint256("mint_strategy_defined - strategy", strategy);

        (, currentTick, , , , , ) = pool.slot0();

        TokenId spread;
        if (strategy == 0) {
            // Mint a OTM spread
            spread = _generate_spread_tokenid(
                asset,
                tokenType,
                false,
                false,
                false,
                false,
                width,
                strike,
                0
            );
        } else if (strategy == 1) {
            // Mint a ATM spread
            spread = _generate_spread_tokenid(
                asset,
                tokenType,
                true,
                true,
                false,
                false,
                width,
                strike,
                0
            );
        } else if (strategy == 2) {
            // Mint an inverted spread
            spread = _generate_spread_tokenid(
                asset,
                tokenType,
                false,
                false,
                true,
                false,
                width,
                strike,
                0
            );
        } else if (strategy == 3) {
            // Mint an inverted ATM spread
            spread = _generate_spread_tokenid(
                asset,
                tokenType,
                true,
                false,
                true,
                false,
                width,
                strike,
                0
            );
        } else if (strategy == 4) {
            // Mint an inverted ATM spread
            spread = _generate_spread_tokenid(
                asset,
                tokenType,
                false,
                true,
                true,
                false,
                width,
                strike,
                0
            );
        } else if (strategy == 5) {
            // Mint a OTM calendar spread
            spread = _generate_spread_tokenid(
                asset,
                tokenType,
                false,
                false,
                false,
                true,
                width,
                strike,
                0
            );
        } else if (strategy == 6) {
            // Mint a ATM calendar spread
            spread = _generate_spread_tokenid(
                asset,
                tokenType,
                true,
                true,
                false,
                true,
                width,
                strike,
                0
            );
        } else if (strategy == 7) {
            // Mint an inverted calendar spread
            spread = _generate_spread_tokenid(
                asset,
                tokenType,
                false,
                false,
                true,
                true,
                width,
                strike,
                0
            );
        } else if (strategy == 8) {
            // Mint an inverted ATM calendar spread
            spread = _generate_spread_tokenid(
                asset,
                tokenType,
                true,
                false,
                true,
                true,
                width,
                strike,
                0
            );
        } else if (strategy == 9) {
            // Mint an inverted ATM calendar spread
            spread = _generate_spread_tokenid(
                asset,
                tokenType,
                false,
                true,
                true,
                false,
                width,
                strike,
                0
            );
        }
        emit LogUint256("mint_strategy_defined - spread", uint256(TokenId.unwrap(spread)));

        if (spread.countLongs() > 0) {
            TokenId tokenIdLongs = _generate_long_only_tokenid(spread);
            _mint_option(seller, tokenIdLongs, (12 * posSize) / 10, false, 0);
            emit LogUint256(
                "mint_strategy_defined - tokenIdLongs",
                uint256(TokenId.unwrap(tokenIdLongs))
            );
        }
        _mint_option(minter, spread, posSize, is_covered, effLiqLimit);
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
        emit LogUint256("price before swap", uint256(price));

        hevm.prank(pool_manipulator);
        swapperc.swapTo(pool, target_sqrt_price);

        update_twap();

        (price, , , , , , ) = pool.slot0();
        emit LogUint256("price after swap", uint256(price));
    }

    function perform_swap_with_delay(uint160 target_sqrt_price, uint256 delay) public {
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
        int24 TWAPtick_after = PanopticMath.twapFilter(pool, 600);
        emit LogInt256("TWAP tick after", TWAPtick_after);
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
    function burn_one_option(uint256 positionIndex, bool isCovered) public {
        $caller = msg.sender;
        require(panopticPool.numberOfPositions($caller) > 0);
        positionIndex = bound(positionIndex, 0, userPositions[$caller].length - 1);

        $position = userPositions[$caller][positionIndex];
        $positionsNew = _get_list_without_tokenid(userPositions[$caller], $position);

        ($posSize, , ) = panopticPool.optionPositionBalance($caller, $position);
        $tickLimitLow = isCovered ? int24(-887272) : int24(887272);

        _try_burning_and_check_balances();

        $position = TokenId.wrap(0);
        delete $caller;
        delete $positionsNew;
        delete $posSize;
        delete $tickLimitLow;
    }

    function _try_burning_and_check_balances() internal {
        _quote_sfpm_burn();
        if ($sfpmRevert) {
            // Nothing to test in this case; leave evaluation of why this reverts to SFPM tests.
            return;
        }

        uint numLegs = $position.countLegs();
        $token0CollectedByLeg = new uint128[](numLegs);
        $token1CollectedByLeg = new uint128[](numLegs);
        for (uint legIndex = 0; legIndex < numLegs; legIndex++) {
            $token0CollectedByLeg[legIndex] = $collectedByLeg[legIndex].rightSlot();
            emit LogUint256("$token0CollectedByLeg[legIndex]", $token0CollectedByLeg[legIndex]);
            $token1CollectedByLeg[legIndex] = $collectedByLeg[legIndex].leftSlot();
        }

        $token0Swapped = $totalSwapped.rightSlot();
        $token1Swapped = $totalSwapped.leftSlot();

        AccumulatorsForLeg[] memory preburnAccumulators = new AccumulatorsForLeg[](numLegs);
        PremiaCalcInputs[] memory premiaCalcInputs = new PremiaCalcInputs[](numLegs);

        try this._get_preburn_accumulators($position, $caller, $posSize) {} catch (
            bytes memory preburn_getting_err
        ) {
            emit LogBytes("preburn_getting_err", preburn_getting_err);
            assertWithMsg(false, "Error getting preburn accumulators");
        }
        (preburnAccumulators, premiaCalcInputs) = this._get_preburn_accumulators(
            $position,
            $caller,
            $posSize
        );
        _burn_and_assert_accumulator_and_token_differences(premiaCalcInputs, preburnAccumulators);

        // Clear storage vars used:
        delete $token0CollectedByLeg;
        delete $token1CollectedByLeg;
        delete $token0Swapped;
        delete $token1Swapped;
    }

    function _quote_sfpm_burn() internal {
        try this._sfpm_burn_sim() {} catch (bytes memory results) {
            emit LogBytes("r", results);
            assembly ("memory-safe") {
                results := add(results, 0x04)
            }
            ($collectedByLeg, $totalSwapped, $sfpmRevert) = abi.decode(
                results,
                (LeftRightUnsigned[4], LeftRightSigned, bool)
            );
        }
    }

    error SFPMBurnResError(
        LeftRightUnsigned[4] collectedByLeg,
        LeftRightSigned totalSwapped,
        bool sfpmRevert
    );

    function _sfpm_burn_sim() external {
        hevm.prank(address(panopticPool));
        try
            sfpm.burnTokenizedPosition($position, $posSize, $tickLimitLow, -1 * $tickLimitLow)
        returns (LeftRightUnsigned[4] memory collectedByLeg, LeftRightSigned totalSwapped) {
            revert SFPMBurnResError(collectedByLeg, totalSwapped, false);
        } catch {
            LeftRightUnsigned[4] memory collectedByLeg;
            LeftRightSigned totalSwapped;
            revert SFPMBurnResError(collectedByLeg, totalSwapped, true);
        }
    }

    function _get_preburn_accumulators(
        TokenId position,
        address caller,
        uint128 posSize
    )
        external
        returns (
            AccumulatorsForLeg[] memory accumulators,
            PremiaCalcInputs[] memory premiaCalcInputs
        )
    {
        uint256 numLegs = position.countLegs();

        accumulators = new AccumulatorsForLeg[](numLegs);
        premiaCalcInputs = new PremiaCalcInputs[](numLegs);

        for (uint legIndex = 0; legIndex < numLegs; legIndex++) {
            _set_preburn_accumulators(position, accumulators, legIndex, caller);

            LiquidityChunk liquidityChunk = PanopticMath.getLiquidityChunk(
                position,
                legIndex,
                posSize
            );
            accumulators[legIndex].positionLiquidity = liquidityChunk.liquidity();
            accumulators[legIndex].totalShortLiquidity = _get_total_short_liquidity(
                position,
                liquidityChunk,
                legIndex
            );

            (uint128 premiumGrowth0, uint128 premiumGrowth1) = panopticPool.optionData(
                position,
                caller,
                legIndex
            );
            premiaCalcInputs[legIndex].premiumGrowth0 = premiumGrowth0;
            premiaCalcInputs[legIndex].premiumGrowth1 = premiumGrowth1;
        }
    }

    uint128 $settledToken0;
    uint128 $settledToken1;
    uint128 $grossPremiaLastToken0;
    uint128 $grossPremiaLastToken1;
    uint128 $sfpmGrossPremiaAccumulator0;
    uint128 $sfpmGrossPremiaAccumulator1;

    function _set_preburn_accumulators(
        TokenId position,
        AccumulatorsForLeg[] memory accumulators,
        uint legIndex,
        address caller
    ) internal {
        (
            $settledToken0,
            $settledToken1,
            $grossPremiaLastToken0,
            $grossPremiaLastToken1
        ) = panopticPool.premiaSettlementData(position, legIndex);
        accumulators[legIndex].settledToken0 = $settledToken0;
        accumulators[legIndex].settledToken1 = $settledToken1;
        accumulators[legIndex].grossPremiaLast0 = $grossPremiaLastToken0;
        accumulators[legIndex].grossPremiaLast1 = $grossPremiaLastToken1;

        ($sfpmGrossPremiaAccumulator0, $sfpmGrossPremiaAccumulator1) = _get_sfpm_accumulators(
            position,
            legIndex
        );
        accumulators[legIndex].sfpmGrossPremiaAccumulator0 = $sfpmGrossPremiaAccumulator0;
        accumulators[legIndex].sfpmGrossPremiaAccumulator1 = $sfpmGrossPremiaAccumulator1;

        delete $settledToken0;
        delete $settledToken1;
        delete $grossPremiaLastToken0;
        delete $grossPremiaLastToken1;
        delete $sfpmGrossPremiaAccumulator0;
        delete $sfpmGrossPremiaAccumulator1;
    }

    function _burn_and_assert_accumulator_and_token_differences(
        PremiaCalcInputs[] memory premiaCalcInputs,
        AccumulatorsForLeg[] memory preburnAccumulators
    ) internal {
        PreburnValues memory burnersPreburnValues = _get_preburn_values();
        try
            this._project_premia_from_preburn_values(premiaCalcInputs, preburnAccumulators)
        returns (
            int128 expectedNonPremiaToken0Difference,
            int128 expectedNonPremiaToken1Difference
        ) {
            try this._prank_and_burn() {
                _make_assertions(
                    preburnAccumulators,
                    expectedNonPremiaToken0Difference,
                    expectedNonPremiaToken1Difference,
                    burnersPreburnValues
                );
                // If burn succeeded, keep userPositions up-to-date for other tests' benefit -
                // one of the caller's positions no longer exist:
                userPositions[$caller] = $positionsNew;
            } catch (bytes memory prank_and_burn_err) {
                // Check if there's a valid reason for .burn to revert,
                // even though SFPM.burnTokenizedPosition succeeded.
                bytes4 revertSelector;
                assembly {
                    revertSelector := mload(add(prank_and_burn_err, 0x20))
                }
                if (
                    // EffectiveLiquidityAboveThreshold
                    revertSelector == 0x3a8795c2
                ) {
                    _assert_effective_liquidity_is_above_threshold();
                } else if (
                    // TooManyPositionsOpen()
                    revertSelector == 0x8026d19e
                ) {
                    assertWithMsg(
                        false,
                        "Previous mint calls failed to enforce the 32 position limit"
                    );
                } else if (
                    // InputListFail()
                    revertSelector == 0x99e877ce
                ) {
                    assertWithMsg(
                        false,
                        "The position we fuzz-selected to be burned was not owned by the user, somehow"
                    );
                } else if (
                    // NotEnoughCollateral()
                    revertSelector == 0x34477cc0
                ) {
                    // TODO: assert that burning actually does leave the user with too little collateral
                    // (Likely have to sim the burn)
                } else if (
                    // Panic(17) overflow
                    keccak256(prank_and_burn_err) == keccak256(PANIC_17)
                ) {
                    (
                        int128 totalProjectedProratedPremium0,
                        int128 totalProjectedProratedPremium1
                    ) = _net_up_prorated_premia();

                    int256 expectedToken0Difference = totalProjectedProratedPremium0 -
                        expectedNonPremiaToken0Difference;
                    int256 expectedToken1Difference = totalProjectedProratedPremium1 -
                        expectedNonPremiaToken1Difference;

                    // TODO: You may need to convert the deltas to shares rounding up/down depending
                    // on the sign to cover some edge cases though (see mint_option as an example)
                    assertWithMsg(
                        int256(collToken0.convertToAssets(collToken0.balanceOf($caller))) +
                            expectedToken0Difference <
                            0 ||
                            int256(collToken1.convertToAssets(collToken1.balanceOf($caller))) +
                                expectedToken1Difference <
                            0,
                        "Received unexpected Panic(17) overflow"
                    );
                } else {
                    emit LogBytes("prank_and_burn_err", prank_and_burn_err);
                    assertWithMsg(false, "Reversion caused by unknown error");
                }
            }
        } catch (bytes memory premia_projection_err) {
            emit LogBytes("premia_projection_err", premia_projection_err);
            assertWithMsg(false, "Error when projecting premia");
        }
        delete $projectedPremia;
    }

    function _get_preburn_values() internal view returns (PreburnValues memory) {
        return
            PreburnValues({
                token0Balance: IERC20(pool.token0()).balanceOf($caller),
                token1Balance: IERC20(pool.token1()).balanceOf($caller),
                assetsInCT0: collToken0.convertToAssets(collToken0.balanceOf($caller)),
                assetsInCT1: collToken1.convertToAssets(collToken1.balanceOf($caller)),
                positionsOpened: panopticPool.numberOfPositions($caller)
            });
    }

    function _project_premia_from_preburn_values(
        PremiaCalcInputs[] memory premiaCalcInputs,
        AccumulatorsForLeg[] memory accumulators
    ) external returns (int128 expectedToken0Difference, int128 expectedToken1Difference) {
        for (uint legIndex = 0; legIndex < $position.countLegs(); legIndex++) {
            // 1. Initialise the projectedPremia, and:
            //    get idealPremia - how much premia should you have been owed based on the position,
            //    ignoring the current state of settled tokens in the PanopticPool?
            $projectedPremia.push(
                PremiaProjection({
                    idealPremium0: uint128(
                        (uint256(
                            accumulators[legIndex].sfpmGrossPremiaAccumulator0 -
                                premiaCalcInputs[legIndex].premiumGrowth0
                        ) * uint256(accumulators[legIndex].positionLiquidity)) >> 64
                    ),
                    idealPremium1: uint128(
                        (uint256(
                            accumulators[legIndex].sfpmGrossPremiaAccumulator1 -
                                premiaCalcInputs[legIndex].premiumGrowth1
                        ) * uint256(accumulators[legIndex].positionLiquidity)) / 2 ** 64
                    ),
                    proratedPremium0: 0,
                    proratedPremium1: 0
                })
            );

            // 2. get proratedPremia:
            //    - short legs should get idealPremia * total settled tokens / total gross premia;
            //    eg, your premia gets prorated by the seller-wide portion of settled tokens available
            //   - long legs should just get their full idealPremia
            this._set_prorated_premia(
                premiaCalcInputs[legIndex],
                accumulators[legIndex],
                legIndex,
                $token0CollectedByLeg[legIndex],
                $token1CollectedByLeg[legIndex]
            );
        }

        (expectedToken0Difference, expectedToken1Difference) = this
            ._get_expected_nonpremia_token_difference($token0Swapped, $token1Swapped);
    }

    function _set_prorated_premia(
        PremiaCalcInputs memory premiaCalcInputs,
        AccumulatorsForLeg memory accumulators,
        uint256 legIndex,
        uint128 token0CollectedByLeg,
        uint128 token1CollectedByLeg
    ) external {
        $projectedPremia[legIndex].proratedPremium0 = $position.isLong(legIndex) == 1
            ? $projectedPremia[legIndex].idealPremium0
            : _prorate_ideal_premium(
                $projectedPremia[legIndex].idealPremium0,
                accumulators.sfpmGrossPremiaAccumulator0,
                accumulators.grossPremiaLast0,
                accumulators.settledToken0 + token0CollectedByLeg,
                accumulators.totalShortLiquidity
            );

        $projectedPremia[legIndex].proratedPremium1 = $position.isLong(legIndex) == 1
            ? $projectedPremia[legIndex].idealPremium1
            : _prorate_ideal_premium(
                $projectedPremia[legIndex].idealPremium1,
                accumulators.sfpmGrossPremiaAccumulator1,
                accumulators.grossPremiaLast1,
                accumulators.settledToken1 + token1CollectedByLeg,
                accumulators.totalShortLiquidity
            );
    }

    function _prorate_ideal_premium(
        uint256 idealPremium,
        uint128 preburnGrossPremium,
        uint128 preburnGrossPremiumLast,
        uint128 preburnSettledTokens,
        uint128 preburnShortLiquidity
    ) internal returns (uint128) {
        // Prevent division by zero, and skip the calculation if prorating a numerator of zero
        if (preburnGrossPremium == 0 || idealPremium == 0) return 0;

        return
            uint128(
                Math.min(
                    uint128(
                        Math.min(
                            (uint256(idealPremium) * uint256(preburnSettledTokens)) /
                                // We >> 64 this, but not the numerator, bc idealPremium is already >> 64
                                (((uint256(preburnGrossPremium - preburnGrossPremiumLast)) *
                                    uint256(preburnShortLiquidity)) >> 64),
                            uint256(idealPremium)
                        )
                    ),
                    // We can only, at maximum, pay out the settled tokens that we have pre-burn
                    // (this figure includes any that were collected according to the SFPM.burn sim)
                    preburnSettledTokens
                )
            );
    }

    function _get_expected_nonpremia_token_difference(
        int128 token0Swapped,
        int128 token1Swapped
    )
        external
        returns (int128 expectedNonPremiaToken0Difference, int128 expectedNonPremiaToken1Difference)
    {
        // We add any expected tokens for burning an ITM position in the SFPM
        expectedNonPremiaToken0Difference = token0Swapped;
        expectedNonPremiaToken1Difference = token1Swapped;

        // And finally, we also add any underlying amounts of long legs,
        // minus the underlying amounts of any short legs.
        (LeftRightSigned longAmounts, LeftRightSigned shortAmounts) = PanopticMath
            .computeExercisedAmounts($position, $posSize);

        expectedNonPremiaToken0Difference -= (longAmounts.rightSlot() - shortAmounts.rightSlot());
        expectedNonPremiaToken1Difference -= (longAmounts.leftSlot() - shortAmounts.leftSlot());
    }

    function _prank_and_burn() external {
        hevm.prank($caller);
        panopticPool.burnOptions($position, $positionsNew, $tickLimitLow, -1 * $tickLimitLow);
    }

    function _make_assertions(
        AccumulatorsForLeg[] memory preburnAccumulators,
        int128 expectedNonPremiaToken0Difference,
        int128 expectedNonPremiaToken1Difference,
        PreburnValues memory burnersPreburnValues
    ) internal {
        $calledFromMakeAssertions = true;
        // Make assertions about each leg's chunk differences, and get expected token diffs:
        try this._assert_each_legs_chunk_accumulators_correct(preburnAccumulators) {
            // Now, see if the assets in token0/token1.balanceOf as well as the CT have changed in
            // alignment with our projections:
            try
                this._compare_against_preburn_values(
                    expectedNonPremiaToken0Difference,
                    expectedNonPremiaToken1Difference,
                    burnersPreburnValues
                )
            {
                $calledFromMakeAssertions = false;
            } catch (bytes memory compare_against_preburn_err) {
                $calledFromMakeAssertions = false;
                emit LogBytes("compare_against_preburn_err", compare_against_preburn_err);
                assertWithMsg(false, "Error when comparing postburn asset values to preburn ones");
            }
        } catch (bytes memory assert_each_leg_err) {
            $calledFromMakeAssertions = false;
            emit LogBytes("assert_each_leg_err", assert_each_leg_err);
            assertWithMsg(false, "Error when evaluating each legs postburn accumulators");
        }
    }

    int256 $expectedSettledToken0DifferenceForChunk;
    int256 $expectedSettledToken1DifferenceForChunk;
    uint128 $postburnSettledToken0;
    uint128 $postburnSettledToken1;
    uint128 $postburnGrossPremiaLast0;
    uint128 $postburnGrossPremiaLast1;
    uint128 $postburnSFPMGrossPremiaAccumulator0;
    uint128 $postburnSFPMGrossPremiaAccumulator1;
    uint256 $postburnShortLiquidity;

    function _assert_each_legs_chunk_accumulators_correct(
        AccumulatorsForLeg[] memory preburnAccumulators
    ) external {
        if (!$calledFromMakeAssertions) {
            return;
        }

        for (uint legIndex = 0; legIndex < $position.countLegs(); legIndex++) {
            $expectedSettledToken0DifferenceForChunk = int256(
                (($position.isLong(legIndex) == 1 ? -1 : int8(1)) *
                    int128($projectedPremia[legIndex].proratedPremium0)) -
                    int128($token0CollectedByLeg[legIndex])
            );

            $expectedSettledToken1DifferenceForChunk = int256(
                (($position.isLong(legIndex) == 1 ? -1 : int8(1)) *
                    int128($projectedPremia[legIndex].proratedPremium1)) -
                    int128($token1CollectedByLeg[legIndex])
            );

            (
                $postburnSettledToken0,
                $postburnSettledToken1,
                $postburnGrossPremiaLast0,
                $postburnGrossPremiaLast1
            ) = panopticPool.premiaSettlementData($position, legIndex);

            assertWithMsg(
                int256(int128($postburnSettledToken0)) ==
                    Math.max(
                        int256(int128(preburnAccumulators[legIndex].settledToken0)) -
                            $expectedSettledToken0DifferenceForChunk,
                        0
                    ),
                "Settled token0s did not increase by the collected tokens and/or increase/decrease by the (prorated) premium for the leg"
            );

            // TODO: If i use _get_sfpm_accumulators_without_itm_swap to set
            // preburnAccumulators[legIndex].sfpmGrossPremiaAccumulator1,
            // i get incorrect settled token projection (unkown if grosspremia correct)
            // If i use regular _get_sfpm_accumulators, i get correct settled token projection,
            // but incorrect gross premia one
            // Must investigate
            // Possibly: should use regular _get_sfpm_accumulators,
            // but round differently when calculating idealPremium maybe? and then compensate in
            // the proration logic so settled tokens is correct too?
            emit LogUint256(
                "$postburnSFPMGrossPremiaAccumulator1",
                $postburnSFPMGrossPremiaAccumulator1
            );
            emit LogUint256("$postburnGrossPremiaLast1", $postburnGrossPremiaLast1);
            emit LogUint256("$postburnShortLiquidity", $postburnShortLiquidity);
            emit LogUint256(
                "preburnAccumulators[legIndex].sfpmGrossPremiaAccumulator1",
                preburnAccumulators[legIndex].sfpmGrossPremiaAccumulator1
            );
            emit LogUint256(
                "preburnAccumulators[legIndex].grossPremiaLast1",
                preburnAccumulators[legIndex].grossPremiaLast1
            );
            emit LogUint256(
                "preburnAccumulators[legIndex].totalShortLiquidity",
                preburnAccumulators[legIndex].totalShortLiquidity
            );
            emit LogUint256(
                "$projectedPremia[legIndex].idealPremium1",
                $projectedPremia[legIndex].idealPremium1
            );
            emit LogUint256("$postburnSettledToken1", $postburnSettledToken1);
            assertWithMsg(
                int256(int128($postburnSettledToken1)) ==
                    Math.max(
                        int256(int128(preburnAccumulators[legIndex].settledToken1)) -
                            $expectedSettledToken1DifferenceForChunk,
                        0
                    ),
                "Settled token1s did not increase by the collected tokens and/or increase/decrease by the (prorated) premium for the leg"
            );

            // INVARIANT:
            // (postBurnGrossPremiaSFPMAccumulator - postBurnGrossPremiaLast)*postBurnShortLiq/2^64
            // ==
            // (preBurnGrossPremiaSFPMAccumulator - preBurnGrossPremiaLast)*preBurnShortLiq/2^64 - idealPremium
            if ($position.isLong(legIndex) != 0) {
                // Gross premia should not change on the long legs' chunks
                $projectedPremia[legIndex].idealPremium0 = 0;
                $projectedPremia[legIndex].idealPremium1 = 0;
            }

            (
                $postburnSFPMGrossPremiaAccumulator0,
                $postburnSFPMGrossPremiaAccumulator1
            ) = _get_sfpm_accumulators_without_itm_swap($position, legIndex);

            $postburnShortLiquidity = _get_total_short_liquidity(
                $position,
                PanopticMath.getLiquidityChunk($position, legIndex, $posSize),
                legIndex
            );

            // We should expect to catch an assertion failure that:
            // for short legs that are owed 0 premia,
            // but the short liquidity changes after burning,
            // the gross premia will not change.
            // (even though it should - we corrected this in a later version of the contracts)
            // If we don't get that, then we're not working properly.
            // NOTE: 7/27 - Confirmed, we got this! Can feel free to modify this test to specifically
            // skip those cases if you want to see other possible invariant failures
            // NOTE: 7/29 - Added that skip as an `if` before each assertion:
            if (
                !($projectedPremia[legIndex].idealPremium0 == 0 && $position.isLong(legIndex) == 0)
            ) {
                uint256 projectedPostburnGrossPremia0 = (uint256(
                    (uint256(preburnAccumulators[legIndex].sfpmGrossPremiaAccumulator0) -
                        uint256(preburnAccumulators[legIndex].grossPremiaLast0)) *
                        uint256(preburnAccumulators[legIndex].totalShortLiquidity)
                ) >> 64) - $projectedPremia[legIndex].idealPremium0;
                uint256 actualPostburnGrossPremia0 = (($postburnSFPMGrossPremiaAccumulator0 -
                    $postburnGrossPremiaLast0) * $postburnShortLiquidity) >> 64;
                if (actualPostburnGrossPremia0 >= projectedPostburnGrossPremia0) {
                    assertWithMsg(
                        // Tolerance of 1 as the contracts round s_grossPremiumLast down,
                        // and our idealPremium calc may not
                        actualPostburnGrossPremia0 - projectedPostburnGrossPremia0 <= 1,
                        "grossPremiaLast on token0 did not go down by the total amount of premia owed for the now-burnt position"
                    );
                } else {
                    // Assert postburn total premium for this chunk suffices for remaining positions
                    _assert_actual_postburn_is_gt_sum_of_ideal_premia_projections(
                        _chunk_for($position, legIndex),
                        actualPostburnGrossPremia0,
                        true
                    );
                }
            }

            emit LogUint256(
                "$postburnSFPMGrossPremiaAccumulator1",
                $postburnSFPMGrossPremiaAccumulator1
            );
            emit LogUint256("$postburnGrossPremiaLast1", $postburnGrossPremiaLast1);
            emit LogUint256("$postburnShortLiquidity", $postburnShortLiquidity);
            emit LogUint256(
                "preburnAccumulators[legIndex].sfpmGrossPremiaAccumulator1",
                preburnAccumulators[legIndex].sfpmGrossPremiaAccumulator1
            );
            emit LogUint256(
                "preburnAccumulators[legIndex].grossPremiaLast1",
                preburnAccumulators[legIndex].grossPremiaLast1
            );
            emit LogUint256(
                "preburnAccumulators[legIndex].totalShortLiquidity",
                preburnAccumulators[legIndex].totalShortLiquidity
            );
            emit LogUint256(
                "$projectedPremia[legIndex].idealPremium1",
                $projectedPremia[legIndex].idealPremium1
            );
            if (
                !($projectedPremia[legIndex].idealPremium1 == 0 && $position.isLong(legIndex) == 0)
            ) {
                uint256 projectedPostburnGrossPremia1 = (uint256(
                    (uint256(preburnAccumulators[legIndex].sfpmGrossPremiaAccumulator1) -
                        uint256(preburnAccumulators[legIndex].grossPremiaLast1)) *
                        uint256(preburnAccumulators[legIndex].totalShortLiquidity)
                ) >> 64) - $projectedPremia[legIndex].idealPremium1;
                uint256 actualPostburnGrossPremia1 = (($postburnSFPMGrossPremiaAccumulator1 -
                    $postburnGrossPremiaLast1) * $postburnShortLiquidity) >> 64;
                if (actualPostburnGrossPremia1 >= projectedPostburnGrossPremia1) {
                    assertWithMsg(
                        // Tolerance of 1 as the contracts round s_grossPremiumLast down,
                        // and our idealPremium calc may not
                        actualPostburnGrossPremia1 - projectedPostburnGrossPremia1 <= 1,
                        "grossPremiaLast on token1 did not go down by the total amount of premia owed for the now-burnt position"
                    );
                } else {
                    // Assert postburn total premium for this chunk suffices for remaining positions
                    _assert_actual_postburn_is_gt_sum_of_ideal_premia_projections(
                        _chunk_for($position, legIndex),
                        actualPostburnGrossPremia1,
                        false
                    );
                }
                if (uint256($postburnSFPMGrossPremiaAccumulator1) == 477726361074331828) {
                    assertWithMsg(false, "passed your old case!");
                }
            }
            delete $expectedSettledToken0DifferenceForChunk;
            delete $expectedSettledToken1DifferenceForChunk;
            delete $postburnSettledToken0;
            delete $postburnSettledToken1;
            delete $postburnGrossPremiaLast0;
            delete $postburnGrossPremiaLast1;
            delete $postburnSFPMGrossPremiaAccumulator0;
            delete $postburnSFPMGrossPremiaAccumulator1;
            delete $postburnShortLiquidity;
        }
    }

    function _assert_actual_postburn_is_gt_sum_of_ideal_premia_projections(
        bytes32 chunkKey,
        uint256 actualPostburnGrossPremia,
        bool isToken0
    ) internal {
        uint256 accumulatedIdealPremiaProjectionsForActorsLegsInThisChunk = 0;

       for (uint256 actorIndex = 0; actorIndex < actors.length; actorIndex++) {
           address actor = actors[actorIndex];
           for (uint256 positionIndex = 0; positionIndex < userPositions[actor]; positionIndex++) {
               TokenId position = userPositions[actor][positionIndex];
               for (uint256 legIndex = 0; legIndex < position.countLegs(); legIndex++) {
                   if (_chunk_for(position, accumulatorLoopLegIndex) == chunkKey) {
                       uint256 idealPremium = _calc_ideal_premium_using_postburn_values(position, legIndex, isToken0);
                       accumulatedIdealPremiaProjectionsForActorsLegsInThisChunk += idealPremium;
                   }
               }
           }
       }

       assertWithMsg(
           accumulatedIdealPremiaProjectionsForActorsLegsInThisChunk <= actualPostburnGrossPremia,
           "Actual post-burn gross premia is below sum of ideal premia projections for outstanding positions"
       );
    }

    function _chunk_for(TokenId position, uint256 legIndexA) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(position.strike(legIndex), position.width(legIndex), position.tokenType(legIndex)));
    }

    function _calc_ideal_premium_using_postburn_values(
        TokenId position,
        uint256 legIndex,
        bool isToken0
    ) internal view returns (uint256) {
        (uint128 sfpmGrossPremiaAccumulator0, uint128 sfpmGrossPremiaAccumulator1) = _get_sfpm_accumulators_without_itm_swap(
            position,
            legIndex
        );

        LiquidityChunk liquidityChunk = PanopticMath.getLiquidityChunk(
            position,
            legIndex,
            posSize
        );
        uint128 positionLiquidity = liquidityChunk.liquidity();

        (uint128 premiumGrowth0, uint128 premiumGrowth1) = panopticPool.optionData(
            position,
            caller,
            legIndex
        );

        if (isToken0) {
            return uint128(
                (
                    uint256(sfpmGrossPremiaAccumulator0 - premiumGrowth0) *
                    uint256(accumulators[legIndex].positionLiquidity)
                ) >> 64
            )
        } else {
            return uint128(
                (
                    uint256(sfpmGrossPremiaAccumulator1 - premiumGrowth1) *
                    uint256(accumulators[legIndex].positionLiquidity)
                ) >> 64
            )
        }
    };

    function _compare_against_preburn_values(
        int128 expectedNonPremiaToken0Difference,
        int128 expectedNonPremiaToken1Difference,
        PreburnValues memory burnersPreburnValues
    ) external {
        if (!$calledFromMakeAssertions) {
            return;
        }

        assertWithMsg(
            panopticPool.numberOfPositions($caller) == burnersPreburnValues.positionsOpened - 1,
            "Burning a position did not decrease the position counter"
        );

        (
            int128 totalProjectedProratedPremium0,
            int128 totalProjectedProratedPremium1
        ) = _net_up_prorated_premia();

        int256 expectedToken0Difference = totalProjectedProratedPremium0 -
            expectedNonPremiaToken0Difference;
        int256 expectedToken1Difference = totalProjectedProratedPremium1 -
            expectedNonPremiaToken1Difference;

        uint256 burnersPostburnAssetsInCT0 = collToken0.convertToAssets(
            collToken0.balanceOf($caller)
        );
        assertWithMsg(
            // Differences in the CT tracker can be off-by-one as a payment can tick you over a
            // rounding threshold
            abs(
                int256(burnersPreburnValues.assetsInCT0) +
                    expectedToken0Difference -
                    int256(burnersPostburnAssetsInCT0)
            ) <= 1,
            "Burners assets in collToken0 were not deducted/added the net premia"
        );

        uint256 burnersPostburnAssetsInCT1 = collToken1.convertToAssets(
            collToken1.balanceOf($caller)
        );
        assertWithMsg(
            abs(
                int256(burnersPreburnValues.assetsInCT1) +
                    expectedToken1Difference -
                    int256(burnersPostburnAssetsInCT1)
            ) <= 1,
            "Burners assets in collToken1 were not deducted/added the net premia"
        );
    }

    function _net_up_prorated_premia()
        internal
        view
        returns (int128 totalProjectedProratedPremium0, int128 totalProjectedProratedPremium1)
    {
        for (uint legIndex = 0; legIndex < $position.countLegs(); legIndex++) {
            totalProjectedProratedPremium0 += $position.isLong(legIndex) == 1
                ? -1 * int128($projectedPremia[legIndex].proratedPremium0)
                : int128($projectedPremia[legIndex].proratedPremium0);
            totalProjectedProratedPremium1 += $position.isLong(legIndex) == 1
                ? -1 * int128($projectedPremia[legIndex].proratedPremium1)
                : int128($projectedPremia[legIndex].proratedPremium1);
        }
    }

    function _assert_effective_liquidity_is_above_threshold() internal {
        bool effectiveLiquidityIsAboveThreshold;
        for (uint legIndex = 0; legIndex < $position.countLegs(); legIndex++) {
            LeftRightUnsigned accountLiquidities = sfpm.getAccountLiquidity(
                address(pool),
                address(panopticPool),
                $position.tokenType(legIndex),
                $tickLower,
                -1 * $tickLower
            );

            uint128 netLiquidity = accountLiquidities.rightSlot();
            uint128 totalLiquidity = accountLiquidities.leftSlot();
            // compute and return effective liquidity. Return if short=net=0, which is closing short position
            if (netLiquidity == 0) continue;

            uint256 effectiveLiquidityFactorX32;
            unchecked {
                effectiveLiquidityFactorX32 = (uint256(totalLiquidity) * 2 ** 32) / netLiquidity;
            }
            if (effectiveLiquidityFactorX32 > uint256(MAX_SPREAD))
                effectiveLiquidityIsAboveThreshold = true;
        }
        assertWithMsg(
            effectiveLiquidityIsAboveThreshold,
            "got EffectiveLiquidityAboveThreshold when attempting to burn, but that is not true"
        );
    }

    /// @custom:property PANO-BURN-003 After burning all options, the number of positions of the user must be zero
    /// @custom:property PANO-BURN-004 After burning some options, the number of positions of the user should go down proportionally
    /// @custom:precondition The user has at least one position open
    function burn_many_options(
        bool isCovered,
        bool burnAll,
        uint numPositionsToBurn,
        bool fromFront
    ) public {
        uint256 preburnNumPositions = userPositions[msg.sender].length;
        if (preburnNumPositions < 1) revert();

        numPositionsToBurn = burnAll
            ? preburnNumPositions
            : numPositionsToBurn % preburnNumPositions;

        TokenId[] memory positionsToBurn = new TokenId[](numPositionsToBurn);
        TokenId[] memory retainedPositions = new TokenId[](
            preburnNumPositions - numPositionsToBurn
        );

        int24 tickLimitLow = isCovered ? int24(-887272) : int24(887272);

        // Get a subset of userPositions[caller]
        for (uint i = 0; i < numPositionsToBurn; i++)
            positionsToBurn[i] = userPositions[msg.sender][
                fromFront ? i : preburnNumPositions - (i + 1)
            ];

        for (uint i = 0; i < preburnNumPositions; i++) {
            if (
                (fromFront && i >= positionsToBurn.length) ||
                (!fromFront && i < (positionsToBurn.length - 1))
            ) {
                retainedPositions[
                    fromFront ? i : (preburnNumPositions - numPositionsToBurn) - i
                ] = userPositions[msg.sender][fromFront ? preburnNumPositions - i : i];
            }
        }

        // Get pre-burn values to compare against
        PreburnValues memory burnersPreburnValues = PreburnValues({
            token0Balance: IERC20(pool.token0()).balanceOf(msg.sender),
            token1Balance: IERC20(pool.token1()).balanceOf(msg.sender),
            assetsInCT0: collToken0.convertToAssets(collToken0.balanceOf(msg.sender)),
            assetsInCT1: collToken1.convertToAssets(collToken1.balanceOf(msg.sender)),
            positionsOpened: preburnNumPositions
        });
        AccumulatorsForLeg[][] memory preburnAccumulators = new AccumulatorsForLeg[][](
            preburnNumPositions
        );
        for (uint positionIndex = 0; positionIndex < positionsToBurn.length; positionIndex++) {
            (uint128 posSize, , ) = panopticPool.optionPositionBalance(
                msg.sender,
                positionsToBurn[positionIndex]
            );
            try
                this._get_preburn_accumulators(positionsToBurn[positionIndex], msg.sender, posSize)
            {
                (preburnAccumulators[positionIndex], ) = this._get_preburn_accumulators(
                    positionsToBurn[positionIndex],
                    msg.sender,
                    posSize
                );
            } catch (bytes memory preburn_getting_err) {
                emit LogBytes("preburn_getting_err", preburn_getting_err);
                assertWithMsg(false, "Error getting preburn accumulators");
            }
        }

        // TODO: Poke here -
        // per https://github.com/panoptic-labs/panoptic-v1-core-private/pull/109#pullrequestreview-2188530484
        // Figure out what changes in settled tokens, burner token balances, and so on we expect
        // if we burn each individually
        try
            this._simulate_burn_on_each_position(
                msg.sender,
                positionsToBurn,
                tickLimitLow,
                preburnAccumulators,
                burnersPreburnValues
            )
        {
            assertWithMsg(false, "The _simulate_burn_on_each_position helper should always revert");
        } catch (bytes memory _err) {
            assembly ("memory-safe") {
                _err := add(_err, 0x04)
            }
            (
                int256[] memory underlyingAssetDifferences,
                int128[][] memory settledToken0Difference,
                int128[][] memory settledToken1Difference,
                int128[][] memory grossPremiaLast0Difference,
                int128[][] memory grossPremiaLast1Difference
            ) = abi.decode(_err, (int256[], int128[][], int128[][], int128[][], int128[][]));

            // Then, prove that burning them all at once makes the same differences:
            // 1. burn
            panopticPool.burnOptions(
                positionsToBurn,
                retainedPositions,
                tickLimitLow,
                -1 * tickLimitLow
            );
            assertWithMsg(
                panopticPool.numberOfPositions(msg.sender) ==
                    preburnNumPositions - positionsToBurn.length,
                "Not all positions were burned"
            );

            // 2. Assert: Same effect on burner's token balance, and assets in CTs, as burning each
            //            position individually
            (
                uint256 burnersPostburnToken0Balance,
                uint256 burnersPostburnToken1Balance
            ) = _get_token_balances(msg.sender);
            uint256 burnersPostburnAssetsInCT0 = collToken0.convertToAssets(
                collToken0.balanceOf(msg.sender)
            );
            uint256 burnersPostburnAssetsInCT1 = collToken1.convertToAssets(
                collToken1.balanceOf(msg.sender)
            );
            assertWithMsg(
                int256(burnersPostburnToken0Balance) - int256(burnersPreburnValues.token0Balance) ==
                    underlyingAssetDifferences[0],
                "Burners token0 balance did not increase by the same amount as if they had burned each position one-by-one"
            );
            assertWithMsg(
                int256(burnersPostburnToken1Balance) - int256(burnersPreburnValues.token1Balance) ==
                    underlyingAssetDifferences[1],
                "Burners token1 balance did not increase by the same amount as if they had burned each position one-by-one"
            );

            assertWithMsg(
                int256(burnersPreburnValues.assetsInCT0) + underlyingAssetDifferences[2] ==
                    int256(burnersPostburnAssetsInCT0),
                "Burners assets in collToken0 did not change by the same amount as if they had burned each position one-by-one"
            );
            assertWithMsg(
                int256(burnersPreburnValues.assetsInCT1) + underlyingAssetDifferences[3] ==
                    int256(burnersPostburnAssetsInCT1),
                "Burners assets in collToken1 did not change by the same amount as if they had burned each position one-by-one"
            );

            // 3. Assert: Same effect on the accumulators for each chunk as burning each one individually
            //    Compare the recorded differences in accumulators after  burning each pos
            //    individually against what we record when we call for accumulators after burning
            //    all at once
            _assert_burning_all_at_once_is_same_as_burning_individually(
                positionsToBurn,
                preburnAccumulators,
                settledToken0Difference,
                settledToken1Difference,
                grossPremiaLast0Difference,
                grossPremiaLast1Difference
            );

            // The user's positions are now just the ones we didn't burn
            userPositions[msg.sender] = retainedPositions;
        }
    }

    function _get_token_balances(
        address caller
    ) internal view returns (uint256 tokenBalance0, uint256 tokenBalance1) {
        tokenBalance0 = IERC20(pool.token0()).balanceOf(caller);
        tokenBalance1 = IERC20(pool.token1()).balanceOf(caller);
    }

    error BurnSimResults(
        int256[] underlyingAssetDifferences,
        int128[][] settledToken0DifferenceForLegsChunk,
        int128[][] settledToken1DifferenceForLegsChunk,
        int128[][] grossPremiaLast0DifferenceForLegsChunk,
        int128[][] grossPremiaLast1DifferenceForLegsChunk
    );

    function _simulate_burn_on_each_position(
        address caller,
        TokenId[] memory positionsToBurn,
        int24 tickLimitLow,
        AccumulatorsForLeg[][] memory accumulators,
        PreburnValues memory burnersPreburnValues
    ) external {
        // Initialise storage arrays we'll be temporarily storing stuff in:
        $settledToken0DifferenceForLegsChunk = new int128[][](positionsToBurn.length);
        $settledToken1DifferenceForLegsChunk = new int128[][](positionsToBurn.length);
        $grossPremiaLast0DifferenceForLegsChunk = new int128[][](positionsToBurn.length);
        $grossPremiaLast1DifferenceForLegsChunk = new int128[][](positionsToBurn.length);

        TokenId[] memory positionsNew = userPositions[caller];
        for (uint positionIndex = 0; positionIndex < positionsToBurn.length; positionIndex++) {
            TokenId position = positionsToBurn[positionIndex];
            positionsNew = _get_list_without_tokenid(positionsNew, position);
            panopticPool.burnOptions(position, positionsNew, tickLimitLow, -1 * tickLimitLow);
        }

        // Get the overall differences in the accumulators now that we've burned all legs:
        // NOTE - we'll have repeated recorded differences if two legs touched the same chunk.
        // That's OK - we'll just evaluate it twice in the caller - no need to be efficient
        for (uint positionIndex = 0; positionIndex < positionsToBurn.length; positionIndex++) {
            TokenId position = positionsToBurn[positionIndex];
            $settledToken0DifferenceForLegsChunk[positionIndex] = new int128[](
                position.countLegs()
            );
            $settledToken1DifferenceForLegsChunk[positionIndex] = new int128[](
                position.countLegs()
            );
            $grossPremiaLast0DifferenceForLegsChunk[positionIndex] = new int128[](
                position.countLegs()
            );
            $grossPremiaLast1DifferenceForLegsChunk[positionIndex] = new int128[](
                position.countLegs()
            );
            for (uint legIndex = 0; legIndex < position.countLegs(); legIndex++) {
                (
                    uint128 postburnSettledToken0,
                    uint128 postburnSettledToken1,
                    uint128 postburnGrossPremiaLast0,
                    uint128 postburnGrossPremiaLast1
                ) = panopticPool.premiaSettlementData(position, legIndex);
                $settledToken0DifferenceForLegsChunk[positionIndex][legIndex] =
                    int128(postburnSettledToken0) -
                    int128(accumulators[positionIndex][legIndex].settledToken0);
                $settledToken1DifferenceForLegsChunk[positionIndex][legIndex] =
                    int128(postburnSettledToken1) -
                    int128(accumulators[positionIndex][legIndex].settledToken1);
                $grossPremiaLast0DifferenceForLegsChunk[positionIndex][legIndex] =
                    int128(postburnGrossPremiaLast0) -
                    int128(accumulators[positionIndex][legIndex].grossPremiaLast0);
                $grossPremiaLast1DifferenceForLegsChunk[positionIndex][legIndex] =
                    int128(postburnGrossPremiaLast1) -
                    int128(accumulators[positionIndex][legIndex].grossPremiaLast1);
            }
        }

        (
            uint256 burnersPostburnToken0Balance,
            uint256 burnersPostburnToken1Balance
        ) = _get_token_balances(caller);
        uint256 burnersPostburnAssetsInCT0 = collToken0.convertToAssets(
            collToken0.balanceOf(caller)
        );
        uint256 burnersPostburnAssetsInCT1 = collToken1.convertToAssets(
            collToken1.balanceOf(caller)
        );

        $underlyingAssetDifferences = new int256[](4);
        // By arbitrary convention - first two members of underlyingAssetDifferences are the
        // difference in burner's balance of token0 and token1 respectively
        $underlyingAssetDifferences[0] =
            int256(burnersPostburnToken0Balance) -
            int256(burnersPreburnValues.token0Balance);
        $underlyingAssetDifferences[1] =
            int256(burnersPostburnToken1Balance) -
            int256(burnersPreburnValues.token1Balance);

        // and second two are differences in the assets in the collateral trackers:
        $underlyingAssetDifferences[2] =
            int256(burnersPostburnAssetsInCT0) -
            int256(burnersPreburnValues.assetsInCT0);
        $underlyingAssetDifferences[3] =
            int256(burnersPostburnAssetsInCT1) -
            int256(burnersPreburnValues.assetsInCT1);

        revert BurnSimResults(
            $underlyingAssetDifferences,
            // We can't revert with an array of Structs, sadly, so we revert with an array of the
            // 4 accumulator differences we care about.
            $settledToken0DifferenceForLegsChunk,
            $settledToken1DifferenceForLegsChunk,
            $grossPremiaLast0DifferenceForLegsChunk,
            $grossPremiaLast1DifferenceForLegsChunk
        );
    }

    function _assert_burning_all_at_once_is_same_as_burning_individually(
        TokenId[] memory positionsBurnt,
        AccumulatorsForLeg[][] memory preburnAccumulators,
        int128[][] memory settledToken0Difference,
        int128[][] memory settledToken1Difference,
        int128[][] memory grossPremiaLast0Difference,
        int128[][] memory grossPremiaLast1Difference
    ) internal {
        for (uint positionIndex = 0; positionIndex < positionsBurnt.length; positionIndex++) {
            TokenId position = positionsBurnt[positionIndex];
            for (uint legIndex = 0; legIndex < position.countLegs(); legIndex++) {
                (
                    uint128 postburnSettledToken0,
                    uint128 postburnSettledToken1,
                    uint128 postburnGrossPremiaLast0,
                    uint128 postburnGrossPremiaLast1
                ) = panopticPool.premiaSettlementData(position, legIndex);

                assertWithMsg(
                    int128(postburnSettledToken0) ==
                        int128(preburnAccumulators[positionIndex][legIndex].settledToken0) -
                            settledToken0Difference[positionIndex][legIndex],
                    "Settled token0s did not decrease by the aggregated difference resulting from burning each position individually"
                );
                assertWithMsg(
                    int128(postburnSettledToken1) ==
                        int128(preburnAccumulators[positionIndex][legIndex].settledToken1) -
                            settledToken1Difference[positionIndex][legIndex],
                    "Settled token1s did not decrease by the aggregated difference resulting from burning each position individually"
                );

                assertWithMsg(
                    int128(postburnGrossPremiaLast0) ==
                        int128(preburnAccumulators[positionIndex][legIndex].grossPremiaLast0) +
                            grossPremiaLast0Difference[positionIndex][legIndex],
                    "grossPremiaLast on token0 did not go down by the aggregated difference resulting from burning each position individually"
                );
                assertWithMsg(
                    int128(postburnGrossPremiaLast1) ==
                        int128(preburnAccumulators[positionIndex][legIndex].grossPremiaLast1) +
                            grossPremiaLast1Difference[positionIndex][legIndex],
                    "grossPremiaLast on token1 did not go down by the aggregated difference resulting from burning each position individually"
                );
            }
        }
    }

    // @custom:property PANO-SYS-009 The pool's grossPremiaLast is always less than what the SFPM
    // records as the grossPremia for that pool.
    function invariant_pools_gross_premia_is_less_than_sfpms_gross_premia(
        uint fuzzedActorIndex,
        uint fuzzedPositionIndex
    ) public {
        address positionHolder = actors[fuzzedActorIndex % actors.length];
        if (userPositions[positionHolder].length == 0) return;

        TokenId position = userPositions[positionHolder][
            fuzzedPositionIndex % userPositions[positionHolder].length
        ];

        for (uint legIndex = 0; legIndex < position.countLegs(); legIndex++) {
            (, , uint128 grossPremiaLastToken0, uint128 grossPremiaLastToken1) = panopticPool
                .premiaSettlementData(position, legIndex);

            // (Below is an old comment that i am leaving in case the "corrected" approach is still incorrect)
            // TODO: you don't actually need the sfpm.getAccountPremiumGross helper, and it returns
            // an incorrect value - need to filter SFPM gross premia by pool.
            // instead, you should getAccountPremium(), which returns a per-liquidity amount of premium owed to
            // position holders like the account+position you passed in
            // then, multiply by liquidity
            // that product is the total gross premia SFPM thinks is owed to the Pool the position is in, and is the value
            // the pool's grossPremiaLast should never exceed.
            // LeftRightUnsigned sfpmGrossPremia = sfpm.getAccountPremiumGross(position, legIndex);
            // TODO: The new, corrected way is in _get_sfpm_accumulators - need to confirm its correct
            (
                uint128 sfpmGrossPremiaAccumulator0,
                uint128 sfpmGrossPremiaAccumulator1
            ) = _get_sfpm_accumulators(position, legIndex);

            assertWithMsg(
                grossPremiaLastToken0 <= sfpmGrossPremiaAccumulator0,
                "Pools grossPremiaLastToken0 is greater than SFPMs grossPremiaToken0"
            );

            assertWithMsg(
                grossPremiaLastToken1 <= sfpmGrossPremiaAccumulator1,
                "Pools grossPremiaLastToken1 is greater than SFPMs grossPremiaToken1"
            );
        }
    }

    function _get_total_short_liquidity(
        TokenId position,
        LiquidityChunk liqChunk,
        uint256 legIndex
    ) internal view returns (uint128) {
        LeftRightUnsigned currentLiquidity = sfpm.getAccountLiquidity(
            address(pool),
            address(panopticPool),
            position.tokenType(legIndex),
            liqChunk.tickLower(),
            liqChunk.tickUpper()
        );
        /* (netLiquidity:removedLiquidity -> rightSlot:leftSlot) */
        return currentLiquidity.rightSlot() + currentLiquidity.leftSlot();
    }

    int24 $currentTick;
    int24 $tickLower;
    int24 $tickUpper;

    function _get_sfpm_accumulators(
        TokenId position,
        uint256 legIndex
    ) internal returns (uint128 premiumAccumulator0, uint128 premiumAccumulator1) {
        (, $currentTick, , , , , ) = pool.slot0();
        ($tickLower, $tickUpper) = position.asTicks(legIndex);
        (premiumAccumulator0, premiumAccumulator1) = sfpm.getAccountPremium(
            address(pool),
            address(panopticPool),
            position.tokenType(legIndex),
            $tickLower,
            $tickUpper,
            $currentTick,
            position.isLong(legIndex)
        );
    }

    function _get_sfpm_accumulators_without_itm_swap(
        TokenId position,
        uint256 legIndex
    ) internal returns (uint128 premiumAccumulator0, uint128 premiumAccumulator1) {
        ($tickLower, $tickUpper) = position.asTicks(legIndex);
        (premiumAccumulator0, premiumAccumulator1) = sfpm.getAccountPremium(
            address(pool),
            address(panopticPool),
            position.tokenType(legIndex),
            $tickLower,
            $tickUpper,
            type(int24).max,
            position.isLong(legIndex)
        );
    }

    // DONE: Add partial burning - greater than 1, less than all
    // TODO: Add assertions about things that should revert to the burn methods
    // DOING: Check that the premiaSettlementData returns differences in s_settledTokens by the expected amount:
    //        (may have to get data from uniswap as inputs here (or maybe from SFPM))
    // DOING: Verify account premium change on position closes:
    //        (premiaSettlementData - the total amount among all sellers)
    //        take the account premia:
    //           s_grossPremiumLast and s_grossPremium
    //        and multiply by liquidity to get premia for all sellers
    // DONE: gross premia last for any given leg always less than SFPM's grossPremia
    // WONTDO: global invariant - pool.grossPremiaLast is never underflown
    //         (maybe test grossPremiaLast is never within X amount of uint256.max,
    //          where X is sufficiently small to seem like an underflow?)
    // WONTDO: Check that rounding to 0 works appropriately where it should
    //         (but what values?)
    // TODO: Run these tests and you should find incorrect premia calculations caused by:
    //       https://github.com/panoptic-labs/panoptic-v1-core-private/blob/abb4eaabf0262247b256fca58108d004472dc2b0/contracts/libraries/PanopticMath.sol#L902-L907
    // TODO: Add similar Accumulator tests for mint. accumulators to test for:
    // settled tokens goes up with collected tokens from SFPM
    // gross premia last does not change

    ////////////////////////////////////////////////////
    // Liquidation
    ////////////////////////////////////////////////////

    function log_bound(uint256 x) internal {
        uint256 out = boundLog(x, 0, 255);
        emit LogUint256("full-range", out);
        assertWithMsg((out <= type(uint256).max) && (out >= 0), "within bounds");

        out = boundLog(x, 0, 15);
        emit LogUint256("0-15", out);
        assertWithMsg((out <= 2 ** 15) && (out >= 0), "within bounds");

        out = boundLog(x, 32, 224);
        emit LogUint256("32-224", out);
        assertWithMsg((out <= 2 ** 224) && (out >= 2 ** 32), "within bounds");

        out = boundLog(x, 100, 114);
        emit LogUint256("100-114", out);
        assertWithMsg((out <= 2 ** 114) && (out >= 2 ** 100), "within bounds");

        out = boundLog(x, 128, 129);
        emit LogUint256("128-129", out);
        assertWithMsg((out <= 2 ** 129) && (out >= 2 ** 128), "within bounds");

        out = boundLog(x, 253, 255);
        emit LogUint256("253-256", out);
        assertWithMsg((out <= 2 ** 255) && (out >= 2 ** 253), "within bounds");

        out = boundLog(x, 254, 255);
        emit LogUint256("254-256", out);
        assertWithMsg((out <= 2 ** 255) && (out >= 2 ** 254), "within bounds");
    }

    function try_settle_long(uint256 fuzzedActorIndex) public {
        // NOTE: This may be the same as msg.sender. Thats ok; you can settleLongPremium yourself.
        address settlee = actors[fuzzedActorIndex % actors.length];

        if (userPositions[settlee].length == 0) return;

        for (uint256 i = 0; i < userPositions[settlee].length; ++i) {
            // Pick a leg at random; skip this position if there isn't / we didn't pick a long leg.
            if (userPositions[settlee][i].countLongs() == 0) continue;
            uint256 longIndex = ((fuzzedActorIndex >> 4) % userPositions[settlee][i].countLegs());
            if (userPositions[settlee][i].isLong(longIndex) != 1) continue;

            // 1. calculate what the premium settled out to settlee _should_ be
            (uint128 premium0, uint128 premium1) = _calc_premium_for_each_token(
                settlee,
                userPositions[settlee][i],
                longIndex
            );

            // 2. get users balance + settled total in CT before any settling occurs
            uint256 settleeAssetsInCT0Before = _assets_in_ct(collToken0, settlee);
            uint256 settleeAssetsInCT1Before = _assets_in_ct(collToken1, settlee);

            (uint128 settledForChunkBefore0, uint128 settledForChunkBefore1, , ) = panopticPool
                .premiaSettlementData(userPositions[settlee][i], longIndex);

            // 3. trigger a settlement of long premium
            // TODO: why do we do this reorg stuff here?
            TokenId[] memory settleesPositionsReorg = userPositions[settlee];
            settleesPositionsReorg[userPositions[settlee].length - 1] = userPositions[settlee][i];
            settleesPositionsReorg[i] = userPositions[settlee][userPositions[settlee].length - 1];

            hevm.prank(msg.sender);
            panopticPool.settleLongPremium(settleesPositionsReorg, settlee, longIndex);

            // 4. get accumulated settledTokens for each CT and ensure it increased by calc'ed premium amount
            (uint128 settledForChunkAfter0, uint128 settledForChunkAfter1, , ) = panopticPool
                .premiaSettlementData(userPositions[settlee][i], longIndex);

            assertWithMsg(
                settledForChunkAfter0 == (settledForChunkBefore0 + premium0) &&
                    settledForChunkAfter1 == (settledForChunkBefore1 + premium1),
                "Settled tokens for chunk recorded in CT did not increase by calculated premium"
            );

            // 5. get users balance in CT after, and assert it reduced by appropriate amounts
            assertWithMsg(
                (((settleeAssetsInCT0Before - _assets_in_ct(collToken0, settlee)) == premium0) &&
                    ((settleeAssetsInCT1Before - _assets_in_ct(collToken1, settlee)) == premium1)),
                "User receiving settled long premia had their assets in the CT decrease by an amount other than the calculated premiums"
            );
        }
    }

    // NOTE: this is basically trying to re-calc a value in s_options -
    //       probably derived from logic in closePosition / getPremium
    function _calc_premium_for_each_token(
        address settlee,
        TokenId position,
        uint256 longIndex
    ) internal returns (uint128 premium0, uint128 premium1) {
        (uint128 numContractsOfPosition, , ) = panopticPool.optionPositionBalance(
            settlee,
            position
        );
        uint128 liquidity = PanopticMath
            .getLiquidityChunk(position, longIndex, numContractsOfPosition)
            .liquidity();

        (uint128 optionData0, uint128 optionData1) = panopticPool.optionData(
            position,
            settlee,
            longIndex
        );

        (, currentTick, , , , , ) = pool.slot0();
        uint256 tokenType = position.tokenType(longIndex);
        (int24 tickLower, int24 tickUpper) = position.asTicks(longIndex);
        (uint128 premiumAccumulator0, uint128 premiumAccumulator1) = sfpm.getAccountPremium(
            address(pool),
            address(panopticPool),
            tokenType,
            tickLower,
            tickUpper,
            currentTick,
            1
        );
        premium0 = ((premiumAccumulator0 - optionData0) * liquidity) >> 64;
        premium1 = ((premiumAccumulator1 - optionData1) * liquidity) >> 64;
    }

    function _assets_in_ct(CollateralTracker collToken, address holder) internal returns (uint256) {
        return collToken.convertToAssets(collToken.balanceOf(holder));
    }

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

        //_execute_burn_simulation(liquidatee, liquidator);

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

        hevm.prank(liquidator);
        try
            panopticPool.liquidate(
                liquidator_positions,
                liquidatee,
                delegations,
                liquidated_positions
            )
        {
            emit LogString("liquidation success");
            //assertWithMsg(0>1, "success liquidation");
        } catch (bytes memory _err) {
            emit LogBytes("err", _err);
            uint256 receivedSelector = uint256(bytes32(bytes4(_err))) >> 224;
            emit LogUint256("selector", receivedSelector);
            if (receivedSelector == 3877932976) {
                emit LogString("StaleTWAP");
            } else if (receivedSelector == 1126409557) {
                emit LogString("NotEnoughLiquidity");
            }
        }
        panopticPool.liquidate(liquidator_positions, liquidatee, delegations, liquidated_positions);

        currentTickOld = currentTick;
        (, currentTick, , , , , ) = pool.slot0();

        emit LogInt256("final tick", currentTick);
        _calculate_liquidation_bonus(TWAPtick, currentTick);

        /*
        burnSimResults.delegated0 = uint256(
            int256(
                collToken0.convertToShares(
                    uint256(int256(uint256(burnSimResults.delegated0)) + liqResults.bonus0)
                )
            )
        );
        burnSimResults.delegated1 = uint256(
            int256(
                collToken1.convertToShares(
                    uint256(int256(uint256(burnSimResults.delegated1)) + liqResults.bonus1)
                )
            )
        );

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
            assertWithMsg(
                (c0a < canaryBalances.rightSlot()) && (c1a < canaryBalances.leftSlot()),
                "protocol loss BOTH tokens"
            );
            assertWithMsg(c0a < canaryBalances.rightSlot(), "protocol loss token0");
            assertWithMsg(c1a < canaryBalances.leftSlot(), "protocol loss token1");
        }
    }

    function try_liquidate_aggressively() public {
        address liquidator = msg.sender;
        hevm.prank(liquidator);
        fund_and_approve();

        // Make sure the liquidator has tokens to delegate
        {
            uint256 lb0 = IERC20(USDC).balanceOf(liquidator);
            uint256 lb1 = IERC20(WETH).balanceOf(liquidator);
            hevm.prank(liquidator);
            deposit_to_ct(true, lb0);
            hevm.prank(liquidator);
            deposit_to_ct(false, lb1);
        }

        for (uint256 i; i < 5; ++i) {
            address liquidatee = actors[i];

            if (userPositions[liquidatee].length > 0) {
                require(liquidatee != liquidator);

                TokenId[] memory liquidated_positions = userPositions[liquidatee];
                TokenId[] memory liquidator_positions = userPositions[liquidator];

                emit LogUint256("liquidator positions length", liquidator_positions.length);
                emit LogUint256(
                    "liquidator positions length",
                    panopticPool.numberOfPositions(liquidator)
                );
                emit LogUint256("liquidated positions length", liquidated_positions.length);
                emit LogUint256(
                    "liquidated positions length",
                    panopticPool.numberOfPositions(liquidatee)
                );
                emit LogAddress("liquidator", liquidator);
                emit LogAddress("liquidated", liquidatee);

                int24 TWAPtick = PanopticMath.twapFilter(pool, 600);
                uint160 price;
                (price, currentTick, , , , , ) = pool.slot0();
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
                    .toLeftSlot(
                        uint96(collToken1.convertToAssets(collToken1.balanceOf(liquidator)))
                    );

                hevm.prank(liquidator);
                LeftRightUnsigned liquidatorBalances;
                address _liquidator = liquidator;
                {
                    uint c0b = collToken0.convertToAssets(collToken0.balanceOf(_liquidator));
                    uint c1b = collToken1.convertToAssets(collToken1.balanceOf(_liquidator));
                    liquidatorBalances = LeftRightUnsigned
                        .wrap(0)
                        .toRightSlot(uint128(c0b))
                        .toLeftSlot(uint128(c1b));
                }
                // If the position is not liquidatable, liquidation call must revert
                if (balanceCross > thresholdCross) {
                    perform_swap_no_delay(price * 100);
                    hevm.prank(liquidator);
                    try
                        panopticPool.liquidate(
                            liquidator_positions,
                            liquidatee,
                            delegations,
                            liquidated_positions
                        )
                    {
                        emit LogString("liquidated on the way up");
                        delete userPositions[liquidatee];
                    } catch (bytes memory _err) {
                        emit LogBytes("err", _err);
                        perform_swap_no_delay(price / 100);
                        hevm.prank(liquidator);
                        try
                            panopticPool.liquidate(
                                liquidator_positions,
                                liquidatee,
                                delegations,
                                liquidated_positions
                            )
                        {
                            emit LogString("liquidated on the way down");
                            delete userPositions[liquidatee];
                        } catch (bytes memory _err) {
                            emit LogBytes("err", _err);
                            emit LogString("not liquidatable");
                            revert();
                        }
                    }
                } else {
                    try
                        panopticPool.liquidate(
                            liquidator_positions,
                            liquidatee,
                            delegations,
                            liquidated_positions
                        )
                    {
                        emit LogString("liquidated account");
                        delete userPositions[liquidatee];
                    } catch (bytes memory _err) {
                        emit LogBytes("err", _err);
                        revert();
                    }

                    currentTickOld = currentTick;
                    {
                        uint c0a = collToken0.convertToAssets(collToken0.balanceOf(_liquidator));
                        uint c1a = collToken1.convertToAssets(collToken1.balanceOf(_liquidator));
                        assertWithMsg(
                            (PanopticMath.convert0to1(c0a, price) + c1a) >=
                                (PanopticMath.convert0to1(liquidatorBalances.rightSlot(), price) +
                                    liquidatorBalances.leftSlot()),
                            "liquidator lost money old price"
                        );
                    }
                    (price, currentTick, , , , , ) = pool.slot0();
                    {
                        uint c0a = collToken0.convertToAssets(collToken0.balanceOf(_liquidator));
                        uint c1a = collToken1.convertToAssets(collToken1.balanceOf(_liquidator));
                        assertWithMsg(
                            (PanopticMath.convert0to1(c0a, price) + c1a) >=
                                (PanopticMath.convert0to1(liquidatorBalances.rightSlot(), price) +
                                    liquidatorBalances.leftSlot()),
                            "liquidator lost money new price"
                        );
                    }

                    emit LogInt256("final tick", currentTick);

                    emit LogUint256(
                        "Number of positions",
                        panopticPool.numberOfPositions(liquidatee)
                    );
                    assertWithMsg(
                        panopticPool.numberOfPositions(liquidatee) == 0,
                        "Liquidation did not close all positions"
                    );

                    log_account_collaterals(liquidator);
                    log_account_collaterals(liquidatee);
                    log_trackers_status();
                }
            }
        }
    }

    function try_force_exercise_aggressively() public {
        address exercisor = msg.sender;

        for (uint256 i; i < 5; ++i) {
            address exercisee = actors[i];

            if (userPositions[exercisee].length > 0) {
                // Make sure the liquidator has tokens to delegate
                {
                    hevm.prank(exercisor);
                    fund_and_approve();

                    uint256 lb0 = IERC20(USDC).balanceOf(exercisor);
                    uint256 lb1 = IERC20(WETH).balanceOf(exercisor);
                    hevm.prank(exercisor);
                    deposit_to_ct(true, lb0);
                    hevm.prank(exercisor);
                    deposit_to_ct(false, lb1);
                }

                require(exercisee != exercisor);

                TokenId[] memory exercised_positions = userPositions[exercisee];
                TokenId[] memory exercisor_positions = userPositions[exercisor];

                emit LogUint256("exercisor positions length", exercisor_positions.length);
                emit LogUint256(
                    "exercisor positions length",
                    panopticPool.numberOfPositions(exercisor)
                );
                emit LogUint256("exercisee positions length", exercised_positions.length);
                emit LogUint256(
                    "exercisee positions length",
                    panopticPool.numberOfPositions(exercisee)
                );
                emit LogAddress("exercisor", exercisor);
                emit LogAddress("exercisee", exercisee);

                int24 TWAPtick = PanopticMath.twapFilter(pool, 600);
                uint160 price;
                (price, currentTick, , , , , ) = pool.slot0();
                emit LogInt256("TWAP tick", TWAPtick);
                emit LogInt256("Current tick", currentTick);

                log_account_collaterals(exercisor);
                log_account_collaterals(exercisee);
                log_trackers_status();

                require(exercised_positions.length > 0);

                (uint256 balanceCross, uint256 thresholdCross) = _get_solvency_balances(
                    exercisee,
                    TWAPtick
                );
                emit LogUint256("Balance cross", balanceCross);
                emit LogUint256("Threshold cross", thresholdCross);

                hevm.prank(exercisor);

                for (uint i; i < exercised_positions.length; ++i) {
                    TokenId _tokenid = exercised_positions[i];

                    if (_tokenid.countLongs() > 0) {
                        TokenId[] memory touchedPos = new TokenId[](1);
                        touchedPos[0] = _tokenid;
                        TokenId[] memory positions_new = _get_list_without_tokenid(
                            userPositions[exercisee],
                            _tokenid
                        );
                        log_account_collaterals(exercisor);
                        log_account_collaterals(exercisee);
                        log_trackers_status();
                        try
                            panopticPool.forceExercise(
                                exercisee,
                                touchedPos,
                                positions_new,
                                exercisor_positions
                            )
                        {
                            userPositions[exercisee] = positions_new;
                        } catch (bytes memory _err) {
                            emit LogBytes("err", _err);
                        }
                    }
                }

                currentTickOld = currentTick;
                (, currentTick, , , , , ) = pool.slot0();

                emit LogInt256("final tick", currentTick);

                emit LogUint256("Number of positions", panopticPool.numberOfPositions(exercisee));

                log_account_collaterals(exercisor);
                log_account_collaterals(exercisee);
                log_trackers_status();
            }
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
