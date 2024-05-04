// SPDX-License-Identifier: The Unlicense

pragma solidity =0.8.25;

import {LibString} from "solady/utils/LibString.sol";
import {LibZip} from "solady/utils/LibZip.sol";

library Letters {
    using LibString for string;

    function m(string memory char) internal pure returns (string[] memory) {
        string[] memory output = new string[](2);
        if (keccak256(bytes(char)) == keccak256(bytes("A"))) {
            output[0] = "367";
            output[
                1
            ] = '<path d="M317 700v-700h-62v224h-126v-224h-61v224h-51v61h51v197q0 90 64 154t154 64h31zM255 285v351q-54 -11 -90 -54t-36 -100v-197h126z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("B"))) {
            output[0] = "372";
            output[
                1
            ] = '<path d="M262 285q35 -19 56.5 -55t21.5 -78q0 -63 -44.5 -107.5t-107.5 -44.5h-117v224h-50v61h50v415h31q64 0 119 -32t87 -87t32 -119q0 -106 -78 -177zM132 636v-348q63 11 105 60t42 114t-42 114t-105 60zM188 61q37 0 64 27t27 64q0 24 -11 44t-30 32.5t-42 14.5 q-31 -13 -64 -17v-165h56z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("C"))) {
            output[0] = "421";
            output[1] = '<path d="M400 446h-62v191q-109 -11 -183.5 -93.5t-74.5 -193.5q0 -119 85 -204t204 -85v-61q-95 0 -175.5 47t-127.5 127.5t-47 175.5q0 71 28 136t74.5 111.5t111.5 74.5t136 28h31v-254z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("D"))) {
            output[0] = "451";
            output[1] = '<path d="M81 700q71 0 135.5 -28t111.5 -74.5t75 -111.5t28 -136q0 -95 -47 -175.5t-127.5 -127.5t-175.5 -47h-31v700h31zM111 63q109 11 183.5 93.5t74.5 193.5q0 73 -34 136.5t-93 103.5t-131 47v-574z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("E"))) {
            output[0] = "303";
            output[1] = '<path d="M283 285v-61h-159v-6q0 -65 46 -111t111 -46v-61q-44 0 -84.5 17.5t-69.5 46.5t-46.5 69.5t-17.5 84.5v6h-49v61h49v197q0 90 64 154t154 64v-61q-65 0 -111 -46t-46 -111v-197h159z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("F"))) {
            output[0] = "298";
            output[1] = '<path d="M128 482v-197h159v-61h-159v-224h-61v224h-49v61h49v197q0 90 64 154t154 64v-61q-65 0 -111 -46t-46 -111z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("G"))) {
            output[0] = "444";
            output[1] = '<path d="M400 446h-60v191q-110 -11 -185 -93t-75 -194q0 -111 74.5 -193.5t183.5 -93.5v161h-100v61h162v-285h-31q-95 0 -175.5 47t-127.5 127.5t-47 175.5t47 175.5t127.5 127.5t175.5 47h31v-254z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("H"))) {
            output[0] = "370";
            output[1] = '<path d="M258 700h62v-700h-62v224h-126v-224h-61v224h-51v61h51v415h61v-415h126v415z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("I"))) {
            output[0] = "162";
            output[1] = '<path d="M111 0h-61v700h61v-700z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("J"))) {
            output[0] = "270";
            output[1] = '<path d="M9 700h218v-482q0 -90 -64 -154t-154 -64v61q65 0 111 46t46 111v421h-157v61z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("K"))) {
            output[0] = "384";
            output[1] = '<path d="M340 462q0 -106 -78 -177q35 -19 56.5 -55t21.5 -78v-152h-61v152q0 36 -24 62t-59 29q-31 -13 -64 -17v-226h-61v224h-50v61h50v415h61v-412q63 11 105 60t42 114v238h61v-238z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("L"))) {
            output[0] = "269";
            output[1] = '<path d="M111 61h157v-61h-218v700h61v-639z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("M"))) {
            output[0] = "577";
            output[1] = '<path d="M496 700h30v-700h-61v636q-63 -11 -104.5 -60t-41.5 -114v-462h-61v462q0 65 -42 114t-105 60v-636h-61v700h31q65 0 120.5 -33t86.5 -89q21 37 52 64t71.5 42.5t84.5 15.5z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("N"))) {
            output[0] = "369";
            output[1] = '<path d="M258 700h61v-700h-61v462q0 65 -42 114t-105 60v-636h-61v700h31q51 0 97 -21t80 -58v79z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("O"))) {
            output[0] = "488";
            output[1] = '<path d="M244 700q60 0 110 -46t79 -126.5t29 -177.5t-29 -177.5t-79 -126.5t-110 -46t-110 46t-79 126.5t-29 177.5t29 177.5t79 126.5t110 46zM244 61q64 0 110.5 86t46.5 203t-46.5 203t-110.5 86t-110.5 -86t-46.5 -203t46.5 -203t110.5 -86zM189 350l51 78l52 -78l-52 -78z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("P"))) {
            output[0] = "353";
            output[1] = '<path d="M102 700q64 0 119 -32t87 -87t32 -119q0 -60 -27.5 -111.5t-75 -84.5t-105.5 -40v-226h-61v224h-51v61h51v415h31zM132 288q42 7 75 31.5t52.5 62t19.5 80.5q0 65 -42 114t-105 60v-348z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("Q"))) {
            output[0] = "509";
            output[1] = '<path d="M403 108l90 -108h-70l-53 63q-56 -63 -126 -63q-60 0 -110 46t-79 126.5t-29 177.5t29 177.5t79 126.5t110 46t110 -46t79 -126.5t29 -177.5q0 -142 -59 -242zM360 159q41 83 41 191q0 117 -46.5 203t-110.5 86t-110.5 -86t-46.5 -203t46.5 -203t110.5 -86q47 0 86 50 l-104 124h70z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("R"))) {
            output[0] = "376";
            output[1] = '<path d="M261 285q36 -19 57.5 -55t21.5 -78v-152h-61v152q0 36 -24 62t-59 29q-31 -13 -64 -17v-226h-61v224h-51v61h51v415h31q64 0 119 -32t87 -87t32 -119q0 -106 -79 -177zM132 288q63 11 105 60t42 114t-42 114t-105 60v-348z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("S"))) {
            output[0] = "303";
            output[1] = '<path d="M267 446h-62v193h-51q-31 0 -53 -22t-22 -53q0 -25 17 -66t33 -70.5t47 -81.5q31 -54 46.5 -82t30 -65.5t14.5 -62.5q0 -56 -40 -96t-96 -40h-82v61h82q20 0 37 10t27 27.5t10 37.5q0 17 -13.5 50t-27.5 57.5t-41 71.5q-35 59 -52.5 91t-35 78.5t-17.5 79.5q0 56 40 96 t96 40h113v-254z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("T"))) {
            output[0] = "259";
            output[1] = '<path d="M5 700h249v-61h-94v-639h-61v639h-94v61z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("U"))) {
            output[0] = "342";
            output[1] = '<path d="M230 700h62v-700h-31q-90 0 -154 64t-64 154v482h61v-482q0 -37 16.5 -70t45.5 -55t64 -29v636z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("V"))) {
            output[0] = "344";
            output[1] = '<path d="M276 700h63l-167 -700l-167 700h63l104 -436z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("W"))) {
            output[0] = "577";
            output[1] = '<path d="M465 700h61v-700h-30q-44 0 -84.5 15.5t-71.5 42.5t-52 64q-31 -56 -86.5 -89t-120.5 -33h-31v700h61v-636q63 11 105 60t42 114v462h61v-462q0 -65 41.5 -114t104.5 -60v636z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("X"))) {
            output[0] = "390";
            output[1] = '<path d="M381 700l-153 -350l153 -350h-66l-120 275l-121 -275h-66l154 350l-154 350h66l121 -275l120 275h66z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("Y"))) {
            output[0] = "370";
            output[1] = '<path d="M307 700h65l-157 -451v-249h-61v249l-156 451h65l122 -356z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("Z"))) {
            output[0] = "297";
            output[1] = '<path d="M280 700l-122 -415h81v-61h-99l-47 -163h146v-61h-228l66 224h-25v61h43l103 354h-146v61h228z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("a"))) {
            output[0] = "342";
            output[1] = '<path d="M261 700h31v-700h-62v224h-126v-224h-61v482q0 90 64 154t154 64zM104 482v-197h126v351q-54 -11 -90 -54t-36 -100z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("b"))) {
            output[0] = "351";
            output[1] = '<path d="M319 462q0 -106 -79 -177q36 -19 57.5 -55t21.5 -78q0 -63 -45 -107.5t-108 -44.5h-116v700h31q64 0 119 -32t87 -87t32 -119zM258 152q0 36 -24 62t-59 29q-31 -13 -64 -17v-165h55q38 0 65 27t27 64zM111 288q63 11 105 60t42 114t-42 114t-105 60v-348z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("c"))) {
            output[0] = "375";
            output[1] = '<path d="M19 350q0 95 47 175.5t127.5 127.5t175.5 47v-61q-119 0 -204 -85t-85 -204t85 -204t204 -85v-61q-95 0 -175.5 47t-127.5 127.5t-47 175.5z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("d"))) {
            output[0] = "451";
            output[1] = '<path d="M431 350q0 -95 -47 -175.5t-127.5 -127.5t-175.5 -47h-31v700h31q95 0 175.5 -47t127.5 -127.5t47 -175.5zM111 63q72 7 131 47t93 103.5t34 136.5t-34 136.5t-93 103.5t-131 47v-574z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("e"))) {
            output[0] = "277";
            output[1] = '<path d="M97 482v-197h159v-61h-159v-6q0 -65 46 -111t111 -46v-61q-90 0 -154 64t-64 154v264q0 90 64 154t154 64v-61q-65 0 -111 -46t-46 -111z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("f"))) {
            output[0] = "276";
            output[1] = '<path d="M261 639q-65 0 -111 -46t-46 -111v-197h159v-61h-159v-224h-61v482q0 90 64 154t154 64v-61z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("g"))) {
            output[0] = "424";
            output[1] = '<path d="M370 0q-95 0 -175.5 47t-127.5 127.5t-47 175.5q0 71 28 136t74.5 111.5t111.5 74.5t136 28v-61q-119 0 -204 -85t-85 -204q0 -111 74.5 -193.5t183.5 -93.5v161h-100v61h162v-285h-31z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("h"))) {
            output[0] = "349";
            output[1] = '<path d="M299 700v-700h-62v224h-126v-224h-61v700h61v-415h126v415h62z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("i"))) {
            output[0] = "162";
            output[1] = '<path d="M111 0h-61v700h61v-700z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("j"))) {
            output[0] = "262";
            output[1] = '<path d="M219 218q0 -90 -64 -154t-154 -64v61q65 0 111 46t46 111v482h61v-482z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("k"))) {
            output[0] = "360";
            output[1] = '<path d="M50 700h61v-412q63 11 105 60t42 114v238h61v-238q0 -63 -30 -116t-82 -86l131 -260h-69l-117 235q-20 -7 -41 -9v-226h-61v700z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("l"))) {
            output[0] = "269";
            output[1] = '<path d="M268 61v-61h-218v700h61v-639h157z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("m"))) {
            output[0] = "530";
            output[1] = '<path d="M258 462q0 43 -19.5 80.5t-53 62t-74.5 31.5v-636h-61v700h31q34 0 67 -9.5t60.5 -27.5t49.5 -42v79h30q82 0 140 -58t58 -140v-502h-61v502q0 48 -30 85.5t-76 47.5v-635h-61v462z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("n"))) {
            output[0] = "361";
            output[1] = '<path d="M111 636v-636h-61v700h31q64 0 119 -32t87 -87t32 -119v-462h-61v462q0 65 -42 114t-105 60z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("o"))) {
            output[0] = "488";
            output[1] = '<path d="M244 700q60 0 110 -46t79 -126.5t29 -177.5t-29 -177.5t-79 -126.5t-110 -46t-110 46t-79 126.5t-29 177.5t29 177.5t79 126.5t110 46zM244 61q64 0 110.5 86t46.5 203t-46.5 203t-110.5 86t-110.5 -86t-46.5 -203t46.5 -203t110.5 -86z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("p"))) {
            output[0] = "333";
            output[1] = '<path d="M50 0v700h31q48 0 92 -19t76 -51t51 -76t19 -92q0 -60 -27.5 -111.5t-75 -84.5t-105.5 -40v-226h-61zM111 636v-348q63 11 105 60t42 114t-42 114t-105 60z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("q"))) {
            output[0] = "509";
            output[1] = '<path d="M244 700q60 0 110 -46t79 -126.5t29 -177.5q0 -142 -59 -242l90 -108h-70l-53 63q-56 -63 -126 -63q-60 0 -110 46t-79 126.5t-29 177.5t29 177.5t79 126.5t110 46zM244 61q47 0 86 50l-104 124h70l64 -76q41 83 41 191q0 117 -46.5 203t-110.5 86t-110.5 -86t-46.5 -203 t46.5 -203t110.5 -86z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("r"))) {
            output[0] = "355";
            output[1] = '<path d="M319 462q0 -42 -14 -80.5t-39 -69t-59 -52.5l131 -260h-69l-117 235q-20 -7 -41 -9v-226h-61v700h31q98 0 168 -70t70 -168zM111 288q41 7 74.5 31.5t53 62t19.5 80.5q0 65 -42 114t-105 60v-348z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("s"))) {
            output[0] = "284";
            output[1] = '<path d="M176 346q31 -54 46.5 -82t30 -65.5t14.5 -62.5q0 -56 -40 -96t-96 -40h-82v61h82q20 0 37 10t27 27.5t10 37.5q0 17 -13.5 50t-27.5 57.5t-41 71.5q-35 59 -52.5 91t-35 78.5t-17.5 79.5q0 56 40 96t96 40h82v-61h-82q-31 0 -53 -22t-22 -53q0 -25 17 -66t33 -70.5 t47 -81.5z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("t"))) {
            output[0] = "259";
            output[1] = '<path d="M160 0h-61v639h-94v61h249v-61h-94v-639z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("u"))) {
            output[0] = "343";
            output[1] = '<path d="M296 124q0 -51 -36.5 -87.5t-88 -36.5t-88 36.5t-36.5 87.5v576h61v-576q0 -26 18.5 -44.5t44.5 -18.5q17 0 31.5 8.5t23 23t8.5 31.5v576h62v-576z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("v"))) {
            output[0] = "341";
            output[1] = '<path d="M295 154q0 -54 -32.5 -96.5t-84.5 -56.5l-8 -2l-8 2q-51 14 -83.5 56.5t-32.5 96.5v546h61v-546q0 -31 17.5 -56t45.5 -35q14 5 26 14t20 21t12.5 26.5t4.5 29.5v546h62v-546z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("w"))) {
            output[0] = "530";
            output[1] = '<path d="M111 64q63 11 105 60t42 114v462h61v-635q46 10 76 47.5t30 85.5v502h61v-502q0 -82 -58 -140t-140 -58h-30v79q-34 -37 -80 -58t-97 -21h-31v700h61v-636z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("x"))) {
            output[0] = "341";
            output[1] = '<path d="M295 136v-136h-62v136q0 30 -17 55t-46 36q-28 -11 -45.5 -36t-17.5 -55v-136h-61v136q0 75 59 123q-59 48 -59 123v318h61v-318q0 -30 17.5 -55t45.5 -36q14 5 26 14.5t20 21t12.5 26t4.5 29.5v318h62v-318q0 -75 -59 -123q59 -48 59 -123z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("y"))) {
            output[0] = "307";
            output[1] = '<path d="M216 382v318h62v-318q0 -47 -26 -86.5t-68 -58.5v-237h-61v237q-43 19 -68.5 58.5t-25.5 86.5v318h61v-318q0 -30 17.5 -55t45.5 -36q29 11 46 36t17 55z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("z"))) {
            output[0] = "286";
            output[1] = '<path d="M49 700h228l-187 -639h146v-61h-228l187 639h-146v61z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("0"))) {
            output[1] = '<path d="M441 700h71l-73 -124q50 -97 50 -226q0 -97 -29 -177.5t-79 -126.5t-110 -46q-73 0 -130 68l-40 -68h-71l73 124q-50 97 -50 226q0 97 28.5 177.5t79 126.5t110.5 46q73 0 130 -68zM114 350q0 -87 27 -160l227 385q-44 64 -97 64q-64 0 -110.5 -86t-46.5 -203zM428 350 q0 87 -28 160l-226 -385q43 -64 97 -64q64 0 110.5 86t46.5 203z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("1"))) {
            output[0] = "202";
            output[1] = '<path d="M27 639v61h124v-700h-61v639h-63z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("2"))) {
            output[0] = "310";
            output[1] = '<path d="M62 700h82q56 0 96 -40t40 -96q0 -33 -18 -79.5t-35.5 -78.5t-51.5 -91q-27 -47 -41 -71.5t-28 -57.5t-14 -50v-75h157v-61h-218v136q0 25 14.5 62.5t29.5 65.5t47 82q31 52 47 81.5t32.5 70.5t16.5 66q0 31 -21.5 53t-52.5 22h-82v61z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("3"))) {
            output[0] = "311";
            output[1] = '<path d="M270 152q0 -63 -44.5 -107.5t-107.5 -44.5h-86v61h86q38 0 64.5 27t26.5 64q0 24 -11 44t-30 32.5t-42 14.5q-45 -19 -94 -19v61q48 0 89 23.5t64.5 64.5t23.5 89q0 73 -52 125t-125 52v61q98 0 168 -70t70 -168q0 -106 -78 -177q35 -19 56.5 -55t21.5 -78z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("4"))) {
            output[0] = "349";
            output[1] = '<path d="M273 117v-120h-62v120h-204l266 583v-522h42v-61h-42zM102 178h109v240z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("5"))) {
            output[0] = "324";
            output[1] = '<path d="M155 285q58 0 100 -42t42 -100.5t-42 -100.5t-100 -42h-79v61h79q33 0 57 24t24 57.5t-24 57.5t-57 24h-110v476h218v-61h-157v-354h49z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("6"))) {
            output[0] = "437";
            output[1] = '<path d="M406 184q0 -76 -53.5 -130t-129.5 -54t-130 54t-54 130q0 6 1 13h-1v153q0 95 47 175.5t127.5 127.5t175.5 47v-61q-119 0 -204 -85t-85 -204v-30q53 47 123 47q76 0 129.5 -53.5t53.5 -129.5zM223 61q50 0 86 36t36 86.5t-36 86.5t-86.5 36t-86.5 -36t-36 -86 q0 -25 10 -48t26 -39t39 -26t48 -10z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("7"))) {
            output[0] = "301";
            output[1] = '<path d="M60 639v61h230l-205 -700h-64l188 639h-149z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("8"))) {
            output[0] = "341";
            output[1] = '<path d="M295 157v-37q0 -51 -36.5 -87.5t-88 -36.5t-88 36.5t-36.5 87.5v37q0 56 43 93q-43 38 -43 94v232q0 51 36.5 87.5t88 36.5t88 -36.5t36.5 -87.5v-232q0 -56 -43 -94q43 -37 43 -93zM107 344q0 -26 18.5 -44.5t44.5 -18.5t44.5 18.5t18.5 44.5v232q0 26 -18.5 44.5 t-44.5 18.5t-44.5 -18.5t-18.5 -44.5v-232zM233 120v37q0 17 -8.5 31.5t-23 23t-31.5 8.5q-26 0 -44.5 -18.5t-18.5 -44.5v-37q0 -26 18.5 -44.5t44.5 -18.5t44.5 18.5t18.5 44.5z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes("9"))) {
            output[0] = "438";
            output[1] = '<path d="M398 503v-153q0 -95 -46.5 -175.5t-127.5 -127.5t-176 -47v61q120 0 204.5 85t84.5 204v30q-52 -47 -122 -47q-76 0 -130 53.5t-54 129.5t54 130t130 54t129.5 -54t53.5 -130v-13zM215 394q50 0 86 36t36 86.5t-36 86.5t-86.5 36t-86.5 -36t-36 -87q0 -33 16.5 -61 t45 -44.5t61.5 -16.5z" />';
        } else if (keccak256(bytes(char)) == keccak256(bytes(" "))) {
            output[0] = "200";
            output[1] = '<path d="" />';
        }


        return output;
    }
}
