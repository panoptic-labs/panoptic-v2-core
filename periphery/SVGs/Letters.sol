// SPDX-License-Identifier: The Unlicense

pragma solidity =0.8.25;
import {console2} from "forge-std/Test.sol";

import {LibString} from "solady/utils/LibString.sol";
import {LibZip} from "solady/utils/LibZip.sol";

library Letters {
    using LibString for string;

    function write(string memory input) internal pure returns (string memory) {
        bytes memory b = bytes(input);

        uint256 offset;
        string memory d;
        for (uint256 i = 0; i < b.length; ++i) {
            string[] memory c = m(string(abi.encodePacked(b[i])));
            d = string.concat('<g transform="translate(-', c[0], ', 0)">', d, c[1], "</g>");
            offset += stringToUint(c[0]);
        }
        string memory factor = "34";
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

    function m(string memory char) internal pure returns (string[] memory) {
        string[] memory output = new string[](2);
        if (keccak256(bytes(char)) == keccak256(bytes("A"))) {
            output[0] = "367";
            output[
                1
            ] = '<path d="M317 0v700h-62V476H129v224H68V476H17v-61h51V218q0-90 64-154T286 0h31zm-62 415V64q-54 11-90 54t-36 100v197h126z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("B"))) {
            output[0] = "372";
            output[
                1
            ] = '<path d="M262 415q35 19 56.5 55t21.5 78q0 63-44.5 107.5T188 700H71V476H21v-61h50V0h31q64 0 119 32t87 87 32 119q0 106-78 177zM132 64v348q63-11 105-60t42-114-42-114-105-60zm56 575q37 0 64-27t27-64q0-24-11-44t-30-32.5-42-14.5q-31 13-64 17v165h56z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("C"))) {
            output[0] = "421";
            output[
                1
            ] = '    <path d="M400 254h-62V63q-109 11-183.5 93.5T80 350q0 119 85 204t204 85v61q-95 0-175.5-47T66 525.5 19 350q0-71 28-136t74.5-111.5T233 28 369 0h31v254z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("D"))) {
            output[0] = "451";
            output[
                1
            ] = '    <path d="M81 0q71 0 135.5 28T328 102.5 403 214t28 136q0 95-47 175.5T256.5 653 81 700H50V0h31zm30 637q109-11 183.5-93.5T369 350q0-73-34-136.5T242 110 111 63v574z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("E"))) {
            output[0] = "303";
            output[
                1
            ] = '    <path d="M283 415v61H124v6q0 65 46 111t111 46v61q-44 0-84.5-17.5T127 636t-46.5-69.5T63 482v-6H14v-61h49V218q0-90 64-154T281 0v61q-65 0-111 46t-46 111v197h159z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("F"))) {
            output[0] = "298";
            output[
                1
            ] = '    <path d="M128 218v197h159v61H128v224H67V476H18v-61h49V218q0-90 64-154T285 0v61q-65 0-111 46t-46 111z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("G"))) {
            output[0] = "444";
            output[
                1
            ] = '    <path d="M400 254h-60V63q-110 11-185 93T80 350q0 111 74.5 193.5T338 637V476H238v-61h162v285h-31q-95 0-175.5-47T66 525.5 19 350t47-175.5T193.5 47 369 0h31v254z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("H"))) {
            output[0] = "370";
            output[
                1
            ] = '    <path d="M258 0h62v700h-62V476H132v224H71V476H20v-61h51V0h61v415h126V0z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("I"))) {
            output[0] = "162";
            output[1] = '    <path d="M111 700H50V0h61v700z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("J"))) {
            output[0] = "270";
            output[
                1
            ] = '    <path d="M9 0h218v482q0 90-64 154T9 700v-61q65 0 111-46t46-111V61H9V0z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("K"))) {
            output[0] = "384";
            output[
                1
            ] = '    <path d="M340 238q0 106-78 177 35 19 56.5 55t21.5 78v152h-61V548q0-36-24-62t-59-29q-31 13-64 17v226H71V476H21v-61h50V0h61v412q63-11 105-60t42-114V0h61v238z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("L"))) {
            output[0] = "269";
            output[1] = '    <path d="M111 639h157v61H50V0h61v639z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("M"))) {
            output[0] = "577";
            output[
                1
            ] = '    <path d="M496 0h30v700h-61V64q-63 11-104.5 60T319 238v462h-61V238q0-65-42-114T111 64v636H50V0h31q65 0 120.5 33t86.5 89q21-37 52-64t71.5-42.5T496 0z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("N"))) {
            output[0] = "369";
            output[
                1
            ] = '    <path d="M258 0h61v700h-61V238q0-65-42-114T111 64v636H50V0h31q51 0 97 21t80 58V0z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("O"))) {
            output[0] = "488";
            output[
                1
            ] = '    <path d="M244 0q60 0 110 46t79 126.5T462 350t-29 177.5T354 654t-110 46-110-46-79-126.5T26 350t29-177.5T134 46 244 0zm0 639q64 0 110.5-86T401 350t-46.5-203T244 61t-110.5 86T87 350t46.5 203T244 639zm-55-289 51-78 52 78-52 78z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("P"))) {
            output[0] = "353";
            output[
                1
            ] = '    <path d="M102 0q64 0 119 32t87 87 32 119q0 60-27.5 111.5t-75 84.5T132 474v226H71V476H20v-61h51V0h31zm30 412q42-7 75-31.5t52.5-62T279 238q0-65-42-114T132 64v348z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("Q"))) {
            output[0] = "509";
            output[
                1
            ] = '    <path d="m403 592 90 108h-70l-53-63q-56 63-126 63-60 0-110-46T55 527.5 26 350t29-177.5T134 46 244 0t110 46 79 126.5T462 350q0 142-59 242zm-43-51q41-83 41-191 0-117-46.5-203T244 61t-110.5 86T87 350t46.5 203T244 639q47 0 86-50L226 465h70z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("R"))) {
            output[0] = "376";
            output[
                1
            ] = '    <path d="M261 415q36 19 57.5 55t21.5 78v152h-61V548q0-36-24-62t-59-29q-31 13-64 17v226H71V476H20v-61h51V0h31q64 0 119 32t87 87 32 119q0 106-79 177zm-129-3q63-11 105-60t42-114-42-114-105-60v348z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("S"))) {
            output[0] = "303";
            output[
                1
            ] = '    <path d="M267 254h-62V61h-51q-31 0-53 22t-22 53q0 25 17 66t33 70.5 47 81.5q31 54 46.5 82t30 65.5T267 564q0 56-40 96t-96 40H49v-61h82q20 0 37-10t27-27.5 10-37.5q0-17-13.5-50T164 456.5 123 385q-35-59-52.5-91t-35-78.5T18 136q0-56 40-96t96-40h113v254z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("T"))) {
            output[0] = "259";
            output[1] = '    <path d="M5 0h249v61h-94v639H99V61H5V0z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("U"))) {
            output[0] = "342";
            output[
                1
            ] = '    <path d="M230 0h62v700h-31q-90 0-154-64T43 482V0h61v482q0 37 16.5 70t45.5 55 64 29V0z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("V"))) {
            output[0] = "344";
            output[1] = '    <path d="M276 0h63L172 700 5 0h63l104 436z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("W"))) {
            output[0] = "577";
            output[
                1
            ] = '    <path d="M465 0h61v700h-30q-44 0-84.5-15.5T340 642t-52-64q-31 56-86.5 89T81 700H50V0h61v636q63-11 105-60t42-114V0h61v462q0 65 41.5 114T465 636V0z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("X"))) {
            output[0] = "390";
            output[
                1
            ] = '    <path d="M381 0 228 350l153 350h-66L195 425 74 700H8l154-350L8 0h66l121 275L315 0h66z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("Y"))) {
            output[0] = "370";
            output[1] = '    <path d="M307 0h65L215 451v249h-61V451L-2 0h65l122 356z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("Z"))) {
            output[0] = "297";
            output[
                1
            ] = '    <path d="M280 0 158 415h81v61h-99L93 639h146v61H11l66-224H52v-61h43L198 61H52V0h228z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("a"))) {
            output[0] = "342";
            output[
                1
            ] = '    <path d="M261 0h31v700h-62V476H104v224H43V218q0-90 64-154T261 0zM104 218v197h126V64q-54 11-90 54t-36 100z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("b"))) {
            output[0] = "351";
            output[
                1
            ] = '    <path d="M319 238q0 106-79 177 36 19 57.5 55t21.5 78q0 63-45 107.5T166 700H50V0h31q64 0 119 32t87 87 32 119zm-61 310q0-36-24-62t-59-29q-31 13-64 17v165h55q38 0 65-27t27-64zM111 412q63-11 105-60t42-114-42-114-105-60v348z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("c"))) {
            output[0] = "375";
            output[
                1
            ] = '    <path d="M19 350q0-95 47-175.5T193.5 47 369 0v61q-119 0-204 85T80 350t85 204 204 85v61q-95 0-175.5-47T66 525.5 19 350z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("d"))) {
            output[0] = "451";
            output[
                1
            ] = '    <path d="M431 350q0 95-47 175.5T256.5 653 81 700H50V0h31q95 0 175.5 47T384 174.5 431 350zM111 637q72-7 131-47t93-103.5T369 350t-34-136.5T242 110 111 63v574z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("e"))) {
            output[0] = "277";
            output[
                1
            ] = '    <path d="M97 218v197h159v61H97v6q0 65 46 111t111 46v61q-90 0-154-64T36 482V218q0-90 64-154T254 0v61q-65 0-111 46T97 218z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("f"))) {
            output[0] = "276";
            output[
                1
            ] = '    <path d="M261 61q-65 0-111 46t-46 111v197h159v61H104v224H43V218q0-90 64-154T261 0v61z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("g"))) {
            output[0] = "424";
            output[
                1
            ] = '    <path d="M370 700q-95 0-175.5-47T67 525.5 20 350q0-71 28-136t74.5-111.5T234 28 370 0v61q-119 0-204 85T81 350q0 111 74.5 193.5T339 637V476H239v-61h162v285h-31z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("h"))) {
            output[0] = "349";
            output[1] = '    <path d="M299 0v700h-62V476H111v224H50V0h61v415h126V0h62z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("i"))) {
            output[0] = "162";
            output[1] = '    <path d="M111 700H50V0h61v700z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("j"))) {
            output[0] = "262";
            output[
                1
            ] = '    <path d="M219 482q0 90-64 154T1 700v-61q65 0 111-46t46-111V0h61v482z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("k"))) {
            output[0] = "360";
            output[
                1
            ] = '    <path d="M50 0h61v412q63-11 105-60t42-114V0h61v238q0 63-30 116t-82 86l131 260h-69L152 465q-20 7-41 9v226H50V0z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("l"))) {
            output[0] = "269";
            output[1] = '    <path d="M268 639v61H50V0h61v639h157z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("m"))) {
            output[0] = "530";
            output[
                1
            ] = '    <path d="M258 238q0-43-19.5-80.5t-53-62T111 64v636H50V0h31q34 0 67 9.5T208.5 37 258 79V0h30q82 0 140 58t58 140v502h-61V198q0-48-30-85.5T319 65v635h-61V238z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("n"))) {
            output[0] = "361";
            output[
                1
            ] = '    <path d="M111 64v636H50V0h31q64 0 119 32t87 87 32 119v462h-61V238q0-65-42-114T111 64z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("o"))) {
            output[0] = "488";
            output[
                1
            ] = '    <path d="M244 0q60 0 110 46t79 126.5T462 350t-29 177.5T354 654t-110 46-110-46-79-126.5T26 350t29-177.5T134 46 244 0zm0 639q64 0 110.5-86T401 350t-46.5-203T244 61t-110.5 86T87 350t46.5 203T244 639z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("p"))) {
            output[0] = "333";
            output[
                1
            ] = '    <path d="M50 700V0h31q48 0 92 19t76 51 51 76 19 92q0 60-27.5 111.5t-75 84.5T111 474v226H50zm61-636v348q63-11 105-60t42-114-42-114-105-60z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("q"))) {
            output[0] = "509";
            output[
                1
            ] = '    <path d="M244 0q60 0 110 46t79 126.5T462 350q0 142-59 242l90 108h-70l-53-63q-56 63-126 63-60 0-110-46T55 527.5 26 350t29-177.5T134 46 244 0zm0 639q47 0 86-50L226 465h70l64 76q41-83 41-191 0-117-46.5-203T244 61t-110.5 86T87 350t46.5 203T244 639z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("r"))) {
            output[0] = "355";
            output[
                1
            ] = '    <path d="M319 238q0 42-14 80.5t-39 69-59 52.5l131 260h-69L152 465q-20 7-41 9v226H50V0h31q98 0 168 70t70 168zM111 412q41-7 74.5-31.5t53-62T258 238q0-65-42-114T111 64v348z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("s"))) {
            output[0] = "284";
            output[
                1
            ] = '    <path d="M176 354q31 54 46.5 82t30 65.5T267 564q0 56-40 96t-96 40H49v-61h82q20 0 37-10t27-27.5 10-37.5q0-17-13.5-50T164 456.5 123 385q-35-59-52.5-91t-35-78.5T18 136q0-56 40-96t96-40h82v61h-82q-31 0-53 22t-22 53q0 25 17 66t33 70.5 47 81.5z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("t"))) {
            output[0] = "259";
            output[1] = '    <path d="M160 700H99V61H5V0h249v61h-94v639z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("u"))) {
            output[0] = "343";
            output[
                1
            ] = '    <path d="M296 576q0 51-36.5 87.5t-88 36.5-88-36.5T47 576V0h61v576q0 26 18.5 44.5T171 639q17 0 31.5-8.5t23-23T234 576V0h62v576z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("v"))) {
            output[0] = "341";
            output[
                1
            ] = '    <path d="M295 546q0 54-32.5 96.5T178 699l-8 2-8-2q-51-14-83.5-56.5T46 546V0h61v546q0 31 17.5 56t45.5 35q14-5 26-14t20-21 12.5-26.5T233 546V0h62v546z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("w"))) {
            output[0] = "530";
            output[
                1
            ] = '    <path d="M111 636q63-11 105-60t42-114V0h61v635q46-10 76-47.5t30-85.5V0h61v502q0 82-58 140t-140 58h-30v-79q-34 37-80 58t-97 21H50V0h61v636z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("x"))) {
            output[0] = "341";
            output[
                1
            ] = '    <path d="M295 564v136h-62V564q0-30-17-55t-46-36q-28 11-45.5 36T107 564v136H46V564q0-75 59-123-59-48-59-123V0h61v318q0 30 17.5 55t45.5 36q14-5 26-14.5t20-21 12.5-26T233 318V0h62v318q0 75-59 123 59 48 59 123z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("y"))) {
            output[0] = "307";
            output[
                1
            ] = '    <path d="M216 318V0h62v318q0 47-26 86.5T184 463v237h-61V463q-43-19-68.5-58.5T29 318V0h61v318q0 30 17.5 55t45.5 36q29-11 46-36t17-55z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("z"))) {
            output[0] = "286";
            output[1] = '<path d="M49 0h228L90 639h146v61H8L195 61H49V0z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("0"))) {
            output[0] = "541";
            output[
                1
            ] = '    <path d="M441 0h71l-73 124q50 97 50 226 0 97-29 177.5T381 654t-110 46q-73 0-130-68l-40 68H30l73-124q-50-97-50-226 0-97 28.5-177.5t79-126.5T271 0q73 0 130 68zM114 350q0 87 27 160l227-385q-44-64-97-64-64 0-110.5 86T114 350zm314 0q0-87-28-160L174 575q43 64 97 64 64 0 110.5-86T428 350z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("1"))) {
            output[0] = "202";
            output[1] = '    <path d="M27 61V0h124v700H90V61H27z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("2"))) {
            output[0] = "310";
            output[
                1
            ] = '    <path d="M62 0h82q56 0 96 40t40 96q0 33-18 79.5T226.5 294 175 385q-27 47-41 71.5T106 514t-14 50v75h157v61H31V564q0-25 14.5-62.5T75 436t47-82q31-52 47-81.5t32.5-70.5 16.5-66q0-31-21.5-53T144 61H62V0z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("3"))) {
            output[0] = "311";
            output[
                1
            ] = '    <path d="M270 548q0 63-44.5 107.5T118 700H32v-61h86q38 0 64.5-27t26.5-64q0-24-11-44t-30-32.5-42-14.5q-45 19-94 19v-61q48 0 89-23.5t64.5-64.5 23.5-89q0-73-52-125T32 61V0q98 0 168 70t70 168q0 106-78 177 35 19 56.5 55t21.5 78z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("4"))) {
            output[0] = "349";
            output[
                1
            ] = '    <path d="M273 583v120h-62V583H7L273 0v522h42v61h-42zm-171-61h109V282z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("5"))) {
            output[0] = "324";
            output[
                1
            ] = '    <path d="M155 415q58 0 100 42t42 100.5T255 658t-100 42H76v-61h79q33 0 57-24t24-57.5-24-57.5-57-24H45V0h218v61H106v354h49z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("6"))) {
            output[0] = "437";
            output[
                1
            ] = '    <path d="M406 516q0 76-53.5 130T223 700 93 646 39 516q0-6 1-13h-1V350q0-95 47-175.5T213.5 47 389 0v61q-119 0-204 85t-85 204v30q53-47 123-47 76 0 129.5 53.5T406 516zM223 639q50 0 86-36t36-86.5-36-86.5-86.5-36-86.5 36-36 86q0 25 10 48t26 39 39 26 48 10z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("7"))) {
            output[0] = "301";
            output[1] = '    <path d="M60 61V0h230L85 700H21L209 61H60z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("8"))) {
            output[0] = "341";
            output[
                1
            ] = '    <path d="M295 543v37q0 51-36.5 87.5t-88 36.5-88-36.5T46 580v-37q0-56 43-93-43-38-43-94V124q0-51 36.5-87.5t88-36.5 88 36.5T295 124v232q0 56-43 94 43 37 43 93zM107 356q0 26 18.5 44.5T170 419t44.5-18.5T233 356V124q0-26-18.5-44.5T170 61t-44.5 18.5T107 124v232zm126 224v-37q0-17-8.5-31.5t-23-23T170 480q-26 0-44.5 18.5T107 543v37q0 26 18.5 44.5T170 643t44.5-18.5T233 580z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes("9"))) {
            output[0] = "438";
            output[
                1
            ] = '    <path d="M398 197v153q0 95-46.5 175.5T224 653 48 700v-61q120 0 204.5-85T337 350v-30q-52 47-122 47-76 0-130-53.5T31 184 85 54 215 0t129.5 54T398 184v13zM215 306q50 0 86-36t36-86.5T301 97t-86.5-36T128 97t-36 87q0 33 16.5 61t45 44.5T215 306z"/>';
        } else if (keccak256(bytes(char)) == keccak256(bytes(" "))) {
            output[0] = "209";
            output[1] = '<path d="" />';
        }

        return output;
    }

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
