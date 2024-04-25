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
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v3-core/libraries/SqrtPriceMath.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
import {CallbackLib} from "@libraries/CallbackLib.sol";
import {Math} from "@libraries/Math.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";

contract SwapperC {
    event LogUint256(string, uint256);

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        // Decode the swap callback data, checks that the UniswapV3Pool has the correct address.
        CallbackLib.CallbackData memory decoded = abi.decode(data, (CallbackLib.CallbackData));

        // Extract the address of the token to be sent (amount0 -> token0, amount1 -> token1)
        address token = amount0Delta > 0
            ? address(decoded.poolFeatures.token0)
            : address(decoded.poolFeatures.token1);

        // Transform the amount to pay to uint256 (take positive one from amount0 and amount1)
        // the pool will always pass one delta with a positive sign and one with a negative sign or zero,
        // so this logic always picks the correct delta to pay
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);

        // Pay the required token from the payer to the caller of this contract
        SafeTransferLib.safeTransferFrom(token, decoded.payer, msg.sender, amountToPay);
    }

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        // Decode the mint callback data
        CallbackLib.CallbackData memory decoded = abi.decode(data, (CallbackLib.CallbackData));

        // Sends the amount0Owed and amount1Owed quantities provided
        if (amount0Owed > 0)
            SafeTransferLib.safeTransferFrom(
                decoded.poolFeatures.token0,
                decoded.payer,
                msg.sender,
                amount0Owed
            );
        if (amount1Owed > 0)
            SafeTransferLib.safeTransferFrom(
                decoded.poolFeatures.token1,
                decoded.payer,
                msg.sender,
                amount1Owed
            );
    }

    function mint(IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) public {
        pool.mint(
            address(this),
            tickLower,
            tickUpper,
            liquidity,
            abi.encode(
                CallbackLib.CallbackData({
                    poolFeatures: CallbackLib.PoolFeatures({
                        token0: pool.token0(),
                        token1: pool.token1(),
                        fee: pool.fee()
                    }),
                    payer: msg.sender
                })
            )
        );
    }

    function burn(IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) public {
        pool.burn(tickLower, tickUpper, liquidity);
    }

    function swapTo(IUniswapV3Pool pool, uint160 sqrtPriceX96) public {
        (uint160 sqrtPriceX96Before, , , , , , ) = pool.slot0();

        if (sqrtPriceX96Before == sqrtPriceX96) return;

        emit LogUint256("price before", sqrtPriceX96Before);
        emit LogUint256("price target", sqrtPriceX96);

        pool.swap(
            msg.sender,
            sqrtPriceX96Before > sqrtPriceX96 ? true : false,
            sqrtPriceX96Before > sqrtPriceX96
                ? int256(IERC20(pool.token0()).balanceOf(msg.sender))
                : int256(IERC20(pool.token1()).balanceOf(msg.sender)),
            sqrtPriceX96,
            abi.encode(
                CallbackLib.CallbackData({
                    poolFeatures: CallbackLib.PoolFeatures({
                        token0: pool.token0(),
                        token1: pool.token1(),
                        fee: pool.fee()
                    }),
                    payer: msg.sender
                })
            )
        );
    }
}

contract FuzzDeployments is FuzzHelpers {
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

    uint128 positionSize;
    uint128 expectedLiq;
    uint128[] expectedLiqs;

    CollateralTracker collToken0;
    CollateralTracker collToken1;

    address[] actors;

    SwapperC swapperc;

    TokenId[] currentPositionsIds;
    address[] currentPositionsMinters;
    mapping(address => TokenId[]) userPositions;
    mapping(address => int256) userLiquidityPerPosition;

    uint256 constant MAX_DEPOSIT = 100 ether;

    constructor() {
        // Actors
        actors = new address[](6);
        actors[0] = address(0xa11ce);
        actors[1] = address(0xb0b);
        actors[2] = address(0xcafe);
        actors[3] = address(0xda210);
        actors[4] = address(0xedda);
        actors[5] = address(0xfaded);

        for (uint i = 0; i < 6; i++) {
            userPositions[actors[i]] = new TokenId[](0);
        }

        univ3factory = IUniswapV3Factory(deployer.factory());
        emit LogAddress("UniV3 Factory", address(univ3factory));

        sfpm = new SemiFungiblePositionManager(univ3factory);
        emit LogAddress("Panoptic SFPM", address(sfpm));

        panopticHelper = new PanopticHelper(sfpm);
        emit LogAddress("Panoptic Helper", address(panopticHelper));

        // Import the Panoptic Pool reference (for cloning)
        poolReference = address(new PanopticPool(sfpm));
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

        // Actor 5 is the pool manipulator
        deal_USDC(actors[5], 1000000000 ether, true);
        deal_WETH(actors[5], 1000000 ether);
        hevm.prank(actors[5]);
        IERC20(USDC).approve(address(pool), type(uint256).max);
        hevm.prank(actors[5]);
        IERC20(WETH).approve(address(pool), type(uint256).max);
        hevm.prank(actors[5]);
        IERC20(USDC).approve(address(swapperc), type(uint256).max);
        hevm.prank(actors[5]);
        IERC20(WETH).approve(address(swapperc), type(uint256).max);
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

        hevm.prank(address(collToken0));
        IERC20(collToken0.asset()).approve(address(pool), type(uint256).max);
        hevm.prank(address(collToken0));
        IERC20(collToken1.asset()).approve(address(pool), type(uint256).max);

        hevm.prank(address(collToken1));
        IERC20(collToken0.asset()).approve(address(pool), type(uint256).max);
        hevm.prank(address(collToken1));
        IERC20(collToken1.asset()).approve(address(pool), type(uint256).max);
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

    function getITMSW(
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 ts_,
        int24 currentTick,
        uint256 tokenType
    ) internal view returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        width = ts == 1
            ? width = int24(int256(bound(widthSeed, 1, 2048)))
            : int24(int256(bound(widthSeed, 1, (2048 * 10) / uint256(ts))));
        int24 oneSidedRange = int24((width * ts) / 2);

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        (int24 strikeOffset, int24 minTick, int24 maxTick) = ts == 1
            ? getContextFull(ts_, currentTick, width)
            : getContext(ts_, currentTick, width);

        int24 lowerBound = tokenType == 0
            ? int24(minTick + oneSidedRange - strikeOffset)
            : int24(currentTick + oneSidedRange - strikeOffset);
        int24 upperBound = tokenType == 0
            ? int24(currentTick + ts - oneSidedRange - strikeOffset)
            : int24(maxTick - oneSidedRange - strikeOffset);

        if (ts == 1) {
            lowerBound = tokenType == 0
                ? int24(minTick + rangeDown - strikeOffset)
                : int24(currentTick + rangeDown - strikeOffset);
            upperBound = tokenType == 0
                ? int24(currentTick + ts - rangeUp - strikeOffset)
                : int24(maxTick - rangeUp - strikeOffset);
        }

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(bound(strikeSeed, lowerBound / ts, upperBound / ts));

        strike = int24(strike * ts + strikeOffset);
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

    function getValidSW(
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 ts_,
        int24 currentTick
    ) internal view returns (int24 width, int24 strike) {
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

    ////////////////////////////////////////////////////

    function log_tokenid_leg(TokenId t, uint256 leg) internal {
        emit LogString("TokenId");
        emit LogUint256("  Asset", t.asset(leg));
        emit LogUint256("  Option ratio", t.optionRatio(leg));
        emit LogUint256("  Is long", t.isLong(leg));
        emit LogUint256("  Token type", t.tokenType(leg));
        emit LogUint256("  Risk partner", t.riskPartner(leg));
        emit LogInt256("  Strike tick", t.strike(leg));
        emit LogInt256("  Width", t.width(leg));
    }

    function log_account_collaterals(address account) internal {
        emit LogAddress("Collaterals for address", account);
        emit LogUint256("  Token0", collToken0.balanceOf(account));
        emit LogUint256("  Token1", collToken1.balanceOf(account));
        emit LogUint256(
            "  Token0 (assets)",
            collToken0.convertToAssets(collToken0.balanceOf(account))
        );
        emit LogUint256(
            "  Token1 (assets)",
            collToken1.convertToAssets(collToken1.balanceOf(account))
        );
    }

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

    function _generate_single_leg_tokenid(
        bool asset_in,
        bool call_put_in,
        bool long_short_in,
        bool otm_itm_in,
        uint24 width_in,
        int256 strike_in
    ) internal returns (TokenId out) {
        out = TokenId.wrap(poolId);

        // Rest of the parameters come from the function parameters
        // For now, fixing them one at a time
        uint256 asset = 0; //asset_in == true ? 1 : 0;
        uint256 call_put = 0; // call_put_in == true ? 1 : 0;
        uint256 long_short = long_short_in == true ? 1 : 0; // 0 for long, 1 for short

        int24 width;
        int24 strike;

        // Lets just generate OTM for now
        (width, strike) = getOTMSW(width_in, strike_in, uint24(poolTickSpacing), currentTick, 0);

        out = out.addLeg(0, 1, asset, long_short, call_put, 0, strike, width);
        log_tokenid_leg(out, 0);
    }

    function mint_option(
        uint256 seller,
        bool asset,
        bool call_put,
        bool long_short,
        bool otm_itm,
        uint24 width,
        int256 strike,
        uint256 posSize
    ) public {
        seller = bound(seller, 0, 4);
        if (actors[seller] == msg.sender) {
            seller = bound(seller + 1, 0, 4);
        }

        uint256 userCollateral0 = collToken0.convertToAssets(collToken0.balanceOf(msg.sender));
        emit LogUint256("User collateral 0", userCollateral0);

        require(userPositions[msg.sender].length == 0, "Too many positions for user");
        if (!long_short) {
            require(userPositions[actors[seller]].length == 0, "Too many positions for seller");
        }

        (, currentTick, , , , , ) = pool.slot0();

        posSize = bound(posSize, userCollateral0 / 2, (3 * userCollateral0) / 4);
        require(posSize > 0);

        int256 balanceBefore;

        if (long_short) {
            TokenId lastPosId = _generate_single_leg_tokenid(
                asset,
                call_put,
                false,
                otm_itm,
                width,
                strike
            );
            userPositions[msg.sender].push(lastPosId);
            TokenId[] memory posIdList = userPositions[msg.sender];

            balanceBefore = int256(_get_assets_in_token0(msg.sender, currentTick));

            hevm.prank(msg.sender);
            panopticPool.mintOptions(posIdList, uint128(posSize), 0, 0, 0);

            userLiquidityPerPosition[msg.sender] =
                int256(_get_assets_in_token0(msg.sender, currentTick)) -
                balanceBefore;

            emit LogString("Minted a new option");
            emit LogUint256("Position size", posSize);
            emit LogAddress("Minter", msg.sender);
        } else {
            TokenId lastPosId = _generate_single_leg_tokenid(
                asset,
                call_put,
                false,
                otm_itm,
                width,
                strike
            );
            userPositions[actors[seller]].push(lastPosId);
            TokenId[] memory posIdList = userPositions[actors[seller]];

            balanceBefore = int256(_get_assets_in_token0(actors[seller], currentTick));

            hevm.prank(actors[seller]);
            panopticPool.mintOptions(posIdList, uint128(posSize) * 2, 0, 0, 0);

            userLiquidityPerPosition[actors[seller]] =
                int256(_get_assets_in_token0(actors[seller], currentTick)) -
                balanceBefore;

            emit LogString("Minted a new option");
            emit LogUint256("Position size", 2 * posSize);
            emit LogAddress("Minter", actors[seller]);

            lastPosId = _generate_single_leg_tokenid(asset, call_put, true, otm_itm, width, strike);
            userPositions[msg.sender].push(lastPosId);
            posIdList = userPositions[msg.sender];

            balanceBefore = int256(_get_assets_in_token0(msg.sender, currentTick));

            hevm.prank(msg.sender);
            panopticPool.mintOptions(posIdList, uint128(posSize), type(uint64).max, 0, 0);

            userLiquidityPerPosition[msg.sender] =
                int256(_get_assets_in_token0(msg.sender, currentTick)) -
                balanceBefore;

            emit LogString("Minted a new option");
            emit LogUint256("Position size", posSize);
            emit LogAddress("Minter", msg.sender);
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

        hevm.prank(actors[5]);
        swapperc.swapTo(pool, target_sqrt_price);
        hevm.warp(block.timestamp + 1000);
        hevm.roll(block.number + 100);

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
        hevm.prank(actors[5]);
        swapperc.mint(pool, -10, 10, 10 ** 18);
        hevm.prank(actors[5]);
        swapperc.burn(pool, -10, 10, 10 ** 18);
        //}

        int24 TWAPtick_after = PanopticMath.twapFilter(pool, 600);
        emit LogInt256("TWAP tick after", TWAPtick_after);
    }

    function _get_account_margin(
        address to_liquidate,
        int24 tick
    ) internal view returns (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1) {
        require(userPositions[to_liquidate].length > 0);
        int128 premium0;
        int128 premium1;
        uint256[2][] memory positions;

        (premium0, premium1, positions) = panopticPool.calculateAccumulatedFeesBatch(
            to_liquidate,
            true,
            userPositions[to_liquidate]
        );
        tokenData0 = collToken0.getAccountMarginDetails(to_liquidate, tick, positions, premium0);
        tokenData1 = collToken1.getAccountMarginDetails(to_liquidate, tick, positions, premium1);
    }

    // Q
    function _get_liquidation_bonus(address who, int24 twaptick) internal {
        //bonus = min{Collateral Balance / 2, Collateral Requirement at TWAP - Collateral Balance at TWAP}
        (uint160 currPriceX96, int24 currTick, , , , , ) = pool.slot0();

        (int128 expPremia0, int128 expPremia1, uint256[2][] memory positionBalances) = panopticPool
            .calculateAccumulatedFeesBatch(who, false, userPositions[who]);

        LeftRightUnsigned tokenData0 = collToken0.getAccountMarginDetails(
            who,
            twaptick,
            positionBalances,
            expPremia0
        );
        LeftRightUnsigned tokenData1 = collToken1.getAccountMarginDetails(
            who,
            twaptick,
            positionBalances,
            expPremia1
        );
        LeftRightSigned premia = LeftRightSigned.wrap(0).toRightSlot(expPremia0).toLeftSlot(
            expPremia1
        );

        /*(int256 bonus0, int256 bonus1, ) = PanopticMath.getLiquidationBonus(tokenData0, tokenData1,
            Math.getSqrtRatioAtTick(twaptick),
            Math.getSqrtRatioAtTick(currTick),
            $netExchanged,
            premia
        );*/
    }

    function _get_assets_in_token0(address who, int24 tick) internal view returns (uint256 assets) {
        assets =
            collToken0.convertToAssets(collToken0.balanceOf(who)) +
            PanopticMath.convert1to0(
                collToken1.convertToAssets(collToken1.balanceOf(who)),
                TickMath.getSqrtRatioAtTick(tick)
            );
    }

    function _getSolvencyBalances(
        address who,
        int24 tick
    ) internal view returns (uint256 balanceCross, uint256 thresholdCross) {
        (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1) = _get_account_margin(
            who,
            tick
        );
        uint160 sqrtPriceX96 = Math.getSqrtRatioAtTick(tick);
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

    function burn_option() public {
        if (userPositions[msg.sender].length < 1) {
            emit LogString("No current positions");
            revert();
        }

        uint256 numOfPositions = panopticPool.numberOfPositions(msg.sender);
        emit LogAddress("Caller", msg.sender);
        emit LogUint256("Positions opened for user", numOfPositions);

        TokenId[] memory emptyList;

        (uint128 bal, uint64 pool0, uint64 pool1) = panopticPool.optionPositionBalance(
            msg.sender,
            userPositions[msg.sender][0]
        );
        emit LogUint256("Pool balance for user", bal);
        emit LogUint256("Pool utilization of t0", pool0);
        emit LogUint256("Pool utilization of t1", pool1);

        uint256 bal0 = collToken0.convertToAssets(collToken0.balanceOf(msg.sender));
        uint256 bal1 = collToken1.convertToAssets(collToken1.balanceOf(msg.sender));
        emit LogUint256("Balance in token0", bal0);
        emit LogUint256("Balance in token1", bal1);

        // Burn the position

        // Preconditions
        // panopticPool.optionPositionBalance balance > 0
        // if leg is short, it is reversed, so:
        //    current liquidity (s_accountLiquidity[positionKey].rightSlot()) > liquidity chunk for the position (tokenid + leg)
        // current tick must be between tick limits in burnOptions call

        TokenId position = userPositions[msg.sender][0];

        (uint128 posSize, , ) = panopticPool.optionPositionBalance(msg.sender, position);
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
            hevm.prank(msg.sender);
            try panopticPool.burnOptions(userPositions[msg.sender][0], emptyList, 0, 0) {
                assertWithMsg(false, "A zero-sized position was burned.");
            } catch {}
            return;
        }

        if (position.isLong(0) == 0 && currentLiquidity.rightSlot() < liquidityChunk.liquidity()) {
            hevm.prank(msg.sender);
            try panopticPool.burnOptions(userPositions[msg.sender][0], emptyList, 0, 0) {
                assertWithMsg(false, "A short position with not enough liquidity was burned.");
            } catch {}
            return;
        }

        // TODO, calculate the minimum balance for it not to revert (CollateralTracker:1069)
        require(collToken0.balanceOf(msg.sender) > posSize / 10);

        int256 balanceBefore = int256(_get_assets_in_token0(msg.sender, currentTick));
        emit LogInt256("User Balance before burning in token0 terms", balanceBefore);

        hevm.prank(msg.sender);
        try panopticPool.burnOptions(userPositions[msg.sender][0], emptyList, 0, 0) {} catch {
            assertWithMsg(false, "Position could not be burned");
        }

        int256 balanceAfter = int256(_get_assets_in_token0(msg.sender, currentTick));
        emit LogInt256("User Balance before burning in token0 terms", balanceAfter);

        emit LogInt256("Delta balance", balanceAfter - balanceBefore);
        emit LogInt256("User liquidity delta", userLiquidityPerPosition[msg.sender]);

        userPositions[msg.sender].pop();
        userLiquidityPerPosition[msg.sender] = 0;
        return;
    }

    function try_liquidate_option(uint256 i_liquidated) public {
        i_liquidated = bound(i_liquidated, 0, 4);
        address liquidatee = actors[i_liquidated];

        if (userPositions[liquidatee].length < 1) {
            emit LogString("No current positions");
            revert();
        }

        require(liquidatee != msg.sender);

        TokenId[] memory liquidated_positions = userPositions[liquidatee];
        TokenId[] memory liquidator_positions = userPositions[msg.sender];

        emit LogUint256("liquidator positions length", liquidator_positions.length);
        emit LogUint256("liquidated positions length", liquidated_positions.length);
        emit LogAddress("liquidator", msg.sender);
        emit LogAddress("liquidated", liquidatee);

        int24 TWAPtick = PanopticMath.twapFilter(pool, 600);
        (, int24 curTick, , , , , ) = pool.slot0();
        emit LogInt256("TWAP tick", TWAPtick);
        emit LogInt256("Current tick", curTick);

        require(liquidated_positions.length > 0);

        (uint256 balanceCross, uint256 thresholdCross) = _getSolvencyBalances(liquidatee, TWAPtick);
        emit LogUint256("Balance cross", balanceCross);
        emit LogUint256("Threshold cross", thresholdCross);

        LeftRightUnsigned lru = LeftRightUnsigned
            .wrap(uint96(collToken0.convertToAssets(collToken0.balanceOf(msg.sender))))
            .toLeftSlot(uint96(collToken1.convertToAssets(collToken1.balanceOf(msg.sender))));

        (int128 p0, int128 p1, ) = panopticPool.calculateAccumulatedFeesBatch(
            liquidatee,
            true,
            liquidated_positions
        );
        emit LogInt256("Premium in token 0", p0);
        emit LogInt256("Premium in token 1", p1);

        uint256 liq_assets_before = _get_assets_in_token0(msg.sender, TWAPtick);

        // If the position is not liquidatable, liquidation call must revert
        if (balanceCross >= thresholdCross) {
            hevm.prank(msg.sender);
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

        hevm.prank(msg.sender);
        panopticPool.liquidate(liquidator_positions, liquidatee, lru, liquidated_positions);
        userPositions[msg.sender].pop();

        uint256 liq_assets_after = _get_assets_in_token0(msg.sender, TWAPtick);

        emit LogUint256("Liquidator assets before", liq_assets_before);
        emit LogUint256("Liquidator assets after", liq_assets_after);

        // Not an invariant, liquidations are not always profitable
        // assertWithMsg(liq_assets_after >= liq_assets_before, "Liquidator profit was negative");
    }

    /////////////////////////////////////////////////////////////
    // System Invariants
    /////////////////////////////////////////////////////////////

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

    /////////////////////////////////////////////////////////////
    // Wrappers
    /////////////////////////////////////////////////////////////

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
        pool.swap(recipient, zeroForOne, amountSpecified, sqrtPriceLimitX96, "");
    }

    function deposit_to_ct(bool token0, uint256 amount) public {
        amount = bound(amount, 1, MAX_DEPOSIT);

        if (token0) {
            amount = bound(amount, 1, IERC20(collToken0.asset()).balanceOf(msg.sender));
            hevm.prank(msg.sender);
            collToken0.deposit(amount, msg.sender);
        } else {
            amount = bound(amount, 1, IERC20(collToken1.asset()).balanceOf(msg.sender));
            hevm.prank(msg.sender);
            collToken1.deposit(amount, msg.sender);
        }
    }

    function withdraw_from_ct(bool token0, uint256 amount) public {
        if (token0) {
            amount = bound(amount, 1, collToken0.convertToAssets(collToken0.balanceOf(msg.sender)));
            hevm.prank(msg.sender);
            collToken0.withdraw(amount, msg.sender, msg.sender);
        } else {
            amount = bound(amount, 1, collToken1.convertToAssets(collToken1.balanceOf(msg.sender)));
            hevm.prank(msg.sender);
            collToken1.withdraw(amount, msg.sender, msg.sender);
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

    function convertToAssets(CollateralTracker ct, int256 amount) internal view returns (int256) {
        return (amount > 0 ? int8(1) : -1) * int256(ct.convertToAssets(uint256(Math.abs(amount))));
    }

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
            deal_USDC(
                address(ct),
                uint256(int256(IERC20(ct.asset()).balanceOf(address(ct))) + assetDelta),
                true
            );
        } else {
            deal_WETH(
                address(ct),
                uint256(int256(IERC20(ct.asset()).balanceOf(address(ct))) + assetDelta)
            );
        }

        deal_Generic(address(ct), 1, owner, newShares, true, 0); // deal(address(ct), owner, newShares, true);
    }

    function liquidate_option_via_edit(uint256 i_liquidated) internal {
        i_liquidated = bound(i_liquidated, 0, 4);
        if (userPositions[actors[i_liquidated]].length < 1) {
            emit LogString("No current positions");
            revert();
        }
        require(actors[i_liquidated] != msg.sender);

        TokenId[] memory liquidated_positions = userPositions[actors[i_liquidated]];
        TokenId[] memory liquidator_positions = userPositions[msg.sender];

        // get parameters from last
        TokenId position = liquidated_positions[liquidated_positions.length - 1];

        (, currentTick, , , , , ) = pool.slot0();

        {
            (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = panopticHelper
                .checkCollateral(
                    panopticPool,
                    actors[i_liquidated],
                    currentTick,
                    position.tokenType(0),
                    liquidated_positions
                );
            assertWithMsg(totalCollateralBalance0 >= totalCollateralRequired0, "not liquidatable");

            editCollateral(
                collToken0,
                actors[i_liquidated],
                collToken0.convertToShares(totalCollateralRequired0) - 1
            );

            (totalCollateralBalance0, totalCollateralRequired0) = panopticHelper.checkCollateral(
                panopticPool,
                actors[i_liquidated],
                currentTick,
                position.tokenType(0),
                liquidated_positions
            );
            require(totalCollateralBalance0 < totalCollateralRequired0);
        }

        emit LogUint256("liquidator positions length", liquidator_positions.length);
        emit LogUint256("liquidated positions length", liquidated_positions.length);
        emit LogAddress("liquidator", msg.sender);
        emit LogAddress("liquidated", actors[i_liquidated]);

        LeftRightUnsigned lru = LeftRightUnsigned
            .wrap(uint96(IERC20(USDC).balanceOf(msg.sender)))
            .toLeftSlot(uint96(IERC20(WETH).balanceOf(msg.sender)));
        hevm.prank(msg.sender);
        panopticPool.liquidate(
            liquidator_positions,
            actors[i_liquidated],
            lru,
            liquidated_positions
        );
    }
}
