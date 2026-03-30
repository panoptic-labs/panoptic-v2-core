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
- `build_release.py`
- `gen_safetx.py`
- `script/select_vanity_addresses.py`
- `script/verify_deployment.py`

This does not cover post-deployment operational tasks such as pool creation or trade simulation from:

- `script/CreatePool.s.sol`
- `script/SellOptions.s.sol`

## Current assumptions

- `gen_safetx.py` defaults to mainnet (`chainId = 1`) and recipient `0x82BF455e9ebd6a541EF10b683dE1edCaf05cE7A1`. Both can be overridden with `--chain-id` and `--recipient`.
- `build_release.py` auto-generates metadata-derived `MD_*` values from `metadata/out/MetadataPackage.json`. Those values do not need to be entered manually in the build configs.
- The split configs currently share the same addresses for:
  - `dataContracts`
  - `PanopticMath`
  - `InteractionHelper`
  - `CollateralTrackerV2`
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

- `env`: deployment-time constants such as Uniswap addresses, guardian, and builder factory owner
- `dataContracts`: deterministic metadata storage deployments with `address`, `salt`, and `nonce`
- `logicContracts`: deterministic logic deployments with:
  - `path`
  - `deployment.address`
  - `deployment.salt`
  - `deployment.nonce`
  - `optimizeRuns`
  - optional `links`
  - optional `constructorArgs`

`build_release.py` does not mine or discover vanity addresses. It only consumes the addresses already present in the config file.

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

Generate Safe JSON bundles from the deployment info:

```bash
python3 gen_safetx.py deployment-info-v3.json safe-txns-v3
python3 gen_safetx.py deployment-info-v4.json safe-txns-v4 --check-duplicates-against deployment-info-v3.json
```

The `--check-duplicates-against` flag loads another deployment-info file and warns about any overlapping addresses. This helps identify shared contracts that should only be deployed once.

For non-mainnet deployments, override the chain ID and recipient:

```bash
python3 gen_safetx.py deployment-info-v3.json safe-txns-v3 --chain-id 11155111 --recipient 0xYourTestnetSafe
```

This produces one Safe JSON file per deployment.

For data contracts:

- `safe-txns-v3/dataDeploy_*.json`
- `safe-txns-v4/dataDeploy_*.json`

For logic contracts:

- `safe-txns-v3/deploy_*.json`
- `safe-txns-v4/deploy_*.json`

Each Safe JSON contains two calls:

- `mint`
- `deploy`

Both calls target the deployer contract at `0x000000000000b361194cfe6312EE3210d53C15AA`.

Each Safe JSON includes a `sourceHash` in its metadata, which is a SHA256 hash of the source deployment-info entry. This can be used to verify that a Safe JSON was generated from a specific deployment-info revision.

## Step 6: Review Safe batches

Before execution, confirm:

- every file has the expected `chainId`
- file names and `meta.name` match the intended contract
- `meta.sourceHash` matches a fresh hash of the corresponding deployment-info entry
- the target address in each deployment matches the expected vanity address
- shared deployments are not going to be submitted twice

Recommended review commands:

```bash
ls safe-txns-v3
ls safe-txns-v4
python3 -m json.tool safe-txns-v3/deploy_0_PanopticMath.json
```

Adjust the example file name above to match the actual output.

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

Execution order matters.

Recommended order:

1. Deploy all shared `dataContracts` once.
2. Deploy shared logic contracts once.
3. Deploy v3-specific contracts.
4. Deploy v4-specific contracts.

If using the current shared configs, the shared logic contracts are:

- `PanopticMath`
- `InteractionHelper`
- `CollateralTrackerV2`

Operational rule:

- Do not execute duplicate Safe files for shared contracts a second time from the other batch.

Practical approach:

1. Import and execute the shared/data portion from either v3 or v4.
2. Skip duplicate shared deployments in the second batch.
3. Execute only the version-specific deployments that remain.

If you want completely independent batches with no overlap, rerun vanity assignment in `disjoint` mode and then regenerate `deployment-info-*` and `safe-txns-*`.

## Suggested review checklist

An engineer reviewing this deployment should explicitly verify:

- the selected vanity addresses are acceptable and intentionally assigned
- the rarity cap used for selection is acceptable
- shared vs disjoint deployment strategy is intentional
- `--chain-id` and `--recipient` values passed to `gen_safetx.py` are correct for the target network
- optimizer runs in each build config are still valid for the current code
- constructor arguments resolve to the intended linked deployments
- no stale contract path, artifact, or library link remains in the config
- `sourceHash` in each Safe JSON matches the deployment-info entry it was generated from
- `script/verify_deployment.py` passes for all deployment-info files

## Full command sequence

Shared deployment flow:

```bash
python3 script/select_vanity_addresses.py --in-place
python3 build_release.py --dry-run build-config-v3.json
python3 build_release.py --dry-run build-config-v4.json
python3 build_release.py build-config-v3.json
python3 build_release.py build-config-v4.json
python3 gen_safetx.py deployment-info-v3.json safe-txns-v3
python3 gen_safetx.py deployment-info-v4.json safe-txns-v4 --check-duplicates-against deployment-info-v3.json
python3 script/verify_deployment.py deployment-info-v3.json --config build-config-v3.json
python3 script/verify_deployment.py deployment-info-v4.json --config build-config-v4.json
```

Fully disjoint deployment flow:

```bash
python3 script/select_vanity_addresses.py --mode disjoint --in-place
python3 build_release.py --dry-run build-config-v3.json
python3 build_release.py --dry-run build-config-v4.json
python3 build_release.py build-config-v3.json
python3 build_release.py build-config-v4.json
python3 gen_safetx.py deployment-info-v3.json safe-txns-v3
python3 gen_safetx.py deployment-info-v4.json safe-txns-v4 --check-duplicates-against deployment-info-v3.json
python3 script/verify_deployment.py deployment-info-v3.json --config build-config-v3.json
python3 script/verify_deployment.py deployment-info-v4.json --config build-config-v4.json
```

## Notes

- Do not use legacy `build-config.json` for the split v2 release flow unless you intentionally want the old single-config path.
- If any config changes after `deployment-info-*.json` or `safe-txns-*` are generated, regenerate those outputs. Do not mix artifacts from different config revisions.
