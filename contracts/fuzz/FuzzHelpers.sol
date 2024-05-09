// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {ISwapRouter} from "v3-periphery/interfaces/ISwapRouter.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PropertiesAsserts} from "./PropertiesHelper.sol";
import {IUniDeployer} from "./fuzz-mocks/IUniDeployer.sol";
import {IUniSwapRouterDeployer} from "./fuzz-mocks/IUniSwapRouterDeployer.sol";
import {WETH9} from "./fuzz-mocks/WETH9.sol";

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {IDonorNFT} from "@tokens/interfaces/IDonorNFT.sol";
import {DonorNFT} from "@periphery/DonorNFT.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {PanopticHelper} from "@periphery/PanopticHelper.sol";
import {IUniswapV3Factory} from "univ3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {TokenId} from "@types/TokenId.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {LiquidityAmounts} from "v3-periphery/libraries/LiquidityAmounts.sol";
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v3-core/libraries/SqrtPriceMath.sol";
import {FullMath} from "v3-core/libraries/FullMath.sol";
import {CallbackLib} from "@libraries/CallbackLib.sol";
import {FeesCalc} from "@libraries/FeesCalc.sol";
import {Math} from "@libraries/Math.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";

interface IHevm {
    function warp(uint256 newTimestamp) external;

    function roll(uint256 newNumber) external;

    function load(address where, bytes32 slot) external returns (bytes32);

    function store(address where, bytes32 slot, bytes32 value) external;

    function sign(
        uint256 privateKey,
        bytes32 digest
    ) external returns (uint8 r, bytes32 v, bytes32 s);

    function addr(uint256 privateKey) external returns (address add);

    function ffi(string[] calldata inputs) external returns (bytes memory result);

    function prank(address newSender) external;

    function createFork(string calldata urlOrAlias) external returns (uint256);

    function selectFork(uint256 forkId) external;

    function activeFork() external returns (uint256);

    function label(address addr, string calldata label) external;
}

// Copy of test/foundry/core/Misc.t.sol:SwapperC
contract SwapperC {
    event LogUint256(string, uint256);

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        // Decode the swap callback data, checks that the UniswapV3Pool has the correct address.
        CallbackLib.CallbackData memory decoded = abi.decode(data, (CallbackLib.CallbackData));

        // Extract the address of the token to be sent (amount0 -> token0, amount1 -> token1)
        address token = amount0Delta > 0
            ? address(decoded.poolFeatures.token0)
            : address(decoded.poolFeatures.token1);

        // Transform the amount to pay to uint256 (take positive one from amount0 and amount1)
        // the pool will always pass one delta with a positive sign and one with a negative sign or zero,
        // so this logic always picks the correct delta to pay
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);

        // Pay the required token from the payer to the caller of this contract
        SafeTransferLib.safeTransferFrom(token, decoded.payer, msg.sender, amountToPay);
    }

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        // Decode the mint callback data
        CallbackLib.CallbackData memory decoded = abi.decode(data, (CallbackLib.CallbackData));

        // Sends the amount0Owed and amount1Owed quantities provided
        if (amount0Owed > 0)
            SafeTransferLib.safeTransferFrom(
                decoded.poolFeatures.token0,
                decoded.payer,
                msg.sender,
                amount0Owed
            );
        if (amount1Owed > 0)
            SafeTransferLib.safeTransferFrom(
                decoded.poolFeatures.token1,
                decoded.payer,
                msg.sender,
                amount1Owed
            );
    }

    function mint(IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) public {
        pool.mint(
            address(this),
            tickLower,
            tickUpper,
            liquidity,
            abi.encode(
                CallbackLib.CallbackData({
                    poolFeatures: CallbackLib.PoolFeatures({
                        token0: pool.token0(),
                        token1: pool.token1(),
                        fee: pool.fee()
                    }),
                    payer: msg.sender
                })
            )
        );
    }

    function burn(IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) public {
        pool.burn(tickLower, tickUpper, liquidity);
    }

    function swapTo(IUniswapV3Pool pool, uint160 sqrtPriceX96) public {
        (uint160 sqrtPriceX96Before, , , , , , ) = pool.slot0();

        if (sqrtPriceX96Before == sqrtPriceX96) return;

        emit LogUint256("price before", sqrtPriceX96Before);
        emit LogUint256("price target", sqrtPriceX96);

        pool.swap(
            msg.sender,
            sqrtPriceX96Before > sqrtPriceX96 ? true : false,
            sqrtPriceX96Before > sqrtPriceX96
                ? int256(IERC20(pool.token0()).balanceOf(msg.sender))
                : int256(IERC20(pool.token1()).balanceOf(msg.sender)),
            sqrtPriceX96,
            abi.encode(
                CallbackLib.CallbackData({
                    poolFeatures: CallbackLib.PoolFeatures({
                        token0: pool.token0(),
                        token1: pool.token1(),
                        fee: pool.fee()
                    }),
                    payer: msg.sender
                })
            )
        );
    }
}

contract PanopticPoolWrapper is PanopticPool {
    /// @notice get the positions hash of an account
    /// @param user the account to get the positions hash of
    /// @return _positionsHash positions hash of the account
    function positionsHash(address user) external view returns (uint248 _positionsHash) {
        _positionsHash = uint248(s_positionsHash[user]);
    }

    function miniMedian() external view returns (uint256) {
        return s_miniMedian;
    }

    function settledTokens(bytes32 chunk) external view returns (LeftRightUnsigned) {
        return s_settledTokens[chunk];
    }

    function calculateAccumulatedPremia(
        address user,
        bool computeAllPremia,
        bool includePendingPremium,
        TokenId[] calldata positionIdList
    ) external view returns (int128 premium0, int128 premium1, uint256[2][] memory) {
        // Get the current tick of the Uniswap pool
        (, int24 currentTick, , , , , ) = s_univ3pool.slot0();

        // Compute the accumulated premia for all tokenId in positionIdList (includes short+long premium)
        (LeftRightSigned premia, uint256[2][] memory balances) = _calculateAccumulatedPremia(
            user,
            positionIdList,
            computeAllPremia,
            includePendingPremium,
            currentTick
        );

        // Return the premia as (token0, token1)
        return (premia.rightSlot(), premia.leftSlot(), balances);
    }

    // return premiaByLeg
    function burnAllOptionsFrom(
        TokenId[] calldata positionIdList,
        int24 tickLimitLow,
        int24 tickLimitHigh
    ) external returns (LeftRightSigned[4][] memory, LeftRightSigned) {
        (
            LeftRightSigned netExchanged,
            LeftRightSigned[4][] memory premiasByLeg
        ) = _burnAllOptionsFrom(
                msg.sender,
                tickLimitLow,
                tickLimitHigh,
                COMMIT_LONG_SETTLED,
                positionIdList
            );

        return (premiasByLeg, netExchanged);
    }

    constructor(SemiFungiblePositionManager _sfpm) PanopticPool(_sfpm) {}
}

contract FuzzHelpers is PropertiesAsserts {

    PanopticHelper panopticHelper;
    SemiFungiblePositionManager sfpm;
    IUniswapV3Factory univ3factory;
    address poolReference;
    address collateralReference;
    IDonorNFT dnft;
    PanopticFactory panopticFactory;
    PanopticPoolWrapper panopticPool;
    uint64 poolId;

    IUniswapV3Pool pool;
    uint24 poolFee;
    int24 poolTickSpacing;
    uint160 currentSqrtPriceX96;
    int24 currentTick;

    CollateralTracker collToken0;
    CollateralTracker collToken1;

    address[] actors;
    address pool_manipulator;

    SwapperC swapperc;

    mapping(address => TokenId[]) userPositions;

    mapping(address => mapping(TokenId => LeftRightUnsigned)) userBalance;

    uint256 constant MAX_DEPOSIT = 100 ether;
    uint256 constant MIN_DEPOSIT = 0.01 ether;


    IHevm hevm = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    //Testing uni deployment
    IUniDeployer deployer = IUniDeployer(address(0xde0001));

    IUniswapV3Pool USDC_WETH_5 = IUniswapV3Pool(deployer.pool());
    IERC20 USDC = IERC20(deployer.token0());
    IERC20 WETH = IERC20(deployer.token1());

    ISwapRouter router = ISwapRouter(IUniSwapRouterDeployer(address(0xde0002)).sr());

    function abs(int256 x) internal pure returns (uint256) {
        if (x >= 0) {
            return uint256(x);
        } else {
            return uint256(-x);
        }
    }

    function bound(uint256 value, uint256 min, uint256 max) internal pure returns (uint256) {
        uint256 range = max - min + 1;
        return min + (value % range);
    }

    function bound(int256 value, int256 min, int256 max) internal pure returns (int256) {
        int256 range = max - min + 1;
        return min + (value % range);
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return ( (a >= b) ? a :  b);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return ( (a <= b) ? a :  b);
    }

    function deal_USDC(address to, uint256 amt, bool alter_supply) internal {
        deployer.mintToken(false, to, amt);
    }

    function deal_WETH(address to, uint256 amt) internal {
        deployer.mintToken(true, to, amt);
    }

    function alter_USDC(address to, uint256 bal) internal {
        // Balances in slot 0
        uint256 slot_balances = uint256(0);
        hevm.store(address(USDC), keccak256(abi.encode(address(to), slot_balances)), bytes32(bal));

    }

    function alter_WETH(address to, uint256 bal) internal {
        // Balances in slot 3 (verify with "slither --print variable-order 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")
        hevm.store(address(WETH), keccak256(abi.encode(address(to), uint256(0))), bytes32(bal));
    }

    function deal_Generic(
        address token,
        uint256 slot,
        address to,
        uint256 amt,
        bool alter_supply,
        uint256 supply_slot
    ) internal {
        uint256 slot_balances = slot;
        uint256 original_balance = uint256(
            hevm.load(token, keccak256(abi.encode(address(to), slot_balances)))
        );
        int256 delta = int256(amt) - int256(original_balance);
        hevm.store(token, keccak256(abi.encode(address(to), slot_balances)), bytes32(amt));

        if (alter_supply) {
            bytes32 slot_supply = bytes32(supply_slot);
            uint256 orig_supply = uint256(hevm.load(token, slot_supply));
            uint256 new_supply = uint256(int256(orig_supply) + delta);
            hevm.store(token, slot_supply, bytes32(new_supply));
        }
    }

    function _get_account_margin(
        address to_liquidate,
        int24 tick
    ) internal view returns (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1) {
        require(userPositions[to_liquidate].length > 0);
        int128 premium0;
        int128 premium1;
        uint256[2][] memory positions;

        (premium0, premium1, positions) = panopticPool.calculateAccumulatedFeesBatch(
            to_liquidate,
            false,
            userPositions[to_liquidate]
        );
        tokenData0 = collToken0.getAccountMarginDetails(to_liquidate, tick, positions, premium0);
        tokenData1 = collToken1.getAccountMarginDetails(to_liquidate, tick, positions, premium1);
    }


    /////////////////////////////////////////////////////////////
    // Calculation helpers
    /////////////////////////////////////////////////////////////

    
    function _get_effective_liq_factor(
        uint256 legTokenType,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (uint64 effectiveLiquidityFactorX32) {
        LeftRightUnsigned accountLiquidities = sfpm.getAccountLiquidity(
            address(pool),
            address(panopticPool),
            legTokenType,
            tickLower,
            tickUpper
        );

        uint128 netLiquidity = accountLiquidities.rightSlot();
        uint128 totalLiquidity = accountLiquidities.leftSlot();
        // compute and return effective liquidity. Return if short=net=0, which is closing short position
        if (netLiquidity == 0) return 0;

        effectiveLiquidityFactorX32 = uint64((uint256(totalLiquidity) * 2 ** 32) / netLiquidity);
    }
    

    function _get_assets_in_token0(address who, int24 tick) internal view returns (uint256 assets) {
        assets =
            collToken0.convertToAssets(collToken0.balanceOf(who)) +
            PanopticMath.convert1to0(
                collToken1.convertToAssets(collToken1.balanceOf(who)),
                TickMath.getSqrtRatioAtTick(tick)
            );
    }

    function _get_assets_in_token1(address who, int24 tick) internal view returns (uint256 assets) {
        assets =
            collToken1.convertToAssets(collToken1.balanceOf(who)) +
            PanopticMath.convert0to1(
                collToken0.convertToAssets(collToken0.balanceOf(who)),
                TickMath.getSqrtRatioAtTick(tick)
            );
    }

    function _get_solvency_balances(
        address who,
        int24 tick
    ) internal view returns (uint256 balanceCross, uint256 thresholdCross) {
        (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1) = _get_account_margin(
            who,
            tick
        );
        uint160 sqrtPriceX96 = Math.getSqrtRatioAtTick(tick);
        unchecked {
            // the cross-collateral balance, computed in terms of liquidity X*√P + Y/√P
            // We use mulDiv to compute Y/√P + X*√P while correctly handling overflows, round down
            balanceCross =
                Math.mulDiv(uint256(tokenData1.rightSlot()), 2 ** 96, sqrtPriceX96) +
                Math.mulDiv96(tokenData0.rightSlot(), sqrtPriceX96);
            // the amount of cross-collateral balance needed for the account to be solvent, computed in terms of liquidity
            // overstimate by rounding up
            thresholdCross =
                Math.mulDivRoundingUp(uint256(tokenData1.leftSlot()), 2 ** 96, sqrtPriceX96) +
                Math.mulDiv96RoundingUp(tokenData0.leftSlot(), sqrtPriceX96);
        }
    }

    function _get_list_without_tokenid(TokenId[] memory list, TokenId target) internal pure returns (TokenId[] memory out) {
        // Assumes target is in list

        uint256 l = list.length;
        out = new TokenId[](l - 1);
        uint256 out_idx = 0;

        for (uint i = 0; i < l; i++) {
            if (keccak256(abi.encode(list[i])) != keccak256(abi.encode(target))) {
                out[out_idx] = list[i];
                out_idx ++;
            }
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

        if(ts_ == 1) {
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
            ? width = int24(int256(bound(_widthSeed, 1, 2048)))
            : int24(int256(bound(_widthSeed, 1, (2048 * 10) / uint256(ts))));
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
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 ts_,
        int24 currentTick,
        uint256 tokenType
    ) internal view returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        width = ts == 1
            ? width = int24(int256(bound(widthSeed, 1, 2048)))
            : int24(int256(bound(widthSeed, 1, (2048 * 10) / uint256(ts))));
        int24 oneSidedRange = int24((width * ts) / 2);

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        (int24 strikeOffset, int24 minTick, int24 maxTick) = getContext(ts_, currentTick, width);

        int24 lowerBound = tokenType == 0
            ? int24(minTick + oneSidedRange - strikeOffset)
            : int24(currentTick + oneSidedRange - strikeOffset);
        int24 upperBound = tokenType == 0
            ? int24(currentTick + ts - oneSidedRange - strikeOffset)
            : int24(maxTick - oneSidedRange - strikeOffset);

        if (ts == 1) {
            lowerBound = tokenType == 0
                ? int24(minTick + rangeDown - strikeOffset)
                : int24(currentTick + rangeDown - strikeOffset);
            upperBound = tokenType == 0
                ? int24(currentTick + ts - rangeUp - strikeOffset)
                : int24(maxTick - rangeUp - strikeOffset);
        }

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(bound(strikeSeed, lowerBound / ts, upperBound / ts));

        strike = int24(strike * ts + strikeOffset);
    }

    function getValidSW(
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 ts_,
        int24 currentTick
    ) internal view returns (int24 width, int24 strike) {
        int256 ts = int256(ts_);

        width = ts == 1
            ? width = int24(int256(bound(widthSeed, 1, 2048)))
            : int24(int256(bound(widthSeed, 1, 2048)));

        int24 rangeDown;
        int24 rangeUp;
        (rangeDown, rangeUp) = PanopticMath.getRangesFromStrike(width, int24(ts));

        (int24 strikeOffset, int24 minTick, int24 maxTick) = getContext(ts_, currentTick, width);

        int24 lowerBound = int24(minTick + rangeDown - strikeOffset);
        int24 upperBound = int24(maxTick - rangeUp - strikeOffset);

        // strike MUST be defined as a multiple of tickSpacing because the range extends out equally on both sides,
        // based on the width being divisibly by 2, it is then offset by either ts or ts / 2
        strike = int24(bound(strikeSeed, lowerBound / ts, upperBound / ts));

        strike = int24(strike * ts + strikeOffset);
    }

    ////////////////////////////////////////////////////
    // Loggers
    ////////////////////////////////////////////////////

    function log_tokenid_leg(TokenId t, uint256 leg) internal {
        emit LogString("TokenId");
        emit LogUint256("  Asset", t.asset(leg));
        emit LogUint256("  Option ratio", t.optionRatio(leg));
        emit LogUint256("  Is long", t.isLong(leg));
        emit LogUint256("  Token type", t.tokenType(leg));
        emit LogUint256("  Risk partner", t.riskPartner(leg));
        emit LogInt256("  Strike tick", t.strike(leg));
        emit LogInt256("  Width", t.width(leg));
    }

    function log_account_collaterals(address account) internal {
        uint c0s = collToken0.balanceOf(account);
        uint c1s = collToken1.balanceOf(account);
        uint c0a = collToken0.convertToAssets(collToken0.balanceOf(account));
        uint c1a = collToken1.convertToAssets(collToken1.balanceOf(account));

        emit LogAddress("Collaterals for address", account);
        emit LogUint256("  Token0 (shares)", c0s);
        emit LogUint256("  Token0 (assets)", c0a);
        emit LogUint256("  Token1 (shares)", c1s);
        emit LogUint256("  Token1 (assets)", c1a);
    }

    function log_trackers_status() internal {
        uint ts0 = collToken0.totalSupply();
        uint ta0 = collToken0.totalAssets();
        uint ts1 = collToken1.totalSupply();
        uint ta1 = collToken1.totalAssets();
        emit LogUint256("Total shares collateral 0:", ts0);
        emit LogUint256("Total assets collateral 0:", ta0);
        emit LogUint256("Total shares collateral 1:", ts1);
        emit LogUint256("Total assets collateral 1:", ta1);
    }

}
