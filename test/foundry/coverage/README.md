# Coverage of `contracts/`

This folder holds one test file per contract. Each file fills the gaps that the rest of the suite leaves in
that contract, so the figures below are for the whole suite, not for this folder alone.

## Summary

|                         | Lines                  | Branches             | Functions          |
| ----------------------- | ---------------------- | -------------------- | ------------------ |
| **All of `contracts/`** | **99.92% (3690/3693)** | **98.85% (943/954)** | **100% (516/516)** |

Measured on 2026-11-12 with forge 1.9.0, at 1,000 fuzz runs, against the pinned mainnet fork of the `ci_test`
profile. See [How to reproduce](#how-to-reproduce) for how the two runs behind these figures are combined.

## What is not covered

Three lines and eleven branches remain. None of them is a reachable behaviour that was simply left untested.

| Location                                                                         | Missing             | Reason                                                                                                                                                                                                                                        |
| -------------------------------------------------------------------------------- | ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `libraries/SafeTransferLib.sol:114,118`                                          | 2 lines, 2 branches | Failure arms of `balanceOfOrZero`. Left out on purpose: the function does not return zero there, and a test would have to pin that.                                                                                                           |
| `base/FactoryNFT.sol:293`                                                        | 1 line, 1 branch    | The `_scale <= 99` arm of `write`. Left out on purpose: the scale formatting is inconsistent in that range.                                                                                                                                   |
| `PanopticPool.sol:771,1010,1885,1954`                                            | 4 branches          | `PositionNotOwned` guards. A stored position never has size zero, and the three guards behind `dispatchFrom` sit after a solvency pass that rejects an unowned position first (line 590), even with a spoofed positions hash.                 |
| `SemiFungiblePositionManagerV3.sol:780`, `SemiFungiblePositionManagerV4.sol:740` | 2 branches          | `swapAmount == 0` in `swapInAMM`. The only caller requires a non-zero `itmAmounts`, and every arm then takes a non-zero slot.                                                                                                                 |
| `RiskEngine.sol:752,753`                                                         | 2 branches          | Per-token bonus clamps in `getLiquidationBonus`. The global cap and the cross-token conversion already keep each bonus within its backable collateral. Backed by a property fuzz and an exhaustive small-value search, not by a formal proof. |

The reasoning for each is also at the top of the matching test file.

## Per file

### Libraries

| File                                     | Lines          | Branches       | Functions    |
| ---------------------------------------- | -------------- | -------------- | ------------ |
| `libraries/CallbackLib.sol`              | 100% (3/3)     | 100% (1/1)     | 100% (1/1)   |
| `libraries/EfficientHash.sol`            | 100% (23/23)   | n/a            | 100% (4/4)   |
| `libraries/FeesCalc.sol`                 | 100% (16/16)   | 100% (4/4)     | 100% (2/2)   |
| `libraries/InteractionHelper.sol`        | 100% (39/39)   | 100% (10/10)   | 100% (5/5)   |
| `libraries/Math.sol`                     | 100% (372/372) | 100% (114/114) | 100% (47/47) |
| `libraries/PanopticMath.sol`             | 100% (191/191) | 100% (69/69)   | 100% (28/28) |
| `libraries/SafeTransferLib.sol`          | 94.29% (33/35) | 71.43% (5/7)   | 100% (4/4)   |
| `libraries/TransientReentrancyGuard.sol` | 100% (16/16)   | 100% (2/2)     | 100% (6/6)   |
| `libraries/V4StateReader.sol`            | 100% (25/25)   | 100% (4/4)     | 100% (4/4)   |

### Types

| File                        | Lines          | Branches     | Functions    |
| --------------------------- | -------------- | ------------ | ------------ |
| `types/LeftRight.sol`       | 100% (77/77)   | 100% (16/16) | 100% (16/16) |
| `types/LiquidityChunk.sol`  | 100% (23/23)   | n/a          | 100% (9/9)   |
| `types/MarketState.sol`     | 100% (25/25)   | n/a          | 100% (9/9)   |
| `types/OraclePack.sol`      | 100% (141/141) | 100% (14/14) | 100% (28/28) |
| `types/Pointer.sol`         | 100% (20/20)   | n/a          | 100% (7/7)   |
| `types/PoolData.sol`        | 100% (14/14)   | 100% (2/2)   | 100% (6/6)   |
| `types/PositionBalance.sol` | 100% (28/28)   | 100% (2/2)   | 100% (10/10) |
| `types/RiskParameters.sol`  | 100% (22/22)   | n/a          | 100% (11/11) |
| `types/TokenId.sol`         | 100% (103/103) | 100% (13/13) | 100% (27/27) |

### Tokens and base

| File                        | Lines            | Branches         | Functions    |
| --------------------------- | ---------------- | ---------------- | ------------ |
| `base/FactoryNFT.sol`       | 99.33% (149/150) | 99.12% (112/113) | 100% (11/11) |
| `base/MetadataStore.sol`    | 100% (4/4)       | n/a              | 100% (1/1)   |
| `base/Multicall.sol`        | 100% (8/8)       | 100% (1/1)       | 100% (1/1)   |
| `tokens/ERC1155Minimal.sol` | 100% (45/45)     | 100% (8/8)       | 100% (7/7)   |
| `tokens/ERC20Minimal.sol`   | 100% (28/28)     | 100% (1/1)       | 100% (6/6)   |

### Core and periphery

| File                                | Lines          | Branches         | Functions    |
| ----------------------------------- | -------------- | ---------------- | ------------ |
| `Builder.sol`                       | 100% (48/48)   | 100% (14/14)     | 100% (12/12) |
| `CollateralTracker.sol`             | 100% (432/432) | 100% (113/113)   | 100% (69/69) |
| `PanopticFactoryV3.sol`             | 100% (42/42)   | 100% (7/7)       | 100% (4/4)   |
| `PanopticFactoryV4.sol`             | 100% (51/51)   | 100% (5/5)       | 100% (5/5)   |
| `PanopticGuardian.sol`              | 100% (95/95)   | 100% (25/25)     | 100% (19/19) |
| `PanopticPool.sol`                  | 100% (495/495) | 95.60% (87/91)   | 100% (62/62) |
| `RiskEngine.sol`                    | 100% (594/594) | 98.91% (181/183) | 100% (46/46) |
| `RiskEngineProxy.sol`               | 100% (1/1)     | n/a              | 100% (1/1)   |
| `RiskEngineStub.sol`                | 100% (2/2)     | n/a              | 100% (1/1)   |
| `SemiFungiblePositionManagerV3.sol` | 100% (271/271) | 98.59% (70/71)   | 100% (26/26) |
| `SemiFungiblePositionManagerV4.sol` | 100% (254/254) | 98.44% (63/64)   | 100% (21/21) |

Interfaces, `Errors.sol`, `Constants.sol` and `RiskEngineParameters.sol` contain no executable lines and do not
appear in the report.

## How to reproduce

The full suite:

```sh
FOUNDRY_PROFILE=ci_test forge coverage \
    --fuzz-runs 1000 --no-match-path "{contracts,test/foundry/scenarios}/*" \
    --no-match-coverage "^(test|script|lib)/" \
    --report summary --report lcov -vv
```

This folder alone: the same command with `--match-path "test/foundry/coverage/*"` in place of
`--no-match-path`.

The figures above are the union of those two runs. Three things to know when reading the output:

- **The coverage filter must be anchored.** An unanchored `(test|script|lib)` also matches
  `contracts/libraries/` and silently drops every library from the report.
- **One test fails under coverage.** `test_implementationSize_withinReleaseHeadroom` checks deployed bytecode
  size, and coverage builds are unoptimized. The command exits non-zero but still writes the report.
- **The full run on its own reports three fewer lines**: 3687/3693 lines, 942/954 branches and 514/516
  functions. The difference comes from two things:
  - The `RiskEngineProxy` constructor and `BuilderWallet.receive` each register about 60 hits when this
    folder runs alone, and zero in the full run. Whether they register changes with which other suites run
    alongside, which points at how forge attributes hits rather than at the tests. The cause is not pinned
    down.
  - The `refund` tests in `CollateralTracker.coverage.t.sol` were added after the full run. They cover one
    line and one branch.

## Layout

One file per contract, named `<Contract>.coverage.t.sol`. The files for the core contracts build small local
fixtures instead of reusing the main suites: a mock pool for `CollateralTracker`, a local Uniswap V4 deployment
for `PanopticPool` and the V4 SFPM, and the pinned fork only for the V3 SFPM.

This folder is matched by the `coverage` rule in `.gitignore`, so new files here need `git add -f`.
