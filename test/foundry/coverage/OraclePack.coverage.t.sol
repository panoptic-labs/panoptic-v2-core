// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {OraclePack, OraclePackLibrary} from "@types/OraclePack.sol";

/// @notice Fills the coverage gaps left in `contracts/types/OraclePack.sol` by the rest of the suite:
/// the single-value getters `fastEMA`, `slowEMA`, `eonsEMA` and `timestamp`.
contract OraclePackCoverageTest is Test {
    int24 internal constant MIN_INT22 = -(2 ** 21);
    int24 internal constant MAX_INT22 = 2 ** 21 - 1;

    function _pack(
        uint256 epoch,
        int24 spot,
        int24 fast,
        int24 slow,
        int24 eons
    ) internal pure returns (OraclePack) {
        return
            OraclePackLibrary.storeOraclePack(
                epoch,
                0,
                OraclePackLibrary.packEMAs(spot, fast, slow, eons),
                0,
                0,
                0,
                0
            );
    }

    function test_singleEMAGetters_roundTrip(
        int24 spot,
        int24 fast,
        int24 slow,
        int24 eons
    ) public pure {
        spot = int24(bound(spot, MIN_INT22, MAX_INT22));
        fast = int24(bound(fast, MIN_INT22, MAX_INT22));
        slow = int24(bound(slow, MIN_INT22, MAX_INT22));
        eons = int24(bound(eons, MIN_INT22, MAX_INT22));

        OraclePack pack = _pack(0, spot, fast, slow, eons);

        assertEq(pack.spotEMA(), spot, "spotEMA");
        assertEq(pack.fastEMA(), fast, "fastEMA");
        assertEq(pack.slowEMA(), slow, "slowEMA");
        assertEq(pack.eonsEMA(), eons, "eonsEMA");

        // the single getters agree with the tuple getter
        (int24 _spot, int24 _fast, int24 _slow, int24 _eons, ) = pack.getEMAs();
        assertEq(pack.spotEMA(), _spot, "spotEMA vs getEMAs");
        assertEq(pack.fastEMA(), _fast, "fastEMA vs getEMAs");
        assertEq(pack.slowEMA(), _slow, "slowEMA vs getEMAs");
        assertEq(pack.eonsEMA(), _eons, "eonsEMA vs getEMAs");
    }

    function test_singleEMAGetters_distinctExtremes() public pure {
        // distinct values in each slot, including both 22-bit sign extremes
        OraclePack pack = _pack(0, 1, MIN_INT22, MAX_INT22, -1);

        assertEq(pack.spotEMA(), 1, "spotEMA");
        assertEq(pack.fastEMA(), MIN_INT22, "fastEMA");
        assertEq(pack.slowEMA(), MAX_INT22, "slowEMA");
        assertEq(pack.eonsEMA(), -1, "eonsEMA");
    }

    function test_timestamp_isEpochTimes64WhileItFits(uint24 epoch) public pure {
        // an epoch below 2**18 scales to seconds without leaving the uint24 return type
        epoch = uint24(bound(epoch, 0, 2 ** 18 - 1));

        OraclePack pack = _pack(epoch, 0, 0, 0, 0);

        assertEq(pack.epoch(), epoch, "epoch");
        assertEq(pack.timestamp(), uint256(epoch) * 64, "timestamp");
    }

    /// @dev Pins the current behaviour: the return type is uint24, so the 30-bit value `epoch << 6`
    /// loses its upper 6 bits. `timestamp()` therefore only equals `epoch * 64` modulo 2**24.
    function test_timestamp_truncatesToUint24(uint24 epoch) public pure {
        OraclePack pack = _pack(epoch, 0, 0, 0, 0);

        assertEq(pack.epoch(), epoch, "epoch");
        assertEq(pack.timestamp(), (uint256(epoch) << 6) % 2 ** 24, "timestamp");
        assertEq(pack.timestamp() % 64, 0, "timestamp is a multiple of 64");
    }
}
