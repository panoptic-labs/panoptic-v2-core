// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;
import {Errors} from "@libraries/Errors.sol";

/// @notice Gas optimized reentrancy protection for smart contracts. Leverages Cancun transient storage.
/// @author Axicon Labs Limited
/// @author Modified from Solmate (https://github.com/transmissions11/solmate/blob/main/src/utils/TransientReentrancyGuard.sol)
/// @author Modified from Soledge (https://github.com/Vectorized/soledge/blob/main/src/utils/ReentrancyGuard.sol)
abstract contract TransientReentrancyGuard {
    uint256 private constant REENTRANCY_GUARD_SLOT =
        0x8053dfe21e206073e7d912b6bcd2323894159cfd58d0a607082c42be308afb86; // keccak256("panoptic.reentrancy.slot")

    /// @notice Prevents reentrant calls by setting and resetting the reentrancy guard
    /// @dev Sets the guard before function execution and resets it after. Reverts if already entered
    modifier nonReentrant() virtual {
        _nonReentrantSet();

        _;
        _nonReentrantReset();
    }

    /// @notice Guards view functions against read-only reentrancy.
    /// @dev If the reentrancy lock is currently active (meaning we are inside a state-changing function),
    /// this modifier will revert. This ensures external callers cannot read inconsistent state.
    modifier ensureNonReentrantView() virtual {
        _ensureNonReentrantView();
        _;
    }

    /// @notice Guards view functions against read-only reentrancy
    /// @dev If the reentrancy lock is currently active (meaning we are inside a state-changing function),
    /// this modifier will revert. This ensures external callers cannot read inconsistent state
    function _ensureNonReentrantView() internal view {
        if (reentrancyGuardEntered()) revert Errors.Reentrancy();
    }

    /// @notice Sets the reentrancy guard using transient storage
    /// @dev Checks if the guard is already set and reverts if so. Stores a non-zero value (address()) in the guard slot
    function _nonReentrantSet() internal {
        bool noReentrancy;

        /// @solidity memory-safe-assembly
        assembly {
            noReentrancy := iszero(tload(REENTRANCY_GUARD_SLOT))

            // Any non-zero value would work, but
            // ADDRESS is cheap and certainly not 0.
            // Wastes a bit of gas doing this before
            // require in the revert path, but we're
            // only optimizing for the happy path here.
            tstore(REENTRANCY_GUARD_SLOT, address())
        }

        if (!noReentrancy) revert Errors.Reentrancy();
    }

    /// @notice Resets the reentrancy guard to zero in transient storage
    /// @dev Must be called to clear the guard as transient storage persists until the end of the transaction, not just the call frame
    function _nonReentrantReset() internal {
        /// @solidity memory-safe-assembly
        assembly {
            // Need to set back to zero, as transient
            // storage is only cleared at the end of the
            // tx, not the end of the outermost call frame.
            tstore(REENTRANCY_GUARD_SLOT, 0)
        }
    }

    /// @notice Returns whether the reentrancy guard is currently entered (a protected function is executing).
    /// @return entered True if the reentrancy guard is active, false otherwise
    function reentrancyGuardEntered() public view returns (bool entered) {
        /// @solidity memory-safe-assembly
        assembly {
            entered := iszero(iszero(tload(REENTRANCY_GUARD_SLOT)))
        }
    }
}
