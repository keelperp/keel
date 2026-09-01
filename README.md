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

The Flap factory is live on BNB Chain at `0x1FBa768c7E78B83edAF99c5094a8ED44A5fdF45B`. No token has been launched — Flap's own
launcher creates one through the VaultPortal. See `deployments/56.json`.

## Measured on live BNB Chain state

BSC public nodes prune state after ~96s and there is no free archive node, so a forge fork
cannot survive a multi-step test. Every number below comes from one atomic `eth_call` with a
state override, run against mainnet as it stands.

### Engine — `tools/probe.py`

| case | leverage | supply $ | debt $ | NAV $ (from 1,000 in) | health | liquidated by |
|---|---:|---:|---:|---:|---:|---:|
| BTC 2x long | 2.00 | 1,999.52 | 1,000.09 | 999.44 | 1.599 | −37.5% |
| BTC 3x long | 2.99 | 2,991.81 | 1,992.74 | 999.08 | 1.201 | −16.7% |
| BTC 2x short | 1.98 | 2,974.59 | 1,976.39 | 998.21 | 1.204 | −16.9% |
| BNB 3x long | 2.99 | 2,991.23 | 1,992.40 | 998.83 | 1.201 | −16.7% |

Building the position costs **0.06–0.18%**, in three passes, via the flash path.

## There is no 5x, and there cannot be

Venus's collateral factor on these markets is 80%. Health is `supply × CF / debt`, and Venus
liquidates at 1.00. Run leverage against it:

| target | health | price move that liquidates |
|---:|---:|---:|
| 2.00x | 1.600 | −37.50% |
| 3.00x | 1.200 | −16.67% |
| 4.00x | 1.067 | −6.25% |
| **5.00x** | **1.000** | **0.00%** |

**5x is not a risky approach to the liquidation point — at CF 80% it IS the liquidation
point.** An earlier build shipped it and measured 4.72x at health 1.015: a 1.5% move in BTC
would have taken the whole position. It is gone. The vault now takes a `minHealthBps` floor
(12000 = liquidated only by a 16.7% move), the constructor **refuses a target the collateral
factor cannot hold**, and `_lever` caps debt by the floor rather than by Venus's own limit.

At CF 80% the floor is the real cap on the product:

| health floor | max leverage |
|---:|---:|
| 1.10 | 3.67x |
| 1.20 | **3.00x** |
| 1.30 | 2.60x |

### Flash build — why it is required, not an optimisation

Venus checks collateral **at the instant of the borrow**, before the proceeds become
collateral. So the one-shot borrow that the algebra allows — `(s·cf − h·b)/(h − cf)` — is
rejected outright with `math error`, and the loop can only take the sliver its *current*
collateral supports. Those passes converge geometrically at `cf/h = 0.667`: **18 swaps to
reach 3x**, at 0.30% in fees.

A flash loan reverses the order — supply first, borrow second — and builds the whole position
with one swap. Cost drops to 0.089% and the loop cap falls from 18 to 3.

The flash pool must be a **different fee tier from the swap pool**: a V3 pool is locked for the
duration of its own flash callback, so borrowing and swapping in the same pool reverts `LOK`.
Flash runs on the 0.05% WBNB/USDT pool (`FLASH_POOL.fee()` is `500` on chain); swaps route through the 0.01% tier (`SWAP_FEE = 100`).

### Rebalance bounty — `tools/bounty.py`

With no keeper, `rebalance()` has to be worth someone's gas. A vault told to reach 3x but
given one loop lands short, which is a drift with no price move required:

| | |
|---|---:|
| leverage after mint (`maxLoops=1`, flash disabled) | 1.660x (target 3.000x) |
| `needsRebalance()` | YES |
| bounty quoted | 30 bps |
| bounty minted to caller | 3.0000 shares = **30 bps of supply** |
| leverage after rebalance | 2.102x |
| second call in the same hour | refused, `"cooldown"` |

Paid in freshly minted shares, so it is funded by dilution and can never fail for want of
liquidity. 5–30 bps scaled to drift, one hour apart — **except** below health 1.10, where the
cooldown is waived and the bounty jumps to 100 bps. An hourly cooldown that protects against
bleed is also the thing that stops anyone saving a position in a fast move; below that line
the loss being avoided dwarfs the dilution.

5x lands at 4.74 rather than 5.00: Venus's 80% collateral factor puts 5x at the limit of an
infinite loop, and `maxLoops` is finite by design.

### Full product — `tools/e2e.py`

launch → lever → curve trade → sell → graduate → seed pool → burn LP, one atomic call:

| | seed 20,000 |
|---|---:|
| tokens to creator | 623,949,579.83 |
| backing after seed | 19,746.72 USDT |
| vault leverage | 3.04x |
| graduation eligible | **YES** |
| unsold supply burned | 126,050,420.17 |
| LP held by `LPLock` | 2,224,859.55 |
| transfer guard lifted | **YES** |
| creator fee (60%) | 120.00 USDT |
| protocol fee (40%) | 80.00 USDT |

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
src/FeeVault.sol      1% trading fee, 60% creator / 40% protocol, creator fees never expire
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

## The factory does not embed the vault

`VaultFactory` reached **23,921 bytes** with `new LevVault(...)` inlined — 655 short of
EIP-170, with every future line in the vault pushing it closer, and a limit that only shows up
on a real deploy. It now takes the creation code as calldata and checks it against a
`vaultCodeHash` fixed at construction: **1,949 bytes**, and provenance is if anything tighter —
only the one build whose hash was recorded can ever be deployed.

## Frontend

`frontend/` — Vite + viem, no framework. `npm run build` is green and typecheck is real
(`tsc --noEmit`, not `tsc -b`, which exits 0 without checking anything when a project has no
references — it caught a `string` where viem needs a literal function name).

Three rules it is built to:

- **ABIs are generated** from forge artefacts by `scripts/gen-abi.mjs`, never hand-copied. A
  hand-written slice drifts silently the moment a signature changes.
- **Empty renders empty.** With no deployment manifest the page says *Not deployed* and shows
  nothing. There is no fixture fallback anywhere — a demo fixture becomes the only content the
  day real data is missing.
- **A value that has not loaded is not zero.** Every read is `Maybe<T>` and renders `—` when
  null. Rounding "unknown" down to 0 on a page where people commit money is how you overcharge.

It is not deployed, because there are no addresses to wire it to. `vercel.json` carries the SPA
rewrite so deep links survive a hard refresh in production — `vite preview` hides that failure.

## Not done yet

- No third-party security audit. Submitted to Flap for review; repeated adversarial self-review is not an audit.
