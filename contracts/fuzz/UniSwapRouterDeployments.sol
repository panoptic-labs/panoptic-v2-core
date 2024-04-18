// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./fuzz-mocks/MockERC20.sol";
import "./fuzz-mocks/IUniDeployer.sol";
import {SwapRouter} from "univ3-periphery/SwapRouter.sol";

contract UniSwapRouterDeployer {

    IUniDeployer deployer = IUniDeployer(address(0xde0001));
    SwapRouter public sr;

    constructor() {
        sr = new SwapRouter(deployer.factory(), deployer.token1());
    }

}