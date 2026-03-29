# Panoptic v2 Deployment Instructions

This document describes the current release deployment flow in this repo.

It is written for an engineer who needs to:

- review the deterministic deployment setup
- regenerate release artifacts
- generate Safe transaction batches
- execute the deployment in a controlled order

## Scope

This runbook covers the deterministic contract deployment flow driven by:

- `build-config-v3.json`
- `build-config-v4.json`
- `build_release.py`
- `gen_safetx.py`
- `script/select_vanity_addresses.py`

This does not cover post-deployment operational tasks such as pool creation or trade simulation from:

- `script/CreatePool.s.sol`
- `script/SellOptions.s.sol`

## Current assumptions

- The Safe transaction generator is mainnet-specific today.
- `gen_safetx.py` hard-codes `chainId = 1`.
- `gen_safetx.py` hard-codes the deterministic deploy recipient as `0x82BF455e9ebd6a541EF10b683dE1edCaf05cE7A1`.
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

Examples:

```bash
python3 script/select_vanity_addresses.py --max-rarity 314649014
python3 script/select_vanity_addresses.py --mode disjoint --in-place
python3 script/select_vanity_addresses.py --exclude-config some-other-config.json
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
python3 gen_safetx.py deployment-info-v4.json safe-txns-v4
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

## Step 6: Review Safe batches

Before execution, confirm:

- every file has `chainId = 1`
- file names and `meta.name` match the intended contract
- the target address in each deployment matches the expected vanity address
- shared deployments are not going to be submitted twice

Recommended review commands:

```bash
ls safe-txns-v3
ls safe-txns-v4
python3 -m json.tool safe-txns-v3/deploy_0_PanopticMath.json
```

Adjust the example file name above to match the actual output.

## Step 7: Execute deployment

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
- hard-coded mainnet and recipient values in `gen_safetx.py` are correct
- optimizer runs in each build config are still valid for the current code
- constructor arguments resolve to the intended linked deployments
- no stale contract path, artifact, or library link remains in the config

## Full command sequence

Shared deployment flow:

```bash
python3 script/select_vanity_addresses.py --in-place
python3 build_release.py build-config-v3.json
python3 build_release.py build-config-v4.json
python3 gen_safetx.py deployment-info-v3.json safe-txns-v3
python3 gen_safetx.py deployment-info-v4.json safe-txns-v4
```

Fully disjoint deployment flow:

```bash
python3 script/select_vanity_addresses.py --mode disjoint --in-place
python3 build_release.py build-config-v3.json
python3 build_release.py build-config-v4.json
python3 gen_safetx.py deployment-info-v3.json safe-txns-v3
python3 gen_safetx.py deployment-info-v4.json safe-txns-v4
```

## Notes

- Do not use legacy `build-config.json` for the split v2 release flow unless you intentionally want the old single-config path.
- If any config changes after `deployment-info-*.json` or `safe-txns-*` are generated, regenerate those outputs. Do not mix artifacts from different config revisions.
