# Overview

Panoptic is a permissionless options trading protocol. It enables the trading of perpetual options on top of [Uniswap V3](https://uniswap.org/) and Uniswap V4 pools.

The Panoptic protocol is noncustodial, has no counterparty risk, offers instantaneous settlement, and is designed to remain fully collateralized at all times.

## Core Contracts

### SemiFungiblePositionManager (V3 / V4)

A gas-efficient alternative to Uniswap's NonFungiblePositionManager that manages complex, multi-leg Uniswap positions encoded in ERC1155 tokenIds, performs swaps allowing users to mint positions with only one type of token, and, most crucially, supports the minting of both typical LP positions where liquidity is added to Uniswap and "long" positions where Uniswap liquidity is burnt.

There are now two SFPM implementations, both conforming to `ISemiFungiblePositionManager` and exposing the unified `mintTokenizedPosition` / `burnTokenizedPosition` entry points:

- `SemiFungiblePositionManagerV3` — canonical SFPM for Uniswap V3 pools.
- `SemiFungiblePositionManagerV4` — canonical SFPM for Uniswap V4 pools.

Each Panoptic Pool is bound at construction to the SFPM matching its underlying AMM. While the SFPM is enshrined as a core component of the protocol and we consider it to be the "engine" of Panoptic, it is also a public good that we hope savvy Uniswap LPs will grow to find an essential tool and upgrade for managing their liquidity.

### PanopticFactory (V3 / V4)

`PanopticFactoryV3` and `PanopticFactoryV4` deploy a full Panoptic pool stack per Uniswap pool: one `PanopticPool`, one `RiskEngine`, two `CollateralTracker` vaults (one per constituent token), and a binding to the version-matched SFPM. The factory is also the authority for builder-code registration that downstream contracts (CollateralTracker, BuilderFactory) trust.

### RiskEngine

The central risk assessment and solvency calculator for the Panoptic Protocol. This contract serves as the mathematical framework for all risk-related calculations and does not hold funds or state regarding user balances. The RiskEngine is responsible for:

- **Collateral Requirements**: Calculating the required collateral for complex option strategies including spreads, strangles, iron condors, and synthetic positions based on position composition and pool utilization
- **Solvency Verification**: Determining whether an account meets the maintenance margin requirements through the `isAccountSolvent` function, accounting for cross-collateralization between token0 and token1
- **Liquidation Parameters**: Computing liquidation bonuses paid to liquidators and protocol loss via `getLiquidationBonus`, factoring in the account's token balances and position requirements
- **Force Exercise Costs**: Calculating the cost to forcefully exercise out-of-range long positions via `exerciseCost`, using an exponentially decaying function based on distance from strike
- **Adaptive Interest Rate Model**: Computing dynamic borrow rates based on pool utilization using a PID controller approach, with rates adjusting between minimum and maximum thresholds to target optimal utilization
- **Oracle Management**: Managing the internal pricing oracle with volatility safeguards, exponential moving averages (EMAs), and median filters to prevent price manipulation
- **Risk Parameters**: Storing and providing access to protocol-wide risk parameters including seller/buyer collateral ratios, commission fees, force exercise costs, and target pool utilization levels
- **Pool Lock State**: Tracking per-pool `lockPool` / `unlockPool` state driven by the `PanopticGuardian`; locked pools halt minting/burning and other state-changing dispatch actions
- **Protocol Fee Accounting**: Accumulating protocol-owned commission and accrued fees on a per-token basis for later withdrawal by the guardian's treasurer

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
- **Oracle Update Entry Point**: Exposing `pokeOracle()` as a standalone permissionless entry point that inserts a new observation into the RiskEngine's internal EMA/median ring buffer (rate-limited to once every 64s)
- **Composable Assertion Helpers**: Exposing a set of view assertions intended for use with `multicall` — `assertMinCollateralValues`, `assertBlockRange`, `assertTimestampRange`, and `assertTickRange` — so that off-chain RFQ flows, force-exercise/liquidation slippage guards, and quoted-price validity checks can be enforced atomically alongside a `dispatch` / `dispatchFrom` call

### PanopticGuardian

`PanopticGuardian` is the protocol's emergency-controls contract. It defines two privileged roles:

- **`GUARDIAN_ADMIN`**: Can instantly lock any Panoptic pool (`lockPool`), schedule a corresponding `unlockPool` subject to a 1-hour `UNLOCK_DELAY` timelock, revoke individual builder admins (`setBuilderAdminRevoked`), and deploy new `BuilderWallet` instances on behalf of registered builders.
- **`TREASURER`**: Withdraws protocol-owned commission and fee balances accumulated inside the RiskEngine / CollateralTracker.

Builder admins authorized via the `BuilderFactory` may also call `lockPoolAsBuilder` to halt their own pool, but cannot interfere with an unlock the guardian has already scheduled.

### Builder & BuilderWallet

The Builder system routes the builder portion of the commission split to a smart-contract escrow per builder code:

- `BuilderFactory` deploys one `BuilderWallet` per `builderCode` using CREATE2, with `salt = bytes32(uint256(builderCode))`, so each builder's wallet address is deterministic from its code.
- `BuilderWallet` is owner/admin-controlled and supports `sweep()` (withdraw accumulated commissions) and `execute()` (arbitrary call) for the registered builder admin.
- The `PanopticGuardian` may revoke a builder admin via `setBuilderAdminRevoked`, after which that admin can no longer act on their wallet or lock pools.

The protocol/builder/PLP commission split itself is configured in `RiskEngine` (e.g. `PROTOCOL_SPLIT`, `BUILDER_SPLIT`).

## Architecture & Actors

Each instance of the Panoptic protocol on a Uniswap pool contains:

- One `PanopticPool` that orchestrates all interactions in the protocol
- One `RiskEngine` that calculates collateral requirements, verifies solvency, manages risk parameters, and tracks the per-pool lock state and protocol-fee balances
- Two `CollateralTracker` vaults, one for each constituent token0/token1 in the Uniswap pool
- A version-matched canonical SFPM (V3 or V4), bound at deployment by the matching `PanopticFactory`

Protocol-wide, there is also:

- A `PanopticGuardian` providing the `GUARDIAN_ADMIN` and `TREASURER` roles
- A `BuilderFactory` and per-builder `BuilderWallet` contracts receiving the builder commission split

The Panoptic ecosystem has the following actors:

### Panoptic Liquidity Providers (PLPs)

Users who deposit tokens into one or both CollateralTracker vaults. The liquidity deposited by these users is borrowed by option sellers to create their positions — their liquidity is what enables undercollateralized positions. In return, they receive commission fees on both the notional and intrinsic values of option positions when they are minted, as well as interest payments from borrowers. Note that options buyers and sellers are PLPs too — they must deposit collateral to open their positions. We consider users who deposit collateral but do not _trade_ on Panoptic to be "passive" PLPs.

### Option Sellers

These users deposit liquidity into the Uniswap pool through Panoptic, making it available for options buyers to remove. This role is similar to providing liquidity directly to Uniswap, but offers numerous benefits including advanced tools to manage risky, complex positions and a multiplier on the fees/premia generated by their liquidity when it is removed by option buyers. Option sellers pay interest to PLPs on borrowed liquidity, with rates dynamically adjusted by the RiskEngine based on pool utilization. Sold option positions on Panoptic have similar payoffs to traditional options.

### Option Buyers

These users remove liquidity added by option sellers from the Uniswap Pool and move the tokens back into Panoptic. The premia they pay to sellers for the privilege is equivalent to the fees that would have been generated by the removed liquidity, plus a spread multiplier based on the portion of available liquidity in their Uniswap liquidity chunk that has been removed or utilized.

### Liquidators

These users are responsible for liquidating distressed accounts that no longer meet the collateral requirements calculated by the RiskEngine. They provide the tokens necessary to close all positions in the distressed account and receive a bonus from the remaining collateral, calculated by the RiskEngine's liquidation bonus formula. Sometimes, they may also need to buy or sell options to allow lower liquidity positions to be exercised. Liquidation through `dispatchFrom` is only allowed when the target is insolvent at every oracle tick the pool tracks (spot, TWAP, latest, and current).

### Force Exercisors

These are usually options sellers. They provide the required tokens and forcefully exercise long positions (from option buyers) in out-of-range strikes that are no longer generating premia, so the liquidity from those positions is added back to Uniswap and the sellers can exercise their positions (which involves burning that liquidity). They pay a fee to the exercised user for the inconvenience, with the fee amount determined by the RiskEngine's `exerciseCost` function.

### Builders

External integrators (front-ends, aggregators, RFQ venues) that route order flow into Panoptic by passing a registered `builderCode` to `dispatch`. They earn the builder portion of the commission split, paid directly into a CREATE2-deterministic `BuilderWallet`. Their admin authority over the wallet and their right to lock the pool can be revoked by the `PanopticGuardian`.

### Guardian Admin

A privileged role on `PanopticGuardian` responsible for the protocol's emergency controls: instantly locking pools, scheduling unlocks subject to a 1-hour timelock, revoking builder admins, and deploying new `BuilderWallet` instances.

### Treasurer

A privileged role on `PanopticGuardian` responsible for sweeping protocol-owned commission and fee balances accumulated in the RiskEngine / CollateralTracker to the protocol treasury.

## Flow

All protocol users first onboard by depositing tokens into one or both CollateralTracker vaults and being issued shares (becoming PLPs in the process). Panoptic's CollateralTracker supports the full ERC4626 interface, making deposits and withdrawals a simple and standardized process. Passive PLPs stop here.

Once they have deposited, active interactions with the protocol go through the PanopticPool's two unified dispatch entry points:

- `dispatch(TokenId[] positionIdList, TokenId[] finalPositionIdList, uint128[] positionSizes, int24[3][] tickAndSpreadLimits, bool usePremiaAsCollateral, uint256 builderCode)` — the primary entry point for a user to mint and/or burn their own positions. Each `tokenId` encodes up to four legs as either short (sold/added) or long (bought/removed) liquidity chunks; `tickAndSpreadLimits` provides per-position acceptable ending-price intervals and a maximum `removedLiquidity/netLiquidity` spread; `builderCode` selects the commission split. The RiskEngine verifies the account remains solvent.
- `dispatchFrom(TokenId[] positionIdListFrom, address account, TokenId[] positionIdListTo, TokenId[] positionIdListToFinal, LeftRightUnsigned usePremiaAsCollateral)` — the entry point for one user to act on another user's account. The action performed is determined by comparing the list arguments:
  - **Settle long premium** — `positionIdListTo` and `positionIdListToFinal` hash to the same value: settles long premium owed by `account`.
  - **Force exercise** — `positionIdListToFinal.length == positionIdListTo.length - 1`: force-exercises an out-of-range long leg held by `account`, paying the exercise cost computed by the RiskEngine.
  - **Liquidate** — `positionIdListToFinal.length == 0` and `account` is insolvent at every oracle tick (spot, TWAP, latest, and current): closes all positions of `account` and pays the liquidation bonus computed by the RiskEngine.

In addition to dispatch, two further entry points are exposed directly on the pool:

- `pokeOracle()` — permissionlessly updates the RiskEngine's internal EMA/median oracle (rate-limited to once every 64 seconds). Not a dispatch action.
- View-only `assertMinCollateralValues` / `assertBlockRange` / `assertTimestampRange` / `assertTickRange` — composable revert-guards intended for use with `multicall` so that RFQ deadlines, force-exercise/liquidation slippage, and quoted-price validity can be enforced atomically with a dispatch call.

### Safe Mode and Pool Lock

Two protocol-level switches can restrict or halt activity:

- **Safe Mode**: A graduated risk-parameter setting (levels 0–3) maintained in the RiskEngine. Higher levels progressively force minted positions to be covered, force exercise on burn, and ultimately disable new mints altogether. The current safe-mode level is consulted on each mint/burn path inside `dispatch`.
- **Pool Lock**: An on/off flag per pool maintained by the RiskEngine, toggled by `PanopticGuardian` (`lockPool` / scheduled `unlockPool` with a 1-hour `UNLOCK_DELAY`) or by a non-revoked builder admin via `lockPoolAsBuilder`. While a pool is locked, state-changing dispatch actions revert; users can still close out by routes that do not require an unlocked pool.

This unified dispatch architecture provides a consistent interface for all protocol interactions while allowing the PanopticPool to orchestrate the necessary calls to the SFPM, CollateralTracker, and RiskEngine based on the requested action.
