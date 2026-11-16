// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Errors} from "@libraries/Errors.sol";
import {Constants} from "@libraries/Constants.sol";
import {PanopticPoolV2} from "@contracts/PanopticPool.sol";
import {CollateralTrackerV2} from "@contracts/CollateralTracker.sol";
import {RiskEngineV2} from "@contracts/RiskEngine.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";
import {ISemiFungiblePositionManager} from "@contracts/interfaces/ISemiFungiblePositionManager.sol";
import {SemiFungiblePositionManagerV4} from "@contracts/SemiFungiblePositionManagerV4.sol";
import {PanopticFactoryV4} from "@contracts/PanopticFactoryV4.sol";
import {TokenId} from "@types/TokenId.sol";
import {Pointer} from "@types/Pointer.sol";
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {OraclePack} from "@types/OraclePack.sol";
import {RiskEngineParams} from "../testUtils/RiskEngineParams.sol";
import {ERC20S} from "../testUtils/ERC20S.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/// @notice Fills the coverage gaps left in `contracts/PanopticPool.sol` by the rest of the suite:
/// - the `poolManager` and `tickSpacing` getters, `getAssetsOf` and `getChunkData`
/// - the risk-engine-only guard on `lockSafeMode` / `unlockSafeMode`
/// - the `InputListFail` reverts of `dispatchFrom` on a solvent account
/// @dev Local Uniswap V4 deployment of the whole protocol with two plain ERC20s, initialized at tick 0.
/// @dev Not covered: the four `PositionNotOwned` reverts in `dispatch` (burn arm), `_burnAllOptionsFrom`,
/// `_forceExercise` and `_settlePremium`. A stored position always has a non-zero size (a zero-size mint is
/// rejected, see the last test), and the latter three only run on a list already matched to the account's hash.
contract PanopticPoolCoverageTest is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 2 ** 96;
    int24 internal constant TICK_SPACING = 10;

    PoolManager internal manager;
    SemiFungiblePositionManagerV4 internal sfpm;
    PanopticFactoryV4 internal factory;
    RiskEngineV2 internal riskEngine;
    PanopticPoolV2 internal pp;
    CollateralTrackerV2 internal ct0;
    CollateralTrackerV2 internal ct1;

    ERC20S internal token0;
    ERC20S internal token1;
    PoolKey internal poolKey;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        manager = new PoolManager(address(0));
        sfpm = new SemiFungiblePositionManagerV4(
            IPoolManager(address(manager)),
            10 ** 13,
            10 ** 13,
            0
        );

        ERC20S a = new ERC20S("Token A", "TKA", 18);
        ERC20S b = new ERC20S("Token B", "TKB", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        poolKey = PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            500,
            TICK_SPACING,
            IHooks(address(0))
        );
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        factory = new PanopticFactoryV4(
            sfpm,
            IPoolManager(address(manager)),
            address(new PanopticPoolV2(ISemiFungiblePositionManager(address(sfpm)))),
            address(new CollateralTrackerV2()),
            new bytes32[](0),
            new uint256[][](0),
            new Pointer[][](0)
        );
        riskEngine = new RiskEngineV2(
            address(0),
            address(0),
            bytes32(0),
            RiskEngineParams.blueChip(10_000_000, 10_000_000)
        );

        pp = factory.deployNewPool(poolKey, IRiskEngine(address(riskEngine)), 0);
        ct0 = pp.collateralToken0();
        ct1 = pp.collateralToken1();

        _fund(alice, 1_000_000 ether);
        _fund(bob, 1_000_000 ether);
    }

    function _fund(address account, uint256 amount) internal {
        token0.mint(account, amount);
        token1.mint(account, amount);
        vm.startPrank(account);
        token0.approve(address(ct0), type(uint256).max);
        token1.approve(address(ct1), type(uint256).max);
        ct0.deposit(amount, account);
        ct1.deposit(amount, account);
        vm.stopPrank();
    }

    function _limits() internal pure returns (int24[3][] memory limits) {
        limits = new int24[3][](1);
        limits[0][0] = Constants.MIN_POOL_TICK;
        limits[0][1] = Constants.MAX_POOL_TICK;
        limits[0][2] = int24(uint24(type(uint24).max / 2));
    }

    function _list(TokenId tokenId) internal pure returns (TokenId[] memory list) {
        list = new TokenId[](1);
        list[0] = tokenId;
    }

    function _sizes(uint128 size) internal pure returns (uint128[] memory sizes) {
        sizes = new uint128[](1);
        sizes[0] = size;
    }

    /// @dev A one-leg short on token0 over the chunk [990, 1010], out of range above the current tick 0.
    function _shortTokenId() internal view returns (TokenId) {
        return TokenId.wrap(0).addPoolId(pp.poolId()).addLeg(0, 1, 0, 0, 0, 0, 1000, 2);
    }

    function _mintShort(address account, uint128 size) internal returns (TokenId tokenId) {
        tokenId = _shortTokenId();
        vm.prank(account);
        pp.dispatch(_list(tokenId), _list(tokenId), _sizes(size), _limits(), false, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        IMMUTABLE ARGUMENT GETTERS
    //////////////////////////////////////////////////////////////*/

    function test_poolManager() public view {
        assertEq(pp.poolManager(), address(manager));
    }

    function test_tickSpacing_matchesPoolKeyAndPoolId() public view {
        assertEq(pp.tickSpacing(), TICK_SPACING, "tick spacing");
        // the tick spacing is the top 16 bits of the pool id
        assertEq(uint24(pp.tickSpacing()), uint24(pp.poolId() >> 48), "from pool id");
        assertEq(pp.poolId(), sfpm.getPoolId(abi.encode(poolKey.toId()), riskEngine.vegoid()));
    }

    /*//////////////////////////////////////////////////////////////
                              getAssetsOf
    //////////////////////////////////////////////////////////////*/

    function test_getAssetsOf_matchesBothTrackers() public {
        (uint256 assets0, uint256 assets1) = pp.getAssetsOf(alice);

        assertEq(assets0, ct0.assetsOf(alice), "token0");
        assertEq(assets1, ct1.assetsOf(alice), "token1");
        assertApproxEqAbs(assets0, 1_000_000 ether, 1, "deposited token0");
        assertApproxEqAbs(assets1, 1_000_000 ether, 1, "deposited token1");

        (assets0, assets1) = pp.getAssetsOf(makeAddr("nobody"));
        assertEq(assets0, 0, "non-depositor token0");
        assertEq(assets1, 0, "non-depositor token1");
    }

    function test_getAssetsOf_tracksAsymmetricDeposits(uint96 extra0, uint96 extra1) public {
        address carol = makeAddr("carol");
        extra0 = uint96(bound(extra0, 1, 1e27));
        extra1 = uint96(bound(extra1, 1, 1e27));
        token0.mint(carol, extra0);
        token1.mint(carol, extra1);
        vm.startPrank(carol);
        token0.approve(address(ct0), extra0);
        token1.approve(address(ct1), extra1);
        ct0.deposit(extra0, carol);
        ct1.deposit(extra1, carol);
        vm.stopPrank();

        (uint256 assets0, uint256 assets1) = pp.getAssetsOf(carol);
        assertApproxEqAbs(assets0, extra0, 1, "token0");
        assertApproxEqAbs(assets1, extra1, 1, "token1");
    }

    /*//////////////////////////////////////////////////////////////
                              getChunkData
    //////////////////////////////////////////////////////////////*/

    function test_getChunkData_emptyChunk() public view {
        (
            LeftRightUnsigned liquidities0,
            LeftRightUnsigned liquidities1,
            LeftRightUnsigned settled0,
            LeftRightUnsigned settled1
        ) = pp.getChunkData(990, 1010);

        assertEq(LeftRightUnsigned.unwrap(liquidities0), 0, "liquidities0");
        assertEq(LeftRightUnsigned.unwrap(liquidities1), 0, "liquidities1");
        assertEq(LeftRightUnsigned.unwrap(settled0), 0, "settled0");
        assertEq(LeftRightUnsigned.unwrap(settled1), 0, "settled1");
    }

    function test_getChunkData_afterShortMint() public {
        _mintShort(alice, 1 ether);

        (
            LeftRightUnsigned liquidities0,
            LeftRightUnsigned liquidities1,
            LeftRightUnsigned settled0,
            LeftRightUnsigned settled1
        ) = pp.getChunkData(990, 1010);

        // the short leg added net liquidity to the token0 side of its chunk only
        assertGt(liquidities0.rightSlot(), 0, "net liquidity on tokenType 0");
        assertEq(liquidities0.leftSlot(), 0, "nothing removed");
        assertEq(LeftRightUnsigned.unwrap(liquidities1), 0, "tokenType 1 untouched");
        assertEq(LeftRightUnsigned.unwrap(settled0), 0, "nothing settled yet");
        assertEq(LeftRightUnsigned.unwrap(settled1), 0, "nothing settled yet");

        // it agrees with what the SFPM holds for the pool
        assertEq(
            LeftRightUnsigned.unwrap(liquidities0),
            LeftRightUnsigned.unwrap(
                sfpm.getAccountLiquidity(abi.encode(poolKey), address(pp), 0, 990, 1010)
            ),
            "matches the SFPM"
        );

        // a neighbouring chunk is unaffected
        (liquidities0, , , ) = pp.getChunkData(1010, 1030);
        assertEq(LeftRightUnsigned.unwrap(liquidities0), 0, "neighbour chunk");
    }

    function test_getChunkData_sizeScalesLiquidity() public {
        _mintShort(alice, 1 ether);
        (LeftRightUnsigned single, , , ) = pp.getChunkData(990, 1010);

        // bob adds three times as much to the same chunk
        _mintShort(bob, 3 ether);
        (LeftRightUnsigned both, , , ) = pp.getChunkData(990, 1010);

        assertApproxEqAbs(both.rightSlot(), uint256(single.rightSlot()) * 4, 4, "4x liquidity");
    }

    function test_getChunkData_revertsOnMisalignedLowerTick(int24 tickLower) public {
        vm.assume(tickLower % TICK_SPACING != 0);
        tickLower = int24(bound(tickLower, -887271, 999));
        vm.assume(tickLower % TICK_SPACING != 0);

        vm.expectRevert(Errors.InvalidTickBound.selector);
        pp.getChunkData(tickLower, 1000);
    }

    function test_getChunkData_revertsOnMisalignedUpperTick(int24 tickUpper) public {
        tickUpper = int24(bound(tickUpper, 1001, 887271));
        vm.assume(tickUpper % TICK_SPACING != 0);

        vm.expectRevert(Errors.InvalidTickBound.selector);
        pp.getChunkData(1000, tickUpper);
    }

    function test_getChunkData_revertsOnEmptyOrInvertedRange() public {
        vm.expectRevert(Errors.InvalidTickBound.selector);
        pp.getChunkData(1000, 1000);

        vm.expectRevert(Errors.InvalidTickBound.selector);
        pp.getChunkData(1010, 990);
    }

    /*//////////////////////////////////////////////////////////////
                          RISK ENGINE ONLY
    //////////////////////////////////////////////////////////////*/

    function test_lockSafeMode_revertsForNonRiskEngine(address caller) public {
        vm.assume(caller != address(riskEngine));

        vm.prank(caller);
        vm.expectRevert(Errors.NotGuardian.selector);
        pp.lockSafeMode();

        assertEq(_lockMode(), 0, "still unlocked");
    }

    function test_unlockSafeMode_revertsForNonRiskEngine(address caller) public {
        vm.prank(address(riskEngine));
        pp.lockSafeMode();
        vm.assume(caller != address(riskEngine));

        vm.prank(caller);
        vm.expectRevert(Errors.NotGuardian.selector);
        pp.unlockSafeMode();

        assertEq(_lockMode(), 3, "still locked");
    }

    function test_lockAndUnlockSafeMode_byRiskEngine() public {
        vm.startPrank(address(riskEngine));
        pp.lockSafeMode();
        assertEq(_lockMode(), 3, "locked");

        pp.unlockSafeMode();
        assertEq(_lockMode(), 0, "unlocked");
        vm.stopPrank();
    }

    function _lockMode() internal view returns (uint8) {
        (, , , , OraclePack oraclePack) = pp.getOracleTicks();
        return oraclePack.lockMode();
    }

    /*//////////////////////////////////////////////////////////////
                    dispatchFrom: INPUT LIST CHECKS
    //////////////////////////////////////////////////////////////*/

    function test_dispatchFrom_revertsWhenSameLengthListsDiffer() public {
        TokenId held = _mintShort(alice, 1 ether);
        // same length as alice's list, different content: neither a settle nor anything else
        TokenId other = TokenId.wrap(0).addPoolId(pp.poolId()).addLeg(0, 1, 0, 0, 0, 0, 2000, 2);

        vm.prank(bob);
        vm.expectRevert(Errors.InputListFail.selector);
        pp.dispatchFrom(
            new TokenId[](0),
            alice,
            _list(held),
            _list(other),
            LeftRightUnsigned.wrap(0)
        );

        assertEq(pp.numberOfLegs(alice), 1, "alice's position untouched");
    }

    function test_dispatchFrom_revertsWhenFinalListIsLonger() public {
        TokenId held = _mintShort(alice, 1 ether);
        // a final list longer than the current one matches no operation on a solvent account
        TokenId[] memory longer = new TokenId[](2);
        longer[0] = held;
        longer[1] = TokenId.wrap(0).addPoolId(pp.poolId()).addLeg(0, 1, 0, 0, 0, 0, 2000, 2);

        vm.prank(bob);
        vm.expectRevert(Errors.InputListFail.selector);
        pp.dispatchFrom(new TokenId[](0), alice, _list(held), longer, LeftRightUnsigned.wrap(0));

        assertEq(pp.numberOfLegs(alice), 1, "alice's position untouched");
    }

    function test_dispatchFrom_revertsWhenFinalListDropsTwoPositions_andOnSolventLiquidation()
        public
    {
        // alice holds three positions; a final list two shorter is neither a force exercise (one shorter)
        // nor a liquidation attempt (empty)
        TokenId[] memory held = new TokenId[](3);
        for (uint256 i; i < 3; ++i) {
            held[i] = TokenId.wrap(0).addPoolId(pp.poolId()).addLeg(
                0,
                1,
                0,
                0,
                0,
                0,
                int24(int256(1000 + 100 * i)),
                2
            );
            TokenId[] memory soFar = new TokenId[](i + 1);
            for (uint256 j; j <= i; ++j) soFar[j] = held[j];
            vm.prank(alice);
            pp.dispatch(_list(held[i]), soFar, _sizes(1 ether), _limits(), false, 0);
        }

        vm.prank(bob);
        vm.expectRevert(Errors.InputListFail.selector);
        pp.dispatchFrom(new TokenId[](0), alice, held, _list(held[0]), LeftRightUnsigned.wrap(0));

        // an empty final list is a liquidation attempt, refused on a solvent account
        vm.prank(bob);
        vm.expectRevert(Errors.NotMarginCalled.selector);
        pp.dispatchFrom(new TokenId[](0), alice, held, new TokenId[](0), LeftRightUnsigned.wrap(0));

        assertEq(pp.numberOfLegs(alice), 3, "alice's positions untouched");
    }

    function test_dispatchFrom_emptyFinalListOnSinglePositionIsAForceExercise() public {
        // with one position, an empty final list is "one shorter": it is read as a force exercise, not a
        // liquidation, and a short-only position has nothing to exercise
        TokenId held = _mintShort(alice, 1 ether);

        vm.prank(bob);
        vm.expectRevert(Errors.NoLegsExercisable.selector);
        pp.dispatchFrom(
            new TokenId[](0),
            alice,
            _list(held),
            new TokenId[](0),
            LeftRightUnsigned.wrap(0)
        );
    }

    /*//////////////////////////////////////////////////////////////
                         ZERO-SIZE POSITIONS
    //////////////////////////////////////////////////////////////*/

    function test_dispatch_revertsOnZeroSizeMint() public {
        // a zero-size loan leg touches no liquidity, so only the ownership check stops it from being recorded
        TokenId loan = TokenId.wrap(0).addPoolId(pp.poolId()).addLeg(0, 1, 0, 0, 0, 0, 0, 0);

        vm.prank(alice);
        vm.expectRevert(Errors.PositionNotOwned.selector);
        pp.dispatch(_list(loan), _list(loan), _sizes(0), _limits(), false, 0);

        assertEq(pp.numberOfLegs(alice), 0, "nothing recorded");
    }
}
