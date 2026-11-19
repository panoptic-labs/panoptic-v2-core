// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PanopticPoolV2} from "@contracts/PanopticPool.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";
import {PanopticGuardian} from "@contracts/PanopticGuardian.sol";
import {BuilderFactory} from "@contracts/Builder.sol";
import {OraclePack} from "@types/OraclePack.sol";

contract CovBuilderWallet {
    address public builderAdmin;

    constructor(address _builderAdmin) {
        builderAdmin = _builderAdmin;
    }
}

/// @dev Has code but reverts on `builderAdmin()`.
contract CovBrokenBuilderWallet {
    function builderAdmin() external pure returns (address) {
        revert("no admin");
    }
}

contract CovBuilderFactory {
    address public OWNER;

    constructor(address owner) {
        OWNER = owner;
    }

    function deployBuilder(uint48, address builderAdmin) external returns (address) {
        return address(new CovBuilderWallet(builderAdmin));
    }
}

contract CovToken {
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

/// @dev `balanceOf` reverts.
contract CovRevertingBalanceToken {
    function balanceOf(address) external pure returns (uint256) {
        revert("balanceOf disabled");
    }
}

/// @dev `balanceOf` succeeds but returns fewer than 32 bytes.
contract CovShortBalanceToken {
    fallback() external {
        assembly {
            mstore(0, 0xff)
            return(0, 31)
        }
    }
}

contract CovRiskEngine {
    mapping(uint256 => address) public feeRecipient;
    mapping(uint256 => bool) public feeRecipientSet;

    uint256 public lockCalls;
    uint256 public unlockCalls;

    address public lastToken;
    address public lastRecipient;
    uint256 public lastAmount;
    uint256 public collectAllCalls;
    uint256 public collectAmountCalls;

    /// @dev An unset builder code reverts, like the real RiskEngine does for an invalid one.
    function setFeeRecipient(uint256 builderCode, address wallet) external {
        feeRecipient[builderCode] = wallet;
        feeRecipientSet[builderCode] = true;
    }

    function getFeeRecipient(uint256 builderCode) external view returns (address) {
        require(feeRecipientSet[builderCode], "InvalidBuilderCode");
        return feeRecipient[builderCode];
    }

    function lockPool(PanopticPoolV2) external {
        lockCalls++;
    }

    function unlockPool(PanopticPoolV2) external {
        unlockCalls++;
    }

    function collect(address token, address recipient, uint256 amount) external {
        (lastToken, lastRecipient, lastAmount) = (token, recipient, amount);
        collectAmountCalls++;
    }

    function collect(address token, address recipient) external {
        (lastToken, lastRecipient, lastAmount) = (token, recipient, 0);
        collectAllCalls++;
    }
}

contract CovPool {
    IRiskEngine public riskEngine;
    uint8 internal lockMode;

    constructor(IRiskEngine _riskEngine) {
        riskEngine = _riskEngine;
    }

    function setLockMode(uint8 mode) external {
        lockMode = mode;
    }

    function getOracleTicks() external view returns (int24, int24, int24, int24, OraclePack) {
        return (0, 0, 0, 0, OraclePack.wrap(uint256(lockMode) << 118));
    }
}

/// @notice Fills the coverage gaps left in `contracts/PanopticGuardian.sol` by the rest of the suite:
/// - constructor zero-address checks and the `onlyTreasurer` revert
/// - `cancelUnlock`, `setBuilderAdminRevoked` and `isPoolUnlockReady`, which had no tests
/// - the revert arms of `executeUnlock`, `lockPoolAsBuilder`, `deployBuilder` and `collect`
/// - the explicit-amount arm of `collect` and the failure arms of the balance snapshot
/// - every way `_isAuthorizedBuilder` can return false
contract PanopticGuardianCoverageTest is Test {
    event PoolLocked(PanopticPoolV2 indexed pool, address indexed locker);
    event PoolUnlocked(PanopticPoolV2 indexed pool);
    event UnlockCancelled(PanopticPoolV2 indexed pool);
    event BuilderAdminRevoked(address indexed admin);
    event BuilderAdminRestored(address indexed admin);
    event TokensCollected(address indexed token, address indexed recipient, uint256 amount);

    address internal constant ADMIN = address(0xA11CE);
    address internal constant TREASURER = address(0xB0B);
    address internal constant BUILDER_ADMIN = address(0xC0DE);
    address internal constant RECIPIENT = address(0xFEE);

    uint256 internal constant CODE = 11;

    PanopticGuardian internal guardian;
    CovRiskEngine internal riskEngine;
    CovPool internal poolMock;
    PanopticPoolV2 internal pool;
    CovToken internal token;

    function setUp() public {
        guardian = new PanopticGuardian(ADMIN, TREASURER);
        riskEngine = new CovRiskEngine();
        poolMock = new CovPool(IRiskEngine(address(riskEngine)));
        pool = PanopticPoolV2(address(poolMock));
        token = new CovToken();

        riskEngine.setFeeRecipient(CODE, address(new CovBuilderWallet(BUILDER_ADMIN)));
    }

    function _requestUnlock() internal returns (uint256 eta) {
        poolMock.setLockMode(3);
        vm.prank(ADMIN);
        guardian.requestUnlock(pool);
        eta = guardian.unlockEta(pool);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_revertsOnZeroGuardianAdmin() public {
        vm.expectRevert(PanopticGuardian.ZeroAddress.selector);
        new PanopticGuardian(address(0), TREASURER);
    }

    function test_constructor_revertsOnZeroTreasurer() public {
        vm.expectRevert(PanopticGuardian.ZeroAddress.selector);
        new PanopticGuardian(ADMIN, address(0));
    }

    function test_constructor_setsImmutables(address admin, address treasurer) public {
        vm.assume(admin != address(0) && treasurer != address(0));
        PanopticGuardian g = new PanopticGuardian(admin, treasurer);

        assertEq(g.GUARDIAN_ADMIN(), admin);
        assertEq(g.TREASURER(), treasurer);
        assertEq(g.UNLOCK_DELAY(), 1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                             ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_adminFunctions_revertForNonAdmin(address caller) public {
        vm.assume(caller != ADMIN);
        vm.startPrank(caller);

        vm.expectRevert(PanopticGuardian.NotGuardianAdmin.selector);
        guardian.lockPool(pool);
        vm.expectRevert(PanopticGuardian.NotGuardianAdmin.selector);
        guardian.requestUnlock(pool);
        vm.expectRevert(PanopticGuardian.NotGuardianAdmin.selector);
        guardian.executeUnlock(pool);
        vm.expectRevert(PanopticGuardian.NotGuardianAdmin.selector);
        guardian.cancelUnlock(pool);
        vm.expectRevert(PanopticGuardian.NotGuardianAdmin.selector);
        guardian.setBuilderAdminRevoked(BUILDER_ADMIN, true);
        vm.expectRevert(PanopticGuardian.NotGuardianAdmin.selector);
        guardian.deployBuilder(CODE, BUILDER_ADMIN, BuilderFactory(address(0)));

        vm.stopPrank();
    }

    function test_collect_revertsForNonTreasurer(address caller) public {
        vm.assume(caller != TREASURER);

        vm.prank(caller);
        vm.expectRevert(PanopticGuardian.NotTreasurer.selector);
        guardian.collect(IRiskEngine(address(riskEngine)), address(token), RECIPIENT, 1);
    }

    function test_collect_revertsForGuardianAdmin() public {
        // the two roles are disjoint: the admin cannot move funds
        vm.prank(ADMIN);
        vm.expectRevert(PanopticGuardian.NotTreasurer.selector);
        guardian.collect(IRiskEngine(address(riskEngine)), address(token), RECIPIENT, 0);
    }

    /*//////////////////////////////////////////////////////////////
                           UNLOCK LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    function test_executeUnlock_revertsWithoutPendingUnlock() public {
        vm.prank(ADMIN);
        vm.expectRevert(PanopticGuardian.NoPendingUnlock.selector);
        guardian.executeUnlock(pool);

        assertEq(riskEngine.unlockCalls(), 0);
    }

    function test_executeUnlock_revertsBeforeEta(uint256 elapsed) public {
        uint256 eta = _requestUnlock();
        elapsed = bound(elapsed, 0, guardian.UNLOCK_DELAY() - 1);
        skip(elapsed);

        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(PanopticGuardian.UnlockNotReady.selector, eta));
        guardian.executeUnlock(pool);

        assertEq(guardian.unlockEta(pool), eta, "still pending");
        assertEq(riskEngine.unlockCalls(), 0);
    }

    function test_executeUnlock_succeedsFromEta(uint256 late) public {
        uint256 eta = _requestUnlock();
        late = bound(late, 0, 365 days);
        vm.warp(eta + late);

        vm.expectEmit(true, true, true, true, address(guardian));
        emit PoolUnlocked(pool);
        vm.prank(ADMIN);
        guardian.executeUnlock(pool);

        assertEq(guardian.unlockEta(pool), 0, "cleared");
        assertEq(riskEngine.unlockCalls(), 1);

        // the request is consumed: a second execution has nothing to act on
        vm.prank(ADMIN);
        vm.expectRevert(PanopticGuardian.NoPendingUnlock.selector);
        guardian.executeUnlock(pool);
    }

    function test_cancelUnlock_revertsWithoutPendingUnlock() public {
        vm.prank(ADMIN);
        vm.expectRevert(PanopticGuardian.NoPendingUnlock.selector);
        guardian.cancelUnlock(pool);
    }

    function test_cancelUnlock_clearsPendingUnlock() public {
        _requestUnlock();

        vm.expectEmit(true, true, true, true, address(guardian));
        emit UnlockCancelled(pool);
        vm.prank(ADMIN);
        guardian.cancelUnlock(pool);

        assertEq(guardian.unlockEta(pool), 0, "cleared");
        assertEq(riskEngine.unlockCalls(), 0, "risk engine untouched");

        // the cancelled request can no longer be executed, even after the delay
        skip(guardian.UNLOCK_DELAY());
        vm.prank(ADMIN);
        vm.expectRevert(PanopticGuardian.NoPendingUnlock.selector);
        guardian.executeUnlock(pool);

        // and a fresh request starts a new full delay
        vm.prank(ADMIN);
        guardian.requestUnlock(pool);
        assertEq(guardian.unlockEta(pool), block.timestamp + guardian.UNLOCK_DELAY());
    }

    function test_isPoolUnlockReady() public {
        assertFalse(guardian.isPoolUnlockReady(pool), "nothing pending");

        uint256 eta = _requestUnlock();
        assertFalse(guardian.isPoolUnlockReady(pool), "just requested");

        vm.warp(eta - 1);
        assertFalse(guardian.isPoolUnlockReady(pool), "one second early");

        vm.warp(eta);
        assertTrue(guardian.isPoolUnlockReady(pool), "at eta");

        vm.warp(eta + 30 days);
        assertTrue(guardian.isPoolUnlockReady(pool), "long after eta");

        vm.prank(ADMIN);
        guardian.executeUnlock(pool);
        assertFalse(guardian.isPoolUnlockReady(pool), "executed");
    }

    function test_lockPool_withoutPendingUnlockEmitsNoCancel() public {
        vm.recordLogs();
        vm.prank(ADMIN);
        guardian.lockPool(pool);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "only PoolLocked");
        assertEq(logs[0].topics[0], PoolLocked.selector);
        assertEq(riskEngine.lockCalls(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                          BUILDER ADMIN REVOCATION
    //////////////////////////////////////////////////////////////*/

    function test_setBuilderAdminRevoked_revertsOnZeroAddress() public {
        vm.prank(ADMIN);
        vm.expectRevert(PanopticGuardian.ZeroAddress.selector);
        guardian.setBuilderAdminRevoked(address(0), true);
    }

    function test_setBuilderAdminRevoked_revokeAndRestore() public {
        assertTrue(guardian.isBuilderAdmin(BUILDER_ADMIN, pool, CODE), "authorized at first");

        vm.expectEmit(true, true, true, true, address(guardian));
        emit BuilderAdminRevoked(BUILDER_ADMIN);
        vm.prank(ADMIN);
        guardian.setBuilderAdminRevoked(BUILDER_ADMIN, true);

        assertTrue(guardian.builderAdminRevoked(BUILDER_ADMIN), "flag set");
        assertFalse(guardian.isBuilderAdmin(BUILDER_ADMIN, pool, CODE), "revoked");

        vm.prank(BUILDER_ADMIN);
        vm.expectRevert(PanopticGuardian.NotAuthorizedBuilder.selector);
        guardian.lockPoolAsBuilder(pool, CODE);
        assertEq(riskEngine.lockCalls(), 0, "no lock while revoked");

        vm.expectEmit(true, true, true, true, address(guardian));
        emit BuilderAdminRestored(BUILDER_ADMIN);
        vm.prank(ADMIN);
        guardian.setBuilderAdminRevoked(BUILDER_ADMIN, false);

        assertFalse(guardian.builderAdminRevoked(BUILDER_ADMIN), "flag cleared");
        assertTrue(guardian.isBuilderAdmin(BUILDER_ADMIN, pool, CODE), "restored");

        vm.expectEmit(true, true, true, true, address(guardian));
        emit PoolLocked(pool, BUILDER_ADMIN);
        vm.prank(BUILDER_ADMIN);
        guardian.lockPoolAsBuilder(pool, CODE);
        assertEq(riskEngine.lockCalls(), 1, "locks again once restored");
    }

    /*//////////////////////////////////////////////////////////////
                         BUILDER AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    function test_lockPoolAsBuilder_revertsForNonAdminOfWallet(address caller) public {
        vm.assume(caller != BUILDER_ADMIN);

        vm.prank(caller);
        vm.expectRevert(PanopticGuardian.NotAuthorizedBuilder.selector);
        guardian.lockPoolAsBuilder(pool, CODE);

        assertEq(riskEngine.lockCalls(), 0);
    }

    function test_isBuilderAdmin_falseForZeroAccount() public {
        // even when the wallet's recorded admin is the zero address
        riskEngine.setFeeRecipient(CODE, address(new CovBuilderWallet(address(0))));

        assertFalse(guardian.isBuilderAdmin(address(0), pool, CODE));
    }

    function test_isBuilderAdmin_falseForZeroBuilderCode() public {
        // even when the risk engine would resolve code 0 to the builder's wallet
        riskEngine.setFeeRecipient(0, address(new CovBuilderWallet(BUILDER_ADMIN)));

        assertFalse(guardian.isBuilderAdmin(BUILDER_ADMIN, pool, 0));
    }

    function test_isBuilderAdmin_falseWhenRiskEngineReverts() public view {
        assertFalse(guardian.isBuilderAdmin(BUILDER_ADMIN, pool, CODE + 1));
    }

    function test_isBuilderAdmin_falseWhenWalletIsZero() public {
        riskEngine.setFeeRecipient(CODE, address(0));

        assertFalse(guardian.isBuilderAdmin(BUILDER_ADMIN, pool, CODE));
    }

    function test_isBuilderAdmin_falseWhenWalletHasNoCode() public {
        // the canonical wallet address is known before the wallet is deployed
        riskEngine.setFeeRecipient(CODE, makeAddr("undeployed wallet"));

        assertFalse(guardian.isBuilderAdmin(BUILDER_ADMIN, pool, CODE));
    }

    function test_isBuilderAdmin_falseWhenWalletCallReverts() public {
        riskEngine.setFeeRecipient(CODE, address(new CovBrokenBuilderWallet()));

        assertFalse(guardian.isBuilderAdmin(BUILDER_ADMIN, pool, CODE));
    }

    function test_isBuilderAdmin_falseForAnotherWalletsAdmin(address other) public view {
        vm.assume(other != BUILDER_ADMIN);

        assertFalse(guardian.isBuilderAdmin(other, pool, CODE));
        assertTrue(guardian.isBuilderAdmin(BUILDER_ADMIN, pool, CODE));
    }

    /*//////////////////////////////////////////////////////////////
                             DEPLOY BUILDER
    //////////////////////////////////////////////////////////////*/

    function test_deployBuilder_revertsOnZeroBuilderCode() public {
        CovBuilderFactory factory = new CovBuilderFactory(address(guardian));

        vm.prank(ADMIN);
        vm.expectRevert(PanopticGuardian.InvalidBuilderCode.selector);
        guardian.deployBuilder(0, BUILDER_ADMIN, BuilderFactory(address(factory)));
    }

    function test_deployBuilder_revertsWhenGuardianDoesNotOwnFactory(address owner) public {
        vm.assume(owner != address(guardian));
        CovBuilderFactory factory = new CovBuilderFactory(owner);

        vm.prank(ADMIN);
        vm.expectRevert(PanopticGuardian.NotFactoryAdmin.selector);
        guardian.deployBuilder(CODE, BUILDER_ADMIN, BuilderFactory(address(factory)));
    }

    function test_deployBuilder_withRealFactory(uint48 builderCode) public {
        vm.assume(builderCode != 0);
        BuilderFactory factory = new BuilderFactory(address(guardian));

        vm.prank(ADMIN);
        address wallet = guardian.deployBuilder(builderCode, BUILDER_ADMIN, factory);

        assertEq(wallet, factory.predictBuilderWallet(builderCode), "canonical address");
        assertEq(CovBuilderWallet(wallet).builderAdmin(), BUILDER_ADMIN, "admin recorded");
    }

    /*//////////////////////////////////////////////////////////////
                                COLLECT
    //////////////////////////////////////////////////////////////*/

    function test_collect_revertsOnZeroToken() public {
        vm.prank(TREASURER);
        vm.expectRevert(PanopticGuardian.ZeroAddress.selector);
        guardian.collect(IRiskEngine(address(riskEngine)), address(0), RECIPIENT, 1);
    }

    function test_collect_revertsOnZeroRecipient() public {
        vm.prank(TREASURER);
        vm.expectRevert(PanopticGuardian.ZeroAddress.selector);
        guardian.collect(IRiskEngine(address(riskEngine)), address(token), address(0), 1);
    }

    function test_collect_explicitAmountUsesAmountOverload(uint256 amount) public {
        amount = bound(amount, 1, type(uint256).max);

        vm.expectEmit(true, true, true, true, address(guardian));
        emit TokensCollected(address(token), RECIPIENT, amount);
        vm.prank(TREASURER);
        guardian.collect(IRiskEngine(address(riskEngine)), address(token), RECIPIENT, amount);

        assertEq(riskEngine.collectAmountCalls(), 1, "amount overload");
        assertEq(riskEngine.collectAllCalls(), 0, "not the full-balance overload");
        assertEq(riskEngine.lastToken(), address(token));
        assertEq(riskEngine.lastRecipient(), RECIPIENT);
        assertEq(riskEngine.lastAmount(), amount);
    }

    function test_collect_zeroAmountSnapshotsBalance(uint256 balance) public {
        token.mint(address(riskEngine), balance);

        vm.expectEmit(true, true, true, true, address(guardian));
        emit TokensCollected(address(token), RECIPIENT, balance);
        vm.prank(TREASURER);
        guardian.collect(IRiskEngine(address(riskEngine)), address(token), RECIPIENT, 0);

        assertEq(riskEngine.collectAllCalls(), 1, "full-balance overload");
        assertEq(riskEngine.collectAmountCalls(), 0, "not the amount overload");
    }

    function test_collect_zeroAmountReportsZeroWhenBalanceOfReverts() public {
        address badToken = address(new CovRevertingBalanceToken());

        vm.expectEmit(true, true, true, true, address(guardian));
        emit TokensCollected(badToken, RECIPIENT, 0);
        vm.prank(TREASURER);
        guardian.collect(IRiskEngine(address(riskEngine)), badToken, RECIPIENT, 0);

        assertEq(riskEngine.collectAllCalls(), 1);
    }

    function test_collect_zeroAmountReportsZeroWhenBalanceOfReturnsShortData() public {
        address badToken = address(new CovShortBalanceToken());

        vm.expectEmit(true, true, true, true, address(guardian));
        emit TokensCollected(badToken, RECIPIENT, 0);
        vm.prank(TREASURER);
        guardian.collect(IRiskEngine(address(riskEngine)), badToken, RECIPIENT, 0);

        assertEq(riskEngine.collectAllCalls(), 1);
    }

    function test_collect_zeroAmountReportsZeroWhenTokenHasNoCode() public {
        address noCode = makeAddr("not a token");

        vm.expectEmit(true, true, true, true, address(guardian));
        emit TokensCollected(noCode, RECIPIENT, 0);
        vm.prank(TREASURER);
        guardian.collect(IRiskEngine(address(riskEngine)), noCode, RECIPIENT, 0);
    }
}
