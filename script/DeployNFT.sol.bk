// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

// Foundry
import "forge-std/Script.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {IUniswapV3Factory} from "univ3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {Pointer, PointerLibrary} from "@types/Pointer.sol";

/**
 * @title Deployment script that deploys two tokens, a Uniswap V3 pool, and a Panoptic Pool on top of that.
 * @author Axicon Labs Limited
 */
contract DeployNFT is Script {
    struct PointerInfo {
        uint256 codeIndex;
        uint256 end;
        uint256 start;
    }

    function run() public {
        uint256 DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        string memory metadata = vm.readFile("./metadata/out/MetadataPackage.json");

        bytes[] memory bytecodes = vm.parseJsonBytesArray(metadata, ".bytecodes");
        address[] memory pointerAddresses = new address[](bytecodes.length);

        for (uint256 i = 0; i < bytecodes.length; i++) {
            bytes memory code = bytecodes[i];
            address pointer;
            // deploy code and store pointer
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
        Pointer[][] memory pointers = new Pointer[][](pointerInfo.length);

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
        bytes32[] memory props = new bytes32[](propsStr.length);
        for (uint256 i = 0; i < propsStr.length; i++) {
            props[i] = bytes32(bytes(propsStr[i]));
        }

        string[][] memory indicesStr = abi.decode(vm.parseJson(metadata, ".indices"), (string[][]));
        uint256[][] memory indices = new uint256[][](indicesStr.length);
        for (uint256 i = 0; i < indicesStr.length; i++) {
            indices[i] = new uint256[](indicesStr[i].length);
            for (uint256 j = 0; j < indicesStr[i].length; j++) {
                indices[i][j] = vm.parseUint(indicesStr[i][j]);
            }
        }

        PanopticFactory factory = new PanopticFactory(
            address(0),
            SemiFungiblePositionManager(address(0)),
            IUniswapV3Factory(address(0)),
            address(0),
            address(0),
            props,
            indices,
            pointers
        );
        factory.tokenURI(0x00c34C41289e6c433723542BB1Eba79c6919504EDD);
        vm.stopBroadcast();
    }
}
