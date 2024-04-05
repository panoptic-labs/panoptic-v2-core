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

    constructor() {
        /*tokens = new SetupTokens();
        uniswap = new SetupUniswap(tokens.token0(), tokens.token1());*/

        // See if mock or new deploy
        univ3factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

        sfpm = new SemiFungiblePositionManager(univ3factory);

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

        emit LogUint256("here", 0);

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();
        feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
        feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();

        emit LogUint256("here", 0);

        sfpm.initializeAMMPool(pool.token0(), pool.token1(), poolFee);

        emit LogUint256("here", 0);

        panopticPool = panopticFactory.deployNewPool(
            pool.token0(),
            pool.token1(),
            poolFee,
            bytes32(uint256(uint160(address(this))) << 96)
        );

        emit LogUint256("here", 0);

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

        // 0.0001 -> 10_000 WETH
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
        emit LogUint256(
            "pre balance",
            sfpm.balanceOf(address(panopticPool), TokenId.unwrap(tokenId))
        );
        posIdList[0] = tokenId;

        hevm.prank(msg.sender);
        panopticPool.mintOptions(posIdList, positionSize, 0, 0, 0);

        emit LogUint256(
            "after mint options spfm",
            sfpm.balanceOf(address(panopticPool), TokenId.unwrap(tokenId))
        );
        emit LogUint256("position size", positionSize);
        assert(sfpm.balanceOf(address(panopticPool), TokenId.unwrap(tokenId)) == positionSize);

        uint256 amount0 = LiquidityAmounts.getAmount0ForLiquidity(
            sqrtLower,
            sqrtUpper,
            expectedLiq
        );

        {
            (, uint256 inAMM, ) = collToken0.getPoolData();
            assert(abs(int256(inAMM) - int256(amount0)) < 10);
        }

        {
            (, uint256 inAMM, ) = collToken1.getPoolData();
            assert(inAMM == 0);
        }
        {
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
}
