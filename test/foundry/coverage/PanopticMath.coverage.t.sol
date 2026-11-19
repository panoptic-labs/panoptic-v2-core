// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Errors} from "@libraries/Errors.sol";
import {Constants} from "@libraries/Constants.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {TokenId} from "@types/TokenId.sol";
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";

/// @dev External entry point, so that the revert inside the library can be expected.
contract PanopticMathRevertHarness {
    function getChunkKey(
        int24 tickLower,
        int24 tickUpper,
        int24 tickSpacing,
        uint256 tokenType
    ) external pure returns (bytes32) {
        return PanopticMath.getChunkKey(tickLower, tickUpper, tickSpacing, tokenType);
    }
}

/// @notice Fills the coverage gaps left in `contracts/libraries/PanopticMath.sol` by the rest of the suite:
/// - `getChunkKey` from ticks, for a chunk too wide to encode
/// - both `convert1to0RoundingUp` overloads in the reduced-precision regime above tick 443636
/// - `getTotalLoanAmounts`, which had no tests
contract PanopticMathCoverageTest is Test {
    /// @dev First sqrt price handled by the reduced-precision branch.
    uint160 internal constant HIGH_PRICE_THRESHOLD = type(uint128).max;
    /// @dev sqrt price 2**128, i.e. a price of exactly 2**64 token1 per token0.
    uint160 internal constant SQRT_PRICE_2_64 = 2 ** 128;

    uint64 internal constant POOL_ID = 1 + (uint64(10) << 48);

    PanopticMathRevertHarness internal harness;

    function setUp() public {
        harness = new PanopticMathRevertHarness();
    }

    /*//////////////////////////////////////////////////////////////
                           getChunkKey FROM TICKS
    //////////////////////////////////////////////////////////////*/

    function test_getChunkKey_revertsWhenWidthDoesNotFit(int24 tickSpacing, int24 extra) public {
        // the width field of a TokenId leg is 12 bits wide
        tickSpacing = int24(bound(tickSpacing, 1, 200));
        extra = int24(bound(extra, 0, 100));
        int24 tickUpper = tickSpacing * (4096 + extra);

        vm.expectRevert(Errors.InvalidTickBound.selector);
        harness.getChunkKey(0, tickUpper, tickSpacing, 0);
    }

    function test_getChunkKey_widestEncodableChunk() public {
        // width 4095 is the last one accepted
        harness.getChunkKey(-20470, 20480, 10, 0);

        vm.expectRevert(Errors.InvalidTickBound.selector);
        harness.getChunkKey(-20480, 20480, 10, 0);
    }

    function test_getChunkKey_matchesTokenIdOverload(
        int24 strike,
        int24 width,
        int24 tickSpacing,
        uint256 tokenType
    ) public view {
        tickSpacing = int24(bound(tickSpacing, 1, 200));
        width = int24(bound(width, 1, 4095));
        strike = int24(bound(strike, -400_000, 400_000));
        tokenType = bound(tokenType, 0, 1);

        (int24 rangeDown, int24 rangeUp) = PanopticMath.getRangesFromStrike(width, tickSpacing);
        TokenId tokenId = TokenId.wrap(0).addLeg(0, 1, 0, 0, tokenType, 0, strike, width);

        // the key rebuilt from a leg's tick range is the key of the leg itself
        assertEq(
            harness.getChunkKey(strike - rangeDown, strike + rangeUp, tickSpacing, tokenType),
            PanopticMath.getChunkKey(tokenId, 0)
        );
    }

    function test_getChunkKey_distinguishesTokenTypes() public view {
        assertNotEq(harness.getChunkKey(990, 1010, 10, 0), harness.getChunkKey(990, 1010, 10, 1));
    }

    /*//////////////////////////////////////////////////////////////
               convert1to0RoundingUp ABOVE TICK 443636
    //////////////////////////////////////////////////////////////*/

    function test_convert1to0RoundingUp_highPrice_literals() public pure {
        // at a price of 2**64 token1 per token0, any non-zero amount up to 2**64 costs one token0
        assertEq(PanopticMath.convert1to0RoundingUp(uint256(0), SQRT_PRICE_2_64), 0, "zero");
        assertEq(PanopticMath.convert1to0RoundingUp(uint256(1), SQRT_PRICE_2_64), 1, "dust");
        assertEq(PanopticMath.convert1to0RoundingUp(uint256(2 ** 64), SQRT_PRICE_2_64), 1, "exact");
        assertEq(
            PanopticMath.convert1to0RoundingUp(uint256(2 ** 64 + 1), SQRT_PRICE_2_64),
            2,
            "over"
        );
        assertEq(
            PanopticMath.convert1to0RoundingUp(uint256(5 * 2 ** 64), SQRT_PRICE_2_64),
            5,
            "multiple"
        );
    }

    function test_convert1to0RoundingUp_highPrice_isCeilingOfRoundDown(
        uint128 amount,
        uint160 sqrtPriceX96
    ) public pure {
        sqrtPriceX96 = uint160(
            bound(sqrtPriceX96, HIGH_PRICE_THRESHOLD, Constants.MAX_POOL_SQRT_RATIO)
        );

        uint256 down = PanopticMath.convert1to0(uint256(amount), sqrtPriceX96);
        uint256 up = PanopticMath.convert1to0RoundingUp(uint256(amount), sqrtPriceX96);

        assertGe(up, down, "not below the floor");
        assertLe(up, down + 1, "at most one above the floor");
        // rounding up always buys back at least the original amount
        assertGe(PanopticMath.convert0to1(up, sqrtPriceX96), amount, "covers the amount");
    }

    function test_convert1to0RoundingUp_continuousAcrossThePrecisionSwitch(
        uint128 amount
    ) public pure {
        // one unit either side of the switch: the two formulas agree to within one unit
        uint256 below = PanopticMath.convert1to0RoundingUp(
            uint256(amount),
            HIGH_PRICE_THRESHOLD - 1
        );
        uint256 above = PanopticMath.convert1to0RoundingUp(uint256(amount), HIGH_PRICE_THRESHOLD);

        assertApproxEqAbs(below, above, 1);
    }

    function test_convert1to0RoundingUpSigned_highPrice_literals() public pure {
        assertEq(PanopticMath.convert1to0RoundingUp(int256(0), SQRT_PRICE_2_64), 0, "zero");
        assertEq(PanopticMath.convert1to0RoundingUp(int256(1), SQRT_PRICE_2_64), 1, "dust");
        assertEq(
            PanopticMath.convert1to0RoundingUp(int256(-1), SQRT_PRICE_2_64),
            -1,
            "negative dust"
        );
        assertEq(
            PanopticMath.convert1to0RoundingUp(int256(2 ** 64 + 1), SQRT_PRICE_2_64),
            2,
            "over"
        );
        assertEq(
            PanopticMath.convert1to0RoundingUp(-int256(2 ** 64 + 1), SQRT_PRICE_2_64),
            -2,
            "negative over"
        );
    }

    function test_convert1to0RoundingUpSigned_highPrice_roundsMagnitudeUp(
        int128 amount,
        uint160 sqrtPriceX96
    ) public pure {
        sqrtPriceX96 = uint160(
            bound(sqrtPriceX96, HIGH_PRICE_THRESHOLD, Constants.MAX_POOL_SQRT_RATIO)
        );
        uint256 magnitude = amount < 0 ? uint256(-int256(amount)) : uint256(int256(amount));

        int256 converted = PanopticMath.convert1to0RoundingUp(int256(amount), sqrtPriceX96);
        uint256 unsignedConverted = PanopticMath.convert1to0RoundingUp(magnitude, sqrtPriceX96);

        // same magnitude as the unsigned overload, sign carried over: negative amounts round away from zero
        assertEq(converted, amount < 0 ? -int256(unsignedConverted) : int256(unsignedConverted));
        assertEq(
            PanopticMath.convert1to0RoundingUp(-int256(amount), sqrtPriceX96),
            -converted,
            "odd function"
        );
    }

    /*//////////////////////////////////////////////////////////////
                          getTotalLoanAmounts
    //////////////////////////////////////////////////////////////*/

    function _balance(uint128 positionSize) internal pure returns (PositionBalance) {
        return PositionBalanceLibrary.storeBalanceData(positionSize, 0, 0, 0, 0, false);
    }

    /// @dev A leg with ratio 1 and asset 0, so a width-0 leg of size `s` on token0 is worth exactly `s`.
    function _leg(
        TokenId tokenId,
        uint256 legIndex,
        uint256 isLong,
        uint256 tokenType,
        int24 strike,
        int24 width
    ) internal pure returns (TokenId) {
        return tokenId.addLeg(legIndex, 1, 0, isLong, tokenType, legIndex, strike, width);
    }

    function _base() internal pure returns (TokenId) {
        return TokenId.wrap(0).addPoolId(POOL_ID);
    }

    function _single(
        TokenId tokenId,
        uint128 positionSize
    ) internal pure returns (PositionBalance[] memory balances, TokenId[] memory ids) {
        balances = new PositionBalance[](1);
        ids = new TokenId[](1);
        balances[0] = _balance(positionSize);
        ids[0] = tokenId;
    }

    function test_getTotalLoanAmounts_emptyList() public pure {
        LeftRightUnsigned loans = PanopticMath.getTotalLoanAmounts(
            new PositionBalance[](0),
            new TokenId[](0)
        );

        assertEq(LeftRightUnsigned.unwrap(loans), 0);
    }

    function test_getTotalLoanAmounts_token0Loan(uint64 positionSize) public pure {
        // width 0 and short: a loan of token0, sized in token0 since asset = 0
        TokenId loan = _leg(_base(), 0, 0, 0, 0, 0);
        (PositionBalance[] memory balances, TokenId[] memory ids) = _single(loan, positionSize);

        LeftRightUnsigned loans = PanopticMath.getTotalLoanAmounts(balances, ids);

        assertEq(loans.rightSlot(), positionSize, "token0 loan is the position size");
        assertEq(loans.leftSlot(), 0, "no token1 loan");
    }

    function test_getTotalLoanAmounts_token1LoanAtParity(uint64 positionSize) public pure {
        // a token1 loan struck at tick 0 (price 1), sized in token0: worth the size in token1, to within rounding
        TokenId loan = _leg(_base(), 0, 0, 1, 0, 0);
        (PositionBalance[] memory balances, TokenId[] memory ids) = _single(loan, positionSize);

        LeftRightUnsigned loans = PanopticMath.getTotalLoanAmounts(balances, ids);

        assertEq(loans.rightSlot(), 0, "no token0 loan");
        assertApproxEqRel(loans.leftSlot(), positionSize, 0.001e18, "token1 loan at parity");
        assertGe(loans.leftSlot(), (uint256(positionSize) * 999) / 1000, "not under-counted");
    }

    function test_getTotalLoanAmounts_matchesAmountsMoved(
        uint64 positionSize,
        int24 strike,
        uint256 tokenType
    ) public pure {
        strike = int24(bound(strike, -100_000, 100_000));
        tokenType = bound(tokenType, 0, 1);
        TokenId loan = _leg(_base(), 0, 0, tokenType, strike, 0);
        (PositionBalance[] memory balances, TokenId[] memory ids) = _single(loan, positionSize);

        LeftRightUnsigned loans = PanopticMath.getTotalLoanAmounts(balances, ids);
        LeftRightUnsigned moved = PanopticMath.getAmountsMoved(loan, positionSize, 0, false);

        if (tokenType == 0) {
            assertEq(loans.rightSlot(), moved.rightSlot(), "token0");
            assertEq(loans.leftSlot(), 0, "token1 slot empty");
        } else {
            assertEq(loans.leftSlot(), moved.leftSlot(), "token1");
            assertEq(loans.rightSlot(), 0, "token0 slot empty");
        }
    }

    function test_getTotalLoanAmounts_ignoresCreditsAndOptions(uint64 positionSize) public pure {
        // width 0 and long is a credit; width > 0 is an option, short or long: none of them is a loan
        TokenId tokenId = _leg(_base(), 0, 1, 0, 0, 0);
        tokenId = _leg(tokenId, 1, 0, 0, 100, 2);
        tokenId = _leg(tokenId, 2, 1, 1, 200, 2);
        (PositionBalance[] memory balances, TokenId[] memory ids) = _single(tokenId, positionSize);

        assertEq(LeftRightUnsigned.unwrap(PanopticMath.getTotalLoanAmounts(balances, ids)), 0);
        // the credit leg is what the credit counterpart picks up
        assertEq(
            PanopticMath.getTotalCreditAmounts(balances, ids).rightSlot(),
            positionSize,
            "counted as a credit instead"
        );
    }

    function test_getTotalLoanAmounts_sumsLoanLegsWithinAPosition(uint64 positionSize) public pure {
        // two token0 loans at different strikes, one token1 loan and one option leg
        TokenId tokenId = _leg(_base(), 0, 0, 0, 0, 0);
        tokenId = _leg(tokenId, 1, 0, 0, 500, 0);
        tokenId = _leg(tokenId, 2, 0, 1, 0, 0);
        tokenId = _leg(tokenId, 3, 0, 0, 1000, 2);
        (PositionBalance[] memory balances, TokenId[] memory ids) = _single(tokenId, positionSize);

        LeftRightUnsigned loans = PanopticMath.getTotalLoanAmounts(balances, ids);

        assertEq(loans.rightSlot(), uint256(positionSize) * 2, "two token0 loans");
        assertEq(
            loans.leftSlot(),
            PanopticMath.getAmountsMoved(tokenId, positionSize, 2, false).leftSlot(),
            "one token1 loan"
        );
    }

    function test_getTotalLoanAmounts_sumsAcrossPositions(uint64 sizeA, uint64 sizeB) public pure {
        PositionBalance[] memory balances = new PositionBalance[](3);
        TokenId[] memory ids = new TokenId[](3);
        // a token0 loan, an option-only position, and a second token0 loan of a different size
        (balances[0], ids[0]) = (_balance(sizeA), _leg(_base(), 0, 0, 0, 0, 0));
        (balances[1], ids[1]) = (_balance(sizeA), _leg(_base(), 0, 0, 0, 100, 2));
        (balances[2], ids[2]) = (_balance(sizeB), _leg(_base(), 0, 0, 0, 700, 0));

        LeftRightUnsigned loans = PanopticMath.getTotalLoanAmounts(balances, ids);

        assertEq(loans.rightSlot(), uint256(sizeA) + sizeB, "sum of both loans");
        assertEq(loans.leftSlot(), 0, "no token1 loan");
    }
}
