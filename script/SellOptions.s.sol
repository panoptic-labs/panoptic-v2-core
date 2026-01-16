// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {TokenId, TokenIdLibrary} from "@types/TokenId.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";

contract SellOptions is Script {
    using TokenIdLibrary for TokenId;

    function run() public {
        PanopticPool pp = PanopticPool(vm.envAddress("PANOPTIC_POOL"));
        SemiFungiblePositionManager sfpm = SemiFungiblePositionManager(vm.envAddress("SFPM"));
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address sender = vm.addr(pk);

        IUniswapV3Pool uniPool = IUniswapV3Pool(abi.decode(pp.poolKey(), (address)));
        int24 tickSpacing = uniPool.tickSpacing();
        int24 currentTick = pp.getCurrentTick();
        int24 strike = (currentTick / tickSpacing) * tickSpacing;
        uint64 poolId = pp.poolId();
        CollateralTracker ct0 = pp.collateralToken0();
        CollateralTracker ct1 = pp.collateralToken1();

        console.log("Sender:", sender);
        console.log("Pool:", address(pp));
        console.log("Uniswap Pool:", address(uniPool));
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

        IERC20Partial(ct0.underlyingToken()).approve(address(ct0), 1e16);
        ct0.deposit(1e16, sender);
        IERC20Partial(ct1.underlyingToken()).approve(address(ct1), 1e7);
        ct1.deposit(1e7, sender);

        console.log("Deposited 1e16 to CT0:", address(ct0));
        console.log("Deposited 1e7 to CT1:", address(ct1));

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
