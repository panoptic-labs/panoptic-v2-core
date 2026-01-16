// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";

contract CreatePool is Script {
    function run() public {
        uint256 DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");

        PanopticFactory factory = PanopticFactory(vm.envAddress("PANOPTIC_FACTORY"));
        IRiskEngine riskEngine = IRiskEngine(vm.envAddress("RISK_ENGINE"));
        address univ3Pool = vm.envAddress("UNIV3_POOL");

        IUniswapV3Pool v3Pool = IUniswapV3Pool(univ3Pool);
        address token0 = v3Pool.token0();
        address token1 = v3Pool.token1();
        uint24 fee = v3Pool.fee();

        console.log("Creating Panoptic Pool (V3)");
        console.log("Uniswap V3 Pool:", univ3Pool);
        console.log("Token0:", token0);
        console.log("Token1:", token1);
        console.log("Fee:", fee);
        console.log("Factory:", address(factory));
        console.log("RiskEngine:", address(riskEngine));

        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        uint96 salt = 0;
        PanopticPool newPool = factory.deployNewPool(token0, token1, fee, riskEngine, salt);

        console.log("Successfully deployed Panoptic Pool at:", address(newPool));

        vm.stopBroadcast();
    }
}
