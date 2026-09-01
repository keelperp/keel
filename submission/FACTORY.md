# LeverVaultFactory — what to register

## The address

Register **`0xb79443A953E6340Bdcba2F420C9f3eD50864f90b`**.

That address is the same on BNB Chain (56) and on BSC testnet (97) — same bytecode, same
deployer, same nonce, so CREATE lands it in the same place on both. Two more contracts came
out of the same transaction; they are not registered, but an admin should be able to see them
and recognise them.

| Contract | Address | Runtime bytes |
|---|---|---:|
| `LeverVaultFactory` — **this is the one to register** | `0xb79443A953E6340Bdcba2F420C9f3eD50864f90b` | 6,476 |
| `LeverBeacon` — upgrade authority | `0x552Fa7b39D6bD4AAAa9A84615b1d8e169A6f1Fd3` | 785 |
| `LeverVault` — the implementation behind every vault | `0x644BFBA1D21b6bBab98fF3ddC281C1e536af85d9` | 19,462 |

Both deployments were made by `0x1544A8fCE3a3c39E0a744a13392981bEcDF014f4` at nonce 1:

| Chain | Block | Transaction | `beacon.owner()` |
|---|---:|---|---|
| BNB Chain, 56 | 119,116,447 | `0x88afc2d3bfea9e3e3ce40b49d65d53f51c1511bc3208404fa9eda4bc5238362d` | `0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b` — Flap Guardian, BNB Chain |
| BSC testnet, 97 | 128,260,131 | `0xba13570ab6942c7ed29e8646eea14d6c2a5e624273e26a95b2341cb6b86276f9` | `0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950` — Flap Guardian, testnet |

Those two transactions are recorded in `deployments/56.json` and `deployments/97.json`. The
runtime sizes above are what a node returns today, not what the build promised.

The registration call is Flap's to make — `registerVaultFactory` requires `VAULT_ADMIN_ROLE`,
which we do not hold. On chain 56 the VaultPortal is
`0x90497450f2a706f1951b5bdda52B4E5d16f34C06`, on chain 97 it is
`0x027e3704fC5C16522e9393d04C60A3ac5c0d775f` (both are resolved by chain id inside
`VaultFactoryBaseV2._getVaultPortal`, so the factory refuses any caller that is not the portal
for the chain it is standing on).

```solidity
registerVaultFactory(0xb79443A953E6340Bdcba2F420C9f3eD50864f90b, /* enabled */ true, /* official */ false, riskLevel)
```

We are not asking to be marked `official`, and we are not asking for a risk level below
`UNVERIFIED`. There has been no third-party audit — `AUDIT.md` is the contract author's own
review, rule by rule. The classification is yours.

**No token has been launched, on any chain.** The factory is deployed and nothing has been
built with it: `vaultCount()` returns `0` on 56 and on 97. A Keel token would be created by
Flap's own launcher through the VaultPortal, which is the call that would make this factory
produce its first vault.

**No vault can be created on testnet either**, and that is a property of chain 97 rather than
of this code. Building a position requires a flash loan (Venus checks collateral before
borrowed funds become collateral, so the first borrow has nowhere to stand), and BSC testnet
has no PancakeSwap V3 pool to flash from: `getPool` returned the zero address for 32 WBNB
pairs across 4 fee tiers, and no `PoolCreated` event appears in the last 40,000 blocks. Both
test USDT contracts gate `mint()` behind `Ownable` with a third party as owner, so we cannot
build a pool ourselves. Venus itself *is* live on 97 — vBNB is listed and 16.3 tBNB is
borrowable — but its collateral factor is 70% against mainnet's 80%, and `_cf()` reads that
from chain, so even with a pool the health floor would bind leverage near 2.4x there. If Flap
has a testnet environment or a seeded pool it wants used, we will run the end-to-end there.

## Do not register `0xE7EC91f5a78c413cDF2F1140B29d51cAfFAfE535`

An earlier factory at `0xE7EC91f5a78c413cDF2F1140B29d51cAfFAfE535` is also on chain, on both
56 and 97, deployed by the same wallet at nonce 0. **It is retired.** Its `vaultDataSchema()`
still describes the project's share of each harvest as 40%, from before the split changed to
30%; the vault's `PROJECT_SHARE_BPS` is `3000`, so that factory would hand a launcher's UI a
number the contract does not honour.

It is easy to find first and hard to tell apart: it has the same runtime size, 6,476 bytes, so
a size check will not separate them. Two things do. Its `beacon()` returns a different beacon
from the one in the table above, and its `vaultDataSchema()` field description reads
"Receives 40% of every harvest" where the live one reads "Receives 30% of every harvest".
Both are one `cast call` away, and the commands are at the end of this page.

## One transaction, three contracts

`LeverVaultFactory`'s constructor is a single line:

```solidity
constructor() {
    beacon = address(new LeverBeacon(address(new LeverVault())));
}
```

Deploying the factory therefore deploys the implementation and the beacon as well, in that
order, and wires them without a second transaction and without a constructor argument anybody
could get wrong. The two children are ordinary CREATEs from the factory address, so their
addresses are the factory's own nonces 1 and 2 — which is checkable arithmetic rather than a
claim (again, commands at the end).

The cost of that convenience is initcode size. A contract that `new`s another contract carries
that contract's entire creation code inside its own, so the factory's initcode is **27,668
bytes**: its own 6,476-byte runtime, plus `LeverVault`'s 19,490-byte creation code, plus
`LeverBeacon`'s 1,528 — 27,494 of the total, with the remaining 174 bytes being the
constructor that runs them. The child sizes are read from `out/LeverVault.sol/LeverVault.json`
and `out/LeverBeacon.sol/LeverBeacon.json` after `forge build`.

Two limits apply and both are cleared. EIP-170 caps *runtime* code at 24,576 bytes, and every
deployable contract here is inside it — the largest is `LeverVault` at 19,462. EIP-3860 caps
*initcode* at 49,152, and 27,668 is inside that. Only a real deploy exercises the second one,
and both of the deploys in the table above did — mainnet first, testnet immediately after.

Three test-only contracts — `FlapProbe` (30,081), `KeelProbe` (27,451), `KeelE2E` (46,100) —
are over the EIP-170 limit. They are injected into an `eth_call` by state override and are
never deployed to any chain.

## Who can upgrade a vault

Every vault this factory creates is a `BeaconProxy` pointing at `LeverBeacon`, so whoever owns
the beacon can replace the logic of every vault at once. That owner is the Flap Guardian, and
it is the Guardian from the first block: `LeverBeacon`'s constructor resolves the Guardian by
chain id and calls `_transferOwnership(guardian)` before the constructor returns. The deployer
never held upgrade authority — there is no window in which it did, and no transfer transaction
to look for. The same bytecode resolves `0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b` on 56 and
`0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950` on 97, which is what the two deployments
demonstrate; on a chain it does not know, the constructor reverts rather than guessing.

This is the premise of rule 009's proxy exemption, not a side note to it. Rule 009 lets a proxy
vault omit emergency-withdraw functions *because* the beacon is the emergency mechanism, so
the exemption is only honest if the Guardian holds the beacon and the operator holds nothing.
Accordingly there are no emergency-withdraw functions on the vault, no pause, and no
privileged role at all — there is no role for a Guardian to be granted here, and nothing that
could lock it out. `test_beaconIsOwnedByTheGuardianNotTheDeployer` asserts the ownership and
that the deployer does not retain it; `test_beaconRefusesAnUnsupportedChain` asserts the
revert on an unknown chain id.

## Launch parameters

These are the values a Keel launch will pass to `newTokenV6WithVault`. They are not yet used
anywhere — no token exists. "Gate" marks the ones this factory checks and rejects before the
token is created; the rest are Flap's own constraints or our choices.

| Field | Value | Gate |
|---|---|---|
| `name` / `symbol` | Keel / KEEL | |
| supply | 1e27 | Flap fixed |
| `tokenVersion` | `TOKEN_TAXED_V3` | |
| `quoteToken` | `address(0)` — native BNB | **gate** |
| `buyTaxRate` / `sellTaxRate` | 200 / 200 | **gate** (both zero is refused) |
| `taxDuration` | 3,153,600,000 (100 years) | |
| `antiFarmerDuration` | 259,200 (3 days) | |
| `mktBps` | 8000 — to the vault | **gate** (zero is refused) |
| `dividendBps` | 2000 | **gate** (zero is refused) |
| `deflationBps` | 0 | |
| `lpBps` | 0 | |
| `dividendToken` | `address(0)` — the quote, which reaches the dividend contract as WBNB | **gate** |
| `minimumShareBalance` | 10,000e18 | |
| `commissionReceiver` | `address(0)` — this factory does not touch commission | |
| `dexThresh` | `FOUR_FIFTHS` | |
| `migratorType` | `V2_MIGRATOR` | |
| `vaultData` | `abi.encode(project address)` — fixed at creation, no setter | **gate** |

The four bps fields must sum to 10000; 8000 + 2000 + 0 + 0 does.

### What the factory refuses, and where

Validation happens in two places, at two different moments.

**Before the token exists**, the VaultPortal calls `onBeforeLaunch(bytes)`, which decodes the
normalized payload and lands in `_validateBeforeLaunch`. Five launches are refused there, each
one a mistake that could not be repaired afterwards:

- a `quoteToken` that is not `address(0)` — the vault's collateral, its borrow and its payouts
  are all BNB, so an ERC-20 quote would be a different vault, not a setting of this one;
- a `dividendToken` that is neither `address(0)` nor WBNB `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c`
  — `harvest()` would revert forever, and the vault would accumulate gains no holder could
  ever be paid;
- `buyTaxRate == 0 && sellTaxRate == 0` — nothing would ever fund the vault;
- `vaultBps == 0` (this is `mktBps` under the normalized payload's name) — same outcome;
- `dividendBps == 0` — refused conservatively. `minimumShareBalance` is only "required when
  dividendBps > 0", which suggests the dividend contract may not be initialised at all
  without it, and `harvest()` would then have nowhere to deposit. **We have not verified this
  against a live zero-dividend token**, so the guard errs toward refusing a launch rather than
  stranding one.

Note that this factory returns an **empty** `tokenCreationPolicies()` array. It declares no
machine-readable constraints, so a launcher UI cannot pre-validate a form against it and must
call `onBeforeLaunch` to find out. That is a gap in what we publish, not in what is enforced.
`factorySpecVersion()` returns `"v2.2"`; the retired v2.1 hook
`onBeforeNewTokenV6WithVault` is left reverting exactly as the base class leaves it, because a
guard written on a hook the portal no longer calls is a guard that silently never runs.
`test_theRetiredV6HookIsRefusedNotSilentlyIgnored` pins that down, and
`test_factoryReportsTheV22Spec` pins the version string.

**At creation**, `newVault` re-checks every argument rather than trusting the caller: the
caller must be the VaultPortal for this chain, the tax token must be non-zero, the quote must
be `address(0)`, the creator must be non-zero, the token must not already have a vault,
`vaultData` must be exactly 32 bytes, and the project address it decodes to must be non-zero.
Each revert carries an inline bilingual string; there are no custom errors in our own code.
The vendored Flap base keeps its two, and both are reachable at this address:
`LegacyV6ValidationHookNotImplemented` from the retired v2.1 hook, and
`UnsupportedChain(uint256)` from `_getVaultPortal`. A UI that renders reverts verbatim will
still meet those two as ABI-encoded error data.
`test_newVaultRejectsEveryCallerThatIsNotThePortal` covers the caller check (including a call
from the Guardian, which is also refused), and `test_portalCallStillValidatesEveryArgument`
covers five of the other six — tax token, quote, creator, `vaultData` length, project. The
sixth, *the token must not already have a vault*, is enforced in `newVault` but exercised by
no test in the repository; take it as read from the source, not from a green suite.
`test_launchValidationAcceptsAServeableToken` and
`test_launchValidationRejectsTokensTheVaultCouldNeverServe` cover the five launch gates, and
`test_onlyNativeBnbIsSupportedAsQuote` and `test_factoryDataSchemaMatchesNewVaultAbi` cover
`isQuoteTokenSupported` and the schema/ABI agreement.

## Verifying this page against a node

Nothing below needs a key, an archive node, or our repository — only `cast` and a public RPC.

```bash
R=https://bsc-dataseed.bnbchain.org          # chain 56
T=https://bsc-testnet-rpc.publicnode.com     # chain 97
F=0xb79443A953E6340Bdcba2F420C9f3eD50864f90b
B=0x552Fa7b39D6bD4AAAa9A84615b1d8e169A6f1Fd3

# runtime sizes: 6,476 / 785 / 19,462
cast codesize $F --rpc-url $R
cast codesize $B --rpc-url $R
cast codesize 0x644BFBA1D21b6bBab98fF3ddC281C1e536af85d9 --rpc-url $R

# the wiring, read from the chain rather than from the deploy log
cast call $F "beacon()(address)" --rpc-url $R              # -> 0x7444B36C...
cast call $B "implementation()(address)" --rpc-url $R      # -> 0xAF3A1d97...
cast call $B "owner()(address)" --rpc-url $R               # -> 0x9e27098d... (Guardian, 56)
cast call $B "owner()(address)" --rpc-url $T               # -> 0x76Fa8C52... (Guardian, 97)

# the same three addresses exist on 97
cast codesize $F --rpc-url $T
cast call $F "beacon()(address)" --rpc-url $T

# nothing has been launched: zero vaults on either chain
cast call $F "vaultCount()(uint256)" --rpc-url $R
cast call $F "vaultCount()(uint256)" --rpc-url $T

# spec, quote support, and the schema whose 30% must match PROJECT_SHARE_BPS
cast call $F "factorySpecVersion()(string)" --rpc-url $R                       # -> "v2.2"
cast call $F "isQuoteTokenSupported(address)(bool)" 0x0000000000000000000000000000000000000000 --rpc-url $R   # true
cast call $F "isQuoteTokenSupported(address)(bool)" 0x55d398326f99059fF775485246999027B3197955 --rpc-url $R   # false (USDT)
cast call $F "vaultDataSchema()((string,(string,string,string,uint8)[],bool))" --rpc-url $R
cast call $F "tokenCreationPolicies()" --rpc-url $R        # empty array, as stated above

# the retired factory, for contrast: same size, 40% in the schema, a different beacon
cast codesize 0xE7EC91f5a78c413cDF2F1140B29d51cAfFAfE535 --rpc-url $R
cast call 0xE7EC91f5a78c413cDF2F1140B29d51cAfFAfE535 "vaultDataSchema()((string,(string,string,string,uint8)[],bool))" --rpc-url $R
cast call 0xE7EC91f5a78c413cDF2F1140B29d51cAfFAfE535 "beacon()(address)" --rpc-url $R

# the deploy transactions and their blocks
cast tx 0x88afc2d3bfea9e3e3ce40b49d65d53f51c1511bc3208404fa9eda4bc5238362d blockNumber --rpc-url $R
cast tx 0xba13570ab6942c7ed29e8646eea14d6c2a5e624273e26a95b2341cb6b86276f9 blockNumber --rpc-url $T

# the addresses are CREATE arithmetic, not a coincidence
cast compute-address 0x1544A8fCE3a3c39E0a744a13392981bEcDF014f4 --nonce 1   # -> the factory
cast compute-address $F --nonce 1                                           # -> the implementation
cast compute-address $F --nonce 2                                           # -> the beacon
cast compute-address 0x1544A8fCE3a3c39E0a744a13392981bEcDF014f4 --nonce 0   # -> the retired factory
```

To reproduce the sizes from source instead of reading them off a node:

```bash
forge build --sizes        # runtime sizes; initcode is in out/<Name>.sol/<Name>.json
bash scripts/test.sh       # 28 forge tests + 33 live-state assertions + 8 vault-UI checks = 69
```

`scripts/test.sh` runs everything named on this page. A plain `forge test` also exits 0 (29
passed, 1 skipped); the skipped group is the position lifecycle, which needs an archive RPC
that BSC has no free equivalent of. Three of its four tests have counterparts among the 33
atomic `eth_call` checks in `tools/verify.py`, asserted against live mainnet state: the build
to target leverage, the 70/30 harvest split, and the automatic path deploying everything it
was holding. The fourth, `test_pendingActionReportsWhatTheNextWakeWillDo`, does not —
`verify.py` decodes the pending-action values and never asserts on them — so what the next
wake reports is covered only by the suite that skips.
