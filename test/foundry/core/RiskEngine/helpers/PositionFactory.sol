// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TokenId} from "@types/TokenId.sol";
import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";

library PositionFactory {
    /// Packs all leg arguments so callers don't explode the stack.
    struct Leg {
        uint256 legIndex; // 0..3
        uint256 optionRatio;
        uint256 asset;
        uint256 isLong;
        uint256 tokenType;
        // riskPartner is ignored on input for makeTwoLegs; we set cross partners explicitly
        int24 strike;
        int24 width; // 0 => loan/credit
    }

    // Builds a single-leg position with given params.
    function makeLeg(uint64 poolId, Leg memory L) internal pure returns (TokenId t) {
        t = TokenId.wrap(0).addPoolId(poolId);
        t = t.addLeg(
            L.legIndex,
            L.optionRatio,
            L.asset,
            L.isLong,
            L.tokenType,
            0, // riskPartner placeholder; self by default
            L.strike,
            L.width
        );
    }

    function makeLeg(
        uint64 poolId,
        uint256 legIndex,
        uint256 optionRatio,
        uint256 asset,
        uint256 isLong,
        uint256 tokenType,
        uint256 /*riskPartner*/,
        int24 strike,
        int24 width
    ) internal pure returns (TokenId t) {
        PositionFactory.Leg memory L = PositionFactory.Leg({
            legIndex: legIndex,
            optionRatio: optionRatio,
            asset: asset,
            isLong: isLong,
            tokenType: tokenType,
            strike: strike,
            width: width
        });
        return makeLeg(poolId, L);
    }

    // Two-legged position with explicit cross-partnership (0 <-> 1).
    // risk partners are set to cross after adding both legs.
    function makeTwoLegs(
        uint64 poolId,
        Leg memory A, // leg 0
        Leg memory B // leg 1
    ) internal pure returns (TokenId t) {
        t = TokenId.wrap(0).addPoolId(poolId);

        // add leg 0 (temp partner = 0)
        t = t.addLeg(0, A.optionRatio, A.asset, A.isLong, A.tokenType, 0, A.strike, A.width);

        // add leg 1 (temp partner = 0)
        t = t.addLeg(1, B.optionRatio, B.asset, B.isLong, B.tokenType, 0, B.strike, B.width);

        // cross-link partners
        t = t.addRiskPartner(1, 0);
        t = t.addRiskPartner(0, 1);
    }

    function makeTwoLegs(
        uint64 poolId,
        // leg 0
        uint256 optionRatio0,
        uint256 asset0,
        uint256 isLong0,
        uint256 tokenType0,
        int24 strike0,
        int24 width0,
        // leg 1
        uint256 optionRatio1,
        uint256 asset1,
        uint256 isLong1,
        uint256 tokenType1,
        int24 strike1,
        int24 width1
    ) internal pure returns (TokenId) {
        Leg memory A = Leg({
            legIndex: 0,
            optionRatio: optionRatio0,
            asset: asset0,
            isLong: isLong0,
            tokenType: tokenType0,
            strike: strike0,
            width: width0
        });
        uint64 _poolId = poolId;

        Leg memory B = Leg({
            legIndex: 1,
            optionRatio: optionRatio1,
            asset: asset1,
            isLong: isLong1,
            tokenType: tokenType1,
            strike: strike1,
            width: width1
        });

        return makeTwoLegs(_poolId, A, B);
    }

    function posBalance(
        uint128 positionSize,
        uint16 util0, // int16 packed in PositionBalance
        uint16 util1
    ) internal pure returns (PositionBalance) {
        uint32 utilPacked = uint32(util0) | (uint32(util1) << 16);
        return PositionBalanceLibrary.storeBalanceData(positionSize, utilPacked, 0);
    }
}
