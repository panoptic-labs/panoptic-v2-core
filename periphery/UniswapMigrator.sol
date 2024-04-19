// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {PanopticFactory} from "@contracts/PanopticFactory.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";

import {IUniswapV3Factory} from "v3-core/interfaces/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Facilitates the migration from Uniswap LPing to PLPing.
contract UniswapMigrator {
    PanopticFactory public panopticFactory;
    INonfungiblePositionManager public univ3NFPM;
    IUniswapV3Factory public univ3Factory;

    constructor(
        PanopticFactory panopticFactory_,
        INonfungiblePositionManager univ3NFPM_,
        IUniswapV3Factory univ3Factory_
    ) {
        panopticFactory = panopticFactory_;
        univ3NFPM = univ3NFPM_;
        univ3Factory = univ3Factory_;
    }

    function migrate(uint256 tokenIds) external {
        // PRECONDITION: the user should either setApprovalForAll(uniswapMigrator) ahead of calling this function, or approve each position NFT one-by-one
        // otherwise it will revert. We don't require (ie:

        //     require(uniswapNFPM.isApprovedForAll(msg.sender, address(this)));

        // but we will revert inside the `for` on the first `decreaseLiquidity` call if unapproved.

        // TODO: There's an argument that this contract doesn't have to track how much it's collecting, and could just .approve the collateral tracker for this contract's whole balance of each token.
        // - Theoretically, this contract should start and end each call to this method with a token balance of 0 based on its own actions. The intermediate balance should only be from the `.collect` calls its making to Uniswap.
        // - If it was receiving random tokens outside of calls to this method, they'd just be donated to the subsequent caller of this method after that random transfer, which seems fine - we advise not transferring here for that reason but can't help it if people do.
        // However, to me, letting token transfers outside this method influence the amount we then pass into the CollateralTracker feels like it increases the attack surface area in exchange for a little gas saving.. I'd rather just track how much we're collecting and send that over:
        uint amount0Collected;
        uint amount1Collected;

        uint128 liquidity;
        address token0;
        address token1;
        for (uint i; i < tokenIds.length; ) {
            (, , token0, token1, , , , liquidity, , , , ) = univ3NFPM.positions(tokenIds[i]);
            univ3NFPM.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenIds[i],
                    liquidity: liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: uint32(block.timestamp)
                })
            );

            (uint amount0CollectedFromPosition, uint amount1CollectedFromPosition) = univ3NFPM
                .collect(
                    INonfungiblePositionManager.CollectParams({
                        tokenId: tokenIds[i],
                        recipient: address(this),
                        amount0Max: liquidity,
                        amount1Max: liquidity
                    })
                );

            amount0Collected += amount0CollectedFromPosition;
            amount1Collected += amount1CollectedFromPosition;

            univ3NFPM.burn(tokenIds[i]);

            unchecked {
                ++i;
            }
        }

        // TODO: I think the best way to get the collateral tracker for each token is to get the Uniswap pool for the pair of tokens, and then get Panoptic pool for the uniswap pool. Henry mentioned something about naming - is there a more efficient way to get the tracker from the name alone? I did not see one.
        PanopticPool pool = panopticFactory.getPanopticPool(univ3Factory.getPool(token0, token1));

        CollateralTracker ct0 = pool.collateralToken0();
        IERC20(token0).approve(ct0, amount0Collected);
        ct0.deposit(amount0Collected, msg.sender);

        CollateralTracker ct1 = pool.collateralToken1();
        IERC20(token1).approve(ct1, amount1Collected);
        ct1.deposit(amount1Collected, msg.sender);
    }

    // TODO: alternative .migrate that takes in an array of pairs of amount0Min and amount1Min so you can ensure the tokens you pull out of uniswap and put into the PLP are at the ratio you desire (IE: slippage protection).
    // same logic as the above .migrate but passes in minimums[i].amount0/1Min in the .decreaseLiquidity call
    function migrate(uint256 tokenIds, uint256[][] amountMins) external {}
}
