import "./FuzzDeployments.sol";

// Wrapper around FuzzDeployements used to demonstrate a different version of the
// short <> long relationship
// In this contract, the short options are tracked, and long options can only be created
// If a previously short option exist.
// The long option minting might fail if it tries to be applied on a short option that was burned
// Or liquidated
//
// Run with echidna .  --contract FuzzMint  --config contracts/fuzz/evaluate_minting.yaml
// This assume than the other mint functions (mint_option, mint_strategy) are disabled
// See the filterFunctions options in contracts/fuzz/evaluate_minting.yaml
contract FuzzMint is FuzzDeployments {
    // track all short and long positions created
    // The options are not removed when liquidated/burned
    // As a result the array can have duplicate
    TokenId[] shortPositions;
    TokenId[] longPositions;

    uint mint_short_counter; // Count how many short option are minted
    uint mint_long_counter; // Count how many short option are minted

    // Generate a short position
    function mint_short(
        bool asset,
        bool is_call,
        bool is_otm,
        bool is_atm,
        uint24 width,
        int256 strike,
        uint256 posSize
    ) public {
        address minter = msg.sender;

        TokenId tokenId = _generate_single_leg_tokenid(
            asset,
            is_call,
            false,
            is_otm,
            is_atm,
            width,
            strike
        );

        _mint_option(minter, tokenId, posSize, 0);
        shortPositions.push(tokenId);
        mint_short_counter += 1;
    }

    // Generate a long position
    function mint_long(bool asset, uint64 effLiqLimit, uint256 posSize, uint position) public {
        address minter = msg.sender;

        require(shortPositions.length > 0);

        TokenId tokenId = shortPositions[position % shortPositions.length];

        _mint_option(minter, tokenId, posSize, effLiqLimit);
        longPositions.push(tokenId);
        mint_long_counter += 1;
    }

    ////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////

    function getShortPositions() public view returns (TokenId[] memory) {
        return shortPositions;
    }

    function getLongPositions() public view returns (TokenId[] memory) {
        return longPositions;
    }

    ////////////////////////////////////////////////////
    // Echidna properties (debug purpose)
    ////////////////////////////////////////////////////

    // Check if Echidna can generate 10 short
    function echidna_mint_10_short() public view returns (bool) {
        return mint_short_counter < 10;
    }

    // Check if Echidna can generate 10 long
    function echidna_mint_10_long() public view returns (bool) {
        return mint_long_counter < 10;
    }

    // Check if Echidna can generate 5 long
    function echidna_mint_5_long() public view returns (bool) {
        return mint_long_counter < 5;
    }
}
