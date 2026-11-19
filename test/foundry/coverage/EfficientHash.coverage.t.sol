// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {EfficientHash} from "@libraries/EfficientHash.sol";

/// @notice Fills the coverage gaps left in `contracts/libraries/EfficientHash.sol` by the rest of the suite:
/// the three typed overloads, each checked against the `keccak256(abi.encodePacked(...))` it replaces.
contract EfficientHashCoverageTest is Test {
    function test_positionKeyOverload_matchesEncodePacked(
        address univ3pool,
        address owner,
        uint256 tokenType,
        int24 tickLower,
        int24 tickUpper
    ) public pure {
        assertEq(
            EfficientHash.efficientKeccak256(univ3pool, owner, tokenType, tickLower, tickUpper),
            keccak256(abi.encodePacked(univ3pool, owner, tokenType, tickLower, tickUpper))
        );
    }

    function test_positionKeyOverload_negativeTicksAreTruncatedTo24Bits() public pure {
        // sign-extended ticks must contribute exactly three bytes each
        bytes32 hash = EfficientHash.efficientKeccak256(
            address(0xA11CE),
            address(0xB0B),
            1,
            int24(-887272),
            int24(-1)
        );

        assertEq(
            hash,
            keccak256(
                abi.encodePacked(
                    address(0xA11CE),
                    address(0xB0B),
                    uint256(1),
                    bytes3(uint24(int24(-887272))),
                    bytes3(0xFFFFFF)
                )
            )
        );
    }

    function test_positionKeyOverload_isSensitiveToEveryField(
        address univ3pool,
        address owner,
        uint256 tokenType,
        int24 tickLower,
        int24 tickUpper
    ) public pure {
        bytes32 base = EfficientHash.efficientKeccak256(
            univ3pool,
            owner,
            tokenType,
            tickLower,
            tickUpper
        );

        unchecked {
            assertNotEq(
                base,
                EfficientHash.efficientKeccak256(
                    address(uint160(univ3pool) + 1),
                    owner,
                    tokenType,
                    tickLower,
                    tickUpper
                ),
                "pool"
            );
            assertNotEq(
                base,
                EfficientHash.efficientKeccak256(
                    univ3pool,
                    address(uint160(owner) + 1),
                    tokenType,
                    tickLower,
                    tickUpper
                ),
                "owner"
            );
            assertNotEq(
                base,
                EfficientHash.efficientKeccak256(
                    univ3pool,
                    owner,
                    tokenType + 1,
                    tickLower,
                    tickUpper
                ),
                "tokenType"
            );
            assertNotEq(
                base,
                EfficientHash.efficientKeccak256(
                    univ3pool,
                    owner,
                    tokenType,
                    tickLower + 1,
                    tickUpper
                ),
                "tickLower"
            );
            assertNotEq(
                base,
                EfficientHash.efficientKeccak256(
                    univ3pool,
                    owner,
                    tokenType,
                    tickLower,
                    tickUpper + 1
                ),
                "tickUpper"
            );
        }
    }

    function test_chunkKeyOverload_matchesEncodePacked(
        int24 strike,
        int24 width,
        uint256 tokenType
    ) public pure {
        bytes32 hash = EfficientHash.efficientKeccak256(strike, width, tokenType);

        assertEq(hash, keccak256(abi.encodePacked(strike, width, tokenType)), "encodePacked");
        // and with the generic bytes overload the rest of the code base uses for chunk keys
        assertEq(
            hash,
            EfficientHash.efficientKeccak256(abi.encodePacked(strike, width, tokenType)),
            "bytes overload"
        );
    }

    function test_arrayOverload_matchesEncodePacked(uint256[] memory data) public pure {
        assertEq(EfficientHash.efficientKeccak256(data), keccak256(abi.encodePacked(data)));
    }

    function test_arrayOverload_emptyArray() public pure {
        assertEq(EfficientHash.efficientKeccak256(new uint256[](0)), keccak256(""));
    }

    function test_arrayOverload_dependsOnOrderAndLength() public pure {
        uint256[] memory ab = new uint256[](2);
        (ab[0], ab[1]) = (1, 2);
        uint256[] memory ba = new uint256[](2);
        (ba[0], ba[1]) = (2, 1);
        uint256[] memory a = new uint256[](1);
        a[0] = 1;
        uint256[] memory aZero = new uint256[](2);
        aZero[0] = 1;

        assertNotEq(EfficientHash.efficientKeccak256(ab), EfficientHash.efficientKeccak256(ba));
        // a trailing zero element is hashed, not ignored
        assertNotEq(EfficientHash.efficientKeccak256(a), EfficientHash.efficientKeccak256(aZero));
    }

    function test_overloads_doNotDisturbSurroundingMemory(uint256[] memory data) public pure {
        // the typed overloads write past the free memory pointer without moving it:
        // an array allocated before the call must read back unchanged afterwards
        uint256[] memory copy = new uint256[](data.length);
        for (uint256 i; i < data.length; ++i) copy[i] = data[i];

        EfficientHash.efficientKeccak256(address(1), address(2), 3, 4, 5);
        EfficientHash.efficientKeccak256(int24(1), int24(2), 3);
        EfficientHash.efficientKeccak256(data);

        assertEq(data, copy);
    }
}
