// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BuilderWallet, BuilderFactory} from "@contracts/Builder.sol";
import {Errors} from "@libraries/Errors.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @dev Target that reverts with a custom error
contract RevertsWithReason {
    error CustomError(uint256 code);

    function doRevert() external pure {
        revert CustomError(42);
    }
}

/// @dev Target that reverts without a reason (empty returndata)
contract RevertsEmpty {
    function doRevert() external pure {
        revert();
    }
}

/// @dev Target that returns a value
contract Echo {
    function echo(uint256 x) external pure returns (uint256) {
        return x;
    }
}

/// @dev Target that accepts ETH
contract ETHSink {
    receive() external payable {}

    function balance() external view returns (uint256) {
        return address(this).balance;
    }
}

/// @dev Smart contract admin that implements ERC-1271
contract SmartAdmin {
    address public signer;

    constructor(address _signer) {
        signer = _signer;
    }

    function isValidSignature(
        bytes32 hash,
        bytes calldata signature
    ) external view returns (bytes4) {
        // Recover signer from signature
        (uint8 v, bytes32 r, bytes32 s) = abi.decode(signature, (uint8, bytes32, bytes32));
        address recovered = ecrecover(hash, v, r, s);
        if (recovered == signer) {
            return IERC1271.isValidSignature.selector;
        }
        return bytes4(0xffffffff);
    }
}

contract BuilderWalletTest is Test {
    BuilderWallet internal wallet;
    BuilderFactory internal factory;

    address internal admin;
    uint256 internal adminKey;
    address internal other = address(0xBEEF);

    function setUp() external {
        (admin, adminKey) = makeAddrAndKey("admin");
        factory = new BuilderFactory(address(this));
        address deployed = factory.deployBuilder(1, admin);
        wallet = BuilderWallet(payable(deployed));
    }

    /*//////////////////////////////////////////////////////////////
                              EXECUTE
    //////////////////////////////////////////////////////////////*/

    function testExecuteCallsTarget() external {
        Echo echo = new Echo();
        vm.prank(admin);
        bytes memory result = wallet.execute(address(echo), 0, abi.encodeCall(Echo.echo, (123)));
        assertEq(abi.decode(result, (uint256)), 123);
    }

    function testExecuteEmitsEvent() external {
        Echo echo = new Echo();
        bytes memory data = abi.encodeCall(Echo.echo, (999));

        vm.expectEmit(true, false, false, true, address(wallet));
        emit BuilderWallet.Executed(address(echo), 0, data);

        vm.prank(admin);
        wallet.execute(address(echo), 0, data);
    }

    function testExecuteSendsETH() external {
        ETHSink sink = new ETHSink();

        // Fund the wallet with a clean balance
        uint256 sendAmount = 0.5 ether;
        vm.deal(address(wallet), sendAmount);
        uint256 sinkBefore = address(sink).balance;

        vm.prank(admin);
        wallet.execute(address(sink), sendAmount, "");

        assertEq(address(sink).balance, sinkBefore + sendAmount);
        assertEq(address(wallet).balance, 0);
    }

    function testExecuteRevertsIfNotAdmin() external {
        vm.prank(other);
        vm.expectRevert(Errors.NotBuilder.selector);
        wallet.execute(address(0x1), 0, "");
    }

    function testExecuteBubblesRevertReason() external {
        RevertsWithReason target = new RevertsWithReason();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RevertsWithReason.CustomError.selector, 42));
        wallet.execute(address(target), 0, abi.encodeCall(RevertsWithReason.doRevert, ()));
    }

    function testExecuteRevertsWithExecuteFailedOnEmptyRevert() external {
        RevertsEmpty target = new RevertsEmpty();

        vm.prank(admin);
        vm.expectRevert(Errors.ExecuteFailed.selector);
        wallet.execute(address(target), 0, abi.encodeCall(RevertsEmpty.doRevert, ()));
    }

    /*//////////////////////////////////////////////////////////////
                          IS VALID SIGNATURE
    //////////////////////////////////////////////////////////////*/

    function testIsValidSignatureWithEOAAdmin() external view {
        bytes32 hash = keccak256("test message");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adminKey, hash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes4 result = wallet.isValidSignature(hash, signature);
        assertEq(result, IERC1271.isValidSignature.selector);
    }

    function testIsValidSignatureRejectsWrongSigner() external {
        bytes32 hash = keccak256("test message");
        (, uint256 wrongKey) = makeAddrAndKey("wrong");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, hash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes4 result = wallet.isValidSignature(hash, signature);
        assertEq(result, bytes4(0xffffffff));
    }

    function testIsValidSignatureWithSmartContractAdmin() external {
        // Deploy a smart contract admin that delegates to a known signer
        (address signer, uint256 signerKey) = makeAddrAndKey("signer");
        SmartAdmin smartAdmin = new SmartAdmin(signer);

        // Deploy a new wallet with the smart contract as admin
        BuilderWallet scWallet = new BuilderWallet(address(factory));
        scWallet.init(address(smartAdmin));

        bytes32 hash = keccak256("test message");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, hash);
        // SmartAdmin expects abi.encode(v, r, s)
        bytes memory signature = abi.encode(v, r, s);

        bytes4 result = scWallet.isValidSignature(hash, signature);
        assertEq(result, IERC1271.isValidSignature.selector);
    }

    /*//////////////////////////////////////////////////////////////
                              RECEIVE
    //////////////////////////////////////////////////////////////*/

    function testReceiveETH() external {
        vm.deal(other, 1 ether);
        vm.prank(other);
        (bool success, ) = address(wallet).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(wallet).balance, 1 ether);
    }
}
