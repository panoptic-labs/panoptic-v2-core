// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CollateralTrackerV2} from "@contracts/CollateralTracker.sol";

/// @notice Minimal, in-memory mock to satisfy RiskEngine calls.
/// It simulates balances, interest accrual, convertToShares/Assets, totalAssets/Supply.
/// No ERC20 semantics; not intended for integration tests.
///
/// Functions used by RiskEngine:
/// - assetsAndInterest(address)
/// - balanceOf(address)
/// - convertToShares(uint128)
/// - convertToAssets(uint256)
/// - totalAssets()
/// - totalSupply()
/// - getPoolData() (RiskEngineV2)
/* is CollateralTracker */ contract MockCollateralTracker {
    // per user balances
    mapping(address => uint256) internal _assets;
    mapping(address => uint256) internal _interest;
    mapping(address => uint256) internal _shares;

    // global accounting
    uint256 internal _totalAssets;
    uint256 internal _totalSupply;

    // pool data (RiskEngineV2 rehypothecation-adjusted utilization)
    uint256 internal _depositedAssets;
    uint256 internal _insideAMM;
    uint256 internal _creditedShares;
    uint256 internal _currentPoolUtilization;

    // linear 1:1 conversions unless specified
    uint256 public sharePriceNum = 1;
    uint256 public sharePriceDen = 1;

    constructor() {}

    function setUser(
        address user,
        uint256 assets_,
        uint256 interest_, // interest to add into requirement via _getMargin path
        uint256 shares_
    ) external {
        _assets[user] = assets_;
        _interest[user] = interest_;
        _shares[user] = shares_;
    }

    function setGlobal(uint256 totalAssets_, uint256 totalSupply_) external {
        _totalAssets = totalAssets_;
        _totalSupply = totalSupply_;
    }

    function setSharePrice(uint256 num, uint256 den) external {
        require(den != 0, "den=0");
        sharePriceNum = num;
        sharePriceDen = den;
    }

    function setPoolData(
        uint256 depositedAssets_,
        uint256 insideAMM_,
        uint256 creditedShares_,
        uint256 currentPoolUtilization_
    ) external {
        _depositedAssets = depositedAssets_;
        _insideAMM = insideAMM_;
        _creditedShares = creditedShares_;
        _currentPoolUtilization = currentPoolUtilization_;
    }

    // ---------- methods RiskEngine invokes ----------

    function assetsAndInterest(address user) external view returns (uint256, uint256) {
        return (_assets[user], _interest[user]);
    }

    function balanceOf(address user) external view returns (uint256) {
        return _shares[user];
    }

    function convertToShares(uint128 assets_) external view returns (uint256) {
        // shares = assets * den / num (inverse if price>1)
        return (uint256(assets_) * sharePriceDen) / sharePriceNum;
    }

    function convertToAssets(uint256 shares_) external view returns (uint256) {
        // assets = shares * num / den
        return (shares_ * sharePriceNum) / sharePriceDen;
    }

    function totalAssets() external view returns (uint256) {
        return _totalAssets;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function getPoolData()
        external
        view
        returns (
            uint256 depositedAssets,
            uint256 insideAMM,
            uint256 creditedShares,
            uint256 currentPoolUtilization
        )
    {
        return (_depositedAssets, _insideAMM, _creditedShares, _currentPoolUtilization);
    }
}
