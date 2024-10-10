import {
  createUseReadContract,
  createUseWriteContract,
  createUseSimulateContract,
  createUseWatchContractEvent,
} from "wagmi/codegen";

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// PanopticFactory
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const panopticFactoryAbi = [
  {
    type: "constructor",
    inputs: [
      { name: "_WETH9", internalType: "address", type: "address" },
      {
        name: "_SFPM",
        internalType: "contract SemiFungiblePositionManager",
        type: "address",
      },
      {
        name: "_univ3Factory",
        internalType: "contract IUniswapV3Factory",
        type: "address",
      },
      { name: "_poolReference", internalType: "address", type: "address" },
      {
        name: "_collateralReference",
        internalType: "address",
        type: "address",
      },
      { name: "properties", internalType: "bytes32[]", type: "bytes32[]" },
      { name: "indices", internalType: "uint256[][]", type: "uint256[][]" },
      { name: "pointers", internalType: "Pointer[][]", type: "uint256[][]" },
    ],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    inputs: [
      { name: "spender", internalType: "address", type: "address" },
      { name: "id", internalType: "uint256", type: "uint256" },
    ],
    name: "approve",
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    inputs: [{ name: "owner", internalType: "address", type: "address" }],
    name: "balanceOf",
    outputs: [{ name: "", internalType: "uint256", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [
      { name: "panopticPool", internalType: "address", type: "address" },
      { name: "symbol0", internalType: "string", type: "string" },
      { name: "symbol1", internalType: "string", type: "string" },
      { name: "fee", internalType: "uint256", type: "uint256" },
    ],
    name: "constructMetadata",
    outputs: [{ name: "", internalType: "string", type: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [
      { name: "token0", internalType: "address", type: "address" },
      { name: "token1", internalType: "address", type: "address" },
      { name: "fee", internalType: "uint24", type: "uint24" },
      { name: "salt", internalType: "uint96", type: "uint96" },
      { name: "amount0Max", internalType: "uint256", type: "uint256" },
      { name: "amount1Max", internalType: "uint256", type: "uint256" },
    ],
    name: "deployNewPool",
    outputs: [
      {
        name: "newPoolContract",
        internalType: "contract PanopticPool",
        type: "address",
      },
    ],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    inputs: [{ name: "", internalType: "uint256", type: "uint256" }],
    name: "getApproved",
    outputs: [{ name: "", internalType: "address", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [
      {
        name: "univ3pool",
        internalType: "contract IUniswapV3Pool",
        type: "address",
      },
    ],
    name: "getPanopticPool",
    outputs: [{ name: "", internalType: "contract PanopticPool", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [
      { name: "", internalType: "address", type: "address" },
      { name: "", internalType: "address", type: "address" },
    ],
    name: "isApprovedForAll",
    outputs: [{ name: "", internalType: "bool", type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [
      { name: "deployerAddress", internalType: "address", type: "address" },
      { name: "v3Pool", internalType: "address", type: "address" },
      { name: "salt", internalType: "uint96", type: "uint96" },
      { name: "loops", internalType: "uint256", type: "uint256" },
      { name: "minTargetRarity", internalType: "uint256", type: "uint256" },
    ],
    name: "minePoolAddress",
    outputs: [
      { name: "bestSalt", internalType: "uint96", type: "uint96" },
      { name: "highestRarity", internalType: "uint256", type: "uint256" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [{ name: "data", internalType: "bytes[]", type: "bytes[]" }],
    name: "multicall",
    outputs: [{ name: "results", internalType: "bytes[]", type: "bytes[]" }],
    stateMutability: "payable",
  },
  {
    type: "function",
    inputs: [],
    name: "name",
    outputs: [{ name: "", internalType: "string", type: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [{ name: "id", internalType: "uint256", type: "uint256" }],
    name: "ownerOf",
    outputs: [{ name: "owner", internalType: "address", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [
      { name: "from", internalType: "address", type: "address" },
      { name: "to", internalType: "address", type: "address" },
      { name: "id", internalType: "uint256", type: "uint256" },
    ],
    name: "safeTransferFrom",
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    inputs: [
      { name: "from", internalType: "address", type: "address" },
      { name: "to", internalType: "address", type: "address" },
      { name: "id", internalType: "uint256", type: "uint256" },
      { name: "data", internalType: "bytes", type: "bytes" },
    ],
    name: "safeTransferFrom",
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    inputs: [
      { name: "operator", internalType: "address", type: "address" },
      { name: "approved", internalType: "bool", type: "bool" },
    ],
    name: "setApprovalForAll",
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    inputs: [{ name: "interfaceId", internalType: "bytes4", type: "bytes4" }],
    name: "supportsInterface",
    outputs: [{ name: "", internalType: "bool", type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [],
    name: "symbol",
    outputs: [{ name: "", internalType: "string", type: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [{ name: "tokenId", internalType: "uint256", type: "uint256" }],
    name: "tokenURI",
    outputs: [{ name: "", internalType: "string", type: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [
      { name: "from", internalType: "address", type: "address" },
      { name: "to", internalType: "address", type: "address" },
      { name: "id", internalType: "uint256", type: "uint256" },
    ],
    name: "transferFrom",
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    inputs: [
      { name: "amount0Owed", internalType: "uint256", type: "uint256" },
      { name: "amount1Owed", internalType: "uint256", type: "uint256" },
      { name: "data", internalType: "bytes", type: "bytes" },
    ],
    name: "uniswapV3MintCallback",
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "event",
    anonymous: false,
    inputs: [
      {
        name: "owner",
        internalType: "address",
        type: "address",
        indexed: true,
      },
      {
        name: "spender",
        internalType: "address",
        type: "address",
        indexed: true,
      },
      { name: "id", internalType: "uint256", type: "uint256", indexed: true },
    ],
    name: "Approval",
  },
  {
    type: "event",
    anonymous: false,
    inputs: [
      {
        name: "owner",
        internalType: "address",
        type: "address",
        indexed: true,
      },
      {
        name: "operator",
        internalType: "address",
        type: "address",
        indexed: true,
      },
      { name: "approved", internalType: "bool", type: "bool", indexed: false },
    ],
    name: "ApprovalForAll",
  },
  {
    type: "event",
    anonymous: false,
    inputs: [
      {
        name: "poolAddress",
        internalType: "contract PanopticPool",
        type: "address",
        indexed: true,
      },
      {
        name: "uniswapPool",
        internalType: "contract IUniswapV3Pool",
        type: "address",
        indexed: true,
      },
      {
        name: "collateralTracker0",
        internalType: "contract CollateralTracker",
        type: "address",
        indexed: false,
      },
      {
        name: "collateralTracker1",
        internalType: "contract CollateralTracker",
        type: "address",
        indexed: false,
      },
      {
        name: "amount0",
        internalType: "uint256",
        type: "uint256",
        indexed: false,
      },
      {
        name: "amount1",
        internalType: "uint256",
        type: "uint256",
        indexed: false,
      },
    ],
    name: "PoolDeployed",
  },
  {
    type: "event",
    anonymous: false,
    inputs: [
      { name: "from", internalType: "address", type: "address", indexed: true },
      { name: "to", internalType: "address", type: "address", indexed: true },
      { name: "id", internalType: "uint256", type: "uint256", indexed: true },
    ],
    name: "Transfer",
  },
  { type: "error", inputs: [], name: "InvalidUniswapCallback" },
  { type: "error", inputs: [], name: "PoolAlreadyInitialized" },
  { type: "error", inputs: [], name: "PriceBoundFail" },
  { type: "error", inputs: [], name: "TransferFailed" },
  { type: "error", inputs: [], name: "UniswapPoolNotInitialized" },
] as const;

/**
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const panopticFactoryAddress = {
  11155111: "0xD958AE206C2243CbcC579e11937937E2C71D127F",
} as const;

/**
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const panopticFactoryConfig = {
  address: panopticFactoryAddress,
  abi: panopticFactoryAbi,
} as const;

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// PanopticPool
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const panopticPoolAbi = [
  {
    type: "constructor",
    inputs: [
      {
        name: "_sfpm",
        internalType: "contract SemiFungiblePositionManager",
        type: "address",
      },
    ],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    inputs: [
      { name: "minValue0", internalType: "uint256", type: "uint256" },
      { name: "minValue1", internalType: "uint256", type: "uint256" },
    ],
    name: "assertMinCollateralValues",
    outputs: [],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [
      { name: "tokenId", internalType: "TokenId", type: "uint256" },
      {
        name: "newPositionIdList",
        internalType: "TokenId[]",
        type: "uint256[]",
      },
      { name: "tickLimitLow", internalType: "int24", type: "int24" },
      { name: "tickLimitHigh", internalType: "int24", type: "int24" },
    ],
    name: "burnOptions",
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    inputs: [
      { name: "positionIdList", internalType: "TokenId[]", type: "uint256[]" },
      {
        name: "newPositionIdList",
        internalType: "TokenId[]",
        type: "uint256[]",
      },
      { name: "tickLimitLow", internalType: "int24", type: "int24" },
      { name: "tickLimitHigh", internalType: "int24", type: "int24" },
    ],
    name: "burnOptions",
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    inputs: [
      { name: "user", internalType: "address", type: "address" },
      { name: "includePendingPremium", internalType: "bool", type: "bool" },
      { name: "positionIdList", internalType: "TokenId[]", type: "uint256[]" },
    ],
    name: "calculateAccumulatedFeesBatch",
    outputs: [
      { name: "premium0", internalType: "int128", type: "int128" },
      { name: "premium1", internalType: "int128", type: "int128" },
      { name: "", internalType: "uint256[2][]", type: "uint256[2][]" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [
      { name: "user", internalType: "address", type: "address" },
      { name: "atTick", internalType: "int24", type: "int24" },
      { name: "positionIdList", internalType: "TokenId[]", type: "uint256[]" },
    ],
    name: "calculatePortfolioValue",
    outputs: [
      { name: "value0", internalType: "int256", type: "int256" },
      { name: "value1", internalType: "int256", type: "int256" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [],
    name: "collateralToken0",
    outputs: [
      {
        name: "collateralToken",
        internalType: "contract CollateralTracker",
        type: "address",
      },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [],
    name: "collateralToken1",
    outputs: [{ name: "", internalType: "contract CollateralTracker", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [
      { name: "account", internalType: "address", type: "address" },
      { name: "touchedId", internalType: "TokenId[]", type: "uint256[]" },
      {
        name: "positionIdListExercisee",
        internalType: "TokenId[]",
        type: "uint256[]",
      },
      {
        name: "positionIdListExercisor",
        internalType: "TokenId[]",
        type: "uint256[]",
      },
    ],
    name: "forceExercise",
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    inputs: [
      {
        name: "positionIdListLiquidator",
        internalType: "TokenId[]",
        type: "uint256[]",
      },
      { name: "liquidatee", internalType: "address", type: "address" },
      {
        name: "delegations",
        internalType: "LeftRightUnsigned",
        type: "uint256",
      },
      { name: "positionIdList", internalType: "TokenId[]", type: "uint256[]" },
    ],
    name: "liquidate",
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    inputs: [
      { name: "positionIdList", internalType: "TokenId[]", type: "uint256[]" },
      { name: "positionSize", internalType: "uint128", type: "uint128" },
      {
        name: "effectiveLiquidityLimitX32",
        internalType: "uint64",
        type: "uint64",
      },
      { name: "tickLimitLow", internalType: "int24", type: "int24" },
      { name: "tickLimitHigh", internalType: "int24", type: "int24" },
    ],
    name: "mintOptions",
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    inputs: [{ name: "data", internalType: "bytes[]", type: "bytes[]" }],
    name: "multicall",
    outputs: [{ name: "results", internalType: "bytes[]", type: "bytes[]" }],
    stateMutability: "payable",
  },
  {
    type: "function",
    inputs: [{ name: "user", internalType: "address", type: "address" }],
    name: "numberOfPositions",
    outputs: [{ name: "_numberOfPositions", internalType: "uint256", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [
      { name: "", internalType: "address", type: "address" },
      { name: "", internalType: "address", type: "address" },
      { name: "", internalType: "uint256[]", type: "uint256[]" },
      { name: "", internalType: "uint256[]", type: "uint256[]" },
      { name: "", internalType: "bytes", type: "bytes" },
    ],
    name: "onERC1155BatchReceived",
    outputs: [{ name: "", internalType: "bytes4", type: "bytes4" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    inputs: [
      { name: "", internalType: "address", type: "address" },
      { name: "", internalType: "address", type: "address" },
      { name: "", internalType: "uint256", type: "uint256" },
      { name: "", internalType: "uint256", type: "uint256" },
      { name: "", internalType: "bytes", type: "bytes" },
    ],
    name: "onERC1155Received",
    outputs: [{ name: "", internalType: "bytes4", type: "bytes4" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    inputs: [
      { name: "user", internalType: "address", type: "address" },
      { name: "tokenId", internalType: "TokenId", type: "uint256" },
    ],
    name: "optionPositionBalance",
    outputs: [
      { name: "balance", internalType: "uint128", type: "uint128" },
      { name: "poolUtilization0", internalType: "uint64", type: "uint64" },
      { name: "poolUtilization1", internalType: "uint64", type: "uint64" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [],
    name: "pokeMedian",
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    inputs: [
      { name: "positionIdList", internalType: "TokenId[]", type: "uint256[]" },
      { name: "owner", internalType: "address", type: "address" },
      { name: "legIndex", internalType: "uint256", type: "uint256" },
    ],
    name: "settleLongPremium",
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    inputs: [
      {
        name: "_univ3pool",
        internalType: "contract IUniswapV3Pool",
        type: "address",
      },
      { name: "token0", internalType: "address", type: "address" },
      { name: "token1", internalType: "address", type: "address" },
      {
        name: "collateralTracker0",
        internalType: "contract CollateralTracker",
        type: "address",
      },
      {
        name: "collateralTracker1",
        internalType: "contract CollateralTracker",
        type: "address",
      },
    ],
    name: "startPool",
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    inputs: [{ name: "interfaceId", internalType: "bytes4", type: "bytes4" }],
    name: "supportsInterface",
    outputs: [{ name: "", internalType: "bool", type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [],
    name: "univ3pool",
    outputs: [{ name: "", internalType: "contract IUniswapV3Pool", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    inputs: [
      { name: "user", internalType: "address", type: "address" },
      { name: "positionIdList", internalType: "TokenId[]", type: "uint256[]" },
    ],
    name: "validateCollateralWithdrawable",
    outputs: [],
    stateMutability: "view",
  },
  {
    type: "event",
    anonymous: false,
    inputs: [
      {
        name: "liquidator",
        internalType: "address",
        type: "address",
        indexed: true,
      },
      {
        name: "liquidatee",
        internalType: "address",
        type: "address",
        indexed: true,
      },
      {
        name: "bonusAmounts",
        internalType: "LeftRightSigned",
        type: "int256",
        indexed: false,
      },
    ],
    name: "AccountLiquidated",
  },
  {
    type: "event",
    anonymous: false,
    inputs: [
      {
        name: "exercisor",
        internalType: "address",
        type: "address",
        indexed: true,
      },
      { name: "user", internalType: "address", type: "address", indexed: true },
      {
        name: "tokenId",
        internalType: "TokenId",
        type: "uint256",
        indexed: true,
      },
      {
        name: "exerciseFee",
        internalType: "LeftRightSigned",
        type: "int256",
        indexed: false,
      },
    ],
    name: "ForcedExercised",
  },
  {
    type: "event",
    anonymous: false,
    inputs: [
      {
        name: "recipient",
        internalType: "address",
        type: "address",
        indexed: true,
      },
      {
        name: "positionSize",
        internalType: "uint128",
        type: "uint128",
        indexed: false,
      },
      {
        name: "tokenId",
        internalType: "TokenId",
        type: "uint256",
        indexed: true,
      },
      {
        name: "premia",
        internalType: "LeftRightSigned",
        type: "int256",
        indexed: false,
      },
    ],
    name: "OptionBurnt",
  },
  {
    type: "event",
    anonymous: false,
    inputs: [
      {
        name: "recipient",
        internalType: "address",
        type: "address",
        indexed: true,
      },
      {
        name: "positionSize",
        internalType: "uint128",
        type: "uint128",
        indexed: false,
      },
      {
        name: "tokenId",
        internalType: "TokenId",
        type: "uint256",
        indexed: true,
      },
      {
        name: "poolUtilizations",
        internalType: "uint128",
        type: "uint128",
        indexed: false,
      },
    ],
    name: "OptionMinted",
  },
  {
    type: "event",
    anonymous: false,
    inputs: [
      { name: "user", internalType: "address", type: "address", indexed: true },
      {
        name: "tokenId",
        internalType: "TokenId",
        type: "uint256",
        indexed: true,
      },
      {
        name: "settledAmounts",
        internalType: "LeftRightSigned",
        type: "int256",
        indexed: false,
      },
    ],
    name: "PremiumSettled",
  },
  { type: "error", inputs: [], name: "CastingError" },
  { type: "error", inputs: [], name: "EffectiveLiquidityAboveThreshold" },
  { type: "error", inputs: [], name: "InputListFail" },
  { type: "error", inputs: [], name: "InvalidTick" },
  {
    type: "error",
    inputs: [{ name: "parameterType", internalType: "uint256", type: "uint256" }],
    name: "InvalidTokenIdParameter",
  },
  { type: "error", inputs: [], name: "NoLegsExercisable" },
  { type: "error", inputs: [], name: "NotALongLeg" },
  { type: "error", inputs: [], name: "NotEnoughCollateral" },
  { type: "error", inputs: [], name: "NotMarginCalled" },
  { type: "error", inputs: [], name: "PoolAlreadyInitialized" },
  { type: "error", inputs: [], name: "PositionAlreadyMinted" },
  { type: "error", inputs: [], name: "StaleTWAP" },
  { type: "error", inputs: [], name: "TicksNotInitializable" },
  { type: "error", inputs: [], name: "TooManyPositionsOpen" },
  { type: "error", inputs: [], name: "UnderOverFlow" },
] as const;

/**
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const panopticPoolAddress = {
  11155111: "0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08",
} as const;

/**
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const panopticPoolConfig = {
  address: panopticPoolAddress,
  abi: panopticPoolAbi,
} as const;

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// React
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticFactoryAbi}__
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useReadPanopticFactory = /*#__PURE__*/ createUseReadContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"balanceOf"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useReadPanopticFactoryBalanceOf = /*#__PURE__*/ createUseReadContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "balanceOf",
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"constructMetadata"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useReadPanopticFactoryConstructMetadata = /*#__PURE__*/ createUseReadContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "constructMetadata",
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"getApproved"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useReadPanopticFactoryGetApproved = /*#__PURE__*/ createUseReadContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "getApproved",
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"getPanopticPool"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useReadPanopticFactoryGetPanopticPool = /*#__PURE__*/ createUseReadContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "getPanopticPool",
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"isApprovedForAll"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useReadPanopticFactoryIsApprovedForAll = /*#__PURE__*/ createUseReadContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "isApprovedForAll",
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"minePoolAddress"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useReadPanopticFactoryMinePoolAddress = /*#__PURE__*/ createUseReadContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "minePoolAddress",
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"name"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useReadPanopticFactoryName = /*#__PURE__*/ createUseReadContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "name",
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"ownerOf"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useReadPanopticFactoryOwnerOf = /*#__PURE__*/ createUseReadContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "ownerOf",
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"supportsInterface"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useReadPanopticFactorySupportsInterface = /*#__PURE__*/ createUseReadContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "supportsInterface",
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"symbol"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useReadPanopticFactorySymbol = /*#__PURE__*/ createUseReadContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "symbol",
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"tokenURI"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useReadPanopticFactoryTokenUri = /*#__PURE__*/ createUseReadContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "tokenURI",
});

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link panopticFactoryAbi}__
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useWritePanopticFactory = /*#__PURE__*/ createUseWriteContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
});

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"approve"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useWritePanopticFactoryApprove = /*#__PURE__*/ createUseWriteContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "approve",
});

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"deployNewPool"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useWritePanopticFactoryDeployNewPool = /*#__PURE__*/ createUseWriteContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "deployNewPool",
});

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"multicall"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useWritePanopticFactoryMulticall = /*#__PURE__*/ createUseWriteContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "multicall",
});

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"safeTransferFrom"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useWritePanopticFactorySafeTransferFrom = /*#__PURE__*/ createUseWriteContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "safeTransferFrom",
});

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"setApprovalForAll"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useWritePanopticFactorySetApprovalForAll = /*#__PURE__*/ createUseWriteContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "setApprovalForAll",
});

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"transferFrom"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useWritePanopticFactoryTransferFrom = /*#__PURE__*/ createUseWriteContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "transferFrom",
});

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"uniswapV3MintCallback"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useWritePanopticFactoryUniswapV3MintCallback = /*#__PURE__*/ createUseWriteContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "uniswapV3MintCallback",
});

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link panopticFactoryAbi}__
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useSimulatePanopticFactory = /*#__PURE__*/ createUseSimulateContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
});

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"approve"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useSimulatePanopticFactoryApprove = /*#__PURE__*/ createUseSimulateContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "approve",
});

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"deployNewPool"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useSimulatePanopticFactoryDeployNewPool = /*#__PURE__*/ createUseSimulateContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "deployNewPool",
});

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"multicall"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useSimulatePanopticFactoryMulticall = /*#__PURE__*/ createUseSimulateContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "multicall",
});

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"safeTransferFrom"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useSimulatePanopticFactorySafeTransferFrom = /*#__PURE__*/ createUseSimulateContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "safeTransferFrom",
});

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"setApprovalForAll"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useSimulatePanopticFactorySetApprovalForAll = /*#__PURE__*/ createUseSimulateContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "setApprovalForAll",
});

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"transferFrom"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useSimulatePanopticFactoryTransferFrom = /*#__PURE__*/ createUseSimulateContract({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  functionName: "transferFrom",
});

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link panopticFactoryAbi}__ and `functionName` set to `"uniswapV3MintCallback"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useSimulatePanopticFactoryUniswapV3MintCallback =
  /*#__PURE__*/ createUseSimulateContract({
    abi: panopticFactoryAbi,
    address: panopticFactoryAddress,
    functionName: "uniswapV3MintCallback",
  });

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link panopticFactoryAbi}__
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useWatchPanopticFactoryEvent = /*#__PURE__*/ createUseWatchContractEvent({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
});

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link panopticFactoryAbi}__ and `eventName` set to `"Approval"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useWatchPanopticFactoryApprovalEvent = /*#__PURE__*/ createUseWatchContractEvent({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  eventName: "Approval",
});

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link panopticFactoryAbi}__ and `eventName` set to `"ApprovalForAll"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useWatchPanopticFactoryApprovalForAllEvent = /*#__PURE__*/ createUseWatchContractEvent(
  {
    abi: panopticFactoryAbi,
    address: panopticFactoryAddress,
    eventName: "ApprovalForAll",
  },
);

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link panopticFactoryAbi}__ and `eventName` set to `"PoolDeployed"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useWatchPanopticFactoryPoolDeployedEvent = /*#__PURE__*/ createUseWatchContractEvent({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  eventName: "PoolDeployed",
});

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link panopticFactoryAbi}__ and `eventName` set to `"Transfer"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xD958AE206C2243CbcC579e11937937E2C71D127F)
 */
export const useWatchPanopticFactoryTransferEvent = /*#__PURE__*/ createUseWatchContractEvent({
  abi: panopticFactoryAbi,
  address: panopticFactoryAddress,
  eventName: "Transfer",
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticPoolAbi}__
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useReadPanopticPool = /*#__PURE__*/ createUseReadContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"assertMinCollateralValues"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useReadPanopticPoolAssertMinCollateralValues = /*#__PURE__*/ createUseReadContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "assertMinCollateralValues",
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"calculateAccumulatedFeesBatch"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useReadPanopticPoolCalculateAccumulatedFeesBatch = /*#__PURE__*/ createUseReadContract(
  {
    abi: panopticPoolAbi,
    address: panopticPoolAddress,
    functionName: "calculateAccumulatedFeesBatch",
  },
);

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"calculatePortfolioValue"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useReadPanopticPoolCalculatePortfolioValue = /*#__PURE__*/ createUseReadContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "calculatePortfolioValue",
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"collateralToken0"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useReadPanopticPoolCollateralToken0 = /*#__PURE__*/ createUseReadContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "collateralToken0",
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"collateralToken1"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useReadPanopticPoolCollateralToken1 = /*#__PURE__*/ createUseReadContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "collateralToken1",
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"numberOfPositions"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useReadPanopticPoolNumberOfPositions = /*#__PURE__*/ createUseReadContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "numberOfPositions",
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"optionPositionBalance"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useReadPanopticPoolOptionPositionBalance = /*#__PURE__*/ createUseReadContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "optionPositionBalance",
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"supportsInterface"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useReadPanopticPoolSupportsInterface = /*#__PURE__*/ createUseReadContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "supportsInterface",
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"univ3pool"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useReadPanopticPoolUniv3pool = /*#__PURE__*/ createUseReadContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "univ3pool",
});

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"validateCollateralWithdrawable"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useReadPanopticPoolValidateCollateralWithdrawable =
  /*#__PURE__*/ createUseReadContract({
    abi: panopticPoolAbi,
    address: panopticPoolAddress,
    functionName: "validateCollateralWithdrawable",
  });

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link panopticPoolAbi}__
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useWritePanopticPool = /*#__PURE__*/ createUseWriteContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
});

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"burnOptions"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useWritePanopticPoolBurnOptions = /*#__PURE__*/ createUseWriteContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "burnOptions",
});

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"forceExercise"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useWritePanopticPoolForceExercise = /*#__PURE__*/ createUseWriteContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "forceExercise",
});

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"liquidate"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useWritePanopticPoolLiquidate = /*#__PURE__*/ createUseWriteContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "liquidate",
});

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"mintOptions"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useWritePanopticPoolMintOptions = /*#__PURE__*/ createUseWriteContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "mintOptions",
});

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"multicall"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useWritePanopticPoolMulticall = /*#__PURE__*/ createUseWriteContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "multicall",
});

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"onERC1155BatchReceived"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useWritePanopticPoolOnErc1155BatchReceived = /*#__PURE__*/ createUseWriteContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "onERC1155BatchReceived",
});

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"onERC1155Received"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useWritePanopticPoolOnErc1155Received = /*#__PURE__*/ createUseWriteContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "onERC1155Received",
});

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"pokeMedian"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useWritePanopticPoolPokeMedian = /*#__PURE__*/ createUseWriteContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "pokeMedian",
});

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"settleLongPremium"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useWritePanopticPoolSettleLongPremium = /*#__PURE__*/ createUseWriteContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "settleLongPremium",
});

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"startPool"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useWritePanopticPoolStartPool = /*#__PURE__*/ createUseWriteContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "startPool",
});

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link panopticPoolAbi}__
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useSimulatePanopticPool = /*#__PURE__*/ createUseSimulateContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
});

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"burnOptions"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useSimulatePanopticPoolBurnOptions = /*#__PURE__*/ createUseSimulateContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "burnOptions",
});

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"forceExercise"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useSimulatePanopticPoolForceExercise = /*#__PURE__*/ createUseSimulateContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "forceExercise",
});

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"liquidate"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useSimulatePanopticPoolLiquidate = /*#__PURE__*/ createUseSimulateContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "liquidate",
});

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"mintOptions"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useSimulatePanopticPoolMintOptions = /*#__PURE__*/ createUseSimulateContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "mintOptions",
});

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"multicall"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useSimulatePanopticPoolMulticall = /*#__PURE__*/ createUseSimulateContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "multicall",
});

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"onERC1155BatchReceived"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useSimulatePanopticPoolOnErc1155BatchReceived =
  /*#__PURE__*/ createUseSimulateContract({
    abi: panopticPoolAbi,
    address: panopticPoolAddress,
    functionName: "onERC1155BatchReceived",
  });

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"onERC1155Received"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useSimulatePanopticPoolOnErc1155Received = /*#__PURE__*/ createUseSimulateContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "onERC1155Received",
});

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"pokeMedian"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useSimulatePanopticPoolPokeMedian = /*#__PURE__*/ createUseSimulateContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "pokeMedian",
});

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"settleLongPremium"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useSimulatePanopticPoolSettleLongPremium = /*#__PURE__*/ createUseSimulateContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "settleLongPremium",
});

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link panopticPoolAbi}__ and `functionName` set to `"startPool"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useSimulatePanopticPoolStartPool = /*#__PURE__*/ createUseSimulateContract({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  functionName: "startPool",
});

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link panopticPoolAbi}__
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useWatchPanopticPoolEvent = /*#__PURE__*/ createUseWatchContractEvent({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
});

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link panopticPoolAbi}__ and `eventName` set to `"AccountLiquidated"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useWatchPanopticPoolAccountLiquidatedEvent = /*#__PURE__*/ createUseWatchContractEvent(
  {
    abi: panopticPoolAbi,
    address: panopticPoolAddress,
    eventName: "AccountLiquidated",
  },
);

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link panopticPoolAbi}__ and `eventName` set to `"ForcedExercised"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useWatchPanopticPoolForcedExercisedEvent = /*#__PURE__*/ createUseWatchContractEvent({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  eventName: "ForcedExercised",
});

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link panopticPoolAbi}__ and `eventName` set to `"OptionBurnt"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useWatchPanopticPoolOptionBurntEvent = /*#__PURE__*/ createUseWatchContractEvent({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  eventName: "OptionBurnt",
});

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link panopticPoolAbi}__ and `eventName` set to `"OptionMinted"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useWatchPanopticPoolOptionMintedEvent = /*#__PURE__*/ createUseWatchContractEvent({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  eventName: "OptionMinted",
});

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link panopticPoolAbi}__ and `eventName` set to `"PremiumSettled"`
 *
 * [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xBe46576F0f5c40D33130C13FF067ed08DA2eCd08)
 */
export const useWatchPanopticPoolPremiumSettledEvent = /*#__PURE__*/ createUseWatchContractEvent({
  abi: panopticPoolAbi,
  address: panopticPoolAddress,
  eventName: "PremiumSettled",
});
