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
            sqrtPriceX96Before > sqrtPriceX96 ? int256(IERC20(pool.token0()).balanceOf(msg.sender)) : int256(IERC20(pool.token1()).balanceOf(msg.sender)),
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

    uint256 constant MAX_DEPOSIT = 10 ether;

    constructor() {

        // Actors
        actors = new address[](6);
        actors[0] = address(0xa11ce);
        actors[1] = address(0xb0b);
        actors[2] = address(0xcafe);
        actors[3] = address(0xda210);
        actors[4] = address(0xedda);
        actors[5] = address(0xfaded);

        for(uint i = 0; i < 6; i++) {
            userPositions[actors[i]] = new TokenId[](0);
        }
        
        // See if mock or new deploy
        univ3factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
        //hevm.label(address(univ3factory), "UniV3Factory");

        sfpm = new SemiFungiblePositionManager(univ3factory);
        //hevm.label(address(sfpm), "SFPM");
        panopticHelper = new PanopticHelper(sfpm);
        //hevm.label(address(panopticHelper), "PanopticHelper");

        // Import the Panoptic Pool reference (for cloning)
        poolReference = address(new PanopticPool(sfpm));
        //hevm.label(address(poolReference), "PanopticPool");

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
        //hevm.label(address(panopticFactory), "PanopticFactory");

        panopticFactory.initialize(address(this));
        DonorNFT(address(dnft)).changeFactory(address(panopticFactory));

        swapperc = new SwapperC();
        //hevm.label(address(swapperc), "SwapperC");

        //hevm.label(address(USDC), "USDC");
        //hevm.label(address(WETH), "WETH");
        //hevm.label(address(USDC_WETH_5), "USDC_WETH_5");

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

        emit LogAddress("collToken0", address(collToken0));
        emit LogAddress("collToken1", address(collToken1));
        emit LogAddress("panopticPool", address(panopticPool));
        emit LogAddress("panopticFactory", address(panopticFactory));
        emit LogAddress("SFPM", address(sfpm));
        emit LogAddress("echidna contract", address(this));
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

        // convert signed int to assets
    function convertToAssets(CollateralTracker ct, int256 amount) internal view returns (int256) {
        return (amount > 0 ? int8(1) : -1) * int256(ct.convertToAssets(uint256(Math.abs(amount))));
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

    function deposit_to_ct(bool token0, uint256 amount) public {
        amount = bound(amount, 1, MAX_DEPOSIT);

        if(token0) {
            amount = bound(amount, 1, IERC20(collToken0.asset()).balanceOf(msg.sender));
            hevm.prank(msg.sender);
            collToken0.deposit(amount, msg.sender);
        } else {
            amount = bound(amount, 1, IERC20(collToken1.asset()).balanceOf(msg.sender));
            hevm.prank(msg.sender);
            collToken1.deposit(amount, msg.sender);
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
            deal_USDC(address(ct), uint256(int256(IERC20(ct.asset()).balanceOf(address(ct))) + assetDelta), true);
        } else {
            deal_WETH(address(ct), uint256(int256(IERC20(ct.asset()).balanceOf(address(ct))) + assetDelta));
        }

        deal_Generic(address(ct), 1, owner, newShares, true, 0); // deal(address(ct), owner, newShares, true);
    }

    function generate_single_leg_tokenid_long(bool asset_in, bool call_put_in, bool otm_itm_in, uint24 width_in, int256 strike_in) internal returns (TokenId out) {

        out = TokenId.wrap(poolId);

        // Rest of the parameters come from the function parameters
        // For now, fixing them one at a time
        uint256 asset = 0; //asset_in == true ? 1 : 0;
        uint256 call_put = 0; // call_put_in == true ? 1 : 0;
        uint256 long_short = 0; // long_short_in == true ? 1 : 0;

        int24 width;
        int24 strike;

        // Lets just generate OTM for now
        (width, strike) = getOTMSW(width_in, strike_in, uint24(poolTickSpacing), currentTick, 0);

        out = out.addLeg(0, 1, asset, long_short, call_put, 0, strike, width);
        emit LogUint256("asset", asset);
        emit LogUint256("long/short", long_short);
        emit LogUint256("call/put", call_put);
        emit LogUint256("strike", uint256(int256(strike)));
        emit LogUint256("width", uint256(int256(width)));
        emit LogUint256("out", TokenId.unwrap(out));
    }

    function generate_single_leg_tokenid_short(bool asset_in, bool call_put_in, bool otm_itm_in, uint24 width_in, int256 strike_in) internal returns (TokenId out) {

        out = TokenId.wrap(poolId);

        // Rest of the parameters come from the function parameters
        // For now, fixing them one at a time
        uint256 asset = 0; //asset_in == true ? 1 : 0;
        uint256 call_put = 0; // call_put_in == true ? 1 : 0;
        uint256 long_short = 1; // long_short_in == true ? 1 : 0;

        int24 width;
        int24 strike;

        // Lets just generate OTM for now
        (width, strike) = getOTMSW(width_in, strike_in, uint24(poolTickSpacing), currentTick, 0);

        out = out.addLeg(0, 1, asset, long_short, call_put, 0, strike, width);
        emit LogUint256("asset", asset);
        emit LogUint256("long/short", long_short);
        emit LogUint256("call/put", call_put);
        emit LogUint256("strike", uint256(int256(strike)));
        emit LogUint256("width", uint256(int256(width)));
        emit LogUint256("out", TokenId.unwrap(out));
    }

    function mint_option(uint256 seller, bool asset, bool call_put, bool long_short, bool otm_itm, uint24 width, int256 strike, uint256 posSize) public {

        seller = bound(seller, 0, 4);
        if(actors[seller] == msg.sender) {
            seller = bound(seller +1, 0, 4);
        }

        require(userPositions[msg.sender].length == 0, "Too many positions for user");

        posSize = bound(posSize, 1000, 1000000);

        if(long_short) {
            TokenId lastPosId = generate_single_leg_tokenid_long(asset, call_put, otm_itm, width, strike);
            userPositions[msg.sender].push(lastPosId);
            TokenId[] memory posIdList = userPositions[msg.sender];

            hevm.prank(msg.sender);
            panopticPool.mintOptions(posIdList, uint128(posSize), 0, 0, 0);

        } else {
            TokenId lastPosId = generate_single_leg_tokenid_long(asset, call_put, otm_itm, width, strike);
            userPositions[actors[seller]].push(lastPosId);
            TokenId[] memory posIdList = userPositions[actors[seller]];

            hevm.prank(actors[seller]);
            panopticPool.mintOptions(posIdList, uint128(posSize)*2, 0, 0, 0);

            lastPosId = generate_single_leg_tokenid_short(asset, call_put, otm_itm, width, strike);
            userPositions[msg.sender].push(lastPosId);
            posIdList = userPositions[msg.sender];

            hevm.prank(msg.sender);
            panopticPool.mintOptions(posIdList, uint128(posSize), type(uint64).max, 0, 0);
        }

        emit LogString("Minted a new option");
    }

    function perform_swap(uint160 target_sqrt_price) public {

        // bound the price between 1000 and 5000 
        target_sqrt_price = uint160(bound(target_sqrt_price, 1120444674276726262247898545651712, 2505352955026066883383046797524992));

        uint160 price;

        (price, , , , , , ) = pool.slot0();

        emit LogUint256("price before swap", uint256(price));

        hevm.prank(actors[5]);
        swapperc.swapTo(pool, target_sqrt_price);

        (price, , , , , , ) = pool.slot0();
        emit LogUint256("price after swap", uint256(price));
        
    }

    function update_twap() public {

        int24 TWAPtick_before = PanopticMath.twapFilter(pool, 600);
        emit LogInt256("TWAP tick before", TWAPtick_before);

        // update twaps
        for (uint256 i = 0; i < 20; ++i) {
            hevm.warp(block.timestamp + 120);
            hevm.roll(block.number + 10);
            hevm.prank(actors[5]);
            swapperc.mint(pool, -10, 10, 10 ** 18);
            hevm.prank(actors[5]);
            swapperc.burn(pool, -10, 10, 10 ** 18);
        }

        int24 TWAPtick_after = PanopticMath.twapFilter(pool, 600);
        emit LogInt256("TWAP tick after", TWAPtick_after);
    }

    function try_liquidate_option(uint256 i_liquidated) public {
        i_liquidated = bound(i_liquidated, 0, 4);
        if(userPositions[actors[i_liquidated]].length < 1) {
            emit LogString("No current positions");
            revert();
        }
        require(actors[i_liquidated] != msg.sender);

        TokenId[] memory liquidated_positions = userPositions[actors[i_liquidated]];
        TokenId[] memory liquidator_positions = userPositions[msg.sender];


        emit LogUint256("liquidator positions length", liquidator_positions.length);
        emit LogUint256("liquidated positions length", liquidated_positions.length);
        emit LogAddress("liquidator", msg.sender);
        emit LogAddress("liquidated", actors[i_liquidated]);


        LeftRightUnsigned lru = LeftRightUnsigned.wrap(uint96(IERC20(USDC).balanceOf(msg.sender))).toLeftSlot(uint96(IERC20(WETH).balanceOf(msg.sender)));
        hevm.prank(msg.sender);
        panopticPool.liquidate(liquidator_positions, actors[i_liquidated], lru, liquidated_positions);

        assertWithMsg(false, "liquidated");

    }

    function liquidate_option_via_edit(uint256 i_liquidated) internal {
        i_liquidated = bound(i_liquidated, 0, 4);
        if(userPositions[actors[i_liquidated]].length < 1) {
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
            (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = panopticHelper.checkCollateral(panopticPool, actors[i_liquidated], currentTick, position.tokenType(0), liquidated_positions);
            assertWithMsg(totalCollateralBalance0 >= totalCollateralRequired0, "not liquidatable");

            editCollateral(collToken0, actors[i_liquidated], collToken0.convertToShares(totalCollateralRequired0) - 1);

            (totalCollateralBalance0, totalCollateralRequired0) = panopticHelper.checkCollateral(panopticPool, actors[i_liquidated], currentTick, position.tokenType(0), liquidated_positions);
            require(totalCollateralBalance0 < totalCollateralRequired0);
        }

        emit LogUint256("liquidator positions length", liquidator_positions.length);
        emit LogUint256("liquidated positions length", liquidated_positions.length);
        emit LogAddress("liquidator", msg.sender);
        emit LogAddress("liquidated", actors[i_liquidated]);


        LeftRightUnsigned lru = LeftRightUnsigned.wrap(uint96(IERC20(USDC).balanceOf(msg.sender))).toLeftSlot(uint96(IERC20(WETH).balanceOf(msg.sender)));
        hevm.prank(msg.sender);
        panopticPool.liquidate(liquidator_positions, actors[i_liquidated], lru, liquidated_positions);

    }

}
