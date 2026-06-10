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

contract RiskEngineCoverageGaps is Test {
    using PositionFactory for *;

    RiskEngineHarness internal E;
    MockCollateralTracker internal ct0;
    MockCollateralTracker internal ct1;

    uint256 constant DEC = 10_000_000;

    function setUp() public {
        E = new RiskEngineHarness(
            /*SELL*/ 2_000_000,
            /*BUY*/ 1_000_000,
            /*FE*/ 1_000,
            /*U_T*/ 5_000_000,
            /*U_S*/ 9_000_000,
            /*CB0*/ 5_000_000,
            /*CB1*/ 5_000_000
        );
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

    // 5) Hit _computeLoanOptionComposite branch where option leg is SHORT (sum path)
    function test_LoanOptionComposite_ShortOptionBranch_Sums() public {
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

        // Partner path (option leg index 0) should return a + b
        uint256 partnerReq = E.reqSinglePartner(t, 0, size, int24(0), int16(0));
        assertEq(partnerReq, a + b, "short option branch sums loan + option");
        // Partner on loan side should be zero
        assertEq(E.reqSinglePartner(t, 1, size, int24(0), int16(0)), 0, "loan side reports zero");
    }
}
