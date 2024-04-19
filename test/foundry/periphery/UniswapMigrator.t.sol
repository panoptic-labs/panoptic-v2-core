// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {UniswapMigrator} from "@periphery/UniswapMigrator.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {PanopticMath} from "@contracts/libraries/PanopticMath.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {IDonorNFT} from "@tokens/interfaces/IDonorNFT.sol";
import {DonorNFT} from "@periphery/DonorNFT.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
// and with UniswapMigration should come PanopticFactory, PanopticPool, IUniswapV3Factory, INonfungiblePositionManager and IERC20
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";

contract SemiFungiblePositionManagerHarness is SemiFungiblePositionManager {
    /// TODO I think the vanilla SFPM is actually all this test needs, but if you need, check out the harness in PanopticHelper.t.sol
}

contract PanopticPoolHarness is PanopticPool {
    /// TODO I think the vanilla Pool is actually all this test needs, but if you need, check out the positions hash getter and other things in the harness inside of PanopticHelper.t.sol
}

contract UniswapMigratorTest {
    SemiFungiblePositionManagerHarness sfpm;

    IUniswapV3Factory V3FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    INonfungiblePositionManager V3NFPM =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    PanopticFactory factory;

    // store a few different mainnet pairs - the pool used is part of the fuzz
    IUniswapV3Pool constant USDC_WETH_5 =
        IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
    IUniswapV3Pool constant WBTC_ETH_30 =
        IUniswapV3Pool(0xCBCdF9626bC03E24f779434178A73a0B4bad62eD);
    IUniswapV3Pool constant USDC_WETH_30 =
        IUniswapV3Pool(0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8);
    IUniswapV3Pool[3] public pools = [USDC_WETH_5, USDC_WETH_5, USDC_WETH_5];

    address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // store some data about the pool we are testing
    IUniswapV3Pool pool;
    uint64 poolId;
    address token0;
    address token1;
    // We range position size in terms of WETH, so need to figure out which token is WETH
    uint256 isWETH;
    uint24 fee;
    int24 tickSpacing;
    uint160 currentSqrtPriceX96;
    int24 currentTick;
    uint256 feeGrowthGlobal0X128;
    uint256 feeGrowthGlobal1X128;
    uint256 poolBalance0;
    uint256 poolBalance1;

    address Deployer = address(0x1234);
    address LiquidityProvider = address(0x123456);

    PanopticPoolHarness pp;
    CollateralTracker ct0;
    CollateralTracker ct1;

    // reference implemenatations used by the factory
    address poolReference;
    address collateralReference;

    uint256 liquidityProvisionTokenId;

    UniswapMigrator uniswapMigrator;

    function _initPool(uint256 seed) internal {
        _initWorld(seed);
    }

    function _initWorld(uint256 seed) internal {
        // Pick a pool from the seed and cache initial state
        _cacheWorldState(pools[bound(seed, 0, pools.length - 1)]);

        _deployPanopticPool();

        _initAccounts();
    }

    function _cacheWorldState(IUniswapV3Pool _pool) internal {
        pool = _pool;
        poolId = PanopticMath.getPoolId(address(_pool));
        token0 = _pool.token0();
        token1 = _pool.token1();
        isWETH = token0 == address(WETH) ? 0 : 1;
        fee = _pool.fee();
        tickSpacing = _pool.tickSpacing();
        (currentSqrtPriceX96, currentTick, , , , , ) = _pool.slot0();
        feeGrowthGlobal0X128 = _pool.feeGrowthGlobal0X128();
        feeGrowthGlobal1X128 = _pool.feeGrowthGlobal1X128();
        poolBalance0 = IERC20Partial(token0).balanceOf(address(_pool));
        poolBalance1 = IERC20Partial(token1).balanceOf(address(_pool));
    }

    function _deployPanopticPool() internal {
        vm.startPrank(Deployer);

        IDonorNFT dNFT = IDonorNFT(address(new DonorNFT()));

        factory = new PanopticFactory(
            WETH,
            sfpm,
            V3FACTORY,
            dNFT,
            poolReference,
            collateralReference
        );

        factory.initialize(Deployer);

        DonorNFT(address(dNFT)).changeFactory(address(factory));

        deal(token0, Deployer, type(uint104).max);
        deal(token1, Deployer, type(uint104).max);
        IERC20Partial(token0).approve(address(factory), type(uint104).max);
        IERC20Partial(token1).approve(address(factory), type(uint104).max);

        pp = PanopticPoolHarness(
            address(
                factory.deployNewPool(
                    token0,
                    token1,
                    fee,
                    bytes32(uint256(uint160(Deployer)) << 96)
                )
            )
        );

        ct0 = pp.collateralToken0();
        ct1 = pp.collateralToken1();
    }

    function _initAccounts() internal {
        // TODO: Deal some tokens to people in here; see PanopticHelper.t.sol 's _initAccounts for inspiration
    }

    function setUp() public {
        sfpm = new SemiFungiblePositionManagerHarness(V3FACTORY);

        // deploy reference pool and collateral token
        poolReference = address(new PanopticPoolHarness(sfpm));
        collateralReference = address(
            new CollateralTracker(10, 2_000, 1_000, -1_024, 5_000, 9_000, 20_000)
        );

        // set up the liquidity provider's LP position
        deal(token0, LiquidityProvider, type(uint104).max);
        deal(token1, LiquidityProvider, type(uint104).max);
        vm.prank(LiquidityProvider);
        IERC20Partial(token0).approve(address(V3NFPM), type(uint104).max);
        IERC20Partial(token1).approve(address(V3NFPM), type(uint104).max);

        (liquidityProvisionTokenId, , , ) = V3NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                // TODO: Do these need to be sensical values, or can I just put 1 for all them?
                // I see the NonfungiblePositionManager test from Uniswap actually calls a getMinTick / getMaxTick when calling .mint in its tests, but i don't know if that's necessary
                fee: 1,
                tickLower: 1,
                tickUpper: 1,
                amount0Desired: 1,
                amount1Desired: 1,
                amount0Min: 1,
                amount1Min: 1,
                recipient: LiquidityProvider,
                deadline: block.timestamp
            })
        );

        // and finally, deploy the migrator!
        uniswapMigrator = new UniswapMigrator(factory, V3NFPM, V3FACTORY);
    }

    function test_migrateSuccess() public {
        vm.prank(LiquidityProvider);
        uniswapMigrator.migrate([liquidityProvisionTokenId]);
    }
}
