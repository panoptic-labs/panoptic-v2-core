// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title RiskEngineStub
/// @author Axicon Labs Limited
/// @notice Placeholder implementation for a RiskEngineProxy that is reserved for a future risk tier.
/// @dev ERC-1967 requires the implementation to have code, so a reserved proxy cannot point at address(0).
/// Every call reverts, so the factory's `riskEngine.vegoid()` check fails and no pool can be created against
/// the proxy until the ProxyAdmin upgrades it to a real RiskEngine.
contract RiskEngineStub {
    error RiskEngineNotSet();

    fallback() external {
        revert RiskEngineNotSet();
    }
}
