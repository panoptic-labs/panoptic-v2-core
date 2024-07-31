// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import "./FuzzHelpers.sol";
import {SFPMActions} from "./SFPMActions.sol";

contract CollateralActions is SFPMActions {
    /*//////////////////////////////////////////////////////////////
                          POSITIVE FUNCTIONAL
    //////////////////////////////////////////////////////////////*/

    /// @custom:property PANO-DEP-001 The Panoptic pool balance must increase by the deposited amount when a deposit is made (or the corresponding amount of assets for a given share value when a mint is made)
    /// @custom:property PANO-DEP-002 The user balance must decrease by the deposited amount when a deposit is made (or the corresponding amount of assets for a given share value when a mint is made)
    /// @custom:property PANO-DEP-003 A user's share balance must increase by the amount of shares previewMint returns
    function deposit_to_ct(bool token0, uint256 assets, bool viaMint) public {
        if (token0) {
            emit LogString("Attempting to deposit/mint token0");
            _deposit_and_check(collToken0, viaMint, assets, msg.sender);
        } else {
            emit LogString("Attempting to deposit/mint token1");
            _deposit_and_check(collToken1, viaMint, assets, msg.sender);
        }
    }

    function _deposit_and_check(
        CollateralTracker collToken,
        bool viaMint,
        uint256 assets,
        address depositor
    ) internal {
        uint256 depositorBalBefore = IERC20(collToken.asset()).balanceOf(depositor);
        uint256 poolBalBefore = IERC20(collToken.asset()).balanceOf(address(panopticPool));
        uint256 sharesBefore = collToken.balanceOf(depositor);

        assets = bound(assets, 1, MAX_DEPOSIT);

        // Limit the maximum amount of collateral to deposit
        if (collToken.convertToAssets(collToken.balanceOf(depositor)) > 10 * MAX_DEPOSIT) {
            return;
        }
        assets = bound(assets, MIN_DEPOSIT, min(MAX_DEPOSIT, depositorBalBefore / 10));
        uint256 shares = collToken.previewDeposit(assets);

        hevm.prank(depositor);
        if (viaMint) {
            collToken.mint(shares, depositor);
        } else {
            collToken.deposit(assets, depositor);
        }

        uint256 poolBalAfter = IERC20(collToken.asset()).balanceOf(address(panopticPool));
        assertWithMsg(
            poolBalAfter - poolBalBefore == assets,
            "Pool token balance incorrect after deposit"
        );
        uint256 depositorBalAfter = IERC20(collToken.asset()).balanceOf(depositor);
        assertWithMsg(
            depositorBalBefore - depositorBalAfter == assets,
            "User token balance incorrect after deposit"
        );
        uint256 sharesAfter = collToken.balanceOf(depositor);
        assertWithMsg(
            sharesAfter - sharesBefore == shares,
            "User shares balance incorrect after deposit"
        );
    }

    /// @custom:property PANO-WIT-001 The Panoptic pool balance must decrease by the withdrawn amount when a withdrawal is made
    /// @custom:property PANO-WIT-002 The user balance must increase by the withdrawn amount when a withdrawal is made
    function withdraw_from_ct(
        bool token0,
        bool viaRedeem,
        uint256 assets,
        address withdrawer
    ) public {
        uint256 numOfPositions = panopticPool.numberOfPositions(withdrawer);
        if (numOfPositions > 0) {
            if (token0) {
                emit LogString("Attempting to withdraw token0 with open positions");
                _withdraw_with_open_positions_and_check(collToken0, assets, withdrawer, true);
            } else {
                emit LogString("Attempting to withdraw token1 with open positions");
                _withdraw_with_open_positions_and_check(collToken1, assets, withdrawer, false);
            }
        } else {
            if (token0) {
                emit LogString("Attempting to withdraw/redeem token0 without open positions");
                _regular_withdraw_and_check(collToken0, viaRedeem, assets, withdrawer);
            } else {
                emit LogString("Attempting to withdraw/redeem token1 without open positions");
                _regular_withdraw_and_check(collToken1, viaRedeem, assets, withdrawer);
            }
        }
    }

    function _regular_withdraw_and_check(
        CollateralTracker collToken,
        bool viaRedeem,
        uint256 assetsToWithdraw,
        address withdrawer
    ) internal {
        uint256 withdrawerAssetsBefore = IERC20(collToken.asset()).balanceOf(withdrawer);
        uint256 poolAssetsBefore = IERC20(collToken.asset()).balanceOf(address(panopticPool));
        uint256 withdrawerSharesBefore = collToken.balanceOf(withdrawer);

        assetsToWithdraw = bound(
            assetsToWithdraw,
            1,
            _max_assets_withdrawable(collToken, collToken.balanceOf(withdrawer))
        );

        uint256 sharesToWithdraw = collToken.previewWithdraw(assetsToWithdraw);

        hevm.prank(withdrawer);
        if (viaRedeem) {
            try collToken.redeem(sharesToWithdraw, withdrawer, withdrawer) {
                uint256 poolAssetsAfter = IERC20(collToken.asset()).balanceOf(
                    address(panopticPool)
                );
                uint256 withdrawerAssetsAfter = IERC20(collToken.asset()).balanceOf(withdrawer);
                uint256 withdrawerSharesAfter = collToken.balanceOf(withdrawer);
                assertWithMsg(
                    poolAssetsBefore - poolAssetsAfter == assetsToWithdraw,
                    "Pool asset balance incorrect after redemption"
                );
                assertWithMsg(
                    withdrawerAssetsAfter - withdrawerAssetsBefore == assetsToWithdraw,
                    "User balance incorrect after redemption"
                );
                assertWithMsg(
                    withdrawerSharesBefore - withdrawerSharesAfter == sharesToWithdraw,
                    "User share balance incorrect after redemption"
                );
            } catch {
                assertWithMsg(false, "Failed to redeem for unknown reason");
            }
        } else {
            try collToken.withdraw(assetsToWithdraw, withdrawer, withdrawer) {
                uint256 poolAssetsAfter = IERC20(collToken.asset()).balanceOf(
                    address(panopticPool)
                );
                uint256 withdrawerAssetsAfter = IERC20(collToken.asset()).balanceOf(withdrawer);
                uint256 withdrawerSharesAfter = collToken.balanceOf(withdrawer);
                assertWithMsg(
                    poolAssetsBefore - poolAssetsAfter == assetsToWithdraw,
                    "Pool asset balance incorrect after withdrawal"
                );
                assertWithMsg(
                    withdrawerAssetsAfter - withdrawerAssetsBefore == assetsToWithdraw,
                    "User balance incorrect after withdrawal"
                );
                assertWithMsg(
                    withdrawerSharesBefore - withdrawerSharesAfter == sharesToWithdraw,
                    "User share balance incorrect after withdrawal"
                );
            } catch {
                assertWithMsg(false, "Failed to withdraw for unknown reason");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          NEGATIVE FUNCTIONAL
    //////////////////////////////////////////////////////////////*/

    /// @custom:property PANO-SYS-001 The max withdrawal or redemption amount of users with open positions is zero, excluding the overloaded withdraw that takes in a positionId list
    /// @custom:property PANO-SYS-002 Users can't withdraw or redeem collateral with open positions, excluding the overloaded withdraw that takes in a positionId list
    /// @custom:precondition The user has a position open
    function invariant_collateral_removal_via_withdrawal_or_redemption(
        uint256 fuzzNumerator,
        uint256 fuzzDenominator,
        address recipient,
        uint256 fullOrSelfFuzz
    ) public {
        uint256 numOfPositions = panopticPool.numberOfPositions(msg.sender);
        emit LogAddress("Caller", msg.sender);
        emit LogUint256("Positions opened for user", numOfPositions);

        if (numOfPositions > 0) {
            uint256 shareBal0 = collToken0.balanceOf(msg.sender);
            uint256 shareBal1 = collToken1.balanceOf(msg.sender);
            uint assetBal0 = collToken0.convertToAssets(shareBal0);
            uint assetBal1 = collToken1.convertToAssets(shareBal1);

            assertWithMsg(
                collToken0.maxWithdraw(msg.sender) == 0 && collToken1.maxWithdraw(msg.sender) == 0,
                "It is possible to withdraw assets when the user has open positions"
            );
            assertWithMsg(
                collToken0.maxRedeem(msg.sender) == 0 && collToken1.maxRedeem(msg.sender) == 0,
                "It is possible to redeem assets when the user has open positions"
            );

            // fuzz a fraction of the total balance to try and withdraw
            if (fuzzNumerator > fuzzDenominator)
                (fuzzNumerator, fuzzDenominator) = (fuzzDenominator, fuzzNumerator);

            // attempt a full withdrawal every 3rd attempt, and a self-withdrawal every 5th attempt, to ensure we're testing those cases
            if (fullOrSelfFuzz % 3 == 0) fuzzNumerator = fuzzDenominator;
            if (fullOrSelfFuzz % 5 == 0) recipient = msg.sender;

            uint256 fuzzedSharesToRedeem0 = (shareBal0 * fuzzNumerator) / fuzzDenominator;
            uint256 fuzzedSharesToRedeem1 = (shareBal1 * fuzzNumerator) / fuzzDenominator;

            uint256 fuzzedAssetsToWithdraw0 = (assetBal0 * fuzzNumerator) / fuzzDenominator;
            uint256 fuzzedAssetsToWithdraw1 = (assetBal1 * fuzzNumerator) / fuzzDenominator;

            if (fuzzedAssetsToWithdraw0 > 0) {
                hevm.prank(msg.sender);
                try collToken0.redeem(fuzzedSharesToRedeem0, recipient, msg.sender) {
                    assertWithMsg(false, "Collateral could be removed with open positions");
                } catch {}

                hevm.prank(msg.sender);
                try collToken0.withdraw(fuzzedAssetsToWithdraw0, recipient, msg.sender) {
                    assertWithMsg(false, "Collateral could be removed with open positions");
                } catch {}
            }

            if (fuzzedAssetsToWithdraw1 > 0) {
                hevm.prank(msg.sender);
                try collToken1.redeem(fuzzedSharesToRedeem1, recipient, msg.sender) {
                    assertWithMsg(false, "Collateral could be removed with open positions");
                } catch {}

                hevm.prank(msg.sender);
                try collToken1.withdraw(fuzzedAssetsToWithdraw1, recipient, msg.sender) {
                    assertWithMsg(false, "Collateral could be removed with open positions");
                } catch {}
            }
        }
    }

    /// @custom:property PANO-SYS-003 The max transfer amount of users with open positions is zero
    /// @custom:property PANO-SYS-004 Users can't transfer collateral with open positions
    /// @custom:precondition The user has a position open
    function invariant_collateral_removal_via_transfer(
        uint256 fuzzNumerator,
        uint256 fuzzDenominator,
        address recipient,
        uint256 fullOrNotFuzz
    ) public {
        uint256 numOfPositions = panopticPool.numberOfPositions(msg.sender);
        emit LogAddress("Caller", msg.sender);
        emit LogUint256("Positions opened for user", numOfPositions);

        if (numOfPositions > 0) {
            uint256 bal0 = collToken0.balanceOf(msg.sender);
            uint256 bal1 = collToken1.balanceOf(msg.sender);

            if (fuzzNumerator > fuzzDenominator)
                (fuzzNumerator, fuzzDenominator) = (fuzzDenominator, fuzzNumerator);

            uint256 fuzzedAmtToTransfer0 = (bal0 * fuzzNumerator) / fuzzDenominator;
            uint256 fuzzedAmtToTransfer1 = (bal1 * fuzzNumerator) / fuzzDenominator;

            // attempt a full withdrawal every 4th attempt, to ensure we're testing that case too
            if (fullOrNotFuzz % 4 == 0) (fuzzedAmtToTransfer0, fuzzedAmtToTransfer1) = (bal0, bal1);

            if (fuzzedAmtToTransfer0 > 0) {
                hevm.prank(msg.sender);
                try collToken0.transfer(recipient, fuzzedAmtToTransfer0) {
                    assertWithMsg(
                        false,
                        "Collateral could be removed via transfer with open positions"
                    );
                } catch {}

                hevm.prank(msg.sender);
                collToken0.approve(recipient, fuzzedAmtToTransfer0);

                hevm.prank(recipient);
                try collToken0.transferFrom(msg.sender, recipient, fuzzedAmtToTransfer0) {
                    assertWithMsg(
                        false,
                        "Collateral could be removed via transferFrom with open positions"
                    );
                } catch {}
            }
            if (fuzzedAmtToTransfer1 > 0) {
                hevm.prank(msg.sender);
                try collToken1.transfer(recipient, fuzzedAmtToTransfer1) {
                    assertWithMsg(
                        false,
                        "Collateral could be removed via transfer with open positions"
                    );
                } catch {}

                hevm.prank(msg.sender);
                collToken1.approve(recipient, fuzzedAmtToTransfer1);

                hevm.prank(recipient);
                try collToken1.transferFrom(msg.sender, recipient, fuzzedAmtToTransfer1) {
                    assertWithMsg(
                        false,
                        "Collateral could be removed via transferFrom with open positions"
                    );
                } catch {}
            }
        }
    }

    /// @custom:property PANO-SYS-005 Users can't use the overloaded withdraw to withdraw so much that it makes their open positions insolvent
    function invariant_collateral_overremoval_with_open_positions(
        CollateralTracker collToken,
        uint256 amountToWithdraw
    ) public {
        _attempt_collateral_overremoval(collToken0, msg.sender, true, amountToWithdraw);
        _attempt_collateral_overremoval(collToken1, msg.sender, false, amountToWithdraw);
    }

    function _attempt_collateral_overremoval(
        CollateralTracker collToken,
        address withdrawer,
        bool isToken0,
        uint256 amountToWithdraw
    ) internal {
        TokenId[] memory withdrawersOpenPositions = userPositions[withdrawer];
        // return early if user has no open positions
        if (withdrawersOpenPositions.length == 0) return;

        amountToWithdraw = bound(
            amountToWithdraw,
            1,
            _max_assets_withdrawable(collToken, collToken.balanceOf(withdrawer))
        );
        try panopticPool.validateCollateralWithdrawable(withdrawer, withdrawersOpenPositions) {
            // Do nothing: the user _can_ withdraw their collateral, so there's nothing to test
        } catch {
            // if validateCollateralWithdrawable says we should not be able to withdraw,
            // then we should fail here:
            hevm.prank(withdrawer);
            try
                collToken.withdraw(
                    amountToWithdraw,
                    withdrawer,
                    withdrawer,
                    withdrawersOpenPositions
                )
            {
                assertWithMsg(
                    false,
                    "User was able to withdraw despite validateCollateralWithdrawable saying they could not"
                );
            } catch {}
        }
    }

    /// @custom:property PANO-SYS-009 No user can ever withdraw greater than the Collateral Tracker's internally-accounted poolAssets
    function invariant_no_withdrawal_gt_pool_assets(
        address owner,
        address recipient,
        uint256 amountOver,
        bool nonOwnerCall
    ) public {
        _attempt_withdrawal_gt_pool_assets_via_withdraw(
            collToken0,
            owner,
            recipient,
            amountOver,
            nonOwnerCall
        );
        _attempt_withdrawal_gt_pool_assets_via_withdraw(
            collToken1,
            owner,
            recipient,
            amountOver,
            nonOwnerCall
        );

        _attempt_withdrawal_gt_pool_assets_via_redeem(
            collToken0,
            owner,
            recipient,
            amountOver,
            nonOwnerCall
        );
        _attempt_withdrawal_gt_pool_assets_via_redeem(
            collToken1,
            owner,
            recipient,
            amountOver,
            nonOwnerCall
        );
    }

    function _attempt_withdrawal_gt_pool_assets_via_withdraw(
        CollateralTracker collToken,
        address owner,
        address recipient,
        uint256 amountOver,
        bool nonOwnerCall
    ) internal {
        (uint256 ct_s_poolAssets, , ) = collToken.getPoolData();
        amountOver = bound(amountOver, 1, type(uint256).max - ct_s_poolAssets);
        uint256 numOfPositions = panopticPool.numberOfPositions(owner);
        TokenId[] memory withdrawersOpenPositions = userPositions[owner];

        hevm.prank(owner);
        if (nonOwnerCall) {
            collToken.approve(recipient, collToken.convertToShares(ct_s_poolAssets + amountOver));
            hevm.prank(recipient);
        }

        if (numOfPositions == 0) {
            try collToken.withdraw(ct_s_poolAssets + amountOver, recipient, owner) {
                assertWithMsg(false, "User withdrew > collateralTokens poolAssets");
            } catch {
                if (
                    collToken.convertToShares(ct_s_poolAssets + amountOver) >
                    collToken.balanceOf(owner)
                ) {
                    emit LogString(
                        "invariant_no_withdrawal_gt_pool_assets succeeded because user didnt have enough shares to attempt overwithdrawal"
                    );
                } else {
                    // NOTE: we could add a deal of the collToken.asset() if we wanted to ensure we hit this case more often
                    emit LogString(
                        "invariant_no_withdrawal_gt_pool_assets succeeded, possibly because we correctly enforced a max withdrawal of ct_s_poolAssets"
                    );
                }
            }

            nonOwnerCall ? hevm.prank(recipient) : hevm.prank(owner);
            try
                collToken.withdraw(ct_s_poolAssets + amountOver, recipient, owner, new TokenId[](0))
            {
                assertWithMsg(false, "User withdrew > collateralTokens poolAssets");
            } catch {
                if (
                    collToken.convertToShares(ct_s_poolAssets + amountOver) >
                    collToken.balanceOf(owner)
                ) {
                    emit LogString(
                        "invariant_no_withdrawal_gt_pool_assets succeeded because user didnt have enough shares to attempt overwithdrawal"
                    );
                } else {
                    // NOTE: we could add a deal of the collToken.asset() if we wanted to ensure we hit this case more often
                    emit LogString(
                        "invariant_no_withdrawal_gt_pool_assets succeeded, possibly because we correctly enforced a max withdrawal of ct_s_poolAssets"
                    );
                }
            }
        } else {
            try
                collToken.withdraw(
                    ct_s_poolAssets + amountOver,
                    recipient,
                    owner,
                    withdrawersOpenPositions
                )
            {
                assertWithMsg(false, "User withdrew > collateralTokens poolAssets");
            } catch {
                if (
                    collToken.convertToShares(ct_s_poolAssets + amountOver) >
                    collToken.balanceOf(owner)
                ) {
                    emit LogString(
                        "invariant_no_withdrawal_gt_pool_assets succeeded because user didnt have enough shares to attempt overwithdrawal"
                    );
                } else {
                    // NOTE: we could add a deal of the collToken.asset() if we wanted to ensure we hit this case more often
                    emit LogString(
                        "invariant_no_withdrawal_gt_pool_assets succeeded, possibly because we correctly enforced a max withdrawal of ct_s_poolAssets"
                    );
                }
            }
        }
    }

    function _attempt_withdrawal_gt_pool_assets_via_redeem(
        CollateralTracker collToken,
        address owner,
        address recipient,
        uint256 amountOver,
        bool nonOwnerCall
    ) internal {
        (uint256 ct_s_poolAssets, , ) = collToken.getPoolData();
        amountOver = bound(amountOver, 1, type(uint256).max - ct_s_poolAssets);

        uint256 numOfPositions = panopticPool.numberOfPositions(owner);
        if (numOfPositions == 0) {
            hevm.prank(owner);
            if (nonOwnerCall) {
                collToken.approve(
                    recipient,
                    collToken.convertToShares(ct_s_poolAssets) + amountOver
                );
                hevm.prank(recipient);
            }

            try
                collToken.redeem(
                    collToken.convertToShares(ct_s_poolAssets) + amountOver,
                    recipient,
                    owner
                )
            {
                assertWithMsg(false, "User redeemed > the poolAssets of collToken");
            } catch {
                if (
                    collToken.convertToShares(ct_s_poolAssets + amountOver) >
                    collToken.balanceOf(owner)
                ) {
                    emit LogString(
                        "invariant_no_withdrawal_gt_pool_assets succeeded because user didnt have enough shares to attempt overwithdrawal"
                    );
                } else {
                    // NOTE: we could add a deal of the collToken.asset() if we wanted to ensure we hit this case more often
                    emit LogString(
                        "invariant_no_withdrawal_gt_pool_assets succeeded, possibly because we correctly enforced a max redemption of convertToShares(ct_s_poolAssets)"
                    );
                }
            }
        }
    }

    /// @custom:property PANO-SYS-010 No user can ever withdraw, redeem, nor transfer an amount greater than their own balance
    function invariant_never_allow_overremoval(
        address owner,
        address recipient,
        uint256 amountOver,
        bool nonOwnerCall
    ) public {
        _attempt_overwithdrawal_via_withdraw(
            collToken0,
            owner,
            recipient,
            amountOver,
            nonOwnerCall
        );
        _attempt_overwithdrawal_via_withdraw(
            collToken1,
            owner,
            recipient,
            amountOver,
            nonOwnerCall
        );

        uint256 numOfPositions = panopticPool.numberOfPositions(owner);
        if (numOfPositions == 0) {
            _attempt_overwithdrawal_via_redeem(
                collToken0,
                owner,
                recipient,
                amountOver,
                nonOwnerCall
            );
            _attempt_overwithdrawal_via_redeem(
                collToken1,
                owner,
                recipient,
                amountOver,
                nonOwnerCall
            );

            _attempt_overtransfer(collToken0, owner, recipient, amountOver, nonOwnerCall);
            _attempt_overtransfer(collToken1, owner, recipient, amountOver, nonOwnerCall);
        }
    }

    function _attempt_overwithdrawal_via_withdraw(
        CollateralTracker collToken,
        address owner,
        address recipient,
        uint256 amountOver,
        bool nonOwnerCall
    ) internal {
        uint256 ownersAssets = collToken.convertToAssets(collToken.balanceOf(owner));
        amountOver = bound(amountOver, 1, type(uint256).max - ownersAssets);
        uint256 numOfPositions = panopticPool.numberOfPositions(owner);
        TokenId[] memory withdrawersOpenPositions = userPositions[owner];

        hevm.prank(owner);
        // every other attempt, make it a non-owner call:
        if (nonOwnerCall) {
            collToken.approve(recipient, collToken.convertToShares(ownersAssets) + amountOver);
            hevm.prank(recipient);
        }

        if (numOfPositions == 0) {
            try collToken.withdraw(ownersAssets + amountOver, recipient, owner) {
                assertWithMsg(false, "User withdrew > their balance");
            } catch {}

            nonOwnerCall ? hevm.prank(recipient) : hevm.prank(owner);
            try collToken.withdraw(ownersAssets + amountOver, recipient, owner, new TokenId[](0)) {
                assertWithMsg(false, "User withdrew > their balance");
            } catch {}
        } else {
            try
                collToken.withdraw(
                    ownersAssets + amountOver,
                    recipient,
                    owner,
                    withdrawersOpenPositions
                )
            {
                assertWithMsg(false, "User withdrew > their balance");
            } catch {}
        }
    }

    function _attempt_overwithdrawal_via_redeem(
        CollateralTracker collToken,
        address owner,
        address recipient,
        uint256 amountOver,
        bool nonOwnerCall
    ) internal {
        uint256 ownersShares = collToken.balanceOf(owner);
        amountOver = bound(amountOver, 1, type(uint256).max - ownersShares);

        hevm.prank(owner);
        if (nonOwnerCall) {
            collToken.approve(recipient, ownersShares + amountOver);
            hevm.prank(recipient);
        }

        try collToken.redeem(ownersShares + amountOver, recipient, owner) {
            assertWithMsg(false, "User redeemed > their balance");
        } catch {}
    }

    function _attempt_overtransfer(
        CollateralTracker collToken,
        address owner,
        address recipient,
        uint256 amountOver,
        bool nonOwnerCall
    ) internal {
        uint256 ownersShares = collToken.balanceOf(owner);
        amountOver = bound(amountOver, 1, type(uint256).max - ownersShares);
        hevm.prank(owner);
        if (nonOwnerCall) {
            try collToken.transfer(recipient, ownersShares + amountOver) {
                assertWithMsg(false, "User transferred > their balance");
            } catch {}
        } else {
            collToken.approve(recipient, ownersShares + amountOver);
            hevm.prank(recipient);
            try collToken.transferFrom(owner, recipient, ownersShares + amountOver) {
                assertWithMsg(false, "User transferFromed > their balance");
            } catch {}
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 GLOBAL
    //////////////////////////////////////////////////////////////*/

    /// @custom:property PANO-SYS-008 The Collateral Tracker's internal accounting always shows it has less than or equal to its true balance of the underlying token
    function invariant_never_overcount_underlying_token() public {
        (uint256 ct0_s_poolAssets, , ) = collToken0.getPoolData();
        assertWithMsg(
            ct0_s_poolAssets <= IERC20(collToken0.asset()).balanceOf(address(panopticPool)) + 1,
            "CollateralTracker0 has overcounted its token0 assets"
        );

        (uint256 ct1_s_poolAssets, , ) = collToken1.getPoolData();
        assertWithMsg(
            ct1_s_poolAssets <= IERC20(collToken1.asset()).balanceOf(address(panopticPool)) + 1,
            "CollateralTracker1 has overcounted its token1 assets"
        );
    }

    /// @custom:property PANO-SYS-011 The pool can never have a utilisation over 100%
    function invariant_never_allow_pool_utilisation_over_100p() public {
        (, , int256 collToken0PU) = collToken0.getPoolData();
        assertWithMsg(
            collToken0PU <= 10000,
            "collToken0 pool utilisation exceeded 10k bps <=> 100%"
        );

        (, , int256 collToken1PU) = collToken1.getPoolData();
        assertWithMsg(
            collToken1PU <= 10000,
            "collToken1 pool utilisation exceeded 10k bps <=> 100%"
        );
    }

    /// @custom:property PANO-SYS-012 Users can't deposit more than the maximum allowed amount, 2^104
    function invariant_never_allow_overdeposit(
        address receiver,
        uint256 tooLargeDepositAmount,
        bool depositToSelf
    ) public {
        _attempt_overdeposit(true, msg.sender, receiver, tooLargeDepositAmount, depositToSelf);
        _attempt_overdeposit(false, msg.sender, receiver, tooLargeDepositAmount, depositToSelf);
    }

    function _attempt_overdeposit(
        bool isToken0,
        address depositor,
        address receiver,
        uint256 tooLargeDepositAmount,
        bool depositToSelf
    ) internal {
        CollateralTracker collToken = isToken0 ? collToken0 : collToken1;
        uint256 maxDeposit = type(uint104).max;
        tooLargeDepositAmount = bound(tooLargeDepositAmount, maxDeposit + 1, type(uint256).max);

        if (depositToSelf) {
            receiver = depositor;
        }

        uint256 depositorBalance = IERC20(collToken.asset()).balanceOf(depositor);
        uint256 shortfallForDeposit = tooLargeDepositAmount - depositorBalance;
        isToken0
            ? deal_USDC(depositor, shortfallForDeposit)
            : deal_WETH(depositor, shortfallForDeposit);
        hevm.prank(depositor);
        IERC20(collToken.asset()).approve(address(collToken), type(uint256).max);

        hevm.prank(depositor);
        try collToken.deposit(tooLargeDepositAmount, receiver) {
            assertWithMsg(false, "Deposit over maximum allowed did not revert");
        } catch {
            emit LogString(
                "Invariant succeeded, likely because we enforced the max deposit amount correctly"
            );
        }
    }

    /// @custom:property PANO-SYS-013 Users can't mint more than the maximum allowed amount, 2^104
    function invariant_never_allow_overmint(
        address minter,
        address receiver,
        uint256 tooLargeMintAmount,
        bool mintToSelf
    ) public {
        _attempt_overmint(true, minter, receiver, tooLargeMintAmount, mintToSelf);
        _attempt_overmint(false, minter, receiver, tooLargeMintAmount, mintToSelf);
    }

    function _attempt_overmint(
        bool isToken0,
        address minter,
        address receiver,
        uint256 tooLargeMintAmount,
        bool mintToSelf
    ) internal {
        CollateralTracker collToken = isToken0 ? collToken0 : collToken1;
        uint256 maxMint = collToken.previewDeposit(type(uint104).max);
        tooLargeMintAmount = bound(tooLargeMintAmount, maxMint + 1, type(uint256).max);

        if (mintToSelf) {
            receiver = minter;
        }

        uint256 minterBalance = IERC20(collToken.asset()).balanceOf(minter);
        uint256 shortfallForMint = collToken.previewDeposit(tooLargeMintAmount) - minterBalance;
        isToken0 ? deal_USDC(minter, shortfallForMint) : deal_WETH(minter, shortfallForMint);

        hevm.prank(minter);
        IERC20(collToken.asset()).approve(address(collToken), type(uint256).max);
        hevm.prank(minter);
        try collToken.mint(tooLargeMintAmount, receiver) {
            assertWithMsg(false, "Mint over maximum allowed did not revert");
        } catch {
            emit LogString(
                "Invariant succeeded, likely because we enforced the max mint amount correctly"
            );
        }
    }

    /// @custom:property PANO-SYS-014 Users can't deposit/mint more than their balance
    function invariant_no_mint_nor_deposit_over_balance(
        address receiver,
        uint256 amountOver,
        bool viaMint
    ) public {
        _attempt_deposit_over_balance(collToken0, msg.sender, receiver, amountOver, viaMint);
        _attempt_deposit_over_balance(collToken1, msg.sender, receiver, amountOver, viaMint);
    }

    function _attempt_deposit_over_balance(
        CollateralTracker collToken,
        address depositor,
        address receiver,
        uint256 amountOver,
        bool viaMint
    ) internal {
        uint256 depositorBalance = IERC20(collToken.asset()).balanceOf(depositor);
        amountOver = bound(amountOver, 1, type(uint256).max - depositorBalance);
        uint256 tooLargeAmount = depositorBalance + amountOver;
        uint256 tooLargeShares = collToken.convertToShares(tooLargeAmount);

        hevm.prank(depositor);
        if (viaMint) {
            try collToken.mint(tooLargeShares, receiver) {
                assertWithMsg(
                    false,
                    "User minted an amount of shares greater than their balance of the asset"
                );
            } catch {}
        } else {
            try collToken.deposit(tooLargeAmount, receiver) {
                assertWithMsg(
                    false,
                    "User deposited an amount greater than their balance of the asset"
                );
            } catch {}
        }
    }

    function _withdraw_with_open_positions_and_check(
        CollateralTracker collToken,
        uint256 assetsToWithdraw,
        address withdrawer,
        bool isToken0
    ) internal {
        // check whether current positions are solvent; revert if not
        TokenId[] memory withdrawersOpenPositions = userPositions[withdrawer];

        panopticPool.validateCollateralWithdrawable(withdrawer, withdrawersOpenPositions);

        // attempt withdrawal, and assert assets & shares were deducted/incremented appropriately
        uint256 withdrawerAssetsBefore = IERC20(collToken.asset()).balanceOf(withdrawer);
        uint256 poolAssetsBefore = IERC20(collToken.asset()).balanceOf(address(panopticPool));
        uint256 withdrawerSharesBefore = collToken.balanceOf(withdrawer);

        // Bound the fuzzed assets-to-withdraw to max assets withdrawable:
        // the smaller of the s_poolAssets and the user's assets in the CT
        assetsToWithdraw = bound(
            assetsToWithdraw,
            1,
            _max_assets_withdrawable(collToken, withdrawerSharesBefore)
        );
        // Figure out how many shares we expect to see burnt:
        uint256 expectedSharesBurnt = collToken.previewWithdraw(assetsToWithdraw);

        hevm.prank(withdrawer);

        try collToken.withdraw(assetsToWithdraw, withdrawer, withdrawer, withdrawersOpenPositions) {
            // assert assets & shares were deducted/incremented appropriately:
            uint256 poolAssetsAfter = IERC20(collToken.asset()).balanceOf(address(panopticPool));
            uint256 withdrawerAssetsAfter = IERC20(collToken.asset()).balanceOf(withdrawer);
            uint256 withdrawerSharesAfter = collToken.balanceOf(withdrawer);
            assertWithMsg(
                poolAssetsBefore - poolAssetsAfter == assetsToWithdraw,
                "Pool asset balance incorrect after withdrawal"
            );
            assertWithMsg(
                withdrawerAssetsAfter - withdrawerAssetsBefore == assetsToWithdraw,
                "User balance incorrect after deposit"
            );
            assertWithMsg(
                withdrawerSharesBefore - withdrawerSharesAfter == expectedSharesBurnt,
                "User share balance incorrect after withdrawal"
            );

            // show we are still solvent:
            try
                panopticPool.validateCollateralWithdrawable(withdrawer, withdrawersOpenPositions)
            {} catch {
                assertWithMsg(
                    false,
                    "User not solvent after seemingly legal withdrawal-with-open-positions"
                );
            }
        } catch {
            // if .withdraw reverted for some unknown reason, we failed an invariant, but if we just
            // reverted because the withdrawal causes insolvency everything is fine:
            assertWithMsg(
                _does_withdrawal_cause_insolvency(
                    withdrawer,
                    withdrawersOpenPositions,
                    assetsToWithdraw,
                    isToken0
                ),
                "Withdrawal reverted for reason other than causing insolvency"
            );
        }
    }

    function _max_assets_withdrawable(
        CollateralTracker collToken,
        uint256 withdrawerSharesBefore
    ) internal view returns (uint256 maxAssetsWithdrawable) {
        (uint256 ct_s_poolAssets, , ) = collToken.getPoolData();
        uint256 withdrawersAssetsInCT = collToken.convertToAssets(withdrawerSharesBefore);
        maxAssetsWithdrawable = ct_s_poolAssets - 1 < withdrawersAssetsInCT
            ? ct_s_poolAssets - 1
            : withdrawersAssetsInCT;
    }

    function _does_withdrawal_cause_insolvency(
        address withdrawer,
        TokenId[] memory withdrawersOpenPositions,
        uint256 assetsToWithdraw,
        bool isToken0
    ) internal returns (bool withdrawalCausesInsolvency) {
        (
            ,
            int24 currentTick,
            uint16 observationIndex,
            uint16 observationCardinality,
            ,
            ,

        ) = initializedPool.slot0();

        (int24 fastOracleTick, ) = PanopticMath.computeMedianObservedPrice(
            initializedPool,
            observationIndex,
            observationCardinality,
            FAST_ORACLE_CARDINALITY,
            FAST_ORACLE_PERIOD
        );

        // s_miniMedian, an internal var in the PanopticPool, can be found in storage slot 1:
        uint256 miniMedian = uint256(hevm.load(address(panopticPool), bytes32(uint256(1))));
        (int24 slowOracleTick, ) = PanopticMath.computeInternalMedian(
            observationIndex,
            observationCardinality,
            MEDIAN_PERIOD,
            miniMedian,
            initializedPool
        );

        withdrawalCausesInsolvency = !_checkSolvencyAtTickForPossibleWithdrawal(
            withdrawer,
            withdrawersOpenPositions,
            currentTick,
            fastOracleTick,
            BP_DECREASE_BUFFER,
            assetsToWithdraw,
            isToken0
        );

        // If one of the ticks is too stale, we fall back to the more conservative tick, i.e, the user must be solvent at both the fast and slow oracle ticks.
        withdrawalCausesInsolvency =
            withdrawalCausesInsolvency ||
            ((Math.abs(int256(fastOracleTick) - slowOracleTick) > MAX_SLOW_FAST_DELTA) &&
                !_checkSolvencyAtTickForPossibleWithdrawal(
                    withdrawer,
                    withdrawersOpenPositions,
                    currentTick,
                    slowOracleTick,
                    BP_DECREASE_BUFFER,
                    assetsToWithdraw,
                    isToken0
                ));
    }

    function _checkSolvencyAtTickForPossibleWithdrawal(
        address account,
        TokenId[] memory positionIdList,
        int24 currentTick,
        int24 atTick,
        uint256 buffer,
        uint256 amountWithdrawn,
        bool isToken0
    ) internal returns (bool) {
        (int128 premium0, int128 premium1, uint256[2][] memory positionBalanceArray) = panopticPool
            .calculateAccumulatedFeesBatch(account, ONLY_AVAILABLE_PREMIUM, positionIdList);

        LeftRightUnsigned tokenData0 = collToken0.getAccountMarginDetails(
            account,
            atTick,
            positionBalanceArray,
            premium0
        );
        LeftRightUnsigned tokenData1 = collToken1.getAccountMarginDetails(
            account,
            atTick,
            positionBalanceArray,
            premium1
        );

        (uint256 balanceCross, uint256 thresholdCross) = _getSolvencyBalances(
            tokenData0,
            tokenData1,
            Math.getSqrtRatioAtTick(atTick),
            amountWithdrawn,
            isToken0
        );

        // compare balance and required tokens, can use unsafe div because denominator is always nonzero
        unchecked {
            return balanceCross >= Math.unsafeDivRoundingUp(thresholdCross * buffer, 10_000);
        }
    }
}
