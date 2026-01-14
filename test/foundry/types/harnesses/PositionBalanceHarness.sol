// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";

/// @title PositionBalanceHarness: A harness to expose the PositionBalance library for code coverage analysis.
/// @notice Replicates the interface of the PositionBalance library, passing through any function calls
/// @author Axicon Labs Limited
contract PositionBalanceHarness {
    /// @notice Create a new `PositionBalance` given by positionSize, utilizations, and its tickData.
    /// @param _positionSize The amount of option minted
    /// @param _utilizations packing of two uint16 utilizations into a 32 bit word
    /// @param _tickAtMint packing of 4 int25s into a single uint96
    /// @param
    /// @return The new PositionBalance with the given positionSize, utilization, and tickData
    function storeBalanceData(
        uint128 _positionSize,
        uint32 _utilizations,
        int24 _tickAtMint,
        uint32 _timestampAtMint,
        uint40 _blockAtMint
    ) public pure returns (PositionBalance) {
        return
            PositionBalanceLibrary.storeBalanceData(
                _positionSize,
                _utilizations,
                _tickAtMint,
                _timestampAtMint,
                _blockAtMint
            );
    }

    /// @notice Get the positionSize of `self`.
    /// @param self The PositionBalance to get the size from
    /// @return The positionSize of `self`
    function positionSize(PositionBalance self) public pure returns (uint128) {
        return PositionBalanceLibrary.positionSize(self);
    }

    /// @notice Get both token0 and token1 utilizations of `self`.
    /// @param self The PositionBalance to get utilization
    /// @return The token utilizations, stored in bips
    function utilizations(PositionBalance self) public pure returns (uint32) {
        return PositionBalanceLibrary.utilizations(self);
    }

    /// @notice Get token0 utilization of `self`.
    /// @param self The PositionBalance to get utilization
    /// @return The token0 utilization, stored in bips
    function utilization0(PositionBalance self) public pure returns (int256) {
        return PositionBalanceLibrary.utilization0(self);
    }

    /// @notice Get token1 utilization of `self`.
    /// @param self The PositionBalance to get utilization
    /// @return The token1 utilization, stored in bips
    function utilization1(PositionBalance self) public pure returns (int256) {
        return PositionBalanceLibrary.utilization1(self);
    }

    /// @notice Get the last observed tick of `self`.
    /// @param self The PositionBalance to get the requested tick
    /// @return The last observed tick of self
    function tickAtMint(PositionBalance self) public pure returns (int24) {
        return PositionBalanceLibrary.tickAtMint(self);
    }

    /// @notice Get the slow oracle tick of `self`.
    /// @param self The PositionBalance to get the requested tick
    /// @return The slow oracle tick of self
    function timestampAtMint(PositionBalance self) public pure returns (uint32) {
        return PositionBalanceLibrary.timestampAtMint(self);
    }

    /// @notice Get the last observed tick of `self`.
    /// @param self The PositionBalance to get the last observed tick
    /// @return The fast oracle tick of self
    function blockAtMint(PositionBalance self) public pure returns (uint40) {
        return PositionBalanceLibrary.blockAtMint(self);
    }
}
