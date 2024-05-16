// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;
// Custom types
import {Pointer} from "@types/Pointer.sol";

import {ERC721} from "solmate/tokens/ERC721.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Base64} from "solady/utils/Base64.sol";

import {MetadataStore} from "@base/MetadataStore.sol";

import {PanopticPool} from "@contracts/PanopticPool.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import "forge-std/Test.sol";

contract FactoryNFT is MetadataStore, ERC721 {
    using LibString for string;

    constructor(
        bytes32[] memory properties,
        uint256[][] memory indices,
        Pointer[][] memory pointers
    )
        MetadataStore(properties, indices, pointers)
        ERC721("Panoptic Factory Deployer NFTs", "PANOPTIC-NFT")
    {}

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        address panopticPool = address(uint160(tokenId));

        uint256 lastCharVal = uint160(panopticPool) & 0xF;
        uint256 rarity = PanopticMath.numberOfLeadingHexZeros(panopticPool);

        string memory symbol0 = PanopticMath.safeERC20Symbol(
            PanopticPool(panopticPool).univ3pool().token0()
        );
        string memory symbol1 = PanopticMath.safeERC20Symbol(
            PanopticPool(panopticPool).univ3pool().token1()
        );
        string memory svgOut = generateSVGArt(lastCharVal, rarity);

        svgOut = generateSVGInfo(svgOut, panopticPool, rarity, symbol0, symbol1);
        console2.log(
            string.concat(
                '<td><img src="data:image/svg+xml;base64,',
                Base64.encode(bytes(svgOut)),
                '" width="300px"></td>'
            )
        );
        return
            string(
                abi.encodePacked(
                    "data:application/json;base64,",
                    Base64.encode(
                        bytes(
                            abi.encodePacked(
                                '{"name":"',
                                abi.encodePacked(
                                    LibString.toHexString(uint256(uint160(panopticPool)), 20),
                                    "-",
                                    string.concat(
                                        metadata[bytes32("strategies")][lastCharVal].dataStr(),
                                        "-",
                                        LibString.toString(rarity)
                                    )
                                ),
                                '", "description":"',
                                string.concat(
                                    "Panoptic Pool for the ",
                                    symbol0,
                                    "-",
                                    symbol1,
                                    "-",
                                    // @TODO: doesnt support fractional bips -- need to include in open PR for related issue
                                    LibString.toString(
                                        PanopticPool(panopticPool).univ3pool().fee() / 100
                                    ),
                                    "bps market"
                                ),
                                '", "attributes": [{',
                                //'"trait_type": "Rarity", "value": "',
                                //LibString.toString(rarity),
                                '"trait_type": "Rarity", "value": "',
                                string.concat(
                                    LibString.toString(rarity),
                                    " - ",
                                    metadata[bytes32("rarities")][rarity].dataStr()
                                ),
                                '"}, {"trait_type": "Strategy", "value": "',
                                metadata[bytes32("strategies")][lastCharVal].dataStr(),
                                '"}, {"trait_type": "ChainId", "value": "',
                                getChainName(),
                                '"}]',
                                '", "image": "',
                                "data:image/svg+xml;base64,",
                                Base64.encode(bytes(svgOut)),
                                '"}'
                            )
                        )
                    )
                )
            );
    }

    function tokenURI(
        uint256 tokenId,
        uint256 rarity,
        uint256 lastCharVal
    ) public view returns (string memory) {
        address panopticPool = address(uint160(tokenId));

        string memory symbol0 = PanopticMath.safeERC20Symbol(
            PanopticPool(panopticPool).univ3pool().token0()
        );
        string memory symbol1 = PanopticMath.safeERC20Symbol(
            PanopticPool(panopticPool).univ3pool().token1()
        );
        string memory svgOut = generateSVGArt(lastCharVal, rarity);

        svgOut = generateSVGInfo(svgOut, panopticPool, rarity, symbol0, symbol1);
        console2.log(
            string.concat(
                '<td><img src="data:image/svg+xml;base64,',
                Base64.encode(bytes(svgOut)),
                '" width="300px"></td>'
            )
        );
        return
            string(
                abi.encodePacked(
                    "data:application/json;base64,",
                    Base64.encode(
                        bytes(
                            abi.encodePacked(
                                '{"name":"',
                                abi.encodePacked(
                                    LibString.toHexString(uint256(uint160(panopticPool)), 20),
                                    "-",
                                    string.concat(
                                        metadata[bytes32("strategies")][lastCharVal].dataStr(),
                                        "-",
                                        LibString.toString(rarity)
                                    )
                                ),
                                '", "description":"',
                                string.concat(
                                    "Panoptic Pool for the ",
                                    symbol0,
                                    "-",
                                    symbol1,
                                    "-",
                                    // @TODO: doesnt support fractional bips -- need to include in open PR for related issue
                                    LibString.toString(
                                        PanopticPool(panopticPool).univ3pool().fee() / 100
                                    ),
                                    "bps market"
                                ),
                                '", "attributes": [{',
                                //'"trait_type": "Rarity", "value": "',
                                //LibString.toString(rarity),
                                '"trait_type": "Rarity", "value": "',
                                string.concat(
                                    LibString.toString(rarity),
                                    " - ",
                                    metadata[bytes32("rarities")][rarity].dataStr()
                                ),
                                '"}, {"trait_type": "Strategy", "value": "',
                                metadata[bytes32("strategies")][lastCharVal].dataStr(),
                                '"}, {"trait_type": "ChainId", "value": "',
                                getChainName(),
                                '"}]',
                                '", "image": "',
                                "data:image/svg+xml;base64,",
                                Base64.encode(bytes(svgOut)),
                                '"}'
                            )
                        )
                    )
                )
            );
    }

    function generateSVGArt(
        uint256 lastCharVal,
        uint256 rarity
    ) internal view returns (string memory svgOut) {
        svgOut = metadata[bytes32("frames")][
            rarity < 18 ? rarity / 3 : rarity < 23 ? 23 - rarity : 0
        ].decompressedDataStr();
        svgOut = svgOut.replace(
            "<!-- LABEL -->",
            write(metadata[bytes32("strategies")][lastCharVal].dataStr(), getMaxLabelWidth(rarity))
        );

        svgOut = svgOut
            .replace(
                "<!-- TEXT -->",
                metadata[bytes32("descriptions")][lastCharVal].decompressedDataStr()
            )
            .replace("<!-- ART -->", metadata[bytes32("art")][lastCharVal].decompressedDataStr())
            .replace("<!-- FILTER -->", metadata[bytes32("filters")][rarity].decompressedDataStr());
    }

    function generateSVGInfo(
        string memory svgIn,
        address panopticPool,
        uint256 rarity,
        string memory symbol0,
        string memory symbol1
    ) internal view returns (string memory) {
        svgIn = svgIn
            .replace("<!-- POOLADDRESS -->", LibString.toHexString(uint160(panopticPool), 20))
            .replace("<!-- CHAINID -->", getChainName());

        svgIn = svgIn.replace(
            "<!-- RARITY_NAME -->",
            write(metadata[bytes32("rarities")][rarity].dataStr(), getMaxRarityWidth(rarity))
        );

        return
            svgIn
                .replace("<!-- RARITY -->", write(LibString.toString(rarity)))
                .replace("<!-- SYMBOL0 -->", write(symbol0, getMaxSymbolWidth(rarity)))
                .replace("<!-- SYMBOL1 -->", write(symbol1, getMaxSymbolWidth(rarity)));
    }

    /// @notice Get the name of the current chain.
    /// @return THe name of the current chain as a string, or "???" if not supported.
    function getChainName() internal view returns (string memory) {
        if (block.chainid == 1) {
            return "Ethereum Mainnet";
        } else if (block.chainid == 56) {
            return "BNB Smart Chain Mainnet";
        } else if (block.chainid == 42161) {
            return "Arbitrum One";
        } else if (block.chainid == 8453) {
            return "Base";
        } else if (block.chainid == 43114) {
            return "Avalanche C-Chain";
        } else if (block.chainid == 137) {
            return "Polygon Mainnet";
        } else if (block.chainid == 10) {
            return "OP Mainnet";
        } else if (block.chainid == 42220) {
            return "Celo Mainnet";
        } else if (block.chainid == 238) {
            return "Blast Mainnet";
        } else {
            // @TODO: do we want to return the chainId as a string?
            return "???";
        }
    }

    function write(string memory input) internal view returns (string memory) {
        return write(input, type(uint256).max);
    }

    function write(string memory input, uint256 maxWidth) internal view returns (string memory) {
        bytes memory b = bytes(input);

        string memory d;
        uint256 offset;

        for (uint256 i = 0; i < b.length; ++i) {
            uint256 charOffset = uint256(
                bytes32(metadata[bytes32("charOffsets")][uint256(bytes32(b[i]))].data())
            );
            offset += charOffset;

            d = string.concat(
                '<g transform="translate(-',
                LibString.toString(charOffset),
                ', 0)">',
                d,
                metadata[bytes32("charPaths")][uint256(bytes32(b[i]))].dataStr(),
                "</g>"
            );
        }

        string memory factor;
        if (offset > maxWidth) {
            uint256 _scale = (3400 * maxWidth) / offset;
            if (_scale > 99) {
                factor = LibString.toString(_scale);
            } else {
                factor = string.concat("0", LibString.toString(_scale));
            }
        } else {
            factor = "34";
        }

        d = string.concat(
            '<g transform="scale(0.0',
            factor,
            ") translate(",
            LibString.toString(offset / 2),
            ', 0)">',
            d,
            "</g>"
        );
        return d;
    }

    function getMaxSymbolWidth(uint256 rarity) internal pure returns (uint256 width) {
        if (rarity < 3) {
            width = 1600;
        } else if (rarity < 9) {
            width = 1350;
        } else if (rarity < 12) {
            width = 1450;
        } else if (rarity < 15) {
            width = 1350;
        } else if (rarity < 19) {
            width = 1250;
        } else if (rarity < 20) {
            width = 1350;
        } else if (rarity < 21) {
            width = 1450;
        } else if (rarity < 23) {
            width = 1350;
        } else if (rarity >= 23) {
            width = 1600;
        }
    }

    function getMaxRarityWidth(uint256 rarity) internal pure returns (uint256 width) {
        if (rarity < 3) {
            width = 210;
        } else if (rarity < 6) {
            width = 220;
        } else if (rarity < 9) {
            width = 210;
        } else if (rarity < 12) {
            width = 220;
        } else if (rarity < 15) {
            width = 260;
        } else if (rarity < 19) {
            width = 225;
        } else if (rarity < 20) {
            width = 260;
        } else if (rarity < 21) {
            width = 220;
        } else if (rarity < 22) {
            width = 210;
        } else if (rarity < 23) {
            width = 220;
        } else if (rarity >= 23) {
            width = 210;
        }
    }

    function getMaxLabelWidth(uint256 rarity) internal pure returns (uint256 width) {
        if (rarity < 6) {
            width = 9000;
        } else if (rarity < 22) {
            width = 3900;
        } else if (rarity > 22) {
            width = 9000;
        }
    }
}
