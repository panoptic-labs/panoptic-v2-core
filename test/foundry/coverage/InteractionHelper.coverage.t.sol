// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {InteractionHelper} from "@libraries/InteractionHelper.sol";

contract CovMetadataToken {
    string public symbol;
    uint8 public decimals;

    constructor(string memory _symbol, uint8 _decimals) {
        (symbol, decimals) = (_symbol, _decimals);
    }
}

/// @dev Has code but implements neither `symbol()` nor `decimals()`.
contract CovBareToken {

}

/// @dev `decimals()` reverts.
contract CovRevertingDecimalsToken {
    function decimals() external pure returns (uint8) {
        revert("no decimals");
    }
}

/// @notice Fills the coverage gaps left in `contracts/libraries/InteractionHelper.sol` by the rest of the suite:
/// - `computeName` for the token1 tracker
/// - `computeDecimals` for native ETH and for tokens without a usable `decimals()`
contract InteractionHelperCoverageTest is Test {
    address internal weth;
    address internal usdc;

    function setUp() public {
        weth = address(new CovMetadataToken("WETH", 18));
        usdc = address(new CovMetadataToken("USDC", 6));
    }

    /*//////////////////////////////////////////////////////////////
                              computeName
    //////////////////////////////////////////////////////////////*/

    function test_computeName_token0Tracker() public view {
        assertEq(
            InteractionHelper.computeName(usdc, weth, true, 500, "POPT-V2"),
            "POPT-V2 USDC LP on USDC/WETH 5bps"
        );
    }

    function test_computeName_token1Tracker() public view {
        assertEq(
            InteractionHelper.computeName(usdc, weth, false, 500, "POPT-V2"),
            "POPT-V2 WETH LP on USDC/WETH 5bps"
        );
    }

    function test_computeName_nativeAndSymbollessTokens() public {
        address bare = address(new CovBareToken());

        assertEq(
            InteractionHelper.computeName(address(0), bare, true, 3000, "P"),
            "P ETH LP on ETH/??? 30bps"
        );
        assertEq(
            InteractionHelper.computeName(address(0), bare, false, 1, "P"),
            "P ??? LP on ETH/??? 0.01bps"
        );
    }

    function test_computeSymbol() public {
        assertEq(InteractionHelper.computeSymbol(weth, "po"), "poWETH");
        assertEq(InteractionHelper.computeSymbol(address(0), "po"), "poETH");
        assertEq(InteractionHelper.computeSymbol(address(new CovBareToken()), "po"), "po???");
    }

    /*//////////////////////////////////////////////////////////////
                            computeDecimals
    //////////////////////////////////////////////////////////////*/

    function test_computeDecimals_nativeETHIs18() public view {
        assertEq(InteractionHelper.computeDecimals(address(0)), 18);
    }

    function test_computeDecimals_readsToken(uint8 decimals) public {
        address token = address(new CovMetadataToken("TKN", decimals));

        assertEq(InteractionHelper.computeDecimals(token), decimals);
    }

    function test_computeDecimals_zeroWhenTokenHasNoDecimals() public {
        assertEq(InteractionHelper.computeDecimals(address(new CovBareToken())), 0);
    }

    function test_computeDecimals_zeroWhenDecimalsReverts() public {
        assertEq(InteractionHelper.computeDecimals(address(new CovRevertingDecimalsToken())), 0);
    }
}
