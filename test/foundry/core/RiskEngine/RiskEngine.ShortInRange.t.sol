// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RiskEngineHarness} from "./RiskEngineHarness.sol";
import {PositionFactory} from "./helpers/PositionFactory.sol";
import {Constants} from "@libraries/Constants.sol";
import {Math} from "@libraries/Math.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {TokenId} from "@types/TokenId.sol";

/// @notice An in-range short leg's requirement must cover the net cost of closing it at the evaluated tick.
/// @dev Closing a short at price P costs `A - V(P)` in the leg's token, where A is the notional credited at mint and
/// V(P) is the chunk's value at P. The in-range interpolation term `r2` sits on the chord between the range edges
/// scaled by `(1 - c/2)` plus `r0`; a shallower slope would fall below the closing cost on wide ranges by up to
/// `c/2` of notional.
contract RiskEngineShortInRangeTest is Test {
    RiskEngineHarness internal E;
    int24[4] internal SPACINGS = [int24(1), int24(10), int24(60), int24(200)];

    function setUp() public {
        E = new RiskEngineHarness(5_000_000, 5_000_000);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _poolId(int24 ts) internal pure returns (uint64) {
        return 1 + (uint64(uint24(ts)) << 48);
    }

    /// @dev token1 -> token0 at sqrtP, in two 96-bit steps so it stays exact beyond tick 443,636 where sqrtP^2 overflows.
    function _toToken0(uint256 a1, uint160 sqrtP) internal pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(a1, Constants.FP96, sqrtP), Constants.FP96, sqrtP);
    }

    /// @dev token0 -> token1 at sqrtP, same two-step form.
    function _toToken1(uint256 a0, uint160 sqrtP) internal pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(a0, sqrtP, Constants.FP96), sqrtP, Constants.FP96);
    }

    /// @notice Net closing cost of leg `leg` in that leg's token at tick t: A - V(P), floored at 0.
    function _closingCost(
        TokenId id,
        uint256 leg,
        uint128 size,
        int24 t
    ) internal pure returns (uint256 A, uint256 cost) {
        LiquidityChunk chunk = PanopticMath.getLiquidityChunk(id, leg, size);
        (uint256 a0, uint256 a1) = Math.getAmountsForLiquidity(t, chunk);
        uint160 sqrtP = Math.getSqrtRatioAtTick(t);
        uint256 V;
        if (id.tokenType(leg) == 0) {
            A = PanopticMath.getAmountsMoved(id, size, leg, false).rightSlot();
            V = a0 + _toToken0(a1, sqrtP);
        } else {
            A = PanopticMath.getAmountsMoved(id, size, leg, false).leftSlot();
            V = a1 + _toToken1(a0, sqrtP);
        }
        cost = A > V ? A - V : 0;
    }

    /// @notice Strike aligned to the spacing, with the whole range inside the pool tick bounds (the SFPM's enforced
    /// range is a subset of this).
    int24 internal constant TICK_BAND = 887_000;

    function _strike(int24 ts, int24 width, int256 seed) internal pure returns (int24) {
        (int24 rangeDown, int24 rangeUp) = PanopticMath.getRangesFromStrike(width, ts);
        int256 lo = (-int256(TICK_BAND) + rangeDown + ts) / ts;
        int256 hi = (int256(TICK_BAND) - rangeUp - ts) / ts;
        return int24(bound(seed, lo, hi) * ts);
    }

    /// @notice External wrapper so a LiquidityTooHigh revert can be caught and the sample discarded. Also returns
    /// the chunk's full-range token amounts, which the SFPM bounds at `int128.max - 4` (`PositionTooLarge`).
    function chunkOf(
        TokenId id,
        uint256 leg,
        uint128 size
    ) external pure returns (LiquidityChunk chunk, uint256 amount0, uint256 amount1) {
        chunk = PanopticMath.getLiquidityChunk(id, leg, size);
        amount0 = Math.getAmount0ForLiquidity(chunk);
        amount1 = Math.getAmount1ForLiquidity(chunk);
    }

    /// @notice Mirrors what the SFPM accepts: liquidity fits uint128 and both token amounts fit the int128 lane.
    /// Beyond that `getAmountsMoved` truncates to uint128 silently, but such a leg can never be minted.
    function _mintable(TokenId id, uint256 leg, uint128 size) internal view returns (bool ok) {
        try this.chunkOf(id, leg, size) returns (LiquidityChunk, uint256 a0, uint256 a1) {
            uint256 lim = uint128(type(int128).max - 4);
            ok = a0 <= lim && a1 <= lim;
        } catch {
            ok = false;
        }
    }

    /// @notice External wrapper for a width-0 leg's notional, whose two-tick synthetic range can also overflow.
    function amountsOf(
        TokenId id,
        uint256 leg,
        uint128 size
    ) external pure returns (uint256, uint256) {
        return (
            PanopticMath.getAmountsMoved(id, size, leg, false).rightSlot(),
            PanopticMath.getAmountsMoved(id, size, leg, false).leftSlot()
        );
    }

    function _fundable(TokenId id, uint256 leg, uint128 size) internal view returns (bool ok) {
        try this.amountsOf(id, leg, size) returns (uint256, uint256) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    /// @notice True when one wei of the leg's other token is below 0.1% of the leg's notional at tick t, i.e. the
    /// integer rounding of the chunk's amounts cannot distort the reference closing cost. Samples where the whole
    /// other-token side of the chunk is sub-wei are excluded: the reference would count the token the seller
    /// receives at close as nothing, which is a rounding artifact bounded by one wei, not an engine error.
    function _roundingImmaterial(
        TokenId id,
        uint256 leg,
        uint128 size,
        int24 t
    ) internal pure returns (bool) {
        uint160 sqrtP = Math.getSqrtRatioAtTick(t);
        uint256 A;
        uint256 quantum;
        if (id.tokenType(leg) == 0) {
            A = PanopticMath.getAmountsMoved(id, size, leg, false).rightSlot();
            quantum = _toToken0(1, sqrtP);
        } else {
            A = PanopticMath.getAmountsMoved(id, size, leg, false).leftSlot();
            quantum = _toToken1(1, sqrtP);
        }
        return A > 0 && quantum * 1000 < A;
    }

    /// @notice Random tick inside [tL, tU).
    function _inRangeTick(TokenId id, uint256 leg, uint256 seed) internal pure returns (int24) {
        (int24 tL, int24 tU) = id.asTicks(leg);
        return int24(tL + int24(uint24(bound(seed, 0, uint24(tU - tL - 1)))));
    }

    /*//////////////////////////////////////////////////////////////
                         SINGLE SHORT LEG, NO PARTNER
    //////////////////////////////////////////////////////////////*/

    /// @notice Both token types, both asset bases, odd and even widths up to the 12-bit maximum, any strike inside
    /// the pool bounds, any in-range tick, any utilization, any size: requirement covers the closing cost.
    function testFuzz_inRangeShort_requirementCoversClosingCost(
        uint16 widthSeed,
        uint8 tsSeed,
        uint8 legSeed,
        int256 strikeSeed,
        uint16 utilSeed,
        uint256 posSeed,
        uint128 sizeSeed
    ) public view {
        int24 ts = SPACINGS[tsSeed % 4];
        int24 width = int24(uint24(bound(widthSeed, 1, 4094)));
        uint256 asset = legSeed & 1;
        uint256 tokenType = (legSeed >> 1) & 1;
        int24 strike = _strike(ts, width, strikeSeed);
        int16 util = int16(uint16(bound(utilSeed, 0, 10_000)));
        uint128 size = uint128(bound(sizeSeed, 1e9, 1e27));

        TokenId id = PositionFactory.makeLeg(
            _poolId(ts),
            0,
            1,
            asset,
            0,
            tokenType,
            0,
            strike,
            width
        );
        vm.assume(_mintable(id, 0, size));
        int24 t = _inRangeTick(id, 0, posSeed);
        vm.assume(_roundingImmaterial(id, 0, size, t));

        (uint256 A, uint256 cost) = _closingCost(id, 0, size, t);
        uint256 req = E.reqSingleNoPartner(id, 0, size, t, util);
        // 1 bp of notional plus a few wei of tolerance for rounding in the two value computations
        assertGe(req + A / 10_000 + 10, cost, "requirement below closing cost");
    }

    /// @notice A 4094 x 60-tick leg at 85% utilization is covered at every decile of its range, and never by more
    /// than c/2 of notional.
    function test_wideShort_deepInRange_covered() public view {
        TokenId id = PositionFactory.makeLeg(_poolId(60), 0, 1, 0, 0, 0, 0, 0, 4094);
        (int24 tL, int24 tU) = id.asTicks(0);
        for (int256 k = 1; k < 10; ++k) {
            int24 t = int24(tL + ((tU - tL) * k) / 10);
            (uint256 A, uint256 cost) = _closingCost(id, 0, 1e18, t);
            uint256 req = E.reqSingleNoPartner(id, 0, 1e18, t, 8500);
            assertGe(req, cost, "wide short under-priced");
            assertLe(req, cost + A / 2 + A / 1000, "wide short over-priced"); // at most c/2 of notional above
        }
    }

    /// @notice The effective requirement is continuous across both range edges, for both token types.
    function test_edges_continuous() public view {
        for (uint256 tt; tt < 2; ++tt) {
            TokenId id = PositionFactory.makeLeg(_poolId(60), 0, 1, tt, 0, tt, 0, 0, 4094);
            (int24 tL, int24 tU) = id.asTicks(0);
            for (uint256 i; i < 2; ++i) {
                int16 util = i == 0 ? int16(5000) : int16(8500);
                assertApproxEqRel(
                    E.reqSingleNoPartner(id, 0, 1e18, tL, util),
                    E.reqSingleNoPartner(id, 0, 1e18, tL - 1, util),
                    1e15,
                    "lower edge discontinuity"
                );
                assertApproxEqRel(
                    E.reqSingleNoPartner(id, 0, 1e18, tU - 1, util),
                    E.reqSingleNoPartner(id, 0, 1e18, tU, util),
                    1e15,
                    "upper edge discontinuity"
                );
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        SHORT LEG WITH A LONG PARTNER
    //////////////////////////////////////////////////////////////*/

    struct Spread {
        int24 ts;
        int24 wS;
        int24 wL;
        uint256 asset;
        uint256 tokenType;
        int24 kS;
        int24 kL;
    }

    function _spreadId(Spread memory p) internal pure returns (TokenId id) {
        id = TokenId.wrap(0).addPoolId(_poolId(p.ts));
        id = id.addLeg(0, 1, p.asset, 0, p.tokenType, 1, p.kS, p.wS); // short, partner = leg 1
        id = id.addLeg(1, 1, p.asset, 1, p.tokenType, 0, p.kL, p.wL); // long, partner = leg 0
    }

    /// @notice Net obligation of closing the pair at t: short's closing cost minus what closing the long returns.
    function _netClosingCost(
        TokenId id,
        uint128 size,
        int24 t
    ) internal pure returns (uint256 A, uint256 net) {
        uint256 costShort;
        (A, costShort) = _closingCost(id, 0, size, t);
        (, uint256 valueLong) = _closingCost(id, 1, size, t);
        net = costShort > valueLong ? costShort - valueLong : 0;
    }

    /// @notice A short leg partnered with a long leg of the same token type (a spread, vertical or calendar or both).
    /// The position's requirement, summed over both legs, must cover the net closing obligation.
    function testFuzz_shortWithLongPartner_requirementCoversNetClosingCost(
        uint16 widthShortSeed,
        uint16 widthLongSeed,
        uint8 tsSeed,
        uint8 legSeed,
        int256 strikeShortSeed,
        int256 strikeLongSeed,
        uint16 utilSeed,
        uint256 posSeed
    ) public view {
        Spread memory p;
        p.ts = SPACINGS[tsSeed % 4];
        p.wS = int24(uint24(bound(widthShortSeed, 1, 4094)));
        p.wL = int24(uint24(bound(widthLongSeed, 1, 4094)));
        p.asset = legSeed & 1;
        p.tokenType = (legSeed >> 1) & 1;
        p.kS = _strike(p.ts, p.wS, strikeShortSeed);
        p.kL = _strike(p.ts, p.wL, strikeLongSeed);
        vm.assume(p.kS != p.kL || p.wS != p.wL); // distinct chunks
        int16 util = int16(uint16(bound(utilSeed, 0, 10_000)));

        TokenId id = _spreadId(p);
        vm.assume(_mintable(id, 0, 1e18) && _mintable(id, 1, 1e18));
        int24 t = _inRangeTick(id, 0, posSeed);
        vm.assume(_roundingImmaterial(id, 0, 1e18, t) && _roundingImmaterial(id, 1, 1e18, t));
        (uint256 A, uint256 net) = _netClosingCost(id, 1e18, t);
        uint256 req = E.reqSinglePartner(id, 0, 1e18, t, util) +
            E.reqSinglePartner(id, 1, 1e18, t, util);
        assertGe(req + A / 10_000 + 10, net, "spread requirement below net closing cost");
    }

    /*//////////////////////////////////////////////////////////////
                              SHORT STRANGLE
    //////////////////////////////////////////////////////////////*/

    struct Strangle {
        int24 ts;
        int24 wC;
        int24 wP;
        uint256 asset;
        int24 kC;
        int24 kP;
    }

    function _strangleId(Strangle memory p) internal pure returns (TokenId id) {
        id = TokenId.wrap(0).addPoolId(_poolId(p.ts));
        id = id.addLeg(0, 1, p.asset, 0, 0, 1, p.kC, p.wC); // short call (token0 leg), partner = leg 1
        id = id.addLeg(1, 1, p.asset, 0, 1, 0, p.kP, p.wP); // short put (token1 leg), partner = leg 0
    }

    /// @notice A short strangle halves each leg's base ratio on the premise that only one side is in the money.
    /// With wide, overlapping ranges both legs can be in range at once; each leg's (discounted) requirement must
    /// still cover that leg's own closing cost in its own token.
    function testFuzz_shortStrangle_eachLegCoversItsClosingCost(
        uint16 widthCallSeed,
        uint16 widthPutSeed,
        uint8 tsSeed,
        uint8 assetSeed,
        int256 strikeCallSeed,
        int256 strikePutSeed,
        uint16 utilSeed,
        uint256 posSeed
    ) public view {
        Strangle memory p;
        p.ts = SPACINGS[tsSeed % 4];
        p.wC = int24(uint24(bound(widthCallSeed, 1, 4094)));
        p.wP = int24(uint24(bound(widthPutSeed, 1, 4094)));
        p.asset = assetSeed & 1;
        p.kC = _strike(p.ts, p.wC, strikeCallSeed);
        p.kP = _strike(p.ts, p.wP, strikePutSeed);
        int16 util = int16(uint16(bound(utilSeed, 0, 10_000)));

        TokenId id = _strangleId(p);
        vm.assume(_mintable(id, 0, 1e18) && _mintable(id, 1, 1e18));
        // evaluate inside the call leg's range; the put leg may or may not also be in range
        int24 t = _inRangeTick(id, 0, posSeed);
        vm.assume(_roundingImmaterial(id, 0, 1e18, t) && _roundingImmaterial(id, 1, 1e18, t));

        for (uint256 leg; leg < 2; ++leg) {
            (uint256 A, uint256 cost) = _closingCost(id, leg, 1e18, t);
            uint256 req = E.reqSinglePartner(id, leg, 1e18, t, util);
            assertGe(
                req + A / 10_000 + 10,
                cost,
                leg == 0 ? "call leg below closing cost" : "put leg below closing cost"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                    FUNDED COMPOSITES (OPTION + LOAN / CREDIT)
    //////////////////////////////////////////////////////////////*/

    struct Funded {
        int24 ts;
        int24 w;
        uint256 asset;
        uint256 tokenType;
        uint256 optionIsLong;
        uint256 fundIsLong;
        int24 k;
        int24 kF;
    }

    /// @dev leg 0 = option (width w), leg 1 = width-0 loan (short) or credit (long); same asset and token type.
    function _fundedId(Funded memory p) internal pure returns (TokenId id) {
        id = TokenId.wrap(0).addPoolId(_poolId(p.ts));
        id = id.addLeg(0, 1, p.asset, p.optionIsLong, p.tokenType, 1, p.k, p.w);
        id = id.addLeg(1, 1, p.asset, p.fundIsLong, p.tokenType, 0, p.kF, 0);
    }

    /// @notice Notional of a width-0 leg in its own token (what a loan must repay / what a credit returns).
    function _fundNotional(TokenId id, uint256 leg, uint128 size) internal pure returns (uint256) {
        return
            id.tokenType(leg) == 0
                ? PanopticMath.getAmountsMoved(id, size, leg, false).rightSlot()
                : PanopticMath.getAmountsMoved(id, size, leg, false).leftSlot();
    }

    /// @notice Short option + loan ("upfront short option"): the position must keep the loan principal locked and
    /// cover the short's closing cost on top; the engine sums the two requirements.
    function testFuzz_shortPlusLoan_coversPrincipalAndClosingCost(
        uint16 widthSeed,
        uint8 tsSeed,
        uint8 legSeed,
        int256 strikeSeed,
        int256 strikeLoanSeed,
        uint16 utilSeed,
        uint256 posSeed
    ) public view {
        Funded memory p = _funded(widthSeed, tsSeed, legSeed, strikeSeed, strikeLoanSeed, 0, 0);
        TokenId id = _fundedId(p);
        vm.assume(_mintable(id, 0, 1e18) && _fundable(id, 1, 1e18));
        int24 t = _inRangeTick(id, 0, posSeed);
        vm.assume(_roundingImmaterial(id, 0, 1e18, t));
        int16 util = int16(uint16(bound(utilSeed, 0, 10_000)));

        (uint256 A, uint256 cost) = _closingCost(id, 0, 1e18, t);
        uint256 principal = _fundNotional(id, 1, 1e18);
        uint256 req = E.reqSinglePartner(id, 0, 1e18, t, util) +
            E.reqSinglePartner(id, 1, 1e18, t, util);
        assertGe(
            req + A / 10_000 + 10,
            cost + principal,
            "short+loan below closing cost plus principal"
        );
    }

    /// @notice Long option + loan ("option-protected loan"): the loan principal must stay locked; the engine takes
    /// the max of the two requirements, which is at least the loan's since that one carries principal plus margin.
    function testFuzz_longPlusLoan_coversPrincipal(
        uint16 widthSeed,
        uint8 tsSeed,
        uint8 legSeed,
        int256 strikeSeed,
        int256 strikeLoanSeed,
        uint16 utilSeed,
        uint256 posSeed
    ) public view {
        Funded memory p = _funded(widthSeed, tsSeed, legSeed, strikeSeed, strikeLoanSeed, 1, 0);
        TokenId id = _fundedId(p);
        vm.assume(_mintable(id, 0, 1e18) && _fundable(id, 1, 1e18));
        int24 t = _inRangeTick(id, 0, posSeed);
        int16 util = int16(uint16(bound(utilSeed, 0, 10_000)));

        uint256 principal = _fundNotional(id, 1, 1e18);
        uint256 req = E.reqSinglePartner(id, 0, 1e18, t, util) +
            E.reqSinglePartner(id, 1, 1e18, t, util);
        assertGe(req + 10, principal, "long+loan below loan principal");
    }

    /// @notice Short option + credit ("cash-secured option"): the credit is counted on the balance side elsewhere,
    /// so the option leg's requirement alone must cover the short's closing cost.
    function testFuzz_shortPlusCredit_coversClosingCost(
        uint16 widthSeed,
        uint8 tsSeed,
        uint8 legSeed,
        int256 strikeSeed,
        int256 strikeCreditSeed,
        uint16 utilSeed,
        uint256 posSeed
    ) public view {
        Funded memory p = _funded(widthSeed, tsSeed, legSeed, strikeSeed, strikeCreditSeed, 0, 1);
        TokenId id = _fundedId(p);
        vm.assume(_mintable(id, 0, 1e18) && _fundable(id, 1, 1e18));
        int24 t = _inRangeTick(id, 0, posSeed);
        vm.assume(_roundingImmaterial(id, 0, 1e18, t));
        int16 util = int16(uint16(bound(utilSeed, 0, 10_000)));

        (uint256 A, uint256 cost) = _closingCost(id, 0, 1e18, t);
        uint256 req = E.reqSinglePartner(id, 0, 1e18, t, util) +
            E.reqSinglePartner(id, 1, 1e18, t, util);
        assertGe(req + A / 10_000 + 10, cost, "short+credit below closing cost");
    }

    function _funded(
        uint16 widthSeed,
        uint8 tsSeed,
        uint8 legSeed,
        int256 strikeSeed,
        int256 strikeFundSeed,
        uint256 optionIsLong,
        uint256 fundIsLong
    ) internal view returns (Funded memory p) {
        p.ts = SPACINGS[tsSeed % 4];
        p.w = int24(uint24(bound(widthSeed, 1, 4094)));
        p.asset = legSeed & 1;
        p.tokenType = (legSeed >> 1) & 1;
        p.optionIsLong = optionIsLong;
        p.fundIsLong = fundIsLong;
        p.k = _strike(p.ts, p.w, strikeSeed);
        p.kF = _strike(p.ts, 2, strikeFundSeed);
    }

    /*//////////////////////////////////////////////////////////////
                             SYNTHETIC STOCK
    //////////////////////////////////////////////////////////////*/

    /// @notice Short + long of different token types at the same strike: the engine prices the short leg only and
    /// the long comes for free. The short leg's requirement must still cover its own closing cost.
    function testFuzz_syntheticStock_shortLegCoversClosingCost(
        uint16 widthShortSeed,
        uint16 widthLongSeed,
        uint8 tsSeed,
        uint8 legSeed,
        int256 strikeSeed,
        uint16 utilSeed,
        uint256 posSeed
    ) public view {
        int24 ts = SPACINGS[tsSeed % 4];
        int24 wS = int24(uint24(bound(widthShortSeed, 1, 4094)));
        int24 wL = int24(uint24(bound(widthLongSeed, 1, 4094)));
        uint256 asset = legSeed & 1;
        uint256 shortType = (legSeed >> 1) & 1;
        int24 k = _strike(ts, wS > wL ? wS : wL, strikeSeed);
        int16 util = int16(uint16(bound(utilSeed, 0, 10_000)));

        TokenId id = TokenId.wrap(0).addPoolId(_poolId(ts));
        id = id.addLeg(0, 1, asset, 0, shortType, 1, k, wS); // short, partner = leg 1
        id = id.addLeg(1, 1, asset, 1, 1 - shortType, 0, k, wL); // long, other token type, same strike
        vm.assume(_mintable(id, 0, 1e18) && _mintable(id, 1, 1e18));
        int24 t = _inRangeTick(id, 0, posSeed);
        vm.assume(_roundingImmaterial(id, 0, 1e18, t));

        (uint256 A, uint256 cost) = _closingCost(id, 0, 1e18, t);
        uint256 req = E.reqSinglePartner(id, 0, 1e18, t, util) +
            E.reqSinglePartner(id, 1, 1e18, t, util);
        assertGe(req + A / 10_000 + 10, cost, "synthetic: short leg below closing cost");
        assertEq(E.reqSinglePartner(id, 1, 1e18, t, util), 0, "synthetic: long leg should be free");
    }
}
