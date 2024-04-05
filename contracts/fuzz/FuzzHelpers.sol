// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {ISwapRouter} from "v3-periphery/interfaces/ISwapRouter.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IHevm {
    function warp(uint256 newTimestamp) external;

    function roll(uint256 newNumber) external;

    function load(address where, bytes32 slot) external returns (bytes32);

    function store(address where, bytes32 slot, bytes32 value) external;

    function sign(
        uint256 privateKey,
        bytes32 digest
    ) external returns (uint8 r, bytes32 v, bytes32 s);

    function addr(uint256 privateKey) external returns (address add);

    function ffi(string[] calldata inputs) external returns (bytes memory result);

    function prank(address newSender) external;

    function createFork(string calldata urlOrAlias) external returns (uint256);

    function selectFork(uint256 forkId) external;

    function activeFork() external returns (uint256);

    function label(address addr, string calldata label) external;
}

contract Loggers {
    event LogAddr(string, address);
    event LogUint256(string, uint256);
    event LogUint128(string, uint128);
    event LogBool(string, bool);
}

contract FuzzHelpers is Loggers {
    IHevm hevm = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    ISwapRouter router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IUniswapV3Pool constant USDC_WETH_5 =
        IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function abs(int256 x) internal pure returns (uint256) {
        if (x >= 0) {
            return uint256(x);
        } else {
            return uint256(-x);
        }
    }

    function bound(uint256 value, uint256 min, uint256 max) internal pure returns (uint256) {
        uint256 range = max - min + 1;
        return value % range;
    }

    function bound(int256 value, int256 min, int256 max) internal pure returns (int256) {
        int256 range = max - min + 1;
        return value % range;
    }

    function deal_USDC(address to, uint256 amt) internal {
        // Balances in slot 9 (verify with "slither --print variable-order 0x43506849D7C04F9138D1A2050bbF3A0c054402dd")
        hevm.store(address(USDC), keccak256(abi.encode(address(to), uint256(9))), bytes32(amt));
    }

    function deal_WETH(address to, uint256 amt) internal {
        // Balances in slot 3 (verify with "slither --print variable-order 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")
        hevm.store(address(WETH), keccak256(abi.encode(address(to), uint256(3))), bytes32(amt));
    }
}
