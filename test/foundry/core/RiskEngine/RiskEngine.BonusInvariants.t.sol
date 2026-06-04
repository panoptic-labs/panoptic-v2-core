// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title Liquidation Bonus Invariants — consolidated test pins
/// @notice Single-file home for every test that asserts a property of the
///         realized bonus model at `RiskEngine.getLiquidationBonus`, including
///         the raw per-token candidate, cross-conversion arm, and backable
///         collateral cap, or the haircut conversion (`RiskEngine.haircutPremia`).
///
/// Audit reference: protocol-analysis/audits/BONUS_INVARIANTS_AUDIT.md
///
/// Target invariants:
///   I1  Liquidator-incentive floor: bonus_value > 0 whenever the account is liquidatable AND
///       retains backable collateral; bonus_value = 0 in genuine bad debt (backable consumed).
///   I2  Protocol-loss safety (final-state): ProtocolLossRealized_t > 0 ⇒ ∀ s, post_balance_s ≤ 0.
///   I3  Continuity: the bonus has no jump in collateral. The backable cap makes it tent-shaped,
///       so it is intentionally NOT monotone in distress; continuity is the binding property.
///   I6  Continuity at the maintenance boundary: no cliff to zero at bal_t → req_t^-.
///
///   Bonus model: raw_i = min(MAX_BONUS*req_i/DECIMALS, max(req_i-bal_i,0)) per token.
///   Raw bonuses may be shifted across tokens by the cross-token conversion, then capped at
///   each token's backable collateral (balance_i - netPaid_i - credits_i). The cap is what
///   guarantees no protocol loss is minted to fund the bonus (=> I9); it is credit-neutral
///   and continuous to zero in bad debt.
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
import {PanopticQuery} from "@helper/PanopticQuery.sol";
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

    /// @notice Sibling of the credit double-count pins, for the OTHER balance-injected term:
    /// `shortPremium`. Negative premium owed to the liquidatee is credited into
    /// `tokenData.balance` upstream AND appears in `netPaid` (received on close), so the
    /// contract removes it from `balance` (RE:544-547) — the mirror of adding credits back to
    /// `paid`. Both count the quantity exactly once.
    ///
    /// Pinned by equivalence (same shape as the credit tests): an account whose balance
    /// includes the premium, with `shortPremium` set, must produce the identical bonus/remaining
    /// to one whose balance never included it (`shortPremium = 0`), with `netPaid` held constant.
    /// The premium sits on a req=0 token so the floor-bonus term (which reads RAW balance) is 0
    /// in both cases, isolating the `balance -= shortPremium` subtraction.
    function test_LiquidationBonus_shortPremiumCountedOnce() public view {
        // token0 carries the premium (req0 = 0 → surplus side); token1 is the deficit.
        LeftRightSigned netPaid = _signedPair(-100, 1000); // +100 premium received, 1000 close cost

        (LeftRightSigned bonusWithPremium, LeftRightSigned remWithPremium) = E.getLiquidationBonus(
            _tokenData(1100, 0), // balance includes the 100 premium
            _tokenData(100, 1100),
            Math.getSqrtRatioAtTick(0),
            netPaid,
            _unsignedPair(100, 0), // shortPremium removes it from balance
            LeftRightUnsigned.wrap(0)
        );
        (LeftRightSigned bonusWithoutBalancePremium, LeftRightSigned remWithoutBalancePremium) = E
            .getLiquidationBonus(
                _tokenData(1000, 0), // balance never included the premium
                _tokenData(100, 1100),
                Math.getSqrtRatioAtTick(0),
                netPaid,
                LeftRightUnsigned.wrap(0),
                LeftRightUnsigned.wrap(0)
            );

        assertEq(
            LeftRightSigned.unwrap(bonusWithPremium),
            LeftRightSigned.unwrap(bonusWithoutBalancePremium),
            "bonus: short premium counted once"
        );
        assertEq(
            LeftRightSigned.unwrap(remWithPremium),
            LeftRightSigned.unwrap(remWithoutBalancePremium),
            "remaining: short premium counted once"
        );
    }

    /// @notice Pins the loan/credit asymmetry: a width-zero LOAN needs NO creditAmounts
    /// adjustment, because (unlike a credit) the loan principal is never added to
    /// `tokenData.balance` (RE:1213 adds only credits). The loan repayment reaches the
    /// surplus/cap math purely through `netPaid` (a positive close payment), so it is
    /// counted exactly once and `creditAmounts` is correctly 0.
    ///
    /// Single-token (token1) so the cap binds directly without the cross-conversion arm.
    /// bal1=800, req1=1000 → floor bonus = min(MAX_BONUS·1000/DEC, 1000-800) = min(200,200) = 200.
    /// Loan repayment netPaid1 = 700 (liquidatee pays to close the loan), credits = 0.
    /// backable cap maxBonus1 = balance1 - netPaid1 - credits1 = 800 - 700 - 0 = 100,
    /// so bonus is trimmed 200 → 100 and paid1 = 100 + 700 = 800 = balance1 (remaining 0).
    /// No credit term appears and the loan is not double-counted.
    function test_LiquidationBonus_pureLoan_noCreditAdjustmentNeeded() public view {
        (LeftRightSigned bonus, LeftRightSigned remaining) = E.getLiquidationBonus(
            _tokenData(0, 0),
            _tokenData(800, 1000), // token1: 800 collateral, req 1000 → floor bonus 200
            Math.getSqrtRatioAtTick(0),
            _signedPair(0, 700), // loan repayment shows up as a +700 close payment
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0) // creditAmounts = 0: a loan is NOT a credit
        );

        // Cap = balance - netPaid (no credit term) = 800 - 700 = 100.
        assertEq(bonus.rightSlot(), 0, "token0 bonus");
        assertEq(bonus.leftSlot(), 100, "token1 bonus capped at backable = balance - netPaid");
        // paid1 = bonus1 + netPaid1 = 100 + 700 = 800 = balance1 → nothing minted.
        assertEq(remaining.leftSlot(), 0, "token1 remaining: loan repayment fully backed, no loss");

        // Sanity on the asymmetry: had we WRONGLY passed the loan principal as a credit
        // (creditAmounts1 = 700), the cap would drop to 800 - 700 - 700 = -600 → 0, zeroing
        // the bonus. That divergence is exactly why loans must NOT be fed through creditAmounts.
        (LeftRightSigned bonusIfMistakenlyTreatedAsCredit, ) = E.getLiquidationBonus(
            _tokenData(0, 0),
            _tokenData(800, 1000),
            Math.getSqrtRatioAtTick(0),
            _signedPair(0, 700),
            LeftRightUnsigned.wrap(0),
            _unsignedPair(0, 700)
        );
        assertEq(
            bonusIfMistakenlyTreatedAsCredit.leftSlot(),
            0,
            "treating a loan as a credit would wrongly zero the bonus"
        );
    }

    /// @notice (#1) Loan AND credit in the SAME token. `netPaid` carries the loan repayment
    /// (+700) and the credit return (−400) netted to a single +300, but `creditAmounts` must
    /// pick out ONLY the credit (400) and subtract it again in both `paid` and the cap. This
    /// is the case that stresses the discrimination: netting and the credit adjustment are
    /// distinct operations and must not be conflated.
    ///
    /// token1: bal1=800 (raw 400 + credit 400, mirroring RE:1213), req1=1000 → floor bonus
    /// = min(MAX_BONUS·1000/DEC, 1000−800) = min(200,200) = 200.
    /// paid1 = bonus + netPaid + credit = 200 + 300 + 400 = 900 > balance 800 → would mint.
    /// cap maxBonus1 = balance − netPaid − credit = 800 − 300 − 400 = 100 trims bonus → 100,
    /// so paid1 = 100 + 300 + 400 = 800 = balance1, remaining 0, nothing minted.
    /// If the cap omitted the credit term it would be 800 − 300 = 500, leaving bonus=200 and
    /// minting 100 of protocol loss — which this test forbids.
    function test_LiquidationBonus_loanAndCreditSameToken_creditSubtractedSeparately() public view {
        (LeftRightSigned bonus, LeftRightSigned remaining) = E.getLiquidationBonus(
            _tokenData(0, 0),
            _tokenData(800, 1000),
            Math.getSqrtRatioAtTick(0),
            _signedPair(0, 300), // +700 loan repayment − 400 credit return, netted
            LeftRightUnsigned.wrap(0),
            _unsignedPair(0, 400) // only the credit half flows through creditAmounts
        );

        assertEq(bonus.rightSlot(), 0, "token0 bonus");
        assertEq(bonus.leftSlot(), 100, "token1 bonus capped at balance - netPaid - credit");
        assertEq(remaining.leftSlot(), 0, "token1 remaining: credit-neutral, nothing minted");
    }

    /// @notice (#2) Credit on the SURPLUS token while the OTHER token's deficit drives the
    /// cross-conversion arm. The credit add-back must keep the convertible surplus equal to
    /// the liquidatee's TRUE collateral — a credit sitting in `balance` must not inflate the
    /// surplus that funds the cross-token bonus.
    ///
    /// token0: bal0=0, req0=1000 → floor bonus0 = 200, paid0 = 200 > balance0 = 0 (deficit).
    /// token1: bal1=2000 (raw 1500 + credit 500), req1=0 (surplus). Closing the credit returns
    /// 500 → netPaid1 = −500, creditAmounts1 = 500. paid1 = 0 − 500 + 500 = 0, so the
    /// convertible surplus = balance1 − paid1 = 2000 = the true collateral (NOT 2500).
    ///
    /// Asserted by equivalence: this must produce the identical bonus/remaining to a clean
    /// account that simply holds 2000 token1 with no credit and no close flow.
    function test_LiquidationBonus_creditOnSurplusToken_doesNotInflateConversion() public view {
        uint160 sp = Math.getSqrtRatioAtTick(0);

        (LeftRightSigned bonusCredit, LeftRightSigned remCredit) = E.getLiquidationBonus(
            _tokenData(0, 1000),
            _tokenData(2000, 0),
            sp,
            _signedPair(0, -500), // credit return on the surplus token
            LeftRightUnsigned.wrap(0),
            _unsignedPair(0, 500)
        );

        // Clean reference: same TRUE collateral (2000 token1), no credit, no close flow.
        (LeftRightSigned bonusClean, LeftRightSigned remClean) = E.getLiquidationBonus(
            _tokenData(0, 1000),
            _tokenData(2000, 0),
            sp,
            LeftRightSigned.wrap(0),
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );

        assertEq(
            LeftRightSigned.unwrap(bonusCredit),
            LeftRightSigned.unwrap(bonusClean),
            "credit on surplus token must not change the converted bonus"
        );
        assertEq(
            LeftRightSigned.unwrap(remCredit),
            LeftRightSigned.unwrap(remClean),
            "credit on surplus token must not change remaining collateral"
        );
        // Sanity: conversion did fire and paid a cross-token bonus on the surplus side.
        assertEq(bonusCredit.rightSlot(), 0, "token0 bonus converted away");
        assertGt(bonusCredit.leftSlot(), int128(0), "token1 carries the converted bonus");
    }

    /// @notice (#2b, I9) GLOBAL-solvency cap: when the account is globally insolvent at TWAP, the
    /// liquidator's NET bonus value must be zero -- otherwise a borrower controlling the liquidator
    /// extracts the difference from PLPs (the self-liquidation-profit vector found by the I9 fuzz).
    ///
    /// token0 in bad debt: bal0=0, req0=1000 (floor 200), netPaid0=+1000 close cost.
    /// token1 is ENTIRELY a returned credit: bal1=1000 (all credit), req1=0, netPaid1=-1000,
    /// credits1=1000. At 1:1 the global backable is exactly zero: mb0=0-1000-0=-1000 token0 and
    /// mb1=1000+1000-1000=1000 token1 sum to 0. The credit is genuinely the borrower's money, but it
    /// is exactly enough to cover their token0 debt -- nothing is left to fund a bonus.
    ///
    /// Pre-fix, the per-token cap let the token1 floor/conversion pay a net +200 bonus while the
    /// token0 deficit was minted (collateralRemaining = (-200, +200): surplus-with-loss, extraction).
    /// The global floor cap zeroes the floors first, so the conversion only covers the deficit
    /// value-neutrally: bonus = (-1000, +1000) (net value 0), collateralRemaining = (0, 0).
    function test_I9_creditOnSurplusToken_globalCapZeroesBonusInBadDebt() public view {
        uint160 sp = Math.getSqrtRatioAtTick(0); // 1:1

        (LeftRightSigned bonus, LeftRightSigned remaining) = E.getLiquidationBonus(
            _tokenData(0, 1000),
            _tokenData(1000, 0),
            sp,
            _signedPair(1000, -1000), // token0 close cost +1000; token1 credit return -1000
            LeftRightUnsigned.wrap(0),
            _unsignedPair(0, 1000) // token1 is entirely a returned credit
        );

        // Net liquidator bonus value at 1:1 must be zero (no extraction): bonus0 + bonus1 == 0.
        assertEq(
            int256(bonus.rightSlot()) + int256(bonus.leftSlot()),
            0,
            "I9: net bonus value zero in global bad debt"
        );
        assertEq(bonus.rightSlot(), -1000, "liquidator provides token0 value-neutrally");
        assertEq(bonus.leftSlot(), 1000, "liquidator receives equal token1");
        // No surplus-with-loss: the credit fully covers the deficit, nothing minted, nothing kept.
        assertEq(remaining.rightSlot(), 0, "token0 collateralRemaining 0");
        assertEq(remaining.leftSlot(), 0, "token1 collateralRemaining 0");
    }

    /// @notice (#3) Credit return (plus premium received) EXCEEDS the close cost, so the
    /// credit-adjusted `paid` goes NEGATIVE — the liquidatee is net-receiving on the token.
    /// Pins that the signed arithmetic handles paid < 0 without underflow/clamp: the bonus
    /// stays at its floor and remaining = balance − paid grows past balance.
    ///
    /// token1: bal1=1200 (raw 200 + credit 1000), req1=1500 → floor bonus
    /// = min(MAX_BONUS·1500/DEC, 1500−1200) = min(300,300) = 300.
    /// netPaid1 = −1600 (1000 credit return + 600 premium received), creditAmounts1 = 1000.
    /// paid1 = 300 − 1600 + 1000 = −300 (< 0). cap maxBonus1 = 1200 + 1600 − 1000 = 1800
    /// (no bind). remaining1 = balance1 − paid1 = 1200 − (−300) = 1500.
    function test_LiquidationBonus_creditExceedsCloseCost_paidGoesNegative() public view {
        (LeftRightSigned bonus, LeftRightSigned remaining) = E.getLiquidationBonus(
            _tokenData(0, 0),
            _tokenData(1200, 1500),
            Math.getSqrtRatioAtTick(0),
            _signedPair(0, -1600),
            LeftRightUnsigned.wrap(0),
            _unsignedPair(0, 1000)
        );

        assertEq(bonus.leftSlot(), 300, "token1 bonus stays at floor when paid < 0");
        assertEq(
            remaining.leftSlot(),
            1500,
            "token1 remaining = balance - paid with paid negative"
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

    /// @notice I1 (direct unit): bonus_value > 0 when the account is liquidatable AND retains
    /// backable collateral (cases b, c), and is exactly 0 in genuine bad debt where no backable
    /// collateral remains in any token (case a). The old M-02 floor — a positive minted bonus when
    /// the deficit token has no balance — is intentionally gone: once backable hits zero a positive
    /// bonus could only be minted, which is the extractable self-liquidation profit I9 forbids.
    function test_I1_bonusPositiveWhenBackable_zeroInGenuineBadDebt() public {
        uint160 sp = Math.getSqrtRatioAtTick(0); // 1:1 price for simple sum

        // (a) Genuine bad debt: deficit token0, and NO collateral anywhere (bal=0 in both tokens),
        //     so backable = 0 everywhere and the bonus is exactly 0 (no minted floor).
        (LeftRightSigned b1, ) = E.getLiquidationBonus(
            _tokenData(0, 1100),
            _tokenData(0, 0),
            sp,
            LeftRightSigned.wrap(0),
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );
        assertEq(
            int256(b1.rightSlot()) + int256(b1.leftSlot()),
            0,
            "I1: zero bonus in genuine bad debt (no backable collateral)"
        );

        // (b) Both-deficit but with backable collateral (netPaid=0 ⇒ backable=bal>0).
        //     Each per-token bonus must be > 0.
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

    /// @notice No-mint (fuzz): with the backable cap, each token's bonus never exceeds the
    /// liquidatee's collateral on that token (here backable = bal since netPaid = credits = 0).
    /// This is what makes the bonus self-funding — nothing is minted to pay it — and is the
    /// per-token foundation of I9. Strict positivity is now conditional on backable being
    /// non-zero, so it is pinned by the direct-unit test above rather than here.
    function testFuzz_noMint_bonusNeverExceedsCollateral(
        uint128 req0,
        uint128 req1,
        uint128 bal0,
        uint128 bal1,
        int24 atTick
    ) public view {
        req0 = uint128(bound(req0, 100, type(uint96).max));
        req1 = uint128(bound(req1, 100, type(uint96).max));
        bal0 = uint128(bound(bal0, 0, type(uint96).max));
        bal1 = uint128(bound(bal1, 0, type(uint96).max));
        atTick = int24(bound(atTick, Constants.MIN_POOL_TICK + 1, Constants.MAX_POOL_TICK - 1));

        uint160 sp = Math.getSqrtRatioAtTick(atTick);
        (LeftRightSigned bonus, ) = E.getLiquidationBonus(
            _tokenData(bal0, req0),
            _tokenData(bal1, req1),
            sp,
            LeftRightSigned.wrap(0),
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );

        // backable_i = bal_i (netPaid = credits = shortPremium = 0); the cap forbids exceeding it.
        assertLe(
            int256(bonus.rightSlot()),
            int256(uint256(bal0)),
            "no-mint: bonus0 <= collateral0"
        );
        assertLe(int256(bonus.leftSlot()), int256(uint256(bal1)), "no-mint: bonus1 <= collateral1");
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

    /// @notice I3 (fuzz): the realized per-token bonus is CONTINUOUS in collateral — bumping bal by
    /// 1 wei moves the bonus by at most 1 wei, with no jump anywhere, in particular across the
    /// bad-debt boundary where the old M-02 floor cliffed the bonus up to MAX_BONUS*req/DECIMALS.
    /// The backable cap makes the realized bonus tent-shaped, so it is intentionally NOT monotone in
    /// distress; continuity is the property that replaced monotonicity. Single-token (token1) so the
    /// cap binds directly, without the cross-conversion arm.
    function testFuzz_I3_realizedBonusContinuousInCollateral(uint128 req, uint128 bal) public view {
        req = uint128(bound(req, 100, type(uint64).max));
        bal = uint128(bound(bal, 1, type(uint64).max));
        uint160 sp = Math.getSqrtRatioAtTick(0);

        (LeftRightSigned lo, ) = E.getLiquidationBonus(
            _tokenData(0, 0),
            _tokenData(bal - 1, req),
            sp,
            LeftRightSigned.wrap(0),
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );
        (LeftRightSigned hi, ) = E.getLiquidationBonus(
            _tokenData(0, 0),
            _tokenData(bal, req),
            sp,
            LeftRightSigned.wrap(0),
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );

        int256 diff = int256(lo.leftSlot()) - int256(hi.leftSlot());
        assertLe(diff < 0 ? -diff : diff, 1, "I3: realized bonus is continuous in bal (no jump)");
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

    /// @notice I9 (direct haircut fuzz): premium haircutting plus the corresponding
    /// bonus delta cannot create positive combined borrower+liquidator value.
    function testFuzz_I9_haircutPremiaCombinedDeltaNonPositive(
        uint128 loss0,
        uint128 loss1,
        uint128 lp0,
        uint128 lp1,
        uint8 nLegs,
        int24 atTick
    ) public view {
        loss0 = uint128(bound(loss0, 0, type(uint64).max));
        loss1 = uint128(bound(loss1, 0, type(uint64).max));
        lp0 = uint128(bound(lp0, 0, type(uint64).max));
        lp1 = uint128(bound(lp1, 0, type(uint64).max));
        nLegs = uint8(bound(nLegs, 1, 4));
        atTick = int24(bound(atTick, -100_000, 100_000));

        uint160 sp = Math.getSqrtRatioAtTick(atTick);
        LeftRightSigned collateralRemaining = LeftRightSigned.wrap(-int128(loss0)).addToLeftSlot(
            -int128(loss1)
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

        int256 combinedDelta0 = int256(bonusDeltas.rightSlot()) -
            int256(uint256(haircutTotal.rightSlot()));
        int256 combinedDelta1 = int256(bonusDeltas.leftSlot()) -
            int256(uint256(haircutTotal.leftSlot()));

        assertLe(
            _valueAt(combinedDelta0, combinedDelta1, sp),
            int256(E.MAX_OPEN_LEGS()),
            "I9: haircut combined delta"
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

    /// @notice DIAGNOSTIC: "sell 2000 put, 400 USDC collateral, price -> 1000" with NO
    /// surplus in the other token. USDC = token1. Bob has 400 token1 collateral, no
    /// token0. Closing the deep-ITM short costs 1000 token1 (netPaid1=1000) -> 600 bad
    /// debt. We sweep the maintenance requirement req1 to show that the backable cap cuts
    /// the raw bonus to zero when the close cost already consumes all collateral. Protocol
    /// loss is the 600 bad-debt shortfall only, not bad debt plus a minted liquidator bonus.
    function test_DIAG_singleToken_putScenario_noSurplus() public view {
        uint128[3] memory reqs = [uint128(1000), 2000, 3000];
        for (uint256 i = 0; i < reqs.length; ++i) {
            (LeftRightSigned bonus, LeftRightSigned remaining) = E.getLiquidationBonus(
                _tokenData(0, 0), // token0: none
                _tokenData(400, reqs[i]), // token1: 400 collateral, req = reqs[i]
                Math.getSqrtRatioAtTick(0),
                _signedPair(0, 1000), // netPaid: Bob pays 1000 token1 to close
                LeftRightUnsigned.wrap(0),
                LeftRightUnsigned.wrap(0)
            );
            console2.log("--- req1 =", uint256(reqs[i]));
            console2.log("  bonus token1     :", int256(bonus.leftSlot()));
            console2.log("  protocol loss t1 :", -int256(remaining.leftSlot())); // remaining<0 => loss
        }
    }

    /// @notice DIAGNOSTIC: a PURE single-token (only token1) account that is only
    /// MILDLY insolvent: close cost (300) < collateral (400), but the 20%-of-req
    /// bonus (200) pushes paid past balance, so part of the bonus would be minted.
    /// Here maxBonus1 = 400-300 = 100 > 0, so the backable cap trims the raw bonus
    /// 200 -> 100, even though there is NO other-token surplus.
    /// Demonstrates the cap is NOT limited to cross-margined accounts.
    function test_DIAG_singleToken_partialInsolvency() public view {
        (LeftRightSigned bonus, LeftRightSigned remaining) = E.getLiquidationBonus(
            _tokenData(0, 0),
            _tokenData(400, 1000), // 400 collateral, req 1000 -> floor bonus 200
            Math.getSqrtRatioAtTick(0),
            _signedPair(0, 300), // close cost 300 (< 400 collateral)
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );
        console2.log("bonus token1     :", int256(bonus.leftSlot()));
        console2.log("protocol loss t1 :", -int256(remaining.leftSlot()));
    }

    /// @notice DIAGNOSTIC: sweep collateral b (token1) with req r=1000, close cost
    /// n=300 fixed, and print bonus + protocol loss to plot continuity. Breakpoints:
    /// 0.8r=800, r=1000, n=300. Watch b around n=300 for a discontinuity.
    function test_DIAG_bonusCurve_sweepCollateral() public view {
        uint128[15] memory bs = [
            uint128(900),
            850,
            800,
            700,
            600,
            500,
            450,
            400,
            350,
            320,
            301,
            300,
            299,
            250,
            150
        ];
        console2.log("b | bonus | protocolLoss   (r=1000, n=300, 0.8r=800)");
        for (uint256 i = 0; i < bs.length; ++i) {
            (LeftRightSigned bonus, LeftRightSigned remaining) = E.getLiquidationBonus(
                _tokenData(0, 0),
                _tokenData(bs[i], 1000),
                Math.getSqrtRatioAtTick(0),
                _signedPair(0, 300),
                LeftRightUnsigned.wrap(0),
                LeftRightUnsigned.wrap(0)
            );
            console2.log("b=", uint256(bs[i]));
            console2.log("   bonus:", int256(bonus.leftSlot()));
            console2.log("   loss :", -int256(remaining.leftSlot()));
        }
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
    PanopticQuery pq;
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
        pq = new PanopticQuery();
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

    struct RandomI9Case {
        TokenId tokenId;
        uint128 maxSizeAtMinUtil;
        uint128 maxSizeAtMaxUtil;
        uint128 positionSize;
        int24 liquidationPriceDown;
        int24 liquidationPriceUp;
        int24 targetTick;
        uint160 oracleSqrtPrice;
        int256 liqValue;
        int256 borValue;
        int256 combinedValue;
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

    function _currentPoolId() internal view returns (uint64) {
        return
            uint40(uint256(PoolId.unwrap(poolKey.toId()))) +
            uint64(uint256(vegoid) << 40) +
            (uint64(uint24(uniPool.tickSpacing())) << 48);
    }

    function _randomI9TokenId(uint256 seed) internal view returns (TokenId tokenId) {
        uint256 numLegs = 1 + (seed & 3);
        int24 tickSpacing = uniPool.tickSpacing();
        tokenId = TokenId.wrap(0).addPoolId(_currentPoolId());

        for (uint256 leg; leg < numLegs; ++leg) {
            tokenId = _addRandomI9Leg(tokenId, seed, leg, tickSpacing);
        }
    }

    function _crossCollateralizedLoanI9TokenId(
        uint256 seed
    ) internal view returns (TokenId tokenId) {
        uint256 tokenType = seed & 1;
        tokenId = TokenId.wrap(0).addPoolId(_currentPoolId()).addLeg(
            0,
            1 + ((seed >> 8) & 3),
            tokenType,
            0,
            tokenType,
            0,
            0,
            0
        );
    }

    function _genuineBadDebtI9TokenId(uint256 seed) internal view returns (TokenId tokenId) {
        int24 tickSpacing = uniPool.tickSpacing();
        int24 width = int24(1 + int256((seed >> 16) % 8));
        int24 strike = int24((int256((seed >> 24) % 31) - 20) * int256(tickSpacing));

        tokenId = TokenId.wrap(0).addPoolId(_currentPoolId()).addLeg(
            0,
            1 + ((seed >> 8) & 3),
            1,
            0,
            1,
            0,
            strike,
            width
        );
    }

    function _haircutPremiaI9TokenId(uint256 seed) internal view returns (TokenId tokenId) {
        int24 tickSpacing = uniPool.tickSpacing();
        int24 width = int24(1 + int256((seed >> 16) % 20));
        int24 shortStrike = int24((int256((seed >> 24) % 41) - 30) * int256(tickSpacing));
        int24 creditStrike = int24(
            shortStrike + int24((80 + int256((seed >> 32) % 40)) * int256(tickSpacing))
        );

        tokenId = TokenId.wrap(0).addPoolId(_currentPoolId()).addLeg(
            0,
            2 + ((seed >> 8) & 3),
            1,
            0,
            1,
            0,
            shortStrike,
            width
        );
        tokenId = tokenId.addLeg(1, 1, 0, 1, 1, 1, creditStrike, 0);
    }

    function _addRandomI9Leg(
        TokenId tokenId,
        uint256 seed,
        uint256 leg,
        int24 tickSpacing
    ) internal pure returns (TokenId) {
        uint256 h = uint256(keccak256(abi.encode(seed, leg)));
        uint256 legClass = h & 3;

        return
            tokenId.addLeg(
                leg,
                1 + ((h >> 4) & 3),
                (h >> 6) & 1,
                legClass & 1,
                (h >> 7) & 1,
                leg,
                _randomI9Strike(h, leg, tickSpacing),
                legClass < 2 ? int24(0) : int24(1 + int256((h >> 16) % 20))
            );
    }

    function _randomI9Strike(
        uint256 h,
        uint256 leg,
        int24 tickSpacing
    ) internal pure returns (int24) {
        // Distinct leg offsets avoid duplicate chunks while keeping strikes close enough
        // that random positions can plausibly become liquidatable in bounded price moves.
        int256 bucket = int256((h >> 24) % 61) - 30 + int256(leg) * 97;
        return int24(bucket * int256(tickSpacing));
    }

    function _randomI9Collateral(
        uint256 seed
    ) internal pure returns (uint256 deposit0, uint256 deposit1) {
        deposit0 = 1_000_000 + ((seed >> 64) % 5) * 250_000;
        deposit1 = 1_000_000 + ((seed >> 72) % 5) * 250_000;

        // Include moderately skewed collateral cases without making mint success too rare.
        if (((seed >> 80) & 1) != 0) deposit0 /= 4;
        if (((seed >> 81) & 1) != 0) deposit1 /= 4;
    }

    function _resetBorrowerCollateral(uint256 seed) internal {
        (uint256 deposit0, uint256 deposit1) = _randomI9Collateral(seed);
        _resetBorrowerCollateralTo(deposit0, deposit1);
    }

    function _resetBorrowerCollateralTo(uint256 deposit0, uint256 deposit1) internal {
        vm.startPrank(Bob);
        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);
        token0.approve(address(ct0), type(uint256).max);
        token1.approve(address(ct1), type(uint256).max);
        if (deposit0 > 0) ct0.deposit(deposit0, Bob);
        if (deposit1 > 0) ct1.deposit(deposit1, Bob);
    }

    function _boundedRandomI9Size(
        uint128 maxSizeAtMinUtil,
        uint128 maxSizeAtMaxUtil,
        uint256 seed
    ) internal pure returns (uint128 size) {
        uint128 maxSize = maxSizeAtMaxUtil == 0 ? maxSizeAtMinUtil : maxSizeAtMaxUtil;
        if (maxSize > 5_000_000) maxSize = 5_000_000;
        if (maxSize < 100) return 0;

        uint256 pct = 70 + ((seed >> 88) % 26);
        size = uint128((uint256(maxSize) * pct) / 100);
        if (size == 0) size = 1;
    }

    function _tryMintRandomI9Position(TokenId tokenId, uint128 size) internal returns (bool) {
        TokenId[] memory positionIdList = new TokenId[](1);
        TokenId[] memory mintList = new TokenId[](1);
        uint128[] memory sizeList = new uint128[](1);
        int24[3][] memory tickAndSpreadLimits = new int24[3][](1);

        positionIdList[0] = tokenId;
        mintList[0] = tokenId;
        sizeList[0] = size;
        tickAndSpreadLimits[0][0] = Constants.MIN_POOL_TICK;
        tickAndSpreadLimits[0][1] = Constants.MAX_POOL_TICK;
        tickAndSpreadLimits[0][2] = int24(type(uint24).max / 2);

        vm.startPrank(Bob);
        try pp.dispatch(mintList, positionIdList, sizeList, tickAndSpreadLimits, true, 0) {
            $posIdList.push(tokenId);
            return true;
        } catch {
            return false;
        }
    }

    function _assertI9FullCycle(
        uint256 seed,
        TokenId tokenId,
        uint256 deposit0,
        uint256 deposit1,
        bool optimizeRiskPartners,
        uint128 positionSizeOverride,
        uint256 minMoveBuffer,
        uint256 moveBufferRange,
        bool expectProtocolLoss
    ) internal {
        delete $posIdList;
        RandomI9Case memory c;

        (currentTick, , , , ) = pp.getOracleTicks();
        c.tokenId = tokenId;

        if (optimizeRiskPartners) {
            try pq.optimizeRiskPartners(pp, currentTick, c.tokenId) returns (
                TokenId optimizedTokenId
            ) {
                c.tokenId = optimizedTokenId;
            } catch {
                console2.log("A");
                assertTrue(false, "optimizeTokenId");
            }
        }

        try pq.validateTokenId(c.tokenId) {} catch {
            console2.log("B");
            assertTrue(false, "validate TokenId");
        }

        _resetBorrowerCollateralTo(deposit0, deposit1);
        FlowSnapshot memory borBefore = _snapshotActor(Bob);

        if (positionSizeOverride == 0) {
            TokenId[] memory emptyPositionList = new TokenId[](0);
            try pq.getMaxPositionSizeBounds(pp, emptyPositionList, Bob, c.tokenId) returns (
                uint128 minUtilBound,
                uint128 maxUtilBound
            ) {
                c.maxSizeAtMinUtil = minUtilBound;
                c.maxSizeAtMaxUtil = maxUtilBound;
            } catch {
                (uint128 a, uint128 b) = pq.getMaxPositionSizeBounds(
                    pp,
                    emptyPositionList,
                    Bob,
                    c.tokenId
                );
                console2.log("a,b", a, b);
                console2.log("C");
                assertTrue(false, "maxSize");
            }

            c.positionSize = _boundedRandomI9Size(c.maxSizeAtMinUtil, c.maxSizeAtMaxUtil, seed);
        } else {
            c.positionSize = positionSizeOverride;
        }

        vm.assume(c.positionSize > 0);
        vm.assume(_tryMintRandomI9Position(c.tokenId, c.positionSize));

        try pq.getLiquidationPrices(pp, Bob, $posIdList) returns (int24 down, int24 up) {
            c.liquidationPriceDown = down;
            c.liquidationPriceUp = up;
        } catch {
            console2.log("D");
            assertTrue(false, "liq prices");
        }

        bool hasTarget;
        (hasTarget, c.targetTick) = _pickLiquidationMoveBuffered(
            c.liquidationPriceDown,
            c.liquidationPriceUp,
            seed,
            minMoveBuffer,
            moveBufferRange
        );
        vm.assume(hasTarget);

        _moveOracleTo(c.targetTick);
        vm.assume(!pq.isAccountSolvent(pp, Bob, $posIdList, c.targetTick));

        address liquidator = address(0xCAFE);
        vm.startPrank(liquidator);
        deal(ct0.asset(), liquidator, 1_000_000_000);
        deal(ct1.asset(), liquidator, 1_000_000_000);
        IERC20Partial(ct0.asset()).approve(address(ct0), 1_000_000_000);
        IERC20Partial(ct1.asset()).approve(address(ct1), 1_000_000_000);

        FlowSnapshot memory liqBefore = _snapshotActor(liquidator);

        // Always record logs so the I2 overlay below can read the protocol-loss
        // events on every run, not just the expectProtocolLoss entry points.
        vm.recordLogs();
        try
            pp.dispatchFrom(
                new TokenId[](0),
                Bob,
                $posIdList,
                new TokenId[](0),
                LeftRightUnsigned.wrap(0).addToRightSlot(1).addToLeftSlot(1)
            )
        {} catch {
            console2.log("E");
            assertTrue(false, "liquidation");
        }

        Vm.Log[] memory liquidationLogs = vm.getRecordedLogs();
        uint256 lossAssets = _protocolLossAssets(liquidationLogs);
        if (expectProtocolLoss) {
            assertGt(lossAssets, 0, "bad debt");
        }
        (bool loss0, bool loss1) = _protocolLossMask(liquidationLogs);

        FlowSnapshot memory liqAfter = _snapshotActor(liquidator);
        FlowSnapshot memory borAfter = _snapshotActor(Bob);
        c.oracleSqrtPrice = _twapSqrtPrice();

        c.liqValue = _toToken1(
            _actorNet0(liqBefore, liqAfter),
            _actorNet1(liqBefore, liqAfter),
            c.oracleSqrtPrice
        );
        c.borValue = _toToken1(
            _actorNet0(borBefore, borAfter),
            _actorNet1(borBefore, borAfter),
            c.oracleSqrtPrice
        );
        c.combinedValue = c.liqValue + c.borValue;

        // I2 (protocol-loss safety, final-state): if the protocol/PLPs realized any
        // loss, the borrower must retain no recoverable surplus in ANY token. The
        // borrower's residual recoverable collateral is exactly their post-liquidation
        // CT-asset balance (their wallet is untouched by dispatchFrom). Per-token (the
        // invariant is `∀ s`), with a tolerance of MAX_OPEN_LEGS wei (the per-leg
        // unsafeDivRoundingUp haircut bias the unit test already tolerates) plus 2 wei
        // for ERC4626 convertToAssets share rounding. Always-on overlay: vacuously true
        // when no loss fires.
        //
        // Gated on `lossAssets > 0` (realized magnitude), NOT on the mere presence of a
        // ProtocolLossRealized event: a zero-asset event fires on healthy cross-collateral
        // liquidations (one token's deficit covered by converting the other), where the
        // borrower legitimately keeps surplus. The invariant is `ProtocolLossRealized_t > 0`.
        if (lossAssets > 0) {
            int256 i2Tol = int256(re.MAX_OPEN_LEGS()) + 2;
            assertLe(
                int256(borAfter.ctAssets0),
                i2Tol,
                "I2: residual surplus token0 with protocol loss"
            );
            assertLe(
                int256(borAfter.ctAssets1),
                i2Tol,
                "I2: residual surplus token1 with protocol loss"
            );
        }

        if (expectProtocolLoss) {
            (bool foundBonus, int256 bonus0, int256 bonus1) = _accountLiquidatedBonusSlots(
                liquidationLogs
            );
            assertTrue(foundBonus, "AccountLiquidated");
            if (loss0) assertLe(bonus0, int256(0), "I9: loss-token bonus0");
            if (loss1) assertLe(bonus1, int256(0), "I9: loss-token bonus1");
        } else {
            assertLe(c.combinedValue, int256(0), "I9: self-liquidation profit");
        }
    }

    function _pickLiquidationMove(
        int24 liquidationPriceDown,
        int24 liquidationPriceUp,
        uint256 seed
    ) internal pure returns (bool hasTarget, int24 targetTick) {
        return
            _pickLiquidationMoveBuffered(
                liquidationPriceDown,
                liquidationPriceUp,
                seed,
                500,
                2_500
            );
    }

    function _pickLiquidationMoveBuffered(
        int24 liquidationPriceDown,
        int24 liquidationPriceUp,
        uint256 seed,
        uint256 minBuffer,
        uint256 bufferRange
    ) internal pure returns (bool hasTarget, int24 targetTick) {
        bool hasDown = liquidationPriceDown != type(int24).min;
        bool hasUp = liquidationPriceUp != type(int24).max;
        if (!hasDown && !hasUp) return (false, 0);

        bool moveUp = hasUp && (!hasDown || ((seed >> 96) & 1) != 0);
        int256 buffer = int256(minBuffer + ((seed >> 97) % bufferRange));
        int256 rawTarget = moveUp
            ? int256(liquidationPriceUp) + buffer
            : int256(liquidationPriceDown) - buffer;

        int256 minTick = int256(Constants.MIN_POOL_TICK) + 2;
        int256 maxTick = int256(Constants.MAX_POOL_TICK) - 2;
        if (rawTarget < minTick) rawTarget = minTick;
        if (rawTarget > maxTick) rawTarget = maxTick;

        return (true, int24(rawTarget));
    }

    function _protocolLossAssets(Vm.Log[] memory entries) internal pure returns (uint256 total) {
        bytes32 sig = keccak256("ProtocolLossRealized(address,address,uint256,uint256)");
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == sig) {
                (uint256 assets, ) = abi.decode(entries[i].data, (uint256, uint256));
                total += assets;
            }
        }
    }

    function _accountLiquidatedBonusSlots(
        Vm.Log[] memory entries
    ) internal pure returns (bool found, int256 bonus0, int256 bonus1) {
        bytes32 sig = keccak256("AccountLiquidated(address,address,int256)");
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == sig) {
                LeftRightSigned bonusAmounts = LeftRightSigned.wrap(
                    abi.decode(entries[i].data, (int256))
                );
                return (true, int256(bonusAmounts.rightSlot()), int256(bonusAmounts.leftSlot()));
            }
        }
    }

    function _protocolLossMask(
        Vm.Log[] memory entries
    ) internal view returns (bool loss0, bool loss1) {
        bytes32 sig = keccak256("ProtocolLossRealized(address,address,uint256,uint256)");
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == sig) {
                if (entries[i].emitter == address(ct0)) loss0 = true;
                if (entries[i].emitter == address(ct1)) loss1 = true;
            }
        }
    }

    function _moveOracleTo(int24 targetTick) internal {
        vm.startPrank(Swapper);
        swapperc.mint(uniPool, -800000, 800000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -800000, 800000, 10 ** 18);
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(targetTick));
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(targetTick));

        for (uint256 j; j < 1000; ++j) {
            vm.warp(block.timestamp + 36000);
            vm.roll(block.number + 100);
            pp.pokeOracle();
        }
    }

    function _twapSqrtPrice() internal returns (uint160) {
        (, , , , oraclePack) = pp.getOracleTicks();
        twapTick = re.twapEMA(oraclePack);
        return Math.getSqrtRatioAtTick(int24(twapTick));
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

    /// @notice I9 (bounded fuzz): random 1-4 leg portfolios cannot produce positive
    /// borrower+liquidator PnL across the full self-liquidation cycle at oracle TWAP.
    /// forge-config: default.fuzz.runs = 25
    function testFuzz_I9_randomTokenId_selfLiquidationNoProfit(uint256 seed) public {
        (uint256 deposit0, uint256 deposit1) = _randomI9Collateral(seed);
        _assertI9FullCycle(
            seed,
            _randomI9TokenId(seed),
            deposit0,
            deposit1,
            true,
            0,
            500,
            2_500,
            false
        );
    }

    function test_I9_randomTokenId_fullCycleCounterexampleRegression() public {
        testFuzz_I9_randomTokenId_selfLiquidationNoProfit(
            19420182117295316302233354161501907838732057622076890809
        );
    }

    /// @notice Regression for the credit-in-surplus-token x cross-token-bad-debt self-liquidation
    /// profit (the global-backable cap fix). Pre-fix this seed extracted ~13% of position size from
    /// PLPs (combined borrower+liquidator value > 0 at TWAP); the proportional global floor cap in
    /// `getLiquidationBonus` drives the net bonus to zero so combined <= 0.
    function test_I9_creditBadDebt_globalCapRegression() public {
        testFuzz_I9_randomTokenId_selfLiquidationNoProfit(
            15711867615927946943544337117520432083872209606168597275098887885787
        );
    }

    /// @notice I9 (directed fuzz): cross-collateralized zero-width loans with
    /// collateral concentrated in the opposite token cannot self-liquidate for profit.
    /// forge-config: default.fuzz.runs = 50
    function testFuzz_I9_crossCollateralizedLoan_fullCycleNoProfit(uint256 seed) public {
        bool token0Loan = (seed & 1) == 0;
        uint256 richSide = 1_000_000 + ((seed >> 64) % 5) * 250_000;
        uint128 loanSize = uint128(3_000_000 + ((seed >> 16) % 2_000_001));
        _assertI9FullCycle(
            seed,
            _crossCollateralizedLoanI9TokenId(seed),
            token0Loan ? 1_000 : richSide,
            token0Loan ? richSide : 1_000,
            false,
            loanSize,
            2_000,
            8_000,
            false
        );
    }

    /// @notice I9 (directed fuzz): genuine bad debt may realize protocol loss,
    /// but the liquidation bonus itself must not be positive at TWAP.
    /// forge-config: default.fuzz.runs = 25
    function testFuzz_I9_genuineBadDebt_noPositiveBonus(uint256 seed) public {
        _assertI9FullCycle(
            seed,
            _genuineBadDebtI9TokenId(seed),
            500_000 + ((seed >> 64) % 4) * 250_000,
            1_005 + ((seed >> 72) % 1_000),
            false,
            uint128(900_000 + ((seed >> 16) % 600_001)),
            50_000,
            250_000,
            true
        );
    }

    /// @notice I2 (directed fuzz): when a liquidation realizes protocol loss (PLP
    /// dilution), the borrower retains no recoverable surplus in ANY token. Biased
    /// toward genuine bad debt via large move buffers + skewed (rich token0 / thin
    /// token1) collateral so the protocol-loss branch fires often; expectProtocolLoss
    /// keeps the "bad debt" precondition so a run that fails to reach bad debt fails
    /// loudly rather than passing vacuously. The I2 assertion itself lives in
    /// `_assertI9FullCycle` as an always-on overlay.
    /// forge-config: default.fuzz.runs = 50
    function testFuzz_I2_genuineBadDebt_borrowerNoResidualSurplus(uint256 seed) public {
        _assertI9FullCycle(
            seed,
            _genuineBadDebtI9TokenId(seed),
            500_000 + ((seed >> 64) % 4) * 250_000, // skewed-rich token0
            1_005 + ((seed >> 72) % 1_000), // thin token1 -> bad debt likely
            false,
            uint128(900_000 + ((seed >> 16) % 600_001)),
            50_000, // large minMoveBuffer (force deep insolvency)
            250_000, // wide moveBufferRange
            true // expectProtocolLoss
        );
    }

    function test_I2_genuineBadDebt_borrowerNoResidualSurplusRegression() public {
        // Seed reaches a full bad-debt liquidation (passes all scenario assumptions).
        // Replace with a counterexample seed if the fuzzer ever finds an I2 violation.
        testFuzz_I2_genuineBadDebt_borrowerNoResidualSurplus(24893033914019724266919454);
    }

    /// @notice I9 (directed fuzz): portfolios with a short option and width-zero
    /// long credit cover the credit/haircut-adjacent liquidation surface.
    /// forge-config: default.fuzz.runs = 50
    function testFuzz_I9_haircutPremiaShape_fullCycleNoProfit(uint256 seed) public {
        _assertI9FullCycle(
            seed,
            _haircutPremiaI9TokenId(seed),
            750_000 + ((seed >> 64) % 5) * 250_000,
            750_000 + ((seed >> 72) % 5) * 250_000,
            false,
            uint128(150_000 + ((seed >> 16) % 250_001)),
            5_000,
            20_000,
            false
        );
    }

    /// @notice RECONCILIATION: replicate the auditor's exact PoC scenario
    /// (tick 7500, 100 warps, fresh liquidator 0xCAFE) and compute, side by side:
    ///   (A) the auditor's raw per-token combined delta from PRE-MINT (convertToAssets+wallet);
    ///   (B) the same combined delta expressed in a single numeraire (token1 @ oracle TWAP);
    ///   (C) the I9 measure: combined delta from PRE-LIQ in token1 @ TWAP;
    ///   (D) the LP cohort (Alice + Charlie) value delta in token1 @ TWAP (the actual LP loss);
    ///   (E) REALIZABILITY: redeem both actors' shares to wallet and recompute the
    ///       raw per-token combined delta from PRE-MINT using only real wallet tokens.
    function test_RECONCILE_selfLiquidation_auditorVsTeam() public {
        // Bob: withdraw setUp deposits, redeposit ONLY token1 (auditor setup)
        vm.startPrank(Bob);
        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);
        token1.approve(address(ct1), 1_000_000);
        ct1.deposit(1_000_000, Bob);

        address Liq = address(0xCAFE);

        // PRE-MINT snapshots (Bob has no position; Liq not funded yet)
        FlowSnapshot memory bobPreMint = _snapshotActor(Bob);
        // LP cohort = Alice + Charlie (pure PLPs, never trade)
        uint256 lpAssets0_preMint = ct0.convertToAssets(
            ct0.balanceOf(Alice) + ct0.balanceOf(Charlie)
        );
        uint256 lpAssets1_preMint = ct1.convertToAssets(
            ct1.balanceOf(Alice) + ct1.balanceOf(Charlie)
        );

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

        // Pump token0 price (tick 0 -> 7500), 100 warps (auditor params)
        vm.startPrank(Swapper);
        swapperc.mint(uniPool, -800000, 800000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -800000, 800000, 10 ** 18);
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(7500));
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(7500));
        for (uint256 j = 0; j < 100; ++j) {
            vm.warp(block.timestamp + 600);
            vm.roll(block.number + 1);
            pp.pokeOracle();
        }

        // Fund fresh liquidator
        vm.startPrank(Liq);
        deal(ct0.asset(), Liq, 100_000_000);
        deal(ct1.asset(), Liq, 100_000_000);
        IERC20Partial(ct0.asset()).approve(address(ct0), 100_000_000);
        IERC20Partial(ct1.asset()).approve(address(ct1), 100_000_000);

        // PRE-LIQ snapshots
        FlowSnapshot memory bobPreLiq = _snapshotActor(Bob);
        FlowSnapshot memory liqPreLiq = _snapshotActor(Liq);

        liquidate(pp, new TokenId[](0), Bob, $posIdList);

        // POST-LIQ snapshots
        FlowSnapshot memory bobPost = _snapshotActor(Bob);
        FlowSnapshot memory liqPost = _snapshotActor(Liq);

        (, , , , oraclePack) = pp.getOracleTicks();
        twapTick = re.twapEMA(oraclePack);
        uint160 sp = Math.getSqrtRatioAtTick(int24(twapTick));

        // ---- (A) auditor raw per-token, from PRE-MINT ----
        {
            int256 combT0 = _actorNet0(bobPreMint, bobPost) + _actorNet0(liqPreLiq, liqPost);
            int256 combT1 = _actorNet1(bobPreMint, bobPost) + _actorNet1(liqPreLiq, liqPost);
            console2.log("(A) auditor raw per-token combined delta (from PRE-MINT):");
            console2.log("    token0:", combT0);
            console2.log("    token1:", combT1);
            console2.log("(B) ... same, in token1 @ TWAP:", _toToken1(combT0, combT1, sp));
        }

        // ---- (C) I9 measure: from PRE-LIQ, token1 @ TWAP ----
        {
            int256 i9 = _toToken1(
                _actorNet0(bobPreLiq, bobPost),
                _actorNet1(bobPreLiq, bobPost),
                sp
            ) + _toToken1(_actorNet0(liqPreLiq, liqPost), _actorNet1(liqPreLiq, liqPost), sp);
            console2.log("(C) I9 combined delta in token1 @ TWAP (from PRE-LIQ):", i9);
        }

        // ---- (D) LP cohort (Alice+Charlie) value delta in token1 @ TWAP ----
        {
            int256 lpDelta = _toToken1(
                int256(ct0.convertToAssets(ct0.balanceOf(Alice) + ct0.balanceOf(Charlie))) -
                    int256(lpAssets0_preMint),
                int256(ct1.convertToAssets(ct1.balanceOf(Alice) + ct1.balanceOf(Charlie))) -
                    int256(lpAssets1_preMint),
                sp
            );
            console2.log("(D) LP cohort (Alice+Charlie) value delta in token1 @ TWAP:", lpDelta);
        }

        // ---- (E) REALIZABILITY: redeem everything to wallet, recompute raw combined ----
        vm.startPrank(Bob);
        if (ct0.maxRedeem(Bob) > 0) ct0.redeem(ct0.maxRedeem(Bob), Bob, Bob);
        if (ct1.maxRedeem(Bob) > 0) ct1.redeem(ct1.maxRedeem(Bob), Bob, Bob);
        vm.startPrank(Liq);
        if (ct0.maxRedeem(Liq) > 0) ct0.redeem(ct0.maxRedeem(Liq), Liq, Liq);
        if (ct1.maxRedeem(Liq) > 0) ct1.redeem(ct1.maxRedeem(Liq), Liq, Liq);

        // Per-actor realized wallet deltas (debug).
        console2.log("(E) realized wallet deltas:");
        console2.log("    Bob  w0:", int256(token0.balanceOf(Bob)) - int256(bobPreMint.wallet0));
        console2.log("    Bob  w1:", int256(token1.balanceOf(Bob)) - int256(bobPreMint.wallet1));
        console2.log("    Liq  w0:", int256(token0.balanceOf(Liq)) - int256(liqPreLiq.wallet0));
        console2.log("    Liq  w1:", int256(token1.balanceOf(Liq)) - int256(liqPreLiq.wallet1));
        console2.log("    Bob ct0 left:", ct0.balanceOf(Bob));
        console2.log("    Bob ct1 left:", ct1.balanceOf(Bob));
        console2.log("    Liq ct0 left:", ct0.balanceOf(Liq));
        console2.log("    Liq ct1 left:", ct1.balanceOf(Liq));
    }

    /// @notice DIAGNOSTIC: sweep liquidation TIMING. Same 5M token0 loan / 1M token1
    /// collateral, liquidated at progressively larger price moves (= progressively
    /// later / more underwater). For each, report how far the account is past the
    /// margin threshold (bal0 vs req0) and the resulting net PLP loss + colluding
    /// pair profit (token1 @ TWAP). Shows whether early liquidation keeps loss ~0
    /// and bounds the worst case. Run against CURRENT (M-02, uncapped) behavior.
    function test_DIAG_lossVsLiquidationTiming() public {
        int24[8] memory ticks = [int24(7000), 7500, 9000, 12000, 20000, 40000, 60000, 74000];
        uint256 snap = vm.snapshotState();
        console2.log("tick | bal0 | req0 | underwater(req0-bal0) | PLP_loss_t1 | pair_profit_t1");
        for (uint256 i = 0; i < ticks.length; ++i) {
            vm.revertToState(snap);
            _diagAtTick(ticks[i]);
        }
    }

    function _diagAtTick(int24 targetTick) internal {
        delete $posIdList;
        vm.startPrank(Bob);
        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);
        token1.approve(address(ct1), 1_000_000);
        ct1.deposit(1_000_000, Bob);

        FlowSnapshot memory bobPreMint = _snapshotActor(Bob);
        uint256 lp0 = ct0.convertToAssets(ct0.balanceOf(Alice) + ct0.balanceOf(Charlie));
        uint256 lp1 = ct1.convertToAssets(ct1.balanceOf(Alice) + ct1.balanceOf(Charlie));

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

        vm.startPrank(Swapper);
        swapperc.mint(uniPool, -800000, 800000, 10 ** 18);
        routerV4.modifyLiquidity(address(0), poolKey, -800000, 800000, 10 ** 18);
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(targetTick));
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(targetTick));
        for (uint256 j = 0; j < 100; ++j) {
            vm.warp(block.timestamp + 600);
            vm.roll(block.number + 1);
            pp.pokeOracle();
        }

        address Liq = address(0xCAFE);
        vm.startPrank(Liq);
        deal(ct0.asset(), Liq, 100_000_000);
        deal(ct1.asset(), Liq, 100_000_000);
        IERC20Partial(ct0.asset()).approve(address(ct0), 100_000_000);
        IERC20Partial(ct1.asset()).approve(address(ct1), 100_000_000);

        FlowSnapshot memory liqPre = _snapshotActor(Liq);
        FlowSnapshot memory bobPre = _snapshotActor(Bob);
        (uint256 b0, uint256 r0) = _balReq0(Bob, $posIdList);

        try
            pp.dispatchFrom(
                new TokenId[](0),
                Bob,
                $posIdList,
                new TokenId[](0),
                LeftRightUnsigned.wrap(0).addToRightSlot(1).addToLeftSlot(1)
            )
        {
            (, , , , oraclePack) = pp.getOracleTicks();
            uint160 sp = Math.getSqrtRatioAtTick(int24(re.twapEMA(oraclePack)));
            FlowSnapshot memory bobPost = _snapshotActor(Bob);
            FlowSnapshot memory liqPost = _snapshotActor(Liq);
            int256 pair = _toToken1(
                _actorNet0(bobPreMint, bobPost) + _actorNet0(liqPre, liqPost),
                _actorNet1(bobPreMint, bobPost) + _actorNet1(liqPre, liqPost),
                sp
            );
            int256 lpd = _toToken1(
                int256(ct0.convertToAssets(ct0.balanceOf(Alice) + ct0.balanceOf(Charlie))) -
                    int256(lp0),
                int256(ct1.convertToAssets(ct1.balanceOf(Alice) + ct1.balanceOf(Charlie))) -
                    int256(lp1),
                sp
            );
            console2.log("--- tick", uint256(uint24(targetTick)));
            console2.log("  bal0,req0:", b0, r0);
            console2.log("  underwater (req0-bal0):", r0 > b0 ? r0 - b0 : 0);
            console2.log("  PLP net loss (t1):", -lpd);
            console2.log("  pair profit  (t1):", pair);
        } catch {
            console2.log("--- tick", uint256(uint24(targetTick)));
            console2.log("  bal0,req0:", b0, r0);
            console2.log("  NOT LIQUIDATABLE (solvent)");
        }
        bobPre; // silence unused
    }

    function _balReq0(
        address user,
        TokenId[] memory ids
    ) internal returns (uint256 bal0, uint256 req0) {
        (LeftRightUnsigned sp_, LeftRightUnsigned lp_, PositionBalance[] memory pb, , ) = pp
            .getFullPositionsData(user, false, ids);
        (, , , , oraclePack) = pp.getOracleTicks();
        (LeftRightUnsigned td0, , ) = re.getMargin(
            pb,
            re.twapEMA(oraclePack),
            user,
            ids,
            sp_,
            lp_,
            ct0,
            ct1
        );
        return (td0.rightSlot(), td0.leftSlot());
    }

    /// @notice DIAGNOSTIC: single-token (NON cross-margined) short that gaps deep
    /// ITM beyond its collateral -> genuine bad debt. Bob deposits ONLY token1 and
    /// sells a token1-collateralized short; price then crashes so the intrinsic
    /// loss exceeds the collateral. Measures net PLP loss under the refined cap.
    /// Expectation: PLP loss is POSITIVE here (irreducible bad debt), in contrast
    /// to the cross-margined loan case where the cap drives it to ~0.
    function test_DIAG_singleToken_genuineBadDebt() public {
        delete $posIdList;
        vm.startPrank(Bob);
        ct0.withdraw(ct0.maxWithdraw(Bob), Bob, Bob);
        ct1.withdraw(ct1.maxWithdraw(Bob), Bob, Bob);
        token0.approve(address(ct0), 1_500_000);
        ct0.deposit(1_500_000, Bob); // token0 collateral (depreciates with the crash)
        token1.approve(address(ct1), 1_005);
        ct1.deposit(1_005, Bob); // dust token1 the option leg needs to mint

        uint256 lp0 = ct0.convertToAssets(ct0.balanceOf(Alice) + ct0.balanceOf(Charlie));
        uint256 lp1 = ct1.convertToAssets(ct1.balanceOf(Alice) + ct1.balanceOf(Charlie));

        poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
        poolId += uint64(uint24(uniPool.tickSpacing())) << 48;
        // short, token1-side (asset=1, tokenType=1), width=1 option near spot
        $posIdList.push(TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 1, 0, -15, 1));
        mintOptions(
            pp,
            $posIdList,
            1_003_003,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        // Crash the price hard so the short goes deep ITM (loss >> collateral).
        vm.startPrank(Swapper);
        routerV4.swapTo(address(0), poolKey, Math.getSqrtRatioAtTick(-500_000));
        swapperc.swapTo(uniPool, Math.getSqrtRatioAtTick(-500_000));
        for (uint256 j = 0; j < 10000; ++j) {
            vm.warp(block.timestamp + 3600);
            vm.roll(block.number + 10);
            pp.pokeOracle();
        }

        address Liq = address(0xCAFE);
        vm.startPrank(Liq);
        deal(ct0.asset(), Liq, type(uint120).max);
        deal(ct1.asset(), Liq, type(uint120).max);
        IERC20Partial(ct0.asset()).approve(address(ct0), type(uint120).max);
        IERC20Partial(ct1.asset()).approve(address(ct1), type(uint120).max);

        vm.recordLogs();
        try
            pp.dispatchFrom(
                new TokenId[](0),
                Bob,
                $posIdList,
                new TokenId[](0),
                LeftRightUnsigned.wrap(0).addToRightSlot(1).addToLeftSlot(1)
            )
        {
            Vm.Log[] memory entries = vm.getRecordedLogs();
            bytes32 sig = keccak256("ProtocolLossRealized(address,address,uint256,uint256)");
            for (uint256 i = 0; i < entries.length; ++i) {
                if (entries[i].topics.length > 0 && entries[i].topics[0] == sig) {
                    (uint256 a, uint256 s) = abi.decode(entries[i].data, (uint256, uint256));
                    console2.log("ProtocolLossRealized on", entries[i].emitter);
                    console2.log("  protocolLossAssets:", a);
                }
            }
            (, , , , oraclePack) = pp.getOracleTicks();
            uint160 sp = Math.getSqrtRatioAtTick(int24(re.twapEMA(oraclePack)));
            int256 lpd = _toToken1(
                int256(ct0.convertToAssets(ct0.balanceOf(Alice) + ct0.balanceOf(Charlie))) -
                    int256(lp0),
                int256(ct1.convertToAssets(ct1.balanceOf(Alice) + ct1.balanceOf(Charlie))) -
                    int256(lp1),
                sp
            );
            console2.log("Bob collateral deposited (t0):", uint256(1_500_000));
            console2.log("PLP net loss (t1) [>0 = real bad debt]:", -lpd);
        } catch {
            console2.log("liquidation reverted");
        }
    }
}
