// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RiskEngineV2} from "@contracts/RiskEngine.sol";
import {BuilderFactory, BuilderWallet} from "@contracts/Builder.sol";
import {RiskEngineParams} from "../../testUtils/RiskEngineParams.sol";

/// @title RiskEngine constructor pins
/// @notice The BuilderWallet init code hash is a constructor input verified against the factory, so the engine
///         can be compiled with any optimizer settings and still derive the factory's wallet addresses.
contract RiskEngineConstructorTest is Test {
    BuilderFactory internal factory;
    bytes32 internal hashOk;

    function setUp() public {
        factory = new BuilderFactory(address(this));
        hashOk = keccak256(
            abi.encodePacked(type(BuilderWallet).creationCode, abi.encode(address(factory)))
        );
    }

    function test_acceptsMatchingInitCodeHash_andDerivesFactoryAddresses() public {
        RiskEngineV2 re = new RiskEngineV2(
            address(0),
            address(factory),
            hashOk,
            RiskEngineParams.blueChip()
        );
        for (uint48 code = 1; code < 5; ++code) {
            // getFeeRecipient requires the wallet to exist, so deploy it through the factory first
            address deployed = factory.deployBuilder(code, address(this));
            assertEq(deployed, factory.predictBuilderWallet(code), "factory prediction");
            assertEq(re.getFeeRecipient(code), deployed, "engine derives the factory's wallet");
        }
        assertEq(re.getFeeRecipient(0), address(0), "code 0 has no recipient");
    }

    function testFuzz_rejectsWrongInitCodeHash(bytes32 wrong) public {
        vm.assume(wrong != hashOk);
        vm.expectRevert(RiskEngineV2.BuilderInitCodeHashMismatch.selector);
        new RiskEngineV2(address(0), address(factory), wrong, RiskEngineParams.blueChip());
    }

    function test_noFactorySkipsTheCheck() public {
        // test deployments pass no factory; any hash is accepted and getFeeRecipient derives from it unverified
        new RiskEngineV2(address(0), address(0), bytes32(0), RiskEngineParams.blueChip());
    }
}
