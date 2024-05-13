// SPDX-License-Identifier: The Unlicense

pragma solidity =0.8.25;

import {console2} from "forge-std/Test.sol";
import {LibString} from "solady/utils/LibString.sol";
import {LibZip} from "solady/utils/LibZip.sol";
import {Letters} from "@periphery/SVGs/Letters.sol";

library Labels {
    using LibString for string;

    function strategy(uint256 index) internal pure returns (string memory) {
        if (index == 0) {
            return "Naked Position";
        } else if (index == 1) {
            return "Spread";
        } else if (index == 2) {
            return "Straddle";
        } else if (index == 3) {
            return "Butterfly";
        } else if (index == 4) {
            return "Iron Condor";
        } else if (index == 5) {
            return "Jade Lizard";
        } else if (index == 6) {
            return "Bull Spread";
        } else if (index == 7) {
            return "Calendar";
        } else if (index == 8) {
            return "Covered Position";
        } else if (index == 9) {
            return "ZEBRA";
        } else if (index == 10) {
            return "Bear Spread";
        } else if (index == 11) {
            return "BATS";
        } else if (index == 12) {
            return "Strangle";
        } else if (index == 13) {
            return "Big Lizard";
        } else if (index == 14) {
            return "Ratio Spread";
        } else if (index == 15) {
            return "ZEEHBS";
        }
    }

    function rarityName(uint256 rarity) internal pure returns (string memory) {
        if (rarity == 0) {
            return "Common";
        } else if (rarity == 1) {
            return "  Rare  ";
        } else if (rarity == 2) {
            return " Mythic ";
        } else if (rarity == 3) {
            return "Legendary";
        } else if (rarity == 4) {
            return "Agathic";
        } else if (rarity == 5) {
            return "Quixotic";
        } else if (rarity == 6) {
            return "Enigmatic";
        } else if (rarity == 7) {
            return "  Utopic  ";
        } else if (rarity == 8) {
            return " Vitalic ";
        } else if (rarity == 9) {
            return "Ethereonic";
        } else if (rarity == 10) {
            return "Prometheic";
        } else if (rarity == 11) {
            return "  Orphic  ";
        } else if (rarity == 12) {
            return " Prismatic ";
        } else if (rarity == 13) {
            return "Phantasmagoric";
        } else if (rarity == 14) {
            return " Cosmic ";
        } else if (rarity == 15) {
            return "Atomic";
        } else if (rarity == 16) {
            return "Quantic";
        } else if (rarity == 17) {
            return "Tachyonic";
        } else if (rarity == 18) {
            return "Leptonic";
        } else if (rarity == 19) {
            return " Quarktic ";
        } else if (rarity == 20) {
            return " Branic ";
        } else if (rarity == 21) {
            return "  Conic  ";
        } else if (rarity == 22) {
            return " Comic ";
        } else if (rarity == 23) {
            return "Stereotypic";
        } else if (rarity >= 24) {
            return "  Basic  ";
        }
    }

    function getDescription(uint256 index, uint256 rarity) internal pure returns (string memory) {
        if (index == 0) {
            // Naked Position
            string memory description = string(
                LibZip.flzDecompress(
                    hex"1f41204e616b656420506f736974696f6e20696e766f6c7665732073656c6c696e116720612063616c6c206f7220707574206f70602504776974686f400e01776e40230a74686520756e6465726c79400e0361737365202a047220616e6f201a0472206f666620110074401ba0400070a06f022e2053e00067006e6089e0036d0a63616e206c65616420746f605f0266696e20ab067269736b2065782042077572652e2054686920ad077472617465677920200b0175732024037768656e609720d002657374208c20220a6f6e676c792062656c69652014601ea08f01776920e320ad042063726f7380190c737472696b652070726963652e"
                )
            );
            //"A Naked Position involves selling a call or put option without owning the underlying asset or another offsetting option position. Selling a naked call or put can lead to undefined risk exposure. This strategy is used when the investor strongly believes the option will not cross the strike price.";
            return description;
        } else if (index == 1) {
            // Spread
            string memory description = string(
                LibZip.flzDecompress(
                    hex"1f412053707265616420697320616e206f7074696f6e7320737472617465677920137468617420696e766f6c76657320627579696e67202805642073656c6c800b0f20657175616c206e756d626572206f66e00044200a127468652073616d652074797065202863616c6c20171572207075747329207769746820646966666572656e74407407696b652070726963606b0074e0013e0a77696474682e2042756c6c607d0562656172207360b9027320632083036265206320c70574656420757340970065205b208ee00471072c20646570656e64401f016f6e605d20da166573746f722773206d61726b6574206f75746c6f6f6b2e"
                )
            );
            //"A Spread is an options strategy that involves buying and selling an equal number of options of the same type (calls or puts) with different strike prices but the same width. Bull and bear spreads can be created using either calls or puts, depending on the investor's market outlook.";
            return description;
        } else if (index == 2) {
            // Straddle
            string memory description = string(
                LibZip.flzDecompress(
                    hex"1b546865205374726164646c6520697320616e206f7074696f6e73207320161f7465677920696e766f6c76696e67207468652073696d756c74616e656f7573200d7075726368617365206f7220736120420d6f6620626f746820612063616c6c204e0064200a02707574a05502207769201c604601616d204b0f7472696b652070726963652e2042757940642014608e0073408f0875736564207768656e6034208902657374206b0565787065637420a31069676e69666963616e74206d6f76656d6520080069802c05756e6465726c60520561737365742720ae4068022c2062208f20eb04756e73757260b20d74686520646972656374696f6e2e"
                )
            );
            //"The Straddle is an options strategy involving the simultaneous purchase or sale of both a call and a put option with the same strike price. Buying straddles is used when the investor expects significant movement in the underlying asset's price, but is unsure of the direction.";
            return description;
        } else if (index == 3) {
            //Butterfly
            string memory description = string(
                LibZip.flzDecompress(
                    hex"1f54686520427574746572666c79206f7074696f6e7320737472617465677920691c6e766f6c76657320627579696e67206f6e652063616c6c202870757429a02f052c2077726974401e0e74776f20617420612068696768657240470d696b652070726963652c20616e64c04703616e6f744020402c056e206576656ee00b32062e204974206973204f026e657520920e6c2c20646566696e6564207269736b405e80a60175732012017768204520550620756e6465726c60af0361737365604205657870656374202510746f2072656d61696e20737461626c652e"
                )
            );
            //"The Butterfly options strategy involves buying one call (put) option, writing two at a higher strike price, and buying another at an even higher strike price. It is a neutral, defined risk strategy used when the underlying asset is expected to remain stable.";
            return description;
        } else if (index == 4) {
            //Iron Condor
            string memory description = string(
                LibZip.flzDecompress(
                    hex"1f5468652049726f6e20436f6e646f72206973206120646566696e656420726973146b2c206e6f6e2d646972656374696f6e616c206f7040081373207374726174656779207468617420636f6d622034403e1162756c6c207075742073707265616420616e2003072062656172206361201a80160a2e20497420696e766f6c7620350673656c6c696e67202740388031602c806d002020610061203805656369666963407a1d696b65207072696365207768696c652073696d756c74616e656f75736c7920830079e0164e0e66757274686572206f75742d6f662d200b0e2d6d6f6e657920737472696b65732e"
                )
            );
            //"The Iron Condor is a defined risk, non-directional options strategy that combines a bull put spread and a bear call spread. It involves selling a put and a call option at a specific strike price while simultaneously buying a put and a call option at further out-of-the-money strikes.";
            return description;
        } else if (index == 5) {
            // Jade Lizard
            string memory description = string(
                LibZip.flzDecompress(
                    hex"1f546865204a616465204c697a617264206973206120646566696e6564207269731f6b2c20736c696768746c792062756c6c697368206f7074696f6e7320737472610d74656779207468617420636f6d622035403f0c73686f72742070757420616e64204f1563616c6c20637265646974207370726561642e205468206ae000410a686173206e6f2075707369208b4077603a0970726f666974732069662063176520756e6465726c79696e672061737365742072656d616920890577697468696e20690e73706563696669632072616e67652c60184016e007c204626961732e"
                )
            );
            // "The Jade Lizard is a defined risk, slightly bullish options strategy that combines a short put and a call credit spread. This strategy has no upside risk and profits if the underlying asset remains within a specific range, with a slightly bullish bias.";
            return description;
        } else if (index == 6) {
            // Bull Spread
            string memory description = string(
                LibZip.flzDecompress(
                    hex"1f412042756c6c2053707265616420697320616e206f7074696f6e7320737472611d74656779207468617420696e766f6c76657320627579696e6720612063612039042870757429a0320420776974682018046c6f776572403e08696b65207072696365205605642073656c6ce016390368696768e0063a032e2054682097e0008c200b0875736564207768656e2099006540980b6573746f722065787065637420c204206d6f646540bb0320726973402060278088016f66600c01756e20210b6c79696e672061737365742e"
                )
            );
            //"A Bull Spread is an options strategy that involves buying a call (put) option with a lower strike price and selling a call (put) option with a higher strike price. This strategy is used when the investor expects a moderate rise in the price of the underlying asset.";
            return description;
        } else if (index == 7) {
            // Calendar
            string memory description = string(
                LibZip.flzDecompress(
                    hex"1f5468652043616c656e6461722053707265616420697320616e206f7074696f6e1e73207374726174656779207468617420696e766f6c76657320627579696e67202805642073656c6c400b0274776fe00035016f66202f10652073616d652074797065202863616c6c20170b722070757473292077697468e00122206408696b65207072696365205a0a7420646966666572656e74202807647468732e20546820972027808c200b0875736564207768656e6046209802657374205e0665787065637473601405756e6465726c80a8067373657420746f2028006320e5007340310b20766f6c6174696c6974792e"
                )
            );
            //"The Calendar Spread is an options strategy that involves buying and selling two options of the same type (calls or puts) with the same strike price but different widths. This strategy is used when the investor expects the underlying asset to increase in volatility.";
            return description;
        } else if (index == 8) {
            // Covered Position
            string memory description = string(
                LibZip.flzDecompress(
                    hex"1f4120436f766572656420506f736974696f6e20696e766f6c7665732073656c6c12696e6720612063616c6c202870757429206f706024177768696c652073696d756c74616e656f75736c79206f776e402f0028a0380c292074686520756e6465726c7940180961737365742e20546869205c077472617465677920200b017573207f06746f2067656e654015208208636f6d652066726f6d6043a074067072656d69756da07c026c696d20b0209f006420771273696465202875707369646529207269736b2e"
                )
            );
            //"A Covered Position involves selling a call (put) option while simultaneously owning (selling) the underlying asset. This strategy is used to generate income from the option premium while limiting downside (upside) risk.";
            return description;
        } else if (index == 9) {
            // ZEBRA
            string memory description = string(
                LibZip.flzDecompress(
                    hex"1f546865205a4542524120285a65726f2045787472696e736963204261636b20520d6174696f2920697320612073746f20110d7265706c6163656d656e74206f70201d016e7320190a7261746567792074686174602101696320100573206c6f6e67201d4037196f776e657273686970207769746820616e20656d626564646564402007702d6c6f73732e20e0018e02686173204e166520616476616e74616765206f66206e6f742070617969205504616e792065e000ac0876616c756520666f7260331270726f7465637469766520666561747572652e"
                )
            );
            //"The ZEBRA (Zero Extrinsic Back Ratio) is a stock replacement options strategy that replicates long stock ownership with an embedded stop-loss. The ZEBRA has the advantage of not paying any extrinsic value for the protective feature.";
            return description;
        } else if (index == 10) {
            // Bear Spread
            string memory description = string(
                LibZip.flzDecompress(
                    hex"1f4120426561722053707265616420697320616e206f7074696f6e7320737472611f74656779207468617420696e766f6c76657320627579696e6720612063616c6c05202870757429a032042077697468201805686967686572403f08696b65207072696365205705642073656c6ce0163a026c6f77e00639032e2054682097e0008c200b0875736564207768656e2099006540980b6573746f722065787065637420c204206d6f646540bb032064656320714023602a808a016f66600c01756e20240b6c79696e672061737365742e"
                )
            );
            //"A Bear Spread is an options strategy that involves buying a call (put) option with a higher strike price and selling a call (put) option with a lower strike price. This strategy is used when the investor expects a moderate decline in the price of the underlying asset.";
            return description;
        } else if (index == 11) {
            // BATS
            string memory description = string(
                LibZip.flzDecompress(
                    hex"1f546865204241545320737472617465677920636f6d62696e65732073686f72740d2070757420616e642063616c6c2020220b696f20737072656164732e20403ce000371f70726f666974732066726f6d2074686520756e6465726c79696e67206173736501742020610064400d0b77697468696e2061206465662069006420560a6e67652c207768696c65202067016f7740260d666f7220706f74656e7469616c20805e0820656e68616e63656d201520640b726f756768206d6f72652067204402756c61403201736920a50d6e2061646a7573746d656e74732e"
                )
            );
            //"The BATS strategy combines short put and call ratio spreads. The strategy profits from the underlying asset trading within a defined range, while allowing for potential profit enhancement through more granular position adjustments.";
            return description;
        } else if (index == 12) {
            // Strangle
            string memory description = string(
                LibZip.flzDecompress(
                    hex"1f54686520537472616e676c6520696e766f6c76657320627579696e67206f72200373656c6c400a09612063616c6c20616e64200a17707574206f7074696f6e2077697468207468652073616d65200d0064200e402418646966666572656e7420737472696b65207072696365732e204070604aa0170869732061626f76652c603600742049405de0011c0462656c6f776017026375726050066d61726b6574206050022e2053e000a0203380c60970726f66697473206966603705756e6465726c60d006617373657427732021208c072072656d61696e732007076c61746976656c7920430e61626c65206f7665722074696d652e"
                )
            );
            // "The Strangle involves buying or selling a call and a put option with the same width and different strike prices. The call strike is above, and the put strike is below the current market price. Selling a strangle profits if the underlying asset's price remains relatively stable over time.";
            return description;
        } else if (index == 13) {
            // Big Lizard
            string memory description = string(
                LibZip.flzDecompress(
                    hex"1f54686520426967204c697a617264206973206120646566696e6564207269736b1f2c206e65757472616c20746f20736c696768746c792062756c6c697368206f700674696f6e73207320210d74656779207468617420636f6d622040404a0473686f7274601e0764646c6520616e64205f086c6f6e672063616c6ca03f032e2054682078e000440c686173206e6f20757073696465608560380970726f666974732069662066096520756e6465726c7969204b0a61737365742072656d6169208c0577697468696e20670e73706563696669632072616e67652c60184016e007c504626961732e"
                )
            );
            // "The Big Lizard is a defined risk, neutral to slightly bullish options strategy that combines a short straddle and a long call option. This strategy has no upside risk and profits if the underlying asset remains within a specific range, with a slightly bullish bias.";
            return description;
        } else if (index == 14) {
            // Ratio Spread
            string memory description = string(
                LibZip.flzDecompress(
                    hex"1854686520526174696f2053707265616420697320616e206f7020121f6e73207374726174656779207468617420696e766f6c76657320627579696e67132061206365727461696e206e756d626572206f66e0003916616e642073696d756c74616e656f75736c792073656c6c803608646966666572656e74e00a382043127468652073616d652074797065202863616c6c20170a722070757473292e20546820a4e00099200b1b7573656420746f206c696d6974207269736b207768696c6520706f7420640069203f07792070726f666974407f0866726f6d206d6f646540db0c207072696365206d6f7665732e"
                )
            );
            //"The Ratio Spread is an options strategy that involves buying a certain number of options and simultaneously selling a different number of options of the same type (calls or puts). This strategy is used to limit risk while potentially profiting from moderate price moves.";
            return description;
        } else if (index == 15) {
            // ZEEHBS
            string memory description = string(
                LibZip.flzDecompress(
                    hex"1f546865205a454548425320285a65726f2045787472696e7369632048656467651f64204261636b205370726561642920697320616e206f7074696f6e7320737472166174656779207468617420636f6d62696e65732074776f20531242524173207769746820612073796e7468657420540973686f727420706f736940420420746f2068406620410965206f766572616c6c2020550364652e20e0029ae00068086361706974616c697a2066403e2035047570736964203c00662067607505207768696c65605702696e676023e0006f0261676120dc40800b74656e7469616c206c6f7373204c017573c02be002ab04686f72742e"
                )
            );
            // "The ZEEHBS (Zero Extrinsic Hedged Back Spread) is an options strategy that combines two ZEBRAs with a synthetic short position to hedge the overall trade. The ZEEHBS strategy capitalizes on the upside of a ZEBRA while hedging the position against potential losses using the synthetic short.";
            return description;
        }
    }

    function addDescription(
        string memory contents,
        uint256 index,
        uint256 rarity
    ) public pure returns (string memory) {
        return contents.replace("<!-- TEXT -->", getDescription(index, rarity));
    }

    function addRarity(string memory contents, uint256 rarity) public pure returns (string memory) {
        uint256 maxWidth;
        if (rarity < 3) {
            maxWidth = 210;
        } else if (rarity < 6) {
            maxWidth = 220;
        } else if (rarity < 9) {
            maxWidth = 210;
        } else if (rarity < 12) {
            maxWidth = 220;
        } else if (rarity < 15) {
            maxWidth = 260;
        } else if (rarity < 18) {
            maxWidth = 225;
        } else if (rarity < 19) {
            maxWidth = 225;
        } else if (rarity < 20) {
            maxWidth = 260;
        } else if (rarity < 21) {
            maxWidth = 220;
        } else if (rarity < 22) {
            maxWidth = 210;
        } else if (rarity < 23) {
            maxWidth = 220;
        } else if (rarity >= 23) {
            maxWidth = 210;
        }

        string memory svgOut = contents.replace(
            "<!-- RARITY_NAME -->",
            Letters.write(rarityName(rarity), maxWidth)
        );
        svgOut = svgOut.replace("<!-- RARITY -->", Letters.write(LibString.toString(rarity)));
        return svgOut;
    }

    function addLabel(
        string memory contents,
        uint256 index,
        uint256 rarity
    ) public pure returns (string memory) {
        uint256 maxWidth;
        if (rarity < 3) {
            maxWidth = 9000;
        } else if (rarity < 6) {
            maxWidth = 9000;
        } else if (rarity < 9) {
            maxWidth = 3900;
        } else if (rarity < 12) {
            maxWidth = 3900;
        } else if (rarity < 15) {
            maxWidth = 3900;
        } else if (rarity < 18) {
            maxWidth = 3900;
        } else if (rarity < 19) {
            maxWidth = 3900;
        } else if (rarity < 20) {
            maxWidth = 3900;
        } else if (rarity < 21) {
            maxWidth = 3900;
        } else if (rarity < 22) {
            maxWidth = 3900;
        } else if (rarity < 23) {
            maxWidth = 9000;
        } else if (rarity >= 23) {
            maxWidth = 9000;
        }

        return contents.replace("<!-- LABEL -->", Letters.write(strategy(index), maxWidth));
    }

    function addAddress(
        string memory contents,
        string memory hexAddress
    ) public pure returns (string memory) {
        return contents.replace("<!-- POOLADDRESS -->", hexAddress);
    }

    function addChainId(
        string memory contents,
        string memory chainid
    ) public pure returns (string memory) {
        return contents.replace("<!-- CHAINID -->", chainid);
    }

    function getChainId(uint256 chainid) public pure returns (string memory) {
        if (chainid == 1) {
            return "Ethereum Mainnet";
        } else if (chainid == 56) {
            return "BNB Smart Chain Mainnet";
        } else if (chainid == 42161) {
            return "Arbitrum One";
        } else if (chainid == 8453) {
            return "Base";
        } else if (chainid == 43114) {
            return "Avalanche C-Chain";
        } else if (chainid == 137) {
            return "Polygon Mainnet";
        } else if (chainid == 10) {
            return "OP Mainnet";
        } else if (chainid == 42220) {
            return "Celo Mainnet";
        } else if (chainid == 238) {
            return "Blast Mainnet";
        }
    }
}
