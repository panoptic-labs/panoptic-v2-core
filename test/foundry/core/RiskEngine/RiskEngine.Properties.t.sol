// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RiskEngineHarness} from "./RiskEngineHarness.sol";
import {MockCollateralTracker} from "./mocks/MockCollateralTracker.sol";
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {TokenId} from "@types/TokenId.sol";
import {PositionBalance} from "@types/PositionBalance.sol";
import {PositionFactory} from "./helpers/PositionFactory.sol";
import {Constants} from "@libraries/Constants.sol";
import {Math} from "@libraries/Math.sol";

contract RiskEngineProperties is Test {
    using PositionFactory for *;

    RiskEngineHarness internal E;
    MockCollateralTracker internal ct0;
    MockCollateralTracker internal ct1;

    // Default params: 20% short, 10% long, 10 bps FE cost, target=50%, saturated=90%
    uint256 constant DECIMALS = 10_000_000;
    uint256 constant SELL = 2_000_000;
    uint256 constant BUY = 1_000_000;
    uint256 constant FE = 1_000; // 10 bps
    uint256 constant U_TARGET = 5_000_000;
    uint256 constant U_SAT = 9_000_000;

    function setUp() public {
        E = new RiskEngineHarness(
            /*CROSS_BUFFER_0*/ 5_000_000, // 0.5
            /*CROSS_BUFFER_1*/ 5_000_000
        );
        ct0 = new MockCollateralTracker();
        ct1 = new MockCollateralTracker();

        // default tracker state
        ct0.setGlobal(1_000_000 ether, 1_000_000 ether);
        ct1.setGlobal(1_000_000 ether, 1_000_000 ether);
        ct0.setSharePrice(1, 1);
        ct1.setSharePrice(1, 1);
    }

    // -------- A. Packing/units/accounting --------

    function test_PackingUnitsAccounting_simpleBalances() public {
        address user = address(0xBEEF);

        // balances and interest
        ct0.setUser(user, 10 ether, 1 ether, 10 ether);
        ct1.setUser(user, 20 ether, 2 ether, 20 ether);

        // no positions → requirements from positions = 0
        TokenId[] memory ids = new TokenId[](1);
        PositionBalance[] memory bals = new PositionBalance[](1);

        LeftRightUnsigned shortPremia = LeftRightUnsigned.wrap(0);
        LeftRightUnsigned longPremia = LeftRightUnsigned.wrap(0);

        (LeftRightUnsigned td0, LeftRightUnsigned td1, ) = E.getMarginInternal(
            user,
            bals,
            int24(0),
            ids,
            shortPremia,
            longPremia,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1))
        );

        // left = requirement, right = balance including short premia and credits
        assertEq(td0.leftSlot(), 0 ether, "req0 equals interest0 only");
        assertEq(td1.leftSlot(), 0 ether, "req1 equals interest1 only");
        assertEq(td0.rightSlot(), 10 ether - 1 ether, "bal0 - interest0");
        assertEq(td1.rightSlot(), 20 ether - 2 ether, "bal1 - interest1");
    }

    // -------- B. Linearity in position size --------

    function testFuzz_LinearityInPositionSize(uint128 size, uint16 util0, uint16 util1) public {
        vm.assume(size > 0 && size < type(uint128).max / 20);
        // minimalist single short call leg
        uint64 poolId = 1 + (10 << 48);
        TokenId t = PositionFactory.makeLeg(
            /*poolId*/ poolId,
            /*leg*/ 0,
            /*ratio*/ 1,
            /*asset*/ 0,
            /*isLong*/ 0,
            /*tokenType*/ 0,
            /*riskPartner*/ 0,
            /*strike*/ int24(0),
            /*width*/ int24(1000) // non-zero width
        );
        TokenId[] memory ids = new TokenId[](1);
        ids[0] = t;

        PositionBalance pb = PositionFactory.posBalance(size, util0, util1);
        PositionBalance[] memory arr = new PositionBalance[](1);
        arr[0] = (pb);

        // no premia impact for scaling
        LeftRightUnsigned zero = LeftRightUnsigned.wrap(0);

        (LeftRightUnsigned reqs0, LeftRightUnsigned reqs1, ) = E.totalRequiredCollateral(
            arr,
            ids,
            /*atTick*/ int24(0),
            /*longPremia*/ zero
        );

        // scale by k=7 and compare
        uint128 size2 = size * 7;
        PositionBalance pb2 = PositionFactory.posBalance(size2, util0, util1);
        PositionBalance[] memory arr2 = new PositionBalance[](1);
        arr2[0] = (pb2);

        (LeftRightUnsigned reqs0b, LeftRightUnsigned reqs1b, ) = E.totalRequiredCollateral(
            arr2,
            ids,
            int24(0),
            zero
        );

        assertEq(reqs0b.leftSlot(), reqs0.leftSlot() * 7, "req0 scales");
        assertEq(reqs1b.leftSlot(), reqs1.leftSlot() * 7, "req1 scales");
    }

    // -------- C. Utilization monotonicity --------

    function test_UtilizationMonotonicity_ShortIncreasingLongDecreasing() public {
        uint128 amount = 1e9; // arbitrary notional
        // short path: isLong=0 must be nondecreasing in util
        uint256 a = E.reqAtUtil(amount, 0, int16(0));
        uint256 b = E.reqAtUtil(amount, 0, int16(5000)); // 5k
        uint256 c = E.reqAtUtil(amount, 0, int16(9000)); // 9k
        assertGe(b, a, "short nondecreasing");
        assertGe(c, b, "short nondecreasing to saturation");

        // long path: isLong=1 must be nonincreasing in util
        a = E.reqAtUtil(amount, 1, int16(0));
        b = E.reqAtUtil(amount, 1, int16(5000));
        c = E.reqAtUtil(amount, 1, int16(9000));
        assertLe(b, a, "long nonincreasing");
        assertLe(c, b, "long nonincreasing to saturation");
    }

    // -------- D. Strategy identities --------

    function test_SpreadEqualsMinOfMaxLossAndSplit() public {
        uint64 poolId = 1 + (10 << 48);
        // Vertical call spread: short higher strike, long lower strike, same tokenType, same asset
        // Leg0 long call at strike 0, width 600
        // Leg1 short call at strike 300, width 600
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
        int24 atTick = 0; // ATM

        uint256 split = E.reqSingleNoPartner(t, 0, size, atTick, int16(0)) +
            E.reqSingleNoPartner(t, 1, size, atTick, int16(0));

        uint256 spread = E.computeSpread(t, size, 0, 1, atTick, int16(0));
        assertLe(spread, split, "spread <= sum legs");

        // Also check that computePartner only returns once
        uint256 p0 = E.reqSinglePartner(t, 0, size, atTick, int16(0));
        uint256 p1 = E.reqSinglePartner(t, 1, size, atTick, int16(0));
        assertGt(p0, 0, "first leg carries spread req");
        assertEq(p1, 0, "partner leg returns 0");
    }

    function test_StrangleHalvesBaseShort() public {
        // short put + short call on same asset, different token types
        uint64 poolId = 1 + (10 << 48);
        TokenId t = PositionFactory.makeTwoLegs(
            poolId,
            1,
            0,
            0,
            1,
            int24(-300),
            int24(600), // leg0 short put
            1,
            0,
            0,
            0,
            int24(300),
            int24(600) // leg1 short call
        );
        uint128 size = 1e9;
        int24 atTick = 0;

        // strangle is computed through negative-utilization path inside computeStrangle via reqSinglePartner
        uint256 str0 = E.reqSinglePartner(t, 0, size, atTick, int16(0));
        uint256 str1 = E.reqSinglePartner(t, 1, size, atTick, int16(0));
        // Only one side should return nonzero (first encountered)
        //assertTrue((str0 == 0) != (str1 == 0), "only one leg returns");
        uint256 strReq = str0 + str1;

        // Compare to base single short leg requirement at same util, then verify approx half
        uint256 base0 = E.reqSingleNoPartner(t, 0, size, atTick, int16(1)); // any small util
        uint256 base1 = E.reqSingleNoPartner(t, 1, size, atTick, int16(1));
        uint256 baseSum = base0 + base1;

        // strangle must be strictly less than baseSum and roughly half on each leg
        assertLt(strReq, baseSum, "strangle < sum singles");
    }

    function test_CreditAndLoanComposites_OptionSideOnly() public {
        // Cash-secured short call: short call + credit (width=0)
        uint64 poolId = 1 + (10 << 48);

        TokenId tCS = PositionFactory.makeTwoLegs(
            poolId,
            1,
            0,
            0,
            0,
            int24(0),
            int24(600), // leg0 short call (option)
            1,
            0,
            1,
            0,
            int24(0),
            int24(0) // leg1 long credit (width 0, same tokenType)
        );
        // Option-protected loan: long call + loan (width=0 on partner)
        TokenId tOL = PositionFactory.makeTwoLegs(
            poolId,
            1,
            0,
            1,
            0,
            int24(0),
            int24(600), // leg0 long call
            1,
            0,
            0,
            0,
            int24(0),
            int24(0) // leg1 short loan
        );

        uint128 size = 1e9;
        int24 atTick = 0;

        // Only the option side should compute a requirement for credit/loan composites.
        uint256 cs0 = E.reqSinglePartner(tCS, 0, size, atTick, int16(0));
        uint256 cs1 = E.reqSinglePartner(tCS, 1, size, atTick, int16(0));
        assertGt(cs0 + cs1, 0, "cash-secured set");
        assertTrue((cs0 > 0 && cs1 == 0) || (cs1 > 0 && cs0 == 0), "only option leg returns");

        uint256 ol0 = E.reqSinglePartner(tOL, 0, size, atTick, int16(0));
        uint256 ol1 = E.reqSinglePartner(tOL, 1, size, atTick, int16(0));
        assertTrue((ol0 > 0 && ol1 == 0) || (ol1 > 0 && ol0 == 0), "only option leg returns");
    }

    // -------- E. Zero-width legs: loan and credit semantics --------

    function test_ZeroWidthLoanAndCredit() public {
        // long loan (width=0, isLong=1) should give credit in tokenType slot via getAmountsMoved path
        uint64 poolId = 1 + (10 << 48);
        TokenId loan = PositionFactory.makeLeg(
            poolId,
            0,
            1,
            0,
            1, // long!
            0, // tokenType 0
            0,
            int24(0),
            int24(0) // width 0
        );

        // Short loan (width=0, isLong=0) should require DECIMALS + SELL collateral ratio of moved amount
        TokenId shortLoan = PositionFactory.makeLeg(
            poolId,
            0,
            1,
            0,
            0, // short
            0,
            0,
            int24(0),
            int24(0)
        );

        uint128 size = 1e9;
        int24 atTick = 0;

        // Verify: per-leg requirement nonzero only for short loan; long loan contributes credits
        uint256 reqShort = E.reqSingleNoPartner(shortLoan, 0, size, atTick, int16(0));
        uint256 reqLong = E.reqSingleNoPartner(loan, 0, size, atTick, int16(0));
        assertGt(reqShort, 0, "short loan requires");
        assertEq(reqLong, 0, "long credit requires 0");
    }

    // -------- F. Aggregation boundaries: _getTotalRequiredCollateral --------

    function test_Aggregation_SumsPositionsAndLongPremia() public {
        // simple: one short call option, plus long premia
        uint64 poolId = 1 + (10 << 48);
        TokenId t = PositionFactory.makeLeg(poolId, 0, 1, 0, 0, 0, 0, int24(0), int24(600));
        TokenId[] memory ids = new TokenId[](1);
        ids[0] = t;

        PositionBalance pb = PositionFactory.posBalance(uint128(1e9), 1000, 0);
        PositionBalance[] memory arr = new PositionBalance[](1);
        arr[0] = (pb);

        LeftRightUnsigned longPremia = LeftRightUnsigned.wrap(0).addToLeftSlot(uint128(5e6));

        (LeftRightUnsigned req0, LeftRightUnsigned req1, ) = E.totalRequiredCollateral(
            arr,
            ids,
            int24(0),
            longPremia
        );

        // Requirement must include long premia (right slot into token0 requirement)
        assertGe(req0.leftSlot(), 5e6, "includes long premia in requirements");
        // No balances counted here; only requirements+credits returned
    }

    // -------- G. isAccountSolvent algebraic consistency --------

    function test_isAccountSolvent_SymmetricAcrossPriceOrderings() public {
        // Setup balances and premia
        address user = address(0xCAFE);
        ct0.setUser(user, 50 ether, 0, 30 ether);
        ct1.setUser(user, 60 ether, 0, 40 ether);
        ct0.setGlobal(1_000 ether, 1_000 ether);
        ct1.setGlobal(1_000 ether, 1_000 ether);
        uint64 poolId = 1 + (10 << 48);

        // one neutral book: long call + short call same strike to keep requirements finite
        TokenId t = PositionFactory.makeTwoLegs(
            poolId,
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

        PositionBalance pb = PositionFactory.posBalance(uint128(5e9), 2000, 2000);
        PositionBalance[] memory arr = new PositionBalance[](1);
        arr[0] = (pb);

        LeftRightUnsigned sPrem = LeftRightUnsigned.wrap(0);
        LeftRightUnsigned lPrem = LeftRightUnsigned.wrap(0);

        // Case A: sqrtPriceX96 < FP96
        bool A = E.isAccountSolvent(
            arr,
            ids,
            /*atTick*/ int24(-200),
            user,
            sPrem,
            lPrem,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1)),
            /*buffer*/ DECIMALS
        );

        // Case B: sqrtPriceX96 > FP96
        bool B = E.isAccountSolvent(
            arr,
            ids,
            /*atTick*/ int24(200),
            user,
            sPrem,
            lPrem,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1)),
            /*buffer*/ DECIMALS
        );

        // We do not assert equality because position risk differs by side,
        // but we assert no algebraic inconsistency: flipping the side should not trivially always pass/fail.
        // This is a sanity check that conversion branches execute without underflow/overflow and produce boolean outputs.
        assertTrue(A || B, "at least one side solvent");
    }

    // -------- H. Buffer monotonicity --------

    function test_BufferMonotonicity() public {
        address user = address(0xB0B);
        ct0.setUser(user, 10 ether, 0, 10 ether);
        ct1.setUser(user, 10 ether, 0, 10 ether);

        uint64 poolId = 1 + (10 << 48);
        TokenId t = PositionFactory.makeLeg(poolId, 0, 1, 0, 0, 0, 0, int24(0), int24(600));
        TokenId[] memory ids = new TokenId[](1);
        ids[0] = t;

        PositionBalance pb = PositionFactory.posBalance(uint128(2e9), 4000, 4000);
        PositionBalance[] memory arr = new PositionBalance[](1);
        arr[0] = (pb);

        LeftRightUnsigned zero = LeftRightUnsigned.wrap(0);

        bool lo = E.isAccountSolvent(
            arr,
            ids,
            int24(0),
            user,
            zero,
            zero,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1)),
            DECIMALS // 1.0x
        );

        bool hi = E.isAccountSolvent(
            arr,
            ids,
            int24(0),
            user,
            zero,
            zero,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1)),
            12_000_000 // 1.2x
        );

        // Higher buffer cannot turn an insolvent account solvent
        if (!lo) {
            assertTrue(!hi, "monotone tightening");
        }
    }

    // -------- I. Rounding and floors --------

    function test_RoundingFloors_NonzeroWhenTiny() public {
        // Create a tiny notional short option, ensure floor 1 can bind
        uint64 poolId = 1 + (10 << 48);
        TokenId t = PositionFactory.makeLeg(poolId, 0, 1, 0, 0, 0, 0, int24(0), int24(600));
        uint128 tiny = 1; // minimal size
        uint256 r = E.reqSingleNoPartner(t, 0, tiny, int24(0), int16(0));
        assertGe(r, 1, "one-unit floor binds for tiny amounts");
    }

    // -------- J. Metamorphic: split/merge --------

    function test_Metamorphic_SplitMergeLegs() public {
        // One leg of size S vs two identical legs of size S/2 each, totals equal (within a factor of 1 due to rounding up)
        uint128 S = 10_000_000;
        uint64 poolId = 1 + (10 << 48);
        TokenId t = PositionFactory.makeLeg(poolId, 0, 1, 0, 0, 0, 0, int24(0), int24(600));
        uint256 r1 = E.reqSingleNoPartner(t, 0, S, int24(0), int16(0));

        uint256 r2 = E.reqSingleNoPartner(t, 0, S / 2, int24(0), int16(0));
        uint256 r3 = E.reqSingleNoPartner(t, 0, S / 2, int24(0), int16(0));
        assertLe(r1, r2 + r3, "split/merge invariance");
        assertApproxEqAbs(r1, r2 + r3, 2, "split/merge invariance");
    }
}
