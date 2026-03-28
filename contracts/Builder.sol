// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Errors} from "@libraries/Errors.sol";
import {SafeTransferLib} from "@libraries/SafeTransferLib.sol";

/*//////////////////////////////////////////////////////////////
                       BUILDER WALLETS
//////////////////////////////////////////////////////////////*/

contract BuilderWallet {
    using SafeTransferLib for address;

    address public immutable BUILDER_FACTORY;
    address public builderAdmin;

    /// @notice Emitted when the builder wallet is initialized
    /// @param builderAdmin The address of the builder admin
    event BuilderWalletInitialized(address indexed builderAdmin);

    /// @notice Emitted when tokens are swept from the wallet
    /// @param token The address of the token swept
    /// @param to The address that received the tokens
    /// @param amount The amount of tokens swept
    event TokensSwept(address indexed token, address indexed to, uint256 amount);

    /// @notice Constructs a new BuilderWallet instance
    /// @param builderFactory The address of the BuilderFactory contract that deployed this wallet
    constructor(address builderFactory) {
        BUILDER_FACTORY = builderFactory;
    }

    /// @notice Initializes the builder wallet with a builder admin address
    /// @dev Can only be called once. Reverts if already initialized or if _builderAdmin is the zero address
    /// @param _builderAdmin The address that will be set as the builder admin with permission to sweep tokens
    function init(address _builderAdmin) external {
        if (builderAdmin != address(0)) revert Errors.AlreadyInitialized();
        if (_builderAdmin == address(0)) revert Errors.ZeroAddress();

        builderAdmin = _builderAdmin;
        emit BuilderWalletInitialized(_builderAdmin);
    }

    /// @notice Transfers all tokens of a given type from this wallet to a specified address
    /// @dev Only callable by the builder admin. Emits TokensSwept event even if balance is zero
    /// @param token The address of the token to sweep from the wallet
    /// @param to The destination address to receive the swept tokens
    function sweep(address token, address to) external {
        if (msg.sender != builderAdmin) revert Errors.NotBuilder();

        uint256 bal = SafeTransferLib.balanceOfOrZero(token, address(this));
        if (bal == 0) {
            emit TokensSwept(token, to, 0);
            return;
        }

        token.safeTransfer(to, bal);
        emit TokensSwept(token, to, bal);
    }
}

library Create2Lib {
    /// @notice Deploys a contract using CREATE2 opcode for deterministic addresses
    /// @dev Reverts with "CREATE2 failed" if deployment returns zero address
    /// @param value The amount of wei to send to the new contract
    /// @param salt The CREATE2 salt for deterministic address generation
    /// @param code The initialization bytecode of the contract to deploy
    /// @return addr The address of the deployed contract
    function deploy(
        uint256 value,
        bytes32 salt,
        bytes memory code
    ) internal returns (address addr) {
        assembly {
            addr := create2(value, add(code, 0x20), mload(code), salt)
        }
        require(addr != address(0), "CREATE2 failed");
    }
}

contract BuilderFactory {
    using Create2Lib for uint256;

    address public immutable OWNER;

    /// @notice Emitted when a new builder wallet is deployed
    /// @param builderCode The builder code used as salt
    /// @param wallet The address of the deployed wallet
    /// @param builderAdmin The admin address for the wallet
    event BuilderWalletDeployed(
        uint48 indexed builderCode,
        address indexed wallet,
        address indexed builderAdmin
    );

    /// @notice Constructs a new BuilderFactory instance
    /// @dev Reverts if owner is the zero address
    /// @param owner The address that will have permission to deploy new builder wallets
    constructor(address owner) {
        if (owner == address(0)) revert Errors.ZeroAddress();
        OWNER = owner;
    }

    /// @notice Modifier function to check if caller is the factory owner
    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    /// @notice Internal function to check if caller is the factory owner
    /// @dev Reverts with "NOT_OWNER" if msg.sender is not the OWNER
    function _onlyOwner() internal view {
        require(msg.sender == OWNER, "NOT_OWNER");
    }

    /// @notice Deploys a BuilderWallet contract using CREATE2.
    /// @param builderCode The uint256 used as the CREATE2 salt (must match caller's referral code).
    /// @param builderAdmin The EOA/multisig allowed to sweep tokens from the wallet.
    /// @return wallet The deployed wallet address (deterministic).
    function deployBuilder(
        uint48 builderCode,
        address builderAdmin
    ) external onlyOwner returns (address wallet) {
        bytes32 salt = bytes32(uint256(builderCode));

        // Constructor args are part of the init code and therefore part of the CREATE2 address.
        bytes memory initCode = abi.encodePacked(
            type(BuilderWallet).creationCode,
            abi.encode(address(this))
        );

        wallet = Create2Lib.deploy(0, salt, initCode);
        // now set the admin in storage (not part of init code)
        BuilderWallet(wallet).init(builderAdmin);

        emit BuilderWalletDeployed(builderCode, wallet, builderAdmin);
    }

    /// @notice Computes the CREATE2 address for (builderCode, builderAdmin).
    /// @dev Must match the formula used in the RiskEngine.
    function predictBuilderWallet(uint48 builderCode) external view returns (address) {
        bytes32 salt = bytes32(uint256(builderCode));

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(BuilderWallet).creationCode, abi.encode(address(this)))
        );

        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash));

        return address(uint160(uint256(h)));
    }
}
