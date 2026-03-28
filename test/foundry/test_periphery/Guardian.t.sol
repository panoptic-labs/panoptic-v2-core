// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PanopticPoolV2} from "@contracts/PanopticPool.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";
import {PanopticGuardian} from "@contracts/PanopticGuardian.sol";
import {BuilderFactory} from "@contracts/Builder.sol";

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);
}

contract MockBuilderWallet {
    address public builderAdmin;

    constructor(address _builderAdmin) {
        builderAdmin = _builderAdmin;
    }
}

contract MockBuilderFactory {
    address public immutable OWNER;
    uint48 public lastBuilderCode;
    address public lastBuilderAdmin;
    address public lastWallet;

    constructor(address owner_) {
        OWNER = owner_;
    }

    function deployBuilder(
        uint48 builderCode,
        address builderAdmin
    ) external returns (address wallet) {
        lastBuilderCode = builderCode;
        lastBuilderAdmin = builderAdmin;
        wallet = address(new MockBuilderWallet(builderAdmin));
        lastWallet = wallet;
    }
}

contract MockERC20 is IERC20Like {
    mapping(address => uint256) public balanceOf;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        return true;
    }
}

contract MockRiskEngine {
    address public immutable GUARDIAN;

    mapping(uint256 => address) internal sFeeRecipients;
    uint256 public lockCalls;
    uint256 public unlockCalls;
    uint256 public collectCalls;
    address public lastToken;
    address public lastRecipient;
    uint256 public lastAmount;

    constructor(address guardian_) {
        GUARDIAN = guardian_;
    }

    function setFeeRecipient(uint256 builderCode, address wallet) external {
        sFeeRecipients[builderCode] = wallet;
    }

    function lockPool(PanopticPoolV2) external {
        require(msg.sender == GUARDIAN, "NotGuardian");
        lockCalls++;
    }

    function unlockPool(PanopticPoolV2) external {
        require(msg.sender == GUARDIAN, "NotGuardian");
        unlockCalls++;
    }

    function getFeeRecipient(uint256 builderCode) external view returns (address) {
        address wallet = sFeeRecipients[builderCode];
        require(wallet != address(0), "InvalidBuilderCode");
        return wallet;
    }

    function collect(address token, address recipient, uint256 amount) external {
        require(msg.sender == GUARDIAN, "NotGuardian");
        _collect(token, recipient, amount);
    }

    function collect(address token, address recipient) external {
        require(msg.sender == GUARDIAN, "NotGuardian");

        uint256 amount = IERC20Like(token).balanceOf(address(this));
        _collect(token, recipient, amount);
    }

    function _collect(address token, address recipient, uint256 amount) internal {
        require(amount != 0, "BelowMinimumRedemption");

        require(IERC20Like(token).transfer(recipient, amount), "TransferFailed");
        collectCalls++;
        lastToken = token;
        lastRecipient = recipient;
        lastAmount = amount;
    }
}

contract PartialCollectRiskEngine {
    address public immutable GUARDIAN;

    constructor(address guardian_) {
        GUARDIAN = guardian_;
    }

    function lockPool(PanopticPoolV2) external pure {}

    function unlockPool(PanopticPoolV2) external pure {}

    function getFeeRecipient(uint256) external pure returns (address) {
        revert("unused");
    }

    function collect(address token, address recipient, uint256 amount) external {
        require(msg.sender == GUARDIAN, "NotGuardian");
        require(amount != 0, "BelowMinimumRedemption");
        require(IERC20Like(token).transfer(recipient, amount), "TransferFailed");
    }

    function collect(address token, address recipient) external {
        require(msg.sender == GUARDIAN, "NotGuardian");

        uint256 amount = IERC20Like(token).balanceOf(address(this)) / 2;
        require(amount != 0, "BelowMinimumRedemption");
        require(IERC20Like(token).transfer(recipient, amount), "TransferFailed");
    }
}

contract MockPanopticPool {
    IRiskEngine internal immutable RISK_ENGINE;

    constructor(IRiskEngine riskEngine_) {
        RISK_ENGINE = riskEngine_;
    }

    function riskEngine() external view returns (IRiskEngine) {
        return RISK_ENGINE;
    }
}

contract GuardianTest is Test {
    event TokensCollected(address indexed token, address indexed recipient, uint256 amount);

    address internal constant GUARDIAN_ADMIN = address(0xA11CE);
    address internal constant TREASURER = address(0xB0B);
    address internal constant BUILDER_ADMIN = address(0xC0DE);

    PanopticGuardian internal guardian;
    MockBuilderFactory internal factory;
    MockRiskEngine internal recognizedRiskEngine;
    MockPanopticPool internal recognizedPool;

    function setUp() external {
        guardian = new PanopticGuardian(GUARDIAN_ADMIN, TREASURER);
        factory = new MockBuilderFactory(address(guardian));

        recognizedRiskEngine = new MockRiskEngine(address(guardian));
        recognizedPool = new MockPanopticPool(IRiskEngine(address(recognizedRiskEngine)));
    }

    function testRequestUnlockRevertsForForeignRiskEngine() external {
        MockRiskEngine foreignRiskEngine = new MockRiskEngine(address(0xDEAD));
        MockPanopticPool foreignPool = new MockPanopticPool(
            IRiskEngine(address(foreignRiskEngine))
        );

        vm.prank(GUARDIAN_ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                PanopticGuardian.RiskEngineDoesNotRecognizeGuardian.selector,
                address(foreignRiskEngine),
                address(guardian)
            )
        );
        guardian.requestUnlock(PanopticPoolV2(address(foreignPool)));
    }

    function testIsBuilderAdminReturnsFalseForUnknownBuilderCode() external view {
        bool isAdmin = guardian.isBuilderAdmin(
            BUILDER_ADMIN,
            PanopticPoolV2(address(recognizedPool)),
            1
        );

        assertFalse(isAdmin);
    }

    function testDeployBuilderForwardsBuilderAdminToFactory() external {
        vm.prank(GUARDIAN_ADMIN);
        address wallet = guardian.deployBuilder(7, BUILDER_ADMIN, BuilderFactory(address(factory)));

        assertEq(factory.lastBuilderCode(), 7);
        assertEq(factory.lastBuilderAdmin(), BUILDER_ADMIN);
        assertEq(factory.lastWallet(), wallet);
        assertEq(MockBuilderWallet(wallet).builderAdmin(), BUILDER_ADMIN);
    }

    function testDeployBuilderRevertsForOversizedBuilderCode() external {
        uint256 oversizedBuilderCode = uint256(type(uint48).max) + 1;

        vm.prank(GUARDIAN_ADMIN);
        vm.expectRevert(PanopticGuardian.InvalidBuilderCode.selector);
        guardian.deployBuilder(
            oversizedBuilderCode,
            BUILDER_ADMIN,
            BuilderFactory(address(factory))
        );
    }

    function testLockPoolAsBuilderUsesRecognizedRiskEngine() external {
        vm.prank(GUARDIAN_ADMIN);
        address wallet = guardian.deployBuilder(
            11,
            BUILDER_ADMIN,
            BuilderFactory(address(factory))
        );
        recognizedRiskEngine.setFeeRecipient(11, wallet);

        vm.prank(BUILDER_ADMIN);
        guardian.lockPoolAsBuilder(PanopticPoolV2(address(recognizedPool)), 11);

        assertEq(recognizedRiskEngine.lockCalls(), 1);
    }

    function testLockPoolAsBuilderDoesNotCancelPendingUnlock() external {
        vm.prank(GUARDIAN_ADMIN);
        address wallet = guardian.deployBuilder(
            11,
            BUILDER_ADMIN,
            BuilderFactory(address(factory))
        );
        recognizedRiskEngine.setFeeRecipient(11, wallet);

        vm.prank(GUARDIAN_ADMIN);
        guardian.requestUnlock(PanopticPoolV2(address(recognizedPool)));

        uint256 etaBefore = guardian.unlockEta(PanopticPoolV2(address(recognizedPool)));

        vm.prank(BUILDER_ADMIN);
        guardian.lockPoolAsBuilder(PanopticPoolV2(address(recognizedPool)), 11);

        assertEq(guardian.unlockEta(PanopticPoolV2(address(recognizedPool))), etaBefore);
        assertEq(recognizedRiskEngine.lockCalls(), 1);
    }

    function testPendingUnlockRemainsExecutableAfterBuilderRelock() external {
        vm.prank(GUARDIAN_ADMIN);
        address wallet = guardian.deployBuilder(
            11,
            BUILDER_ADMIN,
            BuilderFactory(address(factory))
        );
        recognizedRiskEngine.setFeeRecipient(11, wallet);

        vm.prank(GUARDIAN_ADMIN);
        guardian.requestUnlock(PanopticPoolV2(address(recognizedPool)));

        uint256 eta = guardian.unlockEta(PanopticPoolV2(address(recognizedPool)));

        vm.prank(BUILDER_ADMIN);
        guardian.lockPoolAsBuilder(PanopticPoolV2(address(recognizedPool)), 11);

        vm.warp(eta);

        vm.prank(GUARDIAN_ADMIN);
        guardian.executeUnlock(PanopticPoolV2(address(recognizedPool)));

        assertEq(guardian.unlockEta(PanopticPoolV2(address(recognizedPool))), 0);
        assertEq(recognizedRiskEngine.unlockCalls(), 1);
    }

    function testLockPoolCancelsPendingUnlock() external {
        vm.prank(GUARDIAN_ADMIN);
        guardian.requestUnlock(PanopticPoolV2(address(recognizedPool)));

        assertTrue(guardian.unlockEta(PanopticPoolV2(address(recognizedPool))) != 0);

        vm.prank(GUARDIAN_ADMIN);
        guardian.lockPool(PanopticPoolV2(address(recognizedPool)));

        assertEq(guardian.unlockEta(PanopticPoolV2(address(recognizedPool))), 0);
    }

    function testCollectAllEmitsResolvedAmount() external {
        MockERC20 token = new MockERC20();
        address recipient = address(0xCAFE);

        token.mint(address(recognizedRiskEngine), 42);

        vm.expectEmit(true, true, false, true, address(guardian));
        emit TokensCollected(address(token), recipient, 42);

        vm.prank(TREASURER);
        guardian.collect(IRiskEngine(address(recognizedRiskEngine)), address(token), recipient, 0);

        assertEq(token.balanceOf(address(recognizedRiskEngine)), 0);
        assertEq(token.balanceOf(recipient), 42);
        assertEq(recognizedRiskEngine.lastAmount(), 42);
    }

    function testCollectAllEmitsActualTransferredAmountWhenRiskEngineCollectsPartialBalance()
        external
    {
        MockERC20 token = new MockERC20();
        address recipient = address(0xD00D);
        PartialCollectRiskEngine partialCollectRiskEngine = new PartialCollectRiskEngine(
            address(guardian)
        );

        token.mint(address(partialCollectRiskEngine), 42);

        vm.expectEmit(true, true, false, true, address(guardian));
        emit TokensCollected(address(token), recipient, 42);

        vm.prank(TREASURER);
        guardian.collect(
            IRiskEngine(address(partialCollectRiskEngine)),
            address(token),
            recipient,
            0
        );

        assertEq(token.balanceOf(address(partialCollectRiskEngine)), 21);
        assertEq(token.balanceOf(recipient), 21);
    }
}
