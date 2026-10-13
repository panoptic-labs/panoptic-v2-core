# Panoptic v2 Deployment Instructions

This document describes the current release deployment flow in this repo.

It is written for an engineer who needs to:

- review the deterministic deployment setup
- regenerate release artifacts
- generate Safe transaction batches
- verify deployment addresses
- execute the deployment in a controlled order

## Scope

This runbook covers the deterministic contract deployment flow driven by:

- `build-config-v3.json`
- `build-config-v4.json`
- `build-config-RiskEngine.json`
- `build-config-RiskEngineXStocks.json`
- `build-config-RiskEngine-upgrade.json`
- `build_release.py`
- `gen_safetx.py`
- `gen_upgrade_safetx.py`
- `script/select_vanity_addresses.py`
- `script/optimize_runs.py`
- `script/verify_deployment.py`
- `script/verify_etherscan.py`

This does not cover post-deployment operational tasks such as pool creation or trade simulation from:

- `script/CreatePool.s.sol`
- `script/SellOptions.s.sol`

If you need to mine `deployNewPool` salts for Panoptic pool vanity addresses, use the local multithreaded miner in `script/pool-address-miner/`.

If you need to mine `builderCode` values whose CREATE2 wallet addresses fit inside a `uint128` (for fee routing via `dispatch`), use the builder code miner in `script/builder-code-miner/`.

## Current assumptions

- `gen_safetx.py` defaults to mainnet (`chainId = 1`), overridable with `--chain-id`. The mint recipient is derived from the first 20 bytes of each salt (the Safe address embedded in the salt).
- `build_release.py` auto-generates metadata-derived `MD_*` values from `metadata/out/MetadataPackage.json`. Those values do not need to be entered manually in the build configs.
- The split configs currently share the same addresses for:
  - `dataContracts`
  - `PanopticMath`
  - `InteractionHelper`
  - `CollateralTrackerV2`
  - `PanopticGuardian`
  - `BuilderFactory`
  - `RiskEngine`
  - `RiskEngineProxy`
- Because of that sharing, if both v3 and v4 are deployed from the current configs, the shared contracts must only be deployed once.

## Required tooling

Run everything from the repo root.

Required tools:

- `python3`
- `bun`
- `forge`
- `cast`

The release build currently compiles with:

- Solidity `0.8.28`
- EVM version `cancun`

## Files and outputs

Inputs:

- `build-config-v3.json`
- `build-config-v4.json`
- `script/vanity-addresses.tsv`

Generated outputs:

- `deployment-info-v3.json`
- `deployment-info-v4.json`
- `safe-txns-v3/`
- `safe-txns-v4/`

## RiskEngine proxy

Every RiskEngine is deployed behind `contracts/RiskEngineProxy.sol`, an OpenZeppelin v5
`TransparentUpgradeableProxy`. Pools and collateral trackers embed the **proxy** address as an immutable clone
argument, so the proxy is the long-lived address and the one that gets a vanity slot. The implementation
(`RiskEngineV2` in `contracts/RiskEngine.sol`) is redeployed on every upgrade and does not need a vanity address.

There is a single engine source. Risk tiers (blue-chip, xStocks) are the same contract deployed
with different constructor arguments: guardian, builder factory and a `RiskEngineV2.Parameters` struct holding the
cross buffers and every tier knob. In the build configs the struct is the third constructor arg, typed as a tuple
whose member order must match the struct declaration; the canonical values live in
`test/foundry/testUtils/RiskEngineParams.sol` and `build-config-RiskEngineXStocks.json`. Each tier has its own
proxy and its own implementation, so a logic fix is one source change and one upgrade per tier.

The engine exposes no on-chain getters for the tier parameters (they cost ~50 bytes of bytecode each and nothing
on-chain reads them). To see what a live proxy is running, read its ERC-1967 implementation slot and decode that
implementation's verified constructor arguments on Etherscan, or consult the build config it was deployed from.
`CROSS_BUFFER_0()` / `CROSS_BUFFER_1()` remain because `PanopticQuery` (panoptic-helper) calls them.

Config layout:

- `RiskEngine` is the implementation. Its `deployment` triple only needs to be a valid, unused CREATE3 slot.
- `RiskEngineProxy` holds the vanity address that pools key on. Its constructor args are `["@RiskEngine", "$RISK_ENGINE_OWNER"]`.
- `env.RISK_ENGINE_OWNER` is the initial owner of the `ProxyAdmin` the proxy creates in its constructor (the upgrade
  authority). Set it to the multisig before building. Ownership is later moved with `ProxyAdmin.transferOwnership`
  to a `TimelockController`, and later again to governance; neither step touches the proxy or the pools.

Proxies (the addresses pools key on):

| Tier                                | Proxy                                        | Config                                             |
| ----------------------------------- | -------------------------------------------- | -------------------------------------------------- |
| Blue-chip (90% / 90% cross buffers) | `0x000000000000ffE5eFdB5AE76b9200263C58b4c0` | `build-config-RiskEngine.json` (shared with v3/v4) |
| xStocks (75% / 75%, symmetric)      | `0x000000000000FfADa7c641E2aD6B13b51b50Cc94` | `build-config-RiskEngineXStocks.json`              |
| Reserved A (TBD)                    | `0x000000000000ff1F72EB9b4a215DDac4d9dDa3dA` | `build-config-RiskEngine.json`                     |
| Reserved B (TBD)                    | `0x000000000000Ff944ed41CbFa03edc0b477cBbf4` | `build-config-RiskEngine.json`                     |

The reserved proxies point at `RiskEngineStub`, which reverts on every call, so the factory cannot create a pool
against them (`riskEngine.vegoid()` fails). Bring one into service with the normal upgrade flow once its
parameters are decided.

Deploy order inside a batch is implementation first, then proxy, since the proxy constructor reads the
implementation address.

Upgrading: see [Upgrading a RiskEngine](#upgrading-a-riskengine) below.

Finding the `ProxyAdmin` address: it is stored in the proxy's ERC-1967 admin slot.

```bash
cast storage <proxy> 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103
```

## Deploying the same engines on another chain

The deployment-info files are chain-independent: CREATE3 addresses depend only on the deployer and the salt, and
the engine constructor args reference the Guardian, BuilderFactory and init code hash. The same files can be
replayed on any chain where all of the following hold at the **same addresses** as mainnet:

- the CREATE3 deployer `0x000000000000b361194cfe6312EE3210d53C15AA`
- the deploying Safe `0x82BF455e9ebd6a541EF10b683dE1edCaf05cE7A1` (the mint recipient embedded in every salt)
- the owner Safe `RISK_ENGINE_OWNER` (otherwise the ProxyAdmins are owned by nobody and can never upgrade)
- the Guardian and the BuilderFactory, with the factory deriving the same wallet for our init code hash
  (`predictBuilderWallet(1)` must equal the CREATE2 address computed from `0x6a0d5c65…e7412`)
- Cancun opcode support (Arbitrum chains: ArbOS 30 or later)

Check all of that in one go by pointing the fork replay at the chain, then regenerate the batches with its id:

```bash
ETH_RPC_URL=<chain rpc> forge test --match-path test/foundry/core/DeploySimulation.t.sol -vv
python3 gen_safetx.py deployment-info-RiskEngine.json safe-txns-RiskEngine-<chain> --chain-id <id>
python3 gen_safetx.py deployment-info-RiskEngineXStocks.json safe-txns-RiskEngineXStocks-<chain> --chain-id <id> \
  --exclude-addresses-from deployment-info-RiskEngine.json
```

Robinhood chain (chain id 4663) was verified this way on 2026-10-11: every precondition holds and the replay passes.

## Upgrading a RiskEngine

An upgrade is one Safe transaction: deploy the new implementation through the CREATE3 deployer, then call
`ProxyAdmin.upgradeAndCall(proxy, newImplementation, "")`. Pools and trackers pick up the new code in the same
block. Nothing else is redeployed. Config and generator:

- `build-config-RiskEngine-upgrade.json`: the implementation to build (`logicContracts.RiskEngine`) and the
  `upgrades` list mapping each proxy to the implementation it should point at.
- `gen_upgrade_safetx.py`: turns the built initcode into Safe Transaction Builder JSON.

The `ProxyAdmin` address is derived offline as `CREATE(proxy, nonce 1)` because `RiskEngineProxy` creates it in
its constructor. `test_proxyAdminIsCreateNonce1` in `RiskEngineProxy.t.sol` pins that derivation.

### 1. Change the code and test it behind the proxy

```bash
forge test
RISK_ENGINE_PROXY=true forge test --match-path test/foundry/core/PanopticPool.t.sol
forge test --match-path test/foundry/core/RiskEngine/RiskEngineProxy.t.sol
```

Checklist for the diff: `IRiskEngine` selectors and return types unchanged; `RiskParameters`, `OraclePack`,
`MarketState` packing unchanged; `VEGOID` unchanged; deployed size under 24,576 bytes
(`test_implementationSize_fitsUnderLimit` fails otherwise). To upgrade the xStocks tiers too, add
`logicContracts` entries with their constructor args (copy them from `build-config-RiskEngineXStocks.json`) and an
`upgrades` entry per proxy. Pass the tier parameters a proxy was deployed with unless changing one is the point of
the upgrade; `emaPeriods` must never change for a live proxy, since every pool's stored oracle pack depends on it.

### 2. Give the implementation an unused CREATE3 slot

The implementation address is not user-facing, so any unused triple from `script/vanity-addresses.tsv` works.
Exclude every address that is already live:

```bash
python3 script/select_vanity_addresses.py build-config-RiskEngine-upgrade.json \
  --exclude-config build-config-v4.json --exclude-config build-config-v3.json \
  --exclude-config build-config-RiskEngine.json --in-place
```

Keep a freeze file of deployed addresses once mainnet is live and pass it with `--freeze`.

### 3. Build the initcode

```bash
python3 build_release.py --dry-run build-config-RiskEngine-upgrade.json
python3 build_release.py build-config-RiskEngine-upgrade.json
python3 script/verify_deployment.py deployment-info-RiskEngine-upgrade.json --config build-config-RiskEngine-upgrade.json
```

### 4. Generate the Safe batch

Multisig owns the `ProxyAdmin` (current setup):

```bash
python3 gen_upgrade_safetx.py generate build-config-RiskEngine-upgrade.json \
  deployment-info-RiskEngine-upgrade.json safe-txns-upgrade --rpc-url $RPC_URL
```

Writes `safe-txns-upgrade/upgrade.json` with mint, deploy and `upgradeAndCall` in one atomic transaction.
`--rpc-url` is optional but recommended: it reads the live ERC-1967 admin and implementation slots and refuses to
generate if the derived `ProxyAdmin` does not match.

A `TimelockController` owns the `ProxyAdmin` (later setup):

```bash
python3 gen_upgrade_safetx.py generate build-config-RiskEngine-upgrade.json \
  deployment-info-RiskEngine-upgrade.json safe-txns-upgrade \
  --timelock $TIMELOCK --delay 172800 --rpc-url $RPC_URL
```

Writes three files, each one Safe transaction:

- `deploy.json`: mint + deploy of the implementation
- `schedule.json`: `scheduleBatch` on the timelock with the `upgradeAndCall` payload
- `execute.json`: `executeBatch` with the identical payload, valid once the delay has passed

CREATE3 addresses depend only on the salt, so `schedule.json` can be executed before `deploy.json`. For a
security fix, schedule first and deploy the code only right before `execute.json`, so the bytecode is public only
when it activates. For ordinary changes, deploy and verify first so the code can be reviewed during the delay.
`--salt` lets you reschedule an identical operation; the timelock rejects a duplicate operation id otherwise.

### 5. Execute and verify

Import the JSON into the Safe Transaction Builder and execute in order. Then:

```bash
python3 gen_upgrade_safetx.py check build-config-RiskEngine-upgrade.json \
  --deployment-info deployment-info-RiskEngine-upgrade.json --rpc-url $RPC_URL
python3 script/verify_etherscan.py build-config-RiskEngine-upgrade.json --etherscan-api-key $ETHERSCAN_API_KEY
```

`check` prints the live `ProxyAdmin`, its owner, the current implementation and whether the new implementation has
code. Confirm `current impl` equals the new address, then spot-check a pool: `cast call <pool>
"getRiskParameters(uint256)" 0` should reflect the new parameters.

### Rolling back

A rollback is an upgrade whose target is the previous implementation, which is still deployed. Edit `upgrades[]`
to point at the old address, skip steps 2 and 3, and run `gen_upgrade_safetx.py generate` against a
deployment-info that lists the old implementation. The quickest path is to keep each release's
`deployment-info-RiskEngine-upgrade.json` under version control so it is available for this.

## Config structure

Each build config has:

- `env`: deployment-time constants such as Uniswap addresses, guardian admin, and treasurer
- `dataContracts`: deterministic metadata storage deployments with `address`, `salt`, and `nonce` (can be empty or omitted for configs that don't deploy data contracts)
- `sharedCreationCode` (optional): groups of contracts that must be compiled with the same optimizer runs because they embed the same inner contract's creation code. See [Shared creation code](#shared-creation-code) below.
- `logicContracts`: deterministic logic deployments with:
  - `path`
  - `deployment.address`
  - `deployment.salt`
  - `deployment.nonce`
  - `optimizeRuns`
  - optional `links`
  - optional `constructorArgs`

Constructor arguments support `@ContractName` references (resolved to that contract's deployment address from the same config) and `$ENV_VAR` references (resolved from the `env` block). For partial redeployments where a referenced contract is not being redeployed, inline its address as a literal string instead of using `@`.

`build_release.py` does not mine or discover vanity addresses. It only consumes the addresses already present in the config file.

### BuilderWallet init code hash

The RiskEngine takes `keccak256(BuilderWallet creation code ++ abi.encode(BuilderFactory))` as its third
constructor argument and checks it against `BuilderFactory.predictBuilderWallet(1)` at construction. It no longer
embeds `type(BuilderWallet).creationCode`, so it is **not** part of the `BuilderWallet` shared-creation-code group
and can be compiled with whatever optimizer runs fit. The mainnet value, for the factory compiled at 3,333 runs, is
`0x6a0d5c6577773db023c0a2ffa778aa7bd42daedbce4a5b9ad7ddd38b422e7412`; a wrong value makes the deployment revert.

### Shared creation code

When multiple contracts embed the same inner contract via `type(X).creationCode`, they must be compiled with identical optimizer runs. Otherwise the embedded bytecode differs, producing different `keccak256` init-code hashes and mismatched CREATE2 addresses.

The `sharedCreationCode` config key declares these groups:

```json
"sharedCreationCode": {
    "BuilderWallet": ["BuilderFactory", "RiskEngine"]
}
```

`script/optimize_runs.py` uses this to clamp all group members to the minimum optimal runs found across the group. `build_release.py` does not enforce this — it compiles each contract with whatever `optimizeRuns` is in the config. Make sure the values are already consistent before building.

## Step 1: Choose vanity addresses

The source pool of available vanity addresses is:

- `script/vanity-addresses.tsv`

Use the selector to assign address, salt, and nonce triples into the split configs.

Preview shared allocation:

```bash
python3 script/select_vanity_addresses.py
```

Preview fully disjoint allocation:

```bash
python3 script/select_vanity_addresses.py --mode disjoint
```

Write the selected assignments back into the configs:

```bash
python3 script/select_vanity_addresses.py --in-place
```

Important selector behavior:

- The default rarity cap is `314649014`.
- Entries above that cap are ignored unless `--max-rarity` is increased.
- The default mode is `shared`.
- Eligible entries are assigned in descending rarity order using the selector's built-in contract priority table.
- In `shared` mode, v3 and v4 share:
  - `dataContracts`
  - `PanopticMath`
  - `InteractionHelper`
  - `CollateralTrackerV2`
  - `PanopticGuardian`
  - `BuilderFactory`
  - `RiskEngine`
  - `RiskEngineProxy`
- In `disjoint` mode, every slot gets a separate vanity address.
- The selector automatically excludes addresses already used by legacy `build-config.json`, unless that file is one of the explicit selector targets.

Protecting deployed addresses:

If some addresses have already been deployed on-chain, create a freeze file listing those addresses (one per line) and pass it with `--freeze`:

```bash
python3 script/select_vanity_addresses.py --freeze deployed-addresses.txt --in-place
```

The selector will skip any slot whose current config address appears in the freeze file. Use `--force` to override the freeze check with a warning.

Examples:

```bash
python3 script/select_vanity_addresses.py --max-rarity 314649014
python3 script/select_vanity_addresses.py --mode disjoint --in-place
python3 script/select_vanity_addresses.py --exclude-config some-other-config.json
python3 script/select_vanity_addresses.py --freeze deployed-addresses.txt --force --in-place
```

## Step 2: Review the config changes

Before generating deployment artifacts, review the config diff carefully.

Minimum checks:

- each deployment address is unique where it is supposed to be unique
- shared contracts are intentionally shared
- salts and nonces were updated together with addresses
- constructor arguments still point at the intended contracts
- environment addresses are correct for the target deployment

Recommended review commands:

```bash
git diff -- build-config-v3.json build-config-v4.json
python3 script/select_vanity_addresses.py
```

## Step 3: Build deployment artifacts

Preview the build without running forge, bun, or writing any files:

```bash
python3 build_release.py --dry-run build-config-v3.json
python3 build_release.py --dry-run build-config-v4.json
```

This prints a summary table of each contract's name, address, optimizer runs, library links, and constructor arg types.

Generate initcode bundles from each config:

```bash
python3 build_release.py build-config-v3.json
python3 build_release.py build-config-v4.json
```

This produces:

- `deployment-info-v3.json`
- `deployment-info-v4.json`

What `build_release.py` does:

- compiles metadata via `bun run ./metadata/compiler.js`
- injects metadata-derived `MD_*` values into the config environment
- builds each contract with the configured optimizer runs
- links libraries using the configured deployment addresses
- ABI-encodes constructor arguments with `cast abi-encode`
- writes deterministic deployment records containing:
  - `address`
  - `salt`
  - `nonce`
  - `initcode`

If you need custom output paths:

```bash
python3 build_release.py build-config-v3.json custom-deployment-info-v3.json
python3 build_release.py build-config-v4.json custom-deployment-info-v4.json
```

## Step 4: Review deployment-info output

Before generating Safe batches, review the generated deployment info.

Minimum checks:

- every expected contract is present
- the contract names match the intended config
- addresses match the config
- shared addresses are identical between v3 and v4 only where intended
- initcode is present for every contract

Useful review commands:

```bash
python3 -m json.tool deployment-info-v3.json > /tmp/deployment-info-v3.pretty.json
python3 -m json.tool deployment-info-v4.json > /tmp/deployment-info-v4.pretty.json
```

## Step 5: Generate Safe transaction batches

`gen_safetx.py` groups contracts into gas-aware batches. Each contract produces two calls (`mint` + `deploy`) targeting the CREATE3 deployer at `0x000000000000b361194cfe6312EE3210d53C15AA`.

EIP-7825 limits individual transactions to 2^24 (16,777,216) gas. The script's gas estimates are conservative (~75% of actual), so the default `--gas-limit` is set to keep actual gas usage safely under 16.7M per batch.

### Generate batches

Generate v4 batches first (includes all shared contracts), then v3 with `--exclude-addresses-from` to skip contracts already covered by v4:

```bash
python3 gen_safetx.py deployment-info-v4.json safe-txns-v4
python3 gen_safetx.py deployment-info-v3.json safe-txns-v3 --exclude-addresses-from deployment-info-v4.json
```

This produces numbered batch files like `safe-txns-v4/batch_0.json`, `safe-txns-v4/batch_1.json`, etc. The v3 output only contains v3-specific contracts (PanopticPoolV2, SemiFungiblePositionManagerV3, PanopticFactoryV3).

### Merge batches

If two batches together fit within the EIP-7825 gas limit (16.7M), merge them to reduce the number of Safe signatures required:

```bash
python3 gen_safetx.py merge safe-txns-v4/batch_N.json safe-txns-v3/batch_0.json -o safe-txns/combined.json
```

Review the batch listing printed by `gen_safetx.py` to decide which batches can be merged. Execute all batch files in order — each requires one multisig signature round.

### Options

- `--gas-limit N`: override the per-batch estimated gas limit
- `--exclude-addresses-from PATH`: skip contracts whose addresses appear in another deployment-info file
- `--check-duplicates-against PATH`: warn about overlapping addresses without excluding them
- `--chain-id ID`: chain ID for Safe transactions (default: 1)

For non-mainnet deployments:

```bash
python3 gen_safetx.py deployment-info-v4.json safe-txns-v4 --chain-id 11155111
```

## Step 6: Review Safe batches

Before execution, confirm:

- every file has the expected `chainId`
- `meta.contracts` lists the expected contracts in each batch
- the total number of batches and their gas estimates are reasonable
- shared deployments appear only once across all batches
- merged batches contain the expected combination of contracts

Recommended review commands:

```bash
ls safe-txns-v4
ls safe-txns-v3
python3 -m json.tool safe-txns-v4/batch_0.json | head -20
```

## Step 7: Verify deployment addresses

Verify that each address in the deployment-info files matches the expected vanity address derivation:

```bash
python3 script/verify_deployment.py deployment-info-v3.json
python3 script/verify_deployment.py deployment-info-v4.json
```

Cross-check deployment-info against the build config to catch mismatches in addresses, salts, or nonces:

```bash
python3 script/verify_deployment.py deployment-info-v3.json --config build-config-v3.json
python3 script/verify_deployment.py deployment-info-v4.json --config build-config-v4.json
```

After deployment, verify that bytecode is present on-chain:

```bash
python3 script/verify_deployment.py deployment-info-v3.json --rpc-url https://eth-mainnet.alchemyapi.io/v2/YOUR_KEY
```

The script exits non-zero if any check fails.

## Step 8: Execute deployment

Execution order matters. Batches must be executed sequentially because later contracts reference earlier ones via constructor arguments.

Import each batch JSON into the Safe web interface and execute in order. Each batch is a single multisig transaction containing multiple internal calls. The number of batches depends on the `--gas-limit` setting — review the output of `gen_safetx.py` for the exact batch listing.

Due to EIP-7825, each transaction is limited to 2^24 (16,777,216) gas. If the Safe app shows "Cannot estimate" for gas, use Tenderly to simulate the transaction and manually set the gas limit in the Safe UI.

## Step 9: Verify source code on Etherscan

After all contracts are deployed on-chain, verify their source code on Etherscan using `script/verify_etherscan.py`. This script reads the build config and runs `forge verify-contract` for each logic contract with the correct compiler version, optimizer runs, library links, and constructor arguments.

Preview the verification commands without running them:

```bash
python3 script/verify_etherscan.py build-config-v4.json --dry-run
python3 script/verify_etherscan.py build-config-v3.json --dry-run
```

Run verification:

```bash
python3 script/verify_etherscan.py build-config-v4.json --etherscan-api-key $ETHERSCAN_API_KEY
python3 script/verify_etherscan.py build-config-v3.json --etherscan-api-key $ETHERSCAN_API_KEY
```

To verify only specific contracts:

```bash
python3 script/verify_etherscan.py build-config-v4.json --contracts PanopticGuardian RiskEngine --etherscan-api-key $ETHERSCAN_API_KEY
```

For non-mainnet deployments, pass `--chain-id`:

```bash
python3 script/verify_etherscan.py build-config-v4.json --chain-id 11155111 --etherscan-api-key $ETHERSCAN_API_KEY
```

For alternative block explorers (e.g. Blockscout), use `--verifier-url`:

```bash
python3 script/verify_etherscan.py build-config-v4.json --verifier-url https://explorer.example.com/api --etherscan-api-key $ETHERSCAN_API_KEY
```

The script exits non-zero if any verification fails. Shared contracts (PanopticMath, InteractionHelper, CollateralTrackerV2, PanopticGuardian, BuilderFactory, RiskEngine) only need to be verified once — running against either v3 or v4 config is sufficient since they share the same addresses.

## Verifying on chains Foundry does not know (e.g. Robinhood Chain)

`forge verify-contract` refuses chain ids outside its built-in list even when a verifier URL is configured, and
it takes optimizer runs from the cached artifact rather than from `--optimizer-runs`. For those chains, and as a
robust alternative on mainnet, use the Etherscan v2 API directly:

```bash
ETHERSCAN_API_KEY=$KEY python3 script/verify_etherscan_v2.py build-config-RiskEngine.json --chain-id 4663
ETHERSCAN_API_KEY=$KEY python3 script/verify_etherscan_v2.py build-config-RiskEngineXStocks.json --chain-id 4663
```

The script builds the standard-JSON input with forge, sets each contract's `optimizeRuns` from the config, submits
to `https://api.etherscan.io/v2/api?chainid=<id>`, polls the result, and skips contracts Etherscan already
verified (identical bytecode is auto-matched: once one RiskEngineProxy is verified the others are too). Any chain in
`https://api.etherscan.io/v2/chainlist` works with the same key. Robinhood Chain explorer: https://robin.etherscan.io

## Suggested review checklist

An engineer reviewing this deployment should explicitly verify:

- the selected vanity addresses are acceptable and intentionally assigned
- the rarity cap used for selection is acceptable
- shared vs disjoint deployment strategy is intentional
- `--chain-id` passed to `gen_safetx.py` is correct for the target network
- optimizer runs in each build config are still valid for the current code
- constructor arguments resolve to the intended linked deployments
- no stale contract path, artifact, or library link remains in the config
- `sourceHash` in each Safe JSON matches the deployment-info entry it was generated from
- `script/verify_deployment.py` passes for all deployment-info files

## Full command sequence

```bash
# 1. (Optional) Reassign vanity addresses for data contracts
python3 script/select_vanity_addresses.py --in-place

# 2. Preview builds
python3 build_release.py --dry-run build-config-v4.json
python3 build_release.py --dry-run build-config-v3.json

# 3. Build deployment artifacts
python3 build_release.py build-config-v4.json
python3 build_release.py build-config-v3.json

# 4. Generate Safe batches (v4 includes shared, v3 excludes shared)
python3 gen_safetx.py deployment-info-v4.json safe-txns-v4
python3 gen_safetx.py deployment-info-v3.json safe-txns-v3 --exclude-addresses-from deployment-info-v4.json

# 5. (Optional) Merge small batches to reduce signature rounds
python3 gen_safetx.py merge safe-txns-v4/batch_N.json safe-txns-v3/batch_0.json -o safe-txns/combined.json

# 6. Verify addresses
python3 script/verify_deployment.py deployment-info-v4.json --config build-config-v4.json
python3 script/verify_deployment.py deployment-info-v3.json --config build-config-v3.json

# 7. (After deployment) Verify bytecode on-chain
python3 script/verify_deployment.py deployment-info-v4.json --rpc-url $RPC_URL
python3 script/verify_deployment.py deployment-info-v3.json --rpc-url $RPC_URL

# 8. (After deployment) Verify source on Etherscan
python3 script/verify_etherscan.py build-config-v4.json --etherscan-api-key $ETHERSCAN_API_KEY
python3 script/verify_etherscan.py build-config-v3.json --etherscan-api-key $ETHERSCAN_API_KEY
```

The merge step batch file names depend on how many batches are generated. Review the `gen_safetx.py` output and adjust accordingly.

## Redeploying RiskEngine and BuilderFactory

When deploying a new RiskEngine (e.g. with different risk parameters) you must also deploy a new BuilderFactory so that both contracts agree on the `BuilderWallet` init-code hash. The existing PanopticGuardian, PanopticFactory, SFPM, CollateralTracker, and PanopticPool implementations do not need redeployment:

- **PanopticGuardian** takes `BuilderFactory` as a function parameter — not stored as an immutable.
- **PanopticFactory** takes `riskEngine` as a parameter to `deployNewPool` — not hardcoded.
- **PanopticPool** and **CollateralTracker** get the RiskEngine address baked in as clone immutable args at pool creation time. Existing pools keep using their original RiskEngine; new pools use whichever RiskEngine is passed to `deployNewPool`.

Use `build-config-RiskEngine.json` as the template. It contains only BuilderFactory and RiskEngine, with the PanopticGuardian address inlined as a literal constructor argument.

### Workflow

```bash
# 1. Assign vanity addresses for the new BuilderFactory and RiskEngine
#    (update build-config-RiskEngine.json with new address/salt/nonce)

# 2. Find optimal optimizer runs (respects sharedCreationCode clamping)
python3 script/optimize_runs.py build-config-RiskEngine.json

# 3. Update optimizeRuns in the config, then build
python3 build_release.py build-config-RiskEngine.json

# 4. Generate Safe batches
python3 gen_safetx.py deployment-info-RiskEngine.json safe-txns-RiskEngine

# 5. Verify addresses
python3 script/verify_deployment.py deployment-info-RiskEngine.json --config build-config-RiskEngine.json

# 6. Execute Safe batches

# 7. Verify on-chain
python3 script/verify_deployment.py deployment-info-RiskEngine.json --rpc-url $RPC_URL

# 8. Verify source on Etherscan
python3 script/verify_etherscan.py build-config-RiskEngine.json --etherscan-api-key $ETHERSCAN_API_KEY
```

After deployment, update `build-config-v3.json` and `build-config-v4.json` with the new BuilderFactory and RiskEngine addresses and optimizer runs so they stay in sync.

### Mining uint128-compatible builder codes

After deploying the new BuilderFactory, mine `builderCode` values whose CREATE2 wallet addresses fit in a `uint128` (4 leading zero bytes). These codes can be used with `dispatch` for fee routing.

```bash
# 1. Compute the init code hash for the new factory
INIT_CODE_HASH=$(cast keccak $(cast concat-hex \
    $(forge inspect --optimize --optimizer-runs <RUNS> BuilderWallet bytecode) \
    $(cast abi-encode "x(address)" <NEW_FACTORY_ADDRESS>)))

# 2. Mine builder codes (streams hits as found, appends to CSV)
cargo run --release --manifest-path script/builder-code-miner/Cargo.toml -- \
    --factory <NEW_FACTORY_ADDRESS> \
    --init-code-hash $INIT_CODE_HASH \
    -o builder-codes.csv
```

At ~11.6M hashes/sec, expect one uint128-compatible hit roughly every ~6 minutes (1/2^32 probability). Use `--first` to stop after the first hit, or let it run to collect multiple candidates.

## Notes

- Do not use legacy `build-config.json` for the split v2 release flow unless you intentionally want the old single-config path.
- If any config changes after `deployment-info-*.json` or `safe-txns-*` are generated, regenerate those outputs. Do not mix artifacts from different config revisions.
- EIP-7825 (live as of Pectra) limits transactions to 2^24 gas. Keep `--gas-limit` conservative since the script's estimates are ~75% of actual gas usage.
