// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {FactoryNFT} from "@base/FactoryNFT.sol";
import {Pointer, PointerLibrary} from "@types/Pointer.sol";
import {LibString} from "solady/utils/LibString.sol";
import {LibZip} from "solady/utils/LibZip.sol";
import {Base64} from "solady/utils/Base64.sol";

/// @dev Exposes the internal view/pure helpers of FactoryNFT.
contract FactoryNFTHarness is FactoryNFT {
    constructor(
        bytes32[] memory properties,
        uint256[][] memory indices,
        Pointer[][] memory pointers
    ) FactoryNFT(properties, indices, pointers) {}

    function chainName() external view returns (string memory) {
        return getChainName();
    }

    function writeDefault(string memory chars) external view returns (string memory) {
        return write(chars);
    }

    function writeScaled(
        string memory chars,
        uint256 maxWidth
    ) external view returns (string memory) {
        return write(chars, maxWidth);
    }

    function symbolWidth(uint256 rarity) external pure returns (uint256) {
        return maxSymbolWidth(rarity);
    }

    function rarityLabelWidth(uint256 rarity) external pure returns (uint256) {
        return maxRarityLabelWidth(rarity);
    }

    function strategyLabelWidth(uint256 rarity) external pure returns (uint256) {
        return maxStrategyLabelWidth(rarity);
    }

    function svgArt(uint256 lastCharVal, uint256 rarity) external view returns (string memory) {
        return generateSVGArt(lastCharVal, rarity);
    }

    function svgInfo(
        string memory svgIn,
        address panopticPool,
        uint256 rarity,
        string memory symbol0,
        string memory symbol1
    ) external view returns (string memory) {
        return generateSVGInfo(svgIn, panopticPool, rarity, symbol0, symbol1);
    }
}

contract MockSymbolToken {
    string public symbol;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }
}

/// @dev Stands in for both the PanopticPool and its CollateralTracker: `tokenURI` only reads
/// `pool.collateralToken0().{token0,token1,poolFee}()`.
contract MockPoolAndTracker {
    address public token0;
    address public token1;
    uint24 public poolFee;

    constructor(address _token0, address _token1, uint24 _poolFee) {
        (token0, token1, poolFee) = (_token0, _token1, _poolFee);
    }

    function collateralToken0() external view returns (address) {
        return address(this);
    }
}

/// @notice Fills the coverage gaps left in `contracts/base/FactoryNFT.sol` by the rest of the suite:
/// - `constructMetadata` called directly, over every rarity and strategy
/// - every arm of `getChainName`
/// - every arm of `maxSymbolWidth`, `maxRarityLabelWidth`, `maxStrategyLabelWidth` and of the frame selection
/// - the scaling arms of `write`
/// @dev Uses a small synthetic metadata set so that every output can be checked against an exact string:
/// - a glyph for character code `c` has width `10 + c` and path `<pC/>`
/// - strategy `i` is named `S` followed by the letter `A + i`; rarity `r` is named `R` followed by `r` in decimal
/// - art, filter, description and frame entries are short tagged strings, stored FLZ-compressed like the real ones
contract FactoryNFTCoverageTest is Test {
    using LibString for string;

    uint256 internal constant MAX_RARITY = 40;

    string internal constant FRAME_BODY =
        "|L=<!-- LABEL -->|T=<!-- TEXT -->|A=<!-- ART -->|F=<!-- FILTER -->|P=<!-- POOLADDRESS -->"
        "|C=<!-- CHAINID -->|N=<!-- RARITY_NAME -->|R=<!-- RARITY -->|0=<!-- SYMBOL0 -->|1=<!-- SYMBOL1 -->|";

    FactoryNFTHarness internal nft;

    uint256 internal pointerNonce;

    /*//////////////////////////////////////////////////////////////
                                FIXTURE
    //////////////////////////////////////////////////////////////*/

    /// @dev Stores `data` as the code of a fresh address behind a one-byte STOP prefix, as data contracts do.
    function _store(bytes memory data) internal returns (Pointer) {
        address location = address(uint160(0xDA7A000000) + uint160(++pointerNonce));
        vm.etch(location, abi.encodePacked(hex"00", data));
        return PointerLibrary.createPointer(location, 1, uint48(data.length));
    }

    function _storeCompressed(string memory str) internal returns (Pointer) {
        return _store(LibZip.flzCompress(bytes(str)));
    }

    function _strategyName(uint256 i) internal pure returns (string memory) {
        return string(abi.encodePacked("S", bytes1(uint8(65 + i))));
    }

    function _rarityName(uint256 rarity) internal pure returns (string memory) {
        return string.concat("R", LibString.toString(rarity));
    }

    function _frame(uint256 i) internal pure returns (string memory) {
        return string.concat("<svg frame=", LibString.toString(i), ">", FRAME_BODY, "</svg>");
    }

    function _range(uint256 n) internal pure returns (uint256[] memory idx) {
        idx = new uint256[](n);
        for (uint256 i; i < n; ++i) idx[i] = i;
    }

    function setUp() public {
        bytes32[] memory properties = new bytes32[](8);
        uint256[][] memory indices = new uint256[][](8);
        Pointer[][] memory pointers = new Pointer[][](8);

        properties[0] = bytes32("frames");
        indices[0] = _range(6);
        pointers[0] = new Pointer[](6);
        for (uint256 i; i < 6; ++i) pointers[0][i] = _storeCompressed(_frame(i));

        properties[1] = bytes32("strategies");
        indices[1] = _range(16);
        pointers[1] = new Pointer[](16);
        for (uint256 i; i < 16; ++i) pointers[1][i] = _store(bytes(_strategyName(i)));

        // descriptions are keyed by lastCharVal + 16 * (rarity / 8)
        uint256 nDescriptions = 16 * (MAX_RARITY / 8 + 1);
        properties[2] = bytes32("descriptions");
        indices[2] = _range(nDescriptions);
        pointers[2] = new Pointer[](nDescriptions);
        for (uint256 i; i < nDescriptions; ++i)
            pointers[2][i] = _storeCompressed(string.concat("desc", LibString.toString(i)));

        properties[3] = bytes32("art");
        indices[3] = _range(16);
        pointers[3] = new Pointer[](16);
        for (uint256 i; i < 16; ++i)
            pointers[3][i] = _storeCompressed(string.concat("art", LibString.toString(i)));

        properties[4] = bytes32("filters");
        indices[4] = _range(MAX_RARITY + 1);
        pointers[4] = new Pointer[](MAX_RARITY + 1);
        for (uint256 i; i <= MAX_RARITY; ++i)
            pointers[4][i] = _storeCompressed(string.concat("filter", LibString.toString(i)));

        properties[5] = bytes32("rarities");
        indices[5] = _range(MAX_RARITY + 1);
        pointers[5] = new Pointer[](MAX_RARITY + 1);
        for (uint256 i; i <= MAX_RARITY; ++i) pointers[5][i] = _store(bytes(_rarityName(i)));

        // glyphs are keyed by the character left-aligned in a word, as `write` computes it
        properties[6] = bytes32("charOffsets");
        properties[7] = bytes32("charPaths");
        indices[6] = new uint256[](128);
        indices[7] = new uint256[](128);
        pointers[6] = new Pointer[](128);
        pointers[7] = new Pointer[](128);
        for (uint256 c; c < 128; ++c) {
            uint256 key = uint256(bytes32(bytes1(uint8(c))));
            indices[6][c] = key;
            indices[7][c] = key;
            pointers[6][c] = _store(abi.encode(_glyphWidth(c)));
            pointers[7][c] = _store(bytes(string.concat("<p", LibString.toString(c), "/>")));
        }

        nft = new FactoryNFTHarness(properties, indices, pointers);
    }

    /*//////////////////////////////////////////////////////////////
                          REFERENCE HELPERS
    //////////////////////////////////////////////////////////////*/

    function _glyphWidth(uint256 c) internal pure returns (uint256) {
        return 10 + c;
    }

    function _textWidth(string memory chars) internal pure returns (uint256 width) {
        for (uint256 i; i < bytes(chars).length; ++i) width += _glyphWidth(uint8(bytes(chars)[i]));
    }

    /// @dev The nested glyph groups `write` produces, before the outer scaling group is applied.
    function _glyphs(string memory chars) internal pure returns (string memory group) {
        for (uint256 i; i < bytes(chars).length; ++i) {
            uint256 c = uint8(bytes(chars)[i]);
            group = string.concat(
                '<g transform="translate(-',
                LibString.toString(_glyphWidth(c)),
                ', 0)">',
                group,
                "<p",
                LibString.toString(c),
                "/></g>"
            );
        }
    }

    function _scaled(
        string memory chars,
        string memory factor
    ) internal pure returns (string memory) {
        return
            string.concat(
                '<g transform="scale(0.0',
                factor,
                ") translate(",
                LibString.toString(_textWidth(chars) / 2),
                ', 0)">',
                _glyphs(chars),
                "</g>"
            );
    }

    /// @dev An address with exactly `rarity` leading hex zeros whose last nibble is `lastCharVal`.
    /// The two requirements only conflict at rarity 39 (the last nibble is the only non-zero one) and 40.
    function _poolAddress(uint256 rarity, uint256 lastCharVal) internal pure returns (address) {
        if (rarity == 40) return address(0);
        if (rarity == 39) return address(uint160(lastCharVal == 0 ? 1 : lastCharVal));
        return address(uint160((uint256(1) << (4 * (39 - rarity))) | lastCharVal));
    }

    function _expectedFrame(uint256 rarity) internal pure returns (uint256) {
        if (rarity < 18) return rarity / 3;
        if (rarity < 23) return 23 - rarity;
        return 0;
    }

    function _decodeURI(string memory uri) internal pure returns (string memory) {
        string memory prefix = "data:application/json;base64,";
        assertTrue(uri.startsWith(prefix), "uri prefix");
        return string(Base64.decode(uri.slice(bytes(prefix).length)));
    }

    /*//////////////////////////////////////////////////////////////
                             getChainName
    //////////////////////////////////////////////////////////////*/

    function _assertChainName(uint256 chainId, string memory expected) internal {
        vm.chainId(chainId);
        assertEq(nft.chainName(), expected, expected);
    }

    function test_getChainName_knownChains() public {
        _assertChainName(1, "Ethereum");
        _assertChainName(56, "BNB Smart Chain");
        _assertChainName(42161, "Arbitrum One");
        _assertChainName(8453, "Base");
        _assertChainName(43114, "Avalanche C-Chain");
        _assertChainName(137, "Polygon");
        _assertChainName(10, "Optimism");
        _assertChainName(42220, "CELO");
        _assertChainName(238, "Blast");
        _assertChainName(5000, "Mantle");
        _assertChainName(59144, "Linea");
        _assertChainName(534352, "Scroll");
        _assertChainName(100, "Gnosis");
        _assertChainName(34443, "Mode");
        _assertChainName(48900, "Zircuit");
        _assertChainName(1116, "Core Blockchain");
        _assertChainName(250, "Fantom");
        _assertChainName(130, "Unichain");
        _assertChainName(324, "ZkSync Era");
        _assertChainName(1329, "Sei");
        _assertChainName(60808, "BOB");
        _assertChainName(30, "Rootstock");
        _assertChainName(167000, "Taiko");
        _assertChainName(314, "Filecoin");
        _assertChainName(480, "World Chain");
        _assertChainName(1284, "Moonbeam");
        _assertChainName(1135, "Lisk");
        _assertChainName(288, "Boba");
        _assertChainName(1101, "Polygon zkEVM");
        _assertChainName(169, "Manta");
        _assertChainName(7777777, "Zora");
    }

    function test_getChainName_unknownChainFallsBackToId() public {
        _assertChainName(11155111, "11155111");
        _assertChainName(2, "2");
    }

    /*//////////////////////////////////////////////////////////////
                           MAX LABEL WIDTHS
    //////////////////////////////////////////////////////////////*/

    function test_maxSymbolWidth_everyRarity() public view {
        for (uint256 rarity; rarity <= MAX_RARITY; ++rarity) {
            uint256 expected;
            if (rarity <= 2) expected = 1600;
            else if (rarity <= 8) expected = 1350;
            else if (rarity <= 11) expected = 1450;
            else if (rarity <= 14) expected = 1350;
            else if (rarity <= 18) expected = 1250;
            else if (rarity == 19) expected = 1350;
            else if (rarity == 20) expected = 1450;
            else if (rarity <= 22) expected = 1350;
            else expected = 1600;

            assertEq(nft.symbolWidth(rarity), expected, LibString.toString(rarity));
        }
        assertEq(nft.symbolWidth(type(uint256).max), 1600, "max");
    }

    function test_maxRarityLabelWidth_everyRarity() public view {
        for (uint256 rarity; rarity <= MAX_RARITY; ++rarity) {
            uint256 expected;
            if (rarity <= 2) expected = 210;
            else if (rarity <= 5) expected = 220;
            else if (rarity <= 8) expected = 210;
            else if (rarity <= 11) expected = 220;
            else if (rarity <= 14) expected = 260;
            else if (rarity <= 18) expected = 225;
            else if (rarity == 19) expected = 260;
            else if (rarity == 20) expected = 220;
            else if (rarity == 21) expected = 210;
            else if (rarity == 22) expected = 220;
            else expected = 210;

            assertEq(nft.rarityLabelWidth(rarity), expected, LibString.toString(rarity));
        }
        assertEq(nft.rarityLabelWidth(type(uint256).max), 210, "max");
    }

    function test_maxStrategyLabelWidth_everyRarity() public view {
        for (uint256 rarity; rarity <= MAX_RARITY; ++rarity) {
            uint256 expected = rarity <= 5 || rarity >= 23 ? 9000 : 3900;

            assertEq(nft.strategyLabelWidth(rarity), expected, LibString.toString(rarity));
        }
        assertEq(nft.strategyLabelWidth(type(uint256).max), 9000, "max");
    }

    /*//////////////////////////////////////////////////////////////
                                 write
    //////////////////////////////////////////////////////////////*/

    function test_write_emptyString() public view {
        assertEq(nft.writeDefault(""), '<g transform="scale(0.034) translate(0, 0)"></g>');
    }

    function test_write_singleCharLiteral() public view {
        // 'A' is character 65, so its glyph is 75 wide
        assertEq(
            nft.writeDefault("A"),
            '<g transform="scale(0.034) translate(37, 0)"><g transform="translate(-75, 0)"><p65/></g></g>'
        );
    }

    function test_write_nestsGlyphsLeftToRight() public view {
        // 'A' (75) then 'B' (76): the later glyph wraps the earlier one
        assertEq(
            nft.writeDefault("AB"),
            '<g transform="scale(0.034) translate(75, 0)"><g transform="translate(-76, 0)">'
            '<g transform="translate(-75, 0)"><p65/></g><p66/></g></g>'
        );
    }

    function test_write_unscaledWhenWithinMaxWidth(string memory chars, uint256 slack) public view {
        vm.assume(bytes(chars).length <= 24);
        for (uint256 i; i < bytes(chars).length; ++i) vm.assume(uint8(bytes(chars)[i]) < 128);
        uint256 width = _textWidth(chars);
        slack = bound(slack, 0, type(uint256).max - width);

        assertEq(nft.writeScaled(chars, width + slack), _scaled(chars, "34"), "within width");
        assertEq(nft.writeDefault(chars), _scaled(chars, "34"), "default width");
    }

    function test_write_scalesDownWhenWiderThanMaxWidth() public view {
        // "AB" is 151 wide; a 100 limit gives 3400 * 100 / 151 = 2251
        assertEq(nft.writeScaled("AB", 100), _scaled("AB", "2251"));
        // one unit over the limit: 3400 * 150 / 151 = 3377
        assertEq(nft.writeScaled("AB", 150), _scaled("AB", "3377"));
        // exactly at the limit there is no rescaling
        assertEq(nft.writeScaled("AB", 151), _scaled("AB", "34"));
    }

    /*//////////////////////////////////////////////////////////////
                   generateSVGArt / generateSVGInfo
    //////////////////////////////////////////////////////////////*/

    /// @dev Reference for `write(chars, maxWidth)` in the regime where the scale factor has four digits.
    function _write(string memory chars, uint256 maxWidth) internal pure returns (string memory) {
        uint256 width = _textWidth(chars);
        if (width <= maxWidth) return _scaled(chars, "34");

        uint256 scale = (3400 * maxWidth) / width;
        require(scale > 999, "fixture text too wide for the reference");
        return _scaled(chars, LibString.toString(scale));
    }

    function _expectedArt(
        uint256 lastCharVal,
        uint256 rarity
    ) internal view returns (string memory svg) {
        svg = _frame(_expectedFrame(rarity));
        svg = svg.replace(
            "<!-- LABEL -->",
            _write(_strategyName(lastCharVal), nft.strategyLabelWidth(rarity))
        );
        svg = svg.replace(
            "<!-- TEXT -->",
            string.concat("desc", LibString.toString(lastCharVal + 16 * (rarity / 8)))
        );
        svg = svg.replace("<!-- ART -->", string.concat("art", LibString.toString(lastCharVal)));
        svg = svg.replace("<!-- FILTER -->", string.concat("filter", LibString.toString(rarity)));
    }

    function _expectedSVG(
        address pool,
        uint256 rarity,
        string memory symbol0,
        string memory symbol1,
        string memory chain
    ) internal view returns (string memory svg) {
        svg = _expectedArt(uint160(pool) & 0xF, rarity);
        svg = svg.replace("<!-- POOLADDRESS -->", LibString.toHexString(uint160(pool), 20));
        svg = svg.replace("<!-- CHAINID -->", chain);
        svg = svg.replace(
            "<!-- RARITY_NAME -->",
            _write(_rarityName(rarity), nft.rarityLabelWidth(rarity))
        );
        svg = svg.replace("<!-- RARITY -->", _scaled(LibString.toString(rarity), "34"));
        svg = svg.replace("<!-- SYMBOL0 -->", _write(symbol0, nft.symbolWidth(rarity)));
        svg = svg.replace("<!-- SYMBOL1 -->", _write(symbol1, nft.symbolWidth(rarity)));
    }

    function _expectedJSON(
        address pool,
        uint256 rarity,
        string memory symbol0,
        string memory symbol1,
        string memory feeStr,
        string memory chain
    ) internal view returns (string memory) {
        string memory strategy = _strategyName(uint160(pool) & 0xF);
        string memory head = string.concat(
            '{"name":"',
            LibString.toHexString(uint160(pool), 20),
            "-",
            strategy,
            "-",
            LibString.toString(rarity),
            '", "description":"Panoptic Pool for the ',
            symbol0,
            "-",
            symbol1,
            "-",
            feeStr,
            ' market", "attributes": [{"trait_type": "Rarity", "value": "'
        );
        return
            string.concat(
                head,
                LibString.toString(rarity),
                " - ",
                _rarityName(rarity),
                '"}, {"trait_type": "Strategy", "value": "',
                strategy,
                '"}, {"trait_type": "ChainId", "value": "',
                chain,
                '"}], "image": "data:image/svg+xml;base64,',
                Base64.encode(bytes(_expectedSVG(pool, rarity, symbol0, symbol1, chain))),
                '"}'
            );
    }

    function test_generateSVGArt_everyRarityAndStrategy() public view {
        for (uint256 rarity; rarity <= MAX_RARITY; ++rarity) {
            for (uint256 lastCharVal; lastCharVal < 16; ++lastCharVal) {
                assertEq(
                    nft.svgArt(lastCharVal, rarity),
                    _expectedArt(lastCharVal, rarity),
                    LibString.toString(rarity)
                );
            }
        }
    }

    function test_generateSVGArt_frameSelection() public view {
        // rarities 0-17 walk up the six frames three at a time, 18-22 walk back down, 23+ wrap to frame 0
        uint8[41] memory frames = [
            0,
            0,
            0,
            1,
            1,
            1,
            2,
            2,
            2,
            3,
            3,
            3,
            4,
            4,
            4,
            5,
            5,
            5,
            5,
            4,
            3,
            2,
            1,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0
        ];
        for (uint256 rarity; rarity <= MAX_RARITY; ++rarity) {
            assertEq(_expectedFrame(rarity), frames[rarity], "reference");
            assertTrue(
                nft.svgArt(0, rarity).startsWith(
                    string.concat("<svg frame=", LibString.toString(frames[rarity]), ">")
                ),
                LibString.toString(rarity)
            );
        }
    }

    function test_generateSVGInfo_fillsEveryPlaceholder() public {
        vm.chainId(8453);
        address pool = _poolAddress(4, 0xB);

        string memory svg = nft.svgInfo(nft.svgArt(0xB, 4), pool, 4, "WETH", "USDC");

        assertEq(svg, _expectedSVG(pool, 4, "WETH", "USDC", "Base"));
        assertEq(svg.indexOf("<!--"), LibString.NOT_FOUND, "no placeholder left");
    }

    /*//////////////////////////////////////////////////////////////
                      constructMetadata / tokenURI
    //////////////////////////////////////////////////////////////*/

    function test_constructMetadata_everyRarityAndStrategy() public {
        vm.chainId(1);
        for (uint256 rarity; rarity <= MAX_RARITY; ++rarity) {
            for (uint256 lastCharVal; lastCharVal < 16; ++lastCharVal) {
                address pool = _poolAddress(rarity, lastCharVal);

                assertEq(
                    _decodeURI(nft.constructMetadata(pool, "WETH", "USDC", 500)),
                    _expectedJSON(pool, rarity, "WETH", "USDC", "5bps", "Ethereum"),
                    LibString.toHexString(pool)
                );
            }
        }
    }

    function test_constructMetadata_literal() public {
        vm.chainId(130);
        // 39 leading zeros, last nibble 2: strategy "SC", rarity "R39", frame 0, description 2 + 16 * 4
        address pool = address(2);

        string memory json = _decodeURI(nft.constructMetadata(pool, "A", "B", 1));

        string memory svg = string.concat(
            "<svg frame=0>",
            '|L=<g transform="scale(0.034) translate(85, 0)"><g transform="translate(-77, 0)">'
            '<g transform="translate(-93, 0)"><p83/></g><p67/></g></g>',
            "|T=desc66|A=art2|F=filter39|P=0x0000000000000000000000000000000000000002|C=Unichain",
            // "R39" is 220 wide against a 210 limit at this rarity: 3400 * 210 / 220 = 3245
            '|N=<g transform="scale(0.03245) translate(110, 0)"><g transform="translate(-67, 0)">'
            '<g transform="translate(-61, 0)"><g transform="translate(-92, 0)"><p82/></g><p51/></g><p57/></g></g>',
            '|R=<g transform="scale(0.034) translate(64, 0)"><g transform="translate(-67, 0)">'
            '<g transform="translate(-61, 0)"><p51/></g><p57/></g></g>',
            '|0=<g transform="scale(0.034) translate(37, 0)"><g transform="translate(-75, 0)"><p65/></g></g>',
            '|1=<g transform="scale(0.034) translate(38, 0)"><g transform="translate(-76, 0)"><p66/></g></g>',
            "|</svg>"
        );

        assertEq(
            json,
            string.concat(
                '{"name":"0x0000000000000000000000000000000000000002-SC-39", ',
                '"description":"Panoptic Pool for the A-B-0.01bps market", ',
                '"attributes": [{"trait_type": "Rarity", "value": "39 - R39"}, ',
                '{"trait_type": "Strategy", "value": "SC"}, ',
                '{"trait_type": "ChainId", "value": "Unichain"}], ',
                '"image": "data:image/svg+xml;base64,',
                Base64.encode(bytes(svg)),
                '"}'
            )
        );
    }

    function test_constructMetadata_feeFormatting() public {
        vm.chainId(1);
        address pool = _poolAddress(0, 7);

        assertEq(
            _decodeURI(nft.constructMetadata(pool, "X", "Y", 3000)),
            _expectedJSON(pool, 0, "X", "Y", "30bps", "Ethereum")
        );
        assertEq(
            _decodeURI(nft.constructMetadata(pool, "X", "Y", 1)),
            _expectedJSON(pool, 0, "X", "Y", "0.01bps", "Ethereum")
        );
        assertEq(
            _decodeURI(nft.constructMetadata(pool, "X", "Y", 8388)),
            _expectedJSON(pool, 0, "X", "Y", "83.88bps", "Ethereum")
        );
    }

    function _leadingHexZeros(address addr) internal pure returns (uint256 zeros) {
        if (addr == address(0)) return 40;
        while (uint160(addr) >> (4 * (39 - zeros)) == 0) ++zeros;
    }

    function test_tokenURI_readsPoolAndMatchesConstructMetadata() public {
        vm.chainId(42161);
        address token0 = address(new MockSymbolToken("WBTC"));
        address token1 = address(new MockSymbolToken("DAI"));
        address pool = address(new MockPoolAndTracker(token0, token1, 3000));
        uint256 rarity = _leadingHexZeros(pool);

        string memory uri = nft.tokenURI(uint256(uint160(pool)));

        assertEq(
            uri,
            nft.constructMetadata(pool, "WBTC", "DAI", 3000),
            "same as constructMetadata"
        );
        assertEq(
            _decodeURI(uri),
            _expectedJSON(pool, rarity, "WBTC", "DAI", "30bps", "Arbitrum One")
        );
    }

    function test_tokenURI_ignoresUpperBitsOfTokenId(uint96 upper) public {
        address token0 = address(new MockSymbolToken("WBTC"));
        address token1 = address(new MockSymbolToken("DAI"));
        address pool = address(new MockPoolAndTracker(token0, token1, 500));

        assertEq(
            nft.tokenURI((uint256(upper) << 160) | uint160(pool)),
            nft.tokenURI(uint256(uint160(pool)))
        );
    }

    function test_tokenURI_nativeAndSymbollessTokens() public {
        vm.chainId(1);
        // token0 is native ETH, token1 has code but no `symbol()`
        address pool = address(new MockPoolAndTracker(address(0), address(this), 100));

        assertEq(
            _decodeURI(nft.tokenURI(uint256(uint160(pool)))),
            _expectedJSON(pool, _leadingHexZeros(pool), "ETH", "???", "1bps", "Ethereum")
        );
    }
}
