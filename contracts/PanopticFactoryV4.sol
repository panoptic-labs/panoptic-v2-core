// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Interfaces
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {IRiskEngine} from "@contracts/interfaces/IRiskEngine.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManagerV4.sol";
// Inherited implementations
import {Multicall} from "@base/Multicall.sol";
import {FactoryNFT} from "@base/FactoryNFT.sol";
// External libraries
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
// Libraries
import {Errors} from "@libraries/Errors.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {V4StateReader} from "@libraries/V4StateReader.sol";
// Custom types
import {Pointer} from "@types/Pointer.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @title Panoptic Factory which creates and registers Panoptic Pools.
/// @author Axicon Labs Limited
/// @notice Facilitates deployment of Panoptic pools.
contract PanopticFactory is FactoryNFT, Multicall {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a Panoptic Pool is created.
    /// @param poolAddress Address of the deployed Panoptic pool
    /// @param idV4 The Uniswap V4 pool identifier (hash of `poolKey`) associated with the Panoptic Pool
    /// @param collateralTracker0 Address of the collateral tracker contract for currency0
    /// @param collateralTracker1 Address of the collateral tracker contract for currency1
    /// @param riskEngine Address of the risk engine used
    event PoolDeployed(
        PanopticPool indexed poolAddress,
        PoolId indexed idV4,
        CollateralTracker collateralTracker0,
        CollateralTracker collateralTracker1,
        IRiskEngine riskEngine
    );

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    using ClonesWithImmutableArgs for address;

    /*//////////////////////////////////////////////////////////////
                         CONSTANTS & IMMUTABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice The canonical Uniswap V4 Pool Manager address.
    IPoolManager internal immutable POOL_MANAGER_V4;

    /// @notice The Semi Fungible Position Manager (SFPM) which tracks option positions across Panoptic Pools.
    SemiFungiblePositionManager internal immutable SFPM;

    /// @notice Reference implementation of the `PanopticPool` to clone.
    address internal immutable POOL_REFERENCE;

    /// @notice Reference implementation of the `CollateralTracker` to clone.
    address internal immutable COLLATERAL_REFERENCE;

    /// @notice The `observationCardinalityNext` to set on the Uniswap pool when a new PanopticPool is deployed.
    uint16 internal constant CARDINALITY_INCREASE = 51;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Mapping from hash(Uniswap V4 pool key, riskEngine contract address) to address(PanopticPool) that stores the address of all deployed Panoptic Pools.
    mapping(bytes32 panopticPoolKey => PanopticPool panopticPool) internal s_getPanopticPool;

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Set immutable variables and store metadata pointers.
    /// @param _SFPM The canonical `SemiFungiblePositionManager` deployment
    /// @param _manager The canonical Uniswap V4 pool manager
    /// @param _poolReference The reference implementation of the `PanopticPool` to clone
    /// @param _collateralReference The reference implementation of the `CollateralTracker` to clone
    /// @param properties An array of identifiers for different categories of metadata
    /// @param indices A nested array of keys for K-V metadata pairs for each property in `properties`
    /// @param pointers Contains pointers to the metadata values stored in contract data slices for each index in `indices`
    constructor(
        SemiFungiblePositionManager _SFPM,
        IPoolManager _manager,
        address _poolReference,
        address _collateralReference,
        bytes32[] memory properties,
        uint256[][] memory indices,
        Pointer[][] memory pointers
    ) FactoryNFT(properties, indices, pointers) {
        SFPM = _SFPM;
        POOL_MANAGER_V4 = _manager;
        POOL_REFERENCE = _poolReference;
        COLLATERAL_REFERENCE = _collateralReference;
    }

    /*//////////////////////////////////////////////////////////////
                            POOL DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new Panoptic Pool linked to the given Uniswap pool identified by the incoming parameters.
    /// @dev There is a 1:1 mapping between a Panoptic Pool and a Uniswap Pool.
    /// @dev A Uniswap pool is uniquely identified by its tokens and the fee.
    /// @dev Salt used in PanopticPool CREATE2 is `[leading 20 msg.sender chars][leading 20 pool address chars][salt]`.
    /// @param key The Uniswap V4 pool key
    /// @param riskEngine Risk Engine to be used for this Panoptic Pool
    /// @param salt User-defined component of salt used in CREATE2 for the PanopticPool (must be a uint96 number)
    /// @return newPoolContract The address of the newly deployed Panoptic pool
    function deployNewPool(
        PoolKey calldata key,
        IRiskEngine riskEngine,
        uint96 salt
    ) external returns (PanopticPool newPoolContract) {
        PoolId idV4 = key.toId();

        bytes32 panopticPoolKey = _getPoolKey(key, riskEngine);

        if (address(riskEngine) == address(0)) revert Errors.ZeroAddress();

        if (V4StateReader.getSqrtPriceX96(POOL_MANAGER_V4, idV4) == 0)
            revert Errors.PoolNotInitialized();

        if (address(s_getPanopticPool[panopticPoolKey]) != address(0))
            revert Errors.PoolAlreadyInitialized();

        // initialize pool in SFPM if it has not already been initialized
        uint64 poolId = SFPM.initializeAMMPool(key, riskEngine.vegoid());

        // Users can specify a salt, the aim is to incentivize the mining of addresses with leading zeros
        // salt format: (first 20 characters of deployer address) + (first 10 characters of UniswapV3Pool) + (first 10 characters of RiskEngine) + (uint96 user supplied salt)
        bytes32 salt32 = bytes32(
            abi.encodePacked(
                uint80(uint160(msg.sender) >> 80),
                uint40(uint256(PoolId.unwrap(idV4)) >> 120),
                uint40(uint160(address(riskEngine)) >> 120),
                salt
            )
        );

        // using CREATE3 for the PanopticPool given we don't know some of the immutable args (`CollateralTracker` addresses)
        // this allows us to link the PanopticPool into the CollateralTrackers as an immutable arg without advance knowledge of their addresses
        newPoolContract = PanopticPool(ClonesWithImmutableArgs.addressOfClone3(salt32));

        CollateralTracker collateralTracker0;
        CollateralTracker collateralTracker1;
        {
            uint24 fee = key.fee;
            // Deploy collateral token proxies
            collateralTracker0 = CollateralTracker(
                COLLATERAL_REFERENCE.clone2(
                    abi.encodePacked(
                        newPoolContract,
                        true,
                        key.currency0,
                        key.currency0,
                        key.currency1,
                        riskEngine,
                        POOL_MANAGER_V4,
                        fee
                    )
                )
            );
            collateralTracker1 = CollateralTracker(
                COLLATERAL_REFERENCE.clone2(
                    abi.encodePacked(
                        newPoolContract,
                        false,
                        key.currency1,
                        key.currency0,
                        key.currency1,
                        riskEngine,
                        POOL_MANAGER_V4,
                        fee
                    )
                )
            );
        }

        // This creates a new Panoptic Pool (proxy to the PanopticPool implementation)
        newPoolContract = PanopticPool(
            POOL_REFERENCE.clone3(
                abi.encodePacked(
                    collateralTracker0,
                    collateralTracker1,
                    riskEngine,
                    POOL_MANAGER_V4,
                    poolId,
                    abi.encode(key)
                ),
                salt32
            )
        );

        newPoolContract.initialize();
        collateralTracker0.initialize();
        collateralTracker1.initialize();

        s_getPanopticPool[panopticPoolKey] = newPoolContract;

        // The Panoptic pool won't be safe to use until the observation cardinality is at least CARDINALITY_INCREASE
        // If this is not the case, we increase the next cardinality during deployment so the cardinality can catch up over time
        // When that happens, there will be a period of time where the PanopticPool is deployed, but not (safely) usable
        //v3Pool.increaseObservationCardinalityNext(CARDINALITY_INCREASE);

        // Issue reward NFT to donor
        uint256 tokenId = uint256(uint160(address(newPoolContract)));
        _mint(msg.sender, tokenId);

        emit PoolDeployed(
            newPoolContract,
            idV4,
            collateralTracker0,
            collateralTracker1,
            riskEngine
        );
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Find the salt which would give a Panoptic Pool the highest rarity within the search parameters.
    /// @dev The rarity is defined in terms of how many leading zeros the Panoptic pool address has.
    /// @dev Note that the final salt may overflow if too many loops are given relative to the amount in `salt`.
    /// @param deployerAddress Address of the account that deploys the new PanopticPool
    /// @param key The Uniswap V4 pool key
    /// @param salt Salt value to start from, useful as a checkpoint across multiple calls
    /// @param loops The number of mining operations starting from `salt` in trying to find the highest rarity
    /// @param minTargetRarity The minimum target rarity to mine for. The internal loop stops when this is reached *or* when no more iterations
    /// @return bestSalt The salt of the rarest pool (potentially at the specified minimum target)
    /// @return highestRarity The rarity of `bestSalt`
    function minePoolAddress(
        address deployerAddress,
        PoolKey calldata key,
        address riskEngine,
        uint96 salt,
        uint256 loops,
        uint256 minTargetRarity
    ) external view returns (uint96 bestSalt, uint256 highestRarity) {
        // Start at the given `salt` value (a checkpoint used to continue mining across multiple calls)

        // Runs until `bestSalt` reaches `minTargetRarity` or for `loops`, whichever comes first
        uint256 maxSalt;
        unchecked {
            maxSalt = uint256(salt) + loops;
        }

        for (; uint256(salt) < maxSalt; ) {
            bytes32 newSalt = bytes32(
                abi.encodePacked(
                    uint80(uint160(deployerAddress) >> 80),
                    uint40(uint256(PoolId.unwrap(key.toId())) >> 120),
                    uint40(uint160(riskEngine) >> 120),
                    salt
                )
            );

            uint256 rarity = PanopticMath.numberOfLeadingHexZeros(
                ClonesWithImmutableArgs.addressOfClone3(newSalt)
            );

            if (rarity > highestRarity) {
                // found a more rare address at this nonce
                highestRarity = rarity;
                bestSalt = salt;
            }

            if (rarity >= minTargetRarity) {
                // desired target met
                highestRarity = rarity;
                bestSalt = salt;
                break;
            }

            unchecked {
                // increment the nonce of `currentSalt` (lower 96 bits)
                salt += 1;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                QUERIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Return the address of the Panoptic Pool associated with `univ3pool`.
    /// @param keyV4 The Uniswap V4 pool key
    /// @return Address of the Panoptic Pool associated with `univ3pool`
    function getPanopticPool(
        PoolKey calldata keyV4,
        IRiskEngine riskEngine
    ) external view returns (PanopticPool) {
        bytes32 panopticPoolKey = _getPoolKey(keyV4, riskEngine);
        return s_getPanopticPool[panopticPoolKey];
    }

    /// @notice Assembly implementation of keccak256(abi.encode(key, riskEngine))
    /// @dev Duplicates abi.encode behavior: 6 words (192 bytes)
    function _getPoolKey(
        PoolKey calldata keyV4,
        IRiskEngine riskEngine
    ) internal pure returns (bytes32 hash) {
        assembly {
            let freeMemPtr := mload(0x40)

            // Copy the PoolKey struct (5 words = 160 bytes) directly from calldata to memory
            // keyV4 in assembly points to the start of the struct in calldata
            calldatacopy(freeMemPtr, keyV4, 0xa0)

            // Store the riskEngine as the 6th word (offset 160 / 0xa0)
            mstore(add(freeMemPtr, 0xa0), riskEngine)

            // Hash 192 bytes (0xc0)
            hash := keccak256(freeMemPtr, 0xc0)
        }
    }
}
