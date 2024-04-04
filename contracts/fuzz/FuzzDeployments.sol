// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

//import {SetupTokens, SetupUniswap} from "./UniDeployments.sol";
import {WETH9} from "./fuzz-mocks/WETH9.sol";

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {IDonorNFT} from "@tokens/interfaces/IDonorNFT.sol";
import {DonorNFT} from "@periphery/DonorNFT.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {IUniswapV3Factory} from "univ3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";

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

contract FuzzDeployments {
    event LogAddr(address);

    IUniswapV3Pool constant USDC_WETH_5 =
        IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IHevm hevm = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    /*SetupTokens tokens;
    SetupUniswap uniswap;*/
    SemiFungiblePositionManager sfpm;
    IUniswapV3Factory univ3factory;
    address poolReference;
    address collateralReference;
    IDonorNFT dnft;
    PanopticFactory factory;

    constructor() {
        /*tokens = new SetupTokens();
        uniswap = new SetupUniswap(tokens.token0(), tokens.token1());*/

        // See if mock or new deploy
        univ3factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

        sfpm = new SemiFungiblePositionManager(univ3factory);

        // Import the Panoptic Pool reference (for cloning)
        poolReference = address(new PanopticPool(sfpm));

        // Import the Collateral Tracker reference (for cloning)
        collateralReference = address(
            new CollateralTracker(10, 2_000, 1_000, -1_024, 5_000, 9_000, 20_000)
        );

        dnft = IDonorNFT(address(new DonorNFT()));
        factory = new PanopticFactory(
            address(WETH),
            sfpm,
            univ3factory,
            dnft,
            poolReference,
            collateralReference
        );

        factory.initialize(address(this));
        DonorNFT(address(dnft)).changeFactory(address(factory));

        initialize();
    }

    function deal_USDC(address to, uint256 amt) public {
        // Balances in slot 9 (verify with "slither --print variable-order 0x43506849D7C04F9138D1A2050bbF3A0c054402dd")
        hevm.store(address(USDC), keccak256(abi.encode(address(to), uint256(9))), bytes32(amt));
    }

    function deal_WETH(address to, uint256 amt) public {
        // Balances in slot 3 (verify with "slither --print variable-order 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")
        hevm.store(address(WETH), keccak256(abi.encode(address(to), uint256(3))), bytes32(amt));
    }

    function initialize() internal {
        // initalize current pool we are deploying
        IUniswapV3Pool pool = USDC_WETH_5;
        uint24 fee = pool.fee();
        int24 tickSpacing = pool.tickSpacing();

        assert(pool.token0() == address(USDC));
        assert(pool.token1() == address(WETH));

        // give test contract a sufficient amount of tokens to deploy a new pool
        deal_USDC(address(this), 100 ether);
        deal_WETH(address(this), 100 ether);

        assert(USDC.balanceOf(address(this)) == 100 ether);
        assert(WETH.balanceOf(address(this)) == 100 ether);

        // approve factory to move tokens, on behalf of the test contract
        USDC.approve(address(factory), type(uint256).max);
        WETH.approve(address(factory), type(uint256).max);

        // approve sfpm to move tokens, on behalf of the test contract
        USDC.approve(address(sfpm), type(uint256).max);
        WETH.approve(address(sfpm), type(uint256).max);

        // approve self
        USDC.approve(address(this), type(uint256).max);
        WETH.approve(address(this), type(uint256).max);
    }
}
