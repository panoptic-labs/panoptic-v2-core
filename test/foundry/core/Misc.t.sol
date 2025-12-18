// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManagerV4.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {RiskEngine} from "@contracts/RiskEngine.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";
import {PanopticFactory} from "@contracts/PanopticFactoryV4.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {PanopticHelper} from "@test_periphery/PanopticHelper.sol";
import {ISwapRouter} from "v3-periphery/interfaces/ISwapRouter.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {ISemiFungiblePositionManager} from "@contracts/interfaces/ISemiFungiblePositionManager.sol";
import {TokenId} from "@types/TokenId.sol";
import {OraclePack} from "@types/OraclePack.sol";
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {CallbackLib} from "@libraries/CallbackLib.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";
import {PositionUtils} from "../testUtils/PositionUtils.sol";
import {Math} from "@libraries/Math.sol";
import {Errors} from "@libraries/Errors.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {Constants} from "@libraries/Constants.sol";
import {Pointer} from "@types/Pointer.sol";
import {ERC20S} from "../testUtils/ERC20S.sol";
import {LiquidityChunk, LiquidityChunkLibrary} from "@types/LiquidityChunk.sol";
import {V4RouterSimple} from "../testUtils/V4RouterSimple.sol";
// V4 types
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {V4StateReader} from "@libraries/V4StateReader.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {V4RouterSimple} from "../testUtils/V4RouterSimple.sol";

contract SwapperC {
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

        pool.swap(
            msg.sender,
            sqrtPriceX96Before > sqrtPriceX96 ? true : false,
            type(int128).max,
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

// mostly just fixed one-off tests/PoC
contract Misctest is Test, PositionUtils {
    // the instance of SFPM we are testing
    SemiFungiblePositionManager sfpm;

    // reference implemenatations used by the factory
    address poolReference;

    address collateralReference;

    // Mainnet factory address - SFPM is dependent on this for several checks and callbacks
    IUniswapV3Factory V3FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

    // Mainnet router address - used for swaps to test fees/premia
    ISwapRouter router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    PanopticFactory factory;
    PanopticPool pp;
    CollateralTracker ct0;
    CollateralTracker ct1;
    PanopticHelper ph;
    IRiskEngine re;

    IPoolManager manager;

    V4RouterSimple routerV4;
    int24 MAX_CLAMP_DELTA;

    PoolKey poolKey;

    int24 currentTick;
    int256 twapTick;
    int24 slowOracleTick;
    int24 fastOracleTick;
    int24 lastObservedTick;
    int24 $strike;
    int24 $width;

    OraclePack oraclePack;
    uint64 $poolId;
    uint64 poolId;
    uint8 vegoid = 4;
    uint256 medianData;

    uint256 assetsBefore0;
    uint256 assetsBefore1;

    uint256[] assetsBefore0Arr;
    uint256[] assetsBefore1Arr;

    uint256 basalCR;
    uint256 amountBorrowed;
    uint256 amountITM;
    int256 util;
    LeftRightUnsigned amountsMoved;
    uint256 remainingCR;
    uint160 sqrtPriceTargetX96;

    IUniswapV3Pool uniPool;
    ERC20S token0;
    ERC20S token1;

    address Deployer = address(0x1234);
    address Alice = address(0x123456);
    address Bob = address(0x12345678);
    address Swapper = address(0x123456789);
    address Charlie = address(0x1234567891);
    address Seller = address(0x12345678912);
    address Eve = address(0x123456789123);

    address[] Buyers;
    address[] Buyer;
    SwapperC swapperc;

    TokenId $tokenIdShort;
    TokenId $tokenIdLong;
    TokenId[] $setupIdList;
    TokenId[] $posIdList;
    TokenId[][] $posIdLists;
    TokenId[] $tempIdList;

    address[] owners;
    TokenId[] tokenIdsTemp;
    TokenId[][] tokenIds;
    TokenId[][] positionIdLists;
    TokenId[][] collateralIdLists;

    function setUp() public {
        vm.startPrank(Deployer);
        manager = new PoolManager(address(0));
        routerV4 = new V4RouterSimple(manager);

        sfpm = new SemiFungiblePositionManager(manager, 10 ** 13, 10 ** 13, 0);

        ph = new PanopticHelper(ISemiFungiblePositionManager(address(sfpm)));

        // deploy reference pool and collateral token
        poolReference = address(new PanopticPool(ISemiFungiblePositionManager(address(sfpm))));
        collateralReference = address(new CollateralTracker(10));
        token0 = new ERC20S("token0", "T0", 18);
        token1 = new ERC20S("token1", "T1", 18);
        uniPool = IUniswapV3Pool(V3FACTORY.createPool(address(token0), address(token1), 500));

        MAX_CLAMP_DELTA = 149;
        re = IRiskEngine(address(new RiskEngine(10_000_000, 10_000_000, address(0), address(0))));

        poolKey = PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            500,
            10,
            IHooks(address(0))
        );

        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);
        token0.approve(address(routerV4), type(uint248).max);
        token1.approve(address(routerV4), type(uint248).max);
        // This price causes exactly one unit of liquidity to be minted
        // above here reverts b/c 0 liquidity cannot be minted
        IUniswapV3Pool(uniPool).initialize(2 ** 96);

        IUniswapV3Pool(uniPool).increaseObservationCardinalityNext(100);

        // move back to price=1 while generating 100 observations (min required for pool to function)
        for (uint256 i = 0; i < 100; ++i) {
            vm.warp(block.timestamp + 1);
            vm.roll(block.number + 1);
            swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
            swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
        }
        swapperc.mint(uniPool, -887270, 887270, 10 ** 18);

        swapperc.swapTo(uniPool, 2 ** 96 + 2 ** 88);

        manager.initialize(poolKey, 1 * 2 ** 96);

        swapperc.burn(uniPool, -887270, 887270, 10 ** 18);

        _createPanopticPool();

        swapperc.mint(uniPool, -887270, 887270, 1);

        routerV4.modifyLiquidity(address(0), poolKey, -887270, 887270, 1);

        vm.startPrank(Alice);

        token0.mint(Alice, uint256(type(uint104).max) * 2);
        token1.mint(Alice, uint256(type(uint104).max) * 2);

        ct0 = pp.collateralToken0();
        ct1 = pp.collateralToken1();

        token0.approve(address(ct0), type(uint256).max);
        token1.approve(address(ct1), type(uint256).max);

        ct0.deposit(type(uint104).max, Alice);
        ct1.deposit(type(uint104).max, Alice);

        vm.startPrank(Bob);

        token0.mint(Bob, type(uint104).max);
        token1.mint(Bob, type(uint104).max);

        token0.approve(address(ct0), type(uint104).max);
        token1.approve(address(ct1), type(uint104).max);

        ct0.deposit(type(uint104).max, Bob);
        ct1.deposit(type(uint104).max, Bob);

        vm.startPrank(Charlie);

        token0.mint(Charlie, type(uint104).max);
        token1.mint(Charlie, type(uint104).max);

        token0.approve(address(ct0), type(uint104).max);
        token1.approve(address(ct1), type(uint104).max);

        ct0.deposit(type(uint104).max / 2, Charlie);
        ct1.deposit(type(uint104).max / 2, Charlie);

        vm.startPrank(Seller);

        token0.mint(Seller, type(uint104).max / 1_000_000);
        token1.mint(Seller, type(uint104).max / 1_000_000);

        token0.approve(address(ct0), type(uint104).max / 1_000_000);
        token1.approve(address(ct1), type(uint104).max / 1_000_000);

        ct0.deposit(type(uint104).max / 1_000_000, Seller);
        ct1.deposit(type(uint104).max / 1_000_000, Seller);

        for (uint256 i = 0; i < 3; i++) {
            Buyers.push(address(uint160(uint256(keccak256(abi.encodePacked(i + 1337))))));

            vm.startPrank(Buyers[i]);

            token0.mint(Buyers[i], type(uint104).max / 1_000_000);
            token1.mint(Buyers[i], type(uint104).max / 1_000_000);

            token0.approve(address(ct0), type(uint104).max / 1_000_000);
            token1.approve(address(ct1), type(uint104).max / 1_000_000);

            ct0.deposit(type(uint104).max / 1_000_000, Buyers[i]);
            ct1.deposit(type(uint104).max / 1_000_000, Buyers[i]);
        }

        // // setup mini-median price array
        // for (uint256 i = 0; i < 8; ++i) {
        //     vm.warp(block.timestamp + 120);
        //     vm.roll(block.number + 1);
        //     pp.pokeOracle();
        // }

        for (uint256 i = 0; i < 20; ++i) {
            $posIdLists.push(new TokenId[](0));
        }
    }

    function _createPanopticPool() internal {
        vm.startPrank(Deployer);

        factory = new PanopticFactory(
            sfpm,
            manager,
            poolReference,
            collateralReference,
            new bytes32[](0),
            new uint256[][](0),
            new Pointer[][](0)
        );

        token0.mint(Deployer, type(uint104).max);
        token1.mint(Deployer, type(uint104).max);
        token0.approve(address(factory), type(uint104).max);
        token1.approve(address(factory), type(uint104).max);

        pp = PanopticPool(address(factory.deployNewPool(poolKey, re, uint96(block.timestamp))));

        vm.startPrank(Swapper);
        swapperc.swapTo(uniPool, 2 ** 96);
        routerV4.swapTo(address(0), poolKey, 2 ** 96);

        // Update median
        pp.pokeOracle();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        pp.pokeOracle();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        pp.pokeOracle();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        pp.pokeOracle();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        pp.pokeOracle();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        ct0 = pp.collateralToken0();
        ct1 = pp.collateralToken1();
    }

    function mintOptions(
        PanopticPool pp,
        TokenId[] memory positionIdList,
        uint128 positionSize,
        uint24 effectiveLiquidityLimitX32,
        int24 tickLimitLow,
        int24 tickLimitHigh,
        bool premiaAsCollateral
    ) internal {
        uint128[] memory sizeList = new uint128[](1);
        TokenId[] memory mintList = new TokenId[](1);
        int24[3][] memory tickAndSpreadLimits = new int24[3][](1);

        TokenId tokenId = positionIdList[positionIdList.length - 1];
        sizeList[0] = positionSize;
        mintList[0] = tokenId;
        tickAndSpreadLimits[0][0] = tickLimitLow;
        tickAndSpreadLimits[0][1] = tickLimitHigh;
        tickAndSpreadLimits[0][2] = int24(uint24(effectiveLiquidityLimitX32));

        pp.dispatch(mintList, positionIdList, sizeList, tickAndSpreadLimits, premiaAsCollateral, 0);
    }

    function burnOptions(
        PanopticPool pp,
        TokenId tokenId,
        TokenId[] memory positionIdList,
        int24 tickLimitLow,
        int24 tickLimitHigh,
        bool premiaAsCollateral
    ) internal {
        uint128[] memory sizeList = new uint128[](1);
        TokenId[] memory burnList = new TokenId[](1);
        int24[3][] memory tickAndSpreadLimits = new int24[3][](1);

        sizeList[0] = 0;
        burnList[0] = tokenId;
        tickAndSpreadLimits[0][0] = tickLimitLow;
        tickAndSpreadLimits[0][1] = tickLimitHigh;
        tickAndSpreadLimits[0][2] = int24(uint24(0));
        pp.dispatch(burnList, positionIdList, sizeList, tickAndSpreadLimits, premiaAsCollateral, 0);
    }

    function burnOptions(
        PanopticPool pp,
        TokenId[] memory tokenIds,
        TokenId[] memory positionIdList,
        int24 tickLimitLow,
        int24 tickLimitHigh,
        bool premiaAsCollateral
    ) internal {
        uint128[] memory sizeList = new uint128[](tokenIds.length);
        int24[3][] memory tickAndSpreadLimits = new int24[3][](tokenIds.length);

        for (uint256 i; i < tokenIds.length; ++i) {
            tickAndSpreadLimits[i][0] = tickLimitLow;
            tickAndSpreadLimits[i][1] = tickLimitHigh;
            tickAndSpreadLimits[i][2] = int24(uint24(0));
        }

        pp.dispatch(tokenIds, positionIdList, sizeList, tickAndSpreadLimits, premiaAsCollateral, 0);
    }

    function liquidate(
        PanopticPool pp,
        TokenId[] memory liquidatorList,
        address liquidatee,
        TokenId[] memory positionIdList
    ) internal {
        uint128[] memory sizeList = new uint128[](1);

        pp.dispatchFrom(
            liquidatorList,
            liquidatee,
            positionIdList,
            new TokenId[](0),
            LeftRightUnsigned.wrap(0).addToRightSlot(1).addToLeftSlot(1)
        );
    }

    function forceExercise(
        PanopticPool pp,
        address exercisee,
        TokenId tokenId,
        TokenId[] memory exerciseeListFinal,
        TokenId[] memory exercisorList,
        LeftRightUnsigned premiaAsCollateral
    ) internal {
        uint128[] memory sizeList = new uint128[](1);

        TokenId[] memory exerciseeListInitial = new TokenId[](exerciseeListFinal.length + 1);
        for (uint256 i = 0; i < exerciseeListFinal.length; ++i) {
            exerciseeListInitial[i] = exerciseeListFinal[i];
        }
        exerciseeListInitial[exerciseeListInitial.length - 1] = tokenId;

        pp.dispatchFrom(
            exercisorList,
            exercisee,
            exerciseeListInitial,
            exerciseeListFinal,
            premiaAsCollateral
        );
    }

    function settlePremium(
        PanopticPool pp,
        TokenId[] memory settlerList,
        TokenId[] memory settleeList,
        address exercisee,
        uint256 legIndex,
        bool premiaAsCollateral
    ) internal {
        uint128[] memory sizeList = new uint128[](1);

        TokenId[] memory targetList = new TokenId[](1);

        pp.dispatchFrom(
            settlerList,
            exercisee,
            settleeList,
            settleeList,
            LeftRightUnsigned.wrap(0).addToRightSlot(premiaAsCollateral ? 1 : 0).addToLeftSlot(
                premiaAsCollateral ? 1 : 0
            )
        );
    }

    function settlePremiumSelf(
        PanopticPool pp,
        TokenId[] memory mintList,
        uint128 positionSize,
        bool premiaAsCollateral
    ) internal {
        uint128[] memory sizeList = new uint128[](1);
        sizeList[0] = positionSize;

        int24[3][] memory tickAndSpreadLimits = new int24[3][](1);

        tickAndSpreadLimits[0][0] = -887272;
        tickAndSpreadLimits[0][1] = 887272;
        tickAndSpreadLimits[0][2] = int24(uint24(type(uint24).max));

        pp.dispatch(mintList, mintList, sizeList, tickAndSpreadLimits, premiaAsCollateral, 0);
    }

    function test_gas_MaxPositions_short_packed() public {
        uint256 positionCount = 8;

        for (uint256 i = 0; i < positionCount; i++) {
            {
                poolId =
                    uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                    uint64(uint256(vegoid) << 40);
                poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
            }
            TokenId posId = TokenId.wrap(0).addPoolId(poolId).addLeg({
                legIndex: 0,
                _optionRatio: 1,
                _asset: 1,
                _isLong: 0,
                _tokenType: 0,
                _riskPartner: 0,
                _strike: 0,
                _width: int24(uint24(2 * (4 * i + 1)))
            });
            posId = posId.addLeg({
                legIndex: 1,
                _optionRatio: 1,
                _asset: 0,
                _isLong: 0,
                _tokenType: 1,
                _riskPartner: 1,
                _strike: 0,
                _width: int24(uint24(2 * (4 * i + 2)))
            });
            posId = posId.addLeg({
                legIndex: 2,
                _optionRatio: 1,
                _asset: 1,
                _isLong: 0,
                _tokenType: 0,
                _riskPartner: 2,
                _strike: 0,
                _width: int24(uint24(2 * (4 * i + 3)))
            });
            if (i != positionCount - 1)
                posId = posId.addLeg({
                    legIndex: 3,
                    _optionRatio: 1,
                    _asset: 0,
                    _isLong: 0,
                    _tokenType: 1,
                    _riskPartner: 3,
                    _strike: 0,
                    _width: int24(uint24(2 * (4 * i + 4)))
                });

            $posIdList.push(posId);

            vm.startPrank(Bob);

            mintOptions(
                pp,
                $posIdList,
                2_000_000,
                0,
                Constants.MIN_POOL_TICK,
                Constants.MAX_POOL_TICK,
                true
            );

            if (i == positionCount - 1) {
                {
                    poolId =
                        uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                        uint64(uint256(vegoid) << 40);
                    poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
                }

                posId = TokenId.wrap(0).addPoolId(poolId).addLeg({
                    legIndex: 0,
                    _optionRatio: 1,
                    _asset: 1,
                    _isLong: 0,
                    _tokenType: 0,
                    _riskPartner: 0,
                    _strike: 0,
                    _width: int24(uint24(2 * (4 * i + 1)))
                });
                posId = posId.addLeg({
                    legIndex: 1,
                    _optionRatio: 1,
                    _asset: 0,
                    _isLong: 0,
                    _tokenType: 1,
                    _riskPartner: 1,
                    _strike: 0,
                    _width: int24(uint24(2 * (4 * i + 2)))
                });
                posId = posId.addLeg({
                    legIndex: 2,
                    _optionRatio: 1,
                    _asset: 1,
                    _isLong: 0,
                    _tokenType: 0,
                    _riskPartner: 2,
                    _strike: 0,
                    _width: int24(uint24(2 * (4 * i + 3)))
                });
                // posId = posId.addLeg({
                //     legIndex: 3,
                //     _optionRatio: 1,
                //     _asset: 0,
                //     _isLong: 0,
                //     _tokenType: 1,
                //     _riskPartner: 3,
                //     _strike: 0,
                //     _width: int24(uint24(2 * (4 * i + 4)))
                // });

                $posIdList[positionCount - 1] = posId;
            }

            vm.startPrank(Alice);
            mintOptions(
                pp,
                $posIdList,
                1_000_000,
                type(uint24).max,
                Constants.MIN_POOL_TICK,
                Constants.MAX_POOL_TICK,
                true
            );
        }

        vm.startPrank(Eve);

        token0.mint(Eve, type(uint104).max);
        token1.mint(Eve, type(uint104).max);
        token0.approve(address(ct0), type(uint104).max);
        token1.approve(address(ct1), type(uint104).max);

        accruePoolFeesInRange(
            manager,
            poolKey,
            StateLibrary.getLiquidity(manager, poolKey.toId()) - 1,
            10_000_000,
            20_000_000
        );

        editCollateral(ct0, Alice, 0);
        editCollateral(ct1, Alice, 0);

        uint256 gasBefore = gasleft();
        liquidate(pp, new TokenId[](0), Alice, $posIdList);
        console.log("Gas used: %d Liquidation", gasBefore - gasleft());
    }

    function test_gas_MaxPositions_short_soloLeg() public {
        uint256 positionCount = 32;

        for (uint256 i = 0; i < positionCount; i++) {
            {
                poolId =
                    uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                    uint64(uint256(vegoid) << 40);
                poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
            }
            TokenId posId = TokenId.wrap(0).addPoolId(poolId).addLeg({
                legIndex: 0,
                _optionRatio: 1,
                _asset: 1,
                _isLong: 0,
                _tokenType: 0,
                _riskPartner: 0,
                _strike: 0,
                _width: int24(uint24(2 * (i + 1)))
            });

            $posIdList.push(posId);

            vm.startPrank(Bob);

            mintOptions(
                pp,
                $posIdList,
                2_000_000,
                0,
                Constants.MIN_POOL_TICK,
                Constants.MAX_POOL_TICK,
                true
            );

            if (i == positionCount - 1) {
                {
                    poolId =
                        uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                        uint64(uint256(vegoid) << 40);
                    poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
                }
                posId = TokenId.wrap(0).addPoolId(poolId).addLeg({
                    legIndex: 0,
                    _optionRatio: 1,
                    _asset: 1,
                    _isLong: 0,
                    _tokenType: 0,
                    _riskPartner: 0,
                    _strike: 0,
                    _width: int24(uint24(2 * (i + 1)))
                });
                $posIdList[positionCount - 1] = posId;
            }

            vm.startPrank(Alice);
            mintOptions(
                pp,
                $posIdList,
                1_000_000,
                type(uint24).max,
                Constants.MIN_POOL_TICK,
                Constants.MAX_POOL_TICK,
                true
            );
        }

        vm.startPrank(Eve);

        token0.mint(Eve, type(uint104).max);
        token1.mint(Eve, type(uint104).max);
        token0.approve(address(ct0), type(uint104).max);
        token1.approve(address(ct1), type(uint104).max);

        accruePoolFeesInRange(
            manager,
            poolKey,
            StateLibrary.getLiquidity(manager, poolKey.toId()) - 1,
            10_000_000,
            20_000_000
        );

        editCollateral(ct0, Alice, 0);
        editCollateral(ct1, Alice, 0);

        uint256 gasBefore = gasleft();
        liquidate(pp, new TokenId[](0), Alice, $posIdList);
        console.log("Gas used: %d Liquidation", gasBefore - gasleft());
    }

    function test_gas_MaxPositions_long_packed() public {
        uint256 positionCount = 8;

        for (uint256 i = 0; i < positionCount; i++) {
            {
                poolId =
                    uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                    uint64(uint256(vegoid) << 40);
                poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
            }
            TokenId posId = TokenId.wrap(0).addPoolId(poolId).addLeg({
                legIndex: 0,
                _optionRatio: 1,
                _asset: 1,
                _isLong: 0,
                _tokenType: 0,
                _riskPartner: 0,
                _strike: 0,
                _width: int24(uint24(2 * (4 * i + 1)))
            });
            posId = posId.addLeg({
                legIndex: 1,
                _optionRatio: 1,
                _asset: 0,
                _isLong: 0,
                _tokenType: 1,
                _riskPartner: 1,
                _strike: 0,
                _width: int24(uint24(2 * (4 * i + 2)))
            });
            posId = posId.addLeg({
                legIndex: 2,
                _optionRatio: 1,
                _asset: 1,
                _isLong: 0,
                _tokenType: 0,
                _riskPartner: 2,
                _strike: 0,
                _width: int24(uint24(2 * (4 * i + 3)))
            });
            if (i != 0)
                posId = posId.addLeg({
                    legIndex: 3,
                    _optionRatio: 1,
                    _asset: 0,
                    _isLong: 0,
                    _tokenType: 1,
                    _riskPartner: 3,
                    _strike: 0,
                    _width: int24(uint24(2 * (4 * i + 4)))
                });

            $setupIdList.push(posId);

            vm.startPrank(Bob);

            mintOptions(
                pp,
                $setupIdList,
                2_000_000,
                0,
                Constants.MIN_POOL_TICK,
                Constants.MAX_POOL_TICK,
                true
            );

            {
                poolId =
                    uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                    uint64(uint256(vegoid) << 40);
                poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
            }
            posId = TokenId.wrap(0).addPoolId(poolId).addLeg({
                legIndex: 0,
                _optionRatio: 1,
                _asset: 1,
                _isLong: 1,
                _tokenType: 0,
                _riskPartner: 0,
                _strike: 0,
                _width: int24(uint24(2 * (4 * i + 1)))
            });
            posId = posId.addLeg({
                legIndex: 1,
                _optionRatio: 1,
                _asset: 0,
                _isLong: 1,
                _tokenType: 1,
                _riskPartner: 1,
                _strike: 0,
                _width: int24(uint24(2 * (4 * i + 2)))
            });
            posId = posId.addLeg({
                legIndex: 2,
                _optionRatio: 1,
                _asset: 1,
                _isLong: 1,
                _tokenType: 0,
                _riskPartner: 2,
                _strike: 0,
                _width: int24(uint24(2 * (4 * i + 3)))
            });
            posId = posId.addLeg({
                legIndex: 3,
                _optionRatio: 1,
                _asset: 0,
                _isLong: 1,
                _tokenType: 1,
                _riskPartner: 3,
                _strike: 0,
                _width: int24(uint24(2 * (4 * i + 4)))
            });

            if (i == 0) {
                {
                    poolId =
                        uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                        uint64(uint256(vegoid) << 40);
                    poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
                }
                posId = TokenId.wrap(0).addPoolId(poolId).addLeg({
                    legIndex: 0,
                    _optionRatio: 1,
                    _asset: 1,
                    _isLong: 0,
                    _tokenType: 0,
                    _riskPartner: 0,
                    _strike: 0,
                    _width: int24(uint24(2 * (4 * i + 1)))
                });
                posId = posId.addLeg({
                    legIndex: 1,
                    _optionRatio: 1,
                    _asset: 0,
                    _isLong: 1,
                    _tokenType: 1,
                    _riskPartner: 1,
                    _strike: 0,
                    _width: int24(uint24(2 * (4 * i + 2)))
                });
                posId = posId.addLeg({
                    legIndex: 2,
                    _optionRatio: 1,
                    _asset: 1,
                    _isLong: 1,
                    _tokenType: 0,
                    _riskPartner: 2,
                    _strike: 0,
                    _width: int24(uint24(2 * (4 * i + 3)))
                });
                // posId = posId.addLeg({
                //     legIndex: 3,
                //     _optionRatio: 1,
                //     _asset: 0,
                //     _isLong: 1,
                //     _tokenType: 1,
                //     _riskPartner: 3,
                //     _strike: 0,
                //     _width: int24(uint24(2 * (4 * i + 4)))
                // });
            }

            $posIdList.push(posId);

            vm.startPrank(Alice);
            mintOptions(
                pp,
                $posIdList,
                1_000_000,
                type(uint24).max,
                Constants.MIN_POOL_TICK,
                Constants.MAX_POOL_TICK,
                true
            );
        }

        vm.startPrank(Eve);

        token0.mint(Eve, type(uint104).max);
        token1.mint(Eve, type(uint104).max);
        token0.approve(address(ct0), type(uint104).max);
        token1.approve(address(ct1), type(uint104).max);

        accruePoolFeesInRange(
            manager,
            poolKey,
            StateLibrary.getLiquidity(manager, poolKey.toId()) - 1,
            10_000_000,
            20_000_000
        );

        editCollateral(ct0, Alice, 0);
        editCollateral(ct1, Alice, 0);

        uint256 gasBefore = gasleft();
        liquidate(pp, new TokenId[](0), Alice, $posIdList);
        console.log("Gas used: %d Liquidation", gasBefore - gasleft());
    }

    function test_gas_MaxPositions_long_soloLeg() public {
        uint256 positionCount = 32;

        for (uint256 i = 0; i < positionCount; i++) {
            {
                poolId =
                    uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                    uint64(uint256(vegoid) << 40);
                poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
            }
            TokenId posId = TokenId.wrap(0).addPoolId(poolId).addLeg({
                legIndex: 0,
                _optionRatio: 1,
                _asset: 1,
                _isLong: 0,
                _tokenType: 0,
                _riskPartner: 0,
                _strike: 0,
                _width: int24(uint24(2 * (i + 1)))
            });

            $setupIdList.push(posId);

            vm.startPrank(Bob);

            mintOptions(
                pp,
                $setupIdList,
                2_000_000,
                0,
                Constants.MIN_POOL_TICK,
                Constants.MAX_POOL_TICK,
                true
            );

            {
                poolId =
                    uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                    uint64(uint256(vegoid) << 40);
                poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
            }
            posId = TokenId.wrap(0).addPoolId(poolId).addLeg({
                legIndex: 0,
                _optionRatio: 1,
                _asset: 1,
                _isLong: 1,
                _tokenType: 0,
                _riskPartner: 0,
                _strike: 0,
                _width: int24(uint24(2 * (i + 1)))
            });

            if (i == 0) {
                {
                    poolId =
                        uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                        uint64(uint256(vegoid) << 40);
                    poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
                }
                posId = TokenId.wrap(0).addPoolId(poolId).addLeg({
                    legIndex: 0,
                    _optionRatio: 1,
                    _asset: 1,
                    _isLong: 0,
                    _tokenType: 0,
                    _riskPartner: 0,
                    _strike: 0,
                    _width: int24(uint24(2 * (i + 1)))
                });
            }

            $posIdList.push(posId);

            vm.startPrank(Alice);
            mintOptions(
                pp,
                $posIdList,
                1_000_000,
                type(uint24).max,
                Constants.MIN_POOL_TICK,
                Constants.MAX_POOL_TICK,
                true
            );
        }

        vm.startPrank(Eve);

        token0.mint(Eve, type(uint104).max);
        token1.mint(Eve, type(uint104).max);
        token0.approve(address(ct0), type(uint104).max);
        token1.approve(address(ct1), type(uint104).max);

        accruePoolFeesInRange(
            manager,
            poolKey,
            StateLibrary.getLiquidity(manager, poolKey.toId()) - 1,
            10_000_000,
            20_000_000
        );

        editCollateral(ct0, Alice, 0);
        editCollateral(ct1, Alice, 0);

        uint256 gasBefore = gasleft();
        liquidate(pp, new TokenId[](0), Alice, $posIdList);
        console.log("Gas used: %d Liquidation", gasBefore - gasleft());
    }

    function test_TickLimits_Initial(
        uint256 token0Supply,
        uint256 token1Supply,
        uint256 tickSpacingSeed
    ) public {
        sfpm = new SemiFungiblePositionManager(manager, 2100 * 10 ** 18, 2100 * 10 ** 18, 10_000);

        token0 = new ERC20S("token0", "T0", 18);
        token1 = new ERC20S("token1", "T1", 18);

        token0Supply = bound(token0Supply, 0, type(uint256).max / 10_000);
        token1Supply = bound(token1Supply, 0, type(uint256).max / 10_000);

        token0.editSupply(token0Supply);
        token1.editSupply(token1Supply);

        int24 tickSpacing = int24(uint24(bound(tickSpacingSeed, 1, 32767)));

        poolKey = PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            500,
            tickSpacing,
            IHooks(address(0))
        );

        manager.initialize(poolKey, 2 ** 96);

        sfpm.initializeAMMPool(poolKey, vegoid);

        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(routerV4), type(uint128).max);
        token1.approve(address(routerV4), type(uint128).max);

        vm.startPrank(Alice);
        token0.mint(Alice, uint256(type(uint104).max) * 2);
        token1.mint(Alice, uint256(type(uint104).max) * 2);
        token0.approve(address(routerV4), type(uint256).max);
        token1.approve(address(routerV4), type(uint256).max);
        routerV4.mintCurrency(address(0), Currency.wrap(address(token0)), type(uint104).max);
        routerV4.mintCurrency(address(0), Currency.wrap(address(token1)), type(uint104).max);
        manager.setOperator(address(sfpm), true);

        uint256 expectedDOSCost = Math.max(2100 * 10 ** 18, token0Supply);

        (int24 tickLimitLower, int24 tickLimitUpper) = sfpm.getEnforcedTickLimits(
            sfpm.getPoolId(abi.encode(poolKey.toId()), vegoid)
        );

        (uint256 maxDOSCost, ) = Math.getAmountsForLiquidity(
            -100_000,
            LiquidityChunkLibrary.createChunk(
                -tickSpacing,
                0,
                Math.getMaxLiquidityPerTick(tickSpacing)
            )
        );

        (uint256 actualDOSCost, ) = Math.getAmountsForLiquidity(
            -100_000,
            LiquidityChunkLibrary.createChunk(
                tickLimitUpper - tickSpacing + 2,
                tickLimitUpper + 2,
                Math.getMaxLiquidityPerTick(tickSpacing)
            )
        );

        assertLt(actualDOSCost, expectedDOSCost);

        (actualDOSCost, ) = Math.getAmountsForLiquidity(
            -100_000,
            LiquidityChunkLibrary.createChunk(
                tickLimitUpper - tickSpacing - 2,
                tickLimitUpper - 2,
                Math.getMaxLiquidityPerTick(tickSpacing)
            )
        );

        console2.log("maxDOSCost", maxDOSCost);
        console2.log("expectedDOSCost", expectedDOSCost);
        console2.log("tickLimitUpper", tickLimitUpper);
        console2.log("tickSpacing", tickSpacing);

        if (maxDOSCost <= expectedDOSCost) assertEq(tickLimitUpper, 1);
        else assertGt(actualDOSCost, expectedDOSCost);

        expectedDOSCost = Math.max(2100 * 10 ** 18, token1Supply);

        (, actualDOSCost) = Math.getAmountsForLiquidity(
            100_000,
            LiquidityChunkLibrary.createChunk(
                tickLimitLower - 2,
                tickLimitLower + tickSpacing - 2,
                Math.getMaxLiquidityPerTick(tickSpacing)
            )
        );

        assertLt(actualDOSCost, expectedDOSCost);

        (, actualDOSCost) = Math.getAmountsForLiquidity(
            100_000,
            LiquidityChunkLibrary.createChunk(
                tickLimitLower + 2,
                tickLimitLower + tickSpacing + 2,
                Math.getMaxLiquidityPerTick(tickSpacing)
            )
        );

        if (maxDOSCost <= expectedDOSCost) assertEq(tickLimitLower, -1);
        else assertGt(actualDOSCost, expectedDOSCost);

        vm.startPrank(Swapper);
        routerV4.modifyLiquidity(
            address(0),
            poolKey,
            (-887272 / tickSpacing) * tickSpacing,
            (887272 / tickSpacing) * tickSpacing,
            10 ** 18
        );

        routerV4.swapTo(address(0), poolKey, TickMath.getSqrtRatioAtTick(-100_000));

        vm.startPrank(Alice);

        TokenId tickPosition = TokenId
            .wrap(0)
            .addPoolId(sfpm.getPoolId(abi.encode(poolKey.toId()), vegoid))
            .addLeg(
                0,
                1,
                0,
                0,
                0,
                0,
                (tickLimitUpper / tickSpacing) *
                    tickSpacing +
                    int24(int256(Math.unsafeDivRoundingUp(uint24(tickSpacing), 2))),
                1
            );

        vm.expectRevert(Errors.InvalidTickBound.selector);
        sfpm.mintTokenizedPosition(
            abi.encode(poolKey),
            tickPosition,
            1_000_000,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK
        );

        tickPosition = TokenId
            .wrap(0)
            .addPoolId(sfpm.getPoolId(abi.encode(poolKey.toId()), vegoid))
            .addLeg(
                0,
                1,
                0,
                0,
                0,
                0,
                (tickLimitUpper / tickSpacing) *
                    tickSpacing -
                    int24(int256(Math.unsafeDivRoundingUp(uint24(tickSpacing), 2))),
                1
            );

        if (
            (tickLimitUpper / tickSpacing) *
                tickSpacing -
                (tickLimitLower / tickSpacing) *
                tickSpacing >=
            tickSpacing
        )
            sfpm.mintTokenizedPosition(
                abi.encode(poolKey),
                tickPosition,
                1_000_000,
                Constants.MIN_POOL_TICK,
                Constants.MAX_POOL_TICK
            );

        vm.startPrank(Swapper);

        routerV4.swapTo(address(0), poolKey, TickMath.getSqrtRatioAtTick(100_000));

        vm.startPrank(Alice);

        tickPosition = TokenId
            .wrap(0)
            .addPoolId(sfpm.getPoolId(abi.encode(poolKey.toId()), vegoid))
            .addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                (tickLimitLower / tickSpacing) *
                    tickSpacing -
                    int24(int256(Math.unsafeDivRoundingUp(uint24(tickSpacing), 2))),
                1
            );

        vm.expectRevert(Errors.InvalidTickBound.selector);
        sfpm.mintTokenizedPosition(
            abi.encode(poolKey),
            tickPosition,
            1_000_000,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK
        );

        tickPosition = TokenId
            .wrap(0)
            .addPoolId(sfpm.getPoolId(abi.encode(poolKey.toId()), vegoid))
            .addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                (tickLimitLower / tickSpacing) * tickSpacing + tickSpacing / 2,
                1
            );

        if (
            (tickLimitUpper / tickSpacing) *
                tickSpacing -
                (tickLimitLower / tickSpacing) *
                tickSpacing >=
            tickSpacing
        )
            sfpm.mintTokenizedPosition(
                abi.encode(poolKey),
                tickPosition,
                1_000_000,
                Constants.MIN_POOL_TICK,
                Constants.MAX_POOL_TICK
            );
    }

    function test_TickLimits_Expanded(
        uint256 token0SupplyOrig,
        uint256 token1SupplyOrig,
        uint256 token0Supply,
        uint256 token1Supply,
        uint256 tickSpacingSeed
    ) public {
        sfpm = new SemiFungiblePositionManager(manager, 2100 * 10 ** 18, 2100 * 10 ** 18, 10_000);

        token0 = new ERC20S("token0", "T0", 18);
        token1 = new ERC20S("token1", "T1", 18);

        token0SupplyOrig = bound(token0SupplyOrig, 0, type(uint256).max / 10_000);
        token1SupplyOrig = bound(token1SupplyOrig, 0, type(uint256).max / 10_000);

        token0.editSupply(token0SupplyOrig);
        token1.editSupply(token1SupplyOrig);

        int24 tickSpacing = int24(uint24(bound(tickSpacingSeed, 1, 32767)));

        poolKey = PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            500,
            tickSpacing,
            IHooks(address(0))
        );

        manager.initialize(poolKey, 2 ** 96);

        sfpm.initializeAMMPool(poolKey, vegoid);

        token0Supply = bound(token0Supply, 0, type(uint256).max / 10_000);
        token1Supply = bound(token1Supply, 0, type(uint256).max / 10_000);

        token0.editSupply(token0Supply);
        token1.editSupply(token1Supply);

        sfpm.expandEnforcedTickRange(sfpm.getPoolId(abi.encode(poolKey.toId()), vegoid));

        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(routerV4), type(uint128).max);
        token1.approve(address(routerV4), type(uint128).max);

        vm.startPrank(Alice);
        token0.mint(Alice, uint256(type(uint104).max) * 2);
        token1.mint(Alice, uint256(type(uint104).max) * 2);
        token0.approve(address(routerV4), type(uint256).max);
        token1.approve(address(routerV4), type(uint256).max);
        routerV4.mintCurrency(address(0), Currency.wrap(address(token0)), type(uint104).max);
        routerV4.mintCurrency(address(0), Currency.wrap(address(token1)), type(uint104).max);
        manager.setOperator(address(sfpm), true);

        uint256 expectedDOSCost = Math.max(
            2100 * 10 ** 18,
            Math.min(token0Supply, token0SupplyOrig)
        );

        (int24 tickLimitLower, int24 tickLimitUpper) = sfpm.getEnforcedTickLimits(
            sfpm.getPoolId(abi.encode(poolKey.toId()), vegoid)
        );

        (uint256 maxDOSCost, ) = Math.getAmountsForLiquidity(
            -100_000,
            LiquidityChunkLibrary.createChunk(
                -tickSpacing,
                0,
                Math.getMaxLiquidityPerTick(tickSpacing)
            )
        );

        (uint256 actualDOSCost, ) = Math.getAmountsForLiquidity(
            -100_000,
            LiquidityChunkLibrary.createChunk(
                tickLimitUpper - tickSpacing + 2,
                tickLimitUpper + 2,
                Math.getMaxLiquidityPerTick(tickSpacing)
            )
        );

        assertLt(actualDOSCost, expectedDOSCost);

        (actualDOSCost, ) = Math.getAmountsForLiquidity(
            -100_000,
            LiquidityChunkLibrary.createChunk(
                tickLimitUpper - tickSpacing - 2,
                tickLimitUpper - 2,
                Math.getMaxLiquidityPerTick(tickSpacing)
            )
        );

        if (maxDOSCost <= expectedDOSCost) assertEq(tickLimitUpper, 1);
        else assertGt(actualDOSCost, expectedDOSCost);

        expectedDOSCost = Math.max(2100 * 10 ** 18, Math.min(token1Supply, token1SupplyOrig));

        (, actualDOSCost) = Math.getAmountsForLiquidity(
            100_000,
            LiquidityChunkLibrary.createChunk(
                tickLimitLower - 2,
                tickLimitLower + tickSpacing - 2,
                Math.getMaxLiquidityPerTick(tickSpacing)
            )
        );

        assertLt(actualDOSCost, expectedDOSCost);

        (, actualDOSCost) = Math.getAmountsForLiquidity(
            100_000,
            LiquidityChunkLibrary.createChunk(
                tickLimitLower + 2,
                tickLimitLower + tickSpacing + 2,
                Math.getMaxLiquidityPerTick(tickSpacing)
            )
        );

        if (maxDOSCost <= expectedDOSCost) assertEq(tickLimitLower, -1);
        else assertGt(actualDOSCost, expectedDOSCost);

        vm.startPrank(Swapper);
        routerV4.modifyLiquidity(
            address(0),
            poolKey,
            (-887272 / tickSpacing) * tickSpacing,
            (887272 / tickSpacing) * tickSpacing,
            10 ** 18
        );

        routerV4.swapTo(address(0), poolKey, TickMath.getSqrtRatioAtTick(-100_000));

        vm.startPrank(Alice);

        TokenId tickPosition = TokenId
            .wrap(0)
            .addPoolId(sfpm.getPoolId(abi.encode(poolKey.toId()), vegoid))
            .addLeg(
                0,
                1,
                0,
                0,
                0,
                0,
                (tickLimitUpper / tickSpacing) *
                    tickSpacing +
                    int24(int256(Math.unsafeDivRoundingUp(uint24(tickSpacing), 2))),
                1
            );

        vm.expectRevert(Errors.InvalidTickBound.selector);
        sfpm.mintTokenizedPosition(
            abi.encode(poolKey),
            tickPosition,
            1_000_000,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK
        );

        tickPosition = TokenId
            .wrap(0)
            .addPoolId(sfpm.getPoolId(abi.encode(poolKey.toId()), vegoid))
            .addLeg(
                0,
                1,
                0,
                0,
                0,
                0,
                (tickLimitUpper / tickSpacing) *
                    tickSpacing -
                    int24(int256(Math.unsafeDivRoundingUp(uint24(tickSpacing), 2))),
                1
            );

        if (
            (tickLimitUpper / tickSpacing) *
                tickSpacing -
                (tickLimitLower / tickSpacing) *
                tickSpacing >=
            tickSpacing
        )
            sfpm.mintTokenizedPosition(
                abi.encode(poolKey),
                tickPosition,
                1_000_000,
                Constants.MIN_POOL_TICK,
                Constants.MAX_POOL_TICK
            );

        vm.startPrank(Swapper);

        routerV4.swapTo(address(0), poolKey, TickMath.getSqrtRatioAtTick(100_000));

        vm.startPrank(Alice);

        tickPosition = TokenId
            .wrap(0)
            .addPoolId(sfpm.getPoolId(abi.encode(poolKey.toId()), vegoid))
            .addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                (tickLimitLower / tickSpacing) *
                    tickSpacing -
                    int24(int256(Math.unsafeDivRoundingUp(uint24(tickSpacing), 2))),
                1
            );

        vm.expectRevert(Errors.InvalidTickBound.selector);
        sfpm.mintTokenizedPosition(
            abi.encode(poolKey),
            tickPosition,
            1_000_000,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK
        );

        tickPosition = TokenId
            .wrap(0)
            .addPoolId(sfpm.getPoolId(abi.encode(poolKey.toId()), vegoid))
            .addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                (tickLimitLower / tickSpacing) * tickSpacing + tickSpacing / 2,
                1
            );

        if (
            (tickLimitUpper / tickSpacing) *
                tickSpacing -
                (tickLimitLower / tickSpacing) *
                tickSpacing >=
            tickSpacing
        )
            sfpm.mintTokenizedPosition(
                abi.encode(poolKey),
                tickPosition,
                1_000_000,
                Constants.MIN_POOL_TICK,
                Constants.MAX_POOL_TICK
            );
    }

    function test_TickLimits_native(uint256 tickSpacingSeed) public {
        sfpm = new SemiFungiblePositionManager(manager, 2100 * 10 ** 18, 21_000 * 10 ** 18, 10_000);

        token0 = ERC20S(address(0));
        token1 = new ERC20S("token1", "T1", 18);

        int24 tickSpacing = int24(uint24(bound(tickSpacingSeed, 1, 32767)));

        poolKey = PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            500,
            tickSpacing,
            IHooks(address(0))
        );

        manager.initialize(poolKey, 2 ** 96);

        sfpm.initializeAMMPool(poolKey, vegoid);

        (, int24 tickLimitUpper) = sfpm.getEnforcedTickLimits(
            sfpm.getPoolId(abi.encode(poolKey.toId()), vegoid)
        );

        (uint256 actualDOSCost, ) = Math.getAmountsForLiquidity(
            -100_000,
            LiquidityChunkLibrary.createChunk(
                tickLimitUpper - tickSpacing + 2,
                tickLimitUpper + 2,
                Math.getMaxLiquidityPerTick(tickSpacing)
            )
        );

        assertLt(actualDOSCost, 21_000 * 10 ** 18);

        (actualDOSCost, ) = Math.getAmountsForLiquidity(
            -100_000,
            LiquidityChunkLibrary.createChunk(
                tickLimitUpper - tickSpacing - 2,
                tickLimitUpper - 2,
                Math.getMaxLiquidityPerTick(tickSpacing)
            )
        );

        assertGt(actualDOSCost, 21_000 * 10 ** 18);
    }

    function test_CollateralLogic_native(uint256 nativeSeed, uint256 liqNativeSeed) public {
        token0 = ERC20S(address(0));

        poolKey = PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            100,
            1,
            IHooks(address(0))
        );

        manager.initialize(poolKey, 2 ** 96);

        pp = PanopticPool(address(factory.deployNewPool(poolKey, re, uint96(block.timestamp))));

        ct0 = pp.collateralToken0();
        ct1 = pp.collateralToken1();

        nativeSeed = bound(nativeSeed, 100 ether, type(uint128).max);

        vm.deal(Alice, nativeSeed);

        vm.startPrank(Alice);

        ct0.deposit{value: nativeSeed}(100 ether, Alice);

        assertEq(ct0.convertToAssets(ct0.balanceOf(Alice)), 100 ether, "cta");
        assertEq(manager.balanceOf(address(pp), 0), 100 ether, "bal");
        assertEq(Alice.balance, nativeSeed - 100 ether, "eth bal");

        vm.deal(Alice, nativeSeed);

        ct0.mint{value: nativeSeed}(ct0.convertToShares(100 ether), Alice);

        assertEq(ct0.convertToAssets(ct0.balanceOf(Alice)), 200 ether, "cta2");
        assertEq(manager.balanceOf(address(pp), 0), 200 ether, "bal2");
        assertEq(Alice.balance, nativeSeed - 100 ether, "eth bal2");

        vm.deal(Alice, 0);

        ct0.withdraw(100 ether, Alice, Alice);

        assertEq(ct0.convertToAssets(ct0.balanceOf(Alice)), 100 ether, "cta3");
        assertEq(manager.balanceOf(address(pp), 0), 100 ether, "bal3");
        assertEq(Alice.balance, 100 ether, "eth bal3");

        ct0.redeem(ct0.balanceOf(Alice), Alice, Alice);

        assertEq(ct0.balanceOf(Alice), 0, "bal4");
        assertEq(manager.balanceOf(address(pp), 0), 0, "man bal");
        assertEq(Alice.balance, 200 ether, "ali bal");

        vm.deal(Alice, 100 ether);

        console2.log("deposit Alice");
        ct0.deposit{value: 100 ether}(100 ether, Alice);

        token1.mint(Alice, 100 ether);

        token1.approve(address(ct1), type(uint104).max);

        ct1.deposit(100 ether, Alice);

        vm.startPrank(Bob);

        token1.mint(Bob, 3.1 ether);
        token1.approve(address(ct1), type(uint104).max);

        ct1.deposit(3.1 ether, Bob);

        $posIdList.push(
            TokenId.wrap(0).addPoolId(sfpm.getPoolId(abi.encode(poolKey.toId()), vegoid)).addLeg(
                0,
                1,
                0,
                0,
                0,
                0,
                -10,
                1
            )
        );

        mintOptions(
            pp,
            $posIdList,
            3 ether,
            0,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );
        console2.log("BOB");

        editCollateral(ct0, Bob, 0);
        console2.log("BOB");

        uint256 balancePrev = ct0.convertToAssets(ct0.balanceOf(Alice));

        vm.startPrank(Charlie);

        liqNativeSeed = bound(liqNativeSeed, 3 ether, type(uint128).max);

        vm.deal(Charlie, liqNativeSeed);
        console2.log("char", Charlie.balance);

        // liquidate
        pp.dispatchFrom{value: Charlie.balance}(
            new TokenId[](0),
            Bob,
            $posIdList,
            new TokenId[](0),
            LeftRightUnsigned.wrap(0).addToRightSlot(1).addToLeftSlot(1)
        );

        // TODO: where is that `1` from?
        assertEq(Charlie.balance, liqNativeSeed - 3 ether + 1, "cb");

        assertEq(ct0.convertToAssets(ct0.balanceOf(Bob)), 0);

        assertEq(ct0.convertToAssets(ct0.balanceOf(Alice)), balancePrev);

        assertEq(manager.balanceOf(address(pp), 0), 103 ether - 1, "man bal");
    }

    // Test that risk-partnered positions can be minted/burned succesfully
    function test_success_MintBurnStraddle() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);
        routerV4.modifyLiquidity(address(0), poolKey, -10000, 10000, 10 ** 24);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 1, 15, 1).addLeg(
                1,
                1,
                1,
                0,
                1,
                0,
                15,
                1
            )
        );

        vm.startPrank(Bob);

        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        burnOptions(
            pp,
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    function test_success_MintBurnStrangle() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 1, 15, 1).addLeg(
                1,
                1,
                1,
                0,
                1,
                0,
                -15,
                1
            )
        );

        vm.startPrank(Bob);

        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        burnOptions(
            pp,
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    function test_fail_mint0liquidity_SFPM() public {
        vm.startPrank(Seller);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, -224040, 3540));

        vm.expectRevert(Errors.ChunkHasZeroLiquidity.selector);
        mintOptions(pp, $posIdList, 537, 0, Constants.MIN_POOL_TICK, Constants.MAX_POOL_TICK, true);

        mintOptions(
            pp,
            $posIdList,
            2_000_000,
            0,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        vm.startPrank(Alice);
        $posIdList[0] = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 1, 0, 0, -224040, 3540);

        vm.expectRevert(Errors.ChunkHasZeroLiquidity.selector);
        mintOptions(pp, $posIdList, 537, 0, Constants.MIN_POOL_TICK, Constants.MAX_POOL_TICK, true);
    }

    function test_success_MintBurnCallSpread() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        vm.startPrank(Seller);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 35, 1));

        mintOptions(
            pp,
            $posIdList,
            2_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // mint OTM position
        $posIdList[0] = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 1, 15, 1).addLeg(
            1,
            1,
            1,
            1,
            0,
            0,
            35,
            1
        );

        vm.startPrank(Bob);

        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            type(uint24).max,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        burnOptions(
            pp,
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    function test_success_MintBurnPutSpread() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        vm.startPrank(Seller);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 1, 0, -35, 1));

        mintOptions(
            pp,
            $posIdList,
            2_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        // mint OTM position
        $posIdList[0] = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 1, 1, -15, 1).addLeg(
            1,
            1,
            1,
            1,
            1,
            0,
            -35,
            1
        );

        vm.startPrank(Bob);

        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            type(uint24).max,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        burnOptions(
            pp,
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    // are delegations for ITM positions sufficient?
    function test_success_exercise_crossDelegate_1() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 1));

        vm.startPrank(Seller);

        mintOptions(
            pp,
            $posIdList,
            2_000_000,
            0,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        $posIdList[0] = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 0, 0, 15, 1);
        console2.log("poolId", poolId);
        vm.startPrank(Alice);
        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            type(uint24).max,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        editCollateral(ct1, Alice, 0);

        vm.startPrank(Swapper);

        PanopticMath.twapFilter(uniPool, 600);

        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(512));

        pp.pokeOracle();
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);

        swapperc.mint(uniPool, -10, 10, 10 ** 18);
        swapperc.burn(uniPool, -10, 10, 10 ** 18);

        (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, oraclePack) = pp
            .getOracleTicks();
        twapTick = re.twapEMA(oraclePack);
        console2.log("cur", currentTick);
        console2.log("twapTick", twapTick);
        vm.assume(Math.abs(currentTick - twapTick) < 513);

        vm.startPrank(Bob);
        forceExercise(
            pp,
            Alice,
            $posIdList[0],
            new TokenId[](0),
            new TokenId[](0),
            LeftRightUnsigned.wrap(0).addToLeftSlot(0)
        );
    }

    function test_success_ExerciseSettle_ComputeLongPremium() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 1, 0, -35, 1));

        vm.startPrank(Seller);
        mintOptions(
            pp,
            $posIdList,
            4_000_000,
            0,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        $posIdLists[0].push($posIdList[0]);
        vm.startPrank(Alice);
        mintOptions(
            pp,
            $posIdLists[0],
            2_000_000,
            0,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        vm.startPrank(Bob);
        mintOptions(
            pp,
            $posIdList,
            2_000_000,
            0,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        vm.startPrank(Swapper);

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-35));
        routerV4.swapTo(address(0), poolKey, TickMath.getSqrtRatioAtTick(-35));

        console2.log(
            "StateLibrary.getLiquidity(manager, poolKey.toId()) - 1",
            StateLibrary.getLiquidity(manager, poolKey.toId()) - 1
        );
        accruePoolFeesInRange(
            manager,
            poolKey,
            StateLibrary.getLiquidity(manager, poolKey.toId()) - 1,
            1_000_000,
            1_000_000_000
        );

        swapperc.swapTo(uniPool, 2 ** 96);
        routerV4.swapTo(address(0), poolKey, 2 ** 96);

        editCollateral(ct0, Alice, ct0.convertToShares(30000));
        editCollateral(ct1, Alice, ct1.convertToShares(30000));

        editCollateral(ct0, Bob, ct0.convertToShares(20000));
        editCollateral(ct1, Bob, ct1.convertToShares(20000));
        vm.startPrank(Bob);

        console2.log("share0", ct0.convertToShares(20000));
        console2.log("share1", ct1.convertToShares(20000));
        $tempIdList = $posIdList;

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 1, 0, -35, 1));

        console2.log("");
        console2.log("MINT");
        mintOptions(
            pp,
            $posIdList,
            2_000_000,
            type(uint24).max,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        vm.startPrank(Alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.AccountInsolvent.selector,
                uint256(0), // solvent
                uint256(1) // numberOfTicks
            )
        );
        settlePremium(pp, $posIdLists[0], $posIdList, Bob, 0, false);

        uint256 snap = vm.snapshotState();
        settlePremium(pp, $posIdLists[0], $posIdList, Bob, 0, true);

        vm.revertToState(snap);
        console2.log("here?");

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.AccountInsolvent.selector,
                uint256(0), // solvent
                uint256(1) // numberOfTicks
            )
        );
        forceExercise(
            pp,
            Bob,
            $posIdList[1],
            $tempIdList,
            $tempIdList,
            LeftRightUnsigned.wrap(0).addToLeftSlot(0)
        );

        console2.log("there?");
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.AccountInsolvent.selector,
                uint256(0), // solvent
                uint256(1) // numberOfTicks
            )
        );
        forceExercise(
            pp,
            Bob,
            $posIdList[1],
            $tempIdList,
            $tempIdList,
            LeftRightUnsigned.wrap(0).addToLeftSlot(1)
        );
        console2.log("there2?");

        vm.expectRevert(
            abi.encodeWithSelector(Errors.AccountInsolvent.selector, uint256(0), uint256(1))
        );
        forceExercise(
            pp,
            Bob,
            $posIdList[1],
            $tempIdList,
            $tempIdList,
            LeftRightUnsigned.wrap(1).addToLeftSlot(0)
        );

        snap = vm.snapshotState();
        burnOptions(
            pp,
            $posIdList[0],
            new TokenId[](0),
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );
        console2.log("there3?");

        vm.expectRevert(
            abi.encodeWithSelector(Errors.AccountInsolvent.selector, uint256(0), uint256(1))
        );
        forceExercise(
            pp,
            Bob,
            $posIdList[1],
            $tempIdList,
            new TokenId[](0),
            LeftRightUnsigned.wrap(0).addToLeftSlot(0)
        );

        vm.expectRevert(
            abi.encodeWithSelector(Errors.AccountInsolvent.selector, uint256(0), uint256(1))
        );
        forceExercise(
            pp,
            Bob,
            $posIdList[1],
            $tempIdList,
            new TokenId[](0),
            LeftRightUnsigned.wrap(0).addToLeftSlot(1)
        );

        uint256 snap2 = vm.snapshotState();

        forceExercise(
            pp,
            Bob,
            $posIdList[1],
            $tempIdList,
            new TokenId[](0),
            LeftRightUnsigned.wrap(1).addToLeftSlot(0)
        );

        vm.revertToState(snap2);

        forceExercise(
            pp,
            Bob,
            $posIdList[1],
            $tempIdList,
            new TokenId[](0),
            LeftRightUnsigned.wrap(1).addToLeftSlot(1)
        );

        vm.revertToState(snap);

        $setupIdList.push($posIdList[1]);

        vm.startPrank(Bob);
        burnOptions(
            pp,
            $posIdList[0],
            $setupIdList,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        vm.startPrank(Alice);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.AccountInsolvent.selector, uint256(0), uint256(1))
        );
        forceExercise(
            pp,
            Bob,
            $posIdList[1],
            new TokenId[](0),
            $tempIdList,
            LeftRightUnsigned.wrap(0).addToLeftSlot(0)
        );

        vm.expectRevert(
            abi.encodeWithSelector(Errors.AccountInsolvent.selector, uint256(0), uint256(1))
        );
        forceExercise(
            pp,
            Bob,
            $posIdList[1],
            new TokenId[](0),
            $tempIdList,
            LeftRightUnsigned.wrap(1).addToLeftSlot(0)
        );

        snap2 = vm.snapshotState();

        forceExercise(
            pp,
            Bob,
            $posIdList[1],
            new TokenId[](0),
            $tempIdList,
            LeftRightUnsigned.wrap(0).addToLeftSlot(1)
        );

        vm.revertToState(snap2);

        snap2 = vm.snapshotState();

        forceExercise(
            pp,
            Bob,
            $posIdList[1],
            new TokenId[](0),
            $tempIdList,
            LeftRightUnsigned.wrap(1).addToLeftSlot(1)
        );

        vm.revertToState(snap2);

        burnOptions(
            pp,
            $posIdList[0],
            new TokenId[](0),
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        snap2 = vm.snapshotState();
        forceExercise(
            pp,
            Bob,
            $posIdList[1],
            new TokenId[](0),
            new TokenId[](0),
            LeftRightUnsigned.wrap(0).addToLeftSlot(0)
        );

        vm.revertToState(snap2);

        snap2 = vm.snapshotState();

        forceExercise(
            pp,
            Bob,
            $posIdList[1],
            new TokenId[](0),
            new TokenId[](0),
            LeftRightUnsigned.wrap(0).addToLeftSlot(1)
        );

        vm.revertToState(snap2);

        snap2 = vm.snapshotState();
        forceExercise(
            pp,
            Bob,
            $posIdList[1],
            new TokenId[](0),
            new TokenId[](0),
            LeftRightUnsigned.wrap(1).addToLeftSlot(0)
        );

        vm.revertToState(snap2);

        snap2 = vm.snapshotState();

        forceExercise(
            pp,
            Bob,
            $posIdList[1],
            new TokenId[](0),
            new TokenId[](0),
            LeftRightUnsigned.wrap(1).addToLeftSlot(1)
        );
    }

    // are delegations for ITM positions sufficient?
    function test_success_exercise_crossDelegate() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 1));

        vm.startPrank(Seller);

        mintOptions(
            pp,
            $posIdList,
            2_000_000,
            0,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        $posIdList[0] = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 0, 0, 15, 1);

        vm.startPrank(Alice);
        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            type(uint24).max,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        editCollateral(ct1, Alice, 0);

        vm.startPrank(Swapper);

        twapTick = PanopticMath.twapFilter(uniPool, 600);

        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(512));
        routerV4.swapTo(address(0), poolKey, TickMath.getSqrtRatioAtTick(512));

        pp.pokeOracle();
        vm.warp(block.timestamp + 600);
        vm.roll(block.number + 1);

        swapperc.mint(uniPool, -10, 10, 10 ** 18);
        swapperc.burn(uniPool, -10, 10, 10 ** 18);

        (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, oraclePack) = pp
            .getOracleTicks();
        currentTick = sfpm.getCurrentTick(abi.encode(poolKey));

        twapTick = re.twapEMA(oraclePack);
        console2.log("cur", currentTick);
        console2.log("twapTick", twapTick);
        vm.assume(Math.abs(currentTick - twapTick) < 513);

        vm.startPrank(Bob);
        forceExercise(
            pp,
            Alice,
            $posIdList[0],
            new TokenId[](0),
            new TokenId[](0),
            LeftRightUnsigned.wrap(1).addToLeftSlot(1)
        );
    }

    function test_parity_maxmint_previewmint() public view {
        assertEq(ct0.previewMint(ct0.maxMint(Alice)), type(uint104).max);
    }

    function test_fail_buyAllLiquidity() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // mint OTM position
        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 1));

        $tempIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 0, 0, 15, 1));

        vm.startPrank(Alice);
        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.startPrank(Bob);

        vm.expectRevert(Errors.NetLiquidityZero.selector);
        mintOptions(
            pp,
            $tempIdList,
            1_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    // position length in hash should fail instead of overflowing its slot during construction
    function test_fail_validate_longpositionlist() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // mint OTM position
        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 1));

        vm.startPrank(Alice);
        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        TokenId[] memory longPositionList = new TokenId[](256);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        for (uint256 i; i < 256; ++i) {
            TokenId tempTokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                int24(int256(10 * i)),
                2
            );

            longPositionList[i] = tempTokenId;
        }

        vm.expectRevert(stdError.arithmeticError);
        mintOptions(
            pp,
            longPositionList,
            1_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    // ensure all large mint/deposit amounts revert (instead of overflowing)
    function test_fail_mintmax() public {
        vm.startPrank(Eve);
        token0.mint(Eve, type(uint256).max / 10);
        token1.mint(Eve, type(uint256).max / 10);
        token0.approve(address(ct0), type(uint256).max / 10);
        token1.approve(address(ct0), type(uint256).max / 10);

        vm.expectRevert();
        ct0.mint(type(uint256).max / 10_000 + 1, Eve);

        for (uint256 i = 160; i < 256; ++i) {
            vm.expectRevert();
            ct0.mint(2 ** i - 1, Eve);
        }
    }

    function test_fail_depositmax() public {
        vm.startPrank(Eve);
        token0.mint(Eve, type(uint256).max / 10);
        token1.mint(Eve, type(uint256).max / 10);
        token0.approve(address(ct0), type(uint256).max / 10);
        token1.approve(address(ct0), type(uint256).max / 10);

        vm.expectRevert();
        ct0.deposit(type(uint256).max / 10_000 + 1, Eve);

        for (uint256 i = 105; i < 256; ++i) {
            vm.expectRevert();
            ct0.deposit(2 ** i - 1, Eve);
        }
    }

    // total owed/grossPremiumLast should not change when positions with 0 premia are minted/burnt
    function test_settledtracking_premia0() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // mint OTM position
        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 1));

        $tempIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 1));

        $tempIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 0, 0, 15, 1));

        assetsBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        assetsBefore1 = ct1.convertToAssets(ct1.balanceOf(Alice));

        vm.startPrank(Alice);
        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.startPrank(Bob);
        mintOptions(
            pp,
            $posIdList,
            1_000_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        mintOptions(
            pp,
            $tempIdList,
            900_000_000,
            type(uint24).max,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.startPrank(Swapper);
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(10) + 1);
        routerV4.swapTo(address(0), poolKey, TickMath.getSqrtRatioAtTick(10) + 1);

        accruePoolFeesInRange(
            manager,
            poolKey,
            StateLibrary.getLiquidity(manager, poolKey.toId()) - 1,
            1_000_000_000_000_000_000_000,
            1_000_000_000_000
        );

        swapperc.swapTo(uniPool, 2 ** 96);
        routerV4.swapTo(address(0), poolKey, 2 ** 96);

        uint256 snap = vm.snapshot();
        vm.startPrank(Charlie);

        for (uint256 i = 0; i < 10; i++) {
            mintOptions(
                pp,
                $posIdList,
                250_000_000,
                type(uint24).max,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            burnOptions(
                pp,
                $posIdList[0],
                new TokenId[](0),
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );
        }

        vm.startPrank(Alice);
        burnOptions(
            pp,
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        uint256 delta0 = ct0.convertToAssets(ct0.balanceOf(Alice)) - assetsBefore0;
        uint256 delta1 = ct1.convertToAssets(ct1.balanceOf(Alice)) - assetsBefore1;
        vm.revertTo(snap);

        vm.startPrank(Alice);
        burnOptions(
            pp,
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        // there is a small amount of error in token0 -- this is the commissions from Charlie
        assertApproxEqAbs(
            delta0,
            ct0.convertToAssets(ct0.balanceOf(Alice)) - assetsBefore0,
            3_000_000
        );
        assertEq(delta1, ct1.convertToAssets(ct1.balanceOf(Alice)) - assetsBefore1);
    }

    // these tests are PoCs for rounding issues in the premium distribution
    // to demonstrate the issue log the settled, gross, and owed premia at burn
    function test_settledPremiumDistribution_demoInflatedGross() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // mint OTM position
        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 1));

        $tempIdList = $posIdList;

        vm.startPrank(Bob);

        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 0, 0, 15, 1));

        // the collectedAmount will always be a round number, so it's actually not possible to get a greater grossPremium than sum(collected, owed)
        // (owed and gross are both calculated from collectedAmount)
        for (uint256 i = 0; i < 1000; i++) {
            vm.startPrank(Alice);
            $tempIdList[0] = $posIdList[1];
            mintOptions(
                pp,
                $tempIdList,
                250_000,
                type(uint24).max,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            vm.startPrank(Bob);
            mintOptions(
                pp,
                $posIdList,
                250_000,
                type(uint24).max,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            vm.startPrank(Swapper);
            swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(10) + 1);
            routerV4.swapTo(address(0), poolKey, TickMath.getSqrtRatioAtTick(10) + 1);
            // 1998600539
            accruePoolFeesInRange(
                manager,
                poolKey,
                (StateLibrary.getLiquidity(manager, poolKey.toId()) * 2) / 3,
                1,
                1
            );
            swapperc.swapTo(uniPool, 2 ** 96);
            routerV4.swapTo(address(0), poolKey, 2 ** 96);

            vm.startPrank(Bob);
            $tempIdList[0] = $posIdList[0];
            burnOptions(
                pp,
                $posIdList[1],
                $tempIdList,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            vm.startPrank(Alice);
            burnOptions(
                pp,
                $posIdList[1],
                new TokenId[](0),
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );
        }

        vm.startPrank(Bob);
        // burn Bob's short option
        burnOptions(
            pp,
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    function test_settledPremiumDistribution_demoInflatedOwed() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // mint OTM position
        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 1));

        $tempIdList = $posIdList;

        vm.startPrank(Bob);

        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 0, 0, 15, 1));

        // only 20 tokens actually settled, but 22 owed... 2 tokens taken from PLPs
        // we may need to redefine availablePremium as max(availablePremium, settledTokens)
        for (uint256 i = 0; i < 10; i++) {
            mintOptions(
                pp,
                $posIdList,
                499_999,
                type(uint24).max,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );
            vm.startPrank(Swapper);
            swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(10) + 1);
            routerV4.swapTo(address(0), poolKey, TickMath.getSqrtRatioAtTick(10) + 1);
            // 1998600539
            accruePoolFeesInRange(
                manager,
                poolKey,
                StateLibrary.getLiquidity(manager, poolKey.toId()) - 1,
                1,
                1
            );
            swapperc.swapTo(uniPool, 2 ** 96);
            routerV4.swapTo(address(0), poolKey, 2 ** 96);
            vm.startPrank(Bob);
            burnOptions(
                pp,
                $posIdList[1],
                $tempIdList,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );
        }

        // burn Bob's short option
        burnOptions(
            pp,
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    function test_success_settleShortPremium_self() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // sell primary chunk
        $posIdLists[0].push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 1));

        routerV4.modifyLiquidity(address(0), poolKey, -10000, 10000, 10 ** 18);

        // mint some amount of liquidity with Alice owning 1/2 and Bob and Charlie owning 1/4 respectively
        // then, remove 9.737% of that liquidity at the same ratio
        // Once this state is in place, accumulate some amount of fees on the existing liquidity in the pool
        // The fees should be immediately available for withdrawal because they have been paid to liquidity already in the pool
        // 8.896% * 1.022x vegoid = +~10% of the fee amount accumulated will be owed by sellers
        vm.startPrank(Alice);

        mintOptions(
            pp,
            $posIdLists[0],
            1_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.startPrank(Bob);

        mintOptions(
            pp,
            $posIdLists[0],
            499_999_500,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.startPrank(Charlie);

        mintOptions(
            pp,
            $posIdLists[0],
            499_999_500,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // position type A: 1-leg long primary
        $posIdLists[2].push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 0, 0, 15, 1));

        // Buyer 1 buys the chunk
        vm.startPrank(Buyers[0]);
        mintOptions(
            pp,
            $posIdLists[2],
            9_884_444,
            type(uint24).max,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.startPrank(Swapper);

        routerV4.swapTo(address(0), poolKey, TickMath.getSqrtRatioAtTick(100) + 1);

        // There are some precision issues with this (1B is not exactly 1B) but close enough to see the effects
        accruePoolFeesInRange(
            manager,
            poolKey,
            StateLibrary.getLiquidity(manager, poolKey.toId()) - 1,
            1_000_000,
            1_000_000_000
        );

        // accumulate lower order of fees on dummy chunk
        routerV4.swapTo(address(0), poolKey, TickMath.getSqrtRatioAtTick(-100));

        accruePoolFeesInRange(
            manager,
            poolKey,
            StateLibrary.getLiquidity(manager, poolKey.toId()) - 1,
            10_000,
            100_000
        );

        swapperc.swapTo(uniPool, 2 ** 96);
        routerV4.swapTo(address(0), poolKey, 2 ** 96);

        vm.startPrank(Alice);
        {
            (LeftRightUnsigned shortPremium, , ) = pp.getAccumulatedFeesAndPositionsData(
                Alice,
                true,
                $posIdLists[0]
            );

            assertGe(shortPremium.rightSlot(), 0);
            assertGe(shortPremium.leftSlot(), 0);

            (uint256 aliceBalanceBefore0, uint256 aliceBalanceBefore1) = (
                ct0.balanceOf(Alice),
                ct1.balanceOf(Alice)
            );

            // Alice settles her own position, received nothing because the chunks haven't been poked.
            settlePremiumSelf(pp, $posIdLists[0], 1_000, true);
            (uint256 aliceBalanceAfter0, uint256 aliceBalanceAfter1) = (
                ct0.balanceOf(Alice),
                ct1.balanceOf(Alice)
            );

            (shortPremium, , ) = pp.getAccumulatedFeesAndPositionsData(Alice, true, $posIdLists[0]);

            // has 0 owed premium because it was settled at 0 in settlePremium
            assertEq(shortPremium.rightSlot(), 0);
            assertEq(shortPremium.leftSlot(), 0);

            // burn options and forfeit her premium, which was settled as 0 in settlePremium
            burnOptions(
                pp,
                $posIdLists[0],
                new TokenId[](0),
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                false
            );

            (uint256 aliceBalancePost0, uint256 aliceBalancePost1) = (
                ct0.balanceOf(Alice),
                ct1.balanceOf(Alice)
            );

            // Alice re-mints an option, pokes the chunk and make the protocol collect some premium
            mintOptions(
                pp,
                $posIdLists[0],
                1,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );
        }

        uint256 bobDeltaPremia0;
        uint256 bobDeltaPremia1;

        uint256 snap = vm.snapshotState();

        {
            vm.startPrank(Bob);

            (LeftRightUnsigned shortPremium, , ) = pp.getAccumulatedFeesAndPositionsData(
                Bob,
                true,
                $posIdLists[0]
            );
            uint256 owedPremia0 = shortPremium.rightSlot();
            uint256 owedPremia1 = shortPremium.leftSlot();
            console2.log("owedPremia-total0", owedPremia0);
            console2.log("owedPremia-total1", owedPremia1);

            assertGe(owedPremia0, 0);
            assertGe(owedPremia1, 0);

            (uint256 bobBalanceBefore0, uint256 bobBalanceBefore1) = (
                ct0.balanceOf(Bob),
                ct1.balanceOf(Bob)
            );

            // Bob settles his own premium, receives only realize premia and misses out on unsettled longs
            settlePremiumSelf(pp, $posIdLists[0], 499_999_500, true);
            (uint256 bobBalanceAfter0, uint256 bobBalanceAfter1) = (
                ct0.balanceOf(Bob),
                ct1.balanceOf(Bob)
            );

            assertGt(bobBalanceAfter0, bobBalanceBefore0, "bob received premia0");
            assertGt(bobBalanceAfter1, bobBalanceBefore1, "bob received premia1");

            bobDeltaPremia0 = ct0.convertToAssets(bobBalanceAfter0 - bobBalanceBefore0);
            bobDeltaPremia1 = ct1.convertToAssets(bobBalanceAfter1 - bobBalanceBefore1);

            console2.log("bobDeltaPremia0", bobDeltaPremia0);
            console2.log("bobDeltaPremia1", bobDeltaPremia1);
            assertLt(
                bobDeltaPremia0,
                owedPremia0,
                "bob received less than owed due to unsettled token0"
            );
            assertLt(
                bobDeltaPremia1,
                owedPremia1,
                "bob received less than owed due to unsettled token0"
            );
        }

        vm.revertToState(snap);

        vm.startPrank(Charlie);

        uint256 charlieDeltaPremia0;
        uint256 charlieDeltaPremia1;

        {
            (LeftRightUnsigned shortPremium, , ) = pp.getAccumulatedFeesAndPositionsData(
                Charlie,
                true,
                $posIdLists[0]
            );
            uint256 owedPremia0 = shortPremium.rightSlot();
            uint256 owedPremia1 = shortPremium.leftSlot();
            console2.log("owedPremia-total0", owedPremia0);
            console2.log("owedPremia-total1", owedPremia1);

            assertGe(owedPremia0, 0);
            assertGe(owedPremia1, 0);

            (uint256 charlieBalanceBefore0, uint256 charlieBalanceBefore1) = (
                ct0.balanceOf(Charlie),
                ct1.balanceOf(Charlie)
            );

            // Charlie settles Buyers[0] premium first
            settlePremium(pp, $posIdLists[0], $posIdLists[2], Buyers[0], 0, true);

            // Charlie settles his own premium, receives only realize premia from settled longs
            settlePremiumSelf(pp, $posIdLists[0], 499_999_500, true);

            (uint256 charlieBalanceAfter0, uint256 charlieBalanceAfter1) = (
                ct0.balanceOf(Charlie),
                ct1.balanceOf(Charlie)
            );

            assertGt(charlieBalanceAfter0, charlieBalanceBefore0, "charlie received premia0");
            assertGt(charlieBalanceAfter1, charlieBalanceBefore1, "charlie received premia1");

            charlieDeltaPremia0 = ct0.convertToAssets(charlieBalanceAfter0 - charlieBalanceBefore0);
            charlieDeltaPremia1 = ct1.convertToAssets(charlieBalanceAfter1 - charlieBalanceBefore1);

            assertApproxEqAbs(
                charlieDeltaPremia0,
                owedPremia0,
                1,
                "charlie received exactly what they are owed due to settled token0"
            );
            assertApproxEqAbs(
                charlieDeltaPremia1,
                owedPremia1,
                1,
                "charlie received exactly what they are owed due to settled token0"
            );
        }
    }

    function test_success_settleLongPremium_self() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // sell primary chunk
        $posIdLists[0].push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 1));

        routerV4.modifyLiquidity(address(0), poolKey, -10000, 10000, 10 ** 18);

        // mint some amount of liquidity with Alice owning 1/2 and Bob and Charlie owning 1/4 respectively
        // then, remove 9.737% of that liquidity at the same ratio
        // Once this state is in place, accumulate some amount of fees on the existing liquidity in the pool
        // The fees should be immediately available for withdrawal because they have been paid to liquidity already in the pool
        // 8.896% * 1.022x vegoid = +~10% of the fee amount accumulated will be owed by sellers
        vm.startPrank(Alice);

        console2.log("");
        console2.log("Alice MINT");
        mintOptions(
            pp,
            $posIdLists[0],
            2_000_000_000,
            0,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        // position type A: 1-leg long primary
        $posIdLists[2].push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 0, 0, 15, 1));

        vm.startPrank(Bob);
        console2.log("");
        console2.log("Bob MINT");

        mintOptions(
            pp,
            $posIdLists[2],
            250_000_000,
            type(uint24).max,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        vm.startPrank(Charlie);

        console2.log("");
        console2.log("Charlie MINT");
        mintOptions(
            pp,
            $posIdLists[2],
            250_000_000,
            type(uint24).max,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );
        vm.startPrank(Swapper);

        routerV4.swapTo(address(0), poolKey, TickMath.getSqrtRatioAtTick(100) + 1);

        // There are some precision issues with this (1B is not exactly 1B) but close enough to see the effects
        accruePoolFeesInRange(
            manager,
            poolKey,
            StateLibrary.getLiquidity(manager, poolKey.toId()) - 1,
            1_000_000,
            1_000_000_000
        );

        // accumulate lower order of fees on dummy chunk
        routerV4.swapTo(address(0), poolKey, TickMath.getSqrtRatioAtTick(-100));

        accruePoolFeesInRange(
            manager,
            poolKey,
            StateLibrary.getLiquidity(manager, poolKey.toId()) - 1,
            10_000,
            100_000
        );

        swapperc.swapTo(uniPool, 2 ** 96);
        routerV4.swapTo(address(0), poolKey, 2 ** 96);

        vm.startPrank(Bob);

        console2.log("");
        console2.log("Bob SETTLE");
        settlePremiumSelf(pp, $posIdLists[2], 250_000_000, true);

        vm.startPrank(Charlie);
        console2.log("");
        console2.log("Charlie SETTLE");
        settlePremiumSelf(pp, $posIdLists[2], 250_000_000, true);

        vm.startPrank(Alice);

        (LeftRightUnsigned shortPremium, , ) = pp.getAccumulatedFeesAndPositionsData(
            Alice,
            true,
            $posIdLists[0]
        );

        console2.log("");
        console2.log("Alice SETTLE");
        settlePremiumSelf(pp, $posIdLists[0], 2_000_000_000, true);

        vm.startPrank(Bob);
        console2.log("");
        console2.log("Bob BURN");

        burnOptions(
            pp,
            $posIdLists[2],
            new TokenId[](0),
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );
        vm.startPrank(Charlie);

        console2.log("");
        console2.log("Charlie BURN");
        burnOptions(
            pp,
            $posIdLists[2],
            new TokenId[](0),
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        vm.startPrank(Alice);

        console2.log("");
        console2.log("Alice BURN");

        burnOptions(
            pp,
            $posIdLists[0],
            new TokenId[](0),
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );
    }

    function test_success_settleShortPremium_dispatchFrom() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // sell primary chunk
        $posIdLists[0].push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 1));

        routerV4.modifyLiquidity(address(0), poolKey, -10000, 10000, 10 ** 18);

        // mint some amount of liquidity with Alice owning 1/2 and Bob and Charlie owning 1/4 respectively
        // then, remove 9.737% of that liquidity at the same ratio
        // Once this state is in place, accumulate some amount of fees on the existing liquidity in the pool
        // The fees should be immediately available for withdrawal because they have been paid to liquidity already in the pool
        // 8.896% * 1.022x vegoid = +~10% of the fee amount accumulated will be owed by sellers
        vm.startPrank(Alice);

        mintOptions(
            pp,
            $posIdLists[0],
            1_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.startPrank(Bob);

        mintOptions(
            pp,
            $posIdLists[0],
            499_999_500,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.startPrank(Charlie);

        mintOptions(
            pp,
            $posIdLists[0],
            499_999_500,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // position type A: 1-leg long primary
        $posIdLists[2].push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 0, 0, 15, 1));

        // Buyer 1 buys the chunk
        vm.startPrank(Buyers[0]);
        mintOptions(
            pp,
            $posIdLists[2],
            9_884_444,
            type(uint24).max,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.startPrank(Swapper);

        routerV4.swapTo(address(0), poolKey, TickMath.getSqrtRatioAtTick(100) + 1);

        // There are some precision issues with this (1B is not exactly 1B) but close enough to see the effects
        accruePoolFeesInRange(
            manager,
            poolKey,
            StateLibrary.getLiquidity(manager, poolKey.toId()) - 1,
            1_000_000,
            1_000_000_000
        );

        // accumulate lower order of fees on dummy chunk
        routerV4.swapTo(address(0), poolKey, TickMath.getSqrtRatioAtTick(-100));

        accruePoolFeesInRange(
            manager,
            poolKey,
            StateLibrary.getLiquidity(manager, poolKey.toId()) - 1,
            10_000,
            100_000
        );

        swapperc.swapTo(uniPool, 2 ** 96);
        routerV4.swapTo(address(0), poolKey, 2 ** 96);

        vm.startPrank(Alice);
        {
            (LeftRightUnsigned shortPremium, , ) = pp.getAccumulatedFeesAndPositionsData(
                Alice,
                true,
                $posIdLists[0]
            );

            assertGe(shortPremium.rightSlot(), 0);
            assertGe(shortPremium.leftSlot(), 0);

            (uint256 aliceBalanceBefore0, uint256 aliceBalanceBefore1) = (
                ct0.balanceOf(Alice),
                ct1.balanceOf(Alice)
            );

            // Alice settles her own position, received nothing because the chunks haven't been poked.
            settlePremium(pp, $posIdLists[0], $posIdLists[0], Alice, 0, true);
            (uint256 aliceBalanceAfter0, uint256 aliceBalanceAfter1) = (
                ct0.balanceOf(Alice),
                ct1.balanceOf(Alice)
            );

            (shortPremium, , ) = pp.getAccumulatedFeesAndPositionsData(Alice, true, $posIdLists[0]);

            // has 0 owed premium because it was settled at 0 in settlePremium
            assertEq(shortPremium.rightSlot(), 0);
            assertEq(shortPremium.leftSlot(), 0);

            // burn options and forfeit her premium, which was settled as 0 in settlePremium
            burnOptions(
                pp,
                $posIdLists[0],
                new TokenId[](0),
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                false
            );

            (uint256 aliceBalancePost0, uint256 aliceBalancePost1) = (
                ct0.balanceOf(Alice),
                ct1.balanceOf(Alice)
            );

            // Alice re-mints an option, pokes the chunk and make the protocol collect some premium
            mintOptions(
                pp,
                $posIdLists[0],
                1,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            // Alice tries to settle Bob and Charlie, nothing happends because the short legs are skipped
            {
                (uint256 before0, uint256 before1) = (ct0.balanceOf(Bob), ct1.balanceOf(Bob));

                settlePremium(pp, $posIdLists[0], $posIdLists[0], Bob, 0, true);
                (uint256 after0, uint256 after1) = (ct0.balanceOf(Bob), ct1.balanceOf(Bob));

                assertEq(before0, after0, "no change in Bob's token0 balance");
                assertEq(before1, after1, "no change in Bob's token1 balance");
            }

            {
                (uint256 before0, uint256 before1) = (
                    ct0.balanceOf(Charlie),
                    ct1.balanceOf(Charlie)
                );
                settlePremium(pp, $posIdLists[0], $posIdLists[0], Charlie, 0, true);
                (uint256 after0, uint256 after1) = (ct0.balanceOf(Charlie), ct1.balanceOf(Charlie));
                assertEq(before0, after0, "no change in Charlie's token0 balance");
                assertEq(before1, after1, "no change in Charlie's token1 balance");
            }
        }

        uint256 bobDeltaPremia0;
        uint256 bobDeltaPremia1;

        uint256 snap = vm.snapshotState();

        {
            vm.startPrank(Bob);

            (LeftRightUnsigned shortPremium, , ) = pp.getAccumulatedFeesAndPositionsData(
                Bob,
                true,
                $posIdLists[0]
            );
            uint256 owedPremia0 = shortPremium.rightSlot();
            uint256 owedPremia1 = shortPremium.leftSlot();
            console2.log("owedPremia-total0", owedPremia0);
            console2.log("owedPremia-total1", owedPremia1);

            assertGe(owedPremia0, 0);
            assertGe(owedPremia1, 0);

            (uint256 bobBalanceBefore0, uint256 bobBalanceBefore1) = (
                ct0.balanceOf(Bob),
                ct1.balanceOf(Bob)
            );

            // Bob settles his own premium, receives only realize premia and misses out on unsettled longs
            settlePremium(pp, $posIdLists[0], $posIdLists[0], Bob, 0, true);
            (uint256 bobBalanceAfter0, uint256 bobBalanceAfter1) = (
                ct0.balanceOf(Bob),
                ct1.balanceOf(Bob)
            );

            assertGe(bobBalanceAfter0, bobBalanceBefore0, "bob received premia0");
            assertGe(bobBalanceAfter1, bobBalanceBefore1, "bob received premia1");

            bobDeltaPremia0 = ct0.convertToAssets(bobBalanceAfter0 - bobBalanceBefore0);
            bobDeltaPremia1 = ct1.convertToAssets(bobBalanceAfter1 - bobBalanceBefore1);

            console2.log("bobDeltaPremia0", bobDeltaPremia0);
            console2.log("bobDeltaPremia1", bobDeltaPremia1);
            assertLt(
                bobDeltaPremia0,
                owedPremia0,
                "bob received less than owed due to unsettled token0"
            );
            assertLt(
                bobDeltaPremia1,
                owedPremia1,
                "bob received less than owed due to unsettled token0"
            );
        }

        vm.revertToState(snap);

        vm.startPrank(Charlie);

        uint256 charlieDeltaPremia0;
        uint256 charlieDeltaPremia1;

        {
            (LeftRightUnsigned shortPremium, , ) = pp.getAccumulatedFeesAndPositionsData(
                Charlie,
                true,
                $posIdLists[0]
            );
            uint256 owedPremia0 = shortPremium.rightSlot();
            uint256 owedPremia1 = shortPremium.leftSlot();
            console2.log("owedPremia-total0", owedPremia0);
            console2.log("owedPremia-total1", owedPremia1);

            assertGe(owedPremia0, 0);
            assertGe(owedPremia1, 0);

            (uint256 charlieBalanceBefore0, uint256 charlieBalanceBefore1) = (
                ct0.balanceOf(Charlie),
                ct1.balanceOf(Charlie)
            );

            // Charlie settles Buyers[0] premium first
            settlePremium(pp, $posIdLists[0], $posIdLists[2], Buyers[0], 0, true);

            // Charlie settles his own premium, receives only realize premia from settled longs
            settlePremium(pp, $posIdLists[0], $posIdLists[0], Charlie, 0, true);

            (uint256 charlieBalanceAfter0, uint256 charlieBalanceAfter1) = (
                ct0.balanceOf(Charlie),
                ct1.balanceOf(Charlie)
            );

            assertGt(charlieBalanceAfter0, charlieBalanceBefore0, "charlie received premia0");
            assertGt(charlieBalanceAfter1, charlieBalanceBefore1, "charlie received premia1");

            charlieDeltaPremia0 = ct0.convertToAssets(charlieBalanceAfter0 - charlieBalanceBefore0);
            charlieDeltaPremia1 = ct1.convertToAssets(charlieBalanceAfter1 - charlieBalanceBefore1);

            assertApproxEqAbs(
                charlieDeltaPremia0,
                owedPremia0,
                1,
                "charlie received exactly what they are owed due to settled token0"
            );
            assertApproxEqAbs(
                charlieDeltaPremia1,
                owedPremia1,
                1,
                "charlie received exactly what they are owed due to settled token0"
            );
        }
    }

    function test_success_settleLongPremium() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // sell primary chunk
        $posIdLists[0].push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 1));

        // mint some amount of liquidity with Alice owning 1/2 and Bob and Charlie owning 1/4 respectively
        // then, remove 9.737% of that liquidity at the same ratio
        // Once this state is in place, accumulate some amount of fees on the existing liquidity in the pool
        // The fees should be immediately available for withdrawal because they have been paid to liquidity already in the pool
        // 8.896% * 1.022x vegoid = +~10% of the fee amount accumulated will be owed by sellers
        vm.startPrank(Alice);

        mintOptions(
            pp,
            $posIdLists[0],
            500_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.startPrank(Bob);

        mintOptions(
            pp,
            $posIdLists[0],
            250_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.startPrank(Charlie);

        mintOptions(
            pp,
            $posIdLists[0],
            250_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        // sell unrelated, non-overlapping, dummy chunk (to buy for match testing)
        vm.startPrank(Seller);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        $posIdLists[1].push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 1, 0, -15, 1));

        mintOptions(
            pp,
            $posIdLists[1],
            1_000_000_000 - 9_884_444 * 3,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // position type A: 1-leg long primary
        $posIdLists[2].push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 0, 0, 15, 1));

        for (uint256 i = 0; i < Buyers.length; ++i) {
            vm.startPrank(Buyers[i]);
            mintOptions(
                pp,
                $posIdLists[2],
                9_884_444,
                type(uint24).max,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );
        }

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // position type B: 2-leg long primary and long dummy
        $posIdLists[2].push(
            TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 0, 0, 15, 1).addLeg(
                1,
                1,
                1,
                1,
                1,
                1,
                -15,
                1
            )
        );

        for (uint256 i = 0; i < Buyers.length; ++i) {
            vm.startPrank(Buyers[i]);
            mintOptions(
                pp,
                $posIdLists[2],
                9_884_444,
                type(uint24).max,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );
        }

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // position type C: 2-leg long primary and short dummy
        $posIdLists[2].push(
            TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 0, 0, 15, 1).addLeg(
                1,
                1,
                1,
                0,
                1,
                1,
                -15,
                1
            )
        );

        for (uint256 i = 0; i < Buyers.length; ++i) {
            vm.startPrank(Buyers[i]);
            mintOptions(
                pp,
                $posIdLists[2],
                9_884_444,
                type(uint24).max,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );
        }

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // position type D: 1-leg long dummy
        $posIdLists[2].push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 1, 0, -15, 1));

        for (uint256 i = 0; i < Buyers.length; ++i) {
            vm.startPrank(Buyers[i]);
            mintOptions(
                pp,
                $posIdLists[2],
                19_768_888,
                type(uint24).max,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );
        }

        // populate collateralIdLists with each ending at a different token
        {
            $posIdLists[3] = $posIdLists[2];
            $posIdLists[3][0] = $posIdLists[2][3];
            $posIdLists[3][3] = $posIdLists[2][0];
            collateralIdLists.push($posIdLists[3]);
            $posIdLists[3] = $posIdLists[2];
            $posIdLists[3][1] = $posIdLists[2][3];
            $posIdLists[3][3] = $posIdLists[2][1];
            collateralIdLists.push($posIdLists[3]);
            $posIdLists[3] = $posIdLists[2];
            $posIdLists[3][2] = $posIdLists[2][3];
            $posIdLists[3][3] = $posIdLists[2][2];
            collateralIdLists.push($posIdLists[3]);
            collateralIdLists.push($posIdLists[2]);
        }

        vm.startPrank(Swapper);

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(10) + 1);
        routerV4.swapTo(address(0), poolKey, TickMath.getSqrtRatioAtTick(10) + 1);

        // There are some precision issues with this (1B is not exactly 1B) but close enough to see the effects
        accruePoolFeesInRange(
            manager,
            poolKey,
            StateLibrary.getLiquidity(manager, poolKey.toId()) - 1,
            1_000_000,
            1_000_000_000
        );
        console2.log("liquidity", uniPool.liquidity());

        // accumulate lower order of fees on dummy chunk
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-10));
        routerV4.swapTo(address(0), poolKey, TickMath.getSqrtRatioAtTick(-10));

        accruePoolFeesInRange(
            manager,
            poolKey,
            StateLibrary.getLiquidity(manager, poolKey.toId()) - 1,
            10_000,
            100_000
        );
        console2.log("liquidity", uniPool.liquidity());

        swapperc.swapTo(uniPool, 2 ** 96);
        routerV4.swapTo(address(0), poolKey, 2 ** 96);

        {
            (, currentTick, , , , , ) = uniPool.slot0();
            LeftRightUnsigned accountLiquidityPrimary = sfpm.getAccountLiquidity(
                abi.encode(poolKey),
                address(pp),
                0,
                10,
                20
            );
            console2.log(
                "accountLiquidityPrimaryShort",
                accountLiquidityPrimary.rightSlot() + accountLiquidityPrimary.leftSlot()
            );
            console2.log("accountLiquidityPrimaryRemoved", accountLiquidityPrimary.leftSlot());

            (uint256 shortPremium0Primary, uint256 shortPremium1Primary) = sfpm.getAccountPremium(
                abi.encode(poolKey),
                address(pp),
                0,
                10,
                20,
                currentTick,
                0,
                vegoid
            );

            console2.log(
                "shortPremium0Primary",
                (shortPremium0Primary *
                    (accountLiquidityPrimary.rightSlot() + accountLiquidityPrimary.leftSlot())) /
                    2 ** 64
            );
            console2.log(
                "shortPremium1Primary",
                (shortPremium1Primary *
                    (accountLiquidityPrimary.rightSlot() + accountLiquidityPrimary.leftSlot())) /
                    2 ** 64
            );

            (uint256 longPremium0Primary, uint256 longPremium1Primary) = sfpm.getAccountPremium(
                abi.encode(poolKey),
                address(pp),
                0,
                10,
                20,
                currentTick,
                1,
                vegoid
            );

            console2.log(
                "longPremium0Primary",
                (longPremium0Primary * accountLiquidityPrimary.leftSlot()) / 2 ** 64
            );
            console2.log(
                "longPremium1Primary",
                (longPremium1Primary * accountLiquidityPrimary.leftSlot()) / 2 ** 64
            );
        }

        {
            LeftRightUnsigned accountLiquidityDummy = sfpm.getAccountLiquidity(
                abi.encode(poolKey),
                address(pp),
                1,
                -20,
                -10
            );

            console2.log(
                "accountLiquidityDummyShort",
                accountLiquidityDummy.rightSlot() + accountLiquidityDummy.leftSlot()
            );
            console2.log("accountLiquidityDummyRemoved", accountLiquidityDummy.leftSlot());

            (uint256 shortPremium0Dummy, uint256 shortPremium1Dummy) = sfpm.getAccountPremium(
                abi.encode(poolKey),
                address(pp),
                1,
                -20,
                -10,
                0,
                0,
                vegoid
            );

            console2.log(
                "shortPremium0Dummy",
                (shortPremium0Dummy *
                    (accountLiquidityDummy.rightSlot() + accountLiquidityDummy.leftSlot())) /
                    2 ** 64
            );
            console2.log(
                "shortPremium1Dummy",
                (shortPremium1Dummy *
                    (accountLiquidityDummy.rightSlot() + accountLiquidityDummy.leftSlot())) /
                    2 ** 64
            );

            (uint256 longPremium0Dummy, uint256 longPremium1Dummy) = sfpm.getAccountPremium(
                abi.encode(poolKey),
                address(pp),
                1,
                -20,
                -10,
                0,
                1,
                vegoid
            );

            console2.log(
                "longPremium0Dummy",
                (longPremium0Dummy * accountLiquidityDummy.leftSlot()) / 2 ** 64
            );
            console2.log(
                "longPremium1Dummy",
                (longPremium1Dummy * accountLiquidityDummy.leftSlot()) / 2 ** 64
            );
        }

        // >>> s1p = 1100030357
        // >>> l1p = 100030357
        // >>> s1c = 1_000_000_000
        // >>> l1p//3
        // 33343452
        // >>> (s1c+l1p/3)*(0.25*s1p)//(s1p)
        // 258335863.0 (Bob)
        // >>> 258335863.0*2
        // 516671726.0 (Alice)

        assetsBefore0 = ct0.convertToAssets(ct0.balanceOf(Buyers[0]));
        assetsBefore1 = ct1.convertToAssets(ct1.balanceOf(Buyers[0]));

        // collect buyer 1's four (not three) relevant chunks because i=1 has two legs
        // amount collected: 11114 + (11114 + 111) + 11114 =
        for (uint256 i = 0; i < 3; ++i) {
            settlePremium(pp, new TokenId[](0), collateralIdLists[i], Buyers[0], 0, true);
        }

        assertEq(
            assetsBefore0 - ct0.convertToAssets(ct0.balanceOf(Buyers[0])),
            33_453,
            "Incorrect Buyer 1 1st Collect 0"
        );

        assertEq(
            assetsBefore1 - ct1.convertToAssets(ct1.balanceOf(Buyers[0])),
            33_344_563,
            "Incorrect Buyer 1 1st Collect 1: "
        );

        vm.startPrank(Bob);

        // burn Bob's position, should get 25% of fees paid (no long fees avail.)
        assetsBefore0 = ct0.convertToAssets(ct0.balanceOf(Bob));
        assetsBefore1 = ct1.convertToAssets(ct1.balanceOf(Bob));

        burnOptions(
            pp,
            $posIdLists[0][0],
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        assertEq(
            ct0.convertToAssets(ct0.balanceOf(Bob)) - assetsBefore0,
            258_335,
            "Incorrect Bob Delta 0"
        );
        assertEq(
            ct1.convertToAssets(ct1.balanceOf(Bob)) - assetsBefore1,
            258_335_862,
            "Incorrect Bob Delta 1"
        );

        // sell unrelated, non-overlapping, dummy chunk to replenish removed liquidity
        vm.startPrank(Seller);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        $posIdLists[1].push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 1));

        mintOptions(
            pp,
            $posIdLists[1],
            1_000_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        assetsBefore0Arr.push(ct0.convertToAssets(ct0.balanceOf(Buyers[0])));
        assetsBefore1Arr.push(ct1.convertToAssets(ct1.balanceOf(Buyers[0])));
        assetsBefore0Arr.push(ct0.convertToAssets(ct0.balanceOf(Buyers[1])));
        assetsBefore1Arr.push(ct1.convertToAssets(ct1.balanceOf(Buyers[1])));
        assetsBefore0Arr.push(ct0.convertToAssets(ct0.balanceOf(Buyers[2])));
        assetsBefore1Arr.push(ct1.convertToAssets(ct1.balanceOf(Buyers[2])));

        // now, settle the dummy chunks for all the buyers/positions and see that the settled ratio for primary doesn't change

        for (uint256 i = 0; i < Buyers.length; ++i) {
            settlePremium(pp, $posIdLists[1], collateralIdLists[1], Buyers[i], 1, true);

            settlePremium(pp, $posIdLists[1], collateralIdLists[3], Buyers[i], 0, true);
        }

        assertEq(
            assetsBefore0Arr[0] - ct0.convertToAssets(ct0.balanceOf(Buyers[0])),
            222,
            "Incorrect Buyer 1 2nd Collect 0"
        );

        assertEq(
            assetsBefore1Arr[0] - ct1.convertToAssets(ct1.balanceOf(Buyers[0])),
            2_222,
            "Incorrect Buyer 1 2nd Collect 1"
        );

        assertEq(
            assetsBefore0Arr[1] - ct0.convertToAssets(ct0.balanceOf(Buyers[1])),
            11447,
            "Incorrect Buyer 2 2nd Collect 0"
        );

        assertEq(
            assetsBefore1Arr[1] - ct1.convertToAssets(ct1.balanceOf(Buyers[1])),
            11117817,
            "Incorrect Buyer 2 2nd Collect 1"
        );

        assertEq(
            assetsBefore0Arr[2] - ct0.convertToAssets(ct0.balanceOf(Buyers[2])),
            11447,
            "Incorrect Buyer 3 2nd Collect 0"
        );

        assertEq(
            assetsBefore1Arr[2] - ct1.convertToAssets(ct1.balanceOf(Buyers[2])),
            11117817,
            "Incorrect Buyer 3 2nd Collect 1"
        );

        vm.startPrank(Alice);

        // burn Alice's position
        assetsBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        assetsBefore1 = ct1.convertToAssets(ct1.balanceOf(Alice));

        burnOptions(
            pp,
            $posIdLists[0][0],
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        assertEq(
            ct0.convertToAssets(ct0.balanceOf(Alice)) - assetsBefore0,
            531_490,
            "Incorrect Alice Delta 0"
        );
        assertEq(
            ct1.convertToAssets(ct1.balanceOf(Alice)) - assetsBefore1,
            531_491_038,
            "Incorrect Alice Delta 1"
        );

        // try collecting all the dummy chunks again - see that no additional premium is collected
        assetsBefore0Arr[0] = ct0.convertToAssets(ct0.balanceOf(Buyers[0]));
        assetsBefore1Arr[0] = ct1.convertToAssets(ct1.balanceOf(Buyers[0]));
        assetsBefore0Arr[1] = ct0.convertToAssets(ct0.balanceOf(Buyers[1]));
        assetsBefore1Arr[1] = ct1.convertToAssets(ct1.balanceOf(Buyers[1]));
        assetsBefore0Arr[2] = ct0.convertToAssets(ct0.balanceOf(Buyers[2]));
        assetsBefore1Arr[2] = ct1.convertToAssets(ct1.balanceOf(Buyers[2]));

        for (uint256 i = 0; i < Buyers.length; ++i) {
            settlePremium(pp, new TokenId[](0), collateralIdLists[1], Buyers[i], 1, true);

            settlePremium(pp, new TokenId[](0), collateralIdLists[3], Buyers[i], 0, true);
        }

        assertEq(
            assetsBefore0Arr[0] - ct0.convertToAssets(ct0.balanceOf(Buyers[0])),
            0,
            "Incorrect Buyer 1 3rd Collect 0"
        );

        assertEq(
            assetsBefore1Arr[0] - ct1.convertToAssets(ct1.balanceOf(Buyers[0])),
            0,
            "Incorrect Buyer 1 3rd Collect 1"
        );

        assertEq(
            assetsBefore0Arr[1] - ct0.convertToAssets(ct0.balanceOf(Buyers[1])),
            0,
            "Incorrect Buyer 2 3rd Collect 0"
        );

        assertEq(
            assetsBefore1Arr[1] - ct1.convertToAssets(ct1.balanceOf(Buyers[1])),
            0,
            "Incorrect Buyer 2 3rd Collect 1"
        );

        assertEq(
            assetsBefore0Arr[2] - ct0.convertToAssets(ct0.balanceOf(Buyers[2])),
            0,
            "Incorrect Buyer 3 3rd Collect 0"
        );

        assertEq(
            assetsBefore1Arr[2] - ct1.convertToAssets(ct1.balanceOf(Buyers[2])),
            0,
            "Incorrect Buyer 3 3rd Collect 1"
        );

        // now, collect the rest of the long (primary) legs, premium should be collected from 2nd & 3rd buyers
        assetsBefore0Arr[0] = ct0.convertToAssets(ct0.balanceOf(Buyers[0]));
        assetsBefore1Arr[0] = ct1.convertToAssets(ct1.balanceOf(Buyers[0]));
        assetsBefore0Arr[1] = ct0.convertToAssets(ct0.balanceOf(Buyers[1]));
        assetsBefore1Arr[1] = ct1.convertToAssets(ct1.balanceOf(Buyers[1]));
        assetsBefore0Arr[2] = ct0.convertToAssets(ct0.balanceOf(Buyers[2]));
        assetsBefore1Arr[2] = ct1.convertToAssets(ct1.balanceOf(Buyers[2]));

        for (uint256 i = 0; i < Buyers.length; ++i) {
            settlePremium(pp, new TokenId[](0), collateralIdLists[0], Buyers[i], 0, true);

            settlePremium(pp, new TokenId[](0), collateralIdLists[1], Buyers[i], 0, true);

            settlePremium(pp, new TokenId[](0), collateralIdLists[2], Buyers[i], 0, true);
        }

        assertEq(
            assetsBefore0Arr[0] - ct0.convertToAssets(ct0.balanceOf(Buyers[0])),
            0,
            "Incorrect Buyer 1 4th Collect 0"
        );

        assertEq(
            assetsBefore1Arr[0] - ct1.convertToAssets(ct1.balanceOf(Buyers[0])),
            0,
            "Incorrect Buyer 1 4th Collect 1"
        );

        assertEq(
            assetsBefore0Arr[1] - ct0.convertToAssets(ct0.balanceOf(Buyers[1])),
            22_228,
            "Incorrect Buyer 2 4th Collect 0"
        );

        assertEq(
            assetsBefore1Arr[1] - ct1.convertToAssets(ct1.balanceOf(Buyers[1])),
            22_228_968,
            "Incorrect Buyer 2 4th Collect 1:"
        );

        assertEq(
            assetsBefore0Arr[2] - ct0.convertToAssets(ct0.balanceOf(Buyers[2])),
            22_228,
            "Incorrect Buyer 3 4th Collect 0"
        );

        assertEq(
            assetsBefore1Arr[2] - ct1.convertToAssets(ct1.balanceOf(Buyers[2])),
            22_228_968,
            "Incorrect Buyer 3 4th Collect 1"
        );

        vm.startPrank(Charlie);

        // Finally, burn Charlie's position, he should get 27.5% (25% + full 10% long paid (* 25% owned))
        assetsBefore0 = ct0.convertToAssets(ct0.balanceOf(Charlie));
        assetsBefore1 = ct1.convertToAssets(ct1.balanceOf(Charlie));

        burnOptions(
            pp,
            $posIdLists[0][0],
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        assertEq(
            ct0.convertToAssets(ct0.balanceOf(Charlie)) - assetsBefore0,
            275_007,
            "Incorrect Charlie Delta 0"
        );
        assertEq(
            ct1.convertToAssets(ct1.balanceOf(Charlie)) - assetsBefore1,
            275_007_589,
            "Incorrect Charlie Delta 1"
        );

        // test long leg validation
        //console2.log('a');
        //vm.expectRevert(Errors.NotALongLeg.selector);
        //settlePremium(pp, new TokenId[](0), collateralIdLists[2], Buyers[0], 1, true);

        // test positionIdList validation
        // snapshot so we don't have to reset changes to collateralIdLists array
        uint256 snap = vm.snapshot();

        collateralIdLists[0].pop();
        vm.expectRevert(Errors.InputListFail.selector);
        settlePremium(pp, new TokenId[](0), collateralIdLists[0], Buyers[0], 0, true);
        vm.revertTo(snap);

        // test collateral checking (basic)
        for (uint256 i = 0; i < 3; ++i) {
            // snapshot so we don't have to reset changes to collateralIdLists array
            snap = vm.snapshot();

            deal(address(ct0), Buyers[i], i ** 15);
            deal(address(ct1), Buyers[i], i ** 15);
            vm.expectRevert(
                abi.encodeWithSelector(Errors.AccountInsolvent.selector, uint256(0), uint256(4))
            );
            settlePremium(pp, new TokenId[](0), collateralIdLists[0], Buyers[i], 0, true);
            vm.revertTo(snap);
        }

        // burn all buyer positions - they should pay 0 premium since it has all been settled already
        for (uint256 i = 0; i < Buyers.length; ++i) {
            assetsBefore0 = ct0.convertToAssets(ct0.balanceOf(Buyers[i]));
            assetsBefore1 = ct1.convertToAssets(ct1.balanceOf(Buyers[i]));
            vm.startPrank(Buyers[i]);
            burnOptions(
                pp,
                $posIdLists[2],
                new TokenId[](0),
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            console2.log("i", i);
            // the positive premium is from the dummy short chunk
            assertEq(
                int256(ct0.convertToAssets(ct0.balanceOf(Buyers[i]))) - int256(assetsBefore0),
                i == 0 ? int256(107) : i == 1 ? int256(108) : int(99),
                "Buyer paid premium twice"
            );

            assertEq(
                ct1.convertToAssets(ct1.balanceOf(Buyers[i])) - assetsBefore1,
                i < 2 ? 1086 : 1080,
                "Buyer paid premium twice"
            );
        }
    }

    function test_success_settleLongPremium_tokenSubstitution() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(100));
        routerV4.swapTo(address(0), poolKey, TickMath.getSqrtRatioAtTick(100));
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
        swapperc.swapTo(uniPool, 2 ** 96);
        routerV4.swapTo(address(0), poolKey, 2 ** 96);

        $posIdLists[0].push(
            TokenId.wrap(0).addPoolId(sfpm.getPoolId(abi.encode(poolKey.toId()), vegoid)).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                15,
                1
            )
        );

        vm.startPrank(Alice);

        mintOptions(
            pp,
            $posIdLists[0],
            100_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        $posIdLists[1].push(
            TokenId.wrap(0).addPoolId(sfpm.getPoolId(abi.encode(poolKey.toId()), vegoid)).addLeg(
                0,
                1,
                1,
                1,
                0,
                0,
                15,
                1
            )
        );

        for (uint256 i = 0; i < 3; ++i) {
            vm.startPrank(Buyers[i]);
            mintOptions(
                pp,
                $posIdLists[1],
                1_000_000,
                type(uint24).max,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );
        }

        vm.startPrank(Swapper);

        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(10) + 1);
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(10) + 1);

        accruePoolFeesInRange(
            manager,
            poolKey,
            StateLibrary.getLiquidity(manager, poolKey.toId()) - 1,
            1_000_000,
            1_000_000_000
        );

        int256 premium0 = 10388;
        int256 premium1 = 10388989;

        console2.log("TWAP", pp.getTWAP());
        uint160 lastObservedPrice = Math.getSqrtRatioAtTick(pp.getTWAP());

        vm.startPrank(Alice);

        uint256 settlerBalanceBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        uint256 settlerBalanceBefore1 = ct1.convertToAssets(ct1.balanceOf(Alice));

        // shortage of token1 - succeeds and token1 is converted to token0
        editCollateral(ct1, Buyers[0], 0);

        uint256 settleeBalanceBefore0 = ct0.convertToAssets(ct0.balanceOf(Buyers[0]));
        uint256 settleeBalanceBefore1 = ct1.convertToAssets(ct1.balanceOf(Buyers[0]));

        settlePremium(pp, $posIdLists[0], $posIdLists[1], Buyers[0], 0, true);

        int256 balanceDelta0 = int256(ct0.convertToAssets(ct0.balanceOf(Buyers[0]))) -
            int256(settleeBalanceBefore0);
        int256 balanceDelta1 = int256(ct1.convertToAssets(ct1.balanceOf(Buyers[0]))) -
            int256(settleeBalanceBefore1);

        assertEq(
            -balanceDelta0,
            premium0 +
                int256(PanopticMath.convert1to0RoundingUp(uint256(premium1), lastObservedPrice)),
            "Fail: balance delta0 does not match premium"
        );
        assertEq(balanceDelta1, 0);

        assertEq(
            int256(settlerBalanceBefore0) - int256(ct0.convertToAssets(ct0.balanceOf(Alice))),
            balanceDelta0 + premium0,
            "balance premium0"
        );
        assertEq(
            int256(settlerBalanceBefore1) - int256(ct1.convertToAssets(ct1.balanceOf(Alice))),
            premium1,
            "balance premium1"
        );

        settlerBalanceBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        settlerBalanceBefore1 = ct1.convertToAssets(ct1.balanceOf(Alice));

        // shortage of token0 - succeeds and token0 is converted to token1
        editCollateral(ct0, Buyers[1], 0);

        settleeBalanceBefore0 = ct0.convertToAssets(ct0.balanceOf(Buyers[1]));
        settleeBalanceBefore1 = ct1.convertToAssets(ct1.balanceOf(Buyers[1]));

        settlePremium(pp, $posIdLists[0], $posIdLists[1], Buyers[1], 0, true);

        balanceDelta0 =
            int256(ct0.convertToAssets(ct0.balanceOf(Buyers[1]))) -
            int256(settleeBalanceBefore0);
        balanceDelta1 =
            int256(ct1.convertToAssets(ct1.balanceOf(Buyers[1]))) -
            int256(settleeBalanceBefore1);

        assertEq(balanceDelta0, 0);
        assertEq(
            -balanceDelta1,
            premium1 +
                int256(PanopticMath.convert0to1RoundingUp(uint256(premium0), lastObservedPrice)),
            "balancedelta1"
        );

        assertEq(
            int256(settlerBalanceBefore0) - int256(ct0.convertToAssets(ct0.balanceOf(Alice))),
            premium0 + 1,
            "premium0"
        );
        assertEq(
            int256(settlerBalanceBefore1) - int256(ct1.convertToAssets(ct1.balanceOf(Alice))),
            balanceDelta1 + premium1,
            "settlebakance"
        );

        // insolvent account - fails while revoking virtual shares
        editCollateral(ct0, Buyers[2], 0);
        editCollateral(ct1, Buyers[2], 0);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.AccountInsolvent.selector, uint256(0), uint256(4))
        );
        settlePremium(pp, $posIdLists[0], $posIdLists[1], Buyers[2], 0, true);
    }

    function test_success_settledPremiumDistribution() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // mint OTM position
        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 1));

        // mint some amount of liquidity with Alice owning 1/2 and Bob and Charlie owning 1/4 respectively
        // then, remove 9.737% of that liquidity at the same ratio
        // Once this state is in place, accumulate some amount of fees on the existing liquidity in the pool
        // The fees should be immediately available for withdrawal because they have been paid to liquidity already in the pool
        // 8.896% * 1.022x vegoid = +~10% of the fee amount accumulated will be owed by sellers
        // First close Bob's position; they should receive 25% of the initial amount because no fees were paid on their position
        // Close half (4.4468%) of the removed liquidity
        // Then close Alice's position, they should receive ~53.3% (50%+ 2/3*5%)
        // Close the other half of the removed liquidity (4.4468%)
        // Finally, close Charlie's position, they should receive ~27.5% (25% + 10% * 25%)
        vm.startPrank(Alice);

        mintOptions(
            pp,
            $posIdList,
            500_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.startPrank(Bob);

        mintOptions(
            pp,
            $posIdList,
            250_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.startPrank(Charlie);

        mintOptions(
            pp,
            $posIdList,
            250_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 0, 0, 15, 1));

        vm.startPrank(Alice);

        // mint finely tuned amount of long options for Alice so premium paid = 1.1x
        mintOptions(
            pp,
            $posIdList,
            44_468,
            type(uint24).max,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.startPrank(Bob);

        // mint finely tuned amount of long options for Bob so premium paid = 1.1x
        mintOptions(
            pp,
            $posIdList,
            44_468,
            type(uint24).max,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.startPrank(Swapper);

        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(10) + 1);
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(10) + 1);

        // There are some precision issues with this (1B is not exactly 1B) but close enough to see the effects
        accruePoolFeesInRange(
            manager,
            poolKey,
            StateLibrary.getLiquidity(manager, poolKey.toId()) - 1,
            1_000_000,
            1_000_000_000
        );

        routerV4.swapTo(address(0), poolKey, 2 ** 96);
        swapperc.swapTo(uniPool, 2 ** 96);

        vm.startPrank(Bob);

        // burn Bob's position, should get 25% of fees paid (no long fees avail.)
        assetsBefore0 = ct0.convertToAssets(ct0.balanceOf(Bob));
        assetsBefore1 = ct1.convertToAssets(ct1.balanceOf(Bob));

        $tempIdList.push($posIdList[1]);

        // burn Bob's short option
        burnOptions(
            pp,
            $posIdList[0],
            $tempIdList,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        assertEq(
            ct0.convertToAssets(ct0.balanceOf(Bob)) - assetsBefore0,
            250_000,
            "Incorrect Bob Delta 0"
        );
        assertEq(
            ct1.convertToAssets(ct1.balanceOf(Bob)) - assetsBefore1,
            249_999_999,
            "Incorrect Bob Delta 1"
        );

        // re-mint the short option
        $posIdList[1] = $posIdList[0];
        $posIdList[0] = $tempIdList[0];
        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        $tempIdList[0] = $posIdList[1];

        // Burn the long options, adds 1/2 of the removed liq
        // amount of premia paid = 50_000
        burnOptions(
            pp,
            $posIdList[0],
            $tempIdList,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.startPrank(Alice);

        // burn Alice's position, should get 53.3̅% of fees paid back (50% + (5% long paid) * (2/3 owned by Alice))
        assetsBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        assetsBefore1 = ct1.convertToAssets(ct1.balanceOf(Alice));

        $tempIdList[0] = $posIdList[0];
        burnOptions(
            pp,
            $posIdList[1],
            $tempIdList,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        assertEq(
            ct0.convertToAssets(ct0.balanceOf(Alice)) - assetsBefore0,
            533_333,
            "Incorrect Alice Delta 0"
        );
        assertEq(
            ct1.convertToAssets(ct1.balanceOf(Alice)) - assetsBefore1,
            533_333_345,
            "Incorrect Alice Delta 1"
        );

        // Burn other half of the removed liq
        burnOptions(
            pp,
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.startPrank(Charlie);

        // Finally, burn Charlie's position, he should get 27.5% (25% + full 10% long paid (* 25% owned))
        assetsBefore0 = ct0.convertToAssets(ct0.balanceOf(Charlie));
        assetsBefore1 = ct1.convertToAssets(ct1.balanceOf(Charlie));

        burnOptions(
            pp,
            $posIdList[1],
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        assertEq(
            ct0.convertToAssets(ct0.balanceOf(Charlie)) - assetsBefore0,
            275_000,
            "Incorrect Charlie Delta 0"
        );
        assertEq(
            ct1.convertToAssets(ct1.balanceOf(Charlie)) - assetsBefore1,
            275_000_008,
            "Incorrect Charlie Delta 1"
        );
    }

    function test_Success_validateCollateralWithdrawable() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // mint OTM position
        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 1));

        vm.startPrank(Bob);

        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        editCollateral(ct0, Bob, ct0.convertToShares(266269));
        editCollateral(ct1, Bob, 0);

        pp.validateCollateralWithdrawable(Bob, $posIdList, true);
    }

    function test_Success_WithdrawWithOpenPositions() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // mint OTM position
        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 1));

        vm.startPrank(Bob);

        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        editCollateral(ct0, Bob, ct0.convertToShares(1_000_000));
        editCollateral(ct1, Bob, 0);

        ct0.withdraw(1_000_000 - 266269, Bob, Bob, $posIdList, true);
    }

    function test_Fail_validateCollateralWithdrawable() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // mint OTM position
        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 1));

        vm.startPrank(Bob);

        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        editCollateral(ct0, Bob, ct0.convertToShares(264670));
        editCollateral(ct1, Bob, 0);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.AccountInsolvent.selector, uint256(0), uint256(1))
        );
        pp.validateCollateralWithdrawable(Bob, $posIdList, true);
    }

    function test_Fail_WithdrawWithOpenPositions_AccountInsolvent() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // mint OTM position
        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 1));

        vm.startPrank(Bob);

        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        editCollateral(ct0, Bob, ct0.convertToShares(1_000_000));
        editCollateral(ct1, Bob, 0);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.AccountInsolvent.selector, uint256(0), uint256(1))
        );
        ct0.withdraw(1_000_000 - 264670, Bob, Bob, $posIdList, true);
    }

    function test_Fail_InsolventAtCurrentTick_itmPut() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeOracle();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10000, 10000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -10000, 10000, 10 ** 18);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        int24 tickSpacing = uniPool.tickSpacing();
        // mint ITM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                1,
                0,
                1,
                0,
                (0 / tickSpacing) * tickSpacing,
                2
            )
        );

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-955));
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(-955));

        assertTrue(pp.isSafeMode() > 0, "in safe mode");

        vm.startPrank(Bob);

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        token0.approve(address(ct0), 1_000_000);
        token1.approve(address(ct1), 1_000_000);

        // deposit bare minimum
        ct0.deposit(100_200, Bob);
        //ct1.deposit(0, Bob);

        // mint fails
        vm.expectRevert(
            abi.encodeWithSelector(Errors.AccountInsolvent.selector, uint256(0), uint256(4))
        );
        //vm.expectRevert();
        mintOptions(
            pp,
            $posIdList,
            100_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    function test_Fail_InsolventAtCurrentTick_itmCall() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeOracle();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10000, 10000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -10000, 10000, 10 ** 18);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        int24 tickSpacing = uniPool.tickSpacing();
        // mint ITM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                (0 / tickSpacing) * tickSpacing,
                2
            )
        );

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(955));
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(955));

        assertTrue(pp.isSafeMode() > 0, "in safe mode");

        vm.startPrank(Bob);

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        token0.approve(address(ct0), 1_000_000);
        token1.approve(address(ct1), 1_000_000);

        // deposit bare minimum - covered
        //ct0.deposit(0, Bob);
        ct1.deposit(100_200, Bob);

        // mint fails
        vm.expectRevert(
            abi.encodeWithSelector(Errors.AccountInsolvent.selector, uint256(0), uint256(4))
        );
        mintOptions(
            pp,
            $posIdList,
            100_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    function test_Success_InsolventAtCurrentTick_itmPut() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeOracle();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10000, 10000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -10000, 10000, 10 ** 18);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        int24 tickSpacing = uniPool.tickSpacing();
        // mint ITM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                1,
                0,
                1,
                0,
                (0 / tickSpacing) * tickSpacing,
                2
            )
        );

        (, int24 staleTick, , , , , ) = uniPool.slot0();

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-952));
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(-952));

        console2.log("isSafeMode", pp.isSafeMode() > 0 ? "safe mode ON" : "safe mode OFF");
        assertTrue(pp.isSafeMode() == 0, "safeMode");
        vm.startPrank(Bob);

        uint256 snapshot = vm.snapshot();

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        token0.approve(address(ct0), 1_000_000);
        token1.approve(address(ct1), 1_000_000);

        // deposit bare minimum for naked mints
        //ct0.deposit(0, Bob);
        ct1.deposit(17_818, Bob);

        // mint succeeds
        mintOptions(
            pp,
            $posIdList,
            100_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            staleTick,
            $posIdList
        );

        assertTrue(totalCollateralBalance0 > totalCollateralRequired0, "Is solvent at stale tick!");

        (, currentTick, , , , , ) = uniPool.slot0();

        (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            $posIdList
        );

        console2.log("reqs", totalCollateralBalance0, totalCollateralRequired0);

        assertTrue(
            totalCollateralBalance0 <= totalCollateralRequired0,
            "Is liquidatable at current tick!"
        );

        vm.startPrank(Swapper);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -100000, 100000, 10 ** 18);
            vm.warp(block.timestamp + 3600);
            vm.roll(block.number + 1);
            pp.pokeOracle();
            swapperc.burn(uniPool, -100000, 100000, 10 ** 18);
        }

        vm.startPrank(Alice);

        deal(ct0.asset(), Alice, 1_000_000);
        deal(ct1.asset(), Alice, 1_000_000);

        IERC20Partial(ct0.asset()).approve(address(ct0), 1_000_000);
        IERC20Partial(ct1.asset()).approve(address(ct1), 1_000_000);

        liquidate(pp, new TokenId[](0), Bob, $posIdList);

        (uint256 after0, uint256 after1) = (
            ct0.convertToAssets(ct0.balanceOf(Bob)),
            ct1.convertToAssets(ct1.balanceOf(Bob))
        );

        assertTrue((after0 > 0) || (after1 > 0), "no protocol loss");

        vm.revertTo(snapshot);

        vm.startPrank(Swapper);

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-955));
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(-955));

        console2.log("isSafeMode", pp.isSafeMode() > 0 ? "safe mode ON" : "safe mode OFF");
        assertTrue(pp.isSafeMode() > 0);

        vm.startPrank(Bob);

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        token0.approve(address(ct0), 1_000_000);
        token1.approve(address(ct1), 1_000_000);

        // deposit token1 because cross-margin is disabled
        //ct0.deposit(150504, Bob);
        ct1.deposit(150504, Bob);

        mintOptions(
            pp,
            $posIdList,
            100_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        (uint128 balance, uint64 utilization0, uint64 utilization1) = ph.optionPositionInfo(
            pp,
            Bob,
            $posIdList[0]
        );

        assertEq(balance, 100_000);
        assertEq(utilization0, 0);
        assertEq(utilization1, 1);

        (, currentTick, , , , , ) = uniPool.slot0();

        (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            $posIdList
        );

        console2.log("reqs", totalCollateralBalance0, totalCollateralRequired0);
        assertTrue(
            totalCollateralBalance0 >= totalCollateralRequired0,
            "Is solvent at current tick!"
        );
    }

    function test_Success_InsolventAtCurrentTick_itmCall() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeOracle();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10000, 10000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -10000, 10000, 10 ** 18);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        int24 tickSpacing = uniPool.tickSpacing();
        // mint ITM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                (0 / tickSpacing) * tickSpacing,
                2
            )
        );

        (, int24 staleTick, , , , , ) = uniPool.slot0();

        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(952));
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(952));
        pp.pokeOracle();
        console2.log("safeMode level", pp.isSafeMode());
        console2.log("isSafeMode", pp.isSafeMode() > 0 ? "safe mode ON" : "safe mode OFF");
        assertTrue(pp.isSafeMode() == 0);

        vm.startPrank(Bob);

        uint256 snapshot = vm.snapshot();

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        token0.approve(address(ct0), 1_000_000);
        token1.approve(address(ct1), 1_000_000);

        // deposit bare minimum for naked mints
        //ct0.deposit(0, Bob);
        ct1.deposit(20_000, Bob);
        console2.log("Bob mint");

        // mint succeeds
        mintOptions(
            pp,
            $posIdList,
            100_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            staleTick,
            $posIdList
        );

        assertTrue(totalCollateralBalance0 > totalCollateralRequired0, "Is solvent at stale tick!");

        (, currentTick, , , , , ) = uniPool.slot0();

        (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            $posIdList
        );

        console2.log(
            "totalCollateralBalance0, totalCollateralRequired0",
            totalCollateralBalance0,
            totalCollateralRequired0
        );
        assertTrue(
            totalCollateralBalance0 <= totalCollateralRequired0,
            "Is liquidatable at current tick!"
        );

        vm.startPrank(Swapper);

        // setup mini-median price array
        for (uint256 i = 0; i < 60; ++i) {
            swapperc.mint(uniPool, -100000, 100000, 10 ** 18);
            vm.warp(block.timestamp + 3600); // 1h steps
            vm.roll(block.number + 1);
            pp.pokeOracle();
            (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, oraclePack) = pp
                .getOracleTicks();
            int24 TWAPtick = re.twapEMA(oraclePack);
            console2.log(i, uint24(fastOracleTick), uint24(TWAPtick), uint24(lastObservedTick));
            swapperc.burn(uniPool, -100000, 100000, 10 ** 18);
        }

        vm.startPrank(Alice);

        deal(ct0.asset(), Alice, 1_000_000);
        deal(ct1.asset(), Alice, 1_000_000);

        IERC20Partial(ct0.asset()).approve(address(ct0), 1_000_000);
        IERC20Partial(ct1.asset()).approve(address(ct1), 1_000_000);

        (currentTick, , , , oraclePack) = pp.getOracleTicks();
        int24 TWAPtick = re.twapEMA(oraclePack);
        console2.log("TWAPtick", TWAPtick);

        liquidate(pp, new TokenId[](0), Bob, $posIdList);

        (uint256 after0, uint256 after1) = (
            ct0.convertToAssets(ct0.balanceOf(Bob)),
            ct1.convertToAssets(ct1.balanceOf(Bob))
        );

        assertTrue((after0 > 0) || (after1 > 0), "no protocol loss");

        vm.revertTo(snapshot);

        vm.startPrank(Swapper);

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(954));
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(954));

        console2.log("isSafeMode", pp.isSafeMode() > 0 ? "safe mode ON" : "safe mode OFF");
        assertTrue(pp.isSafeMode() > 0, "safe mode still");

        vm.startPrank(Bob);

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        token0.approve(address(ct0), 1_000_000);
        token1.approve(address(ct1), 1_000_000);

        // deposit token0 because no cross-collateral allowed
        ct0.deposit(124745, Bob);
        //ct1.deposit(100000, Bob);

        mintOptions(
            pp,
            $posIdList,
            100_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        (uint128 balance, uint64 utilization0, uint64 utilization1) = ph.optionPositionInfo(
            pp,
            Bob,
            $posIdList[0]
        );

        assertEq(balance, 100_000, "balance");
        assertEq(utilization0, 1, "u0");
        assertEq(utilization1, 0, "u1");

        (, currentTick, , , , , ) = uniPool.slot0();

        (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            $posIdList
        );

        console2.log("reqs", totalCollateralBalance0, totalCollateralRequired0);
        assertTrue(
            totalCollateralBalance0 >= totalCollateralRequired0,
            "Is solvent at current tick!"
        );
    }

    function test_Fail_WithdrawWithOpenPositions_SolventReceiver_AccountInsolvent() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // mint OTM position
        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 1));

        vm.startPrank(Bob);

        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        editCollateral(ct0, Bob, ct0.convertToShares(1_000_000));
        editCollateral(ct1, Bob, 0);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.AccountInsolvent.selector, uint256(0), uint256(1))
        );
        ct0.withdraw(1_000_000 - 264670, Alice, Bob, $posIdList, true);
    }

    function test_Success_SafeMode_down() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        assertTrue(pp.isSafeMode() == 0, "not in safe mode");

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-952));
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(-952));

        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();

        currentTick = sfpm.getCurrentTick(abi.encode(poolKey));
        assertTrue(Math.abs(currentTick - slowOracleTick) <= 953, "small price deviation");
        assertTrue(pp.isSafeMode() == 0, "not in safe mode");

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-954));
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(-954));

        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();
        assertTrue(Math.abs(currentTick - slowOracleTick) > 953, "small price deviation");
        assertTrue(pp.isSafeMode() > 0, "in safe mode");
    }

    function test_Success_SafeMode_up() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        assertTrue(pp.isSafeMode() == 0, "not in safe mode");

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(953));
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(953));

        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();
        currentTick = sfpm.getCurrentTick(abi.encode(poolKey));

        console2.log("slowOracleTick", slowOracleTick);
        console2.log("currentTick", currentTick);
        assertTrue(Math.abs(currentTick - slowOracleTick) <= 953, "small price deviation 0");
        assertTrue(pp.isSafeMode() == 0, "not in safe mode");

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(954));
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(954));

        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();
        currentTick = sfpm.getCurrentTick(abi.encode(poolKey));
        assertTrue(Math.abs(currentTick - slowOracleTick) > 953, "small price deviation1 ");
        assertTrue(pp.isSafeMode() > 0, "in safe mode");
    }

    function test_Success_SafeMode_pokes() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeOracle();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10, 10, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -100000, 100000, 10 ** 24);

        assertTrue(pp.isSafeMode() == 0, "not in safe mode");

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-1065));
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(-1065));

        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();

        assertTrue(Math.abs(currentTick - slowOracleTick) > 953, "small price deviation");
        console2.log("cur", currentTick);
        console2.log("sl", slowOracleTick);
        assertTrue(pp.isSafeMode() > 0, "in safe mode");

        // setup mini-median price array
        for (uint256 i = 0; i < 1; ++i) {
            swapperc.mint(uniPool, -10000, 10000, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeOracle();
            swapperc.burn(uniPool, -10000, 10000, 10 ** 18);
        }
        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();
        console2.log("cur", currentTick);
        console2.log("sl", slowOracleTick);

        assertTrue(pp.isSafeMode() > 0, "slow oracle tick did not catch up 0");

        swapperc.mint(uniPool, -10000, 10000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -10000, 10000, 10 ** 18);

        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 1);
        pp.pokeOracle();
        swapperc.burn(uniPool, -10000, 10000, 10 ** 18);
        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();
        console2.log("cur", currentTick);
        console2.log("sl", slowOracleTick);

        assertTrue(pp.isSafeMode() == 0, "slow oracle tick caught up 1");
    }

    function test_Success_SafeMode_mint_otm() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeOracle();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10, 10, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -100000, 100000, 10 ** 24);

        assertTrue(pp.isSafeMode() == 0, "not in safe mode");

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-953));
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(-953));

        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();
        console2.log("cur", currentTick);
        console2.log("sl", slowOracleTick);

        assertTrue(Math.abs(currentTick - slowOracleTick) <= 953, "small price deviation 0");
        assertTrue(pp.isSafeMode() == 0, "not in safe mode");

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        int24 tickSpacing = uniPool.tickSpacing();
        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                (-900 / tickSpacing) * tickSpacing,
                2
            )
        );

        vm.startPrank(Bob);

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        uint256 snap = vm.snapshot();

        // deposit only token0
        token0.approve(address(ct0), 1_000_000);
        ct0.deposit(41874, Bob);
        token1.approve(address(ct1), 1_000_000);
        //ct1.deposit(0, Bob);

        // not in safeMode, mint with minimum
        mintOptions(
            pp,
            $posIdList,
            100_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.revertTo(snap);

        vm.startPrank(Swapper);
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-955));
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(-955));
        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();

        console2.log("currentTick", currentTick);
        console2.log("slowOracleTick", slowOracleTick);
        assertTrue(Math.abs(currentTick - slowOracleTick) > 953, "large price deviation");

        assertTrue(pp.isSafeMode() > 0, "in safe mode");
        vm.startPrank(Bob);

        // deposit only token1
        token0.approve(address(ct0), 1_000_000);
        ct0.deposit(1_000_000, Bob); // 1.3333 * (1.0001**900 * 100000) * (1 + 1 - 1.0001**-1 / 1.0001**900  -> 100 % collateralization, requirement evaluated at tick=-1.
        token1.approve(address(ct1), 1_000_000);
        ct1.deposit(1_000_000, Bob);

        // can mint covered positions
        mintOptions(
            pp,
            $posIdList,
            100_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        (uint128 balance, uint64 utilization0, uint64 utilization1) = ph.optionPositionInfo(
            pp,
            Bob,
            $posIdList[0]
        );

        assertEq(balance, 100_000);
        assertEq(utilization0, 1);
        assertEq(utilization1, 0);
    }

    function test_Success_SafeMode_mint_itm() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeOracle();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10, 10, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -100000, 100000, 10 ** 24);

        assertTrue(pp.isSafeMode() == 0, "not in safe mode");

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-955));
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(-955));

        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();

        assertTrue(Math.abs(currentTick - slowOracleTick) > 953, "small price deviation");
        assertTrue(pp.isSafeMode() > 0, "in safe mode");

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        int24 tickSpacing = uniPool.tickSpacing();
        // mint ITM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                1,
                0,
                0,
                0,
                (-2500 / tickSpacing) * tickSpacing,
                2
            )
        );

        vm.startPrank(Bob);

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        // deposit only token0
        token0.approve(address(ct0), 1_000_000);
        ct0.deposit(102_000, Bob);
        token1.approve(address(ct1), 1_000_000);
        //ct1.deposit(0, Bob);

        // in safeMode, enforce covered mints, reverts
        vm.expectRevert();
        mintOptions(
            pp,
            $posIdList,
            100_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        //ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        // deposit token0 because cross-margining is disabled
        ct0.deposit(196_000, Bob);
        ct1.deposit(181_183, Bob); //

        // can mint covered positions
        mintOptions(
            pp,
            $posIdList,
            100_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        (uint128 balance, uint64 utilization0, uint64 utilization1) = ph.optionPositionInfo(
            pp,
            Bob,
            $posIdList[0]
        );

        assertEq(balance, 100_000);
        assertEq(utilization0, 1);
        assertEq(utilization1, 0);
    }

    function test_Success_SafeMode_burn() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeOracle();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10, 10, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -100000, 100000, 10 ** 24);

        assertTrue(pp.isSafeMode() == 0, "not in safe mode");

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        int24 tickSpacing = uniPool.tickSpacing();
        // mint OTM position
        $posIdList.push(
            TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                1,
                0,
                1,
                0,
                (-500 / tickSpacing) * tickSpacing,
                2
            )
        );

        vm.startPrank(Bob);

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        token0.approve(address(ct0), 1_000_000);
        ct0.deposit(28_000, Bob);
        token1.approve(address(ct1), 1_000_000);
        ct1.deposit(2_000, Bob);

        mintOptions(
            pp,
            $posIdList,
            100_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.startPrank(Swapper);
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-955));
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(-955));

        (currentTick, slowOracleTick, , , ) = pp.getOracleTicks();

        assertTrue(Math.abs(currentTick - slowOracleTick) > 953, "small price deviation");
        assertTrue(pp.isSafeMode() > 0, "in safe mode");

        vm.startPrank(Bob);

        console2.log("00");
        vm.expectRevert();
        burnOptions(
            pp,
            $posIdList,
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        uint256 before0 = ct0.convertToAssets(ct0.balanceOf(Bob));
        uint256 before1 = ct1.convertToAssets(ct1.balanceOf(Bob));

        // Add just enough to cover the covered exercise:
        ct1.deposit(98_300, Bob);

        burnOptions(
            pp,
            $posIdList,
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        uint256 after0 = ct0.convertToAssets(ct0.balanceOf(Bob));
        uint256 after1 = ct1.convertToAssets(ct1.balanceOf(Bob));

        console2.log(before0, before1, after0, after1);
    }

    function test_Success_OraclePoke_mint() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeOracle();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -100000, 100000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -100000, 100000, 10 ** 18);
        vm.warp((block.timestamp >> 6) * 64 + 128);
        vm.roll(block.number + 1);
        pp.pokeOracle();

        (, , slowOracleTick, , oraclePack) = pp.getOracleTicks();

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // mint OTM position
        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 4095));
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-955));
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(-955));

        vm.warp(block.timestamp + 63);
        vm.roll(block.number + 1);

        vm.startPrank(Alice);

        mintOptions(
            pp,
            $posIdList,
            500_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        burnOptions(
            pp,
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        (, , int24 slowOracleTickStale, , OraclePack oraclePackStale) = pp.getOracleTicks();

        assertEq(slowOracleTick, slowOracleTickStale, "no slow oracle update 1");
        assertEq(
            OraclePack.unwrap(oraclePack),
            OraclePack.unwrap(oraclePackStale),
            "no slow oracle update 2"
        );

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        mintOptions(
            pp,
            $posIdList,
            500_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        (, , slowOracleTickStale, , oraclePackStale) = pp.getOracleTicks();

        assertTrue(slowOracleTick == slowOracleTickStale, "no slow oracle update 3");
        assertTrue(
            OraclePack.unwrap(oraclePack) != OraclePack.unwrap(oraclePackStale),
            "oracle median data update 4"
        );

        vm.warp(block.timestamp + 64);
        vm.roll(block.number + 1);
        pp.pokeOracle();

        (, , slowOracleTickStale, , oraclePackStale) = pp.getOracleTicks();

        assertTrue(slowOracleTick == slowOracleTickStale, "no slow oracle update");
        assertTrue(
            OraclePack.unwrap(oraclePack) != OraclePack.unwrap(oraclePackStale),
            "oracle median data update"
        );

        vm.warp(block.timestamp + 64);
        vm.roll(block.number + 1);
        pp.pokeOracle();

        (, , slowOracleTickStale, , oraclePackStale) = pp.getOracleTicks();

        assertTrue(slowOracleTick == slowOracleTickStale, "no slow oracle update");
        assertTrue(
            OraclePack.unwrap(oraclePack) != OraclePack.unwrap(oraclePackStale),
            "oracle median data update"
        );

        vm.warp(block.timestamp + 64);
        vm.roll(block.number + 1);
        pp.pokeOracle();

        (, , slowOracleTickStale, , oraclePackStale) = pp.getOracleTicks();

        assertTrue(slowOracleTick != slowOracleTickStale, "no slow oracle update");
        assertTrue(
            OraclePack.unwrap(oraclePack) != OraclePack.unwrap(oraclePackStale),
            "oracle median data update"
        );
    }

    function test_Success_OraclePoke_burn() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -100000, 100000, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeOracle();
            swapperc.burn(uniPool, -100000, 100000, 10 ** 18);
        }
        swapperc.mint(uniPool, -100000, 100000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -100000, 100000, 10 ** 18);
        vm.warp((block.timestamp >> 6) * 64 + 128);
        vm.roll(block.number + 1);
        pp.pokeOracle();
        //swapperc.burn(uniPool, -100000, 100000, 10 ** 18);
        //swapperc.mint(uniPool, -100000, 100000, 10 ** 18);

        (, , slowOracleTick, , oraclePack) = pp.getOracleTicks();

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // mint OTM position
        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 4095));

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-955));
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(-955));

        vm.warp(block.timestamp + 63);
        vm.roll(block.number + 1);

        console2.log("safe", pp.isSafeMode());
        vm.startPrank(Alice);

        mintOptions(
            pp,
            $posIdList,
            500_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        (, , int24 slowOracleTickStale, , OraclePack oraclePackStale) = pp.getOracleTicks();

        assertEq(slowOracleTick, slowOracleTickStale, "no slow oracle update");
        assertEq(
            OraclePack.unwrap(oraclePack),
            OraclePack.unwrap(oraclePackStale),
            "no slow oracle update"
        );

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        burnOptions(
            pp,
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        (, , slowOracleTickStale, , oraclePackStale) = pp.getOracleTicks();

        assertTrue(slowOracleTick == slowOracleTickStale, "no slow oracle update");
        assertTrue(
            OraclePack.unwrap(oraclePack) != OraclePack.unwrap(oraclePackStale),
            "oracle median data updated"
        );

        vm.warp(block.timestamp + 64);
        vm.roll(block.number + 1);
        pp.pokeOracle();

        (, , slowOracleTickStale, , oraclePackStale) = pp.getOracleTicks();

        assertTrue(slowOracleTick == slowOracleTickStale, "no slow oracle update");
        assertTrue(
            OraclePack.unwrap(oraclePack) != OraclePack.unwrap(oraclePackStale),
            "oracle median data updated"
        );

        vm.warp(block.timestamp + 64);
        vm.roll(block.number + 1);
        pp.pokeOracle();

        (, , slowOracleTickStale, , oraclePackStale) = pp.getOracleTicks();

        assertTrue(slowOracleTick == slowOracleTickStale, "no slow oracle update");
        assertTrue(
            OraclePack.unwrap(oraclePack) != OraclePack.unwrap(oraclePackStale),
            "oracle median data updated"
        );

        vm.warp(block.timestamp + 64);
        vm.roll(block.number + 1);
        pp.pokeOracle();

        (, , slowOracleTickStale, , oraclePackStale) = pp.getOracleTicks();

        assertTrue(slowOracleTick != slowOracleTickStale, "slow oracle updated");
        assertTrue(
            OraclePack.unwrap(oraclePack) != OraclePack.unwrap(oraclePackStale),
            "oracle median data updated"
        );
    }

    function test_Success_OraclePoke_loop() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);
        (currentTick, , slowOracleTick, , oraclePack) = pp.getOracleTicks();
        vm.warp(0);
        vm.roll(block.number + 1);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeOracle();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -100000, 100000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -100000, 100000, 10 ** 18);
        vm.warp(2 ** 30 - 1);
        vm.roll(block.number + 1);
        console2.log("START");
        pp.pokeOracle();

        (, , slowOracleTick, , oraclePack) = pp.getOracleTicks();

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // mint OTM position
        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 15, 4095));

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-955));
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(-955));

        vm.startPrank(Alice);

        mintOptions(
            pp,
            $posIdList,
            500_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        (, , int24 slowOracleTickStale, , OraclePack oraclePackStale) = pp.getOracleTicks();

        assertEq(slowOracleTick, slowOracleTickStale, "no slow oracle update");
        assertEq(
            OraclePack.unwrap(oraclePack),
            OraclePack.unwrap(oraclePackStale),
            "no slow oracle update"
        );

        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 1);

        burnOptions(
            pp,
            $posIdList[0],
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        (, , slowOracleTickStale, , oraclePackStale) = pp.getOracleTicks();

        assertTrue(slowOracleTick == slowOracleTickStale, "no slow oracle update here?");
        assertTrue(
            OraclePack.unwrap(oraclePack) != OraclePack.unwrap(oraclePackStale),
            "oracle median data updated here?"
        );
    }

    function test_Success_OraclePoke_Max_Deviation() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeOracle();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }

        (currentTick, , , , oraclePack) = pp.getOracleTicks();
        console2.log("currentTick", currentTick);

        // swap to more than MAX_MEDIAN_DELTA ticks away
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(MAX_CLAMP_DELTA + 10));
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(MAX_CLAMP_DELTA + 10));
        swapperc.mint(uniPool, -10000, 10000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -10000, 10000, 10 ** 18);
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 1);
        swapperc.burn(uniPool, -10000, 10000, 10 ** 18);
        pp.pokeOracle();

        (int24 currentTickNew, , int24 slowOracleTickNew, , OraclePack oraclePackNew) = pp
            .getOracleTicks();

        assertEq(
            int24(uint24(OraclePack.unwrap(oraclePack)) % 2 ** 12) + MAX_CLAMP_DELTA,
            int24(uint24(OraclePack.unwrap(oraclePackNew))),
            "uncapped slow oracle update"
        );
    }

    function test_Fuzz_NotionalReverts_shorts(uint128 positionSizeSeed, uint8 x) public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        uint256 n;
        int24 minTick;
        {
            minTick = (-887272 / uniPool.tickSpacing() + 1) * uniPool.tickSpacing();
            int24 maxTick = (887272 / uniPool.tickSpacing()) * uniPool.tickSpacing();
            n = uint256(uint24(maxTick - minTick)) / uint24(1000 * uniPool.tickSpacing());
        }

        vm.startPrank(Bob);
        uint128 positionSize = uint128(PositionUtils._boundLog(positionSizeSeed, 0, 128));

        for (uint256 i = 0; i < n; ++i) {
            // mint OTM position
            int24 strike = int24(minTick + int256(i + 1) * 1000 * uniPool.tickSpacing());

            $tokenIdShort = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                x % 2,
                0,
                (x >> 1) % 2,
                0,
                strike,
                x % 8 == 0 ? int24(0) : int24(2)
            );
            uint128[] memory sizeList = new uint128[](1);
            TokenId[] memory mintList = new TokenId[](1);
            int24[3][] memory tickAndSpreadLimits = new int24[3][](1);

            sizeList[0] = positionSize;
            mintList[0] = $tokenIdShort;
            tickAndSpreadLimits[0][0] = int24(-887272);
            tickAndSpreadLimits[0][1] = int24(887272);
            tickAndSpreadLimits[0][2] = int24(uint24(0));

            // Try to mint and check if it reverts
            try pp.dispatch(mintList, mintList, sizeList, tickAndSpreadLimits, true, 0) {
                // SUCCESS CASE - mintOptions didn't revert
                console2.log("Found non-reverting strike:", strike);

                (, , PositionBalance[] memory positionBalanceArray) = pp
                    .getAccumulatedFeesAndPositionsData(Bob, false, mintList);

                (, currentTick, , , , , ) = uniPool.slot0();

                (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = re.getMargin(
                    positionBalanceArray,
                    currentTick,
                    Bob,
                    mintList,
                    LeftRightUnsigned.wrap(0),
                    LeftRightUnsigned.wrap(0),
                    ct0,
                    ct1
                );
                amountsMoved = PanopticMath.getAmountsMoved($tokenIdShort, positionSize, 0, false);

                console2.log("unwrap", LeftRightUnsigned.unwrap(amountsMoved));
                console2.log("amount.r", amountsMoved.rightSlot());
                console2.log("amount.l", amountsMoved.leftSlot());
                console2.log("tokenData0", tokenData0.rightSlot(), tokenData0.leftSlot());
                console2.log("tokenData1", tokenData1.rightSlot(), tokenData1.leftSlot());
                console2.log("posoitionSize", positionSize);
                (uint256 balanceCross, uint256 requiredCross) = PanopticMath.getCrossBalances(
                    tokenData0,
                    tokenData1,
                    Math.getSqrtRatioAtTick(currentTick)
                );

                assertTrue(
                    (requiredCross > 0) ||
                        (requiredCross == 0 && LeftRightUnsigned.unwrap(amountsMoved) == 0),
                    "zero collateral requirement"
                );
                assertTrue(requiredCross <= balanceCross, "account is solvent");

                burnOptions(pp, mintList, new TokenId[](0), int24(-887272), int24(887272), true);
            } catch (bytes memory reason) {
                if (reason.length >= 4) {
                    bytes4 receivedSelector = bytes4(reason);

                    if (receivedSelector == Errors.ChunkHasZeroLiquidity.selector) {
                        console2.log("ChunkHasZeroLiquidity at strike:", strike);
                    } else if (receivedSelector == Errors.InvalidTickBound.selector) {
                        console2.log("InvalidTickBound at strike:", strike);
                    } else if (receivedSelector == 0x93dafdf1) {
                        console2.log("Uniswap constraint (SafeCastOverflow) at strike:", strike);
                    } else if (receivedSelector == 0xb8e3c385) {
                        console2.log(
                            "Uniswap constraint (TickLiquidityOverflow) at strike:",
                            strike
                        );
                    } else if (receivedSelector == 0x08c379a0) {
                        console2.log("Uniswap constraint at strike:", strike);
                    } else if (receivedSelector == Errors.LiquidityTooHigh.selector) {
                        console2.log("LiquidityTooHigh at strike:", strike);
                    } else if (
                        receivedSelector ==
                        bytes4(
                            abi.encodeWithSelector(
                                Errors.AccountInsolvent.selector,
                                uint256(0),
                                uint256(1)
                            )
                        )
                    ) {
                        console2.log("AccountInsolvent at strike:", strike);
                    } else if (receivedSelector == Errors.PositionTooLarge.selector) {
                        console2.log("PositionTooLarge at strike:", strike);
                        // Position size exceeds protocol limits
                    } else {
                        // Unexpected error
                        console2.logBytes4(receivedSelector);
                        console2.logBytes(reason);
                        revert(string(abi.encodePacked("Unexpected error")));
                    }
                }
            }
        }
    }

    function test_Fuzz_NotionalReverts_longs(uint128 positionSizeSeed, uint8 x) public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        console2.log("uniPool.tickSpacing", uniPool.tickSpacing());
        int24 tickSpacing = 10;
        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(tickSpacing)) << 48;
        }

        uint256 n;
        int24 minTick;
        {
            minTick = (-887272 / tickSpacing + 1) * tickSpacing;
            int24 maxTick = (887272 / tickSpacing) * tickSpacing;
            n = uint256(uint24(maxTick - minTick)) / uint24(1000 * tickSpacing);
        }
        vm.startPrank(Bob);
        uint128 positionSize = uint128(PositionUtils._boundLog(positionSizeSeed, 0, 128));

        $width = x % 8 == 0 ? int24(0) : int24(2);
        for (uint256 i = 0; i < n; ++i) {
            // mint OTM position
            int24 strike = int24(-887270 + int256(i + 1) * 1000 * tickSpacing);

            $tokenIdShort = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                10,
                x % 2,
                0,
                (x >> 1) % 2,
                0,
                strike,
                $width
            );
            uint128[] memory sizeList = new uint128[](1);
            TokenId[] memory mintList = new TokenId[](1);
            int24[3][] memory tickAndSpreadLimits = new int24[3][](1);

            sizeList[0] = positionSize;
            mintList[0] = $tokenIdShort;
            tickAndSpreadLimits[0][0] = int24(-887272);
            tickAndSpreadLimits[0][1] = int24(887272);
            tickAndSpreadLimits[0][2] = int24(uint24(type(uint24).max));

            // Try to mint and check if it reverts
            try pp.dispatch(mintList, mintList, sizeList, tickAndSpreadLimits, true, 0) {
                // SUCCESS CASE - mintOptions didn't revert

                // Alice Buys
                vm.startPrank(Alice);

                {
                    uint256 asset = x % 2;
                    uint256 tokenType = (x >> 1) % 2;
                    uint64 _poolId = poolId;
                    $tokenIdLong = TokenId.wrap(0).addPoolId(_poolId).addLeg(
                        0,
                        9,
                        asset,
                        1,
                        tokenType,
                        0,
                        strike,
                        $width
                    );
                }
                mintList[0] = $tokenIdLong;
                try pp.dispatch(mintList, mintList, sizeList, tickAndSpreadLimits, true, 0) {
                    console2.log("Found non-reverting strike:", strike);
                    (, , PositionBalance[] memory positionBalanceArray) = pp
                        .getAccumulatedFeesAndPositionsData(Alice, false, mintList);

                    (, currentTick, , , , , ) = uniPool.slot0();

                    (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = re.getMargin(
                        positionBalanceArray,
                        currentTick,
                        Alice,
                        mintList,
                        LeftRightUnsigned.wrap(0),
                        LeftRightUnsigned.wrap(0),
                        ct0,
                        ct1
                    );

                    (uint256 balanceCross, uint256 requiredCross) = PanopticMath.getCrossBalances(
                        tokenData0,
                        tokenData1,
                        Math.getSqrtRatioAtTick(currentTick)
                    );

                    assertTrue(
                        (requiredCross > 0) ||
                            (requiredCross == 0 && LeftRightUnsigned.unwrap(amountsMoved) == 0),
                        "zero collateral requirement"
                    );
                    assertTrue(requiredCross <= balanceCross, "account is solvent");

                    burnOptions(
                        pp,
                        mintList,
                        new TokenId[](0),
                        int24(-887272),
                        int24(887272),
                        true
                    );
                } catch (bytes memory reason) {
                    if (reason.length >= 4) {
                        bytes4 receivedSelector = bytes4(reason);
                        if (receivedSelector == Errors.NotEnoughLiquidityInChunk.selector) {
                            console2.log("LONG: NotEnoughLiquidityInChunk at strike:", strike);
                        } else if (
                            receivedSelector == Errors.EffectiveLiquidityAboveThreshold.selector
                        ) {
                            console2.log(
                                "LONG: EffectiveLiquidityAboveThreshold at strike:",
                                strike
                            );
                        } else if (receivedSelector == Errors.NotEnoughTokens.selector) {
                            console2.log("LONG: NotEnoughTokens at strike:", strike);
                        } else if (receivedSelector == Errors.ZeroCollateralRequirement.selector) {
                            console2.log("LONG: ZeroCollateralRequirement at strike:", strike);
                        } else if (receivedSelector == Errors.ChunkHasZeroLiquidity.selector) {
                            console2.log("LONG: ChunkHasZeroLiquidity at strike:", strike);
                        } else if (receivedSelector == Errors.NetLiquidityZero.selector) {
                            console2.log("LONG: NetLiquidityZero at strike:", strike);
                        } else {
                            // Unexpected error
                            console2.logBytes4(receivedSelector);
                            console2.logBytes(reason);
                            revert(string(abi.encodePacked("Unexpected error")));
                        }
                    }
                }

                vm.startPrank(Bob);
                mintList[0] = $tokenIdShort;
                burnOptions(pp, mintList, new TokenId[](0), int24(-887272), int24(887272), true);
            } catch (bytes memory reason) {
                if (reason.length >= 4) {
                    bytes4 receivedSelector = bytes4(reason);

                    if (receivedSelector == Errors.ChunkHasZeroLiquidity.selector) {
                        console2.log("ChunkHasZeroLiquidity at strike:", strike);
                    } else if (receivedSelector == Errors.InvalidTickBound.selector) {
                        console2.log("InvalidTickBound at strike:", strike);
                    } else if (receivedSelector == 0x93dafdf1) {
                        console2.log("Uniswap constraint (SafeCastOverflow) at strike:", strike);
                    } else if (receivedSelector == 0xb8e3c385) {
                        console2.log(
                            "Uniswap constraint (TickLiquidityOverflow) at strike:",
                            strike
                        );
                    } else if (receivedSelector == 0x08c379a0) {
                        console2.log("Uniswap constraint at strike:", strike);
                    } else if (receivedSelector == Errors.LiquidityTooHigh.selector) {
                        console2.log("LiquidityTooHigh at strike:", strike);
                    } else if (receivedSelector == Errors.NotEnoughLiquidityInChunk.selector) {
                        console2.log("NotEnoughLiquidityInChunk at strike:", strike);
                    } else if (
                        receivedSelector ==
                        bytes4(
                            abi.encodeWithSelector(
                                Errors.AccountInsolvent.selector,
                                uint256(0),
                                uint256(1)
                            )
                        )
                    ) {
                        console2.log("AccountInsolvent at strike:", strike);
                    } else if (receivedSelector == Errors.PositionTooLarge.selector) {
                        console2.log("PositionTooLarge at strike:", strike);
                        // Position size exceeds protocol limits
                    } else {
                        // Unexpected error
                        console2.logBytes4(receivedSelector);
                        console2.logBytes(reason);
                        revert(string(abi.encodePacked("Unexpected error")));
                    }
                }
            }
        }
    }

    function test_Fuzz_NotionalReverts_spreads(uint128 positionSizeSeed, uint8 x) public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        $poolId = poolId;
        uint256 n;
        {
            int24 minTick;
            {
                minTick = (-887272 / uniPool.tickSpacing() + 1) * uniPool.tickSpacing();
                int24 maxTick = (887272 / uniPool.tickSpacing()) * uniPool.tickSpacing();
                n = uint256(uint24(maxTick - minTick)) / uint24(1000 * uniPool.tickSpacing());
            }
        }
        vm.startPrank(Bob);
        uint128 positionSize = uint128(PositionUtils._boundLog(positionSizeSeed, 0, 128));
        uint256 asset = x % 2;
        uint256 tokenType = (x >> 1) % 2;

        for (uint256 i = 0; i < n; ++i) {
            // mint OTM position
            $strike = int24(-887270 + int256(i + 1) * 1000 * uniPool.tickSpacing());

            $tokenIdShort = TokenId.wrap(0).addPoolId($poolId).addLeg(
                0,
                100,
                asset,
                0,
                tokenType,
                0,
                $strike,
                2
            );
            uint128[] memory sizeList = new uint128[](1);
            TokenId[] memory mintList = new TokenId[](1);
            int24[3][] memory tickAndSpreadLimits = new int24[3][](1);

            sizeList[0] = positionSize;
            mintList[0] = $tokenIdShort;
            tickAndSpreadLimits[0][0] = int24(-887272);
            tickAndSpreadLimits[0][1] = int24(887272);
            tickAndSpreadLimits[0][2] = int24(uint24(type(uint24).max));

            // Try to mint and check if it reverts
            try pp.dispatch(mintList, mintList, sizeList, tickAndSpreadLimits, true, 0) {
                // SUCCESS CASE - mintOptions didn't revert
                // Alice Buys
                vm.startPrank(Alice);

                {
                    uint256 _asset = asset;
                    uint256 _tokenType = tokenType;
                    $tokenIdLong = TokenId
                        .wrap(0)
                        .addPoolId($poolId)
                        .addLeg(0, 89, _asset, 1, _tokenType, 1, $strike, 2)
                        .addLeg(
                            1,
                            89,
                            _asset,
                            0,
                            _tokenType,
                            0,
                            $strike + uniPool.tickSpacing(),
                            2
                        );
                }
                mintList[0] = $tokenIdLong;
                try pp.dispatch(mintList, mintList, sizeList, tickAndSpreadLimits, true, 0) {
                    console2.log("Found non-reverting strike:", $strike);
                    (, , PositionBalance[] memory positionBalanceArray) = pp
                        .getAccumulatedFeesAndPositionsData(Alice, false, mintList);

                    (, currentTick, , , , , ) = uniPool.slot0();

                    {
                        (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = re
                            .getMargin(
                                positionBalanceArray,
                                currentTick,
                                Alice,
                                mintList,
                                LeftRightUnsigned.wrap(0),
                                LeftRightUnsigned.wrap(0),
                                ct0,
                                ct1
                            );

                        (uint256 balanceCross, uint256 requiredCross) = PanopticMath
                            .getCrossBalances(
                                tokenData0,
                                tokenData1,
                                Math.getSqrtRatioAtTick(currentTick)
                            );

                        assertTrue(requiredCross > 0, "zero collateral requirement");
                        assertTrue(requiredCross <= balanceCross, "account is solvent");

                        (int256 iamount0, int256 iamount1) = ph.getPortfolioValue(
                            pp,
                            Alice,
                            $strike - uniPool.tickSpacing() * 2,
                            mintList
                        );
                        (iamount0, iamount1) = ph.getPortfolioValue(
                            pp,
                            Alice,
                            $strike + uniPool.tickSpacing() * 2,
                            mintList
                        );

                        console2.log("");
                    }

                    burnOptions(
                        pp,
                        mintList,
                        new TokenId[](0),
                        int24(-887272),
                        int24(887272),
                        true
                    );
                } catch (bytes memory reason) {
                    if (reason.length >= 4) {
                        bytes4 receivedSelector = bytes4(reason);
                        if (receivedSelector == Errors.NotEnoughLiquidityInChunk.selector) {
                            console2.log("LONG: NotEnoughLiquidityInChunk at strike:", $strike);
                        } else if (
                            receivedSelector == Errors.EffectiveLiquidityAboveThreshold.selector
                        ) {
                            console2.log(
                                "LONG: EffectiveLiquidityAboveThreshold at strike:",
                                $strike
                            );
                        } else if (
                            receivedSelector ==
                            bytes4(
                                abi.encodeWithSelector(
                                    Errors.AccountInsolvent.selector,
                                    uint256(0),
                                    uint256(1)
                                )
                            )
                        ) {
                            console2.log("SPREAD: AccountInsolvent at strike:", $strike);
                        } else if (receivedSelector == Errors.NotEnoughTokens.selector) {
                            console2.log("SPREAD: NotEnoughTokens at strike:", $strike);
                        } else if (receivedSelector == Errors.ZeroCollateralRequirement.selector) {
                            console2.log("SPREAD: ZeroCollateralRequirement at strike:", $strike);
                        } else if (receivedSelector == Errors.ChunkHasZeroLiquidity.selector) {
                            console2.log("SPREAD: ChunkHasZeroLiquidity at strike:", $strike);
                        } else if (receivedSelector == Errors.NetLiquidityZero.selector) {
                            console2.log("SPREAD: NetLiquidityZero at strike:", $strike);
                        } else if (receivedSelector == Errors.PositionTooLarge.selector) {
                            console2.log("SPREAD: PositionTooLarge at strike:", $strike);
                        } else {
                            // Unexpected error
                            console2.logBytes4(receivedSelector);
                            console2.logBytes(reason);
                            revert(string(abi.encodePacked("Unexpected error Spread")));
                        }
                    }
                }

                vm.startPrank(Bob);
                mintList[0] = $tokenIdShort;
                burnOptions(pp, mintList, new TokenId[](0), int24(-887272), int24(887272), true);
            } catch (bytes memory reason) {
                if (reason.length >= 4) {
                    bytes4 receivedSelector = bytes4(reason);

                    if (receivedSelector == Errors.ChunkHasZeroLiquidity.selector) {
                        console2.log("ChunkHasZeroLiquidity at strike:", $strike);
                    } else if (receivedSelector == Errors.InvalidTickBound.selector) {
                        console2.log("InvalidTickBound at strike:", $strike);
                    } else if (receivedSelector == 0xb8e3c385) {
                        console2.log(
                            "Uniswap constraint (TickLiquidityOverflow) at strike:",
                            $strike
                        );
                    } else if (receivedSelector == 0x93dafdf1) {
                        console2.log("Uniswap constraint (SafeCastOverflow) at strike:", $strike);
                    } else if (receivedSelector == 0x08c379a0) {
                        console2.log("Uniswap constraint at strike:", $strike);
                    } else if (receivedSelector == Errors.LiquidityTooHigh.selector) {
                        console2.log("LiquidityTooHigh at strike:", $strike);
                    } else if (receivedSelector == Errors.NotEnoughLiquidityInChunk.selector) {
                        console2.log("NotEnoughLiquidityInChunk at strike:", $strike);
                    } else if (
                        receivedSelector ==
                        bytes4(
                            abi.encodeWithSelector(
                                Errors.AccountInsolvent.selector,
                                uint256(0),
                                uint256(1)
                            )
                        )
                    ) {
                        console2.log("AccountInsolvent at strike:", $strike);
                    } else if (receivedSelector == Errors.PositionTooLarge.selector) {
                        console2.log("PositionTooLarge at strike:", $strike);
                        // Position size exceeds protocol limits
                    } else {
                        // Unexpected error
                        console2.logBytes4(receivedSelector);
                        console2.logBytes(reason);
                        revert(string(abi.encodePacked("Unexpected error Mint")));
                    }
                }
            }
        }
    }

    function test_success_PremiumRollover() public {
        vm.startPrank(Swapper);
        // JIT a bunch of liquidity so swaps at mint can happen normally
        swapperc.mint(uniPool, -10, 10, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -100000, 100000, 10 ** 18);

        // L = 1
        uniPool.liquidity();

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        TokenId tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, 0, 4094);

        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = tokenId;

        vm.startPrank(Bob);
        // mint 1 liquidity unit of wideish centered position
        mintOptions(pp, posIdList, 3, 0, Constants.MAX_POOL_TICK, Constants.MIN_POOL_TICK, true);

        vm.startPrank(Swapper);
        swapperc.burn(uniPool, -10, 10, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -100000, 100000, -10 ** 18);

        // L = 2
        uniPool.liquidity();

        // accumulate the maximum fees per liq SFPM supports
        accruePoolFeesInRange(manager, poolKey, 1, 2 ** 64 - 1, 0);

        vm.startPrank(Swapper);
        swapperc.mint(uniPool, -10, 10, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -100000, 100000, 10 ** 18);

        vm.startPrank(Bob);
        // works fine
        burnOptions(
            pp,
            tokenId,
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        uint256 balanceBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        uint256 balanceBefore1 = ct1.convertToAssets(ct1.balanceOf(Alice));

        vm.startPrank(Alice);

        // lock in almost-overflowed fees per liquidity
        mintOptions(
            pp,
            posIdList,
            1_000_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.startPrank(Swapper);
        swapperc.burn(uniPool, -10, 10, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -100000, 100000, -10 ** 18);

        // overflow back to ~1_000_000_000_000 (fees per liq)
        accruePoolFeesInRange(manager, poolKey, 412639631, 1_000_000_000_000, 1_000_000_000_000);

        // this should behave like the actual accumulator does and rollover, not revert on overflow
        (uint256 premium0, uint256 premium1) = sfpm.getAccountPremium(
            abi.encode(poolKey),
            address(pp),
            0,
            -20470,
            20470,
            0,
            0,
            vegoid
        );
        assertEq(premium0, 340282366920938463444927863358058659840);
        assertEq(premium1, 44704247211996718928643);

        vm.startPrank(Swapper);
        swapperc.mint(uniPool, -10, 10, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -100000, 100000, 10 ** 18);
        vm.startPrank(Alice);

        // tough luck... PLPs just stole ~2**64 tokens per liquidity Alice had because of an overflow
        // Alice can be frontrun if her transaction goes to a public mempool (or is otherwise anticipated),
        // so the cost of the attack is just ~2**64 * active liquidity (shown here to be as low as 1 even with initial full-range!)
        // + fee to move price initially (if applicable)
        // The solution is to freeze fee accumulation if one of the token accumulators overflow
        burnOptions(
            pp,
            tokenId,
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        // make sure Alice earns no fees on token 0 (her delta is slightly negative due to commission fees/precision etc)
        // the accumulator overflowed, so the accumulation was frozen. If she had poked before the accumulator overflowed,
        // she could have still earned some fees, but now the accumulation is frozen forever.
        // old with itmSpreadFee = -864427
        assertEq(
            int256(ct0.convertToAssets(ct0.balanceOf(Alice))) - int256(balanceBefore0),
            -864427
        );

        // but she earns all of fees on token 1 since the premium accumulator did not overflow (!)
        assertEq(
            int256(ct1.convertToAssets(ct1.balanceOf(Alice))) - int256(balanceBefore1),
            999_999_999_998
        );
    }

    function test_Success_ReverseIronCondor() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        swapperc.mint(uniPool, -10, 10, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -100000, 100000, 10 ** 24);

        vm.startPrank(Seller);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        $posIdList.push(
            TokenId
                .wrap(0)
                .addPoolId(poolId)
                .addLeg(
                    0,
                    1,
                    1,
                    0,
                    1,
                    0,
                    4055, // 1.5 put
                    1
                )
                .addLeg(
                    1,
                    1,
                    1,
                    0,
                    0,
                    1,
                    -6935, // 0.5 call
                    1
                )
        );

        mintOptions(
            pp,
            $posIdList,
            2_000_000,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // long put = 1.5, short put 1.25, short call 0.75, long call 0.5
        $posIdList[0] = TokenId
            .wrap(0)
            .addPoolId(poolId)
            .addLeg(0, 1, 1, 1, 1, 0, 4055, 1)
            .addLeg(1, 1, 1, 0, 1, 1, 2235, 1)
            .addLeg(2, 1, 1, 0, 0, 2, -2875, 1)
            .addLeg(3, 1, 1, 1, 0, 3, -6935, 1);

        uint256 balanceBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        uint256 balanceBefore1 = ct1.convertToAssets(ct1.balanceOf(Alice));

        vm.startPrank(Alice);

        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            type(uint24).max,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    function test_Success_CallCondor() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // setup mini-median price array
        for (uint256 i = 0; i < 10; ++i) {
            swapperc.mint(uniPool, -10, 10, 10 ** 18);
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 1);
            pp.pokeOracle();
            swapperc.burn(uniPool, -10, 10, 10 ** 18);
        }
        swapperc.mint(uniPool, -10, 10, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -100000, 100000, 10 ** 24);

        vm.startPrank(Seller);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        $posIdList.push(
            TokenId
                .wrap(0)
                .addPoolId(poolId)
                .addLeg(
                    0,
                    1,
                    0,
                    0,
                    0,
                    0,
                    12235, // 1.25 call
                    1
                )
                .addLeg(
                    1,
                    1,
                    0,
                    0,
                    0,
                    1,
                    46935, // 2 call
                    1
                )
        );

        mintOptions(
            pp,
            $posIdList,
            2_000_000,
            0,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // long call = 1.25, short call = 1.5, short call = 1.75, long call = 2
        $posIdList[0] = TokenId
            .wrap(0)
            .addPoolId(poolId)
            .addLeg(0, 1, 0, 1, 0, 0, 12235, 1)
            .addLeg(1, 1, 0, 0, 0, 1, 24055, 1)
            .addLeg(2, 1, 0, 0, 0, 2, 35595, 1)
            .addLeg(3, 1, 0, 1, 0, 3, 46935, 1);

        uint256 balanceBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        uint256 balanceBefore1 = ct1.convertToAssets(ct1.balanceOf(Alice));

        vm.startPrank(Alice);

        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            type(uint24).max,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );
    }

    function test_Success_PutCondor() public {
        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        swapperc.mint(uniPool, -10, 10, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -100000, 100000, 10 ** 24);

        vm.startPrank(Seller);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        $posIdList.push(
            TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                1,
                0,
                1,
                0,
                -13_865, // 0.25 put
                1
            )
        );

        mintOptions(
            pp,
            $posIdList,
            2_000_000,
            0,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        // long put = 0.25, short put = 0.5, short put = 0.75, short call = 0.9
        $posIdList[0] = TokenId
            .wrap(0)
            .addPoolId(poolId)
            .addLeg(0, 1, 1, 1, 1, 0, -13_865, 1)
            .addLeg(1, 1, 1, 0, 1, 1, -6935, 1)
            .addLeg(2, 1, 1, 0, 1, 2, -2875, 1)
            .addLeg(3, 1, 1, 0, 0, 3, -1055, 1);

        uint256 balanceBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        uint256 balanceBefore1 = ct1.convertToAssets(ct1.balanceOf(Alice));

        vm.startPrank(Alice);

        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            type(uint24).max,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );
    }

    function test_success_liquidate_100p_protocolLoss() public {
        _createPanopticPool();
        vm.startPrank(Alice);

        token1.mint(Alice, 1_000_000);

        token1.approve(address(ct1), 1_000_000);

        ct1.deposit(1_000_000, Alice);

        vm.startPrank(Bob);

        token0.mint(Bob, type(uint104).max);

        token0.approve(address(ct0), type(uint104).max);

        ct0.deposit(1_500_000, Bob);

        token1.mint(Bob, 1_005);
        token1.approve(address(ct1), 1_005);
        ct1.deposit(1_005, Bob);

        console2.log("ct0.balance", ct0.balanceOf(Bob));
        console2.log("ct1.balance", ct1.balanceOf(Bob));
        vm.startPrank(Charlie);
        token0.mint(Charlie, 1);
        token0.approve(address(ct0), 1);
        token1.mint(Charlie, 1_003_004);
        token1.approve(address(ct1), 1_003_004);

        ct1.deposit(1_003_003, Charlie);

        vm.startPrank(Bob);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 1, 0, -15, 1));

        uint256 totalSupplyBefore = ct1.totalSupply() - ct1.convertToShares(1_003_003);

        mintOptions(
            pp,
            $posIdList,
            1_003_003,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        console2.log("ct0.balance", ct0.balanceOf(Bob));
        console2.log("ct1.balance", ct1.balanceOf(Bob));

        vm.startPrank(Swapper);
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(-500_000));
        for (uint256 j = 0; j < 10000; ++j) {
            vm.warp(block.timestamp + 3600);
            vm.roll(block.number + 10);
            pp.pokeOracle();
        }
        (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, oraclePack) = pp
            .getOracleTicks();
        twapTick = re.twapEMA(oraclePack);
        console2.log("cur", currentTick);
        console2.log("twapTick", twapTick);

        vm.startPrank(Charlie);
        console2.log("tokem0", address(token0));
        console2.log("tokem1", address(token1));
        console2.log("balanceC1", token1.balanceOf(Charlie));
        liquidate(pp, new TokenId[](0), Bob, $posIdList);

        assertLe(ct1.totalSupply() / totalSupplyBefore, 10_000, "protocol loss failed to cap");
    }

    function test_success_liquidation_fuzzedSwapITM(uint256[4] memory prices) public {
        vm.startPrank(Swapper);
        // JIT a bunch of liquidity so swaps at mint can happen normally
        swapperc.mint(uniPool, -887270, 887270, 10 ** 24);
        routerV4.modifyLiquidity(address(0), poolKey, -887270, 887270, 10 ** 24);

        // L = 1
        uniPool.liquidity();

        uint256 snapshot = vm.snapshot();

        /// @dev single leg, liquidation through price move making options ITM, no-cross collateral
        for (uint256 i; i < 4; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = i / 2;

            {
                poolId =
                    uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                    uint64(uint256(vegoid) << 40);
                poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
            }

            TokenId tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                asset,
                0,
                tokenType,
                0,
                0,
                2
            );

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            if (tokenType == 0) {
                token0.approve(address(ct0), 1000);
                ct0.deposit(1000, Bob);
            } else {
                token1.approve(address(ct1), 1000);
                ct1.deposit(1000, Bob);
            }
            // mint 1 liquidity unit of wideish centered position

            mintOptions(
                pp,
                posIdList,
                3000,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            // get base (OTM) collateral requirement for the position we just minted
            // uint256 basalCR;

            // amount of tokens borrowed to create position -- also amount of tokenType when OTM
            // uint256 amountBorrowed;

            // amount of other token when deep ITM
            // uint256 amountITM;
            (, , , uint256 _utilization) = tokenType == 0 ? ct0.getPoolData() : ct1.getPoolData();

            util = int256(_utilization);
            amountsMoved = PanopticMath.getAmountsMoved(tokenId, 3000, 0, false);
            (amountBorrowed, amountITM) = tokenType == 0
                ? (amountsMoved.rightSlot(), amountsMoved.leftSlot())
                : (amountsMoved.leftSlot(), amountsMoved.rightSlot());
            basalCR = (getSCR(util) * amountBorrowed) / 10_000;

            // compute ITM collateral requirement we would need for the position to be liquidatable
            remainingCR =
                (
                    tokenType == 0
                        ? ct0.convertToAssets(ct0.balanceOf(Bob))
                        : ct1.convertToAssets(ct1.balanceOf(Bob))
                ) -
                basalCR;

            // find price where the difference between the borrowed tokens and the value of the LP position is equal to the remaining collateral requirement (the "liquidation price")
            // unless this is an extremely wide/full-range position, this will be deep ITM
            sqrtPriceTargetX96 = uint160(
                tokenType == 0
                    ? FixedPointMathLib.sqrt(
                        Math.mulDiv(amountITM, 2 ** 192, amountBorrowed - remainingCR - 1)
                    )
                    : FixedPointMathLib.sqrt(
                        Math.mulDiv(amountBorrowed - remainingCR - 1, 2 ** 192, amountITM)
                    )
            );

            vm.startPrank(Swapper);

            // swap to somewhere between the liquidation price and maximum/minimum prices
            // limiting "max/min prices" to reasonable levels for now because protocol breaks at tail ends of AMM curve (can't handle >2**128 tokens)
            swapperc.swapTo(
                uniPool,
                uint160(
                    bound(
                        prices[i],
                        tokenType == 0 ? sqrtPriceTargetX96 * 2 : sqrtPriceTargetX96 / 5,
                        tokenType == 0 ? sqrtPriceTargetX96 * 5 : sqrtPriceTargetX96 / 2
                    )
                )
            );
            routerV4.swapTo(
                address(0),
                poolKey,
                uint160(
                    bound(
                        prices[i],
                        tokenType == 0 ? sqrtPriceTargetX96 * 2 : sqrtPriceTargetX96 / 5,
                        tokenType == 0 ? sqrtPriceTargetX96 * 5 : sqrtPriceTargetX96 / 2
                    )
                )
            );

            (, currentTick, , , , , ) = uniPool.slot0();
            (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                .checkCollateral(pp, Bob, currentTick, posIdList);

            console2.log(
                "totalCollateralBalance0, totalCollateralRequired0",
                totalCollateralBalance0,
                totalCollateralRequired0
            );
            assertTrue(totalCollateralBalance0 <= totalCollateralRequired0, "Is liquidatable! 2");

            // update twaps
            for (uint256 j = 0; j < 250; ++j) {
                vm.warp(block.timestamp + 3600);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 10);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 10);
                pp.pokeOracle();
            }

            // deal alice a bunch of collateral tokens without touching the supply
            editCollateral(ct0, Alice, ct0.convertToShares(type(uint120).max));
            editCollateral(ct1, Alice, ct1.convertToShares(type(uint120).max));
            // update twaps
            for (uint256 j = 0; j < 250; ++j) {
                vm.warp(block.timestamp + 3600);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
                pp.pokeOracle();
            }
            (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, oraclePack) = pp
                .getOracleTicks();
            twapTick = re.twapEMA(oraclePack);
            console2.log("cur", currentTick);
            console2.log("twapTick", twapTick);

            vm.startPrank(Alice);
            liquidate(pp, new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }
    }

    function test_Fail_DivergentSolvencyCheck_mint() public {
        vm.startPrank(Swapper);
        // JIT a bunch of liquidity so swaps at mint can happen normally
        swapperc.mint(uniPool, -1000, 1000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -1000, 1000, 10 ** 18);

        // L = 1
        uniPool.liquidity();

        uint256 asset = 0;
        uint256 tokenType = 0;

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        TokenId tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
            0,
            1,
            asset,
            0,
            tokenType,
            0,
            0,
            2
        );

        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = tokenId;

        (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, ) = pp.getOracleTicks();

        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(int24(currentTick) + 950));
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(int24(currentTick) + 950));

        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
        swapperc.burn(uniPool, -887200, 887200, 10 ** 18);

        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
        swapperc.burn(uniPool, -887200, 887200, 10 ** 18);

        (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, ) = pp.getOracleTicks();

        assertTrue(pp.isSafeMode() == 0, "not in safe mode");

        assertTrue(
            int256(fastOracleTick - slowOracleTick) ** 2 +
                int256(lastObservedTick - slowOracleTick) ** 2 +
                int256(currentTick - slowOracleTick) ** 2 >
                int256(953) ** 2,
            "will check at multiple ticks"
        );

        vm.startPrank(Bob);
        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        if (tokenType == 0) {
            token0.approve(address(ct0), 1000);
            ct0.deposit(600, Bob);
        } else {
            token1.approve(address(ct1), 1000);
            //ct1.deposit(0, Bob);
        }

        vm.startPrank(Bob);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.AccountInsolvent.selector,
                uint256(3), // solvent
                uint256(4) // numberOfTicks
            )
        );
        mintOptions(pp, posIdList, 3000, 0, Constants.MAX_POOL_TICK, Constants.MIN_POOL_TICK, true);
    }

    function test_Fail_DivergentSolvencyCheck_burn() public {
        vm.startPrank(Swapper);
        // JIT a bunch of liquidity so swaps at mint can happen normally
        swapperc.mint(uniPool, -1000, 1000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -1000, 1000, 10 ** 18);

        // L = 1
        uniPool.liquidity();

        /// @dev single leg, wide atm call, liquidation through price move making options ITM, no-cross collateral

        uint256 asset = 0;
        uint256 tokenType = 0;

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        TokenId tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
            0,
            1,
            asset,
            0,
            tokenType,
            0,
            0,
            2
        );

        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = tokenId;

        vm.startPrank(Bob);
        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        if (tokenType == 0) {
            token0.approve(address(ct0), 1650);
            ct0.deposit(850, Bob);
        } else {
            token1.approve(address(ct1), 1000);
            //ct1.deposit(0, Bob);
        }

        vm.startPrank(Bob);

        mintOptions(pp, posIdList, 3000, 0, Constants.MAX_POOL_TICK, Constants.MIN_POOL_TICK, true);

        TokenId[] memory posIdList2 = new TokenId[](2);

        posIdList2[0] = tokenId;

        TokenId tokenId2 = TokenId.wrap(0).addPoolId(poolId).addLeg(
            0,
            2,
            asset,
            0,
            tokenType,
            0,
            0,
            2
        );

        posIdList2[1] = tokenId2;

        // mint second option
        mintOptions(pp, posIdList2, 10, 0, Constants.MAX_POOL_TICK, Constants.MIN_POOL_TICK, true);

        (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, ) = pp.getOracleTicks();

        vm.startPrank(Swapper);
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(int24(currentTick) + 954));
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(int24(currentTick) + 954));

        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
        swapperc.burn(uniPool, -887200, 887200, 10 ** 18);

        vm.warp(block.timestamp + 13);
        vm.roll(block.number + 1);
        swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
        swapperc.burn(uniPool, -887200, 887200, 10 ** 18);

        (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, ) = pp.getOracleTicks();

        assertTrue(pp.isSafeMode() == 0, "not in safe mode");

        assertTrue(
            int256(fastOracleTick - slowOracleTick) ** 2 +
                int256(lastObservedTick - slowOracleTick) ** 2 +
                int256(currentTick - slowOracleTick) ** 2 >
                int256(953) ** 2,
            "will check at multiple ticks"
        );

        vm.startPrank(Bob);

        // burn second option
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.AccountInsolvent.selector,
                uint256(3), // solvent
                uint256(4) // numberOfTicks
            )
        );
        burnOptions(
            pp,
            posIdList2[1],
            posIdList,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    function test_Fail_DivergentSolvencyCheck_liquidation() public {
        vm.startPrank(Swapper);
        // JIT a bunch of liquidity so swaps at mint can happen normally
        swapperc.mint(uniPool, -1000, 1000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -1000, 1000, 10 ** 18);

        // L = 1
        uniPool.liquidity();

        /// @dev single leg, wide atm call, liquidation through price move making options ITM, no-cross collateral

        uint256 asset = 0;
        uint256 tokenType = 0;

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }
        TokenId tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
            0,
            1,
            asset,
            0,
            tokenType,
            0,
            0,
            100
        );

        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = tokenId;

        (, currentTick, , , , , ) = uniPool.slot0();

        vm.startPrank(Bob);
        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        if (tokenType == 0) {
            token0.approve(address(ct0), 1000);
            ct0.deposit(1000, Bob);
        } else {
            token1.approve(address(ct1), 1000);
            ct1.deposit(1000, Bob);
        }

        mintOptions(pp, posIdList, 3000, 0, Constants.MAX_POOL_TICK, Constants.MIN_POOL_TICK, true);

        (, currentTick, , , , , ) = uniPool.slot0();

        (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            posIdList
        );

        assertTrue(totalCollateralBalance0 >= totalCollateralRequired0, "Is not liquidatable");

        vm.startPrank(Swapper);

        // swap to 1.21 or 0.82, depending on tokenType
        swapperc.swapTo(
            uniPool,
            tokenType == 0 ? 89150978765690778389772763136 : 70025602285694849958832766976
        );
        routerV4.swapTo(
            address(0),
            poolKey,
            tokenType == 0 ? 89150978765690778389772763136 : 70025602285694849958832766976
        );

        (, currentTick, , , , , ) = uniPool.slot0();

        (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            posIdList
        );

        assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable! 1");

        // update twaps
        for (uint256 j = 0; j < 100; ++j) {
            vm.warp(block.timestamp + 120);
            vm.roll(block.number + 10);
            swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
            swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            pp.pokeOracle();
        }

        (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, oraclePack) = pp
            .getOracleTicks();
        twapTick = re.twapEMA(oraclePack);
        {
            (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
                pp,
                Bob,
                int24(twapTick),
                posIdList
            );

            assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable twap!");
        }

        (currentTick, fastOracleTick, , lastObservedTick, ) = pp.getOracleTicks();

        {
            (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
                pp,
                Bob,
                fastOracleTick,
                posIdList
            );
            assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable fast!");

            (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
                pp,
                Bob,
                lastObservedTick,
                posIdList
            );

            assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable last!");

            swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(int24(twapTick) - 500));
            routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(int24(twapTick) - 500));
            (currentTick, , , , ) = pp.getOracleTicks();

            (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
                pp,
                Bob,
                currentTick,
                posIdList
            );
            console2.log(
                "totalCollateralBalance0,totalCollateralRequired0",
                totalCollateralBalance0,
                totalCollateralRequired0
            );

            console2.log("curren", currentTick);
            console2.log("fat", fastOracleTick);
            console2.log("lastOv", lastObservedTick);
            console2.log("twap", twapTick);
            assertTrue(
                totalCollateralBalance0 > totalCollateralRequired0,
                "Is NOT liquidatable current!"
            );
        }

        vm.startPrank(Alice);

        vm.expectRevert(Errors.NotMarginCalled.selector);
        liquidate(pp, new TokenId[](0), Bob, posIdList);
    }

    function test_success_liquidation_currentTick_bonusOptimization_scenarios() public {
        vm.startPrank(Swapper);
        // JIT a bunch of liquidity so swaps at mint can happen normally
        routerV4.modifyLiquidity(address(0), poolKey, -1000, 1000, 10 ** 18);

        /// @dev single leg, wide atm call, liquidation through price move making options ITM, no-cross collateral

        uint256 asset = 0;
        uint256 tokenType = 0;

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        TokenId tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
            0,
            1,
            asset,
            0,
            tokenType,
            0,
            0,
            100
        );

        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = tokenId;

        currentTick = sfpm.getCurrentTick(abi.encode(poolKey));

        vm.startPrank(Bob);
        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        if (tokenType == 0) {
            token0.approve(address(ct0), 1000);
            ct0.deposit(900, Bob);
        } else {
            token1.approve(address(ct1), 1000);
            ct1.deposit(900, Bob);
        }

        mintOptions(pp, posIdList, 3000, 0, Constants.MAX_POOL_TICK, Constants.MIN_POOL_TICK, true);

        currentTick = sfpm.getCurrentTick(abi.encode(poolKey));

        (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            posIdList
        );

        assertTrue(totalCollateralBalance0 >= totalCollateralRequired0, "Is not liquidatable");

        vm.startPrank(Swapper);

        // swap to 1.21 or 0.82, depending on tokenType
        routerV4.swapTo(
            address(0),
            poolKey,
            tokenType == 0 ? 87150978765690778389772763136 : 72025602285694849958832766976
        );

        currentTick = sfpm.getCurrentTick(abi.encode(poolKey));

        (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            posIdList
        );

        console2.log(
            "totalCollateralBalance0, totalCollateralRequired0",
            totalCollateralBalance0,
            totalCollateralRequired0
        );
        assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable! 0");

        // update twaps
        for (uint256 j = 0; j < 100; ++j) {
            vm.warp(block.timestamp + 3600);
            vm.roll(block.number + 10);
            swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
            swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            pp.pokeOracle();
        }

        (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, oraclePack) = pp
            .getOracleTicks();
        twapTick = re.twapEMA(oraclePack);
        {
            (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
                pp,
                Bob,
                int24(twapTick),
                posIdList
            );

            assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable twap!");
        }

        (, uint256 liquidatorBalance1) = (
            ct0.convertToAssets(ct0.balanceOf(Alice)),
            ct1.convertToAssets(ct1.balanceOf(Alice))
        );

        int256 maxBonus1;

        int256 maxTick;
        uint256 snapshot = vm.snapshot();

        for (int24 t = -350; t <= 510; t += 10) {
            // swap to 1.21*1.05 or 0.82/1.05, depending on tokenType
            vm.startPrank(Swapper);
            routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(int24(twapTick) + t));

            vm.startPrank(Alice);
            liquidate(pp, new TokenId[](0), Bob, posIdList);

            unchecked {
                if (
                    int256(ct1.convertToAssets(ct1.balanceOf(Alice)) - liquidatorBalance1) >
                    maxBonus1
                ) {
                    maxBonus1 = int256(
                        ct1.convertToAssets(ct1.balanceOf(Alice)) - liquidatorBalance1
                    );
                    maxTick = twapTick + t;
                }
            }
            vm.revertTo(snapshot);
        }

        console2.log("maxBonus1", maxBonus1);
        console2.log("twapTick", twapTick);
        console2.log("maxTick", maxTick);
    }

    function test_success_liquidation_interest_stale_scenarios() public {
        vm.startPrank(Swapper);
        // JIT a bunch of liquidity so swaps at mint can happen normally
        routerV4.modifyLiquidity(address(0), poolKey, -600000, 600000, 10 ** 18);

        /// @dev Alice sells a call, Bob buys it. Bob sells a large straddle as well. Bob owes a lot of long premia on that call, enought to trigger the haircut branch, but received none fron that straddle. He also has to pay of lot of interest for that straddle, so the loss will be capped/avoided?

        uint256 asset = 0;
        uint256 tokenType = 0;

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }
        int24 tickSpacing = uniPool.tickSpacing();
        TokenId tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
            0,
            1,
            asset,
            0,
            tokenType,
            0,
            (currentTick / tickSpacing) * tickSpacing,
            2
        );

        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = tokenId;
        vm.startPrank(Alice);
        mintOptions(
            pp,
            posIdList,
            10 ** 12,
            0,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        currentTick = sfpm.getCurrentTick(abi.encode(poolKey));

        console2.log("currentTick", currentTick);

        vm.startPrank(Bob);

        TokenId tokenIdLong = TokenId.wrap(0).addPoolId(poolId).addLeg(
            0,
            1,
            asset,
            1,
            tokenType,
            0,
            (currentTick / tickSpacing) * tickSpacing,
            2
        );

        $posIdList.push(tokenIdLong);

        console2.log("");
        console2.log("Bob mint");
        mintOptions(
            pp,
            $posIdList,
            9 * 10 ** 11,
            type(uint24).max,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        TokenId tokenIdStraddle;
        {
            tokenIdStraddle = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                asset,
                0,
                tokenType,
                0,
                (currentTick / tickSpacing) * tickSpacing + 100 * tickSpacing,
                2
            );
            tokenIdStraddle = tokenIdStraddle.addLeg(
                1,
                1,
                asset,
                0,
                1 - tokenType,
                1,
                (currentTick / tickSpacing) * tickSpacing + 100 * tickSpacing,
                2
            );
        }
        $posIdList.push(tokenIdStraddle);

        mintOptions(
            pp,
            $posIdList,
            10 ** 24,
            0,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        currentTick = sfpm.getCurrentTick(abi.encode(poolKey));

        editCollateral(ct0, Bob, ct0.convertToShares(421033078520736539448040 / 2));
        editCollateral(ct1, Bob, ct1.convertToShares(421033078520736539448040 / 2));

        (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            $posIdList
        );
        console2.log(
            "totalCollateralBalance0, totalCollateralRequired0",
            totalCollateralBalance0,
            totalCollateralRequired0
        );
        assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable");

        // Bob is liquidatable!
        uint256 snapshot = vm.snapshot();

        vm.startPrank(Charlie);

        console2.log("");
        console2.log("NORMAL LIQUIUDATION, NO PROTOCOL LOSS");
        // NORMAL LIQUIDATION, NO PROTOCOL LOSS
        {
            uint256 valueBefore0 = ct0.convertToAssets(10 ** 18);
            uint256 valueBefore1 = ct1.convertToAssets(10 ** 18);

            liquidate(pp, new TokenId[](0), Bob, $posIdList);

            uint256 valueAfter0 = ct0.convertToAssets(10 ** 18);
            uint256 valueAfter1 = ct1.convertToAssets(10 ** 18);

            console2.log("values 0", valueBefore0, valueAfter0);
            console2.log("values 1", valueBefore1, valueAfter1);
            assertEq(valueBefore0, valueAfter0, "share price 0 stays the same");
            assertEq(valueBefore1, valueAfter1, "share price 1 stays the same");
            console2.log("bob0-after", ct0.balanceOf(Bob));
            console2.log("bob1-after", ct1.balanceOf(Bob));
        }
        vm.revertTo(snapshot);

        console2.log("");
        console2.log("STREAMIA ACCRUAL BUT NO INTEREST, HAIRCUT SO NO PROTOCOL LOSS");
        // STREAMIA ACCRUAL BUT NO INTEREST, HAIRCUT SO NO PROTOCOL LOSS

        accruePoolFeesInRange(
            manager,
            poolKey,
            StateLibrary.getLiquidity(manager, poolKey.toId()) - 1,
            2 ** 85,
            2 ** 85
        );

        (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            $posIdList
        );
        console2.log(
            "totalCollateralBalance0, totalCollateralRequired0",
            totalCollateralBalance0,
            totalCollateralRequired0
        );
        assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable");
        {
            uint256 valueBefore0 = ct0.convertToAssets(10 ** 18);
            uint256 valueBefore1 = ct1.convertToAssets(10 ** 18);
            liquidate(pp, new TokenId[](0), Bob, $posIdList);

            uint256 valueAfter0 = ct0.convertToAssets(10 ** 18);
            uint256 valueAfter1 = ct1.convertToAssets(10 ** 18);

            console2.log("values 0", valueBefore0, valueAfter0);
            console2.log("values 1", valueBefore1, valueAfter1);
            assertEq(valueBefore0, valueAfter0, "share price 0 stays the same");
            assertEq(valueBefore1, valueAfter1, "share price 1 stays the same");
            console2.log("bob0-after", ct0.balanceOf(Bob));
            console2.log("bob1-after", ct1.balanceOf(Bob));
        }

        vm.revertTo(snapshot);
        console2.log("");
        console2.log("NO STREAMIA ACCRUAL BUT INTEREST, BUT MINIMAL PROTOCOL LOSS");

        // NO STREAMIA ACCRUAL BUT INTEREST, BUT MINIMAL PROTOCOL LOSS

        // increase interest owed  (100 years)
        vm.warp(block.timestamp + 100 * 365 * 24 * 3600);
        vm.roll(block.number + 10);

        (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            $posIdList
        );
        console2.log(
            "totalCollateralBalance0, totalCollateralRequired0",
            totalCollateralBalance0,
            totalCollateralRequired0
        );
        {
            uint256 valueBefore0 = ct0.convertToAssets(10 ** 18);
            uint256 valueBefore1 = ct1.convertToAssets(10 ** 18);

            liquidate(pp, new TokenId[](0), Bob, $posIdList);

            uint256 valueAfter0 = ct0.convertToAssets(10 ** 18);
            uint256 valueAfter1 = ct1.convertToAssets(10 ** 18);

            console2.log("values 0", valueBefore0, valueAfter0);
            console2.log("values 1", valueBefore1, valueAfter1);
            assertEq(valueBefore0, valueAfter0, "share price 0 stays the same");
            assertGt(valueBefore1, valueAfter1, "share price 1 decreases");
            console2.log("bob0-after", ct0.balanceOf(Bob));
            console2.log("bob1-after", ct1.balanceOf(Bob));
        }

        vm.revertTo(snapshot);
        console2.log("");
        console2.log("STREAMIA ACCRUAL AND INTEREST, ");

        // STREAMIA ACCRUAL AND INTEREST,

        // increase interest owed  (100 years)
        vm.warp(block.timestamp + 100 * 365 * 24 * 3600);
        vm.roll(block.number + 10);

        accruePoolFeesInRange(
            manager,
            poolKey,
            StateLibrary.getLiquidity(manager, poolKey.toId()) - 1,
            2 ** 85,
            2 ** 85
        );

        (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            $posIdList
        );
        console2.log(
            "totalCollateralBalance0, totalCollateralRequired0",
            totalCollateralBalance0,
            totalCollateralRequired0
        );
        {
            uint256 valueBefore0 = ct0.convertToAssets(10 ** 18);
            uint256 valueBefore1 = ct1.convertToAssets(10 ** 18);

            liquidate(pp, new TokenId[](0), Bob, $posIdList);

            uint256 valueAfter0 = ct0.convertToAssets(10 ** 18);
            uint256 valueAfter1 = ct1.convertToAssets(10 ** 18);

            console2.log("values 0", valueBefore0, valueAfter0);
            console2.log("values 1", valueBefore1, valueAfter1);
            assertEq(valueBefore0, valueAfter0, "share price 0 stays the same");
            assertGt(valueBefore1, valueAfter1, "share price 1 decreases");
            console2.log("bob0-after", ct0.balanceOf(Bob));
            console2.log("bob1-after", ct1.balanceOf(Bob));
        }
    }

    function test_success_liquidation_ITM_scenarios() public {
        vm.startPrank(Swapper);
        // JIT a bunch of liquidity so swaps at mint can happen normally
        swapperc.mint(uniPool, -1000, 1000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -1000, 1000, 10 ** 18);

        // L = 1
        uniPool.liquidity();

        uint256 snapshot = vm.snapshot();

        /// @dev single leg, liquidation through price move making options ITM, no-cross collateral

        for (uint256 i; i < 4; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = i / 2;

            {
                poolId =
                    uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                    uint64(uint256(vegoid) << 40);
                poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
            }

            TokenId tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                asset,
                0,
                tokenType,
                0,
                0,
                2
            );
            //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            if (tokenType == 0) {
                token0.approve(address(ct0), 1000);
                ct0.deposit(1000, Bob);
            } else {
                token1.approve(address(ct1), 1000);
                ct1.deposit(1000, Bob);
            }
            // mint 1 liquidity unit of wideish centered position

            mintOptions(
                pp,
                posIdList,
                3000,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                .checkCollateral(pp, Bob, currentTick, posIdList);

            assertTrue(totalCollateralBalance0 >= totalCollateralRequired0, "Is not liquidatable");

            vm.startPrank(Swapper);

            // swap to 1.21 or 0.82, depending on tokenType
            swapperc.swapTo(
                uniPool,
                tokenType == 0 ? 87150978765690778389772763136 : 72025602285694849958832766976
            );
            routerV4.swapTo(
                address(0),
                poolKey,
                tokenType == 0 ? 87150978765690778389772763136 : 72025602285694849958832766976
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
                pp,
                Bob,
                currentTick,
                posIdList
            );

            assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");

            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 3600);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
                pp.pokeOracle();
            }

            (, currentTick, , , , , ) = uniPool.slot0();
            (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, oraclePack) = pp
                .getOracleTicks();
            twapTick = re.twapEMA(oraclePack);
            console2.log("cur", currentTick);
            console2.log("twapTick", twapTick);

            vm.startPrank(Alice);
            console2.log("");
            console2.log("no-cross collateral", i);
            liquidate(pp, new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }

        /// @dev single leg, liquidation through price move making options ITM, with cross collateral
        for (uint256 i; i < 4; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = i / 2;

            {
                poolId =
                    uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                    uint64(uint256(vegoid) << 40);
                poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
            }

            TokenId tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                asset,
                0,
                tokenType,
                0,
                0,
                2
            );
            //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            if (tokenType == 0) {
                token0.approve(address(ct0), 7);
                ct0.deposit(7, Bob);
                token1.approve(address(ct1), 1000);
                ct1.deposit(1000, Bob);
            } else {
                token0.approve(address(ct0), 1000);
                ct0.deposit(1000, Bob);
                token1.approve(address(ct1), 7);
                ct1.deposit(7, Bob);
            }
            // mint 1 liquidity unit of wideish centered position

            mintOptions(
                pp,
                posIdList,
                3000,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                .checkCollateral(pp, Bob, currentTick, posIdList);

            assertTrue(totalCollateralBalance0 >= totalCollateralRequired0, "Is not liquidatable");

            vm.startPrank(Swapper);

            // swap to 1.21 or 0.82, depending on tokenType
            swapperc.swapTo(
                uniPool,
                tokenType == 0 ? 87150978765690778389772763136 : 72025602285694849958832766976
            );
            routerV4.swapTo(
                address(0),
                poolKey,
                tokenType == 0 ? 87150978765690778389772763136 : 72025602285694849958832766976
            );

            (, currentTick, , , , , ) = uniPool.slot0();
            (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
                pp,
                Bob,
                currentTick,
                posIdList
            );

            assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");

            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 3600);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
                pp.pokeOracle();
            }

            vm.startPrank(Alice);
            console2.log("");
            console2.log("cross collateral", i);
            (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, oraclePack) = pp
                .getOracleTicks();
            twapTick = re.twapEMA(oraclePack);
            console2.log("cur", currentTick);
            console2.log("twapTick", twapTick);

            liquidate(pp, new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }
        console2.log("");
        console2.log("");

        /// @dev strangles, liquidation through price move making on leg of the option ITM

        for (uint256 i; i < 8; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = ((i % 4) / 2);

            {
                poolId =
                    uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                    uint64(uint256(vegoid) << 40);
                poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
            }

            TokenId tokenId;
            {
                tokenId = TokenId.wrap(0).addPoolId(poolId);
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    1,
                    tokenType == 0 ? int24(100) : int24(-100),
                    2
                );
                tokenId = tokenId.addLeg(
                    1,
                    1,
                    asset,
                    0,
                    1 - tokenType,
                    0,
                    tokenType == 1 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
            }

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            token0.approve(address(ct0), 1000);
            ct0.deposit(1000, Bob);
            token1.approve(address(ct1), 1000);
            ct1.deposit(1000, Bob);
            // mint 1 liquidity unit of wideish centered position

            mintOptions(
                pp,
                posIdList,
                3000,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 >= totalCollateralRequired0,
                    "Is not liquidatable"
                );
            }
            vm.startPrank(Swapper);

            // swap to 1.41 or 0.62, depending on tokenType
            swapperc.swapTo(
                uniPool,
                i > 3 ? 110919427519970065594087112704 : 56591544653045956680544681984
            );

            routerV4.swapTo(
                address(0),
                poolKey,
                i > 3 ? 110919427519970065594087112704 : 56591544653045956680544681984
            );

            (, currentTick, , , , , ) = uniPool.slot0();
            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");
            }
            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 3600);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
                pp.pokeOracle();
            }
            (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, oraclePack) = pp
                .getOracleTicks();
            twapTick = re.twapEMA(oraclePack);
            console2.log("cur", currentTick);
            console2.log("twapTick", twapTick);

            vm.startPrank(Alice);
            liquidate(pp, new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }

        /// @dev strangles, liquidation through price move making on leg of the option ITM, with cross-collateral (token0)

        for (uint256 i; i < 8; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = ((i % 4) / 2);

            {
                poolId =
                    uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                    uint64(uint256(vegoid) << 40);
                poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
            }

            TokenId tokenId;
            {
                tokenId = TokenId.wrap(0).addPoolId(poolId);
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    1,
                    tokenType == 0 ? int24(100) : int24(-100),
                    2
                );
                tokenId = tokenId.addLeg(
                    1,
                    1,
                    asset,
                    0,
                    1 - tokenType,
                    0,
                    tokenType == 1 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
            }

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            token0.approve(address(ct0), 1000);
            ct0.deposit(1000, Bob);
            token1.approve(address(ct1), 5);
            ct1.deposit(5, Bob);

            mintOptions(
                pp,
                posIdList,
                3000,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 >= totalCollateralRequired0,
                    "Is not liquidatable"
                );
            }
            vm.startPrank(Swapper);

            // swap to 1.41 or 0.62, depending on tokenType
            swapperc.swapTo(
                uniPool,
                i > 3 ? 110919427519970065594087112704 : 56591544653045956680544681984
            );
            routerV4.swapTo(
                address(0),
                poolKey,
                i > 3 ? 110919427519970065594087112704 : 56591544653045956680544681984
            );

            (, currentTick, , , , , ) = uniPool.slot0();
            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");
            }
            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 3600);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
                pp.pokeOracle();
            }

            vm.startPrank(Alice);

            (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, oraclePack) = pp
                .getOracleTicks();
            twapTick = re.twapEMA(oraclePack);
            console2.log("cur", currentTick);
            console2.log("twapTick", twapTick);

            liquidate(pp, new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }

        /// @dev strangles, liquidation through price move making on leg of the option ITM, with cross-collateral (token1)

        for (uint256 i; i < 8; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = ((i % 4) / 2);

            {
                poolId =
                    uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                    uint64(uint256(vegoid) << 40);
                poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
            }

            TokenId tokenId;
            {
                tokenId = TokenId.wrap(0).addPoolId(poolId);
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    1,
                    tokenType == 0 ? int24(100) : int24(-100),
                    2
                );
                tokenId = tokenId.addLeg(
                    1,
                    1,
                    asset,
                    0,
                    1 - tokenType,
                    0,
                    tokenType == 1 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
            }

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            token0.approve(address(ct0), 5);
            ct0.deposit(5, Bob);
            token1.approve(address(ct1), 1000);
            ct1.deposit(1000, Bob);

            mintOptions(
                pp,
                posIdList,
                3000,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 >= totalCollateralRequired0,
                    "Is not liquidatable"
                );
            }
            vm.startPrank(Swapper);

            // swap to 1.41 or 0.62, depending on tokenType
            swapperc.swapTo(
                uniPool,
                i > 3 ? 110919427519970065594087112704 : 56591544653045956680544681984
            );
            routerV4.swapTo(
                address(0),
                poolKey,
                i > 3 ? 110919427519970065594087112704 : 56591544653045956680544681984
            );

            (, currentTick, , , , , ) = uniPool.slot0();
            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable!");
            }
            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 3600);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
                pp.pokeOracle();
            }

            vm.startPrank(Alice);
            (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, oraclePack) = pp
                .getOracleTicks();
            twapTick = re.twapEMA(oraclePack);
            console2.log("cur", currentTick);
            console2.log("twapTick", twapTick);

            liquidate(pp, new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }
    }

    function test_success_liquidation_LowCollateral_scenarios() public {
        vm.startPrank(Swapper);
        // JIT a bunch of liquidity so swaps at mint can happen normally
        swapperc.mint(uniPool, -1000, 1000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -1000, 1000, 10 ** 18);

        // L = 1
        uniPool.liquidity();

        uint256 snapshot = vm.snapshot();

        /// @dev single leg, liquidation through decrease in collateral, no-cross collateral

        for (uint256 i; i < 4; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = i / 2;

            {
                poolId =
                    uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                    uint64(uint256(vegoid) << 40);
                poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
            }

            TokenId tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                asset,
                0,
                tokenType,
                0,
                0,
                2
            );
            //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            if (tokenType == 0) {
                token0.approve(address(ct0), 1000);
                ct0.deposit(1000, Bob);
            } else {
                token1.approve(address(ct1), 1000);
                ct1.deposit(1000, Bob);
            }
            // mint 1 liquidity unit of wideish centered position

            mintOptions(
                pp,
                posIdList,
                3000,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                .checkCollateral(pp, Bob, currentTick, posIdList);

            assertTrue(totalCollateralBalance0 >= totalCollateralRequired0, "Is not liquidatable");

            vm.startPrank(Swapper);

            if (tokenType == 0) {
                editCollateral(ct0, Bob, ct0.convertToShares(550));
            } else {
                editCollateral(ct1, Bob, ct1.convertToShares(550));
            }
            (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
                pp,
                Bob,
                currentTick,
                posIdList
            );

            assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable! 0");

            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
                pp.pokeOracle();
            }
            console2.log("");
            console2.log("no cross collateral", i);

            vm.startPrank(Alice);
            liquidate(pp, new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }

        /// @dev single leg, liquidation through decrease in collateral, with cross collateral

        for (uint256 i; i < 4; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = i / 2;

            {
                poolId =
                    uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                    uint64(uint256(vegoid) << 40);
                poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
            }

            TokenId tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                asset,
                0,
                tokenType,
                0,
                0,
                2
            );
            //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            if (tokenType == 0) {
                token0.approve(address(ct0), 7);
                ct0.deposit(7, Bob);
                token1.approve(address(ct1), 1000);
                ct1.deposit(1000, Bob);
            } else {
                token0.approve(address(ct0), 1000);
                ct0.deposit(1000, Bob);
                token1.approve(address(ct1), 7);
                ct1.deposit(7, Bob);
            }
            // mint 1 liquidity unit of wideish centered position

            mintOptions(
                pp,
                posIdList,
                3000,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                .checkCollateral(pp, Bob, currentTick, posIdList);

            assertTrue(totalCollateralBalance0 >= totalCollateralRequired0, "Is not liquidatable");

            vm.startPrank(Swapper);

            if (tokenType == 0) {
                editCollateral(ct1, Bob, ct1.convertToShares(550));
            } else {
                editCollateral(ct0, Bob, ct0.convertToShares(550));
            }

            (, currentTick, , , , , ) = uniPool.slot0();
            (totalCollateralBalance0, totalCollateralRequired0) = ph.checkCollateral(
                pp,
                Bob,
                currentTick,
                posIdList
            );

            assertTrue(totalCollateralBalance0 < totalCollateralRequired0, "Is liquidatable! 1");

            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
                pp.pokeOracle();
            }

            vm.startPrank(Alice);
            console2.log("");
            console2.log("cross collateral", i);

            liquidate(pp, new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }
        console2.log("");
        console2.log("");

        /// @dev strangles, liquidation through decrease in collateral, no-cross collateral

        for (uint256 i; i < 4; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = (i / 2);

            {
                poolId =
                    uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                    uint64(uint256(vegoid) << 40);
                poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
            }

            TokenId tokenId;
            {
                tokenId = TokenId.wrap(0).addPoolId(poolId);
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    1,
                    tokenType == 0 ? int24(100) : int24(-100),
                    2
                );
                tokenId = tokenId.addLeg(
                    1,
                    1,
                    asset,
                    0,
                    1 - tokenType,
                    0,
                    tokenType == 1 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
            }

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            token0.approve(address(ct0), 1000);
            ct0.deposit(1000, Bob);
            token1.approve(address(ct1), 1000);
            ct1.deposit(1000, Bob);
            // mint 1 liquidity unit of wideish centered position

            mintOptions(
                pp,
                posIdList,
                3000,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 >= totalCollateralRequired0,
                    "Is not liquidatable"
                );
            }
            vm.startPrank(Swapper);

            editCollateral(ct0, Bob, ct0.convertToShares(250));
            editCollateral(ct1, Bob, ct1.convertToShares(250));

            (, currentTick, , , , , ) = uniPool.slot0();
            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 < totalCollateralRequired0,
                    "Is liquidatable! 2"
                );
            }
            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
                pp.pokeOracle();
            }

            vm.startPrank(Alice);
            liquidate(pp, new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }

        /// @dev strangles, liquidation through decrease in collateral, with cross collateral (token0)

        for (uint256 i; i < 4; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = (i / 2);

            {
                poolId =
                    uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                    uint64(uint256(vegoid) << 40);
                poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
            }

            TokenId tokenId;
            {
                tokenId = TokenId.wrap(0).addPoolId(poolId);
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    1,
                    tokenType == 0 ? int24(100) : int24(-100),
                    2
                );
                tokenId = tokenId.addLeg(
                    1,
                    1,
                    asset,
                    0,
                    1 - tokenType,
                    0,
                    tokenType == 1 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
            }

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            token0.approve(address(ct0), 1000);
            ct0.deposit(1000, Bob);
            token1.approve(address(ct1), 15);
            ct1.deposit(15, Bob);

            mintOptions(
                pp,
                posIdList,
                3000,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 >= totalCollateralRequired0,
                    "Is not liquidatable"
                );
            }
            vm.startPrank(Swapper);

            editCollateral(ct0, Bob, ct0.convertToShares(250));

            (, currentTick, , , , , ) = uniPool.slot0();
            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 < totalCollateralRequired0,
                    "Is liquidatable! 3"
                );
            }
            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
                pp.pokeOracle();
            }

            vm.startPrank(Alice);
            liquidate(pp, new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }

        /// @dev strangles, liquidation through decrease in collateral, with cross collateral (token1)

        for (uint256 i; i < 4; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = (i / 2);

            {
                poolId =
                    uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                    uint64(uint256(vegoid) << 40);
                poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
            }

            TokenId tokenId;
            {
                tokenId = TokenId.wrap(0).addPoolId(poolId);
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    1,
                    tokenType == 0 ? int24(100) : int24(-100),
                    2
                );
                tokenId = tokenId.addLeg(
                    1,
                    1,
                    asset,
                    0,
                    1 - tokenType,
                    0,
                    tokenType == 1 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
            }

            TokenId[] memory posIdList = new TokenId[](1);
            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            token0.approve(address(ct0), 15);
            ct0.deposit(15, Bob);
            token1.approve(address(ct1), 1000);
            ct1.deposit(1000, Bob);

            mintOptions(
                pp,
                posIdList,
                3000,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 >= totalCollateralRequired0,
                    "Is not liquidatable"
                );
            }
            vm.startPrank(Swapper);

            editCollateral(ct1, Bob, ct1.convertToShares(250));

            (, currentTick, , , , , ) = uniPool.slot0();
            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 < totalCollateralRequired0,
                    "Is liquidatable! 4"
                );
            }
            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
                pp.pokeOracle();
            }

            vm.startPrank(Alice);
            liquidate(pp, new TokenId[](0), Bob, posIdList);
            vm.revertTo(snapshot);
        }

        /// @dev spreads, liquidation through decrease in collateral, no-cross collateral

        for (uint256 i; i < 8; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = ((i % 4) / 2);
            TokenId tokenId;
            TokenId[] memory posIdList = new TokenId[](1);

            {
                // sell long leg
                vm.startPrank(Charlie);

                {
                    poolId =
                        uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                        uint64(uint256(vegoid) << 40);
                    poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
                }

                tokenId = TokenId.wrap(0).addPoolId(poolId);
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    0,
                    i < 3 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
                posIdList[0] = tokenId;

                mintOptions(
                    pp,
                    posIdList,
                    1_000_000,
                    0,
                    Constants.MAX_POOL_TICK,
                    Constants.MIN_POOL_TICK,
                    true
                );

                {
                    poolId =
                        uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                        uint64(uint256(vegoid) << 40);
                    poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
                }

                // create spread tokenId
                tokenId = TokenId.wrap(0).addPoolId(poolId);
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    1,
                    i < 3 ? int24(-100) : int24(100),
                    2
                );
                tokenId = tokenId.addLeg(
                    1,
                    1,
                    asset,
                    1,
                    tokenType,
                    0,
                    i < 3 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
            }

            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            token0.approve(address(ct0), 1000);
            ct0.deposit(1000, Bob);
            token1.approve(address(ct1), 1000);
            ct1.deposit(1000, Bob);
            // mint 1 liquidity unit of wideish centered position

            mintOptions(
                pp,
                posIdList,
                10_000,
                type(uint24).max,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 >= totalCollateralRequired0,
                    "Is not liquidatable"
                );
            }
            vm.startPrank(Swapper);

            editCollateral(ct0, Bob, ct0.convertToShares(99));
            editCollateral(ct1, Bob, ct1.convertToShares(99));

            (, currentTick, , , , , ) = uniPool.slot0();
            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);
                console2.log(
                    "totalCollateralBalance0, totalCollateralRequired0",
                    totalCollateralBalance0,
                    totalCollateralRequired0
                );
                assertTrue(
                    totalCollateralBalance0 < totalCollateralRequired0,
                    "Is liquidatable! 5"
                );
            }
            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
                pp.pokeOracle();
            }

            vm.startPrank(Alice);
            liquidate(pp, new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }

        /// @dev spreads, liquidation through decrease in collateral, with cross collateral (token0)

        for (uint256 i; i < 8; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = ((i % 4) / 2);
            TokenId tokenId;
            TokenId[] memory posIdList = new TokenId[](1);

            {
                // sell long leg
                vm.startPrank(Charlie);

                {
                    poolId =
                        uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                        uint64(uint256(vegoid) << 40);
                    poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
                }

                tokenId = TokenId.wrap(0).addPoolId(poolId);
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    0,
                    i < 3 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
                posIdList[0] = tokenId;

                mintOptions(
                    pp,
                    posIdList,
                    1_000_000,
                    0,
                    Constants.MAX_POOL_TICK,
                    Constants.MIN_POOL_TICK,
                    true
                );

                // create spread tokenId
                tokenId = TokenId.wrap(0).addPoolId(poolId);
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    1,
                    i < 3 ? int24(-100) : int24(100),
                    2
                );
                tokenId = tokenId.addLeg(
                    1,
                    1,
                    asset,
                    1,
                    tokenType,
                    0,
                    i < 3 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
            }

            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            token0.approve(address(ct0), 2500);
            ct0.deposit(2500, Bob);
            token1.approve(address(ct1), 150);
            ct1.deposit(127, Bob);
            // mint 1 liquidity unit of wideish centered position

            mintOptions(
                pp,
                posIdList,
                10_000,
                type(uint24).max,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 >= totalCollateralRequired0,
                    "Is not liquidatable"
                );
            }
            vm.startPrank(Swapper);

            editCollateral(ct0, Bob, ct0.convertToShares(0));
            editCollateral(ct1, Bob, ct1.convertToShares(198));

            (, currentTick, , , , , ) = uniPool.slot0();
            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);
                console2.log(
                    "totalCollateralBalance0, totalCollateralRequired0",
                    totalCollateralBalance0,
                    totalCollateralRequired0
                );

                assertTrue(
                    totalCollateralBalance0 < totalCollateralRequired0,
                    "Is liquidatable! 6"
                );
            }
            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
                pp.pokeOracle();
            }

            vm.startPrank(Alice);
            liquidate(pp, new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }

        /// @dev spreads, liquidation through decrease in collateral, with cross collateral (token1)

        for (uint256 i; i < 8; ++i) {
            uint256 asset = i % 2;
            uint256 tokenType = ((i % 4) / 2);
            TokenId tokenId;
            TokenId[] memory posIdList = new TokenId[](1);

            {
                // sell long leg
                vm.startPrank(Charlie);

                {
                    poolId =
                        uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
                        uint64(uint256(vegoid) << 40);
                    poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
                }

                tokenId = TokenId.wrap(0).addPoolId(poolId);
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    0,
                    i < 3 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
                posIdList[0] = tokenId;

                mintOptions(
                    pp,
                    posIdList,
                    1_000_000,
                    0,
                    Constants.MAX_POOL_TICK,
                    Constants.MIN_POOL_TICK,
                    true
                );

                // create spread tokenId
                tokenId = TokenId.wrap(0).addPoolId(poolId);
                tokenId = tokenId.addLeg(
                    0,
                    1,
                    asset,
                    0,
                    tokenType,
                    1,
                    i < 3 ? int24(-100) : int24(100),
                    2
                );
                tokenId = tokenId.addLeg(
                    1,
                    1,
                    asset,
                    1,
                    tokenType,
                    0,
                    i < 3 ? int24(100) : int24(-100),
                    2
                );
                //.addLeg(legIndex, optionRatio, asset, isLong, tokenType, riskPartner, strike, width);
            }

            posIdList[0] = tokenId;

            (, currentTick, , , , , ) = uniPool.slot0();

            vm.startPrank(Bob);
            ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
            ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

            token0.approve(address(ct0), 150);
            ct0.deposit(127, Bob);
            token1.approve(address(ct1), 2500);
            ct1.deposit(2500, Bob);
            // mint 1 liquidity unit of wideish centered position

            mintOptions(
                pp,
                posIdList,
                10_000,
                type(uint24).max,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            (, currentTick, , , , , ) = uniPool.slot0();

            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);

                assertTrue(
                    totalCollateralBalance0 >= totalCollateralRequired0,
                    "Is not liquidatable"
                );
            }
            vm.startPrank(Swapper);

            editCollateral(ct0, Bob, ct0.convertToShares(125));
            editCollateral(ct1, Bob, ct1.convertToShares(0));

            (, currentTick, , , , , ) = uniPool.slot0();
            {
                (uint256 totalCollateralBalance0, uint256 totalCollateralRequired0) = ph
                    .checkCollateral(pp, Bob, currentTick, posIdList);
                console2.log(
                    "totalCollateralBalance0, totalCollateralRequired0",
                    totalCollateralBalance0,
                    totalCollateralRequired0
                );

                assertTrue(
                    totalCollateralBalance0 < totalCollateralRequired0,
                    "Is liquidatable! 7"
                );
            }
            // update twaps
            for (uint256 j = 0; j < 100; ++j) {
                vm.warp(block.timestamp + 120);
                vm.roll(block.number + 10);
                swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
                swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
            }

            vm.startPrank(Alice);
            liquidate(pp, new TokenId[](0), Bob, posIdList);

            vm.revertTo(snapshot);
        }
    }
}
