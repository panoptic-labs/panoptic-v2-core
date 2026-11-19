// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";
import {PanopticPoolV2} from "@contracts/PanopticPool.sol";
import {CollateralTrackerV2} from "@contracts/CollateralTracker.sol";
import {Constants} from "@libraries/Constants.sol";
import {TokenId} from "@types/TokenId.sol";
import {LeftRightUnsigned} from "@types/LeftRight.sol";
import {PositionBalance} from "@types/PositionBalance.sol";
import {RiskParameters} from "@types/RiskParameters.sol";
import {OraclePack} from "@types/OraclePack.sol";
import {IERC20Partial} from "@tokens/interfaces/IERC20Partial.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Math} from "@libraries/Math.sol";
import {V4RouterSimple} from "../testUtils/V4RouterSimple.sol";

/// @dev Moves a Uniswap v3 pool's price to a target, paying from its own balance.
contract PriceMoverV3 {
    function swapTo(IUniswapV3Pool pool, uint160 sqrtPriceX96) external {
        (uint160 current, , , , , , ) = pool.slot0();
        if (current == sqrtPriceX96) return;
        pool.swap(address(this), current > sqrtPriceX96, type(int128).max, sqrtPriceX96, "");
    }

    function uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
        if (amount0 > 0) IERC20Partial(pool.token0()).transfer(msg.sender, uint256(amount0));
        if (amount1 > 0) IERC20Partial(pool.token1()).transfer(msg.sender, uint256(amount1));
    }
}

/// @notice Dress rehearsal of the RiskEngine proxy upgrade with the artifacts that ship: the initcode written by
/// build_release.py and the Safe batch written by gen_upgrade_safetx.py, replayed on a mainnet fork at the block
/// the live account list was scanned at. Every account with open positions is then put through every operation
/// (close all, close each, settle, mint, withdraw, be force-exercised, be liquidated) on the live engine and on the
/// new one, and the outcomes are compared.
/// @dev Reads build-config-RiskEngine-upgrade.json and deployment-info-RiskEngine-upgrade.json, plus two files
/// derived from the chain and from the batches in safe-txns-upgrade/ (kept in safe-txns-upgrade-rehearsal/, not
/// tracked):
///   python3 script/upgrade-rehearsal/scan_live.py $RPC safe-txns-upgrade-rehearsal/live.json
///   python3 script/upgrade-rehearsal/raw_txs.py safe-txns-upgrade safe-txns-upgrade-rehearsal/raw-txs.json $RPC
/// The suite skips when they are missing. Run it with:
///   ETH_RPC_URL=... forge test --match-path test/foundry/core/RiskEngineUpgradeRehearsal.t.sol -vv
/// Another proxy or chain is rehearsed by pointing the suite at its build config and at a folder holding its
/// live.json and raw-txs.json (the pool may have its tokens in either order and any tick spacing):
///   REHEARSAL_CONFIG=build-config-RiskEngineXStocks-upgrade.json REHEARSAL_DIR=<folder>/ ETH_RPC_URL=...
/// With UPGRADED_RPC_URL set (an anvil the batch was really sent to, or mainnet after the upgrade) the fork is
/// taken from that node instead, the upgrade is expected to be in place, and only the tests that do not need the
/// old engine run.
contract RiskEngineUpgradeRehearsalTest is Test {
    /// @dev Folder holding live.json and raw-txs.json (env REHEARSAL_DIR).
    string DIR;
    /// @dev Build config of the upgrade (env REHEARSAL_CONFIG); the deployment-info file is the one next to it.
    string CONFIG;
    string RELEASE_INFO;
    /// @dev Name of the implementation in the config, `upgrades[0].implementation`.
    string IMPL_NAME;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /// @dev `upgrades[0].proxy` of the config, and the one pool live.json lists for it.
    address PROXY;
    PanopticPoolV2 POOL;
    IRiskEngine re;

    ProxyAdmin proxyAdmin;
    address ownerSafe;
    CollateralTrackerV2 ct0;
    CollateralTrackerV2 ct1;
    string sym0;
    string sym1;
    uint8 dec0;
    uint8 dec1;
    int24 ts;
    // the dollar side of the pool and the other side, whichever of them is token0 (USDC and WETH on the mainnet
    // pool, where the dollar is token0; USDG and SPY on the Robinhood chain pool, where it is token1)
    bool stableIs0;
    CollateralTrackerV2 ctS;
    CollateralTrackerV2 ctR;
    IERC20Partial stable;
    IERC20Partial risky;
    string symS;
    string symR;
    /// @dev One whole token of each side.
    uint256 S;
    uint256 R;

    address liveImpl;
    /// @dev The address the release initcode deploys to.
    address newImpl;
    /// @dev True when the fork already runs the new implementation.
    bool preUpgraded;
    string rawTxs;

    address[] accounts;
    mapping(address => TokenId[]) lists;
    uint256 totalPositions;

    address KEEPER = makeAddr("KEEPER");
    TokenId[] empty;

    // one entry per operation to compare: `actor` sends `data` to `target`, the result is read on `subject`
    address[] aActor;
    address[] aSubject;
    address[] aTarget;
    bytes[] aData;
    string[] aName;
    /// @dev How many times to cut the subject's collateral to a twentieth first (so that it is liquidatable).
    uint8[] aPrep;

    // steps of the fresh-account lifecycle
    string[] sName;
    bool[] sOk;
    bytes4[] sSel;
    mapping(address => TokenId[]) books;

    function setUp() public {
        DIR = vm.envOr("REHEARSAL_DIR", string("safe-txns-upgrade-rehearsal/"));
        CONFIG = vm.envOr("REHEARSAL_CONFIG", string("build-config-RiskEngine-upgrade.json"));
        RELEASE_INFO = vm.replace(CONFIG, "build-config", "deployment-info");
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        string memory upgraded = vm.envOr("UPGRADED_RPC_URL", string(""));
        bool inputs = vm.exists(string.concat(DIR, "live.json")) &&
            vm.exists(string.concat(DIR, "raw-txs.json")) &&
            vm.exists(CONFIG) &&
            vm.exists(RELEASE_INFO);
        if ((bytes(rpc).length == 0 && bytes(upgraded).length == 0) || !inputs) {
            vm.skip(true);
            return;
        }
        string memory live = vm.readFile(string.concat(DIR, "live.json"));
        PROXY = vm.parseJsonAddress(vm.readFile(CONFIG), ".upgrades[0].proxy");
        IMPL_NAME = vm.parseJsonString(vm.readFile(CONFIG), ".upgrades[0].implementation");
        re = IRiskEngine(PROXY);
        POOL = PanopticPoolV2(vm.parseJsonAddress(live, ".pools[0].pool"));
        if (bytes(upgraded).length != 0) {
            vm.createSelectFork(upgraded);
            preUpgraded = true;
        } else {
            vm.createSelectFork(rpc, vm.parseJsonUint(live, ".block"));
        }

        rawTxs = vm.readFile(string.concat(DIR, "raw-txs.json"));
        newImpl = vm.parseJsonAddress(vm.readFile(RELEASE_INFO), ".logicContracts[0].address");
        liveImpl = _impl();
        proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(PROXY, ADMIN_SLOT)))));
        ownerSafe = proxyAdmin.owner();
        if (preUpgraded) assertEq(liveImpl, newImpl, "UPGRADED_RPC_URL does not run the release");
        else assertEq(newImpl.code.length, 0, "release slot already used");

        assertFalse(
            vm.keyExistsJson(live, ".pools[1]"),
            "more than one pool is bound to the proxy"
        );
        assertEq(address(POOL.riskEngine()), PROXY, "pool is bound to the proxy");
        ct0 = POOL.collateralToken0();
        ct1 = POOL.collateralToken1();
        _sides();

        for (uint256 i; ; ++i) {
            string memory key = string.concat(".pools[0].accounts[", vm.toString(i), "]");
            if (!vm.keyExistsJson(live, key)) break;
            address who = vm.parseJsonAddress(live, string.concat(key, ".who"));
            string[] memory ids = vm.parseJsonStringArray(live, string.concat(key, ".ids"));
            accounts.push(who);
            for (uint256 j; j < ids.length; ++j)
                lists[who].push(TokenId.wrap(vm.parseUint(ids[j])));
            totalPositions += ids.length;
            // reverts with InputListFail if the list is not exactly what the account holds
            try POOL.validateCollateralWithdrawable(who, lists[who], false) {} catch (
                bytes memory reason
            ) {
                require(bytes4(reason) != 0x99e877ce, "live.json list is not the account's book");
            }
        }
        assertGt(accounts.length, 0, "no live accounts");

        _fund(KEEPER, 3_000_000 * S, 1_000 * R);
        // a liquidator pays a negative bonus from its wallet
        deal(address(stable), KEEPER, 1_000_000 * S);
        deal(address(risky), KEEPER, 500 * R);
    }

    /// @dev Which token is the dollar: the one with fewer decimals (6 against 18 in both pools rehearsed so far).
    function _sides() internal {
        sym0 = IERC20Metadata(ct0.asset()).symbol();
        sym1 = IERC20Metadata(ct1.asset()).symbol();
        dec0 = IERC20Metadata(ct0.asset()).decimals();
        dec1 = IERC20Metadata(ct1.asset()).decimals();
        ts = POOL.tickSpacing();
        assertTrue(dec0 != dec1, "cannot tell the dollar side from the decimals");
        stableIs0 = dec0 < dec1;
        (ctS, ctR) = stableIs0 ? (ct0, ct1) : (ct1, ct0);
        (symS, symR) = stableIs0 ? (sym0, sym1) : (sym1, sym0);
        stable = IERC20Partial(ctS.asset());
        risky = IERC20Partial(ctR.asset());
        S = 10 ** (stableIs0 ? dec0 : dec1);
        R = 10 ** (stableIs0 ? dec1 : dec0);
    }

    /// @dev The initialized tick nearest below the current one.
    function _atm() internal view returns (int24) {
        return (POOL.getCurrentTick() / ts) * ts;
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _impl() internal view returns (address) {
        return address(uint160(uint256(vm.load(PROXY, IMPL_SLOT))));
    }

    /// @dev Sends the generated batch call by call, each from the account that has to send it on-chain.
    function _upgrade() internal {
        if (preUpgraded) return;
        for (uint256 i; ; ++i) {
            string memory key = string.concat(".txs[", vm.toString(i), "]");
            if (!vm.keyExistsJson(rawTxs, key)) break;
            vm.prank(vm.parseJsonAddress(rawTxs, string.concat(key, ".from")));
            (bool ok, ) = vm.parseJsonAddress(rawTxs, string.concat(key, ".to")).call(
                vm.parseJsonBytes(rawTxs, string.concat(key, ".data"))
            );
            require(ok, string.concat("batch call failed: ", vm.toString(i)));
        }
        assertEq(_impl(), newImpl, "implementation slot after the batch");
        assertGt(newImpl.code.length, 0, "no code at the release address");
        assertLe(newImpl.code.length, 24_576, "EIP-170");
    }

    function _upgradeTo(address impl) internal {
        vm.prank(ownerSafe);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(PROXY), impl, "");
    }

    /// @dev The release bytecode with the premium fee the live proxy charges today, so that what the new code does
    /// to live accounts can be told apart from what the new fee does. The fee is the 22nd of the 25 constructor
    /// words at the end of the initcode.
    function _releaseAtLiveFee() internal returns (address impl) {
        (RiskParameters rp, ) = POOL.getRiskParameters(0);
        bytes memory initcode = vm.parseJsonBytes(
            vm.readFile(RELEASE_INFO),
            ".logicContracts[0].initcode"
        );
        uint256 at = initcode.length - 96; // memory offset of the word, counting the length prefix
        uint256 configured;
        uint256 liveFee = rp.premiumFee();
        assembly {
            configured := mload(add(initcode, at))
            mstore(add(initcode, at), liveFee)
            impl := create(0, add(initcode, 32), mload(initcode))
        }
        uint256[] memory tier = vm.parseJsonUintArray(
            vm.readFile(CONFIG),
            string.concat(".logicContracts.", IMPL_NAME, ".constructorArgs[0][3]")
        );
        assertEq(configured, tier[18], "premium fee word not where expected");
        assertGt(impl.code.length, 0, "live-fee build did not deploy");
    }

    /// @dev Deposits `amountS` of the dollar token and `amountR` of the other one.
    function _fund(address who, uint256 amountS, uint256 amountR) internal {
        deal(address(stable), who, amountS);
        deal(address(risky), who, amountR);
        vm.startPrank(who);
        stable.approve(address(ctS), type(uint256).max);
        risky.approve(address(ctR), type(uint256).max);
        ctS.deposit(amountS, who);
        ctR.deposit(amountR, who);
        vm.stopPrank();
    }

    function _limits(uint256 n, bool swap) internal pure returns (int24[3][] memory limits) {
        limits = new int24[3][](n);
        for (uint256 i; i < n; ++i)
            limits[i] = swap
                ? [Constants.MAX_POOL_TICK, Constants.MIN_POOL_TICK, int24(8388607)]
                : [Constants.MIN_POOL_TICK, Constants.MAX_POOL_TICK, int24(8388607)];
    }

    function _one(TokenId id) internal pure returns (TokenId[] memory list) {
        list = new TokenId[](1);
        list[0] = id;
    }

    function _size(uint128 size) internal pure returns (uint128[] memory sizes) {
        sizes = new uint128[](1);
        sizes[0] = size;
    }

    /// @dev `list` without its `skip`-th entry.
    function _without(
        TokenId[] memory list,
        uint256 skip
    ) internal pure returns (TokenId[] memory out) {
        out = new TokenId[](list.length - 1);
        uint256 k;
        for (uint256 i; i < list.length; ++i) if (i != skip) out[k++] = list[i];
    }

    /// @dev `list` with its `last`-th entry moved to the end (the entry dispatchFrom acts on).
    function _lastIs(
        TokenId[] memory list,
        uint256 last
    ) internal pure returns (TokenId[] memory out) {
        out = new TokenId[](list.length);
        uint256 k;
        for (uint256 i; i < list.length; ++i) if (i != last) out[k++] = list[i];
        out[k] = list[last];
    }

    function _sel(bytes memory ret) internal pure returns (bytes4 s) {
        if (ret.length >= 4)
            assembly {
                s := mload(add(ret, 32))
            }
    }

    function _state(address who) internal view returns (bytes memory) {
        return
            abi.encode(
                ct0.balanceOf(who),
                ct1.balanceOf(who),
                stable.balanceOf(who),
                risky.balanceOf(who),
                ct0.totalAssets(),
                ct1.totalAssets(),
                POOL.numberOfLegs(who)
            );
    }

    function _slash(address who, uint256 rounds) internal {
        deal(address(ct0), who, ct0.balanceOf(who) / 20 ** rounds);
        deal(address(ct1), who, ct1.balanceOf(who) / 20 ** rounds);
    }

    /// @dev How many cuts to a twentieth leave `who` with less than half the collateral its positions need.
    function _cutsToInsolvency(address who, TokenId[] memory list) internal returns (uint8 rounds) {
        uint256 snap = vm.snapshotState();
        while (rounds < 4) {
            ++rounds;
            _slash(who, 1);
            (
                LeftRightUnsigned shortPremium,
                LeftRightUnsigned longPremium,
                PositionBalance[] memory balances,
                ,

            ) = POOL.getFullPositionsData(who, true, list);
            if (
                _health(who, list, balances, shortPremium, longPremium, POOL.getCurrentTick()) <
                5_000_000
            ) break;
        }
        vm.revertToStateAndDelete(snap);
    }

    function _add(
        address actor,
        address subject,
        address target,
        bytes memory data,
        string memory name,
        uint8 prep
    ) internal {
        aActor.push(actor);
        aSubject.push(subject);
        aTarget.push(target);
        aData.push(data);
        aName.push(name);
        aPrep.push(prep);
    }

    function _label(
        address who,
        string memory what,
        uint256 i
    ) internal pure returns (string memory) {
        return string.concat(vm.toString(who), " ", what, " #", vm.toString(i));
    }

    /// @dev Runs operation `i` `warpBy` seconds from now and rolls everything back: (true, subject state) or
    /// (false, revert data).
    function _outcome(uint256 i, uint256 warpBy) internal returns (bytes memory out) {
        uint256 snap = vm.snapshotState();
        if (warpBy != 0) {
            vm.warp(block.timestamp + warpBy);
            vm.roll(block.number + warpBy / 12);
        }
        if (aPrep[i] != 0) _slash(aSubject[i], aPrep[i]);
        vm.prank(aActor[i]);
        (bool ok, bytes memory ret) = aTarget[i].call(aData[i]);
        out = ok ? abi.encode(true, _state(aSubject[i])) : abi.encode(false, ret);
        vm.revertToStateAndDelete(snap);
    }

    function _runAll(uint256 warpBy) internal returns (bytes[] memory out) {
        out = new bytes[](aData.length);
        for (uint256 i; i < out.length; ++i) out[i] = _outcome(i, warpBy);
    }

    /// @dev 0 identical, 1 goes through with another result, 2 reverts on both, 3 only reverted before,
    /// 4 regression: went through before and reverts after.
    function _classify(
        bytes memory a,
        bytes memory b
    ) internal pure returns (uint256 kind, bytes4 selA, bytes4 selB) {
        (bool okA, bytes memory rA) = abi.decode(a, (bool, bytes));
        (bool okB, bytes memory rB) = abi.decode(b, (bool, bytes));
        if (!okA) selA = _sel(rA);
        if (!okB) selB = _sel(rB);
        if (okA && !okB) kind = 4;
        else if (!okA && okB) kind = 3;
        else if (!okA) kind = 2;
        else if (keccak256(rA) != keccak256(rB)) kind = 1;
    }

    /// @dev Compares two runs of the operation list. A regression is an operation that went through before and
    /// reverts after.
    function _report(
        string memory label,
        bytes[] memory a,
        bytes[] memory b,
        bool listFailures
    ) internal view returns (uint256 regressions, uint256 different) {
        uint256[5] memory count;
        for (uint256 i; i < a.length; ++i) {
            (uint256 kind, bytes4 selA, bytes4 selB) = _classify(a[i], b[i]);
            ++count[kind];
            if (kind == 4) {
                console2.log("  REGRESSION", aName[i]);
                console2.logBytes4(selB);
            } else if (kind == 3) {
                console2.log("  now goes through", aName[i]);
                console2.logBytes4(selA);
            } else if (kind == 2 && (listFailures || selA != selB)) {
                console2.log("  reverts on both", aName[i]);
                console2.logBytes4(selA);
                if (selA != selB) console2.logBytes4(selB);
            } else if (kind == 1 && !listFailures) {
                console2.log("  different balances", aName[i]);
            }
        }
        console2.log(label);
        console2.log("    operations / identical outcome          ", a.length, count[0]);
        console2.log("    go through with different balances      ", count[1]);
        console2.log("    revert on both / revert only before     ", count[2], count[3]);
        console2.log("    REGRESSIONS (went through, now reverts) ", count[4]);
        return (count[4], count[1]);
    }

    /// @dev The operation list on the live engine, on the release bytecode at the live premium fee, and on the
    /// release as configured (through the generated batch). `warpBy` and `locked` set the conditions for all three.
    function _differential(string memory label, uint256 warpBy, bool locked) internal {
        assertEq(
            _differentialCount(label, warpBy, locked),
            0,
            "the new code changes an outcome at the live fee"
        );
    }

    /// @return different How many operations go through on both but end differently at the live fee
    function _differentialCount(
        string memory label,
        uint256 warpBy,
        bool locked
    ) internal returns (uint256 different) {
        if (preUpgraded) {
            vm.skip(true);
            return 0;
        }
        if (locked) {
            vm.prank(re.GUARDIAN());
            re.lockPool(POOL);
        }
        console2.log(label, "- operations:", aData.length);
        bytes[] memory before = _runAll(warpBy);

        uint256 snap = vm.snapshotState();
        _upgradeTo(_releaseAtLiveFee());
        bytes[] memory atLiveFee = _runAll(warpBy);
        vm.revertToStateAndDelete(snap);

        _upgrade();
        bytes[] memory configured = _runAll(warpBy);

        uint256 r0;
        (r0, different) = _report(
            "live engine -> release code at the live fee",
            before,
            atLiveFee,
            false
        );
        (uint256 r1, ) = _report("live engine -> release as configured", before, configured, true);
        assertEq(r0, 0, "the new code blocks an operation that goes through today");
        assertEq(r1, 0, "the configured release blocks an operation that goes through today");
    }

    /*//////////////////////////////////////////////////////////////
                      THE BATCH AND WHAT IT CHANGES
    //////////////////////////////////////////////////////////////*/

    /// @dev The upgrade is two Safe transactions because the CREATE3 slot can only be minted by the Safe embedded
    /// in the salt and the proxy can only be upgraded by the ProxyAdmin owner: neither can send the other's half.
    function test_batch_eachHalfNeedsItsOwnSafe() public {
        if (preUpgraded) {
            vm.skip(true);
            return;
        }
        address deployerSafe = vm.parseJsonAddress(rawTxs, ".txs[0].from");
        assertEq(vm.parseJsonString(rawTxs, ".txs[0].method"), "mint");
        assertEq(vm.parseJsonString(rawTxs, ".txs[4].method"), "upgradeAndCall");
        assertTrue(deployerSafe != ownerSafe, "one Safe does both");

        vm.prank(ownerSafe);
        (bool ok, ) = vm.parseJsonAddress(rawTxs, ".txs[0].to").call(
            vm.parseJsonBytes(rawTxs, ".txs[0].data")
        );
        assertFalse(ok, "the ProxyAdmin owner can mint the deployer Safe's slot");

        vm.prank(deployerSafe);
        (ok, ) = address(proxyAdmin).call(vm.parseJsonBytes(rawTxs, ".txs[4].data"));
        assertFalse(ok, "the deployer Safe can upgrade the proxy");
        console2.log("deploy (mint + deploy) must come from ", deployerSafe);
        console2.log("accrue + upgradeAndCall must come from", ownerSafe);
    }

    /// @dev What the pool reads from the engine, before and after the replayed batch: only the premium fee moves.
    function test_batch_changesOnlyThePremiumFee() public {
        if (preUpgraded) {
            vm.skip(true);
            return;
        }
        // the batch accrues both trackers first; do the same here so the rates are compared like for like
        ct0.accrueInterest();
        ct1.accrueInterest();
        (RiskParameters rpBefore, ) = POOL.getRiskParameters(0);
        bytes32 oracleBefore = keccak256(_oracleView());
        bytes32 fixedBefore = keccak256(_fixedView());
        int24[] memory ticksBefore = _solvencyTicks();

        _upgrade();

        (RiskParameters rp, ) = POOL.getRiskParameters(0);
        assertEq(
            keccak256(_oracleView()),
            oracleBefore,
            "oracle, safe mode or interest rate moved"
        );
        _assertSolvencyTicksMoveOnlyByTheBand(ticksBefore, _solvencyTicks());
        assertEq(
            keccak256(_fixedView()),
            fixedBefore,
            "guardian, factory, vegoid or buffers moved"
        );
        assertEq(rp.safeMode(), rpBefore.safeMode(), "safeMode");
        assertEq(rp.notionalFee(), rpBefore.notionalFee(), "notionalFee");
        assertEq(rp.protocolSplit(), rpBefore.protocolSplit(), "protocolSplit");
        assertEq(rp.builderSplit(), rpBefore.builderSplit(), "builderSplit");
        assertEq(rp.tickDeltaDispatch(), rpBefore.tickDeltaDispatch(), "tickDeltaDispatch");
        assertEq(rp.maxSpread(), rpBefore.maxSpread(), "maxSpread");
        assertEq(rp.bpDecreaseBuffer(), rpBefore.bpDecreaseBuffer(), "bpDecreaseBuffer");
        assertEq(rp.maxLegs(), rpBefore.maxLegs(), "maxLegs");
        assertEq(rp.feeRecipient(), rpBefore.feeRecipient(), "feeRecipient");
        console2.log("premium fee before / after (bps)", rpBefore.premiumFee(), rp.premiumFee());
        console2.log("safe mode", rp.safeMode());
        assertEq(address(proxyAdmin), vm.computeCreateAddress(PROXY, 1), "ProxyAdmin");
        assertEq(proxyAdmin.owner(), ownerSafe, "ProxyAdmin owner");
    }

    /// @dev The ticks the pool's solvency checks are judged at, as the engine picks them now.
    function _solvencyTicks() internal view returns (int24[] memory ticks) {
        (int24 currentTick, , , , OraclePack pack) = POOL.getOracleTicks();
        (ticks, ) = re.getSolvencyTicks(currentTick, pack, 0);
    }

    /// @dev The release adds the current tick to the solvency ticks once spot is a band (the buyer collateral ratio
    /// in ticks) or more from it, where `isAccountSolvent` would otherwise pass an account owing long premium
    /// without testing its collateral (Nethermind N-08). Any other change to the ticks fails.
    function _assertSolvencyTicksMoveOnlyByTheBand(
        int24[] memory before,
        int24[] memory afterUpgrade
    ) internal view {
        (int24 current, int24 spot, , , ) = POOL.getOracleTicks();
        uint256[] memory tier = vm.parseJsonUintArray(
            vm.readFile(CONFIG),
            string.concat(".logicContracts.", IMPL_NAME, ".constructorArgs[0][3]")
        );
        int256 band = int256(tier[9] / 1000);
        int256 d = int256(spot) - current;
        if (before.length == 1 && (d >= band || -d >= band)) {
            assertEq(afterUpgrade.length, 2, "spot a band from the current tick: spot and current");
            assertEq(afterUpgrade[0], before[0], "spot first");
            assertEq(afterUpgrade[1], current, "then the current tick");
            console2.log("solvency ticks: current tick added, spot", int256(spot));
            console2.log("                                   current", int256(current));
        } else {
            assertEq(
                keccak256(abi.encode(afterUpgrade)),
                keccak256(abi.encode(before)),
                "solvency ticks moved"
            );
        }
    }

    function _oracleView() internal view returns (bytes memory out) {
        (int24 currentTick, int24 spot, int24 median, int24 latest, OraclePack pack) = POOL
            .getOracleTicks();
        out = abi.encode(
            currentTick,
            spot,
            median,
            latest,
            pack,
            POOL.getTWAP(),
            POOL.isSafeMode()
        );
        out = bytes.concat(
            out,
            _engineOracleView(currentTick, pack),
            abi.encode(ct0.interestRate(), ct1.interestRate())
        );
    }

    function _engineOracleView(
        int24 currentTick,
        OraclePack pack
    ) internal view returns (bytes memory out) {
        // the solvency ticks themselves are compared by `_assertSolvencyTicksMoveOnlyByTheBand`
        (, OraclePack p0) = re.getSolvencyTicks(currentTick, pack, 0);
        out = abi.encode(p0, re.twapEMA(pack), re.isSafeMode(currentTick, pack));
        (int24 m1, OraclePack p1) = re.computeInternalMedian(pack, currentTick);
        (int24 m2, OraclePack p2) = re.computeInternalMedian(pack, currentTick + 400);
        out = bytes.concat(out, abi.encode(m1, p1, m2, p2));
    }

    function _fixedView() internal view returns (bytes memory out) {
        out = abi.encode(
            re.vegoid(),
            re.DECIMALS(),
            re.GUARDIAN(),
            re.BUILDER_FACTORY(),
            re.CROSS_BUFFER_0(),
            re.CROSS_BUFFER_1(),
            re.getFeeRecipient(0)
        );
        int256[6] memory utilizations = [int256(0), 5_000, 9_000, 9_250, 9_500, 10_000];
        for (uint256 i; i < utilizations.length; ++i)
            out = bytes.concat(
                out,
                abi.encode(re.crossBufferRatio(utilizations[i], re.CROSS_BUFFER_0()))
            );
    }

    /*//////////////////////////////////////////////////////////////
                   EVERY LIVE ACCOUNT, BEFORE AND AFTER
    //////////////////////////////////////////////////////////////*/

    /// @dev Health (100% = exactly at the requirement) and the pool's own solvency check for every live account
    /// on the live engine and on the release, plus the engine's margin and solvency views far from spot: the
    /// release may not revert where the live engine answers.
    function test_live_solvencyOfEveryAccount() public {
        if (preUpgraded) {
            vm.skip(true);
            return;
        }
        uint256 n = accounts.length;
        bool[] memory passes = new bool[](n);
        uint256[] memory health = new uint256[](n);
        bytes32[] memory answers = new bytes32[](n);
        for (uint256 i; i < n; ++i) (passes[i], health[i], answers[i]) = _solvencyView(accounts[i]);

        _upgrade();

        uint256 flips;
        uint256 moved;
        console2.log("accounts / positions", n, totalPositions);
        for (uint256 i; i < n; ++i) {
            (bool pass, uint256 h, bytes32 answer) = _solvencyView(accounts[i]);
            // bit i of the answer mask is set when the engine answered at probe tick i
            assertEq(
                uint256(answers[i]) & ~uint256(answer),
                0,
                string.concat(
                    "release reverts where the live engine answers: ",
                    vm.toString(accounts[i])
                )
            );
            if (pass != passes[i]) ++flips;
            if (h != health[i]) ++moved;
            console2.log(
                accounts[i],
                passes[i] ? "passes" : "FAILS",
                pass ? "-> passes" : "-> FAILS"
            );
            emit log_named_decimal_uint("    health before (%)", health[i], 5);
            emit log_named_decimal_uint("    health after  (%)", h, 5);
        }
        console2.log("accounts whose health moved / whose pool solvency check flips", moved, flips);
        assertEq(flips, 0, "an account changes side of the pool solvency check");
    }

    function _solvencyView(
        address who
    ) internal view returns (bool passes, uint256 health, bytes32 answered) {
        TokenId[] memory list = lists[who];
        try POOL.validateCollateralWithdrawable(who, list, false) {
            passes = true;
        } catch {}
        (
            LeftRightUnsigned shortPremium,
            LeftRightUnsigned longPremium,
            PositionBalance[] memory balances,
            ,

        ) = POOL.getFullPositionsData(who, true, list);
        health = _health(who, list, balances, shortPremium, longPremium, POOL.getCurrentTick());
        int24[9] memory offsets = [int24(-50000), -10000, -2500, -400, 0, 400, 2500, 10000, 50000];
        uint256 mask;
        for (uint256 i; i < offsets.length; ++i)
            if (
                _answers(
                    abi.encodeCall(
                        IRiskEngine.getMargin,
                        (
                            balances,
                            POOL.getCurrentTick() + offsets[i],
                            who,
                            list,
                            shortPremium,
                            longPremium,
                            ct0,
                            ct1
                        )
                    )
                )
            ) mask |= 1 << i;
        answered = bytes32(mask);
    }

    function _answers(bytes memory data) internal view returns (bool ok) {
        (ok, ) = PROXY.staticcall(data);
    }

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

    function _buildCloseAll() internal {
        for (uint256 i; i < accounts.length; ++i) {
            address who = accounts[i];
            TokenId[] memory list = lists[who];
            for (uint256 swap; swap < 2; ++swap)
                _add(
                    who,
                    who,
                    address(POOL),
                    abi.encodeCall(
                        POOL.dispatch,
                        (
                            list,
                            empty,
                            new uint128[](list.length),
                            _limits(list.length, swap == 1),
                            false,
                            0
                        )
                    ),
                    _label(
                        who,
                        swap == 1 ? "closes its book with swap" : "closes its book in kind",
                        0
                    ),
                    0
                );
        }
    }

    /// @dev Whole-book close of every live account, in kind and with swap.
    function test_live_everyAccountClosesItsBook() public {
        _buildCloseAll();
        _differential("close whole book", 0, false);
    }

    /// @dev Same a month after the upgrade with nobody touching the pool in between.
    function test_live_everyAccountClosesItsBook_aMonthLater() public {
        _buildCloseAll();
        _differential("close whole book, 30 days later", 30 days, false);
    }

    /// @dev Same with the guardian lock on (every burn is forced covered).
    function test_live_everyAccountClosesItsBook_whileLocked() public {
        _buildCloseAll();
        _differential("close whole book, pool locked", 0, true);
    }

    /// @dev Every live position closed on its own, in kind and with swap, the rest of the book staying open.
    function test_live_everyPositionClosesAlone() public {
        for (uint256 i; i < accounts.length; ++i) {
            address who = accounts[i];
            TokenId[] memory list = lists[who];
            for (uint256 j; j < list.length; ++j)
                for (uint256 swap; swap < 2; ++swap)
                    _add(
                        who,
                        who,
                        address(POOL),
                        abi.encodeCall(
                            POOL.dispatch,
                            (
                                _one(list[j]),
                                _without(list, j),
                                _size(0),
                                _limits(1, swap == 1),
                                false,
                                0
                            )
                        ),
                        _label(who, swap == 1 ? "closes with swap" : "closes in kind", j),
                        0
                    );
        }
        _differential("close one position", 0, false);
    }

    /// @dev Every live position settles its premium (dispatch at the size held).
    function test_live_everyPositionSettles() public {
        for (uint256 i; i < accounts.length; ++i) {
            address who = accounts[i];
            TokenId[] memory list = lists[who];
            (, , PositionBalance[] memory balances, , ) = POOL.getFullPositionsData(
                who,
                true,
                list
            );
            for (uint256 j; j < list.length; ++j)
                _add(
                    who,
                    who,
                    address(POOL),
                    abi.encodeCall(
                        POOL.dispatch,
                        (
                            _one(list[j]),
                            list,
                            _size(balances[j].positionSize()),
                            _limits(1, false),
                            false,
                            0
                        )
                    ),
                    _label(who, "settles", j),
                    0
                );
        }
        _differential("settle premium", 0, false);
    }

    /// @dev Every live account adds a position (a small short put 3,000 ticks below spot, then a small long of
    /// the same chunk is left to the fresh-account test) and withdraws a little of each token.
    function test_live_everyAccountMintsAndWithdraws() public {
        int24 atm = _atm();
        TokenId base = TokenId.wrap(0).addPoolId(POOL.poolId());
        TokenId put = _leg(base, 0, 0, 1, atm - 3000, 40);
        TokenId call = _leg(base, 0, 0, 0, atm + 3000, 40);
        for (uint256 i; i < accounts.length; ++i) {
            address who = accounts[i];
            _addMint(who, put, "mints a short put");
            _addMint(who, call, "mints a short call");
            _add(
                who,
                who,
                address(ctS),
                abi.encodeWithSignature(
                    "withdraw(uint256,address,address,uint256[],bool)",
                    S,
                    who,
                    who,
                    lists[who],
                    false
                ),
                _label(who, string.concat("withdraws 1 ", symS), 0),
                0
            );
            _add(
                who,
                who,
                address(ctR),
                abi.encodeWithSignature(
                    "withdraw(uint256,address,address,uint256[],bool)",
                    R / 2000,
                    who,
                    who,
                    lists[who],
                    false
                ),
                _label(who, string.concat("withdraws 0.0005 ", symR), 0),
                0
            );
        }
        _differential("mint and withdraw", 0, false);
    }

    function _addMint(address who, TokenId id, string memory what) internal {
        TokenId[] memory list = lists[who];
        TokenId[] memory next = new TokenId[](list.length + 1);
        for (uint256 j; j < list.length; ++j) next[j] = list[j];
        next[list.length] = id;
        _add(
            who,
            who,
            address(POOL),
            abi.encodeCall(
                POOL.dispatch,
                (_one(id), next, _size(uint128(R / 100)), _limits(1, false), false, 0)
            ),
            _label(who, what, 0),
            0
        );
    }

    /// @dev Every live position with an exercisable long leg is force-exercised by a third party.
    function test_live_everyLongIsForceExercisable() public {
        uint256 multiLong;
        for (uint256 i; i < accounts.length; ++i) {
            address who = accounts[i];
            TokenId[] memory list = lists[who];
            for (uint256 j; j < list.length; ++j) {
                if (list[j].countLongs() == 0 || list[j].validateIsExercisable() == 0) continue;
                if (list[j].countLongs() > 1) ++multiLong;
                _add(
                    KEEPER,
                    who,
                    address(POOL),
                    abi.encodeCall(
                        POOL.dispatchFrom,
                        (empty, who, _lastIs(list, j), _without(list, j), LeftRightUnsigned.wrap(0))
                    ),
                    _label(
                        who,
                        list[j].countLongs() > 1
                            ? "(several longs) is force-exercised"
                            : "is force-exercised",
                        j
                    ),
                    0
                );
            }
        }
        // the fee of a position with several long legs is the one intended change (cheapest leg only)
        assertLe(
            _differentialCount("force exercise", 0, false),
            multiLong,
            "a single-long exercise changed"
        );
    }

    /// @dev Whether the pool's current tick is a liquidation band or more (the release's buyer collateral ratio in
    /// ticks) from one of the oracle ticks `dispatchFrom` checks.
    function _poolIsDisplaced() internal view returns (bool) {
        uint256[] memory tier = vm.parseJsonUintArray(
            vm.readFile(CONFIG),
            string.concat(".logicContracts.", IMPL_NAME, ".constructorArgs[0][3]")
        );
        int256 band = int256(tier[9] / 1000);
        (int24 current, int24 spot, , int24 latest, ) = POOL.getOracleTicks();
        int256[3] memory oracle = [int256(spot), int256(latest), int256(POOL.getTWAP())];
        for (uint256 i; i < 3; ++i) {
            int256 d = oracle[i] - current;
            if (d >= band || -d >= band) {
                console2.log("  pool displaced: current tick", int256(current));
                console2.log("                  oracle tick", oracle[i]);
                console2.log("                  band (ticks)", band);
                return true;
            }
        }
        return false;
    }

    /// @dev Liquidations that went through in run `a` and are refused in run `b` by the release's displaced-price
    /// rule: `NotMarginCalled`, for an account that owes long premium, while the pool's tick is a band or more
    /// from the oracle's. A keeper clears these by moving the price back inside the band before liquidating.
    function _displacedRefusals(
        bytes[] memory a,
        bytes[] memory b
    ) internal view returns (uint256 n) {
        if (!_poolIsDisplaced()) return 0;
        for (uint256 i; i < a.length; ++i) {
            (uint256 kind, , bytes4 selB) = _classify(a[i], b[i]);
            if (kind != 4 || selB != 0x2a23f1ad) continue; // NotMarginCalled()
            (, LeftRightUnsigned longPremium, , , ) = POOL.getFullPositionsData(
                aSubject[i],
                true,
                lists[aSubject[i]]
            );
            if (LeftRightUnsigned.unwrap(longPremium) == 0) continue;
            ++n;
            console2.log("  refused at a displaced price, as designed:", aName[i]);
        }
    }

    /// @dev Every live account, with its collateral cut until it covers less than half of what its positions need,
    /// is liquidated by a third party. Two differences from the live engine are expected and not failures:
    /// - balances: the bonus is sized from the requirements, and the release changes the long requirement;
    /// - an account that owes long premium is not liquidated while the pool's tick is a band or more from the
    ///   oracle's (`isAccountSolvent`). Any other liquidation the release blocks is a failure.
    function test_live_everyAccountIsLiquidatableOnceInsolvent() public {
        for (uint256 i; i < accounts.length; ++i) {
            address who = accounts[i];
            _add(
                KEEPER,
                who,
                address(POOL),
                abi.encodeCall(
                    POOL.dispatchFrom,
                    (empty, who, lists[who], empty, LeftRightUnsigned.wrap(0))
                ),
                _label(who, "is liquidated", 0),
                _cutsToInsolvency(who, lists[who])
            );
        }
        if (preUpgraded) {
            vm.skip(true);
            return;
        }
        console2.log("liquidation - operations:", aData.length);
        bytes[] memory before = _runAll(0);

        uint256 snap = vm.snapshotState();
        _upgradeTo(_releaseAtLiveFee());
        bytes[] memory atLiveFee = _runAll(0);
        vm.revertToStateAndDelete(snap);

        _upgrade();
        bytes[] memory configured = _runAll(0);

        (uint256 r0, ) = _report(
            "live engine -> release code at the live fee",
            before,
            atLiveFee,
            false
        );
        (uint256 r1, ) = _report("live engine -> release as configured", before, configured, true);
        // at the live fee, only an account that holds a long leg may be liquidated with other balances
        for (uint256 i; i < before.length; ++i) {
            (uint256 kind, , ) = _classify(before[i], atLiveFee[i]);
            if (kind == 1)
                assertTrue(
                    _holdsLong(aSubject[i]),
                    string.concat(
                        "liquidation balances changed for an account with no long leg: ",
                        vm.toString(aSubject[i])
                    )
                );
        }
        uint256 displaced = _displacedRefusals(before, configured);
        console2.log("    refused at a displaced price (expected)  ", displaced);
        assertEq(
            r0,
            _displacedRefusals(before, atLiveFee),
            "the new code blocks a liquidation that is not at a displaced price"
        );
        assertEq(
            r1,
            displaced,
            "the configured release blocks a liquidation that is not at a displaced price"
        );
    }

    /// @dev Whether `who` holds a long leg with a width (an option bought, not a credit).
    function _holdsLong(address who) internal view returns (bool) {
        TokenId[] memory list = lists[who];
        for (uint256 j; j < list.length; ++j) {
            uint256 legs = list[j].countLegs();
            for (uint256 l; l < legs; ++l)
                if (list[j].isLong(l) == 1 && list[j].width(l) != 0) return true;
        }
        return false;
    }

    /// @dev Swaps in the Uniswap pool (v3 or v4) until its tick is `tick`, from an account funded for it.
    function _movePrice(int24 tick) internal {
        address mover = makeAddr("MOVER");
        deal(address(ct0.asset()), mover, type(uint104).max);
        deal(address(ct1.asset()), mover, type(uint104).max);
        uint160 target = Math.getSqrtRatioAtTick(tick);
        if (POOL.poolManager() == address(0)) {
            IUniswapV3Pool uni = IUniswapV3Pool(abi.decode(POOL.poolKey(), (address)));
            PriceMoverV3 v3 = new PriceMoverV3();
            vm.startPrank(mover);
            IERC20Partial(ct0.asset()).transfer(address(v3), type(uint104).max);
            IERC20Partial(ct1.asset()).transfer(address(v3), type(uint104).max);
            vm.stopPrank();
            v3.swapTo(uni, target);
        } else {
            V4RouterSimple v4 = new V4RouterSimple(IPoolManager(POOL.poolManager()));
            vm.startPrank(mover);
            IERC20Partial(ct0.asset()).approve(address(v4), type(uint256).max);
            IERC20Partial(ct1.asset()).approve(address(v4), type(uint256).max);
            v4.swapTo(address(0), abi.decode(POOL.poolKey(), (PoolKey)), target);
            vm.stopPrank();
        }
        assertEq(POOL.getCurrentTick(), tick, "price move");
    }

    /// @dev The selector a liquidation of `who` by the keeper reverts with, zero if it goes through. Rolled back.
    function _liquidationRefusal(address who) internal returns (bytes4 selector) {
        uint256 snap = vm.snapshotState();
        vm.prank(KEEPER);
        (bool ok, bytes memory ret) = address(POOL).call(
            abi.encodeCall(
                POOL.dispatchFrom,
                (empty, who, lists[who], empty, LeftRightUnsigned.wrap(0))
            )
        );
        if (!ok) selector = _sel(ret);
        vm.revertToStateAndDelete(snap);
    }

    /// @dev The tick nearest to the pool's current tick that is inside `band` of the spot, latest and TWAP ticks.
    function _tickBackInsideBand(int24 band) internal view returns (int24 back) {
        (int24 current, int24 spot, , int24 latest, ) = POOL.getOracleTicks();
        int24 twap = POOL.getTWAP();
        int24 lo = spot < latest ? spot : latest;
        int24 hi = spot > latest ? spot : latest;
        if (twap < lo) lo = twap;
        if (twap > hi) hi = twap;
        assertLt(hi - lo, 2 * band, "oracle ticks too far apart for a push-back");
        back = current < lo ? hi - band + 2 : lo + band - 2;
        console2.log("    refused at tick", current);
        console2.log("        oracle ticks from", lo);
        console2.log("        oracle ticks to  ", hi);
        console2.log("    price moved back to  ", back);
    }

    /// @dev `who`, cut to insolvency: refused by the displaced-price rule (after a fast move of a band and a half
    /// in direction `dir` if it is liquidatable as found), then liquidated once the price is back inside the band.
    /// Returns false if the account is refused for another reason. Rolled back.
    function _refusedThenRescued(
        address who,
        uint8 rounds,
        int24 dir,
        int24 band
    ) internal returns (bool rescued) {
        uint256 snap = vm.snapshotState();
        _slash(who, rounds);
        bytes4 refusal = _liquidationRefusal(who);
        if (refusal == bytes4(0)) {
            // liquidatable as found: a fast move, which the oracle does not follow
            _movePrice(POOL.getCurrentTick() + dir * ((3 * band) / 2));
            refusal = _liquidationRefusal(who);
        }
        // NotMarginCalled() is the only refusal this is about
        if (refusal == 0x2a23f1ad) {
            console2.log(who);
            _movePrice(_tickBackInsideBand(band));
            assertEq(
                _liquidationRefusal(who),
                bytes4(0),
                "still refused with the price back inside the band"
            );
            rescued = true;
        } else {
            console2.log(who, "not refused by the displaced-price rule, selector:");
            console2.logBytes4(refusal);
        }
        vm.revertToStateAndDelete(snap);
    }

    /// @dev The rescue the release's displaced-price rule relies on. For every live account that owes long premium,
    /// made insolvent: after a fast move of a band and a half (in either direction, the oracle staying behind) the
    /// liquidation is refused with `NotMarginCalled`; once the price is moved back just inside the band of the
    /// three oracle ticks, with no oracle update in between, the same liquidation goes through. An account that
    /// is already refused at the fork block (the pool is displaced as found) skips the fast move.
    /// Moving the price reads Uniswap and token state the other tests never touch, so the RPC has to serve state at
    /// the fork block; set REHEARSAL_NO_ARCHIVE=true to skip on a chain whose RPC does not (Robinhood's public one).
    function test_live_displacedLiquidation_clearedByMovingThePriceBack() public {
        if (preUpgraded || vm.envOr("REHEARSAL_NO_ARCHIVE", false)) {
            vm.skip(true);
            return;
        }
        _upgrade();
        uint256[] memory tier = vm.parseJsonUintArray(
            vm.readFile(CONFIG),
            string.concat(".logicContracts.", IMPL_NAME, ".constructorArgs[0][3]")
        );
        int24 band = int24(int256(tier[9] / 1000));
        uint256 rescued;
        for (uint256 i; i < accounts.length; ++i) {
            address who = accounts[i];
            (, LeftRightUnsigned longPremium, , , ) = POOL.getFullPositionsData(
                who,
                true,
                lists[who]
            );
            if (LeftRightUnsigned.unwrap(longPremium) == 0) continue;
            uint8 rounds = _cutsToInsolvency(who, lists[who]);
            if (_refusedThenRescued(who, rounds, -1, band)) ++rescued;
            if (_refusedThenRescued(who, rounds, 1, band)) ++rescued;
        }
        console2.log("displaced refusals cleared by moving the price back:", rescued);
        assertGt(rescued, 0, "no live account exercised the displaced-price rule");
    }

    /// @dev Premium each live account's short legs have accrued against what is available to collect right now
    /// (the rest is still owed by long holders, or will never arrive), and what its long legs owe. Read-only.
    function test_live_premiumOwedVersusAvailable() public {
        uint256[4] memory total;
        for (uint256 i; i < accounts.length; ++i) {
            address who = accounts[i];
            (LeftRightUnsigned owed, LeftRightUnsigned long, , , ) = POOL.getFullPositionsData(
                who,
                true,
                lists[who]
            );
            (LeftRightUnsigned available, , , , ) = POOL.getFullPositionsData(
                who,
                false,
                lists[who]
            );
            total[0] += owed.rightSlot();
            total[1] += available.rightSlot();
            total[2] += owed.leftSlot();
            total[3] += available.leftSlot();
            if (LeftRightUnsigned.unwrap(owed) == 0 && LeftRightUnsigned.unwrap(long) == 0)
                continue;
            console2.log(who);
            _premiumLine("    ", sym0, " short premium accrued  ", owed.rightSlot(), dec0);
            _premiumLine("    ", sym0, " available now          ", available.rightSlot(), dec0);
            _premiumLine("    ", sym1, " short premium accrued  ", owed.leftSlot(), dec1);
            _premiumLine("    ", sym1, " available now          ", available.leftSlot(), dec1);
            _premiumLine("    ", sym0, " owed by its longs      ", long.rightSlot(), dec0);
            _premiumLine("    ", sym1, " owed by its longs      ", long.leftSlot(), dec1);
        }
        _premiumLine("TOTAL ", sym0, " accrued to sellers", total[0], dec0);
        _premiumLine("TOTAL ", sym0, " available now     ", total[1], dec0);
        _premiumLine("TOTAL ", sym1, " accrued to sellers", total[2], dec1);
        _premiumLine("TOTAL ", sym1, " available now     ", total[3], dec1);
    }

    function _premiumLine(
        string memory indent,
        string memory symbol,
        string memory what,
        uint256 amount,
        uint8 decimals
    ) internal {
        emit log_named_decimal_uint(string.concat(indent, symbol, what), amount, decimals);
    }

    function _closeOne(address who, uint256 j) internal returns (bool ok) {
        TokenId[] memory list = lists[who];
        bytes memory inKind = abi.encodeCall(
            POOL.dispatch,
            (_one(list[j]), _without(list, j), _size(0), _limits(1, false), false, 0)
        );
        bytes memory swapped = abi.encodeCall(
            POOL.dispatch,
            (_one(list[j]), _without(list, j), _size(0), _limits(1, true), false, 0)
        );
        vm.prank(who);
        (ok, ) = address(POOL).call(inKind);
        if (!ok) {
            vm.prank(who);
            (ok, ) = address(POOL).call(swapped);
        }
        if (ok) {
            lists[who][j] = lists[who][list.length - 1];
            lists[who].pop();
        }
    }

    /// @dev Everybody leaves: positions are closed in whatever order works (longs free the chunks their sellers
    /// need), accounts that are short of a token to settle in get topped up once the others are stuck, and every
    /// account then redeems all its shares.
    /// @return left Positions nobody could close
    /// @return stuck Accounts that could not redeem everything
    /// @return toppedUp Accounts that needed a deposit to close
    function _unwind() internal returns (uint256 left, uint256 stuck, uint256 toppedUp) {
        for (uint256 round; round < 16; ++round) {
            uint256 closed;
            left = 0;
            for (uint256 i; i < accounts.length; ++i) {
                for (uint256 j = lists[accounts[i]].length; j > 0; --j)
                    if (_closeOne(accounts[i], j - 1)) ++closed;
                left += lists[accounts[i]].length;
            }
            if (left == 0) break;
            if (closed != 0) continue;
            if (toppedUp != 0) break;
            for (uint256 i; i < accounts.length; ++i) {
                if (lists[accounts[i]].length == 0) continue;
                ++toppedUp;
                _fund(accounts[i], 2_000_000 * S, 500 * R);
            }
        }
        for (uint256 i; i < accounts.length; ++i) {
            address who = accounts[i];
            if (lists[who].length != 0) continue;
            vm.startPrank(who);
            try ct0.redeem(ct0.maxRedeem(who), who, who) {} catch {
                if (ct0.balanceOf(who) != 0) ++stuck;
            }
            try ct1.redeem(ct1.maxRedeem(who), who, who) {} catch {
                if (ct1.balanceOf(who) != 0) ++stuck;
            }
            vm.stopPrank();
            if (ct0.balanceOf(who) + ct1.balanceOf(who) != 0) ++stuck;
        }
    }

    /// @dev The whole pool unwinds on the release: every live position closes and every live account withdraws
    /// all it has, at least as completely as on the live engine.
    function test_live_wholePoolUnwinds() public {
        uint256 leftBefore;
        uint256 stuckBefore;
        uint256 toppedUp;
        if (!preUpgraded) {
            uint256 snap = vm.snapshotState();
            (leftBefore, stuckBefore, toppedUp) = _unwind();
            vm.revertToStateAndDelete(snap);
            console2.log("live engine: positions left / accounts not fully redeemed / topped up");
            console2.log("   ", leftBefore, stuckBefore, toppedUp);
        }
        _upgrade();
        (uint256 left, uint256 stuck, uint256 topped) = _unwind();
        console2.log("release:     positions left / accounts not fully redeemed / topped up");
        console2.log("   ", left, stuck, topped);
        console2.log("pool after everyone left:", symS, symR, "still in the trackers");
        console2.log("   ", ctS.totalAssets() / S, ctR.totalAssets() / R);
        assertEq(left, 0, "a live position cannot be closed on the release");
        assertEq(stuck, 0, "a live account cannot withdraw everything on the release");
        if (!preUpgraded) assertLe(topped, toppedUp, "more accounts need a deposit to close");
    }

    /*//////////////////////////////////////////////////////////////
                     FRESH ACCOUNTS, EVERY OPERATION
    //////////////////////////////////////////////////////////////*/

    function _step(
        string memory name,
        address who,
        address target,
        bytes memory data
    ) internal returns (bool ok) {
        bytes memory ret;
        vm.prank(who);
        (ok, ret) = target.call(data);
        sName.push(name);
        sOk.push(ok);
        sSel.push(_sel(ret));
    }

    function _mint(string memory name, address who, TokenId id, uint128 size, bool swap) internal {
        books[who].push(id);
        if (
            !_step(
                name,
                who,
                address(POOL),
                abi.encodeCall(
                    POOL.dispatch,
                    (_one(id), books[who], _size(size), _limits(1, swap), false, 0)
                )
            )
        ) books[who].pop();
    }

    function _drop(address who, TokenId id) internal {
        TokenId[] storage book = books[who];
        for (uint256 i; i < book.length; ++i) {
            if (TokenId.unwrap(book[i]) == TokenId.unwrap(id)) {
                book[i] = book[book.length - 1];
                book.pop();
                return;
            }
        }
    }

    function _burn(string memory name, address who, TokenId id, bool swap) internal {
        _drop(who, id);
        if (
            !_step(
                name,
                who,
                address(POOL),
                abi.encodeCall(
                    POOL.dispatch,
                    (_one(id), books[who], _size(0), _limits(1, swap), false, 0)
                )
            )
        ) books[who].push(id);
    }

    function _redeemAll(string memory name, address who) internal {
        _step(
            string.concat(name, " redeems all ", symS, " shares"),
            who,
            address(ctS),
            abi.encodeWithSignature("redeem(uint256,address,address)", ctS.maxRedeem(who), who, who)
        );
        _step(
            string.concat(name, " redeems all ", symR, " shares"),
            who,
            address(ctR),
            abi.encodeWithSignature("redeem(uint256,address,address)", ctR.maxRedeem(who), who, who)
        );
    }

    /// @dev One leg on the non-dollar token: `tokenType` 0 = call, 1 = put; width 0 is a loan or a credit of the
    /// dollar token. Written for a pool whose token0 is the dollar and whose tick spacing is 10 (`width` is in
    /// units of 10 ticks); the leg is mirrored around the current tick when the dollar is token1.
    function _leg(
        TokenId id,
        uint256 index,
        uint256 isLong,
        uint256 tokenType,
        int24 strike,
        int24 width
    ) internal view returns (TokenId) {
        width = (width * 10) / ts;
        if (stableIs0)
            return id.addLeg(index, 1, width == 0 ? 0 : 1, isLong, tokenType, index, strike, width);
        return _mirrored(id, index, isLong, 1 - tokenType, 2 * _atm() - strike, width);
    }

    function _mirrored(
        TokenId id,
        uint256 index,
        uint256 isLong,
        uint256 tokenType,
        int24 strike,
        int24 width
    ) internal pure returns (TokenId) {
        return id.addLeg(index, 1, width == 0 ? 1 : 0, isLong, tokenType, index, strike, width);
    }

    /// @dev A short call at `call` and a short put at `put`, 1,000 ticks wide each.
    function _shortPair(TokenId base, int24 call, int24 put) internal view returns (TokenId id) {
        id = _leg(base, 0, 0, 0, call, 100);
        id = _leg(id, 1, 0, 1, put, 100);
    }

    function _tokens() internal view returns (TokenId[] memory t) {
        int24 atm = _atm();
        TokenId base = TokenId.wrap(0).addPoolId(POOL.poolId());
        t = new TokenId[](9);
        t[0] = _shortPair(base, atm + 1500, atm - 1500);
        t[1] = _leg(base, 0, 0, 1, atm - 3000, 40);
        t[2] = _leg(base, 0, 1, 1, atm - 3000, 40);
        t[3] = _shortPair(base, atm, atm);
        t[4] = _leg(base, 0, 0, 1, atm + 2000, 100);
        t[5] = _leg(base, 0, 0, 0, atm - 2000, 100);
        t[6] = _leg(base, 0, 0, 0, atm, 0);
        t[7] = _leg(base, 0, 1, 0, atm, 0);
        t[8] = _shortPair(base, atm + ts, atm + ts);
    }

    /// @dev Three fresh accounts go through every operation of the pool. Steps whose name starts with "~" depend
    /// on market state (nothing may be owed) and are only compared between engines.
    function _lifecycle()
        internal
        returns (string[] memory names, bool[] memory oks, bytes4[] memory sels)
    {
        address MAKER = makeAddr("MAKER");
        address TAKER = makeAddr("TAKER");
        address VICTIM = makeAddr("VICTIM");
        _fund(MAKER, 500_000 * S, 200 * R);
        _fund(TAKER, 200_000 * S, 100 * R);
        _fund(VICTIM, 30_000 * S, 10 * R);
        uint128 one = uint128(R);
        uint128 loan = uint128(1_000 * S);

        TokenId[] memory t = _tokens();

        _mint("MAKER sells a strangle", MAKER, t[0], one, false);
        _mint("MAKER sells a far put", MAKER, t[1], 4 * one, false);
        _mint("TAKER buys that put", TAKER, t[2], one, false);
        _mint("MAKER sells an in-range straddle", MAKER, t[3], one / 2, false);
        _mint("TAKER sells a put above spot, swapping", TAKER, t[4], one / 5, true);
        _mint("TAKER sells a call below spot, swapping", TAKER, t[5], one / 5, true);
        _mint(string.concat("MAKER borrows ", symS), MAKER, t[6], loan, false);
        _mint(string.concat("TAKER mints a credit of ", symS), TAKER, t[7], loan, false);
        _mint("VICTIM sells an in-range straddle", VICTIM, t[8], 3 * one, false);

        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 21_600);
        _step(
            "anyone pokes the oracle",
            KEEPER,
            address(POOL),
            abi.encodeCall(POOL.pokeOracle, ())
        );
        _step(
            string.concat("anyone accrues ", symS, " interest"),
            KEEPER,
            address(ctS),
            abi.encodeWithSignature("accrueInterest()")
        );
        _step(
            string.concat("anyone accrues ", symR, " interest"),
            KEEPER,
            address(ctR),
            abi.encodeWithSignature("accrueInterest()")
        );
        _step(
            "MAKER passes the withdrawal solvency check",
            MAKER,
            address(POOL),
            abi.encodeCall(POOL.validateCollateralWithdrawable, (MAKER, books[MAKER], false))
        );
        _step(
            "MAKER settles the strangle",
            MAKER,
            address(POOL),
            abi.encodeCall(
                POOL.dispatch,
                (_one(t[0]), books[MAKER], _size(one), _limits(1, false), false, 0)
            )
        );
        _step(
            string.concat("MAKER withdraws 1,000 ", symS, " with positions open"),
            MAKER,
            address(ctS),
            abi.encodeWithSignature(
                "withdraw(uint256,address,address,uint256[],bool)",
                loan,
                MAKER,
                MAKER,
                books[MAKER],
                false
            )
        );
        _lifecycleThirdParty(TAKER, VICTIM, t[2]);

        _burn("TAKER closes the put, swapping", TAKER, t[4], true);
        _burn("TAKER closes the call, swapping", TAKER, t[5], true);
        _burn("TAKER closes the credit", TAKER, t[7], false);
        _burn("MAKER repays the loan", MAKER, t[6], false);
        _burn("MAKER closes the straddle", MAKER, t[3], false);
        _burn("MAKER closes the far put", MAKER, t[1], false);
        _burn("MAKER closes the strangle", MAKER, t[0], false);
        _redeemAll("MAKER", MAKER);
        _redeemAll("TAKER", TAKER);
        sName.push("MAKER, TAKER and VICTIM hold no legs");
        sOk.push(
            POOL.numberOfLegs(MAKER) + POOL.numberOfLegs(TAKER) + POOL.numberOfLegs(VICTIM) == 0
        );
        sSel.push(bytes4(0));
        console2.log("  out, dollar token and thousandths of the other:");
        console2.log("    MAKER", stable.balanceOf(MAKER) / S, risky.balanceOf(MAKER) / (R / 1000));
        console2.log("    TAKER", stable.balanceOf(TAKER) / S, risky.balanceOf(TAKER) / (R / 1000));

        names = sName;
        oks = sOk;
        sels = sSel;
    }

    /// @dev Settle of a long's premium, force exercise and liquidation, each by KEEPER.
    function _lifecycleThirdParty(address TAKER, address VICTIM, TokenId long) internal {
        TokenId[] memory book = books[TAKER];
        uint256 at;
        for (uint256 i; i < book.length; ++i)
            if (TokenId.unwrap(book[i]) == TokenId.unwrap(long)) at = i;
        _step(
            "~KEEPER settles TAKER's long premium",
            KEEPER,
            address(POOL),
            abi.encodeCall(
                POOL.dispatchFrom,
                (empty, TAKER, _lastIs(book, at), _lastIs(book, at), LeftRightUnsigned.wrap(0))
            )
        );
        if (
            _step(
                "KEEPER force-exercises TAKER's long put",
                KEEPER,
                address(POOL),
                abi.encodeCall(
                    POOL.dispatchFrom,
                    (empty, TAKER, _lastIs(book, at), _without(book, at), LeftRightUnsigned.wrap(0))
                )
            )
        ) _drop(TAKER, long);

        _slash(VICTIM, _cutsToInsolvency(VICTIM, books[VICTIM]));
        _step(
            "KEEPER liquidates VICTIM",
            KEEPER,
            address(POOL),
            abi.encodeCall(
                POOL.dispatchFrom,
                (empty, VICTIM, books[VICTIM], empty, LeftRightUnsigned.wrap(0))
            )
        );
    }

    /// @dev Every step goes through on the release, and no step that goes through on the live engine fails on it.
    function test_fresh_everyOperationGoesThrough() public {
        string[] memory names;
        bool[] memory before;
        bytes4[] memory sels;
        if (!preUpgraded) {
            uint256 snap = vm.snapshotState();
            (names, before, sels) = _lifecycle();
            vm.revertToStateAndDelete(snap);
        }
        _upgrade();
        bool[] memory oks;
        (names, oks, sels) = _lifecycle();

        uint256 failed;
        for (uint256 i; i < names.length; ++i) {
            bool soft = bytes(names[i])[0] == "~";
            console2.log(oks[i] ? "  ok    " : (soft ? "  n/a   " : "  FAIL  "), names[i]);
            if (!oks[i]) console2.logBytes4(sels[i]);
            if (!preUpgraded && before[i] && !oks[i]) ++failed;
            else if (!oks[i] && !soft) ++failed;
        }
        assertEq(failed, 0, "an operation fails on the release");
    }

    /*//////////////////////////////////////////////////////////////
                         GUARDIAN AND ROLLBACK
    //////////////////////////////////////////////////////////////*/

    function test_guardianLocksAndUnlocksThroughTheRelease() public {
        _upgrade();
        address guardian = re.GUARDIAN();
        vm.prank(guardian);
        re.lockPool(POOL);
        assertGt(POOL.isSafeMode(), 1, "locked");
        vm.prank(guardian);
        re.unlockPool(POOL);
        assertLe(POOL.isSafeMode(), 1, "unlocked");
    }

    /// @dev Pointing the proxy back at the implementation that is live today restores every close outcome.
    function test_rollbackRestoresEveryCloseOutcome() public {
        if (preUpgraded) {
            vm.skip(true);
            return;
        }
        _buildCloseAll();
        ct0.accrueInterest();
        ct1.accrueInterest();
        bytes[] memory before = _runAll(0);
        _upgrade();
        _upgradeTo(liveImpl);
        bytes[] memory restored = _runAll(0);
        for (uint256 i; i < before.length; ++i)
            assertEq(keccak256(restored[i]), keccak256(before[i]), aName[i]);
    }
}
