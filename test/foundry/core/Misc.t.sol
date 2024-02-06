import "forge-std/Test.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {PanopticHelper} from "@contracts/periphery/PanopticHelper.sol";
import {ISwapRouter} from "v3-periphery/interfaces/ISwapRouter.sol";
import {ERC20S} from "@scripts/tokens/ERC20S.sol";
import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {TokenId} from "@types/TokenId.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {CallbackLib} from "@libraries/CallbackLib.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";
import {PositionUtils} from "../testUtils/PositionUtils.sol";

contract SwapperC {
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        // Decode the swap callback data, checks that the UniswapV3Pool has the correct address.
        CallbackLib.CallbackData memory decoded = abi.decode(data, (CallbackLib.CallbackData));

        // Extract the address of the token to be sent (amount0 -> token0, amount1 -> token1)
        address token = amount0Delta > 0
            ? address(decoded.poolFeatures.token0)
            : address(decoded.poolFeatures.token1);

        // Transform the amount to pay to uint256 (take positive one from amount0 and amount1)
        // the pool will always pass one delta with a positive sign and one with a negative sign or zero,
        // so this logic always picks the correct delta to pay
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);

        // Pay the required token from the payer to the caller of this contract
        SafeTransferLib.safeTransferFrom(token, decoded.payer, msg.sender, amountToPay);
    }

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        // Decode the mint callback data
        CallbackLib.CallbackData memory decoded = abi.decode(data, (CallbackLib.CallbackData));

        // Sends the amount0Owed and amount1Owed quantities provided
        if (amount0Owed > 0)
            SafeTransferLib.safeTransferFrom(
                decoded.poolFeatures.token0,
                decoded.payer,
                msg.sender,
                amount0Owed
            );
        if (amount1Owed > 0)
            SafeTransferLib.safeTransferFrom(
                decoded.poolFeatures.token1,
                decoded.payer,
                msg.sender,
                amount1Owed
            );
    }

    function mint(IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) public {
        pool.mint(
            address(this),
            tickLower,
            tickUpper,
            liquidity,
            abi.encode(
                CallbackLib.CallbackData({
                    poolFeatures: CallbackLib.PoolFeatures({
                        token0: pool.token0(),
                        token1: pool.token1(),
                        fee: pool.fee()
                    }),
                    payer: msg.sender
                })
            )
        );
    }

    function burn(IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) public {
        pool.burn(tickLower, tickUpper, liquidity);
    }

    function swapTo(IUniswapV3Pool pool, uint160 sqrtPriceX96) public {
        (uint160 sqrtPriceX96Before, , , , , , ) = pool.slot0();

        if (sqrtPriceX96Before == sqrtPriceX96) return;

        (int256 amount0, int256 amount1) = pool.swap(
            msg.sender,
            sqrtPriceX96Before > sqrtPriceX96 ? true : false,
            type(int128).max,
            sqrtPriceX96,
            abi.encode(
                CallbackLib.CallbackData({
                    poolFeatures: CallbackLib.PoolFeatures({
                        token0: pool.token0(),
                        token1: pool.token1(),
                        fee: pool.fee()
                    }),
                    payer: msg.sender
                })
            )
        );
    }
}

// mostly just fixed one-off tests/PoC
contract Misctest is Test, PositionUtils {
    using TokenId for uint256;
    // the instance of SFPM we are testing
    SemiFungiblePositionManager sfpm;

    // reference implemenatations used by the factory
    address poolReference;

    address collateralReference;

    // Mainnet factory address - SFPM is dependent on this for several checks and callbacks
    IUniswapV3Factory V3FACTORY = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

    // Mainnet router address - used for swaps to test fees/premia
    ISwapRouter router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    PanopticFactory factory;
    PanopticPool pp;
    CollateralTracker ct0;
    CollateralTracker ct1;
    PanopticHelper ph;

    IUniswapV3Pool uniPool;
    ERC20S token0;
    ERC20S token1;

    address Deployer = address(0x1234);
    address Alice = address(0x123456);
    address Bob = address(0x12345678);
    address Swapper = address(0x123456789);
    address Charlie = address(0x1234567891);
    address Seller = address(0x12345678912);

    function setUp() public {
        vm.startPrank(Deployer);

        sfpm = new SemiFungiblePositionManager(V3FACTORY);

        ph = new PanopticHelper(sfpm);

        // deploy reference pool and collateral token
        poolReference = address(new PanopticPool(sfpm));
        collateralReference = address(new CollateralTracker());
        token0 = new ERC20S("token0", "T0", 18);
        token1 = new ERC20S("token1", "T1", 18);
        uniPool = IUniswapV3Pool(V3FACTORY.createPool(address(token0), address(token1), 500));

        // This price causes exactly one unit of liquidity to be minted
        // above here reverts b/c 0 liquidity cannot be minted
        IUniswapV3Pool(uniPool).initialize(10 ** 17 * 2 ** 96);

        factory = new PanopticFactory(
            address(token1),
            sfpm,
            V3FACTORY,
            poolReference,
            collateralReference
        );

        token0.mint(Deployer, type(uint104).max);
        token1.mint(Deployer, type(uint104).max);
        token0.approve(address(factory), type(uint104).max);
        token1.approve(address(factory), type(uint104).max);

        pp = PanopticPool(
            address(factory.deployNewPool(address(token0), address(token1), 500, 1337))
        );

        changePrank(Alice);

        token0.mint(Alice, type(uint104).max);
        token1.mint(Alice, type(uint104).max);

        ct0 = pp.collateralToken0();
        ct1 = pp.collateralToken1();

        console2.log("ct0.totalAssets()", ct0.totalAssets());

        token0.approve(address(ct0), type(uint104).max);
        token1.approve(address(ct1), type(uint104).max);

        ct0.deposit(type(uint104).max, Alice);
        ct1.deposit(type(uint104).max, Alice);

        changePrank(Bob);

        token0.mint(Bob, type(uint104).max);
        token1.mint(Bob, type(uint104).max);

        token0.approve(address(ct0), type(uint104).max);
        token1.approve(address(ct1), type(uint104).max);

        ct0.deposit(type(uint104).max, Bob);
        ct1.deposit(type(uint104).max, Bob);
    }

    function test_success_PremiumRollover() public {
        SwapperC swapperc = new SwapperC();
        changePrank(Swapper);
        token0.mint(Swapper, type(uint128).max);
        token1.mint(Swapper, type(uint128).max);
        token0.approve(address(swapperc), type(uint128).max);
        token1.approve(address(swapperc), type(uint128).max);

        // move back to price=1
        swapperc.swapTo(uniPool, 2 ** 96);

        // JIT a bunch of liquidity so swaps at mint can happen normally
        swapperc.mint(uniPool, -10, 10, 10 ** 18);

        // L = 1
        uniPool.liquidity();

        uint256 tokenId = uint256(0).addUniv3pool(PanopticMath.getPoolId(address(uniPool))).addLeg(
            0,
            1,
            1,
            0,
            0,
            0,
            0,
            4094
        );

        uint256[] memory posIdList = new uint256[](1);
        posIdList[0] = tokenId;

        changePrank(Bob);
        // mint 1 liquidity unit of wideish centered position
        pp.mintOptions(posIdList, 3, 0, 0, 0);

        changePrank(Swapper);
        swapperc.burn(uniPool, -10, 10, 10 ** 18);

        // L = 2
        uniPool.liquidity();

        // accumulate the maximum fees per liq SFPM supports
        accruePoolFeesInRange(address(uniPool), 1, 2 ** 64 - 1, 2 ** 64 - 1);

        changePrank(Swapper);
        swapperc.mint(uniPool, -10, 10, 10 ** 18);

        changePrank(Bob);
        // works fine
        pp.burnOptions(tokenId, new uint256[](0), 0, 0);

        uint256 balanceBefore = ct0.convertToAssets(ct0.balanceOf(Alice));

        changePrank(Alice);

        // lock in almost-overflowed fees per liquidity
        pp.mintOptions(posIdList, 1000, 0, 0, 0);

        changePrank(Swapper);
        swapperc.burn(uniPool, -10, 10, 10 ** 18);

        // overflow back to ~1_000_000 (fees per liq)
        accruePoolFeesInRange(address(uniPool), 413, 1_000_000, 1_000_000);

        // this should behave like the actual accumulator does and rollover, not revert on overflow
        (uint256 premium0, uint256 premium1) = sfpm.getAccountPremium(
            address(uniPool),
            address(pp),
            0,
            -20470,
            20470,
            0,
            0
        );
        assertEq(premium0, 44646762138360822200777);
        assertEq(premium1, 44646762138360822200777);

        changePrank(Swapper);
        swapperc.mint(uniPool, -10, 10, 10 ** 18);
        changePrank(Alice);

        // tough luck... PLPs just stole ~2**64 tokens per liquidity Alice had because of an overflow
        // Alice can be frontrun if her transaction goes to a public mempool (or is otherwise anticipated),
        // so the cost of the attack is just ~2**64 * active liquidity (shown here to be as low as 1 even with initial full-range!)
        // + fee to move price initially (if applicable)
        // The solution is to wrap around the overflow once (so if the accumulator goes down, the fees are acc_current + (acc_max - acc_prev)
        // If it overflows multiple times, we leave some fees unclaimed, but that's fine. Can't be exploited.
        pp.burnOptions(tokenId, new uint256[](0), 0, 0);

        // make sure Alice is credited (not debited!) a reasonable amount of fees
        assertEq(int256(ct0.convertToAssets(ct0.balanceOf(Alice))) - int256(balanceBefore), 997570);
    }
}
