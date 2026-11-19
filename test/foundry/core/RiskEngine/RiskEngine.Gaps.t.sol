// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {RiskEngineHarness} from "./RiskEngineHarness.sol";
import {MockCollateralTracker} from "./mocks/MockCollateralTracker.sol";
import {CollateralTrackerV2} from "@contracts/CollateralTracker.sol";
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {TokenId} from "@types/TokenId.sol";
import {PositionBalance} from "@types/PositionBalance.sol";
import {PositionFactory} from "./helpers/PositionFactory.sol";
import {Constants} from "@libraries/Constants.sol";
import {Math} from "@libraries/Math.sol";

contract RiskEngineCoverageGaps is Test {
    using PositionFactory for *;

    RiskEngineHarness internal E;
    MockCollateralTracker internal ct0;
    MockCollateralTracker internal ct1;

    uint256 constant DEC = 10_000_000;

    function setUp() public {
        E = new RiskEngineHarness(/*CB0*/ 5_000_000, /*CB1*/ 5_000_000);
        ct0 = new MockCollateralTracker();
        ct1 = new MockCollateralTracker();

        ct0.setGlobal(1_000_000 ether, 1_000_000 ether);
        ct1.setGlobal(1_000_000 ether, 1_000_000 ether);
        ct0.setSharePrice(1, 1);
        ct1.setSharePrice(1, 1);
    }

    // 1) Hit credits path inside _getRequiredCollateralAtTickSinglePosition:
    //    (width == 0 && isLong == 1) and tokenType matches underlyingIsToken{0,1}
    function test_Credits_LongZeroWidth_BothTokenTypes() public {
        uint64 pool = 1 + (10 << 48);
        // Two separate single-leg positions so we control tokenType in each pass.
        TokenId creditT0 = PositionFactory.makeLeg(
            pool,
            0,
            1,
            0,
            /*isLong*/ 1,
            /*tokenType*/ 0,
            0,
            int24(0),
            int24(0)
        );
        TokenId creditT1 = PositionFactory.makeLeg(
            pool,
            0,
            1,
            0,
            /*isLong*/ 1,
            /*tokenType*/ 1,
            0,
            int24(0),
            int24(0)
        );

        TokenId[] memory ids = new TokenId[](2);
        ids[0] = creditT0;
        ids[1] = creditT1;

        // Give both legs a nonzero position size so PanopticMath.getAmountsMoved produces credits.
        PositionBalance[] memory arr = new PositionBalance[](2);
        arr[0] = (PositionFactory.posBalance(uint128(5e9), 0, 0));
        arr[1] = (PositionFactory.posBalance(uint128(7e9), 0, 0));

        LeftRightUnsigned zero = LeftRightUnsigned.wrap(0);

        // totalRequiredCollateral returns (requirements, credits)
        (LeftRightUnsigned req0, LeftRightUnsigned req1, ) = E.totalRequiredCollateral(
            arr,
            ids,
            int24(0),
            zero
        );

        // We only care that credits were captured on the correct side and are nonzero
        // (exact numbers depend on PanopticMath.getAmountsMoved).
        assertGt(req0.rightSlot() + req1.leftSlot(), 0, "credits aggregated for both token types");
        // And the credit path does not add to requirements directly in this function
        // (long premia is what increases requirements, already covered elsewhere).
    }

    // 3) Hit tokenType==1 calendar term branch inside _computeSpread
    function test_Spread_PutCalendarTerm_TokenType1Branch() public {
        uint64 pool = 1 + (10 << 48);
        // Same strike puts, different widths -> calendar adjustment, tokenType=1
        TokenId t = PositionFactory.makeTwoLegs(
            pool,
            /*long put*/ 1,
            0,
            1,
            /*type*/ 1,
            int24(0),
            int24(300),
            /*short put*/ 1,
            0,
            0,
            /*type*/ 1,
            int24(0),
            int24(500)
        );
        uint256 out = E.computeSpread(
            t,
            uint128(4e9),
            /*index long*/ 0,
            /*partner*/ 1,
            int24(0),
            int16(0)
        );
        assertGt(out, 0, "put calendar spread computes with tokenType==1 path");
    }

    // 4a) Hit max-loss path with asset != tokenType (tokenType==0 sub-branch)
    function test_Spread_MaxLoss_AssetMismatch_TokenType0Branch() public {
        uint64 pool = 1 + (10 << 48);
        // Calls (tokenType 0) but set asset=1 to force asset!=tokenType path
        TokenId t = PositionFactory.makeTwoLegs(
            pool,
            /*long call*/ 1,
            /*asset*/ 1,
            1,
            /*type*/ 0,
            int24(0),
            int24(600),
            /*short call*/ 1,
            /*asset*/ 1,
            0,
            /*type*/ 0,
            int24(300),
            int24(600)
        );
        uint256 out = E.computeSpread(t, uint128(5e9), 0, 1, int24(0), int16(0));
        assertGt(out, 0, "asset!=tokenType (tokenType=0) branch taken");
    }

    // 4b) Hit max-loss path with asset != tokenType (tokenType==1 sub-branch)
    function test_Spread_MaxLoss_AssetMismatch_TokenType1Branch() public {
        uint64 pool = 1 + (10 << 48);
        // Puts (tokenType 1) but set asset=0 to force asset!=tokenType path
        TokenId t = PositionFactory.makeTwoLegs(
            pool,
            /*long put*/ 1,
            /*asset*/ 0,
            1,
            /*type*/ 1,
            int24(0),
            int24(600),
            /*short put*/ 1,
            /*asset*/ 0,
            0,
            /*type*/ 1,
            int24(300),
            int24(600)
        );
        uint256 out = E.computeSpread(t, uint128(5e9), 0, 1, int24(0), int16(0));
        assertGt(out, 0, "asset!=tokenType (tokenType=1) branch taken");
    }

    // 4b) Hit max-loss path with asset != tokenType (tokenType==1 sub-branch)
    function test_Spread_MaxLoss_SameAsset_TokenType1Branch() public {
        uint64 pool = 1 + (10 << 48);
        // Puts (tokenType 1) but set asset=0 to force asset!=tokenType path
        TokenId t = PositionFactory.makeTwoLegs(
            pool,
            /*long put*/ 1,
            /*asset*/ 1,
            1,
            /*type*/ 1,
            int24(0),
            int24(600),
            /*short put*/ 1,
            /*asset*/ 1,
            0,
            /*type*/ 1,
            int24(300),
            int24(600)
        );
        uint256 out = E.computeSpread(t, uint128(5e9), 0, 1, int24(0), int16(0));
        assertGt(out, 0, "asset!=tokenType (tokenType=1) branch taken");
    }

    // 5) A short option partnered with a loan has no composite: each leg reports its own requirement
    function test_LoanOptionPair_NoComposite_EachLegOwnRequirement() public {
        uint64 pool = 1 + (10 << 48);
        // Option leg (index 0) is SHORT call; partner (index 1) is LOAN (width=0, isLong=0), same tokenType
        TokenId t = PositionFactory.makeTwoLegs(
            pool,
            /*short call*/ 1,
            0,
            0,
            /*type*/ 0,
            int24(0),
            int24(600),
            /*loan*/ 1,
            0,
            0,
            /*type*/ 0,
            int24(0),
            int24(0)
        );
        uint128 size = 3e9;

        // Unpartnered requirements to compare sum
        uint256 a = E.reqSingleNoPartner(t, 0, size, int24(0), int16(0)); // short option
        uint256 b = E.reqSingleNoPartner(t, 1, size, int24(0), int16(0)); // loan

        // No loan/option composite: the partner path returns each leg's own requirement, so the pair sums to a + b
        uint256 partnerReq0 = E.reqSinglePartner(t, 0, size, int24(0), int16(0));
        uint256 partnerReq1 = E.reqSinglePartner(t, 1, size, int24(0), int16(0));
        assertEq(partnerReq0, a, "short option leg reports its own requirement");
        assertEq(partnerReq1, b, "loan leg reports its own requirement");
        assertEq(partnerReq0 + partnerReq1, a + b, "pair sums loan + option");
    }

    // -----------------------------------------------------------
    // Narrow legs and the flag-liquidation band (BUYER_COLLATERAL_RATIO / ONE_BPS ticks)
    // -----------------------------------------------------------

    /// @dev The band in ticks: a buyer ratio of 2% is 200 ticks.
    function _band() internal view returns (uint256) {
        return E.buyerCollateralRatioParam() / 1000;
    }

    /// @dev Requirement at tick 0 of a long token0 leg of `SIZE_NARROW` at `strike`, `width` tick spacings wide.
    function _longReq(int24 strike, int24 width) internal view returns (uint256) {
        TokenId t = PositionFactory.makeLeg(1 + (10 << 48), 0, 1, 0, 1, 0, 0, strike, width);
        return E.reqSingleNoPartner(t, 0, SIZE_NARROW, int24(0), int16(0));
    }

    uint128 internal constant SIZE_NARROW = 1e12;

    /// @notice A long leg requires the buyer ratio of its notional at every strike distance, on either side of the
    /// price, and at every width: there is no decay away from the strike.
    function test_LongRequirement_FlatAtEveryStrikeAndWidth() public view {
        int24 band = int24(int256(_band()));
        uint256 base = (uint256(SIZE_NARROW) * E.buyerCollateralRatioParam()) / DEC;

        // inside the band, a few bands away and far away, above and below the price (tick 0)
        int24[6] memory strikes = [
            band - 5,
            4 * band + 5,
            int24(20_000),
            -(band - 5),
            -(4 * band + 5),
            int24(-20_000)
        ];
        // one tick spacing, two bands, and a wide leg (in tick spacings of 10)
        int24[3] memory widths = [int24(1), (2 * band) / 10, int24(400)];
        for (uint256 i; i < strikes.length; ++i) {
            for (uint256 j; j < widths.length; ++j) {
                assertApproxEqAbs(
                    _longReq(strikes[i], widths[j]),
                    base,
                    1,
                    "long leg: the buyer ratio at every strike and width"
                );
            }
        }
    }

    /// @dev A call spread: long leg at `longStrike`, short leg at `shortStrike`, widths in tick spacings.
    function _callSpread(
        uint64 pool,
        int24 longStrike,
        int24 longWidth,
        int24 shortStrike,
        int24 shortWidth
    ) internal pure returns (TokenId) {
        return
            PositionFactory.makeTwoLegs(
                pool,
                1,
                0,
                1,
                0,
                longStrike,
                longWidth,
                1,
                0,
                0,
                0,
                shortStrike,
                shortWidth
            );
    }

    /// @dev Requirement at tick 0 of the call spread built by `_callSpread`, for `SIZE_NARROW`.
    function _spreadReq(
        uint64 pool,
        int24 longStrike,
        int24 longWidth,
        int24 shortStrike,
        int24 shortWidth
    ) internal view returns (uint256) {
        return
            E.computeSpread(
                _callSpread(pool, longStrike, longWidth, shortStrike, shortWidth),
                SIZE_NARROW,
                0,
                1,
                int24(0),
                int16(0)
            );
    }

    /// @notice A spread with a leg narrower than the band is charged a calendar term of ten bands (1.25 times the
    /// buyer ratio of notional) instead of its width difference, at any tick spacing: its long leg can be crossed alone
    /// inside the band, which the strike difference does not cover. Spreads with both legs at least a band wide
    /// keep the plain calendar term.
    function test_Spread_NarrowLeg_ChargedTenBands() public view {
        uint256 band = _band();
        uint256 extra = (uint256(SIZE_NARROW) * 10 * band) / 80_000;
        uint64 pool10 = 1 + (10 << 48);
        int24 bandWidth = int24(int256(band / 10));

        // both legs one spacing wide, strikes one spacing apart
        uint256 tight = _spreadReq(pool10, 85, 1, 95, 1);
        assertGe(tight, extra, "tight narrow spread: charged ten bands");
        assertGt(
            tight,
            (uint256(SIZE_NARROW) * band) / 10_000,
            "which covers a push across the band"
        );

        // one narrow leg is enough
        assertGe(_spreadReq(pool10, 85, 1, 95, bandWidth), extra, "narrow long, wide short");
        assertGe(_spreadReq(pool10, 85, bandWidth, 95, 1), extra, "wide long, narrow short");

        // both legs a band wide: the plain calendar term (zero here) plus the max loss, well under ten bands
        assertLt(
            _spreadReq(pool10, 85, bandWidth, 95, bandWidth),
            extra,
            "wide spread: not charged the narrow-leg term"
        );

        // tick spacing 5: same charge in ticks
        assertGe(
            _spreadReq(1 + (5 << 48), 85, 1, 90, 1),
            extra,
            "tick spacing 5: charged ten bands"
        );
        // tick spacing 60: ten bands rounded down to whole spacings
        assertGe(
            _spreadReq(1 + (60 << 48), 30, 1, 90, 1),
            (uint256(SIZE_NARROW) * ((10 * band) / 60) * 60) / 80_000,
            "tick spacing 60: charged ten bands, rounded to the spacing"
        );
    }

    /// @notice The narrow-leg charge is a floor, not a replacement: a narrow leg paired with a much wider one keeps
    /// its real width difference when that is the larger term. Narrowing the long leg of a 3,792-tick short from one
    /// band to 32 ticks widens the difference, so it must not lower the requirement.
    function test_Spread_NarrowLeg_KeepsLargerWidthDifference() public view {
        uint64 pool1 = 1 + (1 << 48);
        int24 band = int24(int256(_band()));
        // short leg 3,792 ticks wide at strike 0, long leg at strike 695, read inside the short's range
        uint256 narrowLong = _spreadReq(pool1, 695, 32, 0, 3792);
        uint256 bandWideLong = _spreadReq(pool1, 695, band, 0, 3792);
        assertGe(
            narrowLong,
            bandWideLong,
            "a narrower long leg does not lower the spread's requirement"
        );
    }
}
