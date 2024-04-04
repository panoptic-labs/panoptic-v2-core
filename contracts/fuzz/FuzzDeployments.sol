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


    function initialize() internal {
        // initalize current pool we are deploying
        IUniswapV3Pool pool = USDC_WETH_5;
        uint24 fee = pool.fee();
        int24 tickSpacing = pool.tickSpacing();

        assert(pool.token0() == address(USDC));
        assert(pool.token1() == address(WETH));

        // give test contract a sufficient amount of tokens to deploy a new pool
        deal_USDC(address(this), 100 ether);
        deal_WETH(address(this), 100 ether);

        assert(USDC.balanceOf(address(this)) == 100 ether);
        assert(WETH.balanceOf(address(this)) == 100 ether);

        // approve factory to move tokens, on behalf of the test contract
        USDC.approve(address(panopticFactory), type(uint256).max);
        WETH.approve(address(panopticFactory), type(uint256).max);

        // approve sfpm to move tokens, on behalf of the test contract
        USDC.approve(address(sfpm), type(uint256).max);
        WETH.approve(address(sfpm), type(uint256).max);

        // approve self
        USDC.approve(address(this), type(uint256).max);
        WETH.approve(address(this), type(uint256).max);

        sfpm.initializeAMMPool(pool.token0(), pool.token1(), fee);

        panopticPool = panopticFactory.deployNewPool(pool.token0(), pool.token1(), fee, bytes32(uint256(uint160(address(this))) << 96));
        
    }

}
