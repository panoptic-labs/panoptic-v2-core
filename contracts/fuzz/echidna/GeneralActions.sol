// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "./FuzzHelpers.sol";

// (misc non-Panoptic-contract actions)
contract GeneralActions is FuzzHelpers {
    ////////////////////////////////////////////////////
    // General mint functions
    ////////////////////////////////////////////////////
    /// @dev Generate a single leg
    function _generate_single_leg_tokenid(
        bool asset_in,
        bool is_call_in,
        bool is_long_in,
        bool is_otm_in,
        bool is_atm,
        uint24 width_in,
        int256 strike_in
    ) internal returns (TokenId out) {
        out = TokenId.wrap(poolId);

        // Rest of the parameters come from the function parameters
        uint256 asset = asset_in == true ? 1 : 0;
        uint256 call_put = is_call_in == true ? 1 - asset : asset;
        uint256 long_short = is_long_in == true ? 1 : 0;

        int24 width;
        int24 strike;

        (, currentTick, , , , , ) = cyclingPool.slot0();

        if (is_atm) {
            (width, strike) = getATMSW(
                width_in,
                strike_in,
                uint24(poolTickSpacing),
                currentTick,
                call_put
            );
        } else if (is_otm_in) {
            (width, strike) = getOTMSW(
                width_in,
                strike_in,
                uint24(poolTickSpacing),
                currentTick,
                call_put
            );
        } else {
            (width, strike) = getITMSW(
                width_in,
                strike_in,
                uint24(poolTickSpacing),
                currentTick,
                call_put
            );
        }

        out = out.addLeg(0, 1, asset, long_short, call_put, 0, strike, width);
        log_tokenid_leg(out, 0);
    }

    function _generate_multiple_leg_tokenid(
        uint256 numLegs,
        bool[4] memory asset_in,
        bool[4] memory is_call_in,
        bool[4] memory is_long_in,
        bool[4] memory is_otm_in,
        bool[4] memory is_atm_in,
        uint24[4] memory width_in,
        int256[4] memory strike_in
    ) internal returns (TokenId out) {
        out = TokenId.wrap(poolId);

        (, currentTick, , , , , ) = cyclingPool.slot0();

        // The parameters come from the function parameters
        for (uint256 i = 0; i < numLegs; i++) {
            uint256 asset = asset_in[i] == true ? 1 : 0;
            uint256 call_put = is_call_in[i] == true ? 1 - asset : asset;
            uint256 long_short = is_long_in[i] == true ? 1 : 0;

            int24 width;
            int24 strike;

            if (is_atm_in[i]) {
                (width, strike) = getATMSW(
                    width_in[i],
                    strike_in[i],
                    uint24(poolTickSpacing),
                    currentTick,
                    call_put
                );
            } else if (is_otm_in[i]) {
                (width, strike) = getOTMSW(
                    width_in[i],
                    strike_in[i],
                    uint24(poolTickSpacing),
                    currentTick,
                    call_put
                );
            } else {
                (width, strike) = getITMSW(
                    width_in[i],
                    strike_in[i],
                    uint24(poolTickSpacing),
                    currentTick,
                    call_put
                );
            }

            out = out.addLeg(i, 1, asset, long_short, call_put, i, strike, width);
            log_tokenid_leg(out, i);
        }
    }

    /////////////////////////////////////////////////////////////
    // Imported functions
    /////////////////////////////////////////////////////////////

    function getContext(
        uint256 ts_,
        int24 _currentTick,
        int24 _width
    ) internal pure returns (int24 strikeOffset, int24 minTick, int24 maxTick) {
        int256 ts = int256(ts_);

        strikeOffset = int24(_width % 2 == 0 ? int256(0) : ts / 2);

        if (ts_ == 1) {
            minTick = int24(((_currentTick - 4096) / ts) * ts);
            maxTick = int24(((_currentTick + 4096) / ts) * ts);
        } else {
            minTick = int24(((_currentTick - 4096 * 10) / ts) * ts);
            maxTick = int24(((_currentTick + 4096 * 10) / ts) * ts);
        }
    }

    function getOTMSW(
        uint256 _widthSeed,
        int256 _strikeSeed,
        uint256 ts_,
        int24 _currentTick,
        uint256 _tokenType
    ) internal view returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        width = ts == 1
            ? width = int24(int256(bound(_widthSeed, 1, 1000)))
            : int24(int256(bound(_widthSeed, 1, (1000 * 10) / uint256(ts))));
        int24 oneSidedRange = int24((width * ts) / 2);

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        (int24 strikeOffset, int24 minTick, int24 maxTick) = getContext(ts_, _currentTick, width);

        int24 lowerBound = _tokenType == 0
            ? int24(_currentTick + ts + oneSidedRange - strikeOffset)
            : int24(minTick + oneSidedRange - strikeOffset);
        int24 upperBound = _tokenType == 0
            ? int24(maxTick - oneSidedRange - strikeOffset)
            : int24(_currentTick - oneSidedRange - strikeOffset);

        if (ts == 1) {
            lowerBound = _tokenType == 0
                ? int24(_currentTick + ts + rangeDown - strikeOffset)
                : int24(minTick + rangeDown - strikeOffset);
            upperBound = _tokenType == 0
                ? int24(maxTick - rangeUp - strikeOffset)
                : int24(_currentTick - rangeUp - strikeOffset);
        }

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(int256(bound(_strikeSeed, lowerBound / ts, upperBound / ts)));

        strike = int24(strike * ts + strikeOffset);
    }

    function getITMSW(
        uint256 _widthSeed,
        int256 _strikeSeed,
        uint256 ts_,
        int24 _currentTick,
        uint256 _tokenType
    ) internal view returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        width = ts == 1
            ? width = int24(int256(bound(_widthSeed, 1, 1000)))
            : int24(int256(bound(_widthSeed, 1, (1000 * 10) / uint256(ts))));
        int24 oneSidedRange = int24((width * ts) / 2);

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        (int24 strikeOffset, int24 minTick, int24 maxTick) = getContext(ts_, _currentTick, width);

        int24 lowerBound = _tokenType == 0
            ? int24(minTick + oneSidedRange - strikeOffset)
            : int24(_currentTick + oneSidedRange - strikeOffset);
        int24 upperBound = _tokenType == 0
            ? int24(_currentTick + ts - oneSidedRange - strikeOffset)
            : int24(maxTick - oneSidedRange - strikeOffset);

        if (ts == 1) {
            lowerBound = _tokenType == 0
                ? int24(minTick + rangeDown - strikeOffset)
                : int24(_currentTick + rangeDown - strikeOffset);
            upperBound = _tokenType == 0
                ? int24(_currentTick + ts - rangeUp - strikeOffset)
                : int24(maxTick - rangeUp - strikeOffset);
        }

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(bound(_strikeSeed, lowerBound / ts, upperBound / ts));

        strike = int24(strike * ts + strikeOffset);
    }

    function getATMSW(
        uint256 _widthSeed,
        int256 _strikeSeed,
        uint256 ts_,
        int24 _currentTick,
        uint256 _tokenType
    ) internal view returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        width = ts == 1
            ? width = int24(int256(bound(_widthSeed, 1, 1000)))
            : int24(int256(bound(_widthSeed, 1, (1000 * 10) / uint256(ts))));
        int24 oneSidedRange = int24((width * ts) / 2);

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        (int24 strikeOffset, int24 minTick, int24 maxTick) = getContext(ts_, _currentTick, width);

        int24 lowerBound = int24(_currentTick + ts - oneSidedRange - strikeOffset);
        int24 upperBound = int24(_currentTick + oneSidedRange - strikeOffset);

        if (ts == 1) {
            lowerBound = int24(_currentTick + rangeDown - strikeOffset);
            upperBound = int24(_currentTick + ts - rangeUp - strikeOffset);
        }

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(bound(_strikeSeed, lowerBound / ts, upperBound / ts));

        strike = int24(strike * ts + strikeOffset);
    }

    function getValidSW(
        uint256 _widthSeed,
        int256 _strikeSeed,
        uint256 ts_,
        int24 _currentTick
    ) internal view returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        width = ts == 1
            ? width = int24(int256(bound(_widthSeed, 1, 1000)))
            : int24(int256(bound(_widthSeed, 1, 1000)));

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        (int24 strikeOffset, int24 minTick, int24 maxTick) = getContext(ts_, _currentTick, width);

        int24 lowerBound = int24(minTick + rangeDown - strikeOffset);
        int24 upperBound = int24(maxTick - rangeUp - strikeOffset);

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(bound(_strikeSeed, lowerBound / ts, upperBound / ts));

        strike = int24(strike * ts + strikeOffset);
    }

    ////////////////////////////////////////////////////
    // Funds and pool manipulation
    ////////////////////////////////////////////////////

    /// @dev Mint currently active token0 and token1 to the sender and approve all the system contracts
    function fund_and_approve() public {
        deal_USDC(msg.sender, 10000000 ether);
        deal_WETH(msg.sender, 10000 ether);

        hevm.prank(msg.sender);
        IERC20(USDC).approve(address(router), type(uint256).max);
        hevm.prank(msg.sender);
        IERC20(WETH).approve(address(router), type(uint256).max);
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

    function perform_swap(uint160 target_sqrt_price) public {
        uint160 price;

        (price, , , , , , ) = cyclingPool.slot0();

        // bound the price between 10 and 500000 and 50% of the current price
        target_sqrt_price = uint160(
            bound(
                price,
                uint256(
                    Math.max(
                        int256(Math.mulDiv(price, 7_071, 10_000)),
                        112028621795169773357271145775104
                    )
                ),
                uint256(
                    Math.min(
                        int256(Math.mulDiv(price, 14_142, 10_000)),
                        25054084147398268684193622782902272
                    )
                )
            )
        );

        emit LogUint256("price before swap", uint256(price));

        hevm.prank(pool_manipulator);
        swapperc.swapTo(cyclingPool, target_sqrt_price);

        (price, , , , , , ) = cyclingPool.slot0();
        emit LogUint256("price after swap", uint256(price));
    }
}
