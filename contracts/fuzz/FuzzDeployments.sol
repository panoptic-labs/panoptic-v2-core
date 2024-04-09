// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

//import {SetupTokens, SetupUniswap} from "./UniDeployments.sol";
import {WETH9} from "./fuzz-mocks/WETH9.sol";
import "./FuzzHelpers.sol";

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {IDonorNFT} from "@tokens/interfaces/IDonorNFT.sol";
import {DonorNFT} from "@periphery/DonorNFT.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {PanopticHelper} from "@periphery/PanopticHelper.sol";
import {IUniswapV3Factory} from "univ3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {TokenId} from "@types/TokenId.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v3-core/libraries/SqrtPriceMath.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
import {Math} from "@libraries/Math.sol";

contract FuzzDeployments is FuzzHelpers {
    /*SetupTokens tokens;
    SetupUniswap uniswap;*/
    PanopticHelper panopticHelper;
    SemiFungiblePositionManager sfpm;
    IUniswapV3Factory univ3factory;
    address poolReference;
    address collateralReference;
    IDonorNFT dnft;
    PanopticFactory panopticFactory;
    PanopticPool panopticPool;
    uint64 poolId;

    IUniswapV3Pool pool;
    uint24 poolFee;
    int24 poolTickSpacing;
    uint256 isWETH;
    uint160 currentSqrtPriceX96;
    int24 currentTick;
    uint256 feeGrowthGlobal0X128;
    uint256 feeGrowthGlobal1X128;
    uint256 poolBalance0;
    uint256 poolBalance1;

    int24 tickLower;
    int24 tickUpper;
    uint160 sqrtLower;
    uint160 sqrtUpper;
    int24[] tickLowers;
    int24[] tickUppers;
    uint160[] sqrtLowers;
    uint160[] sqrtUppers;

    int256 $amount0Moved;
    int256 $amount1Moved;
    int256[] $amount0Moveds;
    int256[] $amount1Moveds;

    uint128 positionSize;
    uint128 expectedLiq;
    uint128[] expectedLiqs;

    CollateralTracker collToken0;
    CollateralTracker collToken1;

    address[] actors;

    constructor() {
        /*tokens = new SetupTokens();
        uniswap = new SetupUniswap(tokens.token0(), tokens.token1());*/

        // Actors
        actors = new address[6]();
        actors[0] = address(0xa11ce);
        actors[1] = address(0xb0b);
        actors[2] = address(0xcafe);
        actors[3] = address(0xda210);
        actors[4] = address(0xedda);
        actors[5] = address(0xfaded); // this is by default the destination of swaps
        
        // See if mock or new deploy
        univ3factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

        sfpm = new SemiFungiblePositionManager(univ3factory);
        panopticHelper = new PanopticHelper(sfpm);

        // Import the Panoptic Pool reference (for cloning)
        poolReference = address(new PanopticPool(sfpm));

        // Import the Collateral Tracker reference (for cloning)
        collateralReference = address(
            new CollateralTracker(10, 2_000, 1_000, -1_024, 5_000, 9_000, 20_000)
        );

        dnft = IDonorNFT(address(new DonorNFT()));
        panopticFactory = new PanopticFactory(
            address(WETH),
            sfpm,
            univ3factory,
            dnft,
            poolReference,
            collateralReference
        );

        panopticFactory.initialize(address(this));
        DonorNFT(address(dnft)).changeFactory(address(panopticFactory));

        initialize();
    }

    function fund_and_approve() public {
        deal_USDC(msg.sender, 10000000 ether);
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

    function deposit_to_ct() public {
        uint256 bal0 = IERC20(collToken0.asset()).balanceOf(msg.sender);
        uint256 bal1 = IERC20(collToken1.asset()).balanceOf(msg.sender);

        hevm.prank(msg.sender);
        collToken0.deposit(bal0, msg.sender);
        hevm.prank(msg.sender);
        collToken1.deposit(bal1, msg.sender);
    }

    function initialize() internal {
        // initalize current pool we are deploying
        pool = USDC_WETH_5;
        poolFee = pool.fee();
        poolTickSpacing = pool.tickSpacing();
        poolId = PanopticMath.getPoolId(address(pool));
        isWETH = pool.token0() == address(WETH) ? 0 : 1;
        poolBalance0 = IERC20(pool.token0()).balanceOf(address(pool));
        poolBalance1 = IERC20(pool.token1()).balanceOf(address(pool));

        assert(pool.token0() == address(USDC));
        assert(pool.token1() == address(WETH));

        // give test contract a sufficient amount of tokens to deploy a new pool
        deal_USDC(address(this), 10000000 ether);
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
        feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
        feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();

        sfpm.initializeAMMPool(pool.token0(), pool.token1(), poolFee);

        panopticPool = panopticFactory.deployNewPool(
            pool.token0(),
            pool.token1(),
            poolFee,
            bytes32(uint256(uint160(address(this))) << 96)
        );

        collToken0 = panopticPool.collateralToken0();
        collToken1 = panopticPool.collateralToken1();
    }

    function getLiquidityForAmountAtRatio(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 token,
        uint256 amountToken
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        uint256 priceX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 2 ** 64);

        uint256 amount0 = token == 0
            ? amountToken
            : FullMath.mulDiv(amountToken, 2 ** 128, priceX128);
        uint256 amount1 = token == 1
            ? amountToken
            : FullMath.mulDiv(amountToken, priceX128, 2 ** 128);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            // position is already fully token0, so the amount of tokens to the left is the same as the value
            liquidity = LiquidityAmounts.getLiquidityForAmount0(
                sqrtRatioAX96,
                sqrtRatioBX96,
                amount0
            );
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            // first, find ratio x/y: token0/token1
            // use decomposed form to avoid overflows
            // s_A: lower sqrt ratio (X96)
            // s_B: upper sqrt ratio (X96)
            // s_C: current sqrt ratio (X96)
            // x: quantity token0
            // y: quantity token1
            // L: liquidity
            // r: x/y
            // y = L * (s_C - s_A) / 2^96
            // x = 2^96 * L * (s_B - s_C) / (s_C*s_B)
            // r = 2^192 * (s_B - s_C) / (s_C * s_B * (s_C - s_A))
            // = (2^192 * s_B - 2^192 * s_C) / (s_C * s_B * (s_C - s_A))
            // = 2^192 / (s_C * (s_C - s_A)) - 2^192 / (s_B * (s_C - s_A))

            // r * 2^96 (needed to preserve precision)
            uint256 rX96 = FullMath.mulDiv(
                2 ** 96,
                2 ** 192,
                (uint256(sqrtRatioX96) * (sqrtRatioX96 - sqrtRatioAX96))
            ) -
                FullMath.mulDiv(
                    2 ** 96,
                    2 ** 192,
                    (uint256(sqrtRatioBX96) * (sqrtRatioX96 - sqrtRatioAX96))
                );

            // then, multiply r by current price to find ratio y_right/y_left
            // p_C: current price (X128)
            // yL: amount of token1 to the left of the current price
            // yR: (equiv) amount of token1 to the right of the current price
            // x: amount of token0 to the right of the current price
            // r = x/yL
            // given amount yL, xR = yL * r, and yR = xR * p_C
            // so yR = yL * r * p_C
            // also, where rRL = yR/yL, yL * rRL = yR
            // yL * RL = yL * r * p_C, therefore, rRL = r * p_C
            uint256 rRLX96 = FullMath.mulDiv(rX96, priceX128, 2 ** 128);

            // finally, solve for x and y given the yR/yL, p_C, and the specified value in terms of token1
            // rRL: yR/yL
            // yS: specified amount of token1
            // yR + yL = yS
            // yR = rRL * yL
            // yS = rRL * yL + yL
            // yS = yL * (rRL + 1)
            // yL = yS / (rRL + 1)
            // yR = rRL * yS / (rRL + 1)
            uint256 yL = FullMath.mulDiv(amount1, 2 ** 96, rRLX96 + 2 ** 96);
            uint256 yR = FullMath.mulDiv(
                FullMath.mulDiv(amount1, rRLX96, 2 ** 96),
                2 ** 96,
                rRLX96 + 2 ** 96
            );
            uint256 x = FullMath.mulDiv(yR, 2 ** 128, priceX128);

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtRatioX96,
                sqrtRatioAX96,
                sqrtRatioBX96,
                x,
                yL // y(token1) is always to the left of the current price
            );
        } else {
            liquidity = LiquidityAmounts.getLiquidityForAmount1(
                sqrtRatioAX96,
                sqrtRatioBX96,
                amount1
            );
        }
    }

    function getContractsForAmountAtTick(
        int24 _tick,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 _token,
        uint256 _amountToken
    ) internal pure returns (uint256 contractAmount) {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(_tick);
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(_tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(_tickUpper);

        uint128 liquidity = getLiquidityForAmountAtRatio(
            sqrtRatioX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            _token,
            _amountToken
        );

        contractAmount = _token == 0
            ? LiquidityAmounts.getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity)
            : LiquidityAmounts.getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
    }

    function populatePositionData(int24 width, int24 strike, uint256 positionSizeSeed) internal {
        (int24 rangeDown, int24 rangeUp) = PanopticMath.getRangesFromStrike(width, poolTickSpacing);

        tickLower = int24(strike - rangeDown);
        tickLowers.push(tickLower);
        tickUpper = int24(strike + rangeUp);
        tickUppers.push(tickUpper);

        sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
        sqrtLowers.push(sqrtLower);
        sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);
        sqrtUppers.push(sqrtUpper);

        // 0.0001 -> 100 WETH
        positionSizeSeed = bound(positionSizeSeed, 10 ** 15, 10 ** 20);

        // calculate the amount of ETH contracts needed to create a position with above attributes and value in ETH
        positionSize = uint128(
            getContractsForAmountAtTick(currentTick, tickLower, tickUpper, isWETH, positionSizeSeed)
        );

        // `getContractsForAmountAtTick` calculates liquidity under the hood, but SFPM does this conversion
        // as well and using the original value could result in discrepancies due to rounding

        expectedLiq = isWETH == 0
            ? Math.getLiquidityForAmount0(tickLower, tickUpper, positionSize).liquidity()
            : Math.getLiquidityForAmount1(tickLower, tickUpper, positionSize).liquidity();
        expectedLiqs.push(expectedLiq);

        $amount0Moveds.push(
            sqrtUpper < currentSqrtPriceX96
                ? int256(0)
                : SqrtPriceMath.getAmount0Delta(
                    sqrtLower < currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtLower,
                    sqrtUpper,
                    int128(expectedLiq)
                )
        );

        $amount1Moveds.push(
            sqrtLower > currentSqrtPriceX96
                ? int256(0)
                : SqrtPriceMath.getAmount1Delta(
                    sqrtLower,
                    sqrtUpper > currentSqrtPriceX96 ? currentSqrtPriceX96 : sqrtUpper,
                    int128(expectedLiq)
                )
        );
    }

    function getContext(
        uint256 ts_,
        int24 _currentTick,
        int24 _width
    ) internal pure returns (int24 strikeOffset, int24 minTick, int24 maxTick) {
        int256 ts = int256(ts_);

        strikeOffset = int24(_width % 2 == 0 ? int256(0) : ts / 2);

        minTick = int24(((_currentTick - 4096 * 10) / ts) * ts);
        maxTick = int24(((_currentTick + 4096 * 10) / ts) * ts);
    }

    function getContextFull(
        uint256 ts_,
        int24 _currentTick,
        int24 _width
    ) internal pure returns (int24 strikeOffset, int24 minTick, int24 maxTick) {
        int256 ts = int256(ts_);

        strikeOffset = int24(_width % 2 == 0 ? int256(0) : ts / 2);

        minTick = int24(((_currentTick - 4096 * ts) / ts) * ts);
        maxTick = int24(((_currentTick + 4096 * ts) / ts) * ts);
    }

    function getOTMSW(
        uint256 _widthSeed,
        int256 _strikeSeed,
        uint256 ts_,
        int24 _currentTick,
        uint256 _tokenType
    ) internal view returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        width = ts == 1
            ? width = int24(int256(bound(_widthSeed, 1, 2048)))
            : int24(int256(bound(_widthSeed, 1, (2048 * 10) / uint256(ts))));
        int24 oneSidedRange = int24((width * ts) / 2);

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        (int24 strikeOffset, int24 minTick, int24 maxTick) = ts == 1
            ? getContextFull(ts_, _currentTick, width)
            : getContext(ts_, _currentTick, width);

        int24 lowerBound = _tokenType == 0
            ? int24(_currentTick + ts + oneSidedRange - strikeOffset)
            : int24(minTick + oneSidedRange - strikeOffset);
        int24 upperBound = _tokenType == 0
            ? int24(maxTick - oneSidedRange - strikeOffset)
            : int24(_currentTick - oneSidedRange - strikeOffset);

        if (ts == 1) {
            lowerBound = _tokenType == 0
                ? int24(_currentTick + ts + rangeDown - strikeOffset)
                : int24(minTick + rangeDown - strikeOffset);
            upperBound = _tokenType == 0
                ? int24(maxTick - rangeUp - strikeOffset)
                : int24(_currentTick - rangeUp - strikeOffset);
        }

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(int256(bound(_strikeSeed, lowerBound / ts, upperBound / ts)));

        strike = int24(strike * ts + strikeOffset);
    }


    function mint_option_OTM_short() public {
        uint256 widthSeed = 1;
        int256 strikeSeed = 15;
        uint256 positionSizeSeed = 500000;

        (int24 width, int24 strike) = getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(poolTickSpacing),
            currentTick,
            0
        );

        populatePositionData(width, strike, positionSizeSeed);

        uint256 preCallBalance = collToken1.balanceOf(msg.sender);
        TokenId tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            0,
            0,
            strike,
            width
        );

        TokenId[] memory posIdList = new TokenId[](1);
        uint256 preMintOptionsSFPMBalance = sfpm.balanceOf(
            address(panopticPool),
            TokenId.unwrap(tokenId)
        );
        (, uint256 previousInAmm, ) = collToken0.getPoolData();

        posIdList[0] = tokenId;

        hevm.prank(msg.sender);
        panopticPool.mintOptions(posIdList, positionSize, 0, 0, 0);

        // Check: The delta between the previous state and the current state must be equal to the size of the position
        assert(
            sfpm.balanceOf(address(panopticPool), TokenId.unwrap(tokenId)) -
                preMintOptionsSFPMBalance ==
                positionSize
        );

        uint256 amount0 = LiquidityAmounts.getAmount0ForLiquidity(
            sqrtLower,
            sqrtUpper,
            expectedLiq
        );

        {
            (, uint256 inAMM, ) = collToken0.getPoolData();
            // Check: The increase in the AMM for token 0 must be amount0
            assert(inAMM - previousInAmm == amount0);
        }

        {
            (, uint256 inAMM, ) = collToken1.getPoolData();
            // Check: There should be no token1 in the AMM
            assert(inAMM == 0);
        }
        {
            // TODO: all checks here should be modified for multiple positions
             assert(panopticPool.numberOfPositions(msg.sender) == 1);

            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = panopticPool
                .optionPositionBalance(msg.sender, tokenId);

            assert(balance == positionSize);
            assert(poolUtilization0 == (amount0 * 10000) / collToken0.totalSupply());
            assert(poolUtilization1 == 0);
        }

        {
            (, LeftRightSigned shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId,
                uint128(positionSize)
            );

            /*assertApproxEqAbs(
                collToken0.balanceOf(msg.sender),
                uint256(type(uint104).max) - uint128((shortAmounts.rightSlot() * 10) / 10000),
                uint256(int256(shortAmounts.rightSlot()) / 1_000_000 + 10),
                "alice balance 0"
            );*/
            assert(collToken1.balanceOf(msg.sender) == preCallBalance);
        }
    }

    function mint_option_OTM_short_put() public {
        uint256 widthSeed = 1;
        int256 strikeSeed = 15;
        uint256 positionSizeSeed = 500000;

        (int24 width, int24 strike) = getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(poolTickSpacing),
            currentTick,
            1
        );

        populatePositionData(width, strike, positionSizeSeed);

        uint256 preCallBalance = collToken0.balanceOf(msg.sender);

        TokenId tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
            0,
            1,
            isWETH,
            0,
            1,
            0,
            strike,
            width
        );

        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = tokenId;

        hevm.prank(msg.sender);
        panopticPool.mintOptions(posIdList, positionSize, 0, 0, 0);

        assert(sfpm.balanceOf(address(panopticPool), TokenId.unwrap(tokenId)) == positionSize);

        uint256 amount1 = LiquidityAmounts.getAmount1ForLiquidity(
            sqrtLower,
            sqrtUpper,
            expectedLiq
        );

        {
            (, uint256 inAMM, ) = collToken1.getPoolData();

            // there are some inevitable precision errors that occur when
            // converting between contract sizes and liquidity - ~.01 basis points error is acceptable
            /*assertApproxEqAbs(inAMM, amount1, amount1 / 1_000_000);*/
        }

        {
            (, uint256 inAMM, ) = collToken0.getPoolData();
            assert(inAMM == 0);
        }

        {

            assert(panopticPool.numberOfPositions(msg.sender) == 1);

            (uint128 balance, uint64 poolUtilization0, uint64 poolUtilization1) = panopticPool.optionPositionBalance(msg.sender, tokenId);

            assert(balance == positionSize);
            assert(poolUtilization1 == (amount1 * 10000) / collToken1.totalSupply());
            assert(poolUtilization0 == 0);
        }

        {
            (, LeftRightSigned shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId,
                positionSize
            );

            /*assertApproxEqAbs(
                collToken1.balanceOf(Alice),
                uint256(type(uint104).max) - uint128((shortAmounts.leftSlot() * 10) / 10000),
                uint256(int256(shortAmounts.leftSlot()) / 1_000_000 + 10)
            );*/

            assert(collToken0.balanceOf(msg.sender) == uint256(preCallBalance));
        }
    }

    function twoWaySwap(uint256 swapSize, uint256 numberOfSwaps, uint256 recipient) public {

        recipient = bound(recipient, 0, 4);  // Index to the actors array 
        swapSize = bound(swapSize, 10 ** 18, 10 ** 20);
        numberOfSwaps = bound(numberOfSwaps, 1, 15);

        address token0 = collToken0.asset();
        address token1 = collToken1.asset();

        for (uint256 i = 0; i < numberOfSwaps; ++i) {
            hevm.prank(msg.sender);
            router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams(
                    isWETH == 0 ? token0 : token1,
                    isWETH == 1 ? token0 : token1,
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
                    isWETH == 1 ? token0 : token1,
                    isWETH == 0 ? token0 : token1,
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

        // convert signed int to assets
    function convertToAssets(CollateralTracker ct, int256 amount) internal view returns (int256) {
        return (amount > 0 ? int8(1) : -1) * int256(ct.convertToAssets(uint256(Math.abs(amount))));
    }

    function getValidSW(
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 ts_,
        int24 currentTick
    ) public view returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        width = ts == 1
            ? width = int24(int256(bound(widthSeed, 1, 2048)))
            : int24(int256(bound(widthSeed, 1, 2048)));

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        (int24 strikeOffset, int24 minTick, int24 maxTick) = ts == 1
            ? getContextFull(ts_, currentTick, width)
            : getContext(ts_, currentTick, width);

        int24 lowerBound = int24(minTick + rangeDown - strikeOffset);
        int24 upperBound = int24(maxTick - rangeUp - strikeOffset);

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(bound(strikeSeed, lowerBound / ts, upperBound / ts));

        strike = int24(strike * ts + strikeOffset);
    }

    TokenId[] $posIdList;
    TokenId[][1000] $posIdLists;
    int128 $expectedPremia0;
    int128 $expectedPremia1;
    int128[] $expectedPremias0;
    int128[] $expectedPremias1;
    LeftRightUnsigned $tokenData0;
    LeftRightUnsigned $tokenData1;
    int256 $bonus0;
    int256 $bonus1;
    int256 $bonusCombined0;
    uint256 $delegated0;
    uint256 $delegated1;
    uint256 $totalSupply0;
    uint256 $totalSupply1;
    uint256 $totalAssets0;
    uint256 $totalAssets1;
    int256 $burnDelta0;
    int256 $burnDelta1;
    int256 $burnDelta0Combined;
    mapping(bytes32 chunk => LeftRightUnsigned settledTokens) $settledTokens;
    uint256[] settledTokens0;
    int256 longPremium0;
    LeftRightSigned $premia;
    LeftRightSigned $netExchanged;
    int256 $shareDelta0;
    int256 $shareDelta1;
    int24 TWAPtick;
    int256 $combinedBalance0;
    int256 $combinedBalance0Premium;
    int256 $combinedBalance0NoPremium;
    int256 $balance0CombinedPostBurn;
    int256 $protocolLoss0BaseExpected;
    int256 $protocolLoss0Actual;
    uint256 $accValueBefore0;
    uint256[2][] $positionBalanceArray;

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

        if(ct.asset() == address(USDC)) {
            deal_USDC(address(ct), uint256(int256(IERC20(ct.asset()).balanceOf(address(ct))) + assetDelta));
        } else {
            deal_WETH(address(ct), uint256(int256(IERC20(ct.asset()).balanceOf(address(ct))) + assetDelta));
        }

        deal_Generic(address(ct), 1, owner, newShares); // deal(address(ct), owner, newShares, true);
    }


    function mint_and_liquidate (
        uint256 seller, // index to actors array
        uint256 buyer,
        uint256 liquidator,
        uint256 numLegs,
        uint256[4] memory isLongs,
        uint256[4] memory tokenTypes,
        uint256[4] memory widthSeeds,
        int256[4] memory strikeSeeds,
        uint256 positionSizeSeed,
        uint256 collateralBalanceSeed,
        uint256 collateralRatioSeed
    ) public {

        seller = bound(seller, 0, 4);
        buyer = bound(buyer, 0, 4);
        liquidator = bound(liquidator, 0, 4);

        // Make sure they're different
        if (seller == buyer) { buyer = bound(buyer + 1, 0, 4); }
        if (liquidator == seller) { liquidator = bound(liquidator + 1, 0, 4); }
        if (liquidator == buyer) { liquidator = bound(liquidator + 2, 0, 4); }

        numLegs = bound(numLegs, 1, 4);

        int24[4] memory widths;
        int24[4] memory strikes;

        for (uint256 i = 0; i < numLegs; ++i) {
            tokenTypes[i] = bound(tokenTypes[i], 0, 1);
            isLongs[i] = bound(isLongs[i], 0, 1);
            // distancing tickSpacing ensures this position stays OTM throughout this test case. ITM is tested elsewhere.
            (widths[i], strikes[i]) = getValidSW(widthSeeds[i], strikeSeeds[i], uint24(poolTickSpacing), currentTick);

            // make sure there are no conflicts
            for (uint256 j = 0; j < i; ++j) {
                require( widths[i] != widths[j] || strikes[i] != strikes[j] || tokenTypes[i] != tokenTypes[j] );
            }
        }
        if (numLegs == 1) populatePositionData(widths[0], strikes[0], positionSizeSeed);
        if (numLegs == 2) populatePositionData([widths[0], widths[1]], [strikes[0], strikes[1]], positionSizeSeed);
        if (numLegs == 3) populatePositionData([widths[0], widths[1], widths[2]], [strikes[0], strikes[1], strikes[2]], positionSizeSeed);
        if (numLegs == 4) populatePositionData(widths, strikes, positionSizeSeed);

        // this is a long option; so need to sell before it can be bought (let's say 2x position size for now)
        for (uint256 i = 0; i < numLegs; ++i) {
            $posIdLists[0].push( TokenId.wrap(0).addPoolId(poolId).addLeg( 0, 1, isWETH, 0, tokenTypes[i], 0, strikes[i], widths[i] ) );
            hevm.prank(actors[seller]);
            panopticPool.mintOptions($posIdLists[0], positionSize * 2, 0, 0, 0);
        }

        // now we can mint the options being liquidated
        for (uint256 i = 0; i < numLegs; ++i) {
            $posIdLists[1].push( TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, isWETH, isLongs[i], tokenTypes[i], 0, strikes[i], widths[i] ));
            hevm.prank(actors[buyer]);
            panopticPool.mintOptions($posIdLists[1], positionSize, type(uint64).max, 0, 0);
        }
        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();

        require(Math.abs(int256(currentTick) - panopticPool.getUniV3TWAP_()) <= 513);

        (, uint256 totalCollateralRequired0) = panopticHelper.checkCollateral(panopticPool, actors[buyer], panopticPool.getUniV3TWAP_(), 0, $posIdLists[1]);

        uint256 totalCollateralB0 = bound(collateralBalanceSeed, 1, (totalCollateralRequired0 * 9_999) / 10_000);

        editCollateral(collToken0, actors[buyer], collToken0.convertToShares((totalCollateralB0 * bound(collateralRatioSeed, 0, 10_000)) / 10_000));
        editCollateral(collToken1, actors[buyer], collToken1.convertToShares(PanopticMath.convert0to1(
            (totalCollateralB0 * (10_000 - bound(collateralRatioSeed, 0, 10_000))) / 10_000, Math.getSqrtRatioAtTick(panopticPool.getUniV3TWAP_())))
        );

        TWAPtick = panopticPool.getUniV3TWAP_();
        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();

        ($expectedPremia0, $expectedPremia1, $positionBalanceArray) = panopticPool.calculateAccumulatedFeesBatch(actors[buyer], false, $posIdLists[1]);

        $tokenData0 = collToken0.getAccountMarginDetails(actors[buyer], TWAPtick, $positionBalanceArray, $expectedPremia0);
        $tokenData1 = collToken1.getAccountMarginDetails(actors[buyer], TWAPtick, $positionBalanceArray, $expectedPremia1);

        // initialize collateral share deltas - we measure the flow of value out of buyers account to find the bonus
        $shareDelta0 = int256(collToken0.balanceOf(actors[buyer]));
        $shareDelta1 = int256(collToken1.balanceOf(actors[buyer]));

        // delegate liquidators entire balance so we don't have the protocol loss in his unutilized collateral as a source of error
        deal_Generic(address(collToken0), 1, actors[liquidator], collToken0.convertToShares(type(uint96).max));
        deal_Generic(address(collToken1), 1, actors[liquidator], collToken1.convertToShares(type(uint96).max));

        // simulate burning all options to compare against the liquidation
        uint256 snapshot = vm.snapshot();

        hevm.prank(address(panopticPool));
        collToken0.delegate(actors[liquidator], actors[buyer], type(uint96).max);

        hevm.prank(address(panopticPool));
        collToken1.delegate(actors[liquidator], actors[buyer], type(uint96).max);

        int256[2] memory shareDeltasLiquidatee = [int256(collToken0.balanceOf(actors[buyer])), int256(collToken1.balanceOf(actors[buyer]))];

        vm.startPrank(actors[buyer]);

        int24 currentTickFinal;
        {
            (LeftRightSigned[4][] memory premiasByLeg, LeftRightSigned netExchanged) = panopticPool.burnAllOptionsFrom($posIdLists[1], 0, 0);

            shareDeltasLiquidatee = [int256(collToken0.balanceOf(actors[buyer])) - shareDeltasLiquidatee[0], int256(collToken1.balanceOf(actors[buyer])) - shareDeltasLiquidatee[1]];

            (, currentTickFinal, , , , , ) = pool.slot0();

            uint256[2][4][] memory settledTokensTemp = new uint256[2][4][]($posIdLists[1].length);

            for (uint256 i = 0; i < $posIdLists[1].length; ++i) {
                for (uint256 j = 0; j < $posIdLists[1][i].countLegs(); ++j) {
                    bytes32 chunk = keccak256(abi.encodePacked($posIdLists[1][i].strike(j), $posIdLists[1][i].width(j), $posIdLists[1][i].tokenType(j)));
                    settledTokensTemp[i][j] = [uint256(chunk), LeftRightUnsigned.unwrap(panopticPool.settledTokens(chunk))];
                }
            }

            uint256 totalSupply0 = collToken0.totalSupply();
            uint256 totalSupply1 = collToken1.totalSupply();
            uint256 totalAssets0 = collToken0.totalAssets();
            uint256 totalAssets1 = collToken1.totalAssets();

            int256 burnDelta0C = convertToAssets(collToken0, shareDeltasLiquidatee[0]) +
                PanopticMath.convert1to0(convertToAssets(collToken1, shareDeltasLiquidatee[1]), TickMath.getSqrtRatioAtTick(currentTickFinal));
            int256 burnDelta0 = convertToAssets(collToken0, shareDeltasLiquidatee[0]);
            int256 burnDelta1 = convertToAssets(collToken1, shareDeltasLiquidatee[1]);

            vm.revertTo(snapshot);

            $totalSupply0 = totalSupply0;
            $totalSupply1 = totalSupply1;
            $totalAssets0 = totalAssets0;
            $totalAssets1 = totalAssets1;

            $burnDelta0Combined = burnDelta0C;
            $burnDelta0 = burnDelta0;
            $burnDelta1 = burnDelta1;

            $netExchanged = netExchanged;

            for (uint256 i = 0; i < $posIdLists[1].length; ++i) {
                for (uint256 j = 0; j < $posIdLists[1][i].countLegs(); ++j) {
                    longPremium0 += premiasByLeg[i][j].rightSlot() < 0 ? -premiasByLeg[i][j].rightSlot() : int128(0);
                    longPremium0 += PanopticMath.convert1to0(
                        premiasByLeg[i][j].leftSlot() < 0 ? -premiasByLeg[i][j].leftSlot() : int128(0),
                        TickMath.getSqrtRatioAtTick(currentTickFinal)
                    );
                    $settledTokens[bytes32(settledTokensTemp[i][j][0])] = LeftRightUnsigned.wrap(settledTokensTemp[i][j][1]);
                }
            }
        }

        

        $accValueBefore0 =
            collToken0.convertToAssets(collToken0.balanceOf(actors[liquidator])) +
            PanopticMath.convert1to0(collToken1.convertToAssets(collToken1.balanceOf(actors[liquidator])), TickMath.getSqrtRatioAtTick(currentTickFinal));

        {
            (int128 premium0, int128 premium1, ) = panopticPool.calculateAccumulatedFeesBatch(actors[buyer], false, $posIdLists[1]);
            $premia = LeftRightSigned.wrap(0).toRightSlot(premium0).toLeftSlot(premium1);
        }

        ($bonus0, $bonus1, ) = PanopticMath.getLiquidationBonus($tokenData0, $tokenData1, Math.getSqrtRatioAtTick(TWAPtick), Math.getSqrtRatioAtTick(currentTickFinal),
            $netExchanged, $premia);

        $delegated0 = uint256(int256(collToken0.convertToShares(uint256(int256(uint256(type(uint96).max)) + $bonus0))));
        $delegated1 = uint256(int256(collToken1.convertToShares(uint256(int256(uint256(type(uint96).max)) + $bonus1))));

        LeftRightUnsigned delegations = LeftRightUnsigned.wrap(type(uint96).max).toLeftSlot(type(uint96).max);
        hevm.prank(actors[liquidator]);
        panopticPool.liquidate(new TokenId[](0), actors[buyer], delegations, $posIdLists[1]);

        // take the difference between the share deltas after burn and after mint - that should be the bonus
        $shareDelta0 = shareDeltasLiquidatee[0] - (int256(collToken0.balanceOf(actors[buyer])) - $shareDelta0);
        $shareDelta1 = shareDeltasLiquidatee[1] - (int256(collToken1.balanceOf(actors[buyer])) - $shareDelta1);

        // bonus can be very small on the threshold leading to a loss (of 1-2 tokens) due to precision, which is fine
        assert(
            collToken0.convertToAssets(collToken0.balanceOf(actors[liquidator])) +
                PanopticMath.convert1to0(collToken1.convertToAssets(collToken1.balanceOf(actors[liquidator])), TickMath.getSqrtRatioAtTick(currentTickFinal)) + 1
                >= $accValueBefore0,
            "liquidator lost money"
        );

        // get total balance for Alice before liquidation
        $combinedBalance0NoPremium = int256(
            (int256(uint256($tokenData0.rightSlot())) - Math.max($premia.rightSlot(), 0)) +
                PanopticMath.convert1to0(
                    int256(uint256($tokenData1.rightSlot())) - Math.max($premia.leftSlot(), 0),
                    TickMath.getSqrtRatioAtTick(TWAPtick)
                )
        );
        $combinedBalance0Premium = int256(
            ($tokenData0.rightSlot()) +
                PanopticMath.convert1to0(
                    $tokenData1.rightSlot(),
                    TickMath.getSqrtRatioAtTick(TWAPtick)
                )
        );
        $bonusCombined0 = Math.min(
            $combinedBalance0Premium / 2,
            int256(
                $tokenData0.leftSlot() +
                    PanopticMath.convert1to0(
                        $tokenData1.leftSlot(),
                        TickMath.getSqrtRatioAtTick(TWAPtick)
                    )
            ) - $combinedBalance0Premium
        );

        // make sure value outlay for Alice matches the bonus structure
        // if Alice is completely insolvent the deltas will be wrong because
        // some of the bonus will come from PLPs
        // in that case we just assert that the delta is less than whatever the bonus was supposed to be
        // which ensures Alice wasn't overcharged

        // The protocol loss is the value of shares added to the supply multiplied by the portion of NON-DELEGATED collateral
        // (losses in collateral that was returned to the liquidator post-delegation are compensated, so they are not included)
        $protocolLoss0Actual = int256(
            (collToken0.convertToAssets(
                (collToken0.totalSupply() - $totalSupply0) -
                    ((collToken0.totalAssets() - $totalAssets0) * $totalSupply0) /
                    $totalAssets0
            ) * ($totalSupply0 - $delegated0)) /
                ($totalSupply0 - (collToken0.totalSupply() - $totalSupply0)) +
                PanopticMath.convert1to0(
                    (collToken1.convertToAssets(
                        (collToken1.totalSupply() - $totalSupply1) -
                            ((collToken1.totalAssets() - $totalAssets1) * $totalSupply1) /
                            $totalAssets1
                    ) * ($totalSupply1 - $delegated1)) /
                        ($totalSupply1 - (collToken1.totalSupply() - $totalSupply1)),
                    TickMath.getSqrtRatioAtTick(currentTickFinal)
                )
        );

        // every time an option is burnt, the owner can lose up to 1 share (worth much less than 1 token) due to rounding
        // (in this test n = number of options = numLegs)
        // this happens on *both* liquidations and burns, but during liquidations 1-n shares can be clawed back from PLPs
        // this is because the assets refunded to the liquidator are only rounded down once,
        // so they could correspond to a higher amount of overall shares than the liquidatee had
        if (
            (collToken0.totalSupply() - $totalSupply0 <= numLegs) &&
            (collToken1.totalSupply() - $totalSupply1 <= numLegs)
        ) {
           /* assertApproxEqAbs(
                convertToAssets(collToken0, $shareDelta0) +
                    PanopticMath.convert1to0(
                        convertToAssets(collToken1, $shareDelta1),
                        TickMath.getSqrtRatioAtTick(currentTickFinal)
                    ),
                Math.min(
                    $combinedBalance0Premium / 2,
                    int256(
                        $tokenData0.leftSlot() +
                            PanopticMath.convert1to0(
                                $tokenData1.leftSlot(),
                                TickMath.getSqrtRatioAtTick(TWAPtick)
                            )
                    ) - $combinedBalance0Premium
                ),
                10,
                "liquidatee was debited incorrect bonus value (funds leftover)"
            );*/

            for (uint256 i = 0; i < $posIdLists[1].length; ++i) {
                for (uint256 j = 0; j < $posIdLists[1][i].countLegs(); ++j) {
                    bytes32 chunk = keccak256(abi.encodePacked($posIdLists[1][i].strike(j), $posIdLists[1][i].width(j), $posIdLists[1][i].tokenType(j)));
                    assert(
                        LeftRightUnsigned.unwrap(panopticPool.settledTokens(chunk)) ==
                        LeftRightUnsigned.unwrap($settledTokens[chunk]),
                        "settled tokens were modified when a haircut was not needed"
                    );
                }
            }
        } else {
            assert(
                convertToAssets(collToken0, $shareDelta0) + PanopticMath.convert1to0(convertToAssets(collToken1, $shareDelta1), TickMath.getSqrtRatioAtTick(currentTickFinal)) <=
                Math.min($combinedBalance0Premium / 2, int256($tokenData0.leftSlot() + PanopticMath.convert1to0($tokenData1.leftSlot(), TickMath.getSqrtRatioAtTick(TWAPtick))) - $combinedBalance0Premium ),
                "liquidatee was debited incorrectly high bonus value (no funds leftover)"
            );
        }

        settledTokens0.push(0);
        settledTokens0.push(0);

        for (uint256 i = 0; i < $posIdLists[1].length; ++i) {
            for (uint256 j = 0; j < $posIdLists[1][i].countLegs(); ++j) {
                bytes32 chunk = keccak256(
                    abi.encodePacked(
                        $posIdLists[1][i].strike(j),
                        $posIdLists[1][i].width(j),
                        $posIdLists[1][i].tokenType(j)
                    )
                );
                settledTokens0[0] += $settledTokens[chunk].rightSlot();
                settledTokens0[1] += panopticPool.settledTokens(chunk).rightSlot();
                settledTokens0[0] += PanopticMath.convert1to0(
                    $settledTokens[chunk].leftSlot(),
                    TickMath.getSqrtRatioAtTick(currentTickFinal)
                );
                settledTokens0[1] += PanopticMath.convert1to0(
                    panopticPool.settledTokens(chunk).leftSlot(),
                    TickMath.getSqrtRatioAtTick(currentTickFinal)
                );
            }
        }

        int256 balanceCombined0CT = int256($tokenData0.rightSlot() + PanopticMath.convert1to0($tokenData1.rightSlot(), TickMath.getSqrtRatioAtTick(TWAPtick)));

        $balance0CombinedPostBurn =
            int256(uint256($tokenData0.rightSlot())) - Math.max($premia.rightSlot(), 0) + $burnDelta0 + 
            int256(PanopticMath.convert1to0( int256(uint256($tokenData1.rightSlot())) - Math.max($premia.leftSlot(), 0) + $burnDelta1, TickMath.getSqrtRatioAtTick(currentTickFinal)));

        $protocolLoss0BaseExpected = Math.max(-($balance0CombinedPostBurn - Math.min(balanceCombined0CT / 2, int256($tokenData0.leftSlot() + 
            PanopticMath.convert1to0($tokenData1.leftSlot(), TickMath.getSqrtRatioAtTick(TWAPtick))) - balanceCombined0CT)), 0);

        /*
        assertApproxEqAbs(
            int256(settledTokens0[0]) - int256(settledTokens0[1]),
            Math.min(longPremium0, $protocolLoss0BaseExpected),
            10,
            "incorrect amount of premium was haircut"
        );

        assertApproxEqAbs(
            $protocolLoss0Actual,
            $protocolLoss0BaseExpected - Math.min(longPremium0, $protocolLoss0BaseExpected),
            10,
            "not all premium was haircut during protocol loss"
        );

        assertApproxEqAbs(
            int256(
                collToken0.convertToAssets(collToken0.balanceOf(actors[liquidator])) +
                PanopticMath.convert1to0( collToken1.convertToAssets(collToken1.balanceOf(actors[liquidator])), TickMath.getSqrtRatioAtTick(currentTickFinal) )
            ) - int256($accValueBefore0),
            $bonusCombined0,
            10,
            "liquidator did not receive correct bonus"
        );*/
    }


}
