// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Dummy contract that will not revert when called
contract Dummy {
    fallback() external payable {
        // Do nothing
    }
}
