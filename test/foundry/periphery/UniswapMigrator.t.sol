// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {UniswapMigrator} from "@periphery/UniswapMigrator.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {PanopticMath} from "@contracts/libraries/PanopticMath.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {Pointer} from "@types/Pointer.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {PeripheryErrors} from "@periphery/PeripheryErrors.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";

contract UniswapMigratorTest is Test {
    SemiFungiblePositionManager sfpm;

    IUniswapV3Factory V3FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    INonfungiblePositionManager V3NFPM =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    PanopticFactory factory;

    // store a few different mainnet pairs - the pool used is part of the fuzz
    IUniswapV3Pool constant USDC_WETH_5 =
        IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);

    IERC20Partial USDC = IERC20Partial(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    IERC20Partial WETH = IERC20Partial(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    PanopticPool pp;
    CollateralTracker ct0;
    CollateralTracker ct1;

    address Deployer = address(0x1234);
    address Alice = address(0x123456);
    address Bob = address(0x12345678);
    address Charlie = address(0x1234567891);

    uint256 amount0Migrate;
    uint256 amount1Migrate;

    uint256 tokenId;
    uint256[] tokenIds;
    uint256[2][] amount0Mins;
    uint256 amount0;
    uint256 amount1;

    // reference implemenatations used by the factory
    address poolReference;
    address collateralReference;

    UniswapMigrator uniswapMigrator;

    function setUp() public {
        sfpm = new SemiFungiblePositionManager(V3FACTORY);

        // deploy reference pool and collateral token
        poolReference = address(new PanopticPool(sfpm));

        // no commission/mint fee
        collateralReference = address(
            new CollateralTracker(0, 2_000, 1_000, -1_024, 5_000, 9_000, 20_000)
        );

        vm.startPrank(Deployer);

        factory = new PanopticFactory(
            address(WETH),
            sfpm,
            V3FACTORY,
            poolReference,
            collateralReference,
            new bytes32[](0),
            new uint256[][](0),
            new Pointer[][](0)
        );

        uniswapMigrator = new UniswapMigrator(V3NFPM);

        deal(address(USDC), Deployer, type(uint104).max);
        deal(address(WETH), Deployer, type(uint104).max);
        USDC.approve(address(factory), type(uint104).max);
        WETH.approve(address(factory), type(uint104).max);

        pp = PanopticPool(
            address(
                factory.deployNewPool(
                    address(USDC),
                    address(WETH),
                    500,
                    uint96(block.timestamp),
                    type(uint256).max,
                    type(uint256).max
                )
            )
        );

        ct0 = pp.collateralToken0();
        ct1 = pp.collateralToken1();

        deal(address(USDC), Alice, type(uint104).max);
        deal(address(WETH), Alice, type(uint104).max);
        vm.startPrank(Alice);
        USDC.approve(address(V3NFPM), type(uint104).max);
        WETH.approve(address(V3NFPM), type(uint104).max);
        V3NFPM.setApprovalForAll(address(uniswapMigrator), true);

        deal(address(USDC), Bob, type(uint104).max);
        deal(address(WETH), Bob, type(uint104).max);
        vm.startPrank(Bob);
        USDC.approve(address(V3NFPM), type(uint104).max);
        WETH.approve(address(V3NFPM), type(uint104).max);
        V3NFPM.setApprovalForAll(address(uniswapMigrator), true);
    }

    function test_success_migrate_single() public {
        vm.startPrank(Alice);

        (tokenId, , amount0, amount1) = V3NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(USDC),
                token1: address(WETH),
                fee: 500,
                tickLower: -887270,
                tickUpper: 887270,
                amount0Desired: 1000 * 10 ** 6,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: Alice,
                deadline: block.timestamp
            })
        );

        tokenIds.push(tokenId);
        amount0Mins.push([0, 0]);

        uniswapMigrator.migrate(tokenIds, amount0Mins, ct0, ct1);

        // err = rounded down shares
        assertApproxEqAbs(ct0.convertToAssets(ct0.balanceOf(Alice)), amount0, 1);
        assertApproxEqAbs(ct1.convertToAssets(ct1.balanceOf(Alice)), amount1, 1);
    }

    function test_success_migrate_single_only0() public {
        vm.startPrank(Alice);

        (tokenId, , amount0, amount1) = V3NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(USDC),
                token1: address(WETH),
                fee: 500,
                tickLower: 887260,
                tickUpper: 887270,
                amount0Desired: 100,
                amount1Desired: 0,
                amount0Min: 0,
                amount1Min: 0,
                recipient: Alice,
                deadline: block.timestamp
            })
        );

        tokenIds.push(tokenId);
        amount0Mins.push([0, 0]);

        uniswapMigrator.migrate(tokenIds, amount0Mins, ct0, ct1);

        // err = rounded down shares
        assertApproxEqAbs(ct0.convertToAssets(ct0.balanceOf(Alice)), amount0, 1);
        assertEq(ct1.balanceOf(Alice), 0);
    }

    function test_success_migrate_single_only1() public {
        vm.startPrank(Alice);

        (tokenId, , amount0, amount1) = V3NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(USDC),
                token1: address(WETH),
                fee: 500,
                tickLower: -887270,
                tickUpper: -887260,
                amount0Desired: 0,
                amount1Desired: 100,
                amount0Min: 0,
                amount1Min: 0,
                recipient: Alice,
                deadline: block.timestamp
            })
        );

        tokenIds.push(tokenId);
        amount0Mins.push([0, 0]);

        uniswapMigrator.migrate(tokenIds, amount0Mins, ct0, ct1);

        // err = rounded down shares
        assertEq(ct0.balanceOf(Alice), 0);
        assertApproxEqAbs(ct1.convertToAssets(ct1.balanceOf(Alice)), amount1, 1);
    }

    function test_success_migrate_multiple() public {
        vm.startPrank(Alice);

        for (uint256 i = 0; i < 32; ++i) {
            (tokenId, , amount0, amount1) = V3NFPM.mint(
                INonfungiblePositionManager.MintParams({
                    token0: address(USDC),
                    token1: address(WETH),
                    fee: 500,
                    tickLower: -887270,
                    tickUpper: 887270,
                    amount0Desired: 1000 * 10 ** 6 * ((i % 6) + 1),
                    amount1Desired: 1 ether * ((i % 6) + 1),
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: Alice,
                    deadline: block.timestamp
                })
            );

            amount0Migrate += amount0;
            amount1Migrate += amount1;

            tokenIds.push(tokenId);
            amount0Mins.push([0, 0]);
        }

        uniswapMigrator.migrate(tokenIds, amount0Mins, ct0, ct1);

        // err = rounded down shares
        assertApproxEqAbs(ct0.convertToAssets(ct0.balanceOf(Alice)), amount0Migrate, 32);
        assertApproxEqAbs(ct1.convertToAssets(ct1.balanceOf(Alice)), amount1Migrate, 32);
    }

    function test_fail_migrate_single_unauthorized() public {
        vm.startPrank(Bob);

        (tokenId, , amount0, amount1) = V3NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(USDC),
                token1: address(WETH),
                fee: 500,
                tickLower: -887270,
                tickUpper: 887270,
                amount0Desired: 1000 * 10 ** 6,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: Bob,
                deadline: block.timestamp
            })
        );

        tokenIds.push(tokenId);
        amount0Mins.push([0, 0]);

        vm.startPrank(Alice);

        vm.expectRevert(PeripheryErrors.UnauthorizedMigration.selector);
        uniswapMigrator.migrate(tokenIds, amount0Mins, ct0, ct1);
    }

    function test_fail_migrate_single_slippage0() public {
        vm.startPrank(Bob);

        (tokenId, , amount0, amount1) = V3NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(USDC),
                token1: address(WETH),
                fee: 500,
                tickLower: -887270,
                tickUpper: 887270,
                amount0Desired: 1000 * 10 ** 6,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: Bob,
                deadline: block.timestamp
            })
        );

        tokenIds.push(tokenId);
        amount0Mins.push([amount0 + 1, 0]);

        vm.startPrank(Alice);

        vm.expectRevert();
        uniswapMigrator.migrate(tokenIds, amount0Mins, ct0, ct1);
    }

    function test_fail_migrate_single_slippage1() public {
        vm.startPrank(Bob);

        (tokenId, , amount0, amount1) = V3NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(USDC),
                token1: address(WETH),
                fee: 500,
                tickLower: -887270,
                tickUpper: 887270,
                amount0Desired: 1000 * 10 ** 6,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: Bob,
                deadline: block.timestamp
            })
        );

        tokenIds.push(tokenId);
        amount0Mins.push([0, amount1 + 1]);

        vm.startPrank(Alice);

        vm.expectRevert();
        uniswapMigrator.migrate(tokenIds, amount0Mins, ct0, ct1);
    }

    function test_fail_migrate_single_slippageboth() public {
        vm.startPrank(Bob);

        (tokenId, , amount0, amount1) = V3NFPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(USDC),
                token1: address(WETH),
                fee: 500,
                tickLower: -887270,
                tickUpper: 887270,
                amount0Desired: 1000 * 10 ** 6,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: Bob,
                deadline: block.timestamp
            })
        );

        tokenIds.push(tokenId);
        amount0Mins.push([amount0 + 1, amount1 + 1]);

        vm.startPrank(Alice);

        vm.expectRevert();
        uniswapMigrator.migrate(tokenIds, amount0Mins, ct0, ct1);
    }

    function test_fail_migrate_multiple_unauthorized() public {
        vm.startPrank(Alice);

        for (uint256 i = 0; i < 32; ++i) {
            (tokenId, , amount0, amount1) = V3NFPM.mint(
                INonfungiblePositionManager.MintParams({
                    token0: address(USDC),
                    token1: address(WETH),
                    fee: 500,
                    tickLower: -887270,
                    tickUpper: 887270,
                    amount0Desired: 1000 * 10 ** 6 * ((i % 6) + 1),
                    amount1Desired: 1 ether * ((i % 6) + 1),
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: i == 17 ? Bob : Alice,
                    deadline: block.timestamp
                })
            );

            tokenIds.push(tokenId);
            amount0Mins.push([0, 0]);
        }

        vm.expectRevert(PeripheryErrors.UnauthorizedMigration.selector);
        uniswapMigrator.migrate(tokenIds, amount0Mins, ct0, ct1);
    }

    function test_fail_migrate_multiple_slippage() public {
        vm.startPrank(Alice);

        for (uint256 i = 0; i < 32; ++i) {
            (tokenId, , amount0, amount1) = V3NFPM.mint(
                INonfungiblePositionManager.MintParams({
                    token0: address(USDC),
                    token1: address(WETH),
                    fee: 500,
                    tickLower: -887270,
                    tickUpper: 887270,
                    amount0Desired: 1000 * 10 ** 6 * ((i % 6) + 1),
                    amount1Desired: 1 ether * ((i % 6) + 1),
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: i == 17 ? Bob : Alice,
                    deadline: block.timestamp
                })
            );

            tokenIds.push(tokenId);
            amount0Mins.push(i == 17 ? [uint256(0), amount1 + 1] : [uint256(0), uint256(0)]);
        }

        vm.expectRevert();
        uniswapMigrator.migrate(tokenIds, amount0Mins, ct0, ct1);
    }
}
