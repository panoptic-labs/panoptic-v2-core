// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RiskEngineHarness} from "./RiskEngineHarness.sol";
import {RiskEngineParams} from "../../testUtils/RiskEngineParams.sol";
import {MockCollateralTracker} from "./mocks/MockCollateralTracker.sol";
import {PositionFactory} from "./helpers/PositionFactory.sol";
import {CollateralTrackerV2} from "@contracts/CollateralTracker.sol";
import {LeftRightSigned, LeftRightUnsigned} from "@types/LeftRight.sol";
import {Math} from "@libraries/Math.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";
import {TokenId} from "@types/TokenId.sol";

/// @notice Stands in for the PanopticPool calling `isAccountSolvent`: the engine reads the caller's current tick.
contract MockPoolTick {
    int24 public getCurrentTick;

    function set(int24 tick) external {
        getCurrentTick = tick;
    }
}

/// @notice Owed interest in `_getMargin`: the balance in the interest token pays what it can, and the
/// uncollected remainder stays in the requirement. Previously the requirement term was capped at the balance,
/// so an account with (near) zero balance in the interest token dropped its owed interest from the solvency
/// check entirely and could never be liquidated for it, while the vault kept accruing the receivable.
///
/// Interest can only be collected in its own token, so the remainder is not cross-marginable either: once it
/// exceeds one mint commission on the token's interest-bearing principal (`netBorrows * notionalFee`), `_getMargin`
/// sets the interest shortfall flag in the positionSize slot of `globalUtilizations` (bit 0 = token0,
/// bit 1 = token1). `isAccountSolvent` then returns false under every buffered check, whatever the other token
/// holds. With no buffer (the check `dispatchFrom` makes before a liquidation) it returns false only at ticks
/// within `BUYER_COLLATERAL_RATIO / ONE_BPS` ticks of the calling pool's current tick; further away the flag is
/// ignored and the collateral decides, so a flag-only account cannot be liquidated through a displaced price.
/// A caller that is not a pool gets false.
///
/// The same no-buffer check gives an account that owes long premium a pass at ticks that far or further from the
/// pool's current tick, flagged or not: a liquidation burns its long legs at the current tick, so it is refused while
/// the pool's tick is displaced from the oracle's. Accounts that owe no long premium are judged on collateral at any
/// displacement.
///
/// When the flag is the only reason the account is liquidatable (it still passes the cross-token test at `atTick`
/// with no buffer), `_getMargin` replaces each requirement by `_bonusRequirement`, so the per-token bonus floor is
/// exactly twice the uncollected interest instead of `MAX_BONUS` of the requirement (raising the requirement if premia
/// or credits already cover it), and zero in a token without a shortfall.
contract RiskEngineInterestShortfallTest is Test {
    using PositionBalanceLibrary for PositionBalance;

    RiskEngineHarness internal E;
    MockCollateralTracker internal ct0;
    MockCollateralTracker internal ct1;

    address internal constant USER = address(0xA11CE);
    uint64 internal constant POOL_ID = 1 + (10 << 48);
    uint128 internal constant X = 1_000_000; // token0 loan
    LeftRightUnsigned internal constant ZERO = LeftRightUnsigned.wrap(0);

    TokenId[] internal ids;
    PositionBalance[] internal bals;
    MockPoolTick internal POOL;

    function setUp() public {
        POOL = new MockPoolTick();
        E = new RiskEngineHarness(5_000_000, 5_000_000);
        ct0 = new MockCollateralTracker();
        ct1 = new MockCollateralTracker();
        ct0.setGlobal(1e27, 1e27);
        ct1.setGlobal(1e27, 1e27);
        // token0 loan, so interest accrues in token0
        ids.push(PositionFactory.makeLeg(POOL_ID, 0, 1, 0, 0, 0, 0, 0, 0));
        bals.push(PositionFactory.posBalance(X, 0, 0));
        ct0.setNetBorrows(USER, int128(X));
    }

    function _margin() internal view returns (LeftRightUnsigned td0, LeftRightUnsigned td1) {
        (td0, td1, ) = E.getMarginInternal(
            USER,
            bals,
            int24(0),
            ids,
            ZERO,
            ZERO,
            CollateralTrackerV2(address(ct0)),
            CollateralTrackerV2(address(ct1))
        );
    }

    function _solvent() internal view returns (bool) {
        return
            E.isAccountSolvent(
                bals,
                ids,
                int24(0),
                USER,
                ZERO,
                ZERO,
                CollateralTrackerV2(address(ct0)),
                CollateralTrackerV2(address(ct1)),
                E.DECIMALS()
            );
    }

    function _solventAt(int24 tick, uint256 buffer) internal view returns (bool) {
        return
            E.isAccountSolvent(
                bals,
                ids,
                tick,
                USER,
                ZERO,
                ZERO,
                CollateralTrackerV2(address(ct0)),
                CollateralTrackerV2(address(ct1)),
                buffer
            );
    }

    /// @notice `isAccountSolvent` at `atTick`, as called by a pool whose current tick is `poolTick`.
    function _solventFromPool(
        int24 atTick,
        int24 poolTick,
        uint256 buffer
    ) internal returns (bool) {
        POOL.set(poolTick);
        vm.prank(address(POOL));
        return
            E.isAccountSolvent(
                bals,
                ids,
                atTick,
                USER,
                ZERO,
                ZERO,
                CollateralTrackerV2(address(ct0)),
                CollateralTrackerV2(address(ct1)),
                buffer
            );
    }

    /// @notice Same, for an account that owes `longPrem` on its long legs.
    function _solventFromPool(
        int24 atTick,
        int24 poolTick,
        uint256 buffer,
        LeftRightUnsigned longPrem
    ) internal returns (bool) {
        POOL.set(poolTick);
        vm.prank(address(POOL));
        return
            E.isAccountSolvent(
                bals,
                ids,
                atTick,
                USER,
                ZERO,
                longPrem,
                CollateralTrackerV2(address(ct0)),
                CollateralTrackerV2(address(ct1)),
                buffer
            );
    }

    /// @notice Half-width of the band around the pool's current tick in which the flag alone fails solvency.
    function _band() internal view returns (int24) {
        return int24(int256(E.buyerCollateralRatioParam() / 1000));
    }

    /// @notice Interest shortfall flag bits (positionSize slot of the third `_getMargin` return).
    function _flag() internal view returns (uint256) {
        (, , PositionBalance g) = E.getMarginInternal(
            USER,
            bals,
            int24(0),
            ids,
            ZERO,
            ZERO,
            CollateralTrackerV2(address(ct0)),
            CollateralTrackerV2(address(ct1))
        );
        return g.positionSize();
    }

    function _fee() internal view returns (uint256) {
        return uint256(RiskEngineParams.blueChip().notionalFee) * 1000;
    }

    /// @notice Tolerance for token `t`: one mint commission on the tracker's `netBorrows` in that token.
    function _tolerance(uint256 t) internal view returns (uint256) {
        (, int128 nb) = (t == 0 ? ct0 : ct1).interestState(USER);
        if (nb <= 0) return 0;
        return (uint256(uint128(nb)) * _fee()) / E.DECIMALS();
    }

    /// @notice Smallest token1 deposit that makes the account solvent with no interest owed.
    function _token1Boundary(uint256 balance0) internal returns (uint256 hi) {
        ct0.setUser(USER, balance0, 0, balance0);
        (LeftRightUnsigned r0, ) = _margin();
        uint256 lo = r0.leftSlot();
        hi = 10 * lo;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            ct1.setUser(USER, mid, 0, mid);
            if (_solvent()) hi = mid;
            else lo = mid;
        }
    }

    /// @notice Interest covered by the balance: balance is reduced, requirement unchanged.
    function test_interestWithinBalance_paidFromBalance() public {
        ct0.setUser(USER, 0, 0, 0);
        (LeftRightUnsigned ref0, ) = _margin();

        ct0.setUser(USER, 10_000, 4_000, 10_000);
        (LeftRightUnsigned td0, ) = _margin();
        assertEq(td0.rightSlot(), 6_000, "balance minus interest");
        assertEq(td0.leftSlot(), ref0.leftSlot(), "nothing added to the requirement");
    }

    /// @notice Zero balance in the interest token: the whole owed interest is in the requirement.
    function test_zeroBalance_fullInterestInRequirement() public {
        ct0.setUser(USER, 0, 0, 0);
        (LeftRightUnsigned ref0, ) = _margin();

        uint256 I = 50_000;
        ct0.setUser(USER, 0, I, 0);
        (LeftRightUnsigned td0, ) = _margin();
        assertEq(td0.rightSlot(), 0, "balance stays zero");
        assertEq(td0.leftSlot(), ref0.leftSlot() + I, "requirement includes all owed interest");
    }

    /// @notice Balance below the interest: balance is exhausted and the remainder is in the requirement.
    function test_partialBalance_remainderInRequirement() public {
        ct0.setUser(USER, 0, 0, 0);
        (LeftRightUnsigned ref0, ) = _margin();

        uint256 B = 1_000;
        uint256 I = 50_000;
        ct0.setUser(USER, B, I, B);
        (LeftRightUnsigned td0, ) = _margin();
        assertEq(td0.rightSlot(), 0, "balance exhausted");
        assertEq(td0.leftSlot(), ref0.leftSlot() + (I - B), "requirement includes I - B");
    }

    /// @notice The effective charge is the owed interest, never 2B (old double count) and never capped at B.
    function testFuzz_effectiveCharge_isOwedInterest(uint128 B, uint128 I) public {
        B = uint128(bound(B, 0, type(uint64).max));
        I = uint128(bound(I, 0, type(uint64).max));
        ct0.setUser(USER, 0, 0, 0);
        (LeftRightUnsigned ref0, ) = _margin();

        ct0.setUser(USER, B, I, B);
        (LeftRightUnsigned td0, ) = _margin();
        uint256 charge = (B - td0.rightSlot()) + (td0.leftSlot() - ref0.leftSlot());
        assertEq(charge, I, "balance drop + requirement rise == owed interest");
    }

    /// @notice An account funded in the other token becomes liquidatable once the uncollected interest
    /// exceeds the tolerance, however much cross collateral it holds: the trigger is `B + tolerance + 1`,
    /// the same with 2% headroom and with 3x the collateral. Under the capped rule it stayed solvent at any
    /// interest level; under the remainder-only rule it depended on the headroom.
    function test_crossCollateralized_becomesInsolventAsInterestGrows() public {
        uint256 B = 1_000; // token0 dust
        uint256 tol = _tolerance(0);
        uint256 boundary = _token1Boundary(B);
        uint256 D1 = (boundary * 102) / 100; // 2% headroom
        ct1.setUser(USER, D1, 0, D1);

        ct0.setUser(USER, B, 0, B);
        assertTrue(_solvent(), "solvent with no interest");

        ct0.setUser(USER, B, B, B);
        assertTrue(_solvent(), "interest paid from the dust: still solvent");

        // find the smallest I that makes the account insolvent
        uint256 lo = B;
        uint256 hi = X;
        ct0.setUser(USER, B, hi, B);
        assertFalse(_solvent(), "insolvent once the owed interest rivals the loan");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            ct0.setUser(USER, B, mid, B);
            if (_solvent()) lo = mid;
            else hi = mid;
        }
        assertEq(hi, B + tol + 1, "trigger is the dust plus the tolerance");
        assertGt(tol, 0, "setup: tolerance is positive");
        assertLt(hi, X / 10, "trigger is a small fraction of the loan");

        // more cross collateral does not move the trigger: the remainder is not cross-marginable
        ct1.setUser(USER, 3 * boundary, 0, 3 * boundary);
        ct0.setUser(USER, B, hi, B);
        assertFalse(_solvent(), "ample cross collateral does not cover uncollected interest");
        ct0.setUser(USER, B, hi - 1, B);
        assertTrue(_solvent(), "one wei below the trigger is still solvent");
    }

    /*//////////////////////////////////////////////////////////////
                        INTEREST SHORTFALL FLAG
    //////////////////////////////////////////////////////////////*/

    /// @notice Interest covered by the balance: no flag, whatever the size of the interest.
    function test_flag_notSet_whenBalanceCoversInterest() public {
        ct0.setUser(USER, 10_000, 10_000, 10_000);
        assertEq(_flag(), 0, "interest == balance: no shortfall");
        ct0.setUser(USER, 10_000_000, 9_999_999, 10_000_000);
        assertEq(_flag(), 0, "large interest fully covered: no shortfall");
    }

    /// @notice Shortfall at or below the tolerance: no flag; one wei above: flagged.
    function test_flag_thresholdIsTolerance() public {
        uint256 tol = _tolerance(0);
        uint256 B = 1_000;

        ct0.setUser(USER, B, B + tol, B);
        assertEq(_flag(), 0, "remainder == tolerance: not flagged");
        ct0.setUser(USER, B, B + tol + 1, B);
        assertEq(_flag(), 1, "remainder == tolerance + 1: flagged (bit 0)");

        ct0.setUser(USER, 0, tol, 0);
        assertEq(_flag(), 0, "zero balance, remainder == tolerance: not flagged");
        ct0.setUser(USER, 0, tol + 1, 0);
        assertEq(_flag(), 1, "zero balance, remainder == tolerance + 1: flagged");
    }

    /// @notice The tolerance does not depend on the collateral requirement: adding a position that owes no
    /// interest raises the requirement and leaves the flag threshold where it was.
    function test_flag_toleranceIndependentOfRequirement() public {
        uint256 tol = _tolerance(0);
        ct0.setUser(USER, 0, tol, 0);
        (LeftRightUnsigned reqBefore, ) = _margin();
        assertEq(_flag(), 0, "lone loan, remainder == tolerance: not flagged");
        ct0.setUser(USER, 0, tol + 1, 0);
        assertEq(_flag(), 1, "lone loan, remainder == tolerance + 1: flagged");

        // a wide OTM short in token0: large requirement, same principal
        ids.push(PositionFactory.makeLeg(POOL_ID, 0, 1, 0, 0, 0, 0, 5_000, 200));
        bals.push(PositionFactory.posBalance(10 * X, 0, 0));
        ct0.setUser(USER, 0, tol, 0);
        (LeftRightUnsigned reqAfter, ) = _margin();
        assertGt(
            reqAfter.leftSlot(),
            reqBefore.leftSlot(),
            "setup: the short raised the requirement"
        );
        assertEq(_flag(), 0, "with the short, remainder == tolerance: still not flagged");
        ct0.setUser(USER, 0, tol + 1, 0);
        assertEq(_flag(), 1, "with the short, remainder == tolerance + 1: still flagged");
    }

    /// @notice A flagged account fails every buffered check, and fails the no-buffer check at ticks inside the band
    /// around the calling pool's current tick, whatever the other token holds. At or beyond the band the flag is
    /// ignored and the collateral decides, so every tick `dispatchFrom` checks must be near the current tick for
    /// the flag to liquidate.
    function test_flag_failsSolvency_bufferedAlways_noBufferInsideBand() public {
        uint256 tol = _tolerance(0);
        ct1.setUser(USER, 1e24, 0, 1e24); // vast token1 collateral
        ct0.setUser(USER, 0, tol + 1, 0);
        assertEq(_flag(), 1, "setup: flagged");

        int24 band = _band();
        assertEq(band, 200, "blue chip: a 2% buyer ratio is a 200-tick band");
        uint256 D = E.DECIMALS();
        uint256 buffered = (D * 1_075) / 1_000;

        int24[3] memory poolTicks = [int24(0), int24(1_000), int24(-100_000)];
        for (uint256 i; i < poolTicks.length; ++i) {
            int24 p = poolTicks[i];
            // buffered (mint, burn, withdraw) and sub-unit buffers: fail wherever the checked tick is
            assertFalse(_solventFromPool(p, p, buffered), "buffered: fails at the pool tick");
            assertFalse(
                _solventFromPool(p + 10 * band, p, buffered),
                "buffered: fails away from it"
            );
            assertFalse(_solventFromPool(p + 10 * band, p, D / 2), "any other buffer: fails");
            // no buffer, inside the band
            assertFalse(_solventFromPool(p, p, D), "no buffer: fails at the pool tick");
            assertFalse(
                _solventFromPool(p + band - 1, p, D),
                "no buffer: fails just inside, above"
            );
            assertFalse(
                _solventFromPool(p - band + 1, p, D),
                "no buffer: fails just inside, below"
            );
            // no buffer, at the band and beyond: the collateral decides
            assertTrue(
                _solventFromPool(p + band, p, D),
                "no buffer: flag ignored at the band, above"
            );
            assertTrue(
                _solventFromPool(p - band, p, D),
                "no buffer: flag ignored at the band, below"
            );
            assertTrue(_solventFromPool(p + 10 * band, p, D), "no buffer: flag ignored far away");
        }

        // the same account one wei under the tolerance is solvent everywhere
        ct0.setUser(USER, 0, tol, 0);
        for (uint256 i; i < poolTicks.length; ++i) {
            assertTrue(
                _solventFromPool(poolTicks[i], poolTicks[i], D),
                "under the tolerance: solvent"
            );
        }
    }

    /// @notice Outside the band a flagged account that is also short of collateral still fails: only the flag is
    /// ignored there.
    function test_flag_outsideBand_crossInsolventStillFails() public {
        uint256 tol = _tolerance(0);
        ct1.setUser(USER, 1, 0, 1); // no collateral to speak of
        ct0.setUser(USER, 0, tol + 1, 0);
        assertEq(_flag(), 1, "setup: flagged");
        int24 band = _band();
        assertFalse(_solventFromPool(0, 0, E.DECIMALS()), "inside the band: fails");
        assertFalse(_solventFromPool(10 * band, 0, E.DECIMALS()), "outside the band: still fails");
    }

    /// @notice An account that is short of collateral and owes long premium reads solvent, with no buffer, at ticks
    /// a band or more from the calling pool's current tick, so `dispatchFrom` cannot liquidate it at a displaced
    /// price. Inside the band, under a buffer, without long premium, or for a caller that is not a pool, its
    /// collateral decides.
    function test_displacedPrice_longPremiumOwed_readsSolventAwayFromPoolTick() public {
        ct0.setUser(USER, 0, 0, 0);
        ct1.setUser(USER, 1, 0, 1); // nothing to back the loan
        assertEq(_flag(), 0, "setup: not flagged");
        LeftRightUnsigned owed = LeftRightUnsigned.wrap(1); // one unit of token0 long premium

        int24 band = _band();
        uint256 D = E.DECIMALS();
        int24[3] memory poolTicks = [int24(0), int24(1_000), int24(-100_000)];
        for (uint256 i; i < poolTicks.length; ++i) {
            int24 p = poolTicks[i];
            // inside the band: the collateral decides
            assertFalse(_solventFromPool(p, p, D, owed), "at the pool tick: insolvent");
            assertFalse(
                _solventFromPool(p + band - 1, p, D, owed),
                "just inside, above: insolvent"
            );
            assertFalse(
                _solventFromPool(p - band + 1, p, D, owed),
                "just inside, below: insolvent"
            );
            // at the band and beyond: reads solvent
            assertTrue(_solventFromPool(p + band, p, D, owed), "at the band, above: reads solvent");
            assertTrue(_solventFromPool(p - band, p, D, owed), "at the band, below: reads solvent");
            assertTrue(_solventFromPool(p + 10 * band, p, D, owed), "far away: reads solvent");
            // only with no buffer
            assertFalse(
                _solventFromPool(p + 10 * band, p, (D * 1_075) / 1_000, owed),
                "buffered: the collateral decides at any distance"
            );
            // and only for an account that owes long premium: one that does not stays liquidatable when displaced
            assertFalse(
                _solventFromPool(p + 10 * band, p, D, ZERO),
                "no long premium: the collateral decides at any distance"
            );
        }

        // a caller that is not a pool gets no pass
        assertFalse(
            E.isAccountSolvent(
                bals,
                ids,
                int24(10 * band),
                USER,
                ZERO,
                owed,
                CollateralTrackerV2(address(ct0)),
                CollateralTrackerV2(address(ct1)),
                D
            ),
            "not a pool: the collateral decides"
        );
    }

    /// @notice The pass applies to a flagged account too: away from the pool's tick it reads solvent if it owes long
    /// premium, even when it is also short of collateral, and near the pool's tick the flag still fails it.
    function test_displacedPrice_longPremiumOwed_flaggedAccount() public {
        uint256 tol = _tolerance(0);
        ct0.setUser(USER, 0, tol + 1, 0);
        ct1.setUser(USER, 1, 0, 1); // flagged and short of collateral
        assertEq(_flag(), 1, "setup: flagged");
        LeftRightUnsigned owed = LeftRightUnsigned.wrap(1);

        int24 band = _band();
        uint256 D = E.DECIMALS();
        assertFalse(_solventFromPool(0, 0, D, owed), "at the pool tick: the flag fails it");
        assertFalse(_solventFromPool(band - 1, 0, D, owed), "inside the band: the flag fails it");
        assertTrue(_solventFromPool(band, 0, D, owed), "at the band: reads solvent");
        assertTrue(_solventFromPool(-10 * band, 0, D, owed), "far away: reads solvent");
        assertFalse(
            _solventFromPool(10 * band, 0, (D * 1_075) / 1_000, owed),
            "buffered: the flag fails it at any distance"
        );
        // without long premium the same account fails away from the pool's tick too: it is short of collateral
        assertFalse(_solventFromPool(10 * band, 0, D), "no long premium: insolvent when displaced");
    }

    /// @notice A caller that does not expose `getCurrentTick` (not a pool) gets the conservative answer for a
    /// flagged account: insolvent at every tick and buffer.
    function test_flag_nonPoolCaller_failsSolvencyEverywhere() public {
        uint256 tol = _tolerance(0);
        ct1.setUser(USER, 1e24, 0, 1e24);
        ct0.setUser(USER, 0, tol + 1, 0);
        assertEq(_flag(), 1, "setup: flagged");

        int24[5] memory ticks = [
            int24(0),
            int24(1_000),
            int24(-1_000),
            int24(100_000),
            int24(-100_000)
        ];
        uint256[3] memory buffers = [
            E.DECIMALS(),
            (E.DECIMALS() * 1_075) / 1_000,
            E.DECIMALS() / 2
        ];
        for (uint256 i; i < ticks.length; ++i) {
            for (uint256 j; j < buffers.length; ++j) {
                assertFalse(_solventAt(ticks[i], buffers[j]), "not a pool: insolvent");
            }
        }
    }

    /// @notice A caller with no code (an off-chain read from a plain address) is treated like a caller that is not a
    /// pool: the call does not revert, a flagged account is insolvent at every tick, and long premium owed gets no
    /// displaced-price exception.
    function test_flag_noCodeCaller_doesNotRevert_failsSolvencyEverywhere() public {
        uint256 tol = _tolerance(0);
        ct1.setUser(USER, 1e24, 0, 1e24);
        ct0.setUser(USER, 0, tol + 1, 0);
        assertEq(_flag(), 1, "setup: flagged");

        address eoa = address(0xE0A);
        assertEq(eoa.code.length, 0, "setup: no code");
        LeftRightUnsigned owed = LeftRightUnsigned.wrap(0).addToRightSlot(1).addToLeftSlot(1);
        int24[3] memory ticks = [int24(0), int24(1_000), int24(-100_000)];
        for (uint256 i; i < ticks.length; ++i) {
            vm.prank(eoa);
            assertFalse(
                E.isAccountSolvent(
                    bals,
                    ids,
                    ticks[i],
                    USER,
                    ZERO,
                    ZERO,
                    CollateralTrackerV2(address(ct0)),
                    CollateralTrackerV2(address(ct1)),
                    E.DECIMALS()
                ),
                "no code, flagged: insolvent"
            );
            vm.prank(eoa);
            assertFalse(
                E.isAccountSolvent(
                    bals,
                    ids,
                    ticks[i],
                    USER,
                    ZERO,
                    owed,
                    CollateralTrackerV2(address(ct0)),
                    CollateralTrackerV2(address(ct1)),
                    E.DECIMALS()
                ),
                "no code, flagged and owing long premium: insolvent, no exception"
            );
        }
    }

    /// @notice Token1 interest sets bit 1; both tokens set both bits.
    function test_flag_token1Bit_andBothTokens() public {
        // add a token1 loan so interest can accrue in token1 as well
        ids.push(PositionFactory.makeLeg(POOL_ID, 0, 1, 0, 0, 1, 0, 0, 0));
        bals.push(PositionFactory.posBalance(X, 0, 0));
        ct1.setNetBorrows(USER, int128(X));
        uint256 tol0 = _tolerance(0);
        uint256 tol1 = _tolerance(1);
        assertGt(tol1, 0, "setup: token1 tolerance is positive");

        ct0.setUser(USER, 1e24, 0, 1e24);
        ct1.setUser(USER, 0, tol1 + 1, 0);
        assertEq(_flag(), 2, "token1 shortfall: bit 1");
        assertFalse(
            _solventFromPool(0, 0, E.DECIMALS()),
            "token1 shortfall: insolvent at the pool tick despite vast token0 collateral"
        );

        ct0.setUser(USER, 0, tol0 + 1, 0);
        assertEq(_flag(), 3, "both tokens short: bits 0 and 1");

        ct1.setUser(USER, 0, tol1, 0);
        assertEq(_flag(), 1, "token1 back under its tolerance: bit 0 only");
    }

    /// @notice The flag lives in the positionSize slot and leaves the utilization slots intact.
    function test_flag_preservesUtilizationSlots() public {
        bals[0] = PositionFactory.posBalance(X, 4_321, 1_234);
        uint256 tol = _tolerance(0);
        ct0.setUser(USER, 0, tol + 1, 0);
        (, , PositionBalance g) = E.getMarginInternal(
            USER,
            bals,
            int24(0),
            ids,
            ZERO,
            ZERO,
            CollateralTrackerV2(address(ct0)),
            CollateralTrackerV2(address(ct1))
        );
        assertEq(g.positionSize(), 1, "flag in positionSize");
        assertEq(g.utilization0(), 4_321, "utilization0 intact");
        assertEq(g.utilization1(), 1_234, "utilization1 intact");
    }

    /// @notice The external `getMargin` exposes the same flag, so off-chain readers can see it.
    function test_flag_visibleThroughExternalGetMargin() public {
        uint256 tol = _tolerance(0);
        ct0.setUser(USER, 0, tol + 1, 0);
        (, , PositionBalance g) = E.getMargin(
            bals,
            int24(0),
            USER,
            ids,
            ZERO,
            ZERO,
            CollateralTrackerV2(address(ct0)),
            CollateralTrackerV2(address(ct1))
        );
        assertEq(g.positionSize(), 1, "flag visible externally");
        ct0.setUser(USER, 0, 0, 0);
        (, , g) = E.getMargin(
            bals,
            int24(0),
            USER,
            ids,
            ZERO,
            ZERO,
            CollateralTrackerV2(address(ct0)),
            CollateralTrackerV2(address(ct1))
        );
        assertEq(g.positionSize(), 0, "no interest: no flag");
    }

    /// @notice The tolerance is exactly one mint commission on the interest-bearing principal, whatever position
    /// carries it: the same for a loan and for an OTM short of the same notional.
    function test_tolerance_isOneCommissionOnPrincipal() public {
        uint256 commission = (uint256(X) * _fee()) / E.DECIMALS();
        assertEq(_tolerance(0), commission, "loan: one commission on X");

        ct0.setUser(USER, 0, commission, 0);
        assertEq(_flag(), 0, "loan: remainder == commission, not flagged");
        ct0.setUser(USER, 0, commission + 1, 0);
        assertEq(_flag(), 1, "loan: remainder == commission + 1, flagged");

        // OTM short of notional X: requirement ~20% of X, threshold unchanged
        ids[0] = PositionFactory.makeLeg(POOL_ID, 0, 1, 0, 0, 0, 0, 5_000, 20);
        ct0.setUser(USER, 0, commission, 0);
        assertEq(_flag(), 0, "short: remainder == commission, not flagged");
        ct0.setUser(USER, 0, commission + 1, 0);
        assertEq(_flag(), 1, "short: remainder == commission + 1, flagged");
    }

    /// @notice Positions that owe no interest cannot widen the tolerance. A loan+credit pair of size L nets to
    /// zero in `netBorrows` yet adds about `(2 + m) L` to the token0 requirement; under the requirement-based
    /// tolerance it hid the lone loan's uncollected interest, now it changes nothing.
    function test_tolerance_notInflatedByZeroInterestPositions() public {
        uint256 tol = _tolerance(0);
        ct0.setUser(USER, 0, tol + 1, 0);
        (LeftRightUnsigned reqBefore, ) = _margin();
        assertEq(_flag(), 1, "lone loan: flagged just past the tolerance");

        uint128 L = 5 * X;
        ids.push(PositionFactory.makeLeg(POOL_ID, 0, 1, 0, 0, 0, 0, 0, 0)); // loan L
        bals.push(PositionFactory.posBalance(L, 0, 0));
        ids.push(PositionFactory.makeLeg(POOL_ID, 0, 1, 0, 1, 0, 0, 0, 0)); // credit L
        bals.push(PositionFactory.posBalance(L, 0, 0));

        (LeftRightUnsigned reqAfter, ) = _margin();
        assertGt(
            reqAfter.leftSlot(),
            5 * reqBefore.leftSlot(),
            "setup: the pair inflated the requirement > 5x"
        );
        assertEq(_tolerance(0), tol, "tolerance unchanged: the pair carries no principal");
        assertEq(_flag(), 1, "the same owed interest is still flagged");
    }

    /// @notice A near-netted account (loan L, credit L - e) owes interest on e only, and its tolerance is one
    /// commission on e: a few wei of uncollected interest flag it.
    function test_tolerance_nearNettedPrincipal() public {
        int128 e = 100_000;
        ct0.setNetBorrows(USER, e);
        uint256 tol = _tolerance(0);
        assertEq(tol, (uint256(uint128(e)) * _fee()) / E.DECIMALS(), "one commission on e");
        assertLt(
            tol,
            (uint256(X) * _fee()) / E.DECIMALS() / 5,
            "far below one commission on the loan"
        );

        ct0.setUser(USER, 0, tol, 0);
        assertEq(_flag(), 0, "remainder == tolerance: not flagged");
        ct0.setUser(USER, 0, tol + 1, 0);
        assertEq(_flag(), 1, "remainder == tolerance + 1: flagged");
    }

    /// @notice No interest-bearing principal, no tolerance: with `netBorrows <= 0` any uncollected remainder flags.
    /// (Synthetic: the real tracker owes no interest at all in that state.)
    function test_tolerance_zeroWithoutNetBorrows() public {
        ct0.setNetBorrows(USER, 0);
        assertEq(_tolerance(0), 0, "zero principal: zero tolerance");
        ct0.setUser(USER, 0, 1, 0);
        assertEq(_flag(), 1, "one wei uncollected: flagged");

        ct0.setNetBorrows(USER, -int128(X));
        ct0.setUser(USER, 0, 1, 0);
        assertEq(_flag(), 1, "net lender: one wei uncollected still flags");
    }

    /// @notice Flag set iff the balance is exhausted and the remainder exceeds the tolerance; the balance/requirement
    /// accounting is unchanged by the flag.
    function testFuzz_flag_iffRemainderAboveTolerance(uint128 B, uint128 I) public {
        B = uint128(bound(B, 0, type(uint64).max));
        I = uint128(bound(I, 0, type(uint64).max));
        uint256 tol = _tolerance(0);
        ct0.setUser(USER, 0, 0, 0);
        (LeftRightUnsigned ref0, ) = _margin();

        ct0.setUser(USER, B, I, B);
        bool expectFlag = I > B && (I - B) > tol;
        assertEq(_flag(), expectFlag ? 1 : 0, "flag iff remainder above tolerance");

        (LeftRightUnsigned td0, ) = _margin();
        uint256 charge = (B - td0.rightSlot()) + (td0.leftSlot() - ref0.leftSlot());
        assertEq(charge, I, "balance drop + requirement rise == owed interest, flag or not");
        if (expectFlag) assertFalse(_solvent(), "flagged: insolvent");
    }

    /*//////////////////////////////////////////////////////////////
                  BONUS CAP: LIQUIDATABLE ONLY BY THE FLAG
    //////////////////////////////////////////////////////////////*/

    /// @notice Interest uncollected on the accounts below: far above the tolerance (300) on the loan X, and
    /// small enough that `10 * I` stays under the unmodified requirement.
    uint256 internal constant I_CAP = 10_000;
    /// @notice Token1 collateral far above any cross-token boundary at the ticks used here.
    uint256 internal constant RICH = 1e15;

    function _marginFull(
        int24 tick,
        LeftRightUnsigned shortPremia
    ) internal view returns (LeftRightUnsigned td0, LeftRightUnsigned td1, PositionBalance g) {
        (td0, td1, g) = E.getMarginInternal(
            USER,
            bals,
            tick,
            ids,
            shortPremia,
            ZERO,
            CollateralTrackerV2(address(ct0)),
            CollateralTrackerV2(address(ct1))
        );
    }

    /// @notice Requirements of the positions alone, with no interest term and no cap.
    function _baseReq() internal returns (uint256 req0, uint256 req1) {
        ct0.setUser(USER, 0, 0, 0);
        ct1.setUser(USER, 0, 0, 0);
        (LeftRightUnsigned td0, LeftRightUnsigned td1) = _margin();
        return (td0.leftSlot(), td1.leftSlot());
    }

    function _premia0(uint256 p) internal pure returns (LeftRightUnsigned) {
        return LeftRightUnsigned.wrap(0).addToRightSlot(uint128(p));
    }

    /// @notice What `getLiquidationBonus` starts from: min(req * MAX_BONUS / DECIMALS, max(req - bal, 0)).
    function _floor(LeftRightUnsigned td) internal view returns (uint256) {
        uint256 req = td.leftSlot();
        uint256 bal = td.rightSlot();
        return
            Math.min(
                (req * RiskEngineParams.blueChip().maxBonus) / E.DECIMALS(),
                req > bal ? req - bal : 0
            );
    }

    function _bonus(
        LeftRightUnsigned td0,
        LeftRightUnsigned td1,
        int24 tick,
        LeftRightUnsigned shortPremium,
        LeftRightSigned netPaid,
        LeftRightUnsigned credits
    ) internal view returns (int256, int256) {
        (LeftRightSigned b, ) = E.getLiquidationBonus(
            td0,
            td1,
            Math.getSqrtRatioAtTick(tick),
            netPaid,
            shortPremium,
            credits
        );
        return (b.rightSlot(), b.leftSlot());
    }

    function _bonus(
        LeftRightUnsigned td0,
        LeftRightUnsigned td1,
        int24 tick,
        LeftRightUnsigned shortPremium
    ) internal view returns (int256, int256) {
        return _bonus(td0, td1, tick, shortPremium, LeftRightSigned.wrap(0), ZERO);
    }

    /// @notice Flagged token0 with no balance, solvent via token1: the requirement is `10 * I`, the token0 floor
    /// is `2 * I` to the wei and the token1 floor zero. The token0 floor has no token0 behind it, so it is paid in
    /// token1 at the evaluation price; the token0 bonus nets back to zero.
    function test_bonusCap_token0_zeroBalance() public {
        uint256 I = I_CAP;
        (uint256 req0, uint256 req1) = _baseReq();
        assertGt(req0 + I, 10 * I, "setup: the unmodified requirement is larger than 10I");
        ct1.setUser(USER, RICH, 0, RICH);
        ct0.setUser(USER, 0, I, 0);
        assertEq(_flag(), 1, "flagged");

        int24[3] memory ticks = [int24(0), int24(1_000), int24(-1_000)];
        for (uint256 i; i < ticks.length; ++i) {
            (LeftRightUnsigned td0, LeftRightUnsigned td1, ) = _marginFull(ticks[i], ZERO);
            assertEq(td0.leftSlot(), 10 * I, "requirement lowered to 10I");
            assertEq(td0.rightSlot(), 0, "balance stays zero");
            // token1 has no shortfall: its target is its balance, which is above its requirement here
            assertEq(td1.leftSlot(), Math.min(req1, RICH), "token1 requirement: min(req, bal)");
            assertEq(td1.rightSlot(), RICH, "token1 balance untouched");
            assertEq(_floor(td0), 2 * I, "token0 floor is 2I to the wei");
            assertEq(_floor(td1), 0, "token1 floor is zero");

            (int256 b0, int256 b1) = _bonus(td0, td1, ticks[i], ZERO);
            assertEq(b0, 0, "token0 floor fully substituted");
            assertEq(
                b1,
                int256(PanopticMath.convert0to1(2 * I, Math.getSqrtRatioAtTick(ticks[i]))),
                "paid in token1 at the evaluation price"
            );
        }
    }

    /// @notice Flagged token0 with short premia above `8 * I` on the balance side: the `bal + 2I` branch of the
    /// target. The floor is still exactly `2 * I`. The pool passes the same premia as `shortPremium`, which removes
    /// them from the balance `getLiquidationBonus` can use, so the bonus is paid in token1; without that subtraction
    /// it is paid in token0. Either way its value is `2 * I`.
    function test_bonusCap_residualPremiaAbove8I() public {
        uint256 I = I_CAP;
        uint256 P = 8 * I + 50_000;
        (uint256 req0, ) = _baseReq();
        assertGt(req0 + I, P + 2 * I, "setup: the unmodified requirement is larger than bal + 2I");
        ct1.setUser(USER, RICH, 0, RICH);
        ct0.setUser(USER, 0, I, 0);

        (LeftRightUnsigned td0, LeftRightUnsigned td1, PositionBalance g) = _marginFull(
            0,
            _premia0(P)
        );
        assertEq(g.positionSize(), 1, "flagged");
        assertEq(td0.rightSlot(), P, "balance is the premia");
        assertEq(td0.leftSlot(), P + 2 * I, "requirement is bal + 2I");
        assertEq(_floor(td0), 2 * I, "floor is 2I to the wei");

        (int256 b0, int256 b1) = _bonus(td0, td1, 0, _premia0(P));
        assertEq(b0, 0, "pool path: premia not spendable, nothing left in token0");
        assertEq(b1, int256(2 * I), "pool path: 2I paid in token1");

        (b0, b1) = _bonus(td0, td1, 0, ZERO);
        assertEq(b0, int256(2 * I), "no premium subtraction: 2I paid in token0");
        assertEq(b1, 0, "no premium subtraction: no conversion");
    }

    /// @notice Same branch with the balance coming from a same-token credit rather than premia. The credit is
    /// re-margined in full (the account has a loan), so the requirement stays above `bal + 2I`, and closing the
    /// credit shows up as a negative `netPaid`, which cancels the credit in the bonus accounting.
    function test_bonusCap_residualCreditAbove8I() public {
        uint256 I = I_CAP;
        uint128 L = uint128(20 * I);
        ids.push(PositionFactory.makeLeg(POOL_ID, 0, 1, 0, 1, 0, 0, 0, 0));
        bals.push(PositionFactory.posBalance(L, 0, 0));
        ct1.setUser(USER, RICH, 0, RICH);
        ct0.setUser(USER, 0, I, 0);

        (LeftRightUnsigned td0, LeftRightUnsigned td1, PositionBalance g) = _marginFull(0, ZERO);
        assertEq(g.positionSize(), 1, "flagged");
        assertEq(td0.rightSlot(), L, "balance is the credit");
        assertEq(td0.leftSlot(), L + 2 * I, "requirement is bal + 2I");
        assertEq(_floor(td0), 2 * I, "floor is 2I to the wei");

        (int256 b0, int256 b1) = _bonus(
            td0,
            td1,
            0,
            ZERO,
            LeftRightSigned.wrap(0).addToRightSlot(-int128(L)),
            LeftRightUnsigned.wrap(0).addToRightSlot(L)
        );
        assertEq(b0, int256(2 * I), "2I paid out of the credit-side balance");
        assertEq(b1, 0, "no conversion");
    }

    /// @notice `0 < bal <= 8I`: requirement `10I`, floor `min(2I, 10I - bal) == 2I`. At `8I` the two targets
    /// meet; one wei above, the other branch takes over with the floor still `2I`.
    function test_bonusCap_residualPremiaUpTo8I() public {
        uint256 I = I_CAP;
        ct1.setUser(USER, RICH, 0, RICH);
        ct0.setUser(USER, 0, I, 0);

        uint256[3] memory balances = [uint256(1), 3 * I, 8 * I];
        for (uint256 i; i < balances.length; ++i) {
            (LeftRightUnsigned td0, LeftRightUnsigned td1, ) = _marginFull(
                0,
                _premia0(balances[i])
            );
            assertEq(td0.leftSlot(), 10 * I, "requirement is 10I");
            assertEq(td0.rightSlot(), balances[i], "balance is the premia");
            assertEq(_floor(td0), 2 * I, "floor is 2I");
            (int256 b0, int256 b1) = _bonus(td0, td1, 0, _premia0(balances[i]));
            assertEq(b0, 0, "nothing spendable in token0");
            assertEq(b1, int256(2 * I), "2I paid in token1");
        }

        (LeftRightUnsigned td0AtEdge, , ) = _marginFull(0, _premia0(8 * I + 1));
        assertEq(td0AtEdge.leftSlot(), 10 * I + 1, "just past 8I: bal + 2I");
        assertEq(_floor(td0AtEdge), 2 * I, "just past 8I: floor still 2I");
    }

    /// @notice Mirror of the zero-balance case: flagged token1, solvent via token0.
    function test_bonusCap_token1_zeroBalance() public {
        uint256 I = I_CAP;
        ids[0] = PositionFactory.makeLeg(POOL_ID, 0, 1, 0, 0, 1, 0, 0, 0);
        ct0.setNetBorrows(USER, 0);
        ct1.setNetBorrows(USER, int128(X));
        (uint256 req0, uint256 req1) = _baseReq();
        assertGt(req1 + I, 10 * I, "setup: the unmodified requirement is larger than 10I");
        ct0.setUser(USER, RICH, 0, RICH);
        ct1.setUser(USER, 0, I, 0);
        assertEq(_flag(), 2, "flagged in token1");

        int24[3] memory ticks = [int24(0), int24(1_000), int24(-1_000)];
        for (uint256 i; i < ticks.length; ++i) {
            (LeftRightUnsigned td0, LeftRightUnsigned td1, ) = _marginFull(ticks[i], ZERO);
            assertEq(td1.leftSlot(), 10 * I, "requirement lowered to 10I");
            assertEq(td0.leftSlot(), Math.min(req0, RICH), "token0 requirement: min(req, bal)");
            assertEq(_floor(td1), 2 * I, "token1 floor is 2I to the wei");
            assertEq(_floor(td0), 0, "token0 floor is zero");

            (int256 b0, int256 b1) = _bonus(td0, td1, ticks[i], ZERO);
            assertEq(b1, 0, "token1 floor fully substituted");
            assertEq(
                b0,
                int256(PanopticMath.convert1to0(2 * I, Math.getSqrtRatioAtTick(ticks[i]))),
                "paid in token0 at the evaluation price"
            );
        }
    }

    /// @notice A token with no shortfall that is short of its own requirement gets target `bal`: its floor is zero
    /// even though it would pay a bonus uncapped. Reachable when the flagged token's premia carry the account.
    function test_bonusCap_unflaggedToken_shortOfRequirement_floorZero() public {
        uint256 I = I_CAP;
        // token1 loan, with no token1 balance and no token1 interest
        ids.push(PositionFactory.makeLeg(POOL_ID, 0, 1, 0, 0, 1, 0, 0, 0));
        bals.push(PositionFactory.posBalance(X, 0, 0));
        (uint256 req0, uint256 req1) = _baseReq();
        assertGt(req1, 0, "setup: token1 has a requirement");
        // token0 premia far above both requirements carry the account
        uint256 P = 10 * (req0 + req1);
        ct0.setUser(USER, 0, I, 0);

        (LeftRightUnsigned td0, LeftRightUnsigned td1, PositionBalance g) = _marginFull(
            0,
            _premia0(P)
        );
        assertEq(g.positionSize(), 1, "flagged in token0 only");
        assertEq(td1.rightSlot(), 0, "setup: no token1 balance");
        assertEq(td1.leftSlot(), 0, "requirement lowered to the balance");
        assertEq(_floor(td1), 0, "no bonus in the token without a shortfall");
    }

    /// @notice Mirror for token0: flagged token1 whose premia carry the account, token0 short of its requirement.
    function test_bonusCap_unflaggedToken0_shortOfRequirement_floorZero() public {
        uint256 I = I_CAP;
        // token1 loan alongside the token0 loan; interest only in token1
        ids.push(PositionFactory.makeLeg(POOL_ID, 0, 1, 0, 0, 1, 0, 0, 0));
        bals.push(PositionFactory.posBalance(X, 0, 0));
        ct1.setNetBorrows(USER, int128(X));
        (uint256 req0, uint256 req1) = _baseReq();
        assertGt(req0, 0, "setup: token0 has a requirement");
        ct1.setUser(USER, 0, I, 0);

        uint256 P = 10 * (req0 + req1);
        (LeftRightUnsigned td0, LeftRightUnsigned td1, PositionBalance g) = _marginFull(
            0,
            LeftRightUnsigned.wrap(0).addToLeftSlot(uint128(P))
        );
        assertEq(g.positionSize(), 2, "flagged in token1 only");
        assertEq(td0.rightSlot(), 0, "setup: no token0 balance");
        assertEq(td0.leftSlot(), 0, "requirement lowered to the balance");
        assertEq(_floor(td0), 0, "no bonus in the token without a shortfall");
        assertEq(_floor(td1), 2 * I, "the flagged token pays 2I");
    }

    /// @notice The cap is per token: given data with each requirement capped on its own interest, each floor is
    /// twice that token's interest and the bonus is paid where it falls.
    function test_bonusCap_bothTokens_floorsIndependent() public view {
        uint256 I0 = 10_000;
        uint256 I1 = 7_000;
        uint256 bal0 = 50_000;
        uint256 bal1 = 200_000;
        uint256 capped0 = E.bonusRequirement(bal0, I0);
        uint256 capped1 = E.bonusRequirement(bal1, I1);
        assertEq(capped0, 10 * I0, "token0: 10I branch");
        assertEq(capped1, bal1 + 2 * I1, "token1: bal + 2I branch");

        LeftRightUnsigned td0 = LeftRightUnsigned.wrap(uint128(bal0)).addToLeftSlot(
            uint128(capped0)
        );
        LeftRightUnsigned td1 = LeftRightUnsigned.wrap(uint128(bal1)).addToLeftSlot(
            uint128(capped1)
        );
        (int256 b0, int256 b1) = _bonus(td0, td1, 0, ZERO);
        assertEq(b0, int256(2 * I0), "token0 bonus is twice its own interest");
        assertEq(b1, int256(2 * I1), "token1 bonus is twice its own interest");
    }

    /// @notice Both tokens flagged and solvent across tokens through `_getMargin`: each flagged token pays twice
    /// its own interest, including the one whose premia already cover its requirement (raised to `bal + 2I`).
    function test_bonusCap_bothTokensFlagged_eachPaysTwiceOwnInterest() public {
        uint256 I0 = 10_000;
        uint256 I1 = 7_000;
        ids.push(PositionFactory.makeLeg(POOL_ID, 0, 1, 0, 0, 1, 0, 0, 0));
        bals.push(PositionFactory.posBalance(X, 0, 0));
        ct1.setNetBorrows(USER, int128(X));
        (uint256 req0, uint256 req1) = _baseReq();
        ct0.setUser(USER, 0, I0, 0);
        ct1.setUser(USER, 0, I1, 0);

        // token1 premia cover everything; token0 holds none
        uint256 P1 = 10 * (req0 + req1);
        LeftRightUnsigned premia = LeftRightUnsigned.wrap(0).addToLeftSlot(uint128(P1));
        (LeftRightUnsigned td0, LeftRightUnsigned td1, PositionBalance g) = _marginFull(0, premia);
        assertEq(g.positionSize(), 3, "flagged in both tokens");
        assertEq(td0.leftSlot(), 10 * I0, "deficit token: 10I");
        assertEq(td1.leftSlot(), P1 + 2 * I1, "surplus token: raised to bal + 2I");
        assertEq(_floor(td0), 2 * I0, "deficit token floor is 2I");
        assertEq(_floor(td1), 2 * I1, "surplus token floor is 2I of its own interest");
    }

    /// @notice The requirement is replaced, not capped: when the unmodified requirement is below `10I`, the reported
    /// one is raised to `10I` so the floor is still exactly `2I` (the usual `MAX_BONUS` share of the unmodified
    /// requirement would have paid less than the interest).
    function test_bonusCap_raisesRequirementBelowTarget() public {
        uint256 I = 1_000_000; // as large as the loan
        (uint256 req0, ) = _baseReq();
        uint256 req = req0 + I;
        assertLt(req, 10 * I, "setup: the unmodified requirement is below 10I");
        ct1.setUser(USER, RICH, 0, RICH);
        ct0.setUser(USER, 0, I, 0);

        (LeftRightUnsigned td0, LeftRightUnsigned td1, ) = _marginFull(0, ZERO);
        assertEq(td0.leftSlot(), 10 * I, "requirement raised to 10I");
        assertLt(
            (req * RiskEngineParams.blueChip().maxBonus) / E.DECIMALS(),
            2 * I,
            "MAX_BONUS of the unmodified requirement would pay less than 2I"
        );
        assertEq(_floor(td0), 2 * I, "floor is 2I");
        (int256 b0, int256 b1) = _bonus(td0, td1, 0, ZERO);
        assertEq(b0, 0, "token0 floor substituted");
        assertEq(b1, int256(2 * I), "2I paid in token1");
    }

    /// @notice A flagged token whose balance (premia) already covers its requirement paid no bonus before the
    /// change; now the requirement is raised to `bal + 2I` and the floor is `2I`, paid from that balance.
    function test_bonusCap_balanceCoversRequirement_stillPaysTwiceInterest() public {
        uint256 I = I_CAP;
        (uint256 req0, ) = _baseReq();
        uint256 P = 2 * (req0 + I); // premia above the unmodified requirement
        assertGt(P, 8 * I, "setup: bal + 2I branch");
        ct1.setUser(USER, RICH, 0, RICH);
        ct0.setUser(USER, 0, I, 0);

        (LeftRightUnsigned td0, LeftRightUnsigned td1, PositionBalance g) = _marginFull(
            0,
            _premia0(P)
        );
        assertEq(g.positionSize(), 1, "flagged");
        assertEq(td0.rightSlot(), P, "balance is the premia");
        assertEq(td0.leftSlot(), P + 2 * I, "requirement raised to bal + 2I");
        assertEq(_floor(td0), 2 * I, "floor is 2I");
        (int256 b0, int256 b1) = _bonus(td0, td1, 0, ZERO);
        assertEq(b0, int256(2 * I), "paid in token0 out of the premia");
        assertEq(b1, 0, "nothing converted from token1");
    }

    /// @notice Same case with the arguments the pool passes: the premia are `shortPremium`, the burn pays them out
    /// through a negative `netPaid`, and the account holds nothing else, so they are all that backs the bonus.
    function test_bonusCap_balanceCoversRequirement_paidFromRealizedPremia() public {
        uint256 I = I_CAP;
        (uint256 req0, ) = _baseReq();
        uint256 P = 2 * (req0 + I);
        ct0.setUser(USER, 0, I, 0);

        (LeftRightUnsigned td0, LeftRightUnsigned td1, PositionBalance g) = _marginFull(
            0,
            _premia0(P)
        );
        assertEq(g.positionSize(), 1, "flagged");
        assertEq(td1.rightSlot(), 0, "setup: no token1 at all");

        (int256 b0, int256 b1) = _bonus(
            td0,
            td1,
            0,
            _premia0(P),
            LeftRightSigned.wrap(0).addToRightSlot(-int128(int256(P))),
            ZERO
        );
        assertEq(b0, int256(2 * I), "2I paid out of the realized premia");
        assertEq(b1, 0, "nothing converted");
    }

    /// @notice Gate: a flagged account that also fails the cross-token test with no buffer keeps the exact
    /// unmodified data and today's bonus.
    function test_bonusCap_gate_crossInsolventKeepsFullRequirement() public {
        uint256 I = I_CAP;
        uint256 boundary = _token1Boundary(0);
        (uint256 req0, uint256 req1) = _baseReq();
        uint256 D1 = boundary - 1; // below the no-interest boundary, so below the one with interest too
        ct1.setUser(USER, D1, 0, D1);
        ct0.setUser(USER, 0, I, 0);

        (LeftRightUnsigned td0, LeftRightUnsigned td1, PositionBalance g) = _marginFull(0, ZERO);
        assertEq(g.positionSize(), 1, "flagged");
        assertEq(
            LeftRightUnsigned.unwrap(td0),
            LeftRightUnsigned.unwrap(LeftRightUnsigned.wrap(0).addToLeftSlot(uint128(req0 + I))),
            "token0 data as before the cap"
        );
        assertEq(
            LeftRightUnsigned.unwrap(td1),
            LeftRightUnsigned.unwrap(
                LeftRightUnsigned.wrap(uint128(D1)).addToLeftSlot(uint128(req1))
            ),
            "token1 data as before the cap"
        );

        uint256 expected = ((req0 + I) * RiskEngineParams.blueChip().maxBonus) / E.DECIMALS();
        assertGt(expected, 2 * I, "setup: the full bonus exceeds the capped one");
        assertEq(_floor(td0), expected, "floor is MAX_BONUS of the requirement");
        (int256 b0, int256 b1) = _bonus(td0, td1, 0, ZERO);
        assertEq(b0, 0, "token0 floor substituted");
        assertEq(b1, int256(expected), "full bonus, paid in token1");
    }

    /// @notice The gate is the no-buffer solvency test itself. An unflagged account with the same numbers (a larger
    /// `netBorrows` widens the tolerance) finds the boundary through `isAccountSolvent`; the flagged account is
    /// capped at exactly that token1 balance and uncapped one wei below.
    function test_bonusCap_gate_boundaryMatchesNoBufferSolvency() public {
        uint256 I = I_CAP;
        (uint256 req0, ) = _baseReq();

        ct0.setNetBorrows(USER, int128(1_000 * X));
        ct0.setUser(USER, 0, I, 0);
        assertEq(_flag(), 0, "setup: unflagged under the wider tolerance");
        uint256 lo = 0;
        uint256 hi = 10 * (req0 + I);
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            ct1.setUser(USER, mid, 0, mid);
            if (_solvent()) hi = mid;
            else lo = mid;
        }

        ct0.setNetBorrows(USER, int128(X));
        assertEq(_flag(), 1, "setup: flagged again");
        ct1.setUser(USER, hi, 0, hi);
        (LeftRightUnsigned td0, ) = _margin();
        assertEq(td0.leftSlot(), 10 * I, "at the boundary: capped");
        ct1.setUser(USER, hi - 1, 0, hi - 1);
        (td0, ) = _margin();
        assertEq(td0.leftSlot(), req0 + I, "one wei below: not capped");
    }

    /// @notice The gate is evaluated at `atTick`: the same account is capped at a price its token1 collateral
    /// covers and keeps its full requirement at a price it does not.
    function test_bonusCap_gate_evaluatedAtTick() public {
        uint256 I = I_CAP;
        uint256 boundary = _token1Boundary(0);
        (uint256 req0, ) = _baseReq();
        uint256 D1 = 2 * boundary;
        ct1.setUser(USER, D1, 0, D1);
        ct0.setUser(USER, 0, I, 0);

        (LeftRightUnsigned td0, ) = _margin();
        assertEq(td0.leftSlot(), 10 * I, "tick 0: capped");

        // token0 ~7.4x dearer in token1 terms: the same token1 no longer covers the token0 requirement
        (td0, , ) = _marginFull(20_000, ZERO);
        assertEq(td0.leftSlot(), req0 + I, "tick 20000: not capped");
    }

    /// @notice Unflagged accounts are exactly the pre-cap formula, whatever the other token holds: the balance
    /// pays the interest, and any remainder within the tolerance joins the requirement.
    function testFuzz_bonusCap_unflaggedUnchanged(uint128 B, uint128 I, uint128 D1) public {
        uint256 tol = _tolerance(0);
        B = uint128(bound(B, 0, type(uint64).max));
        I = uint128(bound(I, 0, uint256(B) + tol));
        D1 = uint128(bound(D1, 0, type(uint64).max));
        (uint256 req0, uint256 req1) = _baseReq();

        ct0.setUser(USER, B, I, B);
        ct1.setUser(USER, D1, 0, D1);
        (LeftRightUnsigned td0, LeftRightUnsigned td1, PositionBalance g) = _marginFull(0, ZERO);
        assertEq(g.positionSize(), 0, "not flagged");
        assertEq(td0.rightSlot(), I > B ? 0 : B - I, "balance pays the interest");
        assertEq(td0.leftSlot(), req0 + (I > B ? I - B : 0), "remainder joins the requirement");
        assertEq(td1.rightSlot(), D1, "token1 balance untouched");
        assertEq(td1.leftSlot(), req1, "token1 requirement untouched");
    }

    /// @notice A capped account is flagged: it fails every buffered check and the no-buffer check inside the band, so
    /// the lowered requirement does not make it read solvent where a liquidation is judged. Outside the band the
    /// lowered requirement is covered and it reads solvent, which is what refuses a liquidation at a displaced price.
    function test_bonusCap_flagDominatesSolvency_insideBand() public {
        uint256 I = I_CAP;
        ct1.setUser(USER, RICH, 0, RICH);
        ct0.setUser(USER, 0, I, 0);
        (LeftRightUnsigned td0, ) = _margin();
        assertEq(td0.leftSlot(), 10 * I, "setup: capped");

        int24 band = _band();
        uint256 D = E.DECIMALS();
        int24[3] memory poolTicks = [int24(0), int24(50), int24(-50)];
        for (uint256 i; i < poolTicks.length; ++i) {
            int24 p = poolTicks[i];
            assertFalse(_solventFromPool(p, p, D), "capped: insolvent at the pool tick");
            assertFalse(_solventFromPool(p + band - 1, p, D), "capped: insolvent inside the band");
            assertFalse(
                _solventFromPool(p, p, (D * 1_075) / 1_000),
                "capped: insolvent when buffered"
            );
            assertFalse(
                _solventFromPool(p + 2 * band, p, (D * 1_075) / 1_000),
                "capped: insolvent when buffered, away from the pool tick"
            );
            assertTrue(_solventFromPool(p + band, p, D), "capped: reads solvent outside the band");
            assertTrue(
                _solventFromPool(p - 2 * band, p, D),
                "capped: reads solvent outside the band"
            );
        }
    }

    /// @notice The external `getMargin` returns the lowered requirement, the one the pool feeds to the bonus.
    function test_bonusCap_visibleThroughExternalGetMargin() public {
        uint256 I = I_CAP;
        (uint256 req0, ) = _baseReq();
        ct1.setUser(USER, RICH, 0, RICH);
        ct0.setUser(USER, 0, I, 0);
        (LeftRightUnsigned td0, , PositionBalance g) = E.getMargin(
            bals,
            int24(0),
            USER,
            ids,
            ZERO,
            ZERO,
            CollateralTrackerV2(address(ct0)),
            CollateralTrackerV2(address(ct1))
        );
        assertEq(g.positionSize(), 1, "flag visible externally");
        assertEq(td0.leftSlot(), 10 * I, "lowered requirement visible externally");
        assertLt(td0.leftSlot(), req0 + I, "and below the unmodified requirement");
    }

    /// @notice Through `_getMargin`, for any interest and premia that leave the requirement above the target, the
    /// floor is exactly `2 * I`.
    function testFuzz_bonusCap_floorIsTwiceInterest(uint256 I, uint256 P) public {
        (uint256 req0, ) = _baseReq();
        uint256 tol = _tolerance(0);
        I = bound(I, tol + 1, req0 / 10);
        P = bound(P, 0, req0 - I);
        ct1.setUser(USER, RICH, 0, RICH);
        ct0.setUser(USER, 0, I, 0);

        (LeftRightUnsigned td0, , PositionBalance g) = _marginFull(0, _premia0(P));
        assertEq(g.positionSize(), 1, "flagged");
        uint256 target = Math.max(10 * I, P + 2 * I);
        assertLe(target, req0 + I, "setup: the bounds keep the target under the requirement");
        assertEq(td0.leftSlot(), target, "requirement is the target");
        assertEq(_floor(td0), 2 * I, "floor is 2I to the wei");
    }

    /// @notice `_bonusRequirement` arithmetic over the whole uint128 range: both terms of the bonus floor reach
    /// `2I`, and the floor is exactly `2I`.
    function testFuzz_bonusRequirement(uint128 bal, uint128 I) public view {
        uint256 result = E.bonusRequirement(bal, I);
        uint256 target = Math.max(10 * uint256(I), uint256(bal) + 2 * uint256(I));
        assertEq(result, target, "max(10I, bal + 2I)");
        uint256 maxBonus = RiskEngineParams.blueChip().maxBonus;
        uint256 term1 = (result * maxBonus) / E.DECIMALS();
        assertGe(term1, 2 * uint256(I), "MAX_BONUS term >= 2I");
        assertGe(result - bal, 2 * uint256(I), "deficit term >= 2I");
        assertEq(Math.min(term1, result - bal), 2 * uint256(I), "floor is exactly 2I");
    }
}
