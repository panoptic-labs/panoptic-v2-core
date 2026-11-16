// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Errors} from "@libraries/Errors.sol";
import {SemiFungiblePositionManagerV4} from "@contracts/SemiFungiblePositionManagerV4.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/// @dev Only `totalSupply` matters to the enforced-tick computation.
contract SupplyToken {
    uint256 public totalSupply;

    function setTotalSupply(uint256 supply) external {
        totalSupply = supply;
    }
}

/// @notice Fills the coverage gaps left in `contracts/SemiFungiblePositionManagerV4.sol` by the rest of the suite:
/// - `expandEnforcedTickRange` on an unknown pool, and on both native and ERC20 `currency0`
/// - `unlockCallback` called by anyone other than the PoolManager
/// - the disabled ERC1155 transfer entry points
/// @dev Not covered: the `swapAmount == 0` early return in `swapInAMM`. Its only caller requires a non-zero
/// `itmAmounts`, and every arm then sets `swapAmount` to a slot that is non-zero in that arm.
contract SemiFungiblePositionManagerV4CoverageTest is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 2 ** 96;

    uint256 internal constant MIN_COST = 10 ** 13;
    uint256 internal constant NATIVE_COST = 10 ** 15;
    // 1% of the token supply
    uint256 internal constant SUPPLY_MULTIPLIER = 100;

    uint8 internal constant VEGOID = 4;

    PoolManager internal manager;
    SemiFungiblePositionManagerV4 internal sfpm;

    SupplyToken internal tokenA;
    SupplyToken internal tokenB;

    function setUp() public {
        manager = new PoolManager(address(0));
        sfpm = new SemiFungiblePositionManagerV4(
            IPoolManager(address(manager)),
            MIN_COST,
            NATIVE_COST,
            SUPPLY_MULTIPLIER
        );

        SupplyToken t0 = new SupplyToken();
        SupplyToken t1 = new SupplyToken();
        (tokenA, tokenB) = address(t0) < address(t1) ? (t0, t1) : (t1, t0);
    }

    function _key(address currency0, address currency1) internal pure returns (PoolKey memory) {
        return
            PoolKey(
                Currency.wrap(currency0),
                Currency.wrap(currency1),
                500,
                10,
                IHooks(address(0))
            );
    }

    function _init(PoolKey memory key) internal returns (uint64 poolId) {
        manager.initialize(key, SQRT_PRICE_1_1);
        poolId = sfpm.initializeAMMPool(key, VEGOID);
    }

    /*//////////////////////////////////////////////////////////////
                        expandEnforcedTickRange
    //////////////////////////////////////////////////////////////*/

    function test_expandEnforcedTickRange_revertsForUnknownPool(uint64 poolId) public {
        vm.expectRevert(Errors.PoolNotInitialized.selector);
        sfpm.expandEnforcedTickRange(poolId);
    }

    function test_expandEnforcedTickRange_revertsForOtherVegoidOfKnownPool() public {
        tokenA.setTotalSupply(1e30);
        tokenB.setTotalSupply(1e30);
        uint64 poolId = _init(_key(address(tokenA), address(tokenB)));

        // same pool, a vegoid that was never initialized
        uint64 otherVegoid = poolId ^ (uint64(VEGOID ^ (VEGOID + 1)) << 40);

        vm.expectRevert(Errors.PoolNotInitialized.selector);
        sfpm.expandEnforcedTickRange(otherVegoid);
    }

    function test_expandEnforcedTickRange_erc20Pool_widensWhenSupplyDrops() public {
        // a large supply at initialization pins the pool to a narrow range. Supplies are kept below the point
        // where 1% of the supply exceeds one tick's worth of max liquidity, past which the range is unrestricted.
        tokenA.setTotalSupply(1e30);
        tokenB.setTotalSupply(1e30);
        uint64 poolId = _init(_key(address(tokenA), address(tokenB)));
        (int24 min0, int24 max0) = sfpm.getEnforcedTickLimits(poolId);

        // unchanged supply: nothing moves
        sfpm.expandEnforcedTickRange(poolId);
        (int24 min1, int24 max1) = sfpm.getEnforcedTickLimits(poolId);
        assertEq(min1, min0, "min unchanged at equal supply");
        assertEq(max1, max0, "max unchanged at equal supply");

        // token1 supply collapses: only the lower limit widens
        tokenB.setTotalSupply(1e20);
        sfpm.expandEnforcedTickRange(poolId);
        (int24 min2, int24 max2) = sfpm.getEnforcedTickLimits(poolId);
        assertLt(min2, min1, "min widened by the token1 supply drop");
        assertEq(max2, max1, "max untouched by token1");

        // token0 supply collapses: only the upper limit widens
        tokenA.setTotalSupply(1e20);
        sfpm.expandEnforcedTickRange(poolId);
        (int24 min3, int24 max3) = sfpm.getEnforcedTickLimits(poolId);
        assertEq(min3, min2, "min untouched by token0");
        assertGt(max3, max2, "max widened by the token0 supply drop");

        // equal supplies give a symmetric range
        assertEq(min3, -max3, "symmetric");
    }

    function test_expandEnforcedTickRange_erc20Pool_neverNarrows() public {
        tokenA.setTotalSupply(1e20);
        tokenB.setTotalSupply(1e20);
        uint64 poolId = _init(_key(address(tokenA), address(tokenB)));
        (int24 min0, int24 max0) = sfpm.getEnforcedTickLimits(poolId);

        // supply grows by many orders of magnitude: the stored limits must hold
        tokenA.setTotalSupply(1e30);
        tokenB.setTotalSupply(1e30);
        sfpm.expandEnforcedTickRange(poolId);

        (int24 min1, int24 max1) = sfpm.getEnforcedTickLimits(poolId);
        assertEq(min1, min0, "min not narrowed");
        assertEq(max1, max0, "max not narrowed");
    }

    function test_expandEnforcedTickRange_erc20Pool_floorsAtMinCost() public {
        // 1% of the supply is below MIN_COST on both sides, so the floor decides the range
        tokenA.setTotalSupply(MIN_COST);
        tokenB.setTotalSupply(MIN_COST);
        uint64 poolId = _init(_key(address(tokenA), address(tokenB)));
        (int24 min0, int24 max0) = sfpm.getEnforcedTickLimits(poolId);

        tokenA.setTotalSupply(0);
        tokenB.setTotalSupply(0);
        sfpm.expandEnforcedTickRange(poolId);

        (int24 min1, int24 max1) = sfpm.getEnforcedTickLimits(poolId);
        assertEq(min1, min0, "min already at the floor");
        assertEq(max1, max0, "max already at the floor");
    }

    function test_expandEnforcedTickRange_nativePool_upperLimitIgnoresSupply() public {
        tokenB.setTotalSupply(1e30);
        uint64 poolId = _init(_key(address(0), address(tokenB)));
        (int24 min0, int24 max0) = sfpm.getEnforcedTickLimits(poolId);

        // the native side uses a fixed cost, so the upper limit is not tied to any supply
        tokenB.setTotalSupply(1e20);
        sfpm.expandEnforcedTickRange(poolId);

        (int24 min1, int24 max1) = sfpm.getEnforcedTickLimits(poolId);
        assertLt(min1, min0, "min widened by the token1 supply drop");
        assertEq(max1, max0, "max fixed by the native cost");
    }

    function test_expandEnforcedTickRange_nativePool_matchesErc20PoolAtSameCost() public {
        // an ERC20 currency0 whose 1% of supply equals NATIVE_COST must give the same upper limit
        tokenA.setTotalSupply(NATIVE_COST * 100);
        tokenB.setTotalSupply(1e30);
        uint64 erc20Pool = _init(_key(address(tokenA), address(tokenB)));
        uint64 nativePool = _init(_key(address(0), address(tokenB)));

        sfpm.expandEnforcedTickRange(erc20Pool);
        sfpm.expandEnforcedTickRange(nativePool);

        (int24 minErc20, int24 maxErc20) = sfpm.getEnforcedTickLimits(erc20Pool);
        (int24 minNative, int24 maxNative) = sfpm.getEnforcedTickLimits(nativePool);
        assertEq(maxNative, maxErc20, "same cost, same upper limit");
        assertEq(minNative, minErc20, "same token1, same lower limit");
    }

    function test_expandEnforcedTickRange_keepsOtherPoolDataIntact() public {
        tokenA.setTotalSupply(1e30);
        tokenB.setTotalSupply(1e30);
        PoolKey memory key = _key(address(tokenA), address(tokenB));
        uint64 poolId = _init(key);

        tokenA.setTotalSupply(1e20);
        tokenB.setTotalSupply(1e20);
        sfpm.expandEnforcedTickRange(poolId);

        // still registered under the same id, and still initialized: a second init is a no-op returning that id
        assertEq(sfpm.getPoolId(abi.encode(key.toId()), VEGOID), poolId, "pool id");
        (int24 minBefore, int24 maxBefore) = sfpm.getEnforcedTickLimits(poolId);
        assertEq(sfpm.initializeAMMPool(key, VEGOID), poolId, "re-init returns the same id");
        (int24 minAfter, int24 maxAfter) = sfpm.getEnforcedTickLimits(poolId);
        assertEq(minAfter, minBefore, "re-init leaves min");
        assertEq(maxAfter, maxBefore, "re-init leaves max");
    }

    /*//////////////////////////////////////////////////////////////
                             unlockCallback
    //////////////////////////////////////////////////////////////*/

    function test_unlockCallback_revertsForNonPoolManager(
        address caller,
        bytes memory data
    ) public {
        vm.assume(caller != address(manager));

        vm.prank(caller);
        vm.expectRevert(Errors.UnauthorizedUniswapCallback.selector);
        sfpm.unlockCallback(data);
    }

    /*//////////////////////////////////////////////////////////////
                         DISABLED ERC1155 TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function test_safeTransferFrom_alwaysReverts(
        address caller,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) public {
        vm.prank(caller);
        vm.expectRevert(bytes(""));
        sfpm.safeTransferFrom(from, to, id, amount, data);
    }

    function test_safeTransferFrom_revertsEvenForOwnerAndApprovedOperator() public {
        address owner = makeAddr("owner");
        address operator = makeAddr("operator");
        vm.prank(owner);
        sfpm.setApprovalForAll(operator, true);

        vm.prank(owner);
        vm.expectRevert(bytes(""));
        sfpm.safeTransferFrom(owner, operator, 1, 0, "");

        vm.prank(operator);
        vm.expectRevert(bytes(""));
        sfpm.safeTransferFrom(owner, operator, 1, 0, "");
    }

    function test_safeBatchTransferFrom_alwaysReverts(
        address caller,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) public {
        vm.prank(caller);
        vm.expectRevert(bytes(""));
        sfpm.safeBatchTransferFrom(from, to, ids, amounts, data);
    }

    function test_safeBatchTransferFrom_revertsOnEmptyBatch() public {
        // not even a no-op batch goes through
        vm.expectRevert(bytes(""));
        sfpm.safeBatchTransferFrom(
            address(this),
            address(this),
            new uint256[](0),
            new uint256[](0),
            ""
        );
    }
}
