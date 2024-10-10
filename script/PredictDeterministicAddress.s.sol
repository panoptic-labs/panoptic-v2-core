// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

contract PredictDeterministicAddress is Script {
    function predictDeterministicAddress(
        address v3Pool,
        address implementation,
        uint96 salt,
        address deployer
    ) external view returns (address predicted) {
        bytes32 newSalt = bytes32(
            abi.encodePacked(uint80(uint160(deployer) >> 80), uint80(uint160(v3Pool) >> 80), salt)
        );
        console.log("deployer");
        console.log(deployer);

        console.log("\n");
        console.log("uint160(deployer)");
        console.log(uint160(deployer));

        console.log("\n");
        console.log("uint80(uint160(deployer))");
        console.log(uint80(uint160(deployer)));

        console.log("\n");
        console.log("deployer >> 80");
        console.logUint(uint80(uint160(deployer)) >> 80);

        ////// abi tests
        console.log("\n");
        console.log("abi.encodePacked( \
          uint80(uint160(deployer) >> 80), \
        )");
        bytes32 byteesss = bytes32(abi.encodePacked(uint80(uint160(deployer) >> 80)));
        console.logBytes32(byteesss);

        console.log("\n");
        console.log("new salt");
        console.logBytes32(newSalt);

        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x38), deployer)
            mstore(add(ptr, 0x24), 0x5af43d82803e903d91602b57fd5bf3ff)
            mstore(add(ptr, 0x14), implementation)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73)
            mstore(add(ptr, 0x58), newSalt)
            mstore(add(ptr, 0x78), keccak256(add(ptr, 0x0c), 0x37))
            predicted := keccak256(add(ptr, 0x43), 0x55)
        }
    }

    function run() public {
        // address deployer = 0x17b393d0c5a27136deC50aC94715CCcA1D8A0B0e; // factory
        address v3pool = 0x1D2abCcE86Ddaf69Ae85a22DB2F11e6ce43A89A1;
        address deployer = 0x7643c4F21661691fb851AfedaF627695672C9fac; // me
        address addr = this.predictDeterministicAddress(
            v3pool,
            0x96Ee1f82ddc769e54dd09555f4deB2431Ae4264F,
            29677519060991083555293295980,
            deployer
        );
        console.log("predicted address");
        console.log(addr);
    }
}
