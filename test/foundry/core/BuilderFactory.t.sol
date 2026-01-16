// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BuilderFactory} from "@contracts/RiskEngine.sol";
import {BuilderWallet} from "@contracts/RiskEngine.sol";

contract BuilderFactoryTest is Test {
    BuilderFactory public builderFactory;

    address public owner = address(0x1);
    address public builderAdmin = address(0x2);

    event BuilderDeployed(uint48 indexed builderCode, address indexed wallet, address builderAdmin);

    function setUp() public {
        vm.prank(owner);
        builderFactory = new BuilderFactory(owner);
    }

    function test_DeployBuilder_EmitsBuilderDeployedEvent() public {
        uint48 builderCode = 123456;

        address expectedWallet = builderFactory.predictBuilderWallet(builderCode);

        vm.recordLogs();

        vm.prank(owner);
        address wallet = builderFactory.deployBuilder(builderCode, builderAdmin);

        Vm.Log[] memory entries = vm.getRecordedLogs();

        // Find the BuilderDeployed event
        bytes32 eventSig = keccak256("BuilderDeployed(uint48,address,address)");
        bool found = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == eventSig) {
                found = true;

                // Assert event properties match what we expect
                uint48 emittedCode = uint48(uint256(entries[i].topics[1]));
                assertEq(emittedCode, builderCode, "Emitted builderCode should match");

                address emittedWallet = address(uint160(uint256(entries[i].topics[2])));
                assertEq(emittedWallet, expectedWallet, "Emitted wallet should match expected");
                assertEq(emittedWallet, wallet, "Emitted wallet should match returned wallet");

                address emittedAdmin = abi.decode(entries[i].data, (address));
                assertEq(emittedAdmin, builderAdmin, "Emitted builderAdmin should match");

                break;
            }
        }

        assertTrue(found, "BuilderDeployed event should be emitted");
    }
}
