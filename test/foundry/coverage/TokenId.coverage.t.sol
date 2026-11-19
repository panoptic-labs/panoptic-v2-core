// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Errors} from "@libraries/Errors.sol";
import {TokenId, TokenIdLibrary} from "@types/TokenId.sol";
import {TokenIdHarness} from "../types/harnesses/TokenIdHarness.sol";

/// @notice Fills the coverage gaps left in `contracts/types/TokenId.sol` by the rest of the suite, both in `validate`:
/// - `InvalidTokenIdParameter(6)`: two legs touching the same chunk (same strike, width and tokenType)
/// - `InvalidTokenIdParameter(3)`: a risk partner index pointing past the last active leg
contract TokenIdCoverageTest is Test {
    TokenIdHarness internal harness;

    function setUp() public {
        harness = new TokenIdHarness();
    }

    function _base() internal view returns (TokenId) {
        return harness.addTickSpacing(harness.addPoolId(TokenId.wrap(0), 1), 10);
    }

    /// @dev Adds a short leg that is its own risk partner unless `riskPartner` says otherwise.
    function _leg(
        TokenId self,
        uint256 legIndex,
        uint256 tokenType,
        uint256 riskPartner,
        int24 strike,
        int24 width
    ) internal view returns (TokenId) {
        return harness.addLeg(self, legIndex, 1, 0, 0, tokenType, riskPartner, strike, width);
    }

    /*//////////////////////////////////////////////////////////////
                    DUPLICATE CHUNKS: PARAMETER TYPE 6
    //////////////////////////////////////////////////////////////*/

    function test_validate_revertsOnDuplicateChunk_twoLegs() public {
        TokenId tokenId = _leg(_base(), 0, 0, 0, 100, 2);
        tokenId = _leg(tokenId, 1, 0, 1, 100, 2);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenIdParameter.selector, 6));
        harness.validate(tokenId);
    }

    function test_validate_revertsOnDuplicateChunk_nonAdjacentLegs() public {
        // legs 1 and 3 collide while legs 0 and 2 are distinct: the inner loop must scan past leg 2
        TokenId tokenId = _leg(_base(), 0, 0, 0, 100, 2);
        tokenId = _leg(tokenId, 1, 0, 1, 200, 2);
        tokenId = _leg(tokenId, 2, 0, 2, 300, 2);
        tokenId = _leg(tokenId, 3, 0, 3, 200, 2);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenIdParameter.selector, 6));
        harness.validate(tokenId);
    }

    function test_validate_revertsOnDuplicateChunk_fuzz(
        int24 strike,
        int24 width,
        uint256 tokenType,
        uint256 isLongA,
        uint256 isLongB
    ) public {
        // the chunk is (strike, width, tokenType): the long/short flag and ratio do not make it distinct
        strike = int24(bound(strike, -887271, 887271));
        width = int24(bound(width, 0, 4095));
        tokenType = bound(tokenType, 0, 1);
        isLongA = bound(isLongA, 0, 1);
        isLongB = bound(isLongB, 0, 1);

        TokenId tokenId = harness.addLeg(_base(), 0, 1, 0, isLongA, tokenType, 0, strike, width);
        tokenId = harness.addLeg(tokenId, 1, 2, 0, isLongB, tokenType, 1, strike, width);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenIdParameter.selector, 6));
        harness.validate(tokenId);
    }

    function test_validate_distinctChunksPass() public view {
        // same strike and width, different tokenType: a distinct chunk
        TokenId tokenId = _leg(_base(), 0, 0, 0, 100, 2);
        tokenId = _leg(tokenId, 1, 1, 1, 100, 2);

        harness.validate(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
              RISK PARTNER OUT OF RANGE: PARAMETER TYPE 3
    //////////////////////////////////////////////////////////////*/

    function test_validate_revertsOnRiskPartnerPastLastLeg_singleLeg(uint256 riskPartner) public {
        riskPartner = bound(riskPartner, 1, 3);
        TokenId tokenId = _leg(_base(), 0, 0, riskPartner, 100, 2);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenIdParameter.selector, 3));
        harness.validate(tokenId);
    }

    function test_validate_revertsOnRiskPartnerPastLastLeg_twoLegs(uint256 riskPartner) public {
        // leg 0 is valid, leg 1 points at an inactive leg
        riskPartner = bound(riskPartner, 2, 3);
        TokenId tokenId = _leg(_base(), 0, 0, 0, 100, 2);
        tokenId = _leg(tokenId, 1, 0, riskPartner, 200, 2);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenIdParameter.selector, 3));
        harness.validate(tokenId);
    }

    function test_validate_revertsOnNonMutualRiskPartner() public {
        // in range but one-sided: leg 0 points at leg 1, leg 1 points at itself
        TokenId tokenId = _leg(_base(), 0, 0, 1, 100, 2);
        tokenId = _leg(tokenId, 1, 0, 1, 200, 2);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTokenIdParameter.selector, 3));
        harness.validate(tokenId);
    }

    function test_validate_mutualRiskPartnersPass() public view {
        TokenId tokenId = _leg(_base(), 0, 0, 1, 100, 2);
        tokenId = _leg(tokenId, 1, 0, 0, 200, 2);

        harness.validate(tokenId);
    }
}
