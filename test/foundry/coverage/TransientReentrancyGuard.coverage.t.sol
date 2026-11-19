// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Errors} from "@libraries/Errors.sol";
import {TransientReentrancyGuard} from "@libraries/TransientReentrancyGuard.sol";

interface IReentryHook {
    function onGuardedCall() external;
}

contract GuardedVault is TransientReentrancyGuard {
    uint256 public counter;

    /// @dev Guarded entry point that hands control to the caller mid-execution.
    function guardedCallback() external nonReentrant {
        counter++;
        IReentryHook(msg.sender).onGuardedCall();
    }

    function guardedIncrement() external nonReentrant {
        counter++;
    }

    function guardedRevert() external nonReentrant {
        revert("inner failure");
    }

    function guardedView() external view ensureNonReentrantView returns (uint256) {
        return counter;
    }
}

/// @notice Fills the coverage gaps left in `contracts/libraries/TransientReentrancyGuard.sol` by the rest of the
/// suite: the public `reentrancyGuardEntered` getter and the read-only reentrancy revert.
contract TransientReentrancyGuardCoverageTest is Test, IReentryHook {
    GuardedVault internal vault;

    /// @dev What the hook does while the guard is held.
    uint256 internal mode;
    bool internal enteredDuringCall;
    uint256 internal viewDuringCall;

    function setUp() public {
        vault = new GuardedVault();
    }

    function onGuardedCall() external {
        enteredDuringCall = vault.reentrancyGuardEntered();

        if (mode == 1) {
            vault.guardedView();
        } else if (mode == 2) {
            vault.guardedIncrement();
        } else if (mode == 3) {
            vault.guardedCallback();
        } else if (mode == 4) {
            // a caught reentrancy revert must leave the outer call's guard in place
            try vault.guardedView() returns (uint256 value) {
                viewDuringCall = value;
            } catch {
                viewDuringCall = type(uint256).max;
            }
            enteredDuringCall = vault.reentrancyGuardEntered();
        }
    }

    function test_reentrancyGuardEntered_falseOutsideGuardedCalls() public {
        assertFalse(vault.reentrancyGuardEntered(), "before");

        vault.guardedIncrement();

        assertFalse(vault.reentrancyGuardEntered(), "released after the call");
    }

    function test_reentrancyGuardEntered_trueInsideGuardedCall() public {
        vault.guardedCallback();

        assertTrue(enteredDuringCall, "held during the call");
        assertFalse(vault.reentrancyGuardEntered(), "released after the call");
        assertEq(vault.counter(), 1);
    }

    function test_ensureNonReentrantView_passesOutsideGuardedCalls() public {
        vault.guardedIncrement();

        assertEq(vault.guardedView(), 1);
    }

    function test_ensureNonReentrantView_revertsInsideGuardedCall() public {
        mode = 1;

        vm.expectRevert(Errors.Reentrancy.selector);
        vault.guardedCallback();

        assertEq(vault.counter(), 0, "outer call rolled back");
    }

    function test_ensureNonReentrantView_caughtRevertKeepsGuardHeld() public {
        mode = 4;

        vault.guardedCallback();

        assertEq(viewDuringCall, type(uint256).max, "view reverted while the guard was held");
        assertTrue(enteredDuringCall, "guard still held after the caught revert");
        assertFalse(vault.reentrancyGuardEntered(), "released after the call");
        assertEq(vault.guardedView(), 1, "view works again");
    }

    function test_nonReentrant_revertsOnReentryIntoAnotherGuardedFunction() public {
        mode = 2;

        vm.expectRevert(Errors.Reentrancy.selector);
        vault.guardedCallback();
    }

    function test_nonReentrant_revertsOnReentryIntoTheSameFunction() public {
        mode = 3;

        vm.expectRevert(Errors.Reentrancy.selector);
        vault.guardedCallback();
    }

    function test_nonReentrant_releasesGuardWhenTheCallReverts() public {
        vm.expectRevert(bytes("inner failure"));
        vault.guardedRevert();

        // the transient write is rolled back with the call, so the next call in the same transaction goes through
        assertFalse(vault.reentrancyGuardEntered(), "not left locked");
        vault.guardedIncrement();
        assertEq(vault.counter(), 1);
    }

    function test_nonReentrant_sequentialCallsInOneTransaction(uint8 calls) public {
        for (uint256 i; i < calls; ++i) vault.guardedIncrement();

        assertEq(vault.counter(), calls);
        assertFalse(vault.reentrancyGuardEntered());
    }
}
