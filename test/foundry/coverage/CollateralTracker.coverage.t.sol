// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Errors} from "@libraries/Errors.sol";
import {CollateralTrackerV2} from "@contracts/CollateralTracker.sol";
import {RiskParameters, RiskParametersLibrary} from "@types/RiskParameters.sol";
import {MarketState} from "@types/MarketState.sol";
import {TokenId} from "@types/TokenId.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";

contract CovUnderlying {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Zero interest, so share prices only move through the flows under test.
contract CovFlatRiskEngine {
    function interestRate(uint256, MarketState) external pure returns (uint128) {
        return 0;
    }

    function updateInterestRate(uint256, MarketState) external pure returns (uint128, uint256) {
        return (0, 0);
    }
}

/// @notice Fills the coverage gaps left in `contracts/CollateralTracker.sol` by the rest of the suite:
/// - the immutable-argument getters that were only ever read internally
/// - `unlockCallback` called by anyone other than the PoolManager
/// - every arm of `maxWithdraw` and `maxRedeem`
/// - the commission paths of `settleMint` and `settleBurn`: the builder fee split and the insufficient-balance revert
/// - `settleLiquidation` with a negative bonus the liquidator cannot fund, and the ETH refund on a positive bonus
/// - `refund` in both directions, including a refundee who cannot pay
/// @dev The tracker is cloned against this test contract standing in for the PanopticPool, with no PoolManager
/// (the Uniswap V3 configuration) and a zero-rate risk engine, so each flow can be driven and checked in isolation.
contract CollateralTrackerCoverageTest is Test {
    using ClonesWithImmutableArgs for address;

    event CommissionPaid(
        address indexed owner,
        address indexed builder,
        uint128 commissionPaidProtocol,
        uint128 commissionPaidBuilder
    );

    uint24 internal constant POOL_FEE = 500;
    uint256 internal constant DECIMALS = 10_000;

    CovUnderlying internal underlying;
    CovFlatRiskEngine internal riskEngine;
    CollateralTrackerV2 internal ct;

    address internal otherToken = address(0x7070);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    // the fee recipient field is 128 bits wide, so a builder wallet address must have its top 32 bits clear
    address internal builder = address(uint160(uint128(uint160(makeAddr("builder wallet")))));

    /*//////////////////////////////////////////////////////////////
                     PANOPTIC POOL STAND-IN (THIS CONTRACT)
    //////////////////////////////////////////////////////////////*/

    mapping(address => uint256) public numberOfLegs;

    function validateCollateralWithdrawable(address, TokenId[] calldata, bool) external pure {}

    /*//////////////////////////////////////////////////////////////
                                FIXTURE
    //////////////////////////////////////////////////////////////*/

    function _deploy(bool underlyingIsToken0) internal returns (CollateralTrackerV2 tracker) {
        address impl = address(new CollateralTrackerV2());
        (address token0, address token1) = underlyingIsToken0
            ? (address(underlying), otherToken)
            : (otherToken, address(underlying));

        tracker = CollateralTrackerV2(
            impl.clone(
                abi.encodePacked(
                    address(this),
                    underlyingIsToken0,
                    address(underlying),
                    token0,
                    token1,
                    address(riskEngine),
                    address(0),
                    POOL_FEE
                )
            )
        );
        tracker.initialize();
    }

    function setUp() public {
        underlying = new CovUnderlying();
        riskEngine = new CovFlatRiskEngine();
        ct = _deploy(true);
    }

    function _deposit(address account, uint256 assets) internal returns (uint256 shares) {
        underlying.mint(account, assets);
        vm.startPrank(account);
        underlying.approve(address(ct), assets);
        shares = ct.deposit(assets, account);
        vm.stopPrank();
    }

    /// @dev Risk parameters carrying only the fee fields the tracker reads.
    function _riskParameters(
        uint256 notionalFee,
        uint256 premiumFee,
        uint256 protocolSplit,
        uint256 builderSplit,
        address feeRecipient
    ) internal pure returns (RiskParameters) {
        return
            RiskParametersLibrary.storeRiskParameters(
                0,
                notionalFee,
                premiumFee,
                protocolSplit,
                builderSplit,
                0,
                0,
                0,
                0,
                uint256(uint160(feeRecipient))
            );
    }

    /*//////////////////////////////////////////////////////////////
                        IMMUTABLE ARGUMENT GETTERS
    //////////////////////////////////////////////////////////////*/

    function test_immutableArgs_underlyingIsToken0() public view {
        assertEq(address(ct.panopticPool()), address(this), "panopticPool");
        assertTrue(ct.underlyingIsToken0(), "underlyingIsToken0");
        assertEq(ct.underlyingToken(), address(underlying), "underlyingToken");
        assertEq(ct.asset(), address(underlying), "asset");
        assertEq(ct.token0(), address(underlying), "token0");
        assertEq(ct.token1(), otherToken, "token1");
        assertEq(address(ct.riskEngine()), address(riskEngine), "riskEngine");
        assertEq(address(ct.poolManager()), address(0), "poolManager");
        assertEq(ct.poolFee(), POOL_FEE, "poolFee");
    }

    function test_immutableArgs_underlyingIsToken1() public {
        CollateralTrackerV2 ct1 = _deploy(false);

        assertEq(address(ct1.panopticPool()), address(this), "panopticPool");
        assertFalse(ct1.underlyingIsToken0(), "underlyingIsToken0");
        assertEq(ct1.underlyingToken(), address(underlying), "underlyingToken");
        assertEq(ct1.token0(), otherToken, "token0");
        assertEq(ct1.token1(), address(underlying), "token1");
        assertEq(address(ct1.riskEngine()), address(riskEngine), "riskEngine");
        assertEq(address(ct1.poolManager()), address(0), "poolManager");
        assertEq(ct1.poolFee(), POOL_FEE, "poolFee");
    }

    function test_immutableArgs_fuzz(
        address pool,
        bool isToken0,
        address[5] memory addrs,
        uint24 fee
    ) public {
        address impl = address(new CollateralTrackerV2());
        CollateralTrackerV2 tracker = CollateralTrackerV2(
            impl.clone(
                abi.encodePacked(
                    pool,
                    isToken0,
                    addrs[0],
                    addrs[1],
                    addrs[2],
                    addrs[3],
                    addrs[4],
                    fee
                )
            )
        );

        assertEq(address(tracker.panopticPool()), pool, "panopticPool");
        assertEq(tracker.underlyingIsToken0(), isToken0, "underlyingIsToken0");
        assertEq(tracker.underlyingToken(), addrs[0], "underlyingToken");
        assertEq(tracker.token0(), addrs[1], "token0");
        assertEq(tracker.token1(), addrs[2], "token1");
        assertEq(address(tracker.riskEngine()), addrs[3], "riskEngine");
        assertEq(address(tracker.poolManager()), addrs[4], "poolManager");
        assertEq(tracker.poolFee(), fee, "poolFee");
    }

    /*//////////////////////////////////////////////////////////////
                             unlockCallback
    //////////////////////////////////////////////////////////////*/

    function test_unlockCallback_revertsForNonPoolManager(
        address caller,
        bytes memory data
    ) public {
        // the tracker has no PoolManager at all in the V3 configuration
        vm.assume(caller != address(0));

        vm.prank(caller);
        vm.expectRevert(Errors.UnauthorizedUniswapCallback.selector);
        ct.unlockCallback(data);
    }

    function test_unlockCallback_revertsForPanopticPool() public {
        vm.expectRevert(Errors.UnauthorizedUniswapCallback.selector);
        ct.unlockCallback(abi.encode(alice, int256(1), uint256(0)));
    }

    /*//////////////////////////////////////////////////////////////
                        maxWithdraw / maxRedeem
    //////////////////////////////////////////////////////////////*/

    function test_maxWithdrawAndRedeem_freshTracker() public view {
        // only the single virtual asset is deposited, and it is never withdrawable
        assertEq(ct.maxWithdraw(alice), 0, "maxWithdraw");
        assertEq(ct.maxRedeem(alice), 0, "maxRedeem");
    }

    function test_maxWithdrawAndRedeem_uninitializedTracker() public {
        // nothing deposited at all, not even the virtual asset
        address impl = address(new CollateralTrackerV2());
        CollateralTrackerV2 raw = CollateralTrackerV2(
            impl.clone(
                abi.encodePacked(
                    address(this),
                    true,
                    address(underlying),
                    address(underlying),
                    otherToken,
                    address(riskEngine),
                    address(0),
                    POOL_FEE
                )
            )
        );

        // share conversions divide by a zero supply before initialization
        vm.expectRevert();
        raw.maxWithdraw(alice);
        vm.expectRevert();
        raw.maxRedeem(alice);
    }

    function test_maxWithdrawAndRedeem_soleDepositor(uint256 assets) public {
        assets = bound(assets, 1, type(uint104).max);
        uint256 shares = _deposit(alice, assets);

        assertEq(ct.maxWithdraw(alice), ct.convertToAssets(shares), "maxWithdraw is the balance");
        assertEq(ct.maxRedeem(alice), shares, "maxRedeem is the balance");
        assertEq(ct.maxWithdraw(bob), 0, "nothing for a non-depositor");
        assertEq(ct.maxRedeem(bob), 0, "nothing for a non-depositor");
    }

    function test_maxWithdrawAndRedeem_zeroWithOpenPositions(uint256 assets, uint256 legs) public {
        assets = bound(assets, 1, type(uint104).max);
        legs = bound(legs, 1, 255);
        _deposit(alice, assets);

        numberOfLegs[alice] = legs;

        assertEq(ct.maxWithdraw(alice), 0, "maxWithdraw");
        assertEq(ct.maxRedeem(alice), 0, "maxRedeem");

        numberOfLegs[alice] = 0;
        assertGt(ct.maxRedeem(alice), 0, "restored once positions are closed");
    }

    function test_maxWithdrawAndRedeem_cappedByAssetsLeftInPool() public {
        _deposit(alice, 1_000_000);
        _deposit(bob, 1_000_000);

        // bob sells options: 1.5m of the 2m deposited leave the tracker for the AMM
        ct.settleMint(bob, 0, 1_500_000, 1_500_000, _riskParameters(0, 0, 0, 0, address(0)));

        // alice still owns 1m of assets, but only 500k (less the virtual asset) can be paid out
        assertEq(ct.convertToAssets(ct.balanceOf(alice)), 1_000_000, "alice's claim");
        assertEq(ct.maxWithdraw(alice), 500_000, "maxWithdraw capped by available assets");
        assertEq(ct.maxRedeem(alice), ct.convertToShares(500_000), "maxRedeem capped likewise");
        assertLt(ct.maxRedeem(alice), ct.balanceOf(alice), "below her balance");
    }

    function test_maxWithdrawAndRedeem_creditedSharesAreNotWithdrawable() public {
        _deposit(alice, 1_000_000);
        _deposit(bob, 1_000_000);

        // bob buys options: 1.9m of assets are credited to the pool, backed by shares nobody can redeem
        ct.settleMint(bob, 1_900_000, 0, -1_900_000, _riskParameters(0, 0, 0, 0, address(0)));

        uint256 credited = ct.totalSupply() - 2_000_000 * 10 ** 6 - 10 ** 6;
        assertGt(credited, 0, "credited shares exist");

        // 3.9m deposited, of which 1.9m backs the credited shares: 2m remain for the two depositors
        assertEq(ct.maxWithdraw(alice), 1_000_000, "maxWithdraw: full claim");
        assertEq(ct.maxRedeem(alice), ct.balanceOf(alice), "maxRedeem: full balance");
    }

    function test_maxWithdrawAndRedeem_zeroWhenCreditedSharesExceedDeposits() public {
        _deposit(alice, 1_000_000);
        _deposit(bob, 1_000_000);

        // bob buys options while almost everything else sits in the AMM:
        // the credited shares then outweigh what is left in the tracker
        ct.settleMint(bob, 0, 1_900_000, 1_900_000, _riskParameters(0, 0, 0, 0, address(0)));
        ct.settleMint(bob, 500_000, 0, 0, _riskParameters(0, 0, 0, 0, address(0)));

        assertEq(ct.maxWithdraw(alice), 0, "maxWithdraw");
        assertEq(ct.maxRedeem(alice), 0, "maxRedeem");
    }

    /*//////////////////////////////////////////////////////////////
                  withdraw WITH OPEN POSITIONS: LIMITS
    //////////////////////////////////////////////////////////////*/

    function test_withdrawWithPositions_revertsWhenCreditedSharesExceedDeposits() public {
        _deposit(alice, 1_000_000);
        _deposit(bob, 1_000_000);
        ct.settleMint(bob, 0, 1_900_000, 1_900_000, _riskParameters(0, 0, 0, 0, address(0)));
        ct.settleMint(bob, 500_000, 0, 0, _riskParameters(0, 0, 0, 0, address(0)));
        numberOfLegs[alice] = 1;

        // nothing is available once the credited shares are set aside, whatever alice's balance
        vm.prank(alice);
        vm.expectRevert(Errors.ExceedsMaximumRedemption.selector);
        ct.withdraw(1, alice, alice, new TokenId[](0), false);
    }

    function test_withdrawWithPositions_cappedByAssetsLeftInPool() public {
        _deposit(alice, 1_000_000);
        _deposit(bob, 1_000_000);
        ct.settleMint(bob, 0, 1_500_000, 1_500_000, _riskParameters(0, 0, 0, 0, address(0)));
        numberOfLegs[alice] = 1;
        underlying.approve(address(ct), type(uint256).max);

        // one asset more than what is left in the tracker is refused
        vm.prank(alice);
        vm.expectRevert(Errors.ExceedsMaximumRedemption.selector);
        ct.withdraw(500_001, alice, alice, new TokenId[](0), false);

        // exactly what is left goes through, even with a position open
        vm.prank(alice);
        ct.withdraw(500_000, alice, alice, new TokenId[](0), false);
        assertEq(underlying.balanceOf(alice), 500_000, "alice received the assets");
    }

    function test_withdrawWithPositions_revertsWhenEveryDepositedAssetIsInTheAMM() public {
        _deposit(alice, 1_000_000);
        _deposit(bob, 1_000_000);
        // the pool moves every deposited asset, virtual one included, into the AMM
        ct.settleMint(bob, 0, 2_000_000, 2_000_001, _riskParameters(0, 0, 0, 0, address(0)));
        numberOfLegs[alice] = 1;

        assertEq(ct.maxWithdraw(bob), 0, "maxWithdraw");
        assertEq(ct.maxRedeem(bob), 0, "maxRedeem");

        vm.prank(alice);
        vm.expectRevert(Errors.ExceedsMaximumRedemption.selector);
        ct.withdraw(1, alice, alice, new TokenId[](0), false);
    }

    function test_withdrawWithPositions_revertsOnUninitializedTracker() public {
        address impl = address(new CollateralTrackerV2());
        CollateralTrackerV2 raw = CollateralTrackerV2(
            impl.clone(
                abi.encodePacked(
                    address(this),
                    true,
                    address(underlying),
                    address(underlying),
                    otherToken,
                    address(riskEngine),
                    address(0),
                    POOL_FEE
                )
            )
        );

        vm.prank(alice);
        vm.expectRevert();
        raw.withdraw(1, alice, alice, new TokenId[](0), false);
    }

    /*//////////////////////////////////////////////////////////////
                        settleMint: COMMISSION
    //////////////////////////////////////////////////////////////*/

    function test_settleMint_revertsForNonPanopticPool(address caller) public {
        vm.assume(caller != address(this));

        vm.prank(caller);
        vm.expectRevert(Errors.NotPanopticPool.selector);
        ct.settleMint(alice, 0, 1, 0, _riskParameters(0, 0, 0, 0, address(0)));
    }

    function test_settleMint_noBuilder_burnsWholeCommission() public {
        uint256 shares = _deposit(alice, 1_000_000);
        uint256 supplyBefore = ct.totalSupply();

        // 1% of a 100k notional
        vm.expectEmit(true, true, true, true, address(ct));
        emit CommissionPaid(alice, address(0), 1_000, 0);
        (, int128 tokenPaid) = ct.settleMint(
            alice,
            0,
            100_000,
            100_000,
            _riskParameters(100, 0, 6_000, 3_000, address(0))
        );

        uint256 commissionShares = 1_000 * 10 ** 6;
        assertEq(ct.balanceOf(alice), shares - commissionShares, "alice pays the commission");
        assertEq(ct.totalSupply(), supplyBefore - commissionShares, "commission shares are burnt");
        assertEq(ct.balanceOf(address(riskEngine)), 0, "no protocol share without a builder");
        assertEq(tokenPaid, 1_000, "tokenPaid is the commission");
    }

    function test_settleMint_withBuilder_splitsCommission() public {
        uint256 shares = _deposit(alice, 1_000_000);
        uint256 supplyBefore = ct.totalSupply();

        // 1% of a 100k notional, of which 60% goes to the protocol and 30% to the builder
        vm.expectEmit(true, true, true, true, address(ct));
        emit CommissionPaid(alice, builder, 600, 300);
        (, int128 tokenPaid) = ct.settleMint(
            alice,
            0,
            100_000,
            100_000,
            _riskParameters(100, 0, 6_000, 3_000, builder)
        );

        uint256 commissionShares = 1_000 * 10 ** 6;
        assertEq(ct.balanceOf(address(riskEngine)), (commissionShares * 6) / 10, "protocol share");
        assertEq(ct.balanceOf(builder), (commissionShares * 3) / 10, "builder share");
        // the remaining 10% is a discount: it stays with the option owner
        assertEq(ct.balanceOf(alice), shares - (commissionShares * 9) / 10, "alice pays 90%");
        assertEq(ct.totalSupply(), supplyBefore, "nothing is burnt on the builder path");
        assertEq(tokenPaid, 1_000, "tokenPaid reports the undiscounted commission");
    }

    function test_settleMint_withBuilder_fuzz(
        uint256 notional,
        uint256 notionalFee,
        uint256 protocolSplit,
        uint256 builderSplit
    ) public {
        notional = bound(notional, 1, 10 ** 12);
        notionalFee = bound(notionalFee, 0, 1_000);
        protocolSplit = bound(protocolSplit, 0, DECIMALS);
        builderSplit = bound(builderSplit, 0, DECIMALS - protocolSplit);

        uint256 shares = _deposit(alice, 10 ** 13);
        uint256 supplyBefore = ct.totalSupply();

        ct.settleMint(
            alice,
            0,
            int128(int256(notional)),
            int128(int256(notional)),
            _riskParameters(notionalFee, 0, protocolSplit, builderSplit, builder)
        );

        // commission rounds up, then each split rounds down
        uint256 commission = (notional * notionalFee + DECIMALS - 1) / DECIMALS;
        uint256 commissionShares = commission * 10 ** 6;
        uint256 toProtocol = (commissionShares * protocolSplit) / DECIMALS;
        uint256 toBuilder = (commissionShares * builderSplit) / DECIMALS;

        assertEq(ct.balanceOf(address(riskEngine)), toProtocol, "protocol share");
        assertEq(ct.balanceOf(builder), toBuilder, "builder share");
        assertEq(ct.balanceOf(alice), shares - toProtocol - toBuilder, "alice pays both");
        assertEq(ct.totalSupply(), supplyBefore, "supply conserved");
    }

    function test_settleMint_revertsWhenCommissionExceedsBalance() public {
        // alice holds 1 asset worth of shares, the commission on the mint is 10 assets
        _deposit(bob, 1_000_000);
        uint256 shares = _deposit(alice, 1);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.NotEnoughTokens.selector, address(ct), 10, 1)
        );
        ct.settleMint(alice, 0, 1_000, 1_000, _riskParameters(100, 0, 0, 0, address(0)));

        assertEq(ct.balanceOf(alice), shares, "balance untouched");
    }

    /*//////////////////////////////////////////////////////////////
                        settleBurn: COMMISSION
    //////////////////////////////////////////////////////////////*/

    function _openShort(address account, int128 notional) internal {
        ct.settleMint(account, 0, notional, notional, _riskParameters(0, 0, 0, 0, address(0)));
    }

    function test_settleBurn_revertsForNonPanopticPool(address caller) public {
        vm.assume(caller != address(this));

        vm.prank(caller);
        vm.expectRevert(Errors.NotPanopticPool.selector);
        ct.settleBurn(alice, 0, 1, 0, 0, _riskParameters(0, 0, 0, 0, address(0)));
    }

    function test_settleBurn_noPremium_noCommission() public {
        uint256 shares = _deposit(alice, 1_000_000);
        _openShort(alice, 100_000);

        vm.recordLogs();
        int128 tokenPaid = ct.settleBurn(
            alice,
            0,
            100_000,
            -100_000,
            0,
            _riskParameters(100, 1_000, 6_000, 3_000, builder)
        );

        assertEq(vm.getRecordedLogs().length, 0, "no CommissionPaid without premium");
        assertEq(ct.balanceOf(alice), shares, "alice is whole");
        assertEq(tokenPaid, 0, "nothing paid");
    }

    function test_settleBurn_noBuilder_burnsPremiumCommission() public {
        uint256 shares = _deposit(alice, 1_000_000);
        _openShort(alice, 100_000);
        uint256 supplyBefore = ct.totalSupply();

        // 10% of a 5k premium is 500, below the 10x notional-fee cap of 10% of 100k
        vm.expectEmit(true, true, true, true, address(ct));
        emit CommissionPaid(alice, address(0), 500, 0);
        ct.settleBurn(
            alice,
            0,
            100_000,
            -100_000,
            5_000,
            _riskParameters(100, 1_000, 6_000, 3_000, address(0))
        );

        // alice receives the 5k premium as shares and pays 500 of commission
        assertEq(ct.balanceOf(alice), shares + 4_500 * 10 ** 6, "premium net of commission");
        assertEq(ct.totalSupply(), supplyBefore + 4_500 * 10 ** 6, "commission shares are burnt");
    }

    function test_settleBurn_withBuilder_splitsPremiumCommission() public {
        uint256 shares = _deposit(alice, 1_000_000);
        _openShort(alice, 100_000);
        uint256 supplyBefore = ct.totalSupply();

        vm.expectEmit(true, true, true, true, address(ct));
        emit CommissionPaid(alice, builder, 300, 150);
        ct.settleBurn(
            alice,
            0,
            100_000,
            -100_000,
            5_000,
            _riskParameters(100, 1_000, 6_000, 3_000, builder)
        );

        uint256 commissionShares = 500 * 10 ** 6;
        assertEq(ct.balanceOf(address(riskEngine)), (commissionShares * 6) / 10, "protocol share");
        assertEq(ct.balanceOf(builder), (commissionShares * 3) / 10, "builder share");
        assertEq(
            ct.balanceOf(alice),
            shares + 5_000 * 10 ** 6 - (commissionShares * 9) / 10,
            "alice keeps the premium less 90% of the commission"
        );
        assertEq(ct.totalSupply(), supplyBefore + 5_000 * 10 ** 6, "only the premium is minted");
    }

    function test_settleBurn_withBuilder_cappedByNotionalFee() public {
        _deposit(alice, 1_000_000);
        _openShort(alice, 100_000);

        // 10% of a 50k premium is 5k, but the cap is 10 x 0.1% of the 100k notional = 1k
        vm.expectEmit(true, true, true, true, address(ct));
        emit CommissionPaid(alice, builder, 600, 300);
        ct.settleBurn(
            alice,
            0,
            100_000,
            -100_000,
            50_000,
            _riskParameters(10, 1_000, 6_000, 3_000, builder)
        );
    }

    function test_settleBurn_withBuilder_premiumPaidByLong() public {
        // a negative premium (paid by the option owner) is charged on its absolute value
        _deposit(alice, 1_000_000);
        _deposit(bob, 1_000_000);
        ct.settleMint(alice, 100_000, 0, -100_000, _riskParameters(0, 0, 0, 0, address(0)));

        vm.expectEmit(true, true, true, true, address(ct));
        emit CommissionPaid(alice, builder, 300, 150);
        ct.settleBurn(
            alice,
            100_000,
            0,
            100_000,
            -5_000,
            _riskParameters(100, 1_000, 6_000, 3_000, builder)
        );
    }

    function test_settleBurn_withBuilder_settlePremiumOnly() public {
        // no notional at all, as in a premium settlement: the premium fee applies uncapped
        uint256 shares = _deposit(alice, 1_000_000);

        vm.expectEmit(true, true, true, true, address(ct));
        emit CommissionPaid(alice, builder, 300, 150);
        ct.settleBurn(alice, 0, 0, 0, 5_000, _riskParameters(100, 1_000, 6_000, 3_000, builder));

        assertEq(ct.balanceOf(builder), 150 * 10 ** 6, "builder share");
        assertEq(ct.balanceOf(alice), shares + (5_000 - 450) * 10 ** 6, "alice");
    }

    function test_settleBurn_revertsWhenCommissionExceedsBalance() public {
        // alice owes a 100 premium and holds exactly that; the 10% commission on top cannot be paid
        _deposit(bob, 1_000_000);
        _deposit(alice, 100);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.NotEnoughTokens.selector, address(ct), 10, 0)
        );
        ct.settleBurn(alice, 0, 0, 0, -100, _riskParameters(0, 1_000, 0, 0, address(0)));
    }

    /*//////////////////////////////////////////////////////////////
                           settleLiquidation
    //////////////////////////////////////////////////////////////*/

    function test_settleLiquidation_negativeBonus_revertsWhenLiquidatorCannotFund(
        uint256 balance,
        uint256 bonus
    ) public {
        bonus = bound(bonus, 1, type(uint104).max);
        balance = bound(balance, 0, bonus - 1);
        underlying.mint(bob, balance);
        vm.prank(bob);
        underlying.approve(address(ct), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.NotEnoughTokens.selector,
                address(underlying),
                bonus,
                balance
            )
        );
        ct.settleLiquidation(bob, alice, -int256(bonus));

        assertEq(underlying.balanceOf(bob), balance, "liquidator keeps their tokens");
    }

    function test_settleLiquidation_negativeBonus_pullsFromLiquidator(uint256 bonus) public {
        bonus = bound(bonus, 1, type(uint104).max);
        underlying.mint(bob, bonus);
        vm.prank(bob);
        underlying.approve(address(ct), type(uint256).max);

        // the liquidatee's balance carries the delegated virtual shares at this point
        deal(address(ct), alice, type(uint248).max);
        uint256 expectedShares = ct.convertToShares(bonus);

        ct.settleLiquidation(bob, alice, -int256(bonus));

        assertEq(underlying.balanceOf(bob), 0, "liquidator paid");
        assertEq(underlying.balanceOf(address(this)), bonus, "pool received the tokens");
        assertEq(
            ct.balanceOf(alice),
            expectedShares,
            "liquidatee credited, virtual shares revoked"
        );
    }

    function test_settleLiquidation_positiveBonus_refundsAttachedETH(uint96 value) public {
        value = uint96(bound(value, 1, type(uint96).max));
        _deposit(alice, 1_000_000);
        deal(address(ct), alice, ct.balanceOf(alice) + type(uint248).max);
        uint256 aliceShares = ct.balanceOf(alice) - type(uint248).max;
        vm.deal(address(this), value);

        // the liquidator attached ETH expecting to pay, but the bonus is in their favour
        ct.settleLiquidation{value: value}(bob, alice, 1_000);

        assertEq(bob.balance, value, "ETH forwarded back to the liquidator");
        assertEq(address(ct).balance, 0, "nothing retained");
        assertEq(ct.balanceOf(bob), 1_000 * 10 ** 6, "bonus shares");
        assertEq(ct.balanceOf(alice), aliceShares - 1_000 * 10 ** 6, "liquidatee pays the bonus");
    }

    function test_settleLiquidation_positiveBonus_exceedingBalanceMintsCappedShares() public {
        // the liquidatee holds 100 assets of shares against a 1,000 bonus: the rest is minted as protocol loss
        _deposit(bob, 1_000_000);
        _deposit(alice, 100);
        deal(address(ct), alice, ct.balanceOf(alice) + type(uint248).max);
        uint256 supplyBefore = ct.totalSupply();
        address liquidator = makeAddr("liquidator");

        ct.settleLiquidation(liquidator, alice, 1_000);

        assertEq(ct.balanceOf(alice), 0, "liquidatee emptied");
        assertGt(ct.balanceOf(liquidator), 100 * 10 ** 6, "liquidator got more than the balance");
        assertGt(ct.totalSupply(), supplyBefore, "shares were minted");
        // the liquidator ends with a claim worth the bonus, to within rounding
        assertApproxEqAbs(ct.convertToAssets(ct.balanceOf(liquidator)), 1_000, 1, "bonus value");
    }

    function test_settleLiquidation_positiveBonus_mintIsCappedWhenVaultIsNearlyEmpty() public {
        // a bonus far larger than the vault's assets: the uncapped mint formula would blow up
        _deposit(alice, 100);
        deal(address(ct), alice, ct.balanceOf(alice) + type(uint248).max);
        uint256 supplyBefore = ct.totalSupply();
        address liquidator = makeAddr("liquidator");

        ct.settleLiquidation(liquidator, alice, 10 ** 12);

        // at most 10x the pre-mint supply is created, on top of the liquidatee's transferred balance
        assertLe(ct.totalSupply(), supplyBefore * 11, "mint capped at 10x supply");
        assertEq(ct.balanceOf(alice), 0, "liquidatee emptied");
    }

    function test_settleLiquidation_positiveBonus_noMintWhenBonusExceedsADilutedVault() public {
        // When the bonus is at least the vault's total assets, the mint formula's denominator floors at 1 and
        // `rawMinted = bonus * (supply - balance)`. In a vault diluted by an earlier loss, where the liquidatee
        // holds most of the supply, that can fall below the balance already handed over: nothing more is minted.
        _deposit(alice, 1);
        assertEq(ct.totalAssets(), 2, "two assets in the vault");

        // first loss: an empty account is liquidated for a huge bonus, minting the 10x cap to `first`
        address first = makeAddr("first liquidator");
        address empty = makeAddr("empty account");
        deal(address(ct), empty, type(uint248).max);
        ct.settleLiquidation(first, empty, 10 ** 12);
        assertEq(ct.balanceOf(first), 20 * 10 ** 6, "10x the 2e6 supply");
        assertEq(ct.totalSupply(), 22 * 10 ** 6, "diluted supply");
        assertEq(ct.totalAssets(), 2, "assets unchanged");

        // second liquidation: `first` holds 20e6 of 22e6 shares and owes a bonus equal to the whole vault.
        // bonusShares = 22e6 > 20e6, and rawMinted = 2 * (22e6 - 20e6) = 4e6 <= 20e6
        address second = makeAddr("second liquidator");
        deal(address(ct), first, ct.balanceOf(first) + type(uint248).max);
        ct.settleLiquidation(second, first, 2);

        assertEq(ct.balanceOf(first), 0, "liquidatee emptied");
        assertEq(
            ct.balanceOf(second),
            20 * 10 ** 6,
            "liquidator receives the balance and nothing more"
        );
        assertEq(ct.totalSupply(), 22 * 10 ** 6, "no shares minted");
    }

    /*//////////////////////////////////////////////////////////////
                                 refund
    //////////////////////////////////////////////////////////////*/

    function test_refund_positive_movesSharesFromRefunderToRefundee(uint256 assets) public {
        uint256 aliceShares = _deposit(alice, 1_000_000);
        assets = bound(assets, 0, 1_000_000);

        ct.refund(alice, bob, int256(assets));

        assertEq(ct.balanceOf(bob), assets * 10 ** 6, "refundee credited");
        assertEq(ct.balanceOf(alice), aliceShares - assets * 10 ** 6, "refunder debited");
    }

    function test_refund_negative_movesSharesFromRefundeeToRefunder(uint256 assets) public {
        uint256 bobShares = _deposit(bob, 1_000_000);
        assets = bound(assets, 0, 1_000_000);

        // a negative amount flows the other way: the refundee pays the refunder
        ct.refund(alice, bob, -int256(assets));

        assertEq(ct.balanceOf(alice), assets * 10 ** 6, "refunder credited");
        assertEq(ct.balanceOf(bob), bobShares - assets * 10 ** 6, "refundee debited");
    }

    function test_refund_negative_revertsWhenRefundeeCannotPay(
        uint256 balance,
        uint256 assets
    ) public {
        _deposit(alice, 1_000_000);
        balance = bound(balance, 1, 1_000_000);
        assets = bound(assets, balance + 1, 10_000_000);
        _deposit(bob, balance);

        // reports what was asked for and what the refundee actually holds, both in assets
        vm.expectRevert(
            abi.encodeWithSelector(Errors.NotEnoughTokens.selector, address(ct), assets, balance)
        );
        ct.refund(alice, bob, -int256(assets));

        assertEq(ct.balanceOf(bob), balance * 10 ** 6, "refundee untouched");
        assertEq(ct.balanceOf(alice), 1_000_000 * 10 ** 6, "refunder untouched");
    }

    function test_refund_negative_exactBalanceSucceeds() public {
        _deposit(bob, 500);

        ct.refund(alice, bob, -500);

        assertEq(ct.balanceOf(bob), 0, "refundee emptied");
        assertEq(ct.balanceOf(alice), 500 * 10 ** 6, "refunder credited");
    }

    function test_refund_positive_revertsWhenRefunderCannotPay() public {
        _deposit(alice, 100);

        // the positive direction has no explicit check: the share transfer underflows
        vm.expectRevert(stdError.arithmeticError);
        ct.refund(alice, bob, 101);
    }

    function test_refund_revertsForNonPanopticPool(address caller) public {
        vm.assume(caller != address(this));

        vm.prank(caller);
        vm.expectRevert(Errors.NotPanopticPool.selector);
        ct.refund(alice, bob, 1);
    }

    function test_settleLiquidation_revertsForNonPanopticPool(address caller) public {
        vm.assume(caller != address(this));

        vm.prank(caller);
        vm.expectRevert(Errors.NotPanopticPool.selector);
        ct.settleLiquidation(bob, alice, 0);
    }
}
