// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {ISwapRouter} from "v3-periphery/interfaces/ISwapRouter.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PropertiesAsserts} from "./PropertiesHelper.sol";
import {IUniDeployer} from "./fuzz-mocks/IUniDeployer.sol";
import {IUniSwapRouterDeployer} from "./fuzz-mocks/IUniSwapRouterDeployer.sol";
import {WETH9} from "./fuzz-mocks/WETH9.sol";
import {FullMath} from "univ3-core/libraries/FullMath.sol";

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {IDonorNFT} from "@tokens/interfaces/IDonorNFT.sol";
import {DonorNFT} from "@periphery/DonorNFT.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {Constants} from "@libraries/Constants.sol";
import {LiquidityChunk, LiquidityChunkLibrary} from "@types/LiquidityChunk.sol";
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
    ) external returns (int128 premium0, int128 premium1, uint256[2][] memory) {
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
    // Used for safecasting
    using Math for uint256;
    using Math for int256;

    error SwapSimulationResults(int256, int256, int24);

    error UniMintSimulationResults(uint256, uint256, bool);

    error UniMintAndCollectSimulationResults(uint256, uint256, uint128, uint128, bool);

    error UniBurnAndCollectSimulationResults(uint256, uint256, uint128, uint128, bool);

    error SimulationResults(
        LeftRightUnsigned,
        LeftRightUnsigned,
        LeftRightUnsigned,
        LeftRightSigned,
        int256,
        LeftRightSigned,
        LeftRightSigned,
        uint256,
        int256,
        int24,
        bytes
    );

    struct BurnSimulationResults {
        uint256 delegated0;
        uint256 delegated1;
        uint256 totalSupply0;
        uint256 totalSupply1;
        uint256 totalAssets0;
        uint256 totalAssets1;
        uint256 settledTokens0;
        int256 shareDelta0;
        int256 shareDelta1;
        int256 longPremium0;
        int256 burnDelta0C;
        int256 burnDelta0;
        int256 burnDelta1;
        LeftRightSigned netExchanged;
        uint256[2][4][32] settledTokens;
    }

    struct LiquidationResults {
        LeftRightUnsigned margin0;
        LeftRightUnsigned margin1;
        int256 bonus0;
        int256 bonus1;
        int256 sharesD0;
        int256 sharesD1;
        uint256 liquidatorValueBefore0;
        uint256 liquidatorValueAfter0;
        uint256 settledTokens0;
        LeftRightSigned premia;
        int256 bonusCombined0;
        int256 protocolLoss0Actual;
        int256 protocolLoss0Expected;
        uint256[2][4][32] settledTokens;
    }

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
    address token0;
    address token1;
    uint24 poolFee;
    int24 poolTickSpacing;
    uint160 currentSqrtPriceX96;
    int24 currentTick;
    int24 currentTickOld;

    CollateralTracker collToken0;
    CollateralTracker collToken1;

    address[] actors;
    address pool_manipulator;

    SwapperC swapperc;

    mapping(address => TokenId[]) userPositions;

    mapping(address => TokenId[]) userPositionsSFPM;

    mapping(address => mapping(TokenId => LeftRightUnsigned)) userBalance;

    uint256 constant MAX_DEPOSIT = 100 ether;
    uint256 constant MIN_DEPOSIT = 0.01 ether;

    BurnSimulationResults burnSimResults;
    LiquidationResults liqResults;

    IHevm hevm = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    //Testing uni deployment
    IUniDeployer deployer = IUniDeployer(address(0xde0001));

    IUniswapV3Pool USDC_WETH_5 = IUniswapV3Pool(deployer.pool());
    IERC20 USDC = IERC20(deployer.token0());
    IERC20 WETH = IERC20(deployer.token1());

    ISwapRouter router = ISwapRouter(IUniSwapRouterDeployer(address(0xde0002)).sr());

    /// temp storage SFPM
    address $activeUser;

    //
    TokenId tokenIdShort;
    TokenId tokenIdLong;
    LiquidityChunk liquidityChunk;
    //
    uint128 $posLiquidity;
    //
    uint256 removedLiquidityBefore;
    uint256 netLiquidityBefore;
    uint256 removedLiquidityAfter;
    uint256 netLiquidityAfter;

    //
    int256 feesBaseBefore0;
    int256 feesBaseBefore1;
    //
    int256 feesBaseAfter0;
    int256 feesBaseAfter1;
    //
    int256 amountToCollect0;
    int256 amountToCollect1;

    // -- ddd--
    //
    uint256 $feeGrowthInside0LastX128Before;
    uint256 $feeGrowthInside1LastX128Before;
    uint256 $feeGrowthInside0LastX128After;
    uint256 $feeGrowthInside1LastX128After;
    //
    uint256 $amountMinted0;
    uint256 $amountMinted1;
    //
    int256 $amountBurned0;
    int256 $amountBurned1;
    //
    bool $shouldRevertSFPM;
    int24 $tickLowerActive;
    int24 $tickUpperActive;
    uint128 $LiqAmountActive;
    //
    int128 oldFeesBase0;
    int128 oldFeesBase1;
    //
    uint128 $collected0;
    uint128 $collected1;
    //
    LeftRightUnsigned[4] $collectedByLeg;
    LeftRightSigned $totalSwapped;

    ///
    uint256 $amountRequested0;
    uint256 $amountRequested1;
    //
    int128 $amountToCollect0;
    int128 $amountToCollect1;
    //
    uint128 $recievedAmount0;
    uint128 $recievedAmount1;

    /// premium owed
    uint128 $accountPremiumOwedBefore0;
    uint128 $accountPremiumOwedBefore1;
    //
    uint128 $accountPremiumOwedAfter0;
    uint128 $accountPremiumOwedAfter1;
    /// premium gross
    uint128 $accountPremiumGrossBefore0;
    uint128 $accountPremiumGrossBefore1;
    //
    uint128 $accountPremiumGrossAfter0;
    uint128 $accountPremiumGrossAfter1;
    //
    uint256 $accountPremiumOwedCalculated0;
    uint256 $accountPremiumOwedCalculated1;
    //
    uint256 $accountPremiumGrossCalculated0;
    uint256 $accountPremiumGrossCalculated1;

    /// ^^ SFPM

    function bound(uint256 value, uint256 min, uint256 max) internal pure returns (uint256) {
        uint256 range = max - min + 1;
        return min + (value % range);
    }

    function bound(int256 value, int256 min, int256 max) internal pure returns (int256) {
        int256 range = max - min + 1;
        return min + (value % range);
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return ((a >= b) ? a : b);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return ((a <= b) ? a : b);
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
    ) internal returns (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1) {
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
    ) internal returns (uint256 balanceCross, uint256 thresholdCross) {
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

    function _get_list_without_tokenid(
        TokenId[] memory list,
        TokenId target
    ) internal pure returns (TokenId[] memory out) {
        // Assumes target is in list

        uint256 l = list.length;
        out = new TokenId[](l - 1);
        uint256 out_idx = 0;

        for (uint i = 0; i < l; i++) {
            if (keccak256(abi.encode(list[i])) != keccak256(abi.encode(target))) {
                out[out_idx] = list[i];
                out_idx++;
            }
        }
    }

    function convertToAssets(CollateralTracker ct, int256 amount) internal view returns (int256) {
        return (amount > 0 ? int8(1) : -1) * int256(ct.convertToAssets(uint256(Math.abs(amount))));
    }

    /////////////////////////////////////////////////////////////
    // Liquidation calculation helpers
    /////////////////////////////////////////////////////////////

    function _calculate_protocol_loss_0(int24 tick) internal {
        uint256 delegated0 = burnSimResults.delegated0;
        uint256 delegated1 = burnSimResults.delegated1;
        uint256 totalSupply0 = burnSimResults.totalSupply0;
        uint256 totalSupply1 = burnSimResults.totalSupply1;
        uint256 totalAssets0 = burnSimResults.totalAssets0;
        uint256 totalAssets1 = burnSimResults.totalAssets1;

        unchecked {
            liqResults.protocolLoss0Actual = int256(
                (collToken0.convertToAssets(
                    (collToken0.totalSupply() - totalSupply0) -
                        ((collToken0.totalAssets() - totalAssets0) * totalSupply0) /
                        totalAssets0
                ) * (totalSupply0 - delegated0)) /
                    (totalSupply0 - (collToken0.totalSupply() - totalSupply0)) +
                    PanopticMath.convert1to0(
                        (collToken1.convertToAssets(
                            (collToken1.totalSupply() - totalSupply1) -
                                ((collToken1.totalAssets() - totalAssets1) * totalSupply1) /
                                totalAssets1
                        ) * (totalSupply1 - delegated1)) /
                            (totalSupply1 - (collToken1.totalSupply() - totalSupply1)),
                        TickMath.getSqrtRatioAtTick(tick)
                    )
            );
        }
    }

    function _calculate_protocol_loss_expected_0(int24 twaptick, int24 curtick) internal {
        int256 balanceCombined0CT = int256(
            liqResults.margin0.rightSlot() +
                PanopticMath.convert1to0(
                    liqResults.margin1.rightSlot(),
                    TickMath.getSqrtRatioAtTick(twaptick)
                )
        );

        int256 balance0CombinedPostBurn = int256(uint256(liqResults.margin0.rightSlot())) -
            Math.max(liqResults.premia.rightSlot(), 0) +
            burnSimResults.burnDelta0 +
            int256(
                PanopticMath.convert1to0(
                    int256(uint256(liqResults.margin1.rightSlot())) -
                        Math.max(liqResults.premia.leftSlot(), 0) +
                        burnSimResults.burnDelta1,
                    TickMath.getSqrtRatioAtTick(curtick)
                )
            );

        liqResults.protocolLoss0Expected = Math.max(
            -(balance0CombinedPostBurn -
                Math.min(
                    balanceCombined0CT / 2,
                    int256(
                        liqResults.margin0.leftSlot() +
                            PanopticMath.convert1to0(
                                liqResults.margin1.leftSlot(),
                                TickMath.getSqrtRatioAtTick(twaptick)
                            )
                    ) - balanceCombined0CT
                )),
            0
        );
    }

    function _calculate_settled_tokens(
        TokenId[] memory positions,
        int24 tick
    ) internal returns (uint256, bytes memory) {
        uint256 settledTokens0;

        uint256[2][4][32] memory settledTokens;
        for (uint256 i = 0; i < positions.length; ++i) {
            for (uint256 j = 0; j < positions[i].countLegs(); ++j) {
                bytes32 chunk = keccak256(
                    abi.encodePacked(
                        positions[i].strike(j),
                        positions[i].width(j),
                        positions[i].tokenType(j)
                    )
                );
                settledTokens[i][j] = [
                    uint256(chunk),
                    LeftRightUnsigned.unwrap(panopticPool.settledTokens(chunk))
                ];
                settledTokens0 += panopticPool.settledTokens(chunk).rightSlot();
                settledTokens0 += PanopticMath.convert1to0(
                    panopticPool.settledTokens(chunk).leftSlot(),
                    TickMath.getSqrtRatioAtTick(tick)
                );
            }
        }

        return (settledTokens0, abi.encode(settledTokens));
    }

    // given an itm0 and itm1 values return the swapped amounts and swap direction
    function _compute_swap_amounts(
        int256 itm0,
        int256 itm1
    ) internal returns (int256 swapAmount, bool zeroForOne) {
        if ((itm0 != 0) && (itm1 != 0)) {
            (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

            int256 net0 = itm0 - PanopticMath.convert1to0(itm1, sqrtPriceX96);

            zeroForOne = net0 < 0;

            swapAmount = -net0;
        } else if (itm0 != 0) {
            zeroForOne = itm0 < 0;
            swapAmount = -itm0;
        } else {
            zeroForOne = itm1 > 0;
            swapAmount = -itm1;
        }
    }

    //

    function quote_uni_CollectAndBurn() internal {
        try this.uniswap_CollectAndBurn_sim() {} catch (bytes memory results) {
            emit LogBytes("r", results);
            assembly ("memory-safe") {
                results := add(results, 0x04)
            }
            bool sRevert;
            ($amountBurned0, $amountBurned1, $recievedAmount0, $recievedAmount1, sRevert) = abi
                .decode(results, (int256, int256, uint128, uint128, bool));

            $shouldRevertSFPM = $shouldRevertSFPM || sRevert;
        }
    }

    function uniswap_CollectAndBurn_sim() external {
        int256 burned0;
        int256 burned1;

        hevm.prank(address(sfpm));
        try pool.burn($tickLowerActive, $tickUpperActive, $LiqAmountActive) returns (
            uint256 amount0,
            uint256 amount1
        ) {
            burned0 = int256(amount0);
            burned1 = int256(amount1);
        } catch {
            revert UniBurnAndCollectSimulationResults(0, 0, 0, 0, true);
        }

        //
        hevm.prank(address(sfpm));
        try
            pool.collect(
                $activeUser, //recipient
                $tickLowerActive,
                $tickUpperActive,
                uint128($amountToCollect0),
                uint128($amountToCollect1)
            )
        returns (uint128 received0, uint128 received1) {
            revert UniBurnAndCollectSimulationResults(
                uint256(burned0),
                uint256(burned1),
                received0,
                received1,
                false
            );
        } catch {
            revert UniBurnAndCollectSimulationResults(0, 0, 0, 0, true);
        }
    }

    //

    function quote_uni_CollectAndMint() internal {
        try this.uniswap_CollectAndMint_sim() {} catch (bytes memory results) {
            emit LogBytes("r", results);
            assembly ("memory-safe") {
                results := add(results, 0x04)
            }
            bool sRevert;
            ($amountMinted0, $amountMinted1, $recievedAmount0, $recievedAmount1, sRevert) = abi
                .decode(results, (uint256, uint256, uint128, uint128, bool));

            $shouldRevertSFPM = $shouldRevertSFPM || sRevert;
        }
    }

    function uniswap_CollectAndMint_sim() external {
        bytes memory mintdata = abi.encode(
            CallbackLib.CallbackData({
                // compute by reading values from univ3pool every time
                poolFeatures: CallbackLib.PoolFeatures({
                    token0: pool.token0(),
                    token1: pool.token1(),
                    fee: pool.fee()
                }),
                payer: $activeUser
            })
        );

        uint256 minted0;
        uint256 minted1;

        hevm.prank(address(sfpm));
        try
            pool.mint(
                $activeUser, //recipient
                $tickLowerActive,
                $tickUpperActive,
                $LiqAmountActive,
                mintdata
            )
        returns (uint256 amount0, uint256 amount1) {
            minted0 = amount0;
            minted1 = amount1;
        } catch {
            revert UniMintAndCollectSimulationResults(0, 0, 0, 0, true);
        }

        //
        hevm.prank(address(sfpm));
        try
            pool.collect(
                $activeUser, //recipient
                $tickLowerActive,
                $tickUpperActive,
                uint128($amountToCollect0),
                uint128($amountToCollect1)
            )
        returns (uint128 received0, uint128 received1) {
            revert UniMintAndCollectSimulationResults(
                minted0,
                minted1,
                received0,
                received1,
                false
            );
        } catch {
            revert UniMintAndCollectSimulationResults(0, 0, 0, 0, true);
        }
    }

    function quote_uni_mint() internal {
        try this.uniswap_mint_sim() {} catch (bytes memory results) {
            emit LogBytes("r", results);
            assembly ("memory-safe") {
                results := add(results, 0x04)
            }
            bool sRevert;
            ($amountMinted0, $amountMinted1, sRevert) = abi.decode(
                results,
                (uint256, uint256, bool)
            );

            $shouldRevertSFPM = $shouldRevertSFPM || sRevert;
        }
    }

    function uniswap_mint_sim() external {
        bytes memory mintdata = abi.encode(
            CallbackLib.CallbackData({
                // compute by reading values from univ3pool every time
                poolFeatures: CallbackLib.PoolFeatures({
                    token0: pool.token0(),
                    token1: pool.token1(),
                    fee: pool.fee()
                }),
                payer: msg.sender
            })
        );

        hevm.prank(address(sfpm));
        try
            pool.mint(
                msg.sender, //recipient
                $tickLowerActive,
                $tickUpperActive,
                $LiqAmountActive,
                mintdata
            )
        returns (uint256 amount0, uint256 amount1) {
            revert UniMintSimulationResults(amount0, amount1, false);
        } catch {
            revert UniMintSimulationResults(0, 0, false);
        }
    }

    function simulate_swap(address recipient, bool zeroForOne, int256 amountSpecified) external {
        hevm.prank(recipient);
        IERC20(USDC).approve(address(sfpm), type(uint256).max);
        hevm.prank(recipient);
        IERC20(WETH).approve(address(sfpm), type(uint256).max);

        int256 swap0;
        int256 swap1;

        if (amountSpecified != 0) {
            hevm.prank(address(sfpm));
            (int256 amt0, int256 amt1) = pool.swap(
                recipient,
                zeroForOne,
                amountSpecified,
                zeroForOne
                    ? Constants.MIN_V3POOL_SQRT_RATIO + 1
                    : Constants.MAX_V3POOL_SQRT_RATIO - 1,
                abi.encode(
                    CallbackLib.CallbackData({
                        poolFeatures: CallbackLib.PoolFeatures({
                            token0: token0,
                            token1: token1,
                            fee: poolFee
                        }),
                        payer: recipient
                    })
                )
            );

            swap0 = amt0;
            swap1 = amt1;
        }

        // get current tick after swap
        (, int24 tickAfterSwap, , , , , ) = pool.slot0();

        revert SwapSimulationResults(swap0, swap1, tickAfterSwap);
    }

    function _execute_swap_simulation(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified
    ) internal returns (int256, int256, int24) {
        try this.simulate_swap(recipient, zeroForOne, amountSpecified) {
            assertWithMsg(false, "swap succeeded ??");
        } catch (bytes memory results) {
            bytes4 selector = bytes4(results);
            require(selector == SwapSimulationResults.selector);
            emit LogBytes("r", results);

            assembly ("memory-safe") {
                results := add(results, 0x04)
            }

            (int256 swap0, int256 swap1, int24 tickAfterSwap) = abi.decode(
                results,
                (int256, int256, int24)
            );

            return (swap0, swap1, tickAfterSwap);
        }
    }

    /// asserts from foundry

    int256 private constant INT256_MIN =
        -57896044618658097711785492504343953926634992332820282019728792003956564819968;

    function abs(int256 a) internal pure returns (uint256) {
        // Required or it will fail when `a = type(int256).min`
        if (a == INT256_MIN) {
            return 57896044618658097711785492504343953926634992332820282019728792003956564819968;
        }

        return uint256(a > 0 ? a : -a);
    }

    function delta(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function delta(int256 a, int256 b) internal pure returns (uint256) {
        // a and b are of the same sign
        // this works thanks to two's complement, the left-most bit is the sign bit
        if ((a ^ b) > -1) {
            return delta(abs(a), abs(b));
        }

        // a and b are of opposite signs
        return abs(a) + abs(b);
    }

    function percentDelta(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 absDelta = delta(a, b);

        return (absDelta * 1e18) / b;
    }

    function percentDelta(int256 a, int256 b) internal pure returns (uint256) {
        uint256 absDelta = delta(a, b);
        uint256 absB = abs(b);

        return (absDelta * 1e18) / absB;
    }

    function assertApproxEqRel(
        int256 a,
        int256 b,
        uint256 maxPercentDelta, // An 18 decimal fixed point number, where 1e18 == 100%
        string memory err
    ) internal {
        uint256 percentDelta = percentDelta(a, b);

        if (percentDelta > maxPercentDelta) {
            assertWithMsg(false, err);
        }
    }

    function assertApproxEqRel(
        uint256 a,
        uint256 b,
        uint256 maxPercentDelta, // An 18 decimal fixed point number, where 1e18 == 100%
        string memory err
    ) internal {
        uint256 percentDelta = percentDelta(a, b);

        if (percentDelta > maxPercentDelta) {
            assertWithMsg(false, err);
        }
    }

    /// ^^^ asserts from foundry

    function simulate_burning(address who, address liquidator) external {
        require(msg.sender == address(this));

        uint128 delegated0 = uint128(collToken0.convertToAssets(collToken0.balanceOf(liquidator)));
        uint128 delegated1 = uint128(collToken1.convertToAssets(collToken1.balanceOf(liquidator)));
        LeftRightUnsigned delegated = LeftRightUnsigned.wrap(0).toLeftSlot(delegated0).toRightSlot(
            delegated1
        );

        hevm.prank(address(panopticPool));
        collToken0.delegate(liquidator, who, delegated0);
        hevm.prank(address(panopticPool));
        collToken1.delegate(liquidator, who, delegated1);

        int256[2] memory shareDeltasLiquidatee = [
            int256(collToken0.balanceOf(who)),
            int256(collToken1.balanceOf(who))
        ];

        LeftRightSigned[4][] memory premiasByLeg;
        LeftRightSigned netExchanged;

        hevm.prank(who);
        (premiasByLeg, netExchanged) = panopticPool.burnAllOptionsFrom(userPositions[who], 0, 0);

        (, currentTick, , , , , ) = pool.slot0();

        shareDeltasLiquidatee = [
            int256(collToken0.balanceOf(who)) - shareDeltasLiquidatee[0],
            int256(collToken1.balanceOf(who)) - shareDeltasLiquidatee[1]
        ];

        (uint256 settledTokens0, bytes memory settledTokens) = _calculate_settled_tokens(
            userPositions[who],
            currentTick
        );

        int256 longPremium0;
        for (uint256 i = 0; i < userPositions[who].length; ++i) {
            for (uint256 j = 0; j < userPositions[who][i].countLegs(); ++j) {
                longPremium0 += premiasByLeg[i][j].rightSlot() < 0
                    ? -premiasByLeg[i][j].rightSlot()
                    : int128(0);
                longPremium0 += PanopticMath.convert1to0(
                    premiasByLeg[i][j].leftSlot() < 0 ? -premiasByLeg[i][j].leftSlot() : int128(0),
                    TickMath.getSqrtRatioAtTick(currentTick)
                );
            }
        }

        LeftRightUnsigned supply = LeftRightUnsigned
            .wrap(0)
            .toLeftSlot(uint128(collToken0.totalSupply()))
            .toRightSlot(uint128(collToken1.totalSupply()));
        LeftRightUnsigned assets = LeftRightUnsigned
            .wrap(0)
            .toLeftSlot(uint128(collToken0.totalAssets()))
            .toRightSlot(uint128(collToken1.totalAssets()));
        LeftRightSigned shareDelta = LeftRightSigned
            .wrap(0)
            .toLeftSlot(int128(shareDeltasLiquidatee[0]))
            .toRightSlot(int128(shareDeltasLiquidatee[1]));

        int256 burnDelta0C = convertToAssets(collToken0, shareDeltasLiquidatee[0]) +
            PanopticMath.convert1to0(
                convertToAssets(collToken1, shareDeltasLiquidatee[1]),
                TickMath.getSqrtRatioAtTick(currentTick)
            );
        LeftRightSigned burnDelta = LeftRightSigned
            .wrap(0)
            .toLeftSlot(int128(convertToAssets(collToken0, shareDeltasLiquidatee[0])))
            .toRightSlot(int128(convertToAssets(collToken1, shareDeltasLiquidatee[1])));

        bytes memory _settledTokens = settledTokens;
        revert SimulationResults(
            supply,
            assets,
            delegated,
            shareDelta,
            burnDelta0C,
            burnDelta,
            netExchanged,
            settledTokens0,
            longPremium0,
            currentTick,
            _settledTokens
        );
    }

    function _execute_burn_simulation(address liquidatee, address liquidator) internal {
        try this.simulate_burning(liquidatee, liquidator) {} catch (bytes memory results) {
            bytes4 selector = bytes4(results);
            require(selector == SimulationResults.selector);
            emit LogBytes("r", results);
            {
                LeftRightUnsigned totalSupply;
                LeftRightUnsigned totalAssets;
                LeftRightUnsigned delegated;
                LeftRightSigned shareDelta;
                int256 burnDelta0C;
                LeftRightSigned burnDelta;
                LeftRightSigned netExchanged;
                uint256 settledTokens0;
                int256 longPremium0;

                assembly ("memory-safe") {
                    totalSupply := mload(add(results, 0x24))
                    totalAssets := mload(add(results, 0x44))
                    delegated := mload(add(results, 0x64))
                    shareDelta := mload(add(results, 0x84))
                    burnDelta0C := mload(add(results, 0xa4))
                    burnDelta := mload(add(results, 0xc4))
                    netExchanged := mload(add(results, 0xe4))
                    settledTokens0 := mload(add(results, 0x104))
                    longPremium0 := mload(add(results, 0x124))
                }

                burnSimResults.totalSupply0 = totalSupply.leftSlot();
                burnSimResults.totalSupply1 = totalSupply.rightSlot();
                burnSimResults.totalAssets0 = totalAssets.leftSlot();
                burnSimResults.totalAssets1 = totalAssets.rightSlot();
                burnSimResults.delegated0 = delegated.leftSlot();
                burnSimResults.delegated1 = delegated.rightSlot();
                burnSimResults.shareDelta0 = shareDelta.leftSlot();
                burnSimResults.shareDelta1 = shareDelta.rightSlot();
                burnSimResults.settledTokens0 = settledTokens0;
                burnSimResults.longPremium0 = longPremium0;
                burnSimResults.burnDelta0C = burnDelta0C;
                burnSimResults.burnDelta0 = burnDelta.leftSlot();
                burnSimResults.burnDelta1 = burnDelta.rightSlot();
                burnSimResults.netExchanged = netExchanged;
            }
            int24 ct;
            assembly ("memory-safe") {
                ct := mload(add(results, 0x144))
                results := mload(add(results, 0x164))
            }
            currentTickOld = currentTick;
            currentTick = ct;
            burnSimResults.settledTokens = abi.decode(results, (uint256[2][4][32]));
        }
    }

    function _calculate_margins_and_premia(address who, int24 tick) internal {
        (int128 expectedP0, int128 expectedP1, uint256[2][] memory posBal) = panopticPool
            .calculateAccumulatedFeesBatch(who, false, userPositions[who]);

        liqResults.margin0 = collToken0.getAccountMarginDetails(who, tick, posBal, expectedP0);
        liqResults.margin1 = collToken1.getAccountMarginDetails(who, tick, posBal, expectedP1);
        liqResults.premia = LeftRightSigned.wrap(0).toRightSlot(expectedP0).toLeftSlot(expectedP1);
    }

    function _calculate_liquidation_bonus(int24 twaptick, int24 curtick) internal {
        (liqResults.bonus0, liqResults.bonus1, ) = PanopticMath.getLiquidationBonus(
            liqResults.margin0,
            liqResults.margin1,
            Math.getSqrtRatioAtTick(twaptick),
            Math.getSqrtRatioAtTick(curtick),
            burnSimResults.netExchanged,
            liqResults.premia
        );
    }

    function _calculate_bonus(int24 tick) internal {
        int256 combinedBalance0Premium = int256(
            (liqResults.margin0.rightSlot()) +
                PanopticMath.convert1to0(
                    liqResults.margin1.rightSlot(),
                    TickMath.getSqrtRatioAtTick(tick)
                )
        );
        liqResults.bonusCombined0 = Math.min(
            combinedBalance0Premium / 2,
            int256(
                liqResults.margin0.leftSlot() +
                    PanopticMath.convert1to0(
                        liqResults.margin1.leftSlot(),
                        TickMath.getSqrtRatioAtTick(tick)
                    )
            ) - combinedBalance0Premium
        );
    }

    // for multiple legs
    function _calculate_moved_amounts(
        TokenId tokenId,
        uint128 positionSize
    ) internal returns (int256, int256) {
        //
        int256 moved0;
        int256 moved1;

        uint128 _positionSize = positionSize;
        TokenId _tokenId = tokenId;

        // update to latest current tick
        (, currentTick, , , , , ) = pool.slot0();

        //
        uint256 numLegs = _tokenId.countLegs();
        for (uint256 leg = 0; leg < numLegs; leg++) {
            //create liquidity chunk object
            LiquidityChunk currChunk = PanopticMath.getLiquidityChunk(_tokenId, leg, _positionSize);

            // tick lower
            emit LogInt256("tick lower", currChunk.tickLower());
            // tick upper
            emit LogInt256("tick upper", currChunk.tickUpper());
            // amount of liquidity
            emit LogUint256("liquidity", currChunk.liquidity());
            // current tick
            emit LogInt256("current tick", currentTick);

            (uint256 amount0, uint256 amount1) = Math.getAmountsForLiquidity(
                currentTick,
                currChunk
            );

            // actual moved amounts when minting rounds up (round down when burning)

            if (_tokenId.isLong(leg) == 1) {
                moved0 -= int256(amount0);
                moved1 -= int256(amount1);
            } else {
                moved0 += int256(amount0);
                moved1 += int256(amount1);
            }
        }

        return (moved0, moved1);
    }

    function _calculate_itm_amounts(
        uint256 tokenType,
        int256 moved0,
        int256 moved1
    ) internal returns (int256 itm0, int256 itm1) {
        if (tokenType == 0) {
            itm1 += moved1;
        } else {
            // tt = 1
            itm0 += moved0;
        }
    }

    function _calculate_moved_and_ITM_amounts(
        TokenId tokenId,
        uint128 positionSize,
        bool roundUp
    ) internal returns (int256, int256, int256, int256) {
        //
        int256 moved0;
        int256 moved1;

        //
        int256 itm0;
        int256 itm1;

        uint128 _positionSize = positionSize;
        TokenId _tokenId = tokenId;
        bool _roundUp = roundUp;

        // update to latest current tick
        (, currentTick, , , , , ) = pool.slot0();

        //
        uint256 numLegs = _tokenId.countLegs();
        for (uint256 leg = 0; leg < numLegs; leg++) {
            //create liquidity chunk object
            LiquidityChunk currChunk = PanopticMath.getLiquidityChunk(_tokenId, leg, _positionSize);

            (uint256 amount0, uint256 amount1) = Math.getAmountsForLiquidity(
                currentTick,
                currChunk
            );

            if (_tokenId.isLong(leg) == 1) {
                moved0 -= int256(amount0);
                moved1 -= int256(amount1);
            } else {
                moved0 += int256(amount0);
                moved1 += int256(amount1);
            }

            if (_tokenId.tokenType(leg) == 0) {
                itm1 += int256(amount1);
            } else {
                // tt = 1
                itm0 += int256(amount0);
            }

            //
            emit LogUint256("_tokenId.tokenType(leg)", _tokenId.tokenType(leg));

            // amounts
            emit LogUint256("amount0", amount0);
            emit LogUint256("amount1", amount1);
        }

        return (moved0, moved1, itm0, itm1);
    }

    function getPremiaDeltasChecked(
        uint256 netLiquidity,
        uint256 removedLiquidity,
        uint128 collected0,
        uint128 collected1
    ) external returns (LeftRightUnsigned deltaPremiumOwed, LeftRightUnsigned deltaPremiumGross) {
        // premia spread equations are graphed and documented here: https://www.desmos.com/calculator/mdeqob2m04
        // explains how we get from the premium per liquidity (calculated here) to the total premia collected and the multiplier
        // as well as how the value of VEGOID affects the premia
        // note that the "base" premium is just a common factor shared between the owed (long) and gross (short)
        // premia, and is only seperated to simplify the calculation
        // (the graphed equations include this factor without separating it)
        uint256 totalLiquidity = netLiquidity + removedLiquidity;

        uint256 premium0X64_base;
        uint256 premium1X64_base;

        emit LogUint256("inside premia deltas checked removed liq", removedLiquidity);
        emit LogUint256("inside premia deltas checked netLiq", netLiquidity);

        {
            // compute the base premium as collected * total / net^2 (from Eqn 3)
            premium0X64_base = Math.mulDiv(collected0, totalLiquidity * 2 ** 64, netLiquidity ** 2);
            premium1X64_base = Math.mulDiv(collected1, totalLiquidity * 2 ** 64, netLiquidity ** 2);
        }

        {
            uint128 premium0X64_owed;
            uint128 premium1X64_owed;
            {
                // compute the owed premium (from Eqn 3)
                uint256 numerator = netLiquidity + (removedLiquidity / 2 ** 2);

                premium0X64_owed = Math
                    .mulDiv(premium0X64_base, numerator, totalLiquidity)
                    .toUint128Capped();
                premium1X64_owed = Math
                    .mulDiv(premium1X64_base, numerator, totalLiquidity)
                    .toUint128Capped();

                deltaPremiumOwed = LeftRightUnsigned
                    .wrap(0)
                    .toRightSlot(premium0X64_owed)
                    .toLeftSlot(premium1X64_owed);
            }
        }

        {
            uint128 premium0X64_gross;
            uint128 premium1X64_gross;
            {
                // compute the gross premium (from Eqn 4)
                uint256 numerator = totalLiquidity ** 2 -
                    totalLiquidity *
                    removedLiquidity +
                    ((removedLiquidity ** 2) / 2 ** (2));

                premium0X64_gross = Math
                    .mulDiv(premium0X64_base, numerator, totalLiquidity ** 2)
                    .toUint128Capped();
                premium1X64_gross = Math
                    .mulDiv(premium1X64_base, numerator, totalLiquidity ** 2)
                    .toUint128Capped();

                deltaPremiumGross = LeftRightUnsigned
                    .wrap(0)
                    .toRightSlot(premium0X64_gross)
                    .toLeftSlot(premium1X64_gross);
            }
        }
    }

    uint256 MAX_UINT128 = type(uint128).max;

    // takes a premia accumulator and adds the computed amounts
    // checks for freeze if one side is equivalent to uint128.max
    // or ensures there isn't an overflow if the amounts roll over
    function incrementPremiaAccumulator(
        uint256 premiumOwed0,
        uint256 premiumOwed1,
        uint256 deltaPremiumOwed0,
        uint256 deltaPremiumOwed1,
        uint256 premiumGross0,
        uint256 premiumGross1,
        uint256 deltaPremiumGross0,
        uint256 deltaPremiumGross1
    ) internal returns (uint256 owed0, uint256 owed1, uint256 gross0, uint256 gross1) {
        // add together the new owed premiums
        uint256 newOwed0 = premiumOwed0 + deltaPremiumOwed0;
        uint256 newOwed1 = premiumOwed1 + deltaPremiumOwed1;

        // add together the new gross premiums
        uint256 newGross0 = premiumGross0 + deltaPremiumGross0;
        uint256 newGross1 = premiumGross1 + deltaPremiumGross1;

        bool r_Enabled = !(newOwed0 > MAX_UINT128 || newGross0 > MAX_UINT128);
        bool l_Enabled = !(newOwed1 > MAX_UINT128 || newGross1 > MAX_UINT128);

        // assign final values and check for cap / overflow
        owed0 = newOwed0 > MAX_UINT128 ? MAX_UINT128 : newOwed0;
        owed1 = newOwed1 > MAX_UINT128 ? MAX_UINT128 : newOwed1;
        //
        gross0 = newGross0 > MAX_UINT128 ? MAX_UINT128 : newGross0;
        gross1 = newGross1 > MAX_UINT128 ? MAX_UINT128 : newGross1;
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

    function log_burn_simulation_results() internal {
        emit LogString("Burn simulation results");
        emit LogUint256("    delegated0", burnSimResults.delegated0);
        emit LogUint256("    delegated1", burnSimResults.delegated1);
        emit LogUint256("    totalSupply0", burnSimResults.totalSupply0);
        emit LogUint256("    totalSupply1", burnSimResults.totalSupply1);
        emit LogUint256("    totalAssets0", burnSimResults.totalAssets0);
        emit LogUint256("    totalAssets1", burnSimResults.totalAssets1);
        emit LogUint256("    settledTokens0", burnSimResults.settledTokens0);
        emit LogInt256("    shareDelta0", burnSimResults.shareDelta0);
        emit LogInt256("    shareDelta1", burnSimResults.shareDelta1);
        emit LogInt256("    longPremium0", burnSimResults.longPremium0);
        emit LogInt256("    burnDelta0C", burnSimResults.burnDelta0C);
        emit LogInt256("    burnDelta0", burnSimResults.burnDelta0);
        emit LogInt256("    burnDelta1", burnSimResults.burnDelta1);
        emit LogInt256("    netExchanged L", burnSimResults.netExchanged.leftSlot());
        emit LogInt256("    netExchanged R", burnSimResults.netExchanged.rightSlot());
        emit LogUint256("    chunk", burnSimResults.settledTokens[0][0][0]);
    }

    function log_liquidation_results() internal {
        emit LogString("Liquidation results");
        emit LogUint256("    margin0 L", liqResults.margin0.leftSlot());
        emit LogUint256("    margin0 R", liqResults.margin0.rightSlot());
        emit LogUint256("    margin1 L", liqResults.margin1.leftSlot());
        emit LogUint256("    margin1 R", liqResults.margin1.rightSlot());
        emit LogInt256("    bonus0", liqResults.bonus0);
        emit LogInt256("    bonus1", liqResults.bonus1);
        emit LogInt256("    sharesD0", liqResults.sharesD0);
        emit LogInt256("    sharesD1", liqResults.sharesD1);
        emit LogUint256("    liquidatorValueBefore0", liqResults.liquidatorValueBefore0);
        emit LogUint256("    liquidatorValueAfter0", liqResults.liquidatorValueAfter0);
        emit LogUint256("    settledTokens0", liqResults.settledTokens0);
        emit LogInt256("    premia L", liqResults.premia.leftSlot());
        emit LogInt256("    premia R", liqResults.premia.rightSlot());
        emit LogInt256("    bonusCombined0", liqResults.bonusCombined0);
        emit LogInt256("    protocolLoss0Actual", liqResults.protocolLoss0Actual);
        emit LogInt256("    protocolLoss0Expected", liqResults.protocolLoss0Expected);
    }
}
