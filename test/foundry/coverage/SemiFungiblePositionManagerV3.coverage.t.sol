// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Errors} from "@libraries/Errors.sol";
import {SemiFungiblePositionManagerV3} from "@contracts/SemiFungiblePositionManagerV3.sol";
import {TokenId} from "@types/TokenId.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";

/// @notice Fills the coverage gaps left in `contracts/SemiFungiblePositionManagerV3.sol` by the rest of the suite:
/// - `expandEnforcedTickRange` on an unknown pool
/// - the `PriceBoundFail` check at the end of `burnTokenizedPosition`
/// - the disabled ERC1155 transfer entry points
/// @dev Runs against the pinned mainnet fork, like the main SFPM suite.
/// @dev Not covered: the `swapAmount == 0` early return in `swapInAMM`. Its only caller requires a non-zero
/// `itmAmounts`, and every arm then sets `swapAmount` to the negation of a non-zero slot.
contract SemiFungiblePositionManagerV3CoverageTest is Test {
    IUniswapV3Factory internal constant V3FACTORY =
        IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    IUniswapV3Pool internal constant USDC_WETH_5 =
        IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);

    uint8 internal constant VEGOID = 8;
    // 0.01 WETH: the position is sized in token1 (WETH) of the USDC/WETH pool
    uint128 internal constant POSITION_SIZE = 10 ** 16;

    SemiFungiblePositionManagerV3 internal sfpm;

    address internal alice;
    address internal token0;
    address internal token1;
    int24 internal tickSpacing;
    int24 internal currentTick;
    uint64 internal poolId;
    bytes internal poolKey;

    function setUp() public {
        sfpm = new SemiFungiblePositionManagerV3(V3FACTORY, 10 ** 13, 0);

        token0 = USDC_WETH_5.token0();
        token1 = USDC_WETH_5.token1();
        tickSpacing = USDC_WETH_5.tickSpacing();
        (, currentTick, , , , , ) = USDC_WETH_5.slot0();
        poolKey = abi.encode(address(USDC_WETH_5));

        poolId = sfpm.initializeAMMPool(token0, token1, USDC_WETH_5.fee(), VEGOID);

        alice = makeAddr("alice");
        deal(token0, alice, type(uint104).max);
        deal(token1, alice, type(uint104).max);
        vm.startPrank(alice);
        IERC20Partial(token0).approve(address(sfpm), type(uint256).max);
        IERC20Partial(token1).approve(address(sfpm), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev A one-leg short position in a two-tick-spacing chunk well above the current price.
    function _outOfRangeTokenId() internal view returns (TokenId) {
        int24 strike = ((currentTick / tickSpacing) + 100) * tickSpacing;
        return TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, strike, 2);
    }

    function _mint(TokenId tokenId) internal {
        vm.prank(alice);
        sfpm.mintTokenizedPosition(
            poolKey,
            tokenId,
            POSITION_SIZE,
            type(int24).min,
            type(int24).max
        );
    }

    /*//////////////////////////////////////////////////////////////
                        expandEnforcedTickRange
    //////////////////////////////////////////////////////////////*/

    function test_expandEnforcedTickRange_revertsForUnknownPool(uint64 unknownPoolId) public {
        vm.assume(unknownPoolId != poolId);

        vm.expectRevert(Errors.PoolNotInitialized.selector);
        sfpm.expandEnforcedTickRange(unknownPoolId);
    }

    function test_expandEnforcedTickRange_knownPoolDoesNotNarrow() public {
        (int24 min0, int24 max0) = sfpm.getEnforcedTickLimits(poolId);

        sfpm.expandEnforcedTickRange(poolId);

        (int24 min1, int24 max1) = sfpm.getEnforcedTickLimits(poolId);
        assertLe(min1, min0, "min not narrowed");
        assertGe(max1, max0, "max not narrowed");
        assertEq(sfpm.getPoolId(poolKey, VEGOID), poolId, "pool id intact");
    }

    /*//////////////////////////////////////////////////////////////
                     burnTokenizedPosition PRICE BOUND
    //////////////////////////////////////////////////////////////*/

    function test_burn_revertsWhenTickAtOrAboveUpperLimit(int24 tickLimitHigh) public {
        TokenId tokenId = _outOfRangeTokenId();
        _mint(tokenId);

        // the interval is open: a limit equal to the current tick already fails
        tickLimitHigh = int24(bound(tickLimitHigh, type(int24).min + 1, currentTick));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.PriceBoundFail.selector, currentTick));
        sfpm.burnTokenizedPosition(poolKey, tokenId, POSITION_SIZE, type(int24).min, tickLimitHigh);

        assertEq(sfpm.balanceOf(alice, TokenId.unwrap(tokenId)), POSITION_SIZE, "burn rolled back");
    }

    function test_burn_revertsWhenTickAtOrBelowLowerLimit(int24 tickLimitLow) public {
        TokenId tokenId = _outOfRangeTokenId();
        _mint(tokenId);

        tickLimitLow = int24(bound(tickLimitLow, currentTick, type(int24).max - 1));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.PriceBoundFail.selector, currentTick));
        sfpm.burnTokenizedPosition(poolKey, tokenId, POSITION_SIZE, tickLimitLow, type(int24).max);

        assertEq(sfpm.balanceOf(alice, TokenId.unwrap(tokenId)), POSITION_SIZE, "burn rolled back");
    }

    function test_burn_succeedsWhenTickStrictlyInsideLimits() public {
        TokenId tokenId = _outOfRangeTokenId();
        _mint(tokenId);

        vm.prank(alice);
        (, , int24 tickAfter) = sfpm.burnTokenizedPosition(
            poolKey,
            tokenId,
            POSITION_SIZE,
            currentTick - 1,
            currentTick + 1
        );

        assertEq(tickAfter, currentTick, "out-of-range burn does not move the price");
        assertEq(sfpm.balanceOf(alice, TokenId.unwrap(tokenId)), 0, "burnt");
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

    function test_safeTransferFrom_revertsForHolderOfRealPosition() public {
        TokenId tokenId = _outOfRangeTokenId();
        _mint(tokenId);
        address bob = makeAddr("bob");

        vm.prank(alice);
        vm.expectRevert(bytes(""));
        sfpm.safeTransferFrom(alice, bob, TokenId.unwrap(tokenId), POSITION_SIZE, "");

        assertEq(sfpm.balanceOf(alice, TokenId.unwrap(tokenId)), POSITION_SIZE, "alice keeps it");
        assertEq(sfpm.balanceOf(bob, TokenId.unwrap(tokenId)), 0, "bob gets nothing");
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

    function test_safeBatchTransferFrom_revertsForHolderOfRealPosition() public {
        TokenId tokenId = _outOfRangeTokenId();
        _mint(tokenId);

        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = TokenId.unwrap(tokenId);
        amounts[0] = POSITION_SIZE;

        vm.prank(alice);
        vm.expectRevert(bytes(""));
        sfpm.safeBatchTransferFrom(alice, makeAddr("bob"), ids, amounts, "");

        assertEq(sfpm.balanceOf(alice, ids[0]), POSITION_SIZE, "alice keeps it");
    }
}
