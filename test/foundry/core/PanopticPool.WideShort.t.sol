// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PanopticPoolTest} from "./PanopticPool.t.sol";
import {Constants} from "@libraries/Constants.sol";
import {Errors} from "@libraries/Errors.sol";
import {Math} from "@libraries/Math.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {TokenId} from "@types/TokenId.sol";

/// @notice A wide in-range short leg must be backed by the seller's own collateral, in the leg's token.
contract PanopticPoolWideShortTest is PanopticPoolTest {
    TokenId internal $id;
    TokenId[] internal $list;
    uint128 internal $size;
    uint256 internal $T;
    uint256 internal $moved1;

    function _limits() internal pure returns (int24[3][] memory limits) {
        limits = new int24[3][](1);
        limits[0][0] = Constants.MIN_POOL_TICK;
        limits[0][1] = Constants.MAX_POOL_TICK;
        limits[0][2] = int24(uint24(type(uint24).max / 2));
    }

    function _buildWideShort() internal {
        _buildWideShort(85);
    }

    /// @param utilPct target post-mint utilization in percent, sets the sell ratio c
    function _buildWideShort(uint256 utilPct) internal {
        (int24 minT, int24 maxT) = sfpm.getEnforcedTickLimits(poolId);
        int24 width = 4094;
        int24 half = (width * tickSpacing) / 2;
        // put spot ~20% of the way up from the lower edge: strike = spot + 0.3 * half
        int24 strike = ((currentTick + (3 * half) / 10) / tickSpacing) * tickSpacing;
        require(strike - half >= minT && strike + half <= maxT, "range outside enforced ticks");
        console2.log("currentTick", int256(currentTick));
        console2.log("strike", int256(strike));
        console2.log("enforced min", int256(minT));
        console2.log("enforced max", int256(maxT));
        console2.log("tickSpacing", int256(tickSpacing));
        console2.log("width (x tickSpacing)", int256(width));

        (, uint256 inAMM0, , ) = ct0.getPoolData();
        $T = ct0.totalAssets();
        // post-mint utilization ~85% => c ~ 83%
        $size = uint128((utilPct * $T - 100 * inAMM0) / (100 - utilPct));
        console2.log("vault token0 totalAssets", $T);
        console2.log("short notional A", uint256($size));

        $id = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        $list.push($id);

        LiquidityChunk chunk = PanopticMath.getLiquidityChunk($id, 0, $size);
        (uint256 moved0, uint256 moved1) = Math.getAmountsForLiquidity(currentTick, chunk);
        $moved1 = moved1;
        console2.log("moved0 (token0 into AMM)", moved0);
        console2.log("moved1 (token1 paid by seller)", moved1);
    }

    /// @dev 0.3% pool (tickSpacing 60) so the max width reaches ~245k ticks; modest PLP deposits so the
    /// seller's token1 leg stays within the deposit cap.
    function _initWorld30() internal {
        _cacheWorldState(USDC_WETH_30);
        _deployPanopticPool();

        vm.startPrank(Seller);
        deal(token0, Seller, 1e13);
        deal(token1, Seller, 1e22);
        IERC20Partial(token0).approve(address(ct0), type(uint256).max);
        IERC20Partial(token1).approve(address(ct1), type(uint256).max);
        ct0.deposit(1e13, Seller); // 10M USDC
        ct1.deposit(1e22, Seller); // 10k WETH
        vm.stopPrank();
    }

    /// @notice A seller holding only token1 cannot mint a wide token0 short that is in range: the notional credited
    /// at mint does not cover the buffered requirement, so the dispatch reverts with AccountInsolvent.
    function test_Fail_wideShort_cannotMintWithoutCollateral() public {
        _initWorld30();
        _buildWideShort();

        vm.startPrank(Alice);
        deal(token1, Alice, $moved1 * 2 + 1e18);
        IERC20Partial(token1).approve(address(ct1), type(uint256).max);
        ct1.deposit($moved1 * 2 + 1e18, Alice);

        uint128[] memory sizes = new uint128[](1);
        sizes[0] = $size;
        vm.expectRevert(abi.encodeWithSelector(Errors.AccountInsolvent.selector, 0, 1));
        pp.dispatch($list, $list, sizes, _limits(), true, 0);
        vm.stopPrank();

        assertEq(ct0.balanceOf(Alice), 0, "no token0 credited");
    }

    /// @notice Positive path: a seller who posts their own collateral can mint the same wide leg, can withdraw no
    /// more than that collateral, and can still close the leg after withdrawing the maximum.
    function test_wideShort_withdrawBoundedByOwnCollateral_andClosable() public {
        _initWorld30();

        // seller's own token0 collateral, deposited before sizing so utilization sees it
        uint256 own = 4e12; // 4M USDC against a ~10M USDC vault
        vm.startPrank(Alice);
        deal(token0, Alice, own);
        IERC20Partial(token0).approve(address(ct0), type(uint256).max);
        ct0.deposit(own, Alice);
        vm.stopPrank();

        _buildWideShort(70); // c ~ 31%; notional ~2.3x the vault

        vm.startPrank(Alice);
        deal(token1, Alice, $moved1 * 2 + 1e18);
        IERC20Partial(token1).approve(address(ct1), type(uint256).max);
        ct1.deposit($moved1 * 2 + 1e18, Alice);

        uint128[] memory sizes = new uint128[](1);
        sizes[0] = $size;
        pp.dispatch($list, $list, sizes, _limits(), true, 0);
        pp.wipePriceSlot();

        // max the engine lets this account withdraw
        (, , , LeftRightUnsigned[] memory reqs, ) = pp.getFullPositionsData(Alice, false, $list);
        uint256 locked = Math.mulDivRoundingUp(reqs[0].rightSlot(), 10_666_667, 10_000_000);
        uint256 bal = ct0.convertToAssets(ct0.balanceOf(Alice));
        uint256 allowed = bal > locked ? bal - locked - 1 : 0;
        console2.log("own token0 deposit", own);
        console2.log("withdrawable per engine", allowed);
        assertLe(allowed, own, "seller could withdraw more than their own capital");

        if (allowed > 0) ct0.withdraw(allowed, Alice, Alice, $list, true);

        // the leg can still be closed from what is left
        burnOptions(
            pp,
            $id,
            new TokenId[](0),
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );
        assertEq(pp.numberOfLegs(Alice), 0, "leg closed");
        vm.stopPrank();
    }
}
