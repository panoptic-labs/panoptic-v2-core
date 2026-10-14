# Panoptic v2 Deployment Script Report

This report covers the deployment-related changes in:

- `9948e8f36f00` (`fix: use v1 deployment parameters for SFPM`)
- `0d09a60e4c2` (`feat: improve deployment scripts with dry-run, verification, and configurability`)

## Executive Summary

- `9948e8f36f00` updates the legacy direct-deployment path by aligning `script/DeployProtocol.s.sol`, `script/CreatePool.s.sol`, and `build-config.json` with the current Panoptic v2 naming and SFPM constructor parameters.
- `0d09a60e4c2` adds the operator-facing release toolchain for deterministic multisig deployment:
  - `build_release.py`
  - `gen_safetx.py`
  - `script/select_vanity_addresses.py`
  - `script/verify_deployment.py`
  - `script/DEPLOYMENT_INSTRUCTIONS.md`
- The intended release path is the split-config deterministic flow (`build-config-v3.json` and `build-config-v4.json`), not the old Foundry `new`-based deployment path in `script/DeployProtocol.s.sol`.

## Review Findings

### 1. `script/verify_deployment.py` currently crashes before CREATE3 verification

Severity: high

Relevant code:

- `script/verify_deployment.py:15-20`
- `script/verify_deployment.py:33-34`

Issue:

- `compute_create3_address()` builds `create2_input` as `"0xff" + ...`.
- `_cast_keccak()` is then called with `"0x" + create2_input`.
- That produces an invalid hex string beginning with `0x0xff...`, and `cast keccak` exits non-zero.

Observed behavior:

- `python3 script/verify_deployment.py deployment-info-v3.json --config build-config-v3.json`
- `python3 script/verify_deployment.py deployment-info-v4.json --config build-config-v4.json`

Both commands passed the config cross-check and then failed immediately when CREATE3 verification started.

Impact:

- The runbook step that says to verify CREATE3 derivations is not executable as written today.
- The script only provides partial value right now: config/address/salt/nonce consistency can be checked, but address derivation cannot.

### 2. The existing `safe-txns-*` artifacts in this worktree are stale relative to the current generator

Severity: medium

Relevant code and example artifact:

- `gen_safetx.py:24-186`
- `safe-txns-v4/deploy_4_RiskEngine.json`

Issue:

- The current generator adds `meta.sourceHash`.
- The current generator no longer writes an extra `"to"` field into the second `deploy` call's `contractInputsValues`.
- The local Safe JSON currently present in this checkout still reflects the older structure.

Observed behavior:

- The existing `safe-txns-v4/deploy_4_RiskEngine.json` in this worktree has `meta = {"name": ...}` only.
- A freshly generated file has `meta = {"name": ..., "sourceHash": ...}`.
- The existing local file still has `transactions[1].contractInputsValues = {"to", "id", "initcode"}`.
- A fresh file has `transactions[1].contractInputsValues = {"id", "initcode"}`.

Impact:

- Reviewers should not assume the existing local `safe-txns-*` directories are the current release artifacts.
- Operators should regenerate Safe batches from the current `deployment-info-*` inputs before use.

### 3. Freeze handling in `script/select_vanity_addresses.py` can waste top vanity entries

Severity: low

Relevant code:

- `script/select_vanity_addresses.py:251-270`

Issue:

- Targets are zipped to entries before frozen targets are filtered.
- If a target is skipped because its current address is frozen, the candidate vanity entry paired with that target is discarded rather than reused for the next eligible target.

Impact:

- This does not break the selector, but it can reduce allocation quality.
- The problem is most visible when rarity scores are not tied.

## Script Inventory

### `build_release.py`

Relevant code:

- `build_release.py:8-25`
- `build_release.py:64-109`
- `build_release.py:140-205`

Purpose:

- Builds deterministic deployment artifacts from a build config.
- Produces `deployment-info*.json` containing `address`, `salt`, `nonce`, and `initcode` for each deployment.

What it does:

- Parses a build config and derives a default output path.
- Supports `--dry-run` for operator review without running `bun`, `forge`, or writing files.
- Compiles metadata with `bun run ./metadata/compiler.js`.
- Injects metadata-derived `MD_PROPERTIES`, `MD_INDICES`, and `MD_POINTERS` into the config environment.
- Builds each logic contract with the configured optimizer runs and library links.
- ABI-encodes constructor arguments with `cast abi-encode`.
- Emits deterministic deployment records for data contracts and logic contracts.

Role in the flow:

- This is the source of truth for the initcode that later goes into the Safe batches.

### `gen_safetx.py`

Relevant code:

- `gen_safetx.py:6-17`
- `gen_safetx.py:24-91`
- `gen_safetx.py:94-186`

Purpose:

- Converts a `deployment-info*.json` file into one Safe JSON file per deployment.

What it does:

- Accepts `deployment_info`, `output_dir`, `--chain-id`, `--recipient`, and `--check-duplicates-against`.
- Writes two-call Safe batches for each deployment:
  - `mint`
  - `deploy`
- Targets the CREATE3 deployer contract at `0x000000000000b361194cfe6312EE3210d53C15AA`.
- Adds a `sourceHash` derived from the deployment-info entry.
- Warns when two deployment-info files overlap on addresses.

Role in the flow:

- This is the bridge from deterministic build artifacts to multisig-executable payloads.

### `script/select_vanity_addresses.py`

Relevant code:

- `script/select_vanity_addresses.py:61-113`
- `script/select_vanity_addresses.py:153-198`
- `script/select_vanity_addresses.py:212-280`

Purpose:

- Assigns `(address, salt, nonce)` vanity triples from `script/vanity-addresses.tsv` into one or more build configs.

What it does:

- Supports shared or disjoint allocation across `build-config-v3.json` and `build-config-v4.json`.
- Applies a contract priority table so higher-value contracts receive better vanity entries first.
- Excludes addresses already used in legacy configs unless explicitly targeted.
- Supports `--freeze` and `--force` to protect already-deployed addresses.
- Can preview or write changes in place.

Role in the flow:

- This is the first step in release prep. It decides the deterministic deployment addresses that everything else uses downstream.

### `script/verify_deployment.py`

Relevant code:

- `script/verify_deployment.py:10-20`
- `script/verify_deployment.py:23-42`
- `script/verify_deployment.py:81-166`

Purpose:

- Verifies that `deployment-info*.json` matches the expected deterministic deployment plan.

What it intends to do:

- Cross-check `deployment-info` against the build config.
- Recompute expected CREATE3 addresses from deployer + salt.
- Optionally query an RPC endpoint and confirm bytecode exists at each address.

Current status:

- The config cross-check works.
- The CREATE3 verification path is currently broken by the `0x0xff...` bug described above.

Role in the flow:

- Intended as the final pre-execution sanity check and the post-execution presence check.

### `script/DeployProtocol.s.sol`

Relevant code:

- `script/DeployProtocol.s.sol:30-139`

Purpose:

- Direct Foundry broadcast script for deploying protocol contracts from an EOA.

What it does:

- Reads Uniswap v3/v4 addresses from env vars.
- Compiles metadata pointers from `metadata/out/MetadataPackage.json`.
- Deploys the v4 SFPM, builder factory, risk engine, collateral tracker, pool reference, and factory.
- Deploys the v3 SFPM, pool reference, and factory.
- Uses the updated v1-style SFPM constructor parameters introduced in `9948e8f36f00`.

Role in the flow:

- Useful as a legacy/manual deployment helper.
- Not part of the deterministic multisig release path described in `script/DEPLOYMENT_INSTRUCTIONS.md`.

### `script/CreatePool.s.sol`

Relevant code:

- `script/CreatePool.s.sol:16-48`

Purpose:

- Post-deployment helper to create a Panoptic v4 pool through an already deployed factory.

What it does:

- Reads the factory, risk engine, currencies, fee, and tick spacing from env vars.
- Constructs a v4 `PoolKey`.
- Calls `factory.deployNewPool(key, riskEngine, salt)` with `salt = 0`.

Role in the flow:

- This is an operational helper after the core release deployment.
- It is not part of the multisig release bundle generation path.

## Typical Full Deployment Flow Through A Multisig

This is the intended operator flow for the split-config release path.

1. Select vanity addresses.

   - Run `python3 script/select_vanity_addresses.py` to preview.
   - Run `python3 script/select_vanity_addresses.py --in-place` when the allocation is approved.
   - Use `--freeze` if some addresses are already deployed and must stay fixed.

2. Review the config diff.

   - Confirm addresses, salts, nonces, constructor references, and environment constants.
   - Decide whether the release is intentionally `shared` or `disjoint`.

3. Run dry builds.

   - `python3 build_release.py --dry-run build-config-v3.json`
   - `python3 build_release.py --dry-run build-config-v4.json`
   - Use this to review contract names, addresses, links, optimizer runs, and constructor arg shapes.

4. Generate deterministic deployment info.

   - `python3 build_release.py build-config-v3.json`
   - `python3 build_release.py build-config-v4.json`

5. Review `deployment-info-*`.

   - Confirm every expected deployment is present.
   - Confirm shared deployments are only shared where intended.
   - Treat these files as the canonical source for downstream Safe generation.

6. Generate Safe batches.

   - `python3 gen_safetx.py deployment-info-v3.json safe-txns-v3`
   - `python3 gen_safetx.py deployment-info-v4.json safe-txns-v4 --check-duplicates-against deployment-info-v3.json`

7. Review overlap and execution order.

   - In the current shared setup, there are 10 overlaps:
     - 7 `dataContracts`
     - `PanopticMath`
     - `InteractionHelper`
     - `CollateralTrackerV2`
   - Deploy those shared items once.
   - Then deploy v3-only contracts.
   - Then deploy v4-only contracts.

8. Verify before execution.

   - Intended:
     - config/address/salt/nonce cross-check
     - CREATE3 derivation check
     - optional on-chain code presence check
   - Current caveat:
     - the CREATE3 verification script needs the bug above fixed before this step fully works.

9. Import batches into the Safe and execute in order.
   - Start with the shared/data batch from one side.
   - Skip duplicate shared items in the second batch.
   - Execute only the remaining version-specific deployments.

## Potential Improvements By Script

### `build_release.py`

- Add explicit length checks between `config["dataContracts"]` and `metadata["bytecodes"]` instead of relying on `zip()`.
- Print per-contract initcode hashes to make artifact review easier.
- Resolve constructor placeholders into a local copy instead of mutating `options["constructorArgs"]` in place.
- Replace deprecated `forge build --deny-warnings` with `forge build --deny warnings`.

### `gen_safetx.py`

- Add `--fail-on-duplicates` for shared-mode safety, so overlap can be escalated from warning to hard failure.
- Emit a merged deduplicated batch or a machine-readable execution manifest for shared deployments.
- Include `chainId` and `recipient` in the provenance hash if `sourceHash` is meant to validate the full Safe payload, not just the source deployment-info entry.

### `script/select_vanity_addresses.py`

- Re-run assignment after frozen targets are removed so the best remaining vanity entries are not discarded.
- Validate freeze status across every location in a shared target, not just the first one.
- Emit a summary file showing `kept`, `reassigned`, and `skipped` targets for auditability.

### `script/verify_deployment.py`

- Fix the `0x0xff...` bug in CREATE3 hashing.
- Compare runtime bytecode hashes after deployment instead of only checking code presence.
- Consider checking initcode hash consistency between `deployment-info` and regenerated build output when a `--config` is provided.

### `script/DeployProtocol.s.sol`

- Mark it more explicitly as legacy/manual-only so operators do not confuse it with the multisig release flow.
- Parameterize guardian/owner values instead of relying on `msg.sender` for those roles.
- Remove or gate unused helper imports such as `PanopticHelper` if they are no longer needed.

### `script/CreatePool.s.sol`

- Accept pool deployment salt from an env var or CLI flag instead of hardcoding `salt = 0`.
- Add a stronger preflight summary around the derived pool key and expected v4 pool identity.
- Document more explicitly that this is a post-release operational step, not part of the deterministic release deployment.

## Validation Notes

Commands run against this checkout:

- `python3 build_release.py --dry-run build-config-v3.json`
- `python3 build_release.py --dry-run build-config-v4.json`
- `python3 build_release.py build-config-v3.json /tmp/deployment-info-v3.check.json`
- `python3 build_release.py build-config-v4.json /tmp/deployment-info-v4.check.json`
- `python3 gen_safetx.py /tmp/deployment-info-v4.check.json /tmp/safe-txns-v4.check --check-duplicates-against /tmp/deployment-info-v3.check.json`
- `python3 script/verify_deployment.py deployment-info-v3.json --config build-config-v3.json`
- `python3 script/verify_deployment.py deployment-info-v4.json --config build-config-v4.json`

Observed results:

- `build_release.py` succeeds for both split configs.
- `gen_safetx.py` correctly reports 10 overlaps between the current shared v3/v4 deployment plans.
- `script/verify_deployment.py` passes the config cross-check and then crashes on the CREATE3 step.

Important local caveat:

- This worktree has local changes in `metadata/FactoryNFT.json`.
- Because `build_release.py` recompiles metadata, regenerated `deployment-info-*` in this checkout should not be treated as evidence against the existing local artifacts without first reproducing from a clean tree.
