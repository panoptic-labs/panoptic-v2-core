// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BuilderWallet, BuilderFactory} from "@contracts/Builder.sol";
import {Errors} from "@libraries/Errors.sol";

contract CovERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev USDT-style token: `transfer` returns nothing.
contract CovNoReturnERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Reports a balance but refuses to move it.
contract CovFrozenERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @notice Fills the coverage gaps left in `contracts/Builder.sol` by the rest of the suite:
/// - `BuilderWallet.sweep`, which had no tests
/// - `BuilderWallet.init` guards and plain ETH receipt
/// - `BuilderFactory` constructor and owner guards, and the CREATE2 collision revert
contract BuilderCoverageTest is Test {
    event BuilderWalletInitialized(address indexed builderAdmin);
    event TokensSwept(address indexed token, address indexed to, uint256 amount);
    event BuilderWalletDeployed(
        uint48 indexed builderCode,
        address indexed wallet,
        address indexed builderAdmin
    );

    address internal constant OWNER = address(0xA11CE);
    address internal constant ADMIN = address(0xC0DE);
    address internal constant RECIPIENT = address(0xFEE);

    BuilderFactory internal factory;
    BuilderWallet internal wallet;

    function setUp() public {
        factory = new BuilderFactory(OWNER);
        vm.prank(OWNER);
        wallet = BuilderWallet(payable(factory.deployBuilder(1, ADMIN)));
    }

    /*//////////////////////////////////////////////////////////////
                                 SWEEP
    //////////////////////////////////////////////////////////////*/

    function test_sweep_revertsForNonAdmin(address caller) public {
        vm.assume(caller != ADMIN);
        CovERC20 token = new CovERC20();
        token.mint(address(wallet), 100);

        vm.prank(caller);
        vm.expectRevert(Errors.NotBuilder.selector);
        wallet.sweep(address(token), caller);

        assertEq(token.balanceOf(address(wallet)), 100, "funds stay");
    }

    function test_sweep_revertsForFactoryOwner() public {
        // deploying the wallet gives the factory owner no claim on its funds
        CovERC20 token = new CovERC20();
        token.mint(address(wallet), 100);

        vm.prank(OWNER);
        vm.expectRevert(Errors.NotBuilder.selector);
        wallet.sweep(address(token), OWNER);
    }

    function test_sweep_transfersFullBalance(uint256 amount) public {
        amount = bound(amount, 1, type(uint256).max);
        CovERC20 token = new CovERC20();
        token.mint(address(wallet), amount);

        vm.expectEmit(true, true, true, true, address(wallet));
        emit TokensSwept(address(token), RECIPIENT, amount);
        vm.prank(ADMIN);
        wallet.sweep(address(token), RECIPIENT);

        assertEq(token.balanceOf(address(wallet)), 0, "wallet emptied");
        assertEq(token.balanceOf(RECIPIENT), amount, "recipient credited");
    }

    function test_sweep_zeroBalanceEmitsAndSkipsTransfer() public {
        CovERC20 token = new CovERC20();

        vm.expectEmit(true, true, true, true, address(wallet));
        emit TokensSwept(address(token), RECIPIENT, 0);
        // no call to `transfer` is made on the empty path
        vm.expectCall(address(token), abi.encodeWithSelector(CovERC20.transfer.selector), 0);
        vm.prank(ADMIN);
        wallet.sweep(address(token), RECIPIENT);

        assertEq(token.balanceOf(RECIPIENT), 0);
    }

    function test_sweep_tokenWithoutReturnValue(uint256 amount) public {
        amount = bound(amount, 1, type(uint256).max);
        CovNoReturnERC20 token = new CovNoReturnERC20();
        token.mint(address(wallet), amount);

        vm.prank(ADMIN);
        wallet.sweep(address(token), RECIPIENT);

        assertEq(token.balanceOf(address(wallet)), 0, "wallet emptied");
        assertEq(token.balanceOf(RECIPIENT), amount, "recipient credited");
    }

    function test_sweep_revertsWhenTransferFails() public {
        CovFrozenERC20 token = new CovFrozenERC20();
        token.mint(address(wallet), 100);

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.TransferFailed.selector,
                address(token),
                address(wallet),
                100,
                100
            )
        );
        wallet.sweep(address(token), RECIPIENT);
    }

    function test_sweep_secondSweepIsEmpty() public {
        CovERC20 token = new CovERC20();
        token.mint(address(wallet), 5);

        vm.startPrank(ADMIN);
        wallet.sweep(address(token), RECIPIENT);

        vm.expectEmit(true, true, true, true, address(wallet));
        emit TokensSwept(address(token), RECIPIENT, 0);
        wallet.sweep(address(token), RECIPIENT);
        vm.stopPrank();

        assertEq(token.balanceOf(RECIPIENT), 5);
    }

    /*//////////////////////////////////////////////////////////////
                             INIT / RECEIVE
    //////////////////////////////////////////////////////////////*/

    function test_init_revertsWhenAlreadyInitialized(address caller, address newAdmin) public {
        vm.prank(caller);
        vm.expectRevert(Errors.AlreadyInitialized.selector);
        wallet.init(newAdmin);

        assertEq(wallet.builderAdmin(), ADMIN, "admin unchanged");
    }

    function test_init_revertsOnZeroAdmin() public {
        BuilderWallet fresh = new BuilderWallet(address(factory));

        vm.expectRevert(Errors.ZeroAddress.selector);
        fresh.init(address(0));

        assertEq(fresh.builderAdmin(), address(0), "still uninitialized");
    }

    function test_init_setsAdminOnce(address admin) public {
        vm.assume(admin != address(0));
        BuilderWallet fresh = new BuilderWallet(address(factory));

        vm.expectEmit(true, true, true, true, address(fresh));
        emit BuilderWalletInitialized(admin);
        fresh.init(admin);

        assertEq(fresh.builderAdmin(), admin);
        assertEq(fresh.BUILDER_FACTORY(), address(factory));
    }

    function test_receive_acceptsPlainETH(uint96 amount) public {
        vm.deal(address(this), amount);

        (bool ok, ) = address(wallet).call{value: amount}("");

        assertTrue(ok, "transfer accepted");
        assertEq(address(wallet).balance, amount);
    }

    function test_receive_thenAdminWithdrawsViaExecute(uint96 amount) public {
        vm.deal(address(this), amount);
        payable(address(wallet)).transfer(amount);

        vm.prank(ADMIN);
        wallet.execute(RECIPIENT, amount, "");

        assertEq(address(wallet).balance, 0);
        assertEq(RECIPIENT.balance, amount);
    }

    /*//////////////////////////////////////////////////////////////
                             BUILDER FACTORY
    //////////////////////////////////////////////////////////////*/

    function test_factoryConstructor_revertsOnZeroOwner() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new BuilderFactory(address(0));
    }

    function test_deployBuilder_revertsForNonOwner(address caller) public {
        vm.assume(caller != OWNER);

        vm.prank(caller);
        vm.expectRevert(bytes("NOT_OWNER"));
        factory.deployBuilder(2, ADMIN);

        assertEq(factory.predictBuilderWallet(2).code.length, 0, "nothing deployed");
    }

    function test_deployBuilder_revertsOnReusedBuilderCode(address otherAdmin) public {
        // code 1 was deployed in setUp: the CREATE2 address is taken whatever admin is requested
        vm.prank(OWNER);
        vm.expectRevert(bytes("CREATE2 failed"));
        factory.deployBuilder(1, otherAdmin);

        assertEq(wallet.builderAdmin(), ADMIN, "existing wallet untouched");
    }

    function test_deployBuilder_revertsOnZeroAdmin() public {
        vm.prank(OWNER);
        vm.expectRevert(Errors.ZeroAddress.selector);
        factory.deployBuilder(2, address(0));

        // the whole deployment rolled back, so the code can still be used
        assertEq(factory.predictBuilderWallet(2).code.length, 0, "nothing deployed");
        vm.prank(OWNER);
        factory.deployBuilder(2, ADMIN);
    }

    function test_deployBuilder_matchesPrediction(uint48 builderCode, address admin) public {
        vm.assume(builderCode != 1 && admin != address(0));
        address predicted = factory.predictBuilderWallet(builderCode);

        vm.expectEmit(true, true, true, true, address(factory));
        emit BuilderWalletDeployed(builderCode, predicted, admin);
        vm.prank(OWNER);
        address deployed = factory.deployBuilder(builderCode, admin);

        assertEq(deployed, predicted, "deterministic address");
        assertEq(BuilderWallet(payable(deployed)).builderAdmin(), admin);
        assertEq(BuilderWallet(payable(deployed)).BUILDER_FACTORY(), address(factory));
    }
}
