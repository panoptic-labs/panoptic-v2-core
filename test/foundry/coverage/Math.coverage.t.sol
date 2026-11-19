// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Math} from "@libraries/Math.sol";

/// @dev External entry points, so that reverts inside the library can be expected.
contract MathRevertHarness {
    function mulDivCapped(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return Math.mulDivCapped(a, b, d);
    }

    function mulDivCappedPow(
        uint256 a,
        uint256 b,
        uint256 d,
        uint256 power
    ) external pure returns (uint256) {
        return Math.mulDivCapped(a, b, d, power);
    }

    function mulDivRoundingUp(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return Math.mulDivRoundingUp(a, b, d);
    }

    function mulDiv96RoundingUp(uint256 a, uint256 b) external pure returns (uint256) {
        return Math.mulDiv96RoundingUp(a, b);
    }

    function mulDiv128RoundingUp(uint256 a, uint256 b) external pure returns (uint256) {
        return Math.mulDiv128RoundingUp(a, b);
    }

    function mulDiv192RoundingUp(uint256 a, uint256 b) external pure returns (uint256) {
        return Math.mulDiv192RoundingUp(a, b);
    }

    function mulDivWad(uint256 a, uint256 b) external pure returns (uint256) {
        return Math.mulDivWad(a, b);
    }

    function mulDivWadRoundingUp(uint256 a, uint256 b) external pure returns (uint256) {
        return Math.mulDivWadRoundingUp(a, b);
    }
}

/// @notice Fills the coverage gaps left in `contracts/libraries/Math.sol` by the rest of the suite:
/// - `mulDivCapped`: the 512-bit path, the cap, and division by zero
/// - the overflow guard of every `...RoundingUp` variant: a floor of exactly `2^256 - 1` with a remainder
/// - `mulDivWad`: the 512-bit path and its overflow guard
/// - `wExp` for negative inputs, and `sTaylorCompounded`
contract MathCoverageTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant WAD = 1e18;

    MathRevertHarness internal harness;

    function setUp() public {
        harness = new MathRevertHarness();
    }

    /// @dev The upper 256 bits of the 512-bit product a * b.
    function _highWord(uint256 a, uint256 b) internal pure returns (uint256 high) {
        assembly {
            let mm := mulmod(a, b, not(0))
            let low := mul(a, b)
            high := sub(sub(mm, low), lt(mm, low))
        }
    }

    /*//////////////////////////////////////////////////////////////
                              mulDivCapped
    //////////////////////////////////////////////////////////////*/

    function test_mulDivCapped_smallProduct_matchesPlainDivision(
        uint128 a,
        uint128 b,
        uint256 d
    ) public pure {
        d = bound(d, 1, MAX);

        assertEq(Math.mulDivCapped(a, b, d), (uint256(a) * b) / d);
    }

    function test_mulDivCapped_smallProduct_revertsOnZeroDenominator(uint128 a, uint128 b) public {
        vm.expectRevert();
        harness.mulDivCapped(a, b, 0);
    }

    function test_mulDivCapped_largeProduct_matchesMulDivWhenResultFits(
        uint256 a,
        uint256 b,
        uint256 d
    ) public pure {
        // a product above 2**256 whose quotient still fits: d must exceed the high word of a * b
        a = bound(a, 2 ** 128, MAX);
        b = bound(b, 2 ** 128, MAX);
        uint256 high = _highWord(a, b);
        vm.assume(high < MAX);
        d = bound(d, high + 1, MAX);

        assertEq(Math.mulDivCapped(a, b, d), Math.mulDiv(a, b, d));
    }

    function test_mulDivCapped_largeProduct_literals() public pure {
        // (2**255 * 4) / 2 = 2**256: one past the cap
        assertEq(Math.mulDivCapped(2 ** 255, 4, 2), MAX, "capped");
        // (2**255 * 4) / 3 = floor(2**257 / 3): fits, 512-bit path with an odd denominator
        assertEq(Math.mulDivCapped(2 ** 255, 4, 3), (2 ** 257 - 2) / 3, "odd denominator");
        // (2**200 * 2**100) / 2**60 = 2**240: 512-bit path with a power-of-two denominator
        assertEq(Math.mulDivCapped(2 ** 200, 2 ** 100, 2 ** 60), 2 ** 240, "even denominator");
        // MAX * MAX / MAX = MAX exactly, not capped
        assertEq(Math.mulDivCapped(MAX, MAX, MAX), MAX, "exact maximum");
    }

    function test_mulDivCapped_largeProduct_capsWhenQuotientOverflows(
        uint256 a,
        uint256 b,
        uint256 d
    ) public pure {
        a = bound(a, 2 ** 128, MAX);
        b = bound(b, 2 ** 128, MAX);
        // any denominator at or below the high word of a * b gives a quotient of 2**256 or more
        uint256 high = _highWord(a, b);
        d = bound(d, 0, high);

        assertEq(Math.mulDivCapped(a, b, d), MAX);
    }

    function test_mulDivCapped_largeProduct_zeroDenominatorIsCappedNotReverted() public pure {
        // unlike the small-product case, a zero denominator falls under the cap here
        assertEq(Math.mulDivCapped(2 ** 200, 2 ** 200, 0), MAX);
    }

    function test_mulDivCappedPow_smallProduct_revertsOnZeroDenominator(
        uint128 a,
        uint128 b,
        uint256 power
    ) public {
        power = bound(power, 1, 255);

        vm.expectRevert();
        harness.mulDivCappedPow(a, b, 0, power);
    }

    function test_mulDivCappedPow_smallProduct_capsAtPower(
        uint128 a,
        uint128 b,
        uint256 d,
        uint256 power
    ) public pure {
        d = bound(d, 1, MAX);
        power = bound(power, 1, 255);
        uint256 exact = (uint256(a) * b) / d;
        uint256 cap = 2 ** power - 1;

        assertEq(Math.mulDivCapped(a, b, d, power), exact < cap ? exact : cap);
    }

    /*//////////////////////////////////////////////////////////////
                   ROUNDING UP AT THE TOP OF THE RANGE
    //////////////////////////////////////////////////////////////*/

    // For a shift s, (2**k - 1) * (2**k + 1) = 2**(2k) - 1 with 2k = 256 + s floors to 2**256 - 1 after
    // dividing by 2**s and leaves a remainder: rounding up would need 2**256.

    function test_mulDivRoundingUp_revertsWhenRoundingUpOverflows() public {
        vm.expectRevert();
        harness.mulDivRoundingUp(2 ** 176 - 1, 2 ** 176 + 1, 2 ** 96);
    }

    function test_mulDivRoundingUp_exactMaximumDoesNotRevert() public view {
        // (2**128 - 1) * (2**128 + 1) = 2**256 - 1: no remainder, nothing to round
        assertEq(harness.mulDivRoundingUp((2 ** 128 - 1) * 2 ** 96, 2 ** 128 + 1, 2 ** 96), MAX);
        assertEq(harness.mulDivRoundingUp(MAX, 7, 7), MAX);
    }

    function test_mulDiv96RoundingUp_revertsWhenRoundingUpOverflows() public {
        vm.expectRevert();
        harness.mulDiv96RoundingUp(2 ** 176 - 1, 2 ** 176 + 1);
    }

    function test_mulDiv96RoundingUp_exactMaximumDoesNotRevert() public view {
        assertEq(harness.mulDiv96RoundingUp((2 ** 128 - 1) * 2 ** 96, 2 ** 128 + 1), MAX);
    }

    function test_mulDiv128RoundingUp_revertsWhenRoundingUpOverflows() public {
        vm.expectRevert();
        harness.mulDiv128RoundingUp(2 ** 192 - 1, 2 ** 192 + 1);
    }

    function test_mulDiv128RoundingUp_exactMaximumDoesNotRevert() public view {
        assertEq(
            harness.mulDiv128RoundingUp((2 ** 128 - 1) * 2 ** 64, (2 ** 128 + 1) * 2 ** 64),
            MAX
        );
    }

    function test_mulDiv192RoundingUp_revertsWhenRoundingUpOverflows() public {
        vm.expectRevert();
        harness.mulDiv192RoundingUp(2 ** 224 - 1, 2 ** 224 + 1);
    }

    function test_mulDiv192RoundingUp_exactMaximumDoesNotRevert() public view {
        assertEq(
            harness.mulDiv192RoundingUp((2 ** 128 - 1) * 2 ** 96, (2 ** 128 + 1) * 2 ** 96),
            MAX
        );
    }

    function test_mulDivWadRoundingUp_revertsWhenRoundingUpOverflows() public {
        // a * b = (2**256 - 1) * 1e18 + 495113644278145969: the floor is 2**256 - 1 with a remainder
        uint256 a = 1e18 + 1;
        uint256 b = 115792089237316195307778895771371712545491088894268851493966495113644278145969;
        assertEq(harness.mulDivWad(a, b), MAX, "floor is the maximum");
        assertEq(mulmod(a, b, WAD), 495113644278145969, "with a remainder");

        vm.expectRevert();
        harness.mulDivWadRoundingUp(a, b);
    }

    function test_mulDivWadRoundingUp_exactMaximumDoesNotRevert() public view {
        assertEq(harness.mulDivWadRoundingUp(MAX, WAD), MAX);
    }

    /*//////////////////////////////////////////////////////////////
                                mulDivWad
    //////////////////////////////////////////////////////////////*/

    function test_mulDivWad_largeProduct_matchesMulDiv(uint256 a, uint256 b) public pure {
        // a product above 2**256 whose quotient by 1e18 still fits
        a = bound(a, 2 ** 128, 2 ** 157);
        b = bound(b, 2 ** 128, 2 ** 157);

        assertEq(Math.mulDivWad(a, b), Math.mulDiv(a, b, WAD), "floor");
        assertEq(Math.mulDivWadRoundingUp(a, b), Math.mulDivRoundingUp(a, b, WAD), "ceiling");
    }

    function test_mulDivWad_largeProduct_literals() public pure {
        // 1e18 scales out exactly
        assertEq(Math.mulDivWad(2 ** 190 * WAD, 2 ** 30), 2 ** 220, "exact");
        assertEq(Math.mulDivWad(MAX, WAD), MAX, "identity at the maximum");
        // one unit short of a multiple: floor drops it, ceiling restores it
        assertEq(Math.mulDivWad(2 ** 190 * WAD - 1, 2 ** 30), 2 ** 220 - 1, "floor");
        assertEq(Math.mulDivWadRoundingUp(2 ** 190 * WAD - 1, 2 ** 30), 2 ** 220, "ceiling");
    }

    function test_mulDivWad_revertsWhenQuotientOverflows(uint256 a, uint256 b) public {
        // a * b >= 2**256 * 1e18
        a = bound(a, 2 ** 160, MAX);
        b = bound(b, 2 ** 160, MAX);

        vm.expectRevert();
        harness.mulDivWad(a, b);
    }

    function test_mulDivWad_revertsJustPastTheMaximum() public {
        // MAX * 1e18 fits exactly; one more unit of a does not
        assertEq(harness.mulDivWad(MAX, WAD), MAX);

        vm.expectRevert();
        harness.mulDivWad(MAX, WAD + 1);
    }

    /*//////////////////////////////////////////////////////////////
                                  wExp
    //////////////////////////////////////////////////////////////*/

    function test_wExp_negativeLiterals() public pure {
        // e^-1 = 0.367879441171442321..., second-order approximation
        assertApproxEqRel(Math.wExp(-1 ether), 367879441171442321, 0.01e18, "e^-1");
        // e^-ln2 = 1/2: the reduced argument is zero, so the result is exact up to the ln2 constant
        assertApproxEqAbs(Math.wExp(-Math.LN_2_INT), 0.5 ether, 1, "e^-ln2");
        assertApproxEqAbs(Math.wExp(-10 * Math.LN_2_INT), 1 ether / 1024, 1, "e^-10ln2");
        // e^-0.1 = 0.904837418035959573...
        assertApproxEqRel(Math.wExp(-0.1 ether), 904837418035959573, 0.001e18, "e^-0.1");
    }

    function test_wExp_boundaries() public pure {
        assertEq(Math.wExp(0), 1 ether, "e^0");
        assertEq(Math.wExp(Math.LN_WEI_INT - 1), 0, "below ln(1e-18) rounds to zero");
        assertGt(Math.wExp(Math.LN_WEI_INT + 1 ether), 0, "just above it is positive");
        assertEq(Math.wExp(Math.WEXP_UPPER_BOUND), Math.WEXP_UPPER_VALUE, "upper clip");
        assertEq(Math.wExp(type(int256).max), Math.WEXP_UPPER_VALUE, "upper clip, far above");
        assertEq(Math.wExp(type(int256).min), 0, "lower clip, far below");
    }

    function test_wExp_negativeIsBelowOneAndMonotonic(int256 x, int256 dx) public pure {
        x = bound(x, Math.LN_WEI_INT, -1);
        dx = bound(dx, 0, -x);

        int256 lower = Math.wExp(x);
        int256 higher = Math.wExp(x + dx);

        assertLe(lower, 1 ether, "at most one");
        assertGe(lower, 0, "never negative");
        // the piecewise approximation is monotonic to within its error at the segment joins
        assertLe(lower, higher + higher / 50 + 1, "increasing");
    }

    function test_wExp_reciprocal(int256 x) public pure {
        // e^x * e^-x = 1, within the approximation error of each side
        x = bound(x, 0, 20 ether);

        int256 product = (Math.wExp(x) * Math.wExp(-x)) / 1 ether;

        assertApproxEqRel(product, 1 ether, 0.03e18);
    }

    /*//////////////////////////////////////////////////////////////
                           sTaylorCompounded
    //////////////////////////////////////////////////////////////*/

    function test_sTaylorCompounded_literals() public pure {
        // x = s: s * (1 + 1 + 1/2 + 1/6 + 1/24), each term floored
        assertEq(Math.sTaylorCompounded(1e18, 1e18), 2708333333333333332, "x = s = 1e18");
        // x = 0: only the zeroth term
        assertEq(Math.sTaylorCompounded(0, 1e18), 1e18, "x = 0");
        // a 1% rate at 1e18 scale: 1 + 0.01 + 0.00005 + 1.6667e-7 + 4.17e-10, the last two terms floored
        assertEq(Math.sTaylorCompounded(0.01e18, 1e18), 1010050167083333332, "1%");
        // the same series at a different scale
        assertEq(Math.sTaylorCompounded(100, 100), 270, "x = s = 100");
    }

    function test_sTaylorCompounded_extendsWTaylorCompoundedByOneTerm(
        uint256 x,
        uint256 n
    ) public pure {
        x = bound(x, 0, 1e12);
        n = bound(n, 0, 1e9);
        uint256 first = x * n;

        uint256 second = Math.mulDiv(first, first, 2 * WAD);
        uint256 third = Math.mulDiv(second, first, 3 * WAD);
        uint256 fourth = Math.mulDiv(third, first, 4 * WAD);

        // e^(nx) to fourth order is 1 + (e^(nx) - 1 to third order) + the fourth-order term
        assertEq(Math.sTaylorCompounded(first, WAD), WAD + Math.wTaylorCompounded(x, n) + fourth);
    }

    function test_sTaylorCompounded_isAtLeastLinear(uint256 x, uint256 s) public pure {
        s = bound(s, 1, 1e30);
        x = bound(x, 0, s * 10);

        assertGe(Math.sTaylorCompounded(x, s), s + x);
    }

    function test_sTaylorCompounded_revertsOnZeroScale() public {
        vm.expectRevert();
        this.sTaylorExternal(1, 0);
    }

    function sTaylorExternal(uint256 x, uint256 s) external pure returns (uint256) {
        return Math.sTaylorCompounded(x, s);
    }
}
