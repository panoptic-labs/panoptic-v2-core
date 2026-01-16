// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
// V3 imports
import {PanopticFactory as PanopticFactoryV3} from "@contracts/PanopticFactory.sol";
import {SemiFungiblePositionManager as SemiFungiblePositionManagerV3} from "@contracts/SemiFungiblePositionManager.sol";
import {IUniswapV3Factory} from "univ3-core/interfaces/IUniswapV3Factory.sol";
// V4 imports
import {PanopticFactory as PanopticFactoryV4} from "@contracts/PanopticFactoryV4.sol";
import {SemiFungiblePositionManager as SemiFungiblePositionManagerV4} from "@contracts/SemiFungiblePositionManagerV4.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
// Shared imports
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {RiskEngine} from "@contracts/RiskEngine.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {ISemiFungiblePositionManager} from "@contracts/interfaces/ISemiFungiblePositionManager.sol";
import {Pointer, PointerLibrary} from "@types/Pointer.sol";
import {PanopticHelper} from "@test_periphery/PanopticHelper.sol";

contract DeployProtocol is Script {
    struct PointerInfo {
        uint256 codeIndex;
        uint256 end;
        uint256 start;
    }

    function run() public {
        uint256 DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
        IUniswapV3Factory univ3Factory = IUniswapV3Factory(vm.envAddress("UNIV3_FACTORY"));
        IPoolManager poolManagerV4 = IPoolManager(vm.envAddress("POOL_MANAGER_V4"));

        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        // Deploy metadata
        (
            bytes32[] memory props,
            uint256[][] memory indices,
            Pointer[][] memory pointers
        ) = _deployMetadata();

        // Shared
        RiskEngine riskEngine = new RiskEngine(10_000_000, 10_000_000, address(0), address(0));
        CollateralTracker collateralImpl = new CollateralTracker(10);

        console.log("RiskEngine:", address(riskEngine));
        console.log("CollateralTracker impl:", address(collateralImpl));

        // V3
        SemiFungiblePositionManagerV3 sfpmV3 = new SemiFungiblePositionManagerV3(
            univ3Factory,
            10 ** 13,
            0
        );
        PanopticPool poolImplV3 = new PanopticPool(ISemiFungiblePositionManager(address(sfpmV3)));
        PanopticFactoryV3 factoryV3 = new PanopticFactoryV3(
            sfpmV3,
            univ3Factory,
            address(poolImplV3),
            address(collateralImpl),
            props,
            indices,
            pointers
        );

        console.log("SFPM V3:", address(sfpmV3));
        console.log("PanopticPool V3 impl:", address(poolImplV3));
        console.log("PanopticFactory V3:", address(factoryV3));

        // V4
        SemiFungiblePositionManagerV4 sfpmV4 = new SemiFungiblePositionManagerV4(
            poolManagerV4,
            10 ** 13,
            10 ** 13,
            0
        );
        PanopticPool poolImplV4 = new PanopticPool(ISemiFungiblePositionManager(address(sfpmV4)));
        PanopticFactoryV4 factoryV4 = new PanopticFactoryV4(
            sfpmV4,
            poolManagerV4,
            address(poolImplV4),
            address(collateralImpl),
            props,
            indices,
            pointers
        );

        console.log("SFPM V4:", address(sfpmV4));
        console.log("PanopticPool V4 impl:", address(poolImplV4));
        console.log("PanopticFactory V4:", address(factoryV4));

        // Helper
        new PanopticHelper(ISemiFungiblePositionManager(address(sfpmV3)));

        vm.stopBroadcast();
    }

    function _deployMetadata()
        internal
        returns (bytes32[] memory props, uint256[][] memory indices, Pointer[][] memory pointers)
    {
        string memory metadata = vm.readFile("./metadata/out/MetadataPackage.json");

        bytes[] memory bytecodes = vm.parseJsonBytesArray(metadata, ".bytecodes");
        address[] memory pointerAddresses = new address[](bytecodes.length);

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

        PointerInfo[][] memory pointerInfo = abi.decode(
            vm.parseJson(metadata, ".pointers"),
            (PointerInfo[][])
        );
        pointers = new Pointer[][](pointerInfo.length);

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

        string[] memory propsStr = vm.parseJsonStringArray(metadata, ".properties");
        props = new bytes32[](propsStr.length);
        for (uint256 i = 0; i < propsStr.length; i++) {
            props[i] = bytes32(bytes(propsStr[i]));
        }
        string[][] memory indicesStr = new string[][](propsStr.length);
        for (uint256 i = 0; i < propsStr.length; i++) {
            string memory path = string.concat(".indices[", vm.toString(i), "]");
            indicesStr[i] = vm.parseJsonStringArray(metadata, path);
        }
        indices = new uint256[][](indicesStr.length);
        for (uint256 i = 0; i < indicesStr.length; i++) {
            indices[i] = new uint256[](indicesStr[i].length);
            for (uint256 j = 0; j < indicesStr[i].length; j++) {
                indices[i][j] = vm.parseUint(indicesStr[i][j]);
            }
        }
    }
}
