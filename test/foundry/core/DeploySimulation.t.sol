// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";
import {RiskEngineStub} from "@contracts/RiskEngineStub.sol";
import {BuilderFactory} from "@contracts/Builder.sol";

interface ICreate3Deployer {
    function mint(address to, uint256 id, uint8 nonce) external;

    function deploy(uint256 id, bytes calldata initcode) external payable returns (address);
}

/// @notice Replays the RiskEngine release batches against a live mainnet fork, as the deploying Safe would.
/// Proves the CREATE3 derivations, the proxy's implementation check and the engine's BuilderWallet init code
/// hash check against the real BuilderFactory. Run with ETH_RPC_URL set (no pinned fork block):
///   ETH_RPC_URL=... forge test --match-path test/foundry/core/DeploySimulation.t.sol -vv
contract DeploySimulation is Test {
    // JSON fields decode in alphabetical order
    struct Entry {
        address addr;
        string contractName;
        bytes initcode;
        uint256 nonce;
        bytes32 salt;
    }

    ICreate3Deployer constant DEPLOYER =
        ICreate3Deployer(0x000000000000b361194cfe6312EE3210d53C15AA);
    address constant SAFE = 0x82BF455e9ebd6a541EF10b683dE1edCaf05cE7A1;
    address constant GUARDIAN = 0x0000000000000D329aCC1514f4Ba05584a8369ed;
    BuilderFactory constant FACTORY = BuilderFactory(0x0000000000000a3D22E158417AA639D7F71b0FF7);
    address constant OWNER = 0x8DFEAA4AEe4596b90EF581d7731E4E0b7AbA3221;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true); // fork simulation only runs when an RPC is supplied
            return;
        }
        vm.createSelectFork(rpc);
        assertGt(address(FACTORY).code.length, 0, "factory live");
        assertGt(GUARDIAN.code.length, 0, "guardian live");
    }

    function _replay(string memory path) internal returns (Entry[] memory entries) {
        bytes memory raw = vm.parseJson(vm.readFile(path), ".logicContracts");
        entries = abi.decode(raw, (Entry[]));
        for (uint256 i; i < entries.length; ++i) {
            Entry memory e = entries[i];
            assertEq(e.addr.code.length, 0, string.concat(e.contractName, ": slot already used"));
            vm.startPrank(SAFE);
            DEPLOYER.mint(SAFE, uint256(e.salt), uint8(e.nonce));
            DEPLOYER.deploy(uint256(e.salt), e.initcode);
            vm.stopPrank();
            assertGt(
                e.addr.code.length,
                0,
                string.concat(e.contractName, ": no code at expected address")
            );
            console2.log(e.contractName, e.addr, e.addr.code.length);
        }
    }

    function _proxyAdminOwner(address proxy) internal view returns (address) {
        bytes32 ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        address admin = address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));
        (, bytes memory ret) = admin.staticcall(abi.encodeWithSignature("owner()"));
        return abi.decode(ret, (address));
    }

    function test_replayReleaseBatches() public {
        _replay("deployment-info-RiskEngine.json");
        _replay("deployment-info-RiskEngineXStocks.json");

        IRiskEngine blue = IRiskEngine(0x000000000000ffE5eFdB5AE76b9200263C58b4c0);
        IRiskEngine xstocks = IRiskEngine(0x000000000000FfADa7c641E2aD6B13b51b50Cc94);

        // engines behind their proxies
        assertEq(blue.vegoid(), 8);
        assertEq(blue.CROSS_BUFFER_0(), 9_000_000);
        assertEq(blue.CROSS_BUFFER_1(), 9_000_000);
        assertEq(blue.GUARDIAN(), GUARDIAN);
        assertEq(blue.BUILDER_FACTORY(), address(FACTORY));
        assertEq(xstocks.CROSS_BUFFER_0(), 7_500_000);
        assertEq(xstocks.CROSS_BUFFER_1(), 7_500_000);
        assertEq(xstocks.vegoid(), 8);

        // ProxyAdmin ownership
        assertEq(_proxyAdminOwner(address(blue)), OWNER, "blue-chip ProxyAdmin owner");
        assertEq(_proxyAdminOwner(address(xstocks)), OWNER, "xStocks ProxyAdmin owner");
        assertEq(
            _proxyAdminOwner(0x000000000000ff1F72EB9b4a215DDac4d9dDa3dA),
            OWNER,
            "reserved A owner"
        );
        assertEq(
            _proxyAdminOwner(0x000000000000Ff944ed41CbFa03edc0b477cBbf4),
            OWNER,
            "reserved B owner"
        );

        // reserved proxies refuse everything until upgraded
        vm.expectRevert(RiskEngineStub.RiskEngineNotSet.selector);
        IRiskEngine(0x000000000000ff1F72EB9b4a215DDac4d9dDa3dA).vegoid();
        vm.expectRevert(RiskEngineStub.RiskEngineNotSet.selector);
        IRiskEngine(0x000000000000Ff944ed41CbFa03edc0b477cBbf4).vegoid();

        // builder wallet derivation agrees with the live factory for any wallet it already deployed
        uint256 checked;
        for (uint48 code = 1; code < 200 && checked < 3; ++code) {
            address predicted = FACTORY.predictBuilderWallet(code);
            if (predicted.code.length == 0) continue;
            assertEq(blue.getFeeRecipient(code), predicted, "blue-chip fee recipient");
            assertEq(xstocks.getFeeRecipient(code), predicted, "xStocks fee recipient");
            ++checked;
        }
        console2.log("deployed builder wallets checked against the engines:", checked);
    }
}
