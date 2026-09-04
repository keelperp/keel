# Mechanism of record

> This paragraph is the specification. Any behaviour of the deployed contracts that contradicts it
> is a bug in the contracts, not a wording problem here. It is written to be checked line by line
> against `src/flap/LeverVault.sol`, `src/flap/LeverVaultFactory.sol` and `src/flap/LeverBeacon.sol`.

## The paragraph

Keel is the vault behind a Flap taxed-V3 token, and it turns that token's trading tax into a
leveraged BNB long that the vault holds itself on Venus. Every buy and every sell is taxed 2%
(`buyTaxRate` 200, `sellTaxRate` 200, `taxDuration` 3,153,600,000); of that tax `mktBps` **8000**
arrives at the vault as native BNB, `dividendBps` **2000** goes straight to the token's own dividend
contract where it reaches holders without the vault touching it, and `deflationBps` and `lpBps` are
both **0**, so the four shares sum to 10000. The vault's `receive()` does two SSTOREs and one event —
it adds to `totalReceived` and `pendingRevenue` and stops — and returns early, recording nothing, for
anything sent by WBNB or vBNB, because both return BNB on a 2,300-gas stipend that two SSTOREs would
exhaust; all real work is elsewhere. Flap's trigger service
(`0xcf4EE25035CF883895110f367F5BA8172416a7F9`) calls `trigger(requestId)` on a schedule the vault
buys for itself one slot at a time: the vault requires that the caller is that service and that
`requestId` is the exact id it is awaiting, zeroes that id before any work runs so a replay finds
nothing to replay, picks an action, **buys the next slot first** and only then attempts the work
inside a `try`. `_pickAction()` reads Venus once and answers in a fixed priority: **1 rescue** when
health is under `URGENT_HEALTH_BPS` 11000, **2 build** when `pendingRevenue` is at least `MIN_DEPLOY`
0.01 BNB, **3 harvest** when the unrealised gain is at least `MIN_HARVEST` 0.02 BNB, **4 rebalance**
when leverage is outside `TARGET_LEVERAGE` 3e18 ± `REBALANCE_BAND_BPS` 500, and **0 nothing**
otherwise; a wake that found work rebooks in `TRIGGER_INTERVAL` **5 minutes**, a wake that found
nothing rebooks in `IDLE_INTERVAL` 1 hour, and the work is attempted only if `gasleft()` is at least
`WORK_GAS_FLOOR` 1,800,000. A build supplies BNB to vBNB and then levers in a single flash-funded
pass rather than a supply-borrow loop, because Venus checks collateral at the instant of the borrow,
before the borrowed funds have become collateral, so a loop can only ever take the sliver the current
collateral already supports: the vault flash-borrows WBNB from `FLASH_POOL`
`0x36696169C63e42cd08ce11f5deeBbCeBae652050` (PancakeSwap V3 WBNB/USDT 0.05%), supplies it as
collateral **first**, borrows USDT against the enlarged collateral **second**, and swaps that USDT
back to WBNB through the separate 0.01% tier (`SWAP_FEE` 100) to repay the flash in the same
transaction; that build swap alone goes out with `amountOutMinimum: 0` and `sqrtPriceLimitX96: 0`,
deliberately, because what bounds the build is the flash itself — the callback requires
`got >= owed` and reverts the whole transaction if the swap came back too short to repay it, which
is a strictly tighter bound on the same quantity than any price floor would be. Every swap on the
exit path is floored instead: `_sellBnb` and `_buyBnb` pass `_floor(amountIn, pxIn, pxOut)` as
`amountOutMinimum`, valuing the input in units of the output at Venus's ResilientOracle — the same
price that decides whether this position is liquidated — less `MAX_SWAP_SLIP_BPS` **300**, 3%, so a
harvest or rebalance whose swap lands more than 3% under the oracle reverts with PancakeSwap's `Too
little received`; 3% is deliberately loose, and it bounds what a sandwich can take rather than
preventing one. `TARGET_LEVERAGE` 3e18 is a ceiling, not a preference: health is
`CF*L/(L-1)`, so at Venus's mainnet collateral factor of 0.80 a 3x long sits at exactly 1.20 — which is
`MIN_HEALTH_BPS` — and 5x is exactly 1.00, which is liquidation, not aggression; the build therefore
caps debt at `navUsd * cf / (MIN_HEALTH_BPS - cf)` and then takes 97% of that, landing just under
target, measured at **2.960x leverage and 1.208 health at CF 0.80**. A harvest shrinks both legs by
the gain and only the gain — `costBasis` is deliberately never touched — and splits the BNB it
actually freed: the caller's bounty comes off the top, then `PROJECT_SHARE_BPS` **3000** of the
remainder goes to `project` as BNB and the other **70%** is wrapped to WBNB, approved, and deposited
into the token's own dividend contract; that split is a `constant` with no setter, and `project`
itself is written once by `initialize()` and has no setter either. All three jobs are also
permissionless and paid at fixed rates — `deployPending()` pays `DEPLOY_BOUNTY_BPS` 25 (0.25%) of the
pending revenue it takes in hand, `harvest()` pays `HARVEST_BOUNTY_BPS` 50 (0.5%) of what it frees, `rebalance()`
pays `REBALANCE_BOUNTY_BPS` 30 (0.3%) of what it frees — while the automatic path passes
`address(0)` as the payee and pays no bounty at all, because the trigger fee has already come out of
the treasury. Every job re-reads Venus and decides again, nothing assumes the callback arrived on
time, and every job reverts if it would leave health below `MIN_HEALTH_BPS`. When work reverts,
`trigger()` catches it, emits `WorkFailed` and keeps the slot it already bought; when the treasury
cannot afford the trigger fee, `_schedule` returns silently, `pendingRequestId` stays zero, and
anyone may call `kickstart()` to restart the chain. A holder is paid by this vault only in WBNB,
only through the token's dividend contract, only out of a harvest, and only while holding at least
`minimumShareBalance` 10,000e18 tokens; the vault pushes nothing to individual holders and keeps no
per-holder state. Neither the project nor the deployer can move the split, the leverage target, the
health floor, the bounties, the cadence, the route or the fee tier: they are all `constant`, with no
setter, no role and no governance path, and no change short of the Flap Guardian replacing the
implementation behind the beacon — which is the one authority that does reach them. The Guardian's
authority is the beacon it owns, transferred inside `LeverBeacon`'s constructor so the deployer
never held it, and that upgrade path is the emergency mechanism: this vault runs behind a
BeaconProxy, is therefore exempt from Rule 009, and this implementation deliberately ships no
emergency withdraw and no pause.

## Reading it against the code

| Claim in the paragraph | Where |
|---|---|
| `receive()` is two SSTOREs and one event, no call, no loop | `receive()`; `test_receiveUnder1M`, `test_receiveNeverReverts` |
| WBNB and vBNB returns are not recorded as tax, and survive a 2,300-gas stipend | early return in `receive()`; `test_returnsFromWbnbAndVbnbAreNotCountedAsTax`, `test_receiveSurvivesA2300GasStipend` |
| `project` is written once and has no setter | `initialize()`; `test_projectIsFixedAtInitializeAndHasNoSetter`, `test_initializeIsOnceOnly`, `test_initializeRejectsZeroAddresses` |
| only the trigger service may wake the vault, and only with the awaited id | `trigger()`; `test_triggerRejectsEveryCallerThatIsNotTheService`, `test_triggerRejectsAnIdItIsNotAwaiting` |
| the work wrapper is self-call only | `settleSelf()`; `test_settleSelfIsSelfOnly` |
| the priority order of the four actions is what a wake will do | `_pickAction()`, `pendingAction()`; `test_pendingActionReportsWhatTheNextWakeWillDo` (fork) |
| tax accumulates and then builds to target | `_deploy()` / `_build()`; `test_taxAccumulatesThenBuildsToTarget` (fork) |
| the split is 70% holders / 30% project | `PROJECT_SHARE_BPS`; `test_harvestPaysHoldersSeventyAndProjectThirty` (fork) |
| the automatic path pays no bounty and deploys everything | `bountyTo == address(0)` in `_deploy`/`_harvest`/`_rebalance`; `test_automaticPathPaysNoBountyAndDeploysEverything` (fork) |
| each job refuses when its precondition is absent | `test_deployRefusesWhenThereIsNothingToDeploy`, `test_harvestRefusesWhenThereIsNoGain`, `test_rebalanceRefusesWhileLeverageIsInsideTheBand` |
| the chain can only be restarted when it is actually idle and affordable | `kickstart()`; `test_kickstartRefusesWhenAlreadyScheduled`, `test_kickstartRefusesWhenTheVaultCannotPayTheFee` |
| native BNB is the only quote asset | `isQuoteTokenSupported()`; `test_onlyNativeBnbIsSupportedAsQuote` |
| a launch this vault could never serve is refused before the token exists | `_validateBeforeLaunch()`; `test_launchValidationAcceptsAServeableToken`, `test_launchValidationRejectsTokensTheVaultCouldNeverServe`, `test_theRetiredV6HookIsRefusedNotSilentlyIgnored`, `test_factoryReportsTheV22Spec` |
| only the VaultPortal may create a vault, and every argument is still checked | `newVault()`; `test_newVaultRejectsEveryCallerThatIsNotThePortal`, `test_portalCallStillValidatesEveryArgument` |
| the Guardian owns the beacon; the deployer never did | `LeverBeacon` constructor; `test_beaconIsOwnedByTheGuardianNotTheDeployer`, `test_beaconRefusesAnUnsupportedChain` |
| what the UI is told matches what the contracts expose | `vaultUISchema()`, `vaultDataSchema()`; `test_vaultUISchemaDescribesEveryUserFacingMethod`, `test_everySchemaMethodNameResolvesToARealSelector`, `test_factoryDataSchemaMatchesNewVaultAbi`, `test_descriptionIsNonEmpty` |

The four rows marked **(fork)** live in `test/LeverVaultPosition.t.sol`, one of ten suites (plus
two individual tests inside `LeverVaultAuth`) that gate a `vm.createSelectFork` behind
`KEEL_ARCHIVE=1` and skip their whole `setUp` without it — see `submission/RULES.md` rule 006 for
the full list and why. That is why plain `forge test` reports **40 passed, 0 failed, 11 skipped**
(51 total tests) — every skip there is an archive-only suite declining to run, not a failure. The
full run used for this submission is 59 forge tests + 33 live-state assertions + 8 vault-UI
checks = **100, all green**.

## How the tax reaches the vault, and what the other 2000 does

The four tax destinations are set once at launch and must sum to 10000. Keel splits them
8000 / 2000 / 0 / 0:

| Field | Value | Where it goes |
|---|---:|---|
| `mktBps` | 8000 | native BNB to the vault's `receive()` — this is the money that gets levered |
| `dividendBps` | 2000 | straight into the token's dividend contract, reaching holders without the vault |
| `deflationBps` | 0 | nothing is burned |
| `lpBps` | 0 | nothing is added to LP |

The 2000 is not the vault's, and the vault has no view of it, no claim on it, and no ability to
delay or redirect it. It is the part of the design that does not depend on BNB going up: it is paid
out of trading itself. The 8000 is the part that does — it becomes a position, and holders see it
only when that position gains and a harvest runs.

The vault's own entry point is deliberately the cheapest thing in the contract. Rule 005 caps
`receive()` at 1,000,000 gas; Keel's measures **57,433 gas cold and 9,133 hot**, about 94% headroom.
Everything expensive sits behind functions anyone may call, because a `receive()` that reverts would
break tax collection for the token permanently.

## The four things a wake can do, and how it picks

`_pickAction()` returns one code. The order is a priority, not a menu — the first condition that
holds wins, and the rest are not evaluated as alternatives.

| Code | Name | Condition | What actually runs |
|---:|---|---|---|
| 1 | rescue | `healthBps() < 11000` | `_rebalance(address(0))` with the one-hour cooldown waived |
| 2 | build | `pendingRevenue >= 0.01 BNB` | `_deploy(address(0))` — supply, flash, borrow, swap, repay |
| 3 | harvest | `unrealisedGain() >= 0.02 BNB` | `_harvest(address(0))` — shrink by the gain, split, pay |
| 4 | rebalance | leverage outside 3e18 ± 5% | `_rebalance(address(0))`, subject to the one-hour cooldown |
| 0 | nothing | none of the above | no work; rebook at the idle interval |

Two consequences of that routing are worth stating plainly rather than leaving to be discovered.
First, a **rescue is a rebalance with the cooldown removed**, not a separate code path:
`settleSelf` routes anything that is not 2 or 3 into `_rebalance`, and `_cooldown()` returns zero
whenever health is under the urgent floor. Second, `_rebalance` still begins by requiring
`needsRebalance()`. Under a constant collateral factor those two conditions cannot disagree — reaching
health 1.10 at CF 0.80 requires leverage well outside the band — but they can disagree if Venus
itself lowers the collateral factor, since health is `CF*L/(L-1)` and a CF cut moves health without
moving leverage. At CF 0.70 a position sitting exactly at 3x has health 1.05: urgent, yet inside the
band. The rescue would then revert, `trigger()` would catch it, emit `WorkFailed`, and try again at
the next slot. This is disclosed, not defended.

`pendingAction()` is a public view over the same function, so anyone can read what the next wake
intends to do before it happens.

## Why the build must flash-borrow rather than loop

The obvious way to lever on a lending market is to loop: supply, borrow, swap, supply the proceeds,
borrow again. It does not reach 3x here, and the reason is mechanical rather than a matter of gas.
**Venus checks collateral at the instant of the borrow, before the borrowed funds have become
collateral.** Each pass may therefore only draw what the *existing* collateral already supports, and
the series converges on the ratio the collateral factor and health floor permit rather than the ratio
the design wants — approaching it asymptotically, spending a swap and two Venus calls per pass.

The flash path inverts the order. `_build` sizes the shortfall, flash-borrows exactly that much WBNB
from `FLASH_POOL`, and inside `pancakeV3FlashCallback` unwraps it, supplies it to vBNB **first**, and
only then borrows the USDT against a collateral base that already includes the borrowed BNB. That
USDT is swapped back to WBNB and the flash is repaid in the same transaction. The whole position is
reached in one pass, and if any leg fails the entire transaction reverts and the vault is exactly
where it started.

Three details in that path are load-bearing:

- **The flash pool and the swap pool are different pools on purpose.** A V3 pool is locked during its
  own flash callback, so borrowing and swapping in the same pool reverts `LOK`. Keel flashes the
  0.05% WBNB/USDT pool and swaps the 0.01% tier.
- **Only that one pool may call the callback.** `pancakeV3FlashCallback` requires
  `msg.sender == FLASH_POOL` before it reads a byte of the calldata.
- **Prices ride along in the callback data.** Re-reading Venus's ResilientOracle inside the callback
  costs two more round trips; passing them through bought headroom rather than compliance.
  `AUDIT.md`'s own before/after table puts the automatic settlement callback at **1,510,777** gas
  before the change and **1,206,637** after — inside Rule 008's 2,000,000 cap either way, so the
  optimisation took the margin from 24% to 40% headroom and is not what keeps the callback legal.
  Measured across runs: **1,195,717–1,237,284 gas against a 2,000,000 cap**, roughly 40% headroom.

## Why 3x is the ceiling and not a preference

Health, as this vault computes it, is collateral times the collateral factor over debt. For a
position levered `L` times against a collateral factor `CF`, that is:

```
health = CF * L / (L - 1)
```

At Venus's mainnet collateral factor for BNB, `CF = 0.80`, the whole schedule is fixed by arithmetic
— these are consequences of the formula above, not measurements:

| Leverage | Health at CF 0.80 | Meaning |
|---:|---:|---|
| 2x | 1.60 | far inside the floor |
| **3x** | **1.20** | **exactly `MIN_HEALTH_BPS` — the floor, not a cushion** |
| 4x | 1.0667 | already below the floor this vault enforces |
| 5x | 1.00 | liquidation |

So 3x is not the aggressive end of a range the vault could have chosen from; it is the last integer
multiple that the 1.20 floor admits at all, and 5x is not "more leverage" but the liquidation point
itself. Choosing 4x would mean abandoning the floor; choosing 5x would mean opening a position that
is already liquidatable at the moment it is built.

Because 3x sits *on* the floor rather than under it, the build cannot aim at 3x exactly. `_build`
computes `debtCap = navUsd * cfBps / (MIN_HEALTH_BPS - cfBps)` and then takes **97%** of it, which
buys room for the two costs the closed-form model omits: the flash fee and the quote buffer. The
source records why that number and not a rounder one:

> `99% leaves health at 1.198 and trips the check; 97% lands at 1.205.`

The measured result is **2.960x at health 1.208**, and it was measured not on a fork but by the 33
live-state assertions in `tools/verify.py` — each a single atomic `eth_call` against BNB Chain's
*current* state, with the probe bytecode injected by state override. The forge suite that would
cross-check it needs an archive RPC, and on a pruning public node it dies mid-run with `missing trie
node`, so no fork figure stands behind this number. The contract reports both
through `currentLeverage()` and `healthBps()`, which are views over Venus state — there is no
published NAV to go stale and nobody who can stop publishing it. `_cf()` reads the collateral factor
from the chain rather than hard-coding 0.80, so the floor binds correctly wherever the vault runs;
on BSC testnet, where Venus's CF is 70%, it would bind leverage near 2.4x.

## The split, and that it cannot move

A harvest frees BNB by shrinking the position, then divides what it actually freed:

1. the caller's bounty, `HARVEST_BOUNTY_BPS` 50 (0.5%), or **zero on the automatic path**;
2. of the remainder, `PROJECT_SHARE_BPS` **3000** — 30% — to `project`, as native BNB;
3. the remaining **70%** wrapped to WBNB, approved to the token's dividend contract, and deposited.

`PROJECT_SHARE_BPS` is a `constant`. There is no setter, no role, no governance path and no upgrade
short of the Guardian replacing the implementation behind the beacon. `project` is likewise written
once by `initialize()` from the `vaultData` supplied at creation and has no setter — the project
cannot even move its own payout address. The same 30% is stated on-chain by the factory's
`vaultDataSchema()`, and `submission/check` reads it back from BNB Chain and fails if it disagrees
with the constant in the source.

What the harvest does **not** touch is the basis. `_shrinkBy` takes the gain and only the gain, and
`costBasis` is left where it was, so what remains in the position is still exactly what was paid for
it. Holders are paid out of appreciation; they are never paid out of the principal that produced it.

## The cadence, who calls it, and what a failed wake does

The five-minute cadence is bought, not granted. Each `trigger()` ends by calling
`IFlapTriggerService.requestTrigger` with a fee taken from the vault's own balance, and that fee is
also deducted from `pendingRevenue` so the next build never tries to deploy BNB the vault has already
spent. `TRIGGER_INTERVAL` is 5 minutes when the last wake found work; `IDLE_INTERVAL` is 1 hour when
it found none, because checking every five minutes forever would spend the treasury on trigger fees
during a quiet market. `nextSettlementIn()` reads the booked time back from the service.

The ordering inside `trigger()` is the part that matters under failure. The id is consumed first, so
a replayed callback finds nothing. **The next slot is bought before the work is attempted**, so a
build that reverts cannot also destroy the chain that would have retried it. The work then runs
inside `try this.settleSelf(action)`; a revert is caught and emitted as `WorkFailed(requestId, reason)`
with the raw reason bytes, and the schedule already bought stands. The work is skipped entirely if
`gasleft()` is below `WORK_GAS_FLOOR` 1,800,000, so a callback delivered with too little gas records
nothing rather than half-executing.

The stop this design plans for is the affordable one: `_schedule` returns silently when the vault's
balance is below the service's fee, leaving `pendingRequestId` at zero. That state is public, and
`kickstart()` is permissionless, takes no arguments, pays no bounty, and requires both that the vault
is genuinely idle and that the schedule it buys actually succeeds. Anyone can restart Keel from
there.

It is not the only way the chain can stop, and the others do not end in a state `kickstart()` can
clear. `_pickAction()` and `_schedule` both run inside `trigger()` **outside** the `try`, so if the
oracle read, `getFee()` or `requestTrigger()` reverts, the whole callback reverts — including the
`pendingRequestId = 0` written at the top of it. The id keeps its previous non-zero value and
`kickstart()` then refuses with "already scheduled". `TRIGGER_SERVICE` is a hard-coded `constant`
too, so a service migration ends the cadence with nothing in the contract able to point at a new
one. Those are Guardian-upgrade territory, not `kickstart()` territory. And nothing in this
implementation can pause the vault — but the Guardian can replace it with one that does.

## The permissionless work functions and their bounties

Every job the trigger service can do, a stranger can also do, at a rate nobody can tune:

| Function | Bounty | Paid on | Refuses when |
|---|---:|---|---|
| `deployPending()` | `DEPLOY_BOUNTY_BPS` 25 = **0.25%** | the pending revenue it takes in hand (the rest is deployed) | `pendingRevenue < MIN_DEPLOY` (0.01 BNB) |
| `harvest()` | `HARVEST_BOUNTY_BPS` 50 = **0.5%** | the BNB the unwind actually frees | gain `< MIN_HARVEST` (0.02 BNB), or the dividend token is not WBNB |
| `rebalance()` | `REBALANCE_BOUNTY_BPS` 30 = **0.3%** | the BNB the unwind actually frees | leverage is inside the band, or the cooldown has not expired |

All three are `constant`, which is the substance of the Rule 003 claim: the slippage floor, the
route, the timing and the trigger condition are none of them tunable, so there is nothing an insider
could move in their own favour — nothing, that is, short of the Guardian replacing the
implementation behind the beacon. The route, the fee tier, the flash pool, the health floor, the swap
floor `MAX_SWAP_SLIP_BPS` and all three bounties are compile-time values.

The slippage half of that is a `constant` like the rest, and it should be read for exactly what it
bounds. `_swap` takes its `amountOutMinimum` from the caller, and the exit path supplies one:
`_sellBnb` and `_buyBnb` call `_floor(amountIn, pxIn, pxOut)`, which values the input in units of
the output at the prices already read from Venus's ResilientOracle — the same oracle that decides
whether this position is liquidated, not a second feed with its own failure modes — and subtracts
`MAX_SWAP_SLIP_BPS` **300**, 3%. A harvest or rebalance whose swap lands more than 3% below that
price reverts inside the router with `Too little received`, and the whole unwind reverts with it; on
the automatic path `trigger()` catches that, emits `WorkFailed`, and the slot it already bought
stands.

The build's swap still passes zero, deliberately, and it is not newly protected. Its flash callback
requires `got >= owed` and reverts the entire transaction if the swap returns too little to repay
the flash — a bound on the same quantity, strictly tighter than 3% and enforced by the pool rather
than by an oracle. What changed is the exit, which previously had no floor of any kind.

What the floor does **not** do is prevent sandwiching, and it is deliberately loose for a reason:
the pool legitimately drifts from the oracle between updates, and a floor tight enough to catch
every sandwich would also stop the vault deleveraging in exactly the fast market where deleveraging
matters most — the market in which `MIN_HEALTH_BPS` is closest to being breached. Inside the 3%
band nothing has changed: `_shrinkBy` repays `pay = min(usdt, debt - debtTarget)` out of whatever
the swap actually returned, and `_harvest` asks only that the unwind freed something (`freed > 0`)
and that health still clears `MIN_HEALTH_BPS`. A harvest sandwiched within 3% therefore does not
revert — it distributes less. The floor bounds that loss; it does not eliminate it. That is
disclosed, not defended.

Paying on what was actually released has two consequences worth stating. The first is that a
rebalance which levers *up* normally pays too, contrary to what the shape of the rule suggests:
`_rebalance` runs `_build(0, p)`, whose flash callback over-borrows USDT by 0.3%
(`usdtNeeded = owed * pxBnb / pxUsdt * 1003 / 1000`) and then unwraps the swap surplus with
`IWNative(WBNB).withdraw(got - owed)`. That surplus raises the vault's native balance,
`freed = address(this).balance - bnbBefore` counts it, and `REBALANCE_BOUNTY_BPS` is paid on it — a
small bounty out of the quote buffer rather than out of the position. The second is that anything a
rebalance frees beyond the bounty is added back to `pendingRevenue` rather than sent anywhere, so it
is redeployed by the next build instead of leaking.

The automatic path pays no bounty at all: `settleSelf` passes `address(0)`, every bounty computation
short-circuits to zero, and the full amount goes to work. The trigger fee has already been paid out
of the treasury, and charging a second fee on top of it would be paying twice for the same wake.

## What a holder receives, and when

A holder of the token has two claims, and only one of them is this vault's:

**From the tax directly.** `dividendBps` 2000 of every taxed trade goes into the token's dividend
contract as it happens. It does not pass through the vault, does not depend on the position, and does
not wait for a harvest.

**From the vault.** 70% of every harvest, in **WBNB**, deposited into that same dividend contract by
`IDividend.deposit()`. The vault's obligation ends at that call: it wraps the BNB, approves the
dividend contract, deposits, and holds no per-holder state and no list of holders. Distribution from
there is Flap's dividend contract, on its own terms.

The preconditions, stated exactly:

- A harvest only runs when `unrealisedGain()` — `nav()` minus `costBasis + pendingRevenue` — is at
  least **0.02 BNB**. Below that, nothing is paid, whether the wake is automatic or a stranger calls
  `harvest()`.
- `harvest()` requires the token's `dividendContract().dividendToken()` to be **WBNB**, and the
  factory refuses at launch validation any token that would not satisfy this, because a token that
  fails it could never pay a holder and the mistake would be unrepairable after launch.
- Eligibility is Flap's, not Keel's: `minimumShareBalance` is **10,000e18**, and a holder below that
  balance has no dividend share. This is a protocol minimum, and it is the same value Flap's own
  token uses.
- Nothing is pushed to a holder's address by this vault, so a holder that cannot receive BNB blocks
  nobody.

And the converse, which is the honest half: **while the position is at or below its cost basis, a
holder receives nothing from the vault at all.** `unrealisedGain()` floors at zero, `costBasis` is
never reduced by a harvest, and there is no mechanism that pays holders out of principal. A 3x long
moves three times as fast as spot in both directions, so it loses three times as fast as BNB falls,
and Venus liquidates at health 1.00 — the vault's 1.20 floor and its rescue path exist to keep
distance from that line, not to guarantee it is never crossed.

## What this document does not claim

**It does not claim a token exists.** No token has been launched anywhere — not on BNB Chain, not on
testnet. The parameters above are the launch configuration recorded in `LAUNCH.md`, not a description
of anything trading. What *is* deployed is the factory, the beacon and the implementation, at
identical addresses on chain 56 and chain 97.

Those addresses are in [`FACTORY.md`](FACTORY.md) and `deployments/56.json`; the factory to register is `0x3f09f61D8460D330b7387e460FCcc3A90cCe4313`.

**It does not claim the deployed implementation carries the swap floor.** `MAX_SWAP_SLIP_BPS` and
the floored exit swaps are live: the
implementation behind the beacon on chain 56 and chain 97 is the earlier one, whose exit swaps still
pass `amountOutMinimum: 0`. This document describes the source in this repository, which is what a
vault would run once that implementation is replaced behind the beacon.

**It does not claim any of this was exercised on testnet.** No vault can be created on BSC testnet,
and the reason is the mechanism this document just described. The build path must flash-borrow, and
testnet has nothing to borrow from: `getPool` returned the zero address for 32 WBNB pairs across four
fee tiers, and no `PoolCreated` event appears in the last 40,000 blocks. A pool cannot be built
either — both test USDT contracts gate `mint()` behind `Ownable` with a third party as owner. Venus
itself is live on 97 (vBNB listed, 16.3 tBNB borrowable), so the missing piece is precisely and only
the flash liquidity. The position tests therefore run against a mainnet fork with an archive RPC and
are skipped without one — and on the free public nodes the suite dies mid-run with `missing trie
node`, so what stands behind those four paths in this submission is the live-state `eth_call` set,
not a fork run.

**It does not claim the vault reaches 3x.** It reaches 2.960x, by construction, because the 97%
haircut on the debt cap is what keeps the build from tripping its own health floor.

**It does not claim there is an emergency withdraw.** There is none, and that is a choice: a
BeaconProxy vault is exempt from Rule 009, and the Guardian's ability to replace the implementation
behind the beacon it already owns is the emergency mechanism. The trade is stated rather than hidden
— there is no privileged drain, and there is also no privileged rescue that is not an upgrade.

**Two items remain open at the time of writing.** The 30% project share needs Flap's written
acceptance under the Rule 002 recommendation, and an account holding `VAULT_ADMIN_ROLE` must call
`registerVaultFactory` before the factory can be used by the portal.
