# Keel

A Flap custom vault that levers a token's trading tax into a 3x BNB long the contract holds
itself on Venus, settles on a five-minute cadence while there is work to do, and pays the gain
out to holders.

## Why

A tax token's treasury normally sits still. Keel's does not: every unit of tax that arrives is
built into a leveraged BNB position the vault owns outright, and every settlement pays 70% of
the realised gain to holders as WBNB dividends and 30% to the project.

There is no keeper and no custodian. The three working functions — `deployPending`, `harvest`,
`rebalance` — are permissionless. `deployPending` and `harvest` always pay a fixed bounty out of
what they move. `rebalance`'s bounty is real only on the deleveraging half, which is the direction
that has something to pay a caller from; levering up frees nothing and pays none, and is not
urgent — the position is already above target leverage, the safe direction, so it can wait for
Flap's own scheduled wake rather than needing a paid caller to race it. Flap's
Trigger Service calls the automatic path every five minutes while there is work; after a wake
that finds nothing to do it backs off to hourly, so it is not paying a trigger fee to be told the
same thing. That is a floor on responsiveness, not a cap: the three working functions are
permissionless and paid, so anyone may call them at any moment without waiting for a wake.

Nothing in the vault is owner-gated, admin-gated or keeper-gated. The leverage target, health
floor, rebalance band, bounties, swap route, fee tier, slippage floor and settlement interval
are all `constant` with no setter. The one authority that reaches them is the Flap Guardian
replacing the implementation behind the beacon — Rule 009's proxy exemption working as
intended.

## Status

Live on BNB Chain (56) and BSC testnet (97), at identical addresses. **No token has been
launched** — Flap's own launcher creates one through the VaultPortal at registration.

| Contract | Address | Runtime |
|---|---|---:|
| `LeverVaultFactory` (proxy — register this) | `0x2559DD277E5a8E2f6d8594Deded3eD1025e6402C` | 279 |
| `LeverFactoryBeacon` | `0x4EB9bE3Ec27673c5A7B88e1420fA349d68A69910` | 785 |
| `LeverVaultFactory` (implementation) | `0x04F0AAc92361f66E0B78c8f6d03656Ab6A9a460d` | 7,745 |
| `LeverBeacon` | `0x16Bb8430D443d120BC4bDe71d43d2A9EeA759E0B` | 785 |
| `LeverVault` (implementation) | `0xC57c9D2ac2459e814Bc93C885C8D9F9E6d6Cd6A1` | 22,678 |

Both beacons are owned by the Flap Guardian from inside their own constructors — the deployer
never held upgrade authority for a single block. See `deployments/56.json` and
`submission/FACTORY.md`.

## Measured on live BNB Chain state

BSC public nodes prune state after ~96s, so a forge fork cannot survive a multi-step test.
`tools/verify.py` runs 33 assertions as atomic `eth_call`s with a state override, against
mainnet as it stands. `bash scripts/test.sh` runs those plus the forge suites.

## There is no 5x, and there cannot be

Venus's collateral factor on these markets is 80%. Health is `supply x CF / debt`, and Venus
liquidates at 1.00. Run leverage against it:

| target | health | price move that liquidates |
|---:|---:|---:|
| 2.00x | 1.600 | -37.50% |
| 3.00x | 1.200 | -16.67% |
| 4.00x | 1.067 | -6.25% |
| **5.00x** | **1.000** | **0.00%** |

**5x is not a risky approach to the liquidation point — at CF 80% it IS the liquidation
point.** Keel targets 3x, holds a `MIN_HEALTH_BPS` floor of 12000 (liquidated only by a 16.7%
move), and deleverages urgently below 11300. Deploy and harvest hold that floor absolutely and
revert below it. Rebalance is the one exception, and deliberately so: at 3x the health floor is
`0.8 x 3/2 = 1.2000` exactly, so a deleverage that lands on its own target sits precisely on the
line and any swap friction puts it a hair under -- an absolute check there would revert the very
move it exists to encourage, and would also revert a deep rescue climbing from 1.05 to 1.15. It
requires health to have risen instead, keeping the absolute floor as the other way to pass. At CF 80% the floor is the real cap on the
product:

| health floor | max leverage |
|---:|---:|
| 1.10 | 3.67x |
| 1.20 | **3.00x** |
| 1.30 | 2.60x |

### Flash build — why it is required, not an optimisation

Venus checks collateral **at the instant of the borrow**, before the proceeds become
collateral. So the one-shot borrow the algebra allows — `(s*cf - h*b)/(h - cf)` — is rejected
outright with `math error`, and a loop can only take the sliver its *current* collateral
supports. Those passes converge geometrically at `cf/h = 0.667`: 18 swaps to reach 3x.

A flash loan reverses the order — supply first, borrow second — and builds the whole position
with one swap.

The flash pool must be a **different fee tier from the swap pool**: a V3 pool is locked for the
duration of its own flash callback, so borrowing and swapping in the same pool reverts `LOK`.
Flash runs on the 0.05% WBNB/USDT pool (`FLASH_POOL.fee()` is `500` on chain); swaps route
through the 0.01% tier (`SWAP_FEE = 100`). `submission/check` asserts both tiers on chain.

## Routing

PancakeSwap **V2's** pool is thin where **V3's is deep**. Measured against the Venus oracle
price, concentrated liquidity barely moves with size:

| leg | V2 slippage | V3 slippage |
|---:|---:|---:|
| 1,000 USDT | 1.04% | 0.39% |
| 5,000 USDT | 2.19% | 0.39% |
| 18,000 USDT | 5.92% | 0.40% |
| 40,000 USDT | 12.25% | **0.43%** |

So the vault routes through V3 `exactInputSingle` (selector `0x414bf389` — read off the
deployed router's dispatch table, not assumed). The unwind's two swaps carry a slippage floor
of `MAX_SWAP_SLIP_BPS = 300`, valued at Venus's own oracle — the same price that decides
whether this position gets liquidated, not a second feed with its own failure modes.

## Layout

```
src/flap/LeverVault.sol          the vault: tax in, 3x Venus position, 5-minute settlement
src/flap/LeverVaultFactory.sol   what Flap registers; creates one BeaconProxy per token
src/flap/LeverBeacon.sol         UpgradeableBeacon whose owner is the Flap Guardian
src/flap/VaultBase*.sol          Flap's own base contracts, unmodified
src/interfaces/IVenus.sol        Venus, PancakeSwap and WBNB interfaces
script/DeployFlapFactory.s.sol   the only deploy path: five contracts, two of them beacons
script/LaunchKeel.s.sol          launches through Flap's official VaultPortal
test/                            52 forge tests; see scripts/test.sh
tools/verify.py                  33 live-state assertions, one atomic eth_call each
site/                            the public site
vault-ui/                        the custom Vault UI submitted to Flap
submission/                      what Flap reviews; start at submission/README.md
```

## Frontend

`site/` is the public site, deployed. `vault-ui/` is the custom Vault UI package for Flap's
Workbench — a top-of-page risk banner, live parameters read on chain, and a permissionless
trigger button anyone can press.

Three rules both are built to:

- **ABIs are generated** from forge artefacts by `tools/gen-vault-abi.mjs`, never hand-copied.
  A hand-written slice drifts silently the moment a signature changes.
- **Empty renders empty.** No fixture fallback anywhere — a demo fixture becomes the only
  content the day real data is missing.
- **A value that has not loaded is not zero.** Every read renders an em dash when null.
  Rounding "unknown" down to 0 on a page where people commit money is how you overcharge.

## Not done yet

- No third-party security audit. Submitted to Flap for review; repeated adversarial
  self-review is not an audit.
- `vault:check` still reports one blocking rule, `manifest-binding/missing-test-token`, which
  needs a real 7777/8888 token bound in the manifest. Flap's launcher creates that token at
  registration, so the rule can only close afterwards.
