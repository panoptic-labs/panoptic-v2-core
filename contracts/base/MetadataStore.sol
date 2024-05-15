// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.18;

import {Pointer} from "@types/Pointer.sol";

contract MetadataStore {
    mapping(bytes32 property => mapping(uint256 index => Pointer pointer)) internal metadata;

    constructor(
        bytes32[] memory properties,
        uint256[][] memory indices,
        Pointer[][] memory pointers
    ) {
        for (uint256 i = 0; i < properties.length; i++) {
            for (uint256 j = 0; j < indices[i].length; j++) {
                metadata[properties[i]][indices[i][j]] = pointers[i][j];
            }
        }
    }
}
