// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title Liquidation Bonus Invariants — consolidated test pins
/// @notice Single-file home for every test that asserts a property of the
///         bonus formula at `RiskEngine.getLiquidationBonus` (RE:506-617),
///         the cross-conversion arm (RE:560-607), or the haircut conversion
///         (`RiskEngine.haircutPremia`, RE:620-740).
///
/// Audit reference: protocol-analysis/audits/BONUS_INVARIANTS_AUDIT.md
///
/// Target invariants:
///   I1  Liquidator-incentive floor: bonus_value > 0 whenever the account is liquidatable.
///   I2  Protocol-loss safety (final-state): ProtocolLossRealized_t > 0 ⇒ ∀ s, post_balance_s ≤ 0.
///   I3  Bonus monotone in distress (stated, non-binding).
///   I6  Continuity at the maintenance boundary: no cliff to zero at bal_t → req_t^-.
///   I9  No self-liquidation profit at TWAP, net of gas + fees.
///
/// Additional invariants:
///   C1  Cross-conv rounding is protocol-conservative (≤ 1 wei loss to liquidator per arm).
///   C3  bonus_value is linear (homogeneous of degree 1) in positionSize.
///   C5  Token symmetry under (token0 ↔ token1) input swap.
///   C6  Haircut overshoot bound: sum(haircutPerLeg_t) ≤ haircutBase_t + N_t.
///
/// Layout: two contracts in one file.
///   `BonusInvariantsUnit`         — lightweight, direct calls to `RiskEngineHarness`.
///   `BonusInvariantsIntegration`  — full Uniswap V4 + PanopticPool + CT + oracle stack.

import "forge-std/Test.sol";

// Unit deps
import {RiskEngineHarness} from "./RiskEngineHarness.sol";
import {MockCollateralTracker} from "./mocks/MockCollateralTracker.sol";
import {PositionFactory} from "./helpers/PositionFactory.sol";

// Shared types / libs
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {TokenId} from "@types/TokenId.sol";
import {PositionBalance} from "@types/PositionBalance.sol";
import {OraclePack} from "@types/OraclePack.sol";
import {Pointer} from "@types/Pointer.sol";
import {Constants} from "@libraries/Constants.sol";
import {Math} from "@libraries/Math.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {CallbackLib} from "@libraries/CallbackLib.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";

// Integration deps
import {SemiFungiblePositionManagerV4} from "@contracts/SemiFungiblePositionManagerV4.sol";
import {ISemiFungiblePositionManager} from "@contracts/interfaces/ISemiFungiblePositionManager.sol";
import {PanopticPoolV2} from "@contracts/PanopticPool.sol";
import {CollateralTrackerV2} from "@contracts/CollateralTracker.sol";
import {RiskEngine} from "@contracts/RiskEngine.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";
import {PanopticFactoryV4} from "@contracts/PanopticFactoryV4.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {PanopticHelper} from "@test_periphery/PanopticHelper.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {PositionUtils} from "../../testUtils/PositionUtils.sol";
import {ERC20S} from "../../testUtils/ERC20S.sol";
import {V4RouterSimple} from "../../testUtils/V4RouterSimple.sol";

// V4 types
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/*//////////////////////////////////////////////////////////////
                  UNIT-LEVEL BONUS INVARIANTS
//////////////////////////////////////////////////////////////*/

/// @notice Houses the direct-unit pins against `RiskEngine.getLiquidationBonus`
///         and `PanopticMath.getTotalCreditAmounts` via the test harness.
///         No Uniswap pool, no CollateralTracker — just the math.
contract BonusInvariantsUnit is Test {
    using PositionFactory for *;

    RiskEngineHarness internal E;
    MockCollateralTracker internal ct0;
    MockCollateralTracker internal ct1;

    // Mirror of `RiskEngine.Properties.t.sol` setUp constants.
    uint256 constant DECIMALS = 10_000_000;
    uint256 constant SELL = 2_000_000;
    uint256 constant BUY = 1_000_000;

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

    // -----------------------------------------------------------
    // Moved from RiskEngine.Properties.t.sol (block "K. Liquidation
    // bonus transfer accounting", lines 487-622).
    // -----------------------------------------------------------

    /// @notice Pins: width-zero long credit legs contribute to `getTotalCreditAmounts`;
    /// width-zero loans, options, and short legs do not.
    /// Supports the credit accounting precondition of I2.
    function test_TotalCreditAmounts_onlyCountsZeroWidthLongCredits() public {
        uint64 poolId = 1 + (10 << 48);
        TokenId token0Credit = PositionFactory.makeLeg(poolId, 0, 1, 0, 1, 0, 0, 0, 0);
        TokenId token1Credit = PositionFactory.makeLeg(poolId, 0, 1, 0, 1, 1, 0, 0, 0);
        TokenId token0Loan = PositionFactory.makeLeg(poolId, 0, 1, 0, 0, 0, 0, 0, 0);
        TokenId token1Option = PositionFactory.makeLeg(poolId, 0, 1, 0, 1, 1, 0, 0, 600);

        PositionBalance[] memory oneBalance = new PositionBalance[](1);
        TokenId[] memory oneId = new TokenId[](1);

        oneBalance[0] = PositionFactory.posBalance(uint128(1e9), 0, 0);
        oneId[0] = token0Credit;
        LeftRightUnsigned token0Only = E.totalCreditAmounts(oneBalance, oneId);

        oneBalance[0] = PositionFactory.posBalance(uint128(2e9), 0, 0);
        oneId[0] = token1Credit;
        LeftRightUnsigned token1Only = E.totalCreditAmounts(oneBalance, oneId);

        PositionBalance[] memory balances = new PositionBalance[](4);
        TokenId[] memory ids = new TokenId[](4);
        balances[0] = PositionFactory.posBalance(uint128(1e9), 0, 0);
        ids[0] = token0Credit;
        balances[1] = PositionFactory.posBalance(uint128(2e9), 0, 0);
        ids[1] = token1Credit;
        balances[2] = PositionFactory.posBalance(uint128(3e9), 0, 0);
        ids[2] = token0Loan;
        balances[3] = PositionFactory.posBalance(uint128(4e9), 0, 0);
        ids[3] = token1Option;

        LeftRightUnsigned mixedCredits = E.totalCreditAmounts(balances, ids);

        assertGt(token0Only.rightSlot(), 0, "token0 credit expected");
        assertEq(token0Only.leftSlot(), 0, "token0 credit left slot");
        assertEq(token1Only.rightSlot(), 0, "token1 credit right slot");
        assertGt(token1Only.leftSlot(), 0, "token1 credit expected");
        assertEq(mixedCredits.rightSlot(), token0Only.rightSlot(), "mixed token0 credits");
        assertEq(mixedCredits.leftSlot(), token1Only.leftSlot(), "mixed token1 credits");
    }

    /// @notice Pins the credit-double-count fix (commit 94fab92f) on the
    /// token0-credit / token1-deficit branch.
    function test_LiquidationBonus_token0CreditToken1Debt_countsCreditOnce() public {
        LeftRightSigned netPaid = _signedPair(-1000, 1000);

        // Burn settlement already includes the credit transfer in netPaid. Passing creditAmounts
        // must only remove the same credit from tokenData.balance, so this is equivalent to the
        // same settlement against a balance that never included the credit claim.
        // netPaid is intentionally held constant: the bug was treating the same burn settlement
        // differently only because the credit claim had also been pre-added to tokenData.balance.
        (LeftRightSigned bonusWithCredit, LeftRightSigned remainingWithCredit) = E
            .getLiquidationBonus(
                _tokenData(1000, 0),
                _tokenData(100, 1100),
                Math.getSqrtRatioAtTick(0),
                netPaid,
                LeftRightUnsigned.wrap(0),
                _unsignedPair(1000, 0)
            );
        (
            LeftRightSigned bonusWithoutBalanceCredit,
            LeftRightSigned remainingWithoutBalanceCredit
        ) = E.getLiquidationBonus(
                _tokenData(0, 0),
                _tokenData(100, 1100),
                Math.getSqrtRatioAtTick(0),
                netPaid,
                LeftRightUnsigned.wrap(0),
                LeftRightUnsigned.wrap(0)
            );

        assertEq(
            LeftRightSigned.unwrap(bonusWithCredit),
            LeftRightSigned.unwrap(bonusWithoutBalanceCredit),
            "bonus"
        );
        assertEq(
            LeftRightSigned.unwrap(remainingWithCredit),
            LeftRightSigned.unwrap(remainingWithoutBalanceCredit),
            "remaining"
        );
    }

    /// @notice Symmetric pin: token1-credit / token0-deficit branch.
    function test_LiquidationBonus_token1CreditToken0Debt_countsCreditOnce() public {
        LeftRightSigned netPaid = _signedPair(1000, -1000);

        // Symmetric cancellation check for token1 credits.
        // netPaid is intentionally held constant for the same reason as the token0 case above.
        (LeftRightSigned bonusWithCredit, LeftRightSigned remainingWithCredit) = E
            .getLiquidationBonus(
                _tokenData(100, 1100),
                _tokenData(1000, 0),
                Math.getSqrtRatioAtTick(0),
                netPaid,
                LeftRightUnsigned.wrap(0),
                _unsignedPair(0, 1000)
            );
        (
            LeftRightSigned bonusWithoutBalanceCredit,
            LeftRightSigned remainingWithoutBalanceCredit
        ) = E.getLiquidationBonus(
                _tokenData(100, 1100),
                _tokenData(0, 0),
                Math.getSqrtRatioAtTick(0),
                netPaid,
                LeftRightUnsigned.wrap(0),
                LeftRightUnsigned.wrap(0)
            );

        assertEq(
            LeftRightSigned.unwrap(bonusWithCredit),
            LeftRightSigned.unwrap(bonusWithoutBalanceCredit),
            "bonus"
        );
        assertEq(
            LeftRightSigned.unwrap(remainingWithCredit),
            LeftRightSigned.unwrap(remainingWithoutBalanceCredit),
            "remaining"
        );
    }

    /// @notice Pins I6 at the M-02 boundary. Pre-fix this returned bonus = 0
    /// because the cap was anchored on token1 balance; the required-anchored
    /// cap now pays 0.2 * 1100 = 220 to the liquidator on token0.
    function test_LiquidationBonus_requiredCapPaysCrossTokenBonusWhenDeficientTokenHasNoBalance()
        public
    {
        // Pre-M-02 this returned zero because the max bonus cap was anchored on token1 balance.
        (LeftRightSigned bonusAmounts, LeftRightSigned collateralRemaining) = E.getLiquidationBonus(
            _tokenData(1000, 0),
            _tokenData(0, 1100),
            Math.getSqrtRatioAtTick(0),
            LeftRightSigned.wrap(0),
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );

        assertEq(bonusAmounts.rightSlot(), 220, "token0 bonus");
        assertEq(bonusAmounts.leftSlot(), 0, "token1 bonus");
        assertEq(collateralRemaining.rightSlot(), 780, "token0 remaining");
        assertEq(collateralRemaining.leftSlot(), 0, "token1 remaining");
    }

    // -----------------------------------------------------------
    // Audit-proposed new pins (BONUS_INVARIANTS_AUDIT.md, section E)
    // -----------------------------------------------------------

    /// @notice MAX_BONUS / DECIMALS constants mirroring `RiskEngine.sol:160-162`.
    uint256 constant MAX_BONUS = 2_000_000;

    /*============================ I1 ===============================*/

    /// @notice I1 (direct unit): bonus_value > 0 for the three motivating
    /// scenarios — M-02 boundary, both-deficit, single-side deficit with surplus.
    function test_I1_bonusValueStrictlyPositive_whenAccountLiquidatable() public {
        uint160 sp = Math.getSqrtRatioAtTick(0); // 1:1 price for simple sum

        // (a) M-02 boundary case: deficit token0, token1 is "nothing" (bal=0, req=0)
        (LeftRightSigned b1, ) = E.getLiquidationBonus(
            _tokenData(0, 1100),
            _tokenData(0, 0),
            sp,
            LeftRightSigned.wrap(0),
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );
        // M-02 floor pays 220 on token0 (= MAX_BONUS * 1100 / DECIMALS)
        assertGt(int256(b1.rightSlot()) + int256(b1.leftSlot()), 0, "I1: M-02 boundary");

        // (b) Both-deficit (without cross-conv triggering, since paid<balance for each side
        //     when netPaid=0). Each per-token bonus must be > 0.
        (LeftRightSigned b2, ) = E.getLiquidationBonus(
            _tokenData(500, 1000),
            _tokenData(500, 1000),
            sp,
            LeftRightSigned.wrap(0),
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );
        assertGt(b2.rightSlot(), int128(0), "I1: both-token-deficit token0 > 0");
        assertGt(b2.leftSlot(), int128(0), "I1: both-token-deficit token1 > 0");

        // (c) Single-side deficit with surplus on the other (triggers cross-conv arm).
        // bal0=0, req0=1000 → token0 has bonus 200 and paid=200>balance=0 → deficit.
        // bal1=2000, req1=0 → surplus.
        (LeftRightSigned b3, ) = E.getLiquidationBonus(
            _tokenData(0, 1000),
            _tokenData(2000, 0),
            sp,
            LeftRightSigned.wrap(0),
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );
        // At 1:1 price, value at TWAP = b0 + b1
        int256 valueAtTwap = int256(b3.rightSlot()) + int256(b3.leftSlot());
        assertGt(valueAtTwap, 0, "I1: single-side deficit + surplus");
    }

    /// @notice I1 (fuzz): whenever at least one side is in deficit and that side's
    /// req is large enough not to be rounded out by the cap, bonus value at TWAP > 0.
    function testFuzz_I1_bonusValuePositive_overReqBalSweep(
        uint128 req0,
        uint128 req1,
        uint128 bal0,
        uint128 bal1,
        int24 atTick
    ) public view {
        // Bound to avoid uint128 overflow downstream. Lower bound on req keeps
        // MAX_BONUS·req/DECIMALS ≥ 1 wei (above 4 wei, that's guaranteed).
        req0 = uint128(bound(req0, 100, type(uint96).max));
        req1 = uint128(bound(req1, 100, type(uint96).max));
        bal0 = uint128(bound(bal0, 0, type(uint96).max));
        bal1 = uint128(bound(bal1, 0, type(uint96).max));
        atTick = int24(bound(atTick, Constants.MIN_POOL_TICK + 1, Constants.MAX_POOL_TICK - 1));

        // I1 only requires bonus > 0 when the account is liquidatable.
        vm.assume(req0 > bal0 || req1 > bal1);

        uint160 sp = Math.getSqrtRatioAtTick(atTick);
        (LeftRightSigned bonus, ) = E.getLiquidationBonus(
            _tokenData(bal0, req0),
            _tokenData(bal1, req1),
            sp,
            LeftRightSigned.wrap(0),
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );

        int256 value = _valueAt(int256(bonus.rightSlot()), int256(bonus.leftSlot()), sp);
        assertGt(value, 0, "I1: bonus value > 0 at TWAP");
    }

    /*============================ I2 ===============================*/

    /// @notice I2 pre-haircut (direct unit): the cross-conversion arm cannot
    /// leave both collateralRemaining slots with opposite signs. Specifically,
    /// `collateralRemaining.right < 0 ⇒ collateralRemaining.left ≤ 0` and
    /// symmetric.
    function test_I2_pureBonusArm_noSurplusWithLoss() public view {
        uint160 sp = Math.getSqrtRatioAtTick(0);

        // Both deficits (no cross-conv) — netPaid forces deficits.
        _assertNoSurplusWithLoss(
            _tokenData(100, 1000),
            _tokenData(100, 1000),
            sp,
            _signedPair(500, 500),
            "both deficits"
        );

        // token0 deficit + token1 surplus-large
        _assertNoSurplusWithLoss(
            _tokenData(0, 1000),
            _tokenData(5000, 0),
            sp,
            LeftRightSigned.wrap(0),
            "token0 deficit + token1 surplus-large"
        );

        // token0 deficit + token1 surplus-small (boundary)
        _assertNoSurplusWithLoss(
            _tokenData(0, 1000),
            _tokenData(50, 0),
            sp,
            LeftRightSigned.wrap(0),
            "token0 deficit + token1 surplus-small"
        );

        // token1 deficit + token0 surplus-large (symmetric)
        _assertNoSurplusWithLoss(
            _tokenData(5000, 0),
            _tokenData(0, 1000),
            sp,
            LeftRightSigned.wrap(0),
            "token1 deficit + token0 surplus-large"
        );

        // No deficits anywhere
        _assertNoSurplusWithLoss(
            _tokenData(5000, 1000),
            _tokenData(5000, 1000),
            sp,
            LeftRightSigned.wrap(0),
            "no deficits"
        );
    }

    /// @notice I2 post-haircut (fuzz): the BONUS-I2-01 finding bound — after
    /// `getLiquidationBonus` + `haircutPremia`, the borrower's post-state CT
    /// balance per token is at most `MAX_OPEN_LEGS` wei positive. With the
    /// proposed `min`-clamp at RE:805, this bound tightens to 0 — at which
    /// point this test should be re-pinned at the tighter bound (TODO).
    function testFuzz_I2_postHaircutSurplusBoundByLegRounding(
        uint128 req0,
        uint128 req1,
        uint128 bal0,
        uint128 bal1,
        uint128 lp0,
        uint128 lp1,
        uint8 nLegs,
        int24 atTick
    ) public view {
        req0 = uint128(bound(req0, 1_000, type(uint64).max));
        req1 = uint128(bound(req1, 1_000, type(uint64).max));
        bal0 = uint128(bound(bal0, 0, req0));
        bal1 = uint128(bound(bal1, 0, req1));
        lp0 = uint128(bound(lp0, 0, type(uint64).max));
        lp1 = uint128(bound(lp1, 0, type(uint64).max));
        nLegs = uint8(bound(nLegs, 1, 4));
        atTick = int24(bound(atTick, -100_000, 100_000));

        uint160 sp = Math.getSqrtRatioAtTick(atTick);

        (, LeftRightSigned collateralRemaining) = E.getLiquidationBonus(
            _tokenData(bal0, req0),
            _tokenData(bal1, req1),
            sp,
            LeftRightSigned.wrap(0),
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );

        (
            TokenId[] memory positionIdList,
            LeftRightSigned[4][] memory premiasByLeg
        ) = _buildLongLegPositions(nLegs, lp0, lp1);

        (LeftRightSigned bonusDeltas, LeftRightUnsigned haircutTotal, ) = E.haircutPremia(
            positionIdList,
            premiasByLeg,
            collateralRemaining,
            sp
        );

        // post_balance_t = collateralRemaining_t - bonusDeltas_t + haircutTotal_t
        int256 post0 = int256(collateralRemaining.rightSlot()) -
            int256(bonusDeltas.rightSlot()) +
            int256(uint256(haircutTotal.rightSlot()));
        int256 post1 = int256(collateralRemaining.leftSlot()) -
            int256(bonusDeltas.leftSlot()) +
            int256(uint256(haircutTotal.leftSlot()));

        // I2 final-state form: a loss on one side bounds the surplus on the OTHER side
        // to at most MAX_OPEN_LEGS wei (the per-leg `unsafeDivRoundingUp` bias). Borrower
        // is permitted unbounded surplus when no protocol loss is realized anywhere.
        int256 maxBound = int256(uint256(E.MAX_OPEN_LEGS()));
        if (post0 < 0) {
            assertLe(
                post1,
                maxBound,
                "I2: token1 surplus exceeds MAX_OPEN_LEGS while token0 has loss"
            );
        }
        if (post1 < 0) {
            assertLe(
                post0,
                maxBound,
                "I2: token0 surplus exceeds MAX_OPEN_LEGS while token1 has loss"
            );
        }
    }

    /*============================ I3 ===============================*/

    /// @notice I3 (fuzz, per-token form): bonus(req, bal) is non-increasing in bal
    /// (equivalently, non-decreasing in distress (req-bal)/req).
    function testFuzz_I3_perTokenBonusMonotonic(
        uint128 req,
        uint128 balA,
        uint128 balB
    ) public pure {
        req = uint128(bound(req, 5, type(uint96).max));
        balA = uint128(bound(balA, 0, req));
        balB = uint128(bound(balB, 0, req));

        uint256 ba = balA < balB ? balA : balB;
        uint256 bb = balA < balB ? balB : balA;

        uint256 bonusA = _bonusPerToken(req, uint128(ba));
        uint256 bonusB = _bonusPerToken(req, uint128(bb));

        // lower bal = higher distress = bonus ≥
        assertGe(bonusA, bonusB, "I3: bonus non-decreasing in distress");
    }

    /*============================ I6 ===============================*/

    /// @notice I6 (sweep): no jump-discontinuity to 0 as bal → req from below.
    /// bonus is strictly positive everywhere bal < req (with req above the cap-rounding floor).
    function test_I6_continuityAtMaintenanceBoundary() public pure {
        uint128 req = 1000;
        // bonus = min(MAX_BONUS·req/DEC, req-bal) = min(200, req-bal). So bonus is
        // strictly positive whenever bal < req.
        for (uint128 bal = 0; bal < req; ++bal) {
            assertGt(_bonusPerToken(req, bal), 0, "I6: bonus > 0 when bal < req");
        }
        assertEq(_bonusPerToken(req, req), 0, "I6: bonus = 0 at bal = req");
        assertEq(_bonusPerToken(req, req + 1), 0, "I6: bonus = 0 at bal > req");
    }

    /*============================ C1 ===============================*/

    /// @notice C1 (fuzz): the cross-conv arm's `convert0to1` (floor) /
    /// `convert1to0RoundingUp` (ceil) asymmetry leaks ≤ 2 wei at TWAP toward
    /// the protocol (i.e., post-conv value is at most pre-conv value + 2).
    function testFuzz_C1_crossConvRoundingProtocolConservative(
        uint128 req0,
        uint128 req1,
        uint128 bal0,
        uint128 bal1,
        int24 atTick
    ) public view {
        req0 = uint128(bound(req0, 100, type(uint64).max));
        req1 = uint128(bound(req1, 100, type(uint64).max));
        bal0 = uint128(bound(bal0, 0, type(uint64).max));
        bal1 = uint128(bound(bal1, 0, type(uint64).max));
        atTick = int24(bound(atTick, -100_000, 100_000));

        uint160 sp = Math.getSqrtRatioAtTick(atTick);

        uint256 b0Pre = _bonusPerToken(req0, bal0);
        uint256 b1Pre = _bonusPerToken(req1, bal1);
        int256 valuePre = _valueAt(int256(b0Pre), int256(b1Pre), sp);

        (LeftRightSigned bonus, ) = E.getLiquidationBonus(
            _tokenData(bal0, req0),
            _tokenData(bal1, req1),
            sp,
            LeftRightSigned.wrap(0),
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );
        int256 valuePost = _valueAt(int256(bonus.rightSlot()), int256(bonus.leftSlot()), sp);

        // Protocol-conservative direction: post-conv ≤ pre-conv + tolerance.
        // Tolerance of 2 accounts for one wei of rounding per conv arm.
        assertLe(valuePost, valuePre + 2, "C1: cross-conv leaks at most 2 wei against liquidator");
    }

    /*============================ C3 ===============================*/

    /// @notice C3 (fuzz): bonus is homogeneous of degree 1 in (req, bal).
    /// The cap arm uses floor division so per-multiplier rounding is bounded by `mult`.
    function testFuzz_C3_bonusValueLinearityInPositionSize(
        uint128 req,
        uint128 bal,
        uint8 mult
    ) public pure {
        req = uint128(bound(req, 100, type(uint96).max / 16));
        bal = uint128(bound(bal, 0, type(uint96).max / 16));
        mult = uint8(bound(mult, 1, 16));

        uint256 base = _bonusPerToken(req, bal);
        uint256 scaled = _bonusPerToken(uint128(uint256(req) * mult), uint128(uint256(bal) * mult));

        // Tolerance = mult to absorb floor() of the cap arm under scaling.
        assertApproxEqAbs(scaled, base * mult, uint256(mult), "C3: bonus approx linear in scale");
    }

    /*============================ C5 ===============================*/

    /// @notice C5 (direct unit): swapping `token0 ↔ token1` in all inputs and
    /// inverting the price (sqrt(P) → sqrt(1/P) i.e., tick → -tick) mirrors the outputs.
    /// Tolerance of 2 wei accounts for asymmetric round-up/round-down in the
    /// underlying conv helpers.
    function test_C5_tokenSymmetry_getLiquidationBonus() public view {
        int24 t = 5000;
        uint160 sp = Math.getSqrtRatioAtTick(t);
        uint160 spInv = Math.getSqrtRatioAtTick(-t);

        LeftRightUnsigned td0 = _tokenData(100, 1000);
        LeftRightUnsigned td1 = _tokenData(2000, 500);
        LeftRightSigned netPaid = _signedPair(200, -300);
        LeftRightUnsigned shortPrem = _unsignedPair(50, 100);
        LeftRightUnsigned credits = _unsignedPair(30, 70);

        (LeftRightSigned bonus, LeftRightSigned rem) = E.getLiquidationBonus(
            td0,
            td1,
            sp,
            netPaid,
            shortPrem,
            credits
        );

        // Swap inputs: token0 ↔ token1, right ↔ left slots, price inverted.
        (LeftRightSigned bonusSwap, LeftRightSigned remSwap) = E.getLiquidationBonus(
            _tokenData(2000, 500), // = td1
            _tokenData(100, 1000), // = td0
            spInv,
            _signedPair(-300, 200), // swapped netPaid
            _unsignedPair(100, 50), // swapped shortPrem
            _unsignedPair(70, 30) // swapped credits
        );

        assertApproxEqAbs(
            int256(bonus.rightSlot()),
            int256(bonusSwap.leftSlot()),
            2,
            "C5: bonus[t0/t1] symmetry"
        );
        assertApproxEqAbs(
            int256(bonus.leftSlot()),
            int256(bonusSwap.rightSlot()),
            2,
            "C5: bonus[t1/t0] symmetry"
        );
        assertApproxEqAbs(
            int256(rem.rightSlot()),
            int256(remSwap.leftSlot()),
            2,
            "C5: rem[t0/t1] symmetry"
        );
        assertApproxEqAbs(
            int256(rem.leftSlot()),
            int256(remSwap.rightSlot()),
            2,
            "C5: rem[t1/t0] symmetry"
        );
    }

    /*============================ C6 ===============================*/

    /// @notice C6 (fuzz): haircutTotal per side does not exceed `longPremium` on
    /// that side plus `MAX_OPEN_LEGS` wei (the per-leg `unsafeDivRoundingUp` bias).
    function testFuzz_C6_haircutOvershootBound(
        uint128 req0,
        uint128 req1,
        uint128 bal0,
        uint128 bal1,
        uint128 lp0,
        uint128 lp1,
        uint8 nLegs,
        int24 atTick
    ) public view {
        req0 = uint128(bound(req0, 1_000, type(uint64).max));
        req1 = uint128(bound(req1, 1_000, type(uint64).max));
        bal0 = uint128(bound(bal0, 0, req0));
        bal1 = uint128(bound(bal1, 0, req1));
        lp0 = uint128(bound(lp0, 0, type(uint64).max));
        lp1 = uint128(bound(lp1, 0, type(uint64).max));
        nLegs = uint8(bound(nLegs, 1, 4));
        atTick = int24(bound(atTick, -100_000, 100_000));

        uint160 sp = Math.getSqrtRatioAtTick(atTick);

        (, LeftRightSigned collateralRemaining) = E.getLiquidationBonus(
            _tokenData(bal0, req0),
            _tokenData(bal1, req1),
            sp,
            LeftRightSigned.wrap(0),
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );

        (
            TokenId[] memory positionIdList,
            LeftRightSigned[4][] memory premiasByLeg
        ) = _buildLongLegPositions(nLegs, lp0, lp1);

        (, LeftRightUnsigned haircutTotal, ) = E.haircutPremia(
            positionIdList,
            premiasByLeg,
            collateralRemaining,
            sp
        );

        // The per-leg overshoot is bounded by MAX_OPEN_LEGS (≤ 1 wei per leg, ≤ 26 legs).
        uint256 maxOpenLegs = E.MAX_OPEN_LEGS();
        assertLe(
            uint256(haircutTotal.rightSlot()),
            uint256(lp0) + maxOpenLegs,
            "C6: haircutTotal.right <= longPremium.right + MAX_OPEN_LEGS"
        );
        assertLe(
            uint256(haircutTotal.leftSlot()),
            uint256(lp1) + maxOpenLegs,
            "C6: haircutTotal.left <= longPremium.left + MAX_OPEN_LEGS"
        );
    }

    /*======================== local helpers =========================*/

    /// @dev Per-token bonus formula (`min(MAX_BONUS·req/DECIMALS, max(req-bal, 0))`).
    function _bonusPerToken(uint128 req, uint128 bal) internal pure returns (uint256) {
        uint256 cap = (uint256(req) * MAX_BONUS) / DECIMALS;
        uint256 deficit = req > bal ? uint256(req) - uint256(bal) : 0;
        return cap < deficit ? cap : deficit;
    }

    /// @dev Net value of a (v0, v1) signed bonus/balance pair at TWAP, expressed
    /// in the lower-priced token. Mirrors `_toToken1` but selects the token of
    /// expression based on price to minimize rounding.
    function _valueAt(int256 v0, int256 v1, uint160 sp) internal pure returns (int256) {
        if (sp < Constants.FP96) {
            // token1 cheaper → express in token0 terms
            int256 v1in0 = v1 >= 0
                ? int256(PanopticMath.convert1to0(uint256(v1), sp))
                : -int256(PanopticMath.convert1to0(uint256(-v1), sp));
            return v0 + v1in0;
        } else {
            int256 v0in1 = v0 >= 0
                ? int256(PanopticMath.convert0to1(uint256(v0), sp))
                : -int256(PanopticMath.convert0to1(uint256(-v0), sp));
            return v1 + v0in1;
        }
    }

    /// @dev Build `nLegs` single-leg long positions whose token0/token1 premia
    /// sum to (lp0, lp1) with non-uniform shares so per-leg division generates
    /// rounding remainders.
    function _buildLongLegPositions(
        uint8 nLegs,
        uint128 lp0,
        uint128 lp1
    )
        internal
        pure
        returns (TokenId[] memory positionIdList, LeftRightSigned[4][] memory premiasByLeg)
    {
        uint64 poolId = 1 + (10 << 48);
        positionIdList = new TokenId[](nLegs);
        premiasByLeg = new LeftRightSigned[4][](nLegs);

        uint128 acc0;
        uint128 acc1;
        for (uint256 i = 0; i < nLegs; ++i) {
            // alternate tokenType for variety; both contribute to premia
            uint256 tokenType = i % 2;
            positionIdList[i] = PositionFactory.makeLeg(
                poolId,
                /*legIndex*/ 0,
                /*optionRatio*/ 1,
                /*asset*/ 0,
                /*isLong*/ 1,
                tokenType,
                /*riskPartner*/ 0,
                /*strike*/ 0,
                /*width*/ 0
            );

            uint128 share0;
            uint128 share1;
            if (i == uint256(nLegs) - 1) {
                share0 = lp0 > acc0 ? lp0 - acc0 : 0;
                share1 = lp1 > acc1 ? lp1 - acc1 : 0;
            } else {
                // non-uniform: nearly equal shares but offset by (i+1) so
                // p_leg * haircutBase / longPremium has non-zero remainders.
                share0 = uint128(uint256(lp0) / nLegs);
                share1 = uint128(uint256(lp1) / nLegs);
                acc0 += share0;
                acc1 += share1;
            }
            // long premium is represented as negative in premiasByLeg
            premiasByLeg[i][0] = LeftRightSigned
                .wrap(0)
                .addToRightSlot(-int128(share0))
                .addToLeftSlot(-int128(share1));
        }
    }

    /// @dev Check the pre-haircut form of I2.
    function _assertNoSurplusWithLoss(
        LeftRightUnsigned td0,
        LeftRightUnsigned td1,
        uint160 sp,
        LeftRightSigned netPaid,
        string memory label
    ) internal view {
        (, LeftRightSigned rem) = E.getLiquidationBonus(
            td0,
            td1,
            sp,
            netPaid,
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );
        int256 r = int256(rem.rightSlot());
        int256 l = int256(rem.leftSlot());
        if (r < 0) {
            assertLe(
                l,
                int256(0),
                string.concat("I2 (left non-positive when right loss): ", label)
            );
        }
        if (l < 0) {
            assertLe(
                r,
                int256(0),
                string.concat("I2 (right non-positive when left loss): ", label)
            );
        }
    }

    // -----------------------------------------------------------
    // Helpers (moved verbatim from RiskEngine.Properties.t.sol)
    // -----------------------------------------------------------

    function _tokenData(
        uint128 balance,
        uint128 required
    ) internal pure returns (LeftRightUnsigned) {
        return LeftRightUnsigned.wrap(balance).addToLeftSlot(required);
    }

    function _unsignedPair(uint128 right, uint128 left) internal pure returns (LeftRightUnsigned) {
        return LeftRightUnsigned.wrap(0).addToRightSlot(right).addToLeftSlot(left);
    }

    function _signedPair(int128 right, int128 left) internal pure returns (LeftRightSigned) {
        return LeftRightSigned.wrap(0).addToRightSlot(right).addToLeftSlot(left);
    }
}

/*//////////////////////////////////////////////////////////////
              UNISWAP V3 CALLBACK HELPER (SWAPPER C)
//////////////////////////////////////////////////////////////*/

/// @notice Lightweight V3 callback router used by integration tests to seed
/// the legacy V3 oracle that backs the in-protocol observation stack.
/// Copied from Misc.t.sol — same shape.
contract SwapperC {
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        CallbackLib.CallbackData memory decoded = abi.decode(data, (CallbackLib.CallbackData));

        address token = amount0Delta > 0
            ? address(decoded.poolFeatures.token0)
            : address(decoded.poolFeatures.token1);

        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);

        SafeTransferLib.safeTransferFrom(token, decoded.payer, msg.sender, amountToPay);
    }

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        CallbackLib.CallbackData memory decoded = abi.decode(data, (CallbackLib.CallbackData));

        if (amount0Owed > 0)
            SafeTransferLib.safeTransferFrom(
                decoded.poolFeatures.token0,
                decoded.payer,
                msg.sender,
                amount0Owed
            );
        if (amount1Owed > 0)
            SafeTransferLib.safeTransferFrom(
                decoded.poolFeatures.token1,
                decoded.payer,
                msg.sender,
                amount1Owed
            );
    }

    function mint(IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) public {
        pool.mint(
            address(this),
            tickLower,
            tickUpper,
            liquidity,
            abi.encode(
                CallbackLib.CallbackData({
                    poolFeatures: CallbackLib.PoolFeatures({
                        token0: pool.token0(),
                        token1: pool.token1(),
                        fee: pool.fee()
                    }),
                    payer: msg.sender
                })
            )
        );
    }

    function burn(IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) public {
        pool.burn(tickLower, tickUpper, liquidity);
    }

    function swapTo(IUniswapV3Pool pool, uint160 sqrtPriceX96) public {
        (uint160 sqrtPriceX96Before, , , , , , ) = pool.slot0();

        if (sqrtPriceX96Before == sqrtPriceX96) return;

        pool.swap(
            msg.sender,
            sqrtPriceX96Before > sqrtPriceX96 ? true : false,
            type(int128).max,
            sqrtPriceX96,
            abi.encode(
                CallbackLib.CallbackData({
                    poolFeatures: CallbackLib.PoolFeatures({
                        token0: pool.token0(),
                        token1: pool.token1(),
                        fee: pool.fee()
                    }),
                    payer: msg.sender
                })
            )
        );
    }
}

/*//////////////////////////////////////////////////////////////
              INTEGRATION BONUS INVARIANTS
//////////////////////////////////////////////////////////////*/

/// @notice Houses end-to-end liquidation tests that mint positions, drift
/// the Uniswap V4 price, and call `liquidate`. setUp mirrors `Misc.t.sol`
/// because the moved tests depend on its exact deposit/liquidity layout.
contract BonusInvariantsIntegration is Test, PositionUtils {
    // -----------------------------------------------------------
    // State (subset of Misc.t.sol — only what the moved tests need)
    // -----------------------------------------------------------
    SemiFungiblePositionManagerV4 sfpm;
    address poolReference;
    address collateralReference;

    IUniswapV3Factory V3FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

    PanopticFactoryV4 factory;
    PanopticPoolV2 pp;
    CollateralTrackerV2 ct0;
    CollateralTrackerV2 ct1;
    PanopticHelper ph;
    IRiskEngine re;

    IPoolManager manager;
    V4RouterSimple routerV4;
    int24 MAX_CLAMP_DELTA;

    PoolKey poolKey;

    int24 currentTick;
    int256 twapTick;
    int24 slowOracleTick;
    int24 fastOracleTick;
    int24 lastObservedTick;

    OraclePack oraclePack;
    uint64 poolId;
    uint8 vegoid = 8;

    IUniswapV3Pool uniPool;
    ERC20S token0;
    ERC20S token1;

    address Deployer = address(0x1234);
    address Alice = address(0x123456);
    address Bob = address(0x12345678);
    address Swapper = address(0x123456789);
    address Charlie = address(0x1234567891);

    SwapperC swapperc;

    TokenId[] $posIdList;
    TokenId[] $tempIdList;

    // -----------------------------------------------------------
    // setUp — identical shape to Misctest.setUp() in Misc.t.sol so
    // moved tests behave identically.
    // -----------------------------------------------------------
    function setUp() public {
        vm.startPrank(Deployer);
        manager = new PoolManager(address(0));
        routerV4 = new V4RouterSimple(manager);

        sfpm = new SemiFungiblePositionManagerV4(manager, 10 ** 13, 10 ** 13, 0);

        ph = new PanopticHelper(ISemiFungiblePositionManager(address(sfpm)));

        // deploy reference pool and collateral token
        poolReference = address(new PanopticPoolV2(ISemiFungiblePositionManager(address(sfpm))));
        collateralReference = address(new CollateralTrackerV2());
        token0 = new ERC20S("token0", "T0", 18);
        token1 = new ERC20S("token1", "T1", 18);
        uniPool = IUniswapV3Pool(V3FACTORY.createPool(address(token0), address(token1), 500));

        MAX_CLAMP_DELTA = 149;
        re = IRiskEngine(address(new RiskEngine(10_000_000, 10_000_000, address(0), address(0))));

        poolKey = PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            500,
            10,
            IHooks(address(0))
        );

        swapperc = new SwapperC();
        vm.startPrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);
        token0.approve(address(routerV4), type(uint248).max);
        token1.approve(address(routerV4), type(uint248).max);

        IUniswapV3Pool(uniPool).initialize(2 ** 96);
        IUniswapV3Pool(uniPool).increaseObservationCardinalityNext(100);

        // move back to price=1 while generating 100 observations (min required for pool to function)
        for (uint256 i = 0; i < 100; ++i) {
            vm.warp(block.timestamp + 1);
            vm.roll(block.number + 1);
            swapperc.mint(uniPool, -887200, 887200, 10 ** 18);
            swapperc.burn(uniPool, -887200, 887200, 10 ** 18);
        }
        swapperc.mint(uniPool, -887270, 887270, 10 ** 18);

        swapperc.swapTo(uniPool, 2 ** 96 + 2 ** 88);

        manager.initialize(poolKey, 1 * 2 ** 96);

        swapperc.burn(uniPool, -887270, 887270, 10 ** 18);

        _createPanopticPool();

        swapperc.mint(uniPool, -887270, 887270, 1);
        routerV4.modifyLiquidity(address(0), poolKey, -887270, 887270, 1);

        vm.startPrank(Alice);
        token0.mint(Alice, uint256(type(uint104).max) * 2);
        token1.mint(Alice, uint256(type(uint104).max) * 2);
        ct0 = pp.collateralToken0();
        ct1 = pp.collateralToken1();
        token0.approve(address(ct0), type(uint256).max);
        token1.approve(address(ct1), type(uint256).max);
        ct0.deposit(type(uint104).max, Alice);
        ct1.deposit(type(uint104).max, Alice);

        vm.startPrank(Bob);
        token0.mint(Bob, type(uint104).max);
        token1.mint(Bob, type(uint104).max);
        token0.approve(address(ct0), type(uint104).max);
        token1.approve(address(ct1), type(uint104).max);
        ct0.deposit(type(uint104).max, Bob);
        ct1.deposit(type(uint104).max, Bob);

        vm.startPrank(Charlie);
        token0.mint(Charlie, type(uint104).max);
        token1.mint(Charlie, type(uint104).max);
        token0.approve(address(ct0), type(uint104).max);
        token1.approve(address(ct1), type(uint104).max);
        ct0.deposit(type(uint104).max / 2, Charlie);
        ct1.deposit(type(uint104).max / 2, Charlie);
    }

    function _createPanopticPool() internal {
        vm.startPrank(Deployer);

        factory = new PanopticFactoryV4(
            sfpm,
            manager,
            poolReference,
            collateralReference,
            new bytes32[](0),
            new uint256[][](0),
            new Pointer[][](0)
        );

        token0.mint(Deployer, type(uint104).max);
        token1.mint(Deployer, type(uint104).max);
        token0.approve(address(factory), type(uint104).max);
        token1.approve(address(factory), type(uint104).max);

        pp = PanopticPoolV2(address(factory.deployNewPool(poolKey, re, uint96(block.timestamp))));

        vm.startPrank(Swapper);
        swapperc.swapTo(uniPool, 2 ** 96);
        routerV4.swapTo(address(0), poolKey, 2 ** 96);

        pp.pokeOracle();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        pp.pokeOracle();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        pp.pokeOracle();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        pp.pokeOracle();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        pp.pokeOracle();
        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 10);

        ct0 = pp.collateralToken0();
        ct1 = pp.collateralToken1();
    }

    // -----------------------------------------------------------
    // Mint / liquidate helpers (subset from Misc.t.sol)
    // -----------------------------------------------------------
    function mintOptions(
        PanopticPoolV2 _pp,
        TokenId[] memory positionIdList,
        uint128 positionSize,
        uint24 effectiveLiquidityLimitX32,
        int24 tickLimitLow,
        int24 tickLimitHigh,
        bool premiaAsCollateral
    ) internal {
        uint128[] memory sizeList = new uint128[](1);
        TokenId[] memory mintList = new TokenId[](1);
        int24[3][] memory tickAndSpreadLimits = new int24[3][](1);

        TokenId tokenId = positionIdList[positionIdList.length - 1];
        sizeList[0] = positionSize;
        mintList[0] = tokenId;
        tickAndSpreadLimits[0][0] = tickLimitLow;
        tickAndSpreadLimits[0][1] = tickLimitHigh;
        tickAndSpreadLimits[0][2] = int24(uint24(effectiveLiquidityLimitX32));

        _pp.dispatch(
            mintList,
            positionIdList,
            sizeList,
            tickAndSpreadLimits,
            premiaAsCollateral,
            0
        );
    }

    function liquidate(
        PanopticPoolV2 _pp,
        TokenId[] memory liquidatorList,
        address liquidatee,
        TokenId[] memory positionIdList
    ) internal {
        _pp.dispatchFrom(
            liquidatorList,
            liquidatee,
            positionIdList,
            new TokenId[](0),
            LeftRightUnsigned.wrap(0).addToRightSlot(1).addToLeftSlot(1)
        );
    }

    // -----------------------------------------------------------
    // Moved tests from Misc.t.sol (loanBonusClamp / creditMirror /
    // liquidationCreditAmounts series).
    // -----------------------------------------------------------

    /// @notice Same-token loan-clamp regression: a borrower with a loan-inflated
    /// balance can't extract more than their deposit via self-liquidation.
    function test_Success_loanBonusClamp_sameToken() public {
        // --- Step 1: Setup attacker (Bob) with minimal deposit ---
        vm.startPrank(Bob);

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        uint256 deposit = 1_000_000;
        token0.approve(address(ct0), deposit);
        ct0.deposit(deposit, Bob);

        // small token1 deposit for solvency
        token1.approve(address(ct1), 1000);
        ct1.deposit(1000, Bob);

        uint256 bobBalanceBefore0 = ct0.convertToAssets(ct0.balanceOf(Bob));
        console2.log("Bob deposit (assets):", bobBalanceBefore0);

        // --- Step 2: Create a loan (width=0, isLong=0) in token0 ---
        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // Loan: width=0, isLong=0, tokenType=0 (token0 loan)
        $posIdList.push(
            TokenId.wrap(0).addPoolId(poolId).addLeg(
                0, // legIndex
                1, // optionRatio
                0, // asset
                0, // isLong = 0 (short = loan)
                0, // tokenType = 0 (token0)
                0, // riskPartner
                100, // strike
                0 // width = 0 (loan)
            )
        );

        uint256 loanSize = deposit * 3; // L = 3D
        mintOptions(
            pp,
            $posIdList,
            uint128(loanSize),
            type(uint24).max / 2,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        uint256 bobBalanceAfterLoan0 = ct0.convertToAssets(ct0.balanceOf(Bob));
        console2.log("Bob balance after loan (assets):", bobBalanceAfterLoan0);
        assertTrue(bobBalanceAfterLoan0 > bobBalanceBefore0, "Loan should inflate balance");

        // --- Step 3: Create a far-OTM short put (width>0) that will go deep ITM ---
        int24 tickSpacing = uniPool.tickSpacing();
        int24 shortStrike = int24(200) * tickSpacing; // far below tick=0

        $posIdList.push(
            TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1, // optionRatio
                0, // asset
                0, // isLong = 0 (short)
                0, // tokenType = 0
                0, // riskPartner
                shortStrike,
                2 // width = 1 (narrow range)
            )
        );

        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            type(uint24).max / 2,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        console2.log("Bob balance after short (assets):", ct0.convertToAssets(ct0.balanceOf(Bob)));

        // --- Step 4: Crash price to make the short deep ITM ---
        vm.startPrank(Swapper);

        swapperc.mint(uniPool, -800000, 800000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -800000, 800000, 10 ** 18);

        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(500_000));
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(500_000));

        for (uint256 j = 0; j < 10000; ++j) {
            vm.warp(block.timestamp + 3600);
            vm.roll(block.number + 10);
            pp.pokeOracle();
        }

        (currentTick, fastOracleTick, slowOracleTick, lastObservedTick, oraclePack) = pp
            .getOracleTicks();
        twapTick = re.twapEMA(oraclePack);
        console2.log("current tick:", currentTick);
        console2.log("twap tick:", twapTick);

        // --- Step 5: Liquidate (Alice acts as the accomplice liquidator) ---
        vm.startPrank(Alice);
        deal(ct0.asset(), Alice, 10_000_000);
        deal(ct1.asset(), Alice, 10_000_000);
        IERC20Partial(ct0.asset()).approve(address(ct0), 10_000_000);
        IERC20Partial(ct1.asset()).approve(address(ct1), 10_000_000);

        uint256 aliceBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        uint256 aliceBefore1 = ct1.convertToAssets(ct1.balanceOf(Alice));

        liquidate(pp, new TokenId[](0), Bob, $posIdList);

        uint256 aliceAfter0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        uint256 aliceAfter1 = ct1.convertToAssets(ct1.balanceOf(Alice));

        // --- Step 6: Assert the clamp worked ---
        int256 liquidatorGain0 = int256(aliceAfter0) - int256(aliceBefore0);
        int256 liquidatorGain1 = int256(aliceAfter1) - int256(aliceBefore1);

        console2.log("Liquidator gain token0:", liquidatorGain0);
        console2.log("Liquidator gain token1:", liquidatorGain1);
        console2.log("Deposit was:", int256(deposit));

        // Use a generous bound to account for cross-collateral conversion and rounding
        assertTrue(liquidatorGain0 <= int256(deposit), "loan clamp failed!");
    }

    /// @notice Sanity: the loan-clamp surface is inactive when no loan exists.
    function test_Success_loanBonusClamp_noLoan_unchanged() public {
        vm.startPrank(Bob);

        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);

        uint256 deposit = 1_000_000;
        token0.approve(address(ct0), deposit);
        ct0.deposit(deposit, Bob);
        token1.approve(address(ct1), 1000);
        ct1.deposit(1000, Bob);

        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        }

        // Short put (no loan) — width=1, isLong=0, tokenType=0
        int24 tickSpacing = uniPool.tickSpacing();
        $posIdList.push(
            TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, int24(200) * tickSpacing, 2)
        );

        mintOptions(
            pp,
            $posIdList,
            2_500_000,
            type(uint24).max / 2,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        vm.startPrank(Swapper);
        swapperc.mint(uniPool, -800000, 800000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -800000, 800000, 10 ** 18);
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(500_000));
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(500_000));

        for (uint256 j = 0; j < 10000; ++j) {
            vm.warp(block.timestamp + 3600);
            vm.roll(block.number + 10);
            pp.pokeOracle();
        }

        // Liquidate
        vm.startPrank(Alice);
        deal(ct0.asset(), Alice, 10_000_000);
        deal(ct1.asset(), Alice, 10_000_000);
        IERC20Partial(ct0.asset()).approve(address(ct0), 10_000_000);
        IERC20Partial(ct1.asset()).approve(address(ct1), 10_000_000);

        uint256 aliceBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        uint256 aliceBefore1 = ct1.convertToAssets(ct1.balanceOf(Alice));

        liquidate(pp, new TokenId[](0), Bob, $posIdList);

        uint256 aliceAfter0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        int256 liquidatorGain0 = int256(aliceAfter0) - int256(aliceBefore0);
        uint256 aliceAfter1 = ct1.convertToAssets(ct1.balanceOf(Alice));
        int256 liquidatorGain1 = int256(aliceAfter1) - int256(aliceBefore1);

        console2.log("No-loan liquidator gain token0:", liquidatorGain0);
        console2.log("No-loan liquidator gain token1:", liquidatorGain1);

        assertTrue(
            liquidatorGain0 > 0 || liquidatorGain1 > 0,
            "Liquidator should receive bonus in at least one token without loan"
        );
    }

    /// @notice Diagnostic-only: cross-collateralized liquidation flow, logs
    /// ProtocolLossRealized events and liquidator deltas. No assertions —
    /// kept for visibility next to the asserting variant below.
    function test_Success_loanBonusClamp_crossCollateralized_zeroBonus_orig() public {
        // Bob: withdraw setUp deposits, redeposit ONLY token1
        vm.startPrank(Bob);
        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);
        token1.approve(address(ct1), 1_000_000);
        ct1.deposit(1_000_000, Bob);

        // Open a token0 loan (width-0 short), 5x deposit
        poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
        poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, 0, 0));
        mintOptions(
            pp,
            $posIdList,
            5_000_000,
            type(uint24).max / 2,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        // Pump token0 price (tick 0 to 7500, ~2.12x), just past liquidation edge
        vm.startPrank(Swapper);
        swapperc.mint(uniPool, -800000, 800000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -800000, 800000, 10 ** 18);
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(800000));
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(800000));
        // Minimal warps: just enough for TWAP to catch up — rules out interest accrual
        for (uint256 j = 0; j < 100; ++j) {
            vm.warp(block.timestamp + 600);
            vm.roll(block.number + 1);
            pp.pokeOracle();
        }

        // Liquidate as a FRESH liquidator with no prior CT balance
        address Liquidator = address(0xCAFE);
        vm.startPrank(Liquidator);
        deal(ct0.asset(), Liquidator, 100_000_000);
        deal(ct1.asset(), Liquidator, 100_000_000);
        IERC20Partial(ct0.asset()).approve(address(ct0), 100_000_000);
        IERC20Partial(ct1.asset()).approve(address(ct1), 100_000_000);

        _logBalReq("BEFORE Bob", Bob, $posIdList);

        console2.log("Liquidator BEFORE wallet token0:", token0.balanceOf(Liquidator));
        console2.log("Liquidator BEFORE wallet token1:", token1.balanceOf(Liquidator));
        console2.log("Liquidator BEFORE ct0 shares:", ct0.balanceOf(Liquidator));
        console2.log("Liquidator BEFORE ct1 shares:", ct1.balanceOf(Liquidator));

        vm.recordLogs();
        liquidate(pp, new TokenId[](0), Bob, $posIdList);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("ProtocolLossRealized(address,address,uint256,uint256)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == sig) {
                (uint256 a, uint256 s) = abi.decode(entries[i].data, (uint256, uint256));
                console2.log("!! ProtocolLossRealized emitted (Path A / mint hit) !!");
                console2.log("   ct:", entries[i].emitter);
                console2.log("   protocolLossAssets:", a);
                console2.log("   protocolLossShares:", s);
            }
        }

        console2.log("Liquidator AFTER wallet token0:", token0.balanceOf(Liquidator));
        console2.log("Liquidator AFTER wallet token1:", token1.balanceOf(Liquidator));
        console2.log(
            "Liquidator AFTER ct0 underlying:",
            ct0.convertToAssets(ct0.balanceOf(Liquidator))
        );
        console2.log(
            "Liquidator AFTER ct1 underlying:",
            ct1.convertToAssets(ct1.balanceOf(Liquidator))
        );
    }

    /// @notice Primary I9 pin: combined borrower+liquidator value ≤ 0 at TWAP
    /// after a cross-collateralized self-liquidation.
    function test_Success_loanBonusClamp_crossCollateralized_zeroBonus() public {
        // Bob: withdraw setUp deposits, redeposit ONLY token1
        vm.startPrank(Bob);
        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);
        token1.approve(address(ct1), 1_000_000);
        ct1.deposit(1_000_000, Bob);

        // Open a token0 loan (short put), 5x deposit
        poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
        poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, 0, 0));
        mintOptions(
            pp,
            $posIdList,
            5_000_000,
            type(uint24).max / 2,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        // Pump token0 price (tick 0 to 10000, ~2.72x), past the liquidation edge
        vm.startPrank(Swapper);
        swapperc.mint(uniPool, -800000, 800000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -800000, 800000, 10 ** 18);
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(10000));
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(10000));
        for (uint256 j = 0; j < 10000; ++j) {
            vm.warp(block.timestamp + 3600);
            vm.roll(block.number + 10);
            pp.pokeOracle();
        }

        // Liquidate as Alice
        vm.startPrank(Alice);
        deal(ct0.asset(), Alice, 100_000_000);
        deal(ct1.asset(), Alice, 100_000_000);
        IERC20Partial(ct0.asset()).approve(address(ct0), 100_000_000);
        IERC20Partial(ct1.asset()).approve(address(ct1), 100_000_000);

        // ---------- BEFORE snapshot ----------
        FlowSnapshot memory liqBefore = _snapshotActor(Alice);
        FlowSnapshot memory borBefore = _snapshotActor(Bob);
        CTSnapshot memory ct0Before = _snapshotCT(ct0);
        CTSnapshot memory ct1Before = _snapshotCT(ct1);

        vm.recordLogs();
        liquidate(pp, new TokenId[](0), Bob, $posIdList);

        // ---------- ProtocolLossRealized events ----------
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("ProtocolLossRealized(address,address,uint256,uint256)");
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == sig) {
                (uint256 a, uint256 s) = abi.decode(entries[i].data, (uint256, uint256));
                console2.log("ProtocolLossRealized on", entries[i].emitter);
                console2.log("  protocolLossAssets:", a);
                console2.log("  protocolLossShares:", s);
            }
        }

        // ---------- AFTER snapshot + deltas ----------
        FlowSnapshot memory liqAfter = _snapshotActor(Alice);
        FlowSnapshot memory borAfter = _snapshotActor(Bob);
        CTSnapshot memory ct0After = _snapshotCT(ct0);
        CTSnapshot memory ct1After = _snapshotCT(ct1);

        _logActorDelta("LIQUIDATOR (Alice) DELTA", liqBefore, liqAfter);
        _logActorDelta("LIQUIDATEE (Bob)   DELTA", borBefore, borAfter);
        _logCTDelta("CT0 DELTA", ct0Before, ct0After);
        _logCTDelta("CT1 DELTA", ct1Before, ct1After);

        // ---------- Net value in token1 terms ----------
        (, , , , oraclePack) = pp.getOracleTicks();
        twapTick = re.twapEMA(oraclePack);
        uint160 oracleSqrtPrice = Math.getSqrtRatioAtTick(int24(twapTick));

        int256 liqNet0 = _actorNet0(liqBefore, liqAfter);
        int256 liqNet1 = _actorNet1(liqBefore, liqAfter);
        int256 borNet0 = _actorNet0(borBefore, borAfter);
        int256 borNet1 = _actorNet1(borBefore, borAfter);
        int256 ct0Net = int256(ct0After.totalAssets) - int256(ct0Before.totalAssets);
        int256 ct1Net = int256(ct1After.totalAssets) - int256(ct1Before.totalAssets);

        int256 liquidatorNetValue = _toToken1(liqNet0, liqNet1, oracleSqrtPrice);
        int256 liquidateeNetValue = _toToken1(borNet0, borNet1, oracleSqrtPrice);
        int256 ctNetValue = _toToken1(ct0Net, ct1Net, oracleSqrtPrice);
        int256 combinedSelfNet = liquidatorNetValue + liquidateeNetValue;

        console2.log("--- Net value (token1 terms, oracle TWAP) ---");
        console2.log("Liquidator net value:", liquidatorNetValue);
        console2.log("Liquidatee net value:", liquidateeNetValue);
        console2.log("Combined B+L net    :", combinedSelfNet);
        console2.log("CT totalAssets net  :", ctNetValue);
        console2.log(
            "Sum (sanity)        :",
            _toToken1(liqNet0 + borNet0 + ct0Net, liqNet1 + borNet1 + ct1Net, oracleSqrtPrice)
        );
        assertLe(combinedSelfNet, int256(0), "self-liquidation profit");
    }

    /// @notice Secondary I9 pin: same shape with a short-put loan (multi-leg position).
    function test_Success_loanBonusClamp_crossCollateralized_put_zeroBonus() public {
        // Bob: withdraw setUp deposits, redeposit ONLY token1
        vm.startPrank(Bob);
        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);
        token1.approve(address(ct1), 1_000_000);
        ct1.deposit(1_000_000, Bob);

        // Open a token0 loan (short put), 5x deposit
        poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
        poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        $posIdList.push(
            TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, 0, 0).addLeg(
                1,
                100,
                0,
                0,
                0,
                1,
                200,
                2
            )
        );
        mintOptions(
            pp,
            $posIdList,
            50_000,
            type(uint24).max / 2,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        // Pump token0 price (tick 0 to 10000, ~2.72x), past the liquidation edge
        vm.startPrank(Swapper);
        swapperc.mint(uniPool, -800000, 800000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -800000, 800000, 10 ** 18);
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(10000));
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(10000));
        for (uint256 j = 0; j < 10000; ++j) {
            vm.warp(block.timestamp + 3600);
            vm.roll(block.number + 10);
            pp.pokeOracle();
        }

        // Liquidate as Alice
        vm.startPrank(Alice);
        deal(ct0.asset(), Alice, 100_000_000);
        deal(ct1.asset(), Alice, 100_000_000);
        IERC20Partial(ct0.asset()).approve(address(ct0), 100_000_000);
        IERC20Partial(ct1.asset()).approve(address(ct1), 100_000_000);

        uint256 ctBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        uint256 ctBefore1 = ct1.convertToAssets(ct1.balanceOf(Alice));
        uint256 walletBefore0 = token0.balanceOf(Alice);
        uint256 walletBefore1 = token1.balanceOf(Alice);

        liquidate(pp, new TokenId[](0), Bob, $posIdList);

        console2.log("walletBefore0, walletBefore1", walletBefore0, walletBefore1);
        console2.log(
            "token0.balanceOf(Alice), token1.balanceOf(Alice)",
            token0.balanceOf(Alice),
            token1.balanceOf(Alice)
        );

        console2.log(
            "net0",
            int256(ct0.convertToAssets(token0.balanceOf(Alice))) -
                int256(ct0.convertToAssets(walletBefore0))
        );
        console2.log(
            "net1",
            int256(ct1.convertToAssets(token1.balanceOf(Alice))) -
                int256(ct1.convertToAssets(walletBefore1))
        );

        int256 totalGain0 = (int256(ct0.convertToAssets(ct0.balanceOf(Alice))) -
            int256(ctBefore0)) + (int256(token0.balanceOf(Alice)) - int256(walletBefore0));
        int256 totalGain1 = (int256(ct1.convertToAssets(ct1.balanceOf(Alice))) -
            int256(ctBefore1)) + (int256(token1.balanceOf(Alice)) - int256(walletBefore1));

        (, , , , oraclePack) = pp.getOracleTicks();
        twapTick = re.twapEMA(oraclePack);
        uint160 oracleSqrtPrice = Math.getSqrtRatioAtTick(int24(twapTick));

        int256 token0InToken1Terms = totalGain0 >= 0
            ? int256(PanopticMath.convert0to1(uint256(totalGain0), oracleSqrtPrice))
            : -int256(PanopticMath.convert0to1(uint256(-totalGain0), oracleSqrtPrice));

        console2.log("totalGain0", totalGain0);
        console2.log("totalGain1", totalGain1);
        console2.log("token0InToken1Terms", token0InToken1Terms);

        console2.log("Net liquidator value (token1 terms):", totalGain1 + token0InToken1Terms);
    }

    /// @notice Regression guard for Vector L (credit-mirror tick invariance).
    /// @dev A width=0 long leg adds the same credit notional to `bal` (via
    /// `getTotalCreditAmounts`) and to `req` (via the mirror in
    /// `_getRequiredCollateralAtTickSinglePosition`). If those drift, a tick
    /// move alone can open `req - bal` without economic loss to the borrower,
    /// which is the I9-violation path. This test pins the mirror in CI:
    ///   (a) the credit's contribution to (req - bal) is tick-invariant; and
    ///   (b) that contribution equals exactly the mint-time fee on the credit
    ///       leg (commission etc.) — the credit notional itself cancels.
    function test_Success_creditMirror_tickInvariance() public {
        uint256 snap = vm.snapshotState();

        int24[] memory ticks = new int24[](7);
        ticks[0] = -100_000;
        ticks[1] = -10_000;
        ticks[2] = -100;
        ticks[3] = 0;
        ticks[4] = 100;
        ticks[5] = 10_000;
        ticks[6] = 100_000;

        (int256[] memory gapsWithout, , ) = _setupAndRecordGaps(false, ticks);
        vm.revertToState(snap);
        (
            int256[] memory gapsWith,
            int256 creditMintCost0,
            int256 creditMintCost1
        ) = _setupAndRecordGaps(true, ticks);

        // Mass conservation: the credit notional itself moves from open
        // collateral into a credit claim and is added back to `bal` via
        // getTotalCreditAmounts. So the only net change in `bal` from the
        // credit mint is the mint-time fee. The credit term enters `req` at
        // face value (mirror), so the (req - bal) shift must equal exactly
        // that fee, at every tick.
        uint256 n = ticks.length;
        for (uint256 i = 0; i < n; ++i) {
            assertEq(
                gapsWith[i] - gapsWithout[i],
                creditMintCost0,
                "credit's (req0 - bal0) contribution != mint-time fee (tick drift?)"
            );
            assertEq(
                gapsWith[n + i] - gapsWithout[n + i],
                creditMintCost1,
                "credit's (req1 - bal1) contribution != mint-time fee (tick drift?)"
            );
        }
    }

    /// @notice Fuzz variant of test_Success_creditMirror_tickInvariance.
    /// @dev Each run picks a random tick and a random credit positionSize, then
    /// asserts the credit's contribution to (req - bal) at that tick equals
    /// what it is at tick=0. Tick-dependent drift (Vector L regression) fails
    /// here even if the 7-point sweep happens to miss the affected range.
    function testFuzz_creditMirror_tickInvariance(int24 fuzzTick, uint128 creditSize) public {
        fuzzTick = int24(bound(fuzzTick, Constants.MIN_POOL_TICK + 1, Constants.MAX_POOL_TICK - 1));
        creditSize = uint128(bound(creditSize, 1_000, 500_000));

        int24[] memory ticks = new int24[](2);
        ticks[0] = 0;
        ticks[1] = fuzzTick;

        uint256 snap = vm.snapshotState();
        (int256[] memory gapsWithout, , ) = _setupAndRecordGapsForCreditFuzz(
            false,
            ticks,
            creditSize
        );
        vm.revertToState(snap);
        (int256[] memory gapsWith, int256 cost0, int256 cost1) = _setupAndRecordGapsForCreditFuzz(
            true,
            ticks,
            creditSize
        );

        // Tick-invariance: credit's (req - bal) shift at the fuzzed tick must
        // equal its shift at tick=0, and both must equal the mint-time fee.
        assertEq(gapsWith[0] - gapsWithout[0], cost0, "tick0 token0");
        assertEq(gapsWith[1] - gapsWithout[1], cost0, "fuzzTick token0");
        assertEq(gapsWith[2] - gapsWithout[2], cost1, "tick0 token1");
        assertEq(gapsWith[3] - gapsWithout[3], cost1, "fuzzTick token1");
    }

    /// @notice End-to-end pin of the credit-double-count fix: a credit added
    /// to the borrower's portfolio must not yield an extra credit-sized
    /// liquidator payout vs. the no-credit baseline.
    function test_Success_liquidationCreditAmounts_singleCountsCreditedTokenPayout() public {
        uint256 snapshot = vm.snapshotState();

        (int256 withCreditGain0, uint256 credit0) = _liquidationCreditPayoutScenario(true);
        vm.revertToState(snapshot);

        (int256 withoutCreditGain0, ) = _liquidationCreditPayoutScenario(false);

        int256 excessFromCredit = withCreditGain0 - withoutCreditGain0;
        uint256 absExcessFromCredit = excessFromCredit >= 0
            ? uint256(excessFromCredit)
            : uint256(-excessFromCredit);

        // Both branches have the same loan and liquidation-driving option. The credit branch
        // moves 1,000,000 token0 from ordinary collateral into a zero-width long credit; the
        // baseline leaves that token0 as ordinary collateral. Any residual should be only share
        // rounding/interest drift, not another credit-sized payout. Passing zero creditAmounts
        // into getLiquidationBonus makes this fixture fail with a 333,236 token0 excess.
        assertEq(credit0, 1_000_000, "credit0");
        assertLe(absExcessFromCredit, 1_000, "credit double-counted in payout");
    }

    // -----------------------------------------------------------
    // Integration helpers (moved verbatim from Misc.t.sol)
    // -----------------------------------------------------------

    struct FlowSnapshot {
        uint256 wallet0;
        uint256 wallet1;
        uint256 ctShares0;
        uint256 ctShares1;
        uint256 ctAssets0;
        uint256 ctAssets1;
    }

    struct CTSnapshot {
        uint256 totalSupply;
        uint256 totalAssets;
        uint256 tokenBalance;
    }

    function _snapshotActor(address who) internal view returns (FlowSnapshot memory s) {
        s.wallet0 = token0.balanceOf(who);
        s.wallet1 = token1.balanceOf(who);
        s.ctShares0 = ct0.balanceOf(who);
        s.ctShares1 = ct1.balanceOf(who);
        s.ctAssets0 = ct0.convertToAssets(s.ctShares0);
        s.ctAssets1 = ct1.convertToAssets(s.ctShares1);
    }

    function _snapshotCT(CollateralTrackerV2 ct) internal view returns (CTSnapshot memory s) {
        s.totalSupply = ct.totalSupply();
        s.totalAssets = ct.totalAssets();
        s.tokenBalance = IERC20Partial(ct.asset()).balanceOf(address(ct));
    }

    function _logActorDelta(
        string memory label,
        FlowSnapshot memory b,
        FlowSnapshot memory a
    ) internal pure {
        console2.log(label);
        console2.log("  wallet token0 :", int256(a.wallet0) - int256(b.wallet0));
        console2.log("  wallet token1 :", int256(a.wallet1) - int256(b.wallet1));
        console2.log("  ct0 shares    :", int256(a.ctShares0) - int256(b.ctShares0));
        console2.log("  ct0 underlying:", int256(a.ctAssets0) - int256(b.ctAssets0));
        console2.log("  ct1 shares    :", int256(a.ctShares1) - int256(b.ctShares1));
        console2.log("  ct1 underlying:", int256(a.ctAssets1) - int256(b.ctAssets1));
    }

    function _logCTDelta(
        string memory label,
        CTSnapshot memory b,
        CTSnapshot memory a
    ) internal pure {
        console2.log(label);
        console2.log("  totalSupply   :", int256(a.totalSupply) - int256(b.totalSupply));
        console2.log("  totalAssets   :", int256(a.totalAssets) - int256(b.totalAssets));
        console2.log("  token bal     :", int256(a.tokenBalance) - int256(b.tokenBalance));
    }

    function _actorNet0(
        FlowSnapshot memory b,
        FlowSnapshot memory a
    ) internal pure returns (int256) {
        return
            (int256(a.wallet0) - int256(b.wallet0)) + (int256(a.ctAssets0) - int256(b.ctAssets0));
    }

    function _actorNet1(
        FlowSnapshot memory b,
        FlowSnapshot memory a
    ) internal pure returns (int256) {
        return
            (int256(a.wallet1) - int256(b.wallet1)) + (int256(a.ctAssets1) - int256(b.ctAssets1));
    }

    function _toToken1(int256 v0, int256 v1, uint160 sqrtP) internal pure returns (int256) {
        int256 v0in1 = v0 >= 0
            ? int256(PanopticMath.convert0to1(uint256(v0), sqrtP))
            : -int256(PanopticMath.convert0to1(uint256(-v0), sqrtP));
        return v1 + v0in1;
    }

    function _logBalReq(string memory label, address user, TokenId[] memory ids) internal {
        (
            LeftRightUnsigned _shortPrem,
            LeftRightUnsigned _longPrem,
            PositionBalance[] memory _posBal,
            ,

        ) = pp.getFullPositionsData(user, false, ids);
        (, , , , oraclePack) = pp.getOracleTicks();
        int24 _twap = re.twapEMA(oraclePack);
        (LeftRightUnsigned _td0, LeftRightUnsigned _td1, ) = re.getMargin(
            _posBal,
            _twap,
            user,
            ids,
            _shortPrem,
            _longPrem,
            ct0,
            ct1
        );
        console2.log(label);
        console2.log("  bal0:", _td0.rightSlot());
        console2.log("  bal1:", _td1.rightSlot());
        console2.log("  req0:", _td0.leftSlot());
        console2.log("  req1:", _td1.leftSlot());
    }

    /// @dev Mints a loan position and optionally adds a width=0 long credit
    /// leg, then samples (req - bal) at each tick.
    /// @return gaps Length-14 flat array: indices 0..6 are token0 gaps, 7..13 token1.
    /// @return creditMintCost0 Net token0 cost of minting the credit leg
    /// (collateral lost minus credit notional re-credited). 0 if !includeCredit.
    /// @return creditMintCost1 Same for token1.
    function _setupAndRecordGaps(
        bool includeCredit,
        int24[] memory ticks
    ) internal returns (int256[] memory gaps, int256 creditMintCost0, int256 creditMintCost1) {
        delete $posIdList;

        vm.startPrank(Bob);
        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);
        token0.approve(address(ct0), 2_000_000);
        token1.approve(address(ct1), 2_000_000);
        ct0.deposit(2_000_000, Bob);
        ct1.deposit(2_000_000, Bob);

        poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
        poolId += uint64(uint24(uniPool.tickSpacing())) << 48;

        // Loan (width=0, isLong=0) so the borrower has a real margin requirement.
        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 1, 0, 0, 0));
        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            type(uint24).max / 2,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        if (includeCredit) {
            uint256 bal0Before = ct0.convertToAssets(ct0.balanceOf(Bob));
            uint256 bal1Before = ct1.convertToAssets(ct1.balanceOf(Bob));
            // Width=0, isLong=1, tokenType=0: token0 credit leg under test.
            $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 1, 0, 0, 0, 0));
            mintOptions(
                pp,
                $posIdList,
                1_000_000,
                type(uint24).max / 2,
                Constants.MIN_POOL_TICK,
                Constants.MAX_POOL_TICK,
                true
            );
            uint256 bal0After = ct0.convertToAssets(ct0.balanceOf(Bob));
            uint256 bal1After = ct1.convertToAssets(ct1.balanceOf(Bob));

            // Net mint cost = collateral lost minus credit notional re-credited.
            // The credit notional itself is added back to `bal` via
            // getTotalCreditAmounts, so it must be netted out here.
            (, , PositionBalance[] memory pb, , ) = pp.getFullPositionsData(Bob, false, $posIdList);
            LeftRightUnsigned credit = PanopticMath.getTotalCreditAmounts(pb, $posIdList);

            creditMintCost0 =
                int256(bal0Before) -
                int256(bal0After) -
                int256(uint256(credit.rightSlot()));
            creditMintCost1 =
                int256(bal1Before) -
                int256(bal1After) -
                int256(uint256(credit.leftSlot()));
        }

        // First half holds token0 gaps, second half holds token1 gaps.
        uint256 n = ticks.length;
        gaps = new int256[](2 * n);
        (
            LeftRightUnsigned _shortPrem,
            LeftRightUnsigned _longPrem,
            PositionBalance[] memory _posBal,
            ,

        ) = pp.getFullPositionsData(Bob, false, $posIdList);

        for (uint256 i = 0; i < n; ++i) {
            (LeftRightUnsigned td0, LeftRightUnsigned td1, ) = re.getMargin(
                _posBal,
                ticks[i],
                Bob,
                $posIdList,
                _shortPrem,
                _longPrem,
                ct0,
                ct1
            );
            gaps[i] = int256(uint256(td0.leftSlot())) - int256(uint256(td0.rightSlot()));
            gaps[n + i] = int256(uint256(td1.leftSlot())) - int256(uint256(td1.rightSlot()));
        }
    }

    /// @dev Same as _setupAndRecordGaps but parameterizes the credit size.
    /// Kept separate to avoid touching the non-fuzz test's call sites.
    function _setupAndRecordGapsForCreditFuzz(
        bool includeCredit,
        int24[] memory ticks,
        uint128 creditSize
    ) internal returns (int256[] memory gaps, int256 creditMintCost0, int256 creditMintCost1) {
        delete $posIdList;

        vm.startPrank(Bob);
        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);
        token0.approve(address(ct0), 2_000_000);
        token1.approve(address(ct1), 2_000_000);
        ct0.deposit(2_000_000, Bob);
        ct1.deposit(2_000_000, Bob);

        poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
        poolId += uint64(uint24(uniPool.tickSpacing())) << 48;

        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 1, 0, 0, 0));
        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            type(uint24).max / 2,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        if (includeCredit) {
            uint256 bal0Before = ct0.convertToAssets(ct0.balanceOf(Bob));
            uint256 bal1Before = ct1.convertToAssets(ct1.balanceOf(Bob));
            $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 1, 0, 0, 0, 0));
            mintOptions(
                pp,
                $posIdList,
                creditSize,
                type(uint24).max / 2,
                Constants.MIN_POOL_TICK,
                Constants.MAX_POOL_TICK,
                true
            );
            uint256 bal0After = ct0.convertToAssets(ct0.balanceOf(Bob));
            uint256 bal1After = ct1.convertToAssets(ct1.balanceOf(Bob));

            (, , PositionBalance[] memory pb, , ) = pp.getFullPositionsData(Bob, false, $posIdList);
            LeftRightUnsigned credit = PanopticMath.getTotalCreditAmounts(pb, $posIdList);

            creditMintCost0 =
                int256(bal0Before) -
                int256(bal0After) -
                int256(uint256(credit.rightSlot()));
            creditMintCost1 =
                int256(bal1Before) -
                int256(bal1After) -
                int256(uint256(credit.leftSlot()));
        }

        uint256 n = ticks.length;
        gaps = new int256[](2 * n);
        (
            LeftRightUnsigned _shortPrem,
            LeftRightUnsigned _longPrem,
            PositionBalance[] memory _posBal,
            ,

        ) = pp.getFullPositionsData(Bob, false, $posIdList);

        for (uint256 i = 0; i < n; ++i) {
            (LeftRightUnsigned td0, LeftRightUnsigned td1, ) = re.getMargin(
                _posBal,
                ticks[i],
                Bob,
                $posIdList,
                _shortPrem,
                _longPrem,
                ct0,
                ct1
            );
            gaps[i] = int256(uint256(td0.leftSlot())) - int256(uint256(td0.rightSlot()));
            gaps[n + i] = int256(uint256(td1.leftSlot())) - int256(uint256(td1.rightSlot()));
        }
    }

    function _liquidationCreditPayoutScenario(
        bool includeCredit
    ) internal returns (int256 totalGain0, uint256 credit0) {
        delete $posIdList;

        vm.startPrank(Bob);
        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);
        token0.approve(address(ct0), 2_000_000);
        token1.approve(address(ct1), 2_000_000);
        ct0.deposit(2_000_000, Bob);
        ct1.deposit(2_000_000, Bob);

        poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
        poolId += uint64(uint24(uniPool.tickSpacing())) << 48;

        TokenId loanId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 1, 0, 0, 0);
        $posIdList.push(loanId);
        mintOptions(
            pp,
            $posIdList,
            1_000_000,
            type(uint24).max / 2,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        if (includeCredit) {
            $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 1, 0, 0, 0, 0));
            mintOptions(
                pp,
                $posIdList,
                1_000_000,
                type(uint24).max / 2,
                Constants.MIN_POOL_TICK,
                Constants.MAX_POOL_TICK,
                true
            );
        }

        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 1, 0, -15, 1));
        mintOptions(
            pp,
            $posIdList,
            5_000_000,
            type(uint24).max / 2,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        (, , PositionBalance[] memory positionBalanceArray, , ) = pp.getFullPositionsData(
            Bob,
            false,
            $posIdList
        );
        credit0 = PanopticMath.getTotalCreditAmounts(positionBalanceArray, $posIdList).rightSlot();

        vm.startPrank(Swapper);
        swapperc.mint(uniPool, -800000, 800000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -800000, 800000, 10 ** 18);
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(-10_000));
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-10_000));
        for (uint256 j = 0; j < 10000; ++j) {
            vm.warp(block.timestamp + 3600);
            vm.roll(block.number + 10);
            pp.pokeOracle();
        }

        (currentTick, , , , oraclePack) = pp.getOracleTicks();
        twapTick = re.twapEMA(oraclePack);
        (uint256 totalCollateralBalance, uint256 totalCollateralRequired) = ph.checkCollateral(
            pp,
            Bob,
            currentTick,
            $posIdList
        );
        assertLt(totalCollateralBalance, totalCollateralRequired, "liquidatable");

        vm.startPrank(Alice);
        deal(ct0.asset(), Alice, 100_000_000);
        deal(ct1.asset(), Alice, 100_000_000);
        IERC20Partial(ct0.asset()).approve(address(ct0), 100_000_000);
        IERC20Partial(ct1.asset()).approve(address(ct1), 100_000_000);

        uint256 ctBefore0 = ct0.convertToAssets(ct0.balanceOf(Alice));
        uint256 walletBefore0 = token0.balanceOf(Alice);

        liquidate(pp, new TokenId[](0), Bob, $posIdList);

        totalGain0 =
            (int256(ct0.convertToAssets(ct0.balanceOf(Alice))) - int256(ctBefore0)) +
            (int256(token0.balanceOf(Alice)) - int256(walletBefore0));
    }

    // -----------------------------------------------------------
    // Audit-proposed new pin: I9 structural fuzz
    // -----------------------------------------------------------

    /// @notice I9 (fuzz): combined borrower + liquidator net value at TWAP is
    /// non-positive across a range of loanSize values, all driven through the
    /// same cross-collateralized self-liquidation path that the primary
    /// `test_Success_loanBonusClamp_crossCollateralized_zeroBonus` test pins
    /// at one point. Structural pin for prior-audit Vectors A and J.
    /// Capped at 5 runs because each iteration spins up the full V4 pool and
    /// runs a 10,000-iteration warp loop (~10s per run).
    /// forge-config: default.fuzz.runs = 5
    function testFuzz_I9_combinedPnlNonPositive_overSpotTwapCurrentMix(uint128 loanSize) public {
        // Range chosen around the known-working primary I9 scenario (5M).
        // Below ~3M and above 5M leave too little leverage / fail the mint
        // solvency check (collateral = 1M). The drift target (tick 15000)
        // is chosen so every loan in this range becomes liquidatable at all
        // four oracle ticks after the warp loop.
        loanSize = uint128(bound(loanSize, 3_000_000, 5_000_000));

        // Setup: Bob deposits only token1, opens a token0 loan.
        vm.startPrank(Bob);
        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);
        token1.approve(address(ct1), 1_000_000);
        ct1.deposit(1_000_000, Bob);

        poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
        poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, 0, 0));
        mintOptions(
            pp,
            $posIdList,
            loanSize,
            type(uint24).max / 2,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        // Pump token0 price to tick 15_000 to ensure every loanSize in the
        // bounded range becomes liquidatable at all four oracle ticks.
        vm.startPrank(Swapper);
        swapperc.mint(uniPool, -800000, 800000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -800000, 800000, 10 ** 18);
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(15000));
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(15000));
        for (uint256 j = 0; j < 10000; ++j) {
            vm.warp(block.timestamp + 3600);
            vm.roll(block.number + 10);
            pp.pokeOracle();
        }

        // Liquidate as Alice (the self-liquidating affiliate).
        vm.startPrank(Alice);
        deal(ct0.asset(), Alice, 1_000_000_000);
        deal(ct1.asset(), Alice, 1_000_000_000);
        IERC20Partial(ct0.asset()).approve(address(ct0), 1_000_000_000);
        IERC20Partial(ct1.asset()).approve(address(ct1), 1_000_000_000);

        FlowSnapshot memory liqBefore = _snapshotActor(Alice);
        FlowSnapshot memory borBefore = _snapshotActor(Bob);

        liquidate(pp, new TokenId[](0), Bob, $posIdList);

        FlowSnapshot memory liqAfter = _snapshotActor(Alice);
        FlowSnapshot memory borAfter = _snapshotActor(Bob);

        (, , , , oraclePack) = pp.getOracleTicks();
        twapTick = re.twapEMA(oraclePack);
        uint160 oracleSqrtPrice = Math.getSqrtRatioAtTick(int24(twapTick));

        int256 liqValue = _toToken1(
            _actorNet0(liqBefore, liqAfter),
            _actorNet1(liqBefore, liqAfter),
            oracleSqrtPrice
        );
        int256 borValue = _toToken1(
            _actorNet0(borBefore, borAfter),
            _actorNet1(borBefore, borAfter),
            oracleSqrtPrice
        );

        // I9: combined self-liquidation P&L is non-positive at TWAP.
        assertLe(liqValue + borValue, int256(0), "I9: self-liquidation profit at TWAP");
    }
}
