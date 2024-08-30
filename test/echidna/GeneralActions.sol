// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "./FuzzHelpers.sol";

// (misc non-Panoptic-contract actions)
contract GeneralActions is FuzzHelpers {
    modifier canonicalTimeState() {
        hevm.warp(canonicalTimestamp);
        hevm.roll(canonicalBlock);
        _;
    }

    function impulseCanonicalTime(uint256 blockSeed, uint256 timeSeed) public canonicalTimeState {
        canonicalTimestamp += bound(timeSeed, 1, 6000);
        canonicalBlock += Math.min(bound(blockSeed, 1, 600), canonicalTimestamp);
    }

    ////////////////////////////////////////////////////
    // Funds and pool manipulation
    ////////////////////////////////////////////////////

    /// @dev Mint USDC and WETH to the sender and approve all the system contracts
    function fund_and_approve() public canonicalTimeState {
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
    function cyclePool(uint256 pool_idx) external canonicalTimeState {
        //cyclingPool = pools[bound(pool_idx, 0, pools.length - 1)];
        cyclingPool = pools[3];
        sfpmPoolId = sfpm.getPoolId(address(cyclingPool));
        sfpmTickSpacing = cyclingPool.tickSpacing();
    }

    function perform_swap(uint256 target_sqrt_price) public canonicalTimeState {
        (currentSqrtPriceX96, , , , , , ) = cyclingPool.slot0();

        // bound the price within 50% of the current price
        target_sqrt_price = boundLog(
            target_sqrt_price,
            Math.getSqrtRatioAtTick(TickMath.MIN_TICK + 2),
            Math.getSqrtRatioAtTick(TickMath.MAX_TICK - 2)
        );

        emit LogUint256("price before swap", currentSqrtPriceX96);

        hevm.prank(pool_manipulator);
        swapperc.swapTo(cyclingPool, uint160(target_sqrt_price));

        (currentSqrtPriceX96, , , , , , ) = cyclingPool.slot0();
        emit LogUint256("price after swap", currentSqrtPriceX96);
    }

    function perform_swap_and_align_prices(uint256 target_sqrt_price) public canonicalTimeState {
        (currentSqrtPriceX96, , , , , , ) = cyclingPool.slot0();

        // bound the price within 50% of the current price
        target_sqrt_price = boundLog(
            target_sqrt_price,
            Math.getSqrtRatioAtTick(TickMath.MIN_TICK + 2),
            Math.getSqrtRatioAtTick(TickMath.MAX_TICK - 2)
        );

        emit LogUint256("price before swap", currentSqrtPriceX96);

        hevm.prank(pool_manipulator);
        swapperc.swapTo(cyclingPool, uint160(target_sqrt_price));

        (currentSqrtPriceX96, , , , , , ) = cyclingPool.slot0();
        emit LogUint256("price after swap", currentSqrtPriceX96);

        // align TWAP and fast oracle prices
        for (uint256 i; i < 10; i++) {
            canonicalBlock += 1;
            canonicalTimestamp += 600;

            hevm.warp(canonicalTimestamp);
            hevm.roll(canonicalBlock);
            int24 _ts = cyclingPool.tickSpacing();

            hevm.prank(pool_manipulator);
            swapperc.mint(
                cyclingPool,
                (TickMath.MIN_TICK / _ts) * _ts,
                (TickMath.MAX_TICK / _ts) * _ts,
                1
            );
            hevm.prank(pool_manipulator);
            swapperc.burn(
                cyclingPool,
                (TickMath.MIN_TICK / _ts) * _ts,
                (TickMath.MAX_TICK / _ts) * _ts,
                1
            );
            if (i > 1) panopticPool.pokeMedian();
        }
    }
}
