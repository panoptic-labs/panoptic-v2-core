// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {RiskEngineV2} from "@contracts/RiskEngine.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";
import {PanopticPoolV2} from "@contracts/PanopticPool.sol";
import {CollateralTrackerV2} from "@contracts/CollateralTracker.sol";
import {Constants} from "@libraries/Constants.sol";
import {Errors} from "@libraries/Errors.sol";
import {TokenId} from "@types/TokenId.sol";
import {LeftRightUnsigned, LeftRightSigned} from "@types/LeftRight.sol";
import {PositionBalance} from "@types/PositionBalance.sol";
import {RiskParameters} from "@types/RiskParameters.sol";
import {OraclePack} from "@types/OraclePack.sol";
import {RiskEngineParameters} from "@types/RiskEngineParameters.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {BuilderFactory} from "@contracts/Builder.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

interface ICreate3Deployer {
    function mint(address to, uint256 id, uint8 nonce) external;

    function deploy(uint256 id, bytes calldata initcode) external payable returns (address);
}

/// @notice Upgrades the live blue-chip RiskEngine proxy on a mainnet fork, underneath the live WETH/USDC 5bps
/// PanopticPool and the accounts that hold positions in it, with the implementation described by
/// build-config-RiskEngine-upgrade.json compiled from this working tree.
/// @dev Runs only when ETH_RPC_URL is set. The fork block is pinned so the live accounts below are reproducible;
/// bump FORK_BLOCK and the account list together before rehearsing a real upgrade:
///   ETH_RPC_URL=... forge test --match-path test/foundry/core/RiskEngineUpgradeFork.t.sol -vv
contract RiskEngineUpgradeForkTest is Test {
    /// @dev `maxTicksDelta` of the tier the live proxy runs and the configured upgrade keeps.
    int24 internal constant LIVE_MAX_TICKS_DELTA = 724;

    uint256 constant FORK_BLOCK = 26183434;

    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    string constant ARGS = ".logicContracts.RiskEngine.constructorArgs[0]";

    string constant RELEASE_INFO = "deployment-info-RiskEngine-upgrade.json";
    ICreate3Deployer constant CREATE3_DEPLOYER =
        ICreate3Deployer(0x000000000000b361194cfe6312EE3210d53C15AA);
    address constant DEPLOYER_SAFE = 0x82BF455e9ebd6a541EF10b683dE1edCaf05cE7A1;

    address constant PROXY = 0x000000000000ffE5eFdB5AE76b9200263C58b4c0;
    address constant OWNER_SAFE = 0x8DFEAA4AEe4596b90EF581d7731E4E0b7AbA3221;
    PanopticPoolV2 constant POOL = PanopticPoolV2(0x00000000000E98f6c5aE16835bAdF2f7cC0d49D7);

    IRiskEngine constant re = IRiskEngine(PROXY);
    ProxyAdmin proxyAdmin;
    CollateralTrackerV2 ct0; // USDC
    CollateralTrackerV2 ct1; // WETH
    IERC20Partial usdc;
    IERC20Partial weth;
    address liveImpl;

    /// @dev The implementation build-config-RiskEngine-upgrade.json describes, exactly as configured.
    RiskEngineV2 configured;
    /// @dev Same source, at the tier the live proxy runs today: the config with the cross buffers and the fee
    /// parameters the live proxy reports, and the buyer collateral ratio it was deployed with.
    RiskEngineV2 sameTier;

    /// @dev Buyer collateral ratio of the live implementation (1%). Not readable on-chain; the release raises it.
    /// Update this constant once that release is live.
    uint256 constant LIVE_BUYER_COLLATERAL_RATIO = 100_000;

    address[] accounts;
    mapping(address => TokenId[]) lists;

    address TRADER = makeAddr("TRADER");
    TokenId[] traderList;
    TokenId[] empty;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true); // fork rehearsal only runs when an RPC is supplied
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);

        liveImpl = address(uint160(uint256(vm.load(PROXY, IMPL_SLOT))));
        proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(PROXY, ADMIN_SLOT)))));
        assertGt(liveImpl.code.length, 0, "live implementation");
        assertEq(address(proxyAdmin), vm.computeCreateAddress(PROXY, 1), "ProxyAdmin derivation");
        assertEq(proxyAdmin.owner(), OWNER_SAFE, "ProxyAdmin owner");
        assertEq(address(POOL.riskEngine()), PROXY, "pool is bound to the proxy");

        ct0 = POOL.collateralToken0();
        ct1 = POOL.collateralToken1();
        usdc = IERC20Partial(ct0.asset());
        weth = IERC20Partial(ct1.asset());

        _loadLiveAccounts();
        _buildCandidates();
    }

    /// @dev Every account with open positions in the pool at FORK_BLOCK (from its OptionMinted/OptionBurnt logs).
    function _loadLiveAccounts() internal {
        _account(
            0x000DfeA7bC8F8219A726eAE62150851Dd5Bd9886,
            171273897115973071057901176080074057375847334621,
            85639054056468875284209578202130059046919652061
        );
        _account(
            0x2C5cdF59fF686249dd6D369b78fB7DaeF2D849d3,
            48173817541982046408123672704817223092263764701,
            49244261074203015505805464245085739699920749277
        );
        _account(
            0xe5CA19e832bA627a49FAaE73B4858c46Ccc01Ca3,
            608487254611252284883955374670557,
            304251110565921961490485895807709
        );
        _account(
            0x07e55E55d5995D623A5b3D223A510138e74FC257,
            2035741247030093594065266997838337688695924566285205570980240673958692700893,
            0
        );
    }

    function _account(address who, uint256 id0, uint256 id1) internal {
        accounts.push(who);
        lists[who].push(TokenId.wrap(id0));
        if (id1 != 0) lists[who].push(TokenId.wrap(id1));
        // reverts with InputListFail if the list is not exactly what the account holds
        POOL.validateCollateralWithdrawable(who, lists[who], false);
    }

    function _buildCandidates() internal {
        string memory cfg = vm.readFile("build-config-RiskEngine-upgrade.json");
        assertEq(
            vm.parseJsonAddress(cfg, ".upgrades[0].proxy"),
            PROXY,
            "config upgrades another proxy"
        );
        RiskEngineParameters memory p = _configuredParameters(cfg);
        configured = _deploy(cfg, p);

        // The config must carry the tier parameters the proxy was deployed with unless changing one is the point
        // of the upgrade; the cross buffers are the only ones readable on-chain, so pin them here and update this
        // check deliberately if a buffer change is ever intended.
        assertEq(
            p.crossBuffer0,
            re.CROSS_BUFFER_0(),
            "config crossBuffer0 differs from the live proxy"
        );
        assertEq(
            p.crossBuffer1,
            re.CROSS_BUFFER_1(),
            "config crossBuffer1 differs from the live proxy"
        );

        p.crossBuffer0 = re.CROSS_BUFFER_0();
        p.crossBuffer1 = re.CROSS_BUFFER_1();
        // parameters the release changes on purpose are put back to their live values, so that the `sameTier`
        // tests isolate what the new code does from what the new parameters do
        (RiskParameters live, ) = POOL.getRiskParameters(0);
        p.notionalFee = live.notionalFee();
        p.premiumFee = live.premiumFee();
        p.protocolSplit = live.protocolSplit();
        p.builderSplit = live.builderSplit();
        p.buyerCollateralRatio = LIVE_BUYER_COLLATERAL_RATIO;
        sameTier = _deploy(cfg, p);
    }

    function _deploy(
        string memory cfg,
        RiskEngineParameters memory p
    ) internal returns (RiskEngineV2) {
        return
            new RiskEngineV2(
                vm.parseJsonAddress(cfg, string.concat(ARGS, "[0]")),
                vm.parseJsonAddress(cfg, string.concat(ARGS, "[1]")),
                vm.parseJsonBytes32(cfg, string.concat(ARGS, "[2]")),
                p
            );
    }

    /// @dev The 22 tier parameters, in constructor order.
    function _configuredParameters(
        string memory cfg
    ) internal pure returns (RiskEngineParameters memory p) {
        uint256[] memory v = vm.parseJsonUintArray(cfg, string.concat(ARGS, "[3]"));
        require(v.length == 22, "tier parameter count");
        p.crossBuffer0 = v[0];
        p.crossBuffer1 = v[1];
        p.emaPeriods = uint96(v[2]);
        p.maxTicksDelta = int256(v[3]);
        p.maxClampDelta = int24(int256(v[4]));
        p.maxTwapDeltaDispatch = uint16(v[5]);
        p.maxSpread = uint24(v[6]);
        p.bpDecreaseBuffer = uint32(v[7]);
        p.sellerCollateralRatio = v[8];
        p.buyerCollateralRatio = v[9];
        p.maintMarginRate = v[10];
        p.loanMarginDivisor = v[11];
        p.forceExerciseCost = v[12];
        p.targetPoolUtil = v[13];
        p.saturatedPoolUtil = v[14];
        p.maxOpenLegs = v[15];
        p.maxBonus = v[16];
        p.notionalFee = uint16(v[17]);
        p.premiumFee = uint16(v[18]);
        p.protocolSplit = uint16(v[19]);
        p.builderSplit = uint16(v[20]);
        p.minRateAtTarget = int256(v[21]);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev The real batch accrues both trackers first (`test_fork_upgradeBatch_accruesTrackersBeforeUpgrade`);
    /// this helper does not, so the before/after comparisons in the other tests see only the engine change.
    function _upgrade(address newImpl) internal {
        vm.prank(OWNER_SAFE);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(PROXY), newImpl, "");
        assertEq(
            address(uint160(uint256(vm.load(PROXY, IMPL_SLOT)))),
            newImpl,
            "implementation slot"
        );
    }

    function _limits() internal pure returns (int24[3][] memory limits) {
        limits = new int24[3][](1);
        limits[0] = [Constants.MIN_POOL_TICK, Constants.MAX_POOL_TICK, int24(8388607)];
    }

    function _one(TokenId id) internal pure returns (TokenId[] memory list) {
        list = new TokenId[](1);
        list[0] = id;
    }

    /// @dev Pool-wide engine outputs, read through the proxy from the pool's live oracle pack and market state.
    function _poolView() internal view returns (bytes memory out) {
        (RiskParameters rp, ) = POOL.getRiskParameters(0);
        (
            int24 currentTick,
            int24 spotTick,
            int24 medianTick,
            int24 latestTick,
            OraclePack pack
        ) = POOL.getOracleTicks();
        out = abi.encode(rp, currentTick, spotTick, medianTick, latestTick, pack);
        out = bytes.concat(out, _oracleView(currentTick, pack));
        out = bytes.concat(
            out,
            abi.encode(ct0.interestRate(), ct1.interestRate(), POOL.isSafeMode(), POOL.getTWAP()),
            abi.encode(re.vegoid(), re.DECIMALS(), re.GUARDIAN(), re.BUILDER_FACTORY()),
            _feeRecipients(PROXY),
            _crossBufferView()
        );
    }

    function _crossBufferView() internal view returns (bytes memory out) {
        out = abi.encode(re.CROSS_BUFFER_0(), re.CROSS_BUFFER_1());
        int256[6] memory utilizations = [int256(0), 5_000, 9_000, 9_250, 9_500, 10_000];
        for (uint256 i; i < utilizations.length; ++i)
            out = bytes.concat(
                out,
                abi.encode(
                    re.crossBufferRatio(utilizations[i], re.CROSS_BUFFER_0()),
                    re.crossBufferRatio(utilizations[i], re.CROSS_BUFFER_1())
                )
            );
    }

    /// @dev Builder fee routing as `engine` reports it: the answer (or the revert) for the first builder codes,
    /// plus up to three codes whose wallet the live BuilderFactory has actually deployed.
    function _feeRecipients(address engine) internal view returns (bytes memory out) {
        BuilderFactory factory = BuilderFactory(re.BUILDER_FACTORY());
        uint256 deployed;
        for (uint256 code; code < 200 && deployed < 3; ++code) {
            bool live = code != 0 && factory.predictBuilderWallet(uint48(code)).code.length != 0;
            if (live) ++deployed;
            if (code >= 4 && !live) continue;
            (bool ok, bytes memory ret) = engine.staticcall(
                abi.encodeCall(IRiskEngine.getFeeRecipient, (code))
            );
            if (live) require(ok, "deployed builder wallet rejected");
            out = bytes.concat(out, abi.encode(code, ok, ret));
        }
    }

    function _oracleView(
        int24 currentTick,
        OraclePack pack
    ) internal view returns (bytes memory out) {
        {
            (int24[] memory solvencyTicks, OraclePack p0) = re.getSolvencyTicks(
                currentTick,
                pack,
                0
            );
            out = abi.encode(solvencyTicks, p0);
        }
        {
            (int24 median, OraclePack p1) = re.computeInternalMedian(pack, currentTick);
            (int24 moved, OraclePack p2) = re.computeInternalMedian(pack, currentTick + 400);
            out = bytes.concat(out, abi.encode(median, p1, moved, p2));
        }
        // probes a large shock at the highest deviation that is still not severe: above it the engine adds the
        // severe-shock level, pinned by test_fork_upgradeAtLiveTier_severeShockAddsTwoAboveTwiceTheDelta
        (int24 spotEMA, , , , ) = pack.getEMAs();
        out = bytes.concat(
            out,
            abi.encode(
                re.twapEMA(pack),
                re.isSafeMode(currentTick, pack),
                re.isSafeMode(spotEMA + 2 * LIVE_MAX_TICKS_DELTA, pack)
            )
        );
    }

    /// @dev Margin, solvency and per-position requirements of one live account at five ticks around spot.
    function _marginView(address who) internal view returns (bytes memory out) {
        TokenId[] memory list = lists[who];
        (
            LeftRightUnsigned shortPremium,
            LeftRightUnsigned longPremium,
            PositionBalance[] memory balances,
            LeftRightUnsigned[] memory requirements,

        ) = POOL.getFullPositionsData(who, true, list);
        out = abi.encode(shortPremium, longPremium, balances, requirements);

        int24 tick = POOL.getCurrentTick();
        int24[5] memory offsets = [int24(-2500), -400, 0, 400, 2500];
        for (uint256 i; i < offsets.length; ++i) {
            out = bytes.concat(
                out,
                _marginAt(who, list, balances, shortPremium, longPremium, tick + offsets[i]),
                abi.encode(
                    _health(who, list, balances, shortPremium, longPremium, tick + offsets[i])
                ),
                abi.encode(
                    re.getPerPositionCollateralRequirements(balances, list, tick + offsets[i])
                )
            );
        }
    }

    function _marginAt(
        address who,
        TokenId[] memory list,
        PositionBalance[] memory balances,
        LeftRightUnsigned shortPremium,
        LeftRightUnsigned longPremium,
        int24 atTick
    ) internal view returns (bytes memory) {
        // raw calls keep the two nine-argument engine calls off this frame's stack
        (bool ok0, bytes memory margin) = PROXY.staticcall(
            abi.encodeCall(
                IRiskEngine.getMargin,
                (balances, atTick, who, list, shortPremium, longPremium, ct0, ct1)
            )
        );
        (bool ok1, bytes memory solvent) = PROXY.staticcall(
            abi.encodeCall(
                IRiskEngine.isAccountSolvent,
                (balances, list, atTick, who, shortPremium, longPremium, ct0, ct1, 10_000_000)
            )
        );
        require(ok0 && ok1, "engine view reverted");
        return bytes.concat(margin, solvent);
    }

    /// @dev The account's health at `atTick`: the largest requirement multiplier (scaled by DECIMALS) at which the
    /// engine still calls it solvent. One number that moves with every input to the solvency check: balances,
    /// requirements, premia, interest and the cross-collateral buffers.
    function _health(
        address who,
        TokenId[] memory list,
        PositionBalance[] memory balances,
        LeftRightUnsigned shortPremium,
        LeftRightUnsigned longPremium,
        int24 atTick
    ) internal view returns (uint256 lo) {
        uint256 hi = 1e12;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            (bool ok, bytes memory solvent) = PROXY.staticcall(
                abi.encodeCall(
                    IRiskEngine.isAccountSolvent,
                    (balances, list, atTick, who, shortPremium, longPremium, ct0, ct1, mid)
                )
            );
            require(ok, "engine view reverted");
            if (abi.decode(solvent, (bool))) lo = mid;
            else hi = mid - 1;
        }
    }

    /// @dev Force-exercise cost of every position of one live account, at spot and with the oracle 300 ticks away.
    function _exerciseView(address who) internal view returns (bytes memory out) {
        TokenId[] memory list = lists[who];
        (, , PositionBalance[] memory balances, , ) = POOL.getFullPositionsData(who, true, list);
        int24 tick = POOL.getCurrentTick();
        for (uint256 i; i < list.length; ++i) {
            out = bytes.concat(
                out,
                abi.encode(
                    re.exerciseCost(tick, tick, list[i], balances[i]),
                    re.exerciseCost(tick, tick - 300, list[i], balances[i]),
                    re.exerciseCost(tick, tick + 300, list[i], balances[i])
                )
            );
        }
    }

    /// @dev Whether the account passes the pool's own solvency check (with the withdrawal buffer) right now.
    function _passesPoolSolvency(address who) internal view returns (bool ok) {
        try POOL.validateCollateralWithdrawable(who, lists[who], false) {
            ok = true;
        } catch {}
    }

    /// @dev What happens when an account closes its whole book in kind: did it go through, and with what
    /// collateral and wallet balances. State is rolled back afterwards.
    function _closeOutcome(address who) internal returns (bytes memory out) {
        uint256 snap = vm.snapshotState();
        TokenId[] memory list = lists[who];
        int24[3][] memory limits = new int24[3][](list.length);
        for (uint256 i; i < list.length; ++i)
            limits[i] = [Constants.MIN_POOL_TICK, Constants.MAX_POOL_TICK, int24(8388607)];

        vm.prank(who);
        try POOL.dispatch(list, empty, new uint128[](list.length), limits, false, 0) {
            out = abi.encode(
                true,
                ct0.balanceOf(who),
                ct1.balanceOf(who),
                usdc.balanceOf(who),
                weth.balanceOf(who),
                ct0.totalAssets(),
                ct1.totalAssets()
            );
        } catch (bytes memory reason) {
            out = abi.encode(false, reason);
        }
        vm.revertToState(snap);
    }

    /*//////////////////////////////////////////////////////////////
                         CONFIG vs LIVE DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev What must never change on a live proxy, checked on the implementation the config would deploy.
    function test_fork_configuredImplementation_preservesProxyInvariants() public view {
        // tier parameters may change in an upgrade; logged for the record, not asserted
        console2.log("live   CROSS_BUFFER_0/1", re.CROSS_BUFFER_0(), re.CROSS_BUFFER_1());
        console2.log(
            "config CROSS_BUFFER_0/1",
            configured.CROSS_BUFFER_0(),
            configured.CROSS_BUFFER_1()
        );
        assertEq(configured.vegoid(), re.vegoid(), "vegoid is baked into every pool id");
        assertEq(uint8(POOL.poolId() >> 40), configured.vegoid(), "pool id vegoid");
        assertEq(configured.GUARDIAN(), re.GUARDIAN(), "guardian");
        assertEq(configured.BUILDER_FACTORY(), re.BUILDER_FACTORY(), "builder factory");
        assertEq(configured.DECIMALS(), re.DECIMALS(), "DECIMALS");
        assertEq(
            keccak256(_feeRecipients(address(configured))),
            keccak256(_feeRecipients(PROXY)),
            "builder wallet derivation"
        );

        // emaPeriods is not exposed: the same stored oracle pack must be read and advanced identically
        (int24 currentTick, , , , OraclePack pack) = POOL.getOracleTicks();
        (int24 m0, OraclePack p0) = configured.computeInternalMedian(pack, currentTick + 250);
        (int24 m1, OraclePack p1) = re.computeInternalMedian(pack, currentTick + 250);
        assertEq(m0, m1, "median from the live oracle pack");
        assertEq(OraclePack.unwrap(p0), OraclePack.unwrap(p1), "emaPeriods changed");
    }

    /*//////////////////////////////////////////////////////////////
                  UPGRADE UNDER THE LIVE POOL AND ACCOUNTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Oracle, safe mode, risk parameters, interest rates and builder routing read by the live pool must be
    /// bit-identical after moving to this working tree's implementation at the live tier parameters.
    function test_fork_upgradeAtLiveTier_poolWideOutputsUnchanged() public {
        bytes32 before = keccak256(_poolView());
        _upgrade(address(sameTier));
        assertEq(keccak256(_poolView()), before, "pool-wide engine outputs changed");
    }

    /// @dev The Safe batch calls `accrueInterest()` on both trackers right before `upgradeAndCall`
    /// (`gen_upgrade_safetx.py`, `upgrades[].pools`), so the idle interval since each tracker's last interaction is
    /// compounded at the rate of the engine that was live during it, not at the new engine's. Pinned here: after a
    /// day idle, the batch leaves the trackers exactly where accruing on the live engine alone leaves them, and the
    /// new engine finds nothing left to re-price in the upgrade block.
    function test_fork_upgradeBatch_accruesTrackersBeforeUpgrade() public {
        vm.warp(block.timestamp + 1 days);
        uint256 idle0 = ct0.totalAssets();
        uint256 idle1 = ct1.totalAssets();

        // reference: the live engine prices the idle day
        uint256 snap = vm.snapshotState();
        ct0.accrueInterest();
        ct1.accrueInterest();
        uint256 live0 = ct0.totalAssets();
        uint256 live1 = ct1.totalAssets();
        vm.revertToState(snap);
        assertGt(live0, idle0, "setup: the idle day accrues interest in ct0");
        assertGt(live1, idle1, "setup: the idle day accrues interest in ct1");

        // the batch: accrue both trackers, then upgrade, in one block
        ct0.accrueInterest();
        ct1.accrueInterest();
        _upgrade(address(configured));
        assertEq(
            ct0.totalAssets(),
            live0,
            "batch accrual priced ct0's idle day on the live engine"
        );
        assertEq(
            ct1.totalAssets(),
            live1,
            "batch accrual priced ct1's idle day on the live engine"
        );

        ct0.accrueInterest();
        ct1.accrueInterest();
        assertEq(ct0.totalAssets(), live0, "nothing left for the new engine to re-price in ct0");
        assertEq(ct1.totalAssets(), live1, "nothing left for the new engine to re-price in ct1");
    }

    /// @dev The one intended change to the oracle view: a spot deviation beyond twice the delta adds 2 to the safe
    /// mode level, in either direction, and a deviation of exactly twice the delta changes nothing.
    function test_fork_upgradeAtLiveTier_severeShockAddsTwoAboveTwiceTheDelta() public {
        (, , , , OraclePack pack) = POOL.getOracleTicks();
        (int24 spotEMA, , , , ) = pack.getEMAs();
        int24 severe = 2 * LIVE_MAX_TICKS_DELTA;

        uint8 edgeUp = re.isSafeMode(spotEMA + severe, pack);
        uint8 edgeDown = re.isSafeMode(spotEMA - severe, pack);
        uint8 pastUp = re.isSafeMode(spotEMA + severe + 1, pack);
        uint8 pastDown = re.isSafeMode(spotEMA - severe - 1, pack);

        _upgrade(address(sameTier));

        assertEq(re.isSafeMode(spotEMA + severe, pack), edgeUp, "at the edge, up: unchanged");
        assertEq(re.isSafeMode(spotEMA - severe, pack), edgeDown, "at the edge, down: unchanged");
        assertEq(re.isSafeMode(spotEMA + severe + 1, pack), pastUp + 2, "past the edge, up: +2");
        assertEq(
            re.isSafeMode(spotEMA - severe - 1, pack),
            pastDown + 2,
            "past the edge, down: +2"
        );
        assertGe(re.isSafeMode(spotEMA + severe + 1, pack), 3, "severe shock blocks new positions");
    }

    /// @dev Margin of every live account before and after. Any account listed as changed here is one whose
    /// collateral requirement moves the moment the upgrade lands.
    function test_fork_upgradeAtLiveTier_liveAccountMarginsUnchanged() public {
        bytes32[] memory before = new bytes32[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) before[i] = keccak256(_marginView(accounts[i]));

        _upgrade(address(sameTier));

        for (uint256 i; i < accounts.length; ++i)
            assertEq(
                keccak256(_marginView(accounts[i])),
                before[i],
                string.concat("margin changed for ", vm.toString(accounts[i]))
            );
    }

    /// @dev No live account may flip between solvent and insolvent because of the upgrade, with either candidate.
    /// Logs each account's health (100% = exactly at its requirement) on the live engine and on both candidates.
    function test_fork_upgrade_noLiveAccountChangesSolvency() public {
        bool[] memory before = new bool[](accounts.length);
        uint256[] memory healthBefore = new uint256[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) {
            before[i] = _passesPoolSolvency(accounts[i]);
            healthBefore[i] = _healthNow(accounts[i]);
        }

        uint256 snap = vm.snapshotState();
        _upgrade(address(sameTier));
        for (uint256 i; i < accounts.length; ++i) {
            assertEq(
                _passesPoolSolvency(accounts[i]),
                before[i],
                string.concat("live-tier upgrade flips ", vm.toString(accounts[i]))
            );
            assertEq(
                _healthNow(accounts[i]),
                healthBefore[i],
                string.concat("live-tier upgrade moves the health of ", vm.toString(accounts[i]))
            );
        }
        vm.revertToState(snap);

        _upgrade(address(configured));
        for (uint256 i; i < accounts.length; ++i) {
            console2.log(accounts[i], before[i] ? "passes the pool solvency check" : "FAILS it");
            emit log_named_decimal_uint("  health, live engine    (%)", healthBefore[i], 5);
            emit log_named_decimal_uint("  health, as configured  (%)", _healthNow(accounts[i]), 5);
            assertEq(
                _passesPoolSolvency(accounts[i]),
                before[i],
                string.concat("configured upgrade flips ", vm.toString(accounts[i]))
            );
        }
    }

    function _healthNow(address who) internal view returns (uint256) {
        TokenId[] memory list = lists[who];
        (
            LeftRightUnsigned shortPremium,
            LeftRightUnsigned longPremium,
            PositionBalance[] memory balances,
            ,

        ) = POOL.getFullPositionsData(who, true, list);
        return _health(who, list, balances, shortPremium, longPremium, POOL.getCurrentTick());
    }

    /// @dev Each live account closing its whole book in kind gets the same result (success or the same revert,
    /// and the same balances) before and after the upgrade.
    function test_fork_upgradeAtLiveTier_liveAccountsCloseIdentically() public {
        bytes32[] memory before = new bytes32[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) {
            bytes memory outcome = _closeOutcome(accounts[i]);
            before[i] = keccak256(outcome);
            if (abi.decode(outcome, (bool))) {
                console2.log(accounts[i], "closes in kind");
            } else {
                (, bytes memory reason) = abi.decode(outcome, (bool, bytes));
                console2.log(accounts[i], "cannot close in kind, reverts with selector:");
                console2.logBytes4(bytes4(reason));
            }
        }

        _upgrade(address(sameTier));

        for (uint256 i; i < accounts.length; ++i)
            assertEq(
                keccak256(_closeOutcome(accounts[i])),
                before[i],
                string.concat("close outcome changed for ", vm.toString(accounts[i]))
            );
    }

    /// @dev The force-exercise fee is the one engine output this branch changes on purpose (cheapest long leg
    /// only). Reports the fee of every live position before and after; positions with at most one long leg must
    /// be unaffected.
    function test_fork_upgradeAtLiveTier_exerciseCostOnlyChangesForMultiLongPositions() public {
        bytes32[] memory before = new bytes32[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) before[i] = keccak256(_exerciseView(accounts[i]));

        _upgrade(address(sameTier));

        for (uint256 i; i < accounts.length; ++i) {
            bool changed = keccak256(_exerciseView(accounts[i])) != before[i];
            bool hasMultiLong;
            TokenId[] memory list = lists[accounts[i]];
            for (uint256 j; j < list.length; ++j)
                if (_wideLongLegs(list[j]) > 1) hasMultiLong = true;
            console2.log(accounts[i], "exercise cost changed:", changed);
            if (!hasMultiLong)
                assertFalse(
                    changed,
                    string.concat("exercise cost changed for ", vm.toString(accounts[i]))
                );
        }
    }

    function _wideLongLegs(TokenId id) internal pure returns (uint256 n) {
        for (uint256 leg; leg < id.countLegs(); ++leg)
            if (id.isLong(leg) == 1 && id.width(leg) != 0) ++n;
    }

    /*//////////////////////////////////////////////////////////////
               THE CHANGES THIS BRANCH MAKES, ON THE LIVE POOL
    //////////////////////////////////////////////////////////////*/

    /// @dev No live position has two long legs, so the fee change is exercised here with one opened on the live
    /// pool before the upgrade. Old engine: the fees of both long legs are summed. New engine: only the cheapest
    /// leg (valued at the oracle tick) is charged; both legs here are 400 ticks wide, the in-range leg carries
    /// extrinsic value and the far leg pays only the notional-fee floor, so the far leg's fee is charged and the
    /// in-range leg is free. The position is then force-exercised for real on the new implementation.
    function test_fork_upgradeAtLiveTier_twoLongLegsPayCheapestLegOnly() public {
        address MAKER = makeAddr("MAKER");
        address KEEPER = makeAddr("KEEPER");
        _deposit(MAKER, 500_000e6, 200e18);
        _deposit(TRADER, 100_000e6, 50e18);
        _deposit(KEEPER, 100_000e6, 50e18);

        // two put chunks, 400 ticks wide: one around spot (rich in extrinsic value), one 3,000 ticks below
        int24 atm = (POOL.getCurrentTick() / 10) * 10;
        TokenId longs = _twoPuts(atm, 1);
        _dispatchAs(MAKER, _twoPuts(atm, 0), 4e18, _one(_twoPuts(atm, 0)));
        _dispatchAs(TRADER, longs, 1e18, _one(longs));

        TokenId base = TokenId.wrap(0).addPoolId(POOL.poolId());
        int256 nearAlone = _exerciseFee(base.addLeg(0, 1, 1, 1, 1, 0, atm, 40), longs);
        int256 farAlone = _exerciseFee(base.addLeg(0, 1, 1, 1, 1, 0, atm - 3000, 40), longs);
        int256 feeLive = _exerciseFee(longs, longs);
        assertLt(nearAlone, farAlone, "the in-range leg is the expensive one");
        assertEq(feeLive, nearAlone + farAlone, "live engine sums the two legs");

        _upgrade(address(sameTier));

        int256 feeNew = _exerciseFee(longs, longs);
        assertEq(feeNew, farAlone, "new engine charges the cheapest of the two legs only");
        assertGt(feeNew, feeLive, "cheaper than the live engine's sum (fees are negative)");
        emit log_named_decimal_int("exercise fee, live engine (WETH)", feeLive, 18);
        emit log_named_decimal_int("exercise fee, this branch (WETH)", feeNew, 18);

        // and the exercise itself goes through on the live pool
        uint256 traderBefore = ct1.convertToAssets(ct1.balanceOf(TRADER));
        vm.prank(KEEPER);
        POOL.dispatchFrom(
            empty,
            TRADER,
            _one(longs),
            empty,
            LeftRightUnsigned.wrap(0).addToRightSlot(1).addToLeftSlot(1)
        );
        assertEq(POOL.numberOfLegs(TRADER), 0, "exercised");
        assertGt(
            ct1.convertToAssets(ct1.balanceOf(TRADER)),
            traderBefore,
            "exercisee was not paid"
        );
    }

    function _twoPuts(int24 atm, uint256 isLong) internal view returns (TokenId id) {
        id = TokenId.wrap(0).addPoolId(POOL.poolId());
        id = id.addLeg(0, 1, 1, isLong, 1, 0, atm, 40);
        id = id.addLeg(1, 1, 1, isLong, 1, 1, atm - 3000, 40);
    }

    /// @dev Fee in WETH for force-exercising `id` at the size TRADER holds `held` in, with current == oracle so
    /// there is no composition delta (negative = paid by the exercisor).
    function _exerciseFee(TokenId id, TokenId held) internal view returns (int256) {
        (, , PositionBalance[] memory balances, , ) = POOL.getFullPositionsData(
            TRADER,
            true,
            _one(held)
        );
        int24 tick = POOL.getCurrentTick();
        LeftRightSigned fee = re.exerciseCost(tick, tick, id, balances[0]);
        assertEq(fee.rightSlot(), 0, "puts on WETH are charged in WETH only");
        return fee.leftSlot();
    }

    /// @dev No live account holds a loan and a credit in the same token, so the re-margin change is exercised here
    /// with one opened on the live pool before the upgrade. Old engine: the credit counts as collateral and requires
    /// nothing. New engine: it still counts as collateral but is charged in full as a requirement while the account
    /// has a loan in that token, so the loan margin must be real deposits and the account's health drops.
    function test_fork_upgradeAtLiveTier_creditRemarginedNextToLoanInSameToken() public {
        _deposit(TRADER, 50_000e6, 20e18);

        int24 atm = (POOL.getCurrentTick() / 10) * 10;
        TokenId base = TokenId.wrap(0).addPoolId(POOL.poolId());
        TokenId loan = base.addLeg(0, 1, 0, 0, 0, 0, atm, 0);
        TokenId credit = base.addLeg(0, 1, 0, 1, 0, 0, atm, 0);
        traderList.push(loan);
        _dispatchAs(TRADER, loan, 20_000e6, traderList);
        traderList.push(credit);
        _dispatchAs(TRADER, credit, 15_000e6, traderList);

        accounts.push(TRADER);
        lists[TRADER] = traderList;
        (uint256 balance0, uint256 required0, bytes32 token1) = _marginNow(TRADER);
        uint256 healthBefore = _healthNow(TRADER);

        _upgrade(address(sameTier));

        (uint256 balance0After, uint256 required0After, bytes32 token1After) = _marginNow(TRADER);
        assertEq(balance0After, balance0, "the 15,000 USDC credit still counts as balance");
        assertEq(
            required0After - required0,
            15_000e6,
            "the 15,000 USDC credit is charged in full as a requirement"
        );
        assertEq(token1After, token1, "WETH side moved");
        assertLt(_healthNow(TRADER), healthBefore, "health did not drop");
        emit log_named_decimal_uint("loan+credit health, live engine (%)", healthBefore, 5);
        emit log_named_decimal_uint("loan+credit health, this branch (%)", _healthNow(TRADER), 5);

        // the account can still unwind: credit first, then the loan
        _dispatchAs(TRADER, credit, 0, _one(loan));
        _dispatchAs(TRADER, loan, 0, empty);
        assertEq(POOL.numberOfLegs(TRADER), 0, "unwound");
    }

    function _marginNow(
        address who
    ) internal view returns (uint256 balance0, uint256 required0, bytes32 token1) {
        TokenId[] memory list = lists[who];
        (
            LeftRightUnsigned shortPremium,
            LeftRightUnsigned longPremium,
            PositionBalance[] memory balances,
            ,

        ) = POOL.getFullPositionsData(who, true, list);
        (bool ok, bytes memory margin) = PROXY.staticcall(
            abi.encodeCall(
                IRiskEngine.getMargin,
                (balances, POOL.getCurrentTick(), who, list, shortPremium, longPremium, ct0, ct1)
            )
        );
        require(ok, "engine view reverted");
        (LeftRightUnsigned data0, LeftRightUnsigned data1, ) = abi.decode(
            margin,
            (LeftRightUnsigned, LeftRightUnsigned, PositionBalance)
        );
        return (data0.rightSlot(), data0.leftSlot(), keccak256(abi.encode(data1)));
    }

    function _deposit(address who, uint256 amount0, uint256 amount1) internal {
        deal(address(usdc), who, amount0);
        deal(address(weth), who, amount1);
        vm.startPrank(who);
        usdc.approve(address(ct0), type(uint256).max);
        weth.approve(address(ct1), type(uint256).max);
        ct0.deposit(amount0, who);
        ct1.deposit(amount1, who);
        vm.stopPrank();
    }

    /// @dev Mint (`size != 0`) or burn (`size == 0`) one position in kind, leaving `finalList` open.
    function _dispatchAs(
        address who,
        TokenId id,
        uint128 size,
        TokenId[] memory finalList
    ) internal {
        uint128[] memory sizes = new uint128[](1);
        sizes[0] = size;
        vm.prank(who);
        POOL.dispatch(_one(id), finalList, sizes, _limits(), false, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    TRADING ON THE LIVE POOL AFTER IT
    //////////////////////////////////////////////////////////////*/

    /// @dev A fresh account deposits, sells, borrows, lets interest accrue, closes and withdraws everything on
    /// the live pool after the configured implementation is in place.
    function test_fork_upgradeConfigured_newAccountFullLifecycle() public {
        _upgrade(address(configured));

        deal(address(usdc), TRADER, 200_000e6);
        deal(address(weth), TRADER, 100e18);
        vm.startPrank(TRADER);
        usdc.approve(address(ct0), type(uint256).max);
        weth.approve(address(ct1), type(uint256).max);
        ct0.deposit(200_000e6, TRADER);
        ct1.deposit(100e18, TRADER);
        vm.stopPrank();

        int24 ts = POOL.tickSpacing();
        int24 atm = (POOL.getCurrentTick() / ts) * ts;
        TokenId base = TokenId.wrap(0).addPoolId(POOL.poolId());
        // 0.5 ETH short call 1,500 ticks above spot, 0.5 ETH short put 1,500 ticks below, 1,000 USDC loan
        TokenId shortCall = base.addLeg(0, 1, 1, 0, 0, 0, atm + 1500 * (ts / 10), 100);
        TokenId shortPut = base.addLeg(0, 1, 1, 0, 1, 0, atm - 1500 * (ts / 10), 100);
        TokenId loan = base.addLeg(0, 1, 0, 0, 0, 0, atm, 0);

        _mint(shortCall, 0.5e18);
        _mint(shortPut, 0.5e18);
        _mint(loan, 1_000e6);
        assertEq(POOL.numberOfLegs(TRADER), 3, "three positions open");
        POOL.validateCollateralWithdrawable(TRADER, traderList, false);

        vm.warp(block.timestamp + 6 hours);
        vm.roll(block.number + 1800);
        assertGt(
            ct0.previewOwedInterest(TRADER),
            0,
            "loan accrues interest on the new implementation"
        );

        _burn(loan);
        _burn(shortPut);
        _burn(shortCall);
        assertEq(POOL.numberOfLegs(TRADER), 0, "all closed");

        vm.startPrank(TRADER);
        ct0.redeem(ct0.maxRedeem(TRADER), TRADER, TRADER);
        ct1.redeem(ct1.maxRedeem(TRADER), TRADER, TRADER);
        vm.stopPrank();
        // commissions and interest only: the account gets back all but a sliver of what it put in
        assertGt(usdc.balanceOf(TRADER), 199_900e6, "USDC returned");
        assertGt(weth.balanceOf(TRADER), 99.95e18, "WETH returned");
    }

    function _mint(TokenId id, uint128 size) internal {
        traderList.push(id);
        uint128[] memory sizes = new uint128[](1);
        sizes[0] = size;
        vm.prank(TRADER);
        POOL.dispatch(_one(id), traderList, sizes, _limits(), false, 0);
    }

    function _burn(TokenId id) internal {
        for (uint256 i; i < traderList.length; ++i) {
            if (TokenId.unwrap(traderList[i]) == TokenId.unwrap(id)) {
                traderList[i] = traderList[traderList.length - 1];
                traderList.pop();
                break;
            }
        }
        vm.prank(TRADER);
        POOL.dispatch(_one(id), traderList, new uint128[](1), _limits(), false, 0);
    }

    /// @dev The live guardian keeps its powers over the live pool through the new implementation.
    function test_fork_upgradeConfigured_guardianCanStillLockAndUnlock() public {
        _upgrade(address(configured));
        address guardian = re.GUARDIAN();

        vm.prank(guardian);
        re.lockPool(POOL);
        assertGt(POOL.isSafeMode(), 1, "locked");

        vm.prank(guardian);
        re.unlockPool(POOL);
        assertLe(POOL.isSafeMode(), 1, "unlocked");

        vm.prank(OWNER_SAFE);
        vm.expectRevert(Errors.NotGuardian.selector);
        re.lockPool(POOL);
    }

    /*//////////////////////////////////////////////////////////////
                    THE BYTECODE THAT ACTUALLY SHIPS
    //////////////////////////////////////////////////////////////*/

    /// @dev Everything above runs an implementation compiled by this test run. The one that ships is built by
    /// build_release.py (release optimizer settings) and deployed through the CREATE3 deployer. Once
    /// deployment-info-RiskEngine-upgrade.json exists, this deploys that exact initcode as the deploying Safe,
    /// upgrades the live proxy to it, and requires it to behave identically to the test-compiled build for the
    /// pool and every live account. Skipped until the release has been built.
    function test_fork_releaseArtifact_behavesLikeThisSource() public {
        if (!vm.exists(RELEASE_INFO)) {
            vm.skip(true);
            return;
        }
        string memory info = vm.readFile(RELEASE_INFO);
        address expected = vm.parseJsonAddress(info, ".logicContracts[0].address");
        uint256 salt = uint256(vm.parseJsonBytes32(info, ".logicContracts[0].salt"));
        assertEq(expected.code.length, 0, "release slot already used at FORK_BLOCK");

        vm.startPrank(DEPLOYER_SAFE);
        CREATE3_DEPLOYER.mint(
            DEPLOYER_SAFE,
            salt,
            uint8(vm.parseJsonUint(info, ".logicContracts[0].nonce"))
        );
        CREATE3_DEPLOYER.deploy(salt, vm.parseJsonBytes(info, ".logicContracts[0].initcode"));
        vm.stopPrank();
        assertGt(expected.code.length, 0, "no code at the release address");
        assertLe(expected.code.length, 24_576, "EIP-170");

        uint256 snap = vm.snapshotState();
        _upgrade(address(configured));
        bytes32 want = _everything();
        vm.revertToState(snap);

        _upgrade(expected);
        assertEq(_everything(), want, "release bytecode behaves differently from this source");
    }

    function _everything() internal view returns (bytes32) {
        bytes memory out = _poolView();
        for (uint256 i; i < accounts.length; ++i)
            out = bytes.concat(out, _marginView(accounts[i]), _exerciseView(accounts[i]));
        return keccak256(out);
    }

    /*//////////////////////////////////////////////////////////////
                         AUTHORITY AND ROLLBACK
    //////////////////////////////////////////////////////////////*/

    function test_fork_onlyOwnerSafeCanUpgrade() public {
        address[3] memory callers = [re.GUARDIAN(), address(this), address(POOL)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i])
            );
            proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(PROXY), address(configured), "");
        }
        // the Safe itself cannot bypass its ProxyAdmin
        vm.prank(OWNER_SAFE);
        (bool ok, ) = PROXY.call(
            abi.encodeCall(ITransparentUpgradeableProxy.upgradeToAndCall, (address(configured), ""))
        );
        assertFalse(ok, "direct upgrade call went through");
        assertEq(address(uint160(uint256(vm.load(PROXY, IMPL_SLOT)))), liveImpl);
    }

    /// @dev Rolling back to the implementation that is live today restores every output for the pool and the
    /// live accounts.
    function test_fork_rollbackToLiveImplementation_restoresEverything() public {
        bytes32 poolBefore = keccak256(_poolView());
        bytes32[] memory before = new bytes32[](accounts.length);
        for (uint256 i; i < accounts.length; ++i)
            before[i] = keccak256(
                bytes.concat(_marginView(accounts[i]), _exerciseView(accounts[i]))
            );

        _upgrade(address(configured));
        _upgrade(liveImpl);

        assertEq(keccak256(_poolView()), poolBefore, "pool-wide outputs after rollback");
        for (uint256 i; i < accounts.length; ++i)
            assertEq(
                keccak256(bytes.concat(_marginView(accounts[i]), _exerciseView(accounts[i]))),
                before[i],
                string.concat("rollback did not restore ", vm.toString(accounts[i]))
            );
    }

    /// @dev The --timelock path of gen_upgrade_safetx.py on the live ProxyAdmin: the Safe hands ownership to a
    /// TimelockController, schedules the upgrade, and can only execute it after the delay.
    function test_fork_timelockedUpgradeOfLiveProxy() public {
        address[] memory safe = new address[](1);
        safe[0] = OWNER_SAFE;
        TimelockController timelock = new TimelockController(2 days, safe, safe, address(0));

        vm.prank(OWNER_SAFE);
        proxyAdmin.transferOwnership(address(timelock));

        address[] memory targets = new address[](1);
        targets[0] = address(proxyAdmin);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(PROXY), address(configured), "")
        );

        vm.startPrank(OWNER_SAFE);
        timelock.scheduleBatch(targets, new uint256[](1), payloads, 0, 0, 2 days);
        vm.expectRevert();
        timelock.executeBatch(targets, new uint256[](1), payloads, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER_SAFE)
        );
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(PROXY), address(configured), "");
        vm.stopPrank();
        assertEq(address(uint160(uint256(vm.load(PROXY, IMPL_SLOT)))), liveImpl, "not yet");

        vm.warp(block.timestamp + 2 days);
        vm.prank(OWNER_SAFE);
        timelock.executeBatch(targets, new uint256[](1), payloads, 0, 0);
        assertEq(
            address(uint160(uint256(vm.load(PROXY, IMPL_SLOT)))),
            address(configured),
            "upgraded through the timelock"
        );
        assertEq(re.CROSS_BUFFER_0(), configured.CROSS_BUFFER_0());
    }
}
