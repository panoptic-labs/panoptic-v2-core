// SPDX-License-Identifier: The Unlicense

pragma solidity =0.8.25;
import {Test, console2} from "forge-std/Test.sol";
import {LibString} from "solady/utils/LibString.sol";

library Filters {
    using LibString for string;

    function rarity0() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0 0.96"/><feFuncG type="table" tableValues="0 0.96"/><feFuncB type="table" tableValues="0 0.96"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="soft-light" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity1() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0 0 0.2 0.96"/><feFuncG type="table" tableValues="0 0 0 0.96"/><feFuncB type="table" tableValues="0 0 0 0.96"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="screen" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity2() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0 0.41 0.93 1"/><feFuncG type="table" tableValues="0 0.31 0.72 1"/><feFuncB type="table" tableValues="0 0.2 0.51 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="soft-light" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity3() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0 0.28 0.75 0.96"/><feFuncG type="table" tableValues="0 0.28 0.75 0.96"/><feFuncB type="table" tableValues="0 0.23 0.55 0.96"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity4() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0 0.14 0.58 0.96"/><feFuncG type="table" tableValues="0 0.28 0.65 0.96"/><feFuncB type="table" tableValues="0 0.28 0.68 0.96"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity5() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0 0.37 0.45 1 1"/><feFuncG type="table" tableValues="0 0.36 0.62 0.92 1"/><feFuncB type="table" tableValues="0 0.52 0.87 0.78 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="hard-light" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity6() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0 0 .21 0.36 0.36 0.73 0.98 1"/><feFuncG type="table" tableValues="0 0 0.18 0.18 0.33 0.71 0.94 1"/><feFuncB type="table" tableValues="0.26 0.26 0.26 0.26 0.44 0.78 0.9 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="screen" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity7() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0 0 0.24 0.69 0.95 0.97 1"/><feFuncG type="table" tableValues="0 0 0.13 0.21 0.43 0.86 1"/><feFuncB type="table" tableValues="0 0.42 0.42 0.59 0.73 0.78 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="screen" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity8() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0 0.08 0.36 0.81 0.88 1 1"/><feFuncG type="table" tableValues="0 0.07 0.34 0.85 0.29 0.74 1"/><feFuncB type="table" tableValues="0 0.29 1 0.95 0.78 0.73 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="hard-light" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity9() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0.07 0.31 0.64 0.76 0.93"/><feFuncG type="table" tableValues="0.17 0.41 0.54 0.97 0.82"/><feFuncB type="table" tableValues="0.37 0.75 0.84 0.95 0.79"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity10() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0.2 0.13 0.92 0.98"/><feFuncG type="table" tableValues="0.2 0 0.84 1"/><feFuncB type="table" tableValues="0.2 0.36 1 0"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity11() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0.17 0.36 0.78 0.22 0.78 1"/><feFuncG type="table" tableValues="0.18 0 0 0.9 1 1"/><feFuncB type="table" tableValues="0.12 0.23 1 0.58 0.9 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="overlay" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity12() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0 0.03 0.69 1 0.51 0.72 1"/><feFuncG type="table" tableValues="0 0.32 0.18 0.54 0.85 1 1"/><feFuncB type="table" tableValues="0 0.45 0.3 0.63 0.95 0.85 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity13() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0 1 0.73 1 0.51 0.73 1"/><feFuncG type="table" tableValues="0 0.21 0.14 0.91 0.89 0.93 1"/><feFuncB type="table" tableValues="0 0.11 1 0.13 0.99 0.98 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity14() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0.83 0 0.55 1"/><feFuncG type="table" tableValues="0.05 0.75 1 1"/><feFuncB type="table" tableValues="0.89 1 0 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity15() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0.7 0.7 0.04 0.04 0.04 1 0.7 0.04 0.7"/><feFuncG type="table" tableValues="0.1 0.1 0.16 0.16 0.16 1 0.1 0.16 0.1"/><feFuncB type="table" tableValues="0.26 0.26 0.38 0.38 0.38 1 0.26 0.38 0.26"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="screen" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity16() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0 1 0 0.96"/><feFuncG type="table" tableValues="0.47 0 0.87 0.98"/><feFuncB type="table" tableValues="1 0.37 0.64 0.44"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity17() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer">  <feFuncR type="table" tableValues="0 0.01 0 1 0.96 1"/> <feFuncG type="table" tableValues="0 0.47 0.87 0 0.98 1"/> <feFuncB type="table" tableValues="0 1 0.64 0.37 0.44 1"/> <feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity18() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0.98 0.75 0.51"/><feFuncG type="table" tableValues="1 0.45 0.11"/><feFuncB type="table" tableValues="0.91 0.39 0.29"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity19() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0.98 0.9 0.47"/><feFuncG type="table" tableValues="1 0.62 0.31"/><feFuncB type="table" tableValues="0.91 0.3 0.03"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity20() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0.98 0.85 0.25"/><feFuncG type="table" tableValues="1 0.8 0.25"/><feFuncB type="table" tableValues="0.92 0.27 0.09"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity21() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0.98 0.3 0.24"/><feFuncG type="table" tableValues="1 0.62 0.4"/><feFuncB type="table" tableValues="0.91 0.38 0.26"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity22() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0.98 0.3 0.25"/><feFuncG type="table" tableValues="1 0.44 0.24"/><feFuncB type="table" tableValues="0.91 0.62 0.39"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity23() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0.98 0.4 0.25"/><feFuncG type="table" tableValues="1 0.3 0.24"/><feFuncB type="table" tableValues="0.91 0.62 0.39"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
    }

    function rarity24() internal pure returns (string memory) {
        return
            '<feGaussianBlur in="SourceGraphic" stdDeviation="0.2" result="SourceGraphicBlur" /><feColorMatrix type="matrix" values=".33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 1 0" in="SourceGraphicBlur" result="colormatrix"/><feComponentTransfer in="colormatrix" result="componentTransfer"><feFuncR type="table" tableValues="0.98 0.65 0.44"/><feFuncG type="table" tableValues="1 0.65 0.44"/><feFuncB type="table" tableValues="0.91 0.65 0.44"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal" in="componentTransfer" in2="SourceGraphicBlur" result="blend"/>';
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
        } else if (rarity == 7) {
            return svgIn.replace("<!-- FILTER -->", rarity7());
        } else if (rarity == 8) {
            return svgIn.replace("<!-- FILTER -->", rarity8());
        } else if (rarity == 9) {
            return svgIn.replace("<!-- FILTER -->", rarity9());
        } else if (rarity == 10) {
            return svgIn.replace("<!-- FILTER -->", rarity10());
        } else if (rarity == 11) {
            return svgIn.replace("<!-- FILTER -->", rarity11());
        } else if (rarity == 12) {
            return svgIn.replace("<!-- FILTER -->", rarity12());
        } else if (rarity == 13) {
            return svgIn.replace("<!-- FILTER -->", rarity13());
        } else if (rarity == 14) {
            return svgIn.replace("<!-- FILTER -->", rarity14());
        } else if (rarity == 15) {
            return svgIn.replace("<!-- FILTER -->", rarity15());
        } else if (rarity == 16) {
            return svgIn.replace("<!-- FILTER -->", rarity16());
        } else if (rarity == 17) {
            return svgIn.replace("<!-- FILTER -->", rarity17());
        } else if (rarity == 18) {
            return svgIn.replace("<!-- FILTER -->", rarity18());
        } else if (rarity == 19) {
            return svgIn.replace("<!-- FILTER -->", rarity19());
        } else if (rarity == 20) {
            return svgIn.replace("<!-- FILTER -->", rarity20());
        } else if (rarity == 21) {
            return svgIn.replace("<!-- FILTER -->", rarity21());
        } else if (rarity == 22) {
            return svgIn.replace("<!-- FILTER -->", rarity22());
        } else if (rarity == 23) {
            return svgIn.replace("<!-- FILTER -->", rarity23());
        } else if (rarity >= 24) {
            return svgIn.replace("<!-- FILTER -->", rarity24());
        }
    }
}
