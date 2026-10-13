# Robinhood mainnet deployment

Deployment source baseline: core commit `e3b9d125`, chain ID `4663`.
Post-deployment verification at Robinhood block `58991179` confirms all 21
core/metadata contracts have bytecode exactly matching the manifests' expected
runtime, including metadata, linked addresses, and constructor-set immutables.
See [deployment-verification-robinhood.json](../deployment-verification-robinhood.json)
for addresses, byte lengths, runtime Keccak-256 hashes, and input manifest/config
SHA-256 hashes.

Expected runtime was derived by executing each manifest's initcode locally from
its derived vanity proxy at the configured CREATE nonce. The full runtime was
compared with `eth_getCode` at the fixed block. This verifies deployed code;
it does not verify every storage value or operational behavior. Existing Query
and admin Safe bytecode presence was also reconfirmed, without an exact-code
comparison for those pre-existing contracts.

## Configuration

The Robinhood build configs preserve the addresses, salts, deployment nonces,
risk parameters, guardian admin, and treasurer from the corresponding Ethereum
configs. Only the Uniswap constructor dependency changes:

| Dependency             | Robinhood mainnet address                    |
| ---------------------- | -------------------------------------------- |
| Uniswap V3 factory     | `0x1f7d7550b1b028f7571e69a784071f0205fd2efa` |
| Uniswap V4 PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` |
| VanityMarket           | `0x000000000000b361194cfe6312EE3210d53C15AA` |
| Deployment Safe        | `0x82BF455e9ebd6a541EF10b683dE1edCaf05cE7A1` |
| Guardian admin         | `0xC3D385022d082Acd6b8744A85ad1766a01f522F7` |
| Treasurer              | `0xD8c5EbfeEA9B35695e54FFe0AaF9cFC521C9190d` |

Sources: [Robinhood network configuration](https://docs.robinhood.com/chain/connecting/),
[Uniswap V3 deployments](https://developers.uniswap.org/docs/protocols/v3/deployments/v3-robinhood-chain-deployments),
[Uniswap V4 deployments](https://developers.uniswap.org/docs/protocols/v4/deployments).

## Rebuild and verify

Run from the core repository root, sequentially: the build script clears Foundry
artifacts between contracts. The production profile excludes test and script
sources from release compilation.

```sh
FOUNDRY_PROFILE=prod python3 build_release.py build-config-robinhood-v4.json
FOUNDRY_PROFILE=prod python3 build_release.py build-config-robinhood-v3.json
FOUNDRY_PROFILE=prod python3 build_release.py build-config-RiskEngineXStocks.json
python3 script/verify_deployment.py deployment-info-robinhood-v4.json --config build-config-robinhood-v4.json
python3 script/verify_deployment.py deployment-info-robinhood-v3.json --config build-config-robinhood-v3.json
python3 script/verify_deployment.py deployment-info-RiskEngineXStocks.json --config build-config-RiskEngineXStocks.json
```

The regular RiskEngine is included in the V4 manifest; do not also deploy the
standalone regular-engine manifest. The XStocks manifest is chain-independent:
its guardian and builder-factory references retain the same vanity addresses.

## Safe batches

```sh
python3 gen_safetx.py deployment-info-robinhood-v4.json safe-txns-robinhood/v4 --chain-id 4663
python3 gen_safetx.py deployment-info-robinhood-v3.json safe-txns-robinhood/v3 --chain-id 4663 --exclude-addresses-from deployment-info-robinhood-v4.json
python3 gen_safetx.py deployment-info-RiskEngineXStocks.json safe-txns-robinhood/xstocks --chain-id 4663
```

The prepared execution order was V4 batches in numeric order, then V3 batches,
then XStocks batches. The output has 11 batches, 21 unique contract deployments,
and 42 mint/deploy calls.
Seven deployments store metadata; the other 14 are the requested core contracts.
Generated Safe batches are ignored by Git. The deployment is complete; these
commands reproduce the payloads for reference, not for execution again. The
generator assumes each salt needs minting and each destination is unused.
Its gas budget is an estimate, not a transaction simulation result.

## Validation completed

Both rebuilt core manifests passed address/config verification (32 checks each),
and the XStocks manifest passed four checks. All data-contract records are
identical to the Ethereum manifests. Only the V3/V4 SFPM and factory initcode
changes, reflecting the new Uniswap constructor addresses.

A local Foundry fork of Robinhood mainnet successfully executed all 21 mint/deploy
pairs while impersonating the deployment vault and verified code at every target.
That simulation did not broadcast transactions. It validated the underlying calls and slot
availability at the fork state; it does not validate Safe signatures, Safe batch
execution, per-transaction gas limits, or subsequent pool operation. The entire
sequence ran as one local test, not as one proposed mainnet transaction.

## Existing query proxy

`PanopticQuery` source and Safe tooling are in the pinned `lib/panoptic-helper`
submodule (`5750a9c0dd00dca54c3de6a14a352293c22ee195`).
The requested proxy was deployed separately by the Panoptic team. Preserve it
and exclude it from new deployment batches.
Implementation verification remains outstanding:

| Component               | Observed address                             |
| ----------------------- | -------------------------------------------- |
| Query proxy             | `0x0000000000000e1aE9c66C1c3B0A547D23389C93` |
| EIP-1967 implementation | `0x5f7199aaa7cac6574ebcfef4b394c28ce5174e96` |
| EIP-1967 admin          | `0xefc85e9521fddafd2e4154655b2abd1fc660a780` |
| Admin owner             | `0x2ad7353c2ed82845fdf5246bc7b10278a34bca1f` |

The admin owner matches the helper README's documented upgrade Safe. This alone
does not establish that the deployed implementation matches the intended release.

## Admin Safe checks

Preflight reads confirmed the deployment vault reports Safe version `1.4.1`,
five owners, and threshold three. A subsequent RPC batch reporting block
`58854002` on chain `4663` confirmed both guardian admin and treasurer have
171 bytes of code and report Safe `1.4.1`, threshold one, and two owners:
`0xcae438c8505be86b1a200d1c737a580170d5bf22` and
`0x1718e06694adb7806435b70fe0c94c39b952331d`.
Those configuration reads used `latest`, not an atomic historical snapshot.
Code presence for all three Safes was reconfirmed at block `58991179`.

## Pool deployments

Seven Panoptic pools were deployed on 2026-09-25 by calling each factory's
`deployNewPool` directly from `0xcae438c8505be86b1a200d1c737A580170d5bF22`
(Ledger, legacy HD path `m/44'/60'/0'/0`). Salts were mined with
`script/pool-address-miner` against that EOA as the deployer. Every call was
simulated with `cast call --from` before broadcasting and returned the mined
address. Receipts, pool keys and collateral trackers are recorded in
[deployment-pools-robinhood.json](../deployment-pools-robinhood.json).

| Market          | Kind | Risk engine              | PanopticPool                                 |
| --------------- | ---- | ------------------------ | -------------------------------------------- |
| ETH-USDG-1bps   | v3   | RiskEngine               | `0x000000000567861dfB86e396e30e5Ceca1883789` |
| SPY-USDG-5bps   | v4   | RiskEngineXStocks        | `0x000000000c21b38c54AcA7c7145Df01ff09d69Bb` |
| NVDA-USDG-5bps  | v3   | RiskEngineXStocksReverse | `0x000000000D77fF63E3a051F46028A5e972DB4E00` |
| SPCX-USDG-5bps  | v3   | RiskEngineXStocks        | `0x000000000e7356536bBc5753D892cd21c91B7b28` |
| GLD-USDG-5bps   | v3   | RiskEngineXStocksReverse | `0x0000000003977B00A4F6b6E12E760B0d77260F66` |
| QQQ-USDG-5bps   | v3   | RiskEngineXStocksReverse | `0x000000000287126A6CdbA8E713B4930bf806a527` |
| GOOGL-USDG-5bps | v3   | RiskEngineXStocks        | `0x0000000005Cc182d3c65B982eA2F65d5F27AA333` |

The reverse engine is used where USDG is token0. Each pool's
`collateralToken0/1()` and `riskEngine()` were read back and match the
factory's deployment event. The deployer EOA holds the seven factory NFTs.

## Source verification

All 14 logic contracts are source-verified on both Sourcify (exact match,
runtime including metadata hash) and robin.etherscan.io: PanopticMath,
InteractionHelper, CollateralTrackerV2, PanopticGuardian, BuilderFactory,
RiskEngine, RiskEngineXStocks, RiskEngineXStocksReverse, both SFPMs, both
PanopticPoolV2 references and both factories.

Before submission, each standard-JSON input was compiled locally with solc
`0.8.28` and matched against the chain: runtime (immutables masked) and
Etherscan's recorded creation bytecode plus the build config's constructor
arguments, exactly, for all 14.

Notes for reproducing:

- Compile with `--use 0.8.28`; the default toolchain picks a newer solc and
  `forge verify-contract` then finds no matching artifact.
- The installed `forge` has no Etherscan URL for chain `4663` and ignores
  `--verifier-url`, falling back to Sourcify with profile settings. Generate
  the input with `forge verify-contract ... --show-standard-json-input` and
  submit it to `https://api.etherscan.io/v2/api?chainid=4663` or Sourcify's
  `/v2/verify/4663/<address>` directly.
- Etherscan's queue for this chain took several days to process submissions.

Not source-verifiable: the seven metadata data contracts (raw data), and the
pool/collateral-tracker clones (ClonesWithImmutableArgs proxies of the verified
references).

## Remaining release records

The Query proxy implementation (`0x5f7199aaa7cac6574ebcfef4b394c28ce5174e96`)
is not yet source-verified; it builds from `lib/panoptic-helper`.
Safe batch execution transaction hashes are not yet attached to this record.
