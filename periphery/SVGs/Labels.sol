// SPDX-License-Identifier: The Unlicense

pragma solidity =0.8.25;

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
            return "Rare";
        } else if (rarity == 2) {
            return "Mythic";
        } else if (rarity == 3) {
            return "Legendary";
        } else if (rarity == 4) {
            return "Agathic";
        } else if (rarity == 5) {
            return "Quixotic";
        } else if (rarity == 6) {
            return "Enigmatic";
        } else if (rarity == 7) {
            return "Phantasmagoric";
        } else if (rarity == 8) {
            return "Utopic";
        } else if (rarity == 9) {
            return "Vitalic";
        } else if (rarity == 10) {
            return "Etheronic";
        } else if (rarity == 11) {
            return "Orphic";
        } else if (rarity == 12) {
            return "Prometheic";
        } else if (rarity == 13) {
            return "Prismatic";
        } else if (rarity == 14) {
            return "Cosmic";
        } else if (rarity == 15) {
            return "Atomic";
        } else if (rarity == 16) {
            return "Quantic";
        } else if (rarity == 17) {
            return "Tachyonic";
        } else if (rarity == 18) {
            return "Leptonic";
        } else if (rarity == 19) {
            return "Quarktic";
        } else if (rarity == 20) {
            return "Branic";
        } else if (rarity == 21) {
            return "Conic";
        } else if (rarity == 22) {
            return "Comic";
        } else if (rarity == 23) {
            return "Stereotypic";
        } else if (rarity >= 24) {
            return "Basic";
        }
    }

    function getDescription(uint256 index, uint256 rarity) internal pure returns (string memory) {
        if (index == 0) {
            // Naked Position
            return
                "A Naked Position involves selling a call or put option without owning the underlying asset or another offsetting option position. Selling a naked call or put can lead to undefined risk exposure. This strategy is used when the investor strongly believes the option will not cross the strike price.";
        } else if (index == 1) {
            // Spread
            return
                "A Spread is an options strategy that involves buying and selling an equal number of options of the same type (calls or puts) with different strike prices but the same expiration date. Bull and bear spreads can be created using either calls or puts, depending on the investor's market outlook.";
        } else if (index == 2) {
            // Straddle
            return
                "The Straddle is an options strategy involving the simultaneous purchase or sale of both a call and a put option with the same strike price. Buying straddles is used when the investor expects significant movement in the underlying asset's price, but is unsure of the direction.";
        } else if (index == 3) {
            //Butterfly
            return
                "The Butterfly options strategy involves buying one call (put) option, writing two at a higher strike price, and buying another at an even higher strike price. It is a neutral, defined risk strategy used when the underlying asset is expected to remain stable.";
        } else if (index == 4) {
            //Iron Condor
            return
                "The Iron Condor is a defined risk, non-directional options strategy that combines a bull put spread and a bear call spread. It involves selling a put and a call option at a specific strike price while simultaneously buying a put and a call option at further out-of-the-money strikes.";
        } else if (index == 5) {
            // Jade Lizard
            return
                "The Jade Lizard is a defined risk, slightly bullish options strategy that combines a short put and a call credit spread. This strategy has no upside risk and profits if the underlying asset remains within a specific range, with a slightly bullish bias.";
        } else if (index == 6) {
            // Bull Spread
            return
                "A Bull Spread is an options strategy that involves buying a call (put) option with a lower strike price and selling a call (put) option with a higher strike price. This strategy is used when the investor expects a moderate rise in the price of the underlying asset.";
        } else if (index == 7) {
            // Calendar
            return
                "The Calendar Spread is an options strategy that involves buying and selling two options of the same type (calls or puts) with the same strike price but different widths. This strategy is used when the investor expects the underlying asset to increase in volatility.";
        } else if (index == 8) {
            // Covered Position
            return
                "A Covered Position involves selling a call (put) option while simultaneously owning (selling) the underlying asset. This strategy is used to generate income from the option premium while limiting downside (upside) risk.";
        } else if (index == 9) {
            // ZEBRA
            return
                "The ZEBRA (Zero Extrinsic Back Ratio) is a stock replacement options strategy that replicates long stock ownership with an embedded stop-loss. The ZEBRA has the advantage of not paying any extrinsic value for the protective feature.";
        } else if (index == 10) {
            // Bear Spread
            return
                "A Bear Spread is an options strategy that involves buying a call (put) option with a higher strike price and selling a call (put) option with a lower strike price. This strategy is used when the investor expects a moderate decline in the price of the underlying asset.";
        } else if (index == 11) {
            // BATS
            return
                "The BATS strategy combines short put and call ratio spreads. The strategy profits from the underlying asset trading within a defined range, while allowing for potential profit enhancement through more granular position adjustments.";
        } else if (index == 12) {
            // Strangle
            return
                "The Strangle involves buying or selling a call and a put option with the same expiration date and different strike prices. The call strike is above, and the put strike is below the current market price. Selling a strangle profits if the underlying asset's price remains relatively stable until expiration.";
        } else if (index == 13) {
            // Big Lizard
            return
                "The Big Lizard is a defined risk, neutral to slightly bullish options strategy that combines a short straddle and a long call option. This strategy has no upside risk and profits if the underlying asset remains within a specific range, with a slightly bullish bias.";
        } else if (index == 14) {
            // Ratio Spread
            return
                "The Ratio Spread is an options strategy that involves buying a certain number of options and simultaneously selling a different number of options of the same type (calls or puts). This strategy is used to limit risk while potentially profiting from moderate price moves.";
        } else if (index == 15) {
            // ZEEHBS
            return
                "The ZEEHBS (Zero Extrinsic Hedged Back Spread) is an options strategy that combines two ZEBRAs with a synthetic short position to hedge the overall trade. The ZEEHBS strategy capitalizes on the upside of a ZEBRA while hedging the position against potential losses using the synthetic short.";
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
            maxWidth = 175;
        } else if (rarity < 6) {
            maxWidth = 164;
        } else if (rarity < 9) {
            maxWidth = 145;
        } else if (rarity < 12) {
            maxWidth = 145;
        } else if (rarity < 15) {
            maxWidth = 145;
        } else if (rarity < 18) {
            maxWidth = 140;
        } else if (rarity < 19) {
            maxWidth = 140;
        } else if (rarity < 20) {
            maxWidth = 145;
        } else if (rarity < 21) {
            maxWidth = 145;
        } else if (rarity < 22) {
            maxWidth = 145;
        } else if (rarity < 23) {
            maxWidth = 164;
        } else if (rarity >= 23) {
            maxWidth = 175;
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
}
