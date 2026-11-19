// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC1155} from "@tokens/ERC1155Minimal.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

contract ERC1155MintHarness is ERC1155 {
    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount);
    }
}

/// @dev Has code and answers `onERC1155Received`, but with the wrong magic value.
contract WrongSelectorRecipient {
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return 0xdeadbeef;
    }
}

/// @dev Has code but does not implement the receiver hook at all.
contract NoHookRecipient {

}

/// @dev Records what the hook was called with and accepts the transfer.
contract RecordingRecipient is ERC1155Holder {
    address public operator;
    address public from;
    uint256 public id;
    uint256 public amount;
    bytes public data;

    function onERC1155Received(
        address _operator,
        address _from,
        uint256 _id,
        uint256 _amount,
        bytes memory _data
    ) public override returns (bytes4) {
        (operator, from, id, amount, data) = (_operator, _from, _id, _amount, _data);
        return this.onERC1155Received.selector;
    }
}

/// @notice Fills the coverage gaps left in `contracts/tokens/ERC1155Minimal.sol` by the rest of the suite:
/// the `UnsafeRecipient` revert in `_mint` when a contract recipient returns the wrong magic value.
contract ERC1155MinimalCoverageTest is Test {
    event TransferSingle(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 id,
        uint256 amount
    );

    ERC1155MintHarness internal token;

    function setUp() public {
        token = new ERC1155MintHarness();
    }

    function test_mint_revertsOnWrongMagicValue(uint256 id, uint256 amount) public {
        address recipient = address(new WrongSelectorRecipient());

        vm.expectRevert(ERC1155.UnsafeRecipient.selector);
        token.mint(recipient, id, amount);

        assertEq(token.balanceOf(recipient, id), 0, "balance rolled back");
    }

    function test_mint_revertsWhenRecipientHasNoHook(uint256 id, uint256 amount) public {
        address recipient = address(new NoHookRecipient());

        // the hook call itself fails, so the revert carries no data
        vm.expectRevert(bytes(""));
        token.mint(recipient, id, amount);

        assertEq(token.balanceOf(recipient, id), 0, "balance rolled back");
    }

    function test_mint_toAcceptingContract(address operator, uint256 id, uint256 amount) public {
        RecordingRecipient recipient = new RecordingRecipient();

        vm.expectEmit(true, true, true, true, address(token));
        emit TransferSingle(operator, address(0), address(recipient), id, amount);

        vm.prank(operator);
        token.mint(address(recipient), id, amount);

        assertEq(token.balanceOf(address(recipient), id), amount, "balance");
        assertEq(recipient.operator(), operator, "hook operator");
        assertEq(recipient.from(), address(0), "hook from");
        assertEq(recipient.id(), id, "hook id");
        assertEq(recipient.amount(), amount, "hook amount");
        assertEq(recipient.data().length, 0, "hook data");
    }

    function test_mint_toEOASkipsHook(uint256 id, uint256 amount) public {
        address recipient = makeAddr("eoa");

        token.mint(recipient, id, amount);

        assertEq(token.balanceOf(recipient, id), amount, "balance");
    }
}
