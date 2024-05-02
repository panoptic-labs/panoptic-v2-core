// SPDX-License-Identifier: The Unlicense

pragma solidity =0.8.25;
import {Test, console2} from "forge-std/Test.sol";
import {LibString} from "solady/utils/LibString.sol";

library Filters {
    using LibString for string;

    function rarity0() internal pure returns (string memory) {
        return
            '<feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphic" result="colormatrix" /><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0 1"/><feFuncG type="table" tableValues="0 1"/><feFuncB type="table" tableValues="0 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="overlay" in="componentTransfer" in2="SourceGraphic" result="blend"/>';
    }

    function rarity1() internal pure returns (string memory) {
        return
            '<feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphic" result="colormatrix" /><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0 0.95"/><feFuncG type="table" tableValues="0 0.78"/><feFuncB type="table" tableValues="0 0.59"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="overlay" in="componentTransfer" in2="SourceGraphic" result="blend"/>';
    }

    function rarity2() internal pure returns (string memory) {
        return
            '<feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphic" result="colormatrix" /><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0.18 0.25 0.45 0.98"/><feFuncG type="table" tableValues="0.16 0.24 0.6 1"/><feFuncB type="table" tableValues="0.32 0.39 0.81 0.91"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="overlay" in="componentTransfer" in2="SourceGraphic" result="blend"/>';
    }

    function rarity3() internal pure returns (string memory) {
        return
            '<feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphic" result="colormatrix" /><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0 0.13 0.22 0.42 0.98 1"/><feFuncG type="table" tableValues="0 0.2 0.43 0.67 0.92 1"/><feFuncB type="table" tableValues="0 0.29 0.32 0.37 0.36 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="overlay" in="componentTransfer" in2="SourceGraphic" result="blend"/>';
    }

    function rarity4() internal pure returns (string memory) {
        return
            '<feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphic" result="colormatrix" /><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0 0.34 0.68 0.65 0.88 0.96 0.98 1"/><feFuncG type="table" tableValues="0 0.1 0.29 0.29 0.4 0.9 0.85 1"/><feFuncB type="table" tableValues="0 0.09 0.16 0.39 0.38 0.35 0.85 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="overlay" in="componentTransfer" in2="SourceGraphic" result="blend"/>';
    }

    function rarity5() internal pure returns (string memory) {
        return
            '<feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphic" result="colormatrix" /><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0 0.09 0.27 0.38 0.3 0.38 0.55 0.95 0.84 1"/><feFuncG type="table" tableValues="0 0.05 0.2 0.49 0.6 0.76 0.94 0.99 0.98 1"/><feFuncB type="table" tableValues="0 0.49 0.89 0.92 0.74 0.73 0.84 0.38 0.71 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="overlay" in="componentTransfer" in2="SourceGraphic" result="blend"/>';
    }

    function rarity6() internal pure returns (string memory) {
        return
            '<feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphic" result="colormatrix" /><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0 0.08 0.1 0.96 0.96"/><feFuncG type="table" tableValues="0 0.42 0.65 0.95 0.95"/><feFuncB type="table" tableValues="0 0.58 0.81 0.95 0.95"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="overlay" in="componentTransfer" in2="SourceGraphic" result="blend"/>';
    }

    function addFilter(string memory svgIn, uint256 rarity) public pure returns (string memory) {
        if (rarity == 0) {
            return svgIn.replace("<!-- FILTER -->", rarity0());
        } else if (rarity == 1) {
            return svgIn.replace("<!-- FILTER -->", rarity1());
        } else if (rarity == 2) {
            return svgIn.replace("<!-- FILTER -->", rarity2());
        } else if (rarity == 3) {
            return svgIn.replace("<!-- FILTER -->", rarity3());
        } else if (rarity == 4) {
            return svgIn.replace("<!-- FILTER -->", rarity4());
        } else if (rarity == 5) {
            return svgIn.replace("<!-- FILTER -->", rarity5());
        } else if (rarity == 6) {
            return svgIn.replace("<!-- FILTER -->", rarity6());
        } else {
            return svgIn.replace("<!-- FILTER -->", rarity6());
        }
    }
}
