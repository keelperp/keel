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
| BTC 2x long | 2.00 | 1,999.40 | 999.72 | 999.70 |
| BTC 3x long | 3.00 | 2,998.52 | 1,999.02 | 999.52 |
| BTC 5x long | 4.72 | 4,713.18 | 3,714.04 | 999.15 |
| BTC 2x short | 2.00 | 2,994.72 | 1,996.52 | 998.22 |
| BNB 3x long | 3.00 | 2,997.60 | 1,998.41 | 999.21 |

Building the position costs **0.05%**. It cost 2–3.5% until the router moved to
PancakeSwap V3 — see "Routing" below.

### Rebalance bounty — `tools/bounty.py`

With no keeper, `rebalance()` has to be worth someone's gas. A vault told to reach 3x but
given one loop lands short, which is a drift with no price move required:

| | |
|---|---:|
| leverage after mint (`maxLoops=1`) | 1.792x (target 3.000x) |
| `needsRebalance()` | YES |
| bounty quoted | 30 bps |
| bounty minted to caller | 3.0000 shares = **30 bps of supply** |
| leverage after rebalance | 2.428x |
| second call in the same hour | refused, `"cooldown"` |

Paid in freshly minted shares, so it is funded by dilution and can never fail for want of
liquidity. 5–30 bps, scaled to drift, one hour apart.

5x lands at 4.74 rather than 5.00: Venus's 80% collateral factor puts 5x at the limit of an
infinite loop, and `maxLoops` is finite by design.

### Full product — `tools/e2e.py`

launch → lever → curve trade → sell → graduate → seed pool → burn LP, one atomic call:

| | seed 20,000 |
|---|---:|
| tokens to creator | 623,949,579.83 |
| backing after seed | 19,755.50 USDT |
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

## Routing

PancakeSwap **V2's** USDT/BTCB pool holds ~$700k. **V3's 0.05% pool holds $16.2M** — 23x
deeper at a fifth of the fee. Measured against the Venus oracle price:

| leg | V2 slippage | V3 slippage |
|---:|---:|---:|
| 1,000 USDT | 1.04% | 0.39% |
| 5,000 USDT | 2.19% | 0.39% |
| 18,000 USDT | 5.92% | 0.40% |
| 40,000 USDT | 12.25% | **0.43%** |

Concentrated liquidity barely moves with size, so the vault routes through V3
(`exactInputSingle`, selector `0x414bf389` — read off the deployed router's dispatch table,
not assumed). A V2 path with an optional WBNB hop remains as fallback for pairs with no V3
pool, and it quotes both legs and takes the better one.

Effect on the full product: a 20,000 seed used to land 17,900 of backing. It now lands
**19,755 — a 1.22% cost, of which 1% is the trading fee itself**.

A flash-loan build would save roughly 0.45% more in swap fees. It is no longer the
bottleneck it looked like when the router was on V2.

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

## Operator interface

Three commands, per the house standard. Implementation is `tools/go.mjs`, zero npm
dependencies — every chain call shells out to `cast`.

```bash
CONFIRM=KEEL ./deploy    # factory + curve + the opening vault set
CONFIRM=LOCK ./lock      # +1 day onto the standing protocol-fee lock
             ./exit      # immediate. no dry run, no confirm word
```

There is no POL here to lock — launch LP is burnt into `LPLock` forever. The one thing the
protocol *can* take is its fee share, so that is what `./lock` binds, under the same rules:
off by default, custody only, one call adds a day onto whatever stands, no unlock, 30-day
ceiling.

`scripts/rehearse-ops.sh` runs all three against a local fork — the same executables, not a
simulation of them. It caught two things a build could not:

- `swapHop: WBNB` on the BNB vault collided with its own collateral and reverted `hop collides`
- `./exit` **aborted entirely** when the fee lock refused the sweep. `die()` is `process.exit`,
  so the `try/catch` around it caught nothing. Skipping a leg is allowed; skipping the rest of
  the command is not. It now reports the refusal and still names every balance.

## Not done yet

- Flash-loan position build (~0.45% more)
- Frontend
- No audit. Repeated adversarial self-review is not an audit.
