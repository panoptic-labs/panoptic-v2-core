// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PanopticFactoryV3} from "@contracts/PanopticFactoryV3.sol";
import {PanopticPoolV2} from "@contracts/PanopticPool.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";

/// @notice Simulates or broadcasts a PanopticFactoryV3 pool deployment.
/// @dev SALT is the uint96 `bestSalt` emitted by script/pool-address-miner.
contract CreatePoolV3 is Script {
    function run() public {
        PanopticFactoryV3 factory = PanopticFactoryV3(vm.envAddress("PANOPTIC_FACTORY_V3"));
        IRiskEngine riskEngine = IRiskEngine(vm.envAddress("RISK_ENGINE"));
        address token0 = vm.envAddress("TOKEN0");
        address token1 = vm.envAddress("TOKEN1");
        uint24 fee = uint24(vm.envUint("FEE"));
        uint96 salt = uint96(vm.envUint("SALT"));

        console.log("Creating Panoptic Pool (V3)");
        console.log("Factory:", address(factory));
        console.log("RiskEngine:", address(riskEngine));
        console.log("Token0:", token0);
        console.log("Token1:", token1);
        console.log("Fee:", fee);
        console.log("Salt:", salt);

        vm.startBroadcast();
        PanopticPoolV2 newPool = factory.deployNewPool(token0, token1, fee, riskEngine, salt);
        vm.stopBroadcast();

        console.log("Successfully deployed Panoptic Pool at:", address(newPool));
    }
}
