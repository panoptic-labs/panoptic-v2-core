<p align="center">
  <img src="assets/Smart Contracts_1.png" width="1000" title="Panoptic Banner"></img>
</p>

[![Lint](https://github.com/panoptic-labs/panoptic-v2-core/actions/workflows/lint.yml/badge.svg)](https://github.com/panoptic-labs/panoptic-v2-core/actions/workflows/lint.yml)
[![Tests & Coverage](https://github.com/panoptic-labs/panoptic-v2-core/actions/workflows/main.yml/badge.svg)](https://github.com/panoptic-labs/panoptic-v2-core/actions/workflows/main.yml)

[![Twitter](https://img.shields.io/twitter/url/https/twitter.com/cloudposse.svg?style=social&label=Follow%20%40Panoptic_xyz)](https://twitter.com/panoptic_xyz)

Panoptic is a permissionless options trading protocol. It enables the trading of perpetual options on top of any [Uniswap V3](https://uniswap.org/) or [V4](https://docs.uniswap.org/contracts/v4/overview) pool.

The Panoptic protocol is noncustodial, has no counterparty risk, offers instantaneous settlement, and is designed to remain fully collateralized at all times.

- [Panoptic's Website](https://www.panoptic.xyz)
- [Whitepaper](https://paper.panoptic.xyz/)
- [Litepaper](https://intro.panoptic.xyz)
- [Documentation](https://docs.panoptic.xyz/)
- [Twitter](https://twitter.com/Panoptic_xyz)
- [Discord](https://discord.gg/7fE8SN9pRT)
- [Blog](https://www.panoptic.xyz/blog)
- [YouTube](https://www.youtube.com/@Panopticxyz)

## Further Reading

Panoptic has been presented at conferences and was conceived with the first Panoptic's Genesis blog post in mid-summer 2021:

- [Panoptic @ EthCC 2023](https://www.youtube.com/watch?v=9ubpnQRvxY8)
- [Panoptic @ ETH Denver 2023](https://www.youtube.com/watch?v=Dt5AdCNavjs)
- [Panoptic @ ETH Denver 2022](https://www.youtube.com/watch?v=mtd4JphPcuA)
- [Panoptic @ DeFi Guild](https://www.youtube.com/watch?v=vlPIFYfG0FU)
- [Panoptic's Genesis: Blog Series](https://lambert-guillaume.medium.com/)

## Core Contracts

### SemiFungiblePositionManager

A gas-efficient alternative to Uniswap's NonFungiblePositionManager that manages complex, multi-leg Uniswap positions encoded in ERC1155 tokenIds, performs swaps allowing users to mint positions with only one type of token, and, most crucially, supports the minting of both typical LP positions where liquidity is added to Uniswap and "long" positions where Uniswap liquidity is burnt. While the SFPM is enshrined as a core component of the protocol and we consider it to be the "engine" of Panoptic, it is also a public good that we hope savvy Uniswap LPs will grow to find an essential tool and upgrade for managing their liquidity. Separate implementations exist for Uniswap V3 (`SemiFungiblePositionManagerV3`) and V4 (`SemiFungiblePositionManagerV4`).

### RiskEngine

The central risk assessment and solvency calculator for the Panoptic Protocol. This contract serves as the mathematical framework for all risk-related calculations and does not hold funds or state regarding user balances. The RiskEngine is responsible for:

- **Collateral Requirements**: Calculating the required collateral for complex option strategies including spreads, strangles, iron condors, and synthetic positions based on position composition and pool utilization
- **Solvency Verification**: Determining whether an account meets the maintenance margin requirements through the `isAccountSolvent` function, accounting for cross-collateralization between token0 and token1
- **Liquidation Parameters**: Computing liquidation bonuses paid to liquidators and protocol loss via `getLiquidationBonus`, factoring in the account's token balances and position requirements
- **Force Exercise Costs**: Calculating the cost to forcefully exercise out-of-range long positions via `exerciseCost`, using an exponentially decaying function based on distance from strike
- **Adaptive Interest Rate Model**: Computing dynamic borrow rates based on pool utilization using a PID controller approach, with rates adjusting between minimum and maximum thresholds to target optimal utilization
- **Oracle Management**: Managing the internal pricing oracle with volatility safeguards, exponential moving averages (EMAs), and median filters to prevent price manipulation
- **Risk Parameters**: Storing and providing access to protocol-wide risk parameters including seller/buyer collateral ratios, commission fees, force exercise costs, and target pool utilization levels
- **Guardian Controls**: Enabling an authorized guardian address to override safe mode settings and lock/unlock pools in emergency situations

The RiskEngine uses sophisticated algorithms including utilization-based multipliers (modulated by the VEGOID parameter), cross-buffer ratios for cross-collateralization, and dynamic collateral requirements that scale with pool utilization to ensure protocol solvency at all times.

### CollateralTracker

An ERC4626 vault where token liquidity from passive Panoptic Liquidity Providers (PLPs) and collateral for option positions are deposited. The CollateralTracker is responsible for:

- **Asset Management**: Tracking deposited assets, assets deployed in the AMM, and credited shares from long positions that exceed the rehypothecation threshold
- **Interest Accrual**: Implementing a compound interest model where borrowers (option sellers) pay interest on borrowed liquidity, with rates determined by the RiskEngine based on pool utilization
- **Commission Handling**: Collecting and distributing commission fees on option minting and burning, splitting fees between the protocol, builders (if a builder code is present), and PLPs
- **Premium Settlement**: Facilitating the payment and receipt of options premia between buyers and sellers, including settled and unsettled premia calculations
- **Balance Operations**: Managing user share balances through deposits, withdrawals, mints, redeems, and the delegation/revocation of virtual shares for active positions
- **Liquidation Settlement**: Handling the settlement of liquidation bonuses by minting shares to liquidators and managing protocol loss when positions are liquidated
- **Collateral Refunds**: Processing refunds between users when positions are closed, force-exercised, or adjusted

Each CollateralTracker maintains its own market state including a global borrow index for compound interest calculations, tracks per-user interest states (net borrows and last interaction snapshots), and coordinates with the RiskEngine to determine appropriate interest rates based on real-time pool utilization.

### PanopticPool

The Panoptic Pool exposes the core functionality of the protocol. If the SFPM is the "engine" of Panoptic, the Panoptic Pool is the "conductor". All interactions with the protocol, be it minting or burning positions, liquidating or force exercising distressed accounts, or just checking position balances and accumulating premiums, originate in this contract. It is responsible for:

- **Position Orchestration**: Coordinating calls to the SFPM to create, modify, and close option positions in Uniswap
- **Premium Tracking**: Tracking user balances and accumulating premia on option positions over time
- **Solvency Checks**: Consulting the RiskEngine to verify account solvency before allowing position changes or withdrawals
- **Settlement Coordination**: Calling the CollateralTracker with the necessary data to settle position changes, including commission payments, interest accrual, and balance updates
- **Risk Validation**: Ensuring all operations comply with the risk parameters and collateral requirements calculated by the RiskEngine

## Architecture & Actors

Each instance of the Panoptic protocol on a Uniswap pool contains:

- One PanopticPool that orchestrates all interactions in the protocol
- One RiskEngine that calculates collateral requirements, verifies solvency, and manages risk parameters
- Two CollateralTrackers, one for each constituent token0/token1 in the Uniswap pool
- A canonical SFPM - the SFPM manages liquidity across every Panoptic Pool

There are five primary roles assumed by actors in this Panoptic Ecosystem:

### Panoptic Liquidity Providers (PLPs)

Users who deposit tokens into one or both CollateralTracker vaults. The liquidity deposited by these users is borrowed by option sellers to create their positions - their liquidity is what enables undercollateralized positions. In return, they receive commission fees on both the notional and intrinsic values of option positions when they are minted, as well as interest payments from borrowers. Note that options buyers and sellers are PLPs too - they must deposit collateral to open their positions. We consider users who deposit collateral but do not _trade_ on Panoptic to be "passive" PLPs.

### Option Sellers

These users deposit liquidity into the Uniswap pool through Panoptic, making it available for options buyers to remove. This role is similar to providing liquidity directly to Uniswap V3, but offers numerous benefits including advanced tools to manage risky, complex positions and a multiplier on the fees/premia generated by their liquidity when it is removed by option buyers. Option sellers pay interest to PLPs on borrowed liquidity, with rates dynamically adjusted by the RiskEngine based on pool utilization. Sold option positions on Panoptic have similar payoffs to traditional options.

### Option Buyers

These users remove liquidity added by option sellers from the Uniswap Pool and move the tokens back into Panoptic. The premia they pay to sellers for the privilege is equivalent to the fees that would have been generated by the removed liquidity, plus a spread multiplier based on the portion of available liquidity in their Uniswap liquidity chunk that has been removed or utilized.

### Liquidators

These users are responsible for liquidating distressed accounts that no longer meet the collateral requirements calculated by the RiskEngine. They provide the tokens necessary to close all positions in the distressed account and receive a bonus from the remaining collateral, calculated by the RiskEngine's liquidation bonus formula. Sometimes, they may also need to buy or sell options to allow lower liquidity positions to be exercised.

### Force Exercisors

These are usually options sellers. They provide the required tokens and forcefully exercise long positions (from option buyers) in out-of-range strikes that are no longer generating premia, so the liquidity from those positions is added back to Uniswap and the sellers can exercise their positions (which involves burning that liquidity). They pay a fee to the exercised user for the inconvenience, with the fee amount determined by the RiskEngine's `exerciseCost` function.

## Flow

All protocol users first onboard by depositing tokens into one or both CollateralTracker vaults and being issued shares (becoming PLPs in the process). Panoptic's CollateralTracker supports the full ERC4626 interface, making deposits and withdrawals a simple and standardized process. Passive PLPs stop here.

Once they have deposited, all interactions with the protocol are initiated through the PanopticPool's unified entry points:

- `dispatch()` - The primary entry point for users to execute actions on their own behalf
- `dispatchFrom()` - Allows approved operators to execute actions on behalf of another user

These entry points accept encoded action data that specifies the operation to perform, which can include:

- Minting option positions with up to four distinct legs, each encoded in a positionID/tokenID as either short (sold/added) or long (bought/removed) liquidity chunks. The RiskEngine verifies that the account will remain solvent after minting.
- Burning or exercising positions. The RiskEngine ensures collateral requirements are met during the burn process.
- Settling long premium to force solvent option buyers to pay any premium owed to sellers
- Poking the median oracle to insert a new observation into the RiskEngine's internal median ring buffer
- Force exercising out-of-range long positions held by other users, with costs calculated by the RiskEngine
- Liquidating distressed accounts that no longer meet collateral requirements, with bonuses determined by the RiskEngine

This unified dispatch architecture provides a consistent interface for all protocol interactions while allowing the PanopticPool to orchestrate the necessary calls to the SFPM, CollateralTracker, and RiskEngine based on the requested action.

## Repository Structure

```ml
contracts/
├── CollateralTracker - "ERC4626 vault where token liquidity from Panoptic Liquidity Providers (PLPs) and collateral for option positions are deposited"
├── PanopticFactoryV3 - "Handles deployment of new Panoptic instances on top of Uniswap V3 pools, initial liquidity deployments, and NFT rewards for deployers"
├── PanopticFactoryV4 - "Handles deployment of new Panoptic instances on top of Uniswap V4 pools, initial liquidity deployments, and NFT rewards for deployers"
├── PanopticPool - "Coordinates all options trading activity - minting, burning, force exercises, liquidations"
├── RiskEngine - "Central risk assessment and solvency calculator - collateral requirements, liquidation parameters, interest rates, oracle management"
├── SemiFungiblePositionManagerV3 - "The 'engine' of Panoptic for Uniswap V3 - manages all positions in the protocol as well as being a more advanced, gas-efficient alternative to NFPM"
├── SemiFungiblePositionManagerV4 - "The 'engine' of Panoptic for Uniswap V4 - manages all positions in the protocol using V4's singleton pool architecture"
├── base
│   ├── FactoryNFT - "Constructs dynamic SVG art and metadata for Panoptic Factory NFTs from a set of building blocks"
│   ├── MetadataStore - "Base contract that can store two-deep objects with large value sizes at deployment time"
│   └── Multicall - "Adds a function to inheriting contracts that allows for multiple calls to be executed in a single transaction"
├── interfaces
│   ├── IRiskEngine - "Interface for the RiskEngine contract"
│   └── ISemiFungiblePositionManager - "Interface for the SemiFungiblePositionManager contract"
├── tokens
│   ├── ERC1155Minimal - "A minimalist implementation of the ERC1155 token standard without metadata"
│   ├── ERC20Minimal - "A minimalist implementation of the ERC20 token standard without metadata"
│   └── interfaces
│       └── IERC20Partial - "An incomplete ERC20 interface containing functions used in Panoptic with some return values omitted to support noncompliant tokens such as USDT"
├── types
│   ├── LeftRight - "Implementation for a set of custom data types that can hold two 128-bit numbers"
│   ├── LiquidityChunk - "Implementation for a custom data type that can represent a liquidity chunk of a given size in Uniswap - containing a tickLower, tickUpper, and liquidity"
│   ├── MarketState - "Packed data type holding the global borrow index and interest accrual state for a CollateralTracker"
│   ├── OraclePack - "Packed data type holding oracle observations including tick, residual, and EMA data"
│   ├── Pointer - "Implementation for a custom data type that represents a pointer to a slice of contract code at an address"
│   ├── PoolData - "Packed data type holding pool-level configuration and state"
│   ├── PositionBalance - "Implementation for a custom data type that holds a position size, the pool utilizations at mint, and the current/fastOracle/slowOracle/latestObserved ticks at mint"
│   ├── RiskParameters - "Packed data type holding protocol-wide risk parameters including collateral ratios, commission fees, and utilization targets"
│   └── TokenId - "Implementation for the custom data type used in the SFPM and Panoptic to encode position data in 256-bit ERC1155 tokenIds - holds a pool identifier and up to four full position legs"
└── libraries
    ├── CallbackLib - "Library for verifying and decoding Uniswap callbacks"
    ├── Constants - "Library of Constants used in Panoptic"
    ├── EfficientHash - "Gas-efficient hashing utilities"
    ├── Errors - "Contains all custom errors used in Panoptic's core contracts"
    ├── FeesCalc - "Utility to calculate up-to-date swap fees for liquidity chunks"
    ├── InteractionHelper - "Helpers to perform bytecode-size-heavy interactions with external contracts like batch approvals and metadata queries"
    ├── Math - "Library of generic math functions like abs(), mulDiv, etc"
    ├── PanopticMath - "Library containing advanced Panoptic/Uniswap-specific functionality such as our TWAP, price conversions, and position sizing math"
    ├── SafeTransferLib - "Safe ERC20 transfer library that gracefully handles missing return values"
    ├── TransientReentrancyGuard - "Reentrancy protection using transient storage"
    └── V4StateReader - "Utilities for reading Uniswap V4 pool state from the singleton contract"
```

## Protocol Analysis

The `protocol-analysis/` directory contains detailed security analyses and audit reports for the protocol:

- **[Overview](protocol-analysis/overview.md)** - High-level protocol architecture and contract descriptions
- **[Invariants](protocol-analysis/invariants.md)** - Protocol invariants and their justifications
- **Audit Reports** (`protocol-analysis/audits/`):
  - Arithmetic safety and overflow analysis
  - Rounding direction audit across all math operations
  - Denominator sensitivity and division-by-zero analysis
  - Oracle manipulation and MEV resistance analysis
  - Premium economic attack vectors
  - Interest rate model stability analysis
  - Reentrancy and callback safety audit
  - Liquidation game theory analysis
  - Risk engine parameter review
  - Settlement correctness audit
  - State machine transition analysis

## Installation

Panoptic uses the [Foundry](https://book.getfoundry.sh/) framework for testing and deployment, and Prettier for linting.

Prerequisites: [Foundry](https://book.getfoundry.sh/getting-started/installation), [Node.js](https://nodejs.org/) or [bun](https://bun.sh).

To get started, clone the repo, install the pre-commit hooks, and compile the metadata:

```bash
git clone https://github.com/panoptic-labs/panoptic-v2-core.git --recurse-submodules
npm i
bun run ./metadata/compiler.js
```

## Testing

Run the Foundry test suite:

```bash
forge test
```

Get a coverage report (requires `genhtml` to be installed):

```bash
forge coverage --report lcov && genhtml lcov.info --branch-coverage --output-dir coverage
```

## Deployment (Release)

Panoptic can also be deployed at a preconfigured set of addresses on mainnet. The canonical initcodes are saved in `deployment-info.json` and can be updated by running the following commands:

```bash
curl -fsSL https://bun.sh/install | bash
pip install eth_abi
python3 build_release.py
```

The configuration file `build-config.json` can be modified with the desired set of addresses and constructor arguments for each contract. The `env`
section contains deployment variables expected to change, such as the `UNIV3_FACTORY` address.

Each `address` and `salt` pair specified by `build-config.json` can be deployed through the `CREATE3` factory at `0x000000000000b361194cfe6312EE3210d53C15AA`. All salts in the current configuration are owned by `vault.panoptic.eth`.

The following command can be run to generate the Safe transaction batches required to deploy Panoptic with the code in `deployment-info.json` from a Safe multisig that owns salts:

```bash
python3 gen_safetx.py
```

The generated batches for each contract will be saved in individual JSON files in the `safe-txns` directory. These can be uploaded to a Gnosis Safe for execution via the "Transaction Builder" app. To ensure an accurate deployment process, each transaction batch should be queued in alphabetical order and checked against `deployment-info.json` for correctness prior to execution.

## Deployment (Legacy)

Panoptic can be deployed on any chain with a Uniswap V3 instance. To go through with the deployment, several environment variables need to be set:

- `DEPLOYER_PRIVATE_KEY` The private key of the EOA deploying the contracts
- `UNISWAP_V3_FACTORY` The address of the Uniswap V3 Factory Panoptic is being deployed on
- `ETHERSCAN_API_KEY`
- `ALCHEMY_API_KEY`

To deploy Panoptic for testing purposes, run:

```bash
source .env && forge script script/DeployProtocol.s.sol --rpc-url https://eth-sepolia.g.alchemy.com/v2/${ALCHEMY_API_KEY} -vvvv --optimize true --optimizer-runs 200 --broadcast --slow --verify
```

The `--verify` flag is included to ensure deployed contracts are verified on Etherscan.

The preconfigured RPC URL aliases are: `sepolia`. To deploy on another chain a custom RPC URL can be passed.

## License

The primary license for Panoptic V2 is the Business Source License 1.1 (`BUSL-1.1`), see [LICENSE](https://github.com/panoptic-labs/panoptic-v2-core/blob/main/LICENSE). Minus the following exceptions:

- [Interfaces](./contracts/interfaces), [tokens](./contracts/tokens), and [Multicall.sol](./contracts/base/Multicall.sol) have a General Public License
- Some [libraries](./contracts/libraries) and [types](./contracts/types/) have a General Public License
- [Tests](./test/) and some [scripts](./scripts) are unlicensed

Each of these files states their license type.
