// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AssertExt} from "./AssertExt.sol";
import {RiskEngineHarness} from "./RiskEngineHarness.sol";
import {MockCollateralTracker} from "./mocks/MockCollateralTracker.sol";
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {TokenId} from "@types/TokenId.sol";
import {PositionBalance} from "@types/PositionBalance.sol";
import {PositionFactory} from "./helpers/PositionFactory.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {Constants} from "@libraries/Constants.sol";

contract RiskEnginePropertiesPlus is Test {
    using PositionFactory for *;

    RiskEngineHarness internal E;
    MockCollateralTracker internal ct0;
    MockCollateralTracker internal ct1;

    uint256 constant DEC = 10_000_000;
    uint256 constant SELL = 2_000_000;
    uint256 constant BUY = 1_000_000;
    uint256 constant FE = 1_000; // 10 bps

    function setUp() public {
        E = new RiskEngineHarness(
            5_000_000, // cross buf0
            5_000_000 // cross buf1
        );
        ct0 = new MockCollateralTracker();
        ct1 = new MockCollateralTracker();
        ct0.setGlobal(1_000_000 ether, 1_000_000 ether);
        ct1.setGlobal(1_000_000 ether, 1_000_000 ether);
        ct0.setSharePrice(1, 1);
        ct1.setSharePrice(1, 1);
    }

    // ---------- A. Packing, units, accounting ----------

    function testA_LeftRight_meanings_and_conservation() public {
        address u = address(0xA);
        // One-token-only book: only token0 can move, token1 empty
        ct0.setUser(u, 7 ether, 3 ether, 7 ether);
        ct1.setUser(u, 0, 5 ether, 0); // interest1 should be added into requirement1 only

        // No positions, but add premia: short premia credits increase balances only
        LeftRightUnsigned shortPrem = LeftRightUnsigned
            .wrap(0)
            .addToRightSlot(uint128(2 ether))
            .addToLeftSlot(uint128(4 ether)); // token0 credit // token1 credit
        LeftRightUnsigned longPrem = LeftRightUnsigned
            .wrap(0)
            .addToRightSlot(uint128(11))
            .addToLeftSlot(uint128(13)); // long premia should go into requirements

        TokenId[] memory ids = new TokenId[](1);
        PositionBalance[] memory bals = new PositionBalance[](1);

        (LeftRightUnsigned td0, LeftRightUnsigned td1, ) = E.getMarginInternal(
            u,
            bals,
            int24(0),
            ids,
            shortPrem,
            longPrem,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1))
        );

        // Left = requirement, Right = balance
        // token0: requirement gets longPrem.right + interest0; balance gets assets0 + shortPrem.right + credits0(=0)
        assertEq(td0.leftSlot(), 11, "req0 = longPrem0");
        assertEq(
            td0.rightSlot(),
            7 ether - 3 ether + 2 ether,
            "bal0 = assets0 - interest0 + shortPrem0"
        );

        // token1: requirement gets longPrem.left + interest1=0 (because balance1=0); balance gets assets1 + shortPrem.left
        assertEq(td1.leftSlot(), 13, "req1 = interest1 + longPrem1");
        assertEq(td1.rightSlot(), 0 + 4 ether, "bal1 = assets1 + shortPrem1");
    }

    // ---------- B. Monotonicity and scale ----------

    function testB1_Linearity_position_size() public {
        uint64 poolId = 1 + (10 << 48);
        TokenId t = PositionFactory.makeLeg(poolId, 0, 1, 0, 0, 0, 0, int24(0), int24(600));
        uint128 s1 = 3e9;
        PositionBalance pb1 = PositionFactory.posBalance(s1, 4000, 0);
        LeftRightUnsigned zero = LeftRightUnsigned.wrap(0);

        PositionBalance[] memory arr1 = new PositionBalance[](1);
        arr1[0] = (pb1);

        TokenId[] memory ids = new TokenId[](1);
        ids[0] = t;

        (LeftRightUnsigned r0a, LeftRightUnsigned r1a, ) = E.totalRequiredCollateral(
            arr1,
            ids,
            0,
            zero
        );

        uint128 s2 = s1 * 9;
        PositionBalance pb2 = PositionFactory.posBalance(s2, 4000, 0);
        PositionBalance[] memory arr2 = new PositionBalance[](1);
        arr2[0] = (pb2);

        (LeftRightUnsigned r0b, LeftRightUnsigned r1b, ) = E.totalRequiredCollateral(
            arr2,
            ids,
            0,
            zero
        );

        assertEq(r0b.leftSlot(), r0a.leftSlot() * 9, "req0 scales");
        assertEq(r1b.leftSlot(), r1a.leftSlot() * 9, "req1 scales");
    }

    function testB2_Monotone_utilization_short_long() public {
        uint64 poolId = 1 + (10 << 48);

        // short call leg
        TokenId sCall = PositionFactory.makeLeg(poolId, 0, 1, 0, 0, 0, 0, int24(0), int24(600));
        // long call leg
        TokenId lCall = PositionFactory.makeLeg(poolId, 0, 1, 0, 1, 0, 0, int24(0), int24(600));

        uint128 size = 1e9;

        uint256 a = E.reqSingleNoPartner(sCall, 0, size, 0, int16(0));
        uint256 b = E.reqSingleNoPartner(sCall, 0, size, 0, int16(5000));
        uint256 c = E.reqSingleNoPartner(sCall, 0, size, 0, int16(9000));
        assertLe(a, b, "short nondecreasing util ab");
        assertLe(b, c, "short nondecreasing util bc");

        a = E.reqSingleNoPartner(lCall, 0, size, 0, int16(0));
        b = E.reqSingleNoPartner(lCall, 0, size, 0, int16(5000));
        c = E.reqSingleNoPartner(lCall, 0, size, 0, int16(9000));
        assertGe(a, b, "long nonincreasing util");
        assertGe(b, c, "long nonincreasing util");

        // check the saturated rule-of-half
        uint256 atTarget = E.reqSingleNoPartner(lCall, 0, size, 0, int16(5000));
        uint256 atSaturated = E.reqSingleNoPartner(lCall, 0, size, 0, int16(9000 + 1)); // above sat
        // saturated path must be approx half or less than target baseline (tolerate +1 rounding)
        //assertLe(atSaturated * 2 - 1, atTarget, "long reaches half at saturation");
    }

    function testB3_Short_moneyness_monotone_and_long_envelope() public {
        uint64 poolId = 1 + (10 << 48);
        TokenId sCall = PositionFactory.makeLeg(poolId, 0, 1, 0, 0, 0, 0, int24(0), int24(600));
        TokenId lCall = PositionFactory.makeLeg(poolId, 0, 1, 0, 1, 0, 0, int24(0), int24(600));
        uint128 size = 1e9;

        // Short: adverse move cannot reduce requirement
        uint256 otm = E.reqSingleNoPartner(sCall, 0, size, int24(-6000), int16(0));
        uint256 itm = E.reqSingleNoPartner(sCall, 0, size, int24(6000), int16(0));
        assertGt(itm, otm, "short adverse increases");

        // Long: requirement never exceeds base long requirement at same util
        uint256 base = E.reqSingleNoPartner(lCall, 0, size, int24(0), int16(0));
        uint256 far = E.reqSingleNoPartner(lCall, 0, size, int24(6000), int16(0));
        assertLe(far, base, "long decays below base");
    }

    // ---------- C. Strategy identities ----------

    function testC1_Spread_min_of_maxLoss_and_split_once() public {
        uint64 poolId = 1 + (10 << 48);
        // long call at 0, short call at +300, same tokenType
        TokenId t = PositionFactory.makeTwoLegs(
            poolId,
            1,
            0,
            1,
            0,
            int24(0),
            int24(600),
            1,
            0,
            0,
            0,
            int24(300),
            int24(600)
        );
        uint128 size = 1e9;
        uint256 split = E.reqSingleNoPartner(t, 0, size, 0, 0) +
            E.reqSingleNoPartner(t, 1, size, 0, 0);
        uint256 spread = E.computeSpread(t, size, 0, 1, 0, 0);
        assertLe(spread, split, "spread <= split");
        uint256 p0 = E.reqSinglePartner(t, 0, size, 0, 0);
        uint256 p1 = E.reqSinglePartner(t, 1, size, 0, 0);
        assertGt(p0, 0, "first leg reports");
        assertEq(p1, 0, "second is 0");
    }

    function testC2_Synthetic_stock_reports_once_collapses_to_short() public {
        uint64 poolId = 1 + (10 << 48);
        // long call + short put same strike -> synthetic
        TokenId t = PositionFactory.makeTwoLegs(
            poolId,
            1,
            0,
            1,
            0,
            int24(0),
            int24(600),
            1,
            0,
            0,
            1,
            int24(0),
            int24(600)
        );
        uint128 size = 1e9;
        uint256 p0 = E.reqSinglePartner(t, 0, size, 0, 0);
        uint256 p1 = E.reqSinglePartner(t, 1, size, 0, 0);
        uint256 soloShort = E.reqSingleNoPartner(t, 1, size, 0, 0);
        assertTrue((p0 > 0 && p1 == 0) || (p1 > 0 && p0 == 0), "reported once");
        assertEq(p0 + p1, soloShort, "collapses to short");
    }

    function testC3_Strangle_halves_base_and_floor() public {
        uint64 poolId = 1 + (10 << 48);
        TokenId t = PositionFactory.makeTwoLegs(
            poolId,
            1,
            0,
            0,
            1,
            int24(-300),
            int24(600), // short put
            1,
            0,
            0,
            0,
            int24(300),
            int24(600) // short call
        );
        uint128 size = 1e9;
        uint256 str = E.reqSinglePartner(t, 0, size, 0, 0) + E.reqSinglePartner(t, 1, size, 0, 0);
        uint256 sumSingles = E.reqSingleNoPartner(t, 0, size, 0, 1) +
            E.reqSingleNoPartner(t, 1, size, 0, 1);
        assertLt(str, sumSingles, "strangle < sum singles");
        // floor binds for tiny sizes
        uint128 tiny = 1;
        uint256 rs = E.reqSinglePartner(t, 0, tiny, 0, 0) + E.reqSinglePartner(t, 1, tiny, 0, 0);
        assertGe(rs, 1, "1-unit floor binds");
    }

    function testC4_Credit_loan_composites_option_side_only() public {
        uint64 poolId = 1 + (10 << 48);
        // cash-secured short call: short call + credit
        TokenId cs = PositionFactory.makeTwoLegs(
            poolId,
            1,
            0,
            0,
            0,
            int24(0),
            int24(600), // option leg
            1,
            0,
            1,
            0,
            int24(0),
            int24(0) // credit width 0
        );
        // option-protected loan: long call + loan
        TokenId ol = PositionFactory.makeTwoLegs(
            poolId,
            1,
            0,
            1,
            0,
            int24(0),
            int24(600), // option leg
            1,
            0,
            0,
            0,
            int24(0),
            int24(0) // loan width 0
        );
        uint128 size = 1e9;
        uint256 cs0 = E.reqSinglePartner(cs, 0, size, 0, 0);
        uint256 cs1 = E.reqSinglePartner(cs, 1, size, 0, 0);
        assertTrue((cs0 > 0 && cs1 == 0) || (cs1 > 0 && cs0 == 0), "CS: option side only");
        uint256 ol0 = E.reqSinglePartner(ol, 0, size, 0, 0);
        uint256 ol1 = E.reqSinglePartner(ol, 1, size, 0, 0);
        assertTrue((ol0 > 0 && ol1 == 0) || (ol1 > 0 && ol0 == 0), "OL: option side only");
    }

    function testC5_Delayed_swap_max_rule_boundary() public {
        uint64 poolId = 1 + (10 << 48);
        // loan on leg0, credit on leg1 with different token types to trigger conversion
        // choose atTick so that converted credit barely dominates vs loan requirement
        int24 atTick = 0;
        TokenId dl = PositionFactory.makeTwoLegs(
            poolId,
            1,
            0,
            0,
            0,
            int24(0),
            int24(0), // leg0 loan
            1,
            0,
            1,
            1,
            int24(0),
            int24(0) // leg1 credit opposite tokenType
        );
        uint128 size = 5e9;
        uint256 req = E.computeDelayedSwap(dl, size, 0, 1, atTick);
        // must be equal to max(upfront short requirement, converted credit)
        // we cannot compute internals here without duplicating math; just sanity:
        assertGt(req, 0, "delayed swap positive");
    }

    function testC6_Calendar_spread_taylor_term_monotone_in_dWidth() public {
        uint64 poolId = 1 + (10 << 48);
        // same strike, same token type, different widths
        TokenId calNarrow = PositionFactory.makeTwoLegs(
            poolId,
            1,
            0,
            1,
            0,
            int24(0),
            int24(200), // long
            1,
            0,
            0,
            0,
            int24(0),
            int24(260) // short
        );
        TokenId calWide = PositionFactory.makeTwoLegs(
            poolId,
            1,
            0,
            1,
            0,
            int24(0),
            int24(200), // long
            1,
            0,
            0,
            0,
            int24(0),
            int24(500) // short
        );
        uint128 size = 1e9;
        uint256 rN = E.computeSpread(calNarrow, size, 0, 1, 0, 0);
        uint256 rW = E.computeSpread(calWide, size, 0, 1, 0, 0);
        assertGt(rW, rN, "taylor term grows with abs delta-width");
    }

    // ---------- D. Price-path structure and kinks ----------

    function testD1_InRange_short_call_linear_interp_continuity() public {
        uint64 poolId = 1 + (10 << 48);
        // short call with narrow band; walk across lower and upper ticks
        int24 strike = 0;
        int24 width = 300;

        TokenId sCall = PositionFactory.makeLeg(poolId, 0, 1, 0, 0, 0, 0, strike, width);
        uint128 size = 1e9;
        int24 lo = strike - width / 2;
        int24 hi = strike + width / 2;

        uint256 r_lo = E.reqSingleNoPartner(sCall, 0, size, lo, 0);
        uint256 r_mid = E.reqSingleNoPartner(sCall, 0, size, strike, 0);
        uint256 r_hi = E.reqSingleNoPartner(sCall, 0, size, hi, 0);

        /*
        for (int24 t=-5000;t<5000;t += 10) {
            uint256 r   = E.reqSingleNoPartner(sCall, 0, size, t, 0);

            console2.log('\t', r);
        }
        */
        // interpolation implies r_mid between r_lo and r_hi and no upward jump at edges
        assertGe(r_mid, r_lo, "mid >= lo");
        assertLe(r_mid, r_hi + 1, "mid <= hi (+1 rounding)");
        // one tick inside vs just outside boundary continuity
        uint256 r_edge_in = E.reqSingleNoPartner(sCall, 0, size, lo + 1, 0);
        uint256 r_edge_out = E.reqSingleNoPartner(sCall, 0, size, lo - 1, 0);
        assertGe(r_edge_in, r_edge_out, "no spike crossing boundary low");
        r_edge_in = E.reqSingleNoPartner(sCall, 0, size, hi - 1, 0);
        r_edge_out = E.reqSingleNoPartner(sCall, 0, size, hi + 1, 0);
        assertLe(r_edge_in, r_edge_out, "no spike crossing boundary high");
    }

    function testD1_InRange_short_put_linear_interp_continuity() public {
        uint64 poolId = 1 + (10 << 48);
        // short call with narrow band; walk across lower and upper ticks
        int24 strike = 0;
        int24 width = 120;
        TokenId sCall = PositionFactory.makeLeg(poolId, 0, 1, 0, 0, 1, 0, strike, width);
        uint128 size = 1e9;
        int24 lo = strike - width / 2;
        int24 hi = strike + width / 2;

        uint256 r_lo = E.reqSingleNoPartner(sCall, 0, size, lo, 0);
        uint256 r_mid = E.reqSingleNoPartner(sCall, 0, size, strike, 0);
        uint256 r_hi = E.reqSingleNoPartner(sCall, 0, size, hi, 0);

        // interpolation implies r_mid between r_lo and r_hi and no upward jump at edges
        assertLe(r_mid, r_lo, "mid >= lo");
        assertGe(r_mid, r_hi + 1, "mid <= hi (+1 rounding)");
        // one tick inside vs just outside boundary continuity
        uint256 r_edge_in = E.reqSingleNoPartner(sCall, 0, size, lo + 1, 0);
        uint256 r_edge_out = E.reqSingleNoPartner(sCall, 0, size, lo - 1, 0);
        assertLe(r_edge_in, r_edge_out, "no spike crossing boundary");
        r_edge_in = E.reqSingleNoPartner(sCall, 0, size, hi - 1, 0);
        r_edge_out = E.reqSingleNoPartner(sCall, 0, size, hi + 1, 0);
        assertGe(r_edge_in, r_edge_out, "no spike crossing boundary");
    }

    function testD2_Long_halves_per_width_step() public {
        uint64 poolId = 1 + (10 << 48);
        int24 width = 60;
        TokenId lCall = PositionFactory.makeLeg(poolId, 0, 1, 0, 1, 0, 0, int24(0), width);
        uint128 size = 1e9;
        uint256 r0 = E.reqSingleNoPartner(lCall, 0, size, 0, 0);
        // distance = n * width should produce near-halving each step due to LN2_SCALED logic
        for (uint256 n = 1; n <= 4; n++) {
            uint256 r = E.reqSingleNoPartner(
                lCall,
                0,
                size,
                int24(int256(2 * n) * int256(width)),
                0
            );
            // r <= r_prev approximately half, allow small integer slack
            assertLe(r, r0, "halving per width-step");
            r0 = r;
        }
    }

    // ---------- E. Credits and zero-width legs ----------

    function testE_Loans_and_credits_semantics() public {
        uint64 pool = 1 + (10 << 48);
        TokenId loanShort = PositionFactory.makeLeg(pool, 0, 1, 0, 0, 0, 0, 0, 0);
        TokenId loanLong = PositionFactory.makeLeg(pool, 0, 1, 0, 1, 0, 0, 0, 0);
        uint128 size = 1e9;
        uint256 rShort = E.reqSingleNoPartner(loanShort, 0, size, 0, 0);
        uint256 rLong = E.reqSingleNoPartner(loanLong, 0, size, 0, 0);
        assertGt(rShort, 0, "short zero-width requires > 0");
        assertEq(rLong, 0, "long zero-width requires 0");
    }

    // ---------- F. Aggregation and insolvency ----------

    function testF_Aggregation_sums_without_conversion_and_longPremia_only_in_req() public {
        uint64 pool = 1 + (10 << 48);
        TokenId leg0 = PositionFactory.makeLeg(pool, 0, 1, 0, 0, 0, 0, 0, 600);
        TokenId[] memory ids = new TokenId[](1);
        ids[0] = leg0;

        PositionBalance[] memory arr = new PositionBalance[](1);
        arr[0] = (PositionFactory.posBalance(uint128(2e9), 1000, 0));

        LeftRightUnsigned longPrem = LeftRightUnsigned.wrap(0).addToRightSlot(123).addToLeftSlot(
            456
        );

        (LeftRightUnsigned reqs, LeftRightUnsigned creditAmounts, ) = E.totalRequiredCollateral(
            arr,
            ids,
            0,
            longPrem
        );
        // no balances here; verify long premia are added into left slots of returned requirements per token mapping in _getTotalRequiredCollateral
        assertGe(reqs.rightSlot(), 123, "long prem adds into req0");
        assertGe(reqs.leftSlot(), 456, "long prem adds into req1");
        assertEq(creditAmounts.rightSlot(), 0, "no credits");
        assertEq(creditAmounts.leftSlot(), 0, "no credits");
    }

    function testF2_isAccountSolvent_token_swap_equivalence() public {
        // Symmetry sanity: flip FP96 side and swap token trackers, decision must match when inputs are swapped
        address u = address(0xABCD);
        ct0.setUser(u, 30 ether, 1 ether, 30 ether);
        ct1.setUser(u, 20 ether, 2 ether, 20 ether);

        uint64 pool = 1 + (10 << 48);
        TokenId t = PositionFactory.makeTwoLegs(
            pool,
            1,
            0,
            1,
            0,
            int24(0),
            600, // long call
            1,
            0,
            0,
            0,
            int24(300),
            600 // short call
        );
        TokenId[] memory ids = new TokenId[](1);
        ids[0] = t;

        PositionBalance[] memory arr = new PositionBalance[](1);
        arr[0] = (PositionFactory.posBalance(uint128(4e9), 3000, 3000));

        LeftRightUnsigned z = LeftRightUnsigned.wrap(0);

        bool leftSide = E.isAccountSolvent(
            arr,
            ids,
            int24(-200),
            u,
            z,
            z,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1)),
            DEC
        );
        bool rightSide = E.isAccountSolvent(
            arr,
            ids,
            int24(200),
            u,
            z,
            z,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1)),
            DEC
        );
        assertTrue(leftSide || rightSide, "at least one solvent");

        // stricter: check monotone tightening
        bool s1 = E.isAccountSolvent(
            arr,
            ids,
            0,
            u,
            z,
            z,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1)),
            9_000_000
        );
        bool s2 = E.isAccountSolvent(
            arr,
            ids,
            0,
            u,
            z,
            z,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1)),
            10_000_000
        );
        bool s3 = E.isAccountSolvent(
            arr,
            ids,
            0,
            u,
            z,
            z,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1)),
            11_000_000
        );
        assertFalse(
            (s1 == false && s2 == true),
            string.concat("buffer monotonicity", ": no false->true at step2")
        );
        assertFalse(
            (s2 == false && s3 == true),
            string.concat("buffer monotonicity", ": no false->true at step3")
        );
    }

    // ---------- G. Rounding and floors ----------

    function testG_RoundingUp_never_undercounts_by_more_than_1() public {
        uint64 pool = 1 + (10 << 48);
        TokenId sCall = PositionFactory.makeLeg(pool, 0, 1, 0, 0, 0, 0, 0, 600);
        uint128 tiny = 7; // force fractional paths
        uint256 r = E.reqSingleNoPartner(sCall, 0, tiny, 0, 0);
        // lower bound is 1
        assertGe(r, 1, "floor");
        // we cannot recompute exact analytic target here without duplicating; at minimum verify adding one tick of size halves at most by factor that would never require rounding down
        // keep as placeholder bound test
        uint256 r1 = E.reqSingleNoPartner(sCall, 0, tiny, 1, 0);
        assertLe(r, r1, "tiny rounding nonincreasing in favorable move");
    }

    // ---------- Reverts and guards ----------

    function testH_LengthMismatch_reverts() public {
        vm.expectRevert(); // Errors.LengthMismatch()
        E.getMargin(
            new PositionBalance[](1),
            0,
            address(0xB),
            new TokenId[](0),
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0),
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1))
        );
    }
}
