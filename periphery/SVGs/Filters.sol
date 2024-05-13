// SPDX-License-Identifier: The Unlicense

pragma solidity =0.8.25;
import {LibString} from "solady/utils/LibString.sol";
import {LibZip} from "solady/utils/LibZip.sol";

library Filters {
    using LibString for string;

    function rarity0() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"1e3020302e3936222f3e3c666546756e634720747970653d227461626c65222060060756616c7565733d22e0072b0042e0222b0041e0142b00314080132f6665436f6d706f6e656e745472616e73666572409615426c656e64206d6f64653d22736f66742d6c69676874"
            );
        //'0 0.96"/><feFuncG type="table" tableValues="0 0.96"/><feFuncB type="table" tableValues="0 0.96"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="soft-light';
    }

    function rarity1() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"0130202001012e3220031a3936222f3e3c666546756e634720747970653d227461626c65222060060756616c7565733d22202f4001e0042f0042e0262f0041e0142f00314088132f6665436f6d706f6e656e745472616e73666572409e11426c656e64206d6f64653d2273637265656e"
            );
        //'0 0 0.2 0.96"/><feFuncG type="table" tableValues="0 0 0 0.96"/><feFuncB type="table" tableValues="0 0 0 0.96"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="screen';
    }

    function rarity2() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"1f3020302e343120302e39332031222f3e3c666546756e634720747970653d22740561626c65222060060756616c7565733d22403200334032013732e003320042e0163200322064013531e003310041e01431608d132f6665436f6d706f6e656e745472616e7366657240a315426c656e64206d6f64653d22736f66742d6c69676874"
            );
        //'0 0.41 0.93 1"/><feFuncG type="table" tableValues="0 0.31 0.72 1"/><feFuncB type="table" tableValues="0 0.2 0.51 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="soft-light';
    }

    function rarity3() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"0a3020302e323820302e373520041a3936222f3e3c666546756e634720747970653d227461626c65222060060756616c7565733d22e011350042e01735003320660035e0076b0041e0143500314094132f6665436f6d706f6e656e745472616e7366657240aa11426c656e64206d6f64653d226e6f726d616c"
            );
        //'0 0.28 0.75 0.96"/><feFuncG type="table" tableValues="0 0.28 0.75 0.96"/><feFuncB type="table" tableValues="0 0.23 0.55 0.96"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal';
    }

    function rarity4() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"0a3020302e313420302e353820041a3936222f3e3c666546756e634720747970653d227461626c65222060060756616c7565733d22403500324030013635e006350042e01c35403ae0036b0041e0143500314094132f6665436f6d706f6e656e745472616e7366657240aa11426c656e64206d6f64653d226e6f726d616c"
            );
        //'0 0.14 0.58 0.96"/><feFuncG type="table" tableValues="0 0.28 0.65 0.96"/><feFuncB type="table" tableValues="0 0.28 0.68 0.96"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal';
    }

    function rarity5() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"1f3020302e333720302e343520312031222f3e3c666546756e634720747970653d07227461626c65222060060756616c7565733d226034003620340136322004013932e003370042e016370035403200384071013738e003370041e014376098132f6665436f6d706f6e656e745472616e7366657240ae15426c656e64206d6f64653d22686172642d6c69676874"
            );
        //'0 0.37 0.45 1 1"/><feFuncG type="table" tableValues="0 0.36 0.62 0.92 1"/><feFuncB type="table" tableValues="0 0.52 0.87 0.78 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="hard-light';
    }

    function rarity6() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"0b302030202e323120302e3336c00401373320091c39382031222f3e3c666546756e634720747970653d227461626c65222060060756616c7565733d22404203302e3138c0040033403e00374052013934e003430042e01343012e32407ee006040134342053003740580039e003480041e013488028132f6665436f6d706f6e656e745472616e7366657240cb11426c656e64206d6f64653d2273637265656e"
            );
        //'0 0 .21 0.36 0.36 0.73 0.98 1"/><feFuncG type="table" tableValues="0 0 0.18 0.18 0.33 0.71 0.94 1"/><feFuncB type="table" tableValues="0.26 0.26 0.26 0.26 0.44 0.78 0.9 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="screen';
    }

    function rarity7() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"0130202001022e32342004013639200401393540041b372031222f3e3c666546756e634720747970653d227461626c65222060060756616c7565733d22203c202f0131332004013231200400344009013836e0033e0042e0153e022e3432c0040035408000374041013738e003410041e0144160a9132f6665436f6d706f6e656e745472616e7366657240bf11426c656e64206d6f64653d2273637265656e"
            );
        //'0 0 0.24 0.69 0.95 0.97 1"/><feFuncG type="table" tableValues="0 0 0.13 0.21 0.43 0.86 1"/><feFuncB type="table" tableValues="0 0.42 0.42 0.59 0.73 0.78 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="screen';
    }

    function rarity8() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"0a3020302e303820302e3336200401383140041d3820312031222f3e3c666546756e634720747970653d227461626c65222060060756616c7565733d22603e00372034013334200401383520040132392004013734e003410042e01641203240780039403e0037408c013733e0033e0041e0143e60a9132f6665436f6d706f6e656e745472616e7366657240bf15426c656e64206d6f64653d22686172642d6c69676874"
            );
        //'0 0.08 0.36 0.81 0.88 1 1"/><feFuncG type="table" tableValues="0 0.07 0.34 0.85 0.29 0.74 1"/><feFuncB type="table" tableValues="0 0.29 1 0.95 0.78 0.73 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="hard-light';
    }

    function rarity9() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"08302e303720302e33312004013634200401373620041a3933222f3e3c666546756e634720747970653d227461626c65222060060a56616c7565733d22302e31403d0034403d0035403d0039400e013832e0013d0042e0143d0033402e01373520710038603d4009013739e0013d0041e0133d0120314028132f6665436f6d706f6e656e745472616e7366657240ba11426c656e64206d6f64653d226e6f726d616c"
            );
        //'0.07 0.31 0.64 0.76 0.93"/><feFuncG type="table" tableValues="0.17 0.41 0.54 0.97 0.82"/><feFuncB type="table" tableValues="0.37 0.75 0.84 0.95 0.79"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal';
    }

    function rarity10() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"07302e3220302e31332004003940091a3938222f3e3c666546756e634720747970653d227461626c65222060060756616c7565733d22603720340338342031e001310042e01731062e333620312030e001310041e01331805a132f6665436f6d706f6e656e745472616e7366657240a211426c656e64206d6f64653d226e6f726d616c"
            );
        //'0.2 0.13 0.92 0.98"/><feFuncG type="table" tableValues="0.2 0 0.84 1"/><feFuncB type="table" tableValues="0.2 0.36 1 0"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal';
    }

    function rarity11() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"08302e313720302e333620040137382004013232200420091931222f3e3c666546756e634720747970653d227461626c65222060060756616c7565733d22203f20354001032e392031e003350042e015354066013233203202302e352041403de001710041e0133b8028132f6665436f6d706f6e656e745472616e7366657240b012426c656e64206d6f64653d226f7665726c6179"
            );
        //'0.17 0.36 0.78 0.22 0.78 1"/><feFuncG type="table" tableValues="0.18 0 0 0.9 1 1"/><feFuncB type="table" tableValues="0.12 0.23 1 0.58 0.9 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="overlay';
    }

    function rarity12() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"0c3020302e303320302e363920312006003540041c37322031222f3e3c666546756e634720747970653d227461626c65222060060756616c7565733d22403e0133322037013138200401353420040138352048e0023e0042e0163e0134352034608140040039400d4042e0017f0041e014406028132f6665436f6d706f6e656e745472616e7366657240be11426c656e64206d6f64653d226e6f726d616c"
            );
        //'0 0.03 0.69 1 0.51 0.72 1"/><feFuncG type="table" tableValues="0 0.32 0.18 0.54 0.85 1 1"/><feFuncB type="table" tableValues="0 0.45 0.3 0.63 0.95 0.85 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal';
    }

    function rarity13() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"0830203120302e373320400600354004400b18222f3e3c666546756e634720747970653d227461626c65222060060856616c7565733d22302039003240320131342009003940090138394009204de001410042e01641013131607b0131334039603e0038e0033e0041e0143e6067132f6665436f6d706f6e656e745472616e7366657240bf11426c656e64206d6f64653d226e6f726d616c"
            );
        //'0 1 0.73 1 0.51 0.73 1"/><feFuncG type="table" tableValues="0 0.21 0.14 0.91 0.89 0.93 1"/><feFuncB type="table" tableValues="0 0.11 1 0.13 0.99 0.98 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal';
    }

    function rarity14() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"1f302e3833203020302e35352031222f3e3c666546756e634720747970653d22740561626c65222060060b56616c7565733d22302e3035203000372030e003320042e01432013839202d0030e0032f0041e0132f8028132f6665436f6d706f6e656e745472616e7366657240a111426c656e64206d6f64653d226e6f726d616c"
            );
        //'0.83 0 0.55 1"/><feFuncG type="table" tableValues="0.05 0.75 1 1"/><feFuncB type="table" tableValues="0.89 1 0 1"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal';
    }

    function rarity15() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"03302e372080030130342008c0040031200b4018600f1937222f3e3c666546756e634720747970653d227461626c65222060060956616c7565733d22302e403560030036203ec0046010e0000fe0014a0042e0144a003240426004013338203cc0044048e00115013236e0014e0041e0134e00206077132f6665436f6d706f6e656e745472616e7366657240d811426c656e64206d6f64653d2273637265656e"
            );
        //'0.7 0.7 0.04 0.04 0.04 1 0.7 0.04 0.7"/><feFuncG type="table" tableValues="0.1 0.1 0.16 0.16 0.16 1 0.1 0.16 0.1"/><feFuncB type="table" tableValues="0.26 0.26 0.38 0.38 0.38 1 0.26 0.38 0.26"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="screen';
    }

    function rarity16() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"1f302031203020302e3936222f3e3c666546756e634720747970653d227461626c0265222060060b56616c7565733d22302e3437603000382006022e3938e001350042e012352063012e3340300136342009013434e001350041e01235209b4028132f6665436f6d706f6e656e745472616e7366657240aa11426c656e64206d6f64653d226e6f726d616c"
            );
        //'0 1 0 0.96"/><feFuncG type="table" tableValues="0.47 0 0.87 0.98"/><feFuncB type="table" tableValues="1 0.37 0.64 0.44"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal';
    }

    function rarity17() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"083020302e303120302020031e2e39362031222f3e203c666546756e634720747970653d227461626c65222060060756616c7565733d2240370134372033003820042006013938e0043a0042e0143a406b01363420350033203c022e3434e0043a0041e0153a209f153c2f6665436f6d706f6e656e745472616e736665723e20b411426c656e64206d6f64653d226e6f726d616c"
            );
        //'0 0.01 0 1 0.96 1"/> <feFuncG type="table" tableValues="0 0.47 0.87 0 0.98 1"/> <feFuncB type="table" tableValues="0 1 0.64 0.37 0.44 1"/> <feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal';
    }

    function rarity18() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"08302e393820302e373520041a3531222f3e3c666546756e634720747970653d227461626c65222060060856616c7565733d2231202b003440300031e002300042e01230206440330133392038013239e001640041e013330020605c132f6665436f6d706f6e656e745472616e7366657240a311426c656e64206d6f64653d226e6f726d616c"
            );
        //'0.98 0.75 0.51"/><feFuncG type="table" tableValues="1 0.45 0.11"/><feFuncB type="table" tableValues="0.91 0.39 0.29"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal';
    }

    function rarity19() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"04302e393820200420031a3437222f3e3c666546756e634720747970653d227461626c65222060060856616c7565733d2231202b0136322004013331e001300042e01230205e403300332032013033e001320041e013320020605b132f6665436f6d706f6e656e745472616e7366657240a211426c656e64206d6f64653d226e6f726d616c"
            );
        //'0.98 0.9 0.47"/><feFuncG type="table" tableValues="1 0.62 0.31"/><feFuncB type="table" tableValues="0.91 0.3 0.03"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal';
    }

    function rarity20() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"08302e393820302e383520041a3235222f3e3c666546756e634720747970653d227461626c65222060060856616c7565733d2231202b4034e0032f0042e0122f2063003220320132372004013039e001630041e013330120314028132f6665436f6d706f6e656e745472616e7366657240a211426c656e64206d6f64653d226e6f726d616c"
            );
        //'0.98 0.85 0.25"/><feFuncG type="table" tableValues="1 0.8 0.25"/><feFuncB type="table" tableValues="0.92 0.27 0.09"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal';
    }

    function rarity21() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"07302e393820302e3320031a3234222f3e3c666546756e634720747970653d227461626c65222060060856616c7565733d2231202b0136322004e0022f0042e0122f2062403200334067013236e001630041e013330120314028132f6665436f6d706f6e656e745472616e7366657240a211426c656e64206d6f64653d226e6f726d616c"
            );
        //'0.98 0.3 0.24"/><feFuncG type="table" tableValues="1 0.62 0.4"/><feFuncB type="table" tableValues="0.91 0.38 0.26"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal';
    }

    function rarity22() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"07302e393820302e3320031a3235222f3e3c666546756e634720747970653d227461626c65222060060856616c7565733d2231202b0134342004013234e001300042e01230206340330136322033013339e001330041e013330120314028132f6665436f6d706f6e656e745472616e7366657240a311426c656e64206d6f64653d226e6f726d616c"
            );
        //'0.98 0.3 0.25"/><feFuncG type="table" tableValues="1 0.44 0.24"/><feFuncB type="table" tableValues="0.91 0.62 0.39"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal';
    }

    function rarity23() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"07302e393820302e3420031a3235222f3e3c666546756e634720747970653d227461626c65222060060856616c7565733d2231202b00332003013234e0012f0042e0122f206240320136322033013339e001330041e013330120314028132f6665436f6d706f6e656e745472616e7366657240a211426c656e64206d6f64653d226e6f726d616c"
            );
        //'0.98 0.4 0.25"/><feFuncG type="table" tableValues="1 0.3 0.24"/><feFuncB type="table" tableValues="0.91 0.62 0.39"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal';
    }

    function rarity24() internal pure returns (bytes memory) {
        return
            LibZip.flzDecompress(
                hex"08302e393820302e363520041a3434222f3e3c666546756e634720747970653d227461626c65222060060856616c7565733d2231202be008300042e012302064e00c330041e01333012031408d132f6665436f6d706f6e656e745472616e7366657240a311426c656e64206d6f64653d226e6f726d616c"
            );
        //'0.98 0.65 0.44"/><feFuncG type="table" tableValues="1 0.65 0.44"/><feFuncB type="table" tableValues="0.91 0.65 0.44"/><feFuncA type="table" tableValues="0 1"/></feComponentTransfer><feBlend mode="normal';
    }

    function addFilter(string memory svgIn, uint256 rarity) public pure returns (string memory) {
        if (rarity == 0) {
            return svgIn.replace("<!-- FILTER -->", string(rarity0()));
        } else if (rarity == 1) {
            return svgIn.replace("<!-- FILTER -->", string(rarity1()));
        } else if (rarity == 2) {
            return svgIn.replace("<!-- FILTER -->", string(rarity2()));
        } else if (rarity == 3) {
            return svgIn.replace("<!-- FILTER -->", string(rarity3()));
        } else if (rarity == 4) {
            return svgIn.replace("<!-- FILTER -->", string(rarity4()));
        } else if (rarity == 5) {
            return svgIn.replace("<!-- FILTER -->", string(rarity5()));
        } else if (rarity == 6) {
            return svgIn.replace("<!-- FILTER -->", string(rarity6()));
        } else if (rarity == 7) {
            return svgIn.replace("<!-- FILTER -->", string(rarity7()));
        } else if (rarity == 8) {
            return svgIn.replace("<!-- FILTER -->", string(rarity8()));
        } else if (rarity == 9) {
            return svgIn.replace("<!-- FILTER -->", string(rarity9()));
        } else if (rarity == 10) {
            return svgIn.replace("<!-- FILTER -->", string(rarity10()));
        } else if (rarity == 11) {
            return svgIn.replace("<!-- FILTER -->", string(rarity11()));
        } else if (rarity == 12) {
            return svgIn.replace("<!-- FILTER -->", string(rarity12()));
        } else if (rarity == 13) {
            return svgIn.replace("<!-- FILTER -->", string(rarity13()));
        } else if (rarity == 14) {
            return svgIn.replace("<!-- FILTER -->", string(rarity14()));
        } else if (rarity == 15) {
            return svgIn.replace("<!-- FILTER -->", string(rarity15()));
        } else if (rarity == 16) {
            return svgIn.replace("<!-- FILTER -->", string(rarity16()));
        } else if (rarity == 17) {
            return svgIn.replace("<!-- FILTER -->", string(rarity17()));
        } else if (rarity == 18) {
            return svgIn.replace("<!-- FILTER -->", string(rarity18()));
        } else if (rarity == 19) {
            return svgIn.replace("<!-- FILTER -->", string(rarity19()));
        } else if (rarity == 20) {
            return svgIn.replace("<!-- FILTER -->", string(rarity20()));
        } else if (rarity == 21) {
            return svgIn.replace("<!-- FILTER -->", string(rarity21()));
        } else if (rarity == 22) {
            return svgIn.replace("<!-- FILTER -->", string(rarity22()));
        } else if (rarity == 23) {
            return svgIn.replace("<!-- FILTER -->", string(rarity23()));
        } else if (rarity >= 24) {
            return svgIn.replace("<!-- FILTER -->", string(rarity24()));
        }
    }
}
