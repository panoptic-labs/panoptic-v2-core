// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RiskEngineV2} from "@contracts/RiskEngine.sol";
import {RiskEngineProxy} from "@contracts/RiskEngineProxy.sol";
import {RiskEngineStub} from "@contracts/RiskEngineStub.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";
import {ISemiFungiblePositionManager} from "@contracts/interfaces/ISemiFungiblePositionManager.sol";
import {SemiFungiblePositionManagerV4} from "@contracts/SemiFungiblePositionManagerV4.sol";
import {PanopticPoolV2} from "@contracts/PanopticPool.sol";
import {CollateralTrackerV2} from "@contracts/CollateralTracker.sol";
import {PanopticFactoryV4} from "@contracts/PanopticFactoryV4.sol";
import {PanopticGuardian} from "@contracts/PanopticGuardian.sol";
import {BuilderFactory, BuilderWallet} from "@contracts/Builder.sol";
import {Constants} from "@libraries/Constants.sol";
import {Errors} from "@libraries/Errors.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {TokenId} from "@types/TokenId.sol";
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {PositionBalance} from "@types/PositionBalance.sol";
import {RiskParameters} from "@types/RiskParameters.sol";
import {OraclePack} from "@types/OraclePack.sol";
import {Pointer} from "@types/Pointer.sol";
import {RiskEngineParameters} from "@types/RiskEngineParameters.sol";
import {RiskEngineParams} from "../../testUtils/RiskEngineParams.sol";
import {ERC20S} from "../../testUtils/ERC20S.sol";
import {V4RouterSimple} from "../../testUtils/V4RouterSimple.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract UpgradePoolHarness is PanopticPoolV2 {
    constructor(ISemiFungiblePositionManager sfpm) PanopticPoolV2(sfpm) {}

    // Each dispatch stands for a separate transaction.
    function wipePriceSlot() external {
        bytes32 slot = keccak256("panoptic.price.snapshot");
        assembly {
            tstore(slot, 0)
        }
    }

    function oraclePack() external view returns (OraclePack) {
        return s_oraclePack;
    }
}

/// @notice Upgrades the RiskEngine implementation underneath a live PanopticPool that has open positions.
/// @dev Local v4 world with mock tokens (USDC token0, WETH token1), the engine behind its transparent proxy as in
/// production. Complements RiskEngineProxy.t.sol, which covers the proxy mechanics against a mock pool.
contract RiskEngineUpgradeTest is Test {
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    int24 constant STRIKE = 200310; // ~$2,000/ETH with 6/18 decimals
    int24 constant TS = 10;

    address multisig = makeAddr("multisig");
    address guardianAdmin = makeAddr("guardianAdmin");
    address treasurer = makeAddr("treasurer");
    address LP = makeAddr("LP");
    address SELLER = makeAddr("SELLER");
    address BUYER = makeAddr("BUYER");
    address BORROWER = makeAddr("BORROWER");
    address KEEPER = makeAddr("KEEPER");

    PanopticGuardian guardian;
    BuilderFactory builderFactory;
    bytes32 initCodeHash;

    UpgradePoolHarness pp;
    CollateralTrackerV2 ct0;
    CollateralTrackerV2 ct1;
    ERC20S usdc;
    ERC20S weth;
    PoolManager manager;
    V4RouterSimple router;
    PoolKey key;
    uint64 poolId;

    RiskEngineV2 implV1;
    RiskEngineProxy proxy;
    IRiskEngine re;
    ProxyAdmin proxyAdmin;

    // positions
    TokenId shortStrangle; // SELLER: short put below + short call above, both wide enough to stay in range
    TokenId shortPutNarrow; // SELLER: the chunk BUYER buys from
    TokenId longPut; // BUYER: long against shortPutNarrow's chunk
    TokenId loan; // BORROWER: width-0 USDC loan
    TokenId[] sellerList;
    TokenId[] buyerList;
    TokenId[] borrowerList;
    TokenId[] empty;

    function setUp() public {
        usdc = ERC20S(address(0x1000));
        weth = ERC20S(address(0x2000));
        vm.etch(address(usdc), address(new ERC20S("USDC", "USDC", 6)).code);
        vm.etch(address(weth), address(new ERC20S("WETH", "WETH", 18)).code);

        manager = new PoolManager(address(0));
        router = new V4RouterSimple(manager);
        key = PoolKey(
            Currency.wrap(address(usdc)),
            Currency.wrap(address(weth)),
            500,
            TS,
            IHooks(address(0))
        );
        manager.initialize(key, TickMath.getSqrtRatioAtTick(STRIKE));
        usdc.mint(address(this), 1e24);
        weth.mint(address(this), 1e36);
        usdc.approve(address(router), type(uint256).max);
        weth.approve(address(router), type(uint256).max);
        router.modifyLiquidity(address(0), key, 150000, 250000, 1e22);

        SemiFungiblePositionManagerV4 sfpm = new SemiFungiblePositionManagerV4(
            manager,
            10 ** 13,
            10 ** 13,
            0
        );
        PanopticFactoryV4 factory = new PanopticFactoryV4(
            sfpm,
            manager,
            address(new UpgradePoolHarness(ISemiFungiblePositionManager(address(sfpm)))),
            address(new CollateralTrackerV2()),
            new bytes32[](0),
            new uint256[][](0),
            new Pointer[][](0)
        );

        guardian = new PanopticGuardian(guardianAdmin, treasurer);
        builderFactory = new BuilderFactory(address(guardian));
        initCodeHash = keccak256(
            abi.encodePacked(type(BuilderWallet).creationCode, abi.encode(address(builderFactory)))
        );
        implV1 = _newImpl(RiskEngineParams.blueChip());
        proxy = new RiskEngineProxy(address(implV1), multisig);
        re = IRiskEngine(address(proxy));
        proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT)))));

        pp = UpgradePoolHarness(address(factory.deployNewPool(key, re, 0)));
        ct0 = pp.collateralToken0();
        ct1 = pp.collateralToken1();
        poolId = pp.poolId();
        assertEq(address(pp.riskEngine()), address(proxy), "pool is bound to the proxy");

        _fund(LP, 50_000_000e6, 25_000e18);
        _fund(SELLER, 400_000e6, 200e18);
        _fund(BUYER, 100_000e6, 50e18);
        _fund(BORROWER, 100_000e6, 50e18);
        _fund(KEEPER, 5_000_000e6, 2_500e18);

        _openPositions();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _newImpl(RiskEngineParameters memory p) internal returns (RiskEngineV2) {
        return new RiskEngineV2(address(guardian), address(builderFactory), initCodeHash, p);
    }

    function _impl() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(proxy), IMPL_SLOT))));
    }

    function _upgrade(address newImpl) internal {
        vm.prank(multisig);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), newImpl, "");
        assertEq(_impl(), newImpl, "implementation slot");
    }

    function _fund(address who, uint256 amount0, uint256 amount1) internal {
        usdc.mint(who, amount0);
        weth.mint(who, amount1);
        vm.startPrank(who);
        usdc.approve(address(ct0), type(uint256).max);
        weth.approve(address(ct1), type(uint256).max);
        ct0.deposit(amount0, who);
        ct1.deposit(amount1, who);
        vm.stopPrank();
    }

    /// @dev Ascending limits: no ITM swap, settle in kind.
    function _limits() internal pure returns (int24[3][] memory limits) {
        limits = new int24[3][](1);
        limits[0] = [Constants.MIN_POOL_TICK, Constants.MAX_POOL_TICK, int24(8388607)];
    }

    function _mint(address who, TokenId id, uint128 size, TokenId[] storage list) internal {
        list.push(id);
        TokenId[] memory ids = new TokenId[](1);
        ids[0] = id;
        uint128[] memory sizes = new uint128[](1);
        sizes[0] = size;
        vm.prank(who);
        pp.dispatch(ids, list, sizes, _limits(), false, 0);
        pp.wipePriceSlot();
    }

    function _burn(address who, TokenId id, TokenId[] memory finalList) internal {
        TokenId[] memory ids = new TokenId[](1);
        ids[0] = id;
        vm.prank(who);
        pp.dispatch(ids, finalList, new uint128[](1), _limits(), false, 0);
        pp.wipePriceSlot();
    }

    function _one(TokenId id) internal pure returns (TokenId[] memory list) {
        list = new TokenId[](1);
        list[0] = id;
    }

    function _openPositions() internal {
        TokenId base = TokenId.wrap(0).addPoolId(poolId);

        // 2 ETH short strangle, each leg 2,000 ticks wide, centred 1,500 ticks away from spot
        shortStrangle = base.addLeg(0, 1, 1, 0, 1, 0, STRIKE - 1500, 200);
        shortStrangle = shortStrangle.addLeg(1, 1, 1, 0, 0, 1, STRIKE + 1500, 200);
        // 5 ETH short put, 400 ticks wide, in range at spot
        shortPutNarrow = base.addLeg(0, 1, 1, 0, 1, 0, STRIKE, 40);
        // 2 ETH long on the same chunk
        longPut = base.addLeg(0, 1, 1, 1, 1, 0, STRIKE, 40);
        // 20,000 USDC loan
        loan = base.addLeg(0, 1, 0, 0, 0, 0, STRIKE, 0);

        _mint(SELLER, shortStrangle, 2e18, sellerList);
        _mint(SELLER, shortPutNarrow, 5e18, sellerList);
        _mint(BUYER, longPut, 2e18, buyerList);
        _mint(BORROWER, loan, 20_000e6, borrowerList);

        // let interest and the oracle move a little before any snapshot
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 7200);
        pp.pokeOracle();
        pp.wipePriceSlot();
    }

    /// @dev Everything the engine reports about one account, through the pool and directly, at several ticks.
    function _accountView(
        address who,
        TokenId[] memory list
    ) internal view returns (bytes memory out) {
        (
            LeftRightUnsigned shortPremium,
            LeftRightUnsigned longPremium,
            PositionBalance[] memory balances,
            LeftRightUnsigned[] memory requirements,

        ) = pp.getFullPositionsData(who, true, list);
        out = abi.encode(shortPremium, longPremium, balances, requirements);

        int24[5] memory ticks = [STRIKE - 3000, STRIKE - 500, STRIKE, STRIKE + 500, STRIKE + 3000];
        for (uint256 i; i < ticks.length; ++i) {
            out = bytes.concat(
                out,
                _marginAt(who, list, balances, shortPremium, longPremium, ticks[i]),
                abi.encode(_health(who, list, balances, shortPremium, longPremium, ticks[i])),
                abi.encode(re.getPerPositionCollateralRequirements(balances, list, ticks[i]))
            );
        }
    }

    function _marginAt(
        address who,
        TokenId[] memory list,
        PositionBalance[] memory balances,
        LeftRightUnsigned shortPremium,
        LeftRightUnsigned longPremium,
        int24 atTick
    ) internal view returns (bytes memory) {
        // raw calls keep the two nine-argument engine calls off this frame's stack
        (bool ok0, bytes memory margin) = address(re).staticcall(
            abi.encodeCall(
                IRiskEngine.getMargin,
                (balances, atTick, who, list, shortPremium, longPremium, ct0, ct1)
            )
        );
        (bool ok1, bytes memory solvent) = address(re).staticcall(
            abi.encodeCall(
                IRiskEngine.isAccountSolvent,
                (balances, list, atTick, who, shortPremium, longPremium, ct0, ct1, 10_000_000)
            )
        );
        require(ok0 && ok1, "engine view reverted");
        return bytes.concat(margin, solvent);
    }

    /// @dev The account's health at `atTick`: the largest requirement multiplier (scaled by DECIMALS) at which the
    /// engine still calls it solvent. One number that moves with every input to the solvency check: balances,
    /// requirements, premia, interest and the cross-collateral buffers.
    function _health(
        address who,
        TokenId[] memory list,
        PositionBalance[] memory balances,
        LeftRightUnsigned shortPremium,
        LeftRightUnsigned longPremium,
        int24 atTick
    ) internal view returns (uint256 lo) {
        uint256 hi = 1e12;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            (bool ok, bytes memory solvent) = address(re).staticcall(
                abi.encodeCall(
                    IRiskEngine.isAccountSolvent,
                    (balances, list, atTick, who, shortPremium, longPremium, ct0, ct1, mid)
                )
            );
            require(ok, "engine view reverted");
            if (abi.decode(solvent, (bool))) lo = mid;
            else hi = mid - 1;
        }
    }

    /// @dev Everything the engine reports about the pool as a whole.
    function _poolView() internal view returns (bytes memory) {
        return bytes.concat(_oracleView(), _rateView(), _constantsView());
    }

    function _oracleView() internal view returns (bytes memory out) {
        (RiskParameters rp, int24 currentTick) = pp.getRiskParameters(0);
        OraclePack pack = pp.oraclePack();
        out = abi.encode(rp, currentTick, re.twapEMA(pack), re.isSafeMode(currentTick, pack));
        {
            (int24 spot, int24 median, int24 latest, OraclePack updated) = re.getOracleTicks(
                currentTick,
                pack
            );
            out = bytes.concat(out, abi.encode(spot, median, latest, updated));
        }
        (int24[] memory solvencyTicks, ) = re.getSolvencyTicks(currentTick, pack, 0);
        out = bytes.concat(out, abi.encode(solvencyTicks, pp.getTWAP()));
    }

    function _rateView() internal view returns (bytes memory) {
        return
            abi.encode(
                ct0.interestRate(),
                ct1.interestRate(),
                ct0.previewOwedInterest(BORROWER),
                ct0.previewOwedInterest(SELLER),
                ct1.previewOwedInterest(SELLER)
            );
    }

    function _constantsView() internal view returns (bytes memory) {
        return
            abi.encode(
                re.vegoid(),
                re.DECIMALS(),
                re.CROSS_BUFFER_0(),
                re.CROSS_BUFFER_1(),
                re.crossBufferRatio(9_250, re.CROSS_BUFFER_0()),
                re.crossBufferRatio(9_250, re.CROSS_BUFFER_1()),
                re.GUARDIAN(),
                re.BUILDER_FACTORY(),
                re.getFeeRecipient(0)
            );
    }

    /// @dev Hashes of the pool-wide view and of each account's view, compared slot by slot so a failure names
    /// the part that moved.
    function _fullView() internal view returns (bytes32[4] memory out) {
        out[0] = keccak256(_poolView());
        out[1] = keccak256(_accountView(SELLER, sellerList));
        out[2] = keccak256(_accountView(BUYER, buyerList));
        out[3] = keccak256(_accountView(BORROWER, borrowerList));
    }

    function _assertSameView(bytes32[4] memory expected, string memory when) internal view {
        bytes32[4] memory current = _fullView();
        assertEq(
            current[0],
            expected[0],
            string.concat(when, ": pool-wide engine outputs changed")
        );
        assertEq(current[1], expected[1], string.concat(when, ": SELLER margin outputs changed"));
        assertEq(current[2], expected[2], string.concat(when, ": BUYER margin outputs changed"));
        assertEq(current[3], expected[3], string.concat(when, ": BORROWER margin outputs changed"));
    }

    /// @dev Share balances of every account plus the trackers' totals: the complete economic state.
    function _balances() internal view returns (bytes memory) {
        return bytes.concat(_balancesOf(ct0), _balancesOf(ct1));
    }

    function _balancesOf(CollateralTrackerV2 ct) internal view returns (bytes memory) {
        return
            abi.encode(
                ct.balanceOf(SELLER),
                ct.balanceOf(BUYER),
                ct.balanceOf(BORROWER),
                ct.balanceOf(KEEPER),
                ct.totalAssets(),
                ct.totalSupply(),
                ERC20S(ct.asset()).balanceOf(address(proxy))
            );
    }

    /// @dev Runs every close path on the open book and returns the resulting balances.
    function _closeEverything() internal returns (bytes memory) {
        // KEEPER force-exercises BUYER's long
        vm.prank(KEEPER);
        pp.dispatchFrom(
            empty,
            BUYER,
            buyerList,
            empty,
            LeftRightUnsigned.wrap(0).addToRightSlot(1).addToLeftSlot(1)
        );
        pp.wipePriceSlot();
        assertEq(pp.numberOfLegs(BUYER), 0, "long exercised");

        // interest keeps compounding between actions
        vm.warp(block.timestamp + 12 hours);
        vm.roll(block.number + 3600);

        _burn(BORROWER, loan, empty);
        _burn(SELLER, shortPutNarrow, _one(shortStrangle));
        _burn(SELLER, shortStrangle, empty);

        assertEq(pp.numberOfLegs(SELLER), 0, "seller closed");
        assertEq(pp.numberOfLegs(BORROWER), 0, "borrower closed");

        // with no positions left everyone can exit completely
        _redeemAll(SELLER);
        _redeemAll(BUYER);
        _redeemAll(BORROWER);
        return bytes.concat(_balances(), _wallet(SELLER), _wallet(BUYER), _wallet(BORROWER));
    }

    function _wallet(address who) internal view returns (bytes memory) {
        return abi.encode(usdc.balanceOf(who), weth.balanceOf(who));
    }

    function _redeemAll(address who) internal {
        vm.startPrank(who);
        ct0.accrueInterest();
        ct1.accrueInterest();
        assertEq(ct0.maxRedeem(who), ct0.balanceOf(who), "token0 not fully redeemable");
        assertEq(ct1.maxRedeem(who), ct1.balanceOf(who), "token1 not fully redeemable");
        ct0.redeem(ct0.balanceOf(who), who, who);
        ct1.redeem(ct1.balanceOf(who), who, who);
        vm.stopPrank();
        assertEq(ct0.balanceOf(who), 0, "token0 shares left");
        assertEq(ct1.balanceOf(who), 0, "token1 shares left");
    }

    /// @dev Withdraws as much of `ct` as the solvency check lets an account with open positions take out, less a
    /// `cushion` left behind. Returns the amount withdrawn.
    function _withdrawMax(
        CollateralTrackerV2 ct,
        address who,
        TokenId[] memory list,
        uint256 cushion
    ) internal returns (uint256 amount) {
        uint256 lo;
        uint256 hi = ct.convertToAssets(ct.balanceOf(who));
        for (uint256 i; i < 48 && lo < hi; ++i) {
            uint256 mid = (lo + hi + 1) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(who);
            try ct.withdraw(mid, who, who, list, false) {
                lo = mid;
            } catch {
                hi = mid - 1;
            }
            vm.revertToState(snap);
        }
        if (lo <= cushion) return 0;
        amount = lo - cushion;
        vm.prank(who);
        ct.withdraw(amount, who, who, list, false);
    }

    /*//////////////////////////////////////////////////////////////
                    SAME-PARAMETER UPGRADE IS A NO-OP
    //////////////////////////////////////////////////////////////*/

    /// @dev Redeploying the same source with the same parameters must not change a single engine output for a
    /// pool with open shorts, longs and loans.
    function test_upgradeSameParameters_everyEngineOutputUnchanged() public {
        bytes32[4] memory viewBefore = _fullView();
        bytes32 balancesBefore = keccak256(_balances());

        RiskEngineV2 implV2 = _newImpl(RiskEngineParams.blueChip());
        assertTrue(address(implV2) != address(implV1));
        _upgrade(address(implV2));

        _assertSameView(viewBefore, "same-parameter upgrade");
        assertEq(keccak256(_balances()), balancesBefore, "balances changed by the upgrade itself");
    }

    /// @dev Close the whole book (force exercise, loan repayment, burns, full redemption) on the old implementation
    /// and, from the same starting state, after a same-parameter upgrade. Every balance must match to the wei.
    function test_upgradeSameParameters_closePathsSettleIdentically() public {
        uint256 snap = vm.snapshotState();
        bytes32 closedOnV1 = keccak256(_closeEverything());
        vm.revertToState(snap);

        _upgrade(address(_newImpl(RiskEngineParams.blueChip())));
        bytes32 closedOnV2 = keccak256(_closeEverything());

        assertEq(closedOnV2, closedOnV1, "settlement differs after a same-parameter upgrade");
    }

    /// @dev New positions can be opened against the upgraded engine and coexist with the ones minted before it.
    function test_upgrade_mintAfterUpgradeCoexistsWithOldPositions() public {
        _upgrade(address(_newImpl(RiskEngineParams.blueChip())));

        TokenId newShort = TokenId.wrap(0).addPoolId(poolId).addLeg(
            0,
            1,
            1,
            0,
            0,
            0,
            STRIKE + 800,
            60
        );
        _mint(SELLER, newShort, 1e18, sellerList);
        assertEq(pp.numberOfLegs(SELLER), 4, "2 + 1 + 1 legs");

        pp.validateCollateralWithdrawable(SELLER, sellerList, false);
        _closeEverythingWith(newShort);
    }

    function _closeEverythingWith(TokenId extra) internal {
        TokenId[] memory rest = new TokenId[](2);
        rest[0] = shortStrangle;
        rest[1] = shortPutNarrow;
        _burn(SELLER, extra, rest);
        sellerList.pop();
        _closeEverything();
    }

    /*//////////////////////////////////////////////////////////////
                    UPGRADES THAT CHANGE PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Raising the seller ratio and maintenance margin makes a healthy account liquidatable in the block the
    /// upgrade lands, and the liquidation runs to completion on the new implementation.
    function test_upgradeTighterMargin_healthyAccountBecomesLiquidatable() public {
        // leave SELLER with a modest cushion over the current requirement
        _withdrawMax(ct0, SELLER, sellerList, 0);
        _withdrawMax(ct1, SELLER, sellerList, 0.1e18);
        pp.validateCollateralWithdrawable(SELLER, sellerList, false);

        // healthy: a liquidation attempt is refused
        vm.prank(KEEPER);
        vm.expectRevert(Errors.NotMarginCalled.selector);
        pp.dispatchFrom(
            empty,
            SELLER,
            sellerList,
            empty,
            LeftRightUnsigned.wrap(0).addToRightSlot(1).addToLeftSlot(1)
        );

        RiskEngineParameters memory p = RiskEngineParams.blueChip();
        p.sellerCollateralRatio = 6_000_000; // 20% -> 60%
        p.maintMarginRate = 3_000_000; // 10% -> 30%
        _upgrade(address(_newImpl(p)));

        vm.expectRevert();
        pp.validateCollateralWithdrawable(SELLER, sellerList, false);

        // BUYER's long sits on one of SELLER's chunks: it has to be exercised before that liquidity can be removed
        vm.prank(KEEPER);
        pp.dispatchFrom(
            empty,
            BUYER,
            buyerList,
            empty,
            LeftRightUnsigned.wrap(0).addToRightSlot(1).addToLeftSlot(1)
        );
        pp.wipePriceSlot();

        // a liquidator may have to pay one token in from its wallet while the bonus arrives in the other
        usdc.mint(KEEPER, 1_000_000e6);
        weth.mint(KEEPER, 500e18);
        uint256 valueBefore = _keeperValue();

        vm.prank(KEEPER);
        pp.dispatchFrom(
            empty,
            SELLER,
            sellerList,
            empty,
            LeftRightUnsigned.wrap(0).addToRightSlot(1).addToLeftSlot(1)
        );
        pp.wipePriceSlot();

        assertEq(pp.numberOfLegs(SELLER), 0, "liquidated");
        assertGt(_keeperValue(), valueBefore, "liquidator was not paid a bonus");
    }

    /// @dev KEEPER's wallet plus collateral, in USDC at the pool price.
    function _keeperValue() internal view returns (uint256) {
        uint256 amount0 = usdc.balanceOf(KEEPER) + ct0.convertToAssets(ct0.balanceOf(KEEPER));
        uint256 amount1 = weth.balanceOf(KEEPER) + ct1.convertToAssets(ct1.balanceOf(KEEPER));
        return amount0 + PanopticMath.convert1to0(amount1, TickMath.getSqrtRatioAtTick(STRIKE));
    }

    /// @dev Loosening parameters frees collateral immediately for positions minted under the old ones.
    function test_upgradeLooserMargin_freesCollateral() public {
        _withdrawMax(ct0, SELLER, sellerList, 0);
        _withdrawMax(ct1, SELLER, sellerList, 0);
        assertGt(ct0.balanceOf(SELLER) + ct1.balanceOf(SELLER), 0, "collateral locked");

        RiskEngineParameters memory p = RiskEngineParams.blueChip();
        p.sellerCollateralRatio = 1_000_000; // 20% -> 10%
        p.maintMarginRate = 500_000;
        _upgrade(address(_newImpl(p)));

        uint256 freed0 = _withdrawMax(ct0, SELLER, sellerList, 0);
        uint256 freed1 = _withdrawMax(ct1, SELLER, sellerList, 0);
        emit log_named_decimal_uint("USDC freed by the upgrade", freed0, 6);
        emit log_named_decimal_uint("WETH freed by the upgrade", freed1, 18);
        assertTrue(freed0 > 1e6 || freed1 > 1e15, "nothing freed");
        pp.validateCollateralWithdrawable(SELLER, sellerList, false);
    }

    /// @dev Fee parameters apply to the next action; the cross buffers reported to callers follow the new values.
    function test_upgradeChangesFeesAndBuffers_appliedOnNextAction() public {
        (RiskParameters before, ) = pp.getRiskParameters(0);

        RiskEngineParameters memory p = RiskEngineParams.blueChip(7_500_000, 8_000_000);
        p.notionalFee = 10;
        p.premiumFee = 500;
        _upgrade(address(_newImpl(p)));

        (RiskParameters afterUpgrade, ) = pp.getRiskParameters(0);
        assertEq(before.notionalFee(), 3);
        assertEq(afterUpgrade.notionalFee(), 10, "notional fee");
        assertEq(afterUpgrade.premiumFee(), 500, "premium fee");
        assertEq(re.CROSS_BUFFER_0(), 7_500_000);
        assertEq(re.CROSS_BUFFER_1(), 8_000_000);

        _closeEverything();
    }

    /*//////////////////////////////////////////////////////////////
                         UPGRADES AND SAFE MODE
    //////////////////////////////////////////////////////////////*/

    /// @dev The guardian lock lives in the pool's oracle pack, not in the engine: it survives an upgrade, and the
    /// new implementation can lift it.
    function test_upgradeWhileLocked_lockSurvivesAndCanBeLifted() public {
        vm.prank(address(guardian));
        re.lockPool(PanopticPoolV2(address(pp)));
        uint8 lockedMode = pp.isSafeMode();
        assertGt(lockedMode, 1, "locked");
        bytes32[4] memory viewLocked = _fullView();

        _upgrade(address(_newImpl(RiskEngineParams.blueChip())));
        assertEq(pp.isSafeMode(), lockedMode, "lock lost across the upgrade");
        _assertSameView(viewLocked, "upgrade while locked");

        vm.prank(address(guardian));
        re.unlockPool(PanopticPoolV2(address(pp)));
        assertEq(pp.isSafeMode(), 0, "unlocked by the new implementation");

        _closeEverything();
    }

    /// @dev A pool locked before the upgrade can still be wound down after it.
    function test_upgradeWhileLocked_positionsCanStillBeClosed() public {
        vm.prank(address(guardian));
        re.lockPool(PanopticPoolV2(address(pp)));
        _upgrade(address(_newImpl(RiskEngineParams.blueChip())));

        _burn(BORROWER, loan, empty);
        _burn(SELLER, shortStrangle, _one(shortPutNarrow));
        assertEq(pp.numberOfLegs(BORROWER), 0);
        assertEq(pp.numberOfLegs(SELLER), 1);
    }

    /// @dev The guardian set on the new implementation is the one that controls the pool afterwards.
    function test_upgradeChangesGuardian_oldGuardianLosesControl() public {
        PanopticGuardian newGuardian = new PanopticGuardian(guardianAdmin, treasurer);
        RiskEngineV2 implV2 = new RiskEngineV2(
            address(newGuardian),
            address(0),
            bytes32(0),
            RiskEngineParams.blueChip()
        );
        _upgrade(address(implV2));

        vm.prank(address(guardian));
        vm.expectRevert(Errors.NotGuardian.selector);
        re.lockPool(PanopticPoolV2(address(pp)));

        vm.prank(address(newGuardian));
        re.lockPool(PanopticPoolV2(address(pp)));
        assertGt(pp.isSafeMode(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                       BAD UPGRADES AND ROLLBACK
    //////////////////////////////////////////////////////////////*/

    /// @dev Pointing the proxy at an implementation that answers nothing freezes the pool without touching funds;
    /// rolling back to the previous implementation restores it exactly.
    function test_badUpgradeFreezesPool_rollbackRestoresIt() public {
        bytes32[4] memory viewBefore = _fullView();
        bytes32 balancesBefore = keccak256(_balances());

        _upgrade(address(new RiskEngineStub()));

        TokenId[] memory ids = _one(loan);
        vm.prank(BORROWER);
        vm.expectRevert(RiskEngineStub.RiskEngineNotSet.selector);
        pp.dispatch(ids, empty, new uint128[](1), _limits(), false, 0);

        vm.expectRevert(RiskEngineStub.RiskEngineNotSet.selector);
        pp.isSafeMode();

        vm.prank(KEEPER);
        vm.expectRevert(RiskEngineStub.RiskEngineNotSet.selector);
        ct0.withdraw(1e6, KEEPER, KEEPER);

        assertEq(keccak256(_balances()), balancesBefore, "funds moved while frozen");

        // rollback: the previous implementation is still deployed
        _upgrade(address(implV1));
        _assertSameView(viewBefore, "rollback");
        _closeEverything();
    }

    /// @dev `emaPeriods` is baked into how every pool's stored oracle pack is read. This documents what changing it
    /// on a live proxy does, so the invariant in DEPLOYMENT_INSTRUCTIONS.md is enforced by a failing diff, not prose.
    function test_upgradeChangingEmaPeriods_changesOracleReadings() public {
        // move spot and let the EMAs chase it so the periods matter
        router.swapTo(address(0), key, TickMath.getSqrtRatioAtTick(STRIKE + 300));
        for (uint256 i; i < 4; ++i) {
            vm.warp(block.timestamp + 65);
            vm.roll(block.number + 5);
            pp.pokeOracle();
            pp.wipePriceSlot();
        }
        OraclePack pack = pp.oraclePack();
        int24 currentTick = pp.getCurrentTick();
        (int24 spotV1, int24 medianV1, int24 latestV1, ) = re.getOracleTicks(currentTick, pack);

        // same parameters: identical readings
        _upgrade(address(_newImpl(RiskEngineParams.blueChip())));
        (int24 spot, int24 median, int24 latest, ) = re.getOracleTicks(currentTick, pack);
        assertEq(spot, spotV1);
        assertEq(median, medianV1);
        assertEq(latest, latestV1);

        // xStocks periods on a blue-chip pool: the next oracle update diverges
        _upgrade(address(_newImpl(RiskEngineParams.blueChip())));
        vm.warp(block.timestamp + 65);
        vm.roll(block.number + 5);
        (, OraclePack nextSame) = re.computeInternalMedian(pack, currentTick);

        RiskEngineParameters memory p = RiskEngineParams.blueChip();
        p.emaPeriods = RiskEngineParams.xStocks().emaPeriods;
        _upgrade(address(_newImpl(p)));
        (, OraclePack nextChanged) = re.computeInternalMedian(pack, currentTick);

        assertTrue(
            OraclePack.unwrap(nextSame) != OraclePack.unwrap(nextChanged),
            "emaPeriods change had no effect on the stored oracle"
        );
    }

    /*//////////////////////////////////////////////////////////////
                     INTERFACE / LAYOUT INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Every selector in IRiskEngine must exist on the implementation. Pools and trackers are not upgradable,
    /// so a renamed function or a changed argument type bricks them. Reads the compiler's method tables.
    function test_implementationAnswersEveryIRiskEngineSelector() public view {
        string memory iface = vm.readFile("out/IRiskEngine.sol/IRiskEngine.json");
        string memory impl = vm.readFile("out/RiskEngine.sol/RiskEngineV2.json");
        string[] memory signatures = vm.parseJsonKeys(iface, ".methodIdentifiers");
        assertGt(signatures.length, 20, "interface method table not found");

        for (uint256 i; i < signatures.length; ++i) {
            string memory k = string.concat(".methodIdentifiers.['", signatures[i], "']");
            assertTrue(
                vm.keyExistsJson(impl, k),
                string.concat("RiskEngineV2 is missing ", signatures[i])
            );
            assertEq(
                vm.parseJsonString(impl, k),
                vm.parseJsonString(iface, k),
                string.concat("selector mismatch for ", signatures[i])
            );
        }
    }

    /// @dev The implementation must stay stateless: it runs by DELEGATECALL in the proxy's storage, which holds
    /// only the ERC-1967 slots, so a storage variable would read as zero and be written into the proxy. Walks the
    /// runtime bytecode (PUSH data and the trailing CBOR metadata skipped) and rejects any SLOAD, SSTORE, TLOAD or
    /// TSTORE.
    function test_implementationBytecodeNeverTouchesStorage() public view {
        bytes memory code = address(implV1).code;
        uint256 end = code.length -
            2 -
            ((uint256(uint8(code[code.length - 2])) << 8) | uint8(code[code.length - 1]));
        assertGt(end, 20_000, "runtime code not walked");
        for (uint256 pc; pc < end; ++pc) {
            uint8 op = uint8(code[pc]);
            if (op >= 0x60 && op <= 0x7f) {
                pc += op - 0x5f;
                continue;
            }
            assertTrue(
                op != 0x54 && op != 0x55 && op != 0x5c && op != 0x5d,
                string.concat("storage opcode at pc ", vm.toString(pc))
            );
        }
    }

    /// @dev No engine call made by the pool may write to the proxy's storage.
    function test_poolActivityNeverWritesProxyStorage() public {
        vm.record();
        _closeEverything();
        (, bytes32[] memory writes) = vm.accesses(address(proxy));
        assertEq(writes.length, 0, "engine wrote to proxy storage");
    }

    /// @dev `vegoid` is baked into the SFPM pool id of every pool; an implementation reporting another value is
    /// reading a different pool.
    function test_vegoidMatchesPoolId() public view {
        assertEq(uint8(poolId >> 40), re.vegoid(), "pool id vegoid");
    }
}
