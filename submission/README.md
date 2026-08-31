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
account, no published NAV, and no pause — and no slippage bound on the vault's swaps either, which
[`RULES.md`](RULES.md) discloses under rule 003. The split and the cadence are `constant`: no
setter, no role, no governance path, and no change short of the Flap Guardian replacing the
implementation behind the beacon.

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

Deployed by `0x1544A8fCE3a3c39E0a744a13392981bEcDF014f4`. The same deployer and nonces put the
three contracts at identical addresses on BNB Chain (56) and BSC testnet (97). Deployment
transactions and per-chain block numbers are in [`FACTORY.md`](FACTORY.md).

| | Address | |
|---|---|---|
| `LeverVaultFactory` | `0x8666262877046df9f4B338B9D7f1a30d55688A5c` | **this is the one to register** — runtime 6,476 bytes |
| `LeverBeacon` | `0x7444B36CdC9372588C9C6A9A21bc435F31FE761a` | 785 bytes; owner is the Flap Guardian on each chain, transferred inside the constructor, so the deployer never held upgrade authority. The Guardian can replace the implementation behind it, which is rule 009's proxy exemption working as intended and the only way any constant in the vault changes |
| `LeverVault` (implementation) | `0xAF3A1d973724ed416FEE48E5A58146893D1a9ac1` | 19,462 bytes, sitting behind that beacon |

One correction to make before you look at the chain: an earlier factory,
`0xE7EC91f5a78c413cDF2F1140B29d51cAfFAfE535`, is also deployed and is **retired**. Its
`vaultDataSchema()` still described the project share as 40%. It is not the submission and should
never be registered.

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

What we have instead of a testnet run is 69 checks, all green: 28 forge tests, 33 assertions made
against BNB Chain's current live state across seven atomic `eth_call`s, and 8 vault-UI package
checks. Plain `forge test` also exits 0 — 29 passed, 1 skipped, the skip being the position
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
split. Two limits worth knowing before you lean on it: the size rows it diffs are the ones in
[`AUDIT.md`](../AUDIT.md), which carries the same figures this page republishes, and
`PROJECT_SHARE_BPS` is the only constant it checks — read out of `src/flap/LeverVault.sol` by
regex, not out of the artefact. Pass `RPC=<url>` to use your own node. Read a claim here, then
make the script prove it as far as it reaches; where it does not reach — the 69-check tally and
the testnet finding — the working is in [`AUDIT.md`](../AUDIT.md) and reproduces with `forge test`
and `python3 tools/verify.py`.
