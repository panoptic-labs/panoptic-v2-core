// SPDX-License-Identifier: The Unlicense

pragma solidity =0.8.25;

import {console2} from "forge-std/Test.sol";

import {LibString} from "solady//utils/LibString.sol";
import {LibZip} from "solady/utils/LibZip.sol";
import {Base64} from "solady/utils/Base64.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

import {Art} from "@periphery/SVGs/Art.sol";
import {Frames} from "@periphery/SVGs/Frames.sol";
import {Filters} from "@periphery/SVGs/Filters.sol";
import {Labels} from "@periphery/SVGs/Labels.sol";

library NFTBuilder {
    /// @notice The Uniswap V3 factory contract to use

    using Labels for string;
    using Filters for string;
    using Frames for string;
    using Art for string;
    using LibString for string;
    using LibString for uint256;

    function constructTokenURI(
        address deployedAddress,
        address token0,
        address token1,
        uint24 fee
    ) external view returns (string memory) {
        uint256 lastCharVal = uint160(deployedAddress) & 0xF;
        uint256 rarity = numberOfLeadingHexZeros(deployedAddress);

        string memory symbol0 = ERC20(token0).symbol();
        string memory name0 = ERC20(token0).name();
        string memory symbol1 = ERC20(token1).symbol();
        string memory name1 = ERC20(token1).name();
        string memory chainid = LibString.toString(block.chainid);

        string memory svgOut = generateSVG(deployedAddress);

        return svgOut;
    }

    function generateSVG(address deployedAddress) public view returns (string memory) {
        uint256 lastCharVal = uint160(deployedAddress) & 0xF;
        uint256 rarity = numberOfLeadingHexZeros(deployedAddress);
        string memory svgIn;
        if (rarity < 4) {
            svgIn = Frames.frame0();
        } else if (rarity < 8) {
            svgIn = Frames.frame4();
        } else if (rarity < 12) {
            svgIn = Frames.frame8();
        } else if (rarity < 16) {
            svgIn = Frames.frame12();
        } else if (rarity < 20) {
            svgIn = Frames.frame16();
        } else if (rarity < 24) {
            svgIn = Frames.frame20();
        }

        string memory svgFinal = svgIn.addLabel(lastCharVal).addArt(lastCharVal).addFilter(rarity);
        return svgFinal;
    }

    function generateBase64EncodedSVG(address input) public view returns (string memory) {
        string memory svg = generateSVG(input);
        bytes memory svgBytes = bytes(svg);
        string memory base64EncodedSVG = Base64.encode(svgBytes);
        return base64EncodedSVG;
    }

    function compressData(string memory input) public view returns (bytes memory) {
        bytes memory foo = LibZip.flzCompress(bytes(input));
        return foo;
    }

    function decompressData(bytes memory input) public view returns (string memory) {
        return string(LibZip.flzDecompress(input));
    }

    /// @notice Get the number of leading hex characters in an address.
    ///     0x0000bababaab...     0xababababab...
    ///          ▲                 ▲
    ///          │                 │
    ///     4 leading hex      0 leading hex
    ///    character zeros    character zeros
    ///
    /// @param addr The address to get the number of leading zero hex characters for
    /// @return The number of leading zero hex characters in the address
    function numberOfLeadingHexZeros(address addr) internal pure returns (uint256) {
        unchecked {
            return addr == address(0) ? 40 : 39 - mostSignificantNibble(uint160(addr));
        }
    }

    /// @notice Returns the index of the most significant nibble of the 160-bit number,
    /// where the least significant nibble is at index 0 and the most significant nibble is at index 40.
    /// @param x The value for which to compute the most significant nibble
    /// @return r The index of the most significant nibble (default: 0)
    function mostSignificantNibble(uint160 x) internal pure returns (uint256 r) {
        unchecked {
            if (x >= 0x100000000000000000000000000000000) {
                x >>= 128;
                r += 32;
            }
            if (x >= 0x10000000000000000) {
                x >>= 64;
                r += 16;
            }
            if (x >= 0x100000000) {
                x >>= 32;
                r += 8;
            }
            if (x >= 0x10000) {
                x >>= 16;
                r += 4;
            }
            if (x >= 0x100) {
                x >>= 8;
                r += 2;
            }
            if (x >= 0x10) {
                r += 1;
            }
        }
    }
}
