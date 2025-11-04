// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title Efficient Keccak256 Library
/// @notice Provides gas-efficient keccak256 hashing using inline assembly
library EfficientHash {
    /// @notice Efficiently compute keccak256 hash for position key (address, address, uint256, int24, int24)
    /// @param univ3pool The Uniswap V3 pool address (20 bytes)
    /// @param owner The owner address (20 bytes)
    /// @param tokenType The token type (32 bytes)
    /// @param tickLower The lower tick (3 bytes when packed)
    /// @param tickUpper The upper tick (3 bytes when packed)
    /// @return hash The keccak256 hash of the packed data
    function efficientKeccak256(
        address univ3pool,
        address owner,
        uint256 tokenType,
        int24 tickLower,
        int24 tickUpper
    ) internal pure returns (bytes32 hash) {
        assembly {
            let freeMemPtr := mload(0x40)
            // Pack: 20 + 20 + 32 + 3 + 3 = 78 bytes (0x4e)
            mstore(freeMemPtr, shl(96, univ3pool)) // address at byte 0
            mstore(add(freeMemPtr, 0x14), shl(96, owner)) // address at byte 20
            mstore(add(freeMemPtr, 0x28), tokenType) // uint256 at byte 40
            mstore(add(freeMemPtr, 0x48), shl(232, and(tickLower, 0xFFFFFF))) // int24 at byte 72
            mstore(add(freeMemPtr, 0x4b), shl(232, and(tickUpper, 0xFFFFFF))) // int24 at byte 75

            hash := keccak256(freeMemPtr, 0x4e)
        }
    }

    /// @notice Efficiently compute keccak256 hash for chunk key (int24, int24, uint256)
    /// @param strike The strike tick (3 bytes when packed)
    /// @param width The width (3 bytes when packed)
    /// @param tokenType The token type (32 bytes)
    /// @return hash The keccak256 hash of the packed data
    function efficientKeccak256(
        int24 strike,
        int24 width,
        uint256 tokenType
    ) internal pure returns (bytes32 hash) {
        assembly {
            let freeMemPtr := mload(0x40)
            // Pack: 3 + 3 + 32 = 38 bytes (0x26)
            mstore(freeMemPtr, shl(232, and(strike, 0xFFFFFF))) // int24 at byte 0
            mstore(add(freeMemPtr, 0x03), shl(232, and(width, 0xFFFFFF))) // int24 at byte 3
            mstore(add(freeMemPtr, 0x06), tokenType) // uint256 at byte 6

            hash := keccak256(freeMemPtr, 0x26)
        }
    }

    /// @notice Efficiently compute keccak256 hash for a uint256 array
    /// @param data The uint256 array to hash
    /// @return hash The keccak256 hash of the packed data
    function efficientKeccak256(uint256[] memory data) internal pure returns (bytes32 hash) {
        assembly {
            // data layout in memory: [length][item0][item1]...
            // Skip the length field (32 bytes) and hash the rest
            let dataLength := mload(data)
            let dataStart := add(data, 0x20)
            let bytesToHash := mul(dataLength, 0x20)

            hash := keccak256(dataStart, bytesToHash)
        }
    }

    /// @notice Efficiently compute keccak256 hash for bytes memory
    /// @param data The bytes to hash
    /// @return hash The keccak256 hash of the data
    function efficientKeccak256(bytes memory data) internal pure returns (bytes32 hash) {
        assembly {
            // bytes layout in memory: [length][data...]
            let dataLength := mload(data)
            let dataStart := add(data, 0x20)

            hash := keccak256(dataStart, dataLength)
        }
    }
}
