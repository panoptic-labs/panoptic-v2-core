// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {TokenId} from "@types/TokenId.sol";

// ----- Common to Mainnet and V4 Attack -----

interface IAAVELendingPool {
    /**
     * @dev Allows smartcontracts to access the liquidity of the pool within one transaction,
     * as long as the amount taken plus a fee is returned.
     * IMPORTANT There are security concerns for developers of flashloan receiver contracts that must be kept into consideration.
     * For further details please visit https://developers.aave.com
     * @param receiverAddress The address of the contract receiving the funds, implementing the IFlashLoanReceiver interface
     * @param assets The addresses of the assets being flash-borrowed
     * @param amounts The amounts amounts being flash-borrowed
     * @param modes Types of the debt to open if the flash loan is not returned:
     *   0 -> Don't open any debt, just revert if funds can't be transferred from the receiver
     *   1 -> Open debt at stable rate for the value of the amount flash-borrowed to the `onBehalfOf` address
     *   2 -> Open debt at variable rate for the value of the amount flash-borrowed to the `onBehalfOf` address
     * @param onBehalfOf The address  that will receive the debt in the case of using on `modes` 1 or 2
     * @param params Variadic packed params to pass to the receiver as extra information
     * @param referralCode Code used to register the integrator originating the operation, for potential rewards.
     *   0 if the action is executed directly by the user, without any middle-man
     **/
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IMorpho {
  function flashLoan(address, uint, bytes calldata) external;
}

// From AAVE v3
interface IFlashLoanReceiver {
    /**
     * @notice Executes an operation after receiving the flash-borrowed assets
     * @dev Ensure that the contract can return the debt + premium, e.g., has
     *      enough funds to repay and has approved the Pool to pull the total amount
     * @param assets The addresses of the flash-borrowed assets
     * @param amounts The amounts of the flash-borrowed assets
     * @param premiums The fee of each flash-borrowed asset
     * @param initiator The address of the flashloan initiator
     * @param params The byte-encoded params passed when initiating the flashloan
     * @return True if the execution of the operation succeeds, false otherwise
     */
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool);

    // function ADDRESSES_PROVIDER() external view returns (IPoolAddressesProvider);
    // function POOL() external view returns (IPool);
}

// From Morpho
interface IMorphoFlashLoanCallback {
    function onMorphoFlashLoan(
        uint256 amount,
        bytes calldata data
    ) external;
}

interface IERC20Partial {
    function balanceOf(address account) external view returns (uint256);

    function approve(address spender, uint256 amount) external;

    function transfer(address to, uint256 amount) external;

    function totalSupply() external view returns (uint256);
}

// --------------------------------------------------------------------
// Mainnet Panoptic Pool interfaces

interface ICollateralTracker is IERC20Partial {
    function getPoolData()
        external
        view
        returns (uint256 poolAssets, uint256 insideAMM, uint256 currentPoolUtilization);

    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        TokenId[] calldata positionIdList
    ) external returns (uint256 shares);

    function totalAssets() external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}

interface ICollateralTracker_v4 is IERC20Partial {
    function getPoolData()
        external
        view
        returns (uint256 poolAssets, uint256 insideAMM, uint256 currentPoolUtilization);

    function deposit(uint256 assets, address receiver) external payable returns (uint256 shares);

    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        TokenId[] calldata positionIdList,
        bool
    ) external returns (uint256 shares);

    function totalAssets() external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}

interface ISFPM {
    function getPoolId(address univ3pool) external view returns (uint64 poolId);

    function getEnforcedTickLimits(uint64 poolId) external view returns (int24, int24);
}

interface IPanopticPool {
    function mintOptions(
        TokenId[] memory positionIdList,
        uint128 positionSize,
        uint64 effectiveLiquidityLimitX32,
        int24 tickLimitLow,
        int24 tickLimitHigh
    ) external;

    function validateCollateralWithdrawable(
        address user,
        TokenId[] calldata positionIdList
    ) external view;

    function liquidate(
        TokenId[] memory positionIdListLiquidator,
        address liquidatee,
        TokenId[] memory positionIdList
    ) external;

    // function positionData( address user, uint256 tokenId ) external view returns (int24 , int24 , int24 , int24 , int256 , int256 , uint128);
    function collateralToken0() external view returns (address);

    function collateralToken1() external view returns (address);
    // function multicall(bytes[] memory data) external payable returns (bytes[] memory results);
}

interface IPanopticPool_v4 {
    function mintOptions(
        TokenId[] memory positionIdList,
        uint128 positionSize,
        uint64 effectiveLiquidityLimitX32,
        int24 tickLimitLow,
        int24 tickLimitHigh,
        bool premiaAsCollateral
    ) external;

    function validateCollateralWithdrawable(
        address user,
        TokenId[] calldata positionIdList
    ) external view;

    function liquidate(
        TokenId[] memory positionIdListLiquidator,
        address liquidatee,
        TokenId[] memory positionIdList
    ) external;

    // function positionData( address user, uint256 tokenId ) external view returns (int24 , int24 , int24 , int24 , int256 , int256 , uint128);
    function collateralToken0() external view returns (address);

    function collateralToken1() external view returns (address);
    // function multicall(bytes[] memory data) external payable returns (bytes[] memory results);
}

interface IUniswapV3Pool {
    function tickSpacing() external view returns (int24);

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function token0() external view returns (address);

    function token1() external view returns (address);
}

interface IWETH is IERC20Partial {
    function deposit() external payable;

    function withdraw(uint256) external;
}
