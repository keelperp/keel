# Keel

An on-chain leveraged position that the contract holds itself.

`ast.fun` proved the story — *a token whose reserve keeps moving even when nobody trades*.
Its reserve is a perpetual on an Aster account operated by a keeper, and that keeper's address
(`0xBbC6fb3F0E28648E7c803b2DA821f284cCAAAE6c`) is an EOA shared by all 210 of its vaults.
Their own docs say so plainly: *"This is a trusted component."*

Keel keeps the story and removes the custodian.

|  | ast.fun | Keel |
|---|---|---|
| Where the position lives | a keeper's Aster account | the vault contract |
| How NAV is known | keeper publishes every ~90s | `exchangeRate()`, a pure view |
| When data goes stale | buying pauses at 120s | no such state |
| If the operator vanishes | reserve is gone | nothing to take |

## Status

`NOT_DEPLOYED`. Nothing has been broadcast to any network.

## Measured

Full mint → hold → redeem round trip, run as one `eth_call` against live BNB Chain state
(`tools/probe.py`). BSC public nodes prune state after ~96s and no free archive node exists,
so a forge fork cannot survive a multi-step test; one atomic call can.

| case | leverage | supply $ | debt $ | NAV $ | out/in |
|---|---:|---:|---:|---:|---:|
| BTC 2x long | 2.00 | 1,972.06 | 987.29 | 984.90 | 98.68% |
| BTC 3x long | 3.00 | 2,910.11 | 1,940.46 | 969.79 | 98.43% |
| BTC 5x long | 4.77 | 4,450.39 | 3,516.80 | 933.72 | 93.70% |
| BTC 2x short | 2.00 | 2,950.03 | 1,967.07 | 983.09 | 98.46% |
| BNB 3x long | 3.00 | 2,991.38 | 1,994.29 | 997.22 | 98.32% |

Round-trip cost is Pancake swap fees plus slippage on the levering loops. A flash-loan
build (one swap instead of N) is the obvious next optimisation.

## Layout

```
src/LevVault.sol      the engine: ERC-20 shares over a Venus position the contract owns
src/ERC20.sol         minimal standard ERC-20 — no tax, no blacklist, no owner
src/interfaces/       Venus core pool + native BNB market + Pancake router
test/KeelProbe.sol    full-lifecycle probe, one atomic eth_call
tools/probe.py        runs the probe against live state via override
```
