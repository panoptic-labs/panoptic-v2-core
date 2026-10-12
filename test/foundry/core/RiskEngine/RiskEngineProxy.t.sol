// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RiskEngineV2} from "@contracts/RiskEngine.sol";
import {RiskEngineParams} from "../../testUtils/RiskEngineParams.sol";
import {RiskEngineProxy} from "@contracts/RiskEngineProxy.sol";
import {RiskEngineStub} from "@contracts/RiskEngineStub.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";
import {BuilderFactory, BuilderWallet} from "@contracts/Builder.sol";
import {PanopticGuardian} from "@contracts/PanopticGuardian.sol";
import {PanopticPoolV2} from "@contracts/PanopticPool.sol";
import {Errors} from "@libraries/Errors.sol";
import {OraclePack} from "@types/OraclePack.sol";
import {ERC20S} from "../../testUtils/ERC20S.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @dev Minimal stand-in for a PanopticPool: records lock/unlock calls and enforces the risk-engine-only check.
contract MockLockablePool {
    address public immutable RE;
    bool public locked;

    constructor(address re) {
        RE = re;
    }

    function lockSafeMode() external {
        if (msg.sender != RE) revert Errors.NotGuardian();
        locked = true;
    }

    function unlockSafeMode() external {
        if (msg.sender != RE) revert Errors.NotGuardian();
        locked = false;
    }
}

contract RiskEngineProxyTest is Test {
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    address guardianAdmin = makeAddr("guardianAdmin");
    address treasurer = makeAddr("treasurer");
    address multisig = makeAddr("multisig");
    address rando = makeAddr("rando");

    PanopticGuardian guardian;
    BuilderFactory builderFactory;
    bytes32 initCodeHash;
    RiskEngineV2 implV1;
    RiskEngineProxy proxy;
    IRiskEngine re;
    ProxyAdmin proxyAdmin;

    function setUp() public {
        guardian = new PanopticGuardian(guardianAdmin, treasurer);
        builderFactory = new BuilderFactory(address(guardian));
        initCodeHash = keccak256(
            abi.encodePacked(type(BuilderWallet).creationCode, abi.encode(address(builderFactory)))
        );
        implV1 = new RiskEngineV2(
            address(guardian),
            address(builderFactory),
            initCodeHash,
            RiskEngineParams.blueChip(9_000_000, 9_000_000)
        );
        proxy = new RiskEngineProxy(address(implV1), multisig);
        re = IRiskEngine(address(proxy));
        proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT)))));
    }

    function _impl() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(proxy), IMPL_SLOT))));
    }

    /*//////////////////////////////////////////////////////////////
                                WIRING
    //////////////////////////////////////////////////////////////*/

    function test_wiring() public view {
        assertEq(_impl(), address(implV1), "impl slot");
        assertEq(proxyAdmin.owner(), multisig, "ProxyAdmin owner");
        assertEq(re.CROSS_BUFFER_0(), 9_000_000);
        assertEq(re.CROSS_BUFFER_1(), 9_000_000);
        assertEq(re.GUARDIAN(), address(guardian));
        assertEq(re.BUILDER_FACTORY(), address(builderFactory));
        assertEq(re.vegoid(), implV1.VEGOID());
        assertEq(re.DECIMALS(), implV1.DECIMALS());
    }

    /// @dev The default profile (200 runs) is not the release profile; the release optimizer runs are chosen by
    /// script/optimize_runs.py so the implementation fits EIP-170. Guard here only against gross regressions.
    function test_implementationSize_withinReleaseHeadroom() public view {
        assertLe(address(implV1).code.length, 24_576 + 512, "impl far over EIP-170");
    }

    /// @dev Pure functions in IRiskEngine are invoked via STATICCALL; DELEGATECALL inside a static context must succeed.
    function test_pureFunctionThroughProxy() public view {
        OraclePack empty = OraclePack.wrap(0);
        assertEq(re.twapEMA(empty), implV1.twapEMA(empty));
    }

    /*//////////////////////////////////////////////////////////////
                             GUARDIAN PATHS
    //////////////////////////////////////////////////////////////*/

    function test_guardianLockUnlockThroughProxy() public {
        MockLockablePool pool = new MockLockablePool(address(proxy));

        vm.prank(address(guardian));
        re.lockPool(PanopticPoolV2(address(pool)));
        assertTrue(pool.locked(), "locked");

        vm.prank(address(guardian));
        re.unlockPool(PanopticPoolV2(address(pool)));
        assertFalse(pool.locked(), "unlocked");
    }

    function test_nonGuardianCannotLock() public {
        MockLockablePool pool = new MockLockablePool(address(proxy));
        vm.prank(rando);
        vm.expectRevert(Errors.NotGuardian.selector);
        re.lockPool(PanopticPoolV2(address(pool)));
    }

    function test_feesAccrueAtProxyAndGuardianCollects() public {
        ERC20S token = new ERC20S("T", "T", 18);
        token.mint(address(proxy), 1_000e18);
        assertEq(token.balanceOf(address(proxy)), 1_000e18, "proxy holds fees");

        vm.prank(address(guardian));
        re.collect(address(token), treasurer, 400e18);
        assertEq(token.balanceOf(treasurer), 400e18);

        vm.prank(address(guardian));
        re.collect(address(token), treasurer);
        assertEq(token.balanceOf(treasurer), 1_000e18);
        assertEq(token.balanceOf(address(proxy)), 0);
    }

    function test_nonGuardianCannotCollect() public {
        ERC20S token = new ERC20S("T", "T", 18);
        token.mint(address(proxy), 1e18);
        vm.prank(multisig);
        vm.expectRevert(Errors.NotGuardian.selector);
        re.collect(address(token), multisig, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                                UPGRADES
    //////////////////////////////////////////////////////////////*/

    function test_upgradeChangesParametersForCallers() public {
        RiskEngineV2 implV2 = new RiskEngineV2(
            address(guardian),
            address(builderFactory),
            initCodeHash,
            RiskEngineParams.blueChip(7_500_000, 9_500_000)
        );

        vm.prank(multisig);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(implV2),
            ""
        );

        assertEq(_impl(), address(implV2));
        assertEq(re.CROSS_BUFFER_0(), 7_500_000);
        assertEq(re.CROSS_BUFFER_1(), 9_500_000);
        // Fees that accrued at the proxy before the upgrade survive it.
    }

    function test_upgradePreservesProxyBalance() public {
        ERC20S token = new ERC20S("T", "T", 18);
        token.mint(address(proxy), 5e18);

        RiskEngineV2 implV2 = new RiskEngineV2(
            address(guardian),
            address(builderFactory),
            initCodeHash,
            RiskEngineParams.blueChip(1, 1)
        );
        vm.prank(multisig);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(implV2),
            ""
        );

        assertEq(token.balanceOf(address(proxy)), 5e18);
        vm.prank(address(guardian));
        re.collect(address(token), treasurer);
        assertEq(token.balanceOf(treasurer), 5e18);
    }

    function test_nonOwnerCannotUpgrade() public {
        RiskEngineV2 implV2 = new RiskEngineV2(
            address(guardian),
            address(builderFactory),
            initCodeHash,
            RiskEngineParams.blueChip(1, 1)
        );
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(implV2),
            ""
        );
        assertEq(_impl(), address(implV1));
    }

    function test_directUpgradeCallFromNonAdminFallsThroughToImpl() public {
        // Anyone other than the ProxyAdmin hits the implementation, which has no such selector -> revert.
        vm.prank(multisig);
        (bool ok, ) = address(proxy).call(
            abi.encodeWithSelector(
                ITransparentUpgradeableProxy.upgradeToAndCall.selector,
                address(0xdead),
                ""
            )
        );
        assertFalse(ok);
        assertEq(_impl(), address(implV1));
    }

    function test_ownershipHandoffToTimelockThenGovernance() public {
        address timelock = makeAddr("timelock");
        address governance = makeAddr("governance");

        vm.prank(multisig);
        proxyAdmin.transferOwnership(timelock);
        assertEq(proxyAdmin.owner(), timelock);

        RiskEngineV2 implV2 = new RiskEngineV2(
            address(guardian),
            address(builderFactory),
            initCodeHash,
            RiskEngineParams.blueChip(2, 2)
        );
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, multisig)
        );
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(implV2),
            ""
        );

        vm.prank(timelock);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(implV2),
            ""
        );
        assertEq(re.CROSS_BUFFER_0(), 2);

        vm.prank(timelock);
        proxyAdmin.transferOwnership(governance);
        assertEq(proxyAdmin.owner(), governance);
    }

    /// @dev gen_upgrade_safetx.py derives the ProxyAdmin as CREATE(proxy, nonce 1); keep this in sync.
    function test_proxyAdminIsCreateNonce1() public view {
        assertEq(address(proxyAdmin), vm.computeCreateAddress(address(proxy), 1));
    }

    /// @dev Mirrors the --timelock output of gen_upgrade_safetx.py: ProxyAdmin owned by a TimelockController,
    /// Safe is proposer+executor, upgrade is scheduled with scheduleBatch and run with executeBatch.
    function test_timelockScheduleExecuteUpgrade() public {
        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        TimelockController timelock = new TimelockController(
            2 days,
            proposers,
            proposers,
            address(0)
        );

        vm.prank(multisig);
        proxyAdmin.transferOwnership(address(timelock));

        RiskEngineV2 implV2 = new RiskEngineV2(
            address(guardian),
            address(builderFactory),
            initCodeHash,
            RiskEngineParams.blueChip(3, 3)
        );

        address[] memory targets = new address[](1);
        targets[0] = address(proxyAdmin);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(address(proxy)), address(implV2), "")
        );

        vm.prank(multisig);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), 2 days);

        vm.prank(multisig);
        vm.expectRevert();
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));
        assertEq(_impl(), address(implV1), "not yet");

        vm.warp(block.timestamp + 2 days);
        vm.prank(multisig);
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));
        assertEq(_impl(), address(implV2));
        assertEq(re.CROSS_BUFFER_0(), 3);
    }

    /// @dev A reserved proxy fronts RiskEngineStub until its tier is defined: every call reverts, so the factory's
    /// `vegoid()` probe fails and no pool can be created against it. An upgrade brings it into service.
    function test_reservedProxyRevertsUntilUpgraded() public {
        RiskEngineProxy reserved = new RiskEngineProxy(address(new RiskEngineStub()), multisig);
        ProxyAdmin admin = ProxyAdmin(
            address(uint160(uint256(vm.load(address(reserved), ADMIN_SLOT))))
        );

        vm.expectRevert(RiskEngineStub.RiskEngineNotSet.selector);
        IRiskEngine(address(reserved)).vegoid();
        vm.expectRevert(RiskEngineStub.RiskEngineNotSet.selector);
        IRiskEngine(address(reserved)).DECIMALS();

        vm.prank(multisig);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(reserved)), address(implV1), "");
        assertEq(IRiskEngine(address(reserved)).vegoid(), implV1.VEGOID());
    }
}
