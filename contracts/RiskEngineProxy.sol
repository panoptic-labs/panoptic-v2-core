// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title RiskEngineProxy
/// @author Axicon Labs Limited
/// @notice ERC-1967 transparent proxy that fronts a RiskEngine implementation.
/// @dev PanopticPools and CollateralTrackers bind to the RiskEngine address as an immutable clone argument, so this
/// proxy is the address they are deployed against. Swapping the implementation changes the risk parameters and logic
/// for every pool served by this proxy without redeploying any of them.
///
/// The RiskEngine implementations are stateless (constants + immutables only), so no initializer call is made and the
/// proxy's storage holds only the ERC-1967 implementation slot. Upgrades are performed through the `ProxyAdmin`
/// deployed by the constructor, whose owner starts as `initialOwner` (a multisig) and can later be transferred to a
/// `TimelockController` and then to a governance contract via `ProxyAdmin.transferOwnership`.
///
/// This contract deliberately adds no external functions: see the OpenZeppelin warning on extending
/// `TransparentUpgradeableProxy`.
///
/// Invariants every upgrade must preserve, because pools and trackers are not upgradable:
/// - every selector and return encoding in `IRiskEngine`
/// - the `RiskParameters`, `OraclePack` and `MarketState` packed layouts
/// - `vegoid()`, which is baked into SFPM pool ids at pool creation
contract RiskEngineProxy is TransparentUpgradeableProxy {
    /// @param implementation Address of the initial RiskEngine implementation.
    /// @param initialOwner Owner of the `ProxyAdmin` created for this proxy (the upgrade authority).
    constructor(
        address implementation,
        address initialOwner
    ) TransparentUpgradeableProxy(implementation, initialOwner, "") {}
}
