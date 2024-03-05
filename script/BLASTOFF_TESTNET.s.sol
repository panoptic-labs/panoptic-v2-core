// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.18;

// Foundry
import "forge-std/Script.sol";
// Uniswap - Panoptic's version 0.8
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
// Internal
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {ERC20S} from "./tokens/ERC20S.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";

/**
 * @title Deployment script that deploys two tokens, a Uniswap V3 pool, and a Panoptic Pool on top of that.
 * @author Axicon Labs Limited
 */
contract DeployBLAST is Script {
    function run() public {
        // TESTNET
        // THRUSTER FACTORY: 0xe832c58505D5BFECE4053B49f0c64Fb4c0a9AaD7
        // WETHB: 0x4200000000000000000000000000000000000023
        // T0-T1 ThrusterPool: 0x7065Fc20deB1C5f7b48cF37Bd68C78117e204469
        uint256 DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        IUniswapV3Factory UNISWAP_V3_FACTORY = IUniswapV3Factory(0xe832c58505D5BFECE4053B49f0c64Fb4c0a9AaD7);
        SemiFungiblePositionManager SFPM = new SemiFungiblePositionManager(UNISWAP_V3_FACTORY);
        address CT = address(new CollateralTracker());
        address PP = address(new PanopticPool(SFPM));

        PanopticFactory PANOPTIC_FACTORY = new PanopticFactory(0x4200000000000000000000000000000000000023, SFPM, UNISWAP_V3_FACTORY, PP, CT);

        ERC20S token0 = new ERC20S("Token0", "T0", 18);
        ERC20S token1 = new ERC20S("Token1", "T1", 18);

        token0.mint(vm.addr(DEPLOYER_PRIVATE_KEY), 100000e18);
        token1.mint(vm.addr(DEPLOYER_PRIVATE_KEY), 100000e18);

        token0.approve(address(PANOPTIC_FACTORY), type(uint256).max);
        token1.approve(address(PANOPTIC_FACTORY), type(uint256).max);

        // deployed with computed token addresses before script is run (foundry can't sim a precompile call in BLAST.configureClaimableYield() yet)
        // address unipool = UNISWAP_V3_FACTORY.createPool(address(token0), address(token1), 500);

        //initialize at tick 0
        IUniswapV3Pool(0x1D1e3baC4E0a6870123C19edbb8410711848Da92).initialize(0x1000000000000000000000000);

        PANOPTIC_FACTORY.deployNewPool(address(token0), address(token1), 500, 1337);

        vm.stopBroadcast();
    }
}
