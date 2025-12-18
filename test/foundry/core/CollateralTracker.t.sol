// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Foundry
import "forge-std/Test.sol";
// Panoptic Core
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManagerV4.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {RiskEngine} from "@contracts/RiskEngine.sol";
import {BuilderWallet} from "@contracts/RiskEngine.sol";
import {BuilderFactory} from "@contracts/RiskEngine.sol";
import {PanopticHelper} from "@test_periphery/PanopticHelper.sol";

// Panoptic Libraries
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {Math} from "@libraries/PanopticMath.sol";
import {Errors} from "@libraries/Errors.sol";
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {TokenId} from "@types/TokenId.sol";
import {MarketState} from "@types/MarketState.sol";
import {OraclePack} from "@types/OraclePack.sol";
import {LiquidityChunk} from "@types/LiquidityChunk.sol";
import {RiskParameters} from "@types/RiskParameters.sol";
import {PositionBalance, PositionBalanceLibrary} from "@types/PositionBalance.sol";
import {Constants} from "@libraries/Constants.sol";
// Panoptic Interfaces
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
// Uniswap - Panoptic's version 0.8
import {FullMath} from "v3-core/libraries/FullMath.sol";
// Uniswap Libraries
import {TransferHelper} from "v3-periphery/libraries/TransferHelper.sol";
import {FixedPoint96} from "v3-core/libraries/FixedPoint96.sol";
import {PoolAddress} from "v3-periphery/libraries/PoolAddress.sol";
import {TickMath} from "v3-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
// Uniswap Interfaces
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {ISwapRouter} from "v3-periphery/interfaces/ISwapRouter.sol";
import {ISemiFungiblePositionManager} from "@contracts/interfaces/ISemiFungiblePositionManager.sol";
// V4 types
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {V4StateReader} from "@libraries/V4StateReader.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {V4RouterSimple} from "../testUtils/V4RouterSimple.sol";

import {PositionUtils, MiniPositionManager} from "../testUtils/PositionUtils.sol";

// CollateralTracker with extended functionality intended to expose internal data
contract CollateralTrackerHarness is CollateralTracker, PositionUtils, MiniPositionManager {
    //constructor() CollateralTracker(10, 2_000, 1_000, -1_024, 5_000, 9_000) {}
    constructor() CollateralTracker(10) {
        bytes32 slot = keccak256("panoptic.utilization.snapshot");
        assembly {
            tstore(slot, 0)
        }
    }

    // whether the token has been initialized already or not
    function initalized() external view returns (bool) {
        return s_initialized;
    }

    function _inAMM() external view returns (uint256) {
        return s_assetsInAMM;
    }

    function _poolAssets() external view returns (uint256) {
        return s_depositedAssets;
    }

    function _marketState() external view returns (uint256) {
        return MarketState.unwrap(s_marketState);
    }

    function _totalAssets() external view returns (uint256 totalManagedAssets) {
        return totalAssets();
    }

    function _availableAssets() external view returns (uint256) {
        return s_depositedAssets;
    }

    function burnShares(address owner, uint256 shares) external {
        _burn(owner, shares);
    }

    function mintShares(address owner, uint256 shares) external {
        _mint(owner, shares);
    }

    function setPoolAssets(uint256 amount) external {
        s_depositedAssets = uint128(amount);
    }

    function setTotalSupply(uint256 amount) external {
        _internalSupply = amount;
    }

    function setInAMM(int128 amount) external {
        s_assetsInAMM = uint128(int128(s_assetsInAMM) + amount);
    }

    function setCreditedShares(int256 amount) external {
        s_creditedShares = uint256(amount);
    }

    function setMarketState(uint256 amount) external {
        s_marketState = MarketState.wrap(amount);
    }

    function setBalance(address owner, uint256 amount) external {
        balanceOf[owner] = amount;
    }

    function poolUtilizationHook() external view returns (int128) {
        return int128(int256(_poolUtilizationView()));
    }

    function readUtilizationSlot() external view returns (uint128 u) {
        bytes32 slot = keccak256("panoptic.utilization.snapshot");
        assembly {
            u := tload(slot)
        }
    }

    function wipeUtilizationSlot() external {
        bytes32 slot = keccak256("panoptic.utilization.snapshot");
        assembly {
            tstore(slot, 0)
        }
    }
}

// Inherits all of PanopticPool's functionality, however uses a modified version of startPool
// which enables us to use our modified CollateralTracker harness that exposes internal data
contract PanopticPoolHarness is PanopticPool {
    constructor(
        SemiFungiblePositionManager _SFPM
    ) PanopticPool(ISemiFungiblePositionManager(address(_SFPM))) {}

    function delegate(address delegatee, CollateralTracker collateralToken) external {
        collateralToken.delegate(delegatee);
    }

    function refund(
        address delegator,
        address delegatee,
        int256 requestedAmount,
        CollateralTracker collateralToken
    ) external {
        collateralToken.refund(delegator, delegatee, requestedAmount);
    }

    function revoke(address delegatee, CollateralTracker collateralToken) external {
        collateralToken.revoke(delegatee);
    }

    function positionBalance(
        address account,
        TokenId tokenId
    ) external view returns (PositionBalance balanceAndUtilizations) {
        balanceAndUtilizations = s_positionBalance[account][tokenId];
    }

    function positionsHash(address user) external view returns (uint248 _positionsHash) {
        _positionsHash = uint248(s_positionsHash[user]);
    }

    function setPositionsHash(address user, uint256 hash) external {
        s_positionsHash[user] = hash;
    }

    function generatePositionsHash(TokenId[] memory positionIdList) external returns (uint256) {
        uint256 fingerprintIncomingList;
        uint256 pLength = positionIdList.length;

        for (uint256 i = 0; i < pLength; ++i) {
            fingerprintIncomingList = PanopticMath.updatePositionsHash(
                fingerprintIncomingList,
                positionIdList[i],
                true
            );
        }
        return fingerprintIncomingList;
    }

    function oraclePack() external returns (OraclePack) {
        return s_oraclePack;
    }
}

contract SemiFungiblePositionManagerHarness is SemiFungiblePositionManager {
    constructor(
        IPoolManager _manager
    ) SemiFungiblePositionManager(_manager, 10 ** 13, 10 ** 13, 0) {}

    function accountLiquidity(
        bytes32 positionKey
    ) external view returns (LeftRightUnsigned shortAndNetLiquidity) {
        return s_accountLiquidity[positionKey];
    }

    function __getPoolId(
        PoolId idV4,
        int24 tickSpacing,
        uint256 vegoid
    ) external view returns (uint64 poolId) {
        poolId = _getPoolId(idV4, tickSpacing, vegoid);
    }
}

contract RiskEngineHarness is RiskEngine {
    constructor(
        uint256 crossBuffer0,
        uint256 crossBuffer1,
        address guardian,
        address builderFactory
    ) RiskEngine(crossBuffer0, crossBuffer1, guardian, builderFactory) {}

    function getRequiredCollateralAtUtilization(
        uint128 amount,
        uint256 isLong,
        int16 utilization
    ) external view returns (uint256 required) {
        (required, ) = _getRequiredCollateralAtUtilization(amount, isLong, utilization);
    }

    function getRequiredCollateralAtTickSinglePosition(
        TokenId tokenId,
        uint128 positionSize,
        int24 atTick,
        int16 poolUtilization,
        bool underlyingIsToken0
    ) external view returns (uint256) {
        (uint256 tokensRequired, ) = _getRequiredCollateralAtTickSinglePosition(
            tokenId,
            positionSize,
            atTick,
            poolUtilization,
            underlyingIsToken0
        );
        return tokensRequired;
    }

    function getRequiredCollateralSingleLeg(
        TokenId tokenId,
        uint256 i,
        uint128 positionSize,
        int24 atTick,
        int16 poolUtilization
    ) external view returns (uint256) {
        return _getRequiredCollateralSingleLeg(tokenId, i, positionSize, atTick, poolUtilization);
    }

    function sellCollateralRatio(int256 utilization) external view returns (uint256) {
        return _sellCollateralRatio(utilization);
    }

    function buyCollateralRatio(int256 utilization) external view returns (uint256) {
        return _buyCollateralRatio();
    }
}

contract UniswapV3PoolMock {
    struct Slot0 {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        bool unlocked;
    }

    struct Info {
        // the total position liquidity that references this tick
        uint128 liquidityGross;
        // amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left),
        int128 liquidityNet;
        // fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        // the cumulative tick value on the other side of the tick
        int56 tickCumulativeOutside;
        // the seconds per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint160 secondsPerLiquidityOutsideX128;
        // the seconds spent on the other side of the tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint32 secondsOutside;
        // true iff the tick is initialized, i.e. the value is exactly equivalent to the expression liquidityGross != 0
        // these 8 bits are set to prevent fresh sstores when crossing newly initialized ticks
        bool initialized;
    }

    Slot0 public slot0;
    mapping(int24 => Info) public ticks;
    int24 public tickSpacing;

    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    constructor(int24 _tickSpacing) {
        tickSpacing = _tickSpacing;
    }

    // helper to set info for the given tick
    function setInfo(
        int24 tick,
        uint256 _feeGrowthOutside0X128,
        uint256 _feeGrowthOutside1X128
    ) external {
        Info storage info = ticks[tick];

        info.feeGrowthOutside0X128 = _feeGrowthOutside0X128;
        info.feeGrowthOutside1X128 = _feeGrowthOutside1X128;
    }

    // directly tweak the fee growth values
    function setGlobal(uint256 _feeGrowthGlobal0X128, uint256 _feeGrowthGlobal1X128) external {
        feeGrowthGlobal0X128 = _feeGrowthGlobal0X128;
        feeGrowthGlobal1X128 = _feeGrowthGlobal1X128;
    }

    // allows dynamic setting of the current tick
    function setSlot0(int24 _tick) external {
        slot0.tick = _tick;
        slot0.sqrtPriceX96 = TickMath.getSqrtRatioAtTick(_tick);
    }
}

contract Attacker {
    CollateralTracker internal collateralToken;
    IERC20Partial internal underlyingToken;
    PanopticPool internal panopticPool;

    constructor(CollateralTracker _collateral, IERC20Partial _token, PanopticPool _panopticPool) {
        collateralToken = _collateral;
        underlyingToken = _token;
        panopticPool = _panopticPool;
    }

    /// @notice This function performs the attack sequence in a single transaction
    function attackUtilizationRate(
        uint256 depositAmount,
        TokenId tokenId,
        uint128 positionSize
    ) public {
        // 1. Approve the collateral token to take the funds
        underlyingToken.approve(address(collateralToken), depositAmount);

        // 2. Deposit funds to ARTIFICIALLY LOWER utilization
        uint256 shares = collateralToken.deposit(depositAmount, address(this));

        // 3. Call the target function.
        // The new transient storage defense should be active here.
        // It should see the "real" utilization from before the deposit.
        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = tokenId;

        uint128[] memory sizeList = new uint128[](1);
        sizeList[0] = positionSize;

        int24[3][] memory tickAndSpreadLimits = new int24[3][](1);
        tickAndSpreadLimits[0][0] = Constants.MAX_POOL_TICK;
        tickAndSpreadLimits[0][1] = Constants.MIN_POOL_TICK;
        tickAndSpreadLimits[0][2] = int24(uint24(type(uint24).max));

        panopticPool.dispatch(posIdList, posIdList, sizeList, tickAndSpreadLimits, true, 0);

        (, , , , int256 u0, int256 u1, uint128 positionSize) = panopticPool.positionData(
            address(this),
            tokenId
        );

        // 4. Withdraw the funds immediately
        // We use redeem to pull out the exact shares we just minted
        collateralToken.withdraw(
            collateralToken.convertToAssets(collateralToken.balanceOf(address(this))) -
                positionSize,
            address(this),
            address(this),
            posIdList,
            true
        );
    }
}

contract CollateralTrackerTest is Test, PositionUtils {
    using Math for uint256;

    event Donate(address indexed sender, uint256 shares);

    // users who will send/receive deposits, transfers, and withdrawals
    address Alice = makeAddr("Alice");
    address Bob = makeAddr("Bob");
    address Charlie = makeAddr("Charlie");
    address Swapper = makeAddr("Swapper");

    /*//////////////////////////////////////////////////////////////
                           MAINNET CONTRACTS
    //////////////////////////////////////////////////////////////*/

    IUniswapV3Pool constant USDC_WETH_5 =
        IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);

    IUniswapV3Pool constant USDC_WETH_100 =
        IUniswapV3Pool(0x7BeA39867e4169DBe237d55C8242a8f2fcDcc387);

    IUniswapV3Pool constant WBTC_ETH_30 =
        IUniswapV3Pool(0xCBCdF9626bC03E24f779434178A73a0B4bad62eD);

    IUniswapV3Pool constant MATIC_ETH_30 =
        IUniswapV3Pool(0x290A6a7460B308ee3F19023D2D00dE604bcf5B42);

    // 1 bps pool
    IUniswapV3Pool constant DAI_USDC_1 = IUniswapV3Pool(0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168);

    IUniswapV3Pool constant WSTETH_ETH_1 =
        IUniswapV3Pool(0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa);

    IUniswapV3Pool[6] public pools = [
        USDC_WETH_5,
        USDC_WETH_100,
        WBTC_ETH_30,
        MATIC_ETH_30,
        DAI_USDC_1,
        WSTETH_ETH_1
    ];

    // Mainnet factory address
    IUniswapV3Factory V3FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

    // Mainnet router address - used for swaps
    ISwapRouter router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    // Mainnet WETH address
    address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // granted token amounts
    uint256 constant initialMockTokens = type(uint112).max;

    /*//////////////////////////////////////////////////////////////
                              WORLD STATE
    //////////////////////////////////////////////////////////////*/

    // store some data about the pool we are testing
    IUniswapV3Pool pool;
    uint64 poolId;
    uint8 vegoid = 4;
    uint256 isWETH;
    address token0;
    address token1;
    uint24 fee;
    int24 tickSpacing;
    int24 currentTick;
    uint160 currentSqrtPriceX96;
    uint256 feeGrowthGlobal0X128;
    uint256 feeGrowthGlobal1X128;

    // Current instance of Panoptic Pool, CollateralTokens, and SFPM
    PanopticPoolHarness panopticPool;
    address panopticPoolAddress;
    RiskEngineHarness riskEngine;
    BuilderFactory builderFactory;
    PanopticHelper panopticHelper;
    SemiFungiblePositionManagerHarness sfpm;
    CollateralTrackerHarness collateralToken0;
    CollateralTrackerHarness collateralToken1;

    IPoolManager manager;

    V4RouterSimple routerV4;

    PoolKey poolKey;

    /*//////////////////////////////////////////////////////////////
                            POSITION DATA
    //////////////////////////////////////////////////////////////*/

    uint128 positionSize0;
    uint128 positionSize1;
    uint128[] sizeList;
    TokenId[] mintList;
    TokenId[] positionIdList1;
    TokenId[] positionIdList;
    TokenId tokenId;
    TokenId tokenId1;

    // Positional details
    int24 width;
    int24 strike;
    int24 width1;
    int24 strike1;
    int24 rangeDown0;
    int24 rangeUp0;
    int24 rangeDown1;
    int24 rangeUp1;
    int24 legLowerTick;
    int24 legUpperTick;
    uint160 sqrtRatioAX96;
    uint160 sqrtRatioBX96;

    // Collateral
    int64 utilization;
    uint256 sellCollateralRatio;
    uint256 buyCollateralRatio;

    // notional / contracts
    uint128 notionalMoved;
    LeftRightUnsigned amountsMoved;
    LeftRightUnsigned amountsMovedPartner;
    uint256 movedRight;
    uint256 movedLeft;
    uint256 movedPartnerRight;
    uint256 movedPartnerLeft;

    // risk status
    int24 baseStrike;
    int24 partnerStrike;
    uint256 partnerIndex;
    uint256 tokenType;
    uint256 tokenTypeP;
    uint256 isLong;
    uint256 isLongP;

    // liquidity
    LiquidityChunk liquidityChunk;
    uint256 liquidity;

    uint256 balanceData0;
    uint256 thresholdData0;

    LeftRightUnsigned $longPremia;
    LeftRightUnsigned $shortPremia;

    PositionBalance[] posBalanceArray;

    uint128 DECIMALS = 10_000_000;
    int128 DECIMALS128 = 10_000_000;

    function mintOptions(
        PanopticPool pp,
        TokenId[] memory positionIdList,
        uint128 positionSize,
        uint24 effectiveLiquidityLimitX32,
        int24 tickLimitLow,
        int24 tickLimitHigh,
        bool premiaAsCollateral
    ) internal {
        uint128[] memory sizeList = new uint128[](1);
        TokenId[] memory mintList = new TokenId[](1);
        int24[3][] memory tickAndSpreadLimits = new int24[3][](1);

        TokenId tokenId = positionIdList[positionIdList.length - 1];
        sizeList[0] = positionSize;
        mintList[0] = tokenId;
        tickAndSpreadLimits[0][0] = tickLimitLow;
        tickAndSpreadLimits[0][1] = tickLimitHigh;
        tickAndSpreadLimits[0][2] = int24(uint24(effectiveLiquidityLimitX32));

        pp.dispatch(mintList, positionIdList, sizeList, tickAndSpreadLimits, premiaAsCollateral, 0);
        collateralToken0.wipeUtilizationSlot();
        collateralToken1.wipeUtilizationSlot();
    }

    function mintOptions(
        PanopticPool pp,
        TokenId[] memory positionIdList,
        uint128 positionSize,
        uint24 effectiveLiquidityLimitX32,
        int24 tickLimitLow,
        int24 tickLimitHigh,
        bool premiaAsCollateral,
        uint256 builderCode
    ) internal {
        uint128[] memory sizeList = new uint128[](1);
        TokenId[] memory mintList = new TokenId[](1);
        int24[3][] memory tickAndSpreadLimits = new int24[3][](1);

        TokenId tokenId = positionIdList[positionIdList.length - 1];
        sizeList[0] = positionSize;
        mintList[0] = tokenId;
        tickAndSpreadLimits[0][0] = tickLimitLow;
        tickAndSpreadLimits[0][1] = tickLimitHigh;
        tickAndSpreadLimits[0][2] = int24(uint24(effectiveLiquidityLimitX32));

        pp.dispatch(
            mintList,
            positionIdList,
            sizeList,
            tickAndSpreadLimits,
            premiaAsCollateral,
            builderCode
        );
        collateralToken0.wipeUtilizationSlot();
        collateralToken1.wipeUtilizationSlot();
    }

    function burnOptions(
        PanopticPool pp,
        TokenId tokenId,
        TokenId[] memory positionIdList,
        int24 tickLimitLow,
        int24 tickLimitHigh,
        bool premiaAsCollateral
    ) internal {
        uint128[] memory sizeList = new uint128[](1);
        TokenId[] memory burnList = new TokenId[](1);
        int24[3][] memory tickAndSpreadLimits = new int24[3][](1);

        sizeList[0] = 0;
        burnList[0] = tokenId;
        tickAndSpreadLimits[0][0] = tickLimitLow;
        tickAndSpreadLimits[0][1] = tickLimitHigh;
        tickAndSpreadLimits[0][2] = int24(uint24(type(uint24).max));
        pp.dispatch(burnList, positionIdList, sizeList, tickAndSpreadLimits, premiaAsCollateral, 0);
        collateralToken0.wipeUtilizationSlot();
        collateralToken1.wipeUtilizationSlot();
    }

    function burnOptions(
        PanopticPool pp,
        TokenId[] memory tokenIds,
        TokenId[] memory positionIdList,
        int24 tickLimitLow,
        int24 tickLimitHigh,
        bool premiaAsCollateral
    ) internal {
        uint128[] memory sizeList = new uint128[](tokenIds.length);
        int24[3][] memory tickAndSpreadLimits = new int24[3][](tokenIds.length);

        for (uint256 i; i < tokenIds.length; ++i) {
            tickAndSpreadLimits[i][0] = tickLimitLow;
            tickAndSpreadLimits[i][1] = tickLimitHigh;
            tickAndSpreadLimits[i][2] = int24(uint24(type(uint24).max));
        }

        pp.dispatch(tokenIds, positionIdList, sizeList, tickAndSpreadLimits, premiaAsCollateral, 0);
        collateralToken0.wipeUtilizationSlot();
        collateralToken1.wipeUtilizationSlot();
    }

    function burnOptions(
        PanopticPool pp,
        TokenId[] memory tokenIds,
        TokenId[] memory positionIdList,
        int24 tickLimitLow,
        int24 tickLimitHigh,
        bool premiaAsCollateral,
        uint256 builderCode
    ) internal {
        uint128[] memory sizeList = new uint128[](tokenIds.length);
        int24[3][] memory tickAndSpreadLimits = new int24[3][](tokenIds.length);

        for (uint256 i; i < tokenIds.length; ++i) {
            tickAndSpreadLimits[i][0] = tickLimitLow;
            tickAndSpreadLimits[i][1] = tickLimitHigh;
            tickAndSpreadLimits[i][2] = int24(uint24(type(uint24).max));
        }

        pp.dispatch(
            tokenIds,
            positionIdList,
            sizeList,
            tickAndSpreadLimits,
            premiaAsCollateral,
            builderCode
        );
        collateralToken0.wipeUtilizationSlot();
        collateralToken1.wipeUtilizationSlot();
    }

    function liquidate(
        PanopticPool pp,
        TokenId[] memory liquidatorList,
        address liquidatee,
        TokenId[] memory positionIdList
    ) internal {
        uint128[] memory sizeList = new uint128[](1);
        collateralToken0.wipeUtilizationSlot();
        collateralToken1.wipeUtilizationSlot();

        pp.dispatchFrom(
            liquidatorList,
            liquidatee,
            positionIdList,
            new TokenId[](0),
            LeftRightUnsigned.wrap(0).addToRightSlot(1).addToLeftSlot(1)
        );
        collateralToken0.wipeUtilizationSlot();
        collateralToken1.wipeUtilizationSlot();
    }

    function forceExercise(
        PanopticPool pp,
        address exercisee,
        TokenId tokenId,
        TokenId[] memory exerciseeList,
        TokenId[] memory exercisorList,
        LeftRightUnsigned premiaAsCollateral
    ) internal {
        uint128[] memory sizeList = new uint128[](1);

        TokenId[] memory targetList = new TokenId[](1);
        collateralToken0.wipeUtilizationSlot();
        collateralToken1.wipeUtilizationSlot();

        pp.dispatchFrom(
            exercisorList,
            exercisee,
            targetList,
            exerciseeList,
            LeftRightUnsigned.wrap(0).addToRightSlot(1).addToLeftSlot(1)
        );
        collateralToken0.wipeUtilizationSlot();
        collateralToken1.wipeUtilizationSlot();
    }

    function settlePremium(
        PanopticPool pp,
        TokenId[] memory settlerList,
        TokenId[] memory settleeList,
        address exercisee,
        uint256 legIndex,
        bool premiaAsCollateral
    ) internal {
        uint128[] memory sizeList = new uint128[](1);

        TokenId[] memory targetList = new TokenId[](1);

        pp.dispatchFrom(
            settlerList,
            exercisee,
            targetList,
            settleeList,
            LeftRightUnsigned.wrap(0).addToRightSlot(1).addToLeftSlot(1)
        );
        collateralToken0.wipeUtilizationSlot();
        collateralToken1.wipeUtilizationSlot();
    }

    function _initWorld(uint256 seed) internal {
        // Pick a pool from the seed and cache initial state
        _cacheWorldState(pools[bound(seed, 0, pools.length - 1)]);

        _deployCustomPanopticPool(token0, token1, pool);
    }

    function _cacheWorldState(IUniswapV3Pool _pool) internal {
        pool = _pool;
        token0 = _pool.token0();
        token1 = _pool.token1();
        isWETH = token0 == address(WETH) ? 0 : 1;
        fee = _pool.fee();
        tickSpacing = _pool.tickSpacing();
        (currentSqrtPriceX96, currentTick, , , , , ) = _pool.slot0();
        feeGrowthGlobal0X128 = _pool.feeGrowthGlobal0X128();
        feeGrowthGlobal1X128 = _pool.feeGrowthGlobal1X128();
        poolKey = PoolKey(
            Currency.wrap(token0),
            Currency.wrap(token1),
            fee,
            tickSpacing,
            IHooks(address(0))
        );
        {
            poolId = uint40(uint256(PoolId.unwrap(poolKey.toId()))) + uint64(uint256(vegoid) << 40);
            poolId += uint64(uint24(_pool.tickSpacing())) << 48;
        }
    }

    function _deployCustomPanopticPool(
        address _token0,
        address _token1,
        IUniswapV3Pool uniswapPool // must already exist and be initialized
    ) internal {
        manager = new PoolManager(address(0));
        routerV4 = new V4RouterSimple(manager);

        vm.startPrank(Swapper);

        deal(token0, Swapper, type(uint248).max);
        deal(token1, Swapper, type(uint248).max);

        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);

        IERC20Partial(token0).approve(address(routerV4), type(uint256).max);
        IERC20Partial(token1).approve(address(routerV4), type(uint256).max);

        manager.initialize(poolKey, currentSqrtPriceX96);

        routerV4.modifyLiquidity(
            address(0),
            poolKey,
            (TickMath.MIN_TICK / tickSpacing) * tickSpacing,
            (TickMath.MAX_TICK / tickSpacing) * tickSpacing,
            1_000_000 ether
        );

        // deploy the semiFungiblePositionManager
        sfpm = new SemiFungiblePositionManagerHarness(manager);

        address t0 = address(uint160(poolKey.currency0.toId()));
        address t1 = address(uint160(poolKey.currency1.toId()));
        // Initialize the world pool
        uint64 poolId = sfpm.initializeAMMPool(poolKey, vegoid);

        // 2) Risk engine
        riskEngine = new RiskEngineHarness(10_000_000, 10_000_000, address(0), address(0));

        console2.log("manager address", address(manager));
        console2.log("riskEngineAddress", address(riskEngine));
        panopticHelper = new PanopticHelper(ISemiFungiblePositionManager(address(sfpm)));

        vm.startPrank(address(this));
        // 4) Deterministic salt like the factory (deployer + pool + risk + user salt=0)
        bytes32 salt = bytes32(
            abi.encodePacked(
                uint80(uint160(address(this)) >> 80),
                uint40(uint256(PoolId.unwrap(poolKey.toId())) >> 120),
                uint40(uint160(address(riskEngine)) >> 120),
                uint96(0)
            )
        );
        PanopticPoolHarness predictedPool = PanopticPoolHarness(
            ClonesWithImmutableArgs.addressOfClone3(salt)
        );

        CollateralTrackerHarness collateralImpl = new CollateralTrackerHarness();

        collateralToken0 = new CollateralTrackerHarness();
        collateralToken1 = new CollateralTrackerHarness();

        // 6) Clone collateral trackers with immutables
        collateralToken0 = CollateralTrackerHarness(
            ClonesWithImmutableArgs.clone2(
                address(collateralImpl),
                abi.encodePacked(
                    predictedPool, // panopticPool
                    true, // is0
                    t0, // token0
                    t0, // ct.token0()
                    t1, // ct.token1()
                    riskEngine, // risk engine
                    manager, // pool manager
                    fee // pool fee
                )
            )
        );

        collateralToken1 = CollateralTrackerHarness(
            ClonesWithImmutableArgs.clone2(
                address(collateralImpl),
                abi.encodePacked(
                    predictedPool, // panopticPool
                    false, // is0
                    t1, // token1
                    t0, // ct.token0()
                    t1, // ct.token1()
                    riskEngine, // risk engine
                    manager, // pool manager
                    fee // pool fee
                )
            )
        );

        panopticPool = new PanopticPoolHarness(sfpm);

        panopticPool = PanopticPoolHarness(
            ClonesWithImmutableArgs.clone3(
                address(panopticPool),
                abi.encodePacked(
                    collateralToken0,
                    collateralToken1,
                    riskEngine,
                    manager,
                    poolId,
                    abi.encode(poolKey)
                ),
                salt
            )
        );

        vm.startPrank(Swapper);

        panopticPool.initialize();

        collateralToken0.initialize();
        collateralToken1.initialize();

        // store panoptic pool address
        panopticPoolAddress = address(panopticPool);

        // 9) Helpers wiring for tests
        panopticPoolAddress = address(panopticPool);
        vm.stopPrank();
    }

    function _deployCustomPanopticPool(
        address _token0,
        address _token1,
        IUniswapV3Pool uniswapPool, // must already exist and be initialized
        uint256 crossBuffer0,
        uint256 crossBuffer1
    ) internal {
        manager = new PoolManager(address(0));
        routerV4 = new V4RouterSimple(manager);

        vm.startPrank(Swapper);

        deal(token0, Swapper, type(uint248).max);
        deal(token1, Swapper, type(uint248).max);

        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);

        IERC20Partial(token0).approve(address(routerV4), type(uint256).max);
        IERC20Partial(token1).approve(address(routerV4), type(uint256).max);

        manager.initialize(poolKey, currentSqrtPriceX96);

        routerV4.modifyLiquidity(
            address(0),
            poolKey,
            (TickMath.MIN_TICK / tickSpacing) * tickSpacing,
            (TickMath.MAX_TICK / tickSpacing) * tickSpacing,
            1_000_000 ether
        );

        // deploy the semiFungiblePositionManager
        sfpm = new SemiFungiblePositionManagerHarness(manager);

        address t0 = address(uint160(poolKey.currency0.toId()));
        address t1 = address(uint160(poolKey.currency1.toId()));
        // Initialize the world pool
        uint64 poolId = sfpm.initializeAMMPool(poolKey, vegoid);

        // 2) Risk engine
        riskEngine = new RiskEngineHarness(crossBuffer0, crossBuffer1, address(0), address(0));

        panopticHelper = new PanopticHelper(ISemiFungiblePositionManager(address(sfpm)));

        vm.startPrank(address(this));
        // 4) Deterministic salt like the factory (deployer + pool + risk + user salt=0)
        bytes32 salt = bytes32(
            abi.encodePacked(
                uint80(uint160(address(this)) >> 80),
                uint40(uint256(PoolId.unwrap(poolKey.toId())) >> 120),
                uint40(uint160(address(riskEngine)) >> 120),
                uint96(0)
            )
        );
        PanopticPoolHarness predictedPool = PanopticPoolHarness(
            ClonesWithImmutableArgs.addressOfClone3(salt)
        );

        CollateralTrackerHarness collateralImpl = new CollateralTrackerHarness();

        collateralToken0 = new CollateralTrackerHarness();
        collateralToken1 = new CollateralTrackerHarness();

        // 6) Clone collateral trackers with immutables
        collateralToken0 = CollateralTrackerHarness(
            ClonesWithImmutableArgs.clone2(
                address(collateralImpl),
                abi.encodePacked(
                    predictedPool, // panopticPool
                    true, // is0
                    t0, // token0
                    t0, // ct.token0()
                    t1, // ct.token1()
                    riskEngine, // risk engine
                    manager, // pool manager
                    fee // pool fee
                )
            )
        );

        collateralToken1 = CollateralTrackerHarness(
            ClonesWithImmutableArgs.clone2(
                address(collateralImpl),
                abi.encodePacked(
                    predictedPool, // panopticPool
                    false, // is0
                    t1, // token1
                    t0, // ct.token0()
                    t1, // ct.token1()
                    riskEngine, // risk engine
                    manager, // pool manager
                    fee // pool fee
                )
            )
        );

        panopticPool = new PanopticPoolHarness(sfpm);

        panopticPool = PanopticPoolHarness(
            ClonesWithImmutableArgs.clone3(
                address(panopticPool),
                abi.encodePacked(
                    collateralToken0,
                    collateralToken1,
                    riskEngine,
                    manager,
                    poolId,
                    abi.encode(poolKey)
                ),
                salt
            )
        );

        vm.startPrank(Swapper);

        panopticPool.initialize();

        collateralToken0.initialize();
        collateralToken1.initialize();

        // store panoptic pool address
        panopticPoolAddress = address(panopticPool);

        // 9) Helpers wiring for tests
        panopticPoolAddress = address(panopticPool);
    }

    function _deployCustomPanopticPool(
        address _token0,
        address _token1,
        IUniswapV3Pool uniswapPool, // must already exist and be initialized
        address guardian
    ) internal {
        manager = new PoolManager(address(0));
        routerV4 = new V4RouterSimple(manager);

        vm.startPrank(Swapper);

        deal(token0, Swapper, type(uint248).max);
        deal(token1, Swapper, type(uint248).max);

        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);

        IERC20Partial(token0).approve(address(routerV4), type(uint256).max);
        IERC20Partial(token1).approve(address(routerV4), type(uint256).max);

        manager.initialize(poolKey, currentSqrtPriceX96);

        routerV4.modifyLiquidity(
            address(0),
            poolKey,
            (TickMath.MIN_TICK / tickSpacing) * tickSpacing,
            (TickMath.MAX_TICK / tickSpacing) * tickSpacing,
            1_000_000 ether
        );

        // deploy the semiFungiblePositionManager
        sfpm = new SemiFungiblePositionManagerHarness(manager);

        address t0 = address(uint160(poolKey.currency0.toId()));
        address t1 = address(uint160(poolKey.currency1.toId()));
        // Initialize the world pool
        uint64 poolId = sfpm.initializeAMMPool(poolKey, vegoid);

        // 2) Risk engine
        builderFactory = new BuilderFactory(guardian);

        riskEngine = new RiskEngineHarness(10_000, 10_000, guardian, address(builderFactory));

        console2.log("builderFactoryAddr", address(builderFactory));

        panopticHelper = new PanopticHelper(ISemiFungiblePositionManager(address(sfpm)));

        vm.startPrank(address(this));
        // 4) Deterministic salt like the factory (deployer + pool + risk + user salt=0)
        bytes32 salt = bytes32(
            abi.encodePacked(
                uint80(uint160(address(this)) >> 80),
                uint40(uint256(PoolId.unwrap(poolKey.toId())) >> 120),
                uint40(uint160(address(riskEngine)) >> 120),
                uint96(0)
            )
        );
        PanopticPoolHarness predictedPool = PanopticPoolHarness(
            ClonesWithImmutableArgs.addressOfClone3(salt)
        );

        CollateralTrackerHarness collateralImpl = new CollateralTrackerHarness();

        collateralToken0 = new CollateralTrackerHarness();
        collateralToken1 = new CollateralTrackerHarness();

        // 6) Clone collateral trackers with immutables
        collateralToken0 = CollateralTrackerHarness(
            ClonesWithImmutableArgs.clone2(
                address(collateralImpl),
                abi.encodePacked(
                    predictedPool, // panopticPool
                    true, // is0
                    t0, // token0
                    t0, // ct.token0()
                    t1, // ct.token1()
                    riskEngine, // risk engine
                    manager, // pool manager
                    fee // pool fee
                )
            )
        );

        collateralToken1 = CollateralTrackerHarness(
            ClonesWithImmutableArgs.clone2(
                address(collateralImpl),
                abi.encodePacked(
                    predictedPool, // panopticPool
                    false, // is0
                    t1, // token1
                    t0, // ct.token0()
                    t1, // ct.token1()
                    riskEngine, // risk engine
                    manager, // pool manager
                    fee // pool fee
                )
            )
        );

        panopticPool = new PanopticPoolHarness(sfpm);

        panopticPool = PanopticPoolHarness(
            ClonesWithImmutableArgs.clone3(
                address(panopticPool),
                abi.encodePacked(
                    collateralToken0,
                    collateralToken1,
                    riskEngine,
                    manager,
                    poolId,
                    abi.encode(poolKey)
                ),
                salt
            )
        );

        vm.startPrank(Swapper);

        panopticPool.initialize();

        collateralToken0.initialize();
        collateralToken1.initialize();

        // store panoptic pool address
        panopticPoolAddress = address(panopticPool);

        // 9) Helpers wiring for tests
        panopticPoolAddress = address(panopticPool);
    }

    function _grantTokens(address recipient) internal {
        // give sender the max amount of underlying tokens
        deal(token0, recipient, initialMockTokens);
        deal(token1, recipient, initialMockTokens);
        assertEq(IERC20Partial(token0).balanceOf(recipient), initialMockTokens);
        assertEq(IERC20Partial(token1).balanceOf(recipient), initialMockTokens);
    }

    function _mockMaxDeposit(address recipient) internal {
        // award corresponding shares
        deal(
            address(collateralToken0),
            recipient,
            collateralToken0.previewDeposit(initialMockTokens),
            true
        );
        deal(
            address(collateralToken1),
            recipient,
            collateralToken1.previewDeposit(initialMockTokens),
            true
        );

        // equal deposits for both collateral token pairs for testing purposes
        // deposit to panoptic pool
        collateralToken0.setPoolAssets(collateralToken0._availableAssets() + initialMockTokens);
        collateralToken1.setPoolAssets(collateralToken1._availableAssets() + initialMockTokens);

        (, address pranked, ) = vm.readCallers();
        vm.startPrank(Swapper);
        routerV4.mintCurrency(address(0), Currency.wrap(token0), initialMockTokens);
        routerV4.mintCurrency(address(0), Currency.wrap(token1), initialMockTokens);

        manager.transfer(address(panopticPool), uint160(token0), initialMockTokens);
        manager.transfer(address(panopticPool), uint160(token1), initialMockTokens);

        vm.startPrank(pranked);

        manager.transfer(address(0), 0, 0);
    }

    //@note move this and panopticPool helper into position utils
    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    // used to accumulate premia for testing
    function twoWaySwap(uint256 swapSize) public {
        vm.startPrank(Swapper);

        deal(token0, Swapper, type(uint248).max);
        deal(token1, Swapper, type(uint248).max);

        IERC20Partial(token0).approve(address(router), type(uint256).max);
        IERC20Partial(token1).approve(address(router), type(uint256).max);

        swapSize = bound(swapSize, 10 ** 18, 10 ** 22);
        router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams(
                isWETH == 0 ? token0 : token1,
                isWETH == 1 ? token0 : token1,
                fee,
                address(0x23),
                block.timestamp,
                swapSize,
                0,
                0
            )
        );
        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();
        console2.log("ct0", currentSqrtPriceX96);

        router.exactOutputSingle(
            ISwapRouter.ExactOutputSingleParams(
                isWETH == 1 ? token0 : token1,
                isWETH == 0 ? token0 : token1,
                fee,
                address(0x23),
                block.timestamp,
                (swapSize * (1_000_000 - fee)) / 1_000_000,
                type(uint256).max,
                0
            )
        );

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();
        console2.log("ct1", currentSqrtPriceX96);
    }

    function setUp() public {}

    /*//////////////////////////////////////////////////////////////
                        START TOKEN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Success_StartToken_virtualShares() public {
        _initWorld(0);
        CollateralTracker ct = new CollateralTracker(10);
        ct.initialize();

        assertEq(ct.totalSupply(), 10 ** 6);
        assertEq(ct.totalAssets(), 1);
    }

    function test_Fail_startToken_alreadyInitializedToken(uint256 x) public {
        _initWorld(x);

        // Deploy collateral token
        collateralToken0 = new CollateralTrackerHarness();

        // initialize the token
        collateralToken0.initialize();

        // fails if already initialized
        vm.expectRevert(Errors.CollateralTokenAlreadyInitialized.selector);
        collateralToken0.initialize();
    }

    /*//////////////////////////////////////////////////////////////
                        INTEREST ACCRUAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Success_accrueInterest_oneBlock() public {
        _initWorld(0);
        uint256 startingTime = block.timestamp;
        uint128 initialBorrowIndex = 1e18;
        collateralToken0.setPoolAssets(500);
        collateralToken0.setInAMM(500);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12 seconds);

        uint128 perSecondInterestRate = collateralToken0.interestRate();
        collateralToken0.accrueInterest();
        // Calculate the expected new borrow index
        uint256 interestForPeriod = Math.wTaylorCompounded(uint256(perSecondInterestRate), 12);
        uint256 expectedNewIndex = Math.mulDivWadRoundingUp(
            initialBorrowIndex,
            1e18 + interestForPeriod
        );
        uint256 unrealizedGlobalInterest = Math.mulDivWadRoundingUp(
            collateralToken0._inAMM(),
            interestForPeriod
        );

        uint256 expectedAccumulator = (unrealizedGlobalInterest << 150) +
            (collateralToken0.rateAtTarget() << 112) +
            (((startingTime + 12) >> 2) << 80) +
            expectedNewIndex;

        // Get the actual new accumulator value from the contract
        uint256 actualAccumulator = collateralToken0._marketState();

        // Assert they are equal
        assertEq(
            actualAccumulator,
            expectedAccumulator,
            "Interest did not accrue correctly for one block"
        );
    }

    function test_Success_accrueInterest_IRM() public {
        _initWorld(0);
        uint256 startingTime = block.timestamp;
        uint128 initialBorrowIndex = 1e18;
        collateralToken0.setPoolAssets(500);
        collateralToken0.setInAMM(500);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12 seconds);

        uint128 perSecondInterestRate = collateralToken0.interestRate();
        collateralToken0.accrueInterest();
        // Calculate the expected new borrow index
        uint256 interestForPeriod = Math.wTaylorCompounded(uint256(perSecondInterestRate), 12);
        uint256 expectedNewIndex = Math.mulDivWadRoundingUp(
            initialBorrowIndex,
            1e18 + interestForPeriod
        );
        uint256 unrealizedGlobalInterest = Math.mulDivWadRoundingUp(
            collateralToken0._inAMM(),
            interestForPeriod
        );

        uint256 expectedAccumulator = (unrealizedGlobalInterest << 150) +
            (collateralToken0.rateAtTarget() << 112) +
            (((startingTime + 12) >> 2) << 80) +
            expectedNewIndex;

        // Get the actual new accumulator value from the contract
        uint256 actualAccumulator = collateralToken0._marketState();

        // Assert they are equal
        assertEq(
            actualAccumulator,
            expectedAccumulator,
            "Interest did not accrue correctly for one block"
        );

        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 1200 seconds);
        collateralToken0.accrueInterest();
    }

    function test_Success_accrueInterest_loop() public {
        vm.warp(2 ** 32 - 10);
        _initWorld(0);
        uint256 startingTime = block.timestamp;
        uint128 initialBorrowIndex = 1e18;
        collateralToken0.setPoolAssets(500);
        collateralToken0.setInAMM(500);
        collateralToken0.accrueInterest();

        vm.warp(4 * 2 ** 32 + 10);

        uint128 perSecondInterestRate = collateralToken0.interestRate();
        collateralToken0.accrueInterest();
        // Calculate the expected new borrow index
        uint256 interestForPeriod = Math.wTaylorCompounded(uint256(perSecondInterestRate), 20);
        uint256 expectedNewIndex = Math.mulDivWadRoundingUp(
            initialBorrowIndex,
            1e18 + interestForPeriod
        );
        uint256 unrealizedGlobalInterest = Math.mulDivWadRoundingUp(
            collateralToken0._inAMM(),
            interestForPeriod
        );

        uint256 expectedAccumulator = (unrealizedGlobalInterest << 150) +
            (collateralToken0.rateAtTarget() << 112) +
            uint128((uint256(uint32(startingTime + 20) >> 2) << 80) + expectedNewIndex);

        // Get the actual new accumulator value from the contract
        uint256 actualAccumulator = collateralToken0._marketState();

        console2.log("collateralToken0.rateAtTarget()", collateralToken0.rateAtTarget());
        // Assert they are equal
        assertEq(
            actualAccumulator,
            expectedAccumulator,
            "Interest did not accrue correctly for one block"
        );
    }

    function test_Success_accrueInterest_multipleBlocks(uint32 blocksToSkip) public {
        _initWorld(0);
        uint256 startingTime = block.timestamp;
        uint128 initialBorrowIndex = 1e18; // Set by _initWorld's call to startToken
        collateralToken0.setPoolAssets(500);
        collateralToken0.setInAMM(500);

        // Ensure we are actually skipping blocks.
        vm.assume(blocksToSkip > 0 && blocksToSkip < 1_000_000);

        vm.roll(block.number + blocksToSkip);
        vm.warp(block.timestamp + 12 * blocksToSkip);
        uint128 perSecondInterestRate = collateralToken0.interestRate();
        collateralToken0.accrueInterest();

        // Calculate the total linear interest for the entire period.
        uint256 interestForPeriod = Math.wTaylorCompounded(
            uint256(perSecondInterestRate),
            blocksToSkip * 12
        );

        // Calculate the expected new borrow index by applying the total interest.
        uint256 expectedNewIndex = Math.mulDivWadRoundingUp(
            initialBorrowIndex,
            1e18 + interestForPeriod
        );

        uint256 unrealizedGlobalInterest = Math.mulDivWadRoundingUp(
            collateralToken0._inAMM(),
            interestForPeriod
        );

        // Construct the full expected accumulator value for the new block.
        uint256 expectedAccumulator = (unrealizedGlobalInterest << 150) +
            (collateralToken0.rateAtTarget() << 112) +
            (((startingTime + blocksToSkip * 12) >> 2) << 80) +
            expectedNewIndex;

        // Get the actual new accumulator value from the contract.
        uint256 actualAccumulator = collateralToken0._marketState();

        //  Assert they are equal.
        assertEq(
            actualAccumulator,
            expectedAccumulator,
            "Interest did not accrue correctly for multiple blocks"
        );
    }

    function test_Success_accrueInterest_deposits() public {
        _initWorld(0);
        uint104 assets = 1000 ether; // Use a fixed deposit amount

        // Get the initial borrow index right after initialization
        uint256 initialAccumulator = collateralToken0._marketState() % 2 ** 80;
        uint80 initialBorrowIndex = uint80(collateralToken0._marketState());

        // --- Alice deposits ---
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Alice);
        vm.stopPrank();

        // --- Bob deposits ---
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Bob);
        vm.stopPrank();

        // Check that the interest rate is zero.
        uint128 currentRate = collateralToken0.interestRate();

        // Get the final borrow index.
        uint128 finalAccumulator = uint128(collateralToken0._marketState()) % 2 ** 80;

        // 4. Assert that the index has not changed from its initial value.
        assertEq(
            finalAccumulator,
            initialAccumulator,
            "FAIL: Borrow index should not change when only deposits are made"
        );

        uint128 amountToBorrow = assets / 10;
        collateralToken0.setPoolAssets(
            collateralToken0._availableAssets() - uint128(amountToBorrow)
        );
        collateralToken0.setInAMM(int128(amountToBorrow));

        uint256 blockAfterBorrow = block.number;
        uint256 timestampAfterBorrow = block.timestamp;

        uint32 blocksToSkip = 7200;
        vm.roll(blockAfterBorrow + blocksToSkip);
        vm.warp(timestampAfterBorrow + 12 * blocksToSkip);
        console2.log("read rate");
        uint128 perSecondInterestRate = collateralToken0.interestRate();
        console2.log("perS1", perSecondInterestRate);
        console2.log("");
        console2.log("accrueInterest rate");
        collateralToken0.accrueInterest();

        assertGt(perSecondInterestRate, 0, "FAIL: Rate should be positive after borrow");

        // Calculate the expected interest for the period.
        uint256 interestForPeriod = Math.wTaylorCompounded(
            uint256(perSecondInterestRate),
            ((blocksToSkip * 12) >> 2) << 2
        );
        uint256 expectedNewIndex = Math.mulDivWadRoundingUp(
            initialBorrowIndex,
            1e18 + interestForPeriod
        );

        uint256 unrealizedGlobalInterest = Math.mulDivWadRoundingUp(
            collateralToken0._inAMM(),
            interestForPeriod
        );

        console2.log(
            "perSecondInterestRate, interestForPeriod",
            perSecondInterestRate,
            interestForPeriod
        );
        // Construct the full expected accumulator value.
        uint256 expectedAccumulator = (unrealizedGlobalInterest << 150) +
            (collateralToken0.rateAtTarget() << 112) +
            (((timestampAfterBorrow + blocksToSkip * 12) >> 2) << 80) +
            expectedNewIndex;
        uint256 actualAccumulator = collateralToken0._marketState();

        // 4. Assert the final state is correct.
        assertEq(
            actualAccumulator,
            expectedAccumulator,
            "FAIL: Interest did not accrue correctly after borrow was made"
        );
    }

    // This is the new test function
    function test_Success_Defend_FlashDeposit_mintOptions() public {
        _initWorld(0);
        uint104 assets = 1000 ether; // Total LP assets

        // --- Alice and Bob deposit to provide initial liquidity ---
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Alice);
        vm.stopPrank();

        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Bob);
        vm.stopPrank();

        // --- Set up HIGH UTILIZATION state ---
        // We set 80% of the pool to be "in the AMM" (i.e., borrowed)
        uint128 totalPoolAssets = uint128(collateralToken0.totalAssets());
        uint128 amountToBorrow = (totalPoolAssets * 8) / 10; // 80% utilization
        collateralToken0.setPoolAssets(totalPoolAssets - amountToBorrow);
        collateralToken0.setInAMM(int128(amountToBorrow));

        // Check that utilization is high and rate is positive
        (, , , uint256 utilization) = collateralToken0.getPoolData();

        uint256 preAttackUtilization = utilization;
        uint128 preAttackRate = collateralToken0.interestRate();
        assertGe(preAttackUtilization, 8000, "FAIL: Utilization should be ~80%");
        assertGt(preAttackRate, 0, "FAIL: Rate should be positive");

        // --- Warp time forward to accrue interest ---
        uint256 blockAfterBorrow = block.number;
        uint256 timestampAfterBorrow = block.timestamp;
        uint32 blocksToSkip = 7200;
        vm.roll(blockAfterBorrow + blocksToSkip);
        vm.warp(timestampAfterBorrow + 12 * blocksToSkip);

        // Fund the attacker with a massive amount of tokens
        uint256 attackDepositAmount = 1_000_000 ether;

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();

        strike = 198600 + 6000;
        width = 2;

        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        // --- 1. CALCULATE EXPECTED RESULT (No attack) ---
        // This is what the accumulator SHOULD be, based on the high utilization rate

        uint256 snapshot = vm.snapshot();
        {
            vm.startPrank(Alice);

            // 1. Approve the collateral token to take the funds
            IERC20Partial(token0).approve(address(collateralToken0), attackDepositAmount);
            // 2. Deposit funds to ARTIFICIALLY LOWER utilization

            uint256 shares = collateralToken0.deposit(attackDepositAmount, Alice);
            collateralToken0.wipeUtilizationSlot();

            (, , , utilization) = collateralToken0.getPoolData();
            uint256 postDepositUtilization = utilization;
            uint128 postDepositRate = collateralToken0.interestRate();

            assertLe(postDepositUtilization, 20, "FAIL: Utilization should be <0.2%");
            assertGt(preAttackRate, postDepositRate, "FAIL: Rate should be lower after deposit");
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12 seconds);

            // 3. Call the target function.
            // The new transient storage defense should NOT be active here.
            // It should see the "real" utilization from before the deposit.
            uint128 _assets = assets / 2;
            console2.log("mint");
            mintOptions(
                panopticPool,
                positionIdList,
                _assets,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );
            collateralToken0.wipeUtilizationSlot();

            console2.log("get u");
            (, , , , int256 u0, int256 u1, uint128 positionSize) = panopticPool.positionData(
                Alice,
                tokenId
            );
            console2.log("burn");
            burnOptions(
                panopticPool,
                positionIdList,
                new TokenId[](0),
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );
            collateralToken0.wipeUtilizationSlot();

            assertLe(u0, 21, "FAIL: utilization is less than 0.2% 1");

            // 4. Withdraw the funds immediately
            // We use redeem to pull out the exact shares we just minted
            //collateralToken0.redeem(shares, Alice, Alice);
        }

        uint256 expectedAccumulator = collateralToken0._marketState();

        vm.stopPrank();
        vm.revertTo(snapshot);
        // --- 2. RUN THE ATTACK ---
        (, , , utilization) = collateralToken0.getPoolData();

        preAttackUtilization = utilization;
        assertEq(preAttackUtilization, 8000, "FAIL: Utilization should be at 80%");
        console2.log("preAttack", preAttackUtilization);
        Attacker attacker = new Attacker(collateralToken0, IERC20Partial(token0), panopticPool);

        _grantTokens(address(attacker));

        // Prank as the attacker and run the attack function
        vm.prank(address(attacker));
        uint128 _assets = assets;
        attacker.attackUtilizationRate(attackDepositAmount, tokenId, _assets / 2);
        (, , , , int256 u0, int256 u1, uint128 positionSize) = panopticPool.positionData(
            address(attacker),
            tokenId
        );
        assertGe(u0, 8000, "FAIL: utilization is more than 80%");
        // --- 3. ASSERT THE RESULT ---
        // The transient storage should have protected the state.
        // The final accumulator should match the one we calculated
        // using the *high* utilization rate.
        uint256 attackAccumulator = collateralToken0._marketState();

        assertTrue(
            attackAccumulator != expectedAccumulator,
            "FAIL: Attack was successful! Accumulator was manipulated."
        );
    }

    function test_Success_accrueInterest_mints() public {
        _initWorld(0);
        uint104 assets = 1000 ether; // Use a fixed deposit amount

        // Get the initial borrow index right after initialization
        uint128 initialBorrowIndex = uint80(collateralToken0._marketState());

        // --- Alice deposits ---
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Alice);
        IERC20Partial(token1).approve(address(collateralToken1), assets);
        collateralToken1.deposit(assets, Alice);
        vm.stopPrank();

        // --- Bob deposits + Mints ---
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Bob);

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();

        strike = 198600 + 6000;
        width = 2;

        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        console2.log("mintOptions 1st");
        mintOptions(
            panopticPool,
            positionIdList,
            assets / 2,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.stopPrank();

        // --- Move forward by 1 day ---

        uint256 blockAfterBorrow = block.number;
        uint256 timestampAfterBorrow = block.timestamp;

        uint32 blocksToSkip = 7200;
        console2.log("roll 1 day");
        vm.roll(blockAfterBorrow + blocksToSkip);
        vm.warp(timestampAfterBorrow + blocksToSkip * 12);

        uint128 perSecondInterestRate = collateralToken0.interestRate();
        assertGt(perSecondInterestRate, 0, "FAIL: Rate should be positive after borrow");
        collateralToken0.accrueInterest();

        // Calculate the expected interest for the period.
        uint256 interestForPeriod = Math.wTaylorCompounded(
            uint256(perSecondInterestRate),
            blocksToSkip * 12
        );
        uint256 expectedNewIndex = Math.mulDivWadRoundingUp(
            initialBorrowIndex,
            1e18 + interestForPeriod
        );

        uint256 unrealizedGlobalInterest = Math.mulDivWadRoundingUp(
            collateralToken0._inAMM(),
            interestForPeriod
        );
        // Construct the full expected accumulator value.
        uint256 expectedAccumulator = (unrealizedGlobalInterest << 150) +
            (collateralToken0.rateAtTarget() << 112) +
            (((timestampAfterBorrow + blocksToSkip * 12) >> 2) << 80) +
            expectedNewIndex;
        uint256 actualAccumulator = collateralToken0._marketState();

        // 4. Assert the final state is correct.
        assertEq(
            actualAccumulator,
            expectedAccumulator,
            "FAIL: Interest did not accrue correctly after borrow was made"
        );

        // --- Mints Again ---

        vm.startPrank(Bob);
        console2.log(
            collateralToken0.previewRedeem(collateralToken0.balanceOf(Alice)),
            collateralToken0.previewRedeem(collateralToken0.balanceOf(Bob))
        );

        strike = 198600 + 12000;
        width = 2;

        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        console2.log("mintOptions 2nd");
        mintOptions(
            panopticPool,
            positionIdList,
            assets / 4,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        actualAccumulator = collateralToken0._marketState();

        uint256 unrealizedGlobalInterestAfter = actualAccumulator >> 150;

        assertEq(unrealizedGlobalInterestAfter, 0, "FAIL: unrealized interest is not zero");

        // --- Move forward by 1 day ---

        blockAfterBorrow = block.number;
        timestampAfterBorrow = block.timestamp;

        blocksToSkip = 7200;
        vm.roll(blockAfterBorrow + blocksToSkip);
        vm.warp(timestampAfterBorrow + blocksToSkip * 12);

        console2.log("burnOptions", Bob);

        burnOptions(
            panopticPool,
            positionIdList,
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        console2.log("DONE", Bob);
        actualAccumulator = collateralToken0._marketState();
        unrealizedGlobalInterestAfter = actualAccumulator >> 150;
        assertEq(unrealizedGlobalInterestAfter, 0, "FAIL: unrealized interest is not zero");

        console2.log(
            collateralToken0.previewRedeem(collateralToken0.balanceOf(Alice)),
            collateralToken0.previewRedeem(collateralToken0.balanceOf(Bob))
        );
        console2.log(uint128(actualAccumulator), collateralToken0.totalAssets());
        vm.stopPrank();
    }

    function test_Success_accrueInterest_mintlong() public {
        _initWorld(0);
        uint104 assets = 1000 ether; // Use a fixed deposit amount

        // Get the initial borrow index right after initialization
        uint128 initialBorrowIndex = uint80(collateralToken0._marketState());

        // --- Alice deposits ---
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Alice);
        IERC20Partial(token1).approve(address(collateralToken1), assets);
        collateralToken1.deposit(assets, Alice);
        vm.stopPrank();

        // --- Bob deposits ---
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Bob);

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();

        strike = 198600 + 6000;
        width = 2;

        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        // Bob sell assets/2
        mintOptions(
            panopticPool,
            positionIdList,
            assets,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.stopPrank();

        // Alice buys assets/4
        vm.startPrank(Alice);
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 1, 0, 0, strike, width);
        positionIdList1.push(tokenId);
        mintOptions(
            panopticPool,
            positionIdList1,
            assets / 2,
            type(uint24).max,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.stopPrank();

        uint256 blockAfterBorrow = block.number;
        uint256 timestampAfterBorrow = block.timestamp;

        uint32 blocksToSkip = 7200 * 365;
        vm.roll(blockAfterBorrow + blocksToSkip);
        vm.warp(timestampAfterBorrow + blocksToSkip * 12);
        console2.log("before accru", uint128(collateralToken0._marketState()));
        uint128 perSecondInterestRate = collateralToken0.interestRate();
        assertGt(perSecondInterestRate, 0, "FAIL: Rate should be positive after borrow");
        collateralToken0.accrueInterest();
        console2.log("after accru", uint128(collateralToken0._marketState()));

        {
            (, , , uint256 utilization) = collateralToken0.getPoolData();
            assertGt(utilization, 0, "FAIL: Utilization should be positive after borrow");
        }

        // 2. Calculate the expected interest for the period.
        uint256 interestForPeriod = Math.wTaylorCompounded(
            uint256(perSecondInterestRate),
            blocksToSkip * 12
        );
        uint256 expectedNewIndex = Math.mulDivWadRoundingUp(
            initialBorrowIndex,
            1e18 + interestForPeriod
        );

        uint256 unrealizedGlobalInterest = Math.mulDivWadRoundingUp(
            collateralToken0._inAMM(),
            interestForPeriod
        );

        // 3. Construct the full expected accumulator value.
        uint256 expectedAccumulator = (unrealizedGlobalInterest << 150) +
            (collateralToken0.rateAtTarget() << 112) +
            (((timestampAfterBorrow + blocksToSkip * 12) >> 2) << 80) +
            expectedNewIndex;
        uint256 actualAccumulator = collateralToken0._marketState();

        // 4. Assert the final state is correct.
        assertEq(
            actualAccumulator,
            expectedAccumulator,
            "FAIL: Interest did not accrue correctly after borrow was made"
        );
        console2.log(
            "aa",
            collateralToken0.totalAssets(),
            collateralToken0.previewRedeem(collateralToken0.balanceOf(Alice)),
            collateralToken0.previewRedeem(collateralToken0.balanceOf(Bob))
        );
        vm.startPrank(Alice);
        burnOptions(
            panopticPool,
            positionIdList1,
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        console2.log(
            "bb",
            collateralToken0.totalAssets(),
            collateralToken0.previewRedeem(collateralToken0.balanceOf(Alice)),
            collateralToken0.previewRedeem(collateralToken0.balanceOf(Bob))
        );
        vm.stopPrank();

        vm.startPrank(Bob);

        burnOptions(
            panopticPool,
            positionIdList,
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        console2.log(
            "cc",
            collateralToken0.totalAssets(),
            collateralToken0.previewRedeem(collateralToken0.balanceOf(Alice)),
            collateralToken0.previewRedeem(collateralToken0.balanceOf(Bob))
        );
        vm.stopPrank();
    }

    function test_Success_accrueInterest_negativeborrow() public {
        _initWorld(0);
        uint104 assets = 1000 ether; // Use a fixed deposit amount

        // Get the initial borrow index right after initialization
        uint128 initialBorrowIndex = uint128(uint80(collateralToken0._marketState()));

        // --- Alice deposits ---
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Alice);
        IERC20Partial(token1).approve(address(collateralToken1), assets);
        collateralToken1.deposit(assets, Alice);

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();

        strike = 198600 + 12000;
        width = 2;

        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList1.push(tokenId);
        console2.log("");
        console2.log("");
        console2.log("Alice mints");

        // Alice sell assets/2
        mintOptions(
            panopticPool,
            positionIdList1,
            assets / 2,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.stopPrank();

        // --- Bob deposits ---
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Bob);

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();

        strike = 198600 + 6000;
        width = 2;

        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);
        console2.log("");
        console2.log("");
        console2.log("Bob mints");

        // Bob sell assets/4
        mintOptions(
            panopticPool,
            positionIdList,
            assets / 8,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        strike = 198600 + 12000;

        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 1, 0, 0, strike, width);
        positionIdList.push(tokenId);

        // Bob buys assets/2
        mintOptions(
            panopticPool,
            positionIdList,
            assets / 4,
            type(uint24).max,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        vm.stopPrank();

        uint256 blockAfterBorrow = block.number;
        uint256 timestampAfterBorrow = block.timestamp;

        uint32 blocksToSkip = 7200 * 365;
        vm.roll(blockAfterBorrow + blocksToSkip);
        vm.warp(timestampAfterBorrow + blocksToSkip * 12);
        console2.log("before accru", uint128(collateralToken0._marketState()));
        uint128 perSecondInterestRate = collateralToken0.interestRate();
        assertGt(perSecondInterestRate, 0, "FAIL: Rate should be positive after borrow");

        collateralToken0.accrueInterest();
        console2.log("after accru", uint128(collateralToken0._marketState()));

        {
            (, , , uint256 utilization) = collateralToken0.getPoolData();
            assertGt(utilization, 0, "FAIL: Utilization should be positive after borrow");
        }

        // 2. Calculate the expected interest for the period.
        uint256 interestForPeriod = Math.wTaylorCompounded(
            uint256(perSecondInterestRate),
            blocksToSkip * 12
        );
        uint256 expectedNewIndex = Math.mulDivWadRoundingUp(
            initialBorrowIndex,
            1e18 + interestForPeriod
        );
        uint256 unrealizedGlobalInterest = Math.mulDivWadRoundingUp(
            collateralToken0._inAMM(),
            interestForPeriod
        );
        console2.log("collateralToken0.rateAtTarget()", collateralToken0.rateAtTarget());
        // 3. Construct the full expected accumulator value.
        uint256 expectedAccumulator = (unrealizedGlobalInterest << 150) +
            (uint256(collateralToken0.rateAtTarget()) << 112) +
            (((timestampAfterBorrow + blocksToSkip * 12) >> 2) << 80) +
            expectedNewIndex;
        uint256 actualAccumulator = (collateralToken0._marketState());

        // 4. Assert the final state is correct.
        assertEq(
            actualAccumulator,
            expectedAccumulator,
            "FAIL: Interest did not accrue correctly after borrow was made 1"
        );
        console2.log(
            "aa",
            collateralToken0.totalAssets(),
            collateralToken0.previewRedeem(collateralToken0.balanceOf(Alice)),
            collateralToken0.previewRedeem(collateralToken0.balanceOf(Bob))
        );
        vm.startPrank(Bob);

        console2.log("");
        console2.log("");
        console2.log("Bob Burns");
        burnOptions(
            panopticPool,
            positionIdList,
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        console2.log(
            "bb",
            collateralToken0.totalAssets(),
            collateralToken0.previewRedeem(collateralToken0.balanceOf(Alice)),
            collateralToken0.previewRedeem(collateralToken0.balanceOf(Bob))
        );
        vm.stopPrank();
        console2.log("");
        console2.log("");
        console2.log("Alice Burns");

        vm.startPrank(Alice);
        burnOptions(
            panopticPool,
            positionIdList1,
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        console2.log(
            "cc",
            collateralToken0.totalAssets(),
            collateralToken0.previewRedeem(collateralToken0.balanceOf(Alice)),
            collateralToken0.previewRedeem(collateralToken0.balanceOf(Bob))
        );
        vm.stopPrank();
    }

    function test_Success_accrueInterest_smallBalance() public {
        _initWorld(0);
        uint104 assets = 1000 ether; // Use a fixed deposit amount

        // Get the initial borrow index right after initialization
        uint128 initialBorrowIndex = uint80(collateralToken0._marketState());

        // --- Alice deposits ---
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Alice);
        IERC20Partial(token1).approve(address(collateralToken1), assets);
        collateralToken1.deposit(assets, Alice);
        vm.stopPrank();

        // --- Bob deposits ---
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Bob);

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();

        strike = 198600 + 6000;
        width = 2;

        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        // Bob sell assets/2
        mintOptions(
            panopticPool,
            positionIdList,
            1,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        vm.stopPrank();

        (int128 baseIndexBefore, int128 netBorrowsBefore) = collateralToken0.interestState(Bob);

        assertEq(netBorrowsBefore, 1);

        uint256 blockAfterBorrow = block.number;
        uint256 timestampAfterBorrow = block.timestamp;

        uint32 blocksToSkip = 1;
        uint256 blockTime = 12;
        vm.roll(blockAfterBorrow + blocksToSkip);
        vm.warp(timestampAfterBorrow + blocksToSkip * blockTime);

        uint128 perSecondInterestRate = collateralToken0.interestRate();
        collateralToken0.accrueInterest();
        (int128 baseIndexAfter, int128 netBorrowsAfter) = collateralToken0.interestState(Bob);

        assertTrue(baseIndexAfter == baseIndexBefore, "FAIL: Bob's base index increased");

        // 2. Calculate the expected interest for the period.
        uint256 interestForPeriod = Math.wTaylorCompounded(
            uint256(perSecondInterestRate),
            blocksToSkip * blockTime
        );
        uint256 expectedNewIndex = Math.mulDivWadRoundingUp(
            initialBorrowIndex,
            1e18 + interestForPeriod
        );

        uint256 unrealizedGlobalInterest = Math.mulDivWadRoundingUp(
            collateralToken0._inAMM(),
            interestForPeriod
        );

        // 3. Construct the full expected accumulator value.
        uint256 expectedAccumulator = (unrealizedGlobalInterest << 150) +
            (collateralToken0.rateAtTarget() << 112) +
            (((timestampAfterBorrow + blocksToSkip * blockTime) >> 2) << 80) +
            expectedNewIndex;
        uint256 actualAccumulator = collateralToken0._marketState();

        // 4. Assert the final state is correct.
        assertEq(
            actualAccumulator,
            expectedAccumulator,
            "FAIL: Interest did not accrue correctly after borrow was made"
        );

        vm.startPrank(Bob);
        {
            (baseIndexBefore, netBorrowsBefore) = collateralToken0.interestState(Bob);
            uint256 balanceBobBefore = collateralToken0.balanceOf(Bob);
            // pay Bob's interest
            collateralToken0.accrueInterest();
            (baseIndexAfter, netBorrowsAfter) = collateralToken0.interestState(Bob);
            uint256 balanceBobAfter = collateralToken0.balanceOf(Bob);

            console2.log("bak;", balanceBobAfter, balanceBobBefore);
            assertTrue(balanceBobAfter < balanceBobBefore, "FAIL: Bob's balance did not decrease");

            assertTrue(
                collateralToken0.convertToAssets(balanceBobBefore - balanceBobAfter) > 0,
                "FAIL: Bob did not burn at least 1 share"
            );
        }

        assertTrue(baseIndexAfter > baseIndexBefore, "FAIL: Bob's base index did not increased");

        actualAccumulator = collateralToken0._marketState();

        assertEq(actualAccumulator >> 150, 0, "FAIL: still outstanding interest");
        assertEq(actualAccumulator % 2 ** 80, expectedNewIndex, "Fail: wrong index");
    }

    function testFuzz_accrueInterest_smallValues(
        uint8 borrowAmount,
        uint64 userInitialAssets,
        uint32 deltaTime
    ) public {
        // 1. SETUP
        console2.log("deltaTime", deltaTime);
        vm.assume(deltaTime > 4); // Interest only accrues over time, at least 1 epoch in the future.
        vm.assume(deltaTime < 2 ** 32 - 4);
        vm.assume(
            uint256(userInitialAssets) > Math.mulDivRoundingUp(4, uint256(borrowAmount), 3) + 3
        );

        _initWorld(0);
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), 1 ether);
        collateralToken0.deposit(1 ether, Alice);
        vm.stopPrank();

        // Have Bob make a small, fuzzed borrow.
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), type(uint104).max);
        collateralToken0.deposit(userInitialAssets, Bob);

        if (borrowAmount > 0) {
            (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();

            strike = 198600 + 6000;
            width = 2;

            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
            positionIdList.push(tokenId);

            console2.log("a");
            mintOptions(
                panopticPool,
                positionIdList,
                borrowAmount,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );
            console2.log("b");
        }

        (int128 baseIndexBefore, ) = collateralToken0.interestState(Bob);
        uint256 balanceBefore = collateralToken0.balanceOf(Bob);

        // 2. ACTION: Time passes and interest is accrued.
        vm.warp(block.timestamp + deltaTime);
        collateralToken0.accrueInterest(); // Settle Bob's interest.
        vm.stopPrank();

        // 3. ASSERT INVARIANTS
        (int128 baseIndexAfter, ) = collateralToken0.interestState(Bob);
        uint256 balanceAfter = collateralToken0.balanceOf(Bob);
        uint256 sharesOwed = collateralToken0.convertToShares(collateralToken0.owedInterest(Bob));

        // Invariant 1: No reverts (implicitly tested by reaching this point).

        // Invariant 2: No free lunch. Balance should not increase.
        assertTrue(balanceAfter <= balanceBefore, "FAIL: User gained shares by borrowing");

        // Invariant 4: Solvency logic must hold.
        if (borrowAmount > 0) {
            if (balanceBefore >= sharesOwed) {
                // SOLVENT: Base index must be updated.
                console2.log("baseIndexBefore", baseIndexBefore);
                console2.log("baseIndexAfter", baseIndexAfter);
                assertTrue(
                    baseIndexAfter > baseIndexBefore,
                    "FAIL: Solvent user index not updated"
                );

                // Invariant 3: Debt has a cost. If interest is owed, balance must drop.
                if (sharesOwed > 0) {
                    assertTrue(balanceAfter < balanceBefore, "FAIL: Solvent user paid no interest");
                }
            } else {
                // INSOLVENT: Base index must NOT be updated.
                assertTrue(
                    baseIndexAfter == baseIndexBefore,
                    "FAIL: Insolvent user index was updated"
                );
                // They should have been wiped out.
                assertEq(balanceAfter, 0, "FAIL: Insolvent user not wiped out");
            }
        } else {
            // If borrowAmount is 0, nothing should change.
            assertTrue(baseIndexAfter > baseIndexBefore, "FAIL: Index changed with no borrow");
            assertEq(balanceAfter, balanceBefore, "FAIL: Balance changed with no borrow");
        }
    }

    function test_Success_accrueInterest_concurrentBorrowers() public {
        _initWorld(0);
        uint104 assets = 1000 ether;
        // Setup initial liquidity
        vm.startPrank(Swapper);
        deal(token0, Swapper, type(uint104).max);
        deal(token1, Swapper, type(uint104).max);
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        collateralToken0.deposit(assets * 3, Swapper);
        vm.stopPrank();

        // Setup position parameters
        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();
        strike = 198600 + 6000;
        width = 2;
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        // Alice deposits and borrows 100 ether
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Alice);
        uint128 aliceBorrowAmount;
        {
            uint128 aliceSize = 100 ether;
            mintOptions(
                panopticPool,
                positionIdList,
                aliceSize,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );
            vm.stopPrank();
            LeftRightUnsigned _amountsMoved = PanopticMath.getAmountsMoved(
                tokenId,
                aliceSize,
                0,
                true
            );

            aliceBorrowAmount = _amountsMoved.rightSlot();
        }
        // Bob deposits and borrows 50 ether (half of Alice)
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Bob);

        uint128 bobBorrowAmount;
        {
            uint128 bobSize = 50 ether;
            mintOptions(
                panopticPool,
                positionIdList,
                bobSize,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );
            vm.stopPrank();
            LeftRightUnsigned _amountsMoved = PanopticMath.getAmountsMoved(
                tokenId,
                bobSize,
                0,
                true
            );

            bobBorrowAmount = _amountsMoved.rightSlot();
        }

        // Charlie deposits and borrows 50 ether (half of Alice)
        vm.startPrank(Charlie);
        _grantTokens(Charlie);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Charlie);

        uint128 charlieBorrowAmount;
        {
            uint128 charlieSize = 50 ether;
            mintOptions(
                panopticPool,
                positionIdList,
                charlieSize,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );
            vm.stopPrank();
            LeftRightUnsigned _amountsMoved = PanopticMath.getAmountsMoved(
                tokenId,
                charlieSize,
                0,
                true
            );

            charlieBorrowAmount = _amountsMoved.rightSlot();
        }

        uint256 initialTotalSupply = collateralToken0.totalSupply();

        // Record initial balances
        uint256 aliceInitialBalance = collateralToken0.balanceOf(Alice);
        uint256 bobInitialBalance = collateralToken0.balanceOf(Bob);
        uint256 charlieInitialBalance = collateralToken0.balanceOf(Charlie);

        {
            // Verify initial borrow states
            (int128 aliceInitIndex, int128 aliceNetBorrows) = collateralToken0.interestState(Alice);
            (int128 bobInitIndex, int128 bobNetBorrows) = collateralToken0.interestState(Bob);
            (int128 charlieInitIndex, int128 charlieNetBorrows) = collateralToken0.interestState(
                Charlie
            );

            assertEq(aliceNetBorrows, int128(aliceBorrowAmount), "Alice net borrows incorrect");
            assertEq(bobNetBorrows, int128(bobBorrowAmount), "Bob net borrows incorrect");
            assertEq(
                charlieNetBorrows,
                int128(charlieBorrowAmount),
                "Charlie net borrows incorrect"
            );
            assertEq(aliceInitIndex, bobInitIndex, "Initial indices should match");
            assertEq(bobInitIndex, charlieInitIndex, "Initial indices should match");
        }
        // Move forward 1 day
        uint256 timeJump = 1 days;
        vm.warp(block.timestamp + timeJump);

        // Alice accrues and pays interest
        vm.prank(Alice);
        collateralToken0.accrueInterest();

        uint256 aliceInterestPaid;
        {
            uint256 aliceFinalBalance = collateralToken0.balanceOf(Alice);
            aliceInterestPaid = collateralToken0.convertToAssets(
                aliceInitialBalance - aliceFinalBalance
            );
        }
        // Bob accrues and pays interest
        vm.prank(Bob);
        collateralToken0.accrueInterest();
        uint256 bobInterestPaid;
        {
            uint256 bobFinalBalance = collateralToken0.balanceOf(Bob);
            bobInterestPaid = collateralToken0.convertToAssets(bobInitialBalance - bobFinalBalance);
        }
        // Charlie accrues and pays interest
        vm.prank(Charlie);
        collateralToken0.accrueInterest();

        uint256 charlieInterestPaid;
        {
            uint256 charlieFinalBalance = collateralToken0.balanceOf(Charlie);
            charlieInterestPaid = collateralToken0.convertToAssets(
                charlieInitialBalance - charlieFinalBalance
            );
        }
        // Verify interest accounting is properly isolated
        console2.log(
            "Alice borrowed:",
            aliceBorrowAmount / 1e18,
            "ether, paid:",
            aliceInterestPaid
        );
        console2.log("Bob borrowed:", bobBorrowAmount / 1e18, "ether, paid:", bobInterestPaid);
        console2.log(
            "Charlie borrowed:",
            charlieBorrowAmount / 1e18,
            "ether, paid:",
            charlieInterestPaid
        );
        console2.log("Bob + Charlie combined interest:", bobInterestPaid + charlieInterestPaid);

        // Key assertion: Bob and Charlie's combined interest should equal Alice's
        // Since Bob + Charlie borrowed the same total amount as Alice for the same period
        assertApproxEqAbs(
            bobInterestPaid + charlieInterestPaid,
            aliceInterestPaid,
            1, // Small tolerance for rounding
            "Combined interest of Bob+Charlie should equal Alice's interest"
        );

        // Verify proportional interest: Bob and Charlie should pay equal amounts
        assertApproxEqAbs(
            bobInterestPaid,
            charlieInterestPaid,
            1, // Very small tolerance
            "Bob and Charlie should pay equal interest for equal borrows"
        );

        // Verify Alice paid approximately 2x what Bob paid
        assertApproxEqAbs(
            aliceInterestPaid,
            bobInterestPaid * 2,
            1,
            "Alice should pay 2x Bob's interest for 2x borrow"
        );

        {
            // Verify all users' indices are now current
            (int128 aliceFinalIndex, ) = collateralToken0.interestState(Alice);
            (int128 bobFinalIndex, ) = collateralToken0.interestState(Bob);
            (int128 charlieFinalIndex, ) = collateralToken0.interestState(Charlie);
            uint128 globalIndex = collateralToken0.borrowIndex();

            assertEq(uint128(aliceFinalIndex), globalIndex, "Alice index should be current");
            assertEq(uint128(bobFinalIndex), globalIndex, "Bob index should be current");
            assertEq(uint128(charlieFinalIndex), globalIndex, "Charlie index should be current");
        }
        // Test overlapping time periods with different accrual times
        vm.warp(block.timestamp + 1 days);

        // Only Bob accrues
        vm.prank(Bob);
        collateralToken0.accrueInterest();

        vm.warp(block.timestamp + 1 days);

        {
            // Verify Bob's index is ahead of Alice and Charlie
            (int128 bobIndexMid, ) = collateralToken0.interestState(Bob);
            (int128 aliceIndexMid, ) = collateralToken0.interestState(Alice);
            (int128 charlieIndexMid, ) = collateralToken0.interestState(Charlie);
            assertGt(bobIndexMid, aliceIndexMid, "Bob should have a more recent index than Alice");
            assertGt(
                bobIndexMid,
                charlieIndexMid,
                "Bob should have a more recent index than Charlie"
            );
        }

        // Bob and Charlie accrue after Alice
        vm.prank(Alice);
        collateralToken0.accrueInterest();
        vm.prank(Charlie);
        collateralToken0.accrueInterest();
        {
            // Verify Bob and Charlie still have matching interest despite accruing at different times
            (int128 aliceIndex2, ) = collateralToken0.interestState(Alice);
            (int128 charlieIndex2, ) = collateralToken0.interestState(Charlie);
            assertEq(aliceIndex2, charlieIndex2, "Alice and Charlie should have matching indices");
            // Only BoB accrues
            vm.prank(Bob);
            collateralToken0.accrueInterest();

            // ADD: Verify all users are now synchronized
            (int128 bobIndexFinal, ) = collateralToken0.interestState(Bob);
            assertEq(bobIndexFinal, aliceIndex2, "All users should now have the same index");
        }
        {
            // ADD: Verify Bob paid more interest total (accrued twice in this period)
            uint256 bobFinalBalanceEnd = collateralToken0.balanceOf(Bob);
            uint256 aliceFinalBalanceEnd = collateralToken0.balanceOf(Alice);
            uint256 charlieFinalBalanceEnd = collateralToken0.balanceOf(Charlie);
            {
                // Calculate actual interest paid by each user
                uint256 bobTotalInterestPaid = collateralToken0.convertToAssets(
                    bobInitialBalance - bobFinalBalanceEnd
                );
                uint256 aliceTotalInterestPaid = collateralToken0.convertToAssets(
                    aliceInitialBalance - aliceFinalBalanceEnd
                );
                // Bob accrued 3 times (more frequent payments), Alice only 2 times
                // Bob has half the borrow, so his interest should be slightly LESS than half of Alice's
                // because frequent accruals mean less compounding
                assertLt(
                    bobTotalInterestPaid * 2,
                    aliceTotalInterestPaid,
                    "Bob should pay slightly less than half of Alice's interest due to more frequent payments"
                );
                {
                    uint256 charlieTotalInterestPaid = collateralToken0.convertToAssets(
                        charlieInitialBalance - charlieFinalBalanceEnd
                    );

                    // Charlie should have paid more than Bob (same borrow, but less frequent accruals = more compounding)
                    assertGt(
                        charlieTotalInterestPaid,
                        bobTotalInterestPaid,
                        "Charlie should pay more than Bob due to less frequent accruals (more compounding)"
                    );

                    // Alice's interest should be approximately equal to Bob + Charlie
                    // (Alice has 2x the borrow, but same accrual pattern as Charlie)
                    assertApproxEqAbs(
                        aliceTotalInterestPaid,
                        charlieTotalInterestPaid * 2,
                        1,
                        "Alice should pay approximately 2x Charlie's interest (same accrual pattern, 2x borrow)"
                    );
                }
            }
            {
                // Verify no cross-contamination of interest between users
                uint256 unrealizedInterest = collateralToken0.unrealizedGlobalInterest();
                assertEq(
                    unrealizedInterest,
                    0,
                    "All interest should be settled after all users accrued"
                );
            }
            {
                // ADD: Final sanity check - verify total interest collected
                uint256 totalInterestCollected = (aliceInitialBalance - aliceFinalBalanceEnd) +
                    (bobInitialBalance - bobFinalBalanceEnd) +
                    (charlieInitialBalance - charlieFinalBalanceEnd);

                assertGt(totalInterestCollected, 0, "Total interest collected should be positive");
            }

            // Verify net borrows haven't changed (only interest was paid, not principal)
            {
                (, int128 aliceFinalBorrows) = collateralToken0.interestState(Alice);
                uint128 _aliceBorrowAmount = aliceBorrowAmount;
                assertEq(
                    aliceFinalBorrows,
                    int128(_aliceBorrowAmount),
                    "Alice's borrows should be unchanged"
                );
            }
            {
                (, int128 bobFinalBorrows) = collateralToken0.interestState(Bob);
                assertEq(
                    bobFinalBorrows,
                    int128(bobBorrowAmount),
                    "Bob's borrows should be unchanged"
                );
            }
            {
                (, int128 charlieFinalBorrows) = collateralToken0.interestState(Charlie);
                assertEq(
                    charlieFinalBorrows,
                    int128(charlieBorrowAmount),
                    "Charlie's borrows should be unchanged"
                );
            }
            // Verify total supply decreased by exactly the interest paid (burned shares)
            uint256 expectedSupplyDecrease = (aliceInitialBalance - aliceFinalBalanceEnd) +
                (bobInitialBalance - bobFinalBalanceEnd) +
                (charlieInitialBalance - charlieFinalBalanceEnd);

            uint256 _initialTotalSupply = initialTotalSupply;
            console2.log("aa", _initialTotalSupply, collateralToken0.totalSupply());
            assertEq(
                _initialTotalSupply - collateralToken0.totalSupply(),
                expectedSupplyDecrease,
                "Total supply should decrease by exactly the burned interest shares"
            );
        }
    }

    function test_Success_accrueInterest_noMorefunds() public {
        _initWorld(0);
        uint104 assets = 1000 ether; // Use a fixed deposit amount

        // Get the initial borrow index right after initialization
        uint128 initialBorrowIndex = uint80(collateralToken0._marketState());

        // --- Alice deposits ---
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), 2 * assets);
        collateralToken0.deposit(2 * assets, Alice);
        IERC20Partial(token1).approve(address(collateralToken1), 2 * assets);
        collateralToken1.deposit(2 * assets, Alice);
        vm.stopPrank();

        // --- Charlie (our control user) deposits and borrows exactly like Bob ---
        vm.startPrank(Charlie);
        _grantTokens(Charlie);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Charlie);
        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();

        strike = 198600 + 6000;
        width = 2;
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);
        mintOptions(
            panopticPool,
            positionIdList,
            assets,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        vm.stopPrank();

        // --- Bob deposits ---
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Bob);

        console2.log("here?");
        // Bob sell assets/2
        mintOptions(
            panopticPool,
            positionIdList,
            assets,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        console2.log("inAMM", collateralToken0._inAMM());
        collateralToken0.setBalance(Bob, 1 ether);

        uint32 blocksToSkip = 7200 * 365;
        uint256 timestampAfterBorrow = block.timestamp;

        {
            uint256 blockAfterBorrow = block.number;

            vm.roll(blockAfterBorrow + blocksToSkip);
            vm.warp(timestampAfterBorrow + blocksToSkip * 12);
        }
        vm.stopPrank();
        uint128 perSecondInterestRate = collateralToken0.interestRate();
        assertGt(perSecondInterestRate, 0, "FAIL: Rate should be positive after borrow");

        // Charlie repays
        uint256 charliePayment1;
        {
            uint256 charlieBalanceBefore1 = collateralToken0.balanceOf(Charlie);
            vm.startPrank(Charlie);
            console2.log("previewOwedInterest", collateralToken0.previewOwedInterest(Charlie));
            collateralToken0.accrueInterest();
            vm.stopPrank();
            uint256 charlieBalanceAfter1 = collateralToken0.balanceOf(Charlie);
            charliePayment1 = collateralToken0.convertToAssets(
                charlieBalanceBefore1 - charlieBalanceAfter1
            );
        }
        vm.stopPrank();

        uint256 balanceBobBefore = collateralToken0.balanceOf(Bob);
        uint256 maxInterestPaidByBob = collateralToken0.convertToAssets(balanceBobBefore);

        vm.startPrank(Bob);

        {
            (int128 baseIndexBefore, int128 netBorrowsBefore) = collateralToken0.interestState(Bob);

            console2.log("accrue here?");
            console2.log("previewOwedInterest", collateralToken0.previewOwedInterest(Bob));
            collateralToken0.accrueInterest();

            uint256 balanceBobAfter = collateralToken0.balanceOf(Bob);
            (int128 baseIndexAfter, int128 netBorrowsAfter) = collateralToken0.interestState(Bob);

            assertTrue(balanceBobAfter == 0, "FAIL: Bob did not pay all");
            assertEq(
                baseIndexAfter,
                baseIndexBefore,
                "FAIL: Insolvent user's base index was updated"
            );
            assertEq(
                netBorrowsAfter,
                netBorrowsBefore,
                "FAIL: Net borrows changed during interest accrual"
            );
        }
        vm.stopPrank();
        console2.log("here2?");

        // 2. Calculate the expected interest for the period.
        uint256 interestForPeriod = Math.wTaylorCompounded(
            uint256(perSecondInterestRate),
            blocksToSkip * 12
        );

        uint256 totalInterestGenerated = Math.mulDivWadRoundingUp(
            assets, // The amount borrowed before interest was added, Charlie has paid their share already
            interestForPeriod
        );

        uint256 finalUnrealizedInterest = totalInterestGenerated > maxInterestPaidByBob
            ? totalInterestGenerated - maxInterestPaidByBob
            : 0;

        uint256 expectedNewIndex = Math.mulDivWadRoundingUp(
            initialBorrowIndex,
            1e18 + interestForPeriod
        );

        // 3. Construct the full expected accumulator value.
        uint256 expectedAccumulator = (finalUnrealizedInterest << 150) +
            (collateralToken0.rateAtTarget() << 112) +
            (((timestampAfterBorrow + blocksToSkip * 12) >> 2) << 80) +
            expectedNewIndex;

        uint256 actualAccumulator = collateralToken0._marketState();

        // 4. Assert the final state is correct.
        assertEq(
            actualAccumulator,
            expectedAccumulator,
            "FAIL: Interest did not accrue correctly after borrow was made it seems"
        );

        // Bob re-reposits and pays interest
        vm.startPrank(Bob);
        {
            uint256 newAssets = 5000 ether;
            _grantTokens(Bob);
            IERC20Partial(token0).approve(address(collateralToken0), newAssets);
            console2.log("deposit here?");
            console2.log("previewOwedInterest", collateralToken0.previewOwedInterest(Bob));
            collateralToken0.deposit(newAssets, Bob);
        }
        (int128 stuckBaseIndex, ) = collateralToken0.interestState(Bob); // His index is still old

        uint256 bobBalanceBeforeFinalPayment = collateralToken0.balanceOf(Bob);
        vm.warp(block.timestamp + 1 days);

        // Charlie pays interest for the final day
        uint256 charliePayment2;
        {
            uint256 charlieBalanceBefore2 = collateralToken0.balanceOf(Charlie);
            vm.startPrank(Charlie);
            console2.log("previewOwedInterest", collateralToken0.previewOwedInterest(Charlie));
            collateralToken0.accrueInterest();
            vm.stopPrank();
            uint256 charlieBalanceAfter2 = collateralToken0.balanceOf(Charlie);
            charliePayment2 = collateralToken0.convertToAssets(
                charlieBalanceBefore2 - charlieBalanceAfter2
            );
        }
        // NOW, BOB PAYS HIS ACCUMULATED DEBT
        // Since he has funds, this should succeed and take the SOLVENT path
        vm.startPrank(Bob);
        console2.log("previewOwedInterest", collateralToken0.previewOwedInterest(Bob));
        console2.log("interest here again?");
        collateralToken0.accrueInterest();

        uint256 bobFinalPayment;
        {
            uint256 bobBalanceAfterFinalPayment = collateralToken0.balanceOf(Bob);
            bobFinalPayment = collateralToken0.convertToAssets(
                bobBalanceBeforeFinalPayment - bobBalanceAfterFinalPayment
            );
        }
        {
            uint256 finalBalance = collateralToken0.balanceOf(Bob);
            (int128 finalBaseIndex, ) = collateralToken0.interestState(Bob);
            uint128 finalGlobalBorrowIndex = collateralToken0.borrowIndex();
            console2.log("ff", finalBalance, bobBalanceBeforeFinalPayment);
            assertTrue(
                finalBalance < bobBalanceBeforeFinalPayment,
                "FAIL: Bob paid no interest after re-depositing"
            );

            assertTrue(
                finalBaseIndex > stuckBaseIndex,
                "FAIL: Bob's base index was not updated after paying his debt"
            );
            assertEq(
                uint128(finalBaseIndex),
                finalGlobalBorrowIndex,
                "FAIL: Bob's index is not current"
            );

            uint256 finalUnrealizedInterestAfterPayment = collateralToken0
                .unrealizedGlobalInterest();
            assertEq(
                finalUnrealizedInterestAfterPayment,
                0,
                "FAIL: Unrealized interest was not settled to zero"
            );
        }

        vm.stopPrank();
        {
            console2.log("amts", balanceBobBefore, bobFinalPayment);
        }

        {
            uint256 totalCharlieInterestPaid = charliePayment1 + charliePayment2;
            uint256 totalBobInterestPaid = maxInterestPaidByBob + bobFinalPayment;

            console2.log("Total Interest Paid by Charlie (2 payments):", totalCharlieInterestPaid);
            console2.log("Total Interest Paid by Bob (1 lump sum):", totalBobInterestPaid);

            // This assertion proves that Bob paid more due to compounding.
            assertTrue(
                totalBobInterestPaid > totalCharlieInterestPaid,
                "FAIL: Compounding did not result in higher total interest"
            );
        }
    }

    function test_Success_accrueInterest_previewOwedInterest() public {
        _initWorld(0);
        uint104 assets = 1000 ether;

        // Alice deposits
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Alice);
        vm.stopPrank();

        // Bob deposits and borrows
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Bob);

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();
        strike = 198600 + 6000;
        width = 2;
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        // Bob borrows by minting options
        mintOptions(
            panopticPool,
            positionIdList,
            assets / 2,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        vm.stopPrank();

        // Record initial state
        uint256 initialAccumulator = collateralToken0._marketState();
        uint128 initialOwedInterest = collateralToken0.owedInterest(Bob);

        // Should be 0 initially since no time has passed
        assertEq(initialOwedInterest, 0, "Initial owed interest should be 0");

        // Move forward in time without accruing
        uint256 timeJump = 86400; // 1 day
        vm.warp(block.timestamp + timeJump);

        // Get preview of what interest would be owed
        uint128 previewedInterest = collateralToken0.previewOwedInterest(Bob);

        // Verify state hasn't changed
        uint256 accumulatorAfterPreview = collateralToken0._marketState();
        assertEq(
            accumulatorAfterPreview,
            initialAccumulator,
            "Preview should not modify accumulator"
        );

        // owedInterest should match the preview
        uint128 nowRealTimeOwedInterest = collateralToken0.owedInterest(Bob);
        assertEq(
            nowRealTimeOwedInterest,
            previewedInterest,
            "owedInterest should now be real-time and match preview"
        );

        // Preview should show non-zero interest
        assertGt(previewedInterest, 0, "Preview should show interest accrued over time");

        // Now actually accrue interest
        collateralToken0.accrueInterest();

        // After accrual, owedInterest should match what preview showed
        // Note: Interest is paid during accrual, so owedInterest becomes 0 again.
        uint128 previewAfterAccrual = collateralToken0.previewOwedInterest(Bob);
        uint128 actualOwedInterest = collateralToken0.owedInterest(Bob);

        // In the same block, owed interest should be 0, or a very small rounding amount.
        assertApproxEqAbs(
            actualOwedInterest,
            previewAfterAccrual,
            10, // Allow tiny delta for precision
            "Actual owed interest should match preview after accrual"
        );
        console2.log("actualOwedInterest", actualOwedInterest, previewAfterAccrual);

        vm.startPrank(Bob);
        // Bob accrues and pays interest
        collateralToken0.accrueInterest();
        vm.stopPrank();
        actualOwedInterest = collateralToken0.owedInterest(Bob);
        assertApproxEqAbs(
            actualOwedInterest,
            0,
            10,
            "Owed interest should be near zero immediately after accrual"
        );

        // Test preview with multiple time jumps
        uint256 timeJump2 = 43200; // 0.5 days
        vm.warp(block.timestamp + timeJump2);

        uint128 previewedInterest2 = collateralToken0.previewOwedInterest(Bob);
        assertGt(
            previewedInterest2,
            actualOwedInterest,
            "Preview should show additional interest for new time period"
        );

        // Verify preview works correctly for users with no borrows
        uint128 alicePreview = collateralToken0.previewOwedInterest(Alice);
        assertEq(alicePreview, 0, "Preview for non-borrower should be 0");

        // Test preview in same block (deltaTime = 0)
        collateralToken0.accrueInterest();
        uint128 immediatePreview = collateralToken0.previewOwedInterest(Bob);
        uint128 immediateOwed = collateralToken0.owedInterest(Bob);
        assertEq(
            immediatePreview,
            immediateOwed,
            "Preview in same block should match owedInterest"
        );
    }

    function test_Success_accrueInterest_previewOwedInterest_insolventUser() public {
        _initWorld(0);
        uint104 assets = 1000 ether;

        // Alice deposits to provide liquidity
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Alice);
        vm.stopPrank();

        // Setup Bob with a small balance and large borrow
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(100 ether, Bob); // Deposit 100 ether

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();
        strike = 198600 + 6000;
        width = 2;
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);
        uint128 size = 100 ether;

        // Bob borrows a significant amount
        mintOptions(
            panopticPool,
            positionIdList,
            size, // Borrow same amount as deposit
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        LeftRightUnsigned _amountsMoved = PanopticMath.getAmountsMoved(tokenId, size, 0, true);

        uint128 borrowAmount = _amountsMoved.rightSlot();

        // Reduce Bob's balance to make him insolvent when interest accrues
        collateralToken0.setBalance(Bob, 1 ether); // Set very low balance
        vm.stopPrank();

        // Move forward significantly to generate high interest
        vm.warp(block.timestamp + 365 days);

        // Preview should show the full interest owed, regardless of solvency
        uint128 previewedInterest = collateralToken0.previewOwedInterest(Bob);
        assertGt(previewedInterest, 0, "Preview should show interest even for insolvent user");

        // Convert to shares to check if user is insolvent
        uint256 sharesOwed = collateralToken0.convertToShares(previewedInterest);
        uint256 bobBalance = collateralToken0.balanceOf(Bob);

        // Verify Bob would be insolvent
        assertGt(sharesOwed, bobBalance, "Interest owed in shares should exceed Bob's balance");

        // Preview should still return the full mathematical interest owed
        // even though Bob can't pay it all
        uint256 maxBobCanPay = collateralToken0.convertToAssets(bobBalance);
        assertGt(previewedInterest, maxBobCanPay, "Preview shows more than Bob can pay");

        vm.startPrank(Bob);
        // Now accrue interest to verify Bob becomes insolvent
        collateralToken0.accrueInterest();
        vm.stopPrank();

        // Bob's balance should be wiped out
        uint256 bobBalanceAfter = collateralToken0.balanceOf(Bob);
        assertEq(bobBalanceAfter, 0, "Insolvent Bob should have 0 balance after accrual");

        // Bob's base index should not have been updated (remains at old value)
        (int128 baseIndex, int128 netBorrows) = collateralToken0.interestState(Bob);
        assertEq(netBorrows, int128(borrowAmount), "Net borrows should remain unchanged");
        assertLt(uint128(baseIndex), collateralToken0.borrowIndex(), "Bob's index should be stale");
    }

    function test_Success_accrueInterest_liquidation_barelyInsolventUser() public {
        _initWorld(0);
        uint104 assets = 1000 ether;

        // Charlie the PLP deposits to provide liquidity
        vm.startPrank(Charlie);
        _grantTokens(Charlie);
        IERC20Partial(token0).approve(address(collateralToken0), assets * 10);
        collateralToken0.deposit(assets * 10, Charlie);
        vm.stopPrank();

        // Alice th eliquidator does not deposit or provide liquidity
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        //collateralToken0.deposit(assets, Alice);
        vm.stopPrank();

        // Setup Bob with a small balance and large borrow
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(100 ether, Bob); // Deposit 100 ether

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();
        strike = 198600 + 6000;
        width = 2;
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        // Bob borrows a significant amount
        mintOptions(
            panopticPool,
            positionIdList,
            100 ether, // Borrow same amount as deposit
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        ($shortPremia, $longPremia, posBalanceArray) = panopticPool
            .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

        // Move forward significantly to generate high interest
        vm.warp(block.timestamp + 365 days);

        (LeftRightUnsigned tokenData0, , ) = riskEngine.getMargin(
            posBalanceArray,
            currentTick,
            Bob,
            positionIdList,
            $shortPremia,
            $longPremia,
            collateralToken0,
            collateralToken1
        );
        console2.log("balan, thr", tokenData0.rightSlot(), tokenData0.leftSlot());

        // Reduce Bob's balance to make him insolvent when interest accrues
        collateralToken0.burnShares(Bob, collateralToken0.previewDeposit(tokenData0.rightSlot()));
        collateralToken0.mintShares(Bob, collateralToken0.previewDeposit(tokenData0.leftSlot()));

        (tokenData0, , ) = riskEngine.getMargin(
            posBalanceArray,
            currentTick,
            Bob,
            positionIdList,
            $shortPremia,
            $longPremia,
            collateralToken0,
            collateralToken1
        );
        console2.log("balan, thr", tokenData0.rightSlot(), tokenData0.leftSlot());

        vm.stopPrank();

        // Preview should show the full interest owed, regardless of solvency
        uint128 previewedInterest = collateralToken0.previewOwedInterest(Bob);
        assertGt(previewedInterest, 0, "Preview should show interest even for insolvent user");

        // Convert to shares to check if user is insolvent
        uint256 sharesOwed = collateralToken0.convertToShares(previewedInterest);
        uint256 bobBalance = collateralToken0.balanceOf(Bob);

        // Verify Bob would be insolvent but can pau
        assertLt(
            sharesOwed,
            bobBalance,
            "Interest owed in shares should be less than Bob's balance"
        );

        // Preview should still return the full mathematical interest owed
        // even though Bob can't pay it all
        uint256 maxBobCanPay = collateralToken0.convertToAssets(bobBalance);
        assertLt(previewedInterest, maxBobCanPay, "Preview shows that Bob can pay");

        vm.startPrank(Alice);
        // Now accrue interest to verify Bob becomes insolvent
        uint256 charlieAssetsBefore = collateralToken0.convertToAssets(
            collateralToken0.balanceOf(Charlie)
        );
        console2.log("c-before", charlieAssetsBefore);
        uint256 aliceAssetsBefore = collateralToken0.convertToAssets(
            collateralToken0.balanceOf(Alice)
        );
        console2.log("a-before", aliceAssetsBefore);
        uint256 bobAssetsBefore = collateralToken0.convertToAssets(collateralToken0.balanceOf(Bob));
        console2.log("b-before", bobAssetsBefore);

        uint256 expectedBonus = Math.min(
            bobAssetsBefore / 2,
            (tokenData0.leftSlot() - tokenData0.rightSlot())
        );
        console.log("expectedBonus", expectedBonus);
        console2.log("previewBob-before-liq", collateralToken0.previewOwedInterest(Bob));

        liquidate(panopticPool, new TokenId[](0), Bob, positionIdList);

        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12 seconds);

        console2.log("previewBob-after-liq", collateralToken0.previewOwedInterest(Bob));
        uint256 charlieAssetsAfter = collateralToken0.convertToAssets(
            collateralToken0.balanceOf(Charlie)
        );
        console2.log("c-after", charlieAssetsAfter);
        uint256 aliceAssetsAfter = collateralToken0.convertToAssets(
            collateralToken0.balanceOf(Alice)
        );
        console2.log("a-after", aliceAssetsAfter);
        uint256 bobAssetsAfter = collateralToken0.convertToAssets(collateralToken0.balanceOf(Bob));
        console2.log("b-after", bobAssetsAfter);

        assertApproxEqAbs(
            aliceAssetsAfter - aliceAssetsBefore,
            expectedBonus,
            1,
            "FAIL: wrong bonus"
        );

        assertApproxEqAbs(
            charlieAssetsAfter - charlieAssetsBefore,
            (previewedInterest * charlieAssetsBefore) / (charlieAssetsBefore + bobAssetsBefore),
            1,
            "FAIL: charlie did not get his share of the interests"
        );

        assertApproxEqAbs(
            bobAssetsAfter,
            bobAssetsBefore -
                expectedBonus -
                previewedInterest +
                (previewedInterest * bobAssetsBefore) /
                (charlieAssetsBefore + bobAssetsBefore),
            1,
            "FAIL: bob did not get his share of the interests"
        );

        // Bob's base index should not have been updated (remains at old value)
        (int128 baseIndex, int128 netBorrows) = collateralToken0.interestState(Bob);
        assertEq(netBorrows, 1, "Net borrows should be zero"); // accounts for the `1` permanently lost to the Uniswap Pool
        assertLe(uint128(baseIndex), collateralToken0.borrowIndex(), "Bob's index should be stale");
    }

    function test_Success_accrueInterest_liquidation_noProtocolLossInsolventUser() public {
        _initWorld(0);
        uint104 assets = 1000 ether;

        // Charlie the PLP deposits to provide liquidity
        vm.startPrank(Charlie);
        _grantTokens(Charlie);
        IERC20Partial(token0).approve(address(collateralToken0), assets * 10);
        collateralToken0.deposit(assets * 10, Charlie);
        vm.stopPrank();

        // Alice th eliquidator does not deposit or provide liquidity
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        //collateralToken0.deposit(assets, Alice);
        vm.stopPrank();

        // Setup Bob with a small balance and large borrow
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(100 ether, Bob); // Deposit 100 ether

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();
        strike = 198600 + 6000;
        width = 2;
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        // Bob borrows a significant amount
        mintOptions(
            panopticPool,
            positionIdList,
            100 ether, // Borrow same amount as deposit
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        ($shortPremia, $longPremia, posBalanceArray) = panopticPool
            .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

        // Move forward significantly to generate high interest
        vm.warp(block.timestamp + 365 days);

        // Preview should show the full interest owed, regardless of solvency
        uint128 previewedInterest = collateralToken0.previewOwedInterest(Bob);
        assertGt(previewedInterest, 0, "Preview should show interest even for insolvent user");

        (LeftRightUnsigned tokenData0, , ) = riskEngine.getMargin(
            posBalanceArray,
            currentTick,
            Bob,
            positionIdList,
            $shortPremia,
            $longPremia,
            collateralToken0,
            collateralToken1
        );
        console2.log("balan, thr", tokenData0.rightSlot(), tokenData0.leftSlot());

        // Reduce Bob's balance to make him insolvent when interest accrues
        collateralToken0.burnShares(Bob, collateralToken0.previewDeposit(tokenData0.rightSlot()));
        // reduce balance so the account has barely any shares left
        collateralToken0.mintShares(
            Bob,
            collateralToken0.previewDeposit(tokenData0.leftSlot() - 8949971082503561822)
        );

        (tokenData0, , ) = riskEngine.getMargin(
            posBalanceArray,
            currentTick,
            Bob,
            positionIdList,
            $shortPremia,
            $longPremia,
            collateralToken0,
            collateralToken1
        );
        console2.log("balan, thr", tokenData0.rightSlot(), tokenData0.leftSlot());

        vm.stopPrank();
        previewedInterest = collateralToken0.previewOwedInterest(Bob);

        // Convert to shares to check if user is insolvent
        uint256 sharesOwed = collateralToken0.convertToShares(previewedInterest);
        uint256 bobBalance = collateralToken0.balanceOf(Bob);

        // Verify Bob would be insolvent but can pay
        assertLt(
            sharesOwed,
            bobBalance,
            "Interest owed in shares should be less than Bob's balance"
        );

        // Preview should still return the full mathematical interest owed
        // even though Bob can't pay it all
        uint256 maxBobCanPay = collateralToken0.convertToAssets(bobBalance);
        assertLt(previewedInterest, maxBobCanPay, "Preview shows that Bob can pay");

        console2.log("Bobs preview, max", previewedInterest, maxBobCanPay);
        vm.startPrank(Alice);
        // Now accrue interest to verify Bob becomes insolvent
        uint256 charlieAssetsBefore = collateralToken0.convertToAssets(
            collateralToken0.balanceOf(Charlie)
        );
        console2.log("c-before", charlieAssetsBefore);
        uint256 aliceAssetsBefore = collateralToken0.convertToAssets(
            collateralToken0.balanceOf(Alice)
        );
        console2.log("a-before", aliceAssetsBefore);
        uint256 bobAssetsBefore = collateralToken0.convertToAssets(collateralToken0.balanceOf(Bob));
        console2.log("b-before", bobAssetsBefore);

        uint256 expectedBonus = Math.min(
            (bobAssetsBefore - previewedInterest) / 2,
            (tokenData0.leftSlot() - tokenData0.rightSlot())
        );
        console.log("expectedBonus", expectedBonus);
        console2.log("previewBob-before-liq", collateralToken0.previewOwedInterest(Bob));

        liquidate(panopticPool, new TokenId[](0), Bob, positionIdList);

        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12 seconds);

        console2.log("previewBob-after-liq", collateralToken0.previewOwedInterest(Bob));
        uint256 charlieAssetsAfter = collateralToken0.convertToAssets(
            collateralToken0.balanceOf(Charlie)
        );
        console2.log("c-after", charlieAssetsAfter);
        uint256 aliceAssetsAfter = collateralToken0.convertToAssets(
            collateralToken0.balanceOf(Alice)
        );
        console2.log("a-after", aliceAssetsAfter);
        uint256 bobAssetsAfter = collateralToken0.convertToAssets(collateralToken0.balanceOf(Bob));
        console2.log("b-after", bobAssetsAfter);
        assertGt(bobAssetsAfter, 0, "FAIL: Bob has no shares left");

        assertApproxEqAbs(
            aliceAssetsAfter - aliceAssetsBefore,
            expectedBonus,
            2,
            "FAIL: wrong bonus"
        );

        assertApproxEqAbs(
            charlieAssetsAfter - charlieAssetsBefore,
            (previewedInterest * charlieAssetsBefore) / (charlieAssetsBefore + bobAssetsBefore),
            1,
            "FAIL: charlie did not get his share of the interests"
        );

        console2.log("previewIn", expectedBonus, previewedInterest);
        {
            uint256 deltaInt = (previewedInterest * charlieAssetsBefore) /
                (charlieAssetsBefore + bobAssetsBefore) +
                expectedBonus;
            assertApproxEqAbs(
                bobAssetsAfter,
                bobAssetsBefore - deltaInt,
                10,
                "FAIL: bob did not get his share of the interests"
            );
        }
        // Bob's base index should not have been updated (remains at old value)
        (int128 baseIndex, int128 netBorrows) = collateralToken0.interestState(Bob);
        assertEq(netBorrows, 1, "Net borrows should be zero"); // accounts for the `1` permanently lost to the Uniswap Pool
        assertLe(uint128(baseIndex), collateralToken0.borrowIndex(), "Bob's index should be stale");
    }

    function test_Success_accrueInterest_liquidation_insolventUser() public {
        _initWorld(0);
        uint104 assets = 1000 ether;

        // Charlie the PLP deposits to provide liquidity
        vm.startPrank(Charlie);
        _grantTokens(Charlie);
        IERC20Partial(token0).approve(address(collateralToken0), assets * 10);
        collateralToken0.deposit(assets, Charlie);
        vm.stopPrank();

        // Alice th eliquidator does not deposit or provide liquidity
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        //collateralToken0.deposit(assets, Alice);
        vm.stopPrank();

        // Setup Bob with a small balance and large borrow
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(100 ether, Bob); // Deposit 100 ether

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();
        strike = 198600 + 6000;
        width = 2;
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        uint128 size = 500 ether;
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 120 seconds);

        //console2.log("orclePl", panopticPool.oraclePack());
        // Bob borrows a significant amount
        mintOptions(
            panopticPool,
            positionIdList,
            size, // Borrow same amount as deposit
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        //console2.log("orclePl", panopticPool.oraclePack());
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 120 seconds);

        ($shortPremia, $longPremia, posBalanceArray) = panopticPool
            .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

        (LeftRightUnsigned tokenData0, , ) = riskEngine.getMargin(
            posBalanceArray,
            currentTick,
            Bob,
            positionIdList,
            $shortPremia,
            $longPremia,
            collateralToken0,
            collateralToken1
        );

        LeftRightUnsigned _amountsMoved = PanopticMath.getAmountsMoved(tokenId, size, 0, false);

        uint128 borrowAmount = _amountsMoved.rightSlot();

        // Reduce Bob's balance to make him insolvent when interest accrues
        collateralToken0.burnShares(Bob, collateralToken0.previewDeposit(99 ether));
        vm.stopPrank();

        // Move forward significantly to generate high interest
        vm.warp(block.timestamp + 365 days);

        // Preview should show the full interest owed, regardless of solvency
        uint128 previewedInterest = collateralToken0.previewOwedInterest(Bob);
        assertGt(previewedInterest, 0, "Preview should show interest even for insolvent user");

        // Convert to shares to check if user is insolvent
        uint256 sharesOwed = collateralToken0.convertToShares(previewedInterest);
        uint256 bobBalance = collateralToken0.balanceOf(Bob);

        // Verify Bob would be insolvent
        assertGt(sharesOwed, bobBalance, "Interest owed in shares should exceed Bob's balance");

        // Preview should still return the full mathematical interest owed
        // even though Bob can't pay it all
        uint256 maxBobCanPay = collateralToken0.convertToAssets(bobBalance);
        assertGt(previewedInterest, maxBobCanPay, "Preview shows more than Bob can pay");

        vm.startPrank(Alice);
        // Now accrue interest to verify Bob becomes insolvent
        uint256 charlieAssetsBefore = collateralToken0.convertToAssets(
            collateralToken0.balanceOf(Charlie)
        );
        console2.log("c-before", charlieAssetsBefore);
        uint256 aliceAssetsBefore = collateralToken0.convertToAssets(
            collateralToken0.balanceOf(Alice)
        );
        console2.log("a-before", aliceAssetsBefore);
        uint256 bobAssetsBefore = collateralToken0.convertToAssets(collateralToken0.balanceOf(Bob));
        console2.log("b-before", bobAssetsBefore);

        console2.log("preview, bobBefore", previewedInterest, bobAssetsBefore);
        uint256 expectedBonus = Math.min(
            0, // bonus is balance/2, but here balance is 0 so bonus is zero
            (previewedInterest + tokenData0.leftSlot() - bobAssetsBefore)
        );
        console2.log("expectedBonus", expectedBonus);
        console2.log("previewBob-before-liq", collateralToken0.previewOwedInterest(Bob));

        liquidate(panopticPool, new TokenId[](0), Bob, positionIdList);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12 seconds);

        console2.log("previewBob-after-liq", collateralToken0.previewOwedInterest(Bob));
        uint256 charlieAssetsAfter = collateralToken0.convertToAssets(
            collateralToken0.balanceOf(Charlie)
        );
        console2.log("c-after", charlieAssetsAfter);
        uint256 aliceAssetsAfter = collateralToken0.convertToAssets(
            collateralToken0.balanceOf(Alice)
        );
        console2.log("a-after", aliceAssetsAfter);
        uint256 bobAssetsAfter = collateralToken0.convertToAssets(collateralToken0.balanceOf(Bob));
        console2.log("b-after", bobAssetsAfter);

        assertApproxEqAbs(
            aliceAssetsAfter - aliceAssetsBefore,
            expectedBonus,
            10,
            "FAIL: wrong bonus"
        );

        assertLe(
            aliceAssetsAfter - aliceAssetsBefore,
            expectedBonus,
            "FAIL: bad rounding in bonus calculation"
        );
        assertApproxEqAbs(
            charlieAssetsAfter - charlieAssetsBefore,
            0,
            1,
            "FAIL: charlie did not get his share of the interests"
        );

        vm.stopPrank();

        // Bob's balance should be wiped out
        uint256 bobBalanceAfter = collateralToken0.balanceOf(Bob);
        assertEq(bobBalanceAfter, 0, "Insolvent Bob should have 0 balance after accrual");

        // Bob's base index should not have been updated (remains at old value)
        (int128 baseIndex, int128 netBorrows) = collateralToken0.interestState(Bob);
        assertEq(netBorrows, 1, "Net borrows should be zero"); // accounts for the `1` permanently lost to the Uniswap Pool
        assertLe(uint128(baseIndex), collateralToken0.borrowIndex(), "Bob's index should be stale");
    }

    function test_Success_accrueInterest_liquidation_100percent_insolventUser() public {
        _initWorld(0);
        uint104 assets = 1000 ether;

        // Charlie the PLP deposits to provide liquidity
        vm.startPrank(Charlie);
        _grantTokens(Charlie);
        IERC20Partial(token0).approve(address(collateralToken0), assets * 10);
        collateralToken0.deposit(assets * 10, Charlie);
        vm.stopPrank();

        // Alice th eliquidator does not deposit or provide liquidity
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        //collateralToken0.deposit(assets, Alice);
        vm.stopPrank();

        // Setup Bob with a small balance and large borrow
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(100 ether, Bob); // Deposit 100 ether

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();
        strike = 198600 + 6000;
        width = 2;
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        // Bob borrows a significant amount
        mintOptions(
            panopticPool,
            positionIdList,
            100 ether, // Borrow same amount as deposit
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        // Reduce Bob's balance to ZERO
        collateralToken0.burnShares(Bob, collateralToken0.balanceOf(Bob));
        vm.stopPrank();

        // Move forward significantly to generate high interest
        vm.warp(block.timestamp + 365 days);

        // Preview should show the full interest owed, regardless of solvency
        uint128 previewedInterest = collateralToken0.previewOwedInterest(Bob);
        assertGt(previewedInterest, 0, "Preview should show interest even for insolvent user");

        // Convert to shares to check if user is insolvent
        uint256 sharesOwed = collateralToken0.convertToShares(previewedInterest);
        uint256 bobBalance = collateralToken0.balanceOf(Bob);

        // Verify Bob would be insolvent
        assertGt(sharesOwed, bobBalance, "Interest owed in shares should exceed Bob's balance");

        // Preview should still return the full mathematical interest owed
        // even though Bob can't pay it all
        uint256 maxBobCanPay = collateralToken0.convertToAssets(bobBalance);
        assertGt(previewedInterest, maxBobCanPay, "Preview shows more than Bob can pay");

        vm.startPrank(Alice);
        // Now accrue interest to verify Bob becomes insolvent
        uint256 charlieAssetsBefore = collateralToken0.convertToAssets(
            collateralToken0.balanceOf(Charlie)
        );
        console2.log("c-before", charlieAssetsBefore);
        uint256 aliceAssetsBefore = collateralToken0.convertToAssets(
            collateralToken0.balanceOf(Alice)
        );
        console2.log("a-before", aliceAssetsBefore);
        uint256 bobAssetsBefore = collateralToken0.convertToAssets(collateralToken0.balanceOf(Bob));
        console2.log("b-before", bobAssetsBefore);

        uint256 expectedBonus = Math.min(
            bobAssetsBefore / 2,
            (previewedInterest - bobAssetsBefore)
        );
        console2.log("previewBob-before-liq", collateralToken0.previewOwedInterest(Bob));

        liquidate(panopticPool, new TokenId[](0), Bob, positionIdList);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12 seconds);

        console2.log("previewBob-after-liq", collateralToken0.previewOwedInterest(Bob));
        uint256 charlieAssetsAfter = collateralToken0.convertToAssets(
            collateralToken0.balanceOf(Charlie)
        );
        console2.log("c-after", charlieAssetsAfter);
        uint256 aliceAssetsAfter = collateralToken0.convertToAssets(
            collateralToken0.balanceOf(Alice)
        );
        console2.log("a-after", aliceAssetsAfter);
        uint256 bobAssetsAfter = collateralToken0.convertToAssets(collateralToken0.balanceOf(Bob));
        console2.log("b-after", bobAssetsAfter);

        assertApproxEqAbs(
            aliceAssetsAfter - aliceAssetsBefore,
            expectedBonus,
            1,
            "FAIL: wrong bonus"
        );

        assertApproxEqAbs(
            charlieAssetsAfter,
            charlieAssetsBefore,
            1,
            "FAIL: Charlie's balance changed"
        );

        vm.stopPrank();

        // Bob's balance should be wiped out
        uint256 bobBalanceAfter = collateralToken0.balanceOf(Bob);
        assertEq(bobBalanceAfter, 0, "Insolvent Bob should have 0 balance after accrual");

        // Bob's base index should not have been updated (remains at old value)
        (int128 baseIndex, int128 netBorrows) = collateralToken0.interestState(Bob);
        assertEq(netBorrows, 1, "Net borrows should be zero"); // accounts for the `1` permanently lost to the Uniswap Pool
        assertLe(uint128(baseIndex), collateralToken0.borrowIndex(), "Bob's index should be stale");
    }

    function test_Success_accrueInterest_deposit_does_not_crystallize_insolvency() public {
        _initWorld(0);
        uint104 assets = 1000 ether;

        // Charlie the PLP deposits to provide liquidity
        vm.startPrank(Charlie);
        _grantTokens(Charlie);
        IERC20Partial(token0).approve(address(collateralToken0), assets * 10);
        collateralToken0.deposit(100 ether, Charlie);
        vm.stopPrank();

        // Alice (liquidator) does not deposit
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        vm.stopPrank();

        // Bob deposits and borrows in a way that will make him insolvent over time
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(100 ether, Bob); // initial collateral

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();
        strike = 198600 + 6000;
        width = 2;
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        // Bob borrows aggressively
        mintOptions(
            panopticPool,
            positionIdList,
            100 ether, // borrow against the deposit
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        collateralToken0.burnShares(Bob, collateralToken0.balanceOf(Bob));
        vm.stopPrank();

        // Let time pass so interest explodes and Bob becomes insolvent
        vm.warp(block.timestamp + 365 days);

        // Preview the full mathematical interest owed
        uint128 previewedInterestBefore = collateralToken0.previewOwedInterest(Bob);
        assertGt(previewedInterestBefore, 0, "Bob should owe non-zero interest");

        uint256 sharesOwed = collateralToken0.convertToShares(previewedInterestBefore);
        uint256 bobBalanceBefore = collateralToken0.balanceOf(Bob);
        assertGt(sharesOwed, bobBalanceBefore, "Bob must be insolvent for this test");

        // Sanity: preview says he owes more than he can pay at current balance
        uint256 maxBobCanPay = collateralToken0.convertToAssets(bobBalanceBefore);
        assertGt(previewedInterestBefore, maxBobCanPay, "Interest owed should exceed Bob's assets");

        // Take a snapshot of Bob's interest state
        (int128 baseIndexBefore, int128 netBorrowsBefore) = collateralToken0.interestState(Bob);

        // Compute expected shares from a fresh deposit
        uint256 depositAssets = 10 ether;
        uint256 depositShares = collateralToken0.previewDeposit(depositAssets);

        // Bob deposits to "cure" while insolvent
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), depositAssets);
        collateralToken0.deposit(depositAssets, Bob);
        vm.stopPrank();

        // 1) Existing shares should NOT be burned: total shares = old + depositShares (up to rounding)
        uint256 bobBalanceAfter = collateralToken0.balanceOf(Bob);
        assertApproxEqAbs(
            collateralToken0.convertToAssets(bobBalanceAfter),
            collateralToken0.convertToAssets(bobBalanceBefore) + depositAssets,
            1,
            "Deposit should not burn Bob's existing shares when insolvent"
        );

        // 2) Interest preview should be unchanged (no settlement on deposit-path insolvency)
        uint128 previewedInterestAfter = collateralToken0.previewOwedInterest(Bob);
        assertApproxEqAbs(
            previewedInterestAfter,
            previewedInterestBefore,
            1,
            "Deposit should not settle or reduce Bob's interest when insolvent"
        );

        // 3) Interest state: same netBorrows and same stale baseIndex
        (int128 baseIndexAfter, int128 netBorrowsAfter) = collateralToken0.interestState(Bob);
        assertEq(netBorrowsAfter, netBorrowsBefore, "netBorrows should remain unchanged");
        assertEq(
            uint128(baseIndexAfter),
            uint128(baseIndexBefore),
            "baseIndex should remain stale"
        );
    }

    function test_Fuzz_accrueInterest_previewOwedInterest_accuracy(uint32 timeDelta) public {
        // Bound the time delta to reasonable values (12 second to 1 year)
        timeDelta = uint32(bound(timeDelta, 12, 365 days));

        _initWorld(0);
        uint104 assets = 1000 ether;
        console2.log("lastTime", collateralToken0.lastInteractionTimestamp(), block.timestamp);

        // Alice deposits for liquidity
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Alice);
        vm.stopPrank();

        // Bob deposits and borrows
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Bob);

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();
        strike = 198600 + 6000;
        width = 2;
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        // Bob borrows
        uint128 borrowAmount = assets / 2;
        mintOptions(
            panopticPool,
            positionIdList,
            borrowAmount,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        vm.stopPrank();

        // Record state immediately after borrow
        uint256 initialTimestamp = block.timestamp;

        // Move forward by fuzzed time delta
        vm.warp(initialTimestamp + timeDelta);

        // Get preview before accrual
        uint128 previewedInterest = collateralToken0.previewOwedInterest(Bob);

        // Store state before accrual to verify preview didn't change it
        uint256 accumulatorBefore = collateralToken0._marketState();
        (int128 baseIndexBefore, int128 netBorrowsBefore) = collateralToken0.interestState(Bob);

        // Actually accrue interest
        collateralToken0.accrueInterest();
        console2.log("lastTime", collateralToken0.lastInteractionTimestamp(), block.timestamp);

        // Get actual interest after accrual
        uint128 actualInterest = collateralToken0.owedInterest(Bob);

        // Verify preview didn't modify state
        assertEq(
            uint32(accumulatorBefore >> 80), // Extract timestamp portion
            initialTimestamp >> 2,
            "Preview modified the accumulator timestamp"
        );

        // Main assertion: preview should exactly match actual
        assertEq(
            previewedInterest,
            actualInterest,
            "Preview interest doesn't match actual interest after accrual"
        );

        // Additional test: multiple preview calls should return same result
        vm.warp(block.timestamp + timeDelta);
        {
            uint128 preview1 = collateralToken0.previewOwedInterest(Bob);
            uint128 preview2 = collateralToken0.previewOwedInterest(Bob);
            assertEq(preview1, preview2, "Multiple preview calls return different results");
        }
        // Test preview accuracy for Charlie (non-borrower)
        uint128 charliePreview = collateralToken0.previewOwedInterest(Charlie);
        assertEq(charliePreview, 0, "Non-borrower should have zero preview interest");

        // Edge case: preview immediately after accrual (deltaTime = 0)
        {
            collateralToken0.accrueInterest();
            console2.log("lastTime", collateralToken0.lastInteractionTimestamp(), block.timestamp);
            uint128 immediatePreview = collateralToken0.previewOwedInterest(Bob);
            uint128 immediateOwed = collateralToken0.owedInterest(Bob);
            assertEq(
                immediatePreview,
                immediateOwed,
                "Preview with deltaTime=0 should match owedInterest"
            );
        }

        // Test with varying borrow amounts by having Bob adjust position
        if (timeDelta < 30 days) {
            // Only do this for shorter time periods to avoid overflow
            vm.startPrank(Bob);
            (, int128 netBorrowsBefore) = collateralToken0.interestState(Bob);

            // Bob increases his borrow
            burnOptions(
                panopticPool,
                positionIdList[0],
                new TokenId[](0),
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );
            (, int128 netBorrowsAfter) = collateralToken0.interestState(Bob);

            assertEq(netBorrowsAfter, 1, "FAIL: net borrows is not zero after closing loan"); // `1` leftover that is permanently lost to the Uniswap Pool
            // Bob increases his borrow
            mintOptions(
                panopticPool,
                positionIdList,
                borrowAmount + borrowAmount / 4,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );

            // Move forward again
            vm.warp(block.timestamp + 2 * timeDelta);

            vm.stopPrank();
            // Preview should account for the new borrow amount
            uint128 previewAfterIncrease = collateralToken0.previewOwedInterest(Bob);
            collateralToken0.accrueInterest();
            console2.log("lastTime", collateralToken0.lastInteractionTimestamp(), block.timestamp);
            uint128 actualAfterIncrease = collateralToken0.owedInterest(Bob);

            assertEq(
                previewAfterIncrease,
                actualAfterIncrease,
                "Preview doesn't match actual after position change"
            );
        }

        // Verify mathematical properties
        if (timeDelta > 1) {
            // Interest should be monotonically increasing with time
            vm.warp(block.timestamp + (timeDelta / 2));
            uint128 halfTimePreview = collateralToken0.previewOwedInterest(Bob);

            vm.warp(block.timestamp + timeDelta);
            uint128 fullTimePreview = collateralToken0.previewOwedInterest(Bob);

            assertGe(
                fullTimePreview,
                halfTimePreview,
                "Interest should increase monotonically with time"
            );
        }

        // Test precision: ensure we're not losing significant amounts to rounding
        if (borrowAmount > 1e18 && timeDelta > 1 days) {
            // For significant borrows over meaningful time, interest should be non-zero
            assertGt(
                previewedInterest,
                0,
                "Should accrue non-zero interest for significant borrows"
            );
        }
    }

    function test_Success_accrueInterest_compoundingAccuracy() public {
        _initWorld(0);
        uint104 assets = 1000 ether;

        // Setup initial liquidity
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Alice);
        vm.stopPrank();

        // Setup two identical borrowers - Bob (frequent accrual) and Charlie (infrequent accrual)
        uint128 borrowAmount = 100 ether;
        uint256 depositAmount = 200 ether;

        // Bob setup
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), depositAmount);
        collateralToken0.deposit(depositAmount, Bob);

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();
        strike = 198600 + 6000;
        width = 2;
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        mintOptions(
            panopticPool,
            positionIdList,
            borrowAmount,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        vm.stopPrank();

        // Charlie setup (identical position)
        vm.startPrank(Charlie);
        _grantTokens(Charlie);
        IERC20Partial(token0).approve(address(collateralToken0), depositAmount);
        collateralToken0.deposit(depositAmount, Charlie);

        mintOptions(
            panopticPool,
            positionIdList,
            borrowAmount,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        vm.stopPrank();

        collateralToken0.setBalance(Bob, 1e6 * 200 ether);
        collateralToken0.setBalance(Charlie, 1e6 * 200 ether);
        // Record initial balances
        uint256 bobInitialBalance = collateralToken0.balanceOf(Bob);
        uint256 charlieInitialBalance = collateralToken0.balanceOf(Charlie);
        assertEq(bobInitialBalance, charlieInitialBalance, "Initial balances should match");

        // Test period: 365 days
        uint256 testDuration = 365 days;
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + testDuration;

        // Bob: Accrue interest frequently (hourly)
        uint256 accrualFrequency = 1 hours;
        uint256 numAccruals = testDuration / accrualFrequency;

        for (uint256 i = 0; i < numAccruals; i++) {
            vm.warp(startTime + (i + 1) * accrualFrequency);
            vm.prank(Bob);
            collateralToken0.accrueInterest();
        }

        uint256 bobFinalBalance = collateralToken0.balanceOf(Bob);
        uint256 bobInterestPaid = collateralToken0.convertToAssets(
            bobInitialBalance - bobFinalBalance
        );

        // Charlie: Accrue interest once at the end
        vm.warp(endTime);
        vm.prank(Charlie);
        collateralToken0.accrueInterest();

        uint256 tolerance;
        {
            uint256 charlieFinalBalance = collateralToken0.balanceOf(Charlie);
            uint256 charlieInterestPaid = collateralToken0.convertToAssets(
                charlieInitialBalance - charlieFinalBalance
            );

            // Log results for debugging
            console2.log("Bob (daily accrual) paid:", bobInterestPaid);
            console2.log("Charlie (single accrual) paid:", charlieInterestPaid);
            console2.log(
                "Difference:",
                bobInterestPaid > charlieInterestPaid
                    ? bobInterestPaid - charlieInterestPaid
                    : charlieInterestPaid - bobInterestPaid
            );

            // The difference should be minimal (due to rounding in compound calculations)
            // We allow for a small tolerance based on the total interest amount
            tolerance = Math.max(bobInterestPaid, charlieInterestPaid) / 1000; // 1% tolerance
            uint256 tolerance = bobInterestPaid ** 2 /
                (collateralToken0.convertToAssets(bobInitialBalance));

            assertApproxEqAbs(
                bobInterestPaid,
                charlieInterestPaid,
                tolerance,
                "Interest paid should be nearly identical regardless of accrual frequency"
            );
        }
    }

    function test_Success_accrueInterest_maxValues() public {
        _initWorld(0);

        // Setup with near-maximum values
        // Use values close to type(uint104).max (the limit for deposits)
        uint128 maxAssets = type(uint104).max - 1e18; // Leave small buffer for calculations

        // Alice provides massive liquidity
        vm.startPrank(Alice);
        deal(token0, Alice, type(uint256).max);
        deal(token1, Alice, type(uint256).max);
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        collateralToken0.deposit(maxAssets / 2, Alice);
        vm.stopPrank();

        // Bob makes a massive deposit and borrow
        vm.startPrank(Bob);
        deal(token0, Bob, type(uint256).max);
        deal(token1, Bob, type(uint256).max);
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        collateralToken0.deposit(maxAssets / 2, Bob);

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();
        strike = 198600 + 6000;
        width = 2;
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        // Bob borrows near the maximum possible amount
        uint128 maxBorrow = uint128(maxAssets / 450000);
        mintOptions(
            panopticPool,
            positionIdList,
            maxBorrow,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        vm.stopPrank();

        collateralToken0.setInAMM(int128(maxAssets - 1)); // Maximum borrowed
        Math.wTaylorCompounded(2 ** 93, type(uint32).max);

        // Record initial state
        uint256 initialAccumulator = collateralToken0._marketState();
        uint256 bobInitialBalance = collateralToken0.balanceOf(Bob);
        (int128 initialBaseIndex, int128 initialNetBorrows) = collateralToken0.interestState(Bob);

        // Test 1: Maximum time jump (just under uint32 max to avoid wrap)
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 4 * uint256(type(uint32).max)); // 138 years

        // This should not revert despite massive values
        vm.prank(Bob);
        collateralToken0.accrueInterest();

        // Verify state updated correctly
        uint256 newAccumulator = collateralToken0._marketState();
        assertGt(newAccumulator, initialAccumulator, "Accumulator should have increased");

        // Verify Bob paid interest (or was wiped out if insolvent)
        uint256 bobAfterBalance = collateralToken0.balanceOf(Bob);
        assertLe(bobAfterBalance, bobInitialBalance, "Bob's balance should decrease or be zero");
        console2.log("Final borrow index:", collateralToken0.borrowIndex());
        console2.log("Final unrealized interest:", collateralToken0.unrealizedGlobalInterest());
        console2.log("Bob final balance:", collateralToken0.balanceOf(Bob));
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/
    function test_Success_deposit(uint256 x, uint104 assets) public {
        // initalize world state
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);
        assets = uint104(bound(assets, 1, type(uint104).max));

        // approve collateral tracker to move tokens on the msg.senders behalf
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        IERC20Partial(token1).approve(address(collateralToken1), assets);

        // the amount of shares that can be minted
        // supply == 0 ? assets : FullMath.mulDiv(assets, supply, totalAssets());
        uint256 sharesToken0 = FullMath.mulDiv(
            uint256(assets),
            collateralToken0.totalSupply(),
            collateralToken0.totalAssets()
        );
        uint256 sharesToken1 = FullMath.mulDiv(
            uint256(assets),
            collateralToken1.totalSupply(),
            collateralToken1.totalAssets()
        );

        // deposit a number of assets determined via fuzzing
        // equal deposits for both collateral token pairs for testing purposes
        uint256 returnedShares0 = collateralToken0.deposit(assets, Bob);
        uint256 returnedShares1 = collateralToken1.deposit(assets, Bob);

        // check shares were calculated correctly
        assertEq(sharesToken0, returnedShares0, "shares0");
        assertEq(sharesToken1, returnedShares1, "shares1");

        // check if receiver got the shares
        assertEq(sharesToken0, collateralToken0.balanceOf(Bob), "balance0");
        assertEq(sharesToken1, collateralToken1.balanceOf(Bob), "balance1");

        address underlyingToken0 = collateralToken0.asset();
        address underlyingToken1 = collateralToken1.asset();

        // check if the panoptic pool got transferred the correct underlying assets
        assertEq(
            assets,
            manager.balanceOf(address(panopticPool), uint160(underlyingToken0)),
            "manager balance0"
        );
        assertEq(
            assets,
            manager.balanceOf(address(panopticPool), uint160(underlyingToken1)),
            "manager balance1"
        );
    }

    function test_Fail_deposit_DepositTooLarge(uint256 x, uint256 assets) public {
        // initalize world state
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // approve collateral tracker to move tokens on the msg.senders behalf
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        IERC20Partial(token1).approve(address(collateralToken1), assets);

        // deposit more than the maximum (2**104 - 1)
        assets = bound(assets, uint256(type(uint104).max) + 1, type(uint256).max);

        vm.expectRevert(Errors.DepositTooLarge.selector);
        collateralToken0.deposit(assets, Bob);
        vm.expectRevert(Errors.DepositTooLarge.selector);
        collateralToken1.deposit(assets, Bob);
    }

    function test_Fail_deposit_BelowMinimumRedemption(uint256 x) public {
        // initalize world state
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // In mint function, if shares would result in 0 assets, it should revert
        // This happens when shares is so small that previewMint returns 0
        // For this test, we'll try to mint 0 shares which should result in 0 assets

        // approve collateral tracker to move tokens on the msg.senders behalf
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);

        // attempt to mint with shares that would result in 0 assets
        // When shares = 0, previewMint should return 0 assets
        vm.expectRevert(Errors.BelowMinimumRedemption.selector);
        collateralToken0.deposit(0, Bob);
        vm.expectRevert(Errors.BelowMinimumRedemption.selector);
        collateralToken1.deposit(0, Bob);
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    // fuzz for a random pool
    // fuzz for random asset amount to withdraw
    function test_Success_withdraw(uint256 x, uint104 assets) public {
        // initalize world state
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        assets = uint104(bound(assets, 1, type(uint104).max));

        // approve collateral tracker to move tokens on the msg.senders behalf
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        IERC20Partial(token1).approve(address(collateralToken1), assets);

        // deposit a number of assets determined via fuzzing
        // equal deposits for both collateral token pairs for testing purposes
        uint256 returnedShares0 = collateralToken0.deposit(assets, Bob);
        uint256 returnedShares1 = collateralToken1.deposit(assets, Bob);

        // Bob's token balance before withdraw
        uint256 balanceBefore0 = IERC20Partial(token0).balanceOf(Bob);
        uint256 balanceBefore1 = IERC20Partial(token1).balanceOf(Bob);

        // total amount of shares before withdrawal
        uint256 sharesBefore0 = convertToAssets(collateralToken0.totalSupply(), collateralToken0);
        uint256 sharesBefore1 = convertToAssets(collateralToken1.totalSupply(), collateralToken1);

        uint256 assetsToken0 = convertToAssets(returnedShares0, collateralToken0);
        uint256 assetsToken1 = convertToAssets(returnedShares1, collateralToken1);

        // withdraw tokens
        collateralToken0.withdraw(assetsToken0, Bob, Bob);
        collateralToken1.withdraw(assetsToken1, Bob, Bob);

        // Total amount of shares after withdrawal (after burn)
        uint256 sharesAfter0 = convertToAssets(collateralToken0.totalSupply(), collateralToken0);
        uint256 sharesAfter1 = convertToAssets(collateralToken1.totalSupply(), collateralToken1);

        // Bob's token balance after withdraw
        uint256 balanceAfter0 = IERC20Partial(token0).balanceOf(Bob);
        uint256 balanceAfter1 = IERC20Partial(token1).balanceOf(Bob);

        // check the correct amount of shares were burned
        // should be back to baseline
        assertEq(assetsToken0, sharesBefore0 - sharesAfter0);
        assertEq(assetsToken1, sharesBefore1 - sharesAfter1);

        // ensure underlying tokens were received back
        assertEq(assetsToken0, balanceAfter0 - balanceBefore0);
        assertEq(assetsToken1, balanceAfter1 - balanceBefore1);
    }

    function test_Success_withdraw_PositionListSig(uint256 x, uint104 assets) public {
        // initalize world state
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        assets = uint104(bound(assets, 1, type(uint104).max));

        // approve collateral tracker to move tokens on the msg.senders behalf
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        IERC20Partial(token1).approve(address(collateralToken1), assets);

        // deposit a number of assets determined via fuzzing
        // equal deposits for both collateral token pairs for testing purposes
        uint256 returnedShares0 = collateralToken0.deposit(assets, Bob);
        uint256 returnedShares1 = collateralToken1.deposit(assets, Bob);

        // Bob's token balance before withdraw
        uint256 balanceBefore0 = IERC20Partial(token0).balanceOf(Bob);
        uint256 balanceBefore1 = IERC20Partial(token1).balanceOf(Bob);

        // total amount of shares before withdrawal
        uint256 sharesBefore0 = convertToAssets(collateralToken0.totalSupply(), collateralToken0);
        uint256 sharesBefore1 = convertToAssets(collateralToken1.totalSupply(), collateralToken1);

        uint256 assetsToken0 = convertToAssets(returnedShares0, collateralToken0);
        uint256 assetsToken1 = convertToAssets(returnedShares1, collateralToken1);

        // withdraw tokens
        collateralToken0.withdraw(assetsToken0, Bob, Bob, new TokenId[](0), true);
        collateralToken1.withdraw(assetsToken1, Bob, Bob, new TokenId[](0), true);

        // Total amount of shares after withdrawal (after burn)
        uint256 sharesAfter0 = convertToAssets(collateralToken0.totalSupply(), collateralToken0);
        uint256 sharesAfter1 = convertToAssets(collateralToken1.totalSupply(), collateralToken1);

        // Bob's token balance after withdraw
        uint256 balanceAfter0 = IERC20Partial(token0).balanceOf(Bob);
        uint256 balanceAfter1 = IERC20Partial(token1).balanceOf(Bob);

        // check the correct amount of shares were burned
        // should be back to baseline
        assertEq(assetsToken0, sharesBefore0 - sharesAfter0);
        assertEq(assetsToken1, sharesBefore1 - sharesAfter1);

        // ensure underlying tokens were received back
        assertEq(assetsToken0, balanceAfter0 - balanceBefore0);
        assertEq(assetsToken1, balanceAfter1 - balanceBefore1);
    }

    function test_Fail_withdraw_BelowMinimumRedemption(uint256 x, uint104 assets) public {
        // initalize world state
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        assets = uint104(bound(assets, 1, type(uint104).max));

        // approve collateral tracker to move tokens on the msg.senders behalf
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        IERC20Partial(token1).approve(address(collateralToken1), assets);

        // deposit a number of assets determined via fuzzing
        // equal deposits for both collateral token pairs for testing purposes
        collateralToken0.deposit(assets, Bob);
        collateralToken1.deposit(assets, Bob);

        // withdraw tokens
        vm.expectRevert(Errors.BelowMinimumRedemption.selector);
        collateralToken0.withdraw(0, Bob, Bob);
        vm.expectRevert(Errors.BelowMinimumRedemption.selector);
        collateralToken1.withdraw(0, Bob, Bob);
    }

    function test_Fail_withdraw_PositionList_BelowMinimumRedemption(
        uint256 x,
        uint104 assets
    ) public {
        // initalize world state
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        assets = uint104(bound(assets, 1, type(uint104).max));

        // approve collateral tracker to move tokens on the msg.senders behalf
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        IERC20Partial(token1).approve(address(collateralToken1), assets);

        // deposit a number of assets determined via fuzzing
        // equal deposits for both collateral token pairs for testing purposes
        collateralToken0.deposit(assets, Bob);
        collateralToken1.deposit(assets, Bob);

        // withdraw tokens
        vm.expectRevert(Errors.BelowMinimumRedemption.selector);
        collateralToken0.withdraw(0, Bob, Bob, new TokenId[](0), true);
        vm.expectRevert(Errors.BelowMinimumRedemption.selector);
        collateralToken1.withdraw(0, Bob, Bob, new TokenId[](0), true);
    }

    // fail if attempting to withdraw more assets than the max withdraw amount
    function test_Fail_withdraw_ExceedsMax(uint256 x) public {
        // initalize world state
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // maxDeposit
        uint256 maxDeposit0 = collateralToken0.maxDeposit(Bob);
        uint256 maxDeposit1 = collateralToken1.maxDeposit(Bob);

        // approve collateral tracker to move tokens on the msg.senders behalf
        IERC20Partial(token0).approve(address(collateralToken0), maxDeposit0);
        IERC20Partial(token1).approve(address(collateralToken1), maxDeposit1);

        // deposit the max amount
        _mockMaxDeposit(Bob);

        // max withdrawable amount
        uint256 maxAssets = collateralToken0.maxWithdraw(Bob);

        // attempt to withdraw
        // fail as assets > maxWithdraw(owner)
        vm.expectRevert(Errors.ExceedsMaximumRedemption.selector);
        collateralToken0.withdraw(maxAssets + 1, Bob, Bob);
    }

    function test_Fail_withdraw_ExceedsMax_PositionListSig(uint256 x) public {
        // initalize world state
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // maxDeposit
        uint256 maxDeposit0 = collateralToken0.maxDeposit(Bob);
        uint256 maxDeposit1 = collateralToken1.maxDeposit(Bob);

        // approve collateral tracker to move tokens on the msg.senders behalf
        IERC20Partial(token0).approve(address(collateralToken0), maxDeposit0);
        IERC20Partial(token1).approve(address(collateralToken1), maxDeposit1);

        // deposit the max amount
        _mockMaxDeposit(Bob);

        // max withdrawable amount
        uint256 maxAssets = collateralToken0.maxWithdraw(Bob);

        // attempt to withdraw
        // fail as assets > maxWithdraw(owner)
        vm.expectRevert(Errors.ExceedsMaximumRedemption.selector);
        collateralToken0.withdraw(maxAssets + 1, Bob, Bob, new TokenId[](0), true);
    }

    function test_Fail_mintGTAvailableAssets(
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 positionSizeSeed
    ) public {
        // initalize world state
        _initWorld(0);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);

        collateralToken0.deposit(1000, Bob);
        collateralToken1.deposit(type(uint104).max, Bob);

        collateralToken0.setPoolAssets(500);
        collateralToken0.setInAMM(500);

        (width, strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        vm.expectRevert(Errors.CastingError.selector);
        mintOptions(
            panopticPool,
            positionIdList,
            uint128(bound(positionSizeSeed, 501, 1000)),
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    function test_Fail_burnGTAvailableAssets(uint256 widthSeed, int256 strikeSeed) public {
        // initalize world state
        _initWorld(0);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);

        collateralToken0.deposit(1000, Bob);
        collateralToken1.deposit(type(uint104).max, Bob);

        (width, strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        mintOptions(
            panopticPool,
            positionIdList,
            750,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 1, 0, 0, strike, width);
        positionIdList.push(tokenId);

        mintOptions(
            panopticPool,
            positionIdList,
            500,
            type(uint24).max,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        collateralToken0.setPoolAssets(collateralToken0._availableAssets() - 300);

        positionIdList.pop();

        vm.expectRevert(Errors.CastingError.selector);
        burnOptions(
            panopticPool,
            tokenId,
            positionIdList,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    function test_Fail_burnGTInAMM(uint256 widthSeed, int256 strikeSeed) public {
        // initalize world state
        _initWorld(0);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);

        collateralToken0.deposit(1000, Bob);
        collateralToken1.deposit(type(uint104).max, Bob);

        (width, strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        mintOptions(
            panopticPool,
            positionIdList,
            750,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        collateralToken0.setInAMM(-250);

        positionIdList.pop();

        vm.expectRevert(Errors.CastingError.selector);
        burnOptions(
            panopticPool,
            tokenId,
            positionIdList,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    function test_Fail_removeGtAvailableCollateral() public {
        // initalize world state
        _initWorld(0);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);

        collateralToken0.deposit(1000, Bob);

        collateralToken0.setPoolAssets(collateralToken0._availableAssets() - 500);
        collateralToken0.setInAMM(500);

        uint256 bal = collateralToken0.balanceOf(Bob);
        uint256 assets = collateralToken0.convertToAssets(bal);
        vm.expectRevert(Errors.ExceedsMaximumRedemption.selector);
        collateralToken0.redeem(bal, Bob, Bob);

        vm.expectRevert(Errors.ExceedsMaximumRedemption.selector);
        collateralToken0.withdraw(assets, Bob, Bob);

        vm.expectRevert(Errors.ExceedsMaximumRedemption.selector);
        collateralToken0.withdraw(assets, Bob, Bob, new TokenId[](0), true);
    }

    function test_Success_withdraw_OnBehalf(uint256 x, uint104 assets) public {
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // approve collateral tracker to move tokens on Bob's behalf
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        IERC20Partial(token1).approve(address(collateralToken1), assets);

        // approve Alice to move tokens on Bob's behalf
        collateralToken0.approve(Alice, convertToShares(assets, collateralToken0));
        collateralToken1.approve(Alice, convertToShares(assets, collateralToken1));

        // deposit fuzzed amount of tokens
        _mockMaxDeposit(Bob);

        vm.startPrank(Alice);

        // Bob's token balance before withdraw
        uint256 balanceBefore0 = IERC20Partial(token0).balanceOf(Alice);
        uint256 balanceBefore1 = IERC20Partial(token1).balanceOf(Alice);

        vm.assume(assets > 0);
        // attempt to withdraw
        collateralToken0.withdraw(assets, Alice, Bob);
        collateralToken1.withdraw(assets, Alice, Bob);

        // Bob's token balance after withdraw
        uint256 balanceAfter0 = IERC20Partial(token0).balanceOf(Alice);
        uint256 balanceAfter1 = IERC20Partial(token1).balanceOf(Alice);

        // check the withdrawal was successful
        assertEq(assets, balanceAfter0 - balanceBefore0);
        assertEq(assets, balanceAfter1 - balanceBefore1);
    }

    function test_Success_withdraw_OnBehalf_PositionListSig(uint256 x, uint104 assets) public {
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // approve collateral tracker to move tokens on Bob's behalf
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        IERC20Partial(token1).approve(address(collateralToken1), assets);

        // approve Alice to move tokens on Bob's behalf
        collateralToken0.approve(Alice, convertToShares(assets, collateralToken0));
        collateralToken1.approve(Alice, convertToShares(assets, collateralToken1));

        // deposit fuzzed amount of tokens
        _mockMaxDeposit(Bob);

        vm.startPrank(Alice);

        // Bob's token balance before withdraw
        uint256 balanceBefore0 = IERC20Partial(token0).balanceOf(Alice);
        uint256 balanceBefore1 = IERC20Partial(token1).balanceOf(Alice);

        vm.assume(assets > 0);
        // attempt to withdraw
        collateralToken0.withdraw(assets, Alice, Bob, new TokenId[](0), true);
        collateralToken1.withdraw(assets, Alice, Bob, new TokenId[](0), true);

        // Bob's token balance after withdraw
        uint256 balanceAfter0 = IERC20Partial(token0).balanceOf(Alice);
        uint256 balanceAfter1 = IERC20Partial(token1).balanceOf(Alice);

        // check the withdrawal was successful
        assertEq(assets, balanceAfter0 - balanceBefore0);
        assertEq(assets, balanceAfter1 - balanceBefore1);
    }

    function test_Fail_withdraw_onBehalf(uint256 x) public {
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        uint256 assets = type(uint104).max;

        // approve collateral tracker to move tokens on Bob's behalf
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        IERC20Partial(token1).approve(address(collateralToken1), assets);

        // deposit fuzzed amount of tokens
        _mockMaxDeposit(Bob);

        vm.stopPrank();
        vm.startPrank(Alice);

        // attempt to withdraw
        // fail as user does not have approval to transfer on behalf
        vm.expectRevert(stdError.arithmeticError);
        collateralToken0.withdraw(100, Alice, Bob);
    }

    function test_Fail_withdraw_onBehalf_PositionListSig(uint256 x) public {
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        uint256 assets = type(uint104).max;

        // approve collateral tracker to move tokens on Bob's behalf
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        IERC20Partial(token1).approve(address(collateralToken1), assets);

        // deposit fuzzed amount of tokens
        _mockMaxDeposit(Bob);

        vm.stopPrank();
        vm.startPrank(Alice);

        // attempt to withdraw
        // fail as user does not have approval to transfer on behalf
        vm.expectRevert(stdError.arithmeticError);
        collateralToken0.withdraw(100, Alice, Bob, new TokenId[](0), true);
    }

    function test_Fail_spoof(
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 positionSizeSeed
    ) public {
        // initalize world state
        _initWorld(0);

        // Invoke all interactions with the Collateral Tracker from user Alice
        vm.startPrank(Alice);

        // give Bob the max amount of tokens
        _grantTokens(Alice);

        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);

        collateralToken0.deposit(1e18, Alice);
        collateralToken1.deposit(1e18, Alice);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);

        collateralToken0.deposit(1e10, Bob);
        //collateralToken1.deposit(0, Bob);

        //collateralToken0.setPoolAssets(500);
        //collateralToken0.setInAMM(500);

        (width, strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            0
        );

        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        mintOptions(
            panopticPool,
            positionIdList,
            uint128(1e9),
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        uint256 assets0 = collateralToken0.convertToAssets(collateralToken0.balanceOf(Bob));
        // fail because collateral requirement are too high
        vm.expectRevert(
            abi.encodeWithSelector(Errors.AccountInsolvent.selector, uint256(0), uint256(1))
        );
        collateralToken0.withdraw(assets0, Bob, Bob, positionIdList, true);

        // generate a spoof tokenId, set the Hash
        TokenId tokenId_spoof = TokenId.wrap(0).addPoolId(poolId).addLeg(
            0,
            1,
            0,
            0,
            0,
            0,
            strike / 2,
            width
        );
        TokenId[] memory spoofList = new TokenId[](1);
        spoofList[0] = tokenId_spoof;
        panopticPool.setPositionsHash(Bob, panopticPool.generatePositionsHash(spoofList));

        // cannot withdraw because Bob doesn't own the positions
        vm.expectRevert(Errors.PositionNotOwned.selector);
        collateralToken0.withdraw(assets0, Bob, Bob, spoofList, true);

        // create a tokenId with no leg, push to positionIdList and update hash
        TokenId tokenId_noLeg = TokenId.wrap(0).addPoolId(poolId);
        spoofList[0] = tokenId_noLeg;
        panopticPool.setPositionsHash(
            Bob,
            (1 << 248) + uint248(uint256(keccak256(abi.encode(tokenId_noLeg))))
        );

        // revert because positionIdList has tokenId with no leg
        vm.expectRevert(Errors.TokenIdHasZeroLegs.selector);
        collateralToken0.withdraw(assets0, Bob, Bob, spoofList, true);

        positionIdList.push(tokenId_noLeg);
        panopticPool.setPositionsHash(
            Bob,
            (2 << 248) +
                uint248(
                    uint256(keccak256(abi.encode(positionIdList[0]))) ^
                        uint256(keccak256(abi.encode(positionIdList[1])))
                )
        );
        vm.expectRevert(Errors.TokenIdHasZeroLegs.selector);
        collateralToken0.withdraw(assets0, Bob, Bob, positionIdList, true);

        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        console2.log("aa");
        positionIdList.pop();
        positionIdList.push(tokenId);

        panopticPool.setPositionsHash(
            Bob,
            (1 << 248) + uint248(uint256(keccak256(abi.encode(positionIdList[0]))))
        );

        vm.expectRevert(Errors.DuplicateTokenId.selector);
        mintOptions(
            panopticPool,
            positionIdList,
            uint128(1e9),
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    /// @notice It should revert if a user tries to withdraw by providing a tokenId they do not own.
    function test_Fail_spoof_mintWithUnownedPosition() public {
        // Initialize world state
        _initWorld(0);

        // --- Alice setup (not used in these specific tests, but good practice) ---
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);
        collateralToken0.deposit(1e18, Alice);
        collateralToken1.deposit(1e18, Alice);
        vm.stopPrank();

        // --- Bob setup (the primary actor in these tests) ---
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);
        collateralToken0.deposit(1e10, Bob);

        // Define and mint Bob's initial, legitimate position
        (width, strike) = PositionUtils.getOTMSW(
            12345, // Using a fixed seed for determinism
            67890,
            uint24(tickSpacing),
            currentTick,
            0
        );

        TokenId tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 0, 0, 0, 4094);

        positionIdList1.push(tokenId);
        panopticPool.setPositionsHash(Alice, panopticPool.generatePositionsHash(positionIdList1));

        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        mintOptions(
            panopticPool,
            positionIdList,
            uint128(1e9),
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        // 1. Arrange: Create a spoofed tokenId that Bob doesn't own
        // and manually set his positionsHash to match it.
        TokenId tokenId_spoof = TokenId.wrap(0).addPoolId(poolId).addLeg(
            0,
            1,
            0,
            0,
            0,
            0,
            strike - 600,
            width
        );
        TokenId tokenId2 = TokenId.wrap(0).addPoolId(poolId).addLeg(
            0,
            1,
            0,
            0,
            0,
            0,
            strike - 1200,
            width
        );
        TokenId[] memory spoofList = new TokenId[](2);
        spoofList[0] = tokenId_spoof;
        spoofList[1] = tokenId2;

        console2.log("countlegs", tokenId_spoof.countLegs());
        uint256 spoofHash = (1 << 248) + uint248(uint256(keccak256(abi.encode(tokenId_spoof))));
        panopticPool.setPositionsHash(Bob, spoofHash);
        // 2. Assert & 3. Act: Expect a revert when withdrawing with the spoofed list.
        vm.expectRevert(Errors.PositionNotOwned.selector);
        mintOptions(
            panopticPool,
            spoofList,
            uint128(1e9),
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    /// @notice It should revert if a user tries to withdraw by providing a tokenId they do not own.
    function test_Fail_spoof_withdrawWithUnownedPosition() public {
        // Initialize world state
        _initWorld(0);

        // --- Alice setup (not used in these specific tests, but good practice) ---
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);
        collateralToken0.deposit(1e18, Alice);
        collateralToken1.deposit(1e18, Alice);
        vm.stopPrank();

        // --- Bob setup (the primary actor in these tests) ---
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);
        collateralToken0.deposit(1e10, Bob);

        // Define and mint Bob's initial, legitimate position
        (width, strike) = PositionUtils.getOTMSW(
            12345, // Using a fixed seed for determinism
            67890,
            uint24(tickSpacing),
            currentTick,
            0
        );
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        mintOptions(
            panopticPool,
            positionIdList,
            uint128(1e9),
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        // 1. Arrange: Create a spoofed tokenId that Bob doesn't own
        // and manually set his positionsHash to match it.
        TokenId tokenId_spoof = TokenId.wrap(0).addPoolId(poolId).addLeg(
            0,
            1,
            0,
            0,
            0,
            0,
            strike / 2,
            width
        );
        TokenId[] memory spoofList = new TokenId[](1);
        spoofList[0] = tokenId_spoof;

        uint256 spoofHash = panopticPool.generatePositionsHash(spoofList);
        panopticPool.setPositionsHash(Bob, spoofHash);

        uint256 assets0 = collateralToken0.convertToAssets(collateralToken0.balanceOf(Bob));

        // 2. Assert & 3. Act: Expect a revert when withdrawing with the spoofed list.
        vm.expectRevert(Errors.PositionNotOwned.selector);
        collateralToken0.withdraw(assets0, Bob, Bob, spoofList, true);
    }

    /// @notice It should revert if a user tries to withdraw by providing a tokenId they do not own.
    function test_Fail_spoof_burnUnownedPosition() public {
        // Initialize world state
        _initWorld(0);

        // --- Alice setup (not used in these specific tests, but good practice) ---
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);
        collateralToken0.deposit(1e18, Alice);
        collateralToken1.deposit(1e18, Alice);
        vm.stopPrank();

        // --- Bob setup (the primary actor in these tests) ---
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);
        collateralToken0.deposit(1e18, Bob);

        // Define and mint Bob's initial, legitimate position
        (width, strike) = PositionUtils.getOTMSW(
            12345, // Using a fixed seed for determinism
            67890,
            uint24(tickSpacing),
            currentTick,
            0
        );
        console2.log("aa", poolId);
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        mintOptions(
            panopticPool,
            positionIdList,
            uint128(1e16),
            type(uint24).max,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        // 1. Arrange: Create a spoofed tokenId that Bob doesn't own
        // and manually set his positionsHash to match it.
        TokenId tokenId_spoof = TokenId.wrap(0).addPoolId(poolId).addLeg(
            0,
            1,
            0,
            0,
            0,
            0,
            strike + 600,
            width
        );
        TokenId[] memory spoofList = new TokenId[](1);
        spoofList[0] = tokenId_spoof;

        uint256 spoofHash = panopticPool.generatePositionsHash(spoofList);
        panopticPool.setPositionsHash(Bob, spoofHash);

        console2.log("bur");
        // 2. Assert & 3. Act: Expect a revert when withdrawing with the spoofed list. Fails before the position fingerprint with ChunkHasZeroLiquidity at mint
        vm.expectRevert(Errors.ChunkHasZeroLiquidity.selector);
        burnOptions(
            panopticPool,
            spoofList,
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    /// @notice It should revert if a user tries to withdraw by providing a tokenId they do not own.
    function test_Fail_spoof_wrongPoolId() public {
        // Initialize world state
        _initWorld(0);

        // --- Alice setup (not used in these specific tests, but good practice) ---
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);
        collateralToken0.deposit(1e18, Alice);
        collateralToken1.deposit(1e18, Alice);
        vm.stopPrank();

        // --- Bob setup (the primary actor in these tests) ---
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);
        collateralToken0.deposit(1e18, Bob);

        // Define and mint Bob's initial, legitimate position
        (width, strike) = PositionUtils.getOTMSW(
            12345, // Using a fixed seed for determinism
            67890,
            uint24(tickSpacing),
            currentTick,
            0
        );
        // first try to mint a position with the wrong tokenId
        tokenId = TokenId.wrap(0).addPoolId(poolId + 1).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);
        console2.log("0");

        vm.expectRevert(Errors.WrongPoolId.selector);
        mintOptions(
            panopticPool,
            positionIdList,
            uint128(1e16),
            type(uint24).max,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        positionIdList.pop();
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        console2.log("1");
        mintOptions(
            panopticPool,
            positionIdList,
            uint128(1e16),
            type(uint24).max,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        // 1. Arrange: Create a spoofed tokenId with the wrong poolId = poold + 1
        // and manually set his positionsHash to match it.
        TokenId tokenId_spoof = TokenId.wrap(0).addPoolId(poolId + 1).addLeg(
            0,
            1,
            0,
            0,
            0,
            0,
            strike,
            width
        );

        TokenId[] memory spoofList = new TokenId[](1);
        spoofList[0] = tokenId_spoof;

        uint256 spoofHash = panopticPool.generatePositionsHash(spoofList);
        panopticPool.setPositionsHash(Bob, spoofHash);

        console2.log("burn");
        // 2. Assert & 3. Act: Expect a revert when withdrawing with the spoofed list. Fails before the position fingerprint with ChunkHasZeroLiquidity at mint
        vm.expectRevert(Errors.WrongPoolId.selector);
        burnOptions(
            panopticPool,
            spoofList,
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        uint256 realHash = panopticPool.generatePositionsHash(positionIdList);
        panopticPool.setPositionsHash(Bob, realHash);

        TokenId tokenId2 = TokenId.wrap(0).addPoolId(poolId).addLeg(
            0,
            2,
            0,
            0,
            0,
            0,
            strike,
            width
        );
        positionIdList.push(tokenId2);

        mintOptions(
            panopticPool,
            positionIdList,
            uint128(1e16),
            type(uint24).max,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        TokenId[] memory finalList = new TokenId[](1);
        finalList[0] = tokenId2;

        panopticPool.setPositionsHash(Bob, spoofHash);

        // burn second tokenId, wrong poolId in final list but correct fingerprint
        vm.expectRevert(Errors.WrongPoolId.selector);
        burnOptions(
            panopticPool,
            tokenId2,
            spoofList,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    /// @notice It should revert if a user tries to withdraw using a tokenId with no legs.
    function test_Fail_withdrawWithZeroLegPosition() public {
        // Initialize world state
        _initWorld(0);

        // --- Alice setup (not used in these specific tests, but good practice) ---
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);
        collateralToken0.deposit(1e18, Alice);
        collateralToken1.deposit(1e18, Alice);
        vm.stopPrank();

        // --- Bob setup (the primary actor in these tests) ---
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);
        collateralToken0.deposit(1e10, Bob);

        // Define and mint Bob's initial, legitimate position
        (width, strike) = PositionUtils.getOTMSW(
            12345, // Using a fixed seed for determinism
            67890,
            uint24(tickSpacing),
            currentTick,
            0
        );
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        mintOptions(
            panopticPool,
            positionIdList,
            uint128(1e9),
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        // 1. Arrange: Create a tokenId with no legs and set the hash.
        TokenId tokenId_noLeg = TokenId.wrap(0).addPoolId(poolId);
        TokenId[] memory invalidList = new TokenId[](1);
        invalidList[0] = tokenId_noLeg;

        // Note: The hash must be set manually here because updatePositionsHash would revert.
        // This simulates a corrupted state.
        uint256 invalidHash = (1 << 248) + uint248(uint256(keccak256(abi.encode(tokenId_noLeg))));
        panopticPool.setPositionsHash(Bob, invalidHash);

        uint256 assets0 = collateralToken0.convertToAssets(collateralToken0.balanceOf(Bob));

        // 2. Assert & 3. Act: Expect a revert because the tokenId is invalid.
        vm.expectRevert(Errors.TokenIdHasZeroLegs.selector);
        collateralToken0.withdraw(assets0, Bob, Bob, invalidList, true);
    }

    /// @notice It should revert if a user tries to mint options with a list containing duplicate tokenIds.
    function test_Fail_spoof_mintOptionsWithDuplicateTokenId() public {
        // Initialize world state
        _initWorld(0);

        // --- Alice setup (not used in these specific tests, but good practice) ---
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);
        collateralToken0.deposit(1e18, Alice);
        collateralToken1.deposit(1e18, Alice);
        vm.stopPrank();

        // --- Bob setup (the primary actor in these tests) ---
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);
        collateralToken0.deposit(1e10, Bob);

        // Define and mint Bob's initial, legitimate position
        (width, strike) = PositionUtils.getOTMSW(
            12345, // Using a fixed seed for determinism
            67890,
            uint24(tickSpacing),
            currentTick,
            0
        );
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        mintOptions(
            panopticPool,
            positionIdList,
            uint128(1e9),
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        // 1. Arrange: Create a list with the same tokenId twice.
        TokenId[] memory duplicateList = new TokenId[](2);
        duplicateList[0] = tokenId; // The valid tokenId Bob already owns
        duplicateList[1] = tokenId;

        // 2. Assert & 3. Act: Expect a revert when minting with the duplicate list.
        vm.expectRevert(Errors.DuplicateTokenId.selector);
        mintOptions(
            panopticPool,
            duplicateList,
            uint128(1e9),
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    /// @notice It should revert if a user tries to mint options with a list containing duplicate tokenIds.
    function test_Fail_spoof_burnOptionsWithDuplicateTokenId() public {
        // Initialize world state
        _initWorld(0);

        // --- Alice setup (not used in these specific tests, but good practice) ---
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);
        collateralToken0.deposit(1e18, Alice);
        collateralToken1.deposit(1e18, Alice);
        vm.stopPrank();

        // --- Bob setup (the primary actor in these tests) ---
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);
        collateralToken0.deposit(1e10, Bob);

        // Define and mint Bob's initial, legitimate position
        (width, strike) = PositionUtils.getOTMSW(
            12345, // Using a fixed seed for determinism
            67890,
            uint24(tickSpacing),
            currentTick,
            0
        );
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        mintOptions(
            panopticPool,
            positionIdList,
            uint128(1e9),
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        TokenId tokenId2 = TokenId.wrap(0).addPoolId(poolId).addLeg(
            0,
            1,
            0,
            0,
            0,
            0,
            strike + 600,
            width
        );

        positionIdList.push(tokenId2);
        // 2. Assert & 3. Act: Expect a revert when minting with the duplicate list.
        mintOptions(
            panopticPool,
            positionIdList,
            uint128(1e9),
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        TokenId tokenId3 = TokenId.wrap(0).addPoolId(poolId).addLeg(
            0,
            1,
            0,
            0,
            0,
            0,
            strike + 1200,
            width
        );
        // 1. Arrange: Create a list with the same tokenId twice.
        positionIdList.push(tokenId3);

        // 2. Assert & 3. Act: Expect a revert when minting with the duplicate list.
        mintOptions(
            panopticPool,
            positionIdList,
            uint128(1e9),
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        TokenId[] memory spoofedList = new TokenId[](2);

        spoofedList[0] = tokenId;
        spoofedList[1] = tokenId;

        vm.expectRevert(Errors.DuplicateTokenId.selector);
        burnOptions(
            panopticPool,
            tokenId2,
            spoofedList,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
    }

    /*//////////////////////////////////////////////////////////////
                        MINT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Success_mint(uint256 x, uint104 shares) public {
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        shares = uint104(
            bound(shares, collateralToken0.previewWithdraw(1), (uint256(type(uint104).max)))
        );

        console2.log("test shares", shares);
        console2.log("test totalassets", collateralToken0.totalAssets());
        console2.log("test totalsupply", collateralToken0.totalSupply());
        // the amount of assets that would be deposited
        uint256 assetsToken0 = Math.mulDivRoundingUp(
            uint256(shares),
            collateralToken0.totalAssets(),
            collateralToken0.totalSupply()
        );
        uint256 assetsToken1 = Math.mulDivRoundingUp(
            uint256(shares),
            collateralToken1.totalAssets(),
            collateralToken1.totalSupply()
        );

        // approve collateral tracker to move tokens on Bob's behalf
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);

        // deposit a number of assets determined via fuzzing
        // equal deposits for both collateral token pairs for testing purposes
        uint256 returnedAssets0 = collateralToken0.mint(shares, Bob);
        uint256 returnedAssets1 = collateralToken1.mint(shares, Bob);

        vm.stopPrank();

        // check shares were calculated correctly
        assertEq(assetsToken0, returnedAssets0);
        assertEq(assetsToken1, returnedAssets1);

        // check if receiver got the shares
        assertEq(shares, collateralToken0.balanceOf(Bob));
        assertEq(shares, collateralToken1.balanceOf(Bob));

        address underlyingToken0 = collateralToken0.asset();
        address underlyingToken1 = collateralToken1.asset();

        // check if the panoptic pool got transferred the correct underlying assets
        assertEq(
            assetsToken0,
            manager.balanceOf(address(panopticPool), uint160(underlyingToken0)),
            "manager balance0"
        );
        assertEq(
            assetsToken1,
            manager.balanceOf(address(panopticPool), uint160(underlyingToken1)),
            "manager balance1"
        );
    }

    function test_Fail_mint_DepositTooLarge(uint256 x, uint256 shares) public {
        // initalize world state
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // approve collateral tracker to move tokens on the msg.senders behalf
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);

        // change the share price a little so we know it's checking the assets
        collateralToken0.deposit(2 ** 64, Bob);
        collateralToken1.deposit(2 ** 64, Bob);

        IERC20Partial(token0).transfer(address(panopticPool), 2 ** 64);
        IERC20Partial(token1).transfer(address(panopticPool), 2 ** 64);

        // mint more than the maximum (2**128 - 1)
        shares = bound(shares, collateralToken0.maxMint(address(0)), type(uint128).max);

        // clean out some incorrectly lower bounded values, the floor/ceiling functions make the line a bit murky
        vm.assume((collateralToken0.convertToAssets(shares) * 10_000) / 10_010 > type(uint104).max);

        vm.expectRevert(Errors.DepositTooLarge.selector);
        collateralToken0.mint(shares, Bob);
        vm.expectRevert(Errors.DepositTooLarge.selector);
        collateralToken1.mint(shares, Bob);
    }

    function test_Fail_mint_BelowMinimumRedemption(uint256 x) public {
        // initalize world state
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // In mint function, if shares would result in 0 assets, it should revert
        // This happens when shares is so small that previewMint returns 0
        // For this test, we'll try to mint 0 shares which should result in 0 assets

        // approve collateral tracker to move tokens on the msg.senders behalf
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);

        // attempt to mint with shares that would result in 0 assets
        // When shares = 0, previewMint should return 0 assets
        vm.expectRevert(Errors.BelowMinimumRedemption.selector);
        collateralToken0.mint(0, Bob);
        vm.expectRevert(Errors.BelowMinimumRedemption.selector);
        collateralToken1.mint(0, Bob);
    }

    /*//////////////////////////////////////////////////////////////
                        TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    // transfer
    function test_Success_transfer(uint256 x, uint104 amount) public {
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // approve collateral tracker to move tokens on Bob's behalf
        IERC20Partial(token0).approve(address(collateralToken0), amount);
        IERC20Partial(token1).approve(address(collateralToken1), amount);

        // deposit a number of assets determined via fuzzing
        // equal deposits for both collateral token pairs for testing purposes
        _mockMaxDeposit(Bob);

        uint256 bal0 = collateralToken0.balanceOf(Bob);
        uint256 bal1 = collateralToken1.balanceOf(Bob);

        // Transfer to Alice
        collateralToken0.transfer(Alice, bal0);
        collateralToken1.transfer(Alice, bal1);

        // Check Alice received the correct amounts
        assertEq(bal0, collateralToken0.balanceOf(Alice));
        assertEq(bal1, collateralToken1.balanceOf(Alice));
    }

    // transfer fail Errors.PositionCountNotZero()
    function test_Fail_transfer_positionCountNotZero(
        uint256 x,
        uint104 amount,
        uint256 widthSeed,
        int256 strikeSeed,
        uint128 positionSizeSeed
    ) public {
        _initWorld(x);

        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // approve Collateral Token's to move tokens on Bob's behalf
        IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

        // deposit a significant amount of assets into the Panoptic pool
        _mockMaxDeposit(Bob);

        // call will be minted in range
        (width, strike) = PositionUtils.getOTMSW(
            widthSeed,
            strikeSeed,
            uint24(tickSpacing),
            currentTick,
            1
        );

        // sell as Bob
        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        /// calculate position size
        (legLowerTick, legUpperTick) = tokenId.asTicks(0);

        positionSize0 = uint128(bound(positionSizeSeed, 2, 2 ** 104));
        _assumePositionValidity(Bob, tokenId, positionSize0);

        mintOptions(
            panopticPool,
            positionIdList,
            positionSize0,
            0,
            Constants.MIN_POOL_TICK,
            Constants.MAX_POOL_TICK,
            true
        );

        // Attempt a transfer to Alice from Bob
        vm.expectRevert(Errors.PositionCountNotZero.selector);
        collateralToken0.transfer(Alice, amount);

        vm.expectRevert(Errors.PositionCountNotZero.selector);
        collateralToken1.transfer(Alice, amount);
    }

    // transferFrom
    function test_Success_transferFrom(uint256 x, uint104 amount) public {
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);
        amount = uint104(bound(amount, 1, type(uint104).max));

        // approve collateral tracker to move tokens on Bob's behalf
        IERC20Partial(token0).approve(address(collateralToken0), amount);
        IERC20Partial(token1).approve(address(collateralToken1), amount);

        // approve Alice to move tokens on Bob's behalf
        collateralToken0.approve(Alice, convertToShares(amount, collateralToken0));
        collateralToken1.approve(Alice, convertToShares(amount, collateralToken1));

        // deposit a number of assets determined via fuzzing
        // equal deposits for both collateral token pairs for testing purposes
        collateralToken0.deposit(amount, Bob);
        collateralToken1.deposit(amount, Bob);

        vm.startPrank(Alice);

        uint256 bal0 = collateralToken0.balanceOf(Bob);
        uint256 bal1 = collateralToken1.balanceOf(Bob);

        // Alice executes transferFrom Bob to herself
        collateralToken0.transferFrom(Bob, Alice, bal0);
        collateralToken1.transferFrom(Bob, Alice, bal1);

        // Check Alice received the correct amounts
        assertEq(bal0, collateralToken0.balanceOf(Alice));
        assertEq(bal1, collateralToken1.balanceOf(Alice));
    }

    // transferFrom fail Errors.PositionCountNotZero()
    function test_Fail_transferFrom_positionCountNotZero(
        uint256 x,
        uint256 widthSeed,
        int256 strikeSeed,
        uint128 positionSizeSeed
    ) public {
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // approve collateral tracker to move tokens on Bob's behalf
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);

        // award corresponding shares
        _mockMaxDeposit(Bob);

        {
            // call will be minted in range
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                1
            );

            // sell as Bob
            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 1, 0, strike, width);
            positionIdList.push(tokenId);

            console2.log("strike", strike);
            positionSize0 = uint128(PositionUtils._boundLog(positionSizeSeed, 1, 104));
            _assumePositionValidity(Bob, tokenId, positionSize0);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                0,
                Constants.MAX_POOL_TICK,
                Constants.MIN_POOL_TICK,
                true
            );
        }

        // approve Alice to move shares on Bob's behalf
        IERC20Partial(address(collateralToken0)).approve(Alice, type(uint256).max);
        IERC20Partial(address(collateralToken1)).approve(Alice, type(uint256).max);

        uint256 bal0 = collateralToken0.balanceOf(Bob);
        uint256 bal1 = collateralToken1.balanceOf(Bob);

        // redeem from Alice on behalf of Bob
        vm.startPrank(Alice);

        // Check if test reverted
        vm.expectRevert(Errors.PositionCountNotZero.selector);
        collateralToken0.transferFrom(Bob, Alice, bal0);

        // Check if test reverted
        vm.expectRevert(Errors.PositionCountNotZero.selector);
        collateralToken1.transferFrom(Bob, Alice, bal1);
    }

    /*//////////////////////////////////////////////////////////////
                        SHARE REDEMPTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Success_redeem(uint256 x, uint104 shares) public {
        uint256 assetsToken0;
        uint256 assetsToken1;

        uint256 debitedBalance0;
        uint256 debitedBalance1;
        {
            _initWorld(x);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // calculate underlying assets via amount of shares
            assetsToken0 = convertToAssets(shares, collateralToken0);
            assetsToken1 = convertToAssets(shares, collateralToken1);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), assetsToken0);
            IERC20Partial(token1).approve(address(collateralToken1), assetsToken1);

            // deposit a number of assets determined via fuzzing
            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Bob);

            // Bob's asset balance after depositing to the Panoptic pool
            debitedBalance0 = IERC20Partial(token0).balanceOf(Bob);
            debitedBalance1 = IERC20Partial(token1).balanceOf(Bob);
        }

        // Bound the shares redemption to the maxRedeemable amount
        uint256 shares0 = bound(
            shares,
            collateralToken0.previewWithdraw(1),
            collateralToken0.maxRedeem(Bob)
        );
        uint256 shares1 = bound(
            shares,
            collateralToken1.previewWithdraw(1),
            collateralToken1.maxRedeem(Bob)
        );

        // amount of shares Bob held before burn
        uint256 sharesBefore0 = collateralToken0.balanceOf(Bob);
        uint256 sharesBefore1 = collateralToken1.balanceOf(Bob);

        // execute redemption
        uint256 returnedAssets0 = collateralToken0.redeem(shares0, Bob, Bob);
        uint256 returnedAssets1 = collateralToken1.redeem(shares1, Bob, Bob);

        // amount of shares Bob holds after burn
        uint256 sharesAfter0 = collateralToken0.balanceOf(Bob);
        uint256 sharesAfter1 = collateralToken1.balanceOf(Bob);

        // check shares were burned correctly
        assertEq(sharesAfter0, sharesBefore0 - shares0);
        assertEq(sharesAfter1, sharesBefore1 - shares1);

        // Bob's current asset balance after redeemed assets were returned to him
        uint256 creditedBalance0 = IERC20Partial(token0).balanceOf(Bob);
        uint256 creditedBalance1 = IERC20Partial(token1).balanceOf(Bob);

        // check correct amount of assets were moved from the the Panoptic Pool to LP
        assertEq(returnedAssets0, creditedBalance0 - debitedBalance0);
        assertEq(returnedAssets1, creditedBalance1 - debitedBalance1);
    }

    function test_Fail_redeem_exceedsMax(uint256 x, uint256 sharesSeed) public {
        // fuzz
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // approve collateral tracker to move tokens on Bob's behalf
        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);

        // deposit a number of assets determined via fuzzing
        // equal deposits for both collateral token pairs for testing purposes
        _mockMaxDeposit(Bob);

        // Get minimum amount to bound for
        // as we want to gurantee a redemption attempt of above the max redeemable amount
        uint256 exceedsMaxRedeem0 = collateralToken0.maxRedeem(Bob) + 1;
        uint256 exceedsMaxRedeem1 = collateralToken1.maxRedeem(Bob) + 1;

        // Bound the shares redemption to the maxRedeemable amount
        uint256 shares0 = bound(sharesSeed, exceedsMaxRedeem0, type(uint136).max);
        uint256 shares1 = bound(sharesSeed, exceedsMaxRedeem1, type(uint136).max);

        // execute redemption
        vm.expectRevert(Errors.ExceedsMaximumRedemption.selector);
        collateralToken0.redeem(shares0, Bob, Bob);

        vm.expectRevert(Errors.ExceedsMaximumRedemption.selector);
        collateralToken1.redeem(shares1, Bob, Bob);
    }

    function test_Fail_redeem_BelowMinimumRedemption(uint256 x, uint104 depositAssets) public {
        // initalize world state
        _initWorld(x);

        // Ensure we have a non-zero deposit amount for setup
        depositAssets = uint104(bound(depositAssets, 1e18, type(uint104).max));

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);
        depositAssets = uint104(bound(depositAssets, 1, type(uint104).max));

        // approve collateral tracker to move tokens on the msg.senders behalf
        IERC20Partial(token0).approve(address(collateralToken0), depositAssets);
        IERC20Partial(token1).approve(address(collateralToken1), depositAssets);

        // First deposit some assets so we have shares to redeem
        collateralToken0.deposit(depositAssets, Bob);
        collateralToken1.deposit(depositAssets, Bob);

        // In redeem function, if shares would result in 0 assets after previewRedeem, it should revert
        // This could happen with very small share amounts in certain rounding scenarios
        // For this test, we'll attempt to redeem 0 shares which should result in 0 assets
        vm.expectRevert(Errors.BelowMinimumRedemption.selector);
        collateralToken0.redeem(0, Bob, Bob);
        vm.expectRevert(Errors.BelowMinimumRedemption.selector);
        collateralToken1.redeem(0, Bob, Bob);

        uint256 sharesBelow0 = collateralToken0.convertToShares(1) - 1;
        uint256 sharesBelow1 = collateralToken1.convertToShares(1) - 1;
        vm.expectRevert(Errors.BelowMinimumRedemption.selector);
        collateralToken0.redeem(sharesBelow0, Bob, Bob);
        vm.expectRevert(Errors.BelowMinimumRedemption.selector);
        collateralToken1.redeem(sharesBelow1, Bob, Bob);
    }

    function test_Success_redeem_Above_BelowMinimumRedemption(
        uint256 x,
        uint104 depositAssets
    ) public {
        // initalize world state
        _initWorld(x);

        // Ensure we have a non-zero deposit amount for setup
        depositAssets = uint104(bound(depositAssets, 1e18, type(uint104).max));

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);
        depositAssets = uint104(bound(depositAssets, 1, type(uint104).max));

        // approve collateral tracker to move tokens on the msg.senders behalf
        IERC20Partial(token0).approve(address(collateralToken0), depositAssets);
        IERC20Partial(token1).approve(address(collateralToken1), depositAssets);

        // First deposit some assets so we have shares to redeem
        collateralToken0.deposit(depositAssets, Bob);
        collateralToken1.deposit(depositAssets, Bob);

        // In redeem function, if shares would result in 0 assets after previewRedeem, it should revert
        // This could happen with very small share amounts in certain rounding scenarios
        // For this test, we'll attempt to redeem 0 shares which should result in 0 assets

        uint256 sharesBelow0 = collateralToken0.convertToShares(1) - 1;
        uint256 sharesBelow1 = collateralToken1.convertToShares(1) - 1;

        //  do plus 2 to handle exact convertToShares conversion with no rounding
        collateralToken0.redeem(sharesBelow0 + 2, Bob, Bob);
        collateralToken1.redeem(sharesBelow1 + 2, Bob, Bob);
    }

    function test_Success_Redeem_onBehalf(uint128 x, uint104 shares) public {
        uint256 assetsToken0;
        uint256 assetsToken1;

        {
            _initWorld(x);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // calculate underlying assets via amount of shares
            assetsToken0 = convertToAssets(shares, collateralToken0);
            assetsToken1 = convertToAssets(shares, collateralToken1);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), assetsToken0);
            IERC20Partial(token1).approve(address(collateralToken1), assetsToken1);

            // deposit a number of assets determined via fuzzing
            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Bob);
        }

        // Bound the shares redemption to the maxRedeemable amount
        uint256 shares0 = bound(
            shares,
            collateralToken0.previewWithdraw(1),
            collateralToken0.maxRedeem(Bob)
        );
        uint256 shares1 = bound(
            shares,
            collateralToken1.previewWithdraw(1),
            collateralToken1.maxRedeem(Bob)
        );

        // amount of shares Bob held before burn
        uint256 sharesBefore0 = collateralToken0.balanceOf(Bob);
        uint256 sharesBefore1 = collateralToken1.balanceOf(Bob);

        // approve Alice to move shares/assets on Bob's behalf
        IERC20Partial(address(collateralToken0)).approve(Alice, shares0);
        IERC20Partial(address(collateralToken1)).approve(Alice, shares1);

        vm.startPrank(Alice);

        console2.log("sha", shares0, shares1);
        // execute redemption
        uint256 returnedAssets0 = collateralToken0.redeem(shares0, Alice, Bob);
        uint256 returnedAssets1 = collateralToken1.redeem(shares1, Alice, Bob);

        // amount of shares Bob holds after burn
        uint256 sharesAfter0 = collateralToken0.balanceOf(Bob);
        uint256 sharesAfter1 = collateralToken1.balanceOf(Bob);

        // check shares were burned correctly
        assertEq(sharesAfter0, sharesBefore0 - shares0);
        assertEq(sharesAfter1, sharesBefore1 - shares1);

        // Bob's current asset balance after redeemed assets were returned to him
        uint256 AliceBal0 = IERC20Partial(token0).balanceOf(Alice);
        uint256 AliceBal1 = IERC20Partial(token1).balanceOf(Alice);

        // // check correct amount of assets were moved from pool to Alice
        assertEq(returnedAssets0, AliceBal0);
        assertEq(returnedAssets1, AliceBal1);
    }

    function test_Fail_redeem_onBehalf(uint128 x) public {
        _initWorld(x);

        // hardcoded amount of shares to redeem
        uint256 shares = 10 ** 6;

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // calculate underlying assets via amount of shares
        uint256 assetsToken0 = convertToAssets(shares, collateralToken0);
        uint256 assetsToken1 = convertToAssets(shares, collateralToken1);

        // approve collateral tracker to move tokens on Bob's behalf
        IERC20Partial(token0).approve(address(collateralToken0), assetsToken0);
        IERC20Partial(token1).approve(address(collateralToken1), assetsToken1);

        // equal deposits for both collateral token pairs for testing purposes
        _mockMaxDeposit(Bob);

        // Start new interactions with user Alice
        vm.startPrank(Alice);

        // execute redemption
        // should fail as Alice is not authorized to withdraw assets on Bob behalf
        vm.expectRevert(stdError.arithmeticError);
        collateralToken0.redeem(assetsToken0, Alice, Bob);

        vm.expectRevert(stdError.arithmeticError);
        collateralToken1.redeem(assetsToken1, Alice, Bob);
    }

    function test_Fail_redeem_onBehalf_BelowMinimumRedemption(uint128 x) public {
        _initWorld(x);

        // hardcoded amount of shares to redeem
        uint256 shares = 10 ** 6;

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // calculate underlying assets via amount of shares
        uint256 assetsToken0 = convertToAssets(shares, collateralToken0);
        uint256 assetsToken1 = convertToAssets(shares, collateralToken1);

        // approve collateral tracker to move tokens on Bob's behalf
        IERC20Partial(token0).approve(address(collateralToken0), assetsToken0);
        IERC20Partial(token1).approve(address(collateralToken1), assetsToken1);

        // equal deposits for both collateral token pairs for testing purposes
        _mockMaxDeposit(Bob);

        // Bound the shares redemption to the maxRedeemable amount
        uint256 shares0 = bound(shares, 0, collateralToken0.maxRedeem(Bob));
        uint256 shares1 = bound(shares, 0, collateralToken1.maxRedeem(Bob));

        // approve Alice to move shares/assets on Bob's behalf
        IERC20Partial(address(collateralToken0)).approve(Alice, shares0);
        IERC20Partial(address(collateralToken1)).approve(Alice, shares1);

        // Start new interactions with user Alice
        vm.startPrank(Alice);

        uint256 sharesBelow0 = collateralToken0.convertToShares(1) - 1;
        uint256 sharesBelow1 = collateralToken1.convertToShares(1) - 1;

        // execute redemption
        // should fail as Alice is not authorized to withdraw assets on Bob behalf
        vm.expectRevert(Errors.BelowMinimumRedemption.selector);
        collateralToken0.redeem(sharesBelow0, Alice, Bob);

        vm.expectRevert(Errors.BelowMinimumRedemption.selector);
        collateralToken1.redeem(sharesBelow1, Alice, Bob);
    }

    /*//////////////////////////////////////////////////////////////
                        SHARE DONATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Success_donate(uint256 x, uint104 shares) public {
        uint256 assetsToken0;
        uint256 assetsToken1;

        {
            _initWorld(x);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // calculate underlying assets via amount of shares
            assetsToken0 = convertToAssets(shares, collateralToken0);
            assetsToken1 = convertToAssets(shares, collateralToken1);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), assetsToken0);
            IERC20Partial(token1).approve(address(collateralToken1), assetsToken1);

            // deposit a number of assets determined via fuzzing
            _mockMaxDeposit(Bob);
        }

        // We must ensure Bob leaves at least 1 share to avoid "CannotBurnLastShare" logic
        // We also ensure shares > 0 to avoid BelowMinimumRedemption
        uint256 maxRedeem0 = collateralToken0.maxRedeem(Bob);
        uint256 maxRedeem1 = collateralToken1.maxRedeem(Bob);

        // If maxRedeem is too small to split (need at least 2 shares: 1 to donate, 1 to keep), skip
        if (maxRedeem0 < 2) return;
        if (maxRedeem1 < 2) return;

        // Bound shares to [previewWithdraw(1), maxRedeem - 1]
        // This ensures we don't burn the very last share of the protocol
        uint256 shares0 = bound(shares, collateralToken0.previewWithdraw(1), maxRedeem0 - 1);
        uint256 shares1 = bound(shares, collateralToken1.previewWithdraw(1), maxRedeem1 - 1);

        // Snapshot state before
        uint256 sharesBefore0 = collateralToken0.balanceOf(Bob);
        uint256 sharesBefore1 = collateralToken1.balanceOf(Bob);
        uint256 totalSupplyBefore0 = collateralToken0.totalSupply();
        uint256 totalSupplyBefore1 = collateralToken1.totalSupply();

        // Expect Event
        vm.expectEmit(true, false, false, true, address(collateralToken0));
        emit Donate(Bob, shares0);
        collateralToken0.donate(shares0);

        vm.expectEmit(true, false, false, true, address(collateralToken1));
        emit Donate(Bob, shares1);
        collateralToken1.donate(shares1);

        // Snapshot state after
        uint256 sharesAfter0 = collateralToken0.balanceOf(Bob);
        uint256 sharesAfter1 = collateralToken1.balanceOf(Bob);

        // assertions
        assertEq(sharesAfter0, sharesBefore0 - shares0, "Bob shares not burned correctly");
        assertEq(sharesAfter1, sharesBefore1 - shares1, "Bob shares not burned correctly");

        assertEq(
            collateralToken0.totalSupply(),
            totalSupplyBefore0 - shares0,
            "Total supply not updated"
        );
        assertEq(
            collateralToken1.totalSupply(),
            totalSupplyBefore1 - shares1,
            "Total supply not updated"
        );

        // Verify assets did NOT move (Balance of pool should be same)
        // Indirectly checked because no transfer events were emitted and balance check would show no change
    }

    function test_Success_donate_IncreasesSharePrice(uint256 x) public {
        _initWorld(x);
        vm.startPrank(Bob);
        _grantTokens(Bob);

        // 1. Bob deposits 1000 assets -> gets 1000 shares (assuming 1:1 initially)
        uint256 depositAmt = 1000e18;
        IERC20Partial(token0).approve(address(collateralToken0), depositAmt);
        uint256 shares = collateralToken0.deposit(depositAmt, Bob);

        // 2. Alice deposits 1000 assets -> gets 1000 shares
        vm.stopPrank();
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), depositAmt);
        collateralToken0.deposit(depositAmt, Alice);

        // Current state: Total Assets 2000, Total Shares 2000. Price = 1.0

        // 3. Alice donates 500 shares
        // Alice burns 500 shares, but assets remain 2000.
        // New State: Total Assets 2000, Total Shares 1500.
        // Expected Price = 2000 / 1500 = 1.333...
        collateralToken0.donate(collateralToken0.convertToShares(500e18));
        vm.stopPrank();

        // 4. Bob checks exchange rate
        vm.startPrank(Bob);

        // If Bob redeems his 1000 shares now, he should get > 1000 assets
        uint256 previewAssets = collateralToken0.previewRedeem(shares);

        assertGt(previewAssets, 1000e18, "Share price did not increase after donation");

        // Math check: (1000 shares / 1500 total shares) * 2000 total assets = 1333.33
        assertEq(previewAssets, 1333333333333333333333);
    }

    function testFuzz_Success_donate_IncreasesSharePrice(uint256 donationSize) public {
        // 0. Init
        _initWorld(1);
        uint256 depositAmt = 1000e18;

        // 1. Bob deposits
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), depositAmt);
        uint256 bobShares = collateralToken0.deposit(depositAmt, Bob);
        vm.stopPrank();

        // 2. Alice deposits
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), depositAmt);
        uint256 aliceShares = collateralToken0.deposit(depositAmt, Alice);

        // 3. Fuzz Constraint
        // Alice cannot donate less than 0 assets and cannot donate more than she has.
        uint256 minimumDonation = collateralToken0.previewWithdraw(1);
        donationSize = bound(donationSize, minimumDonation, aliceShares);

        // Capture state before donation
        uint256 totalAssetsBefore = collateralToken0.totalAssets();
        uint256 totalSupplyBefore = collateralToken0.totalSupply();

        // 4. Alice donates (burns shares)
        collateralToken0.donate(donationSize);
        vm.stopPrank();

        // 5. Invariant Checks

        // Bob's Check: His 1000 shares should now be worth MORE than 1000 assets
        // because the total assets are the same, but there are fewer shares in existence.
        uint256 bobPreviewAssets = collateralToken0.previewRedeem(bobShares);
        assertGe(bobPreviewAssets, depositAmt, "Bob's share value should increase after donation");

        // Alice's Check: Her remaining value must be LOWER than her initial deposit
        // because she literally gave away value to the pool.
        uint256 aliceRemainingShares = aliceShares - donationSize;
        uint256 alicePreviewAssets = collateralToken0.previewRedeem(aliceRemainingShares);
        assertLt(
            alicePreviewAssets,
            depositAmt,
            "Alice's share value should decrease after donation"
        );

        assertEq(
            collateralToken0.totalAssets(),
            totalAssetsBefore,
            "Total assets changed during share donation"
        );
        assertEq(
            collateralToken0.totalSupply(),
            totalSupplyBefore - donationSize,
            "Total supply did not decrease by donation amount"
        );
        // Allow for 1 wei rounding error due to division
        assertApproxEqAbs(
            bobPreviewAssets + alicePreviewAssets,
            totalAssetsBefore,
            3,
            "Assets extracted do not match assets in vault"
        );
        assertLe(
            bobPreviewAssets + alicePreviewAssets,
            totalAssetsBefore,
            "Assets after are less than before (although should be same)"
        );
    }

    function test_Fail_donate_exceedsMax(uint256 x, uint256 sharesSeed) public {
        _initWorld(x);
        vm.startPrank(Bob);
        _grantTokens(Bob);

        IERC20Partial(token0).approve(address(collateralToken0), type(uint256).max);
        IERC20Partial(token1).approve(address(collateralToken1), type(uint256).max);
        _mockMaxDeposit(Bob);

        // We want to try donating more than we own OR more than allowed
        // maxRedeem is the strict upper bound
        uint256 maxRedeem0 = collateralToken0.maxRedeem(Bob);
        uint256 maxRedeem1 = collateralToken1.maxRedeem(Bob);

        uint256 badShares0 = bound(sharesSeed, maxRedeem0 + 1, type(uint136).max);
        uint256 badShares1 = bound(sharesSeed, maxRedeem1 + 1, type(uint136).max);

        vm.expectRevert(Errors.ExceedsMaximumRedemption.selector);
        collateralToken0.donate(badShares0);

        vm.expectRevert(Errors.ExceedsMaximumRedemption.selector);
        collateralToken1.donate(badShares1);
    }

    function test_Fail_donate_LastShare(uint256 x) public {
        // This tests the "Zero Supply Bug" protection logic
        _initWorld(x);
        vm.startPrank(Bob);
        _grantTokens(Bob);

        uint256 virtualShares = collateralToken0.totalSupply();
        uint256 oneShareAssets = collateralToken0.previewRedeem(1);

        // Deposit
        uint256 depositAmt = 1000e18;
        IERC20Partial(token0).approve(address(collateralToken0), depositAmt);
        uint256 shares = collateralToken0.deposit(depositAmt, Bob);

        // Verify Bob owns everything
        assertEq(collateralToken0.totalSupply(), shares + 1_000_000, "totalSupply");
        assertEq(collateralToken0.balanceOf(Bob), shares, "bob shares");

        // Attempt to donate EVERYTHING (totalSupply)
        // This should revert because shares >= totalSupply()
        collateralToken0.donate(shares);

        assertEq(collateralToken0.balanceOf(Bob), 0, "Bob should be empty");
        assertEq(collateralToken0.totalSupply(), virtualShares, "Only virtual shares remain");

        // 5. Verify the Virtual Shares now have huge value (PPS increased)
        assertGt(collateralToken0.previewRedeem(1), oneShareAssets);

        // The virtual shares now claim the 1 virtual asset + Bob's 1000e18 assets
        // Price Per Share = ~1000e18 / 10**6 = 10**12
        assertEq(
            collateralToken0.previewRedeem(1),
            depositAmt / virtualShares,
            "one share is 1e15 assets"
        );
    }

    function test_Fail_donate_BelowMinimumRedemption(uint256 x, uint104 depositAssets) public {
        _initWorld(x);
        depositAssets = uint104(bound(depositAssets, 1e18, type(uint104).max));

        vm.startPrank(Bob);
        _grantTokens(Bob);

        IERC20Partial(token0).approve(address(collateralToken0), depositAssets);
        IERC20Partial(token1).approve(address(collateralToken1), depositAssets);

        collateralToken0.deposit(depositAssets, Bob);
        collateralToken1.deposit(depositAssets, Bob);

        // 1. Try to donate 0
        vm.expectRevert(Errors.BelowMinimumRedemption.selector);
        collateralToken0.donate(0);

        // 2. Try to donate amount that converts to 0 assets
        // (This catches rounding issues where shares are non-zero but assets are zero)
        uint256 sharesBelow0 = collateralToken0.convertToShares(1) - 1;
        uint256 sharesBelow1 = collateralToken1.convertToShares(1) - 1;

        // Only run if rounding actually creates a gap (sharesBelow > 0)
        if (sharesBelow0 > 0) {
            vm.expectRevert(Errors.BelowMinimumRedemption.selector);
            collateralToken0.donate(sharesBelow0);
        }
        if (sharesBelow1 > 0) {
            vm.expectRevert(Errors.BelowMinimumRedemption.selector);
            collateralToken1.donate(sharesBelow1);
        }
    }

    function test_Fail_donate_RevertDueToAccruedInterestLiquidityCrunch() public {
        _initWorld(0);

        uint104 assets = 1000 ether; // Use a fixed deposit amount

        // Get the initial borrow index right after initialization
        uint128 initialBorrowIndex = collateralToken0.borrowIndex();

        // --- Alice deposits ---
        vm.startPrank(Alice);
        _grantTokens(Alice);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        uint256 initialShares = collateralToken0.deposit(assets, Alice);
        IERC20Partial(token1).approve(address(collateralToken1), assets);
        collateralToken1.deposit(assets, Alice);
        vm.stopPrank();

        // --- Bob deposits + Mints ---
        vm.startPrank(Bob);
        _grantTokens(Bob);
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        collateralToken0.deposit(assets, Bob);

        (currentSqrtPriceX96, currentTick, , , , , ) = pool.slot0();

        strike = 198600 + 6000;
        width = 2;

        tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
        positionIdList.push(tokenId);

        mintOptions(
            panopticPool,
            positionIdList,
            (assets * 15) / 10,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );

        // At this specific moment (price 1:1), maxRedeem is exactly 100 shares (worth 100 assets).
        // But Bob has 1000 shares.
        // If he tried to donate 100 shares now, it would work.
        // We want to show that INTEREST ACCRUAL specifically tightens this constraint.

        // 3. Accrue Massive Interest
        // We warp time forward significantly.
        uint256 blockAfterBorrow = block.number;
        uint256 timestampAfterBorrow = block.timestamp;
        uint32 timeSkip = 20 * 365 days; // Large time jump to generate significant interest

        vm.roll(blockAfterBorrow + timeSkip / 12);
        vm.warp(timestampAfterBorrow + timeSkip);

        burnOptions(
            panopticPool,
            positionIdList,
            new TokenId[](0),
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            true
        );
        assertEq(collateralToken0.balanceOf(Bob), 0, "bob has zero balance");
        // 4. Alice burns

        vm.startPrank(Alice);
        uint256 maxRedeemableShares = collateralToken0.maxRedeem(Alice);

        assertLt(maxRedeemableShares, initialShares, "less shares due to interest rate accrual");

        uint256 aliceAssetValue = collateralToken0.convertToAssets(
            collateralToken0.balanceOf(Alice)
        );
        // 5. Bob tries to donate what WAS a valid liquid amount (e.g. 100 shares)
        vm.expectRevert(Errors.ExceedsMaximumRedemption.selector);
        collateralToken0.donate(initialShares);

        vm.expectRevert(Errors.ExceedsMaximumRedemption.selector);
        collateralToken0.donate(maxRedeemableShares + 1);

        collateralToken0.donate(maxRedeemableShares);

        assertLt(
            collateralToken0.convertToAssets(collateralToken0.balanceOf(Alice)),
            aliceAssetValue,
            "Alice's balance is zero"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        DELEGATE/REVOKE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_success_delegate_virtual(uint256 x) public {
        _initWorld(x);

        panopticPool.delegate(Alice, collateralToken0);
        panopticPool.delegate(Alice, collateralToken1);

        assertEq(type(uint248).max, collateralToken0.balanceOf(Alice));
        assertEq(type(uint248).max, collateralToken1.balanceOf(Alice));
    }

    function test_success_revoke_virtual(uint256 x) public {
        _initWorld(x);

        panopticPool.delegate(Alice, collateralToken0);
        panopticPool.delegate(Alice, collateralToken1);

        panopticPool.revoke(Alice, collateralToken0);
        panopticPool.revoke(Alice, collateralToken1);

        assertEq(0, collateralToken0.balanceOf(Alice));
        assertEq(0, collateralToken1.balanceOf(Alice));
    }

    function test_success_refund_positive(uint256 x, uint104 shares) public {
        {
            // fuzz
            _initWorld(x);

            // Invoke all interactions with the Collateral Tracker from user Alice
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            uint256 assetsToken0 = bound(
                convertToAssets(shares, collateralToken0),
                1,
                type(uint104).max
            );
            uint256 assetsToken1 = bound(
                convertToAssets(shares, collateralToken1),
                1,
                type(uint104).max
            );

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), assetsToken0);
            IERC20Partial(token1).approve(address(collateralToken1), assetsToken1);

            // deposit a number of assets determined via fuzzing
            // equal deposits for both collateral token pairs for testing purposes
            collateralToken0.deposit(uint128(assetsToken0), Alice);
            collateralToken1.deposit(uint128(assetsToken1), Alice);
        }

        // invoke delegate transactions from the Panoptic pool
        panopticPool.refund(
            Alice,
            Bob,
            int256(convertToAssets(collateralToken0.balanceOf(Alice), collateralToken0)),
            collateralToken0
        );
        panopticPool.refund(
            Alice,
            Bob,
            int256(convertToAssets(collateralToken1.balanceOf(Alice), collateralToken1)),
            collateralToken1
        );

        // check delegatee balance after
        uint256 sharesAfter0 = collateralToken0.balanceOf(Alice);
        uint256 sharesAfter1 = collateralToken1.balanceOf(Alice);

        assertApproxEqAbs(0, convertToAssets(sharesAfter0, collateralToken0), 5);
        assertApproxEqAbs(0, convertToAssets(sharesAfter1, collateralToken1), 5);
    }

    function test_success_refund_negative(uint256 x, uint104 assets) public {
        // fuzz
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);
        assets = uint104(bound(assets, 1, type(uint104).max));

        // approve collateral tracker to move tokens on Bob's behalf
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        IERC20Partial(token1).approve(address(collateralToken1), assets);

        // deposit a number of assets determined via fuzzing
        // equal deposits for both collateral token pairs for testing purposes
        collateralToken0.deposit(assets, Bob);
        collateralToken1.deposit(assets, Bob);

        // check delegatee balance before
        uint256 sharesBefore0 = collateralToken0.balanceOf(Bob);

        // invoke delegate transactions from the Panoptic pool
        panopticPool.refund(
            Alice,
            Bob,
            -int256(convertToAssets(sharesBefore0, collateralToken0)),
            collateralToken0
        );

        panopticPool.refund(
            Alice,
            Bob,
            -int256(convertToAssets(sharesBefore0, collateralToken1)),
            collateralToken1
        );

        // check delegatee balance after
        uint256 sharesAfter0 = collateralToken0.balanceOf(Bob);
        uint256 sharesAfter1 = collateralToken1.balanceOf(Bob);

        assertApproxEqAbs(0, convertToAssets(sharesAfter0, collateralToken0), 5);
        assertApproxEqAbs(0, convertToAssets(sharesAfter1, collateralToken1), 5);
    }

    // access control on delegate/revoke/settlement functions
    function test_Fail_All_OnlyPanopticPool(uint256 x, address caller) public {
        _initWorld(x);
        vm.assume(caller != address(panopticPool));

        vm.prank(caller);

        vm.expectRevert(Errors.NotPanopticPool.selector);
        collateralToken0.delegate(address(0));

        vm.expectRevert(Errors.NotPanopticPool.selector);
        collateralToken0.revoke(address(0));

        vm.expectRevert(Errors.NotPanopticPool.selector);
        collateralToken0.settleLiquidation(address(0), address(0), 0);

        vm.expectRevert(Errors.NotPanopticPool.selector);
        collateralToken0.refund(address(0), address(0), 0);

        vm.expectRevert(Errors.NotPanopticPool.selector);
        collateralToken0.settleMint(
            address(0),
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            RiskParameters.wrap(0)
        );

        vm.expectRevert(Errors.NotPanopticPool.selector);
        collateralToken0.settleBurn(
            address(0),
            0,
            0,
            Constants.MAX_POOL_TICK,
            Constants.MIN_POOL_TICK,
            RiskParameters.wrap(0)
        );
    }

    /*//////////////////////////////////////////////////////////////
                            GUARDIANSHIP
    //////////////////////////////////////////////////////////////*/

    function test_Fail_OnlyGuardian_lockPool(uint256 x, address caller) public {
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool, caller);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            vm.expectRevert(Errors.NotGuardian.selector);
            riskEngine.lockPool(panopticPool);
        }
    }

    function test_Fail_OnlyGuardian_unlockPool(uint256 x, address caller) public {
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool, caller);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(caller);
            console2.log("guardian, caller", riskEngine.guardian(), caller);
            riskEngine.lockPool(panopticPool);

            vm.startPrank(Bob);
            vm.expectRevert(Errors.NotGuardian.selector);
            riskEngine.unlockPool(panopticPool);
        }
    }

    function test_Fail_OnlyGuardian_collect(uint256 x, address caller) public {
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool, caller);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.expectRevert(Errors.NotGuardian.selector);
            riskEngine.collect(token0, Bob);

            vm.expectRevert(Errors.NotGuardian.selector);
            riskEngine.collect(token1, Bob);

            vm.expectRevert(Errors.NotGuardian.selector);
            riskEngine.collect(token0, Bob, 0);

            vm.expectRevert(Errors.NotGuardian.selector);
            riskEngine.collect(token1, Bob, 0);
        }
    }

    function test_success_OnlyGuardian_lockPool_oraclePackState(uint256 x, address caller) public {
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool, caller);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(caller);
            riskEngine.lockPool(panopticPool);

            (, , , , OraclePack oraclePack) = panopticPool.getOracleTicks();
            assertEq(oraclePack.lockMode(), 3, "lock mode");
        }
    }

    function test_success_OnlyGuardian_unlockPool_oraclePackState(
        uint256 x,
        address caller
    ) public {
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool, caller);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(caller);
            riskEngine.lockPool(panopticPool);

            (, , , , OraclePack oraclePack) = panopticPool.getOracleTicks();
            assertEq(oraclePack.lockMode(), 3, "lock mode");

            riskEngine.unlockPool(panopticPool);

            (, , , , oraclePack) = panopticPool.getOracleTicks();
            assertEq(oraclePack.lockMode(), 0, "unlock mode");
        }
    }

    function test_success_OnlyGuardian_lockPool_noMint_burnOnly(uint256 x, address caller) public {
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool, caller);

            vm.startPrank(Alice);

            _grantTokens(Alice);
            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);
            // award corresponding shares
            _mockMaxDeposit(Alice);

            strike = (currentTick / tickSpacing) * tickSpacing;
            width = 2;

            positionSize0 = 10 ** 9;
            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
            positionIdList.push(tokenId);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(caller);
            riskEngine.lockPool(panopticPool);

            vm.startPrank(Bob);
            _grantTokens(Bob);
            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);
            // award corresponding shares
            _mockMaxDeposit(Bob);
            // Bob cannot mint
            vm.expectRevert(Errors.StaleOracle.selector);
            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            vm.startPrank(Alice);

            // Alice can still close
            burnOptions(
                panopticPool,
                positionIdList,
                new TokenId[](0),
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            vm.startPrank(caller);
            riskEngine.unlockPool(panopticPool);

            vm.startPrank(Bob);
            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }
    }

    function test_success_builderCode_payouts(
        uint256 x,
        address caller,
        uint256 builderCode
    ) public {
        vm.skip(true);
        vm.assume(builderCode != 0);
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool, caller);

            vm.startPrank(Alice);

            _grantTokens(Alice);
            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);
            // award corresponding shares
            _mockMaxDeposit(Alice);

            strike = (currentTick / tickSpacing) * tickSpacing;
            width = 2;

            positionSize0 = 10 ** 9;
            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
            positionIdList.push(tokenId);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true,
                builderCode
            );

            // mimic pool activity
            twoWaySwap(10 ** 18);

            vm.startPrank(Alice);

            console2.log("burnHere");
            // close
            burnOptions(
                panopticPool,
                positionIdList,
                new TokenId[](0),
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }
    }

    function test_success_builderCode_collects(
        uint256 x,
        address caller,
        uint256 builderCode
    ) public {
        vm.skip(true);
        vm.assume(builderCode != 0);
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool, caller);
            vm.startPrank(caller);

            uint48 _builderCode = 3555421077;
            BuilderWallet builderWallet = BuilderWallet(
                builderFactory.deployBuilder(uint48(_builderCode), Bob)
            );

            console2.log("builderWallet", address(builderWallet));

            assertTrue(uint160(address(builderWallet)) < type(uint128).max, "fits in a uint128");
            assertTrue(false);

            vm.startPrank(Alice);

            _grantTokens(Alice);
            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);
            // award corresponding shares
            _mockMaxDeposit(Alice);

            strike = (currentTick / tickSpacing) * tickSpacing;
            width = 2;

            positionSize0 = 10 ** 9;
            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
            positionIdList.push(tokenId);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true,
                builderCode
            );

            // mimic pool activity
            twoWaySwap(10 ** 18);
            twoWaySwap(10 ** 18);
            twoWaySwap(10 ** 18);
            twoWaySwap(10 ** 18);
            twoWaySwap(10 ** 18);
            twoWaySwap(10 ** 18);
            twoWaySwap(10 ** 18);
            twoWaySwap(10 ** 18);

            vm.startPrank(Alice);

            console2.log("burnHere");
            // close
            burnOptions(
                panopticPool,
                positionIdList,
                new TokenId[](0),
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true,
                builderCode
            );
        }
        vm.startPrank(caller);

        riskEngine.collect(address(collateralToken0), caller, 1);

        riskEngine.collect(address(collateralToken0), caller);
    }

    /*//////////////////////////////////////////////////////////////
                            STRANGLES
    //////////////////////////////////////////////////////////////*/

    function test_Success_collateralCheck_shortStrangle(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 widthSeed2,
        int256 strikeSeed2,
        int24 atTick,
        uint128 utilizationSeed
    ) public {
        vm.assume(strikeSeed != strikeSeed2);

        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                0
            );

            (width1, strike1) = PositionUtils.getOTMSW(
                widthSeed2,
                strikeSeed2,
                uint24(tickSpacing),
                currentTick,
                1
            );

            vm.assume(width != width1 || strike != strike1);
            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
            tokenId = tokenId.addLeg(1, 1, 0, 0, 1, 1, strike1, width1);
            positionIdList.push(tokenId);

            /// calculate position size
            (legLowerTick, legUpperTick) = tokenId.asTicks(0);

            positionSize0 = uint128(bound(positionSizeSeed, 10 ** 18, 10 ** 20));
            _assumePositionValidity(Bob, tokenId, positionSize0);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        {
            // Alice buys
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            _mockMaxDeposit(Alice);

            tokenId1 = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 1, strike, width);
            tokenId1 = tokenId1.addLeg(1, 1, 0, 0, 1, 0, strike1, width1);
            positionIdList1.push(tokenId1);

            _assumePositionValidity(Alice, tokenId1, positionSize0 / 2);

            uint256 snapshot = vm.snapshot();

            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 2,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            uint256 inAMMOffset = collateralToken0._inAMM();

            vm.revertTo(snapshot);

            // set utilization before minting
            // take into account the offsets as states are updated before utilization is checked for the mint
            uint64 targetUtilization = uint64(bound(utilizationSeed, 1, 9_999));
            setUtilization(collateralToken0, token1, int64(targetUtilization), inAMMOffset, false);

            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 2,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Alice, tokenId1);

            uint128 poolUtilizations = uint128(poolUtilization0 == 0 ? 1 : poolUtilization0) +
                (uint128(poolUtilization1 == 0 ? 1 : poolUtilization1) << 64);

            (uint128 tokensRequired0, uint128 tokensRequired1) = _strangleTokensRequired(
                tokenId1,
                positionSize0 / 2,
                poolUtilizations,
                atTick
            );

            // checks tokens required
            assertEq(tokensRequired0, tokenData0.leftSlot(), "required token0");
            assertEq(tokensRequired1, tokenData1.leftSlot(), "required token1");
        }

        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Alice,
                currentTick,
                positionIdList1
            );

            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    function test_Success_collateralCheck_shortStrangle_token0(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 widthSeed2,
        int256 strikeSeed2,
        int24 atTick,
        uint128 utilizationSeed
    ) public {
        vm.assume(strikeSeed != strikeSeed2);

        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool, 10_000_000, 10_000_000);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                0
            );

            (width1, strike1) = PositionUtils.getOTMSW(
                widthSeed2,
                strikeSeed2,
                uint24(tickSpacing),
                currentTick,
                1
            );

            vm.assume(width != width1 || strike != strike1);
            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
            tokenId = tokenId.addLeg(1, 1, 0, 0, 1, 1, strike1, width1);
            positionIdList.push(tokenId);

            /// calculate position size
            (legLowerTick, legUpperTick) = tokenId.asTicks(0);

            positionSize0 = uint128(bound(positionSizeSeed, 10 ** 15, 10 ** 17));
            _assumePositionValidity(Bob, tokenId, positionSize0);

            console2.log("mint1");
            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        {
            // Alice sells one-sided
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            _mockMaxDeposit(Alice);

            tokenId1 = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 1, strike, width);
            tokenId1 = tokenId1.addLeg(1, 1, 0, 0, 1, 0, strike1, width1);
            positionIdList1.push(tokenId1);

            _assumePositionValidity(Alice, tokenId1, positionSize0 / 2);

            (, LeftRightSigned shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId1,
                positionSize0 / 2,
                true
            );

            collateralToken1.withdraw(
                collateralToken1.maxWithdraw(Alice) - uint128(shortAmounts.leftSlot()) / 1000 - 1,
                Alice,
                Alice
            );

            uint256 snapshot = vm.snapshot();
            console2.log("mint2");

            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 2,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
            uint256 inAMMOffset = collateralToken0._inAMM();

            vm.revertTo(snapshot);

            // set utilization before minting
            // take into account the offsets as states are updated before utilization is checked for the mint
            uint64 targetUtilization = uint64(bound(utilizationSeed, 1, 4_999));
            setUtilization(collateralToken0, token1, int64(targetUtilization), inAMMOffset, false);
            console2.log("mint3", targetUtilization);
            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 2,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Alice, tokenId1);

            uint128 poolUtilizations = uint128(poolUtilization0 == 0 ? 1 : poolUtilization0) +
                (uint128(poolUtilization1 == 0 ? 1 : poolUtilization1) << 64);

            (uint128 tokensRequired0, uint128 tokensRequired1) = _strangleTokensRequired(
                tokenId1,
                positionSize0 / 2,
                poolUtilizations,
                atTick
            );

            // checks tokens required
            assertEq(tokensRequired0, tokenData0.leftSlot(), "required token0");
            assertEq(tokensRequired1, tokenData1.leftSlot(), "required token1");
        }

        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Alice,
                currentTick,
                positionIdList1
            );

            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    function test_Fail_collateralCheck_noCross0(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 widthSeed2,
        int256 strikeSeed2,
        int24 atTick,
        uint128 utilizationSeed
    ) public {
        vm.assume(strikeSeed != strikeSeed2);

        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool, 0, 10_000_000);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                0
            );

            (width1, strike1) = PositionUtils.getOTMSW(
                widthSeed2,
                strikeSeed2,
                uint24(tickSpacing),
                currentTick,
                1
            );

            vm.assume(width != width1 || strike != strike1);
            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
            tokenId = tokenId.addLeg(1, 1, 0, 0, 1, 1, strike1, width1);
            positionIdList.push(tokenId);

            /// calculate position size
            (legLowerTick, legUpperTick) = tokenId.asTicks(0);

            positionSize0 = uint128(bound(positionSizeSeed, 10 ** 18, 10 ** 20));
            _assumePositionValidity(Bob, tokenId, positionSize0);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        {
            // Alice sells one-sided
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            _mockMaxDeposit(Alice);

            tokenId1 = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 1, strike, width);
            tokenId1 = tokenId1.addLeg(1, 1, 0, 0, 1, 0, strike1, width1);
            positionIdList1.push(tokenId1);

            _assumePositionValidity(Alice, tokenId1, positionSize0 / 2);

            (, LeftRightSigned shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId1,
                positionSize0 / 2,
                true
            );

            collateralToken1.withdraw(
                collateralToken1.maxWithdraw(Alice) - uint128(shortAmounts.leftSlot()) / 1000 - 1,
                Alice,
                Alice
            );

            vm.expectRevert(
                abi.encodeWithSelector(Errors.AccountInsolvent.selector, uint256(0), uint256(1))
            );
            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 2,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }
    }

    function test_Fail_collateralCheck_noCross1(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 widthSeed2,
        int256 strikeSeed2,
        int24 atTick,
        uint128 utilizationSeed
    ) public {
        vm.assume(strikeSeed != strikeSeed2);

        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool, 10_000_000, 0);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                0
            );

            (width1, strike1) = PositionUtils.getOTMSW(
                widthSeed2,
                strikeSeed2,
                uint24(tickSpacing),
                currentTick,
                1
            );

            vm.assume(width != width1 || strike != strike1);
            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
            tokenId = tokenId.addLeg(1, 1, 0, 0, 1, 1, strike1, width1);
            positionIdList.push(tokenId);

            /// calculate position size
            (legLowerTick, legUpperTick) = tokenId.asTicks(0);

            positionSize0 = uint128(bound(positionSizeSeed, 10 ** 18, 10 ** 20));
            _assumePositionValidity(Bob, tokenId, positionSize0);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        {
            // Alice sells one-sided
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            _mockMaxDeposit(Alice);

            tokenId1 = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 1, strike, width);
            tokenId1 = tokenId1.addLeg(1, 1, 0, 0, 1, 0, strike1, width1);
            positionIdList1.push(tokenId1);

            _assumePositionValidity(Alice, tokenId1, positionSize0 / 2);

            (, LeftRightSigned shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId1,
                positionSize0 / 2,
                true
            );

            collateralToken0.withdraw(
                collateralToken0.maxWithdraw(Alice) - uint128(shortAmounts.rightSlot()) / 1000 - 1,
                Alice,
                Alice
            );

            vm.expectRevert(
                abi.encodeWithSelector(Errors.AccountInsolvent.selector, uint256(0), uint256(1))
            );
            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 2,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }
    }

    function test_Success_collateralCheck_shortStrangle_token1(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 widthSeed2,
        int256 strikeSeed2,
        int24 atTick,
        uint128 utilizationSeed
    ) public {
        vm.assume(strikeSeed != strikeSeed2);

        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                0
            );

            (width1, strike1) = PositionUtils.getOTMSW(
                widthSeed2,
                strikeSeed2,
                uint24(tickSpacing),
                currentTick,
                1
            );

            vm.assume(width != width1 || strike != strike1);
            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 0, strike, width);
            tokenId = tokenId.addLeg(1, 1, 0, 0, 1, 1, strike1, width1);
            positionIdList.push(tokenId);

            /// calculate position size
            (legLowerTick, legUpperTick) = tokenId.asTicks(0);

            positionSize0 = uint128(bound(positionSizeSeed, 10 ** 18, 10 ** 20));
            _assumePositionValidity(Bob, tokenId, positionSize0);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        {
            // Alice sells one-sided
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            _mockMaxDeposit(Alice);

            tokenId1 = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 0, 1, strike, width);
            tokenId1 = tokenId1.addLeg(1, 1, 0, 0, 1, 0, strike1, width1);
            positionIdList1.push(tokenId1);

            _assumePositionValidity(Alice, tokenId1, positionSize0 / 2);

            (, LeftRightSigned shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId1,
                positionSize0 / 2,
                true
            );

            collateralToken0.withdraw(
                collateralToken0.maxWithdraw(Alice) - uint128(shortAmounts.rightSlot()) / 1000 - 1,
                Alice,
                Alice
            );

            uint256 snapshot = vm.snapshot();

            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 2,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
            uint256 inAMMOffset = collateralToken0._inAMM();

            vm.revertTo(snapshot);

            // set utilization before minting
            // take into account the offsets as states are updated before utilization is checked for the mint
            uint64 targetUtilization = uint64(bound(utilizationSeed, 1, 9_999));
            setUtilization(collateralToken0, token1, int64(targetUtilization), inAMMOffset, false);

            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 2,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Alice, tokenId1);

            uint128 poolUtilizations = uint128(poolUtilization0 == 0 ? 1 : poolUtilization0) +
                (uint128(poolUtilization1 == 0 ? 1 : poolUtilization1) << 64);

            (uint128 tokensRequired0, uint128 tokensRequired1) = _strangleTokensRequired(
                tokenId1,
                positionSize0 / 2,
                poolUtilizations,
                atTick
            );

            // checks tokens required
            assertEq(tokensRequired0, tokenData0.leftSlot(), "required token0");
            assertEq(tokensRequired1, tokenData1.leftSlot(), "required token1");
        }

        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Alice,
                currentTick,
                positionIdList1
            );

            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    /*//////////////////////////////////////////////////////////////
                            SPREADS
    //////////////////////////////////////////////////////////////*/

    function test_Success_collateralCheck_OTMputSpread(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        uint256 widthSeed2,
        int256 strikeSeed,
        int256 strikeSeed2,
        int24 atTick,
        uint24 swapSizeSeed
    ) public {
        vm.assume(strikeSeed != strikeSeed2);

        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // award corresponding shares
            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                1
            );

            (width1, strike1) = PositionUtils.getOTMSW(
                widthSeed2,
                strikeSeed2,
                uint24(tickSpacing),
                currentTick,
                1
            );

            vm.assume(width != width1 || strike != strike1);
            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 1, 0, strike, width);
            tokenId = tokenId.addLeg(1, 1, 1, 0, 1, 1, strike1, width1);
            positionIdList.push(tokenId);

            positionSize0 = uint128(bound(positionSizeSeed, 2, 2 ** 128));
            _assumePositionValidity(Bob, tokenId, positionSize0);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        {
            // Alice buys
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // award corresponding shares
            _mockMaxDeposit(Alice);

            tokenId1 = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 1, 1, strike, width);
            tokenId1 = tokenId1.addLeg(1, 1, 1, 0, 1, 0, strike1, width1);
            positionIdList1.push(tokenId1);

            _assumePositionValidity(Alice, tokenId1, positionSize0 / 2);

            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 2,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        // mimic pool activity
        twoWaySwap(swapSizeSeed);

        // check requirement at fuzzed tick
        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Alice, tokenId1);

            uint128 poolUtilizations = uint128(poolUtilization0) +
                (uint128(poolUtilization1) << 64);

            uint128 required = _spreadTokensRequired(
                tokenId1,
                positionSize0 / 2,
                poolUtilizations,
                atTick
            );

            // only add premium requirement if there is net premia owed
            int128 premium0 = int256(uint256($shortPremia.rightSlot())) -
                int256(uint256($longPremia.rightSlot())) <
                0
                ? int128(
                    DECIMALS *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.rightSlot())) -
                                    int256(uint256($longPremia.rightSlot()))
                            )
                        )
                ) / int128(DECIMALS)
                : int128(0);
            required += int256(uint256($shortPremia.leftSlot())) -
                int256(uint256($longPremia.leftSlot())) <
                0
                ? uint128(
                    (uint128(DECIMALS) *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.leftSlot())) -
                                    int256(uint256($longPremia.leftSlot()))
                            )
                        )) / uint128(DECIMALS)
                )
                : 0;

            assertEq(premium0, int128(tokenData0.leftSlot()), "required token0");
            assertEq(required, tokenData1.leftSlot(), "required token1");
        }

        {
            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Alice,
                currentTick,
                positionIdList1
            );

            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    function test_Success_collateralCheck_OTMcallSpread(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        uint256 widthSeed2,
        int256 strikeSeed,
        int256 strikeSeed2,
        int24 atTick,
        uint256 swapSizeSeed
    ) public {
        vm.assume(strikeSeed != strikeSeed2);

        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // award corresponding shares
            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                0
            );

            (width1, strike1) = PositionUtils.getOTMSW(
                widthSeed2,
                strikeSeed2,
                uint24(tickSpacing),
                currentTick,
                0
            );

            vm.assume(width != width1 || strike != strike1);
            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, strike, width);
            tokenId = tokenId.addLeg(1, 1, 1, 0, 0, 1, strike1, width1);
            positionIdList.push(tokenId);

            positionSize0 = uint128(bound(positionSizeSeed, 2, 2 ** 128));
            _assumePositionValidity(Bob, tokenId, positionSize0);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        {
            // Alice buys
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Alice);

            tokenId1 = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 0, 1, strike, width);
            tokenId1 = tokenId1.addLeg(1, 1, 1, 0, 0, 0, strike1, width1);
            positionIdList1.push(tokenId1);

            _assumePositionValidity(Alice, tokenId1, positionSize0 / 4);

            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 4,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        // mimic pool activity
        twoWaySwap(swapSizeSeed);

        // check requirement at fuzzed tick
        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Alice, tokenId1);

            uint128 poolUtilizations = uint128(poolUtilization0) +
                (uint128(poolUtilization1) << 64);

            uint128 required = _spreadTokensRequired(
                tokenId1,
                positionSize0 / 4,
                poolUtilizations,
                atTick
            );

            // only add premium requirement if there is net premia owed
            required += int256(uint256($shortPremia.rightSlot())) -
                int256(uint256($longPremia.rightSlot())) <
                0
                ? uint128(
                    (uint128(DECIMALS) *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.rightSlot())) -
                                    int256(uint256($longPremia.rightSlot()))
                            )
                        )) / uint128(DECIMALS)
                )
                : 0;
            int128 premium1 = int256(uint256($shortPremia.leftSlot())) -
                int256(uint256($longPremia.leftSlot())) <
                0
                ? int128(
                    (DECIMALS *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.leftSlot())) -
                                    int256(uint256($longPremia.leftSlot()))
                            )
                        )) / uint128(DECIMALS)
                )
                : int128(0);
            assertEq(required, tokenData0.leftSlot(), "required token0");
            assertEq(premium1, int128(tokenData1.leftSlot()), "required token1");
        }

        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Alice,
                currentTick,
                positionIdList1
            );

            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    function test_Success_collateralCheck_ITMputSpread(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        uint256 widthSeed2,
        int256 strikeSeed,
        int256 strikeSeed2,
        int24 atTick,
        uint256 swapSizeSeed
    ) public {
        vm.assume(strikeSeed != strikeSeed2);

        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // award corresponding shares
            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getITMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                1
            );

            (width1, strike1) = PositionUtils.getITMSW(
                widthSeed2,
                strikeSeed2,
                uint24(tickSpacing),
                currentTick,
                1
            );

            vm.assume(width != width1 || strike != strike1);
            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 1, 0, strike, width);
            tokenId = tokenId.addLeg(1, 1, 1, 0, 1, 1, strike1, width1);
            positionIdList.push(tokenId);

            /// calculate position
            positionSize0 = uint128(bound(positionSizeSeed, 2, 2 ** 64));
            _assumePositionValidity(Bob, tokenId, positionSize0);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        {
            // Alice buys
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // award corresponding shares
            _mockMaxDeposit(Alice);

            tokenId1 = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 1, 1, strike, width);
            tokenId1 = tokenId1.addLeg(1, 1, 1, 0, 1, 0, strike1, width1);
            positionIdList1.push(tokenId1);

            _assumePositionValidity(Alice, tokenId1, positionSize0 / 2);

            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 2,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        // mimic pool activity
        twoWaySwap(swapSizeSeed);

        // check requirement at fuzzed tick
        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Alice, tokenId1);

            uint128 poolUtilizations = uint128(poolUtilization0) +
                (uint128(poolUtilization1) << 64);

            uint128 required = _spreadTokensRequired(
                tokenId1,
                positionSize0 / 2,
                poolUtilizations,
                atTick
            );

            // only add premium requirement if there is net premia owed
            int128 premium0 = int256(uint256($shortPremia.rightSlot())) -
                int256(uint256($longPremia.rightSlot())) <
                0
                ? int128(
                    DECIMALS *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.rightSlot())) -
                                    int256(uint256($longPremia.rightSlot()))
                            )
                        )
                ) / int128(DECIMALS)
                : int128(0);
            required += int256(uint256($shortPremia.leftSlot())) -
                int256(uint256($longPremia.leftSlot())) <
                0
                ? uint128(
                    (uint128(DECIMALS) *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.leftSlot())) -
                                    int256(uint256($longPremia.leftSlot()))
                            )
                        )) / uint128(DECIMALS)
                )
                : 0;

            assertEq(premium0, int128(tokenData0.leftSlot()), "required token0");
            assertEq(required, tokenData1.leftSlot(), "required token1");
        }

        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Alice,
                currentTick,
                positionIdList1
            );

            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    function test_Success_collateralCheck_PutCallAllTicks(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        uint256 swapSizeSeed
    ) public {
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // award corresponding shares
            _mockMaxDeposit(Bob);
            console2.log("jere?", int24(bound(strikeSeed, -800000, 800000)));

            console2.log("bal0", collateralToken0.balanceOf(Bob));
            console2.log("bal1", collateralToken1.balanceOf(Bob));
            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1 + ((x >> 2) % 127),
                (x % 2),
                0,
                (x >> 1) % 2,
                0,
                int24(bound(strikeSeed, -500000, 500000)),
                int24(uint24(bound(widthSeed, 1, 4095)))
            );
            positionIdList.push(tokenId);

            /// calculate position
            positionSize0 = uint128(PositionUtils._boundLog(positionSizeSeed, 1, 24));
            (legLowerTick, legUpperTick) = tokenId.asTicks(0);

            (int24 minTick, int24 maxTick) = sfpm.getEnforcedTickLimits(tokenId.poolId());

            vm.assume(legUpperTick < maxTick);
            vm.assume(legLowerTick > minTick);
            _assumePositionValidity(Bob, tokenId, positionSize0);

            console2.log("");
            console2.log("Mint");
            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        // mimic pool activity
        twoWaySwap(swapSizeSeed);

        // check requirement at fuzzed tick

        {
            for (
                int24 atTick = (-887272 / tickSpacing) * tickSpacing + tickSpacing;
                atTick < (887272 / tickSpacing) * tickSpacing;
                atTick += 1000 * tickSpacing
            ) {
                ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                    .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

                (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine
                    .getMargin(
                        posBalanceArray,
                        atTick,
                        Bob,
                        positionIdList,
                        $shortPremia,
                        $longPremia,
                        collateralToken0,
                        collateralToken1
                    );

                console2.log(
                    atTick < 0 ? uint24(-atTick) : uint24(atTick),
                    tokenData0.leftSlot(),
                    tokenData1.leftSlot()
                );
                //assertEq(premium0, int128(tokenData0.leftSlot()), "required token0");
                //assertEq(required, tokenData1.leftSlot(), "required token1");
            }
        }
    }

    function test_Success_collateralCheck_ITMcallSpread_assetTT1(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        uint256 widthSeed2,
        int256 strikeSeed,
        int256 strikeSeed2,
        int24 atTick,
        uint256 swapSizeSeed
    ) public {
        vm.assume(strikeSeed != strikeSeed2);

        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // award corresponding shares
            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getITMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                0
            );

            (width1, strike1) = PositionUtils.getITMSW(
                widthSeed2,
                strikeSeed2,
                uint24(tickSpacing),
                currentTick,
                0
            );

            (rangeDown0, rangeUp0) = PanopticMath.getRangesFromStrike(width, tickSpacing);

            (rangeDown1, rangeUp1) = PanopticMath.getRangesFromStrike(width1, tickSpacing);

            vm.assume(width != width1 || strike != strike1);
            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                isWETH,
                0,
                0,
                0,
                strike,
                width
            );
            tokenId = tokenId.addLeg(1, 1, isWETH, 0, 0, 1, strike1, width1);
            positionIdList.push(tokenId);

            positionSizeSeed = uint128(bound(positionSizeSeed, 10 ** 15, 10 ** 20));
            positionSize0 = uint128(
                Math.min(
                    getContractsForAmountAtTick(
                        currentTick,
                        strike - rangeDown0,
                        strike + rangeUp0,
                        isWETH,
                        positionSizeSeed
                    ),
                    getContractsForAmountAtTick(
                        currentTick,
                        strike1 - rangeDown1,
                        strike1 + rangeUp1,
                        isWETH,
                        positionSizeSeed
                    )
                )
            );
            _assumePositionValidity(Bob, tokenId, positionSize0);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        uint128 poolUtilizations;
        {
            // Alice buys
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // award corresponding shares
            _mockMaxDeposit(Alice);

            tokenId1 = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                isWETH,
                1,
                0,
                1,
                strike,
                width
            );
            tokenId1 = tokenId1.addLeg(1, 1, isWETH, 0, 0, 0, strike1, width1);
            positionIdList1.push(tokenId1);

            _assumePositionValidity(Alice, tokenId1, positionSize0 / 2);

            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 2,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        // mimic pool activity
        twoWaySwap(swapSizeSeed);

        // check requirement at fuzzed tick
        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Alice, tokenId1);

            uint128 poolUtilizations = uint128(poolUtilization0) +
                (uint128(poolUtilization1) << 64);

            uint128 required = _spreadTokensRequired(
                tokenId1,
                positionSize0 / 2,
                poolUtilizations,
                atTick
            );
            _assumePositionValidity(Alice, tokenId1, positionSize0 / 2);

            // only add premium requirement if there is net premia owed
            required += int256(uint256($shortPremia.rightSlot())) -
                int256(uint256($longPremia.rightSlot())) <
                0
                ? uint128(
                    (uint128(DECIMALS) *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.rightSlot())) -
                                    int256(uint256($longPremia.rightSlot()))
                            )
                        )) / uint128(DECIMALS)
                )
                : 0;
            int128 premium1 = int256(uint256($shortPremia.leftSlot())) -
                int256(uint256($longPremia.leftSlot())) <
                0
                ? int128(
                    (DECIMALS *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.leftSlot())) -
                                    int256(uint256($longPremia.leftSlot()))
                            )
                        )) / uint128(DECIMALS)
                )
                : int128(0);

            assertEq(required, tokenData0.leftSlot(), "required token0");
            assertEq(premium1, int128(tokenData1.leftSlot()), "required token1");
        }

        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Alice,
                currentTick,
                positionIdList1
            );

            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    function test_Success_collateralCheck_ITMcallSpread_assetTT0(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        uint256 widthSeed2,
        int256 strikeSeed,
        int256 strikeSeed2,
        int24 atTick,
        uint256 swapSizeSeed
    ) public {
        vm.assume(strikeSeed != strikeSeed2);

        uint128 required;

        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // award corresponding shares
            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getITMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                0
            );

            (width1, strike1) = PositionUtils.getITMSW(
                widthSeed2,
                strikeSeed2,
                uint24(tickSpacing),
                currentTick,
                0
            );

            (rangeDown0, rangeUp0) = PanopticMath.getRangesFromStrike(width, tickSpacing);
            (rangeDown1, rangeUp1) = PanopticMath.getRangesFromStrike(width1, tickSpacing);
            vm.assume(width != width1 || strike != strike1);
            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                isWETH,
                0,
                0,
                0,
                strike,
                width
            );
            tokenId = tokenId.addLeg(1, 1, isWETH, 0, 0, 1, strike1, width1);
            positionIdList.push(tokenId);

            positionSizeSeed = uint128(bound(positionSizeSeed, 10 ** 15, 10 ** 20));
            positionSize0 = uint128(
                Math.min(
                    getContractsForAmountAtTick(
                        currentTick,
                        strike - rangeDown0,
                        strike + rangeUp0,
                        isWETH,
                        positionSizeSeed
                    ),
                    getContractsForAmountAtTick(
                        currentTick,
                        strike1 - rangeDown1,
                        strike1 + rangeUp1,
                        isWETH,
                        positionSizeSeed
                    )
                )
            );
            _assumePositionValidity(Bob, tokenId, positionSize0);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        uint128 poolUtilizations;
        {
            // Alice buys
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // award corresponding shares
            _mockMaxDeposit(Alice);

            tokenId1 = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                isWETH,
                1,
                0,
                1,
                strike,
                width
            );
            tokenId1 = tokenId1.addLeg(1, 1, isWETH, 0, 0, 0, strike1, width1);
            positionIdList1.push(tokenId1);

            console2.log("currentTic", currentTick);
            _assumePositionValidity(Alice, tokenId1, positionSize0 / 2);
            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 2,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Alice, tokenId1);

            poolUtilizations =
                uint128(poolUtilization0 == 0 ? 1 : poolUtilization0) +
                (uint128(poolUtilization1 == 0 ? 1 : poolUtilization1) << 64);
            (, currentTick, , , , , ) = pool.slot0();
            console2.log("currentTic-after", currentTick);

            //required = _spreadTokensRequired(tokenId1, positionSize0 / 2, poolUtilizations);
            console2.log("required-spreads", required);
        }

        // mimic pool activity
        twoWaySwap(swapSizeSeed);

        // check requirement at fuzzed tick
        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;
            required = uint128(
                riskEngine.getRequiredCollateralAtTickSinglePosition(
                    tokenId1,
                    positionSize0 / 2,
                    atTick,
                    int16(uint16(poolUtilizations)),
                    true
                )
            );

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Alice, tokenId1);
            console2.log("PU0", poolUtilization0);
            console2.log("PU1", poolUtilization1);

            // only add premium requirement if there is net premia owed
            required += uint128(
                int256(uint256($shortPremia.rightSlot())) -
                    int256(uint256($longPremia.rightSlot())) <
                    0
                    ? int128(
                        DECIMALS *
                            uint128(
                                -int128(
                                    int256(uint256($shortPremia.rightSlot())) -
                                        int256(uint256($longPremia.rightSlot()))
                                )
                            )
                    ) / int128(DECIMALS)
                    : int128(0)
            );
            uint128 premium1 = int256(uint256($shortPremia.leftSlot())) -
                int256(uint256($longPremia.leftSlot())) <
                0
                ? uint128(
                    (int128(DECIMALS) *
                        -int128(
                            int256(uint256($shortPremia.leftSlot())) -
                                int256(uint256($longPremia.leftSlot()))
                        )) / int128(DECIMALS)
                )
                : 0;
            assertEq(required, tokenData0.leftSlot(), "required token0");
            assertEq(premium1, tokenData1.leftSlot(), "required token1");
        }

        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Alice,
                currentTick,
                positionIdList1
            );

            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    /* buy utilization checks */

    // use dynamic var for real utilization values instead of harcoding

    // utilization < targetPoolUtilization
    function test_Success_collateralCheck_buyCallMinUtilization(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        int256 strikeSeed2,
        uint64 utilizationSeed,
        int24 atTick,
        uint256 swapSizeSeed
    ) public {
        vm.assume(strikeSeed != strikeSeed2);

        uint64 targetUtilization;
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                0
            );

            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, strike, width);
            positionIdList.push(tokenId);

            /// calculate position size
            (legLowerTick, legUpperTick) = tokenId.asTicks(0);

            positionSize0 = uint128(bound(positionSizeSeed, 2, 2 ** 104));
            _assumePositionValidity(Bob, tokenId, positionSize0);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        {
            // Alice buys
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Alice);

            tokenId1 = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 0, 0, strike, width);
            positionIdList1.push(tokenId1);

            uint256 snapshot = vm.snapshot();

            uint256 inAMMBefore = collateralToken0._inAMM();

            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 2,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            uint256 inAMMOffset = inAMMBefore - collateralToken0._inAMM();

            vm.revertTo(snapshot);

            // set utilization before minting
            // take into account the offsets as states are updated before utilization is checked for the mint
            targetUtilization = uint64(bound(utilizationSeed, 1, 4_999));
            setUtilization(collateralToken0, token0, int64(targetUtilization), inAMMOffset, true);

            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 2,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            int128 currentUtilization = collateralToken0.poolUtilizationHook();
            vm.assume(currentUtilization < 5_000);
        }

        // mimic pool activity
        twoWaySwap(swapSizeSeed);

        // check requirement at fuzzed tick
        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Alice, tokenId1);

            uint128 poolUtilizations = uint128(poolUtilization0) +
                (uint128(poolUtilization1) << 64);

            uint256[2] memory checkSingle = [uint256(0), uint256(0)];
            uint128 required = uint128(
                riskEngine.getRequiredCollateralAtTickSinglePosition(
                    tokenId1,
                    positionSize0 / 2,
                    atTick,
                    int16(uint16(poolUtilizations)),
                    true
                )
            );

            // only add premium requirement if there is net premia owed
            required += int256(uint256($shortPremia.rightSlot())) -
                int256(uint256($longPremia.rightSlot())) <
                0
                ? uint128(
                    (uint128(DECIMALS) *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.rightSlot())) -
                                    int256(uint256($longPremia.rightSlot()))
                            )
                        )) / uint128(DECIMALS)
                )
                : 0;
            int128 premium1 = int256(uint256($shortPremia.leftSlot())) -
                int256(uint256($longPremia.leftSlot())) <
                0
                ? int128(
                    (DECIMALS *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.leftSlot())) -
                                    int256(uint256($longPremia.leftSlot()))
                            )
                        )) / uint128(DECIMALS)
                )
                : int128(0);
            assertEq(required, tokenData0.leftSlot(), "required token0");
            assertEq(premium1, int128(tokenData1.leftSlot()), "required token1");
        }

        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Alice,
                currentTick,
                positionIdList1
            );

            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    // // utilization > DECIMALS_128
    // function test_Success_collateralCheck_buyUtilizationMax(
    //     uint256 x,
    //     uint128 positionSizeSeed,
    //     uint256 widthSeed,
    //     int256 strikeSeed,
    //     uint256 widthSeed2,
    //     int256 strikeSeed2
    // ) public {
    // }

    // gt than targetPoolUtilization and lt saturatedPoolUtilization
    function test_Success_collateralCheck_buyBetweenTargetSaturated(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        int256 strikeSeed2,
        uint64 utilizationSeed,
        int24 atTick,
        uint256 swapSizeSeed
    ) public {
        vm.assume(strikeSeed != strikeSeed2);

        uint64 targetUtilization;
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                0
            );

            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, strike, width);
            positionIdList.push(tokenId);

            /// calculate position size
            (legLowerTick, legUpperTick) = tokenId.asTicks(0);

            positionSize0 = uint128(bound(positionSizeSeed, 2, 2 ** 120));
            _assumePositionValidity(Bob, tokenId, positionSize0);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        {
            // Alice buys
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Alice);

            tokenId1 = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 0, 0, strike, width);
            positionIdList1.push(tokenId1);

            uint256 snapshot = vm.snapshot();

            uint256 inAMMBefore = collateralToken0._inAMM();

            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 2,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            uint256 inAMMOffset = inAMMBefore - collateralToken0._inAMM();

            vm.revertTo(snapshot);

            // set utilization before minting
            // take into account the offsets as states are updated before utilization is checked for the mint
            targetUtilization = uint64(bound(utilizationSeed, 5_000, 9_000));
            setUtilization(collateralToken0, token0, int64(targetUtilization), inAMMOffset, true);

            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 2,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            int128 currentUtilization = collateralToken0.poolUtilizationHook();
            vm.assume(currentUtilization > 5_000 && currentUtilization < 9_000);
        }

        // mimic pool activity
        twoWaySwap(swapSizeSeed);

        // check requirement at fuzzed tick
        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Alice, tokenId1);

            uint128 poolUtilizations = uint128(poolUtilization0) +
                (uint128(poolUtilization1) << 64);

            uint256[2] memory checkSingle = [uint256(0), uint256(0)];
            uint128 required = _tokensRequired(
                tokenId1,
                positionSize0 / 2,
                atTick,
                poolUtilizations,
                checkSingle
            );

            // only add premium requirement if there is net premia owed
            required += int256(uint256($shortPremia.rightSlot())) -
                int256(uint256($longPremia.rightSlot())) <
                0
                ? uint128(
                    (uint128(DECIMALS) *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.rightSlot())) -
                                    int256(uint256($longPremia.rightSlot()))
                            )
                        )) / uint128(DECIMALS)
                )
                : 0;
            int128 premium1 = int256(uint256($shortPremia.leftSlot())) -
                int256(uint256($longPremia.leftSlot())) <
                0
                ? int128(
                    (DECIMALS *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.leftSlot())) -
                                    int256(uint256($longPremia.leftSlot()))
                            )
                        )) / uint128(DECIMALS)
                )
                : int128(0);
            assertEq(required, tokenData0.leftSlot(), "required token0");
            assertEq(premium1, int128(tokenData1.leftSlot()), "required token1");
        }

        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Alice,
                currentTick,
                positionIdList1
            );

            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    // gt than saturatedPoolUtilization
    function test_Success_collateralCheck_buyGTSaturatedPoolUtilization(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        uint64 utilizationSeed,
        int24 atTick,
        uint256 swapSizeSeed
    ) public {
        uint64 targetUtilization;
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                0
            );

            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, strike, width);
            positionIdList.push(tokenId);

            /// calculate position size
            (legLowerTick, legUpperTick) = tokenId.asTicks(0);

            positionSize0 = uint128(bound(positionSizeSeed, 2, 2 ** 104));
            _assumePositionValidity(Bob, tokenId, positionSize0);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        {
            // Alice buys
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Alice);

            tokenId1 = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 0, 0, strike, width);
            positionIdList1.push(tokenId1);

            uint256 snapshot = vm.snapshot();

            uint256 inAMMBefore = collateralToken0._inAMM();

            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 2,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            uint256 inAMMOffset = inAMMBefore - collateralToken0._inAMM();

            vm.revertTo(snapshot);

            // set utilization before minting
            // take into account the offsets as states are updated before utilization is checked for the mint
            targetUtilization = uint64(bound(utilizationSeed, 9_001, 9_999));
            setUtilization(collateralToken0, token0, int64(targetUtilization), inAMMOffset, true);

            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 2,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            int128 currentUtilization = collateralToken0.poolUtilizationHook();
            vm.assume(currentUtilization > 9_000);
        }

        // mimic pool activity
        twoWaySwap(swapSizeSeed);

        // check requirement at fuzzed tick
        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Alice, tokenId1);

            uint128 poolUtilizations = uint128(poolUtilization0) +
                (uint128(poolUtilization1) << 64);

            uint256[2] memory checkSingle = [uint256(0), uint256(0)];
            uint128 required = _tokensRequired(
                tokenId1,
                positionSize0 / 2,
                atTick,
                poolUtilizations,
                checkSingle
            );

            console2.log("rrr", required);
            // checks tokens required
            required += uint128(
                int256(uint256($shortPremia.rightSlot())) -
                    int256(uint256($longPremia.rightSlot())) <
                    0
                    ? int128(
                        DECIMALS *
                            uint128(
                                -int128(
                                    int256(uint256($shortPremia.rightSlot())) -
                                        int256(uint256($longPremia.rightSlot()))
                                )
                            )
                    ) / int128(DECIMALS)
                    : int128(0)
            );
            uint128 premium1 = int256(uint256($shortPremia.leftSlot())) -
                int256(uint256($longPremia.leftSlot())) <
                0
                ? uint128(
                    (int128(DECIMALS) *
                        -int128(
                            int256(uint256($shortPremia.leftSlot())) -
                                int256(uint256($longPremia.leftSlot()))
                        )) / int128(DECIMALS)
                )
                : 0;
            assertEq(required, tokenData0.leftSlot(), "required token0");
            assertEq(premium1, tokenData1.leftSlot(), "required token1");
        }

        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Alice, false, positionIdList1);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Alice,
                positionIdList1,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Alice,
                currentTick,
                positionIdList1
            );

            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    /* sell utilization checks */

    // utilization > DECIMALS_128

    // utilization < targetPoolUtilization
    function test_Success_collateralCheck_sellCallMinUtilization(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        uint64 utilizationSeed,
        int24 atTick,
        uint256 swapSizeSeed
    ) public {
        uint64 targetUtilization;
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                0
            );

            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, strike, width);
            positionIdList.push(tokenId);

            /// calculate position size
            (legLowerTick, legUpperTick) = tokenId.asTicks(0);

            positionSize0 = uint128(bound(positionSizeSeed, 2, 2 ** 104));
            _assumePositionValidity(Bob, tokenId, positionSize0);

            uint256 snapshot = vm.snapshot();

            uint256 inAMMOffset = collateralToken0._inAMM();

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            vm.revertTo(snapshot);

            // set utilization before minting
            // take into account the offsets as states are updated before utilization is checked for the mint
            targetUtilization = uint64(bound(utilizationSeed, 1, 4_999));
            setUtilization(
                collateralToken0,
                token0,
                int64((targetUtilization)),
                inAMMOffset,
                false
            );

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            vm.assume(
                collateralToken0.poolUtilizationHook() < 5_000 // targetPoolUtilization
            );
        }

        // mimic pool activity
        twoWaySwap(swapSizeSeed);

        // check requirement at fuzzed tick
        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Bob, tokenId);

            uint128 poolUtilizations = uint128(poolUtilization0) +
                (uint128(poolUtilization1) << 64);

            uint256[2] memory checkSingle = [uint256(0), uint256(0)];
            uint128 required = _tokensRequired(
                tokenId,
                positionSize0,
                atTick,
                poolUtilizations,
                checkSingle
            );

            // only add premium requirement if there is net premia owed
            int128 premium1 = int256(uint256($shortPremia.leftSlot())) -
                int256(uint256($longPremia.leftSlot())) <
                0
                ? ((int128(DECIMALS) *
                    -int128(
                        int256(uint256($shortPremia.leftSlot())) -
                            int256(uint256($longPremia.leftSlot()))
                    )) / int128(DECIMALS))
                : int8(0);
            assertEq(required, tokenData0.leftSlot(), "required token0");
            assertEq(premium1, int128(tokenData1.leftSlot()), "required token1");
        }

        //check collateral output against panoptic pool at current tick
        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Bob,
                currentTick,
                positionIdList
            );

            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    function test_Success_collateralCheck_sellPutMinUtilization(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        uint64 utilizationSeed,
        int24 atTick,
        uint256 swapSizeSeed
    ) public {
        uint64 targetUtilization;
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                1
            );

            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 1, 0, strike, width);
            positionIdList.push(tokenId);

            /// calculate position size
            (legLowerTick, legUpperTick) = tokenId.asTicks(0);

            positionSize0 = uint128(bound(positionSizeSeed, 10 ** 15, 10 ** 20));
            _assumePositionValidity(Bob, tokenId, positionSize0);

            uint256 snapshot = vm.snapshot();

            uint256 inAMMOffset = collateralToken0._inAMM();

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
            vm.revertTo(snapshot);

            // set utilization before minting
            // take into account the offsets as states are updated before utilization is checked for the mint
            targetUtilization = uint64(bound(utilizationSeed, 1, 4_999));
            setUtilization(
                collateralToken0,
                token0,
                int64((targetUtilization)),
                inAMMOffset,
                false
            );

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            vm.assume(collateralToken0.poolUtilizationHook() < 5_000);
        }

        // mimic pool activity
        twoWaySwap(swapSizeSeed);

        // check requirement at fuzzed tick
        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, , , uint256 utilization0) = collateralToken0.getPoolData();
            (, , , uint256 utilization1) = collateralToken1.getPoolData();

            // check user packed utilization
            assertApproxEqAbs(targetUtilization, utilization0, 1, "utilization ct 0");
            assertApproxEqAbs(0, utilization1, 1, "utilization ct 1");

            uint128 poolUtilizations = uint128(utilization0) + (uint128(utilization1) << 64);

            uint256[2] memory checkSingle = [uint256(0), uint256(0)];
            console2.log("utili", utilization0, utilization1);
            uint128 required = _tokensRequired(
                tokenId,
                positionSize0,
                atTick,
                poolUtilizations,
                checkSingle
            );

            console2.log("required", required);
            // only add premium requirement if there is net premia owed
            int128 premium0 = int128(
                int256(uint256($shortPremia.rightSlot())) - int256(uint256($longPremia.rightSlot()))
            ) < 0
                ? int128(
                    (DECIMALS *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.rightSlot())) -
                                    int256(uint256($longPremia.rightSlot()))
                            )
                        )) / uint128(DECIMALS)
                )
                : int128(0);
            required += int128(
                int256(uint256($shortPremia.leftSlot())) - int256(uint256($longPremia.leftSlot()))
            ) < 0
                ? uint128(
                    (uint128(DECIMALS) *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.leftSlot())) -
                                    int256(uint256($longPremia.leftSlot()))
                            )
                        )) / uint128(DECIMALS)
                )
                : 0;
            assertEq(premium0, int128(tokenData0.leftSlot()), "required token0");
            assertEq(required, tokenData1.leftSlot(), "required token1");
        }

        //check collateral output against panoptic pool at current tick
        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Bob,
                currentTick,
                positionIdList
            );

            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    // utilization > saturatedPoolUtilization
    function test_Success_collateralCheck_sellCallGTSaturatedPoolUtilization_TT0(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        int256 strikeSeed2,
        uint64 utilizationSeed,
        int24 atTick,
        uint256 swapSizeSeed
    ) public {
        vm.assume(strikeSeed != strikeSeed2);

        uint64 targetUtilization;
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                0
            );

            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, strike, width);
            positionIdList.push(tokenId);

            /// calculate position size
            (legLowerTick, legUpperTick) = tokenId.asTicks(0);

            positionSize0 = uint128(bound(positionSizeSeed, 2, 2 ** 128));
            _assumePositionValidity(Bob, tokenId, positionSize0);

            uint256 snapshot = vm.snapshot();

            uint256 inAMMOffset = collateralToken0._inAMM();

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            vm.revertTo(snapshot);

            // set utilization before minting
            // take into account the offsets as states are updated before utilization is checked for the mint
            targetUtilization = uint64(bound(utilizationSeed, 9_001, 9_999));
            setUtilization(collateralToken0, token0, int64(targetUtilization), inAMMOffset, false);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            int128 currentUtilization = collateralToken0.poolUtilizationHook();
            vm.assume(currentUtilization > 8_999); // account for round by 1
        }

        // mimic pool activity
        twoWaySwap(swapSizeSeed);

        // check requirement at fuzzed tick
        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Bob, tokenId);

            uint128 poolUtilizations = uint128(poolUtilization0) +
                (uint128(poolUtilization1) << 64);

            uint256[2] memory checkSingle = [uint256(0), uint256(0)];
            uint128 required = _tokensRequired(
                tokenId,
                positionSize0,
                atTick,
                poolUtilizations,
                checkSingle
            );

            // checks tokens required
            required += int256(uint256($shortPremia.rightSlot())) -
                int256(uint256($longPremia.rightSlot())) <
                0
                ? uint128(
                    (uint128(DECIMALS) *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.rightSlot())) -
                                    int256(uint256($longPremia.rightSlot()))
                            )
                        )) / uint128(DECIMALS)
                )
                : 0;
            int128 premium1 = int256(uint256($shortPremia.leftSlot())) -
                int256(uint256($longPremia.leftSlot())) <
                0
                ? int128(
                    (DECIMALS *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.leftSlot())) -
                                    int256(uint256($longPremia.leftSlot()))
                            )
                        )) / uint128(DECIMALS)
                )
                : int128(0);
            assertEq(required, tokenData0.leftSlot(), "required token0");
            assertEq(premium1, int128(tokenData1.leftSlot()), "required token1");
        }

        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Bob,
                currentTick,
                positionIdList
            );

            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    function test_Success_collateralCheck_sellPutGTSaturatedPoolUtilization(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        int256 strikeSeed2,
        uint64 utilizationSeed,
        int24 atTick,
        uint256 swapSizeSeed
    ) public {
        vm.assume(strikeSeed != strikeSeed2);

        uint64 targetUtilization;
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                1
            );

            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 1, 0, strike, width);
            positionIdList.push(tokenId);

            /// calculate position size
            (legLowerTick, legUpperTick) = tokenId.asTicks(0);

            positionSize0 = uint128(bound(positionSizeSeed, 2, 2 ** 128));
            _assumePositionValidity(Bob, tokenId, positionSize0);

            uint256 snapshot = vm.snapshot();

            uint256 inAMMOffset = collateralToken1._inAMM();

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            vm.revertTo(snapshot);

            // set utilization before minting
            // take into account the offsets as states are updated before utilization is checked for the mint
            targetUtilization = uint64(bound(utilizationSeed, 9_001, 9_999));
            setUtilization(collateralToken1, token1, int64(targetUtilization), inAMMOffset, false);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            int128 currentUtilization = collateralToken1.poolUtilizationHook();
            vm.assume(currentUtilization > 8_999); // account for round by 1
        }

        // mimic pool activity
        twoWaySwap(swapSizeSeed);

        // check requirement at fuzzed tick
        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Bob, tokenId);

            uint128 poolUtilizations = uint128(poolUtilization0) +
                (uint128(poolUtilization1) << 64);

            uint256[2] memory checkSingle = [uint256(0), uint256(0)];
            uint128 required = _tokensRequired(
                tokenId,
                positionSize0,
                atTick,
                poolUtilizations,
                checkSingle
            );

            console2.log("required", required);
            // only add premium requirement if there is net premia owed
            int128 premium0 = int128(
                int256(uint256($shortPremia.rightSlot())) - int256(uint256($longPremia.rightSlot()))
            ) < 0
                ? int128(
                    (DECIMALS *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.rightSlot())) -
                                    int256(uint256($longPremia.rightSlot()))
                            )
                        )) / uint128(DECIMALS)
                )
                : int128(0);
            required += int128(
                int256(uint256($shortPremia.leftSlot())) - int256(uint256($longPremia.leftSlot()))
            ) < 0
                ? uint128(
                    (uint128(DECIMALS) *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.leftSlot())) -
                                    int256(uint256($longPremia.leftSlot()))
                            )
                        )) / uint128(DECIMALS)
                )
                : 0;
            assertEq(premium0, int128(tokenData0.leftSlot()), "required token0");
            assertEq(required, tokenData1.leftSlot(), "required token1");
        }

        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Bob,
                currentTick,
                positionIdList
            );

            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    // targetPoolUtilization < utilization < saturatedPoolUtilization
    function test_Success_collateralCheck_sellCallBetweenTargetSaturated_asset1(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        int256 strikeSeed2,
        uint64 utilizationSeed,
        int24 atTick,
        uint256 swapSizeSeed
    ) public {
        vm.assume(strikeSeed != strikeSeed2);

        uint64 targetUtilization;
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                0
            );

            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, strike, width);
            positionIdList.push(tokenId);

            positionSize0 = uint128(bound(positionSizeSeed, 2, 2 ** 104));
            _assumePositionValidity(Bob, tokenId, positionSize0);

            uint256 snapshot = vm.snapshot();

            uint256 inAMMOffset = collateralToken0._inAMM();

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            vm.revertTo(snapshot);

            // set utilization before minting
            // take into account the offsets as states are updated before utilization is checked for the mint
            targetUtilization = uint64(bound(utilizationSeed, 5_000, 8_999));
            setUtilization(collateralToken0, token0, int64(targetUtilization), inAMMOffset, false);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            int128 currentUtilization = collateralToken0.poolUtilizationHook();
            vm.assume(currentUtilization > 4_999 && currentUtilization < 9_000);
        }

        // mimic pool activity
        twoWaySwap(swapSizeSeed);

        // check requirement at fuzzed tick
        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Bob, tokenId);

            uint128 poolUtilizations = uint128(poolUtilization0) +
                (uint128(poolUtilization1) << 64);

            uint256[2] memory checkSingle = [uint256(0), uint256(0)];
            uint128 required = _tokensRequired(
                tokenId,
                positionSize0,
                atTick,
                poolUtilizations,
                checkSingle
            );

            console2.log("required", required);
            // only add premium requirement if there is net premia owed
            int128 premium1 = int128(
                int256(uint256($shortPremia.leftSlot())) - int256(uint256($longPremia.leftSlot()))
            ) < 0
                ? int128(
                    (DECIMALS *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.leftSlot())) -
                                    int256(uint256($longPremia.leftSlot()))
                            )
                        )) / uint128(DECIMALS)
                )
                : int128(0);
            assertEq(required, tokenData0.leftSlot(), "required token0");
            assertEq(premium1, int128(tokenData1.leftSlot()), "required token1");
        }

        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Bob,
                currentTick,
                positionIdList
            );

            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    function test_Success_collateralCheck_sellPutBetweenTargetSaturated_asset0(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        int256 strikeSeed2,
        uint64 utilizationSeed,
        int24 atTick,
        uint256 swapSizeSeed
    ) public {
        vm.assume(strikeSeed != strikeSeed2);

        uint64 targetUtilization;
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                1
            );

            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 0, 0, 1, 0, strike, width);
            positionIdList.push(tokenId);

            positionSize0 = uint128(bound(positionSizeSeed, 2, 2 ** 104));
            _assumePositionValidity(Bob, tokenId, positionSize0);

            uint256 snapshot = vm.snapshot();

            uint256 inAMMOffset = collateralToken1._inAMM();

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            vm.revertTo(snapshot);

            // set utilization before minting
            // take into account the offsets as states are updated before utilization is checked for the mint
            targetUtilization = uint64(bound(utilizationSeed, 5_000, 8_999));
            setUtilization(collateralToken1, token1, int64(targetUtilization), inAMMOffset, false);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
            int128 currentUtilization = collateralToken1.poolUtilizationHook();
            vm.assume(currentUtilization > 5_000 && currentUtilization < 9_000);
        }

        // mimic pool activity
        twoWaySwap(swapSizeSeed);

        // check requirement at fuzzed tick
        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Bob, tokenId);

            uint128 poolUtilizations = uint128(poolUtilization0) +
                (uint128(poolUtilization1) << 64);

            uint256[2] memory checkSingle = [uint256(0), uint256(0)];
            uint128 required = _tokensRequired(
                tokenId,
                positionSize0,
                atTick,
                poolUtilizations,
                checkSingle
            );

            // only add premium requirement if there is net premia owed
            int128 premium0 = int128(
                int256(uint256($shortPremia.rightSlot())) - int256(uint256($longPremia.rightSlot()))
            ) < 0
                ? int128(
                    (DECIMALS *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.rightSlot())) -
                                    int256(uint256($longPremia.rightSlot()))
                            )
                        )) / uint128(DECIMALS)
                )
                : int128(0);
            required += int128(
                int256(uint256($shortPremia.leftSlot())) - int256(uint256($longPremia.leftSlot()))
            ) < 0
                ? uint128(
                    (uint128(DECIMALS) *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.leftSlot())) -
                                    int256(uint256($longPremia.leftSlot()))
                            )
                        )) / uint128(DECIMALS)
                )
                : 0;
            assertEq(premium0, int128(tokenData0.leftSlot()), "required token0");
            assertEq(required, tokenData1.leftSlot(), "required token1");
        }

        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Bob,
                currentTick,
                positionIdList
            );

            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    // Positive premia
    function test_Success_collateralCheck_sellPosPremia(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        int24 atTick,
        uint24 swapSizeSeed
    ) public {
        uint64 targetUtilization;
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            collateralToken0.deposit(type(uint104).max, Bob);
            collateralToken1.deposit(type(uint104).max, Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                1
            );

            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 1, 0, strike, width);
            positionIdList.push(tokenId);

            /// calculate position size
            (legLowerTick, legUpperTick) = tokenId.asTicks(0);

            positionSize0 = uint128(bound(positionSizeSeed, 10 ** 15, 10 ** 20));
            _assumePositionValidity(Bob, tokenId, positionSize0);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        // mimic pool activity
        twoWaySwap(swapSizeSeed);

        // check requirement at fuzzed tick
        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Bob, tokenId);

            // check user packed utilization
            assertApproxEqAbs(targetUtilization, poolUtilization0, 1, "utilization ct 0");
            assertApproxEqAbs(0, poolUtilization1, 1, "utilization ct 1");

            uint128 poolUtilizations = uint128(poolUtilization0) +
                (uint128(poolUtilization1) << 64);

            uint256[2] memory checkSingle = [uint256(0), uint256(0)];
            uint128 required = _tokensRequired(
                tokenId,
                positionSize0,
                atTick,
                poolUtilizations,
                checkSingle
            );

            assertTrue(
                int256(uint256($shortPremia.rightSlot())) -
                    int256(uint256($longPremia.rightSlot())) >=
                    0 &&
                    int256(uint256($shortPremia.leftSlot())) -
                        int256(uint256($longPremia.leftSlot())) >=
                    0,
                "invalid premia"
            );

            // checks tokens required
            // only add premium requirement, if there is net premia owed
            required += int128(
                int256(uint256($shortPremia.leftSlot())) - int256(uint256($longPremia.leftSlot()))
            ) < 0
                ? uint128(
                    (uint128(DECIMALS) *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.leftSlot())) -
                                    int256(uint256($longPremia.leftSlot()))
                            )
                        )) / (DECIMALS)
                )
                : 0;
            int128 premium0 = int128(
                int256(uint256($shortPremia.rightSlot())) - int256(uint256($longPremia.rightSlot()))
            ) < 0
                ? int128(
                    (DECIMALS *
                        uint128(
                            -int128(
                                int256(uint256($shortPremia.rightSlot())) -
                                    int256(uint256($longPremia.rightSlot()))
                            )
                        )) / (DECIMALS)
                )
                : int128(0);
            assertEq(premium0, int128(tokenData0.leftSlot()), "required token0");
            assertEq(required, tokenData1.leftSlot(), "required token1");
        }

        //check collateral output against panoptic pool at current tick
        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Bob,
                currentTick,
                positionIdList
            );
            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    // Loan positions
    function test_Success_collateralCheck_LoanPosition(uint256 x) public {
        uint64 targetUtilization;
        x = uint256(keccak256(abi.encode(x)));
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            collateralToken0.deposit(type(uint104).max, Bob);
            collateralToken1.deposit(type(uint104).max, Bob);

            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                (x % 127) + 1,
                (x >> 10) % 2,
                0,
                (x >> 11) % 2,
                0,
                (currentTick / tickSpacing) * tickSpacing,
                0
            );
            positionIdList.push(tokenId);

            positionSize0 = uint128(bound(x >> 128, 10 ** 15, 10 ** 20));

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        // check requirement at fuzzed tick
        {
            int24 atTick = int24(
                bound(int24(uint24((x >> 24) % 2 ** 24)), TickMath.MIN_TICK, TickMath.MAX_TICK)
            );
            atTick = (atTick / tickSpacing) * tickSpacing;

            (LeftRightSigned longAmounts, LeftRightSigned shortAmounts) = PanopticMath
                .computeExercisedAmounts(tokenId, positionSize0, false);

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Bob, tokenId);

            // check user packed utilization
            assertEq(
                poolUtilization0,
                Math.mulDivRoundingUp(
                    uint128(shortAmounts.rightSlot()),
                    10000,
                    collateralToken0.totalAssets()
                ),
                "utilization ct 0"
            );
            assertEq(
                poolUtilization1,
                Math.mulDivRoundingUp(
                    uint128(shortAmounts.leftSlot()),
                    10000,
                    collateralToken1.totalAssets()
                ),
                "utilization ct 1"
            );

            uint128 poolUtilizations = uint128(poolUtilization0) +
                (uint128(poolUtilization1) << 64);

            uint256[2] memory checkSingle = [uint256(0), uint256(0)];
            uint128 required = _tokensRequired(
                tokenId,
                positionSize0,
                atTick,
                poolUtilizations,
                checkSingle
            );

            console2.log("required", required, positionSize0);
            assertTrue(
                int256(uint256($shortPremia.rightSlot())) -
                    int256(uint256($longPremia.rightSlot())) >=
                    0 &&
                    int256(uint256($shortPremia.leftSlot())) -
                        int256(uint256($longPremia.leftSlot())) >=
                    0,
                "invalid premia"
            );

            assertEq(
                tokenId.tokenType(0) == 0 ? required : 0,
                tokenData0.leftSlot(),
                "required token0 -"
            );
            assertEq(
                tokenId.tokenType(0) == 1 ? required : 0,
                tokenData1.leftSlot(),
                "required token1 -"
            );
        }

        //check collateral output against panoptic pool at current tick
        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Bob,
                currentTick,
                positionIdList
            );
            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    // Loan positions
    function test_Success_collateralCheck_CreditPosition(uint256 x) public {
        uint64 targetUtilization;
        x = uint256(keccak256(abi.encode(x)));
        TokenId tokenIdc;
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Alice
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            collateralToken0.deposit(type(uint104).max, Alice);
            collateralToken1.deposit(type(uint104).max, Alice);

            tokenIdc = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                (x % 127) + 1,
                (x >> 10) % 2,
                0,
                (x >> 11) % 2,
                0,
                (currentTick / tickSpacing) * tickSpacing,
                0
            );
            positionIdList.push(tokenIdc);

            positionSize0 = uint128(bound(x >> 128, 10 ** 15, 10 ** 18));
            collateralToken0.wipeUtilizationSlot();
            collateralToken1.wipeUtilizationSlot();
            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0 * 10,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            collateralToken0.deposit(type(uint104).max, Bob);
            collateralToken1.deposit(type(uint104).max, Bob);
            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                (x % 127) + 1,
                (x >> 10) % 2,
                1,
                (x >> 11) % 2,
                0,
                (currentTick / tickSpacing) * tickSpacing,
                0
            );
            positionIdList.pop();
            positionIdList.push(tokenId);
            (LeftRightSigned longAmounts, LeftRightSigned shortAmounts) = PanopticMath
                .computeExercisedAmounts(tokenId, positionSize0, true);

            vm.assume(uint128(longAmounts.rightSlot()) < type(uint104).max);
            vm.assume(uint128(longAmounts.leftSlot()) < type(uint104).max);

            {
                (, , , , int256 u0, int256 u1, uint128 ps) = panopticPool.positionData(
                    Bob,
                    tokenId
                );
                console2.log("u0", u0);
                console2.log("u1", u1);
                (
                    uint256 depositedAssets,
                    uint256 insideAMM,
                    uint256 creditedShares,
                    uint256 currentPoolUtilization
                ) = collateralToken1.getPoolData();
                console2.log(depositedAssets, insideAMM, creditedShares, currentPoolUtilization);
            }
            console2.log("foo", positionSize0);
            collateralToken0.wipeUtilizationSlot();
            collateralToken1.wipeUtilizationSlot();
            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        // check requirement at fuzzed tick
        {
            int24 atTick = int24(
                bound(int24(uint24((x >> 24) % 2 ** 24)), TickMath.MIN_TICK, TickMath.MAX_TICK)
            );
            atTick = (atTick / tickSpacing) * tickSpacing;

            (, LeftRightSigned shortAmountsAlice) = PanopticMath.computeExercisedAmounts(
                tokenIdc,
                positionSize0 * 10,
                false
            );

            (LeftRightSigned longAmounts, LeftRightSigned shortAmounts) = PanopticMath
                .computeExercisedAmounts(tokenId, positionSize0, false);

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            {
                (, , , , int256 u0, int256 u1, uint128 ps) = panopticPool.positionData(
                    Bob,
                    tokenId
                );
                console2.log("u0", u0);
                console2.log("u1", u1);
                (
                    uint256 depositedAssets,
                    uint256 insideAMM,
                    uint256 creditedShares,
                    uint256 currentPoolUtilization
                ) = collateralToken1.getPoolData();
                console2.log(depositedAssets, insideAMM, creditedShares, currentPoolUtilization);
            }
            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Bob, tokenId);

            console2.log("shortAlice1", shortAmountsAlice.leftSlot());
            console2.log("long1", longAmounts.leftSlot());
            console2.log(
                "inAMM0",
                uint128(shortAmountsAlice.rightSlot() - longAmounts.rightSlot())
            );
            console2.log("inAMM1", uint128(shortAmountsAlice.leftSlot() - longAmounts.leftSlot()));

            console2.log("totalA1", collateralToken1.totalAssets());
            // check user packed utilization
            assertEq(
                poolUtilization0,
                Math.mulDivRoundingUp(
                    uint128(shortAmountsAlice.rightSlot()),
                    10000,
                    collateralToken0.totalAssets()
                ),
                "utilization ct 0"
            );
            assertEq(
                poolUtilization1,
                Math.mulDivRoundingUp(
                    uint128(shortAmountsAlice.leftSlot()),
                    10000,
                    collateralToken1.totalAssets()
                ),
                "utilization ct 1"
            );

            uint128 poolUtilizations = uint128(poolUtilization0) +
                (uint128(poolUtilization1) << 64);

            uint256[2] memory checkSingle = [uint256(0), uint256(0)];
            uint128 required = _tokensRequired(
                tokenId,
                positionSize0,
                atTick,
                poolUtilizations,
                checkSingle
            );

            assertTrue(
                int256(uint256($shortPremia.rightSlot())) -
                    int256(uint256($longPremia.rightSlot())) >=
                    0 &&
                    int256(uint256($shortPremia.leftSlot())) -
                        int256(uint256($longPremia.leftSlot())) >=
                    0,
                "invalid premia"
            );

            assertEq(
                tokenId.tokenType(0) == 0 ? required : 0,
                tokenData0.leftSlot(),
                "required token0 -"
            );
            console2.log("required", required, tokenId.tokenType(0));
            assertEq(
                tokenId.tokenType(0) == 1 ? required : 0,
                tokenData1.leftSlot(),
                "required token1 -"
            );
        }

        //check collateral output against panoptic pool at current tick
        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Bob,
                currentTick,
                positionIdList
            );
            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    function test_Success_collateralCheck_CreditOption(uint256 x) public {
        uint64 targetUtilization;
        x = uint256(keccak256(abi.encode(x)));
        TokenId tokenIdc;
        {
            _initWorld(1);

            console2.log("pool.fee", pool.fee());
            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Alice
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            collateralToken0.deposit(type(uint104).max, Alice);
            collateralToken1.deposit(type(uint104).max, Alice);

            tokenIdc = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                100,
                (x >> 10) % 2,
                0,
                (x >> 11) % 2,
                0,
                (currentTick / tickSpacing) * tickSpacing,
                2
            );
            positionIdList.push(tokenIdc);

            positionSize0 = uint128(bound(x >> 128, 10 ** 10, 10 ** 12));

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0 * 10,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            collateralToken0.deposit(type(uint104).max, Bob);
            collateralToken1.deposit(type(uint104).max, Bob);

            // a credit and a long option
            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                (x >> 10) % 2,
                1,
                (x >> 11) % 2,
                1,
                (currentTick / tickSpacing) * tickSpacing,
                0
            );
            tokenId = tokenId.addLeg(
                1,
                100,
                (x >> 10) % 2,
                1,
                (x >> 11) % 2,
                0,
                (currentTick / tickSpacing) * tickSpacing,
                2
            );

            positionIdList.pop();
            positionIdList.push(tokenId);

            mintOptions(
                panopticPool,
                positionIdList,
                (9 * positionSize0) / 10,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        // check requirement at fuzzed tick
        {
            int24 atTick = int24(
                bound(int24(uint24((x >> 24) % 2 ** 24)), TickMath.MIN_TICK, TickMath.MAX_TICK)
            );
            atTick = (atTick / tickSpacing) * tickSpacing;

            (, LeftRightSigned shortAmountsAlice) = PanopticMath.computeExercisedAmounts(
                tokenIdc,
                positionSize0 * 10,
                true
            );

            (LeftRightSigned longAmounts, LeftRightSigned shortAmounts) = PanopticMath
                .computeExercisedAmounts(tokenId, (9 * positionSize0) / 10, true);

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                atTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (, uint64 poolUtilization0, uint64 poolUtilization1) = panopticHelper
                .optionPositionInfo(panopticPool, Bob, tokenId);

            console2.log("shortAlice1", shortAmountsAlice.leftSlot());
            console2.log("long1", longAmounts.leftSlot());
            console2.log(
                "inAMM0",
                uint128(shortAmountsAlice.rightSlot() - longAmounts.rightSlot())
            );
            console2.log("inAMM1", uint128(shortAmountsAlice.leftSlot() - longAmounts.leftSlot()));
            // check user packed utilization
            assertEq(
                poolUtilization0,
                Math.mulDivRoundingUp(
                    uint128(shortAmountsAlice.rightSlot() - longAmounts.rightSlot()),
                    10000,
                    collateralToken0.totalAssets()
                ),
                "utilization ct 0"
            );
            assertEq(
                poolUtilization1,
                Math.mulDivRoundingUp(
                    uint128(shortAmountsAlice.leftSlot() - longAmounts.leftSlot()),
                    10000,
                    collateralToken1.totalAssets()
                ),
                "utilization ct 1"
            );

            uint128 poolUtilizations = uint128(poolUtilization0) +
                (uint128(poolUtilization1) << 64);

            uint256[2] memory checkSingle = [uint256(0), uint256(0)];
            uint128 required = _tokensRequired(
                tokenId,
                (9 * positionSize0) / 10,
                atTick,
                poolUtilizations,
                checkSingle
            );

            assertTrue(
                int256(uint256($shortPremia.rightSlot())) -
                    int256(uint256($longPremia.rightSlot())) >=
                    0 &&
                    int256(uint256($shortPremia.leftSlot())) -
                        int256(uint256($longPremia.leftSlot())) >=
                    0,
                "invalid premia"
            );

            /*
            assertEq(
                tokenId.tokenType(0) == 0 ? required : 0,
                tokenData0.leftSlot(),
                "required token0 -"
            );
            console2.log("required", required, tokenId.tokenType(0));
            assertEq(
                tokenId.tokenType(0) == 1 ? required : 0,
                tokenData1.leftSlot(),
                "required token1 -"
            );
           */
        }

        //check collateral output against panoptic pool at current tick
        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Bob,
                currentTick,
                positionIdList
            );
            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");

            console2.log("tokenData1.leftSlot()", tokenData1.leftSlot());
            collateralToken1.withdraw(
                collateralToken1.convertToAssets(collateralToken1.balanceOf(Bob)) -
                    (1334 * tokenData1.leftSlot()) /
                    1000,
                Bob,
                Bob,
                positionIdList,
                true
            );
            console2.log("tokenData0.leftSlot()", tokenData0.leftSlot());
            collateralToken0.withdraw(
                collateralToken0.convertToAssets(collateralToken0.balanceOf(Bob)) -
                    (1334 * tokenData0.leftSlot()) /
                    1000,
                Bob,
                Bob,
                positionIdList,
                true
            );
        }
        (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
            panopticPool,
            Bob,
            currentTick,
            positionIdList
        );

        for (uint256 i; i < 5; ++i) {
            twoWaySwap(10 ** 21 - 1);
            console2.log("i", i);
            console2.log("currentTick", currentTick);
            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, false, positionIdList);

            console2.log("long.r", $longPremia.rightSlot());
            console2.log("long.l", $longPremia.leftSlot());
            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Bob,
                currentTick,
                positionIdList
            );
            console2.log("balanceData0, thresholdData0", balanceData0, thresholdData0);
            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );
            console2.log("bb", calcBalanceCross, calcThresholdCross);
        }

        //check collateral output against panoptic pool at current tick
        {
            (, currentTick, , , , , ) = pool.slot0();

            ($shortPremia, $longPremia, posBalanceArray) = panopticPool
                .getAccumulatedFeesAndPositionsData(Bob, true, positionIdList);

            console2.log("long.r", $longPremia.rightSlot());
            console2.log("long.l", $longPremia.leftSlot());
            (LeftRightUnsigned tokenData0, LeftRightUnsigned tokenData1, ) = riskEngine.getMargin(
                posBalanceArray,
                currentTick,
                Bob,
                positionIdList,
                $shortPremia,
                $longPremia,
                collateralToken0,
                collateralToken1
            );

            (uint256 calcBalanceCross, uint256 calcThresholdCross) = PanopticMath.getCrossBalances(
                tokenData0,
                tokenData1,
                Math.getSqrtRatioAtTick(currentTick)
            );

            console2.log("calcBalanceCross", calcBalanceCross);
            console2.log("calcThresholdCross", calcThresholdCross);
            (balanceData0, thresholdData0) = panopticHelper.checkCollateral(
                panopticPool,
                Bob,
                currentTick,
                positionIdList
            );
            assertEq(balanceData0, calcBalanceCross, "0");
            assertEq(thresholdData0, calcThresholdCross, "1");
        }
    }

    // check force exercise range changes
    // check ranges are indeed evaluated at correct lower and upper tick bounds

    // try to force exercise an OTM option
    // call -> _currentTick < (strike - rangeDown)

    // put -> _currentTick > (strike + rangeUp)

    function test_Success_exerciseCostRanges_OTMCall(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        int24 atTick
    ) public {
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                0
            );

            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 0, 0, 0, strike, width);
            positionIdList.push(tokenId);

            // must be minimum at least 2 so there is enough liquidity to buy
            positionSize0 = uint128(bound(positionSizeSeed, 8, 2 ** 32));

            _assumePositionValidity(Bob, tokenId, positionSize0);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        {
            // Alice buys
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Alice);

            tokenId1 = TokenId.wrap(0).addPoolId(poolId).addLeg(0, 1, 1, 1, 0, 0, strike, width);
            positionIdList1.push(tokenId1);

            _assumePositionValidity(Alice, tokenId1, positionSize0 / 4);

            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 4,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        // check requirement at fuzzed tick
        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            (legLowerTick, legUpperTick) = tokenId1.asTicks(0);
            (int24 rangeDown, int24 rangeUp) = PanopticMath.getRangesFromStrike(width, tickSpacing);

            // strike - rangeDown
            vm.assume(atTick < legLowerTick);

            (LeftRightSigned longAmounts, ) = PanopticMath.computeExercisedAmounts(
                tokenId1,
                positionSize0 / 4,
                true
            );

            uint256 currNumRangesFromStrikeDown = uint256(
                (int256(strike - rangeUp - atTick)) / rangeUp
            );

            bool hasLegsInRange;
            if ((currentTick < strike + rangeUp) && (currentTick >= strike - rangeDown)) {
                hasLegsInRange = true;
            }

            int256 feeUp = hasLegsInRange ? -int256(102400) : -int256(1000);

            int256 exerciseFee0 = (longAmounts.rightSlot() * feeUp) / int128(DECIMALS);
            int256 exerciseFee1 = (longAmounts.leftSlot() * feeUp) / int128(DECIMALS);

            LeftRightSigned exerciseFees = riskEngine.exerciseCost(
                atTick,
                atTick, // use the fuzzed tick as the median tick for testing purposes
                tokenId1,
                PositionBalanceLibrary.storeBalanceData((positionSize0 / 4), 0, 0)
            );

            assertEq(exerciseFees.rightSlot(), exerciseFee0);
            assertEq(exerciseFees.leftSlot(), exerciseFee1);
        }
    }

    function test_Success_exerciseCostRanges_OTMPut(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        int24 atTick,
        uint256 asset
    ) public {
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                0
            );

            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                asset % 1,
                0,
                1,
                0,
                strike,
                width
            );
            positionIdList.push(tokenId);

            // must be minimum at least 2 so there is enough liquidity to buy
            positionSize0 = uint128(bound(positionSizeSeed, 8, 2 ** 32));

            _assumePositionValidity(Bob, tokenId, positionSize0);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        {
            // Alice buys
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Alice);

            tokenId1 = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                asset % 1,
                1,
                1,
                0,
                strike,
                width
            );
            positionIdList1.push(tokenId1);

            _assumePositionValidity(Alice, tokenId1, positionSize0 / 4);

            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 4,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        // check requirement at fuzzed tick
        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            (legLowerTick, legUpperTick) = tokenId1.asTicks(0);
            (int24 rangeDown, int24 rangeUp) = PanopticMath.getRangesFromStrike(width, tickSpacing);

            // strike - rangeDown
            vm.assume(atTick < legLowerTick);

            (LeftRightSigned longAmounts, ) = PanopticMath.computeExercisedAmounts(
                tokenId1,
                positionSize0 / 4,
                false
            );
            bool hasLegsInRange;
            if ((currentTick < strike + rangeUp) && (currentTick >= strike - rangeDown)) {
                hasLegsInRange = true;
            }

            int256 feeUp = hasLegsInRange ? -int256(102400) : -int256(1000);

            int256 exerciseFee0 = (longAmounts.rightSlot() * feeUp) / int128(DECIMALS);
            int256 exerciseFee1 = (longAmounts.leftSlot() * feeUp) / int128(DECIMALS);

            LeftRightSigned exerciseFees = riskEngine.exerciseCost(
                atTick,
                atTick, // use the fuzzed tick as the median tick for testing purposes
                tokenId1,
                PositionBalanceLibrary.storeBalanceData(positionSize0 / 4, 0, 0)
            );

            assertEq(exerciseFees.rightSlot(), exerciseFee0);
            assertEq(exerciseFees.leftSlot(), exerciseFee1);
        }
    }

    function test_Success_exerciseCostRanges_ITMCall(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        int24 atTick,
        uint256 asset
    ) public {
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                0
            );

            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                asset % 1,
                0,
                0,
                0,
                strike,
                width
            );
            positionIdList.push(tokenId);

            // must be minimum at least 2 so there is enough liquidity to buy
            positionSize0 = uint128(bound(positionSizeSeed, 8, 2 ** 32));

            _assumePositionValidity(Bob, tokenId, positionSize0);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        {
            // Alice buys
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Alice);

            tokenId1 = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                asset % 1,
                1,
                0,
                0,
                strike,
                width
            );
            positionIdList1.push(tokenId1);

            _assumePositionValidity(Alice, tokenId1, positionSize0 / 4);

            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 4,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        // check requirement at fuzzed tick
        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            (legLowerTick, legUpperTick) = tokenId1.asTicks(0);
            (int24 rangeDown, int24 rangeUp) = PanopticMath.getRangesFromStrike(width, tickSpacing);

            // strike - rangeDown
            vm.assume(atTick > legUpperTick);

            (LeftRightSigned longAmounts, ) = PanopticMath.computeExercisedAmounts(
                tokenId1,
                positionSize0 / 4,
                false
            );

            bool hasLegsInRange;
            if ((currentTick < strike + rangeUp) && (currentTick >= strike - rangeDown)) {
                hasLegsInRange = true;
            }

            int256 feeUp = hasLegsInRange ? -int256(102400) : -int256(1000);

            int256 exerciseFee0 = (longAmounts.rightSlot() * feeUp) / int128(DECIMALS);
            int256 exerciseFee1 = (longAmounts.leftSlot() * feeUp) / int128(DECIMALS);

            LeftRightSigned exerciseFees = riskEngine.exerciseCost(
                atTick,
                atTick, // use the fuzzed tick as the median tick for testing purposes
                tokenId1,
                PositionBalanceLibrary.storeBalanceData(positionSize0 / 4, 0, 0)
            );

            assertEq(exerciseFees.rightSlot(), exerciseFee0);
            assertEq(exerciseFees.leftSlot(), exerciseFee1);
        }
    }

    function test_Success_exerciseCostRanges_ITMPut(
        uint256 x,
        uint128 positionSizeSeed,
        uint256 widthSeed,
        int256 strikeSeed,
        int24 atTick,
        uint256 asset
    ) public {
        {
            _initWorld(x);

            // initalize a custom Panoptic pool
            _deployCustomPanopticPool(token0, token1, pool);

            // Invoke all interactions with the Collateral Tracker from user Bob
            vm.startPrank(Bob);

            // give Bob the max amount of tokens
            _grantTokens(Bob);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Bob);

            // have Bob sell
            (width, strike) = PositionUtils.getOTMSW(
                widthSeed,
                strikeSeed,
                uint24(tickSpacing),
                currentTick,
                0
            );

            tokenId = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                asset % 1,
                0,
                1,
                0,
                strike,
                width
            );
            positionIdList.push(tokenId);

            // must be minimum at least 2 so there is enough liquidity to buy
            positionSize0 = uint128(bound(positionSizeSeed, 8, 2 ** 32));

            _assumePositionValidity(Bob, tokenId, positionSize0);

            mintOptions(
                panopticPool,
                positionIdList,
                positionSize0,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        {
            // Alice buys
            vm.startPrank(Alice);

            // give Bob the max amount of tokens
            _grantTokens(Alice);

            // approve collateral tracker to move tokens on Bob's behalf
            IERC20Partial(token0).approve(address(collateralToken0), type(uint128).max);
            IERC20Partial(token1).approve(address(collateralToken1), type(uint128).max);

            // equal deposits for both collateral token pairs for testing purposes
            _mockMaxDeposit(Alice);

            tokenId1 = TokenId.wrap(0).addPoolId(poolId).addLeg(
                0,
                1,
                asset % 1,
                1,
                1,
                0,
                strike,
                width
            );
            positionIdList1.push(tokenId1);

            _assumePositionValidity(Alice, tokenId1, positionSize0 / 4);

            mintOptions(
                panopticPool,
                positionIdList1,
                positionSize0 / 4,
                type(uint24).max,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                true
            );
        }

        // check requirement at fuzzed tick
        {
            atTick = int24(bound(atTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
            atTick = (atTick / tickSpacing) * tickSpacing;

            (legLowerTick, legUpperTick) = tokenId1.asTicks(0);
            (int24 rangeDown, int24 rangeUp) = PanopticMath.getRangesFromStrike(width, tickSpacing);

            // strike - rangeDown
            vm.assume(atTick > legUpperTick);

            (LeftRightSigned longAmounts, ) = PanopticMath.computeExercisedAmounts(
                tokenId1,
                positionSize0 / 4,
                false
            );

            bool hasLegsInRange;
            if ((currentTick < strike + rangeUp) && (currentTick >= strike - rangeDown)) {
                hasLegsInRange = true;
            }

            int256 feeUp = hasLegsInRange ? -int256(102400) : -int256(1000);

            int256 exerciseFee0 = (longAmounts.rightSlot() * feeUp) / int128(DECIMALS);
            int256 exerciseFee1 = (longAmounts.leftSlot() * feeUp) / int128(DECIMALS);

            LeftRightSigned exerciseFees = riskEngine.exerciseCost(
                atTick,
                atTick, // use the fuzzed tick as the median tick for testing purposes
                tokenId1,
                PositionBalanceLibrary.storeBalanceData(positionSize0 / 4, 0, 0)
            );

            assertEq(exerciseFees.rightSlot(), exerciseFee0);
            assertEq(exerciseFees.leftSlot(), exerciseFee1);
        }
    }

    /* Utilization setter */
    function setUtilization(
        CollateralTrackerHarness collateralToken,
        address token,
        int256 targetUtilization,
        uint inAMMOffset,
        bool isBuy
    ) public {
        // utilization = inAMM * DECIMALS / totalAssets()
        // totalAssets() = PanopticPoolBal - lockedFunds + inAMM
        //        totalAssets() = z + inAMM
        //
        //
        // DECIMALS = DECIMALS
        //
        // utilization = (inAMM * DECIMALS) / ((PanopticPoolBal - lockedFunds) + inAMM)
        //      z = (PanopticPoolBal - lockedFunds)
        //      utilization =  (inAMM * DECIMALS) / z + inAMM
        //      inAMM = (utilization * z) / (DECIMALS - utilization)
        //      inAMM / z = utilization / (DECIMALS - utilization)
        //
        // inAMM / (PanopticPoolBal - lockedFunds) = (utilization / (DECIMALS(DECIMALS) - utilization))
        //
        // i.e utilization of 9_000
        //    inAMM / (PanopticPoolBal - lockedFunds) = 9_000 / DECIMALS - 9_000
        //    inAMM / (PanopticPoolBal - lockedFunds) = 9
        //    assume bal of (pool > lockedFunds) and (bal pool - lockedFunds) + inAMM > 0)
        //
        //    i.e 900 / (110 - 10) = 9
        //    utilization = (inAMM * DECIMALS) / ((PanopticPoolBal - lockedFunds) + inAMM)
        //    utilization = (900 * 10_000) / ((110 - 10) + 900)
        //    utilization = 9000.0
        //
        //-----------------------------------------------------------
        int128 _poolBalance = int128(
            int256(manager.balanceOf(address(panopticPool), uint160(token)))
        );
        // Solve for a mocked inAMM amount using real lockedFunds and pool bal
        // satisfy the condition of poolBalance > lockedFunds
        // let poolBalance and lockedFunds be fuzzed
        // inAMM = utilization * (PanopticPoolBal - lockedFunds) / (10_000 - utilization)
        vm.assume(_poolBalance < type(int128).max);
        int256 inAMM = (targetUtilization * (_poolBalance)) / (int128(10_000) - targetUtilization);
        isBuy ? inAMM += int128(int256((inAMMOffset))) : inAMM -= int128(int256((inAMMOffset)));

        // set states
        collateralToken.setInAMM(int128(inAMM));
        deal(token, address(panopticPool), uint128(_poolBalance));
    }

    /*//////////////////////////////////////////////////////////////
                        CONVERT TO ASSETS
    //////////////////////////////////////////////////////////////*/

    function test_Success_convertToAssets_supplyNonZero(uint256 x, uint104 shares) public {
        // fuzz
        _initWorld(x);

        _testconvertToAssetsNonZero(shares);
    }

    // convert to assets tests with a non-zero supply
    // internal function as this is used in many other preview tests
    function _testconvertToAssetsNonZero(uint104 shares) internal returns (uint256) {
        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);
        shares = uint104(bound(shares, 1, type(uint104).max));

        // approve collateral tracker to move tokens on Bob's behalf
        IERC20Partial(token0).approve(address(collateralToken0), shares);
        IERC20Partial(token1).approve(address(collateralToken1), shares);

        // deposit a number of assets determined via fuzzing
        // equal deposits for both collateral token pairs for testing purposes
        collateralToken0.deposit(shares, Bob);
        collateralToken1.deposit(shares, Bob);

        // amount of assets user deposited computed in amount of shares
        uint256 assets0 = convertToAssets(shares, collateralToken0);
        uint256 assets1 = convertToAssets(shares, collateralToken1);

        // actual value of current shares redeemable
        uint256 actualValue0 = collateralToken0.convertToAssets(shares);
        uint256 actualValue1 = collateralToken1.convertToAssets(shares);

        // ensure the correct amount of shares to assets is computed
        assertEq(assets0, actualValue0);
        assertEq(assets1, actualValue1);

        return assets0;
    }

    /*//////////////////////////////////////////////////////////////
                        CONVERT TO SHARES
    //////////////////////////////////////////////////////////////*/

    function test_Success_convertToShares_supplyNonZero(uint256 x, uint104 assets) public {
        // fuzz
        _initWorld(x);

        _testconvertToSharesNonZero(assets);
    }

    // convert to assets tests with a non-zero supply
    // internal function as this is used in many other preview tests
    function _testconvertToSharesNonZero(uint104 assets) internal returns (uint256 shares0) {
        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);
        assets = uint104(bound(assets, 1, type(uint104).max));

        // approve collateral tracker to move tokens on Bob's behalf
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        IERC20Partial(token1).approve(address(collateralToken1), assets);

        // deposit a number of assets determined via fuzzing
        // equal deposits for both collateral token pairs for testing purposes
        collateralToken0.deposit(assets, Bob);
        collateralToken1.deposit(assets, Bob);

        // amount of assets user deposited computed in amount of shares
        shares0 = convertToShares(assets, collateralToken0);
        uint256 shares1 = convertToShares(assets, collateralToken1);

        // actual value of current shares redeemable
        uint256 actualValue0 = collateralToken0.convertToAssets(shares0);
        uint256 actualValue1 = collateralToken1.convertToAssets(shares1);

        // ensure the correct amount of assets to shares is computed
        assertApproxEqAbs(assets, actualValue0, 5);
        assertApproxEqAbs(assets, actualValue1, 5);

        return shares0;
    }

    /*//////////////////////////////////////////////////////////////
                        MISCELLANEOUS QUERIES
    //////////////////////////////////////////////////////////////*/

    function test_Success_previewRedeem(uint256 x) public {
        _initWorld(x);

        // use a fixed amount for single test
        uint256 expectedValue = _testconvertToAssetsNonZero(1000);

        // real value
        uint256 actualValue = collateralToken0.previewRedeem(1000);

        assertEq(expectedValue, actualValue);
    }

    // maxRedeem
    function test_Success_maxRedeem(uint256 x, uint104 shares) public {
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);

        // calculate underlying assets via amount of shares
        uint256 assetsToken0 = convertToAssets(shares, collateralToken0);
        uint256 assetsToken1 = convertToAssets(shares, collateralToken1);

        // approve collateral tracker to move tokens on Bob's behalf
        IERC20Partial(token0).approve(address(collateralToken0), assetsToken0);
        IERC20Partial(token1).approve(address(collateralToken1), assetsToken1);

        // deposit a number of assets determined via fuzzing
        // equal deposits for both collateral token pairs for testing purposes
        vm.assume(assetsToken0 > 0);
        vm.assume(assetsToken1 > 0);
        collateralToken0.deposit(uint128(assetsToken0), Bob);
        collateralToken1.deposit(uint128(assetsToken1), Bob);

        // how many funds that can be redeemed currently
        uint256 availableAssets0 = convertToShares(
            collateralToken0._availableAssets(),
            collateralToken0
        );
        uint256 availableAssets1 = convertToShares(
            collateralToken1._availableAssets(),
            collateralToken1
        );

        // current share balance of owner
        uint256 balance0 = collateralToken0.balanceOf(Bob);
        uint256 balance1 = collateralToken1.balanceOf(Bob);

        // actual maxRedeem returned value
        uint256 actualValue0 = collateralToken0.maxRedeem(Bob);
        uint256 actualValue1 = collateralToken1.maxRedeem(Bob);

        // if there are option positions this should return 0
        if (panopticPool.numberOfLegs(Bob) != 0) {
            assertEq(0, actualValue0);
            assertEq(0, actualValue1);
            // if available is greater than the user balance
            // return the user balance
        } else if (availableAssets0 > balance0) {
            assertEq(balance0, actualValue0);
            assertEq(balance1, actualValue1);
        } else {
            assertEq(availableAssets0, actualValue0);
            assertEq(availableAssets1, actualValue1);
        }
    }

    // previewWithdraw
    function test_Success_previewWithdraw(uint256 x) public {
        _initWorld(x);

        // use a fixed amount for single test
        _testconvertToSharesNonZero(1000);

        // real value
        uint256 actualValue = collateralToken0.previewWithdraw(1000);

        assertEq(actualValue, 1000000000);
    }

    // maxWithdraw
    function test_Success_maxWithdraw(uint256 x, uint104 assets) public {
        _initWorld(x);

        // Invoke all interactions with the Collateral Tracker from user Bob
        vm.startPrank(Bob);

        // give Bob the max amount of tokens
        _grantTokens(Bob);
        assets = uint104(bound(assets, 1, type(uint104).max));

        // approve collateral tracker to move tokens on Bob's behalf
        IERC20Partial(token0).approve(address(collateralToken0), assets);
        IERC20Partial(token1).approve(address(collateralToken1), assets);

        // deposit a number of assets determined via fuzzing
        // equal deposits for both collateral token pairs for testing purposes
        collateralToken0.deposit(assets, Bob);
        collateralToken1.deposit(assets, Bob);

        // how many funds that can be redeemed currently
        uint256 availableAssets0 = convertToShares(
            collateralToken0._availableAssets(),
            collateralToken0
        );

        // current share balance of owner
        uint256 balance0 = convertToAssets(collateralToken0.balanceOf(Bob), collateralToken0);
        uint256 balance1 = convertToAssets(collateralToken1.balanceOf(Bob), collateralToken0);

        // actual maxRedeem returned value
        uint256 actualValue0 = collateralToken0.maxWithdraw(Bob);
        uint256 actualValue1 = collateralToken1.maxWithdraw(Bob);

        // if there are option positions this should return 0
        if (panopticPool.numberOfLegs(Bob) != 0) {
            assertEq(0, actualValue0, "with open positions 0");
            assertEq(0, actualValue1, "with open positions 1");
            // if available is greater than the user balance
            // return the user balance
        } else if (availableAssets0 > balance0) {
            assertEq(balance0, actualValue0, "user balance 0");
            assertEq(balance1, actualValue1, "user balance 1");
        } else {
            uint256 available0 = collateralToken0._availableAssets();
            uint256 available1 = collateralToken1._availableAssets();

            assertEq(available0, actualValue0, "available assets 0");
            assertEq(available1, actualValue1, "available assets 1");
        }
    }

    // previewMint
    function test_Success_previewMint(uint256 x, uint104 shares) public {
        _initWorld(x);
        // use a fixed amount for single test
        _testconvertToAssetsNonZero(shares);

        uint256 expectedValue = convertToAssets(shares, collateralToken0);

        // real value
        uint256 actualValue = collateralToken0.previewMint(shares);

        assertApproxEqAbs(((expectedValue)), actualValue, 5);
    }

    // maxMint
    function test_Success_maxMint(uint256 x) public {
        _initWorld(x);

        // use a fixed amount for single test
        uint256 expectedValue = (collateralToken0.convertToShares(type(uint104).max));

        // real value
        uint256 actualValue = collateralToken0.maxMint(Bob);

        assertEq(expectedValue, actualValue);
    }

    // previewDeposit
    function test_Success_previewDeposit(uint256 x) public {
        _initWorld(x);

        // use a fixed amount for single test
        uint256 expectedValue = _testconvertToSharesNonZero(1000);

        // real value
        uint256 actualValue = collateralToken0.previewDeposit(1000);

        assertEq((expectedValue), actualValue);
    }

    // maxDeposit
    function test_Success_maxDeposit(uint256 x) public {
        _initWorld(x);

        uint256 expectedValue = type(uint104).max;

        // real value
        uint256 actualValue = collateralToken0.maxDeposit(Bob);

        assertEq(expectedValue, actualValue);
    }

    // availableAssets
    function test_Success_availableAssets(uint256 x, uint256 balance) public {
        _initWorld(x);

        balance = bound(balance, 0, uint128(type(uint128).max));

        // set total balance of underlying asset in the Panoptic pool
        collateralToken0.setPoolAssets(balance);
        collateralToken1.setPoolAssets(balance);

        // expected values
        uint256 expectedValue = balance;

        // actual values
        uint256 actualValue0 = collateralToken0._availableAssets();
        uint256 actualValue1 = collateralToken1._availableAssets();

        assertEq(expectedValue, actualValue0);
        assertEq(expectedValue, actualValue1);
    }

    // totalAssets
    function test_Success_totalAssets(uint256 x, uint128 balance, uint128 inAMM) public {
        vm.assume(balance > 0 && balance < uint128(type(int128).max));
        inAMM = uint128(bound(inAMM, 0, balance));

        _initWorld(x);

        // set total balance of underlying asset in the Panoptic pool
        collateralToken0.setPoolAssets(balance);
        collateralToken1.setPoolAssets(balance);

        // set how many funds are locked
        collateralToken0.setInAMM(int128(inAMM));
        collateralToken1.setInAMM(int128(inAMM));

        // expected values
        uint256 expectedValue = (balance) + inAMM;

        // actual values
        uint256 actualValue0 = collateralToken0.totalAssets();
        uint256 actualValue1 = collateralToken1.totalAssets();

        assertEq(expectedValue, actualValue0);
        assertEq(expectedValue, actualValue1);
    }

    /*//////////////////////////////////////////////////////////////
                        INFORMATION TESTS
    //////////////////////////////////////////////////////////////*/
    function test_Success_poolData(uint256 x) public {
        _initWorld(x);

        // expected values

        collateralToken0.setPoolAssets(10 ** 10); // give pool 10 ** 10 tokens
        uint256 expectedBal = 10 ** 10;

        collateralToken0.setInAMM(100);
        uint256 expectedInAMM = 100;

        // bal + inAMM - totalAssets()
        uint256 expectedTotalBalance = expectedBal + expectedInAMM;

        // _inAMM() * DECIMALS) / totalAssets()
        uint256 expectedPoolUtilization = Math.mulDivRoundingUp(
            expectedInAMM,
            10_000,
            expectedTotalBalance
        );

        (
            uint256 poolAssets,
            uint256 insideAMM,
            uint256 creditedShares,
            uint256 currentPoolUtilization
        ) = collateralToken0.getPoolData();

        assertEq(expectedBal, poolAssets);
        assertEq(expectedInAMM, insideAMM);
        assertEq(expectedPoolUtilization, currentPoolUtilization);
    }

    function test_Success_name(uint256 x) public {
        _initWorld(x);

        // string memory expectedName =
        //     string.concat(
        //             "POPT-V1",
        //             " ",
        //             IERC20Metadata(s_univ3token0).symbol(),
        //             " LP on ",
        //             symbol0,
        //             "/",
        //             symbol1,
        //             " ",
        //             fee % 100 == 0
        //                 ? Strings.toString(fee / 100)
        //                 : string.concat(Strings.toString(fee / 100), ".", Strings.toString(fee % 100)),
        //             "bps"
        //         );

        string memory returnedName = collateralToken0.name();
        console2.log(returnedName);
    }

    function test_Success_symbol(uint256 x) public {
        _initWorld(x);

        // string.concat(TICKER_PREFIX, symbol);
        // "po" + symbol IERC20Metadata(s_underlyingToken).symbol()

        string memory returnedSymbol = collateralToken0.symbol();
        console2.log(returnedSymbol);
    }

    function test_Success_decimals(uint256 x) public {
        _initWorld(x);

        //IERC20Metadata(s_underlyingToken).decimals()

        console2.log(collateralToken0.decimals());
    }

    /*//////////////////////////////////////////////////////////////
                    REPLICATED FUNCTIONS (TEST HELPERS)
    //////////////////////////////////////////////////////////////*/

    function convertToShares(
        uint256 assets,
        CollateralTracker collateralToken
    ) public view returns (uint256 shares) {
        uint256 supply = collateralToken.totalSupply();
        return Math.mulDiv(assets, supply, collateralToken.totalAssets());
    }

    function convertToAssets(
        uint256 shares,
        CollateralTracker collateralToken
    ) public view returns (uint256 assets) {
        uint256 supply = collateralToken.totalSupply();
        return Math.mulDiv(shares, collateralToken.totalAssets(), supply);
    }

    /*//////////////////////////////////////////////////////////////
                    POSITION VALIDITY CHECKER
    //////////////////////////////////////////////////////////////*/

    struct CallbackData {
        PoolAddress.PoolKey univ3poolKey;
        address payer;
    }

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        // Decode the mint callback data
        CallbackData memory decoded = abi.decode(data, (CallbackData));

        // Sends the amount0Owed and amount1Owed quantities provided
        if (amount0Owed > 0)
            TransferHelper.safeTransferFrom(
                decoded.univ3poolKey.token0,
                decoded.payer,
                msg.sender,
                amount0Owed
            );
        if (amount1Owed > 0)
            TransferHelper.safeTransferFrom(
                decoded.univ3poolKey.token1,
                decoded.payer,
                msg.sender,
                amount1Owed
            );
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        // Decode the swap callback data, checks that the UniswapV3Pool has the correct address.
        CallbackData memory decoded = abi.decode(data, (CallbackData));

        // Extract the address of the token to be sent (amount0 -> token0, amount1 -> token1)
        address token = amount0Delta > 0
            ? address(decoded.univ3poolKey.token0)
            : address(decoded.univ3poolKey.token1);

        // Transform the amount to pay to uint256 (take positive one from amount0 and amount1)
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);

        // Pay the required token from the payer to the caller of this contract
        TransferHelper.safeTransferFrom(token, decoded.payer, msg.sender, amountToPay);
    }

    function _swapITM(int128 itm0, int128 itm1) internal {
        // Initialize variables
        bool zeroForOne; // The direction of the swap, true for token0 to token1, false for token1 to token0
        int256 swapAmount; // The amount of token0 or token1 to swap
        if ((itm0 != 0) && (itm1 != 0)) {
            (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

            /// @dev we need to compare (deltaX = itm0 - itm1/price) to (deltaY =  itm1 - itm0 * price) to only swap the owed balance
            /// To reduce the number of computation steps, we do the following:
            ///    deltaX = (itm0*sqrtPrice - itm1/sqrtPrice)/sqrtPrice
            ///    deltaY = -(itm0*sqrtPrice - itm1/sqrtPrice)*sqrtPrice
            int256 net0 = itm0 + PanopticMath.convert1to0(itm1, sqrtPriceX96);

            int256 net1 = itm1 + PanopticMath.convert0to1(itm0, sqrtPriceX96);

            // if net1 is negative, then the protocol has a surplus of token0
            zeroForOne = net1 < net0;

            // compute the swap amount, set as positive (exact input)
            swapAmount = zeroForOne ? net0 : net1;
        } else if (itm0 != 0) {
            zeroForOne = itm0 < 0;
            swapAmount = -itm0;
        } else {
            zeroForOne = itm1 > 0;
            swapAmount = -itm1;
        }

        // assert the pool has enough funds to complete the swap for an ITM position (exchange tokens to token type)
        try
            V4RouterSimple(address(sfpm)).swap(address(0), poolKey, swapAmount, zeroForOne)
        {} catch {
            vm.assume(false);
        }
    }

    // Checks to see that a valid position is minted via simulation
    // asserts that the leg is sufficiently large enough to meet dust threshold requirement
    // also ensures that this is a valid mintable position in uniswap (i.e liquidity amount too much for pool, then fuzz a new positionSize)
    function _assumePositionValidity(
        address caller,
        TokenId _tokenId,
        uint128 positionSize
    ) internal {
        // take a snapshot at this storage state
        uint256 snapshot = vm.snapshot();
        vm.startPrank(address(panopticPool));

        vm.etch(address(sfpm), address(routerV4).code);

        manager.setOperator(address(routerV4), true);

        routerV4.burnCurrency(
            address(0),
            poolKey.currency0,
            manager.balanceOf(address(panopticPool), uint160(token0))
        );
        routerV4.burnCurrency(
            address(0),
            poolKey.currency1,
            manager.balanceOf(address(panopticPool), uint160(token1))
        );
        IERC20Partial(token0).approve(address(sfpm), type(uint256).max);
        IERC20Partial(token1).approve(address(sfpm), type(uint256).max);

        int128 itm0;
        int128 itm1;

        uint256 amount0;
        uint256 amount1;

        uint256 maxLoop = _tokenId.countLegs();
        for (uint256 i; i < maxLoop; i++) {
            // basis
            uint256 asset = _tokenId.asset(i);

            // token type we are transacting in
            tokenType = _tokenId.tokenType(i);

            // position bounds
            (legLowerTick, legUpperTick) = _tokenId.asTicks(i);

            // sqrt price of bounds
            sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(legLowerTick);
            sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(legUpperTick);

            if (sqrtRatioAX96 > sqrtRatioBX96)
                (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

            /// get the liquidity
            if (asset == 0) {
                uint256 intermediate = Math.mulDiv96(sqrtRatioAX96, sqrtRatioBX96);
                liquidity = FullMath.mulDiv(
                    positionSize,
                    intermediate,
                    sqrtRatioBX96 - sqrtRatioAX96
                );
            } else {
                liquidity = FullMath.mulDiv(
                    positionSize,
                    FixedPoint96.Q96,
                    sqrtRatioBX96 - sqrtRatioAX96
                );
            }

            // liquidity should be less than 128 bits
            vm.assume(liquidity != 0 && liquidity < type(uint128).max);

            amount0 += LiquidityAmounts.getAmount0ForLiquidity(
                sqrtRatioAX96,
                sqrtRatioBX96,
                uint128(liquidity)
            );

            amount1 += LiquidityAmounts.getAmount1ForLiquidity(
                sqrtRatioAX96,
                sqrtRatioBX96,
                uint128(liquidity)
            );

            vm.assume(amount0 < 2 ** 127 - 1 && amount1 < 2 ** 127 - 1);

            /// assert the notional value is valid
            uint128 contractSize = positionSize * uint128(tokenId.optionRatio(i));

            uint256 notional = asset == 0
                ? PanopticMath.convert0to1(
                    contractSize,
                    TickMath.getSqrtRatioAtTick((legUpperTick + legLowerTick) / 2)
                )
                : PanopticMath.convert1to0(
                    contractSize,
                    TickMath.getSqrtRatioAtTick((legUpperTick + legLowerTick) / 2)
                );
            vm.assume(notional != 0 && notional < type(uint128).max);

            /// simulate mint/burn
            // mint in pool if short
            if (tokenId.isLong(i) == 0) {
                // try
                //     pool.mint(
                //         address(sfpm),
                //         legLowerTick,
                //         legUpperTick,
                //         uint128(liquidity),
                //         abi.encode(
                //             CallbackData({
                //                 univ3poolKey: PoolAddress.PoolKey({
                //                     token0: pool.token0(),
                //                     token1: pool.token1(),
                //                     fee: pool.fee()
                //                 }),
                //                 payer: address(panopticPool)
                //             })
                //         )
                //     )
                try
                    V4RouterSimple(address(sfpm)).modifyLiquidity(
                        address(0),
                        poolKey,
                        legLowerTick,
                        legUpperTick,
                        int256(liquidity)
                    )
                returns (int256 _amount0, int256 _amount1) {
                    // assert that it meets the dust threshold requirement
                    vm.assume(
                        (-_amount0 > 50 && -_amount0 < type(int128).max) ||
                            (-_amount1 > 50 && -_amount1 < type(int128).max)
                    );

                    if (tokenType == 1) {
                        itm0 += int128(-_amount0);
                    } else {
                        itm1 += int128(-_amount1);
                    }
                } catch {
                    vm.assume(false); // invalid position, discard
                }
            } else {
                address _caller = caller;
                V4RouterSimple(address(sfpm)).modifyLiquidityWithSalt(
                    address(0),
                    poolKey,
                    legLowerTick,
                    legUpperTick,
                    int256(liquidity),
                    keccak256(
                        abi.encodePacked(
                            poolKey.toId(),
                            _caller,
                            tokenType,
                            legLowerTick,
                            legUpperTick
                        )
                    )
                );
            }
        }

        if (itm0 != 0 || itm1 != 0)
            // assert the pool has enough funds to complete the swap if ITM
            _swapITM(itm0, itm1);

        // rollback to the previous storage state
        vm.revertTo(snapshot);

        // revert back to original caller
        vm.startPrank(caller);
    }

    function _verifyBonusAmounts(
        LeftRightUnsigned tokenData,
        LeftRightUnsigned otherTokenData,
        uint160 sqrtPriceX96
    ) internal view returns (LeftRightSigned bonusAmounts) {
        uint256 token1TotalValue;
        uint256 tokenValue;
        token1TotalValue = (tokenData.rightSlot() * Constants.FP96) / sqrtPriceX96;
        tokenValue = token1TotalValue + Math.mulDiv96(otherTokenData.rightSlot(), sqrtPriceX96);

        uint256 requiredValue;
        requiredValue =
            (tokenData.leftSlot() * Constants.FP96) /
            sqrtPriceX96 +
            Math.mulDiv96(otherTokenData.leftSlot(), sqrtPriceX96);

        uint256 valueRatio1;
        valueRatio1 =
            (tokenData.rightSlot() * Constants.FP96 * DECIMALS) /
            tokenValue /
            sqrtPriceX96;

        int128 bonus0;
        int128 bonus1;
        bonus0 = int128(
            int256(
                otherTokenData.leftSlot() < otherTokenData.rightSlot()
                    ? ((tokenValue) * (DECIMALS - valueRatio1) * Constants.FP96) / sqrtPriceX96
                    : ((requiredValue - tokenValue) * (DECIMALS - valueRatio1) * Constants.FP96) /
                        sqrtPriceX96
            )
        );

        bonus1 = int128(
            int256(
                tokenData.leftSlot() < tokenData.rightSlot()
                    ? Math.mulDiv96((tokenValue) * (valueRatio1), sqrtPriceX96)
                    : Math.mulDiv96((requiredValue - tokenValue) * (valueRatio1), sqrtPriceX96)
            )
        );

        // store bonus amounts as actual amounts by dividing by DECIMALS_128
        bonusAmounts = bonusAmounts.addToRightSlot(bonus0 / int128(DECIMALS)).addToLeftSlot(
            bonus1 / int128(DECIMALS)
        );
    }

    /*//////////////////////////////////////////////////////////////
                    COLLATERAL CHECKER
    //////////////////////////////////////////////////////////////*/
    function _tokensRequired(
        TokenId _tokenId,
        uint128 positionSize,
        int24 atTick,
        uint128 poolUtilization,
        uint256[2] memory checkSingle // flag to check single tokenId index
    ) internal returns (uint128 tokensRequired) {
        uint i;
        uint maxLoop;
        if (checkSingle[0] == 1) {
            i = checkSingle[1];
            maxLoop = checkSingle[1] + 1;
        } else {
            i = 0;
            maxLoop = _tokenId.countLegs();
        }

        for (; i < maxLoop; ++i) {
            int16 utilization = int16(
                uint16(tokenId.tokenType(i) == 0 ? poolUtilization : poolUtilization >> 64)
            );
            uint128 _tokensRequired = uint128(
                riskEngine.getRequiredCollateralSingleLeg(
                    _tokenId,
                    i,
                    positionSize,
                    atTick,
                    utilization
                )
            );

            tokensRequired += _tokensRequired;
        }
    }

    function _spreadTokensRequired(
        TokenId _tokenId,
        uint128 positionSize,
        uint128 poolUtilizations,
        int24 atTick
    ) internal returns (uint128 tokensRequired) {
        uint maxLoop = tokenId.countLegs();

        uint256 _tempTokensRequired;

        for (uint i; i < maxLoop; ++i) {
            int16 utilization = int16(
                uint16(tokenId.tokenType(i) == 0 ? poolUtilizations : poolUtilizations >> 64)
            );
            uint128 _tokensRequired = uint128(
                riskEngine.getRequiredCollateralSingleLeg(
                    _tokenId,
                    i,
                    positionSize,
                    atTick,
                    utilization
                )
            );

            tokensRequired += _tokensRequired;
        }
    }

    function _strangleTokensRequired(
        TokenId _tokenId,
        uint128 positionSize,
        uint128 poolUtilization,
        int24 atTick
    ) internal returns (uint128 tokensRequired0, uint128 tokensRequired1) {
        uint maxLoop = tokenId.countLegs();

        uint128 tokensRequired;

        for (uint i; i < maxLoop; ++i) {
            int16 utilization = int16(
                uint16(tokenId.tokenType(i) == 0 ? poolUtilization : poolUtilization >> 64)
            );
            uint128 _tokensRequired = uint128(
                riskEngine.getRequiredCollateralSingleLeg(
                    _tokenId,
                    i,
                    positionSize,
                    atTick,
                    utilization
                )
            );

            console2.log("utilization", utilization);

            if (tokenId.tokenType(i) == 0) {
                tokensRequired0 += _tokensRequired;
            } else {
                tokensRequired1 += _tokensRequired;
            }
        }
    }
}
