// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;
import {PanopticPoolV2} from "./PanopticPool.sol";
import {IRiskEngine} from "./interfaces/IRiskEngine.sol";
import {BuilderFactory, BuilderWallet} from "./Builder.sol";

/// @notice Minimal ERC20 balance query interface.
interface IERC20BalanceOf {
    /// @notice Returns an account's token balance.
    /// @param account The account to query.
    /// @return The account's token balance.
    function balanceOf(address account) external view returns (uint256);
}

/// @notice External interface for the guardian contract.
interface IPanopticGuardian {
    /// @notice Instantly locks a pool.
    /// @param pool The pool to lock.
    function lockPool(PanopticPoolV2 pool) external;

    /// @notice Instantly locks a pool as an authorized builder admin.
    /// @param pool The pool to lock.
    /// @param builderCode The builder code whose canonical wallet must recognize the caller.
    function lockPoolAsBuilder(PanopticPoolV2 pool, uint256 builderCode) external;

    /// @notice Starts the unlock timelock for a pool.
    /// @param pool The pool to unlock after the delay.
    function requestUnlock(PanopticPoolV2 pool) external;

    /// @notice Executes a matured unlock request.
    /// @param pool The pool to unlock.
    function executeUnlock(PanopticPoolV2 pool) external;

    /// @notice Cancels a pending unlock request.
    /// @param pool The pool whose pending unlock should be cancelled.
    function cancelUnlock(PanopticPoolV2 pool) external;

    /// @notice Revokes or restores a builder admin's lock authority.
    /// @param admin The builder admin to update.
    /// @param revoked True to revoke the admin, false to restore it.
    function setBuilderAdminRevoked(address admin, bool revoked) external;

    /// @notice Deploys a canonical builder wallet.
    /// @param builderCode The builder code to deploy.
    /// @param builderAdmin The admin that will control the deployed wallet.
    /// @return wallet The deployed wallet address.
    function deployBuilder(
        uint256 builderCode,
        address builderAdmin,
        BuilderFactory builderFactory
    ) external returns (address wallet);

    /// @notice Collects tokens from a RiskEngine to a recipient.
    /// @param riskEngine The RiskEngine to collect from.
    /// @param token The token to collect.
    /// @param recipient The recipient of the collected tokens.
    /// @param amount The amount to collect, or zero to collect the RiskEngine's full balance.
    function collect(
        IRiskEngine riskEngine,
        address token,
        address recipient,
        uint256 amount
    ) external;

    /// @notice Returns whether an account is an authorized, non-revoked builder admin.
    /// @param account The account to check.
    /// @param pool The pool whose RiskEngine is used for builder validation.
    /// @param builderCode The builder code to resolve.
    /// @return True if the account is an authorized builder admin.
    function isBuilderAdmin(
        address account,
        PanopticPoolV2 pool,
        uint256 builderCode
    ) external view returns (bool);

    /// @notice Returns whether a pool's pending unlock can be executed.
    /// @param pool The pool to check.
    /// @return True if the pool has a pending unlock and its ETA has passed.
    function isPoolUnlockReady(PanopticPoolV2 pool) external view returns (bool);
}

/// @notice PanopticGuardian contract for Panoptic RiskEngines and their shared BuilderFactory.
/// @dev Locking is immediate for the guardian admin and authorized builder admins. Unlocking is
/// delayed by a fixed timelock and reserved to the guardian admin. The contract also owns the
/// canonical BuilderFactory and exposes a separate treasurer-only token collection path.
///
/// The `GUARDIAN_ADMIN` and `TREASURER` addresses are immutable. This
/// prevents governance attacks but means key compromise or factory bugs require redeploying
/// the PanopticGuardian and updating all RiskEngine pointers. Both `GUARDIAN_ADMIN` and `TREASURER`
/// should be multisig wallets with appropriate signer thresholds to mitigate this risk.
contract PanopticGuardian is IPanopticGuardian {
    /// @notice Reverts when the caller is not the immutable guardian admin.
    error NotGuardianAdmin();

    /// @notice Reverts when the caller is not the immutable treasurer.
    error NotTreasurer();

    /// @notice Reverts when the caller is not a non-revoked builder admin for the given builder code.
    error NotAuthorizedBuilder();

    /// @notice Reverts when a required address argument is the zero address.
    error ZeroAddress();

    /// @notice Reverts when an address expected to contain code does not.
    /// @param target The address that was expected to be a deployed contract.
    error NotContract(address target);

    /// @notice Reverts when a builder code is zero or outside the supported range.
    error InvalidBuilderCode();

    /// @notice Reverts when an unlock request already exists for the pool.
    error UnlockAlreadyPending();

    /// @notice Reverts when the Guardian is not the builder factory admin.
    error NotFactoryAdmin();

    /// @notice Reverts when no unlock request exists for the pool.
    error NoPendingUnlock();

    /// @notice Reverts when an unlock is executed before its timelock expires.
    /// @param eta The timestamp at which the unlock becomes executable.
    error UnlockNotReady(uint256 eta);

    /// @notice Reverts when a RiskEngine does not recognize this guardian.
    /// @param riskEngine The RiskEngine that failed validation.
    /// @param guardian The guardian address expected by the check.
    error RiskEngineDoesNotRecognizeGuardian(address riskEngine, address guardian);

    /// @notice Emitted when a pool is locked.
    /// @param pool The locked pool.
    /// @param locker The account that initiated the lock.
    event PoolLocked(PanopticPoolV2 indexed pool, address indexed locker);

    /// @notice Emitted when an unlock request is started.
    /// @param pool The pool scheduled for unlock.
    /// @param eta The timestamp at which the unlock becomes executable.
    event UnlockRequested(PanopticPoolV2 indexed pool, uint256 eta);

    /// @notice Emitted when a pool is unlocked.
    /// @param pool The unlocked pool.
    event PoolUnlocked(PanopticPoolV2 indexed pool);

    /// @notice Emitted when a pending unlock is cancelled.
    /// @param pool The pool whose pending unlock was cancelled.
    event UnlockCancelled(PanopticPoolV2 indexed pool);

    /// @notice Emitted when a builder admin is revoked.
    /// @param admin The revoked builder admin.
    event BuilderAdminRevoked(address indexed admin);

    /// @notice Emitted when a builder admin is restored.
    /// @param admin The restored builder admin.
    event BuilderAdminRestored(address indexed admin);

    /// @notice Emitted when a canonical builder wallet is deployed.
    /// @param builderCode The builder code used for deployment.
    /// @param wallet The deployed wallet address.
    event BuilderDeployed(uint256 indexed builderCode, address indexed wallet);

    /// @notice Emitted when tokens are collected from a RiskEngine.
    /// @param token The collected token.
    /// @param recipient The recipient of the collected tokens.
    /// @param amount The amount transferred out of the RiskEngine.
    event TokensCollected(address indexed token, address indexed recipient, uint256 amount);

    /// @notice Immutable guardian admin allowed to lock, unlock, revoke builders, and deploy wallets.
    address public immutable GUARDIAN_ADMIN;

    /// @notice Immutable treasurer allowed to collect tokens from RiskEngines.
    address public immutable TREASURER;

    /// @notice Tracks whether a builder admin's lock authority has been revoked.
    mapping(address => bool) public builderAdminRevoked;

    /// @notice Pending unlock execution timestamp by pool. Zero means no pending unlock.
    mapping(PanopticPoolV2 => uint256) public unlockEta;

    /// @notice Fixed delay before a requested unlock can be executed.
    uint256 public constant UNLOCK_DELAY = 1 hours;

    /// @notice Creates a new guardian.
    /// @param guardianAdmin The immutable guardian admin address.
    /// @param treasurer The immutable treasurer address.
    constructor(address guardianAdmin, address treasurer) {
        if (guardianAdmin == address(0) || treasurer == address(0)) {
            revert ZeroAddress();
        }

        GUARDIAN_ADMIN = guardianAdmin;
        TREASURER = treasurer;
    }

    /// @notice Restricts a function to the guardian admin.
    modifier onlyGuardianAdmin() {
        _onlyGuardianAdmin();
        _;
    }

    function _onlyGuardianAdmin() internal {
        if (msg.sender != GUARDIAN_ADMIN) revert NotGuardianAdmin();
    }

    /// @notice Restricts a function to the treasurer.
    modifier onlyTreasurer() {
        _onlyTreasurer();
        _;
    }

    function _onlyTreasurer() internal {
        if (msg.sender != TREASURER) revert NotTreasurer();
    }

    /// @notice Instantly locks a pool as the guardian admin.
    /// @dev Any pending unlock is cancelled before the RiskEngine call.
    /// @param pool The pool to lock.
    function lockPool(PanopticPoolV2 pool) external onlyGuardianAdmin {
        IRiskEngine riskEngine = _getRiskEngine(pool);
        _clearPendingUnlock(pool);
        riskEngine.lockPool(pool);
        emit PoolLocked(pool, msg.sender);
    }

    /// @notice Allows a non-revoked builder admin to lock a pool through its RiskEngine.
    /// @dev Builder lock authority is intentionally scoped to the target pool's RiskEngine,
    /// not to any single pool. Once `builderCode` resolves to a canonical builder wallet on
    /// that RiskEngine and `msg.sender` is confirmed as its admin, the caller may lock any
    /// pool served by that RiskEngine. This broad scope is deliberate to maximize emergency
    /// responsiveness across markets sharing the same guardian / RiskEngine deployment.
    ///
    /// Unlike `lockPool`, this function intentionally does NOT cancel pending unlocks.
    /// Builder locks are subordinate to the guardian admin's unlock lifecycle: if a pending
    /// unlock exists, it remains active and can still be executed once its ETA matures. This
    /// ensures a builder cannot unilaterally block the guardian admin's unlock schedule. The
    /// guardian admin retains full authority to cancel, execute, or re-request unlocks
    /// regardless of builder-initiated locks.
    /// @param pool The pool to lock.
    /// @param builderCode The builder code used to resolve the caller's canonical wallet.
    function lockPoolAsBuilder(PanopticPoolV2 pool, uint256 builderCode) external {
        _requirePool(pool);

        IRiskEngine riskEngine = _getRiskEngine(pool);
        if (!_isAuthorizedBuilder(msg.sender, riskEngine, builderCode))
            revert NotAuthorizedBuilder();

        riskEngine.lockPool(pool);
        emit PoolLocked(pool, msg.sender);
    }

    /// @notice Starts the unlock timelock for a pool.
    /// @param pool The pool scheduled for unlock.
    function requestUnlock(PanopticPoolV2 pool) external onlyGuardianAdmin {
        _getRiskEngine(pool);
        if (unlockEta[pool] != 0) revert UnlockAlreadyPending();

        uint256 eta = block.timestamp + UNLOCK_DELAY;
        unlockEta[pool] = eta;

        emit UnlockRequested(pool, eta);
    }

    /// @notice Executes a matured unlock request.
    /// @dev Clears the pending unlock before calling out to the RiskEngine.
    /// @param pool The pool to unlock.
    function executeUnlock(PanopticPoolV2 pool) external onlyGuardianAdmin {
        IRiskEngine riskEngine = _getRiskEngine(pool);

        uint256 eta = unlockEta[pool];
        if (eta == 0) revert NoPendingUnlock();
        if (block.timestamp < eta) revert UnlockNotReady(eta);

        unlockEta[pool] = 0;
        riskEngine.unlockPool(pool);

        emit PoolUnlocked(pool);
    }

    /// @notice Cancels a pending unlock request.
    /// @param pool The pool whose pending unlock should be cancelled.
    function cancelUnlock(PanopticPoolV2 pool) external onlyGuardianAdmin {
        _requirePool(pool);
        if (unlockEta[pool] == 0) revert NoPendingUnlock();

        unlockEta[pool] = 0;
        emit UnlockCancelled(pool);
    }

    /// @notice Revokes or restores a builder admin's lock authority.
    /// @param admin The builder admin to update.
    /// @param revoked True to revoke the admin, false to restore it.
    function setBuilderAdminRevoked(address admin, bool revoked) external onlyGuardianAdmin {
        if (admin == address(0)) revert ZeroAddress();

        builderAdminRevoked[admin] = revoked;

        if (revoked) {
            emit BuilderAdminRevoked(admin);
        } else {
            emit BuilderAdminRestored(admin);
        }
    }

    /// @notice Deploys the canonical builder wallet for a builder code.
    /// @param builderCode The builder code to deploy.
    /// @param builderAdmin The admin that will control the deployed wallet.
    /// @return wallet The deployed wallet address.
    function deployBuilder(
        uint256 builderCode,
        address builderAdmin,
        BuilderFactory builderFactory
    ) external onlyGuardianAdmin returns (address wallet) {
        if (builderCode == 0 || builderCode > type(uint48).max) revert InvalidBuilderCode();
        if (builderAdmin == address(0)) revert ZeroAddress();

        _requireContract(address(builderFactory));
        if (builderFactory.OWNER() != address(this)) revert NotFactoryAdmin();

        // casting to uint48 is safe because builderCode is range-checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint48 builderCode48 = uint48(builderCode);

        wallet = builderFactory.deployBuilder(builderCode48, builderAdmin);
        _requireContract(wallet);

        emit BuilderDeployed(builderCode, wallet);
    }

    /// @notice Collects tokens from a RiskEngine to a recipient.
    /// @dev When `amount` is zero, the guardian snapshots the RiskEngine's token balance before
    /// calling the full-balance collect overload, and emits that pre-collect balance as the
    /// collected amount. The actual transfer is governed entirely by the RiskEngine, so the
    /// emitted value may differ from the real delta for fee-on-transfer tokens or if the
    /// RiskEngine's balance changes between the snapshot and the transfer.
    /// @param riskEngine The RiskEngine to collect from.
    /// @param token The token to collect.
    /// @param recipient The recipient of the collected tokens.
    /// @param amount The amount to collect, or zero for the full-balance path.
    function collect(
        IRiskEngine riskEngine,
        address token,
        address recipient,
        uint256 amount
    ) external onlyTreasurer {
        _requireRecognizedRiskEngine(address(riskEngine));
        if (token == address(0) || recipient == address(0)) revert ZeroAddress();

        uint256 collectedAmount = amount;
        if (amount == 0) {
            collectedAmount = _balanceOfOrZero(token, address(riskEngine));
            riskEngine.collect(token, recipient);
        } else {
            riskEngine.collect(token, recipient, amount);
        }

        emit TokensCollected(token, recipient, collectedAmount);
    }

    /// @notice Returns whether an account is an authorized, non-revoked builder admin.
    /// @param account The account to check.
    /// @param pool The pool whose RiskEngine is used for builder validation.
    /// @param builderCode The builder code used to resolve the canonical wallet.
    /// @return True if the account is an authorized builder admin.
    function isBuilderAdmin(
        address account,
        PanopticPoolV2 pool,
        uint256 builderCode
    ) external view returns (bool) {
        if (address(pool) == address(0) || address(pool).code.length == 0) {
            return false;
        }

        IRiskEngine riskEngine = pool.riskEngine();
        return _isAuthorizedBuilder(account, riskEngine, builderCode);
    }

    /// @notice Returns whether a pool's pending unlock is ready to execute.
    /// @param pool The pool to check.
    /// @return True if a pending unlock exists and its ETA has passed.
    function isPoolUnlockReady(PanopticPoolV2 pool) external view returns (bool) {
        uint256 eta = unlockEta[pool];
        return eta != 0 && block.timestamp >= eta;
    }

    /// @notice Returns whether a caller is an authorized builder admin for a RiskEngine.
    /// @dev Builder authorization is resolved through the RiskEngine's canonical fee-recipient
    /// derivation for `builderCode`, then checked against the builder wallet's recorded admin.
    /// @param caller The account to check.
    /// @param riskEngine The RiskEngine used to resolve the canonical builder wallet.
    /// @param builderCode The builder code to resolve.
    /// @return True if the caller is an authorized, non-revoked builder admin.
    function _isAuthorizedBuilder(
        address caller,
        IRiskEngine riskEngine,
        uint256 builderCode
    ) internal view returns (bool) {
        if (caller == address(0) || builderCode == 0 || builderAdminRevoked[caller]) {
            return false;
        }
        if (!_isRecognizedRiskEngine(address(riskEngine))) {
            return false;
        }

        address wallet;
        try riskEngine.getFeeRecipient(builderCode) returns (address resolvedWallet) {
            wallet = resolvedWallet;
        } catch {
            return false;
        }

        if (wallet == address(0) || wallet.code.length == 0) {
            return false;
        }

        try BuilderWallet(wallet).builderAdmin() returns (address builderAdmin) {
            return builderAdmin == caller;
        } catch {
            return false;
        }
    }

    /// @notice Returns an ERC20 balance, or zero if the token call fails or returns malformed data.
    /// @param token The token to query.
    /// @param account The account whose balance should be queried.
    /// @return balance The account balance, or zero if the query fails.
    function _balanceOfOrZero(
        address token,
        address account
    ) internal view returns (uint256 balance) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeCall(IERC20BalanceOf.balanceOf, (account))
        );

        if (!success || data.length < 32) {
            return 0;
        }

        return abi.decode(data, (uint256));
    }

    /// @notice Returns a pool's RiskEngine after validating both contracts and guardian wiring.
    /// @param pool The pool to inspect.
    /// @return riskEngine The pool's validated RiskEngine.
    function _getRiskEngine(PanopticPoolV2 pool) internal view returns (IRiskEngine riskEngine) {
        _requirePool(pool);
        riskEngine = pool.riskEngine();
        _requireRecognizedRiskEngine(address(riskEngine));
    }

    /// @notice Reverts unless a pool address is non-zero and contains code.
    /// @param pool The pool to validate.
    function _requirePool(PanopticPoolV2 pool) internal view {
        if (address(pool) == address(0)) revert ZeroAddress();
        _requireContract(address(pool));
    }

    /// @notice Cancels a pending unlock if one exists.
    /// @param pool The pool whose pending unlock should be cleared.
    function _clearPendingUnlock(PanopticPoolV2 pool) internal {
        if (unlockEta[pool] != 0) {
            unlockEta[pool] = 0;
            emit UnlockCancelled(pool);
        }
    }

    /// @notice Reverts unless a RiskEngine recognizes this guardian.
    /// @param riskEngine The RiskEngine to validate.
    function _requireRecognizedRiskEngine(address riskEngine) internal view {
        if (!_isRecognizedRiskEngine(riskEngine)) {
            revert RiskEngineDoesNotRecognizeGuardian(riskEngine, address(this));
        }
    }

    /// @notice Returns whether a RiskEngine recognizes this guardian.
    /// @param riskEngine The RiskEngine to check.
    /// @return True if the RiskEngine contains code and reports this contract as its guardian.
    function _isRecognizedRiskEngine(address riskEngine) internal view returns (bool) {
        if (riskEngine == address(0) || riskEngine.code.length == 0) {
            return false;
        }

        (bool success, bytes memory data) = riskEngine.staticcall(
            abi.encodeCall(IRiskEngine.GUARDIAN, ())
        );

        return success && data.length >= 32 && abi.decode(data, (address)) == address(this);
    }

    /// @notice Reverts unless an address contains deployed code.
    /// @param target The address to validate.
    function _requireContract(address target) internal view {
        if (target.code.length == 0) revert NotContract(target);
    }
}
