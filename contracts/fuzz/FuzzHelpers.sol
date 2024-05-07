// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {ISwapRouter} from "v3-periphery/interfaces/ISwapRouter.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PropertiesAsserts} from "./PropertiesHelper.sol";
import {IUniDeployer} from "./fuzz-mocks/IUniDeployer.sol";
import {IUniSwapRouterDeployer} from "./fuzz-mocks/IUniSwapRouterDeployer.sol";

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

contract FuzzHelpers is PropertiesAsserts {
    IHevm hevm = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    //Testing uni deployment
    IUniDeployer deployer = IUniDeployer(address(0xde0001));

    IUniswapV3Pool USDC_WETH_5 = IUniswapV3Pool(deployer.pool());
    IERC20 USDC = IERC20(deployer.token0());
    IERC20 WETH = IERC20(deployer.token1());

    ISwapRouter router = ISwapRouter(IUniSwapRouterDeployer(address(0xde0002)).sr());

    function abs(int256 x) internal pure returns (uint256) {
        if (x >= 0) {
            return uint256(x);
        } else {
            return uint256(-x);
        }
    }

    function bound(uint256 value, uint256 min, uint256 max) internal pure returns (uint256) {
        uint256 range = max - min + 1;
        return min + (value % range);
    }

    function bound(int256 value, int256 min, int256 max) internal pure returns (int256) {
        int256 range = max - min + 1;
        return min + (value % range);
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return ( (a >= b) ? a :  b);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return ( (a <= b) ? a :  b);
    }

    function deal_USDC(address to, uint256 amt, bool alter_supply) internal {
        deployer.mintToken(false, to, amt);
    }

    function deal_WETH(address to, uint256 amt) internal {
        deployer.mintToken(true, to, amt);
    }

    function alter_USDC(address to, uint256 bal) internal {
        // Balances in slot 0
        uint256 slot_balances = uint256(0);
        hevm.store(address(USDC), keccak256(abi.encode(address(to), slot_balances)), bytes32(bal));

    }

    function alter_WETH(address to, uint256 bal) internal {
        // Balances in slot 3 (verify with "slither --print variable-order 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")
        hevm.store(address(WETH), keccak256(abi.encode(address(to), uint256(0))), bytes32(bal));
    }

    function deal_Generic(
        address token,
        uint256 slot,
        address to,
        uint256 amt,
        bool alter_supply,
        uint256 supply_slot
    ) internal {
        uint256 slot_balances = slot;
        uint256 original_balance = uint256(
            hevm.load(token, keccak256(abi.encode(address(to), slot_balances)))
        );
        int256 delta = int256(amt) - int256(original_balance);
        hevm.store(token, keccak256(abi.encode(address(to), slot_balances)), bytes32(amt));

        if (alter_supply) {
            bytes32 slot_supply = bytes32(supply_slot);
            uint256 orig_supply = uint256(hevm.load(token, slot_supply));
            uint256 new_supply = uint256(int256(orig_supply) + delta);
            hevm.store(token, slot_supply, bytes32(new_supply));
        }
    }
}
