// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RiskEngineHarness} from "./RiskEngineHarness.sol";
import {MockCollateralTracker} from "./mocks/MockCollateralTracker.sol";
import {PositionFactory} from "./helpers/PositionFactory.sol";
import {CollateralTrackerV2} from "@contracts/CollateralTracker.sol";
import {Errors} from "@libraries/Errors.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {PositionBalance} from "@types/PositionBalance.sol";
import {TokenId} from "@types/TokenId.sol";

/// @notice Unit tests for the uint256 aggregation of collateral requirements and the per-token loan cap.
/// @dev Per-position requirements and credits are summed in uint256. A total that does not fit in uint128
/// saturates at `type(uint128).max` so the account reads as insolvent; the per-token loan total is bounded by
/// `type(int128).max` and anything above it reverts with `PositionTooLarge`.
contract RiskEngineMarginOverflowTest is Test {
    RiskEngineHarness internal E;
    MockCollateralTracker internal ct0;
    MockCollateralTracker internal ct1;

    address internal constant USER = address(0xA11CE);
    uint64 internal constant POOL_ID = 1 + (10 << 48); // tickSpacing = 10
    uint16 internal constant SATURATED_UTIL = 10_000; // loan maintenance margin = 25% at saturation (DECIMALS / LOAN_MARGIN_DIVISOR)
    uint256 internal constant DEC = 10_000_000;
    uint256 internal constant LOAN_MARGIN_DIVISOR = 4;
    uint256 internal constant TWO_POW_128 = uint256(1) << 128;
    uint256 internal constant INT128_MAX = uint256(uint128(type(int128).max));

    LeftRightUnsigned internal constant ZERO = LeftRightUnsigned.wrap(0);

    function setUp() public {
        E = new RiskEngineHarness(5_000_000, 5_000_000);
        ct0 = new MockCollateralTracker();
        ct1 = new MockCollateralTracker();
        ct0.setGlobal(1_000_000 ether, 1_000_000 ether);
        ct1.setGlobal(1_000_000 ether, 1_000_000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Short width-0 leg on token0 = a token0 loan.
    function _loan(int24 strike) internal pure returns (TokenId) {
        return PositionFactory.makeLeg(POOL_ID, 0, 1, 0, 0, 0, 0, strike, 0);
    }

    /// @notice Long width-0 leg on token0 = a token0 credit.
    function _credit(int24 strike) internal pure returns (TokenId) {
        return PositionFactory.makeLeg(POOL_ID, 0, 1, 0, 1, 0, 0, strike, 0);
    }

    function _notional(TokenId id, uint128 size) internal pure returns (uint256) {
        return PanopticMath.getAmountsMoved(id, size, 0, false).rightSlot();
    }

    /// @notice Loan requirement at saturation: notional * (1 + 1/LOAN_MARGIN_DIVISOR), rounded up per leg.
    function _loanReq(TokenId id, uint128 size) internal pure returns (uint256) {
        return (_notional(id, size) * (DEC + DEC / LOAN_MARGIN_DIVISOR) + DEC - 1) / DEC;
    }

    function _two(
        TokenId a,
        uint128 sizeA,
        TokenId b,
        uint128 sizeB
    ) internal pure returns (TokenId[] memory ids, PositionBalance[] memory bals) {
        ids = new TokenId[](2);
        bals = new PositionBalance[](2);
        ids[0] = a;
        ids[1] = b;
        bals[0] = PositionFactory.posBalance(sizeA, SATURATED_UTIL, SATURATED_UTIL);
        bals[1] = PositionFactory.posBalance(sizeB, SATURATED_UTIL, SATURATED_UTIL);
    }

    function _margin(
        TokenId[] memory ids,
        PositionBalance[] memory bals,
        LeftRightUnsigned longPremia
    ) internal view returns (LeftRightUnsigned td0, LeftRightUnsigned td1) {
        (td0, td1, ) = E.getMarginInternal(
            USER,
            bals,
            int24(0),
            ids,
            ZERO,
            longPremia,
            CollateralTrackerV2(address(ct0)),
            CollateralTrackerV2(address(ct1))
        );
    }

    function _solvent(
        TokenId[] memory ids,
        PositionBalance[] memory bals,
        LeftRightUnsigned longPremia
    ) internal view returns (bool) {
        return
            E.isAccountSolvent(
                bals,
                ids,
                int24(0),
                USER,
                ZERO,
                longPremia,
                CollateralTrackerV2(address(ct0)),
                CollateralTrackerV2(address(ct1)),
                E.DECIMALS()
            );
    }

    /*//////////////////////////////////////////////////////////////
                        REQUIREMENT AGGREGATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Two loans under the loan cap plus long premia push the true requirement past 2^128.
    /// The engine saturates the requirement at uint128.max and reports the account insolvent.
    function test_requirement_saturatesInsteadOfWrapping() public {
        // 2 x 0.245 * 2^128 of loans: each requirement is 1.25x notional at saturation, so the loan
        // part of the requirement is ~0.61 * 2^128, and the loan total stays under int128.max.
        uint128 size = uint128((TWO_POW_128 * 245) / 1000);
        (TokenId[] memory ids, PositionBalance[] memory bals) = _two(
            _loan(-300000),
            size,
            _loan(-299990),
            size
        );
        uint256 notional = _notional(ids[0], size) + _notional(ids[1], size);
        assertLe(notional, INT128_MAX, "setup: loan total must stay under the loan cap");

        // premia owed adds another 0.45 * 2^128 to the requirement, pushing the true total past 2^128
        uint128 premia = uint128((TWO_POW_128 * 45) / 100);
        LeftRightUnsigned longPremia = LeftRightUnsigned.wrap(premia);

        // the borrower holds exactly the loan proceeds, nothing else
        ct0.setUser(USER, notional, 0, notional);

        uint256 trueRequirement = _loanReq(ids[0], size) + _loanReq(ids[1], size) + premia;
        assertGt(trueRequirement, type(uint128).max, "setup: true requirement must exceed 2^128");
        assertLt(
            trueRequirement % TWO_POW_128,
            notional,
            "setup: requirement mod 2^128 is below the balance"
        );

        (LeftRightUnsigned td0, ) = _margin(ids, bals, longPremia);
        assertEq(td0.leftSlot(), type(uint128).max, "requirement saturates at uint128.max");
        assertEq(td0.rightSlot(), notional, "balance is the loan proceeds");
        assertFalse(_solvent(ids, bals, longPremia), "account must be insolvent");
    }

    /// @notice Per-position requirements are summed, not wrapped, when the total still fits.
    function testFuzz_requirement_isExactSumOfPositions(uint128 sizeA, uint128 sizeB) public {
        sizeA = uint128(bound(sizeA, 1, uint128(TWO_POW_128 / 8)));
        sizeB = uint128(bound(sizeB, 1, uint128(TWO_POW_128 / 8)));

        (TokenId[] memory ids, PositionBalance[] memory bals) = _two(
            _loan(-300000),
            sizeA,
            _loan(-299990),
            sizeB
        );

        TokenId[] memory one = new TokenId[](1);
        PositionBalance[] memory oneBal = new PositionBalance[](1);

        one[0] = ids[0];
        oneBal[0] = bals[0];
        (LeftRightUnsigned a, ) = _margin(one, oneBal, ZERO);

        one[0] = ids[1];
        oneBal[0] = bals[1];
        (LeftRightUnsigned b, ) = _margin(one, oneBal, ZERO);

        (LeftRightUnsigned both, ) = _margin(ids, bals, ZERO);
        assertEq(
            both.leftSlot(),
            uint256(a.leftSlot()) + uint256(b.leftSlot()),
            "two-position requirement equals the sum of each"
        );
    }

    /*//////////////////////////////////////////////////////////////
                              LOAN CAP
    //////////////////////////////////////////////////////////////*/

    /// @notice The per-token loan total may not exceed int128.max, so the CollateralTracker's int128
    /// net-borrow accounting always fits: two loans of 0.255 * 2^128 each are rejected.
    function test_loanCap_revertsAboveInt128Max() public {
        uint128 size = uint128((TWO_POW_128 * 51) / 200);
        (TokenId[] memory ids, PositionBalance[] memory bals) = _two(
            _loan(-300000),
            size,
            _loan(-299990),
            size
        );
        uint256 notional = _notional(ids[0], size) + _notional(ids[1], size);
        assertGt(notional, INT128_MAX, "setup: loan total must exceed int128.max");
        assertLe(_loanReq(ids[0], size), type(uint128).max, "setup: each requirement fits");

        ct0.setUser(USER, notional, 0, notional);

        vm.expectRevert(Errors.PositionTooLarge.selector);
        this._marginExternal(ids, bals);

        vm.expectRevert(Errors.PositionTooLarge.selector);
        this._solventExternal(ids, bals);
    }

    /// @notice A loan total at or below the cap is accepted.
    function test_loanCap_allowsUpToInt128Max() public {
        uint128 size = uint128(INT128_MAX / 2) - 100; // leave room for round-up
        (TokenId[] memory ids, PositionBalance[] memory bals) = _two(
            _loan(-300000),
            size,
            _loan(-299990),
            size
        );
        uint256 notional = _notional(ids[0], size) + _notional(ids[1], size);
        assertLe(notional, INT128_MAX, "setup: loan total must be under the cap");

        ct0.setUser(USER, notional, 0, notional);
        (LeftRightUnsigned td0, ) = _margin(ids, bals, ZERO);
        assertEq(
            td0.leftSlot(),
            _loanReq(ids[0], size) + _loanReq(ids[1], size),
            "requirement is 1.25x notional at saturation"
        );
    }

    // external wrappers so expectRevert can target the call
    function _marginExternal(TokenId[] memory ids, PositionBalance[] memory bals) external view {
        _margin(ids, bals, ZERO);
    }

    function _solventExternal(TokenId[] memory ids, PositionBalance[] memory bals) external view {
        _solvent(ids, bals, ZERO);
    }

    /*//////////////////////////////////////////////////////////////
                               CREDITS
    //////////////////////////////////////////////////////////////*/

    /// @notice Credits are summed across positions.
    function testFuzz_credits_summedAcrossPositions(uint128 sizeA, uint128 sizeB) public {
        sizeA = uint128(bound(sizeA, 1, uint128(TWO_POW_128 / 8)));
        sizeB = uint128(bound(sizeB, 1, uint128(TWO_POW_128 / 8)));

        (TokenId[] memory ids, PositionBalance[] memory bals) = _two(
            _credit(-300000),
            sizeA,
            _credit(-299990),
            sizeB
        );

        ct0.setUser(USER, 0, 0, 0);

        // credits add to the balance side of tokenData
        (LeftRightUnsigned td0, ) = _margin(ids, bals, ZERO);
        assertEq(
            td0.rightSlot(),
            _notional(ids[0], sizeA) + _notional(ids[1], sizeB),
            "credits from both positions count toward the balance"
        );
    }

    /// @notice Credits saturate rather than revert when their total exceeds uint128.
    function test_credits_saturateAboveUint128() public {
        uint128 size = type(uint128).max;
        (TokenId[] memory ids, PositionBalance[] memory bals) = _two(
            _credit(-300000),
            size,
            _credit(-299990),
            size
        );
        assertGt(
            _notional(ids[0], size) + _notional(ids[1], size),
            type(uint128).max,
            "setup: credit total must exceed 2^128"
        );

        ct0.setUser(USER, 0, 0, 0);
        (LeftRightUnsigned td0, ) = _margin(ids, bals, ZERO);
        assertEq(td0.rightSlot(), type(uint128).max, "credits saturate at uint128.max");
    }
}
