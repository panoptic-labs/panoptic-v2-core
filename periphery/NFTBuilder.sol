// SPDX-License-Identifier: The Unlicense

pragma solidity =0.8.25;

import {console2} from "forge-std/Test.sol";

import {NFTLib} from "@libraries//NFTLib.sol";
import {Pointer} from "@types/Pointer.sol";

import {LibString} from "solady//utils/LibString.sol";
import {LibZip} from "solady/utils/LibZip.sol";
import {Base64} from "solady/utils/Base64.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

import {Art} from "@periphery/SVGs/Art.sol";
import {Frames} from "@periphery/SVGs/Frames.sol";
import {Filters} from "@periphery/SVGs/Filters.sol";
import {Labels} from "@periphery/SVGs/Labels.sol";
import {Letters} from "@periphery/SVGs/Letters.sol";

library NFTBuilder {
    /// @notice The Uniswap V3 factory contract to use

    using Labels for string;
    using Filters for string;
    using Letters for string;
    using Frames for string;
    using Art for string;
    using LibString for string;
    using LibString for uint256;

    bytes16 internal constant ALPHABET = "0123456789abcdef";

    function constructTokenURI(
        address deployedAddress,
        address token0,
        address token1,
        uint24 fee,
        mapping(bytes32 property => Pointer[] pointers) storage metadata
    ) external view returns (string memory) {}

    /// @notice Converts a `uint256` to its ASCII `string` hexadecimal representation with fixed length.
    /// @dev Credit to Open Zeppelin under MIT license https://github.com/OpenZeppelin/openzeppelin-contracts/blob/243adff49ce1700e0ecb99fe522fb16cff1d1ddc/contracts/utils/Strings.sol#L55
    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = ALPHABET[value & 0xf];
            value >>= 4;
        }
        require(value == 0, "Strings: hex length insufficient");
        return string(buffer);
    }
}
