// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Errors} from "@libraries/Errors.sol";
import {RiskEngineV2} from "@contracts/RiskEngine.sol";
import {CollateralTrackerV2} from "@contracts/CollateralTracker.sol";
import {BuilderFactory, BuilderWallet} from "@contracts/Builder.sol";
import {LeftRightSigned, LeftRightUnsigned} from "@types/LeftRight.sol";
import {Math} from "@libraries/Math.sol";
import {RiskEngineParams} from "../testUtils/RiskEngineParams.sol";

contract CovCollectToken {
    mapping(address => uint256) public balanceOf;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev The slice of a CollateralTracker that `getRefundAmounts` reads, at a settable share price.
contract CovRefundTracker {
    mapping(address => uint256) public balanceOf;
    uint256 public totalAssets = 1;
    uint256 public totalSupply = 1;

    function setBalance(address account, uint256 shares) external {
        balanceOf[account] = shares;
    }

    function setSharePrice(uint256 assets, uint256 supply) external {
        (totalAssets, totalSupply) = (assets, supply);
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return (assets * totalSupply) / totalAssets;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return (shares * totalAssets) / totalSupply;
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return (assets * totalSupply + totalAssets - 1) / totalAssets;
    }
}

/// @notice Fills the coverage gaps left in `contracts/RiskEngine.sol` by the rest of the suite:
/// - `collect` with a zero amount, through both overloads
/// - `getFeeRecipient` for a builder code whose wallet is not deployed
/// - `getRefundAmounts` when the token0 fee is owed to the payor rather than by them
/// - the per-token cap in `getLiquidationBonus` when a token's backable collateral is negative
/// @dev Not covered: the two `if (bonus > maxBonus) bonus = maxBonus` clamps that follow that cap. The global
/// cap applied before the cross-token conversion, plus the conversion itself, already leave each bonus at or
/// below its token's backable collateral, so the clamps never fire: the property fuzz at the bottom of this
/// file asserts exactly that bound and did not take either branch in 30,000 runs.
contract RiskEngineCoverageTest is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 2 ** 96;
    uint256 internal constant VIRTUAL_SHARES = type(uint248).max;

    address internal guardian = makeAddr("guardian");
    address internal recipient = makeAddr("recipient");
    address internal payor = makeAddr("payor");

    BuilderFactory internal factory;
    RiskEngineV2 internal engine;
    CovCollectToken internal token;
    CovRefundTracker internal ct0;
    CovRefundTracker internal ct1;

    function setUp() public {
        factory = new BuilderFactory(address(this));
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(BuilderWallet).creationCode, abi.encode(address(factory)))
        );
        engine = new RiskEngineV2(
            guardian,
            address(factory),
            initCodeHash,
            RiskEngineParams.blueChip(5_000_000, 5_000_000)
        );

        token = new CovCollectToken();
        ct0 = new CovRefundTracker();
        ct1 = new CovRefundTracker();
    }

    function _signed(int128 right, int128 left) internal pure returns (LeftRightSigned) {
        return LeftRightSigned.wrap(0).addToRightSlot(right).addToLeftSlot(left);
    }

    function _unsigned(uint128 right, uint128 left) internal pure returns (LeftRightUnsigned) {
        return LeftRightUnsigned.wrap(0).addToRightSlot(right).addToLeftSlot(left);
    }

    /*//////////////////////////////////////////////////////////////
                                collect
    //////////////////////////////////////////////////////////////*/

    function test_collect_revertsOnZeroAmount() public {
        token.mint(address(engine), 100);

        vm.prank(guardian);
        vm.expectRevert(Errors.BelowMinimumRedemption.selector);
        engine.collect(address(token), recipient, 0);

        assertEq(token.balanceOf(address(engine)), 100, "funds stay");
    }

    function test_collectAll_revertsOnZeroBalance() public {
        // the full-balance overload resolves to a zero amount when there is nothing to collect
        vm.prank(guardian);
        vm.expectRevert(Errors.BelowMinimumRedemption.selector);
        engine.collect(address(token), recipient);
    }

    function test_collect_revertsForNonGuardian(address caller) public {
        vm.assume(caller != guardian);
        token.mint(address(engine), 100);

        vm.startPrank(caller);
        vm.expectRevert(Errors.NotGuardian.selector);
        engine.collect(address(token), recipient, 100);
        vm.expectRevert(Errors.NotGuardian.selector);
        engine.collect(address(token), recipient);
        vm.stopPrank();
    }

    function test_collect_transfersAmount(uint256 balance, uint256 amount) public {
        balance = bound(balance, 1, type(uint128).max);
        amount = bound(amount, 1, balance);
        token.mint(address(engine), balance);

        vm.prank(guardian);
        engine.collect(address(token), recipient, amount);

        assertEq(token.balanceOf(recipient), amount, "recipient");
        assertEq(token.balanceOf(address(engine)), balance - amount, "engine");
    }

    function test_collectAll_transfersFullBalance(uint256 balance) public {
        balance = bound(balance, 1, type(uint128).max);
        token.mint(address(engine), balance);

        vm.prank(guardian);
        engine.collect(address(token), recipient);

        assertEq(token.balanceOf(recipient), balance, "recipient");
        assertEq(token.balanceOf(address(engine)), 0, "engine emptied");
    }

    /*//////////////////////////////////////////////////////////////
                            getFeeRecipient
    //////////////////////////////////////////////////////////////*/

    function test_getFeeRecipient_revertsWhenWalletNotDeployed(uint48 builderCode) public {
        vm.assume(builderCode != 0);

        vm.expectRevert(Errors.InvalidBuilderCode.selector);
        engine.getFeeRecipient(builderCode);
    }

    function test_getFeeRecipient_zeroCodeIsZeroAddress() public view {
        assertEq(engine.getFeeRecipient(0), address(0));
    }

    function test_getFeeRecipient_resolvesDeployedWallet(uint48 builderCode) public {
        vm.assume(builderCode != 0);
        address wallet = factory.deployBuilder(builderCode, makeAddr("builder admin"));

        assertEq(
            engine.getFeeRecipient(builderCode),
            wallet,
            "matches the factory's CREATE2 address"
        );

        // a neighbouring code is still undeployed
        uint256 other = builderCode == type(uint48).max ? 1 : uint256(builderCode) + 1;
        vm.expectRevert(Errors.InvalidBuilderCode.selector);
        engine.getFeeRecipient(other);
    }

    /*//////////////////////////////////////////////////////////////
                           getRefundAmounts
    //////////////////////////////////////////////////////////////*/

    function _refund(int128 fees0, int128 fees1) internal view returns (LeftRightSigned) {
        return
            engine.getRefundAmounts(
                payor,
                _signed(fees0, fees1),
                0,
                CollateralTrackerV2(address(ct0)),
                CollateralTrackerV2(address(ct1))
            );
    }

    function test_getRefundAmounts_feeOwedToPayor_noShortage(uint64 fee0, uint64 fee1) public {
        // the payor holds exactly the delegated virtual shares in both tokens and receives fees in both
        ct0.setBalance(payor, VIRTUAL_SHARES);
        ct1.setBalance(payor, VIRTUAL_SHARES);

        LeftRightSigned refund = _refund(-int128(uint128(fee0)), -int128(uint128(fee1)));

        assertEq(refund.rightSlot(), -int128(uint128(fee0)), "token0 delta unchanged");
        assertEq(refund.leftSlot(), -int128(uint128(fee1)), "token1 delta unchanged");
    }

    function test_getRefundAmounts_feeOwedToPayor_coversPartOfShortage() public {
        // 1,000 shares short in token0, of which the 400 received as fee cover a part: 600 remain
        ct0.setBalance(payor, VIRTUAL_SHARES - 1_000);
        ct1.setBalance(payor, VIRTUAL_SHARES);

        LeftRightSigned refund = _refund(-400, 0);

        // the caller supplies the 600 missing token0 on top of the 400 fee, and takes 600 token1 at the 1:1 price
        assertEq(refund.rightSlot(), -1_000, "token0: fee plus the covered shortage");
        assertEq(refund.leftSlot(), 600, "token1: taken in exchange");
    }

    function test_getRefundAmounts_feeOwedToPayor_coversWholeShortage() public {
        // the same 1,000 share shortage is fully covered by a 1,000 fee: nothing to substitute
        ct0.setBalance(payor, VIRTUAL_SHARES - 1_000);
        ct1.setBalance(payor, VIRTUAL_SHARES);

        LeftRightSigned refund = _refund(-1_000, 0);

        assertEq(refund.rightSlot(), -1_000, "token0 delta unchanged");
        assertEq(refund.leftSlot(), 0, "token1 delta unchanged");
    }

    function test_getRefundAmounts_feeOwedToPayor_roundsSharesDown() public {
        // 3 assets per 2 shares: a 100 asset fee is worth 66 shares, rounded down against the payor
        ct0.setSharePrice(3, 2);
        ct0.setBalance(payor, VIRTUAL_SHARES - 66);
        ct1.setBalance(payor, VIRTUAL_SHARES);
        assertEq(_refund(-100, 0).leftSlot(), 0, "66 shares short is exactly covered");

        ct0.setBalance(payor, VIRTUAL_SHARES - 67);
        LeftRightSigned refund = _refund(-100, 0);

        // one share short: worth 1.5 assets, rounded up to 2 on the token0 side and down then up to 1 on token1
        assertEq(refund.rightSlot(), -102, "token0");
        assertEq(refund.leftSlot(), 1, "token1");
    }

    function test_getRefundAmounts_feeOwedByPayor_addsToShortage() public {
        // contrast with the cases above: a fee owed by the payor deepens the shortage
        ct0.setBalance(payor, VIRTUAL_SHARES - 1_000);
        ct1.setBalance(payor, VIRTUAL_SHARES);

        LeftRightSigned refund = _refund(400, 0);

        assertEq(refund.rightSlot(), 400 - 1_400, "token0");
        assertEq(refund.leftSlot(), 1_400, "token1");
    }

    /*//////////////////////////////////////////////////////////////
                    getLiquidationBonus: PER-TOKEN CAP
    //////////////////////////////////////////////////////////////*/

    function test_getLiquidationBonus_negativeBackableToken0IsFlooredAtZero() public view {
        // token0: no balance and 100 owed, so its backable collateral is -100. token1: 1,000 spare.
        (LeftRightSigned bonus, LeftRightSigned remaining) = engine.getLiquidationBonus(
            _unsigned(0, 0),
            _unsigned(1_000, 0),
            SQRT_PRICE_1_1,
            _signed(100, 0),
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );

        // the token0 shortfall is converted into token1; no positive token0 bonus can be paid
        assertEq(bonus.rightSlot(), -100, "token0: liquidator covers the shortfall");
        assertEq(bonus.leftSlot(), 100, "token1: paid in exchange");
        assertEq(remaining.rightSlot(), 0, "token0 fully settled");
        assertEq(remaining.leftSlot(), 900, "token1 left with the liquidatee");
    }

    function test_getLiquidationBonus_negativeBackableToken1IsFlooredAtZero() public view {
        (LeftRightSigned bonus, LeftRightSigned remaining) = engine.getLiquidationBonus(
            _unsigned(1_000, 0),
            _unsigned(0, 0),
            SQRT_PRICE_1_1,
            _signed(0, 100),
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );

        assertEq(bonus.rightSlot(), 100, "token0: paid in exchange");
        assertEq(bonus.leftSlot(), -100, "token1: liquidator covers the shortfall");
        assertEq(remaining.rightSlot(), 900, "token0 left with the liquidatee");
        assertEq(remaining.leftSlot(), 0, "token1 fully settled");
    }

    function test_getLiquidationBonus_negativeBackableInBothTokens() public view {
        // insolvent in both tokens: no conversion is possible and neither bonus can be positive
        (LeftRightSigned bonus, LeftRightSigned remaining) = engine.getLiquidationBonus(
            _unsigned(0, 500),
            _unsigned(0, 500),
            SQRT_PRICE_1_1,
            _signed(100, 100),
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );

        assertEq(bonus.rightSlot(), 0, "token0 bonus");
        assertEq(bonus.leftSlot(), 0, "token1 bonus");
        assertEq(remaining.rightSlot(), -100, "token0 protocol loss");
        assertEq(remaining.leftSlot(), -100, "token1 protocol loss");
    }

    function test_getLiquidationBonus_negativeBackable_fuzz(
        uint64 owed0,
        uint64 spare1,
        uint64 required0
    ) public view {
        owed0 = uint64(bound(owed0, 1, type(uint64).max));

        (LeftRightSigned bonus, LeftRightSigned remaining) = engine.getLiquidationBonus(
            _unsigned(0, required0),
            _unsigned(spare1, 0),
            SQRT_PRICE_1_1,
            _signed(int128(uint128(owed0)), 0),
            LeftRightUnsigned.wrap(0),
            LeftRightUnsigned.wrap(0)
        );

        // with nothing backing token0, its bonus is never positive, whatever the requirement asks for
        assertLe(bonus.rightSlot(), 0, "token0 bonus not positive");
        // and the liquidator is never paid more token1 than the liquidatee has
        assertLe(bonus.leftSlot(), int128(uint128(spare1)), "token1 bonus within balance");
        assertGe(remaining.leftSlot(), 0, "token1 not overdrawn");
    }

    /// @dev Property behind the per-token cap: whatever the inputs, a token's bonus never exceeds that token's
    /// backable collateral `balance - shortPremium - netPaid - credits`, floored at zero.
    function test_getLiquidationBonus_bonusNeverExceedsBackable_fuzz(
        uint64[8] memory u,
        int64[2] memory paid,
        int24 tick
    ) public view {
        tick = int24(bound(tick, -200_000, 200_000));
        // short premium cannot exceed the balance it is part of
        u[4] = uint64(bound(u[4], 0, u[0]));
        u[5] = uint64(bound(u[5], 0, u[1]));

        (LeftRightSigned bonus, LeftRightSigned remaining) = engine.getLiquidationBonus(
            _unsigned(u[0], u[2]),
            _unsigned(u[1], u[3]),
            Math.getSqrtRatioAtTick(tick),
            _signed(paid[0], paid[1]),
            _unsigned(u[4], u[5]),
            _unsigned(u[6], u[7])
        );

        int256 backable0 = int256(uint256(u[0])) -
            int256(uint256(u[4])) -
            paid[0] -
            int256(uint256(u[6]));
        int256 backable1 = int256(uint256(u[1])) -
            int256(uint256(u[5])) -
            paid[1] -
            int256(uint256(u[7]));

        assertLe(
            bonus.rightSlot(),
            backable0 > 0 ? backable0 : int256(0),
            "token0 bonus within backable"
        );
        assertLe(
            bonus.leftSlot(),
            backable1 > 0 ? backable1 : int256(0),
            "token1 bonus within backable"
        );
        // and what is left is exactly the backable collateral less the bonus
        assertEq(remaining.rightSlot(), backable0 - bonus.rightSlot(), "token0 remainder");
        assertEq(remaining.leftSlot(), backable1 - bonus.leftSlot(), "token1 remainder");
    }
}
