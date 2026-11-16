// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Errors} from "@libraries/Errors.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";

contract SafeTransferLibHarness {
    function safeTransferETH(address to, uint256 amount) external {
        SafeTransferLib.safeTransferETH(to, amount);
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) external {
        SafeTransferLib.safeTransferFrom(token, from, to, amount);
    }

    function safeTransfer(address token, address to, uint256 amount) external {
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    function balanceOfOrZero(address token, address who) external view returns (uint256) {
        return SafeTransferLib.balanceOfOrZero(token, who);
    }

    receive() external payable {}
}

/// @dev Minimal ERC20 whose transfer functions answer according to `mode`.
contract ModalERC20 {
    enum Mode {
        Standard,
        NoReturn,
        ReturnsFalse,
        Reverts,
        ReturnsTwo
    }

    Mode public mode;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(Mode _mode) {
        mode = _mode;
    }

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal {
        if (mode == Mode.Reverts) revert("transfer disabled");
        if (mode == Mode.ReturnsFalse) _return(0);

        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        if (mode == Mode.Standard) _return(1);
        if (mode == Mode.ReturnsTwo) _return(2);
        // Mode.NoReturn falls through with empty return data
    }

    function _return(uint256 value) internal pure {
        assembly {
            mstore(0, value)
            return(0, 32)
        }
    }
}

contract ETHRejecter {
    receive() external payable {
        revert("no ETH");
    }
}

contract ETHAccepter {
    receive() external payable {}
}

/// @notice Fills the coverage gaps left in `contracts/libraries/SafeTransferLib.sol` by the rest of the suite:
/// `safeTransferETH`, and both outcomes of `safeTransferFrom` and `safeTransfer`.
/// @dev The two failure arms of `balanceOfOrZero` (a reverting or short-returning `balanceOf`) are deliberately
/// not exercised: the function does not return zero there, see the known issue on `balanceOfOrZero`.
contract SafeTransferLibCoverageTest is Test {
    SafeTransferLibHarness internal harness;

    // fresh addresses: the suite runs against a fork, where short literal addresses can hold balances
    address internal FROM;
    address internal TO;

    function setUp() public {
        harness = new SafeTransferLibHarness();
        FROM = makeAddr("from");
        TO = makeAddr("to");
    }

    function _token(ModalERC20.Mode mode) internal returns (ModalERC20 token) {
        token = new ModalERC20(mode);
    }

    /*//////////////////////////////////////////////////////////////
                            safeTransferETH
    //////////////////////////////////////////////////////////////*/

    function test_safeTransferETH_toEOA(uint96 balance, uint96 amount) public {
        amount = uint96(bound(amount, 0, balance));
        vm.deal(address(harness), balance);

        harness.safeTransferETH(TO, amount);

        assertEq(TO.balance, amount, "recipient");
        assertEq(address(harness).balance, balance - amount, "sender");
    }

    function test_safeTransferETH_toAcceptingContract(uint96 amount) public {
        address to = address(new ETHAccepter());
        vm.deal(address(harness), amount);

        harness.safeTransferETH(to, amount);

        assertEq(to.balance, amount);
    }

    function test_safeTransferETH_revertsWhenRecipientRejects(uint96 amount) public {
        address to = address(new ETHRejecter());
        vm.deal(address(harness), amount);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.TransferFailed.selector,
                address(0),
                address(harness),
                uint256(amount),
                uint256(amount)
            )
        );
        harness.safeTransferETH(to, amount);
    }

    function test_safeTransferETH_revertsOnInsufficientBalance(
        uint96 balance,
        uint96 excess
    ) public {
        excess = uint96(bound(excess, 1, type(uint96).max));
        uint256 amount = uint256(balance) + excess;
        vm.deal(address(harness), balance);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.TransferFailed.selector,
                address(0),
                address(harness),
                amount,
                uint256(balance)
            )
        );
        harness.safeTransferETH(TO, amount);

        assertEq(TO.balance, 0, "nothing sent");
    }

    /*//////////////////////////////////////////////////////////////
                            safeTransferFrom
    //////////////////////////////////////////////////////////////*/

    function _assertTransferFromSucceeds(ModalERC20.Mode mode, uint256 amount) internal {
        ModalERC20 token = _token(mode);
        token.mint(FROM, amount);
        vm.prank(FROM);
        token.approve(address(harness), amount);

        harness.safeTransferFrom(address(token), FROM, TO, amount);

        assertEq(token.balanceOf(FROM), 0, "from");
        assertEq(token.balanceOf(TO), amount, "to");
    }

    function _assertTransferFromFails(
        ModalERC20.Mode mode,
        uint256 balance,
        uint256 amount
    ) internal {
        ModalERC20 token = _token(mode);
        token.mint(FROM, balance);
        vm.prank(FROM);
        token.approve(address(harness), type(uint256).max);

        // the error reports the payer's balance, not the harness's
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.TransferFailed.selector,
                address(token),
                FROM,
                amount,
                balance
            )
        );
        harness.safeTransferFrom(address(token), FROM, TO, amount);
    }

    function test_safeTransferFrom_standardToken(uint256 amount) public {
        _assertTransferFromSucceeds(ModalERC20.Mode.Standard, amount);
    }

    function test_safeTransferFrom_tokenWithoutReturnValue(uint256 amount) public {
        _assertTransferFromSucceeds(ModalERC20.Mode.NoReturn, amount);
    }

    function test_safeTransferFrom_revertsWhenTokenReturnsFalse(
        uint256 balance,
        uint256 amount
    ) public {
        _assertTransferFromFails(ModalERC20.Mode.ReturnsFalse, balance, amount);
    }

    function test_safeTransferFrom_revertsWhenTokenReverts(uint256 balance, uint256 amount) public {
        _assertTransferFromFails(ModalERC20.Mode.Reverts, balance, amount);
    }

    function test_safeTransferFrom_revertsWhenTokenReturnsNonOne(uint256 amount) public {
        // a truthy value other than exactly 1 is not accepted
        ModalERC20 token = _token(ModalERC20.Mode.ReturnsTwo);
        token.mint(FROM, amount);
        vm.prank(FROM);
        token.approve(address(harness), amount);

        // the token did move the funds before answering, so the balance read for the error is already zero
        vm.expectRevert(
            abi.encodeWithSelector(Errors.TransferFailed.selector, address(token), FROM, amount, 0)
        );
        harness.safeTransferFrom(address(token), FROM, TO, amount);

        // and the revert undoes that move
        assertEq(token.balanceOf(FROM), amount, "from restored");
        assertEq(token.balanceOf(TO), 0, "to restored");
    }

    function test_safeTransferFrom_revertsOnInsufficientBalance(
        uint256 balance,
        uint256 amount
    ) public {
        balance = bound(balance, 0, type(uint256).max - 1);
        amount = bound(amount, balance + 1, type(uint256).max);

        _assertTransferFromFails(ModalERC20.Mode.Standard, balance, amount);
    }

    function test_safeTransferFrom_revertsWithoutAllowance(uint256 amount) public {
        amount = bound(amount, 1, type(uint256).max);
        ModalERC20 token = _token(ModalERC20.Mode.Standard);
        token.mint(FROM, amount);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.TransferFailed.selector,
                address(token),
                FROM,
                amount,
                amount
            )
        );
        harness.safeTransferFrom(address(token), FROM, TO, amount);
    }

    /*//////////////////////////////////////////////////////////////
                              safeTransfer
    //////////////////////////////////////////////////////////////*/

    function _assertTransferSucceeds(ModalERC20.Mode mode, uint256 amount) internal {
        ModalERC20 token = _token(mode);
        token.mint(address(harness), amount);

        harness.safeTransfer(address(token), TO, amount);

        assertEq(token.balanceOf(address(harness)), 0, "from");
        assertEq(token.balanceOf(TO), amount, "to");
    }

    function _assertTransferFails(ModalERC20.Mode mode, uint256 balance, uint256 amount) internal {
        ModalERC20 token = _token(mode);
        token.mint(address(harness), balance);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.TransferFailed.selector,
                address(token),
                address(harness),
                amount,
                balance
            )
        );
        harness.safeTransfer(address(token), TO, amount);
    }

    function test_safeTransfer_standardToken(uint256 amount) public {
        _assertTransferSucceeds(ModalERC20.Mode.Standard, amount);
    }

    function test_safeTransfer_tokenWithoutReturnValue(uint256 amount) public {
        _assertTransferSucceeds(ModalERC20.Mode.NoReturn, amount);
    }

    function test_safeTransfer_revertsWhenTokenReturnsFalse(
        uint256 balance,
        uint256 amount
    ) public {
        _assertTransferFails(ModalERC20.Mode.ReturnsFalse, balance, amount);
    }

    function test_safeTransfer_revertsWhenTokenReverts(uint256 balance, uint256 amount) public {
        _assertTransferFails(ModalERC20.Mode.Reverts, balance, amount);
    }

    function test_safeTransfer_revertsWhenTokenReturnsNonOne(uint256 amount) public {
        ModalERC20 token = _token(ModalERC20.Mode.ReturnsTwo);
        token.mint(address(harness), amount);

        // the token did move the funds before answering, so the balance read for the error is already zero
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.TransferFailed.selector,
                address(token),
                address(harness),
                amount,
                0
            )
        );
        harness.safeTransfer(address(token), TO, amount);

        assertEq(token.balanceOf(address(harness)), amount, "from restored");
        assertEq(token.balanceOf(TO), 0, "to restored");
    }

    function test_safeTransfer_revertsOnInsufficientBalance(
        uint256 balance,
        uint256 amount
    ) public {
        balance = bound(balance, 0, type(uint256).max - 1);
        amount = bound(amount, balance + 1, type(uint256).max);

        _assertTransferFails(ModalERC20.Mode.Standard, balance, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            balanceOfOrZero
    //////////////////////////////////////////////////////////////*/

    function test_balanceOfOrZero_readsBalance(address who, uint256 balance) public {
        ModalERC20 token = _token(ModalERC20.Mode.Standard);
        token.mint(who, balance);

        assertEq(harness.balanceOfOrZero(address(token), who), balance);
    }
}
