// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManagerV4.sol";
import {TokenId, TokenIdLibrary} from "@types/TokenId.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {V4StateReader} from "@libraries/V4StateReader.sol";

contract SellOptionsV4 is Script {
    using TokenIdLibrary for TokenId;

    function run() public {
        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER_V4"));
        PanopticPool pp = PanopticPool(vm.envAddress("PANOPTIC_POOL"));
        SemiFungiblePositionManager sfpm = SemiFungiblePositionManager(vm.envAddress("SFPM"));
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address sender = vm.addr(pk);

        // Build pool key from env variables
        address currency0 = vm.envAddress("CURRENCY0");
        address currency1 = vm.envAddress("CURRENCY1");
        uint24 fee = uint24(vm.envUint("FEE"));
        int24 tickSpacing = int24(uint24(vm.envUint("TICK_SPACING")));

        PoolKey memory poolKey = PoolKey(
            Currency.wrap(currency0),
            Currency.wrap(currency1),
            fee,
            tickSpacing,
            IHooks(address(0))
        );

        uint64 poolId = pp.poolId();
        CollateralTracker ct0 = pp.collateralToken0();
        CollateralTracker ct1 = pp.collateralToken1();

        // Get current price and calculate strike
        int24 currentTick = V4StateReader.getTick(manager, poolKey.toId());
        int24 strike = (currentTick / tickSpacing) * tickSpacing;

        console.log("Sender:", sender);
        console.log("Pool:", address(pp));
        console.log("Pool Manager:", address(manager));
        console.log("Pool ID:", poolId);
        console.log("Tick Spacing:", uint256(uint24(tickSpacing)));
        console.log("Current Tick:", int256(currentTick));
        console.log("Strike:", int256(strike));

        // Build 5 tokenIds
        TokenId[] memory tokenIds = new TokenId[](5);
        int24[5] memory strikes = [
            strike - 40 * tickSpacing,
            strike - 20 * tickSpacing,
            strike,
            strike + 20 * tickSpacing,
            strike + 40 * tickSpacing
        ];
        for (uint256 i = 0; i < 5; i++) {
            tokenIds[i] = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 1, 0, strikes[i], 2);
        }

        vm.startBroadcast(pk);

        sfpm.expandEnforcedTickRange(poolId);

        IERC20Partial(currency0).approve(address(ct0), 1e16);
        ct0.deposit(1e16, sender);
        IERC20Partial(currency1).approve(address(ct1), 1e7);
        ct1.deposit(1e7, sender);

        console.log("Deposited 1e16 to CT0:", currency0);
        console.log("Deposited 1e7 to CT1:", currency1);

        // Mint all 5 options in one dispatch call
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
