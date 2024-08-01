// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {UniswapV3Pool} from "univ3-core/contracts/UniswapV3Pool.sol";

interface IUniDeployer {
    function token0() external returns (address);

    function token1() external returns (address);

    function pool() external returns (address);

    function getPools() external returns (UniswapV3Pool[4] memory);

    function factory() external returns (address);

    function mintToken(bool mintToken1, address recipient, uint256 amt) external;
}
