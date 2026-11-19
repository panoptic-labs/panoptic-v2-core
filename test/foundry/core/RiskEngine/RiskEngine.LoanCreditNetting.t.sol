// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RiskEngineHarness} from "./RiskEngineHarness.sol";
import {MockCollateralTracker} from "./mocks/MockCollateralTracker.sol";
import {PositionFactory} from "./helpers/PositionFactory.sol";
import {CollateralTrackerV2} from "@contracts/CollateralTracker.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";
import {TokenId} from "@types/TokenId.sol";

/// @notice Credits are added back to the account balance in `_getMargin` because the shares they burned are
/// returned when the credit closes. A credit funded by the shares a loan of the same token minted is not backed
/// by any deposit: the loan and the credit cancel in `netBorrows`, so the account owes no interest, and the
/// credited shares reserve PLP cash in the CollateralTracker without any cash having entered. Such an account
/// could freeze every PLP withdrawal for the loan margin alone.
/// Rule: when an account mints shares without cash in a token (a loan, or the part of a width-positive short's
/// notional that its chunk did not hold at the tick it was minted at), its credits in that token are charged in full
/// as a requirement. The credit stays in the balance (the pool's liquidation path subtracts it there itself), so
/// the account must fund the whole loan or short requirement with real deposits: `D + C >= req + C` iff `D >= req`.
contract RiskEngineLoanCreditNettingTest is Test {
    RiskEngineHarness internal E;
    MockCollateralTracker internal ct0;
    MockCollateralTracker internal ct1;

    address internal constant USER = address(0xA11CE);
    uint64 internal constant POOL_ID = 1 + (10 << 48); // tickSpacing = 10
    uint16 internal constant UTIL = 0; // loan margin at its floor
    uint128 internal constant SIZE = 1_000 ether;
    uint256 internal DEC;

    LeftRightUnsigned internal constant ZERO = LeftRightUnsigned.wrap(0);

    function setUp() public {
        E = new RiskEngineHarness(5_000_000, 5_000_000);
        DEC = E.DECIMALS();
        ct0 = new MockCollateralTracker();
        ct1 = new MockCollateralTracker();
        ct0.setGlobal(1_000_000_000 ether, 1_000_000_000 ether);
        ct1.setGlobal(1_000_000_000 ether, 1_000_000_000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Width-0 leg: `isLong == 0` is a loan, `isLong == 1` a credit, on `tokenType`.
    function _w0(uint256 isLong, uint256 tokenType) internal pure returns (TokenId) {
        return PositionFactory.makeLeg(POOL_ID, 0, 1, 0, isLong, tokenType, 0, 0, 0);
    }

    function _notional(TokenId id, uint128 size) internal pure returns (uint256) {
        LeftRightUnsigned moved = PanopticMath.getAmountsMoved(id, size, 0, false);
        return id.tokenType(0) == 0 ? moved.rightSlot() : moved.leftSlot();
    }

    function _one(
        TokenId a,
        uint128 sizeA
    ) internal pure returns (TokenId[] memory ids, PositionBalance[] memory bals) {
        ids = new TokenId[](1);
        bals = new PositionBalance[](1);
        ids[0] = a;
        bals[0] = PositionFactory.posBalance(sizeA, UTIL, UTIL);
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
        bals[0] = PositionFactory.posBalance(sizeA, UTIL, UTIL);
        bals[1] = PositionFactory.posBalance(sizeB, UTIL, UTIL);
    }

    /// @dev `a` minted at `mintTickA` (a width-0 `b` ignores its mint tick)
    function _twoAt(
        TokenId a,
        uint128 sizeA,
        int24 mintTickA,
        TokenId b,
        uint128 sizeB
    ) internal pure returns (TokenId[] memory ids, PositionBalance[] memory bals) {
        (ids, bals) = _two(a, sizeA, b, sizeB);
        bals[0] = PositionFactory.posBalance(sizeA, UTIL, UTIL, mintTickA);
    }

    function _margin(
        TokenId[] memory ids,
        PositionBalance[] memory bals
    ) internal view returns (LeftRightUnsigned td0, LeftRightUnsigned td1) {
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

    function _solvent(
        TokenId[] memory ids,
        PositionBalance[] memory bals
    ) internal view returns (bool) {
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

    /*//////////////////////////////////////////////////////////////
                              ADD-BACK RULE
    //////////////////////////////////////////////////////////////*/

    /// @notice A credit on its own is added back to the balance in full.
    function test_creditAlone_addedBack() public {
        TokenId credit = _w0(1, 0);
        (TokenId[] memory ids, PositionBalance[] memory bals) = _one(credit, SIZE);
        ct0.setUser(USER, 1 ether, 0, 1 ether);

        (LeftRightUnsigned td0, ) = _margin(ids, bals);
        assertEq(td0.rightSlot(), 1 ether + _notional(credit, SIZE), "credit added to balance");
        assertEq(td0.leftSlot(), 0, "credit requires nothing");
    }

    /// @notice With a loan in the same token, the credit stays in the balance and is charged in full as a
    /// requirement, whatever its size relative to the loan.
    function test_loanAndCredit_sameToken_creditRemargined() public {
        TokenId loan = _w0(0, 0);
        TokenId credit = _w0(1, 0);
        ct0.setUser(USER, 1 ether, 0, 1 ether);

        (TokenId[] memory loanOnly, PositionBalance[] memory loanOnlyBals) = _one(loan, SIZE);
        (LeftRightUnsigned ref0, ) = _margin(loanOnly, loanOnlyBals);

        // credit smaller than, equal to, and larger than the loan
        uint128[3] memory creditSizes = [SIZE / 2, SIZE, 2 * SIZE];
        for (uint256 i; i < 3; ++i) {
            (TokenId[] memory ids, PositionBalance[] memory bals) = _two(
                loan,
                SIZE,
                credit,
                creditSizes[i]
            );
            uint256 C = _notional(credit, creditSizes[i]);
            (LeftRightUnsigned td0, ) = _margin(ids, bals);
            assertEq(td0.rightSlot(), 1 ether + C, "balance is the deposit plus the credit");
            assertEq(
                td0.leftSlot(),
                ref0.leftSlot() + C,
                "requirement is the loan's plus the full credit (not credit - loan)"
            );
        }
    }

    /// @notice A loan in token0 does not affect a credit in token1 (the delayed-swap composite is cross-token).
    function test_loanAndCredit_differentTokens_creditAddedBack() public {
        TokenId loan0 = _w0(0, 0);
        TokenId credit1 = _w0(1, 1);
        ct0.setUser(USER, 1 ether, 0, 1 ether);
        ct1.setUser(USER, 1 ether, 0, 1 ether);

        (TokenId[] memory loanOnly, PositionBalance[] memory loanOnlyBals) = _one(loan0, SIZE);
        (LeftRightUnsigned ref0, ) = _margin(loanOnly, loanOnlyBals);

        (TokenId[] memory ids, PositionBalance[] memory bals) = _two(loan0, SIZE, credit1, SIZE);
        (LeftRightUnsigned td0, LeftRightUnsigned td1) = _margin(ids, bals);

        assertEq(td0.rightSlot(), 1 ether, "token0: no credit to add");
        assertEq(td0.leftSlot(), ref0.leftSlot(), "token0: loan requirement only");
        assertEq(td1.rightSlot(), 1 ether + _notional(credit1, SIZE), "token1: credit added back");
        assertEq(td1.leftSlot(), 0, "token1: credit requires nothing without a token1 loan");
    }

    /// @notice The rule is symmetric in the token.
    function test_loanAndCredit_token1() public {
        TokenId loan1 = _w0(0, 1);
        TokenId credit1 = _w0(1, 1);
        ct1.setUser(USER, 1 ether, 0, 1 ether);

        (TokenId[] memory loanOnly, PositionBalance[] memory loanOnlyBals) = _one(loan1, SIZE);
        (, LeftRightUnsigned ref1) = _margin(loanOnly, loanOnlyBals);

        (TokenId[] memory ids, PositionBalance[] memory bals) = _two(loan1, SIZE, credit1, SIZE);
        (, LeftRightUnsigned td1) = _margin(ids, bals);
        uint256 C = _notional(credit1, SIZE);
        assertEq(td1.rightSlot(), 1 ether + C, "token1: credit added back");
        assertEq(
            td1.leftSlot(),
            ref1.leftSlot() + C,
            "token1: credit re-margined next to a token1 loan"
        );
    }

    /*//////////////////////////////////////////////////////////////
                              LOCK SCENARIO
    //////////////////////////////////////////////////////////////*/

    /// @notice The PLP-lock position: loan X and credit X in one token, funded with the loan margin only.
    /// Under full add-back it was solvent; now the whole loan requirement must be real deposits.
    function test_lockPosition_requiresRealMargin() public {
        TokenId loan = _w0(0, 0);
        TokenId credit = _w0(1, 0);
        (TokenId[] memory ids, PositionBalance[] memory bals) = _two(loan, SIZE, credit, SIZE);

        uint256 X = _notional(loan, SIZE);
        (TokenId[] memory loanOnly, PositionBalance[] memory loanOnlyBals) = _one(loan, SIZE);
        (LeftRightUnsigned ref0, ) = _margin(loanOnly, loanOnlyBals);
        uint256 required = ref0.leftSlot(); // (1 + m) X: what the account must now hold in real deposits
        assertGt(required, X, "setup: loan requirement exceeds the notional");

        // after the loan minted X and the credit burned X, the account holds only its own deposit
        uint256 margin = required - X; // m X: what the old rule let the attacker get away with
        assertGe(
            margin + X,
            required,
            "setup: the old rule (credit added back, no charge) passed on margin alone"
        );

        ct0.setUser(USER, margin, 0, margin);
        assertFalse(_solvent(ids, bals), "margin alone is insolvent");

        ct0.setUser(USER, required - 1, 0, required - 1);
        assertFalse(_solvent(ids, bals), "one wei short of the full loan requirement is insolvent");

        ct0.setUser(USER, required, 0, required);
        assertTrue(_solvent(ids, bals), "the full loan requirement in real deposits is solvent");

        // the combined margin shows the credit once on each side
        (LeftRightUnsigned td0, ) = _margin(ids, bals);
        assertEq(td0.rightSlot(), required + X, "balance = deposit + credit");
        assertEq(td0.leftSlot(), required + X, "requirement = loan requirement + credit");
    }

    /// @notice For any loan/credit pair in the same token, the credit appears once on each side of the margin:
    /// the credited shares can never be used as collateral for the loan that funded them.
    function testFuzz_sameToken_creditOnBothSides(
        uint128 loanSize,
        uint128 creditSize,
        uint128 deposit
    ) public {
        loanSize = uint128(bound(loanSize, 1, type(uint64).max));
        creditSize = uint128(bound(creditSize, 1, type(uint64).max));
        deposit = uint128(bound(deposit, 0, type(uint96).max));
        ct0.setUser(USER, deposit, 0, deposit);

        TokenId loan = _w0(0, 0);
        TokenId credit = _w0(1, 0);
        (TokenId[] memory loanOnly, PositionBalance[] memory loanOnlyBals) = _one(loan, loanSize);
        (LeftRightUnsigned ref0, ) = _margin(loanOnly, loanOnlyBals);

        (TokenId[] memory ids, PositionBalance[] memory bals) = _two(
            loan,
            loanSize,
            credit,
            creditSize
        );
        (LeftRightUnsigned td0, ) = _margin(ids, bals);
        uint256 C = _notional(credit, creditSize);
        assertEq(td0.rightSlot(), deposit + C, "balance == deposit + credit");
        assertEq(td0.leftSlot(), ref0.leftSlot() + C, "requirement == loan requirement + credit");

        // net effect: solvent iff the real deposit covers the loan requirement
        assertEq(
            _solvent(ids, bals),
            deposit >= ref0.leftSlot(),
            "solvent iff deposit >= loan requirement"
        );
    }

    /*//////////////////////////////////////////////////////////////
                     PER-POSITION VIEW VS ACCOUNT RULE
    //////////////////////////////////////////////////////////////*/

    function _perPositionSum0(
        TokenId[] memory ids,
        PositionBalance[] memory bals
    ) internal view returns (uint256 sum) {
        LeftRightUnsigned[] memory reqs = E.getPerPositionCollateralRequirements(
            bals,
            ids,
            int24(0)
        );
        for (uint256 i; i < reqs.length; ++i) sum += reqs[i].rightSlot();
    }

    /// @notice `getPerPositionCollateralRequirements` nets each position on its own and cannot see the
    /// account-level loan+credit rule, so for an affected account its sum reads lower than the account
    /// requirement by exactly the re-margined credit. Monitoring must use `getMargin` / `isAccountSolvent`.
    function test_perPositionView_readsLowerThanAccountRequirement_forLoanAndCredit() public {
        TokenId loan = _w0(0, 0);
        TokenId credit = _w0(1, 0);
        ct0.setUser(USER, 1 ether, 0, 1 ether);

        // unaffected accounts: the per-position sum equals the account requirement
        (TokenId[] memory loanOnly, PositionBalance[] memory loanOnlyBals) = _one(loan, SIZE);
        (LeftRightUnsigned refLoan, ) = _margin(loanOnly, loanOnlyBals);
        assertEq(
            _perPositionSum0(loanOnly, loanOnlyBals),
            refLoan.leftSlot(),
            "loan alone: views agree"
        );

        (TokenId[] memory creditOnly, PositionBalance[] memory creditOnlyBals) = _one(credit, SIZE);
        (LeftRightUnsigned refCredit, ) = _margin(creditOnly, creditOnlyBals);
        assertEq(refCredit.leftSlot(), 0, "credit alone requires nothing");
        assertEq(_perPositionSum0(creditOnly, creditOnlyBals), 0, "credit alone: views agree");

        // affected account: loan X + credit C in the same token
        uint128[3] memory creditSizes = [SIZE / 2, SIZE, 2 * SIZE];
        for (uint256 i; i < 3; ++i) {
            (TokenId[] memory ids, PositionBalance[] memory bals) = _two(
                loan,
                SIZE,
                credit,
                creditSizes[i]
            );
            uint256 C = _notional(credit, creditSizes[i]);
            (LeftRightUnsigned td0, ) = _margin(ids, bals);
            uint256 perPosition = _perPositionSum0(ids, bals);

            assertEq(
                perPosition,
                refLoan.leftSlot(),
                "per-position sum is the loan requirement only"
            );
            assertLt(perPosition, td0.leftSlot(), "per-position sum reads lower than the account");
            assertEq(td0.leftSlot() - perPosition, C, "the gap is exactly the re-margined credit");
        }

        // the gap is exactly what separates "looks fine per position" from "liquidatable":
        // a lock position funded with the loan margin only passes the per-position view and fails the account.
        {
            (TokenId[] memory ids, PositionBalance[] memory bals) = _two(loan, SIZE, credit, SIZE);
            uint256 X = _notional(loan, SIZE);
            uint256 margin = refLoan.leftSlot() - X;
            ct0.setUser(USER, margin, 0, margin);
            (LeftRightUnsigned td0, ) = _margin(ids, bals);
            assertGe(
                td0.rightSlot(),
                _perPositionSum0(ids, bals),
                "per-position view: balance covers the sum"
            );
            assertFalse(_solvent(ids, bals), "account rule: insolvent");
        }
    }

    /// @notice A credit bundled with an option leg in one position is netted against that position's requirement
    /// when nothing in the account mints shares without cash in the token, and reported gross once something does:
    /// a loan, or the option leg itself once its chunk is in range or ITM. Either way the per-position sum matches
    /// the engine's headroom for a reader that uses the raw vault balance.
    function test_perPositionView_compositeCredit_grossOnlyNextToLoan() public {
        // leg 0: token0 credit (small), leg 1: token0 short option (large requirement), independent risk partners.
        // The option's chunk is [500, 1500], entirely OTM at tick 0, so it moves its whole notional into Uniswap.
        TokenId composite = _composite(1000);
        TokenId loan = _w0(0, 0);
        ct0.setUser(USER, 1 ether, 0, 1 ether);

        // composite alone: the engine adds the credit to the balance and nothing to the requirement
        (TokenId[] memory one, PositionBalance[] memory oneBals) = _one(composite, SIZE / 10);
        (LeftRightUnsigned tdAlone, ) = _margin(one, oneBals);
        uint256 C = tdAlone.rightSlot() - 1 ether;
        uint256 reqOption = tdAlone.leftSlot();
        assertGt(C, 0, "setup: composite carries a credit");
        assertGt(reqOption, C, "setup: option requirement exceeds the credit");
        assertEq(
            _perPositionSum0(one, oneBals),
            reqOption - C,
            "OTM short, no loan: credit netted against the position's requirement"
        );
        assertEq(
            int256(1 ether) - int256(_perPositionSum0(one, oneBals)),
            int256(uint256(tdAlone.rightSlot())) - int256(uint256(tdAlone.leftSlot())),
            "OTM short, no loan: raw-balance headroom matches the engine"
        );

        // composite + loan in the same token: the credit is re-margined, so the position reports gross
        (TokenId[] memory two, PositionBalance[] memory twoBals) = _two(
            loan,
            SIZE,
            composite,
            SIZE / 10
        );
        (TokenId[] memory loanOnly, PositionBalance[] memory loanOnlyBals) = _one(loan, SIZE);
        (LeftRightUnsigned refLoan, ) = _margin(loanOnly, loanOnlyBals);
        (LeftRightUnsigned tdBoth, ) = _margin(two, twoBals);

        LeftRightUnsigned[] memory reqs = E.getPerPositionCollateralRequirements(
            twoBals,
            two,
            int24(0)
        );
        assertEq(reqs[0].rightSlot(), refLoan.leftSlot(), "loan position: its own requirement");
        assertEq(
            reqs[1].rightSlot(),
            reqOption,
            "composite next to a loan: gross requirement, credit not netted"
        );
        assertEq(
            tdBoth.leftSlot(),
            refLoan.leftSlot() + reqOption + C,
            "engine: loan + option + re-margined credit"
        );
        assertEq(
            int256(1 ether) - int256(_perPositionSum0(two, twoBals)),
            int256(uint256(tdBoth.rightSlot())) - int256(uint256(tdBoth.leftSlot())),
            "with loan: raw-balance headroom matches the engine"
        );
    }

    /// @notice A composite whose own short is in range at tick 0 (chunk [-500, 500]) holds only part of its
    /// notional in the chunk, so the account mints shares without cash and the bundled credit is re-margined
    /// without any loan; the view reports it gross and its headroom matches the engine.
    function test_perPositionView_compositeCredit_inRangeShortIsGross() public {
        ct0.setUser(USER, 1 ether, 0, 1 ether);
        (TokenId[] memory ir, PositionBalance[] memory irBals) = _one(_composite(0), SIZE / 10);
        (TokenId[] memory so, PositionBalance[] memory soBals) = _one(_shortOnly(0), SIZE / 10);
        (LeftRightUnsigned refShort, ) = _margin(so, soBals);
        (LeftRightUnsigned tdInRange, ) = _margin(ir, irBals);
        uint256 C = tdInRange.rightSlot() - 1 ether;
        assertGt(C, 0, "setup: composite carries a credit");
        assertEq(
            tdInRange.leftSlot(),
            refShort.leftSlot() + C,
            "in-range short: engine re-margins the bundled credit"
        );
        assertEq(
            _perPositionSum0(ir, irBals),
            refShort.leftSlot(),
            "in-range short: view reports the gross requirement"
        );
        assertEq(
            int256(1 ether) - int256(_perPositionSum0(ir, irBals)),
            int256(uint256(tdInRange.rightSlot())) - int256(uint256(tdInRange.leftSlot())),
            "in-range short: raw-balance headroom matches the engine"
        );
    }

    /// @dev token0 credit (leg 0) bundled with a token0 short option (leg 1), width 100, independent risk partners
    function _composite(int24 strike) internal pure returns (TokenId) {
        return
            TokenId.wrap(0).addPoolId(POOL_ID).addLeg(0, 1, 0, 1, 0, 0, 0, 0).addLeg(
                1,
                10,
                0,
                0,
                0,
                1,
                strike,
                100
            );
    }

    /// @dev the short option leg of `_composite` on its own
    function _shortOnly(int24 strike) internal pure returns (TokenId) {
        return TokenId.wrap(0).addPoolId(POOL_ID).addLeg(0, 10, 0, 0, 0, 0, strike, 100);
    }

    /// @notice Each position's net requirement is floored at zero, so a credit larger than its own position's
    /// requirement cannot offset another position. For a raw-balance reader the view is conservative: its headroom
    /// reads lower than the engine's by exactly the excess credit (invariant RE-M8).
    /// The short is OTM at tick 0 (chunk [500, 1500]) so nothing in the account triggers the re-margin.
    function test_perPositionView_excessCreditFlooredConservative() public {
        TokenId credit = _w0(1, 0);
        TokenId shortOption = _shortOnly(1000);
        ct0.setUser(USER, 1 ether, 0, 1 ether);

        (TokenId[] memory ids, PositionBalance[] memory bals) = _two(
            shortOption,
            SIZE / 10,
            credit,
            SIZE
        );
        uint256 C = _notional(credit, SIZE);
        (LeftRightUnsigned td0, ) = _margin(ids, bals);

        LeftRightUnsigned[] memory reqs = E.getPerPositionCollateralRequirements(
            bals,
            ids,
            int24(0)
        );
        assertGt(reqs[0].rightSlot(), 0, "setup: option position has a requirement");
        assertEq(reqs[1].rightSlot(), 0, "standalone credit floored at zero");
        assertEq(td0.rightSlot(), 1 ether + C, "engine: credit added to the balance");

        int256 viewHeadroom = int256(1 ether) - int256(_perPositionSum0(ids, bals));
        int256 engineHeadroom = int256(uint256(td0.rightSlot())) - int256(uint256(td0.leftSlot()));
        assertEq(
            engineHeadroom - viewHeadroom,
            int256(C),
            "view is conservative by the excess credit"
        );
    }

    /*//////////////////////////////////////////////////////////////
                       UNFUNDED SHORT NOTIONAL RULE
    //////////////////////////////////////////////////////////////*/

    /// @notice A short minted OTM moves its whole notional into Uniswap, so it mints no shares without cash and a
    /// same-token credit is added back without being re-margined. (Mint tick 0 here, the evaluation tick.)
    function test_otmShortAndCredit_creditAddedBack() public {
        TokenId shortId = _shortOnly(1000); // chunk [500, 1500], OTM at tick 0 for tokenType 0
        TokenId credit = _w0(1, 0);
        ct0.setUser(USER, 1 ether, 0, 1 ether);

        (TokenId[] memory so, PositionBalance[] memory soBals) = _one(shortId, SIZE / 10);
        (LeftRightUnsigned ref0, ) = _margin(so, soBals);
        (TokenId[] memory ids, PositionBalance[] memory bals) = _two(
            shortId,
            SIZE / 10,
            credit,
            SIZE
        );
        (LeftRightUnsigned td0, ) = _margin(ids, bals);

        assertEq(td0.rightSlot(), 1 ether + _notional(credit, SIZE), "credit added back");
        assertEq(td0.leftSlot(), ref0.leftSlot(), "OTM short: credit not re-margined");
        assertEq(_perPositionSum0(ids, bals), ref0.leftSlot(), "view: short gross, credit zero");
    }

    /// @notice A short minted in range held only part of its notional in its chunk; the rest was minted as shares
    /// with no cash, so a same-token credit is re-margined in full, whatever its size.
    function test_inRangeShortAndCredit_creditRemargined() public {
        TokenId shortId = _shortOnly(0); // chunk [-500, 500], in range at mint tick 0
        TokenId credit = _w0(1, 0);
        ct0.setUser(USER, 1 ether, 0, 1 ether);

        (TokenId[] memory so, PositionBalance[] memory soBals) = _one(shortId, SIZE / 10);
        (LeftRightUnsigned ref0, ) = _margin(so, soBals);

        uint128[3] memory creditSizes = [SIZE / 2, SIZE, 2 * SIZE];
        for (uint256 i; i < 3; ++i) {
            (TokenId[] memory ids, PositionBalance[] memory bals) = _two(
                shortId,
                SIZE / 10,
                credit,
                creditSizes[i]
            );
            uint256 C = _notional(credit, creditSizes[i]);
            (LeftRightUnsigned td0, ) = _margin(ids, bals);
            assertEq(td0.rightSlot(), 1 ether + C, "balance is the deposit plus the credit");
            assertEq(
                td0.leftSlot(),
                ref0.leftSlot() + C,
                "requirement is the short's plus the full credit"
            );
        }
    }

    /// @notice A short whose chunk is entirely ITM moves none of its own token into Uniswap: its whole notional N
    /// is minted as shares with no cash (`_updateBalancesAndSettle`: `tokenToPay = 0 - N`). A credit of N funded
    /// from those shares reserves N of PLP cash that never entered the vault. Before the rule, the account was
    /// solvent with zero real deposit (requirement `N(1 - 0.8 rho)` < balance N). Now the credit is re-margined:
    /// the account needs the short's full requirement in real deposits and can reserve at most what it deposited.
    function test_itmShortAndCredit_lockRequiresRealMargin() public {
        TokenId shortId = _shortOnly(-1000); // chunk [-1500, -500], entirely ITM at mint tick 0 for tokenType 0
        TokenId credit = _w0(1, 0);

        (TokenId[] memory so, PositionBalance[] memory soBals) = _one(shortId, SIZE / 10);
        (LeftRightUnsigned ref0, ) = _margin(so, soBals);
        uint256 N = _notional(shortId, SIZE / 10);
        uint256 reqShort = ref0.leftSlot();
        assertLt(reqShort, N, "setup: ITM short requires less than its notional");

        // credit sized to the short's notional: the lock position
        uint128 creditSize = uint128(N);
        (TokenId[] memory ids, PositionBalance[] memory bals) = _two(
            shortId,
            SIZE / 10,
            credit,
            creditSize
        );
        uint256 C = _notional(credit, creditSize);
        assertEq(C, N, "setup: credit equals the short's notional");

        // zero real deposit: the N minted shares were burned for the credit and come back as its add-back
        ct0.setUser(USER, 0, 0, 0);
        (LeftRightUnsigned td0, ) = _margin(ids, bals);
        assertEq(td0.rightSlot(), C, "balance is the credit alone");
        assertEq(td0.leftSlot(), reqShort + C, "requirement is the short's plus the credit");
        assertFalse(_solvent(ids, bals), "lock funded by the short's own shares is insolvent");

        // real deposits of the short's requirement are the threshold
        ct0.setUser(USER, reqShort - 1, 0, reqShort - 1);
        assertFalse(_solvent(ids, bals), "one wei short of the short's requirement: insolvent");
        ct0.setUser(USER, reqShort, 0, reqShort);
        assertTrue(_solvent(ids, bals), "short's requirement in real deposits: solvent");
    }

    /// @notice Locked capital: the cash a credit reserves for PLPs can never exceed the real capital the account
    /// had to commit to hold it. Loan route: reserve X, capital >= loan requirement > X. ITM-mint route at several
    /// depths: a short minted entirely ITM pays token1 worth rho*N (rho = strike/price) and is handed N of token0
    /// shares; the credit it funds reserves C. Under the rule the account needs real token0 of
    /// `max(0, req_short + C - N)` on top, and `req_short = N(1 - 0.8 rho)`, so capital >= C + 0.2 rho N > C.
    /// Also pins what the rule prevents: with the credit not re-margined, the ITM short alone covers its own
    /// requirement out of the minted shares (`N >= req_short`), i.e. the lock was free in token0.
    function test_lockedCapital_reserveNeverExceedsCommittedCapital() public {
        // --- loan route ---
        {
            TokenId loan = _w0(0, 0);
            (TokenId[] memory so, PositionBalance[] memory soBals) = _one(loan, SIZE);
            ct0.setUser(USER, 0, 0, 0);
            (LeftRightUnsigned r, ) = _margin(so, soBals);
            uint256 X = _notional(loan, SIZE);
            // with credit C = X the credit cancels on both sides: the real deposit must cover the loan requirement
            assertGt(
                r.leftSlot(),
                X,
                "loan: committed capital (loan requirement) exceeds the reserve X"
            );
        }

        // --- ITM-mint route: strikes from just ITM to deep ITM, evaluated and minted at tick 0 ---
        int24[4] memory strikes = [int24(-30), int24(-1000), int24(-5000), int24(-25000)];
        for (uint256 k; k < 4; ++k) {
            TokenId shortId = _shortOnly(strikes[k]);
            TokenId credit = _w0(1, 0);
            LeftRightUnsigned moved = PanopticMath.getAmountsMoved(shortId, SIZE / 10, 0, false);
            uint256 N = moved.rightSlot();
            uint256 token1Paid = moved.leftSlot(); // worth the same in token0 at tick 0 (price 1)
            uint256 reqShort = _req(shortId, 0, credit, 0, false);
            assertGe(
                N,
                reqShort,
                "without the rule: minted shares alone cover the short (free lock)"
            );

            // credit sizes: the whole minted amount and half of it
            uint128[2] memory creditSizes = [uint128(N), uint128(N / 2)];
            for (uint256 j; j < 2; ++j) {
                uint256 C = _notional(credit, creditSizes[j]);
                uint256 dMin = reqShort + C > N ? reqShort + C - N : 0;

                // boundary check: shares held = D + N - C, balance = D + N, requirement = reqShort + C
                (TokenId[] memory ids, PositionBalance[] memory bals) = _twoAt(
                    shortId,
                    SIZE / 10,
                    0,
                    credit,
                    creditSizes[j]
                );
                ct0.setUser(USER, dMin + N - C, 0, dMin + N - C);
                assertTrue(_solvent(ids, bals), "solvent at the minimum real deposit");
                if (dMin > 0) {
                    ct0.setUser(USER, dMin - 1 + N - C, 0, dMin - 1 + N - C);
                    assertFalse(_solvent(ids, bals), "insolvent one wei below it");
                }

                // the capital the account committed (token0 deposit + token1 paid into the chunk) covers the reserve
                assertGe(dMin + token1Paid, C, "ITM mint: committed capital >= credited reserve");
            }
        }
    }

    /// @notice Fuzzed form of the ITM-mint locked-capital check. Any short minted with its chunk entirely ITM
    /// (either token), any width, any size, any credit up to the minted amount: the minimum real deposit found by
    /// the solvency boundary, plus the other-token amount paid into the chunk, always covers the credited reserve;
    /// and the minted shares alone always cover the short's own requirement (the pre-rule free lock).
    /// Run long with `FOUNDRY_FUZZ_RUNS=<n>` (same profile) to stress it.
    function testFuzz_lockedCapital_itmMint_reserveNeverExceedsCommittedCapital(
        int24 strike,
        uint24 widthSeed,
        uint128 sizeSeed,
        uint128 creditSeed,
        bool tokenType1
    ) public {
        int24 width = int24(int256(bound(uint256(widthSeed), 1, 400)));
        uint128 size = uint128(bound(uint256(sizeSeed), 1e12, 1e22));
        uint256 tt = tokenType1 ? 1 : 0;
        // chunk entirely ITM at tick 0: tokenType 0 needs tickUpper <= 0, tokenType 1 needs tickLower > 0
        if (tokenType1) {
            strike = int24(bound(int256(strike), int256(5 * width) + 10, 300_000));
        } else {
            strike = int24(bound(int256(strike), -300_000, -int256(5 * width)));
        }
        strike = (strike / 10) * 10;

        // size denominated in the short's own token (asset == tokenType) so the notional stays ~size at any strike
        TokenId shortId = TokenId.wrap(0).addPoolId(POOL_ID).addLeg(
            0,
            1,
            tt,
            0,
            tt,
            0,
            strike,
            width
        );
        TokenId credit = _w0(1, tt);
        LeftRightUnsigned moved = PanopticMath.getAmountsMoved(shortId, size, 0, false);
        uint256 N = tokenType1 ? moved.leftSlot() : moved.rightSlot();
        uint256 otherPaid = tokenType1 ? moved.rightSlot() : moved.leftSlot(); // price 1 at tick 0
        vm.assume(N > 1);

        // short alone, zero deposit: requirement
        uint256 reqShort;
        {
            (TokenId[] memory so, PositionBalance[] memory soBals) = _one(shortId, size);
            _setUser(tokenType1, 0);
            (LeftRightUnsigned r0, LeftRightUnsigned r1) = _margin(so, soBals);
            reqShort = tokenType1 ? r1.leftSlot() : r0.leftSlot();
        }
        assertGe(N, reqShort, "without the rule: minted shares alone cover the short (free lock)");

        uint128 creditSize = uint128(bound(uint256(creditSeed), 1, N));
        uint256 C = _notional(credit, creditSize);
        vm.assume(C <= N);
        uint256 dMin = reqShort + C > N ? reqShort + C - N : 0;

        (TokenId[] memory ids, PositionBalance[] memory bals) = _two(
            shortId,
            size,
            credit,
            creditSize
        );
        _setUser(tokenType1, dMin + N - C);
        assertTrue(_solvent(ids, bals), "solvent at the minimum real deposit");
        if (dMin > 0) {
            _setUser(tokenType1, dMin - 1 + N - C);
            assertFalse(_solvent(ids, bals), "insolvent one wei below it");
        }
        assertGe(dMin + otherPaid, C, "ITM mint: committed capital >= credited reserve");
    }

    /// @dev deposit `assets` (shares at price 1) in the short's token, nothing in the other
    function _setUser(bool tokenType1, uint256 assets) internal {
        if (tokenType1) {
            ct1.setUser(USER, assets, 0, assets);
            ct0.setUser(USER, 0, 0, 0);
        } else {
            ct0.setUser(USER, assets, 0, assets);
            ct1.setUser(USER, 0, 0, 0);
        }
    }

    /// @notice The trigger is a property of the mint, not of the current price. A short minted ITM keeps its
    /// phantom shares in the account after the price moves back OTM, so its credit stays re-margined.
    function test_shortMintedItm_nowOtm_stillTriggers() public {
        TokenId shortId = _shortOnly(1000); // chunk [500, 1500]: OTM at the evaluation tick 0 ...
        int24 mintTick = 2000; // ... but entirely ITM when minted
        TokenId credit = _w0(1, 0);
        ct0.setUser(USER, 1 ether, 0, 1 ether);

        uint256 refReq = _req(shortId, mintTick, credit, 0, false);
        uint256 C = _notional(credit, SIZE);
        assertEq(
            _req(shortId, mintTick, credit, SIZE, false),
            refReq + C,
            "minted ITM: credit re-margined although the chunk is OTM now"
        );
        assertEq(
            _req(shortId, 0, credit, SIZE, false),
            refReq,
            "control: the same chunk minted OTM does not trigger"
        );
    }

    /// @notice A short minted OTM was fully cash-funded; the price moving ITM afterwards does not turn its
    /// same-token credit into a re-margined one (no false positive on a seller under stress).
    function test_shortMintedOtm_nowItm_doesNotTrigger() public {
        TokenId shortId = _shortOnly(-1000); // chunk [-1500, -500]: entirely ITM at the evaluation tick 0 ...
        int24 mintTick = -2000; // ... but OTM when minted
        TokenId credit = _w0(1, 0);
        ct0.setUser(USER, 1 ether, 0, 1 ether);

        uint256 refReq = _req(shortId, mintTick, credit, 0, false);
        assertEq(
            _req(shortId, mintTick, credit, SIZE, false),
            refReq,
            "minted OTM: credit not re-margined although the chunk is ITM now"
        );
        assertEq(
            _req(shortId, 0, credit, SIZE, false),
            refReq + _notional(credit, SIZE),
            "control: the same chunk minted ITM triggers"
        );
    }

    /// @notice The trigger is exactly "the chunk did not hold the whole notional at the mint tick":
    /// tokenType 0 shorts trigger when mintTick > tickLower, tokenType 1 shorts when mintTick < tickUpper, and
    /// the re-margin is all-or-nothing on the credit. A chunk entirely OTM at mint never triggers, whatever the
    /// rounding, and the evaluation tick (0) plays no part.
    function testFuzz_shortTrigger_matchesChunkCompositionAtMint(
        int24 mintTick,
        int24 strike,
        uint24 widthSeed,
        bool tokenType1
    ) public {
        mintTick = int24(bound(int256(mintTick), -300_000, 300_000));
        strike = int24(bound(int256(strike), -200_000, 200_000));
        strike = (strike / 10) * 10;
        int24 width = int24(int256(bound(uint256(widthSeed), 1, 400)));
        uint256 tt = tokenType1 ? 1 : 0;

        TokenId shortId = TokenId.wrap(0).addPoolId(POOL_ID).addLeg(
            0,
            1,
            0,
            0,
            tt,
            0,
            strike,
            width
        );
        if (tokenType1) ct1.setUser(USER, 1 ether, 0, 1 ether);
        else ct0.setUser(USER, 1 ether, 0, 1 ether);

        uint256 refReq = _req(shortId, mintTick, _w0(1, tt), 0, tokenType1);
        uint256 req = _req(shortId, mintTick, _w0(1, tt), SIZE, tokenType1);
        uint256 C = _notional(_w0(1, tt), SIZE);

        (int24 tickLower, int24 tickUpper) = shortId.asTicks(0);
        bool unfunded = tokenType1 ? mintTick < tickUpper : mintTick > tickLower;
        assertEq(
            req,
            unfunded ? refReq + C : refReq,
            "credit re-margined iff the chunk held less than N at mint"
        );
    }

    /// @dev requirement at tick 0 of `shortId` (size SIZE/10, minted at `mintTick`) with a credit of `creditSize`
    /// (0 = short alone), in the given token
    function _req(
        TokenId shortId,
        int24 mintTick,
        TokenId credit,
        uint128 creditSize,
        bool tokenType1
    ) internal view returns (uint256) {
        TokenId[] memory ids;
        PositionBalance[] memory bals;
        if (creditSize == 0) {
            (ids, bals) = _one(shortId, SIZE / 10);
            bals[0] = PositionFactory.posBalance(SIZE / 10, UTIL, UTIL, mintTick);
        } else {
            (ids, bals) = _twoAt(shortId, SIZE / 10, mintTick, credit, creditSize);
        }
        (LeftRightUnsigned t0, LeftRightUnsigned t1) = _margin(ids, bals);
        return tokenType1 ? t1.leftSlot() : t0.leftSlot();
    }

    /*//////////////////////////////////////////////////////////////
                           SAFE-MODE SENTINEL
    //////////////////////////////////////////////////////////////*/

    /// @dev The entry the pool writes at index 0 in safe mode: 100%/100% utilization, zero mint tick, block and
    /// timestamp. It carries no information about when the position was minted.
    function _sentinel(uint128 size) internal pure returns (PositionBalance) {
        return
            PositionBalanceLibrary.storeBalanceData(
                size,
                uint32(10_000 | (10_000 << 16)),
                0,
                0,
                0,
                false
            );
    }

    /// @dev requirement at tick 0 of the given list, in the given token
    function _reqList(
        TokenId[] memory ids,
        PositionBalance[] memory bals,
        bool tokenType1
    ) internal view returns (uint256) {
        (LeftRightUnsigned t0, LeftRightUnsigned t1) = _margin(ids, bals);
        return tokenType1 ? t1.leftSlot() : t0.leftSlot();
    }

    /// @notice The list order is caller-chosen, so a short placed under the sentinel cannot be trusted to have been
    /// funded: its whole notional counts as minted without cash, whichever side of tick 0 its chunk lies on. A short
    /// minted ITM cannot hide behind the sentinel's zero tick, and a funded one over-triggers (the account avoids
    /// that by listing its credit first). The control shows that a real entry minted at tick 0 follows the chunk.
    function test_sentinelAtIndex0_shortAlwaysTriggers() public {
        TokenId credit = _w0(1, 0);
        uint256 C = _notional(credit, SIZE);
        ct0.setUser(USER, 1 ether, 0, 1 ether);

        int24[2] memory strikes = [int24(1000), -1000]; // chunk [500, 1500] above tick 0, [-1500, -500] below
        for (uint256 i; i < 2; ++i) {
            TokenId shortId = _shortOnly(strikes[i]);

            // reference: the sentinel short alone (priced at the sentinel's 100% utilization)
            (TokenId[] memory ids, PositionBalance[] memory bals) = _one(shortId, SIZE / 10);
            bals[0] = _sentinel(SIZE / 10);
            uint256 refReq = _reqList(ids, bals, false);

            (ids, bals) = _two(shortId, SIZE / 10, credit, SIZE);
            bals[0] = _sentinel(SIZE / 10);
            assertEq(_reqList(ids, bals, false), refReq + C, "sentinel short: credit re-margined");

            uint256 realRef = _req(shortId, 0, credit, 0, false);
            assertEq(
                _req(shortId, 0, credit, SIZE, false),
                strikes[i] > 0 ? realRef : realRef + C,
                "control: a real entry minted at tick 0 triggers iff its chunk held none of the notional there"
            );
        }
    }

    /// @notice With the credit listed first, the sentinel lands on an entry whose requirement ignores both its
    /// mint tick and its utilization, and the short keeps its real mint tick: the account requirement is the same
    /// as without a sentinel, for a short minted ITM (credit re-margined) and for one minted OTM (not).
    function test_sentinelAtIndex0_creditFirst_shortKeepsMintTick() public {
        TokenId credit = _w0(1, 0);
        TokenId shortId = _shortOnly(1000); // chunk [500, 1500]
        uint256 C = _notional(credit, SIZE);
        ct0.setUser(USER, 1 ether, 0, 1 ether);

        int24[2] memory mintTicks = [int24(2000), 0]; // entirely ITM at mint, entirely OTM at mint
        for (uint256 i; i < 2; ++i) {
            uint256 real = _req(shortId, mintTicks[i], credit, SIZE, false);
            uint256 shortAlone = _req(shortId, mintTicks[i], credit, 0, false);
            assertEq(
                real,
                i == 0 ? shortAlone + C : shortAlone,
                "no sentinel: trigger iff minted ITM"
            );

            (TokenId[] memory ids, PositionBalance[] memory bals) = _two(
                credit,
                SIZE,
                shortId,
                SIZE / 10
            );
            bals[0] = _sentinel(SIZE);
            bals[1] = PositionFactory.posBalance(SIZE / 10, UTIL, UTIL, mintTicks[i]);
            assertEq(_reqList(ids, bals, false), real, "sentinel on the credit: same requirement");
        }
    }

    /// @notice For any width-positive short under the sentinel, in either token, the same-token credit is
    /// re-margined in full: the fallback never depends on the chunk or on the zero tick the sentinel carries.
    function testFuzz_sentinelAtIndex0_triggersForAnyShort(
        int24 strike,
        uint24 widthSeed,
        bool tokenType1
    ) public {
        strike = int24(bound(int256(strike), -200_000, 200_000));
        strike = (strike / 10) * 10;
        int24 width = int24(int256(bound(uint256(widthSeed), 1, 400)));
        uint256 tt = tokenType1 ? 1 : 0;

        TokenId shortId = TokenId.wrap(0).addPoolId(POOL_ID).addLeg(
            0,
            1,
            0,
            0,
            tt,
            0,
            strike,
            width
        );
        if (tokenType1) ct1.setUser(USER, 1 ether, 0, 1 ether);
        else ct0.setUser(USER, 1 ether, 0, 1 ether);

        (TokenId[] memory ids, PositionBalance[] memory bals) = _one(shortId, SIZE / 10);
        bals[0] = _sentinel(SIZE / 10);
        uint256 refReq = _reqList(ids, bals, tokenType1);

        (ids, bals) = _two(shortId, SIZE / 10, _w0(1, tt), SIZE);
        bals[0] = _sentinel(SIZE / 10);
        assertEq(
            _reqList(ids, bals, tokenType1),
            refReq + _notional(_w0(1, tt), SIZE),
            "sentinel short re-margins the credit for any chunk"
        );
    }
}
