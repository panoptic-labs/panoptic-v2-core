// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@types/TickStateCallContext.sol";

/// @title TickStateCallContextHarness: A harness to expose the TickStateCallContext library for code coverage analysis.
/// @notice Replicates the interface of the TickStateCallContext library, passing through any function calls
/// @author Axicon Labs Limited
contract TickStateCallContextHarness {
    function addFastOracleTick(uint256 self, int24 fastOracleTick) public pure returns (uint256) {
        uint256 r = TickStateCallContext.addFastOracleTick(self, fastOracleTick);
        return r;
    }

    function addSlowOracleTick(uint256 self, int24 slowOracleTick) public pure returns (uint256) {
        uint256 r = TickStateCallContext.addSlowOracleTick(self, slowOracleTick);
        return r;
    }

    function addCaller(uint256 self, address _msgSender) public pure returns (uint256) {
        uint256 r = TickStateCallContext.addCaller(self, _msgSender);
        return r;
    }

    function slowOracleTick(uint256 self) public pure returns (int24) {
        int24 r = TickStateCallContext.slowOracleTick(self);
        return r;
    }

    function fastOracleTick(uint256 self) public pure returns (int24) {
        int24 r = TickStateCallContext.fastOracleTick(self);
        return r;
    }

    function caller(uint256 self) public pure returns (address) {
        address r = TickStateCallContext.caller(self);
        return r;
    }
}
