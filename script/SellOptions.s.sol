pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PanopticPoolV2} from "@contracts/PanopticPool.sol";
import {CollateralTrackerV2} from "@contracts/CollateralTracker.sol";
import {SemiFungiblePositionManagerV4} from "@contracts/SemiFungiblePositionManagerV4.sol";
import {TokenId, TokenIdLibrary} from "@types/TokenId.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {V4StateReader} from "@libraries/V4StateReader.sol";

contract SellOptions is Script {
    using TokenIdLibrary for TokenId;
    using PoolIdLibrary for PoolKey;

    function _getCurrentStrike(int24 tickSpacing) internal view returns (int24 strike) {
        PoolKey memory poolKey = PoolKey(
            Currency.wrap(vm.envAddress("CURRENCY0")),
            Currency.wrap(vm.envAddress("CURRENCY1")),
            uint24(vm.envUint("FEE")),
            tickSpacing,
            IHooks(address(0))
        );

        int24 currentTick = V4StateReader.getTick(
            IPoolManager(vm.envAddress("UNIV4_POOL_MANAGER")),
            poolKey.toId()
        );
        strike = (currentTick / tickSpacing) * tickSpacing;

        console.log("Pool Manager:", vm.envAddress("UNIV4_POOL_MANAGER"));
        console.log("Current Tick:", int256(currentTick));
        console.log("Strike:", int256(strike));
    }

    function _buildTokenIds(
        uint64 poolId,
        int24 tickSpacing,
        int24 strike
    ) internal pure returns (TokenId[] memory tokenIds, int24[5] memory strikes) {
        tokenIds = new TokenId[](5);
        strikes = [
            strike - 40 * tickSpacing,
            strike - 20 * tickSpacing,
            strike,
            strike + 20 * tickSpacing,
            strike + 40 * tickSpacing
        ];

        for (uint256 i = 0; i < 5; i++) {
            tokenIds[i] = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 1, 0, strikes[i], 2);
        }
    }

    function _depositCollateral(PanopticPoolV2 pp, address sender) internal {
        CollateralTrackerV2 ct0 = pp.collateralToken0();
        CollateralTrackerV2 ct1 = pp.collateralToken1();

        // IERC20Partial(vm.envAddress("CURRENCY0")).approve(address(ct0), 1e16);
        ct0.deposit{value: 1e16}(1e16, sender);
        IERC20Partial(vm.envAddress("CURRENCY1")).approve(address(ct1), 1e7);
        ct1.deposit(1e7, sender);

        console.log("Deposited 1e16 to CT0:", vm.envAddress("CURRENCY0"));
        console.log("Deposited 1e7 to CT1:", vm.envAddress("CURRENCY1"));
    }

    function run() public {
        PanopticPoolV2 pp = PanopticPoolV2(vm.envAddress("PANOPTIC_POOL"));
        int24 tickSpacing = int24(uint24(vm.envUint("TICK_SPACING")));
        uint64 poolId = pp.poolId();

        console.log("Pool:", address(pp));
        console.log("Pool ID:", poolId);
        console.log("Tick Spacing:", uint256(uint24(tickSpacing)));

        int24 strike = _getCurrentStrike(tickSpacing);
        (TokenId[] memory tokenIds, int24[5] memory strikes) = _buildTokenIds(
            poolId,
            tickSpacing,
            strike
        );

        vm.startBroadcast();

        SemiFungiblePositionManagerV4(vm.envAddress("SFPM_V4")).expandEnforcedTickRange(poolId);
        _depositCollateral(pp, msg.sender);

        uint128[] memory sizes = new uint128[](5);
        int24[3][] memory limits = new int24[3][](5);
        for (uint256 i = 0; i < 5; i++) {
            sizes[i] = 1e12;
            limits[i][0] = -782080;
            limits[i][1] = 782080;
            limits[i][2] = 782080;
        }

        pp.dispatch(tokenIds, tokenIds, sizes, limits, false, 0);

        for (uint256 i = 0; i < 5; i++) {
            console.log("Minted option at strike:", int256(strikes[i]));
            console.log("TokenId:", TokenId.unwrap(tokenIds[i]));
        }

        vm.stopBroadcast();
    }
}
