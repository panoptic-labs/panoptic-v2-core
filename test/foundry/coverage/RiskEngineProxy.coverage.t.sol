// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RiskEngineProxy} from "@contracts/RiskEngineProxy.sol";
import {RiskEngineStub} from "@contracts/RiskEngineStub.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

contract CovImplementationA {
    function vegoid() external pure returns (uint256) {
        return 4;
    }
}

contract CovImplementationB {
    function vegoid() external pure returns (uint256) {
        return 8;
    }
}

/// @notice Exercises the `RiskEngineProxy` constructor directly: implementation and admin wiring, no initializer.
contract RiskEngineProxyCoverageTest is Test {
    address internal owner = makeAddr("proxy admin owner");

    function _admin(address proxy) internal view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(proxy, ERC1967Utils.ADMIN_SLOT)))));
    }

    function _implementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    function test_constructor_wiresImplementationAndAdmin(address initialOwner) public {
        vm.assume(initialOwner != address(0));
        address implementation = address(new CovImplementationA());

        RiskEngineProxy proxy = new RiskEngineProxy(implementation, initialOwner);

        assertEq(_implementation(address(proxy)), implementation, "implementation slot");
        assertEq(_admin(address(proxy)).owner(), initialOwner, "ProxyAdmin owner");
        assertEq(CovImplementationA(address(proxy)).vegoid(), 4, "calls reach the implementation");
    }

    function test_constructor_revertsOnZeroOwner() public {
        address implementation = address(new CovImplementationA());

        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("OwnableInvalidOwner(address)")), address(0))
        );
        new RiskEngineProxy(implementation, address(0));
    }

    function test_constructor_revertsOnImplementationWithoutCode() public {
        address notAContract = makeAddr("no code");

        vm.expectRevert(
            abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, notAContract)
        );
        new RiskEngineProxy(notAContract, owner);
    }

    function test_constructor_makesNoInitializerCall() public {
        // the stub reverts on every call, so deployment only succeeds if no initializer is invoked
        RiskEngineProxy proxy = new RiskEngineProxy(address(new RiskEngineStub()), owner);

        vm.expectRevert(RiskEngineStub.RiskEngineNotSet.selector);
        CovImplementationA(address(proxy)).vegoid();
    }

    function test_onlyProxyAdminOwnerCanUpgrade(address caller) public {
        RiskEngineProxy proxy = new RiskEngineProxy(address(new CovImplementationA()), owner);
        ProxyAdmin admin = _admin(address(proxy));
        address next = address(new CovImplementationB());
        vm.assume(caller != owner);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), caller)
        );
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), next, "");

        vm.prank(owner);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), next, "");

        assertEq(_implementation(address(proxy)), next, "implementation swapped");
        assertEq(
            CovImplementationA(address(proxy)).vegoid(),
            8,
            "new logic behind the same address"
        );
    }
}
