// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "./FuzzHelpers.sol";

// (misc non-Panoptic-contract actions)
contract GeneralActions is FuzzHelpers {
    ////////////////////////////////////////////////////
    // Funds and pool manipulation
    ////////////////////////////////////////////////////

    /// @dev Mint USDC and WETH to the sender and approve all the system contracts
    function fund_and_approve() public {
        deal_USDC(msg.sender, 10000000 ether);
        deal_WETH(msg.sender, 10000 ether);

        hevm.prank(msg.sender);
        IERC20(USDC).approve(address(panopticPool), type(uint256).max);
        hevm.prank(msg.sender);
        IERC20(WETH).approve(address(panopticPool), type(uint256).max);
        hevm.prank(msg.sender);
        IERC20(USDC).approve(address(collToken0), type(uint256).max);
        hevm.prank(msg.sender);
        IERC20(WETH).approve(address(collToken1), type(uint256).max);

        hevm.prank(msg.sender);
        IERC20(USDC).approve(address(sfpm), type(uint256).max);
        hevm.prank(msg.sender);
        IERC20(WETH).approve(address(sfpm), type(uint256).max);
    }

    /// cycling pool
    /// for all general and sfpm actions cycle the underlying uniswap pool being interacted on
    function cyclePool(IUniswapV3Pool pool) external {
        cyclingPool = pool;
        sfpmPoolId = sfpm.getPoolId(address(cyclingPool));
    }

    function perform_swap(uint160 target_sqrt_price) public {
        uint160 price;

        (price, , , , , , ) = cyclingPool.slot0();

        // bound the price within 50% of the current price
        target_sqrt_price = uint160(
            bound(price, Math.mulDiv(price, 7_071, 10_000), Math.mulDiv(price, 14_142, 10_000))
        );

        emit LogUint256("price before swap", uint256(price));

        hevm.prank(pool_manipulator);
        swapperc.swapTo(cyclingPool, target_sqrt_price);

        (price, , , , , , ) = cyclingPool.slot0();
        emit LogUint256("price after swap", uint256(price));
    }
}
