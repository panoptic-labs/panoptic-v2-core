// SPDX-License-Identifier: The Unlicense

pragma solidity =0.8.25;
import {console2} from "forge-std/Test.sol";

import {LibString} from "solady/utils/LibString.sol";
import {LibZip} from "solady/utils/LibZip.sol";

library Letters {
    using LibString for string;

    function write(string memory input) internal pure returns (string memory) {
        string memory d = write(input, type(uint256).max);

        return d;
    }

    function write(string memory input, uint256 maxWidth) internal pure returns (string memory) {
        bytes memory b = bytes(input);

        string memory d;
        uint256 offset;

        for (uint256 i = 0; i < b.length; ++i) {
            string[] memory c = m(string(abi.encodePacked(b[i])));
            d = string.concat('<g transform="translate(-', c[0], ', 0)">', d, c[1], "</g>");
            offset += stringToUint(c[0]);
        }

        console2.log(input, offset);
        string memory factor;
        if (offset > maxWidth) {
            uint256 _scale = (3400 * maxWidth) / offset;
            factor = LibString.toString(_scale);
            console2.log("_scale", _scale);
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

    function addSymbol0(
        string memory contents,
        string memory symbol0,
        uint256 rarity
    ) public pure returns (string memory) {
        string memory d = write(symbol0, maxWidth(rarity));
        return contents.replace("<!-- SYMBOL0 -->", d);
    }

    function addSymbol1(
        string memory contents,
        string memory symbol1,
        uint256 rarity
    ) public pure returns (string memory) {
        string memory d = write(symbol1, maxWidth(rarity));
        return contents.replace("<!-- SYMBOL1 -->", d);
    }

    function maxWidth(uint256 rarity) internal pure returns (uint256 width) {
        if (rarity < 4) {
            width = 1600;
        }
    }

    function m(string memory char) internal pure returns (string[] memory) {
        string[] memory output = new string[](2);
        if (keccak256(bytes(char)) == keccak256(bytes("A"))) {
            output[0] = "367";
            output[
                1
            ] = '<path d="M317-350v700h-62V126H129v224H68V126H17V65h51v-197q0-90 64-154t154-64h31zM255 65v-351q-54 11-90 54t-36 100V65h126z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("B"))) {
            output[0] = "372";
            output[
                1
            ] = '<path d="M262 65q35 19 56.5 55t21.5 78q0 63-44.5 107.5T188 350H71V126H21V65h50v-415h31q64 0 119 32t87 87 32 119q0 106-78 177zM132-286V62q63-11 105-60t42-114-42-114-105-60zm56 575q37 0 64-27t27-64q0-24-11-44t-30-32.5-42-14.5q-31 13-64 17v165h56z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("C"))) {
            output[0] = "421";
            output[
                1
            ] = '<path d="M400-96h-62v-191q-109 11-183.5 93.5T80 0q0 119 85 204t204 85v61q-95 0-175.5-47T66 175.5 19 0q0-71 28-136t74.5-111.5T233-322t136-28h31v254z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("D"))) {
            output[0] = "451";
            output[
                1
            ] = '<path d="M81-350q71 0 135.5 28T328-247.5 403-136 431 0q0 95-47 175.5T256.5 303 81 350H50v-700h31zm30 637q109-11 183.5-93.5T369 0q0-73-34-136.5T242-240t-131-47v574z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("E"))) {
            output[0] = "303";
            output[
                1
            ] = '<path d="M283 65v61H124v6q0 65 46 111t111 46v61q-44 0-84.5-17.5T127 286t-46.5-69.5T63 132v-6H14V65h49v-197q0-90 64-154t154-64v61q-65 0-111 46t-46 111V65h159z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("F"))) {
            output[0] = "298";
            output[
                1
            ] = '<path d="M128-132V65h159v61H128v224H67V126H18V65h49v-197q0-90 64-154t154-64v61q-65 0-111 46t-46 111z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("G"))) {
            output[0] = "444";
            output[
                1
            ] = '<path d="M400-96h-60v-191q-110 11-185 93T80 0q0 111 74.5 193.5T338 287V126H238V65h162v285h-31q-95 0-175.5-47T66 175.5 19 0t47-175.5T193.5-303 369-350h31v254z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("H"))) {
            output[0] = "370";
            output[
                1
            ] = '<path d="M258-350h62v700h-62V126H132v224H71V126H20V65h51v-415h61V65h126v-415z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("I"))) {
            output[0] = "162";
            output[1] = '<path d="M111 350H50v-700h61v700z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("J"))) {
            output[0] = "270";
            output[
                1
            ] = '<path d="M9-350h218v482q0 90-64 154T9 350v-61q65 0 111-46t46-111v-421H9v-61z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("K"))) {
            output[0] = "384";
            output[
                1
            ] = '<path d="M340-112q0 106-78 177 35 19 56.5 55t21.5 78v152h-61V198q0-36-24-62t-59-29q-31 13-64 17v226H71V126H21V65h50v-415h61V62q63-11 105-60t42-114v-238h61v238z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("L"))) {
            output[0] = "269";
            output[1] = '<path d="M111 289h157v61H50v-700h61v639z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("M"))) {
            output[0] = "577";
            output[
                1
            ] = '<path d="M496-350h30v700h-61v-636q-63 11-104.5 60T319-112v462h-61v-462q0-65-42-114t-105-60v636H50v-700h31q65 0 120.5 33t86.5 89q21-37 52-64t71.5-42.5T496-350z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("N"))) {
            output[0] = "369";
            output[
                1
            ] = '<path d="M258-350h61v700h-61v-462q0-65-42-114t-105-60v636H50v-700h31q51 0 97 21t80 58v-79z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("O"))) {
            output[0] = "488";
            output[
                1
            ] = '<path d="M244-350q60 0 110 46t79 126.5T462 0t-29 177.5T354 304t-110 46-110-46-79-126.5T26 0t29-177.5T134-304t110-46zm0 639q64 0 110.5-86T401 0t-46.5-203T244-289t-110.5 86T87 0t46.5 203T244 289zM189 0l51-78 52 78-52 78z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("P"))) {
            output[0] = "353";
            output[
                1
            ] = '<path d="M102-350q64 0 119 32t87 87 32 119q0 60-27.5 111.5t-75 84.5T132 124v226H71V126H20V65h51v-415h31zm30 412q42-7 75-31.5t52.5-62T279-112q0-65-42-114t-105-60V62z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("Q"))) {
            output[0] = "509";
            output[
                1
            ] = '<path d="m403 242 90 108h-70l-53-63q-56 63-126 63-60 0-110-46T55 177.5 26 0t29-177.5T134-304t110-46 110 46 79 126.5T462 0q0 142-59 242zm-43-51q41-83 41-191 0-117-46.5-203T244-289t-110.5 86T87 0t46.5 203T244 289q47 0 86-50L226 115h70z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("R"))) {
            output[0] = "376";
            output[
                1
            ] = '<path d="M261 65q36 19 57.5 55t21.5 78v152h-61V198q0-36-24-62t-59-29q-31 13-64 17v226H71V126H20V65h51v-415h31q64 0 119 32t87 87 32 119q0 106-79 177zm-129-3q63-11 105-60t42-114-42-114-105-60V62z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("S"))) {
            output[0] = "303";
            output[
                1
            ] = '<path d="M267-96h-62v-193h-51q-31 0-53 22t-22 53q0 25 17 66t33 70.5T176 4q31 54 46.5 82t30 65.5T267 214q0 56-40 96t-96 40H49v-61h82q20 0 37-10t27-27.5 10-37.5q0-17-13.5-50T164 106.5 123 35Q88-24 70.5-56t-35-78.5T18-214q0-56 40-96t96-40h113v254z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("T"))) {
            output[0] = "259";
            output[1] = '<path d="M5-350h249v61h-94v639H99v-639H5v-61z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("U"))) {
            output[0] = "342";
            output[
                1
            ] = '<path d="M230-350h62v700h-31q-90 0-154-64T43 132v-482h61v482q0 37 16.5 70t45.5 55 64 29v-636z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("V"))) {
            output[0] = "344";
            output[1] = '<path d="M276-350h63L172 350 5-350h63L172 86z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("W"))) {
            output[0] = "577";
            output[
                1
            ] = '<path d="M465-350h61v700h-30q-44 0-84.5-15.5T340 292t-52-64q-31 56-86.5 89T81 350H50v-700h61v636q63-11 105-60t42-114v-462h61v462q0 65 41.5 114T465 286v-636z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("X"))) {
            output[0] = "390";
            output[
                1
            ] = '<path d="M381-350 228 0l153 350h-66L195 75 74 350H8L162 0 8-350h66L195-75l120-275h66z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("Y"))) {
            output[0] = "370";
            output[1] = '<path d="M307-350h65L215 101v249h-61V101L-2-350h65L185 6z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("Z"))) {
            output[0] = "297";
            output[
                1
            ] = '<path d="M280-350 158 65h81v61h-99L93 289h146v61H11l66-224H52V65h43l103-354H52v-61h228z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("a"))) {
            output[0] = "342";
            output[
                1
            ] = '<path d="M261-350h31v700h-62V126H104v224H43v-482q0-90 64-154t154-64zM104-132V65h126v-351q-54 11-90 54t-36 100z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("b"))) {
            output[0] = "351";
            output[
                1
            ] = '<path d="M319-112q0 106-79 177 36 19 57.5 55t21.5 78q0 63-45 107.5T166 350H50v-700h31q64 0 119 32t87 87 32 119zm-61 310q0-36-24-62t-59-29q-31 13-64 17v165h55q38 0 65-27t27-64zM111 62q63-11 105-60t42-114-42-114-105-60V62z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("c"))) {
            output[0] = "375";
            output[
                1
            ] = '<path d="M19 0q0-95 47-175.5T193.5-303 369-350v61q-119 0-204 85T80 0t85 204 204 85v61q-95 0-175.5-47T66 175.5 19 0z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("d"))) {
            output[0] = "451";
            output[
                1
            ] = '<path d="M431 0q0 95-47 175.5T256.5 303 81 350H50v-700h31q95 0 175.5 47T384-175.5 431 0zM111 287q72-7 131-47t93-103.5T369 0t-34-136.5T242-240t-131-47v574z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("e"))) {
            output[0] = "277";
            output[
                1
            ] = '<path d="M97-132V65h159v61H97v6q0 65 46 111t111 46v61q-90 0-154-64T36 132v-264q0-90 64-154t154-64v61q-65 0-111 46T97-132z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("f"))) {
            output[0] = "276";
            output[
                1
            ] = '<path d="M261-289q-65 0-111 46t-46 111V65h159v61H104v224H43v-482q0-90 64-154t154-64v61z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("g"))) {
            output[0] = "424";
            output[
                1
            ] = '<path d="M370 350q-95 0-175.5-47T67 175.5 20 0q0-71 28-136t74.5-111.5T234-322t136-28v61q-119 0-204 85T81 0q0 111 74.5 193.5T339 287V126H239V65h162v285h-31z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("h"))) {
            output[0] = "349";
            output[1] = '<path d="M299-350v700h-62V126H111v224H50v-700h61V65h126v-415h62z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("i"))) {
            output[0] = "162";
            output[1] = '<path d="M111 350H50v-700h61v700z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("j"))) {
            output[0] = "262";
            output[
                1
            ] = '<path d="M219 132q0 90-64 154T1 350v-61q65 0 111-46t46-111v-482h61v482z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("k"))) {
            output[0] = "360";
            output[
                1
            ] = '<path d="M50-350h61V62q63-11 105-60t42-114v-238h61v238q0 63-30 116t-82 86l131 260h-69L152 115q-20 7-41 9v226H50v-700z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("l"))) {
            output[0] = "269";
            output[1] = '<path d="M268 289v61H50v-700h61v639h157z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("m"))) {
            output[0] = "530";
            output[
                1
            ] = '<path d="M258-112q0-43-19.5-80.5t-53-62T111-286v636H50v-700h31q34 0 67 9.5t60.5 27.5 49.5 42v-79h30q82 0 140 58t58 140v502h-61v-502q0-48-30-85.5T319-285v635h-61v-462z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("n"))) {
            output[0] = "361";
            output[
                1
            ] = '<path d="M111-286v636H50v-700h31q64 0 119 32t87 87 32 119v462h-61v-462q0-65-42-114t-105-60z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("o"))) {
            output[0] = "488";
            output[
                1
            ] = '<path d="M244-350q60 0 110 46t79 126.5T462 0t-29 177.5T354 304t-110 46-110-46-79-126.5T26 0t29-177.5T134-304t110-46zm0 639q64 0 110.5-86T401 0t-46.5-203T244-289t-110.5 86T87 0t46.5 203T244 289z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("p"))) {
            output[0] = "333";
            output[
                1
            ] = '<path d="M50 350v-700h31q48 0 92 19t76 51 51 76 19 92q0 60-27.5 111.5t-75 84.5T111 124v226H50zm61-636V62q63-11 105-60t42-114-42-114-105-60z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("q"))) {
            output[0] = "509";
            output[
                1
            ] = '<path d="M244-350q60 0 110 46t79 126.5T462 0q0 142-59 242l90 108h-70l-53-63q-56 63-126 63-60 0-110-46T55 177.5 26 0t29-177.5T134-304t110-46zm0 639q47 0 86-50L226 115h70l64 76q41-83 41-191 0-117-46.5-203T244-289t-110.5 86T87 0t46.5 203T244 289z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("r"))) {
            output[0] = "355";
            output[
                1
            ] = '<path d="M319-112q0 42-14 80.5t-39 69T207 90l131 260h-69L152 115q-20 7-41 9v226H50v-700h31q98 0 168 70t70 168zM111 62q41-7 74.5-31.5t53-62T258-112q0-65-42-114t-105-60V62z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("s"))) {
            output[0] = "284";
            output[
                1
            ] = '<path d="M176 4q31 54 46.5 82t30 65.5T267 214q0 56-40 96t-96 40H49v-61h82q20 0 37-10t27-27.5 10-37.5q0-17-13.5-50T164 106.5 123 35Q88-24 70.5-56t-35-78.5T18-214q0-56 40-96t96-40h82v61h-82q-31 0-53 22t-22 53q0 25 17 66t33 70.5T176 4z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("t"))) {
            output[0] = "259";
            output[1] = '<path d="M160 350H99v-639H5v-61h249v61h-94v639z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("u"))) {
            output[0] = "343";
            output[
                1
            ] = '<path d="M296 226q0 51-36.5 87.5t-88 36.5-88-36.5T47 226v-576h61v576q0 26 18.5 44.5T171 289q17 0 31.5-8.5t23-23T234 226v-576h62v576z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("v"))) {
            output[0] = "341";
            output[
                1
            ] = '<path d="M295 196q0 54-32.5 96.5T178 349l-8 2-8-2q-51-14-83.5-56.5T46 196v-546h61v546q0 31 17.5 56t45.5 35q14-5 26-14t20-21 12.5-26.5T233 196v-546h62v546z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("w"))) {
            output[0] = "530";
            output[
                1
            ] = '<path d="M111 286q63-11 105-60t42-114v-462h61v635q46-10 76-47.5t30-85.5v-502h61v502q0 82-58 140t-140 58h-30v-79q-34 37-80 58t-97 21H50v-700h61v636z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("x"))) {
            output[0] = "341";
            output[
                1
            ] = '<path d="M295 214v136h-62V214q0-30-17-55t-46-36q-28 11-45.5 36T107 214v136H46V214q0-75 59-123Q46 43 46-32v-318h61v318q0 30 17.5 55T170 59q14-5 26-14.5t20-21 12.5-26T233-32v-318h62v318q0 75-59 123 59 48 59 123z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("y"))) {
            output[0] = "307";
            output[
                1
            ] = '<path d="M216-32v-318h62v318q0 47-26 86.5T184 113v237h-61V113Q80 94 54.5 54.5T29-32v-318h61v318q0 30 17.5 55T153 59q29-11 46-36t17-55z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("z"))) {
            output[0] = "286";
            output[1] = '<path d="M49-350h228L90 289h146v61H8l187-639H49v-61z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("0"))) {
            output[0] = "541";
            output[
                1
            ] = '<path d="M441-350h71l-73 124q50 97 50 226 0 97-29 177.5T381 304t-110 46q-73 0-130-68l-40 68H30l73-124Q53 129 53 0q0-97 28.5-177.5t79-126.5T271-350q73 0 130 68zM114 0q0 87 27 160l227-385q-44-64-97-64-64 0-110.5 86T114 0zm314 0q0-87-28-160L174 225q43 64 97 64 64 0 110.5-86T428 0z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("1"))) {
            output[0] = "202";
            output[1] = '<path d="M27-289v-61h124v700H90v-639H27z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("2"))) {
            output[0] = "310";
            output[
                1
            ] = '<path d="M62-350h82q56 0 96 40t40 96q0 33-18 79.5T226.5-56 175 35q-27 47-41 71.5T106 164t-14 50v75h157v61H31V214q0-25 14.5-62.5T75 86t47-82q31-52 47-81.5t32.5-70.5 16.5-66q0-31-21.5-53T144-289H62v-61z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("3"))) {
            output[0] = "311";
            output[
                1
            ] = '<path d="M270 198q0 63-44.5 107.5T118 350H32v-61h86q38 0 64.5-27t26.5-64q0-24-11-44t-30-32.5-42-14.5q-45 19-94 19V65q48 0 89-23.5T185.5-23t23.5-89q0-73-52-125T32-289v-61q98 0 168 70t70 168q0 106-78 177 35 19 56.5 55t21.5 78z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("4"))) {
            output[0] = "349";
            output[
                1
            ] = '<path d="M273 233v120h-62V233H7l266-583v522h42v61h-42zm-171-61h109V-68z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("5"))) {
            output[0] = "324";
            output[
                1
            ] = '<path d="M155 65q58 0 100 42t42 100.5T255 308t-100 42H76v-61h79q33 0 57-24t24-57.5-24-57.5-57-24H45v-476h218v61H106V65h49z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("6"))) {
            output[0] = "437";
            output[
                1
            ] = '<path d="M406 166q0 76-53.5 130T223 350 93 296 39 166q0-6 1-13h-1V0q0-95 47-175.5T213.5-303 389-350v61q-119 0-204 85T100 0v30q53-47 123-47 76 0 129.5 53.5T406 166zM223 289q50 0 86-36t36-86.5T309 80t-86.5-36T136 80t-36 86q0 25 10 48t26 39 39 26 48 10z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("7"))) {
            output[0] = "301";
            output[1] = '<path d="M60-289v-61h230L85 350H21l188-639H60z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("8"))) {
            output[0] = "341";
            output[
                1
            ] = '<path d="M295 193v37q0 51-36.5 87.5t-88 36.5-88-36.5T46 230v-37q0-56 43-93Q46 62 46 6v-232q0-51 36.5-87.5t88-36.5 88 36.5T295-226V6q0 56-43 94 43 37 43 93zM107 6q0 26 18.5 44.5T170 69t44.5-18.5T233 6v-232q0-26-18.5-44.5T170-289t-44.5 18.5T107-226V6zm126 224v-37q0-17-8.5-31.5t-23-23T170 130q-26 0-44.5 18.5T107 193v37q0 26 18.5 44.5T170 293t44.5-18.5T233 230z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("9"))) {
            output[0] = "438";
            output[
                1
            ] = '<path d="M398-153V0q0 95-46.5 175.5T224 303 48 350v-61q120 0 204.5-85T337 0v-30q-52 47-122 47-76 0-130-53.5T31-166t54-130 130-54 129.5 54T398-166v13zM215-44q50 0 86-36t36-86.5-36-86.5-86.5-36-86.5 36-36 87q0 33 16.5 61t45 44.5T215-44z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes(" "))) {
            output[0] = "209";
            output[1] = '<path d="" />';
        }

        return output;
    }

    /// @dev from https://ethereum.stackexchange.com/a/132434
    function stringToUint(string memory s) public pure returns (uint) {
        bytes memory b = bytes(s);
        uint result = 0;
        for (uint256 i = 0; i < b.length; i++) {
            uint256 c = uint256(uint8(b[i]));
            if (c >= 48 && c <= 57) {
                result = result * 10 + (c - 48);
            }
        }
        return result;
    }
}
