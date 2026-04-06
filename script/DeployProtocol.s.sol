// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Foundry
import "forge-std/Script.sol";
import {PanopticFactoryV3} from "@contracts/PanopticFactoryV3.sol";
import {PanopticFactoryV4} from "@contracts/PanopticFactoryV4.sol";
import {CollateralTrackerV2} from "@contracts/CollateralTracker.sol";
import {RiskEngine} from "@contracts/RiskEngine.sol";
import {BuilderFactory} from "@contracts/Builder.sol";
import {PanopticGuardian} from "@contracts/PanopticGuardian.sol";
import {PanopticPoolV2} from "@contracts/PanopticPool.sol";
import {ISemiFungiblePositionManager} from "@contracts/interfaces/ISemiFungiblePositionManager.sol";
import {SemiFungiblePositionManagerV3} from "@contracts/SemiFungiblePositionManagerV3.sol";
import {SemiFungiblePositionManagerV4} from "@contracts/SemiFungiblePositionManagerV4.sol";
import {IUniswapV3Factory} from "univ3-core/interfaces/IUniswapV3Factory.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Pointer, PointerLibrary} from "@types/Pointer.sol";
import {PanopticHelper} from "@test_periphery/PanopticHelper.sol";

// TEST RUN:
// forge script script/DeployProtocol.s.sol --rpc-url sepolia --turnkey --sender 0x62CB5f6E9F8Bca7032dDf993de8A02ae437D39b8
// DEPLOY + VERIFY
// forge script script/DeployProtocol.s.sol --rpc-url sepolia --turnkey --sender 0x62CB5f6E9F8Bca7032dDf993de8A02ae437D39b8 --broadcast --verify  --etherscan-api-key $ETHERSCAN_API_KEY
contract DeployProtocol is Script {
    struct PointerInfo {
        uint256 codeIndex;
        uint256 end;
        uint256 start;
    }

    function run() public {
        // 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543: sepolia
        IPoolManager uniPoolManager = IPoolManager(vm.envAddress("UNIV4_POOL_MANAGER"));
        IUniswapV3Factory uniV3Factory = IUniswapV3Factory(vm.envAddress("UNIV3_FACTORY"));

        vm.startBroadcast();

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
        string[][] memory indicesStr = new string[][](propsStr.length);
        for (uint256 i = 0; i < propsStr.length; i++) {
            string memory path = string.concat(".indices[", vm.toString(i), "]");
            indicesStr[i] = vm.parseJsonStringArray(metadata, path);
        }
        uint256[][] memory indices = new uint256[][](indicesStr.length);
        for (uint256 i = 0; i < indicesStr.length; i++) {
            indices[i] = new uint256[](indicesStr[i].length);
            for (uint256 j = 0; j < indicesStr[i].length; j++) {
                indices[i][j] = vm.parseUint(indicesStr[i][j]);
            }
        }

        SemiFungiblePositionManagerV4 sfpm = new SemiFungiblePositionManagerV4(
            uniPoolManager,
            21 * 10 ** 20,
            21 * 10 ** 20,
            10000
        );

        PanopticGuardian panopticGuardian = new PanopticGuardian(
            vm.envAddress("GUARDIAN_ADMIN"),
            vm.envAddress("TREASURER")
        );

        BuilderFactory builderFactory = new BuilderFactory(address(panopticGuardian));

        // risk engine MED
        new RiskEngine(10_000_000, 10_000_000, address(panopticGuardian), address(builderFactory));

        /*
        // risk engine LOW
        new RiskEngine(500_000, 250_000, 128, 5_000_000, 9_000_000);
        // risk engine HIGH
        new RiskEngine(4_500_000, 2_250_000, 128, 5_000_000, 9_000_000);
        */
        address collateralTracker = address(new CollateralTrackerV2());

        new PanopticFactoryV4(
            sfpm,
            uniPoolManager,
            address(new PanopticPoolV2(ISemiFungiblePositionManager(address(sfpm)))),
            collateralTracker,
            props,
            indices,
            pointers
        );

        SemiFungiblePositionManagerV3 sfpmV3 = new SemiFungiblePositionManagerV3(
            uniV3Factory,
            21 * 10 ** 20,
            10000
        );

        new PanopticFactoryV3(
            sfpmV3,
            uniV3Factory,
            address(new PanopticPoolV2(ISemiFungiblePositionManager(address(sfpmV3)))),
            collateralTracker,
            props,
            indices,
            pointers
        );

        //new PanopticHelper(ISemiFungiblePositionManager(address(sfpm)));

        // factory.tokenURI(0x00c34C41289e6c433723542BB1Eba79c6919504EDD);
        vm.stopBroadcast();
    }
}
