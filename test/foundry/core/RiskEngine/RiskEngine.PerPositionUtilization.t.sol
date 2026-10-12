// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RiskEngineHarness} from "./RiskEngineHarness.sol";
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {TokenId} from "@types/TokenId.sol";
import {PositionBalance} from "@types/PositionBalance.sol";
import {PositionFactory} from "./helpers/PositionFactory.sol";

/// @title Per-position utilization pins
/// @notice Each position's collateral requirement is priced at that position's own utilization at mint.
///         A later mint at high utilization does not re-price earlier positions. The account-wide maximum
///         utilization is still returned by `_getTotalRequiredCollateral`, but only for the cross-buffer ramp.
contract RiskEnginePerPositionUtilization is Test {
    RiskEngineHarness internal E;

    uint64 constant POOL_ID = 1 + (10 << 48);
    uint128 constant SIZE = 1e12;
    uint16 constant LOW_UTIL = 5000; // 50%: below the 66.7% target -> seller ratio floor (20%)
    uint16 constant HIGH_UTIL = 8500; // 85%: on the ramp towards 100% at 90%

    LeftRightUnsigned internal constant ZERO = LeftRightUnsigned.wrap(0);

    function setUp() public {
        E = new RiskEngineHarness(10_000_000, 10_000_000);
    }

    /// @dev Single-leg short call (tokenType 0): collateral is required in token0, i.e. the right slot, and scales
    /// with utilization through _sellCollateralRatio.
    function _shortCall(uint256 legIndex) internal pure returns (TokenId) {
        return PositionFactory.makeLeg(POOL_ID, legIndex, 1, 0, 0, 0, 0, int24(0), int24(1000));
    }

    function _single(
        TokenId t,
        uint16 util
    ) internal view returns (LeftRightUnsigned req, PositionBalance globalUtil) {
        TokenId[] memory ids = new TokenId[](1);
        ids[0] = t;
        PositionBalance[] memory bals = new PositionBalance[](1);
        bals[0] = PositionFactory.posBalance(SIZE, util, util);
        (req, , globalUtil) = E.totalRequiredCollateral(bals, ids, int24(0), ZERO);
    }

    function _pair(
        uint16 utilA,
        uint16 utilB
    )
        internal
        view
        returns (
            LeftRightUnsigned total,
            PositionBalance globalUtil,
            LeftRightUnsigned[] memory perPosition
        )
    {
        TokenId[] memory ids = new TokenId[](2);
        ids[0] = _shortCall(0);
        ids[1] = _shortCall(0);
        PositionBalance[] memory bals = new PositionBalance[](2);
        bals[0] = PositionFactory.posBalance(SIZE, utilA, utilA);
        bals[1] = PositionFactory.posBalance(SIZE, utilB, utilB);
        (total, , globalUtil) = E.totalRequiredCollateral(bals, ids, int24(0), ZERO);
        perPosition = E.getPerPositionCollateralRequirements(bals, ids, int24(0));
    }

    /// @notice Sanity: the ramp is live, so a position minted at 85% requires more than one minted at 50%.
    function test_requirementRisesWithOwnUtilization() public view {
        (LeftRightUnsigned low, ) = _single(_shortCall(0), LOW_UTIL);
        (LeftRightUnsigned high, ) = _single(_shortCall(0), HIGH_UTIL);
        assertGt(high.rightSlot(), low.rightSlot(), "85% mint requires more than 50% mint");
        assertGt(low.rightSlot(), 0, "non-trivial requirement");
    }

    /// @notice A high-utilization mint does not re-price the low-utilization position next to it.
    function test_laterHighUtilMintDoesNotRepriceEarlierPosition() public view {
        (LeftRightUnsigned low, ) = _single(_shortCall(0), LOW_UTIL);
        (LeftRightUnsigned high, ) = _single(_shortCall(0), HIGH_UTIL);
        (LeftRightUnsigned total, , LeftRightUnsigned[] memory per) = _pair(LOW_UTIL, HIGH_UTIL);

        assertEq(
            per[0].rightSlot(),
            low.rightSlot(),
            "low-util position priced at its own utilization"
        );
        assertEq(
            per[1].rightSlot(),
            high.rightSlot(),
            "high-util position priced at its own utilization"
        );
        assertEq(
            total.rightSlot(),
            low.rightSlot() + high.rightSlot(),
            "total is the sum of own-utilization requirements"
        );

        // Under the former account-maximum rule both legs would have been priced at 85%.
        assertLt(total.rightSlot(), 2 * high.rightSlot(), "not priced at the account maximum");
    }

    /// @notice Order of positions in the list does not matter.
    function test_orderIndependent() public view {
        (LeftRightUnsigned a, , ) = _pair(LOW_UTIL, HIGH_UTIL);
        (LeftRightUnsigned b, , ) = _pair(HIGH_UTIL, LOW_UTIL);
        assertEq(a.leftSlot(), b.leftSlot());
        assertEq(a.rightSlot(), b.rightSlot());
    }

    /// @notice The per-position view reconciles with the solvency path for any pair of utilizations.
    function testFuzz_perPositionSumsToTotal(uint16 utilA, uint16 utilB) public view {
        utilA = uint16(bound(utilA, 0, 10_000));
        utilB = uint16(bound(utilB, 0, 10_000));
        (LeftRightUnsigned total, , LeftRightUnsigned[] memory per) = _pair(utilA, utilB);
        assertEq(total.leftSlot(), per[0].leftSlot() + per[1].leftSlot(), "token1 reconciles");
        assertEq(total.rightSlot(), per[0].rightSlot() + per[1].rightSlot(), "token0 reconciles");
    }

    /// @notice Adding a position never changes what the existing positions require.
    function testFuzz_requirementIsAdditiveAcrossMints(uint16 utilA, uint16 utilB) public view {
        utilA = uint16(bound(utilA, 0, 10_000));
        utilB = uint16(bound(utilB, 0, 10_000));
        (LeftRightUnsigned a, ) = _single(_shortCall(0), utilA);
        (LeftRightUnsigned b, ) = _single(_shortCall(0), utilB);
        (LeftRightUnsigned total, , ) = _pair(utilA, utilB);
        assertEq(total.leftSlot(), a.leftSlot() + b.leftSlot(), "token1 additive");
        assertEq(total.rightSlot(), a.rightSlot() + b.rightSlot(), "token0 additive");
    }

    /// @notice The account-wide maximum is still computed and returned, for the cross-buffer ramp.
    function test_globalUtilizationStillReturnedAsMaximum() public view {
        (, PositionBalance g, ) = _pair(LOW_UTIL, HIGH_UTIL);
        assertEq(g.utilization0(), int256(uint256(HIGH_UTIL)), "max utilization0");
        assertEq(g.utilization1(), int256(uint256(HIGH_UTIL)), "max utilization1");
        (, PositionBalance g2, ) = _pair(HIGH_UTIL, LOW_UTIL);
        assertEq(g2.utilization0(), int256(uint256(HIGH_UTIL)), "order independent");
    }

    /// @notice Invariant: for any list of up to six positions, the total requirement is exactly the sum of the
    ///         single-position requirements, i.e. no position's utilization influences another's.
    function testFuzz_additivityAcrossManyPositions(
        uint16[6] memory utils,
        uint8 nSeed
    ) public view {
        uint256 n = bound(nSeed, 1, 6);
        TokenId[] memory ids = new TokenId[](n);
        PositionBalance[] memory bals = new PositionBalance[](n);
        uint256 sumRight;
        uint256 sumLeft;
        for (uint256 i; i < n; ++i) {
            uint16 u = uint16(bound(utils[i], 0, 10_000));
            ids[i] = _shortCall(0);
            bals[i] = PositionFactory.posBalance(SIZE, u, u);
            (LeftRightUnsigned single, ) = _single(_shortCall(0), u);
            sumRight += single.rightSlot();
            sumLeft += single.leftSlot();
        }
        (LeftRightUnsigned total, , ) = E.totalRequiredCollateral(bals, ids, int24(0), ZERO);
        assertEq(total.rightSlot(), sumRight, "token0 additive over n positions");
        assertEq(total.leftSlot(), sumLeft, "token1 additive over n positions");
    }
}
