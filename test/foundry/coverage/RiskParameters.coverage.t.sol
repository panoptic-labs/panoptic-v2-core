// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RiskParameters, RiskParametersLibrary} from "@types/RiskParameters.sol";

/// @notice Fills the coverage gaps left in `contracts/types/RiskParameters.sol` by the rest of the suite:
/// the `protocolSplit` and `builderSplit` getters, checked as part of a full encode/decode round trip.
contract RiskParametersCoverageTest is Test {
    function test_roundTrip_allFields(
        uint256 safeMode,
        uint256 notionalFee,
        uint256 premiumFee,
        uint256 protocolSplit,
        uint256 builderSplit,
        uint256 tickDeltaDispatch,
        uint256 maxSpread,
        uint256 bpDecreaseBuffer,
        uint256 maxLegs,
        uint128 feeRecipient
    ) public pure {
        // bound every field to its packed width so that neighbours do not bleed into each other
        safeMode = bound(safeMode, 0, 2 ** 4 - 1);
        notionalFee = bound(notionalFee, 0, 2 ** 14 - 1);
        premiumFee = bound(premiumFee, 0, 2 ** 14 - 1);
        protocolSplit = bound(protocolSplit, 0, 2 ** 14 - 1);
        builderSplit = bound(builderSplit, 0, 2 ** 14 - 1);
        tickDeltaDispatch = bound(tickDeltaDispatch, 0, 2 ** 13 - 1);
        maxSpread = bound(maxSpread, 0, 2 ** 22 - 1);
        bpDecreaseBuffer = bound(bpDecreaseBuffer, 0, 2 ** 26 - 1);
        maxLegs = bound(maxLegs, 0, 2 ** 7 - 1);

        RiskParameters params = RiskParametersLibrary.storeRiskParameters(
            safeMode,
            notionalFee,
            premiumFee,
            protocolSplit,
            builderSplit,
            tickDeltaDispatch,
            maxSpread,
            bpDecreaseBuffer,
            maxLegs,
            feeRecipient
        );

        assertEq(params.safeMode(), safeMode, "safeMode");
        assertEq(params.notionalFee(), notionalFee, "notionalFee");
        assertEq(params.premiumFee(), premiumFee, "premiumFee");
        assertEq(params.protocolSplit(), protocolSplit, "protocolSplit");
        assertEq(params.builderSplit(), builderSplit, "builderSplit");
        assertEq(params.tickDeltaDispatch(), tickDeltaDispatch, "tickDeltaDispatch");
        assertEq(params.maxSpread(), maxSpread, "maxSpread");
        assertEq(params.bpDecreaseBuffer(), bpDecreaseBuffer, "bpDecreaseBuffer");
        assertEq(params.maxLegs(), maxLegs, "maxLegs");
        assertEq(params.feeRecipient(), feeRecipient, "feeRecipient");
    }

    function test_splits_areIsolatedFromNeighbours() public pure {
        // only the two split fields set: every other getter must read zero
        RiskParameters params = RiskParametersLibrary.storeRiskParameters(
            0,
            0,
            0,
            2 ** 14 - 1,
            2 ** 14 - 1,
            0,
            0,
            0,
            0,
            0
        );

        assertEq(params.protocolSplit(), 2 ** 14 - 1, "protocolSplit");
        assertEq(params.builderSplit(), 2 ** 14 - 1, "builderSplit");
        assertEq(params.premiumFee(), 0, "premiumFee");
        assertEq(params.tickDeltaDispatch(), 0, "tickDeltaDispatch");
        assertEq(RiskParameters.unwrap(params), ((uint256(1) << 28) - 1) << 32, "raw word");

        // every other field saturated, the two splits empty
        params = RiskParametersLibrary.storeRiskParameters(
            2 ** 4 - 1,
            2 ** 14 - 1,
            2 ** 14 - 1,
            0,
            0,
            2 ** 13 - 1,
            2 ** 22 - 1,
            2 ** 26 - 1,
            2 ** 7 - 1,
            type(uint128).max
        );

        assertEq(params.protocolSplit(), 0, "protocolSplit empty");
        assertEq(params.builderSplit(), 0, "builderSplit empty");
    }
}
