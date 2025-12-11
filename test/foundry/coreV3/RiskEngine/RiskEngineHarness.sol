// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;
// Foundry
import "forge-std/Test.sol";

import {RiskEngine} from "@contracts/RiskEngine.sol";
import {PositionBalance} from "@types/PositionBalance.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {TokenId} from "@types/TokenId.sol";

/// @notice Exposes internal functions of RiskEngine strictly for testing properties.
/// DO NOT DEPLOY IN PROD.
contract RiskEngineHarness is RiskEngine {
    constructor(
        uint256 _sellerCollateralRatio,
        uint256 _buyerCollateralRatio,
        uint256 _forceExerciseCost,
        uint256 _targetPoolUtilization,
        uint256 _saturatedPoolUtilization,
        uint256 _crossBuffer0,
        uint256 _crossBuffer1
    ) RiskEngine(_crossBuffer0, _crossBuffer1, address(0), address(0)) {}

    // Internal → public test shims

    function sellCollateralRatio(int256 util) external view returns (uint256) {
        return _sellCollateralRatio(util);
    }

    function buyCollateralRatio(uint256 util) external view returns (uint256) {
        return _buyCollateralRatio();
    }

    function reqAtUtil(
        uint128 amount,
        uint256 isLong,
        int16 util
    ) external view returns (uint256 required) {
        (required, ) = _getRequiredCollateralAtUtilization(amount, isLong, util);
    }

    function reqSingleNoPartner(
        TokenId tokenId,
        uint256 index,
        uint128 positionSize,
        int24 atTick,
        int16 poolUtilization
    ) external view returns (uint256) {
        return
            _getRequiredCollateralSingleLegNoPartner(
                tokenId,
                index,
                positionSize,
                atTick,
                poolUtilization
            );
    }

    function reqSinglePartner(
        TokenId tokenId,
        uint256 index,
        uint128 positionSize,
        int24 atTick,
        int16 poolUtilization
    ) external view returns (uint256) {
        return
            _getRequiredCollateralSingleLegPartner(
                tokenId,
                index,
                positionSize,
                atTick,
                poolUtilization
            );
    }

    function computeSpread(
        TokenId tokenId,
        uint128 positionSize,
        uint256 index,
        uint256 partnerIndex,
        int24 atTick,
        int16 poolUtilization
    ) external view returns (uint256) {
        return _computeSpread(tokenId, positionSize, index, partnerIndex, atTick, poolUtilization);
    }

    function computeStrangle(
        TokenId tokenId,
        uint256 index,
        uint128 positionSize,
        int24 atTick,
        int16 poolUtilization
    ) external view returns (uint256) {
        return _computeStrangle(tokenId, index, positionSize, atTick, poolUtilization);
    }

    function computeLoanOptionComposite(
        TokenId tokenId,
        uint128 positionSize,
        uint256 index,
        uint256 partnerIndex,
        int24 atTick,
        int16 poolUtilization
    ) external view returns (uint256) {
        return
            _computeLoanOptionComposite(
                tokenId,
                positionSize,
                index,
                partnerIndex,
                atTick,
                poolUtilization
            );
    }

    function computeCreditOptionComposite(
        TokenId tokenId,
        uint128 positionSize,
        uint256 index,
        uint256 partnerIndex,
        int24 atTick,
        int16 poolUtilization
    ) external view returns (uint256) {
        return _computeCreditOptionComposite(tokenId, positionSize, index, atTick);
    }

    function computeDelayedSwap(
        TokenId tokenId,
        uint128 positionSize,
        uint256 index,
        uint256 partnerIndex,
        int24 atTick
    ) external view returns (uint256) {
        return _computeDelayedSwap(tokenId, positionSize, index, partnerIndex, atTick);
    }

    // Thin public shim for _getTotalRequiredCollateral for property-only assertions
    function totalRequiredCollateral(
        PositionBalance[] calldata positionBalanceArray,
        TokenId[] calldata positionIdList,
        int24 atTick,
        LeftRightUnsigned longPremia
    ) external view returns (LeftRightUnsigned, LeftRightUnsigned, PositionBalance) {
        (
            LeftRightUnsigned tokensRequired,
            LeftRightUnsigned creditAmounts,
            PositionBalance globalUtilizations
        ) = _getTotalRequiredCollateral(positionBalanceArray, positionIdList, atTick, longPremia);
        return (tokensRequired, creditAmounts, globalUtilizations);
    }

    // Thin public shim for _getMargin for packing/units properties
    function getMarginInternal(
        address user,
        PositionBalance[] calldata positionBalanceArray,
        int24 atTick,
        TokenId[] calldata positionIdList,
        LeftRightUnsigned shortPremia,
        LeftRightUnsigned longPremia,
        CollateralTracker ct0,
        CollateralTracker ct1
    ) external view returns (LeftRightUnsigned, LeftRightUnsigned, PositionBalance) {
        address _user = user;
        return
            _getMargin(
                positionBalanceArray,
                positionIdList,
                atTick,
                _user,
                shortPremia,
                longPremia,
                ct0,
                ct1
            );
    }
}
