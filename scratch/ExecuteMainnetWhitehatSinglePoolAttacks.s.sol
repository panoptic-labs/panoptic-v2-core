// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {WBTC_USDC30bpsMainnetAttacker_Deployer, WBTC_USDC30bpsMainnetAttacker} from "./attacker-contracts/Deployable_WBTC_USDC30bpsMainnetAttacker.sol";
import {ETH_USDC5bpsMainnetAttacker_Deployer, ETH_USDC5bpsMainnetAttacker} from "./attacker-contracts/Deployable_ETH_USDC_5bpsMainnet.sol";

contract ExecuteMainnetWhitehatSinglePoolAttacks is Script {
    WBTC_USDC30bpsMainnetAttacker wbtcUsdcAttacker;
    ETH_USDC5bpsMainnetAttacker ethUsdcAttacker;

    function run() public {
        uint256 DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        // vault.panoptic.eth on mainnet
        address withdrawer = 0x82BF455e9ebd6a541EF10b683dE1edCaf05cE7A1;

        console.log("Executing the first of 2 mainnet single pool attacks, on WBTC/USDC 30bps:");
        WBTC_USDC30bpsMainnetAttacker_Deployer wbtcUsdcDeployer = new WBTC_USDC30bpsMainnetAttacker_Deployer{salt: bytes32(uint256(0x123))}(withdrawer);
        console.log("WBTC_USDC30bpsMainnetAttacker_Deployer deployed at:", address(wbtcUsdcDeployer));
        console.log("WBTC_USDC30bpsMainnetAttacker_Deployer succeeded");
        wbtcUsdcAttacker = wbtcUsdcDeployer.attacker();
        console.log("ETH_USDC5bpsMainnetAttacker deployed and holding funds at:", address(wbtcUsdcAttacker));

        console.log("Executing the second of 2 mainnet single pool attacks, on ETH/USDC 5bps:");
        ETH_USDC5bpsMainnetAttacker_Deployer ethUsdcAttackerDeployer = new ETH_USDC5bpsMainnetAttacker_Deployer{salt: bytes32(uint256(0x123))}(withdrawer);
        console.log("ETH_USDC5bpsMainnetAttacker_Deployer deployed at:", address(ethUsdcAttackerDeployer));
        console.log("ETH_USDC5bpsMainnetAttacker_Deployer succeeded");
        ethUsdcAttacker = ethUsdcAttackerDeployer.attacker();
        console.log("ETH_USDC5bpsMainnetAttacker deployed and holding funds at:", address(ethUsdcAttacker));

        vm.stopBroadcast();
    }
}
