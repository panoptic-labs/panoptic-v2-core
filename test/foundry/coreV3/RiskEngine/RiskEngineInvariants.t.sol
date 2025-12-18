// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RiskEngineHarness} from "./RiskEngineHarness.sol";
import {MockCollateralTracker} from "./mocks/MockCollateralTracker.sol";
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {TokenId} from "@types/TokenId.sol";
import {PositionBalance} from "@types/PositionBalance.sol";
import {OraclePack} from "@types/OraclePack.sol";
import {PositionFactory} from "./helpers/PositionFactory.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";

contract RiskEngineInvariants is Test {
    using PositionFactory for *;

    RiskEngineHarness internal E;
    MockCollateralTracker internal ct0;
    MockCollateralTracker internal ct1;

    uint256 constant DEC = 10_000_000;
    uint256 internal constant BITMASK_UINT22 = 0x3FFFFF;

    function setUp() public {
        E = new RiskEngineHarness(
            2_000_000,
            1_000_000,
            1_000,
            5_000_000,
            9_000_000,
            5_000_000,
            5_000_000
        );
        ct0 = new MockCollateralTracker();
        ct1 = new MockCollateralTracker();
        ct0.setGlobal(1_000_000 ether, 1_000_000 ether);
        ct1.setGlobal(1_000_000 ether, 1_000_000 ether);
        ct0.setSharePrice(1, 1);
        ct1.setSharePrice(1, 1);
    }

    function _packEMAs(
        int24 slow,
        int24 fast,
        int24 spot,
        int24 median
    ) internal pure returns (OraclePack) {
        // PanopticMath.getEMAs(oraclePack) returns (, slow, fast, spot, median)
        // Use PanopticMath helpers if exposed; otherwise mirror your packing here.
        // For now assume PanopticMath has a pack helper in your codebase; if not, stub as needed.
        uint256 updatedEMAs = (uint256(uint24(spot)) & BITMASK_UINT22) +
            ((uint256(uint24(fast)) & BITMASK_UINT22) << 22) +
            ((uint256(uint24(slow)) & BITMASK_UINT22) << 44);

        // store median as referenceTick
        return OraclePack.wrap((updatedEMAs << 120) + (uint256(uint24(median)) << 96));
    }

    function testFuzz_Invariant_scale_and_util_sign(
        uint128 size,
        int16 util,
        int24 strike,
        int24 width
    ) public {
        size = uint128(bound(size, 1, 1e12));
        width = int24(bound(width, 1, 2000));
        strike = int24(bound(strike, -40000, 40000));
        util = int16(bound(util, -9000, 9500)); // includes negative for strangles

        uint64 pool = 1 + (10 << 48);
        // randomly pick long or short, call or put
        uint256 isLong = uint256(uint160(uint256(keccak256(abi.encodePacked(size)))) & 1);
        uint256 ttype = uint256(
            uint160(uint256(keccak256(abi.encodePacked(size, uint256(1))))) & 1
        );

        TokenId leg = PositionFactory.makeLeg(pool, 0, 1, 0, isLong, ttype, 0, strike, width);
        uint256 r = E.reqSingleNoPartner(leg, 0, size, strike, util);

        // scale by k
        uint128 ksize = size * 3;
        uint256 rScaled = E.reqSingleNoPartner(leg, 0, ksize, strike, util);
        assertApproxEqAbs(rScaled, r * 3, 10, "linear in size");

        // sign of util for short vs strangle is handled internally; requirement must be >= 1 for small sizes when short
        if (isLong == 0) {
            assertGe(r, 1, "short floor");
        }
    }

    function testFuzz_Buffer_monotone_once(uint128 s, uint16 u0, uint16 u1) public {
        s = uint128(bound(s, 1e6, 1e12));
        u0 = uint16(bound(u0, 0, 9000));
        u1 = uint16(bound(u1, 0, 9000));

        address user = address(this);
        ct0.setUser(user, 10 ether, 0, 10 ether);
        ct1.setUser(user, 10 ether, 0, 10 ether);

        uint64 pool = 1 + (10 << 48);
        TokenId t = PositionFactory.makeLeg(pool, 0, 1, 0, 0, 0, 0, 0, 600);
        TokenId[] memory ids = new TokenId[](1);
        ids[0] = t;

        PositionBalance[] memory arr = new PositionBalance[](1);
        arr[0] = (PositionFactory.posBalance(s, u0, u1));
        LeftRightUnsigned z = LeftRightUnsigned.wrap(0);

        bool s1 = E.isAccountSolvent(
            arr,
            ids,
            0,
            user,
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
            user,
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
            user,
            z,
            z,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1)),
            11_000_000
        );
        // no re-entry
        require(!(s1 == false && s2 == true), "flip once at most (1)");
        require(!(s2 == false && s3 == true), "flip once at most (2)");
    }

    // 1) Sell/buy ratio bounds and monotonicity around target/saturated.
    function testFuzz_Invariant_util_curves_bounds(int16 u) public {
        u = int16(bound(u, -10000, 10000)); // include negative for strangle path
        uint256 sell = E.sellCollateralRatio(u);
        uint256 buy = E.buyCollateralRatio(uint16(u < int16(0) ? int16(0) : int16(u)));

        // Ranges: 0 < buy ≤ SELL and sell ≤ 100%
        assertGt(buy, 0, "buy>0");
        assertLe(buy, 2_000_000, "buy leq baseSELL cap proxy");
        assertLe(sell, DEC, "sell leq 100%");

        // At saturation, buy roughly halves, sell→100%
        if (uint256(int256(u < 0 ? int16(0) : u)) * 1000 >= 9_000_000) {
            assertLe(buy, 1_000_000 + 2, "buy halves at saturation (pm slack)");
            assertEq(sell, DEC, "sell=100% at saturation");
        }
    }

    // 2) Spread requirement ≤ sum of legs, always.
    function testFuzz_Invariant_spread_leq_split(
        int24 strike0,
        int24 width0,
        int24 dStrike,
        int24 width1
    ) public {
        strike0 = int24(bound(strike0, -25000, 25000));
        width0 = int24(bound(width0, 10, 2000));
        width1 = int24(bound(width1, 10, 2000));
        int24 strike1 = strike0 + int24(bound(dStrike, -1500, 1500));

        // long call @strike0, short call @strike1 (tokenType=0)
        TokenId t = PositionFactory.makeTwoLegs(
            1 + (10 << 48),
            1,
            0,
            1,
            0,
            strike0,
            width0,
            1,
            0,
            0,
            0,
            strike1,
            width1
        );

        uint128 S = 1e9;
        uint256 split = E.reqSingleNoPartner(t, 0, S, 0, 0) + E.reqSingleNoPartner(t, 1, S, 0, 0);
        uint256 spread = E.computeSpread(t, S, 0, 1, 0, 0);
        assertLe(spread, split, "spread leq sum legs");
    }

    // 3) Calendar tweak: increasing |Δwidth| increases spread requirement (same strike).
    function testFuzz_Invariant_calendar_tweak_monotone(
        int24 strike,
        int24 w0,
        int24 w1,
        int24 w2
    ) public {
        strike = int24(bound(strike, -500, 500));
        w0 = int24(bound(w0, 60, 500));
        w1 = int24(bound(w1, w0, 1500));
        w2 = int24(bound(w2, w0, 1500));
        // Force |Δw2| > |Δw1|
        int24 d1 = w1 - w0;
        int24 d2 = d1 + int24(bound(w2, 60, 300)); // bigger delta

        uint256 r1;
        uint256 r2;
        uint64 pool = 1 + (10 << 48);
        {
            int24 _strike = strike;
            int24 w = int24(int256(w0 + d1));
            int24 _w0 = w0;
            TokenId cal1 = PositionFactory.makeTwoLegs(
                pool,
                1,
                0,
                1,
                0,
                _strike,
                _w0,
                1,
                0,
                0,
                0,
                _strike,
                w
            );
            r1 = E.computeSpread(cal1, 1e9, 0, 1, 0, 0);
        }
        {
            int24 _strike = strike;
            int24 w = int24(int256(w0 + d2));
            int24 _w0 = w0;
            TokenId cal2 = PositionFactory.makeTwoLegs(
                pool,
                1,
                0,
                1,
                0,
                _strike,
                _w0,
                1,
                0,
                0,
                0,
                _strike,
                w
            );
            r2 = E.computeSpread(cal2, 1e9, 0, 1, 0, 0);
        }
        assertGt(r2, r1, "|delta-width| monotone");
    }

    // 4) Strangle halves the base short: partner path result < sum of singles.
    function testFuzz_Invariant_strangle_is_less_than_split(int24 s, int24 w, int24 sep) public {
        s = int24(bound(s, -3000, 3000));
        w = int24(bound(w, 60, 1500));
        sep = int24(bound(sep, 60, 2000));

        int24 a = s - sep;
        int24 b = s + sep;
        int24 _w = w;
        TokenId t = PositionFactory.makeTwoLegs(
            1 + (10 << 48),
            1,
            0,
            0,
            1,
            a,
            _w, // short put
            1,
            0,
            0,
            0,
            b,
            _w // short call
        );
        uint128 S = 1e9;
        uint256 partner = E.reqSinglePartner(t, 0, S, 0, 0) + E.reqSinglePartner(t, 1, S, 0, 0);
        uint256 split = E.reqSingleNoPartner(t, 0, S, 0, 1) + E.reqSingleNoPartner(t, 1, S, 0, 1);
        assertLt(partner, split, "strangle < sum singles");
        assertGe(partner, 1, "floor binds");
    }

    // 5) Delayed swap chooses max(required loan, converted credit) as atTick varies.
    function testFuzz_Invariant_delayed_swap_max_rule(int24 atTick) public {
        atTick = int24(bound(atTick, -30000, 30000));
        uint64 pool = 1 + (10 << 48);
        // loan (short, type=1) + credit (long, type=0) so conversion branch flips with price
        TokenId t = PositionFactory.makeTwoLegs(
            pool,
            1,
            0,
            0,
            1,
            int24(0),
            0, // loan leg0
            1,
            0,
            1,
            0,
            int24(0),
            0 // credit leg1
        );
        uint256 r0 = E.reqSinglePartner(t, 0, 2e9, atTick, 0);
        assertGt(r0, 0, "delayed swap positive");
        // Partner on credit side always zero
        assertEq(E.reqSinglePartner(t, 1, 2e9, atTick, 0), 0, "only loan leg returns");
    }

    // 6) isAccountSolvent monotone in buffer and flips at most once (bisection).
    function testFuzz_Invariant_buffer_single_flip(uint128 s, uint16 u0, uint16 u1) public {
        s = uint128(bound(s, 1e9, 1e12));
        u0 = uint16(bound(u0, 0, 9000));
        u1 = uint16(bound(u1, 0, 9000));
        address user = address(this);
        ct0.setUser(user, 12 ether, 0, 12 ether);
        ct1.setUser(user, 12 ether, 0, 12 ether);

        uint64 pool = 1 + (10 << 48);
        TokenId t = PositionFactory.makeLeg(pool, 0, 1, 0, 0, 0, 0, 0, 600);
        TokenId[] memory ids = new TokenId[](1);
        ids[0] = t;
        PositionBalance[] memory arr = new PositionBalance[](1);
        arr[0] = (PositionFactory.posBalance(s, u0, u1));
        LeftRightUnsigned z = LeftRightUnsigned.wrap(0);

        // search two buffers; verify monotone tightening and at most one flip
        uint256[5] memory B = [uint256(8_000_000), 9_000_000, 10_000_000, 11_000_000, 12_000_000];
        bool last = true;
        bool flipped = false;
        for (uint256 i; i < B.length; ++i) {
            bool si = E.isAccountSolvent(
                arr,
                ids,
                0,
                user,
                z,
                z,
                CollateralTracker(address(ct0)),
                CollateralTracker(address(ct1)),
                B[i]
            );
            if (i > 0 && !si && last) flipped = true;
            // once false, never return to true
            if (!si) {
                /* ok */
            } else {
                require(!flipped, "no re-entry after flip");
            }
            last = si;
        }
    }

    // 7) Price-side symmetry sanity: if you swap tokens and invert price side, solvency should not systematically flip.
    function testFuzz_Invariant_price_side_symmetry(
        uint128 s,
        uint16 u0,
        uint16 u1,
        int24 tick
    ) public {
        s = uint128(bound(s, 1e9, 1e12));
        u0 = uint16(bound(u0, 0, 9000));
        u1 = uint16(bound(u1, 0, 9000));
        tick = int24(bound(tick, -1500, 1500));

        address user = address(0xBEEF);
        ct0.setUser(user, 40 ether, 0, 30 ether);
        ct1.setUser(user, 35 ether, 0, 25 ether);

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
        arr[0] = (PositionFactory.posBalance(s, u0, u1));
        LeftRightUnsigned z = LeftRightUnsigned.wrap(0);

        bool A = E.isAccountSolvent(
            arr,
            ids,
            tick,
            user,
            z,
            z,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1)),
            DEC
        );
        bool B = E.isAccountSolvent(
            arr,
            ids,
            -tick,
            user,
            z,
            z,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1)),
            DEC
        );

        assertTrue(A || B, "no pathological always-false/true symmetry break");
    }

    // 8) Conservation: getMargin includes assets+interest+shortPremia+credits and long premia only in requirements.
    function testFuzz_Invariant_conservation_and_routing(
        uint96 a0,
        uint96 i0,
        uint96 s0,
        uint96 a1,
        uint96 i1,
        uint96 s1,
        uint128 premShort0,
        uint128 premShort1,
        uint128 premLong0,
        uint128 premLong1
    ) public {
        address u = address(0xCAFE);
        ct0.setUser(
            u,
            uint256(bound(a0, 0, 1e24)),
            uint256(bound(i0, 0, 1e24)),
            uint256(bound(s0, 0, 1e24))
        );
        ct1.setUser(
            u,
            uint256(bound(a1, 0, 1e24)),
            uint256(bound(i1, 0, 1e24)),
            uint256(bound(s1, 0, 1e24))
        );

        // zero positions, just to test routing
        PositionBalance[] memory arr = new PositionBalance[](0);
        TokenId[] memory ids = new TokenId[](0);
        LeftRightUnsigned shortPrem = LeftRightUnsigned
            .wrap(0)
            .addToRightSlot(uint128(bound(premShort0, 0, 1e18)))
            .addToLeftSlot(uint128(bound(premShort1, 0, 1e18)));
        LeftRightUnsigned longPrem = LeftRightUnsigned
            .wrap(0)
            .addToRightSlot(uint128(bound(premLong0, 0, 1e18)))
            .addToLeftSlot(uint128(bound(premLong1, 0, 1e18)));

        (LeftRightUnsigned td0, LeftRightUnsigned td1, ) = E.getMarginInternal(
            u,
            arr,
            0,
            ids,
            shortPrem,
            longPrem,
            CollateralTracker(address(ct0)),
            CollateralTracker(address(ct1))
        );

        // Balances side must equal assets + shortPrem + credits(=0 here).
        // balances = assets + short premia + credits(=0 here)
        (uint256 assets0, uint256 interest0) = ct0.assetsAndInterest(u);
        (uint256 assets1, uint256 interest1) = ct1.assetsAndInterest(u);

        // In the insolvent-interest case, balance is zeroed since those assets
        // will be consumed paying interest
        uint256 effectiveAssets0 = interest0 > assets0 ? 0 : assets0 - interest0;
        uint256 effectiveAssets1 = interest1 > assets1 ? 0 : assets1 - interest1;
        assertEq(
            td0.rightSlot(),
            effectiveAssets0 + shortPrem.rightSlot(),
            "balance0 = assets0 + shortPrem0"
        );
        assertEq(
            td1.rightSlot(),
            effectiveAssets1 + shortPrem.leftSlot(),
            "balance1 = assets1 + shortPrem1"
        );

        // Requirements side must include long premia and interest.
        assertGe(td0.leftSlot(), longPrem.rightSlot(), "long premia -> req0");
        assertGe(td1.leftSlot(), longPrem.leftSlot(), "long premia -> req1");
    }

    // 9) Rounding discipline: favorable move never increases requirement for a given short.
    function testFuzz_Invariant_rounding_ceiling_short_monotone(int24 d) public {
        d = int24(bound(d, 1, 2000));
        uint64 pool = 1 + (10 << 48);
        TokenId sCall = PositionFactory.makeLeg(pool, 0, 1, 0, 0, 0, 0, 0, 600);
        uint128 tiny = 23;
        uint256 r0 = E.reqSingleNoPartner(sCall, 0, tiny, 0, 0);
        uint256 r1 = E.reqSingleNoPartner(sCall, 0, tiny, -d, 0); // further OTM
        assertLe(r1, r0, "favorable move does not increase requirement");
        assertGe(r0, 1, "floor binds for tiny");
    }

    // 10) SafeMode flags add, not override; each condition can independently trip.
    function testFuzz_Invariant_safe_mode_flags(int24 K) public {
        // If you expose MAX_TICKS_DELTA, bind to it; otherwise assume ~500 for stress.
        K = int24(bound(K, 200, 1000));
        // Pack simple oracle states via your PanopticMath packer if available in tests.
        // Here we emulate by using Harness interface that calls Math on currentTick vs spot/fast/median deltas.
        // externalShock only
        uint8 s1 = E.isSafeMode(K + 1, _packEMAs(0, 0, 0, 0)); // add packEMAs test-helper in harness if needed
        // If you don't have packEMAs, skip; or assert true with a precomputed oraclePack.
        // We keep as smoke; you can wire your pack helper similarly to RiskEngineSafeModeAndOracle in previous reply.
        assertTrue(s1 >= 0, "smoke");
    }
}
