# Keel

A launchpad whose reserve is an on-chain leveraged position the contract holds itself.

## Why

`ast.fun` proved the story — *a token whose reserve keeps moving even when nobody trades*.
Its reserve is a perpetual on an Aster account operated by a keeper, and that keeper's
address (`0xBbC6fb3F0E28648E7c803b2DA821f284cCAAAE6c`) is an **EOA with zero bytecode**,
shared by all 210 of its vaults. Their own docs say so plainly: *"This is a trusted component,
and we say so plainly."*

Keel keeps the story and removes the custodian.

|  | ast.fun | Keel |
|---|---|---|
| Where the position lives | a keeper's Aster account | the vault contract |
| How NAV is known | keeper publishes every ~90s | `exchangeRate()`, a pure view |
| When data goes stale | buying pauses at 120s | no such state |
| If the operator vanishes | reserve is gone | nothing to take |
| Graduated pool | TOKEN / leveraged share | TOKEN / leveraged share |
| LP after graduation | locked forever | locked forever |

## Status

`NOT_DEPLOYED`. Nothing has been broadcast to any network.

## Measured on live BNB Chain state

BSC public nodes prune state after ~96s and there is no free archive node, so a forge fork
cannot survive a multi-step test. Every number below comes from one atomic `eth_call` with a
state override, run against mainnet as it stands.

### Engine — `tools/probe.py`

| case | leverage | supply $ | debt $ | NAV $ (from 1,000 in) |
|---|---:|---:|---:|---:|
| BTC 2x long | 2.00 | 1,977.62 | 989.49 | 988.20 |
| BTC 3x long | 3.00 | 2,942.92 | 1,962.20 | 980.79 |
| BTC 5x long | 4.74 | 4,575.10 | 3,609.32 | 965.86 |
| BTC 2x short | 2.00 | 2,971.89 | 1,981.48 | 990.49 |
| BNB 3x long | 3.00 | 2,981.82 | 1,987.96 | 993.94 |

5x lands at 4.74 rather than 5.00: Venus's 80% collateral factor puts 5x at the limit of an
infinite loop, and `maxLoops` is finite by design.

### Full product — `tools/e2e.py`

launch → lever → curve trade → sell → graduate → seed pool → burn LP, one atomic call:

| | seed 20,000 |
|---|---:|
| tokens to creator | 623,949,579.83 |
| backing after seed | 17,872.05 USDT |
| vault leverage | 3.04x |
| graduation eligible | **YES** |
| unsold supply burned | 126,050,420.17 |
| LP held by `LPLock` | 2,224,859.55 |
| transfer guard lifted | **YES** |
| creator fee (40%) | 80.00 USDT |
| protocol fee (60%) | 120.00 USDT |

## Two measurement traps this repo already walked into

**A round trip inside one call flatters itself.** An early version reported "out/in 98.4%"
and picked a routing config on it. That number is a lie: buying and redeeming inside a single
`eth_call` hit the same pool with nothing in between, so the vault's own slippage on the way in
is handed back on the way out. In the real world an arbitrageur closes that gap first. The same
A/B, run in one block, shows what the honest metric says:

| size | direct NAV | hop NAV | hop advantage |
|---:|---:|---:|---:|
| 1,000 | 965.88 | 981.09 | +1.6% |
| 5,000 | 4,405.84 | 4,813.10 | +9.2% |
| 20,000 | 13,753.66 | 18,008.04 | **+30.9%** |

Round-trip retention preferred `direct` in every row. NAV — priced by the Venus oracle, not by
the pool we just moved — prefers `hop`, by more and more as size grows. NAV is the one that is
not measuring our own footprint.

**Routing is size-dependent, so the contract quotes both every time.** PancakeSwap V2's
USDT/BTCB pool holds only ~$700k: an 18,000 USDT leg costs 5.90% direct and 2.19% through
WBNB, while a 1,000 USDT leg is cheaper direct because the extra hop's 0.25% outweighs the
slippage saved. `_swap` calls `getAmountsOut` on both paths and takes the better one. No
oracle, no admin, no guess.

## Known costs

Building 3x on a 13,000 USDT seed lands 11,974 of backing — 7.9%, of which 1% is the trading
fee and the rest is Pancake V2 slippage on ~38,600 USDT of swap volume. Routing through V3's
deeper pools, or a flash-loan build that opens the position in one leg, is the next
optimisation. It is a real cost today and is reported as one.

## Layout

```
src/LevVault.sol      the engine: ERC-20 shares over a Venus position the contract owns
src/Bonding.sol       constant-product curve whose reserve asset is a LevVault share
src/LaunchToken.sol   one launch's ERC-20; transfers confined to the curve until graduation
src/FeeVault.sol      1% trading fee, 40% creator / 60% protocol, creator fees never expire
src/LPLock.sol        holds graduated LP; no withdrawal function exists
src/ERC20.sol         minimal standard ERC-20 — no tax, no blacklist, no owner
test/KeelProbe.sol    engine lifecycle + same-block routing A/B
test/KeelE2E.sol      launch → sell → graduate
tools/probe.py        engine cases against live state
tools/ab.py           same-block routing A/B
tools/e2e.py          full product against live state
```

## Not done yet

- Three-command ops (`./deploy`, `./lock`, `./exit`) per the house standard
- Flash-loan position build to cut the slippage above
- Frontend
- No audit. Repeated adversarial self-review is not an audit.
