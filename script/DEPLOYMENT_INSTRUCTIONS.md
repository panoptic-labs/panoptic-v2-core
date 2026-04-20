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
- `build_release.py`
- `gen_safetx.py`
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
