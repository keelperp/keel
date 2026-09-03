# Keel — submission to Flap

Everything needed to register `LeverVaultFactory` on the VaultPortal, in one directory.

| | |
|---|---|
| Vault type | `LeverVault` — a taxed-V3 token's trading tax levered into a 3x BNB long the vault holds itself on Venus |
| Quote asset | native BNB only (`address(0)`) |
| Base | `VaultBaseV2` / `VaultFactoryBaseV2`, the v2.2 path, vendored under `src/flap/` |
| Compiler | solc 0.8.26, Cancun, optimizer 200, no viaIR |
| Source | https://github.com/keelperp/keel |
| Site | https://www.keelperp.fun |
| X | https://x.com/keel_perp |

Gains are settled by Flap's own trigger service every 5 minutes, and 70% of each gain goes to
holders as WBNB through the token's dividend contract, 30% to the project. There is no keeper
account, no published NAV, and no pause. The swaps that unwind the position do have a bound now:
`harvest`, and `rebalance` when it is deleveraging, value each swap at Venus's own ResilientOracle —
the same price that decides whether this position is liquidated — and pass that value less
`MAX_SWAP_SLIP_BPS`, 3%, as `amountOutMinimum`, so an unwind landing further below the oracle
reverts. Three percent is deliberately loose: it bounds what a sandwiched `harvest` or `rebalance`
can cost, it does not prevent one, and that residual exposure is what [`RULES.md`](RULES.md)
discloses under rule 003. The floor is on chain: the implementation behind the beacon below returns
`MAX_SWAP_SLIP_BPS() = 300` on 56 and on 97. The split and the cadence are `constant`: no setter, no
role, no governance path, and no change short of the Flap Guardian replacing the implementation
behind the beacon.

## What is in here

| File | What it is |
|---|---|
| [`FACTORY.md`](FACTORY.md) | the addresses to register, how they were deployed, and the parameters KEEL will be launched with |
| [`MECHANISM.md`](MECHANISM.md) | **the paragraph the audit should be read against.** Any behaviour that contradicts it is a bug in the contracts |
| [`RULES.md`](RULES.md) | the ten rules, one row each, with the test that proves it |
| [`SPEC-CHECK.md`](SPEC-CHECK.md) | our own rule-by-rule self-check against the ten rules — written by the authors of the contracts, not an audit and not a run of yours — and what it leaves open |
| [`UI-REQUEST.md`](UI-REQUEST.md) | the custom vault UI we intend to build from your component template, and what we need confirmed before building it |
| [`schema.txt`](schema.txt) | `vaultDataSchema()`, `description()` and `vaultUISchema()` read back from the deployed contracts, not transcribed from source |
| [`check`](check) | the verification script for this directory — see **How to verify** below |
| [`art/`](art/) | banner, square and logo as PNG, and the mark as SVG |

## Addresses to register

Deployed by `0x1544A8fCE3a3c39E0a744a13392981bEcDF014f4`. The same deployer and nonce sequence
put all five contracts at identical addresses on BNB Chain (56) and BSC testnet (97). Deployment
transactions and per-chain block numbers are in [`FACTORY.md`](FACTORY.md).

| | Address | |
|---|---|---|
| `LeverVaultFactory` | `0x1B4304227D4090E2418ADd6bdB8AA43395cBf69e` | **this is the one to register** — a 279-byte `BeaconProxy`; its logic is the 7,745-byte implementation at `0x4849D256A180f5Db5990fBfF25b2b2C47EC12C19`, behind the Guardian-owned `LeverFactoryBeacon` at `0x237931c0B9770bdfFDbE0a77e75A9d406377361a`. **This address does not move when the Guardian upgrades it** |
| `LeverBeacon` | `0xD71A4655dd2f5C8f3ccC03582DafEAD1b1E73934` | 785 bytes; owner is the Flap Guardian on each chain, transferred inside the constructor, so the deployer never held upgrade authority. The Guardian can replace the implementation behind it, which is rule 009's proxy exemption working as intended and the only way any constant in the vault changes |
| `LeverVault` (implementation) | `0x471f00F9D9cfAc8910a20C95770Dd7706Cb09D9f` | 22,529 bytes, sitting behind that beacon — the code that carries the exit-path floor. `MAX_SWAP_SLIP_BPS()` reads 300 at this address on both chains |

Two corrections to make before you look at the chain, because the same deployer left two earlier
factories behind on both 56 and 97 and **neither should ever be registered**. All three are 6,476
bytes, so size does not tell them apart; `beacon()` does.

`0x8666262877046df9f4B338B9D7f1a30d55688A5c` (nonce 1, block 119,729,060 on 56) is the set this
one replaces. Its beacon is `0x7444B36CdC9372588C9C6A9A21bc435F31FE761a`, pointing at
`0xAF3A1d973724ed416FEE48E5A58146893D1a9ac1` — 19,462 bytes, which unwinds at
`amountOutMinimum: 0`, the missing floor Flap's pre-audit flagged.
`MAX_SWAP_SLIP_BPS()` reverts at that address, which is the cheapest way to tell the two
implementations apart.

`0xE7EC91f5a78c413cDF2F1140B29d51cAfFAfE535` (nonce 0) is older still. Its `vaultDataSchema()`
still described the project share as 40%, from before the split changed to 30%.

## Status

The factory is live on both chains and its beacon is already Guardian-owned. Nothing else has
happened yet, and we would rather say so plainly than let the address list imply otherwise:
**no token has been launched on any chain, and no vault has been created anywhere.** On
mainnet that is deliberate — a vault only comes into existence when the VaultPortal launches a
token through a registered factory, so SB-02 gates it, and we would like SB-01 ruled on before any
token is irreversible. On testnet it is not a choice: a vault **cannot** be created on chain 97 at
all. Building the position must flash-borrow, because Venus checks collateral before borrowed funds
become collateral, and BSC testnet has no PancakeSwap V3 liquidity to borrow from — `getPool`
returned the zero address for 32 WBNB pairs across 4 fee tiers, and no `PoolCreated` event appears
in the last 40,000 blocks. We cannot create the pool either: both test USDT contracts gate `mint()`
behind `Ownable` with a third party as owner. Venus itself is live there (vBNB listed, 16.3 tBNB
borrowable), but its collateral factor is 70% against mainnet's 80%, and since `_cf()` reads it from
chain the health floor would bind leverage near 2.4x even if a pool existed. If you have a test
environment or a pool you want this run against, we will run it there.

One thing the address list does not say on its own: this set **is** the fix. Flap's pre-audit
flagged that the exit path swapped with `amountOutMinimum: 0` — the gap rule 003 had already
disclosed — and rather than ask for an exception we changed the code and redeployed, which is why
the addresses above are not the ones this package named before. `_sellBnb` and `_buyBnb` now floor
`amountOutMinimum` at Venus's ResilientOracle less 3%. The build path — `deployPending`, and
`rebalance` when it levers up — still passes zero, deliberately: its flash callback ends in
`require(got >= owed)`, which is the tighter bound, because the swap must return enough to repay the
flash loan or the whole build reverts. Do not read the build as newly protected; it was always
bounded, by the pool itself. The floor costs 120 bytes, and those 120 bytes are the whole difference
between the retired implementation's 19,462 and the 22,529 now behind the beacon. What it buys is a
bound, not immunity: 3% is deliberately loose, because the pool drifts from the oracle between
updates and a floor tight enough to catch every sandwich would also stop the vault deleveraging in
exactly the fast market where deleveraging matters most. A sandwich that stays inside the band still
profits. None of that needs taking on our word: `cast call
0x471f00F9D9cfAc8910a20C95770Dd7706Cb09D9f "MAX_SWAP_SLIP_BPS()(uint256)"` returns 300 on both
chains, and the same call against the retired `0xAF3A1d97…` reverts.

What we have instead of a testnet run is 72 checks, all green: 50 forge tests, 33 assertions made
against BNB Chain's current live state across seven atomic `eth_call`s, and 8 vault-UI package
checks. Plain `forge test` also exits 0 — 36 passed, 0 failed, 5 skipped, the skip being the position
lifecycle suite, which needs an archive RPC that BSC does not offer for free.

## Open items

**SB-01 — the 30% project share needs your written acceptance.** It is a Rule 002 recommendation,
not a hard rule, so the ruling is yours to make. The vault takes **0% of the tax**; the 30% is a
share of gains the position earns after it exists, and holders take 70% of the same number every
time. Both are `constant`: no setter, no role, no governance path, and no change short of the
Guardian replacing the implementation behind the beacon. The argument in full is in
[`FACTORY.md`](FACTORY.md) and [`MECHANISM.md`](MECHANISM.md). If you want it changed we will
change the code and redeploy rather than ask for an exception.

**SB-02 — registration.** `registerVaultFactory` requires `VAULT_ADMIN_ROLE`. No address we
control holds it, so this is the one step we cannot take ourselves.

## How to verify

```
./check
```

The numbers on these pages are not typed in by hand. `./check` re-derives them from the build and
from the chain, then diffs them against what the documents say: the three runtime sizes and the
factory initcode against the compiled artefacts, the deployed runtime length of all three
contracts against the local build, `beacon.owner()` against the Guardian, the beacon and factory
wiring against each other, the project share the on-chain `vaultDataSchema()` states against
`PROJECT_SHARE_BPS` in the source, and that native BNB is supported as quote. It also asserts that
this package still says no token exists, and that no page in this directory states a superseded
split. It passes whole as of this writing, the five deployed runtimes included — 279 / 785 / 7,745 / 785 /
22,529 against the local build — which is the row that would have caught this package still
pointing at the pre-floor implementation. Two limits worth knowing before you lean on it: the size
rows it diffs are the ones in [`AUDIT.md`](../AUDIT.md), which carries the same figures this page
republishes, and `PROJECT_SHARE_BPS` is the only constant it checks — read out of
`src/flap/LeverVault.sol` by regex, not out of the artefact. `MAX_SWAP_SLIP_BPS` is not one of
them, so read that one off the chain yourself, as above. Pass `RPC=<url>` to use your own node.
Read a claim here, then make the script prove it as far as it reaches; where it does not reach —
the 69-check tally and the testnet finding — the working is in [`AUDIT.md`](../AUDIT.md) and reproduces with `forge test`
and `python3 tools/verify.py`.
