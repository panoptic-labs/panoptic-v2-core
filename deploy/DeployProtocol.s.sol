// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

// Foundry
import "forge-std/Script.sol";
// Uniswap - Panoptic's version 0.8
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
// Internal
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {Pointer, PointerLibrary} from "@types/Pointer.sol";

struct PointerInfo {
    uint256 codeIndex;
    uint256 end;
    uint256 start;
}

/**
 * @title Deployment script that deploys PanopticFactory, SFPM, and dependencies
 * @author Axicon Labs Limited
 */
contract DeployProtocol is Script {
    function run() public {
        uint256 DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");

        IUniswapV3Factory UNISWAP_V3_FACTORY = IUniswapV3Factory(
            vm.envAddress("UNISWAP_V3_FACTORY")
        );
        address WETH9 = vm.envAddress("WETH9");

        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        SemiFungiblePositionManager SFPM = new SemiFungiblePositionManager(UNISWAP_V3_FACTORY);

        // Import the Panoptic Pool reference (for cloning)
        address poolReference = address(new PanopticPool(SFPM));

        // Import the Collateral Tracker reference (for cloning)
        address collateralReference = address(
            new CollateralTracker(10, 2_000, 1_000, -1_024, 5_000, 9_000, 20_000)
        );

        // Read metadata for deployment
        string memory metadata = vm.readFile("./metadata/out/MetadataPackage.json");

        // Parse bytecodes from metadata
        bytes[] memory bytecodes = vm.parseJsonBytesArray(metadata, ".bytecodes");
        address[] memory pointerAddresses = new address[](bytecodes.length);

        // Deploy bytecodes and store pointers
        for (uint256 i = 0; i < bytecodes.length; i++) {
            bytes memory code = bytecodes[i];
            address pointer;
            assembly {
                pointer := create(0, add(code, 0x20), mload(code))
                if iszero(extcodesize(pointer)) {
                    revert(0, 0)
                }
            }
            pointerAddresses[i] = pointer;
        }

        // Decode pointers from metadata
        PointerInfo[][] memory pointerInfo = abi.decode(
            vm.parseJson(metadata, ".pointers"),
            (PointerInfo[][])
        );
        Pointer[][] memory pointers = new Pointer[][](pointerInfo.length);

        // Create pointers from decoded information
        for (uint256 i = 0; i < pointerInfo.length; i++) {
            pointers[i] = new Pointer[](pointerInfo[i].length);
            for (uint256 j = 0; j < pointerInfo[i].length; j++) {
                pointers[i][j] = PointerLibrary.createPointer(
                    pointerAddresses[pointerInfo[i][j].codeIndex],
                    uint48(pointerInfo[i][j].start),
                    uint48(pointerInfo[i][j].end)
                );
            }
        }

        // Parse properties from metadata
        string[] memory propsStr = vm.parseJsonStringArray(metadata, ".properties");
        bytes32[] memory props = new bytes32[](propsStr.length);
        for (uint256 i = 0; i < propsStr.length; i++) {
            props[i] = bytes32(bytes(propsStr[i]));
        }

        // Decode and parse indices from metadata
        string[][] memory indicesStr = abi.decode(vm.parseJson(metadata, ".indices"), (string[][]));
        uint256[][] memory indices = new uint256[][](indicesStr.length);
        for (uint256 i = 0; i < indicesStr.length; i++) {
            indices[i] = new uint256[](indicesStr[i].length);
            for (uint256 j = 0; j < indicesStr[i].length; j++) {
                indices[i][j] = vm.parseUint(indicesStr[i][j]);
            }
        }

        // Deploy the PanopticFactory with the new constructor parameters
        PanopticFactory factory = new PanopticFactory(
            WETH9,
            SFPM,
            UNISWAP_V3_FACTORY,
            poolReference,
            collateralReference,
            props,
            indices,
            pointers
        );

        vm.stopBroadcast();
    }
}
