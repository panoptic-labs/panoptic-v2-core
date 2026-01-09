// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PanopticMath} from "@libraries/PanopticMath.sol";
import {TokenId} from "@types/TokenId.sol";
import "../core/SemiFungiblePositionManager.t.sol";

// Interface for CollateralTracker functions needed for reentrancy tests
interface ICollateralTrackerTest {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares);

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    function donate(uint256 shares) external;

    function delegate(address delegatee) external;

    function revoke(address delegatee) external;

    function settleLiquidation(address liquidator, address liquidatee, int256 bonus) external;

    function refund(address refunder, address refundee, int256 assets) external;

    function settleMint(
        address optionOwner,
        int128 longAmount,
        int128 shortAmount,
        int128 ammDeltaAmount
    ) external returns (uint256, int128);

    function settleBurn(
        address optionOwner,
        int128 longAmount,
        int128 shortAmount,
        int128 ammDeltaAmount,
        int128 realizedPremium
    ) external returns (int128);
}

contract ReenterBurn {
    // ensure storage conflicts don't occur with etched contract
    uint256[65535] private __gap;

    struct Slot0 {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        bool unlocked;
    }

    Slot0 public slot0;

    int24 public tickSpacing;

    address public token0;
    address public token1;
    uint24 public fee;

    bool activated;

    function construct(
        Slot0 memory _slot0,
        address _token0,
        address _token1,
        uint24 _fee,
        int24 _tickSpacing
    ) public {
        slot0 = _slot0;
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;
    }

    fallback() external {
        bool reenter = !activated;
        activated = true;
        if (reenter)
            SemiFungiblePositionManagerHarness(msg.sender).burnTokenizedPosition(
                new bytes(0),
                TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(this), tickSpacing)),
                0,
                0,
                0
            );
    }
}

contract ReenterMint {
    // ensure storage conflicts don't occur with etched contract
    uint256[65535] private __gap;

    struct Slot0 {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        bool unlocked;
    }

    Slot0 public slot0;

    int24 public tickSpacing;

    address public token0;
    address public token1;
    uint24 public fee;

    bool activated;

    function construct(
        Slot0 memory _slot0,
        address _token0,
        address _token1,
        uint24 _fee,
        int24 _tickSpacing
    ) public {
        slot0 = _slot0;
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;
    }

    fallback() external {
        bool reenter = !activated;
        activated = true;

        if (reenter)
            SemiFungiblePositionManagerHarness(msg.sender).mintTokenizedPosition(
                new bytes(0),
                TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(this), tickSpacing)),
                0,
                0,
                0
            );
    }
}

contract ReenterTransferSingle {
    // ensure storage conflicts don't occur with etched contract
    uint256[65535] private __gap;

    struct Slot0 {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        bool unlocked;
    }

    Slot0 public slot0;

    int24 public tickSpacing;

    address public token0;
    address public token1;
    uint24 public fee;

    bool activated;

    function construct(
        Slot0 memory _slot0,
        address _token0,
        address _token1,
        uint24 _fee,
        int24 _tickSpacing
    ) public {
        slot0 = _slot0;
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;
    }

    fallback() external {
        bool reenter = !activated;
        activated = true;

        if (reenter)
            SemiFungiblePositionManagerHarness(msg.sender).safeTransferFrom(
                address(0),
                address(0),
                TokenId.unwrap(
                    TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(this), tickSpacing))
                ),
                0,
                ""
            );
    }
}

contract ReenterTransferBatch {
    // ensure storage conflicts don't occur with etched contract
    uint256[65535] private __gap;

    struct Slot0 {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        bool unlocked;
    }

    Slot0 public slot0;

    int24 public tickSpacing;

    address public token0;
    address public token1;
    uint24 public fee;

    bool activated;

    function construct(
        Slot0 memory _slot0,
        address _token0,
        address _token1,
        uint24 _fee,
        int24 _tickSpacing
    ) public {
        slot0 = _slot0;
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;
    }

    fallback() external {
        bool reenter = !activated;
        activated = true;

        uint256[] memory ids = new uint256[](1);
        ids[0] = TokenId.unwrap(
            TokenId.wrap(0).addPoolId(PanopticMath.getPoolId(address(this), tickSpacing))
        );
        if (reenter)
            SemiFungiblePositionManagerHarness(msg.sender).safeBatchTransferFrom(
                address(0),
                address(0),
                ids,
                new uint256[](1),
                ""
            );
    }
}

// through ERC1155 transfer
contract Reenter1155Initialize {
    address public token0;
    address public token1;
    uint24 public fee;
    uint64 poolId;

    bool activated;

    function construct(address _token0, address _token1, uint24 _fee, uint64 _poolId) public {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        poolId = _poolId;
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public returns (bytes4) {
        bool reenter = !activated;
        activated = true;

        if (reenter)
            SemiFungiblePositionManagerHarness(msg.sender).initializeAMMPool(token0, token1, fee);
        if (reenter)
            SemiFungiblePositionManagerHarness(msg.sender).mintTokenizedPosition(
                new bytes(0),
                TokenId.wrap(poolId),
                0,
                0,
                0
            );
        return this.onERC1155Received.selector;
    }
}

/*//////////////////////////////////////////////////////////////
                    COLLATERAL TRACKER MOCKS
//////////////////////////////////////////////////////////////*/

// Malicious ERC20 token that attempts to reenter CollateralTracker.deposit()
contract ReenterCTDeposit {
    uint256[65535] private __gap;

    bool activated;
    address public collateralTracker;

    function construct(address _collateralTracker) public {
        collateralTracker = _collateralTracker;
    }

    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function transferFrom(address, address, uint256 amount) external returns (bool) {
        bool reenter = !activated;
        activated = true;

        if (reenter) {
            ICollateralTrackerTest(collateralTracker).deposit(amount, address(this));
        }
        return true;
    }
}

// Malicious ERC20 token that attempts to reenter CollateralTracker.mint()
contract ReenterCTMint {
    uint256[65535] private __gap;

    bool activated;
    address public collateralTracker;

    function construct(address _collateralTracker) public {
        collateralTracker = _collateralTracker;
    }

    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        bool reenter = !activated;
        activated = true;

        if (reenter) {
            ICollateralTrackerTest(collateralTracker).mint(1000, address(this));
        }
        return true;
    }
}

// Malicious ERC20 token that attempts to reenter CollateralTracker.withdraw()
contract ReenterCTWithdraw {
    uint256[65535] private __gap;

    bool activated;
    address public collateralTracker;

    function construct(address _collateralTracker) public {
        collateralTracker = _collateralTracker;
    }

    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function transferFrom(address, address, uint256 amount) external returns (bool) {
        bool reenter = !activated;
        activated = true;

        if (reenter) {
            ICollateralTrackerTest(collateralTracker).withdraw(
                amount,
                address(this),
                address(this)
            );
        }
        return true;
    }
}

// Malicious ERC20 token that attempts to reenter CollateralTracker.redeem()
contract ReenterCTRedeem {
    uint256[65535] private __gap;

    bool activated;
    address public collateralTracker;

    function construct(address _collateralTracker) public {
        collateralTracker = _collateralTracker;
    }

    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        bool reenter = !activated;
        activated = true;

        if (reenter) {
            ICollateralTrackerTest(collateralTracker).redeem(1000, address(this), address(this));
        }
        return true;
    }
}

// Malicious ERC20 token that attempts to reenter CollateralTracker.donate()
contract ReenterCTDonate {
    uint256[65535] private __gap;

    bool activated;
    address public collateralTracker;

    function construct(address _collateralTracker) public {
        collateralTracker = _collateralTracker;
    }

    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        bool reenter = !activated;
        activated = true;

        if (reenter) {
            ICollateralTrackerTest(collateralTracker).donate(1000);
        }
        return true;
    }
}

// Malicious PanopticPool that attempts to reenter delegate() during deposit
contract ReenterCTDelegate {
    uint256[65535] private __gap;

    bool activated;
    address public collateralTracker;
    address public targetDelegatee;

    function construct(address _collateralTracker, address _delegatee) public {
        collateralTracker = _collateralTracker;
        targetDelegatee = _delegatee;
    }

    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        bool reenter = !activated;
        activated = true;

        if (reenter) {
            ICollateralTrackerTest(collateralTracker).delegate(targetDelegatee);
        }
        return true;
    }
}

// Malicious PanopticPool that attempts to reenter revoke() during withdraw
contract ReenterCTRevoke {
    uint256[65535] private __gap;

    bool activated;
    address public collateralTracker;
    address public targetDelegatee;

    function construct(address _collateralTracker, address _delegatee) public {
        collateralTracker = _collateralTracker;
        targetDelegatee = _delegatee;
    }

    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        bool reenter = !activated;
        activated = true;

        if (reenter) {
            ICollateralTrackerTest(collateralTracker).revoke(targetDelegatee);
        }
        return true;
    }
}

// Malicious token that attempts to reenter settleLiquidation() during deposit
contract ReenterCTSettleLiquidation {
    uint256[65535] private __gap;

    bool activated;
    address public collateralTracker;

    function construct(address _collateralTracker) public {
        collateralTracker = _collateralTracker;
    }

    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        bool reenter = !activated;
        activated = true;

        if (reenter) {
            ICollateralTrackerTest(collateralTracker).settleLiquidation(
                address(this),
                address(this),
                100
            );
        }
        return true;
    }
}

// Malicious token that attempts to reenter refund() during deposit
contract ReenterCTRefund {
    uint256[65535] private __gap;

    bool activated;
    address public collateralTracker;

    function construct(address _collateralTracker) public {
        collateralTracker = _collateralTracker;
    }

    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        bool reenter = !activated;
        activated = true;

        if (reenter) {
            ICollateralTrackerTest(collateralTracker).refund(address(this), address(this), 100);
        }
        return true;
    }
}

// Malicious token that attempts to reenter settleMint() during deposit
contract ReenterCTSettleMint {
    uint256[65535] private __gap;

    bool activated;
    address public collateralTracker;

    function construct(address _collateralTracker) public {
        collateralTracker = _collateralTracker;
    }

    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        bool reenter = !activated;
        activated = true;

        if (reenter) {
            ICollateralTrackerTest(collateralTracker).settleMint(address(this), 0, 0, 0);
        }
        return true;
    }
}

// Malicious token that attempts to reenter settleBurn() during deposit
contract ReenterCTSettleBurn {
    uint256[65535] private __gap;

    bool activated;
    address public collateralTracker;

    function construct(address _collateralTracker) public {
        collateralTracker = _collateralTracker;
    }

    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        bool reenter = !activated;
        activated = true;

        if (reenter) {
            ICollateralTrackerTest(collateralTracker).settleBurn(address(this), 0, 0, 0, 0);
        }
        return true;
    }
}
